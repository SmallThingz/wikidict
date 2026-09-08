const std = @import("std");
const ir = @import("vm_ir.zig");

// A fixed call does not use `c`; call_vararg does. Keep AOT-only hints
// inside that otherwise-dead operand so ordinary IR and bytecode do not grow.
const native_global_marker: u32 = @as(u32, 1) << 31;
const payload_mask = native_global_marker - 1;

pub fn target(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c == 0 or inst.c & native_global_marker != 0) return null;
    return inst.c - 1;
}

pub fn nativeGlobal(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c & native_global_marker == 0) return null;
    const payload = inst.c & payload_mask;
    return if (payload == 0) null else payload - 1;
}

pub fn set(inst: *ir.Inst, function_id: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    const encoded = std.math.add(u32, function_id, 1) catch return error.FunctionReferenceOverflow;
    if (encoded & native_global_marker != 0) return error.FunctionReferenceOverflow;
    inst.c = encoded;
}

pub fn setNativeGlobal(inst: *ir.Inst, slot: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    const payload = std.math.add(u32, slot, 1) catch return error.GlobalReferenceOverflow;
    if (payload > payload_mask) return error.GlobalReferenceOverflow;
    inst.c = native_global_marker | payload;
}

pub fn clear(inst: *ir.Inst) void {
    if (inst.op == .call) inst.c = 0;
}

test "fixed call hint is omitted from the instruction wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .b = 0, .aux = 0, .count = 1 };
    try set(&inst, 7);
    try std.testing.expectEqual(@as(?u32, 7), target(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(?u32, null), target(restored));
}

test "native global call hint is distinct and omitted from wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .count = 1 };
    try setNativeGlobal(&inst, 15);
    try std.testing.expectEqual(@as(?u32, null), target(inst));
    try std.testing.expectEqual(@as(?u32, 15), nativeGlobal(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(?u32, null), nativeGlobal(restored));
}
