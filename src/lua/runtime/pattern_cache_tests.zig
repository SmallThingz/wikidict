const std = @import("std");
const pattern = @import("ustring_pattern.zig");
var calls: [4096]i32 = undefined;
var count: usize = 0;
fn category(cp: i32) callconv(.c) c_int {
    if (count < calls.len) calls[count] = cp;
    count += 1;
    return if (cp >= 'a' and cp <= 'z') 2 else 0;
}

test "warm cached Unicode percent classes and malformed tails preserve callbacks and errors" {
    var cache = pattern.PatternCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const literal = "[" ++ ("α" ** 70) ++ "βq]";
    const percent = "[" ++ ("α" ** 70) ++ "%aq]";
    const keys = [_][]const u8{ literal ++ "+", percent ++ "+", literal ++ "[", literal ++ "*(", literal ++ "*%1" };
    for (keys) |key| {
        var warm = try pattern.Search.initWithCache(std.testing.allocator, "qqqqqqqq", key, &cache);
        defer warm.deinit();
        _ = warm.find(category, 1, true) catch null;
        try std.testing.expect(cache.lookup(key) != null);
        for ([_][]const u8{ "", "α", "abcdefgh", "qqqqqqqq", "ααβqqqqq", "xxxxxxxx" }) |source| {
            var raw = try pattern.Search.init(std.testing.allocator, source, key);
            defer raw.deinit();
            raw.preparation_attempted = true;
            var cached = try pattern.Search.initWithCache(std.testing.allocator, source, key, &cache);
            defer cached.deinit();
            try std.testing.expect(cached.borrowed_pattern);
            count = 0;
            const expected = raw.find(category, 1, true);
            const expected_count = count;
            try std.testing.expect(expected_count <= calls.len);
            const expected_calls = calls;
            count = 0;
            const actual = cached.find(category, 1, true);
            try std.testing.expectEqual(expected_count, count);
            try std.testing.expectEqualSlices(i32, expected_calls[0..count], calls[0..count]);
            if (expected) |want| {
                const got = try actual;
                try std.testing.expectEqual(want == null, got == null);
                if (want) |w| {
                    try std.testing.expectEqual(w.start, got.?.start);
                    try std.testing.expectEqual(w.end, got.?.end);
                    try std.testing.expectEqual(w.capture_count, got.?.capture_count);
                }
            } else |err| try std.testing.expectError(err, actual);
        }
    }
}
