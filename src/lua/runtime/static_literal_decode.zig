const std = @import("std");
const rt = @import("zig_runtime");
const format = @import("lua_static_literal_format");

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    compact: bool = false,

    fn init(bytes: []const u8) !Reader {
        if (bytes.len != 0 and bytes[0] == format.compact_marker) {
            if (bytes.len < 2 or bytes[1] != format.compact_version)
                return error.InvalidStaticLiteral;
            return .{ .bytes = bytes, .pos = 2, .compact = true };
        }
        return .{ .bytes = bytes };
    }

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

    fn readVarU32(self: *Reader) !u32 {
        var decoded: u32 = 0;
        for (0..5) |index| {
            const item = try self.byte();
            const payload: u32 = item & 0x7f;
            if (index == 4 and payload > 0x0f) return error.InvalidStaticLiteral;
            decoded |= payload << @intCast(index * 7);
            if (item & 0x80 == 0) return decoded;
        }
        return error.InvalidStaticLiteral;
    }

    fn readCount(self: *Reader) !u32 {
        return if (self.compact) self.readVarU32() else self.readU32();
    }

    fn string(self: *Reader) ![]const u8 {
        const len: usize = @intCast(try self.readCount());
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
        const shape_id = if (self.compact) blk: {
            const flags = try self.byte();
            if (flags & ~format.table_flags_mask != 0) return error.InvalidStaticLiteral;
            break :blk if (flags & format.table_has_shape != 0)
                try self.readVarU32()
            else
                format.no_shape;
        } else try self.readU32();
        const field_count = try self.readCount();
        const list_capacity = try self.readCount();
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
    var reader = try Reader.init(bytes);
    const value = try reader.value(ctx, 0);
    if (reader.pos != bytes.len) return error.InvalidStaticLiteral;
    return value;
}

test "compact static literal framing decodes ULEB128 counts" {
    const bytes = [_]u8{ format.compact_marker, format.compact_version, 0xac, 0x02, 0x7f };
    var reader = try Reader.init(&bytes);
    try std.testing.expect(reader.compact);
    try std.testing.expectEqual(@as(u32, 300), try reader.readCount());
    try std.testing.expectEqual(@as(u32, 127), try reader.readCount());
    try std.testing.expectEqual(bytes.len, reader.pos);
}

test "static literal reader preserves legacy counts and rejects bad compact version" {
    const legacy = [_]u8{ 0x2c, 0x01, 0, 0 };
    var legacy_reader = try Reader.init(&legacy);
    try std.testing.expect(!legacy_reader.compact);
    try std.testing.expectEqual(@as(u32, 300), try legacy_reader.readCount());

    const unsupported = [_]u8{ format.compact_marker, format.compact_version + 1 };
    try std.testing.expectError(error.InvalidStaticLiteral, Reader.init(&unsupported));
}
