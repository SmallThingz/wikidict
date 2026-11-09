const std = @import("std");
const namespaces = @import("namespace_registry");
const encoder = @import("encoder");
const types = encoder.presentation_types;
const A = std.mem.Allocator;
const Value = std.json.Value;
const max_metadata: usize = 64 * 1024 * 1024;
const max_response: usize = 2 * 1024 * 1024;
const max_records = 250_000;
const accepted_core = "0470f6c99a6456a366635bf25a517a1f951de6f5";
const compatible_core = "ead780177c5a02aa63ac6fd3a50977df9719fe63";
const current_core = "f45897451256aa3799aecc5d7ee320ade22beaec";
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
const RawFileBatch = struct { requests: []const []const u8, response: []const u8, observed_svg_width_px: ?u32 = null };
const RawFileBatches = struct { schema: []const u8, batches: []const RawFileBatch };
const max_batches = 10_000;
// File-level observations use a separate generator contract from occurrence v1.
pub const file_generator_sha256 = "fab1f2a019e57235e7e2b562bb0ca01a6adeb5fa0686cbd28535157b494f0d37";
const previous_stream_generator_sha256 = "3b352a42f22e51eef1415800916ab8ace31407c6cc01291981f698970d060a15";
fn streamGenerator(value: []const u8) bool {
    return equal(value, file_generator_sha256) or equal(value, previous_stream_generator_sha256) or
        equal(value, "fa3c8823855b1673947c0fd3ea522bbbe276ef5fd59e2669b18b8906914ad74e");
}
fn observedFileGenerator(value: []const u8) bool {
    return streamGenerator(value) or
        equal(value, "ed4aade60ba51fe013fa99a53f4e190d0958a54bb4be5a8811082bda99be5783");
}
fn fileGenerator(value: []const u8) bool {
    return observedFileGenerator(value) or equal(value, "5275665a3638480185984f0702b4248bc42ba8cb5a24428ea01a8eb1e6f0c550");
}

