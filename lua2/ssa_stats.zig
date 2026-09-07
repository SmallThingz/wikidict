const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");

fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try allocator.alloc(u8, len);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;

    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var iterator = dir.iterate();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var modules: u64 = 0;
    var functions: u64 = 0;
    var instructions: u64 = 0;
    var moves: u64 = 0;
    var source_regs: u64 = 0;
    var values: u64 = 0;
    var canonical_values: u64 = 0;
    var instruction_values: u64 = 0;
    var canonical_instruction_values: u64 = 0;
    var dead_instruction_values: u64 = 0;
    var parameters: u64 = 0;
    var phis: u64 = 0;
    var canonical_phis: u64 = 0;
    var memory_values: u64 = 0;
    var used_values: u64 = 0;

    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const allocator = arena.allocator();
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ args[1], entry.name });
        const source = try readAll(init.io, allocator, path);
        var chunk = lua.parse(allocator, source) catch |err| {
            std.debug.print("PARSE_FAIL\t{s}\t{s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        var program = ir.lowerChunk(allocator, &chunk) catch |err| {
            std.debug.print("LOWER_FAIL\t{s}\t{s}\n", .{ entry.name, @errorName(err) });
            return err;
        };

        modules += 1;
        for (program.functions.items) |maybe_function| {
            const function = maybe_function orelse continue;
            functions += 1;
            instructions += function.insts.items.len;
            source_regs += function.reg_count;
            for (function.insts.items) |inst| {
                if (inst.op == .move) moves += 1;
            }

            var graph_function = try ssa.build(allocator, &program, &function);
            defer graph_function.deinit();
            values += graph_function.values.items.len;
            for (graph_function.values.items, 0..) |value, id_usize| {
                const id: ssa.ValueId = @intCast(id_usize);
                const canonical = graph_function.canonicalValue(id) == id;
                if (canonical) canonical_values += 1;
                if (value.uses != 0) used_values += 1;
                switch (value.kind) {
                    .instruction => {
                        instruction_values += 1;
                        if (canonical) canonical_instruction_values += 1;
                        if (canonical and value.uses == 0) dead_instruction_values += 1;
                    },
                    .parameter => parameters += 1,
                    .phi => {
                        phis += 1;
                        if (canonical) canonical_phis += 1;
                    },
                    .memory => memory_values += 1,
                }
            }
        }

        program.deinit();
        chunk.deinit();
        if (modules % 10000 == 0) {
            std.debug.print("modules={d} values={d} canonical={d} phis={d}/{d}\n", .{
                modules,
                values,
                canonical_values,
                canonical_phis,
                phis,
            });
        }
        _ = arena.reset(.retain_capacity);
    }

    std.debug.print("TOTAL modules={d} functions={d} instructions={d} moves={d} source_regs={d}\n", .{
        modules,
        functions,
        instructions,
        moves,
        source_regs,
    });
    std.debug.print("SSA values={d} canonical={d} used={d} instruction={d} canonical_instruction={d} dead_instruction={d} parameters={d} phis={d} canonical_phis={d} memory={d}\n", .{
        values,
        canonical_values,
        used_values,
        instruction_values,
        canonical_instruction_values,
        dead_instruction_values,
        parameters,
        phis,
        canonical_phis,
        memory_values,
    });
}
