//! Seekable XZ transport. The dictionary wire format remains uncompressed.
//! XZ's own stream indexes locate independently decodable blocks after compression.
const std = @import("std");
const c = @cImport({
    @cInclude("lzma.h");
});
const A = std.mem.Allocator;
const Api = struct {
    lib: std.DynLib,
    code: *const @TypeOf(c.lzma_code),
    end: *const @TypeOf(c.lzma_end),
    info: *const @TypeOf(c.lzma_file_info_decoder),
    index_end: *const @TypeOf(c.lzma_index_end),
    size: *const @TypeOf(c.lzma_index_uncompressed_size),
    iter_init: *const @TypeOf(c.lzma_index_iter_init),
    locate: *const @TypeOf(c.lzma_index_iter_locate),
    block_count: *const @TypeOf(c.lzma_index_block_count),
    stream_count: *const @TypeOf(c.lzma_index_stream_count),
    stream: *const @TypeOf(c.lzma_stream_decoder),
    block: *const @TypeOf(c.lzma_block_decoder),
    header: *const @TypeOf(c.lzma_block_header_decode),
    compressed: *const @TypeOf(c.lzma_block_compressed_size),
    filters_free: *const @TypeOf(c.lzma_filters_free),
    memusage: *const @TypeOf(c.lzma_raw_decoder_memusage),
    fn open() !Api {
        var lib = std.DynLib.open("liblzma.so.5") catch return error.XzLibraryUnavailable;
        errdefer lib.close();
        return .{
            .lib = lib,
            .code = lib.lookup(*const @TypeOf(c.lzma_code), "lzma_code") orelse return error.XzLibraryUnavailable,
            .end = lib.lookup(*const @TypeOf(c.lzma_end), "lzma_end") orelse return error.XzLibraryUnavailable,
            .info = lib.lookup(*const @TypeOf(c.lzma_file_info_decoder), "lzma_file_info_decoder") orelse return error.XzLibraryUnavailable,
            .index_end = lib.lookup(*const @TypeOf(c.lzma_index_end), "lzma_index_end") orelse return error.XzLibraryUnavailable,
            .size = lib.lookup(*const @TypeOf(c.lzma_index_uncompressed_size), "lzma_index_uncompressed_size") orelse return error.XzLibraryUnavailable,
            .iter_init = lib.lookup(*const @TypeOf(c.lzma_index_iter_init), "lzma_index_iter_init") orelse return error.XzLibraryUnavailable,
            .locate = lib.lookup(*const @TypeOf(c.lzma_index_iter_locate), "lzma_index_iter_locate") orelse return error.XzLibraryUnavailable,
            .block_count = lib.lookup(*const @TypeOf(c.lzma_index_block_count), "lzma_index_block_count") orelse return error.XzLibraryUnavailable,
            .stream_count = lib.lookup(*const @TypeOf(c.lzma_index_stream_count), "lzma_index_stream_count") orelse return error.XzLibraryUnavailable,
            .stream = lib.lookup(*const @TypeOf(c.lzma_stream_decoder), "lzma_stream_decoder") orelse return error.XzLibraryUnavailable,
            .block = lib.lookup(*const @TypeOf(c.lzma_block_decoder), "lzma_block_decoder") orelse return error.XzLibraryUnavailable,
            .header = lib.lookup(*const @TypeOf(c.lzma_block_header_decode), "lzma_block_header_decode") orelse return error.XzLibraryUnavailable,
            .compressed = lib.lookup(*const @TypeOf(c.lzma_block_compressed_size), "lzma_block_compressed_size") orelse return error.XzLibraryUnavailable,
            .filters_free = lib.lookup(*const @TypeOf(c.lzma_filters_free), "lzma_filters_free") orelse return error.XzLibraryUnavailable,
            .memusage = lib.lookup(*const @TypeOf(c.lzma_raw_decoder_memusage), "lzma_raw_decoder_memusage") orelse return error.XzLibraryUnavailable,
        };
    }
};
fn check(code: c.lzma_ret) !void {
    switch (code) {
        c.LZMA_OK, c.LZMA_STREAM_END => {},
        c.LZMA_MEM_ERROR => return error.OutOfMemory,
        c.LZMA_MEMLIMIT_ERROR => return error.XzMemoryLimit,
        c.LZMA_OPTIONS_ERROR, c.LZMA_UNSUPPORTED_CHECK => return error.UnsupportedXz,
        else => return error.InvalidXz,
    }
}
pub const Source = struct {
    api: Api,
    bytes: []const u8,
    index: ?*c.lzma_index = null,
    size: u64,
    blocks: u64,
    streams: u64,
    decoded_blocks: u64 = 0,
    decoded_bytes: u64 = 0,
    cache: []u8 = &.{},
    cache_offset: u64 = 0,
    pub fn open(bytes: []const u8) !Source {
        var api = try Api.open();
        errdefer api.lib.close();
        var stream: c.lzma_stream = std.mem.zeroes(c.lzma_stream);
        defer api.end(&stream);
        var index: ?*c.lzma_index = null;
        errdefer if (index) |i| api.index_end(i, null);
        try check(api.info(&stream, &index, 64 * 1024 * 1024, bytes.len));
        stream.next_in = bytes.ptr;
        stream.avail_in = bytes.len;
        while (true) {
            const rc = api.code(&stream, c.LZMA_RUN);
            if (rc == c.LZMA_STREAM_END) break;
            if (rc == c.LZMA_SEEK_NEEDED) {
                const pos = std.math.cast(usize, stream.seek_pos) orelse return error.InvalidXz;
                if (pos > bytes.len) return error.InvalidXz;
                stream.next_in = bytes[pos..].ptr;
                stream.avail_in = bytes.len - pos;
            } else try check(rc);
        }
        const i = index orelse return error.InvalidXz;
        return .{ .api = api, .bytes = bytes, .index = i, .size = api.size(i), .blocks = api.block_count(i), .streams = api.stream_count(i) };
    }
    pub fn deinit(self: *Source, a: A) void {
        a.free(self.cache);
        self.api.index_end(self.index, null);
        self.api.lib.close();
        self.* = undefined;
    }
    /// Initial record directory construction is one bounded-memory pass. The
    /// complete source is never saved as a decompressed cache file.
    pub fn scan(self: *Source, visitor: anytype) !void {
        var stream: c.lzma_stream = std.mem.zeroes(c.lzma_stream);
        defer self.api.end(&stream);
        try check(self.api.stream(&stream, 256 * 1024 * 1024, c.LZMA_CONCATENATED));
        stream.next_in = self.bytes.ptr;
        stream.avail_in = self.bytes.len;
        var buffer: [65536]u8 = undefined;
        while (true) {
            stream.next_out = &buffer;
            stream.avail_out = buffer.len;
            const before = stream.avail_in;
            const rc = self.api.code(&stream, c.LZMA_FINISH);
            try check(rc);
            const n = buffer.len - stream.avail_out;
            try visitor.feed(buffer[0..n]);
            if (rc == c.LZMA_STREAM_END) break;
            if (n == 0 and before == stream.avail_in) return error.InvalidXz;
        }
        if (stream.total_out != self.size) return error.InvalidXz;
    }
    /// Decodes only blocks intersecting the requested uncompressed range. A
    /// single-block XZ cannot become cheaply seekable without recompression.
    pub fn read(self: *Source, a: A, offset: u64, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset) return error.InvalidXzRange;
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            if (self.cache.len != 0 and at >= self.cache_offset and at - self.cache_offset < self.cache.len) {
                const start: usize = @intCast(at - self.cache_offset);
                const n = @min(out.len - done, self.cache.len - start);
                @memcpy(out[done..][0..n], self.cache[start..][0..n]);
                done += n;
                continue;
            }
            var it: c.lzma_index_iter = undefined;
            self.api.iter_init(&it, self.index);
            if (self.api.locate(&it, at) != 0) return error.InvalidXzRange;
            const begin = it.block.uncompressed_file_offset;
            const block_size = it.block.uncompressed_size;
            const n: usize = @intCast(@min(out.len - done, block_size - (at - begin)));
            if (block_size <= 4 * 1024 * 1024) {
                const next = try a.alloc(u8, @intCast(block_size));
                errdefer a.free(next);
                try self.decodeBlock(it, begin, next);
                a.free(self.cache);
                self.cache = next;
                self.cache_offset = begin;
            } else {
                try self.decodeBlock(it, at, out[done..][0..n]);
                done += n;
            }
        }
    }
    fn decodeBlock(self: *Source, it: c.lzma_index_iter, offset: u64, out: []u8) !void {
        const pos = std.math.cast(usize, it.block.compressed_file_offset) orelse return error.InvalidXz;
        const total = std.math.cast(usize, it.block.total_size) orelse return error.InvalidXz;
        if (pos >= self.bytes.len or total > self.bytes.len - pos) return error.InvalidXz;
        const input = self.bytes[pos..][0..total];
        const header_len: u32 = (@as(u32, input[0]) + 1) * 4;
        if (header_len > input.len) return error.InvalidXz;
        var filters: [c.LZMA_FILTERS_MAX + 1]c.lzma_filter = undefined;
        var block: c.lzma_block = std.mem.zeroes(c.lzma_block);
        block.version = 0;
        block.header_size = header_len;
        block.check = it.stream.flags.*.check;
        block.filters = &filters;
        try check(self.api.header(&block, null, input.ptr));
        defer self.api.filters_free(&filters, null);
        try check(self.api.compressed(&block, it.block.unpadded_size));
        block.uncompressed_size = it.block.uncompressed_size;
        if (self.api.memusage(&filters) > 256 * 1024 * 1024) return error.XzMemoryLimit;
        var stream: c.lzma_stream = std.mem.zeroes(c.lzma_stream);
        defer self.api.end(&stream);
        try check(self.api.block(&stream, &block));
        stream.next_in = input[header_len..].ptr;
        stream.avail_in = input.len - header_len;
        var buffer: [65536]u8 = undefined;
        var decoded: u64 = 0;
        const wanted = offset - it.block.uncompressed_file_offset;
        while (true) {
            stream.next_out = &buffer;
            stream.avail_out = buffer.len;
            const before = stream.avail_in;
            const rc = self.api.code(&stream, c.LZMA_FINISH);
            try check(rc);
            const n = buffer.len - stream.avail_out;
            const lo = @max(decoded, wanted);
            const hi = @min(decoded + n, wanted + out.len);
            if (lo < hi) @memcpy(out[@intCast(lo - wanted)..][0..@intCast(hi - lo)], buffer[@intCast(lo - decoded)..][0..@intCast(hi - lo)]);
            decoded += n;
            if (rc == c.LZMA_STREAM_END) break;
            if (n == 0 and before == stream.avail_in) return error.InvalidXz;
        }
        if (decoded != it.block.uncompressed_size or stream.avail_in != 0) return error.InvalidXz;
        self.decoded_blocks += 1;
        self.decoded_bytes += decoded;
    }
};
