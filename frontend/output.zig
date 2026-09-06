const std = @import("std");
const model = @import("model.zig");
const args = @import("args.zig");
const store = @import("store.zig");
pub const Match = struct { title: []const u8 };
pub const Response = struct {
    schema: []const u8 = "dict.results.v1",
    operation: args.Command,
    query: []const u8,
    kind: store.Kind,
    language: ?[]const u8,
    match_mode: []const u8 = "exact-utf8-prefix",
    record_count: usize,
    total_matches: usize,
    offset: usize = 0,
    has_more: bool = false,
    matches: []const Match = &.{},
    entries: []const model.Entry = &.{},
};

// Only renderer-owned control sequences reach the terminal.
pub fn terminalText(w: *std.Io.Writer, text: []const u8) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        if (n > text.len - pos) {
            try w.writeAll("�");
            pos += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[pos..][0..n]) catch {
            try w.writeAll("�");
            pos += 1;
            continue;
        };
        if (cp == '\n' or cp == '\t') try w.writeByte(@intCast(cp)) else if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069))
            try w.print("\\u{{{x}}}", .{cp})
        else
            try w.writeAll(text[pos..][0..n]);
        pos += n;
    }
}

pub fn spansText(w: *std.Io.Writer, spans: []const @import("wikitext.zig").Span, color: bool) !void {
    for (spans) |span| {
        if (color and span.bold) try w.writeAll("\x1b[1m");
        if (color and span.italic) try w.writeAll("\x1b[3m");
        if (color and span.underline) try w.writeAll("\x1b[4m");
        if (color and span.strike) try w.writeAll("\x1b[9m");
        if (color and (span.small or span.role == .label or span.role == .citation)) try w.writeAll("\x1b[2m");
        if (color and (span.kind == .link or span.kind == .external_link)) try w.writeAll("\x1b[36m");
        if (span.kind == .template) {
            try w.writeAll("[unavailable template: ");
            try terminalText(w, span.target);
            try w.writeByte(']');
        } else if (span.kind == .line_break) try w.writeByte('\n') else {
            if (span.superscript and span.role != .reference) try w.writeByte('^');
            if (span.subscript) try w.writeByte('_');
            try terminalText(w, span.text);
        }
        try terminalText(w, span.trail);
        if (color) try w.writeAll("\x1b[0m");
    }
}
pub fn entryText(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    return entryTextWithDetails(w, entry, color, true);
}
pub fn entryTextWithDetails(w: *std.Io.Writer, entry: model.Entry, color: bool, details: bool) !void {
    if (color) try w.writeAll("\x1b[1;36m");
    try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.expansion) |e| {
        if (e.status == .failed) {
            try w.writeAll("\n[Lua VM expansion failed; displaying native fallback: ");
            try terminalText(w, e.diagnostic orelse "unknown failure");
            try w.writeAll("]\n");
        }
    }
    if (entry.status == .invalid_payload) {
        try w.writeAll("\nInvalid semantic payload. JSON preserves its bytes as payload_base64.\n");
        return;
    }
    if (entry.preamble_spans.len != 0) {
        try spansText(w, entry.preamble_spans, color);
        try w.writeByte('\n');
    }
    const organization = entry.organization;
    if (organization.lexemes.len == 0) {
        for (entry.sections) |section| try sectionText(w, section, color);
    } else {
        for (organization.lexemes, 0..) |lexeme, l| {
            var seen = false;
            for (organization.lexemes[0..l]) |previous| if (std.mem.eql(u8, previous.kind, lexeme.kind) and std.mem.eql(u8, previous.language, lexeme.language)) {
                seen = true;
                break;
            };
            if (seen) continue;
            try w.writeByte('\n');
            if (color) try w.writeAll("\x1b[1m");
            try terminalText(w, lexeme.kind);
            if (lexeme.language.len != 0 and !std.mem.eql(u8, lexeme.language, entry.language orelse "")) {
                try w.writeAll(" / ");
                try terminalText(w, lexeme.language);
            }
            if (color) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
            for (organization.lexemes) |part| {
                if (!std.mem.eql(u8, part.kind, lexeme.kind) or !std.mem.eql(u8, part.language, lexeme.language)) continue;
                const section = entry.sections[part.section];
                if (part.etymology) |e| {
                    try w.writeAll("  [");
                    try terminalText(w, entry.sections[e].title);
                    try w.writeAll("]\n");
                }
                for (part.introduction) |i| {
                    const block = section.blocks[i];
                    var has_headword = false;
                    for (block.spans) |span| if (span.role == .headword) {
                        has_headword = true;
                        break;
                    };
                    if (!details and has_headword) {
                        for (block.spans, 0..) |span, j| if (span.role == .headword) try spansText(w, block.spans[j..][0..1], color);
                        try w.writeAll("\n\n");
                    } else try blocksText(w, section.blocks[i..][0..1], color);
                }
                for (part.definitions) |sense| {
                    try blocksText(w, section.blocks[sense.block..][0..1], color);
                    for (sense.examples) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    if (details) {
                        for (sense.notes) |i| try blocksText(w, section.blocks[i..][0..1], color);
                        for (sense.quotations) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    } else if (sense.quotations.len + sense.notes.len != 0) try w.print("      [{d} quotations / {d} supporting notes available]\n", .{ sense.quotations.len, sense.notes.len });
                }
                if (details) {
                    for (part.other_blocks) |i| try blocksText(w, section.blocks[i..][0..1], color);
                    for (part.related_sections) |i| try sectionText(w, entry.sections[i], color);
                }
            }
        }
        if (details) {
            for (organization.other_sections) |i| try sectionText(w, entry.sections[i], color);
        } else try w.writeAll("\n[History, quotations, related sections and references retained. Use --details, or d in the TUI.]\n");
    }
    if (details and entry.references.len != 0) {
        try w.writeAll("\nReferences\n");
        for (entry.references) |ref| {
            try w.print("[{d}] ", .{ref.number});
            try spansText(w, ref.spans, color);
            try w.writeByte('\n');
        }
    }
    if (entry.unexpanded_templates != 0) try w.print("\n[{d} unsupported template(s). Exact syntax is available in Source or JSON.]\n", .{entry.unexpanded_templates});
}
pub fn json(w: *std.Io.Writer, response: Response) !void {
    try std.json.Stringify.value(response, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

test "terminal output neutralizes control and bidi sequences without corrupting unicode" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try terminalText(&w.writer, "é猫\x1b[2J\u{9b}31m\u{202e}x");
    try std.testing.expectEqualStrings("é猫\\u{1b}[2J\\u{9b}31m\\u{202e}x", w.written());
}
test "JSON output is a complete versioned machine response" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try json(&w.writer, .{ .operation = .search, .query = "a\"", .kind = .language, .language = "English", .record_count = 2, .total_matches = 0 });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dict.results.v1", parsed.value.object.get("schema").?.string);
    try std.testing.expectEqualStrings("a\"", parsed.value.object.get("query").?.string);
}

