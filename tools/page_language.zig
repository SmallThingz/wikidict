const std = @import("std");
const namespaces = @import("namespace_registry");
const prefix_parser = @import("page_language_prefix.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const invalid = error.InvalidPageLanguageSource;
pub const accepted_core = "0470f6c99a6456a366635bf25a517a1f951de6f5";
const current_core = "f45897451256aa3799aecc5d7ee320ade22beaec";
const metadata_core_714 = "7140a34a88ee294f3b4d8cda0c4f43a880410e20";

// This is a current metadata observation, not a reconstruction of the dump's
// server configuration. No language is inferred from the edition or image.
pub const Context = struct {
    namespace_sha256: [32]u8,
    title: []const u8,
    language: []const u8,
    direction: []const u8,
    observed_utc: []const u8,
    outer_languages: ?[]const []const u8 = null,
    prefix_observed_utc: ?[]const u8 = null,
};
pub const NormalContext = struct {
    source_core_revision: ?[]const u8 = null,
    normal_no_target: bool = false,
    interface_message: ?bool = null,
    target_language_override: ?[]const u8 = null,
    variant_override: ?[]const u8 = null,
};
const Page = struct {
    id: u64,
    revision: u64,
    namespace: i32,
    title: []const u8,
    model: []const u8,
    raw_sha256: []const u8,
    // Optional capture evidence. Ordinary metadata acquisition has no expanded
    // output; absence must never satisfy capturedSourceMatches.
    expanded_sha256: ?[]const u8 = null,
};
pub const max_index_bytes = 8 * 1024 * 1024;
pub const max_payload_bytes = 64 * 1024 * 1024;
const max_records = 8192;
const max_responses = 1024;
const ResponseRange = struct { offset: u64, bytes: u64, sha256: []const u8, observed_utc: []const u8 };
const Record = struct {
    page: Page,
    response_index: u32,
    response_page_index: u32,
    prefix: ?Prefix = null,
};
const Packet = struct {
    schema: []const u8,
    wiki: []const u8,
    core_revision: []const u8,
    namespace_registry_sha256: []const u8,
    historical_page_language_proven: bool,
    source_profile: V,
    responses: []const ResponseRange,
    records: []const Record,
};
const Prefix = struct {
    offset: u64,
    request_url: []const u8,
    final_url: []const u8,
    status: u16,
    observed_utc: []const u8,
    sha256: []const u8,
    receipt_sha256: []const u8,
    original_response_sha256: []const u8,
    original_response_bytes: u32,
    slice_bytes: u32,
    original_response_overshot: bool,
    boundary_correction_sha256: ?[]const u8 = null,
    request_count: u8,
    content_type: []const u8,
    body_replaced: bool,
    historical_rendering_proven: bool,
};
fn eq(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
fn field(v: V, key: []const u8) !V {
    if (v != .object) return invalid;
    return v.object.get(key) orelse return invalid;
}
fn str(v: V, key: []const u8) ![]const u8 {
    const x = try field(v, key);
    if (x != .string) return invalid;
    return x.string;
}
fn integer(v: V, key: []const u8) !i64 {
    const x = try field(v, key);
    if (x != .integer) return invalid;
    return x.integer;
}
fn lowerHash(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}
fn digest(bytes: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}
fn matches(bytes: []const u8, hash: []const u8) bool { return eq(&digest(bytes), hash); }
fn bounded(bytes: []const u8, limit: usize) !void {
    if (bytes.len == 0 or bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes)) return invalid;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) { escaped = false; continue; }
            if (c == '\\') escaped = true else if (c == '"') quoted = false;
            continue;
        }
        switch (c) {
            '"' => quoted = true,
            '{', '[' => { depth += 1; if (depth > 16) return invalid; },
            '}', ']' => { if (depth == 0) return invalid; depth -= 1; },
            else => {},
        }
    }
    if (quoted or escaped or depth != 0) return invalid;
}
fn parse(a: A, bytes: []const u8) !V {
    return parseLimited(a, bytes, 64 * 1024);
}
fn parseLimited(a: A, bytes: []const u8, limit: usize) !V {
    try bounded(bytes, limit);
    return std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid,
    };
}
fn utc(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return false;
    const ranges = [_][2]usize{ .{0,4}, .{5,7}, .{8,10}, .{11,13}, .{14,16}, .{17,19} };
    var n: [6]u32 = undefined;
    for (ranges, 0..) |r, i| {
        for (value[r[0]..r[1]]) |c| if (!std.ascii.isDigit(c)) return false;
        n[i] = std.fmt.parseInt(u32, value[r[0]..r[1]], 10) catch return false;
    }
    if (n[0] == 0 or n[1] == 0 or n[1] > 12 or n[2] == 0 or n[3] > 23 or n[4] > 59 or n[5] > 59) return false;
    const days = [_]u32{31,28,31,30,31,30,31,31,30,31,30,31};
    const leap = n[1] == 2 and n[0] % 4 == 0 and (n[0] % 100 != 0 or n[0] % 400 == 0);
    return n[2] <= days[n[1] - 1] + @as(u32, if (leap) 1 else 0);
}
// Exact same-core source chain. The admitted language set is deliberately the
// single proven trivial-converter/html-code case; other converters stay unknown.
const profile_sources = [_][2][]const u8{
    .{ "Parser.php", "e09e1cbaa4a3a1f47cdd0faf127597cb6a1cc6357e2a81083b6726b7dbdbe90f" },
    .{ "Title.php", "3e1e04cf81bb748963d74d73d82f58a1b8bf78841da2765e43cecc556e3ccb5c" },
    .{ "ContentHandler.php", "de87edcdcccd81160c861ed40487713d6c770c8a22dd11ad96764adc208ff755" },
    .{ "TextContentHandler.php", "5a1de612d1370e2b1680b1072d4c24f6eeb1180487e8837ef54606c6abcc0117" },
    .{ "WikitextContentHandler.php", "f27bfe84c7844b711ea14265d29b0a82e555abac28c7a0e8c5eadbbf2691cf05" },
    .{ "ApiQueryInfo.php", "833251271905228b1176789599bc77e3e15dd496b9eeff363ad2bbef5b4efd84" },
    .{ "ParserOptions.php", "a143b64cceef0d9c085d4b4856d8eae75a38e921860ea3ae30f91750408a9bbd" },
    .{ "LanguageConverterFactory.php", "f7761f728de977f7e8b96040b8c00430e4f1c0db4ff1e6f2cf8cfc4e0537d709" },
    .{ "TrivialLanguageConverter.php", "918db7d24bb2fd54360a63f7a9ef5211fab9000d515de0e907a0f007f7ea39ff" },
    .{ "ParserOutput.current.php", "bb951725fd6a298349aa33f32b1694f05a6f38660f976f57199bedbe6da322a3" },
    .{ "AddWrapperDivClass.php", "6854e9fc9378928ad5cc864ddbd4cc58c60354430060fa84828543d6afc96a27" },
};
const generic_profile_sources = [_][2][]const u8{
    .{ "Language.php", "4ac8a43d9d94cbf4e72a1f19b7c8f2cc954b10ceb10f9679ff9f28cd074064ec" },
    .{ "LanguageCode.php", "17962f89468aa25369f126cc7a4edd8c074cb73497c8d4de77e8cbb04858d60d" },
    .{ "LanguageFactory.php", "2b91686fe7fcaaecb49da33316e407dd7409ce4e9d88f958272b912695ab7723" },
};
const Profile = struct { core: []const u8, generic_trivial: bool };
// Exact LanguageCode mappings. Deprecated internal codes cannot round-trip
// through the ParserOutput BCP47 value to the same LanguageFactory object.
const deprecated_language_codes = [_][]const u8{ "als", "bat-smg", "be-x-old", "fiu-vro", "roa-rup", "zh-classical", "zh-min-nan", "zh-yue" };
const nonstandard_language_codes = [_][2][]const u8{
    .{ "cbk-zam", "cbk" }, .{ "de-formal", "de-x-formal" }, .{ "eml", "egl" },
    .{ "en-rtl", "en-x-rtl" }, .{ "es-formal", "es-x-formal" }, .{ "hu-formal", "hu-x-formal" },
    .{ "map-bms", "jv-x-bms" }, .{ "mo", "ro-Cyrl-MD" }, .{ "nrm", "nrf" },
    .{ "nl-informal", "nl-x-informal" }, .{ "roa-tara", "nap-x-tara" }, .{ "simple", "en-simple" },
    .{ "sr-ec", "sr-Cyrl" }, .{ "sr-el", "sr-Latn" }, .{ "crh-ro", "crh-Latn-RO" },
    .{ "kk-cn", "kk-Arab-CN" }, .{ "kk-tr", "kk-Latn-TR" }, .{ "zh-cn", "zh-Hans-CN" },
    .{ "zh-sg", "zh-Hans-SG" }, .{ "zh-my", "zh-Hans-MY" }, .{ "zh-tw", "zh-Hant-TW" },
    .{ "zh-hk", "zh-Hant-HK" }, .{ "zh-mo", "zh-Hant-MO" },
};
fn trivialLanguage(code: []const u8, html: []const u8, direction: []const u8) bool {
    if (code.len == 0 or code.len > 128 or (!eq(direction, "ltr") and !eq(direction, "rtl"))) return false;
    var segment = false;
    for (code) |c| {
        if (c == '-') { if (!segment) return false; segment = false; }
        else if (std.ascii.isLower(c)) segment = true else return false;
    }
    if (!segment) return false;
    // Factory's complete dispatch table, plus its conditional English entry.
    // No configuration observation here establishes UsePigLatinVariant=false.
    for ([_][]const u8{ "ban", "crh", "en", "gan", "iu", "ku", "mni", "sh", "shi", "sr", "tg", "tly", "uz", "wuu", "zgh", "zh" }) |special| if (eq(code, special)) return false;
    for (deprecated_language_codes) |old| if (eq(code, old)) return false;
    var mapped = code;
    for (nonstandard_language_codes) |pair| {
        if (eq(code, pair[0])) { mapped = pair[1]; break; }
    }
    var canonical: [128]u8 = undefined;
    if (mapped.len > canonical.len) return false;
    var at: usize = 0;
    var previous_private = false;
    while (at < mapped.len) {
        const end = std.mem.indexOfScalarPos(u8, mapped, at, '-') orelse mapped.len;
        const part = mapped[at..end];
        for (part, at..) |c, i| canonical[i] = if (at != 0 and !previous_private and part.len == 2) std.ascii.toUpper(c) else std.ascii.toLower(c);
        if (at != 0 and !previous_private and part.len == 4) canonical[at] = std.ascii.toUpper(canonical[at]);
        previous_private = std.ascii.eqlIgnoreCase(part, "x");
        if (end < mapped.len) canonical[end] = '-';
        at = end + 1;
    }
    if (!eq(html, canonical[0..mapped.len])) return false;
    // AddWrapperDivClass reopens the BCP47 value through LanguageFactory.
    // Reject aliases whose inverse selects a different internal language.
    for (nonstandard_language_codes) |pair| if (std.ascii.eqlIgnoreCase(html, pair[1])) return eq(code, pair[0]);
    return std.ascii.eqlIgnoreCase(code, html);
}

