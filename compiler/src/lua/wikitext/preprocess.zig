const std = @import("std");
const dependency = @import("missing_dependency");

fn findCiPos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return @min(start, hay.len);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    return null;
}

pub fn decodedTagEnd(text: []const u8, start: usize) ?usize {
    const p = std.mem.indexOfScalarPos(u8, text, start, '>') orelse return null;
    return p + 1;
}

// Nowiki alone requires a real closed region; an unmatched opener is literal.
// Match source boundaries before interpreting its literal body, without recursion.
fn nowikiRegionEnd(text: []const u8, start: usize) ?usize {
    return nowikiRegionEndCached(text, start, null);
}
fn nowikiRegionEndCached(text: []const u8, start: usize, no_more_close: ?*bool) ?usize {
    if (start >= text.len or text[start] != '<') return null;
    const name_start = start + 1;
    const name_end = name_start + "nowiki".len;
    if (name_end > text.len or !std.ascii.eqlIgnoreCase(text[name_start..name_end], "nowiki") or
        !isTagNameBoundary(text, name_end)) return null;
    const open_end = decodedTagEnd(text, start) orelse return null;
    if (open_end >= 2 and text[open_end - 2] == '/') return open_end;
    if (no_more_close) |missing| if (missing.*) return null;
    const end = inclusionCloseEnd(text, open_end, "nowiki");
    if (end == null) {
        if (no_more_close) |missing| missing.* = true;
    }
    return end;
}

pub fn stripDecodedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return stripDecodedCommentsPolicy(a, text, false, false);
}
pub fn stripDecodedCommentsPreservingPoem(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return stripDecodedCommentsPolicy(a, text, true, false);
}
pub fn stripDecodedCommentsForParsingPreservingPoem(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return stripDecodedCommentsPolicy(a, text, true, true);
}
// Preserve only a complete physically authored heading whose entire title is
// whitespace/comments. A visible-empty ordinary inline body keeps its original
// delimiter depth through expansion; comment text never becomes a label.
fn emptyCommentHeading(prefix: []const u8, tail: []const u8) bool {
    var level: usize = 0;
    while (level < prefix.len and prefix[level] == '=') : (level += 1) {}
    if (level == 0 or level > 6 or std.mem.trim(u8, prefix[level..], " \t").len != 0) return false;
    const line_end = std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
    const line = std.mem.trimEnd(u8, tail[0..line_end], " \t\r");
    var pos: usize = 0;
    while (pos < line.len) {
        if (line[pos] == ' ' or line[pos] == '\t') { pos += 1; continue; }
        if (!std.mem.startsWith(u8, line[pos..], "<!--")) break;
        const close = std.mem.indexOfPos(u8, line, pos + 4, "-->") orelse return false;
        pos = close + 3;
    }
    const closing = pos;
    while (pos < line.len and line[pos] == '=') : (pos += 1) {}
    if (pos - closing != level) return false;
    // Upstream ignores trailing closed comments when locating the closing
    // delimiter. Visible suffix text still prevents a complete heading.
    while (pos < line.len) {
        if (line[pos] == ' ' or line[pos] == '\t') { pos += 1; continue; }
        if (!std.mem.startsWith(u8, line[pos..], "<!--")) return false;
        const close = std.mem.indexOfPos(u8, line, pos + 4, "-->") orelse return false;
        pos = close + 3;
    }
    return true;
}

// Lazily inspect existing top-level construct ranges only when a candidate
// empty heading is found. Cache the next range so input prefixes never repeat.
const EmptyHeadingScope = struct {
    scan: ExpansionScan = .{},
    cursor: usize = 0,
    next_construct: ?Construct = null,
    finished: bool = false,
    fn outside(self: *@This(), source: []const u8, offset: usize) bool {
        while (!self.finished) {
            if (self.next_construct == null) {
                const node = self.scan.next(source, self.cursor, false) orelse {
                    self.finished = true;
                    return true;
                };
                self.next_construct = switch (node) { .construct => |value| value, .poem => unreachable };
            }
            const root = self.next_construct.?;
            if (offset < root.open) return true;
            const end = root.close + @as(usize, if (root.kind == .parameter) 3 else 2);
            if (offset < end) return false;
            self.cursor = end;
            self.next_construct = null;
        }
        return true;
    }
};

fn stripDecodedCommentsPolicy(a: std.mem.Allocator, text: []const u8, preserve_poem: bool, preserve_boundaries: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var line_start: usize = 0;
    var line_has_content = false;
    var empty_heading_scope: EmptyHeadingScope = .{};
    var no_more_poem_close = false;
    var no_more_poem_gt = false;
    var no_more_nowiki_close = false;
    var no_more_close: [opaque_parser_tags.len + 1]bool = @splat(false);
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |open| {
        const prefix = text[pos..open];
        for (prefix, 0..) |byte, at| {
            if (byte == '\n') {
                line_start = out.items.len + at + 1;
                line_has_content = false;
            } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
        }
        try out.appendSlice(a, prefix);
        // Ordinary raw Poem is formatted before recursive parsing strips comments.
        if (preserve_poem) {
            if (poemRegionAtCached(text, open, &no_more_poem_close, &no_more_poem_gt, null)) |region| {
                if (region.self_closing or region.inner_end < region.end) {
                    const protected = text[open..region.end];
                    for (protected, 0..) |byte, at| {
                        if (byte == '\n') {
                            line_start = out.items.len + at + 1;
                            line_has_content = false;
                        } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
                    }
                    try out.appendSlice(a, protected);
                    pos = region.end;
                    continue;
                }
            }
        }
        if (std.mem.startsWith(u8, text[open..], "<!--")) {
            const close = findCiPos(text, open + 4, "-->") orelse {
                pos = text.len;
                break;
            };
            pos = close + 3;
            if (preserve_boundaries) {
                const heading = emptyCommentHeading(out.items[line_start..], text[open..]) and
                    empty_heading_scope.outside(text, open);
                try out.appendSlice(a, if (heading) "<span></span>" else "<noinclude/>");
            }
            // Remove only comment-only lines and their terminating newline.
            // Keep the preceding newline, authored blanks and protected bodies.
            if (!line_has_content) {
                var line_end = pos;
                while (line_end < text.len and (text[line_end] == ' ' or text[line_end] == '\t' or text[line_end] == '\r')) : (line_end += 1) {}
                if (line_end == text.len or text[line_end] == '\n') {
                    out.items.len = line_start;
                    pos = if (line_end < text.len) line_end + 1 else line_end;
                }
            }
            continue;
        }
        // Only a real closed/self-closing nowiki protects comments. An
        // unmatched opener remains literal and leaves the remainder active.
        if (nowikiRegionEndCached(text, open, &no_more_nowiki_close)) |end| {
            const protected = text[open..end];
            for (protected, 0..) |byte, at| {
                if (byte == '\n') {
                    line_start = out.items.len + at + 1;
                    line_has_content = false;
                } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
            }
            try out.appendSlice(a, protected);
            pos = end;
            continue;
        }
        // Preserve existing closed pre/code-extension comment behavior.
        if (inclusionTagAt(text, open)) |tag| {
            const code_extension = std.ascii.eqlIgnoreCase(tag.name, "source") or
                std.ascii.eqlIgnoreCase(tag.name, "syntaxhighlight");
            if (std.ascii.eqlIgnoreCase(tag.name, "pre") or code_extension) {
                if (rawTagEnd(text, open)) |opening_end| {
                    var end = opening_end;
                    if (text[opening_end - 2] != '/') {
                        // Strict first-closer misses remain absent in the suffix.
                        // Keep each tag's slot separate, and bypass self-closing.
                        const close_end = if (no_more_close[tag.close_cache_slot]) null else inclusionCloseEnd(text, opening_end, tag.name);
                        if (close_end) |closed_end| end = closed_end else no_more_close[tag.close_cache_slot] = true;
                    }
                    const protected = text[open..end];
                    for (protected, 0..) |byte, at| {
                        if (byte == '\n') {
                            line_start = out.items.len + at + 1;
                            line_has_content = false;
                        } else if (byte != ' ' and byte != '\t' and byte != '\r') line_has_content = true;
                    }
                    try out.appendSlice(a, protected);
                    pos = end;
                    continue;
                }
            }
        }
        try out.append(a, '<');
        line_has_content = true;
        pos = open + 1;
    }
    try out.appendSlice(a, text[pos..]);
    return out.toOwnedSlice(a);
}

// Sanitizer's post-expansion phase is distinct from authored preprocessing.
// The input cursor advances once; bounded tail checks also see comment openers
// formed by elision. A cached literal-space suffix is never scanned repeatedly.
// Copy intervals from the existing Sanitizer cursor, not a second parser or
// a search for equal output strings. Synthetic bytes deliberately have no span.
const CommentCopies = struct {
    const Span = struct { source: usize, output: usize, len: usize };
    spans: std.ArrayList(Span) = .empty,
    limited: bool = false,

    fn copy(self: *@This(), a: std.mem.Allocator, source: usize, output: usize, len: usize) !void {
        if (len == 0 or self.limited) return;
        if (self.spans.items.len != 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (last.source + last.len == source and last.output + last.len == output) {
                last.len += len;
                return;
            }
        }
        if (self.spans.items.len >= dependency.max_metadata_bytes / @sizeOf(Span)) {
            self.limited = true;
            self.spans.clearRetainingCapacity();
            return;
        }
        try self.spans.append(a, .{ .source = source, .output = output, .len = len });
    }

    fn truncate(self: *@This(), end: usize) void {
        while (self.spans.items.len != 0) {
            const last = &self.spans.items[self.spans.items.len - 1];
            if (last.output >= end) {
                self.spans.items.len -= 1;
            } else {
                last.len = @min(last.len, end - last.output);
                break;
            }
        }
    }

    // The parser replaces one already-emitted '<' with four literal bytes.
    fn escapeLt(self: *@This(), a: std.mem.Allocator, at: usize) !void {
        if (self.limited) return;
        // The active tag opener is in the emitted tail. Earlier spans cannot
        // move: walk backward only through that affected suffix.
        var index = self.spans.items.len;
        while (index != 0) {
            index -= 1;
            const old = self.spans.items[index];
            if (old.output >= at + 1) {
                self.spans.items[index].output += 3;
                continue;
            }
            if (old.output + old.len > at) {
                const before = at - old.output;
                const after = old.len - before - 1;
                self.spans.items[index].len = before;
                if (after != 0) {
                    if (self.spans.items.len >= dependency.max_metadata_bytes / @sizeOf(Span)) {
                        self.limited = true;
                        self.spans.clearRetainingCapacity();
                        return;
                    }
                    try self.spans.insert(a, index + 1, .{
                        .source = old.source + before + 1,
                        .output = at + 4,
                        .len = after,
                    });
                }
            }
            break;
        }
    }

    fn mapped(self: *const @This(), start: usize, end: usize, cursor: *usize) ?usize {
        if (self.limited) return null;
        while (cursor.* < self.spans.items.len and self.spans.items[cursor.*].source + self.spans.items[cursor.*].len <= start)
            cursor.* += 1;
        if (cursor.* == self.spans.items.len) return null;
        const span = self.spans.items[cursor.*];
        // Adjacent source and output copies were merged at insertion. A range
        // crossing a deletion, inserted byte or reconstructed opener is refused.
        if (span.source > start or span.source + span.len < end) return null;
        return span.output + start - span.source;
    }
};

pub fn stripExpandedCommentsTracked(a: std.mem.Allocator, source: dependency.Text) !dependency.Text {
    var copies: CommentCopies = .{};
    defer copies.spans.deinit(a);
    const bytes = try stripExpandedCommentsImpl(a, source.bytes, &copies);
    errdefer a.free(bytes);
    // This entry runs after escapeLiteralCurly. Retain conservative behavior
    // for callers that have not finalized other in-process provenance yet.
    if (source.literal_curly_ranges.len != 0 or source.generated_links.len != 0 or source.generated_source != null)
        return dependency.Text.transformedFrom(source, bytes);
    var ranges: std.ArrayList(dependency.Range) = .empty;
    errdefer ranges.deinit(a);
    var unknown = source.unknown or copies.limited;
    var lost = source.lost_missing_range;
    var previous: u32 = 0;
    var cursor: usize = 0;
    for (source.ranges) |range| {
        if (range.start < previous or range.start >= range.end or range.end > source.bytes.len or range.occurrence == 0)
            return error.InvalidMissingDependencyCopy;
        previous = range.end;
        if (copies.mapped(range.start, range.end, &cursor)) |start| {
            const end = start + range.end - range.start;
            if (end > std.math.maxInt(u32)) return error.InvalidMissingDependencyCopy;
            try ranges.append(a, .{ .start = @intCast(start), .end = @intCast(end), .occurrence = range.occurrence });
        } else {
            unknown = true;
            lost = true;
        }
    }
    return .{ .bytes = bytes, .ranges = try ranges.toOwnedSlice(a), .unknown = unknown, .lost_missing_range = lost };
}

pub fn stripExpandedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return stripExpandedCommentsImpl(a, text, null);
}

