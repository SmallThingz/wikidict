const std = @import("std");
const rt = @import("zig_runtime");
const stdlib = @import("zig_stdlib");
const scribunto = @import("zig_scribunto");
const globals_abi = @import("lua_globals");

pub const Context = rt.Context;

extern fn dict_lua_program_module_count() callconv(.c) u32;
extern fn dict_lua_program_global_count() callconv(.c) u32;
extern fn dict_lua_program_shape_count() callconv(.c) u32;
extern fn dict_lua_program_shape_field_total() callconv(.c) u32;
extern fn dict_lua_program_module_roots() callconv(.c) *const anyopaque;
extern fn dict_lua_program_module_export_shape_ids() callconv(.c) *const anyopaque;
extern fn dict_lua_program_module_name(id: u32) callconv(.c) [*]const u8;
extern fn dict_lua_program_module_name_len(id: u32) callconv(.c) usize;
extern fn dict_lua_program_module_lookup_count() callconv(.c) u32;
extern fn dict_lua_program_module_lookup_name(index: u32) callconv(.c) [*]const u8;
extern fn dict_lua_program_module_lookup_name_len(index: u32) callconv(.c) usize;
extern fn dict_lua_program_module_lookup_id(index: u32) callconv(.c) u32;
extern fn dict_lua_program_global_name(id: u32) callconv(.c) [*]const u8;
extern fn dict_lua_program_global_name_len(id: u32) callconv(.c) usize;
extern fn dict_lua_program_shape_field_count(id: u32) callconv(.c) u32;
extern fn dict_lua_program_shape_sorted_slot(id: u32, rank: u32) callconv(.c) u32;
extern fn dict_lua_program_shape_field_name(id: u32, field: u32) callconv(.c) [*]const u8;
extern fn dict_lua_program_shape_field_name_len(id: u32, field: u32) callconv(.c) usize;

