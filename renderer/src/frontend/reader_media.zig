//! Optional local speech and explicit media opening for terminal readers.
const std = @import("std");
const A = std.mem.Allocator;
const library = @import("library.zig");
const cache_subdirectory = ".dict-media/edition-v1";
const max_media_bytes = 50 * 1024 * 1024;
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
pub fn trimCache(io: std.Io, a: A, root: []const u8, mb: usize) !void {
    const directory = try std.fs.path.join(a, &.{ root, cache_subdirectory });
    defer a.free(directory);
    try trim(io, a, directory, mb);
}
fn trim(io: std.Io, a: A, root: []const u8, mb: usize) !void {
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
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".part")) continue;
        var file = dir.openFile(io, entry.name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
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
        dir.deleteFile(io, item.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        total -= item.size;
    }
}
const Repository = enum { local, shared };
const Source = struct {
    wiki: []const u8,
    host_label: []const u8,

    fn fromScope(a: A, scope: []const u8) !Source {
        const wiki = library.editionWiki(scope) orelse return error.InvalidEditionScope;
        const prefix = wiki[0 .. wiki.len - "wiktionary".len];
        if (prefix.len == 0 or prefix.len > 63) return error.InvalidEditionScope;
        const label = try a.dupe(u8, prefix);
        errdefer a.free(label);
        for (label) |*byte| if (byte.* == '_') {
            byte.* = '-';
        };
        if (label[0] == '-' or label[label.len - 1] == '-') return error.InvalidEditionScope;
        return .{ .wiki = wiki, .host_label = label };
    }
};
const MediaLocation = struct {
    repository: ?Repository,
    title: []const u8,
    url: []const u8,
    revision: []const u8,
};
const TitleMapping = struct { from: []const u8, to: []const u8, tofragment: ?[]const u8 = null };

fn resolvedTitle(requested: []const u8, normalized: []const TitleMapping, redirects: []const TitleMapping) ![]const u8 {
    const count = normalized.len + redirects.len;
    if (count > 8) return error.InvalidMediaResponse;
    var resolved = requested;
    var seen: [9][]const u8 = undefined;
    seen[0] = requested;
    for (0..count) |step| {
        var next: ?[]const u8 = null;
        for ([_][]const TitleMapping{ normalized, redirects }) |rows| for (rows) |row| {
            if (!std.mem.eql(u8, row.from, resolved)) continue;
            if (next != null or row.to.len == 0 or (row.tofragment orelse @as([]const u8, "")).len != 0) return error.InvalidMediaResponse;
            next = row.to;
        };
        resolved = next orelse return error.InvalidMediaResponse;
        for (seen[0 .. step + 1]) |title| if (std.mem.eql(u8, title, resolved)) return error.InvalidMediaResponse;
        seen[step + 1] = resolved;
    }
    return resolved;
}

const CdnOrigin = enum { upload, thumbnail };
const CdnUrl = struct {
    origin: CdnOrigin,
    path: []const u8,
    query: []const u8,
};

fn cdnUrl(url: []const u8) !CdnUrl {
    if (!std.mem.startsWith(u8, url, "https://") or std.mem.indexOfAny(u8, url, "\\#") != null) return error.InvalidMediaResponse;
    for (url) |byte| if (byte <= 32 or byte == 127) return error.InvalidMediaResponse;
    const authority = url["https://".len..];
    const slash = std.mem.indexOfScalar(u8, authority, '/') orelse return error.InvalidMediaResponse;
    const host = authority[0..slash];
    const origin: CdnOrigin = if (std.mem.eql(u8, host, "upload.wikimedia.org"))
        .upload
    else if (std.mem.eql(u8, host, "thumb.wikimedia.org"))
        .thumbnail
    else
        return error.InvalidMediaResponse;
    const rest = authority[slash..];
    const query = std.mem.indexOfScalar(u8, rest, '?') orelse return .{ .origin = origin, .path = rest, .query = "" };
    return .{ .origin = origin, .path = rest[0..query], .query = rest[query + 1 ..] };
}

fn trackingOnly(query: []const u8) bool {
    if (query.len == 0) return true;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const split = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        const name = field[0..split];
        if (!std.mem.eql(u8, name, "utm_source") and !std.mem.eql(u8, name, "utm_campaign") and
            !std.mem.eql(u8, name, "utm_content")) return false;
    }
    return true;
}

fn titleBody(title: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, title, ':') orelse return error.InvalidMediaResponse;
    if (colon == 0 or colon + 1 == title.len) return error.InvalidMediaResponse;
    return title[colon + 1 ..];
}

fn nativeJpeg(filename: []const u8) bool {
    const extension = std.fs.path.extension(filename);
    return std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg");
}

fn selectedUrl(a: A, source: Source, repository: Repository, filename: []const u8, original: []const u8, thumbnail: ?[]const u8, mime: []const u8) ![]const u8 {
    const prefix = switch (repository) {
        .local => try std.fmt.allocPrint(a, "/wiktionary/{s}/", .{source.host_label}),
        .shared => "/wikipedia/commons/",
    };
    const origin = try cdnUrl(original);
    if (origin.origin != .upload or !std.mem.startsWith(u8, origin.path, prefix)) return error.InvalidMediaResponse;
    const relative = origin.path[prefix.len..];
    var parts = std.mem.splitScalar(u8, relative, '/');
    const first = parts.next() orelse return error.InvalidMediaResponse;
    const second = parts.next() orelse return error.InvalidMediaResponse;
    const encoded = parts.next() orelse return error.InvalidMediaResponse;
    if (first.len != 1 or second.len != 2 or first[0] != second[0] or parts.next() != null) return error.InvalidMediaResponse;
    for (second) |byte| if (!std.ascii.isHex(byte)) return error.InvalidMediaResponse;
    const component: std.Uri.Component = .{ .percent_encoded = encoded };
    const uploaded = try component.toRawMaybeAlloc(a);
    if (uploaded.len != filename.len) return error.InvalidMediaResponse;
    // Upload URL serialization uses underscores for title spaces. Keep the
    // query and cache filename bytes exactly as compiled.
    for (uploaded, filename) |byte, expected| {
        if (byte != expected and !(byte == '_' and expected == ' ')) return error.InvalidMediaResponse;
    }

    const preview = thumbnail orelse return original;
    const parsed = try cdnUrl(preview);
    if (parsed.origin == .upload and std.mem.eql(u8, parsed.path, origin.path)) {
        return if (std.mem.eql(u8, mime, "image/jpeg") and nativeJpeg(filename) and trackingOnly(origin.query) and trackingOnly(parsed.query))
            original
        else
            preview;
    }
    const transformed = try std.fmt.allocPrint(a, "{s}thumb/{s}/", .{ prefix, relative });
    if (!std.mem.startsWith(u8, parsed.path, transformed)) return error.InvalidMediaResponse;
    const encoded_rendition: std.Uri.Component = .{ .percent_encoded = parsed.path[transformed.len..] };
    const rendition = try encoded_rendition.toRawMaybeAlloc(a);
    if (rendition.len == 0 or std.mem.indexOfAny(u8, rendition, "/\\") != null or
        std.mem.eql(u8, rendition, ".") or std.mem.eql(u8, rendition, "..")) return error.InvalidMediaResponse;
    return preview;
}

