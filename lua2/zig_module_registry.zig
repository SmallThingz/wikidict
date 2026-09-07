const std = @import("std");
const rt = @import("zig_runtime");

pub const Registry = struct {
    names: []const []const u8,
    sorted_ids: []const u32,

    fn lookupOpaque(raw: ?*const anyopaque, name: []const u8) ?u32 {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        var low: usize = 0;
        var high = self.sorted_ids.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const id = self.sorted_ids[mid];
            if (id >= self.names.len) return null;
            switch (std.mem.order(u8, name, self.names[id])) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return id,
            }
        }
        return null;
    }

    fn nameOpaque(raw: ?*const anyopaque, id: u32) ?[]const u8 {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        return if (id < self.names.len) self.names[id] else null;
    }

    pub fn configure(self: *const Registry, ctx: *rt.Context) void {
        ctx.configureModules(self, lookupOpaque, nameOpaque);
    }

    pub fn validate(self: *const Registry) !void {
        if (self.sorted_ids.len > self.names.len) return error.BadModuleRegistry;
        var previous: ?[]const u8 = null;
        for (self.sorted_ids) |id| {
            if (id >= self.names.len) return error.BadModuleRegistry;
            const name = self.names[id];
            if (previous) |prev| if (std.mem.order(u8, prev, name) != .lt) return error.BadModuleRegistry;
            previous = name;
        }
    }
};

test "AOT module registry resolves static names to numeric IDs" {
    const names = [_][]const u8{ "Module:Zulu", "Module:Alpha", "Module:Beta" };
    const sorted = [_]u32{ 1, 2, 0 };
    const registry = Registry{ .names = &names, .sorted_ids = &sorted };
    try registry.validate();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = try rt.Context.initProgram(arena.allocator(), 0, names.len);
    defer ctx.deinit();
    registry.configure(&ctx);
    try std.testing.expectEqual(@as(?u32, 1), ctx.module_lookup.?(ctx.module_lookup_ctx, "Module:Alpha"));
    try std.testing.expectEqual(@as(?u32, 2), ctx.module_lookup.?(ctx.module_lookup_ctx, "Module:Beta"));
    try std.testing.expectEqual(@as(?u32, null), ctx.module_lookup.?(ctx.module_lookup_ctx, "Module:Missing"));
    try std.testing.expectEqualStrings("Module:Zulu", ctx.module_name.?(ctx.module_lookup_ctx, 0).?);
}

test "AOT module registry rejects duplicate lookup names and invalid IDs" {
    const duplicate_names = [_][]const u8{ "A", "A" };
    const duplicate_ids = [_]u32{ 0, 1 };
    try std.testing.expectError(error.BadModuleRegistry, (Registry{ .names = &duplicate_names, .sorted_ids = &duplicate_ids }).validate());
    const names = [_][]const u8{"A"};
    const bad_ids = [_]u32{1};
    try std.testing.expectError(error.BadModuleRegistry, (Registry{ .names = &names, .sorted_ids = &bad_ids }).validate());
}
