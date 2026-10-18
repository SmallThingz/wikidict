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
    var source = std.mem.trim(u8, raw, " \t\r\n");
    // Only the captured bare cartouche form is supported; nested/numbered
    // enclosures remain opaque. The edge dashes separate the boundary signs.
    const enclosed = source.len >= 4 and std.mem.startsWith(u8, source, "<-") and std.mem.endsWith(u8, source, "->");
    if (enclosed) source = source[2 .. source.len - 2];
    if (source.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (enclosed) try out.appendSlice(a, "𓍹𓐼");
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
        // Literal normalization from captured data: w&t -> w@t, where @
        // is OVERLAY MIDDLE. Ampersand is not a general join operator.
        if (std.mem.startsWith(u8, source[pos..], "w&t") and
            (pos + 3 == source.len or std.mem.indexOfScalar(u8, "-:* \t\r\n", source[pos + 3]) != null))
        {
            atoms += 2;
            if (atoms > 256) return null;
            try out.appendSlice(a, "𓅱𓐴𓏏");
            pos += 3;
            expect_atom = false;
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
    if (enclosed) try out.appendSlice(a, "𓐽𓍺");
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

test "captured Arabic etymologies preserve overlay and bare cartouche controls" {
    for ([_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "i-mn:n-t-w&t-anx", .expected = "𓇋𓏠𓐰𓈖𓏏𓅱𓐴𓏏𓋹" },
        .{ .source = "<-i-t:n:ra-Ax-x:n->", .expected = "𓍹𓐼𓇋𓏏𓐰𓈖𓐰𓇳𓅜𓐍𓐰𓈖𓐽𓍺" },
    }) |case| {
        const decoded = (try decodeAlloc(std.testing.allocator, case.source)).?;
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(case.expected, decoded);
    }
    for ([_][]const u8{ "w&n", "w&&t", "w&tA35", "<-A35", "A35->", "<-->", "<->", "<-<-A35->->", "<1-A35-1>", "<-A35-NotASign->" }) |source|
        try std.testing.expect((try decodeAlloc(std.testing.allocator, source)) == null);
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(std.testing.allocator);
    for (0..129) |i| {
        if (i != 0) try many.append(std.testing.allocator, '-');
        try many.appendSlice(std.testing.allocator, "w&t");
    }
    try std.testing.expect((try decodeAlloc(std.testing.allocator, many.items)) == null);
}
