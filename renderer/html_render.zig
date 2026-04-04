const std = @import("std");

const wikitext = @import("wikitext_runtime.zig");
const xml_decode = @import("xml_decode.zig");

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
            try flushPendingSection(allocator, &rendered_sections, &pending, options);
            pending.level = if (heading.level == 2) 1 else heading.level;
            pending.title = if (heading.level == 2) "" else heading.title;
            pending.first_line_number = line_number + 1;
            continue;
        }

        if (pending.first_line_number == 0) pending.first_line_number = line_number;
        if (pending.body.items.len != 0) try pending.body.append(allocator, '\n');
        try pending.body.appendSlice(allocator, raw_line);
    }

    try flushPendingSection(allocator, &rendered_sections, &pending, options);
    return rendered_sections.toOwnedSlice(allocator);
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
    const source = if (std.ascii.eqlIgnoreCase(title, "Gallery"))
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
    if (containsResidualMarkup(trimmed)) {
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

        if (looksLikeStructuredInline(segment)) {
            const rendered = try renderInlineHtmlToOwned(allocator, segment, .{});
            defer allocator.free(rendered);
            try pushRenderedTerms(&terms, allocator, rendered);
        } else {
            const rendered = try renderPhraseHtmlAlloc(allocator, trimWikiWhitespace(segment), .{});
            defer allocator.free(rendered);
            try pushRenderedTerms(&terms, allocator, rendered);
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
                pending = .empty;
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
                pending = .empty;
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

        if (pending.items.len != 0) {
            try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            balance.update(raw_line);
            if (balance.isOpen()) {
                current_line_number += 1;
                continue;
            }

            try lines_out.append(allocator, .{
                .text = try pending.toOwnedSlice(allocator),
                .line_number = pending_start_line,
            });
            pending = .empty;
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
            .text = try allocator.dupe(u8, raw_line),
            .line_number = current_line_number,
        });
        current_line_number += 1;
    }

    if (pending.items.len != 0) {
        if (options.strict) {
            return failStrict(title, pending_start_line, pending.items, "logical line ended with unbalanced markup", .unbalanced_markup, options);
        }
        try lines_out.append(allocator, .{ .text = try pending.toOwnedSlice(allocator), .line_number = pending_start_line });
    }

    return .{ .items = try lines_out.toOwnedSlice(allocator) };
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
            if (std.mem.indexOfScalarPos(u8, input, i + 1, ']')) |end| {
                if (std.mem.startsWith(u8, input[i + 1 ..], "http")) {
                    const body = input[i + 1 .. end];
                    if (std.mem.indexOfScalar(u8, body, ' ')) |space| {
                        try validateInlineStrict(body[space + 1 ..], title, line_number, options);
                    }
                    i = end + 1;
                    continue;
                }
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
    const sep = std.mem.indexOfScalar(u8, trimmed, '|') orelse trimmed.len;
    return trimWikiWhitespace(trimmed[0..sep]);
}

fn isStrictSupportedTemplateBody(body: []const u8) bool {
    const name = strictTemplateName(body);
    return isStrictSupportedTemplateName(name);
}

