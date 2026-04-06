const std = @import("std");
const compact_pattern_seed = @import("compact_pattern_seed");

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

pub const BuildData = struct {
    // Highest-frequency exact patterns emitted as direct 1-byte opcodes.
    compact_direct_patterns: []const []const u8 = &.{},
    // Heading encodings that do not depend on heading depth.
    heading_specs: []const HeadingSpec,
    // Heading encodings that are only valid at a specific wiktionary depth.
    heading_level_specs: []const HeadingLevelSpec,
    // Inline templates that are emitted as dedicated compact tokens.
    line_templates: []const TemplateSpec,
    // High-frequency escaped byte patterns embedded directly in the compact codec.
    compact_patterns: []const []const u8,
    // Lower-frequency overflow patterns kept in a second table to avoid bloating the hot tier.
    compact_patterns_ext: []const []const u8,
    translation_templates: []const TemplateSpec,
    target_languages: []const TargetLanguage,
    language_labels: []const LanguageLabel,
    structure_fingerprint: u32,

    pub fn deinit(self: *BuildData, allocator: std.mem.Allocator) void {
        for (self.compact_direct_patterns) |entry| allocator.free(entry);
        allocator.free(self.compact_direct_patterns);
        for (self.heading_specs) |entry| allocator.free(entry.title);
        allocator.free(self.heading_specs);
        for (self.heading_level_specs) |entry| allocator.free(entry.title);
        allocator.free(self.heading_level_specs);
        for (self.line_templates) |entry| allocator.free(entry.name);
        allocator.free(self.line_templates);
        for (self.compact_patterns) |entry| allocator.free(entry);
        allocator.free(self.compact_patterns);
        for (self.compact_patterns_ext) |entry| allocator.free(entry);
        allocator.free(self.compact_patterns_ext);
        for (self.translation_templates) |entry| allocator.free(entry.name);
        allocator.free(self.translation_templates);
        for (self.target_languages) |entry| allocator.free(entry.value);
        allocator.free(self.target_languages);
        for (self.language_labels) |entry| allocator.free(entry.label);
        allocator.free(self.language_labels);
    }
};

pub const CountEntry = struct {
    key: []const u8,
    count: u64 = 0,
};

pub const AnomalySample = struct {
    title: []const u8,
    kind: []const u8,
    detail: []const u8,
};

pub const DependencyFailure = struct {
    name: []const u8,
    reason: []const u8,
};

pub const DependencySourceRef = struct {
    name: []const u8,
    page_start: u64,
    page_end: u64,
};

pub const Dependencies = struct {
    root_templates: []const []const u8 = &.{},
    reachable_templates: []const []const u8 = &.{},
    unresolved_templates: []const []const u8 = &.{},
    direct_modules: []const []const u8 = &.{},
    transitive_modules: []const []const u8 = &.{},
    // Full template page ref table captured during structure analysis so tools
    // can reload any template source directly from the XML mmap without rescans.
    all_template_pages: []const DependencySourceRef = &.{},
    // Full module page ref table captured during structure analysis for the
    // same offset-based source loading path used by code generation.
    all_module_pages: []const DependencySourceRef = &.{},
    reachable_template_pages: []const DependencySourceRef = &.{},
    transitive_module_pages: []const DependencySourceRef = &.{},
    missing_modules: []const []const u8 = &.{},
    compiled_failed: []const DependencyFailure = &.{},
    emitted_inconsistent: []const DependencyFailure = &.{},
};

pub const Anomalies = struct {
    kinds: []const CountEntry = &.{},
    samples: []const AnomalySample = &.{},
};

pub const Summary = struct {
    pages_scanned: usize,
    namespace_zero_pages: usize,
    language_entries: usize,
    heading_level_jumps: usize,
    content_before_subheading: usize,
    unbalanced_sections: usize,
    unclassified_heading_titles: usize,
};

pub const ExactStructureReport = struct {
    input: []const u8,
    summary: Summary,
    anomalies: Anomalies,
    dependencies: Dependencies = .{},
    build: BuildData,
};

pub const LegacyHeadingProfile = struct {
    title: []const u8,
    parser_kind: []const u8,
    count: u64 = 0,
};

pub const LegacyHeadingTemplateEntry = struct {
    heading: []const u8,
    template: []const u8,
    count: u64 = 0,
};

