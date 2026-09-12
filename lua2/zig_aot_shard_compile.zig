const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const aot = @import("zig_aot.zig");

fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try allocator.alloc(u8, len);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    return bytes;
}

fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn shardPath(allocator: std.mem.Allocator, dir: []const u8, kind: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}_{d:0>4}.zig", .{ dir, kind, index });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) return error.Usage;
    const allocator = std.heap.smp_allocator;
    const source = try readAll(init.io, allocator, args[1]);
    defer allocator.free(source);
    var chunk = try lua.parse(allocator, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    _ = try opt.runAot(allocator, &program);

    var config = aot.ShardConfig{};
    if (args.len == 4) config.functions_per_shard = try std.fmt.parseInt(usize, args[3], 10);
    var stats = aot.Stats{};
    const descriptor_roots = try aot.analyzeModuleRootDescriptors(allocator, &program, config.module_registry);
    const buffered_functions = try aot.analyzeBufferedFunctions(allocator, &program);
    defer allocator.free(buffered_functions);
    defer allocator.free(descriptor_roots);

    const root = try aot.generateShardedRootWithDescriptors(allocator, &program, config, descriptor_roots);
    defer allocator.free(root);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{args[2]});
    defer allocator.free(root_path);
    try writeAll(init.io, root_path, root);

    const function_shards = try aot.functionShardCount(&program, config);
    for (0..function_shards) |index| {
        const generated = try aot.generateFunctionShardWithPlans(allocator, &program, config, descriptor_roots, buffered_functions, index, &stats);
        defer allocator.free(generated);
        const path = try shardPath(allocator, args[2], "functions", index);
        defer allocator.free(path);
        try writeAll(init.io, path, generated);
    }
    const constant_shards = try aot.constantShardCount(&program, config);
    for (0..constant_shards) |index| {
        const generated = try aot.generateConstantShard(allocator, &program, config, index);
        defer allocator.free(generated);
        const path = try shardPath(allocator, args[2], "constants", index);
        defer allocator.free(path);
        try writeAll(init.io, path, generated);
    }
    const entry_shards = try aot.entryShardCount(&program, config);
    for (0..entry_shards) |index| {
        const generated = try aot.generateEntryShard(allocator, &program, config, index);
        defer allocator.free(generated);
        const path = try shardPath(allocator, args[2], "entries", index);
        defer allocator.free(path);
        try writeAll(init.io, path, generated);
    }

    std.debug.print(
        "AOT_SHARDED functions={d} instructions={d} function_shards={d} constant_shards={d} entry_shards={d} root_bytes={d}\n",
        .{ stats.functions, stats.instructions, function_shards, constant_shards, entry_shards, root.len },
    );
}