fn isStrictSupportedTemplateName(name: []const u8) bool {
    const trimmed = trimWikiWhitespace(name);
    if (trimmed.len == 0) return false;
    if (asciiStartsWithIgnoreCase(trimmed, "quote-")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "cite-")) return true;
    if (std.mem.startsWith(u8, trimmed, "RQ:")) return true;
    if (std.mem.startsWith(u8, trimmed, "R:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "table:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "U:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "Wiktionary:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "list:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "en-")) return true;
    if (std.mem.endsWith(u8, trimmed, " of")) return true;
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
        "cot",
        "coord",
        "coordinate terms",
        "confix",
        "con",
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
        "good",
        "frac",
        "gloss",
        "glossary",
        "gbooks",
        "given name",
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
        "wikiquote",
        "wp",
        "w",
        "&lit",
        "'",
        "...",
        "+obj",
        "attn",
        "B.C.E.",
        "box-bottom",
        "box-top",
        "calque",
        "C.E.",
        "coin",
        "coinage",
        "compound+",
        "clipping",
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
        "altform",
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
        "ethnologue",
        "emojipic",
        "img",
        "inline alt forms",
        "letter_disp2",
        "mdash",
        "n-g",
        "nearsyn",
        "nsyn",
        "nyms",
        "quote",
        "qf",
        "q-g",
        "senseno",
        "section link",
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
        "attention",
        "bottom",
        "col-top",
        "inherited",
        "ll",
        "long s",
        "lena",
        "ltc-l",
        "merge",
        "multiple image",
        "obs form",
        "onom",
        "rfclarify",
        "rfd-sense",
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
        "sub",
        "semantic loan",
        "tea room",
        "top2",
        "top3",
        "top4",
        "transterm",
        "topics",
        "tlb",
        "univ",
        "used in phrasal verbs",
        "upright",
        "wikiversity",
        "wikinews",
        "zh-l",
        "zh-m",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

fn shouldSkipStrictTemplateArgValidation(name: []const u8) bool {
    if (asciiStartsWithIgnoreCase(name, "table:")) return true;
    if (asciiStartsWithIgnoreCase(name, "U:")) return true;
    if (asciiStartsWithIgnoreCase(name, "Wiktionary:")) return true;
    inline for ([_][]const u8{
        "arithmetic operations",
        "bottom",
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
        "rfi",
        "rfref",
        "rfv",
        "rfv-pron",
        "rfv-etym",
        "rfv-sense",
        "season name spelling",
        "seeCites",
        "see desc",
        "seeSynonyms",
        "seemoreCites",
        "specieslite",
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
        "interwiktionary",
        "swp",
        "commons",
        "commonscat",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
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
    var parts = std.mem.splitAny(u8, rendered, ",;");
    while (parts.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
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
        if (input[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, input, i + 1, ']')) |end| {
                if (std.mem.startsWith(u8, input[i + 1 ..], "http")) {
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
            if (asciiStartsWithIgnoreCase(input[i..], "<br") or asciiStartsWithIgnoreCase(input[i..], "<hr")) {
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
            if (shouldKeepLiteralApostrophe(input, run_start, i - run_start)) {
                try out.append(allocator, '\'');
            }
            plain_start = i;
            continue;
        }
        i += 1;
    }
    try appendDecodedEscapedChunk(out, allocator, input[plain_start..]);
}

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
    if (templateMatchesHtml(name, "rhymes") or templateMatchesHtml(name, "rhyme")) {
        try renderRhymesTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "alti")) {
        try renderAlternativeFormsTemplateHtml(out, allocator, &parts, options);
        return;
    }
    if (isEtymologyLexemeTemplateHtml(name)) {
        try renderEtymologyLexemeTemplateHtml(out, allocator, name, &parts, options);
        return;
    }
    if (templateMatchesHtml(name, "compound") or templateMatchesHtml(name, "compound+") or templateMatchesHtml(name, "com") or templateMatchesHtml(name, "com+")) {
        try renderCompoundTemplateHtml(out, allocator, &parts, options);
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
    if (templateMatchesHtml(name, "l") or templateMatchesHtml(name, "m") or templateMatchesHtml(name, "m+") or templateMatchesHtml(name, "link")) {
        try renderLexemeLikeTemplateHtml(out, allocator, &parts, 1, options);
        return;
    }
    if (templateMatchesHtml(name, "cog") or templateMatchesHtml(name, "noncog")) {
        try renderLanguageAwareLexemeTemplateHtml(out, allocator, &parts, 0, 1, options);
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
    if (templateMatchesHtml(name, "lb") or templateMatchesHtml(name, "lbl") or templateMatchesHtml(name, "label") or templateMatchesHtml(name, "q") or templateMatchesHtml(name, "qualifier") or templateMatchesHtml(name, "i") or templateMatchesHtml(name, "term-label") or templateMatchesHtml(name, "gl")) {
        try appendParenthesizedTemplateArgs(out, allocator, &parts, if (templateMatchesHtml(name, "lb") or templateMatchesHtml(name, "lbl") or templateMatchesHtml(name, "label")) 1 else 0, options);
        return;
    }
    if (templateMatchesHtml(name, "surf")) {
        try appendEscapedHtmlSlice(out, allocator, "By surface analysis, ");
        try appendPositionalTemplateTargetsHtml(out, allocator, &parts, 1, " + ", options);
        return;
    }
    if (templateMatchesHtml(name, "doublet")) {
        try appendEscapedHtmlSlice(out, allocator, "Doublet of ");
        if (templatePositionalHtml(&parts, 1) orelse templatePositionalHtml(&parts, 0)) |arg| {
            try renderTemplateTargetHtml(out, allocator, arg, options);
        }
        return;
    }

    const wrapped = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{body});
    defer allocator.free(wrapped);
    const text = try wikitext.renderWikitextToOwned(allocator, wrapped, max_render_line_bytes);
    defer allocator.free(text);
    if (text.len == 0) return;
    try appendEscapedHtmlSlice(out, allocator, text);
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

    try appendExpandedTemplatePrefix(out, allocator, expansion, options);
    if (templateTargetHtmlArg(parts)) |target| {
        try renderTemplateTargetHtml(out, allocator, target, options);
    }

    const target_index = semanticTemplateTargetIndexHtml(parts);
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
    return true;
}

fn renderSemanticTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const stem = semanticTemplateStem(name) orelse return;
    const link_target = if (std.mem.indexOfScalar(u8, stem, ' ') == null and std.mem.indexOfScalar(u8, stem, '-') == null)
        stem
    else
        null;

    try appendLinkedResolvedTextHtml(out, allocator, stem, link_target orelse stem, options);
    try appendEscapedHtmlSlice(out, allocator, " of ");

    const target_index = semanticTemplateTargetIndexHtml(parts);
    if (templatePositionalHtml(parts, target_index)) |target| {
        try renderTemplateTargetHtml(out, allocator, target, options);
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
        .{ .name = "abbr", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbr of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbrev", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbrev of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "abbreviation of", .display = "Abbreviation", .link_target = "abbreviation", .tail = " of " },
        .{ .name = "acronym", .display = "Acronym", .link_target = "acronym", .tail = " of " },
        .{ .name = "contraction", .display = "Contraction", .link_target = "contraction", .tail = " of " },
        .{ .name = "clip", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "clipping", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "clipping of", .display = "Clipping", .link_target = "clipping", .tail = " of " },
        .{ .name = "back-form", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "back-formation", .display = "Back-formation", .link_target = "back-formation", .tail = " from " },
        .{ .name = "alt form", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "alt form of", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "altform", .display = "Alternative form", .link_target = null, .tail = " of " },
        .{ .name = "alt sp", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt sp of", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt spell", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt spelling of", .display = "Alternative spelling", .link_target = null, .tail = " of " },
        .{ .name = "alt case", .display = "Alternative case form", .link_target = null, .tail = " of " },
        .{ .name = "obs form", .display = "Obsolete form", .link_target = null, .tail = " of " },
        .{ .name = "short for", .display = "Short", .link_target = null, .tail = " for " },
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

fn appendExpandedTemplatePrefix(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    expansion: TemplateExpansion,
    options: RenderOptions,
) !void {
    try appendLinkedResolvedTextHtml(out, allocator, expansion.display, expansion.link_target orelse expansion.display, options);
    try appendEscapedHtmlSlice(out, allocator, expansion.tail);
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

fn renderTemplateTargetHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw_target: []const u8,
    options: RenderOptions,
) anyerror!void {
    const trimmed = trimWikiWhitespace(raw_target);
    if (trimmed.len == 0) return;
    if (looksLikeStructuredInline(trimmed)) {
        try renderInlineHtml(out, allocator, trimmed, options);
        return;
    }
    try renderPhraseHtml(out, allocator, trimmed, options);
}

fn renderPhraseHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    phrase: []const u8,
    options: RenderOptions,
) anyerror!void {
    const target = try resolveLinkTargetAlloc(allocator, phrase, options);
    defer if (target) |value| allocator.free(value);
    if (target != null) {
        try appendLinkMaybe(out, allocator, target, phrase, options);
        return;
    }

    if (try externalWikiHrefAlloc(allocator, phrase)) |href| {
        defer allocator.free(href);
        const display = normalizedWikiTarget(phrase);
        try appendHrefHtml(out, allocator, href, if (display.len != 0) display else phrase, options);
        return;
    }

    try appendLinkMaybe(out, allocator, target, phrase, options);
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
    try renderTemplateTargetHtml(out, allocator, term, options);
    try appendTemplateGlossHtml(out, allocator, parts, term_index, term, options);
}

fn renderEtymologyLexemeTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const term = templateEtymologyTermHtml(parts) orelse return;
    if (isPlaceholderTemplateTermHtml(term)) return;

    if (templateMatchesHtml(name, "bor+") or templateMatchesHtml(name, "borrowed")) {
        try appendEscapedHtmlSlice(out, allocator, "borrowed from ");
    } else if (templateMatchesHtml(name, "inh+") or templateMatchesHtml(name, "inherited")) {
        try appendEscapedHtmlSlice(out, allocator, "inherited from ");
    } else if (templateMatchesHtml(name, "der+") or templateMatchesHtml(name, "derived") or templateMatchesHtml(name, "uder")) {
        try appendEscapedHtmlSlice(out, allocator, "derived from ");
    }

    if (templatePositionalHtml(parts, 1)) |code| {
        if (languageDisplayHtml(code)) |display| {
            try appendResolvedDisplayTargetHtml(out, allocator, display, display, options);
            try out.append(allocator, ' ');
        }
    }

    const display = templateNamedHtml(parts, "alt") orelse term;
    try appendResolvedDisplayTargetHtml(out, allocator, display, term, options);
    try appendTemplateGlossHtml(out, allocator, parts, 2, term, options);
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
    try renderLexemeLikeTemplateHtml(out, allocator, parts, term_index, options);
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
        templateTrailingGlossHtml(parts, term);
    if (translit == null and gloss == null) return;

    try out.appendSlice(allocator, " (");
    if (translit) |value| {
        try renderTemplateTargetHtml(out, allocator, value, options);
        if (gloss != null) try out.appendSlice(allocator, ", ");
    }
    if (gloss) |value| try appendQuotedTemplateTargetHtml(out, allocator, value, options);
    try out.appendSlice(allocator, ")");
}

fn renderCompoundTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    const total = positionalCountHtml(parts);
    if (total == 0) return;

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
        try renderCompoundTermHtml(out, allocator, parts, positional_index, trimmed, options);
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

fn renderCompoundTermHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    parts: *const std.ArrayList([]const u8),
    term_slot: usize,
    fallback_term: []const u8,
    options: RenderOptions,
) anyerror!void {
    var key_buf: [16]u8 = undefined;
    const alt_name = try std.fmt.bufPrint(&key_buf, "alt{d}", .{term_slot});
    const display = templateNamedHtml(parts, alt_name) orelse fallback_term;
    try appendResolvedDisplayTargetHtml(out, allocator, display, fallback_term, options);

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

fn templateLexemeGlossHtml(parts: *const std.ArrayList([]const u8), term_index: usize) ?[]const u8 {
    const count = positionalCountHtml(parts);
    if (count <= term_index + 2) return null;
    const bridge = templatePositionalHtml(parts, term_index + 1) orelse "";
    if (trimWikiWhitespace(bridge).len != 0) return null;
    return templatePositionalHtml(parts, term_index + 2);
}

fn templateTrailingGlossHtml(parts: *const std.ArrayList([]const u8), term: []const u8) ?[]const u8 {
    if (isPlaceholderTemplateTermHtml(term)) return null;
    const count = positionalCountHtml(parts);
    if (count <= 2) return null;
    const candidate = templatePositionalHtml(parts, count - 1) orelse return null;
    const trimmed = trimWikiWhitespace(candidate);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, trimWikiWhitespace(term)) or looksLikeLanguageCodeHtml(trimmed)) return null;
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

    if (templatePositionalHtml(parts, 1)) |qualifier| {
        const trimmed = trimWikiWhitespace(qualifier);
        if (trimmed.len != 0 and !looksLikeLanguageCodeHtml(trimmed)) {
            try renderTemplateTargetHtml(&phrase, allocator, trimmed, options);
            if (phrase.items.len != 0) try phrase.append(allocator, ' ');
        }
    }
    try appendEscapedHtmlSlice(&phrase, allocator, noun);

    try out.appendSlice(allocator, chooseIndefiniteArticleHtml(phrase.items, true));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, phrase.items);
    if (templateNamedHtml(parts, "from")) |source| {
        const trimmed = trimWikiWhitespace(source);
        if (trimmed.len != 0) {
            try out.appendSlice(allocator, " from ");
            try renderTemplateTargetHtml(out, allocator, trimmed, options);
        }
    }
}

fn renderQuoteTemplateHtml(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    parts: *const std.ArrayList([]const u8),
    options: RenderOptions,
) anyerror!void {
    var wrote_meta = false;

    if (templateNamedHtml(parts, "date") orelse templateNamedHtml(parts, "year")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "author")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    } else if (std.mem.startsWith(u8, name, "RQ:")) {
        const label = trimWikiWhitespace(name["RQ:".len..]);
        if (label.len != 0) try appendQuoteMetaPartHtml(out, allocator, label, &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "title")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "chapter")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "work")) |value| {
        try appendQuoteMetaPartHtml(out, allocator, trimmedQuoteMetaValue(value), &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "page")) |value| {
        const rendered = try std.fmt.allocPrint(allocator, "page {s}", .{trimWikiWhitespace(value)});
        defer allocator.free(rendered);
        try appendQuoteMetaPartHtml(out, allocator, rendered, &wrote_meta, options);
    }
    if (templateNamedHtml(parts, "column")) |value| {
        const rendered = try std.fmt.allocPrint(allocator, "column {s}", .{trimWikiWhitespace(value)});
        defer allocator.free(rendered);
        try appendQuoteMetaPartHtml(out, allocator, rendered, &wrote_meta, options);
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

fn trimmedQuoteMetaValue(value: []const u8) []const u8 {
    return trimWikiWhitespace(value);
}

fn languageDisplayHtml(code: []const u8) ?[]const u8 {
    const trimmed = trimWikiWhitespace(code);
    inline for ([_]struct { code: []const u8, display: []const u8 }{
        .{ .code = "ang", .display = "Old English" },
        .{ .code = "cs", .display = "Czech" },
        .{ .code = "da", .display = "Danish" },
        .{ .code = "de", .display = "German" },
        .{ .code = "en", .display = "English" },
        .{ .code = "enm", .display = "Middle English" },
        .{ .code = "fr", .display = "French" },
        .{ .code = "frm", .display = "Middle French" },
        .{ .code = "fro", .display = "Old French" },
        .{ .code = "fy", .display = "West Frisian" },
        .{ .code = "gem-pro", .display = "Proto-Germanic" },
        .{ .code = "gmw-pro", .display = "Proto-West Germanic" },
        .{ .code = "grc", .display = "Ancient Greek" },
        .{ .code = "grc-koi", .display = "Koine Greek" },
        .{ .code = "ine-pro", .display = "Proto-Indo-European" },
        .{ .code = "la", .display = "Latin" },
        .{ .code = "ML.", .display = "Medieval Latin" },
        .{ .code = "nds", .display = "Low German" },
        .{ .code = "NL.", .display = "New Latin" },
        .{ .code = "nl", .display = "Dutch" },
        .{ .code = "no", .display = "Norwegian" },
        .{ .code = "non", .display = "Old Norse" },
        .{ .code = "pl", .display = "Polish" },
        .{ .code = "sa", .display = "Sanskrit" },
        .{ .code = "sh", .display = "Serbo-Croatian" },
        .{ .code = "sv", .display = "Swedish" },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.code)) return entry.display;
    }
    return null;
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
    try appendPronunciationValuesHtml(out, allocator, parts, 1, ", ", .{
        .prepend_hyphen = true,
        .link_prefix = "Rhymes:English/",
    }, options);
}

const TrailingQualifierHtml = struct {
    term: []const u8,
    qualifier: ?[]const u8 = null,
};

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

fn splitTrailingQualifierHtml(raw: []const u8) TrailingQualifierHtml {
    const trimmed = trimWikiWhitespace(raw);
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '>') return .{ .term = trimmed };
    const tag_start = std.mem.lastIndexOf(u8, trimmed, "<q:") orelse return .{ .term = trimmed };
    if (tag_start == 0 or tag_start >= trimmed.len - 1) return .{ .term = trimmed };
    const qualifier = trimWikiWhitespace(trimmed[tag_start + 3 .. trimmed.len - 1]);
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
    const rendered_type_text = try renderPlaceTypeTextHtmlAlloc(allocator, raw_type);
    defer allocator.free(rendered_type_text);
    if (rendered_type_text.len == 0) return;

    if (placeTypeNeedsArticleHtml(rendered_type_text)) {
        try out.appendSlice(allocator, chooseIndefiniteArticleHtml(rendered_type_text, true));
        try out.append(allocator, ' ');
    }
    try renderPlaceTypeHtml(out, allocator, raw_type, options);

    var wrote_location = false;
    var last_was_location_value = false;
    const positional_total = positionalCountHtml(parts);
    var positional_index = type_index + 1;
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
            try out.appendSlice(allocator, if (placeTypeNeedsInHtml(rendered_type_text)) " in " else " ");
            wrote_location = true;
        } else {
            try out.appendSlice(allocator, ", ");
        }
        try renderPlaceLocationFragmentHtml(out, allocator, trimmed, options);
        last_was_location_value = true;
    }

    for ([_][]const u8{ "official", "capital", "located", "located in", "caplc" }) |key| {
        if (templateNamedHtml(parts, key)) |value| {
            const trimmed = trimWikiWhitespace(stripTraversalSegmentsHtml(value));
            if (trimmed.len == 0) continue;
            if (wrote_location) {
                try out.appendSlice(allocator, "; ");
            } else {
                try out.append(allocator, ' ');
                wrote_location = true;
            }
            try renderPlaceLocationFragmentHtml(out, allocator, trimmed, options);
        }
    }
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
        const display = placeHolonymDisplayHtml(prefix);
        switch (display.kind) {
            .plain => {
                try renderTemplateTargetHtml(out, allocator, value, options);
            },
            .prefix => {
                try appendPlaceHolonymPrefixHtml(out, allocator, display.label);
                try renderTemplateTargetHtml(out, allocator, value, options);
            },
            .suffix => {
                try renderTemplateTargetHtml(out, allocator, value, options);
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, display.label);
            },
        }
        return;
    }

    try renderPhraseHtml(out, allocator, input, options);
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
        std.mem.indexOf(u8, input, "<ref") != null;
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
    else
        return null;

    return try buildExternalWikiHrefAlloc(allocator, base, page);
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
        if (std.ascii.isAlphanumeric(normalized) or normalized == '-' or normalized == '_' or normalized == '.' or normalized == '~' or normalized == '(' or normalized == ')') {
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
    return std.ascii.eqlIgnoreCase(trimWikiWhitespace(name), expected);
}

