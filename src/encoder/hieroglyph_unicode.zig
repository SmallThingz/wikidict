//! Conservative build-only conversion of recognized MdC sign sequences to Unicode.
const std = @import("std");
const data = @import("hieroglyph_data.zig");

fn glyph(atom: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = data.entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, atom, data.entries[mid].name)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return data.entries[mid].glyph,
        }
    }
    return null;
}

/// No partial output is exposed: any unknown sign or operator retains the
/// caller's original opaque source. This is not a general MdC layout parser.
pub fn decodeAlloc(a: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len > 8192) return null;
    const source = std.mem.trim(u8, raw, " \t\r\n");
    if (source.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var pos: usize = 0;
    var expect_atom = true;
    var atoms: usize = 0;
    while (pos < source.len) {
        const whitespace_start = pos;
        while (pos < source.len and std.mem.indexOfScalar(u8, " \t\r\n", source[pos]) != null) : (pos += 1) {}
        if (pos == source.len) break;
        if (!expect_atom) {
            switch (source[pos]) {
                '-' => {},
                ':' => try out.appendSlice(a, "𓐰"),
                '*' => try out.appendSlice(a, "𓐱"),
                else => {
                    if (pos == whitespace_start) return null;
                    expect_atom = true;
                    continue;
                },
            }
            pos += 1;
            expect_atom = true;
            continue;
        }
        if (!std.ascii.isAlphabetic(source[pos])) return null;
        const start = pos;
        while (pos < source.len and std.ascii.isAlphanumeric(source[pos])) : (pos += 1) {}
        const sign = glyph(source[start..pos]) orelse return null;
        atoms += 1;
        if (atoms > 256) return null;
        try out.appendSlice(a, sign);
        expect_atom = false;
    }
    if (expect_atom) return null;
    return try out.toOwnedSlice(a);
}

test "captured Gardiner and phonetic sequences have exact Unicode signs and joins" {
    const a = std.testing.allocator;
    const basic = (try decodeAlloc(a, "A35-D40")).?;
    defer a.free(basic);
    try std.testing.expectEqualStrings("𓀨𓂡", basic);
    const joined = (try decodeAlloc(a, "A35 : D40*t")).?;
    defer a.free(joined);
    try std.testing.expectEqualStrings("𓀨𓐰𓂡𓐱𓏏", joined);
    const spaced = (try decodeAlloc(a, " A35 D40 ")).?;
    defer a.free(spaced);
    try std.testing.expectEqualStrings("𓀨𓂡", spaced);
}

test "unknown and complex hieroglyph source cannot produce partial signs" {
    for ([_][]const u8{ "A35-NotASign", "(A35:D40)", "A35& D40", "A35-", "*A35", "A35::D40", "A35<!--comment-->D40", "A35\\D40", "" }) |source|
        try std.testing.expect((try decodeAlloc(std.testing.allocator, source)) == null);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..257) |i| {
        if (i != 0) try source.append(std.testing.allocator, '-');
        try source.appendSlice(std.testing.allocator, "A35");
    }
    try std.testing.expect((try decodeAlloc(std.testing.allocator, source.items)) == null);
}
