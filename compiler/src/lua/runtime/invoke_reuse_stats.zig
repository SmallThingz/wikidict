//! Bounded, exact-key diagnostic. Every invocation still executes.
const std = @import("std");
const rt = @import("zig_runtime");

const max_key_bytes = 8 * 1024;
const max_entries = 32768;
// Counts owned key/name slices; hash-map bucket allocations are bounded separately by max_entries.
const max_owned_bytes = 8 * 1024 * 1024;

const Key = struct {
    bytes: [max_key_bytes]u8 = undefined,
    len: usize = 0,

    fn append(self: *Key, text: []const u8) !void {
        if (text.len > self.bytes.len - self.len) return error.KeyTooLong;
        @memcpy(self.bytes[self.len .. self.len + text.len], text);
        self.len += text.len;
    }

    fn byte(self: *Key, value: u8) !void {
        try self.append(&.{value});
    }

    fn int(self: *Key, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.append(&bytes);
    }

    fn string(self: *Key, value: []const u8) !void {
        try self.int(value.len);
        try self.append(value);
    }

    fn table(self: *Key, value: *rt.Table) !void {
        if (value.shape != null or value.native_namespace != null or value.metatable != null or
            value.global_tail != null or value.choices.len != 0 or value.has_identity_key)
            return error.UnsupportedArgs;
        var count: u64 = 0;
        var it = value.iterator();
        while (it.next()) |entry| {
            if (count == 64) return error.UnsupportedArgs;
            switch (entry.key_ptr.*) {
                .string => |text| {
                    try self.byte(1);
                    try self.string(text);
                },
                .number => |number| {
                    try self.byte(2);
                    try self.int(@bitCast(number));
                },
                else => return error.UnsupportedArgs,
            }
            if (entry.value_ptr.* != .string) return error.UnsupportedArgs;
            try self.string(entry.value_ptr.string);
            count += 1;
        }
        try self.byte(0);
        try self.int(count);
    }
};

const Entry = struct {
    key: []u8,
    module_name: []u8,
    function_name: []u8,
    success_seen: bool = false,
    repeated_after_success: u64 = 0,
    repeated_failed: u64 = 0,
    host_observed_repeats: u64 = 0,
    sampled_cpu_ns: u64 = 0,
    sampled_host_observed_cpu_ns: u64 = 0,
    sampled_host_unobserved_cpu_ns: u64 = 0,
};

const FunctionKey = struct {
    module_id: ?u32,
    module_name: []const u8,
    function_name: []const u8,

    fn eql(a: FunctionKey, b: FunctionKey) bool {
        if (a.module_id != b.module_id) return false;
        if (a.module_id == null and !std.mem.eql(u8, a.module_name, b.module_name)) return false;
        return std.mem.eql(u8, a.function_name, b.function_name);
    }
};

const FunctionKeyContext = struct {
    pub fn hash(_: @This(), key: FunctionKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&.{@intFromBool(key.module_id != null)});
        if (key.module_id) |id| {
            h.update(std.mem.asBytes(&id));
        } else {
            const len: usize = key.module_name.len;
            h.update(std.mem.asBytes(&len));
            h.update(key.module_name);
        }
        const len: usize = key.function_name.len;
        h.update(std.mem.asBytes(&len));
        h.update(key.function_name);
        return h.final();
    }

    pub fn eql(_: @This(), a: FunctionKey, b: FunctionKey) bool {
        return FunctionKey.eql(a, b);
    }
};

const FunctionGroupMap = std.HashMapUnmanaged(FunctionKey, FunctionGroup, FunctionKeyContext, 80);
const FunctionGroup = struct {
    module_id: ?u32,
    module_name: []u8,
    function_name: []u8,
    invokes: u64 = 0,
    timed_invokes: u64 = 0,
    exclusive_timed_invokes: u64 = 0,
    inclusive_cpu_ns: u64 = 0,
    exclusive_cpu_ns: u64 = 0,

    fn key(self: *const FunctionGroup) FunctionKey {
        return .{ .module_id = self.module_id, .module_name = self.module_name, .function_name = self.function_name };
    }
};

// This frame stays on invokeFresh's stack, so nested calls need no heap allocation.
pub const FunctionProbe = struct {
    parent: ?*@This() = null,
    key: ?FunctionKey = null,
    start_ns: ?u64 = null,
    child_ns: u64 = 0,
    child_clock_failed: bool = false,
    depth: usize = 0,
};