fn isEtymologyLexemeTemplateHtml(name: []const u8) bool {
    return templateMatchesHtml(name, "inh") or
        templateMatchesHtml(name, "inh+") or
        templateMatchesHtml(name, "der") or
        templateMatchesHtml(name, "der+") or
        templateMatchesHtml(name, "bor") or
        templateMatchesHtml(name, "bor+") or
        templateMatchesHtml(name, "lbor") or
        templateMatchesHtml(name, "uder") or
        templateMatchesHtml(name, "ncog");
}

fn isPlaceholderTemplateTermHtml(term: []const u8) bool {
    const trimmed = trimWikiWhitespace(term);
    return std.mem.eql(u8, trimmed, "-") or std.mem.eql(u8, trimmed, "—");
}

fn positionalCountHtml(parts: *const std.ArrayList([]const u8)) usize {
    var count: usize = 0;
    for (parts.items[1..]) |segment| {
        if (!templateArgHasName(segment)) count += 1;
    }
    return count;
}

fn templatePositionalHtml(parts: *const std.ArrayList([]const u8), target: usize) ?[]const u8 {
    var positional_index: usize = 0;
    for (parts.items[1..]) |segment| {
        if (templateArgHasName(segment)) continue;
        if (positional_index == target) return trimWikiWhitespace(segment);
        positional_index += 1;
    }
    return null;
}

