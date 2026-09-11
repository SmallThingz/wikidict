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
const static_fields_pass = @import("vm_static_fields.zig");
const module_model = @import("module_model.zig");
const aot = @import("zig_aot.zig");
const aot_stats = @import("zig_aot_stats.zig");
const module_registry_gen = @import("zig_module_registry_gen.zig");
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

fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len > 8) return error.Usage;
    var sharded = false;
    var external_data = false;
    var external_functions = false;
    var limit: usize = std.math.maxInt(usize);
    var have_limit = false;
    for (args[4..]) |arg| {
        if (std.mem.eql(u8, arg, "--sharded")) {
            if (sharded) return error.Usage;
            sharded = true;
        } else if (std.mem.eql(u8, arg, "--external-data")) {
            if (external_data) return error.Usage;
            external_data = true;
        } else if (std.mem.eql(u8, arg, "--external-functions")) {
            if (external_functions) return error.Usage;
            external_functions = true;
        } else {
            if (have_limit) return error.Usage;
            limit = try std.fmt.parseInt(usize, arg, 10);
            have_limit = true;
        }
    }
    if ((external_data or external_functions) and !sharded) return error.Usage;

    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var image = link_image.Image.init(std.heap.smp_allocator);
    defer image.deinit();
    var symbols = link_symbols.Index.init(std.heap.smp_allocator);
    defer symbols.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var module_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (module_names.items) |name| std.heap.smp_allocator.free(@constCast(name));
        module_names.deinit(std.heap.smp_allocator);
    }
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
        if (module_index != module_names.items.len) return error.ModuleRegistryMismatch;
        try symbols.addModule(row.title, &image, module_index, &model);
        const title_copy = try std.heap.smp_allocator.dupe(u8, row.title);
        module_names.append(std.heap.smp_allocator, title_copy) catch |err| {
            std.heap.smp_allocator.free(title_copy);
            return err;
        };
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
    const staged_static_fields = try static_fields_pass.tagCallHints(std.heap.smp_allocator, &image.program);
    const origins = try aot_stats.collectOrigins(std.heap.smp_allocator, &image.program);
    const unguarded_call_origins = try aot_stats.collectUnguardedCallOrigins(std.heap.smp_allocator, &image.program);
    const unguarded_call_field_object_origins = try aot_stats.collectUnguardedCallFieldObjectOrigins(std.heap.smp_allocator, &image.program);
    var unguarded_call_field_names = try aot_stats.collectUnguardedCallFieldNames(std.heap.smp_allocator, &image.program);
    defer unguarded_call_field_names.deinit();
    const global_fields = try aot_stats.collectGlobalFields(std.heap.smp_allocator, &image.program);
    const upvalue_origins = try aot_stats.collectUpvalueOrigins(std.heap.smp_allocator, &image.program);
    const unguarded_upvalue_call_origins = try aot_stats.collectUnguardedUpvalueCallOrigins(std.heap.smp_allocator, &image.program);
    var final = try optimizer.finalizeAot(std.heap.smp_allocator, &image.program);
    final.static_fields.guarded_calls += staged_static_fields.guarded_calls;
    final.static_fields.candidate_calls += staged_static_fields.candidate_calls;
    _ = try cleanup.compactStrings(std.heap.smp_allocator, &image.program);
    try verify.run(std.heap.smp_allocator, &image.program);

    const classified = aot_stats.collect(&image.program);
    var generated_stats = aot.Stats{};
    var generated_bytes: u64 = 0;
    if (sharded) {
        if (module_names.items.len != image.program.module_roots.items.len) return error.ModuleRegistryMismatch;
        const registry_source = try module_registry_gen.generate(std.heap.smp_allocator, module_names.items);
        defer std.heap.smp_allocator.free(registry_source);
        const registry_path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/module_registry.zig", .{args[3]});
        defer std.heap.smp_allocator.free(registry_path);
        try writeAll(init.io, registry_path, registry_source);
        generated_bytes += registry_source.len;

        const config = aot.ShardConfig{ .module_registry = true, .external_data = external_data, .external_functions = external_functions };
        if (external_data) {
            const program_data = try aot.generateProgramData(std.heap.smp_allocator, &image.program);
            defer std.heap.smp_allocator.free(program_data);
            const data_path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/aot-data.bin", .{args[3]});
            defer std.heap.smp_allocator.free(data_path);
            try writeAll(init.io, data_path, program_data);
            std.debug.print("AOT_DATA bytes={d} constants={d} entries={d}\n", .{ program_data.len, image.program.constants.items.len, image.program.const_entries.items.len });
        }

        const descriptor_roots = try aot.analyzeModuleRootDescriptors(std.heap.smp_allocator, &image.program, true);
        defer std.heap.smp_allocator.free(descriptor_roots);
        var descriptor_root_count: usize = 0;
        for (descriptor_roots) |descriptor| descriptor_root_count += @intFromBool(descriptor);
        const root = try aot.generateShardedRootWithDescriptors(std.heap.smp_allocator, &image.program, config, descriptor_roots);
        defer std.heap.smp_allocator.free(root);
        const root_path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/root.zig", .{args[3]});
        defer std.heap.smp_allocator.free(root_path);
        try writeAll(init.io, root_path, root);
        generated_bytes += root.len;

        const function_shards = try aot.functionShardCount(&image.program, config);
        for (0..function_shards) |index| {
            const source = try aot.generateFunctionShardWithDescriptors(std.heap.smp_allocator, &image.program, config, descriptor_roots, index, &generated_stats);
            defer std.heap.smp_allocator.free(source);
            const path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/functions_{d:0>4}.zig", .{ args[3], index });
            defer std.heap.smp_allocator.free(path);
            try writeAll(init.io, path, source);
            generated_bytes += source.len;
        }
        const constant_shards = if (external_data) 0 else try aot.constantShardCount(&image.program, config);
        for (0..constant_shards) |index| {
            const source = try aot.generateConstantShard(std.heap.smp_allocator, &image.program, config, index);
            defer std.heap.smp_allocator.free(source);
            const path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/constants_{d:0>4}.zig", .{ args[3], index });
            defer std.heap.smp_allocator.free(path);
            try writeAll(init.io, path, source);
            generated_bytes += source.len;
        }
        const entry_shards = if (external_data) 0 else try aot.entryShardCount(&image.program, config);
        for (0..entry_shards) |index| {
            const source = try aot.generateEntryShard(std.heap.smp_allocator, &image.program, config, index);
            defer std.heap.smp_allocator.free(source);
            const path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/entries_{d:0>4}.zig", .{ args[3], index });
            defer std.heap.smp_allocator.free(path);
            try writeAll(init.io, path, source);
            generated_bytes += source.len;
        }
        std.debug.print("AOT_SHARDS functions={d} constants={d} entries={d} descriptor_roots={d} external_functions={}\n", .{ function_shards, constant_shards, entry_shards, descriptor_root_count, external_functions });
    } else if (!std.mem.eql(u8, args[3], "-")) {
        const generated = try aot.generate(std.heap.smp_allocator, &image.program);
        defer std.heap.smp_allocator.free(generated.source);
        generated_stats = generated.stats;
        generated_bytes = generated.source.len;
        try writeAll(init.io, args[3], generated.source);
    }
    std.debug.print(
        "AOT_DONE modules={d} functions={d} local_inlined={d} bytes={d}\n",
        .{ modules, image.program.functions.items.len, local_inlined, generated_bytes },
    );
    std.debug.print(
        "AOT_LINK numeric={any} cleanup={any} globals={any} static_fields={any} module_functions={any}\n",
        .{ linked, linked_cleanup, final.globals, final.static_fields, final.module_functions },
    );
    std.debug.print(
        "AOT_CODE functions={d} instructions={d} dynamic_calls={d} emitted_direct_calls={d} emitted_guarded_calls={d} dynamic_indexes={d} string_fields={d}\n",
        .{ classified.functions, classified.instructions, classified.dynamic_calls, generated_stats.direct_calls, generated_stats.guarded_calls, classified.dynamic_indexes, classified.string_fields },
    );
    std.debug.print("AOT_DYNAMIC {any}\n", .{classified});
    std.debug.print("AOT_GLOBAL_FIELDS", .{});
    for (global_abi.names, global_fields.slots) |name, count| if (count != 0)
        std.debug.print(" {s}={d}", .{ name, count });
    std.debug.print(" other={d}\n", .{global_fields.named_other});
    std.debug.print("AOT_GLOBAL_STORES", .{});
    for (global_abi.names, global_fields.stores) |name, count| if (count != 0)
        std.debug.print(" {s}={d}", .{ name, count });
    std.debug.print(" env_reads={d}\n", .{global_fields.env_reads});
    std.debug.print("AOT_ORIGINS {any}\n", .{origins});
    std.debug.print("AOT_UNGUARDED_CALL_ORIGINS {any}\n", .{unguarded_call_origins});
    std.debug.print("AOT_UNGUARDED_CALL_FIELD_OBJECT_ORIGINS {any}\n", .{unguarded_call_field_object_origins});
    std.debug.print("AOT_UNGUARDED_CALL_FIELDS anonymous_slots={d}", .{unguarded_call_field_names.anonymous_slots});
    var unguarded_call_field_it = unguarded_call_field_names.counts.iterator();
    while (unguarded_call_field_it.next()) |entry| std.debug.print(" {s}={d}", .{ entry.key_ptr.*, entry.value_ptr.* });
    std.debug.print("\n", .{});
    std.debug.print("AOT_UPVALUE_ORIGINS {any}\n", .{upvalue_origins});
    std.debug.print("AOT_UNGUARDED_UPVALUE_CALL_ORIGINS {any}\n", .{unguarded_upvalue_call_origins});
}
