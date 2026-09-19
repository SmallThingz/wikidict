const std = @import("std");

pub const magic = "DLPMETA5";

pub fn writeU32(w: *std.Io.Writer, value: u32) !void {
    const bytes = [_]u8{
        @truncate(value),
        @truncate(value >> 8),
        @truncate(value >> 16),
        @truncate(value >> 24),
    };
    try w.writeAll(&bytes);
}

pub fn writeString(w: *std.Io.Writer, value: []const u8) !void {
    if (value.len > std.math.maxInt(u32)) return error.ProgramMetadataStringTooLarge;
    try writeU32(w, @intCast(value.len));
    try w.writeAll(value);
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn readU32(self: *Reader) !u32 {
        if (self.bytes.len -| self.pos < 4) return error.InvalidProgramMetadata;
        const b = self.bytes[self.pos .. self.pos + 4];
        self.pos += 4;
        return @as(u32, b[0]) |
            (@as(u32, b[1]) << 8) |
            (@as(u32, b[2]) << 16) |
            (@as(u32, b[3]) << 24);
    }

    pub fn readString(self: *Reader) ![]const u8 {
        const len: usize = @intCast(try self.readU32());
        if (self.bytes.len -| self.pos < len) return error.InvalidProgramMetadata;
        const value = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return value;
    }

    pub fn expectMagic(self: *Reader) !void {
        if (self.bytes.len -| self.pos < magic.len) return error.InvalidProgramMetadata;
        if (!std.mem.eql(u8, self.bytes[self.pos .. self.pos + magic.len], magic))
            return error.InvalidProgramMetadata;
        self.pos += magic.len;
    }

    pub fn finish(self: *const Reader) !void {
        if (self.pos != self.bytes.len) return error.InvalidProgramMetadata;
    }
};

test "program metadata primitive framing round trips" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writer.writer.writeAll(magic);
    try writeU32(&writer.writer, 0x89abcdef);
    try writeString(&writer.writer, "Module:hello");

    var reader = Reader{ .bytes = writer.written() };
    try reader.expectMagic();
    try std.testing.expectEqual(@as(u32, 0x89abcdef), try reader.readU32());
    try std.testing.expectEqualStrings("Module:hello", try reader.readString());
    try reader.finish();
}
