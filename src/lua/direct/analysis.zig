const std = @import("std");
const lua = @import("../parser/root.zig");
const global_abi = @import("../abi/globals.zig");
const static_fields = @import("../abi/static_fields.zig");

pub const Globals = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    mutated: std.AutoHashMapUnmanaged(u32, void) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    global_table_escapes: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Globals {
        var self = Globals{ .allocator = allocator };
        errdefer self.deinit();
        for (global_abi.names) |name| _ = try self.ensure(name);
        return self;
    }

    pub fn deinit(self: *Globals) void {
        self.by_name.deinit(self.allocator);
        self.mutated.deinit(self.allocator);
        self.names.deinit(self.allocator);
        for (self.owned.items) |name| self.allocator.free(name);
        self.owned.deinit(self.allocator);
    }
    pub fn ensure(self: *Globals, name: []const u8) !u32 {
        if (self.by_name.get(name)) |slot| return slot;
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        const slot: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, copy);
        self.owned.append(self.allocator, copy) catch |err| {
            _ = self.names.pop();
            return err;
        };
        try self.by_name.put(self.allocator, copy, slot);
        return slot;
    }

    pub fn get(self: *const Globals, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }
    pub fn markMutated(self: *Globals, name: []const u8) !void {
        const slot = try self.ensure(name);
        try self.mutated.put(self.allocator, slot, {});
    }

    pub fn stable(self: *const Globals, name: []const u8) bool {
        if (self.global_table_escapes) return false;
        const slot = self.get(name) orelse return false;
        return !self.mutated.contains(slot);
    }

    pub fn stableSlot(self: *const Globals, slot: u32) bool {
        return !self.global_table_escapes and slot < self.names.items.len and !self.mutated.contains(slot);
    }
};

pub const UpvalueSource = union(enum) {
    local: u32,
    upvalue: u32,
};

pub const Upvalue = struct {
    name: []const u8,
    source: UpvalueSource,
    mutated: bool = false,
};
pub const StaticType = enum { unknown, nil, boolean, number, string };
pub const ProgramTableKind = enum { json_object, uri_query };
pub const ShapeDependency = struct { source: u32, target: u32 };
pub const Binding = struct {
    name: []const u8,
    captured: bool = false,
    mutated: bool = false,
    called: bool = false,
    value_used: bool = false,
    function_span: ?lua.Span = null,
    late_function_init: bool = false,
    static_type: StaticType = .unknown,
    static_table_span: ?lua.Span = null,
    static_program_table: ?ProgramTableKind = null,
    static_native_namespace: ?static_fields.Namespace = null,
    static_array_element_native_namespace: ?static_fields.Namespace = null,
    static_module: ?[]const u8 = null,
    static_builtin_require: bool = false,
    callable_field_hint: ?[]const u8 = null,
    linear_index_table: bool = false,

    pub fn directCallOnly(self: Binding) bool {
        return self.function_span != null and self.called and !self.value_used and !self.captured and !self.mutated;
    }
};

pub const FunctionInfo = struct {
    id: u32,
    parent_id: ?u32 = null,
    params: []const []const u8,
    is_vararg: bool,
    body: lua.Block,
    span: lua.Span,
    bindings: []Binding,
    upvalues: []Upvalue,
    shape_dependencies: []ShapeDependency = &.{},
    return_table_span: ?lua.Span = null,
    direct_only: bool = false,
    dead: bool = false,
};

const CallShapeObservation = struct {
    target_span: lua.Span,
    param_index: u32,
    shape_span: ?lua.Span,
};

const TableFunctionField = struct {
    table_span: lua.Span,
    field_name: []const u8,
    function_span: lua.Span,
};

const MetatableShapeObservation = struct {
    metatable_span: lua.Span,
    object_span: lua.Span,
};

pub const TableShapeWrite = struct {
    table_span: lua.Span,
    key: *const lua.Expr,
    value_span: ?lua.Span = null,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    base_id: u32,
    functions: std.ArrayList(*FunctionInfo) = .empty,
    call_shape_observations: std.ArrayList(CallShapeObservation) = .empty,
    table_function_fields: std.ArrayList(TableFunctionField) = .empty,
    metatable_shape_observations: std.ArrayList(MetatableShapeObservation) = .empty,
    table_shape_writes: std.ArrayList(TableShapeWrite) = .empty,
    root: *FunctionInfo,

    pub fn deinit(self: *Module) void {
        for (self.functions.items) |info| {
            self.allocator.free(info.bindings);
            self.allocator.free(info.upvalues);
            self.allocator.free(info.shape_dependencies);
            self.allocator.destroy(info);
        }
        self.functions.deinit(self.allocator);
        self.call_shape_observations.deinit(self.allocator);
        self.table_function_fields.deinit(self.allocator);
        self.metatable_shape_observations.deinit(self.allocator);
        self.table_shape_writes.deinit(self.allocator);
    }
};

