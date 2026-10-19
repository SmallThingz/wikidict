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

// The release filename carries acquisition scope; the blob carries its language.
// Keep the shared desktop marker so one root cannot mix otherwise identical headings.
const edition_marker = ".desktop-edition";

fn validEditionScope(scope: []const u8) bool {
    if (scope.len < "awiktionary-20000101".len or scope.len > 200) return false;
    const split = scope.len - 9;
    if (scope[split] != '-') return false;
    const wiki = scope[0..split];
    if (!std.mem.endsWith(u8, wiki, "wiktionary") or wiki[0] < 'a' or wiki[0] > 'z') return false;
    for (wiki) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    const date = scope[split + 1 ..];
    for (date) |c| if (!std.ascii.isDigit(c)) return false;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, date[4..6], 10) catch return false;
    const day = std.fmt.parseInt(u8, date[6..8], 10) catch return false;
    if (year == 0 or month < 1 or month > 12 or day < 1) return false;
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap: u8 = if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 1 else 0;
    return day <= lengths[month - 1] + leap;
}
fn inputBasename(input: []const u8) []const u8 {
    const end = if (std.mem.startsWith(u8, input, "https://")) (std.mem.indexOfAny(u8, input, "?#") orelse input.len) else input.len;
    return std.fs.path.basename(input[0..end]);
}
fn acquisitionScope(input: []const u8) !?[]const u8 {
    var name = inputBasename(input);
    if (std.mem.endsWith(u8, name, ".xz")) name = name[0 .. name.len - 3];
    if (!std.mem.endsWith(u8, name, ".wikblb")) return null;
    name = name[0 .. name.len - ".wikblb".len];
    // sign-gloss is the only published suffix containing a hyphen.
    const split = if (std.mem.endsWith(u8, name, "-sign-gloss"))
        name.len - "-sign-gloss".len
    else
        std.mem.lastIndexOfScalar(u8, name, '-') orelse return null;
    const suffix = name[split + 1 ..];
    var published_suffix = suffix.len == 64;
    if (published_suffix) {
        for (suffix) |c| {
            if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) {
                published_suffix = false;
                break;
            }
        }
    }
    inline for (.{ "aliases", "supplemental", "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss" }) |feature| {
        if (std.mem.eql(u8, suffix, feature)) published_suffix = true;
    }
    if (!published_suffix) return null;
    const scope = name[0..split];
    // Ordinary local names remain unscoped, even if their suffix resembles a feature.
    if (std.mem.indexOf(u8, scope, "wiktionary-") == null) return null;
    if (!validEditionScope(scope)) return error.InvalidEditionScope;
    return scope;
}
fn installedEditionScope(io: std.Io, a: A, root: []const u8) !?[]u8 {
    const marker = try std.fs.path.join(a, &.{ root, edition_marker });
    defer a.free(marker);
    const marker_bytes = std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (marker_bytes) |bytes| a.free(bytes);
    var marked: ?[]u8 = null;
    errdefer if (marked) |scope| a.free(scope);
    if (marker_bytes) |bytes| {
        const value = std.mem.trim(u8, bytes, " \r\n\t");
        if (!validEditionScope(value)) return error.InvalidEditionScope;
        marked = try a.dupe(u8, value);
    }
    const complete = try std.fs.path.join(a, &.{ root, "complete.json" });
    defer a.free(complete);
    const complete_bytes = std.Io.Dir.cwd().readFileAlloc(io, complete, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return marked,
        else => return err,
    };
    defer a.free(complete_bytes);
    const Completion = struct { edition: []const u8, date: []const u8 };
    const parsed = std.json.parseFromSlice(Completion, a, complete_bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEditionScope,
    };
    defer parsed.deinit();
    const completed = try std.fmt.allocPrint(a, "{s}-{s}", .{ parsed.value.edition, parsed.value.date });
    if (!validEditionScope(completed)) {
        a.free(completed);
        return error.InvalidEditionScope;
    }
    if (marked) |scope| {
        defer a.free(completed);
        if (!std.mem.eql(u8, scope, completed)) return error.InvalidEditionScope;
        return scope;
    }
    return completed;
}
fn hasUnscopedBlobs(io: std.Io, a: A, root: []const u8) !bool {
    const languages = try std.fs.path.join(a, &.{ root, store.catalog.language_directory });
    defer a.free(languages);
    for ([_][]const u8{ root, languages }) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".wikblb") or std.mem.endsWith(u8, entry.name, ".wikblb.xz")) return true;
        }
    }
    return false;
}

fn checkEditionScope(io: std.Io, a: A, root: []const u8, incoming: ?[]const u8) !?[]u8 {
    const installed = try installedEditionScope(io, a, root);
    errdefer if (installed) |scope| a.free(scope);
    if (installed) |scope| {
        if (incoming == null or !std.mem.eql(u8, scope, incoming.?)) return error.EditionScopeMismatch;
    } else if (incoming != null and try hasUnscopedBlobs(io, a, root)) return error.EditionScopeMismatch;
    return installed;
}

