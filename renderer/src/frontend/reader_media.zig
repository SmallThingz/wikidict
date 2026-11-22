//! Optional local speech and explicit media opening for terminal readers.
const std = @import("std");
const A = std.mem.Allocator;
fn command(io: std.Io, a: A, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(2 * 1024 * 1024), .stderr_limit = .limited(8192), .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(45), .clock = .awake } }).toDeadline(io) });
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        a.free(result.stdout);
        return error.MediaActionFailed;
    }
    return result.stdout;
}
pub fn speak(io: std.Io, a: A, word: []const u8, language: []const u8) !void {
    const bytes = command(io, a, &.{ "espeak-ng", "-v", if (language.len == 0) "en" else language, "--", word }) catch |err| switch (err) {
        error.FileNotFound => try command(io, a, &.{ "espeak", "-v", if (language.len == 0) "en" else language, "--", word }),
        else => return err,
    };
    a.free(bytes);
}
pub fn trim(io: std.Io, a: A, root: []const u8, mb: usize) !void {
    return trimExcept(io, a, root, mb, null);
}
fn trimExcept(io: std.Io, a: A, root: []const u8, mb: usize, protected_basename: ?[]const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    const Item = struct { name: []u8, size: u64, time: i128 };
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |item| a.free(item.name);
        items.deinit(a);
    }
    var iterator = dir.iterate();
    var total: u64 = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        total += stat.size;
        try items.ensureUnusedCapacity(a, 1);
        const name = try a.dupe(u8, entry.name);
        items.appendAssumeCapacity(.{ .name = name, .size = stat.size, .time = stat.mtime.nanoseconds });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.time < y.time;
        }
    }.less);
    for (items.items) |item| {
        if (total <= @as(u64, mb) * 1024 * 1024) break;
        if (protected_basename) |name| if (std.mem.eql(u8, item.name, name)) continue;
        try dir.deleteFile(io, item.name);
        total -= item.size;
    }
}
// The caller keeps the response and scratch arena alive until the download ends.
fn mediaLocation(scratch: A, response: []const u8, image: bool) !?[]const u8 {
    const ImageInfo = struct { url: ?std.json.Value = null, thumburl: ?std.json.Value = null };
    const Page = struct { imageinfo: []const ImageInfo = &.{} };
    const Response = struct { query: struct { pages: []const Page } };
    const parsed = std.json.parseFromSliceLeaky(Response, scratch, response, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMediaResponse,
    };
    for (parsed.query.pages) |page| {
        if (page.imageinfo.len == 0) continue;
        const info = page.imageinfo[0];
        const thumbnail = if (image) info.thumburl else null;
        const location = thumbnail orelse info.url orelse return error.InvalidMediaResponse;
        if (location != .string or !std.mem.startsWith(u8, location.string, "https://")) return error.InvalidMediaResponse;
        return location.string;
    }
    return null;
}

pub fn open(io: std.Io, a: A, root: []const u8, file: []const u8, image: bool, mb: usize) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const directory = try std.fmt.allocPrint(scratch, "{s}/.dict-media", .{root});
    try std.Io.Dir.cwd().createDirPath(io, directory);
    if (mb == 0) try trim(io, a, directory, 0);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file, &hash, .{});
    const extension = std.fs.path.extension(file);
    const allowed = [_][]const u8{ ".jpg", ".jpeg", ".png", ".webp", ".gif", ".ogg", ".oga", ".opus", ".mp3", ".wav", ".flac" };
    var valid = false;
    for (allowed) |value| if (std.ascii.eqlIgnoreCase(extension, value)) {
        valid = true;
        break;
    };
    if (!valid) return error.UnsupportedMedia;
    const path = try std.fmt.allocPrint(scratch, "{s}/{s}{s}", .{ directory, std.fmt.bytesToHex(hash, .lower), extension });
    var cached = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (cached) |*f| f.close(io) else {
        var url: ?[]const u8 = null;
        for ([_][]const u8{ "https://commons.wikimedia.org/w/api.php", "https://en.wiktionary.org/w/api.php" }) |api| {
            const response = try command(io, scratch, &.{ "curl", "--fail", "--silent", "--max-time", "30", "--get", api, "--data-urlencode", "action=query", "--data-urlencode", "format=json", "--data-urlencode", "formatversion=2", "--data-urlencode", "prop=imageinfo", "--data-urlencode", "iiprop=url", "--data-urlencode", "iiurlwidth=960", "--data-urlencode", try std.fmt.allocPrint(scratch, "titles=File:{s}", .{file}) });
            url = try mediaLocation(scratch, response, image);
            if (url != null) break;
        }
        const location = url orelse return error.MediaNotFound;
        const temporary = try std.mem.concat(scratch, u8, &.{ path, ".part" });
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        _ = try command(io, scratch, &.{ "curl", "--fail", "--silent", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "40", "--max-filesize", "52428800", "--output", temporary, location });
        try std.Io.Dir.cwd().rename(temporary, .cwd(), path, io);
    }
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, path, scratch);
    _ = try command(io, scratch, &.{ "xdg-open", absolute });
    // The desktop viewer owns playback; retention is bounded independently.
    // Do not remove the just-opened file before the external player reads it.
    if (mb != 0) try trimExcept(io, a, directory, mb, std.fs.path.basename(path));
}

