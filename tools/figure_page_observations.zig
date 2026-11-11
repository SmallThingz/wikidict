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
    file_sha1: []const u8 = "",
    file_timestamp: []const u8 = "",
    original_width: u32 = 0,
    original_height: u32 = 0,
    missing_content: bool = false,
    width: bool = false,
    height: bool = false,
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
    text_class_scope: bool = false,
    outer_context: ?RawOuterContext = null,
};
const MissingLinkStyles = struct {
    profile: []const u8,
    response: []const u8,
    receipt: []const u8,
    defaults: []const u8,
};
pub const Document = struct {
    schema: []const u8,
    wiki: []const u8,
    date: []const u8,
    namespace_sha256: []const u8,
    defaults_sha256: []const u8,
    pages: []const RawPage,
    missing_link_styles: ?MissingLinkStyles = null,
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
const HeightEvidence = struct { requested_height: u32, original_width: u32, observed_width: u32 };
const Occurrence = struct {
    canonical_file: []const u8,
    original_options: []const u8,
    width: ?u32,
    height: ?HeightEvidence = null,
    anchor: ?Inventory,
    centered_width: ?u32 = null,
    centered_default_size: bool = false,
    missing_content: ?ObservedMissing = null,
};
const Page = struct {
    namespace_id: i32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
    raw_sha256: []const u8,
    source: []const u8,
    occurrences: []const Occurrence,
    text_class_scope: ?profile.BoundedTextClassScope = null,
};
const SelectedOccurrence = struct { source: *const Occurrence, stage_options: []const u8 };
pub const SelectedPage = struct {
    text_class_scope: ?profile.BoundedTextClassScope = null,
    // Exact caller-owned complete original expansion, populated only by select.
    text_class_scope_source: ?[]const u8 = null,
    namespace_catalog: *const namespaces.Registry,
    default_width: u32,
    page_title: []const u8 = "",
    occurrences: []const SelectedOccurrence,
    missing_link_paint: ?encoder.presentation_types.MissingLinkPaint = null,
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
    pub fn height(raw: ?*const anyopaque, a: A, wiki: []const u8, title: []const u8, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, requested_height: u32) A.Error!?u32 {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        if (!equal(wiki, self.namespace_catalog.wiki) or !equal(title, self.page_title)) return null;
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        const proof = occurrence.height orelse return null;
        if (requested_height == 0 or requested_height != proof.requested_height) return null;
        return proof.original_width;
    }
    pub fn missing(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8) A.Error!?compiler.MissingFigureObservation {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        const observed = if (occurrence.missing_content) |*value| value else return null;
        const anchor_inventory = if (occurrence.anchor) |*value| value else return null;
        return .{ .label = observed.label, .href = observed.href, .data_width = observed.data_width,
            .link_paint = if (observed.paint_root_proven) self.missing_link_paint else null,
            .anchor_attributes = .{ .ctx = anchor_inventory, .get = Inventory.presence },
            .element_attributes = .{ .ctx = &observed.element, .get = Inventory.presence } };
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
    missing_link_paint: ?encoder.presentation_types.MissingLinkPaint = null,
    pub fn init(parent: A, bytes: []const u8, ns: *const namespaces.Registry, registry: *const sizing.Registry, defaults_sha256: [32]u8, default_width: u32) !Book {
        if (bytes.len == 0 or bytes.len > max_input or default_width == 0 or !registry.file_authority) return invalid;
        var arena = std.heap.ArenaAllocator.init(parent);
        errdefer arena.deinit();
        const a = arena.allocator();
        const doc = (try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }));
        const paint_contract = equal(doc.schema, "wikidict.figure-page-observations.v3");
        const class_contract = equal(doc.schema, "wikidict.figure-page-observations.v4");
        const missing_contract = class_contract or paint_contract or equal(doc.schema, "wikidict.figure-page-observations.v2");
        if ((!equal(doc.schema, "wikidict.figure-page-observations.v1") and !missing_contract) or !equal(doc.wiki, ns.wiki) or !equal(doc.date, ns.dump_date) or
            !hashEqual(ns.source_sha256, doc.namespace_sha256) or !hashEqual(defaults_sha256, doc.defaults_sha256) or
            doc.pages.len == 0 or doc.pages.len > max_pages) return invalid;
        const link_paint: ?encoder.presentation_types.MissingLinkPaint = if (paint_contract)
            try missingLinkPaint(a, doc.missing_link_styles orelse return invalid, doc.wiki, defaults_sha256)
        else if (class_contract) optional: {
            break :optional if (doc.missing_link_styles) |styles| try missingLinkPaint(a, styles, doc.wiki, defaults_sha256) else null;
        } else legacy: {
            if (doc.missing_link_styles != null) return invalid;
            break :legacy null;
        };
        const pages = try a.alloc(Page, doc.pages.len);
        for (doc.pages, pages, 0..) |page, *out, index| {
            if (page.text_class_scope and !class_contract) return invalid;
            if (page.outer_context != null and (!class_contract or !page.text_class_scope)) return invalid;
            if (page.page_id == 0 or page.revision_id == 0 or page.title.len == 0 or !lowerHex(page.raw_sha256, 64) or
                page.occurrences.len == 0 or page.occurrences.len > max_occurrences) return invalid;
            _ = ns.storedPageSpec(page.title, page.namespace_id) catch return invalid;
            for (pages[0..index]) |old| if (old.page_id == page.page_id or
                (old.namespace_id == page.namespace_id and equal(old.title, page.title))) return invalid;
            const source_and_html = try responseSource(a, ns, page);
            var text_scope: ?profile.BoundedTextClassScope = if (page.text_class_scope) try observedTextClassScope(a, ns, source_and_html.html) else null;
            if (page.outer_context) |outer| {
                if (text_scope) |*scope| {
                    const outer_classes = try observedOuterClasses(a, ns, page, outer, scope.*);
                    scope.complete_ancestor_class_superset = try completeObservedTextClassSuperset(a, scope.*, outer_classes, source_and_html.source);
                } else return invalid;
            }
            const observed_images = try observedImages(a, ns, source_and_html.html, page.occurrences);
            const occurrences = try a.alloc(Occurrence, page.occurrences.len);
            for (page.occurrences, occurrences, 0..) |occurrence, *selected, occurrence_index| {
                if (occurrence.start >= occurrence.end or occurrence.end > source_and_html.source.len) return invalid;
                if (occurrence.missing_content) {
                    if (!missing_contract or occurrence.width or occurrence.height or occurrence.anchor_attributes or occurrence.file_sha1.len != 0 or
                        occurrence.file_timestamp.len != 0 or occurrence.original_width != 0 or occurrence.original_height != 0 or
                        !try sizing.Registry.isMissingFile(registry, a, occurrence.canonical_file)) return invalid;
                } else if ((!occurrence.width and !occurrence.height and !occurrence.anchor_attributes) or
                    (occurrence.height and (occurrence.width or occurrence.anchor_attributes)) or !lowerHex(occurrence.file_sha1, 40) or
                    occurrence.file_timestamp.len == 0 or occurrence.original_width == 0 or occurrence.original_height == 0) return invalid;
                for (page.occurrences[0..occurrence_index]) |old| if (equal(old.canonical_file, occurrence.canonical_file) or
                    (old.start < occurrence.end and occurrence.start < old.end)) return invalid;
                const canonical = try canonicalFile(a, ns, occurrence.canonical_file);
                if (!equal(canonical, occurrence.canonical_file)) return invalid;
                var fact_found = false;
                for (registry.records, 0..) |fact, fact_index| if (equal(fact.canonical_file, canonical)) {
                    if (!equal(fact.file_sha1, occurrence.file_sha1) or !equal(fact.file_timestamp, occurrence.file_timestamp) or
                        fact.original_width != occurrence.original_width or fact.original_height != occurrence.original_height) return invalid;
                    if (occurrence.height and (fact_index >= registry.height_bound_records.len or
                        registry.height_bound_records[fact_index] != .svg_redundant_height or
                        fact.format != .thumbnail or fact.sizing != .requested_fit)) return invalid;
                    fact_found = true;
                    break;
                };
                if (fact_found == occurrence.missing_content) return invalid;
                const options = try originalOptions(a, ns, source_and_html.source, occurrence);
                const image = observed_images[occurrence_index];
                selected.* = .{ .canonical_file = canonical, .original_options = options,
                    .width = if (occurrence.width) image.width else null,
                    .height = if (occurrence.height) .{ .requested_height = image.height,
                        .original_width = occurrence.original_width, .observed_width = image.width } else null,
                    .anchor = if (occurrence.anchor_attributes or occurrence.missing_content) image.anchor else null,
                    .centered_width = if (image.centered) image.width else null,
                    .centered_default_size = image.centered_default_size,
                    .missing_content = image.missing_content };
            }
            out.* = .{ .namespace_id = page.namespace_id, .page_id = page.page_id, .revision_id = page.revision_id, .title = page.title,
                .raw_sha256 = page.raw_sha256, .source = source_and_html.source, .occurrences = occurrences, .text_class_scope = text_scope };
        }
        std.mem.sort(Page, pages, {}, struct {
            fn less(_: void, left: Page, right: Page) bool { return left.page_id < right.page_id; }
        }.less);
        return .{ .arena = arena, .namespace_sha256 = ns.source_sha256, .defaults_sha256 = defaults_sha256, .default_width = default_width, .pages = pages, .missing_link_paint = link_paint };
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
                if (occurrence.height) |proof| {
                    if (!heightThumbnailOptions(context.image_options.?, occurrence.original_options, proof.requested_height) or
                        !heightThumbnailOptions(context.image_options.?, slot.stage_options, proof.requested_height)) return null;
                }
                if (occurrence.centered_default_size) {
                    const width = occurrence.width orelse return null;
                    if (occurrence.centered_width != width or
                        !centeredThumbnailDimensionOptions(context.image_options.?, occurrence.original_options, width, true) or
                        !centeredThumbnailDimensionOptions(context.image_options.?, slot.stage_options, width, true)) return null;
                } else if (occurrence.centered_width) |observed_width|
                    if (!centeredThumbnailOptions(context.image_options.?, slot.stage_options, observed_width)) return null;
                if (occurrence.missing_content) |missing| if (
                    !missingThumbnailOptionsForObservation(context.image_options.?, occurrence.original_options, missing) or
                    !missingThumbnailOptionsForObservation(context.image_options.?, slot.stage_options, missing)) return null;
            }
            const result = try a.create(SelectedPage);
            result.* = .{ .namespace_catalog = ns, .default_width = default_width, .page_title = title, .occurrences = selected, .missing_link_paint = self.missing_link_paint,
                .text_class_scope = page.text_class_scope, .text_class_scope_source = if (page.text_class_scope != null) expanded else null };
            return result;
        }
        return null;
    }
};

// Exact right-thumbnail height-only options with one retained caption. The
// ordinary delimiter scanner keeps nested links in that caption intact.
fn heightThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8, height: u32) bool {
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
    if (count != 4 or height == 0 or parts[3].len == 0 or registry.match(parts[3], .image) != null) return false;
    const format = registry.match(parts[0], .image) orelse return false;
    const horizontal = registry.match(parts[1], .image) orelse return false;
    const dimension = registry.match(parts[2], .image) orelse return false;
    if (!equal(format.id, "img_thumbnail") or format.value != null or
        !equal(horizontal.id, "img_right") or horizontal.value != null or !equal(dimension.id, "img_width")) return false;
    const value = dimension.value orelse return false;
    if (value.len < 2 or value.len > 11 or value[0] != 'x') return false;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return (std.fmt.parseInt(u32, value[1..], 10) catch return false) == height;
}

// ImageHandler's positive half-up fit uses logical API axes. The observation
// supplies actual height/width; this validates a bounded downfit, not SVGMaxSize.
fn observedHeightFit(width: u32, height: u32, original_width: u32, original_height: u32) bool {
    if (width == 0 or height == 0 or original_width == 0 or original_height == 0 or height > original_height) return false;
    const product = @as(u64, original_width) * height;
    const expected = product / original_height + @intFromBool(product % original_height >= (@as(u64, original_height) + 1) / 2);
    return width <= original_width and expected == width;
}

// A necessary proof for the additionally observed centered, explicit-width
// shape. Use the selected ordinary image-option registry and delimiter rules;
// the renderer still owns all placement, caption, style and sizing semantics.
fn centeredThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8, observed_width: u32) bool {
    return centeredThumbnailDimensionOptions(registry, options, observed_width, false);
}

