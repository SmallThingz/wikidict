//! Explicit bounded Wikimedia acquisition. Renderers never access the network.
const std = @import("std");
const types = @import("media_types");
const enc = @import("encoder");
const A = std.mem.Allocator;
fn run(io: std.Io, a: A, args: []const []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = args, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(256 * 1024), .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(90), .clock = .awake } }).toDeadline(io) });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("media fetch: {s}\n", .{result.stderr});
        return error.MediaFetchFailed;
    }
    return result.stdout;
}
fn field(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(key) orelse return "";
    if (item != .object) return "";
    const text = item.object.get("value") orelse return "";
    return if (text == .string) text.string else "";
}
fn plain(a: A, input: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < input.len) : (pos += 1) {
        if (input[pos] == '<') {
            const end = std.mem.indexOfScalarPos(u8, input, pos, '>') orelse {
                try bytes.append(a, input[pos]);
                continue;
            };
            pos = end;
            continue;
        }
        try bytes.append(a, input[pos]);
    }
    return enc.xml_decode.decodeSinglePassAlloc(a, bytes.items);
}
fn fetch(io: std.Io, a: A, root: []const u8, file: []const u8) !void {
    const id = types.key(file);
    const meta_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ root, id });
    const data_path = try std.fmt.allocPrint(a, "{s}/{s}.bin", .{ root, id });
    var info: ?std.json.Value = null;
    var response: []const u8 = "";
    for ([_][]const u8{ "https://commons.wikimedia.org/w/api.php", "https://en.wiktionary.org/w/api.php" }) |api| {
        response = try run(io, a, &.{ "/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "40", "--retry", "2", "--retry-delay", "2", "--get", api, "--data-urlencode", "action=query", "--data-urlencode", "format=json", "--data-urlencode", "formatversion=2", "--data-urlencode", "prop=imageinfo", "--data-urlencode", "iiprop=url|mime|extmetadata", "--data-urlencode", "iiurlwidth=800", "--data-urlencode", try std.fmt.allocPrint(a, "titles=File:{s}", .{file}), "-A", "dict-local/0.1 (offline attributed media export)" });
        const data = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        const query = data.value.object.get("query") orelse return error.InvalidMediaResponse;
        const pages = query.object.get("pages") orelse return error.InvalidMediaResponse;
        if (pages.array.items.len != 1) return error.InvalidMediaResponse;
        const records = pages.array.items[0].object.get("imageinfo") orelse continue;
        if (records.array.items.len == 0) continue;
        info = records.array.items[0];
        break;
    }
    const image = info orelse return error.MediaNotFound;
    const metadata = image.object.get("extmetadata") orelse return error.NoMediaLicense;
    const license = field(metadata, "LicenseShortName");
    var license_url = field(metadata, "LicenseUrl");
    const gfdl = std.mem.eql(u8, license, "GFDL 1.2");
    var license_text: ?[]const u8 = null;
    if (gfdl) {
        license_url = "https://www.gnu.org/licenses/old-licenses/fdl-1.2.html";
        license_text = try run(io, a, &.{ "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "40", "https://www.gnu.org/licenses/old-licenses/fdl-1.2.txt" });
        if (std.mem.indexOf(u8, license_text.?, "GNU Free Documentation License") == null or std.mem.indexOf(u8, license_text.?, "Version 1.2") == null) return error.InvalidLicenseDocument;
    }
    const permitted = gfdl or std.mem.startsWith(u8, license, "CC BY") or std.mem.startsWith(u8, license, "CC0") or std.ascii.eqlIgnoreCase(license, "Public domain");
    if (!permitted) {
        std.debug.print("Unsupported media license for {s}: {s}\n", .{ file, license });
        return error.UnsupportedMediaLicense;
    }
    const is_image = types.kind(file) == .image;
    var url = (if (is_image and !gfdl) image.object.get("thumburl") orelse image.object.get("url").? else image.object.get("url").?).string;
    // Official imageinfo can return a Wikimedia thumbnail-rendering endpoint.
    if (std.mem.startsWith(u8, url, "//")) url = try std.fmt.allocPrint(a, "https:{s}", .{url});
    const trusted = std.mem.startsWith(u8, url, "https://thumb.wikimedia.org/") or std.mem.startsWith(u8, url, "https://upload.wikimedia.org/") or std.mem.startsWith(u8, url, "https://commons.wikimedia.org/w/thumb.php?") or std.mem.startsWith(u8, url, "https://en.wiktionary.org/w/thumb.php?");
    if (!trusted) {
        std.debug.print("Rejected media URL: {s}\n", .{url});
        return error.InvalidMediaHost;
    }
    const temporary = try std.fmt.allocPrint(a, "{s}/.download-{d}", .{ root, std.os.linux.getpid() });
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    _ = try run(io, a, &.{ "/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "40", "--retry", "2", "--location", "--max-redirs", "3", "--proto", "=https", "--proto-redir", "=https", "--max-filesize", "16777216", "--output", temporary, url, "-A", "dict-local/0.1 (offline attributed media export)" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, temporary, a, .limited(16 * 1024 * 1024));
    const mime = types.mime(bytes) orelse return error.UnsupportedMedia;
    if (!std.mem.startsWith(u8, mime, if (is_image) "image/" else "audio/")) return error.MediaTypeMismatch;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const credit = try plain(a, if (field(metadata, "Attribution").len != 0) field(metadata, "Attribution") else field(metadata, "Artist"));
    const source_url = image.object.get("descriptionurl").?.string;
    if (credit.len == 0) return error.NoMediaAuthor;
    const meta: types.Metadata = .{ .file = file, .mime = mime, .sha256 = &std.fmt.bytesToHex(hash, .lower), .author = credit, .license = license, .license_url = license_url, .source_url = source_url, .license_text = license_text };
    const text = try std.json.Stringify.valueAlloc(a, meta, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), data_path, io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = meta_path, .data = text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.provenance.json", .{ root, id }), .data = response });
    std.debug.print("MEDIA {s} bytes={d} type={s} license={s}\n", .{ file, bytes.len, mime, license });
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) {
        std.debug.print("usage: fetch-media -- DICT_RESULTS_JSON MEDIA_DIRECTORY\n", .{});
        return error.Usage;
    }
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(32 * 1024 * 1024));
    const data = try std.json.parseFromSlice(std.json.Value, a, input, .{});
    if (!std.mem.eql(u8, data.value.object.get("schema").?.string, "dict.results.v1")) return error.InvalidResults;
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    var seen = std.StringHashMap(void).init(a);
    var count: usize = 0;
    for (data.value.object.get("entries").?.array.items) |entry| if (entry.object.get("media")) |items| for (items.array.items) |item| {
        const file = item.object.get("file").?.string;
        if (file.len == 0 or file.len > 4096 or types.kind(file) == null) return error.InvalidMedia;
        const slot = try seen.getOrPut(file);
        if (slot.found_existing) continue;
        if (count >= 128) return error.MediaLimit;
        try fetch(init.io, a, args[2], file);
        count += 1;
    };
    std.debug.print("MEDIA_COMPLETE={d}\n", .{count});
}
