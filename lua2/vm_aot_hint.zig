const std = @import("std");
const ir = @import("vm_ir.zig");
const static_fields = @import("vm_static_field_abi.zig");

// AOT-only call hints live outside semantic operands and are never serialized.
// Both fixed and vararg dynamic calls can therefore carry the same guard.
const native_marker: u32 = @as(u32, 1) << 31;
// Reserved invalid native-global encoding: compiler-only proof that the live value is callable.
const callable_marker: u32 = native_marker;
const native_field_marker: u32 = @as(u32, 1) << 30;
const native_payload_mask = native_field_marker - 1;
const namespace_shift = 16;
const field_slot_mask: u32 = (@as(u32, 1) << namespace_shift) - 1;
const candidate_namespace_encoded: u32 = (@as(u32, 1) << (30 - namespace_shift)) - 1;

fn supports(op: ir.Opcode) bool {
    return op == .call or op == .call_vararg;
}

pub const NativeField = struct {
    namespace: static_fields.Namespace,
    slot: u32,
};

pub fn target(inst: ir.Inst) ?u32 {
    if (!supports(inst.op) or inst.aot_hint == 0 or inst.aot_hint & native_marker != 0) return null;
    return inst.aot_hint - 1;
}

pub fn nativeGlobal(inst: ir.Inst) ?u32 {
    if (!supports(inst.op) or inst.aot_hint & native_marker == 0 or inst.aot_hint & native_field_marker != 0) return null;
    const payload = inst.aot_hint & native_payload_mask;
    return if (payload == 0) null else payload - 1;
}

pub fn nativeField(inst: ir.Inst) ?NativeField {
    if (!supports(inst.op) or inst.aot_hint & (native_marker | native_field_marker) != (native_marker | native_field_marker)) return null;
    const payload = inst.aot_hint & native_payload_mask;
    const namespace_encoded = payload >> namespace_shift;
    const slot_encoded = payload & field_slot_mask;
    if (namespace_encoded == 0 or slot_encoded == 0) return null;
    const namespace_raw = namespace_encoded - 1;
    if (namespace_raw >= @typeInfo(static_fields.Namespace).@"enum".fields.len) return null;
    return .{ .namespace = @enumFromInt(namespace_raw), .slot = slot_encoded - 1 };
}

pub fn nativeFieldCandidate(inst: ir.Inst) ?u32 {
    if (!supports(inst.op) or inst.aot_hint & (native_marker | native_field_marker) != (native_marker | native_field_marker)) return null;
    const payload = inst.aot_hint & native_payload_mask;
    const namespace_encoded = payload >> namespace_shift;
    const field_encoded = payload & field_slot_mask;
    if (namespace_encoded != candidate_namespace_encoded or field_encoded == 0) return null;
    const field_id = field_encoded - 1;
    return if (field_id < static_fields.names.len) field_id else null;
}

fn directAsHint(inst: ir.Inst) ir.Inst {
    var copy = inst;
    copy.aot_hint = inst.aot_direct;
    return copy;
}

pub fn directTarget(inst: ir.Inst) ?u32 {
    return target(directAsHint(inst));
}

pub fn directNativeGlobal(inst: ir.Inst) ?u32 {
    return nativeGlobal(directAsHint(inst));
}

pub fn directNativeField(inst: ir.Inst) ?NativeField {
    return nativeField(directAsHint(inst));
}

pub fn directCallable(inst: ir.Inst) bool {
    return supports(inst.op) and inst.aot_direct == callable_marker;
}

pub fn set(inst: *ir.Inst, function_id: u32) !void {
    if (!supports(inst.op)) return error.UnsupportedAotCallHint;
    const encoded = std.math.add(u32, function_id, 1) catch return error.FunctionReferenceOverflow;
    if (encoded & native_marker != 0) return error.FunctionReferenceOverflow;
    inst.aot_hint = encoded;
}