const Capture = union(enum) { global, local: u32, upvalue: u32 };
const Save = struct { name: []const u8, previous: ?u32 };
const TypeDependency = struct { source: u32, target: u32 };
const Analyzer = struct {
    allocator: std.mem.Allocator,
    globals: *Globals,
    module: *Module,
    parent: ?*Analyzer,
    info: *FunctionInfo,
    locals: std.StringHashMapUnmanaged(u32) = .empty,
    saves: std.ArrayList(Save) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    upvalues: std.ArrayList(Upvalue) = .empty,
    upvalue_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    type_dependencies: std.ArrayList(TypeDependency) = .empty,
    shape_dependencies: std.ArrayList(ShapeDependency) = .empty,
    return_table_span: ?lua.Span = null,

    fn deinit(self: *Analyzer) void {
        self.locals.deinit(self.allocator);
        self.saves.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.upvalue_by_name.deinit(self.allocator);
        self.type_dependencies.deinit(self.allocator);
        self.shape_dependencies.deinit(self.allocator);
    }

    fn bind(self: *Analyzer, name: []const u8) !u32 {
        const id: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.allocator, .{ .name = name });
        try self.saves.append(self.allocator, .{ .name = name, .previous = self.locals.get(name) });
        try self.locals.put(self.allocator, name, id);
        return id;
    }
    fn endScope(self: *Analyzer, mark: usize) void {
        while (self.saves.items.len > mark) {
            const save = self.saves.pop().?;
            if (save.previous) |id|
                self.locals.put(self.allocator, save.name, id) catch unreachable
            else
                _ = self.locals.remove(save.name);
        }
    }

    fn ensureUpvalue(self: *Analyzer, name: []const u8, source: UpvalueSource) !u32 {
        if (self.upvalue_by_name.get(name)) |ordinal| return ordinal;
        const ordinal: u32 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.allocator, .{ .name = name, .source = source });
        try self.upvalue_by_name.put(self.allocator, name, ordinal);
        return ordinal;
    }

    fn markLocalMutated(self: *Analyzer, binding: u32) void {
        self.bindings.items[binding].mutated = true;
        self.bindings.items[binding].static_module = null;
        self.bindings.items[binding].static_builtin_require = false;
        self.bindings.items[binding].linear_index_table = false;
        self.invalidateStaticTable(binding);
        self.invalidateStaticType(binding);
    }

    fn markUpvalueMutated(self: *Analyzer, ordinal: u32) void {
        if (ordinal >= self.upvalues.items.len) return;
        const source = self.upvalues.items[ordinal].source;
        self.upvalues.items[ordinal].mutated = true;
        const parent = self.parent orelse return;
        switch (source) {
            .local => |binding| parent.markLocalMutated(binding),
            .upvalue => |parent_ordinal| parent.markUpvalueMutated(parent_ordinal),
        }
    }

    fn captureForChild(self: *Analyzer, name: []const u8) !Capture {
        if (self.locals.get(name)) |binding| {
            self.bindings.items[binding].captured = true;
            self.bindings.items[binding].linear_index_table = false;
            // Captured locals live in boxed cells. Any scalar type inferred by
            // aliases before this closure was seen must be invalidated too.
            self.invalidateStaticType(binding);
            return .{ .local = binding };
        }
        const parent = self.parent orelse return .global;
        const outer = try parent.captureForChild(name);
        return switch (outer) {
            .global => .global,
            .local => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .local = id }) },
            .upvalue => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .upvalue = id }) },
        };
    }
    fn markValueUse(self: *Analyzer, name: []const u8) !void {
        switch (try self.resolve(name)) {
            .local => |binding| {
                self.bindings.items[binding].value_used = true;
                self.bindings.items[binding].linear_index_table = false;
            },
            .upvalue, .global => {},
        }
    }

    fn indexedObjectUse(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| if (self.locals.get(name.value)) |binding| {
                self.bindings.items[binding].value_used = true;
            } else try self.expr(value),
            .paren => |paren| try self.indexedObjectUse(paren.expr),
            else => try self.expr(value),
        }
    }

    fn lengthOperandUse(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| if (self.locals.get(name.value)) |binding| {
                self.bindings.items[binding].value_used = true;
            } else try self.expr(value),
            .paren => |paren| try self.lengthOperandUse(paren.expr),
            else => try self.expr(value),
        }
    }

    fn emptyTableLiteral(value: *const lua.Expr) bool {
        return switch (value.*) {
            .table => |table| table.fields.len == 0,
            .paren => |paren| emptyTableLiteral(paren.expr),
            else => false,
        };
    }

    fn callee(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| switch (try self.resolve(name.value)) {
                .local => |binding| {
                    self.bindings.items[binding].called = true;
                    self.bindings.items[binding].linear_index_table = false;
                },
                .upvalue, .global => {},
            },
            .paren => |v| try self.callee(v.expr),
            else => try self.expr(value),
        }
    }

    fn resolve(self: *Analyzer, name: []const u8) !Capture {
        if (self.locals.get(name)) |binding| return .{ .local = binding };
        const parent = self.parent orelse {
            _ = try self.globals.ensure(name);
            return .global;
        };
        const outer = try parent.captureForChild(name);
        return switch (outer) {
            .global => blk: {
                _ = try self.globals.ensure(name);
                break :blk .global;
            },
            .local => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .local = id }) },
            .upvalue => |id| .{ .upvalue = try self.ensureUpvalue(name, .{ .upvalue = id }) },
        };
    }

    fn staticFieldName(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .index => |index| staticString(index.key),
            .paren => |paren| staticFieldName(paren.expr),
            else => null,
        };
    }

    fn staticString(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .string => |literal| literal.value,
            .paren => |paren| staticString(paren.expr),
            else => null,
        };
    }

    fn staticModuleValue(self: *Analyzer, value: *const lua.Expr) anyerror!?[]const u8 {
        return switch (value.*) {
            .call => |call| blk: {
                if (call.args.len != 1 or call.callee.* != .name or
                    !std.mem.eql(u8, call.callee.name.value, "require"))
                    break :blk null;
                switch (try self.resolve("require")) {
                    .global => {},
                    else => break :blk null,
                }
                break :blk staticString(call.args[0]);
            },
            .paren => |paren| self.staticModuleValue(paren.expr),
            .name => |name| switch (try self.resolve(name.value)) {
                .local => |binding| self.bindings.items[binding].static_module,
                else => null,
            },
            else => null,
        };
    }

    fn upvalueStaticBuiltinRequire(self: *const Analyzer, ordinal: u32) bool {
        if (ordinal >= self.upvalues.items.len) return false;
        const parent = self.parent orelse return false;
        return switch (self.upvalues.items[ordinal].source) {
            .local => |binding| binding < parent.bindings.items.len and
                parent.bindings.items[binding].static_builtin_require and
                !parent.bindings.items[binding].mutated,
            .upvalue => |parent_ordinal| parent.upvalueStaticBuiltinRequire(parent_ordinal),
        };
    }

    fn staticBuiltinRequireValue(self: *Analyzer, value: *const lua.Expr) anyerror!bool {
        return switch (value.*) {
            .name => |name| switch (try self.resolve(name.value)) {
                .global => std.mem.eql(u8, name.value, "require"),
                .local => |binding| self.bindings.items[binding].static_builtin_require and
                    !self.bindings.items[binding].mutated,
                .upvalue => |ordinal| self.upvalueStaticBuiltinRequire(ordinal),
            },
            .paren => |paren| self.staticBuiltinRequireValue(paren.expr),
            else => false,
        };
    }

    fn nativeGlobalNamespace(name: []const u8) ?static_fields.Namespace {
        if (std.mem.eql(u8, name, "table")) return .table;
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "math")) return .math;
        if (std.mem.eql(u8, name, "debug")) return .debug;
        if (std.mem.eql(u8, name, "package")) return .package;
        if (std.mem.eql(u8, name, "mw")) return .mw;
        if (std.mem.eql(u8, name, "os")) return .os;
        return null;
    }

    fn exprStaticNativeName(self: *const Analyzer, name: []const u8) ?static_fields.Namespace {
        if (self.locals.get(name)) |binding|
            return self.bindings.items[binding].static_native_namespace;
        if (self.parent) |parent| if (parent.exprStaticNativeName(name)) |namespace|
            return namespace;
        return nativeGlobalNamespace(name);
    }

    fn nativeCallReturnNamespace(
        self: *const Analyzer,
        callee_expr: *const lua.Expr,
        args: []const *lua.Expr,
    ) ?static_fields.Namespace {
        if (callee_expr.* == .name and std.mem.eql(u8, callee_expr.name.value, "require") and args.len == 1)
            if (staticString(args[0])) |requested| {
                if (std.mem.eql(u8, requested, "bit32")) return .bit32;
                if (std.mem.eql(u8, requested, "libraryUtil")) return .library_util;
            };
        return switch (callee_expr.*) {
            .index => |index| blk: {
                const owner = self.exprStaticNative(index.object) orelse break :blk null;
                const field = staticString(index.key) orelse break :blk null;
                break :blk static_fields.callReturnNamespace(owner, field);
            },
            .paren => |paren| self.nativeCallReturnNamespace(paren.expr, args),
            else => null,
        };
    }

    fn exprStaticNative(self: *const Analyzer, value: *const lua.Expr) ?static_fields.Namespace {
        return switch (value.*) {
            .name => |name| self.exprStaticNativeName(name.value),
            .paren => |paren| self.exprStaticNative(paren.expr),
            .index => |index| blk: {
                const owner = self.exprStaticNative(index.object) orelse break :blk null;
                const field = staticString(index.key) orelse break :blk null;
                break :blk static_fields.fieldNamespace(owner, field);
            },
            .call => |call| self.nativeCallReturnNamespace(call.callee, call.args),
            .method_call => |call| blk: {
                const owner = self.exprStaticNative(call.object) orelse break :blk null;
                break :blk static_fields.callReturnNamespace(owner, call.method);
            },
            else => null,
        };
    }

    fn exprStaticArrayElementNativeName(self: *const Analyzer, name: []const u8) ?static_fields.Namespace {
        if (self.locals.get(name)) |binding|
            return self.bindings.items[binding].static_array_element_native_namespace;
        return if (self.parent) |parent| parent.exprStaticArrayElementNativeName(name) else null;
    }

    fn exprStaticArrayElementNative(self: *const Analyzer, value: *const lua.Expr) ?static_fields.Namespace {
        return switch (value.*) {
            .name => |name| self.exprStaticArrayElementNativeName(name.value),
            .paren => |paren| self.exprStaticArrayElementNative(paren.expr),
            .call => |call| switch (call.callee.*) {
                .index => |index| blk: {
                    const owner = self.exprStaticNative(index.object) orelse break :blk null;
                    const field = staticString(index.key) orelse break :blk null;
                    break :blk static_fields.callReturnElementNamespace(owner, field);
                },
                .paren => |paren| self.exprStaticArrayElementNative(paren.expr),
                else => null,
            },
            .method_call => |call| blk: {
                const owner = self.exprStaticNative(call.object) orelse break :blk null;
                break :blk static_fields.callReturnElementNamespace(owner, call.method);
            },
            else => null,
        };
    }

    fn exprStaticProgramTableName(self: *const Analyzer, name: []const u8) ?ProgramTableKind {
        if (self.locals.get(name)) |binding|
            return self.bindings.items[binding].static_program_table;
        return if (self.parent) |parent| parent.exprStaticProgramTableName(name) else null;
    }

    fn exprStaticProgramTable(self: *const Analyzer, value: *const lua.Expr) ?ProgramTableKind {
        return switch (value.*) {
            .name => |name| self.exprStaticProgramTableName(name.value),
            .paren => |paren| self.exprStaticProgramTable(paren.expr),
            .call => |call| blk: {
                if (call.callee.* != .index) break :blk null;
                const owner = self.exprStaticNative(call.callee.index.object) orelse break :blk null;
                const field = staticString(call.callee.index.key) orelse break :blk null;
                if ((owner == .mw and std.mem.eql(u8, field, "loadJsonData")) or
                    (owner == .text and std.mem.eql(u8, field, "jsonDecode")))
                    break :blk .json_object;
                break :blk null;
            },
            .index => |index| blk: {
                if (self.exprStaticProgramTable(index.object)) |kind| switch (kind) {
                    .json_object => break :blk .json_object,
                    .uri_query => break :blk null,
                };
                const owner = self.exprStaticNative(index.object) orelse break :blk null;
                const field = staticString(index.key) orelse break :blk null;
                if (owner == .uri_value and std.mem.eql(u8, field, "query"))
                    break :blk .uri_query;
                break :blk null;
            },
            else => null,
        };
    }

    fn exprStaticType(self: *const Analyzer, value: *const lua.Expr) StaticType {
        return switch (value.*) {
            .nil_lit => .nil,
            .bool_lit => .boolean,
            .number => .number,
            .string => .string,
            .name => |name| if (self.locals.get(name.value)) |binding| self.bindings.items[binding].static_type else .unknown,
            .paren => |v| self.exprStaticType(v.expr),
            .unary => |v| switch (v.op) {
                .not_ => .boolean,
                .neg => if (self.exprStaticType(v.expr) == .number) .number else .unknown,
                .len => .number,
            },
            .binary => |v| switch (v.op) {
                .eq, .ne, .lt, .le, .gt, .ge => .boolean,
                .add, .sub, .mul, .div, .mod, .pow => if (self.exprStaticType(v.lhs) == .number and self.exprStaticType(v.rhs) == .number) .number else .unknown,
                .concat => blk: {
                    const lhs = self.exprStaticType(v.lhs);
                    const rhs = self.exprStaticType(v.rhs);
                    break :blk if ((lhs == .number or lhs == .string) and (rhs == .number or rhs == .string)) .string else .unknown;
                },
                // Lua logical operators return an operand, and the emitter keeps
                // their short-circuit result boxed. Keep mutable-local storage
                // conservative rather than claiming a native scalar type here.
                .and_, .or_ => .unknown,
            },
            .index, .call, .method_call, .function, .table, .vararg => .unknown,
        };
    }

    fn exprStaticTable(self: *const Analyzer, value: *const lua.Expr) ?lua.Span {
        return switch (value.*) {
            .table => |table| table.span,
            .name => |name| if (self.locals.get(name.value)) |binding|
                self.bindings.items[binding].static_table_span
            else if (self.parent) |parent| parent.exprStaticTableName(name.value) else null,
            .paren => |paren| self.exprStaticTable(paren.expr),
            .call => |call| blk: {
                const target_span = self.directLocalFunctionSpan(call.callee) orelse break :blk null;
                for (self.module.functions.items) |info|
                    if (info.span.start == target_span.start and info.span.end == target_span.end)
                        break :blk info.return_table_span;
                break :blk null;
            },
            else => null,
        };
    }

    fn exprStaticTableName(self: *const Analyzer, name: []const u8) ?lua.Span {
        if (self.locals.get(name)) |binding| return self.bindings.items[binding].static_table_span;
        return if (self.parent) |parent| parent.exprStaticTableName(name) else null;
    }

    fn directLocalFunctionSpan(self: *const Analyzer, value: *const lua.Expr) ?lua.Span {
        return switch (value.*) {
            .name => |name| if (self.locals.get(name.value)) |binding|
                self.bindings.items[binding].function_span
            else
                null,
            .paren => |paren| self.directLocalFunctionSpan(paren.expr),
            else => null,
        };
    }

    fn observeDirectCallShapes(self: *Analyzer, target_span: lua.Span, args: []const *lua.Expr) !void {
        var target: ?*const FunctionInfo = null;
        for (self.module.functions.items) |candidate| {
            if (candidate.span.start == target_span.start and candidate.span.end == target_span.end) {
                target = candidate;
                break;
            }
        }
        const info = target orelse return;
        for (info.params, 0..) |_, param_index| {
            const shape = if (param_index < args.len and
                !(param_index + 1 == args.len and isMultiExpr(args[param_index])))
                self.exprStaticTable(args[param_index])
            else
                null;
            try self.module.call_shape_observations.append(self.allocator, .{
                .target_span = target_span,
                .param_index = @intCast(param_index),
                .shape_span = shape,
            });
        }
    }

    fn staticFunctionSpan(value: *const lua.Expr) ?lua.Span {
        return switch (value.*) {
            .function => |function| function.span,
            .paren => |paren| staticFunctionSpan(paren.expr),
            else => null,
        };
    }

    fn observeTableFunctionFields(self: *Analyzer, table: anytype) !void {
        for (table.fields) |field| {
            const name: []const u8, const value: *const lua.Expr = switch (field) {
                .named => |item| .{ item.name, item.value },
                .keyed => |item| .{
                    staticString(item.key) orelse continue,
                    item.value,
                },
                .list => continue,
            };
            const function_span = staticFunctionSpan(value) orelse continue;
            try self.module.table_function_fields.append(self.allocator, .{
                .table_span = table.span,
                .field_name = name,
                .function_span = function_span,
            });
        }
    }

    fn observeMetatableShape(self: *Analyzer, callee_expr: *const lua.Expr, args: []const *lua.Expr) !void {
        if (args.len < 2) return;
        const name = switch (callee_expr.*) {
            .name => |value| value.value,
            .paren => |paren| return self.observeMetatableShape(paren.expr, args),
            else => return,
        };
        if (!std.mem.eql(u8, name, "setmetatable")) return;
        const object_span = self.exprStaticTable(args[0]) orelse return;
        const metatable_span = self.exprStaticTable(args[1]) orelse return;
        try self.module.metatable_shape_observations.append(self.allocator, .{
            .metatable_span = metatable_span,
            .object_span = object_span,
        });
    }

    fn rhsTypes(self: *const Analyzer, values: []const *lua.Expr, needed: usize) ![]StaticType {
        const out = try self.allocator.alloc(StaticType, needed);
        if (needed == 0) return out;
        for (0..needed) |index| {
            if (index >= values.len) {
                const last_is_multi = values.len != 0 and isMultiExpr(values[values.len - 1]);
                out[index] = if (last_is_multi) .unknown else .nil;
            } else if (index + 1 == values.len and isMultiExpr(values[index])) {
                out[index] = .unknown;
            } else {
                out[index] = self.exprStaticType(values[index]);
            }
        }
        return out;
    }

    fn invalidateStaticType(self: *Analyzer, binding: u32) void {
        if (self.bindings.items[binding].static_type == .unknown) return;
        self.bindings.items[binding].static_type = .unknown;
        for (self.type_dependencies.items) |dependency|
            if (dependency.source == binding) self.invalidateStaticType(dependency.target);
    }

    fn invalidateStaticTable(self: *Analyzer, binding: u32) void {
        if (self.bindings.items[binding].static_table_span == null) return;
        self.bindings.items[binding].static_table_span = null;
        for (self.shape_dependencies.items) |dependency|
            if (dependency.source == binding) self.invalidateStaticTable(dependency.target);
    }

    fn addShapeDependency(self: *Analyzer, source: u32, target: u32) !void {
        if (source == target) return;
        for (self.shape_dependencies.items) |dependency|
            if (dependency.source == source and dependency.target == target) return;
        try self.shape_dependencies.append(self.allocator, .{ .source = source, .target = target });
    }

    fn collectShapeSource(self: *const Analyzer, value: *const lua.Expr) ?u32 {
        return switch (value.*) {
            .name => |name| self.locals.get(name.value),
            .paren => |paren| self.collectShapeSource(paren.expr),
            else => null,
        };
    }

    fn addTypeDependency(self: *Analyzer, source: u32, target: u32) !void {
        if (source == target) return;
        for (self.type_dependencies.items) |dependency|
            if (dependency.source == source and dependency.target == target) return;
        try self.type_dependencies.append(self.allocator, .{ .source = source, .target = target });
    }

    fn collectTypeSources(self: *const Analyzer, value: *const lua.Expr, out: *std.ArrayList(u32)) !void {
        switch (value.*) {
            .name => |name| if (self.locals.get(name.value)) |binding| {
                for (out.items) |existing| if (existing == binding) return;
                try out.append(self.allocator, binding);
            },
            .paren => |v| try self.collectTypeSources(v.expr, out),
            .unary => |v| if (v.op == .neg) try self.collectTypeSources(v.expr, out),
            .binary => |v| switch (v.op) {
                .add, .sub, .mul, .div, .mod, .pow => {
                    try self.collectTypeSources(v.lhs, out);
                    try self.collectTypeSources(v.rhs, out);
                },
                else => {},
            },
            else => {},
        }
    }

    fn addTypeDependencies(self: *Analyzer, target: u32, value: *const lua.Expr) !void {
        var sources: std.ArrayList(u32) = .empty;
        defer sources.deinit(self.allocator);
        try self.collectTypeSources(value, &sources);
        for (sources.items) |source| try self.addTypeDependency(source, target);
    }

    fn mergeWriteType(self: *Analyzer, target: lua.LValue, incoming: StaticType) void {
        if (target != .name) return;
        const binding = self.locals.get(target.name) orelse return;
        if (self.bindings.items[binding].static_type != incoming) self.invalidateStaticType(binding);
    }

    fn mergeWriteShape(self: *Analyzer, target: lua.LValue, incoming: ?lua.Span) void {
        if (target != .name) return;
        const binding = self.locals.get(target.name) orelse return;
        const current = self.bindings.items[binding].static_table_span;
        if (current == null or incoming == null or
            current.?.start != incoming.?.start or current.?.end != incoming.?.end)
            self.invalidateStaticTable(binding);
    }

    fn analyzeWriteTarget(self: *Analyzer, target: lua.LValue) anyerror!void {
        switch (target) {
            .name => |name| switch (try self.resolve(name)) {
                .local => |binding| {
                    self.bindings.items[binding].mutated = true;
                    self.bindings.items[binding].static_module = null;
                },
                .upvalue => |ordinal| self.markUpvalueMutated(ordinal),
                .global => try self.globals.markMutated(name),
            },
            .index => |idx| {
                try self.indexedObjectUse(idx.object);
                try self.expr(idx.key);
            },
        }
    }

    fn expr(self: *Analyzer, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .name => |name| {
                if (std.mem.eql(u8, name.value, "_G")) self.globals.global_table_escapes = true;
                try self.markValueUse(name.value);
            },
            .paren => |v| try self.expr(v.expr),
            .index => |v| {
                try self.indexedObjectUse(v.object);
                try self.expr(v.key);
            },
            .call => |v| {
                try self.observeMetatableShape(v.callee, v.args);
                try self.callee(v.callee);
                if (self.directLocalFunctionSpan(v.callee)) |target_span|
                    try self.observeDirectCallShapes(target_span, v.args);
                for (v.args) |arg| try self.expr(arg);
            },
            .method_call => |v| {
                try self.expr(v.object);
                for (v.args) |arg| try self.expr(arg);
            },
            .function => |f| _ = try analyzeFunction(self.allocator, self.globals, self.module, self, f.params, f.is_vararg, f.body, f.span),
            .table => |v| {
                try self.observeTableFunctionFields(v);
                for (v.fields) |field| switch (field) {
                    .list => |item| try self.expr(item),
                    .named => |item| try self.expr(item.value),
                    .keyed => |item| {
                        try self.expr(item.key);
                        try self.expr(item.value);
                    },
                };
            },
            .unary => |v| if (v.op == .len)
                try self.lengthOperandUse(v.expr)
            else
                try self.expr(v.expr),
            .binary => |v| {
                try self.expr(v.lhs);
                try self.expr(v.rhs);
            },
            .nil_lit, .bool_lit, .number, .string, .vararg => {},
        }
    }

    fn scopedBlock(self: *Analyzer, body: lua.Block) anyerror!void {
        const mark = self.saves.items.len;
        defer self.endScope(mark);
        try self.block(body);
    }

    fn block(self: *Analyzer, body: lua.Block) anyerror!void {
        for (body) |stmt| try self.statement(stmt);
    }

    fn statement(self: *Analyzer, stmt: *const lua.Stmt) anyerror!void {
        switch (stmt.*) {
            .empty, .break_stmt => {},
            .local_assign => |s| {
                for (s.values) |value| try self.expr(value);
                const static_module = if (s.names.len == 1 and s.values.len == 1)
                    try self.staticModuleValue(s.values[0])
                else
                    null;
                const static_builtin_require = if (s.names.len == 1 and s.values.len == 1)
                    try self.staticBuiltinRequireValue(s.values[0])
                else
                    false;
                const types = try self.rhsTypes(s.values, s.names.len);
                defer self.allocator.free(types);
                const sources = try self.allocator.alloc(std.ArrayList(u32), s.names.len);
                defer self.allocator.free(sources);
                for (sources) |*items| items.* = .empty;
                defer for (sources) |*items| items.deinit(self.allocator);
                for (s.names, 0..) |_, index| if (index < s.values.len and !(index + 1 == s.values.len and isMultiExpr(s.values[index])))
                    try self.collectTypeSources(s.values[index], &sources[index]);
                for (s.names, types, 0..) |name, static_type, index| {
                    const binding = try self.bind(name);
                    self.bindings.items[binding].static_type = static_type;
                    if (index < s.values.len) {
                        self.bindings.items[binding].linear_index_table =
                            emptyTableLiteral(s.values[index]);
                        self.bindings.items[binding].static_table_span = self.exprStaticTable(s.values[index]);
                        self.bindings.items[binding].static_program_table = self.exprStaticProgramTable(s.values[index]);
                        self.bindings.items[binding].static_native_namespace = self.exprStaticNative(s.values[index]);
                        self.bindings.items[binding].static_array_element_native_namespace =
                            self.exprStaticArrayElementNative(s.values[index]);
                        if (self.collectShapeSource(s.values[index])) |source|
                            try self.addShapeDependency(source, binding);
                    }
                    if (index == 0) self.bindings.items[binding].static_module = static_module;
                    if (index == 0) self.bindings.items[binding].static_builtin_require = static_builtin_require;
                    if (s.values.len == s.names.len)
                        self.bindings.items[binding].callable_field_hint = staticFieldName(s.values[index]);
                    for (sources[index].items) |source| try self.addTypeDependency(source, binding);
                    if (s.values.len == s.names.len and s.values[index].* == .function)
                        self.bindings.items[binding].function_span = s.values[index].function.span;
                }
            },
            .assign => |s| {
                for (s.targets) |target| try self.analyzeWriteTarget(target);
                for (s.values) |value| try self.expr(value);
                const types = try self.rhsTypes(s.values, s.targets.len);
                defer self.allocator.free(types);
                for (s.targets, types, 0..) |target, static_type, index| {
                    if (target == .index and index < s.values.len and
                        !(index + 1 == s.values.len and isMultiExpr(s.values[index])))
                    {
                        if (self.exprStaticTable(target.index.object)) |table_span|
                            try self.module.table_shape_writes.append(self.allocator, .{
                                .table_span = table_span,
                                .key = target.index.key,
                                .value_span = self.exprStaticTable(s.values[index]),
                            });
                    }
                    self.mergeWriteType(target, static_type);
                    if (target == .name and index < s.values.len) {
                        const binding = self.locals.get(target.name) orelse continue;
                        self.bindings.items[binding].static_program_table =
                            self.exprStaticProgramTable(s.values[index]);
                        if (self.exprStaticNative(s.values[index])) |namespace|
                            self.bindings.items[binding].static_native_namespace = namespace;
                        if (self.exprStaticArrayElementNative(s.values[index])) |namespace|
                            self.bindings.items[binding].static_array_element_native_namespace = namespace;
                        const incoming_shape = self.exprStaticTable(s.values[index]);
                        self.mergeWriteShape(target, incoming_shape);
                        if (incoming_shape != null) if (self.collectShapeSource(s.values[index])) |source|
                            try self.addShapeDependency(source, binding);
                        if (self.bindings.items[binding].static_type != .unknown)
                            try self.addTypeDependencies(binding, s.values[index]);
                    }
                }
            },
            .call => |s| try self.expr(s.expr),
            .do_block => |s| try self.scopedBlock(s.body),
            .while_loop => |s| {
                try self.expr(s.cond);
                try self.scopedBlock(s.body);
            },
            .repeat_loop => |s| {
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                try self.block(s.body);
                try self.expr(s.cond);
            },
            .if_stmt => |s| {
                for (s.branches) |branch| {
                    try self.expr(branch.cond);
                    try self.scopedBlock(branch.body);
                }
                if (s.else_body) |body| try self.scopedBlock(body);
            },
            .numeric_for => |s| {
                try self.expr(s.start);
                try self.expr(s.limit);
                if (s.step) |step| try self.expr(step);
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                const binding = try self.bind(s.name);
                self.bindings.items[binding].mutated = true;
                self.bindings.items[binding].static_type = .number;
                try self.block(s.body);
            },
            .generic_for => |s| {
                for (s.values) |value| try self.expr(value);
                const mark = self.saves.items.len;
                defer self.endScope(mark);
                for (s.names) |name| {
                    const binding = try self.bind(name);
                    self.bindings.items[binding].mutated = true;
                }
                try self.block(s.body);
            },
            .function_assign => |s| {
                if (s.target == .index) {
                    if (self.exprStaticTable(s.target.index.object)) |table_span|
                        try self.module.table_shape_writes.append(self.allocator, .{
                            .table_span = table_span,
                            .key = s.target.index.key,
                            .value_span = null,
                        });
                }
                try self.analyzeWriteTarget(s.target);
                self.mergeWriteType(s.target, .unknown);
                try self.expr(s.function);
            },
            .local_function => |s| {
                const binding = try self.bind(s.name);
                self.bindings.items[binding].function_span = s.function.function.span;
                self.bindings.items[binding].late_function_init = true;
                try self.expr(s.function);
            },
            .return_stmt => |s| {
                if (self.return_table_span == null and s.values.len != 0 and !isMultiExpr(s.values[0]))
                    self.return_table_span = self.exprStaticTable(s.values[0]);
                for (s.values) |value| try self.expr(value);
            },
        }
    }
};

