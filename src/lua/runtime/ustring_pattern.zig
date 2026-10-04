const std = @import("std");
const classes = @import("unicode_classes.zig");
pub const PatternCache = @import("pattern_cache.zig").PatternCache;

pub const max_captures = 32;
pub const CategoryFn = *const fn (i32) callconv(.c) c_int;

pub const Capture = union(enum) {
    unfinished: usize,
    slice: struct { start: usize, end: usize },
    position: usize,
};

pub const Match = struct {
    start: usize,
    end: usize,
    captures: [max_captures]Capture,
    capture_count: u8,
};

pub const Error = error{
    InvalidUtf8,
    MalformedPattern,
    TooManyCaptures,
    InvalidCapture,
    UnfinishedCapture,
};

const Decoded = struct {
    codepoints: []const u21,
    bytepos: []const usize,

    fn deinit(self: Decoded, a: std.mem.Allocator) void {
        a.free(self.codepoints);
        a.free(self.bytepos);
    }
};

fn decode(a: std.mem.Allocator, source: []const u8) !Decoded {
    const count = std.unicode.utf8CountCodepoints(source) catch return error.InvalidUtf8;
    const cps = try a.alloc(u21, count);
    errdefer a.free(cps);
    const bytepos = try a.alloc(usize, count + 1);
    errdefer a.free(bytepos);
    var pos: usize = 0;
    var i: usize = 0;
    while (pos < source.len) : (i += 1) {
        bytepos[i] = pos;
        const n = std.unicode.utf8ByteSequenceLength(source[pos]) catch return error.InvalidUtf8;
        if (pos + n > source.len) return error.InvalidUtf8;
        cps[i] = std.unicode.utf8Decode(source[pos .. pos + n]) catch return error.InvalidUtf8;
        pos += n;
    }
    bytepos[count] = source.len;
    return .{ .codepoints = cps, .bytepos = bytepos };
}

fn categoryMatch(category: CategoryFn, cp: u21, class: u21) bool {
    const cat: c_int = category(@intCast(cp));
    const lower: u21 = if (class >= 'A' and class <= 'Z') class + ('a' - 'A') else class;
    const yes = switch (lower) {
        'a' => cat >= 1 and cat <= 5,
        'c' => cat == 26,
        'd' => cat == 9,
        'l' => cat == 2,
        'p' => cat >= 12 and cat <= 18,
        's' => (cat >= 23 and cat <= 25) or (cp >= 9 and cp <= 13),
        'u' => cat == 1,
        'w' => (cat >= 1 and cat <= 5) or cat == 9,
        'x' => (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'F') or
            (cp >= 'a' and cp <= 'f') or (cp >= 0xff10 and cp <= 0xff19) or
            (cp >= 0xff21 and cp <= 0xff26) or (cp >= 0xff41 and cp <= 0xff46),
        'z' => cp == 0,
        else => return cp == class,
    };
    return if (class >= 'A' and class <= 'Z') !yes else yes;
}