fn profile(v: V, core: []const u8) !Profile {
    // These exact revisions have byte-identical complete source chains.
    // The newer revision is admitted only through the generic v2 profile.
    // Return static storage, not a slice into temporary JSON validation memory.
    const selected_core = if (eq(core, accepted_core)) accepted_core else if (eq(core, current_core)) current_core else if (eq(core, metadata_core_714)) metadata_core_714 else return invalid;
    if (v != .object or v.object.count() != 6) return invalid;
    const kind = try str(v, "kind");
    const generic_trivial = eq(kind, "normal-wikitext-trivial-language-v2");
    if ((!generic_trivial and !eq(kind, "normal-wikitext-trivial-language-v1")) or !eq(try str(v, "converter"), "TrivialLanguageConverter")) return invalid;
    if (generic_trivial and !eq(selected_core, current_core) and !eq(selected_core, metadata_core_714)) return invalid;
    if (!generic_trivial and eq(selected_core, metadata_core_714)) return invalid;
    const interface = try field(v, "interface_message");
    if (interface != .bool or interface.bool or try field(v, "target_language_override") != .null or try field(v, "variant_override") != .null) return invalid;
    const sources = try field(v, "sources");
    if (sources != .object or sources.object.count() != profile_sources.len + @as(usize, if (generic_trivial) generic_profile_sources.len else 0)) return invalid;
    for (profile_sources) |pair| if (!eq(try str(sources, pair[0]), pair[1])) return invalid;
    if (generic_trivial) {
        for (generic_profile_sources) |pair| if (!eq(try str(sources, pair[0]), pair[1])) return invalid;
    }
    return .{ .core = selected_core, .generic_trivial = generic_trivial };
}

