const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const language = @import("language.zig");
const Value = rt.Value;

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const weekday_names = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn integer(value: Value) !i64 {
    const n: f64 = switch (value) {
        .number => |v| v,
        .string => |v| std.fmt.parseFloat(f64, v) catch return error.IntegerExpected,
        else => return error.IntegerExpected,
    };
    if (!std.math.isFinite(n) or n != @trunc(n) or n < -9.22e18 or n > 9.22e18)
        return error.IntegerExpected;
    return @intFromFloat(n);
}

fn tableInteger(table: *rt.Table, key: []const u8, default: ?i64) !i64 {
    const value = table.rawGet(.{ .string = key }) orelse return default orelse error.MissingDateField;
    if (value == .nil) return default orelse error.MissingDateField;
    return integer(value);
}

fn addExact(a: i64, b: i64) !i64 {
    const r = @addWithOverflow(a, b);
    return if (r[1] == 0) r[0] else error.TimeOutOfRange;
}
fn mulExact(a: i64, b: i64) !i64 {
    const r = @mulWithOverflow(a, b);
    return if (r[1] == 0) r[0] else error.TimeOutOfRange;
}

fn normalizedTimestamp(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) !i64 {
    const year_months = try mulExact(year, 12);
    const total_months = try addExact(year_months, try addExact(month, -1));
    const normalized_year = @divFloor(total_months, 12);
    const normalized_month: u8 = @intCast(@mod(total_months, 12) + 1);
    var days = language.daysFromCivil(normalized_year, normalized_month, 1);
    days = try addExact(days, try addExact(day, -1));
    var timestamp = try mulExact(days, std.time.s_per_day);
    timestamp = try addExact(timestamp, try mulExact(hour, std.time.s_per_hour));
    timestamp = try addExact(timestamp, try mulExact(minute, std.time.s_per_min));
    return addExact(timestamp, second);
}

fn yearDay(civil: language.Civil) i64 {
    return language.daysFromCivil(civil.year, civil.month, civil.day) -
        language.daysFromCivil(civil.year, 1, 1) + 1;
}
fn weekSunday(civil: language.Civil, timestamp: i64) i64 {
    const yday0 = yearDay(civil) - 1;
    const wday = language.weekdaySunday0(timestamp);
    return @divFloor(yday0 + 7 - wday, 7);
}
fn weekMonday(civil: language.Civil, timestamp: i64) i64 {
    const yday0 = yearDay(civil) - 1;
    const sunday0 = language.weekdaySunday0(timestamp);
    const monday0: i64 = @mod(@as(i64, sunday0) + 6, 7);
    return @divFloor(yday0 + 7 - monday0, 7);
}

fn setDateFields(runtime: *rt.Context, table: *rt.Table, timestamp: i64) !void {
    const civil = language.civilFromUnix(timestamp);
    const wday = language.weekdaySunday0(timestamp);
    inline for (.{
        .{ "year", civil.year },
        .{ "month", @as(i64, civil.month) },
        .{ "day", @as(i64, civil.day) },
        .{ "hour", @as(i64, civil.hour) },
        .{ "min", @as(i64, civil.minute) },
        .{ "sec", @as(i64, civil.second) },
        .{ "yday", yearDay(civil) },
        .{ "wday", @as(i64, wday) + 1 },
    }) |field| try table.rawSet(runtime.allocator, .{ .string = field[0] }, .{ .number = @floatFromInt(field[1]) });
    try table.rawSet(runtime.allocator, .{ .string = "isdst" }, .{ .boolean = false });
}

fn pinnedNow(runtime: *rt.Context) !i64 {
    const host = host_api.get(runtime) orelse return error.MissingCurrentTime;
    return host.now_unix orelse error.MissingCurrentTime;
}

fn appendNumber(out: *std.ArrayList(u8), a: std.mem.Allocator, value: i64, width: usize, pad: u8) !void {
    const raw = try std.fmt.allocPrint(a, "{d}", .{value});
    defer a.free(raw);
    if (raw.len < width) try out.appendNTimes(a, pad, width - raw.len);
    try out.appendSlice(a, raw);
}

