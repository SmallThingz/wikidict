const std = @import("std");
const rt = @import("zig_runtime");
const value_leaf = @import("value_leaf.zig");
const static_decode = @import("lua_static_literal_decode");

comptime {
    if (@sizeOf(rt.Value) != 32 or @alignOf(rt.Value) != 8)
        @compileError("LLVM ABI requires the audited 32-byte, 8-byte-aligned runtime Value");
    if (@sizeOf(rt.Captures) != 24 or @alignOf(rt.Captures) != 8)
        @compileError("LLVM ABI requires the audited 24-byte, 8-byte-aligned Captures union");
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
    return value_leaf.argPtr(args, len, index);
}

test "argument and cell ABI leaf operations preserve borrowed pointers and boxed values" {
    const args = [_]rt.Value{ .{ .number = 3.5 }, .{ .string = "boxed" } };
    try std.testing.expect(dict_lua_arg_ptr(&args, args.len, 0) == &args[0]);
    try std.testing.expect(dict_lua_arg_ptr(&args, args.len, 1) == &args[1]);
    try std.testing.expect(dict_lua_arg_ptr(&args, args.len, 2).* == .nil);
    try std.testing.expect(dict_lua_arg_ptr(&args, args.len, 20).* == .nil);

    var value: rt.Value = .{ .boolean = true };
    dict_lua_arg_get(&args, args.len, 1, &value);
    try std.testing.expectEqualStrings("boxed", value.string);
    dict_lua_arg_get(&args, args.len, 2, &value);
    try std.testing.expect(value == .nil);

    var cell = rt.Cell{ .value = args[0] };
    dict_lua_cell_get(&cell, &value);
    try std.testing.expectEqual(@as(f64, 3.5), value.number);
    dict_lua_cell_set(&cell, &args[1]);
    dict_lua_cell_get(&cell, &value);
    try std.testing.expectEqualStrings("boxed", value.string);
    dict_lua_cell_set(&cell, &cell.value);
    try std.testing.expectEqualStrings("boxed", cell.value.string);
}

// The emitter borrows pointers only for stable native ABI globals.
export fn dict_lua_native_global_ptr(ctx: *const rt.Context, slot: u32) callconv(.c) *const rt.Value {
    if (slot >= rt.module_global_prefix_len or slot >= ctx.globals.len) return &nil_value;
    return &ctx.globals[slot];
}

