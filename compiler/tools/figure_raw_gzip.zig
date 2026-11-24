const std = @import("std");
const flate = std.compress.flate;

/// Forward decoder for a Figure source. The caller supplies a held physical
/// reader and independently authenticates the decoded stream with StreamInput.
const Gzip = @This();

inflater: flate.Decompress,
crc: std.hash.Crc32 = .init(),
member_bytes: u32 = 0,
offset: u64 = 0,
size: u64,
exact: bool = true,
done: bool = false,

pub fn init(input: *std.Io.Reader, window: []u8, logical_size: u64) Gzip {
    return .{ .inflater = .init(input, .gzip, window), .size = logical_size };
}

/// Validate complete gzip members through physical EOF with an absolute decoded ceiling.
pub fn initBounded(input: *std.Io.Reader, window: []u8, ceiling: u64) Gzip {
    return .{ .inflater = .init(input, .gzip, window), .size = ceiling, .exact = false };
}

pub fn readAt(context: *anyopaque, bytes: []u8, offset: u64) !usize {
    const self: *Gzip = @ptrCast(@alignCast(context));
    if (offset != self.offset or bytes.len == 0) return error.InvalidFigureGzip;
    if (self.done) return 0;
    var used: usize = 0;
    const limit = @min(bytes.len, self.size - self.offset +| 1);
    while (used < limit) {
        const out = bytes[used..limit];
        const n = self.inflater.reader.readSliceShort(out) catch return error.InvalidFigureGzip;
        if (n > self.size - self.offset) return error.InvalidFigureGzip;
        self.offset += n;
        self.member_bytes +%= @as(u32, @intCast(n));
        self.crc.update(out[0..n]);
        used += n;
        if (n == out.len) break;
        const footer = self.inflater.container_metadata.gzip;
        if (self.inflater.state != .end or self.inflater.err != null or
            footer.count != self.member_bytes or footer.crc != self.crc.final()) return error.InvalidFigureGzip;
        // Match Python gzip: allow concatenated members and zero padding
        // following each complete member. A nonzero suffix must be a member.
        const input = self.inflater.input;
        while (input.peekByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (self.exact and self.offset != self.size) return error.InvalidFigureGzip;
                self.done = true;
                return used;
            },
            else => return error.InvalidFigureGzip,
        } == 0) input.toss(1);
        const window = self.inflater.reader.buffer;
        self.inflater = .init(input, .gzip, window);
        self.member_bytes = 0;
        self.crc = .init();
    }
    return used;
}

const gzip_abc = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 75, 76, 74, 6, 0, 194, 65, 36, 53, 3, 0, 0, 0 };

fn testRead(archive: []const u8, logical_size: u64) !void {
    var input: std.Io.Reader = .fixed(archive);
    var window: [flate.max_window_len]u8 = undefined;
    var decoder = Gzip.init(&input, &window, logical_size);
    var output: [2]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try Gzip.readAt(&decoder, &output, offset);
        if (n == 0) break;
        for (output[0..n], 0..) |byte, i| try std.testing.expectEqual("abc"[(offset + i) % 3], byte);
        offset += n;
    }
    try std.testing.expect(decoder.done);
    try std.testing.expectEqual(logical_size, offset);
}

test "Figure gzip validates exact decoded size and footer and rejects a trailing nonmember" {
    try testRead(&gzip_abc, 3);
    try testRead(&(gzip_abc ++ [_]u8{0} ++ gzip_abc ++ [_]u8{ 0, 0 }), 6);
    try std.testing.expectError(error.InvalidFigureGzip, testRead(&gzip_abc, 2));
    try std.testing.expectError(error.InvalidFigureGzip, testRead(&gzip_abc, 4));
    try std.testing.expectError(error.InvalidFigureGzip, testRead(gzip_abc[0 .. gzip_abc.len - 1], 3));
    try std.testing.expectError(error.InvalidFigureGzip, testRead(&(gzip_abc ++ [_]u8{ 1, 2 }), 3));
    var bad = gzip_abc;
    bad[15] ^= 1;
    try std.testing.expectError(error.InvalidFigureGzip, testRead(&bad, 3));
    bad = gzip_abc;
    bad[19] ^= 1;
    try std.testing.expectError(error.InvalidFigureGzip, testRead(&bad, 3));
}

test "bounded Figure gzip checks the ceiling independently of physical EOF" {
    for ([_]u64{ 2, 3, 4 }) |ceiling| {
        var input: std.Io.Reader = .fixed(&gzip_abc);
        var window: [flate.max_window_len]u8 = undefined;
        var decoder = Gzip.initBounded(&input, &window, ceiling);
        var output: [8]u8 = undefined;
        if (ceiling < 3) {
            try std.testing.expectError(error.InvalidFigureGzip, Gzip.readAt(&decoder, &output, 0));
        } else {
            const n = try Gzip.readAt(&decoder, &output, 0);
            try std.testing.expectEqualStrings("abc", output[0..n]);
            try std.testing.expect(decoder.done);
        }
    }
}
