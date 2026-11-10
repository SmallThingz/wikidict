//! Optional build-only supplied-page observations. No source or HTML enters blobs.
const std = @import("std");
const encoder = @import("encoder");
const namespaces = @import("namespace_registry");
const sizing = @import("figure_sizing.zig");
const entities = @import("xml_decode").html_entities;
const compiler = encoder.presentation_compile;
const profile = encoder.table_style_profile;
const syntax = encoder.wikitext_syntax;
const A = std.mem.Allocator;
const Value = std.json.Value;
const invalid = error.InvalidFigurePageObservations;
pub const filename = "figure-page-observations.json";
pub const max_input: usize = 16 * 1024 * 1024;
const max_response: usize = 2 * 1024 * 1024;
const max_pages: usize = 256;
const max_occurrences: usize = 64;

pub const RawOccurrence = struct {
    start: usize,
    end: usize,
    canonical_file: []const u8,
    file_sha1: []const u8,
    file_timestamp: []const u8,
    original_width: u32,
    original_height: u32,
    width: bool = false,
    anchor_attributes: bool = false,
};
pub const RawPage = struct {
    namespace_id: i32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
    raw_sha256: []const u8,
    request: []const u8,
    form_body: []const u8,
    receipt: []const u8,
    response: []const u8,
    occurrences: []const RawOccurrence,
};
pub const Document = struct {
    schema: []const u8,
    wiki: []const u8,
    date: []const u8,
    namespace_sha256: []const u8,
    defaults_sha256: []const u8,
    pages: []const RawPage,
};
const Attribute = struct { name: []const u8, value: []const u8 };
const Inventory = struct {
    attributes: []const Attribute,
    fn get(self: Inventory, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
        return null;
    }
    fn presence(raw: ?*const anyopaque, name: []const u8) profile.AttributePresence {
        const self: *const Inventory = @ptrCast(@alignCast(raw orelse return .unknown));
        if (name.len == 0) return .unknown;
        for (name) |byte| if (!attributeNameByte(byte)) return .unknown;
        return if (self.get(name) != null) .present else .absent;
    }
};
const Occurrence = struct {
    canonical_file: []const u8,
    original_options: []const u8,
    width: ?u32,
    anchor: ?Inventory,
    centered_width: ?u32 = null,
};
const Page = struct {
    namespace_id: i32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
    raw_sha256: []const u8,
    source: []const u8,
    occurrences: []const Occurrence,
};
const SelectedOccurrence = struct { source: *const Occurrence, stage_options: []const u8 };
pub const SelectedPage = struct {
    namespace_catalog: *const namespaces.Registry,
    default_width: u32,
    occurrences: []const SelectedOccurrence,
    fn find(self: *const SelectedPage, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8) A.Error!?*const Occurrence {
        if (format_value != .thumbnail) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer a.free(canonical);
        for (self.occurrences) |selected| if (equal(canonical, selected.source.canonical_file) and
            (equal(options, selected.source.original_options) or equal(options, selected.stage_options))) return selected.source;
        return null;
    }
    pub fn width(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, base_width: u32) A.Error!?u32 {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        if (base_width != self.default_width) return null;
        return if (try self.find(a, file, format_value, options)) |occurrence| occurrence.width else null;
    }
    pub fn anchor(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8) A.Error!?profile.AttributePresenceSource {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        if (occurrence.anchor) |*anchor_inventory| return .{ .ctx = anchor_inventory, .get = Inventory.presence };
        return null;
    }
};

pub const Book = struct {
    arena: std.heap.ArenaAllocator,
    namespace_sha256: [32]u8,
    defaults_sha256: [32]u8,
    default_width: u32,
    pages: []const Page,
    pub fn init(parent: A, bytes: []const u8, ns: *const namespaces.Registry, registry: *const sizing.Registry, defaults_sha256: [32]u8, default_width: u32) !Book {
        if (bytes.len == 0 or bytes.len > max_input or default_width == 0 or !registry.file_authority) return invalid;
        var arena = std.heap.ArenaAllocator.init(parent);
        errdefer arena.deinit();
        const a = arena.allocator();
        const doc = (try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }));
        if (!equal(doc.schema, "wikidict.figure-page-observations.v1") or !equal(doc.wiki, ns.wiki) or !equal(doc.date, ns.dump_date) or
            !hashEqual(ns.source_sha256, doc.namespace_sha256) or !hashEqual(defaults_sha256, doc.defaults_sha256) or
            doc.pages.len == 0 or doc.pages.len > max_pages) return invalid;
        const pages = try a.alloc(Page, doc.pages.len);
        for (doc.pages, pages, 0..) |page, *out, index| {
            if (page.page_id == 0 or page.revision_id == 0 or page.title.len == 0 or !lowerHex(page.raw_sha256, 64) or
                page.occurrences.len == 0 or page.occurrences.len > max_occurrences) return invalid;
            _ = ns.storedPageSpec(page.title, page.namespace_id) catch return invalid;
            for (pages[0..index]) |old| if (old.page_id == page.page_id or
                (old.namespace_id == page.namespace_id and equal(old.title, page.title))) return invalid;
            const source_and_html = try responseSource(a, ns, page);
            const observed_images = try observedImages(a, ns, source_and_html.html, page.occurrences);
            const occurrences = try a.alloc(Occurrence, page.occurrences.len);
            for (page.occurrences, occurrences, 0..) |occurrence, *selected, occurrence_index| {
                if ((!occurrence.width and !occurrence.anchor_attributes) or occurrence.start >= occurrence.end or occurrence.end > source_and_html.source.len or
                    !lowerHex(occurrence.file_sha1, 40) or occurrence.file_timestamp.len == 0 or occurrence.original_width == 0 or occurrence.original_height == 0) return invalid;
                for (page.occurrences[0..occurrence_index]) |old| if (equal(old.canonical_file, occurrence.canonical_file) or
                    (old.start < occurrence.end and occurrence.start < old.end)) return invalid;
                const canonical = try canonicalFile(a, ns, occurrence.canonical_file);
                if (!equal(canonical, occurrence.canonical_file)) return invalid;
                var fact_found = false;
                for (registry.records) |fact| if (equal(fact.canonical_file, canonical)) {
                    if (!equal(fact.file_sha1, occurrence.file_sha1) or !equal(fact.file_timestamp, occurrence.file_timestamp) or
                        fact.original_width != occurrence.original_width or fact.original_height != occurrence.original_height) return invalid;
                    fact_found = true;
                    break;
                };
                if (!fact_found) return invalid;
                const options = try originalOptions(a, ns, source_and_html.source, occurrence);
                const image = observed_images[occurrence_index];
                selected.* = .{ .canonical_file = canonical, .original_options = options,
                    .width = if (occurrence.width) image.width else null,
                    .anchor = if (occurrence.anchor_attributes) image.anchor else null,
                    .centered_width = if (image.centered) image.width else null };
            }
            out.* = .{ .namespace_id = page.namespace_id, .page_id = page.page_id, .revision_id = page.revision_id, .title = page.title,
                .raw_sha256 = page.raw_sha256, .source = source_and_html.source, .occurrences = occurrences };
        }
        std.mem.sort(Page, pages, {}, struct {
            fn less(_: void, left: Page, right: Page) bool { return left.page_id < right.page_id; }
        }.less);
        return .{ .arena = arena, .namespace_sha256 = ns.source_sha256, .defaults_sha256 = defaults_sha256, .default_width = default_width, .pages = pages };
    }
    pub fn deinit(self: *Book) void { self.arena.deinit(); self.* = undefined; }
    // Called only with the complete original expansion, before source preparation.
    // `a` is the caller's existing page/process arena: selected arrays, normalized
    // options and the returned object are reclaimed together on success or error.
    // Book and namespace storage must outlive every selected page/worker and codec
    // construction; there is deliberately no individually-owned selected handle.
    pub fn select(self: *const Book, a: A, ns: *const namespaces.Registry, namespace_id: i32, page_id: u64, revision_id: u64, title: []const u8, raw: []const u8, expanded: []const u8, defaults_sha256: [32]u8, default_width: u32, context: compiler.Context) !?*const SelectedPage {
        if (!std.mem.eql(u8, &self.namespace_sha256, &ns.source_sha256) or !std.mem.eql(u8, &self.defaults_sha256, &defaults_sha256) or default_width != self.default_width) return null;
        const option_namespaces = context.namespace_catalog orelse return null;
        if (!equal(context.title, title) or !std.mem.eql(u8, &option_namespaces.source_sha256, &ns.source_sha256) or
            context.behavior_switches == null or context.image_options == null) return null;
        var first: usize = 0;
        var end = self.pages.len;
        while (first < end) {
            const middle = first + (end - first) / 2;
            if (self.pages[middle].page_id < page_id) first = middle + 1 else end = middle;
        }
        if (first < self.pages.len and self.pages[first].page_id == page_id) {
            const page = &self.pages[first];
            if (page.namespace_id != namespace_id or page.revision_id != revision_id or !equal(page.title, title)) return null;
            if (!digestMatches(raw, page.raw_sha256) or !equal(expanded, page.source)) return null;
            const selected = try a.alloc(SelectedOccurrence, page.occurrences.len);
            for (page.occurrences, selected) |*occurrence, *slot| {
                slot.* = .{ .source = occurrence, .stage_options = try compiler.figureObservationStageOptionsAlloc(a, occurrence.original_options, context) };
                if (occurrence.centered_width) |observed_width|
                    if (!centeredThumbnailOptions(context.image_options.?, slot.stage_options, observed_width)) return null;
            }
            const result = try a.create(SelectedPage);
            result.* = .{ .namespace_catalog = ns, .default_width = default_width, .occurrences = selected };
            return result;
        }
        return null;
    }
};