// Bare upright uses only a selected observed width. No default factor or width
// is calculated from the retained CSS property or the thumbnail URL.
fn centeredThumbnailDimensionOptions(registry: *const namespaces.image_options.Registry, options: []const u8, observed_width: u32, bare_upright: bool) bool {
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
        registry.match(parts[3], .image) != null) return false;
    if (bare_upright) return equal(dimension.id, "img_upright") and dimension.value == null and parts[3].len != 0;
    if (!equal(dimension.id, "img_width")) return false;
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
// This capability is scoped to one reviewed served module and the selected
// normal default role. It does not claim historical core equality or an absent
// gadget/author override; the compiler keeps its own indexed-style guards.
fn missingLinkPaint(a: A, styles: MissingLinkStyles, wiki: []const u8, defaults_sha256: [32]u8) !encoder.presentation_types.MissingLinkPaint {
    const language: []const u8 = if (equal(wiki, "enwiktionary")) "en" else if (equal(wiki, "viwiktionary")) "vi" else return invalid;
    const expected_url = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/load.php?lang={s}&modules=skins.vector.styles&only=styles&skin=vector-2022", .{ language, language });
    const expected_source_path = try std.fmt.allocPrint(a, "served:skins.vector.styles:{s}:vector-2022", .{language});
    const response_sha256 = "ecbc7435843a302ddba3652426b60f876a56950eeebdd1b9df0332aefeabd5fb";
    if (!equal(styles.profile, "vector_new_link_v1") or
        styles.response.len != 90597 or !digestMatches(styles.response, response_sha256)) return invalid;
    var actual_defaults: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(styles.defaults, &actual_defaults, .{});
    if (!std.mem.eql(u8, &actual_defaults, &defaults_sha256)) return invalid;
    const defaults = try json(a, styles.defaults);
    const options = try field(try field(defaults, "query"), "defaultoptions");
    if (!equal(try string(defaults, "wiki"), wiki) or
        !equal(try string(options, "skin"), "vector-2022") or
        !equal(try string(options, "language"), language) or
        !equal(try string(options, "vector-theme"), "day")) return invalid;
    const receipt = try json(a, styles.receipt);
    if (receipt != .object or receipt.object.count() != 2 or try field(receipt, "core") != .null) return invalid;
    const sources = try field(receipt, "sources");
    if (sources != .array or sources.array.items.len != 1) return invalid;
    const source = sources.array.items[0];
    try descriptor(styles.response, source);
    if (try number(source, "status") != 200 or
        !equal(try string(source, "url"), expected_url) or !equal(try string(source, "final_url"), expected_url) or
        !equal(try string(source, "source_path"), expected_source_path)) return invalid;
    const content_type = try string(try field(source, "headers"), "content-type");
    const mime_end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    if (!equal(std.mem.trim(u8, content_type[0..mime_end], " \t"), "text/css")) return invalid;
    return .vector_new_link_v1;
}

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
    if (page.form_body.len == 0 or page.form_body.len > 128 * 1024) return invalid;
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
    if (parameters != .object or parameters.object.count() != (if (page.text_class_scope) @as(usize, 11) else 10)) return invalid;
    for ([_][2][]const u8{ .{ "action", "parse" }, .{ "format", "json" }, .{ "formatversion", "2" }, .{ "maxlag", "5" },
        .{ "contentmodel", "wikitext" }, .{ "parser", "legacy" }, .{ "usearticle", "1" } }) |pair|
        if (!equal(try string(parameters, pair[0]), pair[1])) return invalid;
    const expected_prop = if (page.text_class_scope) "text|wikitext|revid|displaytitle|headhtml|modules|jsconfigvars" else "text|wikitext|revid|displaytitle";
    if (!equal(try string(parameters, "prop"), expected_prop)) return invalid;
    if (page.text_class_scope and !equal(try string(parameters, "useskin"), "vector-2022")) return invalid;
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
    if (found.count() != (if (page.text_class_scope) @as(usize, 12) else 11)) return invalid;
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
// A complete conservative class superset for one returned parser root only.
// This does not establish skin ancestry, element positions or computed styles.
fn observedTextClassScope(a: A, ns: *const namespaces.Registry, html: []const u8) !profile.BoundedTextClassScope {
    if (html.len == 0 or html.len > max_response or !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return invalid;
    var stack: [128]syntax.Tag = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    var root_seen = false;
    var root_classes: []const u8 = "";
    var elements: usize = 0;
    var class_tokens: usize = 0;
    var class_bytes: usize = 0;
    var classes: std.StringHashMapUnmanaged(void) = .empty;
    defer classes.deinit(a);
    var union_text: std.ArrayList(u8) = .empty;
    errdefer union_text.deinit(a);
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            if (std.mem.startsWith(u8, html[at + 4 ..], ">") or std.mem.startsWith(u8, html[at + 4 ..], "->")) return invalid;
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            if (std.mem.indexOf(u8, html[at + 4 .. end], "--") != null or
                (end > at + 4 and html[end - 1] == '-')) return invalid;
            at = end + 3;
            continue;
        }
        if (html[at] != '<') {
            if (depth == 0 and !htmlClassSpace(html[at])) return invalid;
            if (depth > 0 and stack[depth - 1].is("audio") and !htmlClassSpace(html[at])) return invalid;
            at += 1;
            continue;
        }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at or tag.end > html.len) return invalid;
        const inv = try inventory(a, tag);
        // Active handlers can mutate classes independently of this observed tree.
        for (inv.attributes) |attr| if (attr.name.len >= 2 and std.ascii.eqlIgnoreCase(attr.name[0..2], "on")) return invalid;
        if (tag.closing) {
            if (inv.attributes.len != 0 or tag.self_closing or html[tag.end - 2] == '/' or depth == 0 or
                !std.ascii.eqlIgnoreCase(stack[depth - 1].name, tag.name)) return invalid;
            depth -= 1;
            at = tag.end;
            continue;
        }
        elements += 1;
        if (elements > 16384) return invalid;
        var ordinary = false;
        for ([_][]const u8{ "div", "span", "a", "figure", "figcaption", "img", "meta", "link", "style",
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
            "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "pre", "font", "audio", "source" }) |name|
            if (tag.is(name)) { ordinary = true; break; };
        const is_void = tag.is("img") or tag.is("meta") or tag.is("link") or tag.is("col") or tag.is("br") or tag.is("hr") or tag.is("wbr") or tag.is("source");
        if (!ordinary or ((tag.self_closing or html[tag.end - 2] == '/') and !is_void)) return invalid;
        const audio_child = depth > 0 and stack[depth - 1].is("audio");
        if ((audio_child and !tag.is("source")) or (tag.is("source") and !audio_child)) return invalid;
        if (depth == 0) {
            if (root_seen or !tag.is("div") or inv.attributes.len != 3 or
                !equal(inv.get("class") orelse return invalid, "mw-content-ltr mw-parser-output") or
                !equal(inv.get("lang") orelse return invalid, ns.content_language) or
                !equal(inv.get("dir") orelse return invalid, "ltr")) return invalid;
            root_seen = true;
            root_classes = inv.get("class").?;
        }
        if (inv.get("class")) |value| {
            class_bytes += value.len;
            if (class_bytes > 65536) return invalid;
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
            while (tokens.next()) |token| {
                class_tokens += 1;
                if (class_tokens > 8192 or token.len > 1024) return invalid;
                for (token) |byte| if (byte < 0x20 or byte == 0x7f) return invalid;
                if (!(try classes.getOrPut(a, token)).found_existing) {
                    if (union_text.items.len != 0) try union_text.append(a, ' ');
                    try union_text.appendSlice(a, token);
                }
            }
        }
        if (tag.is("style")) {
            // First HTML STYLE end tag wins, regardless of case. Do not mistake
            // literal CSS '<span class=...>' text for a rendered descendant.
            var cursor = tag.end;
            var close_end: ?usize = null;
            while (cursor < html.len) : (cursor += 1) {
                if (html.len - cursor < 8 or !std.ascii.eqlIgnoreCase(html[cursor .. cursor + 7], "</style")) continue;
                const next = html[cursor + 7];
                if (next != '>' and next != '/' and !htmlClassSpace(next)) continue;
                const close = syntax.tagAt(html, cursor) orelse return invalid;
                if (!close.closing or !close.is("style") or close.self_closing or html[close.end - 2] == '/' or
                    (try inventory(a, close)).attributes.len != 0) return invalid;
                close_end = close.end;
                break;
            }
            at = close_end orelse return invalid;
            continue;
        }
        if (!is_void) {
            if (depth == stack.len) return invalid;
            stack[depth] = tag;
            depth += 1;
        }
        at = tag.end;
    }
    if (!root_seen or depth != 0) return invalid;
    return .{ .root_tag = "div", .root_classes = root_classes, .subtree_classes = try union_text.toOwnedSlice(a) };
}
fn htmlClassSpace(byte: u8) bool { return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0c; }

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
const ObservedMissing = struct {
    label: []const u8, href: []const u8, data_width: u32, element: Inventory,
    paint_root_proven: bool = false,
    default_size: bool = true,
    right: bool = false,
};
const ObservedImage = struct { width: u32, height: u32 = 0, anchor: Inventory, centered: bool = false, centered_default_size: bool = false, missing_content: ?ObservedMissing = null };
// Returned markup supplies occurrence facts, not computed CSS or image pixels.
fn missingAnchorFile(a: A, ns: *const namespaces.Registry, anchor: Inventory) !?[]const u8 {
    if (!equal(anchor.get("class") orelse return null, "new")) return null;
    const title = anchor.get("title") orelse return null;
    if (ns.ofTitle(title).id != 6) return null;
    return canonicalFile(a, ns, title) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}
fn observedMissingContent(a: A, html: []const u8, tag_at: usize, tag: syntax.Tag, element: Inventory, anchor_tag: syntax.Tag, anchor: Inventory, figure: Inventory) !ObservedMissing {
    const figure_class = figure.get("class") orelse "";
    const default_size = equal(figure_class, "mw-default-size") or equal(figure_class, "mw-default-size mw-halign-right");
    if ((!default_size and !equal(figure_class, "") and !equal(figure_class, "mw-halign-right")) or
        !equal(figure.get("typeof") orelse return invalid, "mw:Error mw:File/Thumb") or
        !equal(element.get("class") orelse return invalid, "mw-file-element mw-broken-media")) return invalid;
    for (figure.attributes) |attr| if (!equal(attr.name, "class") and !equal(attr.name, "typeof")) return invalid;
    for (anchor.attributes) |attr| if (!equal(attr.name, "href") and !equal(attr.name, "class") and !equal(attr.name, "title")) return invalid;
    for (element.attributes) |attr| if (!equal(attr.name, "class") and !equal(attr.name, "data-width")) return invalid;
    if (std.mem.trim(u8, html[anchor_tag.end..tag_at], " \t\r\n").len != 0) return invalid;
    const text_end = std.mem.indexOfScalarPos(u8, html, tag.end, '<') orelse return invalid;
    const close = syntax.tagAt(html, text_end) orelse return invalid;
    if (!close.closing or !close.is("span") or std.mem.trim(u8, close.attrs, " \t\r\n").len != 0) return invalid;
    var after = close.end;
    while (after < html.len and std.ascii.isWhitespace(html[after])) : (after += 1) {}
    const anchor_close = syntax.tagAt(html, after) orelse return invalid;
    if (!anchor_close.closing or !anchor_close.is("a") or std.mem.trim(u8, anchor_close.attrs, " \t\r\n").len != 0) return invalid;
    const label = try decodedAttribute(a, html[tag.end..text_end]);
    if (label.len == 0 or !equal(label, anchor.get("title") orelse return invalid)) return invalid;
    for (label) |byte| if (byte < 0x20 or byte == 0x7f) return invalid;
    const href = anchor.get("href") orelse return invalid;
    const host_at: usize = if (std.mem.startsWith(u8, href, "https://")) 8 else if (std.mem.startsWith(u8, href, "//")) 2 else return invalid;
    const host_end = std.mem.indexOfScalarPos(u8, href, host_at, '/') orelse return invalid;
    if (host_end == host_at or std.mem.indexOfAny(u8, href[host_at..host_end], "@:#?%\\") != null) return invalid;
    for (href) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return invalid;
    return .{ .label = label, .href = href, .data_width = try positiveAttribute(element, "data-width"), .element = element,
        .default_size = default_size, .right = equal(figure_class, "mw-halign-right") or equal(figure_class, "mw-default-size mw-halign-right") };
}
// Explicit Missing width is a text content width installed by the selected
// media script, not a natural image size. Bind its source options and classes.
fn missingThumbnailOptionsForObservation(registry: *const namespaces.image_options.Registry, options: []const u8, observed: ObservedMissing) bool {
    if (observed.default_size) return missingThumbnailOptions(registry, options);
    if (observed.data_width == 0 or observed.data_width > 16_777_216) return false;
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
    if (count < 3 or parts[count - 1].len == 0 or registry.match(parts[count - 1], .image) != null) return false;
    const format = registry.match(parts[0], .image) orelse return false;
    if (!equal(format.id, "img_thumbnail") or format.value != null) return false;
    var width_seen = false;
    var right_seen = false;
    for (parts[1 .. count - 1]) |part| {
        const option = registry.match(part, .image) orelse return false;
        if (equal(option.id, "img_right")) {
            if (right_seen or option.value != null) return false;
            right_seen = true;
        } else if (equal(option.id, "img_width")) {
            if (width_seen) return false;
            const width = option.value orelse return false;
            if (width.len == 0 or width.len > 10) return false;
            for (width) |byte| if (!std.ascii.isDigit(byte)) return false;
            if ((std.fmt.parseInt(u32, width, 10) catch return false) != observed.data_width) return false;
            width_seen = true;
        } else return false;
    }
    return width_seen and right_seen == observed.right;
}

