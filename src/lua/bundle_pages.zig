//! Raw page/template/module source provider for the build-only LLVM bundle worker.
const std = @import("std");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const xml_decode = @import("shared_xml_decode");
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;

const TemplateSlot = struct { page_id: u64, redirect: ?[]const u8 = null };
const CorpusPage = struct { offset: u64, len: usize };

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

pub const Provider = struct {
    io: std.Io,
    a: A,
    root: []const u8,
    corpus_pages: std.StringHashMapUnmanaged(CorpusPage) = .empty,
    corpus_pages_storage: ?Mapped = null,
    dump_file: ?std.Io.File = null,
    templates: std.StringHashMapUnmanaged(TemplateSlot) = .empty,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,

    pub fn init(io: std.Io, a: A, root: []const u8, dump_path: []const u8) !Provider {
        const owned_root = try a.dupe(u8, root);
        var self: Provider = .{ .io = io, .a = a, .root = owned_root };
        errdefer self.deinit();
        try self.loadCorpusPages(dump_path);
        try self.loadTemplateManifest();
        try self.loadInterwikiMap();
        return self;
    }

    pub fn deinit(self: *Provider) void {
        self.corpus_pages.deinit(self.a);
        if (self.corpus_pages_storage) |*mapped| mapped.deinit();
        if (self.dump_file) |*file| file.close(self.io);
        var template_it = self.templates.iterator();
        while (template_it.next()) |entry| {
            self.a.free(entry.key_ptr.*);
            if (entry.value_ptr.redirect) |redirect| self.a.free(redirect);
        }
        self.templates.deinit(self.a);
        for (self.interwiki_rows.items) |row| {
            self.a.free((row.prefix));
            self.a.free((row.url));
        }
        self.interwiki_rows.deinit(self.a);
        self.a.free(self.root);
        self.root = "";
    }

    pub fn api(self: *Provider) lua_program.WikitextProvider {
        return .{ .ctx = self, .get = get, .get_template = getTemplate, .exists = exists, .interwiki_map = interwikiMap };
    }

    fn mapOptional(self: *Provider, name: []const u8) !?Mapped {
        const path = try std.fs.path.join(self.a, &.{ self.root, name });
        defer self.a.free(path);
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(self.io);
        const len = std.math.cast(usize, (try file.stat(self.io)).size) orelse return error.FileTooBig;
        if (len == 0) return .{ .bytes = &.{} };
        return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
    }

    fn unescapeFieldAlloc(a: A, raw: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\' or i + 1 >= raw.len) {
                try out.append(a, raw[i]);
                continue;
            }
            i += 1;
            try out.append(a, switch (raw[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => raw[i],
            });
        }
        return out.toOwnedSlice(a);
    }

    fn loadInterwikiMap(self: *Provider) !void {
        var mapped = (try self.mapOptional("interwiki-map.tsv")) orelse return;
        defer mapped.deinit();
        try self.interwiki_rows.ensureTotalCapacity(self.a, std.mem.count(u8, mapped.bytes, "\n"));
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const prefix_raw = fields.next() orelse continue;
            const local_raw = fields.next() orelse continue;
            const current_raw = fields.next() orelse continue;
            const protocol_raw = fields.next() orelse continue;
            const url_raw = fields.next() orelse continue;
            const prefix = try unescapeFieldAlloc(self.a, prefix_raw);
            errdefer self.a.free(prefix);
            const url = try unescapeFieldAlloc(self.a, url_raw);
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

    fn normalizeTemplateAlloc(self: *Provider, scratch: A, raw: []const u8) ![]u8 {
        const decoded = try unescapeFieldAlloc(scratch, raw);
        const body = if (std.mem.startsWith(u8, decoded, "Template:")) decoded[9..] else decoded;
        const title = try std.fmt.allocPrint(self.a, "Template:{s}", .{body});
        std.mem.replaceScalar(u8, title, '_', ' ');
        return title;
    }

    fn loadCorpusPages(self: *Provider, dump_path: []const u8) !void {
        var mapped = (try self.mapOptional("page-index.tsv")) orelse return;
        errdefer mapped.deinit();
        var file = try std.Io.Dir.cwd().openFile(self.io, dump_path, .{});
        errdefer file.close(self.io);
        const dump_size = (try file.stat(self.io)).size;
        var pages: std.StringHashMapUnmanaged(CorpusPage) = .empty;
        errdefer pages.deinit(self.a);
        try pages.ensureTotalCapacity(self.a, @intCast(std.mem.count(u8, mapped.bytes, "\n")));
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const offset = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
            const len = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10);
            const title = fields.next() orelse return error.InvalidPageIndex;
            if (title.len == 0 or fields.next() != null) return error.InvalidPageIndex;
            const end = std.math.add(u64, offset, len) catch return error.InvalidPageIndex;
            if (end > dump_size) return error.InvalidPageIndex;
            const result = try pages.getOrPut(self.a, title);
            if (result.found_existing) return error.DuplicatePage;
            result.key_ptr.* = title;
            result.value_ptr.* = .{ .offset = offset, .len = len };
        }
        self.corpus_pages = pages;
        self.corpus_pages_storage = mapped;
        self.dump_file = file;
    }

    fn readCorpusSource(self: *Provider, a: A, page: CorpusPage) ![]const u8 {
        if (page.len == 0) return a.dupe(u8, "");
        const file = if (self.dump_file) |*value| value else return error.MissingDump;
        const raw = try a.alloc(u8, page.len);
        defer a.free(raw);
        if (try file.readPositionalAll(self.io, raw, page.offset) != raw.len) return error.TruncatedDump;
        return xml_decode.decodeSinglePassAlloc(a, raw);
    }

    fn loadTemplateManifest(self: *Provider) !void {
        var mapped = (try self.mapOptional("template-manifest.tsv")) orelse return;
        defer mapped.deinit();
        try self.templates.ensureTotalCapacity(self.a, @intCast(std.mem.count(u8, mapped.bytes, "\n")));
        var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer scratch.deinit();
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields_it = std.mem.splitScalar(u8, line, '\t');
            const id_text = fields_it.next() orelse continue;
            const title_raw = fields_it.next() orelse continue;
            _ = fields_it.next();
            const redirect_raw = fields_it.next() orelse "";
            const id = std.fmt.parseInt(u64, id_text, 10) catch continue;
            const title = try self.normalizeTemplateAlloc(scratch.allocator(), title_raw);
            errdefer self.a.free(title);
            const redirect = if (redirect_raw.len == 0) null else try self.normalizeTemplateAlloc(scratch.allocator(), redirect_raw);
            errdefer if (redirect) |value| self.a.free(value);
            const result = try self.templates.getOrPut(self.a, title);
            if (result.found_existing) {
                self.a.free(title);
                if (result.value_ptr.redirect) |old_redirect| self.a.free(old_redirect);
            } else result.key_ptr.* = title;
            result.value_ptr.* = .{ .page_id = id, .redirect = redirect };
            _ = scratch.reset(.retain_capacity);
        }
    }

    fn readSource(self: *Provider, a: A, dir: []const u8, id: u64, suffix: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "{s}/{s}/{d}.{s}", .{ self.root, dir, id, suffix });
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 * 1024 * 1024));
    }

    fn lookup(self: *Provider, a: A, raw_title: []const u8, content: bool) !?[]const u8 {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        var title_buffer: [4096]u8 = undefined;
        const title: []const u8 = if (std.mem.indexOfScalar(u8, raw_title, '_') != null) blk: {
            @memcpy(title_buffer[0..raw_title.len], raw_title);
            std.mem.replaceScalar(u8, title_buffer[0..raw_title.len], '_', ' ');
            break :blk title_buffer[0..raw_title.len];
        } else raw_title;
        if (self.corpus_pages.get(title)) |page| return if (content) try self.readCorpusSource(a, page) else "";
        return null;
    }

    fn templateSource(self: *Provider, a: A, title: []const u8) !?[]const u8 {
        const initial = self.templates.get(title) orelse return null;
        var slot = initial;
        var redirects: usize = 0;
        while (slot.redirect) |target| {
            redirects += 1;
            if (redirects > 32) return error.TemplateRedirectLoop;
            slot = self.templates.get(target) orelse return null;
        }
        return try self.readSource(a, "templates", slot.page_id, "wiki");
    }

    fn getTemplate(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.templateSource(a, title);
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
        return (try self.lookup(self.a, title, false)) != null;
    }
};