// A necessary proof for the additionally observed centered, explicit-width
// shape. Use the selected ordinary image-option registry and delimiter rules;
// the renderer still owns all placement, caption, style and sizing semantics.
fn centeredThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8, observed_width: u32) bool {
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at <= options.len) {
        if (count == parts.len) return false;
        const end = syntax.delimiter(options, "|", at) orelse options.len;
        parts[count] = std.mem.trim(u8, options[at..end], " \t\r\n"); count += 1;
        if (end == options.len) break;
        at = end + 1;
    }
    if (count != parts.len or observed_width == 0) return false;
    const format = registry.match(parts[0], .image) orelse return false;
    const horizontal = registry.match(parts[1], .image) orelse return false;
    const dimension = registry.match(parts[2], .image) orelse return false;
    if (!equal(format.id, "img_thumbnail") or format.value != null or
        !equal(horizontal.id, "img_center") or horizontal.value != null or
        !equal(dimension.id, "img_width") or registry.match(parts[3], .image) != null) return false;
    const width = dimension.value orelse return false;
    if (width.len == 0 or width.len > 10) return false;
    for (width) |byte| if (!std.ascii.isDigit(byte)) return false;
    return (std.fmt.parseInt(u32, width, 10) catch return false) == observed_width;
}

fn equal(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
fn lowerHex(value: []const u8, count: usize) bool {
    if (value.len != count) return false;
    for (value) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}
fn hashEqual(actual: [32]u8, expected: []const u8) bool {
    const text = std.fmt.bytesToHex(actual, .lower);
    return equal(&text, expected);
}
fn digestMatches(bytes: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return hashEqual(digest, expected);
}
fn field(value: Value, name: []const u8) !Value { return if (value == .object) value.object.get(name) orelse invalid else invalid; }
fn string(value: Value, name: []const u8) ![]const u8 { const item = try field(value, name); return if (item == .string) item.string else invalid; }
fn number(value: Value, name: []const u8) !u64 { const item = try field(value, name); return if (item == .integer and item.integer > 0) @intCast(item.integer) else invalid; }
fn flag(value: Value, name: []const u8, expected: bool) !void { const item = try field(value, name); if (item != .bool or item.bool != expected) return invalid; }
fn json(a: A, bytes: []const u8) !Value { if (bytes.len == 0 or bytes.len > max_response) return invalid; return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }); }
fn descriptor(bytes: []const u8, value: Value) !void { if (try number(value, "bytes") != bytes.len or !digestMatches(bytes, try string(value, "sha256"))) return invalid; }
fn canonicalFile(a: A, ns: *const namespaces.Registry, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "|\x00\r\n\t%") != null) return invalid;
    const value = try ns.normalizeTitle(a, raw, 6, .any);
    if (ns.ofTitle(value).id != 6) return invalid;
    return value;
}
fn formDecode(a: A, raw: []const u8) ![]const u8 {
    var at: usize = 0;
    while (at < raw.len) : (at += 1) if (raw[at] == '%') {
        if (raw.len - at < 3 or !std.ascii.isHex(raw[at + 1]) or !std.ascii.isHex(raw[at + 2])) return invalid;
        at += 2;
    };
    const bytes = try a.dupe(u8, raw);
    std.mem.replaceScalar(u8, bytes, '+', ' ');
    const result = std.Uri.percentDecodeInPlace(bytes);
    if (!std.unicode.utf8ValidateSlice(result) or std.mem.indexOfScalar(u8, result, 0) != null) return invalid;
    return result;
}
const Response = struct { source: []const u8, html: []const u8 };
fn responseSource(a: A, ns: *const namespaces.Registry, page: RawPage) !Response {
    if (page.form_body.len == 0 or page.form_body.len > 64 * 1024) return invalid;
    const request = try json(a, page.request);
    const receipt = try json(a, page.receipt);
    const response = try json(a, page.response);
    if (!equal(try string(request, "schema"), "wikidict.supplied-expanded-page-request.v1") or !equal(try string(request, "method"), "POST") or
        !equal(try string(request, "content_type"), "application/x-www-form-urlencoded; charset=utf-8") or
        try number(request, "page_id") != page.page_id or try number(request, "requested_revision_id") != page.revision_id or
        try number(request, "request_count") != 1 or try number(receipt, "request_count") != 1 or try number(receipt, "status") != 200) return invalid;
    try flag(request, "controlled_single_token", false); try flag(request, "full_supplied_expanded_page", true);
    try flag(request, "historical_transclusions", false); try flag(request, "parse_core_binding_proven", false); try flag(receipt, "accepted", true);
    try descriptor(page.request, try field(receipt, "request")); try descriptor(page.response, try field(receipt, "response"));
    try descriptor(page.form_body, try field(request, "form"));
    if (!std.mem.endsWith(u8, ns.wiki, "wiktionary") or ns.wiki.len <= "wiktionary".len) return invalid;
    const language = try a.dupe(u8, ns.wiki[0 .. ns.wiki.len - "wiktionary".len]);
    std.mem.replaceScalar(u8, language, '_', '-');
    const endpoint = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/api.php", .{language});
    if (!equal(try string(request, "url"), endpoint)) return invalid;
    const parameters = try field(request, "parameters_except_text");
    if (parameters != .object or parameters.object.count() != 10) return invalid;
    for ([_][2][]const u8{ .{ "action", "parse" }, .{ "format", "json" }, .{ "formatversion", "2" }, .{ "maxlag", "5" },
        .{ "contentmodel", "wikitext" }, .{ "prop", "text|wikitext|revid|displaytitle" }, .{ "parser", "legacy" }, .{ "usearticle", "1" } }) |pair|
        if (!equal(try string(parameters, pair[0]), pair[1])) return invalid;
    const requested_revision = std.fmt.parseInt(u64, try string(parameters, "revid"), 10) catch return invalid;
    if (!equal(try string(parameters, "title"), page.title) or requested_revision != page.revision_id) return invalid;
    var parts = std.mem.splitScalar(u8, page.form_body, '&');
    var found: std.StringHashMapUnmanaged(void) = .empty;
    var source: ?[]const u8 = null;
    while (parts.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return invalid;
        const key = try formDecode(a, part[0..split]); const value = try formDecode(a, part[split + 1 ..]);
        if ((try found.getOrPut(a, key)).found_existing) return invalid;
        if (equal(key, "text")) source = value else if (!equal(try string(parameters, key), value)) return invalid;
    }
    if (found.count() != 11) return invalid;
    const text = source orelse return invalid;
    try descriptor(text, try field(request, "text_source"));
    if (response != .object or response.object.contains("error") or response.object.contains("warnings")) return invalid;
    const parsed = try field(response, "parse");
    if (!equal(try string(parsed, "title"), page.title) or try number(parsed, "pageid") != page.page_id or !equal(try string(parsed, "wikitext"), text)) return invalid;
    if (parsed.object.get("revid")) |revision| if (revision != .null and try number(parsed, "revid") != page.revision_id) return invalid;
    const html = try string(parsed, "text");
    if (html.len == 0 or html.len > max_response or !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return invalid;
    return .{ .source = text, .html = html };
}

fn originalOptions(a: A, ns: *const namespaces.Registry, source: []const u8, occurrence: RawOccurrence) ![]const u8 {
    const raw = source[occurrence.start..occurrence.end];
    var iterator: encoder.document_ir.InlineIterator = .{ .input = raw, .renderer_boundaries = true };
    const node = iterator.next() orelse return invalid;
    const selected_target = (try compiler.figureObservationFileTargetAlloc(a, node.target, .{ .namespace_catalog = ns })) orelse return invalid;
    if (node.kind != .link or !node.link_has_pipe or node.link_empty_label or node.link_label_restored_close or node.trail.len != 0 or iterator.cursor != raw.len or
        !equal(try canonicalFile(a, ns, selected_target), occurrence.canonical_file)) return invalid;
    var count: usize = 0;
    var selected_range = false;
    var at: usize = 0;
    var opaque_scan: syntax.OpaqueScan = .{};
    while (at < source.len) {
        if (opaque_scan.protectedEnd(source, at, null)) |end| { at = end; continue; }
        if (source[at] == '<') if (syntax.tagAt(source, at)) |tag| { at = tag.end; continue; };
        if (source[at] == '[' or source[at] == '{') {
            var scan: encoder.document_ir.InlineIterator = .{ .input = source, .cursor = at, .renderer_boundaries = true };
            if (scan.next()) |token| {
                // Do not descend into another link label or template argument:
                // its source is not an independent ordinary Figure occurrence.
                if (token.kind == .link or token.kind == .external_link or token.kind == .template) {
                    if (token.kind == .link) {
                        if (try compiler.figureObservationFileTargetAlloc(a, token.target, .{ .namespace_catalog = ns })) |target| {
                            const file = try canonicalFile(a, ns, target);
                            if (equal(file, occurrence.canonical_file)) {
                                count += 1;
                                selected_range = at == occurrence.start and scan.cursor - token.trail.len == occurrence.end;
                            }
                        }
                    }
                    if (scan.cursor <= at) return invalid;
                    at = scan.cursor;
                    continue;
                }
                if (token.literal_tail or token.rejected_external_opener) return invalid;
            }
        }
        at += 1;
    }
    if (count != 1 or !selected_range) return invalid;
    return node.text;
}
fn attributeNameByte(byte: u8) bool { return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':'; }
fn decodedAttribute(a: A, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < raw.len) {
        if (raw[at] != '&') { try out.append(a, raw[at]); at += 1; continue; }
        const end = std.mem.indexOfScalarPos(u8, raw, at + 1, ';') orelse return invalid;
        const name = raw[at + 1 .. end];
        if (name.len == 0) return invalid;
        if (name[0] == '#') {
            const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
            const digits = name[if (hex) @as(usize, 2) else 1 ..];
            const point = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return invalid;
            if (point == 0 or point == 0xfffd or (point >= 0xd800 and point <= 0xdfff) or point > 0x10ffff) return invalid;
            var scratch: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(point, &scratch) catch return invalid;
            try out.appendSlice(a, scratch[0..length]);
        } else try out.appendSlice(a, entities.lookupHtmlNamedEntity(name) orelse return invalid);
        at = end + 1;
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return invalid;
    return out.toOwnedSlice(a);
}
fn inventory(a: A, tag: syntax.Tag) !Inventory {
    var attributes: std.ArrayList(Attribute) = .empty;
    var at: usize = 0;
    while (at < tag.attrs.len) {
        if (!std.ascii.isWhitespace(tag.attrs[at])) return invalid;
        while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len) break;
        const start = at;
        while (at < tag.attrs.len and attributeNameByte(tag.attrs[at])) : (at += 1) {}
        if (start == at or attributes.items.len >= 64) return invalid;
        const name = tag.attrs[start..at];
        for (attributes.items) |old| if (std.ascii.eqlIgnoreCase(old.name, name)) return invalid;
        while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len or tag.attrs[at] != '=') return invalid;
        at += 1;
        while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len or (tag.attrs[at] != '"' and tag.attrs[at] != '\'')) return invalid;
        const quote = tag.attrs[at]; at += 1; const value_start = at;
        while (at < tag.attrs.len and tag.attrs[at] != quote) : (at += 1) if (tag.attrs[at] == '<' or tag.attrs[at] == '>' or tag.attrs[at] == 0) return invalid;
        if (at == tag.attrs.len) return invalid;
        const value = try decodedAttribute(a, tag.attrs[value_start..at]); at += 1;
        try attributes.append(a, .{ .name = name, .value = value });
    }
    return .{ .attributes = try attributes.toOwnedSlice(a) };
}
fn positiveAttribute(inv: Inventory, name: []const u8) !u32 {
    const raw = inv.get(name) orelse return invalid;
    if (raw.len == 0 or raw.len > 10) return invalid;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return invalid;
    const value = std.fmt.parseInt(u32, raw, 10) catch return invalid;
    return if (value > 0) value else invalid;
}
fn fileHref(a: A, ns: *const namespaces.Registry, href: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, href, "/wiki/") or std.mem.indexOfAny(u8, href, "?#&\\\r\n\t") != null) return null;
    const decoded = try a.dupe(u8, href[6..]);
    const title = std.Uri.percentDecodeInPlace(decoded);
    // A missing explicit File prefix must not turn an ordinary article into an image.
    if (ns.ofTitle(title).id != 6) return null;
    return canonicalFile(a, ns, title) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
}
const ObservedImage = struct { width: u32, anchor: Inventory, centered: bool = false };
fn imageSource(a: A, ns: *const namespaces.Registry, raw: []const u8, canonical_file: []const u8) !void {
    const url = if (std.mem.startsWith(u8, raw, "https://")) raw[8..] else if (std.mem.startsWith(u8, raw, "//")) raw[2..] else return invalid;
    const slash = std.mem.indexOfScalar(u8, url, '/') orelse return invalid;
    if ((!equal(url[0..slash], "thumb.wikimedia.org") and !equal(url[0..slash], "upload.wikimedia.org")) or
        std.mem.indexOfAny(u8, url, "#\r\n\t\\") != null) return invalid;
    const query = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    var path = std.mem.splitScalar(u8, url[slash..query], '/');
    var names: usize = 0;
    const expected = ns.ofTitle(canonical_file).text;
    while (path.next()) |part| {
        if (part.len == 0) continue;
        var at: usize = 0;
        while (at < part.len) : (at += 1) if (part[at] == '%') {
            if (part.len - at < 3 or !std.ascii.isHex(part[at + 1]) or !std.ascii.isHex(part[at + 2])) return invalid;
            at += 2;
        };
        const storage = try a.dupe(u8, part);
        const decoded = std.Uri.percentDecodeInPlace(storage);
        std.mem.replaceScalar(u8, decoded, '_', ' ');
        if (equal(decoded, expected)) names += 1;
    }
    if (names != 1) return invalid;
}
fn observedImages(a: A, ns: *const namespaces.Registry, html: []const u8, occurrences: []const RawOccurrence) ![]const ObservedImage {
    const Open = struct { tag: syntax.Tag, attributes: Inventory };
    var stack: [128]Open = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    const anchors = try a.alloc(usize, occurrences.len);
    const images = try a.alloc(usize, occurrences.len);
    const selected = try a.alloc(ObservedImage, occurrences.len);
    @memset(anchors, 0);
    @memset(images, 0);
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            if (depth > 0 and stack[depth - 1].tag.is("audio")) return invalid;
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (html[at] != '<') {
            if (depth > 0 and stack[depth - 1].tag.is("audio") and !std.ascii.isWhitespace(html[at])) return invalid;
            at += 1; continue;
        }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at or tag.end > html.len) return invalid;
        const inv = try inventory(a, tag);
        if (tag.closing) {
            if (inv.attributes.len != 0 or depth == 0 or !std.ascii.eqlIgnoreCase(stack[depth - 1].tag.name, tag.name)) return invalid;
            depth -= 1; at = tag.end; continue;
        }
        const is_void = std.ascii.eqlIgnoreCase(tag.name, "area") or std.ascii.eqlIgnoreCase(tag.name, "base") or std.ascii.eqlIgnoreCase(tag.name, "br") or
            std.ascii.eqlIgnoreCase(tag.name, "col") or std.ascii.eqlIgnoreCase(tag.name, "embed") or std.ascii.eqlIgnoreCase(tag.name, "hr") or
            std.ascii.eqlIgnoreCase(tag.name, "img") or std.ascii.eqlIgnoreCase(tag.name, "input") or std.ascii.eqlIgnoreCase(tag.name, "link") or
            std.ascii.eqlIgnoreCase(tag.name, "meta") or std.ascii.eqlIgnoreCase(tag.name, "param") or std.ascii.eqlIgnoreCase(tag.name, "source") or
            std.ascii.eqlIgnoreCase(tag.name, "track") or std.ascii.eqlIgnoreCase(tag.name, "wbr");
        // Pronunciation audio may contain only direct void SOURCE children
        // and whitespace. No fallback body can lend a Figure or anchor proof.
        const audio_child = depth > 0 and stack[depth - 1].tag.is("audio");
        if ((audio_child and !tag.is("source")) or (tag.is("source") and !audio_child)) return invalid;
        // This is a bounded ordinary-HTML evidence grammar. Unknown insertion
        // modes (SELECT), inert/foreign trees and RCDATA/raw-text containers
        // cannot borrow a literal-looking Figure as a live DOM occurrence.
        var ordinary_tag = false;
        for ([_][]const u8{ "div", "span", "a", "figure", "figcaption", "img", "meta", "link", "style",
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
            "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "pre", "font", "audio", "source" }) |name|
            if (tag.is(name)) { ordinary_tag = true; break; };
        if (!ordinary_tag or ((tag.self_closing or (tag.end >= 2 and html[tag.end - 2] == '/')) and !is_void)) return invalid;
        // STYLE is an HTML raw-text element. Its complete bytes stay in the
        // retained response, but cannot create an observed image or anchor.
        if (tag.is("style")) {
            const close = std.mem.indexOfPos(u8, html, tag.end, "</style>") orelse return invalid;
            at = close + "</style>".len;
            continue;
        }
        if (tag.is("a")) if (inv.get("href")) |href| if (try fileHref(a, ns, href)) |file| {
            for (occurrences, 0..) |occurrence, index| if (equal(file, occurrence.canonical_file)) { anchors[index] += 1; };
        };
        if (tag.is("img") and depth >= 2 and stack[depth - 1].tag.is("a") and stack[depth - 2].tag.is("figure")) {
            const anchor = stack[depth - 1].attributes;
            if (anchor.get("href")) |href| if (try fileHref(a, ns, href)) |file| for (occurrences, 0..) |occurrence, index| {
                if (!equal(file, occurrence.canonical_file)) continue;
                const figure_classes = stack[depth - 2].attributes.get("class") orelse return invalid;
                const centered = equal(figure_classes, "mw-halign-center");
                if (!equal(stack[depth - 2].attributes.get("typeof") orelse return invalid, "mw:File/Thumb") or
                    (!equal(figure_classes, "mw-default-size") and
                        !(centered and occurrence.anchor_attributes and !occurrence.width)) or
                    !equal(anchor.get("class") orelse return invalid, "mw-file-description") or
                    try positiveAttribute(inv, "data-file-width") != occurrence.original_width or try positiveAttribute(inv, "data-file-height") != occurrence.original_height) return invalid;
                for (anchor.attributes) |attr| if (!equal(attr.name, "href") and !equal(attr.name, "class") and !equal(attr.name, "rel") and !equal(attr.name, "title")) return invalid;
                for (stack[depth - 2].attributes.attributes) |attr| if (!equal(attr.name, "class") and !equal(attr.name, "typeof")) return invalid;
                try imageSource(a, ns, inv.get("src") orelse return invalid, occurrence.canonical_file);
                const image_classes = inv.get("class") orelse return invalid;
                if (!equal(image_classes, "mw-file-element") and !equal(image_classes, "mw-file-element mw-file-upright")) return invalid;
                for (inv.attributes) |attr| {
                    var known = false;
                    for ([_][]const u8{ "src", "decoding", "loading", "width", "height", "style", "class", "srcset", "data-file-width", "data-file-height", "alt", "title" }) |name|
                        if (std.ascii.eqlIgnoreCase(attr.name, name)) { known = true; break; };
                    if (!known) return invalid;
                }
                if (inv.get("style")) |css| {
                    // Retain the observed upright property, without deriving a
                    // factor or accepting unrelated inline rendering changes.
                    const prefix = "--mw-file-upright:";
                    const clean = std.mem.trim(u8, css, " \t");
                    if (!std.mem.startsWith(u8, clean, prefix)) return invalid;
                    const factor = std.fmt.parseFloat(f64, std.mem.trim(u8, clean[prefix.len..], " \t")) catch return invalid;
                    if (!std.math.isFinite(factor) or factor <= 0) return invalid;
                }
                images[index] += 1;
                const width = try positiveAttribute(inv, "width");
                if (centered and width > occurrence.original_width) return invalid;
                selected[index] = .{ .width = width, .anchor = anchor, .centered = centered };
                _ = try positiveAttribute(inv, "height");
            };
        }
        if (!is_void) {
            if (depth == stack.len) return invalid;
            stack[depth] = .{ .tag = tag, .attributes = inv }; depth += 1;
        }
        at = tag.end;
    }
    if (depth != 0) return invalid;
    for (anchors, images) |anchor_count, image_count| if (anchor_count != 1 or image_count != 1) return invalid;
    return selected;
}