// Failed staging and ordinary cancellation must not strand owned partial files.
fn removeOwned(io: std.Io, path: []const u8) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("dict: could not remove installation staging file {s}: {s}\n", .{ path, @errorName(err) }),
    };
}
const InstallTransaction = struct {
    io: std.Io,
    destination: []const u8,
    obsolete: []const u8,
    previous: []const u8,
    manifest: ?[]const u8 = null,
    manifest_part: ?[]const u8 = null,
    previous_manifest: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    edition_part: ?[]const u8 = null,
    edition_published: bool = false,
    had_destination: bool = false,
    had_manifest: bool = false,
    installed: bool = false,
    manifest_published: bool = false,

    fn requireAbsent(self: InstallTransaction, path: []const u8) !void {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return error.InstallRecoveryRequired;
    }
    fn moveAside(self: InstallTransaction, from: []const u8, to: []const u8) !bool {
        std.Io.Dir.cwd().rename(from, .cwd(), to, self.io) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    fn publish(self: *InstallTransaction, temporary: []const u8) !void {
        self.had_destination = try self.moveAside(self.destination, self.previous);
        try std.Io.Dir.cwd().rename(temporary, .cwd(), self.destination, self.io);
        self.installed = true;
        if (self.manifest_part) |part| {
            self.had_manifest = try self.moveAside(self.manifest.?, self.previous_manifest.?);
            try std.Io.Dir.cwd().rename(part, .cwd(), self.manifest.?, self.io);
            self.manifest_published = true;
        }
        if (self.edition_part) |part| {
            try std.Io.Dir.cwd().rename(part, .cwd(), self.edition.?, self.io);
            self.edition_published = true;
        }
        // Keep the opposite raw/xz file until the new metadata is published.
        std.Io.Dir.cwd().deleteFile(self.io, self.obsolete) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    fn rollback(self: *InstallTransaction) !void {
        var failed = false;
        if (self.edition_published) {
            std.Io.Dir.cwd().deleteFile(self.io, self.edition.?) catch {
                failed = true;
            };
        }
        if (self.had_manifest) {
            std.Io.Dir.cwd().rename(self.previous_manifest.?, .cwd(), self.manifest.?, self.io) catch {
                failed = true;
            };
        } else if (self.manifest_published) {
            std.Io.Dir.cwd().deleteFile(self.io, self.manifest.?) catch {
                failed = true;
            };
        }
        if (self.had_destination) {
            std.Io.Dir.cwd().rename(self.previous, .cwd(), self.destination, self.io) catch {
                failed = true;
            };
        } else if (self.installed) {
            std.Io.Dir.cwd().deleteFile(self.io, self.destination) catch {
                failed = true;
            };
        }
        if (failed) return error.InstallRollbackFailed;
    }
    fn commit(self: *InstallTransaction, temporary: []const u8) !void {
        // Only the short rename/rollback phase is protected. Download, copy,
        // decoding, manifest preparation and lock acquisition remain cancelable.
        try self.io.checkCancel();
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        try self.requireAbsent(self.previous);
        if (self.previous_manifest) |path| try self.requireAbsent(path);
        if (self.edition) |path| try self.requireAbsent(path);
        self.publish(temporary) catch |err| {
            self.rollback() catch {
                // Never delete a backup which may now be the only original copy.
                std.debug.print("dict: installation recovery needed; retain {s} and {s}\n", .{
                    self.previous, self.previous_manifest orelse "(no manifest backup)",
                });
                return error.InstallRollbackFailed;
            };
            return err;
        };
        // Filesystem commit succeeded. Failed backup cleanup is a warning,
        // not a failed install which misleadingly implies the old data survived.
        if (self.had_destination) removeOwned(self.io, self.previous);
        if (self.had_manifest) removeOwned(self.io, self.previous_manifest.?);
    }
};
fn reportInstalled(w: *std.Io.Writer, count: usize, destination: []const u8) !void {
    w.print("Installed {d} words: ", .{count}) catch return error.InstallReportFailed;
    output.terminalText(w, destination) catch return error.InstallReportFailed;
    w.writeByte('\n') catch return error.InstallReportFailed;
    w.flush() catch return error.InstallReportFailed;
}

pub fn install(io: std.Io, a: A, root: []const u8, input: []const u8, expected: []const u8, w: *std.Io.Writer) !void {
    if (input.len == 0) return error.Usage;
    const incoming_scope = try acquisitionScope(input);
    try @import("blob_files").requireComplete(io, a, root);
    // Fail known conflicts before downloading or copying a potentially large asset.
    const early_scope = try checkEditionScope(io, a, root, incoming_scope);
    if (early_scope) |scope| a.free(scope);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const temporary = try std.fmt.allocPrint(a, "{s}/.install-{d}.part", .{ root, std.os.linux.getpid() });
    defer a.free(temporary);
    defer removeOwned(io, temporary);
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
    const kind = file.view.kind;
    if (file.recordCount() == 0 and kind == .language) return error.EmptyDictionary;
    const view = try @import("blob_decoder").openTrustedBlob(file.directory.header);
    for (0..file.recordCount()) |i| {
        var record = try file.readAlloc(a, i);
        defer record.deinit();
        var decoded = @import("model.zig").fromRecord(a, view.wrapRecord(.{
            .title = record.title,
            .payload = record.payload,
        })) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.UncompiledDictionary,
        };
        decoded.deinit();
    }
    const heading = if (kind == .language) (try file.view.languageMetadata()).heading else "";
    if (incoming_scope) |scope| {
        var name_buffer: [store.catalog.language_blob_filename_len]u8 = undefined;
        const suffix = if (kind == .language) store.catalog.languageBlobFilename(heading, &name_buffer) else store.catalog.featureBlobFilename(kind).?;
        const expected_name = try std.fmt.allocPrint(a, "{s}-{s}{s}", .{ scope, suffix, if (file.compressed != null) ".xz" else "" });
        defer a.free(expected_name);
        if (!std.mem.eql(u8, inputBasename(input), expected_name)) return error.InvalidEditionScope;
    }
    const raw_path = try store.pathAlloc(a, root, kind, heading);
    defer a.free(raw_path);
    const destination = if (file.compressed != null) try std.mem.concat(a, u8, &.{ raw_path, ".xz" }) else try a.dupe(u8, raw_path);
    defer a.free(destination);
    const obsolete = if (file.compressed != null) try a.dupe(u8, raw_path) else try std.mem.concat(a, u8, &.{ raw_path, ".xz" });
    defer a.free(obsolete);
    const previous = try std.mem.concat(a, u8, &.{ temporary, ".previous" });
    defer a.free(previous);
    const manifest = try std.fs.path.join(a, &.{ root, "languages.tsv" });
    defer a.free(manifest);
    const manifest_part = try std.mem.concat(a, u8, &.{ temporary, ".manifest.part" });
    defer a.free(manifest_part);
    defer removeOwned(io, manifest_part);
    const previous_manifest = try std.mem.concat(a, u8, &.{ temporary, ".manifest.previous" });
    defer a.free(previous_manifest);
    const lock_path = try std.fs.path.join(a, &.{ root, ".dict-install.lock" });
    defer a.free(lock_path);
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    try @import("blob_files").requireComplete(io, a, root);
    const installed_scope = try checkEditionScope(io, a, root, incoming_scope);
    defer if (installed_scope) |scope| a.free(scope);
    const scope_path = try std.fs.path.join(a, &.{ root, edition_marker });
    defer a.free(scope_path);
    const scope_part = try std.mem.concat(a, u8, &.{ temporary, ".edition.part" });
    defer a.free(scope_part);
    defer removeOwned(io, scope_part);
    const publish_scope = incoming_scope != null and installed_scope == null;
    if (publish_scope) {
        const text = try std.fmt.allocPrint(a, "{s}\n", .{incoming_scope.?});
        defer a.free(text);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scope_part, .data = text });
    }
    var publish_manifest = false;
    if (kind == .language) {
        const prior = std.Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try a.dupe(u8, "heading\n"),
            else => return err,
        };
        defer a.free(prior);
        // Validate the whole existing catalogue before replacing any dictionary.
        if (try store.catalog.find(prior, heading) == null) {
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            try text.writer.writeAll(prior);
            if (!std.mem.endsWith(u8, prior, "\n")) try text.writer.writeByte('\n');
            try store.catalog.writeEntry(&text.writer, heading);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_part, .data = text.written() });
            publish_manifest = true;
        }
    } else if (kind == .alias) {
        var prior = std.Io.Dir.cwd().openFile(io, manifest, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (prior) |*file_handle| {
            file_handle.close(io);
        } else {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_part, .data = store.catalog.manifest_header ++ "\n" });
            publish_manifest = true;
        }
    }
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(destination).?);
    var transaction: InstallTransaction = .{
        .io = io,
        .destination = destination,
        .obsolete = obsolete,
        .previous = previous,
        .manifest = if (publish_manifest) manifest else null,
        .manifest_part = if (publish_manifest) manifest_part else null,
        .previous_manifest = if (publish_manifest) previous_manifest else null,
        .edition = if (publish_scope) scope_path else null,
        .edition_part = if (publish_scope) scope_part else null,
    };
    try transaction.commit(temporary);
    // Output failure after this point does not undo a committed installation.
    try reportInstalled(w, file.recordCount(), destination);
}

