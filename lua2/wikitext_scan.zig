const std = @import("std");

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn between(hay: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const a = std.mem.indexOf(u8, hay, open) orelse return null;
    const s = a + open.len;
    const b = std.mem.indexOfPos(u8, hay, s, close) orelse return null;
    return hay[s..b];
}

fn pageText(page: []const u8) ?[]const u8 {
    const a = std.mem.indexOf(u8, page, "<text") orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, page, a, '>') orelse return null;
    const s = gt + 1;
    const e = std.mem.indexOfPos(u8, page, s, "</text>") orelse return null;
    return page[s..e];
}

fn findCiPos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return @min(start, hay.len);
    if (start >= hay.len or needle.len > hay.len) return null;
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn stripEncodedComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    while (findCiPos(text, pos, "&lt;!--")) |open| {
        try out.appendSlice(a, text[pos..open]);
        const close = findCiPos(text, open + 8, "--&gt;") orelse {
            pos = text.len;
            break;
        };
        pos = close + 6;
    }
    try out.appendSlice(a, text[pos..]);
    return out.toOwnedSlice(a);
}

fn tagEnd(text: []const u8, start: usize) ?usize {
    const p = std.mem.indexOfPos(u8, text, start, "&gt;") orelse return null;
    return p + 4;
}

fn isEncodedSelfClosing(text: []const u8, start: usize, end: usize) bool {
    if (end <= start + 4) return false;
    var i = end - 5;
    while (i > start and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) : (i -= 1) {}
    return text[i] == '/';
}

fn appendTranscludedRange(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, begin: usize, end: usize) !void {
    var pos = begin;
    while (pos < end) {
        const lt = std.mem.indexOfPos(u8, text, pos, "&lt;") orelse {
            try out.appendSlice(a, text[pos..end]);
            break;
        };
        if (lt >= end) {
            try out.appendSlice(a, text[pos..end]);
            break;
        }
        try out.appendSlice(a, text[pos..lt]);
        if (findCiPos(text, lt, "&lt;noinclude") == lt) {
            const open_end = tagEnd(text, lt) orelse return;
            if (open_end > end) return;
            if (isEncodedSelfClosing(text, lt, open_end)) {
                pos = open_end;
                continue;
            }
            const close = findCiPos(text, open_end, "&lt;/noinclude") orelse return;
            const close_end = tagEnd(text, close) orelse return;
            pos = @min(close_end, end);
            continue;
        }
        if (findCiPos(text, lt, "&lt;/noinclude") == lt or
            findCiPos(text, lt, "&lt;includeonly") == lt or
            findCiPos(text, lt, "&lt;/includeonly") == lt or
            findCiPos(text, lt, "&lt;onlyinclude") == lt or
            findCiPos(text, lt, "&lt;/onlyinclude") == lt)
        {
            const e = tagEnd(text, lt) orelse return;
            pos = @min(e, end);
            continue;
        }
        try out.appendSlice(a, text[lt..@min(lt + 4, end)]);
        pos = @min(lt + 4, end);
    }
}

fn transcludeTemplateAlloc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const no_comments = try stripEncodedComments(a, text);
    defer a.free(no_comments);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (findCiPos(no_comments, 0, "&lt;onlyinclude")) |_| {
        var pos: usize = 0;
        while (findCiPos(no_comments, pos, "&lt;onlyinclude")) |open| {
            const open_end = tagEnd(no_comments, open) orelse break;
            const close = findCiPos(no_comments, open_end, "&lt;/onlyinclude") orelse break;
            try appendTranscludedRange(a, &out, no_comments, open_end, close);
            pos = tagEnd(no_comments, close) orelse no_comments.len;
        }
    } else {
        try appendTranscludedRange(a, &out, no_comments, 0, no_comments.len);
    }
    return out.toOwnedSlice(a);
}

const Kind = enum { template, param };
const Frame = struct { kind: Kind, start: usize };

