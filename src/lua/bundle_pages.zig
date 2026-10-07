//! Raw page/template/module source provider for the build-only LLVM bundle worker.
const std = @import("std");
const A = std.mem.Allocator;
const lua_program = @import("lua_program");
const xml_decode = @import("shared_xml_decode");
const preprocess = @import("lua_wikitext_preprocess");
const wikimedia_dump = @import("wikimedia_dump");
const magic_words = lua_program.namespace_registry.magic_words;
const language_names_lib = @import("language_names.zig");
const date_numbering_lib = @import("date_numbering.zig");
const site_info_lib = @import("site_info.zig");
const page_redirects_lib = lua_program.namespace_registry.page_redirects;
const ExternalData = lua_program.WikitextProvider.ExternalData;
const CategoryStats = lua_program.WikitextProvider.CategoryStats;
const InterfaceMessage = lua_program.WikitextProvider.InterfaceMessage;
const FileMetadata = lua_program.WikitextProvider.FileMetadata;
const InterwikiRow = lua_program.WikitextProvider.InterwikiRow;
const WikibaseEntityText = lua_program.WikitextProvider.WikibaseEntityText;
const WikibaseEntity = lua_program.WikitextProvider.WikibaseEntity;
const WikibaseEntityCache = lua_program.WikibaseEntityCache;
const WikibaseTerm = lua_program.WikitextProvider.WikibaseTerm;
const WikibaseEntityTerms = lua_program.WikitextProvider.WikibaseEntityTerms;
const TransclusionBody = lua_program.WikitextProvider.TransclusionBody;
const CategoryTreeScope = lua_program.WikitextProvider.CategoryTreeScope;

const InterfaceMessageEntry = struct { source_raw: ?[]const u8 };
const StructuredEntityRow = struct { requested_id: []const u8, canonical_id: []const u8, source: ?[]const u8 };
const WikibasePageLinks = std.AutoHashMapUnmanaged(u64, ?[]const u8);

fn parseWikibasePageLinks(a: A, source: []const u8) !WikibasePageLinks {
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidWikibasePageLinkSnapshot, "# wikidict-wikibase-page-links-v1\tpartial")) return error.InvalidWikibasePageLinkSnapshot;
    var entries: WikibasePageLinks = .empty;
    errdefer entries.deinit(a);
    var previous: u64 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# end\t")) {
            const raw_count = line[6..];
            if (raw_count.len == 0 or (raw_count.len > 1 and raw_count[0] == '0')) return error.InvalidWikibasePageLinkSnapshot;
            for (raw_count) |c| if (!std.ascii.isDigit(c)) return error.InvalidWikibasePageLinkSnapshot;
            const count = std.fmt.parseInt(usize, raw_count, 10) catch return error.InvalidWikibasePageLinkSnapshot;
            if (count != entries.count() or !std.mem.eql(u8, lines.next() orelse return error.InvalidWikibasePageLinkSnapshot, "") or lines.next() != null) return error.InvalidWikibasePageLinkSnapshot;
            return entries;
        }
        var fields = std.mem.splitScalar(u8, line, '\t');
        const raw_page_id = fields.next() orelse return error.InvalidWikibasePageLinkSnapshot;
        const entity_id = fields.next() orelse return error.InvalidWikibasePageLinkSnapshot;
        if (fields.next() != null or !validEntityDigits(raw_page_id)) return error.InvalidWikibasePageLinkSnapshot;
        const page_id = std.fmt.parseInt(u64, raw_page_id, 10) catch return error.InvalidWikibasePageLinkSnapshot;
        if (page_id <= previous) return error.InvalidWikibasePageLinkSnapshot;
        const absent = std.mem.eql(u8, entity_id, "-");
        if (!absent) {
            if (!validEntityId(entity_id) or entity_id[0] != 'Q') return error.InvalidWikibasePageLinkSnapshot;
            const number = std.fmt.parseInt(u32, entity_id[1..], 10) catch return error.InvalidWikibasePageLinkSnapshot;
            if (number > 2_147_483_647) return error.InvalidWikibasePageLinkSnapshot;
        }
        try entries.put(a, page_id, if (absent) null else entity_id);
        previous = page_id;
    }
    return error.InvalidWikibasePageLinkSnapshot;
}

fn expectSnapshotHeader(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, expected: []const u8) !void {
    const line = lines.next() orelse return error.InvalidSnapshotIdentity;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], expected)) return error.InvalidSnapshotIdentity;
}