pub fn permitsLargeRawInput(a: A, projection: []const u8) A.Error!bool {
    // Called only after the ordinary 2 MiB raw-file limit rejected the input.
    // This selects a bounded transport envelope, never semantic acceptance.
    preflight(projection, true) catch return false;
    const parsed = std.json.parseFromSlice(FilesDocument, a, projection, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    const doc = parsed.value;
    return equal(doc.schema, "wikidict.figure-sizing-files.v1") and
        fileGenerator(doc.generator_sha256) and
        lowerHex(doc.core_revision, 40) and lowerHex(doc.namespace_registry_sha256, 64) and
        lowerHex(doc.raw_sha256, 64) and doc.records.len <= max_records and
        (if (doc.records.len == 0) doc.source_profile == .null else
            acceptedCore(doc.core_revision) and doc.source_profile == .object);
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
    if (value != .object or value.object.contains("error") or value.object.contains("errors") or value.object.contains("warnings")) return invalid;
    const query = try field(value, "query");
    const item = try field(query, "general");
    const remote = try string(item, "server");
    const bare = if (std.mem.startsWith(u8, remote, "https:")) remote[6..] else remote;
    if (!equal(try string(item, "wikiid"), wiki) or !equal(try string(item, "lang"), language) or (!acceptedCore(core) or !equal(try string(item, "git-hash"), core)) or !equal(bare, server)) return invalid;
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

fn profile(value: Value, site_bytes: []const u8) !void {
    if (value != .object or value.object.count() != profile_strings.len + 3) return invalid;
    for (profile_strings) |pair| if (!equal(try string(value, pair[0]), pair[1])) return invalid;
    const families = try field(value, "handler_families");
    if (families != .object or families.object.count() != handler_families.len) return invalid;
    for (handler_families) |family| {
        const item = try field(families, family.mime);
        if (item != .object or item.object.count() != 2 or
            !equal(try string(item, "handler_class"), family.handler_class) or
            !equal(try string(item, "mediatype"), family.mediatype)) return invalid;
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
const StreamBatches = struct {
    input: *StreamInput,
    backing: A,
    count: usize,
    base_count: usize,
    raw_sha256: []const u8,
    cursor: usize = 0,
    fn next(self: *StreamBatches, a: A) !RawFileBatch {
        if (self.cursor >= self.count) return invalid;
        const bytes = (try self.input.line(a, stream_batch_limit)) orelse return invalid;
        // The outer record has bounded depth independently of its quoted HTTP
        // response. The response itself uses the existing strict preflight.
        try preflightFileBatches(bytes);
        const batch = try std.json.parseFromSliceLeaky(RawFileBatch, a, bytes, .{ .allocate = .alloc_always });
        if ((batch.observed_svg_width_px != null) != (self.cursor >= self.base_count)) return invalid;
        self.cursor += 1;
        return batch;
    }
    fn finish(self: *StreamBatches) !void {
        if (self.cursor != self.count) return invalid;
        try self.input.finish(self.backing);
        if (!equal(&std.fmt.bytesToHex(self.input.digest.?, .lower), self.raw_sha256)) return invalid;
    }
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    namespace_catalog: *const namespaces.Registry,
    records: []const Record,
    file_authority: bool = false,
    // Build-only parallel proof, derived from validated file facts. It is not
    // accepted from either legacy or streamed serialized records.
    height_bound_records: []const bool = &.{},

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

    pub fn initStream(backing: A, projection: *StreamInput, raw: *StreamInput, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !Registry {
        try preflight(site, false);
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        var scratch = std.heap.ArenaAllocator.init(backing);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const header_bytes = (try projection.line(temp, stream_header_limit)) orelse return invalid;
        try preflight(header_bytes, false);
        const header_value = try std.json.parseFromSliceLeaky(Value, temp, header_bytes, .{});
        for ([_][]const u8{ "records_count", "base_batches", "observed_batches", "raw_bytes" }) |name|
            if (!nonnegativeInteger(try field(header_value, name))) return invalid;
        const header = try std.json.parseFromSliceLeaky(StreamHeader, a, header_bytes, .{ .allocate = .alloc_always });
        const count_u64 = std.math.add(u64, header.base_batches, header.observed_batches) catch return invalid;
        const max_requests = std.math.mul(u64, header.base_batches, 50) catch return invalid;
        // Counts are bounded by the authenticated physical inputs, not an
        // edition-size ceiling. Batch IDs remain the existing u32 wire field.
        if (!equal(header.schema, stream_schema) or !streamGenerator(header.generator_sha256) or
            header.raw_bytes != raw.size or header.records_count > projection.size or count_u64 > raw.size or
            count_u64 > std.math.maxInt(u32) or header.observed_batches > header.records_count or
            header.base_batches > header.records_count or header.records_count > max_requests) return invalid;
        const count = std.math.cast(usize, count_u64) orelse return invalid;
        const fact_count = std.math.cast(usize, header.records_count) orelse return invalid;
        const raw_header_bytes = (try raw.line(temp, stream_header_limit)) orelse return invalid;
        try preflight(raw_header_bytes, false);
        const raw_header_value = try std.json.parseFromSliceLeaky(Value, temp, raw_header_bytes, .{});
        for ([_][]const u8{ "records_count", "base_batches", "observed_batches" }) |name|
            if (!nonnegativeInteger(try field(raw_header_value, name))) return invalid;
        const raw_header = try std.json.parseFromSliceLeaky(RawStreamHeader, temp, raw_header_bytes, .{ .allocate = .alloc_always });
        if (header.records_count > projection.size - (@as(u64, header_bytes.len) + 1) or
            count_u64 > raw.size - (@as(u64, raw_header_bytes.len) + 1)) return invalid;
        if (!equal(raw_header.schema, raw_stream_schema) or !equal(raw_header.wiki, header.wiki) or
            !equal(raw_header.core_revision, header.core_revision) or !equal(raw_header.namespace_registry_sha256, header.namespace_registry_sha256) or
            raw_header.base_batches != header.base_batches or raw_header.observed_batches != header.observed_batches or
            raw_header.records_count != header.records_count) return invalid;
        const records = try a.alloc(FileFact, fact_count);
        for (records) |*record| {
            const bytes = (try projection.line(temp, stream_fact_limit)) orelse return invalid;
            try preflight(bytes, false);
            record.* = try std.json.parseFromSliceLeaky(FileFact, a, bytes, .{ .allocate = .alloc_always });
            _ = scratch.reset(.retain_capacity);
        }
        try projection.finish(temp);
        var batches: StreamBatches = .{ .input = raw, .backing = backing, .count = count,
            .base_count = std.math.cast(usize, header.base_batches) orelse return invalid, .raw_sha256 = header.raw_sha256 };
        return validateFileFacts(&arena, .{ .schema = "wikidict.figure-sizing-files.v1", .wiki = header.wiki,
            .content_language = header.content_language, .core_revision = header.core_revision,
            .namespace_registry_sha256 = header.namespace_registry_sha256, .raw_sha256 = header.raw_sha256,
            .generator_sha256 = header.generator_sha256, .source_profile = header.source_profile, .records = records },
            site, ns, source_core_revision, &batches);
    }

    fn initFileFacts(arena: *std.heap.ArenaAllocator, value: Value, raw: []const u8, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8) !Registry {
        const a = arena.allocator();
        try preflightFileBatches(raw);
        const doc = try std.json.parseFromValueLeaky(FilesDocument, a, value, .{});
        if (!observedFileGenerator(doc.generator_sha256)) {
            if (doc.records.len != 0 and !equal(doc.core_revision, accepted_core)) return invalid;
            for (doc.records) |fact| if (fact.observed_svg_width_px != null or fact.observed_batch != null) return invalid;
        }
        const batches = try std.json.parseFromSliceLeaky(RawFileBatches, a, raw, .{ .allocate = .alloc_always });
        if (!equal(batches.schema, "wikidict.figure-sizing-raw-batches.v1") or
            batches.batches.len > max_batches or doc.records.len > max_records or !digestMatches(raw, doc.raw_sha256)) return invalid;
        var input: ArrayBatches = .{ .items = batches.batches, .count = batches.batches.len };
        return validateFileFacts(arena, doc, site, ns, source_core_revision, &input);
    }

    fn validateFileFacts(arena: *std.heap.ArenaAllocator, doc: FilesDocument, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8, batches: anytype) !Registry {
        const a = arena.allocator();
        const registration = try std.json.parseFromSliceLeaky(Value, a, site, .{ .allocate = .alloc_always });
        const ns_digest = std.fmt.bytesToHex(ns.source_sha256, .lower);
        if (!equal(doc.wiki, ns.wiki) or !equal(doc.content_language, ns.content_language) or
            !lowerHex(doc.core_revision, 40) or !compatibleCore(source_core_revision orelse return invalid, doc.core_revision) or
            !equal(doc.namespace_registry_sha256, &ns_digest) or !fileGenerator(doc.generator_sha256) or
            !lowerHex(doc.generator_sha256, 64)) return invalid;
        if (doc.records.len == 0) {
            if (batches.count != 0 or doc.source_profile != .null) return invalid;
            const empty_query = try field(registration, "query");
            const empty_general = try field(empty_query, "general");
            if (!equal(try string(empty_general, "wikiid"), ns.wiki) or
                !equal(try string(empty_general, "lang"), ns.content_language) or
                !equal(try string(empty_general, "git-hash"), doc.core_revision)) return invalid;
            try batches.finish();
            return .{ .arena = arena.*, .namespace_catalog = ns, .records = &.{}, .file_authority = true };
        }
        if (!acceptedCore(doc.core_revision)) return invalid;
        try profile(doc.source_profile, site);
        const server = try officialServer(a, ns.wiki);
        const site_query = try general(registration, ns.wiki, ns.content_language, server, doc.core_revision);
        try mediaRegistration(site_query);
        if ((try timestamp(try string(registration, "curtimestamp"))).fraction.len != 0) return invalid;
        var facts: std.StringHashMapUnmanaged(*const FileFact) = .empty;
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
            facts.getPtr(name).?.* = fact;
        }
        var used_facts: std.StringHashMapUnmanaged(void) = .empty;
        var used_observations: std.StringHashMapUnmanaged(u32) = .empty;
        var canonical_facts: std.StringHashMapUnmanaged(*const FileFact) = .empty;
        var authorities: std.StringHashMapUnmanaged(Record) = .empty;
        var observing = false;
        for (0..batches.count) |batch_index| {
            var scratch = std.heap.ArenaAllocator.init(arena.child_allocator);
            defer scratch.deinit();
            const temp = scratch.allocator();
            const batch = try batches.next(temp);
            if (batch.requests.len == 0 or batch.requests.len > 50) return invalid;
            if (batch.observed_svg_width_px) |observed| {
                if (observed == 0) return invalid;
                observing = true;
            } else if (observing) return invalid;
            try preflight(batch.response, false);
            const source = try std.json.parseFromSliceLeaky(Value, temp, batch.response, .{ .allocate = .alloc_always });
            const query = try general(source, ns.wiki, ns.content_language, server, doc.core_revision);
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
            for (batch.requests) |requested| {
                const fact = facts.get(requested) orelse return invalid;
                if (batch.observed_svg_width_px != null) {
                    if ((fact.observed_batch orelse return invalid) != batch_index or !used_facts.contains(requested)) return invalid;
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
                    if (batch.observed_svg_width_px != null) return invalid;
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
                if (handlerFamily(fact.mime)) |family| {
                    if (!equal(family.mediatype, fact.mediatype)) return invalid;
                    if (equal(fact.mime, "image/tiff")) tiffPageAxes(temp, image, width, height) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => eligible = false,
                    };
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
                if (batch.observed_svg_width_px != null) continue;
                if (!eligible) continue;
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
            if (used_pages.count() != by_title.count()) return invalid;
        }
        try batches.finish();
        if (used_facts.count() != facts.count()) return invalid;
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
        const height_bounds = try a.alloc(bool, records.items.len);
        for (records.items, height_bounds) |record, *bound| {
            const fact = facts.get(record.canonical_file) orelse canonical_facts.get(record.canonical_file) orelse return invalid;
            // PNG/JPEG use the authenticated ImageHandler bitmap fit contract.
            // SVG's configured maximum and paged TIFF remain outside this grant.
            bound.* = fact.state == .eligible and equal(fact.mediatype, "BITMAP") and
                (equal(fact.mime, "image/png") or equal(fact.mime, "image/jpeg"));
        }
        return .{ .arena = arena.*, .namespace_catalog = ns, .records = records.items,
            .file_authority = true, .height_bound_records = height_bounds };
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
        if (lo < self.records.len and lo < self.height_bound_records.len and self.height_bound_records[lo] and
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
            if (height != null and (!self.file_authority or lo >= self.height_bound_records.len or !self.height_bound_records[lo])) return null;
            if (equal(record.canonical_file, canonical) and
                (if (self.file_authority) (width.? <= record.original_width or
                    (equal(record.proof_kind, "file-svg-observed-thumbnail-width") and width.? == record.width_px)) else record.width_px == width.?)) return record.sizing;
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
    for ([_]u32{ 1, 103, 250 }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]?u32{ null, 0, 104, 249, 251, 500, std.math.maxInt(u32) }) |width|
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
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&family_registry, a, TestSource.file, .thumbnail, 251, null));
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
        for (batches) |batch| if (batch.observed_svg_width_px != null) { observed += 1; };
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
    for ([_]u32{ 1, 103, 250 }) |width|
        try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, width, null));
    for ([_]u32{ 104, 249, 251, 500 }) |width|
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
            var registry = try StreamTestSource.init(a, input, ns, 37); defer registry.deinit();
            try std.testing.expectEqual(@as(?types.FigureSizingPolicy, .requested_fit), try Registry.resolve(&registry, a, TestSource.file, .thumbnail, 250, null));
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
    const input = try ObservedSvgTestSource.make(arena.allocator(), &ns, 0);
    const streamed = try StreamTestSource.convert(arena.allocator(), input);
    try std.testing.checkAllAllocationFailures(a, Check.replay, .{ streamed, &ns });
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
    const old_projection = try TestSource.projection(arena.allocator(), &ns, TestSource.raw, TestSource.site);
    var old_registry = try Registry.init(a, old_projection, TestSource.raw, TestSource.site, &ns, accepted_core, generator_sha256); defer old_registry.deinit();
    try std.testing.expectEqual(@as(?u32, null), try Registry.resolveHeightOnlyWidth(&old_registry, a, TestSource.file, .thumbnail, 200));
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
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, 249, null));
                try std.testing.expectEqual(@as(?types.FigureSizingPolicy, null), try Registry.resolve(&registry, a, name, .thumbnail, 251, null));
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
            var registry = try StreamTestSource.init(a, input, ns, 37); defer registry.deinit();
            try std.testing.expectEqual(@as(usize, 4), registry.records.len);
        }
    };
    const a = std.testing.allocator;
    var ns = try TestSource.namespace(a); defer ns.deinit();
    var source = std.heap.ArenaAllocator.init(a); defer source.deinit();
    const input = try ObservedSvgBatchTestSource.make(source.allocator(), &ns, 2, .valid);
    const streamed = try StreamTestSource.convert(source.allocator(), input);
    try std.testing.checkAllAllocationFailures(a, Check.replay, .{ streamed, &ns });
}
