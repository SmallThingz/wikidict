//! Native file ownership and lazy companion resolution. Portable codecs have no I/O.
const std = @import("std");
const enc = @import("blob_encoder");
const parts = enc.language_parts;
const format = enc.blob_format;
pub const File = struct {
    a: std.mem.Allocator,
    bytes: []align(std.heap.page_size_min) const u8,
    index: format.IndexedBlobView,
    pub fn open(io: std.Io, a: std.mem.Allocator, path: []const u8) !File {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const len = std.math.cast(usize, (try file.stat(io)).size) orelse return error.FileTooBig;
        if (len == 0) return error.InvalidBlob;
        const bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(bytes);
        const view = try format.openTrusted(bytes);
        const index = try view.buildIndexAlloc(a);
        return .{ .a = a, .bytes = bytes, .index = index };
    }
    pub fn deinit(self: *File) void {
        self.index.deinit(self.a);
        std.posix.munmap(self.bytes);
        self.* = undefined;
    }
};
pub const Resolver = struct {
    io: std.Io,
    a: std.mem.Allocator,
    root: []const u8,
    metadata: format.LanguageMetadata,
    files: [parts.count]?File = @splat(null),
    attempted: [parts.count]bool = @splat(false),
    used: [parts.count]usize = @splat(0),
    pub fn deinit(self: *Resolver) void {
        for (&self.files) |*file| if (file.*) |*f| f.deinit();
    }
    fn load(self: *Resolver, i: usize) !?*File {
        if (!self.attempted[i]) {
            const family: parts.Kind = @enumFromInt(i + 1);
            const path = try enc.blob_catalog.supplementPathAlloc(self.a, self.root, self.metadata.heading, family);
            defer self.a.free(path);
            var f = File.open(self.io, self.a, path) catch |err| switch (err) {
                error.FileNotFound => {
                    self.attempted[i] = true;
                    return null;
                },
                else => return err,
            };
            errdefer f.deinit();
            const view = f.index.blob;
            if (view.kind != .supplement or try view.supplementKind() != family) return error.InvalidSupplement;
            const meta = try view.languageMetadata();
            if (!std.mem.eql(u8, meta.heading, self.metadata.heading) or !std.mem.eql(u8, meta.code, self.metadata.code)) return error.InvalidSupplement;
            self.files[i] = f;
            self.attempted[i] = true;
        }
        return if (self.files[i]) |*f| f else null;
    }
    /// Null means payload is already complete and may remain borrowed.
    pub fn resolveAlloc(self: *Resolver, a: std.mem.Allocator, title: []const u8, payload: []const u8) !?[]u8 {
        const context: enc.language_blob_encoding.LanguageContext = .{ .heading = self.metadata.heading, .code = self.metadata.code };
        const required = try parts.required(payload, context);
        var bodies: parts.Bodies = @splat(null);
        var any = false;
        for (required, 0..) |needed, i| if (needed) {
            any = true;
            const f = (try self.load(i)) orelse return error.MissingSupplement;
            const body = (try f.index.find(title)) orelse return error.MissingSupplementRecord;
            bodies[i] = body.payload;
            self.used[i] += 1;
        };
        if (!any) return null;
        return try parts.joinAlloc(a, payload, context, bodies);
    }
    /// For the corpus verifier, which visits each core title once.
    pub fn verifyCounts(self: *Resolver) !void {
        for (0..parts.count) |i| {
            const file = try self.load(i);
            const count = if (file) |f| f.index.recordCount() else 0;
            if (count != self.used[i]) return error.OrphanSupplementRecord;
        }
    }
};
