const std = @import("std");

const wikitext = @import("wikitext_runtime.zig");

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

pub const RenderOptions = struct {
    strict: bool = true,
    issue: ?*RenderIssue = null,
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
                try out.appendSlice(allocator, "</div>");
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
                try out.appendSlice(allocator, "</div>");
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

    const rendered = try wikitext.renderWikitextToOwned(allocator, source, max_render_line_bytes);
    defer allocator.free(rendered);

    const trimmed = std.mem.trim(u8, rendered, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (containsResidualMarkup(trimmed)) {
        return failStrict(title, line_number, raw_line, "inline output still contains wiki markup", .raw_markup_leak, options);
    }

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try appendEscapedHtmlSlice(&html, allocator, trimmed);
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

        const rendered = try wikitext.renderWikitextToOwned(allocator, segment, max_term_bytes);
        defer allocator.free(rendered);
        try pushRenderedTerms(&terms, allocator, rendered);
    }

    if (terms.items.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "<ul class=\"render-term-grid\">");
    for (terms.items) |term| {
        try out.appendSlice(allocator, "<li>");
        try appendEscapedHtmlSlice(&out, allocator, term);
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
        "br",
        "chem",
        "code",
        "em",
        "hr",
        "i",
        "math",
        "nowiki",
        "ref",
        "s",
        "small",
        "span",
        "strong",
        "sub",
        "sup",
        "u",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(tag_name, candidate)) return true;
    }
    return false;
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
    if (asciiStartsWithIgnoreCase(trimmed, "list:")) return true;
    if (asciiStartsWithIgnoreCase(trimmed, "en-")) return true;
    if (std.mem.endsWith(u8, trimmed, " of")) return true;
    inline for ([_][]const u8{
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
        "commonscat",
        "compound",
        "co",
        "coi",
        "collocation",
        "cot",
        "coord",
        "coordinate terms",
        "confix",
        "der",
        "dercat",
        "der+",
        "displaced",
        "desc",
        "desctree",
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
        "interwiktionary",
        "ipa",
        "i",
        "ISBN",
        "ja-r",
        "l",
        "label",
        "lb",
        "lbl",
        "Latn-def",
        "langcat",
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
        "...",
        "+obj",
        "attn",
        "B.C.E.",
        "box-bottom",
        "box-top",
        "calque",
        "C.E.",
        "coin",
        "compound+",
        "clipping",
        "back-form",
        "IPAchar",
        "cap",
        "n-g",
        "quote",
        "senseno",
        "top2",
        "top3",
        "top4",
    }) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

fn shouldSkipStrictTemplateArgValidation(name: []const u8) bool {
    inline for ([_][]const u8{
        "checksense",
        "English personal pronouns",
        "gbooks",
        "langcat",
        "lookfrom",
        "multiple images",
        "picdic",
        "picdicimg",
        "picdiclabel",
        "rfap",
        "rfc",
        "rfe",
        "rfex",
        "rfp",
        "rfquote",
        "rfquotek",
        "rfquote-sense",
        "rfv-etym",
        "seeCites",
        "seeSynonyms",
        "seemoreCites",
        "top2",
        "top3",
        "top4",
        "wikiquote",
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
        if (input[i] == sep and templates == 0 and links == 0) {
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
        std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "col5");
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
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
        \\From {{der|en|fro|encloyer}} and {{root|en|ine-pro|*deyḱ-}}.
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
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "encloyer") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "*deyḱ-") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "country, Brazil") != null);
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
