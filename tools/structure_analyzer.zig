const std = @import("std");
const zxml = @import("zxml");

const encoder = @import("encoder");
const wikitext = encoder.wikitext;
const xml_decode = encoder.xml_decode;

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
    if (args.len >= 2 and std.mem.eql(u8, args[1], "help")) {
        printUsage();
        return;
    }

    const options = try parseOptions(args[1..]);
    const stats = try analyzeDump(init.io, init.gpa, options);

    std.debug.print(
        "wrote {s}\npages={d}\nns0={d}\nenglish_entries={d}\nheading_titles={d}\nunclassified_headings={d}\nanomalies={d}\n",
        .{
            options.output_path,
            stats.pages_seen,
            stats.namespace_zero_pages,
            stats.english_entries,
            stats.heading_title_keys,
            stats.unknown_heading_keys,
            stats.anomaly_samples,
        },
    );
}

const Options = struct {
    input_path: []const u8 = "enwiktionary.xml",
    output_path: []const u8 = "data/wiktionary-structure.json",
    format: OutputFormat = .json,
    limit_entries: ?usize = null,
    top_n: usize = 50,
    sample_limit: usize = 64,
};

const AnalyzeStats = struct {
    pages_seen: usize,
    namespace_zero_pages: usize,
    english_entries: usize,
    heading_title_keys: usize,
    unknown_heading_keys: usize,
    anomaly_samples: usize,
};

const OutputFormat = enum {
    json,
    text,
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
    english_entries: usize = 0,
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
    translation_source_label_counts: std.StringHashMapUnmanaged(u64) = .empty,
    translation_target_lang_counts: std.StringHashMapUnmanaged(u64) = .empty,
    anomaly_kind_counts: std.StringHashMapUnmanaged(u64) = .empty,
    anomaly_samples: std.ArrayListUnmanaged(AnomalySample) = .empty,
    key_scratch: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator, options: Options) Analyzer {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .options = options,
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
        self.translation_source_label_counts.deinit(self.gpa);
        self.translation_target_lang_counts.deinit(self.gpa);
        self.anomaly_kind_counts.deinit(self.gpa);
        self.anomaly_samples.deinit(self.gpa);
        self.key_scratch.deinit(self.gpa);
        self.arena.deinit();
    }

    fn stats(self: *const Analyzer) AnalyzeStats {
        return .{
            .pages_seen = self.pages_seen,
            .namespace_zero_pages = self.namespace_zero_pages,
            .english_entries = self.english_entries,
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

    fn analyzeEntry(self: *Analyzer, title: []const u8, english_section: []const u8) !void {
        self.english_entries += 1;

        var active_titles: [7][]const u8 = [_][]const u8{""} ** 7;
        active_titles[2] = "English";
        var seen_subheading = false;
        var balance: LogicalBalance = .{};

        var lines = std.mem.splitScalar(u8, english_section, '\n');
        while (lines.next()) |raw_input| {
            const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
            balance.update(raw_line);

            if (wikitext.parseHeadingLine(raw_line)) |heading| {
                try self.recordHeading(title, heading, &active_titles);
                if (heading.level >= 3) seen_subheading = true;
                continue;
            }

            const trimmed = std.mem.trim(u8, raw_line, " \t");
            const scope = currentHeadingLabel(&active_titles);
            const profile = currentHeadingProfile(&active_titles);
            const family = profile.family;
            const sig = lineSignature(trimmed);

            try self.bump(&self.line_signature_counts, sig);
            try self.bumpComposite(&self.section_signature_counts, scope, sig, "\t");
            try self.bumpComposite(&self.family_signature_counts, family, sig, "\t");
            try self.extractTemplates(scope, family, trimmed);
            try self.analyzeStructuredLine(profile, trimmed);

            if (!seen_subheading and trimmed.len != 0) {
                self.content_before_subheading += 1;
                try self.addAnomaly(title, "content-before-subheading", trimmed);
            }
        }

        if (balance.isOpen()) {
            self.unbalanced_sections += 1;
            try self.addAnomaly(title, "unbalanced-markup", "English section ended with open template/link/comment state");
        }
    }

    fn recordHeading(self: *Analyzer, title: []const u8, heading: wikitext.ParsedHeading, active_titles: *[7][]const u8) !void {
        try self.bump(&self.heading_title_counts, heading.title);
        self.key_scratch.items.len = 0;
        const level_key = try std.fmt.allocPrint(self.gpa, "L{d}:{s}", .{ heading.level, heading.title });
        defer self.gpa.free(level_key);
        try self.key_scratch.appendSlice(self.gpa, level_key);
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
            const jump_detail = try std.fmt.allocPrint(self.gpa, "jump from L{d} to L{d}: {s}", .{ deepest_before, heading.level, heading.title });
            defer self.gpa.free(jump_detail);
            try self.key_scratch.appendSlice(self.gpa, jump_detail);
            try self.addAnomaly(title, "heading-level-jump", self.key_scratch.items);
        }

        try self.validateHeadingPlacement(title, active_titles.*, heading, profile);
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

    fn validateHeadingPlacement(self: *Analyzer, title: []const u8, active_titles: [7][]const u8, heading: wikitext.ParsedHeading, profile: HeadingProfile) !void {
        const parent_level = parentHeadingLevel(active_titles, heading.level);
        const parent_title = if (parent_level == 0) "ROOT" else active_titles[parent_level];
        const parent_kind = if (parent_level == 0)
            "root"
        else
            classifyHeadingTitle(parent_title, parent_level).family;

        if (!isExpectedHeadingLevel(profile.family, heading.level)) {
            const detail = try std.fmt.allocPrint(self.gpa, "{s} at L{d}", .{ heading.title, heading.level });
            defer self.gpa.free(detail);
            try self.addAnomaly(title, "unexpected-heading-level", detail);
        }

        if (!isExpectedHeadingParent(profile.family, parent_kind)) {
            const detail = try std.fmt.allocPrint(self.gpa, "{s} under {s}", .{ heading.title, parent_title });
            defer self.gpa.free(detail);
            try self.addAnomaly(title, "unexpected-heading-parent", detail);
        }
    }

    fn extractTemplates(self: *Analyzer, scope: []const u8, family: []const u8, line: []const u8) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, pos, "{{")) |open| {
            var start = open + 2;
            while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}

            var end = start;
            while (end < line.len and line[end] != '|' and line[end] != '}' and line[end] != '\n' and line[end] != '\r') : (end += 1) {}
            const name = std.mem.trim(u8, line[start..end], " \t");
            if (name.len != 0 and name.len <= 80) {
                try self.bump(&self.template_counts, name);
                try self.bumpComposite(&self.section_template_counts, scope, name, "\t");
                try self.bumpComposite(&self.family_template_counts, family, name, "\t");
            }
            pos = open + 2;
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

