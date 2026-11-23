//! Build-time plain local-link facts from the SAME normal title index, site
//! URLs and content-language message snapshot. No Reader-entry existence or
//! edition/language default is an existence/URL/message authority.
const std = @import("std");
const namespaces = @import("namespace_registry");
const dump = @import("wikimedia_dump");
const encoder = @import("encoder");
const A = std.mem.Allocator;
const title_variant = @import("source_title_variant.zig");
pub const State = enum { present, missing };
pub const Attribute = struct { name: []const u8, value: []const u8 };
pub const Anchor = struct {
    state: State,
    normalized_title: []const u8,
    href: []const u8,
    title: []const u8,
    attributes: []const Attribute,
};
// Caller retains these immutable inputs until all normal expansion slots join.
// Identity is the selected input identity, never inferred from a page language.
pub const Inputs = struct {
    arena: std.heap.ArenaAllocator,
    namespace_sha256: [32]u8,
    site: namespaces.wiki_url.SiteUrlConfig,
    red_link_title: ?[]const u8,
    // Site flags and explicit missing base-table message; indexed absence is
    // checked once when the immutable provider is constructed.
    variant_base: ?[]const u8 = null,

    pub fn init(backing: A, registry: *const namespaces.Registry, site_bytes: []const u8,
        message_bytes: []const u8, identity: namespaces.interface_messages.Identity) !Inputs
    {
        if (!std.mem.eql(u8, registry.wiki, identity.wiki) or
            !std.mem.eql(u8, registry.dump_date, identity.dump_date) or
            !std.mem.eql(u8, registry.content_language, identity.content_language)) return error.InvalidSnapshotIdentity;
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, a, site_bytes, .{ .allocate = .alloc_always });
        if (parsed.value != .object) return error.InvalidSourceLinkSite;
        const namespace_hash = std.fmt.bytesToHex(registry.source_sha256, .lower);
        if (!std.mem.eql(u8, try siteString(parsed.value, "schema"), "wikidict.site-info.v2") or
            !std.mem.eql(u8, try siteString(parsed.value, "wiki"), identity.wiki) or
            !std.mem.eql(u8, try siteString(parsed.value, "date"), identity.dump_date) or
            !std.mem.eql(u8, try siteString(parsed.value, "content_language"), identity.content_language) or
            !std.mem.eql(u8, try siteString(parsed.value, "namespace_registry_sha256"), &namespace_hash)) return error.InvalidSnapshotIdentity;
        const query = parsed.value.object.get("query") orelse return error.InvalidSourceLinkSite;
        if (query != .object) return error.InvalidSourceLinkSite;
        const general = query.object.get("general") orelse return error.InvalidSourceLinkSite;
        if (general != .object) return error.InvalidSourceLinkSite;
        const wiki = try siteString(general, "wikiid");
        const language = try siteString(general, "lang");
        if (!std.mem.eql(u8, wiki, identity.wiki) or
            !std.mem.eql(u8, language, identity.content_language)) return error.InvalidSnapshotIdentity;
        const site: namespaces.wiki_url.SiteUrlConfig = .{
            .server = try siteString(general, "server"),
            .script = try siteString(general, "script"),
            .article_path = try siteString(general, "articlepath"),
        };
        const retained_messages = try a.dupe(u8, message_bytes);
        const messages = try namespaces.interface_messages.parseAlloc(a, retained_messages, identity, true);
        const key = try namespaces.interface_messages.lookupKeyAlloc(a, identity.content_language, "red-link-title");
        const selected = if (messages.get(key)) |entry| entry.source_raw else null;
        var variant_base: ?[]const u8 = null;
        if (variantSite(general, language)) {
            const conversion_key = try namespaces.interface_messages.lookupKeyAlloc(a, language, "conversiontable/ku");
            if (messages.get(conversion_key)) |entry| {
                if (entry.source_raw == null)
                    variant_base = try registry.normalizeTitle(a, "Conversiontable/ku", 8, .literal);
            }
        }
        return .{ .arena = arena, .namespace_sha256 = registry.source_sha256,
            .site = site, .red_link_title = selected, .variant_base = variant_base };
    }
    pub fn deinit(inputs: *Inputs) void { inputs.arena.deinit(); inputs.* = undefined; }
    pub fn provider(inputs: *const Inputs, registry: *const namespaces.Registry,
        page_index: []const u8, titles: dump.PageTitleIndex) ?Provider
    {
        if (!std.mem.eql(u8, &inputs.namespace_sha256, &registry.source_sha256)) return null;
        const variant_enabled = if (inputs.variant_base) |base|
            registry.ofTitle(base).id == 8 and (titles.lookup(page_index, base) catch return null) == null
        else false;
        return .{ .registry = registry, .page_index = page_index, .titles = titles,
            .site = inputs.site, .red_link_title = inputs.red_link_title, .variant_enabled = variant_enabled };
    }
};
fn variantSite(general: std.json.Value, language: []const u8) bool {
    if (!std.mem.eql(u8, language, "ku")) return false;
    const core = siteString(general, "git-hash") catch return false;
    if (!title_variant.matchedCore(core)) return false;
    for ([_][]const u8{ "langconversion", "linkconversion", "titleconversion" }) |name| {
        const flag = general.object.get(name) orelse return false;
        if (flag != .bool or !flag.bool) return false;
    }
    const variants = general.object.get("variants") orelse return false;
    if (variants != .array or variants.array.items.len != 3) return false;
    for (variants.array.items, [_][]const u8{ "ku", "ku-arab", "ku-latn" }) |item, expected| {
        if (item != .object) return false;
        const code = siteString(item, "code") catch return false;
        if (!std.mem.eql(u8, code, expected)) return false;
    }
    return true;
}
fn siteString(general: std.json.Value, name: []const u8) ![]const u8 {
    const value = general.object.get(name) orelse return error.InvalidSourceLinkSite;
    if (value != .string or value.string.len == 0 or !std.unicode.utf8ValidateSlice(value.string))
        return error.InvalidSourceLinkSite;
    return value.string;
}
pub const Provider = struct {
    registry: *const namespaces.Registry,
    page_index: []const u8,
    titles: dump.PageTitleIndex,
    site: namespaces.wiki_url.SiteUrlConfig,
    // Selected V row in the site's content language; absent/M does not invent
    // a localized title. Only flat $1 text is in this first message domain.
    red_link_title: ?[]const u8,
    variant_enabled: bool = false,

    // The ordinary Writer is a normal view, not an edit, submit, redirect=no
    // or linkconvert=no request. Callers with another request do not bind this.
    // Page-local manual conversion may mutate the ordered base table.
    pub fn bindTargets(provider: *const Provider, a: A, source: []const u8) !?encoder.presentation_compile.LocalLinkTargetSource {
        if (!provider.variant_enabled or std.mem.indexOf(u8, source, "-{") != null) return null;
        const binding = try a.create(PageBinding);
        binding.* = .{ .provider = provider, .source = source };
        return .{ .source = source, .namespace_sha256 = provider.registry.source_sha256,
            .context = binding, .resolve = PageBinding.resolveTarget };
    }
    fn variantTarget(self: *const Provider, a: A, raw: []const u8) !?[]const u8 {
        if (!self.variant_enabled or raw.len == 0 or !std.unicode.utf8ValidateSlice(raw) or
            std.mem.indexOfAny(u8, raw, "\x00<>[]{}&'\"#:\r\n\t") != null or self.registry.ofTitle(raw).id != 0) return null;
        const original = try self.registry.normalizeTitle(a, raw, 0, .any);
        // Relative titles need the current namespace/page constructor, which
        // this plain main-title issuer does not claim.
        if (std.mem.startsWith(u8, original, "/") or std.mem.startsWith(u8, original, "./") or
            std.mem.startsWith(u8, original, "../")) return null;
        // Any original indexed page, including a redirect, prevents fallback.
        if (try self.titles.lookup(self.page_index, original) != null) return null;
        const candidate = (try title_variant.arabicAlloc(a, original)) orelse return null;
        if (std.mem.eql(u8, candidate, original)) return null;
        const normalized = try self.registry.normalizeTitle(a, candidate, 0, .any);
        if (self.registry.ofTitle(normalized).id != 0) return null;
        const reference = (try self.titles.lookup(self.page_index, normalized)) orelse return null;
        const offset = dump.pageRowRefOffset(reference);
        if (offset >= self.page_index.len) return error.InvalidPageIndex;
        const end = std.mem.indexOfScalarPos(u8, self.page_index, offset, '\n') orelse self.page_index.len;
        const page = try dump.parsePageIndexLine(self.titles.kind, self.page_index[offset..end]);
        if (!std.mem.eql(u8, page.title, normalized)) return error.PageTitleIndexMismatch;
        // This finite ordinary-link family has no redirect/content-model grant.
        if (page.ns != 0 or page.redirect != null or !page.has_source or
            !std.mem.eql(u8, page.content_model, "wikitext")) return null;
        return normalized;
    }

    pub fn bind(provider: *const Provider, a: A, source: []const u8) !encoder.presentation_compile.TableSourceAnchorConstructor {
        const binding = try a.create(PageBinding);
        binding.* = .{ .provider = provider, .source = source };
        return .{ .source = source, .namespace_sha256 = provider.registry.source_sha256,
            .context = binding, .resolve = PageBinding.resolve };
    }

    pub fn resolve(self: *const Provider, a: A, raw: []const u8) !?Anchor {
        if (raw.len == 0 or !std.unicode.utf8ValidateSlice(raw) or
            std.mem.indexOfAny(u8, raw, "\x00<>[]{}&'\"#:\r\n\t") != null or
            self.registry.ofTitle(raw).id != 0 or self.site.server.len == 0 or
            !safeLocalPath(self.site.script) or !safeLocalPath(self.site.article_path)) return null;
        const marker = std.mem.indexOf(u8, self.site.article_path, "$1") orelse return null;
        if (std.mem.indexOfPos(u8, self.site.article_path, marker + 2, "$1") != null) return null;
        const normalized = try self.registry.normalizeTitle(a, raw, 0, .any);
        if (self.registry.ofTitle(normalized).id != 0) return null;
        var state: State = .missing;
        if (try self.titles.lookup(self.page_index, normalized)) |reference| {
            const offset = dump.pageRowRefOffset(reference);
            if (offset >= self.page_index.len) return error.InvalidPageIndex;
            const end = std.mem.indexOfScalarPos(u8, self.page_index, offset, '\n') orelse self.page_index.len;
            const page = try dump.parsePageIndexLine(self.titles.kind, self.page_index[offset..end]);
            if (!std.mem.eql(u8, page.title, normalized)) return error.PageTitleIndexMismatch;
            // Redirect/interwiki/other content constructors are independent;
            // presence never silently turns their classes/actions into plain A.
            if (page.redirect != null or page.ns != 0 or !page.has_source or
                !std.mem.eql(u8, page.content_model, "wikitext")) return null;
            state = .present;
        }
        const title = if (state == .present) normalized else missing: {
            const message = self.red_link_title orelse return null;
            if (!flatRedTitleMessage(message)) return null;
            const Parameters = struct {
                value: []const u8,
                pub fn get(parameters: @This(), index: usize) ![]const u8 { if (index != 0) return error.InvalidInterfaceMessageKey; return parameters.value; }
            };
            break :missing try namespaces.interface_messages.substituteParams(a, message, 1, Parameters{ .value = normalized });
        };
        // The ordinary maintained URL helper owns both article and queried
        // script paths; missing targets retain edit/redlink parameters.
        const href = try namespaces.wiki_url.buildSiteWikiUrlRawQuery(a, normalized,
            if (state == .missing) "action=edit&redlink=1" else null, .local, false, null, self.site);
        const attributes = try a.alloc(Attribute, if (state == .missing) 3 else 2);
        attributes[0] = .{ .name = "href", .value = href };
        attributes[1] = .{ .name = "title", .value = title };
        // Empty class is omitted, not fabricated as class="": [class] differs.
        if (state == .missing) attributes[2] = .{ .name = "class", .value = "new" };
        return .{ .state = state, .normalized_title = normalized, .href = href, .title = title, .attributes = attributes };
    }
};
// Shared mmap inputs from the ordinary Writer. Missing-link class identity does
// not require a localized edit tooltip or URL configuration.
pub const TableLinkIndex = struct {
    registry: *const namespaces.Registry,
    page_index: []const u8,
    titles: dump.PageTitleIndex,

    pub fn select(registry: *const namespaces.Registry, page_index: []const u8, titles: dump.PageTitleIndex,
        styles: ?*const encoder.table_style_profile.Profile) ?TableLinkIndex
    {
        const profile = styles orelse return null;
        if (!registry.literal_link_titles or !profile.hasNewAnchorTextRule()) return null;
        return .{ .registry = registry, .page_index = page_index, .titles = titles };
    }

    pub fn bind(self: *const TableLinkIndex, source: []const u8) ?encoder.presentation_compile.LocalLinkTargetSource {
        if (std.mem.indexOf(u8, source, "{|") == null or std.mem.indexOf(u8, source, "[[") == null or
            std.mem.indexOf(u8, source, "-{") != null) return null;
        return .{ .source = source, .namespace_sha256 = self.registry.source_sha256, .context = self, .missing = missing };
    }

    fn missing(context: ?*const anyopaque, a: A, op: encoder.presentation_compile.TableSourceAnchorOperation) encoder.presentation_compile.Error!bool {
        const self: *const TableLinkIndex = @ptrCast(@alignCast(context orelse return false));
        if (!PageBinding.contains(op.source, op.token) or !PageBinding.contains(op.token, op.target)) return false;
        const raw = op.target;
        // Fragment existence is unrelated to page existence. Namespaced, relative,
        // percent-escaped and entity-bearing titles need other title constructors.
        if (raw.len == 0 or !std.unicode.utf8ValidateSlice(raw) or std.mem.indexOf(u8, raw, "\u{fffd}") != null or
            std.mem.indexOfAny(u8, raw, "\x00\x7f<>[]{}&'\"%:\r\n\t|") != null) return false;
        const end = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        if (end == 0 or (end < raw.len and std.mem.indexOfScalar(u8, raw[end + 1..], '#') != null)) return false;
        const page = raw[0..end];
        const normalized = self.registry.normalizeTitle(a, page, 0, .any) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, else => return false,
        };
        defer a.free(normalized);
        if (normalized.len == 0 or normalized.len > 255 or std.mem.startsWith(u8, normalized, "/") or
            std.mem.startsWith(u8, normalized, "../") or std.mem.startsWith(u8, normalized, "./") or
            std.mem.eql(u8, normalized, ".") or std.mem.eql(u8, normalized, "..") or
            std.mem.indexOf(u8, normalized, "/./") != null or std.mem.indexOf(u8, normalized, "/../") != null or
            std.mem.endsWith(u8, normalized, "/.") or std.mem.endsWith(u8, normalized, "/..") or
            std.mem.indexOf(u8, normalized, "~~~") != null) return false;
        return (self.titles.lookup(self.page_index, normalized) catch return error.UncompiledPresentation) == null;
    }
};