test "provider owns paths and serves corpus ranges without query-history state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const dump_path = try std.fs.path.join(a, &.{ root, "dump.xml" });
    defer a.free(dump_path);
    const prefix = "prefix";
    const ordinary_raw = "A&amp;B";
    const alias_raw = "#REDIRECT [[Template:Lazy]]";
    const dump_bytes = prefix ++ ordinary_raw ++ alias_raw;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });
    const page_index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(page_index_path);
    const page_index = try std.fmt.allocPrint(
        a,
        "{d}\t{d}\tOrdinary page\n{d}\t{d}\tTemplate:Alias\n",
        .{ prefix.len, ordinary_raw.len, prefix.len + ordinary_raw.len, alias_raw.len },
    );
    defer a.free(page_index);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = page_index_path, .data = page_index });
    const template_manifest_path = try std.fs.path.join(a, &.{ root, "template-manifest.tsv" });
    defer a.free(template_manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = template_manifest_path,
        .data = "42\tTemplate:Lazy\t9\t\n43\tTemplate:Alias\t27\tTemplate:Lazy\n",
    });
    const templates_path = try std.fs.path.join(a, &.{ root, "templates" });
    defer a.free(templates_path);
    try std.Io.Dir.cwd().createDir(io, templates_path, .default_dir);
    const source_path = try std.fs.path.join(a, &.{ templates_path, "42.wiki" });
    defer a.free(source_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "lazy body" });

    const caller_root = try a.dupe(u8, root);
    defer a.free(caller_root);
    var provider = try Provider.init(io, a, caller_root, dump_path);
    defer provider.deinit();
    @memset(caller_root, 'x');
    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    const page_a = page_arena.allocator();
    try std.testing.expect((try provider.lookup(page_a, "Missing page", false)) == null);
    const raw_alias = (try provider.lookup(page_a, "Template:Alias", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(alias_raw, raw_alias);
    const template_content = (try Provider.getTemplate(&provider, page_a, "Template:Alias")) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("lazy body", template_content);
    try std.testing.expect(try Provider.exists(&provider, "Ordinary_page"));
    const main_content = (try provider.lookup(page_a, "Ordinary_page", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("A&B", main_content);
}
