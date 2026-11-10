const std = @import("std");
const namespaces = @import("namespace_registry");
const encoder = @import("encoder");
const dump_source = @import("wikimedia_dump");
const types = encoder.presentation_types;
const A = std.mem.Allocator;
const Value = std.json.Value;
const max_metadata: usize = 64 * 1024 * 1024;
const max_response: usize = 2 * 1024 * 1024;
const max_records = 250_000;
const accepted_core = "0470f6c99a6456a366635bf25a517a1f951de6f5";
const compatible_core = "ead780177c5a02aa63ac6fd3a50977df9719fe63";
const current_core = "f45897451256aa3799aecc5d7ee320ade22beaec";
// Only the retained twenty handler/API/config leaves and each response's
// complete media registration are covered; no HTML/parser-hook equivalence.
const response_core = "889108d826914948ce34af4d0457bf048cfb0398";
fn responseEpoch(core: []const u8) bool { return equal(core, current_core) or equal(core, response_core); }
fn acceptedResponseCore(core: []const u8, epochs: bool) bool {
    return acceptedCore(core) or (epochs and equal(core, response_core));
}
fn compatibleResponseCore(left: []const u8, right: []const u8, epochs: bool) bool {
    return compatibleCore(left, right) or (epochs and responseEpoch(left) and responseEpoch(right));
}
// Exact handler/File/Linker/API/service byte identity is retained in the source
// profile binding. Each defaults/file observation keeps its original core.
fn acceptedCore(core: []const u8) bool { return equal(core, accepted_core) or equal(core, compatible_core) or equal(core, current_core); }
fn compatibleCore(left: []const u8, right: []const u8) bool {
    return equal(left, right) or (acceptedCore(left) and acceptedCore(right));
}
const invalid = error.InvalidFigureSizingSource;

pub const Record = struct {
    canonical_file: []const u8,
    file_sha1: []const u8,
    file_timestamp: []const u8,
    // ApiQueryImageInfo uses File.getWidth/getHeight: logical axes, including
    // the selected handler's orientation, not decoded bitmap backing axes.
    original_width: u32,
    original_height: u32,
    format: types.FigureFormat,
    width_px: u32,
    height_px: ?u32,
    sizing: types.FigureSizingPolicy,
    proof_kind: []const u8,
};
const Document = struct {
    schema: []const u8,
    wiki: []const u8,
    content_language: []const u8,
    core_revision: []const u8,
    namespace_registry_sha256: []const u8,
    observation_utc: []const u8,
    raw_sha256: []const u8,
    generator_sha256: []const u8,
    source_profile: Value,
    records: []const Record,
};
const FileState = enum { eligible, missing, unsupported };
const FileFact = struct {
    requested_file: []const u8,
    canonical_file: []const u8,
    state: FileState,
    batch: u32,
    file_sha1: []const u8,
    file_timestamp: []const u8,
    original_width: u32,
    original_height: u32,
    mime: []const u8,
    mediatype: []const u8,
    observed_svg_width_px: ?u32 = null,
    observed_svg_heights: ?[]const SvgHeightObservation = null,
    observed_batch: ?u32 = null,
};
const FilesDocument = struct {
    schema: []const u8,
    wiki: []const u8,
    content_language: []const u8,
    core_revision: []const u8,
    namespace_registry_sha256: []const u8,
    raw_sha256: []const u8,
    generator_sha256: []const u8,
    source_profile: Value,
    records: []const FileFact,
};
const RawFileBatch = struct {
    requests: []const []const u8,
    response: []const u8,
    observed_svg_width_px: ?u32 = null,
    observed_svg_occurrences: ?[]const RawSvgHeightObservation = null,
    tiff_metadata_response: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), json_writer: anytype) !void {
        if (self.tiff_metadata_response) |companion_bytes| return json_writer.write(.{
            .requests = self.requests, .response = self.response,
            .observed_svg_width_px = self.observed_svg_width_px,
            .observed_svg_occurrences = self.observed_svg_occurrences,
            .tiff_metadata_response = companion_bytes,
        });
        // Preserve the old record shape; absent is distinct from JSON null.
        return json_writer.write(.{ .requests = self.requests, .response = self.response,
            .observed_svg_width_px = self.observed_svg_width_px,
            .observed_svg_occurrences = self.observed_svg_occurrences });
    }
};
const RawFileBatches = struct { schema: []const u8, batches: []const RawFileBatch };
const max_batches = 10_000;
// File-level observations use a separate generator contract from occurrence v1.
pub const file_generator_sha256 = "a6c9ffe29ead25cc5a0ffa4796bfa2c9ffd10cca5a673c56593c181356d2af87";
const occurrence_generator_sha256 = "07321d59004f3d27f5ff9180995c9d0ab6d415ba815303aa176694e6b9eb8db9";
const lean_svg_generator_sha256 = "291815b430843d165791a59bccfe650c186772e6998fb60c4705f38638c196a2";
fn svgOccurrenceGenerator(value: []const u8) bool {
    return equal(value, file_generator_sha256) or equal(value, occurrence_generator_sha256) or equal(value, lean_svg_generator_sha256);
}
const previous_stream_generator_sha256 = "3b352a42f22e51eef1415800916ab8ace31407c6cc01291981f698970d060a15";
fn streamGenerator(value: []const u8) bool {
    return svgOccurrenceGenerator(value) or equal(value, previous_stream_generator_sha256) or
        equal(value, "7bce7ec0bd0acdf6a9d726ed50c1e85a64bc089731d0347d048f1787003d4c0b") or
        equal(value, "fab1f2a019e57235e7e2b562bb0ca01a6adeb5fa0686cbd28535157b494f0d37") or
        equal(value, "fa3c8823855b1673947c0fd3ea522bbbe276ef5fd59e2669b18b8906914ad74e");
}
fn observedFileGenerator(value: []const u8) bool {
    return streamGenerator(value) or
        equal(value, "ed4aade60ba51fe013fa99a53f4e190d0958a54bb4be5a8811082bda99be5783");
}
fn fileGenerator(value: []const u8) bool {
    return observedFileGenerator(value) or equal(value, "5275665a3638480185984f0702b4248bc42ba8cb5a24428ea01a8eb1e6f0c550");
}

// A known replay contract selects validators; the producer digest stays provenance.
pub const replay_contract = "wikidict.figure-files-replay.v1";
pub const replay_contract_v2 = "wikidict.figure-files-replay.v2";
pub const replay_contract_v3 = "wikidict.figure-files-replay.v3";
const raw_record_encoding = "zstd-jsonl-v1";
fn explicitReplayContract(value: Value) !bool {
    if (value != .object) return invalid;
    const contract = value.object.get("replay_contract") orelse return false;
    if (contract != .string or (!equal(contract.string, replay_contract) and !equal(contract.string, replay_contract_v2) and !equal(contract.string, replay_contract_v3))) return invalid;
    return true;
}
fn responseEpochContract(value: Value) bool {
    if (value != .object) return false;
    const contract = value.object.get("replay_contract") orelse return false;
    return contract == .string and equal(contract.string, replay_contract_v3);
}
fn replayDocumentShape(a: A, value: Value) !Value {
    if (!try explicitReplayContract(value)) return value;
    var shape: Value = .{ .object = .empty };
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        if (!equal(entry.key_ptr.*, "replay_contract"))
            try shape.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }
    return shape;
}

pub fn permitsLargeRawInput(a: A, projection: []const u8) A.Error!bool {
    // Called only after the ordinary 2 MiB raw-file limit rejected the input.
    // This selects a bounded transport envelope, never semantic acceptance.
    preflight(projection, true) catch return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const value = std.json.parseFromSliceLeaky(Value, temp, projection, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const contract = explicitReplayContract(value) catch return false;
    const shape = replayDocumentShape(temp, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const doc = std.json.parseFromValueLeaky(FilesDocument, temp, shape, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return equal(doc.schema, "wikidict.figure-sizing-files.v1") and
        (contract or fileGenerator(doc.generator_sha256)) and lowerHex(doc.generator_sha256, 64) and
        lowerHex(doc.core_revision, 40) and lowerHex(doc.namespace_registry_sha256, 64) and
        lowerHex(doc.raw_sha256, 64) and doc.records.len <= max_records and
        (if (doc.records.len == 0) doc.source_profile == .null else
            acceptedResponseCore(doc.core_revision, responseEpochContract(value)) and doc.source_profile == .object);
}

fn preflightFileBatches(bytes: []const u8) !void {
    if (bytes.len > max_metadata or !std.unicode.utf8ValidateSlice(bytes)) return invalid;
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    var objects: usize = 0;
    var arrays: usize = 0;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) { escaped = false; continue; }
            if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 8) return invalid;
                if (byte == '{') objects += 1 else arrays += 1;
                if (objects > max_batches + 1 or arrays > max_batches + 1) return invalid;
            },
            '}', ']' => { if (depth == 0) return invalid; depth -= 1; },
            else => {},
        }
    }
    if (quoted or escaped or depth != 0) return invalid;
}


const SvgHeightObservation = struct {
    wiki: []const u8, title: []const u8, options: []const u8,
    height_px: u32, observed_width_px: u32, observed_height_px: u32, batch: u32,
    parse_core_binding_proven: bool,
};
const RawSvgHeightObservation = struct { request: []const u8, receipt: []const u8, response: []const u8 };
const SvgHeightAuthority = struct { original_width: u32, observation: *const SvgHeightObservation };
const ParsedSvgHeight = struct { canonical_file: []const u8, title: []const u8, options: []const u8, height: u32, html: []const u8 };

fn occurrenceText(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn svgHeightKey(a: A, wiki: []const u8, title: []const u8, file: []const u8, options: []const u8, height: u32) ![]u8 {
    if (!occurrenceText(wiki) or !occurrenceText(title) or !occurrenceText(file) or !occurrenceText(options) or height == 0) return invalid;
    return std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}\x00{s}\x00{d}", .{ wiki, title, file, options, height });
}
fn svgHeightFit(width: u32, original_height: u32, requested_height: u32) ?u32 {
    if (width == 0 or requested_height == 0 or requested_height >= original_height) return null;
    const w: f64 = @floatFromInt(width); const h: f64 = @floatFromInt(original_height); const bound: f64 = @floatFromInt(requested_height);
    const ideal = w * bound / h; const up = @ceil(ideal);
    const selected = if (@floor(up * h / w + 0.5) > bound) @floor(ideal) else up;
    return @intFromFloat(@max(@as(f64, 1), selected));
}
fn occurrenceFlag(value: Value, name: []const u8, expected: bool) !void {
    const item = try field(value, name);
    if (item != .bool or item.bool != expected) return invalid;
}
fn occurrenceUrlPart(a: A, source: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < source.len) : (i += 1) if (source[i] == '%') {
        if (i + 2 >= source.len or !std.ascii.isHex(source[i + 1]) or !std.ascii.isHex(source[i + 2])) return invalid;
        i += 2;
    };
    const owned = try a.dupe(u8, source);
    for (owned) |*byte| if (byte.* == '+') { byte.* = ' '; };
    const decoded = std.Uri.percentDecodeInPlace(owned);
    if (!std.unicode.utf8ValidateSlice(decoded)) return invalid;
    return decoded;
}
fn occurrenceRequestUrl(a: A, url: []const u8, server: []const u8, query: Value) !void {
    const prefix = try std.fmt.allocPrint(a, "https:{s}/w/api.php?", .{server});
    if (url.len > 7168 or !std.mem.startsWith(u8, url, prefix) or std.mem.indexOfScalar(u8, url, '#') != null) return invalid;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return invalid;
        const name = try occurrenceUrlPart(a, part[0..eq]); const value = try occurrenceUrlPart(a, part[eq + 1 ..]);
        if ((try used.getOrPut(a, name)).found_existing or !equal(try string(query, name), value)) return invalid;
    }
    if (query != .object or used.count() != query.object.count()) return invalid;
}
fn parseSvgHeightObservation(a: A, ns: *const namespaces.Registry, server: []const u8, raw: RawSvgHeightObservation) !ParsedSvgHeight {
    for ([_][]const u8{ raw.request, raw.receipt, raw.response }) |bytes| try preflight(bytes, false);
    const request = try std.json.parseFromSliceLeaky(Value, a, raw.request, .{ .allocate = .alloc_always });
    const receipt = try std.json.parseFromSliceLeaky(Value, a, raw.receipt, .{ .allocate = .alloc_always });
    const response = try std.json.parseFromSliceLeaky(Value, a, raw.response, .{ .allocate = .alloc_always });
    try occurrenceFlag(request, "controlled_single_token", true);
    try occurrenceFlag(request, "full_historical_page_render", false);
    try occurrenceFlag(receipt, "accepted", true);
    if (try positive(request, "request_count") != 1 or try positive(receipt, "request_count") != 1 or
        try positive(receipt, "status") != 200 or try positive(receipt, "response_bytes") != raw.response.len or
        !digestMatches(raw.response, try string(receipt, "response_sha256"))) return invalid;
    const query = try field(request, "query");
    if (query != .object or query.object.count() != 8) return invalid;
    for ([_][2][]const u8{ .{"action","parse"}, .{"contentmodel","wikitext"}, .{"format","json"},
        .{"formatversion","2"}, .{"maxlag","5"}, .{"prop","text"} }) |pair|
        if (!equal(try string(query, pair[0]), pair[1])) return invalid;
    try occurrenceRequestUrl(a, try string(request, "url"), server, query);
    const title = try string(query, "title"); const token = try string(query, "text");
    if (!occurrenceText(title) or !occurrenceText(token) or !std.mem.startsWith(u8, token, "[[") or !std.mem.endsWith(u8, token, "]]")) return invalid;
    const inner = token[2 .. token.len - 2];
    if (std.mem.indexOfAny(u8, inner, "[]") != null) return invalid;
    const pipe = std.mem.indexOfScalar(u8, inner, '|') orelse return invalid;
    const canonical = try canonicalFile(a, ns, inner[0..pipe]);
    const options = inner[pipe + 1 ..];
    const end = std.mem.indexOfScalar(u8, options, '|') orelse return invalid;
    const dimension = options[0..end];
    if (dimension.len < 4 or dimension[0] != 'x' or !std.mem.endsWith(u8, dimension, "px")) return invalid;
    const digits = dimension[1 .. dimension.len - 2];
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return invalid;
    const height = std.fmt.parseInt(u32, digits, 10) catch return invalid;
    if (height == 0) return invalid;
    if (response != .object or response.object.count() != 1) return invalid;
    const parsed = try field(response, "parse");
    if (parsed != .object or parsed.object.count() != 3 or !equal(try string(parsed, "title"), title) or try positive(parsed, "pageid") == 0) return invalid;
    return .{ .canonical_file = canonical, .title = title, .options = options, .height = height, .html = try string(parsed, "text") };
}

// Private source-only helper for figure_sizing.zig. Requires std, A,
// namespaces, encoder and the existing owned-result canonicalFile().
// Request/title/source/receipt authentication and PHP fit are caller duties.
const SvgHtmlProof = struct {
    const Tag = encoder.wikitext_syntax.Tag;

    fn whitespace(bytes: []const u8) bool {
        return std.mem.trim(u8, bytes, " \t\r\n").len == 0;
    }
    fn attrs(tag: Tag) !void {
        // tagAt deliberately does not validate duplicate or malformed attrs.
        // Accept only complete quoted attribute assignments from API HTML.
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        var at: usize = 0;
        while (at < tag.attrs.len) {
            if (!std.ascii.isWhitespace(tag.attrs[at])) return error.InvalidSvgHtmlEvidence;
            while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
            if (at == tag.attrs.len) break;
            const start = at;
            while (at < tag.attrs.len and (std.ascii.isAlphanumeric(tag.attrs[at]) or tag.attrs[at] == '-' or tag.attrs[at] == '_' or tag.attrs[at] == ':')) : (at += 1) {}
            if (start == at or count == names.len) return error.InvalidSvgHtmlEvidence;
            const name = tag.attrs[start..at];
            for (names[0..count]) |old| if (std.ascii.eqlIgnoreCase(old, name)) return error.InvalidSvgHtmlEvidence;
            names[count] = name;
            count += 1;
            if (std.ascii.eqlIgnoreCase(name, "style") or
                (name.len >= 2 and std.ascii.eqlIgnoreCase(name[0..2], "on"))) return error.InvalidSvgHtmlEvidence;
            while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
            if (at == tag.attrs.len or tag.attrs[at] != '=') return error.InvalidSvgHtmlEvidence;
            at += 1;
            while (at < tag.attrs.len and std.ascii.isWhitespace(tag.attrs[at])) : (at += 1) {}
            if (at == tag.attrs.len or (tag.attrs[at] != '\'' and tag.attrs[at] != '"')) return error.InvalidSvgHtmlEvidence;
            const quote = tag.attrs[at];
            at += 1;
            while (at < tag.attrs.len and tag.attrs[at] != quote) : (at += 1) {
                if (tag.attrs[at] == '<' or tag.attrs[at] == '>' or tag.attrs[at] == 0) return error.InvalidSvgHtmlEvidence;
            }
            if (at == tag.attrs.len) return error.InvalidSvgHtmlEvidence;
            at += 1;
        }
    }
    fn number(tag: Tag, key: []const u8) !u32 {
        const raw = tag.attr(key) orelse return error.InvalidSvgHtmlEvidence;
        if (raw.len == 0 or raw.len > 10) return error.InvalidSvgHtmlEvidence;
        for (raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSvgHtmlEvidence;
        const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidSvgHtmlEvidence;
        if (value == 0) return error.InvalidSvgHtmlEvidence;
        return value;
    }
    fn hex(byte: u8) !u8 {
        return switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => error.InvalidSvgHtmlEvidence,
        };
    }
    fn href(a: A, ns: *const namespaces.Registry, raw: []const u8, expected: []const u8) !void {
        if (!std.mem.startsWith(u8, raw, "/wiki/") or raw.len <= 6 or raw.len > 8192 or
            std.mem.indexOfAny(u8, raw, "?#&\r\n\t\\") != null) return error.InvalidSvgHtmlEvidence;
        const encoded = raw[6..];
        const decoded = try a.alloc(u8, encoded.len);
        defer a.free(decoded);
        var at: usize = 0;
        var used: usize = 0;
        while (at < encoded.len) {
            var byte = encoded[at];
            if (byte == '%') {
                if (encoded.len - at < 3) return error.InvalidSvgHtmlEvidence;
                byte = (try hex(encoded[at + 1])) * 16 + (try hex(encoded[at + 2]));
                at += 3;
            } else at += 1;
            if (std.ascii.isControl(byte) or byte == '?' or byte == '#' or byte == '\\') return error.InvalidSvgHtmlEvidence;
            decoded[used] = byte;
            used += 1;
        }
        if (!std.unicode.utf8ValidateSlice(decoded[0..used])) return error.InvalidSvgHtmlEvidence;
        const actual = try canonicalFile(a, ns, decoded[0..used]);
        defer a.free(actual);
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidSvgHtmlEvidence;
    }
};

fn observedSvgHtml(a: A, ns: *const namespaces.Registry, html: []const u8, canonical: []const u8, original_width: u32, original_height: u32, requested_height: u32) !u32 {
    if (html.len == 0 or html.len > max_response or original_width == 0 or original_height == 0 or requested_height == 0 or
        !std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return error.InvalidSvgHtmlEvidence;
    // A deliberately small evidence grammar, not a general HTML/DOM parser:
    // optional root DIV, one FIGURE, its A/IMG, and plain FIGCAPTION.
    var stack: [4][]const u8 = undefined;
    var depth: usize = 0;
    var roots: usize = 0;
    var figures: usize = 0;
    var links: usize = 0;
    var images: usize = 0;
    var captions: usize = 0;
    var observed_width: u32 = 0;
    var at: usize = 0;
    while (at < html.len) {
        if (std.mem.startsWith(u8, html[at..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, at + 4, "-->") orelse return error.InvalidSvgHtmlEvidence;
            if (std.mem.indexOf(u8, html[at + 4 .. end], "--") != null) return error.InvalidSvgHtmlEvidence;
            at = end + 3;
            continue;
        }
        if (html[at] != '<') {
            const end = std.mem.indexOfScalarPos(u8, html, at, '<') orelse html.len;
            const in_caption = depth != 0 and std.ascii.eqlIgnoreCase(stack[depth - 1], "figcaption");
            if (!in_caption and !SvgHtmlProof.whitespace(html[at..end])) return error.InvalidSvgHtmlEvidence;
            at = end;
            continue;
        }
        const tag = encoder.wikitext_syntax.tagAt(html, at) orelse return error.InvalidSvgHtmlEvidence;
        if (tag.end <= at or tag.end > html.len) return error.InvalidSvgHtmlEvidence;
        if (tag.end >= 2 and html[tag.end - 2] == '/' and !tag.is("img")) return error.InvalidSvgHtmlEvidence;
        try SvgHtmlProof.attrs(tag);
        if (tag.closing) {
            if (tag.self_closing or !SvgHtmlProof.whitespace(tag.attrs) or depth == 0 or
                !std.ascii.eqlIgnoreCase(stack[depth - 1], tag.name)) return error.InvalidSvgHtmlEvidence;
            if (tag.is("div") and figures != 1) return error.InvalidSvgHtmlEvidence;
            depth -= 1;
            at = tag.end;
            continue;
        }
        const parent: []const u8 = if (depth == 0) "" else stack[depth - 1];
        if (tag.is("div")) {
            if (depth != 0 or roots != 0 or figures != 0 or tag.self_closing) return error.InvalidSvgHtmlEvidence;
            roots += 1;
        } else if (tag.is("figure")) {
            if (figures != 0 or tag.self_closing or (depth != 0 and !std.ascii.eqlIgnoreCase(parent, "div")) or
                !std.mem.eql(u8, tag.attr("typeof") orelse return error.InvalidSvgHtmlEvidence, "mw:File/Thumb")) return error.InvalidSvgHtmlEvidence;
            figures += 1;
        } else if (tag.is("a")) {
            if (!std.ascii.eqlIgnoreCase(parent, "figure") or links != 0 or captions != 0 or tag.self_closing) return error.InvalidSvgHtmlEvidence;
            try SvgHtmlProof.href(a, ns, tag.attr("href") orelse return error.InvalidSvgHtmlEvidence, canonical);
            if (!std.mem.eql(u8, tag.attr("class") orelse return error.InvalidSvgHtmlEvidence, "mw-file-description")) return error.InvalidSvgHtmlEvidence;
            links += 1;
        } else if (tag.is("img")) {
            if (!std.ascii.eqlIgnoreCase(parent, "a") or images != 0 or links != 1 or
                !std.mem.eql(u8, tag.attr("class") orelse return error.InvalidSvgHtmlEvidence, "mw-file-element")) return error.InvalidSvgHtmlEvidence;
            if (try SvgHtmlProof.number(tag, "data-file-width") != original_width or
                try SvgHtmlProof.number(tag, "data-file-height") != original_height or
                try SvgHtmlProof.number(tag, "height") != requested_height) return error.InvalidSvgHtmlEvidence;
            const src = tag.attr("src") orelse return error.InvalidSvgHtmlEvidence;
            if (src.len == 0) return error.InvalidSvgHtmlEvidence;
            observed_width = try SvgHtmlProof.number(tag, "width");
            images += 1;
            at = tag.end;
            continue; // IMG is void, with or without the XHTML slash.
        } else if (tag.is("figcaption")) {
            if (!std.ascii.eqlIgnoreCase(parent, "figure") or captions != 0 or images != 1 or tag.self_closing) return error.InvalidSvgHtmlEvidence;
            captions += 1;
        } else return error.InvalidSvgHtmlEvidence;
        // Width/height on enclosing containers are not image geometry evidence.
        if (tag.attr("width") != null or tag.attr("height") != null) return error.InvalidSvgHtmlEvidence;
        if (depth == stack.len) return error.InvalidSvgHtmlEvidence;
        stack[depth] = tag.name;
        depth += 1;
        at = tag.end;
    }
    if (depth != 0 or figures != 1 or links != 1 or images != 1 or captions != 1 or observed_width == 0) return error.InvalidSvgHtmlEvidence;
    return observed_width;
}

// Context observations belong only to the canonical requested row; aliases
// still compare the same physical identity without acquiring those observations.
fn sameFileFact(left: FileFact, right: FileFact) bool {
    return left.state == right.state and equal(left.canonical_file, right.canonical_file) and
        equal(left.file_sha1, right.file_sha1) and equal(left.file_timestamp, right.file_timestamp) and
        left.original_width == right.original_width and left.original_height == right.original_height and
        equal(left.mime, right.mime) and equal(left.mediatype, right.mediatype) and
        left.observed_svg_width_px == right.observed_svg_width_px and left.observed_batch == right.observed_batch;
}

fn equal(left: []const u8, right: []const u8) bool { return std.mem.eql(u8, left, right); }
fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return invalid;
    return value.object.get(name) orelse return invalid;
}
fn string(value: Value, name: []const u8) ![]const u8 {
    const result = try field(value, name);
    if (result != .string) return invalid;
    return result.string;
}
fn positive(value: Value, name: []const u8) !u32 {
    const result = try field(value, name);
    if (result != .integer or result.integer <= 0) return invalid;
    return std.math.cast(u32, result.integer) orelse return invalid;
}
fn nonnegativeInteger(value: Value) bool {
    if (value == .integer) return value.integer >= 0;
    if (value != .number_string or value.number_string.len == 0) return false;
    for (value.number_string) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn digestMatches(bytes: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return equal(&std.fmt.bytesToHex(digest, .lower), expected);
}
fn lowerHex(value: []const u8, count: usize) bool {
    if (value.len != count) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}
// Allocation bounds precede JSON materialization. Braces inside strings do not
// count; JSON syntax and all field shapes are checked independently below.
fn preflight(bytes: []const u8, projection: bool) !void {
    if (bytes.len > (if (projection) max_metadata else max_response) or !std.unicode.utf8ValidateSlice(bytes)) return invalid;
    var quoted = false; var escaped = false; var depth: usize = 0; var objects: usize = 0; var arrays: usize = 0;
    var containers: [32]u8 = undefined;
    var root_array_waiting = false; var root_array_items: usize = 0;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) { escaped = false; continue; }
            if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        // The only valid root-valued array is records. Count every direct
        // element, including malformed scalar elements, before JSON allocates.
        if (projection and depth == 2 and containers[1] == '[') {
            if (byte == ',') root_array_waiting = true else if (root_array_waiting and byte != ']' and !std.ascii.isWhitespace(byte)) {
                root_array_items += 1; if (root_array_items > max_records) return invalid;
                root_array_waiting = false;
            }
        }
        switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == containers.len) return invalid;
                containers[depth] = byte;
                depth += 1;
                if (projection and depth == 2 and byte == '[') root_array_waiting = true;
                if (byte == '{') objects += 1 else arrays += 1;
                // Root, profile, family map, its five entries and extensions.
                if (projection and (objects > max_records + 9 or arrays > 2)) return invalid;
            },
            '}', ']' => { if (depth == 0) return invalid; depth -= 1; },
            else => {},
        }
    }
    if (quoted or escaped or depth != 0) return invalid;
}
const Timestamp = struct { seconds: []const u8, fraction: []const u8 };
fn timestamp(value: []const u8) !Timestamp {
    if (value.len < 20 or value[value.len - 1] != 'Z' or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return invalid;
    const ranges = [_][2]usize{ .{0,4}, .{5,7}, .{8,10}, .{11,13}, .{14,16}, .{17,19} };
    var values: [6]u32 = undefined;
    for (ranges, 0..) |range, i| {
        const digits = value[range[0]..range[1]];
        for (digits) |byte| if (!std.ascii.isDigit(byte)) return invalid;
        values[i] = std.fmt.parseInt(u32, digits, 10) catch return invalid;
    }
    const year = values[0]; const month = values[1]; const day = values[2];
    if (year == 0 or month == 0 or month > 12 or day == 0 or values[3] > 23 or values[4] > 59 or values[5] > 59) return invalid;
    const days = [_]u32{31,28,31,30,31,30,31,31,30,31,30,31};
    const limit = days[month - 1] + @as(u32, if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 1 else 0);
    if (day > limit) return invalid;
    const fraction = if (value.len == 20) "" else value[20 .. value.len - 1];
    if (value.len != 20 and (value[19] != '.' or fraction.len == 0)) return invalid;
    for (fraction) |byte| if (!std.ascii.isDigit(byte)) return invalid;
    return .{ .seconds = value[0..19], .fraction = fraction };
}
fn notAfter(left: Timestamp, right: Timestamp) bool {
    switch (std.mem.order(u8, left.seconds, right.seconds)) { .lt => return true, .gt => return false, .eq => {} }
    for (0..@max(left.fraction.len, right.fraction.len)) |i| {
        const x = if (i < left.fraction.len) left.fraction[i] else '0';
        const y = if (i < right.fraction.len) right.fraction[i] else '0';
        if (x != y) return x < y;
    }
    return true;
}
fn canonicalFile(a: A, ns: *const namespaces.Registry, value: []const u8) ![]u8 {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "|\x00\r\n\t") != null) return invalid;
    const original = ns.ofTitle(value);
    if (original.id == -2) return ns.normalizeTitle(a, original.text, 6, .literal);
    const normalized = try ns.normalizeTitle(a, value, 6, .any);
    errdefer a.free(normalized);
    if (ns.ofTitle(normalized).id != 6) return invalid;
    return normalized;
}
fn officialServer(a: A, wiki: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, wiki, "wiktionary") or wiki.len <= "wiktionary".len) return invalid;
    const prefix = wiki[0 .. wiki.len - "wiktionary".len];
    for (prefix) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return invalid;
    const server = try std.fmt.allocPrint(a, "//{s}.wiktionary.org", .{prefix});
    for (server) |*byte| if (byte.* == '_') { byte.* = '-'; };
    return server;
}
fn general(value: Value, wiki: []const u8, language: []const u8, server: []const u8, core: []const u8) !Value {
    return generalWithEpoch(value, wiki, language, server, core, false);
}
fn generalWithEpoch(value: Value, wiki: []const u8, language: []const u8, server: []const u8, core: []const u8, epochs: bool) !Value {
    if (value != .object or value.object.contains("error") or value.object.contains("errors") or value.object.contains("warnings")) return invalid;
    const query = try field(value, "query");
    const item = try field(query, "general");
    const remote = try string(item, "server");
    const bare = if (std.mem.startsWith(u8, remote, "https:")) remote[6..] else remote;
    if (!equal(try string(item, "wikiid"), wiki) or !equal(try string(item, "lang"), language) or (!acceptedResponseCore(core, epochs) or !equal(try string(item, "git-hash"), core)) or !equal(bare, server)) return invalid;
    return query;
}