fn validLanguageCode(code: []const u8) bool {
    if (code.len == 0) return false;
    for (code) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

fn validEntityDigits(digits: []const u8) bool {
    if (digits.len == 0 or digits[0] == '0') return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validEntityId(id: []const u8) bool {
    if (id.len < 2) return false;
    if (id[0] != 'Q' and id[0] != 'P' and id[0] != 'L') return false;
    if (std.mem.indexOfScalar(u8, id, '-')) |dash| {
        return id[0] == 'L' and dash + 2 < id.len and validEntityDigits(id[1..dash]) and
            (id[dash + 1] == 'F' or id[dash + 1] == 'S') and validEntityDigits(id[dash + 2 ..]);
    }
    return validEntityDigits(id[1..]);
}

fn structuredEntityRow(line: []const u8) !StructuredEntityRow {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const id = fields.next() orelse return error.InvalidWikibaseEntitySnapshot;
    const state = fields.next() orelse return error.InvalidWikibaseEntitySnapshot;
    const canonical = fields.next() orelse return error.InvalidWikibaseEntitySnapshot;
    const source = fields.next() orelse return error.InvalidWikibaseEntitySnapshot;
    if (fields.next() != null or !validEntityId(id) or source.len > 16 * 1024 * 1024) return error.InvalidWikibaseEntitySnapshot;
    if (std.mem.eql(u8, state, "M")) {
        if (canonical.len != 0 or source.len != 0) return error.InvalidWikibaseEntitySnapshot;
        return .{ .requested_id = id, .canonical_id = canonical, .source = null };
    }
    if (!std.mem.eql(u8, state, "E") or !validEntityId(canonical) or source.len == 0) return error.InvalidWikibaseEntitySnapshot;
    return .{ .requested_id = id, .canonical_id = canonical, .source = source };
}

fn validateEntityPayload(value: std.json.Value, canonical: []const u8) !void {
    if (value != .object) return error.InvalidWikibaseEntitySnapshot;
    const id = value.object.get("id") orelse return error.InvalidWikibaseEntitySnapshot;
    const version = value.object.get("schemaVersion") orelse return error.InvalidWikibaseEntitySnapshot;
    const kind = value.object.get("type") orelse return error.InvalidWikibaseEntitySnapshot;
    if (id != .string or !std.mem.eql(u8, id.string, canonical) or version != .integer or version.integer != 2 or kind != .string) return error.InvalidWikibaseEntitySnapshot;
    const expected_kind: []const u8 = if (std.mem.indexOfScalar(u8, canonical, '-')) |dash|
        (if (canonical[dash + 1] == 'F') "form" else "sense")
    else switch (canonical[0]) {
        'Q' => "item",
        'P' => "property",
        else => "lexeme",
    };
    if (!std.mem.eql(u8, kind.string, expected_kind)) return error.InvalidWikibaseEntitySnapshot;
    inline for (.{ "claims", "lemmas", "labels", "descriptions", "sitelinks", "representations", "glosses" }) |name| {
        if (value.object.get(name)) |field| if (field != .object) return error.InvalidWikibaseEntitySnapshot;
    }
    inline for (.{ "forms", "senses", "grammaticalFeatures" }) |name| {
        if (value.object.get(name)) |field| if (field != .array) return error.InvalidWikibaseEntitySnapshot;
    }
    if (value.object.get("claims")) |claims| {
        var properties = claims.object.iterator();
        while (properties.next()) |entry| {
            if (entry.value_ptr.* != .array) return error.InvalidWikibaseEntitySnapshot;
            for (entry.value_ptr.array.items) |statement| if (statement != .object) return error.InvalidWikibaseEntitySnapshot;
        }
    }
}

fn capturedTerm(a: A, value: std.json.Value) !?WikibaseTerm {
    if (value == .null) return null;
    if (value != .object or value.object.count() < 2 or value.object.count() > 3) return error.InvalidWikibaseEntityTermSnapshot;
    const text = value.object.get("value") orelse return error.InvalidWikibaseEntityTermSnapshot;
    const language = value.object.get("language") orelse return error.InvalidWikibaseEntityTermSnapshot;
    const source_language = value.object.get("source-language");
    if (text != .string or language != .string or !validLanguageCode(language.string)) return error.InvalidWikibaseEntityTermSnapshot;
    if (value.object.count() == 3 and source_language == null) return error.InvalidWikibaseEntityTermSnapshot;
    if (source_language) |source| if (source != .string or !validLanguageCode(source.string)) return error.InvalidWikibaseEntityTermSnapshot;
    return .{ .value = try a.dupe(u8, text.string), .language = try a.dupe(u8, language.string), .source_language = if (source_language) |source| try a.dupe(u8, source.string) else null };
}

fn messageLookupKey(a: A, language: []const u8, raw: []const u8) ![]u8 {
    if (!validLanguageCode(language)) return error.InvalidInterfaceMessageKey;
    const key = try lua_program.WikitextProvider.normalizeInterfaceMessageKeyAlloc(a, raw);
    defer a.free(key);
    return std.fmt.allocPrint(a, "{s}\t{s}", .{ language, key });
}
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
    namespace_catalog: *const lua_program.namespace_registry.Registry,
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
    page_redirects_storage: ?Mapped = null,
    page_redirects: ?page_redirects_lib.Snapshot = null,
    external_data: std.StringHashMapUnmanaged(?ExternalData) = .empty,
    external_data_storage: ?Mapped = null,
    external_data_available: bool = false,
    site_info: ?site_info_lib.Snapshot = null,
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
    file_metadata_available: bool = false,
    interwiki_rows: std.ArrayList(InterwikiRow) = .empty,
    interwiki_available: bool = false,
    wikibase_sitelinks: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty,
    wikibase_sitelinks_storage: ?Mapped = null,
    wikibase_sitelinks_available: bool = false,
    wikibase_entity_text: std.StringHashMapUnmanaged(WikibaseEntityText) = .empty,
    wikibase_entity_text_storage: ?Mapped = null,
    wikibase_entity_text_available: bool = false,
    wikibase_page_links: WikibasePageLinks = .empty,
    wikibase_page_links_storage: ?Mapped = null,
    wikibase_entities: std.StringHashMapUnmanaged(StructuredEntityRow) = .empty,
    wikibase_entities_storage: ?Mapped = null,
    wikibase_entity_cache: ?*WikibaseEntityCache = null,
    wikibase_entity_cache_disabled: bool = false,
    wikibase_entity_terms: std.StringHashMapUnmanaged(WikibaseEntityTerms) = .empty,
    wikibase_entity_terms_storage: ?Mapped = null,
    wikibase_entity_terms_arena: ?std.heap.ArenaAllocator = null,
    language_fallbacks: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    language_fallbacks_storage: ?Mapped = null,
    language_names: ?language_names_lib.Registry = null,
    date_numbering: ?date_numbering_lib.Registry = null,
    language_registry: std.StringHashMapUnmanaged([]const u8) = .empty,
    language_registry_storage: ?Mapped = null,
    language_registry_available: bool = false,
    title_magic_words: ?magic_words.Registry = null,

    pub fn init(io: std.Io, a: A, root: []const u8, namespace_catalog: *const lua_program.namespace_registry.Registry, dump_path: []const u8) !Provider {
        const owned_root = try a.dupe(u8, root);
        var self: Provider = .{ .io = io, .a = a, .root = owned_root, .namespace_catalog = namespace_catalog };
        errdefer self.deinit();
        try self.loadCorpusPages(dump_path);
        try self.loadTransclusionRedirects();
        try self.loadPageRedirects();
        try self.loadExternalData();
        try self.loadSiteInfo();
        try self.loadCategoryStats();
        try self.loadInterfaceMessages();
        try self.loadCategoryTree();
        try self.loadFileMetadata();
        try self.loadInterwikiMap();
        try self.loadWikibaseSitelinks();
        try self.loadWikibaseEntityText();
        try self.loadWikibasePageLinks();
        try self.loadWikibaseEntities();
        try self.loadWikibaseEntityTerms();
        try self.loadLanguageFallbacks();
        try self.loadLanguageNames();
        try self.loadDateNumbering();
        try self.loadLanguageRegistry();
        try self.loadTitleMagicWords();
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
        var redirect_it = self.transclusion_redirects.iterator();
        while (redirect_it.next()) |entry| {
            self.a.free(entry.key_ptr.*);
            self.a.free(entry.value_ptr.*);
        }
        self.transclusion_redirects.deinit(self.a);
        if (self.transclusion_redirects_storage) |*mapped| mapped.deinit();
        if (self.page_redirects) |*snapshot| snapshot.deinit();
        if (self.page_redirects_storage) |*mapped| mapped.deinit();
        self.external_data.deinit(self.a);
        if (self.external_data_storage) |*mapped| mapped.deinit();
        if (self.site_info) |*snapshot| snapshot.deinit();
        self.category_stats.deinit(self.a);
        if (self.category_stats_storage) |*mapped| mapped.deinit();
        var message_keys = self.interface_messages.keyIterator();
        while (message_keys.next()) |key| self.a.free(key.*);
        self.interface_messages.deinit(self.a);
        if (self.interface_messages_storage) |*mapped| mapped.deinit();
        self.category_tree_ranges.deinit(self.a);
        if (self.category_tree_storage) |*mapped| mapped.deinit();
        var files = self.file_metadata.iterator();
        while (files.next()) |entry| {
            self.a.free(entry.key_ptr.*);
            if (entry.value_ptr.canonical_title) |title| self.a.free(title);
        }
        self.file_metadata.deinit(self.a);
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
        self.wikibase_page_links.deinit(self.a);
        if (self.wikibase_page_links_storage) |*mapped| mapped.deinit();
        if (self.wikibase_entity_text_storage) |*mapped| mapped.deinit();
        if (self.wikibase_entity_cache) |cache| {
            lua_program.work_stats.logLine("wikibase parsed cache: entries={d} requested_bytes={d} peak_requested_bytes={d} budget={d} hits={d} misses={d} capacity_bypasses={d} allocation_bypasses={d} parse_bypasses={d} validation_bypasses={d}\n", .{
                cache.entry_count,    cache.budget.used,         cache.budget.peak,       cache.budget.limit,
                cache.hits,           cache.misses,              cache.capacity_bypasses, cache.allocation_bypasses,
                cache.parse_bypasses, cache.validation_bypasses,
            });
            cache.destroy();
        }
        self.wikibase_entities.deinit(self.a);
        if (self.wikibase_entities_storage) |*mapped| mapped.deinit();
        self.wikibase_entity_terms.deinit(self.a);
        if (self.wikibase_entity_terms_storage) |*mapped| mapped.deinit();
        if (self.wikibase_entity_terms_arena) |*arena| arena.deinit();
        var fallback_lists = self.language_fallbacks.valueIterator();
        while (fallback_lists.next()) |list| self.a.free(list.*);
        self.language_fallbacks.deinit(self.a);
        if (self.language_fallbacks_storage) |*mapped| mapped.deinit();
        if (self.language_names) |*registry| registry.deinit();
        if (self.date_numbering) |*registry| registry.deinit();
        self.language_registry.deinit(self.a);
        if (self.language_registry_storage) |*mapped| mapped.deinit();
        if (self.title_magic_words) |*registry| registry.deinit();
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
            .stable_page_reads = true,
            .authoritative_page_source = true,
            .exists = exists,
            .external_data = if (self.external_data_available) externalData else null,
            .site_server = if (self.site_info) |snapshot| snapshot.server else null,
            .site_statistics = if (self.site_info) |snapshot| snapshot.statistics else null,
            .site_script = if (self.site_info) |snapshot| snapshot.script else null,
            .site_article_path = if (self.site_info) |snapshot| snapshot.article_path else null,
            .category_stats = if (self.category_stats_available) categoryStats else null,
            .interface_message = if (self.interface_messages_available) interfaceMessage else null,
            .category_tree = if (self.category_tree_available) categoryTree else null,
            .file_metadata = if (self.file_metadata_available) fileMetadata else null,
            .interwiki_map = if (self.interwiki_available) interwikiMap else null,
            .stable_interwiki_map = self.interwiki_available,
            .resolve_title_magic = if (self.title_magic_words != null) resolveTitleMagic else null,
            .resolve_parser_function = if (self.title_magic_words != null and self.title_magic_words.?.expanded_functions) resolveParserFunction else null,
            .wikibase_sitelink = if (self.wikibase_sitelinks_available) wikibaseSitelink else null,
            .wikibase_entity_text = if (self.wikibase_entity_text_available) wikibaseEntityText else null,
            .wikibase_entity = if (self.wikibase_entities_storage != null) wikibaseEntity else null,
            .wikibase_page_entity_id = if (self.wikibase_page_links_storage != null) wikibasePageEntityId else null,
            .wikibase_entity_terms = if (self.wikibase_entity_terms_storage != null) wikibaseEntityTerms else null,
            .language_fallbacks = if (self.language_fallbacks_storage != null) languageFallbacks else null,
            .date_numbering = if (self.date_numbering != null) dateNumbering else null,
            .language_names = if (self.language_names != null) languageNames else null,
            .language_name = if (self.language_names != null) languageName else null,
            .language_direction = if (self.language_names != null) languageDirection else null,
            .language_known_tag = if (self.language_registry_available) languageKnownTag else null,
        };
    }

    fn loadSiteInfo(self: *Provider) !void {
        var mapped = (try self.mapOptional("namespace-siteinfo.raw.json")) orelse return;
        defer mapped.deinit();
        self.site_info = try site_info_lib.Snapshot.init(self.a, mapped.bytes, self.namespace_catalog.wiki, self.namespace_catalog.dump_date, self.namespace_catalog.content_language);
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
        errdefer {
            var it = entries.iterator();
            while (it.next()) |entry| {
                self.a.free(entry.key_ptr.*);
                self.a.free(entry.value_ptr.*);
            }
            entries.deinit(self.a);
        }
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.TransclusionRedirectSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidTransclusionRedirectSnapshot;
            if (tab == 0 or tab + 1 >= line.len or std.mem.indexOfScalarPos(u8, line, tab + 1, '\t') != null)
                return error.InvalidTransclusionRedirectSnapshot;
            const title = try self.namespace_catalog.normalizeTitle(self.a, line[0..tab], 0, .any);
            errdefer self.a.free(title);
            const target = try self.namespace_catalog.normalizeTitle(self.a, line[tab + 1 ..], 0, .any);
            errdefer self.a.free(target);
            const result = try entries.getOrPut(self.a, title);
            if (result.found_existing) return error.DuplicateTransclusionRedirect;
            result.value_ptr.* = target;
        }
        self.transclusion_redirects = entries;
        self.transclusion_redirects_storage = mapped;
    }

    fn transclusionRedirectTarget(self: *const Provider, raw_title: []const u8) !?[]const u8 {
        if (raw_title.len > 4096) return error.InvalidPageTitle;
        const title = try self.namespace_catalog.normalizeTitle(std.heap.smp_allocator, raw_title, 0, .any);
        defer std.heap.smp_allocator.free(title);
        return self.transclusion_redirects.get(title);
    }

    fn loadExternalData(self: *Provider) !void {
        var mapped = (try self.mapOptional("commons-data.tsv")) orelse return;
        errdefer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(?ExternalData) = .empty;
        errdefer entries.deinit(self.a);
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse return error.ExternalDataSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        const header = lines.next() orelse return error.InvalidExternalDataSnapshot;
        const explicit_state = std.mem.eql(u8, header, "# wikidict-commons-data-v2");
        if (!explicit_state and !std.mem.eql(u8, header, "# wikidict-commons-data-v1"))
            return error.InvalidExternalDataSnapshot;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const name = fields.next() orelse return error.InvalidExternalDataSnapshot;
            const state = if (explicit_state) fields.next() orelse return error.InvalidExternalDataSnapshot else "present";
            const content_model = fields.next() orelse return error.InvalidExternalDataSnapshot;
            const source = fields.next() orelse return error.InvalidExternalDataSnapshot;
            if (name.len == 0 or fields.next() != null) return error.InvalidExternalDataSnapshot;
            const entry: ?ExternalData = if (std.mem.eql(u8, state, "missing")) missing: {
                if (content_model.len != 0 or source.len != 0) return error.InvalidExternalDataSnapshot;
                break :missing null;
            } else present: {
                if (!std.mem.eql(u8, state, "present") or content_model.len == 0 or source.len == 0)
                    return error.InvalidExternalDataSnapshot;
                break :present .{ .content_model = content_model, .source = source };
            };
            const result = try entries.getOrPut(self.a, name);
            if (result.found_existing) return error.DuplicateExternalData;
            result.value_ptr.* = entry;
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
        errdefer {
            var keys = entries.keyIterator();
            while (keys.next()) |key| self.a.free(key.*);
            entries.deinit(self.a);
        }
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse return error.InterfaceMessageSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);

        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        if (std.mem.eql(u8, lines.peek() orelse "", "# wikidict-interface-messages-v1")) {
            _ = lines.next();
            try expectSnapshotHeader(&lines, "# wiki\t", self.namespace_catalog.wiki);
            try expectSnapshotHeader(&lines, "# dump-date\t", self.namespace_catalog.dump_date);
            try expectSnapshotHeader(&lines, "# content-language\t", self.namespace_catalog.content_language);
        }
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
            const second_tab = std.mem.indexOfScalarPos(u8, line, first_tab + 1, '\t') orelse return error.InvalidInterfaceMessageSnapshot;
            if (first_tab == 0 or second_tab == first_tab + 1) return error.InvalidInterfaceMessageSnapshot;
            const lookup_key = try messageLookupKey(self.a, line[0..first_tab], line[first_tab + 1 .. second_tab]);
            errdefer self.a.free(lookup_key);
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
        defer mapped.deinit();
        var entries: std.StringHashMapUnmanaged(FileMetadata) = .empty;
        errdefer {
            var it = entries.iterator();
            while (it.next()) |entry| {
                self.a.free(entry.key_ptr.*);
                if (entry.value_ptr.canonical_title) |title| self.a.free(title);
            }
            entries.deinit(self.a);
        }
        const capacity = std.math.cast(u32, std.mem.count(u8, mapped.bytes, "\n") + 1) orelse
            return error.FileMetadataSnapshotTooLarge;
        try entries.ensureTotalCapacity(self.a, capacity);
        const v2 = std.mem.startsWith(u8, mapped.bytes, "# wikidict-file-metadata-v2\n");
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const title = fields.next() orelse return error.InvalidFileMetadataSnapshot;
            const exists_raw = fields.next() orelse return error.InvalidFileMetadataSnapshot;
            const width = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidFileMetadataSnapshot, 10);
            const height = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidFileMetadataSnapshot, 10);
            if (title.len == 0) return error.InvalidFileMetadataSnapshot;
            const exists_flag = if (std.mem.eql(u8, exists_raw, "1"))
                true
            else if (std.mem.eql(u8, exists_raw, "0"))
                false
            else
                return error.InvalidFileMetadataSnapshot;
            if (!exists_flag and (width != 0 or height != 0)) return error.InvalidFileMetadataSnapshot;
            var media_type: ?FileMetadata.MediaType = null;
            var canonical_title: ?[]const u8 = null;
            errdefer if (canonical_title) |owned| self.a.free(owned);
            if (v2) {
                const media_raw = fields.next() orelse return error.InvalidFileMetadataSnapshot;
                const canonical_raw = fields.next() orelse return error.InvalidFileMetadataSnapshot;
                if (exists_flag) {
                    media_type = std.meta.stringToEnum(FileMetadata.MediaType, media_raw) orelse
                        return error.InvalidFileMetadataSnapshot;
                    if (canonical_raw.len == 0 or std.mem.eql(u8, canonical_raw, "-"))
                        return error.InvalidFileMetadataSnapshot;
                    canonical_title = try self.normalizeFileTitle(self.a, canonical_raw);
                    if (!std.mem.eql(u8, canonical_title.?, canonical_raw))
                        return error.InvalidFileMetadataSnapshot;
                } else if (!std.mem.eql(u8, media_raw, "-") or !std.mem.eql(u8, canonical_raw, "-"))
                    return error.InvalidFileMetadataSnapshot;
            }
            if (fields.next() != null) return error.InvalidFileMetadataSnapshot;
            const canonical = try self.normalizeFileTitle(self.a, title);
            errdefer self.a.free(canonical);
            const result = try entries.getOrPut(self.a, canonical);
            if (result.found_existing) return error.DuplicateFileMetadata;
            result.value_ptr.* = .{
                .exists = exists_flag,
                .width = width,
                .height = height,
                .media_type = media_type,
                .canonical_title = canonical_title,
            };
        }
        self.file_metadata = entries;
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

    fn structuredHeaders(self: *const Provider, lines: *std.mem.SplitIterator(u8, .scalar), terms: bool) !void {
        try expectSnapshotHeader(lines, "", if (terms) "# wikidict-wikibase-entity-terms-v1" else "# wikidict-wikibase-entities-v1");
        try expectSnapshotHeader(lines, "# wiki=", self.namespace_catalog.wiki);
        try expectSnapshotHeader(lines, "# date=", self.namespace_catalog.dump_date);
        try expectSnapshotHeader(lines, "# content-language=", self.namespace_catalog.content_language);
        try expectSnapshotHeader(lines, "# repository=", "https://www.wikidata.org");
        try expectSnapshotHeader(lines, "# profile=", if (terms) "resolved-default-terms-v1" else "complete-entities-v1");
    }

    fn loadWikibasePageLinks(self: *Provider) !void {
        var mapped = (try self.mapOptional("wikibase-page-links.tsv")) orelse return;
        errdefer mapped.deinit();
        self.wikibase_page_links = try parseWikibasePageLinks(self.a, mapped.bytes);
        self.wikibase_page_links_storage = mapped;
    }

    fn loadWikibaseEntities(self: *Provider) !void {
        var mapped = (try self.mapOptional("wikibase-entities.tsv")) orelse return;
        errdefer mapped.deinit();
        if (!std.unicode.utf8ValidateSlice(mapped.bytes)) return error.InvalidWikibaseEntitySnapshot;
        var entries: std.StringHashMapUnmanaged(StructuredEntityRow) = .empty;
        errdefer entries.deinit(self.a);
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        try self.structuredHeaders(&lines, false);
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const row = try structuredEntityRow(line);
            if (row.source) |source| {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.a, source, .{});
                defer parsed.deinit();
                try validateEntityPayload(parsed.value, row.canonical_id);
            }
            const entry = try entries.getOrPut(self.a, row.requested_id);
            if (entry.found_existing) return error.DuplicateWikibaseEntity;
            entry.value_ptr.* = row;
        }
        self.wikibase_entities = entries;
        self.wikibase_entities_storage = mapped;
    }

    fn loadWikibaseEntityTerms(self: *Provider) !void {
        var mapped = (try self.mapOptional("wikibase-entity-terms.tsv")) orelse return;
        errdefer mapped.deinit();
        if (self.wikibase_entities_storage == null or !std.unicode.utf8ValidateSlice(mapped.bytes)) return error.InvalidWikibaseEntityTermSnapshot;
        var entries: std.StringHashMapUnmanaged(WikibaseEntityTerms) = .empty;
        errdefer entries.deinit(self.a);
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        try self.structuredHeaders(&lines, true);
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const row = try structuredEntityRow(line);
            const entity = self.wikibase_entities.get(row.requested_id) orelse return error.InvalidWikibaseEntityTermSnapshot;
            if ((row.source == null) != (entity.source == null) or !std.mem.eql(u8, row.canonical_id, entity.canonical_id)) return error.InvalidWikibaseEntityTermSnapshot;
            var value: WikibaseEntityTerms = .{ .label = null, .description = null };
            if (row.source) |source| {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.a, source, .{});
                defer parsed.deinit();
                if (parsed.value != .object or parsed.value.object.count() != 2) return error.InvalidWikibaseEntityTermSnapshot;
                value.label = try capturedTerm(arena.allocator(), parsed.value.object.get("label") orelse return error.InvalidWikibaseEntityTermSnapshot);
                value.description = try capturedTerm(arena.allocator(), parsed.value.object.get("description") orelse return error.InvalidWikibaseEntityTermSnapshot);
            }
            const entry = try entries.getOrPut(self.a, row.requested_id);
            if (entry.found_existing) return error.DuplicateWikibaseEntityTerm;
            entry.value_ptr.* = value;
        }
        self.wikibase_entity_terms = entries;
        self.wikibase_entity_terms_storage = mapped;
        self.wikibase_entity_terms_arena = arena;
    }

    fn loadDateNumbering(self: *Provider) !void {
        var mapped = (try self.mapOptional("date-numbering.tsv")) orelse return;
        defer mapped.deinit();
        self.date_numbering = try date_numbering_lib.Registry.init(self.a, mapped.bytes, self.namespace_catalog.wiki, self.namespace_catalog.dump_date, self.namespace_catalog.content_language);
    }

    fn loadLanguageNames(self: *Provider) !void {
        var mapped = (try self.mapOptional("language-names.tsv")) orelse return;
        defer mapped.deinit();
        self.language_names = try language_names_lib.Registry.init(self.a, mapped.bytes, self.namespace_catalog.wiki, self.namespace_catalog.dump_date, self.namespace_catalog.content_language);
    }

    fn loadLanguageFallbacks(self: *Provider) !void {
        var mapped = (try self.mapOptional("language-fallbacks.tsv")) orelse return;
        errdefer mapped.deinit();
        if (!std.unicode.utf8ValidateSlice(mapped.bytes)) return error.InvalidLanguageFallbackSnapshot;
        var entries: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        errdefer {
            var values = entries.valueIterator();
            while (values.next()) |list| self.a.free(list.*);
            entries.deinit(self.a);
        }
        var lines = std.mem.splitScalar(u8, mapped.bytes, '\n');
        try expectSnapshotHeader(&lines, "", "# wikidict-language-fallbacks-v1");
        try expectSnapshotHeader(&lines, "# wiki\t", self.namespace_catalog.wiki);
        try expectSnapshotHeader(&lines, "# dump-date\t", self.namespace_catalog.dump_date);
        try expectSnapshotHeader(&lines, "# content-language\t", self.namespace_catalog.content_language);
        try expectSnapshotHeader(&lines, "# mode\t", "strict");
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidLanguageFallbackSnapshot;
            const code = line[0..tab];
            if (!validLanguageCode(code)) return error.InvalidLanguageFallbackSnapshot;
            const raw = line[tab + 1 ..];
            const list = try self.a.alloc([]const u8, if (raw.len == 0) 0 else std.mem.count(u8, raw, "\t") + 1);
            errdefer self.a.free(list);
            var fields = std.mem.splitScalar(u8, raw, '\t');
            for (list, 0..) |*fallback, index| {
                fallback.* = fields.next().?;
                if (!validLanguageCode(fallback.*) or std.mem.eql(u8, code, fallback.*)) return error.InvalidLanguageFallbackSnapshot;
                for (list[0..index]) |previous| if (std.mem.eql(u8, previous, fallback.*)) return error.InvalidLanguageFallbackSnapshot;
            }
            const entry = try entries.getOrPut(self.a, code);
            if (entry.found_existing) return error.DuplicateLanguageFallback;
            entry.value_ptr.* = list;
        }
        self.language_fallbacks = entries;
        self.language_fallbacks_storage = mapped;
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

    fn loadTitleMagicWords(self: *Provider) !void {
        var mapped = (try self.mapOptional("magic-words.tsv")) orelse return;
        defer mapped.deinit();
        self.title_magic_words = try magic_words.Registry.init(
            self.a,
            mapped.bytes,
            self.namespace_catalog.wiki,
            self.namespace_catalog.dump_date,
            self.namespace_catalog.content_language,
        );
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
        const title = try self.namespace_catalog.normalizeTitle(std.heap.smp_allocator, raw_title, 0, .any);
        defer std.heap.smp_allocator.free(title);
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
            if (try self.transclusionRedirectTarget(current)) |target| {
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
            lua_program.work_stats.logLine("warning: transclusion body failed: title={s} page_id={d} error={s}\n", .{ page.title, page.page_id, @errorName(err) });
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

    fn loadPageRedirects(self: *Provider) !void {
        var mapped = (try self.mapOptional("page-redirects.tsv")) orelse return;
        errdefer mapped.deinit();
        self.page_redirects = try page_redirects_lib.Snapshot.init(self.a, mapped.bytes, self.namespace_catalog);
        self.page_redirects_storage = mapped;
    }

    fn redirectTarget(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        if (try self.findPage(title)) |page| {
            const xml_target = page.redirect orelse return null;
            const snapshot = if (self.page_redirects) |*value| value else return error.PageRedirectSnapshotMissing;
            const target = try snapshot.lookup(a, page.page_id, xml_target);
            defer a.free(target.interwiki);
            defer a.free(target.fragment);
            if (target.fragment.len == 0) return target.title;
            defer a.free(target.title);
            return try std.fmt.allocPrint(a, "{s}#{s}", .{ target.title, target.fragment });
        }
        // Supplemental redirects absent from the selected XML have explicit
        // captured targets. Ordinary transclusion routing remains title-only.
        return try self.transclusionRedirectTarget(title);
    }

    fn pageMetadata(ctx: ?*anyopaque, title: []const u8) anyerror!?lua_program.WikitextProvider.PageMetadata {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const page = (try self.findPage(title)) orelse return null;
        return .{ .page_id = page.page_id, .revision_id = page.revision_id, .revision_timestamp = page.revision_timestamp, .revision_user = page.revision_user, .content_model = page.content_model };
    }

    fn externalData(ctx: ?*anyopaque, title: []const u8) anyerror!?ExternalData {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        if (self.external_data.getPtr(title)) |entry| return entry.*;
        // JsonConfig normalizes ASCII spaces and underscores to the same title
        // key. Captured Commons titles use spaces (and are bounded to 512 bytes).
        // Keep the original query in diagnostics and borrow only snapshot data.
        if (title.len <= 512 and std.mem.indexOfScalar(u8, title, '_') != null) {
            var spaced: [512]u8 = undefined;
            @memcpy(spaced[0..title.len], title);
            std.mem.replaceScalar(u8, spaced[0..title.len], '_', ' ');
            if (self.external_data.getPtr(spaced[0..title.len])) |entry| return entry.*;
        }
        lua_program.work_stats.logLine("warning: Commons data snapshot missing: title={s}\n", .{title});
        return error.CommonsDataSnapshotMissing;
    }

    fn categoryStats(ctx: ?*anyopaque, db_key: []const u8) anyerror!?CategoryStats {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.category_stats.get(db_key);
    }

    fn interfaceMessage(ctx: ?*anyopaque, a: A, language: []const u8, key: []const u8) anyerror!?InterfaceMessage {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const lookup_key = try messageLookupKey(a, language, key);
        defer a.free(lookup_key);
        const entry = self.interface_messages.get(lookup_key) orelse {
            const normalized = lookup_key[language.len + 1 ..];
            lua_program.work_stats.logLine("interface message missing: language={s} key={s}\n", .{ language[0..@min(language.len, 128)], normalized[0..@min(normalized.len, 256)] });
            return error.InterfaceMessageSnapshotMissing;
        };
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

    fn normalizeFileTitle(self: *const Provider, a: A, raw_title: []const u8) ![]u8 {
        const title = try self.namespace_catalog.normalizeTitle(a, raw_title, 0, .any);
        const ns = self.namespace_catalog.ofTitle(title);
        if (ns.id == 6) return title;
        defer a.free(title);
        if (ns.id != -2) return error.InvalidFileMetadataTitle;
        return self.namespace_catalog.normalizeTitle(a, ns.text, 6, .literal);
    }

    fn fileMetadata(ctx: ?*anyopaque, raw_title: []const u8) anyerror!FileMetadata {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const title = try self.normalizeFileTitle(std.heap.smp_allocator, raw_title);
        defer std.heap.smp_allocator.free(title);
        return self.file_metadata.get(title) orelse {
            lua_program.work_stats.logLine("warning: file metadata missing: title={s}\n", .{title});
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

    fn wikibasePageEntityId(ctx: ?*anyopaque, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const page = (try self.findPage(title)) orelse return error.WikibasePageLinkSnapshotMissing;
        // Sparse SQL proves positive links only. Nil requires an explicit
        // captured repository-negative row, never an uncovered map entry.
        return (self.wikibase_page_links.getPtr(page.page_id) orelse return error.WikibasePageLinkSnapshotMissing).*;
    }

    fn wikibaseEntity(ctx: ?*anyopaque, entity_id: []const u8) anyerror!WikibaseEntity {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        const entry = self.wikibase_entities.get(entity_id) orelse return error.WikibaseEntitySnapshotMissing;
        var parsed: ?*const std.json.Value = null;
        if (entry.source) |source| if (entity_id[0] == 'Q' or entity_id[0] == 'P') {
            if (self.wikibase_entity_cache == null and !self.wikibase_entity_cache_disabled) {
                self.wikibase_entity_cache = WikibaseEntityCache.create(std.heap.smp_allocator, WikibaseEntityCache.max_bytes, WikibaseEntityCache.max_entries) catch blk: {
                    self.wikibase_entity_cache_disabled = true;
                    break :blk null;
                };
            }
            if (self.wikibase_entity_cache) |cache| parsed = cache.lookupOrAdmit(source);
        };
        return .{
            .source = entry.source,
            .parsed = parsed,
            .parsed_numbers_validated = parsed != null,
        };
    }

    fn wikibaseEntityTerms(ctx: ?*anyopaque, entity_id: []const u8) anyerror!WikibaseEntityTerms {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.wikibase_entity_terms.get(entity_id) orelse error.WikibaseEntityTermSnapshotMissing;
    }

    fn dateNumbering(ctx: ?*anyopaque, code: []const u8) anyerror!lua_program.WikitextProvider.DateNumbering {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return (self.date_numbering orelse return error.DateNumberingSnapshotMissing).lookup(code);
    }

    fn languageNames(ctx: ?*anyopaque, display: ?[]const u8, scope: lua_program.WikitextProvider.LanguageNameScope) anyerror![]const lua_program.WikitextProvider.LanguageNameRow {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return (self.language_names orelse return error.LanguageNameSnapshotMissing).names(display, scope);
    }
    fn languageName(ctx: ?*anyopaque, code: []const u8, display: ?[]const u8) anyerror![]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return (self.language_names orelse return error.LanguageNameSnapshotMissing).name(code, display);
    }
    fn languageDirection(ctx: ?*anyopaque, code: []const u8) anyerror!lua_program.WikitextProvider.LanguageDirection {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return (self.language_names orelse return error.LanguageDirectionSnapshotMissing).direction(code);
    }

    fn languageFallbacks(ctx: ?*anyopaque, code: []const u8) anyerror![]const []const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.language_fallbacks.get(code) orelse {
            lua_program.work_stats.logLine("language fallback missing: language={s}\n", .{code[0..@min(code.len, 128)]});
            return error.LanguageFallbackSnapshotMissing;
        };
    }

    fn languageKnownTag(ctx: ?*anyopaque, code: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.language_registry.contains(code);
    }

    fn resolveTitleMagic(ctx: ?*anyopaque, alias: []const u8, form: magic_words.Form) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return (self.title_magic_words orelse return error.MissingMagicWordsSnapshot).resolve(alias, form);
    }

    fn resolveParserFunction(ctx: ?*anyopaque, alias: []const u8) anyerror!?[]const u8 {
        return resolveTitleMagic(ctx, alias, .parser_function);
    }

    fn get(ctx: ?*anyopaque, a: A, title: []const u8) anyerror!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        return self.lookup(a, title, true);
    }

    fn exists(ctx: ?*anyopaque, title: []const u8) anyerror!bool {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return error.MissingPageProvider));
        if (try self.transclusionRedirectTarget(title) != null) return true;
        if (self.namespace_catalog.ofTitle(title).id == -2) {
            if (!self.file_metadata_available) {
                lua_program.work_stats.logLine("warning: file metadata snapshot unavailable: title={s}\n", .{title});
                return error.FileMetadataSnapshotMissing;
            }
            return (try fileMetadata(ctx, title)).exists;
        }
        return (try self.lookup(self.a, title, false)) != null;
    }
};