const Scanner = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    template_calls: u64 = 0,
    invokes: u64 = 0,
    replay_roots: bool = false,
    replay_calls: u64 = 0,

    fn scanText(self: *Scanner, host_kind: u8, host: []const u8, text: []const u8) !void {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);
        var i: usize = 0;
        var next_comment = findCiPos(text, 0, "&lt;!--") orelse text.len;
        while (i + 1 < text.len) {
            const next_open = std.mem.indexOfPos(u8, text, i, "{{") orelse text.len;
            const next_close = std.mem.indexOfPos(u8, text, i, "}}") orelse text.len;
            const p = @min(@min(next_open, next_close), next_comment);
            if (p == text.len) break;
            i = p;
            if (next_comment <= next_open and next_comment <= next_close) {
                const comment_end = findCiPos(text, i + 8, "--&gt;") orelse break;
                i = comment_end + 6;
                next_comment = findCiPos(text, i, "&lt;!--") orelse text.len;
                continue;
            }
            if (next_open <= next_close) {
                if (i + 2 < text.len and text[i + 2] == '{') {
                    try stack.append(self.allocator, .{ .kind = .param, .start = i });
                    i += 3;
                } else {
                    try stack.append(self.allocator, .{ .kind = .template, .start = i });
                    i += 2;
                }
                continue;
            }
            if (stack.items.len == 0) {
                i += 2;
                continue;
            }
            const top = stack.items[stack.items.len - 1];
            if (top.kind == .param and i + 2 < text.len and text[i + 2] == '}') {
                _ = stack.pop();
                i += 3;
                continue;
            }
            if (top.kind == .template) {
                _ = stack.pop();
                if (self.replay_roots and host_kind == 0) {
                    if (stack.items.len == 0) {
                        try self.writer.writeAll("W\t");
                        try writeField(self.writer, host);
                        try self.writer.writeByte('\t');
                        try writeField(self.writer, text[top.start .. i + 2]);
                        try self.writer.writeByte('\n');
                        self.replay_calls += 1;
                    }
                } else try self.parseTemplate(host_kind, host, text[top.start + 2 .. i]);
                i += 2;
                continue;
            }
            i += 2;
        }
    }

    fn parseTemplate(self: *Scanner, host_kind: u8, host: []const u8, content: []const u8) !void {
        var cleaned: ?[]u8 = null;
        defer if (cleaned) |buf| self.allocator.free(buf);
        const actual = if (findCiPos(content, 0, "&lt;!--") != null) blk: {
            cleaned = try stripEncodedComments(self.allocator, content);
            break :blk cleaned.?;
        } else content;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try splitTop(self.allocator, actual, &parts);
        if (parts.items.len == 0) return;
        const head = trim(parts.items[0]);
        if (head.len == 0) return;

        if (startsIgnoreCase(head, "#invoke:")) {
            const module_expr = trim(head[8..]);
            const function_expr = if (parts.items.len > 1) trim(parts.items[1]) else "";
            try self.writer.writeAll("I\t");
            try self.writer.print("{d}\t", .{host_kind});
            try writeField(self.writer, host);
            try self.writer.writeByte('\t');
            try writeField(self.writer, module_expr);
            try self.writer.writeByte('\t');
            try writeField(self.writer, function_expr);
            if (parts.items.len > 2) for (parts.items[2..]) |arg| {
                try self.writer.writeByte('\t');
                try writeField(self.writer, trim(arg));
            };
            try self.writer.writeByte('\n');
            self.invokes += 1;
            return;
        }
        if (head[0] == '#') return;

        var target = head;
        if (startsIgnoreCase(target, "subst:")) target = trim(target[6..]);
        if (startsIgnoreCase(target, "safesubst:")) target = trim(target[10..]);
        if (startsIgnoreCase(target, "Template:")) target = trim(target[9..]);
        if (target.len == 0) return;

        try self.writer.writeAll(if (host_kind == 0) "Q\t" else "E\t");
        if (host_kind == 1) {
            try writeField(self.writer, host);
            try self.writer.writeByte('\t');
        }
        try writeField(self.writer, target);
        for (parts.items[1..]) |arg| {
            try self.writer.writeByte('\t');
            try writeField(self.writer, trim(arg));
        }
        try self.writer.writeByte('\n');
        self.template_calls += 1;
    }
};