fn missingThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8) bool {
    const separator = syntax.delimiter(options, "|", 0) orelse return false;
    const first = std.mem.trim(u8, options[0..separator], " \t\r\n");
    const option = registry.match(first, .image) orelse return false;
    if (!equal(option.id, "img_thumbnail") or option.value != null) return false;
    var caption = std.mem.trim(u8, options[separator + 1 ..], " \t\r\n");
    if (syntax.delimiter(caption, "|", 0)) |right_end| {
        const right = registry.match(std.mem.trim(u8, caption[0..right_end], " \t\r\n"), .image) orelse return false;
        if (!equal(right.id, "img_right") or right.value != null) return false;
        caption = std.mem.trim(u8, caption[right_end + 1 ..], " \t\r\n");
    }
    return caption.len != 0 and syntax.delimiter(caption, "|", 0) == null and registry.match(caption, .image) == null;
}

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
    const Open = struct { tag: syntax.Tag, attributes: Inventory, ruby_phase: u3 = 0, ruby_base_text: bool = false };
    var stack: [128]Open = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    var embedded_styles = false;
    const anchors = try a.alloc(usize, occurrences.len);
    const images = try a.alloc(usize, occurrences.len);
    const selected = try a.alloc(ObservedImage, occurrences.len);
    @memset(anchors, 0);
    @memset(images, 0);
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            if (depth > 0 and stack[depth - 1].tag.is("audio")) return invalid;
            for (stack[0..depth]) |open| if (open.tag.is("ruby")) return invalid;
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (html[at] != '<') {
            if (depth > 0 and stack[depth - 1].tag.is("audio") and !std.ascii.isWhitespace(html[at])) return invalid;
            if (depth > 0 and stack[depth - 1].tag.is("ruby") and !std.ascii.isWhitespace(html[at])) {
                if (stack[depth - 1].ruby_phase != 0) return invalid;
                stack[depth - 1].ruby_base_text = true;
            }
            at += 1; continue;
        }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at or tag.end > html.len) return invalid;
        const inv = try inventory(a, tag);
        if (tag.closing) {
            if (inv.attributes.len != 0 or depth == 0 or !std.ascii.eqlIgnoreCase(stack[depth - 1].tag.name, tag.name)) return invalid;
            if (tag.is("ruby") and (stack[depth - 1].ruby_phase != 3 or !stack[depth - 1].ruby_base_text)) return invalid;
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
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "pre", "font", "audio", "source", "mark", "ruby", "rp", "rt" }) |name|
            if (tag.is(name)) { ordinary_tag = true; break; };
        if (!ordinary_tag or ((tag.self_closing or (tag.end >= 2 and html[tag.end - 2] == '/')) and !is_void)) return invalid;
        // Admit only explicit simple ruby structure. Every optional-end-tag
        // boundary is supplied; annotation trees cannot manufacture an image
        // occurrence or rely on browser repair. Their ordinary A elements still
        // participate in the duplicate file-anchor census below.
        var ruby_owner: ?usize = null;
        for (stack[0..depth], 0..) |open, index| if (open.tag.is("ruby")) { ruby_owner = index; };
        if (ruby_owner) |owner| {
            const parent = stack[depth - 1].tag;
            if (parent.is("ruby")) {
                if (inv.attributes.len != 0 or !stack[owner].ruby_base_text) return invalid;
                const phase = stack[owner].ruby_phase;
                if (tag.is("rp") and (phase == 0 or phase == 2)) {
                    stack[owner].ruby_phase = phase + 1;
                } else if (tag.is("rt") and phase == 1) {
                    stack[owner].ruby_phase = 2;
                } else return invalid;
            } else if (parent.is("rt") and tag.is("a")) {
                // Starting a nested A would implicitly close an outer anchor.
                for (stack[0..depth]) |open| if (open.tag.is("a")) return invalid;
            } else return invalid;
        } else if (tag.is("rp") or tag.is("rt")) return invalid;
        if (tag.is("ruby")) {
            if (inv.attributes.len != 0) return invalid;
            var ordinary_parent = depth == 0;
            if (depth > 0) for ([_][]const u8{ "div", "span", "a", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite", "li", "dt", "dd", "td", "th", "figcaption", "mark", "u", "s", "code", "pre", "font", "h1", "h2", "h3", "h4", "h5", "h6" }) |name| {
                if (stack[depth - 1].tag.is(name)) { ordinary_parent = true; break; }
            };
            if (!ordinary_parent) return invalid;
        }
        // STYLE is an HTML raw-text element. Its complete bytes stay in the
        // retained response, but cannot create an observed image or anchor.
        if (tag.is("style")) {
            embedded_styles = true;
            const close = std.mem.indexOfPos(u8, html, tag.end, "</style>") orelse return invalid;
            at = close + "</style>".len;
            continue;
        }
        if (tag.is("link")) {
            var rels = std.mem.tokenizeAny(u8, inv.get("rel") orelse "", " \t\r\n\x0c");
            while (rels.next()) |rel| if (std.ascii.eqlIgnoreCase(rel, "stylesheet")) { embedded_styles = true; };
        }
        if (tag.is("a")) {
            if (inv.get("href")) |href| if (try fileHref(a, ns, href)) |file| {
                for (occurrences, 0..) |occurrence, index| if (equal(file, occurrence.canonical_file)) { anchors[index] += 1; };
            };
            if (try missingAnchorFile(a, ns, inv)) |file| {
                for (occurrences, 0..) |occurrence, index| if (occurrence.missing_content and equal(file, occurrence.canonical_file)) { anchors[index] += 1; };
            }
        }
        if (tag.is("span") and depth >= 2 and stack[depth - 1].tag.is("a") and stack[depth - 2].tag.is("figure")) {
            const anchor = stack[depth - 1].attributes;
            if (try missingAnchorFile(a, ns, anchor)) |file| {
                for (occurrences, 0..) |occurrence, index| {
                    if (!occurrence.missing_content or !equal(file, occurrence.canonical_file)) continue;
                    var observed = try observedMissingContent(a, html, at, tag, inv, stack[depth - 1].tag, anchor, stack[depth - 2].attributes);
                    // Only the complete observed ParserOutput root directly
                    // owns this Figure. A wrapper can reset inherited theme
                    // variables (.notheme/.skin-invert), so it cannot borrow
                    // this capability merely because the label matches.
                    if (depth == 3 and stack[0].tag.is("div")) {
                        const root = stack[0].attributes;
                        observed.paint_root_proven = root.attributes.len == 3 and
                            equal(root.get("class") orelse "", "mw-content-ltr mw-parser-output") and
                            equal(root.get("lang") orelse "", ns.content_language) and equal(root.get("dir") orelse "", "ltr");
                    }
                    images[index] += 1;
                    selected[index] = .{ .width = 0, .anchor = anchor, .missing_content = observed };
                }
            }
        }
        if (tag.is("img") and depth >= 2 and stack[depth - 1].tag.is("a") and stack[depth - 2].tag.is("figure")) {
            const anchor = stack[depth - 1].attributes;
            if (anchor.get("href")) |href| if (try fileHref(a, ns, href)) |file| for (occurrences, 0..) |occurrence, index| {
                if (!equal(file, occurrence.canonical_file)) continue;
                if (occurrence.missing_content) return invalid;
                const figure_classes = stack[depth - 2].attributes.get("class") orelse return invalid;
                const centered_default_size = equal(figure_classes, "mw-default-size mw-halign-center");
                const explicit_centered = equal(figure_classes, "mw-halign-center");
                const centered = explicit_centered or centered_default_size;
                const height_right = occurrence.height and equal(figure_classes, "mw-halign-right");
                if (!equal(stack[depth - 2].attributes.get("typeof") orelse return invalid, "mw:File/Thumb") or
                    (!equal(figure_classes, "mw-default-size") and
                        !(explicit_centered and occurrence.anchor_attributes and !occurrence.width) and
                        !(centered_default_size and occurrence.width) and !height_right) or
                    !equal(anchor.get("class") orelse return invalid, "mw-file-description") or
                    try positiveAttribute(inv, "data-file-width") != occurrence.original_width or try positiveAttribute(inv, "data-file-height") != occurrence.original_height) return invalid;
                if (occurrence.height and (!height_right or !equal(inv.get("class") orelse "", "mw-file-element") or inv.get("style") != null)) return invalid;
                for (anchor.attributes) |attr| if (!equal(attr.name, "href") and !equal(attr.name, "class") and !equal(attr.name, "rel") and !equal(attr.name, "title")) return invalid;
                for (stack[depth - 2].attributes.attributes) |attr| if (!equal(attr.name, "class") and !equal(attr.name, "typeof")) return invalid;
                try imageSource(a, ns, inv.get("src") orelse return invalid, occurrence.canonical_file);
                const image_classes = inv.get("class") orelse return invalid;
                if (!equal(image_classes, "mw-file-element") and !equal(image_classes, "mw-file-element mw-file-upright")) return invalid;
                if (centered_default_size and (!equal(image_classes, "mw-file-element mw-file-upright") or inv.get("style") == null)) return invalid;
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
                const height = try positiveAttribute(inv, "height");
                if (occurrence.height and !observedHeightFit(width, height, occurrence.original_width, occurrence.original_height)) return invalid;
                selected[index] = .{ .width = width, .height = height, .anchor = anchor, .centered = centered, .centered_default_size = centered_default_size };
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
    if (embedded_styles) for (selected) |*image| {
        if (image.missing_content) |*missing| missing.paint_root_proven = false;
    };
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


test "supplied Figure Book missing content records real label action and attributes without image dimensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const file = try canonicalFile(a, &ns, "File:Absent.png");
    const html = try std.fmt.allocPrint(a, "<figure class=\"mw-default-size\" typeof=\"mw:Error mw:File/Thumb\"><a href=\"//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png&amp;uselang=en\" class=\"new\" title=\"{s}\"><span class=\"mw-file-element mw-broken-media\" data-width=\"180\">{s}</span></a><figcaption><i><b>Caption</b></i></figcaption></figure>", .{ file, file });
    const occurrence: RawOccurrence = .{ .start = 0, .end = 1, .canonical_file = file, .missing_content = true };
    const observed = try observedImages(a, &ns, html, &.{occurrence});
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expectEqual(@as(u32, 0), observed[0].width);
    const missing = observed[0].missing_content orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(file, missing.label);
    try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png&uselang=en", missing.href);
    try std.testing.expectEqual(@as(u32, 180), missing.data_width);
    try std.testing.expectEqualStrings("mw-file-element mw-broken-media", missing.element.get("class").?);
    try std.testing.expect(missing.element.get("src") == null and missing.element.get("width") == null and missing.element.get("height") == null);
    try std.testing.expectEqualStrings("new", observed[0].anchor.get("class").?);
    // The same observed bytes do not create an image or an unselected missing fact.
    var image_occurrence = occurrence; image_occurrence.missing_content = false;
    try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, html, &.{image_occurrence}));
    try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, try std.mem.concat(a, u8, &.{ html, html }), &.{occurrence}));
    for ([_][2][]const u8{
        .{ "mw:Error mw:File/Thumb", "mw:File/Thumb" },
        .{ "mw-file-element mw-broken-media", "mw-file-element" },
        .{ "data-width=\"180\"", "data-width=\"0\"" },
        .{ "data-width=\"180\"", "data-width=\"180\" style=\"width:180px\"" },
        .{ "</span></a>", "</span><b>extra</b></a>" },
        .{ "</span></a>", "<i>extra</i></span></a>" },
        .{ "class=\"new\"", "class=\"mw-file-description\"" },
        .{ "//commons.wikimedia.org/wiki/", "javascript:evil/" },
    }) |replacement| {
        const changed = try std.mem.replaceOwned(u8, a, html, replacement[0], replacement[1]);
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, changed, &.{occurrence}));
    }
    for ([_][]const u8{ "template", "svg", "select", "textarea" }) |tag| {
        const wrapped = try std.fmt.allocPrint(a, "<{s}>{s}</{s}>", .{ tag, html, tag });
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, wrapped, &.{occurrence}));
    }
}

test "missing link paint authenticates served module and refuses reset ancestors or embedded overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(Document, a,
        @embedFile("testdata/en-missing-tayassu/figure-page-observations.json"), .{ .allocate = .alloc_always });
    const styles = doc.missing_link_styles orelse return error.TestUnexpectedResult;
    var defaults_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(styles.defaults, &defaults_hash, .{});
    try std.testing.expectEqual(encoder.presentation_types.MissingLinkPaint.vector_new_link_v1,
        try missingLinkPaint(a, styles, "enwiktionary", defaults_hash));
    var changed = styles;
    changed.response = try std.mem.replaceOwned(u8, a, styles.response, "#bf3c2c", "#000000");
    try std.testing.expectError(invalid, missingLinkPaint(a, changed, "enwiktionary", defaults_hash));
    changed = styles;
    changed.receipt = try std.mem.replaceOwned(u8, a, styles.receipt, "\"status\": 200", "\"status\": 403");
    try std.testing.expectError(invalid, missingLinkPaint(a, changed, "enwiktionary", defaults_hash));
    changed = styles;
    changed.defaults = try std.mem.replaceOwned(u8, a, styles.defaults, "vector-2022", "monobook");
    std.crypto.hash.sha2.Sha256.hash(changed.defaults, &defaults_hash, .{});
    try std.testing.expectError(invalid, missingLinkPaint(a, changed, "enwiktionary", defaults_hash));

    var ns = try namespaces.Registry.init(a, @embedFile("testdata/en-empty-element271/namespace-registry.tsv")); defer ns.deinit();
    const page = doc.pages[0];
    const html = try string(try field(try json(a, page.response), "parse"), "text");
    const observed = try observedImages(a, &ns, html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expect(observed[0].missing_content.?.paint_root_proven);
    const label = observed[0].missing_content.?.label;
    const href = observed[0].missing_content.?.href;
    for ([_][]const u8{
        "<div class='notheme'>", "<div class='skin-invert'>", "<div style='--color-destructive:#ff0000'>",
    }) |opening| {
        const wrapped = try std.fmt.allocPrint(a, "{s}{s}</div>", .{ opening, html });
        const withheld = try observedImages(a, &ns, wrapped, page.occurrences);
        try std.testing.expect(!withheld[0].missing_content.?.paint_root_proven);
        try std.testing.expectEqualStrings(label, withheld[0].missing_content.?.label);
        try std.testing.expectEqualStrings(href, withheld[0].missing_content.?.href);
    }
    for ([_][]const u8{
        "<style>.new{color:#ff0000}</style>", "<link rel='stylesheet' href='/author.css'>",
    }) |override| {
        const with_style = try std.mem.concat(a, u8, &.{ html, override });
        const withheld = try observedImages(a, &ns, with_style, page.occurrences);
        try std.testing.expect(!withheld[0].missing_content.?.paint_root_proven);
        try std.testing.expectEqualStrings(label, withheld[0].missing_content.?.label);
        try std.testing.expectEqualStrings(href, withheld[0].missing_content.?.href);
    }
}


test "VI missing observations bind their own served module root and exact right option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(Document, a,
        @embedFile("testdata/vi-missing-next268/figure-page-observations.json"), .{ .allocate = .alloc_always });
    const styles = doc.missing_link_styles orelse return error.TestUnexpectedResult;
    const defaults_hash = Testing.hash(styles.defaults);
    try std.testing.expectEqual(encoder.presentation_types.MissingLinkPaint.vector_new_link_v1,
        try missingLinkPaint(a, styles, "viwiktionary", defaults_hash));
    try std.testing.expectError(invalid, missingLinkPaint(a, styles, "enwiktionary", defaults_hash));
    try std.testing.expectError(invalid, missingLinkPaint(a, styles, "srwiktionary", defaults_hash));
    var wrong = styles;
    wrong.receipt = try std.mem.replaceOwned(u8, a, styles.receipt, "vi.wiktionary.org", "en.wiktionary.org");
    try std.testing.expectError(invalid, missingLinkPaint(a, wrong, "viwiktionary", defaults_hash));
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    var missing_pages: usize = 0; var accepted_roots: usize = 0; var refused_styles: usize = 0; var right_pages: usize = 0;
    for (doc.pages) |page| {
        if (page.occurrences.len != 1 or !page.occurrences[0].missing_content) continue;
        missing_pages += 1;
        const source = try responseSource(a, &ns, page);
        const html = try string(try field(try json(a, page.response), "parse"), "text");
        const observed = try observedImages(a, &ns, html, page.occurrences);
        try std.testing.expectEqual(@as(usize, 1), observed.len);
        const missing = observed[0].missing_content orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, missing.label);
        try std.testing.expect(std.mem.indexOf(u8, missing.href, "uselang=vi") != null);
        try std.testing.expectEqual(@as(u32, 180), missing.data_width);
        const original = try originalOptions(a, &ns, source.source, page.occurrences[0]);
        try std.testing.expect(missingThumbnailOptions(&options, original));
        const with_style = equal(page.title, "g") or equal(page.title, "univers");
        try std.testing.expectEqual(!with_style, missing.paint_root_proven);
        if (with_style) refused_styles += 1 else accepted_roots += 1;
        if (equal(page.title, "Thừa Thiên Huế")) {
            right_pages += 1;
            try std.testing.expect(std.mem.indexOf(u8, original, "|phải|") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 8), missing_pages);
    try std.testing.expectEqual(@as(usize, 6), accepted_roots);
    try std.testing.expectEqual(@as(usize, 2), refused_styles);
    try std.testing.expectEqual(@as(usize, 1), right_pages);
    for ([_][]const u8{ "nhỏ|trái|Caption", "nhỏ|giữa|Caption", "nhỏ|250px|Caption", "nhỏ|phải|trái|Caption", "nhỏ|phải|" }) |denied|
        try std.testing.expect(!missingThumbnailOptions(&options, denied));
}