test "Commons provider separates present captured missing and uncaptured titles" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const catalog = try lua_program.namespace_registry.englishTestRegistry();
    const tabular = "{\"schema\":{\"fields\":[{\"name\":\"key\",\"type\":\"string\"}]},\"data\":[[\"value\"]]}";
    const snapshots = [_][]const u8{
        "# wikidict-commons-data-v1\nPresent.tab\tTabular.JsonConfig\t" ++ tabular ++ "\n" ++
            "Unicode data/emoji images/000.tab\tTabular.JsonConfig\t" ++ tabular ++ "\n",
        "# wikidict-commons-data-v2\nPresent.tab\tpresent\tTabular.JsonConfig\t" ++ tabular ++ "\n" ++
            "Unicode data/emoji images/000.tab\tpresent\tTabular.JsonConfig\t" ++ tabular ++ "\n" ++
            "Unicode data/emoji images/00A.tab\tmissing\t\t\n",
    };
    for (snapshots, 0..) |bytes, index| {
        try tmp.dir.writeFile(io, .{ .sub_path = "commons-data.tsv", .data = bytes });
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        const get = provider.api().external_data orelse return error.TestExpectedEqual;
        const present = (try get(&provider, "Present.tab")) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("Tabular.JsonConfig", present.content_model);
        try std.testing.expectEqualStrings(tabular, present.source);
        const canonical = (try get(&provider, "Unicode data/emoji images/000.tab")) orelse return error.TestExpectedEqual;
        const underscored = (try get(&provider, "Unicode data/emoji_images/000.tab")) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(canonical.content_model, underscored.content_model);
        try std.testing.expectEqualStrings(canonical.source, underscored.source);
        try std.testing.expect(canonical.source.ptr == underscored.source.ptr);
        const all_underscored = (try get(&provider, "Unicode_data/emoji_images/000.tab")) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(tabular, all_underscored.source);
        // A temporary lookup key must never replace the mapped payload bytes.
        try std.testing.expectEqualStrings(tabular, underscored.source);
        if (index == 1) {
            // Existing mw.ext.data.get maps this explicit provider null to false.
            try std.testing.expect((try get(&provider, "Unicode data/emoji images/00A.tab")) == null);
            try std.testing.expect((try get(&provider, "Unicode data/emoji_images/00A.tab")) == null);
        } else {
            try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Unicode data/emoji images/00A.tab"));
            try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Unicode data/emoji_images/00A.tab"));
        }
        try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Never queried.tab"));
        try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Never_queried.tab"));
        try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Unicode data/emoji_images/00b.tab"));
        try std.testing.expectError(error.CommonsDataSnapshotMissing, get(&provider, "Unicode data/Emoji_images/000.tab"));
    }
}

