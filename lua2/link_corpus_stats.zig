const entry_pool = @import("vm_entry_pool.zig");
const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const optimizer = @import("vm_optimize.zig");
const codec = @import("vm_codec.zig");
const data = @import("vm_data.zig");
const cleanup = @import("vm_ir_simplify.zig");
const verify = @import("vm_verify.zig");
const dce = @import("vm_dce.zig");
const link_image = @import("vm_link_image.zig");
const link_symbols = @import("vm_link_symbols.zig");
const numeric_link = @import("vm_numeric_link.zig");
const module_model = @import("module_model.zig");

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
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn stringBytes(program: *const ir.Program) u64 {
    var total: u64 = 0;
    for (program.strings.items) |text| total += text.len;
    return total;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len > 5) return error.Usage;
    const mode = if (args.len == 5) args[4] else "";
    const numeric = std.mem.eql(u8, mode, "--numeric-link");
    const semantic_link = numeric or std.mem.eql(u8, mode, "--semantic-link");
    if (args.len == 5 and !semantic_link) return error.UnknownOption;

    const manifest_path = args[1];
    const corpus_root = args[2];
    var manifest = try mmapPath(manifest_path);
    defer manifest.deinit();

    var image = link_image.Image.init(std.heap.smp_allocator);
    defer image.deinit();
    var symbols = link_symbols.Index.init(std.heap.smp_allocator);
    defer symbols.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();

    var modules: u64 = 0;
    var local_inlined: u64 = 0;
    var local_removed: u64 = 0;
    var local_string_entries: u64 = 0;
    var local_string_bytes: u64 = 0;
    var pos: usize = 0;
    while (pos < manifest.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, manifest.bytes, pos, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[pos..nl];
        pos = @min(nl + 1, manifest.bytes.len);
        if (line.len == 0) continue;
        const a = scratch.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, a, line, .{ .ignore_unknown_fields = true });
        const source_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ corpus_root, row.path });
        const source = try readAll(init.io, a, source_path);
        var chunk = try lua.parse(a, source);
        var model = module_model.Builder{ .allocator = a, .source = chunk.source };
        try model.build(chunk.body);
        var program = try ir.lowerChunk(a, &chunk);
        const optimized = if (semantic_link) try optimizer.runSemantics(a, &program) else try optimizer.run(a, &program);
        if (semantic_link) {
            // Compact immutable data while keeping the value graph available.
            _ = try data.run(a, &program);
            _ = try cleanup.compactStrings(a, &program);
        }

        const removed = optimized.removed_functions;
        local_inlined += optimized.inlining.inlined;
        local_removed += removed;
        local_string_entries += program.strings.items.len;
        local_string_bytes += stringBytes(&program);
        const module_index = try image.appendModule(&program);
        if (semantic_link) try symbols.addModule(row.title, &image, module_index, &model);
        program.deinit();
        model.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) {
            std.debug.print("modules={d} functions={d} strings={d}\n", .{
                modules,
                image.program.functions.items.len,
                image.program.strings.items.len,
            });
        }
        _ = scratch.reset(.retain_capacity);
    }

    const global_data = try data.run(std.heap.smp_allocator, &image.program);
    if (numeric) {
        const linked = try numeric_link.run(std.heap.smp_allocator, &image.program, &symbols);
        const linked_cleanup = try cleanup.run(std.heap.smp_allocator, &image.program);
        std.debug.print("NUMERIC_LINK {any} cleanup={any}\n", .{ linked, linked_cleanup });
    }
    if (semantic_link) {
        // Global semantic transforms belong here, before references and registers.
        const final = try optimizer.finalize(std.heap.smp_allocator, &image.program);
        std.debug.print("GLOBAL_FINALIZATION references={any} registers={any} globals={any} direct={any} module_functions={any}\n", .{ final.references, final.registers, final.globals, final.direct, final.module_functions });
    }

    _ = try cleanup.compactStrings(std.heap.smp_allocator, &image.program);
    try verify.run(std.heap.smp_allocator, &image.program);
    const ranges = try entry_pool.run(std.heap.smp_allocator, &image.program);
    try verify.run(std.heap.smp_allocator, &image.program);
    std.debug.print("ENTRY_POOL {any}\n", .{ranges});
    const bytes = try codec.serialize(std.heap.smp_allocator, &image.program);
    defer std.heap.smp_allocator.free(bytes);
    var file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, bytes, 0);
    std.debug.print("ARTIFACT bytes={d} constant_compaction={any}\n", .{ bytes.len, global_data });
    const global_string_bytes = stringBytes(&image.program);
    std.debug.print(
        "TOTAL modules={d} functions={d} constants={d} entries={d} local_inlined={d} local_removed={d}\n",
        .{ modules, image.program.functions.items.len, image.program.constants.items.len, image.program.const_entries.items.len, local_inlined, local_removed },
    );
    std.debug.print(
        "STRINGS local_entries={d} global_entries={d} local_bytes={d} global_bytes={d}\n",
        .{ local_string_entries, image.program.strings.items.len, local_string_bytes, global_string_bytes },
    );
}