pub const LegacyBuildInputs = struct {
    heading_profiles: []const LegacyHeadingProfile,
    // Keys are serialized as `L<level>:<title>` in the legacy report.
    headings_by_level: []const CountEntry = &.{},
    translation_source_labels: []const CountEntry = &.{},
    translation_target_languages: []const CountEntry = &.{},
    templates_by_heading: []const LegacyHeadingTemplateEntry = &.{},
};

const GeneratedHeading = struct {
    title: []const u8,
    kind: SectionKind,
    count: u64,
};

const GeneratedHeadingLevel = struct {
    title: []const u8,
    level: u8,
    kind: SectionKind,
    count: u64,
};

const GeneratedLabel = struct {
    label: []const u8,
    count: u64,
};

const GeneratedTemplate = struct {
    name: []const u8,
    count: u64,
};

const GeneratedCompactPattern = struct {
    pattern: []const u8,
    count: u64,
};

const GeneratedTargetLanguage = struct {
    value: []const u8,
    count: u64,
};

const ParsedHeadingLevelKey = struct {
    level: u8,
    title: []const u8,
};

pub fn parseExactStructureReportFromSlice(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !std.json.Parsed(ExactStructureReport) {
    return std.json.parseFromSlice(ExactStructureReport, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
}

pub fn sectionKindForParserKind(parser_kind: []const u8) ?SectionKind {
    if (std.mem.eql(u8, parser_kind, "part-of-speech")) return .pos_lines;
    if (std.mem.eql(u8, parser_kind, "alternative-forms")) return .term_list;
    if (std.mem.eql(u8, parser_kind, "relations")) return .term_list;
    if (std.mem.eql(u8, parser_kind, "navigation")) return .term_list;
    if (std.mem.eql(u8, parser_kind, "translations")) return .translations;
    if (std.mem.eql(u8, parser_kind, "language-root")) return null;
    if (std.mem.eql(u8, parser_kind, "citations")) return .lines;
    if (std.mem.eql(u8, parser_kind, "descendants")) return .lines;
    if (std.mem.eql(u8, parser_kind, "etymology")) return .lines;
    if (std.mem.eql(u8, parser_kind, "inflection")) return .lines;
    if (std.mem.eql(u8, parser_kind, "meta")) return .lines;
    if (std.mem.eql(u8, parser_kind, "notes")) return .lines;
    if (std.mem.eql(u8, parser_kind, "pronunciation")) return .lines;
    return null;
}

pub fn buildDataFromLegacyAlloc(
    allocator: std.mem.Allocator,
    legacy: LegacyBuildInputs,
) !BuildData {
    var headings: std.ArrayList(GeneratedHeading) = .empty;
    defer headings.deinit(allocator);
    var heading_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &heading_indexes);

    for (legacy.heading_profiles) |profile| {
        const kind = sectionKindForParserKind(profile.parser_kind) orelse continue;
        const gop = try heading_indexes.getOrPut(allocator, profile.title);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, profile.title);
            gop.value_ptr.* = headings.items.len;
            try headings.append(allocator, .{
                .title = gop.key_ptr.*,
                .kind = kind,
                .count = profile.count,
            });
        } else {
            headings.items[gop.value_ptr.*].count += profile.count;
        }
    }
    std.mem.sortUnstable(GeneratedHeading, headings.items, {}, generatedHeadingLessThan);

    var heading_levels: std.ArrayList(GeneratedHeadingLevel) = .empty;
    defer {
        for (heading_levels.items) |entry| allocator.free(entry.title);
        heading_levels.deinit(allocator);
    }
    for (legacy.headings_by_level) |entry| {
        const parsed_key = parseHeadingLevelKey(entry.key) orelse continue;
        const kind = headingKindForTitle(legacy.heading_profiles, parsed_key.title) orelse continue;
        try heading_levels.append(allocator, .{
            .title = try allocator.dupe(u8, parsed_key.title),
            .level = parsed_key.level,
            .kind = kind,
            .count = entry.count,
        });
    }
    std.mem.sortUnstable(GeneratedHeadingLevel, heading_levels.items, {}, generatedHeadingLevelLessThan);

    var labels: std.ArrayList(GeneratedLabel) = .empty;
    defer labels.deinit(allocator);
    var label_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &label_indexes);
    for (legacy.translation_source_labels) |entry| {
        const label = std.mem.trim(u8, entry.key, " \t\r\n");
        if (label.len == 0) continue;
        const gop = try label_indexes.getOrPut(allocator, label);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, label);
            gop.value_ptr.* = labels.items.len;
            try labels.append(allocator, .{
                .label = gop.key_ptr.*,
                .count = entry.count,
            });
        } else {
            labels.items[gop.value_ptr.*].count += entry.count;
        }
    }
    std.mem.sortUnstable(GeneratedLabel, labels.items, {}, generatedLabelLessThan);

    var templates: std.ArrayList(GeneratedTemplate) = .empty;
    defer templates.deinit(allocator);
    var template_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &template_indexes);
    var line_templates: std.ArrayList(GeneratedTemplate) = .empty;
    defer line_templates.deinit(allocator);
    var line_template_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &line_template_indexes);
    for (legacy.templates_by_heading) |entry| {
        const template_name = std.mem.trim(u8, entry.template, " \t\r\n");
        if (template_name.len == 0) continue;
        if (isTranslationHeading(entry.heading)) {
            const gop = try template_indexes.getOrPut(allocator, template_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, template_name);
                gop.value_ptr.* = templates.items.len;
                try templates.append(allocator, .{
                    .name = gop.key_ptr.*,
                    .count = entry.count,
                });
            } else {
                templates.items[gop.value_ptr.*].count += entry.count;
            }
            continue;
        }

        const gop = try line_template_indexes.getOrPut(allocator, template_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, template_name);
            gop.value_ptr.* = line_templates.items.len;
            try line_templates.append(allocator, .{
                .name = gop.key_ptr.*,
                .count = entry.count,
            });
        } else {
            line_templates.items[gop.value_ptr.*].count += entry.count;
        }
    }
    std.mem.sortUnstable(GeneratedTemplate, templates.items, {}, generatedTemplateLessThan);
    std.mem.sortUnstable(GeneratedTemplate, line_templates.items, {}, generatedTemplateLessThan);

    var covered_patterns: std.StringHashMapUnmanaged(void) = .empty;
    defer deinitOwnedStringMap(allocator, void, &covered_patterns);
    try compact_pattern_seed.seedCoveredPatterns(allocator, &covered_patterns);

    var compact_patterns_all: std.ArrayList(GeneratedCompactPattern) = .empty;
    defer compact_patterns_all.deinit(allocator);
    var compact_pattern_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &compact_pattern_indexes);
    for (heading_levels.items) |heading_entry| {
        const pattern = compactPatternForHeading(allocator, heading_entry.level, heading_entry.title) orelse continue;
        if (covered_patterns.contains(pattern)) {
            allocator.free(pattern);
            continue;
        }
        const gop = try compact_pattern_indexes.getOrPut(allocator, pattern);
        if (!gop.found_existing) {
            gop.key_ptr.* = pattern;
            gop.value_ptr.* = compact_patterns_all.items.len;
            try compact_patterns_all.append(allocator, .{
                .pattern = gop.key_ptr.*,
                .count = heading_entry.count,
            });
        } else {
            allocator.free(pattern);
            compact_patterns_all.items[gop.value_ptr.*].count += heading_entry.count;
        }
    }
    std.mem.sortUnstable(GeneratedCompactPattern, compact_patterns_all.items, {}, generatedCompactPatternLessThan);

    const direct_capacity: usize = compact_pattern_seed.max_direct_pattern_count - compact_pattern_seed.static_direct_patterns.len;
    const direct_end: usize = @min(compact_patterns_all.items.len, direct_capacity);
    const escaped_end: usize = @min(compact_patterns_all.items.len, direct_end + @as(usize, 50));
    const extended_end: usize = @min(compact_patterns_all.items.len, direct_end + @as(usize, 250));

    var target_languages: std.ArrayList(GeneratedTargetLanguage) = .empty;
    defer target_languages.deinit(allocator);
    var target_language_indexes = std.StringHashMapUnmanaged(usize).empty;
    defer deinitOwnedStringMap(allocator, usize, &target_language_indexes);
    for (legacy.translation_target_languages) |entry| {
        const value = std.mem.trim(u8, entry.key, " \t\r\n");
        if (value.len == 0) continue;
        const gop = try target_language_indexes.getOrPut(allocator, value);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, value);
            gop.value_ptr.* = target_languages.items.len;
            try target_languages.append(allocator, .{
                .value = gop.key_ptr.*,
                .count = entry.count,
            });
        } else {
            target_languages.items[gop.value_ptr.*].count += entry.count;
        }
    }
    std.mem.sortUnstable(GeneratedTargetLanguage, target_languages.items, {}, generatedTargetLanguageLessThan);

    const build = BuildData{
        .compact_direct_patterns = try dupCompactPatternSliceAlloc(allocator, compact_patterns_all.items[0..direct_end]),
        .heading_specs = try dupHeadingSpecsAlloc(allocator, headings.items),
        .heading_level_specs = try dupHeadingLevelSpecsAlloc(allocator, heading_levels.items),
        .line_templates = try dupTemplateSpecsAlloc(allocator, line_templates.items),
        .compact_patterns = try dupCompactPatternSliceAlloc(allocator, compact_patterns_all.items[direct_end..escaped_end]),
        .compact_patterns_ext = try dupCompactPatternSliceAlloc(allocator, compact_patterns_all.items[escaped_end..extended_end]),
        .translation_templates = try dupTemplateSpecsAlloc(allocator, templates.items),
        .target_languages = try dupTargetLanguageSpecsAlloc(allocator, target_languages.items),
        .language_labels = try dupLanguageLabelSpecsAlloc(allocator, labels.items),
        .structure_fingerprint = 0,
    };
    var out = build;
    out.structure_fingerprint = computeStructureFingerprint(out);
    return out;
}

