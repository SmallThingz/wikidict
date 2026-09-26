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
        // A non-greedy dot accepts every byte. If the following item starts
        // with a mandatory literal, only those source positions can succeed.
        // Keep matchWithRollback at each candidate so captures and later
        // failures retain the normal Lua pattern behavior.
        if (self.pattern[p] == '.') if (requiredStartByte(self.pattern, next)) |literal| {
            var candidate = s;
            while (std.mem.indexOfScalarPos(u8, self.source, candidate, literal)) |found| {
                if (try self.matchWithRollback(found, next)) |result| return result;
                candidate = found + 1;
            }
            return null;
        };
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

fn requiredFindStartByte(pattern: []const u8, start: usize) ?u8 {
    var p = start;
    var captures: usize = 0;
    // Opening and position captures consume no source bytes. Preserve the
    // TooManyCaptures error before skipping any candidate source position.
    while (p < pattern.len and pattern[p] == '(') {
        captures += 1;
        if (captures > max_captures) return null;
        p += if (p + 1 < pattern.len and pattern[p + 1] == ')') @as(usize, 2) else 1;
    }
    if (p >= pattern.len) return null;
    var next = p + 1;
    const literal: u8 = if (pattern[p] == '%') blk: {
        if (next >= pattern.len) return null;
        const escaped = pattern[next];
        // %b and %f have special behavior, %1..%9 are backreferences, and
        // letter classes can match more than one byte. Other escapes are
        // literal under matchClass, including %[, %-, and %0.
        if (escaped == 'b' or escaped == 'f' or
            (escaped >= '1' and escaped <= '9')) return null;
        switch (std.ascii.toLower(escaped)) {
            'a', 'c', 'd', 'g', 'l', 'p', 's', 'u', 'w', 'x', 'z' => return null,
            else => {},
        }
        next += 1;
        break :blk escaped;
    } else blk: {
        if (isPatternMagic(pattern[p])) return null;
        break :blk pattern[p];
    };
    if (next < pattern.len) switch (pattern[next]) {
        '?', '*', '-' => return null,
        else => {},
    };
    return literal;
}

// A mandatory initial byte class can reject source positions before running
// the recursive matcher. Inspect only a class at byte zero: leading captures,
// frontier assertions and backreferences may have observable error behavior.
// Invalid classes fall back to matchAt, which retains the original error order.
fn requiredFindStartClass(pattern: []const u8) ?usize {
    if (pattern.len == 0) return null;
    const ep: usize = switch (pattern[0]) {
        '[' => blk: {
            const matcher = Matcher{ .source = "", .pattern = pattern };
            break :blk matcher.classEnd(0) catch return null;
        },
        '%' => blk: {
            if (pattern.len < 2) return null;
            switch (std.ascii.toLower(pattern[1])) {
                'a', 'c', 'd', 'g', 'l', 'p', 's', 'u', 'w', 'x', 'z' => {},
                else => return null,
            }
            break :blk 2;
        },
        else => return null,
    };
    if (ep < pattern.len) switch (pattern[ep]) {
        '?', '*', '-' => return null,
        else => {},
    };
    return ep;
}

