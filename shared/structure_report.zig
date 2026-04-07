const std = @import("std");

pub const TemplateSpec = struct {
    code: u16,
    name: []const u8,
};

pub const SourcePageRef = struct {
    name: []const u8,
    page_start: u64,
    page_end: u64,
};

pub const ModuleCompileFailure = struct {
    name: []const u8,
    reason: []const u8,
};

pub const TemplateMappings = struct {
    structure_fingerprint: u32 = 0,
    line_templates: []TemplateSpec = &.{},
    translation_templates: []TemplateSpec = &.{},

    pub fn deinit(self: *TemplateMappings, allocator: std.mem.Allocator) void {
        for (self.line_templates) |entry| allocator.free(entry.name);
        allocator.free(self.line_templates);
        for (self.translation_templates) |entry| allocator.free(entry.name);
        allocator.free(self.translation_templates);
        self.* = .{};
    }
};

pub const DependencySet = struct {
    root_templates: []const []const u8 = &.{},
    reachable_templates: []const []const u8 = &.{},
    dynamic_templates: []const []const u8 = &.{},
    unresolved_templates: []const []const u8 = &.{},
    direct_modules: []const []const u8 = &.{},
    transitive_modules: []const []const u8 = &.{},
    all_entry_pages: []const SourcePageRef = &.{},
    // Full template page ref table copied from the structure report so tools
    // can mmap-load arbitrary template sources without rescanning the XML.
    all_template_pages: []const SourcePageRef = &.{},
    // Full module page ref table copied from the structure report for the same
    // offset-based module loading path.
    all_module_pages: []const SourcePageRef = &.{},
    reachable_template_pages: []const SourcePageRef = &.{},
    transitive_module_pages: []const SourcePageRef = &.{},
    missing_modules: []const []const u8 = &.{},
    compiled_failed: []const ModuleCompileFailure = &.{},
    emitted_inconsistent: []const ModuleCompileFailure = &.{},

    pub fn deinit(self: *DependencySet, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.root_templates);
        freeOwnedStrings(allocator, self.reachable_templates);
        freeOwnedStrings(allocator, self.dynamic_templates);
        freeOwnedStrings(allocator, self.unresolved_templates);
        freeOwnedStrings(allocator, self.direct_modules);
        freeOwnedStrings(allocator, self.transitive_modules);
        freeSourceRefs(allocator, self.all_entry_pages);
        freeSourceRefs(allocator, self.all_template_pages);
        freeSourceRefs(allocator, self.all_module_pages);
        freeSourceRefs(allocator, self.reachable_template_pages);
        freeSourceRefs(allocator, self.transitive_module_pages);
        freeOwnedStrings(allocator, self.missing_modules);
        freeFailures(allocator, self.compiled_failed);
        freeFailures(allocator, self.emitted_inconsistent);
        self.* = .{};
    }
};

const ParsedStructureFile = struct {
    dependencies: struct {
        root_templates: []const []const u8 = &.{},
        reachable_templates: []const []const u8 = &.{},
        dynamic_templates: []const []const u8 = &.{},
        unresolved_templates: []const []const u8 = &.{},
        direct_modules: []const []const u8 = &.{},
        transitive_modules: []const []const u8 = &.{},
        all_entry_pages: []const SourcePageRef = &.{},
        all_template_pages: []const SourcePageRef = &.{},
        all_module_pages: []const SourcePageRef = &.{},
        reachable_template_pages: []const SourcePageRef = &.{},
        transitive_module_pages: []const SourcePageRef = &.{},
        missing_modules: []const []const u8 = &.{},
        compiled_failed: []const ModuleCompileFailure = &.{},
        emitted_inconsistent: []const ModuleCompileFailure = &.{},
    } = .{},
    build: struct {
        structure_fingerprint: u32 = 0,
        line_templates: []const TemplateSpec = &.{},
        translation_templates: []const TemplateSpec = &.{},
    } = .{},
};

pub fn loadTemplateMappingsAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !TemplateMappings {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    );
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(ParsedStructureFile, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const build = parsed.value.build;
    return .{
        .structure_fingerprint = build.structure_fingerprint,
        .line_templates = try dupTemplateSpecsAlloc(allocator, build.line_templates),
        .translation_templates = try dupTemplateSpecsAlloc(allocator, build.translation_templates),
    };
}

pub fn loadDependencySetAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !DependencySet {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    );
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(ParsedStructureFile, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const deps = parsed.value.dependencies;
    return .{
        .root_templates = try dupOwnedStringsAlloc(allocator, deps.root_templates),
        .reachable_templates = try dupOwnedStringsAlloc(allocator, deps.reachable_templates),
        .dynamic_templates = try dupOwnedStringsAlloc(allocator, deps.dynamic_templates),
        .unresolved_templates = try dupOwnedStringsAlloc(allocator, deps.unresolved_templates),
        .direct_modules = try dupOwnedStringsAlloc(allocator, deps.direct_modules),
        .transitive_modules = try dupOwnedStringsAlloc(allocator, deps.transitive_modules),
        .all_entry_pages = try dupSourceRefsAlloc(allocator, deps.all_entry_pages),
        .all_template_pages = try dupSourceRefsAlloc(allocator, deps.all_template_pages),
        .all_module_pages = try dupSourceRefsAlloc(allocator, deps.all_module_pages),
        .reachable_template_pages = try dupSourceRefsAlloc(allocator, deps.reachable_template_pages),
        .transitive_module_pages = try dupSourceRefsAlloc(allocator, deps.transitive_module_pages),
        .missing_modules = try dupOwnedStringsAlloc(allocator, deps.missing_modules),
        .compiled_failed = try dupFailuresAlloc(allocator, deps.compiled_failed),
        .emitted_inconsistent = try dupFailuresAlloc(allocator, deps.emitted_inconsistent),
    };
}

