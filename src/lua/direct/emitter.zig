const std = @import("std");
const lua = @import("../parser/root.zig");
const analysis = @import("analysis.zig");
const numbers = @import("numbers.zig");
const shapes = @import("shapes.zig");
const static_fields = @import("../abi/static_fields.zig");
const global_abi = @import("../abi/globals.zig");
const llvm = @import("llvm.zig");
const static_encode = @import("static_literal_encode.zig");

const A = std.mem.Allocator;
const V = llvm.ValueRef;
const T = llvm.TypeRef;
const BB = llvm.BasicBlockRef;
const value_align = 8;
const static_literal_blob_threshold: usize = 128;

pub const ModuleIdMap = std.StringHashMapUnmanaged(u32);
pub const DirectExport = struct {
    name: []const u8,
    function_id: u32,
    capture_count: u32 = 0,
};
pub const ModuleFact = struct {
    root_pure: bool = false,
    eager_prepared: bool = false,
    canonical_name: []const u8 = "",
    exports: []const DirectExport = &.{},
};
pub const ProgramFacts = struct {
    module_ids: ?*const ModuleIdMap = null,
    module_facts: ?[]const ModuleFact = null,
    table_shapes: ?*const shapes.ModuleFacts = null,
    synth_root: bool = false,
    current_module_id: u32 = 0,

    pub fn moduleId(self: ProgramFacts, a: A, raw: []const u8) anyerror!?u32 {
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

    pub fn exportFunction(self: ProgramFacts, module_id: u32, name: []const u8) ?DirectExport {
        const facts = self.module_facts orelse return null;
        if (module_id >= facts.len) return null;
        for (facts[module_id].exports) |entry|
            if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }

    pub fn moduleRootPure(self: ProgramFacts, module_id: u32) bool {
        const facts = self.module_facts orelse return false;
        return module_id < facts.len and facts[module_id].root_pure;
    }

    pub fn canDeferRequire(self: ProgramFacts, module_id: u32, raw: []const u8) bool {
        const facts = self.module_facts orelse return false;
        if (module_id >= facts.len) return false;
        const fact = facts[module_id];
        return fact.eager_prepared and std.mem.eql(u8, raw, fact.canonical_name);
    }

    pub fn moduleEagerPrepared(self: ProgramFacts, module_id: u32) bool {
        const facts = self.module_facts orelse return false;
        return module_id < facts.len and facts[module_id].eager_prepared;
    }
};

const StringRef = struct {
    ptr: V,
    bytes: []const u8,
    len: usize,
};

const TableRef = struct {
    ptr: V,
    shape: ?shapes.Fact = null,
    native_namespace: ?static_fields.Namespace = null,
};

const StaticFunctionRef = struct {
    function_id: u32,
    module_id: u32,
    captures_ptr: V,
    captures_len: usize,
    direct_captures: ?V = null,
    pristine_guard: ?V = null,
    guard_callable: ?V = null,
};

const StaticModuleRef = struct {
    module_id: u32,
    value: V,
    pristine_ptr: ?V = null,
};

const ValueRef = union(enum) {
    nil,
    boolean: V,
    number: V,
    string: StringRef,
    table: TableRef,
    boxed: V,
};

const MultiRef = struct {
    ptr: V,
    len: V,
    owned: bool,
};

const StringPool = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    items: std.ArrayList(StringRef) = .empty,

    fn deinit(self: *StringPool, a: A) void {
        self.map.deinit(a);
        self.items.deinit(a);
    }
};

const LocalStorage = union(enum) {
    uninitialized,
    direct: ValueRef,
    static_function: StaticFunctionRef,
    static_module: StaticModuleRef,
    number: V,
    boolean: V,
    value: V,
    cell: V,
};

pub const Generated = struct {
    module: llvm.Module,
    root_function: u32,
    function_count: u32,

    pub fn deinit(self: *Generated) void {
        self.module.deinit();
    }

    pub fn writeBitcode(self: *const Generated, allocator: A, path: []const u8) anyerror!void {
        if (std.debug.runtime_safety) try self.module.verify(allocator);
        try self.module.writeBitcode(allocator, path);
    }

    pub fn toText(self: *const Generated, allocator: A) anyerror![]u8 {
        return self.module.toText(allocator);
    }
};

