//! Build-only direct GET transport and exact current-prefix authority.
//! No metadata language policy, source/body equivalence or layout is issued.
const std = @import("std");
const namespaces = @import("namespace_registry");
const prefix_parser = @import("page_language_prefix.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const invalid = error.InvalidPageLanguageSource;
pub const max_payload_bytes = 64 * 1024 * 1024;
pub const Page = struct {
    id: u64,
    revision: u64,
    namespace: i32,
    title: []const u8,
    model: []const u8,
    raw_sha256: []const u8,
    // Optional capture evidence. Ordinary metadata acquisition has no expanded
    // output; absence must never satisfy capturedSourceMatches.
    expanded_sha256: ?[]const u8 = null,
};

fn directKeys(value: V, keys: []const []const u8) !void {
    if (value != .object or value.object.count() != keys.len) return invalid;
    for (keys) |key| if (!value.object.contains(key)) return invalid;
}
fn directDescriptor(value: V) !void {
    try directKeys(value, &.{ "bytes", "path", "sha256" });
    const size = try integer(value, "bytes");
    const path = try str(value, "path");
    if (size <= 0 or size > max_payload_bytes or !lowerHash(try str(value, "sha256")) or
        path.len == 0 or path.len > 4096 or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return invalid;
}
pub fn directTimestamp(value: []const u8) bool {
    if (value.len < 20 or value.len > 35) return false;
    const suffix: usize = if (std.mem.endsWith(u8, value, "+00:00")) 6 else if (std.mem.endsWith(u8, value, "Z")) 1 else return false;
    const end = value.len - suffix;
    if (end < 19) return false;
    if (end > 19) {
        if (value[19] != '.' or end == 20 or end > 29) return false;
        for (value[20..end]) |byte| if (!std.ascii.isDigit(byte)) return false;
    }
    var whole: [20]u8 = undefined;
    @memcpy(whole[0..19], value[0..19]); whole[19] = 'Z';
    return utc(&whole);
}
fn directNonnegativeNumber(value: V, key: []const u8, positive: bool) !void {
    const field_value = try field(value, key);
    const amount: f64 = switch (field_value) { .float => field_value.float, .integer => @floatFromInt(field_value.integer), else => return invalid };
    if (!std.math.isFinite(amount) or amount < 0 or (positive and amount == 0)) return invalid;
}
fn directCompleteAcquisition(source: V) !void {
    try directKeys(source, &.{ "accept_encoding", "accepted", "bytes", "content_encoding", "encoded", "file", "final_url", "headers",
        "request_count", "response_complete", "retrieved_utc", "sha256", "source_path", "status", "unknown_response_outcome", "url", "user_agent" });
    if (!eq(try str(source, "accept_encoding"), "gzip") or !eq(try str(source, "content_encoding"), "gzip") or
        !eq(try str(try field(source, "headers"), "content-encoding"), "gzip") or
        !eq(try str(source, "user_agent"), "Wikidict/1.0 (https://github.com/SmallThingz/wikidict)")) return invalid;
    try directDescriptor(try field(source, "encoded"));
}
fn directSavedAcquisition(receipt: V) !void {
    try directKeys(receipt, &.{ "accepted", "compressed_stream_complete", "detail", "elapsed_seconds", "encoded_received_bytes", "encoded_received_sha256",
        "ended_utc", "error", "final_url", "headers", "input_data", "mode", "redirects", "request_count", "response_bytes", "response_sha256",
        "same_response_core_observed", "socket_buffering_measured", "started_unix", "started_utc", "status", "url" });
    if (!eq(try str(receipt, "error"), "AssertionError") or !eq(try str(receipt, "detail"), "Unknown configuration prelude") or
        !directTimestamp(try str(receipt, "started_utc")) or !directTimestamp(try str(receipt, "ended_utc"))) return invalid;
    try directDescriptor(try field(receipt, "input_data"));
    try directNonnegativeNumber(receipt, "elapsed_seconds", false);
    try directNonnegativeNumber(receipt, "started_unix", true);
    try directFlag(receipt, "same_response_core_observed", false);
    try directFlag(receipt, "socket_buffering_measured", false);
}

pub fn Context(comptime Styles: type) type {
    return struct {
    profile: []const u8,
    page: Page,
    mode: enum { @"historical-oldid", @"current-canonical" },
    response_kind: enum { @"complete-response", @"saved-gzip-prefix" },
    response: []const u8,
    prefix: []const u8,
    receipt: []const u8,
    styles: Styles,
    original_received_prefix: ?[]const u8 = null,
    encoded_gzip_base64: ?[]const u8 = null,
    };
}
fn directFlag(v: V, key: []const u8, expected: bool) !void {
    const actual = try field(v, key);
    if (actual != .bool or actual.bool != expected) return invalid;
}
fn validPage(page: Page) bool {
    return page.id != 0 and page.revision != 0 and page.namespace >= 0 and eq(page.model, "wikitext") and
        page.title.len != 0 and std.mem.indexOfAny(u8, page.title, "\x00\r\n\t") == null and
        lowerHash(page.raw_sha256) and lowerHash(page.expanded_sha256 orelse return false);
}
fn directDocumentUrl(a: A, ns: *const namespaces.Registry, record: anytype, url: []const u8) !void {
    if (!std.mem.endsWith(u8, ns.wiki, "wiktionary")) return invalid;
    const edition = ns.wiki[0 .. ns.wiki.len - "wiktionary".len];
    const host = try a.dupe(u8, edition);
    if (host.len == 0) return invalid;
    for (host) |*c| {
        if (c.* == '_') c.* = '-' else if (!std.ascii.isLower(c.*) and !std.ascii.isDigit(c.*) and c.* != '-') return invalid;
    }
    const canonical = try canonicalCurrentUrl(a, host, record.page.title);
    if (record.mode == .@"current-canonical") {
        if (!eq(url, canonical)) return invalid;
    } else {
        const marker = "/wiki/";
        const at = std.mem.indexOf(u8, canonical, marker) orelse return invalid;
        const oldid = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/index.php?oldid={d}", .{ host, record.page.revision });
        const named = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/index.php?title={s}&oldid={d}&useskin=vector-2022", .{ host, canonical[at + marker.len ..], record.page.revision });
        if (!eq(url, oldid) and !eq(url, named)) return invalid;
    }
}
const Transport = struct { url: []const u8, observation: prefix_parser.Observation };
pub fn validateTransport(a: A, ns: *const namespaces.Registry, record: anytype) ![]const u8 {
    if (record.page.namespace != 0) return invalid;
    return (try validateDocumentTransport(a, ns, record)).url;
}

pub fn validatePageLanguageTransport(a: A, ns: *const namespaces.Registry, record: anytype) !Transport {
    if (record.page.namespace != 0 and (record.styles.responses.len != 0 or record.styles.receipt.len != 0)) return invalid;
    return validateDocumentTransport(a, ns, record);
}

fn validateDocumentTransport(a: A, ns: *const namespaces.Registry, record: anytype) !Transport {
    if (!eq(record.profile, "source-parent-direct-get-v1") or !validPage(record.page) or
        record.response.len == 0 or record.response.len > 2 * 1024 * 1024 or
        record.prefix.len == 0 or record.prefix.len > 512 * 1024 or !std.mem.startsWith(u8, record.response, record.prefix) or
        !std.unicode.utf8ValidateSlice(record.response) or std.mem.indexOfScalar(u8, record.response, 0) != null) return invalid;
    const receipt = try parse(a, record.receipt);
    var url: []const u8 = undefined;
    if (record.response_kind == .@"complete-response") {
        if (record.original_received_prefix != null or record.encoded_gzip_base64 != null or receipt != .object or
            (receipt.object.count() != 2 and receipt.object.count() != 4) or try field(receipt, "core") != .null) return invalid;
        const sources = try field(receipt, "sources");
        if (sources != .array or sources.array.items.len != 1) return invalid;
        const source = sources.array.items[0];
        if (source != .object) return invalid;
        if (receipt.object.count() == 2) {
            // The retained historical acquisition has no invented accepted or
            // response_complete flags. Its original legacy shape is distinct.
            if (record.mode != .@"historical-oldid" or source.object.count() != 9) return invalid;
        } else {
            const unrequested = try field(receipt, "unrequested");
            if (unrequested != .array or unrequested.array.items.len != 0 or source.object.count() != 17) return invalid;
            try directCompleteAcquisition(source);
            try directFlag(receipt, "historical_equality_proven", false);
            try directFlag(source, "accepted", true);
            try directFlag(source, "response_complete", true);
            try directFlag(source, "unknown_response_outcome", false);
            if (try integer(source, "request_count") != 1) return invalid;
        }
        if (try integer(source, "bytes") != record.response.len or !matches(record.response, try str(source, "sha256")) or
            try integer(source, "status") != 200 or (try str(source, "file")).len == 0 or
            (try str(source, "source_path")).len == 0 or !directTimestamp(try str(source, "retrieved_utc")) or
            !eq(try str(try field(source, "headers"), "content-type"), "text/html; charset=UTF-8")) return invalid;
        url = try str(source, "url");
        if (!eq(url, try str(source, "final_url"))) return invalid;
    } else {
        // Same retained-gzip proof as current_get_literal: keep the original
        // false prefix receipt, then independently prove EOF/CRC/size and the
        // exact original received prefix. No HTTP receipt is rewritten.
        if (record.mode != .@"current-canonical" or receipt != .object or receipt.object.count() != 22) return invalid;
        try directSavedAcquisition(receipt);
        const received = record.original_received_prefix orelse return invalid;
        const encoded_text = record.encoded_gzip_base64 orelse return invalid;
        if (received.len == 0 or received.len > 512 * 1024 or received.len >= record.response.len or
            !std.mem.startsWith(u8, record.response, received) or encoded_text.len == 0 or encoded_text.len > 4 * 256 * 1024 / 3 + 4) return invalid;
        const decoder = std.base64.standard.Decoder;
        const count = decoder.calcSizeForSlice(encoded_text) catch return invalid;
        if (count < 18 or count > 256 * 1024) return invalid;
        const encoded = try a.alloc(u8, count);
        decoder.decode(encoded, encoded_text) catch return invalid;
        if (!eq(encoded[0..4], "\x1f\x8b\x08\x00") or try integer(receipt, "encoded_received_bytes") != encoded.len or
            !matches(encoded, try str(receipt, "encoded_received_sha256")) or
            try integer(receipt, "response_bytes") != received.len or !matches(received, try str(receipt, "response_sha256")) or
            try integer(receipt, "request_count") != 1 or try integer(receipt, "status") != 200 or
            !eq(try str(receipt, "mode"), "current-canonical") or
            !eq(try str(try field(receipt, "headers"), "content-encoding"), "gzip") or
            !eq(try str(try field(receipt, "headers"), "content-type"), "text/html; charset=UTF-8")) return invalid;
        try directFlag(receipt, "accepted", false);
        try directFlag(receipt, "compressed_stream_complete", false);
        try directFlag(receipt, "redirects", false);
        var input: std.Io.Reader = .fixed(encoded);
        var inflater: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
        const full = inflater.reader.allocRemaining(a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, else => return invalid,
        };
        if (inflater.err != null or inflater.state != .end or input.seek != encoded.len or
            inflater.container_metadata.gzip.count != full.len or inflater.container_metadata.gzip.crc != std.hash.Crc32.hash(full) or
            !eq(full, record.response)) return invalid;
        url = try str(receipt, "url");
        if (!eq(url, try str(receipt, "final_url"))) return invalid;
    }
    try directDocumentUrl(a, ns, record, url);
    // Both URL modes initially require selected revision == retained current
    // revision. historical-oldid names the acquisition URL, not historical
    // rendering equivalence. This uses the held HU parser API explicitly.
    const page = record.page;
    const observation = if (page.namespace == 0)
        try prefix_parser.parseCurrentAlloc(a, record.prefix, page.id, page.revision, page.title)
    else observed: {
        if (record.mode != .@"current-canonical" or record.response_kind != .@"complete-response") return invalid;
        const spec = ns.storedPageSpec(page.title, page.namespace) catch return invalid;
        const local_title = ns.ofTitle(page.title).text;
        if (spec.role == .compile_only or local_title.len == 0) return invalid;
        break :observed try prefix_parser.parseNamespacedCurrentAlloc(a, record.prefix, page.id,
            page.revision, page.namespace, page.title, local_title);
    };
    return .{ .url = url, .observation = observation };
}


fn eq(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }

fn field(v: V, key: []const u8) !V {
    if (v != .object) return invalid;
    return v.object.get(key) orelse return invalid;
}

fn str(v: V, key: []const u8) ![]const u8 {
    const x = try field(v, key);
    if (x != .string) return invalid;
    return x.string;
}

fn integer(v: V, key: []const u8) !i64 {
    const x = try field(v, key);
    if (x != .integer) return invalid;
    return x.integer;
}

fn lowerHash(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

fn digest(bytes: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

fn matches(bytes: []const u8, hash: []const u8) bool { return eq(&digest(bytes), hash); }

fn bounded(bytes: []const u8, limit: usize) !void {
    if (bytes.len == 0 or bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes)) return invalid;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) { escaped = false; continue; }
            if (c == '\\') escaped = true else if (c == '"') quoted = false;
            continue;
        }
        switch (c) {
            '"' => quoted = true,
            '{', '[' => { depth += 1; if (depth > 16) return invalid; },
            '}', ']' => { if (depth == 0) return invalid; depth -= 1; },
            else => {},
        }
    }
    if (quoted or escaped or depth != 0) return invalid;
}