fn analyzeDump(io: std.Io, allocator: std.mem.Allocator, options: Options) !AnalyzeStats {
    var input_file = try std.Io.Dir.cwd().openFile(io, options.input_path, .{});
    defer input_file.close(io);

    var analyzer = Analyzer.init(allocator, options);
    defer analyzer.deinit();

    var stream_parser = StreamParser.init(allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    const stat = try input_file.stat(io);
    if (stat.size == 0) return analyzer.stats();

    const map_len = std.mem.alignForward(usize, @as(usize, @intCast(stat.size)), std.heap.page_size_min);
    const mapped = try std.posix.mmap(
        null,
        map_len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        input_file.handle,
        0,
    );
    defer std.posix.munmap(mapped);

    try processMappedInput(
        mapped[0..@as(usize, @intCast(stat.size))],
        &stream_parser,
        &page_arena,
        &analyzer,
    );
    try writeReport(io, allocator, &analyzer);
    return analyzer.stats();
}

fn processMappedInput(
    mapped: []const u8,
    stream_parser: *StreamParser,
    page_arena: *std.heap.ArenaAllocator,
    analyzer: *Analyzer,
) !void {
    var consumed: usize = 0;
    while (true) {
        const start = std.mem.indexOfPos(u8, mapped, consumed, "<page>") orelse break;
        const end_start = std.mem.indexOfPos(u8, mapped, start, "</page>") orelse break;
        const page_end = end_start + "</page>".len;

        const page_allocator = page_arena.allocator();
        processPageFragment(page_allocator, stream_parser, mapped[start..page_end], analyzer) catch |err| {
            std.log.warn("skipping page after parse error: {}", .{err});
        };
        consumed = page_end;
        _ = page_arena.reset(.retain_capacity);

        if (analyzer.options.limit_entries) |limit| {
            if (analyzer.english_entries >= limit) break;
        }
        if (analyzer.pages_seen != 0 and analyzer.pages_seen % 10_000 == 0) {
            std.log.info("pages={d} ns0={d} english_entries={d}", .{
                analyzer.pages_seen,
                analyzer.namespace_zero_pages,
                analyzer.english_entries,
            });
        }
    }
}

fn processPageFragment(
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    analyzer: *Analyzer,
) !void {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);
    analyzer.pages_seen += 1;

    const ns_raw = capture.ns_raw orelse return;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return;
    if (ns != 0) return;
    analyzer.namespace_zero_pages += 1;

    const text_raw = capture.text_raw orelse return;
    if (std.mem.indexOf(u8, text_raw, "==English==") == null) return;

    const text = try xml_decode.decodeAlloc(allocator, text_raw);
    const english_section = wikitext.extractEnglishSection(text) orelse return;
    const title = try xml_decode.decodeAlloc(allocator, capture.title_raw orelse return);

    try analyzer.analyzeEntry(title, english_section);
}