fn analyzeFunction(
    allocator: std.mem.Allocator,
    globals: *Globals,
    module: *Module,
    parent: ?*Analyzer,
    params: []const []const u8,
    is_vararg: bool,
    body: lua.Block,
    span: lua.Span,
) anyerror!*FunctionInfo {
    const info = try allocator.create(FunctionInfo);
    errdefer allocator.destroy(info);
    const id: u32 = module.base_id + @as(u32, @intCast(module.functions.items.len));
    info.* = .{
        .id = id,
        .parent_id = if (parent) |owner| owner.info.id else null,
        .params = params,
        .is_vararg = is_vararg,
        .body = body,
        .span = span,
        .bindings = &.{},
        .upvalues = &.{},
        .shape_dependencies = &.{},
    };
    try module.functions.append(allocator, info);
    var analyzer = Analyzer{
        .allocator = allocator,
        .globals = globals,
        .module = module,
        .parent = parent,
        .info = info,
    };
    defer analyzer.deinit();
    for (params) |name| _ = try analyzer.bind(name);
    try analyzer.block(body);
    for (analyzer.bindings.items) |binding| if (binding.function_span) |target_span| {
        for (module.functions.items) |target| {
            if (target.span.start != target_span.start or target.span.end != target_span.end) continue;
            if (binding.directCallOnly()) target.direct_only = true;
            break;
        }
    };
    info.bindings = try analyzer.bindings.toOwnedSlice(allocator);
    info.upvalues = try analyzer.upvalues.toOwnedSlice(allocator);
    info.shape_dependencies = try analyzer.shape_dependencies.toOwnedSlice(allocator);
    info.return_table_span = analyzer.return_table_span;
    return info;
}