pub fn computeStructureFingerprint(build: BuildData) u32 {
    var hasher = std.hash.Wyhash.init(0x8f3c2d17c4a9b651);

    for (build.compact_direct_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (build.heading_level_specs) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        hasher.update(&[_]u8{entry.level});
        fingerprintUpdateString(&hasher, entry.title);
        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
    }
    for (build.heading_specs) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.title);
        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
    }
    for (build.line_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }
    for (build.compact_patterns) |entry| fingerprintUpdateString(&hasher, entry);
    for (build.compact_patterns_ext) |entry| fingerprintUpdateString(&hasher, entry);
    for (build.translation_templates) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.name);
    }
    for (build.target_languages) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.value);
    }
    for (build.language_labels) |entry| {
        var code_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        hasher.update(&code_buf);
        fingerprintUpdateString(&hasher, entry.label);
    }

    return @truncate(hasher.final());
}

pub fn generateStructureTableSourceAlloc(
    allocator: std.mem.Allocator,
    source_label: []const u8,
    build: BuildData,
) ![]u8 {
    try validateBuildData(build);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("// Generated from {s}.\n", .{source_label});
    try writer.writeAll(
        \\const std = @import("std");
        \\
        \\pub const SectionKind = enum(u8) {
        \\    lines = 0,
        \\    pos_lines = 1,
        \\    term_list = 2,
        \\    translations = 3,
        \\};
        \\
        \\pub const HeadingSpec = struct {
        \\    code: u16,
        \\    title: []const u8,
        \\    kind: SectionKind,
        \\};
        \\
        \\pub const HeadingLevelSpec = struct {
        \\    code: u16,
        \\    level: u8,
        \\    title: []const u8,
        \\    kind: SectionKind,
        \\};
        \\
        \\pub const compact_direct_patterns = [_][]const u8{
        \\
    );
    for (build.compact_direct_patterns) |entry| {
        try writer.writeAll("    ");
        try appendZigStringLiteral(writer, entry);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const heading_level_specs = [_]HeadingLevelSpec{
        \\
    );
    for (build.heading_level_specs) |entry| {
        try writer.print("    .{{ .code = {d}, .level = {d}, .title = ", .{ entry.code, entry.level });
        try appendZigStringLiteral(writer, entry.title);
        try writer.print(", .kind = .{s} }},\n", .{@tagName(entry.kind)});
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const heading_specs = [_]HeadingSpec{
        \\
    );
    for (build.heading_specs) |entry| {
        try writer.print("    .{{ .code = {d}, .title = ", .{entry.code});
        try appendZigStringLiteral(writer, entry.title);
        try writer.print(", .kind = .{s} }},\n", .{@tagName(entry.kind)});
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const LineTemplate = struct {
        \\    code: u16,
        \\    name: []const u8,
        \\};
        \\
        \\pub const line_templates = [_]LineTemplate{
        \\
    );
    for (build.line_templates) |entry| {
        try writer.print("    .{{ .code = {d}, .name = ", .{entry.code});
        try appendZigStringLiteral(writer, entry.name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const compact_patterns = [_][]const u8{
        \\
    );
    for (build.compact_patterns) |entry| {
        try writer.writeAll("    ");
        try appendZigStringLiteral(writer, entry);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const compact_patterns_ext = [_][]const u8{
        \\
    );
    for (build.compact_patterns_ext) |entry| {
        try writer.writeAll("    ");
        try appendZigStringLiteral(writer, entry);
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const TranslationTemplate = struct {
        \\    code: u16,
        \\    name: []const u8,
        \\};
        \\
        \\pub const translation_templates = [_]TranslationTemplate{
        \\
    );
    for (build.translation_templates) |entry| {
        try writer.print("    .{{ .code = {d}, .name = ", .{entry.code});
        try appendZigStringLiteral(writer, entry.name);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const TargetLanguage = struct {
        \\    code: u16,
        \\    value: []const u8,
        \\};
        \\
        \\pub const target_languages = [_]TargetLanguage{
        \\
    );
    for (build.target_languages) |entry| {
        try writer.print("    .{{ .code = {d}, .value = ", .{entry.code});
        try appendZigStringLiteral(writer, entry.value);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\pub const LanguageLabel = struct {
        \\    code: u16,
        \\    label: []const u8,
        \\};
        \\
        \\pub const language_labels = [_]LanguageLabel{
        \\
    );
    for (build.language_labels) |entry| {
        try writer.print("    .{{ .code = {d}, .label = ", .{entry.code});
        try appendZigStringLiteral(writer, entry.label);
        try writer.writeAll(" },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
        \\    var len_buf: [8]u8 = undefined;
        \\    std.mem.writeInt(u64, &len_buf, value.len, .little);
        \\    hasher.update(&len_buf);
        \\    hasher.update(value);
        \\}
        \\
        \\pub const structure_fingerprint: u32 = blk: {
        \\    @setEvalBranchQuota(1_000_000);
        \\    var hasher = std.hash.Wyhash.init(0x8f3c2d17c4a9b651);
        \\
        \\    for (compact_direct_patterns) |entry| fingerprintUpdateString(&hasher, entry);
        \\
        \\    for (heading_level_specs) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        hasher.update(&[_]u8{entry.level});
        \\        fingerprintUpdateString(&hasher, entry.title);
        \\        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
        \\    }
        \\    for (heading_specs) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.title);
        \\        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
        \\    }
        \\    for (line_templates) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.name);
        \\    }
        \\    for (compact_patterns) |entry| fingerprintUpdateString(&hasher, entry);
        \\    for (compact_patterns_ext) |entry| fingerprintUpdateString(&hasher, entry);
        \\    for (translation_templates) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.name);
        \\    }
        \\    for (target_languages) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.value);
        \\    }
        \\    for (language_labels) |entry| {
        \\        var code_buf: [2]u8 = undefined;
        \\        std.mem.writeInt(u16, &code_buf, entry.code, .little);
        \\        hasher.update(&code_buf);
        \\        fingerprintUpdateString(&hasher, entry.label);
        \\    }
        \\
        \\    break :blk @as(u32, @truncate(hasher.final()));
        \\};
        \\
    );

    return allocator.dupe(u8, out.written());
}

pub fn generateStructureTableSourceFromExactJsonAlloc(
    allocator: std.mem.Allocator,
    source_label: []const u8,
    json_bytes: []const u8,
) ![]u8 {
    var parsed = try parseExactStructureReportFromSlice(allocator, json_bytes);
    defer parsed.deinit();

    const expected = computeStructureFingerprint(parsed.value.build);
    if (parsed.value.build.structure_fingerprint != expected) return error.InvalidStructureFingerprint;
    return generateStructureTableSourceAlloc(allocator, source_label, parsed.value.build);
}

pub fn generateStructureTableSourceFromLegacyJsonAlloc(
    allocator: std.mem.Allocator,
    source_label: []const u8,
    json_bytes: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(LegacyBuildInputs, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var build = try buildDataFromLegacyAlloc(allocator, parsed.value);
    defer build.deinit(allocator);
    return generateStructureTableSourceAlloc(allocator, source_label, build);
}

fn validateBuildData(build: BuildData) !void {
    if (build.compact_direct_patterns.len + compact_pattern_seed.static_direct_patterns.len > compact_pattern_seed.max_direct_pattern_count) return error.TooManyGeneratedCompactPatterns;
    if (build.heading_specs.len + 1 > std.math.maxInt(u16)) return error.TooManyGeneratedHeadings;
    if (build.heading_level_specs.len + 1 > std.math.maxInt(u16)) return error.TooManyGeneratedHeadingLevels;
    if (build.line_templates.len > std.math.maxInt(u16)) return error.TooManyGeneratedTemplates;
    if (build.translation_templates.len > std.math.maxInt(u16)) return error.TooManyGeneratedTemplates;
    if (build.language_labels.len > std.math.maxInt(u16)) return error.TooManyGeneratedLabels;
    if (build.target_languages.len > std.math.maxInt(u16)) return error.TooManyGeneratedTargetLanguages;
}

fn parseHeadingLevelKey(key: []const u8) ?ParsedHeadingLevelKey {
    if (key.len < 4 or key[0] != 'L') return null;
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return null;
    if (colon <= 1 or colon + 1 >= key.len) return null;
    const level = std.fmt.parseInt(u8, key[1..colon], 10) catch return null;
    return .{ .level = level, .title = key[colon + 1 ..] };
}

fn deinitOwnedStringMap(
    allocator: std.mem.Allocator,
    comptime V: type,
    map: *std.StringHashMapUnmanaged(V),
) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit(allocator);
}

fn headingKindForTitle(profiles: []const LegacyHeadingProfile, title: []const u8) ?SectionKind {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.title, title)) {
            return sectionKindForParserKind(profile.parser_kind);
        }
    }
    return null;
}

