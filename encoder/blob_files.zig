//! Native file ownership and lazy companion resolution. Portable codecs have no I/O.
const std = @import("std");
const enc = @import("blob_encoder");
const parts = enc.language_parts;
const storage = @import("blob_storage");
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
pub const SymbolSource = struct {
    io: std.Io,
    a: std.mem.Allocator,
    root: []const u8,
    file: ?storage.File = null,
    keys: []const []const u8 = &.{},
    pub fn deinit(self: *SymbolSource) void {
        self.a.free(self.keys);
        if (self.file) |*file| file.deinit();
        self.file = null;
        self.keys = &.{};
    }
    pub fn load(self: *SymbolSource) !enc.call_symbols.Names {
        if (self.file == null) {
            const path = try std.fs.path.join(self.a, &.{ self.root, enc.call_symbols.filename });
            defer self.a.free(path);
            var file = try storage.File.open(self.io, self.a, path);
            errdefer file.deinit();
            if (file.view.kind != .symbols or !file.view.symbolic) return error.InvalidSymbols;
            const keys = try self.a.alloc([]const u8, file.recordCount());
            errdefer self.a.free(keys);
            for (keys, 0..) |*key, i| {
                const title = try file.titleAt(i);
                if (!enc.call_symbols.validKey(title) or file.directory.rows[i].length != 0) return error.InvalidSymbols;
                key.* = title;
            }
            const names: enc.call_symbols.Names = .{ .keys = keys };
            if (!std.mem.eql(u8, &names.digest(), &file.view.binding_id)) return error.SymbolIdentityMismatch;
            self.file = file;
            self.keys = keys;
        }
        return .{ .keys = self.keys };
    }
    pub fn bindAlloc(self: *SymbolSource, a: std.mem.Allocator, bytes: []const u8, encoded: bool, binding: [32]u8) !?[]u8 {
        if (!encoded or std.mem.indexOfScalar(u8, bytes, enc.call_symbols.marker) == null) return null;
        const names = try self.load();
        if (!std.mem.eql(u8, &self.file.?.view.binding_id, &binding)) return error.SymbolIdentityMismatch;
        return enc.call_symbols.decodeAlloc(a, bytes, names);
    }
};

pub fn requireComplete(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, ".binding-incomplete" });
    defer a.free(path);
    var marker = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    marker.close(io);
    return error.BlobBindingIncomplete;
}

pub const Resolver = struct {
    symbols: ?*SymbolSource = null,
    symbolic: bool = false,
    binding_id: [32]u8 = @splat(0),
    io: std.Io,
    a: std.mem.Allocator,
    root: []const u8,
    metadata: format.LanguageMetadata,
    files: [parts.count]?storage.File = @splat(null),
    attempted: [parts.count]bool = @splat(false),
    used: [parts.count]usize = @splat(0),
    pub fn deinit(self: *Resolver) void {
        for (&self.files) |*file| if (file.*) |*f| f.deinit();
    }
    fn load(self: *Resolver, i: usize) !?*storage.File {
        if (!self.attempted[i]) {
            const family: parts.Kind = @enumFromInt(i + 1);
            const path = try enc.blob_catalog.supplementPathAlloc(self.a, self.root, self.metadata.heading, family);
            defer self.a.free(path);
            var f = storage.File.open(self.io, self.a, path) catch |err| switch (err) {
                // A missing optional package can be installed while a reader is open.
                error.FileNotFound => return null,
                else => return err,
            };
            errdefer f.deinit();
            const view = f.view;
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
        const bound = if (self.symbols) |symbols| try symbols.bindAlloc(a, payload, self.symbolic, self.binding_id) else if (self.symbolic and std.mem.indexOfScalar(u8, payload, enc.call_symbols.marker) != null) return error.MissingSymbols else null;
        errdefer if (bound) |b| a.free(b);
        const core = bound orelse payload;
        const required = try parts.required(core, context);
        var owned: [parts.count]?[]u8 = @splat(null);
        defer for (owned) |b| if (b) |bytes| a.free(bytes);
        var bodies: parts.Bodies = @splat(null);
        var any = false;
        for (required, 0..) |needed, i| if (needed) {
            any = true;
            const f = (try self.load(i)) orelse return error.MissingSupplement;
            const record_index = f.find(title) orelse return error.MissingSupplementRecord;
            var body = try f.readAlloc(a, record_index);
            errdefer body.deinit();
            owned[i] = if (self.symbols) |symbols| try symbols.bindAlloc(a, body.payload, f.view.symbolic, f.view.binding_id) else if (f.view.symbolic and std.mem.indexOfScalar(u8, body.payload, enc.call_symbols.marker) != null) return error.MissingSymbols else null;
            bodies[i] = owned[i] orelse body.payload;
            if (owned[i] == null) {
                owned[i] = body.owned;
                body.owned = null;
            } else {
                body.deinit();
                body.owned = null;
            }
            self.used[i] += 1;
        };
        if (!any) return bound;
        const joined = try parts.joinAlloc(a, core, context, bodies);
        if (bound) |b| a.free(b);
        return joined;
    }
    /// For the corpus verifier, which visits each core title once.
    pub fn verifyCounts(self: *Resolver) !void {
        for (0..parts.count) |i| {
            const file = try self.load(i);
            const count = if (file) |f| f.recordCount() else 0;
            if (count != self.used[i]) return error.OrphanSupplementRecord;
        }
    }
};
