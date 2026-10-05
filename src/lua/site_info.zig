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

pub const Snapshot = struct {
    allocator: A,
    server: []const u8,

    pub fn init(a: A, bytes: []const u8, wiki: []const u8, language: []const u8) !Snapshot {
        if (bytes.len > max_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSiteInfoSnapshot;
        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidSiteInfoSnapshot,
        };
        defer parsed.deinit();
        const general = try field(try field(parsed.value, "query"), "general");
        if (!std.mem.eql(u8, try string(general, "wikiid"), wiki) or !std.mem.eql(u8, try string(general, "lang"), language))
            return error.SiteInfoIdentityMismatch;
        const server = try string(general, "server");
        if (!validServer(server)) return error.InvalidSiteInfoSnapshot;
        return .{ .allocator = a, .server = try a.dupe(u8, server) };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.server);
        self.server = "";
    }
};

const test_raw = "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\"}}}";

test "site info preserves exact captured server independently of JSON storage" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8, test_raw);
    defer a.free(input);
    var snapshot = try Snapshot.init(a, input, "arwiktionary", "ar");
    defer snapshot.deinit();
    @memset(input, 'x');
    try std.testing.expectEqualStrings("//ar.wiktionary.org", snapshot.server);
    var norwegian = try Snapshot.init(a, "{\"query\":{\"general\":{\"wikiid\":\"nowiktionary\",\"lang\":\"nb\",\"server\":\"//no.wiktionary.org\"}}}", "nowiktionary", "nb");
    defer norwegian.deinit();
    try std.testing.expectEqualStrings("//no.wiktionary.org", norwegian.server);
}

test "site info rejects absent duplicate invalid and cross-edition metadata" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{}",                                                                                      "[]",                                                                                                            "{\"query\":null}",                                                                                  "{\"query\":{\"general\":{}}}",
        "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":null}}}", "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//a\",\"server\":\"//b\"}}}", "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//bad/path\"}}}", "\xff",
    }) |raw| try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, raw, "arwiktionary", "ar"));
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Snapshot.init(a, test_raw, "enwiktionary", "ar"));
    try std.testing.expectError(error.SiteInfoIdentityMismatch, Snapshot.init(a, test_raw, "arwiktionary", "en"));
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidSiteInfoSnapshot, Snapshot.init(a, oversized, "arwiktionary", "ar"));
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
            var snapshot = try Snapshot.init(no_resize.allocator(), test_raw, "arwiktionary", "ar");
            defer snapshot.deinit();
        }
    }.load, .{});
}