// Only the absent object field can get the default; explicit null is a token.
const CanonicalTitle = union(enum) {
    omitted,
    supplied: []const u8,

    pub fn jsonParse(a: A, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .supplied = try std.json.innerParse([]const u8, a, source, options) };
    }
};

// Dimensions are required metadata for a positive result. They do not select
// the rendition or describe the pixels actually delivered to the viewer.
const ImageDimension = enum {
    positive_integer,

    pub fn jsonParse(a: A, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        // The generic float parser also accepts strings. Require a JSON number.
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        const value = try std.json.innerParse(f64, a, source, options);
        if (!std.math.isFinite(value) or value <= 0 or @trunc(value) != value) return error.InvalidNumber;
        return .positive_integer;
    }
};

// The source wiki's own ImageInfo response selects the repository. A missing
// local description page can carry real shared ImageInfo.
fn mediaLocation(a: A, response: []const u8, source: Source, requested: []const u8) !?MediaLocation {
    const ImageInfo = struct {
        url: []const u8,
        thumburl: ?[]const u8 = null,
        canonicaltitle: CanonicalTitle = .omitted,
        width: ImageDimension,
        height: ImageDimension,
        mime: []const u8,
        sha1: []const u8 = "",
    };
    const Page = struct {
        ns: i32,
        title: []const u8,
        invalid: bool = false,
        missing: bool = false,
        redirect: bool = false,
        imagerepository: []const u8,
        imageinfo: []const ImageInfo = &.{},
    };
    const Query = struct {
        general: struct { wikiid: []const u8 },
        normalized: []const TitleMapping = &.{},
        redirects: []const TitleMapping = &.{},
        pages: []const Page,
    };
    const Response = struct { @"error": ?std.json.Value = null, query: ?Query = null };
    const parsed = std.json.parseFromSliceLeaky(Response, a, response, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMediaResponse,
    };
    const query = parsed.query orelse return error.InvalidMediaResponse;
    if (parsed.@"error" != null or query.pages.len != 1 or !std.mem.eql(u8, query.general.wikiid, source.wiki)) return error.InvalidMediaResponse;
    const page = query.pages[0];
    if (page.invalid or page.redirect or page.ns != 6 or
        !std.mem.eql(u8, page.title, try resolvedTitle(requested, query.normalized, query.redirects))) return error.InvalidMediaResponse;
    if (page.missing and page.imagerepository.len == 0 and page.imageinfo.len == 0) return null;
    const repository = std.meta.stringToEnum(Repository, page.imagerepository) orelse return error.InvalidMediaResponse;
    if ((page.missing and repository == .local) or page.imageinfo.len != 1) return error.InvalidMediaResponse;
    const info = page.imageinfo[0];
    const filename = try titleBody(page.title);
    if (info.canonicaltitle == .supplied) {
        if (!std.mem.eql(u8, filename, try titleBody(info.canonicaltitle.supplied))) return error.InvalidMediaResponse;
    }
    if (!std.mem.startsWith(u8, info.mime, "image/")) return error.InvalidMediaResponse;
    return .{
        .repository = repository,
        .title = page.title,
        .url = try selectedUrl(a, source, repository, filename, info.url, info.thumburl, info.mime),
        .revision = info.sha1,
    };
}

fn sourceImageLocation(comptime execute: anytype, io: std.Io, a: A, source: Source, title_arg: []const u8) !MediaLocation {
    const api = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/api.php", .{source.host_label});
    const response = try execute(io, a, &.{
        "curl", "--disable", "--fail", "--silent", "--proto", "=https", "--max-time", "30", "--get", api,
        "--data-urlencode", "action=query", "--data-urlencode", "format=json", "--data-urlencode", "formatversion=2",
        "--data-urlencode", "meta=siteinfo", "--data-urlencode", "siprop=general", "--data-urlencode", "prop=imageinfo",
        "--data-urlencode", "iilimit=1", "--data-urlencode", "iiprop=url|size|mime|canonicaltitle|sha1",
        "--data-urlencode", "iiurlwidth=960", "--data-urlencode", title_arg, "--write-out", "\n%{http_code}",
    });
    if (!std.mem.endsWith(u8, response, "\n200")) return error.MediaActionFailed;
    return (try mediaLocation(a, response[0 .. response.len - 4], source, title_arg["titles=".len..])) orelse error.MediaNotFound;
}