test "installer accepts internal compiled aliases and empty feature framing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const enc = @import("blob_encoder");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/installed", .{tmp.sub_path});
    const source = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/input.wikblb", .{tmp.sub_path});
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    const presentation = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{ .title = "A", .kind = .alias } });
    var alias: enc.alias_codec.Record = .{
        .source_namespace = 0,
        .source_kind = .language,
        .source_title = "A",
        .source_key = "A",
        .xml_target = "B",
        .target_title = "B",
        .target_namespace = 0,
        .target_kind = .language,
        .target_key = "B",
        .fragment = "",
        .presentation = presentation,
    };
    const payload = try enc.alias_codec.encodeAlloc(fixture, alias);
    const bytes = try enc.blob_format.buildAlloc(fixture, .alias, "", &.{.{ .title = "1\tA", .payload = payload }});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = bytes });
    try install(io, a, root, source, "", &log.writer);
    const alias_path = try store.pathAlloc(fixture, root, .alias, "");
    {
        var file = try storage.File.open(io, a, alias_path);
        defer file.deinit();
        try std.testing.expectEqual(enc.blob_format.BlobKind.alias, file.view.kind);
        try std.testing.expectEqual(@as(usize, 1), file.recordCount());
    }
    const manifest = try std.fs.path.join(fixture, &.{ root, store.catalog.manifest_filename });
    try expectInstallBytes(io, a, manifest, store.catalog.manifest_header ++ "\n");
    {
        var db = try store.Store.open(io, a, root, .language, "English");
        defer db.deinit();
        try std.testing.expect(db.neutral_main);
        try std.testing.expect(db.heading() == null);
        try std.testing.expectEqual(@as(usize, 1), db.count());
        const label = try db.labelAlloc(a);
        defer a.free(label);
        try std.testing.expectEqualStrings("Redirects", label);
        var raw = try db.recordAlloc(a, (try db.find("A")).?);
        defer raw.deinit();
        var doc = try @import("model.zig").fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings("A", doc.entry.title);
        try std.testing.expect(doc.entry.language == null);
        try std.testing.expectEqualStrings("B", doc.entry.redirect.?.target_title);
        try std.testing.expect(!doc.entry.redirect.?.followed);
    }
    // Installing aliases into an existing root must not rewrite its catalogue,
    // including an invalid catalogue whose repair is a separate operation.
    for ([_][]const u8{ "heading\nEnglish\n", "heading\n\n" }) |prior_manifest| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = prior_manifest });
        try install(io, a, root, source, "", &log.writer);
        try expectInstallBytes(io, a, manifest, prior_manifest);
        try expectInstallBytes(io, a, alias_path, bytes);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = store.catalog.manifest_header ++ "\n" });
    const empty = try enc.blob_format.buildAlloc(fixture, .thesaurus, "", &.{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = empty });
    try install(io, a, root, source, "", &log.writer);
    const feature_path = try store.pathAlloc(fixture, root, .thesaurus, "");
    {
        var file = try storage.File.open(io, a, feature_path);
        defer file.deinit();
        try std.testing.expectEqual(@as(usize, 0), file.recordCount());
    }
    try expectInstallBytes(io, a, manifest, store.catalog.manifest_header ++ "\n");
    try std.testing.expectEqual(@as(?store.Kind, null), store.parseKind("alias"));

    alias.presentation = "DPR2broken";
    const invalid_payload = try enc.alias_codec.encodeAlloc(fixture, alias);
    const invalid = try enc.blob_format.buildAlloc(fixture, .alias, "", &.{.{ .title = "1\tA", .payload = invalid_payload }});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = invalid });
    try std.testing.expectError(error.UncompiledDictionary, install(io, a, root, source, "", &log.writer));
    const language_metadata = try enc.blob_format.buildLanguageMetadataAlloc(fixture, "en", "English");
    const empty_language = try enc.blob_format.buildAlloc(fixture, .language, language_metadata, &.{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = empty_language });
    try std.testing.expectError(error.EmptyDictionary, install(io, a, root, source, "", &log.writer));
}

