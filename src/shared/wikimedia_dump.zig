const std = @import("std");

const BZ_OK: c_int = 0;
const BZ_OUTBUFF_FULL: c_int = -8;
const max_member_uncompressed_bytes: usize = 128 * 1024 * 1024;

extern fn BZ2_bzopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn BZ2_bzread(file: ?*anyopaque, buf: [*]u8, len: c_int) c_int;
extern fn BZ2_bzclose(file: ?*anyopaque) void;
extern fn BZ2_bzBuffToBuffDecompress(
    dest: [*]u8,
    dest_len: *c_uint,
    source: [*]const u8,
    source_len: c_uint,
    small: c_int,
    verbosity: c_int,
) c_int;

pub const page_index_v2_header = "# dict-page-index-v2\tmultistream-bz2";
pub const stream_index_header = "# dict-dump-streams-v1";

pub fn relevantNamespace(ns: u32) bool {
    return ns == 0 or ns == 106 or ns == 110 or ns == 114 or ns == 116 or ns == 118;
}

pub const PageView = struct {
    raw: []const u8,
    title_raw: ?[]const u8,
    ns_raw: ?[]const u8,
    redirect_raw: ?[]const u8,
    page_id_raw: ?[]const u8,
    revision_id_raw: ?[]const u8,
    revision_timestamp_raw: ?[]const u8,
    revision_user_raw: ?[]const u8,
    model_raw: ?[]const u8,
    format_raw: ?[]const u8,
    text_raw: ?[]const u8,
};

const Element = struct {
    content: []const u8,
    open_start: usize,
    open_end: usize,
    close_start: usize,
    self_closing: bool,
};

fn findOpen(hay: []const u8, comptime name: []const u8, start: usize) ?struct { start: usize, end: usize, self_closing: bool } {
    const prefix = "<" ++ name;
    var at = start;
    while (std.mem.indexOfPos(u8, hay, at, prefix)) |open| {
        const after = open + prefix.len;
        if (after >= hay.len) return null;
        const next = hay[after];
        if (next != '>' and next != '/' and !std.ascii.isWhitespace(next)) {
            at = after;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, hay, after, '>') orelse return null;
        var tail = end;
        while (tail > after and std.ascii.isWhitespace(hay[tail - 1])) tail -= 1;
        return .{ .start = open, .end = end + 1, .self_closing = tail > after and hay[tail - 1] == '/' };
    }
    return null;
}

fn element(hay: []const u8, comptime name: []const u8, start: usize) ?Element {
    const open = findOpen(hay, name, start) orelse return null;
    if (open.self_closing) return .{
        .content = "",
        .open_start = open.start,
        .open_end = open.end,
        .close_start = open.end,
        .self_closing = true,
    };
    const close_tag = "</" ++ name ++ ">";
    const close = std.mem.indexOfPos(u8, hay, open.end, close_tag) orelse return null;
    return .{
        .content = hay[open.end..close],
        .open_start = open.start,
        .open_end = open.end,
        .close_start = close,
        .self_closing = false,
    };
}

fn attributeRaw(open_tag: []const u8, comptime name: []const u8) ?[]const u8 {
    var pos: usize = 1;
    while (pos < open_tag.len and open_tag[pos] != '>' and !std.ascii.isWhitespace(open_tag[pos])) pos += 1;
    while (pos < open_tag.len) {
        while (pos < open_tag.len and std.ascii.isWhitespace(open_tag[pos])) pos += 1;
        if (pos >= open_tag.len or open_tag[pos] == '>' or open_tag[pos] == '/') return null;
        const key_start = pos;
        while (pos < open_tag.len and open_tag[pos] != '=' and !std.ascii.isWhitespace(open_tag[pos]) and open_tag[pos] != '>') pos += 1;
        const key = open_tag[key_start..pos];
        while (pos < open_tag.len and std.ascii.isWhitespace(open_tag[pos])) pos += 1;
        if (pos >= open_tag.len or open_tag[pos] != '=') {
            while (pos < open_tag.len and !std.ascii.isWhitespace(open_tag[pos]) and open_tag[pos] != '>') pos += 1;
            continue;
        }
        pos += 1;
        while (pos < open_tag.len and std.ascii.isWhitespace(open_tag[pos])) pos += 1;
        if (pos >= open_tag.len or (open_tag[pos] != '"' and open_tag[pos] != '\'')) return null;
        const quote = open_tag[pos];
        pos += 1;
        const value_start = pos;
        while (pos < open_tag.len and open_tag[pos] != quote) pos += 1;
        if (pos >= open_tag.len) return null;
        const value = open_tag[value_start..pos];
        pos += 1;
        if (std.mem.eql(u8, key, name)) return value;
    }
    return null;
}