fn templateTargetHtmlArg(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
    const count = positionalCountHtml(parts);
    if (count == 0) return null;
    if (count >= 2) return templatePositionalHtml(parts, count - 1);
    return templatePositionalHtml(parts, 0);
}

fn templateEtymologyTermHtml(parts: *const std.ArrayList([]const u8)) ?[]const u8 {
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

fn placeHolonymDisplayHtml(prefix: []const u8) PlaceHolonymDisplayHtml {
    const canonical = canonicalPlaceHolonymTypeHtml(prefix) orelse return .{};

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

fn stripTraversalSegmentsHtml(input: []const u8) []const u8 {
    const trimmed = trimWikiWhitespace(input);
    if (std.mem.lastIndexOfScalar(u8, trimmed, '>')) |marker| {
        if (marker + 1 < trimmed.len) return trimWikiWhitespace(trimmed[marker + 1 ..]);
    }
    return trimmed;
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
    while (i < trimmed.len and !std.ascii.isAlphabetic(trimmed[i])) : (i += 1) {}
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

    var requires_extended_shape = trimmed.len > 5;
    var has_letter = false;
    for (trimmed) |char| {
        if (std.ascii.isAlphabetic(char)) {
            has_letter = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '-' or char == '_') {
            requires_extended_shape = false;
            continue;
        }
        return false;
    }
    return has_letter and !requires_extended_shape;
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
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col2") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col3") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col4") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col5") or
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col6");
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

test "renderEnglishSectionAlloc renders part-of-speech senses without raw templates" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{en-noun}}
        \\# {{lb|en|physical}} A [[round]] object.
        \\## A [[ring]] worn on the finger.
        \\##: {{ux|en|a gold ring}}
        \\
        \\====Derived terms====
        \\{{col4|en|wedding ring|ring finger|signet ring}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<ol class=\"render-sense-list\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A round object.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "<ul class=\"render-term-grid\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "wedding ring") != null);
}