const profile_strings = [_][2][]const u8{
    .{"kind", "wikimedia-imagehandler-v3"},
    .{"site_family", "wikimedia-wiktionary"},
    .{"png_handler_sha256", "47de6d86c665bfcce949a4199d05842a6bf3d8a39cd97af280b7c0a857a86840"},
    .{"paged_tiff_handler_sha256", "b7b733e254f248f0ef2f196a38675700ef3837b41ce26b96bff0d32cc9f8e6c5"},
    .{"paged_tiff_image_sha256", "2de8768338aaa885d38fabb04c4f844fa2bf1910dc6cf914fb2d65f8e0b41e45"},
    .{"local_file_sha256", "193d8640f2e75995741767e1d80ea319f97222b10a76b0748c63f9b8d7343354"},
    .{"foreign_api_file_sha256", "319fd927464b5e0b633ed0386061f051a30ac87ebf2524ce275d89ddcbecf746"},
    .{"jpeg_handler_sha256", "be3aeaab237907ea751c5d5c99ac4c039c40ca0d1c4476a7d6fcfb4f86daf6eb"},
    .{"exif_bitmap_handler_sha256", "e50838b284c4a0dc013da4a405bf568144c9f63e9bd162e19da79f2dbc9f4f45"},
    .{"bitmap_handler_sha256", "d479a959113ddeb55d07ba5607d4a06c52010cba60b616544fcc0800aaab2ce4"},
    .{"transformational_image_handler_sha256", "8abe6f37493ed21944d20385e433a0091e8c8e6b019216b41edc849a13df9970"},
    .{"imageinfo_api_sha256", "e86d5021447684f9bc6f56140a16f6f0a117b8d752ef678b37e66553512318b5"},
    .{"linker_sha256", "202965a43866f0bc5a2ed0f0aaa898dfb27fc91a9a78b6f205ba5f16beea96f5"},
    .{"image_handler_sha256", "2e4b6fd849ff0eddbf01163229305c899ab620b75e21f1c48ca63b53c0a84696"},
    .{"media_handler_sha256", "a56e9e26bb3152b524971b5bc9d9078c1f7ec3741777e32dc7c93d0cf2f1ce96"},
    .{"file_sha256", "45f446888af647f1b175f43580daae9cf9393883c04c30af743821647b681396"},
    .{"svg_handler_sha256", "f3e8b5c497c8ed3871e89edb23ca19c8279caf93a6697f2b9431a562204637a9"},
    .{"handler_factory_sha256", "70a1e42eea69913af2435f68ddd31b8ba6acf0e0e02abf4573e2792a11c42461"},
    .{"service_wiring_sha256", "784aed3e7d2d205cdfab25c99c9952859fbbb0dcb1e8ac17cde470e72b1a9571"},
    .{"wmf_common_sha256", "1390345238dac0e6fe034d5645ce240d82207f27d8e445255dbd6ceabbcf4d17"},
    .{"wmf_initialise_sha256", "438a10cf3567c592cd1504722b5c86f810786952d15b7495e003fc24dfee8aff"},
    .{"paged_tiff_manifest_sha256", "09662c0816af5f534b540582f3fdf50486673433b48b164e63ad14097f0848eb"},
    .{"timed_media_manifest_sha256", "46a14f5dabc9ff8d064854ed8e6ab5103cf0aa29927ce69a36744c0370e1f639"},
    .{"pdf_manifest_sha256", "97ccd0e0302cd0d2b33a4b04afb7c44ba933f75ce984aa21402baa7e8450d6da"},
    .{"three_d_manifest_sha256", "ee490e501725afa14926147c61c2ee89c3e320f4d6824703f0306bd5d5d0c10b"},
    .{"timed_media_registration_sha256", "a3bea9ce1ce5026b983fa1f3a528f9560d02e152996151dc22d2e18320d94da9"},
    .{"timed_media_presets_sha256", "06c3e0c9a65d840d0d8e391389b3b0986699b57c3a9836af1bd6a76b8d6d8529"},
    .{"timed_media_namespaces_sha256", "a1043b29b314adb045baa66faefaf007238ae2411297760c33ced75cfcf39ed2"},
};
const media_extensions = [_][2][]const u8{
    .{"PagedTiffHandler", "053e6a37f77c35fb19a7adb699fdc87af137cc41"},
    .{"TimedMediaHandler", "2d3ee29044041c34a456981b50ad53e87bc12c6a"},
    .{"PDF Handler", "23541e678a77dae376ab9a4693fc6c624d8103ff"},
    .{"3D", "59f36a91e568500d404a01feef4290dafa008002"},
};
pub const generator_sha256 = "445969d476e9e7d5cfa725b74900b3e80b950cfb85eed9a70d3ed7afe85fb2a3";


const HandlerFamily = struct { mime: []const u8, handler_class: []const u8, mediatype: []const u8 };
const handler_families = [_]HandlerFamily{
    .{ .mime = "image/svg+xml", .handler_class = "MediaWiki\\Media\\SvgHandler", .mediatype = "DRAWING" },
    .{ .mime = "image/svg", .handler_class = "MediaWiki\\Media\\SvgHandler", .mediatype = "DRAWING" },
    .{ .mime = "image/jpeg", .handler_class = "MediaWiki\\Media\\JpegHandler", .mediatype = "BITMAP" },
    .{ .mime = "image/png", .handler_class = "MediaWiki\\Media\\PNGHandler", .mediatype = "BITMAP" },
    .{ .mime = "image/tiff", .handler_class = "MediaWiki\\Extension\\PagedTiffHandler\\PagedTiffHandler", .mediatype = "BITMAP" },
};
fn handlerFamily(mime: []const u8) ?HandlerFamily {
    for (handler_families) |family| if (equal(mime, family.mime)) return family;
    return null;
}

const gif_handler: HandlerFamily = .{ .mime = "image/gif", .handler_class = "MediaWiki\\Media\\GIFHandler", .mediatype = "BITMAP" };
fn gifProfile(value: Value) bool {
    return value == .object and (if (value.object.get("kind")) |kind| kind == .string and equal(kind.string, "wikimedia-imagehandler-v4") else false);
}
fn profile(value: Value, site_bytes: []const u8) !void {
    const gif = gifProfile(value);
    if (value != .object or value.object.count() != profile_strings.len + 3 + @as(usize, if (gif) 2 else 0)) return invalid;
    for (profile_strings) |pair| {
        const expected = if (gif and equal(pair[0], "kind")) "wikimedia-imagehandler-v4" else pair[1];
        if (!equal(try string(value, pair[0]), expected)) return invalid;
    }
    if (gif and (!equal(try string(value, "gif_handler_sha256"), "f9ba4542bcbfbcdaee7db0c99a463b3f97e9e1e82b0e11adcae927c6638dbf52") or
        !equal(try string(value, "main_config_schema_sha256"), "cf37b0e27b01de513fa9ac81bb4424f48c9892107543a0697622c677c7a1de52"))) return invalid;
    const families = try field(value, "handler_families");
    if (families != .object or families.object.count() != handler_families.len + @as(usize, if (gif) 1 else 0)) return invalid;
    for (handler_families) |family| {
        const item = try field(families, family.mime);
        if (item != .object or item.object.count() != 2 or
            !equal(try string(item, "handler_class"), family.handler_class) or
            !equal(try string(item, "mediatype"), family.mediatype)) return invalid;
    }
    if (gif) {
        const item = try field(families, gif_handler.mime);
        if (item != .object or item.object.count() != 2 or
            !equal(try string(item, "handler_class"), gif_handler.handler_class) or
            !equal(try string(item, "mediatype"), gif_handler.mediatype)) return invalid;
    }
    const extensions = try field(value, "media_extensions");
    if (extensions != .object or extensions.object.count() != media_extensions.len) return invalid;
    for (media_extensions) |pair| if (!equal(try string(extensions, pair[0]), pair[1])) return invalid;
    if (!digestMatches(site_bytes, try string(value, "site_raw_sha256"))) return invalid;
}
fn mediaRegistration(query: Value) !void {
    const extensions = try field(query, "extensions");
    if (extensions != .array or extensions.array.items.len > 1024) return invalid;
    var seen: [media_extensions.len]bool = @splat(false);
    for (extensions.array.items) |item| {
        if (item != .object) return invalid;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !equal(kind.string, "media")) continue;
        const name = try string(item, "name"); const revision = try string(item, "vcs-version");
        var found = false;
        for (media_extensions, 0..) |pair, i| if (equal(name, pair[0])) {
            if (seen[i] or !equal(revision, pair[1])) return invalid;
            seen[i] = true; found = true; break;
        };
        if (!found) return invalid;
    }
    for (seen) |present| if (!present) return invalid;
}

fn observedUrlBase(value: Value) ?[]const u8 {
    if (value != .string or !std.mem.startsWith(u8, value.string, "https://")) return null;
    const url = value.string;
    for (url) |byte| if (byte <= 32 or byte == 127 or byte == '#' or byte == '\\') return null;
    const base = url[0 .. (std.mem.indexOfScalar(u8, url, '?') orelse url.len)];
    const slash = std.mem.indexOfScalarPos(u8, base, 8, '/') orelse return null;
    if (slash == 8 or slash + 1 == base.len or std.mem.indexOfAny(u8, base[8..slash], "@:") != null) return null;
    return base;
}
fn observedSvgWidth(info: Value, mime: []const u8, mediatype: []const u8, width: u32, height: u32) ?u32 {
    if ((!equal(mime, "image/svg+xml") and !equal(mime, "image/svg")) or !equal(mediatype, "DRAWING") or
        width == 0 or height == 0 or info != .object or hasHidden(info) or info.object.contains("thumberror")) return null;
    const observed_value = info.object.get("thumbwidth") orelse return null;
    const observed_height_value = info.object.get("thumbheight") orelse return null;
    if (observed_value != .integer or observed_height_value != .integer) return null;
    const observed = std.math.cast(u32, observed_value.integer) orelse return null;
    const observed_height = std.math.cast(u32, observed_height_value.integer) orelse return null;
    if (observed <= width or observed_height == 0 or
        (@as(u64, height) * observed + width / 2) / width != observed_height) return null;
    const attributes = info.object.get("thumbattribs") orelse return null;
    if (attributes != .object) return null;
    const attribute_width = attributes.object.get("width") orelse return null;
    const attribute_height = attributes.object.get("height") orelse return null;
    if (attribute_width != .integer or attribute_height != .integer or
        attribute_width.integer != observed or attribute_height.integer != observed_height) return null;
    const original = observedUrlBase(info.object.get("url") orelse return null) orelse return null;
    const thumbnail = observedUrlBase(info.object.get("thumburl") orelse return null) orelse return null;
    if (equal(original, thumbnail)) return null;
    return observed;
}

fn nonempty(value: Value) bool {
    return switch (value) {
        .null => false, .bool => value.bool, .integer => value.integer != 0,
        .float => value.float != 0, .number_string => true,
        .string => value.string.len != 0, .array => value.array.items.len != 0,
        .object => value.object.count() != 0,
    };
}
fn hasHidden(value: Value) bool {
    if (value != .object) return true;
    return value.object.contains("filehidden") or value.object.contains("suppressed") or value.object.contains("filemissing");
}

const MetadataFields = std.StringHashMapUnmanaged(Value);
fn metadataFields(a: A, value: Value) !MetadataFields {
    if (value != .array or value.array.items.len > 4096) return invalid;
    var result: MetadataFields = .empty;
    errdefer result.deinit(a);
    try result.ensureTotalCapacity(a, @intCast(value.array.items.len));
    for (value.array.items) |item| {
        if (item != .object or item.object.count() != 2) return invalid;
        const name = try string(item, "name");
        const body = try field(item, "value");
        const slot = try result.getOrPut(a, name);
        if (slot.found_existing) return invalid;
        slot.value_ptr.* = body;
    }
    return result;
}
// A returned nonempty metadata map is distinct from an omitted lean-query
// field. The selected f458 API preserves Orientation; absence in this map,
// or explicit normal orientation, proves zero handler rotation. This only
// authorizes Linker's logical no-upscale bound, not decoded image fidelity.
fn jpegUnrotatedMetadata(a: A, image: Value) A.Error!bool {
    const value = image.object.get("metadata") orelse return false;
    if (value != .array or value.array.items.len == 0) return false;
    var metadata = metadataFields(a, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer metadata.deinit(a);
    if (metadata.contains("errors")) return false;
    if (metadata.get("_error")) |legacy| {
        // ExifBitmapHandler explicitly retains this old compatible no-EXIF
        // map. Other errors and mixed error/orientation maps prove nothing.
        return metadata.count() == 1 and legacy == .string and equal(legacy.string, "0");
    }
    const orientation = metadata.get("Orientation") orelse return true;
    return orientation == .integer and orientation.integer == 1;
}

fn metadataInteger(fields: MetadataFields, name: []const u8, expected: u32) !void {
    const value = fields.get(name) orelse return invalid;
    if (value != .integer or value.integer != expected) return invalid;
}
// This is the selected handler's single-page metadata grammar, not a filename
// or MIME-derived assumption about decoded pixels or arbitrary TIFF pages.
fn tiffPageAxes(a: A, image: Value, width: u32, height: u32) !void {
    if (try positive(image, "pagecount") != 1) return invalid;
    var metadata = try metadataFields(a, try field(image, "metadata"));
    defer metadata.deinit(a);
    if (metadata.contains("errors") or metadata.contains("_error")) return invalid;
    const version = metadata.get("TIFF_METADATA_VERSION") orelse return invalid;
    if (version != .string or !equal(version.string, "1.4")) return invalid;
    for ([_][]const u8{ "page_count", "first_page", "last_page" }) |name| try metadataInteger(metadata, name, 1);
    const pages = metadata.get("page_data") orelse return invalid;
    if (pages != .array or pages.array.items.len != 1) return invalid;
    const item = pages.array.items[0];
    if (item != .object or item.object.count() != 2) return invalid;
    const key = try field(item, "name");
    const is_first = switch (key) {
        .integer => key.integer == 1,
        .string => equal(key.string, "1"),
        else => false,
    };
    if (!is_first) return invalid;
    var page = try metadataFields(a, try field(item, "value"));
    defer page.deinit(a);
    try metadataInteger(page, "page", 1);
    try metadataInteger(page, "width", width);
    try metadataInteger(page, "height", height);
}

pub const stream_schema = "wikidict.figure-sizing-files.stream.v1";
const raw_stream_schema = "wikidict.figure-sizing-raw.stream.v1";
pub const stream_header_limit = 2 * 1024 * 1024;
const stream_fact_limit = 64 * 1024;
const stream_batch_limit = 16 * 1024 * 1024;

const StreamHeader = struct {
    schema: []const u8,
    wiki: []const u8,
    content_language: []const u8,
    core_revision: []const u8,
    namespace_registry_sha256: []const u8,
    raw_sha256: []const u8,
    generator_sha256: []const u8,
    source_profile: Value,
    records_count: u64,
    base_batches: u64,
    observed_batches: u64,
    raw_bytes: u64,
};
const RawStreamHeader = struct {
    schema: []const u8,
    wiki: []const u8,
    core_revision: []const u8,
    namespace_registry_sha256: []const u8,
    base_batches: u64,
    observed_batches: u64,
    records_count: u64,
};

// The caller supplies an already held file (or a test slice), including its
// exact size. Bytes are hashed once as read, with bounded line allocations.
fn validateFileSource(a: A, doc: anytype, records_count: u64, batch_count: u64, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8, contract: bool, epochs: bool) !?[]const u8 {
    const registration = try std.json.parseFromSliceLeaky(Value, a, site, .{ .allocate = .alloc_always });
    const ns_digest = std.fmt.bytesToHex(ns.source_sha256, .lower);
    if (!equal(doc.wiki, ns.wiki) or !equal(doc.content_language, ns.content_language) or
        !lowerHex(doc.core_revision, 40) or !compatibleResponseCore(source_core_revision orelse return invalid, doc.core_revision, epochs) or
        !equal(doc.namespace_registry_sha256, &ns_digest) or (!contract and !fileGenerator(doc.generator_sha256)) or
        !lowerHex(doc.generator_sha256, 64)) return invalid;
    if (records_count == 0) {
        if (batch_count != 0 or doc.source_profile != .null) return invalid;
        const empty_query = try field(registration, "query");
        const empty_general = try field(empty_query, "general");
        if (!equal(try string(empty_general, "wikiid"), ns.wiki) or
            !equal(try string(empty_general, "lang"), ns.content_language) or
            !equal(try string(empty_general, "git-hash"), doc.core_revision)) return invalid;
        return null;
    }
    if (!acceptedResponseCore(doc.core_revision, epochs)) return invalid;
    try profile(doc.source_profile, site);
    const gif = gifProfile(doc.source_profile);
    if (equal(doc.core_revision, response_core) and !gif) return invalid;
    if (gif and (!(equal(doc.core_revision, current_core) or (epochs and equal(doc.core_revision, response_core))) or (!contract and !svgOccurrenceGenerator(doc.generator_sha256) and
        !equal(doc.generator_sha256, "7bce7ec0bd0acdf6a9d726ed50c1e85a64bc089731d0347d048f1787003d4c0b")))) return invalid;
    const server = try officialServer(a, ns.wiki);
    const site_query = try generalWithEpoch(registration, ns.wiki, ns.content_language, server, doc.core_revision, epochs);
    try mediaRegistration(site_query);
    if ((try timestamp(try string(registration, "curtimestamp"))).fraction.len != 0) return invalid;
    return server;
}

const ReplayHeader = struct { header: StreamHeader, contract: bool, encoded_records: bool, response_epochs: bool };
fn rawStreamHeaderShape(a: A, value: Value, encoded_permitted: bool) !Value {
    if (value != .object) return invalid;
    const encoding = value.object.get("record_encoding") orelse return value;
    if (!encoded_permitted or encoding != .string or !equal(encoding.string, raw_record_encoding)) return invalid;
    var shape: Value = .{ .object = .empty };
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        if (!equal(entry.key_ptr.*, "record_encoding"))
            try shape.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }
    return shape;
}
fn readStreamHeaders(a: A, temp: A, projection: *StreamInput, raw: *StreamInput) !ReplayHeader {
    const header_bytes = (try projection.line(temp, stream_header_limit)) orelse return invalid;
    try preflight(header_bytes, false);
    // Value fields retain their parsed storage even when typed fields copy strings.
    const header_value = try std.json.parseFromSliceLeaky(Value, a, header_bytes, .{ .allocate = .alloc_always });
    for ([_][]const u8{ "records_count", "base_batches", "observed_batches", "raw_bytes" }) |name|
        if (!nonnegativeInteger(try field(header_value, name))) return invalid;
    const contract = try explicitReplayContract(header_value);
    const header = try std.json.parseFromValueLeaky(StreamHeader, a, try replayDocumentShape(a, header_value), .{ .allocate = .alloc_always });
    const count_u64 = std.math.add(u64, header.base_batches, header.observed_batches) catch return invalid;
    const max_requests = std.math.mul(u64, header.base_batches, 50) catch return invalid;
    // Counts are bounded by the authenticated physical inputs, not an
    // edition-size ceiling. Batch IDs remain the existing u32 wire field.
    if (!equal(header.schema, stream_schema) or (!contract and !streamGenerator(header.generator_sha256)) or
        !lowerHex(header.generator_sha256, 64) or
        header.raw_bytes != raw.size or header.records_count > projection.size or count_u64 > raw.size or
        count_u64 > std.math.maxInt(u32) or (header.records_count == 0 and count_u64 != 0) or
        header.base_batches > header.records_count or header.records_count > max_requests) return invalid;
    const raw_header_bytes = (try raw.line(temp, stream_header_limit)) orelse return invalid;
    try preflight(raw_header_bytes, false);
    const raw_header_value = try std.json.parseFromSliceLeaky(Value, temp, raw_header_bytes, .{});
    for ([_][]const u8{ "records_count", "base_batches", "observed_batches" }) |name|
        if (!nonnegativeInteger(try field(raw_header_value, name))) return invalid;
    const encoded_permitted = contract and (equal(try string(header_value, "replay_contract"), replay_contract_v2) or responseEpochContract(header_value));
    const raw_header = try std.json.parseFromValueLeaky(RawStreamHeader, temp,
        try rawStreamHeaderShape(temp, raw_header_value, encoded_permitted), .{ .allocate = .alloc_always });
    if (header.records_count > projection.size - (@as(u64, header_bytes.len) + 1) or
        count_u64 > raw.size - (@as(u64, raw_header_bytes.len) + 1)) return invalid;
    if (!equal(raw_header.schema, raw_stream_schema) or !equal(raw_header.wiki, header.wiki) or
        !equal(raw_header.core_revision, header.core_revision) or !equal(raw_header.namespace_registry_sha256, header.namespace_registry_sha256) or
        raw_header.base_batches != header.base_batches or raw_header.observed_batches != header.observed_batches or
        raw_header.records_count != header.records_count) return invalid;
    return .{ .header = header, .contract = contract, .encoded_records = raw_header_value.object.contains("record_encoding"), .response_epochs = responseEpochContract(header_value) };
}

pub const StreamInput = struct {
    context: *anyopaque,
    read_at: *const fn (*anyopaque, []u8, u64) anyerror!usize,
    size: u64,
    offset: u64 = 0,
    buffer: [65536]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    hash: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    digest: ?[32]u8 = null,

    pub fn line(self: *StreamInput, a: A, limit: usize) !?[]u8 {
        if (self.digest != null) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        while (true) {
            if (self.start == self.end) {
                const n = try self.read_at(self.context, &self.buffer, self.offset);
                if (n > self.buffer.len) return invalid;
                if (n == 0) {
                    if (self.offset != self.size or out.items.len != 0) return invalid;
                    var digest: [32]u8 = undefined;
                    self.hash.final(&digest);
                    self.digest = digest;
                    out.deinit(a);
                    return null;
                }
                self.offset = std.math.add(u64, self.offset, n) catch return invalid;
                if (self.offset > self.size) return invalid;
                self.hash.update(self.buffer[0..n]);
                self.start = 0;
                self.end = n;
            }
            const pending = self.buffer[self.start..self.end];
            const newline = std.mem.indexOfScalar(u8, pending, '\n');
            const take = newline orelse pending.len;
            if (take > limit -| out.items.len) return invalid;
            if (newline != null and take == limit -| out.items.len) return invalid;
            try out.appendSlice(a, pending[0..take]);
            self.start += take;
            if (newline != null) {
                self.start += 1;
                if (out.items.len == 0 or std.mem.indexOfScalar(u8, out.items, '\r') != null or
                    !std.unicode.utf8ValidateSlice(out.items)) return invalid;
                return try out.toOwnedSlice(a);
            }
        }
    }

    pub fn finish(self: *StreamInput, a: A) !void {
        if (try self.line(a, 0)) |extra| {
            a.free(extra);
            return invalid;
        }
    }
};

// Inspect presence before optional typed decoding: JSON null is not absence.
fn validateTiffCompanionField(value: Value, permitted: bool) !void {
    if (value != .object) return invalid;
    if (value.object.get("tiff_metadata_response")) |response| {
        if (!permitted or response != .string or response.string.len == 0 or response.string.len > max_response) return invalid;
    }
}

// All fields in this view borrow from the current batch scratch arena.
const TiffCompanion = struct {
    pages: std.StringHashMapUnmanaged(Value) = .empty,
    mappings: std.StringHashMapUnmanaged([]const u8) = .empty,
    used_pages: std.StringHashMapUnmanaged(void) = .empty,
    observed: Timestamp,
    requests: usize = 0,

    fn init(a: A, raw: []const u8, ns: *const namespaces.Registry, server: []const u8, core: []const u8, request_count: usize, epochs: bool) !TiffCompanion {
        if (raw.len == 0) return invalid;
        try preflight(raw, false);
        const root = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
        const query = try generalWithEpoch(root, ns.wiki, ns.content_language, server, core, epochs);
        try mediaRegistration(query);
        const observed = try timestamp(try string(root, "curtimestamp"));
        if (observed.fraction.len != 0) return invalid;
        for ([_][]const u8{ "interwiki", "converted" }) |name| {
            if (query.object.get(name)) |unsupported| if (nonempty(unsupported)) return invalid;
        }
        if (root.object.get("continue")) |continuation| {
            if (continuation != .object) return invalid;
            var entries = continuation.object.iterator();
            while (entries.next()) |entry| if (!equal(entry.key_ptr.*, "continue") and
                !equal(entry.key_ptr.*, "iicontinue") and !equal(entry.key_ptr.*, "iistart")) return invalid;
        }
        var result: TiffCompanion = .{ .observed = observed };
        for ([_][]const u8{ "normalized", "redirects" }) |name| {
            const rows = query.object.get(name) orelse continue;
            if (rows != .array) return invalid;
            for (rows.array.items) |row| {
                const from = try string(row, "from");
                const to = try string(row, "to");
                if (row.object.get("tofragment")) |fragment| if (nonempty(fragment)) return invalid;
                const slot = try result.mappings.getOrPut(a, from);
                if (slot.found_existing and !equal(slot.value_ptr.*, to)) return invalid;
                slot.value_ptr.* = to;
            }
        }
        const pages = try field(query, "pages");
        if (pages != .array or pages.array.items.len == 0 or pages.array.items.len > request_count) return invalid;
        for (pages.array.items) |page| {
            const title = try string(page, "title");
            const page_ns = try field(page, "ns");
            if (page_ns != .integer or page_ns.integer != 6 or hasHidden(page) or
                page.object.contains("invalid") or page.object.contains("interwiki")) return invalid;
            const repository = try string(page, "imagerepository");
            if (!equal(repository, "local") and !equal(repository, "shared")) return invalid;
            const info = try field(page, "imageinfo");
            if (info != .array or info.array.items.len != 1 or hasHidden(info.array.items[0])) return invalid;
            const image = info.array.items[0];
            if (!equal(try string(image, "mime"), "image/tiff") or !image.object.contains("metadata")) return invalid;
            const slot = try result.pages.getOrPut(a, title);
            if (slot.found_existing) return invalid;
            slot.value_ptr.* = page;
        }
        return result;
    }

    fn matchingInfo(self: *TiffCompanion, a: A, ns: *const namespaces.Registry, requested: []const u8, base_repository: []const u8, base: Value) !Value {
        if (!equal(try string(base, "mime"), "image/tiff") or base.object.contains("metadata")) return invalid;
        var current = requested;
        var seen: [50][]const u8 = undefined;
        var count: usize = 0;
        while (self.mappings.get(current)) |next| {
            if (equal(current, next)) break;
            if (count == seen.len) return invalid;
            for (seen[0..count]) |prior| if (equal(prior, current)) return invalid;
            seen[count] = current;
            count += 1;
            current = next;
        }
        const page = self.pages.get(current) orelse return invalid;
        if (!equal(try string(page, "imagerepository"), base_repository)) return invalid;
        const full = (try field(page, "imageinfo")).array.items[0];
        for ([_][]const u8{ "sha1", "timestamp", "mime", "mediatype" }) |name| {
            if (!equal(try string(full, name), try string(base, name))) return invalid;
        }
        for ([_][]const u8{ "width", "height", "size" }) |name| {
            const left = try field(full, name);
            const right = try field(base, name);
            if (left != .integer or right != .integer or left.integer != right.integer) return invalid;
        }
        const base_pages = base.object.get("pagecount");
        const full_pages = full.object.get("pagecount");
        if ((base_pages == null) != (full_pages == null)) return invalid;
        if (base_pages) |expected| {
            const actual = full_pages.?;
            if (expected != .integer or actual != .integer or expected.integer != actual.integer) return invalid;
        }
        if (!equal(try canonicalFile(a, ns, try string(full, "canonicaltitle")),
            try canonicalFile(a, ns, try string(base, "canonicaltitle"))) or
            !notAfter(try timestamp(try string(full, "timestamp")), self.observed)) return invalid;
        _ = try self.used_pages.getOrPut(a, current);
        self.requests += 1;
        return full;
    }

    fn finish(self: *const TiffCompanion) !void {
        if (self.requests == 0 or self.used_pages.count() != self.pages.count()) return invalid;
    }
};

const ArrayBatches = struct {
    items: []const RawFileBatch,
    count: usize,
    cursor: usize = 0,
    fn next(self: *ArrayBatches, _: A) !RawFileBatch {
        if (self.cursor >= self.count) return invalid;
        defer self.cursor += 1;
        return self.items[self.cursor];
    }
    fn finish(self: *ArrayBatches) !void { if (self.cursor != self.count) return invalid; }
};
extern fn ZSTD_getFrameContentSize(src: [*]const u8, src_size: usize) u64;
extern fn ZSTD_getDictID_fromFrame(src: [*]const u8, src_size: usize) c_uint;
const EncodedRawRecord = struct {
    encoding: []const u8,
    raw_bytes: u64,
    raw_sha256: []const u8,
    data: []const u8,
};
fn rawStreamRecordValue(a: A, bytes: []const u8, encoded_permitted: bool) !Value {
    if (bytes.len >= stream_batch_limit) return invalid;
    try preflightFileBatches(bytes);
    const value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
    if (!encoded_permitted or value != .object or !value.object.contains("encoding")) return value;
    if (!nonnegativeInteger(try field(value, "raw_bytes"))) return invalid;
    const envelope = std.json.parseFromValueLeaky(EncodedRawRecord, a, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid,
    };
    if (!equal(envelope.encoding, "zstd") or envelope.raw_bytes == 0 or envelope.raw_bytes > stream_batch_limit or
        !lowerHex(envelope.raw_sha256, 64)) return invalid;
    const compressed_len = std.base64.standard.Decoder.calcSizeForSlice(envelope.data) catch return invalid;
    if (compressed_len < 6 or compressed_len > stream_batch_limit) return invalid;
    const compressed = try a.alloc(u8, compressed_len);
    defer a.free(compressed);
    std.base64.standard.Decoder.decode(compressed, envelope.data) catch return invalid;
    if (ZSTD_getFrameContentSize(compressed.ptr, compressed.len) != envelope.raw_bytes or
        ZSTD_getDictID_fromFrame(compressed.ptr, compressed.len) != 0) return invalid;
    const decoded = dump_source.decompressZstdBytesAlloc(a, compressed, @intCast(envelope.raw_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid,
    };
    defer a.free(decoded);
    if (decoded.len != envelope.raw_bytes or !digestMatches(decoded, envelope.raw_sha256) or decoded.len < 2 or
        decoded[decoded.len - 1] != '\n' or std.mem.indexOfScalar(u8, decoded[0 .. decoded.len - 1], '\n') != null or
        std.mem.indexOfScalar(u8, decoded, '\r') != null) return invalid;
    const line = decoded[0 .. decoded.len - 1];
    if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) return invalid;
    try preflightFileBatches(line);
    // Copy the decoded strings before releasing the temporary frame buffers.
    return std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always });
}

const StreamBatches = struct {
    input: *StreamInput,
    backing: A,
    count: usize,
    base_count: usize,
    raw_sha256: []const u8,
    allow_tiff_companion: bool = false,
    encoded_records: bool = false,
    cursor: usize = 0,
    fn next(self: *StreamBatches, a: A) !RawFileBatch {
        if (self.cursor >= self.count) return invalid;
        const bytes = (try self.input.line(a, stream_batch_limit)) orelse return invalid;
        // The outer record has bounded depth independently of its quoted HTTP
        // response. The response itself uses the existing strict preflight.
        const value = try rawStreamRecordValue(a, bytes, self.encoded_records);
        try validateTiffCompanionField(value, self.allow_tiff_companion);
        const batch = try std.json.parseFromValueLeaky(RawFileBatch, a, value, .{ .allocate = .alloc_always });
        if ((batch.observed_svg_width_px != null or batch.observed_svg_occurrences != null) != (self.cursor >= self.base_count)) return invalid;
        self.cursor += 1;
        return batch;
    }
    fn finish(self: *StreamBatches) !void {
        if (self.cursor != self.count) return invalid;
        try self.input.finish(self.backing);
        if (!equal(&std.fmt.bytesToHex(self.input.digest.?, .lower), self.raw_sha256)) return invalid;
    }
};

const HeightBound = enum { none, bitmap, png, gif, jpeg_unrotated };

