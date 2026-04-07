const std = @import("std");
const renderer = @import("renderer");
const wikitext = @import("wikitext_source");
const cli_args = @import("cli_args");
const required_path = @import("required_path");

const html_render = renderer.html_render;
const xml_decode = renderer.xml_decode;

pub fn main(init: std.process.Init) !void {
    const args_allocator = init.arena.allocator();
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(args_allocator);
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try printUsage(init.io);
        return;
    }

    const options = try parseOptions(args[1..]);
    required_path.ensureExistsOrExit(init.io, options.input_path, "template audit input");
    required_path.ensureExistsOrExit(init.io, options.structure_path, "template audit structure report");

    var catalog = try loadCatalogAlloc(allocator, options.structure_path, options.template_name);
    defer catalog.deinit(allocator);

    const scan_stats, const audit_stats = if (catalog.cases.len == 0)
        .{ ScanStats{}, AuditStats{} }
    else
        .{ try scanDumpForSamples(init.io, allocator, options, &catalog), try auditCatalog(allocator, &catalog) };

    const report = try buildReportAlloc(allocator, options, catalog.cases, scan_stats, audit_stats);
    defer allocator.free(report);
    try writeReport(init.io, options.report_path, report);

    std.debug.print(
        "template audit: templates={d} sampled={d} missing={d} mismatches={d} strict_failures={d} reference_failures={d}\n",
        .{
            catalog.cases.len,
            scan_stats.sampled_templates,
            audit_stats.missing_samples,
            audit_stats.mismatches,
            audit_stats.strict_failures,
            audit_stats.reference_failures,
        },
    );

    if (auditStatsFailed(audit_stats)) return error.TemplateAuditFailed;
}

const Options = struct {
    input_path: []const u8 = "data/wiktionary.xml",
    structure_path: []const u8 = "data/wiktionary-structure.json",
    report_path: []const u8 = "data/template-audit-report.txt",
    page_limit: ?usize = null,
    template_name: ?[]const u8 = null,
};

const TemplateSample = struct {
    // Exact balanced invocation used to identify the target template in reports.
    invocation: []const u8,
    // Full logical line lifted from the dump so the generated section keeps real context.
    logical_line: []const u8,
    // Title of the page where the invocation was discovered.
    title: []const u8,
    // Lower scores are preferred because they isolate the target template better.
    enclosing_template_count: u16,
    level3_title: []const u8 = "",
    level4_title: []const u8 = "",
    level5_title: []const u8 = "",

    fn deinit(self: *TemplateSample, allocator: std.mem.Allocator) void {
        allocator.free(self.invocation);
        allocator.free(self.logical_line);
        allocator.free(self.title);
        if (self.level3_title.len != 0) allocator.free(self.level3_title);
        if (self.level4_title.len != 0) allocator.free(self.level4_title);
        if (self.level5_title.len != 0) allocator.free(self.level5_title);
        self.* = undefined;
    }
};

const FailureDetails = struct {
    reference_text: []const u8 = "",
    actual_text: []const u8 = "",
    detail: []const u8 = "",

    fn deinit(self: *FailureDetails, allocator: std.mem.Allocator) void {
        if (self.reference_text.len != 0) allocator.free(self.reference_text);
        if (self.actual_text.len != 0) allocator.free(self.actual_text);
        if (self.detail.len != 0) allocator.free(self.detail);
        self.* = undefined;
    }
};

const AuditOutcome = union(enum) {
    pending,
    ok,
    missing_sample,
    reference_failure: FailureDetails,
    strict_failure: FailureDetails,
    mismatch: FailureDetails,

    fn deinit(self: *AuditOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .reference_failure => |*details| details.deinit(allocator),
            .strict_failure => |*details| details.deinit(allocator),
            .mismatch => |*details| details.deinit(allocator),
            else => {},
        }
        self.* = .pending;
    }
};

const TemplateCase = struct {
    name: []const u8,
    key: []const u8,
    sample: ?TemplateSample = null,
    outcome: AuditOutcome = .pending,

    fn deinit(self: *TemplateCase, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.key);
        if (self.sample) |*sample| sample.deinit(allocator);
        self.outcome.deinit(allocator);
        self.* = undefined;
    }
};