fn retentionFixtureFile(dir: std.Io.Dir, name: []const u8, size: u64, seconds: i96) !void {
    const io = std.testing.io;
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setLength(io, size);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = seconds * std.time.ns_per_s } } });
}

test "media response selects a thumbnail or the original without losing shared files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shared =
        \\{"batchcomplete":true,"query":{"pages":[{"missing":true},{"missing":true,"known":true,"imageinfo":[{"thumburl":"https://example.org/preview.png","url":"https://example.org/original.png"}]}]}}
    ;
    try std.testing.expectEqualStrings("https://example.org/preview.png", (try mediaLocation(a, shared, true)).?);
    try std.testing.expectEqualStrings("https://example.org/original.png", (try mediaLocation(a, shared, false)).?);
    const original_only =
        \\{"query":{"pages":[{"imageinfo":[{"url":"https://example.org/art.png"}]}]}}
    ;
    try std.testing.expectEqualStrings("https://example.org/art.png", (try mediaLocation(a, original_only, true)).?);
    const missing =
        \\{"query":{"pages":[{"missing":true},{"imageinfo":[]}]}}
    ;
    try std.testing.expect((try mediaLocation(a, missing, true)) == null);
}

test "media response reports incomplete metadata to the reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{",
        "null",
        "[]",
        "{}",
        "{\"query\":{\"pages\":{}}}",
        "{\"query\":{\"pages\":[{\"imageinfo\":[{\"timestamp\":\"2026-10-01T00:00:00Z\"}]}]}}",
        "{\"query\":{\"pages\":[{\"imageinfo\":[{\"url\":12}]}]}}",
        "{\"query\":{\"pages\":[{\"imageinfo\":[{\"url\":\"http://example.org/art.png\"}]}]}}",
    }) |response| try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(arena.allocator(), response, true));
}

fn expectRetentionFile(dir: std.Io.Dir, name: []const u8, expected: bool) !void {
    const file = dir.openFile(std.testing.io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return std.testing.expect(!expected),
        else => return err,
    };
    file.close(std.testing.io);
    try std.testing.expect(expected);
}

test "media retention protects oldest selected file while evicting newer files" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try retentionFixtureFile(tmp.dir, "selected.ogg", 700 * 1024, 100);
    try retentionFixtureFile(tmp.dir, "newer.ogg", 700 * 1024, 200);
    try trimExcept(std.testing.io, a, root, 1, "selected.ogg");
    try expectRetentionFile(tmp.dir, "selected.ogg", true);
    try expectRetentionFile(tmp.dir, "newer.ogg", false);
}

test "media retention keeps sole oversized selection until ordinary trim" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try retentionFixtureFile(tmp.dir, "selected.ogg", 2 * 1024 * 1024, 100);
    try trimExcept(std.testing.io, a, root, 1, "selected.ogg");
    try expectRetentionFile(tmp.dir, "selected.ogg", true);
    try trim(std.testing.io, a, root, 1);
    try expectRetentionFile(tmp.dir, "selected.ogg", false);
}

test "ordinary zero-budget media trim removes cached files" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try retentionFixtureFile(tmp.dir, "cached.ogg", 1, 100);
    try trim(std.testing.io, a, root, 0);
    try expectRetentionFile(tmp.dir, "cached.ogg", false);
}

test "media trim releases names and list storage on every allocation failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    try retentionFixtureFile(tmp.dir, "first.ogg", 1, 100);
    try retentionFixtureFile(tmp.dir, "second.ogg", 1, 200);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: A, directory: []const u8) !void {
            try trim(std.testing.io, allocator, directory, 1);
        }
    }.run, .{root});
}