const Matcher = struct {
    source: []const u21,
    pattern: []const u21,
    category: CategoryFn,
    prepared: *const classes.Prepared,
    captures: [max_captures]Capture = undefined,
    level: u8 = 0,

    fn classEnd(self: *const Matcher, p: usize) Error!usize {
        if (p >= self.pattern.len) return error.MalformedPattern;
        return switch (self.pattern[p]) {
            '%' => if (p + 1 < self.pattern.len) p + 2 else error.MalformedPattern,
            '[' => classes.bracketEnd(self.pattern, p) orelse error.MalformedPattern,
            else => p + 1,
        };
    }

    fn bracketClass(self: *const Matcher, cp: u21, p: usize, ep: usize) bool {
        var i = p + 1;
        var invert = false;
        if (i < ep and self.pattern[i] == '^') {
            invert = true;
            i += 1;
        }
        var matched = false;
        if (i < ep and self.pattern[i] == ']') {
            matched = cp == ']';
            i += 1;
        }
        while (!matched and i + 1 < ep) {
            if (self.pattern[i] == '%') {
                if (i + 1 < ep and categoryMatch(self.category, cp, self.pattern[i + 1])) matched = true;
                i += 2;
                continue;
            }
            if (i + 2 < ep and self.pattern[i + 1] == '-' and self.pattern[i + 2] != ']') {
                matched = self.pattern[i] <= cp and cp <= self.pattern[i + 2];
                i += 3;
                continue;
            }
            if (self.pattern[i] == cp) matched = true;
            i += 1;
        }
        return if (invert) !matched else matched;
    }

    fn singleMatch(self: *const Matcher, cp: u21, p: usize, ep: usize, prepared: ?*const classes.Class) bool {
        return switch (self.pattern[p]) {
            '.' => true,
            '%' => categoryMatch(self.category, cp, self.pattern[p + 1]),
            '[' => if (prepared) |c| c.matches(cp) else self.bracketClass(cp, p, ep),
            else => self.pattern[p] == cp,
        };
    }

    fn captureToClose(self: *const Matcher) Error!usize {
        var i: usize = self.level;
        while (i > 0) {
            i -= 1;
            if (self.captures[i] == .unfinished) return i;
        }
        return error.InvalidCapture;
    }

    fn checkCapture(self: *const Matcher, digit: u21) Error!usize {
        if (digit < '1' or digit > '9') return error.InvalidCapture;
        const index: usize = @intCast(digit - '1');
        if (index >= self.level or self.captures[index] != .slice) return error.InvalidCapture;
        return index;
    }

    fn startCapture(self: *Matcher, s: usize, p: usize, position: bool) Error!?usize {
        if (self.level >= max_captures) return error.TooManyCaptures;
        const level = self.level;
        self.level += 1;
        self.captures[level] = if (position) .{ .position = s } else .{ .unfinished = s };
        const result = try self.matchAt(s, p);
        if (result == null) self.level = level;
        return result;
    }

    fn endCapture(self: *Matcher, s: usize, p: usize) Error!?usize {
        const index = try self.captureToClose();
        const start = self.captures[index].unfinished;
        self.captures[index] = .{ .slice = .{ .start = start, .end = s } };
        const result = try self.matchAt(s, p);
        if (result == null) self.captures[index] = .{ .unfinished = start };
        return result;
    }

    fn matchCapture(self: *Matcher, s: usize, digit: u21) Error!?usize {
        const index = try self.checkCapture(digit);
        const cap = self.captures[index].slice;
        const len = cap.end - cap.start;
        if (len > self.source.len - s) return null;
        if (!std.mem.eql(u21, self.source[cap.start..cap.end], self.source[s .. s + len])) return null;
        return s + len;
    }

    fn matchWithRollback(self: *Matcher, s: usize, p: usize) Error!?usize {
        const saved_level = self.level;
        if (saved_level == 0) {
            const result = try self.matchAt(s, p);
            if (result == null) self.level = 0;
            return result;
        }
        var saved: [max_captures]Capture = undefined;
        @memcpy(saved[0..saved_level], self.captures[0..saved_level]);
        const result = try self.matchAt(s, p);
        if (result == null) {
            @memcpy(self.captures[0..saved_level], saved[0..saved_level]);
            self.level = saved_level;
        }
        return result;
    }

    fn matchBalance(self: *Matcher, s: usize, p: usize) Error!?usize {
        if (p + 1 >= self.pattern.len) return error.MalformedPattern;
        if (s >= self.source.len or self.source[s] != self.pattern[p]) return null;
        const open = self.pattern[p];
        const close = self.pattern[p + 1];
        var depth: usize = 1;
        var i = s + 1;
        while (i < self.source.len) : (i += 1) {
            if (self.source[i] == close) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (self.source[i] == open) depth += 1;
        }
        return null;
    }

    fn maxExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize, prepared: ?*const classes.Class) Error!?usize {
        var count: usize = 0;
        while (s + count < self.source.len and self.singleMatch(self.source[s + count], p, ep, prepared)) count += 1;
        while (true) {
            if (try self.matchWithRollback(s + count, next)) |result| return result;
            if (count == 0) return null;
            count -= 1;
        }
    }

    fn minExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize, prepared: ?*const classes.Class) Error!?usize {
        var i = s;
        while (true) {
            if (try self.matchWithRollback(i, next)) |result| return result;
            if (i >= self.source.len or !self.singleMatch(self.source[i], p, ep, prepared)) return null;
            i += 1;
        }
    }

    fn frontier(self: *Matcher, s: usize, p: usize) Error!?usize {
        if (p >= self.pattern.len or self.pattern[p] != '[') return error.MalformedPattern;
        const prepared = self.prepared.lookup(p);
        const ep = if (prepared) |c| c.end else try self.classEnd(p);
        const previous: u21 = if (s == 0) 0 else self.source[s - 1];
        const current: u21 = if (s == self.source.len) 0 else self.source[s];
        if (self.singleMatch(previous, p, ep, prepared) or !self.singleMatch(current, p, ep, prepared)) return null;
        return self.matchAt(s, ep);
    }

    fn matchAt(self: *Matcher, s0: usize, p0: usize) Error!?usize {
        var s = s0;
        var p = p0;
        while (true) {
            if (p == self.pattern.len) return s;
            if (self.pattern[p] == '$' and p + 1 == self.pattern.len)
                return if (s == self.source.len) s else null;
            if (self.pattern[p] == '(') {
                if (p + 1 < self.pattern.len and self.pattern[p + 1] == ')')
                    return self.startCapture(s, p + 2, true);
                return self.startCapture(s, p + 1, false);
            }
            if (self.pattern[p] == ')') return self.endCapture(s, p + 1);
            if (self.pattern[p] == '%' and p + 1 < self.pattern.len) {
                const esc = self.pattern[p + 1];
                if (esc == 'b') {
                    const next = try self.matchBalance(s, p + 2) orelse return null;
                    s = next;
                    p += 4;
                    continue;
                }
                if (esc == 'f') return self.frontier(s, p + 2);
                if (esc >= '1' and esc <= '9') {
                    s = try self.matchCapture(s, esc) orelse return null;
                    p += 2;
                    continue;
                }
            }
            const prepared = if (self.pattern[p] == '[') self.prepared.lookup(p) else null;
            const ep = if (prepared) |c| c.end else try self.classEnd(p);
            const matched = s < self.source.len and self.singleMatch(self.source[s], p, ep, prepared);
            if (ep < self.pattern.len) switch (self.pattern[ep]) {
                '?' => {
                    if (matched) if (try self.matchWithRollback(s + 1, ep + 1)) |r| return r;
                    p = ep + 1;
                    continue;
                },
                '*' => return self.maxExpand(s, p, ep, ep + 1, prepared),
                '+' => {
                    if (!matched) return null;
                    return self.maxExpand(s + 1, p, ep, ep + 1, prepared);
                },
                '-' => return self.minExpand(s, p, ep, ep + 1, prepared),
                else => {},
            };
            if (!matched) return null;
            s += 1;
            p = ep;
        }
    }
};

