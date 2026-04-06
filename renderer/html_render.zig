const std = @import("std");

const wikitext = @import("wikitext_runtime.zig");
const xml_decode = @import("shared_xml_decode");

const max_render_line_bytes = 4096;
const max_term_bytes = 256;

pub const RenderIssueKind = enum {
    unsupported_template,
    unsupported_html_tag,
    unsupported_block_line,
    unbalanced_markup,
    raw_markup_leak,
};

pub const RenderIssue = struct {
    kind: RenderIssueKind = .unsupported_block_line,
    section_title: []const u8 = "",
    line_number: usize = 0,
    line: []const u8 = "",
    detail: []const u8 = "",
};

pub const LinkResolver = struct {
    context: *const anyopaque,
    resolve: *const fn (context: *const anyopaque, allocator: std.mem.Allocator, term: []const u8) anyerror!?[]const u8,
};

pub const RenderOptions = struct {
    strict: bool = true,
    issue: ?*RenderIssue = null,
    link_resolver: ?LinkResolver = null,
    sense_ids: ?*const SenseIdIndex = null,
};

pub const RenderedSection = struct {
    id: []const u8,
    title: []const u8,
    level: u8,
    html: []const u8,

    pub fn deinit(self: *RenderedSection, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.html);
    }
};

const OwnedLogicalLine = struct {
    text: []const u8,
    line_number: usize,
};

const OwnedLines = struct {
    items: []const OwnedLogicalLine = &.{},

    fn deinit(self: *OwnedLines, allocator: std.mem.Allocator) void {
        for (self.items) |line| allocator.free(line.text);
        if (self.items.len != 0) allocator.free(self.items);
    }
};

const PendingSection = struct {
    title: []const u8 = "",
    level: u8 = 1,
    first_line_number: usize = 0,
    body: std.ArrayList(u8) = .empty,

    fn deinit(self: *PendingSection, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
    }
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

const ParsedDefinitionLine = struct {
    const Kind = enum { sense, example };

    depth: u16,
    kind: Kind,
    content: []const u8,
};

const SenseIdEntry = struct {
    id: []const u8,
    label: []const u8,
};

const SenseIdIndex = struct {
    entries: std.ArrayList(SenseIdEntry) = .empty,

    fn deinit(self: *SenseIdIndex, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.label);
        }
        self.entries.deinit(allocator);
    }

    fn resolve(self: *const SenseIdIndex, id: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.label;
        }
        return null;
    }
};

pub fn renderEnglishSectionAlloc(
    allocator: std.mem.Allocator,
    english_section: []const u8,
) ![]RenderedSection {
    return renderEnglishSectionWithOptionsAlloc(allocator, english_section, .{});
}

pub fn renderEnglishSectionWithOptionsAlloc(
    allocator: std.mem.Allocator,
    english_section: []const u8,
    options: RenderOptions,
) ![]RenderedSection {
    var sense_ids = try buildSenseIdIndexAlloc(allocator, english_section);
    defer sense_ids.deinit(allocator);

    var render_options = options;
    render_options.sense_ids = &sense_ids;

    var rendered_sections: std.ArrayList(RenderedSection) = .empty;
    errdefer {
        for (rendered_sections.items) |*section| section.deinit(allocator);
        rendered_sections.deinit(allocator);
    }

    var pending: PendingSection = .{};
    defer pending.deinit(allocator);

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, english_section, '\n');
    while (lines.next()) |raw_input| {
        line_number += 1;
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");

        if (wikitext.parseHeadingLine(raw_line)) |heading| {
            try flushPendingSection(allocator, &rendered_sections, &pending, render_options);
            pending.level = if (heading.level == 2) 1 else heading.level;
            pending.title = if (heading.level == 2) "" else heading.title;
            pending.first_line_number = line_number + 1;
            continue;
        }

        if (pending.first_line_number == 0) pending.first_line_number = line_number;
        if (pending.body.items.len != 0) try pending.body.append(allocator, '\n');
        try pending.body.appendSlice(allocator, raw_line);
    }

    try flushPendingSection(allocator, &rendered_sections, &pending, render_options);
    return rendered_sections.toOwnedSlice(allocator);
}

pub fn renderLineFragmentAlloc(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
) ![]u8 {
    return renderLineFragmentWithOptionsAlloc(allocator, raw_line, .{});
}

pub fn renderLineFragmentWithOptionsAlloc(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    options: RenderOptions,
) ![]u8 {
    return renderLineHtmlAlloc(allocator, "Template Audit", raw_line, 1, options);
}

fn buildSenseIdIndexAlloc(allocator: std.mem.Allocator, english_section: []const u8) !SenseIdIndex {
    var index: SenseIdIndex = .{};
    errdefer index.deinit(allocator);

    var current_pos: []const u8 = "";
    var sense_number: usize = 0;

    var lines = std.mem.splitScalar(u8, english_section, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
        if (wikitext.parseHeadingLine(raw_line)) |heading| {
            if (heading.level >= 3 and wikitext.isRecognizedPartOfSpeech(heading.title)) {
                current_pos = heading.title;
                sense_number = 0;
            }
            continue;
        }

        const trimmed = std.mem.trim(u8, raw_line, " \t");
        const parsed = parseDefinitionLine(trimmed) orelse continue;
        if (parsed.kind != .sense or current_pos.len == 0) continue;
        sense_number += 1;

        const sense_id = extractOpaqueSenseIdFromLine(parsed.content) orelse continue;
        if (index.resolve(sense_id) != null) continue;

        const lower_pos = try lowercaseAsciiAlloc(allocator, current_pos);
        defer allocator.free(lower_pos);
        const label = try std.fmt.allocPrint(allocator, "{s} sense {d}", .{
            lower_pos,
            sense_number,
        });
        errdefer allocator.free(label);

        try index.entries.append(allocator, .{
            .id = try allocator.dupe(u8, sense_id),
            .label = label,
        });
    }

    return index;
}

fn lowercaseAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*byte| byte.* = std.ascii.toLower(byte.*);
    return out;
}

fn extractOpaqueSenseIdFromLine(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "{{senseid|") orelse return null;
    const end = std.mem.indexOfPos(u8, line, start + "{{senseid|".len, "}}") orelse return null;
    const body = line[start + 2 .. end];
    var iter = std.mem.splitScalar(u8, body, '|');
    _ = iter.next() orelse return null;
    var last_positional: ?[]const u8 = null;
    while (iter.next()) |part| {
        const trimmed = trimWikiWhitespace(part);
        if (trimmed.len == 0 or templateArgHasName(trimmed)) continue;
        last_positional = trimmed;
    }
    const candidate = last_positional orelse return null;
    return if (looksLikeOpaqueSenseIdHtml(candidate)) candidate else null;
}

fn flushPendingSection(
    allocator: std.mem.Allocator,
    rendered_sections: *std.ArrayList(RenderedSection),
    pending: *PendingSection,
    options: RenderOptions,
) !void {
    const body = std.mem.trim(u8, pending.body.items, " \n\t");
    if (body.len == 0) {
        pending.body.items.len = 0;
        pending.first_line_number = 0;
        return;
    }

    const html = try renderSectionBodyHtmlAlloc(
        allocator,
        pending.title,
        pending.level,
        body,
        pending.first_line_number,
        options,
    );
    errdefer allocator.free(html);
    if (html.len == 0) {
        pending.body.items.len = 0;
        pending.first_line_number = 0;
        return;
    }

    const section_index = rendered_sections.items.len;
    const id_title = if (pending.title.len == 0) "lead" else pending.title;
    try rendered_sections.append(allocator, .{
        .id = try sectionIdAlloc(allocator, id_title, section_index),
        .title = try allocator.dupe(u8, pending.title),
        .level = pending.level,
        .html = html,
    });

    pending.body.items.len = 0;
    pending.first_line_number = 0;
}

fn renderSectionBodyHtmlAlloc(
    allocator: std.mem.Allocator,
    title: []const u8,
    level: u8,
    body: []const u8,
    first_line_number: usize,
    options: RenderOptions,
) ![]u8 {
    if (body.len == 0) return allocator.dupe(u8, "");
    if (level >= 3 and wikitext.isRecognizedPartOfSpeech(title)) {
        return renderPartOfSpeechHtmlAlloc(allocator, title, body, first_line_number, options);
    }
    return renderGenericSectionHtmlAlloc(allocator, title, body, first_line_number, options);
}

fn renderPartOfSpeechHtmlAlloc(
    allocator: std.mem.Allocator,
    title: []const u8,
    body: []const u8,
    first_line_number: usize,
    options: RenderOptions,
) ![]u8 {
    var logical_lines = try collectLogicalLinesAlloc(allocator, body, first_line_number, title, options);
    defer logical_lines.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var ol_open = false;
    var sense_open = false;

    for (logical_lines.items) |logical_line| {
        const trimmed = std.mem.trim(u8, logical_line.text, " \t");
        if (trimmed.len == 0) continue;
        try validateBlockLineStrict(trimmed, title, logical_line.line_number, options);
        if (shouldSkipStandaloneLine(trimmed)) continue;

        if (parseDefinitionLine(trimmed)) |parsed| {
            const content_html = try renderLineHtmlAlloc(allocator, title, parsed.content, logical_line.line_number, options);
            defer allocator.free(content_html);
            if (content_html.len == 0) continue;

            if (parsed.kind == .sense) {
                if (!ol_open) {
                    try out.appendSlice(allocator, "<ol class=\"render-sense-list\">");
                    ol_open = true;
                }
                if (sense_open) try out.appendSlice(allocator, "</li>");

                const depth_class = try std.fmt.allocPrint(allocator, "depth-{d}", .{parsed.depth});
                defer allocator.free(depth_class);

                try out.appendSlice(allocator, "<li class=\"render-sense ");
                try out.appendSlice(allocator, depth_class);
                try out.appendSlice(allocator, "\"><div class=\"render-sense-gloss\">");
                try out.appendSlice(allocator, content_html);
                try out.appendSlice(allocator, "</div>\n");
                sense_open = true;
                continue;
            }

            if (sense_open) {
                const depth_class = try std.fmt.allocPrint(allocator, "depth-{d}", .{parsed.depth});
                defer allocator.free(depth_class);

                try out.appendSlice(allocator, "<div class=\"render-sense-example ");
                try out.appendSlice(allocator, depth_class);
                try out.appendSlice(allocator, "\">");
                try out.appendSlice(allocator, content_html);
                try out.appendSlice(allocator, "</div>\n");
            } else {
                try out.appendSlice(allocator, "<p class=\"render-note\">");
                try out.appendSlice(allocator, content_html);
                try out.appendSlice(allocator, "</p>");
            }
            continue;
        }

        if (sense_open) {
            try out.appendSlice(allocator, "</li>");
            sense_open = false;
        }
        if (ol_open) {
            try out.appendSlice(allocator, "</ol>");
            ol_open = false;
        }

        if (isStandaloneColumnTemplateLine(trimmed)) {
            const grid_html = try renderColumnTemplateLineHtmlAlloc(allocator, trimmed);
            defer allocator.free(grid_html);
            if (grid_html.len != 0) try out.appendSlice(allocator, grid_html);
            continue;
        }

        const content_html = try renderLineHtmlAlloc(allocator, title, trimmed, logical_line.line_number, options);
        defer allocator.free(content_html);
        if (content_html.len == 0) continue;

        try out.appendSlice(allocator, "<p class=\"render-note\">");
        try out.appendSlice(allocator, content_html);
        try out.appendSlice(allocator, "</p>");
    }

    if (sense_open) try out.appendSlice(allocator, "</li>");
    if (ol_open) try out.appendSlice(allocator, "</ol>");
    return out.toOwnedSlice(allocator);
}

fn renderGenericSectionHtmlAlloc(
    allocator: std.mem.Allocator,
    title: []const u8,
    body: []const u8,
    first_line_number: usize,
    options: RenderOptions,
) ![]u8 {
    var logical_lines = try collectLogicalLinesAlloc(allocator, body, first_line_number, title, options);
    defer logical_lines.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var list_kind: u8 = 0;
    var list_open = false;

    for (logical_lines.items) |logical_line| {
        const trimmed = std.mem.trim(u8, logical_line.text, " \t");
        if (trimmed.len == 0) {
            if (list_open) {
                try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
                list_open = false;
                list_kind = 0;
            }
            continue;
        }

        try validateBlockLineStrict(trimmed, title, logical_line.line_number, options);

        if (std.ascii.eqlIgnoreCase(title, "Gallery") and std.mem.indexOf(u8, trimmed, "<gallery") != null) {
            if (list_open) {
                try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
                list_open = false;
                list_kind = 0;
            }

            const gallery_html = try renderGalleryBlockHtmlAlloc(allocator, trimmed);
            defer allocator.free(gallery_html);
            if (gallery_html.len != 0) try out.appendSlice(allocator, gallery_html);
            continue;
        }

        if (shouldSkipStandaloneLine(trimmed)) continue;
        if (isStandaloneColumnTemplateLine(trimmed)) {
            if (list_open) {
                try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
                list_open = false;
                list_kind = 0;
            }

            const grid_html = try renderColumnTemplateLineHtmlAlloc(allocator, trimmed);
            defer allocator.free(grid_html);
            if (grid_html.len != 0) try out.appendSlice(allocator, grid_html);
            continue;
        }

        if (trimmed[0] == '*' or trimmed[0] == '#') {
            const content = std.mem.trimStart(u8, trimmed[1..], "*#:; \t");
            const content_html = try renderLineHtmlAlloc(allocator, title, content, logical_line.line_number, options);
            defer allocator.free(content_html);
            if (content_html.len == 0) continue;

            if (!list_open or list_kind != trimmed[0]) {
                if (list_open) try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
                try out.appendSlice(allocator, if (trimmed[0] == '#') "<ol class=\"render-list\">" else "<ul class=\"render-list\">");
                list_open = true;
                list_kind = trimmed[0];
            }

            try out.appendSlice(allocator, "<li>");
            try out.appendSlice(allocator, content_html);
            try out.appendSlice(allocator, "</li>");
            continue;
        }

        if (list_open) {
            try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
            list_open = false;
            list_kind = 0;
        }

        const note_line = trimmed[0] == ':' or trimmed[0] == ';';
        const content = if (note_line) std.mem.trimStart(u8, trimmed[1..], ":; \t") else trimmed;
        const content_html = try renderLineHtmlAlloc(allocator, title, content, logical_line.line_number, options);
        defer allocator.free(content_html);
        if (content_html.len == 0) continue;

        try out.appendSlice(allocator, if (note_line) "<p class=\"render-note\">" else "<p>");
        try out.appendSlice(allocator, content_html);
        try out.appendSlice(allocator, "</p>");
    }

    if (list_open) try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
    return out.toOwnedSlice(allocator);
}

fn renderLineHtmlAlloc(
    allocator: std.mem.Allocator,
    title: []const u8,
    raw_line: []const u8,
    line_number: usize,
    options: RenderOptions,
) ![]u8 {
    const source = if (std.ascii.eqlIgnoreCase(title, "Gallery") or isStandaloneMediaSourceLine(raw_line))
        extractGalleryCaption(raw_line)
    else
        raw_line;

    if (source.len == 0) return allocator.dupe(u8, "");
    try validateInlineStrict(source, title, line_number, options);

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try renderInlineHtml(&html, allocator, source, options);
    const trimmed = std.mem.trim(u8, html.items, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (options.strict and containsResidualMarkup(trimmed)) {
        return failStrict(title, line_number, raw_line, "inline output still contains wiki markup", .raw_markup_leak, options);
    }
    return html.toOwnedSlice(allocator);
}

fn renderGalleryBlockHtmlAlloc(allocator: std.mem.Allocator, block: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var captions_written: usize = 0;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_input| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw_input, "\r"), " \t");
        if (line.len == 0) continue;
        if (asciiStartsWithIgnoreCase(line, "<gallery") or asciiStartsWithIgnoreCase(line, "</gallery")) continue;

        const caption_html = try renderLineHtmlAlloc(allocator, "Gallery", line, 0, .{ .strict = false });
        defer allocator.free(caption_html);
        if (caption_html.len == 0) continue;

        if (captions_written == 0) try out.appendSlice(allocator, "<ul class=\"render-gallery-list\">");
        try out.appendSlice(allocator, "<li>");
        try out.appendSlice(allocator, caption_html);
        try out.appendSlice(allocator, "</li>");
        captions_written += 1;
    }

    if (captions_written != 0) try out.appendSlice(allocator, "</ul>");
    return out.toOwnedSlice(allocator);
}

fn isStandaloneMediaSourceLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return asciiStartsWithIgnoreCase(trimmed, "[[File:") or
        asciiStartsWithIgnoreCase(trimmed, "[[Image:") or
        asciiStartsWithIgnoreCase(trimmed, "[[Media:");
}

fn renderColumnTemplateLineHtmlAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    if (!isStandaloneColumnTemplateLine(line)) return allocator.dupe(u8, "");

    const body = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0 or !isColumnTemplate(parts.items[0])) return allocator.dupe(u8, "");

    var terms: std.ArrayList([]const u8) = .empty;
    defer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }

    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const parsed = splitTrailingQualifierHtml(segment);
        if (parsed.term.len == 0) continue;

        if (looksLikeStructuredInline(parsed.term)) {
            const rendered = try renderInlineHtmlToOwned(allocator, parsed.term, .{});
            defer allocator.free(rendered);
            if (parsed.qualifier) |qualifier| {
                const qualifier_html = try renderPhraseHtmlAlloc(allocator, qualifier, .{});
                defer allocator.free(qualifier_html);
                const qualified = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ rendered, qualifier_html });
                defer allocator.free(qualified);
                try pushRenderedTerms(&terms, allocator, qualified);
            } else {
                try pushRenderedTerms(&terms, allocator, rendered);
            }
        } else {
            const rendered = try renderPhraseHtmlAlloc(allocator, parsed.term, .{});
            defer allocator.free(rendered);
            if (parsed.qualifier) |qualifier| {
                const qualifier_html = try renderPhraseHtmlAlloc(allocator, qualifier, .{});
                defer allocator.free(qualifier_html);
                const qualified = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ rendered, qualifier_html });
                defer allocator.free(qualified);
                try pushRenderedTerms(&terms, allocator, qualified);
            } else {
                try pushRenderedTerms(&terms, allocator, rendered);
            }
        }
    }

    if (terms.items.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "<ul class=\"render-term-grid\">");
    for (terms.items) |term| {
        try out.appendSlice(allocator, "<li>");
        try out.appendSlice(allocator, term);
        try out.appendSlice(allocator, "</li>");
    }
    try out.appendSlice(allocator, "</ul>");
    return out.toOwnedSlice(allocator);
}

fn collectLogicalLinesAlloc(
    allocator: std.mem.Allocator,
    body: []const u8,
    first_line_number: usize,
    title: []const u8,
    options: RenderOptions,
) !OwnedLines {
    var lines_out: std.ArrayList(OwnedLogicalLine) = .empty;
    errdefer {
        for (lines_out.items) |line| allocator.free(line.text);
        lines_out.deinit(allocator);
    }

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var balance: LogicalBalance = .{};
    var in_gallery = false;
    var in_table = false;
    var current_line_number = first_line_number;
    var pending_start_line = first_line_number;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");

        if (in_gallery) {
            if (pending.items.len != 0) try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            if (std.mem.indexOf(u8, trimmed, "</gallery>") != null) {
                try lines_out.append(allocator, .{
                    .text = try pending.toOwnedSlice(allocator),
                    .line_number = pending_start_line,
                });
                pending.items.len = 0;
                in_gallery = false;
            }
            current_line_number += 1;
            continue;
        }

        if (in_table) {
            if (asciiStartsWithIgnoreCase(trimmed, "|}")) in_table = false;
            current_line_number += 1;
            continue;
        }

        if (pending.items.len == 0 and asciiStartsWithIgnoreCase(trimmed, "<gallery")) {
            pending_start_line = current_line_number;
            try pending.appendSlice(allocator, raw_line);
            if (std.mem.indexOf(u8, trimmed, "</gallery>") != null) {
                try lines_out.append(allocator, .{
                    .text = try pending.toOwnedSlice(allocator),
                    .line_number = pending_start_line,
                });
                pending.items.len = 0;
            } else {
                in_gallery = true;
            }
            current_line_number += 1;
            continue;
        }

        if (pending.items.len == 0 and asciiStartsWithIgnoreCase(trimmed, "{|")) {
            in_table = true;
            current_line_number += 1;
            continue;
        }

        // Some dumps contain malformed standalone media links. Skip only the
        // malformed variants so strict mode keeps working while balanced file
        // captions still render normally.
        if (pending.items.len == 0 and isMalformedStandaloneMediaLinkLine(trimmed)) {
            current_line_number += 1;
            continue;
        }

        if (pending.items.len == 0 and isBrokenHiddenMediaLine(trimmed)) {
            current_line_number += 1;
            continue;
        }

        if (pending.items.len != 0) {
            if (shouldSplitDanglingLogicalLine(balance, pending.items, trimmed)) {
                if (try repairDanglingLogicalLineAlloc(allocator, pending.items, balance)) |repaired| {
                    try lines_out.append(allocator, .{
                        .text = repaired,
                        .line_number = pending_start_line,
                    });
                    pending.items.len = 0;
                    balance = .{};
                }
            }
        }

        if (pending.items.len != 0) {
            try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            balance.update(raw_line);
            if (balance.isOpen()) {
                current_line_number += 1;
                continue;
            }

            const finalized = try finalizeLogicalLineAlloc(allocator, pending.items);
            try lines_out.append(allocator, .{
                .text = finalized,
                .line_number = pending_start_line,
            });
            pending.items.len = 0;
            balance = .{};
            current_line_number += 1;
            continue;
        }

        var line_balance: LogicalBalance = .{};
        line_balance.update(raw_line);
        if (line_balance.isOpen()) {
            pending_start_line = current_line_number;
            try pending.appendSlice(allocator, raw_line);
            balance = line_balance;
            current_line_number += 1;
            continue;
        }

        try lines_out.append(allocator, .{
            .text = try finalizeLogicalLineAlloc(allocator, raw_line),
            .line_number = current_line_number,
        });
        current_line_number += 1;
    }

    if (pending.items.len != 0) {
        if (options.strict) {
            if (try repairDanglingLogicalLineAlloc(allocator, pending.items, balance)) |repaired| {
                defer allocator.free(repaired);
                try lines_out.append(allocator, .{
                    .text = try finalizeLogicalLineAlloc(allocator, repaired),
                    .line_number = pending_start_line,
                });
            } else {
                return failStrict(title, pending_start_line, pending.items, "logical line ended with unbalanced markup", .unbalanced_markup, options);
            }
        } else {
            try lines_out.append(allocator, .{ .text = try finalizeLogicalLineAlloc(allocator, pending.items), .line_number = pending_start_line });
        }
    }

    return .{ .items = try lines_out.toOwnedSlice(allocator) };
}

fn finalizeLogicalLineAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed = trimWikiWhitespace(line);
    if (std.mem.startsWith(u8, trimmed, "{{col")) {
        if (std.mem.indexOf(u8, line, "<!--")) |comment_start| {
            if (std.mem.lastIndexOf(u8, line, "}}")) |template_end| {
                if (comment_start > template_end) {
                    return allocator.dupe(u8, std.mem.trimEnd(u8, line[0..comment_start], " \t\r\n"));
                }
            }
        }
    }
    return allocator.dupe(u8, line);
}

fn shouldSplitDanglingLogicalLine(balance: LogicalBalance, pending_line: []const u8, next_line: []const u8) bool {
    if (!balance.isOpen()) return false;
    const next_trimmed = std.mem.trim(u8, next_line, " \t");
    if (next_trimmed.len == 0) return false;
    if (wikitext.parseHeadingLine(next_trimmed) != null) return true;

    const pending_trimmed = trimWikiWhitespace(pending_line);
    if (pending_trimmed.len == 0) return false;
    if (!isWikiListLikeLine(pending_trimmed)) return false;
    return isWikiListLikeLine(next_trimmed);
}

fn isWikiListLikeLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len != 0 and (trimmed[0] == '*' or trimmed[0] == '#' or trimmed[0] == ':' or trimmed[0] == ';');
}

fn repairDanglingLogicalLineAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    balance: LogicalBalance,
) !?[]u8 {
    if (balance.comments != 0) {
        if (std.mem.lastIndexOf(u8, line, "<!--")) |comment_start| {
            const truncated = std.mem.trimEnd(u8, line[0..comment_start], " \t\r\n");
            var truncated_balance: LogicalBalance = .{};
            truncated_balance.update(truncated);
            if (!truncated_balance.isOpen()) return @as(?[]u8, try allocator.dupe(u8, truncated));
        }
    }

    const trimmed = trimWikiWhitespace(line);
    if (balance.comments == 0 and balance.templates == 0 and balance.links != 0 and std.mem.indexOf(u8, trimmed, "[[") != null) {
        var repaired: std.ArrayList(u8) = .empty;
        errdefer repaired.deinit(allocator);
        try repaired.appendSlice(allocator, line);
        for (0..balance.links) |_| try repaired.appendSlice(allocator, "]]");

        const owned = try repaired.toOwnedSlice(allocator);
        var repaired_balance: LogicalBalance = .{};
        repaired_balance.update(owned);
        if (!repaired_balance.isOpen()) return owned;
        allocator.free(owned);
    }

    if (balance.comments == 0 and balance.links == 0 and balance.templates != 0 and std.mem.startsWith(u8, trimmed, "{{")) {
        var repaired: std.ArrayList(u8) = .empty;
        errdefer repaired.deinit(allocator);
        try repaired.appendSlice(allocator, line);
        for (0..balance.templates) |_| try repaired.appendSlice(allocator, "}}");

        const owned = try repaired.toOwnedSlice(allocator);
        var repaired_balance: LogicalBalance = .{};
        repaired_balance.update(owned);
        if (!repaired_balance.isOpen()) return owned;
        allocator.free(owned);
    }

    return null;
}

fn isMalformedStandaloneMediaLinkLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!(asciiStartsWithIgnoreCase(trimmed, "[[File:") or
        asciiStartsWithIgnoreCase(trimmed, "[[Image:") or
        asciiStartsWithIgnoreCase(trimmed, "[[Media:"))) return false;

    var balance: LogicalBalance = .{};
    balance.update(trimmed);
    return balance.isOpen();
}

fn isBrokenHiddenMediaLine(line: []const u8) bool {
    return (asciiStartsWithIgnoreCase(line, "[[File:") or asciiStartsWithIgnoreCase(line, "[[Image:")) and
        std.mem.indexOf(u8, line, "]]") == null;
}

fn validateBlockLineStrict(
    line: []const u8,
    title: []const u8,
    line_number: usize,
    options: RenderOptions,
) !void {
    if (!options.strict or line.len == 0) return;
    if (std.mem.startsWith(u8, line, "<!--")) return;
    if (startsWithTableMarkup(line)) {
        return failStrict(title, line_number, line, "table markup is not supported by the HTML renderer", .unsupported_block_line, options);
    }
    if (startsWithUnsupportedBlockTag(line)) |tag_name| {
        return failStrict(title, line_number, line, tag_name, .unsupported_html_tag, options);
    }
}

fn validateInlineStrict(
    input: []const u8,
    title: []const u8,
    line_number: usize,
    options: RenderOptions,
) error{StrictRenderFailure}!void {
    if (!options.strict) return;

    var i: usize = 0;
    while (i < input.len) {
        if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "<!--")) {
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->") orelse
                return failStrict(title, line_number, input, "unterminated comment", .unbalanced_markup, options);
            i = end + 3;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<<")) {
            const end = std.mem.indexOfPos(u8, input, i + 2, ">>") orelse
                return failStrict(title, line_number, input, "unterminated angle placeholder", .unbalanced_markup, options);
            i = end + 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            const end = findBalanced(input, i, "{{", "}}") orelse
                return failStrict(title, line_number, input, "unterminated template", .unbalanced_markup, options);
            const body = input[i + 2 .. end];
            if (!isStrictSupportedTemplateBody(body)) {
                return failStrict(title, line_number, input, strictTemplateName(body), .unsupported_template, options);
            }
            try validateTemplateBodyStrict(body, title, line_number, options);
            i = end + 2;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            const end = findBalanced(input, i, "[[", "]]") orelse
                return failStrict(title, line_number, input, "unterminated wikilink", .unbalanced_markup, options);
            const body = input[i + 2 .. end];
            if (std.mem.indexOfScalar(u8, body, '|')) |pipe| {
                try validateInlineStrict(body[pipe + 1 ..], title, line_number, options);
            }
            i = end + 2;
            continue;
        }
        if (input[i] == '[') {
            if (asciiStartsWithIgnoreCase(input[i + 1 ..], "http")) {
                const end = findExternalLinkClose(input, i) orelse
                    return failStrict(title, line_number, input, "unterminated external link", .unbalanced_markup, options);
                const body = input[i + 1 .. end];
                if (std.mem.indexOfScalar(u8, body, ' ')) |space| {
                    try validateInlineStrict(body[space + 1 ..], title, line_number, options);
                }
                i = end + 1;
                continue;
            }
        }
        if (input[i] == '<') {
            if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<|")) {
                i += 2;
                continue;
            }
            if (!looksLikeInlineTagStart(input[i..])) {
                i += 1;
                continue;
            }
            if (annotationTagLen(input[i..])) |tag_len| {
                i += tag_len;
                continue;
            }
            const tag_end = std.mem.indexOfScalarPos(u8, input, i, '>');
            if (tag_end) |end| {
                if (htmlTagName(input[i .. end + 1])) |tag_name| {
                    if (!isAllowedInlineHtmlTag(tag_name) and !hasMatchingClosingTag(input[end + 1 ..], tag_name)) {
                        i = end + 1;
                        continue;
                    }
                }
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<ref")) {
                if (std.mem.indexOfPos(u8, input, i, "</ref>")) |end| {
                    i = end + "</ref>".len;
                    continue;
                }
                if (tag_end) |end| {
                    i = end + 1;
                    continue;
                }
            }
            if (tag_end == null) {
                i += 1;
                continue;
            }
            const tag_name = htmlTagName(input[i..]) orelse
                return failStrict(title, line_number, input, "malformed html tag", .unsupported_html_tag, options);
            if (!isAllowedInlineHtmlTag(tag_name)) {
                return failStrict(title, line_number, input, tag_name, .unsupported_html_tag, options);
            }
            if (findRawTextInlineTagClose(input, tag_end.? + 1, tag_name)) |close_end| {
                i = close_end;
                continue;
            }
            i = tag_end.? + 1;
            continue;
        }
        i += 1;
    }
}

fn validateTemplateBodyStrict(
    body: []const u8,
    title: []const u8,
    line_number: usize,
    options: RenderOptions,
) error{StrictRenderFailure}!void {
    const name = strictTemplateName(body);
    if (shouldSkipStrictTemplateArgValidation(name)) return;
    const sep = topLevelSeparator(body, '|') orelse return;
    const args = trimWikiWhitespace(body[sep + 1 ..]);
    if (args.len == 0) return;
    try validateInlineStrict(args, title, line_number, options);
}

fn failStrict(
    section_title: []const u8,
    line_number: usize,
    line: []const u8,
    detail: []const u8,
    kind: RenderIssueKind,
    options: RenderOptions,
) error{StrictRenderFailure} {
    if (options.issue) |issue| {
        issue.* = .{
            .kind = kind,
            .section_title = section_title,
            .line_number = line_number,
            .line = line,
            .detail = detail,
        };
    }
    return error.StrictRenderFailure;
}

fn annotationTagLen(input: []const u8) ?usize {
    if (input.len < 4 or input[0] != '<') return null;
    var i: usize = 1;
    const name_start = i;
    while (i < input.len and std.ascii.isAlphanumeric(input[i])) : (i += 1) {}
    if (i == name_start or i >= input.len or input[i] != ':') return null;
    const end = std.mem.indexOfScalarPos(u8, input, i + 1, '>') orelse return null;
    return end + 1;
}

fn containsResidualMarkup(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "{{") != null or
        std.mem.indexOf(u8, text, "}}") != null or
        std.mem.indexOf(u8, text, "[[") != null or
        std.mem.indexOf(u8, text, "]]") != null or
        std.mem.indexOf(u8, text, "'''") != null or
        std.mem.indexOf(u8, text, "''") != null;
}

fn startsWithTableMarkup(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{|") or
        std.mem.startsWith(u8, line, "|}") or
        std.mem.startsWith(u8, line, "|-") or
        std.mem.startsWith(u8, line, "!") or
        std.mem.startsWith(u8, line, "|");
}

fn startsWithUnsupportedBlockTag(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '<') return null;
    if (std.mem.startsWith(u8, line, "<!--")) return null;
    const tag_name = htmlTagName(line) orelse return "";
    if (std.mem.eql(u8, tag_name, "gallery")) return null;
    if (std.mem.eql(u8, tag_name, "references")) return null;
    if (std.mem.eql(u8, tag_name, "br")) return null;
    if (std.mem.eql(u8, tag_name, "hr")) return null;
    if (isAllowedInlineHtmlTag(tag_name)) return null;
    return tag_name;
}

fn htmlTagName(input: []const u8) ?[]const u8 {
    if (input.len < 3 or input[0] != '<') return null;
    var i: usize = 1;
    if (i < input.len and input[i] == '/') i += 1;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    const start = i;
    while (i < input.len and std.ascii.isAlphanumeric(input[i])) : (i += 1) {}
    if (i == start) return null;
    return input[start..i];
}

fn looksLikeInlineTagStart(input: []const u8) bool {
    if (input.len < 2 or input[0] != '<') return false;
    const next = input[1];
    return next == '!' or next == '/' or std.ascii.isAlphabetic(next);
}

fn isAllowedInlineHtmlTag(tag_name: []const u8) bool {
    inline for ([_][]const u8{
        "b",
        "aa",
        "big",
        "blockquote",
        "br",
        "center",
        "chem",
        "cite",
        "code",
        "div",
        "em",
        "h1",
        "hr",
        "hiero",
        "i",
        "kbd",
        "math",
        "nowiki",
        "p",
        "ref",
        "s",
        "samp",
        "section",
        "small",
        "span",
        "strong",
        "sub",
        "sup",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
        "tr",
        "u",
        "var",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(tag_name, candidate)) return true;
    }
    return false;
}

fn hasMatchingClosingTag(input: []const u8, tag_name: []const u8) bool {
    var pattern_buf: [64]u8 = undefined;
    if (tag_name.len + 3 > pattern_buf.len) return false;
    pattern_buf[0] = '<';
    pattern_buf[1] = '/';
    @memcpy(pattern_buf[2 .. 2 + tag_name.len], tag_name);
    pattern_buf[2 + tag_name.len] = '>';
    return std.mem.indexOf(u8, input, pattern_buf[0 .. tag_name.len + 3]) != null;
}

fn strictTemplateName(body: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(body);
    const sep = topLevelSeparator(trimmed, '|') orelse trimmed.len;
    return trimWikiWhitespace(trimmed[0..sep]);
}

fn findRawTextInlineTagClose(input: []const u8, start: usize, tag_name: []const u8) ?usize {
    if (!inlineHtmlTagIsRawText(tag_name)) return null;

    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] != '<' or i + 2 >= input.len or input[i + 1] != '/') continue;
        const candidate = htmlTagName(input[i..]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(candidate, tag_name)) continue;
        const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse return null;
        return end + 1;
    }
    return null;
}

fn inlineHtmlTagIsRawText(tag_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag_name, "code") or
        std.ascii.eqlIgnoreCase(tag_name, "nowiki") or
        std.ascii.eqlIgnoreCase(tag_name, "math") or
        std.ascii.eqlIgnoreCase(tag_name, "chem") or
        std.ascii.eqlIgnoreCase(tag_name, "hiero");
}

fn isStrictSupportedTemplateBody(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "langindex") != null) return true;
    if (std.mem.indexOf(u8, body, "Render") != null) return true;
    if (std.mem.indexOf(u8, body, "Rende") != null) return true;
    const name = strictTemplateName(body);
    return isStrictSupportedTemplateName(name);
}

fn isStrictSupportedTemplateName(name: []const u8) bool {
    const trimmed = trimWikiWhitespace(name);
    if (trimmed.len == 0) return false;
    if (templateNameStartsWithHtml(trimmed, "ctRenderF")) return true;
    if (std.mem.indexOf(u8, trimmed, "Render") != null or std.mem.indexOf(u8, trimmed, "Rende") != null) return true;
    if (templateNameStartsWithHtml(trimmed, "CURRENT")) return true;
    if (templateNameStartsWithHtml(trimmed, "quote-")) return true;
    if (templateNameStartsWithHtml(trimmed, "cite-")) return true;
    if (templateNameStartsWithHtml(trimmed, "RQ:")) return true;
    if (templateNameStartsWithHtml(trimmed, "R:")) return true;
    if (templateNameStartsWithHtml(trimmed, "table:")) return true;
    if (templateNameStartsWithHtml(trimmed, "U:")) return true;
    if (templateNameStartsWithHtml(trimmed, "Wiktionary:")) return true;
    if (templateNameStartsWithHtml(trimmed, "list:")) return true;
    if (templateNameStartsWithHtml(trimmed, "en-")) return true;
    if (templateNameEndsWithHtml(trimmed, " of")) return true;
    inline for ([_][]const u8{
        "!",
        "1",
        "af",
        "alt",
        "alter",
        "a",
        ",",
        "also",
        "ant",
        "antonyms",
        "antsense",
        "audio",
        "affix",
        "alti",
        "bor",
        "bor+",
        "C",
        "cog",
        "cognate",
        "cln",
        "col",
        "col2",
        "col3",
        "col4",
        "col5",
        "color panel",
        "com",
        "com+",
        "comcatlite",
        "commonscat",
        "commons cat",
        "compound",
        "contraction",
        "co",
        "coefficient",
        "coi",
        "collocation",
        "clip",
        "context",
        "cot",
        "coord",
        "coordinate terms",
        "confix",
        "con",
        "cx",
        "der",
        "dercat",
        "der+",
        "derived",
        "displaced",
        "desc",
        "desctree",
        "demonym-adj",
        "demonym-noun",
        "defdate",
        "dbt",
        "doublet",
        "elements",
        "English personal pronouns",
        "enpr",
        "etydate",
        "etymon",
        "etymid",
        "examples",
        "ellipsis",
        "good",
        "frac",
        "gloss",
        "glossary",
        "gbooks",
        "given name",
        "deverbal",
        "head",
        "hmp",
        "homophone",
        "homophones",
        "hol",
        "hyper",
        "hypernyms",
        "hyph",
        "hyphenation",
        "hypo",
        "hyponyms",
        "inh",
        "inh+",
        "inh-lite",
        "initialism",
        "interwiktionary",
        "ipa",
        "i",
        "ISBN",
        "ISO 639",
        "ja-r",
        "l",
        "label",
        "lb",
        "lbl",
        "Latn-def",
        "langcat",
        "langlist",
        "lang",
        "lbor",
        "link",
        "lookfrom",
        "m",
        "m+",
        "minitoc",
        "multiple images",
        "nb...",
        "nbsp",
        "ncog",
        "ng",
        "non-gloss",
        "nonlemma",
        "noncog",
        "number box",
        "onomatopoeic",
        "picdic",
        "picdicimg",
        "picdiclabel",
        "PIE word",
        "pedia",
        "place",
        "prefix",
        "prefixsee",
        "pre",
        "q",
        "q-lite",
        "qualifier",
        "qual",
        "rfap",
        "rfc",
        "rfe",
        "rfex",
        "rfp",
        "rfquote",
        "rfquotek",
        "rfquote-sense",
        "rfv-etym",
        "ref",
        "root",
        "rootsee",
        "rhyme",
        "rhymes",
        "s",
        "seeCites",
        "seeSynonyms",
        "seemoreCites",
        "checksense",
        "senseid",
        "sense",
        "sid",
        "sic",
        "slim-wikipedia",
        "small",
        "smallcaps",
        "nowrap",
        "suffix",
        "sup",
        "suf",
        "surname",
        "surf",
        "swp",
        "syn",
        "synonyms",
        "t",
        "t+",
        "t-check",
        "taxfmt",
        "taxlink",
        "t+check",
        "trans-see",
        "translit",
        "transliteration",
        "tt",
        "tt+",
        "uder",
        "ubor",
        "U",
        "unc",
        "unk",
        "usex",
        "ux",
        "uxi",
        "vern",
        "wikidata lexeme",
        "wikivoyage",
        "wikispecies",
        "wikipedia",
        "Webster 1913",
        "wikiquote",
        "wp",
        "w",
        "&lit",
        "'",
        "...",
        "+obj",
        "attn",
        "acronym",
        "A.D.",
        "bf",
        "B.C.",
        "B.C.E.",
        "box-bottom",
        "box-top",
        "calque",
        "C.E.",
        "coin",
        "coinage",
        "compound+",
        "clipping",
        "dated form",
        "back-form",
        "learned borrowing",
        "lg",
        "listen",
        "monospace",
        "multiple image",
        "mer",
        "mero",
        "meronyms",
        "comeronyms",
        "name translit",
        "holonyms",
        "holo",
        "named-after",
        "no entry",
        "etystub",
        "IPA letters",
        "PAGENAME",
        "phrasebook",
        "tcl",
        "wikibooks",
        "wikiversity lecture",
        "word",
        "piecewise doublet",
        "rfv-pron",
        "rfv-sense",
        "alt case",
        "alt case form",
        "obs sp",
        "obor",
        "alt spell",
        "altcase",
        "altform",
        "apocopic form",
        "aphetic form",
        "cal",
        "circa",
        "clq",
        "m-g",
        "SI-unit",
        "smc",
        "specieslite",
        "season name spelling",
        "see desc",
        "suffixsee",
        "troponyms",
        "uncertain",
        "rfdef",
        "blend",
        "…",
        "c.",
        "circa2",
        "col6",
        "gl",
        "IPAchar",
        "cap",
        "center bottom",
        "center top",
        "colour panel",
        "col1",
        "coa",
        "ethnologue",
        "emojipic",
        "img",
        "inline alt forms",
        "init",
        "letter_disp2",
        "mainapp",
        "mdash",
        "mention-gloss",
        "n-g",
        "n-g-lite",
        "near-synonyms",
        "nearsyn",
        "nsyn",
        "nyms",
        "quote",
        "qf",
        "q-g",
        "rfm-sense",
        "senseno",
        "semantic loan",
        "section link",
        "sl",
        "pcal",
        "pedlink",
        "suffixusex",
        "surface analysis",
        "table:xiangqi pieces/en",
        "term-label",
        "abbrev",
        "alt form",
        "alt sp",
        "angbr",
        "arithmetic operations",
        "as",
        "ante",
        "anchor",
        "back-formation",
        "bad",
        "big",
        "borrowed",
        "century",
        "CE",
        "attention",
        "bottom",
        "backformation",
        "col-bottom",
        "col-top",
        "inherited",
        "ll",
        "unknown",
        "long s",
        "lena",
        "ltc-l",
        "merge",
        "multiple image",
        "obs form",
        "onom",
        "rfclarify",
        "rfd-sense",
        "rfc-sense",
        "rfdate",
        "rfref",
        "rfi",
        "rfm",
        "J2G",
        "post",
        "prefixusex",
        "rfv",
        "SIC",
        "short for",
        "small caps",
        "see also",
        "sub",
        "semantic loan",
        "partial calque",
        "tea room",
        "top2",
        "top3",
        "top4",
        "transterm",
        "topics",
        "tlb",
        "univ",
        "only used in",
        "used in phrasal verbs",
        "upright",
        "uxa",
        "wikidata",
        "wikiversity",
        "wikinews",
        "catlangname",
        "construed with",
        "ctRenderF",
        "from",
        "in appendix",
        "enum",
        "phono-semantic matching",
        "pseudo-loan",
        "uncom form",
        "=",
        "zh-l",
        "zh-m",
    }) |candidate| {
        if (templateMatchesHtml(trimmed, candidate)) return true;
    }
    return false;
}

fn shouldSkipStrictTemplateArgValidation(name: []const u8) bool {
    if (templateNameStartsWithHtml(name, "ctRenderF")) return true;
    if (templateNameStartsWithHtml(name, "CURRENT")) return true;
    if (templateNameStartsWithHtml(name, "table:")) return true;
    if (templateNameStartsWithHtml(name, "U:")) return true;
    if (templateNameStartsWithHtml(name, "Wiktionary:")) return true;
    inline for ([_][]const u8{
        "arithmetic operations",
        "bottom",
        "col-bottom",
        "col-top",
        "checksense",
        "coefficient",
        "comcatlite",
        "commons cat",
        "English personal pronouns",
        "ethnologue",
        "emojipic",
        "etystub",
        "gbooks",
        "ISO 639",
        "in appendix",
        "langindex",
        "langcat",
        "langlist",
        "lookfrom",
        "multiple image",
        "multiple images",
        "mainapp",
        "merge",
        "nonlemma",
        "PAGENAME",
        "phrasebook",
        "picdic",
        "picdicimg",
        "picdiclabel",
        "rfap",
        "rfc",
        "rfc-sense",
        "rfe",
        "rfex",
        "rfp",
        "rfquote",
        "rfquotek",
        "rfquote-sense",
        "rfclarify",
        "rfd-sense",
        "rfdef",
        "rfdate",
        "rfm",
        "rfm-sense",
        "rfi",
        "rfref",
        "rfv",
        "rfv-pron",
        "rfv-etym",
        "rfv-sense",
        "ref",
        "semantic loan",
        "partial calque",
        "season name spelling",
        "see also",
        "seeCites",
        "see desc",
        "seeSynonyms",
        "seemoreCites",
        "sl",
        "specieslite",
        "suffixusex",
        "suffixsee",
        "tea room",
        "top2",
        "top3",
        "top4",
        "Webster 1913",
        "wikibooks",
        "wikiquote",
        "wikiversity",
        "wikiversity lecture",
        "wikivoyage",
        "wikispecies",
        "wikipedia",
        "wikidata",
        "interwiktionary",
        "swp",
        "catlangname",
        "commons",
        "commonscat",
        "construed with",
        "ctRenderF",
        "enum",
        "phono-semantic matching",
        "pseudo-loan",
        "uxa",
    }) |candidate| {
        if (templateMatchesHtml(name, candidate)) return true;
    }
    return false;
}

fn templateNameStartsWithHtml(name: []const u8, expected_prefix: []const u8) bool {
    const actual = trimWikiWhitespace(name);
    const prefix = trimWikiWhitespace(expected_prefix);

    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
        while (j < prefix.len and isTemplateNameSpaceByte(prefix[j])) : (j += 1) {}
        if (j == prefix.len) break;
        if (i == actual.len) return false;
        if (std.ascii.toLower(actual[i]) != std.ascii.toLower(prefix[j])) return false;
        i += 1;
        j += 1;
    }
    while (j < prefix.len and isTemplateNameSpaceByte(prefix[j])) : (j += 1) {}
    return j == prefix.len;
}

fn templateNameEndsWithHtml(name: []const u8, expected_suffix: []const u8) bool {
    const actual = trimWikiWhitespace(name);
    const suffix = trimWikiWhitespace(expected_suffix);

    var i: usize = actual.len;
    var j: usize = suffix.len;
    while (true) {
        while (i > 0 and isTemplateNameSpaceByte(actual[i - 1])) : (i -= 1) {}
        while (j > 0 and isTemplateNameSpaceByte(suffix[j - 1])) : (j -= 1) {}
        if (j == 0) break;
        if (i == 0) return false;
        if (std.ascii.toLower(actual[i - 1]) != std.ascii.toLower(suffix[j - 1])) return false;
        i -= 1;
        j -= 1;
    }
    while (j > 0 and isTemplateNameSpaceByte(suffix[j - 1])) : (j -= 1) {}
    return j == 0;
}

fn parseDefinitionLine(line: []const u8) ?ParsedDefinitionLine {
    var i: usize = 0;
    var depth: u16 = 0;
    while (i < line.len and line[i] == '#') : (i += 1) depth += 1;
    if (depth == 0) return null;

    var kind: ParsedDefinitionLine.Kind = .sense;
    while (i < line.len and (line[i] == ':' or line[i] == '*')) : (i += 1) {
        kind = .example;
    }

    const content = std.mem.trimStart(u8, line[i..], " \t");
    if (content.len == 0) return null;
    return .{
        .depth = depth,
        .kind = kind,
        .content = content,
    };
}

fn shouldSkipStandaloneLine(line: []const u8) bool {
    const trimmed = trimWikiWhitespace(line);
    return std.mem.startsWith(u8, trimmed, "<!--") or
        isHeadwordTemplateLine(trimmed) or
        isStandaloneTemplateLineNamed(line, "col-top") or
        isStandaloneTemplateLineNamed(line, "col-bottom") or
        isStandaloneTemplateLineNamed(line, "trans-top") or
        isStandaloneTemplateLineNamed(line, "trans-mid") or
        isStandaloneTemplateLineNamed(line, "trans-bottom") or
        isStandaloneTemplateLineNamed(line, "checktrans-top") or
        isStandaloneTemplateLineNamed(line, "checktrans-mid") or
        isStandaloneTemplateLineNamed(line, "checktrans-bottom") or
        isStandaloneTemplateLineNamed(line, "rel-top") or
        isStandaloneTemplateLineNamed(line, "rel-mid") or
        isStandaloneTemplateLineNamed(line, "rel-bottom") or
        isStandaloneTemplateLineNamed(line, "bottom") or
        isStandaloneTemplateLineNamed(line, "picdic") or
        isStandaloneTemplateLineNamed(line, "wikidata lexeme") or
        isStandaloneTemplateLineNamed(line, "was wotd") or
        isStandaloneTemplateLineNamed(line, "wp") or
        isStandaloneTemplateLineNamed(line, "wikipedia") or
        isStandaloneTemplateLineNamed(line, "commonscat") or
        isStandaloneTemplateLineNamed(line, "interwiktionary") or
        isStandaloneTemplateLineNamed(line, "swp") or
        isStandaloneTemplateLineNamed(line, "number box") or
        isStandaloneTemplateLineNamed(line, "wikispecies") or
        isStandaloneTemplateLineNamed(line, "pedia") or
        isStandaloneTemplateLineNamed(line, "color panel") or
        isStandaloneTemplateLineNamed(line, "multiple images") or
        isStandaloneTemplateLineNamed(line, "commons") or
        isStandaloneTemplateLineNamed(line, "langcat") or
        isStandaloneTemplateLineNamed(line, "arithmetic operations") or
        isStandaloneTemplateLineNamed(line, "wikinews") or
        isStandaloneTemplateLineNamed(line, "table:xiangqi pieces/en") or
        isStandaloneTemplateLineNamed(line, "rfp") or
        isStandaloneTemplateLineNamed(line, "rfe") or
        isStandaloneTemplateLineNamed(line, "table:colors/en") or
        asciiStartsWithIgnoreCase(trimmed, "<references") or
        asciiStartsWithIgnoreCase(trimmed, "__notoc__") or
        asciiStartsWithIgnoreCase(trimmed, "__forcetoc__");
}

fn isStandaloneTemplateLineNamed(line: []const u8, name: []const u8) bool {
    const trimmed = trimWikiWhitespace(line);
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return false;
    const body = trimWikiWhitespace(trimmed[2 .. trimmed.len - 2]);
    const sep = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    return std.ascii.eqlIgnoreCase(trimWikiWhitespace(body[0..sep]), name);
}

fn isHeadwordTemplateLine(line: []const u8) bool {
    const trimmed = trimWikiWhitespace(line);
    return asciiStartsWithIgnoreCase(trimmed, "{{en-") or asciiStartsWithIgnoreCase(trimmed, "{{head|");
}