fn expectInstallBytes(io: std.Io, a: A, path: []const u8, expected: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}
fn expectNoInstallParts(io: std.Io, root: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    while (try entries.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".install-"));
}
fn installFixtureBlob(a: A, kind: store.Kind, payload: []const u8) ![]u8 {
    const enc = @import("blob_encoder");
    const metadata = if (kind == .language) try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English") else "";
    defer if (kind == .language) a.free(metadata);
    return enc.blob_format.buildAlloc(a, kind, metadata, &.{.{ .title = "cat", .payload = payload }});
}
test "installer fully rejects malformed nonalias presentation before replacing raw xz and catalogue" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    const enc = @import("blob_encoder");
    for ([_]store.Kind{ .language, .thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental }) |kind| {
        const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, @tagName(kind) });
        const source = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/{s}.input", .{ tmp.sub_path, @tagName(kind) });
        const raw = try store.pathAlloc(fixture, root, kind, if (kind == .language) "English" else "");
        const packed_path = try std.mem.concat(fixture, u8, &.{ raw, ".xz" });
        const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(raw).?);
        const good_payload = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{
            .title = "cat",
            .kind = kind,
            .language = if (kind == .language) "English" else null,
            .language_code = if (kind == .language) "en" else "",
        } });
        const before = try installFixtureBlob(fixture, kind, good_payload);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raw, .data = before });
        // These prior transport bytes are opaque to the transaction: neither
        // existing variant may change when the incoming record is corrupt.
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = packed_path, .data = "prior xz transport bytes" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\nEnglish\n" });
        const broken = try installFixtureBlob(fixture, kind, "DPR2broken");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = broken });
        try std.testing.expectError(error.UncompiledDictionary, install(io, a, root, source, "", &log.writer));
        try expectInstallBytes(io, a, raw, before);
        try expectInstallBytes(io, a, packed_path, "prior xz transport bytes");
        try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
        try expectNoInstallParts(io, root);
    }
}
test "installer rejects invalid catalogue before touching raw xz or a new destination" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const enc = @import("blob_encoder");
    const payload = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const incoming = try installFixtureBlob(fixture, .language, payload);
    const source = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/incoming", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = incoming });
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    for (0..4) |variant| {
        const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/case-{d}", .{ tmp.sub_path, variant });
        const raw = try store.pathAlloc(fixture, root, .language, "English");
        const packed_path = try std.mem.concat(fixture, u8, &.{ raw, ".xz" });
        const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(raw).?);
        const had_raw = variant == 0 or variant == 2;
        const had_xz = variant == 1 or variant == 2;
        if (had_raw) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raw, .data = "original raw" });
        if (had_xz) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = packed_path, .data = "original xz" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "bad\n" });
        try std.testing.expectError(error.InvalidManifest, install(io, a, root, source, "", &log.writer));
        if (had_raw) try expectInstallBytes(io, a, raw, "original raw") else try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, raw, .{}));
        if (had_xz) try expectInstallBytes(io, a, packed_path, "original xz") else try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, packed_path, .{}));
        try expectInstallBytes(io, a, manifest, "bad\n");
        try expectNoInstallParts(io, root);
    }
}
test "installer manifest publication failure restores replacement and removes new installation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]bool{ false, true }) |existing| {
        const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, if (existing) "replace" else "new" });
        try std.Io.Dir.cwd().createDirPath(io, root);
        const destination = try std.fs.path.join(fixture, &.{ root, "dictionary" });
        const obsolete = try std.mem.concat(fixture, u8, &.{ destination, ".xz" });
        const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
        const temporary = try std.fs.path.join(fixture, &.{ root, ".install-input.part" });
        const previous = try std.mem.concat(fixture, u8, &.{ temporary, ".previous" });
        const previous_manifest = try std.mem.concat(fixture, u8, &.{ temporary, ".manifest.previous" });
        const missing_part = try std.mem.concat(fixture, u8, &.{ temporary, ".missing-manifest" });
        if (existing) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = "original raw" });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = obsolete, .data = "original xz" });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\nEnglish\n" });
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = "replacement" });
        var transaction: InstallTransaction = .{
            .io = io,
            .destination = destination,
            .obsolete = obsolete,
            .previous = previous,
            .manifest = manifest,
            .manifest_part = missing_part,
            .previous_manifest = previous_manifest,
        };
        // A missing staged manifest makes the actual final rename fail after
        // dictionary publication, without a production injection hook.
        try std.testing.expectError(error.FileNotFound, transaction.commit(temporary));
        if (existing) {
            try expectInstallBytes(io, a, destination, "original raw");
            try expectInstallBytes(io, a, obsolete, "original xz");
            try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
        } else {
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, destination, .{}));
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, manifest, .{}));
        }
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, previous, .{}));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, previous_manifest, .{}));
    }
}
test "installer successful transaction retires opposite transport only after manifest publication" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const raw = try std.fs.path.join(fixture, &.{ root, "dictionary" });
    const packed_path = try std.mem.concat(fixture, u8, &.{ raw, ".xz" });
    const temporary = try std.fs.path.join(fixture, &.{ root, ".install-input.part" });
    const previous = try std.mem.concat(fixture, u8, &.{ temporary, ".previous" });
    const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
    const part = try std.mem.concat(fixture, u8, &.{ temporary, ".manifest.part" });
    const prior_manifest = try std.mem.concat(fixture, u8, &.{ temporary, ".manifest.previous" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raw, .data = "old raw" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = packed_path, .data = "old xz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = "new xz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = "heading\nEnglish\n" });
    var transaction: InstallTransaction = .{
        .io = io,
        .destination = packed_path,
        .obsolete = raw,
        .previous = previous,
        .manifest = manifest,
        .manifest_part = part,
        .previous_manifest = prior_manifest,
    };
    try transaction.commit(temporary);
    try expectInstallBytes(io, a, packed_path, "new xz");
    try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, raw, .{}));
    try expectNoInstallParts(io, root);
}
test "installer failed rollback retains the only recovery copy" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const destination = try std.fs.path.join(fixture, &.{ root, "destination" });
    const previous = try std.fs.path.join(fixture, &.{ root, ".install-input.part.previous" });
    const child = try std.fs.path.join(fixture, &.{ destination, "keep" });
    try std.Io.Dir.cwd().createDirPath(io, destination);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = child, .data = "unrelated existing path" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = previous, .data = "only original dictionary" });
    var transaction: InstallTransaction = .{
        .io = io,
        .destination = destination,
        .obsolete = "",
        .previous = previous,
        .had_destination = true,
    };
    try std.testing.expectError(error.InstallRollbackFailed, transaction.rollback());
    try expectInstallBytes(io, a, previous, "only original dictionary");
    try expectInstallBytes(io, a, child, "unrelated existing path");
}
test "installer canceled staging cleanup leaves installed data intact" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const partial = try std.fs.path.join(fixture, &.{ root, ".install-canceled.part" });
    const installed = try std.fs.path.join(fixture, &.{ root, "dictionary" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = "partial staging" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = installed, .data = "original dictionary" });
    const Task = struct {
        fn run(task_io: std.Io, path: []const u8, ready: *std.Io.Event) std.Io.Cancelable!void {
            defer removeOwned(task_io, path);
            ready.set(task_io);
            try task_io.sleep(.fromSeconds(60), .awake);
        }
    };
    var ready: std.Io.Event = .unset;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Task.run, .{ io, partial, &ready });
    try ready.wait(io);
    group.cancel(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, partial, .{}));
    try expectInstallBytes(io, a, installed, "original dictionary");
}
test "installer buffered confirmation failure reports committed filesystem state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/library", .{tmp.sub_path});
    const source = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/incoming", .{tmp.sub_path});
    const payload = try @import("blob_encoder").presentation_codec.encodeAlloc(fixture, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const incoming = try installFixtureBlob(fixture, .language, payload);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = incoming });
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.failing;
    writer.buffer = &buffer;
    try std.testing.expectError(error.InstallReportFailed, install(io, a, root, source, "", &writer));
    // The confirmation fit the same-sized CLI buffer; its actual drain failed.
    try std.testing.expect(std.mem.startsWith(u8, writer.buffer[0..writer.end], "Installed "));
    const raw = try store.pathAlloc(fixture, root, .language, "English");
    const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
    try expectInstallBytes(io, a, raw, incoming);
    try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
    try expectNoInstallParts(io, root);
}