fn normalizeStart(len: usize, init: i64) usize {
    const n: i64 = @intCast(len);
    const raw = if (init < 0) n + init + 1 else init;
    if (raw <= 1) return 0;
    if (raw > n + 1) return len;
    return @intCast(raw - 1);
}

fn findDecodedInto(source: []const u21, pat: []const u21, category: CategoryFn, initial: usize, honor_anchor: bool, out: *Match, prepared: *const classes.Prepared) Error!bool {
    var start = @min(initial, source.len);
    var pattern_start: usize = 0;
    const anchored = honor_anchor and pat.len != 0 and pat[0] == '^';
    if (anchored) pattern_start = 1;
    while (start <= source.len) : (start += 1) {
        var matcher: Matcher = undefined;
        matcher.source = source;
        matcher.pattern = pat;
        matcher.category = category;
        matcher.level = 0;
        matcher.prepared = prepared;
        const end = try matcher.matchAt(start, pattern_start) orelse {
            if (anchored) return false;
            continue;
        };
        for (matcher.captures[0..matcher.level]) |capture|
            if (capture == .unfinished) return error.UnfinishedCapture;
        out.start = start;
        out.end = end;
        out.capture_count = matcher.level;
        @memcpy(out.captures[0..matcher.level], matcher.captures[0..matcher.level]);
        return true;
    }
    return false;
}

