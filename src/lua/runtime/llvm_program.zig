const std = @import("std");
const rt = @import("zig_runtime");
const stdlib = @import("zig_stdlib");
const scribunto = @import("zig_scribunto");
const globals_abi = @import("lua_globals");
const metadata = @import("lua_program_metadata");
const static_decode = @import("lua_static_literal_decode");
const global_shape_index = @import("global_shape_index.zig");
const program_shapes_storage = @import("program_shapes.zig");

pub const Context = rt.Context;
pub const namespace_registry = rt.namespace_registry;
pub const RequestAllocator = rt.RequestAllocator;
pub const RequestPool = rt.RequestPool;
pub const work_stats = rt.work_stats;
pub const moduleTemplateAllocationFailed = rt.moduleTemplateAllocationFailed;

// A generation survives every page/context fork and never aliases a later
// Program load. Exhaustion disables cross-instance shape caching.
var next_program_shape_generation = std.atomic.Value(u64).init(1);
fn takeProgramShapeGeneration() u64 {
    while (true) {
        const current = next_program_shape_generation.load(.monotonic);
        if (current == std.math.maxInt(u64)) return 0;
        if (next_program_shape_generation.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null)
            return current;
    }
}

extern fn dict_lua_program_module_roots() callconv(.c) *const anyopaque;
extern fn dict_lua_program_synth_export_entries() callconv(.c) ?*const anyopaque;
extern fn dict_lua_program_eager_init(ctx: *rt.Context) callconv(.c) u32;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
        self.* = undefined;
    }
};