fn isTranslationHeading(heading: []const u8) bool {
    return std.mem.eql(u8, heading, "Translations") or std.mem.eql(u8, heading, "Translate");
}

fn generatedHeadingLessThan(_: void, a: GeneratedHeading, b: GeneratedHeading) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.title, b.title);
}

fn generatedHeadingLevelLessThan(_: void, a: GeneratedHeadingLevel, b: GeneratedHeadingLevel) bool {
    if (a.count != b.count) return a.count > b.count;
    if (a.level != b.level) return a.level < b.level;
    return std.mem.lessThan(u8, a.title, b.title);
}

fn generatedLabelLessThan(_: void, a: GeneratedLabel, b: GeneratedLabel) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.label, b.label);
}

fn generatedTemplateLessThan(_: void, a: GeneratedTemplate, b: GeneratedTemplate) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn generatedCompactPatternLessThan(_: void, a: GeneratedCompactPattern, b: GeneratedCompactPattern) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.pattern, b.pattern);
}

fn generatedTargetLanguageLessThan(_: void, a: GeneratedTargetLanguage, b: GeneratedTargetLanguage) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.value, b.value);
}

fn compactPatternForHeading(allocator: std.mem.Allocator, level: u8, title: []const u8) ?[]u8 {
    if (level == 0 or title.len == 0) return null;
    if (level > 8) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..level) |_| out.append(allocator, '=') catch return null;
    out.appendSlice(allocator, title) catch return null;
    for (0..level) |_| out.append(allocator, '=') catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

