//! Native derived indexes and seekable transport, deliberately outside .wikblb.
//! A cache is disposable. Source identity, checksum, bounds and title order are checked.
const std = @import("std");
const enc = @import("blob_encoder");
const format = enc.blob_format;
const Xz = @import("xz.zig").Source;
const A = std.mem.Allocator;
const Row = extern struct { offset: u64, length: u32, title: u32 };
const cache_magic = "DIXIDX03";
const cache_row_alignment = 8;
comptime {
    std.debug.assert(@sizeOf(Row) == 16);
}
const max_index_bytes = 512 * 1024 * 1024;
const max_record_bytes = 64 * 1024 * 1024;
const Directory = struct {
    header: []const u8,
    rows: []const Row,
    titles: []const u8,
    owned: bool,
    fn deinit(self: *Directory, a: A) void {
        if (self.owned) {
            a.free(@constCast(self.header));
            a.free(@constCast(self.rows));
            a.free(@constCast(self.titles));
        }
        self.* = undefined;
    }
    fn titleAt(self: Directory, i: usize) []const u8 {
        const start: usize = @intCast(self.rows[i].title);
        const end: usize = if (i + 1 < self.rows.len) @intCast(self.rows[i + 1].title - 1) else self.titles.len - 1;
        return self.titles[start..end];
    }
    fn validate(self: Directory, size: u64) !void {
        _ = try format.openTrusted(self.header);
        var next: u64 = self.header.len;
        var title_end: usize = 0;
        for (self.rows, 0..) |r, i| {
            if (r.title != title_end or r.title >= self.titles.len) return error.InvalidCache;
            const end = std.mem.indexOfScalarPos(u8, self.titles, title_end, 0) orelse return error.InvalidCache;
            if (end == title_end) return error.InvalidCache;
            if (i != 0 and std.mem.order(u8, self.titleAt(i - 1), self.titles[title_end..end]) != .lt) return error.InvalidCache;
            var length: [format.max_varuint_len]u8 = undefined;
            const n = format.encodePayloadLength(std.math.cast(usize, r.length) orelse return error.InvalidCache, &length).len;
            next = std.math.add(u64, next, end - title_end + 1 + n) catch return error.InvalidCache;
            if (r.offset != next or r.offset > size or r.length > size - r.offset) return error.InvalidCache;
            next += r.length;
            title_end = end + 1;
        }
        if (next != size or title_end != self.titles.len) return error.InvalidCache;
    }
};
const Builder = struct {
    a: A,
    header: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    titles: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    state: enum { header, title, length, payload } = .header,
    offset: u64 = 0,
    remaining: u64 = 0,
    length: [format.max_varuint_len]u8 = undefined,
    nlength: usize = 0,
    fn deinit(self: *Builder) void {
        self.header.deinit(self.a);
        self.rows.deinit(self.a);
        self.titles.deinit(self.a);
        self.title.deinit(self.a);
    }
    fn headerComplete(self: Builder) !bool {
        const h = self.header.items;
        if (h.len < 9) return false;
        const base: usize = if (std.mem.eql(u8, h[0..8], format.magic)) format.header_len else if (std.mem.eql(u8, h[0..8], format.legacy_magic)) format.legacy_header_len else return error.InvalidBlob;
        if (h.len < base) return false;
        if (h[8] == 1 or h[8] == 7) {
            const zero1 = std.mem.indexOfScalarPos(u8, h, base, 0) orelse return false;
            const zero2 = std.mem.indexOfScalarPos(u8, h, zero1 + 1, 0) orelse return false;
            return h.len >= zero2 + 1 + @as(usize, if (h[8] == 7) 1 else 0);
        }
        return true;
    }
    pub fn feed(self: *Builder, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) switch (self.state) {
            .header => {
                if (self.header.items.len >= 1024 * 1024) return error.BlobMetadataLimit;
                try self.header.append(self.a, bytes[pos]);
                pos += 1;
                self.offset += 1;
                if (try self.headerComplete()) {
                    _ = try format.openTrusted(self.header.items);
                    self.state = .title;
                }
            },
            .title => {
                const end = std.mem.indexOfScalarPos(u8, bytes, pos, 0) orelse bytes.len;
                if (end - pos > 1024 * 1024 - self.title.items.len) return error.BlobTitleLimit;
                try self.title.appendSlice(self.a, bytes[pos..end]);
                self.offset += end - pos;
                pos = end;
                if (pos < bytes.len) {
                    if (self.title.items.len == 0) return error.InvalidBlob;
                    pos += 1;
                    self.offset += 1;
                    self.nlength = 0;
                    self.state = .length;
                }
            },
            .length => {
                if (self.nlength == self.length.len) return error.InvalidBlob;
                const b = bytes[pos];
                self.length[self.nlength] = b;
                self.nlength += 1;
                pos += 1;
                self.offset += 1;
                if (b & 128 == 0) {
                    var p: usize = 0;
                    const len = try format.readPayloadLength(self.length[0..self.nlength], &p);
                    if (self.rows.items.len != 0) {
                        const previous: usize = @intCast(self.rows.items[self.rows.items.len - 1].title);
                        if (std.mem.order(u8, self.titles.items[previous .. self.titles.items.len - 1], self.title.items) != .lt) return error.InvalidBlob;
                    }
                    try self.rows.append(self.a, .{ .offset = self.offset, .length = std.math.cast(u32, len) orelse return error.RecordLimit, .title = std.math.cast(u32, self.titles.items.len) orelse return error.IndexLimit });
                    try self.titles.appendSlice(self.a, self.title.items);
                    try self.titles.append(self.a, 0);
                    self.title.clearRetainingCapacity();
                    self.remaining = len;
                    self.state = if (len == 0) .title else .payload;
                    if (self.rows.items.len * @sizeOf(Row) + self.titles.items.len > max_index_bytes) return error.IndexLimit;
                }
            },
            .payload => {
                const n: usize = @intCast(@min(bytes.len - pos, self.remaining));
                self.remaining -= n;
                self.offset += n;
                pos += n;
                if (self.remaining == 0) self.state = .title;
            },
        };
    }
    fn finish(self: *Builder, size: u64) !Directory {
        if (self.state != .title or self.title.items.len != 0 or self.offset != size) return error.InvalidBlob;
        const header = try self.header.toOwnedSlice(self.a);
        errdefer self.a.free(header);
        const rows = try self.rows.toOwnedSlice(self.a);
        errdefer self.a.free(rows);
        return .{ .header = header, .rows = rows, .titles = try self.titles.toOwnedSlice(self.a), .owned = true };
    }
};
fn identity(stat: std.Io.File.Stat) [32]u8 {
    var bytes: [56]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], stat.inode, .little);
    std.mem.writeInt(u64, bytes[8..16], stat.size, .little);
    std.mem.writeInt(i128, bytes[16..32], stat.mtime.nanoseconds, .little);
    std.mem.writeInt(i128, bytes[32..48], stat.ctime.nanoseconds, .little);
    std.mem.writeInt(u64, bytes[48..56], @intFromEnum(stat.kind), .little);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &hash, .{});
    return hash;
}
fn put(out: *std.Io.Writer, value: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, value, .little);
    try out.writeAll(&b);
}
fn take(bytes: []const u8, pos: *usize) !u64 {
    if (pos.* > bytes.len or bytes.len - pos.* < 8) return error.InvalidCache;
    const n = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return n;
}
fn take32(bytes: []const u8, pos: *usize) !u32 {
    if (pos.* > bytes.len or bytes.len - pos.* < 4) return error.InvalidCache;
    const n = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return n;
}
fn validateCached(dir: Directory, size: u64) !void {
    _ = try format.openTrusted(dir.header);
    if (dir.rows.len == 0) {
        if (dir.titles.len != 0 or dir.header.len != size) return error.InvalidCache;
        return;
    }
    if (dir.titles.len == 0 or dir.titles[dir.titles.len - 1] != 0 or dir.rows[0].title != 0) return error.InvalidCache;
    const first_end = std.mem.indexOfScalar(u8, dir.titles, 0) orelse return error.InvalidCache;
    if (first_end == 0) return error.InvalidCache;
    var length: [format.max_varuint_len]u8 = undefined;
    const prefix = format.encodePayloadLength(dir.rows[0].length, &length).len;
    if (dir.rows[0].offset != dir.header.len + first_end + 1 + prefix) return error.InvalidCache;
    const last = dir.rows[dir.rows.len - 1];
    if (last.title >= dir.titles.len) return error.InvalidCache;
    const last_end = std.mem.indexOfScalarPos(u8, dir.titles, last.title, 0) orelse return error.InvalidCache;
    if (last_end + 1 != dir.titles.len or last.offset > size or last.length != size - last.offset) return error.InvalidCache;
}
fn cacheDecode(a: A, bytes: []const u8, fingerprint: [32]u8, size: u64) !Directory {
    if (bytes.len < 96 or !std.mem.eql(u8, bytes[0..8], cache_magic) or !std.mem.eql(u8, bytes[8..40], &fingerprint)) return error.InvalidCache;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[72..], &hash, .{});
    if (!std.mem.eql(u8, bytes[40..72], &hash)) return error.InvalidCache;
    var p: usize = 72;
    const h = std.math.cast(usize, try take(bytes, &p)) orelse return error.InvalidCache;
    const n = std.math.cast(usize, try take(bytes, &p)) orelse return error.InvalidCache;
    const t = std.math.cast(usize, try take(bytes, &p)) orelse return error.InvalidCache;
    if (h > bytes.len - p) return error.InvalidCache;
    const header = bytes[p..][0..h];
    p += h;
    const row_start = std.mem.alignForward(usize, p, cache_row_alignment);
    if (row_start > bytes.len or row_start - p > 7) return error.InvalidCache;
    for (bytes[p..row_start]) |padding| if (padding != 0) return error.InvalidCache;
    const row_bytes = std.math.mul(usize, n, @sizeOf(Row)) catch return error.InvalidCache;
    if (row_bytes > bytes.len - row_start) return error.InvalidCache;
    const titles_start = row_start + row_bytes;
    if (t != bytes.len - titles_start) return error.InvalidCache;
    var result: Directory = if (@import("builtin").target.cpu.arch.endian() == .little) blk: {
        const aligned: []align(@alignOf(Row)) const u8 = @alignCast(bytes[row_start..titles_start]);
        break :blk .{ .header = header, .rows = std.mem.bytesAsSlice(Row, aligned), .titles = bytes[titles_start..], .owned = false };
    } else blk: {
        const owned_header = try a.dupe(u8, header);
        errdefer a.free(owned_header);
        const rows = try a.alloc(Row, n);
        errdefer a.free(rows);
        var cursor = row_start;
        for (rows) |*r| r.* = .{ .offset = try take(bytes, &cursor), .length = try take32(bytes, &cursor), .title = try take32(bytes, &cursor) };
        const titles = try a.dupe(u8, bytes[titles_start..]);
        break :blk .{ .header = owned_header, .rows = rows, .titles = titles, .owned = true };
    };
    errdefer result.deinit(a);
    try validateCached(result, size);
    return result;
}
fn hashed(w: *std.Io.Writer, hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) !void {
    hash.update(bytes);
    try w.writeAll(bytes);
}
fn save(io: std.Io, a: A, path: []const u8, fingerprint: [32]u8, dir: Directory) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const temp = try std.fmt.allocPrint(a, "{s}.{d}.{d}.tmp", .{ path, std.os.linux.getpid(), std.Io.Clock.awake.now(io).toNanoseconds() });
    defer a.free(temp);
    var file = try std.Io.Dir.cwd().createFile(io, temp, .{ .exclusive = true });
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    var buffer: [65536]u8 = undefined;
    var output = file.writer(io, &buffer);
    const w = &output.interface;
    try w.writeAll(cache_magic);
    try w.writeAll(&fingerprint);
    try w.splatByteAll(0, 32);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var word: [8]u8 = undefined;
    for ([_]u64{ dir.header.len, dir.rows.len, dir.titles.len }) |value| {
        std.mem.writeInt(u64, &word, value, .little);
        try hashed(w, &hash, &word);
    }
    try hashed(w, &hash, dir.header);
    const before_rows = 96 + dir.header.len;
    const padding = std.mem.alignForward(usize, before_rows, cache_row_alignment) - before_rows;
    var zeros: [cache_row_alignment - 1]u8 = @splat(0);
    try hashed(w, &hash, zeros[0..padding]);
    for (dir.rows) |r| {
        std.mem.writeInt(u64, &word, r.offset, .little);
        try hashed(w, &hash, &word);
        var small: [4]u8 = undefined;
        std.mem.writeInt(u32, &small, r.length, .little);
        try hashed(w, &hash, &small);
        std.mem.writeInt(u32, &small, r.title, .little);
        try hashed(w, &hash, &small);
    }
    try hashed(w, &hash, dir.titles);
    try w.flush();
    const digest = hash.finalResult();
    try file.writePositionalAll(io, &digest, 40);
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
}
pub const Record = struct {
    title: []const u8,
    payload: []const u8,
    a: A,
    owned: ?[]u8 = null,
    pub fn deinit(self: *Record) void {
        if (self.owned) |b| self.a.free(b);
        self.* = undefined;
    }
};
pub const File = struct {
    io: std.Io,
    a: A,
    handle: std.Io.File,
    path: []u8,
    bytes: []align(std.heap.page_size_min) const u8,
    cache_bytes: []align(std.heap.page_size_min) const u8 = &.{},
    compressed: ?Xz = null,
    directory: Directory,
    view: format.BlobView,
    size: u64,
    cache_hit: bool = false,
    cache_saved: bool = false,
    payload_reads: u64 = 0,
    fingerprint: [32]u8,
    pub fn open(io: std.Io, a: A, path: []const u8) !File {
        return openExact(io, a, path) catch |err| switch (err) {
            error.FileNotFound => {
                const x = try std.mem.concat(a, u8, &.{ path, ".xz" });
                defer a.free(x);
                return openExact(io, a, x);
            },
            else => return err,
        };
    }
    fn openExact(io: std.Io, a: A, path: []const u8) !File {
        var handle = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer handle.close(io);
        const stat = try handle.stat(io);
        if (stat.kind != .file or stat.size == 0) return error.InvalidBlob;
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, handle.handle, 0);
        errdefer std.posix.munmap(bytes);
        var compressed: ?Xz = if (std.mem.startsWith(u8, bytes, "\xfd7zXZ\x00")) try Xz.open(bytes) else null;
        errdefer if (compressed) |*x| x.deinit(a);
        const size = if (compressed) |x| x.size else len;
        const fingerprint = identity(stat);
        const path_cache = try std.fmt.allocPrint(a, "{s}/.dict-cache/{s}.idx", .{ std.fs.path.dirname(path) orelse ".", std.fs.path.basename(path) });
        defer a.free(path_cache);
        var cache_bytes: []align(std.heap.page_size_min) const u8 = &.{};
        errdefer if (cache_bytes.len != 0) std.posix.munmap(cache_bytes);
        var cache_file = std.Io.Dir.cwd().openFile(io, path_cache, .{}) catch null;
        if (cache_file) |*f| {
            defer f.close(io);
            const s = f.stat(io) catch null;
            if (s) |stat_cache| if (stat_cache.kind == .file and stat_cache.size >= 96 and stat_cache.size <= max_index_bytes + 1024 * 1024) {
                const cache_len = std.math.cast(usize, stat_cache.size) orelse 0;
                if (cache_len != 0) cache_bytes = std.posix.mmap(null, cache_len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0) catch &.{};
            };
        }
        var hit = false;
        var saved = false;
        var dir: Directory = blk: {
            if (cache_bytes.len != 0) {
                if (cacheDecode(a, cache_bytes, fingerprint, size)) |d| {
                    hit = true;
                    if (d.owned) {
                        std.posix.munmap(cache_bytes);
                        cache_bytes = &.{};
                    }
                    break :blk d;
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    std.posix.munmap(cache_bytes);
                    cache_bytes = &.{};
                }
            }
            var builder: Builder = .{ .a = a };
            defer builder.deinit();
            if (compressed) |*x| try x.scan(&builder) else try builder.feed(bytes);
            const d = try builder.finish(size);
            errdefer {
                var value = d;
                value.deinit(a);
            }
            if (!std.mem.eql(u8, &fingerprint, &identity(try handle.stat(io)))) return error.SourceChanged;
            if (save(io, a, path_cache, fingerprint, d)) |_| {
                saved = true;
            } else |err| {
                if (err == error.OutOfMemory) return err;
            }
            break :blk d;
        };
        errdefer dir.deinit(a);
        const view = try format.openTrusted(dir.header);
        const owned_path = try a.dupe(u8, path);
        if (compressed == null) std.posix.munmap(bytes);
        return .{ .io = io, .a = a, .handle = handle, .path = owned_path, .bytes = if (compressed != null) bytes else &.{}, .cache_bytes = cache_bytes, .compressed = compressed, .directory = dir, .view = view, .size = size, .cache_hit = hit, .cache_saved = saved, .fingerprint = fingerprint };
    }
    pub fn deinit(self: *File) void {
        self.directory.deinit(self.a);
        if (self.compressed) |*x| x.deinit(self.a);
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        if (self.cache_bytes.len != 0) std.posix.munmap(self.cache_bytes);
        self.a.free(self.path);
        self.handle.close(self.io);
        self.* = undefined;
    }
    pub fn recordCount(self: File) usize {
        return self.directory.rows.len;
    }
    pub fn titleAt(self: File, index: usize) ![]const u8 {
        if (index >= self.recordCount()) return error.InvalidRecordIndex;
        return self.directory.titleAt(index);
    }
    pub fn find(self: File, title: []const u8) ?usize {
        var lo: usize = 0;
        var hi = self.recordCount();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.directory.titleAt(mid), title)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }
    pub fn readAlloc(self: *File, a: A, index: usize) !Record {
        if (index >= self.recordCount()) return error.InvalidRecordIndex;
        const row = self.directory.rows[index];
        if (row.length > max_record_bytes) return error.RecordLimit;
        var r: Record = .{ .a = a, .title = self.directory.titleAt(index), .payload = undefined };
        if (self.compressed) |*x| {
            const data = try a.alloc(u8, @intCast(row.length));
            errdefer a.free(data);
            try x.read(self.a, row.offset, data);
            r.payload = data;
            r.owned = data;
        } else {
            const data = try a.alloc(u8, @intCast(row.length));
            errdefer a.free(data);
            if (try self.handle.readPositionalAll(self.io, data, row.offset) != data.len) return error.SourceChanged;
            r.payload = data;
            r.owned = data;
        }
        self.payload_reads += 1;
        return r;
    }
    pub fn prefix(self: File, text: []const u8) struct { start: usize, end: usize } {
        var lo: usize = 0;
        var hi = self.recordCount();
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.directory.titleAt(m), text) == .lt) lo = m + 1 else hi = m;
        }
        const start = lo;
        hi = self.recordCount();
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (std.mem.startsWith(u8, self.directory.titleAt(m), text)) lo = m + 1 else hi = m;
        }
        return .{ .start = start, .end = lo };
    }
    pub fn unchanged(self: File) !bool {
        var current = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer current.close(self.io);
        return std.mem.eql(u8, &self.fingerprint, &identity(try current.stat(self.io))) and std.mem.eql(u8, &self.fingerprint, &identity(try self.handle.stat(self.io)));
    }
    pub fn indexBytes(self: File) usize {
        return self.directory.rows.len * @sizeOf(Row) + self.directory.titles.len;
    }
    pub fn indexHeapBytes(self: File) usize {
        return if (self.directory.owned) self.indexBytes() + self.directory.header.len else 0;
    }
    pub fn cacheMappedBytes(self: File) usize {
        return self.cache_bytes.len;
    }
};
test "incremental derived index accepts every byte boundary and rejects damaged framing" {
    const a = std.testing.allocator;
    const input = try format.buildAlloc(a, .citations, "", &.{ .{ .title = "a", .payload = "\x00\xffbytes" }, .{ .title = "猫", .payload = "" } });
    defer a.free(input);
    for (1..input.len + 1) |step| {
        var b: Builder = .{ .a = a };
        defer b.deinit();
        var p: usize = 0;
        while (p < input.len) {
            const end = @min(input.len, p + step);
            try b.feed(input[p..end]);
            p = end;
        }
        var d = try b.finish(input.len);
        defer d.deinit(a);
        try d.validate(input.len);
        try std.testing.expectEqualStrings("猫", d.titleAt(1));
    }
    var bad: Builder = .{ .a = a };
    defer bad.deinit();
    try bad.feed(input[0 .. input.len - 1]);
    try std.testing.expectError(error.InvalidBlob, bad.finish(input.len - 1));
}