// A validated SVG thumbnail whose URL base differs from the original has
// already taken SvgHandler's raster branch. That width-independent per-file
// mode makes Linker preserve requested logical width. SVGMaxSize and stepping
// only alter physical raster axes; they are not a logical-width certificate.
fn observedSvgRasterLogicalWidth(record: Record, width: u32, height: ?u32) bool {
    if (!equal(record.proof_kind, "file-svg-observed-thumbnail-width") or
        record.format != .thumbnail or record.sizing != .requested_fit or record.height_px != null or
        record.original_width == 0 or record.original_height == 0 or record.width_px <= record.original_width or
        width == 0 or height != null) return false;
    // Preserve the exact previously validated measurement, while bounding new
    // logical requests to the presentation model's positive u32-height domain.
    if (width == record.width_px) return true;
    if (width <= record.original_width) return false;
    return @as(u64, record.original_height) * width <=
        @as(u64, std.math.maxInt(u32)) * record.original_width;
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    namespace_catalog: *const namespaces.Registry,
    records: []const Record,
    file_authority: bool = false,
    // Build-only parallel proof, derived from validated file facts. It is not
    // accepted from either legacy or streamed serialized records.
    height_bound_records: []const HeightBound = &.{},
    height_occurrences: std.StringHashMapUnmanaged(SvgHeightAuthority) = .empty,

    pub fn init(backing: A, projection: []const u8, raw: []const u8, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8, expected_generator: []const u8) !Registry {
        try preflight(projection, true); try preflight(site, false);
        var arena = std.heap.ArenaAllocator.init(backing); errdefer arena.deinit(); const a = arena.allocator();
        // All retained strings and records belong to this registry's arena;
        // no temporary Parsed arena is destroyed underneath the callback.
        const projection_value = try std.json.parseFromSliceLeaky(Value, a, projection, .{ .allocate = .alloc_always });
        if (equal(try string(projection_value, "schema"), "wikidict.figure-sizing-files.v1"))
            return initFileFacts(&arena, projection_value, raw, site, ns, source_core_revision);
        try preflight(raw, false);
        const record_values = try field(projection_value, "records");
        if (record_values != .array or record_values.array.items.len == 0 or record_values.array.items.len > max_records) return invalid;
        for (record_values.array.items) |record_value| {
            _ = try positive(record_value, "original_width");
            _ = try positive(record_value, "original_height");
            _ = try positive(record_value, "width_px");
            if (try field(record_value, "height_px") != .null) return invalid;
        }
        const doc = try std.json.parseFromValueLeaky(Document, a, projection_value, .{});
        const source = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
        const registration = try std.json.parseFromSliceLeaky(Value, a, site, .{ .allocate = .alloc_always });
        const ns_digest = std.fmt.bytesToHex(ns.source_sha256, .lower);
        // Sizing replay and figure defaults are independent source roles. The
        // compiler checks the separately loaded defaults before figure output.
        if (!equal(doc.schema, "wikidict.figure-sizing-source.v1") or !equal(doc.wiki, ns.wiki) or !equal(doc.content_language, ns.content_language) or !equal(doc.core_revision, accepted_core) or
            !equal(source_core_revision orelse return invalid, accepted_core) or !equal(doc.namespace_registry_sha256, &ns_digest) or !equal(doc.generator_sha256, expected_generator) or
            !lowerHex(expected_generator, 64) or !digestMatches(raw, doc.raw_sha256) or doc.records.len == 0 or doc.records.len > max_records) return invalid;
        if (gifProfile(doc.source_profile)) return invalid;
        try profile(doc.source_profile, site);
        const server = try officialServer(a, ns.wiki);
        const query = try general(source, ns.wiki, ns.content_language, server, doc.core_revision);
        const site_query = try general(registration, ns.wiki, ns.content_language, server, doc.core_revision);
        try mediaRegistration(site_query);
        const observed = try timestamp(doc.observation_utc);
        if (observed.fraction.len != 0 or !equal(try string(source, "curtimestamp"), doc.observation_utc)) return invalid;
        const site_observed = try timestamp(try string(registration, "curtimestamp"));
        if (site_observed.fraction.len != 0) return invalid;
        const pages = try field(query, "pages");
        if (pages != .array or pages.array.items.len > max_records) return invalid;
        for ([_][]const u8{ "interwiki", "converted" }) |name| {
            if (query.object.get(name)) |unsupported| if (nonempty(unsupported)) return invalid;
        }
        if (source.object.get("continue")) |continuation| {
            if (continuation != .object) return invalid;
            var entries = continuation.object.iterator();
            while (entries.next()) |entry| if (!equal(entry.key_ptr.*, "continue") and !equal(entry.key_ptr.*, "iicontinue") and !equal(entry.key_ptr.*, "iistart")) return invalid;
        }
        var mappings: std.StringHashMapUnmanaged([]const u8) = .empty;
        for ([_][]const u8{ "normalized", "redirects" }) |name| {
            const rows = query.object.get(name) orelse continue;
            if (rows != .array) return invalid;
            for (rows.array.items) |row| {
                const from = try string(row, "from"); const to = try string(row, "to");
                if (row.object.get("tofragment")) |fragment| if (nonempty(fragment)) return invalid;
                const slot = try mappings.getOrPut(a, from);
                if (slot.found_existing and !equal(slot.value_ptr.*, to)) return invalid;
                slot.value_ptr.* = to;
            }
        }
        var by_title: std.StringHashMapUnmanaged(Value) = .empty;
        for (pages.array.items) |page| {
            const title = try string(page, "title");
            const page_ns = try field(page, "ns");
            if (page_ns != .integer or page_ns.integer != 6 or hasHidden(page)) return invalid;
            if (page.object.contains("invalid") or page.object.contains("interwiki")) return invalid;
            const slot = try by_title.getOrPut(a, title);
            if (slot.found_existing) return invalid;
            slot.value_ptr.* = page;
        }
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        var used_pages: std.StringHashMapUnmanaged(void) = .empty;
        var used_titles: std.StringHashMapUnmanaged(void) = .empty;
        for (doc.records, 0..) |record, record_index| {
            if (record_index != 0) {
                const previous = doc.records[record_index - 1];
                const order = std.mem.order(u8, previous.canonical_file, record.canonical_file);
                if (order == .gt or (order == .eq and previous.width_px >= record.width_px)) return invalid;
            }
            if (record.format != .thumbnail or record.sizing != .requested_fit or record.width_px == 0 or record.height_px != null or record.original_width == 0 or record.original_height == 0 or record.width_px > record.original_width or
                !equal(record.proof_kind, "thumbnail-width-not-above-original") or !lowerHex(record.file_sha1, 40) or !notAfter(try timestamp(record.file_timestamp), observed)) return invalid;
            const canonical = try canonicalFile(a, ns, record.canonical_file);
            if (!equal(canonical, record.canonical_file)) return invalid;
            const key = try std.fmt.allocPrint(a, "{s}\n{d}", .{canonical, record.width_px});
            if ((try keys.getOrPut(a, key)).found_existing) return invalid;
            _ = try used_titles.getOrPut(a, canonical);
            var current: []const u8 = canonical;
            var seen: [50][]const u8 = undefined; var count: usize = 0;
            while (mappings.get(current)) |next| {
                if (equal(current, next)) break;
                if (count == seen.len) return invalid;
                for (seen[0..count]) |previous| if (equal(previous, current)) return invalid;
                seen[count] = current; count += 1; current = next;
            }
            const page = by_title.get(current) orelse return invalid;
            _ = try used_pages.getOrPut(a, current);
            const repository = try string(page, "imagerepository");
            if (!equal(repository, "shared") and !equal(repository, "local")) return invalid;
            const info = try field(page, "imageinfo");
            if (info != .array or info.array.items.len != 1) return invalid;
            const image = info.array.items[0];
            if (hasHidden(image)) return invalid;
            const family = handlerFamily(try string(image, "mime")) orelse return invalid;
            const image_canonical = try canonicalFile(a, ns, try string(image, "canonicaltitle"));
            if (!equal(try string(image, "mediatype"), family.mediatype) or
                !equal(image_canonical, canonical) or !equal(try string(image, "sha1"), record.file_sha1) or !equal(try string(image, "timestamp"), record.file_timestamp) or
                try positive(image, "width") != record.original_width or try positive(image, "height") != record.original_height) return invalid;
            if (!nonnegativeInteger(try field(image, "size"))) return invalid;
            if (equal(family.mime, "image/tiff")) try tiffPageAxes(a, image, record.original_width, record.original_height);
        }
        if (used_pages.count() != by_title.count() or pages.array.items.len > used_titles.count()) return invalid;
        return .{ .arena = arena, .namespace_catalog = ns, .records = doc.records };
    }

    // Compatibility only: bounded headers and source profile. Facts, batch
    // payloads and complete digests are still checked by initStream at use.
    pub fn checkStreamCompatibility(backing: A, projection: *StreamInput, raw: *StreamInput, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !void {
        try preflight(site, false);
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed_header = try readStreamHeaders(a, a, projection, raw);
        const header = parsed_header.header;
        _ = try validateFileSource(a, header, header.records_count, header.base_batches + header.observed_batches, site, ns, source_core_revision, parsed_header.contract, parsed_header.response_epochs);
    }

    pub fn initStream(backing: A, projection: *StreamInput, raw: *StreamInput, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !Registry {
        return initStreamWithScratchReset(.retain_capacity, backing, projection, raw, site, ns, source_core_revision);
    }

    fn initStreamWithScratchReset(comptime reset_mode: std.heap.ArenaAllocator.ResetMode, backing: A, projection: *StreamInput, raw: *StreamInput, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !Registry {
        try preflight(site, false);
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        var scratch = std.heap.ArenaAllocator.init(backing);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const parsed_header = try readStreamHeaders(a, temp, projection, raw);
        const header = parsed_header.header;
        const count = std.math.cast(usize, header.base_batches + header.observed_batches) orelse return invalid;
        const fact_count = std.math.cast(usize, header.records_count) orelse return invalid;
        const records = try a.alloc(FileFact, fact_count);
        for (records) |*record| {
            const bytes = (try projection.line(temp, stream_fact_limit)) orelse return invalid;
            try preflight(bytes, false);
            record.* = try std.json.parseFromSliceLeaky(FileFact, a, bytes, .{ .allocate = .alloc_always });
            _ = scratch.reset(reset_mode);
        }
        try projection.finish(temp);
        var batches: StreamBatches = .{ .input = raw, .backing = backing, .count = count,
            .base_count = std.math.cast(usize, header.base_batches) orelse return invalid, .raw_sha256 = header.raw_sha256,
            .allow_tiff_companion = parsed_header.contract or equal(header.generator_sha256, file_generator_sha256),
            .encoded_records = parsed_header.encoded_records };
        return validateFileFacts(&arena, .{ .schema = "wikidict.figure-sizing-files.v1", .wiki = header.wiki,
            .content_language = header.content_language, .core_revision = header.core_revision,
            .namespace_registry_sha256 = header.namespace_registry_sha256, .raw_sha256 = header.raw_sha256,
            .generator_sha256 = header.generator_sha256, .source_profile = header.source_profile, .records = records },
            site, ns, source_core_revision, &batches, parsed_header.contract, parsed_header.response_epochs);
    }

    fn initFileFacts(arena: *std.heap.ArenaAllocator, value: Value, raw: []const u8, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !Registry {
        const a = arena.allocator();
        try preflightFileBatches(raw);
        const contract = try explicitReplayContract(value);
        const doc = try std.json.parseFromValueLeaky(FilesDocument, a, try replayDocumentShape(a, value), .{});
        if (!contract and !observedFileGenerator(doc.generator_sha256)) {
            if (doc.records.len != 0 and !equal(doc.core_revision, accepted_core)) return invalid;
            for (doc.records) |fact| if (fact.observed_svg_width_px != null or fact.observed_batch != null) return invalid;
        }
        var raw_scratch = std.heap.ArenaAllocator.init(arena.child_allocator);
        defer raw_scratch.deinit();
        const raw_value = try std.json.parseFromSliceLeaky(Value, raw_scratch.allocator(), raw, .{ .allocate = .alloc_always });
        const raw_batches = try field(raw_value, "batches");
        if (raw_batches != .array) return invalid;
        for (raw_batches.array.items) |batch_value| try validateTiffCompanionField(batch_value, contract or equal(doc.generator_sha256, file_generator_sha256));
        const batches = try std.json.parseFromValueLeaky(RawFileBatches, a, raw_value, .{ .allocate = .alloc_always });
        if (!equal(batches.schema, "wikidict.figure-sizing-raw-batches.v1") or
            batches.batches.len > max_batches or doc.records.len > max_records or !digestMatches(raw, doc.raw_sha256)) return invalid;
        var input: ArrayBatches = .{ .items = batches.batches, .count = batches.batches.len };
        return validateFileFacts(arena, doc, site, ns, source_core_revision, &input, contract, responseEpochContract(value));
    }

    fn validateFileFacts(arena: *std.heap.ArenaAllocator, doc: FilesDocument, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8, batches: anytype, contract: bool, epochs: bool) !Registry {
        const a = arena.allocator();
        const server = (try validateFileSource(a, doc, doc.records.len, batches.count, site, ns, source_core_revision, contract, epochs)) orelse {
            try batches.finish();
            return .{ .arena = arena.*, .namespace_catalog = ns, .records = &.{}, .file_authority = true };
        };
        const gif = gifProfile(doc.source_profile);
        var facts: std.StringHashMapUnmanaged(*const FileFact) = .empty;
        var declared_heights: std.StringHashMapUnmanaged(*const SvgHeightObservation) = .empty;
        var height_occurrences: std.StringHashMapUnmanaged(SvgHeightAuthority) = .empty;
        for (doc.records, 0..) |*fact, i| {
            if (i != 0 and std.mem.order(u8, doc.records[i - 1].requested_file, fact.requested_file) != .lt) return invalid;
            const name = try canonicalFile(a, ns, fact.requested_file);
            if (!equal(name, fact.requested_file) or fact.batch >= batches.count or
                (try facts.getOrPut(a, name)).found_existing) return invalid;
            if ((fact.observed_svg_width_px == null) != (fact.observed_batch == null)) return invalid;
            if (fact.observed_batch) |observed_batch| {
                if (observed_batch <= fact.batch or observed_batch >= batches.count or
                    fact.observed_svg_width_px.? <= fact.original_width) return invalid;
            }
            if (fact.observed_svg_heights) |observations| {
                if (!gif or (!contract and !svgOccurrenceGenerator(doc.generator_sha256)) or !equal(doc.core_revision, current_core) or
                    observations.len == 0 or !equal(fact.requested_file, fact.canonical_file) or
                    fact.state != .eligible or !equal(fact.mime, "image/svg+xml") or !equal(fact.mediatype, "DRAWING")) return invalid;
                for (observations) |*observation| {
                    const fit = svgHeightFit(fact.original_width, fact.original_height, observation.height_px) orelse return invalid;
                    if (!equal(observation.wiki, doc.wiki) or observation.parse_core_binding_proven or
                        observation.batch <= fact.batch or observation.batch >= batches.count or
                        observation.observed_height_px != observation.height_px or observation.observed_width_px != fit) return invalid;
                    const key = try svgHeightKey(a, observation.wiki, observation.title, fact.canonical_file, observation.options, observation.height_px);
                    const slot = try declared_heights.getOrPut(a, key);
                    if (slot.found_existing) return invalid;
                    slot.value_ptr.* = observation;
                }
            }
            facts.getPtr(name).?.* = fact;
        }
        var used_facts: std.StringHashMapUnmanaged(void) = .empty;
        var used_observations: std.StringHashMapUnmanaged(u32) = .empty;
        var canonical_facts: std.StringHashMapUnmanaged(*const FileFact) = .empty;
        var jpeg_width_proofs: std.StringHashMapUnmanaged(bool) = .empty;
        var authorities: std.StringHashMapUnmanaged(Record) = .empty;
        var observing = false;
        for (0..batches.count) |batch_index| {
            var scratch = std.heap.ArenaAllocator.init(arena.child_allocator);
            defer scratch.deinit();
            const temp = scratch.allocator();
            const batch = try batches.next(temp);
            if (batch.requests.len == 0 or batch.requests.len > 50) return invalid;
            const supplement = batch.observed_svg_width_px != null or batch.observed_svg_occurrences != null;
            if (batch.observed_svg_width_px != null and batch.observed_svg_occurrences != null) return invalid;
            if (batch.observed_svg_width_px) |observed| if (observed == 0) return invalid;
            if (batch.observed_svg_occurrences) |observations| {
                if (!gif or (!contract and !svgOccurrenceGenerator(doc.generator_sha256)) or observations.len == 0 or observations.len > 50) return invalid;
            }
            if (supplement) observing = true else if (observing) return invalid;
            try preflight(batch.response, false);
            const source = try std.json.parseFromSliceLeaky(Value, temp, batch.response, .{ .allocate = .alloc_always });
            const raw_general = try field(try field(source, "query"), "general");
            const batch_core = try string(raw_general, "git-hash");
            if (!equal(batch_core, doc.core_revision) and
                !(epochs and gif and responseEpoch(doc.core_revision) and responseEpoch(batch_core))) return invalid;
            if (batch.observed_svg_occurrences != null and !equal(batch_core, current_core)) return invalid;
            const query = try generalWithEpoch(source, ns.wiki, ns.content_language, server, batch_core, epochs);
            var tiff_companion: ?TiffCompanion = if (batch.tiff_metadata_response) |response| blk: {
                if (supplement or (!contract and !equal(doc.generator_sha256, file_generator_sha256))) return invalid;
                break :blk try TiffCompanion.init(temp, response, ns, server, batch_core, batch.requests.len, epochs);
            } else null;
            try mediaRegistration(query);
            const observed = try timestamp(try string(source, "curtimestamp"));
            if (observed.fraction.len != 0) return invalid;
            const pages = try field(query, "pages");
            if (pages != .array or pages.array.items.len > batch.requests.len) return invalid;
            for ([_][]const u8{ "interwiki", "converted" }) |name| {
                if (query.object.get(name)) |unsupported| if (nonempty(unsupported)) return invalid;
            }
            if (source.object.get("continue")) |continuation| {
                if (continuation != .object) return invalid;
                var entries = continuation.object.iterator();
                while (entries.next()) |entry| if (!equal(entry.key_ptr.*, "continue") and !equal(entry.key_ptr.*, "iicontinue") and !equal(entry.key_ptr.*, "iistart")) return invalid;
            }
            var mappings: std.StringHashMapUnmanaged([]const u8) = .empty;
            for ([_][]const u8{ "normalized", "redirects" }) |name| {
                const rows = query.object.get(name) orelse continue;
                if (rows != .array) return invalid;
                for (rows.array.items) |row| {
                    const from = try string(row, "from"); const to = try string(row, "to");
                    if (row.object.get("tofragment")) |fragment| if (nonempty(fragment)) return invalid;
                    const slot = try mappings.getOrPut(temp, from);
                    if (slot.found_existing and !equal(slot.value_ptr.*, to)) return invalid;
                    slot.value_ptr.* = to;
                }
            }
            var by_title: std.StringHashMapUnmanaged(Value) = .empty;
            for (pages.array.items) |page| {
                const title = try string(page, "title");
                const page_ns = try field(page, "ns");
                if (page_ns != .integer or page_ns.integer != 6 or hasHidden(page) or
                    page.object.contains("invalid") or page.object.contains("interwiki")) return invalid;
                const slot = try by_title.getOrPut(temp, title);
                if (slot.found_existing) return invalid;
                slot.value_ptr.* = page;
            }
            var used_pages: std.StringHashMapUnmanaged(void) = .empty;
            var used_requests: std.StringHashMapUnmanaged(void) = .empty;
            for (batch.requests) |requested| {
                const fact = facts.get(requested) orelse return invalid;
                if ((try used_requests.getOrPut(temp, requested)).found_existing) return invalid;
                if (batch.observed_svg_width_px != null) {
                    if ((fact.observed_batch orelse return invalid) != batch_index or !used_facts.contains(requested)) return invalid;
                } else if (batch.observed_svg_occurrences != null) {
                    if (!used_facts.contains(requested) or !equal(requested, fact.canonical_file) or
                        fact.state != .eligible or !equal(fact.mime, "image/svg+xml") or !equal(fact.mediatype, "DRAWING")) return invalid;
                } else if (fact.batch != batch_index or (try used_facts.getOrPut(a, fact.requested_file)).found_existing) return invalid;
                var current = requested;
                var seen: [50][]const u8 = undefined;
                var count: usize = 0;
                while (mappings.get(current)) |next| {
                    if (equal(current, next)) break;
                    if (count == seen.len) return invalid;
                    for (seen[0..count]) |prior| if (equal(prior, current)) return invalid;
                    seen[count] = current; count += 1; current = next;
                }
                const page = by_title.get(current) orelse return invalid;
                _ = try used_pages.getOrPut(temp, current);
                const repository = try string(page, "imagerepository");
                const imageinfo = page.object.get("imageinfo");
                const no_info = imageinfo == null or imageinfo.? == .null;
                const redirect = if (page.object.get("redirect")) |flag| nonempty(flag) else false;
                if (equal(repository, "") and no_info and !redirect) {
                    if (supplement) return invalid;
                    const missing_canonical = try canonicalFile(temp, ns, current);
                    if (fact.state != .missing or !equal(fact.canonical_file, missing_canonical) or fact.original_width != 0 or fact.original_height != 0 or
                        fact.file_sha1.len != 0 or fact.file_timestamp.len != 0 or fact.mime.len != 0 or fact.mediatype.len != 0 or fact.observed_svg_width_px != null) return invalid;
                    const prior = try canonical_facts.getOrPut(a, fact.canonical_file);
                    if (prior.found_existing and !sameFileFact(prior.value_ptr.*.*, fact.*)) return invalid;
                    prior.value_ptr.* = fact;
                    continue;
                }
                if ((!equal(repository, "shared") and !equal(repository, "local")) or imageinfo == null) return invalid;
                const info = imageinfo.?;
                if (info != .array or info.array.items.len != 1) return invalid;
                const image = info.array.items[0];
                if (hasHidden(image)) return invalid;
                const width_value = try field(image, "width"); const height_value = try field(image, "height");
                if (width_value != .integer or height_value != .integer) return invalid;
                const width = std.math.cast(u32, width_value.integer) orelse return invalid;
                const height = std.math.cast(u32, height_value.integer) orelse return invalid;
                const canonical = try canonicalFile(temp, ns, try string(image, "canonicaltitle"));
                if (!equal(canonical, fact.canonical_file) or !equal(try string(image, "sha1"), fact.file_sha1) or
                    !equal(try string(image, "timestamp"), fact.file_timestamp) or !lowerHex(fact.file_sha1, 40) or
                    !notAfter(try timestamp(fact.file_timestamp), observed) or width != fact.original_width or height != fact.original_height or
                    !equal(try string(image, "mime"), fact.mime) or !equal(try string(image, "mediatype"), fact.mediatype) or
                    !nonnegativeInteger(try field(image, "size"))) return invalid;
                if (fact.mime.len == 0) return invalid;
                const media_types = [_][]const u8{ "UNKNOWN", "BITMAP", "DRAWING", "AUDIO", "VIDEO", "MULTIMEDIA", "OFFICE", "TEXT", "EXECUTABLE", "ARCHIVE", "3D" };
                var known_media_type = false;
                for (media_types) |name| if (equal(name, fact.mediatype)) { known_media_type = true; break; };
                if (!known_media_type) return invalid;
                var eligible = width > 0 and height > 0;
                if (if (gif and equal(fact.mime, gif_handler.mime)) @as(?HandlerFamily, gif_handler) else handlerFamily(fact.mime)) |family| {
                    if (!equal(family.mediatype, fact.mediatype)) return invalid;
                    if (equal(fact.mime, "image/tiff")) {
                        const tiff_info = if (tiff_companion) |*companion|
                            try companion.matchingInfo(temp, ns, requested, repository, image) else image;
                        tiffPageAxes(temp, tiff_info, width, height) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => eligible = false,
                        };
                    }
                } else eligible = false;
                if (fact.state != (if (eligible) FileState.eligible else FileState.unsupported)) return invalid;
                if (batch.observed_svg_width_px) |observed_width| {
                    if (!eligible or fact.observed_svg_width_px != observed_width or
                        observedSvgWidth(image, fact.mime, fact.mediatype, width, height) != observed_width) return invalid;
                    const observed_slot = try used_observations.getOrPut(a, fact.canonical_file);
                    if (observed_slot.found_existing) return invalid;
                    observed_slot.value_ptr.* = @intCast(batch_index);
                }
                const prior = try canonical_facts.getOrPut(a, fact.canonical_file);
                if (prior.found_existing and !sameFileFact(prior.value_ptr.*.*, fact.*)) return invalid;
                prior.value_ptr.* = fact;
                if (supplement) continue;
                if (!eligible) continue;
                if ((equal(batch_core, current_core) or (epochs and equal(batch_core, response_core))) and equal(fact.mime, "image/jpeg")) {
                    const proven = try jpegUnrotatedMetadata(temp, image);
                    const proof = try jpeg_width_proofs.getOrPut(a, fact.canonical_file);
                    // All authenticated rows for this file must agree on the
                    // grant. An alias cannot hide absent or rotated metadata.
                    proof.value_ptr.* = if (proof.found_existing) proof.value_ptr.* and proven else proven;
                }
                for ([_][]const u8{ fact.requested_file, fact.canonical_file }) |key| {
                    const record: Record = .{ .canonical_file = key, .file_sha1 = fact.file_sha1,
                        .file_timestamp = fact.file_timestamp, .original_width = width, .original_height = height,
                        .format = .thumbnail, .width_px = fact.observed_svg_width_px orelse width, .height_px = null, .sizing = .requested_fit,
                        .proof_kind = if (fact.observed_svg_width_px != null) "file-svg-observed-thumbnail-width" else "file-logical-axes-width-bound" };
                    const slot = try authorities.getOrPut(a, key);
                    if (slot.found_existing and (slot.value_ptr.original_width != width or slot.value_ptr.original_height != height or
                        slot.value_ptr.width_px != record.width_px or !equal(slot.value_ptr.proof_kind, record.proof_kind) or
                        !equal(slot.value_ptr.file_sha1, fact.file_sha1) or !equal(slot.value_ptr.file_timestamp, fact.file_timestamp))) return invalid;
                    slot.value_ptr.* = record;
                }
            }
            if (tiff_companion) |*companion| try companion.finish();
            if (used_pages.count() != by_title.count()) return invalid;
            if (batch.observed_svg_occurrences) |observations| {
                var observed_files: std.StringHashMapUnmanaged(void) = .empty;
                for (observations) |raw_observation| {
                    const parsed = try parseSvgHeightObservation(temp, ns, server, raw_observation);
                    if (!used_requests.contains(parsed.canonical_file)) return invalid;
                    const fact = facts.get(parsed.canonical_file) orelse return invalid;
                    if (!equal(fact.requested_file, fact.canonical_file)) return invalid;
                    const key = try svgHeightKey(temp, doc.wiki, parsed.title, parsed.canonical_file, parsed.options, parsed.height);
                    const declared = declared_heights.get(key) orelse return invalid;
                    if (declared.batch != batch_index) return invalid;
                    const width = observedSvgHtml(temp, ns, parsed.html, fact.canonical_file, fact.original_width, fact.original_height, parsed.height) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory, else => return invalid,
                    };
                    if (width != declared.observed_width_px) return invalid;
                    const slot = try height_occurrences.getOrPut(a, try a.dupe(u8, key));
                    if (slot.found_existing) return invalid;
                    slot.value_ptr.* = .{ .original_width = fact.original_width, .observation = declared };
                    _ = try observed_files.getOrPut(temp, fact.requested_file);
                }
                if (observed_files.count() != used_requests.count()) return invalid;
            }
        }
        try batches.finish();
        if (used_facts.count() != facts.count() or declared_heights.count() != height_occurrences.count()) return invalid;
        for (doc.records) |fact| {
            if (fact.observed_batch) |observed_batch| {
                if (used_observations.get(fact.canonical_file) != observed_batch) return invalid;
            }
            if (canonical_facts.get(fact.requested_file)) |canonical| {
                if (!sameFileFact(canonical.*, fact)) return invalid;
            }
        }
        var records: std.ArrayList(Record) = .empty;
        var values = authorities.valueIterator();
        while (values.next()) |record| try records.append(a, record.*);
        std.mem.sort(Record, records.items, {}, struct {
            fn less(_: void, left: Record, right: Record) bool { return std.mem.order(u8, left.canonical_file, right.canonical_file) == .lt; }
        }.less);
        const height_bounds = try a.alloc(HeightBound, records.items.len);
        for (records.items, height_bounds) |record, *bound| {
            const fact = facts.get(record.canonical_file) orelse canonical_facts.get(record.canonical_file) orelse return invalid;
            // GIFHandler inherits bitmap dimensions. Animation frame selection
            // does not change this box; no animation or pixel authority is stored.
            // SVG's deployment-dependent cap and paged TIFF remain excluded.
            bound.* = if (fact.state != .eligible or !equal(fact.mediatype, "BITMAP")) .none
                else if (equal(fact.mime, "image/png")) .png
                else if (equal(fact.mime, "image/jpeg")) (if (jpeg_width_proofs.get(fact.canonical_file) orelse false) .jpeg_unrotated else .bitmap)
                else if (gif and equal(fact.mime, "image/gif")) .gif else .none;
        }
        return .{ .arena = arena.*, .namespace_catalog = ns, .records = records.items,
            .file_authority = true, .height_bound_records = height_bounds, .height_occurrences = height_occurrences };
    }
    pub fn resolveHeightOccurrence(raw: ?*const anyopaque, a: A, wiki: []const u8, title: []const u8, file: []const u8, format_value: types.FigureFormat, options: []const u8, height: u32) A.Error!?u32 {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        if (!self.file_authority or format_value != .thumbnail or !equal(wiki, self.namespace_catalog.wiki)) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
        defer a.free(canonical);
        const key = svgHeightKey(a, wiki, title, canonical, options, height) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
        defer a.free(key);
        const authority = self.height_occurrences.get(key) orelse return null;
        return authority.original_width;
    }
    pub fn resolveHeightOnlyWidth(raw: ?*const anyopaque, a: A, file: []const u8, format_value: types.FigureFormat, height: u32) A.Error!?u32 {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        if (!self.file_authority or format_value != .thumbnail or height == 0) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, else => return null,
        };
        defer a.free(canonical);
        var lo: usize = 0; var hi = self.records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.records[mid].canonical_file, canonical) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo < self.records.len and lo < self.height_bound_records.len and self.height_bound_records[lo] != .none and
            equal(self.records[lo].canonical_file, canonical)) return self.records[lo].original_width;
        return null;
    }
    pub fn resolveWidthLimit(raw: ?*const anyopaque, a: A, file: []const u8, format_value: types.FigureFormat) A.Error!?u32 {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        if (!self.file_authority or format_value != .thumbnail) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, else => return null,
        };
        defer a.free(canonical);
        var lo: usize = 0; var hi = self.records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.records[mid].canonical_file, canonical) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo < self.records.len and lo < self.height_bound_records.len and (self.height_bound_records[lo] == .png or self.height_bound_records[lo] == .gif or self.height_bound_records[lo] == .jpeg_unrotated) and
            equal(self.records[lo].canonical_file, canonical)) return self.records[lo].original_width;
        return null;
    }
    pub fn deinit(self: *Registry) void { self.arena.deinit(); self.* = undefined; }
    pub fn resolve(raw: ?*const anyopaque, a: A, file: []const u8, format_value: types.FigureFormat, width: ?u32, height: ?u32) A.Error!?types.FigureSizingPolicy {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        if (format_value != .thumbnail or width == null or width.? == 0 or (height != null and height.? == 0)) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
        defer a.free(canonical);
        var lo: usize = 0; var hi = self.records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const record = self.records[mid];
            const order = std.mem.order(u8, record.canonical_file, canonical);
            if (order == .lt or (!self.file_authority and order == .eq and record.width_px < width.?)) lo = mid + 1 else hi = mid;
        }
        if (lo < self.records.len) {
            const record = self.records[lo];
            if (height != null and (!self.file_authority or lo >= self.height_bound_records.len or self.height_bound_records[lo] == .none)) return null;
            if (equal(record.canonical_file, canonical) and
                (if (self.file_authority) (width.? <= record.original_width or
                    observedSvgRasterLogicalWidth(record, width.?, height)) else record.width_px == width.?)) return record.sizing;
        }
        return null;
    }
};

