const std = @import("std");
const builtin = @import("builtin");
const zxml = @import("zxml");

const encoder = @import("encoder");
const lua = @import("lua");
const wikitext = encoder.wikitext;
const xml_decode = encoder.xml_decode;
const required_path = @import("required_path.zig");
const structure_report = @import("shared_structure_report");
const structure_tables_support = @import("structure_tables_support.zig");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = true,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try printUsage(init.io, allocator);
        return;
    }
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(init.io, allocator);
            return;
        }
    }

    const options = try parseOptions(args[1..]);
    required_path.ensureExistsOrExit(init.io, options.input_path, "structure input");
    const stats = try analyzeDump(init.io, init.gpa, options);

    try printStdOut(
        init.io,
        allocator,
        "wrote {s}\npages={d}\nns0={d}\nlanguage_entries={d}\nparse_errors={d}\nheading_titles={d}\nunclassified_headings={d}\nanomalies={d}\n",
        .{
            options.output_path,
            stats.pages_seen,
            stats.namespace_zero_pages,
            stats.language_entries,
            stats.parse_errors,
            stats.heading_title_keys,
            stats.unknown_heading_keys,
            stats.anomaly_samples,
        },
    );
}

const Options = struct {
    input_path: []const u8 = "data/wiktionary.xml",
    output_path: []const u8 = "data/wiktionary-structure.bin",
    limit_entries: ?usize = null,
    worker_threads: ?usize = null,
    top_n: usize = 50,
    sample_limit: usize = 64,
};

const AnalyzeStats = struct {
    pages_seen: usize,
    namespace_zero_pages: usize,
    language_entries: usize,
    parse_errors: usize,
    heading_title_keys: usize,
    unknown_heading_keys: usize,
    anomaly_samples: usize,
};

const HeadingProfile = struct {
    family: []const u8,
    parser_kind: []const u8,
    canonical_title: []const u8,
};

const AnomalySample = struct {
    title: []const u8,
    kind: []const u8,
    detail: []const u8,
};

const SourcePageOffset = struct {
    page_start: u64,
    page_end: u64,
};

const LogicalBalance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,

    fn update(self: *LogicalBalance, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], "<!--")) {
                self.comments += 1;
                i += 3;
                continue;
            }
            if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "-->")) {
                if (self.comments != 0) self.comments -= 1;
                i += 2;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "{{")) {
                self.templates += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "}}")) {
                if (self.templates != 0) self.templates -= 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "[[")) {
                self.links += 1;
                i += 1;
                continue;
            }
            if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "]]")) {
                if (self.links != 0) self.links -= 1;
                i += 1;
                continue;
            }
        }
    }

    fn isOpen(self: LogicalBalance) bool {
        return self.templates != 0 or self.links != 0 or self.comments != 0;
    }
};