pub fn parsePage(raw: []const u8) !PageView {
    if (!std.mem.startsWith(u8, raw, "<page>")) return error.InvalidPageXml;
    const revision = element(raw, "revision", 0) orelse return error.InvalidPageXml;
    const before_revision = raw[0..revision.open_start];
    const title = element(before_revision, "title", 0) orelse return error.InvalidPageXml;
    const ns = element(before_revision, "ns", title.close_start) orelse return error.InvalidPageXml;
    const page_id = element(before_revision, "id", ns.close_start) orelse return error.InvalidPageXml;
    const redirect_open = findOpen(before_revision, "redirect", page_id.close_start);
    const redirect_raw = if (redirect_open) |open|
        attributeRaw(before_revision[open.start..open.end], "title")
    else
        null;

    const rev = revision.content;
    const revision_id = element(rev, "id", 0) orelse return error.InvalidPageXml;
    const timestamp = element(rev, "timestamp", revision_id.close_start) orelse return error.InvalidPageXml;
    const contributor = element(rev, "contributor", timestamp.close_start);
    const revision_user_raw = if (contributor) |contrib| blk: {
        if (element(contrib.content, "username", 0)) |username| break :blk username.content;
        if (element(contrib.content, "ip", 0)) |ip| break :blk ip.content;
        break :blk "";
    } else "";
    const model = element(rev, "model", timestamp.close_start) orelse return error.InvalidPageXml;
    const format = element(rev, "format", model.close_start);
    const text = element(rev, "text", if (format) |value| value.close_start else model.close_start);

    return .{
        .raw = raw,
        .title_raw = title.content,
        .ns_raw = ns.content,
        .redirect_raw = redirect_raw,
        .page_id_raw = page_id.content,
        .revision_id_raw = revision_id.content,
        .revision_timestamp_raw = timestamp.content,
        .revision_user_raw = revision_user_raw,
        .model_raw = model.content,
        .format_raw = if (format) |value| value.content else null,
        .text_raw = if (text) |value| value.content else null,
    };
}

pub const PageIterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *PageIterator) !?PageView {
        const start = std.mem.indexOfPos(u8, self.bytes, self.pos, "<page>") orelse return null;
        const close = std.mem.indexOfPos(u8, self.bytes, start + "<page>".len, "</page>") orelse return error.TruncatedXml;
        const end = close + "</page>".len;
        self.pos = end;
        return @as(?PageView, try parsePage(self.bytes[start..end]));
    }
};

pub const StreamSpan = struct {
    offset: u64,
    len: u64,
};

const BzByteReader = struct {
    handle: ?*anyopaque,
    buffer: [64 * 1024]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,

    fn open(allocator: std.mem.Allocator, path: []const u8) !BzByteReader {
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);
        const handle = BZ2_bzopen(zpath.ptr, "rb") orelse return error.Bzip2OpenFailed;
        return .{ .handle = handle };
    }

    fn close(self: *BzByteReader) void {
        if (self.handle != null) BZ2_bzclose(self.handle);
        self.handle = null;
    }

    fn readByte(self: *BzByteReader) !?u8 {
        if (self.pos == self.end) {
            const got = BZ2_bzread(self.handle, &self.buffer, @intCast(self.buffer.len));
            if (got < 0) return error.Bzip2ReadFailed;
            if (got == 0) return null;
            self.pos = 0;
            self.end = @intCast(got);
        }
        const byte = self.buffer[self.pos];
        self.pos += 1;
        return byte;
    }
};