const FileTestSource = struct {
    const Fixture = struct { projection: []const u8, raw: []const u8 };
    fn make(a: A, ns: *const namespaces.Registry, empty: bool) !Fixture {
        const site = try std.json.parseFromSliceLeaky(Value, a, TestSource.site, .{ .allocate = .alloc_always });
        var response = try std.json.parseFromSliceLeaky(Value, a, TestSource.raw, .{ .allocate = .alloc_always });
        try response.object.getPtr("query").?.object.put(a, "extensions", (try field(site, "query")).object.get("extensions").?);
        const response_bytes = try std.json.Stringify.valueAlloc(a, response, .{});
        const batches = [_]RawFileBatch{.{ .requests = &.{TestSource.file}, .response = response_bytes }};
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{
            .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = if (empty) &.{} else &batches,
        }, .{});
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        const records = [_]FileFact{.{
            .requested_file = TestSource.file, .canonical_file = TestSource.file, .state = .eligible, .batch = 0,
            .file_sha1 = "44a4d04788825a486a53b417a469d95b98113018", .file_timestamp = "2025-04-18T12:52:57Z",
            .original_width = 512, .original_height = 420, .mime = "image/svg+xml", .mediatype = "DRAWING",
        }};
        const projection = try std.json.Stringify.valueAlloc(a, FilesDocument{
            .schema = "wikidict.figure-sizing-files.v1", .wiki = ns.wiki, .content_language = ns.content_language,
            .core_revision = accepted_core, .namespace_registry_sha256 = &std.fmt.bytesToHex(ns.source_sha256, .lower),
            .raw_sha256 = &std.fmt.bytesToHex(hash, .lower), .generator_sha256 = file_generator_sha256,
            .source_profile = if (empty) .null else try TestSource.profileValue(a, TestSource.site),
            .records = if (empty) &.{} else &records,
        }, .{});
        return .{ .projection = projection, .raw = raw };
    }
};

test "figure file axes authorize only bounded thumbnail widths without computing heights" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var input_arena = std.heap.ArenaAllocator.init(a);
    var input_live = true; defer if (input_live) input_arena.deinit();
    const input = try FileTestSource.make(input_arena.allocator(), &ns, false);
    var registry = try Registry.init(a, input.projection, input.raw, TestSource.site, &ns, accepted_core, generator_sha256);
    defer registry.deinit();
    input_arena.deinit(); input_live = false;
    for ([_]u32{ 1, 399, 400, 401, 511, 512 }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]?u32{ null, 0, 513, std.math.maxInt(u32) }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]u32{ 0, 1, 328, 420 }) |height|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 400, height));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .framed, 400, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, "Missing.svg", .thumbnail, 400, null));
}

test "figure file axes replay rejects changed facts and unproved empty authority" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const input = try FileTestSource.make(arena.allocator(), &ns, false);
    for (0..9) |case| {
        var value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), input.projection, .{ .allocate = .alloc_always });
        const record = &value.object.getPtr("records").?.array.items[0];
        switch (case) {
            0 => try record.object.put(arena.allocator(), "original_width", .{ .integer = 513 }),
            1 => try record.object.put(arena.allocator(), "original_height", .{ .integer = 419 }),
            2 => try record.object.put(arena.allocator(), "file_sha1", .{ .string = "0000000000000000000000000000000000000000" }),
            3 => try record.object.put(arena.allocator(), "file_timestamp", .{ .string = "2026-01-01T00:00:00Z" }),
            4 => try record.object.put(arena.allocator(), "mime", .{ .string = "image/png" }),
            5 => try record.object.put(arena.allocator(), "state", .{ .string = "missing" }),
            6 => try record.object.put(arena.allocator(), "batch", .{ .integer = 1 }),
            7 => try value.object.put(arena.allocator(), "source_profile", .null),
            8 => value.object.getPtr("records").?.array.clearRetainingCapacity(),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(arena.allocator(), value, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed, input.raw, TestSource.site, &ns, accepted_core, generator_sha256));
    }
    const empty = try FileTestSource.make(arena.allocator(), &ns, true);
    var registry = try Registry.init(a, empty.projection, empty.raw, TestSource.site, &ns, accepted_core, generator_sha256);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.records.len);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 1, null));
}

test "figure file axes allocation failures preserve registry ownership" {
    const Check = struct {
        fn replay(a: A, input: FileTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try Registry.init(a, input.projection, input.raw, TestSource.site, ns, accepted_core, generator_sha256);
            defer registry.deinit();
            _ = try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 401, null);
        }
    };
    var ns = try TestSource.namespace(std.testing.allocator); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const input = try FileTestSource.make(arena.allocator(), &ns, false);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.replay, .{ input, &ns });
}

test "figure file aliases require consistent facts and each response timestamp" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    for (0..5) |case| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const scratch = arena.allocator();
        const input = try FileTestSource.make(scratch, &ns, false);
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, scratch, input.raw, .{ .allocate = .alloc_always });
        var batches: [2]RawFileBatch = undefined;
        var records: [2]FileFact = undefined;
        const aliases = [_][]const u8{ "Sary:A.svg", "Sary:B.svg" };
        for (aliases, 0..) |alias, index| {
            var response = try std.json.parseFromSliceLeaky(Value, scratch, original.batches[0].response, .{ .allocate = .alloc_always });
            const query = response.object.getPtr("query").?;
            const redirects = try std.json.Stringify.valueAlloc(scratch, .{.{ .from = alias, .to = TestSource.file }}, .{});
            try query.object.put(scratch, "redirects", try std.json.parseFromSliceLeaky(Value, scratch, redirects, .{ .allocate = .alloc_always }));
            const doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, input.projection, .{ .allocate = .alloc_always });
            records[index] = doc.records[0];
            records[index].requested_file = alias; records[index].batch = @intCast(index);
            if (index == 1 and case == 1) {
                try query.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0].object.put(scratch, "width", .{ .integer = 513 });
                records[index].original_width = 513;
            }
            if (index == 1 and (case == 2 or case == 4)) {
                // A canonical name cannot simultaneously be an explicit miss.
                records[index] = .{ .requested_file = if (case == 4) alias else TestSource.file, .canonical_file = TestSource.file,
                    .state = .missing, .batch = 1, .file_sha1 = "", .file_timestamp = "",
                    .original_width = 0, .original_height = 0, .mime = "", .mediatype = "" };
                const pages = try std.json.Stringify.valueAlloc(scratch, .{.{ .title = TestSource.file, .ns = 6, .imagerepository = "", .missing = true }}, .{});
                if (case == 2) _ = query.object.swapRemove("redirects");
                try query.object.put(scratch, "pages", try std.json.parseFromSliceLeaky(Value, scratch, pages, .{ .allocate = .alloc_always }));
            }
            if (index == 0 and case == 3) try response.object.put(scratch, "curtimestamp", .{ .string = "2020-01-01T00:00:00Z" });
            const request = try scratch.alloc([]const u8, 1);
            request[0] = records[index].requested_file;
            batches[index] = .{ .requests = request, .response = try std.json.Stringify.valueAlloc(scratch, response, .{}) };
        }
        const raw = try std.json.Stringify.valueAlloc(scratch, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = &batches }, .{});
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, input.projection, .{ .allocate = .alloc_always });
        const raw_digest = std.fmt.bytesToHex(hash, .lower);
        doc.records = &records; doc.raw_sha256 = &raw_digest;
        const projection = try std.json.Stringify.valueAlloc(scratch, doc, .{});
        if (case != 0) {
            try std.testing.expectError(invalid, Registry.init(a, projection, raw, TestSource.site, &ns, accepted_core, generator_sha256));
        } else {
            var registry = try Registry.init(a, projection, raw, TestSource.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
            for ([_][]const u8{ aliases[0], aliases[1], TestSource.file }) |name|
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, 401, null));
        }
    }
}

const TestSource = struct {
    const raw = @embedFile("testdata/figure-sizing/mg-map-site-sizing.raw.json");
    const site = @embedFile("testdata/figure-sizing/wmf-svg-site-extensions.raw.json");
    const ns_bytes = @embedFile("testdata/figure-sizing/mg-namespace-registry.tsv");
    const file = "Sary:MapOfAinuLanguage-Milk.svg";

    fn namespace(a: A) !namespaces.Registry {
        var ns = try namespaces.Registry.init(a, ns_bytes);
        // Controlled source-context input. The full Writer test separately
        // exercises the real site-info loader and generated auxiliary trio.
        ns.figure_source_defaults = .{ .rtl = false };
        return ns;
    }
    fn profileValue(a: A, site_bytes: []const u8) !Value {
        var result: Value = .{ .object = .empty };
        for (profile_strings) |pair| try result.object.put(a, pair[0], .{ .string = pair[1] });
        var families: Value = .{ .object = .empty };
        for (handler_families) |family| {
            var item: Value = .{ .object = .empty };
            try item.object.put(a, "handler_class", .{ .string = family.handler_class });
            try item.object.put(a, "mediatype", .{ .string = family.mediatype });
            try families.object.put(a, family.mime, item);
        }
        try result.object.put(a, "handler_families", families);
        var extensions: Value = .{ .object = .empty };
        for (media_extensions) |pair| try extensions.object.put(a, pair[0], .{ .string = pair[1] });
        try result.object.put(a, "media_extensions", extensions);
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(site_bytes, &hash, .{});
        try result.object.put(a, "site_raw_sha256", .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
        return result;
    }
    fn projection(a: A, ns: *const namespaces.Registry, raw_bytes: []const u8, site_bytes: []const u8) ![]u8 {
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw_bytes, &hash, .{});
        const records = [_]Record{.{
            .canonical_file = file, .file_sha1 = "44a4d04788825a486a53b417a469d95b98113018", .file_timestamp = "2025-04-18T12:52:57Z",
            .original_width = 512, .original_height = 420, .format = .thumbnail, .width_px = 400,
            .height_px = null, .sizing = .requested_fit, .proof_kind = "thumbnail-width-not-above-original",
        }};
        return std.json.Stringify.valueAlloc(a, Document{
            .schema = "wikidict.figure-sizing-source.v1", .wiki = ns.wiki, .content_language = ns.content_language, .core_revision = accepted_core,
            .namespace_registry_sha256 = &std.fmt.bytesToHex(ns.source_sha256, .lower), .observation_utc = "2026-11-08T05:38:08Z",
            .raw_sha256 = &std.fmt.bytesToHex(hash, .lower), .generator_sha256 = generator_sha256,
            .source_profile = try profileValue(a, site_bytes), .records = &records,
        }, .{});
    }
    fn record(value: *Value) !*Value {
        const rows = value.object.getPtr("records") orelse return invalid;
        if (rows.* != .array or rows.array.items.len != 1) return invalid;
        return &rows.array.items[0];
    }
};

test "figure sizing source owns exact occurrence authority after input arena release" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source_arena = std.heap.ArenaAllocator.init(a);
    var source_live = true; defer if (source_live) source_arena.deinit();
    const input = source_arena.allocator();
    const raw = try input.dupe(u8, TestSource.raw);
    const site = try input.dupe(u8, TestSource.site);
    const projection = try TestSource.projection(input, &ns, raw, site);
    var registry = try Registry.init(a, projection, raw, site, &ns, accepted_core, generator_sha256); defer registry.deinit();
    source_arena.deinit(); source_live = false;
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, "MapOfAinuLanguage-Milk.svg", .thumbnail, 400, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 401, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .framed, 400, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 400, 328));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, "Different.svg", .thumbnail, 400, null));
    try std.testing.expectEqual(@as(u32, 512), registry.records[0].original_width);
    try std.testing.expectEqual(@as(u32, 420), registry.records[0].original_height);
    try std.testing.expectEqualStrings("2025-04-18T12:52:57Z", registry.records[0].file_timestamp);
    try std.testing.expectEqualStrings(TestSource.file, registry.records[0].canonical_file);
}

test "figure sizing replay refuses rehashed false numeric source profile and occurrence records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const original = try TestSource.projection(a, &ns, TestSource.raw, TestSource.site);
    for (0..10) |case| {
        var value = try std.json.parseFromSliceLeaky(Value, a, original, .{ .allocate = .alloc_always });
        const row = try TestSource.record(&value);
        switch (case) {
            0 => try row.object.put(a, "width_px", .{ .number_string = "400.0" }),
            1 => try row.object.put(a, "width_px", .{ .bool = true }),
            2 => try row.object.put(a, "original_width", .{ .integer = 513 }),
            3 => try row.object.put(a, "height_px", .{ .integer = 328 }),
            4 => try row.object.put(a, "canonical_file", .{ .string = "Sary:Other.svg" }),
            5 => try row.object.put(a, "file_timestamp", .{ .string = "2026-11-08T05:38:08.0000001Z" }),
            6 => try value.object.put(a, "namespace_registry_sha256", .{ .string = "changed" }),
            7 => try value.object.put(a, "generator_sha256", .{ .string = "changed" }),
            8 => try value.object.getPtr("source_profile").?.object.getPtr("handler_families").?.object.getPtr("image/svg+xml").?.object.put(a, "handler_class", .{ .string = "OtherHandler" }),
            9 => try value.object.put(a, "wiki", .{ .string = "enwiktionary" }),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(a, value, .{});
        if (case == 0) {
            var lexical = try std.json.parseFromSliceLeaky(Value, a, changed, .{ .parse_numbers = false });
            const token = (try TestSource.record(&lexical)).object.get("width_px").?;
            try std.testing.expect(token == .number_string);
            try std.testing.expectEqualStrings("400.0", token.number_string);
        }
        try std.testing.expectError(error.InvalidFigureSizingSource, Registry.init(a, changed, TestSource.raw, TestSource.site, &ns, accepted_core, generator_sha256));
    }
    for ([_][]const u8{ "filehidden", "suppressed", "filemissing" }) |flag| {
        var raw = try std.json.parseFromSliceLeaky(Value, a, TestSource.raw, .{ .allocate = .alloc_always });
        const query = raw.object.getPtr("query").?;
        const page = &query.object.getPtr("pages").?.array.items[0];
        try page.object.put(a, flag, .{ .bool = true });
        const raw_bytes = try std.json.Stringify.valueAlloc(a, raw, .{});
        const projection = try TestSource.projection(a, &ns, raw_bytes, TestSource.site);
        try std.testing.expectError(error.InvalidFigureSizingSource, Registry.init(a, projection, raw_bytes, TestSource.site, &ns, accepted_core, generator_sha256));
    }
    for ([_]?[]const u8{ null, "79b81ba96674efc8a803fc956bc501d347d440d2", "unproved" }) |source_revision|
        try std.testing.expectError(error.InvalidFigureSizingSource, Registry.init(a, original, TestSource.raw, TestSource.site, &ns, source_revision, generator_sha256));
    ns.figure_source_defaults = null;
    // The explicit independent source role is required; namespace defaults
    // alone no longer stand in for that proof.
    try std.testing.expectError(error.InvalidFigureSizingSource, Registry.init(a, original, TestSource.raw, TestSource.site, &ns, null, generator_sha256));
}

test "figure sizing source timestamps compare exact decimal precision and reject noncanonical dates" {
    const observed = try timestamp("2026-11-08T05:38:08Z");
    try std.testing.expect(!notAfter(try timestamp("2026-11-08T05:38:08.0000001Z"), observed));
    try std.testing.expect(notAfter(try timestamp("2026-11-08T05:38:08.0000000Z"), observed));
    try std.testing.expect(notAfter(try timestamp("2026-11-08T05:38:07.999999999999999999Z"), observed));
    try std.testing.expect(notAfter(try timestamp("2024-02-29T23:59:59Z"), observed));
    for ([_][]const u8{ "2026-02-29T00:00:00Z", "20261108T05:38:08Z", "2026-W45-7T05:38:08Z", "2026-11-08 05:38:08Z", "2026-11-08T05:38:08.Z", "2026-11-08T05:38:60Z" }) |value|
        try std.testing.expectError(error.InvalidFigureSizingSource, timestamp(value));
}

test "figure sizing source initialization and immutable lookup preserve allocation failure" {
    const Check = struct {
        fn init(a: A, projection: []const u8, ns: *const namespaces.Registry) !void {
            var registry = try Registry.init(a, projection, TestSource.raw, TestSource.site, ns, accepted_core, generator_sha256);
            defer registry.deinit();
            const policy = try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 400, null);
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), policy);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const projection = try TestSource.projection(a, &ns, TestSource.raw, TestSource.site);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.init, .{ projection, &ns });
}


test "figure sizing preflight bounds scalar record arrays before materialization" {
    const a = std.testing.allocator;
    const prefix = "{\"records\":[";
    const suffix = "]}";
    const item = "null,";
    const bytes = try a.alloc(u8, prefix.len + item.len * max_records + 4 + suffix.len);
    defer a.free(bytes);
    @memcpy(bytes[0..prefix.len], prefix);
    for (0..max_records) |i| @memcpy(bytes[prefix.len + i * item.len ..][0..item.len], item);
    @memcpy(bytes[prefix.len + max_records * item.len ..][0..4], "null");
    @memcpy(bytes[bytes.len - suffix.len ..], suffix);
    try std.testing.expectError(error.InvalidFigureSizingSource, preflight(bytes, true));
}

const JpegTestSource = struct {
    const raw = @embedFile("testdata/figure-sizing/uz-jpeg-site.raw.json");
    const ns_bytes = @embedFile("testdata/figure-sizing/uz-namespace-registry.tsv");
    const files = [_][]const u8{ "Fayl:Lao Textile Museum 5.jpg", "Fayl:Length of woven silk MET TP208.jpg" };
    const records = [_]Record{
        .{ .canonical_file = files[0], .file_sha1 = "1c478170a0eafc8ecb0fa598417b796af55a9633", .file_timestamp = "2020-02-21T14:17:03Z", .original_width = 4096, .original_height = 3072, .format = .thumbnail, .width_px = 250, .height_px = null, .sizing = .requested_fit, .proof_kind = "thumbnail-width-not-above-original" },
        .{ .canonical_file = files[1], .file_sha1 = "d28aa7c07e80e2d67a4b6afe75b32ace57fcd915", .file_timestamp = "2017-06-22T15:07:25Z", .original_width = 2251, .original_height = 2899, .format = .thumbnail, .width_px = 250, .height_px = null, .sizing = .requested_fit, .proof_kind = "thumbnail-width-not-above-original" },
    };
    fn namespace(a: A) !namespaces.Registry {
        var ns = try namespaces.Registry.init(a, ns_bytes);
        // Controlled context only; full UZ Writer uses the normal site-info loader.
        ns.figure_source_defaults = .{ .rtl = false };
        return ns;
    }
    fn projection(a: A, ns: *const namespaces.Registry, raw_bytes: []const u8) ![]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw_bytes, &hash, .{});
        // A controlled native replay fixture, not a claimed normal helper output.
        return std.json.Stringify.valueAlloc(a, Document{
            .schema = "wikidict.figure-sizing-source.v1", .wiki = ns.wiki, .content_language = ns.content_language, .core_revision = accepted_core,
            .namespace_registry_sha256 = &std.fmt.bytesToHex(ns.source_sha256, .lower), .observation_utc = "2026-11-08T16:32:44Z",
            .raw_sha256 = &std.fmt.bytesToHex(hash, .lower), .generator_sha256 = generator_sha256,
            .source_profile = try TestSource.profileValue(a, raw_bytes), .records = &records,
        }, .{});
    }
};

test "figure sizing replays actual normal SVG and JPEG projections without cross site authority" {
    const a = std.testing.allocator;
    var mg = try TestSource.namespace(a); defer mg.deinit();
    var uz = try JpegTestSource.namespace(a); defer uz.deinit();
    // These are unchanged normal helper outputs, separate from the controlled
    // mutation fixtures. Namespace defaults remain a controlled input here;
    // full Writer controls exercise the normal site-info loader.
    const mg_projection = @embedFile("testdata/figure-sizing/figure-sizing.json");
    const uz_projection = @embedFile("testdata/figure-sizing/uz-figure-sizing.json");
    var svg = try Registry.init(a, mg_projection, TestSource.raw, TestSource.site, &mg, accepted_core, generator_sha256);
    defer svg.deinit();
    var jpeg = try Registry.init(a, uz_projection, JpegTestSource.raw, JpegTestSource.raw, &uz, accepted_core, generator_sha256);
    defer jpeg.deinit();
    try std.testing.expectEqual(@as(usize, 2), svg.records.len);
    try std.testing.expectEqual(@as(usize, 2), jpeg.records.len);
    for (svg.records, [_]u32{ 250, 400 }) |actual, width| {
        try std.testing.expectEqualStrings(TestSource.file, actual.canonical_file);
        try std.testing.expectEqualStrings("44a4d04788825a486a53b417a469d95b98113018", actual.file_sha1);
        try std.testing.expectEqual(@as(u32, 512), actual.original_width);
        try std.testing.expectEqual(@as(u32, 420), actual.original_height);
        try std.testing.expectEqual(width, actual.width_px);
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&svg, a, actual.canonical_file, .thumbnail, width, null));
    }
    for (jpeg.records, JpegTestSource.records) |actual, expected| {
        try std.testing.expectEqualStrings(expected.canonical_file, actual.canonical_file);
        try std.testing.expectEqualStrings(expected.file_sha1, actual.file_sha1);
        try std.testing.expectEqualStrings(expected.file_timestamp, actual.file_timestamp);
        try std.testing.expectEqual(expected.original_width, actual.original_width);
        try std.testing.expectEqual(expected.original_height, actual.original_height);
        try std.testing.expectEqual(expected.width_px, actual.width_px);
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&jpeg, a, actual.canonical_file, .thumbnail, 250, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&svg, a, actual.canonical_file, .thumbnail, 250, null));
    }
    try std.testing.expectError(invalid, Registry.init(a, uz_projection, JpegTestSource.raw, JpegTestSource.raw, &mg, accepted_core, generator_sha256));
    try std.testing.expectError(invalid, Registry.init(a, mg_projection, TestSource.raw, TestSource.site, &uz, accepted_core, generator_sha256));
    try std.testing.expectError(invalid, Registry.init(a, mg_projection, TestSource.raw, JpegTestSource.raw, &mg, accepted_core, generator_sha256));
}

test "figure sizing replay does not borrow defaults or conversion from the namespace role" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, JpegTestSource.ns_bytes); defer ns.deinit();
    try std.testing.expect(ns.figure_source_defaults == null and ns.manual_conversion_context == null);
    const projection = @embedFile("testdata/figure-sizing/uz-figure-sizing.json");
    var registry = try Registry.init(a, projection, JpegTestSource.raw, JpegTestSource.raw, &ns, accepted_core, generator_sha256);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), registry.records.len);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, JpegTestSource.files[0], .thumbnail, 250, null));
    try std.testing.expectError(invalid, Registry.init(a, projection, JpegTestSource.raw, JpegTestSource.raw, &ns, null, generator_sha256));
    try std.testing.expectError(invalid, Registry.init(a, projection, JpegTestSource.raw, JpegTestSource.raw, &ns, "79b81ba96674efc8a803fc956bc501d347d440d2", generator_sha256));
    try std.testing.expect(ns.figure_source_defaults == null and ns.manual_conversion_context == null);
}

test "figure sizing JPEG replay retains two exact logical source axes and occurrence ownership" {
    const a = std.testing.allocator;
    var ns = try JpegTestSource.namespace(a); defer ns.deinit();
    var source_arena = std.heap.ArenaAllocator.init(a);
    var source_live = true; defer if (source_live) source_arena.deinit();
    const raw = try source_arena.allocator().dupe(u8, JpegTestSource.raw);
    const projection = try JpegTestSource.projection(source_arena.allocator(), &ns, raw);
    var registry = try Registry.init(a, projection, raw, raw, &ns, accepted_core, generator_sha256); defer registry.deinit();
    source_arena.deinit(); source_live = false;
    try std.testing.expectEqual(@as(usize, 2), registry.records.len);
    for (registry.records, JpegTestSource.records) |actual, expected| {
        try std.testing.expectEqualStrings(expected.canonical_file, actual.canonical_file);
        try std.testing.expectEqualStrings(expected.file_sha1, actual.file_sha1);
        try std.testing.expectEqualStrings(expected.file_timestamp, actual.file_timestamp);
        try std.testing.expectEqual(expected.original_width, actual.original_width);
        try std.testing.expectEqual(expected.original_height, actual.original_height);
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, actual.canonical_file, .thumbnail, 250, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, actual.canonical_file, .thumbnail, 251, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, actual.canonical_file, .thumbnail, 250, 100));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, actual.canonical_file, .framed, 250, null));
    }
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, "Other.jpg", .thumbnail, 250, null));
}

test "figure sizing compound profile refuses legacy unknown and changed handler families" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const original = try TestSource.profileValue(a, JpegTestSource.raw);
    const bytes = try std.json.Stringify.valueAlloc(a, original, .{});
    try profile(original, JpegTestSource.raw);
    for (0..7) |case| {
        var value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
        const families = value.object.getPtr("handler_families").?;
        switch (case) {
            0 => { _ = families.object.swapRemove("image/jpeg"); },
            1 => try families.object.put(a, "image/png", families.object.get("image/jpeg").?),
            2 => try families.object.getPtr("image/jpeg").?.object.put(a, "handler_class", .{ .string = "OtherHandler" }),
            3 => try families.object.getPtr("image/jpeg").?.object.put(a, "mediatype", .{ .string = "DRAWING" }),
            4 => try families.object.getPtr("image/svg").?.object.put(a, "extra", .null),
            5 => try value.object.put(a, "jpeg_handler_sha256", .{ .string = "changed" }),
            6 => {
                _ = value.object.swapRemove("handler_families");
                try value.object.put(a, "kind", .{ .string = "wikimedia-svg-imagehandler-v1" });
                try value.object.put(a, "handler_class", .{ .string = "MediaWiki\\Media\\SvgHandler" });
                try value.object.put(a, "mime_types", .{ .array = std.array_list.Managed(Value).init(a) });
            },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidFigureSizingSource, profile(value, JpegTestSource.raw));
    }
}

test "figure sizing JPEG replay rejects rehashed MIME axes and file identity substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try JpegTestSource.namespace(a); defer ns.deinit();
    for (0..8) |case| {
        var value = try std.json.parseFromSliceLeaky(Value, a, JpegTestSource.raw, .{ .allocate = .alloc_always });
        const page = &value.object.getPtr("query").?.object.getPtr("pages").?.array.items[0];
        const image_value = &page.object.getPtr("imageinfo").?.array.items[0];
        switch (case) {
            0 => try image_value.object.put(a, "mime", .{ .string = "image/gif" }),
            1 => try image_value.object.put(a, "mediatype", .{ .string = "DRAWING" }),
            2 => try image_value.object.put(a, "width", .{ .integer = 2899 }),
            3 => try image_value.object.put(a, "height", .{ .integer = 2251 }),
            4 => try image_value.object.put(a, "sha1", .{ .string = JpegTestSource.records[0].file_sha1 }),
            5 => try image_value.object.put(a, "width", .{ .number_string = "2251.0" }),
            6 => try image_value.object.put(a, "timestamp", .{ .string = "2026-11-08T16:32:44.0000001Z" }),
            7 => { _ = page.object.swapRemove("imageinfo"); },
            else => unreachable,
        }
        const raw = try std.json.Stringify.valueAlloc(a, value, .{});
        if (case == 5) {
            const lexical = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .parse_numbers = false });
            const token = lexical.object.get("query").?.object.get("pages").?.array.items[0].object.get("imageinfo").?.array.items[0].object.get("width").?;
            try std.testing.expect(token == .number_string);
            try std.testing.expectEqualStrings("2251.0", token.number_string);
        }
        const projection = try JpegTestSource.projection(a, &ns, raw);
        try std.testing.expectError(error.InvalidFigureSizingSource, Registry.init(a, projection, raw, raw, &ns, accepted_core, generator_sha256));
    }
}

test "figure sizing compound profile preserves the full record preallocation boundary" {
    const a = std.testing.allocator;
    const prefix = "{\"source_profile\":{\"handler_families\":{\"image/svg+xml\":{},\"image/svg\":{},\"image/jpeg\":{},\"image/png\":{},\"image/tiff\":{}},\"media_extensions\":{}},\"records\":[";
    var bytes: std.ArrayList(u8) = .empty; defer bytes.deinit(a);
    try bytes.appendSlice(a, prefix);
    for (0..max_records) |i| {
        if (i != 0) try bytes.append(a, ',');
        try bytes.appendSlice(a, "{}");
    }
    try bytes.appendSlice(a, "]}");
    try preflight(bytes.items, true);
    bytes.shrinkRetainingCapacity(bytes.items.len - 2);
    try bytes.appendSlice(a, ",{}]}");
    try std.testing.expectError(error.InvalidFigureSizingSource, preflight(bytes.items, true));
}

const TiffTestSource = struct {
    const raw = @embedFile("testdata/figure-sizing/eo-png-tiff-site.raw.json");
    fn image(a: A) !Value {
        const root = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
        const query = try field(root, "query");
        const pages = try field(query, "pages");
        for (pages.array.items) |page| {
            const images = try field(page, "imageinfo");
            const item = images.array.items[0];
            if (equal(try string(item, "mime"), "image/tiff")) return item;
        }
        return error.TestUnexpectedResult;
    }
    fn named(list: *Value, name: []const u8) !*Value {
        if (list.* != .array) return error.TestUnexpectedResult;
        for (list.array.items) |*node| if (equal(try string(node.*, "name"), name))
            return node.object.getPtr("value") orelse error.TestUnexpectedResult;
        return error.TestUnexpectedResult;
    }
};

test "figure sizing PNG and single page TIFF retain exact handler axes and reject ambiguous metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(digestMatches(TiffTestSource.raw, "b6c16369227849d5824c31ef26f52daa50f4d2fc38ddcd8704e10316ac738d06"));
    // This exact response has depth12,399 objects and33 arrays; the existing
    // response byte/depth bounds remain unchanged by the metadata replay.
    try preflight(TiffTestSource.raw, false);
    try std.testing.expectEqualStrings("MediaWiki\\Media\\PNGHandler", (handlerFamily("image/png") orelse return error.TestUnexpectedResult).handler_class);
    try std.testing.expectEqualStrings("MediaWiki\\Extension\\PagedTiffHandler\\PagedTiffHandler", (handlerFamily("image/tiff") orelse return error.TestUnexpectedResult).handler_class);
    try std.testing.expect(handlerFamily("image/gif") == null);
    const original = try TiffTestSource.image(a);
    try std.testing.expectEqual(@as(u32, 2420), try positive(original, "width"));
    try std.testing.expectEqual(@as(u32, 3000), try positive(original, "height"));
    try tiffPageAxes(a, original, 2420, 3000);
    var string_page = try TiffTestSource.image(a);
    const string_metadata = string_page.object.getPtr("metadata").?;
    const string_pages = try TiffTestSource.named(string_metadata, "page_data");
    try string_pages.array.items[0].object.put(a, "name", .{ .string = "1" });
    try tiffPageAxes(a, string_page, 2420, 3000);
    for (0..17) |case| {
        var image = try TiffTestSource.image(a);
        const metadata = image.object.getPtr("metadata").?;
        const pages = try TiffTestSource.named(metadata, "page_data");
        const page = pages.array.items[0].object.getPtr("value").?;
        switch (case) {
            0 => try image.object.put(a, "pagecount", .{ .integer = 2 }),
            1 => try image.object.put(a, "pagecount", .{ .bool = true }),
            2 => (try TiffTestSource.named(metadata, "page_count")).* = .{ .float = 1.0 },
            3 => (try TiffTestSource.named(metadata, "first_page")).* = .{ .integer = 0 },
            4 => (try TiffTestSource.named(metadata, "last_page")).* = .{ .integer = 2 },
            5 => (try TiffTestSource.named(metadata, "TIFF_METADATA_VERSION")).* = .{ .string = "1.3" },
            6 => try pages.array.append(pages.array.items[0]),
            7 => try pages.array.items[0].object.put(a, "name", .{ .string = "01" }),
            8 => try pages.array.items[0].object.put(a, "name", .{ .bool = true }),
            9 => (try TiffTestSource.named(page, "page")).* = .{ .integer = 2 },
            10 => (try TiffTestSource.named(page, "width")).* = .{ .integer = 3000 },
            11 => (try TiffTestSource.named(page, "height")).* = .{ .bool = true },
            12 => try metadata.array.append(metadata.array.items[0]),
            13 => try page.array.append(page.array.items[0]),
            14 => try metadata.array.items[0].object.put(a, "extra", .null),
            15 => try metadata.array.items[1].object.put(a, "name", .{ .string = "errors" }),
            16 => try metadata.array.items[1].object.put(a, "name", .{ .string = "_error" }),
            else => unreachable,
        }
        try std.testing.expectError(invalid, tiffPageAxes(a, image, 2420, 3000));
    }
    var oversized: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try oversized.array.appendNTimes(.null, 4097);
    try std.testing.expectError(invalid, metadataFields(a, oversized));
}