fn rangeBytes(store: []const u8, offset: u64, length: u64) ![]const u8 {
    const begin = std.math.cast(usize, offset) orelse return invalid;
    const count = std.math.cast(usize, length) orelse return invalid;
    if (count == 0 or begin > store.len or count > store.len - begin) return invalid;
    return store[begin .. begin + count];
}
fn responsePages(a: A, raw: []const u8, source: ResponseRange, doc: Packet, ns: *const namespaces.Registry) ![]const V {
    if (!matches(raw, source.sha256) or !utc(source.observed_utc)) return invalid;
    const response = try parse(a, raw);
    const complete = try field(response, "batchcomplete");
    if (complete != .bool or !complete.bool or !eq(try str(response, "curtimestamp"), source.observed_utc)) return invalid;
    for ([_][]const u8{ "error", "errors", "warnings", "continue" }) |key| if (response.object.contains(key)) return invalid;
    const query = try field(response, "query");
    for ([_][]const u8{ "normalized", "redirects", "interwiki", "converted", "badrevids" }) |key| {
        if (query != .object or query.object.contains(key)) return invalid;
    }
    const general = try field(query, "general");
    const response_core = try str(general, "git-hash");
    const generator = try str(general, "generator");
    const exact_epoch = eq(response_core, doc.core_revision) and eq(generator, "MediaWiki 1.48.0-wmf.3");
    // All eleven complete v1 source bodies at this observed WMF4 revision
    // equal the selected f458 source profile. Preserve the response's actual
    // epoch; the generic v2 language-mapping chain has no such proof here.
    const compatible_ru_epoch = eq(doc.core_revision, current_core) and
        eq(try str(doc.source_profile, "kind"), "normal-wikitext-trivial-language-v1") and
        eq(response_core, "93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c") and
        eq(generator, "MediaWiki 1.48.0-wmf.4");
    if (!eq(try str(general, "wikiid"), doc.wiki) or !eq(try str(general, "lang"), ns.content_language) or
        (!exact_epoch and !compatible_ru_epoch)) return invalid;
    const pages = try field(query, "pages");
    if (pages != .array or pages.array.items.len == 0 or pages.array.items.len > max_records) return invalid;
    return pages.array.items;
}
const ObservedLanguage = struct { html: []const u8, direction: []const u8 };
fn observedPage(page: V, expected: Page, selected_profile: Profile) !ObservedLanguage {
    for ([_][]const u8{ "missing", "invalid", "redirect" }) |key| if (page != .object or page.object.contains(key)) return invalid;
    if ((try integer(page, "pageid")) != expected.id or (try integer(page, "ns")) != expected.namespace or
        !eq(try str(page, "title"), expected.title) or !eq(try str(page, "contentmodel"), expected.model)) return invalid;
    const revisions = try field(page, "revisions");
    if (revisions != .array or revisions.array.items.len != 1 or (try integer(revisions.array.items[0], "revid")) != expected.revision) return invalid;
    // Current page_latest is not the selected revision identity.
    if ((try integer(page, "lastrevid")) <= 0) return invalid;
    const code = try str(page, "pagelanguage");
    const html = try str(page, "pagelanguagehtmlcode");
    const direction = try str(page, "pagelanguagedir");
    if (selected_profile.generic_trivial) {
        if (!trivialLanguage(code, html, direction)) return invalid;
    } else if (!eq(code, "ru") or !eq(html, "ru") or !eq(direction, "ltr")) return invalid;
    return .{ .html = html, .direction = direction };
}
fn observedPrefix(a: A, store: []const u8, p: Prefix, page: Page, wiki: []const u8, html_language: []const u8) !prefix_parser.Observation {
    const bytes = try rangeBytes(store, p.offset, p.slice_bytes);
    if (bytes.len > 512 * 1024 or !std.unicode.utf8ValidateSlice(bytes) or !matches(bytes, p.sha256) or
        !lowerHash(p.receipt_sha256) or !lowerHash(p.original_response_sha256) or
        p.original_response_bytes > 512 * 1024 or p.original_response_bytes < p.slice_bytes or
        p.original_response_overshot != (p.original_response_bytes > p.slice_bytes) or
        p.status != 200 or p.request_count != 1 or p.body_replaced or p.historical_rendering_proven or
        !eq(p.content_type, "text/html; charset=UTF-8") or !utc(p.observed_utc)) return invalid;
    if (p.original_response_overshot) {
        if (!lowerHash(p.boundary_correction_sha256 orelse return invalid)) return invalid;
    } else if (p.boundary_correction_sha256 != null) return invalid;
    if (!std.mem.endsWith(u8, wiki, "wiktionary")) return invalid;
    const edition = wiki[0 .. wiki.len - "wiktionary".len];
    if (edition.len == 0) return invalid;
    const host = try a.dupe(u8, edition);
    for (host) |*c| {
        if (c.* == '_') c.* = '-' else if (!std.ascii.isLower(c.*) and !std.ascii.isDigit(c.*) and c.* != '-') return invalid;
    }
    const url = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/index.php?oldid={d}", .{ host, page.revision });
    if (!eq(p.request_url, url) or !eq(p.final_url, url)) return invalid;
    const parsed = prefix_parser.parseAlloc(a, bytes, page.id, page.revision) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid,
    };
    if (!eq(parsed.root_language, html_language) or parsed.outer_languages.len == 0) return invalid;
    return parsed;
}
pub const Registry = struct {
    const Entry = struct { page: Page, context: Context };
    arena: std.heap.ArenaAllocator,
    // Already sorted and immutable. No per-page maps or duplicated API trees.
    entries: []const Entry = &.{},
    core_revision: ?[]const u8 = null,

    pub fn init(backing: A, packet_bytes: ?[]const u8, response_bytes: ?[]const u8, prefix_bytes: ?[]const u8, ns: *const namespaces.Registry) !Registry {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        if (packet_bytes == null and response_bytes == null and prefix_bytes == null) return .{ .arena = arena };
        const a = arena.allocator();
        // Retain compact entries only. JSON object maps are validation scratch,
        // not a second persistent per-page representation.
        var index_arena = std.heap.ArenaAllocator.init(backing); defer index_arena.deinit();
        const index_allocator = index_arena.allocator();
        const value = try parseLimited(index_allocator, packet_bytes orelse return invalid, max_index_bytes);
        const doc = std.json.parseFromValueLeaky(Packet, index_allocator, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid,
        };
        const raw = response_bytes orelse return invalid;
        if (raw.len == 0 or raw.len > max_payload_bytes or (if (prefix_bytes) |p| p.len == 0 or p.len > max_payload_bytes else false) or
            !eq(doc.schema, "wikidict.page-language-index.v1") or !eq(doc.wiki, ns.wiki) or
            !eq(doc.namespace_registry_sha256, &std.fmt.bytesToHex(ns.source_sha256, .lower)) or doc.historical_page_language_proven or
            doc.records.len == 0 or doc.records.len > max_records or doc.responses.len == 0 or doc.responses.len > max_responses) return invalid;
        const selected_profile = try profile(doc.source_profile, doc.core_revision);
        var previous_id: u64 = 0;
        for (doc.records) |record| {
            const page = record.page;
            if (page.id <= previous_id or page.revision == 0 or page.namespace != 0 or !eq(page.model, "wikitext") or
                page.title.len == 0 or std.mem.indexOfAny(u8, page.title, "\x00\r\n\t") != null or
                !lowerHash(page.raw_sha256) or (if (page.expanded_sha256) |hash| !lowerHash(hash) else false) or record.response_index >= doc.responses.len) return invalid;
            previous_id = page.id;
        }
        const entries = try a.alloc(Entry, doc.records.len);
        var raw_end: usize = 0;
        for (doc.responses, 0..) |source, source_index| {
            if (source.offset != raw_end) return invalid;
            const bytes = try rangeBytes(raw, source.offset, source.bytes);
            raw_end += bytes.len;
            // Release each parsed response after projecting its selected rows.
            var temporary = std.heap.ArenaAllocator.init(backing); defer temporary.deinit();
            const t = temporary.allocator();
            const pages = try responsePages(t, bytes, source, doc, ns);
            const observed_utc = try a.dupe(u8, source.observed_utc);
            const used = try t.alloc(bool, pages.len); @memset(used, false);
            for (doc.records, 0..) |record, record_index| {
                if (record.response_index != source_index) continue;
                if (record.response_page_index >= pages.len or used[record.response_page_index]) return invalid;
                used[record.response_page_index] = true;
                const observed = try observedPage(pages[record.response_page_index], record.page, selected_profile);
                const owned_page: Page = .{
                    .id = record.page.id, .revision = record.page.revision,
                    .namespace = record.page.namespace, .model = "wikitext",
                    .title = try a.dupe(u8, record.page.title),
                    .raw_sha256 = try a.dupe(u8, record.page.raw_sha256),
                    .expanded_sha256 = if (record.page.expanded_sha256) |hash| try a.dupe(u8, hash) else null,
                };
                entries[record_index] = .{ .page = owned_page, .context = .{
                    .namespace_sha256 = ns.source_sha256, .title = owned_page.title,
                    .language = try a.dupe(u8, observed.html), .direction = try a.dupe(u8, observed.direction), .observed_utc = observed_utc,
                } };
            }
            for (used) |was_used| if (!was_used) return invalid;
        }
        if (raw_end != raw.len) return invalid;
        var prefix_end: usize = 0;
        for (doc.records, 0..) |record, record_index| if (record.prefix) |p| {
            if (p.offset != prefix_end) return invalid;
            const bytes = prefix_bytes orelse return invalid;
            const parsed = try observedPrefix(a, bytes, p, record.page, doc.wiki, entries[record_index].context.language);
            prefix_end += p.slice_bytes;
            entries[record_index].context.outer_languages = parsed.outer_languages;
            entries[record_index].context.prefix_observed_utc = try a.dupe(u8, p.observed_utc);
        };
        if (prefix_end != (if (prefix_bytes) |p| p.len else 0)) return invalid;
        return .{ .arena = arena, .entries = entries, .core_revision = selected_profile.core };
    }
    pub fn deinit(self: *Registry) void { self.arena.deinit(); self.* = undefined; }
    fn selected(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8, raw: []const u8) ?*const Entry {
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.entries[mid].page.id < page_id) low = mid + 1 else high = mid;
        }
        if (low == self.entries.len) return null;
        const entry = &self.entries[low];
        if (entry.page.id != page_id or entry.page.revision != revision_id or entry.page.namespace != ns or
            !eq(title, entry.page.title) or !matches(raw, entry.page.raw_sha256)) return null;
        return entry;
    }
    // Expansion output is capture evidence, not an input to page-language
    // resolution. A changed expansion cannot turn a valid page observation stale.
    pub fn lookup(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8, raw: []const u8, normal: NormalContext) ?Context {
        if (!normal.normal_no_target or normal.interface_message == null or normal.interface_message.? or normal.target_language_override != null or normal.variant_override != null or
            !eq(normal.source_core_revision orelse return null, self.core_revision orelse return null)) return null;
        return (self.selected(page_id, revision_id, ns, title, raw) orelse return null).context;
    }
    pub fn capturedSourceMatches(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8, raw: []const u8, expanded: []const u8) bool {
        const entry = self.selected(page_id, revision_id, ns, title, raw) orelse return false;
        return matches(expanded, entry.page.expanded_sha256 orelse return false);
    }
};

const Fixture = struct {
    const packet = @embedFile("testdata/ru-page-language201/page-language-without-prefix.json");
    const prefix_packet = @embedFile("testdata/ru-page-language201/page-language.json");
    const prefix = @embedFile("testdata/ru-page-language201/response.prefix.html");
    const response = @embedFile("testdata/ru-page-language201/response.raw.json");
    const namespaces_bytes = @embedFile("testdata/ru-denaske114/namespace-registry.tsv");
    const raw = @embedFile("testdata/ru-ugol143/raw.wikitext");
    const expanded = @embedFile("testdata/ru-ugol143/expanded.wikitext");
    const normal: NormalContext = .{ .source_core_revision = accepted_core, .normal_no_target = true, .interface_message = false };
    fn lookup(r: *const Registry, selected_context: NormalContext) ?Context {
        return r.lookup(3726, 14376095, 0, "уголь", raw, selected_context);
    }
};

