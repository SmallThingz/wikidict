//! Build-time Wiktionary XML adapter. Product encoders consume decoded wikitext records, not XML.
const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("xml_decode");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = false,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

pub const PageHeader = struct {
    ns: u32,
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    revision_timestamp: []const u8,
    revision_user: []const u8,
    source_offset: u64,
    source_len: usize,
    has_source: bool,
    redirect: ?[]const u8 = null,
};

pub fn decodeSourceAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return xml_decode.decodeSinglePassAlloc(allocator, raw);
}

const Capture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    page_id_raw: ?[]const u8 = null,
    revision_id_raw: ?[]const u8 = null,
    revision_timestamp_raw: ?[]const u8 = null,
    revision_user_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,
    redirect_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();
        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "id")) {
            self.page_id_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "redirect")) {
            self.redirect_raw = node.getAttributeValueRaw("title");
        } else if (node.depth == 2 and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            if (std.mem.eql(u8, name, "id")) self.revision_id_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "timestamp")) self.revision_timestamp_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "text")) self.text_raw = node.leadingTextRaw();
        } else if (node.depth == 3 and std.mem.eql(u8, self.names_by_depth[1], "revision") and std.mem.eql(u8, self.names_by_depth[2], "contributor") and (std.mem.eql(u8, name, "username") or std.mem.eql(u8, name, "ip"))) {
            self.revision_user_raw = node.leadingTextRaw();
        }
        return true;
    }
};

pub fn relevantNamespace(ns: u32) bool {
    return ns == 0 or ns == 106 or ns == 110 or ns == 114 or ns == 116 or ns == 118;
}

pub const Dump = struct {
    allocator: std.mem.Allocator,
    bytes: []align(std.heap.page_size_min) const u8,
    parser: StreamParser,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Dump {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(io);
        const stat = try file.stat(io);
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const bytes = if (len == 0)
            @as([]align(std.heap.page_size_min) const u8, &.{})
        else
            try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        return .{ .allocator = allocator, .bytes = bytes, .parser = StreamParser.init(allocator) };
    }

    pub fn deinit(self: *Dump) void {
        self.parser.deinit();
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.* = undefined;
    }

    pub fn headerIterator(self: *Dump) HeaderIterator {
        return .{ .dump = self };
    }
};

pub const HeaderIterator = struct {
    dump: *Dump,
    pos: usize = 0,
    pages_seen: usize = 0,

    pub fn next(self: *HeaderIterator, allocator: std.mem.Allocator) !?PageHeader {
        while (std.mem.indexOfPos(u8, self.dump.bytes, self.pos, "<page>")) |start| {
            const end_start = std.mem.indexOfPos(u8, self.dump.bytes, start, "</page>") orelse return error.TruncatedXml;
            const page_end = end_start + "</page>".len;
            const page = self.dump.bytes[start..page_end];
            self.pos = page_end;
            self.pages_seen += 1;

            var capture: Capture = .{};
            try self.dump.parser.parse(page, &capture, Capture.onNode);
            const ns_raw = capture.ns_raw orelse continue;
            const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch continue;
            const title_raw = capture.title_raw orelse continue;
            const page_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.page_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.revision_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_timestamp_raw = capture.revision_timestamp_raw orelse return error.InvalidPageMetadata;
            const text_raw = capture.text_raw orelse "";
            const source_offset: u64 = if (text_raw.len == 0) 0 else blk: {
                const base = @intFromPtr(self.dump.bytes.ptr);
                const ptr = @intFromPtr(text_raw.ptr);
                if (ptr < base) return error.InvalidXmlSlice;
                const offset = ptr - base;
                if (offset > self.dump.bytes.len or text_raw.len > self.dump.bytes.len - offset) return error.InvalidXmlSlice;
                break :blk @intCast(offset);
            };
            return .{
                .ns = ns,
                .title = try xml_decode.decodeSinglePassAlloc(allocator, title_raw),
                .page_id = page_id,
                .revision_id = revision_id,
                .revision_timestamp = try xml_decode.decodeSinglePassAlloc(allocator, revision_timestamp_raw),
                .revision_user = try xml_decode.decodeSinglePassAlloc(allocator, capture.revision_user_raw orelse ""),
                .source_offset = source_offset,
                .source_len = text_raw.len,
                .has_source = capture.text_raw != null,
                .redirect = if (capture.redirect_raw) |raw| try xml_decode.decodeSinglePassAlloc(allocator, raw) else null,
            };
        }
        return null;
    }
};