fn writeReport(io: std.Io, allocator: std.mem.Allocator, analyzer: *Analyzer) !void {
    if (analyzer.options.format == .json) {
        try writeJsonReport(io, allocator, analyzer);
        return;
    }

    try writeTextReport(io, allocator, analyzer);
}

fn writeTextReport(io: std.Io, allocator: std.mem.Allocator, analyzer: *Analyzer) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print(
        \\# Wiktionary Structure Report
        \\
        \\Input: {s}
        \\Pages scanned: {d}
        \\Namespace 0 pages: {d}
        \\English entries: {d}
        \\Heading level jumps: {d}
        \\Content before first subheading: {d}
        \\Unbalanced English sections: {d}
        \\
        \\## Heading Kinds
        \\
    , .{
        analyzer.options.input_path,
        analyzer.pages_seen,
        analyzer.namespace_zero_pages,
        analyzer.english_entries,
        analyzer.heading_jumps,
        analyzer.content_before_subheading,
        analyzer.unbalanced_sections,
    });

    try writeSortedMap(&out.writer, allocator, analyzer.heading_kind_counts, analyzer.options.top_n);
    try out.writer.print("\n## Parser Kinds\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.parser_kind_counts, analyzer.options.top_n);
    try out.writer.print("\n## Heading Titles\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.heading_title_counts, analyzer.options.top_n);
    try out.writer.print("\n## Headings By Level\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.heading_level_counts, analyzer.options.top_n);
    try out.writer.print("\n## Unclassified Headings\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.unclassified_heading_counts, analyzer.options.top_n);
    try out.writer.print("\n## Heading Transitions\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.heading_edge_counts, analyzer.options.top_n);
    try out.writer.print("\n## Global Formatting Signatures\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.line_signature_counts, analyzer.options.top_n);
    try out.writer.print("\n## Formatting By Active Heading\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.section_signature_counts, analyzer.options.top_n);
    try out.writer.print("\n## Formatting By Heading Family\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.family_signature_counts, analyzer.options.top_n);
    try out.writer.print("\n## Template Names\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.template_counts, analyzer.options.top_n);
    try out.writer.print("\n## Templates By Active Heading\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.section_template_counts, analyzer.options.top_n);
    try out.writer.print("\n## Templates By Heading Family\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.family_template_counts, analyzer.options.top_n);
    try out.writer.print("\n## Translation Source Labels\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.translation_source_label_counts, analyzer.options.top_n);
    try out.writer.print("\n## Translation Target Languages\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.translation_target_lang_counts, analyzer.options.top_n);
    try out.writer.print("\n## Structural Anomaly Kinds\n\n", .{});
    try writeSortedMap(&out.writer, allocator, analyzer.anomaly_kind_counts, analyzer.options.top_n);
    try out.writer.print("\n## Structural Anomaly Samples\n\n", .{});
    for (analyzer.anomaly_samples.items) |sample| {
        try out.writer.print("- [{s}] {s}: {s}\n", .{ sample.kind, sample.title, sample.detail });
    }

    if (std.mem.eql(u8, analyzer.options.output_path, "-")) {
        std.debug.print("{s}", .{out.written()});
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(io, analyzer.options.output_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, out.written(), 0);
}

fn writeJsonReport(io: std.Io, allocator: std.mem.Allocator, analyzer: *Analyzer) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("{{\n", .{});
    try out.writer.print("  \"input\": ", .{});
    try writeJsonString(&out.writer, analyzer.options.input_path);
    try out.writer.print(",\n  \"summary\": {{\"pages_scanned\": {d}, \"namespace_zero_pages\": {d}, \"english_entries\": {d}, \"heading_level_jumps\": {d}, \"content_before_subheading\": {d}, \"unbalanced_sections\": {d}, \"unclassified_heading_titles\": {d}}},\n", .{
        analyzer.pages_seen,
        analyzer.namespace_zero_pages,
        analyzer.english_entries,
        analyzer.heading_jumps,
        analyzer.content_before_subheading,
        analyzer.unbalanced_sections,
        analyzer.unclassified_heading_counts.count(),
    });

    try writeJsonMapField(&out.writer, allocator, "heading_families", analyzer.heading_kind_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "parser_kinds", analyzer.parser_kind_counts);
    try out.writer.print(",\n", .{});
    try writeJsonHeadingProfilesField(&out.writer, allocator, analyzer.heading_title_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "headings_by_level", analyzer.heading_level_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "unclassified_headings", analyzer.unclassified_heading_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "heading_transitions", analyzer.heading_edge_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "formatting_signatures", analyzer.line_signature_counts);
    try out.writer.print(",\n", .{});
    try writeJsonCompositeField(&out.writer, allocator, "formatting_by_heading", analyzer.section_signature_counts, "heading", "signature");
    try out.writer.print(",\n", .{});
    try writeJsonCompositeField(&out.writer, allocator, "formatting_by_family", analyzer.family_signature_counts, "family", "signature");
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "template_names", analyzer.template_counts);
    try out.writer.print(",\n", .{});
    try writeJsonCompositeField(&out.writer, allocator, "templates_by_heading", analyzer.section_template_counts, "heading", "template");
    try out.writer.print(",\n", .{});
    try writeJsonCompositeField(&out.writer, allocator, "templates_by_family", analyzer.family_template_counts, "family", "template");
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "translation_source_labels", analyzer.translation_source_label_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "translation_target_languages", analyzer.translation_target_lang_counts);
    try out.writer.print(",\n", .{});
    try writeJsonMapField(&out.writer, allocator, "anomaly_kinds", analyzer.anomaly_kind_counts);
    try out.writer.print(",\n  \"anomaly_samples\": [\n", .{});
    for (analyzer.anomaly_samples.items, 0..) |sample, idx| {
        if (idx != 0) try out.writer.print(",\n", .{});
        try out.writer.print("    {{\"title\": ", .{});
        try writeJsonString(&out.writer, sample.title);
        try out.writer.print(", \"kind\": ", .{});
        try writeJsonString(&out.writer, sample.kind);
        try out.writer.print(", \"detail\": ", .{});
        try writeJsonString(&out.writer, sample.detail);
        try out.writer.print("}}", .{});
    }
    try out.writer.print("\n  ]\n}}\n", .{});

    if (std.mem.eql(u8, analyzer.options.output_path, "-")) {
        std.debug.print("{s}", .{out.written()});
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(io, analyzer.options.output_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, out.written(), 0);
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

fn writeSortedMap(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(u64),
    limit: usize,
) !void {
    var items = try allocator.alloc(SortedCount, map.count());
    defer allocator.free(items);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        items[idx] = .{
            .key = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        };
    }

    std.mem.sort(SortedCount, items, {}, struct {
        fn lessThan(_: void, lhs: SortedCount, rhs: SortedCount) bool {
            if (lhs.count != rhs.count) return lhs.count > rhs.count;
            return std.mem.order(u8, lhs.key, rhs.key) == .lt;
        }
    }.lessThan);

    const max = @min(limit, items.len);
    for (items[0..max]) |item| {
        try writer.print("- {s}: {d}\n", .{ item.key, item.count });
    }
}

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
        const profile = classifyHeadingTitle(item.key, if (std.mem.eql(u8, item.key, "English")) 2 else 3);
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

fn currentHeadingLabel(active_titles: *const [7][]const u8) []const u8 {
    const level = deepestHeadingLevel(active_titles.*);
    return if (level <= 2) "English" else active_titles[level];
}

fn currentHeadingProfile(active_titles: *const [7][]const u8) HeadingProfile {
    const level = deepestHeadingLevel(active_titles.*);
    if (level <= 2) return classifyHeadingTitle("English", 2);
    return classifyHeadingTitle(active_titles[level], level);
}

fn appendHeadingLabel(list: *std.ArrayList(u8), allocator: std.mem.Allocator, level: u8, title: []const u8) !void {
    if (level == 0) {
        try list.appendSlice(allocator, "ROOT");
        return;
    }
    const label = try std.fmt.allocPrint(allocator, "L{d}:{s}", .{ level, title });
    defer allocator.free(label);
    try list.appendSlice(allocator, label);
}

fn classifyHeadingTitle(title: []const u8, level: u8) HeadingProfile {
    if (level == 2 and std.mem.eql(u8, title, "English")) {
        return .{ .family = "language-root", .parser_kind = "language-root", .canonical_title = "English" };
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
            if (std.mem.endsWith(u8, options.output_path, ".txt")) options.format = .text;
            if (std.mem.endsWith(u8, options.output_path, ".json")) options.format = .json;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            options.format = if (std.mem.eql(u8, args[i + 1], "text")) .text else .json;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            options.limit_entries = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--top") and i + 1 < args.len) {
            options.top_n = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--samples") and i + 1 < args.len) {
            options.sample_limit = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\dict-structure [--input enwiktionary.xml] [--output data/wiktionary-structure.json]
        \\               [--format json|text] [--limit 10000] [--top 50] [--samples 64]
        \\
    , .{});
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