test "Commons provider rejects malformed or ambiguous negative records" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const catalog = try lua_program.namespace_registry.englishTestRegistry();
    const Case = struct { bytes: []const u8, expected_error: anyerror };
    const cases = [_]Case{
        .{ .bytes = "# wikidict-commons-data-v999\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "Missing.tab\tmissing\t\t\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v1\nMissing.tab\t\t\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nMissing.tab\tunknown\t\t\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nMissing.tab\tmissing\tTabular.JsonConfig\t{}\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nMissing.tab\tmissing\t\t{}\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nMissing.tab\tmissing\t\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nMissing.tab\tmissing\t\t\textra\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\n\tmissing\t\t\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nPresent.tab\tpresent\t\t{}\n", .expected_error = error.InvalidExternalDataSnapshot },
        .{ .bytes = "# wikidict-commons-data-v2\nBoth.tab\tpresent\tTabular.JsonConfig\t{}\nBoth.tab\tmissing\t\t\n", .expected_error = error.DuplicateExternalData },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "commons-data.tsv", .data = case.bytes });
        try std.testing.expectError(case.expected_error, Provider.init(io, a, root, catalog, "unused-dump.xml"));
    }
}

test "title magic provider loads optional snapshots and enforces edition identity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const namespaces = try lua_program.namespace_registry.englishTestRegistry();
    {
        var provider = try Provider.init(io, a, root, namespaces, "unused-dump.xml");
        defer provider.deinit();
        try std.testing.expect(provider.api().resolve_title_magic == null);
    }
    const snapshot = try std.fs.path.join(a, &.{ root, "magic-words.tsv" });
    defer a.free(snapshot);
    const bytes = try std.fmt.allocPrint(a, "{s}\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\npagename\t1\tPAGENAME\n", .{ magic_words.header, namespaces.wiki, namespaces.dump_date, namespaces.content_language });
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot, .data = bytes });
    {
        var provider = try Provider.init(io, a, root, namespaces, "unused-dump.xml");
        defer provider.deinit();
        const resolve = provider.api().resolve_title_magic orelse return error.TestExpectedEqual;
        try std.testing.expect(provider.api().resolve_parser_function == null);
        try std.testing.expectEqualStrings("pagename", (try resolve(&provider, "PAGENAME", .variable)).?);
        try std.testing.expect(try resolve(&provider, "pagename", .variable) == null);
    }
    const expanded = try std.fmt.allocPrint(a, "{s}\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\npagename\t1\tPAGENAME\ninvoke\t0\tاستدعاء\n", .{ magic_words.parser_header, namespaces.wiki, namespaces.dump_date, namespaces.content_language });
    defer a.free(expanded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot, .data = expanded });
    {
        var provider = try Provider.init(io, a, root, namespaces, "unused-dump.xml");
        defer provider.deinit();
        const resolve = provider.api().resolve_parser_function orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("#invoke", (try resolve(&provider, "#استدعاء")).?);
        try std.testing.expect(try resolve(&provider, "#invoke") == null);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot, .data = magic_words.header ++ "\n# wiki\totherwiktionary\n# dump-date\t20261001\n# content-language\ten\npagename\t1\tPAGENAME\n" });
    try std.testing.expectError(error.MagicWordsIdentityMismatch, Provider.init(io, a, root, namespaces, "unused-dump.xml"));
}

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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), dump_path);
    defer provider.deinit();
    try std.testing.expect(try Provider.exists(&provider, "User:Example/helper"));
    try std.testing.expectEqualStrings("Template:Target", (try Provider.redirectTarget(&provider, a, "User:Example/helper")).?);
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), dump_path);
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

