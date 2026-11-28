//! Build-only, edition-local capture inputs. This checks the identity and
//! custody of an explicit observation; it does not infer an initializer or CSS
//! policy from a title, class, missing field, or equal text on another page.
const std = @import("std");
const encoder = @import("encoder");
const namespace_registry = @import("namespace_registry");
const T = encoder.presentation_types;
const PC = encoder.presentation_compile;
pub const image_catalog = @import("container_image_catalog.zig");
pub const timed_media_inputs = @import("container_timed_media_inputs.zig");
pub const MediaSources = image_catalog.Sources;

pub const filename = "container-disclosure-captures.json";
pub const max_input = 1024 * 1024;
// File-demand discovery only. Book still authenticates the full manifest.
pub fn requiresInterwikiMap(a: std.mem.Allocator, bytes: []const u8) !bool {
    if (bytes.len == 0 or bytes.len > max_input) return error.InvalidContainerDisclosureInput;
    const input = try std.json.parseFromSlice(Input, a, bytes, .{});
    defer input.deinit();
    const shared = input.value.shared orelse return false;
    const text = shared.ordinary_manifest orelse return false;
    const manifest = try std.json.parseFromSlice(OrdinaryManifest, a, text, .{});
    defer manifest.deinit();
    const worker = manifest.value.worker_projection orelse return false;
    const ref = worker.image_catalog orelse return false;
    try image_catalog.validReference(ref);
    return std.mem.eql(u8, ref.grammar, image_catalog.interwiki_caption_grammar);
}

pub const Reference = struct {
    scope: []const u8,
    full_page_cascade_qualified: bool,
    historical_deployment_qualified: bool,
    observed_html_sha256: []const u8,
    actual_reference_sha256: []const u8,
    capture_binding_sha256: []const u8,
};
pub const Capture = struct {
    source_labels: ?PC.ContainerDisclosureSourceLabels = null,
    owner_start: usize,
    owner_end: usize,
    content_start: usize,
    content_end: usize,
    owner_sha256: []const u8,
    reference: Reference,
    policy: T.ContainerDisclosure,
};
pub const Page = struct {
    namespace_id: i32,
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    raw_sha256: []const u8,
    expanded_sha256: []const u8,
    captures: []const Capture,
};
// Shared screen-policy inputs are a separate version from finite page rows.
// The source issuer verifies the retained normal-capture and initializer
// closure before producing this input. Native loading rechecks all supplied
// byte bodies, edition binding and the bounded stylesheet parser inputs.
pub const SharedStyleInput = struct {
    byte_start: usize = 0,
    unknown_applicability: bool = false,
    url: []const u8,
    sha256: []const u8,
    body: []const u8,
};
pub const SharedReference = struct {
    ordinary_manifest_sha256: ?[]const u8 = null,
    scope: []const u8,
    historical_deployment_qualified: bool,
    initializer_sha256: []const u8,
    source_closure_sha256: []const u8,
    validation_sha256: []const u8,
    ua_basis_sha256: []const u8,
    parser_constructor_sha256: ?[]const u8 = null,
};
pub const SharedInput = struct {
    ordinary_manifest: ?[]const u8 = null,
    protocol: []const u8,
    reference: SharedReference,
    styles: []const SharedStyleInput,
    ua: encoder.table_style_profile.DisclosureUaBasis,
    boundary: encoder.table_style_profile.DisclosureBoundary,
    placement_shell: ?[]const encoder.table_style_profile.DisclosureShellStep = null,
    parser_output_direction: ?T.BidiResolvedDirection = null,
};

fn sharedProfile(a: std.mem.Allocator, backing: std.mem.Allocator, input: SharedInput) !*encoder.table_style_profile.DisclosureSharedProfile {
    if (!std.mem.eql(u8, input.protocol, "mediawiki-native-div-disclosure.v1") or
        !std.mem.eql(u8, input.reference.scope, "current_normal_shared_initializer_css") or
        input.reference.historical_deployment_qualified or input.styles.len == 0 or input.styles.len > 32 or
        input.boundary.absent_tags.len != 0 or input.boundary.absent_classes.len != 0)
        return error.InvalidContainerDisclosureInput;
    // Per-query ancestry absence is never borrowed from a validation page.
    // The local source issuer may add its own verified absence facts later.
    _ = try digest(input.reference.initializer_sha256);
    _ = try digest(input.reference.source_closure_sha256);
    _ = try digest(input.reference.validation_sha256);
    _ = try digest(input.reference.ua_basis_sha256);
    if (input.placement_shell) |shell| {
        if (shell.len < 2 or shell.len > 32 or !std.ascii.eqlIgnoreCase(shell[0].tag, "html") or
            !std.ascii.eqlIgnoreCase(shell[1].tag, "body")) return error.InvalidContainerDisclosureInput;
        _ = try digest(input.reference.parser_constructor_sha256 orelse return error.InvalidContainerDisclosureInput);
    } else if (input.parser_output_direction != null or input.reference.parser_constructor_sha256 != null)
        return error.InvalidContainerDisclosureInput;
    if (!T.validContainerDisclosureButton(input.ua.button) or
        (input.ua.foreground.kind != .rgb and input.ua.foreground.kind != .transparent))
        return error.InvalidContainerDisclosureInput;
    const sources = try a.alloc(S.Source, input.styles.len);
    var total: usize = 0;
    for (input.styles, sources) |source, *out| {
        if (source.url.len == 0 or source.url.len > 4096 or !std.unicode.utf8ValidateSlice(source.url) or
            !try matches(source.body, source.sha256)) return error.InvalidContainerDisclosureInput;
        total = std.math.add(usize, total, source.body.len) catch return error.InvalidContainerDisclosureInput;
        if (total > 768 * 1024) return error.InvalidContainerDisclosureInput;
        if ((source.byte_start != 0 or source.unknown_applicability) and input.ordinary_manifest == null)
            return error.InvalidContainerDisclosureInput;
        if (source.byte_start > 768 * 1024 - source.body.len) return error.InvalidContainerDisclosureInput;
        out.* = .{ .css = source.body, .base_url = source.url, .byte_start = source.byte_start,
            .unknown_applicability = source.unknown_applicability };
    }
    const styles = try a.create(S.Profile);
    // The Book arena is returned by value. Retaining its local allocator
    // context in this child arena would point into Book.init's expired frame.
    styles.* = try S.parseSourcesForTargetAlloc(backing, sources, .screen);
    errdefer styles.deinit();
    const held = try a.create(S.DisclosureSharedProfile);
    held.* = .{ .styles = styles, .ua = input.ua, .boundary = input.boundary, .placement_shell = input.placement_shell };
    return held;
}


pub const Input = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    pages: []const Page = &.{},
    shared: ?SharedInput = null,
};

fn digest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidContainerDisclosureInput;
    var value: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&value, text) catch return error.InvalidContainerDisclosureInput;
    if (!std.mem.eql(u8, text, &std.fmt.bytesToHex(value, .lower)) or
        std.mem.allEqual(u8, &value, 0)) return error.InvalidContainerDisclosureInput;
    return value;
}

fn matches(bytes: []const u8, expected: []const u8) !bool {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.mem.eql(u8, &actual, &(try digest(expected)));
}

const S = encoder.table_style_profile;

// Issued by the normal source producer for this edition and target. The
// constructor receipt covers hooks, module dependencies, options, target UA,
// base URLs and the skin path for every admitted title and argument value.
// Required calls select the variant. The other named calls must preserve it.
// The byte inventory also checks the expansion for local CSS contributors.
pub const OrdinaryCall = struct { name: []const u8, required: bool };
pub const OrdinarySheet = struct {
    url: []const u8,
    sha256: []const u8,
    local_key: ?[]const u8 = null,
    byte_start: usize = 0,
    unknown_applicability: bool = false,
};
// Optional on the v4 manifest. The authenticated producer qualifies this
// bounded source projection over the entire admitted constructor family.
const WorkerProjection = struct {
    timed_media: ?timed_media_inputs.Reference = null,
    image_catalog: ?image_catalog.Reference = null,
    schema: []const u8,
    catalog_sha256: []const u8,
    feature_source_sha256: []const u8,
    placement_source_sha256: ?[]const u8 = null,
    local_placement: ?[]const u8 = null,
    toc_on: []const OrdinarySheet,
    toc_off: ?[]const OrdinarySheet = null,
    without_tmh: ?struct {
        toc_on: []const OrdinarySheet,
        toc_off: ?[]const OrdinarySheet = null,
    } = null,
    // Exact wiki file operation, including spelling and options, for which
    // the normal provider has proved the generated module/skin effects.
    media_operations: []const struct {
        operand: []const u8,
        evidence_sha256: []const u8,
        media: enum { image, successful_audio_video, unsupported },
        thumbnail: bool,
    } = &.{},
};

const OrdinaryOwnerAttributes = struct {
    schema: []const u8,
    source_sha256: []const u8,
    parser_constructor_sha256: []const u8,
    initializer_sha256: []const u8,
    projection: S.DisclosureOwnerAttributeProjection,
};
const OrdinaryManifest = struct {
    owner_attributes: ?OrdinaryOwnerAttributes = null,
    worker_projection: ?WorkerProjection = null,
    inline_hit: ?struct {
        parser_constructor_sha256: []const u8,
        ua_basis_sha256: []const u8,
        validation_sha256: []const u8,
        source: S.DisclosureInlineHit,
    } = null,
    local_registry: ?OrdinaryLocalRegistry = null,
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    parser_constructor_sha256: []const u8,
    initializer_sha256: []const u8,
    ua_basis_sha256: []const u8,
    module_selection_sha256: []const u8,
    root_font_and_faces_sha256: []const u8,
    sheets: []const OrdinarySheet,
    calls: []const OrdinaryCall,
    font: S.DisclosureRootFontInput,
    shell: S.DisclosureFontShell,
    underline: ?S.DisclosureHtmlUnderline = null,
};

fn classToken(classes: []const u8, name: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0c");
    while (iter.next()) |token| if (std.mem.eql(u8, token, name)) return true;
    return false;
}

fn validOrdinaryCall(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.mem.eql(u8, name, std.mem.trim(u8, name, " "))) return false;
    // Literal template subpages are static names, not relative transclusion.
    // Keep each segment nonempty and canonical; colons, braces, parser
    // functions and leading/trailing/adjacent slashes remain unsupported.
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or !std.mem.eql(u8, segment, std.mem.trim(u8, segment, " "))) return false;
        for (segment) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != ' ' and c != '_') return false;
    }
    return true;
}

fn ordinaryTagAttributes(attrs: []const u8, family_tag: ?encoder.wikitext_syntax.Tag) bool {
    var i: usize = 0;
    while (i < attrs.len) {
        if (!std.ascii.isWhitespace(attrs[i])) return false;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i == attrs.len) break;
        const start = i;
        while (i < attrs.len and (std.ascii.isAlphabetic(attrs[i]) or attrs[i] == '-')) i += 1;
        const name = attrs[start..i];
        var known = false;
        for ([_][]const u8{ "style", "class", "id", "title", "data-expandtext", "data-collapsetext" }) |k| {
            if (std.ascii.eqlIgnoreCase(k, attrs[start..i])) { known = true; break; }
        }
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i == attrs.len or attrs[i] != '=') return false;
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i == attrs.len or (attrs[i] != '"' and attrs[i] != 39)) return false;
        const end = std.mem.indexOfScalarPos(u8, attrs, i + 1, attrs[i]) orelse return false;
        const value = attrs[i + 1 .. end];
        if (std.mem.indexOfAny(u8, value, "<>{}") != null) return false;
        if (family_tag) |tag| {
            if (!known and !ordinaryPresentationAttribute(tag, name, value)) return false;
            if ((std.ascii.eqlIgnoreCase(name, "data-expandtext") or std.ascii.eqlIgnoreCase(name, "data-collapsetext")) and !tag.is("div")) return false;
            // Only literal inline declarations in this domain. Resource or
            // escaped syntax belongs to a separately qualified module scope.
            if (std.ascii.eqlIgnoreCase(name, "style") and std.mem.indexOfAny(u8, value, "@\\&()/") != null) return false;
        } else if (!known) return false;
        i = end + 1;
    }
    return true;
}

// This selects only the no-local-stylesheet variant. File links and the
// admitted templates can still activate modules. Their effects belong in
// the independently qualified module inventory. Inline declarations on the
// owner remain live inputs to the selector engine.
fn ordinaryBoundedSource(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8) bool {
    if (calls.len > 256 or raw.len == 0 or expanded.len == 0 or
        raw.len > 1024 * 1024 or expanded.len > 1024 * 1024) return false;
    for ([_][]const u8{ raw, expanded }) |source| {
        if (!std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null or
            std.mem.indexOf(u8, source, "__") != null) return false;
    }
    return true;
}

pub fn ordinarySourceSelected(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8) bool {
    if (!ordinaryBoundedSource(calls, raw, expanded)) return false;
    if (std.mem.indexOfAny(u8, raw, "<>") != null or std.mem.indexOf(u8, expanded, "{{") != null or
        std.mem.indexOf(u8, expanded, "}}") != null) return false;
    var seen: [256]bool = @splat(false);
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, raw, pos, "{}")) |start| {
        if (!std.mem.startsWith(u8, raw[start..], "{{")) return false;
        const pair = encoder.wikitext_syntax.balanced(raw, start) orelse return false;
        const body = raw[start + 2 .. pair.inner_end];
        if (std.mem.indexOfAny(u8, body, "{}") != null) return false;
        const name = std.mem.trim(u8, body[0 .. std.mem.indexOfScalar(u8, body, '|') orelse body.len], " \t\r\n");
        for (calls, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) { seen[i] = true; break; }
        } else return false;
        pos = pair.end;
    }
    for (calls, seen[0..calls.len]) |c, found| if (c.required and !found) return false;
    pos = 0;
    while (std.mem.indexOfScalarPos(u8, expanded, pos, '<')) |start| {
        const tag = encoder.wikitext_syntax.tagAt(expanded, start) orelse return false;
        if (!(tag.is("div") or tag.is("span") or tag.is("small")) or tag.self_closing or expanded[tag.end - 2] == '/' or
            (tag.closing and std.mem.trim(u8, tag.attrs, " \t\r\n").len != 0) or
            !ordinaryTagAttributes(tag.attrs, null)) return false;
        pos = tag.end;
    }
    return true;
}

