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
    // Finite, independently initialized component captures on one exact
    // revision. This mode additionally requires the original EOF tree proof.
    translation_eof: bool = false,
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
    gallery: ?GalleryProjection = null,
    cite: ?CiteAssets = null,
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

const OrdinaryLiteralAngleRecord = struct {
    title: []const u8, page_id: u64, revision_id: u64,
    raw_sha256: []const u8, expanded_sha256: []const u8,
    raw_start: usize, expanded_start: usize, paragraph_bytes: usize,
    siteinfo_sha256: []const u8, siteinfo_json: []const u8,
    normal_sha256: []const u8, normal_json: []const u8,
};
const OrdinaryLiteralAngles = struct {
    schema: []const u8,
    parser_source_sha256: []const u8,
    sanitizer_source_sha256: []const u8,
    records: []const OrdinaryLiteralAngleRecord,
};
const LiteralAngleEvidence = struct {
    token: []const u8,
    origin: enum { extension_call, literal_input, preprocess_result, expanded_output, display_title },
};
fn literalJsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
fn literalJsonNumber(value: std.json.Value, key: []const u8) ?u64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .integer and field.integer > 0) @intCast(field.integer) else null;
}
fn literalResponseRoot(a: std.mem.Allocator, bytes: []const u8, expected: []const u8) !?std.json.Value {
    if (bytes.len == 0 or bytes.len > 448 * 1024 or !(matches(bytes, expected) catch false)) return null;
    const result = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (result != .object or result.object.contains("error") or result.object.contains("warnings") or
        result.object.contains("continue")) return null;
    return result;
}
fn literalHtmlParagraphCount(html: []const u8, forms: []const []const u8) ?usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, cursor, '<')) |at| {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            const close = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return null;
            cursor = close + 3; continue;
        }
        var name_start = at + 1;
        if (name_start < html.len and html[name_start] == '/') name_start += 1;
        var name_end = name_start;
        while (name_end < html.len and (std.ascii.isAlphanumeric(html[name_end]) or html[name_end] == '-')) : (name_end += 1) {}
        if (name_end == name_start or !std.ascii.isAlphabetic(html[name_start]) or name_end == html.len or
            (!std.ascii.isWhitespace(html[name_end]) and html[name_end] != '/' and html[name_end] != '>')) return null;
        const name = html[name_start..name_end];
        for ([_][]const u8{"script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript", "template"}) |inert|
            if (std.ascii.eqlIgnoreCase(name, inert)) return null;
        var end = name_end;
        var quote: u8 = 0;
        while (end < html.len) : (end += 1) {
            if (quote != 0) { if (html[end] == quote) quote = 0; continue; }
            if (html[end] == '"' or html[end] == '\'') { quote = html[end]; continue; }
            if (html[end] == '<') return null;
            if (html[end] == '>') break;
        }
        if (end == html.len or quote != 0) return null;
        var matched = false;
        if (std.mem.eql(u8, html[at .. end + 1], "<p>")) {
            for (forms) |form| if (std.mem.startsWith(u8, html[at..], form)) {
                count += 1;
                cursor = at + form.len;
                matched = true;
                break;
            };
        }
        if (!matched) cursor = end + 1;
    }
    return count;
}
fn literalApiTagName(value: std.json.Value) ?[]const u8 {
    if (value != .string or value.string.len < 3 or value.string.len > 130 or
        value.string[0] != '<' or value.string[value.string.len - 1] != '>') return null;
    const name = value.string[1 .. value.string.len - 1];
    if (name[0] < 'a' or name[0] > 'z') return null;
    for (name[1..]) |byte| if ((byte < 'a' or byte > 'z') and !std.ascii.isDigit(byte) and byte != '-') return null;
    return name;
}
fn literalAngleRecordValid(a: std.mem.Allocator, record: OrdinaryLiteralAngleRecord) !bool {
    if (record.title.len == 0 or record.title.len > 4096 or record.page_id == 0 or record.revision_id == 0 or
        record.paragraph_bytes == 0 or record.paragraph_bytes > 65536) return false;
    _ = digest(record.expanded_sha256) catch return false;
    const site = (try literalResponseRoot(a, record.siteinfo_json, record.siteinfo_sha256)) orelse return false;
    const complete = site.object.get("batchcomplete") orelse return false;
    if (complete != .bool or !complete.bool) return false;
    const query = site.object.get("query") orelse return false;
    if (query != .object) return false;
    const general = query.object.get("general") orelse return false;
    if (!std.mem.eql(u8, literalJsonString(general, "wikiid") orelse return false, "itwiktionary") or
        !std.mem.startsWith(u8, literalJsonString(general, "generator") orelse return false, "MediaWiki")) return false;
    const tags = query.object.get("extensiontags") orelse return false;
    if (tags != .array or tags.array.items.len == 0 or tags.array.items.len > 256) return false;
    for (tags.array.items, 0..) |tag, index| {
        const name = literalApiTagName(tag) orelse return false;
        for (tags.array.items[0..index]) |prior|
            if (std.mem.eql(u8, literalApiTagName(prior) orelse return false, name)) return false;
    }
    const normal = (try literalResponseRoot(a, record.normal_json, record.normal_sha256)) orelse return false;
    const parsed = normal.object.get("parse") orelse return false;
    if (!std.mem.eql(u8, literalJsonString(parsed, "title") orelse return false, record.title) or
        (literalJsonNumber(parsed, "pageid") orelse return false) != record.page_id or
        (literalJsonNumber(parsed, "revid") orelse return false) != record.revision_id) return false;
    const raw = literalJsonString(parsed, "wikitext") orelse return false;
    if (!(matches(raw, record.raw_sha256) catch false) or record.raw_start > raw.len or
        record.paragraph_bytes > raw.len - record.raw_start) return false;
    const paragraph = raw[record.raw_start .. record.raw_start + record.paragraph_bytes];
    if (!std.unicode.utf8ValidateSlice(paragraph) or std.mem.indexOfAny(u8, paragraph, "\x00\r\n&{}[]") != null or
        std.mem.indexOf(u8, paragraph, "''") != null) return false;
    var escaped: std.ArrayList(u8) = .empty;
    try escaped.appendSlice(a, "<p>");
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < paragraph.len) {
        if (paragraph[cursor] == '<') {
            const end = encoder.wikitext_syntax.literalDoubleAngleProseEnd(paragraph, cursor) orelse return false;
            var word_end = cursor + 2;
            while (word_end < end - 2 and paragraph[word_end] != ',' and paragraph[word_end] != ' ') : (word_end += 1) {}
            for (tags.array.items) |tag|
                if (std.ascii.eqlIgnoreCase(literalApiTagName(tag) orelse return false, paragraph[cursor + 2 .. word_end])) return false;
            try escaped.appendSlice(a, "&lt;&lt;");
            try escaped.appendSlice(a, paragraph[cursor + 2 .. end - 2]);
            try escaped.appendSlice(a, "&gt;&gt;");
            cursor = end;
            count += 1;
            if (count > 128) return false;
        } else {
            if (paragraph[cursor] == '>') return false;
            try escaped.append(a, paragraph[cursor]);
            cursor += 1;
        }
    }
    if (count == 0) return false;
    const html = literalJsonString(parsed, "text") orelse return false;
    const joined = try std.fmt.allocPrint(a, "{s}</p>", .{escaped.items});
    const line_ended = try std.fmt.allocPrint(a, "{s}\n</p>", .{escaped.items});
    const occurrences = literalHtmlParagraphCount(html, &.{joined, line_ended}) orelse return false;
    return occurrences == 1;
}
fn literalAnglePolicyValid(a: std.mem.Allocator, policy: OrdinaryLiteralAngles) !bool {
    if (!std.mem.eql(u8, policy.schema, "it-normal-parser-literal-double-angles.v1") or
        !std.mem.eql(u8, policy.parser_source_sha256, "02962e675880b9034a4cd2b0d05a2f5c7bdbb8817ba0774a6663474812f86a99") or
        !std.mem.eql(u8, policy.sanitizer_source_sha256, "6f61237cef8d818a688d8350fe4d2945616830eef43c473aa812d16d27188c0f") or
        policy.records.len == 0 or policy.records.len > 16) return false;
    for (policy.records, 0..) |record, index| {
        // This finite version is issued only by the authenticated S4 capture.
        // A supplied response plus its self-hash cannot issue source authority.
        if (!std.mem.eql(u8, record.siteinfo_sha256, "f6968e69c319b28ee48e97bc11516d0e42a7f46396ab3211efe05eefd0ffa61e") or
            !std.mem.eql(u8, record.normal_sha256, "9210d08c86de5c6c02e35f0322f1c17632c411e6123f5019e0c2beffa6996eb4") or
            !std.mem.eql(u8, record.expanded_sha256, "2416e54098457601fcc484b48179a0c52d61ea8fb1ff94de422cd7e26b894dcc")) return false;
        if (!try literalAngleRecordValid(a, record)) return false;
        for (policy.records[0..index]) |prior| {
            if (prior.page_id == record.page_id or std.mem.eql(u8, prior.title, record.title)) return false;
        }
    }
    return true;
}
fn literalCandidatesWithin(source: []const u8, start: usize, bytes: usize) bool {
    if (start > source.len or bytes > source.len - start) return false;
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, cursor, '<')) |at| {
        if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(source, at)) |end| {
            if (at < start or end > start + bytes) return false;
            cursor = end;
        } else cursor = at + 1;
    }
    return true;
}
fn ordinaryLiteralAuthority(a: std.mem.Allocator, policy: ?OrdinaryLiteralAngles, phase: WorkerPhase,
    title: []const u8, id: P.PageIdentity, raw: []const u8, expanded: []const u8) !bool
{
    if (id.namespace != 0) return false;
    const conditional = std.mem.eql(u8, phase.status, "literal-angle-authority-required");
    const complete = std.mem.eql(u8, phase.status, "complete");
    if (!conditional and !complete) return false;
    const evidence = phase.literal_angle_candidates;
    if (conditional) {
        if (evidence == null or evidence.?.len == 0 or evidence.?.len > 128) return false;
    } else if (evidence != null) return false;
    var candidate_found = false;
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, expanded, cursor, '<')) |at| {
        if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(expanded, at) != null) { candidate_found = true; break; }
        cursor = at + 1;
    }
    if (!candidate_found) return complete;
    if (!conditional) return false;
    const known = policy orelse return false;
    if (!try literalAnglePolicyValid(a, known)) return false;
    for (known.records) |record| {
        if (record.page_id != id.page_id or record.revision_id != id.revision_id or !std.mem.eql(u8, record.title, title)) continue;
        if (!(matches(raw, record.raw_sha256) catch false) or !(matches(expanded, record.expanded_sha256) catch false) or
            !literalCandidatesWithin(raw, record.raw_start, record.paragraph_bytes) or
            !literalCandidatesWithin(expanded, record.expanded_start, record.paragraph_bytes)) return false;
        const paragraph = raw[record.raw_start .. record.raw_start + record.paragraph_bytes];
        if (!std.mem.eql(u8, paragraph, expanded[record.expanded_start .. record.expanded_start + record.paragraph_bytes])) return false;
        if (evidence) |items| {
            var offset: usize = 0;
            while (std.mem.indexOfScalarPos(u8, paragraph, offset, '<')) |at| {
                const end = encoder.wikitext_syntax.literalDoubleAngleProseEnd(paragraph, at) orelse return false;
                var observed = false;
                for (items) |item| if (item.origin == .expanded_output and std.mem.eql(u8, item.token, paragraph[at..end])) {
                    observed = true; break;
                };
                if (!observed) return false;
                offset = end;
            }
            var total: usize = 0;
            for (items, 0..) |item, index| {
                if (item.origin == .extension_call or item.origin == .display_title or item.token.len > 16 * 1024 - total or
                    encoder.wikitext_syntax.literalDoubleAngleProseEnd(item.token, 0) != item.token.len or
                    std.mem.indexOf(u8, paragraph, item.token) == null) return false;
                total += item.token.len;
                for (items[0..index]) |prior|
                    if (prior.origin == item.origin and std.mem.eql(u8, prior.token, item.token)) return false;
            }
        }
        return true;
    }
    return false;
}