test "renderEnglishSectionAlloc strips gallery filenames and keeps captions" {
    const source =
        \\==English==
        \\
        \\===Gallery===
        \\<gallery mode=packed>
        \\Image:Finger ring.jpg|A '''ring''' on a finger.
        \\Image:Tree rings.jpg|The '''rings''' of a tree.
        \\</gallery>
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Finger ring.jpg") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A ring on a finger.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The rings of a tree.") != null);
}

test "renderEnglishSectionAlloc accepts place and etymology helpers in strict mode" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{der|en|fro|encloyer}}.
        \\
        \\===Proper noun===
        \\# {{place|en|country|c/Brazil|official=Republic of Brazil}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Old French encloyer") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "A country in Brazil") != null);
}

test "renderEnglishSectionAlloc expands etymology borrowing and compound helpers with gloss detail" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{bor|en|frm|portemanteau||coat stand}}, from {{compound|frm|nocat=1|porter|alt1=porte|t1=carries|pos1=third-person singular present indicative of {{m|frm|porter|t=to carry}}|manteau|t2=coat|lit=[that which] carries coat}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "Middle French", "portemanteau", "porter", "manteau" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(sections[0].html.len != 0);
}

test "renderEnglishSectionAlloc preserves form-of template labels" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|Fresnel reflection}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "plural of Fresnel reflection") != null);
}