pub const Ticket = struct {
    key: []const u8,
    repeated_after_success: bool,
    start_ns: ?u64,
};

pub const Stats = struct {
    a: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    function_groups: FunctionGroupMap = .empty,
    function_group_limit: usize = max_entries,
    active_function: ?*FunctionProbe = null,
    owned_bytes: usize = 0,
    function_owned_bytes: usize = 0,
    function_invokes: u64 = 0,
    function_drops: u64 = 0,
    function_timed_invokes: u64 = 0,
    function_exclusive_timed_invokes: u64 = 0,
    function_inclusive_cpu_ns: u64 = 0,
    function_exclusive_cpu_ns: u64 = 0,
    function_clock_drops: u64 = 0,
    function_exclusive_drops: u64 = 0,
    function_stack_errors: u64 = 0,
    function_max_depth: usize = 0,
    attempts: u64 = 0,
    unsupported_parent: u64 = 0,
    unsupported_args: u64 = 0,
    oversized: u64 = 0,
    capacity_drops: u64 = 0,
    exact_repeats: u64 = 0,
    repeated_after_success: u64 = 0,
    repeated_failed: u64 = 0,
    host_observed_repeats: u64 = 0,
    sampled_cpu_ns: u64 = 0,
    sampled_host_observed_cpu_ns: u64 = 0,
    sampled_host_unobserved_cpu_ns: u64 = 0,

    pub fn init(a: std.mem.Allocator) Stats {
        return .{ .a = a };
    }

    pub fn deinit(self: *Stats) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.a.free(entry.key);
            self.a.free(entry.module_name);
            self.a.free(entry.function_name);
        }
        self.entries.deinit(self.a);
        var groups = self.function_groups.valueIterator();
        while (groups.next()) |group| {
            self.a.free(group.module_name);
            self.a.free(group.function_name);
        }
        self.function_groups.deinit(self.a);
    }

    pub fn beginFunction(
        self: *Stats,
        probe: *FunctionProbe,
        module_id: ?u32,
        module_name: []const u8,
        function_name: []const u8,
    ) void {
        const start = rt.work_stats.processCpuNow();
        probe.* = .{
            .parent = self.active_function,
            .start_ns = start,
            .depth = if (self.active_function) |parent| parent.depth +| 1 else 1,
        };
        self.active_function = probe;
        self.function_max_depth = @max(self.function_max_depth, probe.depth);
        self.function_invokes +|= 1;
        if (start == null) self.function_clock_drops +|= 1;

        const lookup = FunctionKey{ .module_id = module_id, .module_name = module_name, .function_name = function_name };
        if (self.function_groups.getPtr(lookup)) |group| {
            group.invokes +|= 1;
            probe.key = group.key();
            return;
        }

        const needed = module_name.len +| function_name.len;
        if (self.function_groups.count() >= self.function_group_limit or
            needed > max_owned_bytes - self.owned_bytes - self.function_owned_bytes)
        {
            self.function_drops +|= 1;
            return;
        }
        const owned_module = self.a.dupe(u8, module_name) catch {
            self.function_drops +|= 1;
            return;
        };
        const owned_function = self.a.dupe(u8, function_name) catch {
            self.a.free(owned_module);
            self.function_drops +|= 1;
            return;
        };
        const stored = FunctionKey{ .module_id = module_id, .module_name = owned_module, .function_name = owned_function };
        self.function_groups.put(self.a, stored, .{
            .module_id = module_id,
            .module_name = owned_module,
            .function_name = owned_function,
            .invokes = 1,
        }) catch {
            self.a.free(owned_module);
            self.a.free(owned_function);
            self.function_drops +|= 1;
            return;
        };
        self.function_owned_bytes += needed;
        probe.key = stored;
    }

    pub fn finishFunction(self: *Stats, probe: *FunctionProbe) void {
        self.finishFunctionAt(probe, rt.work_stats.processCpuNow());
    }

    fn finishFunctionAt(self: *Stats, probe: *FunctionProbe, stop: ?u64) void {
        if (self.active_function != probe) {
            self.function_stack_errors +|= 1;
            self.active_function = probe.parent;
            if (probe.parent) |parent| parent.child_clock_failed = true;
            return;
        }
        self.active_function = probe.parent;
        const start = probe.start_ns orelse {
            if (probe.parent) |parent| parent.child_clock_failed = true;
            return;
        };
        const end = stop orelse {
            self.function_clock_drops +|= 1;
            if (probe.parent) |parent| parent.child_clock_failed = true;
            return;
        };
        if (end < start) {
            self.function_clock_drops +|= 1;
            if (probe.parent) |parent| parent.child_clock_failed = true;
            return;
        }
        const inclusive = end - start;
        self.function_timed_invokes +|= 1;
        self.function_inclusive_cpu_ns +|= inclusive;
        if (probe.parent) |parent| parent.child_ns +|= inclusive;
        const group = if (probe.key) |key| self.function_groups.getPtr(key) else null;
        if (group) |value| {
            value.timed_invokes +|= 1;
            value.inclusive_cpu_ns +|= inclusive;
        }
        if (probe.child_clock_failed or probe.child_ns > inclusive) {
            self.function_exclusive_drops +|= 1;
            return;
        }
        const exclusive = inclusive - probe.child_ns;
        self.function_exclusive_timed_invokes +|= 1;
        self.function_exclusive_cpu_ns +|= exclusive;
        if (group) |value| {
            value.exclusive_timed_invokes +|= 1;
            value.exclusive_cpu_ns +|= exclusive;
        }
    }

    pub fn observe(
        self: *Stats,
        module_id: ?u32,
        module_name: []const u8,
        function_name: []const u8,
        invoke_args: *rt.Table,
        existing_parent: ?rt.Value,
        parent_title: ?[]const u8,
        parent_args: ?*rt.Table,
        sampled: bool,
    ) ?Ticket {
        self.attempts +|= 1;
        if (existing_parent != null) {
            self.unsupported_parent +|= 1;
            return null;
        }
        var key: Key = .{};
        key.byte(1) catch unreachable;
        key.byte(@intFromBool(module_id != null)) catch unreachable;
        key.int(module_id orelse 0) catch unreachable;
        key.string(module_name) catch |err| return self.reject(err);
        key.string(function_name) catch |err| return self.reject(err);
        key.table(invoke_args) catch |err| return self.reject(err);
        key.byte(@intFromBool(parent_title != null)) catch unreachable;
        if (parent_title) |title| key.string(title) catch |err| return self.reject(err);
        key.byte(@intFromBool(parent_args != null)) catch unreachable;
        if (parent_args) |args| key.table(args) catch |err| return self.reject(err);

        const lookup = key.bytes[0..key.len];
        if (self.entries.getPtr(lookup)) |entry| {
            self.exact_repeats +|= 1;
            const reusable = entry.success_seen;
            if (reusable) {
                self.repeated_after_success +|= 1;
                entry.repeated_after_success +|= 1;
            }
            return .{ .key = entry.key, .repeated_after_success = reusable, .start_ns = if (reusable and sampled) rt.work_stats.processCpuNow() else null };
        }
        const needed = key.len +| module_name.len +| function_name.len;
        if (self.entries.count() >= max_entries or needed > max_owned_bytes - self.owned_bytes - self.function_owned_bytes) {
            self.capacity_drops +|= 1;
            return null;
        }
        const owned_key = self.a.dupe(u8, lookup) catch return self.drop();
        const owned_module = self.a.dupe(u8, module_name) catch {
            self.a.free(owned_key);
            return self.drop();
        };
        const owned_function = self.a.dupe(u8, function_name) catch {
            self.a.free(owned_key);
            self.a.free(owned_module);
            return self.drop();
        };
        self.entries.put(self.a, owned_key, .{
            .key = owned_key,
            .module_name = owned_module,
            .function_name = owned_function,
        }) catch {
            self.a.free(owned_key);
            self.a.free(owned_module);
            self.a.free(owned_function);
            return self.drop();
        };
        self.owned_bytes += needed;
        return .{ .key = owned_key, .repeated_after_success = false, .start_ns = null };
    }

    fn reject(self: *Stats, err: anyerror) ?Ticket {
        if (err == error.KeyTooLong) self.oversized +|= 1 else self.unsupported_args +|= 1;
        return null;
    }

    fn drop(self: *Stats) ?Ticket {
        self.capacity_drops +|= 1;
        return null;
    }

    pub fn finish(self: *Stats, ticket: ?Ticket, success: bool, host_observed: bool) void {
        const held = ticket orelse return;
        const entry = self.entries.getPtr(held.key) orelse return;
        if (success) entry.success_seen = true;
        if (!held.repeated_after_success) return;
        if (host_observed) {
            self.host_observed_repeats +|= 1;
            entry.host_observed_repeats +|= 1;
        }
        if (!success) {
            self.repeated_failed +|= 1;
            entry.repeated_failed +|= 1;
        }
        if (held.start_ns) |start| {
            const stop = rt.work_stats.processCpuNow() orelse return;
            const elapsed = stop -| start;
            self.sampled_cpu_ns +|= elapsed;
            entry.sampled_cpu_ns +|= elapsed;
            if (host_observed) {
                self.sampled_host_observed_cpu_ns +|= elapsed;
                entry.sampled_host_observed_cpu_ns +|= elapsed;
            } else {
                self.sampled_host_unobserved_cpu_ns +|= elapsed;
                entry.sampled_host_unobserved_cpu_ns +|= elapsed;
            }
        }
    }

    pub fn log(self: *Stats) void {
        rt.work_stats.logLine("invoke exact-key diagnostic: attempts={d} entries={d} bytes={d} repeats={d} repeats_after_success={d} repeat_failures={d} sampled_repeat_cpu_ns={d} host_observed_repeats={d} sampled_host_observed_cpu_ns={d} sampled_host_unobserved_cpu_ns={d} sampled_interval=32 unsupported_parent={d} unsupported_args={d} oversized={d} capacity_drops={d}\n", .{
            self.attempts,           self.entries.count(),  self.owned_bytes,           self.exact_repeats,                self.repeated_after_success,
            self.repeated_failed,    self.sampled_cpu_ns,   self.host_observed_repeats, self.sampled_host_observed_cpu_ns, self.sampled_host_unobserved_cpu_ns,
            self.unsupported_parent, self.unsupported_args, self.oversized,             self.capacity_drops,
        });
        // Aggregate by module/function only at shutdown, off the invoke hot path.
        const Group = struct {
            module_name: []const u8,
            function_name: []const u8,
            repeats: u64 = 0,
            host_observed_repeats: u64 = 0,
            cpu_ns: u64 = 0,
            host_observed_cpu_ns: u64 = 0,
            host_unobserved_cpu_ns: u64 = 0,
        };
        var groups: std.StringHashMapUnmanaged(Group) = .empty;
        defer {
            var keys = groups.keyIterator();
            while (keys.next()) |key| self.a.free(key.*);
            groups.deinit(self.a);
        }
        var values = self.entries.valueIterator();
        while (values.next()) |entry| {
            if (entry.repeated_after_success == 0) continue;
            var group_key: Key = .{};
            group_key.string(entry.module_name) catch continue;
            group_key.string(entry.function_name) catch continue;
            const pair = self.a.dupe(u8, group_key.bytes[0..group_key.len]) catch break;
            const result = groups.getOrPut(self.a, pair) catch {
                self.a.free(pair);
                break;
            };
            if (result.found_existing) self.a.free(pair) else result.value_ptr.* = .{
                .module_name = entry.module_name,
                .function_name = entry.function_name,
            };
            result.value_ptr.repeats +|= entry.repeated_after_success;
            result.value_ptr.host_observed_repeats +|= entry.host_observed_repeats;
            result.value_ptr.cpu_ns +|= entry.sampled_cpu_ns;
            result.value_ptr.host_observed_cpu_ns +|= entry.sampled_host_observed_cpu_ns;
            result.value_ptr.host_unobserved_cpu_ns +|= entry.sampled_host_unobserved_cpu_ns;
        }
        var prior: [16][]const u8 = undefined;
        var selected: usize = 0;
        while (selected < prior.len) : (selected += 1) {
            var best: ?[]const u8 = null;
            var it = groups.iterator();
            while (it.next()) |group| {
                var used = false;
                for (prior[0..selected]) |key| if (std.mem.eql(u8, key, group.key_ptr.*)) {
                    used = true;
                    break;
                };
                if (used) continue;
                if (best) |key| {
                    const prev = groups.get(key).?;
                    if (group.value_ptr.cpu_ns < prev.cpu_ns or
                        (group.value_ptr.cpu_ns == prev.cpu_ns and group.value_ptr.repeats <= prev.repeats)) continue;
                }
                best = group.key_ptr.*;
            }
            const key = best orelse break;
            prior[selected] = key;
            const group = groups.get(key).?;
            rt.work_stats.logLine("invoke exact-key top: rank={d} repeats={d} sampled_cpu_ns={d} host_observed_repeats={d} sampled_host_observed_cpu_ns={d} sampled_host_unobserved_cpu_ns={d} module={s} function={s}\n", .{
                selected + 1,                                           group.repeats,                                              group.cpu_ns, group.host_observed_repeats, group.host_observed_cpu_ns, group.host_unobserved_cpu_ns,
                group.module_name[0..@min(group.module_name.len, 256)], group.function_name[0..@min(group.function_name.len, 256)],
            });
        }
        self.logFunctionGroups();
    }

    fn logFunctionGroups(self: *Stats) void {
        rt.work_stats.logLine("invoke function diagnostic: invokes={d} groups={d} owned_bytes={d} group_drops={d} timed_invokes={d} exclusive_timed_invokes={d} inclusive_cpu_ns={d} exclusive_cpu_ns={d} clock_drops={d} exclusive_drops={d} stack_errors={d} max_depth={d} timing=all_profiled_invokes\n", .{
            self.function_invokes,       self.function_groups.count(),          self.function_owned_bytes,      self.function_drops,
            self.function_timed_invokes, self.function_exclusive_timed_invokes, self.function_inclusive_cpu_ns, self.function_exclusive_cpu_ns,
            self.function_clock_drops,   self.function_exclusive_drops,         self.function_stack_errors,     self.function_max_depth,
        });
        var prior: [16]FunctionKey = undefined;
        var selected: usize = 0;
        while (selected < prior.len) : (selected += 1) {
            var best: ?FunctionKey = null;
            var it = self.function_groups.iterator();
            while (it.next()) |group| {
                var used = false;
                for (prior[0..selected]) |key| if (FunctionKey.eql(key, group.key_ptr.*)) {
                    used = true;
                    break;
                };
                if (used) continue;
                if (best) |key| {
                    const prev = self.function_groups.get(key).?;
                    if (group.value_ptr.exclusive_cpu_ns < prev.exclusive_cpu_ns or
                        (group.value_ptr.exclusive_cpu_ns == prev.exclusive_cpu_ns and group.value_ptr.invokes <= prev.invokes)) continue;
                }
                best = group.key_ptr.*;
            }
            const key = best orelse break;
            prior[selected] = key;
            const group = self.function_groups.get(key).?;
            rt.work_stats.logLine("invoke function top: rank={d} invokes={d} timed_invokes={d} inclusive_cpu_ns={d} exclusive_timed_invokes={d} exclusive_cpu_ns={d} module={s} function={s}\n", .{
                selected + 1,                  group.invokes,          group.timed_invokes,                                    group.inclusive_cpu_ns,
                group.exclusive_timed_invokes, group.exclusive_cpu_ns, group.module_name[0..@min(group.module_name.len, 256)], group.function_name[0..@min(group.function_name.len, 256)],
            });
        }
    }
};

