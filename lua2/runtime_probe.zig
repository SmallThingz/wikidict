const std = @import("std");
const exec = @import("vm_exec.zig");
const host = @import("wiktionary_runtime.zig");
const rt = @import("vm_runtime.zig");

fn printValue(w: *std.Io.Writer, v: rt.Value) !void {
    switch (v) {
        .nil => try w.writeAll("nil"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| try w.print("{d}", .{n}),
        .string => |s| try w.writeAll(s),
        .table => try w.writeAll("<table>"),
        .closure, .native => try w.writeAll("<function>"),
    }
}


fn parseArg(raw: []const u8) !rt.Value {
    if (std.mem.startsWith(u8, raw, "n:")) return .{ .number = try std.fmt.parseFloat(f64, raw[2..]) };
    if (std.mem.eql(u8, raw, "nil:")) return .nil;
    if (std.mem.eql(u8, raw, "b:true")) return .{ .boolean = true };
    if (std.mem.eql(u8, raw, "b:false")) return .{ .boolean = false };
    if (std.mem.startsWith(u8, raw, "s:")) return .{ .string = raw[2..] };
    return .{ .string = raw };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5) return error.Usage;
    var runtime = host.Runtime.init(init.arena.allocator(), init.io, args[3]);
    try runtime.loadManifest(args[1]);
    try runtime.loadRedirects(args[2]);
    try runtime.loadSiblingTemplates();
    var vm = try exec.Vm.init(init.arena.allocator());
    try runtime.install(&vm);
    const module = try runtime.requireByName(&vm, args[4]);
    if (args.len > 5 and std.mem.eql(u8, args[5], "--get")) {
        var value = module;
        for (args[6..]) |key_raw| {
            const key: rt.Value = if (std.fmt.parseFloat(f64, key_raw)) |n| .{ .number = n } else |_| .{ .string = key_raw };
            value = try vm.getIndex(value, key);
        }
        var get_buf: [1024]u8 = undefined;
        var get_stdout = std.Io.File.stdout().writer(init.io, &get_buf);
        try printValue(&get_stdout.interface, value);
        try get_stdout.interface.writeByte('\n');
        try get_stdout.interface.flush();
        return;
    }
    var callable = module;
    var first_arg: usize = 5;
    if (module == .table and args.len > 5) {
        callable = try vm.getIndex(module, .{ .string = args[5] });
        first_arg = 6;
    }
    if (callable != .closure and callable != .native) {
        var buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buf);
        try printValue(&stdout.interface, module);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
        return;
    }
    var out: []const rt.Value = undefined;
    if (first_arg < args.len and std.mem.eql(u8, args[first_arg], "--frame")) {
        const pairs = args[first_arg + 1 ..];
        const fargs = try init.arena.allocator().alloc(host.FrameArg, pairs.len);
        for (pairs, 0..) |pair, i| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadFrameArg;
            const key_raw = pair[0..eq];
            const value_raw = pair[eq + 1 ..];
            const key: rt.Value = if (std.fmt.parseInt(u32, key_raw, 10)) |n| .{ .number = @floatFromInt(n) } else |_| .{ .string = key_raw };
            fargs[i] = .{ .key = key, .value = try parseArg(value_raw) };
        }
        const frame = try host.makeFrame(&runtime, args[4], fargs, null);
        out = try host.invoke(&runtime, &vm, args[4], args[5], frame);
    } else {
        const argv = try init.arena.allocator().alloc(rt.Value, args.len - first_arg);
        for (args[first_arg..], 0..) |arg, i| argv[i] = try parseArg(arg);
        out = try vm.callValue(callable, argv);
    }
    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout.interface;
    for (out, 0..) |v, i| {
        if (i != 0) try w.writeByte('\t');
        try printValue(w, v);
    }
    try w.writeByte('\n');
    try w.flush();
}