test "native global pointer remains stable across sparse writes" {
    var ctx = try rt.Context.initProgram(std.testing.allocator, 193, 1);
    defer ctx.deinit();
    try ctx.setGlobal(64, .{ .number = 99 });
    try std.testing.expect(dict_lua_native_global_ptr(&ctx, 64).* == .nil);
    try ctx.enterStaticModule(0);
    defer ctx.leaveStaticFunction();
    const native = dict_lua_native_global_ptr(&ctx, 1);
    try ctx.setGlobal(1, .{ .number = 7 });
    try ctx.setGlobal(128, .{ .number = 8 });
    try std.testing.expectEqual(@as(f64, 7), native.number);
    try std.testing.expect(native == dict_lua_native_global_ptr(&ctx, 1));
    try std.testing.expectEqual(@as(f64, 99), ctx.getGlobal(64).number);
    try std.testing.expect(dict_lua_native_global_ptr(&ctx, 64).* == .nil);
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
    value_leaf.nil(out);
}
export fn dict_lua_value_bool(out: *rt.Value, raw: u8) callconv(.c) void {
    value_leaf.boolean(out, raw);
}
export fn dict_lua_value_number(out: *rt.Value, raw: f64) callconv(.c) void {
    value_leaf.number(out, raw);
}
export fn dict_lua_value_string(out: *rt.Value, ptr: [*]const u8, len: usize) callconv(.c) void {
    value_leaf.string(out, ptr, len);
}
export fn dict_lua_value_copy(out: *rt.Value, input: *const rt.Value) callconv(.c) void {
    value_leaf.copy(out, input);
}
export fn dict_lua_value_truthy(input: *const rt.Value) callconv(.c) u8 {
    return value_leaf.truthy(input);
}
export fn dict_lua_value_is_function_id(input: *const rt.Value, function_id: u32) callconv(.c) u8 {
    return value_leaf.isFunctionId(input, function_id);
}
export fn dict_lua_value_function_captures(input: *const rt.Value, function_id: u32) callconv(.c) ?*const rt.Captures {
    return value_leaf.functionCaptures(input, function_id);
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
    value_leaf.cellGet(cell, out);
}
export fn dict_lua_cell_set(cell: *rt.Cell, input: *const rt.Value) callconv(.c) void {
    value_leaf.cellSet(cell, input);
}
export fn dict_lua_direct_capture_cells(
    ctx: *rt.Context,
    captures: *const rt.Captures,
    expected_len: usize,
    out: *[*]const *rt.Cell,
) callconv(.c) u32 {
    const cells = switch (captures.*) {
        .direct => |direct_cells| direct_cells,
        .native => return fail(ctx, error.BadUpvalue),
    };
    if (cells.len < expected_len or (expected_len != 0 and cells.len == 0))
        return fail(ctx, error.BadUpvalue);
    out.* = cells.ptr;
    return 0;
}
export fn dict_lua_init_direct_captures(
    ctx: *rt.Context,
    captures_ptr: ?[*]const *rt.Cell,
    captures_len: usize,
    out: *rt.Captures,
) callconv(.c) u32 {
    const captures: []const *rt.Cell = if (captures_len == 0)
        &.{}
    else
        (captures_ptr orelse return fail(ctx, error.BadUpvalue))[0..captures_len];
    out.* = .{ .direct = captures };
    return 0;
}
export fn dict_lua_make_function(ctx: *rt.Context, id: u32, entry_raw: *const anyopaque, captures_ptr: ?[*]const *rt.Cell, captures_len: usize, out: *rt.Value) callconv(.c) u32 {
    const entry: rt.FunctionFn = @ptrCast(entry_raw);
    const captures: []const *rt.Cell = if (captures_len == 0) &.{} else (captures_ptr orelse return fail(ctx, error.BadUpvalue))[0..captures_len];
    out.* = ctx.makeFunction(id, entry, captures) catch |err| return fail(ctx, err);
    return 0;
}

fn fixedCall(ctx: *rt.Context, callable: rt.Value, args: []const rt.Value, out: []rt.Value) u32 {
    const result = ctx.callValueFixed(callable, args, out) catch |err| {
        @memset(out, .nil);
        return fail(ctx, err);
    };
    defer result.deinit();
    const n = @min(out.len, result.values.len);
    if (result.values.ptr != out.ptr) {
        if (n != 0) @memcpy(out[0..n], result.values[0..n]);
    }
    @memset(out[n..], .nil);
    return 0;
}
export fn dict_lua_enter_local_static_call(ctx: *rt.Context) callconv(.c) u32 {
    ctx.enterLocalStaticFunction() catch |err| return fail(ctx, err);
    return 0;
}

