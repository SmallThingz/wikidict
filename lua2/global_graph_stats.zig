const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const model = @import("module_model.zig");
const inline_pass = @import("vm_inline.zig");
const dce = @import("vm_dce.zig");
const link_image = @import("vm_link_image.zig");
const symbols_mod = @import("vm_link_symbols.zig");
const callgraph = @import("vm_global_callgraph.zig");
const facts = @import("vm_link_facts.zig");

const ManifestRow = struct { page_id: u64, title: []const u8, path: []const u8 };
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
    return .{ .bytes = try std.posix.mmap(null, @intCast(stat.size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

fn buildFunctionModules(allocator: std.mem.Allocator, image: *const link_image.Image) ![]u32 {
    const result = try allocator.alloc(u32, image.program.functions.items.len);
    @memset(result, std.math.maxInt(u32));
    for (image.modules.items, 0..) |module, module_index| {
        const end = module.function_base + module.function_count;
        var function_id = module.function_base;
        while (function_id < end) : (function_id += 1) result[function_id] = @intCast(module_index);
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var image = link_image.Image.init(std.heap.smp_allocator);
    defer image.deinit();
    var symbols = symbols_mod.Index.init(std.heap.smp_allocator);
    defer symbols.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    var modules: u64 = 0;
    var pos: usize = 0;
    while (pos < manifest.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, manifest.bytes, pos, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[pos..nl];
        pos = @min(nl + 1, manifest.bytes.len);
        if (line.len == 0) continue;
        const allocator = scratch.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, allocator, line, .{ .ignore_unknown_fields = true });
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ args[2], row.path });
        const source = try readAll(init.io, allocator, path);
        var chunk = try lua.parse(allocator, source);
        var builder = model.Builder{ .allocator = allocator, .source = chunk.source };
        try builder.build(chunk.body);
        var program = try ir.lowerChunk(allocator, &chunk);
        _ = try inline_pass.run(allocator, &program);
        _ = try dce.removeUnreachableFunctions(allocator, &program);
        const module_index = try image.appendModule(&program);
        try symbols.addModule(row.title, &image, module_index, &builder);
        program.deinit();
        builder.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 10000 == 0) std.debug.print("linked={d} functions={d} exports={d}\n", .{
            modules, image.program.functions.items.len, symbols.exported_functions.count(),
        });
        _ = scratch.reset(.retain_capacity);
    }

    std.debug.print("building-global-graph require_builtin_safe={}\n", .{facts.requireBuiltinSafe(&image.program)});
    var graph = try callgraph.build(std.heap.smp_allocator, &image.program, &symbols);
    defer graph.deinit();
    const function_modules = try buildFunctionModules(std.heap.smp_allocator, &image);
    defer std.heap.smp_allocator.free(function_modules);
    var cross_edges: u64 = 0;
    var exported_edges: u64 = 0;
    var recursive_edges: u64 = 0;
    var single_resolved: u64 = 0;
    var single_cross: u64 = 0;
    var single_exported: u64 = 0;
    for (graph.edges.items) |edge| {
        const cross = function_modules[edge.caller] != function_modules[edge.callee];
        if (cross) cross_edges += 1;
        if (symbols.isExportedFunction(edge.callee)) exported_edges += 1;
        if (graph.sameScc(edge.caller, edge.callee)) recursive_edges += 1;
        if (graph.incoming[edge.callee] == 1 and !graph.sameScc(edge.caller, edge.callee)) {
            single_resolved += 1;
            if (cross) single_cross += 1;
            if (symbols.isExportedFunction(edge.callee)) single_exported += 1;
        }
    }
    std.debug.print(
        "TOTAL modules={d} functions={d} exports={d} edges={d} components={d}\n",
        .{ modules, image.program.functions.items.len, symbols.exported_functions.count(), graph.edges.items.len, graph.component_count },
    );
    std.debug.print(
        "EDGES cross={d} exported={d} recursive={d} single={d} single_cross={d} single_exported={d}\n",
        .{ cross_edges, exported_edges, recursive_edges, single_resolved, single_cross, single_exported },
    );
}
