const std = @import("std");
const format = @import("encoder").blob_format;

// A map covers at most window_bytes plus the prefix needed for page alignment.
// Descriptors close after each mapping, so shard count does not consume FDs.
pub const Window = struct {
    io: std.Io,
    path: []const u8,
    initial: std.Io.File.Stat,
    size: usize,
    window_bytes: usize = 256 * 1024,
    mapped: []align(std.heap.page_size_min) const u8 = &.{},
    mapped_offset: usize = 0,

    pub fn init(io: std.Io, path: []const u8) !Window {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(io);
        const stat = try file.stat(io);
        return .{ .io = io, .path = path, .initial = stat, .size = std.math.cast(usize, stat.size) orelse return error.FileTooBig };
    }

    pub fn deinit(self: *Window) void {
        if (self.mapped.len != 0) std.posix.munmap(self.mapped);
        self.mapped = &.{};
    }

    fn openUnchanged(self: *const Window) !std.Io.File {
        const fd = std.posix.openat(std.posix.AT.FDCWD, self.path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidBlob,
            else => return err,
        };
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.inode != self.initial.inode or stat.size != self.initial.size or stat.kind != self.initial.kind or
            !std.meta.eql(stat.mtime, self.initial.mtime) or !std.meta.eql(stat.ctime, self.initial.ctime)) return error.InvalidBlob;
        return file;
    }

    pub fn checkIdentity(self: *const Window) !void {
        var file = try self.openUnchanged();
        file.close(self.io);
    }

    pub fn slice(self: *Window, offset: usize) ![]const u8 {
        if (offset >= self.size) return error.InvalidBlob;
        if (offset >= self.mapped_offset and offset - self.mapped_offset < self.mapped.len)
            return self.mapped[offset - self.mapped_offset ..];
        self.deinit();
        var file = try self.openUnchanged();
        defer file.close(self.io);
        const aligned = std.mem.alignBackward(usize, offset, std.heap.pageSize());
        const length = offset - aligned + @min(@max(self.window_bytes, 1), self.size - offset);
        self.mapped = try std.posix.mmap(null, length, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, aligned);
        self.mapped_offset = aligned;
        return self.mapped[offset - aligned ..];
    }

    pub fn readInto(self: *Window, offset: usize, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset) return error.InvalidBlob;
        var done: usize = 0;
        while (done < out.len) {
            const bytes = try self.slice(offset + done);
            const count = @min(bytes.len, out.len - done);
            @memcpy(out[done .. done + count], bytes[0..count]);
            done += count;
        }
    }

    pub fn copyRange(self: *Window, offset: usize, length: usize, writer: *std.Io.Writer) !void {
        if (offset > self.size or length > self.size - offset) return error.InvalidBlob;
        var done: usize = 0;
        while (done < length) {
            const bytes = try self.slice(offset + done);
            const count = @min(bytes.len, length - done);
            try writer.writeAll(bytes[0..count]);
            done += count;
        }
    }

    // Appends one field, excluding its delimiter. NUL fields require their
    // delimiter; manifest lines may end at EOF exactly as catalog.Iterator does.
    pub fn readDelimited(self: *Window, a: std.mem.Allocator, cursor: *usize, delimiter: u8, out: *std.ArrayList(u8), allow_eof: bool) !void {
        if (cursor.* > self.size) return error.InvalidBlob;
        while (cursor.* < self.size) {
            const bytes = try self.slice(cursor.*);
            const end = std.mem.indexOfScalar(u8, bytes, delimiter) orelse bytes.len;
            try out.appendSlice(a, bytes[0..end]);
            cursor.* += end;
            if (end < bytes.len) {
                cursor.* += 1;
                return;
            }
        }
        if (!allow_eof) return error.InvalidBlob;
    }
};

pub const Record = struct {
    title: []const u8,
    payload_offset: usize,
    payload_len: usize,
};