export fn dict_lua_leave_local_static_call(ctx: *rt.Context) callconv(.c) void {
    ctx.leaveLocalStaticFunction();
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
    const result = ctx.callStaticFunctionBuffered(module_id, entry, captures, args, out) catch |err| {
        @memset(out, .nil);
        return fail(ctx, err);
    };
    const owned = result.len != 0 and result.ptr != out.ptr;
    defer if (owned) rt.freeResults(result);
    const n = @min(out.len, result.len);
    if (result.ptr != out.ptr) {
        if (n != 0) @memcpy(out[0..n], result[0..n]);
    }
    @memset(out[n..], .nil);
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

fn returnCall(ctx: *rt.Context, callable: rt.Value, args: []const rt.Value, result_ptr: ?[*]rt.Value, result_len: usize) rt.FunctionResult {
    if (result_ptr) |ptr| {
        const out = ptr[0..result_len];
        const result = ctx.callValueFixed(callable, args, out) catch |err| {
            _ = fail(ctx, err);
            return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
        };
        defer result.deinit();
        const n = @min(result.values.len, out.len);
        if (n != 0 and result.values.ptr != out.ptr)
            @memcpy(out[0..n], result.values[0..n]);
        return .{ .values_ptr = if (n == 0) null else out.ptr, .values_len = n, .status = 0, .reserved = 0 };
    }
    const result = ctx.callValue(callable, args) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    return .{ .values_ptr = if (result.len == 0) null else result.ptr, .values_len = result.len, .status = 0, .reserved = 0 };
}

/// Forward a lone tail call directly into the current function's result buffer.
export fn dict_lua_return_call(ctx: *rt.Context, callable: *const rt.Value, args_ptr: [*]const rt.Value, args_len: usize, result_ptr: ?[*]rt.Value, result_len: usize) callconv(.c) rt.FunctionResult {
    return returnCall(ctx, callable.*, values(args_ptr, args_len), result_ptr, result_len);
}

export fn dict_lua_return_call_tail(ctx: *rt.Context, callable: *const rt.Value, fixed_ptr: [*]const rt.Value, fixed_len: usize, tail_ptr: [*]const rt.Value, tail_len: usize, result_ptr: ?[*]rt.Value, result_len: usize) callconv(.c) rt.FunctionResult {
    var storage: [8]rt.Value = undefined;
    const args = mergeCallArgs(values(fixed_ptr, fixed_len), values(tail_ptr, tail_len), &storage) catch |err| {
        _ = fail(ctx, err);
        return .{ .values_ptr = null, .values_len = 0, .status = 1, .reserved = 0 };
    };
    defer if (args.ptr != storage[0..].ptr) std.heap.smp_allocator.free(args);
    return returnCall(ctx, callable.*, args, result_ptr, result_len);
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

    dict_lua_value_nil(&value);
    try std.testing.expect(value == .nil);
    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_is_nil(&value));
    try std.testing.expectEqual(@as(u8, 0), dict_lua_value_truthy(&value));

    dict_lua_value_bool(&value, 0);
    try std.testing.expect(value == .boolean and !value.boolean);
    try std.testing.expectEqual(@as(u8, 0), dict_lua_value_truthy(&value));
    dict_lua_value_bool(&value, 42);
    try std.testing.expect(value == .boolean and value.boolean);
    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_truthy(&value));

    const text = "leaf-value";
    dict_lua_value_string(&value, text.ptr, text.len);
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(text, value.string);
    try std.testing.expectEqual(@intFromPtr(text.ptr), @intFromPtr(value.string.ptr));
    dict_lua_value_copy(&value, &value);
    try std.testing.expectEqualStrings(text, value.string);

    const nan = std.math.nan(f64);
    dict_lua_value_number(&value, nan);
    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_is_number(&value));
    try std.testing.expect(std.math.isNan(dict_lua_value_number_unchecked(&value)));
    dict_lua_value_nil(&value);
    try std.testing.expect(std.math.isNan(dict_lua_value_number_unchecked(&value)));
}

