const std = @import("std");

pub const max_captures = 32;
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
    MalformedPattern,
    TooManyCaptures,
    InvalidCapture,
    UnfinishedCapture,
};

const Matcher = struct {
    source: []const u8,
    pattern: []const u8,
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

    fn matchClass(c: u8, cl: u8) bool {
        const lower = std.ascii.toLower(cl);
        const yes = switch (lower) {
            'a' => std.ascii.isAlphabetic(c),
            'c' => c < 0x20 or c == 0x7f,
            'd' => std.ascii.isDigit(c),
            'g' => c >= 0x21 and c <= 0x7e,
            'l' => std.ascii.isLower(c),
            'p' => c >= 0x21 and c <= 0x7e and !std.ascii.isAlphanumeric(c),
            's' => std.ascii.isWhitespace(c),
            'u' => std.ascii.isUpper(c),
            'w' => std.ascii.isAlphanumeric(c),
            'x' => std.ascii.isHex(c),
            'z' => c == 0,
            else => return c == cl,
        };
        return if (std.ascii.isUpper(cl)) !yes else yes;
    }

    fn bracketClass(self: *const Matcher, c: u8, p: usize, ep: usize) bool {
        var i = p + 1;
        var sig = true;
        if (i < ep and self.pattern[i] == '^') {
            sig = false;
            i += 1;
        }
        while (i + 1 < ep) {
            if (self.pattern[i] == '%') {
                if (i + 1 < ep and matchClass(c, self.pattern[i + 1])) return sig;
                i += 2;
                continue;
            }
            // ep points one byte past the closing ']'. A range endpoint must
            // be inside the class, not the closing bracket itself. Without
            // this guard a trailing literal '-' in e.g. [a-z._-] is consumed
            // as the middle of a bogus '_-]' range.
            if (i + 3 < ep and self.pattern[i + 1] == '-') {
                if (self.pattern[i] <= c and c <= self.pattern[i + 2]) return sig;
                i += 3;
                continue;
            }
            if (self.pattern[i] == c) return sig;
            i += 1;
        }
        return !sig;
    }

    fn singleMatch(self: *const Matcher, c: u8, p: usize, ep: usize) bool {
        return switch (self.pattern[p]) {
            '.' => true,
            '%' => matchClass(c, self.pattern[p + 1]),
            '[' => self.bracketClass(c, p, ep),
            else => self.pattern[p] == c,
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

    fn checkCapture(self: *const Matcher, digit: u8) Error!usize {
        if (digit < '1' or digit > '9') return error.InvalidCapture;
        const index: usize = digit - '1';
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

    fn matchCapture(self: *Matcher, s: usize, digit: u8) Error!?usize {
        const index = try self.checkCapture(digit);
        const cap = self.captures[index].slice;
        const len = cap.end - cap.start;
        if (len > self.source.len - s) return null;
        if (!std.mem.eql(u8, self.source[cap.start..cap.end], self.source[s .. s + len])) return null;
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

    fn maxExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize) Error!?usize {
        var count: usize = 0;
        while (s + count < self.source.len and self.singleMatch(self.source[s + count], p, ep)) count += 1;
        while (true) {
            if (try self.matchWithRollback(s + count, next)) |result| return result;
            if (count == 0) return null;
            count -= 1;
        }
    }
    fn minExpand(self: *Matcher, s: usize, p: usize, ep: usize, next: usize) Error!?usize {
        var i = s;
        while (true) {
            if (try self.matchWithRollback(i, next)) |result| return result;
            if (i >= self.source.len or !self.singleMatch(self.source[i], p, ep)) return null;
            i += 1;
        }
    }

    fn frontier(self: *Matcher, s: usize, p: usize) Error!?usize {
        if (p >= self.pattern.len or self.pattern[p] != '[') return error.MalformedPattern;
        const ep = try self.classEnd(p);
        const previous: u8 = if (s == 0) 0 else self.source[s - 1];
        const current: u8 = if (s == self.source.len) 0 else self.source[s];
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
                    if (matched) if (try self.matchWithRollback(s + 1, ep + 1)) |r| return r;
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
    if (raw > n + 1) return len + 1;
    return @intCast(raw - 1);
}

fn isPatternMagic(c: u8) bool {
    return switch (c) {
        '^', '$', '(', ')', '%', '.', '[', ']', '*', '+', '-', '?' => true,
        else => false,
    };
}

fn isLiteralPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |c| if (isPatternMagic(c)) return false;
    return true;
}

fn requiredStartByte(pattern: []const u8, start: usize) ?u8 {
    if (start >= pattern.len or isPatternMagic(pattern[start])) return null;
    const next = start + 1;
    if (next < pattern.len) switch (pattern[next]) {
        '?', '*', '-' => return null,
        else => {},
    };
    return pattern[start];
}

fn findFrom(source: []const u8, pattern: []const u8, initial: usize, honor_anchor: bool) Error!?Match {
    var start = initial;
    if (start > source.len) return null;
    var pattern_start: usize = 0;
    const anchored = honor_anchor and pattern.len != 0 and pattern[0] == '^';
    if (anchored) pattern_start = 1;
    if (!anchored and isLiteralPattern(pattern)) {
        const found = std.mem.indexOfPos(u8, source, start, pattern) orelse return null;
        return .{ .start = found, .end = found + pattern.len, .captures = undefined, .capture_count = 0 };
    }
    const required_start = if (anchored) null else requiredStartByte(pattern, pattern_start);
    var matcher = Matcher{ .source = source, .pattern = pattern };
    while (start <= source.len) : (start += 1) {
        if (required_start) |literal|
            start = std.mem.indexOfScalarPos(u8, source, start, literal) orelse return null;
        matcher.level = 0;
        const end = try matcher.matchAt(start, pattern_start) orelse {
            if (anchored) return null;
            continue;
        };
        for (matcher.captures[0..matcher.level]) |capture|
            if (capture == .unfinished) return error.UnfinishedCapture;
        return .{
            .start = start,
            .end = end,
            .captures = matcher.captures,
            .capture_count = matcher.level,
        };
    }
    return null;
}

pub fn find(source: []const u8, pattern: []const u8, init: i64) Error!?Match {
    return findFrom(source, pattern, normalizeStart(source.len, init), true);
}

pub fn captureText(source: []const u8, capture: Capture) Error![]const u8 {
    return switch (capture) {
        .slice => |s| source[s.start..s.end],
        .position => error.InvalidCapture,
        .unfinished => error.UnfinishedCapture,
    };
}

pub const Iterator = struct {
    source: []const u8,
    pattern: []const u8,
    next_start: usize = 0,
    last_end: usize = 0,
    done: bool = false,

    pub fn next(self: *Iterator) Error!?Match {
        if (self.done) return null;
        const found = try findFrom(self.source, self.pattern, self.next_start, false) orelse {
            self.done = true;
            return null;
        };
        if (found.end == found.start) {
            if (found.end >= self.source.len) self.done = true else self.next_start = found.end + 1;
        } else self.next_start = found.end;
        self.last_end = found.end;
        return found;
    }
};

test "literal classes captures and anchors" {
    const m = (try find("abc 123 xyz", "^(%a+)%s+(%d+)", 1)).?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqualStrings("abc", try captureText("abc 123 xyz", m.captures[0]));
    try std.testing.expectEqualStrings("123", try captureText("abc 123 xyz", m.captures[1]));
    try std.testing.expect((try find("zabc", "^abc", 1)) == null);
    try std.testing.expect((try find("zabc", "abc", 1)) != null);
}

test "language-code class accepts literal trailing hyphen" {
    const m = (try find("roa-opt:frei", "^([a-zA-Z][a-zA-Z0-9._-]*):(.*)$", 1)).?;
    try std.testing.expectEqual(@as(u8, 2), m.capture_count);
    try std.testing.expectEqualStrings("roa-opt", try captureText("roa-opt:frei", m.captures[0]));
    try std.testing.expectEqualStrings("frei", try captureText("roa-opt:frei", m.captures[1]));
}

test "literal and required-prefix searches skip impossible starts without changing pattern semantics" {
    const literal = (try find("zzneedlezz", "needle", 1)).?;
    try std.testing.expectEqual(@as(usize, 2), literal.start);
    try std.testing.expectEqual(@as(usize, 8), literal.end);
    try std.testing.expectEqual(@as(u8, 0), literal.capture_count);

    const prefixed = (try find("xxxxaa7", "a+%d", 1)).?;
    try std.testing.expectEqual(@as(usize, 4), prefixed.start);
    try std.testing.expectEqual(@as(usize, 7), prefixed.end);

    const zero_width = (try find("bbb", "a*b", 1)).?;
    try std.testing.expectEqual(@as(usize, 0), zero_width.start);
    try std.testing.expectEqual(@as(usize, 1), zero_width.end);
    try std.testing.expectError(error.MalformedPattern, find("xxa", "a[", 1));
}

test "balanced frontier backref and nongreedy" {
    const b = (try find("x(a(b)c)y", "%b()", 1)).?;
    try std.testing.expectEqualStrings("(a(b)c)", "x(a(b)c)y"[b.start..b.end]);
    const f = (try find("foo bar", "%f[%a]bar", 1)).?;
    try std.testing.expectEqual(@as(usize, 4), f.start);
    const r = (try find("abcabc", "(%a+)%1", 1)).?;
    try std.testing.expectEqualStrings("abcabc", "abcabc"[r.start..r.end]);
    const ng = (try find("a123b456b", "a.-b", 1)).?;
    try std.testing.expectEqualStrings("a123b", "a123b456b"[ng.start..ng.end]);
}