const PageBinding = struct {
    provider: *const Provider,
    source: []const u8,
    fn contains(outer: []const u8, inner: []const u8) bool {
        const offset = std.math.sub(usize, @intFromPtr(inner.ptr), @intFromPtr(outer.ptr)) catch return false;
        return offset <= outer.len and inner.len <= outer.len - offset;
    }
    fn resolveTarget(context: ?*const anyopaque, a: A,
        operation: encoder.presentation_compile.TableSourceAnchorOperation) encoder.presentation_compile.Error!?[]const u8
    {
        const binding: *const PageBinding = @ptrCast(@alignCast(context orelse return null));
        if (operation.source.ptr != binding.source.ptr or operation.source.len != binding.source.len or
            !contains(binding.source, operation.token) or !contains(operation.token, operation.target)) return null;
        var iterator: encoder.document_ir.InlineIterator = .{ .input = operation.token, .renderer_boundaries = true };
        const token = iterator.next() orelse return null;
        if (token.kind != .link or iterator.cursor != operation.token.len or token.link_empty_label or
            token.link_label_restored_close or token.target.ptr != operation.target.ptr or token.target.len != operation.target.len) return null;
        return binding.provider.variantTarget(a, operation.target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, else => return error.UncompiledPresentation,
        };
    }
    fn resolve(context: ?*const anyopaque, a: A,
        operation: encoder.presentation_compile.TableSourceAnchorOperation) A.Error!?[]const encoder.table_style_profile.FigureObservedAttribute
    {
        const binding: *const PageBinding = @ptrCast(@alignCast(context orelse return null));
        if (operation.source.ptr != binding.source.ptr or operation.source.len != binding.source.len or
            !contains(binding.source, operation.token) or !contains(operation.token, operation.target) or
            !std.mem.startsWith(u8, operation.token, "[[") or !std.mem.endsWith(u8, operation.token, "]]")) return null;
        const target = if (std.mem.indexOf(u8, binding.source, "-{") == null)
            ((resolveTarget(context, a, operation) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory, else => return null,
            }) orelse operation.target) else operation.target;
        const resolved = (binding.provider.resolve(a, target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }) orelse return null;
        const attributes = try a.alloc(encoder.table_style_profile.FigureObservedAttribute, resolved.attributes.len);
        for (resolved.attributes, attributes) |attribute, *result|
            result.* = .{ .name = attribute.name, .value = attribute.value };
        return attributes;
    }
};
fn flatRedTitleMessage(source: []const u8) bool {
    if (source.len == 0 or !std.unicode.utf8ValidateSlice(source) or
        std.mem.indexOfAny(u8, source, "{}<>\\\x00\r\n\t") != null) return false;
    var at: usize = 0;
    while (at < source.len) : (at += 1) if (source[at] == '$') {
        if (at + 1 >= source.len or source[at + 1] != '1' or
            (at + 2 < source.len and std.ascii.isDigit(source[at + 2]))) return false;
        at += 1;
    };
    return true;
}
fn safeLocalPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/") and !std.mem.startsWith(u8, path, "//") and
        std.mem.indexOfAny(u8, path, "\x00<>\\\"'\r\n\t ") == null;
}