const Analyzer = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    options: Options,
    pages_seen: usize = 0,
    namespace_zero_pages: usize = 0,
    language_entries: usize = 0,
    parse_errors: usize = 0,
    heading_jumps: usize = 0,
    content_before_subheading: usize = 0,
    unbalanced_sections: usize = 0,
    heading_title_counts: std.StringHashMapUnmanaged(u64) = .empty,
    heading_level_counts: std.StringHashMapUnmanaged(u64) = .empty,
    heading_kind_counts: std.StringHashMapUnmanaged(u64) = .empty,
    parser_kind_counts: std.StringHashMapUnmanaged(u64) = .empty,
    unclassified_heading_counts: std.StringHashMapUnmanaged(u64) = .empty,
    heading_edge_counts: std.StringHashMapUnmanaged(u64) = .empty,
    line_signature_counts: std.StringHashMapUnmanaged(u64) = .empty,
    section_signature_counts: std.StringHashMapUnmanaged(u64) = .empty,
    family_signature_counts: std.StringHashMapUnmanaged(u64) = .empty,
    template_counts: std.StringHashMapUnmanaged(u64) = .empty,
    section_template_counts: std.StringHashMapUnmanaged(u64) = .empty,
    family_template_counts: std.StringHashMapUnmanaged(u64) = .empty,
    template_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    section_template_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    family_template_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    link_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    section_link_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    family_link_shape_counts: std.StringHashMapUnmanaged(u64) = .empty,
    translation_source_label_counts: std.StringHashMapUnmanaged(u64) = .empty,
    translation_target_lang_counts: std.StringHashMapUnmanaged(u64) = .empty,
    anomaly_kind_counts: std.StringHashMapUnmanaged(u64) = .empty,
    anomaly_samples: std.ArrayListUnmanaged(AnomalySample) = .empty,
    entry_direct_modules: std.StringHashMap(void),
    template_nodes: std.StringHashMap(lua.TemplateDependencyNode),
    module_nodes: std.StringHashMap([]const []const u8),
    entry_page_refs: std.StringHashMap(SourcePageOffset),
    template_page_refs: std.StringHashMap(SourcePageOffset),
    module_page_refs: std.StringHashMap(SourcePageOffset),
    key_scratch: std.ArrayList(u8) = .empty,
    shape_scratch: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator, options: Options) Analyzer {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .options = options,
            .entry_direct_modules = std.StringHashMap(void).init(gpa),
            .template_nodes = std.StringHashMap(lua.TemplateDependencyNode).init(gpa),
            .module_nodes = std.StringHashMap([]const []const u8).init(gpa),
            .entry_page_refs = std.StringHashMap(SourcePageOffset).init(gpa),
            .template_page_refs = std.StringHashMap(SourcePageOffset).init(gpa),
            .module_page_refs = std.StringHashMap(SourcePageOffset).init(gpa),
        };
    }

    fn deinit(self: *Analyzer) void {
        self.heading_title_counts.deinit(self.gpa);
        self.heading_level_counts.deinit(self.gpa);
        self.heading_kind_counts.deinit(self.gpa);
        self.parser_kind_counts.deinit(self.gpa);
        self.unclassified_heading_counts.deinit(self.gpa);
        self.heading_edge_counts.deinit(self.gpa);
        self.line_signature_counts.deinit(self.gpa);
        self.section_signature_counts.deinit(self.gpa);
        self.family_signature_counts.deinit(self.gpa);
        self.template_counts.deinit(self.gpa);
        self.section_template_counts.deinit(self.gpa);
        self.family_template_counts.deinit(self.gpa);
        self.template_shape_counts.deinit(self.gpa);
        self.section_template_shape_counts.deinit(self.gpa);
        self.family_template_shape_counts.deinit(self.gpa);
        self.link_shape_counts.deinit(self.gpa);
        self.section_link_shape_counts.deinit(self.gpa);
        self.family_link_shape_counts.deinit(self.gpa);
        self.translation_source_label_counts.deinit(self.gpa);
        self.translation_target_lang_counts.deinit(self.gpa);
        self.anomaly_kind_counts.deinit(self.gpa);
        self.anomaly_samples.deinit(self.gpa);
        self.entry_direct_modules.deinit();
        self.template_nodes.deinit();
        self.module_nodes.deinit();
        self.entry_page_refs.deinit();
        self.template_page_refs.deinit();
        self.module_page_refs.deinit();
        self.key_scratch.deinit(self.gpa);
        self.shape_scratch.deinit(self.gpa);
        self.arena.deinit();
    }

    fn stats(self: *const Analyzer) AnalyzeStats {
        return .{
            .pages_seen = self.pages_seen,
            .namespace_zero_pages = self.namespace_zero_pages,
            .language_entries = self.language_entries,
            .parse_errors = self.parse_errors,
            .heading_title_keys = self.heading_title_counts.count(),
            .unknown_heading_keys = self.unclassified_heading_counts.count(),
            .anomaly_samples = self.anomaly_samples.items.len,
        };
    }

    fn keyAllocator(self: *Analyzer) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn bump(self: *Analyzer, map: *std.StringHashMapUnmanaged(u64), key: []const u8) !void {
        if (map.getPtr(key)) |value| {
            value.* += 1;
            return;
        }
        const owned = try self.keyAllocator().dupe(u8, key);
        try map.put(self.gpa, owned, 1);
    }

    fn bumpComposite(self: *Analyzer, map: *std.StringHashMapUnmanaged(u64), left: []const u8, right: []const u8, sep: []const u8) !void {
        self.key_scratch.items.len = 0;
        try self.key_scratch.appendSlice(self.gpa, left);
        try self.key_scratch.appendSlice(self.gpa, sep);
        try self.key_scratch.appendSlice(self.gpa, right);
        try self.bump(map, self.key_scratch.items);
    }

    fn addAnomaly(self: *Analyzer, title: []const u8, kind: []const u8, detail: []const u8) !void {
        try self.bump(&self.anomaly_kind_counts, kind);
        if (self.anomaly_samples.items.len >= self.options.sample_limit) return;

        try self.anomaly_samples.append(self.gpa, .{
            .title = try self.keyAllocator().dupe(u8, title),
            .kind = try self.keyAllocator().dupe(u8, kind),
            .detail = try self.keyAllocator().dupe(u8, detail),
        });
    }

    fn appendAnomalySample(self: *Analyzer, sample: AnomalySample) !void {
        if (self.anomaly_samples.items.len >= self.options.sample_limit) return;
        try self.anomaly_samples.append(self.gpa, .{
            .title = try self.keyAllocator().dupe(u8, sample.title),
            .kind = try self.keyAllocator().dupe(u8, sample.kind),
            .detail = try self.keyAllocator().dupe(u8, sample.detail),
        });
    }

    fn mergeCountMap(self: *Analyzer, dst: *std.StringHashMapUnmanaged(u64), src: std.StringHashMapUnmanaged(u64)) !void {
        var it = src.iterator();
        while (it.next()) |entry| {
            if (dst.getPtr(entry.key_ptr.*)) |value| {
                value.* += entry.value_ptr.*;
                continue;
            }
            const owned = try self.keyAllocator().dupe(u8, entry.key_ptr.*);
            try dst.put(self.gpa, owned, entry.value_ptr.*);
        }
    }

    fn cloneStringSlice(self: *Analyzer, values: []const []const u8) ![]const []const u8 {
        const out = try self.keyAllocator().alloc([]const u8, values.len);
        for (values, 0..) |value, idx| out[idx] = try self.keyAllocator().dupe(u8, value);
        return out;
    }

    fn mergeUniqueStringSlice(self: *Analyzer, existing: []const []const u8, incoming: []const []const u8) ![]const []const u8 {
        var additional: usize = 0;
        for (incoming) |value| {
            if (!stringSliceContains(existing, value)) additional += 1;
        }
        if (additional == 0) return existing;

        const out = try self.keyAllocator().alloc([]const u8, existing.len + additional);
        @memcpy(out[0..existing.len], existing);
        var out_idx = existing.len;
        for (incoming) |value| {
            if (stringSliceContains(existing, value)) continue;
            out[out_idx] = try self.keyAllocator().dupe(u8, value);
            out_idx += 1;
        }
        return out;
    }

    fn mergeStringSet(self: *Analyzer, dst: *std.StringHashMap(void), src: *const std.StringHashMap(void)) !void {
        var it = src.iterator();
        while (it.next()) |entry| {
            if (dst.contains(entry.key_ptr.*)) continue;
            try dst.put(try self.keyAllocator().dupe(u8, entry.key_ptr.*), {});
        }
    }

    fn mergeTemplateNodes(self: *Analyzer, src: *const std.StringHashMap(lua.TemplateDependencyNode)) !void {
        var it = src.iterator();
        while (it.next()) |entry| {
            if (self.template_nodes.getPtr(entry.key_ptr.*)) |existing| {
                existing.template_deps = try self.mergeUniqueStringSlice(existing.template_deps, entry.value_ptr.template_deps);
                existing.direct_modules = try self.mergeUniqueStringSlice(existing.direct_modules, entry.value_ptr.direct_modules);
                continue;
            }
            try self.template_nodes.put(
                try self.keyAllocator().dupe(u8, entry.key_ptr.*),
                .{
                    .template_deps = try self.cloneStringSlice(entry.value_ptr.template_deps),
                    .direct_modules = try self.cloneStringSlice(entry.value_ptr.direct_modules),
                },
            );
        }
    }

    fn mergeModuleNodes(self: *Analyzer, src: *const std.StringHashMap([]const []const u8)) !void {
        var it = src.iterator();
        while (it.next()) |entry| {
            if (self.module_nodes.getPtr(entry.key_ptr.*)) |existing| {
                existing.* = try self.mergeUniqueStringSlice(existing.*, entry.value_ptr.*);
                continue;
            }
            try self.module_nodes.put(
                try self.keyAllocator().dupe(u8, entry.key_ptr.*),
                try self.cloneStringSlice(entry.value_ptr.*),
            );
        }
    }

    fn mergeSourcePageRefs(self: *Analyzer, dst: *std.StringHashMap(SourcePageOffset), src: *const std.StringHashMap(SourcePageOffset)) !void {
        var it = src.iterator();
        while (it.next()) |entry| {
            if (dst.contains(entry.key_ptr.*)) continue;
            try dst.put(try self.keyAllocator().dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
        }
    }

    fn rememberTemplatePage(self: *Analyzer, allocator: std.mem.Allocator, title: []const u8, source: []const u8, page_start: usize, page_end: usize) !void {
        _ = allocator;
        _ = source;
        if (!std.mem.startsWith(u8, title, "Template:")) return;

        const canonical = try lua.canonicalTemplateNameAlloc(self.gpa, title["Template:".len..]);
        defer self.gpa.free(canonical);

        if (!self.template_page_refs.contains(canonical)) {
            try self.template_page_refs.put(
                try self.keyAllocator().dupe(u8, canonical),
                .{ .page_start = @intCast(page_start), .page_end = @intCast(page_end) },
            );
        }
    }

    fn rememberEntryPage(self: *Analyzer, title: []const u8, page_start: usize, page_end: usize) !void {
        if (self.entry_page_refs.contains(title)) return;
        try self.entry_page_refs.put(
            try self.keyAllocator().dupe(u8, title),
            .{ .page_start = @intCast(page_start), .page_end = @intCast(page_end) },
        );
    }

    fn rememberModulePage(self: *Analyzer, allocator: std.mem.Allocator, title: []const u8, source: []const u8, page_start: usize, page_end: usize) !void {
        _ = allocator;
        _ = source;
        if (!std.mem.startsWith(u8, title, "Module:")) return;

        const canonical = try lua.canonicalModuleNameAlloc(self.gpa, title["Module:".len..]);
        defer self.gpa.free(canonical);

        if (!self.module_page_refs.contains(canonical)) {
            try self.module_page_refs.put(
                try self.keyAllocator().dupe(u8, canonical),
                .{ .page_start = @intCast(page_start), .page_end = @intCast(page_end) },
            );
        }
    }

    fn rememberEntryInvokeModules(self: *Analyzer, line: []const u8) !void {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "{{#invoke:")) |start| {
            var name_start = start + "{{#invoke:".len;
            while (name_start < line.len and std.ascii.isWhitespace(line[name_start])) : (name_start += 1) {}
            var name_end = name_start;
            while (name_end < line.len and line[name_end] != '|' and line[name_end] != '}' and line[name_end] != '\n') : (name_end += 1) {}
            const raw_name = std.mem.trim(u8, line[name_start..name_end], " \t");
            if (raw_name.len != 0) {
                const canonical = try lua.canonicalModuleNameAlloc(self.gpa, raw_name);
                defer self.gpa.free(canonical);
                if (!self.entry_direct_modules.contains(canonical)) {
                    try self.entry_direct_modules.put(try self.keyAllocator().dupe(u8, canonical), {});
                }
            }
            cursor = name_end;
        }
    }

    fn mergeFrom(self: *Analyzer, other: *const Analyzer) !void {
        self.pages_seen += other.pages_seen;
        self.namespace_zero_pages += other.namespace_zero_pages;
        self.language_entries += other.language_entries;
        self.parse_errors += other.parse_errors;
        self.heading_jumps += other.heading_jumps;
        self.content_before_subheading += other.content_before_subheading;
        self.unbalanced_sections += other.unbalanced_sections;

        try self.mergeCountMap(&self.heading_title_counts, other.heading_title_counts);
        try self.mergeCountMap(&self.heading_level_counts, other.heading_level_counts);
        try self.mergeCountMap(&self.heading_kind_counts, other.heading_kind_counts);
        try self.mergeCountMap(&self.parser_kind_counts, other.parser_kind_counts);
        try self.mergeCountMap(&self.unclassified_heading_counts, other.unclassified_heading_counts);
        try self.mergeCountMap(&self.heading_edge_counts, other.heading_edge_counts);
        try self.mergeCountMap(&self.line_signature_counts, other.line_signature_counts);
        try self.mergeCountMap(&self.section_signature_counts, other.section_signature_counts);
        try self.mergeCountMap(&self.family_signature_counts, other.family_signature_counts);
        try self.mergeCountMap(&self.template_counts, other.template_counts);
        try self.mergeCountMap(&self.section_template_counts, other.section_template_counts);
        try self.mergeCountMap(&self.family_template_counts, other.family_template_counts);
        try self.mergeCountMap(&self.template_shape_counts, other.template_shape_counts);
        try self.mergeCountMap(&self.section_template_shape_counts, other.section_template_shape_counts);
        try self.mergeCountMap(&self.family_template_shape_counts, other.family_template_shape_counts);
        try self.mergeCountMap(&self.link_shape_counts, other.link_shape_counts);
        try self.mergeCountMap(&self.section_link_shape_counts, other.section_link_shape_counts);
        try self.mergeCountMap(&self.family_link_shape_counts, other.family_link_shape_counts);
        try self.mergeCountMap(&self.translation_source_label_counts, other.translation_source_label_counts);
        try self.mergeCountMap(&self.translation_target_lang_counts, other.translation_target_lang_counts);
        try self.mergeCountMap(&self.anomaly_kind_counts, other.anomaly_kind_counts);
        try self.mergeStringSet(&self.entry_direct_modules, &other.entry_direct_modules);
        try self.mergeTemplateNodes(&other.template_nodes);
        try self.mergeModuleNodes(&other.module_nodes);
        try self.mergeSourcePageRefs(&self.entry_page_refs, &other.entry_page_refs);
        try self.mergeSourcePageRefs(&self.template_page_refs, &other.template_page_refs);
        try self.mergeSourcePageRefs(&self.module_page_refs, &other.module_page_refs);

        for (other.anomaly_samples.items) |sample| try self.appendAnomalySample(sample);
    }

    fn recordPageParseError(self: *Analyzer, page_fragment: []const u8, page_start: usize, err: anyerror) !void {
        self.parse_errors += 1;

        const title = pageTitleHint(page_fragment) orelse "(unknown page)";
        self.key_scratch.items.len = 0;
        try self.key_scratch.appendSlice(self.gpa, @errorName(err));
        try self.key_scratch.appendSlice(self.gpa, " @");
        try appendUnsignedDecimal(&self.key_scratch, self.gpa, page_start);
        try self.addAnomaly(title, "page-parse-error", self.key_scratch.items);
    }

    fn analyzeEntry(self: *Analyzer, title: []const u8, language_title: []const u8, language_section: []const u8) !void {
        self.language_entries += 1;

        var active_titles: [7][]const u8 = [_][]const u8{""} ** 7;
        active_titles[2] = language_title;
        var seen_subheading = false;
        var balance: LogicalBalance = .{};

        var lines = std.mem.splitScalar(u8, language_section, '\n');
        while (lines.next()) |raw_input| {
            const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
            balance.update(raw_line);

            if (wikitext.parseHeadingLine(raw_line)) |heading| {
                try self.recordHeading(title, heading, &active_titles, language_title);
                if (heading.level >= 3) seen_subheading = true;
                continue;
            }

            const trimmed = std.mem.trim(u8, raw_line, " \t");
            try self.rememberEntryInvokeModules(raw_line);
            const scope = currentHeadingLabel(&active_titles, language_title);
            const profile = currentHeadingProfile(&active_titles, language_title);
            const family = profile.family;
            const sig = lineSignature(trimmed);

            try self.bump(&self.line_signature_counts, sig);
            try self.bumpComposite(&self.section_signature_counts, scope, sig, "\t");
            try self.bumpComposite(&self.family_signature_counts, family, sig, "\t");
            try self.extractTemplates(scope, family, trimmed);
            try self.extractLinks(scope, family, trimmed);
            try self.analyzeStructuredLine(profile, trimmed);

            if (!seen_subheading and trimmed.len != 0) {
                self.content_before_subheading += 1;
                try self.addAnomaly(title, "content-before-subheading", trimmed);
            }
        }

        if (balance.isOpen()) {
            self.unbalanced_sections += 1;
            try self.addAnomaly(title, "unbalanced-markup", "Language section ended with open template/link/comment state");
        }
    }

    fn recordHeading(self: *Analyzer, title: []const u8, heading: wikitext.ParsedHeading, active_titles: *[7][]const u8, language_title: []const u8) !void {
        try self.bump(&self.heading_title_counts, heading.title);
        self.key_scratch.items.len = 0;
        try appendHeadingLabel(&self.key_scratch, self.gpa, heading.level, heading.title);
        try self.bump(&self.heading_level_counts, self.key_scratch.items);

        const profile = classifyHeadingTitle(heading.title, heading.level);
        try self.bump(&self.heading_kind_counts, profile.family);
        try self.bump(&self.parser_kind_counts, profile.parser_kind);
        if (!isFullyClassifiedHeading(profile)) {
            try self.bump(&self.unclassified_heading_counts, heading.title);
            try self.addAnomaly(title, "unclassified-heading", heading.title);
        }

        const deepest_before = deepestHeadingLevel(active_titles.*);
        if (heading.level > deepest_before + 1) {
            self.heading_jumps += 1;
            self.key_scratch.items.len = 0;
            try self.key_scratch.appendSlice(self.gpa, "jump from L");
            try appendUnsignedDecimal(&self.key_scratch, self.gpa, deepest_before);
            try self.key_scratch.appendSlice(self.gpa, " to L");
            try appendUnsignedDecimal(&self.key_scratch, self.gpa, heading.level);
            try self.key_scratch.appendSlice(self.gpa, ": ");
            try self.key_scratch.appendSlice(self.gpa, heading.title);
            try self.addAnomaly(title, "heading-level-jump", self.key_scratch.items);
        }

        try self.validateHeadingPlacement(title, active_titles.*, heading, profile, language_title);
        try self.recordHeadingEdge(active_titles.*, heading);

        active_titles[heading.level] = heading.title;
        var level: usize = heading.level + 1;
        while (level < active_titles.len) : (level += 1) active_titles[level] = "";
    }

    fn recordHeadingEdge(self: *Analyzer, active_titles: [7][]const u8, heading: wikitext.ParsedHeading) !void {
        self.key_scratch.items.len = 0;
        try appendHeadingLabel(&self.key_scratch, self.gpa, parentHeadingLevel(active_titles, heading.level), parentHeadingTitle(active_titles, heading.level));
        try self.key_scratch.appendSlice(self.gpa, " -> ");
        try appendHeadingLabel(&self.key_scratch, self.gpa, heading.level, heading.title);
        try self.bump(&self.heading_edge_counts, self.key_scratch.items);
    }

    fn analyzeStructuredLine(self: *Analyzer, profile: HeadingProfile, line: []const u8) !void {
        if (line.len == 0) return;

        if (std.mem.eql(u8, profile.parser_kind, "translations")) {
            try self.analyzeTranslationsLine(line);
            return;
        }
        if (std.mem.eql(u8, profile.parser_kind, "part-of-speech")) return;
        if (std.mem.eql(u8, profile.parser_kind, "pronunciation")) return;
        if (std.mem.eql(u8, profile.parser_kind, "etymology")) return;
        if (std.mem.eql(u8, profile.parser_kind, "alternative-forms")) return;
        if (std.mem.eql(u8, profile.parser_kind, "relations")) return;
        if (std.mem.eql(u8, profile.parser_kind, "descendants")) return;
        if (std.mem.eql(u8, profile.parser_kind, "inflection")) return;
        if (std.mem.eql(u8, profile.parser_kind, "citations")) return;
        if (std.mem.eql(u8, profile.parser_kind, "navigation")) return;
        if (std.mem.eql(u8, profile.parser_kind, "notes")) return;
        if (std.mem.eql(u8, profile.parser_kind, "language-root")) return;
        if (std.mem.eql(u8, profile.parser_kind, "meta")) return;
    }

    fn analyzeTranslationsLine(self: *Analyzer, line: []const u8) !void {
        if (parseTranslationSourceLabel(line)) |label| {
            try self.bump(&self.translation_source_label_counts, label);
        }

        try scanTemplates(line, self, struct {
            fn onTemplate(ctx: *Analyzer, name: []const u8, first_param: ?[]const u8) !void {
                if (!isTranslationTemplate(name)) return;
                const lang = first_param orelse return;
                if (lang.len == 0) return;
                try ctx.bump(&ctx.translation_target_lang_counts, lang);
            }
        }.onTemplate);
    }

    fn validateHeadingPlacement(self: *Analyzer, title: []const u8, active_titles: [7][]const u8, heading: wikitext.ParsedHeading, profile: HeadingProfile, language_title: []const u8) !void {
        const parent_level = parentHeadingLevel(active_titles, heading.level);
        const parent_title = if (parent_level == 0) "ROOT" else active_titles[parent_level];
        const parent_kind = if (parent_level == 0)
            "root"
        else
            classifyHeadingTitle(if (parent_level == 2) language_title else parent_title, parent_level).family;

        if (!isExpectedHeadingLevel(profile.family, heading.level)) {
            self.key_scratch.items.len = 0;
            try self.key_scratch.appendSlice(self.gpa, heading.title);
            try self.key_scratch.appendSlice(self.gpa, " at L");
            try appendUnsignedDecimal(&self.key_scratch, self.gpa, heading.level);
            try self.addAnomaly(title, "unexpected-heading-level", self.key_scratch.items);
        }

        if (!isExpectedHeadingParent(profile.family, parent_kind)) {
            self.key_scratch.items.len = 0;
            try self.key_scratch.appendSlice(self.gpa, heading.title);
            try self.key_scratch.appendSlice(self.gpa, " under ");
            try self.key_scratch.appendSlice(self.gpa, parent_title);
            try self.addAnomaly(title, "unexpected-heading-parent", self.key_scratch.items);
        }
    }

    fn extractTemplates(self: *Analyzer, scope: []const u8, family: []const u8, line: []const u8) !void {
        var pos: usize = 0;
        while (true) {
            const open = std.mem.indexOfPos(u8, line, pos, "{{") orelse break;
            const end = findBalancedMarkup(line, open, "{{", "}}") orelse {
                pos = open + 2;
                continue;
            };

            const body = line[open + 2 .. end];
            const name = templateNameFromBody(body);
            if (name.len != 0 and name.len <= 80) {
                try self.bump(&self.template_counts, name);
                try self.bumpComposite(&self.section_template_counts, scope, name, "\t");
                try self.bumpComposite(&self.family_template_counts, family, name, "\t");

                const shape = try templateShapeAlloc(self.gpa, body);
                defer self.gpa.free(shape);
                try self.bump(&self.template_shape_counts, shape);
                try self.bumpComposite(&self.section_template_shape_counts, scope, shape, "\t");
                try self.bumpComposite(&self.family_template_shape_counts, family, shape, "\t");
            }

            pos = open + 2;
        }
    }

    fn extractLinks(self: *Analyzer, scope: []const u8, family: []const u8, line: []const u8) !void {
        var pos: usize = 0;
        while (pos < line.len) {
            if (pos + 2 <= line.len and std.mem.eql(u8, line[pos .. pos + 2], "[[")) {
                const end = findBalancedMarkup(line, pos, "[[", "]]") orelse {
                    pos += 2;
                    continue;
                };
                const shape = try internalLinkShapeAlloc(self.gpa, line[pos + 2 .. end]);
                defer self.gpa.free(shape);
                try self.bump(&self.link_shape_counts, shape);
                try self.bumpComposite(&self.section_link_shape_counts, scope, shape, "\t");
                try self.bumpComposite(&self.family_link_shape_counts, family, shape, "\t");
                pos += 2;
                continue;
            }

            if (line[pos] == '[' and (pos + 1 >= line.len or line[pos + 1] != '[')) {
                const end = std.mem.indexOfScalarPos(u8, line, pos + 1, ']') orelse {
                    pos += 1;
                    continue;
                };
                const body = std.mem.trim(u8, line[pos + 1 .. end], " \t");
                if (std.mem.startsWith(u8, body, "http://") or std.mem.startsWith(u8, body, "https://")) {
                    const shape = externalLinkShape(body);
                    try self.bump(&self.link_shape_counts, shape);
                    try self.bumpComposite(&self.section_link_shape_counts, scope, shape, "\t");
                    try self.bumpComposite(&self.family_link_shape_counts, family, shape, "\t");
                }
            }
            pos += 1;
        }
    }
};