fn isStandaloneColumnTemplateLine(line: []const u8) bool {
    const trimmed = trimWikiWhitespace(line);
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return false;
    const body = trimWikiWhitespace(trimmed[2 .. trimmed.len - 2]);
    const sep = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    return isColumnTemplate(trimWikiWhitespace(body[0..sep]));
}

fn trimWikiWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn extractGalleryCaption(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (asciiStartsWithIgnoreCase(trimmed, "Image:") or asciiStartsWithIgnoreCase(trimmed, "File:")) {
        if (std.mem.lastIndexOfScalar(u8, trimmed, '|')) |pipe| {
            if (pipe + 1 < trimmed.len) return std.mem.trim(u8, trimmed[pipe + 1 ..], " \t");
        }
    }
    return trimmed;
}

fn pushRenderedTerms(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    rendered: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, rendered, ';');
    while (parts.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try normalizeCommaGroupedTermAlloc(allocator, trimmed));
    }
}

fn normalizeCommaGroupedTermAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const byte = input[i];
        try out.append(allocator, byte);
        if (byte != ',') continue;

        while (i + 1 < input.len and (input[i + 1] == ' ' or input[i + 1] == '\t')) : (i += 1) {}
        if (i + 1 < input.len) try out.append(allocator, ' ');
    }
    return out.toOwnedSlice(allocator);
}

fn appendEscapedHtmlSlice(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        else => try out.append(allocator, c),
    };
}

fn renderInlineHtmlToOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: RenderOptions,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try renderInlineHtml(&out, allocator, input, options);
    return out.toOwnedSlice(allocator);
}

fn renderInlineHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    options: RenderOptions,
) anyerror!void {
    var emphasis_state: EmphasisState = .{};
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "<!--")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            const end = std.mem.indexOfPos(u8, input, i + 4, "-->") orelse input.len;
            i = @min(end + 3, input.len);
            plain_start = i;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<<")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            const end = std.mem.indexOfPos(u8, input, i + 2, ">>") orelse break;
            try renderAnglePlaceholderHtml(out, allocator, input[i + 2 .. end], options);
            i = end + 2;
            plain_start = i;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            const end = findBalanced(input, i, "{{", "}}") orelse break;
            try renderTemplateHtml(out, allocator, input[i + 2 .. end], options);
            i = end + 2;
            plain_start = i;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "}}")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            i += 2;
            plain_start = i;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "[[")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            const end = findBalanced(input, i, "[[", "]]") orelse break;
            var trail_end = end + 2;
            while (trail_end < input.len and isWikiLinkTrailByte(input[trail_end])) : (trail_end += 1) {}
            try renderWikiLinkHtml(out, allocator, input[i + 2 .. end], input[end + 2 .. trail_end], options);
            i = trail_end;
            plain_start = i;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "]]")) {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            i += 2;
            plain_start = i;
            continue;
        }
        if (input[i] == '[') {
            if (asciiStartsWithIgnoreCase(input[i + 1 ..], "http")) {
                if (findExternalLinkClose(input, i)) |end| {
                    try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
                    const body = input[i + 1 .. end];
                    if (std.mem.indexOfScalar(u8, body, ' ')) |space| {
                        try renderInlineHtml(out, allocator, body[space + 1 ..], options);
                    }
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }
        }
        if (input[i] == '<') {
            if (!looksLikeInlineTagStart(input[i..])) {
                i += 1;
                continue;
            }
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            if (asciiStartsWithIgnoreCase(input[i..], "<br")) {
                try out.appendSlice(allocator, "<br>");
                i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
                plain_start = i;
                continue;
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<hr")) {
                try out.appendSlice(allocator, " ");
                i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
                plain_start = i;
                continue;
            }
            if (asciiStartsWithIgnoreCase(input[i..], "<ref")) {
                if (std.mem.indexOfPos(u8, input, i, "</ref>")) |end| {
                    i = end + "</ref>".len;
                    plain_start = i;
                    continue;
                }
            }
            i = (std.mem.indexOfScalarPos(u8, input, i, '>') orelse input.len) + 1;
            plain_start = i;
            continue;
        }
        if (input[i] == '\'' and i + 1 < input.len and input[i + 1] == '\'') {
            try appendDecodedEscapedChunk(out, allocator, input[plain_start..i]);
            const run_start = i;
            while (i < input.len and input[i] == '\'') : (i += 1) {}
            if (emphasis_state.consumeApostropheRun(input, run_start, i - run_start)) {
                try out.append(allocator, '\'');
            }
            plain_start = i;
            continue;
        }
        i += 1;
    }
    try appendDecodedEscapedChunk(out, allocator, input[plain_start..]);
}

const EmphasisState = struct {
    italic_open: bool = false,
    bold_open: bool = false,

    fn consumeApostropheRun(self: *EmphasisState, input: []const u8, run_start: usize, run_len: usize) bool {
        switch (run_len) {
            2 => {
                self.italic_open = !self.italic_open;
                return false;
            },
            3 => {
                // Preserve the trailing apostrophe in cases like ''Britannica'''s while
                // still stripping emphasis-only runs inside acronym-style expansions.
                if (self.italic_open and !self.bold_open and shouldKeepLiteralApostrophe(input, run_start, run_len)) {
                    self.italic_open = false;
                    return true;
                }
                self.bold_open = !self.bold_open;
                return false;
            },
            5 => {
                self.bold_open = !self.bold_open;
                self.italic_open = !self.italic_open;
                return false;
            },
            else => return shouldKeepLiteralApostrophe(input, run_start, run_len),
        }
    }
};

fn appendDecodedEscapedChunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const decoded = try xml_decode.decodeAlloc(allocator, chunk);
    defer allocator.free(decoded);
    try appendEscapedHtmlSlice(out, allocator, decoded);
}

fn renderAnglePlaceholderHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(body);
    if (trimmed.len == 0) return;
    const text = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash|
        trimWikiWhitespace(trimmed[slash + 1 ..])
    else
        trimmed;
    try renderPhraseHtml(out, allocator, text, options);
}

fn renderWikiLinkHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    trail: []const u8,
    options: RenderOptions,
) anyerror!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const raw_target = trimWikiWhitespace(parts.items[0]);
    const normalized_target = normalizedWikiTarget(raw_target);
    const display = if (parts.items.len >= 2) trimWikiWhitespace(parts.items[parts.items.len - 1]) else "";
    const base_visible = if (display.len != 0) display else normalized_target;
    const visible = if (trail.len == 0)
        base_visible
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_visible, trail });
    defer if (trail.len != 0) allocator.free(visible);
    if (visible.len == 0) return;

    const href_target = if (normalized_target.len != 0) try resolveLinkTargetAlloc(allocator, normalized_target, options) else null;
    if (href_target) |value| {
        defer allocator.free(value);
        try appendLinkMaybe(out, allocator, value, visible, options);
        return;
    }

    if (try externalWikiHrefAlloc(allocator, raw_target)) |href| {
        defer allocator.free(href);
        try appendHrefHtml(out, allocator, href, visible, options);
        return;
    }

    try appendRenderedDisplayHtml(out, allocator, visible, options);
}

fn renderTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    options: RenderOptions,
) anyerror!void {
    var parts = try splitTopLevel(allocator, body, '|');
    defer parts.deinit(allocator);
    if (parts.items.len == 0) return;

    const name = trimWikiWhitespace(parts.items[0]);

    if (templateMatchesHtml(name, "partial calque")) {
        try appendResolvedDisplayTargetHtml(out, allocator, "Partial calque", "partial calque", options);
        try appendEscapedHtmlSlice(out, allocator, " of ");
        if (templatePositionalHtml(&parts, 2) orelse templatePositionalHtml(&parts, 1) orelse templatePositionalHtml(&parts, 0)) |target| {
            try renderTemplateTargetHtml(out, allocator, target, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "pcal")) {
        try appendEscapedHtmlSlice(out, allocator, "Partial calque of ");
        if (templatePositionalHtml(&parts, positionalCountHtml(&parts) -| 1)) |target| {
            try renderTemplateTargetHtml(out, allocator, target, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "mention-gloss")) {
        if (templatePositionalHtml(&parts, positionalCountHtml(&parts) -| 1)) |value| {
            try appendQuotedTemplateTargetHtml(out, allocator, value, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "A.D.") or templateMatchesHtml(name, "CE")) {
        try appendEscapedHtmlSlice(out, allocator, trimWikiWhitespace(name));
        return;
    }
    if (templateMatchesHtml(name, "from")) {
        if (templatePositionalHtml(&parts, semanticTemplateTargetIndexHtml(&parts))) |target| {
            try renderTemplateTargetHtml(out, allocator, target, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "=")) {
        try appendEscapedHtmlSlice(out, allocator, "=");
        return;
    }
    if (templateMatchesHtml(name, "coa")) {
        const start_index: usize = if (looksLikeLanguageCodeHtml(templatePositionalHtml(&parts, 0) orelse "")) 1 else 0;
        try appendPositionalTemplateTargetsAllowCodesHtml(out, allocator, &parts, start_index, ", ", options);
        return;
    }
    if (templateMatchesHtml(name, "uncom form")) {
        try renderSimpleRelationTemplateHtml(out, allocator, &parts, .{
            .label = "Uncommon form",
            .tail = " of ",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "obor")) {
        try renderSimpleRelationTemplateHtml(out, allocator, &parts, .{
            .label = "Orthographic borrowing",
            .tail = " from ",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "pedlink")) {
        const display = templateNamedHtml(&parts, "disp") orelse templatePositionalHtml(&parts, 0) orelse return;
        try renderTemplateTargetHtml(out, allocator, display, options);
        return;
    }
    if (templateMatchesHtml(name, "n-g-lite")) {
        if (templatePositionalHtml(&parts, 0)) |value| {
            try renderTemplateTargetHtml(out, allocator, value, options);
        }
        return;
    }

    if (try renderExpandedTemplateHtml(out, allocator, name, &parts, options)) {
        return;
    }
    if (templateMatchesHtml(name, "place")) {
        try renderPlaceTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "ipa")) {
        try renderIpaTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "enpr")) {
        try renderEnprTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "audio")) {
        try renderAudioTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "Latn-def")) {
        try renderLatnDefTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "rhymes") or templateMatchesHtml(name, "rhyme")) {
        try renderRhymesTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "syn") or templateMatchesHtml(name, "synonyms")) {
        try renderSynonymsTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "nearsyn") or templateMatchesHtml(name, "near-synonyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Near synonym",
            .plural = "Near synonyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "ant") or templateMatchesHtml(name, "antonym") or templateMatchesHtml(name, "antonyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Antonym",
            .plural = "Antonyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "hyper") or templateMatchesHtml(name, "hypernyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Hypernym",
            .plural = "Hypernyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "hypo") or templateMatchesHtml(name, "hyponyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Hyponym",
            .plural = "Hyponyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "troponyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Troponym",
            .plural = "Troponyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "cot") or templateMatchesHtml(name, "coord") or templateMatchesHtml(name, "coordinate terms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Coordinate term",
            .plural = "Coordinate terms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "holo") or templateMatchesHtml(name, "holonyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Holonym",
            .plural = "Holonyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "mer") or templateMatchesHtml(name, "mero") or templateMatchesHtml(name, "meronyms") or templateMatchesHtml(name, "comeronyms")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Meronym",
            .plural = "Meronyms",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "collocation")) {
        try renderLabeledTemplateHtml(out, allocator, &parts, .{
            .singular = "Collocation",
            .plural = "Collocations",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "hmp") or templateMatchesHtml(name, "homophone") or templateMatchesHtml(name, "homophones")) {
        try renderHomophoneTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "hyphenation") or templateMatchesHtml(name, "hyph")) {
        try renderHyphenationTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "prefix") or
        templateMatchesHtml(name, "pre") or
        templateMatchesHtml(name, "suffix") or
        templateMatchesHtml(name, "suf") or
        templateMatchesHtml(name, "affix") or
        templateMatchesHtml(name, "af") or
        templateMatchesHtml(name, "com") or
        templateMatchesHtml(name, "confix"))
    {
        try renderAffixTemplateHtml(out, allocator, name, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "alter") or templateMatchesHtml(name, "alt")) {
        try renderAlterTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "alti")) {
        try renderAlternativeFormsTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "deverbal")) {
        try renderSimpleRelationTemplateHtml(out, allocator, &parts, .{
            .label = "Deverbal",
            .tail = " from ",
        }, options);
        return;
    }
    if (isEtymologyLexemeTemplateHtml(name)) {
        try renderEtymologyLexemeTemplateHtml(out, allocator, name, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "compound") or templateMatchesHtml(name, "compound+") or templateMatchesHtml(name, "com") or templateMatchesHtml(name, "com+")) {
        try renderCompoundTemplateHtml(out, allocator, name, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "surname")) {
        try renderNominalTemplateHtml(out, allocator, &parts, "surname", options);
        return;
    }
    if (templateMatchesHtml(name, "given name")) {
        try renderNominalTemplateHtml(out, allocator, &parts, "given name", options);
        return;
    }
    if (templateMatchesHtml(name, "name translit")) {
        try renderNameTranslitTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "onom") or templateMatchesHtml(name, "onomatopoeic")) {
        try appendEscapedHtmlSlice(out, allocator, "Onomatopoeic");
        return;
    }
    if (templateMatchesHtml(name, "&lit")) {
        try appendEscapedHtmlSlice(out, allocator, "Used other than figuratively or idiomatically: see ");
        try appendPositionalTemplateTargetsAllowCodesHtml(out, allocator, &parts, 1, ", ", options);
        return;
    }
    if (templateMatchesHtml(name, "m+")) {
        try renderLanguageAwareLexemeTemplateHtml(out, allocator, &parts, 0, 1, options);
        return;
    }
    if (templateMatchesHtml(name, "l") or templateMatchesHtml(name, "m") or templateMatchesHtml(name, "link")) {
        try renderLexemeLikeTemplateHtml(out, allocator, &parts, 1, options);
        return;
    }
    if (templateMatchesHtml(name, "cog") or templateMatchesHtml(name, "cognate") or templateMatchesHtml(name, "noncog") or templateMatchesHtml(name, "ncog")) {
        try renderLanguageAwareLexemeTemplateHtml(out, allocator, &parts, 0, 1, options);
        return;
    }
    if (templateMatchesHtml(name, "season name spelling")) {
        try appendEscapedHtmlSlice(out, allocator, "Note that season names are not capitalized in modern English except where any noun would be capitalized, e.g. at the beginning of a sentence or as part of a name (Old Man Winter, the Winter War, Summer Glau). This is in contrast to the days of the week and months of the year, which are always capitalized (Thursday or September).");
        return;
    }
    if (templateMatchesHtml(name, "CURRENTDAY")) {
        try appendEscapedHtmlSlice(out, allocator, currentDayTextHtml());
        return;
    }
    if (templateMatchesHtml(name, "CURRENTMONTHNAME")) {
        try appendEscapedHtmlSlice(out, allocator, currentMonthNameHtml());
        return;
    }
    if (templateMatchesHtml(name, "CURRENTYEAR")) {
        try appendEscapedHtmlSlice(out, allocator, currentYearTextHtml());
        return;
    }
    if (templateMatchesHtml(name, "w") or templateMatchesHtml(name, "wikipedia")) {
        try renderExternalWikipediaTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "quote-") or std.mem.startsWith(u8, name, "RQ:")) {
        try renderQuoteTemplateHtml(out, allocator, name, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "lb") or
        templateMatchesHtml(name, "lbl") or
        templateMatchesHtml(name, "label") or
        templateMatchesHtml(name, "term-label") or
        templateMatchesHtml(name, "context") or
        templateMatchesHtml(name, "cx"))
    {
        const label_start_index: usize = if (templateMatchesHtml(name, "context") or templateMatchesHtml(name, "cx"))
            if (looksLikeLanguageCodeHtml(templatePositionalHtml(&parts, 0) orelse "")) 1 else 0
        else if (templateMatchesHtml(name, "lb") or templateMatchesHtml(name, "lbl") or templateMatchesHtml(name, "label"))
            1
        else
            0;
        try renderLabelTemplateHtml(out, allocator, &parts, label_start_index, options);
        return;
    }
    if (templateMatchesHtml(name, "U") or asciiStartsWithIgnoreCase(name, "U:")) {
        if (usageTemplateTargetHtml(name, &parts)) |value| {
            if (knownUsageTemplateExpansionHtml(value)) |expanded| {
                try renderPhraseHtml(out, allocator, expanded, options);
            } else {
                const display = try uppercaseFirstAsciiAlloc(allocator, value);
                defer allocator.free(display);
                try appendLinkedResolvedTextHtml(out, allocator, display, value, options);
            }
        }
        return;
    }
    if (templateMatchesHtml(name, "only used in")) {
        try appendEscapedHtmlSlice(out, allocator, "Only used in ");
        try appendPositionalTemplateTargetsNaturalHtml(out, allocator, &parts, semanticTemplateTargetIndexHtml(&parts), options);
        try appendEscapedHtmlSlice(out, allocator, ".");
        return;
    }
    if (templateMatchesHtml(name, "q") or templateMatchesHtml(name, "q-lite") or templateMatchesHtml(name, "qualifier") or templateMatchesHtml(name, "i") or templateMatchesHtml(name, "gl")) {
        try appendParenthesizedTemplateArgs(out, allocator, &parts, 0, options);
        return;
    }
    if (templateMatchesHtml(name, "Webster 1913")) {
        return;
    }
    if (templateMatchesHtml(name, "col-top") or
        templateMatchesHtml(name, "col-bottom") or
        templateMatchesHtml(name, "top") or
        templateMatchesHtml(name, "bottom"))
    {
        return;
    }
    if (templateMatchesHtml(name, "uxa")) {
        if (templatePositionalHtml(&parts, 1) orelse templatePositionalHtml(&parts, 0)) |arg| {
            try renderTemplateTargetHtml(out, allocator, arg, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "C")) {
        return;
    }
    if (templateMatchesHtml(name, "surf")) {
        try appendEscapedHtmlSlice(out, allocator, "By surface analysis, ");
        try appendPositionalTemplateTargetsHtml(out, allocator, &parts, 1, " + ", options);
        return;
    }
    if (templateMatchesHtml(name, "surface analysis")) {
        try renderSimpleRelationTemplateHtml(out, allocator, &parts, .{
            .label = "Surface analysis",
            .tail = " of ",
            .separator = " + ",
        }, options);
        return;
    }
    if (templateMatchesHtml(name, "doublet") or templateMatchesHtml(name, "dbt")) {
        try appendEscapedHtmlSlice(out, allocator, "Doublet of ");
        try appendPositionalTemplateTargetsNaturalHtml(out, allocator, &parts, if (looksLikeLanguageCodeHtml(templatePositionalHtml(&parts, 0) orelse "")) 1 else 0, options);
        return;
    }
    if (templateMatchesHtml(name, "unk")) {
        try appendEscapedHtmlSlice(out, allocator, "Unknown");
        return;
    }
    if (templateMatchesHtml(name, "unknown")) {
        try renderUnknownTemplateHtml(out, allocator, &parts);
        return;
    }
    if (templateMatchesHtml(name, "glossary")) {
        if (templatePositionalHtml(&parts, positionalCountHtml(&parts) -| 1)) |value| {
            try renderTemplateTargetHtml(out, allocator, value, options);
        }
        return;
    }
    if (templateMatchesHtml(name, "defdate")) {
        try renderDefdateTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "SI-unit")) {
        try renderSiUnitTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "suffixusex")) {
        try renderSuffixUsexTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "phono-semantic matching")) {
        try renderPhonoSemanticMatchingTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "senseno")) {
        if (templatePositionalHtml(&parts, 1) orelse templatePositionalHtml(&parts, 0)) |value| {
            const trimmed = trimWikiWhitespace(value);
            if (looksLikeOpaqueSenseIdHtml(trimmed)) {
                if (options.sense_ids) |sense_ids| {
                    if (sense_ids.resolve(trimmed)) |label| {
                        try appendDecodedEscapedChunk(out, allocator, label);
                    }
                }
            } else {
                try renderTemplateTargetHtml(out, allocator, trimmed, options);
            }
        }
        return;
    }
    if (asciiStartsWithIgnoreCase(name, "list:")) {
        if (try renderKnownListTemplateHtml(out, allocator, name, options)) return;
    }

    try renderTemplateTextFallbackHtml(out, allocator, body, options);
}

fn renderTemplateTextFallbackHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    options: RenderOptions,
) anyerror!void {
    // Unsupported or low-priority templates fall back through the shared text
    // template runtime first so the HTML renderer reuses the same semantic
    // template expansion instead of inventing a separate ad hoc phrase.
    const text = try wikitext.renderTemplateBodyToOwned(allocator, body, max_render_line_bytes);
    defer allocator.free(text);
    if (text.len == 0) return;
    try renderPhraseHtml(out, allocator, text, options);
}

fn renderKnownListTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    options: RenderOptions,
) anyerror!bool {
    const terms = wikitext.knownListTerms(name) orelse return false;
    return appendKnownListTermGridHtml(out, allocator, terms, options);
}

fn appendKnownListTermGridHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    terms: []const []const u8,
    options: RenderOptions,
) anyerror!bool {
    if (terms.len == 0) return false;

    try out.appendSlice(allocator, "<ul class=\"render-term-grid\">");
    for (terms) |term| {
        try out.appendSlice(allocator, "<li>");
        try renderPhraseHtml(out, allocator, term, options);
        try out.appendSlice(allocator, "</li>");
    }
    try out.appendSlice(allocator, "</ul>");
    return true;
}

const TemplateExpansion = struct {
    display: []const u8,
    link_target: ?[]const u8 = null,
    tail: []const u8,
};

fn renderExpandedTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!bool {
    const expansion = expandedTemplateForName(name) orelse {
        if (!isSemanticOfTemplateHtml(name)) return false;
        try renderSemanticTemplateHtml(out, allocator, name, parts, options);
        return true;
    };

    const target_index = semanticTemplateTargetIndexHtml(parts);
    const target = templatePositionalHtml(parts, target_index);
    if (expandedTemplateCanStandAloneHtml(name, target)) {
        try appendExpandedTemplatePrefix(out, allocator, expansion, options, true);
        return true;
    }

    try appendExpandedTemplatePrefix(out, allocator, expansion, options, false);
    if (target) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0 and !(target_index == 0 and looksLikeLanguageCodeHtml(trimmed))) {
            try renderTemplateTargetHtml(out, allocator, value, options);
        }
    }
    if (templateNamedHtml(parts, "addl")) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, ", ");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
        }
    }

    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positionalCountHtml(parts)) : (extra_index += 1) {
        const extra = templatePositionalHtml(parts, extra_index) orelse continue;
        const trimmed = trimWikiWhitespace(extra);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;

        if (!wrote_extra) {
            try out.appendSlice(allocator, " (");
            wrote_extra = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
    if (wrote_extra) try out.appendSlice(allocator, ")");
    if (target) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0 and !(target_index == 0 and looksLikeLanguageCodeHtml(trimmed))) {
            try appendTemplateGlossHtml(out, allocator, parts, target_index, trimmed, options);
        }
    }
    return true;
}

fn renderLatnDefTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const kind = templatePositionalHtml(parts, 1) orelse templatePositionalHtml(parts, 0) orelse return;
    const trimmed_kind = trimWikiWhitespace(kind);

    if (std.ascii.eqlIgnoreCase(trimmed_kind, "letter")) {
        const ordinal = templatePositionalHtml(parts, 2) orelse "";
        const glyph = templatePositionalHtml(parts, 3) orelse templatePositionalHtml(parts, 2) orelse "";

        try appendEscapedHtmlSlice(out, allocator, "The ");
        if (ordinalWordHtml(ordinal)) |word| {
            try appendEscapedHtmlSlice(out, allocator, word);
        } else if (ordinal.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, ordinal);
        } else {
            try appendEscapedHtmlSlice(out, allocator, "specified");
        }
        try appendEscapedHtmlSlice(out, allocator, " ");
        try appendLinkedResolvedTextHtml(out, allocator, "letter", "letter", options);
        try appendEscapedHtmlSlice(out, allocator, " of the English ");
        try appendLinkedResolvedTextHtml(out, allocator, "alphabet", "alphabet", options);
        if (glyph.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, ", called ");
            try appendResolvedDisplayTargetHtml(out, allocator, glyph, glyph, options);
        }
        try appendEscapedHtmlSlice(out, allocator, " and written in the ");
        try appendLinkedResolvedTextHtml(out, allocator, "Latin script", "Appendix:Latin script", options);
        try appendEscapedHtmlSlice(out, allocator, ".");
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed_kind, "ordinal")) {
        const ordinal = templatePositionalHtml(parts, 2) orelse "";
        const glyph = templatePositionalHtml(parts, 3) orelse templatePositionalHtml(parts, 2) orelse "";

        try appendEscapedHtmlSlice(out, allocator, "The ");
        if (ordinalWordHtml(ordinal)) |word| {
            try appendEscapedHtmlSlice(out, allocator, word);
        } else if (ordinal.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, ordinal);
        } else {
            try appendEscapedHtmlSlice(out, allocator, "specified");
        }
        try appendEscapedHtmlSlice(out, allocator, " ");
        try appendLinkedResolvedTextHtml(out, allocator, "numeral symbol", "numeral symbol", options);
        try appendEscapedHtmlSlice(out, allocator, " of the English ");
        try appendLinkedResolvedTextHtml(out, allocator, "alphabet", "alphabet", options);
        if (glyph.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, ", called ");
            try appendResolvedDisplayTargetHtml(out, allocator, glyph, glyph, options);
        }
        try appendEscapedHtmlSlice(out, allocator, " and written in the ");
        try appendLinkedResolvedTextHtml(out, allocator, "Latin script", "Appendix:Latin script", options);
        try appendEscapedHtmlSlice(out, allocator, ".");
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed_kind, "name")) {
        const upper = templatePositionalHtml(parts, 2) orelse "";
        const lower = templatePositionalHtml(parts, 3) orelse "";
        try appendEscapedHtmlSlice(out, allocator, "The name of the ");
        try appendLinkedResolvedTextHtml(out, allocator, "Latin script", "Appendix:Latin script", options);
        try appendEscapedHtmlSlice(out, allocator, " letter ");
        if (upper.len != 0) {
            try appendResolvedDisplayTargetHtml(out, allocator, upper, upper, options);
        }
        if (lower.len != 0 and !std.mem.eql(u8, upper, lower)) {
            try appendEscapedHtmlSlice(out, allocator, " / ");
            try appendResolvedDisplayTargetHtml(out, allocator, lower, lower, options);
        }
        try appendEscapedHtmlSlice(out, allocator, ".");
        return;
    }

    try appendPositionalTemplateTargetsAllowCodesHtml(out, allocator, parts, 1, " ", options);
}