const Catalog = struct {
    cases: []TemplateCase,
    index_by_key: std.StringHashMapUnmanaged(usize) = .empty,
    sampled_count: usize = 0,

    fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.cases) |*case_entry| case_entry.deinit(allocator);
        allocator.free(self.cases);
        self.index_by_key.deinit(allocator);
        self.* = undefined;
    }

    fn lookup(self: *const Catalog, allocator: std.mem.Allocator, scratch: *std.ArrayList(u8), name: []const u8) !?usize {
        scratch.items.len = 0;
        try appendCanonicalTemplateKey(scratch, allocator, name);
        return self.index_by_key.get(scratch.items);
    }
};

const ScanStats = struct {
    pages_seen: usize = 0,
    english_pages_seen: usize = 0,
    sampled_templates: usize = 0,
};

const AuditStats = struct {
    missing_samples: usize = 0,
    mismatches: usize = 0,
    strict_failures: usize = 0,
    reference_failures: usize = 0,
};

const PageNamespace = enum {
    other,
    ns0,
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
            if (self.comments != 0) continue;
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

const TemplateMatch = struct {
    index: usize,
    start: usize,
    end: usize,
};

fn printUsage(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    defer writer.flush() catch {};
    try writer.interface.print(
        \\dict-template-audit [--input data/wiktionary.xml]
        \\                    [--structure data/wiktionary-structure.json]
        \\                    [--report data/template-audit-report.txt]
        \\                    [--page-limit N]
        \\                    [--template name]
        \\
    , .{});
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    if (cli_args.flagValue(args, "--input")) |value| options.input_path = value;
    if (cli_args.flagValue(args, "--structure")) |value| options.structure_path = value;
    if (cli_args.flagValue(args, "--report")) |value| options.report_path = value;
    if (cli_args.flagValue(args, "--template")) |value| options.template_name = value;
    options.page_limit = try cli_args.parseOptionalIntFlag(usize, args, "--page-limit");
    return options;
}

fn loadCatalogAlloc(allocator: std.mem.Allocator, structure_path: []const u8, filter_template: ?[]const u8) !Catalog {
    const bytes = try readFileAlloc(std.Options.debug_io, allocator, structure_path);
    defer allocator.free(bytes);

    const Report = struct {
        build: struct {
            line_templates: []const struct {
                name: []const u8,
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Report, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var selected_count: usize = 0;
    for (parsed.value.build.line_templates) |entry| {
        if (filter_template) |expected| {
            if (!templateNamesEqual(entry.name, expected)) continue;
        }
        selected_count += 1;
    }

    const cases = try allocator.alloc(TemplateCase, selected_count);
    errdefer allocator.free(cases);

    var catalog: Catalog = .{ .cases = cases };
    errdefer catalog.index_by_key.deinit(allocator);

    var write_idx: usize = 0;
    for (parsed.value.build.line_templates) |entry| {
        if (filter_template) |expected| {
            if (!templateNamesEqual(entry.name, expected)) continue;
        }

        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);

        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        try appendCanonicalTemplateKey(&key_buf, allocator, entry.name);
        const owned_key = try key_buf.toOwnedSlice(allocator);
        errdefer allocator.free(owned_key);

        catalog.cases[write_idx] = .{
            .name = owned_name,
            .key = owned_key,
        };

        const gop = try catalog.index_by_key.getOrPut(allocator, owned_key);
        if (!gop.found_existing) {
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = write_idx;
        }
        write_idx += 1;
    }

    if (filter_template != null and selected_count == 0) return error.TemplateNotFound;
    return catalog;
}

fn scanDumpForSamples(io: std.Io, allocator: std.mem.Allocator, options: Options, catalog: *Catalog) !ScanStats {
    var stats: ScanStats = .{};
    if (catalog.cases.len == 0) return stats;

    var file = try std.Io.Dir.cwd().openFile(io, options.input_path, .{});
    defer file.close(io);

    var read_buf: [256 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    var current_title: ?[]u8 = null;
    defer if (current_title) |title| allocator.free(title);
    var current_ns: PageNamespace = .other;
    var capture_text = false;
    var text_accum = std.ArrayList(u8).empty;
    defer text_accum.deinit(allocator);

    while (try readNextLineAlloc(&file_reader.interface, allocator, &line_buf)) |line| {
        if (std.mem.indexOf(u8, line, "<page>") != null) {
            stats.pages_seen += 1;
            if (options.page_limit) |limit| {
                if (stats.pages_seen > limit) break;
            }
        }

        if (extractTagText(line, "title")) |title| {
            if (current_title) |old| allocator.free(old);
            current_title = try allocator.dupe(u8, title);
        }
        if (extractTagText(line, "ns")) |ns| {
            current_ns = if (std.mem.eql(u8, ns, "0")) .ns0 else .other;
        }

        if (std.mem.indexOf(u8, line, "<text")) |_| {
            capture_text = true;
            text_accum.clearRetainingCapacity();
            if (std.mem.indexOf(u8, line, ">")) |start_tag_end| {
                const rest = line[start_tag_end + 1 ..];
                if (std.mem.indexOf(u8, rest, "</text>")) |end_idx| {
                    try text_accum.appendSlice(allocator, rest[0..end_idx]);
                    capture_text = false;
                    try maybeProcessPageText(allocator, current_title, current_ns, text_accum.items, catalog, &stats);
                    if (catalog.sampled_count == catalog.cases.len) break;
                } else {
                    try text_accum.appendSlice(allocator, rest);
                    try text_accum.append(allocator, '\n');
                }
            }
            continue;
        }

        if (!capture_text) continue;
        if (std.mem.indexOf(u8, line, "</text>")) |end_idx| {
            try text_accum.appendSlice(allocator, line[0..end_idx]);
            capture_text = false;
            try maybeProcessPageText(allocator, current_title, current_ns, text_accum.items, catalog, &stats);
            if (catalog.sampled_count == catalog.cases.len) break;
        } else {
            try text_accum.appendSlice(allocator, line);
            try text_accum.append(allocator, '\n');
        }
    }

    stats.sampled_templates = catalog.sampled_count;
    return stats;
}

fn maybeProcessPageText(
    allocator: std.mem.Allocator,
    current_title: ?[]const u8,
    current_ns: PageNamespace,
    raw_text: []const u8,
    catalog: *Catalog,
    stats: *ScanStats,
) !void {
    if (current_ns != .ns0 or current_title == null) return;
    const decoded = try xml_decode.decodeAlloc(allocator, raw_text);
    defer allocator.free(decoded);

    const english = wikitext.extractEnglishSection(decoded) orelse return;
    stats.english_pages_seen += 1;
    try collectSamplesFromEnglishSection(allocator, current_title.?, english, catalog);
}

fn collectSamplesFromEnglishSection(
    allocator: std.mem.Allocator,
    title: []const u8,
    english_section: []const u8,
    catalog: *Catalog,
) !void {
    var active_titles: [7][]const u8 = [_][]const u8{""} ** 7;
    active_titles[2] = "English";
    var logical_line = std.ArrayList(u8).empty;
    defer logical_line.deinit(allocator);
    var match_scratch = std.ArrayList(u8).empty;
    defer match_scratch.deinit(allocator);
    var balance: LogicalBalance = .{};

    var lines = std.mem.splitScalar(u8, english_section, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
        if (wikitext.parseHeadingLine(raw_line)) |heading| {
            active_titles[heading.level] = heading.title;
            var clear_level = heading.level + 1;
            while (clear_level < active_titles.len) : (clear_level += 1) active_titles[clear_level] = "";
            continue;
        }

        if (logical_line.items.len != 0) {
            try logical_line.append(allocator, '\n');
            try logical_line.appendSlice(allocator, raw_line);
            balance.update(raw_line);
            if (balance.isOpen()) continue;

            try collectSamplesFromLogicalLine(allocator, title, logical_line.items, active_titles, catalog, &match_scratch);
            logical_line.items.len = 0;
            balance = .{};
            continue;
        }

        var line_balance: LogicalBalance = .{};
        line_balance.update(raw_line);
        if (line_balance.isOpen()) {
            try logical_line.appendSlice(allocator, raw_line);
            balance = line_balance;
            continue;
        }

        try collectSamplesFromLogicalLine(allocator, title, raw_line, active_titles, catalog, &match_scratch);
        if (catalog.sampled_count == catalog.cases.len) return;
    }

    if (logical_line.items.len != 0) {
        try collectSamplesFromLogicalLine(allocator, title, logical_line.items, active_titles, catalog, &match_scratch);
    }
}

fn collectSamplesFromLogicalLine(
    allocator: std.mem.Allocator,
    title: []const u8,
    logical_line: []const u8,
    active_titles: [7][]const u8,
    catalog: *Catalog,
    match_scratch: *std.ArrayList(u8),
) !void {
    const trimmed = std.mem.trim(u8, logical_line, " \t");
    if (trimmed.len == 0) return;

    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(allocator);
    var matches = std.ArrayList(TemplateMatch).empty;
    defer matches.deinit(allocator);

    var i: usize = 0;
    var total_templates: usize = 0;
    while (i + 1 < logical_line.len) {
        if (std.mem.eql(u8, logical_line[i .. i + 2], "{{")) {
            try starts.append(allocator, i);
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, logical_line[i .. i + 2], "}}")) {
            if (starts.items.len != 0) {
                const start = starts.pop().?;
                total_templates += 1;
                const invocation = logical_line[start .. i + 2];
                const name = templateNameFromInvocation(invocation);
                if (name.len != 0) {
                    if (try catalog.lookup(allocator, match_scratch, name)) |index| {
                        try matches.append(allocator, .{
                            .index = index,
                            .start = start,
                            .end = i + 2,
                        });
                    }
                }
            }
            i += 2;
            continue;
        }
        i += 1;
    }

    for (matches.items) |match| {
        try maybeRecordSample(
            allocator,
            catalog,
            match.index,
            title,
            logical_line[match.start..match.end],
            logical_line,
            active_titles,
            @intCast(@min(total_templates, std.math.maxInt(u16))),
        );
    }
}

fn maybeRecordSample(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    index: usize,
    title: []const u8,
    invocation: []const u8,
    logical_line: []const u8,
    active_titles: [7][]const u8,
    total_templates: u16,
) !void {
    const entry = &catalog.cases[index];
    if (entry.sample) |existing| {
        if (!sampleIsBetter(invocation, total_templates, existing)) return;
        var old = entry.sample.?;
        old.deinit(allocator);
    } else {
        catalog.sampled_count += 1;
    }

    entry.sample = .{
        .invocation = try allocator.dupe(u8, invocation),
        .logical_line = try allocator.dupe(u8, logical_line),
        .title = try allocator.dupe(u8, title),
        .enclosing_template_count = total_templates,
        .level3_title = if (active_titles[3].len != 0) try allocator.dupe(u8, active_titles[3]) else "",
        .level4_title = if (active_titles[4].len != 0) try allocator.dupe(u8, active_titles[4]) else "",
        .level5_title = if (active_titles[5].len != 0) try allocator.dupe(u8, active_titles[5]) else "",
    };
}

fn sampleIsBetter(invocation: []const u8, template_count: u16, existing: TemplateSample) bool {
    if (template_count != existing.enclosing_template_count) return template_count < existing.enclosing_template_count;
    if (invocation.len != existing.invocation.len) return invocation.len < existing.invocation.len;
    return std.mem.lessThan(u8, invocation, existing.invocation);
}

fn auditCatalog(allocator: std.mem.Allocator, catalog: *Catalog) !AuditStats {
    var stats: AuditStats = .{};
    for (catalog.cases) |*case_entry| {
        case_entry.outcome.deinit(allocator);
        if (case_entry.sample == null) {
            case_entry.outcome = .missing_sample;
            stats.missing_samples += 1;
            continue;
        }

        const sample = case_entry.sample.?;
        const generated_section = try buildGeneratedSectionAlloc(allocator, sample);
        defer allocator.free(generated_section);

        const reference_input = stripListPrefix(sample.logical_line);
        const reference_raw = wikitext.renderWikitextToOwned(allocator, reference_input, 16 * 1024) catch |err| {
            case_entry.outcome = .{ .reference_failure = .{
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            } };
            stats.reference_failures += 1;
            continue;
        };
        defer allocator.free(reference_raw);

        const reference_text = try normalizeAuditTextAlloc(allocator, reference_raw);
        errdefer allocator.free(reference_text);

        const actual_text_raw = renderSectionBodiesVisibleTextAlloc(allocator, generated_section) catch |err| {
            allocator.free(reference_text);
            case_entry.outcome = .{ .reference_failure = .{
                .detail = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
            } };
            stats.reference_failures += 1;
            continue;
        };
        defer allocator.free(actual_text_raw);
        const actual_text = try normalizeAuditTextAlloc(allocator, actual_text_raw);
        errdefer allocator.free(actual_text);

        if (std.mem.eql(u8, reference_text, actual_text)) {
            allocator.free(reference_text);
            allocator.free(actual_text);
            case_entry.outcome = .ok;
            continue;
        }

        case_entry.outcome = .{ .mismatch = .{
            .reference_text = reference_text,
            .actual_text = actual_text,
            .detail = try allocator.dupe(u8, "normalized visible text differs"),
        } };
        stats.mismatches += 1;
    }
    return stats;
}

fn auditStatsFailed(stats: AuditStats) bool {
    return stats.missing_samples != 0 or
        stats.mismatches != 0 or
        stats.strict_failures != 0 or
        stats.reference_failures != 0;
}

fn buildReportAlloc(
    allocator: std.mem.Allocator,
    options: Options,
    cases: []const TemplateCase,
    scan_stats: ScanStats,
    audit_stats: AuditStats,
) ![]u8 {
    var report: std.ArrayList(u8) = .empty;
    errdefer report.deinit(allocator);

    try appendFmt(&report, allocator,
        \\# Template Audit
        \\
        \\Input: {s}
        \\Structure: {s}
        \\Pages scanned: {d}
        \\English pages scanned: {d}
        \\Templates: {d}
        \\Sampled: {d}
        \\Missing samples: {d}
        \\Mismatches: {d}
        \\Strict failures: {d}
        \\Reference failures: {d}
        \\
    , .{
        options.input_path,
        options.structure_path,
        scan_stats.pages_seen,
        scan_stats.english_pages_seen,
        cases.len,
        scan_stats.sampled_templates,
        audit_stats.missing_samples,
        audit_stats.mismatches,
        audit_stats.strict_failures,
        audit_stats.reference_failures,
    });

    for (cases) |case_entry| {
        switch (case_entry.outcome) {
            .ok => continue,
            .pending => continue,
            .missing_sample => {
                try appendFmt(&report, allocator, "## {s}\nstatus: missing-sample\n\n", .{case_entry.name});
            },
            .reference_failure => |details| {
                try appendFailureReport(&report, allocator, case_entry, "reference-failure", details);
            },
            .strict_failure => |details| {
                try appendFailureReport(&report, allocator, case_entry, "strict-failure", details);
            },
            .mismatch => |details| {
                try appendFailureReport(&report, allocator, case_entry, "mismatch", details);
            },
        }
    }

    return report.toOwnedSlice(allocator);
}

fn appendFailureReport(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    case_entry: TemplateCase,
    status: []const u8,
    details: FailureDetails,
) !void {
    try appendFmt(out, allocator, "## {s}\nstatus: {s}\n", .{ case_entry.name, status });
    if (case_entry.sample) |sample| {
        try appendFmt(out, allocator, "page: {s}\n", .{sample.title});
        try appendFmt(out, allocator, "sample: {s}\n", .{sample.invocation});
        try appendFmt(out, allocator, "line: {s}\n", .{sample.logical_line});
        if (sample.level3_title.len != 0) try appendFmt(out, allocator, "level3: {s}\n", .{sample.level3_title});
        if (sample.level4_title.len != 0) try appendFmt(out, allocator, "level4: {s}\n", .{sample.level4_title});
        if (sample.level5_title.len != 0) try appendFmt(out, allocator, "level5: {s}\n", .{sample.level5_title});
        try appendFmt(out, allocator, "template-count: {d}\n", .{sample.enclosing_template_count});
    }
    if (details.detail.len != 0) try appendFmt(out, allocator, "detail: {s}\n", .{details.detail});
    if (details.reference_text.len != 0) try appendFmt(out, allocator, "reference: {s}\n", .{details.reference_text});
    if (details.actual_text.len != 0) try appendFmt(out, allocator, "actual: {s}\n", .{details.actual_text});
    try out.append(allocator, '\n');
}

fn writeReport(io: std.Io, report_path: []const u8, contents: []const u8) !void {
    if (std.mem.eql(u8, report_path, "-")) {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
        defer writer.flush() catch {};
        try writer.interface.writeAll(contents);
        return;
    }

    var file = try std.Io.Dir.cwd().createFile(io, report_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    defer writer.flush() catch {};
    try writer.interface.writeAll(contents);
}

fn stripListPrefix(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r\n");
    while (trimmed.len != 0 and (trimmed[0] == '#' or trimmed[0] == '*' or trimmed[0] == ':' or trimmed[0] == ';')) {
        trimmed = std.mem.trimStart(u8, trimmed[1..], " \t");
    }
    return trimmed;
}

fn buildGeneratedSectionAlloc(allocator: std.mem.Allocator, sample: TemplateSample) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "==English==\n");
    if (sample.level3_title.len != 0) {
        try appendHeading(&out, allocator, 3, sample.level3_title);
    } else {
        try appendHeading(&out, allocator, 3, "Noun");
    }
    if (sample.level4_title.len != 0) try appendHeading(&out, allocator, 4, sample.level4_title);
    if (sample.level5_title.len != 0) try appendHeading(&out, allocator, 5, sample.level5_title);
    try out.appendSlice(allocator, sample.logical_line);
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn appendHeading(out: *std.ArrayList(u8), allocator: std.mem.Allocator, level: u8, title: []const u8) !void {
    var eq_count: u8 = 0;
    while (eq_count < level) : (eq_count += 1) try out.append(allocator, '=');
    try out.appendSlice(allocator, title);
    eq_count = 0;
    while (eq_count < level) : (eq_count += 1) try out.append(allocator, '=');
    try out.append(allocator, '\n');
}

fn renderSectionBodiesVisibleTextAlloc(allocator: std.mem.Allocator, english_section: []const u8) ![]u8 {
    const sections = try html_render.renderEnglishSectionWithOptionsAlloc(allocator, english_section, .{
        .strict = false,
    });
    defer {
        for (sections) |*section| section.deinit(allocator);
        allocator.free(sections);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (sections) |section| {
        const visible = try stripHtmlToVisibleTextAlloc(allocator, section.html);
        defer allocator.free(visible);
        const trimmed = std.mem.trim(u8, visible, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (out.items.len != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, trimmed);
    }

    return out.toOwnedSlice(allocator);
}

fn stripHtmlToVisibleTextAlloc(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            try out.append(allocator, html[i]);
            i += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const tag = html[i .. end + 1];
        if (htmlTagNeedsSeparator(tag)) {
            try appendSeparator(&out, allocator, if (tagEndsListItem(tag)) "; " else " ");
        }
        i = end + 1;
    }

    return xml_decode.decodeAlloc(allocator, out.items);
}

fn appendSeparator(out: *std.ArrayList(u8), allocator: std.mem.Allocator, separator: []const u8) !void {
    if (out.items.len == 0) return;
    const last = out.items[out.items.len - 1];
    if (last == ' ' or last == '\n' or last == '\t' or last == ';') return;
    try out.appendSlice(allocator, separator);
}

fn htmlTagNeedsSeparator(tag: []const u8) bool {
    return tagMatches(tag, "br") or
        tagMatches(tag, "/li") or
        tagMatches(tag, "li") or
        tagMatches(tag, "/p") or
        tagMatches(tag, "p") or
        tagMatches(tag, "/div") or
        tagMatches(tag, "div") or
        tagMatches(tag, "/section") or
        tagMatches(tag, "section") or
        tagMatches(tag, "/ul") or
        tagMatches(tag, "ul") or
        tagMatches(tag, "/ol") or
        tagMatches(tag, "ol") or
        tagMatches(tag, "/tr") or
        tagMatches(tag, "tr") or
        tagMatches(tag, "/td") or
        tagMatches(tag, "td") or
        tagMatches(tag, "/th") or
        tagMatches(tag, "th");
}

fn tagEndsListItem(tag: []const u8) bool {
    return tagMatches(tag, "li") or tagMatches(tag, "/li");
}

fn tagMatches(tag: []const u8, expected_name: []const u8) bool {
    if (tag.len < 3 or tag[0] != '<' or tag[tag.len - 1] != '>') return false;
    var i: usize = 1;
    while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
    const start = i;
    while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
    return std.ascii.eqlIgnoreCase(tag[start..i], expected_name);
}

fn normalizeAuditTextAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var wrote_space = false;
    while (i < input.len) {
        if (i + 2 <= input.len and input[i] == 0xC2 and input[i + 1] == 0xA0) {
            if (!wrote_space and out.items.len != 0) {
                try out.append(allocator, ' ');
                wrote_space = true;
            }
            i += 2;
            continue;
        }

        const byte = input[i];
        if (std.ascii.isWhitespace(byte)) {
            if (!wrote_space and out.items.len != 0) {
                try out.append(allocator, ' ');
                wrote_space = true;
            }
            i += 1;
            continue;
        }

        try out.append(allocator, byte);
        wrote_space = false;
        i += 1;
    }

    return allocator.dupe(u8, std.mem.trim(u8, out.items, " "));
}

fn templateNameFromInvocation(invocation: []const u8) []const u8 {
    if (invocation.len < 4 or !std.mem.startsWith(u8, invocation, "{{") or !std.mem.endsWith(u8, invocation, "}}")) return "";
    const body = std.mem.trim(u8, invocation[2 .. invocation.len - 2], " \t\r\n");
    const sep = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    return std.mem.trim(u8, body[0..sep], " \t\r\n");
}

fn appendCanonicalTemplateKey(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        try out.append(allocator, std.ascii.toLower(byte));
    }
}

fn templateNamesEqual(left: []const u8, right: []const u8) bool {
    var left_buf: [256]u8 = undefined;
    var right_buf: [256]u8 = undefined;
    const lhs = canonicalTemplateKeyBuf(left, &left_buf) orelse return false;
    const rhs = canonicalTemplateKeyBuf(right, &right_buf) orelse return false;
    return std.mem.eql(u8, lhs, rhs);
}

fn canonicalTemplateKeyBuf(name: []const u8, buf: []u8) ?[]const u8 {
    var len: usize = 0;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_') continue;
        if (len >= buf.len) return null;
        buf[len] = std.ascii.toLower(byte);
        len += 1;
    }
    return buf[0..len];
}

fn appendFmt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const buffer = try allocator.alloc(u8, len);
    _ = try file.readPositionalAll(io, buffer, 0);
    return buffer;
}

