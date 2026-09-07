const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const exec = @import("vm_exec.zig");
const lua_stdlib = @import("lua_stdlib.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try a.alloc(u8, len);
    if (try file.readPositionalAll(io, bytes, 0) != len) return error.Truncated;
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    const a = std.heap.smp_allocator;
    const source = try readAll(init.io, a, args[1]);
    defer a.free(source);
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try opt.runAot(a, &program);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try lua_stdlib.install(&vm);
    const out = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(out);
    for (out, 0..) |value, index| switch (value) {
        .nil => std.debug.print("{d}:nil\n", .{index}),
        .boolean => |v| std.debug.print("{d}:bool:{}\n", .{ index, v }),
        .number => |v| std.debug.print("{d}:number:{d}\n", .{ index, v }),
        .string => |v| std.debug.print("{d}:string:{s}\n", .{ index, v }),
        else => std.debug.print("{d}:{s}\n", .{ index, @tagName(value) }),
    };
}
