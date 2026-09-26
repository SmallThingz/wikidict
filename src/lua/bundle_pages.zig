//! Raw page/template/module source provider for the build-only LLVM bundle worker.
const std = @import("std");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const xml_decode = @import("shared_xml_decode");
const preprocess = @import("lua_wikitext_preprocess");
const wikimedia_dump = @import("wikimedia_dump");
const ExternalData = lua_program.WikitextProvider.ExternalData;
const CategoryStats = lua_program.WikitextProvider.CategoryStats;
const InterfaceMessage = lua_program.WikitextProvider.InterfaceMessage;
const FileMetadata = lua_program.WikitextProvider.FileMetadata;
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;
const WikibaseEntityText = lua_program.WikitextProvider.WikibaseEntityText;
const TransclusionBody = lua_program.WikitextProvider.TransclusionBody;
const CategoryTreeScope = lua_program.WikitextProvider.CategoryTreeScope;

const InterfaceMessageEntry = struct { source_raw: ?[]const u8 };
const CorpusPage = struct { title: []const u8, source: wikimedia_dump.PageSource, page_id: u64, revision_id: u64, revision_timestamp: []const u8, revision_user: []const u8, content_model: []const u8, ns: u32, ordinal: usize, source_needs_decode: bool, redirect: ?[]const u8 = null };
fn packCorpusPageRef(line_offset: usize, ordinal: usize) !u64 {
    return wikimedia_dump.packPageRowRef(line_offset, ordinal);
}

fn corpusPageRefOffset(value: u64) usize {
    return wikimedia_dump.pageRowRefOffset(value);
}

fn corpusPageRefOrdinal(value: u64) usize {
    return wikimedia_dump.pageRowRefOrdinal(value);
}

const max_transclusion_cache_bytes: usize = 64 * 1024 * 1024;
const max_transclusion_cache_entries: usize = 65_536;
const max_transclusion_cache_entry_bytes: usize = 1024 * 1024;
const max_source_cache_bytes: usize = 64 * 1024 * 1024;
const max_source_cache_entries: usize = 4096;
const max_source_cache_entry_bytes: usize = 1024 * 1024;