fn dupHeadingSpecsAlloc(allocator: std.mem.Allocator, items: []const GeneratedHeading) ![]const HeadingSpec {
    const out = try allocator.alloc(HeadingSpec, items.len);
    for (items, out, 0..) |entry, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 2) orelse return error.TooManyGeneratedHeadings,
            .title = try allocator.dupe(u8, entry.title),
            .kind = entry.kind,
        };
    }
    return out;
}

fn dupHeadingLevelSpecsAlloc(allocator: std.mem.Allocator, items: []const GeneratedHeadingLevel) ![]const HeadingLevelSpec {
    const out = try allocator.alloc(HeadingLevelSpec, items.len);
    for (items, out, 0..) |entry, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 2) orelse return error.TooManyGeneratedHeadingLevels,
            .level = entry.level,
            .title = try allocator.dupe(u8, entry.title),
            .kind = entry.kind,
        };
    }
    return out;
}

fn dupTemplateSpecsAlloc(allocator: std.mem.Allocator, items: []const GeneratedTemplate) ![]const TemplateSpec {
    const out = try allocator.alloc(TemplateSpec, items.len);
    for (items, out, 0..) |entry, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 1) orelse return error.TooManyGeneratedTemplates,
            .name = try allocator.dupe(u8, entry.name),
        };
    }
    return out;
}

