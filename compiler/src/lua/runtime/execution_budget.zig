const std = @import("std");

// Wikimedia's LuaSandbox limit is cumulative CPU time for the parser's engine.
// This is a semantic script limit, independent of the worker's operational
// address-space and wall-clock limits. Generated Lua checks the shared budget
// at function entries and loop backedges; no Context/Value layout changes.
pub const default_limit_ns: u64 = 10 * std.time.ns_per_s;
pub const sample_period: u32 = 4096;
threadlocal var active: ?*Budget = null;

fn cpuNow() error{LuaCpuClockUnavailable}!u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.THREAD_CPUTIME_ID, &ts)) != .SUCCESS)
        return error.LuaCpuClockUnavailable;
    const seconds = std.math.cast(u64, ts.sec) orelse return error.LuaCpuClockUnavailable;
    const nanos = std.math.cast(u64, ts.nsec) orelse return error.LuaCpuClockUnavailable;
    return std.math.add(u64, std.math.mul(u64, seconds, std.time.ns_per_s) catch return error.LuaCpuClockUnavailable, nanos) catch return error.LuaCpuClockUnavailable;
}

pub const Budget = struct {
    limit_ns: u64 = default_limit_ns,
    used_ns: u64 = 0,
    started_ns: ?u64 = null,
    ticks: u32 = sample_period,
    expired: bool = false,
    clock_failed: bool = false,
    allow_pause: bool = true,
    clock: *const fn () error{LuaCpuClockUnavailable}!u64 = cpuNow,

    pub fn reset(self: *Budget) void {
        std.debug.assert(active != self and self.started_ns == null);
        self.used_ns = 0;
        self.expired = false;
        self.clock_failed = false;
        self.ticks = sample_period;
    }

    pub fn checkState(self: *Budget) !void {
        if (self.clock_failed) return error.LuaCpuClockUnavailable;
        if (self.expired) return error.LuaCpuLimit;
    }

    fn account(self: *Budget) !void {
        const start = self.started_ns orelse return self.checkState();
        const now = self.clock() catch |err| {
            self.clock_failed = true;
            return err;
        };
        self.used_ns +|= now -| start;
        self.started_ns = now;
        if (self.used_ns >= self.limit_ns) self.expired = true;
        try self.checkState();
    }

    pub fn enter(self: *Budget) !Scope {
        try self.checkState();
        if (active == self) {
            const allowed = self.allow_pause;
            self.allow_pause = false;
            return .{ .budget = self, .previous = self, .nested = true, .previous_allow_pause = allowed };
        }
        const previous = active;
        if (previous) |outer| {
            try outer.account();
            outer.started_ns = null;
        }
        self.started_ns = self.clock() catch |err| {
            self.clock_failed = true;
            if (previous) |outer| outer.started_ns = outer.clock() catch blk: {
                outer.clock_failed = true;
                break :blk null;
            };
            return err;
        };
        const allowed = self.allow_pause;
        self.allow_pause = previous == null;
        active = self;
        return .{ .budget = self, .previous = previous, .previous_allow_pause = allowed };
    }
};

pub const Scope = struct {
    budget: *Budget,
    previous: ?*Budget,
    nested: bool = false,
    previous_allow_pause: bool,
    finished: bool = false,

    pub fn finish(self: *Scope) !void {
        std.debug.assert(!self.finished and active == self.budget);
        self.finished = true;
        defer self.budget.allow_pause = self.previous_allow_pause;
        if (self.nested) return self.budget.account();
        defer {
            self.budget.started_ns = null;
            active = self.previous;
            if (self.previous) |outer| {
                outer.started_ns = outer.clock() catch blk: {
                    outer.clock_failed = true;
                    break :blk null;
                };
            }
        }
        try self.budget.account();
    }
};

pub fn check() !void {
    const budget = active orelse return;
    try budget.checkState();
    budget.ticks -= 1;
    if (budget.ticks != 0) return;
    budget.ticks = sample_period;
    try budget.account();
}

pub fn expired() bool {
    return if (active) |budget| budget.expired else false;
}

pub fn fatalError() ?anyerror {
    const budget = active orelse return null;
    if (budget.clock_failed) return error.LuaCpuClockUnavailable;
    return if (budget.expired) error.LuaCpuLimit else null;
}

// Scribunto excludes lazy frame-argument expansion, but nested Lua invoked
// while expanding an argument must still charge the same parser budget.
pub const Pause = struct {
    budget: ?*Budget,

    pub fn unpause(self: Pause) void {
        const budget = self.budget orelse return;
        std.debug.assert(active == null);
        budget.started_ns = budget.clock() catch blk: {
            budget.clock_failed = true;
            break :blk null;
        };
        active = budget;
    }
};