const OrdinaryManifest = struct {
    literal_angles: ?OrdinaryLiteralAngles = null,
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
    gallery: ?*const GalleryProjection = null,
    gallery_authority: ?PC.LiteralGalleryAuthority = null,
    cite_evidence: ?CiteReceiptEvidence = null,
    cite_selection_sha256: ?[32]u8 = null,
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

const CiteSourceMode = enum { raw, expanded };
fn ordinaryHtml(source: []const u8, imports: []const OrdinaryStyleImport, comptime origin: CiteSourceMode) bool {
    return ordinaryHtmlWithCite(source, imports, origin, null);
}
fn ordinaryHtmlWithCite(source: []const u8, imports: []const OrdinaryStyleImport,
    comptime origin: CiteSourceMode, cite: ?CiteSites) bool {
    var consumed: usize = 0;
    var open: [64][]const u8 = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, source, pos, "<>")) |start| {
        if (cite) |sites| if (sites.skipAt(source, start)) |end| {
            if (depth != 0) return false;
            pos = end;
            continue;
        };
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
        if (depth == 0) {
            if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(source, start)) |end| {
                pos = end;
                continue;
            }
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
                if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(line, i)) |end| {
                    cursor = end;
                    continue;
                }
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
    return ordinaryFamilyStyleInventoryWithCite(raw, expanded, imports, visitor, null);
}
fn ordinaryFamilyStyleInventoryWithCite(raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport, visitor: anytype, cite: ?CitePair) bool
{
    if (!ordinaryBoundedSource(&.{}, raw, expanded) or std.mem.indexOf(u8, expanded, "{{") != null or
        std.mem.indexOf(u8, expanded, "}}") != null or
        !ordinaryHtmlWithCite(raw, &.{}, .raw, if (cite) |pair| pair.raw else null) or
        !ordinaryHtmlWithCite(expanded, imports, .expanded, if (cite) |pair| pair.expanded else null)) return false;
    if (!ordinaryPinHeaderAbsent(expanded)) return false;
    return ordinaryStaticCalls(raw, 0, visitor);
}

pub fn ordinaryFamilySourceSelected(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8) bool {
    return ordinaryFamilyCallsSelected(calls, raw, expanded, &.{});
}

fn ordinaryFamilyCallsSelected(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport) bool
{
    return ordinaryFamilyCallsSelectedWithCite(calls, raw, expanded, imports, null);
}
fn ordinaryFamilyCallsSelectedWithCite(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport, cite: ?CitePair) bool
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
    if (!ordinaryFamilyStyleInventoryWithCite(raw, expanded, imports, &catalog, cite)) return false;
    for (calls, catalog.seen[0..calls.len]) |call, present| if (call.required and !present) return false;
    return true;
}

// The immutable base contains only the fixed global vector. The effect
// producer supplies the effective order for this job. Check every byte, key
// and base before parsing this exact vector in the page arena.
fn ordinaryReceiptSource(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport) bool
{
    return ordinaryReceiptSourceWithCite(calls, raw, expanded, imports, null);
}
fn ordinaryReceiptSourceWithCite(calls: []const OrdinaryCall, raw: []const u8, expanded: []const u8,
    imports: []const OrdinaryStyleImport, cite: ?CitePair) bool
{
    if (calls.len != 0) return ordinaryFamilyCallsSelectedWithCite(calls, raw, expanded, imports, cite);
    const Names = struct { pub fn visit(_: @This(), _: OrdinarySourceCall) bool { return true; } };
    return ordinaryFamilyStyleInventoryWithCite(raw, expanded, imports, Names{}, cite);
}

const P = @import("bundle_protocol");

