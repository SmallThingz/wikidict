//! Build-only generated links. The codec receives ordinary semantic spans only.
const std = @import("std");
const A = std.mem.Allocator;
pub const prefix = "\x7fWDGLINK:";
pub const max_bytes = 16 * 1024 * 1024;
pub const max_links = 100_000;
pub fn checkedCount(previous: usize, additional: usize) Error!usize {
    if (previous > max_links or additional > max_links - previous) return error.LiteralProvenanceLimit;
    return previous + additional;
}
pub const Error = A.Error || error{ InvalidLiteralProvenance, LiteralProvenanceLimit };
pub const Value = struct {
    kind: enum { isbn } = .isbn,
    token: []const u8,
    argument: []const u8,
    target: []const u8,
    label: []const u8,
};
pub const WireRange = struct { start: u32, end: u32, value: Value };
pub const Bound = struct { root: []const u8, start: u32, end: u32, value: Value };
pub const Range = struct { start: u32, end: u32, bound: *const Bound };

// CoreParserFunctions::isbn, core 79b81ba9: tabs, explicit nbsp spellings and
// Unicode Zs are non-newline spaces. Other entities are not decoded here.
fn spaceLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    if (s[0] == ' ' or s[0] == '\t') return 1;
    if (std.mem.startsWith(u8, s, "&nbsp;")) return 6;
    for ([_][]const u8{ "\u{a0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200a}", "\u{202f}", "\u{205f}", "\u{3000}" }) |space|
        if (std.mem.startsWith(u8, s, space)) return space.len;
    if (!std.mem.startsWith(u8, s, "&#")) return 0;
    var at: usize = 2;
    var hex = false;
    if (at < s.len and (s[at] == 'x' or s[at] == 'X')) { hex = true; at += 1; }
    while (at < s.len and s[at] == '0') at += 1;
    if (hex) {
        if (at + 3 <= s.len and (s[at] == 'a' or s[at] == 'A') and s[at + 1] == '0' and s[at + 2] == ';') return at + 3;
    } else if (std.mem.startsWith(u8, s[at..], "160;")) return at + 4;
    return 0;
}
pub fn normalizeAlloc(a: A, input: []const u8) Error!?[]const u8 {
    if (input.len > max_bytes) return error.LiteralProvenanceLimit;
    if (!std.unicode.utf8ValidateSlice(input)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var at: usize = 0;
    while (at < input.len) {
        const len = spaceLen(input[at..]);
        if (len != 0) { try out.append(a, ' '); at += len; }
        else { try out.append(a, input[at]); at += 1; }
    }
    return try out.toOwnedSlice(a);
}
// The PHP regex is deliberately unanchored. Its optional 978/979 prefix
// changes no success result: every accepted 13-digit match also contains the
// accepted ten-character suffix. Output still uses the WHOLE argument.
pub fn matches(argument: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(argument)) return false;
    for (argument, 0..) |byte, start| {
        if (!std.ascii.isDigit(byte)) continue;
        var at = start;
        var digits: usize = 0;
        while (digits < 9 and at < argument.len and std.ascii.isDigit(argument[at])) : (digits += 1) {
            at += 1;
            if (at < argument.len and (argument[at] == '-' or argument[at] == ' ')) at += 1;
        }
        if (digits == 9 and at < argument.len and (std.ascii.isDigit(argument[at]) or argument[at] == 'X' or argument[at] == 'x')) return true;
    }
    return false;
}
// SpecialPage::getTitleValueFor constructs a TitleValue for name/subpage.
// Its basic constructor rejects CR/LF/HT and a trailing space/underscore.
// ISBN normalization removes spaces/hyphens before this check; the special
// page name owns the first byte, so a leading subpage underscore is valid.
pub fn validTargetArgument(normalized: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(normalized) or std.mem.indexOfAny(u8, normalized, "\r\n\t") != null) return false;
    var end = normalized.len;
    while (end != 0 and (normalized[end - 1] == '-' or normalized[end - 1] == ' ')) end -= 1;
    return end == 0 or normalized[end - 1] != '_';
}
pub fn targetAlloc(a: A, normalized: []const u8) (Error || error{InvalidIsbnTitleTarget})![]const u8 {
    if (!validTargetArgument(normalized)) return error.InvalidIsbnTitleTarget;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "Special:Booksources/");
    for (normalized) |byte| if (byte != '-' and byte != ' ') try out.append(a, if (byte == 'x') 'X' else if (byte == '_') ' ' else byte);
    return try out.toOwnedSlice(a);
}
fn framed(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    h.update(&length); h.update(bytes);
}
pub fn tokenAlloc(a: A, id: usize, argument: []const u8, target: []const u8, label: []const u8) Error![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    framed(&h, argument); framed(&h, target); framed(&h, label);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return try std.fmt.allocPrint(a, "{s}{d}:{s}\x7f", .{ prefix, id, std.fmt.bytesToHex(digest, .lower) });
}
pub fn valid(value: Value) bool {
    if (value.argument.len > max_bytes or !matches(value.argument) or !validTargetArgument(value.argument) or !std.mem.startsWith(u8, value.label, "ISBN ") or !std.mem.eql(u8, value.label[5..], value.argument) or !std.mem.startsWith(u8, value.target, "Special:Booksources/")) return false;
    var pos: usize = "Special:Booksources/".len;
    var at: usize = 0;
    while (at < value.argument.len) {
        const space = spaceLen(value.argument[at..]);
        if (space != 0 and (space != 1 or value.argument[at] != ' ')) return false;
        const byte = value.argument[at]; at += 1;
        if (byte == '-' or byte == ' ') continue;
        if (pos == value.target.len or value.target[pos] != (if (byte == 'x') @as(u8, 'X') else if (byte == '_') @as(u8, ' ') else byte)) return false;
        pos += 1;
    }
    if (pos != value.target.len or value.token.len > 128 or !std.mem.startsWith(u8, value.token, prefix)) return false;
    const rest = value.token[prefix.len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    if (colon == 0 or colon > 10 or (colon > 1 and rest[0] == '0')) return false;
    for (rest[0..colon]) |c| if (!std.ascii.isDigit(c)) return false;
    const tail = rest[colon + 1..];
    if (tail.len != 65 or tail[64] != 0x7f) return false;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    framed(&h, value.argument); framed(&h, value.target); framed(&h, value.label);
    var digest: [32]u8 = undefined; h.final(&digest);
    return std.mem.eql(u8, tail[0..64], &std.fmt.bytesToHex(digest, .lower));
}
pub fn validBound(bound: *const Bound) bool {
    return bound.start < bound.end and bound.end <= bound.root.len and valid(bound.value) and std.mem.eql(u8, bound.root[bound.start..bound.end], bound.value.token);
}
pub fn bindAlloc(a: A, root: []const u8, wire: []const WireRange) Error![]const Range {
    if (wire.len > max_links or root.len > max_bytes) return error.LiteralProvenanceLimit;
    const result = try a.alloc(Range, wire.len);
    var previous: u32 = 0;
    for (wire, result) |item, *out| {
        if (item.start < previous or item.start >= item.end or item.end > root.len) return error.InvalidLiteralProvenance;
        const bound = try a.create(Bound);
        bound.* = .{ .root = root, .start = item.start, .end = item.end, .value = item.value };
        if (!validBound(bound)) return error.InvalidLiteralProvenance;
        out.* = .{ .start = item.start, .end = item.end, .bound = bound };
        previous = item.end;
    }
    return result;
}
pub fn validateRanges(bytes: []const u8, source: ?[]const u8, ranges: []const Range) Error!void {
    if (ranges.len == 0) return;
    const owned = source orelse return error.InvalidLiteralProvenance;
    if (owned.ptr != bytes.ptr or owned.len != bytes.len) return error.InvalidLiteralProvenance;
    var previous: u32 = 0;
    for (ranges) |item| {
        if (item.start < previous or item.start >= item.end or item.end > bytes.len or !validBound(item.bound) or !std.mem.eql(u8, bytes[item.start..item.end], item.bound.value.token)) return error.InvalidLiteralProvenance;
        previous = item.end;
    }
}

// A source slice can borrow authority only by pointer containment, never by
// matching bytes in another allocation. Proved copies use Text.Builder instead.
pub fn borrowedSliceAlloc(a: A, bytes: []const u8, root: []const u8, ranges: []const Range) Error!?[]const Range {
    const base = @intFromPtr(root.ptr);
    const at = @intFromPtr(bytes.ptr);
    if (at < base or at - base > root.len or bytes.len > root.len - (at - base)) return null;
    const start = at - base;
    const end = start + bytes.len;
    var result: std.ArrayList(Range) = .empty;
    errdefer result.deinit(a);
    for (ranges) |link| {
        if (link.end <= start or link.start >= end) continue;
        if (link.start < start or link.end > end) return error.InvalidLiteralProvenance;
        try result.append(a, .{ .start = @intCast(link.start - start), .end = @intCast(link.end - start), .bound = link.bound });
    }
    return try result.toOwnedSlice(a);
}

pub fn validateCoverage(bytes: []const u8, ranges: []const Range) Error!void {
    var at: usize = 0;
    for (ranges) |link| {
        const found = std.mem.indexOfPos(u8, bytes, at, prefix) orelse return error.InvalidLiteralProvenance;
        if (found != link.start) return error.InvalidLiteralProvenance;
        at = link.end;
    }
    if (std.mem.indexOfPos(u8, bytes, at, prefix) != null) return error.InvalidLiteralProvenance;
}

pub fn displayMatches(text: []const u8, label: []const u8, preserve_whitespace: bool) bool {
    if (preserve_whitespace) return std.mem.eql(u8, text, label);
    var pos: usize = 0;
    var whitespace = false;
    for (label) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') {
            if (!whitespace) {
                if (pos == text.len or text[pos] != ' ') return false;
                pos += 1;
            }
            whitespace = true;
        } else {
            if (pos == text.len or text[pos] != byte) return false;
            pos += 1;
            whitespace = byte == ' ';
        }
    }
    return pos == text.len;
}

