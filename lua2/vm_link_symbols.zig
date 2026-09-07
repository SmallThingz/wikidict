const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const model = @import("module_model.zig");
const link_image = @import("vm_link_image.zig");

const ExportTarget = union(enum) {
    function: u32,
    module_export: struct { module: []const u8, name: []const u8 },
};

const ModuleSymbols = struct {
    exports: std.StringHashMapUnmanaged(ExportTarget) = .empty,
    proxy: ?[]const u8 = null,
    dynamic_top: bool = false,

    fn deinit(self: *ModuleSymbols, allocator: std.mem.Allocator) void {
        self.exports.deinit(allocator);
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    by_title: std.StringHashMapUnmanaged(u32) = .empty,
    modules: std.ArrayList(ModuleSymbols) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    exported_functions: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.by_title.deinit(self.allocator);
        self.exported_functions.deinit(self.allocator);
        for (self.owned_strings.items) |text| self.allocator.free(text);
        self.owned_strings.deinit(self.allocator);
    }

    fn own(self: *Index, text: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }

    fn findFunction(
        program: *const ir.Program,
        module: link_image.Module,
        source_start: u32,
    ) ?u32 {
        const end = module.function_base + module.function_count;
        var id = module.function_base;
        while (id < end) : (id += 1) {
            const function = program.functions.items[id] orelse continue;
            if (function.source_start == source_start) return id;
        }
        return null;
    }

    pub fn addModule(
        self: *Index,
        title: []const u8,
        image: *const link_image.Image,
        module_index: u32,
        builder: *const model.Builder,
    ) !void {
        if (module_index != self.modules.items.len) return error.ModuleOrderMismatch;
        if (module_index >= image.modules.items.len) return error.BadModuleIndex;
        const title_copy = try self.own(title);
        try self.by_title.put(self.allocator, title_copy, module_index);
        var symbols = ModuleSymbols{ .dynamic_top = builder.dynamic_top_level };
        errdefer symbols.deinit(self.allocator);
        const linked_module = image.modules.items[module_index];

        switch (builder.return_binding) {
            .table => |table| {
                var it = table.fields.iterator();
                while (it.next()) |entry| switch (entry.value_ptr.*) {
                    .function => |start| {
                        const function_id = findFunction(&image.program, linked_module, start) orelse continue;
                        try symbols.exports.put(self.allocator, try self.own(entry.key_ptr.*), .{ .function = function_id });
                        try self.exported_functions.put(self.allocator, function_id, {});
                    },
                    .module_export => |target| {
                        try symbols.exports.put(self.allocator, try self.own(entry.key_ptr.*), .{ .module_export = .{
                            .module = try self.own(target.module),
                            .name = try self.own(target.name),
                        } });
                    },
                    else => {},
                };
            },
            .module => |target| symbols.proxy = try self.own(target),
            else => {},
        }
        try self.modules.append(self.allocator, symbols);
    }

    pub fn isExportedFunction(self: *const Index, function_id: u32) bool {
        return self.exported_functions.contains(function_id);
    }

    pub fn moduleId(self: *const Index, title: []const u8) ?u32 {
        return self.by_title.get(title);
    }

    pub fn resolveExport(self: *const Index, raw_module: []const u8, raw_name: []const u8) ?u32 {
        var module = raw_module;
        var name = raw_name;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const module_index = self.by_title.get(module) orelse return null;
            const symbols = self.modules.items[module_index];
            if (symbols.dynamic_top) return null;
            if (symbols.exports.get(name)) |target| switch (target) {
                .function => |function_id| return function_id,
                .module_export => |next| {
                    module = next.module;
                    name = next.name;
                    continue;
                },
            };
            if (symbols.proxy) |next_module| {
                module = next_module;
                continue;
            }
            return null;
        }
        return null;
    }
};

fn addSource(
    allocator: std.mem.Allocator,
    image: *link_image.Image,
    symbols: *Index,
    title: []const u8,
    source: []const u8,
) !void {
    var chunk = try lua.parse(allocator, source);
    defer chunk.deinit();
    var builder = model.Builder{ .allocator = allocator, .source = chunk.source };
    defer builder.deinit();
    try builder.build(chunk.body);
    var program = try ir.lowerChunk(allocator, &chunk);
    defer program.deinit();
    const module_index = try image.appendModule(&program);
    try symbols.addModule(title, image, module_index, &builder);
}

test "linked symbols resolve exported functions and proxies" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = Index.init(std.testing.allocator);
    defer symbols.deinit();

    try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local export={}; function export.add(x) return x+1 end; return export");
    try addSource(std.testing.allocator, &image, &symbols, "Module:Proxy", "return require('Module:B')");
    const direct = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    const proxy = symbols.resolveExport("Module:Proxy", "add") orelse return error.MissingProxyExport;
    try std.testing.expectEqual(direct, proxy);
    try std.testing.expect(direct >= image.modules.items[0].function_base);
    try std.testing.expect(direct < image.modules.items[0].function_base + image.modules.items[0].function_count);
}