test "installer preserves incomplete build root and installs into completed empty catalogue" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/library", .{tmp.sub_path});
    const source = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}/input.wikblb", .{tmp.sub_path});
    const marker = try std.fs.path.join(fixture, &.{ root, ".incomplete" });
    const manifest = try std.fs.path.join(fixture, &.{ root, "languages.tsv" });
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "build in progress\n" });
    const enc = @import("blob_encoder");
    const payload = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const input = try installFixtureBlob(fixture, .language, payload);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = input });
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try std.testing.expectError(error.DictionaryBuildIncomplete, install(io, a, root, source, "", &log.writer));
    try std.testing.expectEqual(@as(usize, 0), log.written().len);
    try expectInstallBytes(io, a, manifest, "heading\n");
    try expectInstallBytes(io, a, marker, "build in progress\n");
    try expectInstallBytes(io, a, source, input);
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    var count: usize = 0;
    while (try entries.next(io)) |entry| {
        try std.testing.expect(std.mem.eql(u8, entry.name, "languages.tsv") or std.mem.eql(u8, entry.name, ".incomplete"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // Remove only the producer marker: no complete.json or fabricated empty blob is required.
    try std.Io.Dir.cwd().deleteFile(io, marker);
    try install(io, a, root, source, "", &log.writer);
    const destination = try store.pathAlloc(fixture, root, .language, "English");
    try expectInstallBytes(io, a, destination, input);
    try std.testing.expect((try store.catalog.find(try std.Io.Dir.cwd().readFileAlloc(io, manifest, fixture, .limited(1024)), "English")) != null);
    try expectNoInstallParts(io, root);
}

test "acquisition scope recognizes exact release names and real snapshot dates" {
    const language = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06";
    try std.testing.expectEqualStrings("enwiktionary-20261001", (try acquisitionScope("enwiktionary-20261001-" ++ language ++ ".wikblb")).?);
    try std.testing.expectEqualStrings("zh-min-nanwiktionary-20260901", (try acquisitionScope("https://example.org/releases/zh-min-nanwiktionary-20260901-sign-gloss.wikblb.xz?download=1")).?);
    try std.testing.expectEqualStrings("arwiktionary-20240229", (try acquisitionScope("arwiktionary-20240229-aliases.wikblb")).?);
    try std.testing.expectError(error.InvalidEditionScope, acquisitionScope("enwiktionary-20260229-" ++ language ++ ".wikblb"));
    try std.testing.expectError(error.InvalidEditionScope, acquisitionScope("enwiktionary-20261301-thesaurus.wikblb"));
    try std.testing.expectEqual(@as(?[]const u8, null), try acquisitionScope("English.wikblb"));
    try std.testing.expectEqual(@as(?[]const u8, null), try acquisitionScope("enwiktionary-20261001-" ++ language ++ ".wikblb#copy"));
    try std.testing.expectEqual(@as(?[]const u8, null), try acquisitionScope("enwiktionary-20261001-" ++ language ++ ".wikblb?copy"));
    try std.testing.expectEqual(@as(?[]const u8, null), try acquisitionScope("local-aliases.wikblb"));
}

test "installer refuses other acquisition scopes before copy while preserving installed files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(f, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fs.path.join(f, &.{ base, "installed" });
    const source = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" });
    const payload = try @import("blob_encoder").presentation_codec.encodeAlloc(f, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const first = try installFixtureBlob(f, .language, payload);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = first });
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try install(io, a, root, source, "", &log.writer);
    const raw = try store.pathAlloc(f, root, .language, "English");
    const packed_path = try std.mem.concat(f, u8, &.{ raw, ".xz" });
    const manifest = try std.fs.path.join(f, &.{ root, "languages.tsv" });
    const marker = try std.fs.path.join(f, &.{ root, edition_marker });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = packed_path, .data = "old compressed transport" });
    // None of these inputs exists: refusal must precede the potentially large copy/download.
    for ([_][]const u8{
        "afwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb",
        "enwiktionary-20261101-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb",
        "afwiktionary-20261001-aliases.wikblb",
        "unlabelled-local.wikblb",
    }) |name| {
        const missing_source = try std.fs.path.join(f, &.{ base, name });
        try std.testing.expectError(error.EditionScopeMismatch, install(io, a, root, missing_source, "", &log.writer));
        try expectInstallBytes(io, a, raw, first);
        try expectInstallBytes(io, a, packed_path, "old compressed transport");
        try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
        try expectInstallBytes(io, a, marker, "enwiktionary-20261001\n");
        try expectNoInstallParts(io, root);
    }
    const changed = try @import("blob_encoder").presentation_codec.encodeAlloc(f, .{ .entry = .{
        .title = "different",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const replacement = try installFixtureBlob(f, .language, changed);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = replacement });
    try install(io, a, root, source, "", &log.writer);
    try expectInstallBytes(io, a, raw, replacement);
    try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
    try expectInstallBytes(io, a, marker, "enwiktionary-20261001\n");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, packed_path, .{}));
    const feature_source = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-thesaurus.wikblb" });
    const feature = try @import("blob_encoder").blob_format.buildAlloc(f, .thesaurus, "", &.{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = feature_source, .data = feature });
    try install(io, a, root, feature_source, "", &log.writer);
    try expectInstallBytes(io, a, try store.pathAlloc(f, root, .thesaurus, ""), feature);
}