// Literal HTML here describes the stylesheet/module-selection input only.
// The renderer still owns HTML layout, ancestry, inline style and the live
// owner. Every admitted class, attribute, template argument and media link
// must be covered by the selected constructor's module-effect receipt.
fn ordinaryPresentationAttribute(tag: encoder.wikitext_syntax.Tag, name: []const u8, value: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    const cell = tag.is("td") or tag.is("th");
    if (eq(name, "role")) return tag.is("table") and eq(value, "presentation");
    if (eq(name, "clear") and tag.is("br")) {
        for ([_][]const u8{ "left", "right", "all", "both", "none" }) |v| if (eq(value, v)) return true;
        return false;
    }
    if (eq(name, "align") and (tag.is("table") or tag.is("tr") or cell)) {
        for ([_][]const u8{ "left", "right", "center", "justify" }) |v| if (eq(value, v)) return true;
        return false;
    }
    if (eq(name, "bgcolor") and (tag.is("table") or tag.is("tr") or cell)) {
        const digits = if (value.len != 0 and value[0] == '#') blk: {
            if (value.len != 4 and value.len != 7) return false;
            break :blk value[1..];
        } else blk: {
            // Bare six-digit legacy color on table cells, retained by the
            // normal sanitizer and interpreted as the same RGB triplet.
            if (!cell or value.len != 6) return false;
            break :blk value;
        };
        for (digits) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    const width = eq(name, "width") and (tag.is("table") or cell);
    const spacing = tag.is("table") and (eq(name, "border") or eq(name, "cellspacing") or eq(name, "cellpadding"));
    const span = cell and (eq(name, "colspan") or eq(name, "rowspan"));
    if (!(width or spacing or span)) return false;
    const number = if (width and std.mem.endsWith(u8, value, "%")) value[0 .. value.len - 1] else value;
    if (number.len == 0 or number.len > 8) return false;
    for (number) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// Names and offsets are the expansion issuer's original lexical occurrences.
// ordered and placed_keys are the independently selected final screen cascade,
// including parser effects without visible output. All slices are borrowed.
pub const OrdinaryStyleImport = struct { start: usize, end: usize, src: []const u8 };
pub const OrdinaryStyleReceipt = struct {
    worker_features: ?WorkerFeatures = null,
    document_base: ?[]const u8 = null,
    raw: []const u8,
    expanded: []const u8,
    imports: []const OrdinaryStyleImport,
    ordered: []const S.Source,
    placed_keys: []const ?[]const u8,
    placement_sha256: [32]u8,
    module_selection_sha256: [32]u8,
};

pub const OrdinaryRegistryEntry = struct {
    src: []const u8,
    revision_id: u64,
    dedup_key: []const u8,
    url: []const u8,
    sha256: []const u8,
    body: []const u8,
};
pub const OrdinaryLocalRegistry = struct {
    sanitizer_closure_sha256: []const u8,
    placement_sha256: []const u8,
    entries: []const OrdinaryRegistryEntry,
};

fn ordinaryStyleSrcValid(src: []const u8) bool {
    if (src.len == 0 or src.len > 512 or !std.unicode.utf8ValidateSlice(src)) return false;
    for (src) |c| if (c < 0x20 or c == 0x7f or std.mem.indexOfScalar(u8, "<>&#?:%{}[]|\\\"'", c) != null) return false;
    var parts = std.mem.splitScalar(u8, src, '/');
    while (parts.next()) |part| if (part.len == 0 or part[0] == ' ' or part[part.len - 1] == ' ' or
        std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn ordinaryStyleOccurrence(source: []const u8, start: usize, tag: encoder.wikitext_syntax.Tag, op: OrdinaryStyleImport) bool {
    if (op.start != start or op.end != tag.end or tag.closing or !tag.self_closing or !ordinaryStyleSrcValid(op.src)) return false;
    // Only the closed, standalone literal src operation; wrapper/other options
    // would change sanitized selector scope or the normal deduplication key.
    const begin = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, source, tag.end, '\n') orelse source.len;
    if (std.mem.trim(u8, source[begin..start], " \t\r").len != 0 or
        std.mem.trim(u8, source[tag.end..end], " \t\r").len != 0) return false;
    const attrs = std.mem.trim(u8, tag.attrs, " \t");
    if (attrs.len < 6 or !std.ascii.eqlIgnoreCase(attrs[0..3], "src")) return false;
    const equal = std.mem.trimStart(u8, attrs[3..], " \t");
    if (equal.len == 0 or equal[0] != '=') return false;
    const value = std.mem.trimStart(u8, equal[1..], " \t");
    return value.len >= 2 and (value[0] == '"' or value[0] == 39) and value[value.len - 1] == value[0] and
        std.mem.eql(u8, value[1 .. value.len - 1], op.src);
}

pub const OrdinaryLocalPlan = struct {
    registry: []const OrdinaryRegistryEntry,
    slots: []const OrdinarySheet,
    placement_sha256: [32]u8,

    pub fn prepare(registry: OrdinaryLocalRegistry, slots: []const OrdinarySheet) !@This() {
        if (registry.entries.len == 0 or registry.entries.len > 32 or slots.len == 0 or slots.len > 32)
            return error.InvalidContainerDisclosureInput;
        _ = try digest(registry.sanitizer_closure_sha256);
        const placement = try digest(registry.placement_sha256);
        for (registry.entries, 0..) |entry, i| {
            var buffer: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&buffer, "TemplateStyles:r{d}", .{entry.revision_id}) catch return error.InvalidContainerDisclosureInput;
            if (!ordinaryStyleSrcValid(entry.src) or entry.revision_id == 0 or !std.mem.eql(u8, key, entry.dedup_key) or
                entry.url.len == 0 or entry.url.len > 4096 or !std.unicode.utf8ValidateSlice(entry.url) or
                !try matches(entry.body, entry.sha256)) return error.InvalidContainerDisclosureInput;
            for (registry.entries[0..i]) |other| if (std.mem.eql(u8, other.src, entry.src) or
                other.revision_id == entry.revision_id) return error.InvalidContainerDisclosureInput;
        }
        var used: [32]bool = @splat(false);
        for (slots) |slot| {
            if (slot.local_key) |key| {
                for (registry.entries, 0..) |entry, i| {
                    if (!std.mem.eql(u8, entry.dedup_key, key)) continue;
                    if (used[i] or !std.mem.eql(u8, slot.url, entry.url) or !std.mem.eql(u8, slot.sha256, entry.sha256))
                        return error.InvalidContainerDisclosureInput;
                    used[i] = true;
                    break;
                } else return error.InvalidContainerDisclosureInput;
            } else {
                // An inline sheet known by this registry cannot pass as a
                // global sheet merely because it was present in a capture.
                for (registry.entries) |entry| if (std.mem.eql(u8, entry.url, slot.url) and
                    std.mem.eql(u8, entry.sha256, slot.sha256)) return error.InvalidContainerDisclosureInput;
            }
        }
        return .{ .registry = registry.entries, .slots = slots, .placement_sha256 = placement };
    }

    pub fn matchesPlacement(self: @This(), raw: []const u8, expanded: []const u8, receipt: OrdinaryStyleReceipt) bool {
        if (receipt.raw.ptr != raw.ptr or receipt.raw.len != raw.len or receipt.expanded.ptr != expanded.ptr or
            receipt.expanded.len != expanded.len or !std.mem.eql(u8, &receipt.placement_sha256, &self.placement_sha256) or
            receipt.ordered.len != self.slots.len or receipt.placed_keys.len != self.slots.len or receipt.imports.len > 4096) return false;
        for (self.slots, receipt.placed_keys) |slot, placed| {
            if (slot.local_key) |key| {
                if (!std.mem.eql(u8, key, placed orelse return false)) return false;
            } else if (placed != null) return false;
        }
        var first: [32]bool = @splat(false);
        var next: usize = 0;
        for (receipt.imports) |op| {
            for (self.registry, 0..) |entry, i| {
                if (!std.mem.eql(u8, entry.src, op.src)) continue;
                if (!first[i]) {
                    while (next < self.slots.len and self.slots[next].local_key == null) next += 1;
                    if (next == self.slots.len or !std.mem.eql(u8, self.slots[next].local_key.?, entry.dedup_key)) return false;
                    first[i] = true;
                    next += 1;
                }
                break;
            } else return false;
        }
        for (self.slots[next..]) |slot| if (slot.local_key != null) return false;
        return true;
    }
};

// The direct preprocessor recognizes the first closed comment extent and
// preserves a parsing boundary. Admit only comments without tag-like content,
// and scan the original bytes on either side without joining their syntax.
// The maintained presentation compiler's optionalTableEndFrom ends an
// authored cell and row at the surrounding TABLE close. Recognize only that
// exact stack suffix; unrelated descendants still require their own close.
fn ordinaryHtmlClosingDepth(open: []const []const u8, tag: encoder.wikitext_syntax.Tag) ?usize {
    if (!tag.closing or tag.attrs.len != 0 or open.len == 0) return null;
    if (tag.is(open[open.len - 1])) return open.len - 1;
    if (!tag.is("table")) return null;
    const eq = std.ascii.eqlIgnoreCase;
    var at = open.len;
    if (eq(open[at - 1], "td") or eq(open[at - 1], "th")) at -= 1;
    if (at == 0 or !eq(open[at - 1], "tr")) return null;
    at -= 1;
    if (at == 0 or !eq(open[at - 1], "table")) return null;
    return at - 1;
}

fn ordinaryRawCommentEnd(source: []const u8, start: usize) ?usize {
    const end = encoder.wikitext_syntax.protectedEnd(source, start) orelse return null;
    if (end < start + "<!---->".len or !std.mem.endsWith(u8, source[start..end], "-->")) return null;
    if (std.mem.indexOfScalar(u8, source[start + 4 .. end - 3], '<') != null) return null;
    return end;
}

// In ordinary text, a greater-than between ASCII spaces cannot open a
// tag. Existing tag handling still consumes and validates whole tokens.
fn ordinarySpacedGreaterThan(source: []const u8, at: usize) bool {
    return at != 0 and at + 1 < source.len and source[at] == '>' and
        source[at - 1] == ' ' and source[at + 1] == ' ';
}

fn ordinaryLiteralHtml(source: []const u8, imports: []const OrdinaryStyleImport) bool {
    return ordinaryHtml(source, imports, .expanded);
}

fn ordinaryHtml(source: []const u8, imports: []const OrdinaryStyleImport, comptime origin: enum { raw, expanded }) bool {
    var consumed: usize = 0;
    var open: [64][]const u8 = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, source, pos, "<>")) |start| {
        if (origin == .raw) {
            if (std.mem.startsWith(u8, source[start..], "<!--")) {
                pos = ordinaryRawCommentEnd(source, start) orelse return false;
                continue;
            }
        }
        if (ordinarySpacedGreaterThan(source, start)) {
            pos = start + 1;
            continue;
        }
        const tag = encoder.wikitext_syntax.tagAt(source, start) orelse return false;
        if (tag.is("templatestyles")) {
            if (consumed == imports.len or !ordinaryStyleOccurrence(source, start, tag, imports[consumed])) return false;
            consumed += 1;
            pos = tag.end;
            continue;
        }
        for ([_][]const u8{ "div", "span", "small", "i", "b", "sup", "sub", "kbd",
            "table", "tr", "td", "th", "br" }) |name| {
            if (tag.is(name)) break;
        } else return false;
        // The maintained inline parser renders an attribute-free closing
        // BR as a void line break. It cannot close a parent or add an effect.
        if (tag.closing and tag.is("br")) {
            if (!std.ascii.eqlIgnoreCase(source[start..tag.end], "</br>")) return false;
            pos = tag.end;
            continue;
        }
        if (tag.closing) {
            if (source[tag.end - 2] == '/') return false;
            depth = ordinaryHtmlClosingDepth(open[0..depth], tag) orelse return false;
        } else {
            if (!ordinaryTagAttributes(tag.attrs, tag)) return false;
            if (!tag.is("br")) {
                if (tag.self_closing or source[tag.end - 2] == '/' or depth == open.len) return false;
                open[depth] = tag.name;
                depth += 1;
            }
        }
        pos = tag.end;
    }
    return depth == 0 and consumed == imports.len;
}

// Check where LF can separate independent literal class writers. On an
// ambiguous delimiter the caller keeps the rest of the source in one span.
// A narrow syntactic boundary proof, not link/media classification. The pinned
// wikilink_preproc/link_text grammar recursively consumes an inner [[...]] in
// an outer pipe-delimited label before the outer ]]. Exclude templates, HTML,
// single brackets and a second nesting level. All source bytes still enter the
// marker scan; only the following physical LF may separate class writers.
fn ordinaryClosedNestedLinkEnd(line: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, line[start..], "[[")) return null;
    var pos = start + 2;
    var depth: usize = 0;
    var target_start: [2]usize = .{ pos, 0 };
    var in_label: [2]bool = .{ false, false };
    var structured_label = false;
    while (pos < line.len and pos - start <= 4096) {
        const c = line[pos];
        // Empty attribute-free formatting and numeric notes are literal
        // label contents. Neither can leave a frame open across the LF.
        const empty_small = "<small></small>";
        if (depth == 0 and in_label[0] and std.mem.startsWith(u8, line[pos..], empty_small)) {
            structured_label = true;
            pos += empty_small.len;
            continue;
        }
        if (c == '\r' or c == '\n' or c == 0 or c == '<' or c == '>' or c == '{' or c == '}') return null;
        if (c == '[') {
            if (depth == 0 and in_label[0]) {
                var end = pos + 1;
                while (end < line.len and end - pos <= 3 and std.ascii.isDigit(line[end])) : (end += 1) {}
                if (end > pos + 1 and end + 1 < line.len and line[end] == ']' and line[end + 1] == ' ') {
                    structured_label = true;
                    pos = end + 1;
                    continue;
                }
            }
            if (depth != 0 or !in_label[0] or !std.mem.startsWith(u8, line[pos..], "[[")) return null;
            depth = 1;
            target_start[1] = pos + 2;
            in_label[1] = false;
            structured_label = true;
            pos += 2;
            continue;
        }
        if (c == '|' or c == ']') {
            if (!in_label[depth] and std.mem.trim(u8, line[target_start[depth]..pos], " \t").len == 0) return null;
            if (c == '|') {
                if (depth == 1 and in_label[1]) return null;
                in_label[depth] = true;
                pos += 1;
                continue;
            }
            if (!std.mem.startsWith(u8, line[pos..], "]]")) return null;
            pos += 2;
            if (pos - start > 4096) return null;
            if (depth == 0) return if (structured_label) pos else null;
            depth = 0;
            continue;
        }
        pos += 1;
    }
    return null;
}