test "source anchor uses same title index and selected site message without reader existence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try namespaces.Registry.init(a, namespaces.english_test_fixture);
    defer registry.deinit();
    const index = "0\t1\tPresent\t\t1\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n";
    var bytes: [64 + 8 * 16]u8 = @splat(0);
    @memcpy(bytes[0..8], "DPTIDX01");
    std.mem.writeInt(u64, bytes[16..24], 8, .little);
    std.mem.writeInt(u64, bytes[24..32], 1, .little);
    std.mem.writeInt(u64, bytes[32..40], 1, .little);
    std.mem.writeInt(u64, bytes[40..48], index.len, .little);
    const hash = std.hash.Wyhash.hash(0, "Present");
    const slot: usize = @intCast(hash & 7);
    const entry: *[16]u8 = bytes[64 + slot * 16 ..][0..16];
    std.mem.writeInt(u64, entry[0..8], hash, .little);
    std.mem.writeInt(u64, entry[8..16], (try dump.packPageRowRef(0, 0)) + 1, .little);
    var provider = Provider{
        .registry = &registry, .page_index = index,
        .titles = try dump.PageTitleIndex.init(&bytes),
        .site = .{ .server = "//source.invalid", .script = "/w/index.php", .article_path = "/wiki/$1" },
        .red_link_title = "$1 (missing)",
    };
    const present = (try provider.resolve(a, "Present")).?;
    try std.testing.expectEqual(State.present, present.state);
    try std.testing.expectEqualStrings("/wiki/Present", present.href);
    try std.testing.expectEqualStrings("Present", present.title);
    try std.testing.expectEqual(@as(usize, 2), present.attributes.len);
    const missing = (try provider.resolve(a, "Absent")).?;
    try std.testing.expectEqual(State.missing, missing.state);
    try std.testing.expectEqualStrings("/w/index.php?title=Absent&action=edit&redlink=1", missing.href);
    try std.testing.expectEqualStrings("Absent (missing)", missing.title);
    try std.testing.expectEqualStrings("new", missing.attributes[2].value);
    provider.red_link_title = null;
    try std.testing.expect((try provider.resolve(a, "Absent")) == null);
    try std.testing.expect((try provider.resolve(a, "Present")) != null);
    for ([_][]const u8{ ":Absent", "Absent#part", "https://example.org", "File:Absent", "Absent\n" }) |unsupported|
        try std.testing.expect((try provider.resolve(a, unsupported)) == null);
    provider.red_link_title = "{{unsupported:$1}}";
    try std.testing.expect((try provider.resolve(a, "Absent")) == null);
    provider.red_link_title = "$2";
    try std.testing.expect((try provider.resolve(a, "Absent")) == null);
}