test "exact invocation diagnostic counts only identical successful prior keys" {
    const a = std.testing.allocator;
    var args: rt.Table = .{};
    defer args.deinit(a);
    try args.rawSet(a, .{ .number = 1 }, .{ .string = "en" });
    var parent: rt.Table = .{};
    defer parent.deinit(a);
    try parent.rawSet(a, .{ .string = "label" }, .{ .string = "archaic" });
    var stats = Stats.init(a);
    defer stats.deinit();

    const first = stats.observe(3, "Module:labels", "show", &args, null, "Template:lb", &parent, false);
    try std.testing.expect(first != null and !first.?.repeated_after_success);
    stats.finish(first, true, false);
    const repeat = stats.observe(3, "Module:labels", "show", &args, null, "Template:lb", &parent, false);
    try std.testing.expect(repeat != null and repeat.?.repeated_after_success);
    stats.finish(repeat, true, true);
    try std.testing.expectEqual(@as(u64, 1), stats.exact_repeats);
    try std.testing.expectEqual(@as(u64, 1), stats.repeated_after_success);
    try std.testing.expectEqual(@as(u64, 1), stats.host_observed_repeats);

    const other_parent = stats.observe(3, "Module:labels", "show", &args, null, "Template:qualifier", &parent, false);
    try std.testing.expect(other_parent != null and !other_parent.?.repeated_after_success);
    stats.finish(other_parent, false, true);
    const failed_before = stats.observe(3, "Module:labels", "show", &args, null, "Template:qualifier", &parent, false);
    try std.testing.expect(failed_before != null and !failed_before.?.repeated_after_success);
    stats.finish(failed_before, true, false);
    try std.testing.expect(stats.observe(3, "Module:labels", "show", &args, .nil, null, null, false) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.unsupported_parent);
}