// Audio keeps its existing Commons/English compatibility lookup. Its cache
// records the successful resolver and URL in the versioned namespace.
fn legacyAudioLocation(comptime execute: anytype, io: std.Io, a: A, title_arg: []const u8) !MediaLocation {
    const ImageInfo = struct { url: ?std.json.Value = null };
    const Page = struct { imageinfo: []const ImageInfo = &.{} };
    const Response = struct { query: struct { pages: []const Page } };
    for ([_][]const u8{ "https://commons.wikimedia.org/w/api.php", "https://en.wiktionary.org/w/api.php" }) |api| {
        const response = try execute(io, a, &.{
            "curl", "--fail", "--silent", "--max-time", "30", "--get", api,
            "--data-urlencode", "action=query", "--data-urlencode", "format=json", "--data-urlencode", "formatversion=2",
            "--data-urlencode", "prop=imageinfo", "--data-urlencode", "iiprop=url", "--data-urlencode", "iiurlwidth=960",
            "--data-urlencode", title_arg,
        });
        const parsed = std.json.parseFromSliceLeaky(Response, a, response, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMediaResponse,
        };
        for (parsed.query.pages) |page| {
            if (page.imageinfo.len == 0) continue;
            const url = page.imageinfo[0].url orelse return error.InvalidMediaResponse;
            if (url != .string or !std.mem.startsWith(u8, url.string, "https://")) return error.InvalidMediaResponse;
            return .{ .repository = null, .title = api, .url = url.string, .revision = "" };
        }
    }
    return error.MediaNotFound;
}

fn cacheHash(scope: []const u8, file: []const u8, image: bool, location: MediaLocation) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ cache_subdirectory, scope, file, if (image) "image" else "audio", if (location.repository) |repo| @tagName(repo) else "legacy-audio", location.title, location.url, location.revision }) |part| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, @intCast(part.len), .little);
        hash.update(&len);
        hash.update(part);
    }
    return hash.finalResult();
}

fn cachePresent(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file or stat.size == 0 or stat.size > max_media_bytes) return error.InvalidMediaCacheEntry;
    return true;
}

pub fn open(io: std.Io, a: A, root: []const u8, edition_scope: ?[]const u8, file: []const u8, image: bool, mb: usize) !void {
    try openWithCommand(command, io, a, root, edition_scope, file, image, mb);
}

fn openWithCommand(comptime execute: anytype, io: std.Io, a: A, root: []const u8, edition_scope: ?[]const u8, file: []const u8, image: bool, mb: usize) !void {
    try io.checkCancel();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const T = @import("blob_encoder").presentation_types;
    if (image and (file.len > 1024 or !T.validInlineImageFile(file))) return error.UnsupportedMedia;
    const extension = std.fs.path.extension(file);
    const allowed = [_][]const u8{ ".jpg", ".jpeg", ".png", ".webp", ".gif", ".ogg", ".oga", ".opus", ".mp3", ".wav", ".flac" };
    for (allowed) |value| {
        if (std.ascii.eqlIgnoreCase(extension, value)) break;
    } else return error.UnsupportedMedia;

    const title_arg = try std.fmt.allocPrint(scratch, "titles=File:{s}", .{file});
    const scope = if (image) edition_scope orelse return error.InvalidEditionScope else "";
    const location = if (image)
        try sourceImageLocation(execute, io, scratch, try Source.fromScope(scratch, scope), title_arg)
    else
        try legacyAudioLocation(execute, io, scratch, title_arg);
    try io.checkCancel();

    const directory = try std.fs.path.join(scratch, &.{ root, cache_subdirectory });
    try std.Io.Dir.cwd().createDirPath(io, directory);
    if (mb == 0) try trim(io, a, directory, 0);
    const hash = cacheHash(scope, file, image, location);
    const path = try std.fmt.allocPrint(scratch, "{s}/{s}{s}", .{ directory, std.fmt.bytesToHex(hash, .lower), extension });
    if (!try cachePresent(io, path)) {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const temporary = try std.fmt.allocPrint(scratch, "{s}.{s}.part", .{ path, std.fmt.bytesToHex(nonce, .lower) });
        const staging = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true });
        defer {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        }
        staging.close(io);
        const image_args = [_][]const u8{ "--globoff", "--path-as-is" };
        const audio_args = [_][]const u8{ "--location", "--proto-redir", "=https" };
        const transfer_args: []const []const u8 = if (image) &image_args else &audio_args;
        const argv = try std.mem.concat(scratch, []const u8, &.{
            &.{ "curl", "--disable", "--fail", "--silent", "--proto", "=https", "--max-time", "40" },
            transfer_args,
            &.{ "--max-filesize", std.fmt.comptimePrint("{d}", .{max_media_bytes}), "--write-out", "%{http_code}", "--output", temporary, location.url },
        });
        const status = try execute(io, scratch, argv);
        if (!std.mem.eql(u8, status, "200") or !try cachePresent(io, temporary)) return error.MediaActionFailed;
        try io.checkCancel();
        try std.Io.Dir.cwd().rename(temporary, .cwd(), path, io);
    }
    try io.checkCancel();
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, path, scratch);
    _ = try execute(io, scratch, &.{ "xdg-open", absolute });
    // The desktop viewer owns playback; keep the just-opened file available.
    if (mb != 0) try trimExcept(io, a, directory, mb, std.fs.path.basename(path));
}

fn retentionFixtureFile(dir: std.Io.Dir, name: []const u8, size: u64, seconds: i96) !void {
    const io = std.testing.io;
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setLength(io, size);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = seconds * std.time.ns_per_s } } });
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

// Synthetic one-title responses. The shared case models a missing local
// description page. It does not stand in for a captured shared positive.
const edition_media_local =
    \\{"query":{"general":{"wikiid":"sdwiktionary"},"normalized":[{"from":"File:needle.jpg","to":"فائل:needle.jpg"}],"pages":[{"title":"فائل:needle.jpg","ns":6,"imagerepository":"local","imageinfo":[{"canonicaltitle":"فائل:needle.jpg","width":150,"height":107,"mime":"image/jpeg","sha1":"abcdef","url":"https://upload.wikimedia.org/wiktionary/sd/b/b1/needle.jpg?utm_content=original","thumburl":"https://upload.wikimedia.org/wiktionary/sd/b/b1/needle.jpg?utm_content=thumbnail"}]}]}}
;
const edition_media_shared =
    \\{"query":{"general":{"wikiid":"sdwiktionary"},"normalized":[{"from":"File:needle.jpg","to":"فائل:needle.jpg"}],"pages":[{"title":"فائل:needle.jpg","ns":6,"missing":true,"known":true,"imagerepository":"shared","imageinfo":[{"canonicaltitle":"File:needle.jpg","width":1863,"height":2532,"mime":"image/jpeg","sha1":"abcdef","url":"https://upload.wikimedia.org/wikipedia/commons/b/b1/needle.jpg","thumburl":"https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/needle.jpg/960px-needle.jpg"}]}]}}
