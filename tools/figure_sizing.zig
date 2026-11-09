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
fn general(value: Value, wiki: []const u8, language: []const u8, server: []const u8) !Value {
    if (value != .object or value.object.contains("error") or value.object.contains("errors") or value.object.contains("warnings")) return invalid;
    const query = try field(value, "query");
    const item = try field(query, "general");
    const remote = try string(item, "server");
    const bare = if (std.mem.startsWith(u8, remote, "https:")) remote[6..] else remote;
    if (!equal(try string(item, "wikiid"), wiki) or !equal(try string(item, "lang"), language) or !equal(try string(item, "git-hash"), accepted_core) or !equal(bare, server)) return invalid;
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

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    namespace_catalog: *const namespaces.Registry,
    records: []const Record,

    pub fn init(backing: A, projection: []const u8, raw: []const u8, site: []const u8, ns: *const namespaces.Registry, source_core_revision: ?[]const u8, expected_generator: []const u8) !Registry {
        try preflight(projection, true); try preflight(raw, false); try preflight(site, false);
        var arena = std.heap.ArenaAllocator.init(backing); errdefer arena.deinit(); const a = arena.allocator();
        // All retained strings and records belong to this registry's arena;
        // no temporary Parsed arena is destroyed underneath the callback.
        const projection_value = try std.json.parseFromSliceLeaky(Value, a, projection, .{ .allocate = .alloc_always });
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
        const query = try general(source, ns.wiki, ns.content_language, server);
        const site_query = try general(registration, ns.wiki, ns.content_language, server);
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
    pub fn deinit(self: *Registry) void { self.arena.deinit(); self.* = undefined; }
    pub fn resolve(raw: ?*const anyopaque, a: A, file: []const u8, format_value: types.FigureFormat, width: ?u32, height: ?u32) A.Error!?types.FigureSizingPolicy {
        const self: *const Registry = @ptrCast(@alignCast(raw orelse return null));
        if (format_value != .thumbnail or width == null or height != null) return null;
        const canonical = canonicalFile(a, self.namespace_catalog, file) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return null };
        defer a.free(canonical);
        var lo: usize = 0; var hi = self.records.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const record = self.records[mid];
            const order = std.mem.order(u8, record.canonical_file, canonical);
            if (order == .lt or (order == .eq and record.width_px < width.?)) lo = mid + 1 else hi = mid;
        }
        if (lo < self.records.len) {
            const record = self.records[lo];
            if (record.width_px == width.? and equal(record.canonical_file, canonical)) return record.sizing;
        }
        return null;
    }
};

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