// A translation item can contain a literal single-bracket CJK gloss
// immediately after a closed wiki link. It is neither an external-link
// target nor an open internal-link frame. Keep both closing characters.
fn ordinaryHanGloss(gloss: []const u8) bool {
    if (gloss.len == 0) return false;
    const utf8 = std.unicode.Utf8View.init(gloss) catch return false;
    var it = utf8.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!(cp >= 0x3400 and cp <= 0x4dbf) and !(cp >= 0x4e00 and cp <= 0x9fff)) return false;
    }
    return true;
}

fn ordinaryTranslationGlossEnd(line: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, line, ":*") or start < 3 or
        !std.mem.eql(u8, line[start - 3 .. start], "]] ")) return null;
    const close = std.mem.indexOfScalarPos(u8, line, start + 1, ']') orelse return null;
    if (close - start > 49 or close + 2 >= line.len or !std.mem.startsWith(u8, line[close..], "]] ")) return null;
    const gloss = line[start + 1 .. close];
    return if (ordinaryHanGloss(gloss)) close + 2 else null;
}

fn ordinaryLineOperands(line: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfAnyPos(u8, line, cursor, "[]<>")) |i| {
        switch (line[i]) {
            '<' => {
                const tag = encoder.wikitext_syntax.tagAt(line, i) orelse return false;
                if (std.mem.indexOfAny(u8, tag.attrs, "[]") != null) return false;
                cursor = tag.end;
            },
            '>' => {
                if (!ordinarySpacedGreaterThan(line, i)) return false;
                cursor = i + 1;
            },
            '[' => {
                const double = std.mem.startsWith(u8, line[i..], "[[");
                if (!double) {
                    if (ordinaryTranslationGlossEnd(line, i)) |end| {
                        cursor = end;
                        continue;
                    }
                }
                const start = i + @as(usize, if (double) 2 else 1);
                const close = std.mem.indexOfAnyPos(u8, line, start, "[]<>") orelse return false;
                if (line[close] != ']' or (double and !std.mem.startsWith(u8, line[close..], "]]"))) {
                    if (!double) return false;
                    cursor = ordinaryClosedNestedLinkEnd(line, i) orelse return false;
                    continue;
                }
                cursor = close + @as(usize, if (double) 2 else 1);
            },
            else => return false,
        }
    }
    return true;
}

fn ordinaryPinMatch(bytes: []const u8, matched: *usize) bool {
    const marker = "vector-pinnable-header";
    for (bytes) |byte| {
        if (std.ascii.toLower(byte) == marker[matched.*]) {
            matched.* += 1;
            if (matched.* == marker.len) return true;
        }
    }
    return false;
}

// The single-pass decoder accepts only alphanumeric names or numeric
// references ending in ';'. An ASCII query key ending in '=' cannot be a
// reference. Keep its complete spelling in the pin-header marker scan.
fn ordinaryLiteralQueryKeyEnd(line: []const u8, amp: usize) ?usize {
    var end = amp + 1;
    if (end == line.len or !std.ascii.isAlphanumeric(line[end])) return null;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
    return if (end < line.len and line[end] == '=') end + 1 else null;
}

// A bare terminal query field is literal only in a complete bracketed HTTP(S)
// target. Keep the raw bytes in the marker scan, as with an assigned key.
fn ordinaryTerminalQueryFlagEnd(line: []const u8, amp: usize) ?usize {
    var end = amp + 1;
    if (end == line.len or !std.ascii.isAlphabetic(line[end])) return null;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
    if (end == line.len or std.mem.indexOfScalar(u8, " \t]", line[end]) == null or line.len > 4096)
        return null;
    if (@import("xml_decode").html_entities.lookupNamedEntity(line[amp + 1 .. end]) != null) return null;

    const open = std.mem.lastIndexOfScalar(u8, line[0..amp], '[') orelse return null;
    if (open != 0 and line[open - 1] == '[') return null;
    const target = line[open + 1 .. end];
    if (!std.mem.startsWith(u8, target, "http://") and !std.mem.startsWith(u8, target, "https://")) return null;
    const query = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const amp_in_target = amp - open - 1;
    if (query >= amp_in_target or std.mem.indexOfScalar(u8, target, '#') != null or
        std.mem.indexOfScalar(u8, target[query + 1 .. amp_in_target], '=') == null or
        !ordinaryLineOperands(line)) return null;

    var inline_tokens: encoder.document_ir.InlineIterator = .{ .input = line[open..] };
    const link = inline_tokens.next() orelse return null;
    if (link.kind != .external_link or link.target.ptr != target.ptr or link.target.len != target.len)
        return null;
    return end;
}

// The contents of a flat navigation list are independent wiki link targets
// and plain separators. No attributes, piped labels, entities, namespace
// effects or formatting are admitted. Keep checking for a marker inside each
// target; accumulating one across unrelated targets cannot describe a class.
fn ordinaryPinFlatLinkList(line: []const u8) ?bool {
    if (line.len > 4096 or !std.mem.startsWith(u8, line, "[[") or std.mem.indexOf(u8, line, " · ") == null)
        return null;
    var pos: usize = 0;
    var links: usize = 0;
    var marker_found = false;
    while (pos < line.len) {
        if (std.mem.startsWith(u8, line[pos..], "[[")) {
            const close = std.mem.indexOfPos(u8, line, pos + 2, "]]") orelse return null;
            const name = line[pos + 2 .. close];
            if (std.mem.trim(u8, name, " ").len == 0) return null;
            for (name) |c| {
                if (c < 0x80 and !std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, " '-", c) == null)
                    return null;
            }
            var matched: usize = 0;
            if (ordinaryPinMatch(name, &matched)) marker_found = true;
            links += 1;
            pos = close + 2;
        } else if (std.mem.startsWith(u8, line[pos..], " · ")) {
            pos += " · ".len;
        } else if (std.mem.startsWith(u8, line[pos..], "o ")) {
            pos += 2;
        } else if (std.mem.indexOfScalar(u8, " ()", line[pos]) != null) {
            pos += 1;
        } else return null;
    }
    return if (links >= 2) !marker_found else null;
}

// A closed literal span in a parsed list item owns its quoted style value.
// Its bytes cannot become part of a class on this or another element. Check
// the value for a contiguous marker and keep the old scan for all other bytes.
fn ordinaryPinStyledListLine(line: []const u8) ?bool {
    if (!std.mem.startsWith(u8, line, "* ") or line.len > 4096 or
        std.mem.indexOfAny(u8, line, "&{}\r") != null or !ordinaryLineOperands(line)) return null;

    var search: usize = 0;
    var outside: usize = 0;
    var matched: usize = 0;
    var found = false;
    while (std.mem.indexOfScalarPos(u8, line, search, '<')) |start| {
        const class_open = "<span class=\"";
        const style_open = "\" style=\"";
        const close = "</span>";
        if (!std.mem.startsWith(u8, line[start..], class_open)) return null;
        const tag = encoder.wikitext_syntax.tagAt(line, start) orelse return null;
        if (!ordinaryTagAttributes(tag.attrs, tag)) return null;
        const class_end = std.mem.indexOfScalarPos(u8, line[0..tag.end], start + class_open.len, '"') orelse return null;
        if (!std.mem.startsWith(u8, line[class_end..tag.end], style_open)) return null;
        const style_start = class_end + style_open.len;
        const style_end = std.mem.indexOfScalarPos(u8, line[0..tag.end], style_start, '"') orelse return null;
        if (!std.mem.eql(u8, line[style_end..tag.end], "\">")) return null;
        const end = std.mem.indexOfAnyPos(u8, line, tag.end, "<>[]") orelse return null;
        if (!std.mem.startsWith(u8, line[end..], close)) return null;

        if (!found) found = ordinaryPinMatch(line[outside..style_start], &matched) or
            std.ascii.findIgnoreCase(line[style_start..style_end], "vector-pinnable-header") != null;
        outside = style_end;
        search = end + close.len;
    }
    if (search == 0) return null;
    return !found and !ordinaryPinMatch(line[outside..], &matched);
}

fn ordinaryPinHeaderAbsent(expanded: []const u8) bool {
    if (std.mem.indexOf(u8, expanded, "-{") != null) return false;
    var lines = std.mem.splitScalar(u8, expanded, '\n');
    var matched: usize = 0;
    var joined_suffix = false;
    while (lines.next()) |line| {
        if (!joined_suffix) {
            matched = 0;
            if (ordinaryPinStyledListLine(line)) |absent| {
                if (!absent) return false;
                continue;
            }
            if (ordinaryPinFlatLinkList(line)) |absent| {
                if (!absent) return false;
                continue;
            }
            joined_suffix = !ordinaryLineOperands(line);
        }
        // A subsequence covers token flattening that drops source bytes. Feed
        // both spellings of references, so mixed literal/decoded paths are covered.
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, cursor, '&')) |amp| {
            if (ordinaryPinMatch(line[cursor..amp], &matched)) return false;
            if (ordinaryLiteralQueryKeyEnd(line, amp)) |end| {
                if (ordinaryPinMatch(line[amp..end], &matched)) return false;
                cursor = end;
                continue;
            }
            if (ordinaryTerminalQueryFlagEnd(line, amp)) |end| {
                if (ordinaryPinMatch(line[amp..end], &matched)) return false;
                cursor = end;
                continue;
            }
            const window = line[amp..][0..@min(line.len - amp, 64)];
            const semi = std.mem.indexOfScalar(u8, window, ';') orelse return false;
            const spelling = window[0 .. semi + 1];
            if (std.mem.indexOfAny(u8, spelling[1..semi], "& \t\r") != null) return false;
            var storage: [128]u8 = undefined;
            var scratch = std.heap.FixedBufferAllocator.init(&storage);
            var decoded = std.ArrayList(u8).initCapacity(scratch.allocator(), storage.len) catch return false;
            @import("xml_decode").decodeSinglePassInto(&decoded, scratch.allocator(), spelling) catch return false;
            const value = decoded.items;
            if (std.mem.eql(u8, spelling, value)) return false;
            // A second reference or syntax delimiter is outside this projection.
            for (value) |c| if (c < 0x80 and !std.ascii.isAlphanumeric(c) and c != '-' and c != ' ') return false;
            if (ordinaryPinMatch(spelling, &matched) or ordinaryPinMatch(value, &matched)) return false;
            cursor = amp + spelling.len;
        }
        if (ordinaryPinMatch(line[cursor..], &matched)) return false;
    }
    return true;
}

pub const OrdinarySourceCall = struct { name: []const u8, source: []const u8, depth: usize };

// A single } following one complete flat link at physical EOL is ordinary
// text (for example a translation list), not a template closer.
fn ordinaryStaticLinkTail(raw: []const u8, brace: usize) bool {
    if (brace < 4 or !std.mem.eql(u8, raw[brace - 2 .. brace], "]]")) return false;
    const line = if (std.mem.lastIndexOfScalar(u8, raw[0..brace], 0x0a)) |lf| lf + 1 else 0;
    if (brace - 2 < line) return false;
    const open = line + (std.mem.indexOfAny(u8, raw[line .. brace - 2], "[]<>") orelse return false);
    if (!std.mem.startsWith(u8, raw[open .. brace - 2], "[[")) return false;
    const content = raw[open + 2 .. brace - 2];
    return content.len != 0 and std.mem.indexOfAny(u8, content, "[]{}<>&\r") == null;
}

fn ordinaryStaticCalls(raw: []const u8, depth: usize, visitor: anytype) bool {
    var pos: usize = 0;
    var table = false;
    while (std.mem.indexOfAnyPos(u8, raw, pos, "<{}")) |start| {
        if (raw[start] == '<') {
            pos = if (std.mem.startsWith(u8, raw[start..], "<!--"))
                ordinaryRawCommentEnd(raw, start) orelse return false
            else
                start + 1;
            continue;
        }
        // These root wikitext table markers are literal braces. Resume at the
        // marker so templates in table attributes and cells are still visited.
        if (depth == 0 and (start == 0 or raw[start - 1] == 0x0a) and std.mem.startsWith(u8, raw[start..], "{|")) {
            if (table) return false;
            table = true;
            pos = start + 2;
            continue;
        }
        const line_end = start + 1 == raw.len or raw[start + 1] == 0x0a;
        if (depth == 0 and line_end and raw[start] == '}') {
            if (start != 0 and raw[start - 1] == '|' and (start == 1 or raw[start - 2] == 0x0a)) {
                if (!table) return false;
                table = false;
                pos = start + 1;
                continue;
            }
            if (ordinaryStaticLinkTail(raw, start)) {
                pos = start + 1;
                continue;
            }
        }
        if (depth == 16 or !std.mem.startsWith(u8, raw[start..], "{{") or std.mem.startsWith(u8, raw[start..], "{{{")) return false;
        const pair = encoder.wikitext_syntax.balanced(raw, start) orelse return false;
        // The expander resolves the exact argument-level pipe magic to one
        // literal byte, without a template call. Qualified output still faces
        // the independent HTML, style, marker and media checks.
        if (depth != 0 and std.mem.eql(u8, raw[start..pair.end], "{{!}}")) {
            pos = pair.end;
            continue;
        }
        const body = raw[start + 2 .. pair.inner_end];
        const bar = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const name = std.mem.trim(u8, body[0..bar], " \t\r\n");
        if (!validOrdinaryCall(name)) return false;
        if (!visitor.visit(OrdinarySourceCall{ .name = name, .source = raw[start..pair.end], .depth = depth })) return false;
        if (bar < body.len and !ordinaryStaticCalls(body[bar + 1 ..], depth + 1, visitor)) return false;
        pos = pair.end;
    }
    return !table;
}

