const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const global_abi = @import("vm_global_abi.zig");

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

fn mutatesRequire(program: *const ir.Program, inst: ir.Inst) bool {
    return switch (inst.op) {
        .set_global_slot => inst.aux == global_abi.id("require"),
        .set_global => inst.aux < program.strings.items.len and
            std.mem.eql(u8, program.strings.items[inst.aux], "require"),
        else => false,
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    var modules: usize = 0;
    var mutation_modules: usize = 0;
    var mutation_insts: usize = 0;
    var pos: usize = 0;
    while (pos < manifest.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, manifest.bytes, pos, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[pos..nl];
        pos = @min(nl + 1, manifest.bytes.len);
        if (line.len == 0) continue;
        const allocator = scratch.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, allocator, line, .{ .ignore_unknown_fields = true });
        const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ args[2], row.path });
        const source = try readAll(init.io, allocator, source_path);
        var chunk = try lua.parse(allocator, source);
        var program = try ir.lowerChunk(allocator, &chunk);
        var found_module = false;
        for (program.functions.items, 0..) |maybe, function_id| {
            const function = maybe orelse continue;
            for (function.insts.items, 0..) |inst, pc| {
                if (!mutatesRequire(&program, inst)) continue;
                if (!found_module) mutation_modules += 1;
                found_module = true;
                mutation_insts += 1;
                std.debug.print(
                    "REQUIRE_MUTATION module={d} title={s} path={s} function={d} pc={d}\n",
                    .{ modules, row.title, row.path, function_id, pc },
                );
            }
        }
        program.deinit();
        chunk.deinit();
        modules += 1;
        if (modules % 5000 == 0)
            std.debug.print("REQUIRE_SCAN modules={d} mutation_modules={d} mutation_insts={d}\n", .{
                modules,
                mutation_modules,
                mutation_insts,
            });
        _ = scratch.reset(.retain_capacity);
    }
    std.debug.print("REQUIRE_DONE modules={d} mutation_modules={d} mutation_insts={d}\n", .{
        modules,
        mutation_modules,
        mutation_insts,
    });
}

test "require mutation classification ignores local aliases" {
    var chunk = try lua.parse(std.testing.allocator, "local require=require; return require('Module:X')");
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| try std.testing.expect(!mutatesRequire(&program, inst));
    };

    var global_chunk = try lua.parse(std.testing.allocator, "require=function() return nil end");
    defer global_chunk.deinit();
    var global_program = try ir.lowerChunk(std.testing.allocator, &global_chunk);
    defer global_program.deinit();
    var found = false;
    for (global_program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| found = found or mutatesRequire(&global_program, inst);
    };
    try std.testing.expect(found);
}