const OffsetReader = struct {
    bz: BzByteReader,
    at_line_start: bool = true,
    value: u64 = 0,
    have_digit: bool = false,

    fn open(allocator: std.mem.Allocator, path: []const u8) !OffsetReader {
        return .{ .bz = try BzByteReader.open(allocator, path) };
    }

    fn close(self: *OffsetReader) void {
        self.bz.close();
    }

    fn next(self: *OffsetReader) !?u64 {
        while (try self.bz.readByte()) |byte| {
            if (self.at_line_start) {
                if (byte >= '0' and byte <= '9') {
                    self.have_digit = true;
                    self.value = std.math.mul(u64, self.value, 10) catch return error.InvalidMultistreamIndex;
                    self.value = std.math.add(u64, self.value, byte - '0') catch return error.InvalidMultistreamIndex;
                    continue;
                }
                if (byte != ':' or !self.have_digit) return error.InvalidMultistreamIndex;
                self.at_line_start = false;
                const result = self.value;
                self.value = 0;
                self.have_digit = false;
                return result;
            }
            if (byte == '\n') self.at_line_start = true;
        }
        if (self.have_digit or !self.at_line_start) return error.TruncatedMultistreamIndex;
        return null;
    }

    fn skipLineRemainder(self: *OffsetReader) !void {
        if (self.at_line_start) return;
        while (try self.bz.readByte()) |byte| {
            if (byte == '\n') {
                self.at_line_start = true;
                return;
            }
        }
        self.at_line_start = true;
    }
};

pub const StreamIterator = struct {
    offsets: OffsetReader,
    dump_size: u64,
    current: ?u64 = null,
    stream_id: u32 = 0,
    done: bool = false,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, dump_path: []const u8, index_path: []const u8) !StreamIterator {
        var file = try std.Io.Dir.cwd().openFile(io, dump_path, .{});
        defer file.close(io);
        const dump_size = (try file.stat(io)).size;
        var offsets = try OffsetReader.open(allocator, index_path);
        errdefer offsets.close();
        const first = try offsets.next() orelse return error.EmptyMultistreamIndex;
        try offsets.skipLineRemainder();
        if (first >= dump_size) return error.InvalidMultistreamIndex;
        return .{ .offsets = offsets, .dump_size = dump_size, .current = first };
    }

    pub fn close(self: *StreamIterator) void {
        self.offsets.close();
        self.done = true;
    }

    pub fn next(self: *StreamIterator) !?struct { id: u32, span: StreamSpan } {
        if (self.done) return null;
        const current = self.current orelse return null;
        while (true) {
            const next_offset = try self.offsets.next();
            if (next_offset == null) {
                if (current >= self.dump_size) return error.InvalidMultistreamIndex;
                self.done = true;
                const id = self.stream_id;
                self.stream_id += 1;
                return .{ .id = id, .span = .{ .offset = current, .len = self.dump_size - current } };
            }
            try self.offsets.skipLineRemainder();
            const next_stream_offset = next_offset.?;
            if (next_stream_offset == current) continue;
            if (next_stream_offset < current or next_stream_offset > self.dump_size) return error.InvalidMultistreamIndex;
            self.current = next_stream_offset;
            const id = self.stream_id;
            self.stream_id += 1;
            return .{ .id = id, .span = .{ .offset = current, .len = next_stream_offset - current } };
        }
    }
};

pub fn deriveMultistreamIndexPath(allocator: std.mem.Allocator, dump_path: []const u8) ![]u8 {
    const suffix = ".xml.bz2";
    if (!std.mem.endsWith(u8, dump_path, suffix)) return error.MultistreamIndexPathRequired;
    return std.fmt.allocPrint(allocator, "{s}-index.txt.bz2", .{dump_path[0 .. dump_path.len - suffix.len]});
}

pub fn decompressMemberAlloc(io: std.Io, allocator: std.mem.Allocator, file: *std.Io.File, span: StreamSpan) ![]u8 {
    const compressed_len = std.math.cast(usize, span.len) orelse return error.CompressedMemberTooLarge;
    if (compressed_len == 0 or compressed_len > std.math.maxInt(c_uint)) return error.CompressedMemberTooLarge;
    const compressed = try allocator.alloc(u8, compressed_len);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, span.offset) != compressed.len) return error.TruncatedDump;
    if (compressed.len < 4 or !std.mem.startsWith(u8, compressed, "BZh")) return error.InvalidBzip2Member;

    var capacity = @max(@as(usize, 64 * 1024), compressed.len *| 6);
    capacity = @min(capacity, max_member_uncompressed_bytes);
    while (true) {
        const out = try allocator.alloc(u8, capacity);
        var out_len: c_uint = @intCast(capacity);
        const rc = BZ2_bzBuffToBuffDecompress(out.ptr, &out_len, compressed.ptr, @intCast(compressed.len), 0, 0);
        if (rc == BZ_OK) {
            const actual: usize = @intCast(out_len);
            if (actual == out.len) return out;
            return try allocator.realloc(out, actual);
        }
        allocator.free(out);
        if (rc != BZ_OUTBUFF_FULL) return error.Bzip2DecompressFailed;
        if (capacity >= max_member_uncompressed_bytes) return error.Bzip2MemberTooLarge;
        capacity = @min(max_member_uncompressed_bytes, capacity * 2);
    }
}