fn stripExpandedCommentsImpl(a: std.mem.Allocator, text: []const u8, copies: ?*CommentCopies) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var no_more_comment_close = false;
    var no_more_nowiki_close = false;
    var no_more_close: [opaque_parser_tags.len + 1]bool = @splat(false);
    var spaces_end: usize = 0;
    var spaces_start: usize = 0;
    var tag_open: ?usize = null;
    var tag_joined = false;
    while (pos < text.len or std.mem.endsWith(u8, out.items, "<!--")) {
        if (std.mem.endsWith(u8, out.items, "<!--")) {
            const prefix_end = out.items.len - 4;
            if (copies) |map| map.truncate(prefix_end);
            out.items.len = prefix_end;
            if (tag_open) |open| {
                if (open >= prefix_end) tag_open = null else tag_joined = true;
            }
            const close = if (no_more_comment_close) null else std.mem.indexOfPos(u8, text, pos, "-->");
            if (close) |end| {
                pos = end + 3;
                var before = prefix_end;
                if (before >= spaces_start and before <= spaces_end) {
                    before = spaces_start;
                } else {
                    while (before > 0 and out.items[before - 1] == ' ') : (before -= 1) {}
                }
                spaces_start = before;
                spaces_end = prefix_end;
                var after = pos;
                while (after < text.len and text[after] == ' ') : (after += 1) {}
                if (before > 0 and out.items[before - 1] == '\n' and after < text.len and text[after] == '\n') {
                    if (copies) |map| map.truncate(before);
                    out.items.len = before;
                    pos = after + 1;
                    spaces_end = before;
                } else {
                    // Consume this space run once even when it is not collapsed.
                    if (copies) |map| try map.copy(a, pos, out.items.len, after - pos);
                    try out.appendSlice(a, text[pos..after]);
                    spaces_end = out.items.len;
                    pos = after;
                }
            } else {
                // Sanitizer leaves the unclosed comment, then escapes the '<'
                // as an unknown tag. Keep its remaining body active downstream.
                no_more_comment_close = true;
                try out.appendSlice(a, "&lt;!--");
            }
            continue;
        }
        if (text[pos] == '<' and !std.mem.startsWith(u8, text[pos..], "<!--")) {
            var protected_end = nowikiRegionEndCached(text, pos, &no_more_nowiki_close);
            if (protected_end == null) {
                if (inclusionTagAt(text, pos)) |tag| {
                    if (std.ascii.eqlIgnoreCase(tag.name, "pre") or std.ascii.eqlIgnoreCase(tag.name, "source") or std.ascii.eqlIgnoreCase(tag.name, "syntaxhighlight")) {
                        if (rawTagEnd(text, pos)) |opening_end| {
                            if (text[opening_end - 2] == '/') {
                                protected_end = opening_end;
                            } else if (!no_more_close[tag.close_cache_slot]) {
                                protected_end = inclusionCloseEnd(text, opening_end, tag.name);
                                if (protected_end == null) no_more_close[tag.close_cache_slot] = true;
                            }
                        }
                    }
                }
            }
            if (protected_end) |end| {
                if (copies) |map| try map.copy(a, pos, out.items.len, end - pos);
                try out.appendSlice(a, text[pos..end]);
                pos = end;
                tag_open = null;
                continue;
            }
            tag_open = out.items.len;
            tag_joined = false;
        }
        const byte = text[pos];
        if (copies) |map| try map.copy(a, pos, out.items.len, 1);
        try out.append(a, byte);
        pos += 1;
        if (byte == '>') {
            if (tag_open) |open| {
                if (tag_joined) {
                    if (inclusionTagAt(out.items, open)) |tag| {
                        // These strip hooks have already run before Sanitizer
                        // removes comments. Reconstructed openers are unknown HTML.
                        if (std.ascii.eqlIgnoreCase(tag.name, "nowiki") or
                            std.ascii.eqlIgnoreCase(tag.name, "source") or
                            std.ascii.eqlIgnoreCase(tag.name, "syntaxhighlight"))
                        {
                            if (copies) |map| try map.escapeLt(a, open);
                            const old_len = out.items.len;
                            try out.resize(a, old_len + 3);
                            std.mem.copyBackwards(u8, out.items[open + 4 ..], out.items[open + 1 .. old_len]);
                            @memcpy(out.items[open .. open + 4], "&lt;");
                            spaces_start = out.items.len;
                            spaces_end = out.items.len;
                        }
                    }
                }
            }
            tag_open = null;
        }
    }
    return out.toOwnedSlice(a);
}

test "post expansion comments follow sanitizer boundaries and reconstructed openers" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "A<!<!--inner-->--outer-->B", "AB" },
        .{ "<!--x-->\nB", "\nB" },
        .{ "A\n <!--x--> \nB", "A\nB" },
        .{ "A\n\t<!--x--> \nB", "A\n\t \nB" },
        .{ "A\n <!--x-->\t\nB", "A\n \t\nB" },
        .{ "A\r <!--x--> \nB", "A\r  \nB" },
        .{ "A\n <!--x--> ", "A\n  " },
        .{ "A<!--unclosed __NOEDITSECTION__ [[B]] ISBN 9780306406157", "A&lt;!--unclosed __NOEDITSECTION__ [[B]] ISBN 9780306406157" },
        .{ "<no<!--x-->wiki>__NOEDITSECTION__[[B]]</nowiki>", "&lt;nowiki>__NOEDITSECTION__[[B]]</nowiki>" },
        .{ "<sour<!--x-->ce>[[cat]] __NOEDITSECTION__</source>", "&lt;source>[[cat]] __NOEDITSECTION__</source>" },
        .{ "<syntax<!--x-->highlight>[[cat]] __NOEDITSECTION__</syntaxhighlight>", "&lt;syntaxhighlight>[[cat]] __NOEDITSECTION__</syntaxhighlight>" },
        .{ "<syntax<!--x-->highlight lang=\"text\">[[dog]] __NOEDITSECTION__</syntaxhighlight>", "&lt;syntaxhighlight lang=\"text\">[[dog]] __NOEDITSECTION__</syntaxhighlight>" },
        .{ "<SOU<!--x-->RCE>[[cat]]</SOURCE>", "&lt;SOURCE>[[cat]]</SOURCE>" },
        .{ "<pr<!--x-->e>body</pre>", "<pre>body</pre>" },
        .{ "<nowiki><!--literal-->__NOEDITSECTION__[[B]]</nowiki>", "<nowiki><!--literal-->__NOEDITSECTION__[[B]]</nowiki>" },
        .{ "<pre><!--literal--></pre><source><!--literal--></source><syntaxhighlight><!--literal--></syntaxhighlight>", "<pre><!--literal--></pre><source><!--literal--></source><syntaxhighlight><!--literal--></syntaxhighlight>" },
        .{ "<source>[[cat]] __NOEDITSECTION__ <!--literal--></source><syntaxhighlight>[[dog]] __NOEDITSECTION__ <!--literal--></syntaxhighlight>", "<source>[[cat]] __NOEDITSECTION__ <!--literal--></source><syntaxhighlight>[[dog]] __NOEDITSECTION__ <!--literal--></syntaxhighlight>" },
        .{ "<code>A<!--x-->B</code>", "<code>AB</code>" },
    };
    for (cases) |case| {
        const actual = try stripExpandedComments(a, case[0]);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case[1], actual);
    }
    const authored = try stripDecodedComments(a, "A<!--unclosed __NOEDITSECTION__ [[B]]");
    defer a.free(authored);
    try std.testing.expectEqualStrings("A", authored);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a, "text");
    try input.appendNTimes(a, ' ', 4096);
    for (0..256) |_| try input.appendSlice(a, "<!--x-->");
    const expected = try a.dupe(u8, input.items[0..4100]);
    defer a.free(expected);
    const actual = try stripExpandedComments(a, input.items);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    input.clearRetainingCapacity();
    for (0..256) |_| try input.appendSlice(a, "<!--unclosed ");
    const escaped = try stripExpandedComments(a, input.items);
    defer a.free(escaped);
    try std.testing.expectEqual(@as(usize, 256), std.mem.count(u8, escaped, "&lt;!--unclosed "));
}

const InclusionTag = struct {
    name: []const u8,
    mode: enum { delimiter, excluded, preserved },
    close_cache_slot: usize = 0,
};

fn inclusionTagAt(text: []const u8, start: usize) ?InclusionTag {
    return inclusionTagAtMode(text, start, true);
}

fn inclusionTagAtMode(text: []const u8, start: usize, comptime for_inclusion: bool) ?InclusionTag {
    const name_start = start + 1;
    var end = name_start;
    if (end < text.len and text[end] == '/') end += 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) : (end += 1) {}
    if (end == name_start or end == text.len) return null;
    if (!std.ascii.isWhitespace(text[end]) and text[end] != '>' and
        !std.mem.startsWith(u8, text[end..], "/>")) return null;
    const name = text[name_start..end];
    if (for_inclusion) {
        if (std.ascii.eqlIgnoreCase(name, "includeonly") or std.ascii.eqlIgnoreCase(name, "/includeonly"))
            return .{ .name = name, .mode = .delimiter };
        if (std.ascii.eqlIgnoreCase(name, "noinclude"))
            return .{ .name = name, .mode = .excluded };
    } else {
        if (std.ascii.eqlIgnoreCase(name, "noinclude") or std.ascii.eqlIgnoreCase(name, "/noinclude") or
            std.ascii.eqlIgnoreCase(name, "onlyinclude") or std.ascii.eqlIgnoreCase(name, "/onlyinclude"))
            return .{ .name = name, .mode = .delimiter };
        if (std.ascii.eqlIgnoreCase(name, "includeonly"))
            return .{ .name = name, .mode = .excluded };
    }
    if (opaqueParserTagIndex(name)) |index|
        return .{ .name = name, .mode = .preserved, .close_cache_slot = index + 1 };
    return null;
}

fn inclusionCloseEnd(text: []const u8, start: usize, name: []const u8) ?usize {
    var pos = start;
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        const name_end = lt + 2 + name.len;
        if (name_end <= text.len and text[lt + 1] == '/' and
            std.ascii.eqlIgnoreCase(text[lt + 2 .. name_end], name))
        {
            var end = name_end;
            while (end < text.len and std.ascii.isWhitespace(text[end])) : (end += 1) {}
            if (end < text.len and text[end] == '>') return end + 1;
        }
        pos = lt + 1;
    }
    return null;
}

pub fn transcludeDecodedAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return transcludeDecodedWithBoundariesAlloc(a, text, false);
}

// Empty inclusion nodes must remain separate while parsing template arguments.
// Their text is omitted only when expanding the already separated values.
pub fn transcludeDecodedForParsingAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    return transcludeDecodedWithBoundariesAlloc(a, text, true);
}

// Direct pages use the inverse inclusion mode. Keep ignored nodes until brace
// parsing has separated constructs; removing them here could create new calls.
pub fn directDecodedForParsingAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const included = try inclusionDecodedWithBoundariesAlloc(a, text, true, false);
    defer a.free(included);
    return stripDecodedCommentsForParsingPreservingPoem(a, included);
}

fn transcludeDecodedWithBoundariesAlloc(a: std.mem.Allocator, text: []const u8, preserve_empty_noinclude: bool) ![]u8 {
    return inclusionDecodedWithBoundariesAlloc(a, text, preserve_empty_noinclude, true);
}

fn inclusionDecodedWithBoundariesAlloc(a: std.mem.Allocator, text: []const u8, preserve_empty_noinclude: bool, comptime for_inclusion: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    // MediaWiki Preprocessor_Hash selects exact onlyinclude delimiters on the
    // raw source, before recognizing comments or extension bodies.
    const onlyinclude = for_inclusion and std.mem.indexOf(u8, text, "<onlyinclude>") != null and
        std.mem.indexOf(u8, text, "</onlyinclude>") != null;
    var seeking_onlyinclude = onlyinclude;
    var no_more_gt = false;
    var no_more_close: [opaque_parser_tags.len + 1]bool = @splat(false);
    var pos: usize = 0;
    while (pos < text.len) {
        if (seeking_onlyinclude) {
            const open = std.mem.indexOfPos(u8, text, pos, "<onlyinclude>") orelse break;
            pos = open + "<onlyinclude>".len;
            if (preserve_empty_noinclude) try out.appendSlice(a, "<noinclude/>");
            seeking_onlyinclude = false;
        }
        const lt = std.mem.indexOfScalarPos(u8, text, pos, '<') orelse {
            try out.appendSlice(a, text[pos..]);
            break;
        };
        try out.appendSlice(a, text[pos..lt]);
        if (onlyinclude and std.mem.startsWith(u8, text[lt..], "</onlyinclude>")) {
            if (preserve_empty_noinclude) try out.appendSlice(a, "<noinclude/>");
            pos = lt + "</onlyinclude>".len;
            seeking_onlyinclude = true;
            continue;
        }
        if (std.mem.startsWith(u8, text[lt..], "<!--")) {
            const close = std.mem.indexOfPos(u8, text, lt + 4, "-->") orelse {
                if (!for_inclusion) try out.appendSlice(a, text[lt..]);
                break;
            };
            // The direct-page comment pass retains its comment-only line and
            // heading policies, while inclusion tags inside comments stay inert.
            if (!for_inclusion) {
                try out.appendSlice(a, text[lt .. close + 3]);
            } else if (preserve_empty_noinclude) {
                try out.appendSlice(a, "<noinclude/>");
            }
            pos = close + 3;
            continue;
        }
        const tag = inclusionTagAtMode(text, lt, for_inclusion) orelse {
            try out.append(a, '<');
            pos = lt + 1;
            continue;
        };
        // The PHP preprocessor uses the first raw '>', even inside attributes.
        const open_end = (if (no_more_gt) null else decodedTagEnd(text, lt)) orelse {
            no_more_gt = true;
            try out.append(a, '<');
            pos = lt + 1;
            continue;
        };
        if (tag.mode == .delimiter) {
            if (preserve_empty_noinclude) try out.appendSlice(a, "<noinclude/>");
            pos = open_end;
            continue;
        }
        if (text[open_end - 2] == '/') {
            if (tag.mode == .preserved or (for_inclusion and preserve_empty_noinclude and tag.mode == .excluded)) {
                try out.appendSlice(a, text[lt..open_end]);
            } else if (preserve_empty_noinclude and tag.mode == .excluded) {
                try out.appendSlice(a, "<noinclude/>");
            }
            pos = open_end;
            continue;
        }
        // Elements end at the first closing tag, without nesting. Cache misses
        // so repeated unclosed extension tags cannot cause quadratic scans.
        const close_end = if (no_more_close[tag.close_cache_slot]) null else inclusionCloseEnd(text, open_end, tag.name);
        if (close_end) |end| {
            if (tag.mode == .preserved) {
                try out.appendSlice(a, text[lt..end]);
            } else if (preserve_empty_noinclude) {
                try out.appendSlice(a, "<noinclude/>");
            }
            pos = end;
        } else {
            no_more_close[tag.close_cache_slot] = true;
            // The upstream missing-end whitelist uses the original spelling.
            // The lowercase excluded element legitimately runs through EOF.
            if (std.mem.eql(u8, tag.name, if (for_inclusion) "noinclude" else "includeonly")) break;
            try out.appendSlice(a, text[lt..open_end]);
            pos = open_end;
        }
    }
    return out.toOwnedSlice(a);
}

/// Match the empty excluded inclusion node accepted by parsing-text cleanup.
pub fn parsingBoundaryEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '<') return null;
    const tag = inclusionTagAt(text, start) orelse return null;
    if (tag.mode != .excluded) return null;
    const end = decodedTagEnd(text, start) orelse return null;
    return if (end >= 2 and text[end - 2] == '/') end else null;
}

