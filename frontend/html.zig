//! Self-contained frontend built separately; native consumers need no JS toolchain.
const std = @import("std");
const output = @import("output.zig");
const template = @embedFile("web/dist/index.html");
const slot = "<script id=\"dict-data\" type=\"application/json\">\"__DICT_DATA__\"</script>";

pub fn write(w: *std.Io.Writer, a: std.mem.Allocator, response: output.Response) !void {
    const at = std.mem.indexOf(u8, template, slot) orelse return error.InvalidHtmlTemplate;
    var data: std.Io.Writer.Allocating = .init(a);
    defer data.deinit();
    try output.json(&data.writer, response);
    try w.writeAll(template[0..at]);
    try w.writeAll("<script id=\"dict-data\" type=\"application/json\">");
    try scriptJson(w, data.written());
    try w.writeAll("</script>");
    try w.writeAll(template[at + slot.len ..]);
}

// JSON is inert, but the HTML tokenizer still recognizes </script> and <!--.
fn scriptJson(w: *std.Io.Writer, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |b, i| switch (b) {
        '<', '>', '&' => {
            try w.writeAll(bytes[start..i]);
            try w.writeAll(switch (b) {
                '<' => "\\u003c",
                '>' => "\\u003e",
                else => "\\u0026",
            });
            start = i + 1;
        },
        else => {},
    };
    try w.writeAll(bytes[start..]);
}

test "HTML export embeds one inert lossless JSON document and all assets" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const query = "</script><!--<&>\"é猫";
    try write(&out.writer, a, .{ .operation = .lookup, .query = query, .kind = .language, .language = "English", .record_count = 0, .total_matches = 0 });
    const bytes = out.written();
    const begin_tag = "<script id=\"dict-data\" type=\"application/json\">";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, begin_tag));
    const start = std.mem.indexOf(u8, bytes, begin_tag).? + begin_tag.len;
    const end = std.mem.indexOfPos(u8, bytes, start, "</script>").?;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes[start..end], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(query, parsed.value.object.get("query").?.string);
    try std.testing.expect(std.mem.indexOf(u8, bytes[start..end], "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<script src=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<link rel=\"stylesheet\"") == null);
}

/// Copies only the presentation descriptors; source and shared template IDs stay unchanged.
pub fn writeLocal(w: *std.Io.Writer, a: std.mem.Allocator, io: std.Io, response: output.Response, media_root: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    var rendered = response;
    if (media_root) |root| {
        const entries = try temporary.dupe(@import("model.zig").Entry, response.entries);
        for (entries) |*entry| entry.media = try @import("media_assets.zig").attach(io, temporary, root, entry.media);
        rendered.entries = entries;
    }
    try write(w, a, rendered);
}

test "local media export owns all temporary attachment allocations" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeLocal(&out.writer, a, std.testing.io, .{ .operation = .lookup, .query = "cat", .kind = .language, .language = "English", .record_count = 1, .total_matches = 1, .entries = &.{.{ .title = "cat", .kind = .language }} }, ".zig-cache/no-media-required");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "dict-data") != null);
}
