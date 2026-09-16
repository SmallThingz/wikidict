//! Raw page/template/module source provider for the build-only LLVM bundle worker.
const std = @import("std");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const xml_decode = @import("shared_xml_decode");
const preprocess = @import("lua_wikitext_preprocess");
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;
const TransclusionBody = lua_program.WikitextProvider.TransclusionBody;

const CorpusPage = struct { offset: u64, len: usize, page_id: u64, revision_id: u64, revision_timestamp: []const u8, revision_user: []const u8, content_model: []const u8, ns: u32, ordinal: usize, source_needs_decode: bool, redirect: ?[]const u8 = null };

const max_transclusion_cache_bytes: usize = 64 * 1024 * 1024;
const max_transclusion_cache_entries: usize = 65_536;
const max_transclusion_cache_entry_bytes: usize = 1024 * 1024;

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
    transclusion_body_cache: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    transclusion_body_cache_bytes: usize = 0,
    transclusion_seen: []usize = &.{},
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,
    interwiki_available: bool = false,

    pub fn init(io: std.Io, a: A, root: []const u8, dump_path: []const u8) !Provider {
        const owned_root = try a.dupe(u8, root);
        var self: Provider = .{ .io = io, .a = a, .root = owned_root };
        errdefer self.deinit();
        try self.loadCorpusPages(dump_path);
        try self.loadInterwikiMap();
        return self;
    }

    pub fn deinit(self: *Provider) void {
        self.corpus_pages.deinit(self.a);
        if (self.corpus_pages_storage) |*mapped| mapped.deinit();
        if (self.dump_file) |*file| file.close(self.io);
        var cached = self.transclusion_body_cache.valueIterator();
        while (cached.next()) |body| self.a.free(body.*);
        self.transclusion_body_cache.deinit(self.a);
        self.a.free(self.transclusion_seen);
        for (self.interwiki_rows.items) |row| {
            self.a.free((row.prefix));
            self.a.free((row.url));
        }
        self.interwiki_rows.deinit(self.a);
        self.a.free(self.root);
        self.root = "";
    }

    pub fn api(self: *Provider) lua_program.WikitextProvider {
        return .{
            .ctx = self,
            .get = get,
            .get_transclusion = getTransclusion,
            .get_transclusion_body = getTransclusionBody,
            .redirect_target = redirectTarget,
            .page_metadata = pageMetadata,
            .exists = exists,
            .interwiki_map = if (self.interwiki_available) interwikiMap else null,
        };
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
        self.interwiki_available = true;
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

    fn loadCorpusPages(self: *Provider, dump_path: []const u8) !void {
        var mapped = (try self.mapOptional("page-index.tsv")) orelse return;
        errdefer mapped.deinit();
        var file = try std.Io.Dir.cwd().openFile(self.io, dump_path, .{});
        errdefer file.close(self.io);
        const dump_size = (try file.stat(self.io)).size;
        var pages: std.StringHashMapUnmanaged(CorpusPage) = .empty;
        errdefer pages.deinit(self.a);
        const page_count = std.mem.count(u8, mapped.bytes, "\n") + @intFromBool(mapped.bytes.len != 0 and mapped.bytes[mapped.bytes.len - 1] != '\n');
        try pages.ensureTotalCapacity(self.a, @intCast(page_count));
        const bits_per_word = @bitSizeOf(usize);
        const seen_words = self.a.alloc(usize, (page_count + bits_per_word - 1) / bits_per_word) catch null;
        errdefer if (seen_words) |words| self.a.free(words);
        if (seen_words) |words| @memset(words, 0);
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        var ordinal: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            defer ordinal += 1;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const offset = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
            const len = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidPageIndex, 10);
            const title = fields.next() orelse return error.InvalidPageIndex;
            const redirect_raw = fields.next() orelse return error.InvalidPageIndex;
            const page_id = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
            const revision_id = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidPageIndex, 10);
            const revision_timestamp = fields.next() orelse return error.InvalidPageIndex;
            const revision_user = fields.next() orelse return error.InvalidPageIndex;
            const content_model = fields.next() orelse return error.InvalidPageIndex;
            const ns = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidPageIndex, 10) catch return error.InvalidPageIndex;
            const has_source = fields.next() orelse return error.InvalidPageIndex;
            const needs_decode_raw = fields.next() orelse return error.InvalidPageIndex;
            if (title.len == 0 or revision_timestamp.len == 0 or content_model.len == 0 or
                (!std.mem.eql(u8, has_source, "0") and !std.mem.eql(u8, has_source, "1")) or
                (!std.mem.eql(u8, needs_decode_raw, "0") and !std.mem.eql(u8, needs_decode_raw, "1")) or
                fields.next() != null) return error.InvalidPageIndex;
            const source_needs_decode = std.mem.eql(u8, needs_decode_raw, "1");
            const redirect = if (redirect_raw.len == 0) null else redirect_raw;
            const end = std.math.add(u64, offset, len) catch return error.InvalidPageIndex;
            if (end > dump_size) return error.InvalidPageIndex;
            const result = try pages.getOrPut(self.a, title);
            if (result.found_existing) return error.DuplicatePage;
            result.key_ptr.* = title;
            result.value_ptr.* = .{ .offset = offset, .len = len, .page_id = page_id, .revision_id = revision_id, .revision_timestamp = revision_timestamp, .revision_user = revision_user, .content_model = content_model, .ns = ns, .ordinal = ordinal, .source_needs_decode = source_needs_decode, .redirect = redirect };
        }
        self.corpus_pages = pages;
        self.corpus_pages_storage = mapped;
        self.dump_file = file;
        self.transclusion_seen = seen_words orelse &.{};
    }

    fn readCorpusSource(self: *Provider, a: A, page: CorpusPage) ![]const u8 {
        if (page.len == 0) return "";
        const file = if (self.dump_file) |*value| value else return error.MissingDump;
        const raw = try a.alloc(u8, page.len);
        errdefer a.free(raw);
        if (try file.readPositionalAll(self.io, raw, page.offset) != raw.len) return error.TruncatedDump;
        if (!page.source_needs_decode) return raw;
        const decoded = try xml_decode.decodeSinglePassAlloc(a, raw);
        a.free(raw);
        return decoded;
    }

    fn findPage(self: *Provider, raw_title: []const u8) !?CorpusPage {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        var title_buffer: [4096]u8 = undefined;
        const title: []const u8 = if (std.mem.indexOfScalar(u8, raw_title, '_') != null) blk: {
            @memcpy(title_buffer[0..raw_title.len], raw_title);
            std.mem.replaceScalar(u8, title_buffer[0..raw_title.len], '_', ' ');
            break :blk title_buffer[0..raw_title.len];
        } else raw_title;
        return self.corpus_pages.get(title);
    }

    fn lookup(self: *Provider, a: A, raw_title: []const u8, content: bool) !?[]const u8 {
        const page = (try self.findPage(raw_title)) orelse return null;
        return if (content) try self.readCorpusSource(a, page) else "";
    }

    fn finalTransclusionPage(self: *Provider, raw_title: []const u8) !?CorpusPage {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        var current = raw_title;
        var redirects: usize = 0;
        while (true) {
            const page = (try self.findPage(current)) orelse return null;
            if (page.redirect) |target| {
                redirects += 1;
                if (redirects > 32) return error.PageRedirectLoop;
                current = target;
                continue;
            }
            return page;
        }
    }

    fn transclusionSource(self: *Provider, a: A, raw_title: []const u8) !?[]const u8 {
        const page = (try self.finalTransclusionPage(raw_title)) orelse return null;
        return try self.readCorpusSource(a, page);
    }

    fn transclusionBody(self: *Provider, a: A, raw_title: []const u8) !?TransclusionBody {
        const page = (try self.finalTransclusionPage(raw_title)) orelse return null;
        if (self.transclusion_body_cache.get(page.page_id)) |body| return .{ .text = body, .borrowed = true };

        const raw = try self.readCorpusSource(a, page);
        defer if (page.len != 0) a.free(raw);
        const body = try preprocess.transcludeDecodedAlloc(a, raw);
        if (page.ns != 10 or page.len > max_transclusion_cache_entry_bytes) return .{ .text = body, .borrowed = false };

        const bits_per_word = @bitSizeOf(usize);
        const word_index = page.ordinal / bits_per_word;
        const bit = @as(usize, 1) << @intCast(page.ordinal % bits_per_word);
        if (word_index >= self.transclusion_seen.len) return .{ .text = body, .borrowed = false };
        if (self.transclusion_seen[word_index] & bit == 0) {
            self.transclusion_seen[word_index] |= bit;
            return .{ .text = body, .borrowed = false };
        }
        if (self.transclusion_body_cache.count() >= max_transclusion_cache_entries or
            body.len > max_transclusion_cache_entry_bytes or
            self.transclusion_body_cache_bytes > max_transclusion_cache_bytes -| body.len)
            return .{ .text = body, .borrowed = false };

        const owned = self.a.dupe(u8, body) catch return .{ .text = body, .borrowed = false };
        const result = self.transclusion_body_cache.getOrPut(self.a, page.page_id) catch {
            self.a.free(owned);
            return .{ .text = body, .borrowed = false };
        };
        if (result.found_existing) {
            self.a.free(owned);
            a.free(body);
            return .{ .text = result.value_ptr.*, .borrowed = true };
        }
        a.free(body);
        result.value_ptr.* = owned;
        self.transclusion_body_cache_bytes += owned.len;
        return .{ .text = owned, .borrowed = true };
    }
    fn getTransclusion(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.transclusionSource(a, title);
    }

    fn getTransclusionBody(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?TransclusionBody {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.transclusionBody(a, title);
    }

    fn redirectTarget(ctx: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const page = (try self.findPage(title)) orelse return null;
        return page.redirect;
    }

    fn pageMetadata(ctx: ?*anyopaque, title: []const u8) anyerror!?lua_program.WikitextProvider.PageMetadata {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const page = (try self.findPage(title)) orelse return null;
        return .{ .page_id = page.page_id, .revision_id = page.revision_id, .revision_timestamp = page.revision_timestamp, .revision_user = page.revision_user, .content_model = page.content_model };
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
        if (std.ascii.startsWithIgnoreCase(title, "Media:")) return error.NotImplemented;
        return (try self.lookup(self.a, title, false)) != null;
    }
};