test "dump adapter exposes decoded wikitext pages" {
    const xml = "<mediawiki>" ++
        "<page><title>cat</title><ns>0</ns><id>7</id><revision><id>70</id><timestamp>2024-03-04T05:06:07Z</timestamp><contributor><username>Alice</username></contributor><text>==English==&amp;x</text></revision></page>" ++
        "<page><title>kitty</title><ns>0</ns><id>8</id><redirect title=\"cat\"/><revision><id>80</id><timestamp>2024-03-05T06:07:08Z</timestamp><contributor><ip>192.0.2.7</ip></contributor><text>#REDIRECT [[cat]]</text></revision></page>" ++
        "<page><title>missing-source</title><ns>10</ns><id>9</id><revision><id>90</id><timestamp>2024-03-06T07:08:09Z</timestamp></revision></page>" ++
        "</mediawiki>";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dump.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = xml });
    var dump = try Dump.open(std.testing.io, std.testing.allocator, path);
    defer dump.deinit();
    var headers = dump.headerIterator();
    const header = (try headers.next(std.testing.allocator)).?;
    defer std.testing.allocator.free(header.title);
    defer std.testing.allocator.free(header.revision_timestamp);
    defer std.testing.allocator.free(header.revision_user);
    try std.testing.expectEqual(@as(u32, 0), header.ns);
    try std.testing.expectEqual(@as(u64, 7), header.page_id);
    try std.testing.expectEqual(@as(u64, 70), header.revision_id);
    try std.testing.expectEqualStrings("2024-03-04T05:06:07Z", header.revision_timestamp);
    try std.testing.expectEqualStrings("Alice", header.revision_user);
    try std.testing.expectEqualStrings("cat", header.title);
    try std.testing.expect(header.has_source);
    try std.testing.expect(header.redirect == null);
    const source_start: usize = @intCast(header.source_offset);
    const raw_source = dump.bytes[source_start .. source_start + header.source_len];
    try std.testing.expectEqualStrings("==English==&amp;x", raw_source);
    const decoded_source = try decodeSourceAlloc(std.testing.allocator, raw_source);
    defer std.testing.allocator.free(decoded_source);
    try std.testing.expectEqualStrings("==English==&x", decoded_source);
    const redirect = (try headers.next(std.testing.allocator)).?;
    defer std.testing.allocator.free(redirect.title);
    defer std.testing.allocator.free(redirect.revision_timestamp);
    defer std.testing.allocator.free(redirect.revision_user);
    defer std.testing.allocator.free(redirect.redirect.?);
    try std.testing.expectEqualStrings("kitty", redirect.title);
    try std.testing.expectEqualStrings("cat", redirect.redirect.?);
    try std.testing.expectEqualStrings("192.0.2.7", redirect.revision_user);
    const missing_source = (try headers.next(std.testing.allocator)).?;
    defer std.testing.allocator.free(missing_source.title);
    defer std.testing.allocator.free(missing_source.revision_timestamp);
    defer std.testing.allocator.free(missing_source.revision_user);
    try std.testing.expectEqual(@as(u32, 10), missing_source.ns);
    try std.testing.expectEqualStrings("", missing_source.revision_user);
    try std.testing.expect(!missing_source.has_source);
    try std.testing.expectEqual(@as(usize, 0), missing_source.source_len);
}