test "page language actual observation remains current and exact page source bound" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    const packet = try a.dupe(u8, Fixture.packet);
    const response = try a.dupe(u8, Fixture.response);
    var r = Registry.init(a, packet, response, null, &ns) catch |err| { a.free(packet); a.free(response); return err; };
    defer r.deinit();
    a.free(packet); a.free(response);
    const ctx = Fixture.lookup(&r, Fixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ru", ctx.language);
    try std.testing.expectEqualStrings("ltr", ctx.direction);
    try std.testing.expectEqualStrings("2026-11-09T05:20:03Z", ctx.observed_utc);
    try std.testing.expect(ctx.outer_languages == null and ctx.prefix_observed_utc == null);
    try std.testing.expectEqualSlices(u8, &ns.source_sha256, &ctx.namespace_sha256);
    try std.testing.expect(r.lookup(3727, 14376095, 0, "уголь", Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(3726, 14376094, 0, "уголь", Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(3726, 14376095, 1, "уголь", Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(3726, 14376095, 0, "Coal", Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(3726, 14376095, 0, "уголь", "changed", Fixture.normal) == null);
    try std.testing.expect(r.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
    try std.testing.expect(!r.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, "changed"));
    try std.testing.expect(Fixture.lookup(&r, Fixture.normal) != null);
}

test "page language absent is unknown while partial malformed or mismatched input is invalid" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    var absent = try Registry.init(a, null, null, null, &ns); defer absent.deinit();
    try std.testing.expect(Fixture.lookup(&absent, Fixture.normal) == null);
    try std.testing.expectError(invalid, Registry.init(a, Fixture.packet, null, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, null, Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, "{}", Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, "{", Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, Fixture.packet, "{}", null, &ns));
    const saved = ns.source_sha256; ns.source_sha256[0] ^= 1;
    try std.testing.expectError(invalid, Registry.init(a, Fixture.packet, Fixture.response, null, &ns));
    ns.source_sha256 = saved;
}

test "page language requires explicit normal target interface variant and core context" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    var r = try Registry.init(a, Fixture.packet, Fixture.response, null, &ns); defer r.deinit();
    try std.testing.expect(Fixture.lookup(&r, .{}) == null);
    for (0..7) |i| {
        var normal = Fixture.normal;
        switch (i) {
            0 => normal.normal_no_target = false,
            1 => normal.interface_message = null,
            2 => normal.interface_message = true,
            3 => normal.target_language_override = "ru",
            4 => normal.variant_override = "ru",
            5 => normal.source_core_revision = null,
            6 => normal.source_core_revision = "another core",
            else => unreachable,
        }
        try std.testing.expect(Fixture.lookup(&r, normal) == null);
    }
}

test "page language refuses altered profile provenance and historical claims" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..10) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
        var v = try parse(temp, Fixture.packet);
        const p = v.object.getPtr("source_profile") orelse return invalid;
        switch (i) {
            0 => try v.object.put(temp, "wiki", .{ .string = "enwiktionary" }),
            1 => try v.object.put(temp, "core_revision", .{ .string = "changed" }),
            2 => try v.object.put(temp, "historical_page_language_proven", .{ .bool = true }),
            3 => {
                const source = &(try field(v, "responses")).array.items[0];
                try source.object.put(temp, "observed_utc", .{ .string = "2026-02-30T05:20:03Z" });
            },
            4 => try p.object.put(temp, "converter", .{ .string = "RuConverter" }),
            5 => try p.object.put(temp, "interface_message", .{ .bool = true }),
            6 => try p.object.put(temp, "target_language_override", .{ .string = "ru" }),
            7 => try p.object.put(temp, "variant_override", .{ .string = "ru" }),
            8 => {
                const sources = p.object.getPtr("sources") orelse return invalid;
                try sources.object.put(temp, "Parser.php", .{ .string = "changed" });
            },
            9 => try v.object.put(temp, "unexpected", .{ .bool = true }),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(temp, v, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed, Fixture.response, null, &ns));
    }
}

test "page language replays API identity even when a changed response hash agrees" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..13) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
        var response = try parse(temp, Fixture.response);
        // ObjectMap.put may reallocate even for an existing key. Always
        // update the actual parent-owned Value, never a shallow map copy.
        const query = response.object.getPtr("query") orelse return invalid;
        const general = query.object.getPtr("general") orelse return invalid;
        const pages = query.object.getPtr("pages") orelse return invalid;
        const page = &pages.array.items[0];
        switch (i) {
            0 => try page.object.put(temp, "pageid", .{ .integer = 3727 }),
            1 => try page.object.put(temp, "ns", .{ .integer = 1 }),
            2 => try page.object.put(temp, "title", .{ .string = "Coal" }),
            3 => try page.object.put(temp, "contentmodel", .{ .string = "json" }),
            4 => try page.object.put(temp, "pagelanguage", .{ .string = "sr" }),
            5 => try page.object.put(temp, "pagelanguagehtmlcode", .{ .string = "cu" }),
            6 => try page.object.put(temp, "pagelanguagedir", .{ .string = "rtl" }),
            7 => try general.object.put(temp, "wikiid", .{ .string = "enwiktionary" }),
            8 => try general.object.put(temp, "git-hash", .{ .string = "changed" }),
            9 => {
                const revs = page.object.getPtr("revisions") orelse return invalid;
                const rev = &revs.array.items[0];
                try rev.object.put(temp, "revid", .{ .integer = 14376094 });
            },
            10 => try page.object.put(temp, "missing", .{ .bool = true }),
            11 => try response.object.put(temp, "warnings", .{ .object = .empty }),
            12 => try response.object.put(temp, "curtimestamp", .{ .string = "2026-11-08T05:20:03Z" }),
            else => unreachable,
        }
        const raw = try std.json.Stringify.valueAlloc(temp, response, .{});
        if (i == 10) {
            const replay = try parse(temp, raw);
            const rows = try field(try field(replay, "query"), "pages");
            const missing = try field(rows.array.items[0], "missing");
            try std.testing.expect(missing == .bool and missing.bool);
        }
        const packet = try parse(temp, Fixture.packet);
        const source = &(try field(packet, "responses")).array.items[0];
        try source.object.put(temp, "sha256", .{ .string = try temp.dupe(u8, &digest(raw)) });
        try source.object.put(temp, "bytes", .{ .integer = @intCast(raw.len) });
        const projected = try std.json.Stringify.valueAlloc(temp, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, projected, raw, null, &ns));
    }
}

test "page language bounded JSON rejects oversized deep and duplicate input" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    const oversized = try a.alloc(u8, max_index_bytes + 1); defer a.free(oversized); @memset(oversized, ' ');
    try std.testing.expectError(invalid, Registry.init(a, oversized, Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, "[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]", Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, "{\"schema\":\"a\",\"schema\":\"b\"}", Fixture.response, null, &ns));
}

test "page language exact current prefix binds observed outer chain without replacing source" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    var r = try Registry.init(a, Fixture.prefix_packet, Fixture.response, Fixture.prefix, &ns); defer r.deinit();
    const ctx = Fixture.lookup(&r, Fixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2026-11-09T05:20:03Z", ctx.observed_utc);
    try std.testing.expectEqualStrings("2026-11-09T05:34:38Z", ctx.prefix_observed_utc.?);
    const chain = ctx.outer_languages orelse return error.TestUnexpectedResult;
    try std.testing.expect(chain.len > 0);
    for (chain) |lang| try std.testing.expectEqualStrings("ru", lang);
    try std.testing.expect(r.lookup(3726, 14376094, 0, "уголь", Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(!r.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, "different expansion"));
    try std.testing.expect(Fixture.lookup(&r, Fixture.normal) != null);
}

test "page language prefix requires complete pair exact bytes and strict wrapper EOF" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    try std.testing.expectError(invalid, Registry.init(a, Fixture.prefix_packet, Fixture.response, null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, Fixture.packet, Fixture.response, Fixture.prefix, &ns));
    try std.testing.expectError(invalid, Registry.init(a, Fixture.prefix_packet, Fixture.response, "<html lang=ru>", &ns));
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const with_content = try std.fmt.allocPrint(temp, "{s}<span>body", .{Fixture.prefix});
    const v = try parse(temp, Fixture.prefix_packet);
    const records = v.object.getPtr("records") orelse return invalid;
    const p = records.array.items[0].object.getPtr("prefix") orelse return invalid;
    try p.object.put(temp, "sha256", .{ .string = try temp.dupe(u8, &digest(with_content)) });
    try p.object.put(temp, "slice_bytes", .{ .integer = @intCast(with_content.len) });
    try p.object.put(temp, "original_response_bytes", .{ .integer = @intCast(with_content.len) });
    try p.object.put(temp, "original_response_overshot", .{ .bool = false });
    try p.object.put(temp, "boundary_correction_sha256", .null);
    const changed = try std.json.Stringify.valueAlloc(temp, v, .{});
    const replay = try parse(temp, changed);
    const prefix = try field((try field(replay, "records")).array.items[0], "prefix");
    try std.testing.expectEqualStrings(&digest(with_content), try str(prefix, "sha256"));
    try std.testing.expectEqual(@as(i64, @intCast(with_content.len)), try integer(prefix, "slice_bytes"));
    try std.testing.expectError(invalid, Registry.init(a, changed, Fixture.response, with_content, &ns));
}

test "page language prefix refuses wrong transport oldid epoch and historical claims" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..10) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
        const v = try parse(temp, Fixture.prefix_packet);
        const records = v.object.getPtr("records") orelse return invalid;
        const p = records.array.items[0].object.getPtr("prefix") orelse return invalid;
        switch (i) {
            0 => try p.object.put(temp, "status", .{ .integer = 302 }),
            1 => try p.object.put(temp, "request_url", .{ .string = "https://ru.wiktionary.org/w/index.php?oldid=1" }),
            2 => try p.object.put(temp, "final_url", .{ .string = "https://en.wiktionary.org/w/index.php?oldid=14376095" }),
            3 => try p.object.put(temp, "observed_utc", .{ .string = "2026-11-09" }),
            4 => try p.object.put(temp, "body_replaced", .{ .bool = true }),
            5 => try p.object.put(temp, "historical_rendering_proven", .{ .bool = true }),
            6 => try p.object.put(temp, "request_count", .{ .integer = 2 }),
            7 => try p.object.put(temp, "content_type", .{ .string = "application/json" }),
            8 => try p.object.put(temp, "receipt_sha256", .{ .string = "missing" }),
            9 => try p.object.put(temp, "slice_bytes", .{ .integer = 1 }),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(temp, v, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed, Fixture.response, Fixture.prefix, &ns));
    }
}