;
const edition_media_missing =
    \\{"query":{"general":{"wikiid":"sdwiktionary"},"pages":[{"title":"File:needle.jpg","ns":6,"missing":true,"imagerepository":""}]}}
;

test "source image metadata binds exact requests to coherent local or shared bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try Source.fromScope(a, "sdwiktionary-20261001");
    const local = (try mediaLocation(a, edition_media_local, source, "File:needle.jpg")).?;
    try std.testing.expectEqual(Repository.local, local.repository.?);
    try std.testing.expectEqualStrings("فائل:needle.jpg", local.title);
    try std.testing.expectEqualStrings("https://upload.wikimedia.org/wiktionary/sd/b/b1/needle.jpg?utm_content=original", local.url);
    const shared = (try mediaLocation(a, edition_media_shared, source, "File:needle.jpg")).?;
    try std.testing.expectEqual(Repository.shared, shared.repository.?);
    try std.testing.expectEqualStrings("https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/needle.jpg/960px-needle.jpg", shared.url);
    try std.testing.expect((try mediaLocation(a, edition_media_missing, source, "File:needle.jpg")) == null);
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, edition_media_local, source, "File:Needle.jpg"));

    const without_canonical = try std.mem.replaceOwned(u8, a, edition_media_local, "\"canonicaltitle\":\"فائل:needle.jpg\",", "");
    try std.testing.expectEqualStrings(local.url, (try mediaLocation(a, without_canonical, source, "File:needle.jpg")).?.url);
    const wrong_canonical = try std.mem.replaceOwned(u8, a, edition_media_local, "\"canonicaltitle\":\"فائل:needle.jpg", "\"canonicaltitle\":\"فائل:Needle.jpg");
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, wrong_canonical, source, "File:needle.jpg"));
    for ([_][2][]const u8{
        .{ "/thumb/b/b1/needle.jpg/", "/thumb/b/b1/Needle.jpg/" },
        .{ "/commons/thumb/", "/other/thumb/" },
        .{ "960px-needle.jpg", "nested/960px-needle.jpg" },
        .{ "thumb.wikimedia.org/wikipedia/commons/thumb", "unknown.wikimedia.org/wikipedia/commons/thumb" },
    }) |mutation| {
        const invalid = try std.mem.replaceOwned(u8, a, edition_media_shared, mutation[0], mutation[1]);
        try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, invalid, source, "File:needle.jpg"));
    }

    const query_thumb = try std.mem.replaceOwned(u8, a, edition_media_local, "utm_content=thumbnail", "width=960");
    try std.testing.expect(std.mem.endsWith(u8, (try mediaLocation(a, query_thumb, source, "File:needle.jpg")).?.url, "?width=960"));
    for ([_][2][]const u8{
        .{ "\"ns\":6", "\"ns\":0" },
        .{ "\"wikiid\":\"sdwiktionary\"", "\"wikiid\":\"enwiktionary\"" },
        .{ "\"imagerepository\":\"local\"", "\"imagerepository\":\"shared\"" },
        .{ "\"imagerepository\":\"local\"", "\"missing\":true,\"imagerepository\":\"local\"" },
        .{ "/wiktionary/sd/b/b1/", "/wiktionary/en/b/b1/" },
        .{ "b1/needle.jpg", "b1/Needle.jpg" },
        .{ "\"imageinfo\"", "\"ignored_imageinfo\"" },
    }) |mutation| {
        const invalid = try std.mem.replaceOwned(u8, a, edition_media_local, mutation[0], mutation[1]);
        try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, invalid, source, "File:needle.jpg"));
    }
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, "{\"error\":{\"code\":\"maxlag\"}}", source, "File:needle.jpg"));
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, "{", source, "File:needle.jpg"));
    const alias = r_alias: {
        const with_normalization = try std.mem.replaceOwned(u8, a, edition_media_local, "File:needle.jpg", "File:Alias.jpg");
        break :r_alias try std.mem.replaceOwned(u8, a, with_normalization, "\"to\":\"فائل:needle.jpg\"}],",
            "\"to\":\"فائل:Alias.jpg\"}],\"redirects\":[{\"from\":\"فائل:Alias.jpg\",\"to\":\"فائل:needle.jpg\"}],");
    };
    try std.testing.expectEqualStrings(local.url, (try mediaLocation(a, alias, source, "File:Alias.jpg")).?.url);
    try std.testing.expectError(error.InvalidMediaResponse, resolvedTitle("File:Alias.jpg", &.{},
        &.{.{ .from = "File:Alias.jpg", .to = "File:Alias.jpg" }}));
    try std.testing.expectError(error.InvalidMediaResponse, resolvedTitle("File:Alias.jpg", &.{},
        &.{.{ .from = "File:Alias.jpg", .to = "File:needle.jpg", .tofragment = "target" }}));
    try std.testing.expectError(error.InvalidMediaResponse, resolvedTitle("File:Alias.jpg", &.{},
        &.{ .{ .from = "File:Alias.jpg", .to = "File:needle.jpg" }, .{ .from = "File:Unrelated.jpg", .to = "File:Other.jpg" } }));
}

test "source media cache identity binds edition date repository exact filename and rendition" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const scope = "sdwiktionary-20261001";
    const source = try Source.fromScope(scratch, scope);
    const historical = try Source.fromScope(scratch, "be_x_oldwiktionary-20261001");
    try std.testing.expectEqualStrings("be-x-old", historical.host_label);
    try std.testing.expectError(error.InvalidEditionScope, Source.fromScope(scratch, ""));
    try std.testing.expectError(error.InvalidEditionScope, Source.fromScope(scratch, "sdwiktionary-20260229"));
    const file = "needle.jpg";
    const local = (try mediaLocation(scratch, edition_media_local, source, "File:needle.jpg")).?;
    const key = cacheHash(scope, file, true, local);
    var variant = local;
    variant.repository = .shared;
    var new_revision = local;
    new_revision.revision = "new";
    var new_url = local;
    new_url.url = "https://upload.wikimedia.org/wiktionary/sd/b/b1/needle.jpg?width=960";
    for ([_][32]u8{
        cacheHash("enwiktionary-20261001", file, true, local),
        cacheHash("sdwiktionary-20261101", file, true, local),
        cacheHash(scope, "Needle.jpg", true, local),
        cacheHash(scope, file, false, local),
        cacheHash(scope, file, true, variant),
        cacheHash(scope, file, true, new_revision),
        cacheHash(scope, file, true, new_url),
    }) |other| try std.testing.expect(!std.mem.eql(u8, &key, &other));
}