fn findDecoded(source: []const u21, pat: []const u21, category: CategoryFn, initial: usize, honor_anchor: bool, prepared: *const classes.Prepared) Error!?Match {
    var match: Match = undefined;
    if (!(try findDecodedInto(source, pat, category, initial, honor_anchor, &match, prepared))) return null;
    return match;
}

pub const Search = struct {
    source_bytes: []const u8,
    source: Decoded,
    pattern: Decoded,
    allocator: std.mem.Allocator,
    prepared: classes.Prepared = .{},
    preparation_attempted: bool = false,
    pattern_cache: ?*PatternCache = null,
    cache_entry: ?*const PatternCache.Entry = null,
    borrowed_pattern: bool = false,

    pub fn init(a: std.mem.Allocator, source: []const u8, pat: []const u8) !Search {
        return initWithCache(a, source, pat, null);
    }

    pub fn initWithCache(a: std.mem.Allocator, source: []const u8, pat: []const u8, cache: ?*PatternCache) !Search {
        // Keep source-before-pattern UTF-8 validation and error ordering.
        const src = try decode(a, source);
        errdefer src.deinit(a);
        if (cache) |c| if (c.lookup(pat)) |entry| {
            return .{ .source_bytes = source, .source = src, .pattern = .{ .codepoints = entry.codepoints, .bytepos = &.{} }, .allocator = a, .pattern_cache = cache, .cache_entry = entry, .borrowed_pattern = true };
        };
        const pattern = try decode(a, pat);
        return .{ .source_bytes = source, .source = src, .pattern = pattern, .allocator = a, .pattern_cache = cache };
    }

    pub fn deinit(self: Search) void {
        self.prepared.deinit(self.allocator);
        self.source.deinit(self.allocator);
        if (!self.borrowed_pattern) self.pattern.deinit(self.allocator);
    }

    fn prepare(self: *Search) *const classes.Prepared {
        if (!self.preparation_attempted) {
            self.preparation_attempted = true;
            // Cache-hit metadata is already built, even for tiny subjects.
            if (self.cache_entry) |entry| return &entry.prepared;
            if (self.source.codepoints.len >= 8) {
                if (self.pattern_cache) |cache| if (cache.admit(self.pattern.codepoints)) |entry| {
                    // Keep this first miss's local cps until deinit: callers may
                    // have evaluated the pattern argument before prepare().
                    self.cache_entry = entry;
                    return &entry.prepared;
                };
                self.prepared = classes.Prepared.init(self.allocator, self.pattern.codepoints) catch .{};
            }
        }
        return if (self.cache_entry) |entry| &entry.prepared else &self.prepared;
    }

    pub fn find(self: *Search, category: CategoryFn, init_index: i64, honor_anchor: bool) Error!?Match {
        return findDecoded(self.source.codepoints, self.pattern.codepoints, category, normalizeStart(self.source.codepoints.len, init_index), honor_anchor, self.prepare());
    }

    pub fn findInto(self: *Search, category: CategoryFn, init_index: i64, honor_anchor: bool, out: *Match) Error!bool {
        return findDecodedInto(self.source.codepoints, self.pattern.codepoints, category, normalizeStart(self.source.codepoints.len, init_index), honor_anchor, out, self.prepare());
    }

    pub fn findFrom(self: *Search, category: CategoryFn, start: usize, honor_anchor: bool) Error!?Match {
        return findDecoded(self.source.codepoints, self.pattern.codepoints, category, start, honor_anchor, self.prepare());
    }

    pub fn findFromInto(self: *Search, category: CategoryFn, start: usize, honor_anchor: bool, out: *Match) Error!bool {
        return findDecodedInto(self.source.codepoints, self.pattern.codepoints, category, start, honor_anchor, out, self.prepare());
    }

    pub fn findPlain(self: *const Search, init_index: i64) ?Match {
        const start = normalizeStart(self.source.codepoints.len, init_index);
        const pat = self.pattern.codepoints;
        if (pat.len == 0) return .{ .start = start, .end = start, .captures = undefined, .capture_count = 0 };
        if (pat.len > self.source.codepoints.len) return null;
        var pos = start;
        while (pos + pat.len <= self.source.codepoints.len) : (pos += 1) {
            if (std.mem.eql(u21, self.source.codepoints[pos .. pos + pat.len], pat))
                return .{ .start = pos, .end = pos + pat.len, .captures = undefined, .capture_count = 0 };
        }
        return null;
    }

    pub fn byteSlice(self: *const Search, start: usize, end: usize) []const u8 {
        return self.source_bytes[self.source.bytepos[start]..self.source.bytepos[end]];
    }

    pub fn captureValue(self: *const Search, capture: Capture) union(enum) { slice: []const u8, position: usize } {
        return switch (capture) {
            .slice => |v| .{ .slice = self.byteSlice(v.start, v.end) },
            .position => |v| .{ .position = v + 1 },
            .unfinished => unreachable,
        };
    }
};

