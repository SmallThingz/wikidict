const std = @import("std");
const rt = @import("zig_runtime");
const static_decode = @import("lua_static_literal_decode");

comptime {
    if (@sizeOf(rt.Value) != 32 or @alignOf(rt.Value) != 8)
        @compileError("LLVM ABI requires the audited 32-byte, 8-byte-aligned runtime Value");
    if (@sizeOf(rt.FunctionResult) != 24 or @alignOf(rt.FunctionResult) != 8)
        @compileError("LLVM ABI requires the audited FunctionResult layout");
}

export fn dict_lua_static_module_root_unreachable(
    ctx: *rt.Context,
    _: *const rt.Captures,
    _: [*]const rt.Value,
    _: usize,
    _: ?[*]rt.Value,
    _: usize,
) callconv(.c) rt.FunctionResult {
    ctx.setAotErrorName("StaticModuleRootUnexpected");
    return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
}

pub const CallResult = extern struct {
    values_ptr: ?[*]const rt.Value,
    values_len: usize,
    status: u32,
    reserved: u32,
};

fn fail(ctx: *rt.Context, err: anyerror) u32 {
    if (ctx.aotErrorName() == null) ctx.setAotErrorName(@errorName(err));
    return 1;
}

export fn dict_lua_decode_static_literal(
    ctx: *rt.Context,
    ptr: [*]const u8,
    len: usize,
    out: *rt.Value,
) callconv(.c) u32 {
    out.* = static_decode.decode(ctx, ptr[0..len]) catch |err| return fail(ctx, err);
    return 0;
}

fn values(ptr: [*]const rt.Value, len: usize) []const rt.Value {
    return if (len == 0) &.{} else ptr[0..len];
}
const nil_value: rt.Value = .nil;

export fn dict_lua_arg_ptr(args: [*]const rt.Value, len: usize, index: usize) callconv(.c) *const rt.Value {
    return if (index < len) &args[index] else &nil_value;
}

