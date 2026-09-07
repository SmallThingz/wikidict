const std = @import("std");
const host = @import("wiktionary_runtime.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");

const Arg = struct { name: []const u8, value: []const u8 };
const Entry = struct {
    module: []const u8,
    function: []const u8,
    current: std.ArrayList(Arg) = .empty,
    parent: std.ArrayList(Arg) = .empty,
    is_root: bool = false,
};

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const out = try a.alloc(u8, n);
    _ = try f.readPositionalAll(io, out, 0);
    return out;
}

fn unescape(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        const c = raw[i];
        i += 1;
        try out.append(a, switch (c) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            else => c,
        });
    }
    return out.toOwnedSlice(a);
}

fn keyAlloc(a: std.mem.Allocator, module: []const u8, function: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ module, function });
}

fn getEntry(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(*Entry), module: []const u8, function: []const u8) !*Entry {
    const key = try keyAlloc(a, module, function);
    if (map.get(key)) |entry| return entry;
    const entry = try a.create(Entry);
    entry.* = .{ .module = module, .function = function };
    try map.put(a, key, entry);
    return entry;
}

fn parseUsage(a: std.mem.Allocator, bytes: []const u8, map: *std.StringHashMapUnmanaged(*Entry), roots: *std.ArrayList(*Entry)) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or line[1] != '\t') continue;
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(a);
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |field| try fields.append(a, field);
        if (fields.items.len < 3) continue;
        const kind = fields.items[0][0];
        if (kind != 'U' and kind != 'P' and kind != 'Q') continue;
        const module = try unescape(a, fields.items[1]);
        const function = try unescape(a, fields.items[2]);
        const entry = try getEntry(a, map, module, function);
        if (kind == 'U') {
            if (!entry.is_root) {
                entry.is_root = true;
                try roots.append(a, entry);
            }
            continue;
        }
        if (fields.items.len < 6) continue;
        const missing = std.mem.eql(u8, fields.items[5], "true");
        var chosen: ?[]const u8 = null;
        if (fields.items.len > 6) chosen = try unescape(a, fields.items[6]) else if (!missing and std.mem.eql(u8, fields.items[4], "true")) chosen = "";
        if (chosen) |value| {
            const arg = Arg{ .name = try unescape(a, fields.items[3]), .value = value };
            if (kind == 'P') try entry.current.append(a, arg) else try entry.parent.append(a, arg);
        }
    }
}

fn frameArgs(a: std.mem.Allocator, args: []const Arg) ![]host.FrameArg {
    const out = try a.alloc(host.FrameArg, args.len);
    for (args, 0..) |arg, i| {
        const key: rt.Value = if (std.fmt.parseInt(u32, arg.name, 10)) |n|
            .{ .number = @floatFromInt(n) }
        else |_|
            .{ .string = arg.name };
        out[i] = .{ .key = key, .value = .{ .string = arg.value } };
    }
    return out;
}

const Failure = struct {
    count: usize = 0,
    example_module: []const u8 = "",
    example_function: []const u8 = "",
    inner_module: []const u8 = "<native>",
    inner_function_id: u32 = 0,
    inner_pc: usize = 0,
    inner_source_start: u32 = 0,
    inner_source_end: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.Usage;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const usage = try readAll(init.io, a, args[2]);
    var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
    var roots: std.ArrayList(*Entry) = .empty;
    try parseUsage(a, usage, &entries, &roots);
    var runtime = host.Runtime.init(a, init.io, args[3]);
    try runtime.loadManifest(args[1]);
    try runtime.loadRedirects(args[2]);
    try runtime.loadSiblingTemplates();
    var vm = try exec.Vm.init(a);
    try runtime.install(&vm);
    const limit = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else roots.items.len;
    var failures: std.StringHashMapUnmanaged(Failure) = .empty;
    var succeeded: usize = 0;
    var attempted: usize = 0;
    for (roots.items) |entry| {
        if (attempted >= limit) break;
        attempted += 1;
        const parent_args = try frameArgs(a, entry.parent.items);
        const parent = try host.makeFrame(&runtime, "Template:smoke", parent_args, null);
        const current_args = try frameArgs(a, entry.current.items);
        const frame = try host.makeFrame(&runtime, entry.module, current_args, parent);
        vm.last_error = .nil;
        vm.failure = null;
        if (host.invoke(&runtime, &vm, entry.module, entry.function, frame)) |_| {
            succeeded += 1;
        } else |err| {
            const name: []const u8 = if (err == error.LuaRaised and vm.last_error == .string) blk: {
                const message = vm.last_error.string;
                const shown = message[0..@min(message.len, 180)];
                break :blk try std.fmt.allocPrint(a, "LuaRaised:{s}", .{shown});
            } else @errorName(err);
            const gop = try failures.getOrPut(a, name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .count = 0,
                    .example_module = entry.module,
                    .example_function = entry.function,
                };
                if (vm.failure) |failure| {
                    gop.value_ptr.inner_module = host.titleForProgram(&runtime, failure.program) orelse "<unknown-program>";
                    gop.value_ptr.inner_function_id = failure.function_id;
                    gop.value_ptr.inner_pc = failure.pc;
                    if (failure.function_id < failure.program.functions.items.len) {
                        if (failure.program.functions.items[failure.function_id]) |fun| {
                            gop.value_ptr.inner_source_start = fun.source_start;
                            gop.value_ptr.inner_source_end = fun.source_end;
                        }
                    }
                }
            }
            gop.value_ptr.count += 1;
        }
        if (attempted % 100 == 0)
            std.debug.print("attempted={d} success={d} fail={d}\n", .{ attempted, succeeded, attempted - succeeded });
    }
    var rows: std.ArrayList(struct { name: []const u8, failure: Failure }) = .empty;
    var fit = failures.iterator();
    while (fit.next()) |item| try rows.append(a, .{ .name = item.key_ptr.*, .failure = item.value_ptr.* });
    std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
        fn lessThan(_: void, lhs: @TypeOf(rows.items[0]), rhs: @TypeOf(rows.items[0])) bool {
            if (lhs.failure.count != rhs.failure.count) return lhs.failure.count > rhs.failure.count;
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    std.debug.print("TOTAL attempted={d} success={d} fail={d} kinds={d}\n", .{ attempted, succeeded, attempted - succeeded, rows.items.len });
    for (rows.items) |row| std.debug.print(
        "FAIL\t{d}\t{s}\troot={s}.{s}\tinner={s}\tfn={d}\tpc={d}\tspan={d}..{d}\n",
        .{
            row.failure.count,
            row.name,
            row.failure.example_module,
            row.failure.example_function,
            row.failure.inner_module,
            row.failure.inner_function_id,
            row.failure.inner_pc,
            row.failure.inner_source_start,
            row.failure.inner_source_end,
        },
    );
}