test "ISBN core lexical matching normalizes the whole argument without checksum or anchoring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { argument: []const u8, normalized: []const u8, target: []const u8 }{
        .{ .argument = "978-83-239-9999-7", .normalized = "978-83-239-9999-7", .target = "Special:Booksources/9788323999997" },
        .{ .argument = "prefix_x123456789x#tail[[A|B]]<b>C</b>\u{2028}end", .normalized = "prefix_x123456789x#tail[[A|B]]<b>C</b>\u{2028}end", .target = "Special:Booksources/prefiX X123456789X#tail[[A|B]]<b>C</b>\u{2028}end" },
        .{ .argument = "123\t45&nbsp;6&#000160;7&#x000A0;8\u{2007}9x", .normalized = "123 45 6 7 8 9x", .target = "Special:Booksources/123456789X" },
        // Core validates only the lexical pattern; it does not verify this checksum.
        .{ .argument = "1234567890 suffix", .normalized = "1234567890 suffix", .target = "Special:Booksources/1234567890suffiX" },
    };
    for (cases) |case| {
        const normalized = (try normalizeAlloc(a, case.argument)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.normalized, normalized);
        try std.testing.expect(matches(normalized));
        try std.testing.expectEqualStrings(case.target, try targetAlloc(a, normalized));
    }
    for ([_][]const u8{ "", "978-1", "1234--567890", "12345\n67890", "１２３４５６７８９０" }) |argument| {
        const normalized = (try normalizeAlloc(a, argument)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!matches(normalized));
    }
    try std.testing.expect((try normalizeAlloc(a, "\xff1234567890")) == null);
}