export fn dict_lua_global_ptr(ctx: *const rt.Context, slot: u32) callconv(.c) *const rt.Value {
    if (slot >= ctx.globals.len) return &nil_value;
    return &ctx.globals[slot];
}
export fn dict_lua_observe_package(ctx: *rt.Context) callconv(.c) u32 {
    ctx.observePackage() catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_defer_require_module_id(ctx: *rt.Context, module_id: u32, out: *rt.Value) callconv(.c) u8 {
    const value = ctx.deferStaticRequire(module_id) orelse return 0;
    out.* = value;
    return 1;
}

export fn dict_lua_defer_require_module_ref(ctx: *rt.Context, module_id: u32, out: *rt.Value) callconv(.c) ?*const bool {
    return ctx.deferStaticRequireRef(module_id, out);
}

export fn dict_lua_module_value_sentinel(ctx: *const rt.Context, module_id: u32, value: *const rt.Value) callconv(.c) ?*const bool {
    return ctx.moduleValueSentinel(module_id, value.*);
}

export fn dict_lua_value_nil(out: *rt.Value) callconv(.c) void {
    out.* = .nil;
}
export fn dict_lua_value_bool(out: *rt.Value, raw: u8) callconv(.c) void {
    out.* = .{ .boolean = raw != 0 };
}
export fn dict_lua_value_number(out: *rt.Value, raw: f64) callconv(.c) void {
    out.* = .{ .number = raw };
}
export fn dict_lua_value_string(out: *rt.Value, ptr: [*]const u8, len: usize) callconv(.c) void {
    out.* = .{ .string = ptr[0..len] };
}
export fn dict_lua_value_copy(out: *rt.Value, input: *const rt.Value) callconv(.c) void {
    out.* = input.*;
}
export fn dict_lua_value_truthy(input: *const rt.Value) callconv(.c) u8 {
    return @intFromBool(input.*.truthy());
}
export fn dict_lua_value_is_function_id(input: *const rt.Value, function_id: u32) callconv(.c) u8 {
    return @intFromBool(input.* == .callable and input.callable.id == function_id);
}
export fn dict_lua_value_function_captures(input: *const rt.Value, function_id: u32) callconv(.c) ?*const rt.Captures {
    if (input.* != .callable or input.callable.id != function_id) return null;
    return input.callable.capturesPtr();
}
export fn dict_lua_value_to_number(input: *const rt.Value, out: *f64) callconv(.c) u8 {
    const n = rt.toNumber(input.*) orelse return 0;
    out.* = n;
    return 1;
}
export fn dict_lua_global_get(ctx: *rt.Context, slot: u32, out: *rt.Value) callconv(.c) u32 {
    const value = ctx.getGlobal(slot);
    if (value != .nil) {
        out.* = value;
        return 0;
    }
    const global = ctx.global_table orelse {
        out.* = .nil;
        return 0;
    };
    const key = global.fieldKey(slot) orelse {
        out.* = .nil;
        return 0;
    };
    out.* = ctx.getIndex(.{ .table = global }, key) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_global_set(ctx: *rt.Context, slot: u32, input: *const rt.Value) callconv(.c) u32 {
    if (ctx.getGlobal(slot) == .nil) if (ctx.global_table) |global| {
        if (global.metatable != null and global.fieldKey(slot) != null) {
            ctx.setIndex(.{ .table = global }, global.fieldKey(slot).?, input.*) catch |err| return fail(ctx, err);
            return 0;
        }
    };
    ctx.setGlobal(slot, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_require_module_id(ctx: *rt.Context, module_id: u32, name: [*]const u8, len: usize, out: *rt.Value) callconv(.c) u32 {
    out.* = ctx.requireModuleId(module_id, name[0..len]) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_preinitialize_special_module(
    ctx: *rt.Context,
    module_id: u32,
    snapshot_load_data: u32,
) callconv(.c) u32 {
    ctx.preinitializeSpecialModule(module_id, snapshot_load_data != 0) catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_preinitialize_module(
    ctx: *rt.Context,
    module_id: u32,
    snapshot_load_data: u32,
    values_ptr: ?[*]const rt.Value,
    values_len: usize,
    status: u32,
    reserved: u32,
) callconv(.c) u32 {
    if (reserved != 0 or status > 1) return fail(ctx, error.BadAotFunctionResult);
    if (status != 0) {
        if (ctx.aotErrorName() == null) ctx.setAotErrorName("AotCallFailed");
        return 1;
    }
    if (values_len != 0 and values_ptr == null) return fail(ctx, error.BadAotFunctionResult);
    const result = if (values_len == 0) &.{} else values_ptr.?[0..values_len];
    defer if (result.len != 0) rt.freeResults(result);
    var value: rt.Value = if (result.len == 0) .nil else result[0];
    if (value == .nil) value = .{ .boolean = true };
    ctx.preinitializeModule(module_id, value, snapshot_load_data != 0) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_new_table(ctx: *rt.Context, out: *rt.Value) callconv(.c) u32 {
    const table = ctx.newTable() catch |err| return fail(ctx, err);
    out.* = .{ .table = table };
    return 0;
}
export fn dict_lua_new_array_table(ctx: *rt.Context, capacity: u32, out: *rt.Value) callconv(.c) u32 {
    const table = ctx.newArrayTable(capacity) catch |err| return fail(ctx, err);
    out.* = .{ .table = table };
    return 0;
}
export fn dict_lua_new_shaped_table(ctx: *rt.Context, shape_id: u32, out: *rt.Value) callconv(.c) u32 {
    const table = ctx.newProgramShape(shape_id) catch |err| return fail(ctx, err);
    out.* = .{ .table = table };
    return 0;
}
export fn dict_lua_table_append(ctx: *rt.Context, table_value: *const rt.Value, input: *const rt.Value) callconv(.c) u32 {
    if (table_value.* != .table) return fail(ctx, error.IndexType);
    table_value.table.append(ctx.allocator, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_table_append_many(ctx: *rt.Context, table_value: *const rt.Value, ptr: [*]const rt.Value, len: usize) callconv(.c) u32 {
    if (table_value.* != .table) return fail(ctx, error.IndexType);
    for (values(ptr, len)) |value| table_value.table.append(ctx.allocator, value) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_get_index(ctx: *rt.Context, object: *const rt.Value, key: *const rt.Value, out: *rt.Value) callconv(.c) u32 {
    out.* = ctx.getIndex(object.*, key.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_set_index(ctx: *rt.Context, object: *const rt.Value, key: *const rt.Value, input: *const rt.Value) callconv(.c) u32 {
    ctx.setIndex(object.*, key.*, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_get_field(ctx: *rt.Context, object: *const rt.Value, name: [*]const u8, len: usize, out: *rt.Value) callconv(.c) u32 {
    out.* = ctx.getIndex(object.*, .{ .string = name[0..len] }) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_set_field(ctx: *rt.Context, object: *const rt.Value, name: [*]const u8, len: usize, input: *const rt.Value) callconv(.c) u32 {
    ctx.setIndex(object.*, .{ .string = name[0..len] }, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_set_shape_slot(ctx: *rt.Context, object: *const rt.Value, slot: u32, input: *const rt.Value) callconv(.c) u32 {
    if (object.* != .table) return fail(ctx, error.IndexType);
    object.table.rawSetSlot(slot, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_get_known_shape_field(ctx: *rt.Context, object: *const rt.Value, shape_id: u32, slot: u32, name: [*]const u8, len: usize, out: *rt.Value) callconv(.c) u32 {
    out.* = ctx.getProgramShapeField(object.*, shape_id, slot, name[0..len]) catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_set_known_shape_field(ctx: *rt.Context, object: *const rt.Value, shape_id: u32, slot: u32, name: [*]const u8, len: usize, input: *const rt.Value) callconv(.c) u32 {
    const key: rt.Value = .{ .string = name[0..len] };
    if (object.* == .table and shape_id < ctx.program_shapes.len and object.table.shape == &ctx.program_shapes[shape_id]) {
        if (object.table.rawGetSlot(slot) != null or object.table.metatable == null) {
            object.table.rawSetSlot(slot, input.*) catch |err| return fail(ctx, err);
            return 0;
        }
    }
    ctx.setIndex(object.*, key, input.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_get_native_slot(ctx: *rt.Context, object: *const rt.Value, slot: u32, name: [*]const u8, len: usize, out: *rt.Value) callconv(.c) u32 {
    const key: rt.Value = .{ .string = name[0..len] };
    if (object.* == .table) if (object.table.fieldKey(slot)) |field_key| {
        if (rt.rawEqual(field_key, key)) {
            if (object.table.rawGetSlot(slot)) |value| {
                out.* = value;
                return 0;
            }
            if (object.table.metatable == null) {
                out.* = .nil;
                return 0;
            }
        }
    };
    out.* = ctx.getIndex(object.*, key) catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_set_native_slot(ctx: *rt.Context, object: *const rt.Value, slot: u32, name: [*]const u8, len: usize, input: *const rt.Value) callconv(.c) u32 {
    const key: rt.Value = .{ .string = name[0..len] };
    if (object.* == .table) if (object.table.fieldKey(slot)) |field_key| {
        if (rt.rawEqual(field_key, key) and (object.table.rawGetSlot(slot) != null or object.table.metatable == null)) {
            object.table.rawSetSlot(slot, input.*) catch |err| return fail(ctx, err);
            return 0;
        }
    };
    ctx.setIndex(object.*, key, input.*) catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_len_number(ctx: *rt.Context, input: *const rt.Value, out: *f64) callconv(.c) u32 {
    out.* = switch (input.*) {
        .string => |s| @floatFromInt(s.len),
        .table => |t| @floatFromInt(t.rawLen()),
        else => return fail(ctx, error.LengthType),
    };
    return 0;
}
fn arithOp(raw: u8) ?rt.ArithOp {
    return switch (raw) {
        0 => .add,
        1 => .sub,
        2 => .mul,
        3 => .div,
        4 => .mod,
        5 => .pow,
        else => null,
    };
}
fn compareOp(raw: u8) ?rt.CompareOp {
    return switch (raw) {
        0 => .eq,
        1 => .ne,
        2 => .lt,
        3 => .le,
        4 => .gt,
        5 => .ge,
        else => null,
    };
}
export fn dict_lua_neg(ctx: *rt.Context, input: *const rt.Value, out: *rt.Value) callconv(.c) u32 {
    const n = rt.toNumber(input.*) orelse return fail(ctx, error.ArithmeticType);
    out.* = .{ .number = -n };
    return 0;
}
export fn dict_lua_binary(ctx: *rt.Context, op: u8, lhs: *const rt.Value, rhs: *const rt.Value, out: *rt.Value) callconv(.c) u32 {
    const decoded = arithOp(op) orelse return fail(ctx, error.InvalidArithmeticOp);
    out.* = ctx.binaryArith(decoded, lhs.*, rhs.*) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_compare_bool(ctx: *rt.Context, op: u8, lhs: *const rt.Value, rhs: *const rt.Value, out: *u8) callconv(.c) u32 {
    const decoded = compareOp(op) orelse return fail(ctx, error.InvalidCompareOp);
    out.* = @intFromBool(ctx.comparison(decoded, lhs.*, rhs.*) catch |err| return fail(ctx, err));
    return 0;
}
export fn dict_lua_concat(ctx: *rt.Context, ptr: [*]const rt.Value, len: usize, out: *rt.Value) callconv(.c) u32 {
    out.* = ctx.concatValues(values(ptr, len)) catch |err| return fail(ctx, err);
    return 0;
}
export fn dict_lua_cell_new(ctx: *rt.Context, initial: *const rt.Value, out: **rt.Cell) callconv(.c) u32 {
    const cell = ctx.allocator.create(rt.Cell) catch |err| return fail(ctx, err);
    cell.* = .{ .value = initial.* };
    out.* = cell;
    return 0;
}
export fn dict_lua_cell_get(cell: *const rt.Cell, out: *rt.Value) callconv(.c) void {
    out.* = cell.value;
}
export fn dict_lua_cell_set(cell: *rt.Cell, input: *const rt.Value) callconv(.c) void {
    cell.value = input.*;
}
export fn dict_lua_capture_cell(ctx: *rt.Context, captures: *const rt.Captures, ordinal: u32, out: **rt.Cell) callconv(.c) u32 {
    const cell = captures.cell(ordinal) catch |err| return fail(ctx, err);
    out.* = cell;
    return 0;
}
export fn dict_lua_make_function(ctx: *rt.Context, id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, out: *rt.Value) callconv(.c) u32 {
    const entry: rt.FunctionFn = @ptrCast(entry_raw);
    const captures: []const *rt.Cell = if (captures_len == 0) &.{} else (captures_ptr orelse return fail(ctx, error.BadUpvalue))[0..captures_len];
    out.* = ctx.makeFunction(id, entry, captures) catch |err| return fail(ctx, err);
    return 0;
}

fn fixedCall(ctx: *rt.Context, callable: rt.Value, args: []const rt.Value, out: []rt.Value) u32 {
    @memset(out, .nil);
    const result = ctx.callValueFixed(callable, args, out) catch |err| return fail(ctx, err);
    defer result.deinit();
    if (result.values.ptr != out.ptr) {
        const n = @min(out.len, result.values.len);
        @memcpy(out[0..n], result.values[0..n]);
    }
    return 0;
}
export fn dict_lua_enter_static_call(ctx: *rt.Context, module_id: u32) callconv(.c) u32 {
    ctx.enterStaticModule(module_id) catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_leave_static_call(ctx: *rt.Context) callconv(.c) void {
    ctx.leaveStaticFunction();
}

export fn dict_lua_function_status(ctx: *rt.Context, status: u32) callconv(.c) u32 {
    if (status == 0) return 0;
    if (ctx.aotErrorName() == null) ctx.setAotErrorName("AotCallFailed");
    return 1;
}

fn captureSlice(ptr: ?[*]const *rt.Cell, len: usize) ?[]const *rt.Cell {
    if (len == 0) return &.{};
    return (ptr orelse return null)[0..len];
}

fn staticFixedCall(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, args: []const rt.Value, out: []rt.Value) u32 {
    const captures = captureSlice(captures_ptr, captures_len) orelse return fail(ctx, error.BadUpvalue);
    const entry: rt.FunctionFn = @ptrCast(entry_raw);
    @memset(out, .nil);
    const result = ctx.callStaticFunctionBuffered(module_id, entry, captures, args, out) catch |err| return fail(ctx, err);
    const owned = result.len != 0 and result.ptr != out.ptr;
    defer if (owned) rt.freeResults(result);
    if (result.ptr != out.ptr) {
        const n = @min(out.len, result.len);
        if (n != 0) @memcpy(out[0..n], result[0..n]);
    }
    return 0;
}

export fn dict_lua_call_static_fixed(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, args_ptr: [*]const rt.Value, args_len: usize, out_ptr: [*]rt.Value, out_len: usize) callconv(.c) u32 {
    return staticFixedCall(ctx, module_id, entry_raw, captures_ptr, captures_len, values(args_ptr, args_len), out_ptr[0..out_len]);
}

export fn dict_lua_call_fixed(ctx: *rt.Context, callable: *const rt.Value, args_ptr: [*]const rt.Value, args_len: usize, out_ptr: [*]rt.Value, out_len: usize) callconv(.c) u32 {
    return fixedCall(ctx, callable.*, values(args_ptr, args_len), out_ptr[0..out_len]);
}
fn mergeCallArgs(fixed: []const rt.Value, tail: []const rt.Value, storage: []rt.Value) ![]rt.Value {
    const total = fixed.len + tail.len;
    if (total <= storage.len) {
        @memcpy(storage[0..fixed.len], fixed);
        @memcpy(storage[fixed.len..total], tail);
        return storage[0..total];
    }
    const merged = try std.heap.smp_allocator.alloc(rt.Value, total);
    @memcpy(merged[0..fixed.len], fixed);
    @memcpy(merged[fixed.len..], tail);
    return merged;
}

export fn dict_lua_call_static_fixed_tail(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize, out_ptr: [*]rt.Value, out_len: usize) callconv(.c) u32 {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| return fail(ctx, err);
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    return staticFixedCall(ctx, module_id, entry_raw, captures_ptr, captures_len, args, out_ptr[0..out_len]);
}

fn staticMultiResult(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, args: []const rt.Value) CallResult {
    const captures = captureSlice(captures_ptr, captures_len) orelse {
        _ = fail(ctx, error.BadUpvalue);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    const entry: rt.FunctionFn = @ptrCast(entry_raw);
    const result = ctx.callStaticFunctionBuffered(module_id, entry, captures, args, null) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    return .{ .values_ptr = if (result.len == 0) null else result.ptr, .values_len = result.len, .status = 0, .reserved = 0 };
}

export fn dict_lua_call_static_multi(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, args_ptr: [*]const rt.Value, args_len: usize) callconv(.c) CallResult {
    return staticMultiResult(ctx, module_id, entry_raw, captures_ptr, captures_len, values(args_ptr, args_len));
}

export fn dict_lua_call_static_multi_tail(ctx: *rt.Context, module_id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize) callconv(.c) CallResult {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    return staticMultiResult(ctx, module_id, entry_raw, captures_ptr, captures_len, args);
}

export fn dict_lua_call_fixed_tail(ctx: *rt.Context, callable: *const rt.Value, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize, out_ptr: [*]rt.Value, out_len: usize) callconv(.c) u32 {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| return fail(ctx, err);
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    return fixedCall(ctx, callable.*, args, out_ptr[0..out_len]);
}

export fn dict_lua_call_discard(ctx: *rt.Context, callable: *const rt.Value, args_ptr: [*]const rt.Value, args_len: usize) callconv(.c) u32 {
    const result = ctx.callValue(callable.*, values(args_ptr, args_len)) catch |err| return fail(ctx, err);
    rt.freeResults(result);
    return 0;
}
export fn dict_lua_call_discard_tail(ctx: *rt.Context, callable: *const rt.Value, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize) callconv(.c) u32 {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| return fail(ctx, err);
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    const result = ctx.callValue(callable.*, args) catch |err| return fail(ctx, err);
    rt.freeResults(result);
    return 0;
}

fn multiResult(ctx: *rt.Context, callable: rt.Value, args: []const rt.Value) CallResult {
    const result = ctx.callValue(callable, args) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    return .{
        .values_ptr = if (result.len == 0) null else result.ptr,
        .values_len = result.len,
        .status = 0,
        .reserved = 0,
    };
}

export fn dict_lua_call_multi(ctx: *rt.Context, callable: *const rt.Value, args_ptr: [*]const rt.Value, args_len: usize) callconv(.c) CallResult {
    return multiResult(ctx, callable.*, values(args_ptr, args_len));
}
export fn dict_lua_call_multi_tail(ctx: *rt.Context, callable: *const rt.Value, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize) callconv(.c) CallResult {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    return multiResult(ctx, callable.*, args);
}

export fn dict_lua_results_free(ptr: ?[*]const rt.Value, len: usize) callconv(.c) void {
    if (len == 0) return;
    rt.freeResults((ptr orelse return)[0..len]);
}

fn returnSlice(result_ptr: ?[*]rt.Value, result_len: usize, wanted: usize) ![]rt.Value {
    if (result_ptr) |ptr| return ptr[0..@min(result_len, wanted)];
    return std.heap.smp_allocator.alloc(rt.Value, wanted);
}

export fn dict_lua_return_values(ctx: *rt.Context, result_ptr: ?[*]rt.Value, result_len: usize, input_ptr: [*]const rt.Value, input_len: usize) callconv(.c) rt.FunctionResult {
    const out = returnSlice(result_ptr, result_len, input_len) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    const n = @min(out.len, input_len);
    if (n != 0) @memcpy(out[0..n], input_ptr[0..n]);
    return .{ .values_ptr = if (out.len == 0) null else out.ptr, .values_len = out.len, .status = 0, .reserved = 0 };
}
export fn dict_lua_return_join(ctx: *rt.Context, result_ptr: ?[*]rt.Value, result_len: usize, prefix_ptr: [*]const rt.Value, prefix_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize) callconv(.c) rt.FunctionResult {
    const wanted = prefix_len + tail_len;
    const out = returnSlice(result_ptr, result_len, wanted) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    const first = @min(out.len, prefix_len);
    if (first != 0) @memcpy(out[0..first], prefix_ptr[0..first]);
    if (out.len > first) {
        const n = @min(out.len - first, tail_len);
        if (n != 0) @memcpy(out[first..][0..n], tail_ptr[0..n]);
    }
    return .{ .values_ptr = if (out.len == 0) null else out.ptr, .values_len = out.len, .status = 0, .reserved = 0 };
}

export fn dict_lua_function_error() callconv(.c) rt.FunctionResult {
    return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
}

test "LLVM ABI layouts and primitive helpers" {
    var ctx = try rt.Context.init(std.testing.allocator, 1);
    defer ctx.deinit();
    var value: rt.Value = undefined;
    dict_lua_value_number(&value, 7);
    try std.testing.expectEqual(@as(f64, 7), value.number);
    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_truthy(&value));
}
test "static literal decoder materializes list named and keyed fields" {
    const static_literal = @import("lua_static_literal_format");
    const W = struct {
        fn writeU32(out: *std.ArrayList(u8), value: u32) !void {
            var raw: [4]u8 = undefined;
            std.mem.writeInt(u32, &raw, value, .little);
            try out.appendSlice(std.testing.allocator, &raw);
        }
        fn writeU64(out: *std.ArrayList(u8), value: u64) !void {
            var raw: [8]u8 = undefined;
            std.mem.writeInt(u64, &raw, value, .little);
            try out.appendSlice(std.testing.allocator, &raw);
        }
        fn string(out: *std.ArrayList(u8), value: []const u8) !void {
            try writeU32(out, @intCast(value.len));
            try out.appendSlice(std.testing.allocator, value);
        }
    };

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.ValueTag.table));
    try W.writeU32(&bytes, static_literal.no_shape);
    try W.writeU32(&bytes, 3);
    try W.writeU32(&bytes, 1);

    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.FieldTag.list));
    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.ValueTag.string));
    try W.string(&bytes, "one");

    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.FieldTag.named));
    try W.string(&bytes, "flag");
    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.ValueTag.true_));

    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.FieldTag.keyed));
    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.ValueTag.number));
    try W.writeU64(&bytes, @bitCast(@as(f64, 2)));
    try bytes.append(std.testing.allocator, @intFromEnum(static_literal.ValueTag.string));
    try W.string(&bytes, "two");

    var ctx = try rt.Context.init(std.testing.allocator, 1);
    defer ctx.deinit();
    var decoded: rt.Value = undefined;
    try std.testing.expectEqual(
        @as(u32, 0),
        dict_lua_decode_static_literal(&ctx, bytes.items.ptr, bytes.items.len, &decoded),
    );
    try std.testing.expect(decoded == .table);
    try std.testing.expectEqualStrings(
        "one",
        decoded.table.rawGet(.{ .number = 1 }).?.string,
    );
    try std.testing.expectEqual(true, decoded.table.rawGet(.{ .string = "flag" }).?.boolean);
    try std.testing.expectEqualStrings(
        "two",
        decoded.table.rawGet(.{ .number = 2 }).?.string,
    );
}

export fn dict_lua_require_number(ctx: *rt.Context, input: *const rt.Value, out: *f64) callconv(.c) u32 {
    out.* = rt.toNumber(input.*) orelse return fail(ctx, error.ArithmeticType);
    return 0;
}
export fn dict_lua_value_is_nil(input: *const rt.Value) callconv(.c) u8 {
    return @intFromBool(input.* == .nil);
}
export fn dict_lua_value_is_number(input: *const rt.Value) callconv(.c) u8 {
    return @intFromBool(input.* == .number);
}
export fn dict_lua_value_number_unchecked(input: *const rt.Value) callconv(.c) f64 {
    return if (input.* == .number) input.number else std.math.nan(f64);
}
export fn dict_lua_arg_get(args_ptr: [*]const rt.Value, args_len: usize, index: usize, out: *rt.Value) callconv(.c) void {
    out.* = if (index < args_len) args_ptr[index] else .nil;
}
