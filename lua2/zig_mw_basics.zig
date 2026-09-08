const std = @import("std");
const rt = @import("zig_runtime");
const namespace_lib = @import("zig_namespaces.zig");
const Value = rt.Value;

fn one(value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn noOpCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return &.{};
}

fn falseCall(_: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    return one(.{ .boolean = false });
}

fn dumpObjectCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const text: []const u8 = if (args.len == 0) "nil" else switch (args[0]) {
        .nil => "nil",
        .boolean => |value| if (value) "true" else "false",
        .number => |value| try rt.numberToString(runtime.allocator, value),
        .string => |value| value,
        .table => "table",
        .function, .native => "function",
    };
    return one(.{ .string = text });
}

fn setNative(runtime: *rt.Context, table: *rt.Table, name: []const u8, call: rt.NativeFn) !void {
    try table.rawSet(runtime.allocator, .{ .string = name }, try runtime.newNative(null, call));
}

pub fn install(runtime: *rt.Context, mw: *rt.Table) !void {
    try setNative(runtime, mw, "dumpObject", dumpObjectCall);
    try setNative(runtime, mw, "log", noOpCall);
    try setNative(runtime, mw, "logObject", noOpCall);
    try setNative(runtime, mw, "addWarning", noOpCall);
    try setNative(runtime, mw, "isSubsting", falseCall);

    const site = try runtime.newTable();
    const namespaces = try namespace_lib.makeTable(runtime);
    try site.rawSet(runtime.allocator, .{ .string = "namespaces" }, .{ .table = namespaces });
    try mw.rawSet(runtime.allocator, .{ .string = "site" }, .{ .table = site });
}

fn callField(runtime: *rt.Context, object: Value, name: []const u8, args: []const Value) ![]const Value {
    const callable = try runtime.getIndex(object, .{ .string = name });
    return runtime.callValue(callable, args);
}

test "AOT mw basics expose logging, dumpObject and site namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const mw = try runtime.newNativeNamespace(.mw);
    try install(&runtime, mw);

    const dumped = try callField(&runtime, .{ .table = mw }, "dumpObject", &.{.{ .number = 7 }});
    defer rt.freeResults(dumped);
    try std.testing.expectEqualStrings("7", dumped[0].string);
    const logged = try callField(&runtime, .{ .table = mw }, "log", &.{.{ .string = "ignored" }});
    defer rt.freeResults(logged);
    try std.testing.expectEqual(@as(usize, 0), logged.len);
    const substing = try callField(&runtime, .{ .table = mw }, "isSubsting", &.{});
    defer rt.freeResults(substing);
    try std.testing.expect(!substing[0].boolean);

    const site = mw.rawGet(.{ .string = "site" }).?.table;
    const namespaces = site.rawGet(.{ .string = "namespaces" }).?.table;
    const template = namespaces.rawGet(.{ .number = 10 }).?.table;
    try std.testing.expectEqualStrings("Template", template.rawGet(.{ .string = "name" }).?.string);
    try std.testing.expect(namespaces.rawGet(.{ .string = "Template" }).?.table == template);
    const project = namespaces.rawGet(.{ .number = 4 }).?.table;
    try std.testing.expectEqualStrings("Project", project.rawGet(.{ .string = "canonicalName" }).?.string);
    const aliases = project.rawGet(.{ .string = "aliases" }).?.table;
    try std.testing.expectEqualStrings("WT", aliases.rawGet(.{ .number = 1 }).?.string);
}
