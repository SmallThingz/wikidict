//! Page/template source provider for runtime-specific native AOT workers.
const std = @import("std");
const enc = @import("blob_encoder");
const files = @import("blob_files");
const dec = @import("blob_decoder");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;
const storage = @import("blob_storage");

const ManifestRow = struct {
    page_id: u64,
    title: []const u8,
};
const TemplateSlot = struct { page_id: u64, redirect: ?[]const u8 = null };

const LanguageSourceStore = struct {
    io: std.Io,
    a: A,
    file: storage.File,
    resolver: files.Resolver,

    fn open(io: std.Io, a: A, root: []const u8, language: []const u8) !LanguageSourceStore {
        try files.requireComplete(io, a, root);
        var filename: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, enc.blob_catalog.language_directory, enc.blob_catalog.languageBlobFilename(language, &filename) });
        defer a.free(path);
        var file = try storage.File.open(io, a, path);
        errdefer file.deinit();
        if (file.view.kind != .language) return error.UnexpectedBlobKind;
        const metadata = try file.view.languageMetadata();
        if (!std.mem.eql(u8, metadata.heading, language)) return error.UnexpectedLanguageBlob;
        return .{
            .io = io,
            .a = a,
            .file = file,
            .resolver = .{
                .io = io,
                .a = a,
                .root = root,
                .metadata = metadata,
                .symbolic = file.view.symbolic,
                .binding_id = file.view.binding_id,
            },
        };
    }

    fn deinit(self: *LanguageSourceStore) void {
        self.resolver.deinit();
        self.file.deinit();
    }

    fn sourceAlloc(self: *LanguageSourceStore, a: A, symbols: *files.SymbolSource, title: []const u8) !?[]const u8 {
        const record_index = self.file.find(title) orelse return null;
        var raw = try self.file.readAlloc(a, record_index);
        defer raw.deinit();
        const view = try dec.openTrustedBlob(self.file.directory.header);
        const record = view.wrapRecord(.{ .title = raw.title, .payload = raw.payload });
        if (record != .language) return error.UnexpectedBlobKind;
        self.resolver.symbols = symbols;
        const owned = try self.resolver.resolveRuntimeAlloc(a, record.title(), record.language.payload);
        defer if (owned) |bytes| a.free(bytes);
        const payload = owned orelse record.language.payload;
        const decoded = try enc.language_blob_encoding.decodeAlloc(a, payload, .{
            .heading = record.language.metadata.heading,
            .code = record.language.metadata.code,
        });
        return @as(?[]const u8, decoded);
    }
};