// Synthetic two-page metadata exercises indexing only. It is not evidence for
// another real page, and no observed shell is copied to the controlled page.
const ControlledIndex = struct {
    packet: V,
    response: V,
    const second_id = 4000;
    const second_revision = 15000000;
    const second_title = "controlled page";
    const second_raw = "controlled raw";
    const second_expanded = "controlled expansion";
    fn init(a: A, with_prefix: bool) !ControlledIndex {
        const packet = try parse(a, if (with_prefix) Fixture.prefix_packet else Fixture.packet);
        const response = try parse(a, Fixture.response);
        const records = packet.object.getPtr("records") orelse return invalid;
        var second_record = try parse(a, try std.json.Stringify.valueAlloc(a, records.array.items[0], .{}));
        const page = second_record.object.getPtr("page") orelse return invalid;
        try page.object.put(a, "id", .{ .integer = second_id });
        try page.object.put(a, "revision", .{ .integer = second_revision });
        try page.object.put(a, "title", .{ .string = second_title });
        try page.object.put(a, "raw_sha256", .{ .string = try a.dupe(u8, &digest(second_raw)) });
        try page.object.put(a, "expanded_sha256", .{ .string = try a.dupe(u8, &digest(second_expanded)) });
        try second_record.object.put(a, "response_page_index", .{ .integer = 1 });
        try second_record.object.put(a, "prefix", .null);
        try records.array.append(second_record);
        const query = response.object.getPtr("query") orelse return invalid;
        const pages = query.object.getPtr("pages") orelse return invalid;
        var second_page = try parse(a, try std.json.Stringify.valueAlloc(a, pages.array.items[0], .{}));
        try second_page.object.put(a, "pageid", .{ .integer = second_id });
        try second_page.object.put(a, "title", .{ .string = second_title });
        try second_page.object.put(a, "lastrevid", .{ .integer = second_revision });
        const revisions = second_page.object.getPtr("revisions") orelse return invalid;
        const revision = &revisions.array.items[0];
        try revision.object.put(a, "revid", .{ .integer = second_revision });
        try pages.array.append(second_page);
        return .{ .packet = packet, .response = response };
    }
    fn bytes(self: *ControlledIndex, a: A) !struct { packet: []const u8, raw: []const u8 } {
        const raw = try std.json.Stringify.valueAlloc(a, self.response, .{});
        const source = &(try field(self.packet, "responses")).array.items[0];
        try source.object.put(a, "sha256", .{ .string = try a.dupe(u8, &digest(raw)) });
        try source.object.put(a, "bytes", .{ .integer = @intCast(raw.len) });
        return .{ .packet = try std.json.Stringify.valueAlloc(a, self.packet, .{}), .raw = raw };
    }
    fn second(r: *const Registry, normal: NormalContext) ?Context {
        return r.lookup(second_id, second_revision, 0, second_title, second_raw, normal);
    }
};

test "page language controlled indexed rows retain exact source and independent capture provenance" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    var r = blk: {
        var temporary = std.heap.ArenaAllocator.init(a); defer temporary.deinit();
        var synthetic = try ControlledIndex.init(temporary.allocator(), true);
        const bytes = try synthetic.bytes(temporary.allocator());
        const prefix_copy = try temporary.allocator().dupe(u8, Fixture.prefix);
        break :blk try Registry.init(a, bytes.packet, bytes.raw, prefix_copy, &ns);
    };
    defer r.deinit();
    const first = Fixture.lookup(&r, Fixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), first.outer_languages.?.len);
    for (first.outer_languages.?) |language| try std.testing.expectEqualStrings("ru", language);
    const second = ControlledIndex.second(&r, Fixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(ControlledIndex.second_title, second.title);
    try std.testing.expectEqualStrings("ru", second.language);
    try std.testing.expect(second.outer_languages == null and second.prefix_observed_utc == null);
    try std.testing.expect(ControlledIndex.second(&r, .{}) == null);
    try std.testing.expect(r.lookup(3999, ControlledIndex.second_revision, 0, ControlledIndex.second_title, ControlledIndex.second_raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(4001, ControlledIndex.second_revision, 0, ControlledIndex.second_title, ControlledIndex.second_raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(4000, 15000001, 0, ControlledIndex.second_title, ControlledIndex.second_raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(4000, 15000000, 1, ControlledIndex.second_title, ControlledIndex.second_raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(4000, 15000000, 0, "another title", ControlledIndex.second_raw, Fixture.normal) == null);
    try std.testing.expect(r.lookup(4000, 15000000, 0, ControlledIndex.second_title, Fixture.raw, Fixture.normal) == null);
    try std.testing.expect(r.capturedSourceMatches(4000, 15000000, 0, ControlledIndex.second_title, ControlledIndex.second_raw, ControlledIndex.second_expanded));
    try std.testing.expect(!r.capturedSourceMatches(4000, 15000000, 0, ControlledIndex.second_title, ControlledIndex.second_raw, "new expansion"));
    try std.testing.expect(ControlledIndex.second(&r, Fixture.normal) != null);
}

test "page language controlled index refuses duplicate unordered unused and misbound rows" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..8) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var synthetic = try ControlledIndex.init(t, false);
        const records = synthetic.packet.object.getPtr("records") orelse return invalid;
        const second = &records.array.items[1];
        const page = second.object.getPtr("page") orelse return invalid;
        switch (i) {
            0 => try page.object.put(t, "id", .{ .integer = 3726 }),
            1 => std.mem.swap(V, &records.array.items[0], &records.array.items[1]),
            2 => try second.object.put(t, "response_index", .{ .integer = 1 }),
            3 => try second.object.put(t, "response_page_index", .{ .integer = 0 }),
            4 => try second.object.put(t, "response_page_index", .{ .integer = 2 }),
            5 => records.array.shrinkRetainingCapacity(1),
            6 => try page.object.put(t, "revision", .{ .integer = 15000001 }),
            7 => try page.object.put(t, "model", .{ .string = "json" }),
            else => unreachable,
        }
        const bytes = try synthetic.bytes(t);
        try std.testing.expectError(invalid, Registry.init(a, bytes.packet, bytes.raw, null, &ns));
    }
}

test "page language controlled index requires exact contiguous response and prefix stores" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..9) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var synthetic = try ControlledIndex.init(t, true);
        const bytes = try synthetic.bytes(t);
        const source = &(try field(synthetic.packet, "responses")).array.items[0];
        const records = synthetic.packet.object.getPtr("records") orelse return invalid;
        const p = records.array.items[0].object.getPtr("prefix") orelse return invalid;
        var raw = bytes.raw;
        var prefix_bytes: []const u8 = Fixture.prefix;
        switch (i) {
            0 => try source.object.put(t, "offset", .{ .integer = 1 }),
            1 => try source.object.put(t, "bytes", .{ .integer = @intCast(raw.len - 1) }),
            2 => try source.object.put(t, "sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" }),
            3 => raw = try std.fmt.allocPrint(t, "{s} ", .{raw}),
            4 => try p.object.put(t, "offset", .{ .integer = 1 }),
            5 => prefix_bytes = try std.fmt.allocPrint(t, "{s} ", .{prefix_bytes}),
            6 => {
                // Copying the actual shell to another record cannot grant its
                // language: range ownership and the shell's own IDs both matter.
                const second = &records.array.items[1];
                try second.object.put(t, "prefix", p.*);
            },
            7 => {
                // Deep-copy this deliberately wrong per-page prefix before
                // replacing either parent field; never use a relocated child.
                var wrong_prefix = try parse(t, try std.json.Stringify.valueAlloc(t, p.*, .{}));
                try wrong_prefix.object.put(t, "request_url", .{ .string = "https://ru.wiktionary.org/w/index.php?oldid=15000000" });
                try wrong_prefix.object.put(t, "final_url", .{ .string = "https://ru.wiktionary.org/w/index.php?oldid=15000000" });
                try records.array.items[1].object.put(t, "prefix", wrong_prefix);
                try records.array.items[0].object.put(t, "prefix", .null);
            },
            8 => try source.object.put(t, "observed_utc", .{ .string = "2026-11-08T05:20:03Z" }),
            else => unreachable,
        }
        const packet = try std.json.Stringify.valueAlloc(t, synthetic.packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, packet, raw, prefix_bytes, &ns));
    }
}

