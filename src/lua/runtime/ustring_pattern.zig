const std = @import("std");

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
    codepoints: []u21,
    bytepos: []usize,

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
    captures: [max_captures]Capture = undefined,
    level: u8 = 0,

    fn classEnd(self: *const Matcher, p: usize) Error!usize {
        if (p >= self.pattern.len) return error.MalformedPattern;
        return switch (self.pattern[p]) {
            '%' => if (p + 1 < self.pattern.len) p + 2 else error.MalformedPattern,
            '[' => blk: {
                var i = p + 1;
                if (i < self.pattern.len and self.pattern[i] == '^') i += 1;
                if (i < self.pattern.len and self.pattern[i] == ']') i += 1;
                while (i < self.pattern.len and self.pattern[i] != ']') {
                    if (self.pattern[i] == '%' and i + 1 < self.pattern.len) i += 2 else i += 1;
                }
                if (i >= self.pattern.len) return error.MalformedPattern;
                break :blk i + 1;
            },
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

    fn singleMatch(self: *const Matcher, cp: u21, p: usize, ep: usize) bool {
        return switch (self.pattern[p]) {
            '.' => true,
            '%' => categoryMatch(self.category, cp, self.pattern[p + 1]),
            '[' => self.bracketClass(cp, p, ep),
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

    fn maxExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize) Error!?usize {
        var count: usize = 0;
        while (s + count < self.source.len and self.singleMatch(self.source[s + count], p, ep)) count += 1;
        while (true) {
            const saved = self.captures;
            const saved_level = self.level;
            if (try self.matchAt(s + count, next)) |result| return result;
            self.captures = saved;
            self.level = saved_level;
            if (count == 0) return null;
            count -= 1;
        }
    }

    fn minExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize) Error!?usize {
        var i = s;
        while (true) {
            const saved = self.captures;
            const saved_level = self.level;
            if (try self.matchAt(i, next)) |result| return result;
            self.captures = saved;
            self.level = saved_level;
            if (i >= self.source.len or !self.singleMatch(self.source[i], p, ep)) return null;
            i += 1;
        }
    }

    fn frontier(self: *Matcher, s: usize, p: usize) Error!?usize {
        if (p >= self.pattern.len or self.pattern[p] != '[') return error.MalformedPattern;
        const ep = try self.classEnd(p);
        const previous: u21 = if (s == 0) 0 else self.source[s - 1];
        const current: u21 = if (s == self.source.len) 0 else self.source[s];
        if (self.bracketClass(previous, p, ep) or !self.bracketClass(current, p, ep)) return null;
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
            const ep = try self.classEnd(p);
            const matched = s < self.source.len and self.singleMatch(self.source[s], p, ep);
            if (ep < self.pattern.len) switch (self.pattern[ep]) {
                '?' => {
                    if (matched) {
                        const saved = self.captures;
                        const saved_level = self.level;
                        if (try self.matchAt(s + 1, ep + 1)) |r| return r;
                        self.captures = saved;
                        self.level = saved_level;
                    }
                    p = ep + 1;
                    continue;
                },
                '*' => return self.maxExpand(s, p, ep, ep + 1),
                '+' => {
                    if (!matched) return null;
                    return self.maxExpand(s + 1, p, ep, ep + 1);
                },
                '-' => return self.minExpand(s, p, ep, ep + 1),
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

fn findDecoded(source: []const u21, pat: []const u21, category: CategoryFn, initial: usize, honor_anchor: bool) Error!?Match {
    var start = @min(initial, source.len);
    var pattern_start: usize = 0;
    const anchored = honor_anchor and pat.len != 0 and pat[0] == '^';
    if (anchored) pattern_start = 1;
    while (start <= source.len) : (start += 1) {
        var matcher = Matcher{ .source = source, .pattern = pat, .category = category };
        const end = try matcher.matchAt(start, pattern_start) orelse {
            if (anchored) return null;
            continue;
        };
        for (matcher.captures[0..matcher.level]) |capture|
            if (capture == .unfinished) return error.UnfinishedCapture;
        return .{ .start = start, .end = end, .captures = matcher.captures, .capture_count = matcher.level };
    }
    return null;
}

pub const Search = struct {
    source_bytes: []const u8,
    pattern_bytes: []const u8,
    source: Decoded,
    pattern: Decoded,
    allocator: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, source: []const u8, pat: []const u8) !Search {
        const src = try decode(a, source);
        errdefer src.deinit(a);
        const pattern = try decode(a, pat);
        return .{ .source_bytes = source, .pattern_bytes = pat, .source = src, .pattern = pattern, .allocator = a };
    }

    pub fn deinit(self: Search) void {
        self.source.deinit(self.allocator);
        self.pattern.deinit(self.allocator);
    }

    pub fn find(self: *const Search, category: CategoryFn, init_index: i64, honor_anchor: bool) Error!?Match {
        return findDecoded(self.source.codepoints, self.pattern.codepoints, category, normalizeStart(self.source.codepoints.len, init_index), honor_anchor);
    }

    pub fn findFrom(self: *const Search, category: CategoryFn, start: usize, honor_anchor: bool) Error!?Match {
        return findDecoded(self.source.codepoints, self.pattern.codepoints, category, start, honor_anchor);
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