fn appendFormat(out: *std.ArrayList(u8), a: std.mem.Allocator, format: []const u8, timestamp: i64) !void {
    const civil = language.civilFromUnix(timestamp);
    const wday: usize = language.weekdaySunday0(timestamp);
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] != '%') {
            try out.append(a, format[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= format.len) return error.InvalidDateFormat;
        const spec = format[i];
        i += 1;
        switch (spec) {
            '%' => try out.append(a, '%'),
            'Y' => try appendNumber(out, a, civil.year, 4, '0'),
            'y' => try appendNumber(out, a, @mod(civil.year, 100), 2, '0'),
            'm' => try appendNumber(out, a, civil.month, 2, '0'),
            'd' => try appendNumber(out, a, civil.day, 2, '0'),
            'e' => try appendNumber(out, a, civil.day, 2, ' '),
            'H' => try appendNumber(out, a, civil.hour, 2, '0'),
            'M' => try appendNumber(out, a, civil.minute, 2, '0'),
            'S' => try appendNumber(out, a, civil.second, 2, '0'),
            'R' => {
                try appendNumber(out, a, civil.hour, 2, '0');
                try out.append(a, ':');
                try appendNumber(out, a, civil.minute, 2, '0');
            },
            'T' => {
                try appendNumber(out, a, civil.hour, 2, '0');
                try out.append(a, ':');
                try appendNumber(out, a, civil.minute, 2, '0');
                try out.append(a, ':');
                try appendNumber(out, a, civil.second, 2, '0');
            },
            'F' => {
                try appendNumber(out, a, civil.year, 4, '0');
                try out.append(a, '-');
                try appendNumber(out, a, civil.month, 2, '0');
                try out.append(a, '-');
                try appendNumber(out, a, civil.day, 2, '0');
            },
            'D', 'x' => {
                try appendNumber(out, a, civil.month, 2, '0');
                try out.append(a, '/');
                try appendNumber(out, a, civil.day, 2, '0');
                try out.append(a, '/');
                try appendNumber(out, a, @mod(civil.year, 100), 2, '0');
            },
            'I' => {
                const hour = @mod(@as(i64, civil.hour) + 11, 12) + 1;
                try appendNumber(out, a, hour, 2, '0');
            },
            'p' => try out.appendSlice(a, if (civil.hour < 12) "AM" else "PM"),
            'a' => try out.appendSlice(a, weekday_names[wday][0..3]),
            'A' => try out.appendSlice(a, weekday_names[wday]),
            'b', 'h' => try out.appendSlice(a, month_names[civil.month - 1][0..3]),
            'B' => try out.appendSlice(a, month_names[civil.month - 1]),
            'w' => try appendNumber(out, a, @intCast(wday), 1, '0'),
            'u' => try appendNumber(out, a, if (wday == 0) 7 else @intCast(wday), 1, '0'),
            'j' => try appendNumber(out, a, yearDay(civil), 3, '0'),
            'U' => try appendNumber(out, a, weekSunday(civil, timestamp), 2, '0'),
            'W' => try appendNumber(out, a, weekMonday(civil, timestamp), 2, '0'),
            'c' => {
                try out.appendSlice(a, weekday_names[wday][0..3]);
                try out.append(a, ' ');
                try out.appendSlice(a, month_names[civil.month - 1][0..3]);
                try out.append(a, ' ');
                try appendNumber(out, a, civil.day, 2, ' ');
                try out.append(a, ' ');
                try appendNumber(out, a, civil.hour, 2, '0');
                try out.append(a, ':');
                try appendNumber(out, a, civil.minute, 2, '0');
                try out.append(a, ':');
                try appendNumber(out, a, civil.second, 2, '0');
                try out.append(a, ' ');
                try appendNumber(out, a, civil.year, 4, '0');
            },
            'X' => try appendFormat(out, a, "%T", timestamp),
            else => return error.InvalidDateFormat,
        }
    }
}

fn dateCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    var format: []const u8 = "%c";
    if (args.len > 0 and args[0] != .nil) {
        if (args[0] != .string) return error.StringExpected;
        format = args[0].string;
    }
    const timestamp = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else try pinnedNow(runtime);
    if (format.len != 0 and format[0] == '!') format = format[1..];
    // Bundle execution is deliberately timezone-stable. Wikimedia's production
    // Scribunto environment uses UTC for these corpus-observed calls.
    if (std.mem.eql(u8, format, "*t")) {
        const table = try runtime.newTable();
        try setDateFields(runtime, table, timestamp);
        return one(.{ .table = table });
    }
    var out: std.ArrayList(u8) = .empty;
    try appendFormat(&out, runtime.allocator, format, timestamp);
    return one(.{ .string = try out.toOwnedSlice(runtime.allocator) });
}