pub const MultistreamWalker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    streams: StreamIterator,
    member: []u8 = &.{},

    pub fn open(io: std.Io, allocator: std.mem.Allocator, dump_path: []const u8, index_path: []const u8) !MultistreamWalker {
        var file = try std.Io.Dir.cwd().openFile(io, dump_path, .{});
        errdefer file.close(io);
        var streams = try StreamIterator.open(io, allocator, dump_path, index_path);
        errdefer streams.close();
        return .{ .io = io, .allocator = allocator, .file = file, .streams = streams };
    }

    pub fn deinit(self: *MultistreamWalker) void {
        if (self.member.len != 0) self.allocator.free(self.member);
        self.streams.close();
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn next(self: *MultistreamWalker) !?struct { id: u32, span: StreamSpan, bytes: []const u8 } {
        if (self.member.len != 0) {
            self.allocator.free(self.member);
            self.member = &.{};
        }
        const stream = try self.streams.next() orelse return null;
        self.member = try decompressMemberAlloc(self.io, self.allocator, &self.file, stream.span);
        return .{ .id = stream.id, .span = stream.span, .bytes = self.member };
    }
};

pub const PageIndexKind = enum { raw_xml, multistream_bz2 };

pub const PageSource = union(PageIndexKind) {
    raw_xml: struct { offset: u64, len: usize },
    multistream_bz2: struct { stream_id: u32, offset: usize, len: usize },
};

pub fn sourceLen(source: PageSource) usize {
    return switch (source) {
        .raw_xml => |loc| loc.len,
        .multistream_bz2 => |loc| loc.len,
    };
}

pub const IndexedPage = struct {
    source: PageSource,
    title: []const u8,
    redirect: ?[]const u8,
    page_id: u64,
    revision_id: u64,
    revision_timestamp: []const u8,
    revision_user: []const u8,
    content_model: []const u8,
    ns: u32,
    has_source: bool,
    source_needs_decode: bool,
};

fn parseBool(raw: []const u8) !bool {
    if (std.mem.eql(u8, raw, "1")) return true;
    if (std.mem.eql(u8, raw, "0")) return false;
    return error.InvalidPageIndex;
}

pub fn parsePageIndexLine(kind: PageIndexKind, line: []const u8) !IndexedPage {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const source: PageSource = switch (kind) {
        .raw_xml => .{ .raw_xml = .{
            .offset = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10),
            .len = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10),
        } },
        .multistream_bz2 => .{ .multistream_bz2 = .{
            .stream_id = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPageIndex, 10),
            .offset = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10),
            .len = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10),
        } },
    };
    const title = fields.next() orelse return error.InvalidPageIndex;
    const redirect_raw = fields.next() orelse return error.InvalidPageIndex;
    const page_id = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
    const revision_id = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
    const revision_timestamp = fields.next() orelse return error.InvalidPageIndex;
    const revision_user = fields.next() orelse return error.InvalidPageIndex;
    const content_model = fields.next() orelse return error.InvalidPageIndex;
    const ns = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPageIndex, 10);
    const has_source = try parseBool(fields.next() orelse return error.InvalidPageIndex);
    const source_needs_decode = try parseBool(fields.next() orelse return error.InvalidPageIndex);
    if (title.len == 0 or revision_timestamp.len == 0 or content_model.len == 0 or fields.next() != null) return error.InvalidPageIndex;
    return .{
        .source = source,
        .title = title,
        .redirect = if (redirect_raw.len == 0) null else redirect_raw,
        .page_id = page_id,
        .revision_id = revision_id,
        .revision_timestamp = revision_timestamp,
        .revision_user = revision_user,
        .content_model = content_model,
        .ns = ns,
        .has_source = has_source,
        .source_needs_decode = source_needs_decode,
    };
}

