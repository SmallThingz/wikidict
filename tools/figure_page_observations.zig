//! Optional build-only supplied-page observations. No source or HTML enters blobs.
const std = @import("std");
const diagnostics = @import("build_diagnostics");
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
    static_poster: bool = false,
    width: bool = false,
    height: bool = false,
    anchor_attributes: bool = false,
    svg_language: ?[]const u8 = null,
    // Actual raster language without an authored img_lang option.
    resolved_svg_language: ?[]const u8 = null,
};
pub const RawImageMapNoLink = struct { start: usize, end: usize };
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
    image_map_no_link: ?RawImageMapNoLink = null,
    text_class_scope: bool = false,
    outer_context: ?RawOuterContext = null,
    missing_served_set: ?MissingServedSet = null,
    // Complete emitted and page-authored styles, independently selected from media.
    page_styles: ?MissingServedSet = null,
    // Independent build-only source/observed-DOM relation proof.
    source_element_relations: ?bool = null,
};
const MissingServedSet = struct { responses: []const []const u8, receipt: []const u8 };
const MissingLinkStyles = struct {
    profile: []const u8,
    response: []const u8 = "",
    receipt: []const u8 = "",
    defaults: []const u8,
    served_set: ?MissingServedSet = null,
};
const StaticPosterStyles = struct {
    profile: []const u8,
    responses: [3][]const u8,
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
    static_poster_styles: ?StaticPosterStyles = null,
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
const SvgLanguageEvidence = struct { authored: bool = true, authored_width: ?u32 = null, language: []const u8, width: u32, height: u32, policy: encoder.presentation_types.FigureSizingPolicy };
const SvgUprightFitEvidence = struct { width: u32, height: u32 };
const Occurrence = struct {
    canonical_file: []const u8,
    original_options: []const u8,
    width: ?u32,
    height: ?HeightEvidence = null,
    svg_language: ?SvgLanguageEvidence = null,
    svg_upright_fit: ?SvgUprightFitEvidence = null,
    anchor: ?Inventory,
    centered_width: ?u32 = null,
    centered_default_size: bool = false,
    right_default_size: bool = false,
    missing_content: ?ObservedMissing = null,
    static_poster: ?encoder.presentation_types.StaticPoster = null,
};
const Page = struct {
    namespace_id: i32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
    raw_sha256: []const u8,
    source: []const u8,
    image_map_no_link: ?ImageMapError = null,
    source_siblings: []const profile.SourceSiblingProof = &.{},
    source_root_tables: []const profile.SourceRootTableProof = &.{},
    source_root_children: []const profile.SourceRootChildProof = &.{},
    source_root_parent_groups: []const profile.SourceRootParentProof = &.{},
    root_attributes: ?Inventory = null,
    occurrences: []const Occurrence,
    text_class_scope: ?profile.BoundedTextClassScope = null,
    page_styles: ?*const PageStyleData = null,
};
const SelectedOccurrence = struct { source: *const Occurrence, stage_options: []const u8, svg_upright_fit: bool = false };
pub const SelectedPage = struct {
    text_class_scope: ?profile.BoundedTextClassScope = null,
    // Exact caller-owned complete original expansion, populated only by select.
    text_class_scope_source: ?[]const u8 = null,
    namespace_catalog: *const namespaces.Registry,
    default_width: u32,
    page_title: []const u8 = "",
    occurrences: []const SelectedOccurrence,
    image_map_no_link: ?ImageMapError = null,
    missing_link_paint: ?encoder.presentation_types.MissingLinkPaint = null,
    pub fn imageMapNoLink(raw: ?*const anyopaque, a: A, body: []const u8, line: usize) A.Error!?[]const u8 {
        _ = a;
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const proof = self.image_map_no_link orelse return null;
        if (line != proof.line or body.ptr != proof.body.ptr or body.len != proof.body.len or !equal(body, proof.body)) return null;
        return proof.text;
    }
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
    pub fn svgLanguage(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, language: []const u8, width_px: ?u32, height_px: ?u32) A.Error!?encoder.presentation_types.FigureSizingPolicy {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        const proof = occurrence.svg_language orelse return null;
        if (!proof.authored or !equal(language, proof.language) or width_px != proof.width or height_px != null or
            (if (proof.authored_width) |authored| authored != proof.width else proof.width != self.default_width)) return null;
        return proof.policy;
    }
    pub fn observedSvgLanguage(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, width_px: ?u32, height_px: ?u32) A.Error!?compiler.ObservedSvgLanguage {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        const proof = occurrence.svg_language orelse return null;
        if (proof.authored or proof.authored_width != null or width_px != proof.width or height_px != null or proof.width != self.default_width) return null;
        return .{ .language = proof.language, .policy = proof.policy };
    }
    pub fn width(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, base_width: u32) A.Error!?u32 {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        if (base_width != self.default_width) return null;
        return if (try self.find(a, file, format_value, options)) |occurrence| occurrence.width else null;
    }
    pub fn svgUprightFit(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, width_px: ?u32, height_px: ?u32) A.Error!?encoder.presentation_types.FigureSizingPolicy {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        if (height_px != null) return null;
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        const proof = occurrence.svg_upright_fit orelse return null;
        if (width_px != proof.width or proof.width == 0 or proof.height == 0) return null;
        for (self.occurrences) |selected| if (selected.source == occurrence and selected.svg_upright_fit) return .requested_fit;
        return null;
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
    pub fn staticPoster(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8, width_value: ?u32, height_value: ?u32) A.Error!?encoder.presentation_types.StaticPoster {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        if (width_value != self.default_width or height_value != null) return null;
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        return occurrence.static_poster;
    }
    pub fn anchor(raw: ?*const anyopaque, a: A, file: []const u8, format_value: encoder.presentation_types.FigureFormat, options: []const u8) A.Error!?profile.AttributePresenceSource {
        const self: *const SelectedPage = @ptrCast(@alignCast(raw orelse return null));
        const occurrence = (try self.find(a, file, format_value, options)) orelse return null;
        if (occurrence.anchor) |*anchor_inventory| return .{ .ctx = anchor_inventory, .get = Inventory.presence };
        return null;
    }
};

const PageStyleData = struct {
    authored_sources: []const profile.Source,
    context_sources: []const profile.Source,
    page: RawPage,
    scope: profile.BoundedTextClassScope,
    outer: ObservedOuterContext,
    observed_nodes: []const ObservedSiblingNode = &.{},
    source_custom_elements: []const profile.SourceCustomElementProof = &.{},
};

pub const SelectedPageStyles = struct {
    styles: *const profile.Profile,
    scope: profile.BoundedTextClassScope,
    source: []const u8,
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
        const shape = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
        const doc = try std.json.parseFromValueLeaky(Document, a, shape, .{});
        // v7 composes independent Missing and SVG-language proofs. It does not
        // manufacture a page context or authorize general stylesheets.
        // V9 composes existing independent proofs; it grants no v8-only source
        // operation or image-map authority and cannot merely relabel a v5 Book.
        const poster_svg_contract = equal(doc.schema, "wikidict.figure-page-observations.v9");
        const image_map_contract = equal(doc.schema, "wikidict.figure-page-observations.v8");
        const combined_contract = image_map_contract or poster_svg_contract or equal(doc.schema, "wikidict.figure-page-observations.v7");
        const svg_language_contract = combined_contract or equal(doc.schema, "wikidict.figure-page-observations.v6");
        const paint_contract = equal(doc.schema, "wikidict.figure-page-observations.v3");
        const poster_contract = poster_svg_contract or equal(doc.schema, "wikidict.figure-page-observations.v5");
        const page_style_contract = combined_contract;
        const class_contract = combined_contract or poster_contract or equal(doc.schema, "wikidict.figure-page-observations.v4");
        const class_scope_contract = class_contract or svg_language_contract;
        const missing_contract = class_contract or paint_contract or equal(doc.schema, "wikidict.figure-page-observations.v2");
        if ((!equal(doc.schema, "wikidict.figure-page-observations.v1") and !missing_contract and !svg_language_contract) or !equal(doc.wiki, ns.wiki) or !equal(doc.date, ns.dump_date) or
            !hashEqual(ns.source_sha256, doc.namespace_sha256) or !hashEqual(defaults_sha256, doc.defaults_sha256) or
            doc.pages.len == 0 or doc.pages.len > max_pages) return invalid;
        const served: ?ValidatedMissingSet = if (doc.missing_link_styles) |styles| selected: {
            const observed_set = equal(styles.profile, missing_observed_set_profile);
            try missingStyleShape(shape, observed_set);
            if (observed_set) {
                if (!combined_contract and !equal(doc.schema, "wikidict.figure-page-observations.v4")) return invalid;
                break :selected try missingObservedSet(a, styles, doc.wiki, defaults_sha256);
            }
            break :selected null;
        } else null;
        const link_paint: ?encoder.presentation_types.MissingLinkPaint = if (served != null) .vector_new_link_v1 else if (paint_contract)
            try missingLinkPaint(a, doc.missing_link_styles orelse return invalid, doc.wiki, defaults_sha256)
        else if (class_contract) optional: {
            break :optional if (doc.missing_link_styles) |styles| try missingLinkPaint(a, styles, doc.wiki, defaults_sha256) else null;
        } else legacy: {
            if (doc.missing_link_styles != null) return invalid;
            break :legacy null;
        };
        if (poster_contract) {
            try staticPosterStyles(a, doc.static_poster_styles orelse return invalid, doc.wiki, defaults_sha256);
        } else if (doc.static_poster_styles != null) return invalid;
        const pages = try a.alloc(Page, doc.pages.len);
        for (doc.pages, pages, 0..) |page, *out, index| {
            const has_image_map_error = image_map_contract and page.image_map_no_link != null;
            if (page.image_map_no_link != null and !image_map_contract) return invalid;
            const has_page_styles = page_style_contract and page.page_styles != null;
            if (page.text_class_scope and !class_scope_contract) return invalid;
            if (page_style_contract and page.page_styles != null and (!page.text_class_scope or page.outer_context == null)) return invalid;
            const page_shape = (try field(shape, "pages")).array.items[index];
            if (page_shape.object.get("source_element_relations")) |relation_flag| {
                if (!equal(doc.schema, "wikidict.figure-page-observations.v4") or relation_flag != .bool) return invalid;
            }
            const relations = page.source_element_relations orelse false;
            if (page.outer_context != null and (!class_scope_contract or !page.text_class_scope)) return invalid;
            if (page.page_id == 0 or page.revision_id == 0 or page.title.len == 0 or !lowerHex(page.raw_sha256, 64) or
                (page.occurrences.len == 0 and !(page_style_contract and page.page_styles != null) and !has_image_map_error) or page.occurrences.len > max_occurrences) return invalid;
            _ = ns.storedPageSpec(page.title, page.namespace_id) catch return invalid;
            for (pages[0..index]) |old| if (old.page_id == page.page_id or
                (old.namespace_id == page.namespace_id and equal(old.title, page.title))) return invalid;
            const source_and_html = try responseSource(a, ns, page);
            const image_map_error = if (page.image_map_no_link) |value|
                try observedImageMapNoLink(a, ns, registry, source_and_html.source, source_and_html.html, value) else null;
            if (page_style_contract and !poster_svg_contract) for (page.occurrences) |occurrence| {
                if (occurrence.static_poster) return invalid;
            };
            var has_poster = false;
            for (page.occurrences) |occurrence| if (occurrence.static_poster) { has_poster = true; };
            if (has_poster) {
                if (!poster_contract or !page.text_class_scope or page.namespace_id != 0) return invalid;
                try staticPosterPageContext(a, ns, page, source_and_html.html);
            }
            var observed_nodes: std.ArrayList(ObservedSiblingNode) = .empty;
            var text_scope: ?profile.BoundedTextClassScope = if (page.text_class_scope or relations)
                try observedTextClassScopeWithElements(a, ns, source_and_html.html, if (relations or page.outer_context != null or has_page_styles) &observed_nodes else null) else null;
            const source_siblings = if (relations)
                try observedSourceSiblings(a, source_and_html.source, source_and_html.html, observed_nodes.items) else &.{};
            const source_root_tables = if (page.outer_context != null)
                try observedSourceRootTables(a, ns, source_and_html.source, source_and_html.html, observed_nodes.items) else &.{};
            const source_root_children = if (has_page_styles)
                try observedSourceRootChildren(a, source_and_html.source, source_and_html.html, observed_nodes.items) else &.{};
            const source_root_parent_groups = if (has_page_styles)
                try observedCommonRootParents(a, source_and_html.source, source_and_html.html, observed_nodes.items) else &.{};
            var paint_outer: ?ObservedOuterContext = null;
            if (page.outer_context) |outer| {
                if (text_scope) |*scope| {
                    const context = try observedOuterContext(a, ns, page, outer, scope.*);
                    scope.complete_ancestor_class_superset = try completeObservedTextClassSuperset(a, scope.*, context.classes, source_and_html.source);
                    paint_outer = context;
                } else return invalid;
            }
            const page_styles = try observedPageStyleProfile(a, ns, doc.schema, page,
                (try field(shape, "pages")).array.items[index], source_and_html.html, text_scope, paint_outer);
            if (page_styles) |selected_styles| {
                selected_styles.observed_nodes = observed_nodes.items;
                selected_styles.source_custom_elements = try observedSourceCustomElements(a, source_and_html.source, source_and_html.html, observed_nodes.items);
            }
            const selected_served = try pageMissingServedSet(a, doc, page, (try field(shape, "pages")).array.items[index], defaults_sha256, served);
            var served_profile: ?profile.Profile = if (selected_served) |selected|
                if (paint_outer != null) try missingServedProfile(a, ns, page, selected) else null
            else null;
            defer if (served_profile) |*styles| styles.deinit();
            // Outer ancestry alone does not authorize embedded-style paint.
            const observed_images: []const ObservedImage = if (page.occurrences.len == 0 and has_image_map_error) &.{} else try observedImagesWithServedPaint(a, ns, source_and_html.html, page.occurrences,
                if (selected_served != null) paint_outer else null,
                if (served_profile) |*styles| styles else null, selected_served != null);
            const occurrences = try a.alloc(Occurrence, page.occurrences.len);
            for (page.occurrences, occurrences, 0..) |occurrence, *selected, occurrence_index| {
                if (occurrence.start >= occurrence.end or occurrence.end > source_and_html.source.len) return invalid;
                if (occurrence.svg_language != null and occurrence.resolved_svg_language != null) return invalid;
                if (occurrence.svg_language orelse occurrence.resolved_svg_language) |language| {
                    if (!svg_language_contract or !compiler.validSvgRasterLanguage(language) or
                        (occurrence.width and (!poster_svg_contract or occurrence.svg_language == null)) or occurrence.height or
                        occurrence.anchor_attributes or occurrence.missing_content or occurrence.static_poster) return invalid;
                }
                if (occurrence.missing_content) {
                    if (!missing_contract or occurrence.static_poster or occurrence.width or occurrence.height or occurrence.anchor_attributes or occurrence.file_sha1.len != 0 or
                        occurrence.file_timestamp.len != 0 or occurrence.original_width != 0 or occurrence.original_height != 0 or
                        !try sizing.Registry.isMissingFile(registry, a, occurrence.canonical_file)) return invalid;
                } else if ((!occurrence.width and !occurrence.height and !occurrence.anchor_attributes and !occurrence.static_poster and occurrence.svg_language == null and occurrence.resolved_svg_language == null) or
                    (occurrence.height and (occurrence.width or occurrence.anchor_attributes or occurrence.static_poster)) or !lowerHex(occurrence.file_sha1, 40) or
                    occurrence.file_timestamp.len == 0 or occurrence.original_width == 0 or occurrence.original_height == 0) return invalid;
                for (page.occurrences[0..occurrence_index]) |old| if (equal(old.canonical_file, occurrence.canonical_file) or
                    (old.start < occurrence.end and occurrence.start < old.end)) return invalid;
                const canonical = try canonicalFile(a, ns, occurrence.canonical_file);
                if (!equal(canonical, occurrence.canonical_file)) return invalid;
                if (occurrence.static_poster and (!poster_contract or occurrence.width or occurrence.anchor_attributes or occurrence.missing_content)) return invalid;
                var poster: ?encoder.presentation_types.StaticPoster = null;
                var eligible_svg = false;
                var fact_found = false;
                if (occurrence.static_poster) {
                    const fact = registry.static_poster_files.get(canonical) orelse return invalid;
                    if (!equal(fact.file_sha1, occurrence.file_sha1) or !equal(fact.file_timestamp, occurrence.file_timestamp) or
                        fact.original_width != occurrence.original_width or fact.original_height != occurrence.original_height) return invalid;
                    const image = observed_images[occurrence_index];
                    if (image.width != default_width) return invalid;
                    const proof = (try sizing.Registry.resolveStaticPoster(registry, a, canonical, .thumbnail, image.width, null)) orelse return invalid;
                    if (!equal(proof.label, image.poster_label orelse return invalid)) return invalid;
                    poster = .{ .policy = proof.policy, .label = try a.dupe(u8, proof.label),
                        .file_sha1 = try a.dupe(u8, proof.file_sha1), .file_timestamp = try a.dupe(u8, proof.file_timestamp) };
                    fact_found = true;
                } else for (registry.records, 0..) |fact, fact_index| if (equal(fact.canonical_file, canonical)) {
                    if (!equal(fact.file_sha1, occurrence.file_sha1) or !equal(fact.file_timestamp, occurrence.file_timestamp) or
                        fact.original_width != occurrence.original_width or fact.original_height != occurrence.original_height) return invalid;
                    if (occurrence.height and (fact_index >= registry.height_bound_records.len or
                        registry.height_bound_records[fact_index] != .svg_redundant_height or
                        fact.format != .thumbnail or fact.sizing != .requested_fit)) return invalid;
                    eligible_svg = fact_index < registry.height_bound_records.len and
                        registry.height_bound_records[fact_index] == .svg_redundant_height and
                        fact.format == .thumbnail and fact.sizing == .requested_fit;
                    fact_found = true;
                    break;
                };
                if (fact_found == occurrence.missing_content) return invalid;
                const options = try originalOptions(a, ns, source_and_html.source, occurrence);
                const image = observed_images[occurrence_index];
                const svg_upright_fit: ?SvgUprightFitEvidence = if (eligible_svg and occurrence.width and
                    !occurrence.anchor_attributes and image.width > occurrence.original_width) proof: {
                    if (image.centered or image.svg_language != null or
                        !svgUprightObservedFit(image.width, image.height, occurrence.original_width, occurrence.original_height)) break :proof null;
                    const element = image.element orelse break :proof null;
                    if (!equal(element.get("class") orelse "", "mw-file-element mw-file-upright") or element.get("style") == null) break :proof null;
                    // Keep prior width-only intake unchanged. Missing fit proof
                    // leaves the new sizing callback unavailable.
                    svgRasterSource(a, ns, element.get("src") orelse break :proof null, canonical, null) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :proof null,
                    };
                    if (element.get("srcset")) |srcset| svgRasterSourceSet(a, ns, srcset, canonical, null) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :proof null,
                    };
                    break :proof .{ .width = image.width, .height = image.height };
                } else null;
                if (image.right_default_size and image.width > occurrence.original_width and svg_upright_fit == null) return invalid;
                const svg_language: ?SvgLanguageEvidence = if (occurrence.svg_language orelse occurrence.resolved_svg_language) |language| proof: {
                    // Actual raster and language-key evidence was checked in the
                    // complete HTML observer. File models alone never grant it.
                    const authored_width: ?u32 = if (occurrence.width) svgLanguageAuthoredWidth(options) orelse return invalid else null;
                    if (!equal(image.svg_language orelse return invalid, language) or image.width != (authored_width orelse default_width) or
                        !svgObservedWidthFit(image.width, image.height, occurrence.original_width, occurrence.original_height)) return invalid;
                    const policy = (try sizing.Registry.resolveSvgLanguageModel(registry, a, canonical, language, .thumbnail, image.width, null)) orelse return invalid;
                    break :proof .{ .authored = occurrence.svg_language != null, .authored_width = authored_width,
                        .language = try a.dupe(u8, language), .width = image.width, .height = image.height, .policy = policy };
                } else null;
                selected.* = .{ .canonical_file = canonical, .original_options = options, .svg_language = svg_language, .svg_upright_fit = svg_upright_fit,
                    .width = if (occurrence.width and svg_language == null) image.width else null,
                    .height = if (occurrence.height) .{ .requested_height = image.height,
                        .original_width = occurrence.original_width, .observed_width = image.width } else null,
                    .anchor = if (occurrence.anchor_attributes or occurrence.missing_content or occurrence.static_poster) image.anchor else null,
                    .centered_width = if (image.centered) image.width else null,
                    .centered_default_size = image.centered_default_size, .right_default_size = image.right_default_size,
                    .missing_content = image.missing_content, .static_poster = poster };
            }
            out.* = .{ .namespace_id = page.namespace_id, .page_id = page.page_id, .revision_id = page.revision_id, .title = page.title,
                .raw_sha256 = page.raw_sha256, .source = source_and_html.source, .image_map_no_link = image_map_error, .occurrences = occurrences, .text_class_scope = text_scope, .source_siblings = source_siblings, .source_root_tables = source_root_tables, .page_styles = page_styles, .source_root_children = source_root_children, .source_root_parent_groups = source_root_parent_groups,
                .root_attributes = if (has_page_styles and observed_nodes.items.len != 0) observed_nodes.items[0].attributes else null };
        }
        if (poster_svg_contract) {
            var proved_poster = false; var proved_svg_language = false;
            for (pages) |page| for (page.occurrences) |occurrence| {
                proved_poster = proved_poster or occurrence.static_poster != null;
                proved_svg_language = proved_svg_language or occurrence.svg_language != null;
            };
            if (!proved_poster or !proved_svg_language) return invalid;
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
    // This selector issues no media callback or geometry policy. A zero-media
    // page can contribute only its independently authenticated source/style scope.
    pub fn selectPageStyles(self: *const Book, a: A, ns: *const namespaces.Registry, namespace_id: i32,
        page_id: u64, revision_id: u64, title: []const u8, raw: []const u8, expanded: []const u8,
        defaults_sha256: [32]u8, parent: *const profile.Profile) !?*const SelectedPageStyles
    {
        if (!std.mem.eql(u8, &self.namespace_sha256, &ns.source_sha256) or
            !std.mem.eql(u8, &self.defaults_sha256, &defaults_sha256) or
            parent.page_style_parent != null or parent.reading_target != .screen) return null;
        for (self.pages) |page| {
            if (page.page_id != page_id or page.namespace_id != namespace_id or page.revision_id != revision_id or !equal(page.title, title)) continue;
            if (!digestMatches(raw, page.raw_sha256) or !equal(expanded, page.source)) return null;
            const stored = page.page_styles orelse return null;
            var scope = page.text_class_scope orelse return invalid;
            const styles = try a.create(profile.Profile);
            styles.* = try profile.joinPageSourcesAlloc(a, parent, stored.context_sources, stored.authored_sources);
            errdefer styles.deinit();
            // Preserve the ordinary global custom-property source order, adding
            // complete page-authored sheets last. No title-wide environment is borrowed.
            var context_sources: std.ArrayList(profile.Source) = .empty;
            defer context_sources.deinit(a);
            try context_sources.appendSlice(a, stored.context_sources);
            try context_sources.appendSlice(a, parent.retained_sources);
            try context_sources.appendSlice(a, stored.authored_sources);
            try attachObservedPageCustomProperties(a, styles, ns, stored.page, stored.scope, stored.outer, context_sources.items);
            const response = try json(a, stored.page.response);
            const supplied = try observedOuterPrefix(a, try string(try field(response, "parse"), "headhtml"), false);
            const ancestors = try a.alloc(profile.TextElement, stored.outer.ancestors.len);
            for (ancestors, 0..) |*node, index| {
                // HTML/BODY belong to this exact supplied source; the middle
                // chain is the separately validated same-page insertion proof.
                const observed = if (index < 2) supplied.ancestors[index] else stored.outer.ancestors[index];
                node.* = .{ .tag = observed.tag, .classes = observed.attributes.get("class") orelse "",
                    .id = observed.attributes.get("id") orelse "", .language = observed.attributes.get("lang"),
                    .parent = if (index == 0) null else &ancestors[index - 1],
                    .ancestry_complete = false, .physical_ancestry_complete = false };
            }
            const root = try a.create(profile.TextElement);
            root.* = .{ .tag = scope.root_tag, .classes = scope.root_classes,
                .language = ns.content_language, .parent = &ancestors[ancestors.len - 1],
                .ancestry_complete = false, .physical_ancestry_complete = false };
            // This second path is never lent to an arbitrary descendant. Its
            // exact edges are consumed only with a unique complete source anchor.
            const complete = try a.alloc(profile.TextElement, ancestors.len + 1);
            for (complete, 0..) |*node, index| {
                const attributes = if (index == ancestors.len) page.root_attributes orelse return invalid
                    else if (index < 2) supplied.ancestors[index].attributes else stored.outer.ancestors[index].attributes;
                const inventory_ptr = try a.create(Inventory); inventory_ptr.* = attributes;
                node.* = .{ .tag = if (index == ancestors.len) scope.root_tag else ancestors[index].tag,
                    .classes = attributes.get("class") orelse "", .id = attributes.get("id") orelse "",
                    .language = attributes.get("lang"), .parent = if (index == 0) null else &complete[index - 1],
                    .attribute_presence = .{ .ctx = inventory_ptr, .get = Inventory.presence },
                    .observed_inline_style = attributes.get("style") orelse "",
                    .ancestry_complete = true, .physical_ancestry_complete = true };
            }
            const complete_root = &complete[complete.len - 1];
            for (complete) |*node| node.page_style_root = complete_root;
            // The source insertion contract retains API and full-GET HTML TOC
            // states separately. Ordinary selectors must consider both, just as
            // the existing custom-property environment already does.
            const alternative = try a.alloc(profile.TextElement, complete.len);
            const alternative_root = &alternative[alternative.len - 1];
            for (alternative, 0..) |*node, index| {
                node.* = complete[index];
                node.parent = if (index == 0) null else &alternative[index - 1];
                node.page_style_root = alternative_root;
                if (index == 0) {
                    const attributes = stored.outer.ancestors[0].attributes;
                    const inventory_ptr = try a.create(Inventory); inventory_ptr.* = attributes;
                    node.classes = attributes.get("class") orelse ""; node.id = attributes.get("id") orelse "";
                    node.language = attributes.get("lang");
                    node.attribute_presence = .{ .ctx = inventory_ptr, .get = Inventory.presence };
                    node.observed_inline_style = attributes.get("style") orelse "";
                }
                complete[index].alternative_ancestry = node;
            }
            try retainObservedNodeCustomEnvironments(a, styles, complete, alternative);
            if (styles.custom_properties) |custom| {
                scope.page_custom_invariant = try observedPageCustomInvariant(a, custom, stored.observed_nodes,
                    complete_root.observed_custom_environment orelse return invalid,
                    alternative_root.observed_custom_environment orelse return invalid);
            }
            scope.source_custom_elements = stored.source_custom_elements;
            scope.source_custom_elements_source = expanded;
            scope.page_style_complete_root = complete_root;
            scope.source_root_children = page.source_root_children;
            scope.source_root_parent_groups = page.source_root_parent_groups;
            scope.source_root_children_source = expanded;
            // Preserve the independently issued root-table relation when this
            // page's style scope replaces its media scope in the ordinary loader.
            if (page.source_root_tables.len != 0) {
                scope.source_root_tables = page.source_root_tables;
                scope.source_root_tables_source = expanded;
            }
            scope.page_styles = styles;
            scope.page_style_root = root;
            const result = try a.create(SelectedPageStyles);
            result.* = .{ .styles = styles, .scope = scope, .source = expanded };
            return result;
        }
        return null;
    }
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
            if (!digestMatches(raw, page.raw_sha256) or !equal(expanded, page.source) or (page.occurrences.len == 0 and page.image_map_no_link == null)) return null;
            const selected = try a.alloc(SelectedOccurrence, page.occurrences.len);
            for (page.occurrences, selected) |*occurrence, *slot| {
                slot.* = .{ .source = occurrence, .stage_options = try compiler.figureObservationStageOptionsAlloc(a, occurrence.original_options, context) };
                const right_default_source = occurrence.right_default_size and
                    rightUprightDefaultOptions(context.image_options.?, occurrence.original_options) and
                    rightUprightDefaultOptions(context.image_options.?, slot.stage_options);
                if (occurrence.right_default_size and !right_default_source) return null;
                slot.svg_upright_fit = occurrence.svg_upright_fit != null and
                    ((bareUprightThumbnailOptions(context.image_options.?, occurrence.original_options) and
                    bareUprightThumbnailOptions(context.image_options.?, slot.stage_options)) or right_default_source);
                if (occurrence.svg_language) |proof| {
                    if (!svgLanguageThumbnailOptionsWithWidth(context.image_options.?, occurrence.original_options,
                            if (proof.authored) proof.language else null, proof.authored_width) or
                        !svgLanguageThumbnailOptionsWithWidth(context.image_options.?, slot.stage_options,
                            if (proof.authored) proof.language else null, proof.authored_width)) return null;
                }
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
                if (occurrence.static_poster != null and
                    (!missingThumbnailOptions(context.image_options.?, occurrence.original_options) or
                        !missingThumbnailOptions(context.image_options.?, slot.stage_options))) return null;
                if (occurrence.missing_content) |missing| if (
                    !missingThumbnailOptionsForObservation(context.image_options.?, occurrence.original_options, missing) or
                    !missingThumbnailOptionsForObservation(context.image_options.?, slot.stage_options, missing)) return null;
            }
            const result = try a.create(SelectedPage);
            result.* = .{ .namespace_catalog = ns, .default_width = default_width, .page_title = title, .occurrences = selected, .image_map_no_link = if (page.image_map_no_link) |proof| .{ .body = expanded[proof.body_start..][0..proof.body.len], .body_start = proof.body_start, .line = proof.line, .text = proof.text } else null, .missing_link_paint = self.missing_link_paint,
                .text_class_scope = page.text_class_scope, .text_class_scope_source = if (page.text_class_scope != null) expanded else null };
            if (result.text_class_scope) |*scope| if (page.source_siblings.len != 0) {
                scope.source_siblings = page.source_siblings;
                scope.source_siblings_source = expanded;
            };
            if (result.text_class_scope) |*scope| if (page.source_root_tables.len != 0) {
                scope.source_root_tables = page.source_root_tables;
                scope.source_root_tables_source = expanded;
            };
            return result;
        }
        return null;
    }
};

// Only the exact default thumbnail and explicit raster language are covered.
// Other recognized options keep their existing independent observation routes.
fn svgLanguageThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8, language: []const u8) bool {
    return svgLanguageThumbnailOptionsForOrigin(registry, options, language);
}
fn bareUprightThumbnailOptions(registry: *const namespaces.image_options.Registry, options: []const u8) bool {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at <= options.len) {
        if (count == parts.len) return false;
        const end = syntax.delimiter(options, "|", at) orelse options.len;
        parts[count] = std.mem.trim(u8, options[at..end], " \t\r\n"); count += 1;
        if (end == options.len) break;
        at = end + 1;
    }
    if (count != 3 or parts[2].len == 0 or registry.match(parts[2], .svg) != null) return false;
    const format = registry.match(parts[0], .svg) orelse return false;
    const upright = registry.match(parts[1], .svg) orelse return false;
    return equal(format.id, "img_thumbnail") and format.value == null and
        equal(upright.id, "img_upright") and upright.value == null;
}
// Stage only the exact observed right/default/upright shape at intake. The
// actual captured option registry proves both original and prepared source;
// no CSS factor, default width calculation or right-class authority is used.
fn rightUprightDefaultOptions(registry: *const namespaces.image_options.Registry, options: []const u8) bool {
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
    if (count != 4 or parts[3].len == 0 or registry.match(parts[3], .image) != null) return false;
    var thumbnail = false; var right = false; var upright = false;
    for (parts[0..3]) |part| {
        const option = registry.match(part, .image) orelse return false;
        if (option.value != null) return false;
        if (equal(option.id, "img_thumbnail")) { if (thumbnail) return false; thumbnail = true; }
        else if (equal(option.id, "img_right")) { if (right) return false; right = true; }
        else if (equal(option.id, "img_upright")) { if (upright) return false; upright = true; }
        else return false;
    }
    return thumbnail and right and upright;
}
// The actual selected raster supplies the width. Verify its positive logical
// height with the same half-up aspect fit, without granting any other width.
fn svgUprightObservedFit(width: u32, height: u32, original_width: u32, original_height: u32) bool {
    if (original_width == 0 or original_height == 0 or width <= original_width or height == 0) return false;
    const product = @as(u64, original_height) * width;
    return product / original_width + @intFromBool(product % original_width >= (@as(u64, original_width) + 1) / 2) == height;
}
fn svgLanguageWidthValue(value: []const u8) ?u32 {
    if (value.len == 0 or value.len > 10) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    const width = std.fmt.parseInt(u32, value, 10) catch return null;
    return if (width > 0) width else null;
}
// Intake proves the literal numeric width; selection independently resolves the
// same complete options through the actual captured image-option registry.
fn svgLanguageAuthoredWidth(options: []const u8) ?u32 {
    var width: ?u32 = null; var at: usize = 0;
    while (at <= options.len) {
        const end = syntax.delimiter(options, "|", at) orelse options.len;
        const part = std.mem.trim(u8, options[at..end], " \t\r\n");
        if (part.len >= 2 and std.ascii.eqlIgnoreCase(part[part.len - 2 ..], "px")) {
            if (svgLanguageWidthValue(part[0 .. part.len - 2])) |parsed| {
                if (width != null) return null;
                width = parsed;
            }
        }
        if (end == options.len) break;
        at = end + 1;
    }
    return width;
}
fn svgLanguageThumbnailOptionsForOrigin(registry: *const namespaces.image_options.Registry, options: []const u8, language: ?[]const u8) bool {
    return svgLanguageThumbnailOptionsWithWidth(registry, options, language, null);
}
fn svgLanguageThumbnailOptionsWithWidth(registry: *const namespaces.image_options.Registry, options: []const u8,
    language: ?[]const u8, authored_width: ?u32) bool {
    if (authored_width != null and language == null) return false;
    var thumbnail = false; var language_seen = false; var caption = false; var width_seen = false;
    var at: usize = 0;
    while (at <= options.len) {
        const end = syntax.delimiter(options, "|", at) orelse options.len;
        const part = std.mem.trim(u8, options[at..end], " \t\r\n");
        if (registry.match(part, .svg)) |option| {
            if (equal(option.id, "img_thumbnail")) {
                if (thumbnail or option.value != null) return false;
                thumbnail = true;
            } else if (equal(option.id, "img_lang")) {
                if (language_seen or !std.ascii.eqlIgnoreCase(option.value orelse return false, language orelse return false)) return false;
                language_seen = true;
            } else if (equal(option.id, "img_width")) {
                if (width_seen or svgLanguageWidthValue(option.value orelse return false) != (authored_width orelse return false)) return false;
                width_seen = true;
            } else return false;
        } else {
            if (caption) return false;
            caption = true;
        }
        if (end == options.len) break;
        at = end + 1;
    }
    return thumbnail and language_seen == (language != null) and width_seen == (authored_width != null);
}
fn svgObservedWidthFit(width: u32, height: u32, original_width: u32, original_height: u32) bool {
    if (width == 0 or height == 0 or original_width == 0 or original_height == 0 or width > original_width) return false;
    const product = @as(u64, original_height) * width;
    return product / original_width + @intFromBool(product % original_width >= (@as(u64, original_width) + 1) / 2) == height;
}
// Invert only the actual named PNG transform form from pinned f458
// File.generateThumbName + SvgHandler.makeParamString/getThumbType. The key's
// physical width is validated but never used as logical geometry or a default.
fn svgLanguageRasterSource(a: A, ns: *const namespaces.Registry, raw: []const u8, file: []const u8, language: []const u8) !void {
    return svgRasterSource(a, ns, raw, file, language);
}
fn svgRasterSource(a: A, ns: *const namespaces.Registry, raw: []const u8, file: []const u8, language: ?[]const u8) !void {
    if (language) |value| if (!compiler.validSvgRasterLanguage(value)) return invalid;
    if (std.mem.indexOfScalar(u8, raw, '#') != null) return invalid;
    try imageSource(a, ns, raw, file);
    const end = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    if (end != raw.len) {
        // The actual source-bound response appends only this analytics tail.
        // Reject all other query keys, duplicates, encodings and ordering.
        const wiki_suffix = "wiktionary";
        if (!std.mem.endsWith(u8, ns.wiki, wiki_suffix) or ns.wiki.len == wiki_suffix.len) return invalid;
        const site = ns.wiki[0 .. ns.wiki.len - wiki_suffix.len];
        for (site) |byte| if (!std.ascii.isLower(byte) and byte != '-') return invalid;
        const expected = try std.fmt.allocPrint(a, "utm_source={s}.wiktionary.org&utm_campaign=parser&utm_content=thumbnail", .{site});
        if (!equal(raw[end + 1 ..], expected)) return invalid;
    }
    const path = raw[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return invalid;
    const storage = try a.dupe(u8, path[slash + 1 ..]);
    const name = std.Uri.percentDecodeInPlace(storage);
    std.mem.replaceScalar(u8, name, '_', ' ');
    const prefix = if (language) |value| try std.fmt.allocPrint(a, "lang{s}-", .{value}) else "";
    if (!std.mem.startsWith(u8, name, prefix)) return invalid;
    const dimension_end = std.mem.indexOfPos(u8, name, prefix.len, "px-") orelse return invalid;
    const digits = name[prefix.len..dimension_end];
    if (digits.len == 0 or digits[0] == '0') return invalid;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return invalid;
    if ((std.fmt.parseInt(u32, digits, 10) catch return invalid) == 0) return invalid;
    const suffix = try std.fmt.allocPrint(a, "{s}.png", .{ns.ofTitle(file).text});
    if (!equal(name[dimension_end + 3 ..], suffix)) return invalid;
}
fn svgLanguageRasterSourceSet(a: A, ns: *const namespaces.Registry, raw: []const u8, file: []const u8, language: []const u8) !void {
    return svgRasterSourceSet(a, ns, raw, file, language);
}
fn svgRasterSourceSet(a: A, ns: *const namespaces.Registry, raw: []const u8, file: []const u8, language: ?[]const u8) !void {
    var candidates = std.mem.splitScalar(u8, raw, ',');
    var previous: f64 = 0;
    while (candidates.next()) |candidate| {
        const item = std.mem.trim(u8, candidate, " \t");
        const split = std.mem.lastIndexOfScalar(u8, item, ' ') orelse return invalid;
        const density = std.mem.trim(u8, item[split + 1 ..], " \t");
        if (density.len < 2 or density[density.len - 1] != 'x') return invalid;
        const density_number = density[0 .. density.len - 1];
        for (density_number) |byte| if (!std.ascii.isDigit(byte) and byte != '.') return invalid;
        const value = std.fmt.parseFloat(f64, density_number) catch return invalid;
        if (!std.math.isFinite(value) or value <= previous) return invalid;
        previous = value;
        try svgRasterSource(a, ns, std.mem.trim(u8, item[0..split], " \t"), file, language);
    }
}

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

const static_poster_urls = [_][]const u8{
    "https://it.wiktionary.org/w/load.php?lang=it&modules=ext.3d.styles%7Cext.wikimediamessages.styles%7Cskins.vector.icons%2Cstyles%7Cskins.vector.search.codex.styles&only=styles&skin=vector-2022",
    "https://it.wiktionary.org/w/load.php?lang=it&modules=ext.gadget.IndiceOrizzontale&only=styles&skin=vector-2022",
    "https://it.wiktionary.org/w/load.php?lang=it&modules=site.styles&only=styles&skin=vector-2022",
};
const static_poster_root_classes = "client-nojs vector-feature-language-in-header-enabled vector-feature-language-in-main-menu-disabled vector-feature-language-in-main-page-header-disabled vector-feature-page-tools-pinned-disabled vector-feature-toc-pinned-clientpref-1 vector-feature-main-menu-pinned-disabled vector-feature-limited-width-clientpref-1 vector-feature-limited-width-content-enabled vector-feature-custom-font-size-clientpref-1 vector-feature-appearance-pinned-clientpref-1 skin-theme-clientpref-day vector-sticky-header-enabled skin-thumbsize-clientpref-standard skin-underline-clientpref-browser";
const static_poster_css_sha256 = [_][]const u8{
    "20ecb909844c67ed3118d8c4c2b92355b53dee8e8bc0a9f5dbddc42a3ef10d0d",
    "6a78d97e623212d1460468bf6f5c19268ec86b3e1d47c0511eadd4a061881f9a",
    "da9678cb2aa52dd820774f001fdc1f5a0de05b1c84d196776e3f9d3c95650e38",
};

fn staticPosterStyles(a: A, styles: StaticPosterStyles, wiki: []const u8, defaults_sha256: [32]u8) !void {
    if (!equal(wiki, "itwiktionary") or !equal(styles.profile, "vector_3d_stl_it_v1")) return invalid;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(styles.defaults, &actual, .{});
    if (!std.mem.eql(u8, &actual, &defaults_sha256)) return invalid;
    const defaults = try json(a, styles.defaults);
    const options = try field(try field(defaults, "query"), "defaultoptions");
    if (!equal(try string(defaults, "wiki"), wiki) or !equal(try string(options, "skin"), "vector-2022") or
        !equal(try string(options, "language"), "it") or !equal(try string(options, "vector-theme"), "day")) return invalid;
    const receipt = try json(a, styles.receipt);
    if (receipt != .object or receipt.object.count() != 2 or try field(receipt, "core") != .null) return invalid;
    const sources = try field(receipt, "sources");
    if (sources != .array or sources.array.items.len != 3) return invalid;
    for (styles.responses, sources.array.items, static_poster_urls, static_poster_css_sha256, 0..) |response, source, url, expected, index| {
        if (!digestMatches(response, expected)) return invalid;
        try descriptor(response, source);
        const path = try std.fmt.allocPrint(a, "served:it-stl-head-stylesheet-{d}:it:vector-2022", .{index + 1});
        if (try number(source, "status") != 200 or !equal(try string(source, "url"), url) or
            !equal(try string(source, "final_url"), url) or !equal(try string(source, "source_path"), path)) return invalid;
        const content_type = try string(try field(source, "headers"), "content-type");
        const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
        if (!equal(std.mem.trim(u8, content_type[0..end], " \t"), "text/css")) return invalid;
    }
}
fn staticPosterHeadContext(a: A, head: []const u8, content_language: []const u8) !void {
    const observed = try observedOuterPrefix(a, head, false);
    if (!equal(content_language, "it") or observed.ancestors.len != 2) return invalid;
    const root = observed.ancestors[0].attributes;
    const body = observed.ancestors[1].attributes;
    if (root.attributes.len != 3 or !equal(root.get("class") orelse "", static_poster_root_classes) or
        !equal(root.get("lang") orelse "", content_language) or !equal(root.get("dir") orelse "", "ltr") or body.attributes.len != 1) return invalid;
    var classes = std.mem.tokenizeAny(u8, body.get("class") orelse return invalid, " \t\r\n\x0c");
    var fixed: std.ArrayList(u8) = .empty;
    var page: usize = 0; var rootpage: usize = 0;
    while (classes.next()) |name| {
        if (std.mem.startsWith(u8, name, "page-") and name.len > 5) { page += 1; continue; }
        if (std.mem.startsWith(u8, name, "rootpage-") and name.len > 9) { rootpage += 1; continue; }
        if (fixed.items.len != 0) try fixed.append(a, ' ');
        try fixed.appendSlice(a, name);
    }
    if (page != 1 or rootpage != 1 or !equal(fixed.items,
        "mediawiki ltr sitedir-ltr mw-hide-empty-elt action-view skin-vector-2022 ns-0 ns-subject mw-editable skin--responsive skin-vector skin-vector-search-vue")) return invalid;
    var at: usize = 0; var styles: usize = 0;
    while (at < head.len) {
        if (std.mem.startsWith(u8, head[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, head, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (head[at] != '<') { at += 1; continue; }
        if (head.len - at >= 15 and std.ascii.eqlIgnoreCase(head[at..][0..15], "<!DOCTYPE html>")) { at += 15; continue; }
        const tag = syntax.tagAt(head, at) orelse return invalid;
        const inv = try outerInventory(a, tag);
        if (!tag.closing and tag.is("style")) return invalid;
        if (!tag.closing and tag.is("script")) { at = try outerRawTextEnd(head, tag); continue; }
        if (!tag.closing and tag.is("link")) {
            var rels = std.mem.tokenizeAny(u8, inv.get("rel") orelse "", " \t\r\n\x0c");
            var stylesheet = false;
            while (rels.next()) |rel| if (std.ascii.eqlIgnoreCase(rel, "stylesheet")) { if (stylesheet) return invalid; stylesheet = true; };
            if (stylesheet) {
                if (styles == static_poster_urls.len) return invalid;
                const href = inv.get("href") orelse return invalid;
                const url = if (std.mem.startsWith(u8, href, "/w/")) try std.mem.concat(a, u8, &.{"https://it.wiktionary.org", href}) else href;
                if (!equal(url, static_poster_urls[styles])) return invalid;
                for (inv.attributes) |attr| if (!equal(attr.name, "rel") and !equal(attr.name, "href")) return invalid;
                styles += 1;
            }
        }
        at = tag.end;
    }
    if (styles != static_poster_urls.len) return invalid;
}
fn staticPosterPageContext(a: A, ns: *const namespaces.Registry, page: RawPage, html: []const u8) !void {
    const response = try json(a, page.response);
    try staticPosterHeadContext(a, try string(try field(response, "parse"), "headhtml"), ns.content_language);
    try staticPosterOuterContext(a, page.outer_context orelse return invalid);
    try staticPosterBodyContext(a, html);
}

// This policy was checked against the complete three-response serving set and
// this exact insertion chain. Minimum class membership is insufficient here.
fn staticPosterOuterContext(a: A, outer: RawOuterContext) !void {
    if (!equal(outer.profile, "mediawiki-vector-2022-1.48.0-wmf.4")) return invalid;
    const observed = try observedOuterPrefix(a, outer.response, true);
    if (!equal(observed.generator, "MediaWiki 1.48.0-wmf.4") or observed.ancestors.len != 8) return invalid;
    const full_root_classes = "client-nojs vector-feature-language-in-header-enabled vector-feature-language-in-main-menu-disabled vector-feature-language-in-main-page-header-disabled vector-feature-page-tools-pinned-disabled vector-feature-toc-pinned-clientpref-1 vector-feature-main-menu-pinned-disabled vector-feature-limited-width-clientpref-1 vector-feature-limited-width-content-enabled vector-feature-custom-font-size-clientpref-1 vector-feature-appearance-pinned-clientpref-1 skin-theme-clientpref-day vector-sticky-header-enabled vector-toc-available skin-thumbsize-clientpref-standard skin-underline-clientpref-browser";
    if (!equal(observed.ancestors[0].attributes.get("class") orelse "", full_root_classes)) return invalid;
    const tags = [_][]const u8{ "div", "div", "div", "main", "div", "div" };
    const expected = [_][]const Attribute{
        &.{.{ .name = "class", .value = "mw-page-container" }},
        &.{.{ .name = "class", .value = "mw-page-container-inner" }},
        &.{.{ .name = "class", .value = "mw-content-container" }},
        &.{ .{ .name = "id", .value = "content" }, .{ .name = "class", .value = "mw-body" } },
        &.{ .{ .name = "id", .value = "bodyContent" }, .{ .name = "class", .value = "vector-body" },
            .{ .name = "aria-labelledby", .value = "firstHeading" }, .{ .name = "data-mw-ve-target-container", .value = "" } },
        &.{ .{ .name = "id", .value = "mw-content-text" }, .{ .name = "class", .value = "mw-body-content" } },
    };
    for (observed.ancestors[2..], tags, expected) |node, tag, attributes| {
        if (!equal(node.tag, tag) or !outerSameAttributes(node.attributes, .{ .attributes = attributes }, false)) return invalid;
    }
}

// The normal class inventory allows STYLE/LINK for other capabilities. The
// poster's finite stylesheet proof owns a separate, stricter serving boundary.
fn staticPosterBodyContext(a: A, html: []const u8) !void {
    if (html.len == 0 or html.len > max_response or !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return invalid;
    var at: usize = 0;
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            if (std.mem.indexOf(u8, html[at + 4 .. end], "--") != null) return invalid;
            at = end + 3; continue;
        }
        if (html[at] != '<') { at += 1; continue; }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at or tag.end > html.len or tag.is("style") or tag.is("link") or tag.is("script")) return invalid;
        if (tag.is("meta")) {
            const inv = try inventory(a, tag);
            if (tag.closing or inv.attributes.len != 1 or !equal(inv.get("property") orelse "", "mw:PageProp/toc")) return invalid;
        }
        at = tag.end;
    }
}

const missing_observed_set_profile = "vector_new_link_observed_set_v1";
const missing_vector_css_bytes: usize = 90597;
const missing_vector_css_sha256 = "ecbc7435843a302ddba3652426b60f876a56950eeebdd1b9df0332aefeabd5fb";
const missing_vector_css_prefix = "@media (prefers-reduced-motion:reduce){*,::before,::after{animation-delay:-0.01ms !important;";
const ValidatedMissingSet = struct { responses: []const []const u8, urls: []const []const u8 };

fn missingStyleShape(shape: Value, observed_set: bool) !void {
    const styles = try field(shape, "missing_link_styles");
    if (styles != .object) return invalid;
    if (observed_set) {
        if (styles.object.count() != 3 or styles.object.get("response") != null or styles.object.get("receipt") != null)
            return invalid;
        _ = try field(styles, "profile"); _ = try field(styles, "defaults"); _ = try field(styles, "served_set");
    } else if (styles.object.count() != 4 or styles.object.get("served_set") != null) return invalid;
}
fn missingStyleOrigin(a: A, wiki: []const u8) !struct { origin: []const u8, language: []const u8 } {
    if (!std.mem.endsWith(u8, wiki, "wiktionary") or wiki.len <= "wiktionary".len) return invalid;
    const prefix = wiki[0 .. wiki.len - "wiktionary".len];
    if (prefix[0] < 'a' or prefix[0] > 'z') return invalid;
    var segment_start = true;
    for (prefix) |byte| {
        if (byte == '_') { if (segment_start) return invalid; segment_start = true; }
        else { if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9'))) return invalid; segment_start = false; }
    }
    if (segment_start) return invalid;
    const language = try a.dupe(u8, prefix); std.mem.replaceScalar(u8, language, '_', '-');
    return .{ .origin = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org", .{language}), .language = language };
}
fn missingStyleUrl(a: A, url: []const u8, origin: []const u8, language: []const u8) !void {
    const prefix = try std.mem.concat(a, u8, &.{ origin, "/w/load.php?" });
    if (!std.mem.startsWith(u8, url, prefix) or std.mem.indexOfAny(u8, url, "#\r\n\t\\") != null) return invalid;
    var pairs = std.mem.splitScalar(u8, url[prefix.len..], '&');
    var lang_seen = false; var module_seen = false; var only_seen = false; var skin_seen = false;
    while (pairs.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return invalid;
        const name = part[0..split]; const value = try formDecode(a, part[split + 1 ..]);
        if (equal(name, "lang")) { if (lang_seen or !equal(value, language)) return invalid; lang_seen = true; }
        else if (equal(name, "modules")) {
            if (module_seen or value.len == 0 or value.len > 4096) return invalid;
            for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._-,|", byte) == null) return invalid;
            module_seen = true;
        } else if (equal(name, "only")) { if (only_seen or !equal(value, "styles")) return invalid; only_seen = true; }
        else if (equal(name, "skin")) { if (skin_seen or !equal(value, "vector-2022")) return invalid; skin_seen = true; }
        else return invalid;
    }
    if (!lang_seen or !module_seen or !only_seen or !skin_seen) return invalid;
}
fn missingObservedSet(a: A, styles: MissingLinkStyles, wiki: []const u8, defaults_sha256: [32]u8) !ValidatedMissingSet {
    if (!equal(styles.profile, missing_observed_set_profile) or styles.response.len != 0 or styles.receipt.len != 0) return invalid;
    const served = styles.served_set orelse return invalid;
    if (served.responses.len == 0 or served.responses.len > 16) return invalid;
    const domain = try missingStyleOrigin(a, wiki);
    var defaults_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(styles.defaults, &defaults_hash, .{});
    if (!std.mem.eql(u8, &defaults_hash, &defaults_sha256)) return invalid;
    const defaults = try json(a, styles.defaults);
    const options = try field(try field(defaults, "query"), "defaultoptions");
    if (!equal(try string(defaults, "wiki"), wiki) or !equal(try string(options, "skin"), "vector-2022") or
        !equal(try string(options, "language"), domain.language) or !equal(try string(options, "vector-theme"), "day")) return invalid;
    return validateObservedStyleSet(a, served, wiki);
}
fn validateObservedStyleSet(a: A, served: MissingServedSet, wiki: []const u8) !ValidatedMissingSet {
    if (served.responses.len == 0 or served.responses.len > 16) return invalid;
    const domain = try missingStyleOrigin(a, wiki);
    const receipt = try json(a, served.receipt);
    if (receipt != .object or receipt.object.count() != 2 or try field(receipt, "core") != .null) return invalid;
    const sources = try field(receipt, "sources");
    if (sources != .array or sources.array.items.len != served.responses.len) return invalid;
    const urls = try a.alloc([]const u8, served.responses.len);
    for (served.responses, sources.array.items, urls, 0..) |response, source, *url, index| {
        if (response.len > max_response or !std.unicode.utf8ValidateSlice(response) or std.mem.indexOfScalar(u8, response, 0) != null) return invalid;
        const size = try field(source, "bytes");
        // An authenticated empty stylesheet is still an emitted stylesheet.
        if (size != .integer or size.integer < 0 or @as(u64, @intCast(size.integer)) != response.len or
            !digestMatches(response, try string(source, "sha256")) or try number(source, "status") != 200) return invalid;
        url.* = try string(source, "url");
        if (!equal(url.*, try string(source, "final_url"))) return invalid;
        try missingStyleUrl(a, url.*, domain.origin, domain.language);
        for (urls[0..index]) |old| if (equal(old, url.*)) return invalid;
        const label = try string(source, "source_path");
        if (label.len == 0 or label.len > 4096) return invalid;
        const content_type = try string(try field(source, "headers"), "content-type");
        const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
        if (!equal(std.mem.trim(u8, content_type[0..end], " \t"), "text/css")) return invalid;
    }
    return .{ .responses = served.responses, .urls = urls };
}
// A page supplement strengthens only that page's existing legacy paint proof.
// It never changes the global policy or supplies context for another page.
fn pageMissingServedSet(a: A, doc: Document, page: RawPage, shape: Value, defaults_sha256: [32]u8, inherited: ?ValidatedMissingSet) !?ValidatedMissingSet {
    if (shape != .object) return invalid;
    const value = shape.object.get("missing_served_set") orelse return inherited;
    if ((!equal(doc.schema, "wikidict.figure-page-observations.v4") and !equal(doc.schema, "wikidict.figure-page-observations.v7") and !equal(doc.schema, "wikidict.figure-page-observations.v8") and !equal(doc.schema, "wikidict.figure-page-observations.v9")) or inherited != null or
        value != .object or value.object.count() != 2 or
        value.object.get("responses") == null or value.object.get("receipt") == null or
        !page.text_class_scope or page.outer_context == null) return invalid;
    const supplemental = page.missing_served_set orelse return invalid;
    const legacy = doc.missing_link_styles orelse return invalid;
    _ = try missingLinkPaint(a, legacy, doc.wiki, defaults_sha256);
    var has_missing = false;
    for (page.occurrences) |occurrence| has_missing = has_missing or occurrence.missing_content;
    if (!has_missing) return invalid;
    return try missingObservedSet(a, .{
        .profile = missing_observed_set_profile,
        .defaults = legacy.defaults,
        .served_set = supplemental,
    }, doc.wiki, defaults_sha256);
}

fn missingHeadSources(a: A, ns: *const namespaces.Registry, page: RawPage, served: ValidatedMissingSet) ![]const usize {
    const response = try json(a, page.response);
    const head = try string(try field(response, "parse"), "headhtml");
    const observed = try observedOuterPrefix(a, head, false);
    if (observed.ancestors.len != 2) return invalid;
    const root = observed.ancestors[0].attributes; const body = observed.ancestors[1].attributes;
    const classes = root.get("class") orelse return invalid;
    if (!equal(root.get("lang") orelse "", ns.content_language) or !equal(root.get("dir") orelse "", "ltr") or
        !profile.Profile.hasClass(classes, "skin-theme-clientpref-day") or
        profile.Profile.hasClass(classes, "skin-theme-clientpref-night") or profile.Profile.hasClass(classes, "skin-theme-clientpref-os") or
        !profile.Profile.hasClass(body.get("class") orelse "", "skin-vector-2022")) return invalid;
    const domain = try missingStyleOrigin(a, ns.wiki);
    var selected: std.ArrayList(usize) = .empty;
    var at: usize = 0;
    while (at < head.len) {
        if (std.mem.startsWith(u8, head[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, head, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (head[at] != '<') { at += 1; continue; }
        if (head.len - at >= 15 and std.ascii.eqlIgnoreCase(head[at..][0..15], "<!DOCTYPE html>")) { at += 15; continue; }
        const tag = syntax.tagAt(head, at) orelse return invalid;
        const inv = try outerInventory(a, tag);
        if (!tag.closing and tag.is("style")) return invalid;
        // A BASE href changes even root-relative stylesheet URL resolution.
        if (!tag.closing and tag.is("base") and inv.get("href") != null) return invalid;
        if (!tag.closing and tag.is("script")) { at = try outerRawTextEnd(head, tag); continue; }
        if (!tag.closing and tag.is("link")) {
            var rels = std.mem.tokenizeAny(u8, inv.get("rel") orelse "", " \t\r\n\x0c");
            var stylesheet = false;
            while (rels.next()) |rel| if (std.ascii.eqlIgnoreCase(rel, "stylesheet")) { if (stylesheet) return invalid; stylesheet = true; };
            if (stylesheet) {
                if (selected.items.len == 16) return invalid;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, inv.get("rel") orelse "", " \t\r\n\x0c"), "stylesheet")) return invalid;
                for (inv.attributes) |attr| if (!equal(attr.name, "rel") and !equal(attr.name, "href")) return invalid;
                const href = inv.get("href") orelse return invalid;
                const url = if (std.mem.startsWith(u8, href, "/w/")) try std.mem.concat(a, u8, &.{ domain.origin, href }) else href;
                try missingStyleUrl(a, url, domain.origin, domain.language);
                var found: ?usize = null;
                for (served.urls, 0..) |known, index| if (equal(known, url)) { found = index; break; };
                const index = found orelse return invalid;
                for (selected.items) |old| if (old == index) return invalid;
                try selected.append(a, index);
            }
        }
        at = tag.end;
    }
    if (selected.items.len == 0) return invalid;
    return selected.toOwnedSlice(a);
}
// This path selects complete page-authored CSS, independently from Missing paint.
// It never filters declarations in those bodies. Every emitted body style keeps
// its original byte offset and order, and unknown CSS remains the parser's refusal.
fn observedPageStyleProfile(a: A, ns: *const namespaces.Registry, schema: []const u8, page: RawPage, shape: Value, html: []const u8,
    text_scope: ?profile.BoundedTextClassScope, outer: ?ObservedOuterContext) !?*PageStyleData
{
    if (shape != .object) return invalid;
    const field_value = shape.object.get("page_styles") orelse return null;
    if ((!equal(schema, "wikidict.figure-page-observations.v7") and !equal(schema, "wikidict.figure-page-observations.v8") and !equal(schema, "wikidict.figure-page-observations.v9")) or field_value != .object or field_value.object.count() != 2 or
        field_value.object.get("responses") == null or field_value.object.get("receipt") == null or
        !page.text_class_scope or text_scope == null or outer == null) return invalid;
    const served = try validateObservedStyleSet(a, page.page_styles orelse return invalid, ns.wiki);
    const selected = try missingHeadSources(a, ns, page, served);
    var context_sources: std.ArrayList(profile.Source) = .empty;
    for (selected) |index| try context_sources.append(a, .{ .css = served.responses[index], .base_url = served.urls[index] });
    var authored_sources: std.ArrayList(profile.Source) = .empty;
    try appendObservedPageStyles(a, &authored_sources, html);
    const result = try a.create(PageStyleData);
    // Parsing the joined cascade occurs only after the selected global parent is
    // known. These slices and source identities are owned by the immutable Book.
    result.* = .{ .authored_sources = authored_sources.items, .context_sources = context_sources.items,
        .page = page, .scope = text_scope.?, .outer = outer.? };
    return result;
}
fn retainObservedNodeCustomEnvironments(a: A, styles: *const profile.Profile, primary: []profile.TextElement, alternative: []profile.TextElement) !void {
    const custom = styles.custom_properties orelse return;
    if (primary.len == 0 or primary.len != alternative.len or primary.len > 32) return invalid;
    // The complete observed chain is owned by the selector above. Verify its
    // topology before computing any environment, without borrowing the final
    // descendant root_environment as an initial ancestor state.
    for (primary, alternative, 0..) |left, right, index| {
        if (!left.physical_ancestry_complete or !right.physical_ancestry_complete or
            left.observed_inline_style == null or right.observed_inline_style == null or
            left.parent != (if (index == 0) null else &primary[index - 1]) or
            right.parent != (if (index == 0) null else &alternative[index - 1]) or
            (index == 0 and (!equal(left.tag, "html") or !equal(right.tag, "html")))) return invalid;
    }
    var left_environment: profile.CustomEnvironment = .{ .complete = !custom.is_opaque };
    var right_environment: profile.CustomEnvironment = .{ .complete = !custom.is_opaque };
    for (primary, alternative, 0..) |*left, *right, index| {
        left_environment = try custom.element(a, left_environment, .{ .tag = left.tag, .classes = left.classes, .id = left.id, .root = index == 0 }, left.observed_inline_style.?);
        right_environment = try custom.element(a, right_environment, .{ .tag = right.tag, .classes = right.classes, .id = right.id, .root = index == 0 }, right.observed_inline_style.?);
        left.observed_custom_environment = left_environment;
        right.observed_custom_environment = right_environment;
    }
}

// The inventory comes from the complete, balanced observed parser subtree.
// Agreement covers every element, including elements with no selected source
// anchor. It is a value invariant, never a source-to-DOM identity certificate.
fn observedPageCustomInvariant(a: A, custom: *const profile.CustomProfile, nodes: []const ObservedSiblingNode,
    primary_root: profile.CustomEnvironment, alternative_root: profile.CustomEnvironment) !profile.CustomEnvironment
{
    if (nodes.len == 0 or nodes.len > 16384 or nodes[0].parent != null or !nodes[0].tag.is("div")) return invalid;
    const primary = try a.alloc(profile.CustomEnvironment, nodes.len);
    defer a.free(primary);
    const alternative = try a.alloc(profile.CustomEnvironment, nodes.len);
    defer a.free(alternative);
    primary[0] = primary_root;
    alternative[0] = alternative_root;
    var agreement = try commonObservedCustomEnvironment(a, primary_root, alternative_root);
    const EnvironmentKey = struct { address: usize, len: usize, complete: bool };
    var seen: std.AutoHashMapUnmanaged(EnvironmentKey, void) = .empty;
    defer seen.deinit(a);
    for ([_]profile.CustomEnvironment{ primary_root, alternative_root }) |environment|
        try seen.put(a, .{ .address = @intFromPtr(environment.values.ptr), .len = environment.values.len, .complete = environment.complete }, {});
    if (agreement.values.len > 4096) return .{};
    for (nodes[1..], 1..) |node, index| {
        const parent_index = node.parent orelse return invalid;
        if (parent_index >= index) return invalid;
        const own: profile.CustomElement = .{ .tag = node.tag.name,
            .classes = node.attributes.get("class") orelse "", .id = node.attributes.get("id") orelse "" };
        const css = node.attributes.get("style") orelse "";
        primary[index] = try custom.element(a, primary[parent_index], own, css);
        alternative[index] = try custom.element(a, alternative[parent_index], own, css);
        for ([_]profile.CustomEnvironment{ primary[index], alternative[index] }) |environment| {
            // Most nodes share an immutable parent environment. Do not clone
            // the site's complete token table again for those identical slices.
            const key: EnvironmentKey = .{ .address = @intFromPtr(environment.values.ptr), .len = environment.values.len, .complete = environment.complete };
            if (seen.contains(key)) continue;
            // Exceeding this independent proof budget withholds the invariant;
            // it cannot turn a partial census into a known value or absence.
            if (seen.count() >= 4096 or environment.values.len > 4096) return .{};
            try seen.put(a, key, {});
            agreement = try commonObservedCustomEnvironment(a, agreement, environment);
            if (agreement.values.len > 4096) return .{};
        }
    }
    return agreement;
}

const SourceCustomAnchor = struct { attributes: Inventory, text: []const u8, range: profile.SourceRootChildProof };
fn customAnchorAttributes(a: A, tag: syntax.Tag) !?Inventory {
    // Attribute preprocessing is part of the operation. Close both raw and
    // decoded grammars; an exact decoded signature alone is insufficient.
    if (std.mem.indexOfAny(u8, tag.attrs, "{}[]<>|\r\n\x00") != null or std.mem.indexOf(u8, tag.attrs, "__") != null) return null;
    const attributes = inventory(a, tag) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
    for (attributes.attributes) |attribute| {
        if (!equal(attribute.name, "style")) {
            if (!siblingLiteralAttribute(attribute.name, attribute.value)) return null;
            continue;
        }
        // Functions may contain only literal ASCII CSS tokens. No strings,
        // escapes, comments, markup or wikitext execution are admitted.
        for (attribute.value) |byte| if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, " #.,%+_-:;()", byte) == null) return null;
        var at: usize = 0;
        while (try profile.nextDeclarationAlloc(a, attribute.value, &at)) |declaration| {
            defer a.free(declaration);
            if (std.mem.trim(u8, declaration, " ").len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse return null;
            if (profile.customPriority(declaration[colon + 1..]).unknown) return null;
        }
    }
    return attributes;
}
fn sourceCustomAnchor(a: A, source: []const u8, start: usize) !?SourceCustomAnchor {
    // This is a whole line-start block opening. An earlier quote operation on
    // the same physical line must not change the first child's bold operation.
    if (start != 0 and source[start - 1] != '\n') return null;
    const tag = syntax.tagAt(source, start) orelse return null;
    if (!tag.is("div") or tag.closing or tag.self_closing or std.mem.endsWith(u8, source[start..tag.end], "/>")) return null;
    const attributes = (try customAnchorAttributes(a, tag)) orelse return null;
    if (!std.mem.startsWith(u8, source[tag.end..], "'''")) return null;
    const text_start = tag.end + 3;
    const text_end = std.mem.indexOfPos(u8, source, text_start, "'''" ) orelse return null;
    const text = (try literalSiblingText(a, source[text_start..text_end])) orelse return null;
    if (!std.mem.startsWith(u8, source[text_end + 3..], ":")) return null;
    const whole = syntax.matchingTag(source, tag) orelse return null;
    if (whole.inner_end < text_end + 4) return null;
    return .{ .attributes = attributes, .text = text, .range = .{
        .anchor_start = start, .anchor_end = whole.end,
        .name_start = @intFromPtr(tag.name.ptr) - @intFromPtr(source.ptr), .name_len = tag.name.len,
        .attrs_start = @intFromPtr(tag.attrs.ptr) - @intFromPtr(source.ptr), .attrs_len = tag.attrs.len } };
}
fn sameCustomAnchor(left: SourceCustomAnchor, right: SourceCustomAnchor) bool {
    return sameSiblingAttributes(left.attributes, right.attributes) and equal(left.text, right.text);
}
fn observedCustomAnchor(a: A, html: []const u8, nodes: []const ObservedSiblingNode, index: usize) !?SourceCustomAnchor {
    const own = nodes[index];
    if (!own.tag.is("div") or own.parent == null) return null;
    const child_index = own.first_child orelse return null;
    if (child_index <= index or child_index >= nodes.len) return null;
    const child = nodes[child_index];
    if (!child.tag.is("b") or child.parent != index or child.first_child != null or child.start != own.tag.end or
        child.attributes.attributes.len != 0) return null;
    const end = child.inner_end orelse return null;
    const text = (try literalSiblingText(a, html[child.tag.end..end])) orelse return null;
    const closing = syntax.tagAt(html, end) orelse return null;
    if (!closing.is("b") or !closing.closing or closing.self_closing or
        std.mem.trim(u8, closing.attrs, " \t\r\n").len != 0 or !std.mem.startsWith(u8, html[closing.end..], ":")) return null;
    return .{ .attributes = own.attributes, .text = text,
        .range = .{ .anchor_start = 0, .anchor_end = 0, .name_start = 0, .name_len = 0, .attrs_start = 0, .attrs_len = 0 } };
}
fn customBodyTag(tag: syntax.Tag) bool {
    // Closed ordinary body vocabulary. This is an emission eligibility proof,
    // not an HTML ancestry repair or a source-to-DOM parent certificate.
    for ([_][]const u8{ "div", "p", "span", "b", "i", "strong", "em", "small", "big", "u", "s", "sub", "sup", "abbr", "cite", "code", "tt", "br", "hr", "ul", "ol", "li", "dl", "dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "td", "th", "caption" }) |name| if (tag.is(name)) return true;
    return false;
}
fn ordinaryCustomAnchors(a: A, source: []const u8) ![]const SourceCustomAnchor {
    var result: std.ArrayList(SourceCustomAnchor) = .empty;
    var scan: syntax.OpaqueScan = .{};
    var position: usize = 0;
    var brackets: usize = 0;
    var wiki_tables: usize = 0;
    var html_tables: usize = 0;
    while (position < source.len) {
        const rest = source[position..];
        const line_start = position == 0 or source[position - 1] == '\n';
        // Unexpanded operations may emit parser state before the candidate.
        // Never infer that their eventual output is neutral.
        if (line_start and brackets == 0 and std.mem.startsWith(u8, rest, "{|")) { wiki_tables += 1; position += 2; continue; }
        if (line_start and brackets == 0 and std.mem.startsWith(u8, rest, "|}")) {
            if (wiki_tables == 0) break;
            wiki_tables -= 1; position += 2; continue;
        }
        // Single braces are also closed: comment/strip removal must not join
        // two raw tokens into an executable template delimiter.
        if (source[position] == '{' or source[position] == '}') break;
        if (source[position] == '<') {
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const end = scan.protectedEnd(source, position, null) orelse break;
                position = end; continue;
            }
            const tag = scan.tagAt(source, position, null) orelse break;
            if (std.mem.indexOfAny(u8, tag.attrs, "{}<>") != null or
                (tag.closing and std.mem.trim(u8, tag.attrs, " \t\r\n").len != 0)) break;
            // Duplicate CLASS does not prevent an ordinary prefix tag from
            // being emitted. Discard these values: candidate anchors and the
            // observed tree still require the strict, unique inventory.
            _ = inventoryWithRepeatedClass(a, tag, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break,
            };
            if (tag.isOpaque()) {
                // These registered strip operations do not lend their literal
                // bodies to the ordinary source census. Other extension output
                // is deliberately unknown for a later candidate.
                if (tag.closing or !(tag.is("nowiki") or tag.is("pre") or (tag.is("templatestyles") and tag.self_closing))) break;
                const pair = scan.pair(source, tag) orelse break;
                position = pair.end; continue;
            }
            if (!customBodyTag(tag)) break;
            if (tag.is("table")) {
                if (tag.closing) {
                    if (html_tables == 0) break;
                    html_tables -= 1;
                } else html_tables += 1;
            }
            if (line_start and brackets == 0 and wiki_tables == 0 and html_tables == 0) {
                if (try sourceCustomAnchor(a, source, position)) |anchor_value| try result.append(a, anchor_value);
                if (result.items.len > 4096) return invalid;
            }
            position = tag.end; continue;
        }
        // Bracket scope is refusal-only. Even a balanced caption must not lend
        // a raw tag as an ordinary page block; unknown/malformed balance stays
        // closed to later proof until an actual matching delimiter is present.
        if (source[position] == '[') brackets += 1;
        if (source[position] == ']') {
            if (brackets == 0) break;
            brackets -= 1;
        }
        position += 1;
    }
    return try result.toOwnedSlice(a);
}

fn observedSourceCustomElements(a: A, source: []const u8, html: []const u8, nodes: []const ObservedSiblingNode) ![]const profile.SourceCustomElementProof {
    const authored = try ordinaryCustomAnchors(a, source);
    defer a.free(authored);
    const observed = try a.alloc(?SourceCustomAnchor, nodes.len);
    defer a.free(observed);
    for (nodes, 0..) |_, index| observed[index] = try observedCustomAnchor(a, html, nodes, index);
    var proofs: std.ArrayList(profile.SourceCustomElementProof) = .empty;
    for (authored) |anchor_value| {
        var source_count: usize = 0;
        for (authored) |other| if (sameCustomAnchor(anchor_value, other)) { source_count += 1; };
        var actual_count: usize = 0;
        for (observed) |maybe| if (maybe) |other| if (sameCustomAnchor(anchor_value, other)) { actual_count += 1; };
        // Coverage is universal, never a selected DOM identity or ordinal.
        if (actual_count == 0 or actual_count != source_count) continue;
        try proofs.append(a, .{ .range = anchor_value.range, .candidate_count = @intCast(actual_count) });
    }
    return try proofs.toOwnedSlice(a);
}

fn observedCustomAncestor(node: OuterObservedNode, root: bool) profile.CustomElement {
    return .{ .tag = node.tag, .classes = node.attributes.get("class") orelse "", .id = node.attributes.get("id") orelse "",
        .inline_css = node.attributes.get("style") orelse "", .root = root };
}
fn commonObservedCustomEnvironment(a: A, left: profile.CustomEnvironment, right: profile.CustomEnvironment) !profile.CustomEnvironment {
    return profile.intersectCustomEnvironmentsAlloc(a, left, right);
}
fn attachObservedPageCustomProperties(a: A, styles: *profile.Profile, ns: *const namespaces.Registry, page: RawPage,
    scope: profile.BoundedTextClassScope, outer: ObservedOuterContext, sources: []const profile.Source) !void
{
    const response = try json(a, page.response);
    const supplied = try observedOuterPrefix(a, try string(try field(response, "parse"), "headhtml"), false);
    if (supplied.ancestors.len != 2 or outer.ancestors.len != 8) return invalid;
    const ancestors = try a.alloc(profile.CustomElement, 9);
    for (outer.ancestors, 0..) |node, index| ancestors[index] = observedCustomAncestor(node, index == 0);
    ancestors[0] = observedCustomAncestor(supplied.ancestors[0], true);
    ancestors[1] = observedCustomAncestor(supplied.ancestors[1], false);
    ancestors[8] = .{ .tag = scope.root_tag, .classes = scope.root_classes };
    _ = ns;
    try profile.attachCustomProperties(styles, sources, .{ .dark = null, .ancestors = ancestors });
    const custom = @constCast(styles.custom_properties.?);
    custom.page_title = try styles.arena.allocator().dupe(u8, page.title);
    // The insertion contract permits only the independently retained TOC class
    // difference. Evaluate both actual HTML states with the same CSS engine and
    // retain a value only when both agree; never use their positive class union.
    ancestors[0] = observedCustomAncestor(outer.ancestors[0], true);
    var alternative: profile.CustomEnvironment = .{ .complete = !custom.is_opaque };
    for (ancestors) |node| alternative = try custom.element(a, alternative, node, node.inline_css);
    custom.root_environment = try commonObservedCustomEnvironment(a, custom.root_environment, alternative);
}

fn appendObservedPageStyles(a: A, sources: *std.ArrayList(profile.Source), html: []const u8) !void {
    // Caller has already validated the complete body through observedTextClassScope.
    // This pass inventories only stylesheet-bearing tags and dedup references.
    var ids: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            at = (std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid) + 3;
            continue;
        }
        if (html[at] != '<') { at += 1; continue; }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        if (tag.end <= at) return invalid;
        const inv = try inventory(a, tag);
        if (!tag.closing and tag.is("style")) {
            for (inv.attributes) |attr| if (!equal(attr.name, "data-mw-deduplicate")) return invalid;
            if (inv.get("data-mw-deduplicate")) |id| {
                if (id.len == 0 or id.len > 1024) return invalid;
                for (ids.items) |old| if (equal(old, id)) return invalid;
                try ids.append(a, id);
            }
            var cursor = tag.end;
            while (cursor < html.len) : (cursor += 1) {
                if (html.len - cursor < 8 or !std.ascii.eqlIgnoreCase(html[cursor..][0..7], "</style")) continue;
                const next = html[cursor + 7];
                if (next != '>' and next != '/' and !htmlClassSpace(next)) continue;
                const close = syntax.tagAt(html, cursor) orelse return invalid;
                if (!close.closing or !close.is("style") or close.self_closing or (try inventory(a, close)).attributes.len != 0) return invalid;
                try sources.append(a, .{ .css = html[tag.end..cursor], .base_url = "", .byte_start = tag.end });
                at = close.end;
                break;
            } else return invalid;
            continue;
        }
        if (!tag.closing and tag.is("link")) {
            // No unrepresented body stylesheet, alternate, media, or URL context.
            if (!equal(inv.get("rel") orelse "", "mw-deduplicated-inline-style") or inv.attributes.len != 2) return invalid;
            const href = inv.get("href") orelse return invalid;
            if (!std.mem.startsWith(u8, href, "mw-data:")) return invalid;
            var found = false;
            for (ids.items) |id| if (equal(id, href[8..])) { found = true; break; };
            if (!found) return invalid;
        }
        at = tag.end;
    }
}

fn missingServedProfile(a: A, ns: *const namespaces.Registry, page: RawPage, served: ValidatedMissingSet) !?profile.Profile {
    const selected = try missingHeadSources(a, ns, page, served);
    var sources: std.ArrayList(profile.Source) = .empty;
    var module_count: usize = 0;
    for (selected) |index| {
        const response = served.responses[index];
        var cursor: usize = 0; var start: usize = 0; var candidates: usize = 0;
        while (std.mem.indexOfPos(u8, response, cursor, missing_vector_css_prefix)) |at| {
            candidates += 1; if (candidates > 64) return invalid;
            cursor = at + missing_vector_css_prefix.len;
            if (response.len - at < missing_vector_css_bytes or !digestMatches(response[at..][0..missing_vector_css_bytes], missing_vector_css_sha256)) continue;
            module_count += 1;
            if (module_count != 1) return invalid;
            // Parse both complete sides with the existing parser. An occurrence
            // inside a group, string or comment cannot become a top-level module.
            try sources.append(a, .{ .css = response[start..at], .base_url = served.urls[index], .byte_start = start });
            start = at + missing_vector_css_bytes; cursor = start;
        }
        try sources.append(a, .{ .css = response[start..], .base_url = served.urls[index], .byte_start = start });
    }
    if (module_count != 1) return invalid;
    return profile.parseSourcesAlloc(a, sources.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

const MissingPaintFailure = struct {
    occurrence_index: ?usize = null,
    node_index: usize, tag: []const u8, classes: []const u8,
    blocker: profile.MissingLinkPaintBlocker,
};
fn missingServedStyleNoninterference(a: A, styles: *const profile.Profile, path: ObservedPaintPath) A.Error!bool {
    return missingServedStyleNoninterferenceWithFailure(a, styles, path, null, null);
}
fn missingServedStyleNoninterferenceWithFailure(a: A, styles: *const profile.Profile, path: ObservedPaintPath, failure: ?*?MissingPaintFailure, occurrence_index: ?usize) A.Error!bool {
    if (path.nodes.len == 0 or path.nodes.len > 256 or !std.ascii.eqlIgnoreCase(path.nodes[0].tag, "html")) return false;
    var classes: std.ArrayList(u8) = .empty;
    defer classes.deinit(a);
    for (path.nodes, 0..) |node, index| {
        const own_classes = if (index == 0) path.html_classes else node.attributes.get("class") orelse "";
        if (node.attributes.get("style") != null or profile.Profile.hasClass(own_classes, "notheme") or
            profile.Profile.hasClass(own_classes, "skin-invert")) return false;
        appendOuterClasses(a, &classes, own_classes) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return false };
    }
    const elements = try a.alloc(profile.TextElement, path.nodes.len);
    defer a.free(elements);
    for (path.nodes, elements, 0..) |*node, *element, index| element.* = .{
        .tag = node.tag, .classes = if (index == 0) path.html_classes else node.attributes.get("class") orelse "",
        .id = node.attributes.get("id") orelse "", .typeof_tokens = node.attributes.get("typeof") orelse "",
        .language = node.attributes.get("lang"), .attribute_presence = .{ .ctx = &node.attributes, .get = Inventory.presence },
        .parent = if (index == 0) null else &elements[index - 1], .physical_ancestry_complete = true, .complete_ancestor_classes = classes.items, .ancestry_complete = true,
    };
    for (elements, 0..) |*element, index| if (try styles.missingLinkAdditionalPaintBlockerIn(a, element)) |blocker| {
        if (failure) |out| {
            if (out.* == null) out.* = .{ .occurrence_index = occurrence_index, .node_index = index, .tag = element.tag, .classes = element.classes, .blocker = blocker };
        }
        return false;
    };
    return true;
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
    if (page.form_body.len == 0 or page.form_body.len > 256 * 1024) return invalid;
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
    if (parameters != .object or parameters.object.count() != (if ((page.text_class_scope or page.image_map_no_link != null)) @as(usize, 11) else 10)) return invalid;
    for ([_][2][]const u8{ .{ "action", "parse" }, .{ "format", "json" }, .{ "formatversion", "2" }, .{ "maxlag", "5" },
        .{ "contentmodel", "wikitext" }, .{ "parser", "legacy" }, .{ "usearticle", "1" } }) |pair|
        if (!equal(try string(parameters, pair[0]), pair[1])) return invalid;
    const expected_prop = if ((page.text_class_scope or page.image_map_no_link != null)) "text|wikitext|revid|displaytitle|headhtml|modules|jsconfigvars" else "text|wikitext|revid|displaytitle";
    if (!equal(try string(parameters, "prop"), expected_prop)) return invalid;
    if ((page.text_class_scope or page.image_map_no_link != null) and !equal(try string(parameters, "useskin"), "vector-2022")) return invalid;
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
    if (found.count() != (if ((page.text_class_scope or page.image_map_no_link != null)) @as(usize, 12) else 11)) return invalid;
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
    return inventoryWithRepeatedClass(a, tag, false);
}
fn inventoryWithRepeatedClass(a: A, tag: syntax.Tag, allow_repeated_class: bool) !Inventory {
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
        for (attributes.items) |old| if (std.ascii.eqlIgnoreCase(old.name, name) and
            !(allow_repeated_class and std.ascii.eqlIgnoreCase(name, "class"))) return invalid;
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
fn observedCenterOpening(stack: []const ObservedOpenNode, tag: syntax.Tag) !void {
    if (!tag.is("center")) return;
    // CENTER is an ordinary block in this explicit tree, not a flattening or
    // inherited paint grant. Refuse insertion modes that would reparent it.
    for (stack) |open| if (open.tag.is("p")) return invalid;
    var index = stack.len;
    while (index != 0) {
        index -= 1;
        const parent = stack[index].tag;
        if (parent.is("td") or parent.is("th") or parent.is("caption")) break;
        if (parent.is("table")) return invalid;
    }
}

fn observedBdiOpening(stack: []const ObservedOpenNode, tag: syntax.Tag) !void {
    var inside_bdi = false;
    for (stack) |open| if (open.tag.is("bdi")) { inside_bdi = true; break; };
    if (inside_bdi) {
        // Keep the isolate as a real stack node. This bounded inline domain
        // excludes block insertion and adoption repairs instead of flattening
        // the isolate or inferring its computed direction/language effects.
        var phrasing = false;
        for ([_][]const u8{ "span", "bdi", "a", "b", "strong", "i", "em", "small", "sup", "sub",
            "abbr", "cite", "u", "s", "code", "font", "br", "wbr" }) |name|
            if (tag.is(name)) { phrasing = true; break; };
        if (!phrasing) return invalid;
        if (tag.is("a")) for (stack) |open| if (open.tag.is("a")) return invalid;
    }
    if (!tag.is("bdi")) return;
    // In a table insertion scope an inline opening would be foster-parented.
    // Explicit cells/captions start an ordinary inline scope again.
    var index = stack.len;
    while (index != 0) {
        index -= 1;
        const parent = stack[index].tag;
        if (parent.is("td") or parent.is("th") or parent.is("caption")) break;
        if (parent.is("table")) return invalid;
    }
}

fn observedTextClassScope(a: A, ns: *const namespaces.Registry, html: []const u8) !profile.BoundedTextClassScope {
    return observedTextClassScopeWithElements(a, ns, html, null);
}
fn observedTextClassScopeWithElements(a: A, ns: *const namespaces.Registry, html: []const u8, nodes: ?*std.ArrayList(ObservedSiblingNode)) !profile.BoundedTextClassScope {
    if (html.len == 0 or html.len > max_response or !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return invalid;
    var stack: [128]ObservedOpenNode = undefined;
    var depth: usize = 0;
    var path: [128]usize = undefined;
    var last_element: [129]?usize = @splat(null);
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
            for (stack[0..depth]) |open| if (open.tag.is("ruby")) return invalid;
            if (std.mem.startsWith(u8, html[at + 4 ..], ">") or std.mem.startsWith(u8, html[at + 4 ..], "->")) return invalid;
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            if (std.mem.indexOf(u8, html[at + 4 .. end], "--") != null or
                (end > at + 4 and html[end - 1] == '-')) return invalid;
            at = end + 3;
            continue;
        }
        if (html[at] != '<') {
            if (depth == 0 and !htmlClassSpace(html[at])) return invalid;
            if (depth > 0 and stack[depth - 1].tag.is("audio") and !htmlClassSpace(html[at])) return invalid;
            if (depth > 0 and stack[depth - 1].tag.is("ruby") and !std.ascii.isWhitespace(html[at])) {
                if (stack[depth - 1].ruby_phase != 0) return invalid;
                stack[depth - 1].ruby_base_text = true;
            }
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
                !std.ascii.eqlIgnoreCase(stack[depth - 1].tag.name, tag.name)) return invalid;
            if (tag.is("ruby") and (stack[depth - 1].ruby_phase != 3 or !stack[depth - 1].ruby_base_text)) return invalid;
            if (nodes) |items| items.items[path[depth - 1]].inner_end = at;
            depth -= 1;
            at = tag.end;
            continue;
        }
        elements += 1;
        if (elements > 16384) return invalid;
        var ordinary = false;
        for ([_][]const u8{ "div", "span", "bdi", "a", "figure", "figcaption", "img", "meta", "link", "style",
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
            "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "pre", "font", "center", "audio", "source", "mark", "ruby", "rp", "rt" }) |name|
            if (tag.is(name)) { ordinary = true; break; };
        const is_void = tag.is("img") or tag.is("meta") or tag.is("link") or tag.is("col") or tag.is("br") or tag.is("hr") or tag.is("wbr") or tag.is("source");
        if (!ordinary or ((tag.self_closing or html[tag.end - 2] == '/') and !is_void)) return invalid;
        const audio_child = depth > 0 and stack[depth - 1].tag.is("audio");
        if ((audio_child and !tag.is("source")) or (tag.is("source") and !audio_child)) return invalid;
        try observedRubyOpening(stack[0..depth], tag, inv);
        try observedCenterOpening(stack[0..depth], tag);
        try observedBdiOpening(stack[0..depth], tag);
        if (depth == 0) {
            if (root_seen or !tag.is("div") or inv.attributes.len != 3 or
                !equal(inv.get("class") orelse return invalid, "mw-content-ltr mw-parser-output") or
                !equal(inv.get("lang") orelse return invalid, ns.content_language) or
                !equal(inv.get("dir") orelse return invalid, "ltr")) return invalid;
            root_seen = true;
            root_classes = inv.get("class").?;
        }
        if (nodes) |items| {
            const index = items.items.len;
            const parent: ?usize = if (depth == 0) null else path[depth - 1];
            try items.append(a, .{ .tag = tag, .attributes = inv, .start = at,
                .parent = parent, .previous = last_element[depth] });
            if (parent) |owner| if (items.items[owner].first_child == null) { items.items[owner].first_child = index; };
            last_element[depth] = index;
            if (!is_void and !tag.is("style")) {
                if (depth == path.len) return invalid;
                path[depth] = index;
                last_element[depth + 1] = null;
            }
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
            stack[depth] = .{ .tag = tag, .attributes = inv };
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
// Refusal-only census identity. An ordinary same-file link or a differently
// parameterized description link is still a duplicate, never another proof.
fn svgLanguageFileIdentity(a: A, ns: *const namespaces.Registry, href: []const u8) !?[]const u8 {
    if (try fileHref(a, ns, href)) |file| return file;
    if (!std.mem.startsWith(u8, href, "/w/index.php?title=")) return null;
    const raw = href["/w/index.php?title=".len..];
    const end = std.mem.indexOfScalar(u8, raw, '&') orelse raw.len;
    const title = raw[0..end];
    if (title.len == 0 or std.mem.indexOfAny(u8, title, "?#\\\r\n\t") != null) return null;
    var at: usize = 0;
    while (at < title.len) : (at += 1) if (title[at] == '%') {
        if (title.len - at < 3 or !std.ascii.isHex(title[at + 1]) or !std.ascii.isHex(title[at + 2])) return null;
        at += 2;
    };
    return fileHref(a, ns, try std.mem.concat(a, u8, &.{ "/wiki/", title }));
}
fn svgLanguageFileHref(a: A, ns: *const namespaces.Registry, href: []const u8, language: ?[]const u8) !?[]const u8 {
    const selected = language orelse return fileHref(a, ns, href);
    if (!compiler.validSvgRasterLanguage(selected) or !std.mem.startsWith(u8, href, "/w/index.php?title=")) return null;
    const raw = href["/w/index.php?title=".len..];
    const separator = std.mem.indexOfScalar(u8, raw, '&') orelse return null;
    const tail = try std.fmt.allocPrint(a, "lang={s}", .{selected});
    if (!equal(raw[separator + 1 ..], tail)) return null;
    return svgLanguageFileIdentity(a, ns, href);
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
const ObservedImage = struct { width: u32, height: u32 = 0, svg_language: ?[]const u8 = null, element: ?Inventory = null, anchor: Inventory, centered: bool = false, centered_default_size: bool = false, right_default_size: bool = false, missing_content: ?ObservedMissing = null, poster_label: ?[]const u8 = null };
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
    var thumbnail_seen = false;
    var width_seen = false;
    var right_seen = false;
    for (parts[0 .. count - 1]) |part| {
        const option = registry.match(part, .image) orelse return false;
        if (equal(option.id, "img_thumbnail")) {
            if (thumbnail_seen or option.value != null) return false;
            thumbnail_seen = true;
        } else if (equal(option.id, "img_right")) {
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
    return thumbnail_seen and width_seen and right_seen == observed.right;
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
const ObservedOpenNode = struct { tag: syntax.Tag, attributes: Inventory, start: usize = 0, ruby_phase: u3 = 0, ruby_base_text: bool = false };
fn observedRubyOpening(stack: []ObservedOpenNode, tag: syntax.Tag, inv: Inventory) !void {
    const depth = stack.len;
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
}

const ObservedPaintPath = struct { nodes: []const OuterObservedNode, html_classes: []const u8 };

fn missingPaintPath(a: A, outer: ObservedOuterContext, local: []const ObservedOpenNode, tag: syntax.Tag, attributes: Inventory) A.Error!ObservedPaintPath {
    const nodes = try a.alloc(OuterObservedNode, outer.ancestors.len + local.len + 1);
    @memcpy(nodes[0..outer.ancestors.len], outer.ancestors);
    for (local, nodes[outer.ancestors.len .. nodes.len - 1]) |source, *node|
        node.* = .{ .tag = source.tag.name, .attributes = source.attributes };
    nodes[nodes.len - 1] = .{ .tag = tag.name, .attributes = attributes };
    return .{ .nodes = nodes, .html_classes = outer.html_classes };
}

// This proves absence of every potentially applicable embedded rule, including
// inherited effects. It does not select declarations or reinterpret selectors.
fn missingEmbeddedStyleNoninterference(a: A, styles: *const profile.Profile, path: ObservedPaintPath) A.Error!bool {
    if (path.nodes.len == 0 or path.nodes.len > 256 or !std.ascii.eqlIgnoreCase(path.nodes[0].tag, "html")) return false;
    var classes: std.ArrayList(u8) = .empty;
    defer classes.deinit(a);
    for (path.nodes, 0..) |node, index| {
        const own_classes = if (index == 0) path.html_classes else node.attributes.get("class") orelse "";
        if (node.attributes.get("style") != null or profile.Profile.hasClass(own_classes, "notheme") or
            profile.Profile.hasClass(own_classes, "skin-invert")) return false;
        appendOuterClasses(a, &classes, own_classes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
    }
    const elements = try a.alloc(profile.TextElement, path.nodes.len);
    defer a.free(elements);
    for (path.nodes, elements, 0..) |*node, *element, index| element.* = .{
        .tag = node.tag,
        .classes = if (index == 0) path.html_classes else node.attributes.get("class") orelse "",
        .id = node.attributes.get("id") orelse "",
        .typeof_tokens = node.attributes.get("typeof") orelse "",
        .language = node.attributes.get("lang"),
        .attribute_presence = .{ .ctx = &node.attributes, .get = Inventory.presence },
        .parent = if (index == 0) null else &elements[index - 1], .physical_ancestry_complete = true,
        .complete_ancestor_classes = classes.items,
        .ancestry_complete = true,
    };
    for (elements) |*element| {
        const matches = try styles.containerRuleMatchesIn(a, element);
        defer a.free(matches.rules);
        if (matches.unresolved or matches.rules.len != 0) return false;
    }
    return true;
}

fn observedImages(a: A, ns: *const namespaces.Registry, html: []const u8, occurrences: []const RawOccurrence) ![]const ObservedImage {
    return observedImagesWithPaintContext(a, ns, html, occurrences, null);
}
fn observedImagesWithPaintContext(a: A, ns: *const namespaces.Registry, html: []const u8, occurrences: []const RawOccurrence, paint_outer: ?ObservedOuterContext) ![]const ObservedImage {
    return observedImagesWithServedPaint(a, ns, html, occurrences, paint_outer, null, false);
}
fn observedImagesWithServedPaint(a: A, ns: *const namespaces.Registry, html: []const u8, occurrences: []const RawOccurrence,
    paint_outer: ?ObservedOuterContext, served_profile: ?*const profile.Profile, require_served_proof: bool) ![]const ObservedImage {
    return observedImagesWithServedPaintFailure(a, ns, html, occurrences, paint_outer, served_profile, require_served_proof, null);
}
fn observedImagesWithServedPaintFailure(a: A, ns: *const namespaces.Registry, html: []const u8, occurrences: []const RawOccurrence,
    paint_outer: ?ObservedOuterContext, served_profile: ?*const profile.Profile, require_served_proof: bool, failure: ?*?MissingPaintFailure) ![]const ObservedImage {
    var stack: [128]ObservedOpenNode = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    var embedded_styles = false;
    var external_styles = false;
    var embedded_sources: std.ArrayList(profile.Source) = .empty;
    defer embedded_sources.deinit(a);
    const paint_paths = try a.alloc(?ObservedPaintPath, occurrences.len);
    defer a.free(paint_paths);
    @memset(paint_paths, null);
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
        for ([_][]const u8{ "div", "span", "bdi", "a", "figure", "figcaption", "img", "meta", "link", "style",
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
            "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "pre", "font", "center", "audio", "source", "mark", "ruby", "rp", "rt" }) |name|
            if (tag.is(name)) { ordinary_tag = true; break; };
        if (!ordinary_tag or ((tag.self_closing or (tag.end >= 2 and html[tag.end - 2] == '/')) and !is_void)) return invalid;
        try observedRubyOpening(stack[0..depth], tag, inv);
        try observedCenterOpening(stack[0..depth], tag);
        try observedBdiOpening(stack[0..depth], tag);
        // STYLE is an HTML raw-text element. Its complete bytes stay in the
        // retained response, but cannot create an observed image or anchor.
        if (tag.is("style")) {
            embedded_styles = true;
            const close = std.mem.indexOfPos(u8, html, tag.end, "</style>") orelse return invalid;
            if (paint_outer != null) try embedded_sources.append(a, .{ .css = html[tag.end..close], .base_url = "", .byte_start = tag.end });
            at = close + "</style>".len;
            continue;
        }
        if (tag.is("link")) {
            var rels = std.mem.tokenizeAny(u8, inv.get("rel") orelse "", " \t\r\n\x0c");
            while (rels.next()) |rel| if (std.ascii.eqlIgnoreCase(rel, "stylesheet")) { embedded_styles = true; external_styles = true; };
        }
        if (tag.is("a")) {
            if (inv.get("href")) |href| for (occurrences, 0..) |occurrence, index| {
                const identity = if (occurrence.svg_language != null or occurrence.resolved_svg_language != null)
                    try svgLanguageFileIdentity(a, ns, href)
                else try fileHref(a, ns, href);
                if (identity) |file| if (equal(file, occurrence.canonical_file)) { anchors[index] += 1; };
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
                    if (observed.paint_root_proven) {
                        if (paint_outer) |outer| {
                            paint_paths[index] = try missingPaintPath(a, outer, stack[0..depth], tag, inv);
                        }
                    }
                    images[index] += 1;
                    selected[index] = .{ .width = 0, .anchor = anchor, .missing_content = observed };
                }
            }
        }
        // This separately authenticated terminal shape is deliberately narrow:
        // complete root > Figure > 3D wrapper > source anchor > one PNG image.
        // The wrapper is not discarded when the compiler later resolves style.
        if (tag.is("img") and depth == 4 and stack[3].tag.is("a") and stack[2].tag.is("span") and stack[1].tag.is("figure") and stack[0].tag.is("div")) {
            const anchor = stack[3].attributes;
            if (anchor.get("href")) |href| if (try fileHref(a, ns, href)) |file| for (occurrences, 0..) |occurrence, index| {
                if (!occurrence.static_poster or !equal(file, occurrence.canonical_file)) continue;
                const root = stack[0].attributes; const figure = stack[1].attributes; const wrapper = stack[2].attributes;
                if (root.attributes.len != 3 or !equal(root.get("class") orelse "", "mw-content-ltr mw-parser-output") or
                    !equal(root.get("lang") orelse "", ns.content_language) or !equal(root.get("dir") orelse "", "ltr") or
                    figure.attributes.len != 2 or !equal(figure.get("class") orelse "", "mw-default-size") or !equal(figure.get("typeof") orelse "", "mw:File/Thumb") or
                    wrapper.attributes.len != 2 or !equal(wrapper.get("class") orelse "", "mw-3d-wrapper") or
                    anchor.attributes.len != 2 or !equal(anchor.get("class") orelse "", "mw-file-description") or
                    !equal(inv.get("class") orelse "", "mw-file-element") or
                    try positiveAttribute(inv, "data-file-width") != occurrence.original_width or try positiveAttribute(inv, "data-file-height") != occurrence.original_height) return invalid;
                const label = wrapper.get("data-label") orelse return invalid;
                for (inv.attributes) |attr| {
                    var known = false;
                    for ([_][]const u8{ "src", "decoding", "loading", "width", "height", "class", "srcset", "data-file-width", "data-file-height", "alt", "title" }) |name|
                        if (std.ascii.eqlIgnoreCase(attr.name, name)) { known = true; break; };
                    if (!known) return invalid;
                }
                const src = inv.get("src") orelse return invalid;
                try imageSource(a, ns, src, occurrence.canonical_file);
                const end = std.mem.indexOfScalar(u8, src, '?') orelse src.len;
                if (!std.mem.endsWith(u8, src[0..end], ".stl.png")) return invalid;
                const width = try positiveAttribute(inv, "width");
                if (try positiveAttribute(inv, "height") != encoder.presentation_types.staticPosterHeight(width)) return invalid;
                // No text, whitespace, extra child, or repaired close may change
                // the wrapper's inline formatting box around this one image.
                if (stack[1].tag.end != stack[2].start or stack[2].tag.end != stack[3].start or stack[3].tag.end != at) return invalid;
                var closing = tag.end;
                for ([_][]const u8{"a", "span"}) |name| {
                    const close = syntax.tagAt(html, closing) orelse return invalid;
                    if (!close.closing or !equal(close.name, name) or close.attrs.len != 0) return invalid;
                    closing = close.end;
                }
                const caption = syntax.tagAt(html, closing) orelse return invalid;
                if (caption.closing or !caption.is("figcaption") or caption.attrs.len != 0) return invalid;
                const caption_end = std.mem.indexOfPos(u8, html, caption.end, "</figcaption>") orelse return invalid;
                const frame_close = syntax.tagAt(html, caption_end + "</figcaption>".len) orelse return invalid;
                if (!frame_close.closing or !frame_close.is("figure") or frame_close.attrs.len != 0) return invalid;
                images[index] += 1;
                selected[index] = .{ .width = width, .anchor = anchor, .poster_label = label };
            };
        }
        if (tag.is("img") and depth >= 2 and stack[depth - 1].tag.is("a") and stack[depth - 2].tag.is("figure")) {
            const anchor = stack[depth - 1].attributes;
            if (anchor.get("href")) |href| for (occurrences, 0..) |occurrence, index| {
                const file = (try svgLanguageFileHref(a, ns, href, occurrence.svg_language)) orelse continue;
                if (!equal(file, occurrence.canonical_file)) continue;
                if (occurrence.missing_content) return invalid;
                const explicit_svg_width = occurrence.width and occurrence.svg_language != null and occurrence.resolved_svg_language == null;
                const class_value = stack[depth - 2].attributes.get("class");
                const figure_classes = class_value orelse if (explicit_svg_width) "" else return invalid;
                const centered_default_size = equal(figure_classes, "mw-default-size mw-halign-center");
                const explicit_centered = equal(figure_classes, "mw-halign-center");
                const centered = explicit_centered or centered_default_size;
                const height_right = occurrence.height and equal(figure_classes, "mw-halign-right");
                const right_default_size = occurrence.width and !occurrence.height and !occurrence.anchor_attributes and
                    occurrence.svg_language == null and occurrence.resolved_svg_language == null and
                    equal(figure_classes, "mw-default-size mw-halign-right");
                if (!equal(stack[depth - 2].attributes.get("typeof") orelse return invalid, "mw:File/Thumb") or
                    (!equal(figure_classes, "mw-default-size") and
                        !(explicit_centered and occurrence.anchor_attributes and !occurrence.width) and
                        !(centered_default_size and occurrence.width) and !height_right and !right_default_size and
                        !(explicit_svg_width and class_value == null)) or
                    !equal(anchor.get("class") orelse return invalid, "mw-file-description") or
                    try positiveAttribute(inv, "data-file-width") != occurrence.original_width or try positiveAttribute(inv, "data-file-height") != occurrence.original_height) return invalid;
                if (occurrence.height and (!height_right or !equal(inv.get("class") orelse "", "mw-file-element") or inv.get("style") != null)) return invalid;
                for (anchor.attributes) |attr| if (!equal(attr.name, "href") and !equal(attr.name, "class") and !equal(attr.name, "rel") and !equal(attr.name, "title")) return invalid;
                for (stack[depth - 2].attributes.attributes) |attr| if (!equal(attr.name, "class") and !equal(attr.name, "typeof")) return invalid;
                try imageSource(a, ns, inv.get("src") orelse return invalid, occurrence.canonical_file);
                if (occurrence.svg_language orelse occurrence.resolved_svg_language) |language| {
                    if ((if (explicit_svg_width) class_value != null else !equal(figure_classes, "mw-default-size")) or
                        !equal(inv.get("class") orelse "", "mw-file-element") or inv.get("style") != null) return invalid;
                    try svgLanguageRasterSource(a, ns, inv.get("src") orelse return invalid, occurrence.canonical_file, language);
                    if (inv.get("srcset")) |srcset| try svgLanguageRasterSourceSet(a, ns, srcset, occurrence.canonical_file, language);
                }
                const image_classes = inv.get("class") orelse return invalid;
                if (!equal(image_classes, "mw-file-element") and !equal(image_classes, "mw-file-element mw-file-upright")) return invalid;
                if ((centered_default_size or right_default_size) and (!equal(image_classes, "mw-file-element mw-file-upright") or inv.get("style") == null)) return invalid;
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
                selected[index] = .{ .width = width, .height = height, .svg_language = occurrence.svg_language orelse occurrence.resolved_svg_language, .element = inv, .anchor = anchor, .centered = centered, .centered_default_size = centered_default_size, .right_default_size = right_default_size };
            };
        }
        if (!is_void) {
            if (depth == stack.len) return invalid;
            stack[depth] = .{ .tag = tag, .attributes = inv, .start = at }; depth += 1;
        }
        at = tag.end;
    }
    if (depth != 0) return invalid;
    for (anchors, images) |anchor_count, image_count| if (anchor_count != 1 or image_count != 1) return invalid;
    if (embedded_styles) {
        var embedded_profile: ?profile.Profile = null;
        defer if (embedded_profile) |*styles| styles.deinit();
        if (paint_outer != null and !external_styles) {
            embedded_profile = profile.parseSourcesAlloc(a, embedded_sources.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        for (selected, paint_paths) |*image, path| {
            if (image.missing_content) |*missing| {
                missing.paint_root_proven = if (missing.paint_root_proven and path != null)
                    if (embedded_profile) |*styles| try missingEmbeddedStyleNoninterference(a, styles, path.?) else false
                else false;
            }
        }
    }
    if (require_served_proof) for (selected, paint_paths, 0..) |*image, path, occurrence_index| {
        if (image.missing_content) |*missing| {
            missing.paint_root_proven = if (missing.paint_root_proven and path != null)
                if (served_profile) |styles| try missingServedStyleNoninterferenceWithFailure(a, styles, path.?, failure, occurrence_index) else false
            else false;
        }
    };
    if (embedded_styles or external_styles) for (selected) |image| {
        if (image.poster_label != null) return invalid;
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
        return std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false });
    }
};

test "supplied Figure Book accepts complete encoded forms through the exact 256 KiB boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "it");
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    const defaults = Testing.hash(@embedFile("testdata/figure-page-observations/it/figure-siteinfo.raw.json"));
    const original_source = try Testing.source(a, doc);
    const original_html = try Testing.html(a, doc);
    for ([_]usize{ 65536, 65537, 98608, 131072, 131073, 131913, 262144 }) |form_size| {
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
        var page = try FormIntakeTest.padded(a, if (case == 1) 262145 else 98608);
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
    // Prove the same typed serialization is valid before testing each mutation.
    var baseline = try Book.init(a, try std.json.Stringify.valueAlloc(a, original, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250);
    defer baseline.deinit();
    try std.testing.expectEqual(original.pages.len, baseline.pages.len);
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
            Book.init(std.testing.allocator, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
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
            Book.init(std.testing.allocator, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
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
    var book = try Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250); defer book.deinit();
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
        try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
    doc.schema = "wikidict.figure-page-observations.v4";
    pages[0].text_class_scope = false;
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    var legacy = try Testing.document(a, "it"); legacy.schema = "wikidict.figure-page-observations.v4";
    var no_scope = try Book.init(a, try std.json.Stringify.valueAlloc(a, legacy, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250); defer no_scope.deinit();
    const unbound = (try no_scope.select(a, &ns, 0, 4075, 3935048, "poliziotto", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(unbound.text_class_scope == null and unbound.text_class_scope_source == null);
    // A changed form is still rejected before any certificate.
    pages[0].text_class_scope = true;
    pages[0].form_body = try std.mem.concat(a, u8, &.{ pages[0].form_body, "&useskin=other" });
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
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
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &empty_files, defaults, 250));
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
const ObservedOuterContext = struct {
    classes: []const u8,
    ancestors: []const OuterObservedNode,
    html_classes: []const u8,
};
fn observedOuterClasses(a: A, ns: *const namespaces.Registry, page: RawPage, outer: RawOuterContext, scope: profile.BoundedTextClassScope) ![]const u8 {
    return (try observedOuterContext(a, ns, page, outer, scope)).classes;
}
fn observedOuterContext(a: A, ns: *const namespaces.Registry, page: RawPage, outer: RawOuterContext, scope: profile.BoundedTextClassScope) !ObservedOuterContext {
    const expected_generator: []const u8 = if (equal(outer.profile, "mediawiki-vector-2022-1.48.0-wmf.3"))
        "MediaWiki 1.48.0-wmf.3"
    else if (equal(outer.profile, "mediawiki-vector-2022-1.48.0-wmf.4"))
        "MediaWiki 1.48.0-wmf.4"
    else return invalid;
    if (!page.text_class_scope or outer.receipt.len == 0 or outer.receipt.len > 64 * 1024) return invalid;
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
    if (!equal(supplied.generator, expected_generator) or !equal(observed.generator, supplied.generator) or observed.ancestors.len != 8) return invalid;
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
    var html_classes: std.ArrayList(u8) = .empty;
    errdefer html_classes.deinit(a);
    try appendOuterClasses(a, &html_classes, observed.ancestors[0].attributes.get("class") orelse "");
    try appendOuterClasses(a, &html_classes, supplied.ancestors[0].attributes.get("class") orelse "");
    return .{ .classes = try result.toOwnedSlice(a), .ancestors = observed.ancestors, .html_classes = try html_classes.toOwnedSlice(a) };
}

// Keep the complete source class census even when the next ordinary quoted
// attribute starts immediately. This recognizes boundaries only; it neither
// skips later class spellings nor grants any computed attribute/style value.
fn adjacentQuotedSourceAttributes(source: []const u8, start: usize) bool {
    var cursor = start;
    var count: usize = 0;
    while (cursor < source.len) {
        if (std.ascii.isWhitespace(source[cursor]) or std.mem.indexOfScalar(u8, ">/|!", source[cursor]) != null) return count != 0;
        if (count == 64) return false;
        const name = cursor;
        while (cursor < source.len and attributeNameByte(source[cursor])) : (cursor += 1) {}
        if (cursor == name) return false;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == source.len or source[cursor] != '=') return false;
        cursor += 1;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == source.len or (source[cursor] != '\'' and source[cursor] != '"')) return false;
        const quote = source[cursor];
        cursor += 1;
        while (cursor < source.len and source[cursor] != quote) : (cursor += 1) {
            if (std.mem.indexOfScalar(u8, "<>{}\x00", source[cursor]) != null) return false;
        }
        if (cursor == source.len) return false;
        cursor += 1;
        count += 1;
    }
    return count != 0;
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
                std.mem.indexOfScalar(u8, ">/|!", source[cursor]) == null and
                !adjacentQuotedSourceAttributes(source, cursor)) {
                diagnostics.logLine("figure observation source-class refused phase=quoted_attribute_boundary source_offset={d} class_offset={d} following_byte=0x{x}", .{ cursor, at, source[cursor] });
                return invalid;
            }
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
        const rooted = try std.mem.concat(a, u8, &.{ "<div class=\"mw-content-ltr mw-parser-output\" lang=\"th\" dir=\"ltr\">", html, "</div>" });
        const scope = try observedTextClassScope(a, &ns, rooted);
        try std.testing.expectEqualStrings("div", scope.root_tag);
        try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", scope.root_classes);
        try std.testing.expect(profile.Profile.hasClass(scope.subtree_classes, "mw-broken-media"));
        if (std.mem.indexOf(u8, sibling, "jouyou-reading") != null)
            try std.testing.expect(profile.Profile.hasClass(scope.subtree_classes, "jouyou-reading"));
        if (std.mem.indexOf(u8, sibling, "class=\"new\"") != null)
            try std.testing.expect(profile.Profile.hasClass(scope.subtree_classes, "new"));
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
        const rooted = try std.mem.concat(a, u8, &.{ "<div class=\"mw-content-ltr mw-parser-output\" lang=\"th\" dir=\"ltr\">", html, "</div>" });
        try std.testing.expectError(invalid, observedTextClassScope(a, &ns, rooted));
    }
    for ([_][]const u8{
        "<mark class=\"first\" class=\"second\">text</mark>",
        "<mark onclick=\"change()\">text</mark>",
        "<ruby>base<rp>(</rp><rt><a href=\"/wiki/Reading\" onclick=\"change()\">reading</a></rt><rp>)</rp></ruby>",
        "<mark />", "<mark>unclosed", "<template><mark>inert</mark></template>",
    }) |refused_scope| {
        const rooted = try std.mem.concat(a, u8, &.{ "<div class=\"mw-content-ltr mw-parser-output\" lang=\"th\" dir=\"ltr\">", refused_scope, figure, "</div>" });
        try std.testing.expectError(invalid, observedTextClassScope(a, &ns, rooted));
    }
    const duplicate_anchor = try std.mem.concat(a, u8, &.{ "<ruby>base<rp>(</rp><rt><a href=\"/wiki/File:Absent.png\">duplicate</a></rt><rp>)</rp></ruby>", figure });
    try std.testing.expectError(invalid, observedImages(a, &ns, duplicate_anchor, &.{occurrence}));
    const borrowed_image = try std.mem.concat(a, u8, &.{ "<ruby>base<rp>(</rp><rt>", figure, "</rt><rp>)</rp></ruby>" });
    try std.testing.expectError(invalid, observedImages(a, &ns, borrowed_image, &.{occurrence}));
    const double_figure = try std.mem.concat(a, u8, &.{ figure, figure });
    try std.testing.expectError(invalid, observedImages(a, &ns, double_figure, &.{occurrence}));
}

const MissingServedTesting = if (@import("builtin").is_test) struct {
    const fixture = @embedFile("testdata/figure-page-observations/ku-missing-served-set/figure-page-observations.json");
    const namespace = @embedFile("testdata/figure-page-observations/ku-missing-served-set/namespace-registry.tsv");
    fn document(a: A) !Document {
        return std.json.parseFromSliceLeaky(Document, a, fixture, .{ .allocate = .alloc_always });
    }
    fn page(doc: Document, id: u64) !RawPage {
        var found: ?RawPage = null;
        for (doc.pages) |item| if (item.page_id == id) { if (found != null) return error.TestUnexpectedResult; found = item; };
        return found orelse return error.TestUnexpectedResult;
    }
    fn context(a: A, ns: *const namespaces.Registry, selected: RawPage) !ObservedOuterContext {
        const supplied = try responseSource(a, ns, selected);
        const scope = try observedTextClassScope(a, ns, supplied.html);
        return observedOuterContext(a, ns, selected, selected.outer_context orelse return error.TestUnexpectedResult, scope);
    }
    fn changedSet(a: A, original: MissingLinkStyles, index: usize, body: []const u8) !MissingLinkStyles {
        var changed = original;
        var served = changed.served_set orelse return error.TestUnexpectedResult;
        const responses = try a.dupe([]const u8, served.responses);
        responses[index] = body;
        const receipt = try json(a, served.receipt);
        const sources = receipt.object.getPtr("sources") orelse return error.TestUnexpectedResult;
        const source = &sources.array.items[index];
        try source.object.put(a, "bytes", .{ .integer = @intCast(body.len) });
        const hash = std.fmt.bytesToHex(Testing.hash(body), .lower);
        try source.object.put(a, "sha256", .{ .string = try a.dupe(u8, &hash) });
        served.responses = responses;
        served.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
        changed.served_set = served;
        return changed;
    }
    fn diagnosePaint(a: A, ns: *const namespaces.Registry, candidate_page: RawPage, outer: ?ObservedOuterContext, served: ValidatedMissingSet) void {
        std.debug.print("Missing paint positive page={d} revision={d} outer_nodes={d}\n", .{ candidate_page.page_id, candidate_page.revision_id, if (outer) |value| value.ancestors.len else 0 });
        const supplied = responseSource(a, ns, candidate_page) catch |err| { std.debug.print("  source error={s}\n", .{@errorName(err)}); return; };
        const before_served = observedImagesWithServedPaint(a, ns, supplied.html, candidate_page.occurrences, outer, null, false) catch |err| { std.debug.print("  embedded proof error={s}\n", .{@errorName(err)}); return; };
        for (before_served, 0..) |image, index| if (image.missing_content) |missing_value| {
            std.debug.print("  occurrence={d} before_served_paint={any} width={d} label={s}\n", .{ index, missing_value.paint_root_proven, missing_value.data_width, missing_value.label });
        };
        var css = missingServedProfile(a, ns, candidate_page, served) catch |err| { std.debug.print("  served profile error={s}\n", .{@errorName(err)}); return; };
        defer if (css) |*value| value.deinit();
        if (css) |*value| {
            std.debug.print("  served profile present global_unknown={any} sources={d}\n", .{ value.globally_unresolved, value.sources.len });
            var failure: ?MissingPaintFailure = null;
            _ = observedImagesWithServedPaintFailure(a, ns, supplied.html, candidate_page.occurrences, outer, value, true, &failure) catch |err| {
                std.debug.print("  first blocker lookup error={s}\n", .{@errorName(err)}); return;
            };
            if (failure) |first| {
                std.debug.print("  first blocker occurrence={any} node={d} tag={s} classes={s} reason={s}\n", .{ first.occurrence_index, first.node_index, first.tag, first.classes, @tagName(first.blocker.reason) });
                if (first.blocker.rule) |rule| {
                    std.debug.print("    match={s} viewport={any} rank_unknown={any} order={d} declaration={s}\n", .{ @tagName(rule.match), rule.viewport, rule.rank_unknown, rule.order, first.blocker.declaration });
                    if (rule.provenance) |origin| {
                        std.debug.print("    selector={s} source={d} declaration_byte={d}\n", .{ origin.selector, origin.source_index, origin.css_byte_start + first.blocker.declaration_offset });
                        for (origin.conditions) |condition| std.debug.print("    condition={s}\n", .{condition});
                        if (origin.source_index < value.sources.len) {
                            const source = value.sources[origin.source_index];
                            std.debug.print("    url={s} segment_start={d} segment_bytes={d} segment_sha256={s}\n", .{ source.base_url, source.byte_start, source.bytes, source.css_sha256 });
                        }
                    }
                }
            } else std.debug.print("  no declaration blocker captured; preserve prior structural refusal\n", .{});
        } else std.debug.print("  served profile unavailable\n", .{});
    }
    fn missing(a: A, ns: *const namespaces.Registry, selected: RawPage, outer: ?ObservedOuterContext, styles: ?*const profile.Profile) !ObservedImage {
        const supplied = try responseSource(a, ns, selected);
        const images = try observedImagesWithServedPaint(a, ns, supplied.html, selected.occurrences, outer, styles, true);
        try std.testing.expectEqual(@as(usize, 1), images.len);
        return images[0];
    }
} else struct {};

test "retained KU Missing paint binds complete ordered served set and exact outer source without changing other pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, MissingServedTesting.namespace); defer ns.deinit();
    const doc = try MissingServedTesting.document(a);
    try missingStyleShape(try std.json.parseFromSliceLeaky(Value, a, MissingServedTesting.fixture, .{}), true);
    const styles = doc.missing_link_styles orelse return error.TestUnexpectedResult;
    const served = try missingObservedSet(a, styles, ns.wiki, Testing.hash(styles.defaults));
    try std.testing.expectEqual(@as(usize, 6), served.responses.len);
    try std.testing.expectEqualStrings("", served.responses[2]);
    try std.testing.expectEqualStrings(served.responses[4], served.responses[5]);
    try std.testing.expect(!equal(served.urls[4], served.urls[5]));
    const page = try MissingServedTesting.page(doc, 5048);
    const selected = try missingHeadSources(a, &ns, page, served);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, selected);
    const supplied = try responseSource(a, &ns, page);
    try std.testing.expectEqual(@as(usize, 36981), supplied.source.len);
    try std.testing.expect(digestMatches(supplied.source, "cd317b5033d63b97151a95c05d05280574e14b601ff55d9ac065a986567934e5"));
    try std.testing.expectEqual(@as(usize, 90599), supplied.html.len);
    try std.testing.expect(digestMatches(supplied.html, "db39a439eff6f26ca3ad88bd7fcb74b03963cf4db54d7c0e4384b6f7be83e85f"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, supplied.html, "<style "));
    const outer = try MissingServedTesting.context(a, &ns, page);
    try std.testing.expectEqual(@as(usize, 8), outer.ancestors.len);
    var css = (try missingServedProfile(a, &ns, page, served)) orelse return error.TestUnexpectedResult; defer css.deinit();
    try std.testing.expectEqual(@as(usize, 4), css.sources.len);
    try std.testing.expectEqualStrings(served.urls[0], css.sources[0].base_url);
    try std.testing.expectEqual(@as(usize, 52397), css.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 142994), css.sources[1].byte_start);
    try std.testing.expectEqualStrings(served.urls[1], css.sources[2].base_url);
    try std.testing.expectEqualStrings(served.urls[2], css.sources[3].base_url);
    const image = try MissingServedTesting.missing(a, &ns, page, outer, &css);
    const missing = image.missing_content orelse return error.TestUnexpectedResult;
    if (!missing.paint_root_proven) MissingServedTesting.diagnosePaint(a, &ns, page, outer, served);
    try std.testing.expect(missing.paint_root_proven and !missing.right and !missing.default_size);
    try std.testing.expectEqual(@as(u32, 250), missing.data_width);
    try std.testing.expectEqual(@as(u32, 0), image.width);
    try std.testing.expect(std.mem.indexOf(u8, supplied.html, "<figure typeof=\"mw:Error mw:File/Thumb\">") != null);
    try std.testing.expect(missing.element.get("src") == null and missing.element.get("width") == null and missing.element.get("height") == null);
    try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, missing.label);
    try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?uselang=ku&wpDestFile=Arap_Shamilov_(2).Jpeg", missing.href);
    try std.testing.expect(std.mem.indexOf(u8, supplied.html, "<figcaption>Yekem romannivîsê kurd Erebê Şemo, bi navê xwe yê fermî Arab Şamîlov</figcaption>") != null);
    const prior = try std.json.parseFromSliceLeaky(Document, a, @embedFile("testdata/figure-page-observations/ku-missing-served-set/prior-v2.json"), .{});
    try std.testing.expectEqual(@as(usize, 3), doc.pages.len);
    var occurrence_count: usize = 0;
    for (prior.pages) |old| {
        const current = try MissingServedTesting.page(doc, old.page_id);
        occurrence_count += current.occurrences.len;
        try std.testing.expectEqualDeep(old.occurrences, current.occurrences);
        if (old.page_id != 5048) try std.testing.expectEqualDeep(old, current);
    }
    try std.testing.expectEqual(@as(usize, 5), occurrence_count);
    const unproved = try MissingServedTesting.missing(a, &ns, page, null, &css);
    try std.testing.expect(!unproved.missing_content.?.paint_root_proven);
    const appendix = try MissingServedTesting.page(doc, 53658);
    try std.testing.expect(appendix.outer_context == null);
    const untouched = try MissingServedTesting.missing(a, &ns, appendix, null, &css);
    try std.testing.expect(!untouched.missing_content.?.paint_root_proven and untouched.missing_content.?.right);
    try std.testing.expectEqual(@as(u32, 500), untouched.missing_content.?.data_width);
    // This exercises authenticated intake and paint proof. Registry identity,
    // the normal Writer and complete page rendering remain independent controls.
}

test "observed Missing served set preserves paint refusals for matching unknown and inherited declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, MissingServedTesting.namespace); defer ns.deinit();
    const doc = try MissingServedTesting.document(a); const page = try MissingServedTesting.page(doc, 5048);
    const styles = doc.missing_link_styles.?; const outer = try MissingServedTesting.context(a, &ns, page);
    // Controlled reauthenticated contrasts, never asserted to be served bytes.
    for ([_][]const u8{
        "a.new{color:red}", "body{color:red}", ":root{--color-destructive:red}",
        "a.new:future-pseudo{outline:0}", "a:nth-child(2){text-decoration:none}",
        "@media (unknown-feature:1){a.new{color:red}}", "@layer surprise{a.new{color:red}}",
        "@import url(unknown.css);", "a.new{all:initial}", "a.new{font-size:2em}",
    }) |added| {
        errdefer std.debug.print("served Missing refusal declaration: {s}\n", .{added});
        const changed = try MissingServedTesting.changedSet(a, styles, 2, added);
        const served = try missingObservedSet(a, changed, ns.wiki, Testing.hash(styles.defaults));
        var css = try missingServedProfile(a, &ns, page, served); defer if (css) |*p| p.deinit();
        const image = try MissingServedTesting.missing(a, &ns, page, outer, if (css) |*p| p else null);
        const missing = image.missing_content orelse return error.TestUnexpectedResult;
        try std.testing.expect(!missing.paint_root_proven);
        try std.testing.expectEqual(@as(u32, 250), missing.data_width);
        try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, missing.label);
        try std.testing.expect(std.mem.startsWith(u8, missing.href, "//commons.wikimedia.org/wiki/Special:UploadWizard?"));
    }
    // Removing the relevant own attribute remains a refusal-only proof; it
    // does not turn present or unknown role values into selector authority.
    const irrelevant = try MissingServedTesting.changedSet(a, styles, 2, ".absent-page-class a.new{color:red}a[role=button]{color:red}");
    const served = try missingObservedSet(a, irrelevant, ns.wiki, Testing.hash(styles.defaults));
    var css = (try missingServedProfile(a, &ns, page, served)) orelse return error.TestUnexpectedResult; defer css.deinit();
    const positive = (try MissingServedTesting.missing(a, &ns, page, outer, &css)).missing_content.?;
    if (!positive.paint_root_proven) MissingServedTesting.diagnosePaint(a, &ns, page, outer, served);
    try std.testing.expect(positive.paint_root_proven);
}

test "observed Missing style identity module boundaries and mismatched actual outer context remain refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, MissingServedTesting.namespace); defer ns.deinit();
    const doc = try MissingServedTesting.document(a); const page = try MissingServedTesting.page(doc, 5048);
    const styles = doc.missing_link_styles.?; const original = styles.served_set.?;
    const selected_set = try missingObservedSet(a, styles, ns.wiki, Testing.hash(styles.defaults));
    for ([_][]const u8{ "https://other.example/", "//other.example/", "" }) |base_href| {
        var changed = page;
        const response = try json(a, page.response);
        const parsed = response.object.getPtr("parse") orelse return error.TestUnexpectedResult;
        const head = try string(parsed.*, "headhtml");
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "</head>"));
        const insertion = try std.fmt.allocPrint(a, "<base href=\"{s}\"></head>", .{base_href});
        try parsed.object.put(a, "headhtml", .{ .string = try std.mem.replaceOwned(u8, a, head, "</head>", insertion) });
        changed.response = try std.json.Stringify.valueAlloc(a, response, .{});
        const receipt = try json(a, page.receipt);
        const descriptor_value = receipt.object.getPtr("response") orelse return error.TestUnexpectedResult;
        try descriptor_value.object.put(a, "bytes", .{ .integer = @intCast(changed.response.len) });
        const hash = std.fmt.bytesToHex(Testing.hash(changed.response), .lower);
        try descriptor_value.object.put(a, "sha256", .{ .string = try a.dupe(u8, &hash) });
        changed.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
        _ = try responseSource(a, &ns, changed);
        try std.testing.expectError(invalid, missingHeadSources(a, &ns, changed, selected_set));
    }
    var wrong = styles; const reversed = try a.dupe([]const u8, original.responses);
    std.mem.swap([]const u8, &reversed[0], &reversed[1]); wrong.served_set.?.responses = reversed;
    try std.testing.expectError(invalid, missingObservedSet(a, wrong, ns.wiki, Testing.hash(styles.defaults)));
    try std.testing.expectError(invalid, missingObservedSet(a, styles, "thwiktionary", Testing.hash(styles.defaults)));
    try std.testing.expectError(invalid, missingObservedSet(a, styles, ns.wiki, @as([32]u8, @splat(0))));
    const truncated = try MissingServedTesting.changedSet(a, styles, 0, original.responses[0][0..100]);
    try std.testing.expectError(invalid, missingServedProfile(a, &ns, page, try missingObservedSet(a, truncated, ns.wiki, Testing.hash(styles.defaults))));
    const repeated = try MissingServedTesting.changedSet(a, styles, 0, try std.mem.concat(a, u8, &.{original.responses[0], original.responses[0]}));
    try std.testing.expectError(invalid, missingServedProfile(a, &ns, page, try missingObservedSet(a, repeated, ns.wiki, Testing.hash(styles.defaults))));
    const outer = try MissingServedTesting.context(a, &ns, page);
    for ([_][]const u8{ "@media screen{", "/*", "a{content:\"" }) |prefix| {
        const body = try std.mem.concat(a, u8, &.{prefix, original.responses[0]});
        const changed = try MissingServedTesting.changedSet(a, styles, 0, body);
        var css = try missingServedProfile(a, &ns, page, try missingObservedSet(a, changed, ns.wiki, Testing.hash(styles.defaults)));
        defer if (css) |*p| p.deinit();
        try std.testing.expect(!(try MissingServedTesting.missing(a, &ns, page, outer, if (css) |*p| p else null)).missing_content.?.paint_root_proven);
    }
    const mismatch = try std.json.parseFromSliceLeaky(RawPage, a, @embedFile("testdata/figure-page-observations/ku-missing-served-set/mismatched-53658-page.json"), .{});
    _ = try responseSource(a, &ns, mismatch);
    try std.testing.expectError(invalid, MissingServedTesting.context(a, &ns, mismatch));
    const shape = try std.json.parseFromSliceLeaky(Value, a, MissingServedTesting.fixture, .{});
    const selected = shape.object.getPtr("missing_link_styles") orelse return error.TestUnexpectedResult;
    try selected.object.put(a, "response", .{ .string = "" });
    try std.testing.expectError(invalid, missingStyleShape(shape, true));
}

const ViPageServedTesting = if (@import("builtin").is_test) struct {
    const fixture = @embedFile("testdata/figure-page-observations/vi-page-served-set/figure-page-observations.json");
    const prior = @embedFile("testdata/figure-page-observations/vi-page-served-set/prior-v4.json");
    const namespace = @embedFile("testdata/figure-page-observations/vi-page-served-set/namespace-registry.tsv");
    fn document(a: A, bytes: []const u8) !Document { return std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }); }
    fn shape(a: A, index: usize) !Value {
        const doc = try std.json.parseFromSliceLeaky(Value, a, fixture, .{ .allocate = .alloc_always });
        return (try field(doc, "pages")).array.items[index];
    }
    fn image(a: A, ns: *const namespaces.Registry, doc: Document, page: RawPage, page_shape: Value) !ObservedImage {
        const legacy = doc.missing_link_styles orelse return error.TestUnexpectedResult;
        _ = try missingLinkPaint(a, legacy, doc.wiki, Testing.hash(legacy.defaults));
        const supplied = try responseSource(a, ns, page);
        const served = try pageMissingServedSet(a, doc, page, page_shape, Testing.hash(legacy.defaults), null);
        const outer = if (page.outer_context != null) try MissingServedTesting.context(a, ns, page) else null;
        var styles = if (served) |set| try missingServedProfile(a, ns, page, set) else null;
        defer if (styles) |*p| p.deinit();
        const images = try observedImagesWithServedPaint(a, ns, supplied.html, page.occurrences,
            if (served != null) outer else null, if (styles) |*p| p else null, served != null);
        try std.testing.expectEqual(@as(usize, 1), images.len);
        return images[0];
    }
    fn diagnosePaint(a: A, ns: *const namespaces.Registry, doc: Document, page: RawPage, page_shape: Value) void {
        std.debug.print("VI Missing paint positive page={d} revision={d}\n", .{ page.page_id, page.revision_id });
        const legacy = doc.missing_link_styles orelse return;
        const served = pageMissingServedSet(a, doc, page, page_shape, Testing.hash(legacy.defaults), null) catch |err| { std.debug.print("  supplemental intake error={s}\n", .{@errorName(err)}); return; };
        const set = served orelse { std.debug.print("  legacy proof without page supplement\n", .{}); return; };
        const outer = MissingServedTesting.context(a, ns, page) catch |err| { std.debug.print("  outer proof error={s}\n", .{@errorName(err)}); return; };
        MissingServedTesting.diagnosePaint(a, ns, page, outer, set);
    }
    fn changedResponse(a: A, page: RawPage, key: []const u8, before: []const u8, after: []const u8) !RawPage {
        var result = page;
        const response = try json(a, page.response);
        const parsed = response.object.getPtr("parse") orelse return error.TestUnexpectedResult;
        const original = try string(parsed.*, key);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, original, before));
        try parsed.object.put(a, key, .{ .string = try std.mem.replaceOwned(u8, a, original, before, after) });
        result.response = try std.json.Stringify.valueAlloc(a, response, .{});
        const receipt = try json(a, page.receipt);
        const descriptor_value = receipt.object.getPtr("response") orelse return error.TestUnexpectedResult;
        try descriptor_value.object.put(a, "bytes", .{ .integer = @intCast(result.response.len) });
        const hash = std.fmt.bytesToHex(Testing.hash(result.response), .lower);
        try descriptor_value.object.put(a, "sha256", .{ .string = try a.dupe(u8, &hash) });
        result.receipt = try std.json.Stringify.valueAlloc(a, receipt, .{});
        return result;
    }
} else struct {};

test "VI page Missing supplements preserve all eleven source domains and six legacy paint proofs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, ViPageServedTesting.namespace); defer ns.deinit();
    const doc = try ViPageServedTesting.document(a, ViPageServedTesting.fixture);
    const prior = try ViPageServedTesting.document(a, ViPageServedTesting.prior);
    try std.testing.expectEqual(@as(usize, 11), doc.pages.len);
    try std.testing.expectEqualDeep(prior.missing_link_styles, doc.missing_link_styles);
    try std.testing.expectEqualStrings("vector_new_link_v1", doc.missing_link_styles.?.profile);
    var legacy_count: usize = 0; var supplemented: usize = 0;
    for (doc.pages, prior.pages, 0..) |page, old, index| {
        try std.testing.expectEqualDeep(old.occurrences, page.occurrences);
        if (page.page_id != 43450 and page.page_id != 50098) try std.testing.expectEqualDeep(old, page);
        if (!page.occurrences[0].missing_content) continue;
        const actual = (try ViPageServedTesting.image(a, &ns, doc, page, try ViPageServedTesting.shape(a, index))).missing_content.?;
        if (!actual.paint_root_proven) ViPageServedTesting.diagnosePaint(a, &ns, doc, page, try ViPageServedTesting.shape(a, index));
        try std.testing.expect(actual.paint_root_proven);
        try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, actual.label);
        if (page.page_id == 43450 or page.page_id == 50098) {
            supplemented += 1;
            const supplied = try responseSource(a, &ns, page);
            const expected_source = if (page.page_id == 43450) "91e13a72e0318c5c803ce7e37977e089e3b78717503d766c20c0510fcd4f1187" else "f5c34e6b9ee6d468df5c7763262d41f02116a11ecdb4429646e3721ff297718a";
            const expected_html = if (page.page_id == 43450) "f9b777fdae300dfcc5029227b772c495f9dd01bad834dd7bf7c4d08c5e71b240" else "a5e4138d7dc1622dd537833cec99c8106019690c6e2e652111346e99958c459f";
            try std.testing.expect(digestMatches(supplied.source, expected_source) and digestMatches(supplied.html, expected_html));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, "<style "));
            try std.testing.expect(actual.default_size and !actual.right and actual.data_width == 180);
            try std.testing.expect(actual.element.get("src") == null and actual.element.get("width") == null and actual.element.get("height") == null);
            const expected_href = if (page.page_id == 43450) "//commons.wikimedia.org/wiki/Special:UploadWizard?uselang=vi&wpDestFile=G.F._Knapp.gif" else "//commons.wikimedia.org/wiki/Special:UploadWizard?uselang=vi&wpDestFile=Millennium_simulation_-_galaxies.jpg";
            try std.testing.expectEqualStrings(expected_href, actual.href);
            const set = page.missing_served_set.?;
            try std.testing.expectEqual(@as(usize, 4), set.responses.len);
            const outer = try MissingServedTesting.context(a, &ns, page);
            try std.testing.expectEqual(@as(usize, 8), outer.ancestors.len);
            const old_supplied = try responseSource(a, &ns, old);
            const old_images = try observedImages(a, &ns, old_supplied.html, old.occurrences);
            try std.testing.expect(!old_images[0].missing_content.?.paint_root_proven);
            // A text-class certificate alone cannot replace stylesheet authority.
            var without = page; without.missing_served_set = null;
            var no_shape = try ViPageServedTesting.shape(a, index);
            try std.testing.expect(no_shape.object.swapRemove("missing_served_set"));
            const withheld = try ViPageServedTesting.image(a, &ns, doc, without, no_shape);
            try std.testing.expect(!withheld.missing_content.?.paint_root_proven);
        } else {
            legacy_count += 1;
            const source = try responseSource(a, &ns, old);
            const old_images = try observedImages(a, &ns, source.html, old.occurrences);
            try std.testing.expectEqualDeep(old_images[0].missing_content.?, actual);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), legacy_count);
    try std.testing.expectEqual(@as(usize, 2), supplemented);
    // This is authenticated observation/paint evidence, not FigureRegistry or
    // complete Writer qualification; no missing-file facts are manufactured here.
}

test "VI page Missing supplements reject foreign body source ancestor and ambiguous policy authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, ViPageServedTesting.namespace); defer ns.deinit();
    const doc = try ViPageServedTesting.document(a, ViPageServedTesting.fixture);
    const page = doc.pages[7]; const other = doc.pages[8];
    try std.testing.expect(page.page_id == 43450 and other.page_id == 50098);
    const shape = try ViPageServedTesting.shape(a, 7);
    var wrong = page; wrong.response = other.response; wrong.receipt = other.receipt;
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, wrong, shape));
    wrong = page; wrong.outer_context = other.outer_context;
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, wrong, shape));
    wrong = page; wrong.outer_context.?.response = try std.mem.concat(a, u8, &.{ wrong.outer_context.?.response, "changed" });
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, wrong, shape));
    wrong = page; wrong.outer_context = try OuterContextTesting.replaced(a, page.outer_context.?, "id=\"bodyContent\" class=\"vector-body\"", "id=\"bodyContent\" class=\"foreign-body\"");
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, wrong, shape));
    for ([_][]const u8{ "wikidict.figure-page-observations.v3", "wikidict.figure-page-observations.v5" }) |schema| {
        var changed = doc; changed.schema = schema;
        try std.testing.expectError(invalid, pageMissingServedSet(a, changed, page, shape, Testing.hash(doc.missing_link_styles.?.defaults), null));
    }
    for (0..3) |mode| {
        wrong = page;
        if (mode == 0) wrong.text_class_scope = false;
        if (mode == 1) wrong.outer_context = null;
        if (mode == 2) wrong.occurrences = &.{};
        try std.testing.expectError(invalid, pageMissingServedSet(a, doc, wrong, shape, Testing.hash(doc.missing_link_styles.?.defaults), null));
    }
    const supplied = try ViPageServedTesting.changedResponse(a, page, "wikitext", "G.F. Knapp.gif", "Different.gif");
    try std.testing.expectError(invalid, responseSource(a, &ns, supplied));
    const changed_head = try ViPageServedTesting.changedResponse(a, page, "headhtml", "</head>", "<base href=\"https://other.example/\"></head>");
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, changed_head, shape));
    const set = (try pageMissingServedSet(a, doc, page, shape, Testing.hash(doc.missing_link_styles.?.defaults), null)).?;
    try std.testing.expectError(invalid, pageMissingServedSet(a, doc, page, shape, Testing.hash(doc.missing_link_styles.?.defaults), set));
    var null_shape = try ViPageServedTesting.shape(a, 7);
    try null_shape.object.put(a, "missing_served_set", .null);
    try std.testing.expectError(invalid, pageMissingServedSet(a, doc, page, null_shape, Testing.hash(doc.missing_link_styles.?.defaults), null));
}

test "VI page Missing supplement retains matching inherited and unknown paint refusals per page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, ViPageServedTesting.namespace); defer ns.deinit();
    const doc = try ViPageServedTesting.document(a, ViPageServedTesting.fixture);
    const page = doc.pages[7]; const shape = try ViPageServedTesting.shape(a, 7);
    for ([_][]const u8{ "a.new{color:red}", "body{opacity:.5}", "@media (unknown-feature:yes){a.new{color:red}}", "a.new{--color-destructive:green}", "a.new{all:unset}" }) |css| {
        const wrapper: MissingLinkStyles = .{ .profile = missing_observed_set_profile, .defaults = doc.missing_link_styles.?.defaults, .served_set = page.missing_served_set };
        const changed = try MissingServedTesting.changedSet(a, wrapper, 2, css);
        var mutated = page; mutated.missing_served_set = changed.served_set;
        const image = try ViPageServedTesting.image(a, &ns, doc, mutated, shape);
        try std.testing.expect(!image.missing_content.?.paint_root_proven);
        try std.testing.expectEqual(@as(u32, 180), image.missing_content.?.data_width);
        try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, image.missing_content.?.label);
    }
    var removed = page;
    var set = removed.missing_served_set.?;
    set.responses = set.responses[0..2]; removed.missing_served_set = set;
    try std.testing.expectError(invalid, ViPageServedTesting.image(a, &ns, doc, removed, shape));
    const untouched = try ViPageServedTesting.image(a, &ns, doc, doc.pages[8], try ViPageServedTesting.shape(a, 8));
    if (!untouched.missing_content.?.paint_root_proven) ViPageServedTesting.diagnosePaint(a, &ns, doc, doc.pages[8], try ViPageServedTesting.shape(a, 8));
    try std.testing.expect(untouched.missing_content.?.paint_root_proven);
}


const EmbeddedPaintTesting = if (@import("builtin").is_test) struct {
    fn node(a: A, tag: []const u8, classes: []const u8) !OuterObservedNode {
        const attributes = try a.alloc(Attribute, 1);
        attributes[0] = .{ .name = "class", .value = classes };
        return .{ .tag = tag, .attributes = .{ .attributes = attributes } };
    }
    // Controlled complete ancestry only. It is never a normal Book observation
    // and does not claim that TH's currently held root-only POST has this proof.
    fn controlledOuter(a: A) !ObservedOuterContext {
        const nodes = try a.alloc(OuterObservedNode, 2);
        nodes[0] = try node(a, "html", "skin-theme-clientpref-day");
        nodes[1] = try node(a, "body", "skin-vector-2022");
        return .{ .ancestors = nodes, .html_classes = "skin-theme-clientpref-day", .classes = "skin-theme-clientpref-day skin-vector-2022" };
    }
    fn page(a: A) !RawPage {
        const doc = try std.json.parseFromSliceLeaky(Document, a,
            @embedFile("testdata/figure-page-observations/th-missing-width/figure-page-observations.json"), .{ .allocate = .alloc_always });
        var result: ?RawPage = null;
        for (doc.pages) |value| if (value.page_id == 108817) { try std.testing.expect(result == null); result = value; };
        return result orelse error.TestUnexpectedResult;
    }
} else struct {};

test "embedded missing styles use the existing selector proof over a controlled complete inheritance path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const page = try EmbeddedPaintTesting.page(a);
    const response = try responseSource(a, &ns, page);
    const original = try observedImages(a, &ns, response.html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), original.len);
    try std.testing.expect(!original[0].missing_content.?.paint_root_proven);
    const proved = try observedImagesWithPaintContext(a, &ns, response.html, page.occurrences, try EmbeddedPaintTesting.controlledOuter(a));
    var expected = original[0];
    expected.missing_content.?.paint_root_proven = true;
    try std.testing.expectEqualDeep(expected, proved[0]);
    try std.testing.expect(digestMatches(response.html, "885776131abb832ed18b8b04ea3f3444717170b4f7ed36432917c8fcfee8a9e9"));
    try std.testing.expect(digestMatches(response.source, "2b8290b10c31fd1cf7ba37150dd5bc067098f007b4f15e3efb499ae69624fd07"));
}

test "missing embedded style proof refuses matching inherited uncertain and external rules without dropping content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-width/namespace-registry.tsv")); defer ns.deinit();
    const page = try EmbeddedPaintTesting.page(a);
    const response = try responseSource(a, &ns, page);
    const outer = try EmbeddedPaintTesting.controlledOuter(a);
    const baseline = try observedImages(a, &ns, response.html, page.occurrences);
    for ([_][]const u8{
        "<style>body{color:red}</style>",
        "<style>html{--color-destructive:red}</style>",
        "<style>.mw-parser-output{font-size:200%}</style>",
        "<style>figure{display:none}</style>",
        "<style>a.new{color:red}</style>",
        "<style>.mw-broken-media{font-weight:bold}</style>",
        "<style>a.new:unsupported{color:red}</style>",
        "<style>.new::before{content:'extra'}</style>",
        "<style>@media print{a.new{color:red}}</style>",
        "<style>@layer x{a.new{color:red!important}}</style>",
        "<style>@import url('/unknown.css');</style>",
        "<link rel='stylesheet' href='/unknown.css'>",
    }) |extra| {
        const html = try std.mem.concat(a, u8, &.{ response.html, extra });
        const refused = try observedImagesWithPaintContext(a, &ns, html, page.occurrences, outer);
        try std.testing.expectEqualDeep(baseline[0], refused[0]);
    }
    for ([_][]const u8{ "notheme", "skin-invert", "character-sample" }) |classes| {
        const nodes = try a.dupe(OuterObservedNode, outer.ancestors);
        nodes[1] = try EmbeddedPaintTesting.node(a, "body", classes);
        var changed = outer; changed.ancestors = nodes;
        const refused = try observedImagesWithPaintContext(a, &ns, response.html, page.occurrences, changed);
        try std.testing.expectEqualDeep(baseline[0], refused[0]);
    }
    const nodes = try a.dupe(OuterObservedNode, outer.ancestors);
    const attributes = try a.alloc(Attribute, 2);
    attributes[0] = .{ .name = "class", .value = "skin-vector-2022" };
    attributes[1] = .{ .name = "style", .value = "color:inherit" };
    nodes[1].attributes = .{ .attributes = attributes };
    var changed = outer; changed.ancestors = nodes;
    const refused = try observedImagesWithPaintContext(a, &ns, response.html, page.occurrences, changed);
    try std.testing.expectEqualDeep(baseline[0], refused[0]);
}

test "missing embedded selector proof retains API HTML class possibilities and never fabricates sibling position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const nodes = try a.alloc(OuterObservedNode, 3);
    nodes[0] = try EmbeddedPaintTesting.node(a, "html", "client-nojs");
    nodes[1] = try EmbeddedPaintTesting.node(a, "body", "");
    nodes[2] = try EmbeddedPaintTesting.node(a, "a", "new");
    const path: ObservedPaintPath = .{ .nodes = nodes, .html_classes = "client-nojs client-js" };
    for ([_][]const u8{ "html.client-js{color:red}", "a.new:first-child{color:red}", "a.new:nth-child(2){color:red}", "body .new:not(.other){color:red}" }) |css| {
        var styles = try profile.parseAlloc(a, css); defer styles.deinit();
        try std.testing.expect(!try missingEmbeddedStyleNoninterference(a, &styles, path));
    }
    var unrelated = try profile.parseAlloc(a, ".absent > span:only-child{color:red}"); defer unrelated.deinit();
    try std.testing.expect(try missingEmbeddedStyleNoninterference(a, &unrelated, path));
}

test "observed outer paint context retains the exact previously authenticated wrapper proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const page = OuterContextTesting.page();
    const supplied = try responseSource(a, &ns, page);
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    const outer = OuterContextTesting.outer();
    const old_classes = try observedOuterClasses(a, &ns, page, outer, scope);
    const context = try observedOuterContext(a, &ns, page, outer, scope);
    try std.testing.expectEqualStrings(old_classes, context.classes);
    const captured = try observedOuterPrefix(a, outer.response, true);
    try std.testing.expectEqualDeep(captured.ancestors, context.ancestors);
    const head = try observedOuterPrefix(a, try string(try field(try json(a, page.response), "parse"), "headhtml"), false);
    for ([_]Inventory{ captured.ancestors[0].attributes, head.ancestors[0].attributes }) |attributes| {
        var tokens = std.mem.tokenizeAny(u8, attributes.get("class") orelse "", " \t\r\n\x0c");
        while (tokens.next()) |token| try std.testing.expect(profile.Profile.hasClass(context.html_classes, token));
    }
    var unproved = page; unproved.text_class_scope = false;
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, unproved, outer, scope));
    var wrong = outer; wrong.profile = "mediawiki-vector-2022-1.48.0-wmf.4";
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong, scope));
}


const Wmf4OuterTesting = if (@import("builtin").is_test) struct {
    fn page(a: A) !RawPage {
        const doc = try std.json.parseFromSliceLeaky(Document, a,
            @embedFile("testdata/figure-page-observations/th-missing-outer/figure-page-observations.json"), .{ .allocate = .alloc_always });
        var selected: ?RawPage = null;
        for (doc.pages) |candidate_page| if (candidate_page.page_id == 108817) {
            try std.testing.expect(selected == null);
            selected = candidate_page;
        };
        return selected orelse error.TestUnexpectedResult;
    }
} else struct {};

test "explicit WMF4 wrapper profile preserves the actual TH supplied body and observed outer ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-outer/namespace-registry.tsv")); defer ns.deinit();
    const page = try Wmf4OuterTesting.page(a);
    try std.testing.expectEqual(@as(u64, 2190988), page.revision_id);
    try std.testing.expectEqual(@as(usize, 130509), page.form_body.len);
    const supplied = try responseSource(a, &ns, page);
    try std.testing.expectEqual(@as(usize, 59937), supplied.source.len);
    try std.testing.expectEqual(@as(usize, 96208), supplied.html.len);
    try std.testing.expect(digestMatches(supplied.source, "2b8290b10c31fd1cf7ba37150dd5bc067098f007b4f15e3efb499ae69624fd07"));
    try std.testing.expect(digestMatches(supplied.html, "9e92a178b66dd0dd720e69dedc48f35b70f5443bccde5b96ef4bc249cd6de8ca"));
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    const outer = page.outer_context orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 287587), outer.response.len);
    try std.testing.expect(digestMatches(outer.response, "af0e5cf81a6060a252b0f85eee03d87a2e14f2de03901dbac38d623de4c84024"));
    const context = try observedOuterContext(a, &ns, page, outer, scope);
    const tags = [_][]const u8{ "html", "body", "div", "div", "div", "main", "div", "div" };
    try std.testing.expectEqual(tags.len, context.ancestors.len);
    for (context.ancestors, tags) |node, tag| try std.testing.expectEqualStrings(tag, node.tag);
    for ([_][]const u8{ "client-nojs", "skin-theme-clientpref-day", "skin-vector-2022", "skin--responsive", "vector-toc-available", "mw-page-container", "mw-body", "vector-body", "mw-body-content" }) |class|
        try std.testing.expect(profile.Profile.hasClass(context.classes, class));
    try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", scope.root_classes);
    const unproved = try observedImages(a, &ns, supplied.html, page.occurrences);
    const proved = try observedImagesWithPaintContext(a, &ns, supplied.html, page.occurrences, context);
    try std.testing.expectEqual(@as(usize, 1), unproved.len);
    try std.testing.expectEqual(@as(usize, 1), proved.len);
    try std.testing.expect(!unproved[0].missing_content.?.paint_root_proven);
    var expected = unproved[0];
    expected.missing_content.?.paint_root_proven = true;
    try std.testing.expectEqualDeep(expected, proved[0]);
    try std.testing.expectEqual(@as(u32, 100), proved[0].missing_content.?.data_width);
    try std.testing.expectEqualStrings(page.occurrences[0].canonical_file, proved[0].missing_content.?.label);
    try std.testing.expect(proved[0].missing_content.?.right and !proved[0].missing_content.?.default_size);
    const parsed = try field(try json(a, page.response), "parse");
    if (parsed.object.get("revid")) |revision| try std.testing.expect(revision == .null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, supplied.html, "<style "));
    // This verifies the wrapper and embedded-source proof only. No external
    // stylesheet set, computed paint, FigureRegistry or full Writer is granted.
    try std.testing.expect(digestMatches(supplied.html, "9e92a178b66dd0dd720e69dedc48f35b70f5443bccde5b96ef4bc249cd6de8ca"));
}

test "WMF4 wrapper admission refuses crossed version pairs changed identities and unproved source scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/th-missing-outer/namespace-registry.tsv")); defer ns.deinit();
    const page = try Wmf4OuterTesting.page(a);
    const supplied = try responseSource(a, &ns, page);
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    const outer = page.outer_context orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "mediawiki-vector-2022-1.48.0-wmf.3", "mediawiki-vector-2022-1.48.0-wmf.5", "mediawiki-vector-2022-1.48.0-wmf.40", "" }) |name| {
        var wrong = outer; wrong.profile = name;
        try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong, scope));
    }
    const mismatched = try OuterContextTesting.replaced(a, outer,
        "content=\"MediaWiki 1.48.0-wmf.4\"", "content=\"MediaWiki 1.48.0-wmf.3\"");
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, mismatched, scope));
    var wrong_page = page; wrong_page.text_class_scope = false;
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, wrong_page, outer, scope));
    wrong_page = page; wrong_page.revision_id += 1;
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, wrong_page, outer, scope));
    wrong_page = page; wrong_page.title = "different";
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, wrong_page, outer, scope));
    var wrong_scope = scope; wrong_scope.root_classes = "mw-parser-output";
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, outer, wrong_scope));
    const wrong_wrapper = try OuterContextTesting.replaced(a, outer,
        "id=\"bodyContent\" class=\"vector-body\"", "id=\"wrongContent\" class=\"vector-body\"");
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong_wrapper, scope));
    // The existing WMF3 fixture remains accepted only under its original pair.
    var vi = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer vi.deinit();
    const old_page = OuterContextTesting.page();
    const old_response = try responseSource(a, &vi, old_page);
    const old_scope = try observedTextClassScope(a, &vi, old_response.html);
    const old_outer = OuterContextTesting.outer();
    _ = try observedOuterContext(a, &vi, old_page, old_outer, old_scope);
    var crossed = old_outer; crossed.profile = outer.profile;
    try std.testing.expectError(invalid, observedOuterContext(a, &vi, old_page, crossed, old_scope));
}


test "static STL Book wrapper grammar keeps PNG axes label and strict complete ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const html = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"it\" dir=\"ltr\"><figure class=\"mw-default-size\" typeof=\"mw:File/Thumb\"><span class=\"mw-3d-wrapper\" data-label=\"modello 3D\"><a href=\"/wiki/File:Model.stl\" class=\"mw-file-description\"><img src=\"//thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/Model.stl/250px-Model.stl.png\" width=\"250\" height=\"188\" class=\"mw-file-element\" data-file-width=\"5120\" data-file-height=\"2880\" /></a></span><figcaption>complete caption</figcaption></figure></div>";
    const rows = [_]RawOccurrence{.{ .start = 0, .end = 1, .canonical_file = "File:Model.stl", .static_poster = true, .original_width = 5120, .original_height = 2880 }};
    const result = try observedImages(a, &ns, html, &rows);
    try std.testing.expectEqual(@as(u32, 250), result[0].width);
    try std.testing.expectEqualStrings("modello 3D", result[0].poster_label orelse return error.TestUnexpectedResult);
    for ([_][2][]const u8{
        .{"height=\"188\"", "height=\"187\""}, .{"mw-3d-wrapper\"", "mw-3d-wrapper extra\""},
        .{"data-label=", "title="}, .{"<a href=", " <a href="}, .{"</a></span>", "</a> </span>"},
        .{"class=\"mw-file-element\"", "class=\"mw-file-element\" style=\"margin:0\""},
        .{"250px-Model.stl.png", "250px-Model.stl.jpg"}, .{"</div>", "<style>.mw-3d-wrapper{display:none}</style></div>"},
        .{"</div>", "<link rel=\"stylesheet\" href=\"https://example.test/extra.css\"></div>"},
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, a, html, change[0], change[1]);
        try std.testing.expectError(invalid, observedImages(a, &ns, changed, &rows));
    }
    var ordinary = rows; ordinary[0].static_poster = false;
    try std.testing.expectError(invalid, observedImages(a, &ns, html, &ordinary));
}


test "static STL Book head context binds exact stylesheet order and source default classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var hrefs: [static_poster_urls.len][]const u8 = undefined;
    for (static_poster_urls, 0..) |url, index| hrefs[index] = try std.mem.replaceOwned(u8, a, url, "&", "&amp;");
    const head = try std.fmt.allocPrint(a,
        "<!DOCTYPE html><html class=\"{s}\" lang=\"it\" dir=\"ltr\"><head><meta name=\"generator\" content=\"MediaWiki current observation\"><link rel=\"stylesheet\" href=\"{s}\"><link rel=\"stylesheet\" href=\"{s}\"><link rel=\"stylesheet\" href=\"{s}\"></head><body class=\"mediawiki ltr sitedir-ltr mw-hide-empty-elt action-view skin-vector-2022 ns-0 ns-subject mw-editable page-prova rootpage-prova skin--responsive skin-vector skin-vector-search-vue\">",
        .{static_poster_root_classes, hrefs[0], hrefs[1], hrefs[2]});
    try staticPosterHeadContext(a, head, "it");
    for ([_][2][]const u8{
        .{"skin-theme-clientpref-day", "skin-theme-clientpref-night"},
        .{"skin-thumbsize-clientpref-standard", "skin-thumbsize-clientpref-large"},
        .{"skin--responsive", "notheme"}, .{"<body class=", "<body style=\"line-height:20px\" class="},
        .{"</head>", "<style>.mw-3d-wrapper{display:none}</style></head>"},
        .{hrefs[1], hrefs[2]},
        .{"rel=\"stylesheet\"", "rel=\"alternate\""},
        .{"<link rel=", "<link media=\"print\" rel="},
    }) |change| {
        const changed = try std.mem.replaceOwned(u8, a, head, change[0], change[1]);
        try std.testing.expectError(invalid, staticPosterHeadContext(a, changed, "it"));
    }
    try std.testing.expectError(invalid, staticPosterHeadContext(a, head, "en"));
}

test "static STL selected callback cannot lend another occurrence options dimensions or missing branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    const occurrence: Occurrence = .{ .canonical_file = "File:Model.stl", .original_options = "miniatura|caption", .width = null, .anchor = null,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D", .file_sha1 = "44a4d04788825a486a53b417a469d95b98113018", .file_timestamp = "2025-04-18T12:52:57Z" } };
    const page: SelectedPage = .{ .namespace_catalog = &ns, .default_width = 250, .occurrences = &.{.{ .source = &occurrence, .stage_options = "thumb|caption" }} };
    for ([_][]const u8{ "miniatura|caption", "thumb|caption" }) |options| {
        const poster = (try SelectedPage.staticPoster(&page, a, "File:Model.stl", .thumbnail, options, 250, null)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("3D", poster.label);
        try std.testing.expect((try SelectedPage.width(&page, a, "File:Model.stl", .thumbnail, options, 250)) == null);
        try std.testing.expect((try SelectedPage.height(&page, a, ns.wiki, page.page_title, "File:Model.stl", .thumbnail, options, 188)) == null);
        try std.testing.expect((try SelectedPage.missing(&page, a, "File:Model.stl", .thumbnail, options)) == null);
    }
    try std.testing.expect((try SelectedPage.staticPoster(null, a, "File:Model.stl", .thumbnail, "thumb|caption", 250, null)) == null);
    for ([_]struct{file: []const u8 = "File:Model.stl", format: encoder.presentation_types.FigureFormat = .thumbnail, options: []const u8 = "thumb|caption", width: ?u32 = 250, height: ?u32 = null}{
        .{.file="File:Other.stl"}, .{.format=.framed}, .{.options="thumb|different caption"}, .{.width=null}, .{.width=251}, .{.height=188},
    }) |case| try std.testing.expect((try SelectedPage.staticPoster(&page, a, case.file, case.format, case.options, case.width, case.height)) == null);
}

const StaticPosterContextTesting = if (@import("builtin").is_test) struct {
    const prefix = "testdata/it-static-poster/";
    fn document(a: A) !Document {
        return std.json.parseFromSliceLeaky(Document, a, @embedFile(prefix ++ "figure-page-observations.outer03.json"), .{ .allocate = .alloc_always });
    }
};

test "static STL context joins both actual Vector ancestors while keeping distinct supplied parser bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try StaticPosterContextTesting.document(a);
    try std.testing.expectEqual(@as(usize, 2), doc.pages.len);
    for (doc.pages) |page| {
        const response = try responseSource(a, &ns, page);
        try staticPosterPageContext(a, &ns, page, response.html);
        const scope = try observedTextClassScope(a, &ns, response.html);
        const outer = page.outer_context orelse return error.TestUnexpectedResult;
        const classes = try observedOuterClasses(a, &ns, page, outer, scope);
        try std.testing.expect(profile.Profile.hasClass(classes, "vector-body"));
        try std.testing.expect(profile.Profile.hasClass(classes, "vector-toc-available"));
        // Actual GET is a separate Parsoid body; it is not the supplied body.
        try std.testing.expect(std.mem.indexOf(u8, outer.response, "data-mw-parsoid-version=") != null);
        try std.testing.expect(std.mem.indexOf(u8, response.html, "data-mw-parsoid-version=") == null);
        try std.testing.expect(std.mem.indexOf(u8, outer.response, response.html) == null);
    }
}

test "static STL context refuses missing outer proof and extra middle ancestor attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try StaticPosterContextTesting.document(a);
    const original = doc.pages[0];
    const response = try responseSource(a, &ns, original);
    try staticPosterPageContext(a, &ns, original, response.html);
    var page = original; page.outer_context = null;
    try std.testing.expectError(invalid, staticPosterPageContext(a, &ns, page, response.html));
    page = original; page.outer_context.?.profile = "mediawiki-vector-2022-1.48.0-wmf.3";
    try std.testing.expectError(invalid, staticPosterPageContext(a, &ns, page, response.html));
    for ([_][2][]const u8{
        .{ "class=\"mw-page-container\"", "class=\"mw-page-container center\"" },
        .{ "class=\"mw-page-container-inner\"", "class=\"mw-page-container-inner\" style=\"font-family:serif\"" },
        .{ "class=\"mw-content-container\"", "class=\"mw-content-container\" dir=\"rtl\"" },
        .{ "class=\"mw-body\"", "class=\"mw-body\" data-theme=\"other\"" },
        .{ "aria-labelledby=\"firstHeading\"", "aria-labelledby=\"anotherHeading\"" },
        .{ "class=\"mw-body-content\"", "class=\"mw-body-content noresize\"" },
        .{ " vector-toc-available skin-thumbsize-clientpref-standard skin-underline-clientpref-browser\" lang=\"it\" dir=\"ltr\">", " vector-toc-not-available skin-thumbsize-clientpref-standard skin-underline-clientpref-browser\" lang=\"it\" dir=\"ltr\">" },
    }) |change| {
        page = original;
        page.outer_context = try OuterContextTesting.replaced(a, original.outer_context.?, change[0], change[1]);
        try std.testing.expectError(invalid, staticPosterPageContext(a, &ns, page, response.html));
    }
}

test "static STL serving set refuses body stylesheets and active meta without changing class inventory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const before = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"it\" dir=\"ltr\">";
    const after = "<span style=\"color:red\">ordinary owned text</span><meta property=\"mw:PageProp/toc\" /></div>";
    const original = before ++ "<!-- literal <style> and <link> are inert -->" ++ after;
    try staticPosterBodyContext(a, original);
    _ = try observedTextClassScope(a, &ns, original);
    for ([_][]const u8{
        "<style>.mw-3d-wrapper{font-family:serif}</style>",
        "<STYLE media=\"screen\">.mw-3d-wrapper{opacity:0}</STYLE>",
        "<link rel=\"stylesheet\" href=\"/extra.css\" />",
        "<link rel=\"preload\" as=\"style\" href=\"/extra.css\" />",
        "<script>document.body.className='changed'</script>",
        "<meta http-equiv=\"refresh\" content=\"0\" />",
        "<meta property=\"mw:PageProp/toc\" content=\"extra\" />",
    }) |extra| {
        const changed = try std.mem.concat(a, u8, &.{ before, extra, after });
        try std.testing.expectError(invalid, staticPosterBodyContext(a, changed));
    }
    // The old class-only proof still accepts a well-formed STYLE node.
    const class_only = before ++ "<style>.other{color:red}</style>" ++ after;
    _ = try observedTextClassScope(a, &ns, class_only);
    try std.testing.expectError(invalid, staticPosterBodyContext(a, class_only));
}


test "Missing paint diagnostics keep the first blocked occurrence while all later images retain their own refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/it/namespace-registry.tsv")); defer ns.deinit();
    var occurrences: [3]RawOccurrence = undefined;
    var figures: [3][]const u8 = undefined;
    for ([_][]const u8{ "First.png", "Second.png", "Third.png" }, [_][]const u8{ "", "mw-halign-right", "mw-default-size" }, 0..) |basename, classes, index| {
        const file = try canonicalFile(a, &ns, try std.mem.concat(a, u8, &.{ "File:", basename }));
        occurrences[index] = .{ .start = index * 2, .end = index * 2 + 1, .canonical_file = file, .missing_content = true };
        figures[index] = try std.fmt.allocPrint(a, "<figure class=\"{s}\" typeof=\"mw:Error mw:File/Thumb\"><a href=\"//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile={s}\" class=\"new\" title=\"{s}\"><span class=\"mw-file-element mw-broken-media\" data-width=\"180\">{s}</span></a><figcaption>Caption</figcaption></figure>", .{ classes, basename, file, file });
    }
    const html = try std.fmt.allocPrint(a, "<div class=\"mw-content-ltr mw-parser-output\" lang=\"{s}\" dir=\"ltr\">{s}{s}{s}</div>", .{ ns.content_language, figures[0], figures[1], figures[2] });
    const outer = try EmbeddedPaintTesting.controlledOuter(a);
    const before = try observedImagesWithServedPaint(a, &ns, html, &occurrences, outer, null, false);
    for (before) |image| try std.testing.expect(image.missing_content.?.paint_root_proven);
    var styles = try profile.parseAlloc(a, ".mw-halign-right > a{color:red}.mw-default-size > a{background:blue}"); defer styles.deinit();
    var failure: ?MissingPaintFailure = null;
    const after = try observedImagesWithServedPaintFailure(a, &ns, html, &occurrences, outer, &styles, true, &failure);
    try std.testing.expectEqual(@as(usize, 3), after.len);
    for (after, 0..) |image, index| {
        var expected = before[index]; expected.missing_content.?.paint_root_proven = index == 0;
        try std.testing.expectEqualDeep(expected, image);
    }
    const first = failure orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?usize, 1), first.occurrence_index);
    try std.testing.expectEqualStrings("a", first.tag);
    try std.testing.expectEqualStrings(".mw-halign-right > a", first.blocker.rule.?.provenance.?.selector);
    try std.testing.expectEqualStrings("color:red", first.blocker.declaration);
    // Reordering this controlled occurrence list changes the index of
    // the first refusal; the full parser still binds each file independently.
    const reversed = [_]RawOccurrence{ occurrences[2], occurrences[0], occurrences[1] };
    failure = null;
    const reordered = try observedImagesWithServedPaintFailure(a, &ns, html, &reversed, outer, &styles, true, &failure);
    try std.testing.expect(!reordered[0].missing_content.?.paint_root_proven and reordered[1].missing_content.?.paint_root_proven and !reordered[2].missing_content.?.paint_root_proven);
    try std.testing.expectEqual(@as(?usize, 0), failure.?.occurrence_index);
    try std.testing.expectEqualStrings("background:blue", failure.?.blocker.declaration);
}


test "observed CENTER retains real ancestry and refuses implicit paragraph or table reparenting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, MissingServedTesting.namespace); defer ns.deinit();
    const doc = try MissingServedTesting.document(a);
    const appendix = try MissingServedTesting.page(doc, 53658);
    const supplied = try responseSource(a, &ns, appendix);
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", scope.root_classes);
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    const original = try observedImages(a, &ns, supplied.html, appendix.occurrences);
    try std.testing.expectEqual(@as(usize, 1), original.len);
    try std.testing.expect(original[0].missing_content.?.paint_root_proven);
    const opening = "<figure class=\"mw-halign-right\" typeof=\"mw:Error mw:File/Thumb\">";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, opening));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, "</figure>"));
    const first = try std.mem.replaceOwned(u8, a, supplied.html, opening, "<center class=\"actual-center\">" ++ opening);
    const nested = try std.mem.replaceOwned(u8, a, first, "</figure>", "</figure></center>");
    const wrapped = try observedImages(a, &ns, nested, appendix.occurrences);
    try std.testing.expectEqual(@as(usize, 1), wrapped.len);
    var expected = original[0]; expected.missing_content.?.paint_root_proven = false;
    try std.testing.expectEqualDeep(expected, wrapped[0]);
    const wrapped_scope = try observedTextClassScope(a, &ns, nested);
    try std.testing.expect(profile.Profile.hasClass(wrapped_scope.subtree_classes, "actual-center"));
    for ([_][]const u8{
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"ku\" dir=\"ltr\"><p><center>x</center></p></div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"ku\" dir=\"ltr\"><table><center>x</center></table></div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"ku\" dir=\"ltr\"><center>x</div>",
        "<div class=\"mw-content-ltr mw-parser-output\" lang=\"ku\" dir=\"ltr\"><center/></div>",
    }) |denied| {
        try std.testing.expectError(error.InvalidFigurePageObservations, observedTextClassScope(a, &ns, denied));
        try std.testing.expectError(error.InvalidFigurePageObservations, observedImages(a, &ns, denied, &.{}));
    }
}

test "complete FR borracho observation retains BDI direction source audio and exact upright image facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/fr-borracho/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const parsed = try std.json.parseFromSlice(Document, a, @embedFile(prefix ++ "figure-page-observations.json"), .{}); defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.pages.len);
    const page = parsed.value.pages[0];
    try std.testing.expectEqual(@as(u64, 1501218), page.page_id);
    try std.testing.expectEqual(@as(u64, 38755465), page.revision_id);
    const supplied = try responseSource(a, &ns, page);
    try std.testing.expectEqualStrings(@embedFile(prefix ++ "expanded.wikitext"), supplied.source);
    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, supplied.html, "<bdi"));
    try std.testing.expect(std.mem.indexOf(u8, supplied.html, "<bdi lang=\"es\" class=\"lang-es\">") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, "<audio"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, supplied.html, "<source"));
    const scope = try observedTextClassScope(a, &ns, supplied.html);
    try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", scope.root_classes);
    try std.testing.expect(profile.Profile.hasClass(scope.subtree_classes, "lang-es"));
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    const observed = try observedImages(a, &ns, supplied.html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expectEqual(@as(u32, 190), observed[0].width);
    try std.testing.expectEqual(@as(u32, 232), observed[0].height);
    try std.testing.expect(!observed[0].centered and !observed[0].centered_default_size);
    try std.testing.expect(observed[0].missing_content == null and observed[0].poster_label == null);
    try std.testing.expectEqualStrings(page.occurrences[0].canonical_file,
        (try fileHref(a, &ns, observed[0].anchor.get("href") orelse return error.TestUnexpectedResult)) orelse return error.TestUnexpectedResult);
    // The v1 input did not request a text-scope capability. A direct inventory
    // check above does not promote that input or infer a wiki-wide upright factor.
    try std.testing.expect(!page.text_class_scope and page.outer_context == null);
}

test "observed BDI keeps physical direction ancestry and refuses malformed foreign and reparented evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, MissingServedTesting.namespace); defer ns.deinit();
    const doc = try MissingServedTesting.document(a);
    const page = try MissingServedTesting.page(doc, 53658);
    const supplied = try responseSource(a, &ns, page);
    const original = try observedImages(a, &ns, supplied.html, page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), original.len);
    try std.testing.expect(original[0].missing_content.?.paint_root_proven);
    const opening = "<figure class=\"mw-halign-right\" typeof=\"mw:Error mw:File/Thumb\">";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, opening));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, supplied.html, "</figure>"));
    const isolate = "<bdi class=\"physical-isolate\" dir=\"rtl\" lang=\"he\"><span>owned <bdi dir=\"auto\">text</bdi></span></bdi>";
    const sibling = try std.mem.replaceOwned(u8, a, supplied.html, opening, isolate ++ opening);
    const observed = try observedImages(a, &ns, sibling, page.occurrences);
    try std.testing.expectEqualDeep(original, observed);
    const scope = try observedTextClassScope(a, &ns, sibling);
    try std.testing.expect(profile.Profile.hasClass(scope.subtree_classes, "physical-isolate"));
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    // A bidi isolate cannot be discarded to borrow direct root ownership.
    const first = try std.mem.replaceOwned(u8, a, supplied.html, opening,
        "<bdi dir=\"rtl\" lang=\"he\">" ++ opening);
    const nested = try std.mem.replaceOwned(u8, a, first, "</figure>", "</figure></bdi>");
    try std.testing.expectError(invalid, observedImages(a, &ns, nested, page.occurrences));
    try std.testing.expectError(invalid, observedTextClassScope(a, &ns, nested));
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"ku\" dir=\"ltr\">";
    // BDI is not a transparent splice: malformed nesting, foster parenting,
    // inert/foreign trees and self-closing nonvoid forms retain refusal.
    for ([_][]const u8{
        "<bdi><span>x</bdi></span>", "<bdi>x", "<bdi/>",
        "<bdi dir=\"rtl\" DIR=\"ltr\">x</bdi>",
        "<p><bdi><div>x</div></bdi></p>",
        "<table><bdi>x</bdi></table>",
        "<a href=\"/wiki/Outer\"><bdi><a href=\"/wiki/Inner\">x</a></bdi></a>",
        "<bdi><svg><text>x</text></svg></bdi>",
        "<bdi><math><mi>x</mi></math></bdi>",
        "<bdi><template><figure></figure></template></bdi>",
        "<audio><bdi>x</bdi></audio>",
    }) |body| {
        errdefer std.debug.print("BDI evidence refusal: {s}\n", .{body});
        const denied = try std.mem.concat(a, u8, &.{ root, body, "</div>" });
        try std.testing.expectError(invalid, observedImages(a, &ns, denied, &.{}));
        try std.testing.expectError(invalid, observedTextClassScope(a, &ns, denied));
    }
}

// A literal cell anchor identifies one authored wiki TABLE in an authenticated
// complete parse response. It does not infer ancestry from preceding prose.
const SourceRootTableAnchor = struct {
    table: Inventory, cell: Inventory, child: Inventory, text: []const u8,
    opening_start: usize, opening_end: usize, anchor_start: usize, anchor_end: usize,
    cell_ordinal: usize = 0, eligible: bool = false, actual_root: bool = false,
};
fn rootTableAttributes(a: A, attrs: []const u8) !?Inventory {
    if (std.mem.indexOfAny(u8, attrs, "{}[]<>|\r\n\x00") != null or std.mem.indexOf(u8, attrs, "__") != null) return null;
    const synthetic = try std.mem.concat(a, u8, &.{ "<table ", attrs, ">" });
    const tag = syntax.tagAt(synthetic, 0) orelse return null;
    const parsed = inventory(a, tag) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
    for (parsed.attributes) |attribute| {
        if (siblingLiteralAttribute(attribute.name, attribute.value)) continue;
        if (!equal(attribute.name, "cellpadding") or attribute.value.len == 0) return null;
        for (attribute.value) |byte| if (!std.ascii.isDigit(byte)) return null;
    }
    return parsed;
}
fn rootTableLiteralText(a: A, raw: []const u8) !?[]const u8 {
    if (raw.len == 0 or raw.len > 4096 or std.mem.indexOfAny(u8, raw, "<>[]{}'\r\n\x00") != null) return null;
    const decoded = decodedAttribute(a, raw) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
    // This is an occurrence signature only. MediaWiki's literal typography
    // may emit NBSP for a source space (including before a closing guillemet).
    // Coarsening just this space pair makes any resulting collision refuse;
    // no source bytes, rendered body, or CSS value is normalized here.
    var signature: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < decoded.len) {
        if (at + 1 < decoded.len and decoded[at] == 0xc2 and decoded[at + 1] == 0xa0) {
            try signature.append(a, ' '); at += 2;
        } else { try signature.append(a, decoded[at]); at += 1; }
    }
    const normalized = try signature.toOwnedSlice(a);
    for (normalized) |byte| {
        if (byte >= 0x80 or std.ascii.isAlphabetic(byte) or std.mem.indexOfScalar(u8, " .,;!?()-", byte) != null) continue;
        return null;
    }
    const view = std.unicode.Utf8View.init(normalized) catch return null;
    var points = view.iterator();
    while (points.nextCodepoint()) |point| if (point >= 0x80 and
        (point < 0xa0 or point == 0x2028 or point == 0x2029 or (point >= 0xfdd0 and point <= 0xfdef) or
            point & 0xffff == 0xfffe or point & 0xffff == 0xffff)) return null;
    var words = std.mem.tokenizeAny(u8, normalized, " .,;!?()-");
    while (words.next()) |word| for ([_][]const u8{ "ISBN", "RFC", "PMID" }) |magic|
        if (word.len >= magic.len and std.ascii.eqlIgnoreCase(word[0..magic.len], magic)) return null;
    return normalized;
}
fn sameRootTableAnchor(left: SourceRootTableAnchor, right: SourceRootTableAnchor) bool {
    return sameSiblingAttributes(left.table, right.table) and sameSiblingAttributes(left.cell, right.cell) and
        sameSiblingAttributes(left.child, right.child) and equal(left.text, right.text);
}
fn rootTableInitialCell(ns: *const namespaces.Registry, body: []const u8) bool {
    // Before the literal DIV anchor only one closed, ordinary File link may
    // occupy each initial cell. No template, protected holder or HTML crosses
    // a cell boundary. This is an anchor grammar, not a root-prefix whitelist.
    if (!std.mem.startsWith(u8, body, "[[") or !std.mem.endsWith(u8, body, "]]")) return false;
    const pair = syntax.balanced(body, 0) orelse return false;
    if (pair.end != body.len) return false;
    const inner = body[2 .. body.len - 2];
    if (std.mem.indexOfAny(u8, inner, "[]{}<>&'\r\n\x00") != null or std.mem.indexOf(u8, inner, "__") != null) return false;
    const split = std.mem.indexOfScalar(u8, inner, '|') orelse return false;
    const target = inner[0..split];
    if (target.len == 0 or target[0] == ':' or ns.ofTitle(target).id != 6) return false;
    // Option values remain literal; URL/interwiki/behavior spellings cannot
    // execute inside this closed source anchor.
    if (std.mem.indexOfAny(u8, inner[split + 1 ..], ":/\\") != null) return false;
    return true;
}
fn sourceRootTableAnchors(a: A, ns: *const namespaces.Registry, source: []const u8) ![]const SourceRootTableAnchor {
    var result: std.ArrayList(SourceRootTableAnchor) = .empty;
    var table: ?struct { attrs: Inventory, start: usize, end: usize, cells: usize = 0, eligible: bool = true } = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var start: usize = 0;
    while (lines.next()) |raw| {
        defer start += raw.len + 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "{|")) {
            // Nested or repeated openings cannot lend an outer occurrence.
            if (table != null) { table = null; continue; }
            const attrs = (try rootTableAttributes(a, line[2..])) orelse continue;
            table = .{ .attrs = attrs, .start = start, .end = start + line.len };
            continue;
        }
        if (std.mem.startsWith(u8, line, "|}")) { table = null; continue; }
        const owner = if (table) |*value| value else continue;
        if (line.len < 2 or line[0] != '|' or line[1] == '|' or line[1] == '-' or line[1] == '+') { owner.eligible = false; continue; }
        const separator = std.mem.indexOfScalarPos(u8, line, 1, '|') orelse { owner.eligible = false; continue; };
        const cell = (try rootTableAttributes(a, line[1..separator])) orelse { owner.eligible = false; continue; };
        const cell_ordinal = owner.cells;
        owner.cells += 1;
        const div_at = separator + 1;
        const div = syntax.tagAt(line, div_at) orelse {
            if (!rootTableInitialCell(ns, line[div_at..])) owner.eligible = false;
            continue;
        };
        if (!div.is("div") or div.closing or div.self_closing or std.mem.endsWith(u8, line[div_at..div.end], "/>")) { owner.eligible = false; continue; }
        const child = (try siblingSourceAttributes(a, div)) orelse { owner.eligible = false; continue; };
        const end = std.mem.indexOfScalarPos(u8, line, div.end, '<') orelse { owner.eligible = false; continue; };
        const text = (try rootTableLiteralText(a, line[div.end..end])) orelse { owner.eligible = false; continue; };
        const close = syntax.tagAt(line, end) orelse { owner.eligible = false; continue; };
        if (!close.is("div") or !close.closing or close.self_closing or close.end != line.len or
            std.mem.trim(u8, close.attrs, " \t").len != 0) { owner.eligible = false; continue; }
        try result.append(a, .{ .table = owner.attrs, .cell = cell, .child = child, .text = text,
            .opening_start = owner.start, .opening_end = owner.end, .anchor_start = start, .anchor_end = start + line.len, .cell_ordinal = cell_ordinal, .eligible = owner.eligible });
        owner.eligible = false;
        if (result.items.len > 4096) return invalid;
    }
    return try result.toOwnedSlice(a);
}
fn observedRootTableAnchor(a: A, html: []const u8, nodes: []const ObservedSiblingNode, index: usize) !?SourceRootTableAnchor {
    const child = nodes[index];
    if (!child.tag.is("div") or child.first_child != null) return null;
    const cell_index = child.parent orelse return null;
    const cell = nodes[cell_index];
    if (!cell.tag.is("td")) return null;
    const row_index = cell.parent orelse return null;
    if (!nodes[row_index].tag.is("tr")) return null;
    var table_index = nodes[row_index].parent orelse return null;
    if (nodes[table_index].tag.is("tbody")) table_index = nodes[table_index].parent orelse return null;
    const table = nodes[table_index];
    if (!table.tag.is("table") or nodes.len == 0 or !nodes[0].tag.is("div") or nodes[0].parent != null) return null;
    var cell_ordinal: usize = 0;
    var leading_cells_valid = true;
    var previous = cell.previous;
    while (previous) |before| {
        if (before >= cell_index or nodes[before].parent != row_index) return null;
        if (nodes[before].tag.is("td") or nodes[before].tag.is("th")) cell_ordinal += 1;
        if (!nodes[before].tag.is("td")) leading_cells_valid = false;
        previous = nodes[before].previous;
    }
    const end = child.inner_end orelse return null;
    const text = (try rootTableLiteralText(a, html[child.tag.end..end])) orelse return null;
    const child_close = syntax.tagAt(html, end) orelse return null;
    // Candidate identity is table/cell/DIV attributes and closed literal text.
    // Row, slot, ancestry and exclusive cell placement are eligibility only:
    // none may hide a same-signature candidate from the ambiguity census.
    const eligible = leading_cells_valid and nodes[row_index].previous == null and cell.first_child == index and
        siblingGapEnd(html, cell.tag.end) == child.start and siblingGapEnd(html, child_close.end) == cell.inner_end;
    return .{ .table = table.attributes, .cell = cell.attributes, .child = child.attributes, .text = text,
        .opening_start = 0, .opening_end = 0, .anchor_start = 0, .anchor_end = 0, .cell_ordinal = cell_ordinal, .actual_root = table.parent == 0, .eligible = eligible };
}
fn observedSourceRootTables(a: A, ns: *const namespaces.Registry, source: []const u8, html: []const u8, nodes: []const ObservedSiblingNode) ![]const profile.SourceRootTableProof {
    const anchors = try sourceRootTableAnchors(a, ns, source);
    const observed = try a.alloc(?SourceRootTableAnchor, nodes.len);
    for (nodes, 0..) |_, index| observed[index] = try observedRootTableAnchor(a, html, nodes, index);
    var proofs: std.ArrayList(profile.SourceRootTableProof) = .empty;
    for (anchors, 0..) |anchor, index| {
        var unique = true;
        for (anchors, 0..) |other, other_index| if (index != other_index and sameRootTableAnchor(anchor, other)) { unique = false; break; };
        if (!unique or !anchor.eligible) continue;
        var selected_slot: ?usize = null;
        var selected_root = false;
        var selected_eligible = false;
        var matches: usize = 0;
        for (observed) |candidate| if (candidate) |known| { if (sameRootTableAnchor(anchor, known)) { matches += 1; selected_slot = known.cell_ordinal; selected_root = known.actual_root; selected_eligible = known.eligible; } };
        // Ancestry is tested only after the all-parent signature census. A
        // matching nested table must not disappear before uniqueness is known.
        if (matches != 1 or !selected_root or !selected_eligible or selected_slot != anchor.cell_ordinal) continue;
        try proofs.append(a, .{ .opening_start = anchor.opening_start, .opening_end = anchor.opening_end,
            .anchor_start = anchor.anchor_start, .anchor_end = anchor.anchor_end, .cell_ordinal = anchor.cell_ordinal });
    }
    return try proofs.toOwnedSlice(a);
}

const ObservedSiblingNode = struct {
    tag: syntax.Tag, attributes: Inventory, start: usize, parent: ?usize, previous: ?usize,
    first_child: ?usize = null, inner_end: ?usize = null,
};

const SourceRootChildAnchor = struct {
    attributes: Inventory, text: []const u8, range: profile.SourceRootChildProof,
};
fn closedRootChildStyle(a: A, value: []const u8) !?[]const u8 {
    // Only ASCII spaces after a final plain semicolon are equivalent here.
    // The closed existing grammar excludes strings, comments and escapes, so
    // the terminal semicolon cannot belong to any literal or nested construct.
    const canonical = std.mem.trimEnd(u8, value, " ");
    if (canonical.len == 0 or canonical[canonical.len - 1] != ';' or
        !siblingLiteralAttribute("style", canonical)) return null;
    var position: usize = 0;
    while (try profile.nextDeclarationAlloc(a, canonical, &position)) |declaration| {
        defer a.free(declaration);
        if (std.mem.trim(u8, declaration, " ").len == 0) continue;
        if (std.mem.indexOfScalar(u8, declaration, ':') == null) return null;
    }
    return canonical;
}
fn rootChildAttributes(a: A, tag: syntax.Tag) !?Inventory {
    if (std.mem.indexOfAny(u8, tag.attrs, "{}[]<>|\r\n\x00") != null or std.mem.indexOf(u8, tag.attrs, "__") != null) return null;
    const parsed = inventory(a, tag) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
    const attributes = try a.dupe(Attribute, parsed.attributes);
    for (attributes) |*attribute| {
        if (std.ascii.eqlIgnoreCase(attribute.name, "style")) {
            attribute.value = (try closedRootChildStyle(a, attribute.value)) orelse return null;
        } else if (std.ascii.eqlIgnoreCase(attribute.name, "title")) {
            _ = (try literalSiblingText(a, attribute.value)) orelse return null;
        } else if (!siblingLiteralAttribute(attribute.name, attribute.value)) return null;
    }
    return .{ .attributes = attributes };
}
fn literalRootChildText(a: A, text: []const u8) !?[]const u8 {
    // A literal label may end in one colon. It cannot begin a physical line
    // construct, URL or magic link; the preceding whole text uses the closed
    // nonexecuting sibling alphabet, including its decoded-value guards.
    if (text.len < 2 or text[text.len - 1] != ':') return null;
    const label = (try literalSiblingText(a, text[0 .. text.len - 1])) orelse return null;
    return try std.mem.concat(a, u8, &.{ label, ":" });
}
fn sourceRootChildAnchor(a: A, source: []const u8, start: usize) !?SourceRootChildAnchor {
    const opening = syntax.tagAt(source, start) orelse return null;
    if (!opening.is("p") or opening.closing or opening.self_closing or std.mem.endsWith(u8, source[start..opening.end], "/>")) return null;
    const attributes = (try rootChildAttributes(a, opening)) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, source, opening.end, '<') orelse return null;
    const text = (try literalRootChildText(a, source[opening.end..end])) orelse return null;
    const closing = syntax.tagAt(source, end) orelse return null;
    if (!closing.is("p") or !closing.closing or closing.self_closing or std.mem.endsWith(u8, source[end..closing.end], "/>") or
        std.mem.trim(u8, closing.attrs, " \t\r\n").len != 0) return null;
    return .{ .attributes = attributes, .text = text, .range = .{ .anchor_start = start, .anchor_end = closing.end,
        .name_start = @intFromPtr(opening.name.ptr) - @intFromPtr(source.ptr), .name_len = opening.name.len,
        .attrs_start = @intFromPtr(opening.attrs.ptr) - @intFromPtr(source.ptr), .attrs_len = opening.attrs.len } };
}
fn sameRootChildAnchor(left: SourceRootChildAnchor, right: SourceRootChildAnchor) bool {
    return sameSiblingAttributes(left.attributes, right.attributes) and equal(left.text, right.text);
}
fn observedSourceRootChildren(a: A, source: []const u8, html: []const u8, nodes: []const ObservedSiblingNode) ![]const profile.SourceRootChildProof {
    if (nodes.len == 0 or nodes[0].parent != null or !nodes[0].tag.is("div")) return invalid;
    var authored: std.ArrayList(SourceRootChildAnchor) = .empty;
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, position, '<')) |start| {
        if (try sourceRootChildAnchor(a, source, start)) |anchor| try authored.append(a, anchor);
        if (authored.items.len > 4096) return invalid;
        position = start + 1;
    }
    var result: std.ArrayList(profile.SourceRootChildProof) = .empty;
    for (authored.items, 0..) |anchor, index| {
        var unique = true;
        for (authored.items, 0..) |other, other_index| if (index != other_index and sameRootChildAnchor(anchor, other)) { unique = false; break; };
        if (!unique) continue;
        var matched: ?usize = null;
        for (nodes, 0..) |node, node_index| {
            if (!node.tag.is("p") or node.first_child != null) continue;
            const observed = (try sourceRootChildAnchor(a, html, node.start)) orelse continue;
            if (node.inner_end == null or node.inner_end.? != std.mem.indexOfScalarPos(u8, html, node.tag.end, '<').?) continue;
            if (!sameRootChildAnchor(anchor, observed)) continue;
            if (matched != null) { unique = false; break; }
            matched = node_index;
        }
        if (!unique) continue;
        const selected = matched orelse continue;
        // Nested/injected parents never become a shorter root edge.
        if (nodes[selected].parent != 0) continue;
        try result.append(a, anchor.range);
    }
    return try result.toOwnedSlice(a);
}

fn observedCommonRootParents(a: A, source: []const u8, html: []const u8, nodes: []const ObservedSiblingNode) ![]const profile.SourceRootParentProof {
    if (nodes.len == 0 or nodes[0].parent != null or !nodes[0].tag.is("div") or nodes[0].inner_end == null) return invalid;
    // The caller supplies the complete strict HTML inventory. Count every closed
    // source anchor, including protected lexical duplicates, without choosing a
    // source-to-node mapping. The compiler still requires an ordinary operation.
    var authored: std.ArrayList(SourceRootChildAnchor) = .empty;
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, position, '<')) |start| {
        if (try sourceRootChildAnchor(a, source, start)) |anchor| try authored.append(a, anchor);
        if (authored.items.len > 4096) return invalid;
        position = start + 1;
    }
    const observed = try a.alloc(?SourceRootChildAnchor, nodes.len);
    for (nodes, 0..) |node, index| {
        observed[index] = null;
        if (!node.tag.is("p") or node.first_child != null or node.inner_end == null) continue;
        const anchor = (try sourceRootChildAnchor(a, html, node.start)) orelse continue;
        if (node.inner_end.? != std.mem.indexOfScalarPos(u8, html, node.tag.end, '<').?) continue;
        observed[index] = anchor;
    }
    var result: std.ArrayList(profile.SourceRootParentProof) = .empty;
    for (authored.items) |anchor| {
        var source_count: usize = 0;
        for (authored.items) |other| if (sameRootChildAnchor(anchor, other)) { source_count += 1; };
        if (source_count < 2) continue;
        var candidate_count: usize = 0;
        var common_parent = true;
        var own_attributes: ?Inventory = null;
        for (observed, nodes) |maybe, node| {
            const candidate = maybe orelse continue;
            if (!sameRootChildAnchor(anchor, candidate)) continue;
            candidate_count += 1;
            // Every candidate must use the very same observed parser-root node.
            // Its complete API and GET paths/environments remain separate. Exact
            // own DOM attributes also agree, including literal style whitespace.
            if (node.parent != 0) common_parent = false;
            if (own_attributes) |known| {
                if (!sameSiblingAttributes(known, node.attributes)) common_parent = false;
            } else own_attributes = node.attributes;
        }
        // Equal census is a conservative coverage check, never an ordinal map.
        // An absent/extra candidate, altered own state or any different parent
        // withholds the common fact for every source occurrence in this group.
        if (!common_parent or candidate_count != source_count) continue;
        try result.append(a, .{ .anchor = anchor.range, .candidate_count = @intCast(candidate_count) });
    }
    return try result.toOwnedSlice(a);
}

const SourceSiblingAnchor = struct {
    own: Inventory, child: Inventory, text: []const u8,
    anchor_start: usize, anchor_end: usize,
    name_start: usize, name_len: usize, attrs_start: usize, attrs_len: usize,
};
fn sameSiblingAttributes(left: Inventory, right: Inventory) bool {
    if (left.attributes.len != right.attributes.len) return false;
    for (left.attributes) |attribute| if (!equal(attribute.value, right.get(attribute.name) orelse return false)) return false;
    return true;
}
fn sameSiblingAnchor(left: SourceSiblingAnchor, right: SourceSiblingAnchor) bool {
    return sameSiblingAttributes(left.own, right.own) and sameSiblingAttributes(left.child, right.child) and equal(left.text, right.text);
}
fn siblingGapEnd(source: []const u8, start: usize) ?usize {
    var at = start;
    while (at < source.len) {
        if (std.ascii.isWhitespace(source[at])) { at += 1; continue; }
        if (!std.mem.startsWith(u8, source[at..], "<!--")) return at;
        const end = std.mem.indexOfPos(u8, source, at + 4, "-->") orelse return null;
        if (std.mem.indexOf(u8, source[at + 4 .. end], "--") != null or
            (end > at + 4 and source[end - 1] == '-')) return null;
        at = end + 3;
    }
    return at;
}
fn literalSiblingText(a: A, raw: []const u8) !?[]const u8 {
    // This anchor has no wikitext execution or HTML descendants. Only the
    // existing strict character-reference decoder reconciles equivalent text.
    if (raw.len == 0 or raw.len > 4096 or std.mem.indexOfAny(u8, raw, "<>[]{}'\r\n\x00") != null) return null;
    for (raw) |byte| if (byte < 0x20 and byte != '\t') return null;
    const decoded = decodedAttribute(a, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory, else => return null,
    };
    // Closed literal alphabet after entity decoding. ASCII punctuation/digits
    // cannot introduce URLs, magic links, behavior switches, formatting,
    // signatures, template/table/link syntax, or physical-line constructs.
    // A lone slash is literal prose; a protocol-relative double slash refuses.
    for (decoded, 0..) |byte, index| {
        if (byte >= 0x80) continue;
        if (std.ascii.isAlphabetic(byte) or byte == ' ') continue;
        if (byte == '/' and (index == 0 or decoded[index - 1] != '/') and
            (index + 1 == decoded.len or decoded[index + 1] != '/')) continue;
        return null;
    }
    const utf8 = std.unicode.Utf8View.init(decoded) catch return null;
    var codepoints = utf8.iterator();
    while (codepoints.nextCodepoint()) |point| if (point >= 0x80 and
        (point < 0xa0 or point == 0x2028 or point == 0x2029 or (point >= 0xfdd0 and point <= 0xfdef) or
            point & 0xffff == 0xfffe or point & 0xffff == 0xffff)) return null;
    // Retain legacy magic-link uncertainty even with non-ASCII number forms;
    // the anchor does not choose a wiki's enabled magic-link configuration.
    var words = std.mem.tokenizeScalar(u8, decoded, ' ');
    while (words.next()) |word| for ([_][]const u8{ "ISBN", "RFC", "PMID" }) |magic|
        if (word.len >= magic.len and std.ascii.eqlIgnoreCase(word[0..magic.len], magic)) return null;
    return decoded;
}
fn siblingLiteralAttribute(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "align")) return equal(value, "left") or equal(value, "right") or equal(value, "center") or equal(value, "justify");
    if (std.ascii.eqlIgnoreCase(name, "class")) {
        var names = std.mem.tokenizeScalar(u8, value, ' ');
        while (names.next()) |token| {
            if (!std.ascii.isAlphabetic(token[0]) and token[0] != '_') return false;
            for (token) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
        }
        return std.mem.indexOf(u8, value, "__") == null;
    }
    if (std.ascii.eqlIgnoreCase(name, "style")) {
        // Closed plain declarations: no functions, URLs, escapes, strings or
        // markup. This only proves nonexecution; Profile still owns CSS values.
        var declarations = std.mem.splitScalar(u8, value, ';');
        while (declarations.next()) |raw| {
            const declaration = std.mem.trim(u8, raw, " ");
            if (declaration.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse return false;
            const property = std.mem.trim(u8, declaration[0..colon], " ");
            const content = std.mem.trim(u8, declaration[colon + 1 ..], " ");
            if (property.len == 0 or content.len == 0) return false;
            for (property) |byte| if (!std.ascii.isAlphabetic(byte) and byte != '-') return false;
            for (content) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, " #.,%+-", byte) == null) return false;
        }
        return true;
    }
    return false;
}
fn siblingSourceAttributes(a: A, tag: syntax.Tag) !?Inventory {
    // Wikitext preprocessing runs inside HTML attributes too. Neither an exact
    // source pointer nor a decoded partial signature proves that preprocessing
    // left the opening intact. Keep this anchor domain closed independently.
    if (std.mem.indexOfAny(u8, tag.attrs, "{}[]<>|\r\n\x00") != null or
        std.mem.indexOf(u8, tag.attrs, "__") != null) return null;
    const parsed = inventory(a, tag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory, else => return null,
    };
    for (parsed.attributes) |attribute| {
        if (!siblingLiteralAttribute(attribute.name, attribute.value)) return null;
    }
    return parsed;
}
fn sourceSiblingAnchor(a: A, source: []const u8, at: usize) !?SourceSiblingAnchor {
    const own = syntax.tagAt(source, at) orelse return null;
    // The general HTML parser removes a lexical slash on paired tags. This
    // source anchor accepts only literal paired openings and a plain closer.
    if (!own.is("div") or own.closing or own.self_closing or std.mem.endsWith(u8, source[at..own.end], "/>")) return null;
    const own_attrs = (try siblingSourceAttributes(a, own)) orelse return null;
    const child_at = siblingGapEnd(source, own.end) orelse return null;
    const child = syntax.tagAt(source, child_at) orelse return null;
    if (!child.is("div") or child.closing or child.self_closing or std.mem.endsWith(u8, source[child_at..child.end], "/>")) return null;
    const child_attrs = (try siblingSourceAttributes(a, child)) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, source, child.end, '<') orelse return null;
    const text = (try literalSiblingText(a, source[child.end..end])) orelse return null;
    const closing = syntax.tagAt(source, end) orelse return null;
    if (!closing.is("div") or !closing.closing or closing.self_closing or
        std.mem.endsWith(u8, source[end..closing.end], "/>") or std.mem.trim(u8, closing.attrs, " \t\r\n").len != 0) return null;
    // A generated or transformed opening never borrows this exact source range.
    return .{ .own = own_attrs, .child = child_attrs, .text = text,
        .anchor_start = at, .anchor_end = closing.end,
        .name_start = @intFromPtr(own.name.ptr) - @intFromPtr(source.ptr), .name_len = own.name.len,
        .attrs_start = @intFromPtr(own.attrs.ptr) - @intFromPtr(source.ptr), .attrs_len = own.attrs.len };
}
fn observedSiblingAnchor(a: A, html: []const u8, nodes: []const ObservedSiblingNode, index: usize) !?SourceSiblingAnchor {
    const node = nodes[index];
    if (!node.tag.is("div")) return null;
    // This issuer does not model HTML table/list/paragraph insertion repair.
    // Every actual ancestor through the returned parser root must be DIV.
    var parent = node.parent;
    if (parent == null) return null;
    while (parent) |owner| {
        if (owner >= index or !nodes[owner].tag.is("div")) return null;
        parent = nodes[owner].parent;
    }
    const child_index = node.first_child orelse return null;
    const child = nodes[child_index];
    if (!child.tag.is("div") or child.first_child != null or child.parent != index or
        (siblingGapEnd(html, node.tag.end) orelse return null) != child.start) return null;
    const end = child.inner_end orelse return null;
    const text = (try literalSiblingText(a, html[child.tag.end..end])) orelse return null;
    return .{ .own = node.attributes, .child = child.attributes, .text = text,
        .anchor_start = 0, .anchor_end = 0,
        .name_start = 0, .name_len = 0, .attrs_start = 0, .attrs_len = 0 };
}
fn observedSourceSiblings(a: A, source: []const u8, html: []const u8, nodes: []const ObservedSiblingNode) ![]const profile.SourceSiblingProof {
    var source_anchors: std.ArrayList(SourceSiblingAnchor) = .empty;
    var at: usize = 0;
    // A lexical duplicate, even in protected text, makes this signature
    // ambiguous. Actual issuance still requires the compiler's ordinary tag.
    while (std.mem.indexOfScalarPos(u8, source, at, '<')) |opening| {
        if (try sourceSiblingAnchor(a, source, opening)) |anchor| try source_anchors.append(a, anchor);
        at = opening + 1;
        if (source_anchors.items.len > 4096) return invalid;
    }
    const observed = try a.alloc(?SourceSiblingAnchor, nodes.len);
    for (nodes, 0..) |_, index| observed[index] = try observedSiblingAnchor(a, html, nodes, index);
    var proofs: std.ArrayList(profile.SourceSiblingProof) = .empty;
    for (source_anchors.items, 0..) |anchor, source_index| {
        var unique = true;
        for (source_anchors.items, 0..) |other, other_index| if (source_index != other_index and sameSiblingAnchor(anchor, other)) { unique = false; break; };
        if (!unique) continue;
        var selected: ?usize = null;
        for (observed, 0..) |candidate, index| if (candidate) |known| {
            if (!sameSiblingAnchor(anchor, known)) continue;
            if (selected != null) { unique = false; break; }
            selected = index;
        };
        if (!unique) continue;
        const index = selected orelse continue;
        const node = nodes[index];
        const parent = node.parent orelse continue;
        const previous: ?profile.SourceSiblingElement = if (node.previous) |before| value: {
            if (nodes[before].parent != parent or before >= index) return invalid;
            break :value .{ .tag = nodes[before].tag.name, .classes = nodes[before].attributes.get("class") orelse "",
                .id = nodes[before].attributes.get("id") orelse "" };
        } else null;
        try proofs.append(a, .{ .anchor_start = anchor.anchor_start, .anchor_end = anchor.anchor_end, .name_start = anchor.name_start, .name_len = anchor.name_len,
            .attrs_start = anchor.attrs_start, .attrs_len = anchor.attrs_len,
            .parent_key = parent + 1, .previous = previous });
    }
    return try proofs.toOwnedSlice(a);
}



test "observed sibling identity preserves actual EL first nonmatch and four adjacent NavFrames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/el-height/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try Testing.document(a, "el-height");
    const decoded = try responseSource(a, &ns, doc.pages[0]);
    try std.testing.expect(digestMatches(decoded.source, "83ebd4841f8018c783c893991797e3372cd6417c3004d1fdaf02dd921ece9a64"));
    try std.testing.expect(digestMatches(decoded.html, "f24be9056065f0ec5ff34c68d29b4a58c637c860b63680299ace7fcf6d060e07"));
    var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
    _ = try observedTextClassScopeWithElements(a, &ns, decoded.html, &nodes);
    const proofs = try observedSourceSiblings(a, decoded.source, decoded.html, nodes.items);
    const offsets = [_]usize{ 5233, 6312, 7491, 8738, 10026 };
    var count: usize = 0;
    for (proofs) |proof| {
        const opening = proof.name_start - 1;
        const tag = syntax.tagAt(decoded.source, opening) orelse return error.TestUnexpectedResult;
        if (!equal(tag.attr("class") orelse "", "NavFrame")) continue;
        try std.testing.expectEqual(offsets[count], opening);
        try std.testing.expectEqual(@as(usize, 1), proof.parent_key);
        const previous = proof.previous orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("div", previous.tag);
        try std.testing.expectEqualStrings(if (count == 0) "mw-heading mw-heading4" else "NavFrame", previous.classes);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    // This direct intake proof does not install a page profile or waive the
    // still-unqualified full EL stylesheet, geometry, Writer or report contract.
}

test "observed sibling anchors ignore text comments but refuse ambiguity altered children and unsafe parents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/el-height/namespace-registry.tsv")); defer ns.deinit();
    const first = "<div class=\"NavFrame\"><div class=\"NavHead\">first&nbsp;label</div></div>";
    const second = "<div class=\"NavFrame\"><div class=\"NavHead\">second label</div></div>";
    const source = first ++ "\n<!-- ordinary comment -->\n" ++ second;
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"el\" dir=\"ltr\">";
    const html = root ++ "<div class=\"NavFrame\"><div class=\"NavHead\">first&#160;label</div></div>" ++
        "arbitrary text<!-- another comment -->" ++ second ++ "</div>";
    var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
    _ = try observedTextClassScopeWithElements(a, &ns, html, &nodes);
    const proofs = try observedSourceSiblings(a, source, html, nodes.items);
    try std.testing.expectEqual(@as(usize, 2), proofs.len);
    try std.testing.expect(proofs[0].previous == null);
    try std.testing.expectEqualStrings("NavFrame", proofs[1].previous.?.classes);
    const interrupted = root ++ first ++ "<span>intervening element</span>" ++ second ++ "</div>";
    nodes = .empty; _ = try observedTextClassScopeWithElements(a, &ns, interrupted, &nodes);
    const stopped = try observedSourceSiblings(a, source, interrupted, nodes.items);
    try std.testing.expectEqualStrings("span", stopped[1].previous.?.tag);
    const duplicated = root ++ first ++ second ++ second ++ "</div>";
    nodes = .empty; _ = try observedTextClassScopeWithElements(a, &ns, duplicated, &nodes);
    const ambiguous = try observedSourceSiblings(a, source, duplicated, nodes.items);
    try std.testing.expectEqual(@as(usize, 1), ambiguous.len);
    try std.testing.expectEqual(proofs[0].name_start, ambiguous[0].name_start);
    const changed = root ++ first ++ "<div class=\"NavFrame\"><div class=\"NavHead\">changed label</div></div></div>";
    nodes = .empty; _ = try observedTextClassScopeWithElements(a, &ns, changed, &nodes);
    try std.testing.expectEqual(@as(usize, 1), (try observedSourceSiblings(a, source, changed, nodes.items)).len);
    const unsafe_parent = root ++ "<table><tbody><tr><td>" ++ second ++ "</td></tr></tbody></table></div>";
    nodes = .empty; _ = try observedTextClassScopeWithElements(a, &ns, unsafe_parent, &nodes);
    try std.testing.expectEqual(@as(usize, 0), (try observedSourceSiblings(a, source, unsafe_parent, nodes.items)).len);
    nodes = .empty; _ = try observedTextClassScopeWithElements(a, &ns, html, &nodes);
    const duplicate_source = source ++ "<nowiki>" ++ second ++ "</nowiki>";
    try std.testing.expectEqual(@as(usize, 1), (try observedSourceSiblings(a, duplicate_source, html, nodes.items)).len);
    for ([_][]const u8{ "<div><div>[[generated]]</div>", "<div><div>'''formatting'''</div>",
        "<div><div><span>nested</span></div>", "<div><div>bad&unknown;</div>",
        "<div><div>https://example.org</div>", "<div><div>https&#58;//example.org</div>",
        "<div><div>//example.org</div>", "<div><div>__NOTOC__</div>", "<div><div>RFC 123</div>",
        "<div><div>ISBN 9780000000000</div>", "<div><div>PMID 123</div>", "<div><div>line&#10;break</div>",
        "<div><div>---- rule</div>", "<div><div>signature~~~~</div>" }) |unrepresented|
        try std.testing.expect((try sourceSiblingAnchor(a, unrepresented, 0)) == null);
}


test "sibling identity refuses generated literal collision with executable source URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/el-height/namespace-registry.tsv")); defer ns.deinit();
    const source = "{{GeneratedLiteral}}<div class=\"NavFrame\"><div class=\"NavHead\">https://example.org</div></div>";
    const html = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"el\" dir=\"ltr\">" ++
        "<span>generated prior element</span><div class=\"NavFrame\"><div class=\"NavHead\">https://example.org</div></div>" ++
        "<div class=\"NavFrame\"><div class=\"NavHead\"><a href=\"https://example.org\">https://example.org</a></div></div></div>";
    var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
    _ = try observedTextClassScopeWithElements(a, &ns, html, &nodes);
    try std.testing.expectEqual(@as(usize, 0), (try observedSourceSiblings(a, source, html, nodes.items)).len);
}


test "sibling source signatures refuse own and child attribute preprocessing collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-page-observations/el-height/namespace-registry.tsv")); defer ns.deinit();
    for ([_][]const u8{ "{{ClassName}}", "&#123;&#123;ClassName&#125;&#125;", "[[link]]", "__NOTOC__", "<nowiki>class</nowiki>" }) |value| {
        for ([_]bool{false, true}) |on_child| {
            const source = if (on_child)
                try std.fmt.allocPrint(a, "{{{{GeneratedLiteral}}}}<div class=\"NavFrame\"><div class=\"{s}\">plain label</div></div>", .{value})
            else try std.fmt.allocPrint(a, "{{{{GeneratedLiteral}}}}<div class=\"{s}\"><div class=\"NavHead\">plain label</div></div>", .{value});
            const start = std.mem.indexOf(u8, source, "<div") orelse return error.TestUnexpectedResult;
            try std.testing.expect((try sourceSiblingAnchor(a, source, start)) == null);
        }
    }
    const source = "{{GeneratedLiteral}}<div class=\"{{ClassName}}\"><div class=\"NavHead\">plain label</div></div>";
    const html = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"el\" dir=\"ltr\">" ++
        "<span>generated predecessor</span><div class=\"&#123;&#123;ClassName&#125;&#125;\"><div class=\"NavHead\">plain label</div></div>" ++
        "<div class=\"actual\"><div class=\"NavHead\">plain label</div></div></div>";
    var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
    _ = try observedTextClassScopeWithElements(a, &ns, html, &nodes);
    try std.testing.expectEqual(@as(usize, 0), (try observedSourceSiblings(a, source, html, nodes.items)).len);
}




test "EL relation-only Book preserves all height evidence and requires exact full source selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/el-height/";
    const augmented = @embedFile("testdata/figure-page-observations/el-relations/figure-page-observations.json");
    const original = try Testing.document(a, "el-height");
    const doc = try std.json.parseFromSliceLeaky(Document, a, augmented, .{ .allocate = .alloc_always });
    var retained = doc.pages[0]; retained.source_element_relations = null;
    try std.testing.expectEqualDeep(original.pages[0], retained);
    try std.testing.expect(doc.missing_link_styles == null and doc.pages[0].outer_context == null and !doc.pages[0].text_class_scope);
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    // Existing controlled rows exercise Book selection only; no new normal
    // Registry, Writer or full-page style acceptance follows from this control.
    var files = try Testing.registry(a, &ns, original); defer files.deinit();
    files.height_bound_records = &.{ .svg_redundant_height, .svg_redundant_height };
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const raw = @embedFile(prefix ++ "page.raw.wikitext");
    const source = try Testing.source(a, original);
    var book = try Book.init(a, augmented, &ns, &files, defaults, 250); defer book.deinit();
    var old_book = try Book.init(a, @embedFile(prefix ++ "figure-page-observations.json"), &ns, &files, defaults, 250); defer old_book.deinit();
    const context: compiler.Context = .{ .title = doc.pages[0].title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const selected = (try book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const old = (try old_book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(old.text_class_scope == null);
    const scope = selected.text_class_scope orelse return error.TestUnexpectedResult;
    try std.testing.expect(scope.complete_ancestor_class_superset == null);
    try std.testing.expect(scope.source_siblings_source.?.ptr == source.ptr and scope.source_siblings_source.?.len == source.len);
    try std.testing.expectEqual(@as(usize, 5), scope.source_siblings.len);
    try std.testing.expectEqualDeep(old.occurrences, selected.occurrences);
    try std.testing.expect((try book.select(a, &ns, 0, 5630, 7336337, doc.pages[0].title, raw, source, defaults, 250, context)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, source[0 .. source.len - 1], defaults, 250, context)) == null);
    const wrong_source = try a.dupe(u8, source); wrong_source[0] = '!';
    try std.testing.expect((try book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, wrong_source, defaults, 250, context)) == null);
    var shape = try json(a, augmented);
    const page_shape = &shape.object.getPtr("pages").?.array.items[0];
    _ = page_shape.object.swapRemove("source_element_relations");
    var absent = try Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250); defer absent.deinit();
    try std.testing.expect(absent.pages[0].text_class_scope == null and absent.pages[0].source_siblings.len == 0);
    try page_shape.object.put(a, "source_element_relations", .null);
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250));
    try page_shape.object.put(a, "source_element_relations", .{ .bool = true });
    try shape.object.put(a, "schema", .{ .string = "wikidict.figure-page-observations.v1" });
    try std.testing.expectError(error.InvalidFigurePageObservations, Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250));
}


test "sibling opening grammar requires literal complete attributes and cannot run CSS functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const good = "<div class=\"NavFrame\" style=\"clear:both;\"><div class=\"NavHead\" style=\"background:#eeeeee; color:#000000; font-weight:bold; text-align:left;\" align=\"left\">plain label</div>";
    try std.testing.expect((try sourceSiblingAnchor(a, good, 0)) != null);
    try std.testing.expect((try sourceSiblingAnchor(a, "<DIV><DIV>plain label</DIV >", 0)) != null);
    for ([_][]const u8{
        "<div class=NavFrame><div>plain label</div>",
        "<div class=\"NavFrame\" class=\"other\"><div>plain label</div>",
        "<div onclick=\"run\"><div>plain label</div>",
        "<div style=\"background:url(https://example.org)\"><div>plain label</div>",
        "<div style=\"width:expression(run)\"><div>plain label</div>",
        "<div style=\"background:var(--color)\"><div>plain label</div>",
        "<div style=\"background:&#117;rl(https://example.org)\"><div>plain label</div>",
        "<div><div style=\"background:url(anything)\">plain label</div>",
        "<div><div>plain label</div class=\"end\">",
        "<div><div>plain label</div/>",
        "<div><div>plain label</div />",
        "<div/><div>plain label</div>",
        "<div /><div>plain label</div>",
        "<div><div/>plain label</div>",
        "<div><div />plain label</div>",
    }) |source| {
        errdefer std.debug.print("sibling anchor refusal source={s}\n", .{source});
        try std.testing.expect((try sourceSiblingAnchor(a, source, 0)) == null);
    }
}


test "EL separately observed outer context preserves both heights and five exact source sibling relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/el-height/";
    const bytes = @embedFile("testdata/figure-page-observations/el-relations-outer/figure-page-observations.json");
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const original = try Testing.document(a, "el-height");
    try std.testing.expectEqualDeep(original.pages[0].occurrences, doc.pages[0].occurrences);
    try std.testing.expect(doc.missing_link_styles == null and doc.static_poster_styles == null);
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile(prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    var files = try Testing.registry(a, &ns, original); defer files.deinit();
    files.height_bound_records = &.{ .svg_redundant_height, .svg_redundant_height };
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const raw = @embedFile(prefix ++ "page.raw.wikitext");
    const source = try Testing.source(a, original);
    const context: compiler.Context = .{ .title = doc.pages[0].title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
    var retained = try Book.init(a, @embedFile("testdata/figure-page-observations/el-relations/figure-page-observations.json"), &ns, &files, defaults, 250); defer retained.deinit();
    const selected = (try book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const old = (try retained.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(old.occurrences, selected.occurrences);
    const scope = selected.text_class_scope orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(old.text_class_scope.?.source_siblings, scope.source_siblings);
    try std.testing.expectEqual(@as(usize, 5), scope.source_siblings.len);
    const classes = scope.complete_ancestor_class_superset orelse return error.TestUnexpectedResult;
    try std.testing.expect(profile.Profile.hasClass(classes, "mw-page-container") and profile.Profile.hasClass(classes, "mw-parser-output"));
    try std.testing.expect(!profile.Profile.hasClass(classes, "Boxmerge"));
    try std.testing.expect(old.text_class_scope.?.complete_ancestor_class_superset == null);
    try std.testing.expect(scope.source_siblings_source.?.ptr == source.ptr and scope.source_siblings_source.?.len == source.len);
    try std.testing.expect((try book.select(a, &ns, 0, 5630, 7336337, doc.pages[0].title, raw, source, defaults, 250, context)) == null);
    const changed = try a.dupe(u8, source); changed[0] = '!';
    try std.testing.expect((try book.select(a, &ns, 0, 5630, 7336336, doc.pages[0].title, raw, changed, defaults, 250, context)) == null);
    try std.testing.expect(book.missing_link_paint == null);
}

test "EL outer absence requires its own authenticated context without weakening relation or wrapper guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/figure-page-observations/el-height/";
    const bytes = @embedFile("testdata/figure-page-observations/el-relations-outer/figure-page-observations.json");
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const original = try Testing.document(a, "el-height");
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try Testing.registry(a, &ns, original); defer files.deinit(); files.height_bound_records = &.{ .svg_redundant_height, .svg_redundant_height };
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const shape = try json(a, bytes); const page = &shape.object.getPtr("pages").?.array.items[0];
    _ = page.object.swapRemove("outer_context");
    var absent = try Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250); defer absent.deinit();
    try std.testing.expect(absent.pages[0].text_class_scope.?.complete_ancestor_class_superset == null);
    try std.testing.expectEqual(@as(usize, 5), absent.pages[0].source_siblings.len);
    const parsed = try responseSource(a, &ns, doc.pages[0]);
    const scope = try observedTextClassScope(a, &ns, parsed.html);
    var wrong = doc.pages[0].outer_context.?; wrong.profile = "mediawiki-vector-2022-1.48.0-wmf.3";
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterContext(a, &ns, doc.pages[0], wrong, scope));
    wrong = try OuterContextTesting.replaced(a, doc.pages[0].outer_context.?, "class=\"mw-content-container\"", "class=\"mw-content-container Boxmerge\"");
    const present = try observedOuterContext(a, &ns, doc.pages[0], wrong, scope);
    try std.testing.expect(profile.Profile.hasClass(present.classes, "Boxmerge"));
    const present_classes = try completeObservedTextClassSuperset(a, scope, present.classes, parsed.source);
    var styles = try profile.parseForTargetAlloc(a, ".Boxmerge div.NavFrame{border-top-style:hidden}", .screen); defer styles.deinit();
    const node: profile.TextElement = .{ .tag = "div", .classes = "NavFrame", .complete_ancestor_classes = present_classes };
    const matched = try styles.containerRuleMatchesIn(a, &node); defer a.free(matched.rules);
    try std.testing.expect(!matched.unresolved and matched.rules.len == 1);
    try std.testing.expect(matched.rules[0].match != .no);
    wrong = try OuterContextTesting.replaced(a, doc.pages[0].outer_context.?, "class=\"mw-content-container\"", "class=\"foreign-content-container\"");
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterContext(a, &ns, doc.pages[0], wrong, scope));
    wrong = doc.pages[0].outer_context.?; wrong.response = try std.mem.concat(a, u8, &.{ wrong.response, "changed" });
    try std.testing.expectError(error.InvalidFigurePageObservations, observedOuterContext(a, &ns, doc.pages[0], wrong, scope));
}

test "SVG language observation requires exact named PNG transform for every image candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, namespaces.english_test_fixture); defer ns.deinit();
    const source = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Map.svg/langvi-250px-Map.svg.png";
    try svgLanguageRasterSource(a, &ns, source, "File:Map.svg", "vi");
    const doubled = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Map.svg/langvi-500px-Map.svg.png";
    try svgLanguageRasterSourceSet(a, &ns, try std.fmt.allocPrint(a, "{s} 1x, {s} 2x", .{source, doubled}), "File:Map.svg", "vi");
    for ([_][2][]const u8{
        .{source, "https://upload.wikimedia.org/wikipedia/commons/a/ab/Map.svg"},
        .{"langvi-", "langen-"}, .{".svg.png", ".svg.webp"}, .{"250px", "0px"}, .{"250px", "0250px"},
        .{"250px", "4294967296px"}, .{"250px", "250.0px"}, .{"-Map.svg.png", "-Other.svg.png"},
        .{"upload.wikimedia.org", "evil.example"}, .{"Map.svg/lang", "Map.svg/Map.svg/lang"},
        .{"Map.svg/lang", "Map.svg/%GGlang"},
    }) |mutation| {
        const bad = try std.mem.replaceOwned(u8, a, source, mutation[0], mutation[1]);
        errdefer std.debug.print("SVG raster URL refused member={s}\n", .{bad});
        try std.testing.expectError(invalid, svgLanguageRasterSource(a, &ns, bad, "File:Map.svg", "vi"));
    }
    for ([_][]const u8{ "?lang=vi", "#langvi-250px" }) |suffix|
        try std.testing.expectError(invalid, svgLanguageRasterSource(a, &ns, try std.mem.concat(a, u8, &.{source, suffix}), "File:Map.svg", "vi"));
    const wrong = try std.mem.replaceOwned(u8, a, doubled, "langvi-", "langen-");
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "{s} 1x, {s} 2x", .{source, wrong}),
        try std.fmt.allocPrint(a, "{s} 2x, {s} 1x", .{source, doubled}),
        try std.fmt.allocPrint(a, "{s} 250w", .{source}),
        try std.fmt.allocPrint(a, "{s} 0x", .{source}), "",
    }) |bad| try std.testing.expectError(invalid, svgLanguageRasterSourceSet(a, &ns, bad, "File:Map.svg", "vi"));
    const occurrence: RawOccurrence = .{ .start = 0, .end = 1, .canonical_file = "File:Map.svg", .original_width = 300, .original_height = 250, .svg_language = "vi" };
    const html = try std.fmt.allocPrint(a, "<div class=\"mw-parser-output\"><p>before</p><figure class=\"mw-default-size\" typeof=\"mw:File/Thumb\"><a href=\"/w/index.php?title=File:Map.svg&amp;lang=vi\" class=\"mw-file-description\"><img src=\"{s}\" width=\"250\" height=\"208\" class=\"mw-file-element\" data-file-width=\"300\" data-file-height=\"250\" /></a><figcaption>caption</figcaption></figure><p>after</p></div>", .{source});
    const images = try observedImages(a, &ns, html, &.{occurrence});
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualStrings("vi", images[0].svg_language.?);
    try std.testing.expectEqual(@as(u32, 250), images[0].width);
    try std.testing.expectEqual(@as(u32, 208), images[0].height);
    try std.testing.expect(svgObservedWidthFit(250, 208, 300, 250));
    try std.testing.expect(!svgObservedWidthFit(250, 209, 300, 250));
    try std.testing.expect(!svgObservedWidthFit(301, 251, 300, 250));
    var changed = occurrence; changed.svg_language = "en";
    try std.testing.expectError(invalid, observedImages(a, &ns, html, &.{changed}));
    try std.testing.expectError(invalid, observedImages(a, &ns, try std.mem.concat(a, u8, &.{html, html}), &.{occurrence}));
    // A second same-file occurrence cannot hide behind another language or
    // the ordinary file-description URL. Only the original baseline is unique.
    for ([_][]const u8{
        "<a href=\"/wiki/File:Map.svg\">ordinary same file</a>",
        "<a href=\"/w/index.php?title=File:Map.svg&amp;lang=en\">other language</a>",
        "<a href=\"/w/index.php?title=File:Map.svg&amp;lang=vi&amp;lang=en\">ambiguous language</a>",
        "<figure class=\"mw-default-size\" typeof=\"mw:File/Thumb\"><a href=\"/w/index.php?title=File:Map.svg&amp;lang=en\" class=\"mw-file-description\"><img src=\"https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Map.svg/langen-250px-Map.svg.png\" width=\"250\" height=\"208\" class=\"mw-file-element\" data-file-width=\"300\" data-file-height=\"250\" /></a><figcaption>other language</figcaption></figure>",
    }) |extra| {
        const duplicate = try std.mem.replaceOwned(u8, a, html, "</div>", try std.mem.concat(a, u8, &.{extra, "</div>"}));
        try std.testing.expectError(invalid, observedImages(a, &ns, duplicate, &.{occurrence}));
    }
    const inert = try std.fmt.allocPrint(a, "<template>{s}</template>", .{html});
    try std.testing.expectError(invalid, observedImages(a, &ns, inert, &.{occurrence}));
}

test "SVG language selected callback retains exact options identity dimensions and no observation refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    const original = "lang=vi|thumb|caption [[Target|child]]";
    try std.testing.expect(svgLanguageThumbnailOptions(&options, original, "vi"));
    try std.testing.expect(svgLanguageThumbnailOptions(&options, "thumb|lang=VI|caption", "vi"));
    for ([_][]const u8{ "thumb|caption", "lang=en|thumb|caption", "lang=vi|lang=en|thumb|caption", "lang=vi|thumb|thumb|caption", "lang=vi|frame|caption", "lang=vi|thumb|upright|caption", "lang=vi|thumb|200px|caption", "lang=vi|thumb|caption|tail" }) |bad|
        try std.testing.expect(!svgLanguageThumbnailOptions(&options, bad, "vi"));
    var occurrence: Occurrence = .{ .canonical_file = "Tập tin:Map.svg", .original_options = original, .width = null, .anchor = null,
        .svg_language = .{ .language = "vi", .width = 250, .height = 208, .policy = .requested_fit } };
    const selected_occurrences = [_]SelectedOccurrence{.{ .source = &occurrence, .stage_options = original }};
    var selected: SelectedPage = .{ .namespace_catalog = &ns, .default_width = 250, .occurrences = &selected_occurrences };
    try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit), try SelectedPage.svgLanguage(&selected, a, "Map.svg", .thumbnail, original, "vi", 250, null));
    for ([_]struct { file: []const u8 = "Map.svg", format: encoder.presentation_types.FigureFormat = .thumbnail, text: []const u8 = original, language: []const u8 = "vi", width: ?u32 = 250, height: ?u32 = null }{
        .{ .file = "Other.svg" }, .{ .format = .framed }, .{ .text = "thumb|lang=vi|changed" }, .{ .language = "en" },
        .{ .width = 251 }, .{ .width = null }, .{ .height = 208 },
    }) |case| try std.testing.expect((try SelectedPage.svgLanguage(&selected, a, case.file, case.format, case.text, case.language, case.width, case.height)) == null);
    selected.default_width = 251;
    try std.testing.expect((try SelectedPage.svgLanguage(&selected, a, "Map.svg", .thumbnail, original, "vi", 250, null)) == null);
    selected.default_width = 250; occurrence.svg_language = null;
    try std.testing.expect((try SelectedPage.svgLanguage(&selected, a, "Map.svg", .thumbnail, original, "vi", 250, null)) == null);
}

test "normal VI SVG language Book binds full acceleration source raster identity and strict legacy refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/vi-acceleration18/";
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    // The genuine reduced normal inputs are stream headers followed by complete
    // record/batch lines. Use the same stream validator as the normal loader.
    const Slice = struct {
        bytes: []const u8,
        fn readAt(ctx: *anyopaque, destination: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const at = std.math.cast(usize, offset) orelse return 0;
            if (at >= self.bytes.len) return 0;
            const count = @min(destination.len, self.bytes.len - at);
            @memcpy(destination[0..count], self.bytes[at .. at + count]);
            return count;
        }
    };
    const projection_bytes = @embedFile(prefix ++ "figure-sizing.json");
    const raw_bytes = @embedFile(prefix ++ "figure-sizing.raw.json");
    const header_end = std.mem.indexOfScalar(u8, projection_bytes, '\n') orelse return error.TestUnexpectedResult;
    const header = try json(a, projection_bytes[0..header_end]);
    try std.testing.expectEqualStrings("wikidict.figure-sizing-files.stream.v1", try string(header, "schema"));
    try std.testing.expectEqualStrings("c706f438b798d5252c78bb1c1dea13615330590df0a17c824b6ce94367195bcd", try string(header, "generator_sha256"));
    var projection_slice: Slice = .{ .bytes = projection_bytes };
    var raw_slice: Slice = .{ .bytes = raw_bytes };
    var projection_input: sizing.StreamInput = .{ .context = &projection_slice, .read_at = Slice.readAt, .size = projection_bytes.len };
    var raw_input: sizing.StreamInput = .{ .context = &raw_slice, .read_at = Slice.readAt, .size = raw_bytes.len };
    var files = try sizing.Registry.initStream(a, &projection_input, &raw_input, @embedFile(prefix ++ "figure-sizing.site.json"), &ns,
        "f45897451256aa3799aecc5d7ee320ade22beaec");
    defer files.deinit();
    try std.testing.expectEqualDeep(Testing.hash(projection_bytes), projection_input.digest orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualDeep(Testing.hash(raw_bytes), raw_input.digest orelse return error.TestUnexpectedResult);
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const raw = @embedFile(prefix ++ "raw.wikitext");
    const source = @embedFile(prefix ++ "expanded.wikitext");
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{});
    try std.testing.expectEqual(@as(usize, 1), doc.pages.len);
    const page = doc.pages[0];
    const parsed = try field(try json(a, page.response), "parse");
    try std.testing.expectEqualStrings(source, try string(parsed, "wikitext"));
    try std.testing.expectEqual(@as(usize, 2017), source.len);
    try std.testing.expectEqualStrings("[[Hình:Acceleration.svg|lang=vi|thumb|acceleration]]", source[223..276]);
    const observed = try observedImages(a, &ns, try string(parsed, "text"), page.occurrences);
    try std.testing.expectEqual(@as(usize, 1), observed.len);
    try std.testing.expectEqualStrings("vi", observed[0].svg_language.?);
    try std.testing.expectEqual(@as(u32, 250), observed[0].width);
    try std.testing.expectEqual(@as(u32, 208), observed[0].height);
    var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const context: compiler.Context = .{ .title = "acceleration", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
    const occurrence = selected.occurrences[0];
    try std.testing.expectEqualStrings("lang=vi|thumb|acceleration", occurrence.stage_options);
    try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit), try SelectedPage.svgLanguage(selected, a, "Acceleration.svg", .thumbnail, occurrence.stage_options, "vi", 250, null));
    try std.testing.expect((try SelectedPage.width(selected, a, "Acceleration.svg", .thumbnail, occurrence.stage_options, 250)) == null);
    for ([_][]const u8{ "wikidict.figure-page-observations.v1", "wikidict.figure-page-observations.v2", "wikidict.figure-page-observations.v3", "wikidict.figure-page-observations.v4", "wikidict.figure-page-observations.v5" }) |legacy| {
        var changed = doc; changed.schema = legacy;
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449850, "acceleration", raw, source, defaults, 250, context)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, try std.mem.concat(a, u8, &.{ source, "changed" }), defaults, 250, context)) == null);
    try std.testing.expect((try SelectedPage.svgLanguage(selected, a, "Acceleration.svg", .thumbnail, occurrence.stage_options, "en", 250, null)) == null);
    const actual_src = "//thumb.wikimedia.org/wikipedia/commons/thumb/4/4a/Acceleration.svg/langvi-250px-Acceleration.svg.png?utm_source=vi.wiktionary.org&utm_campaign=parser&utm_content=thumbnail";
    try svgLanguageRasterSource(a, &ns, actual_src, "Tập tin:Acceleration.svg", "vi");
    for ([_][2][]const u8{ .{ "vi.wiktionary.org", "en.wiktionary.org" }, .{ "utm_campaign=parser", "lang=en" }, .{ "utm_content=thumbnail", "utm_content=thumbnail&lang=vi" }, .{ "utm_campaign=parser", "utm_source=vi.wiktionary.org" } }) |mutation| {
        try std.testing.expectError(invalid, svgLanguageRasterSource(a, &ns, try std.mem.replaceOwned(u8, a, actual_src, mutation[0], mutation[1]), "Tập tin:Acceleration.svg", "vi"));
    }
    const anchor = "/w/index.php?title=T%E1%BA%ADp_tin:Acceleration.svg&lang=vi";
    try std.testing.expectEqualStrings("Tập tin:Acceleration.svg", (try svgLanguageFileHref(a, &ns, anchor, "vi")).?);
    for ([_][]const u8{ "/w/index.php?title=T%E1%BA%ADp_tin:Acceleration.svg&lang=en", "/w/index.php?title=T%E1%BA%ADp_tin:Acceleration.svg&lang=vi&lang=en", "/w/index.php?title=T%E1%BA%ADp_tin:Acceleration.svg&lang=%76i", "/wiki/T%E1%BA%ADp_tin:Acceleration.svg", "/w/index.php?title=%GG&lang=vi" }) |bad|
        try std.testing.expect((try svgLanguageFileHref(a, &ns, bad, "vi")) == null);
}


test "VI SVG language and separately authenticated context preserve independent raster and ancestry guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/vi-acceleration18/";
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    // The genuine reduced normal inputs are stream headers followed by complete
    // record/batch lines. Use the same stream validator as the normal loader.
    const Slice = struct {
        bytes: []const u8,
        fn readAt(ctx: *anyopaque, destination: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const at = std.math.cast(usize, offset) orelse return 0;
            if (at >= self.bytes.len) return 0;
            const count = @min(destination.len, self.bytes.len - at);
            @memcpy(destination[0..count], self.bytes[at .. at + count]);
            return count;
        }
    };
    const projection_bytes = @embedFile(prefix ++ "figure-sizing.json");
    const raw_bytes = @embedFile(prefix ++ "figure-sizing.raw.json");
    const header_end = std.mem.indexOfScalar(u8, projection_bytes, '\n') orelse return error.TestUnexpectedResult;
    const header = try json(a, projection_bytes[0..header_end]);
    try std.testing.expectEqualStrings("wikidict.figure-sizing-files.stream.v1", try string(header, "schema"));
    try std.testing.expectEqualStrings("c706f438b798d5252c78bb1c1dea13615330590df0a17c824b6ce94367195bcd", try string(header, "generator_sha256"));
    var projection_slice: Slice = .{ .bytes = projection_bytes };
    var raw_slice: Slice = .{ .bytes = raw_bytes };
    var projection_input: sizing.StreamInput = .{ .context = &projection_slice, .read_at = Slice.readAt, .size = projection_bytes.len };
    var raw_input: sizing.StreamInput = .{ .context = &raw_slice, .read_at = Slice.readAt, .size = raw_bytes.len };
    var files = try sizing.Registry.initStream(a, &projection_input, &raw_input, @embedFile(prefix ++ "figure-sizing.site.json"), &ns,
        "f45897451256aa3799aecc5d7ee320ade22beaec");
    defer files.deinit();
    try std.testing.expectEqualDeep(Testing.hash(projection_bytes), projection_input.digest orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualDeep(Testing.hash(raw_bytes), raw_input.digest orelse return error.TestUnexpectedResult);
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const raw = @embedFile(prefix ++ "raw.wikitext");
    const source = @embedFile(prefix ++ "expanded.wikitext");
    const bytes = @embedFile("testdata/vi-acceleration-context/figure-page-observations.json");
    const old_bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const original = try std.json.parseFromSliceLeaky(Document, a, old_bytes, .{ .allocate = .alloc_always });
    const page = doc.pages[0];
    try std.testing.expectEqualDeep(original.pages[0].occurrences, page.occurrences);
    try std.testing.expectEqualStrings(source, (try responseSource(a, &ns, page)).source);
    try std.testing.expectEqual(@as(usize, 2017), source.len);
    try std.testing.expectEqualStrings("[[Hình:Acceleration.svg|lang=vi|thumb|acceleration]]", source[223..276]);
    var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
    var old_book = try Book.init(a, old_bytes, &ns, &files, defaults, 250); defer old_book.deinit();
    const context: compiler.Context = .{ .title = "acceleration", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const old = (try old_book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(old.occurrences, selected.occurrences);
    try std.testing.expect(old.text_class_scope == null);
    const scope = selected.text_class_scope orelse return error.TestUnexpectedResult;
    const complete = scope.complete_ancestor_class_superset orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "mw-parser-output", "mw-page-container", "skin-vector-2022", "audiotable", "citation-whole", "IPA" }) |name|
        try std.testing.expect(profile.Profile.hasClass(complete, name));
    try std.testing.expect(!profile.Profile.hasClass(complete, "etymology"));
    try std.testing.expect(!profile.Profile.hasClass(complete, "NavContent"));
    try std.testing.expect(scope.source_siblings.len == 0 and scope.source_siblings_source == null);
    try std.testing.expect(selected.text_class_scope_source.?.ptr == source.ptr and selected.text_class_scope_source.?.len == source.len);
    try std.testing.expect(book.missing_link_paint == null);
    try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit),
        try SelectedPage.svgLanguage(selected, a, "Acceleration.svg", .thumbnail, "lang=vi|thumb|acceleration", "vi", 250, null));
    try std.testing.expect((try SelectedPage.svgLanguage(selected, a, "Acceleration.svg", .thumbnail, "lang=vi|thumb|acceleration", "en", 250, null)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449850, "acceleration", raw, source, defaults, 250, context)) == null);
    const changed_source = try std.mem.concat(a, u8, &.{source, "changed"});
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, changed_source, defaults, 250, context)) == null);

    // Outer absence is independently earned. Removing it retains only the
    // bounded parser subtree, and cannot promote the original headless POST.
    const shape = try json(a, bytes);
    const shaped_page = &shape.object.getPtr("pages").?.array.items[0];
    _ = shaped_page.object.swapRemove("outer_context");
    var bounded = try Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250); defer bounded.deinit();
    try std.testing.expect(bounded.pages[0].text_class_scope.?.complete_ancestor_class_superset == null);
    const old_shape = try json(a, old_bytes);
    const old_page = &old_shape.object.getPtr("pages").?.array.items[0];
    try old_page.object.put(a, "text_class_scope", .{ .bool = true });
    try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, old_shape, .{}), &ns, &files, defaults, 250));

    const parsed = try responseSource(a, &ns, page);
    const root_scope = try observedTextClassScope(a, &ns, parsed.html);
    var wrong = page.outer_context.?;
    wrong.profile = "mediawiki-vector-2022-1.48.0-wmf.3";
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong, root_scope));
    wrong = try OuterContextTesting.replaced(a, page.outer_context.?, "mw-editable page-acceleration rootpage-acceleration", "mw-editable page-other rootpage-acceleration");
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong, root_scope));
    wrong = page.outer_context.?;
    wrong.response = try std.mem.concat(a, u8, &.{wrong.response, "changed"});
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, page, wrong, root_scope));
    // A real possible ancestor class must be retained, not erased to obtain
    // the absence proof. No selector match or paint grant is inferred here.
    const possible = try OuterContextTesting.replaced(a, page.outer_context.?, "class=\"mw-content-container\"", "class=\"mw-content-container etymology NavContent\"");
    const possible_outer = try observedOuterContext(a, &ns, page, possible, root_scope);
    const possible_classes = try completeObservedTextClassSuperset(a, root_scope, possible_outer.classes, parsed.source);
    try std.testing.expect(profile.Profile.hasClass(possible_classes, "etymology") and profile.Profile.hasClass(possible_classes, "NavContent"));
    for ([_][]const u8{ "wikidict.figure-page-observations.v4", "wikidict.figure-page-observations.v5" }) |legacy| {
        var changed = doc; changed.schema = legacy;
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
}

test "actual unauthored SVG language preserves resolved raster identity and independent source guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/vi-acceleration18/";
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    // The genuine reduced normal inputs are stream headers followed by complete
    // record/batch lines. Use the same stream validator as the normal loader.
    const Slice = struct {
        bytes: []const u8,
        fn readAt(ctx: *anyopaque, destination: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const at = std.math.cast(usize, offset) orelse return 0;
            if (at >= self.bytes.len) return 0;
            const count = @min(destination.len, self.bytes.len - at);
            @memcpy(destination[0..count], self.bytes[at .. at + count]);
            return count;
        }
    };
    const projection_bytes = @embedFile(prefix ++ "figure-sizing.json");
    const raw_bytes = @embedFile(prefix ++ "figure-sizing.raw.json");
    const header_end = std.mem.indexOfScalar(u8, projection_bytes, '\n') orelse return error.TestUnexpectedResult;
    const header = try json(a, projection_bytes[0..header_end]);
    try std.testing.expectEqualStrings("wikidict.figure-sizing-files.stream.v1", try string(header, "schema"));
    try std.testing.expectEqualStrings("c706f438b798d5252c78bb1c1dea13615330590df0a17c824b6ce94367195bcd", try string(header, "generator_sha256"));
    var projection_slice: Slice = .{ .bytes = projection_bytes };
    var raw_slice: Slice = .{ .bytes = raw_bytes };
    var projection_input: sizing.StreamInput = .{ .context = &projection_slice, .read_at = Slice.readAt, .size = projection_bytes.len };
    var raw_input: sizing.StreamInput = .{ .context = &raw_slice, .read_at = Slice.readAt, .size = raw_bytes.len };
    var files = try sizing.Registry.initStream(a, &projection_input, &raw_input, @embedFile(prefix ++ "figure-sizing.site.json"), &ns,
        "f45897451256aa3799aecc5d7ee320ade22beaec");
    defer files.deinit();
    try std.testing.expectEqualDeep(Testing.hash(projection_bytes), projection_input.digest orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualDeep(Testing.hash(raw_bytes), raw_input.digest orelse return error.TestUnexpectedResult);
    const defaults = Testing.hash(@embedFile(prefix ++ "figure-siteinfo.raw.json"));
    const raw = @embedFile(prefix ++ "raw.wikitext");
    const source = @embedFile(prefix ++ "expanded.wikitext");
    const bytes = @embedFile("testdata/vi-acceleration-resolved-context/figure-page-observations.json");
    const reference_source = @embedFile("testdata/vi-acceleration-resolved-context/expanded.wikitext");
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const page = doc.pages[0];
    try std.testing.expect(page.occurrences[0].svg_language == null);
    try std.testing.expectEqualStrings("vi", page.occurrences[0].resolved_svg_language.?);
    try std.testing.expectEqualStrings(reference_source, (try responseSource(a, &ns, page)).source);
    try std.testing.expectEqual(@as(usize, 2009), reference_source.len);
    try std.testing.expectEqualStrings("[[Hình:Acceleration.svg|thumb|acceleration]]", reference_source[223..268]);
    const observed = try observedImages(a, &ns, (try responseSource(a, &ns, page)).html, page.occurrences);
    try std.testing.expectEqualStrings("vi", observed[0].svg_language.?);
    try std.testing.expectEqual(@as(u32, 250), observed[0].width);
    try std.testing.expectEqual(@as(u32, 208), observed[0].height);
    var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
    const context: compiler.Context = .{ .title = "acceleration", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, reference_source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const proof = (try SelectedPage.observedSvgLanguage(selected, a, "Acceleration.svg", .thumbnail, "thumb|acceleration", 250, null)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("vi", proof.language);
    try std.testing.expectEqual(encoder.presentation_types.FigureSizingPolicy.requested_fit, proof.policy);
    try std.testing.expect((try SelectedPage.svgLanguage(selected, a, "Acceleration.svg", .thumbnail, "thumb|acceleration", "vi", 250, null)) == null);
    for ([_]struct { file: []const u8 = "Acceleration.svg", text: []const u8 = "thumb|acceleration", width: ?u32 = 250, height: ?u32 = null, format: encoder.presentation_types.FigureFormat = .thumbnail }{
        .{ .file = "Other.svg" }, .{ .text = "thumb|changed" }, .{ .text = "lang=vi|thumb|acceleration" },
        .{ .width = 249 }, .{ .height = 208 }, .{ .format = .framed },
    }) |bad| try std.testing.expect((try SelectedPage.observedSvgLanguage(selected, a, bad.file, bad.format, bad.text, bad.width, bad.height)) == null);
    const complete = selected.text_class_scope.?.complete_ancestor_class_superset.?;
    try std.testing.expect(!profile.Profile.hasClass(complete, "etymology") and !profile.Profile.hasClass(complete, "NavContent"));
    try std.testing.expect(selected.text_class_scope_source.?.ptr == reference_source.ptr);
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, source, defaults, 250, context)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 95796, 2449850, "acceleration", raw, reference_source, defaults, 250, context)) == null);
    var explicit_book = try Book.init(a, @embedFile("testdata/vi-acceleration-context/figure-page-observations.json"), &ns, &files, defaults, 250); defer explicit_book.deinit();
    const explicit = (try explicit_book.select(a, &ns, 0, 95796, 2449849, "acceleration", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try SelectedPage.observedSvgLanguage(explicit, a, "Acceleration.svg", .thumbnail, "lang=vi|thumb|acceleration", 250, null)) == null);
    for ([_][]const u8{ "wikidict.figure-page-observations.v1", "wikidict.figure-page-observations.v4", "wikidict.figure-page-observations.v5" }) |schema| {
        var changed = doc; changed.schema = schema;
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
    const occurrences = try a.dupe(RawOccurrence, page.occurrences);
    const pages = try a.dupe(RawPage, doc.pages);
    var changed = doc; changed.pages = pages; pages[0].occurrences = occurrences;
    occurrences[0].svg_language = "vi";
    try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    occurrences[0].svg_language = null; occurrences[0].resolved_svg_language = "en";
    try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    occurrences[0] = page.occurrences[0]; occurrences[0].width = true;
    try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    const html = (try responseSource(a, &ns, page)).html;
    for ([_][]const u8{
        "<a href=\"/wiki/T%E1%BA%ADp_tin:Acceleration.svg\">extra</a>",
        "<a href=\"/w/index.php?title=T%E1%BA%ADp_tin:Acceleration.svg&amp;lang=en\">extra</a>",
    }) |extra| try std.testing.expectError(invalid, observedImages(a, &ns, try std.mem.concat(a, u8, &.{html, extra}), page.occurrences));
    try std.testing.expect(svgLanguageThumbnailOptionsForOrigin(&options, "thumb|acceleration", null));
    for ([_][]const u8{ "lang=vi|thumb|acceleration", "lang=|thumb|acceleration", "thumb|200px|acceleration", "thumb|upright|acceleration" }) |bad|
        try std.testing.expect(!svgLanguageThumbnailOptionsForOrigin(&options, bad, null));
}


test "observed root table proof binds actual cranio literal quote cell and original grid slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try StaticPosterContextTesting.document(a);
    var checked = false;
    for (doc.pages) |page| if (equal(page.title, "cranio")) {
        const response = try responseSource(a, &ns, page);
        try staticPosterPageContext(a, &ns, page, response.html);
        var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
        _ = try observedTextClassScopeWithElements(a, &ns, response.html, &nodes);
        const proofs = try observedSourceRootTables(a, &ns, response.source, response.html, nodes.items);
        const quote = std.mem.indexOf(u8, response.source, "{| cellpadding=\"0\" style=\"width:auto;") orelse return error.TestUnexpectedResult;
        var matches: usize = 0;
        for (proofs) |proof| if (proof.opening_start == quote) {
            try std.testing.expect(std.mem.indexOf(u8, response.source[proof.anchor_start..proof.anchor_end], "Riempi il tuo cranio") != null);
            matches += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), matches);
        checked = true;
    };
    try std.testing.expect(checked);
}

const RootTableAnchorTesting = if (@import("builtin").is_test) struct {
    const source = "closed preceding prose\n{| style=\"font-size:95%\"\n| style=\"padding:0 1.2em\"|[[Immagine:Wikiquote-logo.svg|15px|literal caption]]\n| style=\"padding:0 1.2em 0 0\"|<div style=\"font-style:normal\">Whole literal quote.</div>\n|}\n";
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"it\" dir=\"ltr\">";
    const table = "<table style=\"font-size:95%\"><tbody><tr><td style=\"padding:0 1.2em\">image</td><td style=\"padding:0 1.2em 0 0\"><div style=\"font-style:normal\">Whole literal quote.</div></td></tr></tbody></table>";
    fn count(a: A, ns: *const namespaces.Registry, input: []const u8, html: []const u8) !usize {
        var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
        _ = try observedTextClassScopeWithElements(a, ns, html, &nodes);
        return (try observedSourceRootTables(a, ns, input, html, nodes.items)).len;
    }
};

test "observed root table proof refuses nested observed parent duplicate signatures and changed grid slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = RootTableAnchorTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    try std.testing.expectEqual(@as(usize, 1), try F.count(a, &ns, F.source, F.root ++ F.table ++ "</div>"));
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source, F.root ++ "<div style=\"font-size:120%\">" ++ F.table ++ "</div></div>"));
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source, F.root ++ F.table ++ F.table ++ "</div>"));
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source, F.root ++ F.table ++ "<div>" ++ F.table ++ "</div></div>"));
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source, F.root ++ "<div>" ++ F.table ++ "</div>" ++ F.table ++ "</div>"));
    const duplicate = try std.mem.concat(a, u8, &.{ F.source, "<nowiki>\n", F.source, "</nowiki>" });
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, duplicate, F.root ++ F.table ++ "</div>"));
    const later_row = try std.mem.replaceOwned(u8, a, F.table, "<tbody><tr>", "<tbody><tr><td>earlier row</td></tr><tr>");
    const leading_text = try std.mem.replaceOwned(u8, a, F.table, "0 0\"><div", "0 0\">before<div");
    const leading_child = try std.mem.replaceOwned(u8, a, F.table, "0 0\"><div", "0 0\"><span>before</span><div");
    const trailing_text = try std.mem.replaceOwned(u8, a, F.table, "quote.</div></td>", "quote.</div>after</td>");
    const trailing_child = try std.mem.replaceOwned(u8, a, F.table, "quote.</div></td>", "quote.</div><span>after</span></td>");
    const header_open = try std.mem.replaceOwned(u8, a, F.table, "<td style=\"padding:0 1.2em\">", "<th style=\"padding:0 1.2em\">");
    const preceding_header = try std.mem.replaceOwned(u8, a, header_open, ">image</td>", ">image</th>");
    for ([_][]const u8{ later_row, leading_text, leading_child, trailing_text, trailing_child, preceding_header }) |ineligible| {
        // Even a non-root/later-row/nonexclusive candidate must count when a
        // separate root candidate shares its signature. Both orders refuse.
        try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source,
            try std.mem.concat(a, u8, &.{ F.root, F.table, "<div>", ineligible, "</div></div>" })));
        try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source,
            try std.mem.concat(a, u8, &.{ F.root, "<div>", ineligible, "</div>", F.table, "</div>" })));
    }
    const nbsp_html = try std.mem.replaceOwned(u8, a, F.table, "literal quote.", "literal&#160;quote.");
    try std.testing.expectEqual(@as(usize, 1), try F.count(a, &ns, F.source, try std.mem.concat(a, u8, &.{ F.root, nbsp_html, "</div>" })));
    const nbsp_source = try std.mem.replaceOwned(u8, a, F.source, "literal quote.", "literal&#160;quote.");
    const nbsp_collision = try std.mem.concat(a, u8, &.{ F.source, nbsp_source });
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, nbsp_collision, F.root ++ F.table ++ "</div>"));
    const extra_cell = try std.mem.replaceOwned(u8, a, F.table, "<tr>", "<tr><td>additional</td>");
    try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, F.source, try std.mem.concat(a, u8, &.{ F.root, extra_cell, "</div>" })));
}

test "observed root table proof refuses executing anchors and unclosed initial cell holders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = RootTableAnchorTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(StaticPosterContextTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    for ([_][]const u8{ "{{Whole}}", "[[Whole]]", "ISBN literal", "https://example.org", "&#123;&#123;Whole&#125;&#125;", "__NOTOC__", "''Whole''", "<span>Whole</span>" }) |text| {
        const source = try std.mem.replaceOwned(u8, a, F.source, "Whole literal quote.", text);
        try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, source, F.root ++ F.table ++ "</div>"));
    }
    for ([_][]const u8{ "<nowiki>", "<div>", "{|", "|-", "[[Unknown:File|caption]]", "[[Immagine:File|caption]]<span>" }) |body| {
        const source = try std.mem.replaceOwned(u8, a, F.source, "[[Immagine:Wikiquote-logo.svg|15px|literal caption]]", body);
        try std.testing.expectEqual(@as(usize, 0), try F.count(a, &ns, source, F.root ++ F.table ++ "</div>"));
    }
}


const PageStylesV7Testing = struct {
    const prefix = "testdata/de-mai-page-styles/";
    const original = @embedFile(prefix ++ "original.json");
    const reference = @embedFile(prefix ++ "reference.json");
    const raw = @embedFile("testdata/de-mai301/page.raw.wikitext");
    const css = @embedFile("testdata/de-polish-states/common.css");
    fn document(a: A, bytes: []const u8) !Document {
        return std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    }
};

test "independent original and reference page styles retain complete sources without reference media authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    const old = try Testing.document(a, "de-mai");
    var parent = try profile.parseForTargetAlloc(a, PageStylesV7Testing.css, .screen); defer parent.deinit();
    for ([_][]const u8{ PageStylesV7Testing.original, PageStylesV7Testing.reference }, 0..) |bytes, arm| {
        const doc = try PageStylesV7Testing.document(a, bytes);
        var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
        const source = (try responseSource(a, &ns, doc.pages[0])).source;
        try std.testing.expectEqualStrings(if (arm == 0) @embedFile("testdata/de-mai301/page.expanded.wikitext") else @embedFile("testdata/de-mai301/reference.expanded.wikitext"), source);
        if (arm == 0) try std.testing.expectEqualDeep(old.pages[0].occurrences, doc.pages[0].occurrences)
        else try std.testing.expectEqual(@as(usize, 0), book.pages[0].occurrences.len);
        const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(selected.source.ptr == source.ptr and selected.source.len == source.len);
        try std.testing.expect(selected.styles.page_style_parent == &parent and selected.scope.page_styles == selected.styles);
        try std.testing.expectEqualStrings("mw-content-ltr mw-parser-output", selected.scope.page_style_root.?.classes);
        try std.testing.expect(!selected.scope.page_style_root.?.physical_ancestry_complete);
        var ancestor = selected.scope.page_style_root.?.parent;
        var ancestor_count: usize = 0;
        var content = false;
        while (ancestor) |node| : (ancestor = node.parent) {
            ancestor_count += 1;
            try std.testing.expect(!node.ancestry_complete and !node.physical_ancestry_complete);
            if (profile.Profile.hasClass(node.classes, "mw-body-content")) content = true;
        }
        try std.testing.expectEqual(@as(usize, 8), ancestor_count);
        try std.testing.expect(content);
        try std.testing.expectEqual(@as(usize, 4), selected.styles.sources.len);
        const hashes = [_][]const u8{
            "bad9e70537494dc2a02cbf4e06e2f300addf1564379dbce7bce5c493dba6ce98",
            "3d2b0b96116abbbbc0c1777ff54f5ee1a2d62d6cebce8125136b887e46479d29",
            "99d1da9c951ab87c7cc3e174c7b11f4b3537aa9ab66bc6bedb4e18b399c05c4b",
            "3ba3d0aad75479a1b521d9d937ed01b21157c2ddfc8592a0e5636712ad32406c",
        };
        for (selected.styles.sources, hashes) |item, hash| try std.testing.expectEqualStrings(hash, &item.css_sha256);
        try std.testing.expectEqual(@as(usize, 2857), selected.styles.sources[3].bytes);
        try std.testing.expectEqual(@as(usize, 1), parent.sources.len);
        // Inspect the same rule inventory used by ordinary paragraph projection.
        const paragraph: profile.TextElement = .{ .tag = "p", .page_style_root = selected.scope.page_style_root };
        const rules = try selected.styles.containerRuleMatchesIn(a, &paragraph); defer a.free(rules.rules);
        try std.testing.expect(!rules.unresolved);
        var found = false;
        for (rules.rules) |rule| if (std.mem.eql(u8, rule.css, "margin:0.4em 0 0.5em 0") and rule.match == .known) { found = true; };
        try std.testing.expect(found);
        if (arm == 1) try std.testing.expect((try book.select(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, 250, .{ .title = "Mai", .namespace_catalog = &ns })) == null);
        try std.testing.expect(book.pages[0].text_class_scope.?.page_styles == null);
    }
}

test "page style selection refuses wrong identity source defaults and nested parent without lending reference media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    var book = try Book.init(a, PageStylesV7Testing.reference, &ns, &files, defaults, 250); defer book.deinit();
    var parent = try profile.parseForTargetAlloc(a, "", .screen); defer parent.deinit();
    const source = @embedFile("testdata/de-mai301/reference.expanded.wikitext");
    const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 722, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777071, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Other", PageStylesV7Testing.raw, source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", "changed raw", source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, @embedFile("testdata/de-mai301/page.expanded.wikitext"), defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, @as([32]u8, @splat(0)), &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, selected.styles)) == null);
    var unknown = try profile.parseAlloc(a, ""); defer unknown.deinit();
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &unknown)) == null);
    const copied = try a.dupe(u8, source);
    const rebound = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, copied, defaults, &parent)) orelse return error.TestUnexpectedResult;
    // A complete independently checked copy is a new selection, never a fragment grant.
    try std.testing.expect(rebound.source.ptr == copied.ptr and rebound.source.ptr != source.ptr);
}

test "page styles preserve strict schema body receipt outer and complete emitted set refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    for (0..9) |mutation| {
        var shape = try json(a, PageStylesV7Testing.reference);
        const page = &shape.object.getPtr("pages").?.array.items[0];
        switch (mutation) {
            0 => { _ = page.object.swapRemove("page_styles"); },
            1 => try page.object.put(a, "page_styles", .null),
            2 => try page.object.put(a, "text_class_scope", .{ .bool = false }),
            3 => { _ = page.object.swapRemove("outer_context"); },
            4 => try shape.object.put(a, "schema", .{ .string = "wikidict.figure-page-observations.v4" }),
            5 => try page.object.put(a, "response", .{ .string = "{}" }),
            6 => try page.object.getPtr("page_styles").?.object.put(a, "receipt", .{ .string = "{}" }),
            7 => try page.object.getPtr("page_styles").?.object.put(a, "extra", .{ .bool = true }),
            else => page.object.getPtr("page_styles").?.object.getPtr("responses").?.array.items[0] = .{ .string = "p{margin:0}" },
        }
        const bytes = try std.json.Stringify.valueAlloc(a, shape, .{});
        // The strict JSON shape parser rejects the added field before the
        // semantic constructor checks; all other mutations reach those checks.
        try std.testing.expectError(if (mutation == 7) error.UnknownField else error.InvalidFigurePageObservations,
            Book.init(a, bytes, &ns, &files, defaults, 250));
    }
}


test "literal root child style equivalence is limited to a final plain semicolon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const plain = "margin-bottom:-0.5em; font-weight:bold;";
    try std.testing.expectEqualStrings(plain, (try closedRootChildStyle(a, plain)).?);
    try std.testing.expectEqualStrings(plain, (try closedRootChildStyle(a, plain ++ "   ")).?);
    for ([_][]const u8{ "color:red ", "color:red;\t", "color:red;/* */ ", "content:'literal; '; ", "font-family:\"literal; \"; ", "font-family:escaped\\ ; ", "color:var(--x); ", "color:red;broken", "color:red;!", "color:red;\n" }) |css| {
        errdefer std.debug.print("closed root child CSS refusal: {s}\n", .{css});
        try std.testing.expect((try closedRootChildStyle(a, css)) == null);
    }
    const source = "<p style=\"font-weight:bold; \" title=\"Label\">Unique:</p>";
    const observed = "<p style=\"font-weight:bold;\" title=\"Label\">Unique:</p>";
    try std.testing.expect(sameRootChildAnchor((try sourceRootChildAnchor(a, source, 0)).?, (try sourceRootChildAnchor(a, observed, 0)).?));
    for ([_][]const u8{
        "<p class=\"{{ClassName}}\">Unique:</p>", "<p title=\"&#123;&#123;ClassName&#125;&#125;\">Unique:</p>",
        "<p>https://example.org:</p>", "<p>__NOTOC__:</p>", "<p>[[Target]]:</p>",
        "<p>Unique:<span>extra</span></p>", "<p/>Unique:</p>", "<p>Unique:</p/>",
        "<p style=\"content:'text';\">Unique:</p>", "<p title=\"run|text\">Unique:</p>",
    }) |bad| try std.testing.expect((try sourceRootChildAnchor(a, bad, 0)) == null);
}

test "root child correspondence requires unique whole anchors and exact observed parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const source = "<p style=\"font-weight:bold; \" title=\"Label\">Unique:</p>";
    const actual = "<p style=\"font-weight:bold;\" title=\"Label\">Unique:</p>";
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"de\" dir=\"ltr\">";
    const whole = try std.mem.concat(a, u8, &.{ root, actual, "</div>" });
    var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
    _ = try observedTextClassScopeWithElements(a, &ns, whole, &nodes);
    const proven = try observedSourceRootChildren(a, source, whole, nodes.items);
    try std.testing.expectEqual(@as(usize, 1), proven.len);
    try std.testing.expectEqual(@as(usize, 0), proven[0].anchor_start);
    try std.testing.expectEqual(source.len, proven[0].anchor_end);
    const duplicate_source = try std.mem.concat(a, u8, &.{ source, "<nowiki>", source, "</nowiki>" });
    try std.testing.expectEqual(@as(usize, 0), (try observedSourceRootChildren(a, duplicate_source, whole, nodes.items)).len);
    for ([_][]const u8{
        try std.mem.concat(a, u8, &.{ root, actual, actual, "</div>" }),
        try std.mem.concat(a, u8, &.{ root, "<div>", actual, "</div></div>" }),
        try std.mem.replaceOwned(u8, a, whole, "font-weight:bold;", "font-weight:normal;"),
        try std.mem.replaceOwned(u8, a, whole, "title=\"Label\"", "title=\"Other\""),
    }) |html| {
        var changed: std.ArrayList(ObservedSiblingNode) = .empty;
        _ = try observedTextClassScopeWithElements(a, &ns, html, &changed);
        try std.testing.expectEqual(@as(usize, 0), (try observedSourceRootChildren(a, source, html, changed.items)).len);
    }
}

test "actual original and independent reference Mai issue only five unique literal root paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    var parent = try profile.parseForTargetAlloc(a, PageStylesV7Testing.css, .screen); defer parent.deinit();
    for ([_][]const u8{ PageStylesV7Testing.original, PageStylesV7Testing.reference }, 0..) |bytes, arm| {
        const doc = try PageStylesV7Testing.document(a, bytes);
        var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
        const source = (try responseSource(a, &ns, doc.pages[0])).source;
        const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 5), selected.scope.source_root_children.len);
        const labels = [_][]const u8{ "Nebenformen:", "Herkunft:", "Synonyme:", "Redewendungen:", "Anmerkung:" };
        for (selected.scope.source_root_children, labels) |proof, label| {
            const anchor = (try sourceRootChildAnchor(a, source, proof.anchor_start)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(label, anchor.text);
            try std.testing.expectEqualDeep(proof, anchor.range);
        }
        try std.testing.expect(selected.scope.source_root_children_source.?.ptr == source.ptr);
        try std.testing.expect(selected.scope.page_style_complete_root.?.physical_ancestry_complete);
        try std.testing.expect(!selected.scope.page_style_root.?.physical_ancestry_complete);
        try std.testing.expect(selected.scope.page_style_complete_root != selected.scope.page_style_root);
        var actual_html = selected.scope.page_style_complete_root.?;
        var alternate_html = actual_html.alternative_ancestry orelse return error.TestUnexpectedResult;
        while (actual_html.parent) |node| { actual_html = node; alternate_html = alternate_html.parent orelse return error.TestUnexpectedResult; }
        try std.testing.expect(alternate_html.parent == null and alternate_html.alternative_ancestry == null);
        try std.testing.expect(!profile.Profile.hasClass(actual_html.classes, "vector-toc-available"));
        try std.testing.expect(profile.Profile.hasClass(alternate_html.classes, "vector-toc-available"));
        try std.testing.expectEqual(@as(usize, if (arm == 0) 2 else 0), book.pages[0].occurrences.len);
        try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 722, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) == null);
        try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source[0 .. source.len - 1], defaults, &parent)) == null);
    }
}


test "actual Mai retains every observed ancestor variable environment independently in both source arms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    var parent = try profile.parseForTargetAlloc(a, PageStylesV7Testing.css, .screen); defer parent.deinit();
    for ([_][]const u8{ PageStylesV7Testing.original, PageStylesV7Testing.reference }, 0..) |bytes, arm| {
        const doc = try PageStylesV7Testing.document(a, bytes);
        var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
        const source = (try responseSource(a, &ns, doc.pages[0])).source;
        const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
        const custom = selected.styles.custom_properties orelse return error.TestUnexpectedResult;
        const root = selected.scope.page_style_complete_root.?;
        const alternate = root.alternative_ancestry.?;
        const combined = try commonObservedCustomEnvironment(a, root.observed_custom_environment.?, alternate.observed_custom_environment.?);
        // These actual roots have no authored custom declaration overrides;
        // the unchanged final environment agrees with the two exact root nodes.
        try std.testing.expectEqualDeep(custom.root_environment, combined);
        var node: ?*const profile.TextElement = root;
        var count: usize = 0;
        while (node) |actual| : (node = actual.parent) {
            try std.testing.expect(actual.observed_custom_environment != null);
            try std.testing.expect(actual.alternative_ancestry.?.observed_custom_environment != null);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 9), count);
        try std.testing.expectEqual(@as(usize, 5), selected.scope.source_root_children.len);
        try std.testing.expectEqual(@as(usize, if (arm == 0) 2 else 0), book.pages[0].occurrences.len);
        try std.testing.expect(selected.scope.source_root_children_source.?.ptr == source.ptr);
        try std.testing.expect((try selected.styles.pageUnprovedInheritanceBlockerIn(a, selected.scope.page_style_root)) != null);
        try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source[0 .. source.len - 1], defaults, &parent)) == null);
    }
}


const CommonRootParentTesting = struct {
    fn proofs(a: A, ns: *const namespaces.Registry, source: []const u8, html: []const u8) ![]const profile.SourceRootParentProof {
        var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
        _ = try observedTextClassScopeWithElements(a, ns, html, &nodes);
        return observedCommonRootParents(a, source, html, nodes.items);
    }
};
test "repeated closed paragraphs issue only universally identical root parent facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const authored = "<p style=\"font-weight:bold; \" title=\"Label\">Repeated:</p>";
    const actual = "<p style=\"font-weight:bold;\" title=\"Label\">Repeated:</p>";
    const source = authored ++ "\n" ++ authored;
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"de\" dir=\"ltr\">";
    const whole = root ++ actual ++ "<!-- element order is not lent -->" ++ actual ++ "</div>";
    const proofs = try CommonRootParentTesting.proofs(a, &ns, source, whole);
    try std.testing.expectEqual(@as(usize, 2), proofs.len);
    for (proofs, [_]usize{ 0, authored.len + 1 }) |proof, offset| {
        try std.testing.expectEqual(@as(u16, 2), proof.candidate_count);
        try std.testing.expectEqualDeep((try sourceRootChildAnchor(a, source, offset)).?.range, proof.anchor);
    }
    // Singletons stay in the unchanged unique issuer, not this common-fact path.
    try std.testing.expectEqual(@as(usize, 0), (try CommonRootParentTesting.proofs(a, &ns, authored, root ++ actual ++ "</div>")).len);
    for ([_][]const u8{
        root ++ actual ++ "</div>", root ++ actual ++ actual ++ actual ++ "</div>",
        root ++ actual ++ "<div>" ++ actual ++ "</div></div>",
        root ++ "<div class=\"different\" style=\"--ink:red;\">" ++ actual ++ actual ++ "</div></div>",
        root ++ actual ++ "<p style=\"font-weight:normal;\" title=\"Label\">Repeated:</p></div>",
        root ++ actual ++ "<p style=\"font-weight:bold;\" title=\"Label \">Repeated:</p></div>",
        // CSS-semantic trailing space does not erase unequal actual DOM attrs.
        root ++ actual ++ authored ++ "</div>",
        root ++ actual ++ "<p style=\"font-weight:bold;\" title=\"Label\"><span>Repeated:</span></p></div>",
    }) |denied| try std.testing.expectEqual(@as(usize, 0), (try CommonRootParentTesting.proofs(a, &ns, source, denied)).len);
    const protected_duplicate = authored ++ "<nowiki>" ++ authored ++ "</nowiki>";
    try std.testing.expectEqual(@as(usize, 0), (try CommonRootParentTesting.proofs(a, &ns, protected_duplicate, root ++ actual ++ "</div>")).len);
    const other_source = authored ++ "<p title=\"Changed\">Repeated:</p>";
    try std.testing.expectEqual(@as(usize, 0), (try CommonRootParentTesting.proofs(a, &ns, other_source, whole)).len);
}

test "actual Mai repeated paragraph groups retain common root ancestry in both independent source arms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    var parent = try profile.parseForTargetAlloc(a, PageStylesV7Testing.css, .screen); defer parent.deinit();
    const labels = [_][]const u8{ "Worttrennung:", "Aussprache:", "Abkürzungen:", "Gegenwörter:", "Oberbegriffe:", "Beispiele:", "Charakteristische Wortkombinationen:", "Alternative Schreibweisen:" };
    const counts = [_]u16{ 4, 4, 2, 2, 2, 4, 2, 2 };
    for ([_][]const u8{ PageStylesV7Testing.original, PageStylesV7Testing.reference }, 0..) |bytes, arm| {
        const doc = try PageStylesV7Testing.document(a, bytes);
        var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
        const source = (try responseSource(a, &ns, doc.pages[0])).source;
        const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 5), selected.scope.source_root_children.len);
        try std.testing.expectEqual(@as(usize, 22), selected.scope.source_root_parent_groups.len);
        var consumed = @as([labels.len]u16, @splat(0));
        for (selected.scope.source_root_parent_groups) |proof| {
            const anchor = (try sourceRootChildAnchor(a, source, proof.anchor.anchor_start)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualDeep(anchor.range, proof.anchor);
            var found = false;
            for (labels, counts, 0..) |label, count, index| if (equal(anchor.text, label)) {
                try std.testing.expectEqual(count, proof.candidate_count); consumed[index] += 1; found = true; break;
            };
            try std.testing.expect(found);
        }
        try std.testing.expectEqualDeep(counts, consumed);
        const root = selected.scope.page_style_complete_root.?;
        const alternate = root.alternative_ancestry.?;
        try std.testing.expect(root != alternate and root.observed_custom_environment != null and alternate.observed_custom_environment != null);
        try std.testing.expectEqualDeep(selected.styles.custom_properties.?.root_environment,
            try commonObservedCustomEnvironment(a, root.observed_custom_environment.?, alternate.observed_custom_environment.?));
        try std.testing.expectEqual(@as(usize, if (arm == 0) 2 else 0), book.pages[0].occurrences.len);
        try std.testing.expect((try selected.styles.pageUnprovedInheritanceBlockerIn(a, selected.scope.page_style_root)) != null);
        try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source[0 .. source.len - 1], defaults, &parent)) == null);
    }
}


const ThPaletteTesting = struct {
    const prefix = "testdata/th-page-palette/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    fn document(a: A) !Document { return std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }); }
    // Controlled rows qualify Book validation only; full Writer qualification
    // still uses the independent, complete normal Registry package.
    fn registry(a: A, ns: *const namespaces.Registry, doc: Document) !sizing.Registry {
        var rows: std.ArrayList(sizing.Record) = .empty;
        var missing: std.StringHashMapUnmanaged(void) = .empty;
        for (doc.pages) |page| for (page.occurrences) |occurrence| {
            if (occurrence.missing_content) { try missing.put(a, occurrence.canonical_file, {}); continue; }
            try rows.append(a, .{ .canonical_file = occurrence.canonical_file, .file_sha1 = occurrence.file_sha1,
                .file_timestamp = occurrence.file_timestamp, .original_width = occurrence.original_width,
                .original_height = occurrence.original_height, .format = .thumbnail, .width_px = occurrence.original_width,
                .height_px = null, .sizing = .requested_fit, .proof_kind = "controlled-validator-file-row" });
        };
        return .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = ns, .records = rows.items,
            .missing_files = missing, .file_authority = true };
    }
    fn known(environment: profile.CustomEnvironment, name: []const u8, expected: []const u8) !void {
        const value = environment.get(name);
        try std.testing.expect(value == .known);
        try std.testing.expectEqualStrings(expected, value.known);
    }
};
test "complete retained TH page palette preserves all old pages Missing proof and exact note colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(ThPaletteTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(ThPaletteTesting.prefix ++ "figure-siteinfo.raw.json"));
    const doc = try ThPaletteTesting.document(a);
    const old = try std.json.parseFromSliceLeaky(Document, a, @embedFile(ThPaletteTesting.prefix ++ "prior-v4.json"), .{});
    try std.testing.expectEqual(@as(usize, 4), doc.pages.len);
    try std.testing.expectEqualDeep(old.missing_link_styles, doc.missing_link_styles);
    for (old.pages, doc.pages) |before, after| {
        var without_style = after; without_style.page_styles = null;
        try std.testing.expectEqualDeep(before, without_style);
        try std.testing.expect((after.page_styles != null) == (after.page_id == 108817));
    }
    var files = try ThPaletteTesting.registry(a, &ns, doc); defer files.deinit();
    var book = try Book.init(a, ThPaletteTesting.bytes, &ns, &files, defaults, 250); defer book.deinit();
    var parent = try profile.parseForTargetAlloc(a, @embedFile(ThPaletteTesting.prefix ++ "common.css"), .screen); defer parent.deinit();
    const raw = @embedFile(ThPaletteTesting.prefix ++ "page.raw.wikitext");
    const source = @embedFile(ThPaletteTesting.prefix ++ "page.expanded.wikitext");
    try std.testing.expectEqual(@as(usize, 59937), source.len);
    const selected = (try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), selected.scope.source_custom_elements.len);
    try std.testing.expect(selected.scope.source_custom_elements_source.?.ptr == source.ptr);
    for (selected.scope.source_custom_elements) |proof| {
        try std.testing.expectEqual(@as(u32, 3), proof.candidate_count);
        _ = (try sourceCustomAnchor(a, source, proof.range.anchor_start)) orelse return error.TestUnexpectedResult;
    }
    const environment = selected.scope.page_custom_invariant orelse return error.TestUnexpectedResult;
    try ThPaletteTesting.known(environment, "--wikt-palette-forestgreen", "#235923");
    try ThPaletteTesting.known(environment, "--wikt-palette-lightyellow", "#ffffe0");
    const note = "border: 1px solid var(--wikt-palette-forestgreen, #235923); padding: 4px; margin: 8px; background: var(--wikt-palette-lightyellow, #ffffe0); font-size: 85%";
    var own = try profile.parseForTargetAlloc(a, "", .screen); defer own.deinit();
    const node: profile.TextElement = .{ .tag = "div", .ancestry_complete = true };
    const painted = try own.resolveContainerInWithCustom(a, &node, note, environment);
    try std.testing.expect(!painted.unresolved);
    try std.testing.expectEqualStrings("#235923", painted.style.border.?.solid.color.rgb);
    try std.testing.expectEqualStrings("#ffffe0", painted.style.background.?.rgb);
    try std.testing.expectEqualDeep(encoder.presentation_types.StyleLength{ .unit = .px, .value = 4 }, painted.style.padding.?.top);
    try std.testing.expectEqualDeep(encoder.presentation_types.StyleLength{ .unit = .px, .value = 8 }, painted.style.margins.?.top);
    try std.testing.expect((try own.resolveContainerInWithCustom(a, &node, note, .{})).unresolved);
    // Palette agreement does not erase unsupported inherited effects or grant
    // any of the unchanged media callbacks, language ownership or scrollport.
    try std.testing.expect((try selected.styles.pageUnprovedInheritanceBlockerIn(a, selected.scope.page_style_root)) != null);
    for (book.pages) |page| {
        if (page.page_id != 108817) {
            try std.testing.expect(page.page_styles == null and page.source_root_children.len == 0 and
                page.source_root_parent_groups.len == 0 and page.root_attributes == null);
            continue;
        }
        try std.testing.expect(page.page_styles.?.observed_nodes.len > 1000);
        try std.testing.expectEqual(@as(usize, 1), page.occurrences.len);
        const missing = page.occurrences[0].missing_content orelse return error.TestUnexpectedResult;
        try std.testing.expect(missing.paint_root_proven and missing.right and missing.data_width == 100);
        try std.testing.expectEqualStrings(doc.pages[2].occurrences[0].canonical_file, missing.label);
    }
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190989, "間", raw, source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw, source[1..], defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", "changed", source, defaults, &parent)) == null);
}

test "page custom invariant visits every physical node and withholds differing unknown or malformed paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"de\" dir=\"ltr\">";
    var styles = try profile.parseForTargetAlloc(a, "", .screen); defer styles.deinit();
    try profile.attachCustomProperties(&styles, &.{.{ .css = ":root{--ink:#123456;--stable:#235923}.changed{--ink:#ff0000}.unknown{--ink:var(--unproved)}", .base_url = "" }},
        .{ .ancestors = &.{.{ .tag = "html", .root = true }} });
    const custom = styles.custom_properties.?;
    for ([_][]const u8{ "", "changed", "unknown" }, 0..) |class_name, mode| {
        const html = try std.fmt.allocPrint(a, root ++ "<div><span class=\"{s}\">text</span></div></div>", .{class_name});
        var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
        _ = try observedTextClassScopeWithElements(a, &ns, html, &nodes);
        const agreement = try observedPageCustomInvariant(a, custom, nodes.items, custom.root_environment, custom.root_environment);
        try ThPaletteTesting.known(agreement, "--stable", "#235923");
        if (mode == 0) try ThPaletteTesting.known(agreement, "--ink", "#123456")
        else try std.testing.expect(agreement.get("--ink") == .unknown);
        const alternate: profile.CustomEnvironment = .{ .complete = true, .values = &.{.{ .name = "--ink", .value = .{ .known = "#000000" } }} };
        const different_shell = try observedPageCustomInvariant(a, custom, nodes.items, custom.root_environment, alternate);
        try std.testing.expect(different_shell.get("--ink") == .unknown and different_shell.get("--stable") == .unknown);
        const unknown_shell = try observedPageCustomInvariant(a, custom, nodes.items, custom.root_environment, .{});
        try std.testing.expect(unknown_shell.get("--stable") == .unknown);
        const old_parent = nodes.items[2].parent;
        nodes.items[2].parent = 2;
        try std.testing.expectError(invalid, observedPageCustomInvariant(a, custom, nodes.items, custom.root_environment, custom.root_environment));
        nodes.items[2].parent = old_parent;
    }
    try std.testing.expectError(invalid, observedPageCustomInvariant(a, custom, &.{}, custom.root_environment, custom.root_environment));
}


test "custom element issuance requires complete closed source operation and equal observed candidate census" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const F = struct {
        fn proofs(allocator: A, catalog: *const namespaces.Registry, input: []const u8, html: []const u8) ![]const profile.SourceCustomElementProof {
            var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
            _ = try observedTextClassScopeWithElements(allocator, catalog, html, &nodes);
            return observedSourceCustomElements(allocator, input, html, nodes.items);
        }
    };
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"de\" dir=\"ltr\">";
    const source = "<div style=\"background:var(--paper);\">'''Note''': body</div>";
    const observed = "<div style=\"background:var(--paper);\"><b>Note</b>: body</div>";
    const both = try std.mem.concat(a, u8, &.{source, "\n", source});
    const html = try std.mem.concat(a, u8, &.{root, observed, "<div>", observed, "</div></div>"});
    const prefixed = try std.mem.concat(a, u8, &.{ "prefix ", source });
    try std.testing.expect((try sourceCustomAnchor(a, prefixed, 7)) == null);
    const proofs = try F.proofs(a, &ns, both, html);
    try std.testing.expectEqual(@as(usize, 2), proofs.len);
    for (proofs) |proof| try std.testing.expectEqual(@as(u32, 2), proof.candidate_count);
    try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, both, root ++ observed ++ "</div>")).len);
    try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, source, html)).len);
    const changed = "<div style=\"--ink:blue;background:var(--paper);\">'''Note''': body</div>";
    try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, changed, root ++ observed ++ "</div>")).len);
    for ([_][]const u8{
        "<div>label</div>", "<div/>'''Note''': body</div>",
        "<div style=\"color:var(--ink\">'''Note''': body</div>",
        "<div class=\"{{ClassName}}\">'''Note''': body</div>",
        "<div class=\"&#123;&#123;ClassName&#125;&#125;\">'''Note''': body</div>",
        "<div style=\"--ink:var(--x,{{value}})\">'''Note''': body</div>",
        "<div style=\"--ink:&#123;&#123;value&#125;&#125;\">'''Note''': body</div>",
        "<div style=\"color:red\" style=\"color:blue\">'''Note''': body</div>",
        "<div>'''https://example.org''': body</div>",
        "<div>'''__NOTOC__''': body</div>",
        "<div>'''{{label}}''': body</div>",
    }) |unsupported| try std.testing.expect((try sourceCustomAnchor(a, unsupported, 0)) == null);
}

test "custom palette source census refuses ignored contexts and requires a whole ordinary DIV operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const F = struct {
        fn proofs(allocator: A, catalog: *const namespaces.Registry, input: []const u8, html: []const u8) ![]const profile.SourceCustomElementProof {
            var nodes: std.ArrayList(ObservedSiblingNode) = .empty;
            _ = try observedTextClassScopeWithElements(allocator, catalog, html, &nodes);
            return observedSourceCustomElements(allocator, input, html, nodes.items);
        }
    };
    const root = "<div class=\"mw-content-ltr mw-parser-output\" lang=\"de\" dir=\"ltr\">";
    const source = "<div style=\"background:var(--paper);\">'''Note''': body</div>";
    const observed = "<div style=\"background:var(--paper);\"><b>Note</b>: body</div>";
    // A hidden/protected lexical signature cannot balance a different, midline
    // actual operation and lend that operation's palette to a source opening.
    for ([_][2][]const u8{
        .{ "<!--\n", "\n-->" }, .{ "<nowiki>\n", "\n</nowiki>" },
        .{ "<pre>\n", "\n</pre>" }, .{ "<includeonly>\n", "\n</includeonly>" },
        .{ "<ref>\n", "\n</ref>" }, .{ "<select>\n", "\n</select>" },
        .{ "<template>\n", "\n</template>" }, .{ "[[target|\n", "]]" },
        .{ "{|\n|\n", "\n|}" }, .{ "<table><tr><td>\n", "</td></tr></table>" },
    }) |scope| {
        const collision = try std.mem.concat(a, u8, &.{ scope[0], source, scope[1], "\nprefix ", source });
        try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, collision, root ++ observed ++ "</div>")).len);
    }
    for ([_][]const u8{ "{{GeneratedLiteral}}\n", "{<!-- join -->{GeneratedLiteral}}\n", "<unknown>\n", "<div title=\"unterminated>\n", "<div class=\"{{ClassName}}\">\n", "<!-- unclosed\n", "<nowiki>unclosed\n", "[[unclosed\n", "{|\n", "<table>\n" }) |prefix| {
        const uncertain = try std.mem.concat(a, u8, &.{prefix, source});
        try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, uncertain, root ++ observed ++ "</div>")).len);
    }
    const incomplete = "<div style=\"background:var(--paper);\">'''Note''': body";
    try std.testing.expect((try sourceCustomAnchor(a, incomplete, 0)) == null);
    const wrapped = "<div class=\"ordinary\"><span>prefix</span>\n" ++ source ++ "</div>";
    const plain = try F.proofs(a, &ns, wrapped, root ++ "<div class=\"ordinary\"><span>prefix</span>" ++ observed ++ "</div></div>");
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqual(source.len, plain[0].range.anchor_end - plain[0].range.anchor_start);
    // Ignored raw anchors are never issued; a later independently ordinary
    // operation may still be proved without selecting a DOM identity.
    const after_comment = "<!--\n" ++ source ++ "\n-->\n" ++ source;
    const actual = try F.proofs(a, &ns, after_comment, root ++ observed ++ "</div>");
    try std.testing.expectEqual(@as(usize, 1), actual.len);
    try std.testing.expect(actual[0].range.anchor_start > source.len);

    const duplicate_prefix = "<span class=\"first\" CLASS=\"second\">prefix</span>\n";
    const after_duplicate = try F.proofs(a, &ns, duplicate_prefix ++ source,
        root ++ "<span class=\"second\">prefix</span>" ++ observed ++ "</div>");
    try std.testing.expectEqual(@as(usize, 1), after_duplicate.len);
    try std.testing.expectEqual(@as(usize, duplicate_prefix.len), after_duplicate[0].range.anchor_start);
    try std.testing.expectEqual(@as(usize, source.len), after_duplicate[0].range.anchor_end - after_duplicate[0].range.anchor_start);
    try std.testing.expectEqual(@as(u32, 1), after_duplicate[0].candidate_count);
    const duplicate_tag = syntax.tagAt(duplicate_prefix, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.InvalidFigurePageObservations, inventory(a, duplicate_tag));
    try std.testing.expectError(error.InvalidFigurePageObservations,
        F.proofs(a, &ns, source, root ++ duplicate_prefix ++ observed ++ "</div>"));
    const duplicate_anchor = "<div class=\"first\" class=\"second\" style=\"background:var(--paper);\">'''Note''': body</div>";
    try std.testing.expect((try sourceCustomAnchor(a, duplicate_anchor, 0)) == null);
    for ([_][]const u8{
        "<span style=\"color:red\" style=\"color:blue\">prefix</span>\n",
        "<span class=\"first\" class=\"{{Generated}}\">prefix</span>\n",
    }) |prefix| {
        const refused = try std.mem.concat(a, u8, &.{ prefix, source });
        try std.testing.expectEqual(@as(usize, 0), (try F.proofs(a, &ns, refused, root ++ observed ++ "</div>")).len);
    }
}

const CombinedObservationTesting = if (@import("builtin").is_test) struct {
    const prefix = "testdata/vi-all12-capabilities/";
    const snapshot = @embedFile(prefix ++ "figure-page-observations.json");
    const Slice = struct {
        bytes: []const u8,
        fn readAt(ctx: *anyopaque, destination: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const at = std.math.cast(usize, offset) orelse return 0;
            if (at >= self.bytes.len) return 0;
            const count = @min(destination.len, self.bytes.len - at);
            @memcpy(destination[0..count], self.bytes[at .. at + count]);
            return count;
        }
    };
    fn registry(a: A, ns: *const namespaces.Registry) !sizing.Registry {
        const projected = @embedFile(prefix ++ "figure-sizing.json");
        const captured = @embedFile(prefix ++ "figure-sizing.raw.json");
        var projection: Slice = .{ .bytes = projected };
        var raw: Slice = .{ .bytes = captured };
        var projection_input: sizing.StreamInput = .{ .context = &projection, .read_at = Slice.readAt, .size = projected.len };
        var raw_input: sizing.StreamInput = .{ .context = &raw, .read_at = Slice.readAt, .size = captured.len };
        var result = try sizing.Registry.initStream(a, &projection_input, &raw_input, @embedFile(prefix ++ "figure-sizing.site.json"), ns,
            "f45897451256aa3799aecc5d7ee320ade22beaec");
        errdefer result.deinit();
        try std.testing.expectEqualDeep(Testing.hash(projected), projection_input.digest orelse return error.TestUnexpectedResult);
        try std.testing.expectEqualDeep(Testing.hash(captured), raw_input.digest orelse return error.TestUnexpectedResult);
        try std.testing.expect(result.file_authority);
        return result;
    }
    fn parsedPage(book: *const Book, id: u64) !Page {
        for (book.pages) |candidate| if (candidate.page_id == id) return candidate;
        return error.TestUnexpectedResult;
    }
} else struct {};

test "v7 genuine normal package composes twelve independent Missing and SVG language pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const T = CombinedObservationTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(T.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try T.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(T.prefix ++ "figure-siteinfo.raw.json"));
    try std.testing.expect(digestMatches(T.snapshot, "087837e25d350421133f759ca869dd7dd8411f1ace99e8a8b509bef9a0081c03"));
    const doc = try std.json.parseFromSliceLeaky(Document, a, T.snapshot, .{ .allocate = .alloc_always });
    const old = try std.json.parseFromSliceLeaky(Document, a, @embedFile(T.prefix ++ "all11-v4.json"), .{ .allocate = .alloc_always });
    const language = try std.json.parseFromSliceLeaky(Document, a, @embedFile(T.prefix ++ "acceleration-v6.json"), .{ .allocate = .alloc_always });
    try std.testing.expectEqual(@as(usize, 12), doc.pages.len);
    try std.testing.expectEqualDeep(old.pages, doc.pages[0..11]);
    try std.testing.expectEqualDeep(language.pages[0], doc.pages[11]);
    try std.testing.expectEqualDeep(old.missing_link_styles, doc.missing_link_styles);
    var book = try Book.init(a, T.snapshot, &ns, &files, defaults, 250); defer book.deinit();
    try std.testing.expectEqual(@as(usize, 12), book.pages.len);
    var missing_count: usize = 0;
    for (doc.pages) |raw_page| {
        const parsed = try T.parsedPage(&book, raw_page.page_id);
        try std.testing.expectEqualStrings((try responseSource(a, &ns, raw_page)).source, parsed.source);
        try std.testing.expectEqual(raw_page.occurrences.len, parsed.occurrences.len);
        for (parsed.occurrences) |occurrence| if (occurrence.missing_content) |missing_value| {
            missing_count += 1;
            try std.testing.expect(missing_value.paint_root_proven);
            try std.testing.expect(occurrence.svg_language == null);
        };
    }
    try std.testing.expectEqual(@as(usize, 8), missing_count);
    const acceleration = try T.parsedPage(&book, 95796);
    const raster = acceleration.occurrences[0].svg_language orelse return error.TestUnexpectedResult;
    try std.testing.expect(raster.authored);
    try std.testing.expectEqualStrings("vi", raster.language);
    try std.testing.expectEqual(@as(u32, 250), raster.width);
    try std.testing.expect(acceleration.occurrences[0].missing_content == null);
    try std.testing.expect(acceleration.text_class_scope.?.complete_ancestor_class_superset != null);
    // Same occurrence objects under earlier schemas remain invalid; a new
    // version does not alter any page request, body, range or style receipt.
    for ([_][]const u8{ "wikidict.figure-page-observations.v4", "wikidict.figure-page-observations.v6" }) |legacy| {
        var changed = doc; changed.schema = legacy;
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
}

test "v7 combined normal Book retains missing copy range and mixed capability refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const T = CombinedObservationTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(T.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try T.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(T.prefix ++ "figure-siteinfo.raw.json"));
    var baseline = try Book.init(a, T.snapshot, &ns, &files, defaults, 250); defer baseline.deinit();
    for (0..10) |mode| {
        errdefer std.debug.print("v7 independent proof refusal mode={d}\n", .{mode});
        const original = try std.json.parseFromSliceLeaky(Document, a, T.snapshot, .{ .allocate = .alloc_always });
        var changed = original;
        const pages = try a.dupe(RawPage, original.pages); changed.pages = pages;
        try std.testing.expect(pages[7].page_id == 43450 and pages[8].page_id == 50098 and pages[11].page_id == 95796);
        switch (mode) {
            0 => changed.missing_link_styles = null,
            1 => pages[7].text_class_scope = false,
            2 => pages[7].outer_context = null,
            3 => pages[7].outer_context = pages[8].outer_context,
            4 => { pages[7].response = pages[8].response; pages[7].receipt = pages[8].receipt; },
            5, 6, 7 => {
                const occurrences = try a.dupe(RawOccurrence, pages[11].occurrences); pages[11].occurrences = occurrences;
                if (mode == 5) occurrences[0].end = 9999999;
                if (mode == 6) occurrences[0].resolved_svg_language = "vi";
                if (mode == 7) occurrences[0].width = true;
            },
            8 => pages[11].source_element_relations = true,
            9 => {
                var legacy = changed.missing_link_styles.?;
                legacy.defaults = "{}"; changed.missing_link_styles = legacy;
            },
            else => unreachable,
        }
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, changed, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250));
    }
    // Deleting just one supplement retains its actual text context and withholds
    // that page's styled Missing paint. The other ten pages and language remain.
    const shape = try json(a, T.snapshot);
    const candidate = &shape.object.getPtr("pages").?.array.items[7];
    try std.testing.expect(candidate.object.swapRemove("missing_served_set"));
    var bounded = try Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250); defer bounded.deinit();
    const omitted = try T.parsedPage(&bounded, 43450);
    try std.testing.expect(omitted.text_class_scope.?.complete_ancestor_class_superset != null);
    try std.testing.expect(!omitted.occurrences[0].missing_content.?.paint_root_proven);
    for (baseline.pages) |before| if (before.page_id != 43450) {
        const after = try T.parsedPage(&bounded, before.page_id);
        try std.testing.expectEqualStrings(before.source, after.source);
        try std.testing.expectEqualDeep(before.occurrences, after.occurrences);
    };
}

test "current complete TH supplied source accepts 131913 byte form without stale source authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/th-current-four/";
    var ns = try namespaces.Registry.init(a, @embedFile(prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const doc = try std.json.parseFromSliceLeaky(Document, a, @embedFile(prefix ++ "figure-page-observations.json"), .{ .allocate = .alloc_always });
    const old = try std.json.parseFromSliceLeaky(Document, a, @embedFile(prefix ++ "prior-v4.json"), .{ .allocate = .alloc_always });
    try std.testing.expectEqualDeep(old.missing_link_styles, doc.missing_link_styles);
    try std.testing.expectEqual(@as(usize, 4), doc.pages.len);
    for (doc.pages, old.pages) |page, prior| {
        try std.testing.expectEqualDeep(prior.occurrences, page.occurrences);
        var restored = page; restored.request = prior.request; restored.form_body = prior.form_body; restored.receipt = prior.receipt; restored.response = prior.response;
        try std.testing.expectEqualDeep(prior, restored);
        if (page.page_id != 108817 and page.page_id != 175438) try std.testing.expectEqualDeep(prior, page);
        const source = try responseSource(a, &ns, page);
        if (page.page_id != 108817) continue;
        try std.testing.expectEqual(@as(usize, 131913), page.form_body.len);
        try std.testing.expect(digestMatches(page.form_body, "f6aaa526d707439696c9d5a865a602f951f34c19e8f97a2701a5aa155bc73e3b"));
        try std.testing.expectEqual(@as(usize, 60551), source.source.len);
        try std.testing.expect(digestMatches(source.source, "137238f617ab7c056dff9a2fca60e50a5e5182732784cc35a2755cf0d78045df"));
        var stale = page; stale.request = prior.request;
        try std.testing.expectError(invalid, responseSource(a, &ns, stale));
        stale = page; stale.form_body = page.form_body[0 .. page.form_body.len - 1];
        try std.testing.expectError(invalid, responseSource(a, &ns, stale));
        stale = page; stale.response = prior.response; stale.receipt = prior.receipt;
        try std.testing.expectError(invalid, responseSource(a, &ns, stale));
    }
}


const ImidazoleFitTesting = if (@import("builtin").is_test) struct {
    const fixture = @embedFile("testdata/vi-imidazole-fit/figure-page-observations.json");
    const raw = @embedFile("testdata/vi-imidazole-fit/raw.wikitext");
    const source = @embedFile("testdata/vi-imidazole-fit/expanded.wikitext");
    fn document(a: A) !Document { return std.json.parseFromSliceLeaky(Document, a, fixture, .{ .allocate = .alloc_always }); }
    fn changedPage(a: A, page: RawPage) ![]const u8 {
        const shape = try json(a, fixture);
        const selected = &shape.object.getPtr("pages").?.array.items[0];
        try selected.object.put(a, "response", .{ .string = page.response });
        try selected.object.put(a, "receipt", .{ .string = page.receipt });
        return std.json.Stringify.valueAlloc(a, shape, .{});
    }
} else struct {};

test "retained imidazole Book grants only exact selected SVG upright fit and preserves ordinary refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = ImidazoleFitTesting;
    const doc = try F.document(a);
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    // Controlled file classification tests only this Book seam. The companion
    // full Writer test uses complete retained batches through the normal loader.
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    files.height_bound_records = &.{.svg_redundant_height};
    const defaults = Testing.hash(@embedFile("testdata/vi-acceleration18/figure-siteinfo.raw.json"));
    try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, null), try sizing.Registry.resolve(&files, a, "Imidazol.svg", .thumbnail, 190, null));
    var book = try Book.init(a, F.fixture, &ns, &files, defaults, 250); defer book.deinit();
    const context: compiler.Context = .{ .title = "imidazole", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 17966, 2480867, "imidazole", F.raw, F.source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1617), F.source.len);
    try std.testing.expectEqualStrings("[[Hình:Imidazol.svg|thumb|upright|imidazole]]", F.source[223..269]);
    try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
    const occurrence = selected.occurrences[0];
    try std.testing.expect(occurrence.svg_upright_fit);
    try std.testing.expectEqualDeep(SvgUprightFitEvidence{ .width = 190, .height = 282 }, occurrence.source.svg_upright_fit.?);
    try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, "Imidazol.svg", .thumbnail, occurrence.stage_options, 250));
    try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit), try SelectedPage.svgUprightFit(selected, a, "Imidazol.svg", .thumbnail, occurrence.stage_options, 190, null));
    for ([_]struct { file: []const u8 = "Imidazol.svg", format: encoder.presentation_types.FigureFormat = .thumbnail, text: []const u8 = "thumb|upright|imidazole", width: ?u32 = 190, height: ?u32 = null }{
        .{ .file = "Other.svg" }, .{ .format = .framed }, .{ .text = "thumb|upright|changed" },
        .{ .text = "thumb|upright=0.75|imidazole" }, .{ .text = "thumb|190px|imidazole" },
        .{ .width = 189 }, .{ .width = 191 }, .{ .width = null }, .{ .height = 282 },
    }) |case| try std.testing.expect((try SelectedPage.svgUprightFit(selected, a, case.file, case.format, case.text, case.width, case.height)) == null);
    try std.testing.expect((try SelectedPage.svgUprightFit(null, a, "Imidazol.svg", .thumbnail, occurrence.stage_options, 190, null)) == null);
    for ([_]struct { namespace_id: i32 = 0, page: u64 = 17966, revision: u64 = 2480867, title: []const u8 = "imidazole", raw: []const u8 = F.raw, source: []const u8 = F.source, width: u32 = 250 }{
        .{ .namespace_id = 1 }, .{ .page = 17967 }, .{ .revision = 2480868 }, .{ .title = "other" },
        .{ .raw = "changed" }, .{ .source = "changed" }, .{ .width = 251 },
    }) |case| try std.testing.expect((try book.select(a, &ns, case.namespace_id, case.page, case.revision, case.title, case.raw, case.source, defaults, case.width, context)) == null);
    var wrong_defaults = defaults; wrong_defaults[0] ^= 1;
    try std.testing.expect((try book.select(a, &ns, 0, 17966, 2480867, "imidazole", F.raw, F.source, wrong_defaults, 250, context)) == null);
    var no_options = context; no_options.image_options = null;
    try std.testing.expect((try book.select(a, &ns, 0, 17966, 2480867, "imidazole", F.raw, F.source, defaults, 250, no_options)) == null);
    files.height_bound_records = &.{.none};
    var unclassified = try Book.init(a, F.fixture, &ns, &files, defaults, 250); defer unclassified.deinit();
    const no_fit = (try unclassified.select(a, &ns, 0, 17966, 2480867, "imidazole", F.raw, F.source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try SelectedPage.svgUprightFit(no_fit, a, "Imidazol.svg", .thumbnail, occurrence.stage_options, 190, null)) == null);
    try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(no_fit, a, "Imidazol.svg", .thumbnail, occurrence.stage_options, 250));
}

test "SVG upright fit rejects changed geometry raster identity and unauthenticated file evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = ImidazoleFitTesting; const doc = try F.document(a);
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    var files = try Testing.registry(a, &ns, doc); defer files.deinit(); files.height_bound_records = &.{.svg_redundant_height};
    const defaults = Testing.hash(@embedFile("testdata/vi-acceleration18/figure-siteinfo.raw.json"));
    var baseline = try Book.init(a, F.fixture, &ns, &files, defaults, 250); defer baseline.deinit();
    try std.testing.expect(baseline.pages[0].occurrences[0].svg_upright_fit != null);
    for ([_][2][]const u8{
        .{ "width=\"190\"", "width=\"191\"" }, .{ "height=\"282\"", "height=\"283\"" },
        .{ "data-file-width=\"66\"", "data-file-width=\"67\"" },
        .{ "250px-Imidazol.svg.png", "250px-Imidazol.svg.webp" },
        .{ "250px-Imidazol.svg.png", "langvi-250px-Imidazol.svg.png" },
        .{ "250px-Imidazol.svg.png", "250px-Other.svg.png" },
        .{ "500px-Imidazol.svg.png", "langen-500px-Imidazol.svg.png" },
        .{ "mw-file-element mw-file-upright", "mw-file-element" },
        .{ "--mw-file-upright: 0.75", "color:red" },
        .{ "<figcaption>imidazole</figcaption>", "<figcaption><a href=\"/wiki/T%E1%BA%ADp_tin:Imidazol.svg\">duplicate</a></figcaption>" },
    }) |mutation| {
        errdefer std.debug.print("SVG upright retained HTML refusal={s}\n", .{mutation[1]});
        const changed = try ViPageServedTesting.changedResponse(a, doc.pages[0], "text", mutation[0], mutation[1]);
        var refused = Book.init(a, try F.changedPage(a, changed), &ns, &files, defaults, 250) catch |err| {
            try std.testing.expectEqual(invalid, err);
            continue;
        };
        defer refused.deinit();
        try std.testing.expect(refused.pages[0].occurrences[0].svg_upright_fit == null);
    }
    const changed_source = try ViPageServedTesting.changedResponse(a, doc.pages[0], "wikitext", "|thumb|upright|imidazole]]", "|thumb|upright|changed]]");
    try std.testing.expectError(invalid, Book.init(a, try F.changedPage(a, changed_source), &ns, &files, defaults, 250));
    const original_record = files.records[0];
    const changed_records = try a.dupe(sizing.Record, files.records); files.records = changed_records;
    for (0..4) |mode| {
        changed_records[0] = original_record;
        if (mode == 0) changed_records[0].file_sha1 = "0000000000000000000000000000000000000000";
        if (mode == 1) changed_records[0].file_timestamp = "2007-02-04T15:02:07Z";
        if (mode == 2) changed_records[0].original_width = 67;
        if (mode == 3) changed_records[0].original_height = 99;
        try std.testing.expectError(invalid, Book.init(a, F.fixture, &ns, &files, defaults, 250));
    }
    changed_records[0] = original_record; files.file_authority = false;
    try std.testing.expectError(invalid, Book.init(a, F.fixture, &ns, &files, defaults, 250));
}

test "SVG upright occurrence fit keeps exact option grammar and positive aspect bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/vi-dau100/namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile("testdata/vi-dau100/behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/vi-dau100/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    try std.testing.expect(bareUprightThumbnailOptions(&options, "thumb|upright|imidazole"));
    try std.testing.expect(bareUprightThumbnailOptions(&options, "thumb|upright|Caption [[Target|child]]"));
    for ([_][]const u8{ "thumb|upright=0.75|caption", "thumb|upright|", "thumb|upright|190px", "thumb|190px|caption", "thumb|upright|caption|extra", "thumb|lang=vi|caption", "frame|upright|caption", "thumb|right|upright|caption", "upright|thumb|caption" }) |text|
        try std.testing.expect(!bareUprightThumbnailOptions(&options, text));
    try std.testing.expect(svgUprightObservedFit(190, 282, 66, 98));
    for ([_][4]u32{ .{190, 283, 66, 98}, .{190, 0, 66, 98}, .{190, 282, 0, 98}, .{66, 98, 66, 98}, .{65, 97, 66, 98}, .{std.math.maxInt(u32), 1, 1, std.math.maxInt(u32)} }) |value|
        try std.testing.expect(!svgUprightObservedFit(value[0], value[1], value[2], value[3]));
}


test "current complete TH palette constructor binds all four pages and exact three authored note operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const prefix = "testdata/th-page-palette-current/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    var ns = try namespaces.Registry.init(a, @embedFile(ThPaletteTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(ThPaletteTesting.prefix ++ "figure-siteinfo.raw.json"));
    const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const prior = try std.json.parseFromSliceLeaky(Document, a, @embedFile(prefix ++ "prior-v4.json"), .{ .allocate = .alloc_always });
    try std.testing.expectEqual(@as(usize, 4), doc.pages.len);
    try std.testing.expectEqualDeep(prior.missing_link_styles, doc.missing_link_styles);
    for (prior.pages, doc.pages) |before, after| {
        var restored = after; restored.page_styles = null;
        try std.testing.expectEqualDeep(before, restored);
        try std.testing.expect((after.page_styles != null) == (after.page_id == 108817));
    }
    // As in the historical constructor control, these rows qualify intake only.
    // The ordinary Writer continues to require its independent normal Registry.
    var files = try ThPaletteTesting.registry(a, &ns, doc); defer files.deinit();
    var book = try Book.init(a, bytes, &ns, &files, defaults, 250); defer book.deinit();
    var parent = try profile.parseForTargetAlloc(a, @embedFile(ThPaletteTesting.prefix ++ "common.css"), .screen); defer parent.deinit();
    const raw = @embedFile(ThPaletteTesting.prefix ++ "page.raw.wikitext");
    const source = @embedFile(prefix ++ "page.expanded.wikitext");
    try std.testing.expectEqual(@as(usize, 60551), source.len);
    try std.testing.expect(digestMatches(source, "137238f617ab7c056dff9a2fca60e50a5e5182732784cc35a2755cf0d78045df"));
    var found = false;
    for (doc.pages) |candidate_page| if (candidate_page.page_id == 108817) {
        found = true;
        try std.testing.expectEqual(@as(usize, 131913), candidate_page.form_body.len);
        try std.testing.expectEqualStrings(source, (try responseSource(a, &ns, candidate_page)).source);
    };
    try std.testing.expect(found);
    const selected = (try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
    const starts = [_]usize{ 18077, 19048, 20243 };
    const ends = [_]usize{ 18393, 19330, 20486 };
    try std.testing.expectEqual(@as(usize, starts.len), selected.scope.source_custom_elements.len);
    try std.testing.expect(selected.scope.source_custom_elements_source.?.ptr == source.ptr);
    for (selected.scope.source_custom_elements, starts, ends) |proof, start, end| {
        try std.testing.expectEqual(start, proof.range.anchor_start);
        try std.testing.expectEqual(end, proof.range.anchor_end);
        try std.testing.expectEqual(@as(u32, 3), proof.candidate_count);
        const anchor = (try sourceCustomAnchor(a, source, start)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualDeep(anchor.range, proof.range);
    }
    const environment = selected.scope.page_custom_invariant orelse return error.TestUnexpectedResult;
    try ThPaletteTesting.known(environment, "--wikt-palette-forestgreen", "#235923");
    try ThPaletteTesting.known(environment, "--wikt-palette-lightyellow", "#ffffe0");
    // Actual source variables are selected independently of the unchanged Missing
    // image proof; neither substitutes for the other capability.
    for (book.pages) |candidate_page| if (candidate_page.page_id == 108817) {
        try std.testing.expectEqualStrings(source, candidate_page.source);
        try std.testing.expectEqual(@as(usize, 1), candidate_page.occurrences.len);
        const missing_value = candidate_page.occurrences[0].missing_content orelse return error.TestUnexpectedResult;
        try std.testing.expect(missing_value.paint_root_proven and missing_value.right and missing_value.data_width == 100);
    };
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw,
        @embedFile(ThPaletteTesting.prefix ++ "page.expanded.wikitext"), defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw, source[1..], defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 108817, 2190989, "間", raw, source, defaults, &parent)) == null);
    // Typed defaults insert legacy response/receipt keys into an observed set;
    // that mixed shape remains invalid independently of page-style selection.
    var typed_without = doc;
    const typed_pages = try a.dupe(RawPage, doc.pages);
    for (typed_pages) |*candidate_page| candidate_page.page_styles = null;
    typed_without.pages = typed_pages;
    const mixed_bytes = try std.json.Stringify.valueAlloc(a, typed_without, .{ .emit_null_optional_fields = false });
    const mixed_shape = try json(a, mixed_bytes);
    const mixed_styles = try field(mixed_shape, "missing_link_styles");
    try std.testing.expectEqual(@as(usize, 5), mixed_styles.object.count());
    try std.testing.expectEqualStrings("", try string(mixed_styles, "response"));
    try std.testing.expectEqualStrings("", try string(mixed_styles, "receipt"));
    try std.testing.expectError(invalid, Book.init(a, mixed_bytes, &ns, &files, defaults, 250));
    // Remove only the optional page capability from the original JSON shape.
    // The independent complete Missing served-set evidence stays unchanged.
    const without = try json(a, bytes);
    const original_missing = try std.json.Stringify.valueAlloc(a, try field(without, "missing_link_styles"), .{});
    var removed_styles: usize = 0;
    for (without.object.getPtr("pages").?.array.items) |*candidate_page| {
        if (candidate_page.object.swapRemove("page_styles")) removed_styles += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), removed_styles);
    try std.testing.expectEqualStrings(original_missing,
        try std.json.Stringify.valueAlloc(a, try field(without, "missing_link_styles"), .{}));
    var no_styles = try Book.init(a, try std.json.Stringify.valueAlloc(a, without, .{}), &ns, &files, defaults, 250); defer no_styles.deinit();
    try std.testing.expect((try no_styles.selectPageStyles(a, &ns, 0, 108817, 2190988, "間", raw, source, defaults, &parent)) == null);
    for (book.pages, no_styles.pages) |before, after| {
        try std.testing.expectEqual(before.page_id, after.page_id);
        try std.testing.expectEqualStrings(before.source, after.source);
        try std.testing.expectEqualDeep(before.occurrences, after.occurrences);
    }
    try std.testing.expect((try selected.styles.pageUnprovedInheritanceBlockerIn(a, selected.scope.page_style_root)) != null);
}


test "page style selection preserves independently issued root table relations only for its exact source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(PageStylesV7Testing.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try MaiCenteredTest.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(@embedFile(PageStylesV7Testing.prefix ++ "figure-siteinfo.raw.json"));
    var parent = try profile.parseForTargetAlloc(a, PageStylesV7Testing.css, .screen); defer parent.deinit();
    var doc = try PageStylesV7Testing.document(a, PageStylesV7Testing.reference);
    var changed = doc.pages[0];
    var response = try json(a, changed.response);
    const parsed = response.object.getPtr("parse").?;
    const original_source = try string(parsed.*, "wikitext");
    const original_html = try string(parsed.*, "text");
    // Controlled coherent source/HTML addition exercises the normal constructor;
    // it is not another captured Mai page or new evidence for that real page.
    const suffix = "\n{| style=\"font-size:95%\"\n| style=\"padding:0\"|<div style=\"font-style:normal\">Whole controlled quote.</div>\n|}\n";
    const table_html = "<table style=\"font-size:95%\"><tbody><tr><td style=\"padding:0\"><div style=\"font-style:normal\">Whole controlled quote.</div></td></tr></tbody></table>";
    const source = try std.mem.concat(a, u8, &.{original_source, suffix});
    const root_end = std.mem.lastIndexOf(u8, original_html, "</div>") orelse return error.TestUnexpectedResult;
    const html = try std.mem.concat(a, u8, &.{original_html[0..root_end], table_html, original_html[root_end..]});
    try parsed.object.put(a, "wikitext", .{ .string = source });
    try parsed.object.put(a, "text", .{ .string = html });
    changed.response = try std.json.Stringify.valueAlloc(a, response, .{});
    const text_at = std.mem.indexOf(u8, changed.form_body, "&text=") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfScalar(u8, changed.form_body[text_at + 6 ..], '&') == null);
    var form: std.ArrayList(u8) = .empty;
    try form.appendSlice(a, changed.form_body);
    for (suffix) |byte| {
        try form.append(a, '%');
        const hex = std.fmt.bytesToHex([1]u8{byte}, .upper);
        try form.appendSlice(a, &hex);
    }
    changed.form_body = form.items;
    var request = try json(a, changed.request);
    try request.object.put(a, "text_source", try FormIntakeTest.descriptorValue(a, source));
    changed.request = try std.json.Stringify.valueAlloc(a, request, .{});
    try FormIntakeTest.bindForm(a, &changed);
    doc.pages = &.{changed};
    var book = try Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250); defer book.deinit();
    try std.testing.expectEqual(@as(usize, 0), book.pages[0].occurrences.len);
    const issued = book.pages[0].source_root_tables;
    var matching: usize = 0;
    for (issued) |proof| if (proof.opening_start == original_source.len + 1) { matching += 1; };
    try std.testing.expectEqual(@as(usize, 1), matching);
    const selected = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(selected.scope.source_root_tables.ptr == issued.ptr and selected.scope.source_root_tables.len == issued.len);
    try std.testing.expect(selected.scope.source_root_tables_source.?.ptr == source.ptr and selected.scope.source_root_tables_source.?.len == source.len);
    try std.testing.expectEqualDeep(issued, selected.scope.source_root_tables);
    try std.testing.expect(selected.scope.page_styles == selected.styles and selected.styles.page_style_parent == &parent);
    // A byte-identical complete copy is selected afresh and bound to that caller
    // buffer; changed, partial or another page's source cannot reuse the binding.
    const copied = try a.dupe(u8, source);
    const rebound = (try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, copied, defaults, &parent)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rebound.scope.source_root_tables.ptr == issued.ptr);
    try std.testing.expect(rebound.scope.source_root_tables_source.?.ptr == copied.ptr and copied.ptr != source.ptr);
    for ([_][]const u8{original_source, source[1..], "foreign source"}) |foreign|
        try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, foreign, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 722, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) == null);
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", "foreign raw", source, defaults, &parent)) == null);
    // The same signature below a real DIV is not an observed parser-root table.
    const nested_html = try std.mem.concat(a, u8, &.{original_html[0..root_end], "<div>", table_html, "</div>", original_html[root_end..]});
    try parsed.object.put(a, "text", .{ .string = nested_html });
    changed.response = try std.json.Stringify.valueAlloc(a, response, .{});
    try FormIntakeTest.bindReceipt(a, &changed);
    doc.pages = &.{changed};
    var nested = try Book.init(a, try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }), &ns, &files, defaults, 250); defer nested.deinit();
    const denied = (try nested.selectPageStyles(a, &ns, 0, 721, 10777072, "Mai", PageStylesV7Testing.raw, source, defaults, &parent)) orelse return error.TestUnexpectedResult;
    for (denied.scope.source_root_tables) |proof| try std.testing.expect(proof.opening_start != original_source.len + 1);
}

const ImageMapError = struct { body: []const u8, body_start: usize, line: usize, text: []const u8 };
const SourceImageMap = struct { start: usize, end: usize, body: []const u8, file: []const u8 };
const ImageMapOutput = union(enum) { file: []const u8, error_text: []const u8 };

fn imageMapOrdinarySourceTag(tag: syntax.Tag) bool {
    for ([_][]const u8{ "div", "span", "bdi", "a", "figure", "figcaption", "img", "meta", "link", "style", "templatestyles",
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
        "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "font", "center" }) |name|
        if (tag.is(name)) return true;
    return false;
}
fn imageMapSourceLink(a: A, bytes: []const u8) !void {
    // Links cannot hide a second extension or forge its output marker. Retain
    // ordinary inline label spans; no generated/ignored source is accepted.
    if (std.mem.indexOf(u8, bytes, "{{") != null or std.mem.indexOf(u8, bytes, "}}") != null) return invalid;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, at, '<')) |open| {
        const tag = syntax.tagAt(bytes, open) orelse return invalid;
        var inline_tag = false;
        for ([_][]const u8{ "span", "bdi", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite", "u", "s", "code", "font" }) |name|
            if (tag.is(name)) { inline_tag = true; break; };
        if (!inline_tag) return invalid;
        _ = try inventory(a, tag);
        at = tag.end;
    }
}

fn sourceImageMaps(a: A, ns: *const namespaces.Registry, source: []const u8) ![]const SourceImageMap {
    var maps: std.ArrayList(SourceImageMap) = .empty;
    var stack: [128]syntax.Tag = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    while (at < source.len) {
        if (std.mem.startsWith(u8, source[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, source, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (std.mem.startsWith(u8, source[at..], "{{") or std.mem.startsWith(u8, source[at..], "}}")) return invalid;
        if (std.mem.startsWith(u8, source[at..], "[[")) {
            const pair = syntax.balanced(source, at) orelse return invalid;
            try imageMapSourceLink(a, source[at..pair.end]);
            at = pair.end; continue;
        }
        if (source[at] == '[' or std.mem.startsWith(u8, source[at..], "]]")) return invalid;
        if (source[at] != '<') { at += 1; continue; }
        const tag = syntax.tagAt(source, at) orelse return invalid;
        if (tag.is("imagemap")) {
            if (tag.closing or tag.self_closing or std.mem.trim(u8, tag.attrs, " \t\r\n").len != 0 or maps.items.len == max_occurrences) return invalid;
            const close = std.mem.indexOfPos(u8, source, tag.end, "</imagemap>") orelse return invalid;
            const body = source[tag.end..close];
            if (std.mem.indexOf(u8, body, "{{") != null or std.mem.indexOf(u8, body, "}}") != null or
                std.ascii.findIgnoreCase(body, "<imagemap") != null or std.ascii.findIgnoreCase(body, "<include") != null) return invalid;
            var lines = std.mem.splitScalar(u8, body, '\n');
            var file: ?[]const u8 = null;
            while (lines.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const pipe = std.mem.indexOfScalar(u8, line, '|') orelse return invalid;
                const title = std.mem.trim(u8, line[0..pipe], " \t\r");
                if (ns.ofTitle(title).id != 6) return invalid;
                file = try canonicalFile(a, ns, title);
                break;
            }
            const end = close + "</imagemap>".len;
            try maps.append(a, .{ .start = at, .end = end, .body = body, .file = file orelse return invalid });
            at = end; continue;
        }
        if (!imageMapOrdinarySourceTag(tag)) return invalid;
        const attributes = try inventory(a, tag);
        if (tag.closing) {
            if (attributes.attributes.len != 0 or depth == 0 or !std.ascii.eqlIgnoreCase(stack[depth - 1].name, tag.name)) return invalid;
            depth -= 1; at = tag.end; continue;
        }
        const classes = attributes.get("class") orelse "";
        if ((tag.is("p") and profile.Profile.hasClass(classes, "error")) or
            (tag.is("figure") and std.mem.indexOf(u8, classes, "mw-ext-imagemap-") != null)) return invalid;
        if (tag.is("style")) {
            const close = std.mem.indexOfPos(u8, source, tag.end, "</style>") orelse return invalid;
            at = close + "</style>".len; continue;
        }
        const is_void = tag.is("img") or tag.is("meta") or tag.is("link") or tag.is("col") or tag.is("br") or tag.is("hr") or tag.is("wbr") or tag.is("templatestyles");
        if ((tag.self_closing or (tag.end >= 2 and source[tag.end - 2] == '/')) and !is_void) return invalid;
        if (tag.is("templatestyles") and !tag.self_closing) return invalid;
        if (!is_void) {
            if (depth == stack.len) return invalid;
            stack[depth] = tag; depth += 1;
        }
        at = tag.end;
    }
    if (depth != 0) return invalid;
    return maps.toOwnedSlice(a);
}

// This independent observer grants only an extension error result. It neither
// issues class/ancestor certificates nor borrows any image geometry policy.
fn observedImageMapOutputs(a: A, ns: *const namespaces.Registry, html: []const u8) ![]const ImageMapOutput {
    const Figure = struct { depth: usize, file: ?[]const u8 = null, usemap: ?[]const u8 = null, map_name: ?[]const u8 = null, areas: usize = 0 };
    var stack: [128]syntax.Tag = undefined;
    var depth: usize = 0;
    var figure: ?Figure = null;
    var outputs: std.ArrayList(ImageMapOutput) = .empty;
    var at: usize = 0;
    var root_seen = false;
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return invalid;
            at = end + 3; continue;
        }
        if (html[at] != '<') {
            if (depth == 0 and !std.ascii.isWhitespace(html[at])) return invalid;
            at += 1; continue;
        }
        const tag = syntax.tagAt(html, at) orelse return invalid;
        const attributes = try inventory(a, tag);
        if (tag.closing) {
            if (attributes.attributes.len != 0 or depth == 0 or !std.ascii.eqlIgnoreCase(stack[depth - 1].name, tag.name)) return invalid;
            if (figure) |current| if (depth == current.depth) {
                if (!tag.is("figure") or current.file == null or current.usemap == null or current.map_name == null or current.areas == 0 or
                    !std.mem.startsWith(u8, current.usemap.?, "#") or !equal(current.usemap.?[1..], current.map_name.?)) return invalid;
                try outputs.append(a, .{ .file = current.file.? }); figure = null;
            };
            depth -= 1; at = tag.end; continue;
        }
        var ordinary = false;
        for ([_][]const u8{ "div", "span", "bdi", "a", "figure", "figcaption", "img", "map", "area", "meta", "link", "style",
            "h1", "h2", "h3", "h4", "h5", "h6", "p", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "cite",
            "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
            "col", "colgroup", "br", "hr", "wbr", "u", "s", "code", "font", "center" }) |name|
            if (tag.is(name)) { ordinary = true; break; };
        if (!ordinary) return invalid;
        const is_void = tag.is("area") or tag.is("img") or tag.is("meta") or tag.is("link") or tag.is("col") or tag.is("br") or tag.is("hr") or tag.is("wbr");
        if ((tag.self_closing or (tag.end >= 2 and html[tag.end - 2] == '/')) and !is_void) return invalid;
        if (depth == 0) {
            if (root_seen or !tag.is("div") or !profile.Profile.hasClass(attributes.get("class") orelse "", "mw-parser-output") or
                !equal(attributes.get("lang") orelse "", ns.content_language)) return invalid;
            root_seen = true;
        }
        if (tag.is("style")) {
            if (figure != null) return invalid;
            const close = std.mem.indexOfPos(u8, html, tag.end, "</style>") orelse return invalid;
            at = close + "</style>".len; continue;
        }
        const classes = attributes.get("class") orelse "";
        if (tag.is("p") and profile.Profile.hasClass(classes, "error")) {
            if (figure != null or attributes.attributes.len != 1 or !equal(classes, "error")) return invalid;
            const close = std.mem.indexOfScalarPos(u8, html, tag.end, '<') orelse return invalid;
            if (!std.mem.startsWith(u8, html[close..], "</p>")) return invalid;
            try outputs.append(a, .{ .error_text = try decodedAttribute(a, html[tag.end..close]) });
            at = close + "</p>".len; continue;
        }
        if (tag.is("figure") and std.mem.indexOf(u8, classes, "mw-ext-imagemap-desc-") != null) {
            if (figure != null or !profile.Profile.hasClass(classes, "noresize")) return invalid;
            var expected_class = false;
            for ([_][]const u8{ "mw-ext-imagemap-desc-top-right", "mw-ext-imagemap-desc-bottom-right", "mw-ext-imagemap-desc-bottom-left", "mw-ext-imagemap-desc-top-left", "mw-ext-imagemap-desc-none" }) |name|
                if (profile.Profile.hasClass(classes, name)) { if (expected_class) return invalid; expected_class = true; };
            if (!expected_class) return invalid;
            figure = .{ .depth = depth + 1 };
        } else if (tag.is("figure") and figure != null) return invalid;
        if (figure) |*current| {
            if (tag.is("img")) {
                if (current.file != null) return invalid;
                current.file = (try fileHref(a, ns, attributes.get("resource") orelse return invalid)) orelse return invalid;
                current.usemap = attributes.get("usemap") orelse return invalid;
                for ([_][]const u8{ "width", "height", "data-file-width", "data-file-height" }) |name| {
                    const dimension = std.fmt.parseInt(u32, attributes.get(name) orelse return invalid, 10) catch return invalid;
                    if (dimension == 0) return invalid;
                }
            }
            if (tag.is("map")) {
                if (current.map_name != null) return invalid;
                current.map_name = attributes.get("name") orelse return invalid;
            }
            if (tag.is("area")) {
                if (depth == 0 or !stack[depth - 1].is("map") or @as([]const u8, attributes.get("href") orelse "").len == 0) return invalid;
                current.areas += 1;
            }
        } else if (tag.is("map") or tag.is("area")) return invalid;
        if (!is_void) {
            if (depth == stack.len) return invalid;
            stack[depth] = tag; depth += 1;
        }
        at = tag.end;
    }
    if (!root_seen or depth != 0 or figure != null or outputs.items.len == 0 or outputs.items.len > max_occurrences) return invalid;
    return outputs.toOwnedSlice(a);
}

fn observedImageMapNoLink(a: A, ns: *const namespaces.Registry, registry: *const sizing.Registry, source: []const u8, html: []const u8, raw: RawImageMapNoLink) !ImageMapError {
    if (raw.start >= raw.end or raw.end > source.len) return invalid;
    const maps = try sourceImageMaps(a, ns, source);
    const outputs = try observedImageMapOutputs(a, ns, html);
    if (maps.len != outputs.len) return invalid;
    var selected: ?ImageMapError = null;
    for (maps, outputs) |map, output| {
        if (map.start == raw.start and map.end == raw.end) {
            if (selected != null or output != .error_text or std.mem.count(u8, source, map.body) != 1) return invalid;
            const branch = compiler.imageMapNoLinkSource(map.body) orelse return invalid;
            if (!equal(try canonicalFile(a, ns, branch.file), map.file)) return invalid;
            const message = (try registry.imageMapNoLinkText(a, branch.line)) orelse return invalid;
            if (!equal(message, output.error_text)) return invalid;
            selected = .{ .body = map.body, .body_start = @intFromPtr(map.body.ptr) - @intFromPtr(source.ptr), .line = branch.line, .text = message };
        } else if (output != .file or !equal(output.file, map.file)) return invalid;
    }
    return selected orelse return invalid;
}

const ImageMapErrorTesting = if (@import("builtin").is_test) struct {
    const prefix = "testdata/en-koukang-imagemap/";
    const fixture = @embedFile(prefix ++ "figure-page-observations.json");
    const source = @embedFile(prefix ++ "expanded.wikitext");
    const raw = @embedFile(prefix ++ "raw.wikitext");
    const default_bytes = @embedFile(prefix ++ "figure-siteinfo.raw.json");
    fn document(a: A) !Document { return std.json.parseFromSliceLeaky(Document, a, fixture, .{ .allocate = .alloc_always }); }
    fn registry(a: A, ns: *const namespaces.Registry) !sizing.Registry {
        var result: sizing.Registry = .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = ns,
            .records = &.{}, .file_authority = true, .image_map_no_link_policy = true };
        errdefer result.deinit();
        try result.bindImageMapMessages(a, @embedFile(prefix ++ "interface-messages.tsv"), @embedFile(prefix ++ "language-fallbacks.tsv"));
        return result;
    }
    fn bytes(a: A, doc: Document) ![]const u8 { return std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }); }
} else struct {};

test "observed ImageMap no link error binds full normal page source prior map and localized result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(ImageMapErrorTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try ImageMapErrorTesting.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(ImageMapErrorTesting.default_bytes);
    var book = try Book.init(a, ImageMapErrorTesting.fixture, &ns, &files, defaults, 250); defer book.deinit();
    try std.testing.expectEqual(@as(usize, 1), book.pages.len);
    try std.testing.expectEqualStrings(ImageMapErrorTesting.source, book.pages[0].source);
    try std.testing.expectEqual(@as(usize, 0), book.pages[0].occurrences.len);
    try std.testing.expect(book.pages[0].text_class_scope == null and book.pages[0].page_styles == null);
    const proof = book.pages[0].image_map_no_link orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), proof.line);
    try std.testing.expectEqualStrings("Error: No valid link was found at the end of line 3.", proof.text);
    const behavior_bytes = @embedFile(ImageMapErrorTesting.prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var images = try namespaces.image_options.Registry.init(a, @embedFile(ImageMapErrorTesting.prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer images.deinit();
    const context: compiler.Context = .{ .title = "kōukāng", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &images };
    const selected = (try book.select(a, &ns, 0, 10637514, 84991998, "kōukāng", ImageMapErrorTesting.raw, ImageMapErrorTesting.source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    const selected_body = selected.image_map_no_link.?.body;
    try std.testing.expect(selected_body.ptr == ImageMapErrorTesting.source[proof.body_start..].ptr);
    try std.testing.expectEqualStrings(proof.text, (try SelectedPage.imageMapNoLink(selected, a, selected_body, 3)).?);
    try std.testing.expect(try SelectedPage.imageMapNoLink(selected, a, proof.body, 3) == null);
    try std.testing.expect(try SelectedPage.imageMapNoLink(selected, a, try a.dupe(u8, selected_body), 3) == null);
    try std.testing.expect(try SelectedPage.imageMapNoLink(selected, a, selected_body[1..], 3) == null);
    try std.testing.expect(try SelectedPage.imageMapNoLink(selected, a, proof.body, 4) == null);
    const changed_body = try std.mem.replaceOwned(u8, a, proof.body, "150x75px", "151x75px");
    try std.testing.expect(try SelectedPage.imageMapNoLink(selected, a, changed_body, 3) == null);
    try std.testing.expect(try book.select(a, &ns, 0, 10637514, 84991999, "kōukāng", ImageMapErrorTesting.raw, ImageMapErrorTesting.source, defaults, 250, context) == null);
    try std.testing.expect(try book.select(a, &ns, 0, 10637514, 84991998, "kōukāng", ImageMapErrorTesting.raw, changed_body, defaults, 250, context) == null);
    try std.testing.expect(try book.select(a, &ns, 0, 10637514, 84991998, "kōukāng", "changed raw", ImageMapErrorTesting.source, defaults, 250, context) == null);
    try std.testing.expect(try SelectedPage.width(selected, a, "Map of the world by the US Gov as of 2016 no legend.svg", .thumbnail, "150x75px|", 250) == null);
}

test "observed ImageMap error refuses altered precedence output range message and legacy admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile(ImageMapErrorTesting.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    var files = try ImageMapErrorTesting.registry(a, &ns); defer files.deinit();
    const defaults = Testing.hash(ImageMapErrorTesting.default_bytes);
    const doc = try ImageMapErrorTesting.document(a);
    const page = doc.pages[0];
    const source_and_html = try responseSource(a, &ns, page);
    const observed = page.image_map_no_link.?;
    _ = try observedImageMapNoLink(a, &ns, &files, source_and_html.source, source_and_html.html, observed);
    const error_markup = "<p class=\"error\">Error: No valid link was found at the end of line 3.</p>";
    for ([_][2][]const u8{
        .{ "line 3.</p>", "line 4.</p>" },
        .{ error_markup, "<p class=\"error\">Earlier image header error.</p>" },
        .{ error_markup, error_markup ++ error_markup },
        .{ "<map name=", "<map data-name=" },
        .{ "resource=\"/wiki/File:Map_of_the_world_by_the_US_Gov_as_of_2016_no_legend.svg\"", "resource=\"/wiki/File:Different.svg\"" },
    }) |replacement| {
        var changed = doc;
        const pages = try a.dupe(RawPage, doc.pages);
        pages[0] = try ViPageServedTesting.changedResponse(a, page, "text", replacement[0], replacement[1]);
        changed.pages = pages;
        try std.testing.expectError(invalid, Book.init(a, try ImageMapErrorTesting.bytes(a, changed), &ns, &files, defaults, 250));
    }
    for ([_][]const u8{ "<includeonly>", "<ref>", "<nowiki>", "{{#tag:imagemap|hidden}}", "[[Target|" }) |prefix| {
        const altered = try std.mem.concat(a, u8, &.{ prefix, source_and_html.source });
        try std.testing.expectError(invalid, sourceImageMaps(a, &ns, altered));
    }
    const suppressed = "<includeonly><imagemap>File:Map.svg|20px\ndefault plain</imagemap></includeonly>{{#tag:imagemap|File:Map.svg|20px|default plain}}";
    try std.testing.expectError(invalid, sourceImageMaps(a, &ns, suppressed));
    var moved = observed; moved.start += 1;
    try std.testing.expectError(invalid, observedImageMapNoLink(a, &ns, &files, source_and_html.source, source_and_html.html, moved));
    const bad_header = try std.mem.replaceOwned(u8, a, source_and_html.source, "150x75px|", "150x75px|<ref>header</ref>");
    var bad_header_range = observed;
    bad_header_range.end += bad_header.len - source_and_html.source.len;
    try std.testing.expectError(invalid, observedImageMapNoLink(a, &ns, &files, bad_header, source_and_html.html, bad_header_range));
    for ([_][]const u8{ "wikidict.figure-page-observations.v1", "wikidict.figure-page-observations.v4", "wikidict.figure-page-observations.v7" }) |schema| {
        var changed = doc; changed.schema = schema;
        try std.testing.expectError(invalid, Book.init(a, try ImageMapErrorTesting.bytes(a, changed), &ns, &files, defaults, 250));
    }
    files.image_map_no_link_message = null;
    try std.testing.expectError(invalid, Book.init(a, ImageMapErrorTesting.fixture, &ns, &files, defaults, 250));
}


test "source class census accepts genuine adjacent quoted attributes without losing later classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    // Exact first-table opening in the retained current EL expansion455bd17d.
    const actual = "{| class=\"notheme\"style=\"clear:right; float:right; margin-left:0.5em; margin-bottom:0.5em;background:#ffffff; color:#000000; border:1px solid#a1bdea; text-align:right;\"rules=\"none\" border=\"1\" cellpadding=\"3\" cellspacing=\"0\"|-";
    const tag: syntax.Tag = .{ .name = "table", .attrs = actual[2..], .end = actual.len, .closing = false, .self_closing = false };
    try std.testing.expectEqualStrings("notheme", tag.attr("class").?);
    try std.testing.expectEqualStrings("clear:right; float:right; margin-left:0.5em; margin-bottom:0.5em;background:#ffffff; color:#000000; border:1px solid#a1bdea; text-align:right;", tag.attr("style").?);
    const scope: profile.BoundedTextClassScope = .{ .root_tag = "div", .root_classes = "mw-parser-output", .subtree_classes = "observed-descendant" };
    const complete = try completeObservedTextClassSuperset(a, scope, "skin-vector-2022", actual);
    for ([_][]const u8{ "mw-parser-output", "observed-descendant", "skin-vector-2022", "notheme" }) |name|
        try std.testing.expect(profile.Profile.hasClass(complete, name));
    for ([_][]const u8{ "class=\"first\"id='owner'class=\"second\"", "CLASS='first'data-k=\"v\"CLASS='second'", "class=\"first\"style=\"color:red\" class=\"second\"" }) |source| {
        var classes: std.ArrayList(u8) = .empty;
        try appendAuthoredSourceClasses(a, &classes, source);
        try std.testing.expect(profile.Profile.hasClass(classes.items, "first"));
        try std.testing.expect(profile.Profile.hasClass(classes.items, "second"));
    }
}

test "adjacent quoted class census retains malformed dynamic and boundary refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    for ([_][]const u8{
        "class=\"kept\"suffix", "class=\"kept\"style=plain", "class=\"kept\"=\"v\"",
        "class=\"kept\"style=\"unclosed", "class=\"kept\"style=\"v\"suffix",
        "class=\"kept\"style=\"{{dynamic}}\"", "class=\"kept\"style=\"<span>\"",
        "class=\"kept\"style=\"v\"class=\"{{dynamic}}\"", "class=\"kept\"style=\"v\"class=\"unterminated",
        "class=unquoted|cell", "class=\"unterminated", "class=\"{{dynamic}}\"",
        "class=\"kept\"style=\"v\"?", "class=\"kept\"style=\"v\"\x00",
    }) |source| {
        var classes: std.ArrayList(u8) = .empty;
        try std.testing.expectError(invalid, appendAuthoredSourceClasses(a, &classes, source));
    }
    var too_many: std.ArrayList(u8) = .empty;
    try too_many.appendSlice(a, "class=\"kept\"");
    for (0..65) |_| try too_many.appendSlice(a, "data-x=\"v\"");
    var classes: std.ArrayList(u8) = .empty;
    try std.testing.expectError(invalid, appendAuthoredSourceClasses(a, &classes, too_many.items));
}

const SrFuheMissingTesting = struct {
    const prefix = "testdata/figure-page-observations/sr-fuhe-served-set/";
    const bytes = @embedFile(prefix ++ "figure-page-observations.json");
    const raw = @embedFile(prefix ++ "page.raw.wikitext");
    const source = @embedFile(prefix ++ "page.expanded.wikitext");
    fn document(a: A) !Document { return std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always }); }
    // This controlled Missing row exercises Book intake, not the independent
    // full normal Registry. Unselected ordinary images receive no callback.
    fn registry(a: A, ns: *const namespaces.Registry) !sizing.Registry {
        var missing: std.StringHashMapUnmanaged(void) = .empty;
        try missing.put(a, "Датотека:符-bw.png", {});
        return .{ .arena = std.heap.ArenaAllocator.init(a), .namespace_catalog = ns, .records = &.{}, .missing_files = missing, .file_authority = true };
    }
};

test "explicit Missing thumbnail options admit unique supported permutations without changing default grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = SrFuheMissingTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile(F.prefix ++ "behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile(F.prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    const observed: ObservedMissing = .{ .label = "Датотека:符-bw.png", .href = "//commons.wikimedia.org/wiki/Special:UploadWizard?wpDestFile=x", .data_width = 200, .element = .{ .attributes = &.{} }, .default_size = false, .right = true };
    for ([_][]const u8{
        "200px|мини|десно|Caption", "200px|десно|мини|Caption", "мини|200px|десно|Caption",
        "мини|десно|200px|Caption", "десно|мини|200px|Caption", "десно|200px|мини|Caption",
    }) |input| try std.testing.expect(missingThumbnailOptionsForObservation(&options, input, observed));
    var no_right = observed; no_right.right = false;
    for ([_][]const u8{ "200px|мини|Caption", "мини|200px|Caption" }) |input|
        try std.testing.expect(missingThumbnailOptionsForObservation(&options, input, no_right));
    for ([_][]const u8{
        "200px|мини|мини|Caption", "200px|200px|мини|Caption", "десно|десно|200px|Caption",
        "200px|десно|Caption", "мини|десно|Caption", "200px|мини|Caption",
        "201px|мини|десно|Caption", "0px|мини|десно|Caption", "200x100px|мини|десно|Caption",
        "200px|мини|лево|Caption", "200px|мини|upright|Caption", "200px|мини|alt=Other|Caption",
        "200px|мини|десно|", "200px|мини|десно|200px", "200px|мини|десно|Caption|extra",
        "200px|мини|десно|мини|Caption", "200px|мини|десно|десно|Caption",
    }) |input| try std.testing.expect(!missingThumbnailOptionsForObservation(&options, input, observed));
    try std.testing.expect(!missingThumbnailOptionsForObservation(&options, "200px|мини|десно|Caption", no_right));
    var default_size = observed; default_size.default_size = true;
    try std.testing.expect(missingThumbnailOptionsForObservation(&options, "мини|десно|Caption", default_size));
    try std.testing.expect(!missingThumbnailOptionsForObservation(&options, "десно|мини|Caption", default_size));
    try std.testing.expect(!missingThumbnailOptionsForObservation(&options, "200px|мини|десно|Caption", default_size));
}

test "current complete SR Missing source binds its own served paint and preserves unselected ordinary images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = SrFuheMissingTesting; const doc = try F.document(a);
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    try std.testing.expectEqual(@as(usize, 1), doc.pages.len);
    const candidate = doc.pages[0];
    try std.testing.expectEqual(@as(u64, 31899), candidate.page_id);
    try std.testing.expectEqual(@as(u64, 147909), candidate.revision_id);
    try std.testing.expectEqual(@as(usize, 1), candidate.occurrences.len);
    const accepted = try responseSource(a, &ns, candidate);
    try std.testing.expectEqualStrings(F.source, accepted.source);
    try std.testing.expectEqual(@as(usize, 4337), accepted.source.len);
    try std.testing.expect(digestMatches(accepted.source, "c95da2e5482423b889add540c39c253f5e51c277e3ce5da3f50e90fe13eb1c89"));
    try std.testing.expect(digestMatches(accepted.html, "4bd2b9c9188c81c3a42e694249e467b71e3cc5c953dc3b44480f1472f429b822"));
    try std.testing.expectEqualStrings("[[Датотека:符-bw.png|200px|мини|десно|Редослед писања карактера 符.]]", accepted.source[218..329]);
    try std.testing.expect(std.mem.indexOf(u8, accepted.source, "[[Датотека:合-bw.png|200px|мини|десно|Редослед писања карактера 合.]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted.html, "data-file-width=\"863\" data-file-height=\"130\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, accepted.html, "<style "));
    const styles = doc.missing_link_styles.?;
    try missingStyleShape(try json(a, F.bytes), true);
    const served = try missingObservedSet(a, styles, ns.wiki, defaults);
    try std.testing.expectEqual(@as(usize, 4), served.responses.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, try missingHeadSources(a, &ns, candidate, served));
    const outer = try MissingServedTesting.context(a, &ns, candidate);
    try std.testing.expectEqual(@as(usize, 8), outer.ancestors.len);
    var css = (try missingServedProfile(a, &ns, candidate, served)) orelse return error.TestUnexpectedResult; defer css.deinit();
    const image = try MissingServedTesting.missing(a, &ns, candidate, outer, &css);
    const observed = image.missing_content orelse return error.TestUnexpectedResult;
    if (!observed.paint_root_proven) MissingServedTesting.diagnosePaint(a, &ns, candidate, outer, served);
    try std.testing.expect(observed.paint_root_proven and observed.right and !observed.default_size);
    try std.testing.expectEqual(@as(u32, 200), observed.data_width);
    try std.testing.expectEqual(@as(u32, 0), image.width);
    try std.testing.expectEqualStrings("Датотека:符-bw.png", observed.label);
    try std.testing.expectEqualStrings("//commons.wikimedia.org/wiki/Special:UploadWizard?uselang=sr&wpDestFile=%E7%AC%A6-bw.png", observed.href);
    try std.testing.expect(observed.element.get("src") == null and observed.element.get("width") == null and observed.element.get("height") == null);
    var files = try F.registry(a, &ns); defer files.deinit();
    var book = try Book.init(a, F.bytes, &ns, &files, defaults, 250); defer book.deinit();
    const behavior_bytes = @embedFile(F.prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile(F.prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    const context: compiler.Context = .{ .title = candidate.title, .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 31899, 147909, candidate.title, F.raw, F.source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), selected.occurrences.len);
    const occurrence = selected.occurrences[0];
    for ([_][]const u8{ occurrence.source.original_options, occurrence.stage_options }) |input| {
        try std.testing.expect(missingThumbnailOptionsForObservation(&options, input, observed));
        const proof = (try SelectedPage.missing(selected, a, "Датотека:符-bw.png", .thumbnail, input)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?encoder.presentation_types.MissingLinkPaint, .vector_new_link_v1), proof.link_paint);
        try std.testing.expectEqualStrings(observed.label, proof.label);
        try std.testing.expectEqualStrings(observed.href, proof.href);
        try std.testing.expectEqual(@as(u32, 200), proof.data_width);
    }
    try std.testing.expect((try SelectedPage.missing(selected, a, "Датотека:合-bw.png", .thumbnail, occurrence.stage_options)) == null);
    try std.testing.expect((try SelectedPage.width(selected, a, "Датотека:合-bw.png", .thumbnail, occurrence.stage_options, 250)) == null);
    var parent_profile = try profile.parseAlloc(a, ""); defer parent_profile.deinit();
    try std.testing.expect((try book.selectPageStyles(a, &ns, 0, 31899, 147909, candidate.title, F.raw, F.source, defaults, &parent_profile)) == null);
    for ([_]struct { raw: []const u8 = F.raw, source: []const u8 = F.source, revision: u64 = 147909 }{
        .{ .raw = "changed" }, .{ .source = F.source[1..] }, .{ .revision = 147910 },
    }) |changed| try std.testing.expect((try book.select(a, &ns, 0, 31899, changed.revision, candidate.title, changed.raw, changed.source, defaults, 250, context)) == null);
}

test "SR Missing observed set retains independent source outer stylesheet and occurrence refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = SrFuheMissingTesting; const doc = try F.document(a); const candidate = doc.pages[0];
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    const served = try missingObservedSet(a, doc.missing_link_styles.?, ns.wiki, defaults);
    _ = try MissingServedTesting.context(a, &ns, candidate);
    var css = (try missingServedProfile(a, &ns, candidate, served)) orelse return error.TestUnexpectedResult; defer css.deinit();
    const unproved = try MissingServedTesting.missing(a, &ns, candidate, null, &css);
    try std.testing.expect(!unproved.missing_content.?.paint_root_proven);
    var changed_page = candidate; changed_page.revision_id += 1;
    try std.testing.expectError(invalid, responseSource(a, &ns, changed_page));
    changed_page = candidate; changed_page.form_body = candidate.form_body[0 .. candidate.form_body.len - 1];
    try std.testing.expectError(invalid, responseSource(a, &ns, changed_page));
    const scope = try observedTextClassScope(a, &ns, (try responseSource(a, &ns, candidate)).html);
    var changed_outer = candidate.outer_context.?; changed_outer.response = changed_outer.response[0 .. changed_outer.response.len - 1];
    try std.testing.expectError(invalid, observedOuterContext(a, &ns, candidate, changed_outer, scope));
    var files = try F.registry(a, &ns); defer files.deinit();
    for (0..4) |mutation| {
        const shape = try json(a, F.bytes);
        const pages = shape.object.getPtr("pages").?;
        const current = &pages.array.items[0];
        if (mutation == 0) {
            const occurrences = current.object.getPtr("occurrences").?;
            try occurrences.array.items[0].object.put(a, "start", .{ .integer = 219 });
        } else if (mutation == 1) {
            try current.object.put(a, "text_class_scope", .{ .bool = false });
        } else if (mutation == 2) {
            const policy = shape.object.getPtr("missing_link_styles").?;
            const set = policy.object.getPtr("served_set").?;
            const responses = set.object.getPtr("responses").?;
            responses.array.items[0] = .{ .string = "changed" };
        } else {
            const policy = shape.object.getPtr("missing_link_styles").?;
            const set = policy.object.getPtr("served_set").?;
            const responses = set.object.getPtr("responses").?;
            responses.array.items = responses.array.items[0..3];
        }
        try std.testing.expectError(invalid, Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250));
    }
    var no_paint = try json(a, F.bytes);
    try std.testing.expect(no_paint.object.swapRemove("missing_link_styles"));
    var unstyled = try Book.init(a, try std.json.Stringify.valueAlloc(a, no_paint, .{}), &ns, &files, defaults, 250); defer unstyled.deinit();
    try std.testing.expect(unstyled.missing_link_paint == null and !unstyled.pages[0].occurrences[0].missing_content.?.paint_root_proven);
    // The real STYLE and both complete image bodies remain present without
    // granting the missing-link palette from source custody alone.
    try std.testing.expectEqualStrings(F.source, unstyled.pages[0].source);
}



const PosterSvgConjunctionTesting = if (@import("builtin").is_test) struct {
    const prefix = StaticPosterContextTesting.prefix;
    const actual = "testdata/it-book-conjunction/";
    fn pangea(a: A) !RawPage {
        return std.json.parseFromSliceLeaky(RawPage, a, @embedFile(actual ++ "Pangea.page.json"), .{ .allocate = .alloc_always });
    }
    fn document(a: A) !Document {
        var doc = try StaticPosterContextTesting.document(a);
        const pages = try a.alloc(RawPage, doc.pages.len + 1);
        @memcpy(pages[0..doc.pages.len], doc.pages); pages[doc.pages.len] = try pangea(a);
        doc.pages = pages; doc.schema = "wikidict.figure-page-observations.v9";
        return doc;
    }
    fn bytes(a: A, doc: Document) ![]const u8 {
        const encoded = try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false });
        if (doc.missing_link_styles) |styles| if (equal(styles.profile, missing_observed_set_profile)) {
            const shape = try json(a, encoded); const value = shape.object.getPtr("missing_link_styles").?;
            try std.testing.expect(value.object.swapRemove("response"));
            try std.testing.expect(value.object.swapRemove("receipt"));
            return std.json.Stringify.valueAlloc(a, shape, .{});
        };
        return encoded;
    }
    fn registry(a: A, ns: *const namespaces.Registry) !sizing.Registry {
        const projected = @embedFile(prefix ++ "figure-sizing.json");
        const captured = @embedFile(prefix ++ "figure-sizing.raw.json");
        var projection: CombinedObservationTesting.Slice = .{ .bytes = projected };
        var raw: CombinedObservationTesting.Slice = .{ .bytes = captured };
        var projection_input: sizing.StreamInput = .{ .context = &projection, .read_at = CombinedObservationTesting.Slice.readAt, .size = projected.len };
        var raw_input: sizing.StreamInput = .{ .context = &raw, .read_at = CombinedObservationTesting.Slice.readAt, .size = captured.len };
        var result = try sizing.Registry.initStream(a, &projection_input, &raw_input,
            @embedFile(prefix ++ "figure-sizing.site.json"), ns, "f45897451256aa3799aecc5d7ee320ade22beaec");
        errdefer result.deinit();
        try result.bindStaticPosterMessages(a, @embedFile(prefix ++ "interface-messages.tsv"), @embedFile(prefix ++ "language-fallbacks.tsv"));
        try std.testing.expectEqualDeep(Testing.hash(projected), projection_input.digest.?);
        try std.testing.expectEqualDeep(Testing.hash(captured), raw_input.digest.?);
        // Explicit validator-only SVG model row from the actual selected fact.
        // The normal complete Registry replay remains an independent obligation.
        const occurrence = (try pangea(a)).occurrences[0];
        result.records = try a.dupe(sizing.Record, &.{.{ .canonical_file = occurrence.canonical_file,
            .file_sha1 = occurrence.file_sha1, .file_timestamp = occurrence.file_timestamp,
            .original_width = occurrence.original_width, .original_height = occurrence.original_height,
            .format = .thumbnail, .width_px = occurrence.original_width, .height_px = null,
            .sizing = .requested_fit, .proof_kind = "controlled-validator-file-row" }});
        result.svg_language_file_models = &.{true};
        return result;
    }
    fn changedSource(a: A, page: RawPage, before: []const u8, after: []const u8) !RawPage {
        var changed = page; var response = try json(a, page.response); const parsed = response.object.getPtr("parse").?;
        const previous = try string(parsed.*, "wikitext");
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, previous, before));
        const source = try std.mem.replaceOwned(u8, a, previous, before, after);
        try parsed.object.put(a, "wikitext", .{ .string = source });
        changed.response = try std.json.Stringify.valueAlloc(a, response, .{});
        var request = try json(a, page.request); const parameters = try field(request, "parameters_except_text");
        var form: std.ArrayList(u8) = .empty; var iterator = parameters.object.iterator();
        while (iterator.next()) |entry| try TextClassTesting.formField(a, &form, entry.key_ptr.*, entry.value_ptr.string);
        try TextClassTesting.formField(a, &form, "text", source); changed.form_body = try form.toOwnedSlice(a);
        try request.object.put(a, "text_source", try FormIntakeTest.descriptorValue(a, source));
        changed.request = try std.json.Stringify.valueAlloc(a, request, .{}); try FormIntakeTest.bindForm(a, &changed);
        return changed;
    }
};

test "v9 genuine poster and Pangea pages retain independent proofs exact options and explicit SVG width selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = PosterSvgConjunctionTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    var files = try F.registry(a, &ns); defer files.deinit();
    const original = try StaticPosterContextTesting.document(a); const doc = try F.document(a);
    try std.testing.expectEqualDeep(original.pages, doc.pages[0..original.pages.len]);
    try std.testing.expectEqualDeep(original.static_poster_styles, doc.static_poster_styles);
    try std.testing.expectEqualDeep(try F.pangea(a), doc.pages[original.pages.len]);
    var old = try Book.init(a, try F.bytes(a, original), &ns, &files, defaults, 250); defer old.deinit();
    var book = try Book.init(a, try F.bytes(a, doc), &ns, &files, defaults, 250); defer book.deinit();
    for (old.pages) |before| {
        const after = try CombinedObservationTesting.parsedPage(&book, before.page_id);
        try std.testing.expectEqualStrings(before.source, after.source);
        try std.testing.expectEqualDeep(before.occurrences, after.occurrences);
    }
    const page = try CombinedObservationTesting.parsedPage(&book, 178433);
    try std.testing.expectEqualStrings(@embedFile(F.actual ++ "Pangea.expanded.wikitext"), page.source);
    try std.testing.expectEqual(@as(usize, 1), page.occurrences.len);
    const occurrence = page.occurrences[0];
    try std.testing.expectEqualStrings("File:Pangaea continents.svg", occurrence.canonical_file);
    try std.testing.expectEqualStrings("lang=it|thumb|250px|ricostruzione di '''Pangea'''<small></small>", occurrence.original_options);
    try std.testing.expect(occurrence.static_poster == null and occurrence.width == null and occurrence.anchor == null);
    const proof = occurrence.svg_language.?;
    try std.testing.expect(proof.authored); try std.testing.expectEqual(@as(?u32, 250), proof.authored_width);
    try std.testing.expectEqualStrings("it", proof.language);
    try std.testing.expectEqual(@as(u32, 250), proof.width); try std.testing.expectEqual(@as(u32, 294), proof.height);
    const behavior_source = @embedFile("testdata/it-per/behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_source, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/it-per/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_source)); defer options.deinit();
    const context: compiler.Context = .{ .title = "Pangea", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const raw = @embedFile(F.actual ++ "Pangea.raw.wikitext");
    const selected = (try book.select(a, &ns, 0, 178433, 3770735, "Pangea", raw, page.source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    for ([_][]const u8{selected.occurrences[0].source.original_options, selected.occurrences[0].stage_options}) |source_options| {
        try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit),
            try SelectedPage.svgLanguage(selected, a, occurrence.canonical_file, .thumbnail, source_options, "it", 250, null));
        try std.testing.expect((try SelectedPage.width(selected, a, occurrence.canonical_file, .thumbnail, source_options, 250)) == null);
        try std.testing.expect((try SelectedPage.svgLanguage(selected, a, occurrence.canonical_file, .thumbnail, source_options, "it", 251, null)) == null);
        try std.testing.expect((try SelectedPage.svgLanguage(selected, a, occurrence.canonical_file, .thumbnail, source_options, "en", 250, null)) == null);
        try std.testing.expect((try SelectedPage.observedSvgLanguage(selected, a, occurrence.canonical_file, .thumbnail, source_options, 250, null)) == null);
    }
    try std.testing.expect((try SelectedPage.svgLanguage(selected, a, occurrence.canonical_file, .thumbnail,
        "lang=it|thumb|250px|different caption", "it", 250, null)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 178433, 3770735, "Pangea", raw, page.source, defaults, 251, context)) == null);
}

test "v9 preserves old schemas requires both kinds and refuses crossed Pangea source class language width and model proofs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = PosterSvgConjunctionTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    var files = try F.registry(a, &ns); defer files.deinit(); const original = try F.document(a);
    for ([_][]const u8{ "wikidict.figure-page-observations.v5", "wikidict.figure-page-observations.v7", "wikidict.figure-page-observations.v8" }) |schema| {
        var changed = original; changed.schema = schema;
        try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, changed), &ns, &files, defaults, 250));
    }
    var no_svg = try StaticPosterContextTesting.document(a); no_svg.schema = "wikidict.figure-page-observations.v9";
    try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, no_svg), &ns, &files, defaults, 250));
    var no_poster = original; no_poster.pages = original.pages[original.pages.len - 1 ..];
    try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, no_poster), &ns, &files, defaults, 250));
    for (0..10) |mode| {
        var changed = original; const pages = try a.dupe(RawPage, original.pages); changed.pages = pages;
        const last = pages.len - 1; const occurrences = try a.dupe(RawOccurrence, pages[last].occurrences); pages[last].occurrences = occurrences;
        switch (mode) {
            0 => occurrences[0].width = false,
            1 => occurrences[0].svg_language = "en",
            2 => occurrences[0].resolved_svg_language = "it",
            3 => occurrences[0].height = true,
            4 => occurrences[0].file_sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            5 => {
                pages[last] = try ViPageServedTesting.changedResponse(a, pages[last], "text", "width=\"250\"", "width=\"251\"");
                pages[last] = try ViPageServedTesting.changedResponse(a, pages[last], "text", "height=\"294\"", "height=\"296\"");
            },
            6 => pages[last] = try ViPageServedTesting.changedResponse(a, pages[last], "text", "<figure typeof=\"mw:File/Thumb\">", "<figure class=\"mw-default-size\" typeof=\"mw:File/Thumb\">"),
            7 => pages[last] = try ViPageServedTesting.changedResponse(a, pages[last], "text", "langit-500px", "langen-500px"),
            8 => pages[last] = try F.changedSource(a, pages[last], "|250px|", "|251px|"),
            9 => changed.static_poster_styles = null,
            else => unreachable,
        }
        try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, changed), &ns, &files, defaults, 250));
    }
    files.svg_language_file_models = &.{false};
    try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, original), &ns, &files, defaults, 250));
}

test "explicit SVG width option proof keeps default path and rejects missing duplicate foreign dimension or caption associations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/it-static-poster/namespace-registry.tsv")); defer ns.deinit();
    const behavior = @embedFile("testdata/it-per/behavior-switches.tsv");
    var options = try namespaces.image_options.Registry.init(a, @embedFile("testdata/it-per/image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior)); defer options.deinit();
    try std.testing.expect(svgLanguageThumbnailOptionsForOrigin(&options, "lang=it|thumb|caption [[Kept|child]]", "it"));
    try std.testing.expect(!svgLanguageThumbnailOptionsForOrigin(&options, "lang=it|thumb|250px|caption", "it"));
    const source = "lang=it|thumb|250px|caption [[Kept|child]]";
    try std.testing.expectEqual(@as(?u32, 250), svgLanguageAuthoredWidth(source));
    try std.testing.expect(svgLanguageThumbnailOptionsWithWidth(&options, source, "it", 250));
    for ([_][]const u8{ "lang=it|thumb|caption", "lang=it|thumb|251px|caption", "lang=it|thumb|0px|caption",
        "lang=it|thumb|250px|250px|caption", "lang=it|frame|250px|caption", "lang=en|thumb|250px|caption",
        "lang=it|thumb|250px|lang=en|caption", "lang=it|thumb|250x300px|caption", "lang=it|thumb|250px|caption|tail" }) |bad|
        try std.testing.expect(!svgLanguageThumbnailOptionsWithWidth(&options, bad, "it", 250));
    try std.testing.expect(!svgLanguageThumbnailOptionsWithWidth(&options, "thumb|250px|caption", null, 250));
    for ([_][]const u8{ "lang=it|thumb|0px|caption", "lang=it|thumb|4294967296px|caption", "lang=it|thumb|250px|250px|caption" }) |bad|
        try std.testing.expect(svgLanguageAuthoredWidth(bad) == null);
}


test "v9 independently validates existing served Missing page styles and withholds v8 operation privileges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = PosterSvgConjunctionTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    var files = try F.registry(a, &ns); defer files.deinit();
    var doc = try F.document(a);
    const poster_styles = doc.static_poster_styles.?;
    const served: MissingServedSet = .{ .responses = &poster_styles.responses, .receipt = poster_styles.receipt };
    doc.missing_link_styles = .{ .profile = missing_observed_set_profile, .defaults = poster_styles.defaults, .served_set = served };
    const pages = try a.dupe(RawPage, doc.pages); doc.pages = pages; pages[0].page_styles = served;
    const encoded = try F.bytes(a, doc);
    var book = try Book.init(a, encoded, &ns, &files, defaults, 250); defer book.deinit();
    try std.testing.expectEqual(@as(?encoder.presentation_types.MissingLinkPaint, .vector_new_link_v1), book.missing_link_paint);
    const page = try CombinedObservationTesting.parsedPage(&book, pages[0].page_id);
    try std.testing.expect(page.page_styles != null);
    try std.testing.expect(page.occurrences[0].static_poster != null);
    const svg_page = try CombinedObservationTesting.parsedPage(&book, 178433);
    try std.testing.expect(svg_page.occurrences[0].svg_language != null);
    for ([_][]const u8{ "image_map_no_link", "figure_style_operations", "authored_style_operations", "figure_style_assets" }) |key| {
        const shape = try json(a, encoded);
        const candidate = &shape.object.getPtr("pages").?.array.items[0];
        const value = if (equal(key, "image_map_no_link"))
            try json(a, "{\"start\":0,\"end\":1}")
        else if (equal(key, "figure_style_assets"))
            try json(a, "{\"responses\":[],\"receipt\":\"{}\"}")
        else try json(a, "[]");
        try candidate.object.put(a, key, value);
        // The known image-map field reaches semantic refusal; the three
        // unavailable operation fields are refused by the strict JSON shape.
        const expected_error = if (equal(key, "image_map_no_link")) invalid else error.UnknownField;
        try std.testing.expectError(expected_error, Book.init(a, try std.json.Stringify.valueAlloc(a, shape, .{}), &ns, &files, defaults, 250));
    }
    var changed = doc; var styles = doc.missing_link_styles.?; var wrong = served; wrong.receipt = "{}";
    styles.served_set = wrong; changed.missing_link_styles = styles;
    try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, changed), &ns, &files, defaults, 250));
    changed = doc; const altered_pages = try a.dupe(RawPage, doc.pages); changed.pages = altered_pages;
    altered_pages[0].page_styles = wrong;
    try std.testing.expectError(invalid, Book.init(a, try F.bytes(a, changed), &ns, &files, defaults, 250));
}

const RightDefaultCapturedTesting = if (@import("builtin").is_test) struct {
    const prefix = "testdata/it-cediglia-right-default/";
    fn page(a: A) !RawPage {
        return std.json.parseFromSliceLeaky(RawPage, a, @embedFile(prefix ++ "page.json"), .{ .allocate = .alloc_always });
    }
    fn document(a: A, raw_page: RawPage) !Document {
        // One unchanged captured page projected into the existing v4 width
        // contract; complete actual v9/normal Registry intake is separate.
        return .{ .schema = "wikidict.figure-page-observations.v4", .wiki = "itwiktionary", .date = "20261001",
            .namespace_sha256 = "8fc73407a5f932ba725c3339034fc0aa9894078272b08a5ae62566a834496996",
            .defaults_sha256 = "58177d7029c25bdbb248f6b457c5872f304f2a4012cf054f68c35786f14e77db", .pages = try a.dupe(RawPage, &.{raw_page}) };
    }
};

test "captured cediglia right default upright stages exact raster and requires original and prepared source options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    const F = RightDefaultCapturedTesting;
    var ns = try namespaces.Registry.init(a, @embedFile(F.prefix ++ "namespace-registry.tsv")); defer ns.deinit();
    const behavior_bytes = @embedFile(F.prefix ++ "behavior-switches.tsv");
    var behavior = try namespaces.behavior_switches.Registry.init(a, behavior_bytes, ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256); defer behavior.deinit();
    var options = try namespaces.image_options.Registry.init(a, @embedFile(F.prefix ++ "image-options.tsv"), ns.wiki, ns.dump_date, ns.content_language, ns.source_sha256, Testing.hash(behavior_bytes)); defer options.deinit();
    const page = try F.page(a); const doc = try F.document(a, page);
    // Controlled validator rows isolate source/markup boundaries. They do not
    // replace the independent full selected normal Registry integration check.
    var files = try Testing.registry(a, &ns, doc); defer files.deinit();
    files.height_bound_records = &.{.svg_redundant_height};
    const defaults = Testing.hash(@embedFile(F.prefix ++ "figure-siteinfo.raw.json"));
    var book = try Book.init(a, try PosterSvgConjunctionTesting.bytes(a, doc), &ns, &files, defaults, 250); defer book.deinit();
    const source = @embedFile(F.prefix ++ "expanded.wikitext"); const raw = @embedFile(F.prefix ++ "raw.wikitext");
    try std.testing.expectEqualStrings(source, book.pages[0].source);
    const occurrence = book.pages[0].occurrences[0];
    try std.testing.expect(occurrence.right_default_size and !occurrence.centered_default_size and occurrence.centered_width == null);
    try std.testing.expectEqual(@as(?u32, 190), occurrence.width);
    try std.testing.expect(occurrence.svg_upright_fit != null);
    try std.testing.expectEqualStrings("upright|right|thumb|La cediglia", occurrence.original_options);
    const context: compiler.Context = .{ .title = "cediglia", .namespace_catalog = &ns, .behavior_switches = &behavior, .image_options = &options };
    const selected = (try book.select(a, &ns, 0, 143745, 3991833, "cediglia", raw, source, defaults, 250, context)) orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ occurrence.original_options, selected.occurrences[0].stage_options }) |source_options| {
        try std.testing.expect(rightUprightDefaultOptions(&options, source_options));
        try std.testing.expectEqual(@as(?u32, 190), try SelectedPage.width(selected, a, occurrence.canonical_file, .thumbnail, source_options, 250));
        try std.testing.expectEqual(@as(?encoder.presentation_types.FigureSizingPolicy, .requested_fit),
            try SelectedPage.svgUprightFit(selected, a, occurrence.canonical_file, .thumbnail, source_options, 190, null));
        try std.testing.expect((try SelectedPage.svgUprightFit(selected, a, occurrence.canonical_file, .thumbnail, source_options, 191, null)) == null);
    }
    for ([_][]const u8{ "upright|left|thumb|Caption", "upright|thumb|Caption", "upright=1|right|thumb|Caption",
        "190px|right|thumb|Caption", "upright|right|right|Caption", "upright|right|thumb|left",
        "upright|right|thumb|Caption|left", "upright|right|unknown|Caption" }) |false_source|
        try std.testing.expect(!rightUprightDefaultOptions(&options, false_source));
    var changed = try PosterSvgConjunctionTesting.changedSource(a, page, "|right|", "|left |" );
    const changed_doc = try F.document(a, changed);
    var false_book = try Book.init(a, try PosterSvgConjunctionTesting.bytes(a, changed_doc), &ns, &files, defaults, 250); defer false_book.deinit();
    const false_source = (try responseSource(a, &ns, changed)).source;
    try std.testing.expect((try false_book.select(a, &ns, 0, 143745, 3991833, "cediglia", raw, false_source, defaults, 250, context)) == null);
    // The staged HTML flag alone grants no width for a foreign source/options.
    try std.testing.expect((try SelectedPage.width(selected, a, occurrence.canonical_file, .thumbnail, "upright|left|thumb|La cediglia", 250)) == null);
    try std.testing.expect((try book.select(a, &ns, 0, 143745, 3991834, "cediglia", raw, source, defaults, 250, context)) == null);
    changed = page; const wrong_occurrences = try a.dupe(RawOccurrence, page.occurrences); wrong_occurrences[0].start += 1; changed.occurrences = wrong_occurrences;
    try std.testing.expectError(invalid, Book.init(a, try PosterSvgConjunctionTesting.bytes(a, try F.document(a, changed)), &ns, &files, defaults, 250));
    wrong_occurrences[0] = page.occurrences[0]; wrong_occurrences[0].canonical_file = "File:Other.svg";
    try std.testing.expectError(invalid, Book.init(a, try PosterSvgConjunctionTesting.bytes(a, try F.document(a, changed)), &ns, &files, defaults, 250));
    for ([_][]const u8{ "mw-default-size mw-halign-right unknown", "mw-halign-right", "mw-default-size mw-halign-left" }) |classes| {
        changed = try ViPageServedTesting.changedResponse(a, page, "text", "mw-default-size mw-halign-right", classes);
        try std.testing.expectError(invalid, Book.init(a, try PosterSvgConjunctionTesting.bytes(a, try F.document(a, changed)), &ns, &files, defaults, 250));
    }
    changed = try ViPageServedTesting.changedResponse(a, page, "text", "mw-file-element mw-file-upright", "mw-file-element");
    try std.testing.expectError(invalid, Book.init(a, try PosterSvgConjunctionTesting.bytes(a, try F.document(a, changed)), &ns, &files, defaults, 250));
}