fn dupCompactPatternSliceAlloc(allocator: std.mem.Allocator, items: []const GeneratedCompactPattern) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, out) |entry, *slot| slot.* = try allocator.dupe(u8, entry.pattern);
    return out;
}

fn dupTargetLanguageSpecsAlloc(allocator: std.mem.Allocator, items: []const GeneratedTargetLanguage) ![]const TargetLanguage {
    const out = try allocator.alloc(TargetLanguage, items.len);
    for (items, out, 0..) |entry, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 1) orelse return error.TooManyGeneratedTargetLanguages,
            .value = try allocator.dupe(u8, entry.value),
        };
    }
    return out;
}

fn dupLanguageLabelSpecsAlloc(allocator: std.mem.Allocator, items: []const GeneratedLabel) ![]const LanguageLabel {
    const out = try allocator.alloc(LanguageLabel, items.len);
    for (items, out, 0..) |entry, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 1) orelse return error.TooManyGeneratedLabels,
            .label = try allocator.dupe(u8, entry.label),
        };
    }
    return out;
}

fn fingerprintUpdateString(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, value.len, .little);
    hasher.update(&len_buf);
    hasher.update(value);
}

fn appendZigStringLiteral(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => try writer.print("\\x{X:0>2}", .{byte}),
        }
    }
    try writer.writeByte('"');
}