fn parse(a: A, bytes: []const u8) !V {
    return parseLimited(a, bytes, 64 * 1024);
}

fn parseLimited(a: A, bytes: []const u8, limit: usize) !V {
    try bounded(bytes, limit);
    return std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid,
    };
}

fn utc(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return false;
    const ranges = [_][2]usize{ .{0,4}, .{5,7}, .{8,10}, .{11,13}, .{14,16}, .{17,19} };
    var n: [6]u32 = undefined;
    for (ranges, 0..) |r, i| {
        for (value[r[0]..r[1]]) |c| if (!std.ascii.isDigit(c)) return false;
        n[i] = std.fmt.parseInt(u32, value[r[0]..r[1]], 10) catch return false;
    }
    if (n[0] == 0 or n[1] == 0 or n[1] > 12 or n[2] == 0 or n[3] > 23 or n[4] > 59 or n[5] > 59) return false;
    const days = [_]u32{31,28,31,30,31,30,31,31,30,31,30,31};
    const leap = n[1] == 2 and n[0] % 4 == 0 and (n[0] % 100 != 0 or n[0] % 400 == 0);
    return n[2] <= days[n[1] - 1] + @as(u32, if (leap) 1 else 0);
}
// Exact same-core source chain. The admitted language set is deliberately the
// single proven trivial-converter/html-code case; other converters stay unknown.

