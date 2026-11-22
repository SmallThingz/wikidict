//! Unicode 16.0.0 default lowercase for UTF-8 search text.
//! Preserves accents and compatibility characters; this is not case folding.
//! Uses no locale state, external libraries, or runtime data files.
//! Android/JDK Unicode versions can differ for newly assigned characters.

const std = @import("std");
const data = @import("unicode_lower_data.zig");

pub const unicode_version = data.unicode_version;
pub const Error = std.Io.Writer.Error || error{InvalidUtf8};

/// Appends lowercase text. Invalid UTF-8 is rejected before anything is written.
/// A writer failure can leave partial output, as with any Writer operation.
pub fn writeLower(w: *std.Io.Writer, input: []const u8) Error!void {
    const ascii = for (input) |byte| {
        if (byte >= 0x80) break false;
    } else true;
    if (ascii) {
        for (input) |byte| try w.writeByte(std.ascii.toLower(byte));
        return;
    }

    const view = std.unicode.Utf8View.init(input) catch return error.InvalidUtf8;
    var it = view.iterator();
    var cased_before = false;
    while (it.nextCodepoint()) |cp| {
        const final_sigma = cp == 0x03A3 and cased_before and !followingIsCased(it);
        // Case_Ignorable takes precedence when it overlaps Cased (e.g. U+0345).
        // Context is evaluated in the original input, not the lowercase output.
        if (!inRanges(&data.case_ignorable, cp)) cased_before = inRanges(&data.cased, cp);

        for (data.expansions) |entry| {
            if (entry.cp == cp) {
                for (entry.lower) |lowered| try writeCodepoint(w, lowered);
                break;
            }
        } else {
            try writeCodepoint(w, if (final_sigma) 0x03C2 else lowerSimple(cp));
        }
    }
}

/// Returns an owned lowercase copy. Free the result with the same allocator.
pub fn lowerAlloc(a: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{InvalidUtf8})![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(a, input.len);
    defer out.deinit();
    writeLower(&out.writer, input) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
    };
    return out.toOwnedSlice();
}

fn writeCodepoint(w: *std.Io.Writer, cp: u21) std.Io.Writer.Error!void {
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &bytes) catch unreachable;
    try w.writeAll(bytes[0..len]);
}

fn followingIsCased(remaining: std.unicode.Utf8Iterator) bool {
    var it = remaining;
    while (it.nextCodepoint()) |cp| {
        if (!inRanges(&data.case_ignorable, cp)) return inRanges(&data.cased, cp);
    }
    return false;
}

fn inRanges(ranges: []const data.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (cp < range.first) {
            hi = mid;
        } else if (cp > range.last) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn lowerSimple(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    var lo: usize = 0;
    var hi: usize = data.lower_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = data.lower_ranges[mid];
        if (cp < range.first) {
            hi = mid;
        } else if (cp > range.last) {
            lo = mid + 1;
        } else {
            if ((cp - range.first) % range.step != 0) return cp;
            return @intCast(@as(i32, cp) + range.delta);
        }
    }
    return cp;
}

fn expectLower(expected: []const u8, input: []const u8) !void {
    const actual = try lowerAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "ASCII and empty text" {
    try expectLower("", "");
    try expectLower("wikidict: abc_xyz 0123!", "WIKIDICT: AbC_XyZ 0123!");
}

test "accented Latin, Cyrillic and non-BMP case pairs" {
    try expectLower("\u{e9}cole \u{e0} \u{f6} \u{153} \u{df}", "\u{c9}COLE \u{c0} \u{d6} \u{152} \u{1e9e}");
    try expectLower("\u{43c}\u{43e}\u{441}\u{43a}\u{432}\u{430} \u{451}", "\u{41c}\u{41e}\u{421}\u{41a}\u{412}\u{410} \u{401}");
    try expectLower("\u{10428}\u{1044f}", "\u{10400}\u{10427}");
    try expectLower("\u{1c8a}", "\u{1c89}"); // Unicode 16.0 addition.
}

test "dotted I expands using default locale rules" {
    try expectLower("i\u{307}stanbul i \u{131}", "\u{130}STANBUL I \u{131}");
    try expectLower("i\u{307}\u{301}", "\u{130}\u{301}");
}

test "Greek sigma respects surrounding original cased characters" {
    try expectLower("\u{3bf}\u{3c2}", "\u{39f}\u{3a3}");
    try expectLower("\u{3bf}\u{3c3}\u{3b1}", "\u{39f}\u{3a3}\u{391}");
    try expectLower("\u{3c3} \u{3c3}", "\u{3a3} \u{3a3}");
    try expectLower("a\u{3c2}!a\u{3c3}b", "A\u{3a3}!A\u{3a3}B");
    try expectLower("a'\u{3c2}\u{301}", "A'\u{3a3}\u{301}");
    try expectLower("a\u{3c3}\u{301}b", "A\u{3a3}\u{301}B");
    try expectLower("\u{3c3}\u{3c2}", "\u{3a3}\u{3a3}");
}

test "sigma context skips characters that are both cased and case-ignorable" {
    try expectLower("\u{345}\u{3c3}", "\u{345}\u{3a3}");
    try expectLower("a\u{345}\u{3c2}", "A\u{345}\u{3a3}");
    try expectLower("a\u{3c2}\u{345}", "A\u{3a3}\u{345}");
    try expectLower("a\u{3c3}\u{345}b", "A\u{3a3}\u{345}B");
}

test "uncased scripts, emoji, accents and compatibility distinctions survive" {
    const unchanged = "\u{4e2d}\u{6587} \u{65e5}\u{672c}\u{8a9e} \u{627}\u{644}\u{639}\u{631}\u{628}\u{64a}\u{629} \u{1f600}\u{1f3fd}\u{200d}\u{1f4bb}";
    try expectLower(unchanged, unchanged);
    try expectLower("\u{df}\u{fb03}\u{3c2} e\u{301} \u{e9}", "\u{df}\u{fb03}\u{3c2} E\u{301} \u{c9}");
}

test "invalid UTF-8 is rejected before writing" {
    const inputs = [_][]const u8{
        "\xff", "\x80", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "valid\xe2\x82",
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("prefix");
    for (inputs) |input| {
        try std.testing.expectError(error.InvalidUtf8, writeLower(&out.writer, input));
        try std.testing.expectEqualStrings("prefix", out.written());
        try std.testing.expectError(error.InvalidUtf8, lowerAlloc(std.testing.allocator, input));
    }
}

test "writer appends and supports caller-owned reusable storage" {
    var storage: [100]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    try out.writeAll("result: ");
    try writeLower(&out, "\u{130}STANBUL");
    try std.testing.expectEqualStrings("result: i\u{307}stanbul", out.buffered());
    out.end = 0;
    try writeLower(&out, "\u{39f}\u{3a3}");
    try std.testing.expectEqualStrings("\u{3bf}\u{3c2}", out.buffered());
}

test "writer failure and allocation failure propagate" {
    var storage: [2]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    try std.testing.expectError(error.WriteFailed, writeLower(&out, "\u{130}"));
    var empty: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&empty);
    try std.testing.expectError(error.OutOfMemory, lowerAlloc(fixed.allocator(), "ABC"));
}