/// Append expanded plain text without leaking empty inclusion-node boundaries.
/// Literal extension bodies keep their authored contents untouched.
pub fn appendParsingText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var pos: usize = 0;
    var copied: usize = 0;
    var opaque_scan: OpaqueParserScan = .{};
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        if (opaque_scan.literalEnd(text, lt)) |end| {
            pos = end;
            continue;
        }
        if (parsingBoundaryEnd(text, lt)) |end| {
            try out.appendSlice(a, text[copied..lt]);
            copied = end;
            pos = end;
            continue;
        }
        pos = lt + 1;
    }
    try out.appendSlice(a, text[copied..]);
}

// Only real parsing boundaries activate literal-brace provenance. Literal bodies
// retain their original contents and existing protected-literal ownership.
pub fn hasParsingBoundary(text: []const u8) bool {
    var pos: usize = 0;
    var opaque_scan: OpaqueParserScan = .{};
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        if (opaque_scan.literalEnd(text, lt)) |end| {
            pos = end;
            continue;
        }
        if (parsingBoundaryEnd(text, lt) != null) return true;
        pos = lt + 1;
    }
    return false;
}

fn appendParsingChunk(a: std.mem.Allocator, out: *dependency.Builder, text: []const u8, protect_literal_curly: bool, after_boundary: *bool, literal_balance: *usize, last_source_byte: *?u8) !void {
    if (text.len == 0) return;
    var copied: usize = 0;
    if (protect_literal_curly and after_boundary.* and (text[0] == '{' or text[0] == '}') and
        last_source_byte.* != null and last_source_byte.*.? == text[0] and
        out.bytes.items.len != 0 and out.bytes.items[out.bytes.items.len - 1] == text[0])
    {
        const previous_owned = out.literal_curly_ranges.items.len != 0 and
            out.literal_curly_ranges.items[out.literal_curly_ranges.items.len - 1].end == out.bytes.items.len;
        try out.append(a, dependency.Text.untracked(text[0..1]));
        try out.markLiteralCurly(a, out.bytes.items.len - 2, out.bytes.items.len);
        const newly_owned: usize = 2 - @as(usize, @intFromBool(previous_owned));
        if (text[0] == '{') {
            literal_balance.* += newly_owned;
        } else literal_balance.* -= @min(literal_balance.*, newly_owned);
        copied = 1;
    }
    after_boundary.* = false;
    // Match only the closes owned by an opener synthesized in this same literal
    // source segment. Distant unmatched syntax acquires no provenance.
    var at = copied;
    while (literal_balance.* != 0 and at < text.len) {
        if (text[at] != '}') {
            at += 1;
            continue;
        }
        const start = at;
        while (at < text.len and text[at] == '}' and at - start < literal_balance.*) : (at += 1) {}
        try out.append(a, dependency.Text.untracked(text[copied..start]));
        try out.appendLiteralCurly(a, text[start..at]);
        literal_balance.* -= at - start;
        copied = at;
    }
    try out.append(a, dependency.Text.untracked(text[copied..]));
    last_source_byte.* = text[text.len - 1];
}

pub const ParsingLiteralState = struct {
    after_boundary: bool = false,
    literal_balance: usize = 0,
    last_source_byte: ?u8 = null,
};

pub fn appendParsingTextTracked(a: std.mem.Allocator, out: *dependency.Builder, text: []const u8, protect_literal_curly: bool) !void {
    var state: ParsingLiteralState = .{};
    try appendParsingTextTrackedState(a, out, text, protect_literal_curly, &state);
}

// One state belongs to one authoritative source scan. Active child output never
// changes its balance; callers clear pending adjacency at each child callback.
pub fn appendParsingTextTrackedState(a: std.mem.Allocator, out: *dependency.Builder, text: []const u8, protect_literal_curly: bool, state: *ParsingLiteralState) !void {
    var pos: usize = 0;
    var copied: usize = 0;
    var opaque_scan: OpaqueParserScan = .{};
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |lt| {
        if (opaque_scan.literalEnd(text, lt)) |end| {
            try appendParsingChunk(a, out, text[copied..lt], protect_literal_curly, &state.after_boundary, &state.literal_balance, &state.last_source_byte);
            try out.append(a, dependency.Text.untracked(text[lt..end]));
            state.after_boundary = false;
            state.last_source_byte = null;
            copied = end;
            pos = end;
            continue;
        }
        if (parsingBoundaryEnd(text, lt)) |end| {
            try appendParsingChunk(a, out, text[copied..lt], protect_literal_curly, &state.after_boundary, &state.literal_balance, &state.last_source_byte);
            state.after_boundary = true;
            copied = end;
            pos = end;
            continue;
        }
        pos = lt + 1;
    }
    try appendParsingChunk(a, out, text[copied..], protect_literal_curly, &state.after_boundary, &state.literal_balance, &state.last_source_byte);
}

// Residual source closers are unconditional, even when the default is unused.
// Inspect its literal nodes without evaluating any template or parser function.
pub fn parameterLiteralCloseCount(a: std.mem.Allocator, inside: []const u8, conversion_enabled: bool) !usize {
    const fallback = splitParameterWithConversion(inside, conversion_enabled).default orelse return 0;
    if (!hasParsingBoundary(fallback)) return 0;
    var out: dependency.Builder = .{};
    defer out.deinit(a);
    var scan: ExpansionScan = .{ .conversion_enabled = conversion_enabled };
    var literal_state: ParsingLiteralState = .{};
    var pos: usize = 0;
    while (scan.next(fallback, pos, false)) |node| {
        const construct = node.construct;
        try appendParsingTextTrackedState(a, &out, fallback[pos..construct.open], true, &literal_state);
        literal_state.after_boundary = false;
        literal_state.last_source_byte = null;
        pos = construct.close + if (construct.kind == .parameter) @as(usize, 3) else 2;
    }
    try appendParsingTextTrackedState(a, &out, fallback[pos..], true, &literal_state);
    return dependency.unclosedLiteralCurly(.{ .bytes = out.bytes.items, .literal_curly_ranges = out.literal_curly_ranges.items });
}

pub const ConstructKind = enum { template, parameter };

pub const Construct = struct {
    open: usize,
    close: usize,
    kind: ConstructKind,
};

const BracePiece = struct {
    count: usize,
    root: bool,
    saved_minus: bool = false,
};

fn repeatedByteRun(s: []const u8, start: usize, byte: u8) usize {
    var end = start;
    while (end < s.len and s[end] == byte) : (end += 1) {}
    return end - start;
}

fn matchingBraceWidth(open_count: usize, close_count: usize) u8 {
    const count = @min(open_count, close_count);
    if (count >= 3) return 3;
    if (count >= 2) return 2;
    return 0;
}

fn findBraceConstruct(s: []const u8, start: usize) ?Construct {
    var cache: OpaqueParserScan = .{};
    return findBraceConstructCached(s, start, &cache, false);
}

fn findBraceConstructCached(s: []const u8, start: usize, forward_cache: *OpaqueParserScan, conversion_enabled: bool) ?Construct {
    if (start >= s.len or s[start] != '{') return null;
    const root_count = repeatedByteRun(s, start, '{');
    if (root_count < 2) return null;

    var stack: [128]BracePiece = undefined;
    var depth: usize = 1;
    stack[0] = .{ .count = root_count, .root = true };
    var square: usize = 0;
    var square_braces: [128]usize = undefined;
    var conversions: [128]struct { depth: usize, square: usize } = undefined;
    var conversion_depth: usize = 0;
    var i = start + root_count;
    // Only a complete root commits positive lookahead as the caller advances.
    // Failed lookahead retains only absence facts guarded by their source offset.
    var opaque_scan = forward_cache.*;
    defer forward_cache.mergeAbsence(&opaque_scan);
    while (i < s.len) {
        if (opaque_scan.end(s, i)) |region_end| {
            i = region_end;
            continue;
        }
        if (conversion_enabled and std.mem.startsWith(u8, s[i..], "-{") and
            (i + 2 == s.len or s[i + 2] != '{')) {
            if (conversion_depth == conversions.len) return null;
            conversions[conversion_depth] = .{ .depth = depth, .square = square };
            conversion_depth += 1;
            i += 2;
            continue;
        }
        const conversion_here = conversion_depth != 0 and
            conversions[conversion_depth - 1].depth == depth and
            conversions[conversion_depth - 1].square == square;
        if (conversion_here and std.mem.startsWith(u8, s[i..], "}-")) {
            conversion_depth -= 1;
            i += 2;
            continue;
        }
        // Link delimiters scope literal braces even without language conversion.
        if (std.mem.startsWith(u8, s[i..], "[[")) {
            if (square == square_braces.len) return null;
            square_braces[square] = depth;
            square += 1;
            i += 2;
            continue;
        }
        if (square != 0 and depth == square_braces[square - 1] and !conversion_here and std.mem.startsWith(u8, s[i..], "]]")) {
            square -= 1;
            i += 2;
            continue;
        }
        if (s[i] == '{') {
            const count = repeatedByteRun(s, i, '{');
            if (count >= 2) {
                if (depth == stack.len) return null;
                stack[depth] = .{ .count = count, .root = false, .saved_minus = conversion_enabled and i != 0 and s[i - 1] == '-' };
                depth += 1;
                i += count;
                continue;
            }
        }
        if (s[i] == '}' and depth != 0 and !conversion_here and (square == 0 or depth > square_braces[square - 1])) {
            const close_count = repeatedByteRun(s, i, '}');
            const piece = stack[depth - 1];
            const width = matchingBraceWidth(piece.count, close_count);
            if (width != 0) {
                depth -= 1;
                const remainder = piece.count - width;
                if (remainder >= 2) {
                    stack[depth] = .{ .count = remainder, .root = piece.root, .saved_minus = piece.saved_minus };
                    depth += 1;
                } else if (remainder == 1 and piece.saved_minus) {
                    if (conversion_depth == conversions.len) return null;
                    conversions[conversion_depth] = .{ .depth = depth, .square = square };
                    conversion_depth += 1;
                } else if (piece.root) {
                    forward_cache.* = opaque_scan;
                    return .{
                        .open = start + @intFromBool(remainder == 1),
                        .close = i,
                        .kind = if (width == 2) .template else .parameter,
                    };
                }
                i += width;
                continue;
            }
        }
        i += 1;
    }
    return null;
}

pub fn findTemplateEnd(s: []const u8, start: usize) ?usize {
    const construct = findBraceConstruct(s, start) orelse return null;
    if (construct.open != start or construct.kind != .template) return null;
    return construct.close;
}

pub fn findParamEnd(s: []const u8, start: usize) ?usize {
    const construct = findBraceConstruct(s, start) orelse return null;
    if (construct.open != start or construct.kind != .parameter) return null;
    return construct.close;
}

const opaque_parser_tags = [_][]const u8{
    "nowiki",  "pre",      "gallery",      "indicator",       "ref",             "references", "templatestyles",
    "math",    "ce",       "chem",         "score",           "syntaxhighlight", "source",     "timeline",
    "hiero",   "poem",     "categorytree", "charinsert",      "graph",           "mapframe",   "maplink",
    "section", "inputbox", "imagemap",     "dynamicpagelist",
};

fn opaqueParserTagIndex(name: []const u8) ?usize {
    inline for (opaque_parser_tags, 0..) |tag, i|
        if (std.ascii.eqlIgnoreCase(name, tag)) return i;
    return null;
}

fn isOpaqueParserTag(name: []const u8) bool {
    return opaqueParserTagIndex(name) != null;
}

fn isLiteralParserTag(name: []const u8) bool {
    inline for (&.{
        "nowiki",          "pre",   "math",  "ce",       "chem",    "score",    "syntaxhighlight", "source",
        "timeline",        "hiero", "graph", "mapframe", "maplink", "inputbox", "imagemap",        "templatestyles",
        "dynamicpagelist",
    }) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn isTagNameBoundary(s: []const u8, pos: usize) bool {
    if (pos >= s.len) return true;
    return s[pos] == '>' or std.ascii.isWhitespace(s[pos]) or
        (s[pos] == '/' and pos + 1 < s.len and s[pos + 1] == '>');
}

pub fn rawTagEnd(s: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '>') return i + 1;
    }
    return null;
}

pub const PoemRegion = struct {
    open: usize,
    opening_end: usize,
    inner_end: usize,
    end: usize,
    self_closing: bool,
};
pub const ExpansionNode = union(enum) { construct: Construct, poem: PoemRegion };

// A direct forward-cursor lookup; speculative lookahead never shares these caches.
fn poemRegionAtCached(s: []const u8, start: usize, no_more_close: *bool, no_more_gt: *bool, unmatched_opening_end: ?*?usize) ?PoemRegion {
    if (start >= s.len or s[start] != '<') return null;
    const name_end = start + 1 + "poem".len;
    if (name_end > s.len or !std.ascii.eqlIgnoreCase(s[start + 1 .. name_end], "poem") or
        !isTagNameBoundary(s, name_end) or
        (name_end < s.len and s[name_end] == '/' and (name_end + 1 >= s.len or s[name_end + 1] != '>'))) return null;
    const opening_end = (if (no_more_gt.*) null else decodedTagEnd(s, start)) orelse {
        no_more_gt.* = true;
        return null;
    };
    if (opening_end >= 2 and s[opening_end - 2] == '/')
        return .{ .open = start, .opening_end = opening_end, .inner_end = opening_end, .end = opening_end, .self_closing = true };
    if (no_more_close.*) {
        if (unmatched_opening_end) |value| value.* = opening_end;
        return null;
    }
    const end = inclusionCloseEnd(s, opening_end, "poem") orelse {
        no_more_close.* = true;
        if (unmatched_opening_end) |value| value.* = opening_end;
        return null;
    };
    const closing_open = opening_end + (std.mem.lastIndexOfScalar(u8, s[opening_end..end], '<') orelse unreachable);
    return .{ .open = start, .opening_end = opening_end, .inner_end = closing_open, .end = end, .self_closing = false };
}
pub fn findNextExpansionNode(s: []const u8, start: usize) ?ExpansionNode {
    return findNextExpansionNodeMode(s, start, true);
}
pub fn findNextConstructOutsideLiteralTags(s: []const u8, start: usize) ?Construct {
    const node = findNextExpansionNodeMode(s, start, false) orelse return null;
    return switch (node) {
        .construct => |value| value,
        .poem => unreachable,
    };
}
// A refusal guard, not a link parser: only flat, balanced internal links are
// transparent to this narrowly scoped literal-source proof.
fn plainInternalLinksOnly(text: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfAny(u8, text[cursor..], "[]")) |relative| {
        const at = cursor + relative;
        if (!std.mem.startsWith(u8, text[at..], "[[")) return false;
        const close = std.mem.indexOfPos(u8, text, at + 2, "]]") orelse return false;
        if (close == at + 2 or std.mem.indexOfAny(u8, text[at + 2 .. close], "[]{}<>&\r\n") != null) return false;
        cursor = close + 2;
    }
    return true;
}