test "buildDataFromLegacyAlloc keeps template names out of compact exact patterns" {
    var build = try buildDataFromLegacyAlloc(std.testing.allocator, .{
        .heading_profiles = &.{
            .{ .title = "Noun", .parser_kind = "part-of-speech", .count = 10 },
        },
        .templates_by_heading = &.{
            .{ .heading = "Noun", .template = "plural of", .count = 5 },
            .{ .heading = "Noun", .template = "custom form of", .count = 4 },
        },
    });
    defer build.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), build.compact_direct_patterns.len);
    try std.testing.expectEqual(@as(usize, 0), build.compact_patterns.len);
}

test "buildDataFromLegacyAlloc promotes exact heading lines into compact direct patterns" {
    var build = try buildDataFromLegacyAlloc(std.testing.allocator, .{
        .heading_profiles = &.{
            .{ .title = "Noun", .parser_kind = "part-of-speech", .count = 10 },
        },
        .headings_by_level = &.{
            .{ .key = "L3:Noun", .count = 10 },
        },
    });
    defer build.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), build.compact_direct_patterns.len);
    try std.testing.expectEqualStrings("===Noun===", build.compact_direct_patterns[0]);
}

test "generateStructureTableSourceFromExactJsonAlloc validates the embedded fingerprint" {
    var build = try buildDataFromLegacyAlloc(std.testing.allocator, .{
        .heading_profiles = &.{
            .{ .title = "Noun", .parser_kind = "part-of-speech", .count = 1 },
        },
        .templates_by_heading = &.{
            .{ .heading = "Translations", .template = "t", .count = 3 },
        },
    });
    defer build.deinit(std.testing.allocator);

    var report = ExactStructureReport{
        .input = "fixture.xml",
        .summary = .{
            .pages_scanned = 1,
            .namespace_zero_pages = 1,
            .language_entries = 1,
            .heading_level_jumps = 0,
            .content_before_subheading = 0,
            .unbalanced_sections = 0,
            .unclassified_heading_titles = 0,
        },
        .anomalies = .{},
        .build = build,
    };

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(report);

    const source = try generateStructureTableSourceFromExactJsonAlloc(std.testing.allocator, "fixture", writer.written());
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const heading_specs") != null);

    report.build.structure_fingerprint +%= 1;
    writer.clearRetainingCapacity();
    stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(report);
    try std.testing.expectError(
        error.InvalidStructureFingerprint,
        generateStructureTableSourceFromExactJsonAlloc(std.testing.allocator, "fixture", writer.written()),
    );
}