pub const Program = struct {
    allocator: std.mem.Allocator,
    module_count: u32,
    module_lookup_count: u32,
    global_keys: []rt.Value,
    global_shape: rt.Shape,
    shapes: []rt.Shape,
    shape_keys: []rt.Value,
    shape_sorted_slots: []u32,
    stdlib_template: stdlib.Template,

    pub fn init(allocator: std.mem.Allocator) !Program {
        const module_count = dict_lua_program_module_count();
        const module_lookup_count = dict_lua_program_module_lookup_count();
        const global_count = dict_lua_program_global_count();
        if (global_count < globals_abi.count) return error.BadGlobalLayout;
        const global_keys = try allocator.alloc(rt.Value, global_count);
        errdefer allocator.free(global_keys);
        const shape_count: usize = @intCast(dict_lua_program_shape_count());
        const shape_field_total: usize = @intCast(dict_lua_program_shape_field_total());
        const program_shapes = try allocator.alloc(rt.Shape, shape_count);
        errdefer allocator.free(program_shapes);
        const shape_keys = try allocator.alloc(rt.Value, shape_field_total);
        errdefer allocator.free(shape_keys);
        const shape_sorted_slots = try allocator.alloc(u32, shape_field_total);
        errdefer allocator.free(shape_sorted_slots);
        var stdlib_template = try stdlib.Template.init();
        errdefer stdlib_template.deinit();

        var self = Program{
            .allocator = allocator,
            .module_count = module_count,
            .module_lookup_count = module_lookup_count,
            .global_keys = global_keys,
            .global_shape = .{},
            .shapes = program_shapes,
            .shape_keys = shape_keys,
            .shape_sorted_slots = shape_sorted_slots,
            .stdlib_template = stdlib_template,
        };
        for (0..global_count) |index| {
            const id: u32 = @intCast(index);
            const name = dict_lua_program_global_name(id)[0..dict_lua_program_global_name_len(id)];
            self.global_keys[index] = .{ .string = name };
        }
        self.global_shape = .{
            .field_keys = self.global_keys,
            .field_count = global_count,
            .open = true,
        };
        var shape_offset: usize = 0;
        for (0..shape_count) |shape_index| {
            const shape_id: u32 = @intCast(shape_index);
            const field_count: usize = @intCast(dict_lua_program_shape_field_count(shape_id));
            const keys = self.shape_keys[shape_offset .. shape_offset + field_count];
            const sorted_slots = self.shape_sorted_slots[shape_offset .. shape_offset + field_count];
            for (keys, 0..) |*key, field_index| {
                const field_id: u32 = @intCast(field_index);
                const ptr = dict_lua_program_shape_field_name(shape_id, field_id);
                key.* = .{ .string = ptr[0..dict_lua_program_shape_field_name_len(shape_id, field_id)] };
                sorted_slots[field_index] = dict_lua_program_shape_sorted_slot(shape_id, field_id);
            }
            self.shapes[shape_index] = .{ .field_keys = keys, .sorted_string_slots = sorted_slots, .field_count = @intCast(field_count), .open = true };
            shape_offset += field_count;
        }
        if (shape_offset != shape_field_total) return error.BadShapeLayout;
        return self;
    }

    pub fn deinit(self: *Program) void {
        self.stdlib_template.deinit();
        self.allocator.free(self.shape_sorted_slots);
        self.allocator.free(self.shape_keys);
        self.allocator.free(self.shapes);
        self.allocator.free(self.global_keys);
    }

    inline fn moduleNameById(id: u32) []const u8 {
        return dict_lua_program_module_name(id)[0..dict_lua_program_module_name_len(id)];
    }

    inline fn lookupName(index: u32) []const u8 {
        return dict_lua_program_module_lookup_name(index)[0..dict_lua_program_module_lookup_name_len(index)];
    }

    fn lookupExact(self: *const Program, name: []const u8) ?u32 {
        var low: u32 = 0;
        var high = self.module_lookup_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, name, lookupName(mid))) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return dict_lua_program_module_lookup_id(mid),
            }
        }
        return null;
    }

    fn lookup(raw: ?*const anyopaque, raw_name: []const u8) ?u32 {
        const self: *const Program = @ptrCast(@alignCast(raw orelse return null));
        if (self.lookupExact(raw_name)) |id| return id;
        const colon = std.mem.indexOfScalar(u8, raw_name, ':') orelse return null;
        const prefix_raw = raw_name[0..colon];
        if (!std.ascii.eqlIgnoreCase(prefix_raw, "Module") and !std.ascii.eqlIgnoreCase(prefix_raw, "MOD")) return null;
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
        return if (id < self.module_count) moduleNameById(id) else null;
    }

    pub fn initContext(self: *Program, allocator: std.mem.Allocator) !rt.Context {
        var ctx = try rt.Context.initProgram(allocator, self.global_keys.len, self.module_count);
        errdefer ctx.deinit();
        const roots: [*]const rt.FunctionFn = @ptrCast(@alignCast(dict_lua_program_module_roots()));
        ctx.module_root_entries = roots[0..self.module_count];
        const export_shapes: [*]const u32 = @ptrCast(@alignCast(dict_lua_program_module_export_shape_ids()));
        ctx.module_export_shape_ids = export_shapes[0..self.module_count];
        ctx.program_shapes = self.shapes;
        ctx.configureModules(self, lookup, moduleName);
        ctx.configureProgramBootstrap(&self.stdlib_template, stdlib.Template.bootstrapOpaque);
        try rt.bindGlobalTable(&ctx, &self.global_shape, globals_abi.id("_G"));
        _ = try ctx.bootstrapProgram();
        return ctx;
    }
};

pub const Host = scribunto.Host;
pub const FrameArg = scribunto.FrameArg;
pub const WikitextProvider = scribunto.WikitextProvider;
pub const WikitextExpander = scribunto.WikitextExpander;
pub fn initExpander(ctx: *rt.Context, provider: WikitextProvider) WikitextExpander {
    return scribunto.makeWikitextExpander(ctx, globals_abi.id("_G"), globals_abi.id("string"), globals_abi.id("mw"), provider);
}