const EditionMediaCommand = struct {
    var response: []const u8 = edition_media_local;
    var cancel_download = false;
    var metadata_status: []const u8 = "200";
    var queries: usize = 0;
    var downloads: usize = 0;
    var opens: usize = 0;

    fn execute(io: std.Io, a: A, argv: []const []const u8) ![]u8 {
        const shared = std.mem.eql(u8, response, edition_media_shared);
        const raster = if (shared) @as([]const u8, "commons-raster") else "source-raster";
        if (std.mem.eql(u8, argv[0], "xdg-open")) {
            opens += 1;
            try std.testing.expect(std.mem.indexOf(u8, argv[1], cache_subdirectory) != null);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, argv[1], a, .limited(128));
            defer a.free(bytes);
            try std.testing.expectEqualStrings(raster, bytes);
            return a.dupe(u8, "");
        }
        try std.testing.expectEqualStrings("curl", argv[0]);
        for (argv, 0..) |argument, index| {
            try std.testing.expect(!std.mem.eql(u8, argument, "https://commons.wikimedia.org/w/api.php"));
            try std.testing.expect(!std.mem.eql(u8, argument, "https://en.wiktionary.org/w/api.php"));
            try std.testing.expect(!std.mem.eql(u8, argument, "redirects=1"));
            try std.testing.expect(!std.mem.eql(u8, argument, "--location"));
            if (std.mem.eql(u8, argument, "--output")) {
                downloads += 1;
                const expected = if (shared)
                    "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/needle.jpg/960px-needle.jpg"
                else
                    "https://upload.wikimedia.org/wiktionary/sd/b/b1/needle.jpg?utm_content=original";
                try std.testing.expectEqualStrings(expected, argv[argv.len - 1]);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = argv[index + 1], .data = raster });
                if (cancel_download) return error.Canceled;
                return a.dupe(u8, "200");
            }
        }
        var exact_title = false;
        var exact_host = false;
        for (argv) |argument| {
            exact_title = exact_title or std.mem.eql(u8, argument, "titles=File:needle.jpg");
            exact_host = exact_host or std.mem.eql(u8, argument, "https://sd.wiktionary.org/w/api.php");
        }
        try std.testing.expect(exact_title and exact_host);
        queries += 1;
        return std.fmt.allocPrint(a, "{s}\n{s}", .{ response, metadata_status });
    }
};

test "source media rechecks repository before using warm bytes and isolates filename-only poison" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var old_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("needle.jpg", &old_hash, .{});
    const legacy = try std.fmt.allocPrint(a, ".dict-media/{s}.jpg", .{std.fmt.bytesToHex(old_hash, .lower)});
    defer a.free(legacy);
    try tmp.dir.createDirPath(io, ".dict-media");
    try tmp.dir.writeFile(io, .{ .sub_path = legacy, .data = "old-wrong-repository" });
    const Mock = EditionMediaCommand;
    Mock.response = edition_media_local;
    Mock.cancel_download = true;
    Mock.metadata_status = "200";
    Mock.queries = 0;
    Mock.downloads = 0;
    Mock.opens = 0;
    const scope = "sdwiktionary-20261001";
    try std.testing.expectError(error.InvalidEditionScope, openWithCommand(Mock.execute, io, a, root, "", "needle.jpg", true, 4));
    try std.testing.expectEqual(@as(usize, 0), Mock.queries);
    try std.testing.expectError(error.Canceled, openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4));
    var cache = try tmp.dir.openDir(io, cache_subdirectory, .{ .iterate = true });
    defer cache.close(io);
    var iterator = cache.iterate();
    try std.testing.expect((try iterator.next(io)) == null);
    try std.testing.expectEqual(@as(usize, 0), Mock.opens);
    Mock.cancel_download = false;
    try openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4);
    try openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4);
    Mock.response = edition_media_shared;
    try openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4);
    Mock.metadata_status = "302";
    try std.testing.expectError(error.MediaActionFailed, openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4));
    Mock.metadata_status = "200";
    Mock.response = edition_media_missing;
    try std.testing.expectError(error.MediaNotFound, openWithCommand(Mock.execute, io, a, root, scope, "needle.jpg", true, 4));
    try std.testing.expectEqual(@as(usize, 6), Mock.queries);
    try std.testing.expectEqual(@as(usize, 3), Mock.downloads);
    try std.testing.expectEqual(@as(usize, 3), Mock.opens);
    try trimCache(io, a, root, 0);
    var after_trim = cache.iterate();
    try std.testing.expect((try after_trim.next(io)) == null);
    const kept = try tmp.dir.readFileAlloc(io, legacy, a, .limited(128));
    defer a.free(kept);
    try std.testing.expectEqualStrings("old-wrong-repository", kept);
}