fn spansEqual(lhs: lua.Span, rhs: lua.Span) bool {
    return lhs.start == rhs.start and lhs.end == rhs.end;
}

fn applyDirectParameterShapes(module: *Module) void {
    for (module.functions.items) |info| {
        if (!info.direct_only or info.dead) continue;
        for (info.params, 0..) |_, param_index| {
            var observed = false;
            var valid = true;
            var chosen: ?lua.Span = null;
            for (module.call_shape_observations.items) |observation| {
                if (!spansEqual(observation.target_span, info.span) or
                    observation.param_index != param_index)
                    continue;
                observed = true;
                const shape = observation.shape_span orelse {
                    valid = false;
                    break;
                };
                if (chosen) |existing| {
                    if (!spansEqual(existing, shape)) {
                        valid = false;
                        break;
                    }
                } else {
                    chosen = shape;
                }
            }
            if (observed and valid and chosen != null and param_index < info.bindings.len)
                info.bindings[param_index].static_table_span = chosen;
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (info.shape_dependencies) |dependency| {
                if (dependency.source >= info.bindings.len or dependency.target >= info.bindings.len)
                    continue;
                const source = info.bindings[dependency.source].static_table_span orelse continue;
                const target = &info.bindings[dependency.target];
                if (target.mutated or target.static_table_span != null) continue;
                target.static_table_span = source;
                changed = true;
            }
        }
    }
}

