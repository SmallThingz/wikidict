const std = @import("std");

// Immutable membership metadata for long, percent-free Unicode brackets.
// Escaped classes deliberately retain the original callback/evaluation order.
pub const Range = struct { lo: u21, hi: u21 };
pub const Class = struct {
    start: usize,
    end: usize,
    inverted: bool,
    ranges: []const Range,

    pub fn matches(self: Class, cp: u21) bool {
        var lo: usize = 0;
        var hi = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const range = self.ranges[mid];
            if (cp < range.lo) {
                hi = mid;
            } else if (cp > range.hi) {
                lo = mid + 1;
            } else return !self.inverted;
        }
        return self.inverted;
    }
};

pub fn bracketEnd(pattern: []const u21, p: usize) ?usize {
    var i = p + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len and pattern[i] != ']') {
        if (pattern[i] == '%' and i + 1 < pattern.len) i += 2 else i += 1;
    }
    return if (i < pattern.len) i + 1 else null;
}

pub const Prepared = struct {
    classes: []const Class = &.{},
    // Keep the allocation separate from the shortened merged range views.
    storage: []const Range = &.{},

    pub fn deinit(self: Prepared, allocator: std.mem.Allocator) void {
        allocator.free(self.classes);
        allocator.free(self.storage);
    }

    pub fn lookup(self: *const Prepared, p: usize) ?*const Class {
        var lo: usize = 0;
        var hi = self.classes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const class = &self.classes[mid];
            if (p < class.start) hi = mid else if (p > class.start) lo = mid + 1 else return class;
        }
        return null;
    }

    // An optional acceleration: caller falls back on any allocation failure.
    // Discovery must never report a syntax error ahead of actual matching.
    const AllocationPlan = struct {
        classes: usize = 0,
        capacity: usize = 0,

        fn bytes(self: AllocationPlan) usize {
            return self.classes * @sizeOf(Class) + self.capacity * @sizeOf(Range);
        }
    };

    fn allocationPlan(pattern: []const u21) AllocationPlan {
        if (pattern.len < 66) return .{};
        var scan = Scanner{ .pattern = pattern };
        var plan: AllocationPlan = .{};
        while (scan.next()) |item| {
            plan.classes += 1;
            plan.capacity += item.end - item.start;
            if (plan.bytes() > 256 * 1024) return .{};
        }
        return plan;
    }

    pub fn allocationBytes(pattern: []const u21) usize {
        return allocationPlan(pattern).bytes();
    }

    pub fn init(allocator: std.mem.Allocator, pattern: []const u21) !Prepared {
        const plan = allocationPlan(pattern);
        const classes = plan.classes;
        const capacity = plan.capacity;
        if (classes == 0) return .{};
        var scan = Scanner{ .pattern = pattern };
        const descriptors = try allocator.alloc(Class, classes);
        errdefer allocator.free(descriptors);
        const storage = try allocator.alloc(Range, capacity);
        errdefer allocator.free(storage);
        scan = .{ .pattern = pattern };
        var index: usize = 0;
        var used: usize = 0;
        while (scan.next()) |item| : (index += 1) {
            var i = item.start + 1;
            const inverted = pattern[i] == '^';
            if (inverted) i += 1;
            const begin = used;
            if (pattern[i] == ']') {
                storage[used] = .{ .lo = ']', .hi = ']' };
                used += 1;
                i += 1;
            }
            while (i + 1 < item.end) {
                if (i + 2 < item.end and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                    if (pattern[i] <= pattern[i + 2]) {
                        storage[used] = .{ .lo = pattern[i], .hi = pattern[i + 2] };
                        used += 1;
                    }
                    i += 3;
                } else {
                    storage[used] = .{ .lo = pattern[i], .hi = pattern[i] };
                    used += 1;
                    i += 1;
                }
            }
            const raw = storage[begin..used];
            var sorted = true;
            for (1..@max(1, raw.len)) |n| {
                if (lessThan({}, raw[n], raw[n - 1])) {
                    sorted = false;
                    break;
                }
            }
            if (!sorted) std.mem.sort(Range, raw, {}, lessThan);
            var merged: usize = 0;
            for (raw) |range| {
                if (merged > 0 and @as(u32, range.lo) <= @as(u32, raw[merged - 1].hi) + 1) {
                    raw[merged - 1].hi = @max(raw[merged - 1].hi, range.hi);
                } else {
                    raw[merged] = range;
                    merged += 1;
                }
            }
            descriptors[index] = .{ .start = item.start, .end = item.end, .inverted = inverted, .ranges = raw[0..merged] };
        }
        return .{ .classes = descriptors, .storage = storage };
    }
};

fn lessThan(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi);
}

const Scanner = struct {
    pattern: []const u21,
    pos: usize = 0,
    const Item = struct { start: usize, end: usize };

    fn next(self: *Scanner) ?Item {
        while (self.pos < self.pattern.len) {
            const p = self.pos;
            if (self.pattern[p] == '%') {
                if (p + 1 >= self.pattern.len) {
                    self.pos = self.pattern.len;
                    return null;
                }
                self.pos = @min(self.pattern.len, p + (if (self.pattern[p + 1] == 'b') @as(usize, 4) else 2));
                continue;
            }
            if (self.pattern[p] != '[') {
                self.pos += 1;
                continue;
            }
            const ep = bracketEnd(self.pattern, p) orelse {
                self.pos = self.pattern.len;
                return null;
            };
            self.pos = ep;
            if (ep - p < 66 or std.mem.indexOfScalar(u21, self.pattern[p..ep], '%') != null) continue;
            return .{ .start = p, .end = ep };
        }
        return null;
    }
};

test "long ranges prepare, merge, invert and retain allocation ownership" {
    const a = std.testing.allocator;
    var pattern: [100]u21 = @splat('q');
    pattern[0] = '[';
    pattern[1] = '^';
    pattern[2] = ']';
    pattern[3] = 0x10ffff;
    pattern[4] = '-';
    pattern[5] = 0x10ffff;
    pattern[6] = 'z';
    pattern[7] = '-';
    pattern[8] = 'a'; // empty reversed range
    pattern[9] = 0;
    pattern[10] = '-';
    pattern[11] = 128;
    pattern[99] = ']';
    const prepared = try Prepared.init(a, &pattern);
    defer prepared.deinit(a);
    const c = prepared.lookup(0).?;
    try std.testing.expect(!c.matches(0));
    try std.testing.expect(!c.matches(127));
    try std.testing.expect(!c.matches(128));
    try std.testing.expect(c.matches(129));
    try std.testing.expect(!c.matches(0x10ffff));
    try std.testing.expect(c.matches(0x10fffe));
    try std.testing.expect(prepared.lookup(1) == null);
}

test "escaped and short classes retain raw matching" {
    const a = std.testing.allocator;
    const short = [_]u21{ '[', 'a', '-', 'z', ']' };
    const p = try Prepared.init(a, &short);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), p.classes.len);
    var escaped: [100]u21 = @splat('a');
    escaped[0] = '[';
    escaped[20] = '%';
    escaped[21] = 'a';
    escaped[99] = ']';
    const q = try Prepared.init(a, &escaped);
    defer q.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), q.classes.len);
}

test "optional preparation allocation failures release partial storage" {
    const Runner = struct {
        fn run(a: std.mem.Allocator) !void {
            var pattern: [100]u21 = @splat('q');
            pattern[0] = '[';
            pattern[99] = ']';
            const p = try Prepared.init(a, &pattern);
            defer p.deinit(a);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Runner.run, .{});
}
