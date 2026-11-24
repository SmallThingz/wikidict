//! Immutable site constants captured alongside the namespace registry.
const std = @import("std");
const A = std.mem.Allocator;
const max_bytes = 2 * 1024 * 1024;

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidSiteInfoSnapshot;
    return value.object.get(name) orelse error.InvalidSiteInfoSnapshot;
}

fn string(value: std.json.Value, name: []const u8) ![]const u8 {
    const result = try field(value, name);
    if (result != .string) return error.InvalidSiteInfoSnapshot;
    return result.string;
}

// The capture validator admits ASCII DNS authorities (including punycode) with
// an optional port. Preserve their bytes, including protocol-relative URLs.
fn validServer(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |c| if (c > 127) return false;
    const authority = if (std.mem.startsWith(u8, value, "//"))
        value[2..]
    else if (std.mem.startsWith(u8, value, "https://"))
        value[8..]
    else if (std.mem.startsWith(u8, value, "http://"))
        value[7..]
    else
        return false;
    if (authority.len == 0) return false;
    for (authority) |c| if (c <= 32 or c == 127 or std.mem.indexOfScalar(u8, "/?#@\\", c) != null) return false;
    const host = if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| blk: {
        const port = authority[colon + 1 ..];
        if (port.len == 0 or port.len > 5) return false;
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
        if ((std.fmt.parseInt(u16, port, 10) catch return false) == 0) return false;
        break :blk authority[0..colon];
    } else authority;
    const hostname = if (std.mem.endsWith(u8, host, ".")) host[0 .. host.len - 1] else host;
    if (hostname.len == 0 or hostname.len > 253) return false;
    var labels = std.mem.splitScalar(u8, hostname, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

// Captured scalar contract: Scribunto SiteLibrary::loadStats at
// b109cb6e5866c13871e308859ef78249b1bd3ea2. views is absent upstream.
// Fixed order shared by the provider ABI: pages, articles, files, edits,
// users, activeUsers, admins. A primitive array crosses independently built
// Lua modules without importing files outside their module roots.
pub const Statistics = [7]u53;

fn counter(value: std.json.Value, name: []const u8) !u53 {
    const raw = try field(value, name);
    if (raw != .integer) return error.InvalidSiteInfoSnapshot;
    return std.math.cast(u53, raw.integer) orelse error.InvalidSiteInfoSnapshot;
}

pub const Snapshot = struct {
    allocator: A,
    server: []const u8,
    script: ?[]const u8,
    article_path: ?[]const u8,
    statistics: ?Statistics = null,
    language_conversion_enabled: ?bool = null,

    fn urlPath(general: std.json.Value, name: []const u8, article: bool) !?[]const u8 {
        const value = general.object.get(name) orelse return null;
        if (value != .string) return error.InvalidSiteInfoSnapshot;
        const path = value.string;
        if (path.len == 0 or path.len > 4096 or path[0] != '/' or std.mem.startsWith(u8, path, "//")) return error.InvalidSiteInfoSnapshot;
        for (path) |c| if (c <= 32 or c == 127 or c == '\\' or c == '#') return error.InvalidSiteInfoSnapshot;
        if (article) {
            if (std.mem.count(u8, path, "$1") != 1) return error.InvalidSiteInfoSnapshot;
        } else if (std.mem.indexOfAny(u8, path, "?$")) |_| return error.InvalidSiteInfoSnapshot;
        return path;
    }

    pub fn init(a: A, bytes: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !Snapshot {
        if (bytes.len > max_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSiteInfoSnapshot;
        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidSiteInfoSnapshot,
        };
        defer parsed.deinit();
        const query = try field(parsed.value, "query");
        const general = try field(query, "general");
        var statistics: ?Statistics = null;
        if (parsed.value.object.get("schema")) |schema| {
            if (schema != .string or !std.mem.eql(u8, schema.string, "wikidict.site-info.v2") or
                !std.mem.eql(u8, try string(parsed.value, "profile"), "general-and-seven-scribunto-statistics") or
                !std.mem.eql(u8, try string(parsed.value, "temporal_scope"), "current-api-observation"))
                return error.InvalidSiteInfoSnapshot;
            if (!std.mem.eql(u8, try string(parsed.value, "wiki"), wiki) or
                !std.mem.eql(u8, try string(parsed.value, "date"), date) or
                !std.mem.eql(u8, try string(parsed.value, "content_language"), language))
                return error.SiteInfoIdentityMismatch;
            const counts = try field(query, "statistics");
            statistics = .{ try counter(counts, "pages"), try counter(counts, "articles"), try counter(counts, "images"), try counter(counts, "edits"), try counter(counts, "users"), try counter(counts, "activeusers"), try counter(counts, "admins") };
        }
        if (!std.mem.eql(u8, try string(general, "wikiid"), wiki) or !std.mem.eql(u8, try string(general, "lang"), language))
            return error.SiteInfoIdentityMismatch;
        const language_conversion_enabled: ?bool = if (general.object.get("langconversion")) |value| enabled: {
            if (value != .bool) return error.InvalidSiteInfoSnapshot;
            break :enabled value.bool;
        } else null;
        const server = try string(general, "server");
        if (!validServer(server)) return error.InvalidSiteInfoSnapshot;
        const script = try urlPath(general, "script", false);
        const article_path = try urlPath(general, "articlepath", true);
        const owned_server = try a.dupe(u8, server);
        errdefer a.free(owned_server);
        const owned_script = if (script) |value| try a.dupe(u8, value) else null;
        errdefer if (owned_script) |value| a.free(value);
        return .{ .allocator = a, .server = owned_server, .script = owned_script, .article_path = if (article_path) |value| try a.dupe(u8, value) else null, .statistics = statistics, .language_conversion_enabled = language_conversion_enabled };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.server);
        if (self.script) |value| self.allocator.free(value);
        if (self.article_path) |value| self.allocator.free(value);
        self.server = "";
        self.script = null;
        self.article_path = null;
        self.statistics = null;
    }
};

const test_raw = "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\",\"script\":\"/w/index.php\",\"articlepath\":\"/wiki/$1\"}}}";

test "site info preserves exact captured server independently of JSON storage" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8, test_raw);
    defer a.free(input);
    var snapshot = try Snapshot.init(a, input, "arwiktionary", "20261001", "ar");
    defer snapshot.deinit();
    @memset(input, 'x');
    try std.testing.expectEqualStrings("//ar.wiktionary.org", snapshot.server);
    try std.testing.expectEqualStrings("/w/index.php", snapshot.script.?);
    try std.testing.expectEqualStrings("/wiki/$1", snapshot.article_path.?);
    var norwegian = try Snapshot.init(a, "{\"query\":{\"general\":{\"wikiid\":\"nowiktionary\",\"lang\":\"nb\",\"server\":\"//no.wiktionary.org\"}}}", "nowiktionary", "20261001", "nb");
    defer norwegian.deinit();
    try std.testing.expectEqualStrings("//no.wiktionary.org", norwegian.server);
}