fn binaryMetamethod(name: []const u8) bool {
    inline for (.{
        "__add",    "__sub", "__mul", "__div", "__mod", "__pow",
        "__concat", "__eq",  "__lt",  "__le",
    }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn applyMetatableParameterShapes(module: *Module) void {
    for (module.metatable_shape_observations.items) |observation| {
        for (module.table_function_fields.items) |field| {
            if (!spansEqual(field.table_span, observation.metatable_span)) continue;
            var target: ?*FunctionInfo = null;
            for (module.functions.items) |info| {
                if (spansEqual(info.span, field.function_span)) {
                    target = info;
                    break;
                }
            }
            const info = target orelse continue;
            if (info.bindings.len != 0 and info.bindings[0].static_table_span == null)
                info.bindings[0].static_table_span = observation.object_span;
            if (binaryMetamethod(field.field_name) and
                info.bindings.len > 1 and
                info.bindings[1].static_table_span == null)
                info.bindings[1].static_table_span = observation.object_span;
        }
    }
}

const FunctionOrigin = struct {
    owner_index: usize,
    binding: u32,
};

fn functionIndex(module: *const Module, id: u32) ?usize {
    if (id < module.base_id) return null;
    const index: usize = @intCast(id - module.base_id);
    return if (index < module.functions.items.len) index else null;
}

fn upvalueOrigin(module: *const Module, function_index: usize, ordinal: u32) ?FunctionOrigin {
    var current_index = function_index;
    var current_ordinal = ordinal;
    while (true) {
        const current = module.functions.items[current_index];
        if (current_ordinal >= current.upvalues.len) return null;
        const parent_index = functionIndex(module, current.parent_id orelse return null) orelse return null;
        switch (current.upvalues[current_ordinal].source) {
            .local => |binding| return .{ .owner_index = parent_index, .binding = binding },
            .upvalue => |parent_ordinal| {
                current_index = parent_index;
                current_ordinal = parent_ordinal;
            },
        }
    }
}

fn addFunctionEdge(adjacency: []std.ArrayList(u32), allocator: std.mem.Allocator, from: usize, to: usize) !void {
    for (adjacency[from].items) |existing| if (existing == to) return;
    try adjacency[from].append(allocator, @intCast(to));
}

fn computeFunctionLiveness(allocator: std.mem.Allocator, module: *Module) !void {
    if (module.functions.items.len == 0) return;

    var by_span: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer by_span.deinit(allocator);
    for (module.functions.items, 0..) |info, index|
        try by_span.put(allocator, info.span.start, @intCast(index));

    const bound = try allocator.alloc(bool, module.functions.items.len);
    defer allocator.free(bound);
    @memset(bound, false);

    const adjacency = try allocator.alloc(std.ArrayList(u32), module.functions.items.len);
    defer allocator.free(adjacency);
    for (adjacency) |*edges| edges.* = .empty;
    defer for (adjacency) |*edges| edges.deinit(allocator);

    for (module.functions.items, 0..) |owner, owner_index| {
        for (owner.bindings) |binding| if (binding.function_span) |span| {
            const target_index_u32 = by_span.get(span.start) orelse continue;
            const target_index: usize = @intCast(target_index_u32);
            const target = module.functions.items[target_index];
            if (target.span.end != span.end or target.parent_id != owner.id) continue;
            bound[target_index] = true;
            if (binding.called or binding.value_used or binding.mutated)
                try addFunctionEdge(adjacency, allocator, owner_index, target_index);
        };
    }

    for (module.functions.items[1..], 1..) |info, index| {
        if (bound[index]) continue;
        const parent_index = functionIndex(module, info.parent_id orelse continue) orelse continue;
        try addFunctionEdge(adjacency, allocator, parent_index, index);
    }

    for (module.functions.items, 0..) |info, source_index| {
        for (info.upvalues, 0..) |_, ordinal| {
            const origin = upvalueOrigin(module, source_index, @intCast(ordinal)) orelse continue;
            const owner = module.functions.items[origin.owner_index];
            if (origin.binding >= owner.bindings.len) return error.FunctionAnalysisMismatch;
            const span = owner.bindings[origin.binding].function_span orelse continue;
            const target_index_u32 = by_span.get(span.start) orelse continue;
            const target_index: usize = @intCast(target_index_u32);
            const target = module.functions.items[target_index];
            if (target.span.end != span.end or target.parent_id != owner.id) continue;
            try addFunctionEdge(adjacency, allocator, source_index, target_index);
        }
    }

    const live = try allocator.alloc(bool, module.functions.items.len);
    defer allocator.free(live);
    @memset(live, false);
    const queue = try allocator.alloc(u32, module.functions.items.len);
    defer allocator.free(queue);
    live[0] = true;
    queue[0] = 0;
    var read_at: usize = 0;
    var write_at: usize = 1;
    while (read_at < write_at) : (read_at += 1) {
        const source: usize = @intCast(queue[read_at]);
        for (adjacency[source].items) |target_u32| {
            const target: usize = @intCast(target_u32);
            if (live[target]) continue;
            live[target] = true;
            queue[write_at] = target_u32;
            write_at += 1;
        }
    }
    for (module.functions.items, live) |info, is_live| info.dead = !is_live;
}

pub fn analyze(
    allocator: std.mem.Allocator,
    globals: *Globals,
    chunk: *const lua.Chunk,
    function_base: u32,
) !Module {
    var module = Module{ .allocator = allocator, .root = undefined, .base_id = function_base };
    errdefer module.deinit();
    const synthetic_span = lua.Span{ .start = 0, .end = @intCast(chunk.source.len) };
    module.root = try analyzeFunction(allocator, globals, &module, null, &.{}, true, chunk.body, synthetic_span);
    try computeFunctionLiveness(allocator, &module);
    applyMetatableParameterShapes(&module);
    applyDirectParameterShapes(&module);
    return module;
}

test "analysis marks unused local functions and descendants dead" {
    const source =
        \\local function dead()
        \\  local function child() return 1 end
        \\  return child
        \\end
        \\local function live() return 2 end
        \\return live
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 20);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 4), module.functions.items.len);
    try std.testing.expect(!module.functions.items[0].dead);
    try std.testing.expect(module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
    try std.testing.expectEqual(@as(?u32, 20), module.functions.items[1].parent_id);
    try std.testing.expectEqual(@as(?u32, 21), module.functions.items[2].parent_id);
}