// Controlled request padding changes only trailing source whitespace. It tests
// intake bounds, not a new observation or a grant for the actual Mai figures.
const FormIntakeTest = struct {
    fn descriptorValue(a: A, bytes: []const u8) !Value {
        const digest = std.fmt.bytesToHex(Testing.hash(bytes), .lower);
        return json(a, try std.json.Stringify.valueAlloc(a, .{ .bytes = bytes.len, .sha256 = &digest }, .{}));
    }
    fn bindReceipt(a: A, page: *RawPage) !void {
        var receipt = try json(a, page.receipt);
        try receipt.object.put(a, "request", try descriptorValue(a, page.request));
        try receipt.object.put(a, "response", try descriptorValue(a, page.response));
        page.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
    }
    fn bindForm(a: A, page: *RawPage) !void {
        var request = try json(a, page.request);
        try request.object.put(a, "form", try descriptorValue(a, page.form_body));
        page.request = try std.json.Stringify.valueAlloc(a, request, .{});
        try bindReceipt(a, page);
    }
    fn padded(a: A, form_size: usize) !RawPage {
        var page = (try Testing.document(a, "it")).pages[0];
        try std.testing.expect(form_size >= page.form_body.len);
        const text_at = std.mem.indexOf(u8, page.form_body, "&text=") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfScalar(u8, page.form_body[text_at + 6 ..], '&') == null);
        const pad = try a.alloc(u8, form_size - page.form_body.len);
        @memset(pad, '+');
        page.form_body = try std.mem.concat(a, u8, &.{ page.form_body, pad });
        @memset(pad, ' ');
        var response = try json(a, page.response);
        const parsed = response.object.getPtr("parse").?;
        const source = try std.mem.concat(a, u8, &.{ try string(parsed.*, "wikitext"), pad });
        try parsed.object.put(a, "wikitext", .{ .string = source });
        page.response = try std.json.Stringify.valueAlloc(a, response, .{});
        var request = try json(a, page.request);
        try request.object.put(a, "text_source", try descriptorValue(a, source));
        page.request = try std.json.Stringify.valueAlloc(a, request, .{});
        try bindForm(a, &page);
        return page;
    }
    fn documentBytes(a: A, page: RawPage) ![]const u8 {
        var doc = try Testing.document(a, "it");
        doc.pages = &.{page};
        return std.json.Stringify.valueAlloc(a, doc, .{});
    }
};

test "supplied Figure Book accepts complete encoded forms through the exact 128 KiB boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "it");
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/it/figure-siteinfo.raw.json"));
    const original_source = try Testing.source(a, doc);
    const original_html = try Testing.html(a, doc);
    for ([_]usize{ 65536, 65537, 98608, 131072 }) |form_size| {
        errdefer std.debug.print("Book encoded form size={d}\n", .{form_size});
        const page = try FormIntakeTest.padded(a, form_size);
        try std.testing.expectEqual(form_size, page.form_body.len);
        const decoded = try responseSource(a, &ns, page);
        try std.testing.expectEqualStrings(original_html, decoded.html);
        try std.testing.expectEqualStrings(original_source, decoded.source[0..original_source.len]);
        for (decoded.source[original_source.len..]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
        var book = try Book.init(std.testing.allocator, try FormIntakeTest.documentBytes(a, page), &ns, &files, defaults, 250);
        defer book.deinit();
        try std.testing.expectEqual(@as(usize, 1), book.pages.len);
        try std.testing.expectEqualStrings(decoded.source, book.pages[0].source);
        try std.testing.expectEqual(doc.pages[0].occurrences.len, book.pages[0].occurrences.len);
    }
}

test "supplied Figure Book large forms retain bound truncation echo identity and receipt refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "it");
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/it/figure-siteinfo.raw.json"));
    for (0..10) |case| {
        errdefer std.debug.print("Book large form refusal case={d}\n", .{case});
        var page = try FormIntakeTest.padded(a, if (case == 1) 131073 else 98608);
        switch (case) {
            0 => page.form_body = "",
            1 => {}, // A coherent request one byte above the encoded bound.
            2 => page.form_body = page.form_body[0 .. page.form_body.len - 1],
            3 => { // Authenticate a truncated decoded echo: source binding still fails.
                var response = try json(a, page.response);
                const parsed = response.object.getPtr("parse").?;
                const source = try string(parsed.*, "wikitext");
                try parsed.object.put(a, "wikitext", .{ .string = source[0 .. source.len - 1] });
                page.response = try std.json.Stringify.valueAlloc(a, response, .{});
                try FormIntakeTest.bindReceipt(a, &page);
            },
            4 => { // A reauthenticated request cannot misbind the decoded source hash.
                var request = try json(a, page.request);
                try request.object.put(a, "text_source", try FormIntakeTest.descriptorValue(a, "different source"));
                page.request = try std.json.Stringify.valueAlloc(a, request, .{});
                try FormIntakeTest.bindReceipt(a, &page);
            },
            5 => { // Form hash equality does not make an incomplete escape valid.
                const bytes = try a.dupe(u8, page.form_body);
                bytes[bytes.len - 1] = '%'; page.form_body = bytes;
                try FormIntakeTest.bindForm(a, &page);
            },
            6 => { // The separate complete-response ceiling does not change.
                const bytes = try a.alloc(u8, max_response + 1); @memset(bytes, ' ');
                page.response = bytes;
                try FormIntakeTest.bindReceipt(a, &page);
            },
            7 => page.revision_id += 1,
            8 => {
                var request = try json(a, page.request);
                try request.object.put(a, "parse_core_binding_proven", .{ .bool = true });
                page.request = try std.json.Stringify.valueAlloc(a, request, .{});
                try FormIntakeTest.bindReceipt(a, &page);
            },
            9 => page.page_id += 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidFigurePageObservations,
            Book.init(std.testing.allocator, try FormIntakeTest.documentBytes(a, page), &ns, &files, defaults, 250));
    }
}

test "supplied Figure Book intake retains the complete actual Mai response without a sizing grant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/de-mai/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "de-mai");
    try std.testing.expectEqual(@as(usize, 1), doc.pages.len);
    const page = doc.pages[0];
    try std.testing.expectEqual(@as(u64, 721), page.page_id);
    try std.testing.expectEqual(@as(u64, 10777072), page.revision_id);
    try std.testing.expectEqualStrings("Mai", page.title);
    try std.testing.expectEqual(@as(usize, 98608), page.form_body.len);
    try std.testing.expect(digestMatches(page.form_body, "422d2da284ef0642fab212846a76e157951ad79e84d5755a3ba75f07687fc19c"));
    try std.testing.expect(digestMatches(page.response, "e06f8235d0d9b40e5d69e43b5d04588076d7e50ce21634ecb97b822c11c3bc34"));
    const accepted = try responseSource(a, &ns, page);
    try std.testing.expectEqual(@as(usize, 61787), accepted.source.len);
    try std.testing.expectEqual(@as(usize, 110136), accepted.html.len);
    try std.testing.expect(digestMatches(accepted.source, "01d3e7a45d3f9d3504311fdba3eebed4c8a1a2d9f8760c0f9bc11f75b8b00ed8"));
    try std.testing.expect(digestMatches(accepted.html, "bc3875dcb5fdda2c4d329449a7436ec6dd88fece68b60f66a8d5ac5c703c9603"));
    const parsed = try field(try json(a, page.response), "parse");
    if (parsed.object.get("revid")) |revision| try std.testing.expect(revision == .null);
    const request = try json(a, page.request);
    try flag(request, "parse_core_binding_proven", false);
    try flag(request, "historical_transclusions", false);
    // This proves only the normal request/response intake. No Registry, Book
    // occurrence selection, width callback, CSS or full Writer is fabricated.
    var truncated = page; truncated.form_body = page.form_body[0 .. page.form_body.len - 1];
    try std.testing.expectError(error.InvalidFigurePageObservations, responseSource(a, &ns, truncated));
    var wrong_revision = page; wrong_revision.revision_id += 1;
    try std.testing.expectError(error.InvalidFigurePageObservations, responseSource(a, &ns, wrong_revision));
}

const MaiCenteredTest = struct {
    // Independent named rows from the retained normal projection. These rows
    // exercise Book identity checks; they do not grant a sizing-provider result.
    fn registry(a: A, ns: *const namespaces.Registry) !sizing.Registry {
        const rows = try a.alloc(sizing.Record, 2);
        rows[0] = .{ .canonical_file = "Datei:Verteilung Nachname Mai DE.png",
            .file_sha1 = "e6f97c68e843cfe8b2349a27a41b9d64b3e32b94", .file_timestamp = "2020-04-04T04:03:57Z",
            .original_width = 460, .original_height = 600, .format = .thumbnail,
            .width_px = 460, .height_px = null, .sizing = .requested_fit, .proof_kind = "controlled-validator-file-row" };
        rows[1] = .{ .canonical_file = "Datei:Elmar Mai.jpeg",
            .file_sha1 = "012bfbb0476e97f9e8e5d79ec43d36826c773aad", .file_timestamp = "2014-07-16T16:03:24Z",
            .original_width = 2420, .original_height = 3775, .format = .thumbnail,
            .width_px = 2420, .height_px = null, .sizing = .requested_fit, .proof_kind = "controlled-validator-file-row" };
        return .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = ns, .records = rows, .file_authority = true };
    }
    fn withHtml(a: A, original: RawPage, html: []const u8) !RawPage {
        var page = original;
        var response = try json(a, page.response);
        try response.object.getPtr("parse").?.object.put(a, "text", .{ .string = html });
        page.response = try std.json.Stringify.valueAlloc(a, response, .{});
        try FormIntakeTest.bindReceipt(a, &page);
        return page;
    }
};

test "centered bare upright Book selects both complete retained Mai occurrences without a factor or anchor grant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/de-mai/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const raw = @embedFile(prefix ++ "page.raw.wikitext");
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    const doc = try Testing.document(a, "de-mai");
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const source = try Testing.source(a, doc);
    const html = try Testing.html(a, doc);
    try std.testing.expectEqual(@as(usize, 61787), source.len);
    try std.testing.expect(digestMatches(html, "bc3875dcb5fdda2c4d329449a7436ec6dd88fece68b60f66a8d5ac5c703c9603"));
    try std.testing.expectEqualStrings(source, book.pages[0].source);
    const context: compiler.Context = .{ .title = "Mai", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const selected = (try book.select(a, &ns, 0, 721, 10777072, "Mai", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), selected.occurrences.len);
    const original = [_][]const u8{
        "mini|zentriert| hochkant| [1] Verteilung des Nachnamens ''Mai'' in D",
        "mini|zentriert| hochkant| [1] Elmar ''Mai'', Biologe, Filmrealisator und Wissenschaftsjournalist (*1948)",
    };
    const stage = [_][]const u8{
        "mini|zentriert| hochkant| [1] Verteilung des Nachnamens <i>Mai</i> in D",
        "mini|zentriert| hochkant| [1] Elmar <i>Mai</i>, Biologe, Filmrealisator und Wissenschaftsjournalist (*1948)",
    };
    const ranges = [_][2]usize{ .{ 86091, 86890 }, .{ 86924, 87714 } };
    const heights = [_]u32{ 248, 296 };
    for (selected.occurrences, files.records, original, stage, ranges, heights) |row, fact, original_options, stage_options, range, height| {
        try std.testing.expectEqualStrings(fact.canonical_file, row.source.canonical_file);
        try std.testing.expectEqualStrings(original_options, row.source.original_options);
        try std.testing.expectEqualStrings(stage_options, row.stage_options);
        try std.testing.expect(row.source.centered_default_size);
        try std.testing.expectEqual(@as(?u32, 190), row.source.centered_width);
        try std.testing.expectEqual(@as(?u32, 190), row.source.width);
        try std.testing.expect(row.source.anchor == null and row.source.missing_content == null);
        const figure = html[range[0]..range[1]];
        const image_at = std.mem.indexOf(u8, figure, "<img ") orelse return error.TestUnexpectedResult;
        const attrs = try inventory(a, syntax.tagAt(figure, image_at) orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(@as(u32, 190), try positiveAttribute(attrs, "width"));
        try std.testing.expectEqual(height, try positiveAttribute(attrs, "height"));
        try std.testing.expectEqual(fact.original_width, try positiveAttribute(attrs, "data-file-width"));
        try std.testing.expectEqual(fact.original_height, try positiveAttribute(attrs, "data-file-height"));
        for ([_][]const u8{ original_options, stage_options }) |options| {
            try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, fact.canonical_file, .thumbnail, options, 250));
            try std.testing.expect((try SelectedPage.anchor(selected, a, fact.canonical_file, .thumbnail, options)) == null);
        }
        try std.testing.expect((try SelectedPage.width(selected, a, fact.canonical_file, .framed, stage_options, 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, fact.canonical_file, .thumbnail, stage_options, 251)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, fact.canonical_file, .thumbnail, "mini|zentriert|hochkant|changed", 250)) == null);
        try std.testing.expect((try SelectedPage.width(selected, a, "Datei:Other.png", .thumbnail, stage_options, 250)) == null);
    }
    const changed = try a.dupe(u8, source); changed[0] = if (changed[0] == 'X') 'Y' else 'X';
    for ([_]struct { ns: i32 = 0, page: u64 = 721, revision: u64 = 10777072, title: []const u8 = "Mai", raw: []const u8, source: []const u8, width: u32 = 250 }{
        .{ .ns = 1, .raw = raw, .source = source }, .{ .page = 722, .raw = raw, .source = source },
        .{ .revision = 10777073, .raw = raw, .source = source }, .{ .title = "Other", .raw = raw, .source = source },
        .{ .raw = "changed raw", .source = source }, .{ .raw = raw, .source = changed }, .{ .raw = raw, .source = source, .width = 251 },
    }) |case| try std.testing.expect((try book.select(a, &ns, case.ns, case.page, case.revision, case.title, case.raw, case.source, defaults, case.width, context)) == null);
    var stale_defaults = defaults; stale_defaults[0] ^= 1;
    try std.testing.expect((try book.select(a, &ns, 0, 721, 10777072, "Mai", raw, source, stale_defaults, 250, context)) == null);
    var no_images = context; no_images.image_options = null;
    try std.testing.expect((try book.select(a, &ns, 0, 721, 10777072, "Mai", raw, source, defaults, 250, no_images)) == null);
}

test "centered bare upright option proof refuses explicit factors competing dimensions and ambiguous captions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/de-mai/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var images = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    for ([_][]const u8{ "mini|zentriert| hochkant| caption", "thumb|center|upright|caption", "thumb|center|upright|[[Target|caption]]" }) |options|
        try std.testing.expect(centeredThumbnailDimensionOptions(&images, options, 190, true));
    try std.testing.expect(!centeredThumbnailDimensionOptions(&images, "mini|zentriert|hochkant|caption", 0, true));
    for ([_][]const u8{
        "mini|zentriert|hochkant=0.75|caption", "mini|zentriert|hochkant=|caption", "mini|zentriert|190px|caption",
        "mini|zentriert|x190px|caption", "mini|rechts|hochkant|caption", "gerahmt|zentriert|hochkant|caption",
        "mini|hochkant|zentriert|caption", "mini|zentriert|hochkant|190px", "mini|zentriert|hochkant|link=Target",
        "mini|zentriert|hochkant|caption|extra", "mini|zentriert|hochkant|hochkant", "mini|zentriert|hochkant|",
    }) |options| {
        errdefer std.debug.print("centered bare upright options refusal={s}\n", .{options});
        try std.testing.expect(!centeredThumbnailDimensionOptions(&images, options, 190, true));
    }
    try std.testing.expect(centeredThumbnailOptions(&images, "mini|zentriert|190px|caption", 190));
    try std.testing.expect(!centeredThumbnailOptions(&images, "mini|zentriert|hochkant|caption", 190));
}