test "legacy audio retains its Commons then English original lookup" {
    const Mock = struct {
        var requests: usize = 0;
        fn execute(_: std.Io, a: A, argv: []const []const u8) ![]u8 {
            const api = [_][]const u8{ "https://commons.wikimedia.org/w/api.php", "https://en.wiktionary.org/w/api.php" };
            try std.testing.expect(requests < api.len);
            var found = false;
            for (argv) |arg| found = found or std.mem.eql(u8, arg, api[requests]);
            try std.testing.expect(found);
            try std.testing.expectEqualStrings("titles=File:Note.ogg", argv[argv.len - 1]);
            requests += 1;
            return a.dupe(u8, if (requests == 1)
                "{\"query\":{\"pages\":[{\"missing\":true}]}}"
            else
                "{\"query\":{\"pages\":[{\"imageinfo\":[{\"url\":\"https://example.org/original.ogg\",\"thumburl\":\"https://example.org/preview.ogg\"}]}]}}");
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    Mock.requests = 0;
    const location = try legacyAudioLocation(Mock.execute, std.testing.io, arena.allocator(), "titles=File:Note.ogg");
    try std.testing.expectEqual(@as(usize, 2), Mock.requests);
    try std.testing.expect(location.repository == null);
    try std.testing.expectEqualStrings("https://example.org/original.ogg", location.url);
}

test "source image rejects supplied invalid canonical titles and nonpositive or malformed dimensions" {
    const Query = struct {
        fn execute(_: std.Io, a: A, argv: []const []const u8) ![]u8 {
            var requested_size = false;
            for (argv) |argument| {
                if (std.mem.eql(u8, argument, "iiprop=url|size|mime|canonicaltitle|sha1")) requested_size = true;
            }
            try std.testing.expect(requested_size);
            return std.fmt.allocPrint(a, "{s}\n200", .{edition_media_local});
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try Source.fromScope(a, "sdwiktionary-20261001");
    const requested = "File:needle.jpg";
    const positive = try sourceImageLocation(Query.execute, std.testing.io, a, source, "titles=" ++ requested);
    try std.testing.expectEqual(Repository.local, positive.repository.?);

    const without_title = try std.mem.replaceOwned(u8, a, edition_media_local, "\"canonicaltitle\":\"فائل:needle.jpg\",", "");
    try std.testing.expectEqualStrings(positive.url, (try mediaLocation(a, without_title, source, requested)).?.url);
    for ([_][]const u8{ "null", "150", "\"\"", "true", "{}", "[]" }) |supplied| {
        const field = try std.fmt.allocPrint(a, "\"canonicaltitle\":{s},", .{supplied});
        const invalid = try std.mem.replaceOwned(u8, a, edition_media_local, "\"canonicaltitle\":\"فائل:needle.jpg\",", field);
        try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, invalid, source, requested));
    }
    for ([_][2][]const u8{ .{ "width", "150" }, .{ "height", "107" } }) |axis| {
        const original = try std.fmt.allocPrint(a, "\"{s}\":{s},", .{ axis[0], axis[1] });
        const missing = try std.mem.replaceOwned(u8, a, edition_media_local, original, "");
        try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, missing, source, requested));
        for ([_][]const u8{ "null", "\"150\"", "true", "0", "-1", "1.5", "1e999", "{}", "[]" }) |value| {
            const field = try std.fmt.allocPrint(a, "\"{s}\":{s},", .{ axis[0], value });
            const invalid = try std.mem.replaceOwned(u8, a, edition_media_local, original, field);
            try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, invalid, source, requested));
        }
    }
    const integral_number = try std.mem.replaceOwned(u8, a, edition_media_local, "\"width\":150,", "\"width\":150.0,");
    try std.testing.expectEqualStrings(positive.url, (try mediaLocation(a, integral_number, source, requested)).?.url);
}

test "source image admits the explicit thumbnail host only for its bound transformation path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try Source.fromScope(a, "sdwiktionary-20261001");
    const original = "https://upload.wikimedia.org/wikipedia/commons/b/b1/needle.jpg";
    const full_rendition = "/wikipedia/commons/thumb/b/b1/needle.jpg/960px-needle.jpg";
    for ([_][]const u8{ "https://upload.wikimedia.org", "https://thumb.wikimedia.org" }) |host| {
        const thumbnail = try std.mem.concat(a, u8, &.{ host, full_rendition });
        try std.testing.expectEqualStrings(thumbnail, try selectedUrl(a, source, .shared, "needle.jpg", original, thumbnail, "image/jpeg"));
    }
    for ([_][]const u8{
        "https://thumb.wikimedia.org/wikipedia/commons/b/b1/needle.jpg", // Cross-host static URL.
        "https://cdn.wikimedia.org" ++ full_rendition,
        "http://thumb.wikimedia.org" ++ full_rendition,
        "https://thumb.wikimedia.org:443" ++ full_rendition,
        "https://thumb.wikimedia.org/wiktionary/sd/thumb/b/b1/needle.jpg/960px-needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/Needle.jpg/960px-needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/old.jpg/960px-needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/b1/needle.jpg/960px-needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/needle.jpg/sub/960px-needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/needle.jpg/sub%2F960px-needle.jpg",
    }) |invalid| try std.testing.expectError(error.InvalidMediaResponse,
        selectedUrl(a, source, .shared, "needle.jpg", original, invalid, "image/jpeg"));
    try std.testing.expectError(error.InvalidMediaResponse, selectedUrl(a, source, .shared, "needle.jpg",
        "https://thumb.wikimedia.org/wikipedia/commons/b/b1/needle.jpg", null, "image/jpeg"));
}

