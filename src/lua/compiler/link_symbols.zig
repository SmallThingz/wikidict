const std = @import("std");
const lua = @import("../parser/root.zig");
const ir = @import("ir.zig");
const model = @import("module_model.zig");
const link_image = @import("link_image.zig");

const ExportTarget = union(enum) {
    function: u32,
    module_export: struct { module: []const u8, name: []const u8 },
};

const FieldFunctionCandidate = union(enum) { target: u32, ambiguous };

const ModuleSymbols = struct {
    exports: std.StringHashMapUnmanaged(ExportTarget) = .empty,
    callable: ?ExportTarget = null,
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
    field_function_candidates: std.StringHashMapUnmanaged(FieldFunctionCandidate) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.by_title.deinit(self.allocator);
        self.exported_functions.deinit(self.allocator);
        self.field_function_candidates.deinit(self.allocator);
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
                        const export_name = try self.own(entry.key_ptr.*);
                        try symbols.exports.put(self.allocator, export_name, .{ .function = function_id });
                        try self.exported_functions.put(self.allocator, function_id, {});
                        if (!builder.dynamic_top_level) {
                            if (self.field_function_candidates.getPtr(export_name)) |candidate| {
                                if (candidate.* == .target and candidate.target != function_id) candidate.* = .ambiguous;
                            } else {
                                try self.field_function_candidates.put(self.allocator, export_name, .{ .target = function_id });
                            }
                        }
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
            .function => |start| if (findFunction(&image.program, linked_module, start)) |function_id| {
                symbols.callable = .{ .function = function_id };
            },
            .module_export => |target| symbols.callable = .{ .module_export = .{
                .module = try self.own(target.module),
                .name = try self.own(target.name),
            } },
            .module => |target| symbols.proxy = try self.own(target),
            else => {},
        }
        try self.modules.append(self.allocator, symbols);
    }

    pub fn isExportedFunction(self: *const Index, function_id: u32) bool {
        return self.exported_functions.contains(function_id);
    }

    pub fn fieldFunctionCandidate(self: *const Index, name: []const u8) ?u32 {
        const candidate = self.field_function_candidates.get(name) orelse return null;
        return switch (candidate) {
            .target => |function_id| function_id,
            .ambiguous => null,
        };
    }

    pub fn moduleId(self: *const Index, title: []const u8) ?u32 {
        return self.by_title.get(title);
    }

    pub fn resolveCallableModule(self: *const Index, raw_module: []const u8) ?u32 {
        var module = raw_module;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const module_index = self.by_title.get(module) orelse return null;
            const symbols = self.modules.items[module_index];
            if (symbols.dynamic_top) return null;
            if (symbols.callable) |target| return switch (target) {
                .function => |function_id| function_id,
                .module_export => |next| self.resolveExport(next.module, next.name),
            };
            if (symbols.proxy) |next_module| {
                module = next_module;
                continue;
            }
            return null;
        }
        return null;
    }

    // Candidate-only lookup: this intentionally ignores the module-wide dynamic-top
    // veto. Callers must use the result only behind a live runtime function-ID guard.
    pub fn resolveExportCandidate(self: *const Index, raw_module: []const u8, raw_name: []const u8) ?u32 {
        var module = raw_module;
        var name = raw_name;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const module_index = self.by_title.get(module) orelse return null;
            const symbols = self.modules.items[module_index];
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

test "field function candidates require one static export target" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = Index.init(std.testing.allocator);
    defer symbols.deinit();
    try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;return e");
    const first = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    try std.testing.expectEqual(@as(?u32, first), symbols.fieldFunctionCandidate("add"));
    try addSource(std.testing.allocator, &image, &symbols, "Module:C", "local e={};function e.sub(x)return x-1 end;return e");
    try std.testing.expectEqual(@as(?u32, first), symbols.fieldFunctionCandidate("add"));
    try addSource(std.testing.allocator, &image, &symbols, "Module:D", "local e={};function e.add(x)return x+2 end;return e");
    try std.testing.expectEqual(@as(?u32, null), symbols.fieldFunctionCandidate("add"));
}

test "callable modules resolve function roots and proxies" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = Index.init(std.testing.allocator);
    defer symbols.deinit();
    try addSource(std.testing.allocator, &image, &symbols, "Module:F", "local function f(x)return x+1 end;return f");
    try addSource(std.testing.allocator, &image, &symbols, "Module:Proxy", "return require('Module:F')");
    const direct = symbols.resolveCallableModule("Module:F") orelse return error.MissingCallableModule;
    try std.testing.expectEqual(direct, symbols.resolveCallableModule("Module:Proxy").?);
    try std.testing.expect(direct < image.program.functions.items.len);
    try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+2 end;return e");
    try addSource(std.testing.allocator, &image, &symbols, "Module:ExportProxy", "return require('Module:B').add");
    const exported = symbols.resolveExport("Module:B", "add") orelse return error.MissingExport;
    try std.testing.expectEqual(exported, symbols.resolveCallableModule("Module:ExportProxy").?);

    try addSource(std.testing.allocator, &image, &symbols, "Module:Table", "return {}");
    try std.testing.expectEqual(@as(?u32, null), symbols.resolveCallableModule("Module:Table"));
    try addSource(std.testing.allocator, &image, &symbols, "Module:Dynamic", "local function f()end;if x then f=function()end end;return f");
    try std.testing.expectEqual(@as(?u32, null), symbols.resolveCallableModule("Module:Dynamic"));
}

test "dynamic modules expose export candidates without strict export facts" {
    var image = link_image.Image.init(std.testing.allocator);
    defer image.deinit();
    var symbols = Index.init(std.testing.allocator);
    defer symbols.deinit();
    try addSource(std.testing.allocator, &image, &symbols, "Module:B", "local e={};function e.add(x)return x+1 end;if flag then e.add=function(x)return x+100 end end;return e");
    try std.testing.expectEqual(@as(?u32, null), symbols.resolveExport("Module:B", "add"));
    const candidate = symbols.resolveExportCandidate("Module:B", "add") orelse return error.MissingCandidate;
    try std.testing.expect(candidate < image.program.functions.items.len);
    try std.testing.expectEqual(@as(?u32, null), symbols.fieldFunctionCandidate("add"));
    try std.testing.expectEqual(@as(?u32, null), symbols.resolveExportCandidate("Module:B", "missing"));
}