test "source anchor inputs retain selected snapshot bytes and reject site or message identity substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var registry = try namespaces.Registry.init(a, namespaces.english_test_fixture); defer registry.deinit();
    const identity: namespaces.interface_messages.Identity = .{ .wiki = registry.wiki,
        .dump_date = registry.dump_date, .content_language = registry.content_language };
    const namespace_hash = std.fmt.bytesToHex(registry.source_sha256, .lower);
    const json = try std.json.Stringify.valueAlloc(a, .{
        .schema = "wikidict.site-info.v2", .wiki = identity.wiki, .date = identity.dump_date,
        .content_language = identity.content_language, .namespace_registry_sha256 = @as([]const u8, &namespace_hash),
        .query = .{ .general = .{
        .wikiid = identity.wiki, .lang = identity.content_language,
        .server = "//source.invalid", .script = "/w/index.php", .articlepath = "/wiki/$1",
    } } }, .{});
    const message = try std.fmt.allocPrint(a,
        "# wikidict-interface-messages-v1\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\n{s}\tred-link-title\tV\t$1 (selected missing)\n",
        .{ identity.wiki, identity.dump_date, identity.content_language, identity.content_language });
    var inputs = try Inputs.init(a, &registry, json, message, identity); defer inputs.deinit();
    @memset(message, 'x');
    @memset(json, 'x');
    try std.testing.expectEqualStrings("$1 (selected missing)", inputs.red_link_title.?);
    try std.testing.expectEqualStrings("/wiki/$1", inputs.site.article_path);
    var wrong = identity; wrong.wiki = "otherwiki";
    try std.testing.expectError(error.InvalidSnapshotIdentity, Inputs.init(a, &registry, "{}", "", wrong));
    const bad_site = try std.json.Stringify.valueAlloc(a, .{
        .schema = "wikidict.site-info.v2", .wiki = identity.wiki, .date = identity.dump_date,
        .content_language = identity.content_language, .namespace_registry_sha256 = @as([]const u8, &namespace_hash),
        .query = .{ .general = .{
        .wikiid = "otherwiki", .lang = identity.content_language,
        .server = "//source.invalid", .script = "/w/index.php", .articlepath = "/wiki/$1",
    } } }, .{});
    try std.testing.expectError(error.InvalidSnapshotIdentity, Inputs.init(a, &registry, bad_site, "", identity));
}