// Owns metadata and two reusable title buffers. Returned title views are valid
// only until the next next()/reset()/deinit(); payloads remain file ranges.
pub const Reader = struct {
    window: Window,
    allocator: std.mem.Allocator,
    kind: format.BlobKind = .citations,
    metadata: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    next_title: std.ArrayList(u8) = .empty,
    has_previous: bool = false,
    records_start: usize = 0,
    cursor: usize = 0,

    pub fn init(io: std.Io, a: std.mem.Allocator, path: []const u8) !Reader {
        return initWindowed(io, a, path, 256 * 1024);
    }

    fn initWindowed(io: std.Io, a: std.mem.Allocator, path: []const u8, window_bytes: usize) !Reader {
        var self: Reader = .{ .window = try Window.init(io, path), .allocator = a };
        self.window.window_bytes = @max(window_bytes, 1);
        errdefer self.deinit();
        var header: [format.header_len]u8 = undefined;
        try self.window.readInto(0, &header);
        self.kind = try format.decodeKind(&header);
        self.cursor = format.header_len;
        if (self.kind == .language) {
            try self.window.readDelimited(a, &self.cursor, 0, &self.metadata, false);
            try self.metadata.append(a, 0);
            try self.window.readDelimited(a, &self.cursor, 0, &self.metadata, false);
            try self.metadata.append(a, 0);
        }
        format.validateMetadata(self.kind, self.metadata.items) catch return error.InvalidBlob;
        self.records_start = self.cursor;
        return self;
    }

    pub fn deinit(self: *Reader) void {
        self.window.deinit();
        self.metadata.deinit(self.allocator);
        self.title.deinit(self.allocator);
        self.next_title.deinit(self.allocator);
    }

    pub fn reset(self: *Reader) void {
        self.cursor = self.records_start;
        self.title.clearRetainingCapacity();
        self.next_title.clearRetainingCapacity();
        self.has_previous = false;
    }

    // Preserve inspect()'s complete framing/order preflight before callers test
    // kind/metadata, create an output, or decode any presentation payload.
    pub fn validate(self: *Reader) !void {
        self.reset();
        while (try self.next()) |_| {}
        self.reset();
    }

    pub fn languageMetadata(self: *const Reader) !format.LanguageMetadata {
        const view: format.BlobView = .{ .bytes = &.{}, .kind = self.kind, .metadata = self.metadata.items, .records = &.{} };
        return view.languageMetadata();
    }

    pub fn next(self: *Reader) !?Record {
        if (self.cursor == self.window.size) {
            try self.window.checkIdentity();
            return null;
        }
        self.next_title.clearRetainingCapacity();
        try self.window.readDelimited(self.allocator, &self.cursor, 0, &self.next_title, false);
        if (self.next_title.items.len == 0) return error.InvalidBlob;
        var encoded: [format.max_varuint_len]u8 = undefined;
        var encoded_len: usize = 0;
        while (true) {
            if (encoded_len == encoded.len or self.cursor == self.window.size) return error.InvalidBlob;
            const byte = (try self.window.slice(self.cursor))[0];
            self.cursor += 1;
            encoded[encoded_len] = byte;
            encoded_len += 1;
            if ((byte & 0x80) == 0) break;
        }
        var length_cursor: usize = 0;
        const payload_len = try format.readPayloadLength(encoded[0..encoded_len], &length_cursor);
        if (payload_len > self.window.size - self.cursor) return error.InvalidBlob;
        if (self.has_previous and std.mem.order(u8, self.title.items, self.next_title.items) != .lt) return error.InvalidBlob;
        std.mem.swap(std.ArrayList(u8), &self.title, &self.next_title);
        self.has_previous = true;
        const result: Record = .{ .title = self.title.items, .payload_offset = self.cursor, .payload_len = payload_len };
        self.cursor += payload_len;
        return result;
    }

    pub fn copyPayload(self: *Reader, record: Record, writer: *std.Io.Writer) !void {
        try self.window.copyRange(record.payload_offset, record.payload_len, writer);
    }

    pub fn readPayloadAlloc(self: *Reader, a: std.mem.Allocator, record: Record) ![]u8 {
        if (record.payload_offset > self.window.size or record.payload_len > self.window.size - record.payload_offset) return error.InvalidBlob;
        const bytes = try a.alloc(u8, record.payload_len);
        errdefer a.free(bytes);
        try self.window.readInto(record.payload_offset, bytes);
        return bytes;
    }
};

