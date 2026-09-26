//! Bounded, exact-key diagnostic. Every invocation still executes.
const std = @import("std");
const rt = @import("zig_runtime");

const max_key_bytes = 8 * 1024;
const max_entries = 4096;
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
    sampled_cpu_ns: u64 = 0,
};

pub const Ticket = struct {
    key: []const u8,
    repeated_after_success: bool,
    start_ns: ?u64,
};

pub const Stats = struct {
    a: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    owned_bytes: usize = 0,
    attempts: u64 = 0,
    unsupported_parent: u64 = 0,
    unsupported_args: u64 = 0,
    oversized: u64 = 0,
    capacity_drops: u64 = 0,
    exact_repeats: u64 = 0,
    repeated_after_success: u64 = 0,
    repeated_failed: u64 = 0,
    sampled_cpu_ns: u64 = 0,

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
        if (self.entries.count() >= max_entries or needed > max_owned_bytes - self.owned_bytes) {
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

    pub fn finish(self: *Stats, ticket: ?Ticket, success: bool) void {
        const held = ticket orelse return;
        const entry = self.entries.getPtr(held.key) orelse return;
        if (success) entry.success_seen = true;
        if (!held.repeated_after_success) return;
        if (!success) {
            self.repeated_failed +|= 1;
            entry.repeated_failed +|= 1;
        }
        if (held.start_ns) |start| {
            const stop = rt.work_stats.processCpuNow() orelse return;
            const elapsed = stop -| start;
            self.sampled_cpu_ns +|= elapsed;
            entry.sampled_cpu_ns +|= elapsed;
        }
    }

    pub fn log(self: *Stats) void {
        rt.work_stats.logLine("invoke exact-key diagnostic: attempts={d} entries={d} bytes={d} repeats={d} repeats_after_success={d} repeat_failures={d} sampled_repeat_cpu_ns={d} sampled_interval=32 unsupported_parent={d} unsupported_args={d} oversized={d} capacity_drops={d}\n", .{
            self.attempts,        self.entries.count(), self.owned_bytes,        self.exact_repeats,    self.repeated_after_success,
            self.repeated_failed, self.sampled_cpu_ns,  self.unsupported_parent, self.unsupported_args, self.oversized,
            self.capacity_drops,
        });
        // Aggregate by module/function only at shutdown, off the invoke hot path.
        const Group = struct {
            module_name: []const u8,
            function_name: []const u8,
            repeats: u64 = 0,
            cpu_ns: u64 = 0,
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
            result.value_ptr.cpu_ns +|= entry.sampled_cpu_ns;
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
            rt.work_stats.logLine("invoke exact-key top: rank={d} repeats={d} sampled_cpu_ns={d} module={s} function={s}\n", .{
                selected + 1,                                           group.repeats,                                              group.cpu_ns,
                group.module_name[0..@min(group.module_name.len, 256)], group.function_name[0..@min(group.function_name.len, 256)],
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
    stats.finish(first, true);
    const repeat = stats.observe(3, "Module:labels", "show", &args, null, "Template:lb", &parent, false);
    try std.testing.expect(repeat != null and repeat.?.repeated_after_success);
    stats.finish(repeat, true);
    try std.testing.expectEqual(@as(u64, 1), stats.exact_repeats);
    try std.testing.expectEqual(@as(u64, 1), stats.repeated_after_success);

    const other_parent = stats.observe(3, "Module:labels", "show", &args, null, "Template:qualifier", &parent, false);
    try std.testing.expect(other_parent != null and !other_parent.?.repeated_after_success);
    stats.finish(other_parent, false);
    const failed_before = stats.observe(3, "Module:labels", "show", &args, null, "Template:qualifier", &parent, false);
    try std.testing.expect(failed_before != null and !failed_before.?.repeated_after_success);
    stats.finish(failed_before, true);
    try std.testing.expect(stats.observe(3, "Module:labels", "show", &args, .nil, null, null, false) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.unsupported_parent);
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