fn splitTop(a: std.mem.Allocator, s: []const u8, out: *std.ArrayList([]const u8)) !void {
    var curly: i32 = 0;
    var square: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            curly += 3;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            curly += 2;
            i += 2;
            continue;
        }
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}") and curly >= 3) {
            curly -= 3;
            i += 3;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}") and curly >= 2) {
            curly -= 2;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "[[")) {
            square += 2;
            i += 2;
            continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "]]") and square >= 2) {
            square -= 2;
            i += 2;
            continue;
        }
        if (s[i] == '|' and curly == 0 and square == 0) {
            try out.append(a, s[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    try out.append(a, s[start..]);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn startsIgnoreCase(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p);
}

fn redirectTarget(text: []const u8, namespace_prefix: []const u8) ?[]const u8 {
    const body = trim(text);
    if (!startsIgnoreCase(body, "#redirect")) return null;
    const open = std.mem.indexOf(u8, body, "[[") orelse return null;
    const close = std.mem.indexOfPos(u8, body, open + 2, "]]") orelse return null;
    var target = trim(body[open + 2 .. close]);
    if (startsIgnoreCase(target, namespace_prefix)) target = trim(target[namespace_prefix.len..]);
    if (target.len == 0) return null;
    return target;
}

fn writeField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingInput;
    const replay_roots = args.len >= 3 and std.mem.eql(u8, args[2], "--replay-roots");
    var mapped = try mmapPath(args[1]);
    defer mapped.deinit();
    var out_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    var scanner = Scanner{ .allocator = std.heap.smp_allocator, .writer = w, .replay_roots = replay_roots };

    var pos: usize = 0;
    var released: usize = 0;
    var pages: u64 = 0;
    var entries: u64 = 0;
    var templates: u64 = 0;
    while (std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>")) |ps| {
        const pe0 = std.mem.indexOfPos(u8, mapped.bytes, ps + 6, "</page>") orelse break;
        const pe = pe0 + 7;
        const page = mapped.bytes[ps..pe];
        pos = pe;
        pages += 1;
        if (pos - released >= 64 * 1024 * 1024) {
            const page_size = std.heap.page_size_min;
            const release_end = (ps / page_size) * page_size;
            if (release_end > released) {
                const base: [*]u8 = @ptrCast(@constCast(mapped.bytes.ptr));
                const release_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(base + released);
                std.posix.madvise(release_ptr, release_end - released, std.posix.MADV.DONTNEED) catch {};
                released = release_end;
            }
        }
        const ns = between(page, "<ns>", "</ns>") orelse continue;
        const kind: u8 = if (std.mem.eql(u8, ns, "0")) 0 else if (std.mem.eql(u8, ns, "10")) 1 else if (std.mem.eql(u8, ns, "828")) 2 else continue;
        if (replay_roots and kind != 0) continue;
        const title_raw = between(page, "<title>", "</title>") orelse continue;
        const host = if (kind == 1 and std.mem.startsWith(u8, title_raw, "Template:")) title_raw[9..] else if (kind == 2 and std.mem.startsWith(u8, title_raw, "Module:")) title_raw[7..] else title_raw;
        const text = pageText(page) orelse continue;
        if (kind == 2) {
            if (redirectTarget(text, "Module:")) |target| {
                try w.writeAll("M\t");
                try writeField(w, host);
                try w.writeByte('\t');
                try writeField(w, target);
                try w.writeByte('\n');
            }
            continue;
        }
        if (kind == 0) entries += 1 else {
            templates += 1;
            try w.writeAll("T\t");
            try writeField(w, host);
            try w.writeByte('\n');
            if (redirectTarget(text, "Template:")) |target| {
                try w.writeAll("X\t");
                try writeField(w, host);
                try w.writeByte('\t');
                try writeField(w, target);
                try w.writeByte('\n');
            }
        }
        if (kind == 1) {
            const transcluded = try transcludeTemplateAlloc(scanner.allocator, text);
            defer scanner.allocator.free(transcluded);
            try scanner.scanText(kind, host, transcluded);
        } else {
            try scanner.scanText(kind, host, text);
        }
        if (pages % 100000 == 0) {
            try w.flush();
            std.debug.print("pages={d} entries={d} templates={d} calls={d} invokes={d} replay={d} offset={d}\n", .{ pages, entries, templates, scanner.template_calls, scanner.invokes, scanner.replay_calls, pos });
        }
    }
    try w.flush();
    std.debug.print("TOTAL pages={d} entries={d} templates={d} calls={d} invokes={d} replay={d}\n", .{ pages, entries, templates, scanner.template_calls, scanner.invokes, scanner.replay_calls });
}