test "unicode dot consumes one codepoint" {
    const fakeCategory = struct {
        fn category(_: i32) callconv(.c) c_int {
            return 0;
        }
    }.category;
    var search = try Search.init(std.testing.allocator, "ʃə", "^.");
    defer search.deinit();
    const m = (try search.find(fakeCategory, 1, true)).?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(@as(usize, 1), m.end);
    try std.testing.expectEqualStrings("ʃ", search.byteSlice(m.start, m.end));
}

test "unicode findInto preserves output on misses and copies live captures" {
    const category = struct {
        fn call(_: i32) callconv(.c) c_int {
            return 0;
        }
    }.call;
    var search = try Search.init(std.testing.allocator, "ʃə foo", "(ʃ.)");
    defer search.deinit();
    var match: Match = undefined;
    match.start = 999;
    try std.testing.expect(try search.findInto(category, 1, true, &match));
    try std.testing.expectEqual(@as(u8, 1), match.capture_count);
    try std.testing.expectEqualStrings("ʃə", search.captureValue(match.captures[0]).slice);
    var missing = try Search.init(std.testing.allocator, "ʃə foo", "ζ");
    defer missing.deinit();
    match.start = 999;
    try std.testing.expect(!(try missing.findInto(category, 1, true, &match)));
    try std.testing.expectEqual(@as(usize, 999), match.start);
}

test "unicode literal classes ranges captures and frontier" {
    const fakeCategory = struct {
        fn category(cp: i32) callconv(.c) c_int {
            return if ((cp >= 'A' and cp <= 'Z')) 1 else if ((cp >= 'a' and cp <= 'z') or cp == 0x03b1) 2 else if (cp >= '0' and cp <= '9') 9 else if (cp == ' ') 23 else 0;
        }
    }.category;
    var search = try Search.init(std.testing.allocator, "αβ 12", "^(α.)(%s)(%d+)");
    defer search.deinit();
    const m = (try search.find(fakeCategory, 1, true)).?;
    try std.testing.expectEqualStrings("αβ", search.captureValue(m.captures[0]).slice);
    try std.testing.expectEqualStrings(" ", search.captureValue(m.captures[1]).slice);
    try std.testing.expectEqualStrings("12", search.captureValue(m.captures[2]).slice);
}

test "unicode balanced capture preserves inline modifier" {
    var search = try Search.init(std.testing.allocator, "*man<t:particle expressing solidarity>", "(%b<>)");
    defer search.deinit();
    const found = (try search.find(struct {
        fn category(_: i32) callconv(.c) c_int {
            return 0;
        }
    }.category, 1, true)).?;
    try std.testing.expectEqual(@as(u8, 1), found.capture_count);
    try std.testing.expectEqualStrings("<t:particle expressing solidarity>", search.byteSlice(found.captures[0].slice.start, found.captures[0].slice.end));
}