// Controlled Registry rows below exercise the input validator's boundary only.
// The full saved Writer regressions load the independent normal Registry files.
pub const Testing = if (@import("builtin").is_test) struct {
    pub fn document(a: A, comptime edition: []const u8) !Document {
        return std.json.parseFromSliceLeaky(Document, a,
            @embedFile("testdata/figure-page-observations/" ++ edition ++ "/figure-page-observations.json"), .{ .allocate = .alloc_always });
    }
    pub fn registry(a: A, ns: *const namespaces.Registry, doc: Document) !sizing.Registry {
        var count: usize = 0;
        for (doc.pages) |page| count += page.occurrences.len;
        const rows = try a.alloc(sizing.Record, count);
        var index: usize = 0;
        for (doc.pages) |page| for (page.occurrences) |occurrence| {
            const row = &rows[index]; index += 1; row.* = .{
            .canonical_file = occurrence.canonical_file, .file_sha1 = occurrence.file_sha1, .file_timestamp = occurrence.file_timestamp,
            .original_width = occurrence.original_width, .original_height = occurrence.original_height,
            .format = .thumbnail, .width_px = occurrence.original_width, .height_px = null,
            .sizing = .requested_fit, .proof_kind = "controlled-validator-file-row",
            };
        };
        return .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = ns, .records = rows, .file_authority = true };
    }
    pub fn hash(bytes: []const u8) [32]u8 {
        var value: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
        return value;
    }
    pub fn source(a: A, doc: Document) ![]const u8 { return string(try field(try json(a, doc.pages[0].response), "parse"), "wikitext"); }
    pub fn html(a: A, doc: Document) ![]const u8 { return string(try field(try json(a, doc.pages[0].response), "parse"), "text"); }
} else struct {};