const PageCapture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();

        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 2 and std.mem.eql(u8, name, "text") and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            self.text_raw = node.leadingTextRaw();
        }
        return true;
    }
};

const AnalyzeChunk = struct {
    start: usize,
    end: usize,
};

const AnalyzeChunkResult = struct {
    analyzer: Analyzer,
    err: ?anyerror = null,
};

const AnalyzeChunkJob = struct {
    mapped: []const u8,
    chunks: []const AnalyzeChunk,
    next_chunk_index: *std.atomic.Value(usize),
    result: *AnalyzeChunkResult,
    progress: *StructureProgress,
};

const StructureProgress = struct {
    const refresh_interval_ns = std.time.ns_per_s / 20;

    const Phase = enum {
        scanning,
        writing,
        done,
    };

    total_input_bytes: usize,
    scanned_input_bytes: std.atomic.Value(usize) = .init(0),
    scanned_pages: std.atomic.Value(usize) = .init(0),
    scanned_language_entries: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    phase: Phase = .scanning,
    scanning_parallel: bool = false,
    last_percent: u8 = 255,
    last_primary: usize = std.math.maxInt(usize),
    last_secondary: usize = std.math.maxInt(usize),
    last_render_ns: i96 = 0,

    fn init(total_input_bytes: usize) StructureProgress {
        return .{ .total_input_bytes = total_input_bytes };
    }

    fn setScanningParallel(self: *StructureProgress, scanning_parallel: bool) void {
        self.scanning_parallel = scanning_parallel;
    }

    fn scanAdvance(self: *StructureProgress, input_bytes_delta: usize, page_delta: usize, language_entry_delta: usize) void {
        const consumed_input_bytes = self.scanned_input_bytes.fetchAdd(input_bytes_delta, .monotonic) + input_bytes_delta;
        const pages = self.scanned_pages.fetchAdd(page_delta, .monotonic) + page_delta;
        const language_entries = self.scanned_language_entries.fetchAdd(language_entry_delta, .monotonic) + language_entry_delta;
        const percent = if (self.total_input_bytes == 0)
            97
        else
            @as(u8, @intCast(@min(97, (consumed_input_bytes * 97) / self.total_input_bytes)));
        self.render(.scanning, percent, pages, language_entries);
    }

    fn finishScanning(self: *StructureProgress) void {
        const pages = self.scanned_pages.load(.monotonic);
        const language_entries = self.scanned_language_entries.load(.monotonic);
        self.render(.scanning, 97, pages, language_entries);
    }

    fn setWriting(self: *StructureProgress, pages: usize, language_entries: usize) void {
        self.render(.writing, 98, pages, language_entries);
    }

    fn finish(self: *StructureProgress, pages: usize, language_entries: usize) void {
        self.render(.done, 100, pages, language_entries);
        if (!builtin.is_test) std.debug.print("\n", .{});
    }

    fn render(self: *StructureProgress, phase: Phase, percent: u8, primary: usize, secondary: usize) void {
        if (builtin.is_test) return;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.phase == phase and self.last_percent == percent and self.last_primary == primary and self.last_secondary == secondary) return;
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (!shouldRenderNow(self, phase, now_ns)) return;

        self.phase = phase;
        self.last_percent = percent;
        self.last_primary = primary;
        self.last_secondary = secondary;
        self.last_render_ns = now_ns;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        switch (phase) {
            .scanning, .done => std.debug.print(
                "\rscan struct [{s}] {d:>3}% {s} (pages={d} language_entries={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
            .writing => std.debug.print(
                "\rscan struct [{s}] {d:>3}% {s} (pages={d} language_entries={d})",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            ),
        }
    }

    fn phaseLabel(self: *const StructureProgress, phase: Phase) []const u8 {
        return switch (phase) {
            .scanning => if (self.scanning_parallel) "scan xml in parallel" else "scan xml",
            .writing => "build deps + write report",
            .done => "ready",
        };
    }

    fn shouldRenderNow(self: *const StructureProgress, phase: Phase, now_ns: i96) bool {
        if (phase == .done or phase != self.phase) return true;
        return now_ns - self.last_render_ns >= refresh_interval_ns;
    }
};

fn analyzeDump(io: std.Io, allocator: std.mem.Allocator, options: Options) !AnalyzeStats {
    var input = try mmapReadOnlyPath(io, options.input_path);
    defer input.deinit();

    var analyzer = Analyzer.init(allocator, options);
    defer analyzer.deinit();

    var stream_parser = StreamParser.init(allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    const stat = input.stat;
    if (stat.size == 0) return analyzer.stats();

    const input_bytes = input.bytes();
    var progress = StructureProgress.init(@intCast(stat.size));
    const worker_count = analyzeThreadCount(input_bytes.len, options.limit_entries, options.worker_threads);
    progress.setScanningParallel(worker_count > 1);
    if (worker_count == 1) {
        try processMappedInputSequential(
            input_bytes,
            &stream_parser,
            &page_arena,
            &analyzer,
            &progress,
        );
    } else {
        try processMappedInputParallel(
            allocator,
            input_bytes,
            options,
            worker_count,
            &analyzer,
            &progress,
        );
    }
    progress.finishScanning();
    progress.setWriting(analyzer.pages_seen, analyzer.language_entries);
    try writeReport(io, allocator, &analyzer);
    progress.finish(analyzer.pages_seen, analyzer.language_entries);
    return analyzer.stats();
}

const MappedReadOnlyFile = struct {
    stat: std.Io.File.Stat,
    mapping: ?[]align(std.heap.page_size_min) const u8,

    fn bytes(self: MappedReadOnlyFile) []const u8 {
        return if (self.mapping) |mapping|
            mapping[0..@as(usize, @intCast(self.stat.size))]
        else
            &.{};
    }

    fn deinit(self: *MappedReadOnlyFile) void {
        if (self.mapping) |mapping| std.posix.munmap(mapping);
        self.mapping = null;
    }
};

fn mmapReadOnlyPath(io: std.Io, path: []const u8) !MappedReadOnlyFile {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    var file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) {
        return .{
            .stat = stat,
            .mapping = null,
        };
    }

    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const mapping = try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    return .{
        .stat = stat,
        .mapping = mapping,
    };
}

fn analyzeThreadCount(total_input_bytes: usize, limit_entries: ?usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or limit_entries != null) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), requested);
    if (total_input_bytes < (32 << 20)) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), cpu_count);
}

fn collectAnalyzeChunksAlloc(allocator: std.mem.Allocator, mapped: []const u8, desired_chunks: usize) ![]AnalyzeChunk {
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(allocator);
    try starts.append(allocator, 0);

    for (1..desired_chunks) |chunk_index| {
        const approx = @divTrunc(mapped.len * chunk_index, desired_chunks);
        const page_start = std.mem.indexOfPos(u8, mapped, approx, "<page>") orelse continue;
        if (page_start <= starts.items[starts.items.len - 1]) continue;
        try starts.append(allocator, page_start);
    }
    try starts.append(allocator, mapped.len);

    const chunks = try allocator.alloc(AnalyzeChunk, starts.items.len - 1);
    for (chunks, 0..) |*chunk, idx| {
        chunk.* = .{
            .start = starts.items[idx],
            .end = starts.items[idx + 1],
        };
    }
    return chunks;
}

fn processMappedInputParallel(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    options: Options,
    worker_count: usize,
    analyzer: *Analyzer,
    progress: *StructureProgress,
) !void {
    const desired_chunks = @max(worker_count, worker_count * 4);
    const chunks = try collectAnalyzeChunksAlloc(allocator, mapped, desired_chunks);
    defer allocator.free(chunks);

    const results = try allocator.alloc(AnalyzeChunkResult, worker_count);
    defer {
        for (results) |*result| result.analyzer.deinit();
        allocator.free(results);
    }
    for (results) |*result| {
        result.* = .{
            .analyzer = Analyzer.init(std.heap.smp_allocator, options),
        };
    }

    const jobs = try allocator.alloc(AnalyzeChunkJob, worker_count);
    defer allocator.free(jobs);
    var next_chunk_index: std.atomic.Value(usize) = .init(0);
    for (jobs, results) |*job, *result| {
        job.* = .{
            .mapped = mapped,
            .chunks = chunks,
            .next_chunk_index = &next_chunk_index,
            .result = result,
            .progress = progress,
        };
    }

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();

    for (jobs[1..], threads) |*job, *thread| {
        thread.* = try std.Thread.spawn(.{}, processAnalyzeChunks, .{job});
        started_threads += 1;
    }
    processAnalyzeChunks(&jobs[0]);
    for (threads[0..started_threads]) |thread| thread.join();

    for (results) |*result| {
        if (result.err) |err| return err;
        try analyzer.mergeFrom(&result.analyzer);
    }
}