test "function status normalization leaves success inert and preserves errors" {
    var ctx = try rt.Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    ctx.depth = 7;
    ctx.last_error = .{ .string = "original Lua error" };
    try std.testing.expectEqual(@as(u32, 0), dict_lua_function_status(&ctx, 0));
    try std.testing.expect(ctx.aotErrorName() == null);
    try std.testing.expectEqual(@as(usize, 7), ctx.depth);
    try std.testing.expectEqualStrings("original Lua error", ctx.last_error.string);

    for ([_]u32{ 1, 2, std.math.maxInt(u32) }) |status| {
        ctx.clearAotErrorName();
        try std.testing.expectEqual(@as(u32, 1), dict_lua_function_status(&ctx, status));
        try std.testing.expectEqualStrings("AotCallFailed", ctx.aotErrorName().?);
        ctx.setAotErrorName("OriginalAotFailure");
        try std.testing.expectEqual(@as(u32, 1), dict_lua_function_status(&ctx, status));
        try std.testing.expectEqualStrings("OriginalAotFailure", ctx.aotErrorName().?);
        try std.testing.expectEqual(@as(u32, 0), dict_lua_function_status(&ctx, 0));
        try std.testing.expectEqualStrings("OriginalAotFailure", ctx.aotErrorName().?);
        try std.testing.expectEqual(@as(usize, 7), ctx.depth);
        try std.testing.expectEqualStrings("original Lua error", ctx.last_error.string);
    }
}

test "local static call depth remains balanced across normalized errors" {
    var ctx = try rt.Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    ctx.max_depth = 1;
    try std.testing.expectEqual(@as(u32, 0), dict_lua_enter_local_static_call(&ctx));
    try std.testing.expectEqual(@as(usize, 1), ctx.depth);
    try std.testing.expectEqual(@as(u32, 1), dict_lua_enter_local_static_call(&ctx));
    try std.testing.expectEqual(@as(usize, 1), ctx.depth);
    try std.testing.expectEqualStrings("CallDepth", ctx.aotErrorName().?);
    dict_lua_leave_local_static_call(&ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.depth);
    try std.testing.expectEqual(@as(u32, 1), dict_lua_function_status(&ctx, std.math.maxInt(u32)));
    try std.testing.expectEqualStrings("CallDepth", ctx.aotErrorName().?);
    try std.testing.expectEqual(@as(usize, 0), ctx.depth);

    ctx.clearAotErrorName();
    try std.testing.expectEqual(@as(u32, 0), dict_lua_enter_local_static_call(&ctx));
    dict_lua_leave_local_static_call(&ctx);
    try std.testing.expectEqual(@as(u32, 0), dict_lua_function_status(&ctx, 0));
    try std.testing.expect(ctx.aotErrorName() == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.depth);
}

test "callable leaf ABI preserves exact ID and live capture pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), 1);
    defer ctx.deinit();

    var first_cell = rt.Cell{ .value = .{ .number = 11 } };
    var second_cell = rt.Cell{ .value = .{ .number = 22 } };
    const first = try ctx.makeFunction(7, dict_lua_static_module_root_unreachable, &.{&first_cell});
    const second = try ctx.makeFunction(7, dict_lua_static_module_root_unreachable, &.{&second_cell});
    const no_capture = try ctx.makeFunction(7, dict_lua_static_module_root_unreachable, &.{});
    const missing: rt.Value = .nil;
    const native: rt.Value = .{ .callable = .{
        .env = rt.FunctionEnv.native(&first_cell),
        .entry = dict_lua_static_module_root_unreachable,
        .id = rt.native_function_id,
        .identity = 0,
    } };

    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_is_function_id(&first, 7));
    try std.testing.expectEqual(@as(u8, 0), dict_lua_value_is_function_id(&first, 8));
    try std.testing.expectEqual(@as(u8, 0), dict_lua_value_is_function_id(&missing, 7));
    const first_captures = dict_lua_value_function_captures(&first, 7) orelse return error.MissingFirstCaptures;
    const second_captures = dict_lua_value_function_captures(&second, 7) orelse return error.MissingSecondCaptures;
    try std.testing.expect(first_captures != second_captures);
    try std.testing.expect(first_captures.* == .direct and first_captures.direct.len == 1 and first_captures.direct[0] == &first_cell);
    try std.testing.expect(second_captures.* == .direct and second_captures.direct.len == 1 and second_captures.direct[0] == &second_cell);
    try std.testing.expect(dict_lua_value_function_captures(&first, 8) == null);
    try std.testing.expect(dict_lua_value_function_captures(&missing, 7) == null);
    try std.testing.expect(dict_lua_value_function_captures(&no_capture, 7) == null);
    try std.testing.expectEqual(@as(u8, 1), dict_lua_value_is_function_id(&native, rt.native_function_id));
    try std.testing.expect(dict_lua_value_function_captures(&native, rt.native_function_id) == null);
}