test "partial Wikibase page links reject malformed coverage and free failed allocations" {
    const header = "# wikidict-wikibase-page-links-v1\tpartial\n";
    const ParseProbe = struct {
        fn run(a: A) !void {
            var links = try parseWikibasePageLinks(a, "# wikidict-wikibase-page-links-v1\tpartial\n1\tQ1\n2\t-\n# end\t2\n");
            defer links.deinit(a);
            try std.testing.expectEqualStrings("Q1", links.getPtr(1).?.*.?);
            try std.testing.expect(links.getPtr(2).?.* == null);
            try std.testing.expect(links.getPtr(3) == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ParseProbe.run, .{});
    inline for (.{
        "1\tQ1\n",
        "1\tQ1\n# end\t0\n",
        "1\tQ1\n# end\t1",
        "1\tQ1\n# end\t1\nextra\n",
        "1\tQ1\n1\tQ2\n# end\t2\n",
        "2\tQ1\n1\tQ2\n# end\t2\n",
        "01\tQ1\n# end\t1\n",
        "0\tQ1\n# end\t1\n",
        "1\tQ0\n# end\t1\n",
        "1\tL1\n# end\t1\n",
        "1\tq1\n# end\t1\n",
        "1\t\n# end\t1\n",
        "1\tQ1\textra\n# end\t1\n",
    }) |tail| try std.testing.expectError(error.InvalidWikibasePageLinkSnapshot, parseWikibasePageLinks(std.testing.allocator, header ++ tail));
    var empty = try parseWikibasePageLinks(std.testing.allocator, header ++ "# end\t0\n");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), empty.count());
}