// Complete synthetic index for focused issuer controls; never a production
// absence certificate or a substitute for the retained KU title index.
fn variantTestIndex(a: A, index: []const u8) !dump.PageTitleIndex {
    var lines = std.mem.splitScalar(u8, index, '\n');
    var count: usize = 0;
    while (lines.next()) |line| if (line.len != 0) { count += 1; };
    const capacity: usize = 64;
    if (count > capacity / 2) return error.TestUnexpectedResult;
    const bytes = try a.alloc(u8, 64 + capacity * 16); @memset(bytes, 0);
    @memcpy(bytes[0..8], "DPTIDX01");
    std.mem.writeInt(u64, bytes[16..24], capacity, .little);
    std.mem.writeInt(u64, bytes[24..32], count, .little);
    std.mem.writeInt(u64, bytes[32..40], count, .little);
    std.mem.writeInt(u64, bytes[40..48], index.len, .little);
    lines.reset(); var offset: usize = 0;
    while (lines.next()) |line| {
        defer offset += line.len + 1;
        if (line.len == 0) continue;
        const row = try dump.parsePageIndexLine(.raw_xml, line);
        const hash = std.hash.Wyhash.hash(0, row.title);
        var slot: usize = @intCast(hash & (capacity - 1));
        while (std.mem.readInt(u64, bytes[64 + slot * 16 + 8 ..][0..8], .little) != 0) slot = (slot + 1) & (capacity - 1);
        std.mem.writeInt(u64, bytes[64 + slot * 16 ..][0..8], hash, .little);
        std.mem.writeInt(u64, bytes[64 + slot * 16 + 8 ..][0..8], (try dump.packPageRowRef(offset, 0)) + 1, .little);
    }
    return dump.PageTitleIndex.init(bytes);
}

