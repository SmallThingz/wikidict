const std = @import("std");
const lua = @import("../parser/root.zig");
const analysis = @import("analysis.zig");
const numbers = @import("numbers.zig");
const shapes = @import("shapes.zig");
const static_fields = @import("../abi/static_fields.zig");

const A = std.mem.Allocator;
const value_size = 32;
const value_align = 8;

pub const ModuleIdMap = std.StringHashMapUnmanaged(u32);
pub const ProgramFacts = struct {
    module_ids: ?*const ModuleIdMap = null,
    table_shapes: ?*const shapes.ModuleFacts = null,

    pub fn moduleId(self: ProgramFacts, a: A, raw: []const u8) !?u32 {
        const ids = self.module_ids orelse return null;
        if (ids.get(raw)) |id| return id;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (!std.mem.eql(u8, raw, trimmed)) if (ids.get(trimmed)) |id| return id;
        if (std.mem.indexOfScalar(u8, trimmed, '_') == null) return null;
        const normalized = try a.dupe(u8, trimmed);
        defer a.free(normalized);
        std.mem.replaceScalar(u8, normalized, '_', ' ');
        return ids.get(normalized);
    }

    pub fn tableShape(self: ProgramFacts, span_start: u32) ?shapes.Fact {
        const table_shapes = self.table_shapes orelse return null;
        return table_shapes.get(span_start);
    }
};

fn text(out: *std.ArrayList(u8), a: A, bytes: []const u8) anyerror!void {
    try out.appendSlice(a, bytes);
}
fn print(out: *std.ArrayList(u8), a: A, comptime format: []const u8, args: anytype) anyerror!void {
    const bytes = try std.fmt.allocPrint(a, format, args);
    defer a.free(bytes);
    try out.appendSlice(a, bytes);
}

const StringRef = struct { id: u32, len: usize };
const TableRef = struct { ptr: []const u8, shape: ?shapes.Fact = null, native_namespace: ?static_fields.Namespace = null };
const StaticFunctionRef = struct {
    target: *const analysis.FunctionInfo,
    captures_ptr: []const u8,
    captures_len: usize,
};
const ValueRef = union(enum) {
    nil,
    boolean: []const u8,
    number: []const u8,
    string: StringRef,
    table: TableRef,
    boxed: []const u8,
};
const MultiRef = struct {
    ptr: []const u8,
    len: []const u8,
    owned: bool,
};

const StringPool = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    items: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *StringPool, a: A) void {
        self.map.deinit(a);
        self.items.deinit(a);
    }

    fn intern(self: *StringPool, a: A, value: []const u8) anyerror!StringRef {
        if (self.map.get(value)) |id| return .{ .id = id, .len = value.len };
        const id: u32 = @intCast(self.items.items.len);
        try self.items.append(a, value);
        try self.map.put(a, value, id);
        return .{ .id = id, .len = value.len };
    }
};

const LocalStorage = union(enum) {
    uninitialized,
    direct: ValueRef,
    static_function: StaticFunctionRef,
    number: []const u8,
    boolean: []const u8,
    value: []const u8,
    cell: []const u8,
};
pub const Generated = struct {
    source: []u8,
    root_function: u32,
    function_count: u32,
};

const ModuleEmitter = struct {
    allocator: A,
    globals: *const analysis.Globals,
    module: *const analysis.Module,
    facts: ProgramFacts,
    strings: StringPool = .{},
    out: std.ArrayList(u8) = .empty,

    fn deinit(self: *ModuleEmitter) void {
        self.strings.deinit(self.allocator);
        self.out.deinit(self.allocator);
    }

    fn functionForSpan(self: *const ModuleEmitter, span: lua.Span) anyerror!*const analysis.FunctionInfo {
        for (self.module.functions.items[1..]) |info|
            if (info.span.start == span.start and info.span.end == span.end) return info;
        return error.MissingFunctionAnalysis;
    }
};

fn emitPreamble(out: *std.ArrayList(u8), a: A) anyerror!void {
    try text(out, a, "%FunctionResult = type { ptr, i64, i32, i32 }\n%CallResult = type { ptr, i64, i32, i32 }\n%Value = type [32 x i8]\n\n");
    try text(out, a, "declare void @dict_lua_value_nil(ptr)\n" ++
        "declare void @dict_lua_value_bool(ptr, i8)\n" ++
        "declare void @dict_lua_value_number(ptr, double)\n" ++
        "declare void @dict_lua_value_string(ptr, ptr, i64)\n" ++
        "declare void @dict_lua_value_copy(ptr, ptr)\n" ++
        "declare i8 @dict_lua_value_truthy(ptr)\n" ++
        "declare i8 @dict_lua_value_is_nil(ptr)\n" ++
        "declare i32 @dict_lua_require_number(ptr, ptr, ptr)\n" ++
        "declare ptr @dict_lua_arg_ptr(ptr, i64, i64)\n" ++
        "declare void @dict_lua_arg_get(ptr, i64, i64, ptr)\n" ++
        "declare ptr @dict_lua_global_ptr(ptr, i32)\n" ++
        "declare void @dict_lua_global_get(ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_global_set(ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_require_module_id(ptr, i32, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_new_table(ptr, ptr)\n" ++
        "declare i32 @dict_lua_new_array_table(ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_new_shaped_table(ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_table_append(ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_table_append_many(ptr, ptr, ptr, i64)\n" ++
        "declare i32 @dict_lua_get_index(ptr, ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_set_index(ptr, ptr, ptr, ptr)\n");
    try text(out, a, "declare i32 @dict_lua_get_field(ptr, ptr, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_set_field(ptr, ptr, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_set_shape_slot(ptr, ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_get_known_shape_field(ptr, ptr, i32, i32, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_set_known_shape_field(ptr, ptr, i32, i32, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_get_native_slot(ptr, ptr, i32, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_set_native_slot(ptr, ptr, i32, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_len_number(ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_neg(ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_binary(ptr, i8, ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_compare_bool(ptr, i8, ptr, ptr, ptr)\n" ++
        "declare i32 @dict_lua_concat(ptr, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_cell_new(ptr, ptr, ptr)\n" ++
        "declare void @dict_lua_cell_get(ptr, ptr)\n" ++
        "declare void @dict_lua_cell_set(ptr, ptr)\n" ++
        "declare i32 @dict_lua_capture_cell(ptr, ptr, i32, ptr)\n" ++
        "declare i32 @dict_lua_make_function(ptr, i32, ptr, ptr, i64, ptr)\n" ++
        "declare i32 @dict_lua_call_fixed(ptr, ptr, ptr, i64, ptr, i64)\n" ++
        "declare i32 @dict_lua_call_fixed_tail(ptr, ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
        "declare i32 @dict_lua_call_static_fixed(ptr, ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
        "declare i32 @dict_lua_call_static_fixed_tail(ptr, ptr, ptr, i64, ptr, i64, ptr, i64, ptr, i64)\n" ++
        "declare i32 @dict_lua_enter_static_call(ptr)\n" ++
        "declare void @dict_lua_leave_static_call(ptr)\n" ++
        "declare i32 @dict_lua_function_status(ptr, i32)\n");
    try text(out, a, "declare i32 @dict_lua_call_discard(ptr, ptr, ptr, i64)\n" ++
        "declare i32 @dict_lua_call_discard_tail(ptr, ptr, ptr, i64, ptr, i64)\n" ++
        "declare %CallResult @dict_lua_call_multi(ptr, ptr, ptr, i64)\n" ++
        "declare %CallResult @dict_lua_call_multi_tail(ptr, ptr, ptr, i64, ptr, i64)\n" ++
        "declare %CallResult @dict_lua_call_static_multi(ptr, ptr, ptr, i64, ptr, i64)\n" ++
        "declare %CallResult @dict_lua_call_static_multi_tail(ptr, ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
        "declare void @dict_lua_results_free(ptr, i64)\n" ++
        "declare %FunctionResult @dict_lua_return_values(ptr, ptr, i64, ptr, i64)\n" ++
        "declare %FunctionResult @dict_lua_return_join(ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
        "declare %FunctionResult @dict_lua_function_error()\n" ++
        "declare double @llvm.floor.f64(double)\n" ++
        "declare double @llvm.pow.f64(double, double)\n\n");
}

fn llvmByte(out: *std.ArrayList(u8), a: A, byte: u8) anyerror!void {
    if (byte >= 0x20 and byte <= 0x7e and byte != '"' and byte != '\\')
        try out.append(a, byte)
    else
        try print(out, a, "\\{X:0>2}", .{byte});
}
fn emitStrings(emitter: *ModuleEmitter) anyerror!void {
    if (emitter.strings.items.items.len == 0) return;
    try text(&emitter.out, emitter.allocator, "\n; module-local immutable strings\n");
    for (emitter.strings.items.items, 0..) |value, id| {
        try print(&emitter.out, emitter.allocator, "@lua_s_{d} = private unnamed_addr constant [{d} x i8] c\"", .{ id, value.len });
        for (value) |byte| try llvmByte(&emitter.out, emitter.allocator, byte);
        try text(&emitter.out, emitter.allocator, "\", align 1\n");
    }
}

fn functionName(a: A, id: u32) anyerror![]u8 {
    return std.fmt.allocPrint(a, "@lua_f_{d}", .{id});
}