test "renderEnglishSectionAlloc preserves wiki link trails and alternative-form qualifiers" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# A [[travel]]ling [[case]].
        \\#: {{alti|en|portemanteau|portmantua<q:obsolete>}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "travelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Alternative forms:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "(obsolete) portmantua") != null);
}

const TestResolverContext = struct {
    terms: []const []const u8,
};

fn resolveTestLink(context: *const anyopaque, allocator: std.mem.Allocator, term: []const u8) !?[]const u8 {
    const resolver: *const TestResolverContext = @ptrCast(@alignCast(context));
    for (resolver.terms) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, trimWikiWhitespace(term))) {
            return @as([]const u8, try allocator.dupe(u8, candidate));
        }
    }
    return null;
}

test "renderEnglishSectionAlloc links expanded shorthand form templates" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|Fresnel reflection}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "plural", "Fresnel reflection" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/plural\">plural</a> of <a href=\"/entry/Fresnel%20reflection\">Fresnel reflection</a>") != null);
}

test "renderEnglishSectionAlloc expands init of and preserves nested wiki links" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{init of|en|[[aeronautical|Aeronautical]] [[systems|Systems]] [[division|Division]]}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "initialism", "Aeronautical", "Systems", "Division" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/initialism\">Initialism</a> of <a href=\"/entry/Aeronautical\">Aeronautical</a> <a href=\"/entry/Systems\">Systems</a> <a href=\"/entry/Division\">Division</a>") != null);
}

