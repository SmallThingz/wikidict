const std = @import("std");
const rt = @import("zig_runtime");
const stdlib = @import("zig_stdlib");
const scribunto = @import("zig_scribunto");
const globals_abi = @import("lua_globals");
const metadata = @import("lua_program_metadata");
const static_decode = @import("lua_static_literal_decode");

pub const Context = rt.Context;

extern fn dict_lua_program_module_roots() callconv(.c) *const anyopaque;
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

pub const Program = struct {
    allocator: std.mem.Allocator,
    mapped: Mapped,
    module_count: u32,
    module_lookup_count: u32,
    module_names: [][]const u8,
    module_lookup_names: [][]const u8,
    module_lookup_ids: []u32,
    module_export_shape_ids: []u32,
    module_function_bases: []u32,
    module_function_counts: []u32,
    module_requirement_offsets: []u32,
    module_requirements: []rt.ModuleRequirement,
    module_static_root_blobs: [][]const u8,
    module_static_root_load_data: []bool,
    global_keys: []rt.Value,
    global_shape: rt.Shape,
    shapes: []rt.Shape,
    shape_keys: []rt.Value,
    shape_sorted_slots: []u32,
    stdlib_template: stdlib.Template,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
    ) !Program {
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
        const item_bound: u64 = mapped.bytes.len / 4 + 1;
        if (@as(u64, module_count) > item_bound or
            @as(u64, module_lookup_count) > item_bound or
            @as(u64, global_count) > item_bound or
            @as(u64, shape_count) > item_bound or
            @as(u64, shape_field_total) > item_bound or
            @as(u64, module_requirement_total) > item_bound)
            return error.InvalidProgramMetadata;
        if (global_count < globals_abi.count) return error.BadGlobalLayout;

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

        const module_function_bases = try allocator.alloc(u32, module_count);
        errdefer allocator.free(module_function_bases);
        const module_function_counts = try allocator.alloc(u32, module_count);
        errdefer allocator.free(module_function_counts);
        var previous_end: u64 = 0;
        for (module_function_bases, module_function_counts, 0..) |*base, *count, index| {
            base.* = try reader.readU32();
            count.* = try reader.readU32();
            const end = @as(u64, base.*) + count.*;
            if (index != 0 and @as(u64, base.*) < previous_end)
                return error.InvalidProgramMetadata;
            previous_end = end;
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
        for (module_static_root_blobs, module_static_root_load_data) |*blob, *snapshot| {
            const flags = try reader.readU32();
            if (flags > 1) return error.InvalidProgramMetadata;
            snapshot.* = flags != 0;
            blob.* = try reader.readString();
        }

        const global_keys = try allocator.alloc(rt.Value, global_count);
        errdefer allocator.free(global_keys);
        for (global_keys) |*key|
            key.* = .{ .string = try reader.readString() };

        const program_shapes = try allocator.alloc(rt.Shape, shape_count);
        errdefer allocator.free(program_shapes);
        const shape_keys = try allocator.alloc(rt.Value, shape_field_total);
        errdefer allocator.free(shape_keys);
        const shape_sorted_slots = try allocator.alloc(u32, shape_field_total);
        errdefer allocator.free(shape_sorted_slots);

        var shape_offset: usize = 0;
        for (program_shapes) |*shape| {
            const field_count_u32 = try reader.readU32();
            const field_count: usize = @intCast(field_count_u32);
            if (field_count > shape_keys.len -| shape_offset)
                return error.InvalidProgramMetadata;

            const keys = shape_keys[shape_offset .. shape_offset + field_count];
            const sorted_slots = shape_sorted_slots[shape_offset .. shape_offset + field_count];
            for (keys) |*key|
                key.* = .{ .string = try reader.readString() };
            for (sorted_slots) |*slot| {
                slot.* = try reader.readU32();
                if (slot.* >= field_count_u32) return error.InvalidProgramMetadata;
            }
            shape.* = .{
                .field_keys = keys,
                .sorted_string_slots = sorted_slots,
                .field_count = field_count_u32,
                .open = true,
            };
            shape_offset += field_count;
        }
        if (shape_offset != shape_field_total) return error.InvalidProgramMetadata;
        try reader.finish();

        var stdlib_template = try stdlib.Template.init();
        errdefer stdlib_template.deinit();

        return .{
            .allocator = allocator,
            .mapped = mapped,
            .module_count = module_count,
            .module_lookup_count = module_lookup_count,
            .module_names = module_names,
            .module_lookup_names = module_lookup_names,
            .module_lookup_ids = module_lookup_ids,
            .module_export_shape_ids = module_export_shape_ids,
            .module_function_bases = module_function_bases,
            .module_function_counts = module_function_counts,
            .module_requirement_offsets = module_requirement_offsets,
            .module_requirements = module_requirements,
            .module_static_root_blobs = module_static_root_blobs,
            .module_static_root_load_data = module_static_root_load_data,
            .global_keys = global_keys,
            .global_shape = .{
                .field_keys = global_keys,
                .field_count = global_count,
                .open = true,
            },
            .shapes = program_shapes,
            .shape_keys = shape_keys,
            .shape_sorted_slots = shape_sorted_slots,
            .stdlib_template = stdlib_template,
        };
    }

    pub fn deinit(self: *Program) void {
        self.stdlib_template.deinit();
        self.allocator.free(self.shape_sorted_slots);
        self.allocator.free(self.shape_keys);
        self.allocator.free(self.shapes);
        self.allocator.free(self.global_keys);
        self.allocator.free(self.module_static_root_load_data);
        self.allocator.free(self.module_static_root_blobs);
        self.allocator.free(self.module_requirements);
        self.allocator.free(self.module_requirement_offsets);
        self.allocator.free(self.module_function_counts);
        self.allocator.free(self.module_function_bases);
        self.allocator.free(self.module_export_shape_ids);
        self.allocator.free(self.module_lookup_ids);
        self.allocator.free(self.module_lookup_names);
        self.allocator.free(self.module_names);
        self.mapped.deinit();
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
        if (self.lookupExact(raw_name)) |id| return id;
        const colon = std.mem.indexOfScalar(u8, raw_name, ':') orelse return null;
        const prefix_raw = raw_name[0..colon];
        if (!std.ascii.eqlIgnoreCase(prefix_raw, "Module") and
            !std.ascii.eqlIgnoreCase(prefix_raw, "MOD")) return null;
        const suffix = raw_name[colon + 1 ..];
        var buffer: [4096]u8 = undefined;
        const prefix = "Module:";
        if (prefix.len + suffix.len > buffer.len) return null;
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[prefix.len .. prefix.len + suffix.len], suffix);
        return self.lookupExact(buffer[0 .. prefix.len + suffix.len]);
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
        if (blob.len == 0) return null;
        return try static_decode.decode(ctx, blob);
    }

    pub fn initContext(self: *Program, allocator: std.mem.Allocator) !rt.Context {
        var ctx = try rt.Context.initProgram(
            allocator,
            self.global_keys.len,
            self.module_count,
        );
        errdefer ctx.deinit();
        const roots: [*]const rt.FunctionFn = @ptrCast(
            @alignCast(dict_lua_program_module_roots()),
        );
        ctx.module_root_entries = roots[0..self.module_count];
        ctx.module_export_shape_ids = self.module_export_shape_ids;
        ctx.program_shapes = self.shapes;
        ctx.configureModules(self, lookup, moduleName);
        ctx.configureModuleFunctions(self.module_function_bases, self.module_function_counts);
        ctx.configureModuleRequirements(self, moduleRequirements);
        ctx.configureStaticModules(self, staticModule);
        ctx.configureProgramBootstrap(
            &self.stdlib_template,
            stdlib.Template.bootstrapOpaque,
        );
        try rt.bindGlobalTable(&ctx, &self.global_shape, globals_abi.id("_G"));
        _ = try ctx.bootstrapProgram();
        for (self.module_static_root_blobs, self.module_static_root_load_data, 0..) |blob, snapshot, module_id| {
            if (blob.len == 0) continue;
            var value = try static_decode.decode(&ctx, blob);
            if (value == .nil) value = .{ .boolean = true };
            try ctx.preinitializeModule(@intCast(module_id), value, snapshot);
        }
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