pub fn loadEntryPageRefsAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]SourcePageRef {
    var deps = try loadDependencySetAlloc(io, allocator, path);
    errdefer deps.deinit(allocator);
    const refs = deps.all_entry_pages;
    deps.all_entry_pages = &.{};
    deps.deinit(allocator);
    return refs;
}

pub fn templateTableFingerprint(line_templates: anytype, translation_templates: anytype) u32 {
    var hasher = std.hash.Wyhash.init(0x2d9e31f4cb6a77d1);

    for (line_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }
    for (translation_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }

    return @truncate(hasher.final());
}

fn dupTemplateSpecsAlloc(allocator: std.mem.Allocator, items: []const TemplateSpec) ![]TemplateSpec {
    const out = try allocator.alloc(TemplateSpec, items.len);
    errdefer {
        for (out[0..items.len]) |entry| {
            if (entry.name.len != 0) allocator.free(entry.name);
        }
        allocator.free(out);
    }

    for (items, 0..) |item, idx| {
        out[idx] = .{
            .code = item.code,
            .name = try allocator.dupe(u8, item.name),
        };
    }
    return out;
}

fn dupOwnedStringsAlloc(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    errdefer {
        for (out[0..items.len]) |value| {
            if (value.len != 0) allocator.free(value);
        }
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
    }
    return out;
}

fn dupSourceRefsAlloc(allocator: std.mem.Allocator, items: []const SourcePageRef) ![]SourcePageRef {
    const out = try allocator.alloc(SourcePageRef, items.len);
    errdefer {
        for (out[0..items.len]) |entry| {
            if (entry.name.len != 0) allocator.free(entry.name);
        }
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, item.name),
            .page_start = item.page_start,
            .page_end = item.page_end,
        };
    }
    return out;
}

fn dupFailuresAlloc(allocator: std.mem.Allocator, items: []const ModuleCompileFailure) ![]ModuleCompileFailure {
    const out = try allocator.alloc(ModuleCompileFailure, items.len);
    errdefer {
        for (out[0..items.len]) |entry| {
            if (entry.name.len != 0) allocator.free(entry.name);
            if (entry.reason.len != 0) allocator.free(entry.reason);
        }
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, item.name),
            .reason = try allocator.dupe(u8, item.reason),
        };
    }
    return out;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeSourceRefs(allocator: std.mem.Allocator, items: []const SourcePageRef) void {
    for (items) |item| allocator.free(item.name);
    allocator.free(items);
}

fn freeFailures(allocator: std.mem.Allocator, items: []const ModuleCompileFailure) void {
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.reason);
    }
    allocator.free(items);
}

test "loadDependencySetAlloc reads full source ref tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json =
        \\{
        \\  "dependencies": {
        \\    "root_templates": ["foo"],
        \\    "all_entry_pages": [
        \\      { "name": "entry", "page_start": 1, "page_end": 9 }
        \\    ],
        \\    "all_template_pages": [
        \\      { "name": "foo", "page_start": 10, "page_end": 20 }
        \\    ],
        \\    "all_module_pages": [
        \\      { "name": "bar", "page_start": 30, "page_end": 40 }
        \\    ],
        \\    "reachable_template_pages": [
        \\      { "name": "foo", "page_start": 10, "page_end": 20 }
        \\    ],
        \\    "transitive_module_pages": [
        \\      { "name": "bar", "page_start": 30, "page_end": 40 }
        \\    ]
        \\  },
        \\  "build": {}
        \\}
    ;

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure-report-test.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, json);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var deps = try loadDependencySetAlloc(std.Options.debug_io, std.testing.allocator, path);
    defer deps.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), deps.all_template_pages.len);
    try std.testing.expectEqual(@as(usize, 1), deps.all_entry_pages.len);
    try std.testing.expectEqualStrings("entry", deps.all_entry_pages[0].name);
    try std.testing.expectEqualStrings("foo", deps.all_template_pages[0].name);
    try std.testing.expectEqual(@as(u64, 30), deps.all_module_pages[0].page_start);
}

fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, value.len, .little);
    hasher.update(&len_buf);
    hasher.update(value);
}

test "templateTableFingerprint changes when template names change" {
    const a = [_]TemplateSpec{.{ .code = 1, .name = "plural of" }};
    const b = [_]TemplateSpec{.{ .code = 1, .name = "alternative form of" }};
    try std.testing.expect(templateTableFingerprint(&a, &.{}) != templateTableFingerprint(&b, &.{}));
}