fn testCategory(cp: i32) callconv(.c) c_int {
    return if (cp >= 'a' and cp <= 'z') 2 else if (cp >= '0' and cp <= '9') 9 else 0;
}

fn expectSameSearch(source: []const u8, pat: []const u8) !void {
    var prepared = try Search.init(std.testing.allocator, source, pat);
    defer prepared.deinit();
    // Force metadata even on tiny test subjects to exercise both matchers.
    prepared.prepared = try classes.Prepared.init(std.testing.allocator, prepared.pattern.codepoints);
    prepared.preparation_attempted = true;
    var raw = try Search.init(std.testing.allocator, source, pat);
    defer raw.deinit();
    raw.preparation_attempted = true;
    for (0..prepared.source.codepoints.len + 1) |start| {
        for ([_]bool{ false, true }) |anchor| {
            const expected = raw.findFrom(testCategory, start, anchor);
            const actual = prepared.findFrom(testCategory, start, anchor);
            if (expected) |want| {
                const got = try actual;
                try std.testing.expectEqual(want == null, got == null);
                if (want) |w| {
                    const g = got.?;
                    try std.testing.expectEqual(w.start, g.start);
                    try std.testing.expectEqual(w.end, g.end);
                    try std.testing.expectEqual(w.capture_count, g.capture_count);
                    for (w.captures[0..w.capture_count], g.captures[0..g.capture_count]) |wc, gc|
                        try std.testing.expectEqualDeep(wc, gc);
                    try std.testing.expectEqualStrings(raw.byteSlice(w.start, w.end), prepared.byteSlice(g.start, g.end));
                }
            } else |err| {
                try std.testing.expectError(err, actual);
            }
        }
    }
}

test "prepared Unicode membership agrees with raw literal parser" {
    var pattern: [101]u21 = @splat('q');
    pattern[0] = '[';
    pattern[100] = ']';
    const empty: classes.Prepared = .{};
    var matcher = Matcher{ .source = &.{}, .pattern = &pattern, .category = testCategory, .prepared = &empty };
    for (0..8) |variant| {
        pattern[1] = if (variant & 1 != 0) '^' else ']';
        pattern[2] = if (variant & 1 != 0) ']' else '-';
        pattern[3] = '-';
        pattern[4] = 0x180;
        pattern[5] = 0x10000;
        pattern[6] = '-';
        pattern[7] = 0x10100;
        pattern[8] = 0;
        pattern[9] = '-';
        pattern[10] = 128;
        pattern[11] = 'z';
        pattern[12] = '-';
        pattern[13] = 'a';
        pattern[14] = 0x10ffff;
        pattern[15] = if (variant & 2 != 0) 0x100 else 0x80;
        pattern[16] = '-';
        pattern[17] = if (variant & 4 != 0) 0x120 else 0x70;
        pattern[99] = '-';
        const prepared = try classes.Prepared.init(std.testing.allocator, &pattern);
        defer prepared.deinit(std.testing.allocator);
        const c = prepared.lookup(0).?;
        for (0..512) |cp| try std.testing.expectEqual(matcher.bracketClass(@intCast(cp), 0, 101), c.matches(@intCast(cp)));
        for ([_]u21{ 0x10000, 0x10001, 0x10100, 0x10101, 0x10fffe, 0x10ffff }) |cp|
            try std.testing.expectEqual(matcher.bracketClass(cp, 0, 101), c.matches(cp));
    }
    // All reversed intervals produce an empty prepared set.
    const reversed = [_]u21{'['} ++ ([_]u21{ 'z', '-', 'a' } ** 24) ++ [_]u21{']'};
    const p = try classes.Prepared.init(std.testing.allocator, &reversed);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), p.classes[0].ranges.len);
    try std.testing.expect(!p.classes[0].matches('a'));
}