/// Only identity/semantic metadata. Does not build a record directory.
pub fn headerAlloc(io: std.Io, a: A, path: []const u8) ![]u8 {
    const alternate = try std.mem.concat(a, u8, &.{ path, ".xz" });
    defer a.free(alternate);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().openFile(io, alternate, .{}),
        else => return err,
    };
    defer file.close(io);
    const len = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
    if (len == 0) return error.InvalidBlob;
    const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(bytes);
    if (!std.mem.startsWith(u8, bytes, "\xfd7zXZ\x00")) {
        const view = try format.openTrusted(bytes);
        return a.dupe(u8, bytes[0 .. bytes.len - view.records.len]);
    }
    var x = try Xz.open(bytes);
    defer x.deinit(a);
    const Visitor = struct {
        builder: Builder,
        header: ?[]u8 = null,
        pub fn feed(self: *@This(), data: []const u8) !void {
            for (data, 0..) |_, i| {
                try self.builder.feed(data[i..][0..1]);
                if (self.builder.state != .header) {
                    self.header = try self.builder.header.toOwnedSlice(self.builder.a);
                    return error.HeaderFound;
                }
            }
        }
    };
    var visitor: Visitor = .{ .builder = .{ .a = a } };
    defer visitor.builder.deinit();
    x.scan(&visitor) catch |err| switch (err) {
        error.HeaderFound => {},
        else => return err,
    };
    return visitor.header orelse error.InvalidBlob;
}