test "human renderer displays definitions and supplied template data instead of wikitext" {
    const a = std.testing.allocator;
    const source = "==English==\n===Noun===\n{{en-noun}}\n#{{lb|en|informal}} A '''small''' [[cat|feline]].<ref>''Book''</ref>\n\n{{quote-text|en|year=2020|title=Book\n|passage=A {{m|en|cat}} appeared.}}\n";
    var doc = try model.fromWikitext(a, "cat", "English", source, true);
    defer doc.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try entryText(&out.writer, doc.entry, true);
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[[") == null);
    var plain_output: std.Io.Writer.Allocating = .init(a);
    defer plain_output.deinit();
    try entryText(&plain_output.writer, doc.entry, false);
    try std.testing.expect(std.mem.indexOf(u8, plain_output.written(), "(informal) A small feline.") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "References") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1msmall") != null);
    try std.testing.expectEqualStrings(source, doc.entry.source.?);
}

fn sectionText(w: *std.Io.Writer, section: model.Section, color: bool) !void {
    // Feature blobs can contain several level-2 languages; do not drop those labels.
    {
        try w.writeByte('\n');
        if (color) try w.writeAll("\x1b[1m");
        try terminalText(w, section.title);
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }
    try blocksText(w, section.blocks, color);
}
fn blocksText(w: *std.Io.Writer, blocks: []const model.Block, color: bool) !void {
    var ordinal: usize = 0;
    for (blocks) |block| {
        if (block.kind == .blank) continue;
        if (block.kind == .rule) {
            try w.writeAll("────────────────────────\n");
            continue;
        }
        if (block.table) |table| {
            if (table.caption.len != 0) {
                try spansText(w, table.caption, color);
                try w.writeByte('\n');
            }
            for (table.rows) |row| {
                try w.writeAll("  │ ");
                for (row.cells, 0..) |cell, i| {
                    if (i != 0) try w.writeAll(" │ ");
                    if (color and cell.header) try w.writeAll("\x1b[1m");
                    try spansText(w, cell.spans, color);
                    if (color) try w.writeAll("\x1b[0m");
                }
                try w.writeAll(" │\n");
            }
            try w.writeByte('\n');
            continue;
        }
        try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
        switch (block.kind) {
            .definition => {
                ordinal += 1;
                if (block.number.len != 0) {
                    try terminalText(w, block.number);
                    try w.writeAll(". ");
                } else try w.print("{d}. ", .{ordinal});
            },
            .example, .quotation => try w.writeAll("│ "),
            .list_item => try w.writeAll("• "),
            .preformatted => try w.writeAll("    "),
            else => {},
        }
        try spansText(w, block.spans, color);
        if (block.feature) |f| if (f.language.len != 0) {
            try w.writeAll("  [");
            try terminalText(w, f.language);
            try w.writeByte(']');
        };
        try w.writeByte('\n');
        if (block.kind == .paragraph or block.kind == .quotation) try w.writeByte('\n');
    }
}

test "concise reading is definition first and all details remain explicitly available" {
    const source = "==English==\n===Etymology===\nLong origin story.\n====Noun====\n# Definition.\n#* A quotation.\n#: An example.\n===References===\nA reference.\n";
    var doc = try model.fromWikitext(std.testing.allocator, "word", "English", source, true);
    defer doc.deinit();
    var brief: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer brief.deinit();
    try entryTextWithDetails(&brief.writer, doc.entry, false, false);
    try std.testing.expect(std.mem.indexOf(u8, brief.written(), "Definition.") != null);
    try std.testing.expect(std.mem.indexOf(u8, brief.written(), "An example.") != null);
    try std.testing.expect(std.mem.indexOf(u8, brief.written(), "Long origin story.") == null);
    var complete: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer complete.deinit();
    try entryTextWithDetails(&complete.writer, doc.entry, false, true);
    try std.testing.expect(std.mem.indexOf(u8, complete.written(), "Definition.").? < std.mem.indexOf(u8, complete.written(), "Long origin story.").?);
    try std.testing.expect(std.mem.indexOf(u8, complete.written(), "A quotation.") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete.written(), "A reference.") != null);
}

test "inflection tags are grammar rather than a fake gloss" {
    var doc = try model.fromWikitext(std.testing.allocator, "cats", "English", "==English==\n===Verb===\n# {{infl of|en|cat||s-verb-form}}\n", false);
    defer doc.deinit();
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try entryText(&w.writer, doc.entry, false);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "third-person singular simple present indicative of cat") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "s-verb-form") == null);
}