fn fixedCallTestCount(args: []const rt.Value) !usize {
    if (args.len == 0 or args[0] != .number) return error.TestCallFailed;
    return @intFromFloat(args[0].number);
}

fn fixedCallBufferedTest(_: ?*anyopaque, _: *rt.Context, args: []const rt.Value, buffer: ?[]rt.Value) ![]const rt.Value {
    const count = try fixedCallTestCount(args);
    if (count == 9) return error.TestCallFailed;
    const out = try rt.returnBuffer(buffer, count);
    for (out, 0..) |*value, index| value.* = .{ .number = @floatFromInt(index + 1) };
    return out;
}

fn fixedCallDirectTest(_: *rt.Context, _: rt.Captures, args: []const rt.Value, buffer: ?[]rt.Value) ![]const rt.Value {
    const count = try fixedCallTestCount(args);
    if (count == 9) return error.TestCallFailed;
    const out = try rt.returnBuffer(buffer, count);
    for (out, 0..) |*value, index| value.* = .{ .number = @floatFromInt(index + 1) };
    return out;
}

fn fixedCallOwnedTest(_: ?*anyopaque, _: *rt.Context, _: []const rt.Value) ![]const rt.Value {
    const out = try std.heap.smp_allocator.alloc(rt.Value, 3);
    for (out, 0..) |*value, index| value.* = .{ .number = @floatFromInt(index + 1) };
    return out;
}

test "fixed call results fill only missing slots for buffered owned and static calls" {
    var ctx = try rt.Context.init(std.testing.allocator, 0);
    defer ctx.deinit();
    const buffered = try ctx.newNativeBuffered(null, fixedCallBufferedTest);
    const owned = try ctx.newNative(null, fixedCallOwnedTest);
    const entry: rt.FunctionFn = rt.stabilizeBuffered(fixedCallDirectTest);
    const entry_raw: *const anyopaque = @ptrCast(entry);
    for ([_]usize{ 0, 1, 2, 3, 9 }) |count| {
        const args = [_]rt.Value{.{ .number = @floatFromInt(count) }};
        const old = rt.Value{ .string = "stale" };
        var out = [_]rt.Value{ old, old };
        const dynamic_status = fixedCall(&ctx, buffered, &args, &out);
        try std.testing.expectEqual(@as(u32, if (count == 9) 1 else 0), dynamic_status);
        for (out, 0..) |value, index| {
            if (count != 9 and index < count)
                try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), value.number)
            else
                try std.testing.expect(value == .nil);
        }
        out = .{ old, old };
        const static_status = staticFixedCall(&ctx, std.math.maxInt(u32), entry_raw, null, 0, &args, &out);
        try std.testing.expectEqual(dynamic_status, static_status);
        for (out, 0..) |value, index| {
            if (count != 9 and index < count)
                try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), value.number)
            else
                try std.testing.expect(value == .nil);
        }
    }
    var owned_out = [_]rt.Value{ .nil, .nil };
    try std.testing.expectEqual(@as(u32, 0), fixedCall(&ctx, owned, &.{}, &owned_out));
    try std.testing.expectEqual(@as(f64, 1), owned_out[0].number);
    try std.testing.expectEqual(@as(f64, 2), owned_out[1].number);
}
fn tailReturnTableCall(_: ?*anyopaque, _: *rt.Context, args: []const rt.Value, buffer: ?[]rt.Value) ![]const rt.Value {
    if (args.len != 2 or args[0] != .table or args[1] != .number) return error.TestCallFailed;
    const out = try rt.returnBuffer(buffer, 1);
    rt.storeReturn(out, 0, args[1]);
    return out;
}

