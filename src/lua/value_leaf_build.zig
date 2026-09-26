//! Build-only root for leaf Value helper bitcode. Do not link its object into
//! the worker; runtime/llvm_abi.zig supplies the external C symbols.
const rt = @import("zig_runtime");
const leaf = @import("runtime/value_leaf.zig");

export fn dict_lua_leaf_value_nil(out: *rt.Value) callconv(.c) void {
    leaf.nil(out);
}
export fn dict_lua_leaf_value_bool(out: *rt.Value, raw: u8) callconv(.c) void {
    leaf.boolean(out, raw);
}
export fn dict_lua_leaf_value_number(out: *rt.Value, raw: f64) callconv(.c) void {
    leaf.number(out, raw);
}
export fn dict_lua_leaf_value_string(out: *rt.Value, ptr: [*]const u8, len: usize) callconv(.c) void {
    leaf.string(out, ptr, len);
}
export fn dict_lua_leaf_value_copy(out: *rt.Value, input: *const rt.Value) callconv(.c) void {
    leaf.copy(out, input);
}
export fn dict_lua_leaf_value_truthy(input: *const rt.Value) callconv(.c) u8 {
    return leaf.truthy(input);
}
export fn dict_lua_leaf_value_is_function_id(input: *const rt.Value, function_id: u32) callconv(.c) u8 {
    return leaf.isFunctionId(input, function_id);
}
export fn dict_lua_leaf_value_function_captures(input: *const rt.Value, function_id: u32) callconv(.c) ?*const rt.Captures {
    return leaf.functionCaptures(input, function_id);
}
export fn dict_lua_leaf_value_is_nil(input: *const rt.Value) callconv(.c) u8 {
    return leaf.isNil(input);
}
export fn dict_lua_leaf_value_is_number(input: *const rt.Value) callconv(.c) u8 {
    return leaf.isNumber(input);
}
export fn dict_lua_leaf_value_number_unchecked(input: *const rt.Value) callconv(.c) f64 {
    return leaf.numberUnchecked(input);
}

export fn dict_lua_leaf_value_arg_ptr(args: [*]const rt.Value, len: usize, index: usize) callconv(.c) *const rt.Value {
    return leaf.argPtr(args, len, index);
}
export fn dict_lua_leaf_value_arg_get(args: [*]const rt.Value, len: usize, index: usize, out: *rt.Value) callconv(.c) void {
    leaf.argGet(args, len, index, out);
}
export fn dict_lua_leaf_value_cell_get(cell: *const rt.Cell, out: *rt.Value) callconv(.c) void {
    leaf.cellGet(cell, out);
}
export fn dict_lua_leaf_value_cell_set(cell: *rt.Cell, input: *const rt.Value) callconv(.c) void {
    leaf.cellSet(cell, input);
}