// The provider may stage source effects using exact original call slices.
// Commit the staging only on success. Visiting a call, particularly a lazy
// argument, never proves that its expansion activated a module.
pub fn ordinaryFamilySourceInventory(raw: []const u8, expanded: []const u8, visitor: anytype) bool {
    return ordinaryFamilyStyleInventory(raw, expanded, &.{}, visitor);
}

// Verify the issuer's occurrence inventory while checking the original
// expansion, including its document-wide marker. No source bytes are erased.
pub fn ordinaryFamilyStyleInventory(raw: []const u8, expanded: []const u8, imports: []const OrdinaryStyleImport,
    visitor: anytype) bool
{
    if (!ordinaryBoundedSource(&.{}, raw, expanded) or std.mem.indexOf(u8, expanded, "{{") != null or
        std.mem.indexOf(u8, expanded, "}}") != null or !ordinaryHtml(raw, &.{}, .raw) or !ordinaryLiteralHtml(expanded, imports)) return false;
    if (!ordinaryPinHeaderAbsent(expanded)) return false;
    return ordinaryStaticCalls(raw, 0, visitor);
}

pub fn ordinaryFamilySourceSelected(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8) bool {
    return ordinaryFamilyCallsSelected(calls, raw, expanded, &.{});
}

fn ordinaryFamilyCallsSelected(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport) bool
{
    if (calls.len > 1024) return false;
    var catalog = struct {
        calls: []const OrdinaryCall,
        seen: [1024]bool = @splat(false),
        pub fn visit(self: *@This(), found: OrdinarySourceCall) bool {
            for (self.calls, 0..) |call, i| {
                if (std.mem.eql(u8, found.name, call.name)) {
                    if (found.depth == 0) self.seen[i] = true;
                    return true;
                }
            }
            return false;
        }
    }{ .calls = calls };
    if (!ordinaryFamilyStyleInventory(raw, expanded, imports, &catalog)) return false;
    for (calls, catalog.seen[0..calls.len]) |call, present| if (call.required and !present) return false;
    return true;
}

// The immutable base contains only the fixed global vector. The effect
// producer supplies the effective order for this job. Check every byte, key
// and base before parsing this exact vector in the page arena.
fn ordinaryReceiptSource(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport) bool
{
    if (calls.len != 0) return ordinaryFamilyCallsSelected(calls, raw, expanded, imports);
    const Names = struct { pub fn visit(_: @This(), _: OrdinarySourceCall) bool { return true; } };
    return ordinaryFamilyStyleInventory(raw, expanded, imports, Names{});
}

const P = @import("bundle_protocol");

const WorkerPhase = struct {
    schema: []const u8,
    status: []const u8,
    collector: []const u8,
    generation: u64,
    identity: struct { title: []const u8, namespace: i32, page_id: u64, revision_id: u64 },
    source_sha256: []const u8,
    expanded_sha256: []const u8,
    display_title_sha256: []const u8,
    operation_count: u32,
    observed_extensions: []const []const u8,
    template_styles: []const struct {
        src: []const u8,
        origin: enum { extension_call, literal_input, preprocess_result, expanded_output, display_title },
    },
    placement: ?bool,
};

fn sheetEqual(x: OrdinarySheet, y: OrdinarySheet) bool {
    return x.local_key == null and y.local_key == null and x.byte_start == y.byte_start and
        x.unknown_applicability == y.unknown_applicability and std.mem.eql(u8, x.url, y.url) and
        std.mem.eql(u8, x.sha256, y.sha256);
}

const WorkerFeatures = struct { toc: bool, tmh: bool };

fn workerSlots(w: WorkerProjection, f: WorkerFeatures) ?[]const OrdinarySheet {
    if (f.tmh) return if (f.toc) w.toc_on else w.toc_off;
    const absent = w.without_tmh orelse return null;
    return if (f.toc) absent.toc_on else absent.toc_off;
}

fn workerSubsequence(full: []const OrdinarySheet, part: []const OrdinarySheet) bool {
    if (part.len == 0 or part.len > full.len) return false;
    var i: usize = 0;
    for (full) |slot| {
        if (i < part.len and sheetEqual(slot, part[i])) i += 1;
    }
    return i == part.len;
}

fn workerProjectionValid(w: WorkerProjection, m: OrdinaryManifest) !bool {
    if (!std.mem.eql(u8, w.schema, "native-it-normal-module-projection.v1") or
        !std.mem.eql(u8, m.wiki, "itwiktionary") or !std.mem.eql(u8, w.catalog_sha256, m.module_selection_sha256) or
        w.toc_on.len != m.sheets.len or w.media_operations.len > 4096) return false;
    _ = try digest(w.feature_source_sha256);
    if (w.image_catalog) |ref| {
        try image_catalog.validReference(ref);
        if (!std.mem.eql(u8, ref.namespace_sha256, m.namespace_sha256) or
            !std.mem.eql(u8, ref.feature_source_sha256, w.feature_source_sha256) or
            !std.mem.eql(u8, ref.module_selection_sha256, m.module_selection_sha256)) return false;
    }
    if (w.timed_media) |ref| {
        try timed_media_inputs.validReference(ref);
        if (w.image_catalog == null or !std.mem.eql(u8, ref.namespace_sha256, m.namespace_sha256) or
            !std.mem.eql(u8, ref.module_selection_sha256, m.module_selection_sha256)) return false;
    }
    if (w.placement_source_sha256) |pin| if (!std.mem.eql(u8, pin, m.local_registry.?.placement_sha256)) return false;
    if (w.local_placement) |mode| {
        if ((!std.mem.eql(u8, mode, "document-prefix-first-key.v1") and
            !std.mem.eql(u8, mode, "document-prefix-one-tail-key.v1")) or w.placement_source_sha256 == null) return false;
    }
    for (w.toc_on, m.sheets) |x, y| if (!sheetEqual(x, y)) return false;
    if (w.toc_off) |off| {
        if (off.len + 1 != w.toc_on.len or !workerSubsequence(w.toc_on, off)) return false;
    }
    if (w.without_tmh) |absent| {
        if (absent.toc_on.len + 1 != w.toc_on.len or !workerSubsequence(w.toc_on, absent.toc_on)) return false;
        if (absent.toc_off) |off| {
            const on_media_off_toc = w.toc_off orelse return false;
            if (off.len + 1 != absent.toc_on.len or !workerSubsequence(absent.toc_on, off) or
                !workerSubsequence(on_media_off_toc, off)) return false;
        }
    }
    for (w.media_operations, 0..) |op, i| {
        _ = try digest(op.evidence_sha256);
        if (op.operand.len < 5 or op.operand.len > 4096 or !std.mem.startsWith(u8, op.operand, "[[") or
            !std.mem.endsWith(u8, op.operand, "]]")) return false;
        for (w.media_operations[0..i]) |prior| if (std.mem.eql(u8, op.operand, prior.operand)) return false;
    }
    return true;
}

// TemplateStyles emits a STYLE node at the extension position. A sequence of
// standalone imports before all page content is outside any table, formatting
// or preformatted context. Tree construction cannot move a later page node in
// front of this prefix. Deduplication therefore keeps first full-key order.
// Do not extend this to arbitrary balanced HTML: foster parenting can reorder
// two distinct keys even when all source tags are balanced.
pub fn ordinaryStylePrefix(expanded: []const u8, imports: []const OrdinaryStyleImport) bool {
    if (imports.len == 0) return true;
    if (imports.len > 4096 or expanded.len > 1024 * 1024 or !ordinaryLiteralHtml(expanded, imports)) return false;
    var cursor: usize = 0;
    for (imports) |op| {
        if (op.start < cursor or op.end <= op.start or op.end > expanded.len or
            (op.start != 0 and expanded[op.start - 1] != '\n')) return false;
        // Only trailing whitespace on the preceding import line is allowed.
        // Indent-only blank lines could start wiki preformatted content.
        var gap = cursor;
        if (cursor != 0) while (gap < op.start and (expanded[gap] == ' ' or expanded[gap] == '\t')) : (gap += 1) {};
        while (gap < op.start) {
            if (expanded[gap] == '\n') {
                gap += 1;
            } else if (expanded[gap] == '\r' and gap + 1 < op.start and expanded[gap + 1] == '\n') {
                gap += 2;
            } else return false;
        }
        const tag = encoder.wikitext_syntax.tagAt(expanded, op.start) orelse return false;
        if (!ordinaryStyleOccurrence(expanded, op.start, tag, op)) return false;
        cursor = op.end;
    }
    return true;
}

// First occurrences in the document prefix cannot be moved behind body nodes
// by table foster parenting. Repeated keys have already been deduplicated there.
// Permit one further distinct key: its internal placement cannot change its
// order relative to the anchored keys. Two unanchored keys would require an
// independent final-tree ordering proof, even for lexically balanced HTML.
pub fn ordinaryStyleAnchoredKeys(expanded: []const u8, imports: []const OrdinaryStyleImport) bool {
    if (imports.len == 0) return true;
    if (imports.len > 4096 or expanded.len > 1024 * 1024 or !ordinaryLiteralHtml(expanded, imports)) return false;
    var anchored: [32][]const u8 = undefined;
    var anchored_count: usize = 0;
    var cursor: usize = 0;
    var in_prefix = true;
    var tail_key: ?[]const u8 = null;
    for (imports) |op| {
        if (op.start < cursor or op.end <= op.start or op.end > expanded.len) return false;
        if (in_prefix) {
            var gap = cursor;
            if (cursor != 0) while (gap < op.start and (expanded[gap] == ' ' or expanded[gap] == '\t')) : (gap += 1) {};
            while (gap < op.start) {
                if (expanded[gap] == '\n') {
                    gap += 1;
                } else if (expanded[gap] == '\r' and gap + 1 < op.start and expanded[gap + 1] == '\n') {
                    gap += 2;
                } else break;
            }
            in_prefix = gap == op.start and (op.start == 0 or expanded[op.start - 1] == '\n');
        }
        if (anchored_count == 0 and !in_prefix) return false;
        const known = for (anchored[0..anchored_count]) |key| {
            if (std.mem.eql(u8, key, op.src)) break true;
        } else false;
        if (!known) {
            if (in_prefix) {
                if (anchored_count == anchored.len) return false;
                anchored[anchored_count] = op.src;
                anchored_count += 1;
            } else if (tail_key) |key| {
                if (!std.mem.eql(u8, key, op.src)) return false;
            } else tail_key = op.src;
        }
        cursor = op.end;
    }
    return true;
}

fn workerLocalPlacementValid(w: WorkerProjection, expanded: []const u8, imports: []const OrdinaryStyleImport) bool {
    if (imports.len == 0) return true;
    if (w.placement_source_sha256 == null) return false;
    const mode = w.local_placement orelse return false;
    if (std.mem.eql(u8, mode, "document-prefix-first-key.v1")) return ordinaryStylePrefix(expanded, imports);
    if (std.mem.eql(u8, mode, "document-prefix-one-tail-key.v1")) return ordinaryStyleAnchoredKeys(expanded, imports);
    return false;
}

fn workerStyleImports(a: std.mem.Allocator, expanded: []const u8, registry: OrdinaryLocalRegistry) !?[]const OrdinaryStyleImport {
    var ops: std.ArrayList(OrdinaryStyleImport) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, expanded, pos, '<')) |start| {
        const tag = encoder.wikitext_syntax.tagAt(expanded, start) orelse return null;
        pos = tag.end;
        if (!tag.is("templatestyles")) continue;
        if (ops.items.len == 4096) return null;
        for (registry.entries) |entry| {
            const op: OrdinaryStyleImport = .{ .src = entry.src, .start = start, .end = tag.end };
            if (ordinaryStyleOccurrence(expanded, start, tag, op)) {
                try ops.append(a, op);
                break;
            }
        } else return null;
    }
    return ops.items;
}

// The collector records a set of observed operands/origins. Only final output
// occurrences enter the placement recipe. Never add CSS from a discarded call.
fn workerOperationsMatch(phase: WorkerPhase, ops: []const OrdinaryStyleImport, registry: OrdinaryLocalRegistry) bool {
    if (phase.placement != null or phase.operation_count > 4096 or phase.template_styles.len > 128 or
        phase.observed_extensions.len > 1 or phase.observed_extensions.len > phase.operation_count or
        phase.template_styles.len > phase.operation_count) return false;
    if (phase.observed_extensions.len == 0) return phase.template_styles.len == 0 and ops.len == 0 and phase.operation_count == 0;
    if (!std.mem.eql(u8, phase.observed_extensions[0], "templatestyles") or phase.template_styles.len == 0) return false;
    for (phase.template_styles) |item| {
        if (item.origin == .display_title) return false;
        for (registry.entries) |entry| {
            if (std.mem.eql(u8, item.src, entry.src)) break;
        } else return false;
        if (item.origin == .expanded_output) {
            for (ops) |op| {
                if (std.mem.eql(u8, item.src, op.src)) break;
            } else return false;
        }
    }
    for (ops) |op| {
        for (phase.template_styles) |item| {
            if (item.origin == .expanded_output and std.mem.eql(u8, op.src, item.src)) break;
        } else return false;
    }
    return true;
}

fn workerHasUnsupportedTrigger(bytes: []const u8) bool {
    for ([_][]const u8{ "sortable", "mw-ui-button", "mw-message-box", "floatright", "floatleft", "thumbinner" }) |token|
        if (std.ascii.findIgnoreCase(bytes, token) != null) return true;
    return false;
}