const Runtime = struct {
    value_nil: V,
    value_bool: V,
    value_number: V,
    value_string: V,
    value_copy: V,
    value_truthy: V,
    value_is_function_id: V,
    value_function_captures: V,
    value_is_nil: V,
    require_number: V,
    observe_package: V,
    defer_require_module_id: V,
    defer_require_module_ref: V,
    module_value_sentinel: V,
    arg_ptr: V,
    arg_get: V,
    global_ptr: V,
    global_get: V,
    global_set: V,
    require_module_id: V,
    new_table: V,
    new_array_table: V,
    new_shaped_table: V,
    table_append: V,
    table_append_many: V,
    decode_static_literal: V,
    get_index: V,
    set_index: V,
    get_field: V,
    set_field: V,
    set_shape_slot: V,
    get_known_shape_field: V,
    set_known_shape_field: V,
    get_native_slot: V,
    set_native_slot: V,
    len_number: V,
    neg: V,
    binary: V,
    compare_bool: V,
    concat: V,
    cell_new: V,
    cell_get: V,
    cell_set: V,
    capture_cell: V,
    make_function: V,
    call_fixed: V,
    call_fixed_tail: V,
    call_static_fixed: V,
    call_static_fixed_tail: V,
    enter_local_static_call: V,
    leave_local_static_call: V,
    enter_static_call: V,
    leave_static_call: V,
    function_status: V,
    call_discard: V,
    call_discard_tail: V,
    call_multi: V,
    call_multi_tail: V,
    call_static_multi: V,
    call_static_multi_tail: V,
    results_free: V,
    return_values: V,
    return_join: V,
    function_error: V,
    floor: V,
    pow: V,

    fn init(m: *const llvm.Module) anyerror!Runtime {
        const ty = m.types;
        return .{
            .value_nil = try declare(m, "dict_lua_value_nil", ty.void, &.{ty.ptr}),
            .value_bool = try declare(m, "dict_lua_value_bool", ty.void, &.{ ty.ptr, ty.i8 }),
            .value_number = try declare(m, "dict_lua_value_number", ty.void, &.{ ty.ptr, ty.double }),
            .value_string = try declare(m, "dict_lua_value_string", ty.void, &.{ ty.ptr, ty.ptr, ty.i64 }),
            .value_copy = try declare(m, "dict_lua_value_copy", ty.void, &.{ ty.ptr, ty.ptr }),
            .value_truthy = try declare(m, "dict_lua_value_truthy", ty.i8, &.{ty.ptr}),
            .value_is_function_id = try declare(m, "dict_lua_value_is_function_id", ty.i8, &.{ ty.ptr, ty.i32 }),
            .value_function_captures = try declare(m, "dict_lua_value_function_captures", ty.ptr, &.{ ty.ptr, ty.i32 }),
            .value_is_nil = try declare(m, "dict_lua_value_is_nil", ty.i8, &.{ty.ptr}),
            .require_number = try declare(m, "dict_lua_require_number", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr }),
            .observe_package = try declare(m, "dict_lua_observe_package", ty.i32, &.{ty.ptr}),
            .defer_require_module_id = try declare(m, "dict_lua_defer_require_module_id", ty.i8, &.{ ty.ptr, ty.i32, ty.ptr }),
            .defer_require_module_ref = try declare(m, "dict_lua_defer_require_module_ref", ty.ptr, &.{ ty.ptr, ty.i32, ty.ptr }),
            .module_value_sentinel = try declare(m, "dict_lua_module_value_sentinel", ty.ptr, &.{ ty.ptr, ty.i32, ty.ptr }),
            .arg_ptr = try declare(m, "dict_lua_arg_ptr", ty.ptr, &.{ ty.ptr, ty.i64, ty.i64 }),
            .arg_get = try declare(m, "dict_lua_arg_get", ty.void, &.{ ty.ptr, ty.i64, ty.i64, ty.ptr }),
            .global_ptr = try declare(m, "dict_lua_global_ptr", ty.ptr, &.{ ty.ptr, ty.i32 }),
            .global_get = try declare(m, "dict_lua_global_get", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr }),
            .global_set = try declare(m, "dict_lua_global_set", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr }),
            .require_module_id = try declare(m, "dict_lua_require_module_id", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr, ty.i64, ty.ptr }),
            .new_table = try declare(m, "dict_lua_new_table", ty.i32, &.{ ty.ptr, ty.ptr }),
            .new_array_table = try declare(m, "dict_lua_new_array_table", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr }),
            .new_shaped_table = try declare(m, "dict_lua_new_shaped_table", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr }),
            .table_append = try declare(m, "dict_lua_table_append", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr }),
            .table_append_many = try declare(m, "dict_lua_table_append_many", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64 }),
            .decode_static_literal = try declare(m, "dict_lua_decode_static_literal", ty.i32, &.{ ty.ptr, ty.ptr, ty.i64, ty.ptr }),
            .get_index = try declare(m, "dict_lua_get_index", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.ptr }),
            .set_index = try declare(m, "dict_lua_set_index", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.ptr }),
            .get_field = try declare(m, "dict_lua_get_field", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr }),
            .set_field = try declare(m, "dict_lua_set_field", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr }),
            .set_shape_slot = try declare(m, "dict_lua_set_shape_slot", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.ptr }),
            .get_known_shape_field = try declare(m, "dict_lua_get_known_shape_field", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.i32, ty.ptr, ty.i64, ty.ptr }),
            .set_known_shape_field = try declare(m, "dict_lua_set_known_shape_field", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.i32, ty.ptr, ty.i64, ty.ptr }),
            .get_native_slot = try declare(m, "dict_lua_get_native_slot", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.ptr, ty.i64, ty.ptr }),
            .set_native_slot = try declare(m, "dict_lua_set_native_slot", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.ptr, ty.i64, ty.ptr }),
            .len_number = try declare(m, "dict_lua_len_number", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr }),
            .neg = try declare(m, "dict_lua_neg", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr }),
            .binary = try declare(m, "dict_lua_binary", ty.i32, &.{ ty.ptr, ty.i8, ty.ptr, ty.ptr, ty.ptr }),
            .compare_bool = try declare(m, "dict_lua_compare_bool", ty.i32, &.{ ty.ptr, ty.i8, ty.ptr, ty.ptr, ty.ptr }),
            .concat = try declare(m, "dict_lua_concat", ty.i32, &.{ ty.ptr, ty.ptr, ty.i64, ty.ptr }),
            .cell_new = try declare(m, "dict_lua_cell_new", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr }),
            .cell_get = try declare(m, "dict_lua_cell_get", ty.void, &.{ ty.ptr, ty.ptr }),
            .cell_set = try declare(m, "dict_lua_cell_set", ty.void, &.{ ty.ptr, ty.ptr }),
            .capture_cell = try declare(m, "dict_lua_capture_cell", ty.i32, &.{ ty.ptr, ty.ptr, ty.i32, ty.ptr }),
            .make_function = try declare(m, "dict_lua_make_function", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr, ty.ptr, ty.i64, ty.ptr }),
            .call_fixed = try declare(m, "dict_lua_call_fixed", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_fixed_tail = try declare(m, "dict_lua_call_fixed_tail", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_static_fixed = try declare(m, "dict_lua_call_static_fixed", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_static_fixed_tail = try declare(m, "dict_lua_call_static_fixed_tail", ty.i32, &.{ ty.ptr, ty.i32, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .enter_local_static_call = try declare(m, "dict_lua_enter_local_static_call", ty.i32, &.{ty.ptr}),
            .leave_local_static_call = try declare(m, "dict_lua_leave_local_static_call", ty.void, &.{ty.ptr}),
            .enter_static_call = try declare(m, "dict_lua_enter_static_call", ty.i32, &.{ ty.ptr, ty.i32 }),
            .leave_static_call = try declare(m, "dict_lua_leave_static_call", ty.void, &.{ty.ptr}),
            .function_status = try declare(m, "dict_lua_function_status", ty.i32, &.{ ty.ptr, ty.i32 }),
            .call_discard = try declare(m, "dict_lua_call_discard", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64 }),
            .call_discard_tail = try declare(m, "dict_lua_call_discard_tail", ty.i32, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_multi = try declare(m, "dict_lua_call_multi", ty.call_result, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64 }),
            .call_multi_tail = try declare(m, "dict_lua_call_multi_tail", ty.call_result, &.{ ty.ptr, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_static_multi = try declare(m, "dict_lua_call_static_multi", ty.call_result, &.{ ty.ptr, ty.i32, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .call_static_multi_tail = try declare(m, "dict_lua_call_static_multi_tail", ty.call_result, &.{ ty.ptr, ty.i32, ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .results_free = try declare(m, "dict_lua_results_free", ty.void, &.{ ty.ptr, ty.i64 }),
            .return_values = try declare(m, "dict_lua_return_values", ty.function_result, &.{ ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .return_join = try declare(m, "dict_lua_return_join", ty.function_result, &.{ ty.ptr, ty.ptr, ty.i64, ty.ptr, ty.i64, ty.ptr, ty.i64 }),
            .function_error = try declare(m, "dict_lua_function_error", ty.function_result, &.{}),
            .floor = try declare(m, "floor", ty.double, &.{ty.double}),
            .pow = try declare(m, "pow", ty.double, &.{ ty.double, ty.double }),
        };
    }

    fn declare(m: *const llvm.Module, name: []const u8, ret: T, params: []const T) anyerror!V {
        return m.addFunction(name, try m.functionType(ret, params));
    }
};

const ModuleEmitter = struct {
    allocator: A,
    llvm_module: *llvm.Module,
    globals: *const analysis.Globals,
    module: *const analysis.Module,
    facts: ProgramFacts,
    runtime: Runtime,
    strings: StringPool = .{},
    static_modules: std.StringHashMapUnmanaged(u32) = .empty,
    static_literal_blobs: u32 = 0,
    functions: []V,
    function_base: u32,

    fn deinit(self: *ModuleEmitter) void {
        self.strings.deinit(self.allocator);
        self.static_modules.deinit(self.allocator);
        self.allocator.free(self.functions);
    }

    fn collectStaticModules(self: *ModuleEmitter) anyerror!void {
        if (!self.globals.stable("require")) return;
        var invalid: std.StringHashMapUnmanaged(void) = .empty;
        defer invalid.deinit(self.allocator);
        for (self.module.functions.items) |info| {
            for (info.bindings) |binding| {
                if (invalid.contains(binding.name)) continue;
                const candidate = if (!binding.mutated)
                    if (binding.static_module) |raw| try self.facts.moduleId(self.allocator, raw) else null
                else
                    null;
                if (candidate) |module_id| {
                    if (self.static_modules.get(binding.name)) |existing| {
                        if (existing != module_id) {
                            _ = self.static_modules.remove(binding.name);
                            try invalid.put(self.allocator, binding.name, {});
                        }
                    } else {
                        try self.static_modules.put(self.allocator, binding.name, module_id);
                    }
                } else if (self.static_modules.contains(binding.name)) {
                    _ = self.static_modules.remove(binding.name);
                    try invalid.put(self.allocator, binding.name, {});
                } else {
                    // A non-module binding with this spelling can shadow a module
                    // binding in a nested scope. Mark the spelling unusable globally.
                    try invalid.put(self.allocator, binding.name, {});
                }
            }
        }
    }

    fn staticModuleId(self: *const ModuleEmitter, name: []const u8) ?u32 {
        return self.static_modules.get(name);
    }

    fn functionForSpan(self: *const ModuleEmitter, span: lua.Span) anyerror!*const analysis.FunctionInfo {
        for (self.module.functions.items[1..]) |info|
            if (info.span.start == span.start and info.span.end == span.end) return info;
        return error.MissingFunctionAnalysis;
    }

    fn functionValue(self: *const ModuleEmitter, id: u32) anyerror!V {
        if (id >= self.function_base) {
            const index: usize = @intCast(id - self.function_base);
            if (index < self.functions.len) return self.functions[index];
        }
        const name = try std.fmt.allocPrint(self.allocator, "lua_f_{d}", .{id});
        defer self.allocator.free(name);
        if (self.llvm_module.getFunction(name)) |function| return function;
        return self.llvm_module.addFunction(name, try generatedFunctionType(self.llvm_module));
    }

    fn stringRef(self: *ModuleEmitter, value: []const u8) anyerror!StringRef {
        if (self.strings.map.get(value)) |id| return self.strings.items.items[id];
        const id: u32 = @intCast(self.strings.items.items.len);
        const initializer = try llvm.constString(self.llvm_module.context, value);
        const array_ty = try llvm.arrayType(self.llvm_module.types.i8, value.len);
        const name = try std.fmt.allocPrint(self.allocator, "lua_s_{d}_{d}", .{ self.function_base, id });
        defer self.allocator.free(name);
        const global = try self.llvm_module.addGlobal(name, array_ty, initializer, .private, 1);
        const ref = StringRef{ .ptr = global, .bytes = value, .len = value.len };
        try self.strings.items.append(self.allocator, ref);
        try self.strings.map.put(self.allocator, value, id);
        return ref;
    }

    const StaticLiteralBlob = struct {
        ptr: V,
        len: usize,
    };

    fn staticLiteralBlob(self: *ModuleEmitter, value: *const lua.Expr) anyerror!StaticLiteralBlob {
        const bytes = try static_encode.encode(self.allocator, value, self.facts.table_shapes);
        defer self.allocator.free(bytes);

        const id = self.static_literal_blobs;
        self.static_literal_blobs += 1;
        const name = try std.fmt.allocPrint(
            self.allocator,
            "lua_slb_{d}_{d}",
            .{ self.function_base, id },
        );
        defer self.allocator.free(name);
        const array_ty = try llvm.arrayType(self.llvm_module.types.i8, bytes.len);
        const global = try self.llvm_module.addGlobal(
            name,
            array_ty,
            try llvm.constString(self.llvm_module.context, bytes),
            .private,
            1,
        );
        return .{ .ptr = global, .len = bytes.len };
    }
};

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
    function: V,
    builder: llvm.BuilderRef,
    alloca_builder: llvm.BuilderRef,
    entry: BB,
    start: BB,
    error_block: ?BB = null,
    locals: std.StringHashMapUnmanaged(u32) = .empty,
    saves: std.ArrayList(Save) = .empty,
    storage: []LocalStorage,
    upvalue_slots: []V,
    binding_next: u32 = 0,
    breaks: std.ArrayList(BB) = .empty,

    fn a(self: *FnEmitter) A {
        return self.module.allocator;
    }

    fn ty(self: *FnEmitter) llvm.Types {
        return self.module.llvm_module.types;
    }

    fn rt(self: *FnEmitter) *const Runtime {
        return &self.module.runtime;
    }

    fn ctx(self: *FnEmitter) V {
        return llvm.param(self.function, 0) catch unreachable;
    }

    fn captures(self: *FnEmitter) V {
        return llvm.param(self.function, 1) catch unreachable;
    }

    fn args(self: *FnEmitter) V {
        return llvm.param(self.function, 2) catch unreachable;
    }

    fn argsLen(self: *FnEmitter) V {
        return llvm.param(self.function, 3) catch unreachable;
    }

    fn resultPtr(self: *FnEmitter) V {
        return llvm.param(self.function, 4) catch unreachable;
    }

    fn resultLen(self: *FnEmitter) V {
        return llvm.param(self.function, 5) catch unreachable;
    }

    fn cI1(self: *FnEmitter, value: bool) anyerror!V {
        return llvm.constInt(self.ty().i1, @intFromBool(value));
    }

    fn cI8(self: *FnEmitter, value: u8) anyerror!V {
        return llvm.constInt(self.ty().i8, value);
    }

    fn cI32(self: *FnEmitter, value: anytype) anyerror!V {
        return llvm.constInt(self.ty().i32, value);
    }

    fn cI64(self: *FnEmitter, value: anytype) anyerror!V {
        return llvm.constInt(self.ty().i64, value);
    }

    fn cDouble(self: *FnEmitter, value: f64) anyerror!V {
        return llvm.constReal(self.ty().double, value);
    }

    fn nullPtr(self: *FnEmitter) anyerror!V {
        return llvm.constNull(self.ty().ptr);
    }

    fn deinit(self: *FnEmitter) void {
        llvm.disposeBuilder(self.builder);
        llvm.disposeBuilder(self.alloca_builder);
        self.locals.deinit(self.a());
        self.saves.deinit(self.a());
        self.a().free(self.storage);
        self.a().free(self.upvalue_slots);
        self.breaks.deinit(self.a());
    }

    fn init(module: *ModuleEmitter, info: *const analysis.FunctionInfo) anyerror!FnEmitter {
        const function = try module.functionValue(info.id);
        const entry = try llvm.appendBlock(module.llvm_module.context, function, "entry");
        const start = try llvm.appendBlock(module.llvm_module.context, function, "start");
        const alloca_builder = try llvm.createBuilder(module.llvm_module.context);
        errdefer llvm.disposeBuilder(alloca_builder);
        llvm.position(alloca_builder, entry);
        const builder = try llvm.createBuilder(module.llvm_module.context);
        errdefer llvm.disposeBuilder(builder);
        llvm.position(builder, start);
        const storage = try module.allocator.alloc(LocalStorage, info.bindings.len);
        errdefer module.allocator.free(storage);
        const upvalue_slots = try module.allocator.alloc(V, info.upvalues.len);
        errdefer module.allocator.free(upvalue_slots);
        var self = FnEmitter{
            .module = module,
            .info = info,
            .function = function,
            .builder = builder,
            .alloca_builder = alloca_builder,
            .entry = entry,
            .start = start,
            .storage = storage,
            .upvalue_slots = upvalue_slots,
        };
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

    fn finish(self: *FnEmitter) anyerror!void {
        llvm.position(self.alloca_builder, self.entry);
        try llvm.br(self.alloca_builder, self.start);
        if (self.error_block) |error_block| {
            llvm.position(self.builder, error_block);
            const result = try llvm.call(self.builder, self.rt().function_error, &.{});
            try llvm.ret(self.builder, result);
        }
    }

    fn newBlock(self: *FnEmitter, name: []const u8) anyerror!BB {
        return llvm.appendBlock(self.module.llvm_module.context, self.function, name);
    }

    fn errorBlock(self: *FnEmitter) anyerror!BB {
        if (self.error_block) |bb| return bb;
        const bb = try self.newBlock("error");
        self.error_block = bb;
        return bb;
    }

    fn valueSlot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().value, value_align);
    }

    fn ptrSlot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().ptr, 8);
    }

    fn i64Slot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().i64, 8);
    }

    fn nativeNumberSlot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().double, 8);
    }

    fn nativeBoolSlot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().i1, 1);
    }

    fn valueArray(self: *FnEmitter, count: usize) anyerror!V {
        const array_ty = try llvm.arrayType(self.ty().value, @max(count, 1));
        return llvm.alloca(self.alloca_builder, array_ty, value_align);
    }

    fn arrayElem(self: *FnEmitter, array: V, index: usize) anyerror!V {
        var indices = [_]V{try self.cI64(index)};
        return llvm.gep(self.builder, self.ty().value, array, &indices);
    }

    fn pointerArray(self: *FnEmitter, count: usize) anyerror!V {
        const array_ty = try llvm.arrayType(self.ty().ptr, @max(count, 1));
        return llvm.alloca(self.alloca_builder, array_ty, 8);
    }

    fn pointerArrayElem(self: *FnEmitter, array: V, index: usize) anyerror!V {
        var indices = [_]V{try self.cI64(index)};
        return llvm.gep(self.builder, self.ty().ptr, array, &indices);
    }

    fn doubleSlot(self: *FnEmitter) anyerror!V {
        return llvm.alloca(self.alloca_builder, self.ty().double, 8);
    }

    fn check(self: *FnEmitter, status: V) anyerror!void {
        const ok = try llvm.icmp(self.builder, .eq, status, try self.cI32(0));
        const cont = try self.newBlock("ok");
        try llvm.condBr(self.builder, ok, cont, try self.errorBlock());
        llvm.position(self.builder, cont);
    }

    fn copyValue(self: *FnEmitter, dst: V, src: V) anyerror!void {
        _ = try llvm.call(self.builder, self.rt().value_copy, &.{ dst, src });
    }

    fn stringRef(self: *FnEmitter, value: []const u8) anyerror!StringRef {
        return self.module.stringRef(value);
    }

    fn box(self: *FnEmitter, value: ValueRef) anyerror!V {
        switch (value) {
            .boxed => |ptr| return ptr,
            .table => |table_value| return table_value.ptr,
            else => {},
        }
        const out = try self.valueSlot();
        switch (value) {
            .nil => _ = try llvm.call(self.builder, self.rt().value_nil, &.{out}),
            .number => |operand| _ = try llvm.call(self.builder, self.rt().value_number, &.{ out, operand }),
            .boolean => |operand| {
                const wide = try llvm.zext(self.builder, operand, self.ty().i8);
                _ = try llvm.call(self.builder, self.rt().value_bool, &.{ out, wide });
            },
            .string => |s| _ = try llvm.call(self.builder, self.rt().value_string, &.{ out, s.ptr, try self.cI64(s.len) }),
            .table, .boxed => unreachable,
        }
        return out;
    }

    fn materializeCopy(self: *FnEmitter, value: ValueRef) anyerror!V {
        const boxed = try self.box(value);
        const out = try self.valueSlot();
        try self.copyValue(out, boxed);
        return out;
    }

    fn truthy(self: *FnEmitter, value: ValueRef) anyerror!V {
        return switch (value) {
            .nil => try self.cI1(false),
            .boolean => |v| v,
            .number, .string, .table => try self.cI1(true),
            .boxed => |ptr| blk: {
                const raw = try llvm.call(self.builder, self.rt().value_truthy, &.{ptr});
                break :blk try llvm.icmp(self.builder, .ne, raw, try self.cI8(0));
            },
        };
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
            .direct, .static_function, .static_module => return error.BindingInitializedTwice,
            .number => |slot| {
                if (value != .number) return error.StaticTypeMismatch;
                try llvm.store(self.builder, value.number, slot, 8);
            },
            .boolean => |slot| {
                if (value != .boolean) return error.StaticTypeMismatch;
                try llvm.store(self.builder, value.boolean, slot, 1);
            },
            .value => |slot| try self.copyValue(slot, try self.box(value)),
            .cell => |slot| {
                const boxed = try self.box(value);
                const status = try llvm.call(self.builder, self.rt().cell_new, &.{ self.ctx(), boxed, slot });
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
                .static_module => |module| .{ .boxed = module.value },
                .number => |slot| .{ .number = try llvm.load(self.builder, self.ty().double, slot, 8) },
                .boolean => |slot| .{ .boolean = try llvm.load(self.builder, self.ty().i1, slot, 1) },
                .value => |slot| blk: {
                    const out = try self.valueSlot();
                    try self.copyValue(out, slot);
                    break :blk .{ .boxed = out };
                },
                .cell => |slot| blk: {
                    const out = try self.valueSlot();
                    const cell = try llvm.load(self.builder, self.ty().ptr, slot, 8);
                    _ = try llvm.call(self.builder, self.rt().cell_get, &.{ cell, out });
                    break :blk .{ .boxed = out };
                },
            },
            .upvalue => |ordinal| blk: {
                const out = try self.valueSlot();
                const cell = try llvm.load(self.builder, self.ty().ptr, self.upvalue_slots[ordinal], 8);
                _ = try llvm.call(self.builder, self.rt().cell_get, &.{ cell, out });
                break :blk .{ .boxed = out };
            },
            .global => |slot| blk: {
                if (slot == global_abi.id("package") or slot == global_abi.id("_G")) {
                    const status = try llvm.call(self.builder, self.rt().observe_package, &.{self.ctx()});
                    try self.check(status);
                }
                if (self.module.globals.stableSlot(slot) and slot < global_abi.count) {
                    const ptr = try llvm.call(self.builder, self.rt().global_ptr, &.{ self.ctx(), try self.cI32(slot) });
                    const name = self.module.globals.names.items[slot];
                    if (nativeGlobalNamespace(name)) |namespace|
                        break :blk .{ .table = .{ .ptr = ptr, .native_namespace = namespace } };
                    break :blk .{ .boxed = ptr };
                }
                const out = try self.valueSlot();
                const status = try llvm.call(self.builder, self.rt().global_get, &.{ self.ctx(), try self.cI32(slot), out });
                try self.check(status);
                break :blk .{ .boxed = out };
            },
        };
    }

    fn storeResolved(self: *FnEmitter, resolved: Resolved, value: ValueRef) anyerror!void {
        switch (resolved) {
            .local => |binding| switch (self.storage[binding]) {
                .uninitialized, .direct, .static_function, .static_module => return error.MutationAnalysisMismatch,
                .number => |slot| {
                    if (value != .number) return error.StaticTypeMismatch;
                    try llvm.store(self.builder, value.number, slot, 8);
                },
                .boolean => |slot| {
                    if (value != .boolean) return error.StaticTypeMismatch;
                    try llvm.store(self.builder, value.boolean, slot, 1);
                },
                .value => |slot| try self.copyValue(slot, try self.box(value)),
                .cell => |slot| {
                    const boxed = try self.box(value);
                    const cell = try llvm.load(self.builder, self.ty().ptr, slot, 8);
                    _ = try llvm.call(self.builder, self.rt().cell_set, &.{ cell, boxed });
                },
            },
            .upvalue => |ordinal| {
                const boxed = try self.box(value);
                const cell = try llvm.load(self.builder, self.ty().ptr, self.upvalue_slots[ordinal], 8);
                _ = try llvm.call(self.builder, self.rt().cell_set, &.{ cell, boxed });
            },
            .global => |slot| {
                const boxed = try self.box(value);
                const status = try llvm.call(self.builder, self.rt().global_set, &.{ self.ctx(), try self.cI32(slot), boxed });
                try self.check(status);
            },
        }
    }

    fn numberOperand(self: *FnEmitter, raw: []const u8) anyerror!V {
        return self.cDouble(try numbers.parse(raw));
    }

    fn nativeArith(self: *FnEmitter, op: lua.BinaryOp, lhs: V, rhs: V) anyerror!ValueRef {
        const out = switch (op) {
            .add => try llvm.fadd(self.builder, lhs, rhs),
            .sub => try llvm.fsub(self.builder, lhs, rhs),
            .mul => try llvm.fmul(self.builder, lhs, rhs),
            .div => try llvm.fdiv(self.builder, lhs, rhs),
            .pow => try llvm.call(self.builder, self.rt().pow, &.{ lhs, rhs }),
            .mod => blk: {
                const div = try llvm.fdiv(self.builder, lhs, rhs);
                const floor = try llvm.call(self.builder, self.rt().floor, &.{div});
                const product = try llvm.fmul(self.builder, floor, rhs);
                break :blk try llvm.fsub(self.builder, lhs, product);
            },
            else => unreachable,
        };
        return .{ .number = out };
    }

    fn nativeCompare(self: *FnEmitter, op: lua.BinaryOp, lhs: V, rhs: V) anyerror!ValueRef {
        const predicate: llvm.RealPredicate = switch (op) {
            .eq => .oeq,
            .ne => .une,
            .lt => .olt,
            .le => .ole,
            .gt => .ogt,
            .ge => .oge,
            else => unreachable,
        };
        return .{ .boolean = try llvm.fcmp(self.builder, predicate, lhs, rhs) };
    }

    fn dynamicBinary(self: *FnEmitter, op: lua.BinaryOp, lhs: ValueRef, rhs: ValueRef) anyerror!ValueRef {
        const lhs_box = try self.box(lhs);
        const rhs_box = try self.box(rhs);
        const out = try self.valueSlot();
        const raw: u8 = switch (op) {
            .add => 0,
            .sub => 1,
            .mul => 2,
            .div => 3,
            .mod => 4,
            .pow => 5,
            else => unreachable,
        };
        const status = try llvm.call(self.builder, self.rt().binary, &.{
            self.ctx(), try self.cI8(raw), lhs_box, rhs_box, out,
        });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn dynamicCompare(self: *FnEmitter, op: lua.BinaryOp, lhs: ValueRef, rhs: ValueRef) anyerror!ValueRef {
        const lhs_box = try self.box(lhs);
        const rhs_box = try self.box(rhs);
        const raw_slot = try llvm.alloca(self.alloca_builder, self.ty().i8, 1);
        const raw: u8 = switch (op) {
            .eq => 0,
            .ne => 1,
            .lt => 2,
            .le => 3,
            .gt => 4,
            .ge => 5,
            else => unreachable,
        };
        const status = try llvm.call(self.builder, self.rt().compare_bool, &.{
            self.ctx(), try self.cI8(raw), lhs_box, rhs_box, raw_slot,
        });
        try self.check(status);
        const raw_value = try llvm.load(self.builder, self.ty().i8, raw_slot, 1);
        return .{ .boolean = try llvm.icmp(self.builder, .ne, raw_value, try self.cI8(0)) };
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
        try self.copyValue(out, try self.box(lhs));
        const condition = try self.truthy(lhs);
        const rhs_block = try self.newBlock("sc_rhs");
        const done = try self.newBlock("sc_done");
        if (op == .and_)
            try llvm.condBr(self.builder, condition, rhs_block, done)
        else
            try llvm.condBr(self.builder, condition, done, rhs_block);
        llvm.position(self.builder, rhs_block);
        const rhs = try self.expr(rhs_expr);
        try self.copyValue(out, try self.box(rhs));
        try llvm.br(self.builder, done);
        llvm.position(self.builder, done);
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
            const dst = try self.arrayElem(array, index);
            try self.copyValue(dst, try self.box(value));
        }
        const out = try self.valueSlot();
        const status = try llvm.call(self.builder, self.rt().concat, &.{
            self.ctx(), array, try self.cI64(parts.items.len), out,
        });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn unary(self: *FnEmitter, op: lua.UnaryOp, operand_expr: *const lua.Expr) anyerror!ValueRef {
        const operand = try self.expr(operand_expr);
        return switch (op) {
            .not_ => .{ .boolean = try llvm.bitNot(self.builder, try self.truthy(operand)) },
            .neg => blk: {
                if (operand == .number)
                    break :blk .{ .number = try llvm.fneg(self.builder, operand.number) };
                const boxed = try self.box(operand);
                const out = try self.valueSlot();
                const status = try llvm.call(self.builder, self.rt().neg, &.{ self.ctx(), boxed, out });
                try self.check(status);
                break :blk .{ .boxed = out };
            },
            .len => blk: {
                if (operand == .string)
                    break :blk .{ .number = try self.cDouble(@floatFromInt(operand.string.len)) };
                const boxed = try self.box(operand);
                const slot = try self.doubleSlot();
                const status = try llvm.call(self.builder, self.rt().len_number, &.{ self.ctx(), boxed, slot });
                try self.check(status);
                break :blk .{ .number = try llvm.load(self.builder, self.ty().double, slot, 8) };
            },
        };
    }

    fn staticFunction(self: *FnEmitter, target: *const analysis.FunctionInfo) anyerror!StaticFunctionRef {
        var captures_ptr = try self.nullPtr();
        if (target.upvalues.len != 0) {
            const capture_array = try self.pointerArray(target.upvalues.len);
            captures_ptr = capture_array;
            for (target.upvalues, 0..) |upvalue, index| {
                const cell = switch (upvalue.source) {
                    .local => |binding| switch (self.storage[binding]) {
                        .cell => |slot| try llvm.load(self.builder, self.ty().ptr, slot, 8),
                        .uninitialized, .direct, .static_function, .static_module, .number, .boolean, .value => return error.CaptureAnalysisMismatch,
                    },
                    .upvalue => |ordinal| try llvm.load(self.builder, self.ty().ptr, self.upvalue_slots[ordinal], 8),
                };
                try llvm.store(self.builder, cell, try self.pointerArrayElem(capture_array, index), 8);
            }
        }
        return .{
            .function_id = target.id,
            .module_id = self.module.facts.current_module_id,
            .captures_ptr = captures_ptr,
            .captures_len = target.upvalues.len,
        };
    }

    fn closure(self: *FnEmitter, target: *const analysis.FunctionInfo) anyerror!ValueRef {
        const direct = try self.staticFunction(target);
        const out = try self.valueSlot();
        const status = try llvm.call(self.builder, self.rt().make_function, &.{
            self.ctx(),
            try self.cI32(target.id),
            try self.module.functionValue(target.id),
            direct.captures_ptr,
            try self.cI64(direct.captures_len),
            out,
        });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn getIndex(self: *FnEmitter, object: ValueRef, key_expr: *const lua.Expr) anyerror!ValueRef {
        if (staticString(key_expr)) |name| return self.getField(object, name);
        const object_box = try self.box(object);
        const out = try self.valueSlot();
        const key_box = try self.box(try self.expr(key_expr));
        const status = try llvm.call(self.builder, self.rt().get_index, &.{
            self.ctx(), object_box, key_box, out,
        });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn table(self: *FnEmitter, table_expr: anytype) anyerror!ValueRef {
        const fields = table_expr.fields;
        const shape = self.module.facts.tableShape(table_expr.span.start);
        if (fields.len >= static_literal_blob_threshold and static_encode.isFields(fields)) {
            var literal = lua.Expr{ .table = table_expr };
            const data = try self.module.staticLiteralBlob(&literal);
            const table_value = try self.valueSlot();
            const status = try llvm.call(
                self.builder,
                self.rt().decode_static_literal,
                &.{ self.ctx(), data.ptr, try self.cI64(data.len), table_value },
            );
            try self.check(status);
            return .{ .table = .{ .ptr = table_value, .shape = shape } };
        }

        const table_value = try self.valueSlot();
        const create_status = if (shape) |shape_value|
            try llvm.call(self.builder, self.rt().new_shaped_table, &.{
                self.ctx(), try self.cI32(shape_value.id), table_value,
            })
        else blk: {
            var list_capacity: u32 = 0;
            for (fields) |field| if (field == .list) {
                list_capacity += 1;
            };
            break :blk if (list_capacity != 0)
                try llvm.call(self.builder, self.rt().new_array_table, &.{
                    self.ctx(), try self.cI32(list_capacity), table_value,
                })
            else
                try llvm.call(self.builder, self.rt().new_table, &.{ self.ctx(), table_value });
        };
        try self.check(create_status);

        for (fields, 0..) |field, index| switch (field) {
            .named => |item| {
                const boxed = try self.box(try self.expr(item.value));
                const status = if (shape) |shape_value| blk: {
                    const slot = shapeSlot(shape_value, item.name) orelse return error.ShapeAnalysisMismatch;
                    break :blk try llvm.call(self.builder, self.rt().set_shape_slot, &.{
                        self.ctx(), table_value, try self.cI32(slot), boxed,
                    });
                } else blk: {
                    const key = try self.stringRef(item.name);
                    break :blk try llvm.call(self.builder, self.rt().set_field, &.{
                        self.ctx(), table_value, key.ptr, try self.cI64(key.len), boxed,
                    });
                };
                try self.check(status);
            },
            .keyed => |item| {
                const status = if (shape) |shape_value| blk: {
                    const key_name = staticString(item.key) orelse return error.ShapeAnalysisMismatch;
                    const value_box = try self.box(try self.expr(item.value));
                    const slot = shapeSlot(shape_value, key_name) orelse return error.ShapeAnalysisMismatch;
                    break :blk try llvm.call(self.builder, self.rt().set_shape_slot, &.{
                        self.ctx(), table_value, try self.cI32(slot), value_box,
                    });
                } else blk: {
                    const key_box = try self.box(try self.expr(item.key));
                    const value_box = try self.box(try self.expr(item.value));
                    break :blk try llvm.call(self.builder, self.rt().set_index, &.{
                        self.ctx(), table_value, key_box, value_box,
                    });
                };
                try self.check(status);
            },
            .list => |item| {
                if (index + 1 == fields.len and isMultiExpr(item)) {
                    const tail = try self.multi(item);
                    const status = try llvm.call(self.builder, self.rt().table_append_many, &.{
                        self.ctx(), table_value, tail.ptr, tail.len,
                    });
                    try self.check(status);
                    try self.freeMulti(tail);
                } else {
                    const boxed = try self.box(try self.expr(item));
                    const status = try llvm.call(self.builder, self.rt().table_append, &.{
                        self.ctx(), table_value, boxed,
                    });
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
            _ = try llvm.call(self.builder, self.rt().results_free, &.{ multi_value.ptr, multi_value.len });
    }

    fn getField(self: *FnEmitter, object: ValueRef, name: []const u8) anyerror!ValueRef {
        const object_box = try self.box(object);
        const key = try self.stringRef(name);
        const out = try self.valueSlot();
        const status = if (object == .table) blk: {
            if (object.table.shape) |shape| if (shapeSlot(shape, name)) |slot|
                break :blk try llvm.call(self.builder, self.rt().get_known_shape_field, &.{
                    self.ctx(), object_box,             try self.cI32(shape.id), try self.cI32(slot),
                    key.ptr,    try self.cI64(key.len), out,
                });
            if (object.table.native_namespace) |namespace| if (static_fields.slotForName(namespace, name)) |slot|
                break :blk try llvm.call(self.builder, self.rt().get_native_slot, &.{
                    self.ctx(), object_box, try self.cI32(slot), key.ptr, try self.cI64(key.len), out,
                });
            break :blk try llvm.call(self.builder, self.rt().get_field, &.{
                self.ctx(), object_box, key.ptr, try self.cI64(key.len), out,
            });
        } else try llvm.call(self.builder, self.rt().get_field, &.{
            self.ctx(), object_box, key.ptr, try self.cI64(key.len), out,
        });
        try self.check(status);
        return .{ .boxed = out };
    }

    fn varargs(self: *FnEmitter) anyerror!MultiRef {
        const param_count = self.info.params.len;
        const has = try llvm.icmp(self.builder, .ugt, self.argsLen(), try self.cI64(param_count));
        const raw_len = try llvm.sub(self.builder, self.argsLen(), try self.cI64(param_count));
        const len = try llvm.select(self.builder, has, raw_len, try self.cI64(0));
        var indices = [_]V{try self.cI64(param_count)};
        const ptr = try llvm.gep(self.builder, self.ty().value, self.args(), &indices);
        return .{ .ptr = ptr, .len = len, .owned = false };
    }

    const PreparedCall = struct {
        callee: ValueRef,
        fixed: V,
        fixed_len: usize,
        tail: ?MultiRef,
    };

    const PreparedArgs = struct {
        fixed: V,
        fixed_len: usize,
        tail: ?MultiRef,
    };

    fn prepareStaticArgs(self: *FnEmitter, args_in: []const *lua.Expr) anyerror!PreparedArgs {
        const has_tail = args_in.len != 0 and isMultiExpr(args_in[args_in.len - 1]);
        const fixed_args = if (has_tail) args_in[0 .. args_in.len - 1] else args_in;
        const fixed = try self.valueArray(fixed_args.len);
        for (fixed_args, 0..) |arg, index| {
            const dst = try self.arrayElem(fixed, index);
            try self.copyValue(dst, try self.box(try self.expr(arg)));
        }
        const tail = if (has_tail) try self.multi(args_in[args_in.len - 1]) else null;
        return .{ .fixed = fixed, .fixed_len = fixed_args.len, .tail = tail };
    }

    fn staticModuleExpr(self: *FnEmitter, value: *const lua.Expr) anyerror!?StaticModuleRef {
        return switch (value.*) {
            .name => |name| blk: {
                const resolved = try self.resolve(name.value);
                if (resolved == .local) switch (self.storage[resolved.local]) {
                    .static_module => |module| break :blk module,
                    else => {},
                };
                const module_id = self.module.staticModuleId(name.value) orelse break :blk null;
                const value_ref = try self.loadResolved(resolved);
                const boxed = try self.box(value_ref);
                const sentinel = if (self.module.facts.moduleEagerPrepared(module_id))
                    try llvm.call(self.builder, self.rt().module_value_sentinel, &.{
                        self.ctx(), try self.cI32(module_id), boxed,
                    })
                else
                    null;
                break :blk .{ .module_id = module_id, .value = boxed, .pristine_ptr = sentinel };
            },
            .paren => |paren| self.staticModuleExpr(paren.expr),
            .call => |call| if (try self.staticRequire(call.callee, null, call.args)) |request|
                try self.directStaticModuleRequire(request)
            else
                null,
            else => null,
        };
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
            .index => |index| blk: {
                const field = staticString(index.key) orelse break :blk null;
                const module = (try self.staticModuleExpr(index.object)) orelse break :blk null;
                const export_fact = self.module.facts.exportFunction(module.module_id, field) orelse break :blk null;

                if (export_fact.capture_count == 0) if (module.pristine_ptr) |sentinel| {
                    const direct_slot = try self.nativeBoolSlot();
                    try llvm.store(self.builder, try llvm.constInt(self.ty().i1, 0), direct_slot, 1);
                    const check_block = try self.newBlock("export_callee_check_pristine");
                    const selected_block = try self.newBlock("export_callee_pristine");
                    const fallback_block = try self.newBlock("export_callee_fallback");
                    const join = try self.newBlock("export_callee_join");
                    const has_sentinel = try llvm.icmp(self.builder, .ne, sentinel, try self.nullPtr());
                    try llvm.condBr(self.builder, has_sentinel, check_block, fallback_block);

                    llvm.position(self.builder, check_block);
                    const pristine_raw = try llvm.load(self.builder, self.ty().i8, sentinel, 1);
                    const pristine = try llvm.icmp(self.builder, .ne, pristine_raw, try self.cI8(0));
                    try llvm.condBr(self.builder, pristine, selected_block, fallback_block);

                    llvm.position(self.builder, selected_block);
                    try llvm.store(self.builder, try llvm.constInt(self.ty().i1, 1), direct_slot, 1);
                    try llvm.br(self.builder, join);

                    llvm.position(self.builder, fallback_block);
                    const live = try self.getField(.{ .boxed = module.value }, field);
                    const callable = try self.box(live);
                    try llvm.br(self.builder, join);

                    llvm.position(self.builder, join);
                    break :blk .{
                        .function_id = export_fact.function_id,
                        .module_id = module.module_id,
                        .captures_ptr = try self.nullPtr(),
                        .captures_len = 0,
                        .direct_captures = null,
                        .pristine_guard = try llvm.load(self.builder, self.ty().i1, direct_slot, 1),
                        .guard_callable = callable,
                    };
                };

                const live = try self.getField(.{ .boxed = module.value }, field);
                const callable = try self.box(live);
                const direct_captures = if (export_fact.capture_count == 0)
                    try self.nullPtr()
                else
                    try llvm.call(self.builder, self.rt().value_function_captures, &.{
                        callable,
                        try self.cI32(export_fact.function_id),
                    });
                break :blk .{
                    .function_id = export_fact.function_id,
                    .module_id = module.module_id,
                    .captures_ptr = try self.nullPtr(),
                    .captures_len = 0,
                    .direct_captures = direct_captures,
                    .guard_callable = callable,
                };
            },
            .paren => |paren| self.staticCallee(paren.expr),
            else => null,
        };
    }

    fn prepareCall(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args_in: []const *lua.Expr) anyerror!PreparedCall {
        var callee: ValueRef = undefined;
        var self_value: ?ValueRef = null;
        if (method) |name| {
            const object = try self.expr(callee_expr);
            self_value = object;
            callee = try self.getField(object, name);
        } else callee = try self.expr(callee_expr);

        const has_tail = args_in.len != 0 and isMultiExpr(args_in[args_in.len - 1]);
        const fixed_args = if (has_tail) args_in[0 .. args_in.len - 1] else args_in;
        const fixed_len = fixed_args.len + @intFromBool(self_value != null);
        const fixed = try self.valueArray(fixed_len);
        var at: usize = 0;
        if (self_value) |value| {
            try self.copyValue(try self.arrayElem(fixed, at), try self.box(value));
            at += 1;
        }
        for (fixed_args) |arg| {
            try self.copyValue(try self.arrayElem(fixed, at), try self.box(try self.expr(arg)));
            at += 1;
        }
        const tail = if (has_tail) try self.multi(args_in[args_in.len - 1]) else null;
        return .{ .callee = callee, .fixed = fixed, .fixed_len = fixed_len, .tail = tail };
    }

    const StaticRequire = struct {
        module_id: u32,
        requested: StringRef,
    };

    fn staticString(value: *const lua.Expr) ?[]const u8 {
        return switch (value.*) {
            .string => |v| v.value,
            .paren => |v| staticString(v.expr),
            else => null,
        };
    }

    fn staticRequire(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args_in: []const *lua.Expr) anyerror!?StaticRequire {
        if (method != null or args_in.len != 1 or callee_expr.* != .name) return null;
        if (!std.mem.eql(u8, callee_expr.name.value, "require")) return null;
        if (!self.module.globals.stable("require")) return null;
        const require_slot = self.module.globals.get("require") orelse return null;
        switch (try self.resolve("require")) {
            .global => |slot| if (slot != require_slot) return null,
            else => return null,
        }
        const requested = staticString(args_in[0]) orelse return null;
        const module_id = (try self.module.facts.moduleId(self.a(), requested)) orelse return null;
        return .{ .module_id = module_id, .requested = try self.stringRef(requested) };
    }

    fn directStaticModuleRequire(self: *FnEmitter, request: StaticRequire) anyerror!StaticModuleRef {
        if (!self.module.facts.canDeferRequire(request.module_id, request.requested.bytes))
            return .{ .module_id = request.module_id, .value = try self.directRequireValue(request) };

        const loaded = try self.valueSlot();
        const sentinel = try llvm.call(self.builder, self.rt().defer_require_module_ref, &.{
            self.ctx(), try self.cI32(request.module_id), loaded,
        });
        const fast_block = try self.newBlock("require_ref_prepared");
        const fallback_block = try self.newBlock("require_ref_fallback");
        const join = try self.newBlock("require_ref_join");
        const ready = try llvm.icmp(self.builder, .ne, sentinel, try self.nullPtr());
        try llvm.condBr(self.builder, ready, fast_block, fallback_block);

        llvm.position(self.builder, fast_block);
        try llvm.br(self.builder, join);

        llvm.position(self.builder, fallback_block);
        const status = try llvm.call(self.builder, self.rt().require_module_id, &.{
            self.ctx(),                           try self.cI32(request.module_id), request.requested.ptr,
            try self.cI64(request.requested.len), loaded,
        });
        try self.check(status);
        try llvm.br(self.builder, join);
        llvm.position(self.builder, join);
        return .{ .module_id = request.module_id, .value = loaded, .pristine_ptr = sentinel };
    }

    fn directRequireValue(self: *FnEmitter, request: StaticRequire) anyerror!V {
        const loaded = try self.valueSlot();
        if (self.module.facts.canDeferRequire(request.module_id, request.requested.bytes)) {
            const fast = try llvm.call(self.builder, self.rt().defer_require_module_id, &.{
                self.ctx(), try self.cI32(request.module_id), loaded,
            });
            const fast_block = try self.newBlock("require_prepared");
            const fallback_block = try self.newBlock("require_fallback");
            const join = try self.newBlock("require_join");
            const ready = try llvm.icmp(self.builder, .ne, fast, try self.cI8(0));
            try llvm.condBr(self.builder, ready, fast_block, fallback_block);

            llvm.position(self.builder, fast_block);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, fallback_block);
            const status = try llvm.call(self.builder, self.rt().require_module_id, &.{
                self.ctx(),                           try self.cI32(request.module_id), request.requested.ptr,
                try self.cI64(request.requested.len), loaded,
            });
            try self.check(status);
            try llvm.br(self.builder, join);
            llvm.position(self.builder, join);
            return loaded;
        }

        const status = try llvm.call(self.builder, self.rt().require_module_id, &.{
            self.ctx(),                           try self.cI32(request.module_id), request.requested.ptr,
            try self.cI64(request.requested.len), loaded,
        });
        try self.check(status);
        return loaded;
    }

    fn directRequireFixed(self: *FnEmitter, request: StaticRequire, count: usize) anyerror!?V {
        const loaded = try self.directRequireValue(request);
        if (count == 0) return null;
        const output = try self.valueArray(count);
        try self.copyValue(try self.arrayElem(output, 0), loaded);
        for (1..count) |index|
            _ = try llvm.call(self.builder, self.rt().value_nil, &.{try self.arrayElem(output, index)});
        return output;
    }

    fn sameModuleStaticCall(self: *const FnEmitter, function: StaticFunctionRef) bool {
        return function.module_id == self.module.facts.current_module_id;
    }

    fn staticCallModuleId(self: *const FnEmitter, function: StaticFunctionRef) u32 {
        return if (self.sameModuleStaticCall(function)) std.math.maxInt(u32) else function.module_id;
    }

    fn emitStaticFixedPrepared(
        self: *FnEmitter,
        function: StaticFunctionRef,
        entry_fn: V,
        prepared: PreparedArgs,
        output: V,
        count: usize,
    ) anyerror!void {
        if ((function.captures_len == 0 or function.direct_captures != null) and prepared.tail == null) {
            for (0..count) |index|
                _ = try llvm.call(self.builder, self.rt().value_nil, &.{try self.arrayElem(output, index)});
            const same_module = self.sameModuleStaticCall(function);
            const enter = if (same_module)
                try llvm.call(self.builder, self.rt().enter_local_static_call, &.{self.ctx()})
            else
                try llvm.call(self.builder, self.rt().enter_static_call, &.{
                    self.ctx(), try self.cI32(function.module_id),
                });
            try self.check(enter);
            const capture_context = function.direct_captures orelse try self.nullPtr();
            const result = try llvm.call(self.builder, entry_fn, &.{
                self.ctx(), capture_context,      prepared.fixed, try self.cI64(prepared.fixed_len),
                output,     try self.cI64(count),
            });
            _ = if (same_module)
                try llvm.call(self.builder, self.rt().leave_local_static_call, &.{self.ctx()})
            else
                try llvm.call(self.builder, self.rt().leave_static_call, &.{self.ctx()});
            const raw_status = try llvm.extractValue(self.builder, result, 2);
            const status = try llvm.call(self.builder, self.rt().function_status, &.{ self.ctx(), raw_status });
            try self.check(status);
            return;
        }

        const status = if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_static_fixed_tail, &.{
                self.ctx(),                           try self.cI32(self.staticCallModuleId(function)), entry_fn,                          function.captures_ptr,
                try self.cI64(function.captures_len), prepared.fixed,                                   try self.cI64(prepared.fixed_len), tail.ptr,
                tail.len,                             output,                                           try self.cI64(count),
            })
        else
            try llvm.call(self.builder, self.rt().call_static_fixed, &.{
                self.ctx(),                           try self.cI32(self.staticCallModuleId(function)), entry_fn,                          function.captures_ptr,
                try self.cI64(function.captures_len), prepared.fixed,                                   try self.cI64(prepared.fixed_len), output,
                try self.cI64(count),
            });
        try self.check(status);
    }

    fn emitFallbackFixedPrepared(
        self: *FnEmitter,
        callable: V,
        prepared: PreparedArgs,
        output: V,
        count: usize,
    ) anyerror!void {
        const status = if (count == 0)
            if (prepared.tail) |tail|
                try llvm.call(self.builder, self.rt().call_discard_tail, &.{
                    self.ctx(), callable, prepared.fixed, try self.cI64(prepared.fixed_len), tail.ptr, tail.len,
                })
            else
                try llvm.call(self.builder, self.rt().call_discard, &.{
                    self.ctx(), callable, prepared.fixed, try self.cI64(prepared.fixed_len),
                })
        else if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_fixed_tail, &.{
                self.ctx(), callable, prepared.fixed, try self.cI64(prepared.fixed_len),
                tail.ptr,   tail.len, output,         try self.cI64(count),
            })
        else
            try llvm.call(self.builder, self.rt().call_fixed, &.{
                self.ctx(), callable,             prepared.fixed, try self.cI64(prepared.fixed_len),
                output,     try self.cI64(count),
            });
        try self.check(status);
    }

    fn directStaticFixed(self: *FnEmitter, function: StaticFunctionRef, args_in: []const *lua.Expr, count: usize) anyerror!?V {
        const prepared = try self.prepareStaticArgs(args_in);
        const output = try self.valueArray(count);
        const entry_fn = try self.module.functionValue(function.function_id);

        if (function.pristine_guard) |pristine| {
            const callable = function.guard_callable orelse return error.MissingPristineFallback;
            const direct_block = try self.newBlock("pristine_export");
            const fallback_block = try self.newBlock("pristine_export_fallback");
            const join = try self.newBlock("pristine_export_join");
            try llvm.condBr(self.builder, pristine, direct_block, fallback_block);

            llvm.position(self.builder, direct_block);
            try self.emitStaticFixedPrepared(function, entry_fn, prepared, output, count);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, fallback_block);
            try self.emitFallbackFixedPrepared(callable, prepared, output, count);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, join);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return if (count == 0) null else output;
        }

        if (function.guard_callable) |callable| {
            if (function.direct_captures != null and prepared.tail != null) {
                try self.emitFallbackFixedPrepared(callable, prepared, output, count);
                if (prepared.tail) |tail| try self.freeMulti(tail);
                return if (count == 0) null else output;
            }
            const is_expected = try llvm.call(self.builder, self.rt().value_is_function_id, &.{
                callable, try self.cI32(function.function_id),
            });
            const direct_block = try self.newBlock("direct_export");
            const fallback_block = try self.newBlock("dynamic_export");
            const join = try self.newBlock("export_join");
            const matches = try llvm.icmp(self.builder, .ne, is_expected, try self.cI8(0));
            try llvm.condBr(self.builder, matches, direct_block, fallback_block);

            llvm.position(self.builder, direct_block);
            try self.emitStaticFixedPrepared(function, entry_fn, prepared, output, count);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, fallback_block);
            try self.emitFallbackFixedPrepared(callable, prepared, output, count);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, join);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return if (count == 0) null else output;
        }

        try self.emitStaticFixedPrepared(function, entry_fn, prepared, output, count);
        if (prepared.tail) |tail| try self.freeMulti(tail);
        return if (count == 0) null else output;
    }

    fn emitStaticMultiPrepared(
        self: *FnEmitter,
        function: StaticFunctionRef,
        entry_fn: V,
        prepared: PreparedArgs,
    ) anyerror!MultiRef {
        if ((function.captures_len == 0 or function.direct_captures != null) and prepared.tail == null) {
            const same_module = self.sameModuleStaticCall(function);
            const enter = if (same_module)
                try llvm.call(self.builder, self.rt().enter_local_static_call, &.{self.ctx()})
            else
                try llvm.call(self.builder, self.rt().enter_static_call, &.{
                    self.ctx(), try self.cI32(function.module_id),
                });
            try self.check(enter);
            const capture_context = function.direct_captures orelse try self.nullPtr();
            const result = try llvm.call(self.builder, entry_fn, &.{
                self.ctx(),         capture_context,  prepared.fixed, try self.cI64(prepared.fixed_len),
                try self.nullPtr(), try self.cI64(0),
            });
            _ = if (same_module)
                try llvm.call(self.builder, self.rt().leave_local_static_call, &.{self.ctx()})
            else
                try llvm.call(self.builder, self.rt().leave_static_call, &.{self.ctx()});
            const raw_status = try llvm.extractValue(self.builder, result, 2);
            const status = try llvm.call(self.builder, self.rt().function_status, &.{ self.ctx(), raw_status });
            try self.check(status);
            return .{
                .ptr = try llvm.extractValue(self.builder, result, 0),
                .len = try llvm.extractValue(self.builder, result, 1),
                .owned = true,
            };
        }

        const result = if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_static_multi_tail, &.{
                self.ctx(),                           try self.cI32(self.staticCallModuleId(function)), entry_fn,                          function.captures_ptr,
                try self.cI64(function.captures_len), prepared.fixed,                                   try self.cI64(prepared.fixed_len), tail.ptr,
                tail.len,
            })
        else
            try llvm.call(self.builder, self.rt().call_static_multi, &.{
                self.ctx(),                           try self.cI32(self.staticCallModuleId(function)), entry_fn,                          function.captures_ptr,
                try self.cI64(function.captures_len), prepared.fixed,                                   try self.cI64(prepared.fixed_len),
            });
        try self.check(try llvm.extractValue(self.builder, result, 2));
        return .{
            .ptr = try llvm.extractValue(self.builder, result, 0),
            .len = try llvm.extractValue(self.builder, result, 1),
            .owned = true,
        };
    }

    fn emitFallbackMultiPrepared(self: *FnEmitter, callable: V, prepared: PreparedArgs) anyerror!MultiRef {
        const result = if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_multi_tail, &.{
                self.ctx(), callable, prepared.fixed, try self.cI64(prepared.fixed_len), tail.ptr, tail.len,
            })
        else
            try llvm.call(self.builder, self.rt().call_multi, &.{
                self.ctx(), callable, prepared.fixed, try self.cI64(prepared.fixed_len),
            });
        try self.check(try llvm.extractValue(self.builder, result, 2));
        return .{
            .ptr = try llvm.extractValue(self.builder, result, 0),
            .len = try llvm.extractValue(self.builder, result, 1),
            .owned = true,
        };
    }

    fn directStaticMulti(self: *FnEmitter, function: StaticFunctionRef, args_in: []const *lua.Expr) anyerror!MultiRef {
        const prepared = try self.prepareStaticArgs(args_in);
        const entry_fn = try self.module.functionValue(function.function_id);

        if (function.pristine_guard) |pristine| {
            const callable = function.guard_callable orelse return error.MissingPristineFallback;
            const ptr_slot = try self.ptrSlot();
            const len_slot = try self.i64Slot();
            const direct_block = try self.newBlock("pristine_export_multi");
            const fallback_block = try self.newBlock("pristine_export_multi_fallback");
            const join = try self.newBlock("pristine_export_multi_join");
            try llvm.condBr(self.builder, pristine, direct_block, fallback_block);

            llvm.position(self.builder, direct_block);
            const direct = try self.emitStaticMultiPrepared(function, entry_fn, prepared);
            try llvm.store(self.builder, direct.ptr, ptr_slot, 8);
            try llvm.store(self.builder, direct.len, len_slot, 8);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, fallback_block);
            const fallback = try self.emitFallbackMultiPrepared(callable, prepared);
            try llvm.store(self.builder, fallback.ptr, ptr_slot, 8);
            try llvm.store(self.builder, fallback.len, len_slot, 8);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, join);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return .{
                .ptr = try llvm.load(self.builder, self.ty().ptr, ptr_slot, 8),
                .len = try llvm.load(self.builder, self.ty().i64, len_slot, 8),
                .owned = true,
            };
        }

        if (function.guard_callable) |callable| {
            if (function.direct_captures != null and prepared.tail != null) {
                const fallback = try self.emitFallbackMultiPrepared(callable, prepared);
                if (prepared.tail) |tail| try self.freeMulti(tail);
                return fallback;
            }
            const ptr_slot = try self.ptrSlot();
            const len_slot = try self.i64Slot();
            const is_expected = try llvm.call(self.builder, self.rt().value_is_function_id, &.{
                callable, try self.cI32(function.function_id),
            });
            const direct_block = try self.newBlock("direct_export_multi");
            const fallback_block = try self.newBlock("dynamic_export_multi");
            const join = try self.newBlock("export_multi_join");
            const matches = try llvm.icmp(self.builder, .ne, is_expected, try self.cI8(0));
            try llvm.condBr(self.builder, matches, direct_block, fallback_block);

            llvm.position(self.builder, direct_block);
            const direct = try self.emitStaticMultiPrepared(function, entry_fn, prepared);
            try llvm.store(self.builder, direct.ptr, ptr_slot, 8);
            try llvm.store(self.builder, direct.len, len_slot, 8);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, fallback_block);
            const fallback = try self.emitFallbackMultiPrepared(callable, prepared);
            try llvm.store(self.builder, fallback.ptr, ptr_slot, 8);
            try llvm.store(self.builder, fallback.len, len_slot, 8);
            try llvm.br(self.builder, join);

            llvm.position(self.builder, join);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return .{
                .ptr = try llvm.load(self.builder, self.ty().ptr, ptr_slot, 8),
                .len = try llvm.load(self.builder, self.ty().i64, len_slot, 8),
                .owned = true,
            };
        }

        const result = try self.emitStaticMultiPrepared(function, entry_fn, prepared);
        if (prepared.tail) |tail| try self.freeMulti(tail);
        return result;
    }

    fn callFixed(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args_in: []const *lua.Expr, count: usize) anyerror!?V {
        if (try self.staticRequire(callee_expr, method, args_in)) |request|
            return self.directRequireFixed(request, count);
        if (method == null) if (try self.staticCallee(callee_expr)) |function|
            return self.directStaticFixed(function, args_in, count);

        const prepared = try self.prepareCall(callee_expr, method, args_in);
        const callee = try self.box(prepared.callee);
        if (count == 0) {
            const status = if (prepared.tail) |tail|
                try llvm.call(self.builder, self.rt().call_discard_tail, &.{
                    self.ctx(), callee, prepared.fixed, try self.cI64(prepared.fixed_len), tail.ptr, tail.len,
                })
            else
                try llvm.call(self.builder, self.rt().call_discard, &.{
                    self.ctx(), callee, prepared.fixed, try self.cI64(prepared.fixed_len),
                });
            try self.check(status);
            if (prepared.tail) |tail| try self.freeMulti(tail);
            return null;
        }

        const output = try self.valueArray(count);
        const status = if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_fixed_tail, &.{
                self.ctx(), callee,   prepared.fixed, try self.cI64(prepared.fixed_len),
                tail.ptr,   tail.len, output,         try self.cI64(count),
            })
        else
            try llvm.call(self.builder, self.rt().call_fixed, &.{
                self.ctx(), callee,               prepared.fixed, try self.cI64(prepared.fixed_len),
                output,     try self.cI64(count),
            });
        try self.check(status);
        if (prepared.tail) |tail| try self.freeMulti(tail);
        return output;
    }

    fn callMulti(self: *FnEmitter, callee_expr: *const lua.Expr, method: ?[]const u8, args_in: []const *lua.Expr) anyerror!MultiRef {
        if (try self.staticRequire(callee_expr, method, args_in)) |request|
            return .{ .ptr = try self.directRequireValue(request), .len = try self.cI64(1), .owned = false };
        if (method == null) if (try self.staticCallee(callee_expr)) |function|
            return self.directStaticMulti(function, args_in);

        const prepared = try self.prepareCall(callee_expr, method, args_in);
        const callee = try self.box(prepared.callee);
        const result = if (prepared.tail) |tail|
            try llvm.call(self.builder, self.rt().call_multi_tail, &.{
                self.ctx(), callee, prepared.fixed, try self.cI64(prepared.fixed_len), tail.ptr, tail.len,
            })
        else
            try llvm.call(self.builder, self.rt().call_multi, &.{
                self.ctx(), callee, prepared.fixed, try self.cI64(prepared.fixed_len),
            });
        if (prepared.tail) |tail| try self.freeMulti(tail);
        try self.check(try llvm.extractValue(self.builder, result, 2));
        return .{
            .ptr = try llvm.extractValue(self.builder, result, 0),
            .len = try llvm.extractValue(self.builder, result, 1),
            .owned = true,
        };
    }

    fn multi(self: *FnEmitter, value: *const lua.Expr) anyerror!MultiRef {
        return switch (value.*) {
            .call => |call| try self.callMulti(call.callee, null, call.args),
            .method_call => |call| try self.callMulti(call.object, call.method, call.args),
            .vararg => try self.varargs(),
            else => blk: {
                const one = try self.expr(value);
                break :blk .{ .ptr = try self.box(one), .len = try self.cI64(1), .owned = false };
            },
        };
    }

    fn expr(self: *FnEmitter, value: *const lua.Expr) anyerror!ValueRef {
        return switch (value.*) {
            .nil_lit => .nil,
            .bool_lit => |v| .{ .boolean = try self.cI1(v.value) },
            .number => |v| .{ .number = try self.numberOperand(v.raw) },
            .string => |v| .{ .string = try self.stringRef(v.value) },
            .name => |v| try self.loadResolved(try self.resolve(v.value)),
            .paren => |v| try self.expr(v.expr),
            .vararg => blk: {
                const out = try self.valueSlot();
                _ = try llvm.call(self.builder, self.rt().arg_get, &.{
                    self.args(), self.argsLen(), try self.cI64(self.info.params.len), out,
                });
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

    fn rhsFixed(self: *FnEmitter, values_in: []const *lua.Expr, needed: usize) anyerror!V {
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
                        for (0..remain) |j|
                            try self.copyValue(try self.arrayElem(out, oi + j), try self.arrayElem(results, j));
                    },
                    .method_call => |v| {
                        const results = (try self.callFixed(v.object, v.method, v.args, remain)) orelse unreachable;
                        for (0..remain) |j|
                            try self.copyValue(try self.arrayElem(out, oi + j), try self.arrayElem(results, j));
                    },
                    .vararg => {
                        for (0..remain) |j| {
                            _ = try llvm.call(self.builder, self.rt().arg_get, &.{
                                self.args(),                     self.argsLen(), try self.cI64(self.info.params.len + j),
                                try self.arrayElem(out, oi + j),
                            });
                        }
                    },
                    else => unreachable,
                }
                oi = needed;
                continue;
            }
            try self.copyValue(try self.arrayElem(out, oi), try self.box(try self.expr(value)));
            oi += 1;
        }
        while (oi < needed) : (oi += 1)
            _ = try llvm.call(self.builder, self.rt().value_nil, &.{try self.arrayElem(out, oi)});
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
                        _ = try llvm.call(self.builder, self.rt().arg_get, &.{
                            self.args(), self.argsLen(), try self.cI64(self.info.params.len + j), dst,
                        });
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
                const status = if (field.object == .table) blk: {
                    const key_name = field.key.bytes;
                    if (field.object.table.shape) |shape| if (shapeSlot(shape, key_name)) |slot|
                        break :blk try llvm.call(self.builder, self.rt().set_known_shape_field, &.{
                            self.ctx(),    object,                       try self.cI32(shape.id), try self.cI32(slot),
                            field.key.ptr, try self.cI64(field.key.len), boxed,
                        });
                    if (field.object.table.native_namespace) |namespace| if (static_fields.slotForName(namespace, key_name)) |slot|
                        break :blk try llvm.call(self.builder, self.rt().set_native_slot, &.{
                            self.ctx(),                   object, try self.cI32(slot), field.key.ptr,
                            try self.cI64(field.key.len), boxed,
                        });
                    break :blk try llvm.call(self.builder, self.rt().set_field, &.{
                        self.ctx(), object, field.key.ptr, try self.cI64(field.key.len), boxed,
                    });
                } else try llvm.call(self.builder, self.rt().set_field, &.{
                    self.ctx(), object, field.key.ptr, try self.cI64(field.key.len), boxed,
                });
                try self.check(status);
            },
            .index => |index| {
                const status = try llvm.call(self.builder, self.rt().set_index, &.{
                    self.ctx(), try self.box(index.object), try self.box(index.key), try self.box(value),
                });
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
            const result = try llvm.call(self.builder, self.rt().return_values, &.{
                self.ctx(), self.resultPtr(), self.resultLen(), self.args(), try self.cI64(0),
            });
            try llvm.ret(self.builder, result);
            return;
        }

        const prefix_count = values_in.len - 1;
        const last = values_in[values_in.len - 1];
        if (isMultiExpr(last)) {
            const prefix = try self.valueArray(prefix_count);
            for (values_in[0..prefix_count], 0..) |value, index|
                try self.copyValue(try self.arrayElem(prefix, index), try self.box(try self.expr(value)));
            const tail = try self.multi(last);
            const result = try llvm.call(self.builder, self.rt().return_join, &.{
                self.ctx(), self.resultPtr(),            self.resultLen(),
                prefix,     try self.cI64(prefix_count), tail.ptr,
                tail.len,
            });
            try self.freeMulti(tail);
            try llvm.ret(self.builder, result);
            return;
        }

        const fixed = try self.valueArray(values_in.len);
        for (values_in, 0..) |value, index|
            try self.copyValue(try self.arrayElem(fixed, index), try self.box(try self.expr(value)));
        const result = try llvm.call(self.builder, self.rt().return_values, &.{
            self.ctx(), self.resultPtr(), self.resultLen(), fixed, try self.cI64(values_in.len),
        });
        try llvm.ret(self.builder, result);
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
                try llvm.br(self.builder, target);
                return true;
            },
            .local_assign => |s| {
                if (s.names.len == 1 and s.values.len == 1 and s.values[0].* == .call and self.binding_next < self.info.bindings.len) {
                    const binding_info = self.info.bindings[self.binding_next];
                    const call = s.values[0].call;
                    if (!binding_info.mutated and !binding_info.captured)
                        if (try self.staticRequire(call.callee, null, call.args)) |request| {
                            const binding = try self.bindName(s.names[0]);
                            self.storage[binding] = .{ .static_module = try self.directStaticModuleRequire(request) };
                            return false;
                        };
                }
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
                try self.storeTarget(target, try self.expr(s.function));
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
                try self.storeResolved(.{ .local = binding }, try self.expr(s.function));
                return false;
            },
            .if_stmt => |s| return self.emitIf(s),
            .while_loop => |s| return self.emitWhile(s),
            .repeat_loop => |s| return self.emitRepeat(s),
            .numeric_for => |s| return self.emitNumericFor(s),
            .generic_for => |s| return self.emitGenericFor(s),
        }
    }

    fn coerceNumber(self: *FnEmitter, value: ValueRef) anyerror!V {
        if (value == .number) return value.number;
        const boxed = try self.box(value);
        const slot = try self.doubleSlot();
        const status = try llvm.call(self.builder, self.rt().require_number, &.{ self.ctx(), boxed, slot });
        try self.check(status);
        return llvm.load(self.builder, self.ty().double, slot, 8);
    }

    fn emitIf(self: *FnEmitter, s: anytype) anyerror!bool {
        var end_block: ?BB = null;
        var all_terminate = s.else_body != null;
        for (s.branches) |branch| {
            const then_block = try self.newBlock("if_then");
            const next_block = try self.newBlock("if_next");
            const condition = try self.truthy(try self.expr(branch.cond));
            try llvm.condBr(self.builder, condition, then_block, next_block);
            llvm.position(self.builder, then_block);
            const term = try self.scopedBlock(branch.body);
            all_terminate = all_terminate and term;
            if (!term) {
                if (end_block == null) end_block = try self.newBlock("if_end");
                try llvm.br(self.builder, end_block.?);
            }
            llvm.position(self.builder, next_block);
        }
        if (s.else_body) |body| {
            const term = try self.scopedBlock(body);
            all_terminate = all_terminate and term;
            if (!term) {
                if (end_block == null) end_block = try self.newBlock("if_end");
                try llvm.br(self.builder, end_block.?);
            }
        } else {
            if (end_block == null) end_block = try self.newBlock("if_end");
            try llvm.br(self.builder, end_block.?);
            all_terminate = false;
        }
        if (end_block) |end| llvm.position(self.builder, end);
        return all_terminate;
    }

    fn emitWhile(self: *FnEmitter, s: anytype) anyerror!bool {
        const cond_block = try self.newBlock("while_cond");
        const body_block = try self.newBlock("while_body");
        const end_block = try self.newBlock("while_end");
        try llvm.br(self.builder, cond_block);
        llvm.position(self.builder, cond_block);
        try llvm.condBr(self.builder, try self.truthy(try self.expr(s.cond)), body_block, end_block);
        llvm.position(self.builder, body_block);
        try self.breaks.append(self.a(), end_block);
        const term = try self.scopedBlock(s.body);
        _ = self.breaks.pop();
        if (!term) try llvm.br(self.builder, cond_block);
        llvm.position(self.builder, end_block);
        return false;
    }

    fn emitRepeat(self: *FnEmitter, s: anytype) anyerror!bool {
        const body_block = try self.newBlock("repeat_body");
        const cond_block = try self.newBlock("repeat_cond");
        const end_block = try self.newBlock("repeat_end");
        const mark = self.saves.items.len;
        defer self.endScope(mark);

        try llvm.br(self.builder, body_block);
        llvm.position(self.builder, body_block);
        try self.breaks.append(self.a(), end_block);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) try llvm.br(self.builder, cond_block);
        llvm.position(self.builder, cond_block);
        try llvm.condBr(self.builder, try self.truthy(try self.expr(s.cond)), end_block, body_block);
        llvm.position(self.builder, end_block);
        return false;
    }

    fn emitNumericFor(self: *FnEmitter, s: anytype) anyerror!bool {
        const start = try self.coerceNumber(try self.expr(s.start));
        const limit = try self.coerceNumber(try self.expr(s.limit));
        const step = if (s.step) |value| try self.coerceNumber(try self.expr(value)) else try self.cDouble(1.0);
        const current_slot = try self.doubleSlot();
        const limit_slot = try self.doubleSlot();
        const step_slot = try self.doubleSlot();
        try llvm.store(self.builder, start, current_slot, 8);
        try llvm.store(self.builder, limit, limit_slot, 8);
        try llvm.store(self.builder, step, step_slot, 8);

        const mark = self.saves.items.len;
        defer self.endScope(mark);
        const binding = try self.bindName(s.name);
        try self.initBinding(binding, .{ .number = try self.cDouble(0.0) });

        const cond_block = try self.newBlock("nfor_cond");
        const body_block = try self.newBlock("nfor_body");
        const end_block = try self.newBlock("nfor_end");
        try llvm.br(self.builder, cond_block);
        llvm.position(self.builder, cond_block);

        const current = try llvm.load(self.builder, self.ty().double, current_slot, 8);
        const lim = try llvm.load(self.builder, self.ty().double, limit_slot, 8);
        const stp = try llvm.load(self.builder, self.ty().double, step_slot, 8);
        const zero = try self.cDouble(0.0);
        const positive = try llvm.fcmp(self.builder, .ogt, stp, zero);
        const positive_ok = try llvm.fcmp(self.builder, .ole, current, lim);
        const negative_ok = try llvm.fcmp(self.builder, .oge, current, lim);
        const keep_going = try llvm.select(self.builder, positive, positive_ok, negative_ok);
        try llvm.condBr(self.builder, keep_going, body_block, end_block);

        llvm.position(self.builder, body_block);
        try self.storeResolved(.{ .local = binding }, .{ .number = current });
        try self.breaks.append(self.a(), end_block);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) {
            const old = try llvm.load(self.builder, self.ty().double, current_slot, 8);
            const delta = try llvm.load(self.builder, self.ty().double, step_slot, 8);
            try llvm.store(self.builder, try llvm.fadd(self.builder, old, delta), current_slot, 8);
            try llvm.br(self.builder, cond_block);
        }
        llvm.position(self.builder, end_block);
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

        const args_array = try self.valueArray(2);
        const arg0 = try self.arrayElem(args_array, 0);
        const arg1 = try self.arrayElem(args_array, 1);
        const results = try self.valueArray(s.names.len);
        const call_block = try self.newBlock("gfor_call");
        const body_block = try self.newBlock("gfor_body");
        const end_block = try self.newBlock("gfor_end");

        try llvm.br(self.builder, call_block);
        llvm.position(self.builder, call_block);
        try self.copyValue(arg0, state);
        try self.copyValue(arg1, control);
        const status = try llvm.call(self.builder, self.rt().call_fixed, &.{
            self.ctx(), iter, args_array, try self.cI64(2), results, try self.cI64(s.names.len),
        });
        try self.check(status);
        const first = try self.arrayElem(results, 0);
        const nil_raw = try llvm.call(self.builder, self.rt().value_is_nil, &.{first});
        const is_nil = try llvm.icmp(self.builder, .ne, nil_raw, try self.cI8(0));
        try llvm.condBr(self.builder, is_nil, end_block, body_block);

        llvm.position(self.builder, body_block);
        try self.copyValue(control, first);
        for (bindings, 0..) |binding, index|
            try self.storeResolved(.{ .local = binding }, .{ .boxed = try self.arrayElem(results, index) });
        try self.breaks.append(self.a(), end_block);
        const term = try self.block(s.body);
        _ = self.breaks.pop();
        if (!term) try llvm.br(self.builder, call_block);
        llvm.position(self.builder, end_block);
        return false;
    }

    fn emitInitialization(self: *FnEmitter) anyerror!void {
        for (self.info.upvalues, 0..) |_, index| {
            const status = try llvm.call(self.builder, self.rt().capture_cell, &.{
                self.ctx(), self.captures(), try self.cI32(index), self.upvalue_slots[index],
            });
            try self.check(status);
        }
        for (self.info.params, 0..) |name, index| {
            const binding = try self.bindName(name);
            const value = try llvm.call(self.builder, self.rt().arg_ptr, &.{
                self.args(), self.argsLen(), try self.cI64(index),
            });
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
    try function.finish();
}

fn generatedFunctionType(m: *const llvm.Module) anyerror!T {
    return m.functionType(m.types.function_result, &.{
        m.types.ptr, m.types.ptr, m.types.ptr, m.types.i64, m.types.ptr, m.types.i64,
    });
}

pub const AppendResult = struct {
    root_function: u32,
    function_count: u32,
};

pub const Batch = struct {
    module: llvm.Module,
    runtime: Runtime,

    pub fn init() anyerror!Batch {
        var module = try llvm.Module.init("dict_lua_batch");
        errdefer module.deinit();
        return .{
            .runtime = try Runtime.init(&module),
            .module = module,
        };
    }

    pub fn deinit(self: *Batch) void {
        self.module.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *Batch,
        allocator: A,
        globals: *const analysis.Globals,
        module: *const analysis.Module,
        facts: ProgramFacts,
    ) anyerror!AppendResult {
        const functions = try allocator.alloc(V, module.functions.items.len);
        errdefer allocator.free(functions);
        const function_base = module.functions.items[0].id;
        const function_ty = try generatedFunctionType(&self.module);
        for (module.functions.items, 0..) |info, index| {
            const name = try std.fmt.allocPrint(allocator, "lua_f_{d}", .{info.id});
            defer allocator.free(name);
            functions[index] = self.module.getFunction(name) orelse
                try self.module.addFunction(name, function_ty);
            const param_names = [_][]const u8{ "ctx", "captures", "args", "args_len", "result_ptr", "result_len" };
            for (param_names, 0..) |param_name, param_index|
                llvm.setName(try llvm.param(functions[index], param_index), param_name);
            if (info.direct_only) llvm.setLinkage(functions[index], .internal);
        }

        var emitter = ModuleEmitter{
            .allocator = allocator,
            .llvm_module = &self.module,
            .globals = globals,
            .module = module,
            .facts = facts,
            .runtime = self.runtime,
            .functions = functions,
            .function_base = function_base,
        };
        defer emitter.deinit();
        try emitter.collectStaticModules();

        for (module.functions.items, 0..) |info, index| {
            if (facts.synth_root and index == 0) continue;
            try emitFunction(&emitter, info);
        }
        return .{
            .root_function = module.root.id,
            .function_count = @intCast(module.functions.items.len),
        };
    }

    pub fn writeBitcode(self: *const Batch, allocator: A, path: []const u8) anyerror!void {
        if (std.debug.runtime_safety) try self.module.verify(allocator);
        try self.module.writeBitcode(allocator, path);
    }

    pub fn toText(self: *const Batch, allocator: A) anyerror![]u8 {
        return self.module.toText(allocator);
    }
};

pub fn generate(
    allocator: A,
    globals: *const analysis.Globals,
    module: *const analysis.Module,
    facts: ProgramFacts,
) anyerror!Generated {
    var batch = try Batch.init();
    errdefer batch.deinit();
    const result = try batch.append(allocator, globals, module, facts);
    if (std.debug.runtime_safety) try batch.module.verify(allocator);
    return .{
        .module = batch.module,
        .root_function = result.root_function,
        .function_count = result.function_count,
    };
}

test "direct LLVM module smoke" {
    const source = "local x=1; x=x+2; return x";
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var globals = try analysis.Globals.init(std.testing.allocator);
    defer globals.deinit();
    var module = try analysis.analyze(std.testing.allocator, &globals, &chunk, 0);
    defer module.deinit();
    var generated = try generate(std.testing.allocator, &globals, &module, .{});
    defer generated.deinit();
    const text_ir = try generated.toText(std.testing.allocator);
    defer std.testing.allocator.free(text_ir);
    try std.testing.expect(std.mem.indexOf(u8, text_ir, "define %FunctionResult @lua_f_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_ir, "fadd double") != null);
}