// Called only for an actual root ExpansionScan literal interval immediately
// after its normal append. The coordinates identify those exact output bytes;
// no finished-expansion substring search can manufacture this provenance.
pub fn markRootSingletonLiteralCurly(a: std.mem.Allocator, out: *dependency.Builder, source: []const u8, start: usize, end: usize, output_start: usize) !void {
    if (start > end or end > source.len or output_start > out.bytes.items.len) return;
    const literal = source[start..end];
    if (literal.len > 4096 or !std.mem.eql(u8, out.bytes.items[output_start..], literal)) return;
    const local_open = std.mem.indexOf(u8, literal, "{{") orelse return;
    const opening = start + local_open;
    if (std.mem.indexOfAny(u8, source[0..opening], "<>&\x7f") != null or
        std.mem.indexOfAny(u8, literal, "<>&\x7f") != null or
        !plainInternalLinksOnly(source[0..opening]) or
        std.mem.indexOfPos(u8, literal, local_open + 2, "{{") != null or
        std.mem.startsWith(u8, literal[local_open..], "{{{") or
        findTemplateEnd(source, opening) != null) return;
    const line_end = std.mem.indexOfScalarPos(u8, literal, local_open, '\n') orelse literal.len;
    const candidate = std.mem.trimEnd(u8, literal[local_open..line_end], " \t\r");
    if (candidate.len < 6 or candidate[candidate.len - 1] != '}' or candidate[candidate.len - 2] == '}' or
        std.mem.indexOfAny(u8, candidate[2 .. candidate.len - 1], "{}<>&\r\n") != null or
        !plainInternalLinksOnly(candidate[2 .. candidate.len - 1])) return;
    const pipe = std.mem.indexOfScalar(u8, candidate, '|') orelse return;
    const name = candidate[2..pipe];
    if (name.len == 0 or pipe + 1 >= candidate.len - 1) return;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return;
    try out.markLiteralCurly(a, output_start + local_open, output_start + local_open + 2);
    try out.markLiteralCurly(a, output_start + local_open + candidate.len - 1, output_start + local_open + candidate.len);
}

// Retain this state across successive nodes of one unchanged input only.
// Speculative brace parsing owns independent caches and never publishes misses.
pub const ExpansionScan = struct {
    conversion_enabled: bool = false,
    opaque_scan: OpaqueParserScan = .{},
    no_more_poem_close: bool = false,
    no_more_poem_gt: bool = false,
    pub fn next(self: *ExpansionScan, s: []const u8, start: usize, include_poem: bool) ?ExpansionNode {
        var i = start;
        while (i + 1 < s.len) {
            if (s[i] == '<') {
                if (include_poem) {
                    var unmatched_opening_end: ?usize = null;
                    if (poemRegionAtCached(s, i, &self.no_more_poem_close, &self.no_more_poem_gt, &unmatched_opening_end)) |region|
                        return .{ .poem = region };
                    if (unmatched_opening_end) |end| {
                        // Official recovery emits the entire opener literally;
                        // attributes are not expanded, while the body stays active.
                        i = end;
                        continue;
                    }
                }
                if (self.opaque_scan.literalEnd(s, i)) |end| {
                    i = end;
                    continue;
                }
            }
            if (s[i] == '{' and s[i + 1] == '{') {
                if (findBraceConstructCached(s, i, &self.opaque_scan, self.conversion_enabled)) |construct| return .{ .construct = construct };
            }
            i += 1;
        }
        return null;
    }
};

fn findNextExpansionNodeMode(s: []const u8, start: usize, include_poem: bool) ?ExpansionNode {
    var scan: ExpansionScan = .{};
    return scan.next(s, start, include_poem);
}

pub fn findTemplateOpenOutsideLiteralTags(s: []const u8, start: usize) ?usize {
    return if (findNextConstructOutsideLiteralTags(s, start)) |construct| construct.open else null;
}

// Caches belong to one monotonically forward scan of one input only.
// Unmatched extension openers are literal nodes, not protected EOF bodies.
pub const OpaqueParserScan = struct {
    no_more_gt_from: ?usize = null,
    no_more_close_from: [opaque_parser_tags.len]?usize = @splat(null),
    next_close_end: [opaque_parser_tags.len]?usize = @splat(null),

    fn remember(current: *?usize, from: usize) void {
        current.* = if (current.*) |previous| @min(previous, from) else from;
    }

    // A failed speculative parse may publish only offset-qualified absences.
    // Earlier probes still perform their own search; positive lookahead is not merged.
    fn mergeAbsence(self: *OpaqueParserScan, other: *const OpaqueParserScan) void {
        if (other.no_more_gt_from) |from| remember(&self.no_more_gt_from, from);
        for (other.no_more_close_from, 0..) |missing, slot| {
            if (missing) |from| remember(&self.no_more_close_from[slot], from);
        }
    }

    pub fn end(self: *OpaqueParserScan, s: []const u8, start: usize) ?usize {
        return self.endMode(s, start, false);
    }

    fn literalEnd(self: *OpaqueParserScan, s: []const u8, start: usize) ?usize {
        return self.endMode(s, start, true);
    }

    fn endMode(self: *OpaqueParserScan, s: []const u8, start: usize, literal_only: bool) ?usize {
        if (start >= s.len or s[start] != '<') return null;
        if (std.mem.startsWith(u8, s[start..], "<!--")) {
            const close = std.mem.indexOfPos(u8, s, start + 4, "-->") orelse return s.len;
            return close + 3;
        }
        var p = start + 1;
        if (p >= s.len or s[p] == '/') return null;
        const name_start = p;
        while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) : (p += 1) {}
        if (p == name_start or !isTagNameBoundary(s, p)) return null;
        const name = s[name_start..p];
        const slot = opaqueParserTagIndex(name) orelse return null;
        const no_gt = if (self.no_more_gt_from) |from| start >= from else false;
        const open_end = (if (no_gt) null else decodedTagEnd(s, start)) orelse {
            remember(&self.no_more_gt_from, start);
            return null;
        };
        // Use nowiki's specialized closed-region matcher; a missing closer
        // still leaves the complete opener literal and the body active.
        if (std.ascii.eqlIgnoreCase(name, "nowiki")) {
            var missing = if (self.no_more_close_from[slot]) |from| open_end >= from else false;
            const found = nowikiRegionEndCached(s, start, &missing);
            if (missing and found == null) remember(&self.no_more_close_from[slot], open_end);
            return found orelse open_end;
        }
        // Registered Cite attributes are raw extension-node text, not a fresh
        // transclusion input. Its body remains active for normal expansion.
        // This also preserves self-closing and unmatched opener attributes.
        if (literal_only and (std.ascii.eqlIgnoreCase(name, "ref") or
            std.ascii.eqlIgnoreCase(name, "references")))
            return open_end;
        if (open_end >= 2 and s[open_end - 2] == '/')
            return if (literal_only and !isLiteralParserTag(name)) null else open_end;
        var closed_end: ?usize = null;
        const no_close = if (self.no_more_close_from[slot]) |from| open_end >= from else false;
        if (!no_close) {
            if (self.next_close_end[slot]) |known| {
                if (known > open_end) closed_end = known;
            }
            if (closed_end == null) {
                closed_end = inclusionCloseEnd(s, open_end, name);
                self.next_close_end[slot] = closed_end;
                if (closed_end == null) remember(&self.no_more_close_from[slot], open_end);
            }
        }
        if (closed_end) |closed|
            return if (literal_only and !isLiteralParserTag(name)) null else closed;
        // Emit the entire unmatched opener literally, then resume the body.
        // Its attribute templates must not be expanded.
        return open_end;
    }
};

pub fn opaqueParserRegionEnd(s: []const u8, start: usize) ?usize {
    var scan: OpaqueParserScan = .{};
    return scan.end(s, start);
}

pub fn findTopDelimiter(s: []const u8, needle: u8) ?usize {
    return findTopDelimiterWithConversion(s, needle, false);
}

pub fn findTopDelimiterWithConversion(s: []const u8, needle: u8, conversion_enabled: bool) ?usize {
    return findTopDelimiterImpl(s, needle, false, conversion_enabled);
}

pub const ParserColon = struct { index: usize, len: usize };

pub fn findTopParserColon(s: []const u8) ?ParserColon {
    return findTopParserColonWithConversion(s, false);
}

pub fn findTopParserColonWithConversion(s: []const u8, conversion_enabled: bool) ?ParserColon {
    const index = findTopDelimiterImpl(s, ':', true, conversion_enabled) orelse return null;
    return .{ .index = index, .len = if (s[index] == ':') 1 else "：".len };
}

fn findTopDelimiterImpl(s: []const u8, needle: u8, fullwidth_colon: bool, conversion_enabled: bool) ?usize {
    var scan: OpaqueParserScan = .{};
    return findTopDelimiterFrom(s, needle, fullwidth_colon, 0, &scan, conversion_enabled);
}

fn findTopDelimiterFrom(s: []const u8, needle: u8, fullwidth_colon: bool, start: usize, opaque_scan: *OpaqueParserScan, conversion_enabled: bool) ?usize {
    var braces: [128]usize = undefined;
    var brace_depth: usize = 0;
    var saved_minus: [128]bool = undefined;
    var square: usize = 0;
    var square_braces: [128]usize = undefined;
    // Pinned MediaWiki Preprocessor_Hash: -{ owns its internal pipes only
    // when global language conversion is enabled; -{{ remains a brace opener.
    var conversions: [128]struct { braces: usize, square: usize } = undefined;
    var conversion_depth: usize = 0;
    var i = start;
    while (i < s.len) {
        if (opaque_scan.end(s, i)) |region_end| {
            i = region_end;
            continue;
        }
        if (conversion_enabled and std.mem.startsWith(u8, s[i..], "-{") and
            (i + 2 == s.len or s[i + 2] != '{')) {
            if (conversion_depth == conversions.len) return null;
            conversions[conversion_depth] = .{ .braces = brace_depth, .square = square };
            conversion_depth += 1;
            i += 2;
            continue;
        }
        const conversion_here = conversion_depth != 0 and
            conversions[conversion_depth - 1].braces == brace_depth and
            conversions[conversion_depth - 1].square == square;
        if (conversion_here and std.mem.startsWith(u8, s[i..], "}-")) {
            conversion_depth -= 1;
            i += 2;
            continue;
        }
        if (s[i] == '{') {
            const count = repeatedByteRun(s, i, '{');
            if (count >= 2) {
                if (brace_depth == braces.len) return null;
                braces[brace_depth] = count;
                saved_minus[brace_depth] = conversion_enabled and i != 0 and s[i - 1] == '-';
                brace_depth += 1;
                i += count;
                continue;
            }
        }
        if (s[i] == '}' and brace_depth != 0 and !conversion_here and (!conversion_enabled or square == 0 or brace_depth > square_braces[square - 1])) {
            const close_count = repeatedByteRun(s, i, '}');
            const open_count = braces[brace_depth - 1];
            const width = matchingBraceWidth(open_count, close_count);
            if (width != 0) {
                const minus = saved_minus[brace_depth - 1];
                brace_depth -= 1;
                const remainder = open_count - width;
                if (remainder >= 2) {
                    braces[brace_depth] = remainder;
                    saved_minus[brace_depth] = minus;
                    brace_depth += 1;
                } else if (remainder == 1 and minus) {
                    if (conversion_depth == conversions.len) return null;
                    conversions[conversion_depth] = .{ .braces = brace_depth, .square = square };
                    conversion_depth += 1;
                }
                i += width;
                continue;
            }
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "[[")) {
            if (conversion_enabled) {
                if (square == square_braces.len) return null;
                square_braces[square] = brace_depth;
            }
            square += 1;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "]]") and square != 0 and !conversion_here and (!conversion_enabled or brace_depth == square_braces[square - 1])) {
            square -= 1;
            i += 2;
            continue;
        }
        if (brace_depth == 0 and square == 0 and conversion_depth == 0 and
            (s[i] == needle or (fullwidth_colon and std.mem.startsWith(u8, s[i..], "：")))) return i;
        i += 1;
    }
    return null;
}

pub fn splitWikitextTop(a: std.mem.Allocator, s: []const u8, delimiter: u8, out: *std.ArrayList([]const u8)) !void {
    return splitWikitextTopWithConversion(a, s, delimiter, out, false);
}

pub fn splitWikitextTopWithConversion(a: std.mem.Allocator, s: []const u8, delimiter: u8, out: *std.ArrayList([]const u8), conversion_enabled: bool) !void {
    var start: usize = 0;
    var opaque_scan: OpaqueParserScan = .{};
    while (start < s.len) {
        const cut = findTopDelimiterFrom(s, delimiter, false, start, &opaque_scan, conversion_enabled) orelse break;
        try out.append(a, s[start..cut]);
        start = cut + 1;
    }
    try out.append(a, s[start..]);
}

test "parser colon recognizes ASCII and fullwidth outside nested constructs" {
    try std.testing.expectEqual(ParserColon{ .index = 3, .len = 3 }, findTopParserColon("#if：yes").?);
    try std.testing.expectEqual(ParserColon{ .index = 3, .len = 1 }, findTopParserColon("#if:yes").?);
    const head = "{{name|inner：value}}：argument:tail";
    try std.testing.expectEqual(ParserColon{ .index = "{{name|inner：value}}".len, .len = 3 }, findTopParserColon(head).?);
    try std.testing.expect(findTopParserColon("[[a：b]]<nowiki>:</nowiki>") == null);
}

pub const ParameterSplit = struct { key: []const u8, default: ?[]const u8 };
pub fn splitParameter(s: []const u8) ParameterSplit {
    return splitParameterWithConversion(s, false);
}

