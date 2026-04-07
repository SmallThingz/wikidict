const std = @import("std");

pub const magic = "WSTRUC01";

pub fn hasValidMagicAtPath(io: std.Io, path: []const u8) !bool {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [magic.len]u8 = undefined;
    const read_len = try file.readPositionalAll(io, &buf, 0);
    if (read_len != magic.len) return false;
    return std.mem.eql(u8, &buf, magic);
}

pub const SectionKind = enum(u8) {
    lines = 0,
    pos_lines = 1,
    term_list = 2,
    translations = 3,
};

pub const HeadingSpec = struct {
    code: u16,
    title: []const u8,
    kind: SectionKind,
};

pub const HeadingLevelSpec = struct {
    code: u16,
    level: u8,
    title: []const u8,
    kind: SectionKind,
};

pub const TemplateSpec = struct {
    code: u16,
    name: []const u8,
};

pub const TargetLanguage = struct {
    code: u16,
    value: []const u8,
};

pub const LanguageLabel = struct {
    code: u16,
    label: []const u8,
};

pub const SourcePageRef = struct {
    name: []const u8,
    // Byte offsets into the source XML dump for the full `<page>...</page>` payload.
    page_start: u64,
    page_end: u64,
};

pub const ModuleCompileFailure = struct {
    name: []const u8,
    reason: []const u8,
};

pub const BuildData = struct {
    // Consumed by encoder/compact_encoding.zig for single-byte direct contractions.
    compact_direct_patterns: []const []const u8 = &.{},
    // Consumed by encoder/section_encoding.zig when emitting generic heading refs.
    heading_specs: []const HeadingSpec = &.{},
    // Consumed by encoder/compact_encoding.zig and decoder/compact_runtime.zig.
    heading_level_specs: []const HeadingLevelSpec = &.{},
    // Consumed by encoder/compact_encoding.zig and decoder/reader.zig template-table loading.
    line_templates: []const TemplateSpec = &.{},
    // Consumed by encoder/compact_encoding.zig as the hot escaped-pattern table.
    compact_patterns: []const []const u8 = &.{},
    // Consumed by encoder/compact_encoding.zig as the overflow escaped-pattern table.
    compact_patterns_ext: []const []const u8 = &.{},
    // Consumed by encoder/compact_encoding.zig and decoder/reader.zig template-table loading.
    translation_templates: []const TemplateSpec = &.{},
    // Consumed by encoder/section_encoding.zig translation compaction.
    target_languages: []const TargetLanguage = &.{},
    // Consumed by encoder/section_encoding.zig translation compaction.
    language_labels: []const LanguageLabel = &.{},
    // Consumed by tools/structure_tables_codegen.zig and decoder/reader.zig validation.
    structure_fingerprint: u32 = 0,

    pub fn deinit(self: *BuildData, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.compact_direct_patterns);
        freeHeadingSpecs(allocator, self.heading_specs);
        freeHeadingLevelSpecs(allocator, self.heading_level_specs);
        freeTemplateSpecs(allocator, self.line_templates);
        freeOwnedStrings(allocator, self.compact_patterns);
        freeOwnedStrings(allocator, self.compact_patterns_ext);
        freeTemplateSpecs(allocator, self.translation_templates);
        freeTargetLanguages(allocator, self.target_languages);
        freeLanguageLabels(allocator, self.language_labels);
        self.* = .{};
    }
};

pub const TemplateMappings = struct {
    structure_fingerprint: u32 = 0,
    line_templates: []TemplateSpec = &.{},
    translation_templates: []TemplateSpec = &.{},

    pub fn deinit(self: *TemplateMappings, allocator: std.mem.Allocator) void {
        freeTemplateSpecs(allocator, self.line_templates);
        freeTemplateSpecs(allocator, self.translation_templates);
        self.* = .{};
    }
};