pub fn canonicalCurrentUrl(a: A, host: []const u8, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "https://"); try out.appendSlice(a, host); try out.appendSlice(a, ".wiktionary.org/wiki/");
    const hex = "0123456789ABCDEF";
    for (title) |byte| {
        if (byte == ' ') try out.append(a, '_')
        else if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/:", byte) != null) try out.append(a, byte)
        else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return out.toOwnedSlice(a);
}


pub fn validateCompleteCssSource(source: V) !void {
    try directKeys(source, &.{ "accept_encoding", "accepted", "bytes", "content_encoding", "encoded", "file", "final_url", "headers",
        "request_count", "response_complete", "retrieved_utc", "sha256", "source_path", "status", "unknown_response_outcome", "url", "user_agent" });
    if (!eq(try str(source, "accept_encoding"), "gzip") or
        !eq(try str(source, "user_agent"), "Wikidict/1.0 (https://github.com/SmallThingz/wikidict)")) return invalid;
    const encoding = try str(source, "content_encoding");
    if (eq(encoding, "gzip")) {
        try directCompleteAcquisition(source);
    } else if (eq(encoding, "identity")) {
        if (try field(source, "encoded") != .null) return invalid;
        const headers = try field(source, "headers");
        if (headers != .object) return invalid;
        if (headers.object.get("content-encoding")) |value| {
            if (value != .string or !eq(value.string, "identity")) return invalid;
        }
    } else return invalid;
    try directFlag(source, "accepted", true); try directFlag(source, "response_complete", true);
    try directFlag(source, "unknown_response_outcome", false);
    if (try integer(source, "status") != 200 or try integer(source, "request_count") != 1 or
        !directTimestamp(try str(source, "retrieved_utc")) or (try str(source, "file")).len == 0) return invalid;
}
