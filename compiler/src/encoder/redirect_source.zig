//! Extract only the remaining content of an XML-marked redirect. Target and
//! fragment come from the matching pinned redirect SQL row, never source guesses.
const std = @import("std");

pub fn tail(source: []const u8) ![]const u8 {
    // WikitextContentHandler::extractRedirectTargetAndText first ltrims, then
    // matches the localized redirect word and its following [[...]] link. XML
    // already establishes that classification, so do not invent a locale table.
    const text = std.mem.trimStart(u8, source, " \t\r\n\x00\x0b");
    const open = std.mem.indexOf(u8, text, "[[") orelse return error.RedirectSourceMismatch;
    const prefix = std.mem.trim(u8, text[0..open], " \t\r\n\x00\x0b");
    if (prefix.len == 0 or std.mem.indexOfAny(u8, prefix, "<>[]{}|") != null) return error.RedirectSourceMismatch;
    const close = std.mem.indexOfPos(u8, text, open + 2, "]]") orelse return error.RedirectSourceMismatch;
    if (close == open + 2) return error.RedirectSourceMismatch;
    return std.mem.trimStart(u8, text[close + 2 ..], " \t\r\n\x0b\x0c");
}

test "XML redirect tail extraction preserves content without decoding target metadata" {
    for ([_][]const u8{ "#REDIRECT [[animus]]", " \n#ПРЕНАСОЧВАНЕ : [[animus]]\n" }) |source|
        try std.testing.expectEqualStrings("", try tail(source));
    try std.testing.expectEqualStrings("Tail [[kept]].\n{{template}}", try tail("#REDIRECT [[Template:sample%23e\u{301}_&nsbp;|label]]\nTail [[kept]].\n{{template}}"));
    try std.testing.expectEqualStrings("<!-- retained -->", try tail("#REDIRECT [[A]] <!-- retained -->"));
    try std.testing.expectError(error.RedirectSourceMismatch, tail("<!-- [[wrong]] -->#REDIRECT [[right]]"));
    try std.testing.expectError(error.RedirectSourceMismatch, tail("#REDIRECT [[unfinished"));
}
