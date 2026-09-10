const std = @import("std");
const ir = @import("vm_ir.zig");
const static_fields = @import("vm_static_field_abi.zig");

// A fixed call does not use `c`; call_vararg does. Keep AOT-only hints
// inside that otherwise-dead operand so ordinary IR and bytecode do not grow.
const native_marker: u32 = @as(u32, 1) << 31;
const native_field_marker: u32 = @as(u32, 1) << 30;
const native_payload_mask = native_field_marker - 1;
const namespace_shift = 16;
const field_slot_mask: u32 = (@as(u32, 1) << namespace_shift) - 1;
const candidate_namespace_encoded: u32 = (@as(u32, 1) << (30 - namespace_shift)) - 1;

pub const NativeField = struct {
    namespace: static_fields.Namespace,
    slot: u32,
};

pub fn target(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c == 0 or inst.c & native_marker != 0) return null;
    return inst.c - 1;
}

pub fn nativeGlobal(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c & native_marker == 0 or inst.c & native_field_marker != 0) return null;
    const payload = inst.c & native_payload_mask;
    return if (payload == 0) null else payload - 1;
}

pub fn nativeField(inst: ir.Inst) ?NativeField {
    if (inst.op != .call or inst.c & (native_marker | native_field_marker) != (native_marker | native_field_marker)) return null;
    const payload = inst.c & native_payload_mask;
    const namespace_encoded = payload >> namespace_shift;
    const slot_encoded = payload & field_slot_mask;
    if (namespace_encoded == 0 or slot_encoded == 0) return null;
    const namespace_raw = namespace_encoded - 1;
    if (namespace_raw >= @typeInfo(static_fields.Namespace).@"enum".fields.len) return null;
    return .{ .namespace = @enumFromInt(namespace_raw), .slot = slot_encoded - 1 };
}

pub fn nativeFieldCandidate(inst: ir.Inst) ?u32 {
    if (inst.op != .call or inst.c & (native_marker | native_field_marker) != (native_marker | native_field_marker)) return null;
    const payload = inst.c & native_payload_mask;
    const namespace_encoded = payload >> namespace_shift;
    const field_encoded = payload & field_slot_mask;
    if (namespace_encoded != candidate_namespace_encoded or field_encoded == 0) return null;
    const field_id = field_encoded - 1;
    return if (field_id < static_fields.names.len) field_id else null;
}

pub fn set(inst: *ir.Inst, function_id: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    const encoded = std.math.add(u32, function_id, 1) catch return error.FunctionReferenceOverflow;
    if (encoded & native_marker != 0) return error.FunctionReferenceOverflow;
    inst.c = encoded;
}

pub fn setNativeGlobal(inst: *ir.Inst, slot: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    const payload = std.math.add(u32, slot, 1) catch return error.GlobalReferenceOverflow;
    if (payload > native_payload_mask) return error.GlobalReferenceOverflow;
    inst.c = native_marker | payload;
}

pub fn setNativeField(inst: *ir.Inst, namespace: static_fields.Namespace, slot: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    const namespace_encoded = std.math.add(u32, @intFromEnum(namespace), 1) catch return error.NativeFieldReferenceOverflow;
    const slot_encoded = std.math.add(u32, slot, 1) catch return error.NativeFieldReferenceOverflow;
    if (slot_encoded > field_slot_mask or namespace_encoded >= (@as(u32, 1) << (30 - namespace_shift)))
        return error.NativeFieldReferenceOverflow;
    const payload = (namespace_encoded << namespace_shift) | slot_encoded;
    inst.c = native_marker | native_field_marker | payload;
}

pub fn setNativeFieldCandidate(inst: *ir.Inst, field_id: u32) !void {
    if (inst.op != .call) return error.UnsupportedAotCallHint;
    if (field_id >= static_fields.names.len) return error.NativeFieldReferenceOverflow;
    const field_encoded = std.math.add(u32, field_id, 1) catch return error.NativeFieldReferenceOverflow;
    if (field_encoded > field_slot_mask) return error.NativeFieldReferenceOverflow;
    inst.c = native_marker | native_field_marker | (candidate_namespace_encoded << namespace_shift) | field_encoded;
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

test "native field call hint is distinct and omitted from wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .count = 1 };
    try setNativeField(&inst, .string, 8);
    const field = nativeField(inst) orelse return error.MissingNativeFieldHint;
    try std.testing.expectEqual(static_fields.Namespace.string, field.namespace);
    try std.testing.expectEqual(@as(u32, 8), field.slot);
    try std.testing.expectEqual(@as(?u32, null), nativeGlobal(inst));
    try std.testing.expectEqual(@as(?u32, null), target(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(?NativeField, null), nativeField(restored));
}

test "native field candidate hint is distinct and omitted from wire format" {
    const wire = @import("vm_wire.zig");
    const field_id = static_fields.find("gsub") orelse return error.MissingStaticField;
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .count = 1 };
    try setNativeFieldCandidate(&inst, field_id);
    try std.testing.expectEqual(@as(?u32, field_id), nativeFieldCandidate(inst));
    try std.testing.expectEqual(@as(?NativeField, null), nativeField(inst));
    try std.testing.expectEqual(@as(?u32, null), nativeGlobal(inst));
    try std.testing.expectEqual(@as(?u32, null), target(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(?u32, null), nativeFieldCandidate(restored));
}