test "supplied Figure Book selects only the exact original page source defaults and normalized options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const bytes = @embedFile("testdata/figure-page-observations/it/figure-page-observations.json");
    const raw = @embedFile("testdata/figure-page-observations/it/page.raw.wikitext");
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/it/figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/figure-page-observations/it/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/it/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    const doc = try Testing.document(a, "it");
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const source = try Testing.source(a, doc);
    const context: compiler.Context = .{ .title = "poliziotto", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer page_arena.deinit();
    const selected = (try book.select(page_arena.allocator(), &ns, 0, 4075, 3935048, "poliziotto", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    for (selected.occurrences) |row| {
        try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 250));
        try std.testing.expect((try SelectedPage.anchor(selected, a, row.source.canonical_file, .thumbnail, row.stage_options)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .framed, row.stage_options, 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 251)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, "thumb|upright|changed", 250)) == null);
    }
    const copied = try a.dupe(u8, source); copied[0] = if (copied[0] == 'X') 'Y' else 'X';
    for ([_]struct { ns: i32 = 0, page: u64 = 4075, revision: u64 = 3935048, title: []const u8 = "poliziotto", raw: []const u8, source: []const u8, width: u32 = 250 }{
        .{ .ns = 1, .raw = raw, .source = source }, .{ .page = 4076, .raw = raw, .source = source },
        .{ .revision = 3935049, .raw = raw, .source = source }, .{ .title = "other", .raw = raw, .source = source },
        .{ .raw = "changed raw", .source = source }, .{ .raw = raw, .source = copied }, .{ .raw = raw, .source = source, .width = 251 },
    }) |case| try std.testing.expect((try book.select(page_arena.allocator(), &ns, case.ns, case.page, case.revision, case.title, case.raw, case.source, defaults, case.width, context)) == null);
    var stale_defaults = defaults; stale_defaults[0] ^= 1;
    try std.testing.expect((try book.select(page_arena.allocator(), &ns, 0, 4075, 3935048, "poliziotto", raw, source, stale_defaults, 250, context)) == null);
    var no_options = context; no_options.image_options = null;
    try std.testing.expect((try book.select(page_arena.allocator(), &ns, 0, 4075, 3935048, "poliziotto", raw, source, defaults, 250, no_options)) == null);
    const last = selected.occurrences[selected.occurrences.len - 1];
    try std.testing.expect(!equal(last.source.original_options, last.stage_options));
    try std.testing.expect(std.mem.indexOf(u8, last.stage_options, "<b>poliziotto</b>") != null);
}

