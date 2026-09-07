const std = @import("std");
const lua = @import("root.zig");
const vmir = @import("vm_ir.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const base = if (args.len >= 2) args[1] else ".zig-cache/wiktionary-lua-2026-04-01/modules";
    var dir = try std.Io.Dir.cwd().openDir(init.io, base, .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var total: usize = 0;
    var ok: usize = 0;
    var fail: usize = 0;
    var source_bytes: u64 = 0;
    var functions: u64 = 0;
    var insts: u64 = 0;
    var operands: u64 = 0;
    var strings: u64 = 0;
    var constants: u64 = 0;
    var const_entries: u64 = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        total += 1;
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, entry.name });
        var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
        defer file.close(init.io);
        const stat = try file.stat(init.io);
        source_bytes += stat.size;
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const source = try a.alloc(u8, len);
        _ = try file.readPositionalAll(init.io, source, 0);
        var chunk = lua.parse(a, source) catch |err| {
            fail += 1;
            std.debug.print("PARSE_FAIL\t{s}\t{s}\n", .{ entry.name, @errorName(err) });
            continue;
        };
        defer chunk.deinit();
        var p = vmir.lowerChunk(a, &chunk) catch |err| {
            fail += 1;
            std.debug.print("LOWER_FAIL\t{s}\t{s}\n", .{ entry.name, @errorName(err) });
            continue;
        };
        defer p.deinit();
        functions += p.functions.items.len;
        strings += p.strings.items.len;
        constants += p.constants.items.len;
        const_entries += p.const_entries.items.len;
        for (p.functions.items) |mf| if (mf) |f| {
            insts += f.insts.items.len;
            operands += f.operands.items.len;
        };
        ok += 1;
        if (total % 5000 == 0) std.debug.print("checked {d} ok={d} fail={d} funcs={d} insts={d}\n", .{ total, ok, fail, functions, insts });
    }
    std.debug.print("TOTAL {d} OK {d} FAIL {d} BYTES {d} FUNCTIONS {d} INSTS {d} OPERANDS {d} STRINGS {d} CONSTANTS {d} CONST_ENTRIES {d}\n", .{ total, ok, fail, source_bytes, functions, insts, operands, strings, constants, const_entries });
    if (fail != 0) return error.CorpusLowerFailed;
}