fn processAnalyzeChunks(job: *AnalyzeChunkJob) void {
    processAnalyzeChunksFallible(job) catch |err| {
        job.result.err = err;
    };
}

fn processAnalyzeChunksFallible(job: *AnalyzeChunkJob) !void {
    var parser = StreamParser.init(std.heap.smp_allocator);
    defer parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer page_arena.deinit();

    while (true) {
        const chunk_index = job.next_chunk_index.fetchAdd(1, .monotonic);
        if (chunk_index >= job.chunks.len) break;

        const chunk = job.chunks[chunk_index];
        var consumed = chunk.start;
        while (true) {
            const start = std.mem.indexOfPos(u8, job.mapped, consumed, "<page>") orelse break;
            if (start >= chunk.end) break;
            const end_start = std.mem.indexOfPos(u8, job.mapped, start, "</page>") orelse break;
            const page_end = end_start + "</page>".len;
            if (page_end > chunk.end) break;

            const page_allocator = page_arena.allocator();
            const language_entries_before = job.result.analyzer.language_entries;
            processPageFragment(page_allocator, &parser, job.mapped[start..page_end], start, page_end, &job.result.analyzer) catch |err| {
                try job.result.analyzer.recordPageParseError(job.mapped[start..page_end], start, err);
            };
            job.progress.scanAdvance(page_end - start, 1, job.result.analyzer.language_entries - language_entries_before);
            consumed = page_end;
            _ = page_arena.reset(.retain_capacity);
        }
    }
}

fn processMappedInputSequential(
    mapped: []const u8,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    analyzer: *Analyzer,
    progress: *StructureProgress,
) !void {
    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        const language_entries_before = analyzer.language_entries;
        processPageFragment(page_allocator, stream_parser, mapped[start..page_end], start, page_end, analyzer) catch |err| {
            try analyzer.recordPageParseError(mapped[start..page_end], start, err);
        };
        progress.scanAdvance(page_end - start, 1, analyzer.language_entries - language_entries_before);
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);

        if (analyzer.options.limit_entries) |limit| {
            if (analyzer.language_entries >= limit) break;
        }
    }
}

fn processPageFragment(
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    page_start: usize,
    page_end: usize,
    analyzer: *Analyzer,
) !void {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);
    analyzer.pages_seen += 1;

    const ns_raw = capture.ns_raw orelse return;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return;
    var decoded_title = try decodeXmlBorrowOrAlloc(allocator, capture.title_raw orelse return);
    defer decoded_title.deinit(allocator);
    const title = decoded_title.slice();

    const text_raw = capture.text_raw orelse return;
    var decoded_text = try decodeXmlBorrowOrAlloc(allocator, text_raw);
    defer decoded_text.deinit(allocator);
    const text = decoded_text.slice();

    switch (ns) {
        0 => {},
        10 => {
            try analyzer.rememberTemplatePage(allocator, title, text, page_start, page_end);
            return;
        },
        828 => {
            try analyzer.rememberModulePage(allocator, title, text, page_start, page_end);
            return;
        },
        else => return,
    }

    analyzer.namespace_zero_pages += 1;
    try analyzer.rememberEntryPage(title, page_start, page_end);

    const stored_sections = (try wikitext.extractConfiguredLanguageSectionsAlloc(allocator, text, .defaultCompact())) orelse return;

    var section_start: ?usize = null;
    var section_title: []const u8 = "";
    var line_start: usize = 0;
    while (line_start <= stored_sections.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, stored_sections, line_start, '\n') orelse stored_sections.len;
        const raw_line = std.mem.trimEnd(u8, stored_sections[line_start..next_newline], "\r");
        if (wikitext.parseHeadingLine(raw_line)) |heading| {
            if (heading.level == 2) {
                if (section_start) |start| try analyzer.analyzeEntry(title, section_title, stored_sections[start..line_start]);
                section_start = line_start;
                section_title = heading.title;
            }
        }
        if (next_newline == stored_sections.len) break;
        line_start = next_newline + 1;
    }
    if (section_start) |start| try analyzer.analyzeEntry(title, section_title, stored_sections[start..stored_sections.len]);
}

const DecodedXmlText = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn slice(self: DecodedXmlText) []const u8 {
        return switch (self) {
            .borrowed => |value| value,
            .owned => |value| value,
        };
    }

    fn deinit(self: *DecodedXmlText, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |value| allocator.free(value),
        }
    }
};

fn decodeXmlBorrowOrAlloc(allocator: std.mem.Allocator, input: []const u8) !DecodedXmlText {
    if (std.mem.indexOfScalar(u8, input, '&') == null) {
        return .{ .borrowed = input };
    }
    return .{ .owned = try xml_decode.decodeAlloc(allocator, input) };
}

fn pageTitleHint(page_fragment: []const u8) ?[]const u8 {
    const start_tag = std.mem.indexOf(u8, page_fragment, "<title>") orelse return null;
    const title_start = start_tag + "<title>".len;
    const title_end = std.mem.indexOfPos(u8, page_fragment, title_start, "</title>") orelse return null;
    return std.mem.trim(u8, page_fragment[title_start..title_end], " \t\r\n");
}
fn writeReport(io: std.Io, allocator: std.mem.Allocator, analyzer: *Analyzer) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const build_inputs = try buildInputsAlloc(arena_allocator, analyzer);
    var build = try structure_tables_support.buildDataFromInputsAlloc(arena_allocator, build_inputs);
    const dependencies = try buildStructureDependenciesAlloc(arena_allocator, allocator, analyzer, build);
    try replaceBuildLineTemplatesAlloc(arena_allocator, &build, dependencies.reachable_templates);
    build.structure_fingerprint = structure_tables_support.computeStructureFingerprint(build);

    if (std.mem.eql(u8, analyzer.options.output_path, "-")) {
        var stdout_buffer: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
        defer stdout_writer.flush() catch {};
        try stdout_writer.interface.print(
            "pages={d}\nns0={d}\nlanguage_entries={d}\nparse_errors={d}\nheading_titles={d}\nunclassified_headings={d}\nanomalies={d}\n",
            .{
                analyzer.pages_seen,
                analyzer.namespace_zero_pages,
                analyzer.language_entries,
                analyzer.parse_errors,
                analyzer.heading_title_counts.count(),
                analyzer.unclassified_heading_counts.count(),
                analyzer.anomaly_samples.items.len,
            },
        );
        return;
    }
    try structure_report.saveStructureFile(io, analyzer.options.output_path, build, dependencies);
}

const SortedCount = struct {
    key: []const u8,
    count: u64,
};

const SortedCompositeCount = struct {
    left: []const u8,
    right: []const u8,
    count: u64,
};

fn sortedCounts(allocator: std.mem.Allocator, map: std.StringHashMapUnmanaged(u64)) ![]SortedCount {
    var items = try allocator.alloc(SortedCount, map.count());
    errdefer allocator.free(items);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        items[idx] = .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* };
    }

    std.mem.sort(SortedCount, items, {}, struct {
        fn lessThan(_: void, lhs: SortedCount, rhs: SortedCount) bool {
            if (lhs.count != rhs.count) return lhs.count > rhs.count;
            return std.mem.order(u8, lhs.key, rhs.key) == .lt;
        }
    }.lessThan);
    return items;
}

fn sortedCompositeCounts(allocator: std.mem.Allocator, map: std.StringHashMapUnmanaged(u64)) ![]SortedCompositeCount {
    var items = try allocator.alloc(SortedCompositeCount, map.count());
    errdefer allocator.free(items);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        const key = entry.key_ptr.*;
        const tab = std.mem.indexOfScalar(u8, key, '\t') orelse key.len;
        items[idx] = .{
            .left = key[0..tab],
            .right = if (tab < key.len) key[tab + 1 ..] else "",
            .count = entry.value_ptr.*,
        };
    }

    std.mem.sort(SortedCompositeCount, items, {}, struct {
        fn lessThan(_: void, lhs: SortedCompositeCount, rhs: SortedCompositeCount) bool {
            if (lhs.count != rhs.count) return lhs.count > rhs.count;
            const left_order = std.mem.order(u8, lhs.left, rhs.left);
            if (left_order != .eq) return left_order == .lt;
            return std.mem.order(u8, lhs.right, rhs.right) == .lt;
        }
    }.lessThan);
    return items;
}

fn buildStructureDependenciesAlloc(
    dest_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    build: structure_tables_support.BuildData,
) !structure_tables_support.Dependencies {
    const all_root_templates = try collectBuildTemplateRootsAlloc(scratch_allocator, build);
    defer freeOwnedStringSlice(scratch_allocator, all_root_templates);

    const use_prebuilt_graph = analyzer.template_nodes.count() != 0 or analyzer.module_nodes.count() != 0;

    const root_templates = try filterNamesPresentInMapAlloc(
        scratch_allocator,
        all_root_templates,
        analyzer.template_page_refs,
    );
    defer freeOwnedStringSlice(scratch_allocator, root_templates);

    const entry_direct_modules = try collectSortedMapKeysAlloc(scratch_allocator, analyzer.entry_direct_modules);
    defer freeOwnedStringSlice(scratch_allocator, entry_direct_modules);

    var report = if (use_prebuilt_graph) blk: {
        break :blk try lua.analyzeRenderDependenciesFromGraphAlloc(scratch_allocator, root_templates, .{
            .entry_direct_modules = entry_direct_modules,
            .template_nodes = &analyzer.template_nodes,
            .module_nodes = &analyzer.module_nodes,
        });
    } else blk: {
        const template_refs = try collectBorrowedSourceRefsAlloc(scratch_allocator, analyzer.template_page_refs);
        defer scratch_allocator.free(template_refs);
        const module_refs = try collectBorrowedSourceRefsAlloc(scratch_allocator, analyzer.module_page_refs);
        defer scratch_allocator.free(module_refs);

        break :blk try analyzeRenderDependenciesFromPageRefsAlloc(
            scratch_allocator,
            analyzer.options.input_path,
            root_templates,
            entry_direct_modules,
            template_refs,
            module_refs,
        );
    };
    defer report.deinit(scratch_allocator);

    const reachable_templates = try filterNamesPresentInMapAlloc(
        scratch_allocator,
        report.reachable_templates,
        analyzer.template_page_refs,
    );
    defer freeOwnedStringSlice(scratch_allocator, reachable_templates);

    const transitive_modules = try filterNamesPresentInMapAlloc(
        scratch_allocator,
        report.transitive_modules,
        analyzer.module_page_refs,
    );
    defer freeOwnedStringSlice(scratch_allocator, transitive_modules);

    return .{
        .root_templates = try dupStringSliceAlloc(dest_allocator, report.root_templates),
        .reachable_templates = try dupStringSliceAlloc(dest_allocator, reachable_templates),
        // Keep the structure report self-contained for codegen. This is a
        // conservative superset of runtime-built template names, but it avoids
        // a second dynamic-name analysis pass during template compilation.
        .dynamic_templates = try dupStringSliceAlloc(dest_allocator, reachable_templates),
        .unresolved_templates = try dupStringSliceAlloc(dest_allocator, report.unresolved_templates),
        .direct_modules = try dupStringSliceAlloc(dest_allocator, report.direct_modules),
        .transitive_modules = try dupStringSliceAlloc(dest_allocator, transitive_modules),
        .all_entry_pages = try collectAllSourceRefsAlloc(dest_allocator, analyzer.entry_page_refs),
        .all_template_pages = try collectAllSourceRefsAlloc(dest_allocator, analyzer.template_page_refs),
        .all_module_pages = try collectAllSourceRefsAlloc(dest_allocator, analyzer.module_page_refs),
        .reachable_template_pages = try collectDependencySourceRefsAlloc(dest_allocator, reachable_templates, analyzer.template_page_refs),
        .transitive_module_pages = try collectDependencySourceRefsAlloc(dest_allocator, transitive_modules, analyzer.module_page_refs),
        .missing_modules = try dupStringSliceAlloc(dest_allocator, report.missing_modules),
        .compiled_failed = try dupDependencyFailuresAlloc(dest_allocator, report.compiled_failed),
        .emitted_inconsistent = try dupDependencyFailuresAlloc(dest_allocator, report.emitted_inconsistent),
    };
}

fn analyzeRenderDependenciesFromPageRefsAlloc(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    root_templates: []const []const u8,
    entry_direct_modules: []const []const u8,
    template_refs: []const lua.SourcePageRef,
    module_refs: []const lua.SourcePageRef,
) !lua.TemplateDependencyReport {
    var sources = try collectReachableSourcesFromPageRefsAlloc(
        allocator,
        input_path,
        root_templates,
        entry_direct_modules,
        template_refs,
        module_refs,
    );
    defer sources.deinit(allocator);

    return try lua.analyzeRenderDependenciesFromSourcesAlloc(
        allocator,
        root_templates,
        entry_direct_modules,
        &sources,
    );
}