fn workerHeadingTrigger(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '=') continue;
        for ([_][]const u8{ "sortable", "mw-ui-button", "mw-message-box", "floatright", "floatleft", "thumbinner" }) |token| {
            var i: usize = 0;
            for (line) |c| {
                if (std.ascii.toLower(c) != token[i]) continue;
                i += 1;
                if (i == token.len) return true;
            }
        }
    }
    return false;
}

fn workerTriggerFree(a: std.mem.Allocator, bytes: []const u8) !bool {
    if (workerHasUnsupportedTrigger(bytes) or workerHeadingTrigger(bytes)) return false;
    if (std.mem.indexOfScalar(u8, bytes, '&') == null) return true;
    const decoded = try @import("xml_decode").decodeSinglePassAlloc(a, bytes);
    defer a.free(decoded);
    return !workerHasUnsupportedTrigger(decoded) and !workerHeadingTrigger(decoded);
}

// The source inventory has already matched every literal tag against its opener.
// At a wiki-table boundary consume only bare closers belonging to the exterior.
fn workerTableTailDepth(tail: []const u8, outer_depth: usize) ?usize {
    var depth = outer_depth;
    var pos: usize = 0;
    while (pos < tail.len) {
        if (tail[pos] == ' ' or tail[pos] == '\t') {
            pos += 1;
            continue;
        }
        const tag = encoder.wikitext_syntax.tagAt(tail, pos) orelse return null;
        if (depth == 0 or !tag.closing or tag.is("br") or tag.self_closing or tag.attrs.len != 0 or tail[tag.end - 2] == '/') return null;
        depth -= 1;
        pos = tag.end;
    }
    return depth;
}

fn workerPlainExternalText(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ' or c == '\t';
}

// The maintained inline parser recognizes a literal '[' followed by a complete
// external link. The caller found the first markup delimiter on this line.
// Any subsequent markup stays with the outer scanner, including file links.
fn workerDoubleExternalEnd(line: []const u8, start: usize, close: usize) ?usize {
    if (line[close] != ']') return null;
    const body = line[start + 2 .. close];
    const space = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
    const target = body[0..space];
    if (!std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "http://")) return null;
    if (std.mem.indexOfAny(u8, target, "&{}|'\"\\") != null or !encoder.document_ir.validExternalUrl(target)) return null;
    for (body[space..]) |c| if (!workerPlainExternalText(c)) return null;
    if (!encoder.document_ir.doubleOpeningExternalToken(line[start .. close + 1], 0)) return null;

    // The extra opening punctuation may have a separate literal closing
    // bracket after plain words. Never search through a token to pair it.
    var end = close + 1;
    while (end < line.len and workerPlainExternalText(line[end])) end += 1;
    if (end < line.len and line[end] == ']') return end + 1;
    return close + 1;
}

// Only count closed wiki headings at root. Require local, single-line link
// syntax, balanced non-nested wiki tables and balanced literal HTML. Ambiguous
// transitions cannot contribute a heading or a negative media observation.
// Parsoid inlineline falls back to text when neither wikilink nor extlink
// matches. These bounded alphabets also exclude autolinks and inline markup.
fn ordinaryLiteralBracket(content: []const u8) bool {
    if (content.len == 0 or content.len > 128) return false;
    if (std.mem.eql(u8, content, "...")) return true;

    // A primary-stress mark followed only by letters cannot introduce an
    // external target, a magic link or inline markup in Parsoid inlineline.
    if (std.mem.cutPrefix(u8, content, "ˈ")) |letters| {
        if (letters.len == 0) return false;
        const view = std.unicode.Utf8View.init(letters) catch return false;
        var chars = view.iterator();
        while (chars.nextCodepoint()) |cp| {
            if (cp >= 'a' and cp <= 'z') continue;
            if (cp < 0x0250 or cp > 0x02af) return false;
        }
        return true;
    }

    if (std.ascii.isLower(content[0])) {
        if (std.mem.indexOfScalar(u8, content, '-') == null) return false;
        var words = std.mem.splitScalar(u8, content, '-');
        while (words.next()) |word| {
            if (word.len == 0) return false;
            for (word) |c| if (!std.ascii.isLower(c)) return false;
        }
        return true;
    }

    var groups = std.mem.splitSequence(u8, content, ", ");
    while (groups.next()) |group| {
        const view = std.unicode.Utf8View.init(group) catch return false;
        var chars = view.iterator();
        const first = chars.nextCodepoint() orelse return false;
        if (first < 0x4e00 or first > 0x9fff) return false;
        var digits = false;
        while (chars.nextCodepoint()) |c| {
            if (c >= '0' and c <= '9') {
                digits = true;
            } else if (digits or c < 0x4e00 or c > 0x9fff) return false;
        }
    }
    return true;
}

fn workerFeatures(a: std.mem.Allocator, expanded: []const u8, ns: *const namespace_registry.Registry,
    recipe: WorkerProjection, catalog: ?*const image_catalog.Catalog) !?WorkerFeatures
{
    return workerFeaturesWithTimed(a, expanded, ns, recipe, catalog, null);
}

fn workerStandaloneNonModificabileHeading(expanded: []const u8, start: usize, end: usize) bool {
    const opener = "<div class=\"NonModificabile\">\n";
    if (start < opener.len) return false;
    const open = start - opener.len;
    if (open != 0 and expanded[open - 1] != '\n') return false;
    if (!std.mem.eql(u8, expanded[open..start], opener)) return false;
    const tail = expanded[end..];
    return std.mem.eql(u8, tail, "\n</div>") or std.mem.startsWith(u8, tail, "\n</div>\n");
}

// The expanded translation list contains plain reading glosses. Recognize
// only the local parenthesized ASCII reading or a Han gloss after a closed
// link. Neither spelling can open an external URL or a wiki-link frame.
fn workerTranslationBracket(line: []const u8, start: usize, end: usize) bool {
    if (!std.mem.startsWith(u8, line, ":*") or start == 0 or line[start - 1] != ' ') return false;
    const gloss = line[start + 1 .. end];
    const after = line[end + 1 ..];
    if (start >= 3 and std.mem.eql(u8, line[start - 3 .. start], "]] ") and
        std.mem.startsWith(u8, after, " (") and std.mem.endsWith(u8, gloss, "-"))
        return gloss.len <= 49 and ordinaryHanGloss(gloss[0 .. gloss.len - 1]);
    if (!std.mem.startsWith(u8, after, ")") or gloss.len == 0 or gloss.len > 8) return false;
    for (gloss) |c| if (!std.ascii.isLower(c)) return false;
    const open = std.mem.lastIndexOfScalar(u8, line[0 .. start - 1], '(') orelse return false;
    const reading = line[open + 1 .. start - 1];
    return reading.len != 0 and std.mem.indexOfAny(u8, reading, " []()<>:/{&\t\r") == null;
}

fn workerFeaturesWithTimed(a: std.mem.Allocator, expanded: []const u8, ns: *const namespace_registry.Registry,
    recipe: WorkerProjection, catalog: ?*const image_catalog.Catalog, timed: ?timed_media_inputs.Page) !?WorkerFeatures
{
    var html_depth: usize = 0;
    var html_open: [64][]const u8 = undefined;
    var in_table = false;
    // Two wiki-table frames admit the retained RAL color layouts. A nested
    // table may start only in a bare data cell, through DIV wrappers.
    const TableFrame = struct { outer_depth: usize, bare_cell_depth: ?usize = null };
    var tables: [2]TableFrame = undefined;
    var table_count: usize = 0;
    var headings: usize = 0;
    var early_reference_heading = false;
    var audio = false;
    var lines = std.mem.splitScalar(u8, expanded, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        // An indented closing control is outside this witnessed grammar.
        // Do not silently count it as ordinary text inside an open table.
        const table_control = std.mem.trimStart(u8, line, " \t");
        if (in_table and table_control.len != line.len and std.mem.startsWith(u8, table_control, "|}")) return null;
        if (std.mem.startsWith(u8, line, "{|")) {
            if (table_count == tables.len) return null;
            if (in_table) {
                const parent = tables[table_count - 1];
                const cell_depth = parent.bare_cell_depth orelse return null;
                if (parent.outer_depth != cell_depth or cell_depth > html_depth) return null;
                for (html_open[cell_depth..html_depth]) |name| {
                    if (!std.ascii.eqlIgnoreCase(name, "div")) return null;
                }
            }
            tables[table_count] = .{ .outer_depth = html_depth };
            table_count += 1;
            in_table = true;
        } else if (std.mem.startsWith(u8, line, "|}")) {
            // Every HTML scope opened inside the wiki table must close there.
            // A suffix may then close wrappers belonging to the exterior.
            if (!in_table) return null;
            const frame = tables[table_count - 1];
            if (frame.outer_depth != html_depth or (table_count > 1 and line.len != 2)) return null;
            table_count -= 1;
            in_table = table_count != 0;
            if (line.len != 2) {
                html_depth = workerTableTailDepth(line[2..], html_depth) orelse return null;
                continue;
            }
        } else if (in_table and line.len != 0 and (line[0] == '|' or line[0] == '!')) {
            // Row, caption, header and non-bare cells revoke nested entry.
            tables[table_count - 1].bare_cell_depth =
                if (std.mem.eql(u8, line, "|") and tables[table_count - 1].outer_depth == html_depth)
                    html_depth else null;
        } else if (line.len != 0 and line[0] == '=') {
            var left: usize = 0;
            while (left < line.len and line[left] == '=') left += 1;
            var end = line.len;
            while (end > left and line[end - 1] == '=') end -= 1;
            if (left > 6 or end == left or line.len - end != left or in_table) return null;
            if (html_depth == 0) {
                headings += 1;
            } else if (headings < 4) {
                const line_offset = @intFromPtr(raw.ptr) - @intFromPtr(expanded.ptr);
                if (html_depth != 1 or left != 2 or early_reference_heading or
                    !workerStandaloneNonModificabileHeading(expanded, line_offset, line_offset + raw.len))
                    return null;
                early_reference_heading = true;
            }
            // A single isolated reference heading may precede the fourth
            // root heading. Keep scanning its links and prove TOC-on at EOF.
        }
        var pos: usize = 0;
        while (std.mem.indexOfAnyPos(u8, line, pos, "<[]")) |start| {
            if (line[start] == '<') {
                const tag = encoder.wikitext_syntax.tagAt(line, start) orelse return null;
                if (tag.is("br")) {
                    if (tag.closing and !std.ascii.eqlIgnoreCase(line[start..tag.end], "</br>")) return null;
                } else if (tag.closing) {
                    if (line[tag.end - 2] == '/') return null;
                    const next_depth = ordinaryHtmlClosingDepth(html_open[0..html_depth], tag) orelse return null;
                    // Optional TD/TR closes may return to their literal
                    // TABLE, but cannot escape any open wiki-table frame.
                    for (tables[0..table_count]) |frame| {
                        if (next_depth < frame.outer_depth) return null;
                    }
                    html_depth = next_depth;
                } else if (!tag.self_closing) {
                    if (html_depth == html_open.len) return null;
                    html_open[html_depth] = tag.name;
                    html_depth += 1;
                }
                pos = tag.end;
                continue;
            }
            if (line[start] == ']') return null;
            if (!std.mem.startsWith(u8, line[start..], "[[")) {
                if (ordinaryTranslationGlossEnd(line, start)) |end| {
                    pos = end;
                    continue;
                }
                const end = std.mem.indexOfAnyPos(u8, line, start + 1, "[]<>") orelse return null;
                if (line[end] != ']') return null;
                const content = line[start + 1 .. end];
                if (ordinaryLiteralBracket(content) or workerTranslationBracket(line, start, end)) {
                    pos = end + 1;
                    continue;
                }
                const space = std.mem.indexOfAny(u8, content, " \t") orelse content.len;
                const target = content[0..space];
                if ((!std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "http://") and
                    !std.mem.startsWith(u8, target, "//")) or !encoder.document_ir.validExternalUrl(target)) return null;
                pos = end + 1;
                continue;
            }
            var right = std.mem.indexOfAnyPos(u8, line, start + 2, "[]<>") orelse return null;
            if (catalog) |images| if (images.ordinary_captions) {
                const head = line[start + 2 .. right];
                const file_target = std.mem.trim(u8, head[0 .. std.mem.indexOfScalar(u8, head, '|') orelse head.len], " \t");
                if (ns.ofTitle(file_target).id == 6) {
                    // A v2 catalog recognizes exactly one bounded ordinary
                    // caption-link level. The entire outer file operand is
                    // subsequently classified; inner media/options cannot be
                    // hidden by advancing to an inner closing bracket.
                    const end = image_catalog.captionOperandEnd(line[start..]) orelse return null;
                    right = start + end - 2;
                }
            };
            if (!std.mem.startsWith(u8, line[right..], "]]")) {
                pos = workerDoubleExternalEnd(line, start, right) orelse return null;
                continue;
            }
            // The empty wikilink production emits the original four delimiters as text.
            // Both bracket pairs are verified here. Resume before any following operand.
            if (right == start + 2) {
                pos = right + 2;
                continue;
            }
            const body = line[start + 2 .. right];
            const target = std.mem.trim(u8, body[0 .. std.mem.indexOfScalar(u8, body, '|') orelse body.len], " \t");
            if (target.len == 0 or std.mem.indexOfAny(u8, target, "&%{}\x7f") != null) return null;
            for (target) |c| if (std.ascii.isControl(c)) return null;
            if (ns.ofTitle(target).id == 6) {
                for (recipe.media_operations) |op| {
                    if (!std.mem.eql(u8, op.operand, line[start .. right + 2])) continue;
                    if (op.media == .unsupported) return null;
                    if (op.media == .successful_audio_video) {
                        // Only an ordinary inline file operation can witness
                        // activation. Headings, table attributes, nested HTML
                        // and other link contexts can serialize the same bytes.
                        if (in_table or html_depth != 0 or line.len == 0 or
                            std.ascii.isWhitespace(line[0]) or std.mem.indexOfScalar(u8, "=|!;:#*", line[0]) != null or
                            std.mem.indexOfAny(u8, line[0..start], "[]<>") != null) return null;
                        audio = true;
                    }
                    // The optional thumbnail script contributes no sheet in
                    // either state under the authenticated normal module catalog.
                    break;
                } else {
                    const images = catalog orelse return null;
                    // This fallback only proves a static image cannot add TMH.
                    // Thumbnail script selection is independent and contributes
                    // no sheet in the authenticated normal module catalog.
                    if ((try images.classify(a, ns, line[start .. right + 2])) == null) {
                        const held = timed orelse return null;
                        // This exact byte offset and live ancestry belong to the
                        // same source-bound expansion as the page quota proof.
                        const absolute = @intFromPtr(line.ptr) - @intFromPtr(expanded.ptr) + start;
                        _ = held.proof.contribution(held.catalog, absolute, in_table, html_depth) orelse return null;
                        audio = true;
                    }
                }
            }
            pos = right + 2;
        }
    }
    if (html_depth != 0 or in_table) return null;
    if (early_reference_heading and headings < 4) return null;
    return .{ .toc = headings >= 4, .tmh = audio };
}