test "supplied Figure Book rejects inactive DOM containers and duplicate returned occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "it"); const html = try Testing.html(a, doc);
    const positive = try observedImages(a, &ns, html, doc.pages[0].occurrences);
    try std.testing.expectEqual(@as(usize, 2), positive.len);
    for (positive) |row| try std.testing.expectEqual(@as(u32, 190), row.width);
    for ([_][]const u8{ "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript", "template", "svg", "math", "object", "audio", "video", "select", "option", "optgroup", "datalist", "frameset" }) |tag| {
        errdefer std.debug.print("Book inactive DOM tag={s}\n", .{tag});
        const wrapped = try std.fmt.allocPrint(a, "<{s}>{s}</{s}>", .{ tag, html, tag });
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, wrapped, doc.pages[0].occurrences));
    }
    try std.testing.expectError(error.InvalidFigurePageObservations,
        observedImages(a, &ns, try std.mem.concat(a, u8, &.{ html, html }), doc.pages[0].occurrences));
    const zero = try std.mem.replaceOwned(u8, a, html, "width=\"190\"", "width=\"0\"");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, zero, doc.pages[0].occurrences));
    const wrong_axes = try std.mem.replaceOwned(u8, a, html, "data-file-width=\"1360\"", "data-file-width=\"1361\"");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, wrong_axes, doc.pages[0].occurrences));
}