test "centered bare upright Book preserves selected width file identity complete DOM and ambiguity refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/de-mai/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const original = try Testing.document(a, "de-mai");
    const html = try Testing.html(a, original);
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    for (0..10) |case| {
        errdefer std.debug.print("centered bare upright occurrence refusal={d}\n", .{case});
        var page = original.pages[0];
        const occurrences = try a.dupe(RawOccurrence, page.occurrences);
        page.occurrences = occurrences;
        switch (case) {
            0 => { occurrences[0].width = false; occurrences[0].anchor_attributes = true; },
            1 => occurrences[0].canonical_file = "Datei:Other.png",
            2 => occurrences[0].file_sha1 = "0000000000000000000000000000000000000000",
            3 => occurrences[0].file_timestamp = "2000-01-01T00:00:00Z",
            4 => occurrences[0].original_width += 1,
            5 => occurrences[0].original_height += 1,
            6 => occurrences[0].start += 1,
            7 => occurrences[1] = occurrences[0],
            8 => page = try MaiCenteredTest.withHtml(a, page, try std.mem.concat(a, u8, &.{ html, html })),
            9 => page = try MaiCenteredTest.withHtml(a, page, try std.mem.concat(a, u8, &.{ "<template>", html, "</template>" })),
            else => unreachable,
        }
        var changed = original; changed.pages = &.{page};
        try std.testing.expectError(error.InvalidFigurePageObservations,
            Book.init(std.testing.allocator, try std.json.Stringify.valueAlloc(a, changed, .{}), &ns, &files, defaults, 250));
    }
    for ([_][2][]const u8{
        .{ "class=\"mw-default-size mw-halign-center\"", "class=\"mw-default-size mw-halign-center extra\"" },
        .{ "class=\"mw-default-size mw-halign-center\"", "class=\"mw-halign-center\"" },
        .{ "class=\"mw-file-element mw-file-upright\"", "class=\"mw-file-element\"" },
        .{ "style=\"--mw-file-upright: 0.75\"", "style=\"width:190px\"" },
        .{ " style=\"--mw-file-upright: 0.75\"", "" },
        .{ "width=\"190\"", "width=\"9999\"" },
        .{ "height=\"248\"", "height=\"0\"" },
        .{ "class=\"mw-file-description\"", "class=\"mw-file-description\" CLASS=\"duplicate\"" },
    }) |change| {
        errdefer std.debug.print("centered bare upright HTML refusal={s}\n", .{change[1]});
        try std.testing.expect(std.mem.indexOf(u8, html, change[0]) != null);
        const invalid_html = try std.mem.replaceOwned(u8, a, html, change[0], change[1]);
        const page = try MaiCenteredTest.withHtml(a, original.pages[0], invalid_html);
        var changed = original; changed.pages = &.{page};
        try std.testing.expectError(error.InvalidFigurePageObservations,
            Book.init(std.testing.allocator, try std.json.Stringify.valueAlloc(a, changed, .{}), &ns, &files, defaults, 250));
    }
}

const TextClassTesting = if (@import("builtin").is_test) struct {
    fn has(scope: profile.BoundedTextClassScope, name: []const u8) bool {
        var tokens = std.mem.tokenizeScalar(u8, scope.subtree_classes, ' ');
        while (tokens.next()) |token| if (equal(token, name)) return true;
        return false;
    }
    fn descriptorValue(a: A, bytes: []const u8) !Value {
        const hex = std.fmt.bytesToHex(Testing.hash(bytes), .lower);
        return json(a, try std.json.Stringify.valueAlloc(a, .{ .bytes = bytes.len, .sha256 = @as([]const u8, &hex) }, .{}));
    }
    fn formField(a: A, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
        if (out.items.len != 0) try out.append(a, '&');
        for ([_][]const u8{ key, value }, 0..) |part, index| {
            if (index != 0) try out.append(a, '=');
            for (part) |byte| {
                try out.append(a, '%');
                try out.append(a, "0123456789ABCDEF"[byte >> 4]);
                try out.append(a, "0123456789ABCDEF"[byte & 15]);
            }
        }
    }
    // Controlled transformation of the existing validator fixture only.
    // This does not create a new observation or authenticate a new remote page.
    fn extendedPage(a: A, original: RawPage) !RawPage {
        var page = original;
        var request = try json(a, page.request);
        var parameters = try field(request, "parameters_except_text");
        try parameters.object.put(a, "prop", .{ .string = "text|wikitext|revid|displaytitle|headhtml|modules|jsconfigvars" });
        try parameters.object.put(a, "useskin", .{ .string = "vector-2022" });
        try request.object.put(a, "parameters_except_text", parameters);
        var form: std.ArrayList(u8) = .empty;
        var iterator = parameters.object.iterator();
        while (iterator.next()) |entry| try formField(a, &form, entry.key_ptr.*, entry.value_ptr.string);
        const source = try string(try field(try json(a, page.response), "parse"), "wikitext");
        try formField(a, &form, "text", source);
        page.form_body = try form.toOwnedSlice(a);
        try request.object.put(a, "form", try descriptorValue(a, page.form_body));
        page.request = try std.json.Stringify.valueAlloc(a, request, .{});
        var receipt = try json(a, page.receipt);
        try receipt.object.put(a, "request", try descriptorValue(a, page.request));
        page.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
        page.text_class_scope = true;
        return page;
    }
} else struct {};

test "supplied Figure text class scope inventories the exact root decoded descendants and raw style boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"vi\" dir=\"ltr\">";
    const html = root ++ "<span class=\"alpha&#32;beta\"><b class=\"alpha\">word</b></span><style class=\"stylesheet\">.x{content:'<i class=\"not-an-element\">'}</STYLE><span class=\"after-style\"></span></div> <!--done-->\n";
    const scope = try observedTextClassScope(a, &ns, html);
    try std.testing.expectEqualStrings("div", scope.root_tag);
    try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", scope.root_classes);
    try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output alpha beta stylesheet after-style", scope.subtree_classes);
    try std.testing.expect(!TextClassTesting.has(scope, "not-an-element"));
    try std.testing.expect(!TextClassTesting.has(scope, "skin-vector-2022"));
    const empty = try observedTextClassScope(a, &ns, root ++ "<span class=\"\"></span></div>");
    try std.testing.expectEqualStrings(scope.root_classes, empty.subtree_classes);
    for ([_][]const u8{
        "", "text", root, root ++ "</div>text", "text" ++ root ++ "</div>",
        root ++ "</div><span></span>", root ++ "</div>" ++ root ++ "</div>",
        root ++ "<span></div></span>", root ++ "<span/>", root ++ "<template class=\"hidden\"></template></div>",
        root ++ "<svg></svg></div>", root ++ "<script>ignored</script></div>", root ++ "<textarea></textarea></div>",
        root ++ "<span class=\"a\" CLASS=\"b\"></span></div>", root ++ "<span class=unquoted></span></div>",
        root ++ "<span class=\"bad&unknown;\"></span></div>", root ++ "<style>unclosed</div>",
        root ++ "<img src=\"bad\" onerror=\"changeClasses()\" /></div>",
        root ++ "<style>x</STYLE><span class=\"x\"></span></style></div>",
        root ++ "<!--unclosed</div>", root ++ "</div><!--a--b-->",
        root ++ "<!--><span class=\"hidden-by-invalid-comment\"></span>--></div>",
        root ++ "<!---><span class=\"hidden-by-invalid-comment\"></span>--></div>",
        "<div class=\"mw-parser-output\" lang=\"vi\" dir=\"ltr\"></div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"en\" dir=\"ltr\"></div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"vi\" dir=\"rtl\"></div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"vi\" dir=\"ltr\" id=\"extra\"></div>",
    }) |bad| try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, bad));
    const token = try a.alloc(u8, 1025); @memset(token, 'x');
    try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns,
        try std.fmt.allocPrint(a, "{s}<span class=\"{s}\"></span></div>", .{ root, token })));
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(a, root);
    for (0..128) |_| try deep.appendSlice(a, "<span>");
    for (0..128) |_| try deep.appendSlice(a, "</span>");
    try deep.appendSlice(a, "</div>");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, deep.items));
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(a, root);
    for (0..16384) |_| try many.appendSlice(a, "<br>");
    try many.appendSlice(a, "</div>");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, many.items));
    many.clearRetainingCapacity();
    try many.appendSlice(a, root ++ "<span class=\"");
    for (0..8192) |_| try many.appendSlice(a, "x ");
    try many.appendSlice(a, "\"></span></div>");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, many.items));
    many.clearRetainingCapacity();
    try many.appendSlice(a, root);
    for (0..64) |_| {
        try many.appendSlice(a, "<span class=\"");
        try many.appendSlice(a, token[0..1024]);
        try many.appendSlice(a, "\"></span>");
    }
    try many.appendSlice(a, "</div>");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, many.items));
}

test "supplied Figure v4 certificate remains behind original selection and legacy schema request joins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var doc = try Testing.document(a, "it");
    const raw = @embedFile("testdata/figure-page-observations/it/page.raw.wikitext");
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/it/figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/figure-page-observations/it/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/it/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    const pages = try a.dupe(RawPage, doc.pages);
    for (pages) |*page| page.* = try TextClassTesting.extendedPage(a, page.*);
    doc.pages = pages;
    doc.schema = "wikidict.figure-page-observations.v4";
    var book = try Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{}), &ns, &files, defaults, 250); defer book.deinit();
    const context: compiler.Context = .{ .title = "poliziotto", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const source = try Testing.source(a, doc);
    const copy = try a.dupe(u8, source);
    const selected = (try book.select(a, &ns, 0, 4075, 3935048, "poliziotto", raw, copy, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.text_class_scope != null);
    const bound = selected.text_class_scope_source orelse return error.TestUnexpectedResult;
    try std.testing.expect(bound.ptr == copy.ptr and bound.len == copy.len);
    try std.testing.expect(bound.ptr != book.pages[0].source.ptr);
    try std.testing.expect((try book.select(a, &ns, 0, 4075, 3935048, "poliziotto", raw, copy[1..], defaults, 250, context)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 4075, 3935048, "poliziotto", "changed", copy, defaults, 250, context)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 4075, 3935049, "poliziotto", raw, copy, defaults, 250, context)) == null);
    var wrong_defaults = defaults; wrong_defaults[0] ^= 1;
    try std.testing.expect((try book.select(a, &ns, 0, 4075, 3935048, "poliziotto", raw, copy, wrong_defaults, 250, context)) == null);
    for ([_][]const u8{ "wikidict.figure-page-observations.v1", "wikidict.figure-page-observations.v2", "wikidict.figure-page-observations.v3" }) |schema| {
        doc.schema = schema;
        try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{}), &ns, &files, defaults, 250));
    }
    doc.schema = "wikidict.figure-page-observations.v4";
    pages[0].text_class_scope = false;
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{}), &ns, &files, defaults, 250));
    var legacy = try Testing.document(a, "it"); legacy.schema = "wikidict.figure-page-observations.v4";
    var no_scope = try Book.init(a, try std.json.Stringify.valueAlloc(a, legacy, .{}), &ns, &files, defaults, 250); defer no_scope.deinit();
    const unbound = (try no_scope.select(a, &ns, 0, 4075, 3935048, "poliziotto", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(unbound.text_class_scope == null and unbound.text_class_scope_source == null);
    // A changed form is still rejected before any certificate.
    pages[0].text_class_scope = true;
    pages[0].form_body = try std.mem.concat(a, u8, &.{ pages[0].form_body, "&useskin=other" });
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{}), &ns, &files, defaults, 250));
}

test "supplied Figure text class scope authenticates complete retained cubeb response without outer skin authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const html = @embedFile("testdata/figure-text-class-scope/cubeb/response.html");
    try std.testing.expect(digestMatches(html, "cc858b862fff47ef6d4e631c23af425e3082083cc8ea8301e1dbbe1d57ac5641"));
    const page: RawPage = .{ .namespace_id = 0, .page_id = 12617, .revision_id = 2313690, .title = "cubeb", .raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .text_class_scope = true, .occurrences = &.{},
        .request = @embedFile("testdata/figure-text-class-scope/cubeb/request.json"),
        .form_body = @embedFile("testdata/figure-text-class-scope/cubeb/request.form"),
        .receipt = @embedFile("testdata/figure-text-class-scope/cubeb/receipt.json"),
        .response = @embedFile("testdata/figure-text-class-scope/cubeb/response.json") };
    const response = try responseSource(a, &ns, page);
    try std.testing.expectEqualStrings(html, response.html);
    try std.testing.expect(digestMatches(response.source, "4152682161b163e2dc72b7e0dac620d293ca352328c9866fdb9fdd2a2214f4e3"));
    const scope = try observedTextClassScope(a, &ns, response.html);
    for ([_][]const u8{ "mw-content-ltr", "mw-parser-output", "interproject-box", "interproject-box-logo", "floatright", "mw-file-element", "inflection-table", "indef|nom//acc|s-form-of", "scribunto-error" }) |name|
        try std.testing.expect(TextClassTesting.has(scope, name));
    for ([_][]const u8{ "etymology", "NavContent", "skin-vector-2022", "vector-hide", "k-player" }) |name|
        try std.testing.expect(!TextClassTesting.has(scope, name));
    var wrong_mode = page; wrong_mode.text_class_scope = false;
    try std.testing.expectError(error.InvalidFigurePageObservations, responseSource(a, &ns, wrong_mode));
    var wrong_page = page; wrong_page.page_id += 1;
    try std.testing.expectError(error.InvalidFigurePageObservations, responseSource(a, &ns, wrong_page));
    // The complete HTML/request proof is not a Book occurrence or raw/namespace/default selection proof.
    const defaults = Testing.hash("not selected defaults");
    var empty_files: sizing.Registry = .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = &ns, .records = &.{}, .file_authority = true }; defer empty_files.deinit();
    const namespace_hex = std.fmt.bytesToHex(ns.source_sha256, .lower);
    const defaults_hex = std.fmt.bytesToHex(defaults, .lower);
    const doc: Document = .{ .schema = "wikidict.figure-page-observations.v4", .wiki = ns.wiki, .date = ns.dump_date,
        .namespace_sha256 = &namespace_hex, .defaults_sha256 = &defaults_hex, .pages = &.{page} };
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{}), &ns, &empty_files, defaults, 250));
}

