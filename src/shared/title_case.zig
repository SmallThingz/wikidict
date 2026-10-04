//! MediaWiki first-codepoint title casing, independent of the Lua runtime.
const std = @import("std");
const DecomposeFn = *const fn ([*]const u8, isize, ?[*]i32, isize, c_int) callconv(.c) isize;
const ReencodeFn = *const fn ([*]i32, isize, c_int) callconv(.c) isize;
const nfc_options: c_int = (1 << 1) | (1 << 3);
const CaseFn = *const fn ([*]const u8, usize, ?[*:0]const u8, ?*anyopaque, ?[*]u8, *usize) callconv(.c) ?[*]u8;

pub fn wmfUcfirstOverride(cp: u21) bool {
    return switch (cp) {
        0xDF, 0x19B, 0x264, 0x1C8A, 0xA7CD, 0xA7CF, 0xA7D3, 0xA7D5, 0xA7DB => true,
        else => (cp >= 0x10D70 and cp <= 0x10D85) or (cp >= 0x16EBB and cp <= 0x16ED3),
    };
}

pub const Mapper = struct {
    lib: std.DynLib,
    title: CaseFn,
    normalization_lib: std.DynLib,
    decompose: DecomposeFn,
    reencode: ReencodeFn,

    pub fn init() !Mapper {
        var lib = std.DynLib.open("libunistring.so.5") catch try std.DynLib.open("libunistring.so");
        errdefer lib.close();
        var normalization_lib = std.DynLib.open("libutf8proc.so.3") catch try std.DynLib.open("libutf8proc.so");
        errdefer normalization_lib.close();
        return .{ .lib = lib, .title = lib.lookup(CaseFn, "u8_totitle") orelse return error.UnicodeCaseUnavailable, .normalization_lib = normalization_lib, .decompose = normalization_lib.lookup(DecomposeFn, "utf8proc_decompose") orelse return error.UnicodeNormalizerUnavailable, .reencode = normalization_lib.lookup(ReencodeFn, "utf8proc_reencode") orelse return error.UnicodeNormalizerUnavailable };
    }
    pub fn deinit(self: *Mapper) void {
        self.normalization_lib.close();
        self.lib.close();
    }
    pub fn nfcInto(self: *const Mapper, source: []const u8, storage: []i32) ![]const u8 {
        const ascii = for (source) |c| {
            if (c >= 128) break false;
        } else true;
        if (ascii) return source;
        const needed = self.decompose(source.ptr, @intCast(source.len), null, 0, nfc_options);
        if (needed < 0) return error.InvalidUtf8;
        if (@as(usize, @intCast(needed)) >= storage.len) return error.NoSpaceLeft;
        const written = self.decompose(source.ptr, @intCast(source.len), storage.ptr, @intCast(storage.len - 1), nfc_options);
        if (written != needed) return error.UnicodeNormalizeFailed;
        const length = self.reencode(storage.ptr, written, nfc_options);
        if (length < 0 or @as(usize, @intCast(length)) >= std.mem.sliceAsBytes(storage).len) return error.UnicodeNormalizeFailed;
        return std.mem.sliceAsBytes(storage)[0..@intCast(length)];
    }
    pub fn nfcAlloc(self: *const Mapper, a: std.mem.Allocator, source: []const u8) ![]u8 {
        const ascii = for (source) |c| {
            if (c >= 128) break false;
        } else true;
        if (ascii) return a.dupe(u8, source);
        const needed = self.decompose(source.ptr, @intCast(source.len), null, 0, nfc_options);
        if (needed < 0) return error.InvalidUtf8;
        const storage = try a.alloc(i32, @as(usize, @intCast(needed)) + 1);
        defer a.free(storage);
        return a.dupe(u8, try self.nfcInto(source, storage));
    }

    /// Always returns an owned allocation, including unchanged strings.
    pub fn firstAlloc(self: *const Mapper, a: std.mem.Allocator, source: []const u8) ![]u8 {
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        if (source.len == 0) return a.dupe(u8, source);
        if (source[0] < 0x80) {
            const result = try a.dupe(u8, source);
            result[0] = std.ascii.toUpper(result[0]);
            return result;
        }
        const size = try std.unicode.utf8ByteSequenceLength(source[0]);
        const cp = try std.unicode.utf8Decode(source[0..size]);
        if (wmfUcfirstOverride(cp)) return a.dupe(u8, source);
        var buffer: [64]u8 = undefined;
        var length: usize = buffer.len;
        const mapped = self.title(source.ptr, size, null, null, &buffer, &length) orelse return error.UnicodeCaseFailed;
        defer if (mapped != &buffer) std.c.free(@ptrCast(mapped));
        return std.mem.concat(a, u8, &.{ mapped[0..length], source[size..] });
    }
};

test "MediaWiki title case preserves suffix and special overrides" {
    var mapper = try Mapper.init();
    defer mapper.deinit();
    const cases = .{ .{ "Foo bar", "foo bar" }, .{ "École", "école" }, .{ "ǅabc", "ǆabc" }, .{ "ßfoo", "ßfoo" }, .{ "中文", "中文" } };
    inline for (cases) |pair| {
        const actual = try mapper.firstAlloc(std.testing.allocator, pair[1]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(pair[0], actual);
    }
}
