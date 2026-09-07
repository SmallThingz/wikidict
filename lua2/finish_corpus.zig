const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const codec = @import("vm_codec.zig");
const verify = @import("vm_verify.zig");
const wire = @import("vm_wire.zig");
const sem = @import("vm_semantics.zig");
const Counts = struct { functions: u64 = 0, instructions: u64 = 0, registers: u64 = 0, operands: u64 = 0, strings: u64 = 0, string_bytes: u64 = 0, constants: u64 = 0, entries: u64 = 0, wire_bytes: u64 = 0, payload: u64 = 0 };
fn measure(a: std.mem.Allocator, p: *const ir.Program, bytes: []const u8) !Counts {
    var out = Counts{ .functions = p.functions.items.len, .strings = p.strings.items.len, .constants = p.constants.items.len, .entries = p.const_entries.items.len, .payload = bytes.len };
    for (p.strings.items) |text| out.string_bytes += text.len;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    for (p.functions.items) |maybe| if (maybe) |f| {
        out.instructions += f.insts.items.len;
        out.registers += f.reg_count;
        out.operands += f.operands.items.len;
        buffer.clearRetainingCapacity();
        for (f.insts.items, 0..) |inst, pc| try wire.writeInst(&buffer, a, @intCast(pc), inst);
        out.wire_bytes += buffer.items.len;
    };
    return out;
}
fn add(comptime T: type, target: *T, source: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| @field(target, field.name) += @field(source, field.name);
}
fn read(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try f.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    return bytes;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const manifest = try read(init.io, init.arena.allocator(), args[1]);
    const limit = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else std.math.maxInt(usize);
    var before = Counts{};
    var after = Counts{};
    var totals = opt.Stats{};
    var done: usize = 0;
    var failed: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (done + failed >= limit) break;
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const row = try std.json.parseFromSliceLeaky(struct { path: []const u8, title: []const u8 }, a, line, .{ .ignore_unknown_fields = true });
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[2], row.path });
        const source = try read(init.io, a, path);
        var chunk = try lua.parse(a, source);
        defer chunk.deinit();
        var p = try ir.lowerChunk(a, &chunk);
        defer p.deinit();
        const original = try codec.serialize(a, &p);
        const before_one = try measure(a, &p, original);
        const stats = opt.run(a, &p) catch |err| {
            failed += 1;
            std.debug.print("FAIL {s} {s} {s}\n", .{ row.path, row.title, @errorName(err) });
            continue;
        };
        const bytes = try codec.serialize(a, &p);
        var restored = try codec.deserializeBorrowed(a, bytes);
        defer restored.deinit();
        try verify.run(a, &restored);
        const second = try codec.serialize(a, &restored);
        if (!std.mem.eql(u8, bytes, second)) return error.UnstableCodecRoundtrip;
        add(Counts, &before, before_one);
        add(Counts, &after, try measure(a, &p, bytes));
        add(@TypeOf(totals.inlining), &totals.inlining, stats.inlining);
        add(@TypeOf(totals.flow), &totals.flow, stats.flow);
        add(@TypeOf(totals.direct), &totals.direct, stats.direct);
        add(@TypeOf(totals.globals), &totals.globals, stats.globals);
        add(@TypeOf(totals.layouts), &totals.layouts, stats.layouts);
        add(@TypeOf(totals.shapes), &totals.shapes, stats.shapes);
        add(@TypeOf(totals.scalar), &totals.scalar, stats.scalar);
        add(@TypeOf(totals.cleanup), &totals.cleanup, stats.cleanup);
        add(@TypeOf(totals.registers), &totals.registers, stats.registers);
        totals.removed_functions += stats.removed_functions;
        done += 1;
        if (done % 1000 == 0) std.debug.print("PROGRESS ok={d} failed={d} instructions={d}->{d}\n", .{ done, failed, before.instructions, after.instructions });
    }
    std.debug.print("TOTAL modules={d} failures={d}\n", .{ done, failed });
    inline for (@typeInfo(Counts).@"struct".fields) |field| std.debug.print("{s} {d} -> {d}\n", .{ field.name, @field(before, field.name), @field(after, field.name) });
    std.debug.print("TRANSFORMS inline={any} flow={any} shape={any} scalar={any} cleanup={any}\n", .{ totals.inlining, totals.flow, totals.shapes, totals.scalar, totals.cleanup });
    std.debug.print("STATIC globals={any} direct={any} layouts={any}\n", .{ totals.globals, totals.direct, totals.layouts });
    if (failed != 0) return error.CorpusOptimizationFailed;
}
