const std = @import("std");
const ir = @import("ir.zig");
const sem = @import("semantics.zig");
pub const payload_mask: u32 = 0x1fffffff;
pub const Tag = enum(u3) { register = 0, constant = 1, string = 2, integer = 3, special = 4, _ };
pub fn tag(value: u32) Tag {
    return @enumFromInt(value >> 29);
}
pub fn index(value: u32) u32 {
    return value & payload_mask;
}
pub fn isRegister(value: u32) bool {
    return tag(value) == .register;
}
pub fn constant(id: u32) !u32 {
    if (id > payload_mask) return error.ReferenceOverflow;
    return 0x20000000 | id;
}
pub fn string(id: u32) !u32 {
    if (id > payload_mask) return error.ReferenceOverflow;
    return 0x40000000 | id;
}
pub const nil: u32 = 0x80000000;
pub const false_value: u32 = 0x80000001;
pub const true_value: u32 = 0x80000002;
pub fn integer(n: i29) u32 {
    return 0x60000000 | @as(u32, @as(u29, @bitCast(n)));
}
pub fn integerValue(value: u32) i32 {
    const n: i29 = @bitCast(@as(u29, @truncate(value)));
    return n;
}
pub fn number(n: f64) ?u32 {
    if (!std.math.isFinite(n) or @floor(n) != n or n < -268435456.0 or n > 268435455.0) return null;
    if (@as(u64, @bitCast(n)) == 0x8000000000000000) return null;
    return integer(@intFromFloat(n));
}
pub fn mask(op: ir.Opcode) u8 {
    var result = sem.info(op).reads;
    switch (op) {
        .numeric_for_next => result &= ~sem.a,
        .generic_for_init, .generic_for_next => result &= ~sem.c,
        .call_vararg, .call_scoped_vararg, .call_local_vararg, .direct_call_vararg, .method_call_vararg, .method_call_field_vararg => result &= ~sem.c,
        .ret_var => result &= ~sem.a,
        .table_append_var => result &= ~sem.b,
        else => {},
    }
    return result;
}
pub fn validate(p: *const ir.Program, value: u32) !void {
    switch (tag(value)) {
        .register => {},
        .constant => {
            if (index(value) >= p.constants.items.len) return error.BadConstantReference;
            switch (p.constants.items[index(value)]) {
                .table, .number => return error.NonScalarReference,
                else => {},
            }
        },
        .string => if (index(value) >= p.strings.items.len) {
            return error.BadStringReference;
        },
        .integer => {},
        .special => if (index(value) > 2) {
            return error.BadImmediate;
        },
        else => return error.BadImmediate,
    }
}
pub fn encode(value: u32) !u64 {
    return switch (tag(value)) {
        .register => @as(u64, value) << 3,
        .constant => (@as(u64, index(value)) << 3) | 1,
        .string => (@as(u64, index(value)) << 3) | 2,
        .integer => blk: {
            const n: i64 = integerValue(value);
            const zz = (@as(u64, @bitCast(n)) << 1) ^ @as(u64, @bitCast(n >> 63));
            break :blk (zz << 3) | 3;
        },
        .special => if (index(value) <= 2) 4 + @as(u64, index(value)) else error.BadImmediate,
        else => error.BadImmediate,
    };
}
pub fn decode(encoded: u64) !u32 {
    const payload = encoded >> 3;
    return switch (encoded & 7) {
        0 => if (payload <= payload_mask) @intCast(payload) else error.ReferenceOverflow,
        1 => try constant(std.math.cast(u32, payload) orelse return error.ReferenceOverflow),
        2 => try string(std.math.cast(u32, payload) orelse return error.ReferenceOverflow),
        3 => blk: {
            const n: i64 = @bitCast((payload >> 1) ^ (0 -% (payload & 1)));
            const small = std.math.cast(i29, n) orelse return error.ReferenceOverflow;
            break :blk integer(small);
        },
        4, 5, 6 => if (payload == 0) nil + @as(u32, @intCast((encoded & 7) - 4)) else error.BadImmediate,
        else => error.BadImmediate,
    };
}
test "immediate integer and special encodings roundtrip" {
    const values = [_]u32{ 0, 15, 1024, try constant(54321), try string(23), nil, false_value, true_value, integer(-268435456), integer(-1), integer(0), integer(268435455) };
    for (values) |value| try std.testing.expectEqual(value, try decode(try encode(value)));
    try std.testing.expect(number(-0.0) == null);
    try std.testing.expect(number(std.math.inf(f64)) == null);
    try std.testing.expect(number(1.25) == null);
}

pub fn visit(f: *ir.Function, ctx: anytype, comptime transform: anytype) !void {
    for (f.insts.items) |*inst| inline for (sem.fields, 0..) |field, i| {
        if (mask(inst.op) & (@as(u8, 1) << i) != 0)
            @field(inst, field) = try transform(ctx, @field(inst, field));
    };
    for (f.operands.items) |*value| value.* = try transform(ctx, value.*);
}
pub fn remapConstant(map: []const u32, value: u32) !u32 {
    if (tag(value) != .constant) return value;
    if (index(value) >= map.len) return error.BadConstantReference;
    return constant(map[index(value)]);
}
pub fn remapString(map: []const u32, value: u32) !u32 {
    if (tag(value) != .string) return value;
    if (index(value) >= map.len) return error.BadStringReference;
    return string(map[index(value)]);
}