test "installer retains producer scope for completed empty catalogues and refuses inconsistent markers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(f, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fs.path.join(f, &.{ base, "completed" });
    const source = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" });
    try std.Io.Dir.cwd().createDirPath(io, root);
    const complete = try std.fs.path.join(f, &.{ root, "complete.json" });
    const manifest = try std.fs.path.join(f, &.{ root, "languages.tsv" });
    const marker = try std.fs.path.join(f, &.{ root, edition_marker });
    const completion = "{\"edition\":\"enwiktionary\",\"date\":\"20261001\",\"blobs\":0}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = complete, .data = completion });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\n" });
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    // Empty does not mean unscoped, and a conflicting input is never opened.
    const missing = try std.fs.path.join(f, &.{ base, "afwiktionary-20261001-aliases.wikblb" });
    try std.testing.expectError(error.EditionScopeMismatch, install(io, a, root, missing, "", &log.writer));
    try expectInstallBytes(io, a, manifest, "heading\n");
    const payload = try @import("blob_encoder").presentation_codec.encodeAlloc(f, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const blob = try installFixtureBlob(f, .language, payload);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = blob });
    try install(io, a, root, source, "", &log.writer);
    try expectInstallBytes(io, a, try store.pathAlloc(f, root, .language, "English"), blob);
    try expectInstallBytes(io, a, complete, completion);
    // Existing producer metadata remains authoritative; no extra marker is needed.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker, .{}));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "afwiktionary-20261001\n" });
    try std.testing.expectError(error.InvalidEditionScope, install(io, a, root, source, "", &log.writer));
    try expectInstallBytes(io, a, try store.pathAlloc(f, root, .language, "English"), blob);
    try expectInstallBytes(io, a, complete, completion);
    try expectInstallBytes(io, a, marker, "afwiktionary-20261001\n");
}