test "supplied Figure Book source occurrence cannot borrow a protected attribute or nested same-file token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "it"); var occurrence = doc.pages[0].occurrences[0];
    const token = try std.fmt.allocPrint(a, "[[{s}|thumb|upright|caption]]", .{occurrence.canonical_file});
    occurrence.start = 0; occurrence.end = token.len;
    try std.testing.expectEqualStrings("thumb|upright|caption", try originalOptions(a, &ns, token, occurrence));
    for ([_][2][]const u8{
        .{ "<nowiki>", "</nowiki>" }, .{ "<!--", "-->" }, .{ "<span title=\"", "\"></span>" },
        .{ "[[Article|", "]]" }, .{ "[https://example.test/ ", "]" }, .{ "{{Template|", "}}" },
    }) |wrapper| {
        const source = try std.fmt.allocPrint(a, "{s}{s}{s}\n{s}", .{ wrapper[0], token, wrapper[1], token });
        occurrence.start = wrapper[0].len; occurrence.end = occurrence.start + token.len;
        errdefer std.debug.print("Book selected hidden source prefix={s}\n", .{wrapper[0]});
        try std.testing.expectError(error.InvalidFigurePageObservations, originalOptions(a, &ns, source, occurrence));
    }
    occurrence.start = 0; occurrence.end = token.len;
    const duplicate = try std.fmt.allocPrint(a, "{s}\n{s}", .{ token, token });
    try std.testing.expectError(error.InvalidFigurePageObservations, originalOptions(a, &ns, duplicate, occurrence));
    const article = "[[Article|thumb|upright|caption]]";
    occurrence.end = article.len;
    try std.testing.expectError(error.InvalidFigurePageObservations, originalOptions(a, &ns, article, occurrence));
}

test "supplied Figure Book complete anchor inventory distinguishes absent empty present and duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_]struct { opening: []const u8, state: profile.AttributePresence }{
        .{ .opening = "<a href=\"/wiki/File:X.jpg\" class=\"mw-file-description\">", .state = .absent },
        .{ .opening = "<a href=\"/wiki/File:X.jpg\" rel=\"\">", .state = .present },
        .{ .opening = "<a href=\"/wiki/File:X.jpg\" REL=\"mw:referencedBy\">", .state = .present },
    }) |case| {
        const tag = syntax.tagAt(case.opening, 0) orelse return error.TestUnexpectedResult;
        const attributes = try inventory(a, tag);
        try std.testing.expectEqual(case.state, Inventory.presence(&attributes, "rel"));
        try std.testing.expectEqual(case.state, Inventory.presence(&attributes, "REL"));
        try std.testing.expectEqual(profile.AttributePresence.present, Inventory.presence(&attributes, "href"));
    }
    for ([_][]const u8{ "<a rel=\"\" REL=\"present\">", "<a rel=unquoted>", "<a rel=\"unclosed>" }) |opening| {
        if (syntax.tagAt(opening, 0)) |tag| try std.testing.expectError(error.InvalidFigurePageObservations, inventory(a, tag));
    }
    try std.testing.expectEqual(profile.AttributePresence.unknown, Inventory.presence(null, "rel"));
}


