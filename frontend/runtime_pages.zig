//! Supply real auxiliary/current-dictionary source to mw.title and #ifexist.
//! Never turn unavailable data into fabricated page content or an empty definition.
const std = @import("std");
const enc = @import("blob_encoder");
const files = @import("blob_files");
const bridge = @import("runtime_bridge");
const store = @import("store.zig");
const model = @import("model.zig");
const A = std.mem.Allocator;
pub const Provider = struct {
    io: std.Io,
    a: A,
    runtime: *bridge.Runtime,
    root: []const u8,
    dictionary_root: ?[]const u8,
    language: []const u8,
    pages: ?PageFile = null,
    symbols: files.SymbolSource,
    pub fn init(io: std.Io, a: A, runtime: *bridge.Runtime, root: []const u8, dictionary_root: ?[]const u8, language: []const u8) !Provider {
        var self: Provider = .{ .io = io, .a = a, .runtime = runtime, .root = root, .dictionary_root = dictionary_root, .language = language, .symbols = .{ .io = io, .a = a, .root = root } };
        errdefer self.deinit();
        for ([_][]const u8{ "pages.wikblb", "pages.source.wikblb" }) |name| {
            const path = try std.fs.path.join(a, &.{ root, name });
            defer a.free(path);
            var file = PageFile.open(io, a, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            errdefer file.deinit();

            self.pages = file;
            break;
        }
        return self;
    }
    pub fn deinit(self: *Provider) void {
        if (self.pages) |*p| p.deinit();
        self.symbols.deinit();
    }
    pub fn attach(self: *Provider) void {
        self.runtime.setPageContentProvider(.{ .ctx = self, .get = get, .exists = exists });
    }
    fn languageRecord(self: *Provider, a: A, title: []const u8, language: []const u8, content: bool) !?[]const u8 {
        const root = self.dictionary_root orelse return null;
        var db = store.Store.open(self.io, self.a, root, .language, language, false) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer db.deinit();
        const raw = (try db.index.find(title)) orelse return null;
        if (!content) return "";
        var resolved = try db.resolveAlloc(self.a, raw);
        defer resolved.deinit();
        return try model.sourceAlloc(a, resolved.record);
    }
    fn lookup(self: *Provider, a: A, raw_title: []const u8, content: bool) !?[]const u8 {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        const title = try a.dupe(u8, raw_title);
        std.mem.replaceScalar(u8, title, '_', ' ');
        if (self.pages) |*file| if (file.records.get(title)) |r| {
            if (!content) return "";
            const payload = try a.alloc(u8, r.length);
            errdefer a.free(payload);
            if (try file.handle.readPositionalAll(self.io, payload, r.offset) != payload.len) return error.TruncatedSourcePage;
            const decoded = try self.symbols.bindAlloc(a, payload, file.symbolic, file.binding_id);
            if (decoded) |bound| {
                a.free(payload);
                return bound;
            }
            return payload;
        };
        if (self.runtime.templates.get(title)) |slot| {
            if (!content) return "";
            if (slot.body) |body| return try a.dupe(u8, body);
            if (self.runtime.templates_dir) |dir| return try std.Io.Dir.cwd().readFileAlloc(self.io, try std.fmt.allocPrint(a, "{s}/{d}.wiki", .{ dir, slot.page_id }), a, .limited(16 * 1024 * 1024));
        }
        if (self.runtime.modules.get(title)) |slot| {
            if (!content) return "";
            if (slot.page_id == 0) return error.ModuleSourceUnavailable;
            return try std.Io.Dir.cwd().readFileAlloc(self.io, try std.fmt.allocPrint(a, "{s}/{d}.lua", .{ self.runtime.modules_dir, slot.page_id }), a, .limited(16 * 1024 * 1024));
        }
        // These source namespaces were exhaustively extracted; tracking pages
        // must not trigger a scan of every lexical language on a miss.
        if (std.mem.startsWith(u8, title, "Appendix:") or std.mem.startsWith(u8, title, "Wiktionary:") or std.mem.startsWith(u8, title, "MediaWiki:")) return null;
        if (self.dictionary_root) |root| {
            if (try self.languageRecord(a, title, self.language, content)) |body| return body;
            // Existence spans dictionary languages, not just the current spelling's language.
            const path = try std.fs.path.join(self.a, &.{ root, enc.blob_catalog.manifest_filename });
            defer self.a.free(path);
            const catalog = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(16 * 1024 * 1024));
            defer self.a.free(catalog);
            var it = try enc.blob_catalog.Iterator.init(catalog);
            while (try it.next()) |item| {
                if (std.mem.eql(u8, item.heading, self.language)) continue;
                if (try self.languageRecord(a, title, item.heading, content)) |body| return body;
            }
            return null;
        }
        // Known namespaces are completely captured by the runtime-page extractor.
        if (std.mem.startsWith(u8, title, "Appendix:") or std.mem.startsWith(u8, title, "Wiktionary:") or std.mem.startsWith(u8, title, "MediaWiki:")) return null;
        self.runtime.last_not_implemented = try self.runtime.allocator.dupe(u8, title);
        return error.PageContentUnavailable;
    }
    fn get(ctx: *anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.lookup(a, title, true);
    }
    fn exists(ctx: *anyopaque, a: A, title: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return (try self.lookup(a, title, false)) != null;
    }
};

/// Derive a small in-memory page directory, then release the large source mapping.
/// Payloads are read only when needed. No offsets/index are serialized.
const PageFile = struct {
    io: std.Io,
    a: A,
    handle: std.Io.File,
    records: std.StringHashMapUnmanaged(struct { offset: u64, length: usize }) = .empty,
    symbolic: bool,
    binding_id: [32]u8,
    fn open(io: std.Io, a: A, path: []const u8) !PageFile {
        var input = try files.File.open(io, a, path);
        defer input.deinit();
        if (input.index.blob.kind != .pages) return error.InvalidSourcePages;
        var file: PageFile = .{ .io = io, .a = a, .handle = try std.Io.Dir.cwd().openFile(io, path, .{}), .symbolic = input.index.blob.symbolic, .binding_id = input.index.blob.binding_id };
        errdefer file.deinit();
        var it = input.index.blob.iterator();
        while (try it.next()) |record| {
            const title = try a.dupe(u8, record.title);
            errdefer a.free(title);
            const slot = try file.records.getOrPut(a, title);
            if (slot.found_existing) return error.DuplicatePage;
            slot.value_ptr.* = .{ .offset = @intFromPtr(record.payload.ptr) - @intFromPtr(input.bytes.ptr), .length = record.payload.len };
        }
        return file;
    }
    fn deinit(self: *PageFile) void {
        var it = self.records.keyIterator();
        while (it.next()) |key| self.a.free(key.*);
        self.records.deinit(self.a);
        self.handle.close(self.io);
    }
};