test "page language controlled index supports two independent contiguous response ranges" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
    var synthetic = try ControlledIndex.init(t, false);
    const query = synthetic.response.object.getPtr("query") orelse return invalid;
    const pages = query.object.getPtr("pages") orelse return invalid;
    const second_page = pages.array.items[1];
    pages.array.shrinkRetainingCapacity(1);
    const first = try std.json.Stringify.valueAlloc(t, synthetic.response, .{});
    pages.array.items[0] = second_page;
    const second = try std.json.Stringify.valueAlloc(t, synthetic.response, .{});
    const raw = try std.mem.concat(t, u8, &.{ first, second });
    const sources = synthetic.packet.object.getPtr("responses") orelse return invalid;
    const first_source = &sources.array.items[0];
    try first_source.object.put(t, "bytes", .{ .integer = @intCast(first.len) });
    try first_source.object.put(t, "sha256", .{ .string = try t.dupe(u8, &digest(first)) });
    var second_source = try parse(t, try std.json.Stringify.valueAlloc(t, first_source.*, .{}));
    try second_source.object.put(t, "offset", .{ .integer = @intCast(first.len) });
    try second_source.object.put(t, "bytes", .{ .integer = @intCast(second.len) });
    try second_source.object.put(t, "sha256", .{ .string = try t.dupe(u8, &digest(second)) });
    try sources.array.append(second_source);
    const record = &(try field(synthetic.packet, "records")).array.items[1];
    try record.object.put(t, "response_index", .{ .integer = 1 });
    try record.object.put(t, "response_page_index", .{ .integer = 0 });
    const packet = try std.json.Stringify.valueAlloc(t, synthetic.packet, .{});
    var r = try Registry.init(a, packet, raw, null, &ns); defer r.deinit();
    try std.testing.expect(Fixture.lookup(&r, Fixture.normal) != null);
    try std.testing.expect(ControlledIndex.second(&r, Fixture.normal) != null);
    try std.testing.expect(ControlledIndex.second(&r, Fixture.normal).?.outer_languages == null);
}


test "page language ordinary metadata needs no expanded capture and cannot certify one" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for ([_]bool{ false, true }) |explicit_null| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const temp = arena.allocator();
        var packet = try parseLimited(temp, Fixture.prefix_packet, max_index_bytes);
        const records = packet.object.getPtr("records") orelse return invalid;
        const page = records.array.items[0].object.getPtr("page") orelse return invalid;
        if (explicit_null) {
            try page.object.put(temp, "expanded_sha256", .null);
        } else {
            try std.testing.expect(page.object.swapRemove("expanded_sha256"));
        }
        const bytes = try std.json.Stringify.valueAlloc(temp, packet, .{});
        var registry = try Registry.init(a, bytes, Fixture.response, Fixture.prefix, &ns); defer registry.deinit();
        const actual = Fixture.lookup(&registry, Fixture.normal) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("ru", actual.language);
        try std.testing.expectEqualStrings("2026-11-09T05:20:03Z", actual.observed_utc);
        try std.testing.expect(actual.outer_languages != null);
        try std.testing.expect(!registry.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
        try std.testing.expect(registry.lookup(3727, 14376095, 0, "уголь", Fixture.raw, Fixture.normal) == null);
        try std.testing.expect(registry.lookup(3726, 14376094, 0, "уголь", Fixture.raw, Fixture.normal) == null);
        try std.testing.expect(registry.lookup(3726, 14376095, 1, "уголь", Fixture.raw, Fixture.normal) == null);
        try std.testing.expect(registry.lookup(3726, 14376095, 0, "Other", Fixture.raw, Fixture.normal) == null);
        try std.testing.expect(registry.lookup(3726, 14376095, 0, "уголь", "changed raw", Fixture.normal) == null);
        try std.testing.expect(Fixture.lookup(&registry, .{ .source_core_revision = accepted_core, .normal_no_target = false, .interface_message = false }) == null);
        try std.testing.expect(Fixture.lookup(&registry, .{ .source_core_revision = "wrong", .normal_no_target = true, .interface_message = false }) == null);
    }
    var exact = try Registry.init(a, Fixture.prefix_packet, Fixture.response, Fixture.prefix, &ns); defer exact.deinit();
    try std.testing.expect(exact.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
    try std.testing.expect(!exact.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, "changed expansion"));
}

test "page language optional capture binding is validated independently of normal authority" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for ([_]V{ .{ .integer = 1 }, .{ .bool = false }, .{ .string = "bad" }, .{ .string = "" } }) |bad| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const temp = arena.allocator();
        var packet = try parseLimited(temp, Fixture.packet, max_index_bytes);
        const records = packet.object.getPtr("records") orelse return invalid;
        const page = records.array.items[0].object.getPtr("page") orelse return invalid;
        try page.object.put(temp, "expanded_sha256", bad);
        const bytes = try std.json.Stringify.valueAlloc(temp, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, bytes, Fixture.response, null, &ns));
    }
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const temp = arena.allocator();
    var packet = try parseLimited(temp, Fixture.packet, max_index_bytes);
    const records = packet.object.getPtr("records") orelse return invalid;
    const page = records.array.items[0].object.getPtr("page") orelse return invalid;
    try page.object.put(temp, "expanded_sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" });
    const bytes = try std.json.Stringify.valueAlloc(temp, packet, .{});
    var registry = try Registry.init(a, bytes, Fixture.response, null, &ns); defer registry.deinit();
    try std.testing.expect(Fixture.lookup(&registry, Fixture.normal) != null);
    try std.testing.expect(!registry.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
}

const CurrentCoreFixture = struct {
    const packet = @embedFile("testdata/ru-page-language231/page-language.json");
    const response = @embedFile("testdata/ru-page-language231/response.raw.json");
    const normal: NormalContext = .{ .source_core_revision = current_core, .normal_no_target = true, .interface_message = false };
};

test "indexed page language actual current core keeps ordinary authority separate from captured replay" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    const packet = try a.dupe(u8, CurrentCoreFixture.packet);
    const response = try a.dupe(u8, CurrentCoreFixture.response);
    var registry = Registry.init(a, packet, response, null, &ns) catch |err| { a.free(packet); a.free(response); return err; };
    defer registry.deinit();
    a.free(packet); a.free(response);
    const ctx = Fixture.lookup(&registry, CurrentCoreFixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ru", ctx.language);
    try std.testing.expectEqualStrings("ltr", ctx.direction);
    try std.testing.expectEqualStrings("2026-11-09T21:37:21Z", ctx.observed_utc);
    try std.testing.expectEqualStrings(current_core, registry.core_revision.?);
    try std.testing.expect(ctx.outer_languages == null and ctx.prefix_observed_utc == null);
    try std.testing.expectEqualSlices(u8, &ns.source_sha256, &ctx.namespace_sha256);
    try std.testing.expect(!registry.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
    try std.testing.expect(Fixture.lookup(&registry, Fixture.normal) == null);
    try std.testing.expect(Fixture.lookup(&registry, .{}) == null);
    try std.testing.expect(registry.lookup(3726, 14376094, 0, "уголь", Fixture.raw, CurrentCoreFixture.normal) == null);
    try std.testing.expect(registry.lookup(3726, 14376095, 0, "уголь", "changed", CurrentCoreFixture.normal) == null);
    var historical = try Registry.init(a, Fixture.packet, Fixture.response, null, &ns); defer historical.deinit();
    try std.testing.expect(Fixture.lookup(&historical, Fixture.normal) != null);
    try std.testing.expect(Fixture.lookup(&historical, CurrentCoreFixture.normal) == null);
    try std.testing.expect(historical.capturedSourceMatches(3726, 14376095, 0, "уголь", Fixture.raw, Fixture.expanded));
}

test "indexed page language refuses mixed current core response profile and unproven language" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, Fixture.namespaces_bytes); defer ns.deinit();
    for (0..6) |case_index| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
        var packet = try parse(temp, CurrentCoreFixture.packet);
        var response = try parse(temp, CurrentCoreFixture.response);
        switch (case_index) {
            0 => try packet.object.put(temp, "core_revision", .{ .string = accepted_core }),
            1 => try packet.object.put(temp, "core_revision", .{ .string = "unreviewed" }),
            2 => {
                const query = response.object.getPtr("query") orelse return invalid;
                const general = query.object.getPtr("general") orelse return invalid;
                try general.object.put(temp, "git-hash", .{ .string = accepted_core });
            },
            3 => {
                const source_profile = packet.object.getPtr("source_profile") orelse return invalid;
                const sources = source_profile.object.getPtr("sources") orelse return invalid;
                try sources.object.put(temp, "Title.php", .{ .string = "changed" });
            },
            4, 5 => {
                const query = response.object.getPtr("query") orelse return invalid;
                const pages = query.object.getPtr("pages") orelse return invalid;
                const page = &pages.array.items[0];
                try page.object.put(temp, if (case_index == 4) "pagelanguage" else "pagelanguagehtmlcode", .{ .string = "en" });
            },
            else => unreachable,
        }
        const changed_response = try std.json.Stringify.valueAlloc(temp, response, .{});
        const ranges = packet.object.getPtr("responses") orelse return invalid;
        const source = &ranges.array.items[0];
        const sha = digest(changed_response);
        try source.object.put(temp, "bytes", .{ .integer = @intCast(changed_response.len) });
        try source.object.put(temp, "sha256", .{ .string = &sha });
        const changed_packet = try std.json.Stringify.valueAlloc(temp, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed_packet, changed_response, null, &ns));
    }
}