pub fn setNativeGlobal(inst: *ir.Inst, slot: u32) !void {
    if (!supports(inst.op)) return error.UnsupportedAotCallHint;
    const payload = std.math.add(u32, slot, 1) catch return error.GlobalReferenceOverflow;
    if (payload > native_payload_mask) return error.GlobalReferenceOverflow;
    inst.aot_hint = native_marker | payload;
}

pub fn setNativeField(inst: *ir.Inst, namespace: static_fields.Namespace, slot: u32) !void {
    if (!supports(inst.op)) return error.UnsupportedAotCallHint;
    const namespace_encoded = std.math.add(u32, @intFromEnum(namespace), 1) catch return error.NativeFieldReferenceOverflow;
    const slot_encoded = std.math.add(u32, slot, 1) catch return error.NativeFieldReferenceOverflow;
    if (slot_encoded > field_slot_mask or namespace_encoded >= (@as(u32, 1) << (30 - namespace_shift)))
        return error.NativeFieldReferenceOverflow;
    const payload = (namespace_encoded << namespace_shift) | slot_encoded;
    inst.aot_hint = native_marker | native_field_marker | payload;
}

pub fn setNativeFieldCandidate(inst: *ir.Inst, field_id: u32) !void {
    if (!supports(inst.op)) return error.UnsupportedAotCallHint;
    if (field_id >= static_fields.names.len) return error.NativeFieldReferenceOverflow;
    const field_encoded = std.math.add(u32, field_id, 1) catch return error.NativeFieldReferenceOverflow;
    if (field_encoded > field_slot_mask) return error.NativeFieldReferenceOverflow;
    inst.aot_hint = native_marker | native_field_marker | (candidate_namespace_encoded << namespace_shift) | field_encoded;
}

pub fn setDirectCallable(inst: *ir.Inst) !void {
    if (!supports(inst.op)) return error.UnsupportedAotCallHint;
    inst.aot_direct = callable_marker;
}

pub fn setDirect(inst: *ir.Inst, function_id: u32) !void {
    var copy = inst.*;
    try set(&copy, function_id);
    inst.aot_direct = copy.aot_hint;
}

pub fn setDirectNativeGlobal(inst: *ir.Inst, slot: u32) !void {
    var copy = inst.*;
    try setNativeGlobal(&copy, slot);
    inst.aot_direct = copy.aot_hint;
}

pub fn setDirectNativeField(inst: *ir.Inst, namespace: static_fields.Namespace, slot: u32) !void {
    var copy = inst.*;
    try setNativeField(&copy, namespace, slot);
    inst.aot_direct = copy.aot_hint;
}

pub fn clear(inst: *ir.Inst) void {
    if (!supports(inst.op)) return;
    inst.aot_hint = 0;
    inst.aot_direct = 0;
}

test "proven callable fact is compiler-only and omitted from wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .count = 1 };
    try setDirectCallable(&inst);
    try std.testing.expect(directCallable(inst));
    try std.testing.expectEqual(@as(?u32, null), directTarget(inst));
    try std.testing.expectEqual(@as(?u32, null), directNativeGlobal(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expect(!directCallable(restored));
}

test "proven call target is compiler-only and omitted from wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call, .dst = 1, .a = 2, .count = 1 };
    try setDirect(&inst, 7);
    try std.testing.expectEqual(@as(?u32, 7), directTarget(inst));
    try std.testing.expectEqual(@as(?u32, null), target(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(?u32, null), directTarget(restored));
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

test "vararg call hint preserves its semantic tail and stays out of wire format" {
    const wire = @import("vm_wire.zig");
    var inst = ir.Inst{ .op = .call_vararg, .dst = 1, .a = 2, .b = 1, .c = 7, .aux = 0, .count = ir.multi_count };
    try set(&inst, 9);
    try std.testing.expectEqual(@as(u32, 7), inst.c);
    try std.testing.expectEqual(@as(?u32, 9), target(inst));
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try wire.writeInst(&bytes, std.testing.allocator, 0, inst);
    var pos: usize = 0;
    const restored = try wire.readInst(bytes.items, &pos, 0, 1);
    try std.testing.expectEqual(@as(u32, 7), restored.c);
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