pub const DependencySet = struct {
    // Consumed by tools/template_codegen.zig as the runtime/template compilation roots.
    root_templates: []const []const u8 = &.{},
    // Consumed by tools/template_codegen.zig for the precomputed reachable closure.
    reachable_templates: []const []const u8 = &.{},
    // Consumed by tools/template_codegen.zig for narrowed dynamic dispatch support.
    dynamic_templates: []const []const u8 = &.{},
    // Consumed by tools/template_codegen.zig and tools/lua_translate.zig diagnostics.
    unresolved_templates: []const []const u8 = &.{},
    // Consumed by tools/structure_analyzer.zig and tools/lua_translate.zig dependency reports.
    direct_modules: []const []const u8 = &.{},
    // Consumed by tools/template_codegen.zig and tools/lua_translate.zig module closure loading.
    transitive_modules: []const []const u8 = &.{},
    // Consumed by encoder/builder.zig and tools/verifier.zig to avoid rescanning XML pages.
    all_entry_pages: []const SourcePageRef = &.{},
    // Consumed by tools/template_codegen.zig and lua/root.zig full source loading.
    all_template_pages: []const SourcePageRef = &.{},
    // Consumed by tools/template_codegen.zig and lua/root.zig full source loading.
    all_module_pages: []const SourcePageRef = &.{},
    // Consumed by tools/template_codegen.zig and lua/root.zig dependency-source loading.
    reachable_template_pages: []const SourcePageRef = &.{},
    // Consumed by tools/template_codegen.zig and lua/root.zig dependency-source loading.
    transitive_module_pages: []const SourcePageRef = &.{},
    // Consumed by tools/template_codegen.zig and tools/lua_translate.zig diagnostics.
    missing_modules: []const []const u8 = &.{},
    // Consumed by tools/template_codegen.zig and tools/lua_translate.zig diagnostics.
    compiled_failed: []const ModuleCompileFailure = &.{},
    // Consumed by tools/template_codegen.zig and tools/lua_translate.zig diagnostics.
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

pub const StructureFile = struct {
    dependencies: DependencySet = .{},
    build: BuildData = .{},

    pub fn deinit(self: *StructureFile, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.build.deinit(allocator);
        self.* = .{};
    }
};

pub fn saveStructureFile(
    io: std.Io,
    path: []const u8,
    build: anytype,
    dependencies: anytype,
) !void {
    const temp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(temp_path);
    std.Io.Dir.cwd().deleteFile(io, temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    defer writer.flush() catch {};

    try writer.interface.writeAll(magic);
    try writeBuildData(&writer.interface, build);
    try writeDependencySet(&writer.interface, dependencies);
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, io);
}

pub fn loadStructureFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !StructureFile {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    );
    defer allocator.free(bytes);

    var cursor: usize = 0;
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidStructureReport;
    cursor = magic.len;

    return .{
        .build = try readBuildDataAlloc(allocator, bytes, &cursor),
        .dependencies = try readDependencySetAlloc(allocator, bytes, &cursor),
    };
}

pub fn loadBuildDataAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !BuildData {
    var structure = try loadStructureFileAlloc(io, allocator, path);
    errdefer structure.deinit(allocator);
    const build = structure.build;
    structure.build = .{};
    structure.deinit(allocator);
    return build;
}

pub fn loadTemplateMappingsAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !TemplateMappings {
    var build = try loadBuildDataAlloc(io, allocator, path);
    defer build.deinit(allocator);
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
    var structure = try loadStructureFileAlloc(io, allocator, path);
    errdefer structure.deinit(allocator);
    const deps = structure.dependencies;
    structure.dependencies = .{};
    structure.deinit(allocator);
    return deps;
}