const SourceCacheEntry = struct {
    page_id: u64,
    revision_id: u64,
    bytes: []u8,
    stamp: u64,
};

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
    // Keep only title -> page-index row references resident. The TSV mmap owns
    // all strings and full metadata is parsed lazily on lookup.
    corpus_pages: std.StringHashMapUnmanaged(u64) = .empty,
    corpus_pages_storage: ?Mapped = null,
    corpus_title_index_storage: ?Mapped = null,
    corpus_title_index: ?wikimedia_dump.PageTitleIndex = null,
    corpus_page_index_kind: wikimedia_dump.PageIndexKind = .raw_xml,
    dump_reader: ?wikimedia_dump.SourceReader = null,
    template_source: ?wikimedia_dump.TemplateSource = null,
    // The ordinal identifies an immutable index row for this Provider lifetime.
    source_cache: std.AutoHashMapUnmanaged(u64, SourceCacheEntry) = .empty,
    source_cache_limit_bytes: usize = max_source_cache_bytes,
    source_cache_bytes: usize = 0,
    source_cache_clock: u64 = 0,
    source_cache_hits: u64 = 0,
    source_cache_misses: u64 = 0,
    source_cache_admits: u64 = 0,
    source_cache_evicts: u64 = 0,
    member_cache_hits: u64 = 0,
    member_cache_misses: u64 = 0,
    member_decoded_bytes: u64 = 0,
    transclusion_body_cache: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    transclusion_body_cache_bytes: usize = 0,
    transclusion_seen: []usize = &.{},
    transclusion_redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    transclusion_redirects_storage: ?Mapped = null,
    external_data: std.StringHashMapUnmanaged(ExternalData) = .empty,
    external_data_storage: ?Mapped = null,
    external_data_available: bool = false,
    category_stats: std.StringHashMapUnmanaged(CategoryStats) = .empty,
    category_stats_storage: ?Mapped = null,
    category_stats_available: bool = false,
    interface_messages: std.StringHashMapUnmanaged(InterfaceMessageEntry) = .empty,
    interface_messages_storage: ?Mapped = null,
    interface_messages_available: bool = false,
    category_tree_ranges: std.StringHashMapUnmanaged([]const u8) = .empty,
    category_tree_storage: ?Mapped = null,
    category_tree_available: bool = false,
    file_metadata: std.StringHashMapUnmanaged(FileMetadata) = .empty,
    file_metadata_storage: ?Mapped = null,
    file_metadata_available: bool = false,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,
    interwiki_available: bool = false,
    wikibase_sitelinks: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty,
    wikibase_sitelinks_storage: ?Mapped = null,
    wikibase_sitelinks_available: bool = false,
    wikibase_entity_text: std.StringHashMapUnmanaged(WikibaseEntityText) = .empty,
    wikibase_entity_text_storage: ?Mapped = null,
    wikibase_entity_text_available: bool = false,
    language_registry: std.StringHashMapUnmanaged([]const u8) = .empty,
    language_registry_storage: ?Mapped = null,
    language_registry_available: bool = false,

    pub fn init(io: std.Io, a: A, root: []const u8, dump_path: []const u8) !Provider {
        const owned_root = try a.dupe(u8, root);
        var self: Provider = .{ .io = io, .a = a, .root = owned_root };
        errdefer self.deinit();
        try self.loadCorpusPages(dump_path);
        try self.loadTransclusionRedirects();
        try self.loadExternalData();
        try self.loadCategoryStats();
        try self.loadInterfaceMessages();
        try self.loadCategoryTree();
        try self.loadFileMetadata();
        try self.loadInterwikiMap();
        try self.loadWikibaseSitelinks();
        try self.loadWikibaseEntityText();
        try self.loadLanguageRegistry();
        return self;
    }

    pub fn deinit(self: *Provider) void {
        lua_program.work_stats.logLine("provider source cache: hits={d} misses={d} admits={d} evicts={d} bytes={d} member_hits={d} member_misses={d} decompressed_bytes={d}\n", .{
            self.source_cache_hits,  self.source_cache_misses, self.source_cache_admits, self.source_cache_evicts,
            self.source_cache_bytes, self.member_cache_hits,   self.member_cache_misses, self.member_decoded_bytes,
        });
        var cached_sources = self.source_cache.valueIterator();
        while (cached_sources.next()) |entry| std.heap.smp_allocator.free(entry.bytes);
        self.source_cache.deinit(std.heap.smp_allocator);
        self.corpus_pages.deinit(self.a);
        if (self.corpus_pages_storage) |*mapped| mapped.deinit();
        if (self.corpus_title_index_storage) |*mapped| mapped.deinit();
        if (self.dump_reader) |*reader| reader.deinit();
        if (self.template_source) |*source| source.deinit();
        var cached = self.transclusion_body_cache.valueIterator();
        while (cached.next()) |body| self.a.free(body.*);
        self.transclusion_body_cache.deinit(self.a);
        self.a.free(self.transclusion_seen);
        self.transclusion_redirects.deinit(self.a);
        if (self.transclusion_redirects_storage) |*mapped| mapped.deinit();
        self.external_data.deinit(self.a);
        if (self.external_data_storage) |*mapped| mapped.deinit();
        self.category_stats.deinit(self.a);
        if (self.category_stats_storage) |*mapped| mapped.deinit();
        self.interface_messages.deinit(self.a);
        if (self.interface_messages_storage) |*mapped| mapped.deinit();
        self.category_tree_ranges.deinit(self.a);
        if (self.category_tree_storage) |*mapped| mapped.deinit();
        self.file_metadata.deinit(self.a);
        if (self.file_metadata_storage) |*mapped| mapped.deinit();
        for (self.interwiki_rows.items) |row| {
            self.a.free((row.prefix));
            self.a.free((row.url));
        }
        self.interwiki_rows.deinit(self.a);
        var sitelinks = self.wikibase_sitelinks.valueIterator();
        while (sitelinks.next()) |site_map| site_map.deinit(self.a);
        self.wikibase_sitelinks.deinit(self.a);
        if (self.wikibase_sitelinks_storage) |*mapped| mapped.deinit();
        self.wikibase_entity_text.deinit(self.a);
        if (self.wikibase_entity_text_storage) |*mapped| mapped.deinit();
        self.language_registry.deinit(self.a);
        if (self.language_registry_storage) |*mapped| mapped.deinit();
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
            .external_data = if (self.external_data_available) externalData else null,
            .category_stats = if (self.category_stats_available) categoryStats else null,
            .interface_message = if (self.interface_messages_available) interfaceMessage else null,
            .category_tree = if (self.category_tree_available) categoryTree else null,
            .file_metadata = if (self.file_metadata_available) fileMetadata else null,
            .interwiki_map = if (self.interwiki_available) interwikiMap else null,
            .stable_interwiki_map = self.interwiki_available,
            .wikibase_sitelink = if (self.wikibase_sitelinks_available) wikibaseSitelink else null,
            .wikibase_entity_text = if (self.wikibase_entity_text_available) wikibaseEntityText else null,
            .language_known_tag = if (self.language_registry_available) languageKnownTag else null,
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

    fn loadTransclusionRedirects(self: *Provider) !void {
        var mapped = (try self.mapOptional("transclusion-redirects.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged([]const u8) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.TransclusionRedirectSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidTransclusionRedirectSnapshot;
            if (tab == 0 or tab + 1 >= line.len or std.mem.indexOfScalarPos(u8, line, tab + 1, '\t') != null)
                return error.InvalidTransclusionRedirectSnapshot;
            const title = line[0..tab];
            const target = line[tab + 1 ..];
            const result = try entries.getOrPut(self.a, title);
            if (result.found_existing) return error.DuplicateTransclusionRedirect;
            result.value_ptr.* = target;
        }
        self.transclusion_redirects = entries;
        self.transclusion_redirects_storage = mapped;
    }

    fn transclusionRedirectTarget(self: *const Provider, raw_title: []const u8) ?[]const u8 {
        if (raw_title.len > 4096) return null;
        if (std.mem.indexOfScalar(u8, raw_title, '_') == null) return self.transclusion_redirects.get(raw_title);
        var title_buffer: [4096]u8 = undefined;
        @memcpy(title_buffer[0..raw_title.len], raw_title);
        std.mem.replaceScalar(u8, title_buffer[0..raw_title.len], '_', ' ');
        return self.transclusion_redirects.get(title_buffer[0..raw_title.len]);
    }

    fn loadExternalData(self: *Provider) !void {
        var mapped = (try self.mapOptional("commons-data.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(ExternalData) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse return error.ExternalDataSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidExternalDataSnapshot;
            const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse return error.InvalidExternalDataSnapshot;
            const name = line[0..first_tab];
            const content_model = line[first_tab + 1 .. second_tab];
            const source = line[second_tab + 1 ..];
            if (name.len == 0 or content_model.len == 0 or source.len == 0) return error.InvalidExternalDataSnapshot;
            const result = try entries.getOrPut(self.a, name);
            if (result.found_existing) return error.DuplicateExternalData;
            result.value_ptr.* = .{ .content_model = content_model, .source = source };
        }
        self.external_data = entries;
        self.external_data_storage = mapped;
        self.external_data_available = true;
    }

    fn loadCategoryStats(self: *Provider) !void {
        var mapped = (try self.mapOptional("category-stats.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(CategoryStats) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse return error.CategoryStatsSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const key = fields.next() orelse return error.InvalidCategoryStatsSnapshot;
            const all = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidCategoryStatsSnapshot, 10);
            const subcats = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidCategoryStatsSnapshot, 10);
            const files = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidCategoryStatsSnapshot, 10);
            if (key.len == 0 or fields.next() != null or subcats > all or files > all - subcats)
                return error.InvalidCategoryStatsSnapshot;
            const result = try entries.getOrPut(self.a, key);
            if (result.found_existing) return error.DuplicateCategoryStats;
            result.value_ptr.* = .{ .all = all, .subcats = subcats, .files = files };
        }
        self.category_stats = entries;
        self.category_stats_storage = mapped;
        self.category_stats_available = true;
    }

    fn loadInterfaceMessages(self: *Provider) !void {
        var mapped = (try self.mapOptional("interface-messages.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(InterfaceMessageEntry) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse return error.InterfaceMessageSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
            const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
            if (first_tab == 0 or second_tab == first_tab + 1) return error.InvalidInterfaceMessageSnapshot;
            const lookup_key = line[0..second_tab];
            const encoded = line[second_tab + 1 ..];
            const entry: InterfaceMessageEntry = if (std.mem.eql(u8, encoded, "M"))
                .{ .source_raw = null }
            else if (std.mem.startsWith(u8, encoded, "V\t"))
                .{ .source_raw = encoded[2..] }
            else
                return error.InvalidInterfaceMessageSnapshot;
            const result = try entries.getOrPut(self.a, lookup_key);
            if (result.found_existing) return error.DuplicateInterfaceMessage;
            result.value_ptr.* = entry;
        }
        self.interface_messages = entries;
        self.interface_messages_storage = mapped;
        self.interface_messages_available = true;
    }

    fn loadCategoryTree(self: *Provider) !void {
        var mapped = (try self.mapOptional("category-tree.tsv")) orelse return;
        errdefer mapped.deinit();
        var ranges: std.StringHashMapUnmanaged([]const u8) = .empty;
        errdefer ranges.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.CategoryTreeSnapshotTooLarge;
        try ranges.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const category = fields.next() orelse return error.InvalidCategoryTreeSnapshot;
            const scope = fields.next() orelse return error.InvalidCategoryTreeSnapshot;
            if (category.len == 0 or std.meta.stringToEnum(CategoryTreeScope, scope) == null)
                return error.InvalidCategoryTreeSnapshot;
            const key_len = category.len + 1 + scope.len;
            var count: usize = 0;
            while (fields.next()) |title| {
                if (title.len == 0 or count >= 200) return error.InvalidCategoryTreeSnapshot;
                count += 1;
            }
            const result = try ranges.getOrPut(self.a, line[0..key_len]);
            if (result.found_existing) return error.DuplicateCategoryTree;
            result.value_ptr.* = if (key_len == line.len) "" else line[key_len + 1 ..];
        }
        self.category_tree_ranges = ranges;
        self.category_tree_storage = mapped;
        self.category_tree_available = true;
    }

    fn loadFileMetadata(self: *Provider) !void {
        var mapped = (try self.mapOptional("file-metadata.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(FileMetadata) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.FileMetadataSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const title = fields.next() orelse return error.InvalidFileMetadataSnapshot;
            const exists_raw = fields.next() orelse return error.InvalidFileMetadataSnapshot;
            const width = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidFileMetadataSnapshot, 10);
            const height = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidFileMetadataSnapshot, 10);
            if (title.len == 0 or fields.next() != null) return error.InvalidFileMetadataSnapshot;
            const exists_flag = if (std.mem.eql(u8, exists_raw, "1"))
                true
            else if (std.mem.eql(u8, exists_raw, "0"))
                false
            else
                return error.InvalidFileMetadataSnapshot;
            if (!exists_flag and (width != 0 or height != 0)) return error.InvalidFileMetadataSnapshot;
            const result = try entries.getOrPut(self.a, title);
            if (result.found_existing) return error.DuplicateFileMetadata;
            result.value_ptr.* = .{ .exists = exists_flag, .width = width, .height = height };
        }
        self.file_metadata = entries;
        self.file_metadata_storage = mapped;
        self.file_metadata_available = true;
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
            const transcludable_raw = fields.next() orelse continue;
            const url_raw = fields.next() orelse continue;
            if (fields.next() != null) return error.InvalidInterwikiSnapshot;
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
                .is_transcludable = std.mem.eql(u8, transcludable_raw, "1"),
            });
        }
    }

    fn loadWikibaseSitelinks(self: *Provider) !void {
        var mapped = (try self.mapOptional("wikibase-sitelinks.tsv")) orelse return;
        errdefer mapped.deinit();
        var entities: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
        errdefer {
            var values = entities.valueIterator();
            while (values.next()) |site_map| site_map.deinit(self.a);
            entities.deinit(self.a);
        }

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidWikibaseSitelinkSnapshot;
            const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse return error.InvalidWikibaseSitelinkSnapshot;
            if (std.mem.indexOfScalarPos(u8, line, second_tab + 1, '\t') != null)
                return error.InvalidWikibaseSitelinkSnapshot;
            const entity_id = line[0..first_tab];
            const global_site_id = line[first_tab + 1 .. second_tab];
            const title = line[second_tab + 1 ..];
            if (entity_id.len == 0 or global_site_id.len == 0) return error.InvalidWikibaseSitelinkSnapshot;
            if (std.mem.eql(u8, global_site_id, "*") and title.len != 0)
                return error.InvalidWikibaseSitelinkSnapshot;

            const entity = try entities.getOrPut(self.a, entity_id);
            if (!entity.found_existing) entity.value_ptr.* = .empty;
            const site = try entity.value_ptr.getOrPut(self.a, global_site_id);
            if (site.found_existing) return error.DuplicateWikibaseSitelink;
            site.value_ptr.* = title;
        }
        self.wikibase_sitelinks = entities;
        self.wikibase_sitelinks_storage = mapped;
        self.wikibase_sitelinks_available = true;
    }

    fn loadWikibaseEntityText(self: *Provider) !void {
        var mapped = (try self.mapOptional("wikibase-entity-text.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(WikibaseEntityText) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.WikibaseEntityTextSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidWikibaseEntityTextSnapshot;
            const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse
                return error.InvalidWikibaseEntityTextSnapshot;
            if (std.mem.indexOfScalarPos(u8, line, second_tab + 1, '\t') != null)
                return error.InvalidWikibaseEntityTextSnapshot;
            const entity_id = line[0..first_tab];
            const label = line[first_tab + 1 .. second_tab];
            const description = line[second_tab + 1 ..];
            if (entity_id.len == 0) return error.InvalidWikibaseEntityTextSnapshot;
            const result = try entries.getOrPut(self.a, entity_id);
            if (result.found_existing) return error.DuplicateWikibaseEntityText;
            result.value_ptr.* = .{
                .label = if (label.len == 0) null else label,
                .description = if (description.len == 0) null else description,
            };
        }
        self.wikibase_entity_text = entries;
        self.wikibase_entity_text_storage = mapped;
        self.wikibase_entity_text_available = true;
    }

    fn loadLanguageRegistry(self: *Provider) !void {
        var mapped = (try self.mapOptional("language-registry.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged([]const u8) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.LanguageRegistrySnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        var mediawiki_rows = true;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "# iso-639-3")) {
                mediawiki_rows = false;
                continue;
            }
            if (line.len == 0 or line[0] == '#' or !mediawiki_rows) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidLanguageRegistrySnapshot;
            const code = line[0..tab];
            const aliases = line[tab + 1 ..];
            const next_tab = std.mem.indexOfScalar(u8, aliases, '\t') orelse aliases.len;
            const name = aliases[0..next_tab];
            if (code.len == 0 or name.len == 0) return error.InvalidLanguageRegistrySnapshot;
            var alias_it = std.mem.splitScalar(u8, aliases, '\t');
            while (alias_it.next()) |alias| if (alias.len == 0) return error.InvalidLanguageRegistrySnapshot;
            const result = try entries.getOrPut(self.a, code);
            if (result.found_existing) return error.DuplicateLanguageRegistryCode;
            result.value_ptr.* = name;
        }
        self.language_registry = entries;
        self.language_registry_storage = mapped;
        self.language_registry_available = true;
    }

    fn loadCorpusPages(self: *Provider, dump_path: []const u8) !void {
        var mapped = (try self.mapOptional("page-index.tsv")) orelse return;
        errdefer mapped.deinit();
        const kind = wikimedia_dump.pageIndexKind(mapped.bytes);
        const stream_index_path = if (wikimedia_dump.isMultistream(kind))
            try std.fs.path.join(self.a, &.{ self.root, "dump-streams.tsv" })
        else
            null;
        defer if (stream_index_path) |path| self.a.free(path);
        var reader = try wikimedia_dump.SourceReader.open(self.io, self.a, std.heap.smp_allocator, dump_path, kind, stream_index_path);
        errdefer reader.deinit();

        var title_index_storage = try self.mapOptional(wikimedia_dump.page_title_index_filename);
        errdefer if (title_index_storage) |*title_mapped| title_mapped.deinit();
        const title_index: ?wikimedia_dump.PageTitleIndex = if (title_index_storage) |title_mapped| blk: {
            const index = try wikimedia_dump.PageTitleIndex.init(title_mapped.bytes);
            if (index.kind != kind or index.page_index_size != mapped.bytes.len) return error.PageTitleIndexMismatch;
            break :blk index;
        } else null;

        var pages: std.StringHashMapUnmanaged(u64) = .empty;
        errdefer pages.deinit(self.a);
        const page_count = if (title_index) |index|
            index.row_count
        else blk: {
            const line_count = std.mem.count(u8, mapped.bytes, "\n") + @intFromBool(mapped.bytes.len != 0 and mapped.bytes[mapped.bytes.len - 1] != '\n');
            break :blk line_count -| @intFromBool(wikimedia_dump.isMultistream(kind));
        };
        if (title_index == null) {
            try pages.ensureTotalCapacity(self.a, @intCast(page_count));
            var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
            var ordinal: usize = 0;
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                const indexed = try wikimedia_dump.parsePageIndexLine(kind, line);
                const base = @intFromPtr(mapped.bytes.ptr);
                const line_ptr = @intFromPtr(line.ptr);
                if (line_ptr < base) return error.InvalidPageIndex;
                const line_offset = line_ptr - base;
                defer ordinal += 1;
                const result = try pages.getOrPut(self.a, indexed.title);
                // Wikimedia dump jobs can observe a title before and after a delete/recreate
                // while walking page IDs. The later row is the state seen later in the dump.
                result.key_ptr.* = indexed.title;
                result.value_ptr.* = try packCorpusPageRef(line_offset, ordinal);
            }
        }
        const bits_per_word = @bitSizeOf(usize);
        const seen_words = self.a.alloc(usize, (page_count + bits_per_word - 1) / bits_per_word) catch null;
        errdefer if (seen_words) |words| self.a.free(words);
        if (seen_words) |words| @memset(words, 0);
        var template_source = try wikimedia_dump.TemplateSource.open(self.io, self.a, self.root, mapped.bytes);
        errdefer if (template_source) |*source| source.deinit();

        self.corpus_pages = pages;
        self.corpus_pages_storage = mapped;
        self.corpus_title_index_storage = title_index_storage;
        self.corpus_title_index = title_index;
        self.corpus_page_index_kind = kind;
        self.dump_reader = reader;
        self.template_source = template_source;
        self.transclusion_seen = seen_words orelse &.{};
    }
    fn corpusPageRef(self: *const Provider, title: []const u8) !?u64 {
        if (self.corpus_title_index) |index| {
            const mapped = self.corpus_pages_storage orelse return error.MissingPageIndex;
            return try index.lookup(mapped.bytes, title);
        }
        return self.corpus_pages.get(title);
    }

    fn corpusPageFromRef(self: *const Provider, ref: u64) !CorpusPage {
        const mapped = self.corpus_pages_storage orelse return error.MissingPageIndex;
        const start = corpusPageRefOffset(ref);
        if (start >= mapped.bytes.len) return error.InvalidPageIndex;
        const end = std.mem.indexOfScalarPos(u8, mapped.bytes, start, '\n') orelse mapped.bytes.len;
        const indexed = try wikimedia_dump.parsePageIndexLine(self.corpus_page_index_kind, mapped.bytes[start..end]);
        return .{
            .title = indexed.title,
            .source = indexed.source,
            .page_id = indexed.page_id,
            .revision_id = indexed.revision_id,
            .revision_timestamp = indexed.revision_timestamp,
            .revision_user = indexed.revision_user,
            .content_model = indexed.content_model,
            .ns = indexed.ns,
            .ordinal = corpusPageRefOrdinal(ref),
            .source_needs_decode = indexed.source_needs_decode,
            .redirect = indexed.redirect,
        };
    }

    pub fn isCanonicalPage(self: *const Provider, title: []const u8, ordinal: u64) bool {
        const ref = (self.corpusPageRef(title) catch return false) orelse return false;
        const wanted = std.math.cast(usize, ordinal) orelse return false;
        return corpusPageRefOrdinal(ref) == wanted;
    }

    fn nextSourceCacheStamp(self: *Provider) u64 {
        self.source_cache_clock +%= 1;
        if (self.source_cache_clock == 0) {
            var entries = self.source_cache.valueIterator();
            while (entries.next()) |entry| entry.stamp = 0;
            self.source_cache_clock = 1;
        }
        return self.source_cache_clock;
    }

    fn evictSource(self: *Provider, ordinal: u64) void {
        const old = self.source_cache.fetchRemove(ordinal) orelse return;
        self.source_cache_bytes -= old.value.bytes.len;
        std.heap.smp_allocator.free(old.value.bytes);
        self.source_cache_evicts +|= 1;
    }

    fn cachedSource(self: *Provider, a: A, page: CorpusPage) !?[]const u8 {
        const ordinal: u64 = @intCast(page.ordinal);
        if (self.source_cache.getPtr(ordinal)) |entry| {
            if (entry.page_id == page.page_id and entry.revision_id == page.revision_id) {
                entry.stamp = self.nextSourceCacheStamp();
                self.source_cache_hits +|= 1;
                return try a.dupe(u8, entry.bytes);
            }
            self.evictSource(ordinal);
        }
        self.source_cache_misses +|= 1;
        return null;
    }

    fn admitSource(self: *Provider, page: CorpusPage, source: []const u8) void {
        if (source.len == 0 or source.len > max_source_cache_entry_bytes or source.len > self.source_cache_limit_bytes) return;
        const ordinal: u64 = @intCast(page.ordinal);
        if (self.source_cache.contains(ordinal)) self.evictSource(ordinal);
        const owned = std.heap.smp_allocator.dupe(u8, source) catch return;
        while (self.source_cache.count() >= max_source_cache_entries or
            self.source_cache_bytes > self.source_cache_limit_bytes - owned.len)
        {
            var it = self.source_cache.iterator();
            const first = it.next() orelse break;
            var oldest_ordinal = first.key_ptr.*;
            var oldest_stamp = first.value_ptr.stamp;
            while (it.next()) |entry| if (entry.value_ptr.stamp < oldest_stamp) {
                oldest_ordinal = entry.key_ptr.*;
                oldest_stamp = entry.value_ptr.stamp;
            };
            self.evictSource(oldest_ordinal);
        }
        self.source_cache.put(std.heap.smp_allocator, ordinal, .{
            .page_id = page.page_id,
            .revision_id = page.revision_id,
            .bytes = owned,
            .stamp = self.nextSourceCacheStamp(),
        }) catch {
            std.heap.smp_allocator.free(owned);
            return;
        };
        self.source_cache_bytes += owned.len;
        self.source_cache_admits +|= 1;
    }

    fn readCorpusSource(self: *Provider, a: A, page: CorpusPage) ![]const u8 {
        if (page.ns != 10) if (try self.cachedSource(a, page)) |cached| return cached;
        const reader = if (self.dump_reader) |*value| value else return error.MissingDump;
        var sidecar_raw: ?[]const u8 = null;
        if (page.ns == 10) {
            if (self.template_source) |*source| {
                sidecar_raw = try source.lookup(@intCast(page.ordinal), page.page_id, page.revision_id);
            }
        }
        const raw: []const u8 = if (sidecar_raw) |stored| blk: {
            if (stored.len != wikimedia_dump.sourceLen(page.source)) return error.TemplateSourceLengthMismatch;
            break :blk if (stored.len == 0) "" else try a.dupe(u8, stored);
        } else blk: {
            const stream_id: ?u32 = switch (page.source) {
                .raw_xml => null,
                .multistream_bz2, .multistream_zstd => |loc| if (loc.len == 0) null else loc.stream_id,
            };
            const was_cached = if (stream_id) |id| reader.cache.contains(id) else false;
            const bytes = try reader.readAlloc(a, page.source);
            if (stream_id) |id| {
                if (was_cached) {
                    self.member_cache_hits +|= 1;
                } else {
                    self.member_cache_misses +|= 1;
                    if (reader.cache.get(id)) |entry| self.member_decoded_bytes +|= entry.bytes.len;
                }
            }
            break :blk bytes;
        };
        if (!page.source_needs_decode) {
            if (page.ns != 10) self.admitSource(page, raw);
            return raw;
        }
        errdefer if (raw.len != 0) a.free(raw);
        const decoded = try xml_decode.decodeSinglePassAlloc(a, raw);
        if (raw.len != 0) a.free(raw);
        if (page.ns != 10) self.admitSource(page, decoded);
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
        const ref = (try self.corpusPageRef(title)) orelse return null;
        return try self.corpusPageFromRef(ref);
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
            if (self.transclusionRedirectTarget(current)) |target| {
                redirects += 1;
                if (redirects > 32) return error.PageRedirectLoop;
                current = target;
                continue;
            }
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
        if (self.transclusion_body_cache.get(page.page_id)) |body| return .{ .text = body, .title = page.title, .borrowed = true };

        const raw = try self.readCorpusSource(a, page);
        defer if (wikimedia_dump.sourceLen(page.source) != 0) a.free(raw);
        const body = preprocess.transcludeDecodedAlloc(a, raw) catch |err| {
            std.log.warn("transclusion body failed: title={s} page_id={d} error={s}", .{ page.title, page.page_id, @errorName(err) });
            return err;
        };
        if (page.ns != 10 or wikimedia_dump.sourceLen(page.source) > max_transclusion_cache_entry_bytes) return .{ .text = body, .title = page.title, .borrowed = false };

        const bits_per_word = @bitSizeOf(usize);
        const word_index = page.ordinal / bits_per_word;
        const bit = @as(usize, 1) << @intCast(page.ordinal % bits_per_word);
        if (word_index >= self.transclusion_seen.len) return .{ .text = body, .title = page.title, .borrowed = false };
        if (self.transclusion_seen[word_index] & bit == 0) {
            self.transclusion_seen[word_index] |= bit;
            return .{ .text = body, .title = page.title, .borrowed = false };
        }
        if (self.transclusion_body_cache.count() >= max_transclusion_cache_entries or
            body.len > max_transclusion_cache_entry_bytes or
            self.transclusion_body_cache_bytes > max_transclusion_cache_bytes -| body.len)
            return .{ .text = body, .title = page.title, .borrowed = false };

        const owned = self.a.dupe(u8, body) catch return .{ .text = body, .title = page.title, .borrowed = false };
        const result = self.transclusion_body_cache.getOrPut(self.a, page.page_id) catch {
            self.a.free(owned);
            return .{ .text = body, .title = page.title, .borrowed = false };
        };
        if (result.found_existing) {
            self.a.free(owned);
            a.free(body);
            return .{ .text = result.value_ptr.*, .title = page.title, .borrowed = true };
        }
        a.free(body);
        result.value_ptr.* = owned;
        self.transclusion_body_cache_bytes += owned.len;
        return .{ .text = owned, .title = page.title, .borrowed = true };
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
        if (self.transclusionRedirectTarget(title)) |target| return target;
        const page = (try self.findPage(title)) orelse return null;
        return page.redirect;
    }

    fn pageMetadata(ctx: ?*anyopaque, title: []const u8) anyerror!?lua_program.WikitextProvider.PageMetadata {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const page = (try self.findPage(title)) orelse return null;
        return .{ .page_id = page.page_id, .revision_id = page.revision_id, .revision_timestamp = page.revision_timestamp, .revision_user = page.revision_user, .content_model = page.content_model };
    }

    fn externalData(ctx: ?*anyopaque, title: []const u8) anyerror!?ExternalData {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.external_data.get(title);
    }

    fn categoryStats(ctx: ?*anyopaque, db_key: []const u8) anyerror!?CategoryStats {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.category_stats.get(db_key);
    }

    fn interfaceMessage(ctx: ?*anyopaque, a: A, language: []const u8, key: []const u8) anyerror!?InterfaceMessage {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const lookup_key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ language, key });
        defer a.free(lookup_key);
        const entry = self.interface_messages.get(lookup_key) orelse return null;
        return .{ .source = if (entry.source_raw) |raw| try unescapeFieldAlloc(a, raw) else null };
    }

    fn categoryTree(ctx: ?*anyopaque, a: A, db_key: []const u8, scope: CategoryTreeScope) anyerror![]const []const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ db_key, @tagName(scope) });
        defer a.free(key);
        const raw = self.category_tree_ranges.get(key) orelse return error.CategoryTreeSnapshotMissing;
        if (raw.len == 0) return &.{};
        const members = try a.alloc([]const u8, std.mem.count(u8, raw, "\t") + 1);
        var fields = std.mem.splitScalar(u8, raw, '\t');
        for (members) |*member| member.* = fields.next().?;
        return members;
    }

    fn fileMetadata(ctx: ?*anyopaque, title: []const u8) anyerror!FileMetadata {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.file_metadata.get(title) orelse {
            std.log.warn("file metadata missing: title={s}", .{title});
            return error.FileMetadataSnapshotMissing;
        };
    }

    fn interwikiMap(ctx: ?*anyopaque) anyerror![]const InterwikiRow {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.interwiki_rows.items;
    }

    fn wikibaseSitelink(ctx: ?*anyopaque, entity_id: []const u8, global_site_id: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const sites = self.wikibase_sitelinks.get(entity_id) orelse return error.WikibaseSitelinkSnapshotMissing;
        const title = sites.get(global_site_id) orelse {
            if (sites.contains("*")) return null;
            return error.WikibaseSitelinkSnapshotMissing;
        };
        return if (title.len == 0) null else title;
    }

    fn wikibaseEntityText(ctx: ?*anyopaque, entity_id: []const u8) anyerror!WikibaseEntityText {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.wikibase_entity_text.get(entity_id) orelse error.WikibaseEntityTextSnapshotMissing;
    }

    fn languageKnownTag(ctx: ?*anyopaque, code: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.language_registry.contains(code);
    }

    fn get(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.lookup(a, title, true);
    }

    fn exists(ctx: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        if (self.transclusionRedirectTarget(title) != null) return true;
        if (std.ascii.startsWithIgnoreCase(title, "Media:")) {
            if (!self.file_metadata_available) {
                std.log.warn("file metadata snapshot unavailable: title=File:{s}", .{title["Media:".len..]});
                return error.FileMetadataSnapshotMissing;
            }
            var file_title_buffer: [512]u8 = undefined;
            const file_title = std.fmt.bufPrint(&file_title_buffer, "File:{s}", .{title["Media:".len..]}) catch {
                std.log.warn("file metadata title exceeds limit: title=File:{s}", .{title["Media:".len..]});
                return error.FileMetadataSnapshotMissing;
            };
            const metadata = self.file_metadata.get(file_title) orelse {
                std.log.warn("file metadata missing: title={s}", .{file_title});
                return error.FileMetadataSnapshotMissing;
            };
            return metadata.exists;
        }
        return (try self.lookup(self.a, title, false)) != null;
    }
};