test "figure sizing TIFF metadata map ownership preserves allocation failure cleanup" {
    const Check = struct {
        fn replay(a: A, image: Value) !void { try tiffPageAxes(a, image, 2420, 3000); }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const image = try TiffTestSource.image(arena.allocator());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.replay, .{image});
}

test "figure sizing replays actual normal PNG TIFF and JPEG tuples with strict single page metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try namespaces.Registry.init(a, @embedFile("testdata/figure-sizing/eo-namespace-registry.tsv")); defer ns.deinit();
    const projection = @embedFile("testdata/figure-sizing/eo-figure-sizing.json");
    const raw = TiffTestSource.raw;
    var registry = try Registry.init(a, projection, raw, raw, &ns, accepted_core, generator_sha256); defer registry.deinit();
    // Expected identities/axes come from the retained source response, not the
    // projection generator. All six selected occurrences request200/noheight.
    const Expected = struct { file: []const u8, sha1: []const u8, timestamp: []const u8, width: u32, height: u32 };
    const expected = [_]Expected{
        .{ .file = "Dosiero:A close-up view of a five-yard dipper on electric shovel - NARA - 294280.tif", .sha1 = "31903129101b972514e4d035cdda76a3e51ef8bb", .timestamp = "2011-09-19T18:18:35Z", .width = 2420, .height = 3000 },
        .{ .file = "Dosiero:A view of rental buckets for devotees in Siththar Temple, Salem.JPG", .sha1 = "d5ffe47b311d3b99f34fbde18702da4a6ae956b6", .timestamp = "2011-12-26T20:05:49Z", .width = 3648, .height = 2736 },
        .{ .file = "Dosiero:Abortkübel.jpg", .sha1 = "72441fb532bb052269a857c0164aee981dafe39a", .timestamp = "2011-07-25T09:54:32Z", .width = 1500, .height = 1125 },
        .{ .file = "Dosiero:Balde.PNG", .sha1 = "9048d45172267cefa0366a1f8cecc47e1852467b", .timestamp = "2022-03-03T07:41:54Z", .width = 202, .height = 226 },
        .{ .file = "Dosiero:Closet Abortkuebel.jpg", .sha1 = "288424568b9920a151445c8031865d91643c3195", .timestamp = "2011-02-25T21:38:26Z", .width = 2800, .height = 2100 },
        .{ .file = "Dosiero:River cane soaking, Cherokee Camp, Colonial Williamsburg - Stierch.jpg", .sha1 = "a6164c05d93f0703f8e6f428ce8e41eb1284afa0", .timestamp = "2010-06-10T02:01:28Z", .width = 768, .height = 1024 },
    };
    try std.testing.expectEqual(expected.len, registry.records.len);
    for (registry.records, expected) |record, source| {
        try std.testing.expectEqualStrings(source.file, record.canonical_file);
        try std.testing.expectEqualStrings(source.sha1, record.file_sha1);
        try std.testing.expectEqualStrings(source.timestamp, record.file_timestamp);
        try std.testing.expectEqual(source.width, record.original_width);
        try std.testing.expectEqual(source.height, record.original_height);
        try std.testing.expectEqual(@as(u32, 200), record.width_px);
        try std.testing.expectEqual(@as(?u32, null), record.height_px);
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, source.file, .thumbnail, 200, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, source.file, .thumbnail, 201, null));
    }
    try std.testing.expectError(invalid, Registry.init(a, projection, raw, raw, &ns, null, generator_sha256));
    var other = try TestSource.namespace(a); defer other.deinit();
    try std.testing.expectError(invalid, Registry.init(a, projection, raw, raw, &other, accepted_core, generator_sha256));
    for (0..4) |case| {
        var changed = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
        const pages = changed.object.getPtr("query").?.object.getPtr("pages").?;
        var selected: ?*Value = null;
        for (pages.array.items) |*page| {
            const image = &page.object.getPtr("imageinfo").?.array.items[0];
            if (equal(try string(image.*, "mime"), "image/tiff")) selected = image;
        }
        const image = selected orelse return error.TestUnexpectedResult;
        const metadata = image.object.getPtr("metadata").?;
        const page_data = try TiffTestSource.named(metadata, "page_data");
        const page = page_data.array.items[0].object.getPtr("value").?;
        switch (case) {
            0 => try image.object.put(a, "pagecount", .{ .number_string = "1.0" }),
            1 => (try TiffTestSource.named(page, "width")).* = .{ .number_string = "2420.0" },
            2 => try metadata.array.append(metadata.array.items[0]),
            3 => try page_data.array.items[0].object.put(a, "name", .{ .string = "01" }),
            else => unreachable,
        }
        const changed_raw = try std.json.Stringify.valueAlloc(a, changed, .{});
        if (case < 2) {
            const lexical = try std.json.parseFromSliceLeaky(Value, a, changed_raw, .{ .parse_numbers = false });
            const lexical_pages = (try field(try field(lexical, "query"), "pages")).array.items;
            var checked = false;
            for (lexical_pages) |item| {
                var candidate = (try field(item, "imageinfo")).array.items[0];
                if (!equal(try string(candidate, "mime"), "image/tiff")) continue;
                var token = try field(candidate, "pagecount");
                if (case == 1) {
                    const fields = candidate.object.getPtr("metadata").?;
                    const data = try TiffTestSource.named(fields, "page_data");
                    token = (try TiffTestSource.named(data.array.items[0].object.getPtr("value").?, "width")).*;
                }
                try std.testing.expect(token == .number_string);
                try std.testing.expectEqualStrings(if (case == 0) "1.0" else "2420.0", token.number_string);
                checked = true;
            }
            try std.testing.expect(checked);
        }
        var changed_projection = try std.json.parseFromSliceLeaky(Value, a, projection, .{ .allocate = .alloc_always });
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(changed_raw, &hash, .{});
        const digest = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
        try changed_projection.object.put(a, "raw_sha256", .{ .string = digest });
        try changed_projection.object.getPtr("source_profile").?.object.put(a, "site_raw_sha256", .{ .string = digest });
        const changed_bytes = try std.json.Stringify.valueAlloc(a, changed_projection, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed_bytes, changed_raw, changed_raw, &ns, accepted_core, generator_sha256));
    }
}

const ObservedSvgTestSource = struct {
    const Fixture = struct { projection: []const u8, raw: []const u8, site: []const u8 };
    fn make(a: A, ns: *const namespaces.Registry, mode: usize) !Fixture {
        const input = try FileTestSource.make(a, ns, false);
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, input.projection, .{ .allocate = .alloc_always });
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, a, input.raw, .{ .allocate = .alloc_always });
        var base = try std.json.parseFromSliceLeaky(Value, a, original.batches[0].response, .{ .allocate = .alloc_always });
        var site = try std.json.parseFromSliceLeaky(Value, a, TestSource.site, .{ .allocate = .alloc_always });
        try base.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = compatible_core });
        try site.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = compatible_core });
        var fact = doc.records[0];
        fact.original_width = 103; fact.original_height = 94;
        fact.observed_svg_width_px = 250; fact.observed_batch = 1;
        const base_image = &base.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
        try base_image.object.put(a, "width", .{ .integer = 103 });
        try base_image.object.put(a, "height", .{ .integer = 94 });
        if (mode == 1) {
            fact.mime = "image/jpeg"; fact.mediatype = "BITMAP";
            try base_image.object.put(a, "mime", .{ .string = fact.mime });
            try base_image.object.put(a, "mediatype", .{ .string = fact.mediatype });
        }
        const base_bytes = try std.json.Stringify.valueAlloc(a, base, .{});
        var observed = try std.json.parseFromSliceLeaky(Value, a, base_bytes, .{ .allocate = .alloc_always });
        const image_value = &observed.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
        try image_value.object.put(a, "thumbwidth", .{ .integer = if (mode == 8) 251 else 250 });
        try image_value.object.put(a, "thumbheight", .{ .integer = if (mode == 2) 229 else 228 });
        try image_value.object.put(a, "url", .{ .string = "https://upload.wikimedia.org/original.svg?utm_content=original" });
        try image_value.object.put(a, "thumburl", .{ .string = if (mode == 4)
            "https://upload.wikimedia.org/original.svg?utm_content=thumbnail" else "https://thumb.wikimedia.org/rendered.png?utm_content=thumbnail" });
        const attributes = try std.json.Stringify.valueAlloc(a, .{ .width = @as(u32, 250), .height = @as(u32, if (mode == 3) 229 else 228) }, .{});
        if (mode != 5) try image_value.object.put(a, "thumbattribs", try std.json.parseFromSliceLeaky(Value, a, attributes, .{}));
        if (mode == 6) try image_value.object.put(a, "sha1", .{ .string = "0000000000000000000000000000000000000000" });
        if (mode == 7) try observed.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = accepted_core });
        if (mode == 10) try image_value.object.put(a, "thumberror", .{ .string = "conversion failed" });
        if (mode == 11) try image_value.object.put(a, "thumburl", .{ .string = "https://user@thumb.wikimedia.org/rendered.png" });
        const observed_bytes = try std.json.Stringify.valueAlloc(a, observed, .{});
        const batches = [_]RawFileBatch{
            .{ .requests = &.{TestSource.file}, .response = base_bytes },
            .{ .requests = &.{TestSource.file}, .response = observed_bytes, .observed_svg_width_px = if (mode == 9) null else 250 },
        };
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = &batches }, .{});
        const site_bytes = try std.json.Stringify.valueAlloc(a, site, .{});
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        doc.raw_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
        doc.core_revision = compatible_core;
        doc.source_profile = try TestSource.profileValue(a, site_bytes);
        doc.records = &.{fact};
        return .{ .projection = try std.json.Stringify.valueAlloc(a, doc, .{}), .raw = raw, .site = site_bytes };
    }
};

test "observed SVG upscale is exact width corroboration with independent default source identity" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    var registry = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256);
    defer registry.deinit();
    arena.deinit(); live = false;
    // The measured250 fact also attests width-independent raster mode.
    for ([_]u32{ 1, 103, 104, 249, 250, 251, 500, std.math.maxInt(u32) }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]?u32{ null, 0 }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, 228));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .framed, 250, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, "Missing.svg", .thumbnail, 250, null));
    // Source-compatible cores do not relabel either the file or defaults observation.
    for ([_][]const u8{ accepted_core, compatible_core, current_core }) |file_core| {
        var family_arena = std.heap.ArenaAllocator.init(a); defer family_arena.deinit();
        const scratch = family_arena.allocator();
        const original = try ObservedSvgTestSource.make(scratch, &ns, 0);
        const family_raw = try std.mem.replaceOwned(u8, scratch, original.raw, compatible_core, file_core);
        const family_site = try std.mem.replaceOwned(u8, scratch, original.site, compatible_core, file_core);
        var family_doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, original.projection, .{});
        family_doc.core_revision = file_core;
        var family_hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(family_raw, &family_hash, .{});
        family_doc.raw_sha256 = try scratch.dupe(u8, &std.fmt.bytesToHex(family_hash, .lower));
        family_doc.source_profile = try TestSource.profileValue(scratch, family_site);
        const family_projection = try std.json.Stringify.valueAlloc(scratch, family_doc, .{});
        for ([_][]const u8{ accepted_core, compatible_core, current_core }) |default_core| {
            var family_registry = try Registry.init(a, family_projection, family_raw, family_site, &ns, default_core, generator_sha256);
            defer family_registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&family_registry, a, TestSource.file, .thumbnail, 250, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&family_registry, a, TestSource.file, .thumbnail, 251, null));
        }
        try std.testing.expectError(invalid, Registry.init(a, family_projection, family_raw, family_site, &ns, "ffffffffffffffffffffffffffffffffffffffff", generator_sha256));
        family_doc.core_revision = "ffffffffffffffffffffffffffffffffffffffff";
        try std.testing.expectError(invalid, Registry.init(a, try std.json.Stringify.valueAlloc(scratch, family_doc, .{}), family_raw, family_site, &ns, file_core, generator_sha256));
    }
    // An old generator's empty document grants no widths. Its original
    // matching source/site core contract remains valid outside the policy cores.
    for ([_][]const u8{ compatible_core, "0000000000000000000000000000000000000000" }) |empty_core| {
        var empty_arena = std.heap.ArenaAllocator.init(a); defer empty_arena.deinit();
        const scratch = empty_arena.allocator();
        const empty = try FileTestSource.make(scratch, &ns, true);
        var empty_doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, empty.projection, .{});
        empty_doc.core_revision = empty_core;
        empty_doc.generator_sha256 = "5275665a3638480185984f0702b4248bc42ba8cb5a24428ea01a8eb1e6f0c550";
        var empty_site = try std.json.parseFromSliceLeaky(Value, scratch, TestSource.site, .{ .allocate = .alloc_always });
        try empty_site.object.getPtr("query").?.object.getPtr("general").?.object.put(scratch, "git-hash", .{ .string = empty_core });
        var empty_registry = try Registry.init(a, try std.json.Stringify.valueAlloc(scratch, empty_doc, .{}),
            empty.raw, try std.json.Stringify.valueAlloc(scratch, empty_site, .{}), &ns, empty_core, generator_sha256);
        defer empty_registry.deinit();
        try std.testing.expectEqual(@as(usize, 0), empty_registry.records.len);
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&empty_registry, a, TestSource.file, .thumbnail, 250, null));
    }
}

test "observed SVG supplement rejects bitmap stale identity native URL incomplete axes and ordinary duplicates" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    for (1..12) |mode| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, mode);
        try std.testing.expectError(invalid, Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256));
    }
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    for ([_]?[]const u8{ null, "79b81ba96674efc8a803fc956bc501d347d440d2" }) |source_core|
        try std.testing.expectError(invalid, Registry.init(a, input.projection, input.raw, input.site, &ns, source_core, generator_sha256));
}

test "observed SVG corroboration preserves allocation failure ownership" {
    const Check = struct {
        fn replay(a: A, input: ObservedSvgTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try Registry.init(a, input.projection, input.raw, input.site, ns, accepted_core, generator_sha256);
            defer registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, null));
        }
    };
    var ns = try TestSource.namespace(std.testing.allocator); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.replay, .{ input, &ns });
}

const StreamTestSource = struct {
    const Fixture = ObservedSvgTestSource.Fixture;
    const Slice = struct {
        bytes: []const u8,
        chunk: usize = 65536,
        fn readAt(context: *anyopaque, out: []u8, offset: u64) !usize {
            const self: *Slice = @ptrCast(@alignCast(context));
            if (offset >= self.bytes.len) return 0;
            const start: usize = @intCast(offset);
            const n = @min(out.len, self.chunk, self.bytes.len - start);
            @memcpy(out[0..n], self.bytes[start..][0..n]);
            return n;
        }
        fn input(self: *Slice) StreamInput { return .{ .context = self, .read_at = readAt, .size = self.bytes.len }; }
    };
    fn append(a: A, out: *std.ArrayList(u8), value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        defer a.free(bytes);
        try out.appendSlice(a, bytes);
        try out.append(a, '\n');
    }
    fn parts(a: A, doc: FilesDocument, batches: []const RawFileBatch, site: []const u8) !Fixture {
        var observed: usize = 0;
        for (batches) |batch| if (batch.observed_svg_width_px != null or batch.observed_svg_occurrences != null) { observed += 1; };
        var raw: std.ArrayList(u8) = .empty;
        try append(a, &raw, RawStreamHeader{ .schema = raw_stream_schema, .wiki = doc.wiki,
            .core_revision = doc.core_revision, .namespace_registry_sha256 = doc.namespace_registry_sha256,
            .base_batches = batches.len - observed, .observed_batches = observed, .records_count = doc.records.len });
        for (batches) |batch| try append(a, &raw, batch);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw.items, &hash, .{});
        var projection: std.ArrayList(u8) = .empty;
        try append(a, &projection, StreamHeader{ .schema = stream_schema, .wiki = doc.wiki,
            .content_language = doc.content_language, .core_revision = doc.core_revision,
            .namespace_registry_sha256 = doc.namespace_registry_sha256,
            .raw_sha256 = &std.fmt.bytesToHex(hash, .lower), .generator_sha256 = file_generator_sha256,
            .source_profile = doc.source_profile, .records_count = doc.records.len,
            .base_batches = batches.len - observed, .observed_batches = observed, .raw_bytes = raw.items.len });
        for (doc.records) |fact| try append(a, &projection, fact);
        return .{ .projection = try projection.toOwnedSlice(a), .raw = try raw.toOwnedSlice(a), .site = site };
    }
    fn convert(a: A, input: Fixture) !Fixture {
        const doc = try std.json.parseFromSliceLeaky(FilesDocument, a, input.projection, .{});
        const batches = try std.json.parseFromSliceLeaky(RawFileBatches, a, input.raw, .{});
        return parts(a, doc, batches.batches, input.site);
    }
    fn init(a: A, fixture: Fixture, ns: *const namespaces.Registry, chunk: usize) !Registry {
        var p: Slice = .{ .bytes = fixture.projection, .chunk = chunk };
        var r: Slice = .{ .bytes = fixture.raw, .chunk = chunk };
        var projection = p.input(); var raw = r.input();
        var result = try Registry.initStream(a, &projection, &raw, fixture.site, ns, accepted_core);
        errdefer result.deinit();
        try std.testing.expect(projection.digest != null and raw.digest != null);
        return result;
    }
    fn initFreshScratch(a: A, fixture: Fixture, ns: *const namespaces.Registry, chunk: usize) !Registry {
        var p: Slice = .{ .bytes = fixture.projection, .chunk = chunk };
        var r: Slice = .{ .bytes = fixture.raw, .chunk = chunk };
        var projection = p.input(); var raw = r.input();
        var result = try Registry.initStreamWithScratchReset(.free_all, a, &projection, &raw, fixture.site, ns, accepted_core);
        errdefer result.deinit();
        try std.testing.expect(projection.digest != null and raw.digest != null);
        return result;
    }
};

test "streamed Figure facts preserve legacy policies and exact SVG supplements after source release" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    const streamed = try StreamTestSource.convert(arena.allocator(), input);
    var legacy = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256);
    defer legacy.deinit();
    var old_doc = try std.json.parseFromSliceLeaky(FilesDocument, arena.allocator(), input.projection, .{});
    old_doc.generator_sha256 = "ed4aade60ba51fe013fa99a53f4e190d0958a54bb4be5a8811082bda99be5783";
    const old_projection = try std.json.Stringify.valueAlloc(arena.allocator(), old_doc, .{});
    var old_legacy = try Registry.init(a, old_projection, input.raw, input.site, &ns, accepted_core, generator_sha256);
    defer old_legacy.deinit();
    try std.testing.expectEqualDeep(legacy.records, old_legacy.records);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&old_legacy, a, TestSource.file, .thumbnail, 250, null));
    for ([_][]const u8{ "5275665a3638480185984f0702b4248bc42ba8cb5a24428ea01a8eb1e6f0c550", "0000000000000000000000000000000000000000000000000000000000000000" }) |unproved| {
        old_doc.generator_sha256 = unproved;
        try std.testing.expectError(invalid, Registry.init(a, try std.json.Stringify.valueAlloc(arena.allocator(), old_doc, .{}), input.raw, input.site, &ns, accepted_core, generator_sha256));
    }
    const header_end = std.mem.indexOfScalar(u8, streamed.projection, '\n').?;
    var old_header = try std.json.parseFromSliceLeaky(StreamHeader, arena.allocator(), streamed.projection[0..header_end], .{});
    old_header.generator_sha256 = "ed4aade60ba51fe013fa99a53f4e190d0958a54bb4be5a8811082bda99be5783";
    const old_stream = try std.mem.concat(arena.allocator(), u8, &.{ try std.json.Stringify.valueAlloc(arena.allocator(), old_header, .{}), streamed.projection[header_end..] });
    try std.testing.expectError(invalid, StreamTestSource.init(a, .{ .projection = old_stream, .raw = streamed.raw, .site = streamed.site }, &ns, 7));
    // The prior qualified producer remains an exact supported source contract.
    old_doc.generator_sha256 = previous_stream_generator_sha256;
    var previous_legacy = try Registry.init(a, try std.json.Stringify.valueAlloc(arena.allocator(), old_doc, .{}), input.raw, input.site, &ns, accepted_core, generator_sha256);
    defer previous_legacy.deinit();
    old_header.generator_sha256 = previous_stream_generator_sha256;
    const previous_projection = try std.mem.concat(arena.allocator(), u8, &.{ try std.json.Stringify.valueAlloc(arena.allocator(), old_header, .{}), streamed.projection[header_end..] });
    var previous_stream = try StreamTestSource.init(a, .{ .projection = previous_projection, .raw = streamed.raw, .site = streamed.site }, &ns, 7);
    defer previous_stream.deinit();
    old_header.generator_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    const unknown_projection = try std.mem.concat(arena.allocator(), u8, &.{ try std.json.Stringify.valueAlloc(arena.allocator(), old_header, .{}), streamed.projection[header_end..] });
    try std.testing.expectError(invalid, StreamTestSource.init(a, .{ .projection = unknown_projection, .raw = streamed.raw, .site = streamed.site }, &ns, 7));
    var registry = try StreamTestSource.init(a, streamed, &ns, 7); defer registry.deinit();
    arena.deinit(); live = false;
    try std.testing.expectEqualDeep(legacy.records, previous_legacy.records);
    try std.testing.expectEqualDeep(legacy.records, previous_stream.records);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&previous_legacy, a, TestSource.file, .thumbnail, 250, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&previous_stream, a, TestSource.file, .thumbnail, 250, null));
    try std.testing.expectEqualDeep(legacy.records, registry.records);
    // Stream replay retains the same validated raster-mode proof as the JSON
    // file-facts path; serialization does not narrow its logical-width policy.
    for ([_]u32{ 1, 103, 104, 249, 250, 251, 500, std.math.maxInt(u32) }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]?u32{ null, 0 }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, 228));
}

test "streamed Figure authority rejects truncated trailing corrupt and inconsistent records before return" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const input = try ObservedSvgTestSource.make(temp, &ns, 0);
    const good = try StreamTestSource.convert(temp, input);
    for (0..9) |mode| {
        var fixture = good;
        switch (mode) {
            0 => fixture.projection = good.projection[0 .. good.projection.len - 1],
            1 => fixture.raw = good.raw[0 .. good.raw.len - 1],
            2 => fixture.projection = try std.mem.concat(temp, u8, &.{ good.projection, "{}\n" }),
            3 => fixture.raw = try std.mem.concat(temp, u8, &.{ good.raw, "{}\n" }),
            else => {
                const end = std.mem.indexOfScalar(u8, good.projection, '\n').?;
                var header = try std.json.parseFromSliceLeaky(StreamHeader, temp, good.projection[0..end], .{});
                switch (mode) {
                    4 => header.raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
                    5 => header.records_count += 1,
                    6 => header.raw_bytes += 1,
                    7 => { header.base_batches = 2; header.observed_batches = 0; },
                    8 => header.namespace_registry_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
                    else => unreachable,
                }
                const first = try std.json.Stringify.valueAlloc(temp, header, .{});
                fixture.projection = try std.mem.concat(temp, u8, &.{ first, good.projection[end..] });
            },
        }
        if (mode == 1 or mode == 3) {
            // Keep the external length/hash coherent so these cases reach the
            // final-line and extra-record checks, not just the digest guard.
            const end = std.mem.indexOfScalar(u8, fixture.projection, '\n').?;
            var header = try std.json.parseFromSliceLeaky(StreamHeader, temp, fixture.projection[0..end], .{});
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(fixture.raw, &digest, .{});
            header.raw_bytes = fixture.raw.len;
            header.raw_sha256 = try temp.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
            const first = try std.json.Stringify.valueAlloc(temp, header, .{});
            fixture.projection = try std.mem.concat(temp, u8, &.{ first, fixture.projection[end..] });
        }
        try std.testing.expectError(invalid, StreamTestSource.init(a, fixture, &ns, 13));
    }
    for (1..12) |mode| {
        const bad = try ObservedSvgTestSource.make(temp, &ns, mode);
        const streamed = try StreamTestSource.convert(temp, bad);
        try std.testing.expectError(invalid, StreamTestSource.init(a, streamed, &ns, 29));
    }
}

test "streamed Figure records preserve empty authority and bounded line EOF semantics" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const empty = try FileTestSource.make(arena.allocator(), &ns, true);
    const input = try StreamTestSource.convert(arena.allocator(), .{ .projection = empty.projection, .raw = empty.raw, .site = TestSource.site });
    var registry = try StreamTestSource.init(a, input, &ns, 1); defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.records.len);
    var slice: StreamTestSource.Slice = .{ .bytes = "12345\n", .chunk = 2 };
    var stream = slice.input();
    try std.testing.expectError(invalid, stream.line(a, 5));
    slice.bytes = "1234\r\n"; stream = slice.input();
    try std.testing.expectError(invalid, stream.line(a, 6));
    slice.bytes = "1234\n"; stream = slice.input();
    const line = (try stream.line(a, 5)).?; defer a.free(line);
    try std.testing.expectEqualStrings("1234", line);
    try stream.finish(a);
    try std.testing.expect(stream.digest != null);
}

test "streamed Figure batch scratch retains only compact facts beyond the old aggregate limit" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit(); const temp = arena.allocator();
    const initial = try FileTestSource.make(temp, &ns, false);
    var doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, initial.projection, .{});
    const original = try std.json.parseFromSliceLeaky(RawFileBatches, temp, initial.raw, .{});
    const padding = try temp.alloc(u8, 1024 * 1024); @memset(padding, ' ');
    const facts = try temp.alloc(FileFact, 65);
    const batches = try temp.alloc(RawFileBatch, facts.len);
    for (facts, batches, 0..) |*fact, *batch, i| {
        const title = try std.fmt.allocPrint(temp, "Sary:Stream-{d:0>3}.svg", .{i});
        fact.* = doc.records[0]; fact.requested_file = title; fact.canonical_file = title; fact.batch = @intCast(i);
        var response = try std.json.parseFromSliceLeaky(Value, temp, original.batches[0].response, .{ .allocate = .alloc_always });
        const page = &response.object.getPtr("query").?.object.getPtr("pages").?.array.items[0];
        try page.object.put(temp, "title", .{ .string = title });
        try page.object.getPtr("imageinfo").?.array.items[0].object.put(temp, "canonicaltitle", .{ .string = title });
        const encoded = try std.json.Stringify.valueAlloc(temp, response, .{});
        const requests = try temp.alloc([]const u8, 1); requests[0] = title;
        batch.* = .{ .requests = requests, .response = try std.mem.concat(temp, u8, &.{ encoded, padding }) };
    }
    doc.records = facts;
    const fixture = try StreamTestSource.parts(temp, doc, batches, TestSource.site);
    try std.testing.expect(fixture.raw.len > max_metadata);
    var counted = std.testing.FailingAllocator.init(a, .{});
    var registry = try StreamTestSource.init(counted.allocator(), fixture, &ns, 65536);
    defer registry.deinit();
    arena.deinit(); live = false;
    try std.testing.expectEqual(@as(usize, 65), registry.records.len);
    // This checks retained allocations, not a claim about measured peak RSS.
    try std.testing.expect(counted.allocated_bytes - counted.freed_bytes < 4 * 1024 * 1024);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, "Sary:Stream-064.svg", .thumbnail, 512, null));
}

test "streamed Figure ownership propagates every allocation failure" {
    const Check = struct {
        fn replay(a: A, input: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.initFreshScratch(a, input, ns, 37); defer registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, null));
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    const streamed = try StreamTestSource.convert(arena.allocator(), input);
    try Check.replay(a, streamed, &ns);
    // Optional capacity preheating is not a required allocation. Sweep the
    // same reader with fresh scratch and deterministic allocation fallback.
    var backing = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Check.replay, .{ streamed, &ns });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "streamed figure file aliases require consistent facts and each response timestamp" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    for (0..5) |case| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
        const scratch = arena.allocator();
        const input = try FileTestSource.make(scratch, &ns, false);
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, scratch, input.raw, .{ .allocate = .alloc_always });
        var batches: [2]RawFileBatch = undefined;
        var records: [2]FileFact = undefined;
        const aliases = [_][]const u8{ "Sary:A.svg", "Sary:B.svg" };
        for (aliases, 0..) |alias, index| {
            var response = try std.json.parseFromSliceLeaky(Value, scratch, original.batches[0].response, .{ .allocate = .alloc_always });
            const query = response.object.getPtr("query").?;
            const redirects = try std.json.Stringify.valueAlloc(scratch, .{.{ .from = alias, .to = TestSource.file }}, .{});
            try query.object.put(scratch, "redirects", try std.json.parseFromSliceLeaky(Value, scratch, redirects, .{ .allocate = .alloc_always }));
            const doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, input.projection, .{ .allocate = .alloc_always });
            records[index] = doc.records[0];
            records[index].requested_file = alias; records[index].batch = @intCast(index);
            if (index == 1 and case == 1) {
                try query.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0].object.put(scratch, "width", .{ .integer = 513 });
                records[index].original_width = 513;
            }
            if (index == 1 and (case == 2 or case == 4)) {
                // A canonical name cannot simultaneously be an explicit miss.
                records[index] = .{ .requested_file = if (case == 4) alias else TestSource.file, .canonical_file = TestSource.file,
                    .state = .missing, .batch = 1, .file_sha1 = "", .file_timestamp = "",
                    .original_width = 0, .original_height = 0, .mime = "", .mediatype = "" };
                const pages = try std.json.Stringify.valueAlloc(scratch, .{.{ .title = TestSource.file, .ns = 6, .imagerepository = "", .missing = true }}, .{});
                if (case == 2) _ = query.object.swapRemove("redirects");
                try query.object.put(scratch, "pages", try std.json.parseFromSliceLeaky(Value, scratch, pages, .{ .allocate = .alloc_always }));
            }
            if (index == 0 and case == 3) try response.object.put(scratch, "curtimestamp", .{ .string = "2020-01-01T00:00:00Z" });
            const request = try scratch.alloc([]const u8, 1);
            request[0] = records[index].requested_file;
            batches[index] = .{ .requests = request, .response = try std.json.Stringify.valueAlloc(scratch, response, .{}) };
        }
        const raw = try std.json.Stringify.valueAlloc(scratch, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = &batches }, .{});
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, scratch, input.projection, .{ .allocate = .alloc_always });
        const raw_digest = std.fmt.bytesToHex(hash, .lower);
        doc.records = &records; doc.raw_sha256 = &raw_digest;
        const projection = try std.json.Stringify.valueAlloc(scratch, doc, .{});
        if (case != 0) {
            try std.testing.expectError(invalid, StreamTestSource.init(a, try StreamTestSource.convert(scratch, .{ .projection = projection, .raw = raw, .site = TestSource.site }), &ns, 19));
        } else {
            var registry = try StreamTestSource.init(a, try StreamTestSource.convert(scratch, .{ .projection = projection, .raw = raw, .site = TestSource.site }), &ns, 19); defer registry.deinit();
            for ([_][]const u8{ aliases[0], aliases[1], TestSource.file }) |name|
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, 401, null));
        }
    }
}