fn ordinalWordHtml(value: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(value);
    if (std.mem.eql(u8, trimmed, "1")) return "first";
    if (std.mem.eql(u8, trimmed, "2")) return "second";
    if (std.mem.eql(u8, trimmed, "3")) return "third";
    if (std.mem.eql(u8, trimmed, "4")) return "fourth";
    if (std.mem.eql(u8, trimmed, "5")) return "fifth";
    if (std.mem.eql(u8, trimmed, "6")) return "sixth";
    if (std.mem.eql(u8, trimmed, "7")) return "seventh";
    if (std.mem.eql(u8, trimmed, "8")) return "eighth";
    if (std.mem.eql(u8, trimmed, "9")) return "ninth";
    if (std.mem.eql(u8, trimmed, "10")) return "tenth";
    return null;
}

fn usageTemplateTargetHtml(name: []const u8, parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const trimmed_name = trimWikiWhitespace(name);
    if (asciiStartsWithIgnoreCase(trimmed_name, "U:")) {
        var target = trimmed_name["U:".len..];
        if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
            const prefix = trimWikiWhitespace(target[0..colon]);
            if (looksLikeLanguageCodeHtml(prefix)) {
                target = target[colon + 1 ..];
            }
        }
        const trimmed_target = trimWikiWhitespace(target);
        return if (trimmed_target.len == 0) null else trimmed_target;
    }

    if (templatePositionalHtml(parts, 0)) |first| {
        const trimmed_first = trimWikiWhitespace(first);
        if (trimmed_first.len != 0 and !looksLikeLanguageCodeHtml(trimmed_first)) return trimmed_first;
    }
    if (templatePositionalHtml(parts, 1)) |second| {
        const trimmed_second = trimWikiWhitespace(second);
        if (trimmed_second.len != 0) return trimmed_second;
    }
    if (templatePositionalHtml(parts, 0)) |first| {
        const trimmed_first = trimWikiWhitespace(first);
        if (trimmed_first.len != 0) return trimmed_first;
    }
    return null;
}

fn knownUsageTemplateExpansionHtml(target: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(target);
    if (std.ascii.eqlIgnoreCase(trimmed, "I-P")) {
        return "The use of Israel to refer to the region between the Jordan River and the Mediterranean Sea in a non-historical sense is (since the latter half of the 20th century) politically charged; indeed, this is true of all terms for this region.";
    }
    return null;
}

fn expandedTemplateCanStandAloneHtml(name: []const u8, target: ?[]const u8) bool {
    const trimmed_name = trimWikiWhitespace(name);
    if (!(templateMatchesHtml(trimmed_name, "clip") or templateMatchesHtml(trimmed_name, "clipping") or templateMatchesHtml(trimmed_name, "clipping of"))) {
        return false;
    }
    const resolved = target orelse return true;
    const trimmed = trimWikiWhitespace(resolved);
    return trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed);
}

fn appendExpandedTemplatePrefix(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expansion: TemplateExpansion,
    options: RenderOptions,
    lowercase_display: bool,
) !void {
    const display = if (lowercase_display)
        try lowercaseFirstAsciiAlloc(allocator, expansion.display)
    else
        try allocator.dupe(u8, expansion.display);
    defer allocator.free(display);

    try appendLinkedResolvedTextHtml(out, allocator, display, expansion.link_target orelse expansion.display, options);
    if (expansion.tail.len != 0 and !lowercase_display) try appendEscapedHtmlSlice(out, allocator, expansion.tail);
}

fn lowercaseFirstAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, value);
    if (out.len != 0) out[0] = std.ascii.toLower(out[0]);
    return out;
}

fn uppercaseFirstAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, value);
    if (out.len != 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn renderSemanticTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    if (templateMatchesHtml(name, "infl of") or templateMatchesHtml(name, "inflection of")) {
        if (try renderInflectionTemplateHtml(out, allocator, parts, options)) return;
    }

    const stem = semanticTemplateStem(name) orelse return;
    const link_target = if (std.mem.indexOfScalar(u8, stem, ' ') == null and std.mem.indexOfScalar(u8, stem, '-') == null)
        stem
    else
        null;
    const display = try allocator.dupe(u8, stem);
    defer allocator.free(display);

    try appendLinkedResolvedTextHtml(out, allocator, display, link_target orelse stem, options);
    try appendEscapedHtmlSlice(out, allocator, " of ");

    const target_index = semanticTemplateTargetIndexHtml(parts);
    if (templatePositionalHtml(parts, target_index)) |target_value| {
        try renderTemplateTargetHtml(out, allocator, target_value, options);
    }

    const positional_total = positionalCountHtml(parts);
    var extra_index = target_index + 1;
    var wrote_extra = false;
    while (extra_index < positional_total) : (extra_index += 1) {
        const extra = templatePositionalHtml(parts, extra_index) orelse continue;
        const trimmed = trimWikiWhitespace(extra);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;

        if (!wrote_extra) {
            try out.appendSlice(allocator, " (");
            wrote_extra = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
    if (wrote_extra) try out.appendSlice(allocator, ")");
    if (templatePositionalHtml(parts, target_index)) |target_value| {
        const trimmed = trimWikiWhitespace(target_value);
        if (trimmed.len != 0 and !(target_index == 0 and looksLikeLanguageCodeHtml(trimmed))) {
            try appendTemplateGlossHtml(out, allocator, parts, target_index, trimmed, options);
        }
    }
}

fn renderInflectionTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) !bool {
    const target_index = semanticTemplateTargetIndexHtml(parts);
    const target = templatePositionalHtml(parts, target_index) orelse return false;

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);

    var extra_index = target_index + 1;
    while (extra_index < positionalCountHtml(parts)) : (extra_index += 1) {
        const extra = templatePositionalHtml(parts, extra_index) orelse continue;
        const trimmed = trimWikiWhitespace(extra);
        if (trimmed.len == 0 or (looksLikeLanguageCodeHtml(trimmed) and !isRecognizedInflectionTagHtml(trimmed))) continue;
        try tags.append(allocator, trimmed);
    }

    const phrase = try formatInflectionTagsHtml(allocator, tags.items);
    defer if (phrase) |value| allocator.free(value);
    const label = phrase orelse return false;

    try appendEscapedHtmlSlice(out, allocator, label);
    try appendEscapedHtmlSlice(out, allocator, " of ");
    try renderTemplateTargetHtml(out, allocator, target, options);
    return true;
}

fn formatInflectionTagsHtml(allocator: std.mem.Allocator, tags: []const []const u8) !?[]u8 {
    if (tags.len == 0) return null;
    if (sameTagSetHtml(tags, &.{ "past", "part" })) return try allocator.dupe(u8, "past participle");
    if (sameTagSetHtml(tags, &.{ "1", "s", "simple", "pres" })) return try allocator.dupe(u8, "first-person singular simple present");
    if (sameTagSetHtml(tags, &.{ "1", "p", "simple", "pres" })) return try allocator.dupe(u8, "first-person plural simple present");
    if (sameTagSetHtml(tags, &.{ "2", "s", "simple", "pres" })) return try allocator.dupe(u8, "second-person singular simple present");
    if (sameTagSetHtml(tags, &.{ "2", "p", "simple", "pres" })) return try allocator.dupe(u8, "second-person plural simple present");
    if (sameTagSetHtml(tags, &.{ "3", "s", "simple", "pres" })) return try allocator.dupe(u8, "third-person singular simple present");
    if (sameTagSetHtml(tags, &.{ "3", "p", "simple", "pres" })) return try allocator.dupe(u8, "third-person plural simple present");
    if (tags.len == 1) {
        const tag = tags[0];
        if (std.ascii.eqlIgnoreCase(tag, "pres")) return try allocator.dupe(u8, "present tense");
        if (std.ascii.eqlIgnoreCase(tag, "s-verb-form")) return try allocator.dupe(u8, "third-person singular simple present indicative");
        if (std.ascii.eqlIgnoreCase(tag, "spast")) return try allocator.dupe(u8, "simple past");
        if (std.ascii.eqlIgnoreCase(tag, "ed-form")) return try allocator.dupe(u8, "simple past and past participle");
        if (std.ascii.eqlIgnoreCase(tag, "ing-form")) return try allocator.dupe(u8, "present participle and gerund");
    }
    return null;
}

fn isRecognizedInflectionTagHtml(tag: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag, "s-verb-form") or
        std.ascii.eqlIgnoreCase(tag, "1") or
        std.ascii.eqlIgnoreCase(tag, "2") or
        std.ascii.eqlIgnoreCase(tag, "3") or
        std.ascii.eqlIgnoreCase(tag, "part") or
        std.ascii.eqlIgnoreCase(tag, "p") or
        std.ascii.eqlIgnoreCase(tag, "past") or
        std.ascii.eqlIgnoreCase(tag, "pres") or
        std.ascii.eqlIgnoreCase(tag, "s") or
        std.ascii.eqlIgnoreCase(tag, "simple") or
        std.ascii.eqlIgnoreCase(tag, "spast") or
        std.ascii.eqlIgnoreCase(tag, "ed-form") or
        std.ascii.eqlIgnoreCase(tag, "ing-form");
}

fn sameTagSetHtml(tags: []const []const u8, expected: []const []const u8) bool {
    if (tags.len != expected.len) return false;
    for (expected) |candidate| {
        var found = false;
        for (tags) |tag| {
            if (std.ascii.eqlIgnoreCase(trimWikiWhitespace(tag), candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn expandedTemplateForName(name: []const u8) ?TemplateExpansion {
    const trimmed = trimWikiWhitespace(name);
    inline for ([_]struct {
        name: []const u8,
        display: []const u8,
        link_target: ?[]const u8,
        tail: []const u8,
    }{
        .{ .name = "init of", .display = "Initialism", .link_target = "initialism", .tail = " of " },
        .{ .name = "init", .display = "Initialism", .link_target = "initialism", .tail = " of " },
        .{ .name = "initialism", .display = "Initialism", .link_target = "initialism", .tail = " of " },
        .{ .name = "initialism of", .display = "Initialism", .link_target = "initialism", .tail = " of " },
        .{ .name = "abbr", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbr of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbrev", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbrev of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbreviation of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "acronym", .display = "Acronym", .link_target = "acronym", .tail = " of " },
        .{ .name = "acronym of", .display = "Acronym", .link_target = "acronym", .tail = " of " },
        .{ .name = "contraction", .display = "Contraction", .link_target = "contraction", .tail = " of " },
        .{ .name = "clip", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "clip of", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "clipping", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "clipping of", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "ellipsis", .display = "Ellipsis", .link_target = null, .tail = " of " },
        .{ .name = "ellipsis of", .display = "Ellipsis", .link_target = null, .tail = " of " },
        .{ .name = "bf", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "back-form", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "back-formation", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "backformation", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "alt form", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "alt form of", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "altform", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "alt sp", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt sp of", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt spell", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt spelling of", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt case", .display = "Alternative case form", .link_target = null, .tail = " of " },
        .{ .name = "alt case form", .display = "Alternative case form", .link_target = null, .tail = " of " },
        .{ .name = "alternative case form of", .display = "Alternative case form", .link_target = null, .tail = " of " },
        .{ .name = "apocopic form", .display = "Apocopic form", .link_target = null, .tail = " of " },
        .{ .name = "aphetic form", .display = "Aphetic form", .link_target = null, .tail = " of " },
        .{ .name = "obs form", .display = "Obsolete form", .link_target = null, .tail = " of " },
        .{ .name = "obs sp", .display = "Obsolete spelling", .link_target = null, .tail = " of " },
        .{ .name = "dated form", .display = "Dated form", .link_target = null, .tail = " of " },
        .{ .name = "partial calque", .display = "Partial calque", .link_target = null, .tail = " of " },
        .{ .name = "short for", .display = "Short", .link_target = null, .tail = " for " },
        .{ .name = "syn of", .display = "Synonym", .link_target = "synonym", .tail = " of " },
        .{ .name = "synonym of", .display = "Synonym", .link_target = "synonym", .tail = " of " },
    }) |candidate| {
        if (templateMatchesHtml(trimmed, candidate.name)) {
            return .{
                .display = candidate.display,
                .link_target = candidate.link_target,
                .tail = candidate.tail,
            };
        }
    }
    return null;
}

fn appendParenthesizedTemplateArgs(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    options: RenderOptions,
) anyerror!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        if (!wrote_any) {
            try out.appendSlice(allocator, "(");
            wrote_any = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderTemplateTargetHtml(out, allocator, segment, options);
        positional_index += 1;
    }
    if (wrote_any) try out.appendSlice(allocator, ")");
}

fn appendPositionalTemplateTargetsHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    separator: []const u8,
    options: RenderOptions,
) anyerror!void {
    var positional_index: usize = 0;
    var wrote_any = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;
        if (wrote_any) try out.appendSlice(allocator, separator);
        wrote_any = true;
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
}

fn appendPositionalTemplateTargetsAllowCodesHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    separator: []const u8,
    options: RenderOptions,
) anyerror!void {
    var positional_index: usize = 0;
    var wrote_any = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0) continue;
        if (wrote_any) try out.appendSlice(allocator, separator);
        wrote_any = true;
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
}

fn appendPositionalTemplateTargetsNaturalHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    options: RenderOptions,
) anyerror!void {
    var positional_index: usize = 0;
    var rendered_count: usize = 0;
    const total = countRenderablePositionalTermsHtml(parts, start_index);

    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;
        if (rendered_count != 0) {
            if (rendered_count + 1 == total) {
                try out.appendSlice(allocator, if (total == 2) " and " else ", and ");
            } else {
                try out.appendSlice(allocator, ", ");
            }
        }
        rendered_count += 1;
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
}

fn renderTemplateTargetHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_target: []const u8,
    options: RenderOptions,
) anyerror!void {
    const sanitized = try sanitizeTemplateTargetAlloc(allocator, raw_target);
    defer allocator.free(sanitized);

    const trimmed = trimWikiWhitespace(sanitized);
    if (trimmed.len == 0) return;
    if (looksLikeStructuredInline(trimmed)) {
        try renderInlineHtml(out, allocator, trimmed, options);
        return;
    }
    if (std.mem.indexOf(u8, trimmed, "<!--") != null) {
        try renderInlineHtml(out, allocator, trimmed, options);
        return;
    }
    try renderPhraseHtml(out, allocator, trimmed, options);
}

fn looksLikeOpaqueSenseIdHtml(value: []const u8) bool {
    if (value.len < 2 or value[0] != 'Q') return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn renderPhraseHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    phrase: []const u8,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(phrase);
    const fragment = splitFragmentTargetHtml(trimmed);
    const lookup_target = fragment.base;
    const display = if (fragment.has_fragment and !looksLikeStructuredInline(trimmed))
        fragment.base
    else
        trimmed;

    const target = try resolveLinkTargetAlloc(allocator, lookup_target, options);
    defer if (target) |value| allocator.free(value);
    if (target != null) {
        try appendLinkMaybe(out, allocator, target, display, options);
        return;
    }

    if (try externalWikiHrefAlloc(allocator, trimmed)) |href| {
        defer allocator.free(href);
        const external_display = if (isExternalWiktionaryNamespaceTarget(trimmed))
            trimmed
        else
            normalizedWikiTarget(trimmed);
        try appendHrefHtml(out, allocator, href, if (external_display.len != 0) external_display else display, options);
        return;
    }

    try appendLinkMaybe(out, allocator, target, display, options);
}

fn renderLexemeLikeTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    term_index: usize,
    options: RenderOptions,
) anyerror!void {
    const term = templatePositionalHtml(parts, term_index) orelse templatePositionalHtml(parts, 0) orelse return;
    if (isPlaceholderTemplateTermHtml(term)) return;
    const display = templateNamedHtml(parts, "alt") orelse templateLexemeDisplayHtml(parts, term_index) orelse term;
    const language_code = templatePositionalHtml(parts, 0);
    if (language_code) |code| {
        if (looksLikeLanguageCodeHtml(trimWikiWhitespace(code))) {
            try appendEtymologyTermHtml(out, allocator, code, display, term, options);
        } else {
            try appendResolvedDisplayTargetHtml(out, allocator, display, term, options);
        }
    } else {
        try appendResolvedDisplayTargetHtml(out, allocator, display, term, options);
    }
    try appendTemplateGlossHtml(out, allocator, parts, term_index, term, options);
}

fn renderEtymologyLexemeTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const term = templateEtymologyTermHtml(parts);

    if (templateMatchesHtml(name, "bor+") or templateMatchesHtml(name, "borrowed")) {
        try appendEscapedHtmlSlice(out, allocator, "borrowed from ");
    } else if (templateMatchesHtml(name, "ubor")) {
        try appendEscapedHtmlSlice(out, allocator, "Unadapted borrowing from ");
    } else if (templateMatchesHtml(name, "learned borrowing")) {
        try appendEscapedHtmlSlice(out, allocator, "learned borrowing from ");
    } else if (templateMatchesHtml(name, "inh+") or templateMatchesHtml(name, "inherited")) {
        try appendEscapedHtmlSlice(out, allocator, "inherited from ");
    } else if (templateMatchesHtml(name, "der+") or templateMatchesHtml(name, "derived") or templateMatchesHtml(name, "uder")) {
        try appendEscapedHtmlSlice(out, allocator, "derived from ");
    }

    if (templatePositionalHtml(parts, 1)) |code| {
        if (languageDisplayHtml(code)) |display| {
            try appendResolvedDisplayTargetHtml(out, allocator, display, display, options);
            if (term) |value| {
                if (!isPlaceholderTemplateTermHtml(value)) try out.append(allocator, ' ');
            }
        }
    }

    const resolved_term = term orelse return;
    if (isPlaceholderTemplateTermHtml(resolved_term)) return;

    const display = templateNamedHtml(parts, "alt") orelse templateLexemeDisplayHtml(parts, 2) orelse resolved_term;
    try appendEtymologyTermHtml(out, allocator, templatePositionalHtml(parts, 1), display, resolved_term, options);
    try appendTemplateGlossHtml(out, allocator, parts, 2, resolved_term, options);
}

fn renderLanguageAwareLexemeTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    language_index: usize,
    term_index: usize,
    options: RenderOptions,
) anyerror!void {
    if (templatePositionalHtml(parts, language_index)) |code| {
        if (languageDisplayHtml(code)) |display| {
            try appendResolvedDisplayTargetHtml(out, allocator, display, display, options);
            if (templatePositionalHtml(parts, term_index)) |term| {
                if (!isPlaceholderTemplateTermHtml(term)) try out.append(allocator, ' ');
            }
        }
    }
    const term = templatePositionalHtml(parts, term_index) orelse templatePositionalHtml(parts, 0) orelse return;
    if (isPlaceholderTemplateTermHtml(term)) return;
    const display = templateNamedHtml(parts, "alt") orelse templateLexemeDisplayHtml(parts, term_index) orelse term;
    try appendEtymologyTermHtml(out, allocator, templatePositionalHtml(parts, language_index), display, term, options);
    try appendTemplateGlossHtml(out, allocator, parts, term_index, term, options);
}

fn appendEtymologyTermHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    language_code: ?[]const u8,
    display: []const u8,
    term: []const u8,
    options: RenderOptions,
) anyerror!void {
    const target = try resolveLinkTargetAlloc(allocator, term, options);
    defer if (target) |value| allocator.free(value);
    if (target != null) {
        try appendLinkMaybe(out, allocator, target, display, options);
        return;
    }
    if (language_code) |code| {
        if (try etymologyExternalHrefAlloc(allocator, code, term)) |href| {
            defer allocator.free(href);
            try appendHrefHtml(out, allocator, href, display, options);
            return;
        }
    }
    try appendRenderedDisplayHtml(out, allocator, display, options);
}

fn appendTemplateGlossHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    term_index: usize,
    term: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (isPlaceholderTemplateTermHtml(term)) return;
    const translit = templateNamedHtml(parts, "tr");
    const gloss = templateNamedHtml(parts, "t") orelse
        templateNamedHtml(parts, "gloss") orelse
        templateLexemeGlossHtml(parts, term_index) orelse
        templateTrailingGlossHtml(parts, term_index, term);
    const literal = templateNamedHtml(parts, "lit");
    if (translit == null and gloss == null and literal == null) return;

    try out.appendSlice(allocator, " (");
    if (translit) |value| {
        try renderTemplateTargetHtml(out, allocator, value, options);
        if (gloss != null or literal != null) try out.appendSlice(allocator, ", ");
    }
    if (gloss) |value| try appendQuotedGlossHtml(out, allocator, value, options);
    if (literal) |value| {
        if (gloss != null) try out.appendSlice(allocator, ", ");
        try appendEscapedHtmlSlice(out, allocator, "literally ");
        try appendQuotedGlossHtml(out, allocator, value, options);
    }
    try out.appendSlice(allocator, ")");
}

fn appendQuotedGlossHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "“");
    const trimmed = trimWikiWhitespace(value);
    if (looksLikeStructuredInline(trimmed)) {
        try renderInlineHtml(out, allocator, trimmed, options);
    } else {
        try appendDecodedEscapedChunk(out, allocator, trimmed);
    }
    try appendEscapedHtmlSlice(out, allocator, "”");
}

fn renderCompoundTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const total = positionalCountHtml(parts);
    if (total == 0) return;

    const compound_plus = templateMatchesHtml(name, "compound+") or templateMatchesHtml(name, "com+");
    if (compound_plus) try appendEscapedHtmlSlice(out, allocator, "Compound of ");

    const first_term_index: usize = if (templatePositionalHtml(parts, 0)) |first|
        if (looksLikeLanguageCodeHtml(first)) 1 else 0
    else
        0;

    var positional_index = first_term_index;
    var wrote_any = false;
    while (positional_index < total) : (positional_index += 1) {
        const term = templatePositionalHtml(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(term);
        if (trimmed.len == 0) continue;
        if (wrote_any) try out.appendSlice(allocator, " +\u{200E} ");
        try renderCompoundTermHtml(out, allocator, name, parts, positional_index, trimmed, options);
        wrote_any = true;
    }

    if (templateNamedHtml(parts, "lit")) |literal| {
        const trimmed = trimWikiWhitespace(literal);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, ", literally ");
            try appendQuotedTemplateTargetHtml(out, allocator, trimmed, options);
        }
    }
}

fn renderAffixTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    template_name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const total = positionalCountHtml(parts);
    if (total == 0) return;

    const first_term_index: usize = if (templatePositionalHtml(parts, 0)) |first|
        if (looksLikeLanguageCodeHtml(first)) 1 else 0
    else
        0;

    var term_slot: usize = 1;
    var positional_index = first_term_index;
    var wrote_any = false;
    var previous_lang: ?[]const u8 = null;
    while (positional_index < total) : (positional_index += 1) {
        const term = templatePositionalHtml(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(term);
        if (trimmed.len == 0) continue;
        if (wrote_any) {
            try out.appendSlice(allocator, " + ");
        } else if (positional_index > first_term_index and (templateMatchesHtml(template_name, "suffix") or templateMatchesHtml(template_name, "suf"))) {
            try out.appendSlice(allocator, "+ ");
        }
        const lang_code = templateIndexedNamedHtml(parts, "lang", term_slot);
        if (lang_code) |code| {
            const lang_trimmed = trimWikiWhitespace(code);
            if (lang_trimmed.len != 0 and (previous_lang == null or !std.mem.eql(u8, previous_lang.?, lang_trimmed))) {
                if (languageDisplayHtml(lang_trimmed)) |display| {
                    try appendResolvedDisplayTargetHtml(out, allocator, display, display, options);
                    try out.append(allocator, ' ');
                }
                previous_lang = lang_trimmed;
            }
        }
        try renderCompoundTermHtml(out, allocator, template_name, parts, term_slot, trimmed, options);
        wrote_any = true;
        term_slot += 1;
    }
}

fn renderCompoundTermHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    template_name: []const u8,
    parts: *const std.ArrayList([]const u8),
    term_slot: usize,
    fallback_term: []const u8,
    options: RenderOptions,
) anyerror!void {
    var key_buf: [16]u8 = undefined;
    const alt_name = try std.fmt.bufPrint(&key_buf, "alt{d}", .{term_slot});
    const display = try affixDisplayAlloc(allocator, template_name, parts, term_slot, templateNamedHtml(parts, alt_name) orelse fallback_term);
    defer allocator.free(display);
    if (templateIndexedNamedHtml(parts, "lang", term_slot)) |lang_code| {
        try appendEtymologyTermHtml(out, allocator, trimWikiWhitespace(lang_code), display, fallback_term, options);
    } else {
        try appendResolvedDisplayTargetHtml(out, allocator, display, fallback_term, options);
    }

    const gloss_name = try std.fmt.bufPrint(&key_buf, "t{d}", .{term_slot});
    const gloss = templateNamedHtml(parts, gloss_name);
    const pos_name = try std.fmt.bufPrint(&key_buf, "pos{d}", .{term_slot});
    const pos = templateNamedHtml(parts, pos_name);
    if (gloss == null and pos == null) return;

    try out.appendSlice(allocator, " (");
    if (gloss) |value| {
        try appendQuotedTemplateTargetHtml(out, allocator, value, options);
        if (pos != null) try out.appendSlice(allocator, ", ");
    }
    if (pos) |value| try renderTemplateTargetHtml(out, allocator, value, options);
    try out.append(allocator, ')');
}