test "observed centered explicit thumbnail exposes only exact original page anchor attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/hsb-two-pages/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    const doc = try Testing.document(a, "hsb-two-pages");
    try std.testing.expectEqual(@as(usize, 2), doc.pages.len);
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const raw = @embedFile(prefix ++ "sarko.raw.wikitext");
    const source = @embedFile(prefix ++ "sarko.expanded.wikitext");
    const context: compiler.Context = .{ .title = "ŝarko", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const selected = (try book.select(a, &ns, 0, 5804, 16516, "ŝarko", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
    const row = selected.occurrences[0];
    try std.testing.expectEqualStrings("thumb|center|200px| Ŝarko", row.stage_options);
    const attributes = (try SelectedPage.anchor(selected, a, "Great white shark south africa.jpg", .thumbnail, row.stage_options)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(profile.AttributePresence.absent, attributes.get(attributes.ctx, "rel"));
    try std.testing.expectEqual(profile.AttributePresence.present, attributes.get(attributes.ctx, "href"));
    try std.testing.expectEqual(profile.AttributePresence.present, attributes.get(attributes.ctx, "class"));
    try std.testing.expect((try SelectedPage.width(selected, a, "Great white shark south africa.jpg", .thumbnail, row.stage_options, 250)) == null);
    try std.testing.expect((try SelectedPage.anchor(selected, a, "Other.jpg", .thumbnail, row.stage_options)) == null);
    try std.testing.expect((try SelectedPage.anchor(selected, a, "Great white shark south africa.jpg", .framed, row.stage_options)) == null);
    const aliases = try std.mem.replaceOwned(u8, a, source, "|thumb|center|200px|", "|mini|zentriert|200px|");
    try std.testing.expect((try book.select(a, &ns, 0, 5804, 16516, "ŝarko", raw, aliases, defaults, 250, context)) == null);
    try std.testing.expect((try SelectedPage.anchor(selected, a, "Great white shark south africa.jpg", .thumbnail, "mini|zentriert|200px| Ŝarko")) == null);
    try std.testing.expect(centeredThumbnailOptions(&images, "thumb|center|200px| Ŝarko", 200));
    try std.testing.expect(centeredThumbnailOptions(&images, "mini|zentriert|200px| Ŝarko", 200));
    for ([_][]const u8{
        "thumb|right|200px| Ŝarko", "framed|center|200px| Ŝarko", "thumb|center|x200px| Ŝarko",
        "thumb|center|200x146px| Ŝarko", "thumb|center|0px| Ŝarko", "thumb|center|201px| Ŝarko",
        "thumb|center|200px|link=Target", "thumb|center|200px| Ŝarko|extra", "thumb|200px|caption center",
    }) |options| {
        errdefer std.debug.print("centered observation options refusal={s}\n", .{options});
        try std.testing.expect(!centeredThumbnailOptions(&images, options, 200));
    }
    // Adding the second page preserves the previously observed original page.
    var original_context = context; original_context.title = "maćeršćina";
    try std.testing.expect((try book.select(a, &ns, 0, 332, 18318, "maćeršćina",
        @embedFile("testdata/figure-page-observations/hsb/page.raw.wikitext"), try Testing.source(a, doc), defaults, 250, original_context)) != null);
}

test "centered observed HTML cannot grant width or unsupported classes formats or oversized axes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/hsb-two-pages/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "hsb-two-pages");
    const page = doc.pages[1];
    const html = @embedFile(prefix ++ "sarko.observed-full.html");
    const observed = try observedImages(a, &ns, html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expect(observed[0].centered);
    try std.testing.expectEqual(@as(u32, 200), observed[0].width);
    var wider = page.occurrences[0]; wider.width = true;
    try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, html, &.{wider}));
    for ([_][2][]const u8{
        .{ "class=\"mw-halign-center\"", "class=\"mw-halign-center extra\"" },
        .{ "typeof=\"mw:File/Thumb\"", "typeof=\"mw:File/Frame\"" },
        .{ "width=\"200\"", "width=\"910\"" },
        .{ "class=\"mw-file-description\"", "class=\"mw-file-description\" CLASS=\"duplicate\"" },
    }) |change| {
        errdefer std.debug.print("centered observation HTML refusal={s}\n", .{change[1]});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, change[0]));
        const invalid_html = try std.mem.replaceOwned(u8, a, html, change[0], change[1]);
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, invalid_html, page.occurrences));
    }
}

test "supplied Figure Book retains complete Thai pages with source-only audio and exact upright widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = @embedFile("testdata/figure-page-observations/th-upright/figure-page-observations.json");
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/th-upright/figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-upright/namespace-registry.tsv"));
    defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/figure-page-observations/th-upright/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256);
    defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/th-upright/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes));
    defer options.deinit();
    const doc = try Testing.document(a, "th-upright");
    var files = try Testing.registry(a, &ns, doc);
    defer files.deinit();
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250);
    defer book.deinit();
    const raw_sources = [_][]const u8{
        @embedFile("testdata/figure-page-observations/th-upright/16614.raw.wikitext"),
        @embedFile("testdata/figure-page-observations/th-upright/30858.raw.wikitext"),
    };
    try std.testing.expectEqual(@as(usize, 2), doc.pages.len);
    for (doc.pages, raw_sources) |page, raw| {
        var member: []const u8 = "full source and normal selected context";
        errdefer std.debug.print("TH supplied Figure page={d} title={s} member={s}\n", .{page.page_id, page.title, member});
        var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page_arena.deinit();
        const page_a = page_arena.allocator();
        const parsed = try field(try json(a, page.response), "parse");
        const source = try string(parsed, "wikitext");
        const html = try string(parsed, "text");
        const context: compiler.Context = .{ .title = page.title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
        const selected = (try book.select(page_a, &ns, page.namespace_id, page.page_id, page.revision_id, page.title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
        member = "literal full HTML client width and capability";
        try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
        const observed = try observedImages(a, &ns, html, page.occurrences);
        try std.testing.expectEqual(@as(usize, 1), observed.len);
        try std.testing.expectEqual(@as(u32, 190), observed[0].width);
        const row = selected.occurrences[0];
        try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 250));
        try std.testing.expect((try SelectedPage.anchor(selected, a, row.source.canonical_file, .thumbnail, row.stage_options)) == null);
        member = "changed options default and complete source refuse";
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, "thumb|upright|changed", 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 251)) == null);
        const changed = try std.mem.concat(page_a, u8, &.{source, " "});
        try std.testing.expect((try book.select(page_a, &ns, page.namespace_id, page.page_id, page.revision_id, page.title, raw, changed, defaults, 250, context)) == null);
    }
}

test "supplied Figure Book audio evidence refuses fallback figures links text nesting and misplaced source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv"));
    defer ns.deinit();
    const doc = try Testing.document(a, "it");
    const html = try Testing.html(a, doc);
    const source = "<source src=\"https://example.invalid/pronunciation.ogg\" type=\"audio/ogg\" />";
    const positive = try std.mem.concat(a, u8, &.{ "<audio controls=\"\"> \n", source, "\t</audio>", html });
    const images = try observedImages(a, &ns, positive, doc.pages[0].occurrences);
    try std.testing.expectEqual(@as(usize, 2), images.len);
    for ([_][]const u8{
        "<audio>fallback text</audio>", "<audio>&#32;</audio>",
        "<audio><!-- hidden fallback --></audio>",
        "<audio><span>fallback</span></audio>", "<audio><a href=\"/wiki/File:Other.jpg\">fallback</a></audio>",
        "<audio><img src=\"https://example.invalid/other.jpg\" /></audio>",
        "<audio><figure></figure></audio>", "<audio><audio></audio></audio>",
        "<audio><style></style></audio>", "<audio><source /></video>", "<audio />", "<audio/>",
        "<source />", "<div><source /></div>", "<audio><source><span></span></audio>",
    }) |prefix| {
        errdefer std.debug.print("Book audio refused evidence prefix={s}\n", .{prefix});
        try std.testing.expectError(error.InvalidFigurePageObservations,
            observedImages(a, &ns, try std.mem.concat(a, u8, &.{prefix, html}), doc.pages[0].occurrences));
    }
    try std.testing.expectError(error.InvalidFigurePageObservations,
        observedImages(a, &ns, try std.mem.concat(a, u8, &.{ "<audio>", html, "</audio>" }), doc.pages[0].occurrences));
}