fn workerDocumentUrl(a: std.mem.Allocator, title: []const u8, revision: u64) ![]const u8 {
    const digits = "0123456789ABCDEF";
    var encoded: std.ArrayList(u8) = .empty;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) {
            try encoded.append(a, c);
        } else {
            try encoded.appendSlice(a, &.{ '%', digits[c >> 4], digits[c & 15] });
        }
    }
    return std.fmt.allocPrint(a, "https://it.wiktionary.org/w/index.php?title={s}&oldid={d}&useskin=vector-2022",
        .{ encoded.items, revision });
}

fn ordinaryPageScope(a: std.mem.Allocator, m: *const OrdinaryManifest, shared: *const S.DisclosureSharedProfile,
    input: Input, raw: []const u8, expanded: []const u8, issued: OrdinaryStyleReceipt) !?*const PC.ContainerDisclosureStyleScope
{
    const registry = m.local_registry.?;
    // A configured worker recipe cannot be downgraded to the legacy receipt
    // path by clearing both optional worker fields.
    if (m.worker_projection) |recipe| {
        if (issued.imports.len != 0 and (issued.worker_features == null or
            !workerLocalPlacementValid(recipe, expanded, issued.imports))) return null;
    }
    const global_bytes = input.shared.?.styles;
    const globals = if (issued.worker_features) |features| blk: {
        const recipe = m.worker_projection orelse return null;
        break :blk workerSlots(recipe, features) orelse return null;
    } else m.sheets;
    var base_index: usize = 0;
    if (issued.ordered.len < globals.len or issued.ordered.len > 32 or issued.placed_keys.len != issued.ordered.len or
        issued.raw.ptr != raw.ptr or issued.raw.len != raw.len or issued.expanded.ptr != expanded.ptr or
        issued.expanded.len != expanded.len or issued.imports.len > 4096 or
        !std.mem.eql(u8, &issued.module_selection_sha256, &(try digest(m.module_selection_sha256)))) return null;
    var slots_buf: [32]OrdinarySheet = undefined;
    const slots = slots_buf[0..issued.ordered.len];
    var global: usize = 0;
    var total: usize = 0;
    for (issued.ordered, issued.placed_keys, slots) |source, key, *slot| {
        if (source.css.len > 768 * 1024 - total) return null;
        total += source.css.len;
        if (key) |local_key| {
            // In the normal prefix rule all global HEAD sheets precede every
            // local BODY sheet, even when both have byte offset zero.
            if (m.worker_projection != null and global != globals.len) return null;
            if (source.unknown_applicability or source.byte_start != 0 or
                (global < globals.len and globals[global].byte_start != 0)) return null;
            for (registry.entries) |entry| {
                if (!std.mem.eql(u8, entry.dedup_key, local_key)) continue;
                const base = if (issued.worker_features != null) issued.document_base orelse return null else entry.url;
                if (!std.mem.eql(u8, entry.body, source.css) or !std.mem.eql(u8, base, source.base_url)) return null;
                slot.* = .{ .local_key = entry.dedup_key, .url = base, .sha256 = entry.sha256 };
                break;
            } else return null;
        } else {
            if (global == globals.len) return null;
            const wanted = globals[global];
            while (base_index < m.sheets.len and !sheetEqual(m.sheets[base_index], wanted)) base_index += 1;
            if (base_index == m.sheets.len or source.byte_start != wanted.byte_start or
                source.unknown_applicability != wanted.unknown_applicability or
                !std.mem.eql(u8, global_bytes[base_index].body, source.css) or
                !std.mem.eql(u8, wanted.url, source.base_url)) return null;
            base_index += 1;
            slot.* = wanted;
            global += 1;
        }
    }
    if (global != globals.len) return null;
    // matchesPlacement verifies order and count of first occurrences. Repeated
    // source imports remain in the independent lexical inventory.
    const plan: OrdinaryLocalPlan = .{ .registry = registry.entries, .slots = slots, .placement_sha256 = try digest(registry.placement_sha256) };
    if (!plan.matchesPlacement(raw, expanded, issued) or !ordinaryReceiptSource(m.calls, raw, expanded, issued.imports)) return null;
    const profile = try a.create(S.DisclosureSharedProfile);
    profile.* = shared.*;
    profile.owner_attribute_projection = if (m.owner_attributes) |*known| &known.projection else null;
    if (slots.len != globals.len or globals.len != global_bytes.len) {
        const styles = try a.create(S.Profile);
        styles.* = S.parseSourcesForTargetAlloc(a, issued.ordered, .screen) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        profile.styles = styles;
    }
    const resolved = (try S.prepareDisclosureConstructorTransfer(a, profile.styles, m.font, m.shell, profile.placement_shell.?)) orelse return null;
    profile.boundary.?.custom_environment = resolved.environment;
    const font = try a.create(S.DisclosureFontTransfer);
    font.* = resolved.font;
    if (m.inline_hit) |*hit| font.inline_hit = &hit.source;
    var scope = PC.ContainerDisclosureStyleScope.fromPageSourcesAndFont(expanded, profile, issued.ordered, font) orelse return null;
    scope.html_underline = m.underline;
    const result = try a.create(PC.ContainerDisclosureStyleScope);
    result.* = scope;
    return result;
}

