const std = @import("std");

extern fn BZ2_bzBuffToBuffDecompress(dest: [*]u8, dest_len: *c_uint, source: [*]u8, source_len: c_uint, small: c_int, verbosity: c_int) c_int;

// Logical XML coordinates and historical frame coordinates are independent of
// the physical bzip2 transport. The authenticated producer supplies this table.
pub const Bridge = struct {
    frames: []const [2]u64,
    dump_bytes: u64,
    dump_sha256: []const u8,
    offset_index_bytes: u64,
    offset_index_sha256: []const u8,
    page_index_bytes: u64,
    page_index_sha256: []const u8,
};
const Part = struct {
    name: []const u8,
    size: u64,
    sha1: []const u8,
    xml_bytes: u64,
    blocks: []const [4]u64,
};
const Directory = struct {
    format: []const u8,
    xml_bytes: u64,
    source_pages: ?u64 = null,
    parts: []const Part,
    zstd_frame_bridge: ?Bridge = null,
};
const Block = struct { part: usize, raw_start: u64, row: [4]u64 };
const max_member_block = 4 * 1024 * 1024;
const max_raw_block = 64 * 1024 * 1024;

fn lowerHex(bytes: []const u8, len: usize) bool {
    if (bytes.len != len) return false;
    for (bytes) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub const Reader = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_allocator: std.mem.Allocator,
    cache: [2]?struct { index: usize, bytes: []u8, stamp: u64 } = .{ null, null },
    cache_bytes: usize = 0,
    clock: u64 = 0,
    decoded_block_count: usize = 0,
    parsed: std.json.Parsed(Directory),
    files: []std.Io.File,
    identities: []std.Io.File.Stat,
    blocks: []Block,

    // Part SHA-1 authentication belongs to normal intake, which must bind this
    // immutable descriptor to the selected official inventory. Size and native
    // block CRC checks below are not substitutes for that authentication.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, cache_allocator: std.mem.Allocator, directory_path: []const u8, source_directory: []const u8) !Reader {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, directory_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(Directory, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const d = parsed.value;
        if (!std.mem.eql(u8, d.format, "wikidict-bzip2-blocks-v1") or d.parts.len == 0 or d.parts.len > 1024) return error.InvalidBzip2Directory;
        const files = try allocator.alloc(std.Io.File, d.parts.len);
        errdefer allocator.free(files);
        const identities = try allocator.alloc(std.Io.File.Stat, d.parts.len);
        errdefer allocator.free(identities);
        var opened: usize = 0;
        errdefer for (files[0..opened]) |file| file.close(io);
        var blocks: std.ArrayList(Block) = .empty;
        errdefer blocks.deinit(allocator);
        var total: u64 = 0;
        for (d.parts, 0..) |part, pi| {
            if (part.name.len == 0 or std.mem.eql(u8, part.name, ".") or std.mem.eql(u8, part.name, "..") or
                std.mem.indexOfAny(u8, part.name, "/\\\x00") != null or !lowerHex(part.sha1, 40) or part.size > std.math.maxInt(u64) / 8)
                return error.InvalidBzip2Directory;
            for (d.parts[0..pi]) |prior| if (std.mem.eql(u8, prior.name, part.name)) return error.InvalidBzip2Directory;
            const path = try std.fs.path.join(allocator, &.{ source_directory, part.name });
            defer allocator.free(path);
            files[pi] = try std.Io.Dir.cwd().openFile(io, path, .{});
            opened += 1;
            identities[pi] = try files[pi].stat(io);
            if (identities[pi].kind != .file or identities[pi].size != part.size) return error.Bzip2PartChanged;
            var header: [4]u8 = undefined;
            if (try files[pi].readPositionalAll(io, &header, 0) != 4 or !std.mem.eql(u8, header[0..3], "BZh") or header[3] < '1' or header[3] > '9') return error.InvalidBzip2Directory;
            var raw: u64 = 0;
            var previous_end: u64 = 32;
            for (part.blocks) |row| {
                if (row[0] < previous_end or row[1] < 80 or row[1] > max_member_block * 8 or row[0] > part.size * 8 or row[1] > part.size * 8 - row[0] or row[2] > max_raw_block or row[3] < 1 or row[3] > 9) return error.InvalidBzip2Directory;
                try blocks.append(allocator, .{ .part = pi, .raw_start = try std.math.add(u64, total, raw), .row = row });
                raw = try std.math.add(u64, raw, row[2]);
                previous_end = row[0] + row[1];
            }
            if (raw != part.xml_bytes) return error.InvalidBzip2Directory;
            total = try std.math.add(u64, total, raw);
        }
        if (total != d.xml_bytes) return error.InvalidBzip2Directory;
        if (d.zstd_frame_bridge) |frame_bridge| {
            if (!lowerHex(frame_bridge.dump_sha256, 64) or !lowerHex(frame_bridge.offset_index_sha256, 64) or !lowerHex(frame_bridge.page_index_sha256, 64) or frame_bridge.dump_bytes == 0 or frame_bridge.offset_index_bytes == 0 or frame_bridge.page_index_bytes == 0) return error.InvalidBzip2Bridge;
            var next: u64 = 0;
            for (frame_bridge.frames) |frame| {
                if (frame[0] != next or frame[1] > max_raw_block) return error.InvalidBzip2Bridge;
                next = try std.math.add(u64, next, frame[1]);
            }
            if (next != total or frame_bridge.frames.len == 0) return error.InvalidBzip2Bridge;
        }
        return .{ .io = io, .allocator = allocator, .cache_allocator = cache_allocator, .parsed = parsed, .files = files, .identities = identities, .blocks = try blocks.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Reader) void {
        for (self.cache) |entry| if (entry) |cached| self.cache_allocator.free(cached.bytes);
        for (self.files) |file| file.close(self.io);
        self.allocator.free(self.files);
        self.allocator.free(self.identities);
        self.allocator.free(self.blocks);
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn checkCurrent(self: *const Reader) !void {
        for (self.files, self.identities) |file, before| {
            const after = try file.stat(self.io);
            if (after.inode != before.inode or after.size != before.size or after.kind != before.kind or
                !std.meta.eql(after.mtime, before.mtime) or !std.meta.eql(after.ctime, before.ctime)) return error.Bzip2PartChanged;
        }
    }

    pub fn checkRangeCurrent(self: *const Reader, offset: u64, len: usize) !void {
        if (offset > self.parsed.value.xml_bytes or len > self.parsed.value.xml_bytes - offset) return error.InvalidPageIndex;
        var start: u64 = 0;
        for (self.parsed.value.parts, 0..) |part, pi| {
            const end = start + part.xml_bytes;
            if (offset < end and offset + len > start) try self.checkPartCurrent(pi);
            start = end;
        }
    }

    pub fn bridge(self: *const Reader) ?Bridge {
        return self.parsed.value.zstd_frame_bridge;
    }

    pub fn frameRange(self: *const Reader, stream_id: u32, offset: usize, len: usize) !u64 {
        const b = self.bridge() orelse return error.MissingBzip2Bridge;
        if (stream_id >= b.frames.len) return error.InvalidPageIndex;
        const frame = b.frames[stream_id];
        if (offset > frame[1] or len > frame[1] - offset) return error.InvalidPageIndex;
        return try std.math.add(u64, frame[0], offset);
    }

    pub fn readAlloc(self: *Reader, allocator: std.mem.Allocator, offset: u64, len: usize) ![]u8 {
        if (offset > self.parsed.value.xml_bytes or len > self.parsed.value.xml_bytes - offset) return error.InvalidPageIndex;
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        if (len == 0) return out;
        // Binary search the final block whose start is at or before the range.
        var lo: usize = 0;
        var hi = self.blocks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.blocks[mid].raw_start <= offset) lo = mid + 1 else hi = mid;
        }
        var index = lo -| 1;
        var written: usize = 0;
        while (written < len and index < self.blocks.len) : (index += 1) {
            const block = self.blocks[index];
            if (offset + written < block.raw_start or offset + written >= block.raw_start + block.row[2]) continue;
            try self.checkPartCurrent(block.part);
            const raw = try self.cachedBlock(index);
            try self.checkPartCurrent(block.part);
            const start: usize = @intCast(offset + written - block.raw_start);
            const count = @min(len - written, raw.len - start);
            @memcpy(out[written..][0..count], raw[start..][0..count]);
            written += count;
        }
        if (written != len) return error.TruncatedDump;
        return out;
    }

    fn checkPartCurrent(self: *const Reader, part: usize) !void {
        const before = self.identities[part];
        const after = try self.files[part].stat(self.io);
        if (after.inode != before.inode or after.size != before.size or after.kind != before.kind or
            !std.meta.eql(after.mtime, before.mtime) or !std.meta.eql(after.ctime, before.ctime)) return error.Bzip2PartChanged;
    }

    fn cachedBlock(self: *Reader, index: usize) ![]const u8 {
        self.clock +%= 1;
        if (self.clock == 0) {
            for (&self.cache) |*entry| if (entry.*) |*cached| {
                cached.stamp = 0;
            };
            self.clock = 1;
        }
        for (&self.cache) |*entry| if (entry.*) |*cached| {
            if (cached.index == index) {
                cached.stamp = self.clock;
                return cached.bytes;
            }
        };
        const needed: usize = @intCast(self.blocks[index].row[2]);
        while (self.cache_bytes > max_raw_block - needed or (self.cache[0] != null and self.cache[1] != null)) {
            const victim: usize = if (self.cache[0] == null) 1 else if (self.cache[1] == null) 0 else if (self.cache[0].?.stamp <= self.cache[1].?.stamp) 0 else 1;
            const old = self.cache[victim].?;
            self.cache_bytes -= old.bytes.len;
            self.cache_allocator.free(old.bytes);
            self.cache[victim] = null;
        }
        const raw = try self.decodeBlock(self.blocks[index]);
        const slot: usize = if (self.cache[0] == null) 0 else 1;
        self.cache[slot] = .{ .index = index, .bytes = raw, .stamp = self.clock };
        self.cache_bytes += raw.len;
        self.decoded_block_count += 1;
        return raw;
    }

    fn decodeBlock(self: *Reader, block: Block) ![]u8 {
        const row = block.row;
        const first_byte = row[0] / 8;
        const shift: usize = @intCast(row[0] % 8);
        const input_len: usize = @intCast((shift + row[1] + 7) / 8);
        const input = try self.cache_allocator.alloc(u8, input_len);
        defer self.cache_allocator.free(input);
        const file = &self.files[block.part];
        if ((try file.stat(self.io)).size != self.parsed.value.parts[block.part].size or try file.readPositionalAll(self.io, input, first_byte) != input.len) return error.Bzip2PartChanged;
        const bit_len: usize = @intCast(row[1]);
        const member = try self.cache_allocator.alloc(u8, 4 + (bit_len + 80 + 7) / 8);
        defer self.cache_allocator.free(member);
        @memset(member, 0);
        @memcpy(member[0..3], "BZh");
        member[3] = '0' + @as(u8, @intCast(row[3]));
        for (0..bit_len / 8) |i| {
            member[4 + i] = if (shift == 0) input[i] else (input[i] << @as(u3, @intCast(shift))) | (input[i + 1] >> @as(u3, @intCast(8 - shift)));
        }
        for (bit_len / 8 * 8..bit_len) |i| setBit(member[4..], i, getBit(input, shift + i));
        const marker = [_]u8{ 0x31, 0x41, 0x59, 0x26, 0x53, 0x59 };
        if (!std.mem.eql(u8, member[4..10], &marker)) return error.InvalidBzip2Block;
        const end = [_]u8{ 0x17, 0x72, 0x45, 0x38, 0x50, 0x90 };
        for (0..48) |i| setBit(member[4..], bit_len + i, getBit(&end, i));
        for (0..32) |i| setBit(member[4..], bit_len + 48 + i, getBit(member[4..], 48 + i));
        const raw = try self.cache_allocator.alloc(u8, @intCast(row[2]));
        errdefer self.cache_allocator.free(raw);
        var raw_len: c_uint = @intCast(raw.len);
        if (BZ2_bzBuffToBuffDecompress(raw.ptr, &raw_len, member.ptr, @intCast(member.len), 0, 0) != 0 or raw_len != row[2]) return error.InvalidBzip2Block;
        return raw;
    }
};

fn getBit(bytes: []const u8, at: usize) u1 {
    return @truncate(bytes[at / 8] >> @as(u3, @intCast(7 - at % 8)));
}
fn setBit(bytes: []u8, at: usize, bit: u1) void {
    bytes[at / 8] |= @as(u8, bit) << @as(u3, @intCast(7 - at % 8));
}