const WorkerPhase = struct {
    literal_angle_candidates: ?[]const LiteralAngleEvidence = null,
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

// A whole-page normal ParserOutput observation. The Worker envelope supplies
// exact operand custody, while the Book supplies the witnessed module cascade
// and rendered media outcomes. An operand can never select this route alone.
const GalleryOperand = struct {
    raw_start: usize,
    expanded_start: usize,
    bytes: usize,
    sha256: []const u8,

    fn same(self: @This(), other: @This()) bool {
        return self.raw_start == other.raw_start and self.expanded_start == other.expanded_start and
            self.bytes == other.bytes and std.mem.eql(u8, self.sha256, other.sha256);
    }

    fn region(self: @This(), raw: []const u8, expanded: []const u8) ?[]const u8 {
        if (self.raw_start > raw.len or self.expanded_start > expanded.len or
            self.bytes > raw.len - self.raw_start or self.bytes > expanded.len - self.expanded_start) return null;
        const span = expanded[self.expanded_start..][0..self.bytes];
        if (self.raw_start == 0 or raw[self.raw_start - 1] != '\n' or
            self.expanded_start == 0 or expanded[self.expanded_start - 1] != '\n' or
            (self.raw_start + self.bytes != raw.len and raw[self.raw_start + self.bytes] != '\n') or
            (self.expanded_start + self.bytes != expanded.len and expanded[self.expanded_start + self.bytes] != '\n') or
            !std.mem.eql(u8, raw[self.raw_start..][0..self.bytes], span) or
            !(matches(span, self.sha256) catch false)) return null;
        if (std.mem.indexOf(u8, raw, span) != self.raw_start or
            std.mem.indexOfPos(u8, raw, self.raw_start + 1, span) != null or
            std.mem.indexOf(u8, expanded, span) != self.expanded_start or
            std.mem.indexOfPos(u8, expanded, self.expanded_start + 1, span) != null) return null;
        return span;
    }
};

const GalleryProjection = struct {
    schema: []const u8,
    observation_sha256: []const u8,
    title: []const u8,
    page_id: u64,
    revision_id: u64,
    raw_sha256: []const u8,
    expanded_sha256: []const u8,
    display_sha256: []const u8,
    operand: GalleryOperand,
    rows: []const struct {
        source_sha256: []const u8,
        image: ?struct {
            requested: []const u8,
            canonical: []const u8,
            caption_sha256: []const u8,
            links_sha256: []const u8,
        },
    },
    styles: []const struct { url: []const u8, sha256: []const u8, body: []const u8 },

    fn claims(self: *const @This(), title: []const u8, page_id: u64) bool {
        return self.page_id == page_id or std.mem.eql(u8, self.title, title);
    }

    fn source(self: *const @This(), raw: []const u8, expanded: []const u8) ?[]const u8 {
        if (!(matches(raw, self.raw_sha256) catch false) or
            !(matches(expanded, self.expanded_sha256) catch false)) return null;
        return self.operand.region(raw, expanded);
    }

    fn valid(self: @This()) !bool {
        if (!std.mem.eql(u8, self.schema, "it-normal-literal-gallery.v1") or
            self.title.len == 0 or self.title.len > 4096 or !std.unicode.utf8ValidateSlice(self.title) or
            std.mem.indexOfAny(u8, self.title, "\r\n\x00") != null or self.page_id == 0 or self.revision_id == 0 or
            self.operand.bytes == 0 or self.operand.bytes > 16384 or self.rows.len == 0 or self.rows.len > 128 or
            self.styles.len != 3) return false;
        for ([_][]const u8{ self.observation_sha256, self.raw_sha256, self.expanded_sha256,
            self.display_sha256, self.operand.sha256 }) |value| _ = try digest(value);
        const style_modules = [_][]const u8{ "mediawiki.page.gallery.styles", "ext.gadget.IndiceOrizzontale", "site.styles" };
        var bytes: usize = 0;
        for (self.styles, style_modules) |style, name| {
            const prefix = "https://it.wiktionary.org/w/load.php?lang=it&modules=";
            const suffix = "&only=styles&skin=vector-2022";
            if (style.body.len == 0 or style.body.len > 768 * 1024 - bytes or
                style.url.len <= prefix.len + suffix.len or style.url.len > 4096 or
                !std.mem.startsWith(u8, style.url, prefix) or !std.mem.endsWith(u8, style.url, suffix) or
                !try matches(style.body, style.sha256)) return false;
            const modules = style.url[prefix.len .. style.url.len - suffix.len];
            if (std.mem.indexOfAny(u8, modules, "&?#") != null or
                std.mem.indexOf(u8, modules, "ext.tmh.player.styles") != null) return false;
            if (std.mem.eql(u8, name, style_modules[0])) {
                var names = std.mem.splitSequence(u8, modules, "%7C");
                while (names.next()) |candidate| {
                    if (std.mem.eql(u8, candidate, name)) break;
                } else return false;
            } else if (!std.mem.eql(u8, modules, name)) return false;
            bytes += style.body.len;
        }
        var rendered = false;
        for (self.rows) |row| {
            _ = try digest(row.source_sha256);
            if (row.image) |image| {
                if (!galleryFullFile(image.requested) or !galleryFullFile(image.canonical)) return false;
                _ = try digest(image.caption_sha256);
                _ = try digest(image.links_sha256);
                rendered = true;
            }
        }
        return rendered;
    }

    fn renderAuthority(self: *const @This(), a: std.mem.Allocator, ns: *const namespace_registry.Registry,
        images: image_catalog.Catalog, region: []const u8) !?PC.LiteralGalleryAuthority
    {
        const open = "<gallery>";
        const close = "</gallery>";
        if (!std.mem.startsWith(u8, region, open ++ "\n") or !std.mem.endsWith(u8, region, "\n" ++ close) or
            region.len <= open.len + close.len + 2) return null;
        const body = region[open.len .. region.len - close.len];
        if (std.mem.indexOfAny(u8, body, "<>{}\r\x00") != null) return null;
        const files = try a.alloc(?[]const u8, self.rows.len);
        var lines = std.mem.splitScalar(u8, body[1 .. body.len - 1], '\n');
        for (self.rows, files) |row, *file| {
            const line = lines.next() orelse return null;
            if (line.len > 4096 or !(matches(line, row.source_sha256) catch false)) return null;
            const separator = std.mem.indexOfScalar(u8, line, '|') orelse return null;
            const options = std.mem.trim(u8, line[separator + 1 ..], " \t");
            const retained = PC.traditionalLiteralGalleryOptions(options) != null;
            if (row.image) |image| {
                if (!retained) return null;
                const operand = std.mem.trim(u8, line[0..separator], " \t");
                if (!try images.matchesGalleryBitmap(a, ns, operand, image.requested, image.canonical)) return null;
                file.* = image.canonical["File:".len..];
            } else {
                if (retained) return null;
                file.* = null;
            }
        }
        if (lines.next() != null) return null;
        return .{ .body = body, .files = files };
    }

    fn ordered(self: *const @This(), a: std.mem.Allocator) ![]const S.Source {
        const result = try a.alloc(S.Source, self.styles.len);
        for (self.styles, result) |style, *out| out.* = .{ .base_url = style.url, .css = style.body };
        return result;
    }

    fn sameStyles(self: *const @This(), issued: OrdinaryStyleReceipt) bool {
        if (issued.ordered.len != self.styles.len or issued.placed_keys.len != self.styles.len) return false;
        for (self.styles, issued.ordered, issued.placed_keys) |style, actual, key| {
            if (key != null or actual.byte_start != 0 or actual.unknown_applicability or
                !std.mem.eql(u8, style.url, actual.base_url) or !std.mem.eql(u8, style.body, actual.css)) return false;
        }
        return true;
    }
};

fn galleryFullFile(file: []const u8) bool {
    return std.mem.startsWith(u8, file, "File:") and file.len > "File:".len and file.len <= 4096 and
        std.unicode.utf8ValidateSlice(file) and std.mem.indexOfAny(u8, file, "<>[]{}|\t\r\n\x00") == null;
}

const GalleryEnvelope = struct {
    schema: []const u8,
    status: []const u8,
    phase: WorkerPhase,
    gallery: GalleryOperand,
};

fn workerPhaseMatches(phase: WorkerPhase, status: []const u8, ordinal: u64, id: P.PageIdentity,
    title: []const u8, raw: []const u8, expanded: []const u8, display: []const u8) bool
{
    if (phase.literal_angle_candidates != null and !std.mem.eql(u8, status, "literal-angle-authority-required")) return false;
    return std.mem.eql(u8, phase.schema, "wikidict.page-effects.v1") and std.mem.eql(u8, phase.status, status) and
        std.mem.eql(u8, phase.collector, "native-executed-extensions.v1") and phase.generation == ordinal and
        phase.identity.namespace == 0 and phase.identity.page_id == id.page_id and phase.identity.revision_id == id.revision_id and
        std.mem.eql(u8, phase.identity.title, title) and (matches(raw, phase.source_sha256) catch false) and
        (matches(expanded, phase.expanded_sha256) catch false) and (matches(display, phase.display_title_sha256) catch false);
}

fn sheetEqual(x: OrdinarySheet, y: OrdinarySheet) bool {
    return x.local_key == null and y.local_key == null and x.byte_start == y.byte_start and
        x.unknown_applicability == y.unknown_applicability and std.mem.eql(u8, x.url, y.url) and
        std.mem.eql(u8, x.sha256, y.sha256);
}

const WorkerFeatures = struct { toc: bool, tmh: bool, cite_active: bool = false };

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
    if (w.gallery) |gallery| {
        if (w.image_catalog == null or !(try gallery.valid())) return false;
    }
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
        if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(expanded, start)) |end| {
            pos = end;
            continue;
        }
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
    return workerFeaturesWithCite(a, expanded, ns, recipe, catalog, timed, null);
}
fn workerFeaturesWithCite(a: std.mem.Allocator, expanded: []const u8, ns: *const namespace_registry.Registry,
    recipe: WorkerProjection, catalog: ?*const image_catalog.Catalog, timed: ?timed_media_inputs.Page,
    cite: ?CiteSites) !?WorkerFeatures
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
            const absolute = @intFromPtr(line.ptr) - @intFromPtr(expanded.ptr) + start;
            if (cite) |sites| if (sites.skipAt(expanded, absolute)) |end| {
                if (html_depth != 0 or in_table or end - absolute > line.len - start) return null;
                pos = start + end - absolute;
                continue;
            };
            if (line[start] == '<') {
                if (html_depth == 0 and !in_table) {
                    if (encoder.wikitext_syntax.literalDoubleAngleProseEnd(line, start)) |end| {
                        pos = end;
                        continue;
                    }
                }
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
                if (ordinaryLiteralBracket(content) or workerTranslationBracket(line, start, end) or
                    citeLiteralIpaAllowed(cite, recipe.cite, line, start, end)) {
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
    return .{ .toc = headings >= 4, .tmh = audio, .cite_active = cite != null };
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
    book: *const Book, raw: []const u8, expanded: []const u8, issued: OrdinaryStyleReceipt) !?*const PC.ContainerDisclosureStyleScope
{
    const input = book.input;
    if (issued.worker_features) |features| if (features.cite_active)
        return citePageScope(a, m, shared, book, raw, expanded, issued);
    if (issued.cite_evidence != null or issued.cite_selection_sha256 != null) return null;
    const registry = m.local_registry.?;
    if (issued.gallery) |gallery| {
        const registered = if (m.worker_projection) |*recipe| (if (recipe.gallery) |*selected| selected else return null) else return null;
        if (registered != gallery or issued.worker_features != null or issued.document_base != null or issued.imports.len != 0 or
            issued.raw.ptr != raw.ptr or issued.raw.len != raw.len or issued.expanded.ptr != expanded.ptr or issued.expanded.len != expanded.len or
            !std.mem.eql(u8, &issued.module_selection_sha256, &(try digest(m.module_selection_sha256))) or
            !std.mem.eql(u8, &issued.placement_sha256, &(try digest(registry.placement_sha256))) or
            !gallery.sameStyles(issued)) return null;
        const region = gallery.source(raw, expanded) orelse return null;
        const authority = issued.gallery_authority orelse return null;
        const open = "<gallery>";
        const close = "</gallery>";
        if (region.len <= open.len + close.len or
            authority.body.ptr != region[open.len..].ptr or authority.body.len != region.len - open.len - close.len or
            authority.files.len != gallery.rows.len) return null;
        for (authority.files, gallery.rows) |file, row| {
            if (row.image) |image| {
                if (!std.mem.eql(u8, file orelse return null, image.canonical["File:".len..])) return null;
            } else if (file != null) return null;
        }
        return ordinarySelectedScope(a, m, shared, expanded, issued.ordered, true, authority);
    }
    if (issued.gallery_authority != null) return null;
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
    return ordinarySelectedScope(a, m, shared, expanded, issued.ordered,
        slots.len != globals.len or globals.len != global_bytes.len, null);
}

fn ordinarySelectedScope(a: std.mem.Allocator, m: *const OrdinaryManifest, shared: *const S.DisclosureSharedProfile,
    expanded: []const u8, ordered: []const S.Source, reparse: bool, gallery: ?PC.LiteralGalleryAuthority) !?*const PC.ContainerDisclosureStyleScope
{
    const profile = try a.create(S.DisclosureSharedProfile);
    profile.* = shared.*;
    profile.owner_attribute_projection = if (m.owner_attributes) |*known| &known.projection else null;
    if (reparse) {
        const styles = try a.create(S.Profile);
        styles.* = S.parseSourcesForTargetAlloc(a, ordered, .screen) catch |err| switch (err) {
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
    var scope = PC.ContainerDisclosureStyleScope.fromPageSourcesAndFont(expanded, profile, ordered, font) orelse return null;
    scope.html_underline = m.underline;
    scope.literal_gallery = gallery;
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
            if (w.cite) |assets| {
                if (!try assets.valid(selected.styles)) return error.InvalidContainerDisclosureInput;
                _ = try assets.compositionDigest(m);
            }
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
        if (m.literal_angles) |policy| {
            if (!dynamic or !std.mem.eql(u8, m.wiki, "itwiktionary") or !try literalAnglePolicyValid(a, policy))
                return error.InvalidContainerDisclosureInput;
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
            var previous_start: usize = 0;
            for (page.captures, 0..) |capture, at| {
                if (capture.owner_start >= capture.content_start or capture.content_start >= capture.content_end or
                    capture.content_end > capture.owner_end or (!page.translation_eof and capture.content_end == capture.owner_end) or
                    (at != 0 and (capture.owner_start <= previous_start or
                        (!page.translation_eof and capture.owner_start < previous_end))) or
                    !T.validContainerDisclosure(capture.policy) or capture.policy.button == null or capture.policy.direction == null)
                    return error.InvalidContainerDisclosureInput;
                previous_end = capture.owner_end;
                previous_start = capture.owner_start;
                _ = try digest(capture.owner_sha256);
                const reference = capture.reference;
                if (page.translation_eof and
                    !std.mem.eql(u8, reference.scope, "normal_current_initialized_component"))
                    return error.InvalidContainerDisclosureInput;
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

    fn galleryReceipt(self: *const Book, a: std.mem.Allocator, gallery: *const GalleryProjection, ordinal: u64,
        id: P.PageIdentity, title: []const u8, raw: []const u8, expanded: []const u8, display: []const u8,
        collector: []const u8, ns: *const namespace_registry.Registry) !?OrdinaryStyleReceipt
    {
        if (gallery.page_id != id.page_id or gallery.revision_id != id.revision_id or
            !std.mem.eql(u8, gallery.title, title) or !ordinaryBoundedSource(&.{}, raw, expanded) or
            !(matches(display, gallery.display_sha256) catch false)) return null;
        const region = gallery.source(raw, expanded) orelse return null;
        const envelope = std.json.parseFromSliceLeaky(GalleryEnvelope, a, collector, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const phase = envelope.phase;
        if (!std.mem.eql(u8, envelope.schema, "wikidict.page-effects.literal-gallery.v1") or
            !std.mem.eql(u8, envelope.status, "operands_only") or
            !gallery.operand.same(envelope.gallery) or !workerPhaseMatches(phase, "operands_only", ordinal, id, title, raw, expanded, display) or
            phase.operation_count != 2 or phase.observed_extensions.len != 0 or phase.template_styles.len != 0 or
            phase.placement != null) return null;
        for ([_][]const u8{ title, raw, expanded, display }) |source| if (!try workerTriggerFree(a, source)) return null;
        const images = self.images orelse return null;
        const authority = (try gallery.renderAuthority(a, ns, images, region)) orelse return null;
        const m = self.ordinary.?.dynamic.?;
        const keys = try a.alloc(?[]const u8, gallery.styles.len);
        @memset(keys, null);
        return .{ .gallery = gallery, .gallery_authority = authority, .raw = raw, .expanded = expanded,
            .imports = &.{}, .ordered = try gallery.ordered(a), .placed_keys = keys,
            .module_selection_sha256 = self.ordinary.?.module_selection_sha256,
            .placement_sha256 = try digest(m.local_registry.?.placement_sha256) };
    }

    fn pageFeatures(self: *const Book, a: std.mem.Allocator, ns: *const namespace_registry.Registry,
        recipe: WorkerProjection, id: P.PageIdentity, title: []const u8, raw: []const u8,
        expanded: []const u8, cite: ?CiteSites) !?WorkerFeatures
    {
        const timed = if (self.timed) |*media| try media.forPage(a,
            .{ .title = title, .page_id = id.page_id, .revision_id = id.revision_id }, raw, expanded) else null;
        return workerFeaturesWithCite(a, expanded, ns, recipe,
            if (self.images) |*images| images else null, timed, cite);
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
        const m = self.ordinary.?.dynamic.?;
        const w = if (m.worker_projection) |*recipe| recipe else return null;
        if (w.gallery) |*gallery| {
            if (gallery.claims(title, id.page_id))
                return self.galleryReceipt(a, gallery, ordinal, id, title, raw, expanded, display, data.collector, ns);
        }
        const phase = std.json.parseFromSliceLeaky(WorkerPhase, a, data.collector, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const required_status: []const u8 = if (phase.literal_angle_candidates == null) "complete" else "literal-angle-authority-required";
        if (!workerPhaseMatches(phase, required_status, ordinal, id, title, raw, expanded, display)) return null;
        if (!try ordinaryLiteralAuthority(a, m.literal_angles, phase, title, id, raw, expanded)) return null;
        if (!ordinaryBoundedSource(&.{}, raw, expanded)) return null;
        const registry = m.local_registry.?;
        const imports = (try workerStyleImports(a, expanded, registry)) orelse return null;
        var cite_pair: ?CitePair = null;
        var cite_evidence: ?CiteReceiptEvidence = null;
        if (!workerOperationsMatch(phase, imports, registry)) {
            if (w.cite == null or imports.len != 0) return null;
            const evidence: CiteReceiptEvidence = .{ .ordinal = ordinal, .id = id, .title = title,
                .display = display, .payload = data, .namespaces = ns };
            cite_pair = (try citeEvidencePair(a, profile, raw, expanded, evidence)) orelse return null;
            if (!try citeUxEnvironment(a, m.*, raw, expanded)) return null;
            cite_evidence = evidence;
        }
        if (!ordinaryReceiptSourceWithCite(m.calls, raw, expanded, imports, cite_pair)) return null;
        for ([_][]const u8{ title, raw, expanded, display }) |source| if (!try workerTriggerFree(a, source)) return null;
        if (!workerLocalPlacementValid(w.*, expanded, imports)) return null;
        const features = (try self.pageFeatures(a, ns, w.*, id, title, raw, expanded,
            if (cite_pair) |pair| pair.expanded else null)) orelse return null;
        const url = if (imports.len != 0 or features.cite_active) try workerDocumentUrl(a, title, id.revision_id) else null;
        if (features.cite_active) {
            const assets = w.cite orelse return null;
            var projected: [32]S.Source = undefined;
            const sources = assets.project(self.input.shared.?.styles, features,
                url.?, &projected) orelse return null;
            const ordered_cite = try a.dupe(S.Source, sources);
            const keys_cite = try a.alloc(?[]const u8, sources.len);
            @memset(keys_cite, null);
            return .{ .raw = raw, .expanded = expanded, .imports = imports, .ordered = ordered_cite,
                .placed_keys = keys_cite, .module_selection_sha256 = self.ordinary.?.module_selection_sha256,
                .placement_sha256 = try digest(registry.placement_sha256), .worker_features = features,
                .document_base = url, .cite_evidence = cite_evidence,
                .cite_selection_sha256 = try assets.compositionDigest(m.*) };
        }
        const globals = workerSlots(w.*, features) orelse return null;
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
            const eof = if (page.translation_eof) blk: {
                const inspected = inspectTranslationEof(expanded, try digest(page.expanded_sha256)) orelse
                    return error.InvalidContainerDisclosureInput;
                if (!translationEofCapturesMatch(&inspected, page.captures)) return error.InvalidContainerDisclosureInput;
                const held = try a.create(PC.TranslationEofProof);
                held.* = inspected;
                break :blk held;
            } else null;
            const rows = try a.alloc(PC.ContainerDisclosureCapture, page.captures.len);
            for (rows, page.captures) |*row, capture| row.* = .{
                .owner_start = capture.owner_start, .owner_end = capture.owner_end,
                .content_start = capture.content_start, .content_end = capture.content_end,
                .policy = capture.policy, .source_labels = capture.source_labels,
            };
            const held = try a.create(PC.ContainerDisclosureSource);
            held.* = .{ .source = expanded, .captures = rows, .translation_eof = eof, .shared_profile = self.shared, .parser_output_direction = if (self.input.shared) |shared| shared.parser_output_direction else null };
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
                    const manifest = ordinary.dynamic;
                    const registered = if (manifest) |m| (if (m.worker_projection) |*w|
                        (if (w.gallery) |*g| g else null) else null) else null;
                    if (registered) |gallery| {
                        if (gallery.claims(title, page_id)) {
                            if (gallery.page_id != page_id or gallery.revision_id != revision_id or
                                !std.mem.eql(u8, gallery.title, title) or issued.gallery != gallery) break :blk null;
                        } else if (issued.gallery != null) break :blk null;
                    } else if (issued.gallery != null) break :blk null;
                    if (issued.document_base) |url| {
                        if (issued.worker_features == null or
                            (issued.imports.len == 0 and !issued.worker_features.?.cite_active) or
                            !std.mem.eql(u8, url, try workerDocumentUrl(a, title, revision_id))) break :blk null;
                    } else if (issued.worker_features != null and
                        (issued.imports.len != 0 or issued.worker_features.?.cite_active)) break :blk null;
                    if (issued.cite_evidence) |evidence| {
                        if (evidence.id.namespace != 0 or evidence.id.page_id != page_id or
                            evidence.id.revision_id != revision_id or !std.mem.eql(u8, evidence.title, title)) break :blk null;
                    }
                }
                if (ordinary.dynamic) |manifest| break :blk if (receipt) |issued|
                    try ordinaryPageScope(a, manifest, shared, self, raw, expanded, issued) else null;
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

pub const TranslationEofProof = PC.TranslationEofProof;

const EofTag = struct {
    tag: encoder.wikitext_syntax.Tag,
    start: usize,

    fn class(self: @This(), want: []const u8) bool {
        return self.tag.is("div") and classToken(eofSingleClass(self.tag) orelse return false, want);
    }
};

const EofTable = struct {
    start: usize,
    html_depth: usize,
    row: ?usize = null,
    cell: ?usize = null,
    child: ?TranslationEofProof.Child = null,
};

fn eofSingleClass(tag: encoder.wikitext_syntax.Tag) ?[]const u8 {
    const first = std.ascii.findIgnoreCase(tag.attrs, "class") orelse return null;
    if (std.ascii.findIgnoreCase(tag.attrs[first + "class".len ..], "class") != null) return null;
    const value = tag.attr("class") orelse return null;
    return if (std.mem.indexOfScalar(u8, value, '&') == null) value else null;
}

fn eofTranslationTable(line: []const u8) bool {
    const tag: encoder.wikitext_syntax.Tag = .{
        .name = "table", .attrs = line[2..], .end = line.len,
        .closing = false, .self_closing = false,
    };
    return ordinaryTagAttributes(tag.attrs, tag) and
        std.mem.eql(u8, eofSingleClass(tag) orelse return false, "translations");
}

fn eofTableControl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{|") or (line.len != 0 and (line[0] == '|' or line[0] == '!'));
}

/// The input must be the complete, authenticated expanded page, not a
/// wrapper or cell subslice. Recheck the selected expanded digest before
/// scanning. This function issues no style, worker, or render admission.
pub fn inspectTranslationEof(expanded: []const u8, expected_sha256: [32]u8) ?TranslationEofProof {
    if (expanded.len == 0 or expanded.len > 32 * 1024 or !std.unicode.utf8ValidateSlice(expanded) or
        std.mem.indexOfAny(u8, expanded, "\r\x00") != null or
        std.mem.indexOf(u8, expanded, "{{") != null or std.mem.indexOf(u8, expanded, "}}") != null or
        std.mem.indexOf(u8, expanded, "-{") != null or std.mem.indexOf(u8, expanded, "__") != null) return null;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(expanded, &actual, .{});
    if (!std.mem.eql(u8, &expected_sha256, &actual)) return null;

    var html: [16]EofTag = undefined;
    var depth: usize = 0;
    var tables: [2]EofTable = undefined;
    var table_count: usize = 0;
    var children: [8]TranslationEofProof.Child = undefined;
    var child_count: usize = 0;
    var lines = std.mem.splitScalar(u8, expanded, '\n');
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(expanded.ptr);
        const trimmed = std.mem.trimStart(u8, line, " \t");
        // Refuse alternative table-marker spellings and ambiguous attribute
        // boundaries. The candidate only handles the recorded physical grammar.
        const without_indent = std.mem.trimStart(u8, trimmed, ": \t");
        if ((trimmed.len != line.len and eofTableControl(trimmed)) or
            (without_indent.len != trimmed.len and std.mem.startsWith(u8, without_indent, "{|"))) return null;
        if (std.mem.startsWith(u8, line, "{|")) {
            if (table_count == tables.len or std.mem.indexOfAny(u8, line[2..], "<>[]{}") != null) return null;
            tables[table_count] = .{ .start = start, .html_depth = depth };
            if (table_count == 1) {
                const parent = tables[0];
                const cell = parent.cell orelse return null;
                if (depth != parent.html_depth + 2 or !eofTranslationTable(line) or
                    !html[depth - 2].class("mw-collapsible") or !html[depth - 1].class("mw-collapsible-content"))
                    return null;
                tables[table_count].child = .{ .owner = html[depth - 2].start,
                    .content = html[depth - 1].start, .table = start, .table_close = 0,
                    .end = 0, .parent_cell = cell };
            }
            table_count += 1;
            continue;
        }
        var cursor: usize = 0;
        if (table_count != 0) {
            const frame = &tables[table_count - 1];
            if (std.mem.startsWith(u8, line, "|}")) {
                if (frame.html_depth != depth) return null;
                if (frame.child) |child| {
                    if (!std.mem.eql(u8, line, "|}</div></div>") or child_count == children.len or frame.cell == null)
                        return null;
                    children[child_count] = child;
                    children[child_count].end = start + line.len;
                    children[child_count].table_close = start;
                    child_count += 1;
                } else if (!std.mem.eql(u8, line, "|}") and !std.mem.eql(u8, line, "|}</div></div>")) {
                    return null;
                }
                table_count -= 1;
                cursor = 2;
            } else if (std.mem.startsWith(u8, line, "|-")) {
                if (frame.html_depth != depth or std.mem.trim(u8, line[2..], " \t").len != 0) return null;
                frame.row = start;
                frame.cell = null;
                continue;
            } else if (std.mem.startsWith(u8, line, "|")) {
                if (frame.html_depth != depth or std.mem.startsWith(u8, line, "|+") or
                    std.mem.indexOf(u8, line, "||") != null) return null;
                frame.cell = start;
            } else if (std.mem.startsWith(u8, line, "!") or (frame.cell == null and trimmed.len != 0)) {
                return null;
            }
        } else if (std.mem.startsWith(u8, line, "|}")) return null;

        // Real link tokens must stay intact. A DIV delimiter inside one is
        // outside this scan, even if lexical matching would see the spelling.
        if (!ordinaryLineOperands(line[cursor..])) return null;
        while (std.mem.indexOfScalarPos(u8, line, cursor, '<')) |at| {
            const tag = encoder.wikitext_syntax.tagAt(line, at) orelse return null;
            if (tag.is("br")) {
                if (tag.closing or std.mem.trim(u8, tag.attrs, " \t").len != 0) return null;
            } else if (tag.closing) {
                if (depth == 0 or !tag.is(html[depth - 1].tag.name) or tag.attrs.len != 0 or line[tag.end - 2] == '/')
                    return null;
                if (table_count != 0 and depth <= tables[table_count - 1].html_depth)
                    return null;
                depth -= 1;
            } else {
                const allowed = tag.is("div") or tag.is("span") or tag.is("i") or tag.is("b") or
                    tag.is("small") or tag.is("sup") or tag.is("sub");
                if (!allowed or depth == html.len or tag.self_closing or line[tag.end - 2] == '/' or
                    !ordinaryTagAttributes(tag.attrs, tag)) return null;
                html[depth] = .{ .tag = tag, .start = start + at };
                depth += 1;
            }
            cursor = tag.end;
        }
    }

    if (table_count != 1 or depth != 2 or tables[0].html_depth != 2 or
        !html[0].class("mw-collapsible") or !html[1].class("mw-collapsible-content") or
        child_count == 0) return null;
    const outer_table = tables[0];
    const row = outer_table.row orelse return null;
    const cell = outer_table.cell orelse return null;
    const table_line_end = std.mem.indexOfScalarPos(u8, expanded, outer_table.start, '\n') orelse return null;
    if (!eofTranslationTable(expanded[outer_table.start..table_line_end])) return null;
    // Each nested owner was physically closed under this same authored cell.
    // A close followed by a new row or cell cannot preserve this shape.
    for (children[0..child_count]) |child| if (child.parent_cell != cell) return null;
    const eof = expanded.len;
    return .{
        .expanded = expanded, .child_count = child_count, .children = children,
        .closes = .{
            .{ .kind = .cell, .opener = cell, .at = eof },
            .{ .kind = .row, .opener = row, .at = eof },
            .{ .kind = .row_group, .opener = null, .at = eof },
            .{ .kind = .table, .opener = outer_table.start, .at = eof },
            .{ .kind = .content, .opener = html[1].start, .at = eof },
            .{ .kind = .owner, .opener = html[0].start, .at = eof },
        },
    };
}

fn translationEofCapturesMatch(proof: *const PC.TranslationEofProof, captures: []const Capture) bool {
    const outer = proof.closes[5].opener orelse return false;
    const content = proof.closes[4].opener orelse return false;
    var previous_end: usize = 0;
    var outer_seen = false;
    var children: usize = 0;
    for (captures) |capture| {
        if (capture.owner_start < outer) {
            if (capture.owner_start < previous_end or capture.owner_end > outer or
                capture.content_end >= capture.owner_end) return false;
            previous_end = capture.owner_end;
        } else if (capture.owner_start == outer) {
            if (outer_seen or capture.content_start != content or
                capture.owner_end != proof.expanded.len or capture.content_end != proof.expanded.len) return false;
            outer_seen = true;
        } else {
            if (!outer_seen or children == proof.child_count) return false;
            const child = proof.children[children];
            if (capture.owner_start != child.owner or capture.content_start != child.content or
                capture.owner_end != child.end or capture.content_end != child.end - "</div>".len) return false;
            children += 1;
        }
    }
    return outer_seen and children == proof.child_count;
}

// Offsets must come from the ordinary parser's matched top-level literal
// occurrences in each original input. This predicate cannot establish ancestry.
// Call it after validating full-document context and refusing any other Cite.
const CiteSites = struct {
    const skipAt = workerCiteSkipAt;
    ref_open: usize,
    ref_close: usize,
    sink: usize,

    fn note(self: @This(), src: []const u8) ?[]const u8 {
        if (self.ref_open >= self.ref_close or self.ref_close >= self.sink or self.sink >= src.len or
            !std.mem.startsWith(u8, src[self.ref_open..self.ref_close], "<ref>") or
            !std.mem.startsWith(u8, src[self.ref_close..self.sink], "</ref>") or
            !std.mem.startsWith(u8, src[self.sink..], "<references/>")) return null;
        const end = self.ref_close + "</ref>".len;
        if (end != src.len and src[end] != '\n') return null;
        const after = self.sink + "<references/>".len;
        if (self.sink == 0 or src[self.sink - 1] != '\n' or (after < src.len and src[after] != '\n')) return null;
        const text = src[self.ref_open + "<ref>".len .. self.ref_close];
        if (text.len == 0 or text.len > 4096 or std.mem.trim(u8, text, " ").len == 0) return null;
        // First contract: ordinary Latin prose and digits. Exclude syntax for
        // extensions, URLs, headings, templates, magic links, entities and lists.
        var iter = (std.unicode.Utf8View.init(text) catch return null).iterator();
        while (iter.nextCodepoint()) |cp| {
            if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
                (cp >= '0' and cp <= '9') or (cp >= 0xc0 and cp <= 0xff and cp != 0xd7 and cp != 0xf7) or
                cp == ' ' or cp == ',' or cp == '.') continue;
            return null;
        }
        if (!(std.ascii.isAlphabetic(text[0]) or text[0] >= 0x80)) return null;
        for ([_][]const u8{ "ISBN", "RFC", "PMID" }) |magic| if (std.ascii.findIgnoreCase(text, magic) != null) return null;
        return text;
    }
};

fn citePhaseAndSites(phase: WorkerPhase, raw: []const u8, raw_sites: CiteSites,
    expanded: []const u8, expanded_sites: CiteSites, display: []const u8, imports: []const OrdinaryStyleImport) bool
{
    // Each actual complete literal-input and expanded-output scan contributes
    // one ref and one sink in this branch. No budget slack for other observations.
    if (phase.operation_count != 4 or phase.observed_extensions.len != 2 or
        !std.mem.eql(u8, phase.observed_extensions[0], "ref") or
        !std.mem.eql(u8, phase.observed_extensions[1], "references") or
        phase.template_styles.len != 0 or phase.placement != null or display.len != 0 or imports.len != 0) return false;
    const source_note = raw_sites.note(raw) orelse return false;
    const final_note = expanded_sites.note(expanded) orelse return false;
    return std.mem.eql(u8, source_note, final_note);
}

// CDI part. This replaces only the CiteAssets declaration in cite-loader03.
// Parse the optional WorkerProjection.cite value with OrdinaryManifest in the
// Book arena. The outer Input parse already owns ordinary_manifest bytes;
// escaped asset strings also use the Book allocator. Keep strict JSON parsing.
const CiteAssets = struct {
    literal_ipa_source_sha256: ?[]const u8 = null,
    schema: []const u8,
    source_proof_sha256: []const u8,
    operands_sha256: []const u8,
    head_tmh_on_url: []const u8,
    head_tmh_off_url: []const u8,
    parsoid_css: []const u8,
    common_css: []const u8,
    ux_css: []const u8,

    const Hash = std.crypto.hash.sha2.Sha256;
    const literal_ipa_pin = "7a83b155a68c702352157b3a077d6653806ff7bd29f5edda516847e2f0cd62f7";
    fn literalIpaProofMatches(self: @This()) bool {
        return std.mem.eql(u8, self.literal_ipa_source_sha256 orelse return false, literal_ipa_pin);
    }
    const authority_pin = "a5b4b7adcea65177fd13adc4bc4d9f3b1ffac8a3c886e4aa0a32809b742fe947";
    const operands_pin = "69ab54e50bc8292b81d3f9efed04b03d8fe5c54187a0c71b1372165774e22767";
    const base_pin = "eb022acdd5ec376b132dd1a71aea10dc000b319b0405719ce9f3d0f2b5846931";
    const head_on_pin = "6760811627001914761f36dfeba2cb5e6c34b09f981c4d354fbdb34c875add7f";
    const head_off_pin = "25c559763ae0bb46495c2165a9451462aed3550589fdff7dba3de3388bad916a";
    const base_count = 23;
    const base_head_count = 6;
    const toc_slot = 11;
    const max_sources = 32;
    const max_css_bytes = 768 * 1024;
    const max_url_bytes = 4096;

    fn authorityMatches(self: @This()) bool {
        return std.mem.eql(u8, self.schema, "it-normal-cite-plain-note-sink.v1") and
            std.mem.eql(u8, self.source_proof_sha256, authority_pin) and
            std.mem.eql(u8, self.operands_sha256, operands_pin);
    }

    fn hashSize(hash: *Hash, size: usize) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(size), .big);
        hash.update(&bytes);
    }

    // Ordered fc65 style descriptor pin. Include the source count and every
    // length, response offset, applicability byte, URL and verified body hash.
    // Row boundaries and all base authorities are bound by one digest.
    fn baseValid(base: []const SharedStyleInput) !bool {
        if (base.len != base_count) return false;
        var vector = Hash.init(.{});
        vector.update("wikidict.it.cite.base-styles.v1\x00");
        hashSize(&vector, base.len);
        var total: usize = 0;
        for (base) |row| {
            if (row.url.len == 0 or row.url.len > max_url_bytes or
                row.body.len > max_css_bytes - total or row.byte_start > max_css_bytes - row.body.len) return false;
            total += row.body.len;
            const claimed = digest(row.sha256) catch return false;
            var body: [32]u8 = undefined;
            Hash.hash(row.body, &body, .{});
            if (!std.mem.eql(u8, &body, &claimed)) return false;
            hashSize(&vector, row.body.len);
            hashSize(&vector, row.url.len);
            hashSize(&vector, row.byte_start);
            vector.update(&.{@as(u8, @intFromBool(row.unknown_applicability))});
            vector.update(row.url);
            vector.update(&body);
        }
        return std.mem.eql(u8, &vector.finalResult(), &(try digest(base_pin)));
    }

    // OrdinaryConstructor.prepare must reject a supplied Cite value if this
    // check fails. Run once on immutable Book inputs, before projecting pages.
    fn valid(self: @This(), base: []const SharedStyleInput) !bool {
        if (self.literal_ipa_source_sha256 != null and !self.literalIpaProofMatches()) return false;
        if (!self.authorityMatches() or self.head_tmh_on_url.len != 491 or self.head_tmh_off_url.len != 467 or
            self.parsoid_css.len != 1387 or self.common_css.len != 2097 or self.ux_css.len != 380 or
            !try matches(self.head_tmh_on_url, "366392128a4f6a4c184170d51d5b35c7e13f117c526f225aaaff093a002a1232") or
            !try matches(self.head_tmh_off_url, "75b0dfe1be46e693cc8d16f59681858dc4b7867ea1cd7f4966d131092b2252f8") or
            !try matches(self.parsoid_css, "53b4194e77ffbb2531e5e3821b4fdbb17ea38a8d5594554db4a315c4d1987bc3") or
            !try matches(self.common_css, "3ff57177f0a953a74a78e4bb64b0f9b0459fd8c491339a55afc200543cb5da5c") or
            !try matches(self.ux_css, "61b35e4321a46b219a4dcc8a4ec9380fdba07f551f9c1074271a824c8a18338e") or
            !try baseValid(base)) return false;

        var on = Hash.init(.{});
        on.update(self.parsoid_css);
        on.update(self.common_css);
        var off = on;
        var on_bytes = self.parsoid_css.len + self.common_css.len;
        var off_bytes = on_bytes;
        for (base[0..base_head_count], 0..) |row, i| {
            on.update(row.body);
            on_bytes += row.body.len;
            if (i != 0) {
                off.update(row.body);
                off_bytes += row.body.len;
            }
        }
        return on_bytes == 244262 and off_bytes == 240939 and
            std.mem.eql(u8, &on.finalResult(), &(try digest(head_on_pin))) and
            std.mem.eql(u8, &off.finalResult(), &(try digest(head_off_pin)));
    }

    // Separate Cite selection receipt digest. The baseline module selection
    // continues to bind ordinary media. The future ordinary manifest/profile
    // digest independently binds the parsed Cite assets and baseline fields.
    fn compositionDigest(self: @This(), m: OrdinaryManifest) ![32]u8 {
        if (!self.authorityMatches()) return error.InvalidContainerDisclosureInput;
        var hash = Hash.init(.{});
        hash.update("wikidict.it.cite.module-selection.v1\x00");
        for ([_][]const u8{
            authority_pin, operands_pin, m.parser_constructor_sha256,
            m.initializer_sha256, m.namespace_sha256, m.module_selection_sha256,
        }) |pin| {
            const bytes = try digest(pin);
            hash.update(&bytes);
        }
        if (self.literal_ipa_source_sha256) |pin| {
            if (!self.literalIpaProofMatches()) return error.InvalidContainerDisclosureInput;
            hash.update("wikidict.it.cite.literal-ipa.v1\x00");
            hash.update(&(try digest(pin)));
        }
        return hash.finalResult();
    }

    fn writeHead(self: @This(), base: []const SharedStyleInput, tmh: bool, dst: *[8]S.Source) []const S.Source {
        const url = if (tmh) self.head_tmh_on_url else self.head_tmh_off_url;
        dst[0] = .{ .css = self.parsoid_css, .base_url = url };
        dst[1] = .{ .css = self.common_css, .base_url = url, .byte_start = self.parsoid_css.len };
        var offset = self.parsoid_css.len + self.common_css.len;
        const first: usize = if (tmh) 0 else 1;
        const head = base[first..base_head_count];
        for (head, dst[2 .. 2 + head.len]) |row, *out| {
            out.* = .{
                .css = row.body,
                .base_url = url,
                .byte_start = offset,
                .unknown_applicability = row.unknown_applicability,
            };
            offset += row.body.len;
        }
        return dst[0 .. 2 + head.len];
    }

    // Producer and consumer both use the same checked Book assets and base.
    // Required UX proof: citeUxEnvironment(a, m, raw, expanded) must succeed
    // for the original source pair before either caller selects this branch.
    // The ordered result starts UX at its logical module boundary and chooses
    // first in the dynamic bucket after proof. CSSOM rank remains unobserved.
    // document_url is the current job's checked workerDocumentUrl result.
    // Returned descriptors borrow dst; CSS and URLs borrow Book/job storage.
    fn project(self: @This(), base: []const SharedStyleInput, features: WorkerFeatures,
        document_url: []const u8, dst: *[max_sources]S.Source) ?[]const S.Source
    {
        if (!features.cite_active or base.len != base_count or
            document_url.len > max_url_bytes or
            !std.mem.startsWith(u8, document_url, "https://it.wiktionary.org/w/index.php?title=") or
            !std.mem.endsWith(u8, document_url, "&useskin=vector-2022")) return null;
        const head = self.writeHead(base, features.tmh, dst[0..8]);
        var count = head.len;
        dst[count] = .{ .css = self.ux_css, .base_url = document_url };
        count += 1;
        for (base[base_head_count..], base_head_count..) |row, i| {
            if (i == toc_slot and !features.toc) continue;
            dst[count] = .{
                .css = row.body,
                .base_url = row.url,
                .byte_start = row.byte_start,
                .unknown_applicability = row.unknown_applicability,
            };
            count += 1;
        }
        // At most eight head descriptors, one UX and seventeen base rows.
        const ordered = dst[0..count];
        var total: usize = 0;
        for (ordered) |source| {
            if (source.css.len > max_css_bytes - total or
                source.byte_start > max_css_bytes - source.css.len) return null;
            total += source.css.len;
        }
        return ordered;
    }

    fn exactSource(expected: S.Source, actual: S.Source) bool {
        return expected.byte_start == actual.byte_start and
            expected.unknown_applicability == actual.unknown_applicability and
            std.mem.eql(u8, expected.base_url, actual.base_url) and
            std.mem.eql(u8, expected.css, actual.css);
    }
};

// CDI-local, alongside the intake03 CiteSites. In the composed CiteSites,
// add "const skipAt = workerCiteSkipAt;" to expose the method spelling.
// Both offsets and src must come from the same completed whole-source walk.
const SourceOrigin = enum { raw, expanded };

fn workerCiteSkipAt(sites: CiteSites, src: []const u8, start: usize) ?usize {
    if (start != sites.ref_open and start != sites.sink) return null;
    _ = sites.note(src) orelse return null;
    return if (start == sites.ref_open) sites.ref_close + "</ref>".len else sites.sink + "<references/>".len;
}

// The marker line contains literal prose and possibly ordinary inline links.
// File/category/interwiki/fragment targets, template output, quote markup,
// entities, and external links cannot certify a visible prose prefix.
fn citeLatinLetter(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        (cp >= 0xc0 and cp <= 0xff and cp != 0xd7 and cp != 0xf7);
}

fn citeProseWords(bytes: []const u8, punctuation: []const u8) bool {
    if (std.mem.indexOf(u8, bytes, "''") != null) return false;
    const view = std.unicode.Utf8View.init(bytes) catch return false;
    var chars = view.iterator();
    while (chars.nextCodepoint()) |cp| {
        if (citeLatinLetter(cp) or (cp >= '0' and cp <= '9')) continue;
        if (cp > 127 or std.mem.indexOfScalar(u8, punctuation, @intCast(cp)) == null) return false;
    }
    return true;
}

fn citePlainLinkField(field: []const u8) bool {
    return std.mem.trim(u8, field, " ").len != 0 and citeProseWords(field, " '-");
}

fn citeProsePrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!(std.ascii.isAlphanumeric(prefix[0]) or prefix[0] >= 0x80 or prefix[0] == '[')) return false;
    var pos: usize = 0;
    while (pos < prefix.len) {
        const open = std.mem.indexOfScalarPos(u8, prefix, pos, '[') orelse prefix.len;
        const prose = prefix[pos..open];
        if (!citeProseWords(prose, " ,.!?;:'\"()-")) return false;
        // An inline scheme such as tel:123 and a magic identifier can
        // generate an external link even without bracket markup.
        var spans: encoder.document_ir.InlineIterator = .{ .input = prose };
        while (spans.next()) |span| if (span.kind == .external_link) return false;
        for ([_][]const u8{ "ISBN ", "RFC ", "PMID " }) |marker| {
            if (std.mem.indexOf(u8, prose, marker) != null) return false;
        }
        if (open == prefix.len) break;
        if (!std.mem.startsWith(u8, prefix[open..], "[[")) return false;
        const pair = encoder.wikitext_syntax.balanced(prefix, open) orelse return false;
        var fields = std.mem.splitScalar(u8, prefix[open + 2 .. pair.inner_end], '|');
        if (!citePlainLinkField(fields.next().?)) return false;
        if (fields.next()) |label| if (!citePlainLinkField(label) or fields.next() != null) return false;
        pos = pair.end;
    }
    return true;
}

const CiteWalk = struct {
    open: [64][]const u8 = undefined,
    depth: usize = 0,
    table_outer_depth: ?usize = null,
    ref_open: ?usize = null,
    ref_close: usize = 0,
    sink: ?usize = null,

    fn html(self: *@This(), line: []const u8, at: usize, tag: encoder.wikitext_syntax.Tag) bool {
        for ([_][]const u8{ "div", "span", "small", "i", "b", "sup", "sub", "kbd",
            "table", "tr", "td", "th", "br" }) |name| {
            if (tag.is(name)) break;
        } else return false;

        if (tag.closing) {
            if (tag.is("br")) return std.ascii.eqlIgnoreCase(line[at..tag.end], "</br>");
            if (line[tag.end - 2] == '/') return false;
            const depth = ordinaryHtmlClosingDepth(self.open[0..self.depth], tag) orelse return false;
            if (self.table_outer_depth) |outer| if (depth < outer) return false;
            self.depth = depth;
        } else {
            if (std.mem.indexOfAny(u8, tag.attrs, "[]") != null or !ordinaryTagAttributes(tag.attrs, tag)) return false;
            if (!tag.is("br")) {
                if (tag.self_closing or line[tag.end - 2] == '/' or self.depth == self.open.len) return false;
                self.open[self.depth] = tag.name;
                self.depth += 1;
            }
        }
        return true;
    }

    fn scanLine(self: *@This(), line: []const u8, offset: usize, origin: SourceOrigin) bool {
        const syntax = encoder.wikitext_syntax;
        var pos: usize = 0;
        if (std.mem.startsWith(u8, line, "{|")) {
            if (self.table_outer_depth != null) return false;
            self.table_outer_depth = self.depth;
            pos = 2;
        } else if (std.mem.startsWith(u8, line, "|}")) {
            const outer = self.table_outer_depth orelse return false;
            if (outer != self.depth) return false;
            // Only closes and horizontal whitespace may follow the delimiter.
            // Consume the suffix below so each name also matches the real stack.
            _ = workerTableTailDepth(line[2..], outer) orelse return false;
            self.table_outer_depth = null;
            pos = 2;
        }
        while (std.mem.indexOfAnyPos(u8, line, pos, "<>[]{}")) |at| {
            const rest = line[at..];
            switch (line[at]) {
                '<' => {
                    if (origin == .raw and std.mem.startsWith(u8, rest, "<!--")) {
                        pos = ordinaryRawCommentEnd(line, at) orelse return false;
                        continue;
                    }
                    const tag = syntax.tagAt(line, at) orelse return false;
                    const token = line[at..tag.end];
                    if (tag.is("ref")) {
                        if (self.ref_open != null or self.depth != 0 or self.table_outer_depth != null or
                            !std.mem.eql(u8, token, "<ref>") or !citeProsePrefix(line[0..at])) return false;
                        // The exact closer must end this line; the shared note
                        // accessor below validates every body byte, including
                        // rejecting any earlier closer, markup or hidden effect.
                        if (!std.mem.endsWith(u8, line[tag.end..], "</ref>")) return false;
                        self.ref_open = offset + at;
                        self.ref_close = offset + line.len - "</ref>".len;
                        return true;
                    }
                    if (tag.is("references")) {
                        if (self.ref_open == null or self.sink != null or self.depth != 0 or self.table_outer_depth != null or
                            !std.mem.eql(u8, line, "<references/>")) return false;
                        self.sink = offset;
                        return true;
                    }
                    if (!self.html(line, at, tag)) return false;
                    pos = tag.end;
                },
                '>' => {
                    if (!ordinarySpacedGreaterThan(line, at)) return false;
                    pos = at + 1;
                },
                '{' => {
                    if (origin != .raw or !std.mem.startsWith(u8, rest, "{{")) return false;
                    const pair = syntax.balanced(line, at) orelse return false;
                    const call = line[at..pair.end];
                    if (std.mem.indexOfAny(u8, call, "<>[]") != null) return false;
                    const Names = struct {
                        pub fn visit(_: @This(), _: OrdinarySourceCall) bool { return true; }
                    };
                    if (!ordinaryStaticCalls(call, 0, Names{})) return false;
                    pos = pair.end;
                },
                '[' => {
                    if (std.mem.startsWith(u8, rest, "[[")) {
                        const pair = syntax.balanced(line, at) orelse return false;
                        if (std.mem.indexOfAny(u8, line[at + 2 .. pair.inner_end], "<>[]{}") != null) return false;
                        pos = pair.end;
                    } else {
                        // Raw phonetic glosses and expanded external links occur
                        // elsewhere on Angola. Their classification belongs to
                        // the ordinary gates; their extent cannot cross markup.
                        const close = std.mem.indexOfAnyPos(u8, line, at + 1, "<>[]{}") orelse return false;
                        if (line[close] != ']') return false;
                        pos = close + 1;
                    }
                },
                else => return false,
            }
        }
        return true;
    }
};

fn workerCiteSites(source: []const u8, origin: SourceOrigin) ?CiteSites {
    if (source.len == 0 or source.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(source) or
        std.mem.indexOf(u8, source, "__") != null) return null;
    for (source) |c| if (std.ascii.isControl(c) and c != '\n' and c != '\t') return null;

    var walk = CiteWalk{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    while (lines.next()) |line| {
        if (!walk.scanLine(line, offset, origin)) return null;
        offset += line.len + 1;
    }
    if (walk.depth != 0 or walk.table_outer_depth != null) return null;
    const sites = CiteSites{
        .ref_open = walk.ref_open orelse return null,
        .ref_close = walk.ref_close,
        .sink = walk.sink orelse return null,
    };
    _ = sites.note(source) orelse return null;
    return sites;
}

// Logical UX insertion order is usable only after these source-derived
// nonmatch checks. This is not a physical CSSOM position or JSON absence bit.
const cite_ux_classes = [_][]const u8{
    "cite-accessibility-label", "mw-cite-targeted-backlink",
    "mw-cite-up-arrow-backlink", "mw-cite-up-arrow",
};

fn citeUxClassDomain(fixed: []const u8, prefixes: []const []const u8) bool {
    for (cite_ux_classes) |name| {
        if (classToken(fixed, name)) return false;
        for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    return true;
}

fn citeUxSourceSafe(a: std.mem.Allocator, source: []const u8) !bool {
    // Reject even unrelated text spelling these identifiers. This conservative
    // document-wide condition includes every authored owner and descendant,
    // including tokens composed through the selected single-pass decoder.
    const decoded = try @import("xml_decode").decodeSinglePassAlloc(a, source);
    defer a.free(decoded);
    for ([_][]const u8{ source, decoded }) |bytes| {
        for (cite_ux_classes) |name| if (std.ascii.findIgnoreCase(bytes, name) != null) return false;
        // Prevent authored markup from impersonating Cite's named/reused
        // reference or backlink activation paths in the selected initializer.
        for ([_][]const u8{ "mw-cite-", "cite_ref-", "cite_note-" }) |name|
            if (std.ascii.findIgnoreCase(bytes, name) != null) return false;
    }
    return true;
}

fn citeUxEnvironment(a: std.mem.Allocator, m: OrdinaryManifest,
    raw: []const u8, expanded: []const u8) !bool
{
    // These exact source closures generate only the witnessed normal parser,
    // SECTION and collapsible toggle/bracket/run class writers. The one plain
    // anonymous ref has one backlink: Cite a11y writes only aria/title, and
    // highlighting returns before the reused-named-reference class writers.
    if (!std.mem.eql(u8, m.parser_constructor_sha256,
        "26d7e0bfd243fd474712e523da978f506e328b48c21a35e711fa50e0141ac846") or
        !std.mem.eql(u8, m.initializer_sha256,
        "fc9e6a0cf4bc0df0715e43fbff8f6730bf6f28e2969a466ed1c24f75492c1307")) return false;
    if (!citeUxClassDomain(m.font.parser_classes, &.{})) return false;
    for (m.font.section_attributes) |name| if (std.ascii.eqlIgnoreCase(name, "class")) return false;
    for (m.shell.path) |step| {
        // A generic variable class attribute is not a bounded class domain.
        for (step.variable_attributes) |name| if (std.ascii.eqlIgnoreCase(name, "class")) return false;
        var classes: []const u8 = "";
        for (step.fixed_attributes) |attr| if (std.ascii.eqlIgnoreCase(attr.name, "class")) {
            if (classes.len != 0) return false;
            classes = attr.value;
        };
        if (!citeUxClassDomain(classes, step.extra_class_prefixes)) return false;
    }
    return try citeUxSourceSafe(a, raw) and try citeUxSourceSafe(a, expanded);
}

const CiteReceiptEvidence = struct {
    // Like the expansion buffers, the issuing job's namespace registry must
    // remain live through bindWithStyleReceipt.
    namespaces: ?*const namespace_registry.Registry = null,
    ordinal: u64,
    id: P.PageIdentity,
    title: []const u8,
    display: []const u8,
    payload: P.BoundPageEffects,
};

const CitePair = struct { raw: CiteSites, expanded: CiteSites };

fn citeEvidencePair(a: std.mem.Allocator, profile: [32]u8,
    raw: []const u8, expanded: []const u8, evidence: CiteReceiptEvidence) !?CitePair
{
    const data = evidence.payload;
    if (data.collector.len == 0 or data.collector.len > P.max_page_effect_bytes or evidence.id.namespace != 0 or
        !std.mem.eql(u8, &data.binding, &P.pageEffectBinding(profile, evidence.ordinal, evidence.id,
            evidence.title, raw, expanded, data.collector))) return null;
    const phase = std.json.parseFromSliceLeaky(WorkerPhase, a, data.collector, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!workerPhaseMatches(phase, "complete", evidence.ordinal, evidence.id,
        evidence.title, raw, expanded, evidence.display)) return null;
    const pair: CitePair = .{ .raw = workerCiteSites(raw, .raw) orelse return null,
        .expanded = workerCiteSites(expanded, .expanded) orelse return null };
    if (!citePhaseAndSites(phase, raw, pair.raw, expanded, pair.expanded, evidence.display, &.{})) return null;
    return pair;
}

fn citeSourceEqual(a: S.Source, b: S.Source) bool {
    return a.byte_start == b.byte_start and a.unknown_applicability == b.unknown_applicability and
        std.mem.eql(u8, a.css, b.css) and std.mem.eql(u8, a.base_url, b.base_url);
}

fn citePageScope(a: std.mem.Allocator, m: *const OrdinaryManifest,
    shared: *const S.DisclosureSharedProfile, book: *const Book, raw: []const u8,
    expanded: []const u8, issued: OrdinaryStyleReceipt) !?*const PC.ContainerDisclosureStyleScope
{
    // Gallery and Cite are disjoint source roles, even if a caller combines
    // independently valid receipt fields.
    if (issued.gallery != null or issued.gallery_authority != null) return null;
    const input = book.input;
    const recipe = m.worker_projection orelse return null;
    const assets = recipe.cite orelse return null;
    if (!try assets.valid(input.shared.?.styles)) return null;
    const features = issued.worker_features orelse return null;
    const evidence = issued.cite_evidence orelse return null;
    if (!features.cite_active or issued.imports.len != 0 or
        issued.raw.ptr != raw.ptr or issued.raw.len != raw.len or
        issued.expanded.ptr != expanded.ptr or issued.expanded.len != expanded.len or
        !std.mem.eql(u8, &issued.module_selection_sha256, &(try digest(m.module_selection_sha256))) or
        !std.mem.eql(u8, &issued.placement_sha256, &(try digest(m.local_registry.?.placement_sha256)))) return null;
    const pair = (try citeEvidencePair(a, try digest(input.shared.?.reference.ordinary_manifest_sha256.?),
        raw, expanded, evidence)) orelse return null;
    if (!ordinaryReceiptSourceWithCite(m.calls, raw, expanded, &.{}, pair) or
        !try citeUxEnvironment(a, m.*, raw, expanded)) return null;
    const url = issued.document_base orelse return null;
    if (!std.mem.eql(u8, url, try workerDocumentUrl(a, evidence.title, evidence.id.revision_id))) return null;
    if (!std.mem.eql(u8, &(issued.cite_selection_sha256 orelse return null),
        &(try assets.compositionDigest(m.*)))) return null;
    var projection: [32]S.Source = undefined;
    const ns = evidence.namespaces orelse return null;
    if (!std.mem.eql(u8, &ns.source_sha256, &(try digest(input.namespace_sha256)))) return null;
    const actual_features = (try book.pageFeatures(a, ns, recipe, evidence.id, evidence.title,
        raw, expanded, pair.expanded)) orelse return null;
    if (!std.meta.eql(actual_features, features)) return null;
    const expected = assets.project(input.shared.?.styles, actual_features, url, &projection) orelse return null;
    if (issued.ordered.len != expected.len or issued.placed_keys.len != expected.len) return null;
    var total: usize = 0;
    for (issued.ordered, expected, issued.placed_keys) |actual, wanted, key| {
        if (key != null or !citeSourceEqual(actual, wanted) or actual.css.len > 768 * 1024 - total) return null;
        total += actual.css.len;
    }
    // Cite changes bytes, bases and offsets even if another variant were to
    // have the same length as the base vector. Never reuse by count alone.
    const styles = try a.create(S.Profile);
    styles.* = S.parseSourcesForTargetAlloc(a, issued.ordered, .screen) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const profile = try a.create(S.DisclosureSharedProfile);
    profile.* = shared.*;
    profile.styles = styles;
    profile.owner_attribute_projection = if (m.owner_attributes) |*known| &known.projection else null;
    const resolved = (try S.prepareDisclosureConstructorTransfer(a, styles, m.font, m.shell,
        profile.placement_shell.?)) orelse return null;
    profile.boundary.?.custom_environment = resolved.environment;
    const font = try a.create(S.DisclosureFontTransfer);
    font.* = resolved.font;
    if (m.inline_hit) |*hit| font.inline_hit = &hit.source;
    var scope = PC.ContainerDisclosureStyleScope.fromPageSourcesAndFont(expanded, profile,
        issued.ordered, font) orelse return null;
    scope.html_underline = m.underline;
    const result = try a.create(PC.ContainerDisclosureStyleScope);
    result.* = scope;
    return result;
}

// A complete literal bracket after an already-scanned ordinary WikiLink in a
// translation item. This adds no link or phonetic interpretation. The enclosing
// scanner still owns every preceding and following byte and all later guards.
fn citeLiteralIpaBracket(line: []const u8, start: usize, end: usize) bool {
    if (!std.mem.startsWith(u8, line, ":*") or start < 3 or end <= start + 1 or
        end >= line.len or line[start] != '[' or line[end] != ']' or
        end - start - 1 > 128 or !std.mem.eql(u8, line[start - 3 .. start], "]] ")) return false;
    const body = line[start + 1 .. end];
    var pos: usize = 0;
    var letter_seen = false;
    var phonetic_seen = false;
    var in_group = false;
    var group_letter = false;
    var after_letter = false;
    var pending_stress = false;
    while (pos < body.len) {
        const size = std.unicode.utf8ByteSequenceLength(body[pos]) catch return false;
        if (size > body.len - pos) return false;
        const cp = std.unicode.utf8Decode(body[pos .. pos + size]) catch return false;
        pos += size;
        if ((cp >= 'a' and cp <= 'z') or cp == 0x014b or (cp >= 0x0250 and cp <= 0x02af)) {
            letter_seen = true;
            phonetic_seen = phonetic_seen or cp > 0x7f;
            if (in_group) group_letter = true;
            after_letter = true;
            pending_stress = false;
        } else if (cp == 0x02c8 or cp == 0x02cc) {
            if (pending_stress) return false;
            phonetic_seen = true;
            pending_stress = true;
            after_letter = false;
        } else if (cp >= 0x0300 and cp <= 0x036f) {
            if (!after_letter or pending_stress) return false;
            phonetic_seen = true;
        } else if (cp == '(') {
            if (in_group) return false;
            in_group = true;
            group_letter = false;
            after_letter = false;
        } else if (cp == ')') {
            if (!in_group or !group_letter or pending_stress) return false;
            in_group = false;
            after_letter = false;
        } else return false;
    }
    return letter_seen and phonetic_seen and !in_group and !pending_stress;
}

fn citeLiteralIpaAllowed(cite: ?CiteSites, assets: ?CiteAssets,
    line: []const u8, start: usize, end: usize) bool
{
    if (cite == null) return false;
    const selected = assets orelse return false;
    if (!selected.literalIpaProofMatches()) return false;
    return citeLiteralIpaBracket(line, start, end);
}