test "supplemental transclusion redirects resolve omitted namespace pages" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const dump_path = try std.fs.path.join(a, &.{ root, "dump.xml" });
    defer a.free(dump_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = "target body" });
    const page_index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(page_index_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = page_index_path, .data = "0\t11\tTemplate:Target\t\t1\t11\t2024-01-01T00:00:00Z\tEditor\twikitext\t10\t1\t0\n" });
    const redirects_path = try std.fs.path.join(a, &.{ root, "transclusion-redirects.tsv" });
    defer a.free(redirects_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = redirects_path, .data = "# title\ttarget\nUser:Example/helper\tTemplate:Target\n" });

    var provider = try Provider.init(io, a, root, dump_path);
    defer provider.deinit();
    try std.testing.expect(try Provider.exists(&provider, "User:Example/helper"));
    try std.testing.expectEqualStrings("Template:Target", (try Provider.redirectTarget(&provider, "User:Example/helper")).?);
    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    const body = (try Provider.getTransclusionBody(&provider, page_arena.allocator(), "User:Example/helper")).?;
    try std.testing.expectEqualStrings("target body", body.text);
    try std.testing.expectEqualStrings("Template:Target", body.title);
}

test "provider keeps the later duplicate page row as canonical" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const dump_path = try std.fs.path.join(a, &.{ root, "dump.xml" });
    defer a.free(dump_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = "oldnew" });
    const page_index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(page_index_path);
    const page_index =
        "0\t3\tSame\t\t1\t11\t2024-01-01T00:00:00Z\tOld\twikitext\t0\t1\t0\n" ++
        "3\t3\tSame\t\t2\t22\t2024-01-02T00:00:00Z\tNew\twikitext\t0\t1\t0\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = page_index_path, .data = page_index });

    var provider = try Provider.init(io, a, root, dump_path);
    defer provider.deinit();
    try std.testing.expect(!provider.isCanonicalPage("Same", 0));
    try std.testing.expect(provider.isCanonicalPage("Same", 1));
    try std.testing.expect(!provider.isCanonicalPage("Missing", 1));

    var page_arena = std.heap.ArenaAllocator.init(a);
    defer page_arena.deinit();
    const content = (try provider.lookup(page_arena.allocator(), "Same", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("new", content);
    const metadata = (try Provider.pageMetadata(&provider, "Same")).?;
    try std.testing.expectEqual(@as(u64, 2), metadata.page_id);
    try std.testing.expectEqual(@as(u64, 22), metadata.revision_id);
    try std.testing.expectEqualStrings("2024-01-02T00:00:00Z", metadata.revision_timestamp);
}

test "provider loads exact Wikibase sitelinks and fails closed on unknown pairs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "wikibase-sitelinks.tsv" });
    defer a.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "# entity_id\tglobal_site_id\tpage_title\n" ++
            "Q42\tenwiki\tDouglas Adams\n" ++
            "Q42\t*\t\n" ++
            "Q1\tenwiktionary\t\n" ++
            "Q2\tenwiki\tExample\n",
    });

    var provider = try Provider.init(io, a, root, "unused-dump.xml");
    defer provider.deinit();
    const get = provider.api().wikibase_sitelink orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Douglas Adams", (try get(&provider, "Q42", "enwiki")).?);
    try std.testing.expect((try get(&provider, "Q42", "dewiki")) == null);
    try std.testing.expect((try get(&provider, "Q1", "enwiktionary")) == null);
    try std.testing.expectError(error.WikibaseSitelinkSnapshotMissing, get(&provider, "Q1", "dewiki"));
    try std.testing.expectError(error.WikibaseSitelinkSnapshotMissing, get(&provider, "Q2", "dewiki"));
    try std.testing.expectError(error.WikibaseSitelinkSnapshotMissing, get(&provider, "Q3", "enwiki"));
}