pub const Provider = struct {
    io: std.Io,
    a: A,
    root: []const u8,
    dictionary_root: ?[]const u8,
    language: []const u8,
    pages: ?storage.File = null,
    linked_templates: ?storage.File = null,
    symbols: files.SymbolSource,
    primary: ?LanguageSourceStore = null,
    existence: std.StringHashMapUnmanaged(bool) = .empty,
    templates: std.StringHashMapUnmanaged(TemplateSlot) = .empty,
    modules: std.StringHashMapUnmanaged(u64) = .empty,
    modules_loaded: bool = false,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,
    module_symbol_ids: []u32 = &.{},

    pub fn init(io: std.Io, a: A, root: []const u8, dictionary_root: ?[]const u8, language: []const u8) !Provider {
        return initWithSha256(io, a, root, dictionary_root, language, null);
    }

    pub fn initWithSha256(io: std.Io, a: A, root: []const u8, dictionary_root: ?[]const u8, language: []const u8, sha256: ?files.Sha256Fn) !Provider {
        var self: Provider = .{
            .io = io,
            .a = a,
            .root = root,
            .dictionary_root = dictionary_root,
            .language = language,
            .symbols = .{ .io = io, .a = a, .root = root, .sha256 = sha256 },
        };
        errdefer self.deinit();
        for ([_][]const u8{ "pages.wikblb", "pages.source.wikblb" }) |name| {
            const path = try std.fs.path.join(a, &.{ root, name });
            defer a.free(path);
            var file = storage.File.open(io, a, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            errdefer file.deinit();
            self.pages = file;
            break;
        }
        const linked_path = try std.fs.path.join(a, &.{ root, "templates.wikblb" });
        defer a.free(linked_path);
        self.linked_templates = storage.File.open(io, a, linked_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (self.linked_templates) |*file| {
            if (file.view.kind != .templates or !file.view.symbolic) return error.InvalidRuntimeArtifact;
            const binding = try self.symbols.bindingId();
            if (!std.mem.eql(u8, &binding, &file.view.binding_id)) return error.SymbolIdentityMismatch;
        }
        if (self.linked_templates == null) try self.loadTemplateManifest();
        try self.loadInterwikiMap();
        return self;
    }

    pub fn deinit(self: *Provider) void {
        if (self.pages) |*p| p.deinit();
        if (self.linked_templates) |*p| p.deinit();
        self.symbols.deinit();
        self.a.free(self.module_symbol_ids);
        self.module_symbol_ids = &.{};
        if (self.primary) |*db| db.deinit();
        var template_it = self.templates.iterator();
        while (template_it.next()) |entry| {
            self.a.free(entry.key_ptr.*);
            if (entry.value_ptr.redirect) |redirect| self.a.free(redirect);
        }
        self.templates.deinit(self.a);
        freeStringMapKeys(u64, self.a, &self.modules);
        freeStringMapKeys(bool, self.a, &self.existence);
        for (self.interwiki_rows.items) |row| {
            self.a.free((row.prefix));
            self.a.free((row.url));
        }
        self.interwiki_rows.deinit(self.a);
    }

    pub fn api(self: *Provider) lua_program.WikitextProvider {
        return .{ .ctx = self, .get = get, .exists = exists, .interwiki_map = interwikiMap, .resolve_call_symbol = resolveCallSymbol, .get_template_symbol = getTemplateSymbol };
    }

    fn freeStringMapKeys(comptime V: type, a: A, map: *std.StringHashMapUnmanaged(V)) void {
        var keys = map.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        map.deinit(a);
    }

    fn readOptional(self: *Provider, name: []const u8, max: usize) !?[]u8 {
        const path = try std.fs.path.join(self.a, &.{ self.root, name });
        defer self.a.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(max)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    fn unescapeField(self: *Provider, raw: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\' or i + 1 >= raw.len) {
                try out.append(self.a, raw[i]);
                continue;
            }
            i += 1;
            try out.append(self.a, switch (raw[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => raw[i],
            });
        }
        return out.toOwnedSlice(self.a);
    }

    fn loadInterwikiMap(self: *Provider) !void {
        const bytes = (try self.readOptional("interwiki-map.tsv", 16 * 1024 * 1024)) orelse return;
        defer self.a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const prefix_raw = fields.next() orelse continue;
            const local_raw = fields.next() orelse continue;
            const current_raw = fields.next() orelse continue;
            const protocol_raw = fields.next() orelse continue;
            const url_raw = fields.next() orelse continue;
            const prefix = try self.unescapeField(prefix_raw);
            errdefer self.a.free(prefix);
            const url = try self.unescapeField(url_raw);
            errdefer self.a.free(url);
            try self.interwiki_rows.append(self.a, .{
                .prefix = prefix,
                .url = url,
                .is_local = std.mem.eql(u8, local_raw, "1"),
                .is_current_wiki = std.mem.eql(u8, current_raw, "1"),
                .is_protocol_relative = std.mem.eql(u8, protocol_raw, "1"),
            });
        }
    }

    fn normalizeTemplateAlloc(self: *Provider, raw: []const u8) ![]u8 {
        const decoded = try self.unescapeField(raw);
        defer self.a.free(decoded);
        const body = if (std.mem.startsWith(u8, decoded, "Template:")) decoded[9..] else decoded;
        const title = try std.fmt.allocPrint(self.a, "Template:{s}", .{body});
        std.mem.replaceScalar(u8, title, '_', ' ');
        return title;
    }

    fn loadTemplateManifest(self: *Provider) !void {
        const bytes = (try self.readOptional("template-manifest.tsv", 64 * 1024 * 1024)) orelse return;
        defer self.a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields_it = std.mem.splitScalar(u8, line, '\t');
            const id_text = fields_it.next() orelse continue;
            const title_raw = fields_it.next() orelse continue;
            _ = fields_it.next();
            const redirect_raw = fields_it.next() orelse "";
            const id = std.fmt.parseInt(u64, id_text, 10) catch continue;
            const title = try self.normalizeTemplateAlloc(title_raw);
            errdefer self.a.free(title);
            const redirect = if (redirect_raw.len == 0) null else try self.normalizeTemplateAlloc(redirect_raw);
            errdefer if (redirect) |value| self.a.free(value);
            const result = try self.templates.getOrPut(self.a, title);
            if (result.found_existing) {
                self.a.free(title);
                if (result.value_ptr.redirect) |old_redirect| self.a.free(old_redirect);
            } else result.key_ptr.* = title;
            result.value_ptr.* = .{ .page_id = id, .redirect = redirect };
        }
    }

    fn loadModuleManifest(self: *Provider) !void {
        if (self.modules_loaded) return;
        const maybe_bytes = try self.readOptional("manifest.jsonl", 64 * 1024 * 1024);
        if (maybe_bytes == null) {
            self.modules_loaded = true;
            return;
        }
        const bytes = maybe_bytes.?;
        defer self.a.free(bytes);
        var loaded: std.StringHashMapUnmanaged(u64) = .empty;
        errdefer freeStringMapKeys(u64, self.a, &loaded);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(ManifestRow, self.a, line, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const row = parsed.value;
            const title = try self.a.dupe(u8, row.title);
            errdefer self.a.free(title);
            const result = try loaded.getOrPut(self.a, title);
            if (result.found_existing) self.a.free(title) else result.key_ptr.* = title;
            result.value_ptr.* = row.page_id;
        }
        std.debug.assert(self.modules.count() == 0);
        self.modules = loaded;
        self.modules_loaded = true;
    }

    fn languageRecord(self: *Provider, a: A, title: []const u8, language: []const u8, content: bool) !?[]const u8 {
        const root = self.dictionary_root orelse return null;
        if (std.mem.eql(u8, language, self.language)) {
            if (self.primary == null) self.primary = LanguageSourceStore.open(self.io, self.a, root, language) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            return self.fromStore(a, &self.primary.?, title, content);
        }
        var db = LanguageSourceStore.open(self.io, self.a, root, language) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer db.deinit();
        return self.fromStore(a, &db, title, content);
    }

    fn fromStore(self: *Provider, a: A, db: *LanguageSourceStore, title: []const u8, content: bool) !?[]const u8 {
        if (db.file.find(title) == null) return null;
        if (!content) return "";
        return db.sourceAlloc(a, &self.symbols, title);
    }

    fn linkedTemplateId(self: *Provider, a: A, start_id: usize) !?[]const u8 {
        var file = if (self.linked_templates) |*value| value else return null;
        var id = start_id;
        var depth: usize = 0;
        while (true) {
            var key: [16]u8 = undefined;
            const key_text = try std.fmt.bufPrint(&key, "{x:0>16}", .{id});
            const record_index = file.find(key_text) orelse return null;
            var record = try file.readAlloc(a, record_index);
            defer record.deinit();
            var pos: usize = 0;
            const redirect_id = try enc.blob_format.readPayloadLength(record.payload, &pos);
            if (redirect_id != 0) {
                depth += 1;
                if (depth > 32) return error.TemplateRedirectLoop;
                id = redirect_id;
                continue;
            }
            return (try self.symbols.bindRuntimeAlloc(a, record.payload[pos..], true, file.view.binding_id)) orelse try a.dupe(u8, record.payload[pos..]);
        }
    }

    fn linkedTemplate(self: *Provider, a: A, title: []const u8) !?[]const u8 {
        if (!std.ascii.startsWithIgnoreCase(title, "Template:")) return null;
        const names = try self.symbols.load();
        const id = names.find(.template, title[9..]) orelse return null;
        return self.linkedTemplateId(a, id);
    }

    fn readRuntimeSource(self: *Provider, a: A, dir: []const u8, id: u64, suffix: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "{s}/{s}/{d}.{s}", .{ self.root, dir, id, suffix });
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 * 1024 * 1024));
    }

    fn lookup(self: *Provider, a: A, raw_title: []const u8, content: bool) !?[]const u8 {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        const title = try a.dupe(u8, raw_title);
        std.mem.replaceScalar(u8, title, '_', ' ');
        if (self.pages) |*file| if (file.find(title)) |record_index| {
            if (!content) return "";
            var r = try file.readAlloc(a, record_index);
            defer r.deinit();
            const decoded = try self.symbols.bindRuntimeAlloc(a, r.payload, file.view.symbolic, file.view.binding_id);
            return decoded orelse try a.dupe(u8, r.payload);
        };
        if (try self.linkedTemplate(a, title)) |body| return if (content) body else "";
        if (self.templates.get(title)) |initial| {
            if (!content) return "";
            var slot = initial;
            var redirects: usize = 0;
            while (slot.redirect) |target| {
                redirects += 1;
                if (redirects > 32) return error.TemplateRedirectLoop;
                slot = self.templates.get(target) orelse return null;
            }
            return try self.readRuntimeSource(a, "templates", slot.page_id, "wiki");
        }
        if (std.mem.startsWith(u8, title, "Module:")) {
            try self.loadModuleManifest();
            if (self.modules.get(title)) |id| {
                if (!content) return "";
                return try self.readRuntimeSource(a, "modules", id, "lua");
            }
        }
        if (std.mem.startsWith(u8, title, "Appendix:") or std.mem.startsWith(u8, title, "Wiktionary:") or std.mem.startsWith(u8, title, "MediaWiki:")) return null;
        if (self.dictionary_root) |root| {
            if (try self.languageRecord(a, title, self.language, content)) |body| return body;
            const path = try std.fs.path.join(self.a, &.{ root, enc.blob_catalog.manifest_filename });
            defer self.a.free(path);
            const catalog = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(16 * 1024 * 1024));
            defer self.a.free(catalog);
            var it = try enc.blob_catalog.Iterator.init(catalog);
            while (try it.next()) |item| {
                if (std.mem.eql(u8, item.heading, self.language)) continue;
                if (try self.languageRecord(a, title, item.heading, content)) |body| return body;
            }
        }
        return null;
    }

    fn moduleIdForSymbol(self: *Provider, runtime: *lua_program.Context, names: enc.call_symbols.Names, id: usize, text: []const u8) !?u32 {
        const unresolved = std.math.maxInt(u32);
        const missing = unresolved - 1;
        if (self.module_symbol_ids.len == 0) {
            self.module_symbol_ids = try self.a.alloc(u32, names.keys.len + 1);
            @memset(self.module_symbol_ids, unresolved);
        }
        if (id >= self.module_symbol_ids.len) return error.InvalidSymbol;
        const cached = self.module_symbol_ids[id];
        if (cached != unresolved) return if (cached == missing) null else cached;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var full_buffer: [4096]u8 = undefined;
        const full = if (trimmed.len >= 7 and std.ascii.eqlIgnoreCase(trimmed[0..7], "Module:")) blk: {
            if (trimmed.len > full_buffer.len) return error.ModuleNameTooLong;
            @memcpy(full_buffer[0..trimmed.len], trimmed);
            break :blk full_buffer[0..trimmed.len];
        } else std.fmt.bufPrint(&full_buffer, "Module:{s}", .{trimmed}) catch return error.ModuleNameTooLong;
        std.mem.replaceScalar(u8, full, '_', ' ');
        const module_id = runtime.resolveModule(full) catch |err| switch (err) {
            error.ModuleNotFound => null,
            else => return err,
        };
        self.module_symbol_ids[id] = module_id orelse missing;
        return module_id;
    }

    fn getTemplateSymbol(ctx: ?*anyopaque, a: std.mem.Allocator, id: usize) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.linkedTemplateId(a, id);
    }

    fn resolveCallSymbol(
        ctx: ?*anyopaque,
        runtime: *lua_program.Context,
        raw: []const u8,
        kind: lua_program.WikitextProvider.SymbolKind,
    ) anyerror!?lua_program.WikitextProvider.Symbol {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const names = try self.symbols.load();
        const expected: enc.call_symbols.Kind = switch (kind) {
            .template => .template,
            .module => .module,
            .function => .function,
        };
        const id = (try enc.call_symbols.preservedId(raw, names, expected)) orelse return null;
        const text = try names.get(id);
        const module_id = if (kind == .module) try self.moduleIdForSymbol(runtime, names, id, text) else null;
        return .{ .id = id, .text = text, .module_id = module_id };
    }

    fn interwikiMap(ctx: ?*anyopaque) anyerror![]const InterwikiRow {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.interwiki_rows.items;
    }

    fn get(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.lookup(a, title, true);
    }

    fn exists(ctx: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        if (self.existence.get(title)) |known| return known;
        const result = (try self.lookup(self.a, title, false)) != null;
        const owned = try self.a.dupe(u8, title);
        errdefer self.a.free(owned);
        try self.existence.put(self.a, owned, result);
        return result;
    }
};