test "height-only bitmap thumbnails retain original width bounds without source or rounding guesses" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const Case = struct { mime: []const u8, width: u32, height: u32, bound: u32 };
    // Existing requested_fit keeps these bounds: landscape356x200,
    // portrait112x200, square200x200, and no-upscale550x550. MediaHandler
    // fitBoxWidth and ImageHandler retain the authored height when it binds.
    for ([_]Case{
        .{ .mime = "image/png", .width = 180, .height = 180, .bound = 250 },
        .{ .mime = "image/png", .width = 1600, .height = 900, .bound = 200 },
        .{ .mime = "image/jpeg", .width = 900, .height = 1600, .bound = 200 },
        .{ .mime = "image/png", .width = 550, .height = 550, .bound = 200 },
        .{ .mime = "image/jpeg", .width = 550, .height = 550, .bound = 1000 },
        .{ .mime = "image/png", .width = 1, .height = 1000, .bound = 1 },
        .{ .mime = "image/png", .width = 4, .height = 3, .bound = 2 },
        .{ .mime = "image/jpeg", .width = 3, .height = 4, .bound = 2 },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
        const temp = arena.allocator();
        const initial = try FileTestSource.make(temp, &ns, false);
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, initial.projection, .{});
        const raw_doc = try std.json.parseFromSliceLeaky(RawFileBatches, temp, initial.raw, .{});
        var response = try std.json.parseFromSliceLeaky(Value, temp, raw_doc.batches[0].response, .{ .allocate = .alloc_always });
        const image = &response.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
        try image.object.put(temp, "width", .{ .integer = case.width });
        try image.object.put(temp, "height", .{ .integer = case.height });
        try image.object.put(temp, "mime", .{ .string = case.mime });
        try image.object.put(temp, "mediatype", .{ .string = "BITMAP" });
        var fact = doc.records[0]; fact.mime = case.mime; fact.mediatype = "BITMAP";
        fact.original_width = case.width; fact.original_height = case.height; doc.records = &.{fact};
        const response_bytes = try std.json.Stringify.valueAlloc(temp, response, .{});
        const batches = [_]RawFileBatch{.{ .requests = raw_doc.batches[0].requests, .response = response_bytes }};
        const raw_bytes = try std.json.Stringify.valueAlloc(temp, RawFileBatches{ .schema = raw_doc.schema, .batches = &batches }, .{});
        var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw_bytes, &digest, .{});
        doc.raw_sha256 = try temp.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        const projection = try std.json.Stringify.valueAlloc(temp, doc, .{});
        var registry = try Registry.init(a, projection, raw_bytes, TestSource.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
        const streamed = try StreamTestSource.convert(temp, .{ .projection = projection, .raw = raw_bytes, .site = TestSource.site });
        var stream_registry = try StreamTestSource.init(a, streamed, &ns, 7); defer stream_registry.deinit();
        arena.deinit(); live = false;
        try std.testing.expectEqual(@as(?u32, case.width), try Registry.resolveHeightOnlyWidth(&registry, a, TestSource.file, .thumbnail, case.bound));
        try std.testing.expectEqual(@as(?u32, case.width), try Registry.resolveHeightOnlyWidth(&stream_registry, a, TestSource.file, .thumbnail, case.bound));
        try std.testing.expectEqualDeep(registry.records, stream_registry.records);
        // Linker clamps thumbnail width before ImageHandler fits any height.
        // The retained 丄 case requests250 from an authenticated180px PNG.
        for ([_]*const Registry{ &registry, &stream_registry }) |source| {
            const allowed_limit = try Registry.resolveWidthLimit(source, a, TestSource.file, .thumbnail);
            if (equal(case.mime, "image/jpeg")) {
                // EXIF rotation can make mustRender true; no unproved logical clamp.
                try std.testing.expectEqual(@as(?u32, null), allowed_limit);
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(source, a, TestSource.file, .thumbnail, case.width + 1, null));
                continue;
            }
            const limit = allowed_limit orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(case.width, limit);
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, TestSource.file, .framed));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, "Missing.png", .thumbnail));
            for ([_]u32{ 1, 100, 250, 1000 }) |requested| {
                const bounded = @min(requested, limit);
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, bounded, null));
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, bounded, case.bound));
            }
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(source, a, TestSource.file, .thumbnail, case.width + 1, null));
        }
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, case.width, case.bound));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, case.width + 1, case.bound));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, case.width, 0));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&registry, a, TestSource.file, .thumbnail, 0));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&registry, a, TestSource.file, .framed, case.bound));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&registry, a, "Missing.png", .thumbnail, case.bound));
    }
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const svg = try FileTestSource.make(arena.allocator(), &ns, false);
    var svg_registry = try Registry.init(a, svg.projection, svg.raw, TestSource.site, &ns, accepted_core, generator_sha256); defer svg_registry.deinit();
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&svg_registry, a, TestSource.file, .thumbnail, 200));
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&svg_registry, a, TestSource.file, .thumbnail));
    const old_projection = try TestSource.projection(arena.allocator(), &ns, TestSource.raw, TestSource.site);
    var old_registry = try Registry.init(a, old_projection, TestSource.raw, TestSource.site, &ns, accepted_core, generator_sha256); defer old_registry.deinit();
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&old_registry, a, TestSource.file, .thumbnail, 200));
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&old_registry, a, TestSource.file, .thumbnail));
}

const ObservedSvgBatchTestSource = struct {
    const Mode = enum { valid, bitmap, stale_second, missing_axes, wrong_width, unknown_request, duplicate_request, duplicate_canonical, over_limit };
    fn make(a: A, ns: *const namespaces.Registry, count: usize, mode: Mode) !ObservedSvgTestSource.Fixture {
        std.debug.assert(count >= 2 and count <= 50);
        const input = try ObservedSvgTestSource.make(a, ns, 0);
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, input.projection, .{ .allocate = .alloc_always });
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, a, input.raw, .{ .allocate = .alloc_always });
        const facts = try a.alloc(FileFact, count);
        const requests = try a.alloc([]const u8, count);
        const canonical = try a.alloc([]const u8, count);
        for (0..count) |i| {
            requests[i] = try std.fmt.allocPrint(a, "Sary:Alias-{d:0>3}.svg", .{i});
            canonical[i] = try std.fmt.allocPrint(a, "Sary:Target-{d:0>3}.svg", .{i});
            facts[i] = doc.records[0];
            facts[i].requested_file = requests[i];
            facts[i].canonical_file = canonical[i];
            // Different original aspect ratios require separate returned heights
            // under the same 250px request, including after alias resolution.
            if (i != 0) { facts[i].original_width = 48; facts[i].original_height = 48; }
            if (i == 1 and mode == .bitmap) { facts[i].mime = "image/jpeg"; facts[i].mediatype = "BITMAP"; }
        }
        if (mode == .duplicate_canonical) {
            facts[1] = facts[0]; facts[1].requested_file = requests[1]; canonical[1] = canonical[0];
        }
        var batches: [2]RawFileBatch = undefined;
        for (0..2) |batch_index| {
            var response = try std.json.parseFromSliceLeaky(Value, a, original.batches[batch_index].response, .{ .allocate = .alloc_always });
            const query = response.object.getPtr("query").?;
            const template = try std.json.Stringify.valueAlloc(a, query.object.getPtr("pages").?.array.items[0], .{});
            var pages: Value = .{ .array = std.json.Array.init(a) };
            var redirects: Value = .{ .array = std.json.Array.init(a) };
            for (facts, 0..) |fact, i| {
                const mapping = try std.json.Stringify.valueAlloc(a, .{ .from = requests[i], .to = canonical[i] }, .{});
                try redirects.array.append(try std.json.parseFromSliceLeaky(Value, a, mapping, .{}));
                if (mode == .duplicate_canonical and i == 1) continue;
                var page = try std.json.parseFromSliceLeaky(Value, a, template, .{ .allocate = .alloc_always });
                try page.object.put(a, "title", .{ .string = canonical[i] });
                const info = &page.object.getPtr("imageinfo").?.array.items[0];
                try info.object.put(a, "canonicaltitle", .{ .string = canonical[i] });
                try info.object.put(a, "width", .{ .integer = fact.original_width });
                try info.object.put(a, "height", .{ .integer = fact.original_height });
                try info.object.put(a, "mime", .{ .string = fact.mime });
                try info.object.put(a, "mediatype", .{ .string = fact.mediatype });
                if (batch_index == 1) {
                    const height: u32 = if (i == 0) 228 else 250;
                    try info.object.put(a, "thumbheight", .{ .integer = height });
                    try info.object.getPtr("thumbattribs").?.object.put(a, "height", .{ .integer = height });
                    if (i == 1) switch (mode) {
                        .stale_second => try info.object.put(a, "sha1", .{ .string = "0000000000000000000000000000000000000000" }),
                        .missing_axes => { _ = info.object.swapRemove("thumbwidth"); },
                        .wrong_width => try info.object.put(a, "thumbwidth", .{ .integer = 251 }),
                        else => {},
                    };
                }
                try pages.array.append(page);
            }
            try query.object.put(a, "pages", pages);
            try query.object.put(a, "redirects", redirects);
            const batch_requests = try a.alloc([]const u8, if (batch_index == 1 and mode == .over_limit) 51 else count);
            for (batch_requests, 0..) |*request, i| request.* = requests[i % count];
            if (batch_index == 1) switch (mode) {
                .unknown_request => batch_requests[1] = "Sary:Unknown.svg",
                .duplicate_request => batch_requests[1] = batch_requests[0],
                else => {},
            };
            batches[batch_index] = .{ .requests = batch_requests, .response = try std.json.Stringify.valueAlloc(a, response, .{}),
                .observed_svg_width_px = if (batch_index == 1) 250 else null };
        }
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = &batches }, .{});
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        doc.raw_sha256 = &std.fmt.bytesToHex(hash, .lower);
        doc.records = facts;
        return .{ .projection = try std.json.Stringify.valueAlloc(a, doc, .{}), .raw = raw, .site = input.site };
    }
};

test "same width observed SVG batches retain per file alias identity and exact geometry authority" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    for ([_]usize{ 2, 50 }) |count| {
        var source = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) source.deinit();
        const input = try ObservedSvgBatchTestSource.make(source.allocator(), &ns, count, .valid);
        const streamed = try StreamTestSource.convert(source.allocator(), input);
        var legacy = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256); defer legacy.deinit();
        var registry = try StreamTestSource.init(a, streamed, &ns, 37); defer registry.deinit();
        source.deinit(); live = false;
        try std.testing.expectEqual(count * 2, registry.records.len);
        try std.testing.expectEqualDeep(legacy.records, registry.records);
        for (0..count) |i| {
            var name_buffer: [64]u8 = undefined;
            for ([_][]const u8{ "Alias", "Target" }) |prefix| {
                const name = try std.fmt.bufPrint(&name_buffer, "Sary:{s}-{d:0>3}.svg", .{ prefix, i });
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, 250, null));
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, 249, null));
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, 251, null));
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, 250, 250));
                try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&registry, a, name, .thumbnail, 250));
            }
        }
        for (registry.records) |record| {
            const first = std.mem.indexOf(u8, record.canonical_file, "000") != null;
            try std.testing.expectEqual(@as(u32, if (first) 103 else 48), record.original_width);
            try std.testing.expectEqual(@as(u32, if (first) 94 else 48), record.original_height);
            try std.testing.expectEqual(@as(u32, 250), record.width_px);
            try std.testing.expectEqual(@as(?u32, null), record.height_px);
            try std.testing.expectEqualStrings("file-svg-observed-thumbnail-width", record.proof_kind);
        }
    }
}

test "same width observed SVG batches reject mixed stale incomplete duplicate and excessive requests" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    for ([_]ObservedSvgBatchTestSource.Mode{ .bitmap, .stale_second, .missing_axes, .wrong_width, .unknown_request, .duplicate_request, .duplicate_canonical, .over_limit }) |mode| {
        var source = std.heap.ArenaAllocator.init(a); defer source.deinit();
        const input = try ObservedSvgBatchTestSource.make(source.allocator(), &ns, 2, mode);
        try std.testing.expectError(invalid, Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256));
        const streamed = try StreamTestSource.convert(source.allocator(), input);
        try std.testing.expectError(invalid, StreamTestSource.init(a, streamed, &ns, 37));
    }
}

test "same width observed SVG batches preserve allocation failure ownership" {
    const Check = struct {
        fn replay(a: A, input: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.initFreshScratch(a, input, ns, 37); defer registry.deinit();
            try std.testing.expectEqual(@as(usize, 4), registry.records.len);
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); defer source.deinit();
    const input = try ObservedSvgBatchTestSource.make(source.allocator(), &ns, 2, .valid);
    const streamed = try StreamTestSource.convert(source.allocator(), input);
    try Check.replay(a, streamed, &ns);
    // Optional capacity preheating is not a required allocation. Sweep the
    // same reader with fresh scratch and deterministic allocation fallback.
    var backing = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Check.replay, .{ streamed, &ns });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

const GifGeometryTestSource = struct {
    // Keep the synthetic source filename's SVG suffix: eligibility comes from
    // authenticated MIME/handler facts, never the spelling of the filename.
    const Options = struct {
        v4: bool = true, width: u32 = 100, height: u32 = 100,
        mime: []const u8 = "image/gif", mediatype: []const u8 = "BITMAP",
        metadata: []const u8 = "[]", state: FileState = .eligible, core: []const u8 = current_core,
    };
    fn make(a: A, ns: *const namespaces.Registry, options: Options) !ObservedSvgTestSource.Fixture {
        const initial = try FileTestSource.make(a, ns, false);
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, initial.projection, .{ .allocate = .alloc_always });
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, a, initial.raw, .{ .allocate = .alloc_always });
        var response = try std.json.parseFromSliceLeaky(Value, a, original.batches[0].response, .{ .allocate = .alloc_always });
        var site = try std.json.parseFromSliceLeaky(Value, a, TestSource.site, .{ .allocate = .alloc_always });
        try response.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = options.core });
        try site.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = options.core });
        const image = &response.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
        try image.object.put(a, "width", .{ .integer = options.width });
        try image.object.put(a, "height", .{ .integer = options.height });
        try image.object.put(a, "mime", .{ .string = options.mime });
        try image.object.put(a, "mediatype", .{ .string = options.mediatype });
        try image.object.put(a, "metadata", try std.json.parseFromSliceLeaky(Value, a, options.metadata, .{ .allocate = .alloc_always }));
        var fact = doc.records[0]; fact.mime = options.mime; fact.mediatype = options.mediatype;
        fact.original_width = options.width; fact.original_height = options.height; fact.state = options.state;
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = original.schema,
            .batches = &.{.{ .requests = original.batches[0].requests, .response = try std.json.Stringify.valueAlloc(a, response, .{}) }} }, .{});
        var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        doc.raw_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        doc.core_revision = options.core; doc.records = &.{fact};
        const site_bytes = try std.json.Stringify.valueAlloc(a, site, .{});
        doc.source_profile = try TestSource.profileValue(a, site_bytes);
        if (options.v4) {
            try doc.source_profile.object.put(a, "kind", .{ .string = "wikimedia-imagehandler-v4" });
            try doc.source_profile.object.put(a, "gif_handler_sha256", .{ .string = "f9ba4542bcbfbcdaee7db0c99a463b3f97e9e1e82b0e11adcae927c6638dbf52" });
            try doc.source_profile.object.put(a, "main_config_schema_sha256", .{ .string = "cf37b0e27b01de513fa9ac81bb4424f48c9892107543a0697622c677c7a1de52" });
            const family = try std.json.Stringify.valueAlloc(a, .{ .handler_class = gif_handler.handler_class, .mediatype = gif_handler.mediatype }, .{});
            try doc.source_profile.object.getPtr("handler_families").?.object.put(a, "image/gif", try std.json.parseFromSliceLeaky(Value, a, family, .{}));
        }
        return .{ .projection = try std.json.Stringify.valueAlloc(a, doc, .{}), .raw = raw, .site = site_bytes };
    }
};

test "GIF source profile grants only original logical geometry independently of animation selection" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const Case = struct { width: u32, height: u32, metadata: []const u8 };
    for ([_]Case{
        .{ .width = 584, .height = 500, .metadata = "[{\"name\":\"frameCount\",\"value\":1}]" },
        .{ .width = 300, .height = 300, .metadata = "[{\"name\":\"frameCount\",\"value\":49},{\"name\":\"looped\",\"value\":true}]" },
        .{ .width = 100, .height = 100, .metadata = "[]" },
        .{ .width = 4, .height = 3, .metadata = "[{\"name\":\"frameCount\",\"value\":100000001}]" },
        .{ .width = 3, .height = 4, .metadata = "[{\"name\":\"_error\",\"value\":\"unavailable animation metadata\"}]" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
        const input = try GifGeometryTestSource.make(arena.allocator(), &ns, .{ .width = case.width, .height = case.height, .metadata = case.metadata });
        var registry = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
        var streamed = try StreamTestSource.init(a, try StreamTestSource.convert(arena.allocator(), input), &ns, 11); defer streamed.deinit();
        arena.deinit(); live = false;
        try std.testing.expectEqualDeep(registry.records, streamed.records);
        for ([_]*Registry{ &registry, &streamed }) |source| {
            try std.testing.expectEqual(@as(?u32, case.width), try Registry.resolveWidthLimit(source, a, TestSource.file, .thumbnail));
            try std.testing.expectEqual(@as(?u32, case.width), try Registry.resolveHeightOnlyWidth(source, a, TestSource.file, .thumbnail, 180));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, @min(250, case.width), null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, case.width, 180));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(source, a, TestSource.file, .thumbnail, case.width + 1, null));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, TestSource.file, .framed));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, "Missing.gif", .thumbnail));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(source, a, TestSource.file, .thumbnail, 0));
        }
    }
}

test "GIF geometry preserves old unsupported facts and rejects MIME profile identity and axes substitutions" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const old = try GifGeometryTestSource.make(temp, &ns, .{ .v4 = false, .state = .unsupported });
    var old_registry = try Registry.init(a, old.projection, old.raw, old.site, &ns, accepted_core, generator_sha256); defer old_registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), old_registry.records.len);
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&old_registry, a, TestSource.file, .thumbnail));
    for ([_]GifGeometryTestSource.Options{
        .{ .v4 = false }, .{ .width = 0 }, .{ .height = 0 }, .{ .mime = "image/unknown" }, .{ .mediatype = "DRAWING" }, .{ .core = accepted_core }, .{ .core = compatible_core },
    }) |options| {
        const input = try GifGeometryTestSource.make(temp, &ns, options);
        try std.testing.expectError(invalid, Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256));
    }
    const good = try GifGeometryTestSource.make(temp, &ns, .{});
    for (0..7) |case| {
        var doc = try std.json.parseFromSliceLeaky(Value, temp, good.projection, .{ .allocate = .alloc_always });
        const p = doc.object.getPtr("source_profile").?;
        const fact = &doc.object.getPtr("records").?.array.items[0];
        switch (case) {
            0 => try p.object.put(temp, "gif_handler_sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" }),
            1 => try p.object.getPtr("handler_families").?.object.getPtr("image/gif").?.object.put(temp, "handler_class", .{ .string = "MediaWiki\\Media\\BitmapHandler" }),
            2 => try doc.object.put(temp, "core_revision", .{ .string = accepted_core }),
            3 => try fact.object.put(temp, "original_width", .{ .integer = 101 }),
            4 => try fact.object.put(temp, "file_sha1", .{ .string = "0000000000000000000000000000000000000000" }),
            5 => try fact.object.put(temp, "file_timestamp", .{ .string = "2026-01-01T00:00:00Z" }),
            6 => try doc.object.put(temp, "generator_sha256", .{ .string = previous_stream_generator_sha256 }),
            else => unreachable,
        }
        try std.testing.expectError(invalid, Registry.init(a, try std.json.Stringify.valueAlloc(temp, doc, .{}), good.raw, good.site, &ns, accepted_core, generator_sha256));
    }
    const svg = try GifGeometryTestSource.make(temp, &ns, .{ .mime = "image/svg+xml", .mediatype = "DRAWING" });
    var svg_registry = try Registry.init(a, svg.projection, svg.raw, svg.site, &ns, accepted_core, generator_sha256); defer svg_registry.deinit();
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&svg_registry, a, TestSource.file, .thumbnail));
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&svg_registry, a, TestSource.file, .thumbnail, 180));
}

test "GIF geometry callbacks and streamed owned records propagate allocation failure" {
    const Check = struct {
        fn run(a: A, input: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.init(a, input, ns, 17); defer registry.deinit();
            try std.testing.expectEqual(@as(?u32, 100), try Registry.resolveWidthLimit(&registry, a, TestSource.file, .thumbnail));
            try std.testing.expectEqual(@as(?u32, 100), try Registry.resolveHeightOnlyWidth(&registry, a, TestSource.file, .thumbnail, 180));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 100, 180));
        }
    };
    var ns = try TestSource.namespace(std.testing.allocator); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const input = try StreamTestSource.convert(arena.allocator(), try GifGeometryTestSource.make(arena.allocator(), &ns, .{}));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{ input, &ns });
}

const SvgHeightTestSource = struct {
    const title = "Observed page";
    const options = "x250px|thumb|right|caption";
    fn make(a: A, ns: *const namespaces.Registry) !ObservedSvgTestSource.Fixture {
        return makeTitle(a, ns, title);
    }
    fn makeTitle(a: A, ns: *const namespaces.Registry, page_title: []const u8) !ObservedSvgTestSource.Fixture {
        const initial = try GifGeometryTestSource.make(a, ns, .{ .mime = "image/svg+xml", .mediatype = "DRAWING", .width = 323, .height = 415 });
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, initial.projection, .{ .allocate = .alloc_always });
        const raw_doc = try std.json.parseFromSliceLeaky(RawFileBatches, a, initial.raw, .{ .allocate = .alloc_always });
        const file_href = try std.fmt.allocPrint(a, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = TestSource.file }, .formatEscaped)});
        const html = try std.fmt.allocPrint(a,
            "<div><figure typeof=\"mw:File/Thumb\" class=\"mw-halign-right\"><a class=\"mw-file-description\" href=\"/wiki/{s}\"><img src=\"//thumb.example/250px-source.png\" class=\"mw-file-element\" width=\"194\" height=\"250\" data-file-width=\"323\" data-file-height=\"415\"/></a><figcaption>caption</figcaption></figure></div>", .{file_href});
        const response = try std.json.Stringify.valueAlloc(a, .{ .parse = .{ .title = page_title, .pageid = @as(u32, 1), .text = html } }, .{});
        var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(response, &digest, .{});
        const receipt = try std.json.Stringify.valueAlloc(a, .{ .accepted = true, .status = @as(u32, 200), .request_count = @as(u32, 1),
            .response = "response01.raw.json", .response_bytes = response.len, .response_sha256 = &std.fmt.bytesToHex(digest, .lower) }, .{});
        const token = try std.fmt.allocPrint(a, "[[{s}|{s}]]", .{TestSource.file, options});
        const escaped_title = try std.fmt.allocPrint(a, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = page_title }, .formatEscaped)});
        const escaped_text = try std.fmt.allocPrint(a, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = token }, .formatEscaped)});
        const url = try std.fmt.allocPrint(a, "https:{s}/w/api.php?action=parse&contentmodel=wikitext&format=json&formatversion=2&maxlag=5&prop=text&title={s}&text={s}", .{try officialServer(a, ns.wiki), escaped_title, escaped_text});
        const request = try std.json.Stringify.valueAlloc(a, .{ .controlled_single_token = true, .full_historical_page_render = false, .request_count = @as(u32, 1), .url = url,
            .query = .{ .action = "parse", .contentmodel = "wikitext", .format = "json", .formatversion = "2", .maxlag = "5", .prop = "text", .title = page_title, .text = token } }, .{});
        const observations = try a.alloc(RawSvgHeightObservation, 1);
        observations[0] = .{ .request = request, .receipt = receipt, .response = response };
        const batches = try a.alloc(RawFileBatch, 2); batches[0] = raw_doc.batches[0];
        batches[1] = .{ .requests = batches[0].requests, .response = batches[0].response, .observed_svg_occurrences = observations };
        var fact = doc.records[0];
        const declared = try a.alloc(SvgHeightObservation, 1);
        declared[0] = .{ .wiki = ns.wiki, .title = page_title, .options = options, .height_px = 250, .observed_width_px = 194, .observed_height_px = 250, .batch = 1, .parse_core_binding_proven = false };
        fact.observed_svg_heights = declared; doc.records = try a.dupe(FileFact, &.{fact});
        return repack(a, doc, batches, initial.site);
    }
    fn repack(a: A, original: FilesDocument, batches: []const RawFileBatch, site: []const u8) !ObservedSvgTestSource.Fixture {
        var doc = original;
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = batches }, .{});
        var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        doc.raw_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        return .{ .projection = try std.json.Stringify.valueAlloc(a, doc, .{}), .raw = raw, .site = site };
    }
};

test "observed SVG height is an exact page context grant independent of raster URL bucket" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
    const input = try SvgHeightTestSource.make(arena.allocator(), &ns);
    var legacy = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256); defer legacy.deinit();
    var streamed = try StreamTestSource.init(a, try StreamTestSource.convert(arena.allocator(), input), &ns, 13); defer streamed.deinit();
    const temp = arena.allocator();
    const second = try SvgHeightTestSource.makeTitle(temp, &ns, "Second page");
    var pair_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, input.projection, .{ .allocate = .alloc_always });
    const second_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, second.projection, .{ .allocate = .alloc_always });
    const first_raw = try std.json.parseFromSliceLeaky(RawFileBatches, temp, input.raw, .{ .allocate = .alloc_always });
    const second_raw = try std.json.parseFromSliceLeaky(RawFileBatches, temp, second.raw, .{ .allocate = .alloc_always });
    var second_height = second_doc.records[0].observed_svg_heights.?[0]; second_height.batch = 2;
    var pair_fact = pair_doc.records[0];
    pair_fact.observed_svg_heights = &.{ pair_fact.observed_svg_heights.?[0], second_height };
    pair_doc.records = &.{pair_fact};
    const pair_input = try SvgHeightTestSource.repack(temp, pair_doc, &.{ first_raw.batches[0], first_raw.batches[1], second_raw.batches[1] }, input.site);
    var pair = try StreamTestSource.init(a, try StreamTestSource.convert(temp, pair_input), &ns, 19); defer pair.deinit();
    arena.deinit(); live = false;
    for ([_][]const u8{ SvgHeightTestSource.title, "Second page" }) |page_title|
        try std.testing.expectEqual(@as(?u32, 323), try Registry.resolveHeightOccurrence(&pair, a, ns.wiki, page_title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
    try std.testing.expectEqualDeep(legacy.records, streamed.records);
    for ([_]*Registry{ &legacy, &streamed }) |registry| {
        try std.testing.expectEqual(@as(?u32, 323), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(registry, a, TestSource.file, .thumbnail, 323, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(registry, a, TestSource.file, .thumbnail, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, "otherwiktionary", SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, "Other page", TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, SvgHeightTestSource.title, "Other.svg", .thumbnail, SvgHeightTestSource.options, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .framed, SvgHeightTestSource.options, 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, "x250px|thumb|right|other caption", 250));
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOccurrence(registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 249));
    }
    try std.testing.expectEqual(@as(?u32, 224), svgHeightFit(495, 552, 250));
    try std.testing.expectEqual(@as(?u32, 194), svgHeightFit(323, 415, 250));
    try std.testing.expectEqual(@as(?u32, 156), svgHeightFit(285, 366, 200));
    try std.testing.expectEqual(@as(?u32, 168), svgHeightFit(420, 500, 200));
    try std.testing.expectEqual(@as(?u32, null), svgHeightFit(100, 100, 250));
}

test "observed SVG height rejects unproved identity context receipts and HTML geometry" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const input = try SvgHeightTestSource.make(temp, &ns);
    const gif = try GifGeometryTestSource.make(temp, &ns, .{});
    var gif_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, gif.projection, .{ .allocate = .alloc_always });
    gif_doc.generator_sha256 = "7bce7ec0bd0acdf6a9d726ed50c1e85a64bc089731d0347d048f1787003d4c0b";
    var retained_gif = try Registry.init(a, try std.json.Stringify.valueAlloc(temp, gif_doc, .{}), gif.raw, gif.site, &ns, accepted_core, generator_sha256); defer retained_gif.deinit();
    try std.testing.expectEqual(@as(?u32, 100), try Registry.resolveWidthLimit(&retained_gif, a, TestSource.file, .thumbnail));
    for (0..17) |case| {
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, input.projection, .{ .allocate = .alloc_always });
        var fact = doc.records[0];
        var height = fact.observed_svg_heights.?[0];
        switch (case) {
            0 => height.wiki = "otherwiktionary", 1 => height.title = "Other page",
            2 => height.options = "x250px|thumb|caption", 3 => height.height_px = 249,
            4 => height.observed_width_px = 195, 5 => height.observed_height_px = 249,
            6 => height.batch = 0, 7 => height.parse_core_binding_proven = true,
            8 => fact.file_sha1 = "0000000000000000000000000000000000000000",
            9 => fact.file_timestamp = "2026-01-01T00:00:00Z",
            10 => fact.original_width = 324, 11 => fact.original_height = 416,
            12 => fact.mime = "image/png", 13 => fact.requested_file = "Sary:Other.svg",
            14 => doc.generator_sha256 = "7bce7ec0bd0acdf6a9d726ed50c1e85a64bc089731d0347d048f1787003d4c0b",
            15 => doc.source_profile = try TestSource.profileValue(temp, input.site),
            16 => height.batch = 2,
            else => unreachable,
        }
        fact.observed_svg_heights = &.{height}; doc.records = &.{fact};
        try std.testing.expectError(invalid, Registry.init(a, try std.json.Stringify.valueAlloc(temp, doc, .{}), input.raw, input.site, &ns, accepted_core, generator_sha256));
    }
    for (0..17) |case| {
        const doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, input.projection, .{ .allocate = .alloc_always });
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, temp, input.raw, .{ .allocate = .alloc_always });
        const batches = try temp.dupe(RawFileBatch, original.batches);
        var raw = batches[1].observed_svg_occurrences.?[0];
        var request = try std.json.parseFromSliceLeaky(Value, temp, raw.request, .{ .allocate = .alloc_always });
        var receipt = try std.json.parseFromSliceLeaky(Value, temp, raw.receipt, .{ .allocate = .alloc_always });
        var response = try std.json.parseFromSliceLeaky(Value, temp, raw.response, .{ .allocate = .alloc_always });
        const parsed = response.object.getPtr("parse").?;
        const html = parsed.object.getPtr("text").?;
        switch (case) {
            0 => try receipt.object.put(temp, "status", .{ .integer = 500 }),
            1 => try receipt.object.put(temp, "response_bytes", .{ .integer = 1 }),
            2 => try request.object.getPtr("query").?.object.put(temp, "title", .{ .string = "Other page" }),
            3 => try request.object.put(temp, "url", .{ .string = "https://example.test/w/api.php?action=parse" }),
            4 => try parsed.object.put(temp, "title", .{ .string = "Other page" }),
            5 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "width=\"194\"", "width=\"195\"") },
            6 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "height=\"250\"", "height=\"249\"") },
            7 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "data-file-width=\"323\"", "data-file-width=\"324\"") },
            8 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "<img ", "<img style=\"width:100px\" ") },
            9 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "</a>", "<img src=\"other\"/></a>") },
            10 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "/wiki/", "/wrong/") },
            11 => batches[1].observed_svg_width_px = 250,
            12 => batches[1].observed_svg_occurrences = &.{ raw, raw },
            13 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "width=\"194\"", "width=\"&#49;94\"") },
            14 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "class=\"mw-file-element\"", "class=\"mw-file-eleme&#110;t\"") },
            15 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "</a>", "</a bogus>") },
            16 => html.* = .{ .string = try std.mem.replaceOwned(u8, temp, html.string, "<div>", "<div></div>") },
            else => unreachable,
        }
        if ((case >= 4 and case <= 10) or case >= 13) {
            raw.response = try std.json.Stringify.valueAlloc(temp, response, .{});
            var digest: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw.response, &digest, .{});
            try receipt.object.put(temp, "response_bytes", .{ .integer = @intCast(raw.response.len) });
            try receipt.object.put(temp, "response_sha256", .{ .string = try temp.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) });
        }
        raw.request = try std.json.Stringify.valueAlloc(temp, request, .{});
        raw.receipt = try std.json.Stringify.valueAlloc(temp, receipt, .{});
        if (case != 12) batches[1].observed_svg_occurrences = &.{raw};
        const changed = try SvgHeightTestSource.repack(temp, doc, batches, input.site);
        try std.testing.expectError(invalid, Registry.init(a, changed.projection, changed.raw, changed.site, &ns, accepted_core, generator_sha256));
    }
}