test "function diagnostic counts all invokes and subtracts nested CPU" {
    const a = std.testing.allocator;
    var stats = Stats.init(a);
    defer stats.deinit();
    var parent: FunctionProbe = .{};
    stats.beginFunction(&parent, 7, "Module:seven", "show");
    parent.start_ns = 100;
    var child: FunctionProbe = .{};
    stats.beginFunction(&child, 8, "Module:eight", "show");
    child.start_ns = 110;
    stats.finishFunctionAt(&child, 130);
    stats.finishFunctionAt(&parent, 150);
    try std.testing.expectEqual(@as(u64, 2), stats.function_invokes);
    try std.testing.expectEqual(@as(u64, 2), stats.function_timed_invokes);
    try std.testing.expectEqual(@as(u64, 2), stats.function_exclusive_timed_invokes);
    try std.testing.expectEqual(@as(u64, 70), stats.function_inclusive_cpu_ns);
    try std.testing.expectEqual(@as(u64, 50), stats.function_exclusive_cpu_ns);
    try std.testing.expectEqual(@as(usize, 2), stats.function_max_depth);
    try std.testing.expectEqual(@as(usize, 2), stats.function_groups.count());
    try std.testing.expectEqual(@as(u64, 30), stats.function_groups.get(parent.key.?).?.exclusive_cpu_ns);
    try std.testing.expectEqual(@as(u64, 20), stats.function_groups.get(child.key.?).?.exclusive_cpu_ns);
}