pub fn splitParameterWithConversion(s: []const u8, conversion_enabled: bool) ParameterSplit {
    var scan: OpaqueParserScan = .{};
    const bar = findTopDelimiterFrom(s, '|', false, 0, &scan, conversion_enabled) orelse
        return .{ .key = s, .default = null };
    // Parser::argSubstitution evaluates only the first part when lookup fails.
    const end = findTopDelimiterFrom(s, '|', false, bar + 1, &scan, conversion_enabled) orelse s.len;
    return .{ .key = s[0..bar], .default = s[bar + 1 .. end] };
}

test "template opener scan skips literal extension bodies but enters wikitext extensions" {
    const source = "a<NoWiKi class='x'>{{hidden}}</NoWiKi>b{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(source, 0).?);
    try std.testing.expectEqual(@as(usize, 8), findTemplateOpenOutsideLiteralTags("<nowiki>{{hidden}}", 0).?);
    try std.testing.expectEqual(@as(usize, 10), findTemplateOpenOutsideLiteralTags("<nowiki/> {{x}}", 0).?);
    const math = "<math>{{hidden}}</math>{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, math, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(math, 0).?);
    const syntax = "<syntaxhighlight lang='lua'>{{hidden}}</syntaxhighlight>{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, syntax, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(syntax, 0).?);
    try std.testing.expectEqual(@as(usize, 5), findTemplateOpenOutsideLiteralTags("<ref>{{visible}}</ref>", 0).?);
    try std.testing.expectEqual(@as(usize, 6), findTemplateOpenOutsideLiteralTags("<poem>{{visible}}</poem>", 0).?);
    try std.testing.expectEqual(@as(usize, 5), findTemplateOpenOutsideLiteralTags("<pre:{{visible}}>", 0).?);
}

test "nested template and parameter boundaries match MediaWiki preprocessing" {
    const template = "{{a|{{b|x={{{p|q}}}}}|z}}";
    try std.testing.expectEqual(template.len - 2, findTemplateEnd(template, 0).?);
    const parameter = "{{{x|{{y|z}}}}}";
    try std.testing.expectEqual(parameter.len - 3, findParamEnd(parameter, 0).?);
    const dynamic_template = "{{{{{name|Hello}}}|Bob}}";
    const dynamic = findNextConstructOutsideLiteralTags(dynamic_template, 0).?;
    try std.testing.expectEqual(@as(usize, 0), dynamic.open);
    try std.testing.expectEqual(ConstructKind.template, dynamic.kind);
    try std.testing.expectEqual(dynamic_template.len - 2, dynamic.close);
    const dynamic_parameter = "{{{{{safesubst:#if:{{{defparam|}}}|{{{defparam}}}|def}}|d}}}";
    const parameter_construct = findNextConstructOutsideLiteralTags(dynamic_parameter, 0).?;
    try std.testing.expectEqual(@as(usize, 0), parameter_construct.open);
    try std.testing.expectEqual(ConstructKind.parameter, parameter_construct.kind);
    try std.testing.expectEqual(dynamic_parameter.len - 3, parameter_construct.close);
    const literal_then_parameter = "{{{{name}}}}";
    const literal_construct = findNextConstructOutsideLiteralTags(literal_then_parameter, 0).?;
    try std.testing.expectEqual(@as(usize, 1), literal_construct.open);
    try std.testing.expectEqual(ConstructKind.parameter, literal_construct.kind);
    try std.testing.expectEqual(literal_then_parameter.len - 4, literal_construct.close);
    try std.testing.expectEqual(@as(usize, 2), findTopDelimiter("nm=&nbsp;{{{{{5}}}|x}}", '=').?);
    try std.testing.expect(findTopDelimiter("x=<math>a=b</math>", '=') == 1);
    try std.testing.expect(findTopDelimiter("<math>a=b</math>", '=') == null);
    const pronunciation =
        "it-pr|À*<pre:{{q|letter name}}><hmp:a>|a<pre:{{q|phonemic realization}}><rhyme:->";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(std.testing.allocator);
    try splitWikitextTop(std.testing.allocator, pronunciation, '|', &parts);
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("it-pr", parts.items[0]);
    try std.testing.expectEqualStrings("À*<pre:{{q|letter name}}><hmp:a>", parts.items[1]);
    try std.testing.expectEqualStrings("a<pre:{{q|phonemic realization}}><rhyme:->", parts.items[2]);
}

test "decoded comments and transclusion tags share one preprocessing core" {
    const a = std.testing.allocator;
    const stripped = try stripDecodedComments(a, "a<!--x-->b");
    defer a.free(stripped);
    try std.testing.expectEqualStrings("ab", stripped);
    const transcluded = try transcludeDecodedAlloc(a, "A<noinclude>X</noinclude>B<includeonly>C</includeonly>D");
    defer a.free(transcluded);
    try std.testing.expectEqualStrings("ABCD", transcluded);
    const only = try transcludeDecodedAlloc(a, "A<onlyinclude>B</onlyinclude>C");
    defer a.free(only);
    try std.testing.expectEqualStrings("B", only);
}

test "unclosed corpus noinclude tails preserve transcluded content" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        // Exact 2026-10-01 bodies: af:Sjabloon:Sub and an:Plantilla:io/ms.
        .{ .source = "<includeonly><sub>{{{1}}}</sub></includeonly><noinclude>", .expected = "<sub>{{{1}}}</sub>" },
        .{ .source = "[[ido|Ido]] <noinclude>", .expected = "[[ido|Ido]] " },
        .{ .source = "[[malayo|Malayo]]<noinclude>[[categoría:Plantillas de traducción|ms]]", .expected = "[[malayo|Malayo]]" },
        .{ .source = "<!--old--><includeonly>category</includeonly><noinclude>docs</noinclude>\n{{betekenisse}}\n#meaning\n<noinclude>", .expected = "category\n{{betekenisse}}\n#meaning\n" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "inclusion tag boundaries attributes first close and missing ends follow MediaWiki" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "A<noinclude>B", .expected = "A" },
        .{ .source = "A<NOINCLUDE>B", .expected = "A<NOINCLUDE>B" },
        .{ .source = "A<NOINCLUDE>B</noinclude>C", .expected = "AC" },
        .{ .source = "A<noinclude>B</NOINCLUDE >C", .expected = "AC" },
        .{ .source = "A<noinclude>B</noinclude/>C", .expected = "A" },
        .{ .source = "A<noinclude>B</noinclude x>C", .expected = "A" },
        .{ .source = "A</noinclude>B", .expected = "A</noinclude>B" },
        .{ .source = "A<noinclude x=1>B</noinclude>C", .expected = "AC" },
        .{ .source = "A<noinclude/>B", .expected = "AB" },
        .{ .source = "A<NOINCLUDE />B", .expected = "AB" },
        .{ .source = "A<noinclude / >B", .expected = "A" },
        .{ .source = "A<noinclude/ >B", .expected = "A<noinclude/ >B" },
        .{ .source = "A<noinclude>B<noinclude>C</noinclude>D</noinclude>E", .expected = "AD</noinclude>E" },
        .{ .source = "A<includeonly x=1>B</includeonly x=2>C", .expected = "ABC" },
        .{ .source = "A<includeonly x=\">\">B</includeonly>C", .expected = "A\">BC" },
        .{ .source = "A<noincludeX>B</noincludeX>C", .expected = "A<noincludeX>B</noincludeX>C" },
        .{ .source = "A< includeonly>B</ includeonly>C", .expected = "A< includeonly>B</ includeonly>C" },
        .{ .source = "A<noinclude", .expected = "A<noinclude" },
        .{ .source = "A<includeonly ", .expected = "A<includeonly " },
        .{ .source = "A<noinclude <!--hidden", .expected = "A<noinclude " },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "onlyinclude uses exact raw delimiters and a flat selector" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "A<onlyinclude>B", .expected = "A<onlyinclude>B" },
        .{ .source = "A<onlyinclude/>B", .expected = "A<onlyinclude/>B" },
        .{ .source = "A<ONLYINCLUDE>B</ONLYINCLUDE>C", .expected = "A<ONLYINCLUDE>B</ONLYINCLUDE>C" },
        .{ .source = "A<onlyinclude x=1>B</onlyinclude>C", .expected = "A<onlyinclude x=1>B</onlyinclude>C" },
        .{ .source = "A<onlyinclude>B</onlyinclude >C", .expected = "A<onlyinclude>B</onlyinclude >C" },
        .{ .source = "A</onlyinclude>B<onlyinclude>C", .expected = "C" },
        .{ .source = "A<onlyinclude>B</onlyinclude>C<onlyinclude>D", .expected = "BD" },
        .{ .source = "A<onlyinclude>B<onlyinclude>C</onlyinclude>D</onlyinclude>E", .expected = "B<onlyinclude>C" },
        .{ .source = "A<!--<onlyinclude>B</onlyinclude>-->C", .expected = "B" },
        .{ .source = "A<nowiki><onlyinclude>B</onlyinclude></nowiki>C", .expected = "B" },
        .{ .source = "A<noinclude><onlyinclude>B</onlyinclude></noinclude>C", .expected = "B" },
        .{ .source = "<onlyinclude>A<!--</onlyinclude>-->B", .expected = "AB" },
        .{ .source = "<onlyinclude>A<noinclude></onlyinclude></noinclude>B", .expected = "AB" },
        .{ .source = "<onlyinclude>A<nowiki></onlyinclude></nowiki>B", .expected = "A<nowiki></onlyinclude></nowiki>B" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "transclusion preserves first opened literal regions" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "<nowiki>A<noinclude>B</noinclude>C<!--D--></nowiki>", .expected = "<nowiki>A<noinclude>B</noinclude>C<!--D--></nowiki>" },
        .{ .source = "<ref><includeonly>A</includeonly></ref>", .expected = "<ref><includeonly>A</includeonly></ref>" },
        .{ .source = "A<noinclude>B<!--</noinclude>-->C", .expected = "A-->C" },
        .{ .source = "A<noinclude>B<nowiki></noinclude></nowiki>C", .expected = "A</nowiki>C" },
        .{ .source = "<nowiki>A<noinclude>B", .expected = "<nowiki>A" },
        .{ .source = "A<!--<noinclude>B--><includeonly>C</includeonly>", .expected = "AC" },
        .{ .source = "<nowiki/><includeonly>A</includeonly>", .expected = "<nowiki/>A" },
    };
    for (cases) |case| {
        const actual = try transcludeDecodedAlloc(std.testing.allocator, case.source);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "grammar syntax oracle comment only line preserves list adjacency and authored blanks" {
    const a = std.testing.allocator;
    // A comment occupying its entire physical line vanishes upstream, including
    // the redundant newline; authored blank lines must still remain blank.
    const joined = try stripDecodedComments(a, "# first\n<!--hidden-->\n# second");
    defer a.free(joined);
    const blank = try stripDecodedComments(a, "# first\n\n# second");
    defer a.free(blank);
    try std.testing.expectEqualStrings("# first\n\n# second", blank);
    const inline_comment = try stripDecodedComments(a, "before<!--hidden-->after");
    defer a.free(inline_comment);
    try std.testing.expectEqualStrings("beforeafter", inline_comment);
    const protected = try stripDecodedComments(a, "<nowiki><!--hidden--></nowiki>");
    defer a.free(protected);
    try std.testing.expectEqualStrings("<nowiki><!--hidden--></nowiki>", protected);
    try std.testing.expectEqualStrings("# first\n# second", joined);
}

test "grammar syntax oracle standalone comment variants retain list adjacency" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "# first\n  <!-- hidden --> \t\n# second",
        "# first\n<!-- hidden\nmore hidden -->\n# second",
        "# first\n<!-- one -->\n<!-- two -->\n# second",
    }) |source| {
        const result = try stripDecodedComments(a, source);
        defer a.free(result);
        try std.testing.expectEqualStrings("# first\n# second", result);
    }
    const source = "# first\n<nowiki><!--hidden--></nowiki>\n# second";
    const protected = try stripDecodedComments(a, source);
    defer a.free(protected);
    try std.testing.expectEqualStrings(source, protected);
    const blanks = try stripDecodedComments(a, "# first\n\n<!--hidden-->\n\n# second");
    defer a.free(blanks);
    try std.testing.expectEqualStrings("# first\n\n\n# second", blanks);
}

test "grammar syntax oracle multiple comments on a line preserve visible content" {
    const a = std.testing.allocator;
    const standalone = try stripDecodedComments(a, "# first\n<!--one--> <!--two-->\n# second");
    defer a.free(standalone);
    try std.testing.expectEqualStrings("# first\n# second", standalone);
    const inline_comments = try stripDecodedComments(a, "before<!--one--> <!--two-->after");
    defer a.free(inline_comments);
    try std.testing.expectEqualStrings("before after", inline_comments);
    const protected = try stripDecodedComments(a, "<nowiki>first\n<!--one--></nowiki>\n<!--two-->\nafter");
    defer a.free(protected);
    try std.testing.expectEqualStrings("<nowiki>first\n<!--one--></nowiki>\nafter", protected);
}

test "protected comment boundary preserves closed pre and removes outside comments" {
    const a = std.testing.allocator;
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "outside<!--hide--><pre title='>'><!--literal-->&lt;b&gt;&amp;lt;[[B]]</pre><!--hide-->tail", .expected = "outside<pre title='>'><!--literal-->&lt;b&gt;&amp;lt;[[B]]</pre>tail" },
        .{ .source = "<PRE><!--literal--></PRE ><!--hide-->tail", .expected = "<PRE><!--literal--></PRE >tail" },
        .{ .source = "<pre/><!--hide-->tail", .expected = "<pre/>tail" },
        .{ .source = "A<pre>B<!--hidden-->&lt;i&gt;[[C]]", .expected = "A<pre>B&lt;i&gt;[[C]]" },
        .{ .source = "<nowiki><!--literal-->&lt;/nowiki&gt;</nowiki><!--hide-->tail", .expected = "<nowiki><!--literal-->&lt;/nowiki&gt;</nowiki>tail" },
    };
    for (cases) |case| {
        const actual = try stripDecodedComments(a, case.source);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "closed code extensions keep literal comments before behavior control matching" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "source", "syntaxhighlight" }) |tag| {
        const input = try std.fmt.allocPrint(a, "<{s} lang=\"text\">\n<!--__NOEDITSECTION__-->\n&#95;&#95;NOEDITSECTION&#95;&#95; {{{{T}}}}\n</{s}><!--outside-->tail", .{ tag, tag });
        defer a.free(input);
        const expected = try std.fmt.allocPrint(a, "<{s} lang=\"text\">\n<!--__NOEDITSECTION__-->\n&#95;&#95;NOEDITSECTION&#95;&#95; {{{{T}}}}\n</{s}>tail", .{ tag, tag });
        defer a.free(expected);
        const actual = try stripDecodedComments(a, input);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
        const unclosed = try std.fmt.allocPrint(a, "<{s}>A<!--ordinary-->B", .{tag});
        defer a.free(unclosed);
        const unchanged = try std.fmt.allocPrint(a, "<{s}>AB", .{tag});
        defer a.free(unchanged);
        const recovered = try stripDecodedComments(a, unclosed);
        defer a.free(recovered);
        try std.testing.expectEqualStrings(unchanged, recovered);
    }
    const joined = try stripDecodedComments(a, "__NOEDIT<!--ordinary-->SECTION__A");
    defer a.free(joined);
    try std.testing.expectEqualStrings("__NOEDITSECTION__A", joined);
}