test "module manifest stays lazy until a Module page lookup" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const manifest_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" });
    defer a.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = "{\"page_id\":42,\"title\":\"Module:Lazy\"}\n",
    });
    const modules_path = try std.fs.path.join(a, &.{ root, "modules" });
    defer a.free(modules_path);
    try std.Io.Dir.cwd().createDir(io, modules_path, .default_dir);
    const source_path = try std.fs.path.join(a, &.{ modules_path, "42.lua" });
    defer a.free(source_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "return 42" });

    var provider = try Provider.init(io, a, root, null, "English");
    defer provider.deinit();
    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    const page_a = page_arena.allocator();
    try std.testing.expect(!provider.modules_loaded);
    try std.testing.expectEqual(@as(usize, 0), provider.modules.count());
    try std.testing.expect((try provider.lookup(page_a, "Ordinary page", false)) == null);
    try std.testing.expect(!provider.modules_loaded);
    try std.testing.expectEqual(@as(usize, 0), provider.modules.count());
    const exists = (try provider.lookup(page_a, "Module:Lazy", false)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("", exists);
    try std.testing.expect(provider.modules_loaded);
    try std.testing.expectEqual(@as(usize, 1), provider.modules.count());
    const content = (try provider.lookup(page_a, "Module:Lazy", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("return 42", content);
}