pub fn loadEntryPageRefsAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const SourcePageRef {
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

fn writeBuildData(writer: *std.Io.Writer, build: anytype) !void {
    try writeStringSlice(writer, build.compact_direct_patterns);
    try writeHeadingSpecs(writer, build.heading_specs);
    try writeHeadingLevelSpecs(writer, build.heading_level_specs);
    try writeTemplateSpecs(writer, build.line_templates);
    try writeStringSlice(writer, build.compact_patterns);
    try writeStringSlice(writer, build.compact_patterns_ext);
    try writeTemplateSpecs(writer, build.translation_templates);
    try writeTargetLanguages(writer, build.target_languages);
    try writeLanguageLabels(writer, build.language_labels);
    try writeU32(writer, build.structure_fingerprint);
}

fn writeDependencySet(writer: *std.Io.Writer, deps: anytype) !void {
    try writeStringSlice(writer, deps.root_templates);
    try writeStringSlice(writer, deps.reachable_templates);
    try writeStringSlice(writer, deps.dynamic_templates);
    try writeStringSlice(writer, deps.unresolved_templates);
    try writeStringSlice(writer, deps.direct_modules);
    try writeStringSlice(writer, deps.transitive_modules);
    try writeSourceRefs(writer, deps.all_entry_pages);
    try writeSourceRefs(writer, deps.all_template_pages);
    try writeSourceRefs(writer, deps.all_module_pages);
    try writeSourceRefs(writer, deps.reachable_template_pages);
    try writeSourceRefs(writer, deps.transitive_module_pages);
    try writeStringSlice(writer, deps.missing_modules);
    try writeFailures(writer, deps.compiled_failed);
    try writeFailures(writer, deps.emitted_inconsistent);
}

fn readBuildDataAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) !BuildData {
    return .{
        .compact_direct_patterns = try readStringSliceAlloc(allocator, bytes, cursor),
        .heading_specs = try readHeadingSpecsAlloc(allocator, bytes, cursor),
        .heading_level_specs = try readHeadingLevelSpecsAlloc(allocator, bytes, cursor),
        .line_templates = try readTemplateSpecsAlloc(allocator, bytes, cursor),
        .compact_patterns = try readStringSliceAlloc(allocator, bytes, cursor),
        .compact_patterns_ext = try readStringSliceAlloc(allocator, bytes, cursor),
        .translation_templates = try readTemplateSpecsAlloc(allocator, bytes, cursor),
        .target_languages = try readTargetLanguagesAlloc(allocator, bytes, cursor),
        .language_labels = try readLanguageLabelsAlloc(allocator, bytes, cursor),
        .structure_fingerprint = try readU32(bytes, cursor),
    };
}

fn readDependencySetAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) !DependencySet {
    return .{
        .root_templates = try readStringSliceAlloc(allocator, bytes, cursor),
        .reachable_templates = try readStringSliceAlloc(allocator, bytes, cursor),
        .dynamic_templates = try readStringSliceAlloc(allocator, bytes, cursor),
        .unresolved_templates = try readStringSliceAlloc(allocator, bytes, cursor),
        .direct_modules = try readStringSliceAlloc(allocator, bytes, cursor),
        .transitive_modules = try readStringSliceAlloc(allocator, bytes, cursor),
        .all_entry_pages = try readSourceRefsAlloc(allocator, bytes, cursor),
        .all_template_pages = try readSourceRefsAlloc(allocator, bytes, cursor),
        .all_module_pages = try readSourceRefsAlloc(allocator, bytes, cursor),
        .reachable_template_pages = try readSourceRefsAlloc(allocator, bytes, cursor),
        .transitive_module_pages = try readSourceRefsAlloc(allocator, bytes, cursor),
        .missing_modules = try readStringSliceAlloc(allocator, bytes, cursor),
        .compiled_failed = try readFailuresAlloc(allocator, bytes, cursor),
        .emitted_inconsistent = try readFailuresAlloc(allocator, bytes, cursor),
    };
}

fn writeTemplateSpecs(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeU16(writer, item.code);
        try writeString(writer, item.name);
    }
}

fn readTemplateSpecsAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]TemplateSpec {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(TemplateSpec, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.name);
        allocator.free(out);
    }
    for (out) |*item| {
        item.code = try readU16(bytes, cursor);
        item.name = try readStringAlloc(allocator, bytes, cursor);
    }
    return out;
}

fn writeHeadingSpecs(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeU16(writer, item.code);
        try writeString(writer, item.title);
        try writeU8(writer, @intFromEnum(item.kind));
    }
}

fn readHeadingSpecsAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]HeadingSpec {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(HeadingSpec, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.title);
        allocator.free(out);
    }
    for (out) |*item| {
        item.code = try readU16(bytes, cursor);
        item.title = try readStringAlloc(allocator, bytes, cursor);
        item.kind = @enumFromInt(try readU8(bytes, cursor));
    }
    return out;
}

fn writeHeadingLevelSpecs(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeU16(writer, item.code);
        try writeU8(writer, item.level);
        try writeString(writer, item.title);
        try writeU8(writer, @intFromEnum(item.kind));
    }
}

fn readHeadingLevelSpecsAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]HeadingLevelSpec {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(HeadingLevelSpec, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.title);
        allocator.free(out);
    }
    for (out) |*item| {
        item.code = try readU16(bytes, cursor);
        item.level = try readU8(bytes, cursor);
        item.title = try readStringAlloc(allocator, bytes, cursor);
        item.kind = @enumFromInt(try readU8(bytes, cursor));
    }
    return out;
}

fn writeTargetLanguages(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeU16(writer, item.code);
        try writeString(writer, item.value);
    }
}

fn readTargetLanguagesAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]TargetLanguage {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(TargetLanguage, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.value);
        allocator.free(out);
    }
    for (out) |*item| {
        item.code = try readU16(bytes, cursor);
        item.value = try readStringAlloc(allocator, bytes, cursor);
    }
    return out;
}

fn writeLanguageLabels(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeU16(writer, item.code);
        try writeString(writer, item.label);
    }
}

fn readLanguageLabelsAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]LanguageLabel {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(LanguageLabel, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.label);
        allocator.free(out);
    }
    for (out) |*item| {
        item.code = try readU16(bytes, cursor);
        item.label = try readStringAlloc(allocator, bytes, cursor);
    }
    return out;
}

fn writeSourceRefs(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeString(writer, item.name);
        try writeU64(writer, item.page_start);
        try writeU64(writer, item.page_end);
    }
}

fn readSourceRefsAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]SourcePageRef {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(SourcePageRef, count);
    errdefer {
        for (out[0..count]) |entry| allocator.free(entry.name);
        allocator.free(out);
    }
    for (out) |*item| {
        item.name = try readStringAlloc(allocator, bytes, cursor);
        item.page_start = try readU64(bytes, cursor);
        item.page_end = try readU64(bytes, cursor);
    }
    return out;
}

fn writeFailures(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| {
        try writeString(writer, item.name);
        try writeString(writer, item.reason);
    }
}

fn readFailuresAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]ModuleCompileFailure {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc(ModuleCompileFailure, count);
    errdefer {
        for (out[0..count]) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.reason);
        }
        allocator.free(out);
    }
    for (out) |*item| {
        item.name = try readStringAlloc(allocator, bytes, cursor);
        item.reason = try readStringAlloc(allocator, bytes, cursor);
    }
    return out;
}

fn writeStringSlice(writer: *std.Io.Writer, items: anytype) !void {
    try writeCount(writer, items.len);
    for (items) |item| try writeString(writer, item);
}