pub fn pageIndexKind(bytes: []const u8) PageIndexKind {
    const first_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    return if (std.mem.eql(u8, bytes[0..first_end], page_index_v2_header)) .multistream_bz2 else .raw_xml;
}

pub fn loadStreamTable(io: std.Io, allocator: std.mem.Allocator, path: []const u8, dump_size: u64) ![]StreamSpan {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = lines.next() orelse return error.InvalidStreamIndex;
    if (!std.mem.eql(u8, header, stream_index_header)) return error.InvalidStreamIndex;
    var spans: std.ArrayList(StreamSpan) = .empty;
    errdefer spans.deinit(allocator);
    var expected_id: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidStreamIndex, 10);
        const offset = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidStreamIndex, 10);
        const len = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidStreamIndex, 10);
        if (fields.next() != null or id != expected_id or len == 0 or offset > dump_size or len > dump_size - offset) return error.InvalidStreamIndex;
        try spans.append(allocator, .{ .offset = offset, .len = len });
        expected_id += 1;
    }
    return spans.toOwnedSlice(allocator);
}

const member_cache_max_entries: usize = 128;
const member_cache_max_bytes: usize = 128 * 1024 * 1024;

const CachedMember = struct {
    stream_id: u32,
    bytes: []u8,
    stamp: u64,
};

pub const SourceReader = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    // Provider metadata may use an arena; member eviction needs real per-allocation frees.
    cache_allocator: std.mem.Allocator,
    file: std.Io.File,
    kind: PageIndexKind,
    streams: []StreamSpan = &.{},
    cache: std.AutoHashMapUnmanaged(u32, CachedMember) = .empty,
    cache_bytes: usize = 0,
    cache_clock: u64 = 0,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        cache_allocator: std.mem.Allocator,
        dump_path: []const u8,
        kind: PageIndexKind,
        stream_table_path: ?[]const u8,
    ) !SourceReader {
        var file = try std.Io.Dir.cwd().openFile(io, dump_path, .{});
        errdefer file.close(io);
        const size = (try file.stat(io)).size;
        var streams: []StreamSpan = &.{};
        if (kind == .multistream_bz2) {
            const path = stream_table_path orelse return error.MissingStreamIndex;
            streams = try loadStreamTable(io, allocator, path, size);
        }
        return .{
            .io = io,
            .allocator = allocator,
            .cache_allocator = cache_allocator,
            .file = file,
            .kind = kind,
            .streams = streams,
        };
    }

    pub fn deinit(self: *SourceReader) void {
        var cache_values = self.cache.valueIterator();
        while (cache_values.next()) |entry| self.cache_allocator.free(entry.bytes);
        self.cache.deinit(self.cache_allocator);
        if (self.streams.len != 0) self.allocator.free(self.streams);
        self.file.close(self.io);
        self.* = undefined;
    }

    fn nextStamp(self: *SourceReader) u64 {
        self.cache_clock +%= 1;
        if (self.cache_clock == 0) {
            var values = self.cache.valueIterator();
            while (values.next()) |entry| entry.stamp = 0;
            self.cache_clock = 1;
        }
        return self.cache_clock;
    }

    fn copyCached(self: *SourceReader, allocator: std.mem.Allocator, loc: anytype) !?[]u8 {
        const entry = self.cache.getPtr(loc.stream_id) orelse return null;
        entry.stamp = self.nextStamp();
        if (loc.offset > entry.bytes.len or loc.len > entry.bytes.len - loc.offset) return error.InvalidPageIndex;
        return try allocator.dupe(u8, entry.bytes[loc.offset .. loc.offset + loc.len]);
    }

    fn cacheMember(self: *SourceReader, stream_id: u32, bytes: []u8) !void {
        if (bytes.len > member_cache_max_bytes) return error.MemberTooLargeToCache;
        while (self.cache.count() >= member_cache_max_entries or
            self.cache_bytes > member_cache_max_bytes - bytes.len)
        {
            var it = self.cache.iterator();
            const first = it.next() orelse return error.InvalidCacheState;
            var lru_id = first.key_ptr.*;
            var lru_stamp = first.value_ptr.stamp;
            while (it.next()) |entry| {
                if (entry.value_ptr.stamp < lru_stamp) {
                    lru_id = entry.key_ptr.*;
                    lru_stamp = entry.value_ptr.stamp;
                }
            }
            const old = self.cache.fetchRemove(lru_id) orelse return error.InvalidCacheState;
            self.cache_bytes -= old.value.bytes.len;
            self.cache_allocator.free(old.value.bytes);
        }
        try self.cache.put(self.cache_allocator, stream_id, .{
            .stream_id = stream_id,
            .bytes = bytes,
            .stamp = self.nextStamp(),
        });
        self.cache_bytes += bytes.len;
    }

    fn readCompressedAlloc(self: *SourceReader, allocator: std.mem.Allocator, loc: anytype) ![]u8 {
        if (try self.copyCached(allocator, loc)) |cached| return cached;
        const index: usize = @intCast(loc.stream_id);
        if (index >= self.streams.len) return error.InvalidPageIndex;
        const member = try decompressMemberAlloc(self.io, self.cache_allocator, &self.file, self.streams[index]);
        errdefer self.cache_allocator.free(member);
        if (loc.offset > member.len or loc.len > member.len - loc.offset) return error.InvalidPageIndex;
        const out = try allocator.dupe(u8, member[loc.offset .. loc.offset + loc.len]);
        errdefer allocator.free(out);
        if (member.len <= member_cache_max_bytes) {
            try self.cacheMember(loc.stream_id, member);
        } else {
            self.cache_allocator.free(member);
        }
        return out;
    }

    pub fn readAlloc(self: *SourceReader, allocator: std.mem.Allocator, source: PageSource) ![]const u8 {
        return switch (source) {
            .raw_xml => |loc| blk: {
                if (loc.len == 0) break :blk "";
                const out = try allocator.alloc(u8, loc.len);
                errdefer allocator.free(out);
                if (try self.file.readPositionalAll(self.io, out, loc.offset) != out.len) return error.TruncatedDump;
                break :blk out;
            },
            .multistream_bz2 => |loc| if (loc.len == 0) "" else try self.readCompressedAlloc(allocator, loc),
        };
    }
};

