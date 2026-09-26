//! Shared implementation of the small Value ABI primitives. The runtime
//! exports these through llvm_abi; the build-only bitcode root uses the same
//! functions so the optimizer sees the exact compiled union representation.
const std = @import("std");
const rt = @import("zig_runtime");

comptime {
    if (@sizeOf(rt.Value) != 32 or @alignOf(rt.Value) != 8)
        @compileError("LLVM Value ABI layout changed");
}

pub fn nil(out: *rt.Value) void {
    out.* = .nil;
}
pub fn boolean(out: *rt.Value, raw: u8) void {
    out.* = .{ .boolean = raw != 0 };
}
pub fn number(out: *rt.Value, raw: f64) void {
    out.* = .{ .number = raw };
}
pub fn string(out: *rt.Value, ptr: [*]const u8, len: usize) void {
    out.* = .{ .string = ptr[0..len] };
}
pub fn copy(out: *rt.Value, input: *const rt.Value) void {
    out.* = input.*;
}
pub fn truthy(input: *const rt.Value) u8 {
    return @intFromBool(input.*.truthy());
}
pub fn isFunctionId(input: *const rt.Value, function_id: u32) u8 {
    return @intFromBool(input.* == .callable and input.callable.id == function_id);
}

pub fn functionCaptures(input: *const rt.Value, function_id: u32) ?*const rt.Captures {
    if (input.* != .callable or input.callable.id != function_id) return null;
    return input.callable.capturesPtr();
}

pub fn isNil(input: *const rt.Value) u8 {
    return @intFromBool(input.* == .nil);
}
pub fn isNumber(input: *const rt.Value) u8 {
    return @intFromBool(input.* == .number);
}
pub fn numberUnchecked(input: *const rt.Value) f64 {
    return if (input.* == .number) input.number else std.math.nan(f64);
}

const nil_argument: rt.Value = .nil;

pub fn argPtr(args: [*]const rt.Value, len: usize, index: usize) *const rt.Value {
    return if (index < len) &args[index] else &nil_argument;
}

pub fn argGet(args: [*]const rt.Value, len: usize, index: usize, out: *rt.Value) void {
    out.* = if (index < len) args[index] else .nil;
}

pub fn cellGet(cell: *const rt.Cell, out: *rt.Value) void {
    out.* = cell.value;
}

pub fn cellSet(cell: *rt.Cell, input: *const rt.Value) void {
    cell.value = input.*;
}
