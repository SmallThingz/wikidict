const std = @import("std");

const wikitext = @import("wikitext.zig");

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

pub fn renderEnglishSectionAlloc(allocator: std.mem.Allocator, english_section: []const u8) ![]RenderedSection {
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

    const html = try renderSectionBodyHtmlAlloc(allocator, pending.title, pending.level, body, pending.first_line_number, options);
    errdefer allocator.free(html);
    if (html.len == 0) {
        pending.body.items.len = 0;
        pending.first_line_number = 0;
        return;
    }

    const section_index = rendered_sections.items.len;
    const effective_id_title = if (pending.title.len == 0) "lead" else pending.title;
    try rendered_sections.append(allocator, .{
        .id = try sectionIdAlloc(allocator, effective_id_title, section_index),
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
) ![]u8 {
    if (body.len == 0) return allocator.dupe(u8, "");
    if (level >= 3 and wikitext.isRecognizedPartOfSpeech(title)) {
        return renderPartOfSpeechHtmlAlloc(allocator, title, body);
    }
    return renderGenericSectionHtmlAlloc(allocator, title, body);
}

fn renderPartOfSpeechHtmlAlloc(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    var logical_lines = try collectLogicalLinesAlloc(allocator, body);
    defer logical_lines.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var ol_open = false;
    var sense_open = false;

    for (logical_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (shouldSkipStandaloneLine(trimmed)) continue;

        if (parseDefinitionLine(trimmed)) |parsed| {
            const content_html = try renderLineHtmlAlloc(allocator, title, parsed.content);
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

        const content_html = try renderLineHtmlAlloc(allocator, title, trimmed);
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

fn renderGenericSectionHtmlAlloc(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    var logical_lines = try collectLogicalLinesAlloc(allocator, body);
    defer logical_lines.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var list_kind: u8 = 0;
    var list_open = false;

    for (logical_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            if (list_open) {
                try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
                list_open = false;
                list_kind = 0;
            }
            continue;
        }

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
            const content_html = try renderLineHtmlAlloc(allocator, title, content);
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
        const content_html = try renderLineHtmlAlloc(allocator, title, content);
        defer allocator.free(content_html);
        if (content_html.len == 0) continue;

        try out.appendSlice(allocator, if (note_line) "<p class=\"render-note\">" else "<p>");
        try out.appendSlice(allocator, content_html);
        try out.appendSlice(allocator, "</p>");
    }

    if (list_open) try out.appendSlice(allocator, if (list_kind == '#') "</ol>" else "</ul>");
    return out.toOwnedSlice(allocator);
}

fn renderLineHtmlAlloc(allocator: std.mem.Allocator, title: []const u8, raw_line: []const u8) ![]u8 {
    const source = if (std.ascii.eqlIgnoreCase(title, "Gallery"))
        extractGalleryCaption(raw_line)
    else
        raw_line;

    if (source.len == 0) return allocator.dupe(u8, "");

    const rendered = try wikitext.renderWikitextToOwned(allocator, source, max_render_line_bytes);
    defer allocator.free(rendered);

    const trimmed = std.mem.trim(u8, rendered, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

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

        const caption_html = try renderLineHtmlAlloc(allocator, "Gallery", line);
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

fn collectLogicalLinesAlloc(allocator: std.mem.Allocator, body: []const u8) !OwnedLines {
    var lines_out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines_out.items) |line| allocator.free(line);
        lines_out.deinit(allocator);
    }

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var balance: LogicalBalance = .{};
    var in_gallery = false;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_input| {
        const raw_line = std.mem.trimEnd(u8, raw_input, "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");

        if (in_gallery) {
            if (pending.items.len != 0) try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            if (std.mem.indexOf(u8, trimmed, "</gallery>") != null) {
                try lines_out.append(allocator, try pending.toOwnedSlice(allocator));
                pending = .empty;
                in_gallery = false;
            }
            continue;
        }

        if (pending.items.len == 0 and asciiStartsWithIgnoreCase(trimmed, "<gallery")) {
            try pending.appendSlice(allocator, raw_line);
            if (std.mem.indexOf(u8, trimmed, "</gallery>") != null) {
                try lines_out.append(allocator, try pending.toOwnedSlice(allocator));
                pending = .empty;
            } else {
                in_gallery = true;
            }
            continue;
        }

        if (pending.items.len != 0) {
            if (pending.items.len != 0) try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, raw_line);
            balance.update(raw_line);
            if (balance.isOpen()) continue;

            try lines_out.append(allocator, try pending.toOwnedSlice(allocator));
            pending = .empty;
            balance = .{};
            continue;
        }

        var line_balance: LogicalBalance = .{};
        line_balance.update(raw_line);
        if (line_balance.isOpen()) {
            try pending.appendSlice(allocator, raw_line);
            balance = line_balance;
            continue;
        }

        try lines_out.append(allocator, try allocator.dupe(u8, raw_line));
    }

    if (pending.items.len != 0) {
        try lines_out.append(allocator, try pending.toOwnedSlice(allocator));
    }

    return .{ .items = try lines_out.toOwnedSlice(allocator) };
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
    return isHeadwordTemplateLine(line) or
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
        isStandaloneTemplateLineNamed(line, "rfe") or
        isStandaloneTemplateLineNamed(line, "table:colors/en");
}

fn isStandaloneTemplateLineNamed(line: []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return false;
    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    const sep = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, body[0..sep], " \t"), name);
}

fn isHeadwordTemplateLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return asciiStartsWithIgnoreCase(trimmed, "{{en-") or asciiStartsWithIgnoreCase(trimmed, "{{head|");
}

fn isStandaloneColumnTemplateLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 4 or !std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return false;
    const body = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    const sep = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    return isColumnTemplate(std.mem.trim(u8, body[0..sep], " \t"));
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

fn pushRenderedTerms(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, rendered: []const u8) !void {
    var parts = std.mem.splitAny(u8, rendered, ",;");
    while (parts.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn appendEscapedHtmlSlice(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
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