test "prepared Unicode searches preserve rollback quantifiers and lazy errors" {
    const body = "q" ** 72;
    const cl = "[" ++ body ++ "α-ωa-c]";
    const neg = "[^" ++ body ++ "α-ωa-c]";
    const patterns = [_][]const u8{
        cl,                       cl ++ "*b",                     cl ++ "+b",             cl ++ "-b",                     cl ++ "?b",
        "^(" ++ cl ++ "+)(b)%1$", "(" ++ cl ++ "*)b%1",           "(" ++ cl ++ "?)(a?)b", cl ++ "*(" ++ neg ++ "+)",      "%f" ++ cl ++ cl ++ "+",
        "%f" ++ neg ++ ".*",      cl ++ "*%f[^" ++ body ++ "%z]", "%b[]" ++ cl,           "%[" ++ cl,                     cl ++ "[",
        "x[",                     cl ++ "*(",                     cl ++ "*%1",            cl ++ "*$",                     cl ++ "*%f",
        "[a-%%]" ++ cl,           "[%-a]" ++ cl,                  "[a-%d]" ++ cl,         "[^" ++ body ++ "\x00]" ++ "*",
    };
    const sources = [_][]const u8{ "", "αβ", "αbα", "qaabaaq", "xxx", "[ab]α", "[α", "aa\x00b", "ααβaqqqb" };
    for (patterns) |pat| for (sources) |source| try expectSameSearch(source, pat);
}

test "Unicode preparation is lazy optional and never retries failed allocation" {
    const long = "[" ++ ("q" ** 72) ++ "]";
    for (0..2) |fail_after| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var search = try Search.init(failing.allocator(), "qqqqqqqq", long);
        const initial = failing.alloc_index;
        try std.testing.expect(!search.preparation_attempted);
        _ = search.findPlain(1);
        try std.testing.expect(!search.preparation_attempted);
        try std.testing.expectEqual(initial, failing.alloc_index);
        failing.fail_index = initial + fail_after;
        const result = (try search.find(testCategory, 1, true)).?;
        try std.testing.expectEqual(@as(usize, 1), result.end);
        try std.testing.expect(search.preparation_attempted);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), search.prepared.classes.len);
        failing.fail_index = std.math.maxInt(usize);
        const after_failure = failing.alloc_index;
        _ = try search.find(testCategory, 1, true);
        try std.testing.expectEqual(after_failure, failing.alloc_index);
        search.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    var prepared = try Search.init(std.testing.allocator, "qqqqqqqq", long);
    defer prepared.deinit();
    _ = try prepared.find(testCategory, 1, true);
    try std.testing.expectEqual(@as(usize, 1), prepared.prepared.classes.len);
    var tiny = try Search.init(std.testing.allocator, "q", long);
    defer tiny.deinit();
    _ = try tiny.find(testCategory, 1, true);
    try std.testing.expectEqual(@as(usize, 0), tiny.prepared.classes.len);
}

test "percent-containing long classes preserve category callback sequence" {
    const Counter = struct {
        var calls: usize = 0;
        fn category(_: i32) callconv(.c) c_int {
            calls += 1;
            return if (calls % 2 == 0) 2 else 0;
        }
    };
    const pat = "[" ++ ("q" ** 72) ++ "%a%g%a]+";
    var a = try Search.init(std.testing.allocator, "gagq", pat);
    defer a.deinit();
    var b = try Search.init(std.testing.allocator, "gagq", pat);
    defer b.deinit();
    b.preparation_attempted = true;
    Counter.calls = 0;
    const am = try a.find(Counter.category, 1, true);
    const calls = Counter.calls;
    Counter.calls = 0;
    const bm = try b.find(Counter.category, 1, true);
    try std.testing.expectEqual(calls, Counter.calls);
    try std.testing.expectEqual(am.?.end, bm.?.end);
    try std.testing.expectEqual(@as(usize, 0), a.prepared.classes.len);
}