fn expectValidReaderFixture(path: []const u8, window_bytes: usize) !void {
    var reader = try Reader.initWindowed(std.testing.io, std.testing.allocator, path, window_bytes);
    defer reader.deinit();
    reader.window.window_bytes = window_bytes;
    reader.window.deinit();
    try reader.validate();
}

test "window reader crosses metadata title varuint and payload boundaries and resets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/records", .{tmp.sub_path});
    defer a.free(path);
    const metadata = "en\x00English heading crossing several tiny windows\x00";
    const title = "a:012345678901234567890123456789012345678901234567890123456789";
    var payload: [257]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    const bytes = try format.buildAlloc(a, .language, metadata, &.{
        .{ .title = title, .payload = &payload },
        .{ .title = "b", .payload = "" },
        .{ .title = "c", .payload = "last" },
    });
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    for ([_]usize{ 1, 2, 3, 7, 31 }) |window_bytes| {
        var reader = try Reader.initWindowed(io, a, path, window_bytes);
        defer reader.deinit();
        reader.window.window_bytes = window_bytes;
        reader.window.deinit();
        // Repeated validation must not consume the subsequent caller iteration.
        try reader.validate();
        try reader.validate();
        try std.testing.expectEqual(format.BlobKind.language, reader.kind);
        try std.testing.expectEqualSlices(u8, metadata, reader.metadata.items);
        const first = (try reader.next()).?;
        try std.testing.expectEqualStrings(title, first.title);
        try std.testing.expectEqual(@as(usize, 257), first.payload_len);
        try std.testing.expectEqual(@as(u64, format.header_len + metadata.len + title.len + 1 + 2), @as(u64, @intCast(first.payload_offset)));
        // Payload methods must not invalidate current owned title or metadata,
        // even though their internal mappings will change many times.
        var copied: std.Io.Writer.Allocating = .init(a);
        defer copied.deinit();
        try reader.copyPayload(first, &copied.writer);
        try std.testing.expectEqualSlices(u8, &payload, copied.written());
        try std.testing.expectEqualStrings(title, first.title);
        try std.testing.expectEqualSlices(u8, metadata, reader.metadata.items);
        const allocated = try reader.readPayloadAlloc(a, first);
        defer a.free(allocated);
        try std.testing.expectEqualSlices(u8, &payload, allocated);
        try std.testing.expectEqualStrings(title, first.title);
        const second = (try reader.next()).?;
        try std.testing.expectEqualStrings("b", second.title);
        try std.testing.expectEqual(@as(usize, 0), second.payload_len);
        const empty = try reader.readPayloadAlloc(a, second);
        defer a.free(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.len);
        const third = (try reader.next()).?;
        try std.testing.expectEqualStrings("c", third.title);
        const last = try reader.readPayloadAlloc(a, third);
        defer a.free(last);
        try std.testing.expectEqualStrings("last", last);
        try std.testing.expect(reader.window.mapped.len <= window_bytes + std.heap.pageSize() - 1);
        try std.testing.expect((try reader.next()) == null);
        try std.testing.expect((try reader.next()) == null);
        try reader.validate();
        try std.testing.expectEqualStrings(title, (try reader.next()).?.title);
    }
}