test "supplied Figure Book retains complete English edition bibliography pages and exact upright widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/en-upright/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv"));
    defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256);
    defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes));
    defer options.deinit();
    const doc = try Testing.document(a, "en-upright");
    var files = try Testing.registry(a, &ns, doc);
    defer files.deinit();
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250);
    defer book.deinit();
    const raw_sources = [_][]const u8{
        @embedFile(prefix ++ "10505709.raw.wikitext"),
        @embedFile(prefix ++ "10528333.raw.wikitext"),
    };
    const cases = [_]struct { page_id: u64, title: []const u8, owner_heading: []const u8, figure_count: usize, cite_count: usize, image_axes: []const u8, caption_part: []const u8 }{
        .{ .page_id = 10505709, .title = "barnsjukdom", .owner_heading = "==Swedish==", .figure_count = 1, .cite_count = 10, .image_axes = "width=\"190\" height=\"281\"", .caption_part = "<a href=\"/wiki/nurse#Noun\" title=\"nurse\">nurse</a>" },
        .{ .page_id = 10528333, .title = "rous", .owner_heading = "==Czech==", .figure_count = 2, .cite_count = 3, .image_axes = "width=\"190\" height=\"234\"", .caption_part = "<figcaption>rousy</figcaption>" },
    };
    try std.testing.expectEqual(@as(usize, 2), doc.pages.len);
    for (doc.pages, raw_sources, cases) |page, raw, case| {
        var member: []const u8 = "complete source and observation identity";
        errdefer std.debug.print("EN supplied Figure title={s} member={s}\n", .{ page.title, member });
        var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer page_arena.deinit();
        const page_a = page_arena.allocator();
        const parsed = try field(try json(a, page.response), "parse");
        const source = try string(parsed, "wikitext");
        const html = try string(parsed, "text");
        try std.testing.expectEqual(case.page_id, page.page_id);
        try std.testing.expectEqualStrings(case.title, page.title);
        try std.testing.expect(std.mem.indexOf(u8, raw, case.owner_heading) != null);
        try std.testing.expect(std.mem.indexOf(u8, source, case.owner_heading) != null);
        try std.testing.expectEqual(case.figure_count, std.mem.count(u8, html, "<figure "));
        try std.testing.expectEqual(case.cite_count, std.mem.count(u8, html, "<cite>"));
        try std.testing.expectEqual(case.cite_count, std.mem.count(u8, html, "</cite>"));
        try std.testing.expect(std.mem.indexOf(u8, html, case.image_axes) != null);
        try std.testing.expect(std.mem.indexOf(u8, html, case.caption_part) != null);
        const context: compiler.Context = .{ .title = page.title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
        const selected = (try book.select(page_a, &ns, page.namespace_id, page.page_id, page.revision_id, page.title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
        member = "unique selected Figure and exact observed width-only capability";
        try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
        const observed = try observedImages(a, &ns, html, page.occurrences);
        try std.testing.expectEqual(@as(usize, 1), observed.len);
        try std.testing.expectEqual(@as(u32, 190), observed[0].width);
        const row = selected.occurrences[0];
        try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 250));
        try std.testing.expect((try SelectedPage.anchor(selected, a, row.source.canonical_file, .thumbnail, row.stage_options)) == null);
        member = "source title identity options defaults and other file cannot borrow width";
        try std.testing.expect((try SelectedPage.width(selected, a, "File:Wikipedia-logo-v2.svg", .thumbnail, row.stage_options, 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, "thumb|upright|changed", 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, row.source.canonical_file, .thumbnail, row.stage_options, 251)) == null);
        const changed = try std.mem.concat(page_a, u8, &.{ source, " " });
        try std.testing.expect((try book.select(page_a, &ns, page.namespace_id, page.page_id, page.revision_id, page.title, raw, changed, defaults, 250, context)) == null);
        try std.testing.expect((try book.select(page_a, &ns, page.namespace_id, page.page_id, page.revision_id, "different title", raw, source, defaults, 250, context)) == null);
        try std.testing.expect((try book.select(page_a, &ns, page.namespace_id, page.page_id + 1, page.revision_id, page.title, raw, source, defaults, 250, context)) == null);
    }
}

test "supplied Figure Book balanced cite evidence preserves inert unknown raw and duplicate attribute refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/en-upright/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv"));
    defer ns.deinit();
    const doc = try Testing.document(a, "en-upright");
    for (doc.pages) |page| {
        const html = try string(try field(try json(a, page.response), "parse"), "text");
        const positive = try observedImages(a, &ns, html, page.occurrences);
        try std.testing.expectEqual(@as(usize, 1), positive.len);
        const mixed_case = try std.mem.replaceOwned(u8, a, html, "<cite>", "<CiTe>");
        try std.testing.expectEqual(@as(usize, 1), (try observedImages(a, &ns, mixed_case, page.occurrences)).len);
        for ([_][]const u8{ "<cite/>", "<cite class=\"a\" CLASS=\"b\">", "<cite class=unquoted>", "<unknown-cite>", "<cite><select>" }) |opening| {
            errdefer std.debug.print("EN citation refusal page={s} opening={s}\n", .{ page.title, opening });
            const malformed = try std.mem.replaceOwned(u8, a, html, "<cite>", opening);
            try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, malformed, page.occurrences));
        }
        const unbalanced = try std.mem.replaceOwned(u8, a, html, "</cite>", "</span>");
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, unbalanced, page.occurrences));
        for ([_][]const u8{ "template", "textarea", "select", "svg", "unknown-cite" }) |tag| {
            errdefer std.debug.print("EN citation inactive wrapper page={s} tag={s}\n", .{ page.title, tag });
            const hidden = try std.fmt.allocPrint(a, "<{s}>{s}</{s}>", .{ tag, html, tag });
            try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, hidden, page.occurrences));
        }
        const raw_style = try std.mem.concat(a, u8, &.{ "<style>", html, "</style>" });
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, raw_style, page.occurrences));
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, try std.mem.concat(a, u8, &.{ html, html }), page.occurrences));
    }
}