test "tail return forwards actual arity and caller buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.init(arena.allocator(), 0);
    defer ctx.deinit();
    const buffered = try ctx.newNativeBuffered(null, fixedCallBufferedTest);
    const owned = try ctx.newNative(null, fixedCallOwnedTest);
    const stale = rt.Value{ .string = "stale" };
    var out = [_]rt.Value{ stale, stale };
    for ([_]usize{ 0, 1, 2, 3, 9 }) |count| {
        out = .{ stale, stale };
        const args = [_]rt.Value{.{ .number = @floatFromInt(count) }};
        const result = dict_lua_return_call(&ctx, &buffered, &args, args.len, &out, out.len);
        try std.testing.expectEqual(@as(u32, if (count == 9) 1 else 0), result.status);
        if (count == 9) continue;
        try std.testing.expectEqual(@min(count, out.len), result.values_len);
        for (out, 0..) |value, index| {
            if (index < result.values_len)
                try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), value.number)
            else
                try std.testing.expectEqualStrings("stale", value.string);
        }
    }
    out = .{ stale, stale };
    const clipped = dict_lua_return_call(&ctx, &owned, &.{}, 0, &out, out.len);
    try std.testing.expectEqual(@as(usize, 2), clipped.values_len);
    try std.testing.expectEqual(@as(f64, 2), out[1].number);
    const unbounded = dict_lua_return_call(&ctx, &owned, &.{}, 0, null, 0);
    try std.testing.expectEqual(@as(usize, 3), unbounded.values_len);
    rt.freeResults(unbounded.values_ptr.?[0..unbounded.values_len]);
    const zero = dict_lua_return_call(&ctx, &owned, &.{}, 0, &out, 0);
    try std.testing.expectEqual(@as(usize, 0), zero.values_len);
    try std.testing.expect(zero.values_ptr == null);

    const many_fixed = [_]rt.Value{.{ .number = 3 }} ** 8;
    const tail = [_]rt.Value{.{ .number = 4 }} ** 2;
    out = .{ stale, stale };
    const merged = dict_lua_return_call_tail(&ctx, &buffered, &many_fixed, many_fixed.len, &tail, tail.len, &out, out.len);
    try std.testing.expectEqual(@as(u32, 0), merged.status);
    try std.testing.expectEqual(@as(usize, 2), merged.values_len);
    try std.testing.expectEqual(@as(f64, 1), out[0].number);

    const mt = try ctx.newTable();
    const object = try ctx.newTable();
    object.metatable = mt;
    const table_method = try ctx.newNativeBuffered(null, tailReturnTableCall);
    try mt.rawSet(ctx.allocator, .{ .string = "__call" }, table_method);
    const callable = rt.Value{ .table = object };
    const table_args = [_]rt.Value{.{ .number = 1 }};
    const table_result = dict_lua_return_call(&ctx, &callable, &table_args, table_args.len, &out, out.len);
    try std.testing.expectEqual(@as(u32, 0), table_result.status);
    try std.testing.expectEqual(@as(usize, 1), table_result.values_len);
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
    defer {
        decoded.table.deinit(ctx.allocator);
        ctx.allocator.destroy(decoded.table);
    }
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
    return value_leaf.isNil(input);
}
export fn dict_lua_value_is_number(input: *const rt.Value) callconv(.c) u8 {
    return value_leaf.isNumber(input);
}
export fn dict_lua_value_number_unchecked(input: *const rt.Value) callconv(.c) f64 {
    return value_leaf.numberUnchecked(input);
}
export fn dict_lua_arg_get(args_ptr: [*]const rt.Value, args_len: usize, index: usize, out: *rt.Value) callconv(.c) void {
    value_leaf.argGet(args_ptr, args_len, index, out);
}