test "site info rejects absent duplicate invalid and cross-edition metadata" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{}",                                                                                      "[]",                                                                                                            "{\"query\":null}",                                                                                  "{\"query\":{\"general\":{}}}",
        "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":null}}}", "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//a\",\"server\":\"//b\"}}}", "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//bad/path\"}}}", "\xff",
    }) |raw| try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, raw, "arwiktionary", "20261001", "ar"));
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Snapshot.init(a, test_raw, "enwiktionary", "20261001", "ar"));
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Snapshot.init(a, test_raw, "arwiktionary", "20261001", "en"));
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, oversized, "arwiktionary", "20261001", "ar"));
}

test "site info supported server authorities retain exact spelling" {
    for ([_][]const u8{ "//ar.wiktionary.org", "https://HOST.Example.:443", "http://localhost:8080", "//xn--example-9d0b.org", "//a:00001" }) |value|
        try std.testing.expect(validServer(value));
    for ([_][]const u8{ "", "ar.wiktionary.org", "ftp://host", "//", "//a/path", "//a?q", "//a#f", "//user@host", "//a\\b", "//a\n", "//a\x7f", "//é.org", "//[::1]", "//a:", "//a:0", "//a:65536", "//a:000001", "//-a", "//a-", "//a..b", "//a_b" }) |value|
        try std.testing.expect(!validServer(value));
}