fn collectReachableSourcesFromPageRefsAlloc(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    root_templates: []const []const u8,
    entry_direct_modules: []const []const u8,
    template_refs: []const lua.SourcePageRef,
    module_refs: []const lua.SourcePageRef,
) !lua.TemplateSources {
    var template_ref_map = std.StringHashMapUnmanaged(lua.SourcePageRef){};
    defer template_ref_map.deinit(allocator);
    for (template_refs) |ref| {
        const gop = try template_ref_map.getOrPut(allocator, ref.name);
        if (!gop.found_existing) gop.key_ptr.* = ref.name;
        gop.value_ptr.* = ref;
    }

    var module_ref_map = std.StringHashMapUnmanaged(lua.SourcePageRef){};
    defer module_ref_map.deinit(allocator);
    for (module_refs) |ref| {
        const gop = try module_ref_map.getOrPut(allocator, ref.name);
        if (!gop.found_existing) gop.key_ptr.* = ref.name;
        gop.value_ptr.* = ref;
    }

    var mapped = try mmapReadOnlyPath(std.Options.debug_io, input_path);
    defer mapped.deinit();
    const mapped_bytes = mapped.bytes();

    var sources = lua.TemplateSources{
        .template_sources = std.StringHashMap([]const u8).init(allocator),
        .module_sources = std.StringHashMap([]const u8).init(allocator),
    };
    errdefer sources.deinit(allocator);

    var pending_templates = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &pending_templates);
    var pending_modules = std.StringHashMapUnmanaged(void){};
    defer deinitOwnedStringSet(allocator, &pending_modules);

    var template_stack: std.ArrayList([]const u8) = .empty;
    defer template_stack.deinit(allocator);
    var module_stack: std.ArrayList([]const u8) = .empty;
    defer module_stack.deinit(allocator);

    for (root_templates) |name| {
        const canonical = try lua.canonicalTemplateNameAlloc(allocator, name);
        defer allocator.free(canonical);
        const gop = try pending_templates.getOrPut(allocator, canonical);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, canonical);
            try template_stack.append(allocator, gop.key_ptr.*);
        }
    }

    for (entry_direct_modules) |name| {
        const canonical = try lua.canonicalModuleNameAlloc(allocator, name);
        defer allocator.free(canonical);
        const gop = try pending_modules.getOrPut(allocator, canonical);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, canonical);
            try module_stack.append(allocator, gop.key_ptr.*);
        }
    }

    while (template_stack.pop()) |name| {
        if (sources.template_sources.contains(name)) continue;
        const ref = template_ref_map.get(name) orelse continue;

        const source = try loadSelectedSourceFromMappedAlloc(allocator, mapped_bytes, ref, "10");
        errdefer allocator.free(source);
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        try sources.template_sources.put(key, source);

        const template_deps = try lua.extractTemplateDependenciesAlloc(allocator, source, name);
        defer freeOwnedStringSlice(allocator, template_deps);
        for (template_deps) |dep| {
            if (sources.template_sources.contains(dep)) continue;
            const gop = try pending_templates.getOrPut(allocator, dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, dep);
                try template_stack.append(allocator, gop.key_ptr.*);
            }
        }

        const direct_modules = try lua.extractInvokeModulesAlloc(allocator, source);
        defer freeOwnedStringSlice(allocator, direct_modules);
        for (direct_modules) |module_name| {
            if (sources.module_sources.contains(module_name)) continue;
            const gop = try pending_modules.getOrPut(allocator, module_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, module_name);
                try module_stack.append(allocator, gop.key_ptr.*);
            }
        }
    }

    while (module_stack.pop()) |name| {
        if (sources.module_sources.contains(name)) continue;
        const ref = module_ref_map.get(name) orelse continue;

        const source = try loadSelectedSourceFromMappedAlloc(allocator, mapped_bytes, ref, "828");
        errdefer allocator.free(source);
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        try sources.module_sources.put(key, source);

        const deps = try lua.extractModuleDependencies(allocator, source);
        defer freeOwnedStringSlice(allocator, deps);
        for (deps) |dep| {
            if (sources.module_sources.contains(dep)) continue;
            const gop = try pending_modules.getOrPut(allocator, dep);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, dep);
                try module_stack.append(allocator, gop.key_ptr.*);
            }
        }
    }

    return sources;
}

fn collectBorrowedSourceRefsAlloc(
    allocator: std.mem.Allocator,
    map: std.StringHashMap(SourcePageOffset),
) ![]const lua.SourcePageRef {
    const out = try allocator.alloc(lua.SourcePageRef, map.count());
    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        out[idx] = .{
            .name = entry.key_ptr.*,
            .page_start = entry.value_ptr.page_start,
            .page_end = entry.value_ptr.page_end,
        };
    }
    return out;
}

fn loadSelectedSourceFromMappedAlloc(
    allocator: std.mem.Allocator,
    mapped: []const u8,
    ref: lua.SourcePageRef,
    expected_ns: []const u8,
) ![]u8 {
    const start = std.math.cast(usize, ref.page_start) orelse return error.FileTooBig;
    const end = std.math.cast(usize, ref.page_end) orelse return error.FileTooBig;
    if (start >= end or end > mapped.len) return error.InvalidDictionaryFile;

    const page_fragment = mapped[start..end];
    const ns = extractPageTagText(page_fragment, "ns") orelse return error.InvalidDictionaryFile;
    if (!std.mem.eql(u8, std.mem.trim(u8, ns, " \t\r\n"), expected_ns)) return error.InvalidDictionaryFile;

    const text_raw = extractPageText(page_fragment) orelse return error.InvalidDictionaryFile;
    return try xml_decode.decodeSinglePassAlloc(allocator, text_raw);
}

fn extractPageTagText(page: []const u8, tag: []const u8) ?[]const u8 {
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    const start = std.fmt.bufPrint(&start_buf, "<{s}>", .{tag}) catch return null;
    const end = std.fmt.bufPrint(&end_buf, "</{s}>", .{tag}) catch return null;
    const start_idx = std.mem.indexOf(u8, page, start) orelse return null;
    const after_start = start_idx + start.len;
    const end_idx = std.mem.indexOfPos(u8, page, after_start, end) orelse return null;
    return page[after_start..end_idx];
}

fn extractPageText(page: []const u8) ?[]const u8 {
    const text_tag_start = std.mem.indexOf(u8, page, "<text") orelse return null;
    const content_start_rel = std.mem.indexOfScalarPos(u8, page, text_tag_start, '>') orelse return null;
    const content_start = content_start_rel + 1;
    const content_end = std.mem.indexOfPos(u8, page, content_start, "</text>") orelse return null;
    return page[content_start..content_end];
}

fn collectBuildTemplateRootsAlloc(
    allocator: std.mem.Allocator,
    build: structure_tables_support.BuildData,
) ![]const []const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer {
        var it = set.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        set.deinit(allocator);
    }

    for (build.line_templates) |entry| {
        const gop = try set.getOrPut(allocator, entry.name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.name);
    }
    for (build.translation_templates) |entry| {
        const gop = try set.getOrPut(allocator, entry.name);
        if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, entry.name);
    }

    var out = try allocator.alloc([]const u8, set.count());
    var it = set.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    std.mem.sortUnstable([]const u8, out, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return out;
}

fn replaceBuildLineTemplatesAlloc(
    allocator: std.mem.Allocator,
    build: *structure_tables_support.BuildData,
    reachable_templates: []const []const u8,
) !void {
    const out = try allocator.alloc(structure_tables_support.TemplateSpec, reachable_templates.len);
    for (reachable_templates, out, 0..) |name, *slot, idx| {
        slot.* = .{
            .code = std.math.cast(u16, idx + 1) orelse return error.TooManyGeneratedTemplates,
            .name = try allocator.dupe(u8, name),
        };
    }
    build.line_templates = out;
}

fn dupStringSliceAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, out) |value, *slot| slot.* = try allocator.dupe(u8, value);
    return out;
}

fn dupDependencyFailuresAlloc(
    allocator: std.mem.Allocator,
    failures: []const lua.ModuleCompileFailure,
) ![]const structure_tables_support.DependencyFailure {
    const out = try allocator.alloc(structure_tables_support.DependencyFailure, failures.len);
    for (failures, out) |failure, *slot| {
        slot.* = .{
            .name = try allocator.dupe(u8, failure.name),
            .reason = try allocator.dupe(u8, failure.reason),
        };
    }
    return out;
}

fn collectSortedMapKeysAlloc(
    allocator: std.mem.Allocator,
    map: anytype,
) ![]const []const u8 {
    const Map = @TypeOf(map);
    comptime {
        if (!@hasDecl(Map, "iterator") or !@hasDecl(Map, "count")) {
            @compileError("collectSortedMapKeysAlloc expects a std.StringHashMap-like map");
        }
    }

    var out = try allocator.alloc([]const u8, map.count());
    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) out[idx] = try allocator.dupe(u8, entry.key_ptr.*);
    std.mem.sortUnstable([]const u8, out, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return out;
}

fn collectDependencySourceRefsAlloc(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    map: std.StringHashMap(SourcePageOffset),
) ![]const structure_tables_support.DependencySourceRef {
    var out: std.ArrayList(structure_tables_support.DependencySourceRef) = .empty;
    errdefer {
        for (out.items) |entry| allocator.free(entry.name);
        out.deinit(allocator);
    }

    for (names) |name| {
        const offset = map.get(name) orelse continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .page_start = offset.page_start,
            .page_end = offset.page_end,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn collectAllSourceRefsAlloc(
    allocator: std.mem.Allocator,
    map: std.StringHashMap(SourcePageOffset),
) ![]const structure_tables_support.DependencySourceRef {
    const names = try collectSortedMapKeysAlloc(allocator, map);
    defer freeOwnedStringSlice(allocator, names);
    return collectDependencySourceRefsAlloc(allocator, names, map);
}

fn filterNamesPresentInMapAlloc(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    map: std.StringHashMap(SourcePageOffset),
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }

    for (names) |name| {
        if (!map.contains(name)) continue;
        try out.append(allocator, try allocator.dupe(u8, name));
    }
    return out.toOwnedSlice(allocator);
}

fn deinitOwnedStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit(allocator);
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn stringSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn buildInputsAlloc(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
) !structure_tables_support.BuildInputs {
    const heading_items = try sortedCounts(allocator, analyzer.heading_title_counts);
    const heading_profiles = try allocator.alloc(structure_tables_support.HeadingProfile, heading_items.len);
    for (heading_items, heading_profiles) |item, *slot| {
        const level = if (looksLikeLanguageHeading(item.key)) @as(u8, 2) else 3;
        const profile = classifyHeadingTitle(item.key, level);
        slot.* = .{
            .title = item.key,
            .parser_kind = profile.parser_kind,
            .count = item.count,
        };
    }

    const heading_levels = try countEntriesAlloc(allocator, analyzer.heading_level_counts);
    const translation_source_labels = try countEntriesAlloc(allocator, analyzer.translation_source_label_counts);
    const translation_target_languages = try countEntriesAlloc(allocator, analyzer.translation_target_lang_counts);

    const template_items = try sortedCompositeCounts(allocator, analyzer.section_template_counts);
    const templates_by_heading = try allocator.alloc(structure_tables_support.HeadingTemplateEntry, template_items.len);
    for (template_items, templates_by_heading) |item, *slot| {
        slot.* = .{
            .heading = item.left,
            .template = item.right,
            .count = item.count,
        };
    }

    return .{
        .heading_profiles = heading_profiles,
        .headings_by_level = heading_levels,
        .translation_source_labels = translation_source_labels,
        .translation_target_languages = translation_target_languages,
        .templates_by_heading = templates_by_heading,
    };
}

fn countEntriesAlloc(
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(u64),
) ![]structure_tables_support.CountEntry {
    const items = try sortedCounts(allocator, map);
    const out = try allocator.alloc(structure_tables_support.CountEntry, items.len);
    for (items, out) |item, *slot| {
        slot.* = .{
            .key = item.key,
            .count = item.count,
        };
    }
    return out;
}

fn anomalySamplesAlloc(
    allocator: std.mem.Allocator,
    samples: []const AnomalySample,
) ![]structure_tables_support.AnomalySample {
    const out = try allocator.alloc(structure_tables_support.AnomalySample, samples.len);
    for (samples, out) |sample, *slot| {
        slot.* = .{
            .title = sample.title,
            .kind = sample.kind,
            .detail = sample.detail,
        };
    }
    return out;
}

fn writeJsonMapField(writer: *std.Io.Writer, allocator: std.mem.Allocator, field_name: []const u8, map: std.StringHashMapUnmanaged(u64)) !void {
    const items = try sortedCounts(allocator, map);
    defer allocator.free(items);

    try writer.print("  \"{s}\": [\n", .{field_name});
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.print(",\n", .{});
        try writer.print("    {{\"key\": ", .{});
        try writeJsonString(writer, item.key);
        try writer.print(", \"count\": {d}}}", .{item.count});
    }
    try writer.print("\n  ]", .{});
}

