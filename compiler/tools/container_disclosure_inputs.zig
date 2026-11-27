//! Build-only, edition-local capture inputs. This checks the identity and
//! custody of an explicit observation; it does not infer an initializer or CSS
//! policy from a title, class, missing field, or equal text on another page.
const std = @import("std");
const encoder = @import("encoder");
const namespace_registry = @import("namespace_registry");
const T = encoder.presentation_types;
const PC = encoder.presentation_compile;

pub const filename = "container-disclosure-captures.json";
pub const max_input = 1024 * 1024;
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
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != ' ' and c != '_') return false;
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
        if ((value.len != 4 and value.len != 7) or value[0] != '#') return false;
        for (value[1..]) |c| if (!std.ascii.isHex(c)) return false;
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

fn ordinaryLiteralHtml(source: []const u8, imports: []const OrdinaryStyleImport) bool {
    var consumed: usize = 0;
    var open: [64][]const u8 = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, source, pos, "<>")) |start| {
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
            if (depth == 0 or !tag.is(open[depth - 1]) or tag.attrs.len != 0 or source[tag.end - 2] == '/') return false;
            depth -= 1;
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
fn ordinaryLineOperands(line: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfAnyPos(u8, line, cursor, "[]<>")) |i| {
        switch (line[i]) {
            '<' => {
                const tag = encoder.wikitext_syntax.tagAt(line, i) orelse return false;
                if (std.mem.indexOfAny(u8, tag.attrs, "[]") != null) return false;
                cursor = tag.end;
            },
            '[' => {
                const double = std.mem.startsWith(u8, line[i..], "[[");
                const start = i + @as(usize, if (double) 2 else 1);
                const close = std.mem.indexOfAnyPos(u8, line, start, "[]<>") orelse return false;
                if (line[close] != ']' or (double and !std.mem.startsWith(u8, line[close..], "]]"))) return false;
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

fn ordinaryPinHeaderAbsent(expanded: []const u8) bool {
    if (std.mem.indexOf(u8, expanded, "-{") != null) return false;
    var lines = std.mem.splitScalar(u8, expanded, '\n');
    var matched: usize = 0;
    var joined_suffix = false;
    while (lines.next()) |line| {
        if (!joined_suffix) {
            matched = 0;
            joined_suffix = !ordinaryLineOperands(line);
        }
        // A subsequence covers token flattening that drops source bytes. Feed
        // both spellings of references, so mixed literal/decoded paths are covered.
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, cursor, '&')) |amp| {
            if (ordinaryPinMatch(line[cursor..amp], &matched)) return false;
            // An alphanumeric query key followed by '=' cannot be a character
            // reference in the maintained single-pass decoder. Keep every
            // literal byte in the marker observation; do not swallow a later
            // ampersand or relax unknown/numeric reference handling.
            var key_end = amp + 1;
            while (key_end < line.len and std.ascii.isAlphanumeric(line[key_end])) : (key_end += 1) {}
            if (key_end > amp + 1 and key_end < line.len and line[key_end] == '=') {
                if (ordinaryPinMatch(line[amp .. key_end + 1], &matched)) return false;
                cursor = key_end + 1;
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

fn ordinaryStaticCalls(raw: []const u8, depth: usize, visitor: anytype) bool {
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, raw, pos, "{}")) |start| {
        if (depth == 16 or !std.mem.startsWith(u8, raw[start..], "{{") or std.mem.startsWith(u8, raw[start..], "{{{")) return false;
        const pair = encoder.wikitext_syntax.balanced(raw, start) orelse return false;
        const body = raw[start + 2 .. pair.inner_end];
        const bar = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const name = std.mem.trim(u8, body[0..bar], " \t\r\n");
        if (!validOrdinaryCall(name)) return false;
        if (!visitor.visit(OrdinarySourceCall{ .name = name, .source = raw[start..pair.end], .depth = depth })) return false;
        if (bar < body.len and !ordinaryStaticCalls(body[bar + 1 ..], depth + 1, visitor)) return false;
        pos = pair.end;
    }
    return true;
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
        std.mem.indexOf(u8, expanded, "}}") != null or !ordinaryLiteralHtml(raw, &.{}) or !ordinaryLiteralHtml(expanded, imports)) return false;
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
fn workerFeatures(expanded: []const u8, ns: *const namespace_registry.Registry, recipe: WorkerProjection) ?WorkerFeatures {
    var html_depth: usize = 0;
    var in_table = false;
    var table_outer_depth: ?usize = null;
    var headings: usize = 0;
    var audio = false;
    var lines = std.mem.splitScalar(u8, expanded, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "{|")) {
            if (in_table) return null;
            in_table = true;
            table_outer_depth = html_depth;
        } else if (std.mem.startsWith(u8, line, "|}")) {
            if (!in_table) return null;
            in_table = false;
            if (line.len != 2) {
                if (table_outer_depth != html_depth) return null;
                html_depth = workerTableTailDepth(line[2..], html_depth) orelse return null;
                continue;
            }
        } else if (line.len != 0 and line[0] == '=') {
            var left: usize = 0;
            while (left < line.len and line[left] == '=') left += 1;
            var end = line.len;
            while (end > left and line[end - 1] == '=') end -= 1;
            if (left > 6 or end == left or line.len - end != left or in_table) return null;
            if (html_depth == 0) {
                headings += 1;
            } else if (headings < 4) {
                return null;
            }
            // Once four root headings establish TOC-on, a heading in an HTML
            // wrapper cannot change that choice. Scan its links as usual.
        }
        var pos: usize = 0;
        while (std.mem.indexOfAnyPos(u8, line, pos, "<[]")) |start| {
            if (line[start] == '<') {
                const tag = encoder.wikitext_syntax.tagAt(line, start) orelse return null;
                if (tag.is("br")) {
                    if (tag.closing and !std.ascii.eqlIgnoreCase(line[start..tag.end], "</br>")) return null;
                } else if (tag.closing) {
                    if (html_depth == 0) return null;
                    if (in_table and table_outer_depth == html_depth) table_outer_depth = null;
                    html_depth -= 1;
                } else if (!tag.self_closing) html_depth += 1;
                pos = tag.end;
                continue;
            }
            if (line[start] == ']') return null;
            if (!std.mem.startsWith(u8, line[start..], "[[")) {
                const end = std.mem.indexOfAnyPos(u8, line, start + 1, "[]<>") orelse return null;
                if (line[end] != ']') return null;
                const content = line[start + 1 .. end];
                const space = std.mem.indexOfAny(u8, content, " \t") orelse content.len;
                const target = content[0..space];
                if ((!std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "http://") and
                    !std.mem.startsWith(u8, target, "//")) or !encoder.document_ir.validExternalUrl(target)) return null;
                pos = end + 1;
                continue;
            }
            const right = std.mem.indexOfAnyPos(u8, line, start + 2, "[]<>") orelse return null;
            if (!std.mem.startsWith(u8, line[right..], "]]")) {
                pos = workerDoubleExternalEnd(line, start, right) orelse return null;
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
                } else return null;
            }
            pos = right + 2;
        }
    }
    if (html_depth != 0 or in_table) return null;
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
    arena: std.heap.ArenaAllocator,
    input: Input,
    shared: ?*const encoder.table_style_profile.DisclosureSharedProfile = null,

    pub fn init(backing: std.mem.Allocator, bytes: []const u8, namespaces: *const namespace_registry.Registry) !Book {
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
        return .{ .arena = arena, .input = input, .shared = shared, .ordinary = ordinary };
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
        const features = workerFeatures(expanded, ns, w) orelse return null;
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