test "site info allocation failures preserve OutOfMemory and release parser storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn load(a: A) !void {
            var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
            var snapshot = try Snapshot.init(no_resize.allocator(), test_raw, "arwiktionary", "20261001", "ar");
            defer snapshot.deinit();
        }
    }.load, .{});
}

test "site info URL path configuration is captured or explicitly absent" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "\"script\":\"//other.example/path\"",
        "\"script\":\"/w/index.php?extra\"",
        "\"articlepath\":\"/wiki/no-title\"",
        "\"articlepath\":\"/wiki/$1/$1\"",
        "\"articlepath\":null",
    }) |extra| {
        const raw = try std.fmt.allocPrint(a, "{{\"query\":{{\"general\":{{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\",{s}}}}}}}", .{extra});
        defer a.free(raw);
        try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, raw, "arwiktionary", "20261001", "ar"));
    }
    var missing = try Snapshot.init(a, "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\"}}}", "arwiktionary", "20261001", "ar");
    defer missing.deinit();
    try std.testing.expect(missing.script == null and missing.article_path == null);
}

const test_stats_prefix =
    "{\"schema\":\"wikidict.site-info.v2\",\"profile\":\"general-and-seven-scribunto-statistics\",\"temporal_scope\":\"current-api-observation\"," ++
    "\"wiki\":\"bclwiktionary\",\"date\":\"20261001\",\"content_language\":\"bcl\",\"query\":{\"general\":{" ++
    "\"wikiid\":\"bclwiktionary\",\"lang\":\"bcl\",\"server\":\"//bcl.wiktionary.org\"},\"statistics\":{" ++
    "\"pages\":13332,\"articles\":8530,\"images\":0,\"edits\":60889,\"users\":1596,\"activeusers\":14,\"admins\":";

test "versioned site info binds date and complete seven-counter current profile" {
    const a = std.testing.allocator;
    var snapshot = try Snapshot.init(a, test_stats_prefix ++ "2}}}", "bclwiktionary", "20261001", "bcl");
    defer snapshot.deinit();
    const statistics = snapshot.statistics.?;
    try std.testing.expectEqual(@as(u53, 13332), statistics[0]);
    try std.testing.expectEqual(@as(u53, 8530), statistics[1]);
    try std.testing.expectEqual(@as(u53, 0), statistics[2]);
    try std.testing.expectEqual(@as(u53, 60889), statistics[3]);
    try std.testing.expectEqual(@as(u53, 1596), statistics[4]);
    try std.testing.expectEqual(@as(u53, 14), statistics[5]);
    try std.testing.expectEqual(@as(u53, 2), statistics[6]);
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Snapshot.init(a, test_stats_prefix ++ "2}}}", "bclwiktionary", "20261002", "bcl"));
    for ([_][]const u8{ "null", "true", "-1", "1.5", "\"2\"", "9007199254740992" }) |bad| {
        const raw = try std.mem.concat(a, u8, &.{ test_stats_prefix, bad, "}}}" });
        defer a.free(raw);
        try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, raw, "bclwiktionary", "20261001", "bcl"));
    }
    var legacy = try Snapshot.init(a, test_raw, "arwiktionary", "20261001", "ar");
    defer legacy.deinit();
    try std.testing.expect(legacy.statistics == null);
    try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, "{\"schema\":\"unknown\",\"query\":{\"general\":{}}}", "arwiktionary", "20261001", "ar"));
}