pub fn pause() !Pause {
    const budget = active orelse return .{ .budget = null };
    // Reentry through an unpaused host callback still belongs to the outer
    // charged call; LuaSandbox does not permit that nested call to pause it.
    if (!budget.allow_pause) return .{ .budget = null };
    try budget.account();
    budget.started_ns = null;
    active = null;
    return .{ .budget = budget };
}

test "argument expansion pause excludes host work but nested Lua still consumes page quota" {
    const Fake = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 {
            return now;
        }
    };
    Fake.now = 0;
    var budget: Budget = .{ .limit_ns = 10, .clock = Fake.clock };
    var outer = try budget.enter();
    Fake.now = 2;
    const paused = try pause();
    Fake.now = 100;
    var nested = try budget.enter();
    Fake.now = 103;
    try nested.finish();
    Fake.now = 200;
    paused.unpause();
    Fake.now = 204;
    try outer.finish();
    try std.testing.expectEqual(@as(u64, 9), budget.used_ns);
}

test "script CPU budget accumulates calls excludes idle time and resets only for next page" {
    const Fake = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 {
            return now;
        }
    };
    Fake.now = 0;
    var budget: Budget = .{ .limit_ns = 10, .clock = Fake.clock };
    var first = try budget.enter();
    Fake.now = 4;
    try first.finish();
    Fake.now = 100;
    var second = try budget.enter();
    Fake.now = 105;
    try second.finish();
    try std.testing.expectEqual(@as(u64, 9), budget.used_ns);
    var third = try budget.enter();
    Fake.now = 106;
    try std.testing.expectError(error.LuaCpuLimit, third.finish());
    try std.testing.expectError(error.LuaCpuLimit, budget.enter());
    budget.reset();
    var fresh = try budget.enter();
    try fresh.finish();
    try std.testing.expectEqual(@as(u64, 0), budget.used_ns);
}

test "nested script calls share sticky quota and sampled guards" {
    const Fake = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 {
            return now;
        }
    };
    Fake.now = 0;
    var budget: Budget = .{ .limit_ns = 10, .clock = Fake.clock };
    var outer = try budget.enter();
    var inner = try budget.enter();
    Fake.now = 11;
    budget.ticks = 1;
    try std.testing.expectError(error.LuaCpuLimit, check());
    try std.testing.expect(expired());
    try std.testing.expectError(error.LuaCpuLimit, inner.finish());
    try std.testing.expectError(error.LuaCpuLimit, outer.finish());
    try std.testing.expect(active == null);
}

test "unpaused nested Lua cannot suspend the outer CPU timer" {
    const Fake = struct {
        var now: u64 = 0;
        fn clock() error{LuaCpuClockUnavailable}!u64 {
            return now;
        }
    };
    Fake.now = 0;
    var budget: Budget = .{ .limit_ns = 100, .clock = Fake.clock };
    var outer = try budget.enter();
    Fake.now = 2;
    var inner = try budget.enter();
    const refused = try pause();
    try std.testing.expect(refused.budget == null);
    Fake.now = 7;
    refused.unpause();
    try inner.finish();
    try std.testing.expect(budget.allow_pause);
    const allowed = try pause();
    Fake.now = 1000;
    allowed.unpause();
    Fake.now = 1003;
    try outer.finish();
    try std.testing.expectEqual(@as(u64, 10), budget.used_ns);
}

test "failed nested budget clock restoration leaves outer budget failed closed" {
    const Fake = struct {
        var calls: usize = 0;
        fn outer() error{LuaCpuClockUnavailable}!u64 {
            calls += 1;
            if (calls >= 3) return error.LuaCpuClockUnavailable;
            return calls;
        }
        fn broken() error{LuaCpuClockUnavailable}!u64 {
            return error.LuaCpuClockUnavailable;
        }
    };
    Fake.calls = 0;
    var outer_budget: Budget = .{ .clock = Fake.outer };
    var inner_budget: Budget = .{ .clock = Fake.broken };
    var outer = try outer_budget.enter();
    try std.testing.expectError(error.LuaCpuClockUnavailable, inner_budget.enter());
    try std.testing.expectError(error.LuaCpuClockUnavailable, check());
    try std.testing.expectError(error.LuaCpuClockUnavailable, outer.finish());
    try std.testing.expect(active == null);
}