test "provider owns paths and separates raw content from redirect-following transclusion" {
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
    const template_raw = "lazy <noinclude>docs</noinclude>body";
    const alias_raw = "#REDIRECT [[Template:Lazy]]";
    const dump_bytes = prefix ++ ordinary_raw ++ template_raw ++ alias_raw;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });
    const page_index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(page_index_path);
    const template_offset = prefix.len + ordinary_raw.len;
    const alias_offset = template_offset + template_raw.len;
    const page_index = try std.fmt.allocPrint(
        a,
        "{d}\t{d}\tOrdinary page\t\t1\t101\t2024-03-04T05:06:07Z\tAlice\twikitext\t0\t1\t1\n{d}\t{d}\tTemplate:Lazy\t\t2\t102\t2024-03-05T06:07:08Z\tBob\twikitext\t10\t1\t0\n{d}\t{d}\tTemplate:Alias\tTemplate:Lazy\t3\t103\t2024-03-06T07:08:09Z\t192.0.2.7\twikitext\t10\t1\t0",
        .{ prefix.len, ordinary_raw.len, template_offset, template_raw.len, alias_offset, alias_raw.len },
    );
    defer a.free(page_index);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = page_index_path, .data = page_index });

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
    const template_content = (try Provider.getTransclusion(&provider, page_a, "Template:Alias")) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(template_raw, template_content);
    const template_body = (try Provider.getTransclusionBody(&provider, page_a, "Template:Alias")) orelse return error.TestExpectedEqual;
    defer if (!template_body.borrowed) page_a.free(template_body.text);
    try std.testing.expectEqualStrings("lazy body", template_body.text);
    const persistent_a = provider.a;
    var cache_alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    provider.a = cache_alloc.allocator();
    const uncached_body = (try Provider.getTransclusionBody(&provider, page_a, "Template:Lazy")) orelse return error.TestExpectedEqual;
    provider.a = persistent_a;
    defer if (!uncached_body.borrowed) page_a.free(uncached_body.text);
    try std.testing.expect(!uncached_body.borrowed);
    try std.testing.expectEqualStrings("lazy body", uncached_body.text);
    const admitted_body = (try Provider.getTransclusionBody(&provider, page_a, "Template:Lazy")) orelse return error.TestExpectedEqual;
    try std.testing.expect(admitted_body.borrowed);
    try std.testing.expectEqualStrings("lazy body", admitted_body.text);
    var no_alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const cached_body = (try Provider.getTransclusionBody(&provider, no_alloc.allocator(), "Template:Alias")) orelse return error.TestExpectedEqual;
    try std.testing.expect(cached_body.borrowed);
    try std.testing.expectEqualStrings("lazy body", cached_body.text);
    var borrowed_alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    const borrowed_a = borrowed_alloc.allocator();
    const borrowed_template = (try provider.lookup(borrowed_a, "Template:Lazy", true)) orelse return error.TestExpectedEqual;
    defer borrowed_a.free(borrowed_template);
    try std.testing.expectEqualStrings(template_raw, borrowed_template);
    var decoded_alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, provider.lookup(decoded_alloc.allocator(), "Ordinary page", true));
    try std.testing.expectEqualStrings("Template:Lazy", (try Provider.redirectTarget(&provider, "Template:Alias")).?);
    try std.testing.expect((try Provider.redirectTarget(&provider, "Template:Lazy")) == null);
    const metadata = (try Provider.pageMetadata(&provider, "Ordinary page")).?;
    try std.testing.expectEqual(@as(u64, 1), metadata.page_id);
    try std.testing.expectEqual(@as(u64, 101), metadata.revision_id);
    try std.testing.expectEqualStrings("2024-03-04T05:06:07Z", metadata.revision_timestamp);
    try std.testing.expectEqualStrings("Alice", metadata.revision_user);
    try std.testing.expectEqualStrings("wikitext", metadata.content_model);
    try std.testing.expect(try Provider.exists(&provider, "Ordinary_page"));
    try std.testing.expectError(error.NotImplemented, Provider.exists(&provider, "Media:Remote.svg"));
    const main_content = (try provider.lookup(page_a, "Ordinary_page", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("A&B", main_content);
    try std.testing.expect(provider.api().interwiki_map == null);
}