const Save = struct { name: []const u8, previous: ?u32 };
const Resolved = union(enum) { local: u32, upvalue: u32, global: u32 };
const PreparedTarget = union(enum) {
    name: Resolved,
    index: struct { object: ValueRef, key: ValueRef },
    field: struct { object: ValueRef, key: StringRef },
};
const FnEmitter = struct {
    module: *ModuleEmitter,
    info: *const analysis.FunctionInfo,
    allocas: std.ArrayList(u8) = .empty,
    code: std.ArrayList(u8) = .empty,
    locals: std.StringHashMapUnmanaged(u32) = .empty,
    saves: std.ArrayList(Save) = .empty,
    storage: []LocalStorage,
    upvalue_slots: [][]const u8,
    binding_next: u32 = 0,
    temp_next: u32 = 0,
    label_next: u32 = 0,
    array_next: u32 = 0,
    breaks: std.ArrayList([]const u8) = .empty,
    owned_names: std.ArrayList([]u8) = .empty,
    error_used: bool = false,

    fn a(self: *FnEmitter) A {
        return self.module.allocator;
    }

    fn deinit(self: *FnEmitter) void {
        self.allocas.deinit(self.a());
        self.code.deinit(self.a());
        self.locals.deinit(self.a());
        self.saves.deinit(self.a());
        self.a().free(self.storage);
        self.a().free(self.upvalue_slots);
        self.breaks.deinit(self.a());
        for (self.owned_names.items) |value| self.a().free(value);
        self.owned_names.deinit(self.a());
    }
    fn ownFmt(self: *FnEmitter, comptime format: []const u8, args: anytype) anyerror![]const u8 {
        const value = try std.fmt.allocPrint(self.a(), format, args);
        errdefer self.a().free(value);
        try self.owned_names.append(self.a(), value);
        return value;
    }
    fn temp(self: *FnEmitter, prefix: []const u8) anyerror![]const u8 {
        const id = self.temp_next;
        self.temp_next += 1;
        return self.ownFmt("%{s}{d}", .{ prefix, id });
    }

    fn label(self: *FnEmitter, prefix: []const u8) anyerror![]const u8 {
        const id = self.label_next;
        self.label_next += 1;
        return self.ownFmt("bb_{s}{d}", .{ prefix, id });
    }

    fn valueSlot(self: *FnEmitter) anyerror![]const u8 {
        const slot = try self.temp("v");
        try print(&self.allocas, self.a(), "  {s} = alloca %Value, align {d}\n", .{ slot, value_align });
        return slot;
    }

    fn ptrSlot(self: *FnEmitter) anyerror![]const u8 {
        const slot = try self.temp("p");
        try print(&self.allocas, self.a(), "  {s} = alloca ptr, align 8\n", .{slot});
        return slot;
    }

    fn nativeNumberSlot(self: *FnEmitter) anyerror![]const u8 {
        const slot = try self.temp("numlocal");
        try print(&self.allocas, self.a(), "  {s} = alloca double, align 8\n", .{slot});
        return slot;
    }

    fn nativeBoolSlot(self: *FnEmitter) anyerror![]const u8 {
        const slot = try self.temp("boollocal");
        try print(&self.allocas, self.a(), "  {s} = alloca i1, align 1\n", .{slot});
        return slot;
    }

    fn valueArray(self: *FnEmitter, count: usize) anyerror![]const u8 {
        const id = self.array_next;
        self.array_next += 1;
        const slot = try self.ownFmt("%a{d}", .{id});
        try print(&self.allocas, self.a(), "  {s} = alloca [{d} x %Value], align {d}\n", .{ slot, @max(count, 1), value_align });
        return slot;
    }
    fn arrayElem(self: *FnEmitter, array: []const u8, index: usize) anyerror![]const u8 {
        const ptr = try self.temp("e");
        try print(&self.code, self.a(), "  {s} = getelementptr %Value, ptr {s}, i64 {d}\n", .{ ptr, array, index });
        return ptr;
    }

    fn check(self: *FnEmitter, status: []const u8) anyerror!void {
        self.error_used = true;
        const ok = try self.temp("ok");
        const cont = try self.label("ok");
        try print(&self.code, self.a(), "  {s} = icmp eq i32 {s}, 0\n", .{ ok, status });
        try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %error\n{s}:\n", .{ ok, cont, cont });
    }

    fn copyValue(self: *FnEmitter, dst: []const u8, src: []const u8) anyerror!void {
        try print(&self.code, self.a(), "  call void @dict_lua_value_copy(ptr {s}, ptr {s})\n", .{ dst, src });
    }

    fn stringRef(self: *FnEmitter, value: []const u8) anyerror!StringRef {
        return self.module.strings.intern(self.a(), value);
    }

    fn box(self: *FnEmitter, value: ValueRef) anyerror![]const u8 {
        switch (value) {
            .boxed => |ptr| return ptr,
            .table => |table_value| return table_value.ptr,
            else => {},
        }
        const out = try self.valueSlot();
        switch (value) {
            .nil => try print(&self.code, self.a(), "  call void @dict_lua_value_nil(ptr {s})\n", .{out}),
            .number => |operand| try print(&self.code, self.a(), "  call void @dict_lua_value_number(ptr {s}, double {s})\n", .{ out, operand }),
            .boolean => |operand| {
                const wide = try self.temp("b8");
                try print(&self.code, self.a(), "  {s} = zext i1 {s} to i8\n", .{ wide, operand });
                try print(&self.code, self.a(), "  call void @dict_lua_value_bool(ptr {s}, i8 {s})\n", .{ out, wide });
            },
            .string => |s| try print(&self.code, self.a(), "  call void @dict_lua_value_string(ptr {s}, ptr @lua_s_{d}, i64 {d})\n", .{ out, s.id, s.len }),
            .table, .boxed => unreachable,
        }
        return out;
    }

    fn materializeCopy(self: *FnEmitter, value: ValueRef) anyerror![]const u8 {
        const boxed = try self.box(value);
        const out = try self.valueSlot();
        try self.copyValue(out, boxed);
        return out;
    }

    fn truthy(self: *FnEmitter, value: ValueRef) anyerror![]const u8 {
        return switch (value) {
            .nil => "false",
            .boolean => |v| v,
            .number, .string, .table => "true",
            .boxed => |ptr| blk: {
                const raw = try self.temp("truth");
                const out = try self.temp("truth1");
                try print(&self.code, self.a(), "  {s} = call i8 @dict_lua_value_truthy(ptr {s})\n", .{ raw, ptr });
                try print(&self.code, self.a(), "  {s} = icmp ne i8 {s}, 0\n", .{ out, raw });
                break :blk out;
            },
        };
    }
    fn init(module: *ModuleEmitter, info: *const analysis.FunctionInfo) anyerror!FnEmitter {
        const storage = try module.allocator.alloc(LocalStorage, info.bindings.len);
        errdefer module.allocator.free(storage);
        const upvalue_slots = try module.allocator.alloc([]const u8, info.upvalues.len);
        errdefer module.allocator.free(upvalue_slots);
        var self = FnEmitter{ .module = module, .info = info, .storage = storage, .upvalue_slots = upvalue_slots };
        errdefer self.deinit();
        for (info.bindings, 0..) |binding, index| {
            self.storage[index] = if (binding.captured)
                .{ .cell = try self.ptrSlot() }
            else if (binding.late_function_init and !binding.directCallOnly())
                .{ .value = try self.valueSlot() }
            else if (!binding.mutated)
                .uninitialized
            else switch (binding.static_type) {
                .number => .{ .number = try self.nativeNumberSlot() },
                .boolean => .{ .boolean = try self.nativeBoolSlot() },
                else => .{ .value = try self.valueSlot() },
            };
        }
        for (info.upvalues, 0..) |_, index| self.upvalue_slots[index] = try self.ptrSlot();
        return self;
    }

    fn bindName(self: *FnEmitter, name: []const u8) anyerror!u32 {
        if (self.binding_next >= self.info.bindings.len) return error.BindingAnalysisMismatch;
        const id = self.binding_next;
        self.binding_next += 1;
        if (!std.mem.eql(u8, self.info.bindings[id].name, name)) return error.BindingAnalysisMismatch;
        try self.saves.append(self.a(), .{ .name = name, .previous = self.locals.get(name) });
        try self.locals.put(self.a(), name, id);
        return id;
    }
    fn endScope(self: *FnEmitter, mark: usize) void {
        while (self.saves.items.len > mark) {
            const save = self.saves.pop().?;
            if (save.previous) |id|
                self.locals.put(self.a(), save.name, id) catch unreachable
            else
                _ = self.locals.remove(save.name);
        }
    }

    fn upvalueOrdinal(self: *const FnEmitter, name: []const u8) ?u32 {
        for (self.info.upvalues, 0..) |upvalue, index|
            if (std.mem.eql(u8, upvalue.name, name)) return @intCast(index);
        return null;
    }

    fn nativeGlobalNamespace(name: []const u8) ?static_fields.Namespace {
        if (std.mem.eql(u8, name, "table")) return .table;
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "math")) return .math;
        if (std.mem.eql(u8, name, "debug")) return .debug;
        if (std.mem.eql(u8, name, "mw")) return .mw;
        return null;
    }

    fn resolve(self: *FnEmitter, name: []const u8) anyerror!Resolved {
        if (self.locals.get(name)) |binding| return .{ .local = binding };
        if (self.upvalueOrdinal(name)) |ordinal| return .{ .upvalue = ordinal };
        return .{ .global = self.module.globals.get(name) orelse return error.MissingGlobalAnalysis };
    }

    fn initBinding(self: *FnEmitter, binding: u32, value: ValueRef) anyerror!void {
        switch (self.storage[binding]) {
            .uninitialized => self.storage[binding] = .{ .direct = value },
            .direct, .static_function => return error.BindingInitializedTwice,
            .number => |slot| {
                if (value != .number) return error.StaticTypeMismatch;
                try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n", .{ value.number, slot });
            },
            .boolean => |slot| {
                if (value != .boolean) return error.StaticTypeMismatch;
                try print(&self.code, self.a(), "  store i1 {s}, ptr {s}, align 1\n", .{ value.boolean, slot });
            },
            .value => |slot| try self.copyValue(slot, try self.box(value)),
            .cell => |slot| {
                const boxed = try self.box(value);
                const status = try self.temp("st");
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_cell_new(ptr %ctx, ptr {s}, ptr {s})\n", .{ status, boxed, slot });
                try self.check(status);
            },
        }
    }
    fn loadResolved(self: *FnEmitter, resolved: Resolved) anyerror!ValueRef {
        return switch (resolved) {
            .local => |binding| switch (self.storage[binding]) {
                .uninitialized => error.UninitializedBinding,
                .direct => |value| value,
                .static_function => error.DirectFunctionUsedAsValue,
                .number => |slot| blk: {
                    const out = try self.temp("numlocal_load");
                    try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ out, slot });
                    break :blk .{ .number = out };
                },
                .boolean => |slot| blk: {
                    const out = try self.temp("boollocal_load");
                    try print(&self.code, self.a(), "  {s} = load i1, ptr {s}, align 1\n", .{ out, slot });
                    break :blk .{ .boolean = out };
                },
                .value => |slot| blk: {
                    const out = try self.valueSlot();
                    try self.copyValue(out, slot);
                    break :blk .{ .boxed = out };
                },
                .cell => |slot| blk: {
                    const out = try self.valueSlot();
                    const cell = try self.temp("cell");
                    try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, slot });
                    try print(&self.code, self.a(), "  call void @dict_lua_cell_get(ptr {s}, ptr {s})\n", .{ cell, out });
                    break :blk .{ .boxed = out };
                },
            },
            .upvalue => |ordinal| blk: {
                const out = try self.valueSlot();
                const cell = try self.temp("cell");
                try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, self.upvalue_slots[ordinal] });
                try print(&self.code, self.a(), "  call void @dict_lua_cell_get(ptr {s}, ptr {s})\n", .{ cell, out });
                break :blk .{ .boxed = out };
            },
            .global => |slot| blk: {
                if (self.module.globals.stableSlot(slot)) {
                    const ptr = try self.temp("global");
                    try print(&self.code, self.a(), "  {s} = call ptr @dict_lua_global_ptr(ptr %ctx, i32 {d})\n", .{ ptr, slot });
                    const name = self.module.globals.names.items[slot];
                    if (nativeGlobalNamespace(name)) |namespace|
                        break :blk .{ .table = .{ .ptr = ptr, .native_namespace = namespace } };
                    break :blk .{ .boxed = ptr };
                }
                const out = try self.valueSlot();
                try print(&self.code, self.a(), "  call void @dict_lua_global_get(ptr %ctx, i32 {d}, ptr {s})\n", .{ slot, out });
                break :blk .{ .boxed = out };
            },
        };
    }

    fn storeResolved(self: *FnEmitter, resolved: Resolved, value: ValueRef) anyerror!void {
        switch (resolved) {
            .local => |binding| switch (self.storage[binding]) {
                .uninitialized, .direct, .static_function => return error.MutationAnalysisMismatch,
                .number => |slot| {
                    if (value != .number) return error.StaticTypeMismatch;
                    try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n", .{ value.number, slot });
                },
                .boolean => |slot| {
                    if (value != .boolean) return error.StaticTypeMismatch;
                    try print(&self.code, self.a(), "  store i1 {s}, ptr {s}, align 1\n", .{ value.boolean, slot });
                },
                .value => |slot| try self.copyValue(slot, try self.box(value)),
                .cell => |slot| {
                    const boxed = try self.box(value);
                    const cell = try self.temp("cell");
                    try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, slot });
                    try print(&self.code, self.a(), "  call void @dict_lua_cell_set(ptr {s}, ptr {s})\n", .{ cell, boxed });
                },
            },
            .upvalue => |ordinal| {
                const boxed = try self.box(value);
                const cell = try self.temp("cell");
                try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, self.upvalue_slots[ordinal] });
                try print(&self.code, self.a(), "  call void @dict_lua_cell_set(ptr {s}, ptr {s})\n", .{ cell, boxed });
            },
            .global => |slot| {
                const boxed = try self.box(value);
                const status = try self.temp("st");
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_global_set(ptr %ctx, i32 {d}, ptr {s})\n", .{ status, slot, boxed });
                try self.check(status);
            },
        }
    }

    fn numberOperand(self: *FnEmitter, raw: []const u8) anyerror![]const u8 {
        const value = try numbers.parse(raw);
        return self.ownFmt("0x{X:0>16}", .{@as(u64, @bitCast(value))});
    }
    fn nativeArith(self: *FnEmitter, op: lua.BinaryOp, lhs: []const u8, rhs: []const u8) anyerror!ValueRef {
        const out = try self.temp("n");
        switch (op) {
            .add => try print(&self.code, self.a(), "  {s} = fadd double {s}, {s}\n", .{ out, lhs, rhs }),
            .sub => try print(&self.code, self.a(), "  {s} = fsub double {s}, {s}\n", .{ out, lhs, rhs }),
            .mul => try print(&self.code, self.a(), "  {s} = fmul double {s}, {s}\n", .{ out, lhs, rhs }),
            .div => try print(&self.code, self.a(), "  {s} = fdiv double {s}, {s}\n", .{ out, lhs, rhs }),
            .pow => try print(&self.code, self.a(), "  {s} = call double @llvm.pow.f64(double {s}, double {s})\n", .{ out, lhs, rhs }),
            .mod => {
                const div = try self.temp("div");
                const floor = try self.temp("floor");
                const product = try self.temp("mul");
                try print(&self.code, self.a(), "  {s} = fdiv double {s}, {s}\n", .{ div, lhs, rhs });
                try print(&self.code, self.a(), "  {s} = call double @llvm.floor.f64(double {s})\n", .{ floor, div });
                try print(&self.code, self.a(), "  {s} = fmul double {s}, {s}\n", .{ product, floor, rhs });
                try print(&self.code, self.a(), "  {s} = fsub double {s}, {s}\n", .{ out, lhs, product });
            },
            else => unreachable,
        }
        return .{ .number = out };
    }
    fn nativeCompare(self: *FnEmitter, op: lua.BinaryOp, lhs: []const u8, rhs: []const u8) anyerror!ValueRef {
        const predicate: []const u8 = switch (op) {
            .eq => "oeq",
            .ne => "une",
            .lt => "olt",
            .le => "ole",
            .gt => "ogt",
            .ge => "oge",
            else => unreachable,
        };
        const out = try self.temp("cmp");
        try print(&self.code, self.a(), "  {s} = fcmp {s} double {s}, {s}\n", .{ out, predicate, lhs, rhs });
        return .{ .boolean = out };
    }

    fn dynamicBinary(self: *FnEmitter, op: lua.BinaryOp, lhs: ValueRef, rhs: ValueRef) anyerror!ValueRef {
        const lhs_box = try self.box(lhs);
        const rhs_box = try self.box(rhs);
        const out = try self.valueSlot();
        const status = try self.temp("st");
        const raw: u8 = switch (op) {
            .add => 0,
            .sub => 1,
            .mul => 2,
            .div => 3,
            .mod => 4,
            .pow => 5,
            else => unreachable,
        };
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_binary(ptr %ctx, i8 {d}, ptr {s}, ptr {s}, ptr {s})\n", .{ status, raw, lhs_box, rhs_box, out });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn dynamicCompare(self: *FnEmitter, op: lua.BinaryOp, lhs: ValueRef, rhs: ValueRef) anyerror!ValueRef {
        const lhs_box = try self.box(lhs);
        const rhs_box = try self.box(rhs);
        const raw_slot = try self.temp("cmp8slot");
        try print(&self.allocas, self.a(), "  {s} = alloca i8, align 1\n", .{raw_slot});
        const status = try self.temp("st");
        const raw: u8 = switch (op) {
            .eq => 0,
            .ne => 1,
            .lt => 2,
            .le => 3,
            .gt => 4,
            .ge => 5,
            else => unreachable,
        };
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_compare_bool(ptr %ctx, i8 {d}, ptr {s}, ptr {s}, ptr {s})\n", .{ status, raw, lhs_box, rhs_box, raw_slot });
        try self.check(status);
        const raw_value = try self.temp("cmp8");
        const out = try self.temp("cmp1");
        try print(&self.code, self.a(), "  {s} = load i8, ptr {s}, align 1\n  {s} = icmp ne i8 {s}, 0\n", .{ raw_value, raw_slot, out, raw_value });
        return .{ .boolean = out };
    }

    fn binary(self: *FnEmitter, op: lua.BinaryOp, lhs_expr: *const lua.Expr, rhs_expr: *const lua.Expr) anyerror!ValueRef {
        if (op == .and_ or op == .or_) return self.shortCircuit(op, lhs_expr, rhs_expr);
        if (op == .concat) return self.concat(lhs_expr, rhs_expr);
        const lhs = try self.expr(lhs_expr);
        const rhs = try self.expr(rhs_expr);
        switch (op) {
            .add, .sub, .mul, .div, .mod, .pow => {
                if (lhs == .number and rhs == .number) return self.nativeArith(op, lhs.number, rhs.number);
                return self.dynamicBinary(op, lhs, rhs);
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                if (lhs == .number and rhs == .number) return self.nativeCompare(op, lhs.number, rhs.number);
                return self.dynamicCompare(op, lhs, rhs);
            },
            else => unreachable,
        }
    }
    fn shortCircuit(self: *FnEmitter, op: lua.BinaryOp, lhs_expr: *const lua.Expr, rhs_expr: *const lua.Expr) anyerror!ValueRef {
        const lhs = try self.expr(lhs_expr);
        if (lhs == .nil) return if (op == .and_) lhs else try self.expr(rhs_expr);
        if (lhs == .number or lhs == .string or lhs == .table) return if (op == .or_) lhs else try self.expr(rhs_expr);
        const out = try self.valueSlot();
        const lhs_box = try self.box(lhs);
        try self.copyValue(out, lhs_box);
        const condition = try self.truthy(lhs);
        const rhs_label = try self.label("sc_rhs");
        const done = try self.label("sc_done");
        if (op == .and_)
            try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n", .{ condition, rhs_label, done })
        else
            try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n", .{ condition, done, rhs_label });
        try print(&self.code, self.a(), "{s}:\n", .{rhs_label});
        const rhs = try self.expr(rhs_expr);
        const rhs_box = try self.box(rhs);
        try self.copyValue(out, rhs_box);
        try print(&self.code, self.a(), "  br label %{s}\n{s}:\n", .{ done, done });
        return .{ .boxed = out };
    }

    fn collectConcat(node: *const lua.Expr, out: *std.ArrayList(*const lua.Expr), allocator: A) anyerror!void {
        if (node.* == .binary and node.binary.op == .concat) {
            try collectConcat(node.binary.lhs, out, allocator);
            try collectConcat(node.binary.rhs, out, allocator);
        } else try out.append(allocator, node);
    }
    fn concat(self: *FnEmitter, lhs: *const lua.Expr, rhs: *const lua.Expr) anyerror!ValueRef {
        var parts: std.ArrayList(*const lua.Expr) = .empty;
        defer parts.deinit(self.a());
        try collectConcat(lhs, &parts, self.a());
        try collectConcat(rhs, &parts, self.a());
        const array = try self.valueArray(parts.items.len);
        for (parts.items, 0..) |part, index| {
            const value = try self.expr(part);
            const boxed = try self.box(value);
            const dst = try self.arrayElem(array, index);
            try self.copyValue(dst, boxed);
        }
        const out = try self.valueSlot();
        const status = try self.temp("st");
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_concat(ptr %ctx, ptr {s}, i64 {d}, ptr {s})\n", .{ status, array, parts.items.len, out });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn unary(self: *FnEmitter, op: lua.UnaryOp, operand_expr: *const lua.Expr) anyerror!ValueRef {
        const operand = try self.expr(operand_expr);
        return switch (op) {
            .not_ => blk: {
                const truth = try self.truthy(operand);
                const out = try self.temp("not");
                try print(&self.code, self.a(), "  {s} = xor i1 {s}, true\n", .{ out, truth });
                break :blk .{ .boolean = out };
            },
            .neg => blk: {
                if (operand == .number) {
                    const out = try self.temp("neg");
                    try print(&self.code, self.a(), "  {s} = fneg double {s}\n", .{ out, operand.number });
                    break :blk .{ .number = out };
                }
                const boxed = try self.box(operand);
                const out = try self.valueSlot();
                const status = try self.temp("st");
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_neg(ptr %ctx, ptr {s}, ptr {s})\n", .{ status, boxed, out });
                try self.check(status);
                break :blk .{ .boxed = out };
            },
            .len => blk: {
                if (operand == .string) {
                    const bits: u64 = @bitCast(@as(f64, @floatFromInt(operand.string.len)));
                    break :blk .{ .number = try self.ownFmt("0x{X:0>16}", .{bits}) };
                }
                const boxed = try self.box(operand);
                const slot = try self.temp("lenslot");
                try print(&self.allocas, self.a(), "  {s} = alloca double, align 8\n", .{slot});
                const status = try self.temp("st");
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_len_number(ptr %ctx, ptr {s}, ptr {s})\n", .{ status, boxed, slot });
                try self.check(status);
                const out = try self.temp("len");
                try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ out, slot });
                break :blk .{ .number = out };
            },
        };
    }
    fn pointerArray(self: *FnEmitter, count: usize) anyerror![]const u8 {
        const id = self.array_next;
        self.array_next += 1;
        const slot = try self.ownFmt("%pa{d}", .{id});
        try print(&self.allocas, self.a(), "  {s} = alloca [{d} x ptr], align 8\n", .{ slot, @max(count, 1) });
        return slot;
    }

    fn pointerArrayElem(self: *FnEmitter, array: []const u8, index: usize) anyerror![]const u8 {
        const ptr = try self.temp("pe");
        try print(&self.code, self.a(), "  {s} = getelementptr ptr, ptr {s}, i64 {d}\n", .{ ptr, array, index });
        return ptr;
    }

    fn staticFunction(self: *FnEmitter, target: *const analysis.FunctionInfo) anyerror!StaticFunctionRef {
        var captures_ptr: []const u8 = "null";
        if (target.upvalues.len != 0) {
            const captures = try self.pointerArray(target.upvalues.len);
            captures_ptr = captures;
            for (target.upvalues, 0..) |upvalue, index| {
                const cell = try self.temp("cap");
                switch (upvalue.source) {
                    .local => |binding| switch (self.storage[binding]) {
                        .cell => |slot| try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, slot }),
                        .uninitialized, .direct, .static_function, .number, .boolean, .value => return error.CaptureAnalysisMismatch,
                    },
                    .upvalue => |ordinal| try print(&self.code, self.a(), "  {s} = load ptr, ptr {s}, align 8\n", .{ cell, self.upvalue_slots[ordinal] }),
                }
                const cell_slot = try self.pointerArrayElem(captures, index);
                try print(&self.code, self.a(), "  store ptr {s}, ptr {s}, align 8\n", .{ cell, cell_slot });
            }
        }
        return .{ .target = target, .captures_ptr = captures_ptr, .captures_len = target.upvalues.len };
    }

    fn closure(self: *FnEmitter, target: *const analysis.FunctionInfo) anyerror!ValueRef {
        const direct = try self.staticFunction(target);
        const out = try self.valueSlot();
        const status = try self.temp("st");
        const target_name = try self.ownFmt("@lua_f_{d}", .{target.id});
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_make_function(ptr %ctx, i32 {d}, ptr {s}, ptr {s}, i64 {d}, ptr {s})\n", .{ status, target.id, target_name, direct.captures_ptr, direct.captures_len, out });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn getIndex(self: *FnEmitter, object: ValueRef, key_expr: *const lua.Expr) anyerror!ValueRef {
        if (staticString(key_expr)) |name| return self.getField(object, name);
        const object_box = try self.box(object);
        const out = try self.valueSlot();
        const status = try self.temp("st");
        const key = try self.expr(key_expr);
        const key_box = try self.box(key);
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_get_index(ptr %ctx, ptr {s}, ptr {s}, ptr {s})\n", .{ status, object_box, key_box, out });
        try self.check(status);
        return .{ .boxed = out };
    }
    fn table(self: *FnEmitter, table_expr: anytype) anyerror!ValueRef {
        const fields = table_expr.fields;
        const table_value = try self.valueSlot();
        const create_status = try self.temp("st");
        const shape = self.module.facts.tableShape(table_expr.span.start);
        if (shape) |shape_value| {
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_new_shaped_table(ptr %ctx, i32 {d}, ptr {s})\n", .{ create_status, shape_value.id, table_value });
        } else {
            var list_capacity: u32 = 0;
            for (fields) |field| {
                if (field == .list) list_capacity += 1;
            }
            if (list_capacity != 0)
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_new_array_table(ptr %ctx, i32 {d}, ptr {s})\n", .{ create_status, list_capacity, table_value })
            else
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_new_table(ptr %ctx, ptr {s})\n", .{ create_status, table_value });
        }
        try self.check(create_status);
        for (fields, 0..) |field, index| switch (field) {
            .named => |item| {
                const value = try self.expr(item.value);
                const boxed = try self.box(value);
                const status = try self.temp("st");
                if (shape) |shape_value| {
                    const slot = shapeSlot(shape_value, item.name) orelse return error.ShapeAnalysisMismatch;
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_shape_slot(ptr %ctx, ptr {s}, i32 {d}, ptr {s})\n", .{ status, table_value, slot, boxed });
                } else {
                    const key = try self.stringRef(item.name);
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_field(ptr %ctx, ptr {s}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, table_value, key.id, key.len, boxed });
                }
                try self.check(status);
            },
            .keyed => |item| {
                const status = try self.temp("st");
                if (shape) |shape_value| {
                    const key_name = staticString(item.key) orelse return error.ShapeAnalysisMismatch;
                    const value = try self.expr(item.value);
                    const value_box = try self.box(value);
                    const slot = shapeSlot(shape_value, key_name) orelse return error.ShapeAnalysisMismatch;
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_shape_slot(ptr %ctx, ptr {s}, i32 {d}, ptr {s})\n", .{ status, table_value, slot, value_box });
                } else {
                    const key = try self.expr(item.key);
                    const value = try self.expr(item.value);
                    const key_box = try self.box(key);
                    const value_box = try self.box(value);
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_index(ptr %ctx, ptr {s}, ptr {s}, ptr {s})\n", .{ status, table_value, key_box, value_box });
                }
                try self.check(status);
            },
            .list => |item| {
                if (index + 1 == fields.len and isMultiExpr(item)) {
                    const tail = try self.multi(item);
                    const status = try self.temp("st");
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_table_append_many(ptr %ctx, ptr {s}, ptr {s}, i64 {s})\n", .{ status, table_value, tail.ptr, tail.len });
                    try self.check(status);
                    try self.freeMulti(tail);
                } else {
                    const value = try self.expr(item);
                    const boxed = try self.box(value);
                    const status = try self.temp("st");
                    try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_table_append(ptr %ctx, ptr {s}, ptr {s})\n", .{ status, table_value, boxed });
                    try self.check(status);
                }
            },
        };
        return .{ .table = .{ .ptr = table_value, .shape = shape } };
    }

    fn shapeSlot(shape: shapes.Fact, name: []const u8) ?u32 {
        for (shape.fields, 0..) |field, slot|
            if (std.mem.eql(u8, field, name)) return @intCast(slot);
        return null;
    }

    fn freeMulti(self: *FnEmitter, multi_value: MultiRef) anyerror!void {
        if (multi_value.owned)
            try print(&self.code, self.a(), "  call void @dict_lua_results_free(ptr {s}, i64 {s})\n", .{ multi_value.ptr, multi_value.len });
    }
    fn getField(self: *FnEmitter, object: ValueRef, name: []const u8) anyerror!ValueRef {
        const object_box = try self.box(object);
        const key = try self.stringRef(name);
        const out = try self.valueSlot();
        const status = try self.temp("st");
        if (object == .table) {
            if (object.table.shape) |shape| if (shapeSlot(shape, name)) |slot| {
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_get_known_shape_field(ptr %ctx, ptr {s}, i32 {d}, i32 {d}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object_box, shape.id, slot, key.id, key.len, out });
                try self.check(status);
                return .{ .boxed = out };
            };
            if (object.table.native_namespace) |namespace| if (static_fields.slotForName(namespace, name)) |slot| {
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_get_native_slot(ptr %ctx, ptr {s}, i32 {d}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object_box, slot, key.id, key.len, out });
                try self.check(status);
                return .{ .boxed = out };
            };
        }
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_get_field(ptr %ctx, ptr {s}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object_box, key.id, key.len, out });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn varargs(self: *FnEmitter) anyerror!MultiRef {
        const has = try self.temp("hasva");
        const raw_len = try self.temp("valenraw");
        const len = try self.temp("valen");
        const ptr = try self.temp("vaptr");
        const param_count = self.info.params.len;
        try print(&self.code, self.a(), "  {s} = icmp ugt i64 %args_len, {d}\n", .{ has, param_count });
        try print(&self.code, self.a(), "  {s} = sub i64 %args_len, {d}\n", .{ raw_len, param_count });
        try print(&self.code, self.a(), "  {s} = select i1 {s}, i64 {s}, i64 0\n", .{ len, has, raw_len });
        try print(&self.code, self.a(), "  {s} = getelementptr %Value, ptr %args, i64 {d}\n", .{ ptr, param_count });
        return .{ .ptr = ptr, .len = len, .owned = false };
    }
    const PreparedCall = struct {
        callee: ValueRef,
        fixed: []const u8,
        fixed_len: usize,
        tail: ?MultiRef,
    };
    const PreparedArgs = struct {
        fixed: []const u8,
        fixed_len: usize,
        tail: ?MultiRef,
    };

    fn prepareStaticArgs(self: *FnEmitter, args: []const *lua.Expr) anyerror!PreparedArgs {
        const has_tail = args.len != 0 and isMultiExpr(args[args.len - 1]);
        const fixed_args = if (has_tail) args[0 .. args.len - 1] else args;
        const fixed = try self.valueArray(fixed_args.len);
        for (fixed_args, 0..) |arg, index| {
            const value = try self.expr(arg);
            const dst = try self.arrayElem(fixed, index);
            try self.copyValue(dst, try self.box(value));
        }
        const tail = if (has_tail) try self.multi(args[args.len - 1]) else null;
        return .{ .fixed = fixed, .fixed_len = fixed_args.len, .tail = tail };
    }

    fn staticCallee(self: *FnEmitter, value: *const lua.Expr) anyerror!?StaticFunctionRef {
        return switch (value.*) {
            .name => |name| switch (try self.resolve(name.value)) {
                .local => |binding| switch (self.storage[binding]) {
                    .static_function => |function| function,
                    else => null,
                },
                else => null,
            },
            .paren => |paren| self.staticCallee(paren.expr),
            else => null,
        };
    }

    fn prepareCall(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args: []const *lua.Expr) anyerror!PreparedCall {
        var callee: ValueRef = undefined;
        var self_value: ?ValueRef = null;
        if (method) |name| {
            const object = try self.expr(callee_expr);
            self_value = object;
            callee = try self.getField(object, name);
        } else callee = try self.expr(callee_expr);

        const has_tail = args.len != 0 and isMultiExpr(args[args.len - 1]);
        const fixed_args = if (has_tail) args[0 .. args.len - 1] else args;
        const fixed_len = fixed_args.len + @intFromBool(self_value != null);
        const fixed = try self.valueArray(fixed_len);
        var at: usize = 0;
        if (self_value) |value| {
            const dst = try self.arrayElem(fixed, at);
            at += 1;
            try self.copyValue(dst, try self.box(value));
        }
        for (fixed_args) |arg| {
            const value = try self.expr(arg);
            const dst = try self.arrayElem(fixed, at);
            at += 1;
            try self.copyValue(dst, try self.box(value));
        }
        const tail = if (has_tail) try self.multi(args[args.len - 1]) else null;
        return .{ .callee = callee, .fixed = fixed, .fixed_len = fixed_len, .tail = tail };
    }

    const StaticRequire = struct { module_id: u32, requested: StringRef };

    fn staticString(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .string => |v| v.value,
            .paren => |v| staticString(v.expr),
            else => null,
        };
    }

    fn staticRequire(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args: []const *lua.Expr) anyerror!?StaticRequire {
        if (method != null or args.len != 1 or callee_expr.* != .name) return null;
        if (!std.mem.eql(u8, callee_expr.name.value, "require")) return null;
        if (!self.module.globals.stable("require")) return null;
        const require_slot = self.module.globals.get("require") orelse return null;
        switch (try self.resolve("require")) {
            .global => |slot| if (slot != require_slot) return null,
            else => return null,
        }
        const requested = staticString(args[0]) orelse return null;
        const module_id = (try self.module.facts.moduleId(self.a(), requested)) orelse return null;
        return .{ .module_id = module_id, .requested = try self.stringRef(requested) };
    }

    fn directRequireValue(self: *FnEmitter, request: StaticRequire) anyerror![]const u8 {
        const loaded = try self.valueSlot();
        const status = try self.temp("st");
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_require_module_id(ptr %ctx, i32 {d}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, request.module_id, request.requested.id, request.requested.len, loaded });
        try self.check(status);
        return loaded;
    }

    fn directRequireFixed(self: *FnEmitter, request: StaticRequire, count: usize) anyerror!?[]const u8 {
        const loaded = try self.directRequireValue(request);
        if (count == 0) return null;
        const output = try self.valueArray(count);
        const first = try self.arrayElem(output, 0);
        try self.copyValue(first, loaded);
        for (1..count) |index| {
            const dst = try self.arrayElem(output, index);
            try print(&self.code, self.a(), "  call void @dict_lua_value_nil(ptr {s})\n", .{dst});
        }
        return output;
    }

    fn directStaticFixed(self: *FnEmitter, function: StaticFunctionRef, args: []const *lua.Expr, count: usize) anyerror!?[]const u8 {
        const prepared = try self.prepareStaticArgs(args);
        const output = try self.valueArray(count);
        const entry = try self.ownFmt("@lua_f_{d}", .{function.target.id});
        if (function.captures_len == 0 and prepared.tail == null) {
            for (0..count) |index| {
                const dst = try self.arrayElem(output, index);
                try print(&self.code, self.a(), "  call void @dict_lua_value_nil(ptr {s})\n", .{dst});
            }
            const enter = try self.temp("enter");
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_enter_static_call(ptr %ctx)\n", .{enter});
            try self.check(enter);
            const result = try self.temp("directcall");
            try print(&self.code, self.a(), "  {s} = call %FunctionResult {s}(ptr %ctx, ptr null, ptr {s}, i64 {d}, ptr {s}, i64 {d})\n", .{ result, entry, prepared.fixed, prepared.fixed_len, output, count });
            try print(&self.code, self.a(), "  call void @dict_lua_leave_static_call(ptr %ctx)\n", .{});
            const raw_status = try self.temp("directst");
            const status = try self.temp("st");
            try print(&self.code, self.a(), "  {s} = extractvalue %FunctionResult {s}, 2\n  {s} = call i32 @dict_lua_function_status(ptr %ctx, i32 {s})\n", .{ raw_status, result, status, raw_status });
            try self.check(status);
            return if (count == 0) null else output;
        }
        const status = try self.temp("st");
        if (prepared.tail) |tail|
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_static_fixed_tail(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {d}, ptr {s}, i64 {s}, ptr {s}, i64 {d})\n", .{ status, entry, function.captures_ptr, function.captures_len, prepared.fixed, prepared.fixed_len, tail.ptr, tail.len, output, count })
        else
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_static_fixed(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {d}, ptr {s}, i64 {d})\n", .{ status, entry, function.captures_ptr, function.captures_len, prepared.fixed, prepared.fixed_len, output, count });
        try self.check(status);
        if (prepared.tail) |tail| try self.freeMulti(tail);
        return if (count == 0) null else output;
    }

    fn directStaticMulti(self: *FnEmitter, function: StaticFunctionRef, args: []const *lua.Expr) anyerror!MultiRef {
        const prepared = try self.prepareStaticArgs(args);
        const entry = try self.ownFmt("@lua_f_{d}", .{function.target.id});
        if (function.captures_len == 0 and prepared.tail == null) {
            const enter = try self.temp("enter");
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_enter_static_call(ptr %ctx)\n", .{enter});
            try self.check(enter);
            const result = try self.temp("directcall");
            try print(&self.code, self.a(), "  {s} = call %FunctionResult {s}(ptr %ctx, ptr null, ptr {s}, i64 {d}, ptr null, i64 0)\n", .{ result, entry, prepared.fixed, prepared.fixed_len });
            try print(&self.code, self.a(), "  call void @dict_lua_leave_static_call(ptr %ctx)\n", .{});
            const raw_status = try self.temp("directst");
            const status = try self.temp("st");
            try print(&self.code, self.a(), "  {s} = extractvalue %FunctionResult {s}, 2\n  {s} = call i32 @dict_lua_function_status(ptr %ctx, i32 {s})\n", .{ raw_status, result, status, raw_status });
            try self.check(status);
            const ptr = try self.temp("callptr");
            const len = try self.temp("calllen");
            try print(&self.code, self.a(), "  {s} = extractvalue %FunctionResult {s}, 0\n  {s} = extractvalue %FunctionResult {s}, 1\n", .{ ptr, result, len, result });
            return .{ .ptr = ptr, .len = len, .owned = true };
        }
        const result = try self.temp("call");
        if (prepared.tail) |tail|
            try print(&self.code, self.a(), "  {s} = call %CallResult @dict_lua_call_static_multi_tail(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {d}, ptr {s}, i64 {s})\n", .{ result, entry, function.captures_ptr, function.captures_len, prepared.fixed, prepared.fixed_len, tail.ptr, tail.len })
        else
            try print(&self.code, self.a(), "  {s} = call %CallResult @dict_lua_call_static_multi(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {d})\n", .{ result, entry, function.captures_ptr, function.captures_len, prepared.fixed, prepared.fixed_len });
        if (prepared.tail) |tail| try self.freeMulti(tail);
        const status = try self.temp("callst");
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 2\n", .{ status, result });
        try self.check(status);
        const ptr = try self.temp("callptr");
        const len = try self.temp("calllen");
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 0\n", .{ ptr, result });
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 1\n", .{ len, result });
        return .{ .ptr = ptr, .len = len, .owned = true };
    }

    fn callFixed(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args: []const *lua.Expr, count: usize) anyerror!?[]const u8 {
        if (try self.staticRequire(callee_expr, method, args)) |request|
            return self.directRequireFixed(request, count);
        if (method == null) if (try self.staticCallee(callee_expr)) |function|
            return self.directStaticFixed(function, args, count);
        const prepared = try self.prepareCall(callee_expr, method, args);
        const callee = try self.box(prepared.callee);
        if (count == 0) {
            const status = try self.temp("st");
            if (prepared.tail) |tail|
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_discard_tail(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {s})\n", .{ status, callee, prepared.fixed, prepared.fixed_len, tail.ptr, tail.len })
            else
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_discard(ptr %ctx, ptr {s}, ptr {s}, i64 {d})\n", .{ status, callee, prepared.fixed, prepared.fixed_len });
            try self.check(status);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return null;
        }
        const output = try self.valueArray(count);
        const status = try self.temp("st");
        if (prepared.tail) |tail|
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_fixed_tail(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {s}, ptr {s}, i64 {d})\n", .{ status, callee, prepared.fixed, prepared.fixed_len, tail.ptr, tail.len, output, count })
        else
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_fixed(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {d})\n", .{ status, callee, prepared.fixed, prepared.fixed_len, output, count });
        try self.check(status);
        if (prepared.tail) |tail| try self.freeMulti(tail);
        return output;
    }

    fn callMulti(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args: []const *lua.Expr) anyerror!MultiRef {
        if (try self.staticRequire(callee_expr, method, args)) |request|
            return .{ .ptr = try self.directRequireValue(request), .len = "1", .owned = false };
        if (method == null) if (try self.staticCallee(callee_expr)) |function|
            return self.directStaticMulti(function, args);
        const prepared = try self.prepareCall(callee_expr, method, args);
        const callee = try self.box(prepared.callee);
        const result = try self.temp("call");
        if (prepared.tail) |tail|
            try print(&self.code, self.a(), "  {s} = call %CallResult @dict_lua_call_multi_tail(ptr %ctx, ptr {s}, ptr {s}, i64 {d}, ptr {s}, i64 {s})\n", .{ result, callee, prepared.fixed, prepared.fixed_len, tail.ptr, tail.len })
        else
            try print(&self.code, self.a(), "  {s} = call %CallResult @dict_lua_call_multi(ptr %ctx, ptr {s}, ptr {s}, i64 {d})\n", .{ result, callee, prepared.fixed, prepared.fixed_len });
        if (prepared.tail) |tail| try self.freeMulti(tail);
        const status = try self.temp("callst");
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 2\n", .{ status, result });
        try self.check(status);
        const ptr = try self.temp("callptr");
        const len = try self.temp("calllen");
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 0\n", .{ ptr, result });
        try print(&self.code, self.a(), "  {s} = extractvalue %CallResult {s}, 1\n", .{ len, result });
        return .{ .ptr = ptr, .len = len, .owned = true };
    }

    fn multi(self: *FnEmitter, value: *const lua.Expr) anyerror!MultiRef {
        return switch (value.*) {
            .call => |call| try self.callMulti(call.callee, null, call.args),
            .method_call => |call| try self.callMulti(call.object, call.method, call.args),
            .vararg => try self.varargs(),
            else => blk: {
                const one = try self.expr(value);
                const boxed = try self.box(one);
                break :blk .{ .ptr = boxed, .len = "1", .owned = false };
            },
        };
    }
    fn expr(self: *FnEmitter, value: *const lua.Expr) anyerror!ValueRef {
        return switch (value.*) {
            .nil_lit => .nil,
            .bool_lit => |v| .{ .boolean = if (v.value) "true" else "false" },
            .number => |v| .{ .number = try self.numberOperand(v.raw) },
            .string => |v| .{ .string = try self.stringRef(v.value) },
            .name => |v| try self.loadResolved(try self.resolve(v.value)),
            .paren => |v| try self.expr(v.expr),
            .vararg => blk: {
                const out = try self.valueSlot();
                try print(&self.code, self.a(), "  call void @dict_lua_arg_get(ptr %args, i64 %args_len, i64 {d}, ptr {s})\n", .{ self.info.params.len, out });
                break :blk .{ .boxed = out };
            },
            .index => |v| try self.getIndex(try self.expr(v.object), v.key),
            .call => |v| blk: {
                const result = (try self.callFixed(v.callee, null, v.args, 1)) orelse unreachable;
                break :blk .{ .boxed = try self.arrayElem(result, 0) };
            },
            .method_call => |v| blk: {
                const result = (try self.callFixed(v.object, v.method, v.args, 1)) orelse unreachable;
                break :blk .{ .boxed = try self.arrayElem(result, 0) };
            },
            .function => |f| try self.closure(try self.module.functionForSpan(f.span)),
            .table => |v| try self.table(v),
            .unary => |v| try self.unary(v.op, v.expr),
            .binary => |v| try self.binary(v.op, v.lhs, v.rhs),
        };
    }
    fn discardExpr(self: *FnEmitter, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .call => |v| _ = try self.callFixed(v.callee, null, v.args, 0),
            .method_call => |v| _ = try self.callFixed(v.object, v.method, v.args, 0),
            .vararg => {},
            else => _ = try self.expr(value),
        }
    }

    fn rhsFixed(self: *FnEmitter, values_in: []const *lua.Expr, needed: usize) anyerror![]const u8 {
        const out = try self.valueArray(needed);
        if (needed == 0) {
            for (values_in) |value| try self.discardExpr(value);
            return out;
        }
        var oi: usize = 0;
        for (values_in, 0..) |value, index| {
            if (oi >= needed) {
                try self.discardExpr(value);
                continue;
            }
            const last = index + 1 == values_in.len;
            if (last and isMultiExpr(value)) {
                const remain = needed - oi;
                switch (value.*) {
                    .call => |v| {
                        const results = (try self.callFixed(v.callee, null, v.args, remain)) orelse unreachable;
                        for (0..remain) |j| {
                            const src = try self.arrayElem(results, j);
                            const dst = try self.arrayElem(out, oi + j);
                            try self.copyValue(dst, src);
                        }
                    },
                    .method_call => |v| {
                        const results = (try self.callFixed(v.object, v.method, v.args, remain)) orelse unreachable;
                        for (0..remain) |j| {
                            const src = try self.arrayElem(results, j);
                            const dst = try self.arrayElem(out, oi + j);
                            try self.copyValue(dst, src);
                        }
                    },
                    .vararg => for (0..remain) |j| {
                        const dst = try self.arrayElem(out, oi + j);
                        try print(&self.code, self.a(), "  call void @dict_lua_arg_get(ptr %args, i64 %args_len, i64 {d}, ptr {s})\n", .{ self.info.params.len + j, dst });
                    },
                    else => unreachable,
                }
                oi = needed;
                continue;
            }
            const result = try self.expr(value);
            const dst = try self.arrayElem(out, oi);
            try self.copyValue(dst, try self.box(result));
            oi += 1;
        }
        while (oi < needed) : (oi += 1) {
            const dst = try self.arrayElem(out, oi);
            try print(&self.code, self.a(), "  call void @dict_lua_value_nil(ptr {s})\n", .{dst});
        }
        return out;
    }

    fn rhsFixedRefs(self: *FnEmitter, values_in: []const *lua.Expr, needed: usize) anyerror![]ValueRef {
        const out = try self.a().alloc(ValueRef, needed);
        errdefer self.a().free(out);
        if (needed == 0) {
            for (values_in) |value| try self.discardExpr(value);
            return out;
        }
        var oi: usize = 0;
        for (values_in, 0..) |value, index| {
            if (oi >= needed) {
                try self.discardExpr(value);
                continue;
            }
            const last = index + 1 == values_in.len;
            if (last and isMultiExpr(value)) {
                const remain = needed - oi;
                switch (value.*) {
                    .call => |v| {
                        const results = (try self.callFixed(v.callee, null, v.args, remain)) orelse unreachable;
                        for (0..remain) |j| out[oi + j] = .{ .boxed = try self.arrayElem(results, j) };
                    },
                    .method_call => |v| {
                        const results = (try self.callFixed(v.object, v.method, v.args, remain)) orelse unreachable;
                        for (0..remain) |j| out[oi + j] = .{ .boxed = try self.arrayElem(results, j) };
                    },
                    .vararg => for (0..remain) |j| {
                        const dst = try self.valueSlot();
                        try print(&self.code, self.a(), "  call void @dict_lua_arg_get(ptr %args, i64 %args_len, i64 {d}, ptr {s})\n", .{ self.info.params.len + j, dst });
                        out[oi + j] = .{ .boxed = dst };
                    },
                    else => unreachable,
                }
                oi = needed;
                continue;
            }
            out[oi] = try self.expr(value);
            oi += 1;
        }
        while (oi < needed) : (oi += 1) out[oi] = .nil;
        return out;
    }
    fn prepareTarget(self: *FnEmitter, target: lua.LValue) anyerror!PreparedTarget {
        return switch (target) {
            .name => |name| .{ .name = try self.resolve(name) },
            .index => |idx| blk: {
                const object = try self.expr(idx.object);
                if (staticString(idx.key)) |name|
                    break :blk .{ .field = .{ .object = object, .key = try self.stringRef(name) } };
                break :blk .{ .index = .{ .object = object, .key = try self.expr(idx.key) } };
            },
        };
    }
    fn storeTarget(self: *FnEmitter, target: PreparedTarget, value: ValueRef) anyerror!void {
        switch (target) {
            .name => |resolved| try self.storeResolved(resolved, value),
            .field => |field| {
                const object = try self.box(field.object);
                const boxed = try self.box(value);
                const status = try self.temp("st");
                if (field.object == .table) {
                    const key_name = self.module.strings.items.items[field.key.id];
                    if (field.object.table.shape) |shape| if (shapeSlot(shape, key_name)) |slot| {
                        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_known_shape_field(ptr %ctx, ptr {s}, i32 {d}, i32 {d}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object, shape.id, slot, field.key.id, field.key.len, boxed });
                        try self.check(status);
                        return;
                    };
                    if (field.object.table.native_namespace) |namespace| if (static_fields.slotForName(namespace, key_name)) |slot| {
                        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_native_slot(ptr %ctx, ptr {s}, i32 {d}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object, slot, field.key.id, field.key.len, boxed });
                        try self.check(status);
                        return;
                    };
                }
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_field(ptr %ctx, ptr {s}, ptr @lua_s_{d}, i64 {d}, ptr {s})\n", .{ status, object, field.key.id, field.key.len, boxed });
                try self.check(status);
            },
            .index => |index| {
                const object = try self.box(index.object);
                const key = try self.box(index.key);
                const boxed = try self.box(value);
                const status = try self.temp("st");
                try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_set_index(ptr %ctx, ptr {s}, ptr {s}, ptr {s})\n", .{ status, object, key, boxed });
                try self.check(status);
            },
        }
    }

    fn scopedBlock(self: *FnEmitter, body: lua.Block) anyerror!bool {
        const mark = self.saves.items.len;
        defer self.endScope(mark);
        return self.block(body);
    }
    fn emitReturn(self: *FnEmitter, values_in: []const *lua.Expr) anyerror!void {
        if (values_in.len == 0) {
            const result = try self.temp("ret");
            try print(&self.code, self.a(), "  {s} = call %FunctionResult @dict_lua_return_values(ptr %ctx, ptr %result_ptr, i64 %result_len, ptr %args, i64 0)\n", .{result});
            try print(&self.code, self.a(), "  ret %FunctionResult {s}\n", .{result});
            return;
        }
        const prefix_count = values_in.len - 1;
        const last = values_in[values_in.len - 1];
        if (isMultiExpr(last)) {
            const prefix = try self.valueArray(prefix_count);
            for (values_in[0..prefix_count], 0..) |value, index| {
                const evaluated = try self.expr(value);
                const dst = try self.arrayElem(prefix, index);
                try self.copyValue(dst, try self.box(evaluated));
            }
            const tail = try self.multi(last);
            const result = try self.temp("ret");
            try print(&self.code, self.a(), "  {s} = call %FunctionResult @dict_lua_return_join(ptr %ctx, ptr %result_ptr, i64 %result_len, ptr {s}, i64 {d}, ptr {s}, i64 {s})\n", .{ result, prefix, prefix_count, tail.ptr, tail.len });
            try self.freeMulti(tail);
            try print(&self.code, self.a(), "  ret %FunctionResult {s}\n", .{result});
            return;
        }
        const fixed = try self.valueArray(values_in.len);
        for (values_in, 0..) |value, index| {
            const evaluated = try self.expr(value);
            const dst = try self.arrayElem(fixed, index);
            try self.copyValue(dst, try self.box(evaluated));
        }
        const result = try self.temp("ret");
        try print(&self.code, self.a(), "  {s} = call %FunctionResult @dict_lua_return_values(ptr %ctx, ptr %result_ptr, i64 %result_len, ptr {s}, i64 {d})\n", .{ result, fixed, values_in.len });
        try print(&self.code, self.a(), "  ret %FunctionResult {s}\n", .{result});
    }

    fn block(self: *FnEmitter, body: lua.Block) anyerror!bool {
        for (body) |stmt| if (try self.statement(stmt)) return true;
        return false;
    }

    fn statement(self: *FnEmitter, stmt: *const lua.Stmt) anyerror!bool {
        switch (stmt.*) {
            .empty => return false,
            .break_stmt => {
                const target = self.breaks.getLastOrNull() orelse return error.InvalidBreak;
                try print(&self.code, self.a(), "  br label %{s}\n", .{target});
                return true;
            },
            .local_assign => |s| {
                if (s.names.len == 1 and s.values.len == 1 and s.values[0].* == .function and self.binding_next < self.info.bindings.len and self.info.bindings[self.binding_next].directCallOnly()) {
                    const target = try self.module.functionForSpan(s.values[0].function.span);
                    const direct = try self.staticFunction(target);
                    const binding = try self.bindName(s.names[0]);
                    self.storage[binding] = .{ .static_function = direct };
                    return false;
                }
                const values_out = try self.rhsFixedRefs(s.values, s.names.len);
                defer self.a().free(values_out);
                for (s.names, 0..) |name, index| {
                    const binding = try self.bindName(name);
                    try self.initBinding(binding, values_out[index]);
                }
                return false;
            },
            .assign => |s| {
                const targets = try self.a().alloc(PreparedTarget, s.targets.len);
                defer self.a().free(targets);
                for (s.targets, 0..) |target, index| targets[index] = try self.prepareTarget(target);
                const values_out = try self.rhsFixedRefs(s.values, s.targets.len);
                defer self.a().free(values_out);
                for (targets, 0..) |target, index| try self.storeTarget(target, values_out[index]);
                return false;
            },
            .call => |s| {
                try self.discardExpr(s.expr);
                return false;
            },
            .do_block => |s| return try self.scopedBlock(s.body),
            .return_stmt => |s| {
                try self.emitReturn(s.values);
                return true;
            },
            .function_assign => |s| {
                const target = try self.prepareTarget(s.target);
                const closure_value = try self.expr(s.function);
                try self.storeTarget(target, closure_value);
                return false;
            },
            .local_function => |s| {
                if (self.binding_next < self.info.bindings.len and self.info.bindings[self.binding_next].directCallOnly()) {
                    const target = try self.module.functionForSpan(s.function.function.span);
                    const direct = try self.staticFunction(target);
                    const binding = try self.bindName(s.name);
                    self.storage[binding] = .{ .static_function = direct };
                    return false;
                }
                const binding = try self.bindName(s.name);
                try self.initBinding(binding, .nil);
                const closure_value = try self.expr(s.function);
                try self.storeResolved(.{ .local = binding }, closure_value);
                return false;
            },
            .if_stmt => |s| return try self.emitIf(s),
            .while_loop => |s| return try self.emitWhile(s),
            .repeat_loop => |s| return try self.emitRepeat(s),
            .numeric_for => |s| return try self.emitNumericFor(s),
            .generic_for => |s| return try self.emitGenericFor(s),
        }
    }
    fn coerceNumber(self: *FnEmitter, value: ValueRef) anyerror![]const u8 {
        if (value == .number) return value.number;
        const boxed = try self.box(value);
        const slot = try self.temp("numslot");
        try print(&self.allocas, self.a(), "  {s} = alloca double, align 8\n", .{slot});
        const status = try self.temp("st");
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_require_number(ptr %ctx, ptr {s}, ptr {s})\n", .{ status, boxed, slot });
        try self.check(status);
        const number = try self.temp("num");
        try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ number, slot });
        return number;
    }

    fn emitIf(self: *FnEmitter, s: anytype) anyerror!bool {
        const end = try self.label("if_end");
        var all_terminate = s.else_body != null;
        var end_pred = false;
        for (s.branches) |branch| {
            const then_label = try self.label("if_then");
            const next_label = try self.label("if_next");
            const condition = try self.truthy(try self.expr(branch.cond));
            try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ condition, then_label, next_label, then_label });
            const term = try self.scopedBlock(branch.body);
            all_terminate = all_terminate and term;
            if (!term) {
                try print(&self.code, self.a(), "  br label %{s}\n", .{end});
                end_pred = true;
            }
            try print(&self.code, self.a(), "{s}:\n", .{next_label});
        }
        if (s.else_body) |body| {
            const term = try self.scopedBlock(body);
            all_terminate = all_terminate and term;
            if (!term) {
                try print(&self.code, self.a(), "  br label %{s}\n", .{end});
                end_pred = true;
            }
        } else {
            try print(&self.code, self.a(), "  br label %{s}\n", .{end});
            end_pred = true;
            all_terminate = false;
        }
        if (end_pred) try print(&self.code, self.a(), "{s}:\n", .{end});
        return all_terminate;
    }

    fn emitWhile(self: *FnEmitter, s: anytype) anyerror!bool {
        const cond_label = try self.label("while_cond");
        const body_label = try self.label("while_body");
        const end_label = try self.label("while_end");
        try print(&self.code, self.a(), "  br label %{s}\n{s}:\n", .{ cond_label, cond_label });
        const condition = try self.truthy(try self.expr(s.cond));
        try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ condition, body_label, end_label, body_label });
        try self.breaks.append(self.a(), end_label);
        const term = try self.scopedBlock(s.body);
        _ = self.breaks.pop();
        if (!term) try print(&self.code, self.a(), "  br label %{s}\n", .{cond_label});
        try print(&self.code, self.a(), "{s}:\n", .{end_label});
        return false;
    }
    fn emitRepeat(self: *FnEmitter, s: anytype) anyerror!bool {
        const body_label = try self.label("repeat_body");
        const cond_label = try self.label("repeat_cond");
        const end_label = try self.label("repeat_end");
        const mark = self.saves.items.len;
        defer self.endScope(mark);
        try print(&self.code, self.a(), "  br label %{s}\n{s}:\n", .{ body_label, body_label });
        try self.breaks.append(self.a(), end_label);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) try print(&self.code, self.a(), "  br label %{s}\n", .{cond_label});
        try print(&self.code, self.a(), "{s}:\n", .{cond_label});
        const condition = try self.truthy(try self.expr(s.cond));
        try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ condition, end_label, body_label, end_label });
        return false;
    }

    fn doubleSlot(self: *FnEmitter) anyerror![]const u8 {
        const slot = try self.temp("dslot");
        try print(&self.allocas, self.a(), "  {s} = alloca double, align 8\n", .{slot});
        return slot;
    }
    fn emitNumericFor(self: *FnEmitter, s: anytype) anyerror!bool {
        const start = try self.coerceNumber(try self.expr(s.start));
        const limit = try self.coerceNumber(try self.expr(s.limit));
        const step = if (s.step) |value| try self.coerceNumber(try self.expr(value)) else "0x3FF0000000000000";
        const current_slot = try self.doubleSlot();
        const limit_slot = try self.doubleSlot();
        const step_slot = try self.doubleSlot();
        try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n", .{ start, current_slot });
        try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n", .{ limit, limit_slot });
        try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n", .{ step, step_slot });

        const mark = self.saves.items.len;
        defer self.endScope(mark);
        const binding = try self.bindName(s.name);
        try self.initBinding(binding, .{ .number = "0x0000000000000000" });
        const cond_label = try self.label("nfor_cond");
        const body_label = try self.label("nfor_body");
        const end_label = try self.label("nfor_end");
        try print(&self.code, self.a(), "  br label %{s}\n{s}:\n", .{ cond_label, cond_label });
        const current = try self.temp("current");
        const lim = try self.temp("limit");
        const stp = try self.temp("step");
        try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ current, current_slot });
        try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ lim, limit_slot });
        try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ stp, step_slot });
        const positive = try self.temp("positive");
        const positive_ok = try self.temp("posok");
        const negative_ok = try self.temp("negok");
        const keep_going = try self.temp("keep");
        try print(&self.code, self.a(), "  {s} = fcmp ogt double {s}, 0x0000000000000000\n", .{ positive, stp });
        try print(&self.code, self.a(), "  {s} = fcmp ole double {s}, {s}\n", .{ positive_ok, current, lim });
        try print(&self.code, self.a(), "  {s} = fcmp oge double {s}, {s}\n", .{ negative_ok, current, lim });
        try print(&self.code, self.a(), "  {s} = select i1 {s}, i1 {s}, i1 {s}\n", .{ keep_going, positive, positive_ok, negative_ok });
        try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ keep_going, body_label, end_label, body_label });
        try self.storeResolved(.{ .local = binding }, .{ .number = current });
        try self.breaks.append(self.a(), end_label);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) {
            const old = try self.temp("oldcurrent");
            const delta = try self.temp("delta");
            const next = try self.temp("nextcurrent");
            try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ old, current_slot });
            try print(&self.code, self.a(), "  {s} = load double, ptr {s}, align 8\n", .{ delta, step_slot });
            try print(&self.code, self.a(), "  {s} = fadd double {s}, {s}\n", .{ next, old, delta });
            try print(&self.code, self.a(), "  store double {s}, ptr {s}, align 8\n  br label %{s}\n", .{ next, current_slot, cond_label });
        }
        try print(&self.code, self.a(), "{s}:\n", .{end_label});
        return false;
    }
    fn emitGenericFor(self: *FnEmitter, s: anytype) anyerror!bool {
        const iter_values = try self.rhsFixed(s.values, 3);
        const iter = try self.arrayElem(iter_values, 0);
        const state = try self.arrayElem(iter_values, 1);
        const control = try self.arrayElem(iter_values, 2);
        const mark = self.saves.items.len;
        defer self.endScope(mark);
        const bindings = try self.a().alloc(u32, s.names.len);
        defer self.a().free(bindings);
        for (s.names, 0..) |name, index| {
            bindings[index] = try self.bindName(name);
            try self.initBinding(bindings[index], .nil);
        }
        const args = try self.valueArray(2);
        const arg0 = try self.arrayElem(args, 0);
        const arg1 = try self.arrayElem(args, 1);
        const results = try self.valueArray(s.names.len);
        const call_label = try self.label("gfor_call");
        const body_label = try self.label("gfor_body");
        const end_label = try self.label("gfor_end");
        try print(&self.code, self.a(), "  br label %{s}\n{s}:\n", .{ call_label, call_label });
        try self.copyValue(arg0, state);
        try self.copyValue(arg1, control);
        const status = try self.temp("st");
        try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_call_fixed(ptr %ctx, ptr {s}, ptr {s}, i64 2, ptr {s}, i64 {d})\n", .{ status, iter, args, results, s.names.len });
        try self.check(status);
        const first = try self.arrayElem(results, 0);
        const nil_raw = try self.temp("isnil8");
        const is_nil = try self.temp("isnil");
        try print(&self.code, self.a(), "  {s} = call i8 @dict_lua_value_is_nil(ptr {s})\n", .{ nil_raw, first });
        try print(&self.code, self.a(), "  {s} = icmp ne i8 {s}, 0\n", .{ is_nil, nil_raw });
        try print(&self.code, self.a(), "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ is_nil, end_label, body_label, body_label });
        try self.copyValue(control, first);
        for (bindings, 0..) |binding, index| {
            const src = try self.arrayElem(results, index);
            try self.storeResolved(.{ .local = binding }, .{ .boxed = src });
        }
        try self.breaks.append(self.a(), end_label);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) try print(&self.code, self.a(), "  br label %{s}\n", .{call_label});
        try print(&self.code, self.a(), "{s}:\n", .{end_label});
        return false;
    }
    fn emitInitialization(self: *FnEmitter) anyerror!void {
        for (self.info.upvalues, 0..) |_, index| {
            const status = try self.temp("st");
            try print(&self.code, self.a(), "  {s} = call i32 @dict_lua_capture_cell(ptr %ctx, ptr %captures, i32 {d}, ptr {s})\n", .{ status, index, self.upvalue_slots[index] });
            try self.check(status);
        }
        for (self.info.params, 0..) |name, index| {
            const binding = try self.bindName(name);
            const value = try self.temp("arg");
            try print(&self.code, self.a(), "  {s} = call ptr @dict_lua_arg_ptr(ptr %args, i64 %args_len, i64 {d})\n", .{ value, index });
            try self.initBinding(binding, .{ .boxed = value });
        }
    }
};