test "provider page links resolve page IDs and preserve explicit negative versus uncovered" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const dump_path = try std.fs.path.join(a, &.{ root, "dump.xml" });
    defer a.free(dump_path);
    const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(index_path);
    const links_path = try std.fs.path.join(a, &.{ root, "wikibase-page-links.tsv" });
    defer a.free(links_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = "abc" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t1\tLinked\t\t1\t11\t2024-01-01T00:00:00Z\tEditor\twikitext\t0\t1\t0\n" ++
        "1\t1\tUnlinked\t\t2\t22\t2024-01-01T00:00:00Z\tEditor\twikitext\t0\t1\t0\n" ++
        "2\t1\tUncovered\t\t3\t33\t2024-01-01T00:00:00Z\tEditor\twikitext\t0\t1\t0\n" });
    {
        var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), dump_path);
        defer provider.deinit();
        try std.testing.expect(provider.api().wikibase_page_entity_id == null);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = links_path, .data = "# wikidict-wikibase-page-links-v1\tpartial\n1\tQ1\n2\t-\n# end\t2\n" });
    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), dump_path);
    defer provider.deinit();
    const get = provider.api().wikibase_page_entity_id.?;
    try std.testing.expectEqualStrings("Q1", (try get(&provider, "Linked")).?);
    try std.testing.expect((try get(&provider, "Unlinked")) == null);
    try std.testing.expectError(error.WikibasePageLinkSnapshotMissing, get(&provider, "Uncovered"));
    try std.testing.expectError(error.WikibasePageLinkSnapshotMissing, get(&provider, "Unknown"));
}

const entity_test_headers = "# wikidict-wikibase-entities-v1\n# wiki=enwiktionary\n# date=20261001\n# content-language=en\n# repository=https://www.wikidata.org\n# profile=complete-entities-v1\n";
const terms_test_headers = "# wikidict-wikibase-entity-terms-v1\n# wiki=enwiktionary\n# date=20261001\n# content-language=en\n# repository=https://www.wikidata.org\n# profile=resolved-default-terms-v1\n";
const fallback_test_headers = "# wikidict-language-fallbacks-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n# mode\tstrict\n";
const message_test_headers = "# wikidict-interface-messages-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n";

test "provider structured entities preserve redirects missing records resolved terms and strict fallbacks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entities.tsv", .data = entity_test_headers ++
        "L1\tE\tL1\t{\"id\":\"L1\",\"type\":\"lexeme\",\"schemaVersion\":2,\"lemmas\":{\"en\":{\"language\":\"en\",\"value\":\"word\"}}}\n" ++
        "L2\tE\tL1\t{\"id\":\"L1\",\"type\":\"lexeme\",\"schemaVersion\":2}\n" ++
        "Q1\tE\tQ1\t{\"id\":\"Q1\",\"type\":\"item\",\"schemaVersion\":2}\nL9\tM\t\t\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entity-terms.tsv", .data = terms_test_headers ++
        "Q1\tE\tQ1\t{\"label\":{\"value\":\"caf\\u00e9\",\"language\":\"fr\",\"source-language\":\"fr\"},\"description\":null}\nL9\tM\t\t\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "language-fallbacks.tsv", .data = fallback_test_headers ++ "en\t\nfr\tde\ten\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "interface-messages.tsv", .data = message_test_headers ++ "en\tComma-separator\tV\t, \\t\n" ++ "en\tmissing\tM\n" });
    {
        var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
        defer provider.deinit();
        const api = provider.api();
        const get = api.wikibase_entity.?;
        try std.testing.expect(std.mem.indexOf(u8, (try get(&provider, "L2")).source.?, "\"id\":\"L1\"") != null);
        try std.testing.expect((try get(&provider, "L9")).source == null);
        try std.testing.expectError(error.WikibaseEntitySnapshotMissing, get(&provider, "L404"));
        const term = (try api.wikibase_entity_terms.?(&provider, "Q1")).label.?;
        try std.testing.expectEqualStrings("café", term.value);
        try std.testing.expectEqualStrings("fr", term.language);
        try std.testing.expectEqualStrings("fr", term.source_language.?);
        try std.testing.expect((try api.wikibase_entity_terms.?(&provider, "L9")).label == null);
        try std.testing.expectError(error.WikibaseEntityTermSnapshotMissing, api.wikibase_entity_terms.?(&provider, "L1"));
        try std.testing.expectEqual(@as(usize, 0), (try api.language_fallbacks.?(&provider, "en")).len);
        const fallbacks = try api.language_fallbacks.?(&provider, "fr");
        try std.testing.expectEqual(@as(usize, 2), fallbacks.len);
        try std.testing.expectEqualStrings("de", fallbacks[0]);
        try std.testing.expectEqualStrings("en", fallbacks[1]);
        try std.testing.expectError(error.LanguageFallbackSnapshotMissing, api.language_fallbacks.?(&provider, "ar"));
        const message = (try api.interface_message.?(&provider, a, "en", "Comma-separator")).?;
        defer a.free(message.source.?);
        try std.testing.expectEqualStrings(", \t", message.source.?);
        try std.testing.expect((try api.interface_message.?(&provider, a, "en", "Missing")).?.source == null);
        try std.testing.expectError(error.InterfaceMessageSnapshotMissing, api.interface_message.?(&provider, a, "en", "Unknown"));
    }
    try std.testing.checkAllAllocationFailures(a, struct {
        fn load(backing: A, directory: []const u8) !void {
            // JSON arenas can grow in place depending on the backing heap's
            // layout. Disable resizing so the exhaustive allocation sweep has
            // the same allocation points in its baseline and failing runs.
            var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
            var provider = try Provider.init(std.testing.io, no_resize.allocator(), directory, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
            defer provider.deinit();
        }
    }.load, .{root});
}

