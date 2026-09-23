const std = @import("std");

const ParsedHeading = struct {
    level: u8,
    title: []const u8,
};

pub const Section = struct {
    heading: []const u8,
    source: []const u8,
};

pub const Iterator = struct {
    source: []const u8,
    cursor: usize = 0,
    active_start: ?usize = null,
    active_heading: []const u8 = "",
    balance: Balance = .{},
    done: bool = false,

    pub fn init(source: []const u8) Iterator {
        return .{ .source = source };
    }

    pub fn next(self: *Iterator) ?Section {
        if (self.done) return null;
        while (self.cursor < self.source.len) {
            const line_start = self.cursor;
            const newline = std.mem.indexOfScalarPos(u8, self.source, line_start, '\n') orelse self.source.len;
            var content_end = newline;
            if (content_end != line_start and self.source[content_end - 1] == '\r') content_end -= 1;
            const line = self.source[line_start..content_end];
            self.cursor = if (newline == self.source.len) self.source.len else newline + 1;

            if (!self.balance.isOpen()) {
                if (parseHeading(line)) |heading| {
                    if (heading.level == 2) {
                        if (self.active_start) |start| {
                            const result: Section = .{
                                .heading = self.active_heading,
                                .source = self.source[start..line_start],
                            };
                            self.active_start = line_start;
                            self.active_heading = heading.title;
                            return result;
                        }
                        self.active_start = line_start;
                        self.active_heading = heading.title;
                        continue;
                    }
                }
            }
            self.balance.update(line);
        }

        self.done = true;
        if (self.active_start) |start| {
            self.active_start = null;
            return .{ .heading = self.active_heading, .source = self.source[start..] };
        }
        return null;
    }
};

const Balance = struct {
    templates: usize = 0,
    links: usize = 0,
    comments: usize = 0,
    tables: usize = 0,

    fn update(self: *Balance, line: []const u8) void {
        const content = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, content, "{|")) self.tables += 1;
        if (std.mem.startsWith(u8, content, "|}") and self.tables != 0) self.tables -= 1;
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
            }
        }
    }

    fn isOpen(self: Balance) bool {
        return self.templates != 0 or self.links != 0 or self.comments != 0 or self.tables != 0;
    }
};

fn parseHeading(line: []const u8) ?ParsedHeading {
    if (line.len < 5 or line[0] != '=') return null;
    var left: usize = 0;
    while (left < line.len and line[left] == '=') : (left += 1) {}
    if (left < 2 or left > 6) return null;
    var right = line.len;
    while (right != 0 and line[right - 1] == '=') : (right -= 1) {}
    if (line.len - right != left or right <= left) return null;
    const title = std.mem.trim(u8, line[left..right], " \t");
    if (title.len == 0) return null;
    return .{ .level = @intCast(left), .title = title };
}

test "language sections ignore preamble and nested fake headings" {
    const source = "{{also|cat}}\n==English==\n{{foo|\n==not French==\n}}\n===Noun===\n# cat\n==French==\r\n===Nom===\n# chat\n";
    var it = Iterator.init(source);
    const english = it.next().?;
    try std.testing.expectEqualStrings("English", english.heading);
    try std.testing.expect(std.mem.startsWith(u8, english.source, "==English=="));
    try std.testing.expect(std.mem.indexOf(u8, english.source, "==not French==") != null);
    const french = it.next().?;
    try std.testing.expectEqualStrings("French", french.heading);
    try std.testing.expect(std.mem.startsWith(u8, french.source, "==French=="));
    try std.testing.expect(it.next() == null);
}

test "repeated language sections remain separate" {
    const source = "==English==\n# first\n==French==\n# milieu\n==English==\n# second\n";
    var it = Iterator.init(source);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expectEqualStrings("French", it.next().?.heading);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expect(it.next() == null);
}

test "table subheadings do not become language sections" {
    const source = "{| class=wikitable\n== AC ==\n|-\n| entry\n|}\n==English==\n===Noun===\n# meaning\n";
    var it = Iterator.init(source);
    try std.testing.expectEqualStrings("English", it.next().?.heading);
    try std.testing.expect(it.next() == null);
}