test "specialized page parser extracts Wikimedia page fields without a DOM" {
    const xml = "<page><title>A&amp;B</title><ns>0</ns><id>7</id><redirect title=\"C&amp;D\"/><revision><id>70</id><timestamp>2026-09-01T00:00:00Z</timestamp><contributor><username>Alice</username></contributor><model>wikitext</model><format>text/x-wiki</format><text bytes=\"20\" xml:space=\"preserve\">==English==&amp;x</text></revision></page>";
    const page = try parsePage(xml);
    try std.testing.expectEqualStrings("A&amp;B", page.title_raw.?);
    try std.testing.expectEqualStrings("0", page.ns_raw.?);
    try std.testing.expectEqualStrings("7", page.page_id_raw.?);
    try std.testing.expectEqualStrings("70", page.revision_id_raw.?);
    try std.testing.expectEqualStrings("Alice", page.revision_user_raw.?);
    try std.testing.expectEqualStrings("C&amp;D", page.redirect_raw.?);
    try std.testing.expectEqualStrings("wikitext", page.model_raw.?);
    try std.testing.expectEqualStrings("text/x-wiki", page.format_raw.?);
    try std.testing.expectEqualStrings("==English==&amp;x", page.text_raw.?);
}

test "specialized page parser handles ip contributors and self-closing text" {
    const xml = "<page><title>X</title><ns>10</ns><id>8</id><revision><id>80</id><timestamp>2026-09-01T00:00:01Z</timestamp><contributor><ip>192.0.2.1</ip></contributor><model>wikitext</model><format>text/x-wiki</format><text bytes=\"0\" /></revision></page>";
    const page = try parsePage(xml);
    try std.testing.expectEqualStrings("192.0.2.1", page.revision_user_raw.?);
    try std.testing.expect(page.text_raw != null);
    try std.testing.expectEqualStrings("", page.text_raw.?);
}

test "page index parser accepts legacy raw and compressed v2 rows" {
    const raw = try parsePageIndexLine(.raw_xml, "12\t3\tcat\t\t7\t70\t2026-09-01T00:00:00Z\tA\twikitext\t0\t1\t0");
    try std.testing.expectEqual(@as(u64, 12), raw.source.raw_xml.offset);
    const compressed = try parsePageIndexLine(.multistream_bz2, "4\t120\t3\tcat\t\t7\t70\t2026-09-01T00:00:00Z\tA\twikitext\t0\t1\t0");
    try std.testing.expectEqual(@as(u32, 4), compressed.source.multistream_bz2.stream_id);
    try std.testing.expectEqual(@as(usize, 120), compressed.source.multistream_bz2.offset);
}