test "provider parsed backing survives relocation preserves Q redirects and bypasses capped admission" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entities.tsv", .data = entity_test_headers ++
        "Q1\tE\tQ1\t{\"id\":\"Q1\",\"type\":\"item\",\"schemaVersion\":2,\"labels\":{\"en\":{\"value\":\"first\"}}}\n" ++
        "Q2\tE\tQ1\t{\"id\":\"Q1\",\"type\":\"item\",\"schemaVersion\":2,\"labels\":{\"en\":{\"value\":\"redirect row\"}}}\n" ++
        "P1\tE\tP1\t{\"id\":\"P1\",\"type\":\"property\",\"schemaVersion\":2}\n" ++
        "L1\tE\tL1\t{\"id\":\"L1\",\"type\":\"lexeme\",\"schemaVersion\":2}\nQ9\tM\t\t\n" });
    var provider = try struct {
        fn relocated(allocator: A, directory: []const u8) !Provider {
            var original = try Provider.init(std.testing.io, allocator, directory, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
            errdefer original.deinit();
            _ = try Provider.wikibaseEntity(&original, "Q1");
            return original;
        }
    }.relocated(a, root);
    defer provider.deinit();
    const first = try Provider.wikibaseEntity(&provider, "Q1");
    try std.testing.expect(first.parsed != null and first.parsed_numbers_validated);
    try std.testing.expect((try Provider.wikibaseEntity(&provider, "Q1")).parsed.? == first.parsed.?);
    const redirect = try Provider.wikibaseEntity(&provider, "Q2");
    try std.testing.expect(redirect.parsed.? != first.parsed.?);
    try std.testing.expectEqualStrings("redirect row", redirect.parsed.?.object.get("labels").?.object.get("en").?.object.get("value").?.string);
    try std.testing.expect((try Provider.wikibaseEntity(&provider, "P1")).parsed != null);
    const lexeme = try Provider.wikibaseEntity(&provider, "L1");
    try std.testing.expect(lexeme.parsed == null and !lexeme.parsed_numbers_validated);
    const missing = try Provider.wikibaseEntity(&provider, "Q9");
    try std.testing.expect(missing.source == null and missing.parsed == null and !missing.parsed_numbers_validated);
    try std.testing.expectError(error.WikibaseEntitySnapshotMissing, Provider.wikibaseEntity(&provider, "Q404"));
    provider.wikibase_entity_cache.?.destroy();
    provider.wikibase_entity_cache = null;
    provider.wikibase_entity_cache = try WikibaseEntityCache.create(a, @sizeOf(WikibaseEntityCache), WikibaseEntityCache.max_entries);
    const raw = try Provider.wikibaseEntity(&provider, "Q1");
    try std.testing.expect(raw.parsed == null and !raw.parsed_numbers_validated);
    try std.testing.expectEqualStrings(first.source.?, raw.source.?);
    try std.testing.expect((try Provider.wikibaseEntity(&provider, "Q1")).parsed == null);
    try std.testing.expectEqual(@as(u64, 1), provider.wikibase_entity_cache.?.allocation_bypasses);
}

test "structured entity provider rejects inconsistent identity duplicate rows and payloads" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const cases = .{
        .{ entity_test_headers ++ "Q1\tE\tQ1\t{\"id\":\"Q2\",\"type\":\"item\",\"schemaVersion\":2}\n", error.InvalidWikibaseEntitySnapshot },
        .{ entity_test_headers ++ "Q1\tM\tQ1\t\n", error.InvalidWikibaseEntitySnapshot },
        .{ entity_test_headers ++ "Q1\tM\t\t\nQ1\tM\t\t\n", error.DuplicateWikibaseEntity },
        .{ "# wikidict-wikibase-entities-v1\n# wiki=arwiktionary\n", error.InvalidSnapshotIdentity },
    };
    inline for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entities.tsv", .data = case[0] });
        try std.testing.expectError(case[1], Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml"));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entities.tsv", .data = entity_test_headers ++ "Q1\tM\t\t\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wikibase-entity-terms.tsv", .data = terms_test_headers ++ "Q1\tE\tQ1\t{\"label\":null,\"description\":null}\n" });
    try std.testing.expectError(error.InvalidWikibaseEntityTermSnapshot, Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml"));
}

test "provider message key normalization preserves suffix case and rejects duplicate aliases" {
    const a = std.testing.allocator;
    const normalized = try messageLookupKey(a, "ar", "A mixedCase");
    defer a.free(normalized);
    try std.testing.expectEqualStrings("ar\ta_mixedCase", normalized);
    try std.testing.expectError(error.UnsupportedInterfaceMessageKey, messageLookupKey(a, "ar", "أ"));
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "interface-messages.tsv", .data = message_test_headers ++ "ar\tAnd\tV\tو\nar\tand\tV\tو\n" });
    try std.testing.expectError(error.DuplicateInterfaceMessage, Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml"));
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
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

    var provider = try Provider.init(io, a, root, try lua_program.namespace_registry.englishTestRegistry(), "unused-dump.xml");
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

test "file metadata normalizes edition aliases and frees owned keys on failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const snapshot_path = try std.fs.path.join(a, &.{ root, "file-metadata.tsv" });
    defer a.free(snapshot_path);
    var registry = try lua_program.namespace_registry.Registry.init(a, lua_program.namespace_registry.french_test_fixture);
    defer registry.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "Image:Example.svg\t1\t640\t480\nFichier:Missing.svg\t0\t0\t0\n",
    });
    {
        var provider = try Provider.init(io, a, root, &registry, "unused-dump.xml");
        defer provider.deinit();
        const get = provider.api().file_metadata orelse return error.TestExpectedEqual;
        for ([_][]const u8{ "Fichier:Example.svg", "File:Example.svg", "Image:Example.svg", "Média:Example.svg", "Media:Example.svg" }) |title| {
            const metadata = try get(&provider, title);
            try std.testing.expect(metadata.exists);
            try std.testing.expectEqual(@as(u32, 640), metadata.width);
            try std.testing.expectEqual(@as(u32, 480), metadata.height);
        }
        try std.testing.expect(try Provider.exists(&provider, "Média:Example.svg"));
        try std.testing.expect(try Provider.exists(&provider, "Media:Example.svg"));
        try std.testing.expect(!try Provider.exists(&provider, "Média:Missing.svg"));
        try std.testing.expect(!try Provider.exists(&provider, "Media:Missing.svg"));
        try std.testing.expectError(error.FileMetadataSnapshotMissing, get(&provider, "Fichier:Unknown.svg"));
        try std.testing.expectError(error.FileMetadataSnapshotMissing, Provider.exists(&provider, "Média:Unknown.svg"));
    }
    try std.testing.checkAllAllocationFailures(a, struct {
        fn load(backing: A, directory: []const u8, catalog: *const lua_program.namespace_registry.Registry) !void {
            var provider = try Provider.init(std.testing.io, backing, directory, catalog, "unused-dump.xml");
            defer provider.deinit();
            try std.testing.expect((try Provider.fileMetadata(&provider, "File:Example.svg")).exists);
        }
    }.load, .{ root, &registry });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "Fichier:Example.svg\t1\t640\t480\nFile:Example.svg\t1\t640\t480\n",
    });
    try std.testing.expectError(error.DuplicateFileMetadata, Provider.init(io, a, root, &registry, "unused-dump.xml"));
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = snapshot_path,
        .data = "Catégorie:Example.svg\t1\t640\t480\n",
    });
    try std.testing.expectError(error.InvalidFileMetadataTitle, Provider.init(io, a, root, &registry, "unused-dump.xml"));
    try std.Io.Dir.cwd().deleteFile(io, snapshot_path);
    var unavailable = try Provider.init(io, a, root, &registry, "unused-dump.xml");
    defer unavailable.deinit();
    try std.testing.expect(unavailable.api().file_metadata == null);
    try std.testing.expectError(error.FileMetadataSnapshotMissing, Provider.exists(&unavailable, "Média:Example.svg"));
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

    const namespaces = try lua_program.namespace_registry.englishTestRegistry();
    const redirects_path = try std.fs.path.join(a, &.{ root, "page-redirects.tsv" });
    defer a.free(redirects_path);
    // This fixture explicitly supplies the SQL identity of page 3's redirect,
    // including the known empty fragment; XML alone does not prove that field.
    const redirects = try std.fmt.allocPrint(a, "# wikidict-page-redirects-v1\n# wiki\t{s}\n# dump-date\t{s}\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n3\t10\t4c617a79\t\t\n# end\t1\n", .{ namespaces.wiki, namespaces.dump_date });
    defer a.free(redirects);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = redirects_path, .data = redirects });

    const caller_root = try a.dupe(u8, root);
    defer a.free(caller_root);
    var provider = try Provider.init(io, a, caller_root, namespaces, dump_path);
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
    try std.testing.expectEqualStrings("Template:Lazy", (try Provider.redirectTarget(&provider, page_a, "Template:Alias")).?);
    try std.testing.expect((try Provider.redirectTarget(&provider, page_a, "Template:Lazy")) == null);
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
    var provider: Provider = .{ .io = std.testing.io, .a = std.testing.allocator, .root = "", .namespace_catalog = try lua_program.namespace_registry.englishTestRegistry() };
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
    var provider: Provider = .{ .io = std.testing.io, .a = std.testing.allocator, .root = "", .namespace_catalog = try lua_program.namespace_registry.englishTestRegistry(), .source_cache_limit_bytes = 2 };
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