fn isMultiExpr(expr: *const lua.Expr) bool {
    return switch (expr.*) {
        .call, .method_call, .vararg => true,
        else => false,
    };
}

fn emitFunction(emitter: *ModuleEmitter, info: *const analysis.FunctionInfo) anyerror!void {
    var function = try FnEmitter.init(emitter, info);
    defer function.deinit();
    try function.emitInitialization();
    const terminated = try function.block(info.body);
    if (!terminated) try function.emitReturn(&.{});
    const name = try functionName(emitter.allocator, info.id);
    defer emitter.allocator.free(name);
    const linkage: []const u8 = if (info.direct_only) "internal " else "";
    try print(&emitter.out, emitter.allocator, "define {s}%FunctionResult {s}(ptr %ctx, ptr %captures, ptr %args, i64 %args_len, ptr %result_ptr, i64 %result_len) {{\nentry:\n", .{ linkage, name });
    try text(&emitter.out, emitter.allocator, function.allocas.items);
    try text(&emitter.out, emitter.allocator, "  br label %start\nstart:\n");
    try text(&emitter.out, emitter.allocator, function.code.items);
    if (function.error_used) {
        try text(&emitter.out, emitter.allocator, "error:\n");
        try text(&emitter.out, emitter.allocator, "  %error_result = call %FunctionResult @dict_lua_function_error()\n");
        try text(&emitter.out, emitter.allocator, "  ret %FunctionResult %error_result\n");
    }
    try text(&emitter.out, emitter.allocator, "}\n\n");
}

pub fn generate(allocator: A, globals: *const analysis.Globals, module: *const analysis.Module, facts: ProgramFacts) anyerror!Generated {
    var emitter = ModuleEmitter{ .allocator = allocator, .globals = globals, .module = module, .facts = facts };
    defer emitter.deinit();
    try emitPreamble(&emitter.out, allocator);
    for (module.functions.items) |info| try emitFunction(&emitter, info);
    try emitStrings(&emitter);
    const source = try emitter.out.toOwnedSlice(allocator);
    return .{
        .source = source,
        .root_function = module.root.id,
        .function_count = @intCast(module.functions.items.len),
    };
}