extern fn BZ2_bzBuffToBuffCompress(
    dest: [*]u8,
    dest_len: *c_uint,
    source: [*]const u8,
    source_len: c_uint,
    block_size_100k: c_int,
    verbosity: c_int,
    work_factor: c_int,
) c_int;

fn testCompressAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const capacity = input.len + input.len / 100 + 601;
    const out = try allocator.alloc(u8, capacity);
    errdefer allocator.free(out);
    var len: c_uint = @intCast(out.len);
    if (BZ2_bzBuffToBuffCompress(out.ptr, &len, input.ptr, @intCast(input.len), 9, 0, 30) != BZ_OK)
        return error.TestBzip2CompressFailed;
    return allocator.realloc(out, @intCast(len));
}

test "multistream offsets and source reads stay compressed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const header = try testCompressAlloc(a, "<mediawiki>");
    defer a.free(header);
    const page_a_xml = "<page><title>A</title><ns>0</ns><id>1</id><revision><id>11</id><timestamp>2026-09-01T00:00:00Z</timestamp><contributor><username>X</username></contributor><model>wikitext</model><format>text/x-wiki</format><text>hello&amp;</text></revision></page>";
    const page_b_xml = "<page><title>B</title><ns>0</ns><id>2</id><revision><id>22</id><timestamp>2026-09-01T00:00:01Z</timestamp><contributor><username>Y</username></contributor><model>wikitext</model><format>text/x-wiki</format><text>world</text></revision></page>";
    const member_a = try testCompressAlloc(a, page_a_xml);
    defer a.free(member_a);
    const member_b = try testCompressAlloc(a, page_b_xml);
    defer a.free(member_b);

    const offset_a = header.len;
    const offset_b = header.len + member_a.len;
    const index_text = try std.fmt.allocPrint(a, "{d}:1:A\n{d}:2:B\n", .{ offset_a, offset_b });
    defer a.free(index_text);
    const index_bz2 = try testCompressAlloc(a, index_text);
    defer a.free(index_bz2);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const dump_path = try std.fs.path.join(a, &.{ root, "sample-multistream.xml.bz2" });
    defer a.free(dump_path);
    const index_path = try std.fs.path.join(a, &.{ root, "sample-multistream-index.txt.bz2" });
    defer a.free(index_path);
    const streams_path = try std.fs.path.join(a, &.{ root, "dump-streams.tsv" });
    defer a.free(streams_path);

    var dump_bytes: std.ArrayList(u8) = .empty;
    defer dump_bytes.deinit(a);
    try dump_bytes.appendSlice(a, header);
    try dump_bytes.appendSlice(a, member_a);
    try dump_bytes.appendSlice(a, member_b);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_bz2 });

    var streams = try StreamIterator.open(io, a, dump_path, index_path);
    defer streams.close();
    const first = (try streams.next()).?;
    const second = (try streams.next()).?;
    try std.testing.expectEqual(@as(u64, @intCast(offset_a)), first.span.offset);
    try std.testing.expectEqual(@as(u64, @intCast(member_a.len)), first.span.len);
    try std.testing.expectEqual(@as(u64, @intCast(offset_b)), second.span.offset);
    try std.testing.expectEqual(@as(u64, @intCast(member_b.len)), second.span.len);
    try std.testing.expect((try streams.next()) == null);

    const table = try std.fmt.allocPrint(a, "{s}\n0\t{d}\t{d}\n1\t{d}\t{d}\n", .{
        stream_index_header,
        offset_a,
        member_a.len,
        offset_b,
        member_b.len,
    });
    defer a.free(table);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = streams_path, .data = table });

    const source_start = std.mem.indexOf(u8, page_a_xml, "hello&amp;").?;
    var metadata_arena = std.heap.ArenaAllocator.init(a);
    defer metadata_arena.deinit();
    var reader = try SourceReader.open(io, metadata_arena.allocator(), a, dump_path, .multistream_bz2, streams_path);
    defer reader.deinit();
    const raw = try reader.readAlloc(a, .{ .multistream_bz2 = .{
        .stream_id = 0,
        .offset = source_start,
        .len = "hello&amp;".len,
    } });
    defer a.free(raw);
    try std.testing.expectEqualStrings("hello&amp;", raw);
}