test "provider exposes immutable date numbering and distinguishes absent unsupported and foreign captures" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const catalog = try lua_program.namespace_registry.englishTestRegistry();
    {
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        try std.testing.expect(provider.api().date_numbering == null);
    }
    const path = try std.fs.path.join(a, &.{ root, "date-numbering.tsv" });
    defer a.free(path);
    const bytes = try std.fmt.allocPrint(a, "# wikidict-date-numbering-v1\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\n# timezone\tUTC\n# profiles\t2\n" ++
        "D\tbn\t০\t১\t২\t৩\t৪\t৫\t৬\t৭\t৮\t৯\n" ++
        "U\tzz\traw-control-mismatch\n", .{ catalog.wiki, catalog.dump_date, catalog.content_language });
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    {
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        const api = provider.api();
        const profile = try api.date_numbering.?(&provider, "bn");
        try std.testing.expectEqualStrings("০", profile.digits[0]);
        try std.testing.expectEqualStrings("UTC", profile.timezone);
        try std.testing.expectError(error.DateNumberingUnsupported, api.date_numbering.?(&provider, "zz"));
        try std.testing.expectError(error.DateNumberingSnapshotMissing, api.date_numbering.?(&provider, "en"));
        // The reader owns its source: replacing the mapped input cannot alter it.
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "# wikidict-date-numbering-v1\n# wiki\tforeignwiktionary\n" });
        try std.testing.expectEqualStrings("৯", (try api.date_numbering.?(&provider, "bn")).digits[9]);
    }
    try std.testing.expectError(error.InvalidDateNumberingSnapshot, Provider.init(io, a, root, catalog, "unused-dump.xml"));
}

test "provider exposes captured language profiles with exact single aliases and explicit direction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const catalog = try lua_program.namespace_registry.englishTestRegistry();
    {
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        try std.testing.expect(provider.api().language_names == null);
        try std.testing.expect(provider.api().language_name == null);
        try std.testing.expect(provider.api().language_direction == null);
    }
    const path = try std.fs.path.join(a, &.{ root, "language-names.tsv" });
    defer a.free(path);
    const bytes = try std.fmt.allocPrint(a, "# wikidict-language-names-v1\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\n" ++
        "C\tar\tall\t2\nN\tar\tall\tar\tالعربية\nN\tar\tall\tals\tAlemannic\n" ++
        "C\tar\tsingle\t2\nN\tar\tsingle\tar\tالعربية\nN\tar\tsingle\tals\tالألمانية السويسرية\n" ++
        "C\t-\tdir\t2\nD\tar\trtl\nD\ten\tltr\n", .{ catalog.wiki, catalog.dump_date, catalog.content_language });
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
    defer provider.deinit();
    const api = provider.api();
    try std.testing.expectEqualStrings("Alemannic", (try api.language_names.?(&provider, "ar", .all))[1].name);
    try std.testing.expectEqualStrings("الألمانية السويسرية", try api.language_name.?(&provider, "als", "ar"));
    try std.testing.expectEqualStrings("", try api.language_name.?(&provider, "unknown", "ar"));
    try std.testing.expectEqual(lua_program.WikitextProvider.LanguageDirection.rtl, try api.language_direction.?(&provider, "ar"));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, api.language_names.?(&provider, "fr", .all));
    try std.testing.expectError(error.LanguageDirectionSnapshotMissing, api.language_direction.?(&provider, "unknown"));
}

test "provider exposes exact site server and rejects a different captured edition" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const catalog = try lua_program.namespace_registry.englishTestRegistry();
    {
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        try std.testing.expect(provider.api().site_server == null);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "namespace-siteinfo.raw.json", .data = "{\"query\":{\"general\":{\"wikiid\":\"enwiktionary\",\"lang\":\"en\",\"server\":\"https://captured.example:8443\"}}}" });
    {
        var provider = try Provider.init(io, a, root, catalog, "unused-dump.xml");
        defer provider.deinit();
        try std.testing.expectEqualStrings("https://captured.example:8443", provider.api().site_server.?);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "namespace-siteinfo.raw.json", .data = "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\"}}}" });
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Provider.init(io, a, root, catalog, "unused-dump.xml"));
}

test "file metadata v2 owns canonical AUDIO identity and rejects malformed rows" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "file-metadata.tsv" });
    defer a.free(path);
    const registry = try lua_program.namespace_registry.englishTestRegistry();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "# wikidict-file-metadata-v2\nFile:Alias.ogg\t1\t0\t0\tAUDIO\tFile:Actual.ogg\nFile:Gone.ogg\t0\t0\t0\t-\t-\n",
    });
    {
        var provider = try Provider.init(io, a, root, registry, "unused-dump.xml");
        defer provider.deinit();
        const metadata = try Provider.fileMetadata(&provider, "File:Alias.ogg");
        try std.testing.expectEqual(FileMetadata.MediaType.AUDIO, metadata.media_type.?);
        try std.testing.expectEqualStrings("File:Actual.ogg", metadata.canonical_title.?);
        const gone = try Provider.fileMetadata(&provider, "File:Gone.ogg");
        try std.testing.expect(!gone.exists);
        try std.testing.expect(gone.canonical_title == null and gone.media_type == null);
    }
    try std.testing.checkAllAllocationFailures(a, struct {
        fn load(backing: A, directory: []const u8, catalog: *const lua_program.namespace_registry.Registry) !void {
            var provider = try Provider.init(std.testing.io, backing, directory, catalog, "unused-dump.xml");
            defer provider.deinit();
            const metadata = try Provider.fileMetadata(&provider, "File:Alias.ogg");
            try std.testing.expectEqualStrings("File:Actual.ogg", metadata.canonical_title.?);
        }
    }.load, .{ root, registry });
    for ([_][]const u8{
        "File:Alias.ogg\t1\t0\t0\tAUDIO\tFile:Actual.ogg\n", // Undeclared v2.
        "# wikidict-file-metadata-v2\nFile:Alias.ogg\t1\t0\t0\n",
        "# wikidict-file-metadata-v2\nFile:Alias.ogg\t1\t0\t0\taudio\tFile:Actual.ogg\n",
        "# wikidict-file-metadata-v2\nFile:Gone.ogg\t0\t0\t0\tAUDIO\tFile:Gone.ogg\n",
        "# wikidict-file-metadata-v2\nFile:Alias.ogg\t1\t0\t0\tAUDIO\t-\n",
        "# wikidict-file-metadata-v2\nFile:Alias.ogg\t1\t0\t0\tAUDIO\tImage:Actual.ogg\n",
    }) |bad| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bad });
        try std.testing.expectError(error.InvalidFileMetadataSnapshot, Provider.init(io, a, root, registry, "unused-dump.xml"));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "File:Old.ogg\t1\t0\t0\n" });
    var legacy = try Provider.init(io, a, root, registry, "unused-dump.xml");
    defer legacy.deinit();
    const old = try Provider.fileMetadata(&legacy, "File:Old.ogg");
    try std.testing.expect(old.exists and old.media_type == null and old.canonical_title == null);
}

test "provider redirect metadata requires SQL fragments while transclusion stays title only" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dump_path = try std.fs.path.join(pa, &.{ root, "dump.xml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = "target body" });
    const index_path = try std.fs.path.join(pa, &.{ root, "page-index.tsv" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tTemplate:Alias\tTemplate:Target\t1\t11\t2026-10-01T00:00:00Z\tUser\twikitext\t10\t1\t0\n" ++
        "0\t11\tTemplate:Target\t\t2\t12\t2026-10-01T00:00:00Z\tUser\twikitext\t10\t1\t0\n" });
    const namespaces = try lua_program.namespace_registry.englishTestRegistry();
    {
        var provider = try Provider.init(io, a, root, namespaces, dump_path);
        defer provider.deinit();
        try std.testing.expectError(error.PageRedirectSnapshotMissing, Provider.redirectTarget(&provider, pa, "Template:Alias"));
        try std.testing.expect(try Provider.redirectTarget(&provider, pa, "Template:Target") == null);
    }
    const snapshot_path = try std.fs.path.join(pa, &.{ root, "page-redirects.tsv" });
    const source = try std.fmt.allocPrint(pa, "# wikidict-page-redirects-v1\n# wiki\t{s}\n# dump-date\t{s}\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n1\t10\t546172676574\t\t65cc81\n# end\t1\n", .{ namespaces.wiki, namespaces.dump_date });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snapshot_path, .data = source });
    var provider = try Provider.init(io, a, root, namespaces, dump_path);
    defer provider.deinit();
    try std.testing.expectEqualStrings("Template:Target#e\u{301}", (try Provider.redirectTarget(&provider, pa, "Template:Alias")).?);
    const body = (try Provider.getTransclusionBody(&provider, pa, "Template:Alias")).?;
    try std.testing.expectEqualStrings("Template:Target", body.title);
    try std.testing.expectEqualStrings("target body", body.text);
}