/// Exact content-language formatting observations for the seven pinned site-info
/// values. This is not a general locale formatter and never reads live counts.
pub const FormattedStatistics = struct {
    arena: std.heap.ArenaAllocator,
    values: [7][]const u8,

    pub fn init(a: A, bytes: []const u8, site_bytes: []const u8, namespace_sha256: [32]u8, wiki: []const u8, date: []const u8, language: []const u8) !FormattedStatistics {
        if (bytes.len > 16 * 1024 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSiteStatisticsFormatSnapshot;
        var site = try Snapshot.init(a, site_bytes, wiki, date, language);
        defer site.deinit();
        const counts = site.statistics orelse return error.InvalidSiteStatisticsFormatSnapshot;
        const parsed_site = try std.json.parseFromSlice(std.json.Value, a, site_bytes, .{ .duplicate_field_behavior = .@"error" });
        defer parsed_site.deinit();
        if (!std.mem.eql(u8, try string(parsed_site.value, "namespace_registry_sha256"), &std.fmt.bytesToHex(namespace_sha256, .lower)))
            return error.SiteStatisticsFormatIdentityMismatch;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, owned, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidSiteStatisticsFormatSnapshot,
        };
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object or value.object.count() != 7 or
            !std.mem.eql(u8, try string(value, "schema"), "wikidict.site-statistics-format.v1"))
            return error.InvalidSiteStatisticsFormatSnapshot;
        if (!std.mem.eql(u8, try string(value, "wiki"), wiki) or
            !std.mem.eql(u8, try string(value, "date"), date) or
            !std.mem.eql(u8, try string(value, "content_language"), language))
            return error.SiteStatisticsFormatIdentityMismatch;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(site_bytes, &digest, .{});
        if (!std.mem.eql(u8, try string(value, "site_info_sha256"), &std.fmt.bytesToHex(digest, .lower)) or
            !std.mem.eql(u8, try string(value, "namespace_registry_sha256"), &std.fmt.bytesToHex(namespace_sha256, .lower)))
            return error.SiteStatisticsFormatIdentityMismatch;
        const rows = try field(value, "values");
        if (rows != .array or rows.array.items.len != 7) return error.InvalidSiteStatisticsFormatSnapshot;
        var values: [7][]const u8 = undefined;
        const keys = [_][]const u8{ "pages", "articles", "images", "edits", "users", "activeusers", "admins" };
        for (rows.array.items, keys, counts, 0..) |row, key, count, i| {
            if (row != .object or row.object.count() != 3 or !std.mem.eql(u8, try string(row, "key"), key))
                return error.InvalidSiteStatisticsFormatSnapshot;
            const raw = try std.fmt.allocPrint(owned, "{d}", .{count});
            if (!std.mem.eql(u8, try string(row, "raw"), raw)) return error.SiteStatisticsFormatIdentityMismatch;
            const formatted = try string(row, "formatted");
            if (formatted.len == 0 or formatted.len > 256 or !std.unicode.utf8ValidateSlice(formatted) or
                std.mem.indexOfAny(u8, formatted, "<>{}|[]") != null) return error.InvalidSiteStatisticsFormatSnapshot;
            var codepoints = (try std.unicode.Utf8View.init(formatted)).iterator();
            while (codepoints.nextCodepoint()) |cp|
                if (cp < 32 or (cp >= 127 and cp <= 159)) return error.InvalidSiteStatisticsFormatSnapshot;
            values[i] = try owned.dupe(u8, formatted);
        }
        return .{ .arena = arena, .values = values };
    }

    pub fn deinit(self: *FormattedStatistics) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "formatted statistics bind captured raw values identity and exact locale strings" {
    const a = std.testing.allocator;
    const namespace: [32]u8 = @splat(0);
    const namespace_hex = std.fmt.bytesToHex(namespace, .lower);
    const site = try std.fmt.allocPrint(a, "{{\"namespace_registry_sha256\":\"{s}\",{s}", .{ namespace_hex, (test_stats_prefix ++ "2}}}")[1..] });
    defer a.free(site);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(site, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const Row = struct { key: []const u8, raw: []const u8, formatted: []const u8 };
    const Proof = struct {
        schema: []const u8,
        wiki: []const u8,
        date: []const u8,
        content_language: []const u8,
        namespace_registry_sha256: []const u8,
        site_info_sha256: []const u8,
        values: [7]Row,
    };
    var proof: Proof = .{
        .schema = "wikidict.site-statistics-format.v1",
        .wiki = @as([]const u8, "bclwiktionary"),
        .date = @as([]const u8, "20261001"),
        .content_language = @as([]const u8, "bcl"),
        .namespace_registry_sha256 = @as([]const u8, &namespace_hex),
        .site_info_sha256 = @as([]const u8, &digest_hex),
        .values = [_]Row{
            .{ .key = "pages", .raw = "13332", .formatted = "13.332" },
            .{ .key = "articles", .raw = "8530", .formatted = "۸٬۵۳۰" },
            .{ .key = "images", .raw = "0", .formatted = "۰" },
            .{ .key = "edits", .raw = "60889", .formatted = "60 889" },
            .{ .key = "users", .raw = "1596", .formatted = "1,596" },
            .{ .key = "activeusers", .raw = "14", .formatted = "14" },
            .{ .key = "admins", .raw = "2", .formatted = "2" },
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(encoded);
    var snapshot = try FormattedStatistics.init(a, encoded, site, namespace, "bclwiktionary", "20261001", "bcl");
    defer snapshot.deinit();
    for (proof.values, snapshot.values) |expected, actual| try std.testing.expectEqualStrings(expected.formatted, actual);
    proof.values[1].raw = "0";
    const wrong_count = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(wrong_count);
    try std.testing.expectError(error.SiteStatisticsFormatIdentityMismatch, FormattedStatistics.init(a, wrong_count, site, namespace, "bclwiktionary", "20261001", "bcl"));
    proof.values[1].raw = "8530";
    proof.site_info_sha256 = &namespace_hex;
    const wrong_hash = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(wrong_hash);
    try std.testing.expectError(error.SiteStatisticsFormatIdentityMismatch, FormattedStatistics.init(a, wrong_hash, site, namespace, "bclwiktionary", "20261001", "bcl"));
    proof.site_info_sha256 = &digest_hex;
    proof.wiki = "enwiktionary";
    const wrong_wiki = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(wrong_wiki);
    try std.testing.expectError(error.SiteStatisticsFormatIdentityMismatch, FormattedStatistics.init(a, wrong_wiki, site, namespace, "bclwiktionary", "20261001", "bcl"));
    proof.wiki = "bclwiktionary";
    proof.values[0].key = "articles";
    const wrong_order = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(wrong_order);
    try std.testing.expectError(error.InvalidSiteStatisticsFormatSnapshot, FormattedStatistics.init(a, wrong_order, site, namespace, "bclwiktionary", "20261001", "bcl"));
    proof.values[0].key = "pages";
    proof.values[0].formatted = "<b>13,332</b>";
    const markup = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(markup);
    try std.testing.expectError(error.InvalidSiteStatisticsFormatSnapshot, FormattedStatistics.init(a, markup, site, namespace, "bclwiktionary", "20261001", "bcl"));
}

/// Finite formatnum observations for exactly the values in the pinned category
/// statistics, including missing-category zero. No locale/count inference.
// Shared finite capture bound covers the measured retained corpus domains.
pub const max_category_formatted_values: usize = 8192;

pub const CategoryFormattedStatistics = struct {
    arena: std.heap.ArenaAllocator,
    values: std.AutoHashMapUnmanaged(u32, []const u8),

    fn member(value: std.json.Value, name: []const u8) !std.json.Value {
        if (value != .object) return error.InvalidCategoryStatisticsFormatSnapshot;
        return value.object.get(name) orelse error.InvalidCategoryStatisticsFormatSnapshot;
    }

    fn text(value: std.json.Value, name: []const u8) ![]const u8 {
        const result = try member(value, name);
        if (result != .string) return error.InvalidCategoryStatisticsFormatSnapshot;
        return result.string;
    }

    pub fn decimal(raw: []const u8) !u32 {
        if (raw.len == 0 or raw.len > 10 or (raw.len > 1 and raw[0] == '0'))
            return error.InvalidCategoryStatisticsFormatSnapshot;
        for (raw) |c| if (!std.ascii.isDigit(c)) return error.InvalidCategoryStatisticsFormatSnapshot;
        return std.fmt.parseInt(u32, raw, 10) catch error.InvalidCategoryStatisticsFormatSnapshot;
    }

    pub fn init(a: A, bytes: []const u8, site_bytes: []const u8, category_bytes: []const u8, namespace_sha256: [32]u8, wiki: []const u8, date: []const u8, language: []const u8) !CategoryFormattedStatistics {
        if (bytes.len > 4 * 1024 * 1024 or category_bytes.len > 64 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(bytes) or !std.unicode.utf8ValidateSlice(category_bytes))
            return error.InvalidCategoryStatisticsFormatSnapshot;
        var scratch_arena = std.heap.ArenaAllocator.init(a);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        var domain: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try domain.put(scratch, 0, {});
        var category_keys: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, category_bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const key = fields.next() orelse return error.InvalidCategoryStatisticsFormatSnapshot;
            const all = try decimal(fields.next() orelse return error.InvalidCategoryStatisticsFormatSnapshot);
            const subcats = try decimal(fields.next() orelse return error.InvalidCategoryStatisticsFormatSnapshot);
            const files = try decimal(fields.next() orelse return error.InvalidCategoryStatisticsFormatSnapshot);
            if (key.len == 0 or fields.next() != null or subcats > all or files > all - subcats)
                return error.InvalidCategoryStatisticsFormatSnapshot;
            const entry = try category_keys.getOrPut(scratch, key);
            if (entry.found_existing) return error.InvalidCategoryStatisticsFormatSnapshot;
            for ([_]u32{ all, all - subcats - files, subcats, files }) |count|
                try domain.put(scratch, count, {});
            if (domain.count() > max_category_formatted_values) return error.CategoryStatisticsFormatDomainTooLarge;
        }
        var category_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(category_bytes, &category_digest, .{});
        return initFromVerifiedDomain(a, bytes, site_bytes, category_digest, domain, namespace_sha256, wiki, date, language);
    }

    pub fn initFromVerifiedDomain(a: A, bytes: []const u8, site_bytes: []const u8, category_digest: [32]u8, domain: std.AutoHashMapUnmanaged(u32, void), namespace_sha256: [32]u8, wiki: []const u8, date: []const u8, language: []const u8) !CategoryFormattedStatistics {
        if (bytes.len > 4 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(bytes))
            return error.InvalidCategoryStatisticsFormatSnapshot;
        var site = try Snapshot.init(a, site_bytes, wiki, date, language);
        defer site.deinit();
        const parsed_site = try std.json.parseFromSlice(std.json.Value, a, site_bytes, .{ .duplicate_field_behavior = .@"error" });
        defer parsed_site.deinit();
        const namespace_hex = std.fmt.bytesToHex(namespace_sha256, .lower);
        if (!std.mem.eql(u8, try text(parsed_site.value, "namespace_registry_sha256"), &namespace_hex))
            return error.CategoryStatisticsFormatIdentityMismatch;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(a);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, scratch, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidCategoryStatisticsFormatSnapshot,
        };
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object or value.object.count() != 8 or
            !std.mem.eql(u8, try text(value, "schema"), "wikidict.category-statistics-format.v1"))
            return error.InvalidCategoryStatisticsFormatSnapshot;
        if (!std.mem.eql(u8, try text(value, "wiki"), wiki) or
            !std.mem.eql(u8, try text(value, "date"), date) or
            !std.mem.eql(u8, try text(value, "content_language"), language))
            return error.CategoryStatisticsFormatIdentityMismatch;
        var site_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(site_bytes, &site_digest, .{});
        if (!std.mem.eql(u8, try text(value, "namespace_registry_sha256"), &namespace_hex) or
            !std.mem.eql(u8, try text(value, "site_info_sha256"), &std.fmt.bytesToHex(site_digest, .lower)) or
            !std.mem.eql(u8, try text(value, "category_stats_sha256"), &std.fmt.bytesToHex(category_digest, .lower)))
            return error.CategoryStatisticsFormatIdentityMismatch;
        const rows = try member(value, "values");
        if (rows != .array or rows.array.items.len != domain.count())
            return error.InvalidCategoryStatisticsFormatSnapshot;
        var values: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        var previous: ?u32 = null;
        for (rows.array.items) |row| {
            if (row != .object or row.object.count() != 2) return error.InvalidCategoryStatisticsFormatSnapshot;
            const count = try decimal(try text(row, "raw"));
            if ((if (previous) |last| count <= last else false) or !domain.contains(count))
                return error.InvalidCategoryStatisticsFormatSnapshot;
            previous = count;
            const formatted = try text(row, "formatted");
            if (formatted.len == 0 or formatted.len > 256 or !std.unicode.utf8ValidateSlice(formatted) or
                std.mem.indexOfAny(u8, formatted, "<>{}|[]") != null)
                return error.InvalidCategoryStatisticsFormatSnapshot;
            var codepoints = (try std.unicode.Utf8View.init(formatted)).iterator();
            while (codepoints.nextCodepoint()) |cp|
                if (cp < 32 or (cp >= 127 and cp <= 159)) return error.InvalidCategoryStatisticsFormatSnapshot;
            try values.put(owned, count, try owned.dupe(u8, formatted));
        }
        return .{ .arena = arena, .values = values };
    }

    pub fn get(self: *const CategoryFormattedStatistics, raw: u32) ?[]const u8 {
        return self.values.get(raw);
    }

    pub fn deinit(self: *CategoryFormattedStatistics) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "category formatted statistics require exact pinned domain and own locale observations" {
    const a = std.testing.allocator;
    const namespace: [32]u8 = @splat(0);
    const namespace_hex = std.fmt.bytesToHex(namespace, .lower);
    const site = try std.fmt.allocPrint(a, "{{\"namespace_registry_sha256\":\"{s}\",{s}", .{ namespace_hex, test_raw[1..] });
    defer a.free(site);
    const categories = "One\t12\t2\t1\nEmpty\t0\t0\t0\n";
    var site_digest: [32]u8 = undefined;
    var category_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(site, &site_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(categories, &category_digest, .{});
    const site_hex = std.fmt.bytesToHex(site_digest, .lower);
    const category_hex = std.fmt.bytesToHex(category_digest, .lower);
    const Row = struct { raw: []const u8, formatted: []const u8 };
    const Proof = struct {
        schema: []const u8 = "wikidict.category-statistics-format.v1",
        wiki: []const u8 = "arwiktionary",
        date: []const u8 = "20261001",
        content_language: []const u8 = "ar",
        namespace_registry_sha256: []const u8,
        site_info_sha256: []const u8,
        category_stats_sha256: []const u8,
        values: []const Row,
    };
    var rows = [_]Row{
        .{ .raw = "0", .formatted = "٠" },
        .{ .raw = "1", .formatted = "١" },
        .{ .raw = "2", .formatted = "٢" },
        .{ .raw = "9", .formatted = "٩" },
        .{ .raw = "12", .formatted = "١٢" },
    };
    var proof: Proof = .{ .namespace_registry_sha256 = &namespace_hex, .site_info_sha256 = &site_hex, .category_stats_sha256 = &category_hex, .values = &rows };
    const encoded = try std.json.Stringify.valueAlloc(a, proof, .{});
    var snapshot = try CategoryFormattedStatistics.init(a, encoded, site, categories, namespace, "arwiktionary", "20261001", "ar");
    defer snapshot.deinit();
    a.free(encoded);
    try std.testing.expectEqualStrings("٩", snapshot.get(9).?);
    try std.testing.expect(snapshot.get(7) == null);
    inline for (.{ "site_info_sha256", "category_stats_sha256", "namespace_registry_sha256" }) |name| {
        const saved = @field(proof, name);
        @field(proof, name) = "wrong";
        const bad = try std.json.Stringify.valueAlloc(a, proof, .{});
        defer a.free(bad);
        try std.testing.expectError(error.CategoryStatisticsFormatIdentityMismatch, CategoryFormattedStatistics.init(a, bad, site, categories, namespace, "arwiktionary", "20261001", "ar"));
        @field(proof, name) = saved;
    }
    inline for (.{ "wiki", "date", "content_language" }) |name| {
        const saved = @field(proof, name);
        @field(proof, name) = "different";
        const bad = try std.json.Stringify.valueAlloc(a, proof, .{});
        defer a.free(bad);
        try std.testing.expectError(error.CategoryStatisticsFormatIdentityMismatch, CategoryFormattedStatistics.init(a, bad, site, categories, namespace, "arwiktionary", "20261001", "ar"));
        @field(proof, name) = saved;
    }
    try std.testing.expectError(error.InvalidCategoryStatisticsFormatSnapshot, CategoryFormattedStatistics.init(a, "{\"schema\":0,\"schema\":1}", site, categories, namespace, "arwiktionary", "20261001", "ar"));
    proof.values = rows[0..4];
    const missing = try std.json.Stringify.valueAlloc(a, proof, .{});
    defer a.free(missing);
    try std.testing.expectError(error.InvalidCategoryStatisticsFormatSnapshot, CategoryFormattedStatistics.init(a, missing, site, categories, namespace, "arwiktionary", "20261001", "ar"));
    proof.values = &rows;
    for ([_][]const u8{ "02", "1", "7", "4294967296" }) |bad_raw| {
        rows[2].raw = bad_raw;
        const bad = try std.json.Stringify.valueAlloc(a, proof, .{});
        defer a.free(bad);
        try std.testing.expectError(error.InvalidCategoryStatisticsFormatSnapshot, CategoryFormattedStatistics.init(a, bad, site, categories, namespace, "arwiktionary", "20261001", "ar"));
    }
    rows[2].raw = "2";
    try std.testing.expectError(error.InvalidCategoryStatisticsFormatSnapshot, CategoryFormattedStatistics.init(a, "\xc0", site, categories, namespace, "arwiktionary", "20261001", "ar"));
    for ([_][]const u8{ "", "<b>2</b>", "2\n" }) |bad_format| {
        rows[2].formatted = bad_format;
        const bad = try std.json.Stringify.valueAlloc(a, proof, .{});
        defer a.free(bad);
        try std.testing.expectError(error.InvalidCategoryStatisticsFormatSnapshot, CategoryFormattedStatistics.init(a, bad, site, categories, namespace, "arwiktionary", "20261001", "ar"));
    }
}

test "site info retains explicit global language conversion independently of language variants" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "true", "false" }) |enabled| {
        const raw = try std.fmt.allocPrint(a, "{{\"query\":{{\"general\":{{\"wikiid\":\"enwiktionary\",\"lang\":\"en\",\"server\":\"//en.wiktionary.org\",\"langconversion\":{s}}}}}}}", .{enabled});
        defer a.free(raw);
        var snapshot = try Snapshot.init(a, raw, "enwiktionary", "20261001", "en");
        defer snapshot.deinit();
        try std.testing.expectEqual(std.mem.eql(u8, enabled, "true"), snapshot.language_conversion_enabled.?);
    }
    var absent = try Snapshot.init(a, test_raw, "arwiktionary", "20261001", "ar");
    defer absent.deinit();
    try std.testing.expect(absent.language_conversion_enabled == null);
    for ([_][]const u8{ "null", "1", "\"true\"", "{}", "[]" }) |value| {
        const raw = try std.fmt.allocPrint(a, "{{\"query\":{{\"general\":{{\"wikiid\":\"enwiktionary\",\"lang\":\"en\",\"server\":\"//en.wiktionary.org\",\"langconversion\":{s}}}}}}}", .{value});
        defer a.free(raw);
        try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, raw, "enwiktionary", "20261001", "en"));
    }
}