fn writeJsonCompositeField(writer: *std.Io.Writer, allocator: std.mem.Allocator, field_name: []const u8, map: std.StringHashMapUnmanaged(u64), left_name: []const u8, right_name: []const u8) !void {
    var items = try allocator.alloc(SortedCompositeCount, map.count());
    defer allocator.free(items);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        const key = entry.key_ptr.*;
        const tab = std.mem.indexOfScalar(u8, key, '\t') orelse key.len;
        items[idx] = .{
            .left = key[0..tab],
            .right = if (tab < key.len) key[tab + 1 ..] else "",
            .count = entry.value_ptr.*,
        };
    }

    std.mem.sort(SortedCompositeCount, items, {}, struct {
        fn lessThan(_: void, lhs: SortedCompositeCount, rhs: SortedCompositeCount) bool {
            if (lhs.count != rhs.count) return lhs.count > rhs.count;
            const left_order = std.mem.order(u8, lhs.left, rhs.left);
            if (left_order != .eq) return left_order == .lt;
            return std.mem.order(u8, lhs.right, rhs.right) == .lt;
        }
    }.lessThan);

    try writer.print("  \"{s}\": [\n", .{field_name});
    for (items, 0..) |item, item_idx| {
        if (item_idx != 0) try writer.print(",\n", .{});
        try writer.print("    {{\"{s}\": ", .{left_name});
        try writeJsonString(writer, item.left);
        try writer.print(", \"{s}\": ", .{right_name});
        try writeJsonString(writer, item.right);
        try writer.print(", \"count\": {d}}}", .{item.count});
    }
    try writer.print("\n  ]", .{});
}

fn writeJsonHeadingProfilesField(writer: *std.Io.Writer, allocator: std.mem.Allocator, map: std.StringHashMapUnmanaged(u64)) !void {
    const items = try sortedCounts(allocator, map);
    defer allocator.free(items);

    try writer.print("  \"heading_profiles\": [\n", .{});
    for (items, 0..) |item, idx| {
        const profile = classifyHeadingTitle(item.key, if (looksLikeLanguageHeading(item.key)) 2 else 3);
        if (idx != 0) try writer.print(",\n", .{});
        try writer.print("    {{\"title\": ", .{});
        try writeJsonString(writer, item.key);
        try writer.print(", \"count\": {d}, \"family\": ", .{item.count});
        try writeJsonString(writer, profile.family);
        try writer.print(", \"parser_kind\": ", .{});
        try writeJsonString(writer, profile.parser_kind);
        try writer.print(", \"canonical_title\": ", .{});
        try writeJsonString(writer, profile.canonical_title);
        try writer.print("}}", .{});
    }
    try writer.print("\n  ]", .{});
}

fn looksLikeLanguageHeading(title: []const u8) bool {
    if (title.len == 0) return false;
    if (isAlternativeFormsHeading(title) or
        isEtymologyHeading(title) or
        isTranslationHeading(title) or
        isDescendantHeading(title) or
        isInflectionHeading(title) or
        isRelationHeading(title) or
        isCitationHeading(title) or
        isNavigationHeading(title) or
        isNotesHeading(title) or
        isPronunciationHeading(title) or
        isPartOfSpeechHeading(title) or
        isMetaHeading(title))
    {
        return false;
    }
    return true;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{X:0>4}", .{@as(u16, byte)});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn deepestHeadingLevel(active_titles: [7][]const u8) u8 {
    var level: usize = active_titles.len;
    while (level > 0) {
        level -= 1;
        if (active_titles[level].len != 0) return @intCast(level);
    }
    return 0;
}

fn parentHeadingLevel(active_titles: [7][]const u8, level: u8) u8 {
    if (level <= 2) return 0;
    var cursor: usize = level - 1;
    while (cursor > 0) : (cursor -= 1) {
        if (active_titles[cursor].len == 0) continue;
        return @intCast(cursor);
    }
    return 0;
}

fn parentHeadingTitle(active_titles: [7][]const u8, level: u8) []const u8 {
    const parent_level = parentHeadingLevel(active_titles, level);
    return if (parent_level == 0) "ROOT" else active_titles[parent_level];
}

fn currentHeadingLabel(active_titles: *const [7][]const u8, language_title: []const u8) []const u8 {
    const level = deepestHeadingLevel(active_titles.*);
    return if (level <= 2) language_title else active_titles[level];
}

fn currentHeadingProfile(active_titles: *const [7][]const u8, language_title: []const u8) HeadingProfile {
    const level = deepestHeadingLevel(active_titles.*);
    if (level <= 2) return classifyHeadingTitle(language_title, 2);
    return classifyHeadingTitle(active_titles[level], level);
}

fn appendUnsignedDecimal(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try list.appendSlice(allocator, text);
}

fn appendHeadingLabel(list: *std.ArrayList(u8), allocator: std.mem.Allocator, level: u8, title: []const u8) !void {
    if (level == 0) {
        try list.appendSlice(allocator, "ROOT");
        return;
    }
    try list.appendSlice(allocator, "L");
    try appendUnsignedDecimal(list, allocator, level);
    try list.append(allocator, ':');
    try list.appendSlice(allocator, title);
}

fn classifyHeadingTitle(title: []const u8, level: u8) HeadingProfile {
    if (level == 2) {
        return .{ .family = "language-root", .parser_kind = "language-root", .canonical_title = title };
    }
    if (isAlternativeFormsHeading(title)) {
        return .{ .family = "alternative-forms", .parser_kind = "alternative-forms", .canonical_title = "Alternative forms" };
    }
    if (isEtymologyHeading(title)) {
        return .{ .family = "etymology", .parser_kind = "etymology", .canonical_title = "Etymology" };
    }
    if (isTranslationHeading(title)) {
        return .{ .family = "translations", .parser_kind = "translations", .canonical_title = "Translations" };
    }
    if (isDescendantHeading(title)) {
        return .{ .family = "descendants", .parser_kind = "descendants", .canonical_title = "Descendants" };
    }
    if (isInflectionHeading(title)) {
        return .{ .family = "inflection", .parser_kind = "inflection", .canonical_title = title };
    }
    if (isRelationHeading(title)) {
        return .{ .family = "relations", .parser_kind = "relations", .canonical_title = title };
    }
    if (isCitationHeading(title)) {
        return .{ .family = "citations", .parser_kind = "citations", .canonical_title = title };
    }
    if (isNavigationHeading(title)) {
        return .{ .family = "navigation", .parser_kind = "navigation", .canonical_title = title };
    }
    if (isNotesHeading(title)) {
        return .{ .family = "notes", .parser_kind = "notes", .canonical_title = title };
    }
    if (isPronunciationHeading(title)) {
        return .{ .family = "pronunciation", .parser_kind = "pronunciation", .canonical_title = "Pronunciation" };
    }
    if (isPartOfSpeechHeading(title)) {
        return .{ .family = "part-of-speech", .parser_kind = "part-of-speech", .canonical_title = title };
    }
    if (isMetaHeading(title)) {
        return .{ .family = "meta", .parser_kind = "meta", .canonical_title = title };
    }
    return .{ .family = "meta", .parser_kind = "meta", .canonical_title = title };
}

fn isFullyClassifiedHeading(profile: HeadingProfile) bool {
    _ = profile;
    return true;
}

fn isAlternativeFormsHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Alternative forms") or
        std.mem.eql(u8, title, "Alternate forms") or
        std.mem.eql(u8, title, "Alternative spelling") or
        std.mem.eql(u8, title, "Alternative spellings");
}

fn isEtymologyHeading(title: []const u8) bool {
    return wikitext.isRecognizedEtymologyTitle(title) or
        std.mem.startsWith(u8, title, "Etymolog");
}

fn isTranslationHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Translations") or
        std.mem.eql(u8, title, "Translate");
}

fn isDescendantHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Descendants");
}

fn isInflectionHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Conjugation") or
        std.mem.eql(u8, title, "Declension") or
        std.mem.eql(u8, title, "Inflection") or
        std.mem.eql(u8, title, "Mutation");
}

fn isRelationHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Derived terms") or
        std.mem.eql(u8, title, "Derivations") or
        std.mem.eql(u8, title, "Related terms") or
        std.mem.eql(u8, title, "Related forms") or
        std.mem.eql(u8, title, "Related vocabulary") or
        std.mem.eql(u8, title, "Synonyms") or
        std.mem.eql(u8, title, "Near-synonyms") or
        std.mem.eql(u8, title, "Parasynonyms") or
        std.mem.eql(u8, title, "Synonyms and related terms") or
        std.mem.eql(u8, title, "Antonyms") or
        std.mem.eql(u8, title, "Hypernyms") or
        std.mem.eql(u8, title, "Hyponyms") or
        std.mem.eql(u8, title, "Meronyms") or
        std.mem.eql(u8, title, "Comeronyms") or
        std.mem.eql(u8, title, "Holonyms") or
        std.mem.eql(u8, title, "Troponyms") or
        std.mem.eql(u8, title, "Paronyms") or
        std.mem.eql(u8, title, "Coordinate terms") or
        std.mem.eql(u8, title, "Collocations");
}

fn isCitationHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "References") or
        std.mem.eql(u8, title, "Citations") or
        std.mem.eql(u8, title, "Sources") or
        std.mem.eql(u8, title, "Source") or
        std.mem.eql(u8, title, "Further reading") or
        std.mem.eql(u8, title, "Further information") or
        std.mem.eql(u8, title, "External links") or
        std.mem.eql(u8, title, "Links") or
        std.mem.eql(u8, title, "Quotations");
}

fn isNavigationHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "See also") or
        std.mem.eql(u8, title, "See Also") or
        std.mem.eql(u8, title, "Anagrams") or
        std.mem.eql(u8, title, "Statistics") or
        std.mem.eql(u8, title, "Gallery") or
        std.mem.eql(u8, title, "Sense overview") or
        std.mem.eql(u8, title, "Description") or
        std.mem.eql(u8, title, "Examples") or
        std.mem.eql(u8, title, "Trivia");
}

fn isNotesHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Notes") or
        std.mem.eql(u8, title, "Note") or
        std.mem.eql(u8, title, "Additional notes") or
        std.mem.eql(u8, title, "Historical notes") or
        std.mem.eql(u8, title, "Usage notes") or
        std.mem.eql(u8, title, "Usage Notes") or
        std.mem.eql(u8, title, "Usage") or
        std.mem.eql(u8, title, "Pronunciation notes");
}

fn isPronunciationHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Pronunciation") or
        std.mem.eql(u8, title, "Pronunciation 1") or
        std.mem.eql(u8, title, "Pronunciation 2") or
        std.mem.eql(u8, title, "Homophones") or
        std.mem.eql(u8, title, "Pronunciation notes");
}

fn isPartOfSpeechHeading(title: []const u8) bool {
    return wikitext.isRecognizedPartOfSpeech(title) or
        std.mem.eql(u8, title, "Prepositional phrase") or
        std.mem.eql(u8, title, "Verb phrase") or
        std.mem.eql(u8, title, "Proper adjective") or
        std.mem.eql(u8, title, "Proper nouns") or
        std.mem.eql(u8, title, "Proper noun 1") or
        std.mem.eql(u8, title, "Proper noun 2") or
        std.mem.eql(u8, title, "Proper Noun") or
        std.mem.eql(u8, title, "Multiple parts of speech") or
        std.mem.eql(u8, title, "Abbreviations") or
        std.mem.eql(u8, title, "Number") or
        std.mem.eql(u8, title, "Punctuation mark") or
        std.mem.eql(u8, title, "Diacritical mark") or
        std.mem.eql(u8, title, "Symbols") or
        std.mem.eql(u8, title, "Combining form") or
        std.mem.eql(u8, title, "Verb form") or
        std.mem.eql(u8, title, "Adverbial phrase") or
        std.mem.eql(u8, title, "Affix") or
        std.mem.eql(u8, title, "Common nouns") or
        std.mem.eql(u8, title, "Initialisms") or
        std.mem.eql(u8, title, "Adjectives") or
        std.mem.eql(u8, title, "Proper");
}