test "nowiki preprocessing requires immediate name and first valid closer" {
    const a = std.testing.allocator;
    const unclosed = "<nowiki>A<!--hide-->{{visible}}";
    const stripped = try stripDecodedComments(a, unclosed);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("<nowiki>A{{visible}}", stripped);
    try std.testing.expect(nowikiRegionEnd(unclosed, 0) == null);
    try std.testing.expectEqual(@as(usize, 8), opaqueParserRegionEnd(unclosed, 0).?);
    try std.testing.expectEqual(@as(usize, 20), findTemplateOpenOutsideLiteralTags(unclosed, 0).?);
    const malformed_open = "< nowiki>{{visible}}</nowiki>";
    try std.testing.expect(opaqueParserRegionEnd(malformed_open, 0) == null);
    try std.testing.expectEqual(@as(usize, 9), findTemplateOpenOutsideLiteralTags(malformed_open, 0).?);
    const closed = "<NoWiKi>{{hidden}}<!--literal--></nowiki extra>{{alsohidden}}</NOWIKI \t>{{visible}}";
    const preserved = try stripDecodedComments(a, closed);
    defer a.free(preserved);
    try std.testing.expectEqualStrings(closed, preserved);
    try std.testing.expectEqual(closed.len - "{{visible}}".len, opaqueParserRegionEnd(closed, 0).?);
    try std.testing.expectEqual(closed.len - "{{visible}}".len, findTemplateOpenOutsideLiteralTags(closed, 0).?);
    try std.testing.expect(nowikiRegionEnd("<nowiki / >{{visible}}", 0) == null);
    try std.testing.expectEqual(@as(usize, 11), opaqueParserRegionEnd("<nowiki / >{{visible}}", 0).?);
    try std.testing.expectEqual(@as(usize, 11), findTemplateOpenOutsideLiteralTags("<nowiki / >{{visible}}", 0).?);
    // An unmatched literal extension also leaves its body active.
    try std.testing.expectEqual(@as(usize, 6), findTemplateOpenOutsideLiteralTags("<math>{{hidden}}", 0).?);
}

test "missing nowiki closer cache retains later self-closing markers" {
    var missing = false;
    const input = "<nowiki><!--ordinary--><nowiki/><nowiki>{{visible}}";
    try std.testing.expect(nowikiRegionEndCached(input, 0, &missing) == null);
    try std.testing.expect(missing);
    try std.testing.expectEqual(@as(usize, 32), nowikiRegionEndCached(input, 23, &missing).?);
    try std.testing.expect(nowikiRegionEndCached(input, 32, &missing) == null);
    try std.testing.expectEqual(@as(usize, 40), findTemplateOpenOutsideLiteralTags(input, 0).?);
    const stripped = try stripDecodedComments(std.testing.allocator, input);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("<nowiki><nowiki/><nowiki>{{visible}}", stripped);
}

test "comment normalization caches repeated missing code-extension closers without changing protection" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    for (0..256) |_| {
        try source.appendSlice(a, "<pre>A<!--a-->B<source/>C<!--b-->D<source>E<!--c-->F<syntaxhighlight />G<!--d-->H<syntaxhighlight>I<!--e-->J");
        try expected.appendSlice(a, "<pre>AB<source/>CD<source>EF<syntaxhighlight />GH<syntaxhighlight>IJ");
    }
    const actual = try stripDecodedComments(a, source.items);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected.items, actual);
    const mixed = "<pre>A<!--literal--></pre><source />B<!--outside-->C<source>D<!--literal--></source><syntaxhighlight>E<!--literal--></syntaxhighlight>";
    const mixed_actual = try stripDecodedComments(a, mixed);
    defer a.free(mixed_actual);
    try std.testing.expectEqualStrings("<pre>A<!--literal--></pre><source />BC<source>D<!--literal--></source><syntaxhighlight>E<!--literal--></syntaxhighlight>", mixed_actual);
    // A missing pre closer cannot poison a later closed source scope.
    const independent = try stripDecodedComments(a, "<pre>A<!--outside--><source>B<!--literal--></source><!--outside-->C");
    defer a.free(independent);
    try std.testing.expectEqualStrings("<pre>A<source>B<!--literal--></source>C", independent);
    const first_closer = try stripDecodedComments(a, "<pre><pre>A<!--literal--></pre><!--outside-->B");
    defer a.free(first_closer);
    try std.testing.expectEqualStrings("<pre><pre>A<!--literal--></pre>B", first_closer);
}

test "expansion nodes dispatch raw poem before its inner constructs without changing legacy scan" {
    const source = "x<poem>{{T}}</poem>{{after}}";
    const node = findNextExpansionNode(source, 0).?;
    const region = node.poem;
    try std.testing.expectEqual(@as(usize, 1), region.open);
    try std.testing.expectEqualStrings("{{T}}", source[region.opening_end..region.inner_end]);
    try std.testing.expectEqualStrings("{{after}}", source[region.end..]);
    try std.testing.expect(!region.self_closing);
    try std.testing.expectEqual(@as(usize, 7), findNextConstructOutsideLiteralTags(source, 0).?.open);
    try std.testing.expectEqual(@as(usize, 19), findNextExpansionNode(source, region.end).?.construct.open);
    try std.testing.expectEqual(@as(usize, 0), findNextExpansionNode("{{before}}<poem>x</poem>", 0).?.construct.open);
}
test "expansion poem regions preserve first strict closer selfclosing and protected boundaries" {
    const source = "<nowiki><poem>hidden</poem></nowiki><PoEm a='>'>first</poem extra>second</PoEm >{{after}}";
    const region = findNextExpansionNode(source, 0).?.poem;
    try std.testing.expectEqualStrings("'>first</poem extra>second", source[region.opening_end..region.inner_end]);
    try std.testing.expectEqualStrings("{{after}}", source[region.end..]);
    const empty = findNextExpansionNode("<poem/>{{after}}", 0).?.poem;
    try std.testing.expect(empty.self_closing);
    try std.testing.expectEqual(@as(usize, 7), empty.end);
    try std.testing.expect(std.meta.activeTag(findNextExpansionNode("< poem>{{visible}}</poem>", 0).?) == .construct);
    const unmatched = findNextExpansionNode("<poem>{{active}}", 0).?.construct;
    try std.testing.expectEqual(@as(usize, 6), unmatched.open);
    const spaced = "<poem / >body</poem>{{after}}";
    const paired = findNextExpansionNode(spaced, 0).?.poem;
    try std.testing.expect(!paired.self_closing);
    try std.testing.expectEqualStrings("body", spaced[paired.opening_end..paired.inner_end]);
    try std.testing.expectEqualStrings("{{after}}", spaced[paired.end..]);
    try std.testing.expectEqual(@as(usize, 9), findNextExpansionNode("<poem / >{{active}}", 0).?.construct.open);
    try std.testing.expectEqual(@as(usize, 8), findNextExpansionNode("<poem/ >{{active}}", 0).?.construct.open);
    const attribute_then_body = findNextExpansionNode("<poem a=\"{{A}}\">{{B}}", 0).?.construct;
    try std.testing.expectEqual(@as(usize, 16), attribute_then_body.open);
    const after_missing = findNextExpansionNode("<poem a=\"{{A}}\"><poem b=\"{{C}}\">{{B}}", 0).?.construct;
    try std.testing.expectEqual(@as(usize, 32), after_missing.open);
    const resumed = "<poem>{{active}}<poem/>";
    const first = findNextExpansionNode(resumed, 0).?.construct;
    try std.testing.expectEqual(@as(usize, 6), first.open);
    try std.testing.expect(findNextExpansionNode(resumed, first.close + 2).?.poem.self_closing);
}
test "authored comment policy preserves only actual matched raw poem before hook" {
    const source = "<!--before--><poem>A<!--inline-->\n<!--line-->\n::B<nowiki><!--literal--></nowiki></poem><!--after-->{{T}}";
    const preserved = try stripDecodedCommentsPreservingPoem(std.testing.allocator, source);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("<poem>A<!--inline-->\n<!--line-->\n::B<nowiki><!--literal--></nowiki></poem>{{T}}", preserved);
    const ordinary = try stripDecodedComments(std.testing.allocator, source);
    defer std.testing.allocator.free(ordinary);
    try std.testing.expectEqualStrings("<poem>A\n::B<nowiki><!--literal--></nowiki></poem>{{T}}", ordinary);
    const unmatched = try stripDecodedCommentsPreservingPoem(std.testing.allocator, "<poem>A<!--gone-->{{T}}");
    defer std.testing.allocator.free(unmatched);
    try std.testing.expectEqualStrings("<poem>A{{T}}", unmatched);
}
test "poem preserving input policy bounds missing closer scans and retains transclusion raw body" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..256) |_| try input.appendSlice(std.testing.allocator, "<poem><!--gone-->");
    try input.appendSlice(std.testing.allocator, "<poem/>{{T}}");
    const stripped = try stripDecodedCommentsPreservingPoem(std.testing.allocator, input.items);
    defer std.testing.allocator.free(stripped);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "<!--") == null);
    const node = findNextExpansionNode(stripped, 0).?.poem;
    try std.testing.expect(node.self_closing);
    const transcluded = try transcludeDecodedForParsingAlloc(std.testing.allocator, "<noinclude>excluded</noinclude><poem>A<!--kept-->\n{{T}}</poem>");
    defer std.testing.allocator.free(transcluded);
    try std.testing.expectEqualStrings("<noinclude/><poem>A<!--kept-->\n{{T}}</poem>", transcluded);
}

