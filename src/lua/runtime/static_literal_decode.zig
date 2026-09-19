const std = @import("std");
const rt = @import("zig_runtime");
const format = @import("lua_static_literal_format");

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.InvalidStaticLiteral;
        const out = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return out;
    }

    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn string(self: *Reader) ![]const u8 {
        const len: usize = @intCast(try self.readU32());
        return self.take(len);
    }

    fn value(self: *Reader, ctx: *rt.Context, depth: usize) anyerror!rt.Value {
        if (depth >= format.max_depth) return error.InvalidStaticLiteral;
        return switch (try self.byte()) {
            @intFromEnum(format.ValueTag.nil) => .nil,
            @intFromEnum(format.ValueTag.false_) => .{ .boolean = false },
            @intFromEnum(format.ValueTag.true_) => .{ .boolean = true },
            @intFromEnum(format.ValueTag.number) => .{ .number = @bitCast(try self.readU64()) },
            @intFromEnum(format.ValueTag.string) => .{ .string = try self.string() },
            @intFromEnum(format.ValueTag.table) => try self.table(ctx, depth + 1),
            else => error.InvalidStaticLiteral,
        };
    }

    fn table(self: *Reader, ctx: *rt.Context, depth: usize) anyerror!rt.Value {
        const shape_id = try self.readU32();
        const field_count = try self.readU32();
        const list_capacity = try self.readU32();
        const table_value = if (shape_id != format.no_shape)
            try ctx.newProgramShape(shape_id)
        else if (list_capacity != 0)
            try ctx.newArrayTable(list_capacity)
        else
            try ctx.newTable();

        for (0..field_count) |_| switch (try self.byte()) {
            @intFromEnum(format.FieldTag.list) => try table_value.append(ctx.allocator, try self.value(ctx, depth)),
            @intFromEnum(format.FieldTag.named) => {
                const key = try self.string();
                try table_value.rawSet(ctx.allocator, .{ .string = key }, try self.value(ctx, depth));
            },
            @intFromEnum(format.FieldTag.keyed) => {
                const key = try self.value(ctx, depth);
                const item = try self.value(ctx, depth);
                try table_value.rawSet(ctx.allocator, key, item);
            },
            else => return error.InvalidStaticLiteral,
        };
        return .{ .table = table_value };
    }
};

pub fn decode(ctx: *rt.Context, bytes: []const u8) !rt.Value {
    var reader = Reader{ .bytes = bytes };
    const value = try reader.value(ctx, 0);
    if (reader.pos != bytes.len) return error.InvalidStaticLiteral;
    return value;
}