test "provider loads pinned Wikibase entity text and fails closed on unknown entities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "wikibase-entity-text.tsv" });
    defer a.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "# entity_id\tlabel\tdescription\n" ++
            "Q42\tDouglas Adams\tEnglish writer and humorist\n" ++
            "Q1\t\tuniverse\n" ++
            "Q2\tEarth\t\n",
    });

    var provider = try Provider.init(io, a, root, "unused-dump.xml");
    defer provider.deinit();
    const get = provider.api().wikibase_entity_text orelse return error.TestExpectedEqual;
    const q42 = try get(&provider, "Q42");
    try std.testing.expectEqualStrings("Douglas Adams", q42.label.?);
    try std.testing.expectEqualStrings("English writer and humorist", q42.description.?);
    const q1 = try get(&provider, "Q1");
    try std.testing.expect(q1.label == null);
    try std.testing.expectEqualStrings("universe", q1.description.?);
    const q2 = try get(&provider, "Q2");
    try std.testing.expectEqualStrings("Earth", q2.label.?);
    try std.testing.expect(q2.description == null);
    try std.testing.expectError(error.WikibaseEntityTextSnapshotMissing, get(&provider, "Q3"));
}

test "provider loads pinned category tree members and fails closed on unknown categories" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "category-tree.tsv" });
    defer a.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "# category_db_key\tpage_title_1...\n" ++
            "English_terms_prefixed_with_un-\tmain\tunable\tunclear\n" ++
            "English_terms_prefixed_with_un-\tpages\tCategory:Child\tTalk:unable\tunable\n" ++
            "Empty_category\tmain\n",
    });

    var provider = try Provider.init(io, a, root, "unused-dump.xml");
    defer provider.deinit();
    const get = provider.api().category_tree orelse return error.TestExpectedEqual;
    const members = try get(&provider, a, "English_terms_prefixed_with_un-", .main);
    defer a.free(members);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("unable", members[0]);
    try std.testing.expectEqualStrings("unclear", members[1]);
    const all_pages = try get(&provider, a, "English_terms_prefixed_with_un-", .pages);
    defer a.free(all_pages);
    try std.testing.expectEqual(@as(usize, 3), all_pages.len);
    try std.testing.expectEqualStrings("Category:Child", all_pages[0]);
    try std.testing.expectEqualStrings("Talk:unable", all_pages[1]);
    try std.testing.expectError(error.CategoryTreeSnapshotMissing, get(&provider, a, "Empty_category", .pages));
    const empty = try get(&provider, a, "Empty_category", .main);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.CategoryTreeSnapshotMissing, get(&provider, a, "Missing_category", .pages));
}

