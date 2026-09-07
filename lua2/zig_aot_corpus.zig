const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const optimizer = @import("vm_optimize.zig");
const data = @import("vm_data.zig");
const cleanup = @import("vm_ir_simplify.zig");
const verify = @import("vm_verify.zig");
const link_image = @import("vm_link_image.zig");
const link_symbols = @import("vm_link_symbols.zig");
const numeric_link = @import("vm_numeric_link.zig");
const module_model = @import("module_model.zig");
const aot = @import("zig_aot.zig");
const aot_stats = @import("zig_aot_stats.zig");

const ManifestRow = struct {
    page_id: u64,
    title: []const u8,
    path: []const u8,
};

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};
fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

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
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len > 5) return error.Usage;
    const limit = if (args.len == 5)
        try std.fmt.parseInt(usize, args[4], 10)
    else
        std.math.maxInt(usize);

    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var image = link_image.Image.init(std.heap.smp_allocator);
    defer image.deinit();
    var symbols = link_symbols.Index.init(std.heap.smp_allocator);
    defer symbols.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();

    var modules: usize = 0;
    var local_inlined: u64 = 0;
    var pos: usize = 0;
    while (pos < manifest.bytes.len and modules < limit) {
        const nl = std.mem.indexOfScalarPos(u8, manifest.bytes, pos, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[pos..nl];
        pos = @min(nl + 1, manifest.bytes.len);
        if (line.len == 0) continue;
        const allocator = scratch.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, allocator, line, .{ .ignore_unknown_fields = true });
        const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ args[2], row.path });
        const source = try readAll(init.io, allocator, source_path);
        var chunk = try lua.parse(allocator, source);
        var model = module_model.Builder{ .allocator = allocator, .source = chunk.source };
        try model.build(chunk.body);
        var program = try ir.lowerChunk(allocator, &chunk);
        const optimized = try optimizer.runSemantics(allocator, &program);
        local_inlined += optimized.inlining.inlined;
        _ = try data.run(allocator, &program);
        _ = try cleanup.compactStrings(allocator, &program);

        const module_index = try image.appendModule(&program);
        try symbols.addModule(row.title, &image, module_index, &model);
        program.deinit();
        model.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 1000 == 0)
            std.debug.print("AOT_LINK modules={d} functions={d} strings={d}\n", .{
                modules,
                image.program.functions.items.len,
                image.program.strings.items.len,
            });
        _ = scratch.reset(.retain_capacity);
    }
    _ = try data.run(std.heap.smp_allocator, &image.program);
    const linked = try numeric_link.run(std.heap.smp_allocator, &image.program, &symbols);
    const linked_cleanup = try cleanup.run(std.heap.smp_allocator, &image.program);
    const final = try optimizer.finalizeAot(std.heap.smp_allocator, &image.program);
    _ = try cleanup.compactStrings(std.heap.smp_allocator, &image.program);
    try verify.run(std.heap.smp_allocator, &image.program);

    const classified = aot_stats.collect(&image.program);
    const generated = try aot.generate(std.heap.smp_allocator, &image.program);
    defer std.heap.smp_allocator.free(generated.source);
    try writeAll(init.io, args[3], generated.source);
    std.debug.print(
        "AOT_DONE modules={d} functions={d} local_inlined={d} bytes={d}\n",
        .{ modules, image.program.functions.items.len, local_inlined, generated.source.len },
    );
    std.debug.print(
        "AOT_LINK numeric={any} cleanup={any} globals={any} module_functions={any}\n",
        .{ linked, linked_cleanup, final.globals, final.module_functions },
    );
    std.debug.print(
        "AOT_CODE functions={d} instructions={d} dynamic_calls={d} dynamic_indexes={d} string_fields={d}\n",
        .{ generated.stats.functions, generated.stats.instructions, generated.stats.dynamic_calls, generated.stats.dynamic_indexes, generated.stats.string_fields },
    );
    std.debug.print("AOT_DYNAMIC {any}\n", .{classified});
}