fn isMetaHeading(title: []const u8) bool {
    return std.mem.eql(u8, title, "Dialects") or
        std.mem.eql(u8, title, "Attestation") or
        std.mem.eql(u8, title, "Other names");
}

fn isExpectedHeadingLevel(kind: []const u8, level: u8) bool {
    if (std.mem.eql(u8, kind, "language-root")) return level == 2;
    if (std.mem.eql(u8, kind, "etymology")) return level == 3;
    return level >= 3 and level <= 6;
}

fn isExpectedHeadingParent(kind: []const u8, parent_kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "language-root")) return std.mem.eql(u8, parent_kind, "root");
    if (std.mem.eql(u8, kind, "etymology")) return std.mem.eql(u8, parent_kind, "language-root");
    if (std.mem.eql(u8, kind, "part-of-speech")) {
        return std.mem.eql(u8, parent_kind, "language-root") or std.mem.eql(u8, parent_kind, "etymology");
    }
    if (std.mem.eql(u8, kind, "translations") or
        std.mem.eql(u8, kind, "relations") or
        std.mem.eql(u8, kind, "descendants") or
        std.mem.eql(u8, kind, "inflection"))
    {
        return std.mem.eql(u8, parent_kind, "part-of-speech");
    }
    if (std.mem.eql(u8, kind, "pronunciation") or
        std.mem.eql(u8, kind, "notes") or
        std.mem.eql(u8, kind, "alternative-forms") or
        std.mem.eql(u8, kind, "citations") or
        std.mem.eql(u8, kind, "navigation") or
        std.mem.eql(u8, kind, "meta"))
    {
        return std.mem.eql(u8, parent_kind, "language-root") or
            std.mem.eql(u8, parent_kind, "etymology") or
            std.mem.eql(u8, parent_kind, "part-of-speech");
    }
    return true;
}

fn lineSignature(line: []const u8) []const u8 {
    if (line.len == 0) return "blank";
    if (std.mem.startsWith(u8, line, "<!--")) return "comment";
    if (std.mem.startsWith(u8, line, "{|")) return "table-start";
    if (std.mem.startsWith(u8, line, "|}")) return "table-end";
    if (std.mem.startsWith(u8, line, "|-")) return "table-row";
    if (std.mem.startsWith(u8, line, "{{")) return "template";
    if (std.mem.startsWith(u8, line, "[[")) return "link";
    if (line[0] == '|' or line[0] == '!') return "table-cell";
    if (line[0] == '<') return "html";

    var i: usize = 0;
    while (i < line.len and (line[i] == '#' or line[i] == '*' or line[i] == ':' or line[i] == ';')) : (i += 1) {}
    if (i != 0) return switch (i) {
        1 => switch (line[0]) {
            '#' => "#",
            '*' => "*",
            ':' => ":",
            ';' => ";",
            else => "list",
        },
        else => line[0..i],
    };

    return "text";
}

fn parseTranslationSourceLabel(line: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == '*' or line[start] == ':' or line[start] == ';' or line[start] == '#' or line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    if (start >= line.len or line[start] == '{') return null;

    const colon = std.mem.indexOfScalarPos(u8, line, start, ':') orelse return null;
    if (colon <= start) return null;
    const label = std.mem.trim(u8, line[start..colon], " \t");
    if (label.len == 0 or label.len > 64) return null;
    if (std.mem.indexOfScalar(u8, label, '{') != null) return null;
    return label;
}

fn isTranslationTemplate(name: []const u8) bool {
    return std.mem.eql(u8, name, "t") or
        std.mem.eql(u8, name, "t+") or
        std.mem.eql(u8, name, "tt") or
        std.mem.eql(u8, name, "tt+") or
        std.mem.eql(u8, name, "t-check") or
        std.mem.eql(u8, name, "t+check") or
        std.mem.eql(u8, name, "t-needed") or
        std.mem.eql(u8, name, "t-egy");
}

fn scanTemplates(line: []const u8, ctx: anytype, comptime onTemplate: fn (@TypeOf(ctx), []const u8, ?[]const u8) anyerror!void) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, "{{")) |open| {
        var cursor = open + 2;
        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}

        const name_start = cursor;
        while (cursor < line.len and line[cursor] != '|' and line[cursor] != '}' and line[cursor] != '\n' and line[cursor] != '\r') : (cursor += 1) {}
        const name = std.mem.trim(u8, line[name_start..cursor], " \t");

        var first_param: ?[]const u8 = null;
        if (cursor < line.len and line[cursor] == '|') {
            cursor += 1;
            const param_start = cursor;
            while (cursor < line.len and line[cursor] != '|' and line[cursor] != '}' and line[cursor] != '\n' and line[cursor] != '\r') : (cursor += 1) {}
            first_param = std.mem.trim(u8, line[param_start..cursor], " \t");
        }

        if (name.len != 0) try onTemplate(ctx, name, first_param);
        pos = open + 2;
    }
}

fn findBalancedMarkup(input: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (i + open.len <= input.len and std.mem.eql(u8, input[i .. i + open.len], open)) {
            depth += 1;
            i += open.len - 1;
            continue;
        }
        if (i + close.len <= input.len and std.mem.eql(u8, input[i .. i + close.len], close)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
            i += close.len - 1;
        }
    }
    return null;
}

fn templateNameFromBody(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t");
    const sep = std.mem.indexOfScalar(u8, trimmed, '|') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..sep], " \t");
}

fn templateShapeAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    _ = try templateShapeScratch(&out, allocator, body);
    return out.toOwnedSlice(allocator);
}

fn templateShapeScratch(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    out.items.len = 0;

    var cursor: usize = 0;
    const first = nextTopLevelSegment(body, '|', &cursor) orelse {
        try out.appendSlice(allocator, "|pos:-|named:-");
        return out.items;
    };
    try out.appendSlice(allocator, first);

    var positional_shapes: [4][]const u8 = undefined;
    var named_keys: [4][]const u8 = undefined;
    var positional_total: usize = 0;
    var named_total: usize = 0;

    while (nextTopLevelSegment(body, '|', &cursor)) |segment| {
        const equals = topLevelEquals(segment);
        if (equals) |idx| {
            const key = std.mem.trim(u8, segment[0..idx], " \t");
            if (key.len == 0) continue;
            if (named_total < named_keys.len) named_keys[named_total] = key;
            named_total += 1;
            continue;
        }

        if (positional_total < positional_shapes.len) {
            positional_shapes[positional_total] = fragmentShape(segment);
        }
        positional_total += 1;
    }

    try out.appendSlice(allocator, "|pos:");
    if (positional_total == 0) {
        try out.appendSlice(allocator, "-");
    } else {
        const positional_written = @min(positional_total, positional_shapes.len);
        for (positional_shapes[0..positional_written], 0..) |shape, idx| {
            if (idx != 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, shape);
        }
        if (positional_total > positional_written) {
            try out.append(allocator, '+');
            try appendUnsignedDecimal(out, allocator, positional_total - positional_written);
        }
    }

    try out.appendSlice(allocator, "|named:");
    if (named_total == 0) {
        try out.appendSlice(allocator, "-");
    } else {
        const named_written = @min(named_total, named_keys.len);
        for (named_keys[0..named_written], 0..) |key, idx| {
            if (idx != 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, key);
        }
        if (named_total > named_written) {
            try out.append(allocator, '+');
            try appendUnsignedDecimal(out, allocator, named_total - named_written);
        }
    }

    return out.items;
}

fn internalLinkShapeAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    _ = try internalLinkShapeScratch(&out, allocator, body);
    return out.toOwnedSlice(allocator);
}

fn internalLinkShapeScratch(out: *std.ArrayList(u8), allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    out.items.len = 0;
    try out.appendSlice(allocator, "wikilink");

    var cursor: usize = 0;
    const first = nextTopLevelSegment(body, '|', &cursor) orelse "";
    var target = first;
    if (target.len != 0 and target[0] == ':') target = std.mem.trim(u8, target[1..], " \t");

    if (linkNamespaceKind(target)) |namespace_kind| {
        try out.appendSlice(allocator, "|ns:");
        try out.appendSlice(allocator, namespace_kind);
    } else {
        try out.appendSlice(allocator, "|ns:-");
    }

    if (std.mem.indexOfScalar(u8, target, '#') != null) {
        try out.appendSlice(allocator, "|anchor");
    }

    var last_segment = first;
    var segment_count: usize = 1;
    while (nextTopLevelSegment(body, '|', &cursor)) |segment| {
        last_segment = segment;
        segment_count += 1;
    }

    if (segment_count >= 2) {
        try out.appendSlice(allocator, if (last_segment.len == 0) "|pipe-trick" else "|display");
    } else {
        try out.appendSlice(allocator, "|plain");
    }

    return out.items;
}

fn externalLinkShape(body: []const u8) []const u8 {
    const has_label = std.mem.indexOfScalar(u8, body, ' ') != null;
    return if (has_label) "extlink|label" else "extlink|bare";
}

fn linkNamespaceKind(target: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return null;
    const namespace = std.mem.trim(u8, target[0..colon], " \t");
    if (namespace.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(namespace, "File") or std.ascii.eqlIgnoreCase(namespace, "Image")) return "file";
    if (std.ascii.eqlIgnoreCase(namespace, "Category")) return "category";
    if (std.ascii.eqlIgnoreCase(namespace, "Appendix")) return "appendix";
    if (std.ascii.eqlIgnoreCase(namespace, "Reconstruction")) return "reconstruction";
    if (namespace.len <= 12) return "namespace";
    return "namespace";
}

fn fragmentShape(fragment: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, fragment, " \t");
    if (trimmed.len == 0) return "empty";
    if (std.mem.indexOf(u8, trimmed, "{{") != null) return "template";
    if (std.mem.indexOf(u8, trimmed, "[[") != null) return "wikilink";
    if (std.mem.indexOf(u8, trimmed, "[http") != null or std.mem.indexOf(u8, trimmed, "[https") != null) return "extlink";
    if (std.mem.indexOfScalar(u8, trimmed, '<') != null) return "html";
    if (looksLikeLanguageCode(trimmed)) return "lang";
    if (looksLikeNumericToken(trimmed)) return "number";
    return "text";
}

fn nextTopLevelSegment(input: []const u8, sep: u8, cursor: *usize) ?[]const u8 {
    if (cursor.* > input.len) return null;

    const start = cursor.*;
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (input[i] == sep and templates == 0 and links == 0) {
            cursor.* = i + 1;
            return std.mem.trim(u8, input[start..i], " \t");
        }
    }
    cursor.* = input.len + 1;
    return std.mem.trim(u8, input[start..], " \t");
}

fn templateArgHasName(segment: []const u8) bool {
    return topLevelEquals(segment) != null;
}

fn topLevelEquals(segment: []const u8) ?usize {
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "{{")) {
            templates += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "}}")) {
            if (templates != 0) templates -= 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "[[")) {
            links += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= segment.len and std.mem.eql(u8, segment[i .. i + 2], "]]")) {
            if (links != 0) links -= 1;
            i += 1;
            continue;
        }
        if (segment[i] == '=' and templates == 0 and links == 0) return i;
    }
    return null;
}

fn looksLikeLanguageCode(value: []const u8) bool {
    if (value.len < 2 or value.len > 12) return false;
    var has_letter = false;
    for (value) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') continue;
        return false;
    }
    return has_letter;
}

fn looksLikeNumericToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |char| {
        if (std.ascii.isDigit(char) or char == '.' or char == '-' or char == '+' or char == '/') continue;
        return false;
    }
    return true;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") and i + 1 < args.len) {
            options.input_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            options.output_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            options.limit_entries = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--threads") and i + 1 < args.len) {
            options.worker_threads = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--top") and i + 1 < args.len) {
            options.top_n = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--samples") and i + 1 < args.len) {
            options.sample_limit = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

fn printUsage(io: std.Io, allocator: std.mem.Allocator) !void {
    try printStdOut(io, allocator,
        \\dict-structure [--input data/wiktionary.xml] [--output data/wiktionary-structure.bin]
        \\               [--limit 10000] [--threads 4] [--top 50] [--samples 64]
        \\
    , .{});
}