const TrivialProfileFixture = struct {
    const packet = @embedFile("testdata/wo-page-language242/page-language.json");
    const response = @embedFile("testdata/wo-page-language242/response.raw.json");
    const prefix = @embedFile("testdata/wo-page-language242/response.prefix.html");
    const namespace_bytes = @embedFile("testdata/wo-page-language242/namespace-registry.tsv");
    const raw = @embedFile("testdata/wo-page-language242/raw.wikitext");
    const expanded = @embedFile("testdata/wo-page-language242/expanded.wikitext");
    const normal: NormalContext = .{ .source_core_revision = current_core, .normal_no_target = true, .interface_message = false };
    fn lookup(r: *const Registry) ?Context { return r.lookup(3618, 26533, 0, "cosaan", raw, normal); }
};

test "generic trivial page language uses actual WO page and complete independent prefix without defaults" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, TrivialProfileFixture.namespace_bytes); defer ns.deinit();
    const packet = try a.dupe(u8, TrivialProfileFixture.packet); defer a.free(packet);
    const response = try a.dupe(u8, TrivialProfileFixture.response); defer a.free(response);
    const prefix = try a.dupe(u8, TrivialProfileFixture.prefix); defer a.free(prefix);
    var registry = try Registry.init(a, packet, response, prefix, &ns); defer registry.deinit();
    // All observed strings survive scratch JSON and caller input disposal/change.
    @memset(packet, 'x'); @memset(response, 'x'); @memset(prefix, 'x');
    const ctx = TrivialProfileFixture.lookup(&registry) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wo", ctx.language);
    try std.testing.expectEqualStrings("ltr", ctx.direction);
    try std.testing.expect(ctx.outer_languages != null and ctx.outer_languages.?.len > 2);
    for (ctx.outer_languages.?) |lang| try std.testing.expectEqualStrings("wo", lang);
    try std.testing.expect(ctx.prefix_observed_utc != null);
    try std.testing.expect(registry.capturedSourceMatches(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, TrivialProfileFixture.expanded));
    try std.testing.expect(!registry.capturedSourceMatches(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, "changed"));
    try std.testing.expect(registry.lookup(3619, 26533, 0, "cosaan", TrivialProfileFixture.raw, TrivialProfileFixture.normal) == null);
    try std.testing.expect(registry.lookup(3618, 26532, 0, "cosaan", TrivialProfileFixture.raw, TrivialProfileFixture.normal) == null);
    try std.testing.expect(registry.lookup(3618, 26533, 0, "cosaan", "changed", TrivialProfileFixture.normal) == null);
    try std.testing.expect(registry.lookup(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, Fixture.normal) == null);
    var normal = TrivialProfileFixture.normal; normal.variant_override = "wo";
    try std.testing.expect(registry.lookup(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, normal) == null);
}

test "generic trivial page language follows converter dispatch and reversible BCP47 source semantics" {
    for ([_][3][]const u8{
        .{ "wo", "wo", "ltr" }, .{ "fr", "fr", "ltr" }, .{ "ar", "ar", "rtl" },
        .{ "pt-br", "pt-BR", "ltr" }, .{ "de-formal", "de-x-formal", "ltr" },
        .{ "simple", "en-simple", "ltr" }, .{ "mo", "ro-Cyrl-MD", "ltr" },
        .{ "eml", "egl", "ltr" }, .{ "sr-ec", "sr-Cyrl", "ltr" },
    }) |parts| try std.testing.expect(trivialLanguage(parts[0], parts[1], parts[2]));
    for ([_][]const u8{ "ban", "crh", "en", "gan", "iu", "ku", "mni", "sh", "shi", "sr", "tg", "tly", "uz", "wuu", "zgh", "zh" }) |lang| try std.testing.expect(!trivialLanguage(lang, lang, "ltr"));
    for ([_][3][]const u8{
        .{ "", "", "ltr" }, .{ "WO", "wo", "ltr" }, .{ "wo--x", "wo--x", "ltr" },
        .{ "wo", "fr", "ltr" }, .{ "wo", "wo", "auto" }, .{ "wo", "wo", "" },
        .{ "pt-br", "pt-br", "ltr" }, .{ "simple", "simple", "ltr" },
        .{ "egl", "egl", "ltr" }, .{ "als", "gsw", "ltr" }, .{ "wo\x00", "wo", "ltr" },
    }) |parts| try std.testing.expect(!trivialLanguage(parts[0], parts[1], parts[2]));
}

test "generic trivial page language preserves rehashed profile identity capture and prefix refusals" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, TrivialProfileFixture.namespace_bytes); defer ns.deinit();
    for (0..10) |i| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var packet = try parse(t, TrivialProfileFixture.packet);
        const response = try parse(t, TrivialProfileFixture.response);
        const source_profile = packet.object.getPtr("source_profile").?;
        const source_pins = source_profile.object.getPtr("sources").?;
        const records = packet.object.getPtr("records").?;
        const prefix = records.array.items[0].object.getPtr("prefix").?;
        const page = &(try field(try field(response, "query"), "pages")).array.items[0];
        switch (i) {
            0 => try source_pins.object.put(t, "LanguageCode.php", .{ .string = "changed" }),
            1 => try source_profile.object.put(t, "kind", .{ .string = "normal-wikitext-trivial-language-v1" }),
            2 => try source_profile.object.put(t, "interface_message", .{ .bool = true }),
            3 => try page.object.put(t, "pagelanguage", .{ .string = "sr" }),
            4 => try page.object.put(t, "pagelanguagehtmlcode", .{ .string = "fr" }),
            5 => try page.object.put(t, "pageid", .{ .integer = 3619 }),
            6 => try page.object.put(t, "pagelanguagedir", .{ .string = "auto" }),
            7 => try prefix.object.put(t, "request_url", .{ .string = "https://wo.wiktionary.org/w/index.php?oldid=26532" }),
            8 => try source_profile.object.put(t, "variant_override", .{ .string = "wo" }),
            9 => {
                // A valid independent French observation cannot borrow a WO root.
                try page.object.put(t, "pagelanguage", .{ .string = "fr" });
                try page.object.put(t, "pagelanguagehtmlcode", .{ .string = "fr" });
            },
            else => unreachable,
        }
        const raw = try std.json.Stringify.valueAlloc(t, response, .{});
        const range = &(try field(packet, "responses")).array.items[0];
        try range.object.put(t, "sha256", .{ .string = try t.dupe(u8, &digest(raw)) });
        try range.object.put(t, "bytes", .{ .integer = @intCast(raw.len) });
        const encoded = try std.json.Stringify.valueAlloc(t, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, encoded, raw, TrivialProfileFixture.prefix, &ns));
        if (i == 9) {
            // Remove only the independently missing prefix: actual nondefault
            // page language remains available, with outer scope still unknown.
            try records.array.items[0].object.put(t, "prefix", .null);
            const record_page = records.array.items[0].object.getPtr("page").?;
            _ = record_page.object.swapRemove("expanded_sha256");
            const ordinary = try std.json.Stringify.valueAlloc(t, packet, .{});
            var registry = try Registry.init(a, ordinary, raw, null, &ns); defer registry.deinit();
            const ctx = TrivialProfileFixture.lookup(&registry) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("fr", ctx.language);
            try std.testing.expectEqualStrings("wo", ns.content_language);
            try std.testing.expect(ctx.outer_languages == null);
            try std.testing.expect(!registry.capturedSourceMatches(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, TrivialProfileFixture.expanded));
        }
    }
}