test "window reader rejects malformed framing and source order with InvalidBlob" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/malformed", .{tmp.sub_path});
    defer a.free(path);
    const malformed = [_][]const u8{
        "", "WIKBLB08", "BADBLB08\x07", "WIKBLB08\x00", "WIKBLB08\x08",
        "WIKBLB08\x01", // No language code terminator.
        "WIKBLB08\x01en\x00", // No heading terminator.
        "WIKBLB08\x01en\x00English", // Unterminated heading.
        "WIKBLB08\x01en\x00\x00", // Empty heading.
        "WIKBLB08\x07\x00\x00", // Empty title.
        "WIKBLB08\x07unterminated", // Unterminated title.
        "WIKBLB08\x07a\x00", // Missing length.
        "WIKBLB08\x07a\x00\x80", // Truncated continuation.
        "WIKBLB08\x07a\x00\x80\x00", // Noncanonical zero.
        "WIKBLB08\x07a\x00\x81\x00x", // Noncanonical one.
        "WIKBLB08\x07a\x00\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02", // u64 overflow.
        "WIKBLB08\x07a\x00\x80\x80\x80\x80\x80\x80\x80\x80\x80\x81", // Continued tenth byte.
        "WIKBLB08\x07a\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", // Valid max length; end overflow.
        "WIKBLB08\x07a\x00\x02x", // Short payload.
        "WIKBLB08\x07a\x00\x00z", // Trailing incomplete record.
        "WIKBLB08\x07a\x00\x00a\x00\x00", // Duplicate within one source.
        "WIKBLB08\x07b\x00\x00a\x00\x00", // Descending source order.
    };
    for (malformed) |bytes| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        for ([_]usize{ 1, 3, 17 }) |window_bytes|
            try std.testing.expectError(error.InvalidBlob, expectValidReaderFixture(path, window_bytes));
    }
}

test "window reader retains existing valid zero record empty code and opaque title cases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/valid", .{tmp.sub_path});
    defer a.free(path);
    const valid = [_][]const u8{
        "WIKBLB08\x07", // Empty feature blob.
        "WIKBLB08\x01\x00Unclassified\x00", // Empty code is intentionally legal.
        "WIKBLB08\x01en\x00English\x00", // Empty language blob.
        "WIKBLB08\x07a\x00\x00", // Zero payload is format-valid.
        "WIKBLB08\x07\xff\x00\x00", // Format does not require title UTF-8.
        "WIKBLB08\x07a\x00\x01\x00b\x00\x01\xff", // Payload is opaque framing data.
    };
    for (valid) |bytes| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        try expectValidReaderFixture(path, 1);
    }
}

test "window reader rejects inode replacement on a later remap" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/source", .{tmp.sub_path});
    defer a.free(path);
    const replacement = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/replacement", .{tmp.sub_path});
    defer a.free(replacement);
    // More than one default window forces a real remap after replacement.
    const payload = try a.alloc(u8, 256 * 1024 + 31);
    defer a.free(payload);
    @memset(payload, 'x');
    const bytes = try format.buildAlloc(a, .supplemental, "", &.{
        .{ .title = "a", .payload = payload },
    });
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var reader = try Reader.init(io, a, path);
    defer reader.deinit();
    reader.window.window_bytes = 7;
    try reader.validate();
    const record = (try reader.next()).?;
    // Atomic replacement avoids SIGBUS from truncating an already mapped inode.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = replacement, .data = bytes });
    try std.Io.Dir.cwd().rename(replacement, std.Io.Dir.cwd(), path, io);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expectError(error.InvalidBlob, reader.copyPayload(record, &out.writer));
}

test "window reader rejects same-inode truncation before a new mapping" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/input", .{tmp.sub_path});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x07a\x00\x01x" });
    var reader = try Reader.init(io, a, path);
    defer reader.deinit();
    try reader.validate();
    reader.window.deinit();
    // Drop the old mapping first so this test never accesses truncated pages.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "WIKBLB08\x07" });
    try std.testing.expectError(error.InvalidBlob, reader.next());
}