fn readNextLineAlloc(reader: *std.Io.Reader, allocator: std.mem.Allocator, line_buf: *std.ArrayList(u8)) !?[]const u8 {
    line_buf.clearRetainingCapacity();
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, line_buf);
    const n = reader.streamDelimiterEnding(&writer.writer, '\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => unreachable,
    };
    line_buf.* = writer.toArrayList();

    const next = reader.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => {
            if (n == 0 and line_buf.items.len == 0) return null;
            return line_buf.items;
        },
        error.ReadFailed => return error.ReadFailed,
    };
    if (next.len != 0 and next[0] == '\n') reader.toss(1);
    return line_buf.items;
}

fn extractTagText(line: []const u8, tag: []const u8) ?[]const u8 {
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    const start = std.fmt.bufPrint(&start_buf, "<{s}>", .{tag}) catch return null;
    const end = std.fmt.bufPrint(&end_buf, "</{s}>", .{tag}) catch return null;
    const start_idx = std.mem.indexOf(u8, line, start) orelse return null;
    const after_start = start_idx + start.len;
    const end_idx = std.mem.indexOfPos(u8, line, after_start, end) orelse return null;
    return line[after_start..end_idx];
}

test "canonical template key ignores case spaces and underscores" {
    try std.testing.expect(templateNamesEqual("Webster 1913", "webster_1913"));
    try std.testing.expect(templateNamesEqual("q-lite", "Q-lite"));
    try std.testing.expect(!templateNamesEqual("q", "qlite"));
}

test "stripListPrefix removes leading wiki list markers" {
    try std.testing.expectEqualStrings("{{plural of|en|cat}}", stripListPrefix("# {{plural of|en|cat}}"));
    try std.testing.expectEqualStrings("value", stripListPrefix("*: value"));
}

test "stripHtmlToVisibleTextAlloc keeps item boundaries visible" {
    const visible = try stripHtmlToVisibleTextAlloc(std.testing.allocator, "<ul><li><a href=\"/wiki/cat\">cat</a></li><li>dog</li></ul>");
    defer std.testing.allocator.free(visible);
    const normalized = try normalizeAuditTextAlloc(std.testing.allocator, visible);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("cat; dog;", normalized);
}
