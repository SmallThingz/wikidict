//! Explicit catalogue downloads and atomic installation of compiled dictionaries.
const std = @import("std");
const storage = @import("blob_storage");
const store = @import("store.zig");
const output = @import("output.zig");
const A = std.mem.Allocator;
pub const default_source = "https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list";
fn run(io: std.Io, a: A, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(2 * 1024 * 1024), .stderr_limit = .limited(8192) });
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        a.free(result.stdout);
        return error.DownloadFailed;
    }
    return result.stdout;
}
pub fn catalog(io: std.Io, a: A, url: []const u8, w: *std.Io.Writer) !void {
    const source = if (url.len == 0) default_source else url;
    if (!std.mem.startsWith(u8, source, "https://")) return error.HttpsRequired;
    const text = try run(io, a, &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "60", "--max-filesize", "2097152", source });
    defer a.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const link = fields.next().?;
        if (!std.mem.startsWith(u8, link, "https://")) return error.InvalidCatalog;
        const label = fields.next() orelse link;
        const size = fields.next();
        const hash = fields.next();
        if (fields.next() != null) return error.InvalidCatalog;
        if (size) |n| if (n.len != 0) {
            _ = try std.fmt.parseInt(u64, n, 10);
        };
        if (hash) |h| if (h.len != 0) {
            if (h.len != 64) return error.InvalidCatalog;
            var buf: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&buf, h);
        };
        try output.terminalText(w, label);
        try w.writeByte('\n');
        try output.terminalText(w, link);
        try w.writeByte('\n');
        if (hash) |h| {
            try w.writeAll("SHA-256: ");
            try output.terminalText(w, h);
            try w.writeByte('\n');
        }
        count += 1;
        if (count > 10000) return error.InvalidCatalog;
    }
}
pub fn install(io: std.Io, a: A, root: []const u8, input: []const u8, expected: []const u8, w: *std.Io.Writer) !void {
    if (input.len == 0) return error.Usage;
    try std.Io.Dir.cwd().createDirPath(io, root);
    const temporary = try std.fmt.allocPrint(a, "{s}/.install-{d}.part", .{ root, std.os.linux.getpid() });
    defer a.free(temporary);
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    if (std.mem.startsWith(u8, input, "https://")) {
        const response = try run(io, a, &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "3600", "--max-filesize", "34359738368", "--output", temporary, input });
        a.free(response);
    } else {
        if (std.mem.indexOf(u8, input, "://") != null) return error.HttpsRequired;
        try std.Io.Dir.cwd().copyFile(input, .cwd(), temporary, io, .{});
    }
    var file = try storage.File.open(io, a, temporary);
    defer file.deinit();
    const cache_path = try std.fmt.allocPrint(a, "{s}/.dict-cache/{s}.idx", .{ root, std.fs.path.basename(temporary) });
    defer a.free(cache_path);
    defer std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    if (expected.len != 0) {
        var wanted: [32]u8 = undefined;
        if (expected.len != 64) return error.InvalidChecksum;
        _ = try std.fmt.hexToBytes(&wanted, expected);
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file.bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &wanted)) return error.ChecksumMismatch;
    }
    if (file.recordCount() == 0) return error.EmptyDictionary;
    for (0..file.recordCount()) |i| {
        var record = try file.readAlloc(a, i);
        defer record.deinit();
        if (!std.mem.startsWith(u8, record.payload, "DPR2")) return error.UncompiledDictionary;
    }
    const kind = file.view.kind;
    const heading = if (kind == .language) (try file.view.languageMetadata()).heading else "";
    const raw_path = try store.pathAlloc(a, root, kind, heading);
    defer a.free(raw_path);
    const destination = if (file.compressed != null) try std.mem.concat(a, u8, &.{ raw_path, ".xz" }) else try a.dupe(u8, raw_path);
    defer a.free(destination);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(destination).?);
    try std.Io.Dir.cwd().rename(temporary, .cwd(), destination, io);
    const obsolete = if (file.compressed != null) try a.dupe(u8, raw_path) else try std.mem.concat(a, u8, &.{ raw_path, ".xz" });
    defer a.free(obsolete);
    std.Io.Dir.cwd().deleteFile(io, obsolete) catch {};
    if (kind == .language) {
        const manifest = try std.fs.path.join(a, &.{ root, "languages.tsv" });
        defer a.free(manifest);
        const prior = std.Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try a.dupe(u8, "heading\n"),
            else => return err,
        };
        defer a.free(prior);
        if (try store.catalog.find(prior, heading) == null) {
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            try text.writer.writeAll(prior);
            if (!std.mem.endsWith(u8, prior, "\n")) try text.writer.writeByte('\n');
            try store.catalog.writeEntry(&text.writer, heading);
            const temp_manifest = try std.mem.concat(a, u8, &.{ manifest, ".part" });
            defer a.free(temp_manifest);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_manifest, .data = text.written() });
            try std.Io.Dir.cwd().rename(temp_manifest, .cwd(), manifest, io);
        }
    }
    try w.print("Installed {d} words: ", .{file.recordCount()});
    try output.terminalText(w, destination);
    try w.writeByte('\n');
}