// Build-only observation of the selected outer insertion context. The supplied
// API parser body remains authoritative; this never imports the GET body.
pub const RawOuterContext = struct {
    profile: []const u8,
    receipt: []const u8,
    response: []const u8,
};
const OuterObservedNode = struct { tag: []const u8, attributes: Inventory };
const OuterObservedPrefix = struct {
    ancestors: []const OuterObservedNode,
    root: ?Inventory = null,
    generator: []const u8,
};
// Full skin markup uses ordinary boolean attributes. Keep this parser local;
// the older supplied-body attribute domain remains unchanged.
fn outerInventory(a: A, tag: syntax.Tag) !Inventory {
    var attrs: std.ArrayList(Attribute) = .empty;
    var at: usize = 0;
    while (at < tag.attrs.len) {
        if (!htmlClassSpace(tag.attrs[at])) return invalid;
        while (at < tag.attrs.len and htmlClassSpace(tag.attrs[at])) : (at += 1) {}
        if (at == tag.attrs.len) break;
        const start = at;
        while (at < tag.attrs.len and attributeNameByte(tag.attrs[at])) : (at += 1) {}
        if (at == start or attrs.items.len >= 64) return invalid;
        const name = tag.attrs[start..at];
        for (attrs.items) |old| if (std.ascii.eqlIgnoreCase(old.name, name)) return invalid;
        const after_name = at;
        while (at < tag.attrs.len and htmlClassSpace(tag.attrs[at])) : (at += 1) {}
        var value: []const u8 = "";
        if (at < tag.attrs.len and tag.attrs[at] == '=') {
            at += 1;
            while (at < tag.attrs.len and htmlClassSpace(tag.attrs[at])) : (at += 1) {}
            if (at == tag.attrs.len or (tag.attrs[at] != '"' and tag.attrs[at] != '\'')) return invalid;
            const quote = tag.attrs[at]; at += 1; const begin = at;
            while (at < tag.attrs.len and tag.attrs[at] != quote) : (at += 1) if (tag.attrs[at] == '<' or tag.attrs[at] == '>' or tag.attrs[at] == 0) return invalid;
            if (at == tag.attrs.len) return invalid;
            value = try decodedAttribute(a, tag.attrs[begin..at]); at += 1;
        } else at = after_name;
        try attrs.append(a, .{ .name = name, .value = value });
    }
    return .{ .attributes = try attrs.toOwnedSlice(a) };
}
fn outerVoidTag(tag: syntax.Tag) bool {
    for ([_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |name|
        if (tag.is(name)) return true;
    return false;
}
fn outerRawTextEnd(html: []const u8, tag: syntax.Tag) !usize {
    var at = tag.end;
    while (at < html.len) : (at += 1) {
        if (html[at] != '<' or at + 2 + tag.name.len >= html.len or html[at + 1] != '/' or
            !std.ascii.eqlIgnoreCase(html[at + 2 .. at + 2 + tag.name.len], tag.name)) continue;
        const next = html[at + 2 + tag.name.len];
        if (next != '>' and next != '/' and !htmlClassSpace(next)) continue;
        const close = syntax.tagAt(html, at) orelse return invalid;
        if (!close.closing or close.self_closing or close.attrs.len != 0 or !std.ascii.eqlIgnoreCase(close.name, tag.name)) return invalid;
        return close.end;
    }
    return invalid;
}
// Only a completely explicit lexical prefix is accepted. No HTML error repair,
// implicit parent insertion, or guessed closure can supply an ancestor class.
fn observedOuterPrefix(a: A, html: []const u8, parser_root: bool) !OuterObservedPrefix {
    if (html.len == 0 or html.len > max_response or !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return invalid;
    var stack: [128]OuterObservedNode = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    var generator: ?[]const u8 = null;
    var html_seen = false;
    var body_seen = false;
    var elements: usize = 0;
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            if (std.mem.indexOf(u8, html[at + 4 .. end], "--") != null) return invalid;
            at = end + 3; continue;
        }
        if (html.len - at >= 15 and std.ascii.eqlIgnoreCase(html[at .. at + 15], "<!DOCTYPE html>")) {
            if (html_seen or depth != 0) return invalid;
            at += 15; continue;
        }
        if (html[at] != '<') {
            if (depth == 0 and !htmlClassSpace(html[at])) return invalid;
            at += 1; continue;
        }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at or tag.end > html.len) return invalid;
        const inv = try outerInventory(a, tag);
        if (tag.closing) {
            if (inv.attributes.len != 0 or tag.self_closing or depth == 0 or !std.ascii.eqlIgnoreCase(stack[depth - 1].tag, tag.name)) return invalid;
            depth -= 1; at = tag.end; continue;
        }
        elements += 1;
        if (elements > 16384) return invalid;
        if (tag.is("html")) {
            if (html_seen or depth != 0) return invalid;
            html_seen = true;
        } else if (!html_seen or depth == 0) return invalid;
        if (tag.is("body")) {
            if (body_seen or depth != 1 or !equal(stack[0].tag, "html")) return invalid;
            body_seen = true;
        }
        if (tag.is("meta") and equal(inv.get("name") orelse "", "generator")) {
            if (generator != null or body_seen) return invalid;
            generator = inv.get("content") orelse return invalid;
        }
        if (profile.Profile.hasClass(inv.get("class") orelse "", "mw-parser-output")) {
            if (!parser_root or !body_seen or !tag.is("div") or tag.self_closing) return invalid;
            return .{ .ancestors = try a.dupe(OuterObservedNode, stack[0..depth]), .root = inv, .generator = generator orelse return invalid };
        }
        if (tag.is("script") or tag.is("style")) {
            if (tag.self_closing) return invalid;
            at = try outerRawTextEnd(html, tag); continue;
        }
        if (!outerVoidTag(tag)) {
            if (tag.self_closing or depth == stack.len) return invalid;
            stack[depth] = .{ .tag = tag.name, .attributes = inv }; depth += 1;
        }
        at = tag.end;
    }
    if (parser_root or !html_seen or !body_seen or depth != 2 or !equal(stack[0].tag, "html") or !equal(stack[1].tag, "body")) return invalid;
    return .{ .ancestors = try a.dupe(OuterObservedNode, stack[0..depth]), .generator = generator orelse return invalid };
}
fn outerSameAttributes(left: Inventory, right: Inventory, omit_class: bool) bool {
    var left_count: usize = 0;
    var right_count: usize = 0;
    for (left.attributes) |attr| {
        if (omit_class and equal(attr.name, "class")) continue;
        left_count += 1;
        if (!equal(attr.value, right.get(attr.name) orelse return false)) return false;
    }
    for (right.attributes) |attr| { if (!(omit_class and equal(attr.name, "class"))) right_count += 1; }
    return left_count == right_count;
}
fn outerRootClassesCompatible(left: []const u8, right: []const u8) bool {
    for ([_][2][]const u8{ .{ left, right }, .{ right, left } }) |pair| {
        var it = std.mem.tokenizeAny(u8, pair[0], " \t\r\n\x0c");
        while (it.next()) |name| {
            // SkinVector22 adds this finite TOC state while building template
            // data after the API has emitted headhtml. Both states are retained.
            if (equal(name, "vector-toc-available") or equal(name, "vector-toc-not-available")) continue;
            if (!profile.Profile.hasClass(pair[1], name)) return false;
        }
    }
    return true;
}
fn appendOuterClasses(a: A, result: *std.ArrayList(u8), classes: []const u8) !void {
    if (classes.len > 65536) return invalid;
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0c");
    while (it.next()) |name| {
        if (name.len > 1024) return invalid;
        for (name) |byte| if (byte < 0x20 or byte == 0x7f) return invalid;
        if (profile.Profile.hasClass(result.items, name)) continue;
        if (result.items.len + name.len + 1 > 65536) return invalid;
        if (result.items.len != 0) try result.append(a, ' ');
        try result.appendSlice(a, name);
    }
}
fn observedOuterClasses(a: A, ns: *const namespaces.Registry, page: RawPage, outer: RawOuterContext, scope: profile.BoundedTextClassScope) ![]const u8 {
    if (!page.text_class_scope or !equal(outer.profile, "mediawiki-vector-2022-1.48.0-wmf.3") or outer.receipt.len == 0 or outer.receipt.len > 64 * 1024) return invalid;
    const receipt = try std.json.parseFromSliceLeaky(Value, a, outer.receipt, .{ .allocate = .alloc_always });
    const sources = try field(receipt, "sources");
    if (sources != .array or sources.array.items.len != 1) return invalid;
    const source = sources.array.items[0];
    if (try number(source, "status") != 200) return invalid;
    try descriptor(outer.response, source);
    const url = try string(source, "url");
    if (!equal(url, try string(source, "final_url"))) return invalid;
    if (!std.mem.endsWith(u8, ns.wiki, "wiktionary") or ns.wiki.len <= "wiktionary".len) return invalid;
    const language = try a.dupe(u8, ns.wiki[0 .. ns.wiki.len - "wiktionary".len]);
    std.mem.replaceScalar(u8, language, '_', '-');
    const prefix = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/index.php?", .{language});
    if (!std.mem.startsWith(u8, url, prefix)) return invalid;
    var query = std.mem.splitScalar(u8, url[prefix.len..], '&');
    var title_seen = false; var revision_seen = false; var skin_seen = false;
    while (query.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return invalid;
        const key = part[0..split]; const value = try formDecode(a, part[split + 1 ..]);
        if (equal(key, "title")) { if (title_seen or !equal(value, page.title)) return invalid; title_seen = true; }
        else if (equal(key, "oldid")) { if (revision_seen or (std.fmt.parseInt(u64, value, 10) catch return invalid) != page.revision_id) return invalid; revision_seen = true; }
        else if (equal(key, "useskin")) { if (skin_seen or !equal(value, "vector-2022")) return invalid; skin_seen = true; }
        else return invalid;
    }
    if (!title_seen or !revision_seen or !skin_seen) return invalid;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, page.response, .{ .allocate = .alloc_always });
    const supplied = try observedOuterPrefix(a, try string(try field(parsed, "parse"), "headhtml"), false);
    const observed = try observedOuterPrefix(a, outer.response, true);
    if (!equal(supplied.generator, "MediaWiki 1.48.0-wmf.3") or !equal(observed.generator, supplied.generator) or observed.ancestors.len != 8) return invalid;
    if (!outerSameAttributes(supplied.ancestors[1].attributes, observed.ancestors[1].attributes, false) or
        !outerSameAttributes(supplied.ancestors[0].attributes, observed.ancestors[0].attributes, true) or
        !outerRootClassesCompatible(supplied.ancestors[0].attributes.get("class") orelse "", observed.ancestors[0].attributes.get("class") orelse "")) return invalid;
    const tags = [_][]const u8{ "div", "div", "div", "main", "div", "div" };
    const classes = [_][]const u8{ "mw-page-container", "mw-page-container-inner", "mw-content-container", "mw-body", "vector-body", "mw-body-content" };
    const ids = [_][]const u8{ "", "", "", "content", "bodyContent", "mw-content-text" };
    for (observed.ancestors[2..], tags, classes, ids) |node, tag, class, id| {
        if (!equal(node.tag, tag) or !profile.Profile.hasClass(node.attributes.get("class") orelse "", class) or !equal(node.attributes.get("id") orelse "", id)) return invalid;
    }
    const root = observed.root orelse return invalid;
    if (!equal(root.get("class") orelse "", scope.root_classes) or !equal(root.get("lang") orelse "", ns.content_language) or !equal(root.get("dir") orelse "", "ltr")) return invalid;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    for (observed.ancestors) |node| {
        for (node.attributes.attributes) |attr| if (attr.name.len >= 2 and std.ascii.eqlIgnoreCase(attr.name[0..2], "on")) return invalid;
        try appendOuterClasses(a, &result, node.attributes.get("class") orelse "");
    }
    try appendOuterClasses(a, &result, supplied.ancestors[0].attributes.get("class") orelse "");
    return result.toOwnedSlice(a);
}

// This is a conservative source inventory, not an HTML/wikitext renderer.
// Inspect even protected/text occurrences: extra classes can only prevent an
// absence proof. Unrepresented class-value syntax refuses the certificate.
fn appendAuthoredSourceClasses(a: A, result: *std.ArrayList(u8), source: []const u8) !void {
    if (source.len == 0 or source.len > max_response or !std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return invalid;
    // Match Tag.attribute source whitespace, including vertical tab. The
    // returned HTML inventory deliberately keeps its separate HTML grammar.
    var at: usize = 0;
    var values: usize = 0;
    var value_bytes: usize = 0;
    while (at < source.len) : (at += 1) {
        if (source.len - at < 5 or !std.ascii.eqlIgnoreCase(source[at..][0..5], "class") or
            (at != 0 and attributeNameByte(source[at - 1]))) continue;
        var cursor = at + 5;
        if (cursor < source.len and attributeNameByte(source[cursor])) continue;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == source.len or source[cursor] != '=') continue;
        cursor += 1;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == source.len) return invalid;
        const quoted = source[cursor] == '"' or source[cursor] == '\'';
        const quote = source[cursor];
        if (quoted) cursor += 1;
        const begin = cursor;
        if (quoted) {
            while (cursor < source.len and source[cursor] != quote) : (cursor += 1) {
                // Inclusions/manual conversion could change the class value
                // after this source boundary; no such rewrite is certified here.
                if (std.mem.indexOfScalar(u8, "<>{}", source[cursor]) != null) return invalid;
            }
            if (cursor == source.len) return invalid;
        } else {
            while (cursor < source.len and !std.ascii.isWhitespace(source[cursor]) and source[cursor] != '>') : (cursor += 1) {
                // A compact wiki cell separator and an HTML unquoted value
                // have different endpoints. Keep that ambiguity unresolved.
                if (std.mem.indexOfScalar(u8, "\"'`=</|!{}", source[cursor]) != null) return invalid;
            }
            if (cursor == begin) return invalid;
        }
        const raw = source[begin..cursor];
        values += 1;
        if (values > 8192 or raw.len > 65536 - value_bytes) return invalid;
        value_bytes += raw.len;
        const decoded = try decodedAttribute(a, raw);
        defer a.free(decoded);
        try appendOuterClasses(a, result, decoded);
        if (quoted) {
            cursor += 1;
            if (cursor < source.len and !std.ascii.isWhitespace(source[cursor]) and
                std.mem.indexOfScalar(u8, ">/|!", source[cursor]) == null) return invalid;
        }
        // Continue at the next source byte, including inside this candidate.
        // A false-positive quoted occurrence in text cannot hide a later real
        // wiki attribute. Conflicting nested candidates conservatively refuse.
    }
}

fn completeObservedTextClassSuperset(a: A, scope: profile.BoundedTextClassScope, outer_classes: []const u8, source: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    try appendOuterClasses(a, &result, outer_classes);
    try appendOuterClasses(a, &result, scope.root_classes);
    try appendOuterClasses(a, &result, scope.subtree_classes);
    try appendAuthoredSourceClasses(a, &result, source);
    return result.toOwnedSlice(a);
}