test "normal variant target issuer requires original absence selected flags base table and source occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var registry = try namespaces.Registry.init(a, @embedFile("testdata/ku-malper/namespace-registry.tsv")); defer registry.deinit();
    const identity: namespaces.interface_messages.Identity = .{ .wiki = registry.wiki, .dump_date = registry.dump_date, .content_language = registry.content_language };
    const header = try std.fmt.allocPrint(a, "# wikidict-interface-messages-v1\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\n", .{ identity.wiki, identity.dump_date, identity.content_language });
    const message = try std.mem.concat(a, u8, &.{ header, "ku\tconversiontable/ku\tM\nku\tred-link-title\tV\t$1 (missing)\n" });
    const site = @embedFile("testdata/ku-mer-next268/figure-siteinfo.raw.json");
    const row = "0\t1\tگه\t\t365293\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n";
    const original_row = "0\t1\tgh\t\t1\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n";
    const source = "[[gh|different visible label]]";
    for (0..10) |mode| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, site, .{ .allocate = .alloc_always });
        const general = parsed.value.object.getPtr("query").?.object.getPtr("general").?;
        if (mode == 1) try general.object.put(a, "linkconversion", .{ .bool = false });
        if (mode == 2) try general.object.put(a, "git-hash", .{ .string = "unknown" });
        if (mode == 3) try general.object.put(a, "git-hash", .{ .string = "79b81ba96674efc8a803fc956bc501d347d440d2" });
        if (mode == 4) try general.object.put(a, "langconversion", .{ .bool = false });
        if (mode == 5) std.mem.swap(std.json.Value, &general.object.getPtr("variants").?.array.items[0], &general.object.getPtr("variants").?.array.items[1]);
        const messages = if (mode == 6) try std.mem.replaceOwned(u8, a, message, "conversiontable/ku\tM", "conversiontable/ku\tV\t") else message;
        var inputs = try Inputs.init(a, &registry, try std.json.Stringify.valueAlloc(a, parsed.value, .{}), messages, identity); defer inputs.deinit();
        const index = switch (mode) {
            7 => try std.mem.concat(a, u8, &.{ row, original_row }),
            8 => try std.mem.concat(a, u8, &.{ row, "0\t1\tMediaWiki:Conversiontable/ku\t\t3\t2\t2026-01-01T00:00:00Z\tU\twikitext\t8\t1\t0\n" }),
            9 => original_row,
            else => row,
        };
        const provider = inputs.provider(&registry, index, try variantTestIndex(a, index)) orelse return error.TestUnexpectedResult;
        const bound = try provider.bindTargets(a, source);
        const target = if (bound) |proof| try proof.resolve(proof.context, a, .{ .source = source, .token = source, .target = source[2..4] }) else null;
        if (mode == 0 or mode == 3) {
            try std.testing.expectEqualStrings("گه", target orelse return error.TestUnexpectedResult);
            try std.testing.expectEqualStrings("گه", (try provider.variantTarget(a, "gh_")).?);
            const proof = bound.?;
            const copy = try a.dupe(u8, source);
            try std.testing.expect(try proof.resolve(proof.context, a, .{ .source = copy, .token = copy, .target = copy[2..4] }) == null);
            try std.testing.expect(try proof.resolve(proof.context, a, .{ .source = source, .token = source, .target = source[5..12] }) == null);
            try std.testing.expect(try provider.bindTargets(a, "-{ku:manual;}- [[gh]]") == null);
            try std.testing.expect(try provider.variantTarget(a, "File:gh") == null);
            try std.testing.expect(try provider.variantTarget(a, "gh#fragment") == null);
            try std.testing.expect(try provider.variantTarget(a, "/gh") == null);
            try std.testing.expect(try provider.variantTarget(a, "./gh") == null);
            try std.testing.expect(try provider.variantTarget(a, "../gh") == null);
            try std.testing.expect(try provider.variantTarget(a, "missing") == null);
            const attrs = try provider.bind(a, source);
            const values = (try attrs.resolve(attrs.context, a, .{ .source = source, .token = source, .target = source[2..4] })).?;
            try std.testing.expectEqualStrings("/wiki/%DA%AF%D9%87", values[0].value);
            try std.testing.expectEqualStrings("گه", values[1].value);
            var mismatched = provider;
            mismatched.page_index = index[0 .. index.len - 1];
            const mismatched_source = (try mismatched.bindTargets(a, source)).?;
            try std.testing.expectError(error.UncompiledPresentation, mismatched_source.resolve(mismatched_source.context, a,
                .{ .source = source, .token = source, .target = source[2..4] }));
        } else try std.testing.expect(target == null);
    }
}