test "renderEnglishSectionAlloc expands shorthand template families into full labels" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{abbr of|en|aeronautical systems division}}
        \\# {{back-form|en|escalator}}
        \\# {{alt sp|en|colour}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "abbreviation", "aeronautical systems division", "back-formation", "escalator", "colour" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/abbreviation\">Abbreviation</a> of <a href=\"/entry/aeronautical%20systems%20division\">aeronautical systems division</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/back-formation\">Back-formation</a> from <a href=\"/entry/escalator\">escalator</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Alternative spelling of <a href=\"/entry/colour\">colour</a>") != null);
}

test "renderEnglishSectionAlloc formats place and surname definitions like sentence glosses" {
    const source =
        \\==English==
        \\{{wp}}
        \\
        \\===Proper noun===
        \\{{en-proper noun}}
        \\
        \\# {{place|en|hamlet|par/Ipplepen|dist/Teignbridge|co/Devon|cc/England}} {{q|[[OS]] grid ref SX8566}}.
        \\# {{surname|en}}.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A hamlet in Ipplepen parish, Teignbridge district, Devon, England (OS grid ref SX8566).") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A surname.") != null);
}

test "renderEnglishSectionAlloc preserves nominal template origins" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{surname|en|habitational|from=Old Norse}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "Old Norse" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A habitational surname from <a href=\"/entry/Old%20Norse\">Old Norse</a>") != null);
}