test "unmatched literal extension openers resume active body constructs" {
    const a = std.testing.allocator;
    for (opaque_parser_tags) |name| {
        if (!isLiteralParserTag(name)) continue;
        const input = try std.fmt.allocPrint(a, "<{s} data='{{{{hidden}}}}'>{{{{visible}}}}", .{name});
        defer a.free(input);
        try std.testing.expectEqual(std.mem.indexOf(u8, input, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(input, 0).?);
        const closed = try std.fmt.allocPrint(a, "<{s}>{{{{hidden}}}}</{s}>{{{{visible}}}}", .{ name, name });
        defer a.free(closed);
        try std.testing.expectEqual(std.mem.indexOf(u8, closed, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(closed, 0).?);
    }
    try std.testing.expectEqual(@as(usize, 6), findTemplateOpenOutsideLiteralTags("<math {{visible}}", 0).?);
    try std.testing.expect(findTemplateOpenOutsideLiteralTags("<!--{{hidden}}", 0) == null);
    const braced = "{{Hello|<math>x|tail}}";
    try std.testing.expectEqual(braced.len - 2, findNextConstructOutsideLiteralTags(braced, 0).?.close);
    try std.testing.expectEqual(std.mem.indexOfScalar(u8, "<math>x|tail", '|').?, findTopDelimiter("<math>x|tail", '|').?);
    const paired = "<math>x|y</math>|tail";
    try std.testing.expectEqual(std.mem.lastIndexOfScalar(u8, paired, '|').?, findTopDelimiter(paired, '|').?);
}

test "unmatched extension scan caches misses without hiding another closed family" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    for (0..2048) |_| try input.appendSlice(a, "<math data='literal'>");
    try input.appendSlice(a, "<source>{{hidden}}</source>{{visible}}");
    try std.testing.expectEqual(std.mem.indexOf(u8, input.items, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(input.items, 0).?);
    var missing_gt: std.ArrayList(u8) = .empty;
    defer missing_gt.deinit(a);
    for (0..2048) |_| try missing_gt.appendSlice(a, "<math ");
    try missing_gt.appendSlice(a, "{{visible}}");
    try std.testing.expectEqual(std.mem.indexOf(u8, missing_gt.items, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(missing_gt.items, 0).?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendParsingText(a, &out, "<math>body<noinclude/>tail");
    try std.testing.expectEqualStrings("<math>bodytail", out.items);
}

test "successive expansion nodes retain unmatched extension misses across calls" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    for (0..1024) |_| try input.appendSlice(a, "<math>{{visible}}");
    for ([_]bool{ false, true }) |include_poem| {
        var scan: ExpansionScan = .{};
        var pos: usize = 0;
        var count: usize = 0;
        while (scan.next(input.items, pos, include_poem)) |node| {
            const construct = node.construct;
            try std.testing.expectEqual(pos + "<math>".len, construct.open);
            pos = construct.close + 2;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1024), count);
        try std.testing.expectEqual(input.items.len, pos);
    }
    const nonliteral = "<ref data='{{hidden}}'>{{visible}}";
    try std.testing.expectEqual(std.mem.indexOf(u8, nonliteral, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(nonliteral, 0).?);
    const closed = "<ref data='{{active}}'>{{body}}</ref>";
    try std.testing.expectEqual(std.mem.indexOf(u8, closed, "{{body}}").?, findTemplateOpenOutsideLiteralTags(closed, 0).?);
}

test "complete brace roots commit scan misses while failed lookahead retains earlier closed scopes" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    for (0..1024) |_| try input.appendSlice(a, "{{Hello|<math>x|1}}");
    var scan: ExpansionScan = .{};
    var pos: usize = 0;
    var count: usize = 0;
    while (scan.next(input.items, pos, true)) |node| {
        const construct = node.construct;
        try std.testing.expectEqual(pos, construct.open);
        pos = construct.close + 2;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1024), count);
    try std.testing.expectEqual(input.items.len, pos);
    const failed = "{{broken <math>{{hidden}}</math> {{visible}} <math>tail";
    var independent: ExpansionScan = .{};
    const visible = independent.next(failed, 0, true).?.construct;
    try std.testing.expectEqual(std.mem.indexOf(u8, failed, "{{visible}}").?, visible.open);
    const no_gt = "{{broken <math>{{hidden}}</math> {{visible}} <math ";
    var separate: ExpansionScan = .{};
    try std.testing.expectEqual(std.mem.indexOf(u8, no_gt, "{{visible}}").?, separate.next(no_gt, 0, true).?.construct.open);
    var failed_roots: std.ArrayList(u8) = .empty;
    defer failed_roots.deinit(a);
    for (0..1024) |_| try failed_roots.appendSlice(a, "{{broken <math>tail ");
    var repeated: ExpansionScan = .{};
    try std.testing.expect(repeated.next(failed_roots.items, 0, true) == null);
}

test "extension short tags require adjacent slash and preserve paired literal bodies" {
    for ([_][]const u8{ "math", "pre", "source", "syntaxhighlight", "nowiki" }) |name| {
        const a = std.testing.allocator;
        const paired = try std.fmt.allocPrint(a, "<{s} / >{{{{hidden}}}}</{s}>{{{{visible}}}}", .{ name, name });
        defer a.free(paired);
        try std.testing.expectEqual(std.mem.indexOf(u8, paired, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(paired, 0).?);
        const malformed = try std.fmt.allocPrint(a, "<{s}/ >{{{{visible}}}}</{s}>", .{ name, name });
        defer a.free(malformed);
        try std.testing.expectEqual(std.mem.indexOf(u8, malformed, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(malformed, 0).?);
    }
    const spaced = "< math>{{visible}}</math>";
    try std.testing.expectEqual(std.mem.indexOf(u8, spaced, "{{visible}}").?, findTemplateOpenOutsideLiteralTags(spaced, 0).?);
    const a = std.testing.allocator;
    const comments = "<pre / ><!--literal--></pre><!--outside--><nowiki / ><!--literal--></nowiki>";
    const stripped = try stripDecodedComments(a, comments);
    defer a.free(stripped);
    try std.testing.expectEqualStrings("<pre / ><!--literal--></pre><nowiki / ><!--literal--></nowiki>", stripped);
    const expanded = try stripExpandedComments(a, comments);
    defer a.free(expanded);
    try std.testing.expectEqualStrings(stripped, expanded);
}

test "parameter splitting retains one extension scan across absolute delimiter positions" {
    const a = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a, "head|<math>a|b</math>|");
    for (0..1024) |_| try input.appendSlice(a, "<math>x|");
    try input.appendSlice(a, "tail");
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(a);
    try splitWikitextTop(a, input.items, '|', &pieces);
    try std.testing.expectEqual(@as(usize, 1027), pieces.items.len);
    try std.testing.expectEqualStrings("head", pieces.items[0]);
    try std.testing.expectEqualStrings("<math>a|b</math>", pieces.items[1]);
    for (pieces.items[2..1026]) |piece| try std.testing.expectEqualStrings("<math>x", piece);
    try std.testing.expectEqualStrings("tail", pieces.items[1026]);
}

test "parsing node elision protects only synthesized literal template pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: dependency.Builder = .{};
    const source = "{<noinclude/>{uc:cat}} [[cat|label]] {| table |}";
    try appendParsingTextTracked(a, &out, source, hasParsingBoundary(source));
    const raw = try out.finish(a);
    try std.testing.expectEqualStrings("{{uc:cat}} [[cat|label]] {| table |}", raw.bytes);
    const published = try dependency.escapeLiteralCurly(a, raw);
    try std.testing.expectEqualStrings("&#123;&#123;uc:cat&#125;&#125; [[cat|label]] {| table |}", published.bytes);
    for ([_][]const u8{ "A<noinclude/>B }} {{broken", "{<noinclude/>| table |}", "<nowiki>{<noinclude/>{uc:cat}}</nowiki>" }) |control| {
        var plain: dependency.Builder = .{};
        try appendParsingTextTracked(a, &plain, control, hasParsingBoundary(control));
        const value = try plain.finish(a);
        try std.testing.expectEqual(@as(usize, 0), value.literal_curly_ranges.len);
    }
    var generated_left: dependency.Builder = .{};
    try generated_left.append(a, dependency.Text.untracked("{"));
    try appendParsingTextTracked(a, &generated_left, "<noinclude/>{uc:cat}}", true);
    const unproven = try generated_left.finish(a);
    try std.testing.expectEqualStrings("{{uc:cat}}", unproven.bytes);
    try std.testing.expectEqual(@as(usize, 0), unproven.literal_curly_ranges.len);
}

test "parsing inclusion boundaries preserve plain API and selected literal segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "<noinclude/>", "<NoInclude/>", "<noinclude />", "<noinclude attr=x/>" }) |boundary| {
        try std.testing.expectEqual(@as(?usize, boundary.len), parsingBoundaryEnd(boundary, 0));
        const source = try std.fmt.allocPrint(a, "<ref>A{s}B</ref>", .{boundary});
        var plain: std.ArrayList(u8) = .empty;
        try appendParsingText(a, &plain, source);
        try std.testing.expectEqualStrings("<ref>AB</ref>", plain.items);
        var tracked: dependency.Builder = .{};
        try appendParsingTextTracked(a, &tracked, source, hasParsingBoundary(source));
        try std.testing.expectEqualStrings("<ref>AB</ref>", (try tracked.finish(a)).bytes);
    }
    for ([_][]const u8{ "ref", "references" }) |tag| {
        const source = try std.fmt.allocPrint(a, "<{s}>A<noinclude/>B</{s}>", .{ tag, tag });
        const expected = try std.fmt.allocPrint(a, "<{s}>AB</{s}>", .{ tag, tag });
        try std.testing.expect(hasParsingBoundary(source));
        var plain: std.ArrayList(u8) = .empty;
        try appendParsingText(a, &plain, source);
        try std.testing.expectEqualStrings(expected, plain.items);
        const braces = try std.fmt.allocPrint(a, "<{s}>{{<noinclude/>{{uc:cat}}}}</{s}>", .{ tag, tag });
        var tracked: dependency.Builder = .{};
        try appendParsingTextTracked(a, &tracked, braces, hasParsingBoundary(braces));
        const published = try dependency.escapeLiteralCurly(a, try tracked.finish(a));
        const escaped = try std.fmt.allocPrint(a, "<{s}>&#123;&#123;uc:cat&#125;&#125;</{s}>", .{ tag, tag });
        try std.testing.expectEqualStrings(escaped, published.bytes);
    }
    for ([_][]const u8{ "nowiki", "pre", "math", "source" }) |tag| {
        const source = try std.fmt.allocPrint(a, "<{s}>{{<noinclude/>{{uc:cat}}}}</{s}>", .{ tag, tag });
        try std.testing.expect(!hasParsingBoundary(source));
        var plain: std.ArrayList(u8) = .empty;
        try appendParsingText(a, &plain, source);
        try std.testing.expectEqualStrings(source, plain.items);
        var tracked: dependency.Builder = .{};
        try appendParsingTextTracked(a, &tracked, source, hasParsingBoundary(source));
        const value = try tracked.finish(a);
        try std.testing.expectEqualStrings(source, value.bytes);
        try std.testing.expectEqual(@as(usize, 0), value.literal_curly_ranges.len);
    }
    const paired = "{{{missing|{<noinclude>x</noinclude>{uc:cat}}}}}";
    try std.testing.expectEqualStrings("{{{missing|{{uc:cat}}}}}", try transcludeDecodedAlloc(a, paired));
    try std.testing.expectEqualStrings("{{{missing|{<noinclude/>{uc:cat}}}}}", try transcludeDecodedForParsingAlloc(a, paired));
    const selected = try transcludeDecodedForParsingAlloc(a, "<onlyinclude>{</onlyinclude><onlyinclude>{uc:cat}}</onlyinclude>");
    var out: dependency.Builder = .{};
    try appendParsingTextTracked(a, &out, selected, hasParsingBoundary(selected));
    try std.testing.expectEqualStrings("&#123;&#123;uc:cat&#125;&#125;", (try dependency.escapeLiteralCurly(a, try out.finish(a))).bytes);
    try std.testing.expectEqualStrings("# first\n# second", try stripDecodedCommentsForParsingPreservingPoem(a, "# first\n<!--x-->\n# second"));
    try std.testing.expectEqual(@as(usize, 2), try parameterLiteralCloseCount(a, "missing|{<noinclude/>{uc:cat", false));
    try std.testing.expectEqual(@as(usize, 2), try parameterLiteralCloseCount(a, "missing|{<noinclude/>{uc:cat{{#expr:1/0}}", false));
    try std.testing.expectEqual(@as(usize, 0), try parameterLiteralCloseCount(a, "missing|A<noinclude/>B {{broken", false));
}


test "comment only heading provenance retains original delimiters without visible labels" {
    const a = std.testing.allocator;
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "===<!--Adverb-->===", .expected = "===<span></span>===" },
        .{ .raw = "===<!--Unknown-->===\nnext", .expected = "===<span></span>===\nnext" },
        .{ .raw = "===<!--title-->=== <!--tail-->", .expected = "===<span></span>=== <noinclude/>" },
        .{ .raw = "===<!--title-->===<!--tail--><!--second-->\nnext", .expected = "===<span></span>===<noinclude/><noinclude/>\nnext" },
        .{ .raw = "===<!--title-->=== <!--tail--> visible", .expected = "===<noinclude/>=== <noinclude/> visible" },
        .{ .raw = "===<!--title-->=== <!--unclosed", .expected = "===<noinclude/>=== " },
        .{ .raw = "=== <!--one--> <!--two--> ===\r\nnext", .expected = "=== <span></span> <noinclude/> ===\r\nnext" },
        .{ .raw = "======", .expected = "======" },
        .{ .raw = "{{#if:1|\n===<!--nested-->===\n|no}}", .expected = "{{#if:1|\n===<noinclude/>===\n|no}}" },
        .{ .raw = "===Word<!--one-->===", .expected = "===Word<noinclude/>===" },
        .{ .raw = " ===<!--one-->===", .expected = " ===<noinclude/>===" },
        .{ .raw = "===<!--one-->==", .expected = "===<noinclude/>==" },
        .{ .raw = "===<!--one-->===tail", .expected = "===<noinclude/>===tail" },
        .{ .raw = "===<!--one\ntwo-->===", .expected = "===<noinclude/>===" },
        .{ .raw = "<nowiki>===<!--one-->===</nowiki>", .expected = "<nowiki>===<!--one-->===</nowiki>" },
        .{ .raw = "<pre>===<!--one-->===</pre>", .expected = "<pre>===<!--one-->===</pre>" },
        .{ .raw = "before\n<!--only-->\nafter", .expected = "before\nafter" },
    };
    for (cases) |case| {
        const actual = try stripDecodedCommentsForParsingPreservingPoem(a, case.raw);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
    // Non-parsing comment APIs and post-expansion sanitizer remain unchanged.
    const plain = try stripDecodedComments(a, "===<!--one-->==="); defer a.free(plain);
    const generated = try stripExpandedComments(a, "===<!--one-->==="); defer a.free(generated);
    try std.testing.expectEqualStrings("======", plain);
    try std.testing.expectEqualStrings("======", generated);
}

test "Cite expansion scan separates raw opener attributes from active body" {
    for ([_][]const u8{
        "<ref name=n<{{Attr}}>{{Body}}</ref>{{After}}",
        "<REF name='{{Attr}}'>{{Body}}</REF>{{After}}",
        "<ref name='{{Attr}}'/>{{Body}}",
        "<ref name='{{Attr}}'>{{Body}}",
        "<references group='{{Attr}}'><ref name=n>{{Body}}</ref></references>{{After}}",
    }) |source| {
        for ([_]bool{ false, true }) |include_poem| {
            var scan: ExpansionScan = .{};
            const first = scan.next(source, 0, include_poem).?.construct;
            try std.testing.expectEqual(std.mem.indexOf(u8, source, "{{Body}}").?, first.open);
            const later = scan.next(source, first.close + 2, include_poem);
            if (std.mem.indexOf(u8, source, "{{After}}")) |at|
                try std.testing.expectEqual(at, later.?.construct.open)
            else
                try std.testing.expect(later == null);
        }
    }
    const quoted_gt = "<ref name='a>{{Body}}'>note</ref>";
    try std.testing.expectEqual(std.mem.indexOf(u8, quoted_gt, "{{Body}}").?, findTemplateOpenOutsideLiteralTags(quoted_gt, 0).?);
    const outer = "{{Outer|<ref name='{{Attr}}'>{{Body}}</ref>|tail}}";
    const construct = findBraceConstruct(outer, 0).?;
    try std.testing.expectEqual(@as(usize, 0), construct.open);
    try std.testing.expectEqual(outer.len - 2, construct.close);
    // Ordinary HTML keeps its established transclusion behavior; protected
    // extension bodies remain inactive. No generalized attribute suppression.
    const html = "<span title='{{Attr}}'>{{Body}}</span>";
    try std.testing.expectEqual(std.mem.indexOf(u8, html, "{{Attr}}").?, findTemplateOpenOutsideLiteralTags(html, 0).?);
    try std.testing.expect(findTemplateOpenOutsideLiteralTags("<nowiki><ref>{{Body}}</ref></nowiki>", 0) == null);
    try std.testing.expect(findTemplateOpenOutsideLiteralTags("<math><ref>{{Body}}</ref></math>", 0) == null);
}