test "variant target original redirects and namespace collisions never authorize a replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var registry = try namespaces.Registry.init(a, @embedFile("testdata/ku-malper/namespace-registry.tsv")); defer registry.deinit();
    const row = "0\t1\tگه\t\t365293\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n";
    for ([_][]const u8{
        "0\t1\tgh\tElsewhere\t1\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n",
        "0\t1\tgh\t\t1\t2\t2026-01-01T00:00:00Z\tU\tcss\t0\t1\t0\n",
    }) |original| {
        const index = try std.mem.concat(a, u8, &.{ row, original });
        const provider: Provider = .{ .registry = &registry, .page_index = index, .titles = try variantTestIndex(a, index),
            .site = .{ .server = "//ku.wiktionary.org", .script = "/w/index.php", .article_path = "/wiki/$1" }, .red_link_title = null, .variant_enabled = true };
        try std.testing.expect(try provider.variantTarget(a, "gh") == null);
    }
}

// These six synthetic index rows are an explicitly controlled test domain.
// They do not attest the contents or absence of any page in a real corpus.
// Only the source-owned variant-target API is supplied to the strict oracles;
// this sparse index must never supply redlink attributes or existence evidence.
pub const ControlledKuTitleInputsTesting = if (@import("builtin").is_test) struct {
    const pairs = [_][2][]const u8{
        .{ "gh", "گه" }, .{ "gw", "گو" }, .{ "kw", "کو" },
        .{ "hr", "هر" }, .{ "rz", "رز" }, .{ "sw", "سو" },
    };
    pub const Loaded = struct {
        inputs: *Inputs,
        provider: *Provider,
        pub fn deinit(self: *@This()) void { self.inputs.deinit(); }
        pub fn targets(self: @This(), a: A, source: []const u8) !encoder.presentation_compile.LocalLinkTargetSource {
            return (try self.provider.bindTargets(a, source)) orelse error.TestUnexpectedResult;
        }
    };
    pub fn load(a: A, registry: *const namespaces.Registry) !Loaded {
        const identity: namespaces.interface_messages.Identity = .{
            .wiki = registry.wiki, .dump_date = registry.dump_date, .content_language = registry.content_language,
        };
        try std.testing.expectEqualStrings("ku", identity.content_language);
        const messages = try std.fmt.allocPrint(a,
            "# wikidict-interface-messages-v1\n# wiki\t{s}\n# dump-date\t{s}\n# content-language\t{s}\nku\tconversiontable/ku\tM\nku\tred-link-title\tV\t$1 (controlled missing)\n",
            .{ identity.wiki, identity.dump_date, identity.content_language });
        var index: std.ArrayList(u8) = .empty;
        for (pairs, 0..) |pair, ordinal| {
            const row = try std.fmt.allocPrint(a, "0\t1\t{s}\t\t{d}\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n", .{ pair[1], ordinal + 1 });
            try index.appendSlice(a, row);
        }
        const inputs = try a.create(Inputs);
        inputs.* = try Inputs.init(a, registry, @embedFile("testdata/ku-mer-next268/figure-siteinfo.raw.json"), messages, identity);
        errdefer inputs.deinit();
        const provider = try a.create(Provider);
        provider.* = inputs.provider(registry, index.items, try variantTestIndex(a, index.items)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(provider.variant_enabled);
        return .{ .inputs = inputs, .provider = provider };
    }
    // Independent explicit source-pair expectations precede both controlled
    // and authentic-provider strict oracles. No captured href is consulted.
    pub fn verify(a: A, registry: *const namespaces.Registry, source: []const u8,
        selected: encoder.presentation_compile.LocalLinkTargetSource) !void
    {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        try std.testing.expectEqualStrings("ed942971342411e72720f64881ff55ebbc3d36a3a019d96da2b5ce8f199bcb42", &std.fmt.bytesToHex(digest, .lower));
        try std.testing.expect(selected.source.ptr == source.ptr and selected.source.len == source.len);
        try std.testing.expectEqualSlices(u8, &registry.source_sha256, &selected.namespace_sha256);
        var counts: [pairs.len]usize = .{ 0, 0, 0, 0, 0, 0 };
        var ordinary: usize = 0;
        var iterator: encoder.document_ir.InlineIterator = .{ .input = source, .renderer_boundaries = true };
        while (iterator.next()) |span| {
            if (span.kind != .link) continue;
            const namespace = registry.ofTitle(span.target).id;
            if (namespace == 6 or namespace == 14) continue;
            ordinary += 1;
            try std.testing.expect(!span.link_has_pipe and !span.link_empty_label and std.mem.eql(u8, span.text, span.target));
            const offset = std.math.sub(usize, @intFromPtr(span.target.ptr), @intFromPtr(source.ptr)) catch return error.TestUnexpectedResult;
            const end = offset + span.target.len + 2;
            try std.testing.expect(offset >= 2 and end <= source.len);
            try std.testing.expectEqualStrings("[[", source[offset - 2..offset]);
            try std.testing.expectEqualStrings("]]", source[end - 2..end]);
            const resolved = try selected.resolve(selected.context, a, .{ .source = source, .token = source[offset - 2..end], .target = span.target });
            var expected: ?[]const u8 = null;
            for (pairs, 0..) |pair, index| if (std.mem.eql(u8, pair[0], span.target)) {
                expected = pair[1]; counts[index] += 1; break;
            };
            if (expected) |target| try std.testing.expectEqualStrings(target, resolved orelse return error.TestUnexpectedResult)
            else try std.testing.expect(resolved == null);
        }
        try std.testing.expectEqual(@as(usize, 679), ordinary);
        try std.testing.expectEqualSlices(usize, &.{ 3, 4, 1, 3, 8, 6 }, &counts);
    }
} else struct {};

test "ordinary indexed table links keep fragment actions and cascade missing-page paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/en-empty-element271/namespace-registry.tsv"));
    defer ns.deinit();
    const rows = "0\t1\tPresent\t\t1\t2\t2026-01-01T00:00:00Z\tU\twikitext\t0\t1\t0\n";
    const titles = try variantTestIndex(a, rows);
    var styles = try encoder.table_style_profile.parseForTargetAlloc(a,
        ".inflection-table-right a.new { color: #000000; }\n.inflection-table-right a { color: #191970; }", .screen);
    defer styles.deinit();
    const source = "{| class=\"inflection-table-right\"\n|-\n| [[Autoversicherungen#Þýsk|form]] || [[Present#Absent section|entry]]\n|}";
    try std.testing.expect(TableLinkIndex.select(&ns, rows, titles, &styles) == null);
    try ns.attachLanguageConversion(@embedFile("testdata/en-empty-element271/namespace-siteinfo.raw.json"));
    try std.testing.expect(ns.literal_link_titles);
    var index = TableLinkIndex.select(&ns, rows, titles, &styles) orelse return error.TestUnexpectedResult;
    const selected = index.bind(source) orelse return error.TestUnexpectedResult;
    try std.testing.expect(index.bind("[[Absent]]") == null);
    try std.testing.expect(index.bind("{|\n| -{x}- [[Absent]]\n|}") == null);
    try std.testing.expect(TableLinkIndex.select(&ns, rows, titles, null) == null);
    for ([_][]const u8{ "#section", "../relative#section", "Category:Absent#section", "Encoded%2Ftitle", "Missing#one#two",
        "Absent/../Present", "Absent/./Present", "Absent/.", "Absent/..#part", "Unusable\u{fffd}#part" }) |raw| {
        const token = try std.fmt.allocPrint(a, "[[{s}]]", .{raw});
        try std.testing.expect(!try TableLinkIndex.missing(&index, a, .{ .source = token, .token = token, .target = token[2 .. token.len - 2] }));
    }
    for (0..2) |mode| {
        var renderer: encoder.presentation_compile.Renderer = .{ .a = a, .context = .{
            .title = "Host", .namespace_catalog = &ns, .table_styles = &styles,
            .local_link_targets = if (mode == 0) selected else index.bind(try a.dupe(u8, source)),
        } };
        const blocks = try renderer.renderBody(source);
        const cells = blocks[0].table.?.rows[0].cells;
        try std.testing.expectEqual(@as(usize, 2), cells.len);
        const missing_span = cells[0].spans[0];
        const present_span = cells[1].spans[0];
        try std.testing.expectEqualStrings("Autoversicherungen#Þýsk", missing_span.target);
        try std.testing.expectEqualStrings("form", missing_span.text);
        try std.testing.expectEqualStrings(if (mode == 0) "new" else "", missing_span.classes);
        try std.testing.expectEqualStrings(if (mode == 0) "#000000" else "#191970", missing_span.foreground.?);
        try std.testing.expectEqualStrings("Present#Absent section", present_span.target);
        try std.testing.expectEqualStrings("entry", present_span.text);
        try std.testing.expectEqualStrings("", present_span.classes);
        try std.testing.expectEqualStrings("#191970", present_span.foreground.?);
    }
}