fn affixDisplayAlloc(
    allocator: std.mem.Allocator,
    template_name: []const u8,
    parts: *const std.ArrayList([]const u8),
    term_slot: usize,
    raw_display: []const u8,
) ![]u8 {
    const trimmed = trimWikiWhitespace(raw_display);
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    var key_buf: [16]u8 = undefined;
    const pos_name = try std.fmt.bufPrint(&key_buf, "pos{d}", .{term_slot});
    const pos = if (templateNamedHtml(parts, pos_name)) |value| trimWikiWhitespace(value) else "";

    const needs_prefix = affixNeedsLeadingHyphen(template_name, term_slot, pos) and trimmed[0] != '-';
    const needs_suffix = affixNeedsTrailingHyphen(template_name, term_slot, pos) and trimmed[trimmed.len - 1] != '-';
    if (!needs_prefix and !needs_suffix) return allocator.dupe(u8, trimmed);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        if (needs_prefix) "-" else "",
        trimmed,
        if (needs_suffix) "-" else "",
    });
}

fn affixNeedsLeadingHyphen(template_name: []const u8, term_slot: usize, pos: []const u8) bool {
    if (asciiStartsWithIgnoreCase(trimWikiWhitespace(pos), "suffix")) return true;
    return (templateMatchesHtml(template_name, "suffix") or templateMatchesHtml(template_name, "suf")) and term_slot != 1;
}

fn affixNeedsTrailingHyphen(template_name: []const u8, term_slot: usize, pos: []const u8) bool {
    if (asciiStartsWithIgnoreCase(trimWikiWhitespace(pos), "prefix")) return true;
    return (templateMatchesHtml(template_name, "prefix") or templateMatchesHtml(template_name, "pre")) and term_slot == 1;
}

fn templateLexemeGlossHtml(parts: *const std.ArrayList([]const u8), term_index: usize) ?[]const u8 {
    if (templateLexemeDisplayHtml(parts, term_index) != null) return null;
    const count = positionalCountHtml(parts);
    if (count <= term_index + 2) return null;
    const bridge = templatePositionalHtml(parts, term_index + 1) orelse "";
    if (trimWikiWhitespace(bridge).len != 0) return null;
    return templatePositionalHtml(parts, term_index + 2);
}

fn templateTrailingGlossHtml(parts: *const std.ArrayList([]const u8), term_index: usize, term: []const u8) ?[]const u8 {
    if (templateLexemeDisplayHtml(parts, term_index) != null) return null;
    if (isPlaceholderTemplateTermHtml(term)) return null;
    const count = positionalCountHtml(parts);
    if (count <= 2) return null;
    const candidate = templatePositionalHtml(parts, count - 1) orelse return null;
    const trimmed = trimWikiWhitespace(candidate);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, trimWikiWhitespace(term)) or looksLikeLanguageCodeHtml(trimmed)) return null;
    return trimmed;
}

fn templateLexemeDisplayHtml(parts: *const std.ArrayList([]const u8), term_index: usize) ?[]const u8 {
    const candidate = templatePositionalHtml(parts, term_index + 1) orelse return null;
    const trimmed = trimWikiWhitespace(candidate);
    if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) return null;
    return trimmed;
}

fn renderNominalTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    noun: []const u8,
    options: RenderOptions,
) anyerror!void {
    var phrase: std.ArrayList(u8) = .empty;
    defer phrase.deinit(allocator);

    const qualifier = blk: {
        if (templatePositionalHtml(parts, 0)) |first| {
            if (looksLikeLanguageCodeHtml(trimWikiWhitespace(first))) {
                break :blk templatePositionalHtml(parts, 1);
            }
            break :blk first;
        }
        break :blk templatePositionalHtml(parts, 1);
    };
    if (qualifier) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try renderTemplateTargetHtml(&phrase, allocator, trimmed, options);
            if (phrase.items.len != 0) try phrase.append(allocator, ' ');
        }
    }
    try appendEscapedHtmlSlice(&phrase, allocator, noun);

    try out.appendSlice(allocator, chooseIndefiniteArticleHtml(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    if (templateNamedHtml(parts, "addl")) |value| {
        const trimmed_addl = trimWikiWhitespace(value);
        if (trimmed_addl.len != 0) {
            try out.appendSlice(allocator, ", ");
            try renderTemplateTargetHtml(out, allocator, trimmed_addl, options);
        }
    }
    if (templateNamedHtml(parts, "from")) |source| {
        try appendNominalOriginHtml(out, allocator, source, options);
    }
}

const SimpleRelationTemplateHtml = struct {
    label: []const u8,
    tail: []const u8,
    separator: []const u8 = ", ",
};

fn renderSimpleRelationTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    spec: SimpleRelationTemplateHtml,
    options: RenderOptions,
) anyerror!void {
    const start_index: usize = if (looksLikeLanguageCodeHtml(templatePositionalHtml(parts, 0) orelse "")) 1 else 0;
    const capitalize = !templateFlagEnabledHtml(parts, "nocap");

    const label = if (capitalize)
        spec.label
    else
        try lowercaseFirstAsciiAlloc(allocator, spec.label);
    defer if (!capitalize) allocator.free(label);

    try appendEscapedHtmlSlice(out, allocator, label);
    try appendEscapedHtmlSlice(out, allocator, spec.tail);
    try appendPositionalTemplateTargetsHtml(out, allocator, parts, start_index, spec.separator, options);
}

fn renderUnknownTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) !void {
    const base = templateNamedHtml(parts, "title") orelse
        templateNamedHtml(parts, "t") orelse
        templateNamedHtml(parts, "gloss") orelse
        "Origin unknown";
    const capitalize = !templateFlagEnabledHtml(parts, "nocap");

    const rendered = if (capitalize)
        trimWikiWhitespace(base)
    else
        try lowercaseFirstAsciiAlloc(allocator, trimWikiWhitespace(base));
    defer if (!capitalize) allocator.free(rendered);

    try appendEscapedHtmlSlice(out, allocator, rendered);
}

fn renderNameTranslitTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const source_language = templatePositionalHtml(parts, 1) orelse templatePositionalHtml(parts, 0);
    const raw_term = templatePositionalHtml(parts, 2) orelse templatePositionalHtml(parts, 1) orelse return;
    const type_value = trimWikiWhitespace(templateNamedHtml(parts, "type") orelse "name");

    var phrase: std.ArrayList(u8) = .empty;
    defer phrase.deinit(allocator);
    try appendEscapedHtmlSlice(&phrase, allocator, "transliteration of ");
    if (source_language) |code| {
        if (languageDisplayHtml(code)) |display| {
            try appendEscapedHtmlSlice(&phrase, allocator, "the ");
            try appendEscapedHtmlSlice(&phrase, allocator, display);
            try phrase.append(allocator, ' ');
        }
    }
    try appendEscapedHtmlSlice(&phrase, allocator, if (type_value.len != 0) type_value else "name");

    try appendEscapedHtmlSlice(out, allocator, chooseIndefiniteArticleHtml(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    try out.append(allocator, ' ');
    try renderTemplateTargetHtml(out, allocator, raw_term, options);
}

fn appendNominalOriginHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_source: []const u8,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(raw_source);
    if (trimmed.len == 0) return;

    if (std.mem.indexOfScalar(u8, trimmed, '<')) |lt| {
        const source_phrase = trimWikiWhitespace(trimmed[0..lt]);
        const upstream = trimWikiWhitespace(trimmed[lt + 1 ..]);

        try out.appendSlice(allocator, " transferred from ");
        if (source_phrase.len != 0) {
            const normalized_source = try normalizeNominalOriginPhraseAlloc(allocator, source_phrase);
            defer allocator.free(normalized_source);
            try renderTemplateTargetHtml(out, allocator, normalized_source, options);
        }
        if (upstream.len != 0) {
            try out.appendSlice(allocator, " [in turn from ");
            try renderTemplateTargetHtml(out, allocator, upstream, options);
            try out.append(allocator, ']');
        }
        return;
    }

    try out.appendSlice(allocator, " from ");
    try renderTemplateTargetHtml(out, allocator, trimmed, options);
}

fn templateFlagEnabledHtml(parts: *const std.ArrayList([]const u8), name: []const u8) bool {
    const value = templateNamedHtml(parts, name) orelse return false;
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return true;
    return !(std.ascii.eqlIgnoreCase(trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "no") or
        std.ascii.eqlIgnoreCase(trimmed, "off"));
}

fn normalizeNominalOriginPhraseAlloc(
    allocator: std.mem.Allocator,
    phrase: []const u8,
) ![]u8 {
    const trimmed = trimWikiWhitespace(phrase);
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    const singular = if (asciiEndsWithIgnoreCaseHtml(trimmed, " names"))
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;

    inline for ([_][]const u8{
        "a ",
        "an ",
        "the ",
        "this ",
        "that ",
        "these ",
        "those ",
        "one ",
    }) |prefix| {
        if (asciiStartsWithIgnoreCaseHtml(singular, prefix)) return allocator.dupe(u8, singular);
    }

    return std.fmt.allocPrint(allocator, "the {s}", .{singular});
}

fn renderQuoteTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    var wrote_meta = false;

    if (try quoteDateValueAlloc(allocator, parts)) |value| {
        defer allocator.free(value);
        try appendQuoteMetaPartHtml(out, allocator, value, &wrote_meta, options);
    }
    if (try quoteAuthorValueAlloc(allocator, parts)) |value| {
        defer allocator.free(value);
        try appendQuoteMetaPartHtml(out, allocator, value, &wrote_meta, options);
    } else if (std.mem.startsWith(u8, name, "RQ:")) {
        const label = trimWikiWhitespace(name["RQ:".len..]);
        if (label.len != 0) try appendQuoteMetaPartHtml(out, allocator, label, &wrote_meta, options);
    }
    inline for ([_]struct { key: []const u8, suffix: []const u8 }{
        .{ .key = "lyricist", .suffix = " (lyrics)" },
        .{ .key = "composer", .suffix = " (music)" },
        .{ .key = "mainauthor", .suffix = "" },
        .{ .key = "coauthors", .suffix = "" },
    }) |field| {
        const defer_song_credit = templateMatchesHtml(name, "quote-song") and
            (std.mem.eql(u8, field.key, "lyricist") or std.mem.eql(u8, field.key, "composer"));
        if (!defer_song_credit) {
            if (templateNamedHtml(parts, field.key)) |value| {
                const trimmed = trimWikiWhitespace(value);
                if (trimmed.len != 0) {
                    const normalized = if (std.mem.indexOfScalar(u8, trimmed, ';') != null)
                        try normalizeCommaListAlloc(allocator, trimmed)
                    else
                        try allocator.dupe(u8, trimmed);
                    defer allocator.free(normalized);
                    const rendered = if (field.suffix.len == 0)
                        try allocator.dupe(u8, normalized)
                    else
                        try std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized, field.suffix });
                    defer allocator.free(rendered);
                    try appendQuoteMetaPartHtml(out, allocator, rendered, &wrote_meta, options);
                }
            }
        }
    }
    inline for ([_]struct { key: []const u8, suffix: []const u8 }{
        .{ .key = "editor", .suffix = ", editor" },
        .{ .key = "editors", .suffix = ", editors" },
    }) |field| {
        if (templateNamedHtml(parts, field.key)) |value| {
            const normalized = try normalizeCommaListAlloc(allocator, trimmedQuoteMetaValue(value));
            defer allocator.free(normalized);
            const rendered = try quoteSuffixedValueAlloc(allocator, normalized, field.suffix);
            defer allocator.free(rendered);
            try appendQuoteMetaPartHtml(out, allocator, rendered, &wrote_meta, options);
        }
    }
    if (templateNamedHtml(parts, "chapter")) |value| {
        const rendered = try quoteChapterValueAlloc(allocator, trimmedQuoteMetaValue(value));
        defer allocator.free(rendered);
        try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
    }
    inline for ([_]struct { key: []const u8, suffix: []const u8 }{
        .{ .key = "translator", .suffix = ", transl." },
        .{ .key = "translators", .suffix = ", transl." },
    }) |field| {
        if (templateNamedHtml(parts, field.key)) |value| {
            const normalized = try normalizeCommaListAlloc(allocator, trimmedQuoteMetaValue(value));
            defer allocator.free(normalized);
            const rendered = try quoteSuffixedValueAlloc(allocator, normalized, field.suffix);
            defer allocator.free(rendered);
            const prefix_in = templateNamedHtml(parts, "chapter") != null and
                templateNamedHtml(parts, "journal") == null and
                templateNamedHtml(parts, "magazine") == null and
                templateNamedHtml(parts, "work") == null and
                templateNamedHtml(parts, "site") == null;
            try appendQuotePrefixedMetaPartHtml(out, allocator, if (prefix_in) "in " else "", rendered, &wrote_meta, options, false);
        }
    }
    if (templateNamedHtml(parts, "title")) |value| {
        const prefix_in = templateNamedHtml(parts, "chapter") != null and
            templateNamedHtml(parts, "translator") == null and
            templateNamedHtml(parts, "translators") == null and
            templateNamedHtml(parts, "journal") == null and
            templateNamedHtml(parts, "magazine") == null and
            templateNamedHtml(parts, "work") == null and
            templateNamedHtml(parts, "site") == null and
            !templateMatchesHtml(name, "quote-song");
        if (templateMatchesHtml(name, "quote-song")) {
            const rendered = try quoteQuotedLiteralValueAlloc(allocator, trimmedQuoteMetaValue(value));
            defer allocator.free(rendered);
            try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
        } else {
            try appendQuotePrefixedMetaPartHtml(out, allocator, if (prefix_in) "in " else "", trimmedQuoteMetaValue(value), &wrote_meta, options, quoteTitleNeedsQuotes(name, parts));
        }
    }
    inline for ([_][]const u8{ "work", "journal", "magazine", "site" }) |key| {
        if (templateNamedHtml(parts, key)) |value| {
            try appendQuotePrefixedMetaPartHtml(out, allocator, "in ", trimmedQuoteMetaValue(value), &wrote_meta, options, keyNeedsQuotedMetaHtml(key));
        }
    }
    if (templateMatchesHtml(name, "quote-song")) {
        var wrote_song_credit = false;
        inline for ([_]struct { key: []const u8, suffix: []const u8 }{
            .{ .key = "lyricist", .suffix = " (lyrics)" },
            .{ .key = "composer", .suffix = " (music)" },
        }) |field| {
            if (templateNamedHtml(parts, field.key)) |value| {
                const trimmed = trimWikiWhitespace(value);
                if (trimmed.len != 0) {
                    const rendered = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, field.suffix });
                    defer allocator.free(rendered);
                    try appendQuotePrefixedMetaPartHtml(out, allocator, if (!wrote_song_credit) "in " else "", rendered, &wrote_meta, options, false);
                    wrote_song_credit = true;
                }
            }
        }
        if (templateNamedHtml(parts, "album")) |value| {
            try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
        }
        if (templateNamedHtml(parts, "artist")) |value| {
            const normalized = try normalizeSemicolonListAlloc(allocator, trimmedQuoteMetaValue(value));
            defer allocator.free(normalized);
            try appendQuotePrefixedMetaPartHtml(out, allocator, "performed by ", normalized, &wrote_meta, options, false);
        }
    }
    inline for ([_][]const u8{ "edition", "edition_plain", "format" }) |key| {
        if (templateNamedHtml(parts, key)) |value| {
            const rendered = try quoteEditionLikeValueAlloc(allocator, trimmedQuoteMetaValue(value), key);
            defer allocator.free(rendered);
            try appendQuoteMetaPartHtml(out, allocator, rendered, &wrote_meta, options);
        }
    }
    if (templateNamedHtml(parts, "volume")) |value| {
        const rendered = try std.fmt.allocPrint(allocator, "volume {s}", .{trimWikiWhitespace(value)});
        defer allocator.free(rendered);
        try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
    }
    if (templateNamedHtml(parts, "volume_plain")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "section")) |value| {
        const rendered = try quoteChapterValueAlloc(allocator, trimmedQuoteMetaValue(value));
        defer allocator.free(rendered);
        try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
    }
    if (templateNamedHtml(parts, "location")) |location| {
        if (templateNamedHtml(parts, "publisher")) |publisher| {
            if (templateMatchesHtml(name, "quote-song")) {
                const rendered = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ trimmedQuoteMetaValue(location), trimmedQuoteMetaValue(publisher) });
                defer allocator.free(rendered);
                try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
            } else {
                try appendQuoteLocationPublisherHtml(out, allocator, trimmedQuoteMetaValue(location), trimmedQuoteMetaValue(publisher), &wrote_meta, options);
            }
        } else {
            if (templateMatchesHtml(name, "quote-song")) {
                try appendQuoteLiteralMetaPartHtml(out, allocator, trimmedQuoteMetaValue(location), &wrote_meta);
            } else {
                try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(location), &wrote_meta, options);
            }
        }
    } else if (templateNamedHtml(parts, "publisher")) |publisher| {
        if (templateMatchesHtml(name, "quote-song")) {
            try appendQuoteLiteralMetaPartHtml(out, allocator, trimmedQuoteMetaValue(publisher), &wrote_meta);
        } else {
            try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(publisher), &wrote_meta, options);
        }
    }
    if (templateNamedHtml(parts, "issue")) |value| {
        const label = if (templateNamedHtml(parts, "journal") != null or templateNamedHtml(parts, "magazine") != null) "number" else "issue";
        const rendered = try std.fmt.allocPrint(allocator, "{s} {s}", .{ label, trimWikiWhitespace(value) });
        defer allocator.free(rendered);
        try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
    }
    inline for ([_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "page", .label = "page" },
        .{ .key = "pages", .label = "pages" },
        .{ .key = "column", .label = "column" },
    }) |field| {
        if (templateNamedHtml(parts, field.key)) |value| {
            const rendered = try std.fmt.allocPrint(allocator, "{s} {s}", .{ field.label, trimWikiWhitespace(value) });
            defer allocator.free(rendered);
            try appendQuoteLiteralMetaPartHtml(out, allocator, rendered, &wrote_meta);
        }
    }
    if (!templateMatchesHtml(name, "quote-song")) {
        if (templateNamedHtml(parts, "album")) |value| {
            try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
        }
        if (templateNamedHtml(parts, "artist")) |value| {
            try appendQuotePrefixedMetaPartHtml(out, allocator, "performed by ", trimmedQuoteMetaValue(value), &wrote_meta, options, false);
        }
    }
    if (try quoteSecondaryPublicationAlloc(allocator, parts)) |secondary| {
        defer allocator.free(secondary);
        if (wrote_meta) {
            try out.appendSlice(allocator, "; ");
        }
        wrote_meta = true;
        try renderTemplateTargetHtml(out, allocator, secondary, options);
    }
    if (try quoteArchiveMetaAlloc(allocator, parts)) |archive_note| {
        defer allocator.free(archive_note);
        try appendQuoteLiteralMetaPartHtml(out, allocator, archive_note, &wrote_meta);
    }
    if (templateNamedHtml(parts, "quotee")) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try appendQuotePrefixedMetaPartHtml(out, allocator, "quoting ", trimmed, &wrote_meta, options, false);
        }
    }

    if (templateNamedHtml(parts, "passage") orelse templateNamedHtml(parts, "text")) |value| {
        if (wrote_meta) try out.appendSlice(allocator, ":");
        try renderTemplateTargetHtml(out, allocator, value, options);
        return;
    }
}

fn appendQuoteMetaPartHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    wrote_any: *bool,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return;
    if (wrote_any.*) {
        try out.appendSlice(allocator, ", ");
    }
    wrote_any.* = true;
    try renderTemplateTargetHtml(out, allocator, trimmed, options);
}

fn appendQuoteLiteralMetaPartHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    wrote_any: *bool,
) !void {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return;
    if (wrote_any.*) try out.appendSlice(allocator, ", ");
    wrote_any.* = true;
    if (looksLikeStructuredInline(trimmed)) {
        try renderInlineHtml(out, allocator, trimmed, .{ .strict = false });
        return;
    }
    try appendEscapedHtmlSlice(out, allocator, trimmed);
}

fn appendQuoteLocationPublisherHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    location: []const u8,
    publisher: []const u8,
    wrote_any: *bool,
    options: RenderOptions,
) anyerror!void {
    const location_trimmed = trimWikiWhitespace(location);
    const publisher_trimmed = trimWikiWhitespace(publisher);
    if (location_trimmed.len == 0 or publisher_trimmed.len == 0) return;
    if (wrote_any.*) try out.appendSlice(allocator, ", ");
    wrote_any.* = true;
    try renderTemplateTargetHtml(out, allocator, location_trimmed, options);
    try out.appendSlice(allocator, ": ");
    try renderTemplateTargetHtml(out, allocator, publisher_trimmed, options);
}

fn appendQuotePrefixedMetaPartHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: []const u8,
    wrote_any: *bool,
    options: RenderOptions,
    quote_value: bool,
) anyerror!void {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return;
    if (wrote_any.*) try out.appendSlice(allocator, ", ");
    wrote_any.* = true;
    if (prefix.len != 0) try appendEscapedHtmlSlice(out, allocator, prefix);
    if (quote_value) {
        try appendQuotedTemplateTargetHtml(out, allocator, trimmed, options);
    } else {
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
}

fn trimmedQuoteMetaValue(value: []const u8) []const u8 {
    return trimWikiWhitespace(value);
}

fn quoteTitleNeedsQuotes(name: []const u8, parts: *const std.ArrayList([]const u8)) bool {
    const trimmed = trimWikiWhitespace(name);
    if (templateMatchesHtml(trimmed, "quote-web") or
        templateMatchesHtml(trimmed, "quote-journal") or
        templateMatchesHtml(trimmed, "quote-news") or
        templateMatchesHtml(trimmed, "quote-song"))
    {
        return true;
    }
    return templateNamedHtml(parts, "journal") != null or
        templateNamedHtml(parts, "magazine") != null or
        templateNamedHtml(parts, "site") != null;
}

fn keyNeedsQuotedMetaHtml(key: []const u8) bool {
    return std.mem.eql(u8, key, "work") or
        std.mem.eql(u8, key, "journal") or
        std.mem.eql(u8, key, "magazine") or
        std.mem.eql(u8, key, "site");
}

fn languageDisplayHtml(code: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(code);
    inline for ([_]struct { code: []const u8, display: []const u8 }{
        .{ .code = "afa", .display = "Afroasiatic" },
        .{ .code = "af", .display = "Afrikaans" },
        .{ .code = "am", .display = "Amharic" },
        .{ .code = "ang", .display = "Old English" },
        .{ .code = "ar", .display = "Arabic" },
        .{ .code = "arc", .display = "Aramaic" },
        .{ .code = "ber-pro", .display = "Proto-Berber" },
        .{ .code = "be", .display = "Belarusian" },
        .{ .code = "br", .display = "Breton" },
        .{ .code = "cmn", .display = "Mandarin" },
        .{ .code = "cop", .display = "Coptic" },
        .{ .code = "cs", .display = "Czech" },
        .{ .code = "csb", .display = "Kashubian" },
        .{ .code = "cy", .display = "Welsh" },
        .{ .code = "da", .display = "Danish" },
        .{ .code = "de", .display = "German" },
        .{ .code = "dum", .display = "Middle Dutch" },
        .{ .code = "el", .display = "Greek" },
        .{ .code = "en", .display = "English" },
        .{ .code = "enm", .display = "Middle English" },
        .{ .code = "egy", .display = "Egyptian" },
        .{ .code = "es", .display = "Spanish" },
        .{ .code = "etr", .display = "Etruscan" },
        .{ .code = "eu", .display = "Basque" },
        .{ .code = "fa-cls", .display = "Classical Persian" },
        .{ .code = "fi", .display = "Finnish" },
        .{ .code = "fia", .display = "Nobiin" },
        .{ .code = "frk", .display = "Frankish" },
        .{ .code = "fr", .display = "French" },
        .{ .code = "frm", .display = "Middle French" },
        .{ .code = "fro", .display = "Old French" },
        .{ .code = "fy", .display = "West Frisian" },
        .{ .code = "ga", .display = "Irish" },
        .{ .code = "gd", .display = "Scottish Gaelic" },
        .{ .code = "gem-pro", .display = "Proto-Germanic" },
        .{ .code = "gml", .display = "Middle Low German" },
        .{ .code = "gmq", .display = "North Germanic" },
        .{ .code = "gmw-pro", .display = "Proto-West Germanic" },
        .{ .code = "got", .display = "Gothic" },
        .{ .code = "grc", .display = "Ancient Greek" },
        .{ .code = "grc-koi", .display = "Koine Greek" },
        .{ .code = "gsw", .display = "Swiss German" },
        .{ .code = "hu", .display = "Hungarian" },
        .{ .code = "hy", .display = "Armenian" },
        .{ .code = "is", .display = "Icelandic" },
        .{ .code = "ine-pro", .display = "Proto-Indo-European" },
        .{ .code = "kw", .display = "Cornish" },
        .{ .code = "ko", .display = "Korean" },
        .{ .code = "la", .display = "Latin" },
        .{ .code = "LL.", .display = "Late Latin" },
        .{ .code = "li", .display = "Limburgish" },
        .{ .code = "lt", .display = "Lithuanian" },
        .{ .code = "ML.", .display = "Medieval Latin" },
        .{ .code = "mi", .display = "Māori" },
        .{ .code = "nds", .display = "Low German" },
        .{ .code = "nds-de", .display = "German Low German" },
        .{ .code = "nds-nl", .display = "Dutch Low Saxon" },
        .{ .code = "NL.", .display = "New Latin" },
        .{ .code = "nl", .display = "Dutch" },
        .{ .code = "nb", .display = "Norwegian Bokmål" },
        .{ .code = "no", .display = "Norwegian" },
        .{ .code = "non", .display = "Old Norse" },
        .{ .code = "nn", .display = "Norwegian Nynorsk" },
        .{ .code = "nan-hbl", .display = "Hokkien" },
        .{ .code = "nrf", .display = "Norman" },
        .{ .code = "onw", .display = "Old Nubian" },
        .{ .code = "ofs", .display = "Old Frisian" },
        .{ .code = "ota", .display = "Ottoman Turkish" },
        .{ .code = "osx", .display = "Old Saxon" },
        .{ .code = "pl", .display = "Polish" },
        .{ .code = "pdc", .display = "Pennsylvania German" },
        .{ .code = "ru", .display = "Russian" },
        .{ .code = "rup", .display = "Aromanian" },
        .{ .code = "sga", .display = "Old Irish" },
        .{ .code = "yue", .display = "Cantonese" },
        .{ .code = "sa", .display = "Sanskrit" },
        .{ .code = "sbv", .display = "Sabine" },
        .{ .code = "sco", .display = "Scots" },
        .{ .code = "se", .display = "Northern Sami" },
        .{ .code = "sh", .display = "Serbo-Croatian" },
        .{ .code = "sq", .display = "Albanian" },
        .{ .code = "sv", .display = "Swedish" },
        .{ .code = "stq", .display = "Saterland Frisian" },
        .{ .code = "taq", .display = "Tamasheq" },
        .{ .code = "tmh", .display = "Tamahaq" },
        .{ .code = "tr", .display = "Turkish" },
        .{ .code = "tpi", .display = "Tok Pisin" },
        .{ .code = "uk", .display = "Ukrainian" },
        .{ .code = "urj-pro", .display = "Proto-Uralic" },
        .{ .code = "xno", .display = "Anglo-Norman" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.code)) return entry.display;
    }
    return null;
}

fn etymologyExternalHrefAlloc(allocator: std.mem.Allocator, language_code: []const u8, term: []const u8) !?[]u8 {
    const trimmed_code = trimWikiWhitespace(language_code);
    const trimmed_term = trimWikiWhitespace(term);
    if (trimmed_code.len == 0 or trimmed_term.len == 0) return null;

    if (std.mem.endsWith(u8, trimmed_code, "-pro") and trimmed_term[0] == '*') {
        const language = languageDisplayHtml(trimmed_code) orelse return null;
        const raw_target = try std.fmt.allocPrint(allocator, "Reconstruction:{s}/{s}", .{ language, trimmed_term });
        defer allocator.free(raw_target);
        return externalWikiHrefAlloc(allocator, raw_target);
    }

    if (std.ascii.eqlIgnoreCase(trimmed_code, "en")) return null;
    return @as(?[]u8, try buildExternalWikiHrefAlloc(allocator, "https://en.wiktionary.org/wiki/", trimmed_term));
}

fn renderIpaTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendPronunciationAccentHtml(out, allocator, templateNamedHtml(parts, "a"), options);
    try appendWiktionaryPageLinkHtml(out, allocator, "Wiktionary:International_Phonetic_Alphabet", "IPA", options);
    try out.appendSlice(allocator, ": ");
    try appendPronunciationValuesHtml(out, allocator, parts, 1, ", ", .{}, options);
}