test "an unavailable cache remains an explicit memory-only index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "test.wikblb" });
    defer a.free(path);
    const broken_cache = try std.fs.path.join(a, &.{ root, ".dict-cache" });
    defer a.free(broken_cache);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = broken_cache, .data = "not a directory" });
    const bytes = try format.buildAlloc(a, .citations, "", &.{.{ .title = "word", .payload = "body" }});
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var f = try File.open(io, a, path);
    defer f.deinit();
    try std.testing.expect(!f.cache_hit and !f.cache_saved);
    var record = try f.readAlloc(a, f.find("word").?);
    defer record.deinit();
    try std.testing.expectEqualStrings("body", record.payload);
}

fn allocationCase(a: A, path: []const u8) !void {
    var file = try File.open(std.testing.io, a, path);
    defer file.deinit();
    var record = try file.readAlloc(a, 0);
    defer record.deinit();
    try std.testing.expectEqualStrings("retained data", record.payload);
}
test "cached storage releases every failed allocation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/input.wikblb", .{tmp.sub_path});
    defer a.free(path);
    const bytes = try format.buildAlloc(a, .citations, "", &.{.{ .title = "word", .payload = "retained data" }});
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var initial = try File.open(std.testing.io, a, path);
    initial.deinit();
    var mapped = try File.open(std.testing.io, a, path);
    defer mapped.deinit();
    try std.testing.expect(mapped.cache_hit and mapped.indexHeapBytes() == 0 and mapped.cacheMappedBytes() != 0);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{path});
}