test "renderEnglishSectionAlloc links place holonyms from place template fragments" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|town|metbor/Knowsley|co/Merseyside|cc/England}} {{q|[[OS]] grid ref SJ4491}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "town", "Knowsley", "Merseyside", "England", "OS" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/town\">town</a> in the Metropolitan Borough of <a href=\"/entry/Knowsley\">Knowsley</a>, <a href=\"/entry/Merseyside\">Merseyside</a>, <a href=\"/entry/England\">England</a> (<a href=\"/entry/OS\">OS</a> grid ref SJ4491).") != null);
}

test "renderEnglishSectionAlloc expands combined place type shorthands" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|village/and/cpar|in|co/North Yorkshire|cc/England|previously in|dist/Hambleton}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "village", "civil parish", "North Yorkshire", "England", "Hambleton" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(
        u8,
        sections[0].html,
        "A <a href=\"/entry/village\">village</a> and <a href=\"/entry/civil%20parish\">civil parish</a> in <a href=\"/entry/North%20Yorkshire\">North Yorkshire</a>, <a href=\"/entry/England\">England</a>, previously in <a href=\"/entry/Hambleton\">Hambleton</a> district",
    ) != null);
}

test "renderEnglishSectionAlloc does not prepend an indefinite article to determiner-led place text" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|The largest and most populous <<constituent country>> of the <<c/United Kingdom>>}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "constituent country", "United Kingdom" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A The largest") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The largest and most populous <a href=\"/entry/constituent%20country\">constituent country</a> of the <a href=\"/entry/United%20Kingdom\">United Kingdom</a>") != null);
}

test "renderEnglishSectionAlloc preserves possessive apostrophes and external wiki links in lead captions" {
    const source =
        \\==English==
        \\[[File:Britannica Macropaedia.jpg|thumb|right|250px|Volumes 21–24 of ''Britannica'''s ''[[w:Macropædia|Macropædia]]'' (covering topics from ''India'' to ''Norway'') in the [[w:Deutsches Museum|Deutsches Museum]]'s library.]]
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Britannica's") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://en.wikipedia.org/wiki/Macrop%C3%A6dia") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://en.wikipedia.org/wiki/Deutsches_Museum") != null);
}

test "renderEnglishSectionAlloc renders pronunciation templates with qualifiers and links" {
    const source =
        \\==English==
        \\===Pronunciation===
        \\* {{IPA|en|/pɔːtˈmæn.təʊ/|a=RP}}
        \\* {{enPR|pôrtmă'ntō|pô'rtmăntōʹ|a=US}}, {{IPA|en|/pɔːɹtˈmæntoʊ/|/ˌpɔːɹtmænˈtoʊ/}}
        \\* {{audio|en|en-us-portmanteau-1.ogg|a=US}}
        \\* {{rhymes|en|æntəʊ|əʊ|s=3}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Received Pronunciation") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "International_Phonetic_Alphabet") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "en-us-portmanteau-1.ogg") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Rhymes:") != null);
}

test "renderEnglishSectionAlloc keeps literal less-than text" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\Borrowed from month names < English usage.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "month names &lt; English usage.") != null);
}

test "renderEnglishSectionAlloc skips float tables and keeps later content" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{| class="wikitable floatright"
        \\|-
        \\| ignored
        \\|}
        \\# A [[test]] entry.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A test entry.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "wikitable") == null);
}