fn readStringSliceAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]const []const u8 {
    const count = try readCount(bytes, cursor);
    const out = try allocator.alloc([]const u8, count);
    errdefer {
        for (out[0..count]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (out) |*item| item.* = try readStringAlloc(allocator, bytes, cursor);
    return out;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeCount(writer, value.len);
    try writer.writeAll(value);
}

fn readStringAlloc(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize) ![]u8 {
    const len = try readCount(bytes, cursor);
    if (cursor.* > bytes.len or len > bytes.len - cursor.*) return error.InvalidStructureReport;
    const out = try allocator.dupe(u8, bytes[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}

fn writeCount(writer: *std.Io.Writer, value: usize) !void {
    try writeU32(writer, std.math.cast(u32, value) orelse return error.FileTooBig);
}

fn readCount(bytes: []const u8, cursor: *usize) !usize {
    return try readU32(bytes, cursor);
}

fn writeU8(writer: *std.Io.Writer, value: u8) !void {
    try writer.writeByte(value);
}

fn readU8(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len) return error.InvalidStructureReport;
    const value = bytes[cursor.*];
    cursor.* += 1;
    return value;
}

fn writeU16(writer: *std.Io.Writer, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readU16(bytes: []const u8, cursor: *usize) !u16 {
    if (cursor.* > bytes.len or 2 > bytes.len - cursor.*) return error.InvalidStructureReport;
    const ptr: *const [2]u8 = @ptrCast(bytes[cursor.* .. cursor.* + 2].ptr);
    cursor.* += 2;
    return std.mem.readInt(u16, ptr, .little);
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* > bytes.len or 4 > bytes.len - cursor.*) return error.InvalidStructureReport;
    const ptr: *const [4]u8 = @ptrCast(bytes[cursor.* .. cursor.* + 4].ptr);
    cursor.* += 4;
    return std.mem.readInt(u32, ptr, .little);
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readU64(bytes: []const u8, cursor: *usize) !u64 {
    if (cursor.* > bytes.len or 8 > bytes.len - cursor.*) return error.InvalidStructureReport;
    const ptr: *const [8]u8 = @ptrCast(bytes[cursor.* .. cursor.* + 8].ptr);
    cursor.* += 8;
    return std.mem.readInt(u64, ptr, .little);
}

fn dupTemplateSpecsAlloc(allocator: std.mem.Allocator, items: []const TemplateSpec) ![]TemplateSpec {
    const out = try allocator.alloc(TemplateSpec, items.len);
    errdefer {
        for (out[0..items.len]) |entry| allocator.free(entry.name);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| out[idx] = .{
        .code = item.code,
        .name = try allocator.dupe(u8, item.name),
    };
    return out;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeHeadingSpecs(allocator: std.mem.Allocator, items: []const HeadingSpec) void {
    for (items) |item| allocator.free(item.title);
    allocator.free(items);
}

fn freeHeadingLevelSpecs(allocator: std.mem.Allocator, items: []const HeadingLevelSpec) void {
    for (items) |item| allocator.free(item.title);
    allocator.free(items);
}

fn freeTemplateSpecs(allocator: std.mem.Allocator, items: []const TemplateSpec) void {
    for (items) |item| allocator.free(item.name);
    allocator.free(items);
}

fn freeTargetLanguages(allocator: std.mem.Allocator, items: []const TargetLanguage) void {
    for (items) |item| allocator.free(item.value);
    allocator.free(items);
}

fn freeLanguageLabels(allocator: std.mem.Allocator, items: []const LanguageLabel) void {
    for (items) |item| allocator.free(item.label);
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

fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, value.len, .little);
    hasher.update(&len_buf);
    hasher.update(value);
}

test "structure report binary round-trips build data and entry refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure-report-test.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    const build = BuildData{
        .compact_direct_patterns = &.{"abc"},
        .heading_specs = &.{.{ .code = 1, .title = "Noun", .kind = .pos_lines }},
        .heading_level_specs = &.{.{ .code = 2, .level = 3, .title = "Translations", .kind = .translations }},
        .line_templates = &.{.{ .code = 3, .name = "plural of" }},
        .compact_patterns = &.{"{{"},
        .compact_patterns_ext = &.{"}}"},
        .translation_templates = &.{.{ .code = 4, .name = "t" }},
        .target_languages = &.{.{ .code = 5, .value = "French" }},
        .language_labels = &.{.{ .code = 6, .label = "gloss" }},
        .structure_fingerprint = 77,
    };
    const deps = DependencySet{
        .root_templates = &.{"foo"},
        .all_entry_pages = &.{.{ .name = "entry", .page_start = 10, .page_end = 20 }},
        .all_template_pages = &.{.{ .name = "foo", .page_start = 21, .page_end = 30 }},
    };
    try saveStructureFile(std.testing.io, path, build, deps);

    var loaded = try loadStructureFileAlloc(std.testing.io, std.testing.allocator, path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc", loaded.build.compact_direct_patterns[0]);
    try std.testing.expectEqualStrings("plural of", loaded.build.line_templates[0].name);
    try std.testing.expectEqual(@as(u32, 77), loaded.build.structure_fingerprint);
    try std.testing.expectEqual(@as(usize, 1), loaded.dependencies.all_entry_pages.len);
    try std.testing.expectEqualStrings("entry", loaded.dependencies.all_entry_pages[0].name);
    try std.testing.expectEqual(@as(u64, 21), loaded.dependencies.all_template_pages[0].page_start);
}

test "templateTableFingerprint changes when template names change" {
    const a = [_]TemplateSpec{.{ .code = 1, .name = "plural of" }};
    const b = [_]TemplateSpec{.{ .code = 1, .name = "alternative form of" }};
    try std.testing.expect(templateTableFingerprint(&a, &.{}) != templateTableFingerprint(&b, &.{}));
}