const OuterContextTesting = if (@import("builtin").is_test) struct {
    fn page() RawPage {
        return .{ .namespace_id = 0, .page_id = 12617, .revision_id = 2313690, .title = "cubeb", .raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000", .text_class_scope = true, .occurrences = &.{},
            .request = @embedFile("testdata/figure-text-class-scope/cubeb/request.json"),
            .form_body = @embedFile("testdata/figure-text-class-scope/cubeb/request.form"),
            .receipt = @embedFile("testdata/figure-text-class-scope/cubeb/receipt.json"),
            .response = @embedFile("testdata/figure-text-class-scope/cubeb/response.json") };
    }
    fn outer() RawOuterContext {
        return .{ .profile = "mediawiki-vector-2022-1.48.0-wmf.3",
            .receipt = @embedFile("testdata/figure-outer-context/cubeb/receipt.json"),
            .response = @embedFile("testdata/figure-outer-context/cubeb/response.html") };
    }
    // Controlled validator input, never described as a new remote observation.
    fn replaced(a: A, original: RawOuterContext, before: []const u8, after: []const u8) !RawOuterContext {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, original.response, before));
        var result = original;
        result.response = try std.mem.replaceOwned(u8, a, original.response, before, after);
        var receipt = try json(a, original.receipt);
        const sources = try field(receipt, "sources");
        var source = sources.array.items[0];
        const description = try TextClassTesting.descriptorValue(a, result.response);
        try source.object.put(a, "bytes", try field(description, "bytes"));
        try source.object.put(a, "sha256", try field(description, "sha256"));
        sources.array.items[0] = source;
        try receipt.object.put(a, "sources", sources);
        result.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
        return result;
    }
} else struct {};

test "observed outer context binds the supplied body to only the captured Vector insertion ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const page = OuterContextTesting.page();
    const supplied = try responseSource(a, &ns, page);
    try std.testing.expect(digestMatches(supplied.source, "4152682161b163e2dc72b7e0dac620d293ca352328c9866fdb9fdd2a2214f4e3"));
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    const outer = OuterContextTesting.outer();
    try std.testing.expect(digestMatches(outer.response, "c3f78ca7d2e67626675adc939705db10e54e2707e9b2aeaa6b2da909f9ae17c9"));
    const classes = try observedOuterClasses(a, &ns, page, outer, scope);
    for ([_][]const u8{ "client-nojs", "skin-vector-2022", "skin--responsive", "vector-toc-available", "mw-page-container", "mw-page-container-inner", "mw-content-container", "mw-body", "vector-body", "mw-body-content" }) |name|
        try std.testing.expect(profile.Profile.hasClass(classes, name));
    for ([_][]const u8{ "etymology", "NavContent", "biota", "headword-line", "inflection-table" }) |name|
        try std.testing.expect(!profile.Profile.hasClass(classes, name));
    try std.testing.expect(TextClassTesting.has(scope, "biota") and TextClassTesting.has(scope, "headword-line"));
    // The original API body and its source remain exact; the GET's distinct
    // Romanian body and generated SECTION/RDFa nodes are not imported.
    try std.testing.expectEqualStrings(@embedFile("testdata/figure-text-class-scope/cubeb/response.html"), supplied.html);
    const prefix = try observedOuterPrefix(a, outer.response, true);
    try std.testing.expectEqual(@as(usize, 8), prefix.ancestors.len);
    const expected_tags = [_][]const u8{ "html", "body", "div", "div", "div", "main", "div", "div" };
    for (prefix.ancestors, expected_tags) |node, tag| try std.testing.expectEqualStrings(tag, node.tag);
    const body = prefix.ancestors[6].attributes;
    try std.testing.expectEqualStrings("", body.get("data-mw-ve-target-container") orelse return error.TestUnexpectedResult);
}

test "observed outer context refuses missing mismatched and unrepresented ancestry without changing the supplied domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const page = OuterContextTesting.page(); const outer = OuterContextTesting.outer();
    const supplied = try responseSource(a, &ns, page);
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    var wrong = page; wrong.title = "different";
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, wrong, outer, scope));
    wrong = page; wrong.revision_id += 1;
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, wrong, outer, scope));
    wrong = page; wrong.text_class_scope = false;
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, wrong, outer, scope));
    var unsupported = outer; unsupported.profile = "unknown";
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, page, unsupported, scope));
    unsupported = outer; unsupported.response = try std.mem.concat(a, u8, &.{ outer.response, "changed" });
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, page, unsupported, scope));
    for ([_][2][]const u8{
        .{ "content=\"MediaWiki 1.48.0-wmf.3\"", "content=\"MediaWiki 1.48.0-wmf.4\"" },
        .{ "<div class=\"mw-page-container\">", "<div class=\"mw-page-container\"><div class=\"unrepresented\">" },
        .{ "id=\"bodyContent\" class=\"vector-body\"", "id=\"wrongContent\" class=\"vector-body\"" },
        .{ "id=\"bodyContent\" class=\"vector-body\"", "id=\"bodyContent\" class=\"vector-body\" onload=\"change()\"" },
        .{ "id=\"bodyContent\" class=\"vector-body\"", "id=\"bodyContent\" class=\"vector-body\" CLASS=\"duplicate\"" },
    }) |change| {
        const modified = try OuterContextTesting.replaced(a, outer, change[0], change[1]);
        try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, page, modified, scope));
    }
    var wrong_scope = scope; wrong_scope.root_classes = "mw-parser-output";
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterClasses(a, &ns, page, outer, wrong_scope));
    for ([_][]const u8{ "", "<html><body>", "<html><head><meta name=\"generator\" content=\"MediaWiki 1.48.0-wmf.3\"></head><body><div>", "<html><head></head><body><div></body></div>" }) |bad|
        try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterPrefix(a, bad, false));
}

test "observed outer context keeps necessary ancestor classes present rather than granting a selector match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const page = OuterContextTesting.page(); const outer = OuterContextTesting.outer();
    const supplied = try responseSource(a, &ns, page);
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    const modified = try OuterContextTesting.replaced(a, outer, "<div class=\"mw-page-container\">", "<div class=\"mw-page-container etymology NavContent\">");
    const classes = try observedOuterClasses(a, &ns, page, modified, scope);
    try std.testing.expect(profile.Profile.hasClass(classes, "etymology") and profile.Profile.hasClass(classes, "NavContent"));
    // Extra classes conservatively stop absence refutation; no tag adjacency,
    // selector order, positive paint or computed layout is inferred here.
    try std.testing.expect(!TextClassTesting.has(scope, "etymology"));
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
}

test "complete observed class superset retains authored source classes absent from the observed subtree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const page = OuterContextTesting.page();
    const supplied = try responseSource(a, &ns, page);
    try std.testing.expect(digestMatches(supplied.source, "4152682161b163e2dc72b7e0dac620d293ca352328c9866fdb9fdd2a2214f4e3"));
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    const outer = try observedOuterClasses(a, &ns, page, OuterContextTesting.outer(), scope);
    const complete = try completeObservedTextClassSuperset(a, scope, outer, supplied.source);
    for ([_][]const u8{ "skin-vector-2022", "vector-toc-available", "mw-parser-output", "biota", "IPA", "usage-label-sense", "inflection-table", "outer", "separator" }) |name|
        try std.testing.expect(profile.Profile.hasClass(complete, name));
    try std.testing.expect(!profile.Profile.hasClass(complete, "etymology") and !profile.Profile.hasClass(complete, "NavContent"));
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    // Controlled omission, not a claim about the retained remote response:
    // the exact retained source still supplies a class stripped from HTML.
    const spelling = "class=\"biota\"";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, spelling));
    const stripped = try std.mem.replaceOwned(u8, a, supplied.html, spelling, "class=\"\"");
    const stripped_scope = try observedTextClassScope(a, &ns, stripped);
    try std.testing.expect(!TextClassTesting.has(stripped_scope, "biota"));
    const restored = try completeObservedTextClassSuperset(a, stripped_scope, outer, supplied.source);
    try std.testing.expect(profile.Profile.hasClass(restored, "biota"));
    for ([_][2][]const u8{ .{ complete, restored }, .{ restored, complete } }) |pair| {
        var names = std.mem.tokenizeAny(u8, pair[0], " \t\r\n\x0c");
        while (names.next()) |name| try std.testing.expect(profile.Profile.hasClass(pair[1], name));
    }
    try std.testing.expectEqualStrings(@embedFile("testdata/figure-text-class-scope/cubeb/response.html"), supplied.html);
    try std.testing.expect(digestMatches(supplied.source, "4152682161b163e2dc72b7e0dac620d293ca352328c9866fdb9fdd2a2214f4e3"));
}

test "authored class inventory covers HTML wiki attributes entities unquoted values and protected false positives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const source =
        "<div CLASS = \"alpha&#32;bet&#97;\" data-class=ignored><span class=html>body</span></div>\n" ++
        "{| class=table \n|- class='row' \n| class=cell | value\n|}\n" ++
        "<nowiki>literal class='protected' </nowiki> plain class=text_only \n" ++
        "<span class=\"literal|pipe &#x3b2;\"></span> class='' \n";
    const scope: profile.BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "root", .subtree_classes = "root observed alpha" };
    const actual = try completeObservedTextClassSuperset(a, scope, "shell root", source);
    try std.testing.expectEqualStrings("shell root observed alpha beta html table row cell protected text_only literal|pipe \xce\xb2", actual);
    try std.testing.expect(!profile.Profile.hasClass(actual, "ignored"));
    // Source Tag.attribute accepts ASCII VT at all attribute boundaries.
    // Missing this candidate would incorrectly certify ancestor absence.
    for ([_][2][]const u8{
        .{ "<span class\x0b=etymology>text</span>", "etymology" },
        .{ "<span class=\x0bNavContent>text</span>", "NavContent" },
        .{ "<span class=terminal\x0btitle=ignored>text</span>", "terminal" },
        .{ "<span class='afterquote'\x0btitle=ignored>text</span>", "afterquote" },
    }) |case| {
        const complete = try completeObservedTextClassSuperset(a, scope, "shell", case[0]);
        try std.testing.expect(profile.Profile.hasClass(complete, case[1]));
        try std.testing.expect(!profile.Profile.hasClass(complete, "ignored"));
    }
    // Scanning a false-positive quoted occurrence must not skip an embedded
    // wiki class candidate: conflicting interpretations stay unresolved.
    try std.testing.expectError(error.InvalidFigurePageObservations,
        completeObservedTextClassSuperset(a, scope, "shell", "class=\"quoted class=hidden\" "));
}

test "authored class inventory refuses uncertain values truncation encoding and bounded resource excess" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const scope: profile.BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "root", .subtree_classes = "root" };
    for ([_][]const u8{
        "", "class=", "class='unfinished", "class=\"unfinished", "class=\"ok\"extra",
        "class=unquoted|cell", "class=unquoted!!header", "class=unquoted/>", "class=unquoted=other",
        "class=unquoted`other", "class=unquoted'other", "class=unquoted<other", "class=\"-{converted}-\"",
        "class=\"one<includeonly>two</includeonly>\"", "class='&unknown;'", "class='&#0;'", "class='&#xD800;'",
        "class='&#x110000;'", "class='&amp'", "class='\x00'", "class='\xff'", "class='\x7f'", "class='&#11;'",
    }) |bad| try std.testing.expectError(error.InvalidFigurePageObservations, completeObservedTextClassSuperset(a, scope, "shell", bad));
    const token = try a.alloc(u8, 1025); @memset(token, 'a');
    const boundary = try std.fmt.allocPrint(a, "class='{s}' ", .{token[0..1024]});
    try std.testing.expect(profile.Profile.hasClass(try completeObservedTextClassSuperset(a, scope, "shell", boundary), token[0..1024]));
    try std.testing.expectError(error.InvalidFigurePageObservations,
        completeObservedTextClassSuperset(a, scope, "shell", try std.fmt.allocPrint(a, "class='{s}' ", .{token})));
    var repeated: std.ArrayList(u8) = .empty;
    for (0..8192) |_| try repeated.appendSlice(a, "class=x ");
    try std.testing.expectEqualStrings("shell root x", try completeObservedTextClassSuperset(a, scope, "shell", repeated.items));
    try repeated.appendSlice(a, "class=x ");
    try std.testing.expectError(error.InvalidFigurePageObservations, completeObservedTextClassSuperset(a, scope, "shell", repeated.items));
    var byte_limit: std.ArrayList(u8) = .empty;
    for (0..65) |_| try byte_limit.appendSlice(a, boundary);
    try std.testing.expectError(error.InvalidFigurePageObservations, completeObservedTextClassSuperset(a, scope, "shell", byte_limit.items));
    const too_large = try a.alloc(u8, max_response + 1); @memset(too_large, ' ');
    try std.testing.expectError(error.InvalidFigurePageObservations, completeObservedTextClassSuperset(a, scope, "shell", too_large));
}