test "analysis prunes unrooted recursive functions but keeps called recursion" {
    const source =
        \\local function called() return 1 end
        \\local function dead_recursive() return dead_recursive() end
        \\local function live_recursive(n)
        \\  if n == 0 then return 0 end
        \\  return live_recursive(n - 1)
        \\end
        \\called()
        \\return live_recursive(2)
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expect(!module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[1].direct_only);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
}

test "analysis roots function values through live captured dependencies only" {
    const source =
        \\local hidden = function() return 7 end
        \\local function dead_wrapper() return hidden end
        \\local kept = function() return 9 end
        \\local function live_wrapper() return kept() end
        \\return live_wrapper
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 5), module.functions.items.len);
    try std.testing.expect(module.functions.items[1].dead);
    try std.testing.expect(module.functions.items[2].dead);
    try std.testing.expect(!module.functions.items[3].dead);
    try std.testing.expect(!module.functions.items[4].dead);
}

test "analysis propagates captured upvalue mutation through descendants" {
    const source =
        \\local data = "a"
        \\local function outer()
        \\  local function inner() data = "b" end
        \\  return inner
        \\end
        \\return outer
    ;
    var chunk = try @import("../parser/root.zig").parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 3), module.functions.items.len);
    const outer = module.functions.items[1];
    const inner = module.functions.items[2];
    try std.testing.expectEqual(@as(usize, 1), outer.upvalues.len);
    try std.testing.expectEqual(@as(usize, 1), inner.upvalues.len);
    try std.testing.expect(outer.upvalues[0].mutated);
    try std.testing.expect(inner.upvalues[0].mutated);
}

fn isMultiExpr(value: *const lua.Expr) bool {
    return switch (value.*) {
        .call, .method_call, .vararg => true,
        else => false,
    };
}