// Exact retained response bytes. Only the siteinfo wrappers below are constructed.
const retained_sd_response =
    "{\x22batchcomplete\x22:true,\x22query\x22:{\x22normalized\x22:[{\x22fromencoded\x22:false,\x22from\x22:\x22File:antenna.jpg\x22,\x22to\x22" ++
    ":\x22\xd9\x81\xd8\xa7\xd8\xa6\xd9\x84:antenna.jpg\x22}],\x22pages\x22:[{\x22pageid\x22:2276,\x22ns\x22:6,\x22title\x22:\x22\xd9\x81\xd8\xa7\xd8\xa6\xd9\x84:antenna.jpg\x22,\x22imagere" ++
    "pository\x22:\x22local\x22,\x22imageinfo\x22:[{\x22size\x22:3794,\x22width\x22:150,\x22height\x22:107,\x22thumburl\x22:\x22https://upload." ++
    "wikimedia.org/wiktionary/sd/e/e2/antenna.jpg?utm_source=sd.wiktionary.org&utm_campaign=imageinfo" ++
    "&utm_content=thumbnail_unscaled\x22,\x22thumbwidth\x22:960,\x22thumbheight\x22:685,\x22thumbattribs\x22:{\x22src\x22:\x22//upl" ++
    "oad.wikimedia.org/wiktionary/sd/e/e2/antenna.jpg?utm_source=sd.wiktionary.org&utm_campaign=image" ++
    "info&utm_content=thumbnail_unscaled\x22,\x22decoding\x22:\x22async\x22,\x22loading\x22:\x22lazy\x22,\x22width\x22:960,\x22height\x22:68" ++
    "5},\x22url\x22:\x22https://upload.wikimedia.org/wiktionary/sd/e/e2/antenna.jpg?utm_source=sd.wiktionary.o" ++
    "rg&utm_campaign=imageinfo&utm_content=original\x22,\x22descriptionurl\x22:\x22https://sd.wiktionary.org/wiki" ++
    "/%D9%81%D8%A7%D8%A6%D9%84:antenna.jpg\x22,\x22descriptionshorturl\x22:\x22https://sd.wiktionary.org/wiki/Spe" ++
    "cial:Redirect/page/2276\x22,\x22extmetadata\x22:{\x22DateTime\x22:{\x22value\x22:\x222006-04-19 22:26:32\x22,\x22source\x22:\x22medi" ++
    "awiki-metadata\x22,\x22hidden\x22:\x22\x22},\x22ObjectName\x22:{\x22value\x22:\x22antenna\x22,\x22source\x22:\x22mediawiki-metadata\x22},\x22Com" ++
    "monsMetadataExtension\x22:{\x22value\x22:1.2,\x22source\x22:\x22extension\x22,\x22hidden\x22:\x22\x22},\x22Categories\x22:{\x22value\x22:\x22Fil" ++
    "es with no machine-readable author|Files with no machine-readable description|Files with no mach" ++
    "ine-readable license|Files with no machine-readable source\x22,\x22source\x22:\x22commons-categories\x22,\x22hidde" ++
    "n\x22:\x22\x22},\x22Assessments\x22:{\x22value\x22:\x22\x22,\x22source\x22:\x22commons-categories\x22,\x22hidden\x22:\x22\x22},\x22Restrictions\x22:{\x22val" ++
    "ue\x22:\x22\x22,\x22source\x22:\x22commons-desc-page\x22,\x22hidden\x22:\x22\x22}},\x22mime\x22:\x22image/jpeg\x22}]}]}}";
const retained_commons_response =
    "{\x22continue\x22:{\x22iistart\x22:\x222019-06-28T13:46:03Z\x22,\x22continue\x22:\x22||\x22},\x22query\x22:{\x22normalized\x22:[{\x22fromenco" ++
    "ded\x22:false,\x22from\x22:\x22File:antenna.jpg\x22,\x22to\x22:\x22File:Antenna.jpg\x22}],\x22pages\x22:[{\x22pageid\x22:1642466,\x22ns\x22:6" ++
    ",\x22title\x22:\x22File:Antenna.jpg\x22,\x22imagerepository\x22:\x22local\x22,\x22imageinfo\x22:[{\x22size\x22:2854153,\x22width\x22:1863," ++
    "\x22height\x22:2532,\x22thumburl\x22:\x22https://thumb.wikimedia.org/wikipedia/commons/thumb/7/76/Antenna.jpg/9" ++
    "60px-Antenna.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail\x22," ++
    "\x22thumbwidth\x22:960,\x22thumbheight\x22:1305,\x22responsiveUrls\x22:{\x222\x22:\x22https://upload.wikimedia.org/wikipedi" ++
    "a/commons/7/76/Antenna.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=t" ++
    "humbnail_unscaled\x22},\x22thumbattribs\x22:{\x22src\x22:\x22https://thumb.wikimedia.org/wikipedia/commons/thumb/7" ++
    "/76/Antenna.jpg/960px-Antenna.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_co" ++
    "ntent=thumbnail\x22,\x22decoding\x22:\x22async\x22,\x22loading\x22:\x22lazy\x22,\x22width\x22:960,\x22height\x22:1305,\x22srcset\x22:\x22https:/" ++
    "/upload.wikimedia.org/wikipedia/commons/7/76/Antenna.jpg?utm_source=commons.wikimedia.org&utm_ca" ++
    "mpaign=imageinfo&utm_content=thumbnail_unscaled 2x\x22},\x22url\x22:\x22https://upload.wikimedia.org/wikiped" ++
    "ia/commons/7/76/Antenna.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=" ++
    "original\x22,\x22descriptionurl\x22:\x22https://commons.wikimedia.org/wiki/File:Antenna.jpg\x22,\x22descriptionsho" ++
    "rturl\x22:\x22https://commons.wikimedia.org/wiki/Special:Redirect/page/1642466\x22,\x22extmetadata\x22:{\x22DateTi" ++
    "me\x22:{\x22value\x22:\x222019-10-03 15:32:13\x22,\x22source\x22:\x22mediawiki-metadata\x22,\x22hidden\x22:\x22\x22},\x22ObjectName\x22:{\x22val" ++
    "ue\x22:\x22Antenna\x22,\x22source\x22:\x22mediawiki-metadata\x22},\x22CommonsMetadataExtension\x22:{\x22value\x22:1.2,\x22source\x22:\x22e" ++
    "xtension\x22,\x22hidden\x22:\x22\x22},\x22Categories\x22:{\x22value\x22:\x22Yagi-Uda antennas|GFDL|License migration redundant" ++
    "|Self-published work|Terrestrial television receiving antennas\x22,\x22source\x22:\x22commons-categories\x22,\x22h" ++
    "idden\x22:\x22\x22},\x22Assessments\x22:{\x22value\x22:\x22\x22,\x22source\x22:\x22commons-categories\x22,\x22hidden\x22:\x22\x22},\x22ImageDescriptio" ++
    "n\x22:{\x22value\x22:\x22<a href=\x5c\x22https://en.wikipedia.org/wiki/Television_antenna\x5c\x22 class=\x5c\x22extiw\x5c\x22 title=" ++
    "\x5c\x22wikipedia:Television antenna\x5c\x22>Television antennas</a>.  These six antennas are of a type call" ++
    "ed a <a href=\x5c\x22https://en.wikipedia.org/wiki/Yagi-Uda_antenna\x5c\x22 class=\x5c\x22extiw\x5c\x22 title=\x5c\x22en:Yagi-" ++
    "Uda antenna\x5c\x22>Yagi-Uda antenna</a>, widely used for television reception at VHF and UHF frequenc" ++
    "ies.  They consist of a series of parallel metal rods. One pair of rods, called the <i>driven el" ++
    "ement</i>, collects the radio waves and is attached to a cable that conducts the television sign" ++
    "al to the television.  The other rods, called <i>parasitic elements</i>, serve to increase the s" ++
    "ensitivity of the antenna to signals coming from a particular direction.\x22,\x22source\x22:\x22commons-desc" ++
    "-page\x22},\x22DateTimeOriginal\x22:{\x22value\x22:\x222007-02-05\x22,\x22source\x22:\x22commons-desc-page\x22},\x22Credit\x22:{\x22value\x22" ++
    ":\x22<span class=\x5c\x22int-own-work\x5c\x22 lang=\x5c\x22en\x5c\x22>Own work</span>\x22,\x22source\x22:\x22commons-desc-page\x22},\x22Artis" ++
    "t\x22:{\x22value\x22:\x22<a href=\x5c\x22//commons.wikimedia.org/wiki/User:Yonatanh\x5c\x22 title=\x5c\x22User:Yonatanh\x5c\x22>Yona" ++
    "tan Horan</a>\x22,\x22source\x22:\x22commons-desc-page\x22},\x22LicenseShortName\x22:{\x22value\x22:\x22CC BY 2.5\x22,\x22source\x22:\x22c" ++
    "ommons-desc-page\x22,\x22hidden\x22:\x22\x22},\x22UsageTerms\x22:{\x22value\x22:\x22Creative Commons Attribution 2.5\x22,\x22source\x22" ++
    ":\x22commons-desc-page\x22},\x22AttributionRequired\x22:{\x22value\x22:\x22true\x22,\x22source\x22:\x22commons-desc-page\x22,\x22hidden" ++
    "\x22:\x22\x22},\x22LicenseUrl\x22:{\x22value\x22:\x22https://creativecommons.org/licenses/by/2.5\x22,\x22source\x22:\x22commons-desc" ++
    "-page\x22},\x22Copyrighted\x22:{\x22value\x22:\x22True\x22,\x22source\x22:\x22commons-desc-page\x22,\x22hidden\x22:\x22\x22},\x22Restrictions\x22:{" ++
    "\x22value\x22:\x22\x22,\x22source\x22:\x22commons-desc-page\x22,\x22hidden\x22:\x22\x22},\x22License\x22:{\x22value\x22:\x22cc-by-2.5\x22,\x22source\x22:\x22co" ++
    "mmons-templates\x22,\x22hidden\x22:\x22\x22}},\x22mime\x22:\x22image/jpeg\x22}]}]}}";