test "root singleton literal proof refuses changed append bytes ambiguous boundaries and active constructs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "{{Known|value}}",
        "{{Known|before\n{{Known|nested}}\nafter}}",
        "{{t|ja|one}\n{{t|ja|two}\n",
        "{{{parameter|fallback}}}",
        "[[target|{{t|ja|word}\ncaption]]",
        "[https://example.test\n{{t|ja|word}\ncaption]",
        "<span title=\"value\n{{t|ja|word}\n\">body</span>",
        "<nowiki>{{t|ja|word}\n</nowiki>",
        "<pre>{{t|ja|word}\n</pre>",
        "<!--{{t|ja|word}\n-->",
        "{{t|ja|word|label=[https://example.test value]}\n",
    };
    for (cases) |source| {
        var out: dependency.Builder = .{}; defer out.deinit(a);
        try out.append(a, dependency.Text.untracked(source));
        try markRootSingletonLiteralCurly(a, &out, source, 0, source.len, 0);
        try std.testing.expectEqual(@as(usize, 0), out.literal_curly_ranges.items.len);
        try std.testing.expectEqualStrings(source, out.bytes.items);
    }
    var changed: dependency.Builder = .{}; defer changed.deinit(a);
    try changed.append(a, dependency.Text.untracked("generated {{t|ja|word}\n"));
    try markRootSingletonLiteralCurly(a, &changed, "{{t|ja|word}\n", 0, "{{t|ja|word}\n".len, 0);
    try std.testing.expectEqual(@as(usize, 0), changed.literal_curly_ranges.items.len);
}

test "retained complete HU te and motor raw source scans mark only their actual unmatched three brace bytes" {
    const F = struct {
        fn hash(bytes: []const u8, expected: []const u8) !void {
            var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }
    };
    const cases = [_]struct { raw: []const u8, hash: []const u8, literal: []const u8, escaped: []const u8 }{
        .{ .raw = @embedFile("testdata/hu-root-literal/te.raw.wikitext"), .hash = "6026dc73d5895cba9163311b4b4852600fe57ca1c6fe878b52b518bd2b8abcdd", .literal = "{{t|ja|貴方|tr=[[あなた]], anata}", .escaped = "&#123;&#123;t|ja|貴方|tr=[[あなた]], anata&#125;" },
        .{ .raw = @embedFile("testdata/hu-root-literal/motor.raw.wikitext"), .hash = "f19ab91587ce179ee661746fb07541c1bc3422c98f0f07a3a3442ab32d053663", .literal = "{{t|mi|iniana}", .escaped = "&#123;&#123;t|mi|iniana&#125;" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for (cases) |case| {
        try F.hash(case.raw, case.hash);
        var out: dependency.Builder = .{}; defer out.deinit(a);
        var scan: ExpansionScan = .{}; var position: usize = 0;
        while (scan.next(case.raw, position, true)) |node| {
            const construct = switch (node) { .construct => |value| value, .poem => return error.TestUnexpectedResult };
            const start = out.bytes.items.len;
            try out.append(a, dependency.Text.untracked(case.raw[position..construct.open]));
            try markRootSingletonLiteralCurly(a, &out, case.raw, position, construct.open, start);
            position = construct.close + (if (construct.kind == .parameter) @as(usize, 3) else 2);
            // Retain active source nodes byte-for-byte in this source-only
            // oracle; the separate normal Expander tests execute child nodes.
            try out.append(a, dependency.Text.untracked(case.raw[construct.open..position]));
        }
        const tail = out.bytes.items.len;
        try out.append(a, dependency.Text.untracked(case.raw[position..]));
        try markRootSingletonLiteralCurly(a, &out, case.raw, position, case.raw.len, tail);
        try std.testing.expectEqualStrings(case.raw, out.bytes.items);
        try std.testing.expectEqual(@as(usize, 2), out.literal_curly_ranges.items.len);
        const opening = std.mem.indexOf(u8, case.raw, case.literal) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, @intCast(opening)), out.literal_curly_ranges.items[0].start);
        try std.testing.expectEqual(@as(u32, @intCast(opening + 2)), out.literal_curly_ranges.items[0].end);
        try std.testing.expectEqual(@as(u32, @intCast(opening + case.literal.len - 1)), out.literal_curly_ranges.items[1].start);
        try std.testing.expectEqual(@as(u32, @intCast(opening + case.literal.len)), out.literal_curly_ranges.items[1].end);
        const marked = try out.finish(a);
        const actual = try dependency.escapeLiteralCurly(a, marked);
        const expected = try std.mem.replaceOwned(u8, a, case.raw, case.literal, case.escaped);
        try std.testing.expectEqualStrings(expected, actual.bytes);
    }
}

test "expanded comment copies preserve a later missing sibling without cleaning unknown provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The comment delimiters mirror retained Script utilities tag_translit;
    // this is a controlled intermediate, not a recaptured expansion result.
    const input = "<span lang=\"hi-Latn\" class=\"tr Latn\" dir=\"ltr\">-{<!---->dekhnā<!---->}-</span>\n* [[:Template:R:hi:Rajpal]]";
    const expected = "<span lang=\"hi-Latn\" class=\"tr Latn\" dir=\"ltr\">-{dekhnā}-</span>\n* [[:Template:R:hi:Rajpal]]";
    const start = std.mem.indexOf(u8, input, "[[:Template:").?;
    const out_start = std.mem.indexOf(u8, expected, "[[:Template:").?;
    for ([_]bool{ false, true }) |unknown| {
        const output = try stripExpandedCommentsTracked(a, .{
            .bytes = input,
            .ranges = &.{.{ .start = @intCast(start), .end = @intCast(input.len), .occurrence = 1 }},
            .unknown = unknown,
        });
        try std.testing.expectEqualStrings(expected, output.bytes);
        try std.testing.expectEqual(unknown, output.unknown);
        try std.testing.expect(!output.lost_missing_range);
        try std.testing.expectEqual(@as(usize, 1), output.ranges.len);
        try std.testing.expectEqual(@as(u32, @intCast(out_start)), output.ranges[0].start);
        try std.testing.expectEqual(@as(u32, @intCast(expected.len)), output.ranges[0].end);
        try std.testing.expectEqual(@as(u32, 1), output.ranges[0].occurrence);
    }
}

test "expanded comment tracking preserves sanitizer edits and refuses edited missing ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "A<!<!--inner-->--outer-->B", "AB" },
        .{ "A\n <!--x--> \nB", "A\nB" },
        .{ "A<!--unclosed body", "A&lt;!--unclosed body" },
        .{ "<no<!--x-->wiki>body</nowiki>", "&lt;nowiki>body</nowiki>" },
        .{ "<sour<!--x-->ce>body</source>", "&lt;source>body</source>" },
        .{ "<nowiki><!--literal--></nowiki>", "<nowiki><!--literal--></nowiki>" },
        .{ "<pre><!--literal--></pre>", "<pre><!--literal--></pre>" },
    };
    for (cases) |case| {
        const input = try std.fmt.allocPrint(a, "{s}|MISSING", .{case[0]});
        const expected = try std.fmt.allocPrint(a, "{s}|MISSING", .{case[1]});
        const start = input.len - "MISSING".len;
        const output = try stripExpandedCommentsTracked(a, .{
            .bytes = input,
            .ranges = &.{.{ .start = @intCast(start), .end = @intCast(input.len), .occurrence = 1 }},
        });
        try std.testing.expectEqualStrings(expected, output.bytes);
        try std.testing.expect(!output.unknown and !output.lost_missing_range);
        try std.testing.expectEqual(@as(usize, 1), output.ranges.len);
        try std.testing.expectEqualStrings("MISSING", output.bytes[output.ranges[0].start..output.ranges[0].end]);
        try std.testing.expectEqual(@as(u32, @intCast(expected.len - "MISSING".len)), output.ranges[0].start);
    }
    for ([_][]const u8{ "A<!--x-->B", "<!--MISSING-->", "<no<!--x-->wiki>" }) |input| {
        const output = try stripExpandedCommentsTracked(a, .{
            .bytes = input,
            .ranges = &.{.{ .start = 0, .end = @intCast(input.len), .occurrence = 1 }},
        });
        try std.testing.expectEqualStrings(try stripExpandedComments(a, input), output.bytes);
        try std.testing.expect(output.unknown and output.lost_missing_range);
        try std.testing.expectEqual(@as(usize, 0), output.ranges.len);
    }
    const retained = try stripExpandedCommentsTracked(a, .{ .bytes = "A<!--x-->B", .unknown = true, .lost_missing_range = true });
    try std.testing.expect(retained.unknown and retained.lost_missing_range);
    var limited: CommentCopies = .{ .limited = true };
    try limited.copy(a, 0, 0, 1);
    var cursor: usize = 0;
    try std.testing.expect(limited.mapped(0, 1, &cursor) == null);
}

test "expanded comment escape mapping leaves prior spans unchanged across repeated reconstructed tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var copies: CommentCopies = .{};
    for (0..128) |i| try copies.copy(a, i * 4, i * 4, 3);
    const prior = try a.dupe(CommentCopies.Span, copies.spans.items[0..127]);
    try copies.escapeLt(a, 127 * 4 + 1);
    for (prior, copies.spans.items[0..127]) |before, after| {
        try std.testing.expectEqual(before.source, after.source);
        try std.testing.expectEqual(before.output, after.output);
        try std.testing.expectEqual(before.len, after.len);
    }
    try std.testing.expectEqual(@as(usize, 129), copies.spans.items.len);
    try std.testing.expectEqual(@as(usize, 1), copies.spans.items[127].len);
    try std.testing.expectEqual(@as(usize, 127 * 4 + 2), copies.spans.items[128].source);
    try std.testing.expectEqual(@as(usize, 127 * 4 + 5), copies.spans.items[128].output);
    try std.testing.expectEqual(@as(usize, 1), copies.spans.items[128].len);
    var input: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList(u8) = .empty;
    for (0..256) |_| {
        try input.appendSlice(a, "<no<!--x-->wiki>body</nowiki>");
        try expected.appendSlice(a, "&lt;nowiki>body</nowiki>");
    }
    const start = input.items.len;
    try input.appendSlice(a, "MISSING");
    const mapped_start = expected.items.len;
    try expected.appendSlice(a, "MISSING");
    const output = try stripExpandedCommentsTracked(a, .{
        .bytes = input.items,
        .ranges = &.{.{ .start = @intCast(start), .end = @intCast(input.items.len), .occurrence = 1 }},
    });
    try std.testing.expectEqualStrings(expected.items, output.bytes);
    try std.testing.expect(!output.unknown and !output.lost_missing_range);
    try std.testing.expectEqual(@as(usize, 1), output.ranges.len);
    try std.testing.expectEqual(@as(u32, @intCast(mapped_start)), output.ranges[0].start);
    try std.testing.expectEqual(@as(u32, @intCast(expected.items.len)), output.ranges[0].end);
}

test "conversion frames shield argument pipes only under captured global enablement" {
    const a = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const []const u8 }{
        .{ .input = "yes|-{T|ku-latn:{{PAGENAME}};ku-arab:{{{1|}}}}-|no", .expected = &.{ "yes", "-{T|ku-latn:{{PAGENAME}};ku-arab:{{{1|}}}}-", "no" } },
        .{ .input = "a|-{x|-{y|z}-|q}-|b", .expected = &.{ "a", "-{x|-{y|z}-|q}-", "b" } },
        .{ .input = "-{{{x}}|hidden}-|outer", .expected = &.{ "-{{{x}}|hidden}-", "outer" } },
        .{ .input = "[[a|-{x]]y}-]]|z", .expected = &.{ "[[a|-{x]]y}-]]", "z" } },
        .{ .input = "a|-{[[x}}]]}-|b", .expected = &.{ "a", "-{[[x}}]]}-", "b" } },
        .{ .input = "a|-{[[{{x]]|y}}z]]}-|b", .expected = &.{ "a", "-{[[{{x]]|y}}z]]}-", "b" } },
        .{ .input = "a|-{{x|y}}|b", .expected = &.{ "a", "-{{x|y}}", "b" } },
        .{ .input = "a|<nowiki>-{x|y}-</nowiki>|b", .expected = &.{ "a", "<nowiki>-{x|y}-</nowiki>", "b" } },
        .{ .input = "a|-{x|[[p|q]]{{t|v}}}-|b", .expected = &.{ "a", "-{x|[[p|q]]{{t|v}}}-", "b" } },
        .{ .input = "a|-{x|'quoted|text'}-|b", .expected = &.{ "a", "-{x|'quoted|text'}-", "b" } },
    };
    for (cases) |case| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(a);
        try splitWikitextTopWithConversion(a, case.input, '|', &parts, true);
        try std.testing.expectEqual(case.expected.len, parts.items.len);
        for (case.expected, parts.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }
    for ([_]bool{ false, true }) |enabled| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(a);
        try splitWikitextTopWithConversion(a, "a|-{T|x}-|b", '|', &parts, enabled);
        try std.testing.expectEqual(@as(usize, if (enabled) 3 else 4), parts.items.len);
    }
    try std.testing.expectEqual(@as(?usize, null), findTopDelimiterWithConversion("-{x=y}-", '=', true));
    try std.testing.expectEqual(@as(?usize, 3), findTopDelimiterWithConversion("-{x=y}-", '=', false));
    try std.testing.expect(findTopParserColonWithConversion("-{x:y}-", true) == null);
    try std.testing.expectEqualStrings("-{x|y}-", splitParameterWithConversion("-{x|y}-|default", true).key);
    try std.testing.expectEqualStrings("default", splitParameterWithConversion("-{x|y}-|default", true).default.?);
}

test "conversion aware construct boundaries retain internal closing brace text" {
    const source = "{{T|-{a}}b}-|c}}";
    var scan: ExpansionScan = .{ .conversion_enabled = true };
    const construct = scan.next(source, 0, false).?.construct;
    try std.testing.expectEqual(@as(usize, 0), construct.open);
    try std.testing.expectEqual(source.len - 2, construct.close);
    var incomplete: ExpansionScan = .{ .conversion_enabled = true };
    try std.testing.expect(incomplete.next("{{T|-{a|b}}", 0, false) == null);
    var incomplete_parts: std.ArrayList([]const u8) = .empty;
    defer incomplete_parts.deinit(std.testing.allocator);
    try splitWikitextTopWithConversion(std.testing.allocator, "a|-{x|y", '|', &incomplete_parts, true);
    try std.testing.expectEqual(@as(usize, 2), incomplete_parts.items.len);
    try std.testing.expectEqualStrings("-{x|y", incomplete_parts.items[1]);
    const nested_source = "{{T|-{[[x}}]]}-|y}}";
    var nested: ExpansionScan = .{ .conversion_enabled = true };
    try std.testing.expectEqual(nested_source.len - 2, nested.next(nested_source, 0, false).?.construct.close);
    var disabled: ExpansionScan = .{};
    try std.testing.expectEqual(@as(usize, 7), disabled.next(source, 0, false).?.construct.close);
}
