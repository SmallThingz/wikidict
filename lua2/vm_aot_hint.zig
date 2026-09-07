const std = @import("std");
const ir = @import("vm_ir.zig");

// A fixed call does not use `c`; call_vararg does. Keep this AOT-only hint
// inside that otherwise-dead operand so ordinary IR and bytecode do not grow.
pub fn target(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c == 0) return null;
    return inst.c - 1;
}

pub fn set(inst: *ir.Inst, function_id: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    inst.c = std.math.add(u32, function_id, 1) catch return error.FunctionReferenceOverflow;
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