test "installer preserves unscoped local installs without claiming canonical provenance" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(f, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fs.path.join(f, &.{ base, "legacy" });
    const source = try std.fs.path.join(f, &.{ base, "English.wikblb" });
    const payload = try @import("blob_encoder").presentation_codec.encodeAlloc(f, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    const blob = try installFixtureBlob(f, .language, payload);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = blob });
    var log: std.Io.Writer.Allocating = .init(a);
    defer log.deinit();
    try install(io, a, root, source, "", &log.writer);
    try install(io, a, root, source, "", &log.writer);
    // '#' is literal in a local filename, not a URL fragment or canonical scope.
    const local_copy = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb#copy" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = local_copy, .data = blob });
    try install(io, a, root, local_copy, "", &log.writer);
    const canonical = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb" });
    try std.testing.expectError(error.EditionScopeMismatch, install(io, a, root, canonical, "", &log.writer));
    try expectInstallBytes(io, a, try store.pathAlloc(f, root, .language, "English"), blob);
    try expectInstallBytes(io, a, try std.fs.path.join(f, &.{ root, "languages.tsv" }), "heading\nEnglish\n");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try std.fs.path.join(f, &.{ root, edition_marker }), .{}));
    // A canonical label cannot override the decoded kind/heading even in a new root.
    const wrong_source = try std.fs.path.join(f, &.{ base, "enwiktionary-20261001-aliases.wikblb" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wrong_source, .data = blob });
    const fresh = try std.fs.path.join(f, &.{ base, "fresh" });
    try std.testing.expectError(error.InvalidEditionScope, install(io, a, fresh, wrong_source, "", &log.writer));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try std.fs.path.join(f, &.{ fresh, edition_marker }), .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try store.pathAlloc(f, fresh, .language, "English"), .{}));
    try expectNoInstallParts(io, fresh);
}