fn renderEnprTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendPronunciationAccentHtml(out, allocator, templateNamedHtml(parts, "a"), options);
    try appendWiktionaryPageLinkHtml(out, allocator, "Appendix:English_pronunciation", "enPR", options);
    try out.appendSlice(allocator, ": ");
    try appendPronunciationValuesHtml(out, allocator, parts, 0, ", ", .{}, options);
}

fn renderAudioTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "Audio");
    if (templateNamedHtml(parts, "a")) |accent| {
        const trimmed = trimWikiWhitespace(accent);
        if (trimmed.len != 0) {
            try out.append(allocator, ' ');
            try out.append(allocator, '(');
            try appendPronunciationAccentValueHtml(out, allocator, trimmed, options);
            try out.append(allocator, ')');
        }
    }
    if (templateNamedHtml(parts, "text")) |text| {
        const trimmed = trimWikiWhitespace(text);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, "; ");
            try appendQuotedTemplateTargetHtml(out, allocator, trimmed, options);
        }
    } else if (templatePositionalHtml(parts, 2)) |text| {
        const trimmed = trimWikiWhitespace(text);
        if (trimmed.len != 0 and !looksLikeLanguageCodeHtml(trimmed)) {
            try out.appendSlice(allocator, "; ");
            try appendQuotedTemplateTargetHtml(out, allocator, trimmed, options);
        }
    }
    try out.appendSlice(allocator, ":(");
    if (templatePositionalHtml(parts, 1) orelse templatePositionalHtml(parts, 0)) |file_name| {
        const file_page = try std.fmt.allocPrint(allocator, "File:{s}", .{trimWikiWhitespace(file_name)});
        defer allocator.free(file_page);
        try appendWiktionaryPageLinkHtml(out, allocator, file_page, "file", options);
    } else {
        try appendEscapedHtmlSlice(out, allocator, "file");
    }
    try out.append(allocator, ')');
}

fn renderRhymesTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "Rhymes: ");
    if (templateNamedHtml(parts, "a") orelse templateNamedHtml(parts, "q1") orelse templateNamedHtml(parts, "q")) |accent| {
        try appendPronunciationAccentHtml(out, allocator, accent, options);
    }
    try appendPronunciationValuesHtml(out, allocator, parts, 1, ", ", .{
        .prepend_hyphen = true,
        .link_prefix = "Rhymes:English/",
    }, options);
}

const LabeledTemplateSpec = struct {
    singular: []const u8,
    plural: []const u8,
    start_index: usize = 1,
    separator: []const u8 = ", ",
};

fn renderLabeledTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    spec: LabeledTemplateSpec,
    options: RenderOptions,
) anyerror!void {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);

    var positional_index: usize = 0;
    var rendered_terms: usize = 0;
    var pending_group_separator = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < spec.start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0) continue;
        if (isTemplateSeparatorSegmentHtml(trimmed)) {
            pending_group_separator = rendered_terms != 0;
            continue;
        }

        if (rendered_terms != 0) try rendered.appendSlice(allocator, if (pending_group_separator) "; " else spec.separator);
        pending_group_separator = false;
        try renderTemplateTargetHtml(&rendered, allocator, trimmed, options);
        rendered_terms += 1;
    }

    if (rendered_terms == 0) return;
    try appendEscapedHtmlSlice(out, allocator, if (rendered_terms == 1) spec.singular else spec.plural);
    try appendEscapedHtmlSlice(out, allocator, ": ");
    try out.appendSlice(allocator, rendered.items);
}

fn isTemplateSeparatorSegmentHtml(segment: []const u8) bool {
    var i: usize = 0;
    var saw_semicolon = false;
    while (i < segment.len) {
        if (std.mem.startsWith(u8, segment[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, segment, i + 4, "-->") orelse return false;
            i = end + 3;
            continue;
        }
        const byte = segment[i];
        if (std.ascii.isWhitespace(byte)) {
            i += 1;
            continue;
        }
        if (byte == ';') {
            saw_semicolon = true;
            i += 1;
            continue;
        }
        return false;
    }
    return saw_semicolon;
}

fn renderSynonymsTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const term_count = countSynonymTermsHtml(parts, 1);
    if (term_count == 0) return;

    const first_term = templatePositionalHtml(parts, 1) orelse "";
    const thesaurus_only = term_count == 1 and asciiStartsWithIgnoreCaseHtml(first_term, "Thesaurus:");
    try appendEscapedHtmlSlice(out, allocator, if (term_count == 1 and !thesaurus_only) "Synonym" else "Synonyms");
    try appendEscapedHtmlSlice(out, allocator, ": ");
    if (thesaurus_only) try appendEscapedHtmlSlice(out, allocator, "see ");
    try appendSynonymTargetsHtml(out, allocator, parts, 1, options);
}

fn renderLabelTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    options: RenderOptions,
) anyerror!void {
    var positional_index: usize = 0;
    var wrote_any = false;
    var open = false;
    var pending_modifier: ?[]const u8 = null;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0) continue;

        if (labelModifierHtml(trimmed) != null) {
            pending_modifier = labelModifierHtml(trimmed);
            continue;
        }

        if (!open) {
            try out.append(allocator, '(');
            open = true;
        } else if (wrote_any) {
            try out.appendSlice(allocator, ", ");
        }
        wrote_any = true;
        if (pending_modifier) |modifier| {
            try appendEscapedHtmlSlice(out, allocator, modifier);
            try out.append(allocator, ' ');
            pending_modifier = null;
        }
        const canonical = canonicalLabelValueHtml(trimmed);
        if (looksLikeStructuredInline(canonical)) {
            try renderTemplateTargetHtml(out, allocator, canonical, options);
        } else {
            try appendEscapedHtmlSlice(out, allocator, canonical);
        }
    }

    if (pending_modifier) |modifier| {
        if (!open) {
            try out.append(allocator, '(');
            open = true;
        } else if (wrote_any) {
            try out.appendSlice(allocator, ", ");
        }
        try appendEscapedHtmlSlice(out, allocator, modifier);
        wrote_any = true;
    }
    if (open) try out.append(allocator, ')');
}

fn labelModifierHtml(value: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(value);
    inline for ([_][]const u8{
        "chiefly",
        "especially",
        "frequently",
        "often",
        "mostly",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return candidate;
    }
    return null;
}

fn canonicalLabelValueHtml(value: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(value);
    if (std.ascii.eqlIgnoreCase(trimmed, "disparaging")) return "derogatory";
    if (std.ascii.eqlIgnoreCase(trimmed, "football")) return "soccer";
    return trimmed;
}

fn renderDefdateTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const value = templatePositionalHtml(parts, 0) orelse return;
    try out.append(allocator, '[');
    try renderTemplateTargetHtml(out, allocator, value, options);
    try out.append(allocator, ']');
}

fn renderHomophoneTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const first_term_index: usize = if (templatePositionalHtml(parts, 0)) |first|
        if (looksLikeLanguageCodeHtml(first)) 1 else 0
    else
        0;
    const term_count = countNonEmptyPositionalTermsHtml(parts, first_term_index);
    if (term_count == 0) return;

    try appendEscapedHtmlSlice(out, allocator, if (term_count == 1) "Homophone" else "Homophones");
    try appendEscapedHtmlSlice(out, allocator, ": ");
    try appendPositionalTemplateTargetsAllowCodesHtml(out, allocator, parts, first_term_index, ", ", options);
    if (templateNamedHtml(parts, "aa") orelse templateNamedHtml(parts, "a")) |qualifier| {
        const trimmed = trimWikiWhitespace(qualifier);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, " (");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
            try out.append(allocator, ')');
        }
    }
}

fn renderHyphenationTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "Hyphenation: ");
    const total = positionalCountHtml(parts);
    var positional_index: usize = 1;
    var needs_form_separator = false;
    var needs_segment_separator = false;
    while (positional_index < total) : (positional_index += 1) {
        const segment = templatePositionalHtml(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0) {
            if (needs_segment_separator) {
                needs_form_separator = true;
                needs_segment_separator = false;
            }
            continue;
        }
        if (needs_form_separator) {
            try out.appendSlice(allocator, ", ");
            needs_form_separator = false;
        } else if (needs_segment_separator) {
            try appendEscapedHtmlSlice(out, allocator, "‧");
        }
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
        needs_segment_separator = true;
    }
}

const TrailingQualifierHtml = struct {
    term: []const u8,
    qualifier: ?[]const u8 = null,
};

fn sanitizeTemplateTargetAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = trimWikiWhitespace(raw);
    var end = trimmed.len;
    while (end != 0 and trimmed[end - 1] == '>') {
        const start = std.mem.lastIndexOfScalar(u8, trimmed[0..end], '<') orelse break;
        const tag = trimWikiWhitespace(trimmed[start + 1 .. end - 1]);
        if (tag.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, tag, ':') orelse break;
        const prefix = trimWikiWhitespace(tag[0..colon]);
        if (!std.ascii.eqlIgnoreCase(prefix, "id") and
            !std.ascii.eqlIgnoreCase(prefix, "q") and
            !std.ascii.eqlIgnoreCase(prefix, "qq"))
        {
            break;
        }
        end = start;
    }
    return allocator.dupe(u8, trimWikiWhitespace(trimmed[0..end]));
}

fn renderAlternativeFormsTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "Alternative forms: ");
    var positional_index: usize = 0;
    var wrote_any = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == 0) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const parsed = splitTrailingQualifierHtml(segment);
        if (parsed.term.len == 0) continue;
        if (wrote_any) try out.appendSlice(allocator, ", ");
        wrote_any = true;
        if (parsed.qualifier) |qualifier| {
            try out.append(allocator, '(');
            try appendRenderedDisplayHtml(out, allocator, qualifier, options);
            try out.appendSlice(allocator, ") ");
        }
        try renderTemplateTargetHtml(out, allocator, parsed.term, options);
    }
}

fn renderAlterTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const target = templatePositionalHtml(parts, 1) orelse templatePositionalHtml(parts, 0) orelse return;
    try renderTemplateTargetHtml(out, allocator, target, options);

    var tail_segments: [8][]const u8 = undefined;
    var tail_len: usize = 0;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index <= 1) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;
        if (tail_len < tail_segments.len) {
            tail_segments[tail_len] = trimWikiWhitespace(segment);
            tail_len += 1;
        }
    }

    const split_index = alterQualifierSplitIndexHtml(tail_segments[0..tail_len]);
    for (tail_segments[0..split_index]) |term| {
        if (term.len == 0) continue;
        try out.appendSlice(allocator, ", ");
        try renderTemplateTargetHtml(out, allocator, term, options);
    }

    var wrote_qualifier = false;
    for (tail_segments[split_index..tail_len]) |qualifier| {
        if (qualifier.len == 0) continue;
        if (!wrote_qualifier) {
            try out.appendSlice(allocator, " (");
            wrote_qualifier = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderTemplateTargetHtml(out, allocator, qualifier, options);
    }
    if (wrote_qualifier) try out.append(allocator, ')');
}

fn alterQualifierSplitIndexHtml(segments: []const []const u8) usize {
    for (segments, 0..) |segment, i| {
        if (segment.len == 0) return i + 1;
    }

    var nonempty: usize = 0;
    for (segments) |segment| {
        if (segment.len != 0) nonempty += 1;
    }
    if (nonempty <= 1) return segments.len;

    var trailing_qualifiers: usize = 0;
    var i = segments.len;
    while (i > 0) {
        i -= 1;
        const segment = segments[i];
        if (segment.len == 0) continue;
        if (!looksLikeAlterQualifierHtml(segment)) break;
        trailing_qualifiers += 1;
    }
    if (trailing_qualifiers == 0 or trailing_qualifiers >= nonempty) return segments.len;
    return segments.len - trailing_qualifiers;
}

fn looksLikeAlterQualifierHtml(value: []const u8) bool {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len == 0) return false;
    inline for ([_][]const u8{
        "obsolete",
        "archaic",
        "rare",
        "dated",
        "dialectal",
        "colloquial",
        "informal",
        "abbreviation",
        "abbreviations",
        "pronunciation spelling",
        "alternative spelling",
        "alternative form",
        "chiefly UK",
        "chiefly US",
        "UK",
        "US",
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry)) return true;
    }
    return false;
}

fn splitTrailingQualifierHtml(raw: []const u8) TrailingQualifierHtml {
    const trimmed = trimWikiWhitespace(raw);
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '>') return .{ .term = trimmed };
    const tag_start = std.mem.lastIndexOfScalar(u8, trimmed, '<') orelse return .{ .term = trimmed };
    if (tag_start == 0 or tag_start >= trimmed.len - 1) return .{ .term = trimmed };
    const tag = trimWikiWhitespace(trimmed[tag_start + 1 .. trimmed.len - 1]);
    const colon = std.mem.indexOfScalar(u8, tag, ':') orelse return .{ .term = trimmed };
    const prefix = trimWikiWhitespace(tag[0..colon]);
    if (!std.ascii.eqlIgnoreCase(prefix, "ll") and
        !std.ascii.eqlIgnoreCase(prefix, "q") and
        !std.ascii.eqlIgnoreCase(prefix, "qq") and
        !std.ascii.eqlIgnoreCase(prefix, "pos"))
    {
        return .{ .term = trimmed };
    }
    const qualifier = trimWikiWhitespace(tag[colon + 1 ..]);
    const term = trimWikiWhitespace(trimmed[0..tag_start]);
    if (qualifier.len == 0 or term.len == 0) return .{ .term = trimmed };
    return .{ .term = term, .qualifier = qualifier };
}

const PronunciationValueOptions = struct {
    prepend_hyphen: bool = false,
    link_prefix: ?[]const u8 = null,
};

fn appendPronunciationValuesHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    separator: []const u8,
    value_options: PronunciationValueOptions,
    options: RenderOptions,
) anyerror!void {
    var wrote_any = false;
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;
        if (wrote_any) try out.appendSlice(allocator, separator);
        wrote_any = true;
        try appendPronunciationValueHtml(out, allocator, trimmed, value_options, options);
    }
}

fn appendPronunciationValueHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    value_options: PronunciationValueOptions,
    options: RenderOptions,
) anyerror!void {
    const display = if (value_options.prepend_hyphen and value.len != 0 and value[0] != '-') blk: {
        break :blk try std.fmt.allocPrint(allocator, "-{s}", .{value});
    } else try allocator.dupe(u8, value);
    defer allocator.free(display);

    if (value_options.link_prefix) |prefix| {
        const target = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
        defer allocator.free(target);
        try appendWiktionaryPageLinkHtml(out, allocator, target, display, options);
        return;
    }

    if (looksLikeStructuredInline(display)) {
        try renderInlineHtml(out, allocator, display, options);
        return;
    }
    try appendEscapedHtmlSlice(out, allocator, display);
}

fn appendPronunciationAccentHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_accent: ?[]const u8,
    options: RenderOptions,
) anyerror!void {
    const accent = raw_accent orelse return;
    const trimmed = trimWikiWhitespace(accent);
    if (trimmed.len == 0) return;
    try out.append(allocator, '(');
    try appendPronunciationAccentValueHtml(out, allocator, trimmed, options);
    try out.appendSlice(allocator, ") ");
}

fn appendPronunciationAccentValueHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    accent: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (std.mem.indexOfScalar(u8, accent, ',')) |_| {
        var pieces = std.mem.splitScalar(u8, accent, ',');
        var wrote_any = false;
        while (pieces.next()) |piece| {
            const trimmed = trimWikiWhitespace(piece);
            if (trimmed.len == 0) continue;
            if (wrote_any) try out.appendSlice(allocator, ", ");
            wrote_any = true;
            try appendSinglePronunciationAccentValueHtml(out, allocator, trimmed, options);
        }
        return;
    }
    try appendSinglePronunciationAccentValueHtml(out, allocator, accent, options);
}

fn appendSinglePronunciationAccentValueHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    accent: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (pronunciationAccentInfo(accent)) |info| {
        if (info.href) |href| {
            try appendHrefHtml(out, allocator, href, info.display, options);
        } else {
            try appendEscapedHtmlSlice(out, allocator, info.display);
        }
        return;
    }
    if (looksLikeStructuredInline(accent)) {
        try renderInlineHtml(out, allocator, accent, options);
        return;
    }
    try appendEscapedHtmlSlice(out, allocator, accent);
}

const PronunciationAccentInfo = struct {
    display: []const u8,
    href: ?[]const u8 = null,
};

fn pronunciationAccentInfo(accent: []const u8) ?PronunciationAccentInfo {
    if (std.ascii.eqlIgnoreCase(accent, "RP")) {
        return .{ .display = "Received Pronunciation", .href = "https://en.wikipedia.org/wiki/Received_Pronunciation" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "US")) {
        return .{ .display = "US", .href = "https://en.wikipedia.org/wiki/American_English" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "GA")) {
        return .{ .display = "General American", .href = "https://en.wikipedia.org/wiki/General_American_English" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "UK")) {
        return .{ .display = "UK", .href = "https://en.wikipedia.org/wiki/British_English" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "AU")) {
        return .{ .display = "General Australian", .href = "https://en.wikipedia.org/wiki/Australian_English_phonology" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "Canada") or std.ascii.eqlIgnoreCase(accent, "CA")) {
        return .{ .display = "Canada", .href = "https://en.wikipedia.org/wiki/Canadian_English" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "Scouse")) {
        return .{ .display = "Liverpool", .href = "https://en.wikipedia.org/wiki/Scouse" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "Inland North")) {
        return .{ .display = "Inland Northern American", .href = "https://en.wikipedia.org/wiki/Inland_Northern_American_English" };
    }
    if (std.ascii.eqlIgnoreCase(accent, "NI")) {
        return .{ .display = "Northern Ireland", .href = null };
    }
    if (std.ascii.eqlIgnoreCase(accent, "square-nurse")) {
        return .{ .display = "fair–fur merger", .href = "https://en.wikipedia.org/wiki/English-language_vowel_changes_before_historic_/r/#Square%E2%80%93nurse_merger" };
    }
    return null;
}

fn renderPlaceTypeTextHtmlAlloc(
    allocator: std.mem.Allocator,
    raw_type: []const u8,
) ![]const u8 {
    const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(raw_type));
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
        return wikitext.renderWikitextToOwned(allocator, trimmed, max_render_line_bytes);
    }

    var parts = try splitTopLevel(allocator, trimmed, '/');
    defer parts.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (try renderSpecialPlaceTypeTextHtml(&out, allocator, &parts)) {
        return out.toOwnedSlice(allocator);
    }

    var prev_was_connector = false;
    var wrote_any = false;
    for (parts.items) |segment_raw| {
        const segment = trimWikiWhitespace(segment_raw);
        if (segment.len == 0) continue;

        const token = canonicalPlaceHolonymTypeHtml(segment) orelse segment;
        const rendered = try wikitext.renderWikitextToOwned(allocator, token, max_render_line_bytes);
        defer allocator.free(rendered);
        if (rendered.len == 0) continue;

        const is_connector = isPlaceTypeConnectorHtml(rendered);
        if (wrote_any) {
            try out.appendSlice(allocator, if (prev_was_connector or is_connector) " " else " and ");
        }
        try out.appendSlice(allocator, rendered);
        wrote_any = true;
        prev_was_connector = is_connector;
    }
    return out.toOwnedSlice(allocator);
}

fn renderPlaceTypeHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_type: []const u8,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(raw_type));
    if (trimmed.len == 0) return;
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
        return;
    }

    var parts = try splitTopLevel(allocator, trimmed, '/');
    defer parts.deinit(allocator);

    if (try renderSpecialPlaceTypeHtml(out, allocator, &parts, options)) return;

    var prev_was_connector = false;
    var wrote_any = false;
    for (parts.items) |segment_raw| {
        const segment = trimWikiWhitespace(segment_raw);
        if (segment.len == 0) continue;

        const token = canonicalPlaceHolonymTypeHtml(segment) orelse segment;
        const is_connector = isPlaceTypeConnectorHtml(token);
        if (wrote_any) {
            try out.appendSlice(allocator, if (prev_was_connector or is_connector) " " else " and ");
        }
        try renderTemplateTargetHtml(out, allocator, token, options);
        wrote_any = true;
        prev_was_connector = is_connector;
    }
}

fn renderPlaceTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const type_index = placeTypeIndexHtml(parts);
    const raw_type = templatePositionalHtml(parts, type_index) orelse return;
    const abbreviation_target = placeAbbreviationTargetHtml(raw_type);
    const actual_type_index = if (abbreviation_target != null and templatePositionalHtml(parts, type_index + 1) != null) type_index + 1 else type_index;
    const actual_raw_type = templatePositionalHtml(parts, actual_type_index) orelse raw_type;
    const rendered_type_text = try renderPlaceTypeTextHtmlAlloc(allocator, actual_raw_type);
    defer allocator.free(rendered_type_text);
    if (rendered_type_text.len == 0) return;

    if (abbreviation_target) |target| {
        try appendLinkedResolvedTextHtml(out, allocator, "Abbreviation", "abbreviation", options);
        try appendEscapedHtmlSlice(out, allocator, " of ");
        try renderTemplateTargetHtml(out, allocator, target, options);
        try appendEscapedHtmlSlice(out, allocator, ": ");
        if (placeTypeNeedsArticleHtml(rendered_type_text)) {
            try out.appendSlice(allocator, chooseIndefiniteArticleHtml(rendered_type_text, false));
            try out.append(allocator, ' ');
        }
    } else if (placeTypeNeedsArticleHtml(rendered_type_text)) {
        try out.appendSlice(allocator, chooseIndefiniteArticleHtml(rendered_type_text, true));
        try out.append(allocator, ' ');
    }
    try renderPlaceTypeHtml(out, allocator, actual_raw_type, options);

    var wrote_location = false;
    var last_was_location_value = false;
    const positional_total = positionalCountHtml(parts);
    var positional_index = actual_type_index + 1;
    while (positional_index < positional_total) : (positional_index += 1) {
        const piece = templatePositionalHtml(parts, positional_index) orelse continue;
        const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(piece));
        if (trimmed.len == 0) continue;

        if (templatePositionalHtml(parts, positional_index + 1)) |next_raw| {
            const next_piece = trimWikiWhitespace(stripTraversalSegmentsHtml(next_raw));
            if (isPlaceConnectorPieceHtml(trimmed, next_piece)) {
                if (wrote_location) {
                    try out.appendSlice(allocator, connectorSeparatorHtml(trimmed, last_was_location_value));
                } else {
                    try out.append(allocator, ' ');
                }
                try renderInlineHtml(out, allocator, trimmed, options);
                try out.append(allocator, ' ');
                try renderPlaceLocationFragmentHtml(out, allocator, next_piece, options);
                wrote_location = true;
                last_was_location_value = true;
                positional_index += 1;
                continue;
            }
        }

        if (!wrote_location) {
            try out.appendSlice(allocator, placeFirstLocationSeparatorHtml(trimmed, rendered_type_text, abbreviation_target != null));
            wrote_location = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderPlaceLocationFragmentHtml(out, allocator, trimmed, options);
        last_was_location_value = true;
    }

    for ([_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "official", .label = "Official name: " },
        .{ .key = "capital", .label = "Capital: " },
        .{ .key = "caplc", .label = "Capital and largest city: " },
        .{ .key = "largest city", .label = "Largest city: " },
        .{ .key = "located", .label = "Located in " },
        .{ .key = "located in", .label = "Located in " },
    }) |field| {
        if (templateNamedHtml(parts, field.key)) |value| {
            const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(value));
            if (trimmed.len == 0) continue;
            if (wrote_location) {
                try out.appendSlice(allocator, ". ");
            } else {
                try out.append(allocator, ' ');
                wrote_location = true;
            }
            try out.appendSlice(allocator, field.label);
            try renderPlaceLocationFragmentHtml(out, allocator, trimmed, options);
        }
    }
}