test "generated ISBN values bind all semantic bytes and exact borrowed token ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argument = "9781234567890#tail";
    const target = try targetAlloc(a, argument);
    const label = try std.fmt.allocPrint(a, "ISBN {s}", .{argument});
    const token = try tokenAlloc(a, 0, argument, target, label);
    const root = try std.mem.concat(a, u8, &.{ "A", token, "Z" });
    const value: Value = .{ .token = token, .argument = argument, .target = target, .label = label };
    const links = try bindAlloc(a, root, &.{.{ .start = 1, .end = @intCast(1 + token.len), .value = value }});
    try validateRanges(root, root, links);
    try validateCoverage(root, links);
    const borrowed = (try borrowedSliceAlloc(a, root[1..root.len - 1], root, links)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), borrowed[0].start);
    try std.testing.expect((try borrowedSliceAlloc(a, try a.dupe(u8, root), root, links)) == null);
    try std.testing.expectError(error.InvalidLiteralProvenance, borrowedSliceAlloc(a, root[2..], root, links));
    try std.testing.expectError(error.InvalidLiteralProvenance, validateRanges(try a.dupe(u8, root), root, links));
    var changed = value;
    changed.target = "Special:Booksources/other";
    try std.testing.expect(!valid(changed));
    changed = value;
    changed.label = "active different label";
    try std.testing.expect(!valid(changed));
    try std.testing.expectError(error.InvalidLiteralProvenance, validateCoverage(try std.mem.concat(a, u8, &.{root, token}), links));
}

test "generated ISBN page count includes output and title without any body items" {
    try std.testing.expectEqual(@as(usize, max_links), try checkedCount(max_links - 1, 1));
    try std.testing.expectError(error.LiteralProvenanceLimit, checkedCount(max_links, 1));
    try std.testing.expectError(error.LiteralProvenanceLimit, checkedCount(0, max_links + 1));
    try std.testing.expectError(error.LiteralProvenanceLimit, checkedCount(std.math.maxInt(usize), 1));
}

test "ISBN lexical success can still fail matched TitleValue construction" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "9781234567890\nend", "9781234567890\rend", "9781234567890_", "9781234567890_- -" }) |argument| {
        const normalized = (try normalizeAlloc(a, argument)) orelse return error.TestUnexpectedResult;
        defer a.free(normalized);
        try std.testing.expect(matches(normalized));
        try std.testing.expect(!validTargetArgument(normalized));
        try std.testing.expectError(error.InvalidIsbnTitleTarget, targetAlloc(a, normalized));
    }
    const normalized = (try normalizeAlloc(a, "_978123456789x\t")) orelse return error.TestUnexpectedResult;
    defer a.free(normalized);
    const target = try targetAlloc(a, normalized);
    defer a.free(target);
    try std.testing.expectEqualStrings("Special:Booksources/ 978123456789X", target);
    // Literal # and Unicode line separator are accepted by this basic constructor.
    try std.testing.expect(validTargetArgument("9781234567890#tail\u{2028}end"));
}