fn mapMetadata(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Mapped {
    const path = try std.fs.path.join(allocator, &.{ root, "lua-program.meta" });
    defer allocator.free(path);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.ProgramMetadataTooLarge;
    if (len == 0) return error.InvalidProgramMetadata;
    return .{
        .bytes = try std.posix.mmap(
            null,
            len,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ),
    };
}

const SynthExport = struct {
    name: []const u8,
    function_id: u32,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    namespace_catalog: *rt.namespace_registry.Registry,
    mapped: Mapped,
    shape_generation: u64,
    module_count: u32,
    module_lookup_count: u32,
    module_names: [][]const u8,
    module_lookup_names: [][]const u8,
    module_lookup_ids: []u32,
    module_export_shape_ids: []u32,
    function_module_ids: []u32,
    module_requirement_offsets: []u32,
    module_requirements: []rt.ModuleRequirement,
    module_static_root_blobs: [][]const u8,
    module_static_root_load_data: []bool,
    module_template_eligible: []bool,
    module_template_rejected: []bool,
    module_synth_roots: []bool,
    module_synth_offsets: []u32,
    synth_exports: []SynthExport,
    synth_export_entries: []const rt.FunctionFn,
    global_keys: []rt.Value,
    global_sorted_slots: []u32,
    global_shape: rt.Shape,
    shapes: []rt.Shape,
    shape_keys: []rt.Value,
    shape_string_keys: [][]const u8,
    shape_sorted_slots: []u32,
    shape_string_indices: []u32,
    frame_args_shape_id: ?u32,
    package_loaded_module_slots: []u32,
    package_loaded_slot_modules: []u32,
    package_loaded_shape_id: ?u32,
    json_object_shape_id: ?u32,
    uri_query_shape_id: ?u32,
    stdlib_template: stdlib.Template,
    template_arena: ?*std.heap.ArenaAllocator = null,
    template_context: ?*rt.Context = null,
    pattern_cache: ?*scribunto.PatternCache = null,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
    ) !Program {
        const namespace_catalog = try allocator.create(rt.namespace_registry.Registry);
        errdefer allocator.destroy(namespace_catalog);
        namespace_catalog.* = try rt.namespace_registry.Registry.load(io, allocator, root);
        errdefer namespace_catalog.deinit();
        var mapped = try mapMetadata(io, allocator, root);
        errdefer mapped.deinit();

        var reader = metadata.Reader{ .bytes = mapped.bytes };
        try reader.expectMagic();
        const module_count = try reader.readU32();
        const module_lookup_count = try reader.readU32();
        const global_count = try reader.readU32();
        const shape_count = try reader.readU32();
        const shape_field_total = try reader.readU32();
        const module_requirement_total = try reader.readU32();
        const synth_export_total = try reader.readU32();
        const frame_args_shape_raw = try reader.readU32();
        const package_loaded_shape_raw = try reader.readU32();
        const json_object_shape_raw = try reader.readU32();
        const uri_query_shape_raw = try reader.readU32();
        const item_bound: u64 = mapped.bytes.len / 4 + 1;
        if (@as(u64, module_count) > item_bound or
            @as(u64, module_lookup_count) > item_bound or
            @as(u64, global_count) > item_bound or
            @as(u64, shape_count) > item_bound or
            @as(u64, shape_field_total) > item_bound or
            @as(u64, module_requirement_total) > item_bound or
            @as(u64, synth_export_total) > item_bound)
            return error.InvalidProgramMetadata;
        if (global_count < globals_abi.count) return error.BadGlobalLayout;
        const frame_args_shape_id = if (frame_args_shape_raw == std.math.maxInt(u32))
            null
        else if (frame_args_shape_raw < shape_count)
            frame_args_shape_raw
        else
            return error.InvalidProgramMetadata;
        const package_loaded_shape_id = if (package_loaded_shape_raw == std.math.maxInt(u32))
            null
        else if (package_loaded_shape_raw < shape_count)
            package_loaded_shape_raw
        else
            return error.InvalidProgramMetadata;
        const json_object_shape_id = if (json_object_shape_raw == std.math.maxInt(u32))
            null
        else if (json_object_shape_raw < shape_count)
            json_object_shape_raw
        else
            return error.InvalidProgramMetadata;
        const uri_query_shape_id = if (uri_query_shape_raw == std.math.maxInt(u32))
            null
        else if (uri_query_shape_raw < shape_count)
            uri_query_shape_raw
        else
            return error.InvalidProgramMetadata;

        const module_names = try allocator.alloc([]const u8, module_count);
        errdefer allocator.free(module_names);
        for (module_names) |*name| name.* = try reader.readString();

        const module_lookup_names = try allocator.alloc([]const u8, module_lookup_count);
        errdefer allocator.free(module_lookup_names);
        const module_lookup_ids = try allocator.alloc(u32, module_lookup_count);
        errdefer allocator.free(module_lookup_ids);
        for (module_lookup_names, module_lookup_ids, 0..) |*name, *id, index| {
            name.* = try reader.readString();
            id.* = try reader.readU32();
            if (id.* >= module_count) return error.InvalidProgramMetadata;
            if (index != 0 and
                std.mem.order(u8, module_lookup_names[index - 1], name.*) != .lt)
                return error.InvalidProgramMetadata;
        }

        const module_export_shape_ids = try allocator.alloc(u32, module_count);
        errdefer allocator.free(module_export_shape_ids);
        for (module_export_shape_ids) |*shape_id| {
            shape_id.* = try reader.readU32();
            if (shape_id.* != std.math.maxInt(u32) and shape_id.* >= shape_count)
                return error.InvalidProgramMetadata;
        }

        const FunctionRange = struct { base: u32, count: u32 };
        const function_ranges = try allocator.alloc(FunctionRange, module_count);
        defer allocator.free(function_ranges);
        var previous_end: u64 = 0;
        for (function_ranges, 0..) |*range, index| {
            range.base = try reader.readU32();
            range.count = try reader.readU32();
            const end = @as(u64, range.base) + range.count;
            if (end > std.math.maxInt(u32) or
                (index != 0 and @as(u64, range.base) < previous_end))
                return error.InvalidProgramMetadata;
            previous_end = end;
        }
        const function_count = std.math.cast(usize, previous_end) orelse
            return error.ProgramMetadataTooLarge;
        const function_module_ids = try allocator.alloc(u32, function_count);
        errdefer allocator.free(function_module_ids);
        @memset(function_module_ids, std.math.maxInt(u32));
        for (function_ranges, 0..) |range, module_id| {
            const start: usize = range.base;
            const end: usize = start + range.count;
            if (end > function_module_ids.len) return error.InvalidProgramMetadata;
            @memset(function_module_ids[start..end], @intCast(module_id));
        }

        const module_requirement_offsets = try allocator.alloc(u32, @as(usize, module_count) + 1);
        errdefer allocator.free(module_requirement_offsets);
        const module_requirements = try allocator.alloc(rt.ModuleRequirement, module_requirement_total);
        errdefer allocator.free(module_requirements);
        var requirement_at: usize = 0;
        for (0..module_count) |module_index| {
            module_requirement_offsets[module_index] = @intCast(requirement_at);
            const count: usize = @intCast(try reader.readU32());
            if (count > module_requirements.len -| requirement_at)
                return error.InvalidProgramMetadata;
            for (module_requirements[requirement_at .. requirement_at + count]) |*requirement| {
                requirement.module_id = try reader.readU32();
                if (requirement.module_id >= module_count)
                    return error.InvalidProgramMetadata;
                requirement.requested = try reader.readString();
            }
            requirement_at += count;
        }
        if (requirement_at != module_requirements.len)
            return error.InvalidProgramMetadata;
        module_requirement_offsets[module_count] = @intCast(requirement_at);

        const module_static_root_blobs = try allocator.alloc([]const u8, module_count);
        errdefer allocator.free(module_static_root_blobs);
        const module_static_root_load_data = try allocator.alloc(bool, module_count);
        errdefer allocator.free(module_static_root_load_data);
        const module_template_eligible = try allocator.alloc(bool, module_count);
        errdefer allocator.free(module_template_eligible);
        const module_template_rejected = try allocator.alloc(bool, module_count);
        errdefer allocator.free(module_template_rejected);
        @memset(module_template_rejected, false);
        for (module_static_root_blobs, module_static_root_load_data, module_template_eligible) |*blob, *snapshot, *template| {
            const flags = try reader.readU32();
            if (flags > 3) return error.InvalidProgramMetadata;
            snapshot.* = flags & 1 != 0;
            template.* = flags & 2 != 0;
            blob.* = try reader.readString();
        }

        const module_synth_roots = try allocator.alloc(bool, module_count);
        errdefer allocator.free(module_synth_roots);
        const module_synth_offsets = try allocator.alloc(u32, @as(usize, module_count) + 1);
        errdefer allocator.free(module_synth_offsets);
        const synth_exports = try allocator.alloc(SynthExport, synth_export_total);
        errdefer allocator.free(synth_exports);
        var synth_at: usize = 0;
        for (0..module_count) |module_index| {
            module_synth_offsets[module_index] = @intCast(synth_at);
            const flag = try reader.readU32();
            if (flag > 1) return error.InvalidProgramMetadata;
            module_synth_roots[module_index] = flag != 0;
            const count: usize = @intCast(try reader.readU32());
            if ((!module_synth_roots[module_index] and count != 0) or
                count > synth_exports.len -| synth_at)
                return error.InvalidProgramMetadata;
            for (synth_exports[synth_at .. synth_at + count]) |*entry| {
                entry.name = try reader.readString();
                entry.function_id = try reader.readU32();
            }
            synth_at += count;
        }
        if (synth_at != synth_exports.len) return error.InvalidProgramMetadata;
        module_synth_offsets[module_count] = @intCast(synth_at);
        const synth_export_entries: []const rt.FunctionFn = if (synth_exports.len == 0)
            &.{}
        else blk: {
            const raw = dict_lua_program_synth_export_entries() orelse return error.MissingSyntheticExportEntries;
            const ptr: [*]const rt.FunctionFn = @ptrCast(@alignCast(raw));
            break :blk ptr[0..synth_exports.len];
        };

        const global_keys = try allocator.alloc(rt.Value, global_count);
        errdefer allocator.free(global_keys);
        for (global_keys) |*key|
            key.* = .{ .string = try reader.readString() };
        const global_sorted_slots = try global_shape_index.build(allocator, global_keys);
        errdefer allocator.free(global_sorted_slots);

        const shape_storage = try program_shapes_storage.load(allocator, &reader, shape_count, shape_field_total);
        errdefer shape_storage.deinit(allocator);
        const program_shapes = shape_storage.shapes;
        const shape_keys = shape_storage.boxed;
        const shape_sorted_slots = shape_storage.sorted;

        const shape_string_indices = try rt.buildShapeStringIndices(allocator, program_shapes);
        errdefer allocator.free(shape_string_indices);

        const package_loaded_module_slots = try allocator.alloc(u32, module_count);
        errdefer allocator.free(package_loaded_module_slots);
        @memset(package_loaded_module_slots, std.math.maxInt(u32));
        if (package_loaded_shape_id) |shape_id| {
            const package_shape = &program_shapes[shape_id];
            for (module_names, package_loaded_module_slots) |name, *slot|
                slot.* = rt.shapeStringSlot(package_shape, name) orelse std.math.maxInt(u32);
        }
        const package_loaded_slot_modules = try allocator.alloc(u32, if (package_loaded_shape_id) |id|
            program_shapes[id].field_count
        else
            0);
        errdefer allocator.free(package_loaded_slot_modules);
        @memset(package_loaded_slot_modules, std.math.maxInt(u32));
        // Bind only canonical names to the exact module selected by the
        // authoritative lookup index. Redirect aliases retain their ordinary
        // resolution and independently observable package.loaded keys.
        for (module_lookup_names, module_lookup_ids) |name, id| {
            if (!std.mem.eql(u8, name, module_names[id])) continue;
            const slot = package_loaded_module_slots[id];
            if (slot < package_loaded_slot_modules.len)
                package_loaded_slot_modules[slot] = id;
        }

        var stdlib_template = try stdlib.Template.init();
        errdefer stdlib_template.deinit();

        return .{
            .allocator = allocator,
            .namespace_catalog = namespace_catalog,
            .mapped = mapped,
            .shape_generation = takeProgramShapeGeneration(),
            .module_count = module_count,
            .module_lookup_count = module_lookup_count,
            .module_names = module_names,
            .module_lookup_names = module_lookup_names,
            .module_lookup_ids = module_lookup_ids,
            .module_export_shape_ids = module_export_shape_ids,
            .function_module_ids = function_module_ids,
            .module_requirement_offsets = module_requirement_offsets,
            .module_requirements = module_requirements,
            .module_static_root_blobs = module_static_root_blobs,
            .module_static_root_load_data = module_static_root_load_data,
            .module_template_eligible = module_template_eligible,
            .module_template_rejected = module_template_rejected,
            .module_synth_roots = module_synth_roots,
            .module_synth_offsets = module_synth_offsets,
            .synth_exports = synth_exports,
            .synth_export_entries = synth_export_entries,
            .global_keys = global_keys,
            .global_sorted_slots = global_sorted_slots,
            .global_shape = .{
                .keys = .{ .boxed = global_keys },
                .sorted_string_slots = global_sorted_slots,
                .field_count = global_count,
                .open = true,
                .all_string_keys = true,
            },
            .shapes = program_shapes,
            .shape_keys = shape_keys,
            .shape_string_keys = shape_storage.strings,
            .shape_sorted_slots = shape_sorted_slots,
            .shape_string_indices = shape_string_indices,
            .frame_args_shape_id = frame_args_shape_id,
            .package_loaded_module_slots = package_loaded_module_slots,
            .package_loaded_slot_modules = package_loaded_slot_modules,
            .package_loaded_shape_id = package_loaded_shape_id,
            .json_object_shape_id = json_object_shape_id,
            .uri_query_shape_id = uri_query_shape_id,
            .stdlib_template = stdlib_template,
            // Stable independent storage: Program may move, and its allocator
            // may be an arena that cannot reclaim rejected cache admissions.
            .pattern_cache = scribunto.PatternCache.create(io, std.heap.smp_allocator) catch null,
        };
    }

    pub fn deinit(self: *Program) void {
        if (self.template_context) |ctx| {
            ctx.deinit();
            self.template_arena.?.deinit();
            self.allocator.destroy(self.template_context.?);
            self.allocator.destroy(self.template_arena.?);
        }
        self.stdlib_template.deinit();
        if (self.pattern_cache) |cache| {
            cache.logDiagnostics();
            cache.destroy();
        }
        self.allocator.free(self.shape_string_indices);
        self.allocator.free(self.shape_sorted_slots);
        self.allocator.free(self.shape_keys);
        self.allocator.free(self.shape_string_keys);
        self.allocator.free(self.shapes);
        self.allocator.free(self.package_loaded_module_slots);
        self.allocator.free(self.package_loaded_slot_modules);
        self.allocator.free(self.global_sorted_slots);
        self.allocator.free(self.global_keys);
        self.allocator.free(self.synth_exports);
        self.allocator.free(self.module_synth_offsets);
        self.allocator.free(self.module_synth_roots);
        self.allocator.free(self.module_static_root_load_data);
        self.allocator.free(self.module_static_root_blobs);
        self.allocator.free(self.module_template_rejected);
        self.allocator.free(self.module_template_eligible);
        self.allocator.free(self.module_requirements);
        self.allocator.free(self.module_requirement_offsets);
        self.allocator.free(self.function_module_ids);
        self.allocator.free(self.module_export_shape_ids);
        self.allocator.free(self.module_lookup_ids);
        self.allocator.free(self.module_lookup_names);
        self.allocator.free(self.module_names);
        self.mapped.deinit();
        self.namespace_catalog.deinit();
        self.allocator.destroy(self.namespace_catalog);
        self.* = undefined;
    }

    inline fn lookupName(self: *const Program, index: u32) []const u8 {
        return self.module_lookup_names[index];
    }

    fn lookupExact(self: *const Program, name: []const u8) ?u32 {
        var low: u32 = 0;
        var high = self.module_lookup_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, name, self.lookupName(mid))) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return self.module_lookup_ids[mid],
            }
        }
        return null;
    }

    fn lookup(raw: ?*const anyopaque, raw_name: []const u8) ?u32 {
        const self: *const Program = @ptrCast(@alignCast(raw orelse return null));
        return self.lookupExact(raw_name);
    }

    fn moduleName(raw: ?*const anyopaque, id: u32) ?[]const u8 {
        const self: *const Program = @ptrCast(@alignCast(raw orelse return null));
        return if (id < self.module_count) self.module_names[id] else null;
    }

    fn moduleRequirements(raw: ?*const anyopaque, id: u32) []const rt.ModuleRequirement {
        const self: *const Program = @ptrCast(@alignCast(raw orelse return &.{}));
        if (id >= self.module_count) return &.{};
        const start: usize = self.module_requirement_offsets[id];
        const end: usize = self.module_requirement_offsets[id + 1];
        return self.module_requirements[start..end];
    }

    fn staticModule(raw: ?*const anyopaque, ctx: *rt.Context, id: u32) anyerror!?rt.Value {
        const self: *const Program = @ptrCast(@alignCast(raw orelse return null));
        if (id >= self.module_count) return null;
        const blob = self.module_static_root_blobs[id];
        if (!self.module_synth_roots[id]) {
            if (blob.len != 0) {
                if (work_stats.current()) |work| work.static_roots +|= 1;
                return try static_decode.decode(ctx, blob);
            }
            return null;
        }

        if (work_stats.current()) |work| work.static_roots +|= 1;

        const start: usize = self.module_synth_offsets[id];
        const end: usize = self.module_synth_offsets[id + 1];
        if (blob.len != 0 and blob[0] == static_decode.synth_callable_marker) {
            if (end - start != 1) return error.InvalidSyntheticCallableRoot;
            const meta = self.synth_exports[start];
            if (meta.name.len != 0) return error.InvalidSyntheticCallableRoot;
            const captures_value = try static_decode.decode(ctx, blob[1..]);
            if (captures_value != .table) return error.InvalidSyntheticCallableCaptures;
            const capture_table = captures_value.table;
            defer ctx.destroyTable(capture_table);
            if (capture_table.shape != null or capture_table.native_namespace != null or
                capture_table.append_index == 0)
                return error.InvalidSyntheticCallableCaptures;
            const capture_count: usize = capture_table.append_index - 1;
            if (capture_count > capture_table.slots.len) return error.InvalidSyntheticCallableCaptures;
            const cells = try ctx.allocator.alloc(*rt.Cell, capture_count);
            defer ctx.allocator.free(cells);
            for (cells, 0..) |*cell_out, capture_index| {
                cell_out.* = try ctx.newCell(capture_table.slots[capture_index]);
            }
            return try ctx.makeFunction(
                meta.function_id,
                self.synth_export_entries[start],
                cells,
            );
        }

        const table = if (blob.len != 0) blk: {
            const seed = try static_decode.decode(ctx, blob);
            if (seed != .table) return error.InvalidSyntheticRootSeed;
            break :blk seed.table;
        } else blk: {
            const shape_id = self.module_export_shape_ids[id];
            break :blk if (shape_id == std.math.maxInt(u32))
                try ctx.newTable()
            else
                try ctx.newProgramShape(shape_id);
        };
        for (self.synth_exports[start..end], self.synth_export_entries[start..end]) |meta, entry| {
            const callable = try ctx.makeFunction(meta.function_id, entry, &.{});
            try table.rawSet(ctx.allocator, .{ .string = meta.name }, callable);
        }
        return .{ .table = table };
    }

    fn initContextBase(self: *Program, allocator: std.mem.Allocator, bulk_owned_strings: bool) !rt.Context {
        var ctx = try rt.Context.initProgram(
            allocator,
            self.global_keys.len,
            self.module_count,
        );
        errdefer ctx.deinit();
        if (bulk_owned_strings) ctx.useContextAllocatorForStrings();
        const roots: [*]const rt.FunctionFn = @ptrCast(
            @alignCast(dict_lua_program_module_roots()),
        );
        ctx.namespace_catalog = self.namespace_catalog;
        ctx.ustring_pattern_cache = if (self.pattern_cache) |cache| @ptrCast(cache) else null;
        ctx.module_root_entries = roots[0..self.module_count];
        ctx.module_export_shape_ids = self.module_export_shape_ids;
        ctx.module_template_eligible = self.module_template_eligible;
        ctx.module_template_rejected = self.module_template_rejected;
        ctx.program_shapes = self.shapes;
        ctx.program_shapes_validated = true;
        ctx.program_shape_generation = self.shape_generation;
        ctx.frame_args_shape_id = self.frame_args_shape_id;
        ctx.package_loaded_module_slots = self.package_loaded_module_slots;
        ctx.package_loaded_slot_modules = self.package_loaded_slot_modules;
        ctx.package_loaded_shape_id = self.package_loaded_shape_id;
        ctx.json_object_shape_id = self.json_object_shape_id;
        ctx.uri_query_shape_id = self.uri_query_shape_id;
        ctx.configureModules(self, lookup, moduleName);
        ctx.configureFunctionModules(self.function_module_ids);
        ctx.configureModuleRequirements(self, moduleRequirements);
        ctx.configureStaticModules(self, staticModule);
        ctx.configureProgramBootstrap(
            &self.stdlib_template,
            stdlib.Template.bootstrapOpaque,
        );
        try rt.bindGlobalTable(&ctx, &self.global_shape, globals_abi.id("_G"));
        _ = try ctx.bootstrapProgram();
        return ctx;
    }

    fn ensureTemplateContext(self: *Program) !*rt.Context {
        if (self.template_context) |ctx| return ctx;
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        // Keep mutable process-cache growth out of the asset arena: nesting
        // geometric arenas reserves far more virtual space than live graphs.
        arena.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        errdefer arena.deinit();
        const ctx = try self.allocator.create(rt.Context);
        errdefer self.allocator.destroy(ctx);
        ctx.* = try self.initContextBase(arena.allocator(), true);
        errdefer ctx.deinit();
        // A template root runs compiled Lua with the same builtin surface as
        // its page child. Host observations still have no worker-page owner.
        try scribunto.install(ctx, globals_abi.id("_G"), globals_abi.id("string"), globals_abi.id("mw"));
        self.template_arena = arena;
        self.template_context = ctx;
        return ctx;
    }

    pub fn initPageContext(self: *Program, allocator: std.mem.Allocator) !rt.Context {
        const template = try self.ensureTemplateContext();
        var ctx = try template.forkProgram(allocator);
        errdefer ctx.deinit();
        try rt.bindGlobalTable(&ctx, &self.global_shape, globals_abi.id("_G"));
        _ = try ctx.bootstrapProgram();
        ctx.module_template_context = template;
        ctx.module_template_eligible = self.module_template_eligible;
        ctx.module_template_rejected = self.module_template_rejected;
        return ctx;
    }

    pub fn initContext(self: *Program, allocator: std.mem.Allocator) !rt.Context {
        var ctx = try self.initContextBase(allocator, false);
        errdefer ctx.deinit();
        ctx.beginEagerBootstrap();
        const eager_status = dict_lua_program_eager_init(&ctx);
        ctx.endEagerBootstrap();
        if (eager_status != 0) return error.ProgramEagerInitFailed;
        return ctx;
    }
};

pub const Host = scribunto.Host;
pub const FrameArg = scribunto.FrameArg;
pub const WikitextProvider = scribunto.WikitextProvider;
pub const WikitextExpander = scribunto.WikitextExpander;
pub const SharedLoadDataCache = scribunto.SharedLoadDataCache;
pub const InvokeReuseStats = scribunto.InvokeReuseStats;

pub fn loadDataCacheability(program: *const Program) []const bool {
    return program.module_static_root_load_data;
}

pub fn initExpander(
    ctx: *rt.Context,
    provider: WikitextProvider,
) WikitextExpander {
    return scribunto.makeWikitextExpander(
        ctx,
        globals_abi.id("_G"),
        globals_abi.id("string"),
        globals_abi.id("mw"),
        provider,
    );
}

pub fn initExpanderShared(
    ctx: *rt.Context,
    provider: WikitextProvider,
    shared: *SharedLoadDataCache,
) WikitextExpander {
    return scribunto.makeWikitextExpanderShared(
        ctx,
        globals_abi.id("_G"),
        globals_abi.id("string"),
        globals_abi.id("mw"),
        provider,
        shared,
    );
}