test "function groups respect entry and shared owned-byte limits" {
    const a = std.testing.allocator;
    var entry_limited = Stats.init(a);
    defer entry_limited.deinit();
    entry_limited.function_group_limit = 1;
    var first: FunctionProbe = .{};
    entry_limited.beginFunction(&first, 1, "Module:one", "show");
    entry_limited.finishFunction(&first);
    var second: FunctionProbe = .{};
    entry_limited.beginFunction(&second, 2, "Module:two", "show");
    entry_limited.finishFunction(&second);
    try std.testing.expectEqual(@as(u64, 1), entry_limited.function_drops);
    try std.testing.expectEqual(@as(usize, 1), entry_limited.function_groups.count());

    var name_budget = Stats.init(a);
    defer name_budget.deinit();
    name_budget.owned_bytes = max_owned_bytes;
    var no_group: FunctionProbe = .{};
    name_budget.beginFunction(&no_group, 1, "Module:one", "show");
    name_budget.finishFunction(&no_group);
    try std.testing.expectEqual(@as(u64, 1), name_budget.function_drops);

    var exact_budget = Stats.init(a);
    defer exact_budget.deinit();
    exact_budget.function_owned_bytes = max_owned_bytes;
    var args: rt.Table = .{};
    defer args.deinit(a);
    try std.testing.expect(exact_budget.observe(1, "Module:one", "show", &args, null, null, null, false) == null);
    try std.testing.expectEqual(@as(u64, 1), exact_budget.capacity_drops);
}