test "observed SVG height streamed ownership and contextual lookup propagate allocation failure" {
    const Check = struct {
        fn run(a: A, input: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.init(a, input, ns, 17); defer registry.deinit();
            try std.testing.expectEqual(@as(?u32, 323), try Registry.resolveHeightOccurrence(&registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
        }
    };
    var ns = try TestSource.namespace(std.testing.allocator); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const input = try StreamTestSource.convert(arena.allocator(), try SvgHeightTestSource.make(arena.allocator(), &ns));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{ input, &ns });
}


const TiffCompanionTestSource = struct {
    const file = "Sary:Companion.tif";
    fn producerStream(a: A, input: ObservedSvgTestSource.Fixture, producer: []const u8) !ObservedSvgTestSource.Fixture {
        const streamed = try StreamTestSource.convert(a, input);
        const header_end = std.mem.indexOfScalar(u8, streamed.projection, '\n').?;
        var header = try std.json.parseFromSliceLeaky(StreamHeader, a, streamed.projection[0..header_end], .{});
        header.generator_sha256 = producer;
        return .{ .projection = try std.mem.concat(a, u8, &.{ try std.json.Stringify.valueAlloc(a, header, .{}), streamed.projection[header_end..] }),
            .raw = streamed.raw, .site = streamed.site };
    }
    fn make(a: A, ns: *const namespaces.Registry, companion: bool) !FileTestSource.Fixture {
        const baseline = try FileTestSource.make(a, ns, false);
        const batches = try std.json.parseFromSliceLeaky(RawFileBatches, a, baseline.raw, .{ .allocate = .alloc_always });
        var full = try std.json.parseFromSliceLeaky(Value, a, batches.batches[0].response, .{ .allocate = .alloc_always });
        const query = full.object.getPtr("query").?;
        _ = query.object.swapRemove("normalized");
        _ = query.object.swapRemove("redirects");
        const page = &query.object.getPtr("pages").?.array.items[0];
        try page.object.put(a, "title", .{ .string = file });
        var full_info = try TiffTestSource.image(a);
        try full_info.object.put(a, "canonicaltitle", .{ .string = file });
        page.object.getPtr("imageinfo").?.array.items[0] = full_info;
        const full_bytes = try std.json.Stringify.valueAlloc(a, full, .{});
        var lean = try std.json.parseFromSliceLeaky(Value, a, full_bytes, .{ .allocate = .alloc_always });
        _ = lean.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0].object.swapRemove("metadata");
        const lean_bytes = try std.json.Stringify.valueAlloc(a, lean, .{});
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{
            .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = &.{.{ .requests = &.{file},
                .response = if (companion) lean_bytes else full_bytes,
                .tiff_metadata_response = if (companion) full_bytes else null }},
        }, .{});
        var doc = try std.json.parseFromSliceLeaky(Value, a, baseline.projection, .{ .allocate = .alloc_always });
        const fact = &doc.object.getPtr("records").?.array.items[0];
        for ([_][2][]const u8{ .{ "requested_file", "canonicaltitle" }, .{ "canonical_file", "canonicaltitle" },
            .{ "file_sha1", "sha1" }, .{ "file_timestamp", "timestamp" }, .{ "mime", "mime" }, .{ "mediatype", "mediatype" },
            .{ "original_width", "width" }, .{ "original_height", "height" } }) |pair|
            try fact.object.put(a, pair[0], try field(full_info, pair[1]));
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        try doc.object.put(a, "raw_sha256", .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
        return .{ .raw = raw, .projection = try std.json.Stringify.valueAlloc(a, doc, .{}) };
    }
    fn registry(a: A, input: FileTestSource.Fixture, ns: *const namespaces.Registry) !Registry {
        return Registry.init(a, input.projection, input.raw, TestSource.site, ns, accepted_core, generator_sha256);
    }
};

test "TIFF companion retains full query authority across owned legacy and streamed replay" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var inputs = std.heap.ArenaAllocator.init(a);
    var inputs_live = true; defer if (inputs_live) inputs.deinit();
    const full = try TiffCompanionTestSource.make(inputs.allocator(), &ns, false);
    const lean = try TiffCompanionTestSource.make(inputs.allocator(), &ns, true);
    const batches = try std.json.parseFromSliceLeaky(RawFileBatches, inputs.allocator(), lean.raw, .{});
    const companion = try std.json.parseFromSliceLeaky(Value, inputs.allocator(), batches.batches[0].tiff_metadata_response.?, .{});
    const shared_page = companion.object.get("query").?.object.get("pages").?.array.items[0];
    // Missing local description is not a missing shared file.
    try std.testing.expectEqualStrings("shared", try string(shared_page, "imagerepository"));
    const local_missing = try field(shared_page, "missing");
    try std.testing.expect(local_missing == .bool and local_missing.bool);
    var expected = try TiffCompanionTestSource.registry(a, full, &ns); defer expected.deinit();
    var actual = try TiffCompanionTestSource.registry(a, lean, &ns); defer actual.deinit();
    const temp = inputs.allocator();
    const height = try SvgHeightTestSource.make(temp, &ns);
    for ([_][]const u8{ occurrence_generator_sha256, lean_svg_generator_sha256 }) |prior_generator| {
        var prior_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, full.projection, .{});
        prior_doc.generator_sha256 = prior_generator;
        const prior_full = FileTestSource.Fixture{ .projection = try std.json.Stringify.valueAlloc(temp, prior_doc, .{}), .raw = full.raw };
        var prior = try TiffCompanionTestSource.registry(a, prior_full, &ns); defer prior.deinit();
        try std.testing.expectEqualDeep(expected.records, prior.records);
        var prior_stream = try StreamTestSource.init(a, try TiffCompanionTestSource.producerStream(temp, .{ .projection = prior_full.projection, .raw = full.raw, .site = TestSource.site }, prior_generator), &ns, 17); defer prior_stream.deinit();
        try std.testing.expectEqualDeep(expected.records, prior_stream.records);
        var companion_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, lean.projection, .{});
        companion_doc.generator_sha256 = prior_generator;
        const prior_companion = FileTestSource.Fixture{ .projection = try std.json.Stringify.valueAlloc(temp, companion_doc, .{}), .raw = lean.raw };
        try std.testing.expectError(invalid, TiffCompanionTestSource.registry(a, prior_companion, &ns));
        try std.testing.expectError(invalid, StreamTestSource.init(a, try TiffCompanionTestSource.producerStream(temp, .{ .projection = prior_companion.projection, .raw = lean.raw, .site = TestSource.site }, prior_generator), &ns, 17));
        var height_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, height.projection, .{});
        height_doc.generator_sha256 = prior_generator;
        const prior_height = ObservedSvgTestSource.Fixture{ .projection = try std.json.Stringify.valueAlloc(temp, height_doc, .{}), .raw = height.raw, .site = height.site };
        var height_stream = try StreamTestSource.init(a, try TiffCompanionTestSource.producerStream(temp, prior_height, prior_generator), &ns, 17); defer height_stream.deinit();
        try std.testing.expectEqual(@as(?u32, 323), try Registry.resolveHeightOccurrence(&height_stream, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
    }
    const streamed = try StreamTestSource.convert(inputs.allocator(), .{ .projection = lean.projection, .raw = lean.raw, .site = TestSource.site });
    var projection = StreamTestSource.Slice{ .bytes = streamed.projection, .chunk = 71 };
    var raw = StreamTestSource.Slice{ .bytes = streamed.raw, .chunk = 53 };
    var projection_input = projection.input(); var raw_input = raw.input();
    var stream = try Registry.initStream(a, &projection_input, &raw_input, TestSource.site, &ns, accepted_core); defer stream.deinit();
    inputs.deinit(); inputs_live = false;
    try std.testing.expectEqualDeep(expected.records, actual.records);
    try std.testing.expectEqualDeep(expected.records, stream.records);
    for ([_]*Registry{ &actual, &stream }) |result| {
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(result, a, TiffCompanionTestSource.file, .thumbnail, 250, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(result, a, TiffCompanionTestSource.file, .thumbnail, 2421, null));
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(result, a, TiffCompanionTestSource.file, .thumbnail, 250, 300));
    }
}

test "TIFF companion field presence rejects old producers null empty and nonstring values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const absent = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try validateTiffCompanionField(absent, false);
    for ([_][]const u8{ "null", "\"\"", "123", "false", "{}" }) |token| {
        const bytes = try std.fmt.allocPrint(a, "{{\"tiff_metadata_response\":{s}}}", .{token});
        const value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
        try std.testing.expectError(invalid, validateTiffCompanionField(value, true));
        try std.testing.expectError(invalid, validateTiffCompanionField(value, false));
    }
    const present = try std.json.parseFromSliceLeaky(Value, a, "{\"tiff_metadata_response\":\"{}\"}", .{});
    try validateTiffCompanionField(present, true);
    try std.testing.expectError(invalid, validateTiffCompanionField(present, false));
}

test "TIFF companion rehashed identity page count and authority contradictions remain refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const input = try TiffCompanionTestSource.make(a, &ns, true);
    for (0..18) |mode| {
        var batches = try std.json.parseFromSliceLeaky(Value, a, input.raw, .{ .allocate = .alloc_always });
        const batch = &batches.object.getPtr("batches").?.array.items[0];
        var full = try std.json.parseFromSliceLeaky(Value, a, try string(batch.*, "tiff_metadata_response"), .{ .allocate = .alloc_always });
        const query = full.object.getPtr("query").?;
        const page = &query.object.getPtr("pages").?.array.items[0];
        const info = &page.object.getPtr("imageinfo").?.array.items[0];
        switch (mode) {
            0 => try info.object.put(a, "sha1", .{ .string = "0000000000000000000000000000000000000000" }),
            1 => try info.object.put(a, "width", .{ .integer = 2419 }),
            2 => try info.object.put(a, "height", .{ .integer = 2999 }),
            3 => try info.object.put(a, "size", .{ .integer = 1 }),
            4 => try info.object.put(a, "pagecount", .{ .integer = 2 }),
            5 => { _ = info.object.swapRemove("pagecount"); },
            6 => { _ = info.object.swapRemove("metadata"); },
            7 => try info.object.put(a, "canonicaltitle", .{ .string = "Sary:Other.tif" }),
            8 => try info.object.put(a, "mime", .{ .string = "image/png" }),
            9 => try info.object.put(a, "mediatype", .{ .string = "DRAWING" }),
            10 => try page.object.put(a, "title", .{ .string = "Sary:Unrequested.tif" }),
            11 => try query.object.getPtr("pages").?.array.append(page.*),
            12 => try batch.object.put(a, "observed_svg_width_px", .{ .integer = 250 }),
            13 => {}, // The authenticated projection producer is changed below.
            14 => {
                var lean = try std.json.parseFromSliceLeaky(Value, a, try string(batch.*, "response"), .{ .allocate = .alloc_always });
                const lean_info = &lean.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
                try lean_info.object.put(a, "metadata", try field(info.*, "metadata"));
                try batch.object.put(a, "response", .{ .string = try std.json.Stringify.valueAlloc(a, lean, .{}) });
            },
            15 => try query.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = "0000000000000000000000000000000000000000" }),
            16 => try page.object.put(a, "imagerepository", .{ .string = "" }),
            17 => { _ = page.object.swapRemove("imageinfo"); },
            else => unreachable,
        }
        try batch.object.put(a, "tiff_metadata_response", .{ .string = try std.json.Stringify.valueAlloc(a, full, .{}) });
        const raw = try std.json.Stringify.valueAlloc(a, batches, .{});
        var doc = try std.json.parseFromSliceLeaky(Value, a, input.projection, .{ .allocate = .alloc_always });
        if (mode == 13) try doc.object.put(a, "generator_sha256", .{ .string = occurrence_generator_sha256 });
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        try doc.object.put(a, "raw_sha256", .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
        try std.testing.expectError(invalid, TiffCompanionTestSource.registry(a, .{ .raw = raw, .projection = try std.json.Stringify.valueAlloc(a, doc, .{}) }, &ns));
    }
}

test "TIFF companion scratch and owned facts preserve allocation failure cleanup" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const input = try TiffCompanionTestSource.make(arena.allocator(), &ns, true);
    const Check = struct {
        fn run(allocator: A, fixture: FileTestSource.Fixture, namespaces_value: *const namespaces.Registry) !void {
            var result = try TiffCompanionTestSource.registry(allocator, fixture, namespaces_value);
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 1), result.records.len);
            try std.testing.expectEqualStrings(TiffCompanionTestSource.file, result.records[0].canonical_file);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Check.run, .{ input, &ns });
}

test "validated raster SVG mode supports logical width parameters without granting base or legacy authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var ns = try TestSource.namespace(a); defer ns.deinit();
    // Controlled normal-format replay, not a new API observation. Existing
    // constructor checks still establish identity, axes and raster URL mode.
    const observed = try ObservedSvgBatchTestSource.make(a, &ns, 2, .valid);
    var registry = try Registry.init(a, observed.projection, observed.raw, observed.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
    for (0..2) |i| {
        var name_buffer: [64]u8 = undefined;
        for ([_][]const u8{ "Alias", "Target" }) |prefix| {
            const name = try std.fmt.bufPrint(&name_buffer, "Sary:{s}-{d:0>3}.svg", .{prefix, i});
            for ([_]u32{ 104, 249, 250, 251, 400, 8192 }) |width|
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, name, .thumbnail, width, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, 400, 250));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .framed, 400, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, 0, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, null, null));
        }
    }
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, "Sary:Unknown.svg", .thumbnail, 400, null));
    const base = try FileTestSource.make(a, &ns, false);
    var unobserved = try Registry.init(a, base.projection, base.raw, TestSource.site, &ns, accepted_core, generator_sha256); defer unobserved.deinit();
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&unobserved, a, TestSource.file, .thumbnail, 512, null));
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&unobserved, a, TestSource.file, .thumbnail, 513, null));
    var legacy = try Registry.init(a, @embedFile("testdata/figure-sizing/figure-sizing.json"), TestSource.raw, TestSource.site, &ns, accepted_core, generator_sha256); defer legacy.deinit();
    try std.testing.expect(!legacy.file_authority);
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&legacy, a, TestSource.file, .thumbnail, 401, null));
}

test "parameterized raster SVG logical width keeps measured point and representation format provenance limits" {
    // Scalar boundary controls use a hypothetical validated-mode record. They
    // are not a source-file/handler attestation or a replacement API fixture.
    var record: Record = .{ .canonical_file = "File:Controlled.svg", .file_sha1 = "0000000000000000000000000000000000000000",
        .file_timestamp = "2026-10-01T00:00:00Z", .original_width = 1, .original_height = 2,
        .format = .thumbnail, .width_px = 250, .height_px = null, .sizing = .requested_fit,
        .proof_kind = "file-svg-observed-thumbnail-width" };
    try std.testing.expect(observedSvgRasterLogicalWidth(record, 250, null));
    try std.testing.expect(observedSvgRasterLogicalWidth(record, 2147483647, null));
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 2147483648, null));
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 0, null));
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, 250));
    record.proof_kind = "file-logical-axes-width-bound";
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
    record.proof_kind = "file-svg-observed-thumbnail-width"; record.format = .framed;
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
    record.format = .thumbnail; record.sizing = .intrinsic;
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
    record.sizing = .requested_fit; record.original_width = 0;
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
    record.original_width = 1; record.original_height = 0;
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
    record.original_height = 2; record.height_px = 1;
    try std.testing.expect(!observedSvgRasterLogicalWidth(record, 400, null));
}

const CompatibilityTestSource = struct {
    fn check(a: A, fixture: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
        var p: StreamTestSource.Slice = .{ .bytes = fixture.projection, .chunk = 37 };
        var r: StreamTestSource.Slice = .{ .bytes = fixture.raw, .chunk = 37 };
        var projection = p.input(); var raw = r.input();
        try Registry.checkStreamCompatibility(a, &projection, &raw, fixture.site, ns, accepted_core);
        try std.testing.expect(projection.digest == null and raw.digest == null);
        const p_end = std.mem.indexOfScalar(u8, fixture.projection, '\n').? + 1;
        const r_end = std.mem.indexOfScalar(u8, fixture.raw, '\n').? + 1;
        try std.testing.expect(projection.offset < p_end + 37 and raw.offset < r_end + 37);
    }
};

test "stream compatibility shares known source profiles and refuses incompatible headers" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const v3 = try StreamTestSource.convert(temp, try ObservedSvgTestSource.make(temp, &ns, 0));
    const v4 = try StreamTestSource.convert(temp, try GifGeometryTestSource.make(temp, &ns, .{}));
    for ([_]StreamTestSource.Fixture{ v3, v4 }) |good| {
        try CompatibilityTestSource.check(a, good, &ns);
        var full = try StreamTestSource.init(a, good, &ns, 37); defer full.deinit();
        const end = std.mem.indexOfScalar(u8, good.projection, '\n').?;
        for (0..6) |mode| {
            var header = try std.json.parseFromSliceLeaky(StreamHeader, temp, good.projection[0..end], .{ .allocate = .alloc_always });
            switch (mode) {
                0 => header.generator_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
                1 => try header.source_profile.object.put(temp, "kind", .{ .string = "unproved-profile" }),
                2 => header.namespace_registry_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
                3 => header.raw_bytes += 1,
                4 => header.base_batches += 1,
                5 => header.core_revision = "ffffffffffffffffffffffffffffffffffffffff",
                else => unreachable,
            }
            var bad = good;
            bad.projection = try std.mem.concat(temp, u8, &.{ try std.json.Stringify.valueAlloc(temp, header, .{}), good.projection[end..] });
            try std.testing.expectError(invalid, CompatibilityTestSource.check(a, bad, &ns));
            try std.testing.expectError(invalid, StreamTestSource.init(a, bad, &ns, 37));
        }
    }
}

test "stream compatibility never substitutes for full fact and raw digest validation" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const good = try StreamTestSource.convert(temp, try ObservedSvgTestSource.make(temp, &ns, 0));
    const end = std.mem.indexOfScalar(u8, good.projection, '\n').? + 1;
    const corrupt = try temp.dupe(u8, good.projection);
    @memset(corrupt[end .. corrupt.len - 1], ' ');
    corrupt[end] = '{'; corrupt[end + 1] = '}';
    const bad = StreamTestSource.Fixture{ .projection = corrupt, .raw = good.raw, .site = good.site };
    try CompatibilityTestSource.check(a, bad, &ns);
    try std.testing.expectError(error.MissingField, StreamTestSource.init(a, bad, &ns, 37));
    var header = try std.json.parseFromSliceLeaky(StreamHeader, temp, good.projection[0 .. end - 1], .{});
    header.raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    const wrong_digest = StreamTestSource.Fixture{
        .projection = try std.mem.concat(temp, u8, &.{ try std.json.Stringify.valueAlloc(temp, header, .{}), good.projection[end - 1 ..] }),
        .raw = good.raw, .site = good.site,
    };
    try CompatibilityTestSource.check(a, wrong_digest, &ns);
    try std.testing.expectError(invalid, StreamTestSource.init(a, wrong_digest, &ns, 37));
    try std.testing.checkAllAllocationFailures(a, CompatibilityTestSource.check, .{ good, &ns });
}

const ReplayContractTestSource = struct {
    const producer_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const producer_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    fn document(a: A, bytes: []const u8, generator: []const u8) ![]const u8 {
        var value = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
        try value.object.put(a, "replay_contract", .{ .string = replay_contract });
        try value.object.put(a, "generator_sha256", .{ .string = generator });
        return std.json.Stringify.valueAlloc(a, value, .{});
    }
    fn stream(a: A, fixture: ObservedSvgTestSource.Fixture, generator: []const u8) !ObservedSvgTestSource.Fixture {
        const end = std.mem.indexOfScalar(u8, fixture.projection, '\n').?;
        return .{ .projection = try std.mem.concat(a, u8, &.{ try document(a, fixture.projection[0..end], generator), fixture.projection[end..] }),
            .raw = fixture.raw, .site = fixture.site };
    }
    fn compatibility(a: A, fixture: ObservedSvgTestSource.Fixture, ns: *const namespaces.Registry) !void {
        var p = StreamTestSource.Slice{ .bytes = fixture.projection, .chunk = 17 };
        var r = StreamTestSource.Slice{ .bytes = fixture.raw, .chunk = 19 };
        var projection = p.input(); var raw = r.input();
        try Registry.checkStreamCompatibility(a, &projection, &raw, fixture.site, ns, accepted_core);
        try std.testing.expect(projection.digest == null and raw.digest == null);
    }
};

test "explicit Figure replay contract preserves TIFF and SVG semantics across producer provenance" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var inputs = std.heap.ArenaAllocator.init(a); defer inputs.deinit(); const temp = inputs.allocator();
    const input = try TiffCompanionTestSource.make(temp, &ns, true);
    var legacy = try TiffCompanionTestSource.registry(a, input, &ns); defer legacy.deinit();
    const streamed = try StreamTestSource.convert(temp, .{ .projection = input.projection, .raw = input.raw, .site = TestSource.site });
    const height = try SvgHeightTestSource.make(temp, &ns);
    const height_stream = try StreamTestSource.convert(temp, height);
    for ([_][]const u8{ ReplayContractTestSource.producer_a, ReplayContractTestSource.producer_b }) |generator| {
        const projected = try ReplayContractTestSource.document(temp, input.projection, generator);
        var aggregate = try Registry.init(a, projected, input.raw, TestSource.site, &ns, accepted_core, generator_sha256);
        defer aggregate.deinit();
        const fixture = try ReplayContractTestSource.stream(temp, streamed, generator);
        try ReplayContractTestSource.compatibility(a, fixture, &ns);
        var stream = try StreamTestSource.init(a, fixture, &ns, 7); defer stream.deinit();
        try std.testing.expectEqualDeep(legacy.records, aggregate.records);
        try std.testing.expectEqualDeep(legacy.records, stream.records);
        try std.testing.expect(try permitsLargeRawInput(a, projected));
        for ([_]*Registry{ &aggregate, &stream }) |registry| {
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(registry, a, TiffCompanionTestSource.file, .thumbnail, 250, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(registry, a, TiffCompanionTestSource.file, .thumbnail, 2421, null));
        }
        const height_fixture = try ReplayContractTestSource.stream(temp, height_stream, generator);
        var height_registry = try StreamTestSource.init(a, height_fixture, &ns, 11); defer height_registry.deinit();
        try std.testing.expectEqual(@as(?u32, 323), try Registry.resolveHeightOccurrence(&height_registry, a, ns.wiki, SvgHeightTestSource.title, TestSource.file, .thumbnail, SvgHeightTestSource.options, 250));
        var old = try std.json.parseFromSliceLeaky(Value, temp, projected, .{});
        _ = old.object.swapRemove("replay_contract");
        try std.testing.expectError(invalid, Registry.init(a, try std.json.Stringify.valueAlloc(temp, old, .{}), input.raw, TestSource.site, &ns, accepted_core, generator_sha256));
    }
}

test "explicit Figure replay contract rejects unknown contract feature provenance and false facts" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var inputs = std.heap.ArenaAllocator.init(a); defer inputs.deinit(); const temp = inputs.allocator();
    const input = try TiffCompanionTestSource.make(temp, &ns, true);
    const projection = try ReplayContractTestSource.document(temp, input.projection, ReplayContractTestSource.producer_a);
    for (0..5) |mode| {
        var value = try std.json.parseFromSliceLeaky(Value, temp, projection, .{});
        switch (mode) {
            0 => try value.object.put(temp, "replay_contract", .{ .string = "wikidict.figure-files-replay.future" }),
            1 => try value.object.put(temp, "replay_contract", .null),
            2 => try value.object.put(temp, "generator_sha256", .{ .string = "unknown" }),
            3 => try value.object.put(temp, "future_feature", .{ .bool = true }),
            4 => try value.object.getPtr("records").?.array.items[0].object.put(temp, "original_width", .{ .integer = 1 }),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(temp, value, .{});
        if (mode == 3) {
            try std.testing.expectError(error.UnknownField, Registry.init(a, changed, input.raw, TestSource.site, &ns, accepted_core, generator_sha256));
        } else try std.testing.expectError(invalid, Registry.init(a, changed, input.raw, TestSource.site, &ns, accepted_core, generator_sha256));
        if (mode < 4) try std.testing.expect(!try permitsLargeRawInput(a, changed));
    }
    var raw_value = try std.json.parseFromSliceLeaky(Value, temp, input.raw, .{});
    try raw_value.object.getPtr("batches").?.array.items[0].object.put(temp, "future_feature", .{ .bool = true });
    const changed_raw = try std.json.Stringify.valueAlloc(temp, raw_value, .{});
    var value = try std.json.parseFromSliceLeaky(Value, temp, projection, .{});
    var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(changed_raw, &hash, .{});
    try value.object.put(temp, "raw_sha256", .{ .string = try temp.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
    try std.testing.expectError(error.UnknownField, Registry.init(a, try std.json.Stringify.valueAlloc(temp, value, .{}), changed_raw, TestSource.site, &ns, accepted_core, generator_sha256));
    const stream = try ReplayContractTestSource.stream(temp, try StreamTestSource.convert(temp, .{ .projection = input.projection, .raw = input.raw, .site = TestSource.site }), ReplayContractTestSource.producer_a);
    try ReplayContractTestSource.compatibility(a, stream, &ns);
    const end = std.mem.indexOfScalar(u8, stream.projection, '\n').?;
    for (0..4) |mode| {
        var header = try std.json.parseFromSliceLeaky(Value, temp, stream.projection[0..end], .{});
        switch (mode) {
            0 => try header.object.put(temp, "replay_contract", .null),
            1 => try header.object.put(temp, "replay_contract", .{ .string = "future" }),
            2 => try header.object.put(temp, "generator_sha256", .{ .string = "unknown" }),
            3 => try header.object.put(temp, "future_feature", .{ .bool = true }),
            else => unreachable,
        }
        const bad_stream = ObservedSvgTestSource.Fixture{ .projection = try std.mem.concat(temp, u8, &.{ try std.json.Stringify.valueAlloc(temp, header, .{}), stream.projection[end..] }), .raw = stream.raw, .site = stream.site };
        if (mode == 3) {
            try std.testing.expectError(error.UnknownField, ReplayContractTestSource.compatibility(a, bad_stream, &ns));
            try std.testing.expectError(error.UnknownField, StreamTestSource.init(a, bad_stream, &ns, 7));
        } else {
            try std.testing.expectError(invalid, ReplayContractTestSource.compatibility(a, bad_stream, &ns));
            try std.testing.expectError(invalid, StreamTestSource.init(a, bad_stream, &ns, 7));
        }
    }
    const fact_end = std.mem.indexOfScalarPos(u8, stream.projection, end + 1, '\n').?;
    var false_fact = try std.json.parseFromSliceLeaky(Value, temp, stream.projection[end + 1..fact_end], .{});
    try false_fact.object.put(temp, "original_width", .{ .integer = 1 });
    const false_stream = ObservedSvgTestSource.Fixture{ .projection = try std.mem.concat(temp, u8, &.{ stream.projection[0..end + 1], try std.json.Stringify.valueAlloc(temp, false_fact, .{}), stream.projection[fact_end..] }), .raw = stream.raw, .site = stream.site };
    try ReplayContractTestSource.compatibility(a, false_stream, &ns);
    try std.testing.expectError(invalid, StreamTestSource.init(a, false_stream, &ns, 7));
}

test "explicit Figure replay contract allocation failures retain owned registry cleanup" {
    const Check = struct {
        fn replay(a: A, input: FileTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try Registry.init(a, input.projection, input.raw, TestSource.site, ns, accepted_core, generator_sha256);
            defer registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TiffCompanionTestSource.file, .thumbnail, 250, null));
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var inputs = std.heap.ArenaAllocator.init(a); defer inputs.deinit(); const temp = inputs.allocator();
    var input = try TiffCompanionTestSource.make(temp, &ns, true);
    input.projection = try ReplayContractTestSource.document(temp, input.projection, ReplayContractTestSource.producer_b);
    try std.testing.checkAllAllocationFailures(a, Check.replay, .{ input, &ns });
}


test "explicit Figure stream replay profile survives overwritten header scratch storage" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var inputs = std.heap.ArenaAllocator.init(a); defer inputs.deinit(); const temp = inputs.allocator();
    const input = try TiffCompanionTestSource.make(temp, &ns, true);
    const fixture = try ReplayContractTestSource.stream(temp,
        try StreamTestSource.convert(temp, .{ .projection = input.projection, .raw = input.raw, .site = TestSource.site }),
        ReplayContractTestSource.producer_b);
    var p = StreamTestSource.Slice{ .bytes = fixture.projection, .chunk = 17 };
    var r = StreamTestSource.Slice{ .bytes = fixture.raw, .chunk = 19 };
    var projection = p.input(); var raw = r.input();
    var owned = std.heap.ArenaAllocator.init(a); defer owned.deinit();
    var scratch_bytes: [128 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    const parsed = try readStreamHeaders(owned.allocator(), scratch.allocator(), &projection, &raw);
    // Reuse all temporary header bytes before dereferencing the dynamic profile.
    @memset(&scratch_bytes, 0xa5);
    _ = try validateFileSource(owned.allocator(), parsed.header, parsed.header.records_count,
        parsed.header.base_batches + parsed.header.observed_batches, fixture.site, &ns, accepted_core, parsed.contract, parsed.response_epochs);
    try std.testing.expect(parsed.contract);
    try std.testing.expectEqualStrings(ReplayContractTestSource.producer_b, parsed.header.generator_sha256);
    var registry = try StreamTestSource.init(a, fixture, &ns, 7); defer registry.deinit();
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit),
        try Registry.resolve(&registry, a, TiffCompanionTestSource.file, .thumbnail, 250, null));
    try std.testing.checkAllAllocationFailures(a, ReplayContractTestSource.compatibility, .{ fixture, &ns });
}