fn printStdOut(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

test "line signature classifies common prefixes" {
    try std.testing.expectEqualStrings("#", lineSignature("# gloss"));
    try std.testing.expectEqualStrings("#:", lineSignature("#: example"));
    try std.testing.expectEqualStrings("*", lineSignature("* bullet"));
    try std.testing.expectEqualStrings("template", lineSignature("{{en-noun|s}}"));
    try std.testing.expectEqualStrings("table-start", lineSignature("{| class=\"wikitable\""));
}

test "heading kind recognizes parser-known titles" {
    try std.testing.expectEqualStrings("part-of-speech", classifyHeadingTitle("Noun", 3).family);
    try std.testing.expectEqualStrings("notes", classifyHeadingTitle("Usage notes", 4).family);
    try std.testing.expectEqualStrings("language-root", classifyHeadingTitle("Hindi", 2).family);
}

test "heading kind recognizes common wiktionary structure families" {
    try std.testing.expectEqualStrings("translations", classifyHeadingTitle("Translations", 4).family);
    try std.testing.expectEqualStrings("relations", classifyHeadingTitle("Derived terms", 4).family);
    try std.testing.expectEqualStrings("descendants", classifyHeadingTitle("Descendants", 4).family);
    try std.testing.expectEqualStrings("inflection", classifyHeadingTitle("Conjugation", 4).family);
    try std.testing.expectEqualStrings("citations", classifyHeadingTitle("References", 3).family);
    try std.testing.expectEqualStrings("navigation", classifyHeadingTitle("Anagrams", 3).family);
}

test "classification covers uncommon heading variants" {
    try std.testing.expectEqualStrings("part-of-speech", classifyHeadingTitle("Prepositional phrase", 3).family);
    try std.testing.expectEqualStrings("alternative-forms", classifyHeadingTitle("Alternative spelling", 3).family);
    try std.testing.expectEqualStrings("pronunciation", classifyHeadingTitle("Pronunciation 1", 3).family);
    try std.testing.expectEqualStrings("citations", classifyHeadingTitle("External links", 3).family);
    try std.testing.expectEqualStrings("relations", classifyHeadingTitle("Near-synonyms", 4).family);
}

test "structure expectations model core heading grammar" {
    try std.testing.expect(isExpectedHeadingParent("part-of-speech", "language-root"));
    try std.testing.expect(isExpectedHeadingParent("part-of-speech", "etymology"));
    try std.testing.expect(isExpectedHeadingParent("translations", "part-of-speech"));
    try std.testing.expect(!isExpectedHeadingParent("translations", "language-root"));
    try std.testing.expect(isExpectedHeadingLevel("etymology", 3));
    try std.testing.expect(!isExpectedHeadingLevel("etymology", 4));
}

test "templateShapeAlloc records positional and named argument shapes" {
    const shape = try templateShapeAlloc(std.testing.allocator, "plural of|en|Fresnel reflection|t=gloss");
    defer std.testing.allocator.free(shape);

    try std.testing.expectEqualStrings("plural of|pos:lang,text|named:t", shape);
}

test "internalLinkShapeAlloc records namespaces and pipe tricks" {
    const shape = try internalLinkShapeAlloc(std.testing.allocator, "File:Example.png|");
    defer std.testing.allocator.free(shape);

    try std.testing.expectEqualStrings("wikilink|ns:file|pipe-trick", shape);
}

test "binary structure report includes exact build payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure-fixture.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(input_path);
    var fixture = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .truncate = true });
    defer fixture.close(std.testing.io);
    try fixture.writeStreamingAll(std.testing.io,
        \\<mediawiki>
        \\  <page><title>Template:custom form of</title><ns>10</ns><revision><text xml:space="preserve">{{{1}}}</text></revision></page>
        \\</mediawiki>
    );

    const output_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(output_path);

    var analyzer = Analyzer.init(std.testing.allocator, .{
        .input_path = input_path,
        .output_path = output_path,
    });
    defer analyzer.deinit();

    analyzer.pages_seen = 3;
    analyzer.namespace_zero_pages = 2;
    analyzer.language_entries = 2;
    analyzer.heading_jumps = 1;
    analyzer.content_before_subheading = 0;
    analyzer.unbalanced_sections = 0;
    try analyzer.bump(&analyzer.heading_title_counts, "English");
    try analyzer.bump(&analyzer.heading_title_counts, "Noun");
    try analyzer.bump(&analyzer.heading_level_counts, "L3:Noun");
    try analyzer.bumpComposite(&analyzer.section_template_counts, "Noun", "custom form of", "\t");
    try analyzer.bumpComposite(&analyzer.section_template_counts, "Translations", "t", "\t");
    try analyzer.template_nodes.put(
        try analyzer.keyAllocator().dupe(u8, "customformof"),
        .{
            .template_deps = try analyzer.keyAllocator().alloc([]const u8, 0),
            .direct_modules = try analyzer.keyAllocator().alloc([]const u8, 0),
        },
    );
    try analyzer.template_nodes.put(
        try analyzer.keyAllocator().dupe(u8, "t"),
        .{
            .template_deps = try analyzer.keyAllocator().alloc([]const u8, 0),
            .direct_modules = try analyzer.keyAllocator().alloc([]const u8, 0),
        },
    );
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "customformof"),
        .{ .page_start = 10, .page_end = 20 },
    );
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "t"),
        .{ .page_start = 21, .page_end = 30 },
    );
    try analyzer.bump(&analyzer.translation_source_label_counts, "gloss");
    try analyzer.bump(&analyzer.translation_target_lang_counts, "French");
    try analyzer.addAnomaly("entry", "heading-jump", "bad nesting");
    try analyzer.entry_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "entry"),
        .{ .page_start = 1, .page_end = 9 },
    );

    try writeReport(std.testing.io, std.testing.allocator, &analyzer);

    var structure = try structure_report.loadStructureFileAlloc(std.testing.io, std.testing.allocator, output_path);
    defer structure.deinit(std.testing.allocator);

    try std.testing.expect(structure.build.compact_direct_patterns.len != 0);
    try std.testing.expect(structure.build.heading_specs.len != 0);
    try std.testing.expectEqual(@as(usize, 1), structure.dependencies.all_entry_pages.len);
    try std.testing.expectEqualStrings("entry", structure.dependencies.all_entry_pages[0].name);
    try std.testing.expectEqual(@as(usize, 2), structure.dependencies.all_template_pages.len);
    try std.testing.expectEqual(@as(usize, 1), structure.dependencies.reachable_template_pages.len);
}

test "dependency analysis does not synthesize alias nodes" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();

    try analyzer.template_nodes.put(
        try analyzer.keyAllocator().dupe(u8, "an-lite/node"),
        .{
            .template_deps = try analyzer.keyAllocator().alloc([]const u8, 0),
            .direct_modules = try analyzer.keyAllocator().alloc([]const u8, 0),
        },
    );
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "an-lite/node"),
        .{ .page_start = 10, .page_end = 20 },
    );
    try analyzer.module_nodes.put(
        try analyzer.keyAllocator().dupe(u8, "gender and number"),
        try analyzer.keyAllocator().alloc([]const u8, 0),
    );
    try analyzer.module_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "gender and number"),
        .{ .page_start = 30, .page_end = 40 },
    );

    try std.testing.expect(!analyzer.template_nodes.contains("an-lite"));
    try std.testing.expect(!analyzer.module_nodes.contains("gender and number/templates"));
    try std.testing.expect(!analyzer.template_page_refs.contains("an-lite"));
    try std.testing.expect(!analyzer.module_page_refs.contains("gender and number/templates"));
}

test "buildStructureDependenciesAlloc skips root templates without source pages" {
    var analyzer = Analyzer.init(std.testing.allocator, .{});
    defer analyzer.deinit();

    try analyzer.template_nodes.put(
        try analyzer.keyAllocator().dupe(u8, "realtemplate"),
        .{
            .template_deps = try analyzer.keyAllocator().alloc([]const u8, 0),
            .direct_modules = try analyzer.keyAllocator().alloc([]const u8, 0),
        },
    );
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "realtemplate"),
        .{ .page_start = 100, .page_end = 200 },
    );

    const line_templates = [_]structure_tables_support.TemplateSpec{
        .{ .code = 1, .name = "realtemplate" },
        .{ .code = 2, .name = "builtinonly" },
    };
    const build = structure_tables_support.BuildData{
        .heading_specs = &.{},
        .heading_level_specs = &.{},
        .line_templates = &line_templates,
        .compact_patterns = &.{},
        .compact_patterns_ext = &.{},
        .translation_templates = &.{},
        .target_languages = &.{},
        .language_labels = &.{},
        .structure_fingerprint = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const deps = try buildStructureDependenciesAlloc(arena.allocator(), std.testing.allocator, &analyzer, build);
    try std.testing.expectEqual(@as(usize, 1), deps.root_templates.len);
    try std.testing.expectEqualStrings("realtemplate", deps.root_templates[0]);
    try std.testing.expectEqual(@as(usize, 1), deps.reachable_templates.len);
    try std.testing.expectEqualStrings("realtemplate", deps.reachable_templates[0]);
    try std.testing.expectEqual(@as(usize, 1), deps.all_template_pages.len);
    try std.testing.expectEqualStrings("realtemplate", deps.all_template_pages[0].name);
    try std.testing.expectEqual(@as(usize, 1), deps.reachable_template_pages.len);
    try std.testing.expectEqualStrings("realtemplate", deps.reachable_template_pages[0].name);
    try std.testing.expectEqual(@as(u64, 100), deps.reachable_template_pages[0].page_start);
    try std.testing.expectEqual(@as(usize, 0), deps.unresolved_templates.len);
}

test "buildStructureDependenciesAlloc loads reachable dependencies from page refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/structure-refs-fixture.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(input_path);

    const fixture =
        \\<mediawiki>
        \\  <page><title>Template:realtemplate</title><ns>10</ns><revision><text xml:space="preserve">{{subtemplate}}{{#invoke:testmod|main}}</text></revision></page>
        \\  <page><title>Template:subtemplate</title><ns>10</ns><revision><text xml:space="preserve">body</text></revision></page>
        \\  <page><title>Module:testmod</title><ns>828</ns><revision><text xml:space="preserve">return { main = function() return "ok" end }</text></revision></page>
        \\</mediawiki>
    ;

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, fixture);

    const root_start = std.mem.indexOf(u8, fixture, "<page><title>Template:realtemplate</title>") orelse unreachable;
    const root_end_start = std.mem.indexOfPos(u8, fixture, root_start, "</page>") orelse unreachable;
    const child_start = std.mem.indexOf(u8, fixture, "<page><title>Template:subtemplate</title>") orelse unreachable;
    const child_end_start = std.mem.indexOfPos(u8, fixture, child_start, "</page>") orelse unreachable;
    const module_start = std.mem.indexOf(u8, fixture, "<page><title>Module:testmod</title>") orelse unreachable;
    const module_end_start = std.mem.indexOfPos(u8, fixture, module_start, "</page>") orelse unreachable;

    var analyzer = Analyzer.init(std.testing.allocator, .{ .input_path = input_path });
    defer analyzer.deinit();
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "realtemplate"),
        .{ .page_start = @intCast(root_start), .page_end = @intCast(root_end_start + "</page>".len) },
    );
    try analyzer.template_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "subtemplate"),
        .{ .page_start = @intCast(child_start), .page_end = @intCast(child_end_start + "</page>".len) },
    );
    try analyzer.module_page_refs.put(
        try analyzer.keyAllocator().dupe(u8, "testmod"),
        .{ .page_start = @intCast(module_start), .page_end = @intCast(module_end_start + "</page>".len) },
    );

    const line_templates = [_]structure_tables_support.TemplateSpec{
        .{ .code = 1, .name = "realtemplate" },
    };
    const build = structure_tables_support.BuildData{
        .heading_specs = &.{},
        .heading_level_specs = &.{},
        .line_templates = &line_templates,
        .compact_patterns = &.{},
        .compact_patterns_ext = &.{},
        .translation_templates = &.{},
        .target_languages = &.{},
        .language_labels = &.{},
        .structure_fingerprint = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const deps = try buildStructureDependenciesAlloc(arena.allocator(), std.testing.allocator, &analyzer, build);
    try std.testing.expect(stringSliceContains(deps.reachable_templates, "realtemplate"));
    try std.testing.expect(stringSliceContains(deps.reachable_templates, "subtemplate"));
    try std.testing.expect(stringSliceContains(deps.direct_modules, "testmod"));
    try std.testing.expect(stringSliceContains(deps.transitive_modules, "testmod"));
    try std.testing.expectEqual(@as(usize, 2), deps.reachable_template_pages.len);
    try std.testing.expectEqual(@as(usize, 1), deps.transitive_module_pages.len);
    try std.testing.expectEqual(@as(usize, 0), deps.unresolved_templates.len);
}