test "provider loads complete known-language registry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" });
    defer a.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "# wikidict-language-registry-v2\n" ++
            "# content-language\tes\n" ++
            "# mediawiki\n" ++
            "en\tEnglish\ten\teng\n" ++
            "es\tespañol\tEspañol\tes\tspa\n" ++
            "# iso-639-3\n" ++
            "aiw\tAari\taiw\n",
    });

    var provider = try Provider.init(io, a, root, "unused-dump.xml");
    defer provider.deinit();
    const known = provider.api().language_known_tag orelse return error.TestExpectedEqual;
    try std.testing.expect(try known(&provider, "en"));
    try std.testing.expect(try known(&provider, "es"));
    try std.testing.expect(!try known(&provider, "zz-invalid"));
    try std.testing.expect(!try known(&provider, "aiw"));
}

test "provider loads pinned file metadata and fails closed on unknown files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "file-metadata.tsv" });
    defer a.free(snapshot_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "# title\texists\twidth\theight\n" ++
            "File:Example.svg\t1\t640\t480\n" ++
            "File:Missing.svg\t0\t0\t0\n",
    });

    var provider = try Provider.init(io, a, root, "unused-dump.xml");
    defer provider.deinit();
    const get = provider.api().file_metadata orelse return error.TestExpectedEqual;
    const existing = try get(&provider, "File:Example.svg");
    try std.testing.expect(existing.exists);
    try std.testing.expectEqual(@as(u32, 640), existing.width);
    try std.testing.expectEqual(@as(u32, 480), existing.height);
    const missing = try get(&provider, "File:Missing.svg");
    try std.testing.expect(!missing.exists);
    try std.testing.expectError(error.FileMetadataSnapshotMissing, get(&provider, "File:Unknown.svg"));
    try std.testing.expect(try Provider.exists(&provider, "Media:Example.svg"));
    try std.testing.expect(!try Provider.exists(&provider, "Media:Missing.svg"));
    try std.testing.expectError(error.FileMetadataSnapshotMissing, Provider.exists(&provider, "Media:Unknown.svg"));
}

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
    try std.testing.expectEqualStrings("Template:Lazy", template_body.title);
    const persistent_a = provider.a;
    var cache_alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    provider.a = cache_alloc.allocator();
    const uncached_body = (try Provider.getTransclusionBody(&provider, page_a, "Template:Lazy")) orelse return error.TestExpectedEqual;
    provider.a = persistent_a;
    defer if (!uncached_body.borrowed) page_a.free(uncached_body.text);
    try std.testing.expect(!uncached_body.borrowed);
    try std.testing.expectEqualStrings("lazy body", uncached_body.text);
    try std.testing.expectEqualStrings("Template:Lazy", uncached_body.title);
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
    const template_page = (try provider.findPage("Template:Lazy")) orelse return error.TestExpectedEqual;
    try std.testing.expect(!provider.source_cache.contains(@intCast(template_page.ordinal)));
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
    try std.testing.expectError(error.FileMetadataSnapshotMissing, Provider.exists(&provider, "Media:Remote.svg"));
    const main_content = (try provider.lookup(page_a, "Ordinary_page", true)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("A&B", main_content);
    // A decoded source hit still belongs to the caller and needs no dump read.
    const first_copy = (try provider.lookup(a, "Ordinary page", true)) orelse return error.TestExpectedEqual;
    defer a.free(first_copy);
    const saved_reader = provider.dump_reader;
    provider.dump_reader = null;
    const second_copy = blk: {
        defer provider.dump_reader = saved_reader;
        break :blk (try provider.lookup(a, "Ordinary page", true)) orelse return error.TestExpectedEqual;
    };
    defer a.free(second_copy);
    try std.testing.expectEqualStrings("A&B", second_copy);
    try std.testing.expect(first_copy.ptr != second_copy.ptr);
    try std.testing.expect(provider.source_cache_hits >= 2);
    try std.testing.expect(provider.source_cache_bytes <= max_source_cache_bytes);

    // The ordinal is unique only within the index; a changed revision must
    // never borrow bytes from an earlier index row.
    var changed_revision = (try provider.findPage("Ordinary page")) orelse return error.TestExpectedEqual;
    changed_revision.revision_id += 1;
    try std.testing.expect((try provider.cachedSource(a, changed_revision)) == null);
    try std.testing.expect(provider.api().interwiki_map == null);
}

