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

pub fn entryText(w: *std.Io.Writer, entry: model.Entry, color: bool) !void {
    if (color) try w.writeAll("\x1b[1;36m");
    try terminalText(w, entry.title);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("  / ");
    try terminalText(w, entry.language orelse @tagName(entry.kind));
    try w.writeByte('\n');
    if (entry.status == .invalid_payload) {
        try w.writeAll("\nInvalid semantic payload. JSON preserves its bytes as payload_base64.\n");
        return;
    }
    if (entry.preamble.len != 0) {
        try terminalText(w, entry.preamble);
        try w.writeByte('\n');
    }
    for (entry.sections) |section| {
        if (section.level > 2 or entry.kind != .language) {
            try w.writeByte('\n');
            if (color) try w.writeAll("\x1b[1m");
            try terminalText(w, section.title);
            if (color) try w.writeAll("\x1b[0m");
            try w.writeByte('\n');
        }
        var ordinal: usize = 0;
        for (section.blocks) |block| {
            if (block.kind == .blank) continue;
            try w.splatByteAll(' ', @as(usize, @min(block.depth, 12)) * 2);
            switch (block.kind) {
                .definition => {
                    ordinal += 1;
                    try w.print("{d}. ", .{ordinal});
                },
                .example, .quotation => try w.writeAll("│ "),
                .list_item => try w.writeAll("• "),
                else => {},
            }
            for (block.spans) |span| {
                if (color and span.bold) try w.writeAll("\x1b[1m");
                if (color and span.italic) try w.writeAll("\x1b[3m");
                if (color and (span.kind == .link or span.kind == .external_link)) try w.writeAll("\x1b[36m");
                if (span.kind == .template) try w.writeAll("{{");
                if (span.kind == .line_break) try w.writeAll("\n    ") else try terminalText(w, span.text);
                if (span.kind == .template) try w.writeAll("}}");
                try terminalText(w, span.trail);
                if (color) try w.writeAll("\x1b[0m");
            }
            if (block.feature) |f| {
                if (f.language.len != 0) {
                    try w.writeAll("  [");
                    try terminalText(w, f.language);
                    try w.writeByte(']');
                }
            }
            try w.writeByte('\n');
        }
    }
    if (entry.unexpanded_templates != 0) try w.print("\n[{d} template(s) preserved, not expanded. Use --format source for exact wikitext.]\n", .{entry.unexpanded_templates});
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