fn findInto(source: []const u8, pattern: []const u8, initial: usize, honor_anchor: bool, out: *Match) Error!bool {
    var start = initial;
    if (start > source.len) return false;
    var pattern_start: usize = 0;
    const anchored = honor_anchor and pattern.len != 0 and pattern[0] == '^';
    if (anchored) pattern_start = 1;
    if (!anchored and isLiteralPattern(pattern)) {
        const found = std.mem.indexOfPos(u8, source, start, pattern) orelse return false;
        out.start = found;
        out.end = found + pattern.len;
        out.capture_count = 0;
        return true;
    }
    const required_start = if (anchored) null else requiredFindStartByte(pattern, pattern_start);
    var matcher: Matcher = undefined;
    matcher.source = source;
    matcher.pattern = pattern;
    const required_class_end = if (!anchored and required_start == null and source.len - start >= 16)
        requiredFindStartClass(pattern[pattern_start..])
    else
        null;
    while (start <= source.len) : (start += 1) {
        if (required_start) |literal| {
            start = std.mem.indexOfScalarPos(u8, source, start, literal) orelse return false;
        } else if (required_class_end) |ep| {
            while (start < source.len and !matcher.singleMatch(source[start], pattern_start, pattern_start + ep))
                start += 1;
            if (start == source.len) return false;
        }
        matcher.level = 0;
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

pub fn findIntoStart(source: []const u8, pattern: []const u8, init: i64, out: *Match) Error!bool {
    return findInto(source, pattern, normalizeStart(source.len, init), true, out);
}

fn findFrom(source: []const u8, pattern: []const u8, initial: usize, honor_anchor: bool) Error!?Match {
    var match: Match = undefined;
    if (!(try findInto(source, pattern, initial, honor_anchor, &match))) return null;
    return match;
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
        var found: Match = undefined;
        if (!(try findInto(self.source, self.pattern, self.next_start, false, &found))) {
            self.done = true;
            return null;
        }
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

test "findInto preserves output on misses and errors and copies live captures" {
    var match: Match = undefined;
    match.start = 999;
    match.end = 999;
    match.capture_count = 0;
    try std.testing.expect(!(try findIntoStart("abc", "z", 1, &match)));
    try std.testing.expectEqual(@as(usize, 999), match.start);
    try std.testing.expectError(error.MalformedPattern, findIntoStart("abc", "[", 1, &match));
    try std.testing.expectEqual(@as(usize, 999), match.start);
    try std.testing.expect(try findIntoStart("abc 123", "(%a+)%s+(%d+)", 1, &match));
    try std.testing.expectEqual(@as(u8, 2), match.capture_count);
    try std.testing.expectEqualStrings("abc", try captureText("abc 123", match.captures[0]));
    try std.testing.expectEqualStrings("123", try captureText("abc 123", match.captures[1]));
    try std.testing.expect(try findIntoStart("abc 123", "abc", 1, &match));
    try std.testing.expectEqual(@as(u8, 0), match.capture_count);
    try std.testing.expectEqual(@as(usize, 3), match.end);
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

test "lazy dot skips impossible suffix starts without changing captures or errors" {
    const source = "abqabx";
    const selected = (try find(source, "a.-bx", 1)).?;
    try std.testing.expectEqualStrings("abqabx", source[selected.start..selected.end]);
    const captured = (try find("title#fragment", "^(.-)#(.+)$", 1)).?;
    try std.testing.expectEqualStrings("title", try captureText("title#fragment", captured.captures[0]));
    try std.testing.expectEqualStrings("fragment", try captureText("title#fragment", captured.captures[1]));
    try std.testing.expect((try find("aaaa", "a.-b[", 1)) == null);
    try std.testing.expectError(error.MalformedPattern, find("ab", "a.-b[", 1));
}

test "required initial byte class skips nonmatching starts and preserves suffix errors" {
    const source = "!" ** 80 ++ "az123";
    const bracket = (try find(source, "[a-z]+%d+", 1)).?;
    try std.testing.expectEqual(@as(usize, 80), bracket.start);
    try std.testing.expectEqual(@as(usize, 85), bracket.end);
    const escaped = (try find(source, "%a+%d+", 1)).?;
    try std.testing.expectEqual(@as(usize, 80), escaped.start);
    try std.testing.expect((try find("!" ** 80, "[a-z]+%d+", 1)) == null);
    try std.testing.expectError(error.MalformedPattern, find(source, "[a-z]+[", 1));
    // A zero-width first item must still be tried at the initial position.
    const optional = (try find("!" ** 80 ++ "b", "[a]?b", 1)).?;
    try std.testing.expectEqual(@as(usize, 80), optional.start);
    try std.testing.expectError(error.MalformedPattern, find(source, "[", 1));
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

test "required start skips leading captures and literal escapes without hiding errors" {
    const source = "xxxx<abc>";
    const tag = (try find(source, "((<[^>]+>))", 1)).?;
    try std.testing.expectEqual(@as(usize, 4), tag.start);
    try std.testing.expectEqualStrings("<abc>", try captureText(source, tag.captures[0]));
    try std.testing.expectEqualStrings("<abc>", try captureText(source, tag.captures[1]));
    const escaped = (try find("abc[", "((%[))", 1)).?;
    try std.testing.expectEqual(@as(usize, 3), escaped.start);
    try std.testing.expectEqualStrings("[", try captureText("abc[", escaped.captures[0]));
    try std.testing.expect((try find("bbb", "((a?b))", 1)) != null);
    try std.testing.expect((try find("zzz", "((a[", 1)) == null);
    try std.testing.expectError(error.MalformedPattern, find("a", "((a[", 1));
    var too_many: [34]u8 = undefined;
    @memset(too_many[0..33], '(');
    too_many[33] = 'x';
    try std.testing.expectError(error.TooManyCaptures, find("zz", &too_many, 1));
    var exactly: [33]u8 = undefined;
    @memset(exactly[0..32], '(');
    exactly[32] = 'x';
    try std.testing.expect((try find("zz", &exactly, 1)) == null);
    try std.testing.expectError(error.UnfinishedCapture, find("x", &exactly, 1));
}

test "lazy suffix respects total captures already open" {
    var too_many: [37]u8 = undefined;
    too_many[0] = '(';
    too_many[1] = 'a';
    too_many[2] = '.';
    too_many[3] = '-';
    @memset(too_many[4..36], '(');
    too_many[36] = 'z';
    try std.testing.expectError(error.TooManyCaptures, find("abc", &too_many, 1));

    var exactly: [36]u8 = undefined;
    exactly[0] = '(';
    exactly[1] = 'a';
    exactly[2] = '.';
    exactly[3] = '-';
    @memset(exactly[4..35], '(');
    exactly[35] = 'z';
    try std.testing.expect((try find("abc", &exactly, 1)) == null);
    try std.testing.expectError(error.UnfinishedCapture, find("az", &exactly, 1));
}