test "streamed Figure fresh fault scratch preserves retained semantics after input release" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); var source_live = true;
    defer if (source_live) source.deinit();
    const input = try ObservedSvgBatchTestSource.make(source.allocator(), &ns, 2, .valid);
    const streamed = try StreamTestSource.convert(source.allocator(), input);
    var retained = try StreamTestSource.init(a, streamed, &ns, 37); defer retained.deinit();
    var fresh = try StreamTestSource.initFreshScratch(a, streamed, &ns, 37); defer fresh.deinit();
    try std.testing.expectEqualDeep(retained.records, fresh.records);
    try std.testing.expectEqual(@as(usize, 4), fresh.records.len);
    source.deinit(); source_live = false;
    for (fresh.records) |record| {
        for ([_]*Registry{ &retained, &fresh }) |registry|
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit),
                try Registry.resolve(registry, a, record.canonical_file, .thumbnail, 250, null));
    }
}

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize, compression_level: c_int) usize;
extern fn ZSTD_isError(code: usize) c_uint;
const RawRecordTestSource = struct {
    fn base64(a: A, bytes: []const u8) ![]const u8 {
        const result = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        return std.base64.standard.Encoder.encode(result, bytes);
    }
    fn envelope(a: A, line: []const u8) !Value {
        const frame = try a.alloc(u8, ZSTD_compressBound(line.len));
        defer a.free(frame);
        const size = ZSTD_compress(frame.ptr, frame.len, line.ptr, line.len, 1);
        if (ZSTD_isError(size) != 0) return error.TestZstdCompressFailed;
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(line, &hash, .{});
        const value = EncodedRawRecord{ .encoding = "zstd", .raw_bytes = line.len,
            .raw_sha256 = &std.fmt.bytesToHex(hash, .lower), .data = try base64(a, frame[0..size]) };
        return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{ .allocate = .alloc_always });
    }
    fn decode(a: A, bytes: []const u8) !RawFileBatch {
        const value = try rawStreamRecordValue(a, bytes, true);
        try validateTiffCompanionField(value, true);
        return std.json.parseFromValueLeaky(RawFileBatch, a, value, .{ .allocate = .alloc_always });
    }
    fn refused(a: A, value: Value, label: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        if (decode(a, bytes)) |_| {
            std.debug.print("compressed Figure refusal vector accepted: {s}\n", .{label});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err == error.OutOfMemory) return err;
        }
    }
    fn reheader(a: A, fixture: StreamTestSource.Fixture, raw: []const u8, contract: ?[]const u8) !StreamTestSource.Fixture {
        const end = std.mem.indexOfScalar(u8, fixture.projection, '\n').?;
        var value = try std.json.parseFromSliceLeaky(Value, a, fixture.projection[0..end], .{});
        if (contract) |name| try value.object.put(a, "replay_contract", .{ .string = name }) else _ = value.object.swapRemove("replay_contract");
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        try value.object.put(a, "raw_sha256", .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
        try value.object.put(a, "raw_bytes", .{ .integer = @intCast(raw.len) });
        return .{ .projection = try std.mem.concat(a, u8, &.{ try std.json.Stringify.valueAlloc(a, value, .{}), fixture.projection[end..] }),
            .raw = raw, .site = fixture.site };
    }
    fn stream(a: A, fixture: StreamTestSource.Fixture, mixed: bool) !StreamTestSource.Fixture {
        const end = std.mem.indexOfScalar(u8, fixture.raw, '\n').?;
        var header = try std.json.parseFromSliceLeaky(Value, a, fixture.raw[0..end], .{});
        try header.object.put(a, "record_encoding", .{ .string = raw_record_encoding });
        var raw: std.ArrayList(u8) = .empty;
        try StreamTestSource.append(a, &raw, header);
        var at = end + 1; var index: usize = 0;
        while (at < fixture.raw.len) : (index += 1) {
            const last = std.mem.indexOfScalarPos(u8, fixture.raw, at, '\n').? + 1;
            const line = fixture.raw[at..last];
            if (mixed and index % 2 != 0) try raw.appendSlice(a, line) else
                try StreamTestSource.append(a, &raw, try envelope(a, line));
            at = last;
        }
        return reheader(a, fixture, raw.items, replay_contract_v2);
    }
    fn marker(a: A, fixture: StreamTestSource.Fixture, encoding: ?Value, contract: ?[]const u8) !StreamTestSource.Fixture {
        const end = std.mem.indexOfScalar(u8, fixture.raw, '\n').?;
        var value = try std.json.parseFromSliceLeaky(Value, a, fixture.raw[0..end], .{});
        if (encoding) |name| try value.object.put(a, "record_encoding", name) else _ = value.object.swapRemove("record_encoding");
        const raw = try std.mem.concat(a, u8, &.{ try std.json.Stringify.valueAlloc(a, value, .{}), fixture.raw[end..] });
        return reheader(a, fixture, raw, contract);
    }
};

test "compressed Figure raw records preserve mixed plain authority and owned source fidelity" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) source.deinit(); const temp = source.allocator();
    const input = try ObservedSvgBatchTestSource.make(temp, &ns, 2, .valid);
    const plain = try StreamTestSource.convert(temp, input);
    const encoded = try RawRecordTestSource.stream(temp, plain, true);
    var legacy = try StreamTestSource.init(a, plain, &ns, 17); defer legacy.deinit();
    var registry = try StreamTestSource.init(a, encoded, &ns, 13); defer registry.deinit();
    try std.testing.expectEqualDeep(legacy.records, registry.records);
    try ReplayContractTestSource.compatibility(a, encoded, &ns);
    const raw_end = std.mem.indexOfScalar(u8, plain.raw, '\n').? + 1;
    const line_end = std.mem.indexOfScalarPos(u8, plain.raw, raw_end, '\n').? + 1;
    const original = plain.raw[raw_end..line_end];
    const envelope = try RawRecordTestSource.envelope(temp, original);
    const batch = try RawRecordTestSource.decode(temp, try std.json.Stringify.valueAlloc(temp, envelope, .{}));
    const original_batch = try std.json.parseFromSliceLeaky(RawFileBatch, temp, original, .{});
    try std.testing.expectEqualDeep(original_batch.requests, batch.requests);
    try std.testing.expectEqualStrings(original_batch.response, batch.response);
    source.deinit(); live = false;
    for (registry.records) |record| {
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit),
            try Registry.resolve(&registry, a, record.canonical_file, .thumbnail, 250, null));
    }
}

test "compressed Figure raw marker requires v2 while v2 plain migration remains supported" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); defer source.deinit(); const temp = source.allocator();
    const plain = try StreamTestSource.convert(temp, try ObservedSvgTestSource.make(temp, &ns, 0));
    const encoded = try RawRecordTestSource.stream(temp, plain, false);
    for ([_]?[]const u8{ null, replay_contract }) |contract| {
        const bad = try RawRecordTestSource.reheader(temp, encoded, encoded.raw, contract);
        try std.testing.expectError(invalid, ReplayContractTestSource.compatibility(a, bad, &ns));
        try std.testing.expectError(invalid, StreamTestSource.init(a, bad, &ns, 17));
    }
    for ([_]Value{ .null, .{ .string = "unknown" } }) |encoding| {
        const bad = try RawRecordTestSource.marker(temp, encoded, encoding, replay_contract_v2);
        try std.testing.expectError(invalid, StreamTestSource.init(a, bad, &ns, 17));
    }
    const unmarked = try RawRecordTestSource.marker(temp, encoded, null, replay_contract_v2);
    try ReplayContractTestSource.compatibility(a, unmarked, &ns);
    try std.testing.expectError(error.UnknownField, StreamTestSource.init(a, unmarked, &ns, 17));
    var migration = try StreamTestSource.init(a, try RawRecordTestSource.reheader(temp, plain, plain.raw, replay_contract_v2), &ns, 17);
    defer migration.deinit();
    try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&migration, a, TestSource.file, .thumbnail, 250, null));
}

test "compressed Figure raw envelope rejects malformed frame hash size base64 and JSONL" {
    var source = std.heap.ArenaAllocator.init(std.testing.allocator); defer source.deinit(); const a = source.allocator();
    const line = "{\"requests\":[\"File:A\"],\"response\":\"{}\"}\n";
    const original = try RawRecordTestSource.envelope(a, line);
    _ = try RawRecordTestSource.decode(a, try std.json.Stringify.valueAlloc(a, original, .{}));
    const field_labels = [_][]const u8{ "encoding", "zero-size", "oversize", "bool-size", "float-wire-size", "uppercase-sha", "wrong-sha", "base64", "extra-key", "wrong-size" };
    for (0..10) |mode| {
        var value = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, original, .{}), .{});
        switch (mode) {
            0 => try value.object.put(a, "encoding", .{ .string = "gzip" }),
            1 => try value.object.put(a, "raw_bytes", .{ .integer = 0 }),
            2 => try value.object.put(a, "raw_bytes", .{ .integer = stream_batch_limit + 1 }),
            3 => try value.object.put(a, "raw_bytes", .{ .bool = true }),
            4 => try value.object.put(a, "raw_bytes", .{ .number_string = try std.fmt.allocPrint(a, "{d}.0", .{line.len}) }),
            5 => try value.object.put(a, "raw_sha256", .{ .string = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }),
            6 => try value.object.put(a, "raw_sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" }),
            7 => try value.object.put(a, "data", .{ .string = "A/==" }),
            8 => try value.object.put(a, "extra", .{ .bool = true }),
            9 => try value.object.put(a, "raw_bytes", .{ .integer = @intCast(line.len - 1) }),
            else => unreachable,
        }
        if (mode == 4) {
            // Integral floats stringify as integer tokens unless the wire spelling is explicit.
            const wire = try std.json.Stringify.valueAlloc(a, value, .{});
            const parsed = try std.json.parseFromSliceLeaky(Value, a, wire, .{});
            try std.testing.expect((try field(parsed, "raw_bytes")) == .float);
        }
        try RawRecordTestSource.refused(a, value, field_labels[mode]);
    }
    const nested = try std.mem.concat(a, u8, &.{ try std.json.Stringify.valueAlloc(a, original, .{}), "\n" });
    for ([_][]const u8{ line[0 .. line.len - 1], "{}\n\n", "{}\r\n", "\xef\xbb\xbf{}\n", "\xff\n", nested },
        [_][]const u8{ "missing-LF", "extra-LF", "CR", "BOM", "UTF8", "nested-envelope" }) |invalid_line, label|
        try RawRecordTestSource.refused(a, try RawRecordTestSource.envelope(a, invalid_line), label);
    const data = try string(original, "data");
    const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
    const frame = try a.alloc(u8, size); try std.base64.standard.Decoder.decode(frame, data);
    const duplicate = try std.mem.concat(a, u8, &.{ frame, frame });
    const trailing = try std.mem.concat(a, u8, &.{ frame, "junk" });
    const corrupt = try a.dupe(u8, frame); corrupt[0] = 0;
    for ([_][]const u8{ frame[0 .. frame.len - 1], duplicate, trailing, corrupt, "\x50\x2a\x4d\x18\x00\x00\x00\x00" },
        [_][]const u8{ "truncated", "duplicate-frame", "trailing-bytes", "corrupt-magic", "skippable-frame" }) |invalid_frame, label| {
        var value = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, original, .{}), .{});
        try value.object.put(a, "data", .{ .string = try RawRecordTestSource.base64(a, invalid_frame) });
        try RawRecordTestSource.refused(a, value, label);
    }
}

test "compressed Figure raw full replay still rejects rehashed semantic corruption" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); defer source.deinit(); const temp = source.allocator();
    const initial = try ObservedSvgTestSource.make(temp, &ns, 0);
    const plain = try StreamTestSource.convert(temp, initial);
    const end = std.mem.indexOfScalar(u8, plain.raw, '\n').? + 1;
    const last = std.mem.indexOfScalarPos(u8, plain.raw, end, '\n').?;
    var record = try std.json.parseFromSliceLeaky(Value, temp, plain.raw[end..last], .{});
    var response = try std.json.parseFromSliceLeaky(Value, temp, try string(record, "response"), .{});
    const info = response.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?;
    try info.array.items[0].object.put(temp, "width", .{ .integer = 1 });
    try record.object.put(temp, "response", .{ .string = try std.json.Stringify.valueAlloc(temp, response, .{}) });
    const changed_raw = try std.mem.concat(temp, u8, &.{ plain.raw[0..end], try std.json.Stringify.valueAlloc(temp, record, .{}), plain.raw[last..] });
    const false_plain = try RawRecordTestSource.reheader(temp, plain, changed_raw, replay_contract_v2);
    const encoded = try RawRecordTestSource.stream(temp, false_plain, false);
    try ReplayContractTestSource.compatibility(a, encoded, &ns);
    try std.testing.expectError(invalid, StreamTestSource.init(a, encoded, &ns, 17));
}

test "compressed Figure raw decoding propagates required allocation failures and cleanup" {
    const Check = struct {
        fn replay(a: A, fixture: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.initFreshScratch(a, fixture, ns, 17); defer registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit),
                try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, null));
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); defer source.deinit(); const temp = source.allocator();
    const fixture = try RawRecordTestSource.stream(temp, try StreamTestSource.convert(temp, try ObservedSvgTestSource.make(temp, &ns, 0)), false);
    try Check.replay(a, fixture, &ns);
    var backing = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Check.replay, .{ fixture, &ns });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

const JpegWidthTestSource = struct {
    fn make(a: A, ns: *const namespaces.Registry, metadata: ?[]const u8, core: []const u8, second_metadata: ?[]const u8) !ObservedSvgTestSource.Fixture {
        const initial = try GifGeometryTestSource.make(a, ns, .{ .v4 = false, .mime = "image/jpeg", .width = 200, .height = 144,
            .metadata = metadata orelse "[]", .core = core });
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, initial.projection, .{ .allocate = .alloc_always });
        const original = try std.json.parseFromSliceLeaky(RawFileBatches, a, initial.raw, .{ .allocate = .alloc_always });
        var response = try std.json.parseFromSliceLeaky(Value, a, original.batches[0].response, .{ .allocate = .alloc_always });
        const image = &response.object.getPtr("query").?.object.getPtr("pages").?.array.items[0].object.getPtr("imageinfo").?.array.items[0];
        if (metadata == null) _ = image.object.swapRemove("metadata");
        const first_response = try std.json.Stringify.valueAlloc(a, response, .{});
        var batch_list: std.ArrayList(RawFileBatch) = .empty;
        try batch_list.append(a, .{ .requests = original.batches[0].requests, .response = first_response });
        if (second_metadata) |other| {
            const alias = "Sary:Z-JPEG-alias.jpg";
            try image.object.put(a, "metadata", try std.json.parseFromSliceLeaky(Value, a, other, .{ .allocate = .alloc_always }));
            const redirects = try std.json.Stringify.valueAlloc(a, .{.{ .from = alias, .to = TestSource.file }}, .{});
            try response.object.getPtr("query").?.object.put(a, "redirects", try std.json.parseFromSliceLeaky(Value, a, redirects, .{ .allocate = .alloc_always }));
            try batch_list.append(a, .{ .requests = &.{alias}, .response = try std.json.Stringify.valueAlloc(a, response, .{}) });
            const facts = try a.alloc(FileFact, 2);
            facts[0] = doc.records[0]; facts[1] = doc.records[0];
            facts[1].requested_file = alias; facts[1].batch = 1;
            std.mem.sort(FileFact, facts, {}, struct {
                fn less(_: void, left: FileFact, right: FileFact) bool {
                    return std.mem.order(u8, left.requested_file, right.requested_file) == .lt;
                }
            }.less);
            doc.records = facts;
        }
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = original.schema, .batches = batch_list.items }, .{});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        doc.raw_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        return .{ .projection = try std.json.Stringify.valueAlloc(a, doc, .{}), .raw = raw, .site = initial.site };
    }
};

test "JPEG width clamp requires complete authenticated unrotated metadata and preserves height authority" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    const Case = struct { metadata: ?[]const u8, allowed: bool };
    for ([_]Case{
        .{ .metadata = "[]", .allowed = false },
        .{ .metadata = "[{\"name\":\"_error\",\"value\":\"0\"}]", .allowed = true },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":1}]", .allowed = true },
        .{ .metadata = "[{\"name\":\"Software\",\"value\":\"retained\"}]", .allowed = true },
        .{ .metadata = null, .allowed = false },
        .{ .metadata = "null", .allowed = false },
        .{ .metadata = "{}", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":6}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":3}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":8}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":2}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":null}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":\"1\"}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":true}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"Orientation\",\"value\":1},{\"name\":\"Orientation\",\"value\":6}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"_error\",\"value\":\"-1\"}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"_error\",\"value\":0}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"_error\",\"value\":\"0\"},{\"name\":\"Orientation\",\"value\":1}]", .allowed = false },
        .{ .metadata = "[{\"name\":\"errors\",\"value\":[]}]", .allowed = false },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
        const temp = arena.allocator();
        const input = try JpegWidthTestSource.make(temp, &ns, case.metadata, current_core, null);
        var registry = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
        const stream = try StreamTestSource.convert(temp, input);
        var streamed = try StreamTestSource.init(a, stream, &ns, 11); defer streamed.deinit();
        arena.deinit(); live = false;
        try std.testing.expectEqualDeep(registry.records, streamed.records);
        for ([_]*const Registry{ &registry, &streamed }) |source| {
            try std.testing.expectEqual(@as(?u32, if (case.allowed) 200 else null), try Registry.resolveWidthLimit(source, a, TestSource.file, .thumbnail));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, TestSource.file, .framed));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(source, a, "Missing.jpg", .thumbnail));
            // The grant bounds the caller's request; final resolution never accepts an oversized box.
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(source, a, TestSource.file, .thumbnail, 250, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, 200, null));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(source, a, TestSource.file, .thumbnail, 200, 80));
            try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveHeightOnlyWidth(source, a, TestSource.file, .thumbnail, 80));
            try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(source, a, TestSource.file, .thumbnail, 0));
        }
    }
}

test "JPEG width metadata proof is core bound and cannot hide contradictory alias metadata" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const temp = arena.allocator();
    const lean_input = try JpegWidthTestSource.make(temp, &ns, null, current_core, null);
    var lean = try Registry.init(a, lean_input.projection, lean_input.raw, lean_input.site, &ns, accepted_core, generator_sha256); defer lean.deinit();
    const full_input = try JpegWidthTestSource.make(temp, &ns, "[{\"name\":\"_error\",\"value\":\"0\"}]", current_core, null);
    var full = try Registry.init(a, full_input.projection, full_input.raw, full_input.site, &ns, accepted_core, generator_sha256); defer full.deinit();
    try std.testing.expectEqualDeep(lean.records, full.records);
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&lean, a, TestSource.file, .thumbnail));
    try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveWidthLimit(&full, a, TestSource.file, .thumbnail));
    for ([_][]const u8{ accepted_core, compatible_core }) |core| {
        const input = try JpegWidthTestSource.make(temp, &ns, "[{\"name\":\"_error\",\"value\":\"0\"}]", core, null);
        var registry = try Registry.init(a, input.projection, input.raw, input.site, &ns, accepted_core, generator_sha256); defer registry.deinit();
        try std.testing.expectEqual(@as(?u32, null), try Registry.resolveWidthLimit(&registry, a, TestSource.file, .thumbnail));
        try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveHeightOnlyWidth(&registry, a, TestSource.file, .thumbnail, 80));
    }
    for ([_]bool{ false, true }) |contradictory| {
        const input = try JpegWidthTestSource.make(temp, &ns, "[{\"name\":\"_error\",\"value\":\"0\"}]", current_core, if (contradictory) "[{\"name\":\"Orientation\",\"value\":6}]" else "[{\"name\":\"_error\",\"value\":\"0\"}]");
        var registry = try StreamTestSource.init(a, try StreamTestSource.convert(temp, input), &ns, 13); defer registry.deinit();
        for ([_][]const u8{ TestSource.file, "Sary:Z-JPEG-alias.jpg" }) |name| {
            try std.testing.expectEqual(@as(?u32, if (contradictory) null else 200), try Registry.resolveWidthLimit(&registry, a, name, .thumbnail));
            try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveHeightOnlyWidth(&registry, a, name, .thumbnail, 80));
        }
    }
}

test "JPEG metadata proof ownership propagates required allocation failures" {
    const Check = struct {
        fn replay(a: A, input: StreamTestSource.Fixture, ns: *const namespaces.Registry) !void {
            var registry = try StreamTestSource.initFreshScratch(a, input, ns, 17); defer registry.deinit();
            try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveWidthLimit(&registry, a, TestSource.file, .thumbnail));
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const input = try JpegWidthTestSource.make(arena.allocator(), &ns, "[{\"name\":\"_error\",\"value\":\"0\"}]", current_core, null);
    const stream = try StreamTestSource.convert(arena.allocator(), input);
    try Check.replay(a, stream, &ns);
    var backing = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Check.replay, .{ stream, &ns });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

const ResponseEpochTestSource = struct {
    const Fixture = ObservedSvgTestSource.Fixture;
    fn contract(a: A, bytes: []const u8, selected: ?[]const u8) ![]const u8 {
        var doc = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
        if (selected) |value| try doc.object.put(a, "replay_contract", .{ .string = value }) else _ = doc.object.swapRemove("replay_contract");
        return std.json.Stringify.valueAlloc(a, doc, .{});
    }
    fn seal(a: A, doc: FilesDocument, batches: []const RawFileBatch, site: []const u8, streamed: bool, selected: ?[]const u8) !Fixture {
        if (streamed) {
            const input = try StreamTestSource.parts(a, doc, batches, site);
            const end = std.mem.indexOfScalar(u8, input.projection, '\n').?;
            return .{ .projection = try std.mem.concat(a, u8, &.{ try contract(a, input.projection[0..end], selected), input.projection[end..] }), .raw = input.raw, .site = site };
        }
        const raw = try std.json.Stringify.valueAlloc(a, RawFileBatches{ .schema = "wikidict.figure-sizing-raw-batches.v1", .batches = batches }, .{});
        var projected = doc;
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        projected.raw_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
        return .{ .projection = try contract(a, try std.json.Stringify.valueAlloc(a, projected, .{}), selected), .raw = raw, .site = site };
    }
    fn make(a: A, ns: *const namespaces.Registry, cores: []const []const u8, anchor: []const u8, streamed: bool, selected: ?[]const u8) !Fixture {
        const initial = try GifGeometryTestSource.make(a, ns, .{ .core = anchor, .mime = "image/jpeg", .width = 200, .height = 144,
            .metadata = "[{\"name\":\"_error\",\"value\":\"0\"}]" });
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, initial.projection, .{});
        const raw = try std.json.parseFromSliceLeaky(RawFileBatches, a, initial.raw, .{});
        const facts = try a.alloc(FileFact, cores.len);
        const batches = try a.alloc(RawFileBatch, cores.len);
        for (cores, facts, batches, 0..) |core, *fact, *batch, index| {
            const title = try std.fmt.allocPrint(a, "Sary:Epoch-{d}.jpg", .{index});
            var response = try std.json.parseFromSliceLeaky(Value, a, raw.batches[0].response, .{ .allocate = .alloc_always });
            const query = response.object.getPtr("query").?;
            _ = query.object.swapRemove("normalized"); _ = query.object.swapRemove("redirects");
            try query.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = core });
            const page = &query.object.getPtr("pages").?.array.items[0];
            try page.object.put(a, "title", .{ .string = title });
            try page.object.getPtr("imageinfo").?.array.items[0].object.put(a, "canonicaltitle", .{ .string = title });
            const names = try a.alloc([]const u8, 1); names[0] = title;
            batch.* = .{ .requests = names, .response = try std.json.Stringify.valueAlloc(a, response, .{}) };
            fact.* = doc.records[0]; fact.requested_file = title; fact.canonical_file = title; fact.batch = @intCast(index);
        }
        doc.records = facts;
        return seal(a, doc, batches, initial.site, streamed, selected);
    }
    fn init(a: A, input: Fixture, ns: *const namespaces.Registry, streamed: bool, comptime fresh: bool) !Registry {
        if (!streamed) return Registry.init(a, input.projection, input.raw, input.site, ns, current_core, generator_sha256);
        var p = StreamTestSource.Slice{ .bytes = input.projection, .chunk = 13 };
        var r = StreamTestSource.Slice{ .bytes = input.raw, .chunk = 17 };
        var projection = p.input(); var raw = r.input();
        var result = if (fresh)
            try Registry.initStreamWithScratchReset(.free_all, a, &projection, &raw, input.site, ns, current_core)
        else try Registry.initStream(a, &projection, &raw, input.site, ns, current_core);
        errdefer result.deinit();
        try std.testing.expect(projection.digest != null and raw.digest != null);
        return result;
    }
    fn compatibility(a: A, input: Fixture, ns: *const namespaces.Registry) !void {
        var p = StreamTestSource.Slice{ .bytes = input.projection, .chunk = 13 };
        var r = StreamTestSource.Slice{ .bytes = input.raw, .chunk = 17 };
        var projection = p.input(); var raw = r.input();
        try Registry.checkStreamCompatibility(a, &projection, &raw, input.site, ns, current_core);
        try std.testing.expect(projection.digest == null and raw.digest == null);
    }
    fn changeEpoch(a: A, ns: *const namespaces.Registry, input: Fixture, companion_core: []const u8, streamed: bool) !Fixture {
        const profile_fixture = try GifGeometryTestSource.make(a, ns, .{});
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, a, input.projection, .{});
        doc.core_revision = current_core;
        doc.source_profile = (try std.json.parseFromSliceLeaky(FilesDocument, a, profile_fixture.projection, .{})).source_profile;
        const parsed = try std.json.parseFromSliceLeaky(RawFileBatches, a, input.raw, .{});
        const batches = try a.dupe(RawFileBatch, parsed.batches);
        for (batches) |*batch| {
            var response = try std.json.parseFromSliceLeaky(Value, a, batch.response, .{});
            try response.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = response_core });
            batch.response = try std.json.Stringify.valueAlloc(a, response, .{});
            if (batch.tiff_metadata_response) |bytes| {
                var companion = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
                try companion.object.getPtr("query").?.object.getPtr("general").?.object.put(a, "git-hash", .{ .string = companion_core });
                batch.tiff_metadata_response = try std.json.Stringify.valueAlloc(a, companion, .{});
            }
        }
        return seal(a, doc, batches, profile_fixture.site, streamed, replay_contract_v3);
    }
};

test "compatible response epochs preserve exact aggregate stream facts and JPEG metadata grants" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    for ([_][2][]const u8{ .{ current_core, current_core }, .{ current_core, response_core }, .{ response_core, response_core } }) |cores| {
        const plain = try ResponseEpochTestSource.make(temp, &ns, &cores, cores[0], false, replay_contract_v3);
        const stream = try ResponseEpochTestSource.make(temp, &ns, &cores, cores[0], true, replay_contract_v3);
        try ResponseEpochTestSource.compatibility(a, stream, &ns);
        var aggregate = try ResponseEpochTestSource.init(a, plain, &ns, false, false); defer aggregate.deinit();
        var streamed = try ResponseEpochTestSource.init(a, stream, &ns, true, false); defer streamed.deinit();
        try std.testing.expectEqualDeep(aggregate.records, streamed.records);
        try std.testing.expectEqual(@as(usize, 2), aggregate.records.len);
        for ([_]*const Registry{ &aggregate, &streamed }) |registry| {
            try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveWidthLimit(registry, a, "Sary:Epoch-1.jpg", .thumbnail));
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(registry, a, "Sary:Epoch-1.jpg", .thumbnail, 200, null));
        }
    }
}

test "compatible response epochs reject legacy downgrade unknown core registration and false facts" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const non_gif = try ResponseEpochTestSource.make(temp, &ns, &.{response_core}, response_core, false, null);
    var non_gif_doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, non_gif.projection, .{});
    non_gif_doc.source_profile = try TestSource.profileValue(temp, non_gif.site);
    const non_gif_batches = try std.json.parseFromSliceLeaky(RawFileBatches, temp, non_gif.raw, .{});
    for ([_]bool{ false, true }) |streamed| {
        const bad = try ResponseEpochTestSource.seal(temp, non_gif_doc, non_gif_batches.batches, non_gif.site, streamed, replay_contract_v3);
        try std.testing.expectError(invalid, ResponseEpochTestSource.init(a, bad, &ns, streamed, false));
        if (streamed) try std.testing.expectError(invalid, ResponseEpochTestSource.compatibility(a, bad, &ns));
    }
    for ([_]?[]const u8{ null, replay_contract, replay_contract_v2, "wikidict.figure-file-replay.future" }) |selected| {
        for ([_]bool{ false, true }) |streamed| {
            const input = try ResponseEpochTestSource.make(temp, &ns, &.{ current_core, response_core }, current_core, streamed, selected);
            try std.testing.expectError(invalid, ResponseEpochTestSource.init(a, input, &ns, streamed, false));
        }
    }
    const input = try ResponseEpochTestSource.make(temp, &ns, &.{ current_core, response_core }, current_core, false, null);
    const original = try std.json.parseFromSliceLeaky(RawFileBatches, temp, input.raw, .{});
    for (0..5) |mode| {
        var doc = try std.json.parseFromSliceLeaky(FilesDocument, temp, input.projection, .{ .allocate = .alloc_always });
        const batches = try temp.dupe(RawFileBatch, original.batches);
        var response = try std.json.parseFromSliceLeaky(Value, temp, batches[1].response, .{ .allocate = .alloc_always });
        const query = response.object.getPtr("query").?;
        if (mode == 0) try query.object.getPtr("general").?.object.put(temp, "git-hash", .{ .string = "0000000000000000000000000000000000000000" });
        if (mode == 1) try query.object.getPtr("extensions").?.array.items[0].object.put(temp, "vcs-version", .{ .string = "0000000000000000000000000000000000000000" });
        if (mode == 2) try query.object.getPtr("general").?.object.put(temp, "lang", .{ .string = "en" });
        if (mode == 3) try response.object.put(temp, "curtimestamp", .{ .string = "2000-01-01T00:00:00Z" });
        if (mode == 4) {
            const records = try temp.dupe(FileFact, doc.records); records[1].original_width += 1; doc.records = records;
        }
        batches[1].response = try std.json.Stringify.valueAlloc(temp, response, .{});
        for ([_]bool{ false, true }) |streamed| {
            const bad = try ResponseEpochTestSource.seal(temp, doc, batches, input.site, streamed, replay_contract_v3);
            try std.testing.expectError(invalid, ResponseEpochTestSource.init(a, bad, &ns, streamed, false));
        }
    }
}

test "compatible response epochs bind TIFF companion epoch and exclude HTML occurrence authority" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temp = arena.allocator();
    const tiff = try TiffCompanionTestSource.make(temp, &ns, true);
    const fixture = ObservedSvgTestSource.Fixture{ .projection = tiff.projection, .raw = tiff.raw, .site = TestSource.site };
    const html = try SvgHeightTestSource.make(temp, &ns);
    for ([_]bool{ false, true }) |streamed| {
        const good = try ResponseEpochTestSource.changeEpoch(temp, &ns, fixture, response_core, streamed);
        var registry = try ResponseEpochTestSource.init(a, good, &ns, streamed, false); defer registry.deinit();
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TiffCompanionTestSource.file, .thumbnail, 250, null));
        const bad = try ResponseEpochTestSource.changeEpoch(temp, &ns, fixture, current_core, streamed);
        try std.testing.expectError(invalid, ResponseEpochTestSource.init(a, bad, &ns, streamed, false));
        const unproved_html = try ResponseEpochTestSource.changeEpoch(temp, &ns, html, response_core, streamed);
        try std.testing.expectError(invalid, ResponseEpochTestSource.init(a, unproved_html, &ns, streamed, false));
    }
}

test "compatible response epoch stream owns facts after source release and required allocation failures" {
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); var live = true; defer if (live) arena.deinit();
    const fixture = try ResponseEpochTestSource.make(arena.allocator(), &ns, &.{ current_core, response_core }, current_core, true, replay_contract_v3);
    const Check = struct {
        fn replay(backing: A, input: ResponseEpochTestSource.Fixture, registry_ns: *const namespaces.Registry) !void {
            var result = try ResponseEpochTestSource.init(backing, input, registry_ns, true, true); defer result.deinit();
            try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveWidthLimit(&result, backing, "Sary:Epoch-1.jpg", .thumbnail));
        }
    };
    var backing = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Check.replay, .{ fixture, &ns });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    var result = try ResponseEpochTestSource.init(a, fixture, &ns, true, false); defer result.deinit();
    arena.deinit(); live = false;
    try std.testing.expectEqualStrings("Sary:Epoch-1.jpg", result.records[1].canonical_file);
    try std.testing.expectEqual(@as(?u32, 200), try Registry.resolveWidthLimit(&result, a, "Sary:Epoch-1.jpg", .thumbnail));
}