test "decoded source cache evicts least recent entry at its entry bound" {
    var provider: Provider = .{ .io = std.testing.io, .a = std.testing.allocator, .root = "" };
    defer {
        var entries = provider.source_cache.valueIterator();
        while (entries.next()) |entry| std.heap.smp_allocator.free(entry.bytes);
        provider.source_cache.deinit(std.heap.smp_allocator);
    }
    const page: CorpusPage = .{
        .title = "cached",
        .source = .{ .raw_xml = .{ .offset = 0, .len = 1 } },
        .page_id = 1,
        .revision_id = 1,
        .revision_timestamp = "",
        .revision_user = "",
        .content_model = "wikitext",
        .ns = 0,
        .ordinal = 0,
        .source_needs_decode = false,
    };
    for (0..max_source_cache_entries) |index| {
        var entry = page;
        entry.ordinal = index;
        entry.page_id = index + 1;
        provider.admitSource(entry, "x");
    }
    var hot = page;
    hot.ordinal = 0;
    const value = (try provider.cachedSource(std.testing.allocator, hot)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(value);
    var next = page;
    next.ordinal = max_source_cache_entries;
    next.page_id = max_source_cache_entries + 1;
    provider.admitSource(next, "y");
    try std.testing.expectEqual(@as(usize, max_source_cache_entries), provider.source_cache.count());
    try std.testing.expectEqual(@as(u64, 1), provider.source_cache_evicts);
    try std.testing.expect(provider.source_cache.contains(0));
    try std.testing.expect(!provider.source_cache.contains(1));
    try std.testing.expect(provider.source_cache_bytes <= max_source_cache_bytes);
}

test "decoded source cache respects byte budget and maximum entry size" {
    var provider: Provider = .{ .io = std.testing.io, .a = std.testing.allocator, .root = "", .source_cache_limit_bytes = 2 };
    defer {
        var entries = provider.source_cache.valueIterator();
        while (entries.next()) |entry| std.heap.smp_allocator.free(entry.bytes);
        provider.source_cache.deinit(std.heap.smp_allocator);
    }
    const page: CorpusPage = .{
        .title = "cached",
        .source = .{ .raw_xml = .{ .offset = 0, .len = 1 } },
        .page_id = 1,
        .revision_id = 1,
        .revision_timestamp = "",
        .revision_user = "",
        .content_model = "wikitext",
        .ns = 0,
        .ordinal = 0,
        .source_needs_decode = false,
    };
    provider.admitSource(page, "a");
    var second = page;
    second.ordinal = 1;
    provider.admitSource(second, "b");
    var third = page;
    third.ordinal = 2;
    provider.admitSource(third, "c");
    try std.testing.expectEqual(@as(usize, 2), provider.source_cache_bytes);
    try std.testing.expectEqual(@as(usize, 2), provider.source_cache.count());
    try std.testing.expect(!provider.source_cache.contains(0));
    try std.testing.expectEqual(@as(u64, 1), provider.source_cache_evicts);
    provider.admitSource(page, "abc");
    try std.testing.expectEqual(@as(usize, 2), provider.source_cache_bytes);
    provider.source_cache_limit_bytes = max_source_cache_bytes;
    const too_large = try std.testing.allocator.alloc(u8, max_source_cache_entry_bytes + 1);
    defer std.testing.allocator.free(too_large);
    provider.admitSource(page, too_large);
    try std.testing.expect(!provider.source_cache.contains(0));
    try std.testing.expectEqual(@as(usize, 2), provider.source_cache_bytes);
}