test "cached searches retain snapshot semantics after the original pattern is freed" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const key = "[" ++ ("q" ** 128) ++ "]";
    const original = try std.testing.allocator.dupe(u8, key);
    var first = try Search.initWithCache(std.testing.allocator, "qqqqqqqq", original, &cache);
    defer first.deinit();
    std.testing.allocator.free(original);
    const overwrite = try std.testing.allocator.dupe(u8, "x" ** 130);
    defer std.testing.allocator.free(overwrite);
    const m = (try first.find(testCategory, 1, true)).?;
    try std.testing.expectEqual(@as(usize, 1), m.end);
    try std.testing.expect(!first.borrowed_pattern);
    try std.testing.expectEqual(@as(usize, 1), cache.entry_count);
    const entry = cache.lookup(key).?;
    try std.testing.expect(cache.lookup(overwrite) == null);
    var second = try Search.initWithCache(std.testing.allocator, "q", key, &cache);
    defer second.deinit();
    try std.testing.expect(second.borrowed_pattern);
    try std.testing.expect(second.pattern.codepoints.ptr == entry.codepoints.ptr);
    try std.testing.expect((try second.find(testCategory, 1, true)) != null);
}

test "cache admission stays lazy and tiny misses do not prepare" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const key = "[" ++ ("q" ** 128) ++ "]";
    {
        var unused = try Search.initWithCache(std.testing.allocator, "qqqqqqqq", key, &cache);
        defer unused.deinit();
        try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
    }
    {
        var plain = try Search.initWithCache(std.testing.allocator, key, key, &cache);
        defer plain.deinit();
        try std.testing.expect(plain.findPlain(1) != null);
        try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
    }
    {
        var tiny = try Search.initWithCache(std.testing.allocator, "q", key, &cache);
        defer tiny.deinit();
        try std.testing.expect((try tiny.find(testCategory, 1, true)) != null);
        try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
    }
    var real = try Search.initWithCache(std.testing.allocator, "qqqqqqqq", key, &cache);
    defer real.deinit();
    try std.testing.expect((try real.find(testCategory, 1, true)) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.entry_count);
    const before = cache.hits;
    try std.testing.expectError(error.InvalidUtf8, Search.initWithCache(std.testing.allocator, "\xff", key, &cache));
    try std.testing.expectEqual(before, cache.hits);
}

test "cache allocation failure preserves ordinary prepared search" {
    const key = "[" ++ ("q" ** 128) ++ "]";
    for (0..5) |failure| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure });
        var cache = PatternCache.init(std.testing.io, failing.allocator());
        {
            var search = try Search.initWithCache(std.testing.allocator, "qqqqqqqq", key, &cache);
            defer search.deinit();
            const found = (try search.find(testCategory, 1, true)).?;
            try std.testing.expectEqual(@as(usize, 1), found.end);
            try std.testing.expectEqual(@as(usize, 0), cache.entry_count);
            try std.testing.expectEqual(@as(usize, 1), search.prepared.classes.len);
        }
        cache.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "borrowed search survives cache saturation by nested searches" {
    var cache = PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const key = "[" ++ ("q" ** 128) ++ "]+";
    var outer = try Search.initWithCache(std.testing.allocator, "qqqqqqqq", key, &cache);
    defer outer.deinit();
    try std.testing.expectEqual(@as(usize, 8), (try outer.find(testCategory, 1, true)).?.end);
    const entry = outer.cache_entry.?;
    var cps: [130]u21 = @splat('z');
    cps[0] = '[';
    cps[129] = ']';
    for (0..PatternCache.max_entries + 1) |i| {
        cps[1] = @intCast(0x100 + i);
        _ = cache.admit(&cps);
    }
    try std.testing.expectEqual(@as(usize, PatternCache.max_entries), cache.entry_count);
    try std.testing.expect(outer.cache_entry.? == entry);
    try std.testing.expectEqual(@as(usize, 8), (try outer.findFrom(testCategory, 2, true)).?.end);
}

test { _ = @import("pattern_cache_tests.zig"); }