fn timeCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] == .nil) return one(.{ .number = @floatFromInt(try pinnedNow(runtime)) });
    if (args[0] != .table) return error.TableExpected;
    const table = args[0].table;
    const timestamp = try normalizedTimestamp(
        try tableInteger(table, "year", null),
        try tableInteger(table, "month", null),
        try tableInteger(table, "day", null),
        try tableInteger(table, "hour", 12),
        try tableInteger(table, "min", 0),
        try tableInteger(table, "sec", 0),
    );
    try setDateFields(runtime, table, timestamp);
    return one(.{ .number = @floatFromInt(timestamp) });
}

fn difftimeCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    if (args.len < 2) return error.NumberExpected;
    const lhs: f64 = switch (args[0]) {
        .number => |v| v,
        else => return error.NumberExpected,
    };
    const rhs: f64 = switch (args[1]) {
        .number => |v| v,
        else => return error.NumberExpected,
    };
    return one(.{ .number = lhs - rhs });
}

fn clockCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.NotImplemented;
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.PROCESS_CPUTIME_ID, &ts)) != .SUCCESS)
        return error.NotImplemented;
    const value = @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
    return one(.{ .number = value });
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, comptime call: anytype) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(null, call));
}

pub fn install(runtime: *rt.Context) !void {
    const global = runtime.global_table orelse return;
    const table = try runtime.newTable();
    try setNative(runtime, table, "date", dateCall);
    try setNative(runtime, table, "time", timeCall);
    try setNative(runtime, table, "difftime", difftimeCall);
    try setNative(runtime, table, "clock", clockCall);
    try global.rawSet(runtime.allocator, .{ .string = "os" }, .{ .table = table });
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "Scribunto os date time difftime and clock use pinned UTC semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 24);
    defer runtime.deinit();
    try rt.bindGlobalTable(&runtime, null, 0);
    const pinned = try normalizedTimestamp(2024, 3, 4, 5, 6, 7);
    var host = host_api.Host{ .now_unix = pinned };
    host_api.set(&runtime, &host);
    try install(&runtime);
    const os = runtime.global_table.?.rawGet(.{ .string = "os" }).?;

    const formatted = try callField(&runtime, os, "date", &.{.{ .string = "!%Y-%m-%d %H:%M:%S %A %b %R %U %w" }});
    defer rt.freeResults(formatted);
    try std.testing.expectEqualStrings("2024-03-04 05:06:07 Monday Mar 05:06 09 1", formatted[0].string);
    const fields = try callField(&runtime, os, "date", &.{.{ .string = "*t" }});
    defer rt.freeResults(fields);
    try std.testing.expectEqual(@as(f64, 2024), fields[0].table.rawGet(.{ .string = "year" }).?.number);
    try std.testing.expectEqual(@as(f64, 64), fields[0].table.rawGet(.{ .string = "yday" }).?.number);
    try std.testing.expectEqual(@as(f64, 2), fields[0].table.rawGet(.{ .string = "wday" }).?.number);

    const input = try runtime.newTable();
    try input.rawSet(runtime.allocator, .{ .string = "year" }, .{ .number = 2024 });
    try input.rawSet(runtime.allocator, .{ .string = "month" }, .{ .number = 13 });
    try input.rawSet(runtime.allocator, .{ .string = "day" }, .{ .number = 1 });
    const timestamp = try callField(&runtime, os, "time", &.{.{ .table = input }});
    defer rt.freeResults(timestamp);
    const normalized = try callField(&runtime, os, "date", &.{ .{ .string = "!%Y-%m-%d %H:%M:%S" }, timestamp[0] });
    defer rt.freeResults(normalized);
    try std.testing.expectEqualStrings("2025-01-01 12:00:00", normalized[0].string);
    try std.testing.expectEqual(@as(f64, 2025), input.rawGet(.{ .string = "year" }).?.number);
    try std.testing.expectEqual(@as(f64, 1), input.rawGet(.{ .string = "month" }).?.number);
    try std.testing.expectEqual(@as(f64, 12), input.rawGet(.{ .string = "hour" }).?.number);

    const diff = try callField(&runtime, os, "difftime", &.{ .{ .number = 10 }, .{ .number = 4 } });
    defer rt.freeResults(diff);
    try std.testing.expectEqual(@as(f64, 6), diff[0].number);
    const clock = try callField(&runtime, os, "clock", &.{});
    defer rt.freeResults(clock);
    try std.testing.expect(clock[0].number >= 0);
}