test "height-only observed fit preserves exact half-up axes and refuses cap inference" {
    try std.testing.expect(observedHeightFit(197, 170, 630, 545));
    try std.testing.expect(observedHeightFit(156, 250, 1000, 1600));
    for ([_][4]u32{ .{196,170,630,545}, .{198,170,630,545}, .{156,248,1000,1600},
        .{0,170,630,545}, .{197,0,630,545}, .{631,546,630,545}, .{197,170,0,545} }) |row|
        try std.testing.expect(!observedHeightFit(row[0], row[1], row[2], row[3]));
    try std.testing.expect(observedHeightFit(std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "complete EL height Book preserves rich tokens and independent capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const bytes = @embedFile("testdata/figure-page-observations/el-height/figure-page-observations.json");
    const raw = @embedFile("testdata/figure-page-observations/el-height/page.raw.wikitext");
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/el-height/figure-siteinfo.raw.json"));
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/el-height/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/figure-page-observations/el-height/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/el-height/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    const document = try Testing.document(a, "el-height");
    // Controlled Registry rows test only this validator. A normal saved Writer
    // must separately replay genuine raw file batches before source admission.
    var files = try Testing.registry(a, &ns, document); defer files.deinit();
    files.height_bound_records = &.{ .svg_redundant_height, .svg_redundant_height };
    var book = try Book.init(std.testing.allocator, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const source = try Testing.source(a, document);
    const context: compiler.Context = .{ .title = "λεκάνη", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const selected = (try book.select(a, &ns, 0, 5630, 7336336, "λεκάνη", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const heights = [_]u32{170,250}; const widths = [_]u32{630,1000}; const observed = [_]u32{197,156};
    for (selected.occurrences, heights, widths, observed) |row, height, width, actual_width| {
        try std.testing.expectEqual(actual_width, row.source.height.?.observed_width);
        for ([_][]const u8{row.source.original_options,row.stage_options}) |options|
            try std.testing.expectEqual(@as(?u32,width), try SelectedPage.height(selected,a,ns.wiki,"λεκάνη",row.source.canonical_file,.thumbnail,options,height));
        try std.testing.expect((try SelectedPage.width(selected,a,row.source.canonical_file,.thumbnail,row.stage_options,250))==null);
        try std.testing.expect((try SelectedPage.anchor(selected,a,row.source.canonical_file,.thumbnail,row.stage_options))==null);
        try std.testing.expect((try SelectedPage.height(selected,a,ns.wiki,"other",row.source.canonical_file,.thumbnail,row.stage_options,height))==null);
        try std.testing.expect((try SelectedPage.height(selected,a,"otherwiki","λεκάνη",row.source.canonical_file,.thumbnail,row.stage_options,height))==null);
        try std.testing.expect((try SelectedPage.height(selected,a,ns.wiki,"λεκάνη",row.source.canonical_file,.thumbnail,row.stage_options,height+1))==null);
        try std.testing.expect((try SelectedPage.height(selected,a,ns.wiki,"λεκάνη",row.source.canonical_file,.framed,row.stage_options,height))==null);
        try std.testing.expect(!heightThumbnailOptions(&images,"thumb|right|170px|caption",height));
        try std.testing.expect(!heightThumbnailOptions(&images,"thumb|left|x170px|caption",height));
        try std.testing.expect(!heightThumbnailOptions(&images,"thumb|right|x170px|caption|extra",height));
    }
    try std.testing.expect((try book.select(a,&ns,0,5630,7336337,"λεκάνη",raw,source,defaults,250,context))==null);
    try std.testing.expect((try book.select(a,&ns,0,5630,7336336,"λεκάνη",raw,source[1..],defaults,250,context))==null);
    files.height_bound_records = &.{ .none,.none };
    try std.testing.expectError(error.InvalidFigurePageObservations,Book.init(a,bytes,&ns,&files,defaults,250));
}

test "EL height HTML refuses changed axes classes style and duplicate image authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a,@embedFile("testdata/figure-page-observations/el-height/namespace-registry.tsv")); defer ns.deinit();
    const document = try Testing.document(a,"el-height"); const html = try Testing.html(a,document);
    for ([_][2][]const u8{
        .{ "width=\"197\" height=\"170\"", "width=\"196\" height=\"170\"" },
        .{ "width=\"197\" height=\"170\"", "width=\"197\" height=\"169\"" },
        .{ "data-file-width=\"630\"", "data-file-width=\"631\"" },
        .{ "class=\"mw-halign-right\"", "class=\"mw-halign-left\"" },
        .{ "width=\"197\"", "style=\"width:197px\" width=\"197\"" },
    }) |replacement| {
        const changed = try std.mem.replaceOwned(u8,a,html,replacement[0],replacement[1]);
        try std.testing.expect(!equal(changed,html));
        try std.testing.expectError(error.InvalidFigurePageObservations,observedImages(a,&ns,changed,document.pages[0].occurrences));
    }
    const duplicate = try std.mem.concat(a,u8,&.{html,html});
    try std.testing.expectError(error.InvalidFigurePageObservations,observedImages(a,&ns,duplicate,document.pages[0].occurrences));
}

test "missing Book authored widths bind exact source options and observed Figure classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile("testdata/figure-page-observations/th-missing-width/behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    const file = try canonicalFile(a, &ns, "File:Absent.png");
    const occurrence: RawOccurrence = .{ .start = 0, .end = 1, .canonical_file = file, .missing_content = true };
    for ([_]u32{ 100, 250, 500 }) |width| for ([_]bool{ false, true }) |right| {
        const html = try std.fmt.allocPrint(a, "<figure class=\"{s}\" typeof=\"mw:Error mw:File/Thumb\"><a href=\"//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png\" class=\"new\" title=\"{s}\"><span class=\"mw-file-element mw-broken-media\" data-width=\"{d}\">{s}</span></a><figcaption><i>Caption</i></figcaption></figure>", .{ if (right) "mw-halign-right" else "", file, width, file });
        const observed = try observedImages(a, &ns, html, &.{occurrence});
        const missing = observed[0].missing_content orelse return error.TestUnexpectedResult;
        try std.testing.expect(!missing.default_size and missing.right == right and !missing.paint_root_proven);
        try std.testing.expectEqual(@as(u32, 0), observed[0].width);
        try std.testing.expectEqual(width, missing.data_width);
        try std.testing.expectEqualStrings(file, missing.label);
        try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png", missing.href);
        const first = try std.fmt.allocPrint(a, "thumb|{s}{d}px|Caption", .{ if (right) "right|" else "", width });
        const second = try std.fmt.allocPrint(a, "thumb|{d}px|{s}Caption", .{ width, if (right) "right|" else "" });
        try std.testing.expect(missingThumbnailOptionsForObservation(&options, first, missing));
        try std.testing.expect(missingThumbnailOptionsForObservation(&options, second, missing));
        if (!right) {
            // Html::openElement drops an empty class list before serialization.
            const omitted_class = try std.mem.replaceOwned(u8, a, html, "<figure class=\"\"", "<figure");
            const omitted = try observedImages(a, &ns, omitted_class, &.{occurrence});
            const without_class = omitted[0].missing_content orelse return error.TestUnexpectedResult;
            try std.testing.expect(!without_class.default_size and !without_class.right);
            try std.testing.expect(missingThumbnailOptionsForObservation(&options, first, without_class));
            try std.testing.expectEqualStrings(missing.href, without_class.href);
            try std.testing.expectEqualStrings(missing.label, without_class.label);
            try std.testing.expectEqual(width, without_class.data_width);
        }
        var mismatch = missing; mismatch.data_width += 1;
        try std.testing.expect(!missingThumbnailOptionsForObservation(&options, first, mismatch));
        mismatch = missing; mismatch.default_size = true;
        try std.testing.expect(!missingThumbnailOptionsForObservation(&options, first, mismatch));
        mismatch = missing; mismatch.right = !right;
        try std.testing.expect(!missingThumbnailOptionsForObservation(&options, first, mismatch));
        for ([_][]const u8{ "thumb|right|Caption", "thumb|0px|Caption", "thumb|250x100px|Caption", "thumb|250px|250px|Caption", "thumb|upright|250px|Caption", "thumb|left|250px|Caption", "thumb|250px|alt=Other|Caption", "thumb|250px|", "thumb|250px|Caption|extra" }) |denied|
            try std.testing.expect(!missingThumbnailOptionsForObservation(&options, denied, missing));
        const bad_class = try std.mem.replaceOwned(u8, a, html, "typeof=", "style=\"width:250px\" typeof=");
        try std.testing.expectError(invalid, observedImages(a, &ns, bad_class, &.{occurrence}));
        const duplicate = try std.mem.concat(a, u8, &.{ html, html });
        try std.testing.expectError(invalid, observedImages(a, &ns, duplicate, &.{occurrence}));
    };
}

test "retained complete TH missing width observation preserves source action and refuses unproved paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const doc = try std.json.parseFromSliceLeaky(Document, a, @embedFile("testdata/figure-page-observations/th-missing-width/figure-page-observations.json"), .{ .allocate = .alloc_always });
    var selected: ?RawPage = null;
    for (doc.pages) |page| if (page.page_id == 108817) { try std.testing.expect(selected == null); selected = page; };
    const page = selected orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2190988), page.revision_id);
    try std.testing.expectEqual(@as(usize, 1), page.occurrences.len);
    try std.testing.expect(page.occurrences[0].missing_content and page.occurrences[0].original_width == 0 and page.occurrences[0].original_height == 0);
    const accepted = try responseSource(a, &ns, page);
    try std.testing.expectEqual(@as(usize, 59937), accepted.source.len);
    try std.testing.expectEqual(@as(usize, 96209), accepted.html.len);
    try std.testing.expect(digestMatches(accepted.source, "2b8290b10c31fd1cf7ba37150dd5bc067098f007b4f15e3efb499ae69624fd07"));
    try std.testing.expect(digestMatches(accepted.html, "885776131abb832ed18b8b04ea3f3444717170b4f7ed36432917c8fcfee8a9e9"));
    const observed = try observedImages(a, &ns, accepted.html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expectEqual(@as(u32, 0), observed[0].width);
    const missing = observed[0].missing_content orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 100), missing.data_width);
    try std.testing.expect(missing.right and !missing.default_size and !missing.paint_root_proven);
    try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, missing.label);
    try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?uselang=th&wpDestFile=%E0%B8%A0%E0%B8%B2%E0%B8%A9%E0%B8%B2%E0%B8%8D%E0%B8%B5%E0%B9%88%E0%B8%9B%E0%B8%B8%E0%B9%88%E0%B8%99_ryakuji_KAN.png", missing.href);
    try std.testing.expect(missing.element.get("src") == null and missing.element.get("width") == null and missing.element.get("height") == null);
    const behavior_bytes = @embedFile("testdata/figure-page-observations/th-missing-width/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    const original = try originalOptions(a, &ns, accepted.source, page.occurrences[0]);
    try std.testing.expect(std.mem.startsWith(u8, original, "thumb|right|100px|"));
    try std.testing.expect(missingThumbnailOptionsForObservation(&options, original, missing));
    const stage = try compiler.figureObservationStageOptionsAlloc(a, original, .{ .title = page.title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options });
    try std.testing.expect(missingThumbnailOptionsForObservation(&options, stage, missing));
    const parsed = try field(try json(a, page.response), "parse");
    if (parsed.object.get("revid")) |revision| try std.testing.expect(revision == .null);
    var altered = page; altered.revision_id += 1;
    try std.testing.expectError(invalid, responseSource(a, &ns, altered));
    altered = page; altered.form_body = page.form_body[0 .. page.form_body.len - 1];
    try std.testing.expectError(invalid, responseSource(a, &ns, altered));
    // This retains a real missing occurrence with embedded STYLE and no IMG.
    // It does not fabricate Registry authority, served paint or full-page output.
}

const ExplicitRubyObservationFixture = struct {
    fn figure(a: A, file: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "<figure class=\"mw-halign-right\" typeof=\"mw:Error mw:File/Thumb\"><a href=\"//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png\" class=\"new\" title=\"{s}\"><span class=\"mw-file-element mw-broken-media\" data-width=\"100\">{s}</span></a><figcaption>Caption</figcaption></figure>", .{ file, file });
    }
};

test "observed Missing intake retains explicit mark and ruby siblings without granting annotation images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const file = try canonicalFile(a, &ns, "File:Absent.png");
    const occurrence: RawOccurrence = .{ .start = 0, .end = 1, .canonical_file = file, .missing_content = true };
    const figure = try ExplicitRubyObservationFixture.figure(a, file);
    const plain = try observedImages(a, &ns, figure, &.{occurrence});
    for ([_][]const u8{
        "<mark class=\"jouyou-reading\"><i>Reading</i></mark>",
        "<a href=\"/wiki/Article\"><ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp></ruby></a>",
        "<strong><ruby>base<rp>(</rp><rt><a href=\"/wiki/Reading\" title=\"Reading\">reading</a></rt><rp>)</rp></ruby></strong>",
        "<p><ruby>base<rp>(</rp><rt><a href=\"/w/index.php?title=Reading&amp;action=edit&amp;redlink=1\" class=\"new\">reading</a></rt><rp>)</rp></ruby></p>",
    }) |sibling| {
        const html = try std.mem.concat(a, u8, &.{ sibling, figure, sibling });
        const actual = try observedImages(a, &ns, html, &.{occurrence});
        try std.testing.expectEqualDeep(plain, actual);
        const missing = actual[0].missing_content.?;
        try std.testing.expectEqual(@as(u32, 0), actual[0].width);
        try std.testing.expectEqual(@as(u32, 100), missing.data_width);
        try std.testing.expect(!missing.paint_root_proven and missing.right and !missing.default_size);
        try std.testing.expectEqualStrings(file, missing.label);
        try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=Absent.png", missing.href);
    }
}

test "observed ruby grammar refuses implicit closures misplaced children image borrowing and duplicate file anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const file = try canonicalFile(a, &ns, "File:Absent.png");
    const occurrence: RawOccurrence = .{ .start = 0, .end = 1, .canonical_file = file, .missing_content = true };
    const figure = try ExplicitRubyObservationFixture.figure(a, file);
    for ([_][]const u8{
        "<rt>orphan</rt>", "<rp>orphan</rp>",
        "<ruby>base<rt>reading</rt></ruby>",
        "<ruby>base<rp>(<rt>reading</rt><rp>)</ruby>",
        "<ruby>base<rp>(</rp><rt>reading</rt></ruby>",
        "<ruby><rp>(</rp><rt>reading</rt><rp>)</rp></ruby>",
        "<ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp>extra</ruby>",
        "<ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp><rp>extra</rp></ruby>",
        "<ruby>base<!--comment--><rp>(</rp><rt>reading</rt><rp>)</rp></ruby>",
        "<ruby class=\"altered\">base<rp>(</rp><rt>reading</rt><rp>)</rp></ruby>",
        "<ruby>base<rp class=\"altered\">(</rp><rt>reading</rt><rp>)</rp></ruby>",
        "<ruby>base<rp>(</rp><rt><ruby>nested</ruby></rt><rp>)</rp></ruby>",
        "<ruby>base<rp><span>(</span></rp><rt>reading</rt><rp>)</rp></ruby>",
        "<ruby>base<rp>(</rp><rt><img src=\"x\"></rt><rp>)</rp></ruby>",
        "<ruby>base<rp>(</rp><rt><style>.x{display:none}</style></rt><rp>)</rp></ruby>",
        "<a href=\"/wiki/Outer\"><ruby>base<rp>(</rp><rt><a href=\"/wiki/Inner\">reading</a></rt><rp>)</rp></ruby></a>",
        "<table><ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp></ruby></table>",
        "<select><option>unrepresented insertion mode</option></select>",
        "<ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp>",
    }) |refused| {
        const html = try std.mem.concat(a, u8, &.{ refused, figure });
        try std.testing.expectError(invalid, observedImages(a, &ns, html, &.{occurrence}));
    }
    const duplicate_anchor = try std.mem.concat(a, u8, &.{ "<ruby>base<rp>(</rp><rt><a href=\"/wiki/File:Absent.png\">duplicate</a></rt><rp>)</rp></ruby>", figure });
    try std.testing.expectError(invalid, observedImages(a, &ns, duplicate_anchor, &.{occurrence}));
    const borrowed_image = try std.mem.concat(a, u8, &.{ "<ruby>base<rp>(</rp><rt>", figure, "</rt><rp>)</rp></ruby>" });
    try std.testing.expectError(invalid, observedImages(a, &ns, borrowed_image, &.{occurrence}));
    const double_figure = try std.mem.concat(a, u8, &.{ figure, figure });
    try std.testing.expectError(invalid, observedImages(a, &ns, double_figure, &.{occurrence}));
}
