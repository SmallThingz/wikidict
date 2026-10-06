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
        const server = try string(general, "server");
        if (!validServer(server)) return error.InvalidSiteInfoSnapshot;
        const script = try urlPath(general, "script", false);
        const article_path = try urlPath(general, "articlepath", true);
        const owned_server = try a.dupe(u8, server);
        errdefer a.free(owned_server);
        const owned_script = if (script) |value| try a.dupe(u8, value) else null;
        errdefer if (owned_script) |value| a.free(value);
        return .{ .allocator = a, .server = owned_server, .script = owned_script, .article_path = if (article_path) |value| try a.dupe(u8, value) else null, .statistics = statistics };
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