test "function diagnostic drops exclusive timing when child clock fails" {
    const a = std.testing.allocator;
    var stats = Stats.init(a);
    defer stats.deinit();
    var parent: FunctionProbe = .{};
    stats.beginFunction(&parent, 7, "Module:seven", "show");
    parent.start_ns = 100;
    var child: FunctionProbe = .{};
    stats.beginFunction(&child, 8, "Module:eight", "show");
    child.start_ns = null;
    stats.finishFunctionAt(&child, 130);
    stats.finishFunctionAt(&parent, 150);
    try std.testing.expectEqual(@as(u64, 1), stats.function_timed_invokes);
    try std.testing.expectEqual(@as(u64, 0), stats.function_exclusive_timed_invokes);
    try std.testing.expectEqual(@as(u64, 1), stats.function_exclusive_drops);
}

test "exact invocation diagnostic rejects oversized keys and nonstring arguments" {
    const a = std.testing.allocator;
    var args: rt.Table = .{};
    defer args.deinit(a);
    var stats = Stats.init(a);
    defer stats.deinit();
    const big = try a.alloc(u8, max_key_bytes);
    defer a.free(big);
    @memset(big, 'x');
    try args.rawSet(a, .{ .number = 1 }, .{ .string = big });
    try std.testing.expect(stats.observe(null, "Module:example", "main", &args, null, null, null, false) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.oversized);
    try args.rawSet(a, .{ .number = 1 }, .{ .number = 1 });
    try std.testing.expect(stats.observe(null, "Module:example", "main", &args, null, null, null, false) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.unsupported_args);
}