const OrdinaryConstructor = struct {
    dynamic: ?*const OrdinaryManifest = null,
    local: ?OrdinaryLocalPlan,
    module_selection_sha256: [32]u8,
    family_scope: bool,
    font: ?S.DisclosureFontTransfer,
    calls: []const OrdinaryCall,
    underline: ?S.DisclosureHtmlUnderline,

    fn prepare(a: std.mem.Allocator, input: Input, shared: *S.DisclosureSharedProfile) !?OrdinaryConstructor {
        const selected = input.shared orelse return null;
        const expected = selected.reference.ordinary_manifest_sha256;
        const bytes = selected.ordinary_manifest orelse {
            if (expected != null) return error.InvalidContainerDisclosureInput;
            return null;
        };
        if (!try matches(bytes, expected orelse return error.InvalidContainerDisclosureInput) or
            shared.boundary == null or shared.placement_shell == null) return error.InvalidContainerDisclosureInput;
        const m = try std.json.parseFromSliceLeaky(OrdinaryManifest, a, bytes, .{});
        const dynamic = std.mem.eql(u8, m.schema, "normal-parser-output-registered-style-vector.v4");
        const local_scope = dynamic or std.mem.eql(u8, m.schema, "normal-parser-output-selected-templatestyles.v3");
        const family_scope = local_scope or std.mem.eql(u8, m.schema, "normal-parser-output-static-calls-no-local-styles.v2");
        if ((!family_scope and !std.mem.eql(u8, m.schema, "normal-parser-output-flat-calls-no-local-styles.v1")) or
            !std.mem.eql(u8, m.wiki, input.wiki) or !std.mem.eql(u8, m.dump_date, input.dump_date) or
            !std.mem.eql(u8, m.namespace_sha256, input.namespace_sha256) or
            !std.mem.eql(u8, m.parser_constructor_sha256, selected.reference.parser_constructor_sha256 orelse
                return error.InvalidContainerDisclosureInput) or
            !std.mem.eql(u8, m.initializer_sha256, selected.reference.initializer_sha256) or
            !std.mem.eql(u8, m.ua_basis_sha256, selected.reference.ua_basis_sha256) or
            m.calls.len > @as(usize, if (family_scope) 1024 else 256) or m.sheets.len == 0 or m.sheets.len != selected.styles.len or
            m.sheets.len != shared.styles.retained_sources.len) return error.InvalidContainerDisclosureInput;
        if (m.owner_attributes) |known| {
            if (!dynamic or !std.mem.eql(u8, known.schema, "normal-source-div-owner-attributes.v1") or
                !std.mem.eql(u8, known.parser_constructor_sha256, m.parser_constructor_sha256) or
                !std.mem.eql(u8, known.initializer_sha256, m.initializer_sha256) or
                known.projection.absent.len > 1) return error.InvalidContainerDisclosureInput;
            _ = try digest(known.source_sha256);
            // This constructor preserves source-absent hidden on the owner;
            // it can generate an ID. Source id absence is never DOM id absence.
            // Class order and unrelated metadata retain their uncertainty.
            for (known.projection.absent, 0..) |name, i| {
                if (!std.mem.eql(u8, name, "hidden"))
                    return error.InvalidContainerDisclosureInput;
                for (known.projection.absent[0..i]) |prior| if (std.mem.eql(u8, prior, name))
                    return error.InvalidContainerDisclosureInput;
            }
            if (known.projection.generated_id) |domain| {
                // The schema names the selected CounterType Base64URL
                // generator. A narrower alphabet or higher minimum could
                // incorrectly refute a possible generated ID such as mwAQ.
                if (!std.mem.eql(u8, domain.prefix, "mw") or
                    !std.mem.eql(u8, domain.suffix_alphabet,
                        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") or
                    domain.min_suffix_bytes != 2 or domain.max_suffix_bytes != 11)
                    return error.InvalidContainerDisclosureInput;
                // Reuse the selected constructor's existing generator/width
                // bound. This adds no wider deployment or integer-width claim.
                const prefix = m.font.section_id_prefix orelse return error.InvalidContainerDisclosureInput;
                const max_bytes = m.font.section_id_max_bytes orelse return error.InvalidContainerDisclosureInput;
                if (!std.mem.eql(u8, domain.prefix, prefix)) return error.InvalidContainerDisclosureInput;
                if (domain.prefix.len == 0 or domain.prefix.len > 32 or
                    domain.suffix_alphabet.len == 0 or domain.suffix_alphabet.len > 128 or
                    domain.min_suffix_bytes == 0 or domain.min_suffix_bytes > domain.max_suffix_bytes or
                    domain.max_suffix_bytes > 64 or domain.prefix.len + domain.max_suffix_bytes != max_bytes)
                    return error.InvalidContainerDisclosureInput;
                for (known.projection.absent) |name| if (std.mem.eql(u8, name, "id"))
                    return error.InvalidContainerDisclosureInput;
                for (domain.prefix) |byte| if (byte <= 0x20 or byte >= 0x7f)
                    return error.InvalidContainerDisclosureInput;
                for (domain.suffix_alphabet, 0..) |byte, i| if (byte <= 0x20 or byte >= 0x7f or
                    std.mem.indexOfScalar(u8, domain.suffix_alphabet[0..i], byte) != null)
                    return error.InvalidContainerDisclosureInput;
            }
        }
        const module_selection = try digest(m.module_selection_sha256);
        if (local_scope != (m.local_registry != null)) return error.InvalidContainerDisclosureInput;
        if (m.worker_projection) |w| {
            if (!dynamic or !(try workerProjectionValid(w, m))) return error.InvalidContainerDisclosureInput;
        }
        const local = if (m.local_registry) |registry| try OrdinaryLocalPlan.prepare(registry, m.sheets) else null;
        if (local == null or dynamic) for (m.sheets) |slot| {
            if (slot.local_key != null) return error.InvalidContainerDisclosureInput;
        };
        _ = try digest(m.root_font_and_faces_sha256);
        for (m.calls, 0..) |c, i| {
            if (!validOrdinaryCall(c.name)) return error.InvalidContainerDisclosureInput;
            for (m.calls[0..i]) |prior| if (std.mem.eql(u8, prior.name, c.name)) return error.InvalidContainerDisclosureInput;
        }
        for (m.sheets, shared.styles.retained_sources) |sheet, retained| {
            if (retained.unknown_applicability != sheet.unknown_applicability or retained.byte_start != sheet.byte_start or
                (!dynamic and (sheet.unknown_applicability or sheet.byte_start != 0)) or
                !std.mem.eql(u8, sheet.url, retained.base_url) or !try matches(retained.css, sheet.sha256))
                return error.InvalidContainerDisclosureInput;
        }
        for ([_][]const u8{ "data-mw-section-id", "id", "aria-labelledby", "about", "typeof",
            "data-mw", "data-parsoid", "data-x-id" }) |attr| {
            for (m.font.section_attributes) |possible| {
                if (std.mem.eql(u8, possible, attr)) break;
            } else return error.InvalidContainerDisclosureInput;
        }
        if (m.font.section_id_max_bytes) |n| if (n < 13) return error.InvalidContainerDisclosureInput;
        if (m.font.section_id_prefix) |pre| if (!std.mem.eql(u8, pre, "mw")) return error.InvalidContainerDisclosureInput;
        if (m.shell.path.len < 2 or m.shell.path.len > 64) return error.InvalidContainerDisclosureInput;
        if (selected.parser_output_direction) |dir| {
            const root = m.shell.path[m.shell.path.len - 1];
            const token = if (dir == .ltr) "ltr" else "rtl";
            const cls = if (dir == .ltr) "mw-content-ltr" else "mw-content-rtl";
            var fixed_dir = false;
            for (root.fixed_attributes) |attr| {
                if (std.ascii.eqlIgnoreCase(attr.name, "dir") and std.ascii.eqlIgnoreCase(attr.value, token)) fixed_dir = true;
            }
            if (!fixed_dir or !classToken(m.font.parser_classes, cls)) return error.InvalidContainerDisclosureInput;
        }
        if (m.underline) |preference| {
            const html = m.shell.path[0];
            var classes: []const u8 = "";
            for (html.fixed_attributes) |attr| {
                if (std.ascii.eqlIgnoreCase(attr.name, "class")) classes = attr.value;
            }
            for ([_][]const u8{ "skin-underline-clientpref-always", "skin-underline-clientpref-never" },
                [_]bool{ preference == .always, preference == .never }) |name, present| {
                if (classToken(classes, name) != present) return error.InvalidContainerDisclosureInput;
                if (!present) for (html.extra_class_prefixes) |prefix| {
                    if (std.mem.startsWith(u8, name, prefix)) return error.InvalidContainerDisclosureInput;
                };
            }
        }
        // Book.init still owns this unpublished profile. The parser/SECTION
        // cascade replaces any serialized boundary custom-property values.
        if (m.inline_hit) |hit| {
            if (!family_scope or !std.mem.eql(u8, hit.parser_constructor_sha256, m.parser_constructor_sha256) or
                !std.mem.eql(u8, hit.ua_basis_sha256, m.ua_basis_sha256) or
                !std.mem.eql(u8, hit.validation_sha256, selected.reference.validation_sha256) or
                !hit.source.valid()) return error.InvalidContainerDisclosureInput;
            _ = try digest(hit.source.observation_sha256);
        }
        const manifest = try a.create(OrdinaryManifest);
        manifest.* = m;
        if (dynamic) return .{ .local = local, .dynamic = manifest, .font = null, .family_scope = true,
            .module_selection_sha256 = module_selection, .calls = m.calls, .underline = m.underline };
        var transfer = (try S.prepareDisclosureConstructorTransfer(a, shared.styles, m.font, m.shell,
            shared.placement_shell.?)) orelse return error.InvalidContainerDisclosureInput;
        if (manifest.inline_hit) |*hit| transfer.font.inline_hit = &hit.source;
        shared.boundary.?.custom_environment = transfer.environment;
        return .{ .local = local, .module_selection_sha256 = module_selection, .family_scope = family_scope, .font = transfer.font, .calls = m.calls, .underline = m.underline };
    }

    fn bind(self: *const OrdinaryConstructor, a: std.mem.Allocator, shared: *const S.DisclosureSharedProfile,
        raw: []const u8, expanded: []const u8, receipt: ?OrdinaryStyleReceipt) !?*const PC.ContainerDisclosureStyleScope
    {
        const font = if (self.font) |*present| present else return null;
        if (font.styles != shared.styles) return null;
        if (self.local) |plan| {
            const issued = receipt orelse return null;
            if (!std.mem.eql(u8, &self.module_selection_sha256, &issued.module_selection_sha256) or
                !plan.matchesPlacement(raw, expanded, issued)) return null;
            if (!ordinaryReceiptSource(self.calls, raw, expanded, issued.imports)) return null;
            var selected = PC.ContainerDisclosureStyleScope.fromPageSourcesAndFont(expanded, shared,
                issued.ordered, font) orelse return null;
            selected.html_underline = self.underline;
            const result = try a.create(PC.ContainerDisclosureStyleScope);
            result.* = selected;
            return result;
        }
        if (receipt != null) return null;
        const selected = if (self.family_scope) ordinaryFamilySourceSelected(self.calls, raw, expanded)
            else ordinarySourceSelected(self.calls, raw, expanded);
        if (!selected) return null;
        const scope = try a.create(PC.ContainerDisclosureStyleScope);
        scope.* = .{ .source = expanded, .shared = shared, .selected_font = font, .html_underline = self.underline };
        return scope;
    }
};

pub const Book = struct {
    ordinary: ?OrdinaryConstructor = null,
    images: ?image_catalog.Catalog = null,
    timed: ?timed_media_inputs.Book = null,
    arena: std.heap.ArenaAllocator,
    input: Input,
    shared: ?*const encoder.table_style_profile.DisclosureSharedProfile = null,

    pub fn init(backing: std.mem.Allocator, bytes: []const u8, namespaces: *const namespace_registry.Registry) !Book {
        return initWithMediaSources(backing, bytes, namespaces, null);
    }

    pub fn initWithMediaSources(backing: std.mem.Allocator, bytes: []const u8,
        namespaces: *const namespace_registry.Registry, media: ?MediaSources) !Book
    {
        if (bytes.len == 0 or bytes.len > max_input) return error.InvalidContainerDisclosureInput;
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        // Always own strings: the mmap used by the loader closes on return.
        const input = try std.json.parseFromSliceLeaky(Input, arena.allocator(), bytes, .{ .allocate = .alloc_always });
        const finite = std.mem.eql(u8, input.schema, "wikidict.container-disclosure-captures.v1");
        const shared_version = std.mem.eql(u8, input.schema, "wikidict.container-disclosure-inputs.v2");
        if ((!finite and !shared_version) or (finite and input.shared != null) or
            (shared_version and input.shared == null) or
            !std.mem.eql(u8, input.wiki, namespaces.wiki) or
            !std.mem.eql(u8, input.dump_date, namespaces.dump_date) or
            !std.mem.eql(u8, &(try digest(input.namespace_sha256)), &namespaces.source_sha256) or
            (input.pages.len == 0 and input.shared == null) or input.pages.len > 4096) return error.InvalidContainerDisclosureInput;
        var count: usize = 0;
        for (input.pages, 0..) |page, i| {
            if (page.namespace_id != 0 or page.title.len == 0 or page.title.len > 4096 or
                !std.unicode.utf8ValidateSlice(page.title) or page.page_id == 0 or page.revision_id == 0 or
                page.captures.len == 0 or page.captures.len > 64) return error.InvalidContainerDisclosureInput;
            for (page.title) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidContainerDisclosureInput;
            for (input.pages[0..i]) |previous| {
                if (previous.page_id == page.page_id or
                    (previous.namespace_id == page.namespace_id and std.mem.eql(u8, previous.title, page.title)))
                    return error.InvalidContainerDisclosureInput;
            }
            _ = try digest(page.raw_sha256);
            _ = try digest(page.expanded_sha256);
            count += page.captures.len;
            if (count > 4096) return error.InvalidContainerDisclosureInput;
            var previous_end: usize = 0;
            for (page.captures, 0..) |capture, at| {
                if (capture.owner_start >= capture.content_start or capture.content_start >= capture.content_end or
                    capture.content_end >= capture.owner_end or (at != 0 and capture.owner_start < previous_end) or
                    !T.validContainerDisclosure(capture.policy) or capture.policy.button == null or capture.policy.direction == null)
                    return error.InvalidContainerDisclosureInput;
                previous_end = capture.owner_end;
                _ = try digest(capture.owner_sha256);
                const reference = capture.reference;
                if (reference.full_page_cascade_qualified or reference.historical_deployment_qualified)
                    return error.InvalidContainerDisclosureInput;
                if (std.mem.eql(u8, reference.scope, "normal_current_initialized_component")) {
                    const labels = capture.source_labels orelse return error.InvalidContainerDisclosureInput;
                    if (!labels.matchesPolicy(capture.policy)) return error.InvalidContainerDisclosureInput;
                } else if (!std.mem.eql(u8, reference.scope, "controlled_component_current_initializer_css") or
                    capture.source_labels != null) return error.InvalidContainerDisclosureInput;
                _ = try digest(reference.observed_html_sha256);
                _ = try digest(reference.actual_reference_sha256);
                _ = try digest(reference.capture_binding_sha256);
            }
        }
        const shared = if (input.shared) |value| try sharedProfile(arena.allocator(), backing, value) else null;
        errdefer if (shared) |profile| @constCast(profile.styles).deinit();
        const ordinary = if (shared) |profile| try OrdinaryConstructor.prepare(arena.allocator(), input, profile) else null;
        const images: ?image_catalog.Catalog = images: {
            const ref = if (ordinary) |o| if (o.dynamic) |m| if (m.worker_projection) |w| w.image_catalog else null else null else null;
            if (ref == null and media == null) break :images null;
            if (ref == null or media == null) return error.InvalidContainerDisclosureInput;
            const catalog = try image_catalog.Catalog.prepare(arena.allocator(), backing, ref.?, media.?, namespaces);
            // Overlapping exact evidence must agree; exceptional operands that
            // the generic grammar refuses still use their original exact proof.
            for (ordinary.?.dynamic.?.worker_projection.?.media_operations) |op| {
                if (try catalog.classify(arena.allocator(), namespaces, op.operand)) |effect| {
                    if (op.media != .image or op.thumbnail != effect.thumbnail)
                        return error.InvalidContainerDisclosureInput;
                }
            }
            break :images catalog;
        };
        const timed: ?timed_media_inputs.Book = timed: {
            const m = if (ordinary) |o| o.dynamic orelse break :timed null else break :timed null;
            const w = m.worker_projection orelse break :timed null;
            const ref = w.timed_media orelse break :timed null;
            const source = media orelse return error.InvalidContainerDisclosureInput;
            break :timed try timed_media_inputs.Book.prepare(arena.allocator(), ref, source.file_metadata,
                namespaces.source_sha256, try digest(m.module_selection_sha256));
        };
        return .{ .arena = arena, .input = input, .shared = shared, .ordinary = ordinary, .images = images, .timed = timed };
    }

    pub fn deinit(self: *Book) void {
        if (self.shared) |shared| @constCast(shared.styles).deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn bind(self: *const Book, a: std.mem.Allocator, namespace_id: i32, language_record: bool,
        alias: bool, title: []const u8, page_id: u64, revision_id: u64, raw: []const u8, expanded: []const u8) !?*const PC.ContainerDisclosureSource
    {
        return self.bindWithStyleReceipt(a, namespace_id, language_record, alias, title, page_id, revision_id, raw, expanded, null);
    }

    pub fn workerEffectProfile(self: *const Book, namespace_id: u32, language_record: bool, alias: bool,
        title: []const u8, page_id: u64) ?[32]u8
    {
        if (namespace_id != 0 or !language_record or alias) return null;
        for (self.input.pages) |page| if (page.page_id == page_id or std.mem.eql(u8, page.title, title)) return null;
        const constructor = self.ordinary orelse return null;
        const m = constructor.dynamic orelse return null;
        if (m.worker_projection == null) return null;
        return digest(self.input.shared.?.reference.ordinary_manifest_sha256.?) catch null;
    }

    pub fn styleReceiptFromExpansion(self: *const Book, a: std.mem.Allocator, ordinal: u64,
        id: P.PageIdentity, title: []const u8, raw: []const u8, expanded: []const u8, display: []const u8,
        unsupported: bool, payload: ?P.BoundPageEffects, namespaces: ?*const namespace_registry.Registry) !?OrdinaryStyleReceipt
    {
        const data = payload orelse return null;
        const ns = namespaces orelse return null;
        const profile = self.workerEffectProfile(id.namespace, true, false, title, id.page_id) orelse return null;
        if (unsupported or data.collector.len == 0 or data.collector.len > P.max_page_effect_bytes or
            !std.mem.eql(u8, &ns.source_sha256, &(try digest(self.input.namespace_sha256))) or
            !std.mem.eql(u8, &data.binding, &P.pageEffectBinding(profile, ordinal, id, title, raw, expanded, data.collector))) return null;
        const phase = std.json.parseFromSliceLeaky(WorkerPhase, a, data.collector, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (!std.mem.eql(u8, phase.schema, "wikidict.page-effects.v1") or !std.mem.eql(u8, phase.status, "complete") or
            !std.mem.eql(u8, phase.collector, "native-executed-extensions.v1") or phase.generation != ordinal or
            phase.identity.namespace != 0 or phase.identity.page_id != id.page_id or phase.identity.revision_id != id.revision_id or
            !std.mem.eql(u8, phase.identity.title, title) or !(matches(raw, phase.source_sha256) catch false) or
            !(matches(expanded, phase.expanded_sha256) catch false) or !(matches(display, phase.display_title_sha256) catch false)) return null;
        const m = self.ordinary.?.dynamic.?;
        const w = m.worker_projection.?;
        if (!ordinaryBoundedSource(&.{}, raw, expanded)) return null;
        const registry = m.local_registry.?;
        const imports = (try workerStyleImports(a, expanded, registry)) orelse return null;
        if (!workerOperationsMatch(phase, imports, registry) or !ordinaryReceiptSource(m.calls, raw, expanded, imports)) return null;
        for ([_][]const u8{ title, raw, expanded, display }) |source| if (!try workerTriggerFree(a, source)) return null;
        if (!workerLocalPlacementValid(w, expanded, imports)) return null;
        const timed = if (self.timed) |*media| try media.forPage(a,
            .{ .title = title, .page_id = id.page_id, .revision_id = id.revision_id }, raw, expanded) else null;
        const features = (try workerFeaturesWithTimed(a, expanded, ns, w,
            if (self.images) |*images| images else null, timed)) orelse return null;
        const globals = workerSlots(w, features) orelse return null;
        const url = if (imports.len != 0) try workerDocumentUrl(a, title, id.revision_id) else null;
        var ordered: std.ArrayList(S.Source) = .empty;
        var keys: std.ArrayList(?[]const u8) = .empty;
        var i: usize = 0;
        for (globals) |slot| {
            while (i < m.sheets.len and !sheetEqual(m.sheets[i], slot)) i += 1;
            if (i == m.sheets.len) return null;
            const bytes = self.input.shared.?.styles[i];
            try ordered.append(a, .{ .css = bytes.body, .base_url = slot.url, .byte_start = slot.byte_start,
                .unknown_applicability = slot.unknown_applicability });
            try keys.append(a, null);
            i += 1;
        }
        var used: [32]bool = @splat(false);
        for (imports) |op| {
            if (w.placement_source_sha256 == null) return null;
            for (registry.entries, 0..) |entry, k| {
                if (!std.mem.eql(u8, op.src, entry.src)) continue;
                if (!used[k]) {
                    if (keys.items.len == 32 or !try workerTriggerFree(a, entry.body)) return null;
                    try ordered.append(a, .{ .css = entry.body, .base_url = url.? });
                    try keys.append(a, entry.dedup_key);
                    used[k] = true;
                }
                break;
            } else return null;
        }
        return .{ .raw = raw, .expanded = expanded, .imports = imports, .ordered = ordered.items, .placed_keys = keys.items,
            .module_selection_sha256 = self.ordinary.?.module_selection_sha256, .placement_sha256 = try digest(registry.placement_sha256),
            .worker_features = features, .document_base = url };
    }

    pub fn bindWithStyleReceipt(self: *const Book, a: std.mem.Allocator, namespace_id: i32, language_record: bool,
        alias: bool, title: []const u8, page_id: u64, revision_id: u64, raw: []const u8, expanded: []const u8,
        receipt: ?OrdinaryStyleReceipt) !?*const PC.ContainerDisclosureSource
    {
        for (self.input.pages) |page| {
            // A different page has no capture. A partial identity match is a
            // stale/crossed input and fails instead of silently borrowing it.
            const same_title = namespace_id == page.namespace_id and std.mem.eql(u8, title, page.title);
            if (!same_title and page_id != page.page_id) continue;
            if (!same_title or page_id != page.page_id or revision_id != page.revision_id or !language_record or alias or
                !try matches(raw, page.raw_sha256) or !try matches(expanded, page.expanded_sha256))
                return error.InvalidContainerDisclosureInput;
            for (page.captures) |capture| {
                if (capture.owner_end > expanded.len or
                    !try matches(expanded[capture.owner_start..capture.owner_end], capture.owner_sha256))
                    return error.InvalidContainerDisclosureInput;
            }
            const rows = try a.alloc(PC.ContainerDisclosureCapture, page.captures.len);
            for (rows, page.captures) |*row, capture| row.* = .{
                .owner_start = capture.owner_start, .owner_end = capture.owner_end,
                .content_start = capture.content_start, .content_end = capture.content_end,
                .policy = capture.policy, .source_labels = capture.source_labels,
            };
            const held = try a.create(PC.ContainerDisclosureSource);
            held.* = .{ .source = expanded, .captures = rows, .shared_profile = self.shared, .parser_output_direction = if (self.input.shared) |shared| shared.parser_output_direction else null };
            return held;
        }
        if (self.shared) |shared| {
            if (namespace_id != 0 or !language_record or alias) return null;
            if (title.len == 0 or title.len > 4096 or !std.unicode.utf8ValidateSlice(title) or
                page_id == 0 or revision_id == 0 or raw.len == 0 or expanded.len == 0)
                return error.InvalidContainerDisclosureInput;
            for (title) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidContainerDisclosureInput;
            const held = try a.create(PC.ContainerDisclosureSource);
            const scope = if (self.ordinary) |*ordinary| blk: {
                if (receipt) |issued| {
                    if (issued.document_base) |url| {
                        if (issued.worker_features == null or issued.imports.len == 0 or
                            !std.mem.eql(u8, url, try workerDocumentUrl(a, title, revision_id))) break :blk null;
                    } else if (issued.worker_features != null and issued.imports.len != 0) break :blk null;
                }
                if (ordinary.dynamic) |manifest| break :blk if (receipt) |issued|
                    try ordinaryPageScope(a, manifest, shared, self.input, raw, expanded, issued) else null;
                break :blk try ordinary.bind(a, shared, raw, expanded, receipt);
            } else null;
            held.* = .{ .source = expanded, .captures = &.{}, .page_style_scope = scope, .shared_profile = if (scope) |selected| selected.shared else shared, .parser_output_direction = self.input.shared.?.parser_output_direction };
            return held;
        }
        return null;
    }
};

test "IT qualified optional table refuses an indented wiki-table close through HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespace_registry.Registry.init(a, @embedFile("testdata/it-per/namespace-registry.tsv"));
    defer ns.deinit();
    const recipe: WorkerProjection = .{ .schema = "test-direct-feature-observation",
        .catalog_sha256 = "", .feature_source_sha256 = "", .toc_on = &.{} };
    const source = "{|\n|-\n|\n<table><tr><td>v\n |}\n</table>\n|}\n";
    try std.testing.expect(ordinaryLiteralHtml(source, &.{}));
    if ((try workerFeatures(a, source, &ns, recipe, null)) != null)
        return error.IndentedWikiTableCloseCrossesHtml;
}

test "IT family09 authentic image captions and explicit-width bare upright stay bounded" {
    const C = image_catalog;
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespace_registry.Registry.init(a, @embedFile("testdata/it-per/namespace-registry.tsv"));
    defer ns.deinit();
    const map = @embedFile("testdata/it-consistente/interwiki-map.tsv");
    try ns.attachInterwikiMap(map);

    // Exact provider rows for the retained lilla146, gatto171 and marrone139 operands.
    const catalog =
        "# wikidict-image-effect-catalog-v1\n" ++
        "File:600px Lilla.png\tFile:600px Lilla.png\t0903da311cb5794cdcc4800438102b7e8edb88a5\t2007-07-20T00:19:15Z\tBITMAP\timage/png\n" ++
        "File:Color icon brown v2.svg\tFile:Color icon brown v2.svg\t8b55ce1175733335ceae700bb86a5d40b1cd7941\t2011-12-14T10:46:42Z\tDRAWING\timage/svg+xml\n" ++
        "File:Felis catus-cat on snow.jpg\tFile:Felis catus-cat on snow.jpg\t0a40637f60dc79f0c3aa67bcbd2ee28cdb3b08b9\t2019-09-20T09:32:16Z\tBITMAP\timage/jpeg\n";
    const metadata =
        "# wikidict-file-metadata-v2\n" ++
        "File:600px Lilla.png\t1\t600\t400\tBITMAP\tFile:600px Lilla.png\n" ++
        "File:Color icon brown v2.svg\t1\t300\t300\tDRAWING\tFile:Color icon brown v2.svg\n" ++
        "File:Felis catus-cat on snow.jpg\t1\t3000\t2000\tBITMAP\tFile:Felis catus-cat on snow.jpg\n";
    const images = try C.Catalog.prepare(a, backing, .{
        .schema = "normal-it-image-effect-catalog.v1",
        .grammar = "normal-image-options-interwiki-caption.v3",
        .sha256 = "6451a345aafd5f629d6c2ec578533c467cd05a9003d11dac7a5e01159ca62dce",
        .bytes = 444,
        .count = 3,
        .namespace_sha256 = "8fc73407a5f932ba725c3339034fc0aa9894078272b08a5ae62566a834496996",
        .image_options_sha256 = "0aec7cd928857fe992b82159729d831fb5331f881d315938c681d1447f4392d3",
        .behavior_switches_sha256 = "56b1d23731c2cde8818d283358112b315bf890c759f0b55913b812622880ab91",
        .file_metadata_sha256 = "6db64ca0a82ea6d489c87f23bb4014153f862b860a0a8915f9a050da9178029d",
        .source_manifest_sha256 = "11519fc9b67f02d9ade57af9d2bd8ed14aa835320a88d21ba2d3b10d274dff30",
        .raw_sha256 = "ba4ec09d3d6cd12bde955bf8045ff39f762358f9eac5daef3a1b77aee010583b",
        .projection_sha256 = "64e99fe780b50a0ba5c747f6207da6c68a466d8d9745cc2e16f1d7fad9710dc4",
        .source_proof_sha256 = "23e072723f3dcedd2cbd4eb5293424da728ef4ab39566ef8bdbc9c5bd096471b",
        .feature_source_sha256 = "377b07f6dfa2a01e0724e12b243ad35b7c1891d0611d3191743be6cafb8bdb98",
        .module_selection_sha256 = "cdbdd6437688c1a305af6d41ce960f15c6ff587435beda9538851b62c046324a",
        .interwiki_sha256 = "f265f5cbc69400a9cf489eb5a3fb1fa62758c981801916911e4f20dbb85ecfdd",
    }, .{
        .catalog = catalog,
        .file_metadata = metadata,
        .image_options = @embedFile("testdata/it-per/image-options.tsv"),
        .behavior_switches = @embedFile("testdata/it-per/behavior-switches.tsv"),
        .interwiki_map = map,
    }, &ns);

    for ([_][]const u8{
        "[[File:600px Lilla.png|thumb| il colore '''lilla'''<small></small>]]",
        "[[File:Felis catus-cat on snow.jpg|180px|thumb|[1] un gatto [[domestico]] ([[w:Felis silvestris catus|Felis silvestris catus]]) sulla [[neve]]]]",
        "[[File:Color icon brown v2.svg|thumb|200px|upright|un [[quadrato]] [[suddiviso]] in [[nove]] parti [[raffigurante]] varie  gradazioni di '''marrone'''<small></small>]]",
        "[[File:Color icon brown v2.svg|verticale|thumb|200px|colore]]",
    }) |operand| {
        const extent = try std.mem.concat(a, u8, &.{ operand, " seguito" });
        try std.testing.expectEqual(@as(?usize, operand.len), C.captionOperandEnd(extent));
        const effect = (try images.classify(a, &ns, operand)) orelse return error.AuthenticThumbnailRefused;
        try std.testing.expect(effect.thumbnail);
    }

    const cat = "[[File:Felis catus-cat on snow.jpg|180px|thumb|";
    for ([_][]const u8{
        cat ++ "[1234] un gatto]]",
        cat ++ "[1]un gatto]]",
        cat ++ "un gatto [1] sulla neve]]",
        cat ++ "[[gatto|[1] un animale]]]]",
        "[[File:600px Lilla.png|thumb|il colore '''lilla'''<small class=\"x\"></small>]]",
        "[[File:600px Lilla.png|thumb|il colore '''lilla'''<small>testo</small>]]",
    }) |bad| try std.testing.expectEqual(@as(?usize, null), C.captionOperandEnd(bad));
    const dot = cat ++ "[1] un gatto [[w:..|dot]]]]";
    try std.testing.expectEqual(@as(?usize, dot.len), C.captionOperandEnd(dot));
    try std.testing.expect((try images.classify(a, &ns, dot)) == null);

    const brown = "[[File:Color icon brown v2.svg|";
    for ([_][]const u8{
        brown ++ "thumb|upright|colore]]",
        brown ++ "200px|upright|colore]]",
        brown ++ "frame|200px|upright|colore]]",
        brown ++ "thumb|200x100px|upright|colore]]",
        brown ++ "thumb|x200px|upright|colore]]",
        brown ++ "thumb|200px|upright=0.75|colore]]",
        brown ++ "thumb|200px|upright|verticale|colore]]",
        brown ++ "thumb|200px|180px|upright|colore]]",
    }) |bad| try std.testing.expect((try images.classify(a, &ns, bad)) == null);
}

test "IT family09 inglese readings keep closed bracket boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespace_registry.Registry.init(a, @embedFile("testdata/it-per/namespace-registry.tsv"));
    defer ns.deinit();
    const recipe: WorkerProjection = .{
        .schema = "test-direct-feature-observation",
        .catalog_sha256 = "",
        .feature_source_sha256 = "",
        .toc_on = &.{},
    };
    // Three complete expansion lines from inglese160, revision 4251752.
    for ([_][]const u8{
        ":*[[cinese]]:  [[英國]]([[的]]) <small>([[cinese tradizionale|t.]])</small> / [[英国]]([[的]]) <small>([[cinese semplificato|s.]])</small> (Yīngguó [de])",
        ":*[[coreano]]:  [[영국의]] [英國-] (yeongguk-eui, yeonggugi)",
        ":*[[coreano]]:  [[영어]] [英語]] (yeong-eo)",
    }) |line| {
        const features = (try workerFeatures(a, line, &ns, recipe, null)) orelse return error.AuthenticReadingRefused;
        try std.testing.expect(!features.toc and !features.tmh);
    }
    for ([_][]const u8{
        ":*[[cinese]]: (Yīngguó [DE])",
        ":*[[cinese]]: (Yīngguó [de] extra)",
        "[[coreano]]: [[영국의]] [英國-] (yeongguk-eui)",
        ":*[[coreano]]: [[영어]] [ABC]] (yeong-eo)",
    }) |line| try std.testing.expect((try workerFeatures(a, line, &ns, recipe, null)) == null);
}

test "IT family09 viola IPA styles keep marker detection on its valid boundaries" {
    // Two complete pronunciation lines from viola145, revision 4064877.
    const source = @embedFile("testdata/it-per/family09-viola-pronunciation.wikitext");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var legacy_state: usize = 0;
        try std.testing.expect(ordinaryPinMatch(line, &legacy_state));
        try std.testing.expectEqual(@as(?bool, true), ordinaryPinStyledListLine(line));
        try std.testing.expect(ordinaryPinHeaderAbsent(line));
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(ordinaryPinHeaderAbsent(source));

    const contiguous = "* <span class=\"IPA\" style=\"font-family:VECTOR-PINNABLE-HEADER;\">/a/</span>";
    const literal_class = "* <span class=\"VeCtOr-pinnable-header\" style=\"font-family:Arial;\">/a/</span>";
    const split_class = "* <span class=\"vector-pin\" style=\"font-family:Arial;\">/a/</span>" ++
        " <span class=\"nable-header\" style=\"font-family:Arial;\">/b/</span>";
    for ([_][]const u8{ contiguous, literal_class, split_class }) |line| {
        try std.testing.expectEqual(@as(?bool, false), ordinaryPinStyledListLine(line));
        try std.testing.expect(!ordinaryPinHeaderAbsent(line));
    }

    const joined = "* <span class=\"vector-pin<!-- gap -->nable-header\" style=\"font-family:Arial;\">/a/</span>";
    const encoded = "* <span class=\"vector&#45;pinnable-header\" style=\"font-family:Arial;\">/a/</span>";
    const unclosed = "* <span class=\"IPA\" style=\"font-family:Arial;\">/a/";
    for ([_][]const u8{ joined, encoded, unclosed }) |line|
        try std.testing.expectEqual(@as(?bool, null), ordinaryPinStyledListLine(line));
    try std.testing.expect(!ordinaryPinHeaderAbsent(joined));
    try std.testing.expect(!ordinaryPinHeaderAbsent(encoded));
}
