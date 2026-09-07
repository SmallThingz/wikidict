const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const exec = @import("vm_exec.zig");
const lib = @import("lua_stdlib.zig");
const rt = @import("vm_runtime.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const out = try a.alloc(u8, n);
    _ = try f.readPositionalAll(io, out, 0);
    return out;
}

fn printValue(w: *std.Io.Writer, v: rt.Value) !void {
    switch (v) {
        .nil => try w.writeAll("nil"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| try w.print("{d}", .{n}),
        .string => |s| try w.print("{f}", .{std.zig.fmtString(s)}),
        .table => try w.writeAll("<table>"),
        .closure, .function, .native => try w.writeAll("<function>"),
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingInput;
    const source = try readAll(init.io, init.arena.allocator(), args[1]);
    var chunk = try lua.parse(init.arena.allocator(), source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(init.arena.allocator(), &chunk);
    defer program.deinit();
    var vm = try exec.Vm.init(init.arena.allocator());
    try lib.install(&vm);
    const out = try vm.executeRoot(&program, &.{});
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