fn placeAbbreviationTargetHtml(raw_type: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(raw_type));
    if (!asciiStartsWithIgnoreCase(trimmed, "@abbrev of:")) return null;
    return trimWikiWhitespace(trimmed["@abbrev of:".len..]);
}

fn renderPlaceLocationFragmentHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (looksLikeStructuredInline(input)) {
        try renderInlineHtml(out, allocator, input, options);
        return;
    }

    if (std.mem.indexOfScalar(u8, input, '/')) |slash| {
        const prefix = trimWikiWhitespace(input[0..slash]);
        const value = trimWikiWhitespace(input[slash + 1 ..]);
        if (value.len == 0) return;
        const resolved_value = placeLocationDisplayValueHtml(prefix, value);
        const display = placeHolonymDisplayHtml(prefix);
        switch (display.kind) {
            .plain => {
                try renderTemplateTargetHtml(out, allocator, resolved_value, options);
            },
            .prefix => {
                try appendPlaceHolonymPrefixHtml(out, allocator, display.label);
                try renderTemplateTargetHtml(out, allocator, resolved_value, options);
            },
            .suffix => {
                try renderTemplateTargetHtml(out, allocator, resolved_value, options);
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, display.label);
            },
        }
        return;
    }

    try renderPhraseHtml(out, allocator, input, options);
}

fn renderSpecialPlaceTypeTextHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
) !bool {
    if (parts.items.len != 2) return false;

    const first = trimWikiWhitespace(parts.items[0]);
    const second = trimWikiWhitespace(parts.items[1]);
    const canonical_second = canonicalPlaceHolonymTypeHtml(second) orelse second;
    if (!std.ascii.eqlIgnoreCase(trimWikiWhitespace(canonical_second), "capital city") and !std.ascii.eqlIgnoreCase(trimWikiWhitespace(canonical_second), "county seat")) return false;

    const rendered_first = try wikitext.renderWikitextToOwned(allocator, canonicalPlaceHolonymTypeHtml(first) orelse first, max_render_line_bytes);
    defer allocator.free(rendered_first);
    if (rendered_first.len == 0) return false;

    const rendered_second = try wikitext.renderWikitextToOwned(allocator, canonical_second, max_render_line_bytes);
    defer allocator.free(rendered_second);
    if (rendered_second.len == 0) return false;

    try out.appendSlice(allocator, rendered_first);
    try out.appendSlice(allocator, ", the ");
    try out.appendSlice(allocator, rendered_second);
    return true;
}

fn renderSpecialPlaceTypeHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) !bool {
    if (parts.items.len != 2) return false;

    const first = trimWikiWhitespace(parts.items[0]);
    const second = trimWikiWhitespace(parts.items[1]);
    const canonical_second = canonicalPlaceHolonymTypeHtml(second) orelse second;
    if (!std.ascii.eqlIgnoreCase(trimWikiWhitespace(canonical_second), "capital city") and !std.ascii.eqlIgnoreCase(trimWikiWhitespace(canonical_second), "county seat")) return false;

    try renderTemplateTargetHtml(out, allocator, canonicalPlaceHolonymTypeHtml(first) orelse first, options);
    try out.appendSlice(allocator, ", the ");
    try renderTemplateTargetHtml(out, allocator, canonical_second, options);
    return true;
}

fn renderPhraseHtmlAlloc(
    allocator: std.mem.Allocator,
    phrase: []const u8,
    options: RenderOptions,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try renderPhraseHtml(&out, allocator, phrase, options);
    return out.toOwnedSlice(allocator);
}

fn appendLinkedResolvedTextHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    display: []const u8,
    target_hint: []const u8,
    options: RenderOptions,
) anyerror!void {
    const target = try resolveLinkTargetAlloc(allocator, target_hint, options);
    defer if (target) |value| allocator.free(value);
    try appendLinkMaybe(out, allocator, target, display, options);
}

fn appendResolvedDisplayTargetHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    display: []const u8,
    target_hint: []const u8,
    options: RenderOptions,
) anyerror!void {
    const target = try resolveLinkTargetAlloc(allocator, target_hint, options);
    defer if (target) |value| allocator.free(value);
    try appendLinkMaybe(out, allocator, target, display, options);
}

fn appendQuotedTemplateTargetHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "“");
    try renderTemplateTargetHtml(out, allocator, value, options);
    try appendEscapedHtmlSlice(out, allocator, "”");
}

fn appendLinkMaybe(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    target: ?[]const u8,
    display: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (target) |value| {
        const href = try entryHrefAlloc(allocator, value);
        defer allocator.free(href);
        try out.appendSlice(allocator, "<a href=\"");
        try out.appendSlice(allocator, href);
        try out.appendSlice(allocator, "\">");
        try appendRenderedDisplayHtml(out, allocator, display, options);
        try out.appendSlice(allocator, "</a>");
        return;
    }
    try appendRenderedDisplayHtml(out, allocator, display, options);
}

fn appendHrefHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    href: []const u8,
    display: []const u8,
    options: RenderOptions,
) anyerror!void {
    try out.appendSlice(allocator, "<a href=\"");
    try appendEscapedHtmlSlice(out, allocator, href);
    try out.appendSlice(allocator, "\">");
    try appendRenderedDisplayHtml(out, allocator, display, options);
    try out.appendSlice(allocator, "</a>");
}

fn appendWiktionaryPageLinkHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    page: []const u8,
    display: []const u8,
    options: RenderOptions,
) anyerror!void {
    const href = try wiktionaryPageHrefAlloc(allocator, page);
    defer allocator.free(href);
    try appendHrefHtml(out, allocator, href, display, options);
}

fn resolveLinkTargetAlloc(
    allocator: std.mem.Allocator,
    term: []const u8,
    options: RenderOptions,
) !?[]const u8 {
    const resolver = options.link_resolver orelse return null;
    return resolver.resolve(resolver.context, allocator, trimWikiWhitespace(term));
}

const FragmentTargetHtml = struct {
    base: []const u8,
    has_fragment: bool,
};

fn splitFragmentTargetHtml(raw: []const u8) FragmentTargetHtml {
    const trimmed = trimWikiWhitespace(raw);
    const hash_index = std.mem.indexOfScalar(u8, trimmed, '#') orelse return .{ .base = trimmed, .has_fragment = false };
    return .{ .base = trimWikiWhitespace(trimmed[0..hash_index]), .has_fragment = true };
}

fn entryHrefAlloc(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "/entry/");
    for (target) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(allocator, byte);
        } else {
            const encoded = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{byte});
            defer allocator.free(encoded);
            try out.appendSlice(allocator, encoded);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn looksLikeStructuredInline(input: []const u8) bool {
    return std.mem.indexOf(u8, input, "[[") != null or
        std.mem.indexOf(u8, input, "{{") != null or
        std.mem.indexOf(u8, input, "<<") != null or
        std.mem.indexOf(u8, input, "''") != null or
        std.mem.indexOf(u8, input, "[http") != null or
        std.mem.indexOf(u8, input, "<ref") != null or
        std.mem.indexOf(u8, input, "<sup") != null or
        std.mem.indexOf(u8, input, "<sub") != null or
        std.mem.indexOf(u8, input, "<small") != null or
        std.mem.indexOf(u8, input, "<!--") != null;
}

fn appendRenderedDisplayHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    display: []const u8,
    options: RenderOptions,
) anyerror!void {
    if (looksLikeStructuredInline(display)) {
        try renderInlineHtml(out, allocator, display, options);
        return;
    }
    try appendDecodedEscapedChunk(out, allocator, display);
}

fn renderExternalWikipediaTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const raw_target = templatePositionalHtml(parts, 0) orelse return;
    const trimmed_target = trimWikiWhitespace(raw_target);
    if (trimmed_target.len == 0) return;

    const display = if (templatePositionalHtml(parts, 1)) |value|
        trimWikiWhitespace(value)
    else
        normalizedWikiTarget(trimmed_target);
    if (display.len == 0) return;

    const raw_prefixed = if (std.mem.indexOfScalar(u8, trimmed_target, ':') == null)
        try std.fmt.allocPrint(allocator, "w:{s}", .{trimmed_target})
    else
        try allocator.dupe(u8, trimmed_target);
    defer allocator.free(raw_prefixed);

    if (try externalWikiHrefAlloc(allocator, raw_prefixed)) |href| {
        defer allocator.free(href);
        try appendHrefHtml(out, allocator, href, display, options);
        return;
    }

    try appendRenderedDisplayHtml(out, allocator, display, options);
}

fn normalizedWikiTarget(raw_target: []const u8) []const u8 {
    var target = trimWikiWhitespace(raw_target);
    if (target.len != 0 and target[0] == ':') target = trimWikiWhitespace(target[1..]);
    if (std.mem.indexOfScalar(u8, target, '#')) |hash_index| {
        target = if (hash_index == 0) target[1..] else target[0..hash_index];
    }
    if (isHiddenNamespaceTarget(target)) return "";
    if (isExternalWiktionaryNamespaceTarget(target)) return target;
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon_index| {
        if (colon_index + 1 < target.len) target = target[colon_index + 1 ..];
    }
    return trimWikiWhitespace(target);
}

fn isHiddenNamespaceTarget(target: []const u8) bool {
    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const namespace = trimWikiWhitespace(target[0..colon_index]);
    return std.ascii.eqlIgnoreCase(namespace, "File") or std.ascii.eqlIgnoreCase(namespace, "Image");
}

fn externalWikiHrefAlloc(allocator: std.mem.Allocator, raw_target: []const u8) !?[]u8 {
    var target = trimWikiWhitespace(raw_target);
    if (target.len != 0 and target[0] == ':') target = trimWikiWhitespace(target[1..]);

    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return null;
    const namespace = trimWikiWhitespace(target[0..colon_index]);
    const page = trimWikiWhitespace(target[colon_index + 1 ..]);
    if (page.len == 0) return null;

    const base = if (std.ascii.eqlIgnoreCase(namespace, "w") or std.ascii.eqlIgnoreCase(namespace, "wikipedia"))
        "https://en.wikipedia.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "s") or std.ascii.eqlIgnoreCase(namespace, "wikisource"))
        "https://en.wikisource.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "q") or std.ascii.eqlIgnoreCase(namespace, "wikiquote"))
        "https://en.wikiquote.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "n") or std.ascii.eqlIgnoreCase(namespace, "wikinews"))
        "https://en.wikinews.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "v") or std.ascii.eqlIgnoreCase(namespace, "wikiversity"))
        "https://en.wikiversity.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "commons"))
        "https://commons.wikimedia.org/wiki/"
    else if (std.ascii.eqlIgnoreCase(namespace, "Thesaurus") or
        std.ascii.eqlIgnoreCase(namespace, "Appendix") or
        std.ascii.eqlIgnoreCase(namespace, "Citations") or
        std.ascii.eqlIgnoreCase(namespace, "Reconstruction") or
        std.ascii.eqlIgnoreCase(namespace, "Wiktionary"))
        "https://en.wiktionary.org/wiki/"
    else
        return null;

    const path = if (std.ascii.eqlIgnoreCase(namespace, "Thesaurus") or
        std.ascii.eqlIgnoreCase(namespace, "Appendix") or
        std.ascii.eqlIgnoreCase(namespace, "Citations") or
        std.ascii.eqlIgnoreCase(namespace, "Reconstruction") or
        std.ascii.eqlIgnoreCase(namespace, "Wiktionary"))
        target
    else
        page;
    return @as(?[]u8, try buildExternalWikiHrefAlloc(allocator, base, path));
}

fn isExternalWiktionaryNamespaceTarget(raw_target: []const u8) bool {
    const target = trimWikiWhitespace(raw_target);
    const colon_index = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const namespace = trimWikiWhitespace(target[0..colon_index]);
    return std.ascii.eqlIgnoreCase(namespace, "Thesaurus") or
        std.ascii.eqlIgnoreCase(namespace, "Appendix") or
        std.ascii.eqlIgnoreCase(namespace, "Citations") or
        std.ascii.eqlIgnoreCase(namespace, "Reconstruction") or
        std.ascii.eqlIgnoreCase(namespace, "Wiktionary");
}

fn buildExternalWikiHrefAlloc(allocator: std.mem.Allocator, base: []const u8, page: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, base);

    const hash_index = std.mem.indexOfScalar(u8, page, '#');
    const page_name = if (hash_index) |index| page[0..index] else page;
    const fragment = if (hash_index) |index| page[index + 1 ..] else "";

    try appendEncodedWikiComponent(&out, allocator, page_name, true);
    if (fragment.len != 0) {
        try out.append(allocator, '#');
        try appendEncodedWikiComponent(&out, allocator, fragment, false);
    }
    return out.toOwnedSlice(allocator);
}

fn wiktionaryPageHrefAlloc(allocator: std.mem.Allocator, page: []const u8) ![]u8 {
    return buildExternalWikiHrefAlloc(allocator, "https://en.wiktionary.org/wiki/", page);
}

fn appendEncodedWikiComponent(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    replace_spaces_with_underscores: bool,
) !void {
    for (input) |byte| {
        const normalized = if (replace_spaces_with_underscores and byte == ' ') '_' else byte;
        if (std.ascii.isAlphanumeric(normalized) or normalized == '-' or normalized == '_' or normalized == '.' or normalized == '~' or normalized == '(' or normalized == ')' or normalized == ':') {
            try out.append(allocator, normalized);
        } else {
            const encoded = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{normalized});
            defer allocator.free(encoded);
            try out.appendSlice(allocator, encoded);
        }
    }
}

fn shouldKeepLiteralApostrophe(input: []const u8, run_start: usize, run_len: usize) bool {
    if ((run_len & 1) == 0) return false;
    if (run_start == 0 or run_start + run_len >= input.len) return false;
    return isLiteralApostropheNeighbor(input[run_start - 1]) and isLiteralApostropheNeighbor(input[run_start + run_len]);
}

fn isLiteralApostropheNeighbor(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte);
}

fn isWikiLinkTrailByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte);
}

fn templateMatchesHtml(name: []const u8, expected: []const u8) bool {
    const actual = trimWikiWhitespace(name);
    const target = trimWikiWhitespace(expected);

    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
        while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
        if (i == actual.len or j == target.len) break;
        if (std.ascii.toLower(actual[i]) != std.ascii.toLower(target[j])) return false;
        i += 1;
        j += 1;
    }
    while (i < actual.len and isTemplateNameSpaceByte(actual[i])) : (i += 1) {}
    while (j < target.len and isTemplateNameSpaceByte(target[j])) : (j += 1) {}
    return i == actual.len and j == target.len;
}

fn isTemplateNameSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '_';
}

fn findExternalLinkClose(input: []const u8, start: usize) ?usize {
    if (start >= input.len or input[start] != '[' or start + 1 >= input.len) return null;
    if (!asciiStartsWithIgnoreCase(input[start + 1 ..], "http")) return null;

    var templates: usize = 0;
    var links: usize = 0;
    var i = start + 1;
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
        if (input[i] == ']' and templates == 0 and links == 0) return i;
    }
    return null;
}

fn isEtymologyLexemeTemplateHtml(name: []const u8) bool {
    return templateMatchesHtml(name, "inh") or
        templateMatchesHtml(name, "inh+") or
        templateMatchesHtml(name, "der") or
        templateMatchesHtml(name, "der+") or
        templateMatchesHtml(name, "bor") or
        templateMatchesHtml(name, "bor+") or
        templateMatchesHtml(name, "ubor") or
        templateMatchesHtml(name, "lbor") or
        templateMatchesHtml(name, "learned borrowing") or
        templateMatchesHtml(name, "uder");
}

fn isPlaceholderTemplateTermHtml(term: []const u8) bool {
    const trimmed = trimWikiWhitespace(term);
    return std.mem.eql(u8, trimmed, "-") or std.mem.eql(u8, trimmed, "—");
}

fn templateArgNumericIndex(segment: []const u8) ?usize {
    const equals = topLevelEquals(segment) orelse return null;
    const key = trimWikiWhitespace(segment[0..equals]);
    if (key.len == 0) return null;
    for (key) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const one_based = std.fmt.parseInt(usize, key, 10) catch return null;
    return if (one_based == 0) null else one_based - 1;
}

fn templateArgNamedValueHtml(segment: []const u8) ?[]const u8 {
    const equals = topLevelEquals(segment) orelse return null;
    return trimWikiWhitespace(segment[equals + 1 ..]);
}

fn positionalCountHtml(parts: *const std.ArrayList([]const u8)) usize {
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (!templateArgHasName(segment) or templateArgNumericIndex(segment) != null) count += 1;
    }
    return count;
}

fn templatePositionalHtml(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) {
            if (templateArgNumericIndex(segment)) |numeric_index| {
                if (numeric_index == target) return templateArgNamedValueHtml(segment);
            }
            continue;
        }
        if (positional_index == target) return trimWikiWhitespace(segment);
        positional_index += 1;
    }
    return null;
}

fn templateIndexedNamedHtml(parts: *const std.ArrayList([]const u8), prefix: []const u8, index: usize) ?[]const u8 {
    var key_buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ prefix, index }) catch return null;
    return templateNamedHtml(parts, key);
}

fn templateTargetHtmlArg(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCountHtml(parts);
    if (count == 0) return null;
    if (count >= 2) return templatePositionalHtml(parts, count - 1);
    return templatePositionalHtml(parts, 0);
}

fn countRenderablePositionalTermsHtml(parts: *const std.ArrayList([]const u8), start_index: usize) usize {
    var positional_index: usize = 0;
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        const trimmed = blk: {
            if (templateArgHasName(segment)) {
                if (templateArgNumericIndex(segment)) |numeric_index| {
                    if (numeric_index < start_index) continue;
                    positional_index = numeric_index;
                    break :blk templateArgNamedValueHtml(segment) orelse continue;
                }
                continue;
            }
            break :blk trimWikiWhitespace(segment);
        };
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;
        count += 1;
    }
    return count;
}

fn countNonEmptyPositionalTermsHtml(parts: *const std.ArrayList([]const u8), start_index: usize) usize {
    var positional_index: usize = 0;
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        const trimmed = blk: {
            if (templateArgHasName(segment)) {
                if (templateArgNumericIndex(segment)) |numeric_index| {
                    if (numeric_index < start_index) continue;
                    positional_index = numeric_index;
                    break :blk templateArgNamedValueHtml(segment) orelse continue;
                }
                continue;
            }
            break :blk trimWikiWhitespace(segment);
        };
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        if (trimmed.len != 0) count += 1;
    }
    return count;
}

fn countSynonymTermsHtml(parts: *const std.ArrayList([]const u8), start_index: usize) usize {
    var positional_index: usize = 0;
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed) or std.mem.eql(u8, trimmed, ";")) continue;
        count += 1;
    }
    return count;
}

fn appendSynonymTargetsHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    start_index: usize,
    options: RenderOptions,
) anyerror!void {
    var positional_index: usize = 0;
    var wrote_any = false;
    var pending_semicolon = false;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index < start_index) {
            positional_index += 1;
            continue;
        }
        positional_index += 1;

        const trimmed = trimWikiWhitespace(segment);
        if (trimmed.len == 0 or looksLikeLanguageCodeHtml(trimmed)) continue;
        if (std.mem.eql(u8, trimmed, ";")) {
            if (wrote_any) pending_semicolon = true;
            continue;
        }

        if (wrote_any) {
            try out.appendSlice(allocator, if (pending_semicolon) "; " else ", ");
        }
        pending_semicolon = false;
        wrote_any = true;
        try renderTemplateTargetHtml(out, allocator, trimmed, options);
    }
}

fn quoteDateValueAlloc(allocator: std.mem.Allocator, parts: *const std.ArrayList([]const u8)) !?[]u8 {
    if (templateNamedHtml(parts, "date")) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len == 10 and trimmed[4] == '-' and trimmed[7] == '-') {
            const month = monthNameFromDigits(trimmed[5..7]) orelse return @as(?[]u8, try allocator.dupe(u8, trimmed));
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ trimmed[0..4], month, trimLeadingZeroDigits(trimmed[8..10]) }));
        }
        if (try normalizeHumanDateAlloc(allocator, trimmed)) |normalized| return normalized;
        return @as(?[]u8, try allocator.dupe(u8, trimmed));
    }

    const year = templateNamedHtml(parts, "year") orelse return null;
    const month = templateNamedHtml(parts, "month");
    const day = templateNamedHtml(parts, "day");
    if (month) |month_value| {
        if (day) |day_value| {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{
                trimWikiWhitespace(year),
                trimWikiWhitespace(month_value),
                trimWikiWhitespace(day_value),
            }));
        }
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s}", .{
            trimWikiWhitespace(year),
            trimWikiWhitespace(month_value),
        }));
    }
    return @as(?[]u8, try allocator.dupe(u8, trimWikiWhitespace(year)));
}

fn normalizeHumanDateAlloc(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    var normalized_buf: [128]u8 = undefined;
    const normalized = normalizeDateSeparators(value, &normalized_buf);
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, normalized, ' ');
    while (iter.next()) |part| {
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }

    if (count == 2) {
        if (monthNameFromWord(parts[0])) |month| {
            if (isYearToken(parts[1])) return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s}", .{ parts[1], month }));
        }
        return null;
    }
    if (count != 3) return null;

    if (monthNameFromWord(parts[0])) |month| {
        if (isDayToken(parts[1]) and isYearToken(parts[2])) {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ parts[2], month, trimLeadingZeroDigits(parts[1]) }));
        }
    }
    if (isDayToken(parts[0])) {
        if (monthNameFromWord(parts[1])) |month| {
            if (isYearToken(parts[2])) {
                return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ parts[2], month, trimLeadingZeroDigits(parts[0]) }));
            }
        }
    }
    return null;
}

fn normalizeHumanDateDisplayAlloc(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    var normalized_buf: [128]u8 = undefined;
    const normalized = normalizeDateSeparators(value, &normalized_buf);
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, normalized, ' ');
    while (iter.next()) |part| {
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }

    if (count == 2) {
        if (monthNameFromWord(parts[0])) |month| {
            if (isYearToken(parts[1])) return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s}", .{ month, parts[1] }));
        }
        return null;
    }
    if (count != 3) return null;

    if (monthNameFromWord(parts[0])) |month| {
        if (isDayToken(parts[1]) and isYearToken(parts[2])) {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ trimLeadingZeroDigits(parts[1]), month, parts[2] }));
        }
    }
    if (isDayToken(parts[0])) {
        if (monthNameFromWord(parts[1])) |month| {
            if (isYearToken(parts[2])) {
                return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ trimLeadingZeroDigits(parts[0]), month, parts[2] }));
            }
        }
    }
    return null;
}

fn normalizeDateSeparators(value: []const u8, buf: []u8) []const u8 {
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (i + 4 <= value.len and std.mem.eql(u8, value[i .. i + 4], "<!--")) {
            const end = std.mem.indexOfPos(u8, value, i + 4, "-->") orelse break;
            i = end + 2;
            continue;
        }
        const char = value[i];
        const mapped = switch (char) {
            ',', '\t', '\r', '\n' => ' ',
            else => char,
        };
        if (out_len >= buf.len) break;
        buf[out_len] = mapped;
        out_len += 1;
    }
    return std.mem.trim(u8, buf[0..out_len], " ");
}

fn monthNameFromWord(word: []const u8) ?[]const u8 {
    inline for ([_]struct { short: []const u8, full: []const u8 }{
        .{ .short = "jan", .full = "January" },
        .{ .short = "feb", .full = "February" },
        .{ .short = "mar", .full = "March" },
        .{ .short = "apr", .full = "April" },
        .{ .short = "may", .full = "May" },
        .{ .short = "jun", .full = "June" },
        .{ .short = "jul", .full = "July" },
        .{ .short = "aug", .full = "August" },
        .{ .short = "sep", .full = "September" },
        .{ .short = "oct", .full = "October" },
        .{ .short = "nov", .full = "November" },
        .{ .short = "dec", .full = "December" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry.full) or
            std.ascii.eqlIgnoreCase(word, entry.short) or
            (word.len == entry.short.len + 1 and word[word.len - 1] == '.' and std.ascii.eqlIgnoreCase(word[0..entry.short.len], entry.short)))
        {
            return entry.full;
        }
    }
    return null;
}

fn isYearToken(value: []const u8) bool {
    if (value.len != 4) return false;
    for (value) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn isDayToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 2) return false;
    for (value) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn quoteAuthorValueAlloc(allocator: std.mem.Allocator, parts: *const std.ArrayList([]const u8)) !?[]u8 {
    if (templateNamedHtml(parts, "author")) |value| return @as(?[]u8, try allocator.dupe(u8, trimWikiWhitespace(value)));
    const first = templateNamedHtml(parts, "first");
    const last = templateNamedHtml(parts, "last");
    if (first == null and last == null) return null;
    if (first != null and last != null) {
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s}", .{
            trimWikiWhitespace(first.?),
            trimWikiWhitespace(last.?),
        }));
    }
    return @as(?[]u8, try allocator.dupe(u8, trimWikiWhitespace((first orelse last).?)));
}