test "generic 714 page language keeps exact epoch host and source guards" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, TrivialProfileFixture.namespace_bytes); defer ns.deinit();
    // Synthetic epoch mutation of the existing fixture, not a new WO observation.
    for (0..5) |mutation| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var packet = try parse(t, TrivialProfileFixture.packet);
        const response = try parse(t, TrivialProfileFixture.response);
        try packet.object.put(t, "core_revision", .{ .string = metadata_core_714 });
        const general = response.object.getPtr("query").?.object.getPtr("general").?;
        try general.object.put(t, "git-hash", .{ .string = metadata_core_714 });
        const record = &packet.object.getPtr("records").?.array.items[0];
        try record.object.put(t, "prefix", .null);
        _ = record.object.getPtr("page").?.object.swapRemove("expanded_sha256");
        const source_profile = packet.object.getPtr("source_profile").?;
        switch (mutation) {
            0 => {},
            1 => try source_profile.object.put(t, "kind", .{ .string = "normal-wikitext-trivial-language-v1" }),
            2 => try source_profile.object.getPtr("sources").?.object.put(t, "Parser.php", .{ .string = "changed" }),
            3 => try general.object.put(t, "git-hash", .{ .string = current_core }),
            4 => {
                try packet.object.put(t, "core_revision", .{ .string = "7140a34a88ee294f3b4d8cda0c4f43a880410e21" });
                try general.object.put(t, "git-hash", .{ .string = "7140a34a88ee294f3b4d8cda0c4f43a880410e21" });
            },
            else => unreachable,
        }
        const raw = try std.json.Stringify.valueAlloc(t, response, .{});
        const range = &packet.object.getPtr("responses").?.array.items[0];
        try range.object.put(t, "sha256", .{ .string = try t.dupe(u8, &digest(raw)) });
        try range.object.put(t, "bytes", .{ .integer = @intCast(raw.len) });
        const encoded = try std.json.Stringify.valueAlloc(t, packet, .{});
        if (mutation != 0) {
            try std.testing.expectError(invalid, Registry.init(a, encoded, raw, null, &ns));
            continue;
        }
        var registry = try Registry.init(a, encoded, raw, null, &ns); defer registry.deinit();
        const normal: NormalContext = .{ .source_core_revision = metadata_core_714, .normal_no_target = true, .interface_message = false };
        const ctx = registry.lookup(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, normal) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("wo", ctx.language);
        try std.testing.expect(ctx.outer_languages == null and ctx.prefix_observed_utc == null);
        try std.testing.expect(!registry.capturedSourceMatches(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, TrivialProfileFixture.expanded));
        for ([_][]const u8{ accepted_core, current_core }) |old_core| {
            var old = normal; old.source_core_revision = old_core;
            try std.testing.expect(registry.lookup(3618, 26533, 0, "cosaan", TrivialProfileFixture.raw, old) == null);
        }
        try std.testing.expect(registry.lookup(3619, 26533, 0, "cosaan", TrivialProfileFixture.raw, normal) == null);
        try std.testing.expect(registry.lookup(3618, 26532, 0, "cosaan", TrivialProfileFixture.raw, normal) == null);
        try std.testing.expect(registry.lookup(3618, 26533, 1, "cosaan", TrivialProfileFixture.raw, normal) == null);
        try std.testing.expect(registry.lookup(3618, 26533, 0, "cosaan", "changed", normal) == null);
    }
}

const RuObserved93Fixture = struct {
    const packet = @embedFile("testdata/ru-root-language93/page-language.json");
    const response = @embedFile("testdata/ru-root-language93/page-language.raw.json");
    const prefix = @embedFile("testdata/ru-root-language93/page-language.html");
    const old_packet = @embedFile("testdata/ru-root-language93/prior-nine.json");
    const old_response = @embedFile("testdata/ru-root-language93/prior-nine.raw.json");
    const old_prefix = @embedFile("testdata/ru-root-language93/prior-nine.html");
    const namespace_bytes = @embedFile("testdata/ru-root-language93/namespace-registry.tsv");
    const raw = @embedFile("testdata/ru-root-language93/raw.wikitext");
    fn lookup(registry: *const Registry, normal: NormalContext) ?Context {
        return registry.lookup(1500042, 10248798, 0, "𛀁", raw, normal);
    }
};

test "actual RU WMF4 response preserves nine prior records and exact root ancestry under reviewed v1 source" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, RuObserved93Fixture.namespace_bytes); defer ns.deinit();
    var prior = try Registry.init(a, RuObserved93Fixture.old_packet, RuObserved93Fixture.old_response, RuObserved93Fixture.old_prefix, &ns); defer prior.deinit();
    var current = try Registry.init(a, RuObserved93Fixture.packet, RuObserved93Fixture.response, RuObserved93Fixture.prefix, &ns); defer current.deinit();
    try std.testing.expectEqual(@as(usize, 9), prior.entries.len);
    try std.testing.expectEqual(@as(usize, 10), current.entries.len);
    for (prior.entries, current.entries[0..9]) |old, now| try std.testing.expectEqualDeep(old, now);
    try std.testing.expectEqualStrings(current_core, current.core_revision.?);
    const context = RuObserved93Fixture.lookup(&current, CurrentCoreFixture.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ru", context.language);
    try std.testing.expectEqualStrings("ltr", context.direction);
    try std.testing.expectEqualStrings("2026-11-12T01:16:03Z", context.observed_utc);
    try std.testing.expectEqual(@as(usize, 8), context.outer_languages.?.len);
    for (context.outer_languages.?) |lang| try std.testing.expectEqualStrings("ru", lang);
    try std.testing.expect(context.prefix_observed_utc != null);
    try std.testing.expectEqualSlices(u8, &ns.source_sha256, &context.namespace_sha256);
    try std.testing.expect(!current.capturedSourceMatches(1500042, 10248798, 0, "𛀁", RuObserved93Fixture.raw, "unobserved expansion"));
    try std.testing.expect(RuObserved93Fixture.lookup(&current, .{}) == null);
    try std.testing.expect(RuObserved93Fixture.lookup(&current, .{ .source_core_revision = "93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c", .normal_no_target = true, .interface_message = false }) == null);
    var wrong_normal = CurrentCoreFixture.normal;
    wrong_normal.target_language_override = "ru";
    try std.testing.expect(RuObserved93Fixture.lookup(&current, wrong_normal) == null);
    wrong_normal = CurrentCoreFixture.normal; wrong_normal.interface_message = true;
    try std.testing.expect(RuObserved93Fixture.lookup(&current, wrong_normal) == null);
    try std.testing.expect(current.lookup(1500042, 10248797, 0, "𛀁", RuObserved93Fixture.raw, CurrentCoreFixture.normal) == null);
    try std.testing.expect(current.lookup(1500042, 10248798, 0, "𛀁", "changed source", CurrentCoreFixture.normal) == null);
}

test "RU WMF4 compatible response keeps generator profile language and exact prefix refusals after rehash" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, RuObserved93Fixture.namespace_bytes); defer ns.deinit();
    for (0..9) |case_index| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var packet = try parse(t, RuObserved93Fixture.packet);
        const ranges = packet.object.getPtr("responses") orelse return invalid;
        const last = &ranges.array.items[ranges.array.items.len - 1];
        const offset: usize = @intCast(try integer(last.*, "offset"));
        var response = try parse(t, RuObserved93Fixture.response[offset..]);
        const query = response.object.getPtr("query") orelse return invalid;
        const general = query.object.getPtr("general") orelse return invalid;
        const source_profile = packet.object.getPtr("source_profile") orelse return invalid;
        switch (case_index) {
            0 => try general.object.put(t, "git-hash", .{ .string = "unreviewed" }),
            1 => try general.object.put(t, "generator", .{ .string = "MediaWiki 1.48.0-wmf.3" }),
            2 => try packet.object.put(t, "core_revision", .{ .string = accepted_core }),
            3 => {
                // This is otherwise a valid generic profile, but its extra
                // language-mapping leaves were not proven at the new epoch.
                try source_profile.object.put(t, "kind", .{ .string = "normal-wikitext-trivial-language-v2" });
                const sources = source_profile.object.getPtr("sources") orelse return invalid;
                for (generic_profile_sources) |pair| try sources.object.put(t, pair[0], .{ .string = pair[1] });
            },
            4 => {
                const sources = source_profile.object.getPtr("sources") orelse return invalid;
                try sources.object.put(t, "Title.php", .{ .string = "changed" });
            },
            5, 6 => {
                const pages = query.object.getPtr("pages") orelse return invalid;
                try pages.array.items[0].object.put(t, if (case_index == 5) "pagelanguage" else "pagelanguagehtmlcode", .{ .string = "ja" });
            },
            7 => {
                const records = packet.object.getPtr("records") orelse return invalid;
                const prefix = records.array.items[records.array.items.len - 1].object.getPtr("prefix") orelse return invalid;
                try prefix.object.put(t, "final_url", .{ .string = "https://ru.wiktionary.org/w/index.php?oldid=10248797" });
            },
            8 => try packet.object.put(t, "historical_page_language_proven", .{ .bool = true }),
            else => unreachable,
        }
        const changed_response = try std.json.Stringify.valueAlloc(t, response, .{});
        const changed_hash = digest(changed_response);
        try last.object.put(t, "bytes", .{ .integer = @intCast(changed_response.len) });
        try last.object.put(t, "sha256", .{ .string = &changed_hash });
        const raw_store = try std.mem.concat(t, u8, &.{ RuObserved93Fixture.response[0..offset], changed_response });
        const encoded = try std.json.Stringify.valueAlloc(t, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, encoded, raw_store, RuObserved93Fixture.prefix, &ns));
    }
}