test "installer edition publication failure restores dictionary and catalogue before obsolete deletion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(f, ".zig-cache/tmp/{s}/rollback", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, root);
    const destination = try std.fs.path.join(f, &.{ root, "dictionary" });
    const obsolete = try std.mem.concat(f, u8, &.{ destination, ".xz" });
    const manifest = try std.fs.path.join(f, &.{ root, "languages.tsv" });
    const temporary = try std.fs.path.join(f, &.{ root, ".install-test.part" });
    const manifest_part = try std.mem.concat(f, u8, &.{ temporary, ".manifest.part" });
    const marker = try std.fs.path.join(f, &.{ root, edition_marker });
    const scope_part = try std.mem.concat(f, u8, &.{ temporary, ".edition.part" });
    const previous = try std.mem.concat(f, u8, &.{ temporary, ".previous" });
    const previous_manifest = try std.mem.concat(f, u8, &.{ temporary, ".manifest.previous" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = "old raw" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = obsolete, .data = "old xz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\nEnglish\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = "replacement" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_part, .data = "heading\nEnglish\nFrench\n" });
    var transaction: InstallTransaction = .{
        .io = io,
        .destination = destination,
        .obsolete = obsolete,
        .previous = previous,
        .manifest = manifest,
        .manifest_part = manifest_part,
        .previous_manifest = previous_manifest,
        .edition = marker,
        .edition_part = scope_part,
    };
    // The scope part is deliberately missing; the failure occurs after blob/manifest rename.
    try std.testing.expectError(error.FileNotFound, transaction.commit(temporary));
    try expectInstallBytes(io, a, destination, "old raw");
    try expectInstallBytes(io, a, obsolete, "old xz");
    try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker, .{}));
    try expectNoInstallParts(io, root);
}

test "installer rolls back a published edition marker when final obsolete removal fails" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const f = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(f, ".zig-cache/tmp/{s}/rollback-marker", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, root);
    const destination = try std.fs.path.join(f, &.{ root, "dictionary" });
    const obsolete = try std.mem.concat(f, u8, &.{ destination, ".xz" });
    const manifest = try std.fs.path.join(f, &.{ root, "languages.tsv" });
    const temporary = try std.fs.path.join(f, &.{ root, ".install-test.part" });
    const manifest_part = try std.mem.concat(f, u8, &.{ temporary, ".manifest.part" });
    const marker = try std.fs.path.join(f, &.{ root, edition_marker });
    const scope_part = try std.mem.concat(f, u8, &.{ temporary, ".edition.part" });
    try std.Io.Dir.cwd().createDirPath(io, obsolete);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(f, &.{ obsolete, "retained" }), .data = "old transport" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = "old raw" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "heading\nEnglish\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = "replacement" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_part, .data = "heading\nEnglish\nFrench\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scope_part, .data = "enwiktionary-20261001\n" });
    var transaction: InstallTransaction = .{
        .io = io,
        .destination = destination,
        .obsolete = obsolete,
        .previous = try std.mem.concat(f, u8, &.{ temporary, ".previous" }),
        .manifest = manifest,
        .manifest_part = manifest_part,
        .previous_manifest = try std.mem.concat(f, u8, &.{ temporary, ".manifest.previous" }),
        .edition = marker,
        .edition_part = scope_part,
    };
    var failed = false;
    transaction.commit(temporary) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    try expectInstallBytes(io, a, destination, "old raw");
    try expectInstallBytes(io, a, manifest, "heading\nEnglish\n");
    try expectInstallBytes(io, a, try std.fs.path.join(f, &.{ obsolete, "retained" }), "old transport");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker, .{}));
    try expectNoInstallParts(io, root);
}
