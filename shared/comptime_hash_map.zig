const std = @import("std");

pub fn Entry(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
    };
}

pub const StringContext = std.hash_map.StringContext;

pub fn AutoContext(comptime K: type) type {
    return std.hash_map.AutoContext(K);
}

pub fn ComptimeHashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime ctx: Context,
    comptime entries: []const Entry(K, V),
) type {
    return struct {
        const Self = @This();
        pub const KV = Entry(K, V);
        pub const context = ctx;
        pub const entry_count = entries.len;
        pub const slot_count = computeSlotCount(entry_count);
        pub const Slot = struct {
            used: bool = false,
            key: K = undefined,
            value: V = undefined,
        };
        pub const slots = buildSlots();

        pub fn init() Self {
            return .{};
        }

        pub fn get(_: Self, key: K) ?V {
            var index = startIndex(key);
            while (true) {
                const slot = slots[index];
                if (!slot.used) return null;
                if (context.eql(slot.key, key)) return slot.value;
                index = (index + 1) & (slot_count - 1);
            }
        }

        pub fn contains(self: Self, key: K) bool {
            return self.get(key) != null;
        }

        fn computeSlotCount(len: usize) usize {
            if (len == 0) return 1;
            const required = (len * 100 + 79) / 80;
            return std.math.ceilPowerOfTwo(usize, @max(required + 1, 2)) catch unreachable;
        }

        fn startIndex(key: K) usize {
            return @intCast(context.hash(key) & @as(u64, slot_count - 1));
        }

        fn buildSlots() [slot_count]Slot {
            @setEvalBranchQuota(2_000_000);
            var built: [slot_count]Slot = [_]Slot{.{}} ** slot_count;
            for (entries) |entry| {
                var index = startIndex(entry.key);
                while (built[index].used) : (index = (index + 1) & (slot_count - 1)) {
                    if (context.eql(built[index].key, entry.key)) {
                        @compileError("duplicate key in ComptimeHashMap");
                    }
                }
                built[index] = .{
                    .used = true,
                    .key = entry.key,
                    .value = entry.value,
                };
            }
            return built;
        }
    };
}

test "ComptimeHashMap supports string keys" {
    const KV = Entry([]const u8, u8);
    const Map = ComptimeHashMap([]const u8, u8, StringContext, .{}, &[_]KV{
        .{ .key = "alpha", .value = 1 },
        .{ .key = "beta", .value = 2 },
        .{ .key = "gamma", .value = 3 },
    });
    const map = Map.init();

    try std.testing.expectEqual(@as(?u8, 2), map.get("beta"));
    try std.testing.expectEqual(@as(?u8, null), map.get("delta"));
}

test "ComptimeHashMap supports auto-hashed integer keys" {
    const KV = Entry(u32, []const u8);
    const Map = ComptimeHashMap(u32, []const u8, AutoContext(u32), .{}, &[_]KV{
        .{ .key = 7, .value = "seven" },
        .{ .key = 42, .value = "forty-two" },
        .{ .key = 99, .value = "ninety-nine" },
    });
    const map = Map.init();

    try std.testing.expectEqualStrings("forty-two", map.get(42).?);
    try std.testing.expect(map.contains(99));
    try std.testing.expect(!map.contains(100));
}