test "retained SD ImageInfo binds local lowercase file and refuses the Commons collision" {
    const Exp = struct { bytes: []const u8, sha256: []const u8 };
    for ([_]Exp{
        .{ .bytes = retained_sd_response, .sha256 = "a9ba249d00aeee89547b971a5bfaf09b1917aa9f8a07e0859cbf8b498be01e9b" },
        .{ .bytes = retained_commons_response, .sha256 = "506a9ab84e6a7849bfbbe2589dc92ba7d7ea321d1d10ea8eee7888068770cd24" },
    }) |fixture| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fixture.bytes, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        try std.testing.expectEqualStrings(fixture.sha256, &hex);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try Source.fromScope(a, "sdwiktionary-20261001");
    const requested = "File:antenna.jpg";
    // Captures lacked siteinfo; these constructed envelopes exercise only
    // parser binding. They are not a capture of the combined request.
    const query = "\"query\":{";
    const sd_siteinfo = query ++ "\"general\":{\"wikiid\":\"sdwiktionary\"},";
    const commons_siteinfo = query ++ "\"general\":{\"wikiid\":\"commonswiki\"},";
    const wrapped_sd = try std.mem.replaceOwned(u8, a, retained_sd_response, query, sd_siteinfo);
    const wrapped_commons = try std.mem.replaceOwned(u8, a, retained_commons_response, query, commons_siteinfo);
    const misattributed_commons = try std.mem.replaceOwned(u8, a, retained_commons_response, query, sd_siteinfo);
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, retained_sd_response, source, requested));
    const local = (try mediaLocation(a, wrapped_sd, source, requested)).?;
    try std.testing.expectEqual(Repository.local, local.repository.?);
    try std.testing.expectEqualStrings("فائل:antenna.jpg", local.title);
    try std.testing.expectEqualStrings("https://upload.wikimedia.org/wiktionary/sd/e/e2/antenna.jpg?utm_source=sd.wiktionary.org&utm_campaign=imageinfo&utm_content=original", local.url);
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, wrapped_commons, source, requested));
    try std.testing.expectError(error.InvalidMediaResponse, mediaLocation(a, misattributed_commons, source, requested));
}

test "canonical image rejects missing and invalid editions before external actions or cache access" {
    const Command = struct {
        fn execute(_: std.Io, _: A, _: []const []const u8) ![]u8 {
            return error.UnexpectedExternalCommand;
        }
    };
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);

    try openWithCommandMustRefuseScope(Command.execute, io, a, root, null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".dict-media", .{}));

    // A zero budget would remove this cached file if retention ran first.
    try tmp.dir.createDirPath(io, cache_subdirectory);
    const cached = cache_subdirectory ++ "/cached.jpg";
    try tmp.dir.writeFile(io, .{ .sub_path = cached, .data = "existing-versioned-cache" });
    for ([_]?[]const u8{ null, "", "English", "sdwiktionary-20260229" }) |scope|
        try openWithCommandMustRefuseScope(Command.execute, io, a, root, scope);
    const still_cached = try tmp.dir.readFileAlloc(io, cached, a, .limited(64));
    defer a.free(still_cached);
    try std.testing.expectEqualStrings("existing-versioned-cache", still_cached);
}

fn openWithCommandMustRefuseScope(comptime execute: anytype, io: std.Io, a: A, root: []const u8, scope: ?[]const u8) !void {
    try std.testing.expectError(error.InvalidEditionScope, openWithCommand(execute, io, a, root, scope, "needle.jpg", true, 0));
}