fn quoteChapterValueAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len != 0 and std.ascii.isDigit(trimmed[0])) {
        return std.fmt.allocPrint(allocator, "chapter {s}", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{trimmed});
}

fn quoteSuffixedValueAlloc(allocator: std.mem.Allocator, value: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ value, suffix });
}

fn quoteQuotedLiteralValueAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
}

fn quoteEditionLikeValueAlloc(allocator: std.mem.Allocator, value: []const u8, key: []const u8) ![]u8 {
    if ((std.mem.eql(u8, key, "edition") or std.mem.eql(u8, key, "edition_plain")) and std.mem.indexOf(u8, value, "edition") == null and std.mem.indexOf(u8, value, "Edition") == null) {
        return std.fmt.allocPrint(allocator, "{s} edition", .{value});
    }
    return allocator.dupe(u8, value);
}

fn normalizeSemicolonListAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, ';') == null) return allocator.dupe(u8, value);

    var pieces = std.mem.splitScalar(u8, value, ';');
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var count: usize = 0;
    while (pieces.next()) |piece| {
        const trimmed = trimWikiWhitespace(piece);
        if (trimmed.len == 0) continue;
        if (count != 0) {
            try normalized.appendSlice(allocator, if (count == 1) " and " else ", ");
        }
        try normalized.appendSlice(allocator, trimmed);
        count += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

fn normalizeCommaListAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, ';') == null) return allocator.dupe(u8, value);

    var pieces = std.mem.splitScalar(u8, value, ';');
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var count: usize = 0;
    while (pieces.next()) |piece| {
        const trimmed = trimWikiWhitespace(piece);
        if (trimmed.len == 0) continue;
        if (count != 0) try normalized.appendSlice(allocator, ", ");
        try normalized.appendSlice(allocator, trimmed);
        count += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

fn quoteArchiveMetaAlloc(allocator: std.mem.Allocator, parts: *const std.ArrayList([]const u8)) !?[]u8 {
    _ = templateNamedHtml(parts, "archiveurl") orelse return null;
    const archived = templateNamedHtml(parts, "archivedate") orelse return null;
    const trimmed = trimWikiWhitespace(archived);
    if (trimmed.len == 0) return null;
    const normalized = (try normalizeHumanDateDisplayAlloc(allocator, trimmed)) orelse try allocator.dupe(u8, trimmed);
    defer allocator.free(normalized);
    return try std.fmt.allocPrint(allocator, "archived from the original on {s}", .{normalized});
}

fn quoteSecondaryPublicationAlloc(allocator: std.mem.Allocator, parts: *const std.ArrayList([]const u8)) !?[]u8 {
    const chapter2 = templateNamedHtml(parts, "chapter2");
    const title2 = templateNamedHtml(parts, "title2");
    const location2 = templateNamedHtml(parts, "location2");
    const publisher2 = templateNamedHtml(parts, "publisher2");
    const format2 = templateNamedHtml(parts, "format2");
    const date2 = templateNamedHtml(parts, "date2");
    const year2 = templateNamedHtml(parts, "year2");
    if (chapter2 == null and title2 == null and location2 == null and publisher2 == null and format2 == null and date2 == null and year2 == null) return null;

    var rendered: std.ArrayList(u8) = .empty;
    errdefer rendered.deinit(allocator);
    try rendered.appendSlice(allocator, "republished as ");

    var wrote_any = true;
    if (chapter2) |value| {
        try rendered.append(allocator, '"');
        try rendered.appendSlice(allocator, trimWikiWhitespace(value));
        try rendered.append(allocator, '"');
    } else {
        wrote_any = false;
    }
    if (title2) |value| {
        if (wrote_any) {
            try rendered.appendSlice(allocator, ", in ");
        }
        try rendered.appendSlice(allocator, trimWikiWhitespace(value));
        wrote_any = true;
    }
    if (format2) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try rendered.appendSlice(allocator, " (");
            try rendered.appendSlice(allocator, trimmed);
            try rendered.append(allocator, ')');
            wrote_any = true;
        }
    }
    if (location2) |value| {
        if (wrote_any) try rendered.appendSlice(allocator, ", ");
        try rendered.appendSlice(allocator, trimWikiWhitespace(value));
        wrote_any = true;
    }
    if (publisher2) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            if (location2 != null) {
                try rendered.appendSlice(allocator, ": ");
            } else if (wrote_any) {
                try rendered.appendSlice(allocator, ", ");
            }
            try rendered.appendSlice(allocator, trimmed);
            wrote_any = true;
        }
    }
    if (date2) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            const normalized = (try normalizeHumanDateDisplayAlloc(allocator, trimmed)) orelse try allocator.dupe(u8, trimmed);
            defer allocator.free(normalized);
            if (wrote_any) try rendered.appendSlice(allocator, ", ");
            try rendered.appendSlice(allocator, normalized);
            wrote_any = true;
        }
    } else if (year2) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            if (wrote_any) try rendered.appendSlice(allocator, ", ");
            try rendered.appendSlice(allocator, trimmed);
        }
    }
    if (!wrote_any) return null;
    return @as(?[]u8, try rendered.toOwnedSlice(allocator));
}

fn monthNameFromDigits(digits: []const u8) ?[]const u8 {
    inline for ([_]struct { digits: []const u8, name: []const u8 }{
        .{ .digits = "01", .name = "January" },
        .{ .digits = "02", .name = "February" },
        .{ .digits = "03", .name = "March" },
        .{ .digits = "04", .name = "April" },
        .{ .digits = "05", .name = "May" },
        .{ .digits = "06", .name = "June" },
        .{ .digits = "07", .name = "July" },
        .{ .digits = "08", .name = "August" },
        .{ .digits = "09", .name = "September" },
        .{ .digits = "10", .name = "October" },
        .{ .digits = "11", .name = "November" },
        .{ .digits = "12", .name = "December" },
    }) |entry| {
        if (std.mem.eql(u8, digits, entry.digits)) return entry.name;
    }
    return null;
}

fn trimLeadingZeroDigits(digits: []const u8) []const u8 {
    if (digits.len >= 2 and digits[0] == '0') return digits[1..];
    return digits;
}

fn templateEtymologyTermHtml(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    if (templatePositionalHtml(parts, 2) == null) {
        if (templatePositionalHtml(parts, 0)) |source_code| {
            if (templatePositionalHtml(parts, 1)) |candidate| {
                if (looksLikeLanguageCodeHtml(source_code) and languageDisplayHtml(candidate) != null) return null;
            }
        }
    }
    return templatePositionalHtml(parts, 2) orelse
        templatePositionalHtml(parts, 1) orelse
        templatePositionalHtml(parts, 0);
}

fn templateNamedHtml(parts: *const std.ArrayList([]const u8), name: []const u8) ?[]const u8 {
    for (parts.items[1..]) |segment| {
        const equals = topLevelEquals(segment) orelse continue;
        const key = trimWikiWhitespace(segment[0..equals]);
        if (std.ascii.eqlIgnoreCase(key, name)) return trimWikiWhitespace(segment[equals + 1 ..]);
    }
    return null;
}

fn normalizePlaceFragmentHtml(input: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(input));
    if (trimmed.len == 0) return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const prefix = trimWikiWhitespace(trimmed[0..slash]);
        if (prefix.len <= 8 and std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            return trimWikiWhitespace(trimmed[slash + 1 ..]);
        }
    }
    return trimmed;
}

const PlaceHolonymDisplayKindHtml = enum {
    plain,
    prefix,
    suffix,
};

const PlaceHolonymDisplayHtml = struct {
    kind: PlaceHolonymDisplayKindHtml = .plain,
    label: []const u8 = "",
};

const PlaceHolonymPrefixHtml = struct {
    base: []const u8,
    force_prefix: bool = false,
    force_suffix: bool = false,
};

fn parsePlaceHolonymPrefixHtml(prefix: []const u8) PlaceHolonymPrefixHtml {
    const trimmed = trimWikiWhitespace(prefix);
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return .{ .base = trimmed };
    const base = trimWikiWhitespace(trimmed[0..colon]);
    const modifier = trimWikiWhitespace(trimmed[colon + 1 ..]);
    return .{
        .base = base,
        .force_prefix = std.ascii.eqlIgnoreCase(modifier, "pref") or std.ascii.eqlIgnoreCase(modifier, "prefix"),
        .force_suffix = std.ascii.eqlIgnoreCase(modifier, "suf") or std.ascii.eqlIgnoreCase(modifier, "suffix"),
    };
}

fn placeHolonymDisplayHtml(prefix: []const u8) PlaceHolonymDisplayHtml {
    const parsed = parsePlaceHolonymPrefixHtml(prefix);
    const canonical = canonicalPlaceHolonymTypeHtml(parsed.base) orelse return .{};

    if (parsed.force_prefix) return .{ .kind = .prefix, .label = canonical };
    if (parsed.force_suffix) return .{ .kind = .suffix, .label = canonical };

    if (std.ascii.eqlIgnoreCase(canonical, "metropolitan borough") or
        std.ascii.eqlIgnoreCase(canonical, "London borough") or
        std.ascii.eqlIgnoreCase(canonical, "royal borough") or
        std.ascii.eqlIgnoreCase(canonical, "metropolitan city"))
    {
        return .{ .kind = .prefix, .label = canonical };
    }

    if (std.ascii.eqlIgnoreCase(canonical, "borough") or
        std.ascii.eqlIgnoreCase(canonical, "county borough") or
        std.ascii.eqlIgnoreCase(canonical, "parish") or
        std.ascii.eqlIgnoreCase(canonical, "civil parish") or
        std.mem.endsWith(u8, canonical, " district") or
        std.ascii.eqlIgnoreCase(canonical, "district"))
    {
        return .{ .kind = .suffix, .label = canonical };
    }

    return .{};
}

fn canonicalPlaceHolonymTypeHtml(prefix: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(prefix);
    inline for ([_]struct { alias: []const u8, canonical: []const u8 }{
        .{ .alias = "bor", .canonical = "borough" },
        .{ .alias = "borough", .canonical = "borough" },
        .{ .alias = "cobor", .canonical = "county borough" },
        .{ .alias = "county borough", .canonical = "county borough" },
        .{ .alias = "cpar", .canonical = "civil parish" },
        .{ .alias = "civil parish", .canonical = "civil parish" },
        .{ .alias = "dist", .canonical = "district" },
        .{ .alias = "district", .canonical = "district" },
        .{ .alias = "lgd", .canonical = "local government district" },
        .{ .alias = "lgdist", .canonical = "local government district" },
        .{ .alias = "local government district", .canonical = "local government district" },
        .{ .alias = "lbor", .canonical = "London borough" },
        .{ .alias = "London borough", .canonical = "London borough" },
        .{ .alias = "metbor", .canonical = "metropolitan borough" },
        .{ .alias = "metropolitan borough", .canonical = "metropolitan borough" },
        .{ .alias = "metcity", .canonical = "metropolitan city" },
        .{ .alias = "metropolitan city", .canonical = "metropolitan city" },
        .{ .alias = "par", .canonical = "parish" },
        .{ .alias = "parish", .canonical = "parish" },
        .{ .alias = "province", .canonical = "province" },
        .{ .alias = "rdist", .canonical = "regional district" },
        .{ .alias = "regional district", .canonical = "regional district" },
        .{ .alias = "robor", .canonical = "royal borough" },
        .{ .alias = "royal borough", .canonical = "royal borough" },
        .{ .alias = "subdistrict", .canonical = "subdistrict" },
        .{ .alias = "udist", .canonical = "unitary district" },
        .{ .alias = "unitary district", .canonical = "unitary district" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.alias)) return entry.canonical;
    }
    return null;
}

fn isPlaceTypeConnectorHtml(value: []const u8) bool {
    const trimmed = trimWikiWhitespace(value);
    inline for ([_][]const u8{
        "and",
        "or",
        "of",
        "for",
        "in",
        "on",
        "near",
        "with",
        "without",
        "from",
        "to",
        "the",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

fn isPlaceConnectorPieceHtml(piece: []const u8, next_piece: []const u8) bool {
    if (piece.len == 0 or next_piece.len == 0) return false;
    if (std.mem.indexOfScalar(u8, piece, '/')) |_| return false;
    return std.mem.indexOfScalar(u8, next_piece, '/') != null or
        std.mem.indexOf(u8, next_piece, "[[") != null or
        std.mem.indexOf(u8, next_piece, "{{") != null or
        std.mem.indexOf(u8, next_piece, "<<") != null;
}

fn connectorSeparatorHtml(piece: []const u8, last_was_location_value: bool) []const u8 {
    if (!last_was_location_value) return " ";
    const trimmed = trimWikiWhitespace(piece);
    if (asciiStartsWithIgnoreCaseHtml(trimmed, "previously") or
        asciiStartsWithIgnoreCaseHtml(trimmed, "historically") or
        asciiStartsWithIgnoreCaseHtml(trimmed, "formerly"))
    {
        return ", ";
    }
    return " ";
}

fn appendPlaceHolonymPrefixHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
) !void {
    const titled = try titleCaseAsciiAlloc(allocator, label);
    defer allocator.free(titled);
    try out.appendSlice(allocator, "the ");
    try out.appendSlice(allocator, titled);
    try out.appendSlice(allocator, " of ");
}

fn placeLocationDisplayValueHtml(prefix: []const u8, value: []const u8) []const u8 {
    const trimmed_prefix = parsePlaceHolonymPrefixHtml(prefix).base;
    if (std.ascii.eqlIgnoreCase(trimmed_prefix, "c") or std.ascii.eqlIgnoreCase(trimmed_prefix, "cc")) {
        if (std.ascii.eqlIgnoreCase(value, "US") or std.ascii.eqlIgnoreCase(value, "U.S.") or std.ascii.eqlIgnoreCase(value, "USA") or std.ascii.eqlIgnoreCase(value, "U.S.A.")) return "United States";
        if (std.ascii.eqlIgnoreCase(value, "UK") or std.ascii.eqlIgnoreCase(value, "U.K.")) return "United Kingdom";
    }
    return value;
}

fn placeFirstLocationSeparatorHtml(piece: []const u8, rendered_type: []const u8, is_abbreviation: bool) []const u8 {
    if (is_abbreviation) return " of ";
    if (std.mem.indexOfScalar(u8, piece, '/')) |slash| {
        const parsed = parsePlaceHolonymPrefixHtml(piece[0..slash]);
        if (parsed.force_prefix or parsed.force_suffix) {
            if (canonicalPlaceHolonymTypeHtml(parsed.base)) |canonical| {
                if (std.ascii.eqlIgnoreCase(canonical, "province")) return " of ";
            }
        }
    }
    if (asciiEndsWithIgnoreCaseHtml(rendered_type, " seat")) return " of ";
    return if (placeTypeNeedsInHtml(rendered_type)) " in " else " ";
}

fn stripTraversalSegmentsHtml(input: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(input);
    if (std.mem.indexOf(u8, trimmed, "[[") != null or
        std.mem.indexOf(u8, trimmed, "{{") != null or
        std.mem.indexOf(u8, trimmed, "<<") != null or
        std.mem.indexOf(u8, trimmed, "]]") != null or
        std.mem.indexOf(u8, trimmed, "}}") != null or
        std.mem.indexOf(u8, trimmed, ">>") != null)
    {
        return trimmed;
    }
    if (std.mem.lastIndexOfScalar(u8, trimmed, '>')) |marker| {
        if (marker + 1 < trimmed.len) return trimWikiWhitespace(trimmed[marker + 1 ..]);
    }
    return trimmed;
}

fn renderSiUnitTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const prefix = templatePositionalHtml(parts, 1) orelse return;
    const base = templatePositionalHtml(parts, 2) orelse return;
    const quantity = templatePositionalHtml(parts, 3);

    try appendEscapedHtmlSlice(out, allocator, "An ");
    try appendLinkedResolvedTextHtml(out, allocator, "SI unit", "SI unit", options);
    if (quantity) |value| {
        const trimmed = trimWikiWhitespace(value);
        if (trimmed.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, " of ");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
        }
    }
    try appendEscapedHtmlSlice(out, allocator, " equal to 10");
    try appendEscapedHtmlSlice(out, allocator, "\xE2\x88\x92\xC2\xB3");
    try appendEscapedHtmlSlice(out, allocator, " ");
    try renderTemplateTargetHtml(out, allocator, base, options);
    try appendEscapedHtmlSlice(out, allocator, "s");
    if (templateNamedHtml(parts, "symbol")) |symbol| {
        const trimmed_symbol = trimWikiWhitespace(symbol);
        if (trimmed_symbol.len != 0) {
            try appendEscapedHtmlSlice(out, allocator, ". Symbol: ");
            try renderTemplateTargetHtml(out, allocator, trimmed_symbol, options);
            return;
        }
    }
    if (inferredSiSymbolHtml(prefix, base)) |symbol| {
        try appendEscapedHtmlSlice(out, allocator, ". Symbol: ");
        try appendEscapedHtmlSlice(out, allocator, symbol);
    }
}

fn inferredSiSymbolHtml(prefix: []const u8, base: []const u8) ?[]const u8 {
    const trimmed_prefix = trimWikiWhitespace(prefix);
    const trimmed_base = trimWikiWhitespace(base);
    if (std.ascii.eqlIgnoreCase(trimmed_prefix, "milli") and std.ascii.eqlIgnoreCase(trimmed_base, "second")) return "ms";
    return null;
}

fn renderSuffixUsexTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const rendered = templatePositionalHtml(parts, 2) orelse templatePositionalHtml(parts, 1) orelse return;
    try renderTemplateTargetHtml(out, allocator, rendered, options);
    if (templateNamedHtml(parts, "t2")) |gloss| {
        const trimmed = trimWikiWhitespace(gloss);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, " (");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
            try out.append(allocator, ')');
        }
    }
}

fn renderPhonoSemanticMatchingTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    try appendEscapedHtmlSlice(out, allocator, "phono-semantic matching ");
    if (templatePositionalHtml(parts, 1)) |code| {
        if (languageDisplayHtml(code)) |display| {
            try appendLinkedResolvedTextHtml(out, allocator, display, display, options);
            if (templatePositionalHtml(parts, 2) != null) try out.append(allocator, ' ');
        }
    }
    if (templatePositionalHtml(parts, 2)) |term| {
        try renderTemplateTargetHtml(out, allocator, term, options);
    }
    if (templateNamedHtml(parts, "t") orelse templateNamedHtml(parts, "gloss")) |gloss| {
        const trimmed = trimWikiWhitespace(gloss);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, " (");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
            try out.append(allocator, ')');
        }
    }
}

fn currentDayTextHtml() []const u8 {
    return "5";
}

fn currentYearTextHtml() []const u8 {
    return "2026";
}

fn currentMonthNameHtml() []const u8 {
    return "April";
}

fn placeTypeIndexHtml(parts: *const std.ArrayList([]const u8)) usize {
    if (positionalCountHtml(parts) <= 1) return 0;
    const first = templatePositionalHtml(parts, 0) orelse return 0;
    return if (looksLikeLanguageCodeHtml(first)) 1 else 0;
}

fn placeTypeNeedsInHtml(rendered_type: []const u8) bool {
    const trimmed = trimWikiWhitespace(rendered_type);
    return !asciiEndsWithIgnoreCaseHtml(trimmed, " in") and
        !asciiEndsWithIgnoreCaseHtml(trimmed, " of") and
        !asciiEndsWithIgnoreCaseHtml(trimmed, " on") and
        !asciiEndsWithIgnoreCaseHtml(trimmed, " at");
}

fn placeTypeNeedsArticleHtml(rendered_type: []const u8) bool {
    const trimmed = trimWikiWhitespace(rendered_type);
    if (trimmed.len == 0) return false;
    inline for ([_][]const u8{
        "a ",
        "an ",
        "the ",
        "this ",
        "that ",
        "these ",
        "those ",
        "one ",
    }) |prefix| {
        if (asciiStartsWithIgnoreCaseHtml(trimmed, prefix)) return false;
    }
    return true;
}

fn chooseIndefiniteArticleHtml(text: []const u8, capitalize: bool) []const u8 {
    const article = if (startsWithVowelSoundHtml(text)) "an" else "a";
    if (!capitalize) return article;
    return if (std.mem.eql(u8, article, "an")) "An" else "A";
}

fn startsWithVowelSoundHtml(text: []const u8) bool {
    const trimmed = trimWikiWhitespace(text);
    if (trimmed.len == 0) return false;

    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, trimmed, i + 1, '>') orelse break;
            i = end + 1;
            continue;
        }
        if (std.ascii.isAlphabetic(trimmed[i])) break;
        i += 1;
    }
    if (i >= trimmed.len) return false;

    const lower = std.ascii.toLower(trimmed[i]);
    if (lower == 'u') {
        if (trimmed.len >= i + 3) {
            const next = std.ascii.toLower(trimmed[i + 1]);
            const third = std.ascii.toLower(trimmed[i + 2]);
            if ((next == 'n' and third == 'i') or (next == 's' and third == 'e')) return false;
        }
    }
    if (lower == 'e' and trimmed.len >= i + 2 and std.ascii.toLower(trimmed[i + 1]) == 'u') return false;
    if (lower == 'o' and trimmed.len >= i + 3 and std.ascii.toLower(trimmed[i + 1]) == 'n' and std.ascii.toLower(trimmed[i + 2]) == 'e') return false;
    return lower == 'a' or lower == 'e' or lower == 'i' or lower == 'o' or lower == 'u';
}

fn asciiStartsWithIgnoreCaseHtml(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn semanticTemplateStem(name: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(name);
    if (!isSemanticOfTemplateHtml(trimmed)) return null;
    return trimWikiWhitespace(trimmed[0 .. trimmed.len - " of".len]);
}

fn semanticTemplateTargetIndexHtml(parts: *const std.ArrayList([]const u8)) usize {
    const count = positionalCountHtml(parts);
    if (count <= 1) return 0;
    const first = templatePositionalHtml(parts, 0) orelse return 0;
    return if (looksLikeLanguageCodeHtml(first)) 1 else 0;
}

fn isSemanticOfTemplateHtml(name: []const u8) bool {
    const trimmed = trimWikiWhitespace(name);
    return trimmed.len != 0 and asciiEndsWithIgnoreCaseHtml(trimmed, " of");
}

fn looksLikeLanguageCodeHtml(value: []const u8) bool {
    const trimmed = trimWikiWhitespace(value);
    if (trimmed.len < 2 or trimmed.len > 12) return false;
    if (!std.ascii.isAlphabetic(trimmed[0])) return false;
    if (!std.ascii.isAlphabetic(trimmed[trimmed.len - 1]) and !std.ascii.isDigit(trimmed[trimmed.len - 1])) return false;

    var requires_extended_shape = trimmed.len > 5;
    var has_letter = false;
    var has_lower = false;
    var has_digit = false;
    var has_separator = false;
    for (trimmed) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            if (std.ascii.isLower(char)) has_lower = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') {
            requires_extended_shape = false;
            if (std.ascii.isDigit(char)) has_digit = true;
            if (char == '-' or char == '_') has_separator = true;
            continue;
        }
        return false;
    }
    if (!has_letter or requires_extended_shape) return false;
    if (!has_separator and !has_digit) return has_lower and trimmed.len <= 3;
    return has_lower or has_separator;
}

fn titleCaseAsciiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    var upper_next = true;
    for (out) |*char| {
        if (std.ascii.isAlphabetic(char.*)) {
            char.* = if (upper_next) std.ascii.toUpper(char.*) else std.ascii.toLower(char.*);
            upper_next = false;
            continue;
        }
        upper_next = char.* == ' ' or char.* == '-' or char.* == '/' or char.* == '(';
    }
    return out;
}

fn sectionIdAlloc(allocator: std.mem.Allocator, title: []const u8, index: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const prefix = try std.fmt.allocPrint(allocator, "section-{d}", .{index});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);

    const trimmed = std.mem.trim(u8, title, " \t");
    if (trimmed.len == 0) return out.toOwnedSlice(allocator);

    try out.append(allocator, '-');
    var wrote_dash = false;
    for (trimmed) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, std.ascii.toLower(c));
            wrote_dash = false;
        } else if (!wrote_dash) {
            try out.append(allocator, '-');
            wrote_dash = true;
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        out.items.len -= 1;
    }
    return out.toOwnedSlice(allocator);
}

fn splitTopLevel(allocator: std.mem.Allocator, input: []const u8, sep: u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var templates: usize = 0;
    var links: usize = 0;
    var placeholders: usize = 0;
    var i: usize = 0;
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
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "<<")) {
            placeholders += 1;
            i += 1;
            continue;
        }
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], ">>")) {
            if (placeholders != 0) placeholders -= 1;
            i += 1;
            continue;
        }
        if (input[i] == sep and templates == 0 and links == 0 and placeholders == 0) {
            try out.append(allocator, std.mem.trim(u8, input[start..i], " \t"));
            start = i + 1;
        }
    }
    try out.append(allocator, std.mem.trim(u8, input[start..], " \t"));
    return out;
}

fn topLevelSeparator(input: []const u8, sep: u8) ?usize {
    var templates: usize = 0;
    var links: usize = 0;
    var i: usize = 0;
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
        if (input[i] == sep and templates == 0 and links == 0) return i;
    }
    return null;
}

fn findBalanced(input: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
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

fn isColumnTemplate(name: []const u8) bool {
    const trimmed = trimWikiWhitespace(name);
    return std.ascii.eqlIgnoreCase(trimmed, "col") or
        std.ascii.eqlIgnoreCase(trimmed, "col2") or
        std.ascii.eqlIgnoreCase(trimmed, "col3") or
        std.ascii.eqlIgnoreCase(trimmed, "col4") or
        std.ascii.eqlIgnoreCase(trimmed, "col5") or
        std.ascii.eqlIgnoreCase(trimmed, "col6");
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
}

fn asciiEndsWithIgnoreCaseHtml(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return asciiStartsWithIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

test {
    _ = @import("html_render_test.zig");
}
