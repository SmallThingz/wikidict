const refs = @import("vm_ref.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const sem = @import("vm_semantics.zig");
pub fn putVar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 128) : (v >>= 7) try out.append(allocator, @intCast((v & 127) | 128));
    try out.append(allocator, @intCast(v));
}
pub fn getVar(bytes: []const u8, pos: *usize) !u64 {
    var value: u64 = 0;
    for (0..10) |i| {
        if (pos.* >= bytes.len) return error.Truncated;
        const byte = bytes[pos.*];
        pos.* += 1;
        if (i == 9 and byte > 1) return error.BadVarint;
        value |= @as(u64, byte & 127) << @as(u6, @intCast(i * 7));
        if (byte & 128 == 0) return value;
    }
    return error.BadVarint;
}
pub fn asU32(value: u64) !u32 {
    return std.math.cast(u32, value) orelse error.IntegerOverflow;
}
pub fn zigzag(value: i64) u64 {
    return (@as(u64, @bitCast(value)) << 1) ^ @as(u64, @bitCast(value >> 63));
}
pub fn unzigzag(value: u64) i64 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}
fn registerMask(inst: ir.Inst, include_ignored: bool) u8 {
    const d = sem.info(inst.op);
    var mask = d.reads;
    if (d.defines or (d.results and (include_ignored or inst.count != 0))) mask |= sem.dst;
    switch (inst.op) {
        .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => mask |= sem.dst,
        else => {},
    }
    return mask;
}

fn metadataMask(inst: ir.Inst) u8 {
    var mask = sem.info(inst.op).fields & ~registerMask(inst, true);
    if (inst.op == .load_bool) mask &= ~sem.a;
    return mask;
}
pub fn writeInst(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pc: u32, inst: ir.Inst) !void {
    const description = sem.info(inst.op);
    const regs = registerMask(inst, false);
    var packed_regs = @popCount(regs) >= 2;
    inline for (sem.fields, 0..) |field, i| if (regs & (@as(u8, 1) << i) != 0 and @field(inst, field) > 15) {
        packed_regs = false;
    };
    const flag = if (inst.op == .load_bool) inst.a != 0 else packed_regs;
    try out.append(allocator, @intFromEnum(inst.op) | (if (flag) @as(u8, 128) else 0));
    const metadata = metadataMask(inst);
    inline for (sem.fields, 0..) |field, i| if (metadata & (@as(u8, 1) << i) != 0) {
        var value: u64 = @field(inst, field);
        if (comptime std.mem.eql(u8, field, "count")) {
            if (description.results) value = if (inst.count == ir.multi_count) 0 else @as(u64, inst.count) + 1;
        }
        if (comptime std.mem.eql(u8, field, "aux")) {
            if (description.target) value = zigzag(@as(i64, inst.aux) - @as(i64, pc) - 1);
        }
        try putVar(out, allocator, value);
    };
    var pending: ?u8 = null;
    inline for (sem.fields, 0..) |field, i| if (regs & (@as(u8, 1) << i) != 0) {
        const value = @field(inst, field);
        if (!packed_regs) try putVar(out, allocator, if (refs.mask(inst.op) & (@as(u8, 1) << i) != 0) try refs.encode(value) else value) else if (pending) |lo| {
            try out.append(allocator, lo | (@as(u8, @intCast(value)) << 4));
            pending = null;
        } else pending = @intCast(value);
    };
    if (pending) |lo| try out.append(allocator, lo);
}
pub fn readInst(bytes: []const u8, pos: *usize, pc: u32, instruction_count: u32) !ir.Inst {
    return readInstVersion(bytes, pos, pc, instruction_count, true);
}
pub fn readInstVersion(bytes: []const u8, pos: *usize, pc: u32, instruction_count: u32, use_references: bool) !ir.Inst {
    if (pos.* >= bytes.len) return error.Truncated;
    const tag = bytes[pos.*];
    pos.* += 1;
    if ((tag & 127) >= @typeInfo(ir.Opcode).@"enum".fields.len) return error.BadOpcode;
    var inst = ir.Inst{ .op = @enumFromInt(tag & 127) };
    const description = sem.info(inst.op);
    const metadata = metadataMask(inst);
    inline for (sem.fields, 0..) |field, i| if (metadata & (@as(u8, 1) << i) != 0) {
        var value = try getVar(bytes, pos);
        if (comptime std.mem.eql(u8, field, "count")) {
            if (description.results) value = if (value == 0) ir.multi_count else value - 1;
        }
        if (comptime std.mem.eql(u8, field, "aux")) {
            if (description.target) {
                const target = std.math.add(i64, @as(i64, pc) + 1, unzigzag(value)) catch return error.BadJumpTarget;
                if (target < 0 or target > instruction_count) return error.BadJumpTarget;
                value = @intCast(target);
            }
        }
        @field(inst, field) = try asU32(value);
    };
    if (inst.op == .load_bool) inst.a = @intFromBool(tag & 128 != 0);
    const packed_regs = inst.op != .load_bool and tag & 128 != 0;
    const regs = registerMask(inst, false);
    var pending: ?u8 = null;
    inline for (sem.fields, 0..) |field, i| if (regs & (@as(u8, 1) << i) != 0) {
        if (!packed_regs) {
            const encoded = try getVar(bytes, pos);
            @field(inst, field) = if (use_references and refs.mask(inst.op) & (@as(u8, 1) << i) != 0) try refs.decode(encoded) else try asU32(encoded);
        } else if (pending) |hi| {
            @field(inst, field) = hi;
            pending = null;
        } else {
            if (pos.* >= bytes.len) return error.Truncated;
            const byte = bytes[pos.*];
            pos.* += 1;
            @field(inst, field) = byte & 15;
            pending = byte >> 4;
        }
    };
    if (pending) |padding| if (padding != 0) {
        return error.BadRegisterPadding;
    };
    return inst;
}
test "every opcode roundtrips packed and wide semantic operands" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    inline for (@typeInfo(ir.Opcode).@"enum".fields) |field| {
        for ([_]u32{ 3, 500 }) |r| {
            var inst = sem.canonical(.{ .op = @enumFromInt(field.value), .dst = r, .a = r, .b = r, .c = r, .aux = 3, .count = ir.multi_count });
            if (inst.op == .load_bool) inst.a = 1;
            out.clearRetainingCapacity();
            try writeInst(&out, allocator, 10, inst);
            var pos: usize = 0;
            const restored = try readInst(out.items, &pos, 10, 100);
            try std.testing.expectEqualDeep(inst, restored);
            try std.testing.expectEqual(out.items.len, pos);
        }
    }
}
test "numeric binary operation occupies three bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try writeInst(&out, std.testing.allocator, 0, .{ .op = .add_number, .dst = 1, .a = 2, .b = 3 });
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
}
