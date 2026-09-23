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
        try items.append(a, .{ .name = try a.dupe(u8, entry.name), .size = stat.size, .time = stat.mtime.nanoseconds });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.time < y.time;
        }
    }.less);
    for (items.items) |item| {
        if (total <= @as(u64, mb) * 1024 * 1024) break;
        try dir.deleteFile(io, item.name);
        total -= item.size;
    }
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
    var cached = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
    if (cached) |*f| f.close(io) else {
        var url: ?[]const u8 = null;
        for ([_][]const u8{ "https://commons.wikimedia.org/w/api.php", "https://en.wiktionary.org/w/api.php" }) |api| {
            const response = try command(io, scratch, &.{ "curl", "--fail", "--silent", "--max-time", "30", "--get", api, "--data-urlencode", "action=query", "--data-urlencode", "format=json", "--data-urlencode", "formatversion=2", "--data-urlencode", "prop=imageinfo", "--data-urlencode", "iiprop=url", "--data-urlencode", "iiurlwidth=960", "--data-urlencode", try std.fmt.allocPrint(scratch, "titles=File:{s}", .{file}) });
            const parsed = try std.json.parseFromSlice(std.json.Value, scratch, response, .{});
            const query = parsed.value.object.get("query") orelse return error.InvalidMediaResponse;
            const pages = query.object.get("pages") orelse return error.InvalidMediaResponse;
            for (pages.array.items) |page| if (page.object.get("imageinfo")) |info| {
                if (info.array.items.len != 0) {
                    const item = info.array.items[0];
                    url = (if (image) item.object.get("thumburl") orelse item.object.get("url").? else item.object.get("url").?).string;
                    break;
                }
            };
            if (url != null) break;
        }
        const location = url orelse return error.MediaNotFound;
        if (!std.mem.startsWith(u8, location, "https://")) return error.InvalidMediaResponse;
        const temporary = try std.mem.concat(scratch, u8, &.{ path, ".part" });
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        _ = try command(io, scratch, &.{ "curl", "--fail", "--silent", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "40", "--max-filesize", "52428800", "--output", temporary, location });
        try std.Io.Dir.cwd().rename(temporary, .cwd(), path, io);
    }
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, path, scratch);
    _ = try command(io, scratch, &.{ "xdg-open", absolute });
    // The desktop viewer owns playback; retention is bounded independently.
    // Do not remove the just-opened file before the external player reads it.
    if (mb != 0) try trim(io, a, directory, mb);
}
