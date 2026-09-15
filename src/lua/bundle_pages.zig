//! Raw page/template/module source provider for the build-only LLVM bundle worker.
const std = @import("std");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;

const ManifestRow = struct {
    page_id: u64,
    title: []const u8,
};
const TemplateSlot = struct { page_id: u64, redirect: ?[]const u8 = null };

pub const Provider = struct {
    io: std.Io,
    a: A,
    root: []const u8,
    pages: std.StringHashMapUnmanaged(u64) = .empty,
    existence: std.StringHashMapUnmanaged(bool) = .empty,
    templates: std.StringHashMapUnmanaged(TemplateSlot) = .empty,
    modules: std.StringHashMapUnmanaged(u64) = .empty,
    modules_loaded: bool = false,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,

    pub fn init(io: std.Io, a: A, root: []const u8) !Provider {
        var self: Provider = .{ .io = io, .a = a, .root = root };
        errdefer self.deinit();
        try self.loadPageManifest();
        try self.loadTemplateManifest();
        try self.loadInterwikiMap();
        return self;
    }

    pub fn deinit(self: *Provider) void {
        freeStringMapKeys(u64, self.a, &self.pages);
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
        return .{ .ctx = self, .get = get, .exists = exists, .interwiki_map = interwikiMap };
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

    fn loadPageManifest(self: *Provider) !void {
        const bytes = (try self.readOptional("pages-manifest.jsonl", 64 * 1024 * 1024)) orelse return;
        defer self.a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(ManifestRow, self.a, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const title = try self.a.dupe(u8, parsed.value.title);
            errdefer self.a.free(title);
            const result = try self.pages.getOrPut(self.a, title);
            if (result.found_existing) {
                self.a.free(title);
                return error.DuplicatePage;
            }
            result.key_ptr.* = title;
            result.value_ptr.* = parsed.value.page_id;
        }
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

    fn readSource(self: *Provider, a: A, dir: []const u8, id: u64, suffix: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "{s}/{s}/{d}.{s}", .{ self.root, dir, id, suffix });
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 * 1024 * 1024));
    }

    fn lookup(self: *Provider, a: A, raw_title: []const u8, content: bool) !?[]const u8 {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        const title = try a.dupe(u8, raw_title);
        std.mem.replaceScalar(u8, title, '_', ' ');
        if (self.pages.get(title)) |id| {
            if (!content) return "";
            return try self.readSource(a, "pages", id, "wiki");
        }
        if (self.templates.get(title)) |initial| {
            if (!content) return "";
            var slot = initial;
            var redirects: usize = 0;
            while (slot.redirect) |target| {
                redirects += 1;
                if (redirects > 32) return error.TemplateRedirectLoop;
                slot = self.templates.get(target) orelse return null;
            }
            return try self.readSource(a, "templates", slot.page_id, "wiki");
        }
        if (std.mem.startsWith(u8, title, "Module:")) {
            try self.loadModuleManifest();
            if (self.modules.get(title)) |id| {
                if (!content) return "";
                return try self.readSource(a, "modules", id, "lua");
            }
        }
        if (std.mem.startsWith(u8, title, "Appendix:") or std.mem.startsWith(u8, title, "Wiktionary:") or std.mem.startsWith(u8, title, "MediaWiki:")) return null;
        return null;
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

    var provider = try Provider.init(io, a, root);
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
