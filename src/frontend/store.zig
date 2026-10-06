const std = @import("std");
const enc = @import("blob_encoder");
const dec = @import("blob_decoder");
pub const Kind = enc.blob_format.BlobKind;
pub const catalog = enc.blob_catalog;
const native_storage = @import("blob_storage");
const Alias = enc.alias_codec.Record;
const Redirect = enc.presentation_types.Redirect;

const AliasPosition = struct {
    record_index: usize,
    key: []const u8,
    position: usize = 0,
};

pub fn parseKind(text: []const u8) ?Kind {
    if (std.mem.eql(u8, text, "sign-gloss")) return .sign_gloss;
    const kind = std.meta.stringToEnum(Kind, text) orelse return null;
    return if (kind == .alias) null else kind;
}
pub fn pathAlloc(a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8) ![]u8 {
    if (kind == .language) {
        var name: [catalog.language_blob_filename_len]u8 = undefined;
        return std.fs.path.join(a, &.{ root, catalog.language_directory, catalog.languageBlobFilename(language, &name) });
    }
    return std.fs.path.join(a, &.{ root, catalog.featureBlobFilename(kind).? });
}

pub const Store = struct {
    file: @import("blob_storage").File,
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    aliases: ?native_storage.File = null,
    alias_positions: []AliasPosition = &.{},
    neutral_main: bool = false,

    pub fn open(io: std.Io, a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8) !Store {
        if (kind == .alias) return error.InvalidArgument;
        try @import("blob_files").requireComplete(io, a, root);
        const path = try pathAlloc(a, root, kind, language);
        defer a.free(path);
        var neutral = false;
        var file = native_storage.File.open(io, a, path) catch |err| blk: {
            if (err != error.FileNotFound or kind != .language) return err;
            if (!try neutralAvailable(io, a, root)) return err;
            const alias_path = try pathAlloc(a, root, .alias, "");
            defer a.free(alias_path);
            neutral = true;
            break :blk try native_storage.File.open(io, a, alias_path);
        };
        errdefer file.deinit();
        if (file.view.kind != (if (neutral) Kind.alias else kind)) return error.UnexpectedBlobKind;
        if (kind == .language and !neutral) {
            const meta = try file.view.languageMetadata();
            if (!std.mem.eql(u8, meta.heading, language)) return error.UnexpectedLanguageBlob;
        }
        const owned_root = try a.dupe(u8, root);
        errdefer a.free(owned_root);
        var result: Store = .{ .file = file, .allocator = a, .root = owned_root, .neutral_main = neutral };
        if (neutral) try result.indexAliases(&result.file, .language) else try result.loadAliases();
        return result;
    }

    fn neutralAvailable(io: std.Io, a: std.mem.Allocator, root: []const u8) !bool {
        const manifest = try std.fs.path.join(a, &.{ root, catalog.manifest_filename });
        defer a.free(manifest);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer a.free(bytes);
        var entries = try catalog.Iterator.init(bytes);
        if (try entries.next() != null) return false;
        const directory = try std.fs.path.join(a, &.{ root, catalog.language_directory });
        defer a.free(directory);
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".wikblb") or std.mem.endsWith(u8, entry.name, ".wikblb.xz")) return false;
        }
        return true;
    }

    fn loadAliases(self: *Store) !void {
        if (self.file.view.kind == .alias) return;
        const a = self.allocator;
        const path = try pathAlloc(a, self.root, .alias, "");
        defer a.free(path);
        var aliases = native_storage.File.open(self.file.io, a, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        errdefer aliases.deinit();
        if (aliases.view.kind != .alias) return error.UnexpectedBlobKind;
        try self.indexAliases(&aliases, self.file.view.kind);
        self.aliases = aliases;
    }

    fn indexAliases(self: *Store, aliases: *native_storage.File, kind: Kind) !void {
        const a = self.allocator;
        var positions: std.ArrayList(AliasPosition) = .empty;
        errdefer positions.deinit(a);
        const prefix_key = [_]u8{ '0' + @as(u8, @intCast(@backingInt(kind))), '\t' };
        const selected = aliases.prefix(&prefix_key);
        for (selected.start..selected.end) |i| {
            const raw_key = try aliases.titleAt(i);
            const key = raw_key[prefix_key.len..];
            if (key.len == 0 or !std.unicode.utf8ValidateSlice(key)) return error.InvalidAlias;
            // The alias directory owns this suffix for the Store lifetime.
            try positions.append(a, .{ .record_index = i, .key = key });
        }
        if (self.neutral_main and positions.items.len == 0) return error.FileNotFound;
        _ = try std.math.add(usize, self.definitionCount(), positions.items.len);
        for (positions.items, 0..) |*position, i| {
            if (i != 0 and std.mem.eql(u8, positions.items[i - 1].key, position.key)) return error.DuplicateAliasKey;
            if (!self.neutral_main and self.file.find(position.key) != null) return error.AliasDefinitionCollision;
            position.position = if (self.neutral_main) i else try std.math.add(usize, self.file.prefix(position.key).start, i);
        }
        self.alias_positions = try positions.toOwnedSlice(a);
    }

    fn decodeAlias(raw: native_storage.Record) !Alias {
        const alias = try enc.alias_codec.decode(raw.payload);
        try enc.alias_codec.validateKey(raw.title, alias);
        return alias;
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.alias_positions);
        if (self.aliases) |*aliases| aliases.deinit();
        self.file.deinit();
        self.allocator.free(self.root);
        self.* = undefined;
    }
    pub fn count(self: Store) usize {
        return self.definitionCount() + self.alias_positions.len;
    }
    fn definitionCount(self: Store) usize {
        return if (self.neutral_main) 0 else self.file.recordCount();
    }
    pub fn selectionKind(self: Store) Kind {
        return if (self.neutral_main) .language else self.file.view.kind;
    }
    pub fn heading(self: Store) ?[]const u8 {
        return if (self.metadata()) |meta| meta.heading else null;
    }
    pub fn labelAlloc(self: Store, a: std.mem.Allocator) ![]u8 {
        if (self.neutral_main) return a.dupe(u8, "Redirects");
        return std.fmt.allocPrint(a, "{s} / {s}", .{ self.heading() orelse "Features", @tagName(self.selectionKind()) });
    }
    /// Existing ordinary caches retain their identity. Overlay caches bind
    /// both immutable file fingerprints, selection kind and index version.
    pub fn searchFingerprint(self: Store) [32]u8 {
        if (!self.neutral_main and self.aliases == null) return self.file.fingerprint;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("wikidict-folded-alias-v1\x00");
        hash.update(&self.file.fingerprint);
        hash.update(if (self.neutral_main) &self.file.fingerprint else &self.aliases.?.fingerprint);
        const mode = [_]u8{ @intCast(@backingInt(self.selectionKind())), @intFromBool(self.neutral_main) };
        hash.update(&mode);
        return hash.finalResult();
    }
    pub fn hasAliases(self: Store) bool {
        return self.alias_positions.len != 0;
    }

    const Position = union(enum) { definition: usize, alias: usize };
    fn positionAt(self: Store, index: usize) !Position {
        if (index >= self.count()) return error.InvalidRecordIndex;
        var lo: usize = 0;
        var hi = self.alias_positions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.alias_positions[mid].position < index) lo = mid + 1 else hi = mid;
        }
        if (lo < self.alias_positions.len and self.alias_positions[lo].position == index) return .{ .alias = lo };
        return .{ .definition = index - lo };
    }
    pub fn titleAt(self: Store, index: usize) ![]const u8 {
        return switch (try self.positionAt(index)) {
            .definition => |i| self.file.titleAt(i),
            .alias => |i| self.alias_positions[i].key,
        };
    }
    pub fn find(self: Store, title: []const u8) !?usize {
        if (!self.hasAliases()) return self.file.find(title);
        var lo: usize = 0;
        var hi = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, try self.titleAt(mid), title)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }
    pub fn metadata(self: Store) ?enc.blob_format.LanguageMetadata {
        return if (self.file.view.kind == .language) self.file.view.languageMetadata() catch null else null;
    }
    pub const Raw = struct {
        record: dec.BlobRecordView,
        storage: native_storage.Record,
        source_alias: ?native_storage.Record = null,
        target_file: ?native_storage.File = null,
        pub fn deinit(self: *Raw) void {
            self.storage.deinit();
            if (self.source_alias) |*source| source.deinit();
            if (self.target_file) |*file| file.deinit();
        }
    };
    pub fn recordAlloc(self: *Store, a: std.mem.Allocator, index: usize) !Raw {
        return switch (try self.positionAt(index)) {
            .definition => |i| readFile(a, &self.file, i),
            .alias => |i| self.readAlias(a, self.alias_positions[i].record_index),
        };
    }

    fn readFile(a: std.mem.Allocator, file: *native_storage.File, index: usize) !Raw {
        var r = try file.readAlloc(a, index);
        errdefer r.deinit();
        const view = try dec.openTrustedBlob(file.directory.header);
        return .{ .record = view.wrapRecord(.{ .title = r.title, .payload = r.payload }), .storage = r };
    }

    fn aliasView(source: native_storage.Record, alias: Alias) Raw {
        return .{
            .record = .{ .alias = .{
                .title = source.title,
                .payload = source.payload,
                .redirect = redirectInfo(alias, false),
            } },
            .storage = source,
        };
    }
    fn redirectInfo(alias: Alias, followed: bool) Redirect {
        return .{ .source_title = alias.source_title, .target_title = alias.target_title, .fragment = alias.fragment, .followed = followed };
    }

    fn readAlias(self: *Store, a: std.mem.Allocator, index: usize) !Raw {
        const aliases = if (self.neutral_main) &self.file else if (self.aliases) |*file| file else return error.InvalidAlias;
        var source = try aliases.readAlloc(a, index);
        errdefer source.deinit();
        const alias = try decodeAlias(source);
        const kind = alias.target_kind orelse return aliasView(source, alias);
        if (kind == .alias) return error.InvalidAlias;

        // One direct hop only. A target which is itself a redirect is displayed
        // as its precompiled redirect page, including for self/cyclic edges.
        const target_alias_key = try enc.alias_codec.keyAlloc(a, kind, alias.target_key);
        defer a.free(target_alias_key);
        if (aliases.find(target_alias_key)) |target_index| {
            var target = try readFile(a, aliases, target_index);
            errdefer target.deinit();
            const target_alias = try decodeAlias(target.storage);
            if (target_alias.source_kind != kind or
                alias.target_namespace == null or target_alias.source_namespace != alias.target_namespace.? or
                !std.mem.eql(u8, target_alias.source_title, alias.target_title) or
                !std.mem.eql(u8, target_alias.source_key, alias.target_key)) return error.InvalidAlias;
            target.source_alias = source;
            target.record.setRedirect(redirectInfo(alias, true));
            return target;
        }
        if (kind == self.file.view.kind) {
            const target_index = self.file.find(alias.target_key) orelse return aliasView(source, alias);
            var target = try readFile(a, &self.file, target_index);
            target.source_alias = source;
            target.record.setRedirect(redirectInfo(alias, true));
            return target;
        }
        // A feature selection carries no selected definition language. Do not
        // invent one when its redirect points into the main namespace.
        if (kind == .language) return aliasView(source, alias);
        const path = try pathAlloc(a, self.root, kind, "");
        defer a.free(path);
        var target_file = native_storage.File.open(self.file.io, a, path) catch |err| switch (err) {
            error.FileNotFound => return aliasView(source, alias),
            else => return err,
        };
        errdefer target_file.deinit();
        if (target_file.view.kind != kind) return error.UnexpectedBlobKind;
        const target_index = target_file.find(alias.target_key) orelse {
            target_file.deinit();
            return aliasView(source, alias);
        };
        var target = try readFile(a, &target_file, target_index);
        target.target_file = target_file;
        target.source_alias = source;
        target.record.setRedirect(redirectInfo(alias, true));
        return target;
    }

    pub fn prefix(self: Store, text: []const u8) !Range {
        if (!self.hasAliases()) {
            const p = self.file.prefix(text);
            return .{ .start = p.start, .end = p.end };
        }
        var lo: usize = 0;
        var hi = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, try self.titleAt(mid), text) == .lt) lo = mid + 1 else hi = mid;
        }
        const start = lo;
        hi = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.startsWith(u8, try self.titleAt(mid), text)) lo = mid + 1 else hi = mid;
        }
        return .{ .start = start, .end = lo };
    }
};
pub const Range = struct { start: usize, end: usize };
/// Exact UTF-8 byte prefix, matching the wire's strict bytewise title order.
/// Two binary searches avoid scanning millions of hits for an empty prefix.
pub fn prefixRange(index: dec.BlobIndexedView, query: []const u8) !Range {
    var lo: usize = 0;
    var hi = index.recordCount();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, (try index.recordAt(mid)).title(), query) == .lt) lo = mid + 1 else hi = mid;
    }
    const start = lo;
    hi = index.recordCount();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.startsWith(u8, (try index.recordAt(mid)).title(), query)) lo = mid + 1 else hi = mid;
    }
    return .{ .start = start, .end = lo };
}
test "prefix ranges handle exact matches empty prefixes unicode and misses" {
    const a = std.testing.allocator;
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{
        .{ .title = "cat", .payload = "" }, .{ .title = "catfish", .payload = "" },
        .{ .title = "dog", .payload = "" },
        .{ .title = "éclair", .payload = "" },
    });
    defer a.free(bytes);
    const view = try dec.openTrustedBlob(bytes);
    var index = try view.buildIndexAlloc(a);
    defer index.deinit(a);
    try std.testing.expectEqual(Range{ .start = 0, .end = 2 }, try prefixRange(index, "cat"));
    try std.testing.expectEqual(Range{ .start = 0, .end = 4 }, try prefixRange(index, ""));
    try std.testing.expectEqual(Range{ .start = 3, .end = 4 }, try prefixRange(index, "é"));
    try std.testing.expectEqual(Range{ .start = 3, .end = 3 }, try prefixRange(index, "missing"));
}

test "compiled records need no resolution machinery" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const payload_bytes = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{
        .title = "cat",
        .kind = .language,
        .language = "English",
        .language_code = "en",
    } });
    defer a.free(payload_bytes);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = "cat", .payload = payload_bytes }});
    defer a.free(bytes);
    const path = try pathAlloc(a, root, .language, "English");
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    var db = try Store.open(io, a, root, .language, "English");
    defer db.deinit();
    var raw = try db.recordAlloc(a, (try db.find("cat")).?);
    defer raw.deinit();
    try std.testing.expectEqualStrings(payload_bytes, @import("model.zig").payload(raw.record));
}

fn writeAliasTestBlob(a: std.mem.Allocator, root: []const u8, kind: Kind, language: []const u8, records: []const enc.blob_format.RecordInput) !void {
    const metadata = if (kind == .language) try enc.blob_format.buildLanguageMetadataAlloc(a, "test", language) else "";
    const bytes = try enc.blob_format.buildAlloc(a, kind, metadata, records);
    const path = try pathAlloc(a, root, kind, language);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

const AliasTestSpec = struct {
    source: []const u8,
    target: []const u8,
    source_kind: Kind = .language,
    target_kind: ?Kind = .language,
    fragment: []const u8 = "",
};

fn aliasTestKey(title: []const u8, kind: Kind) []const u8 {
    return if (kind == .language or kind == .supplemental) title else title[std.mem.indexOfScalar(u8, title, ':').? + 1 ..];
}

fn aliasTestPayload(a: std.mem.Allocator, spec: AliasTestSpec) ![]const u8 {
    const link = if (spec.fragment.len == 0) spec.target else try std.fmt.allocPrint(a, "{s}#{s}", .{ spec.target, spec.fragment });
    const presentation = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{
        .title = spec.source,
        .kind = .alias,
        .preamble_spans = &.{.{ .kind = .link, .text = spec.target, .target = link }},
        .sections = &.{.{ .level = 2, .title = "Redirect notes", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "Compiled tail" }} }} }},
    } });
    return try enc.alias_codec.encodeAlloc(a, .{
        .source_namespace = if (spec.source_kind == .language) 0 else 110,
        .source_kind = spec.source_kind,
        .source_title = spec.source,
        .source_key = aliasTestKey(spec.source, spec.source_kind),
        .xml_target = spec.target,
        .target_title = spec.target,
        .target_namespace = if (spec.target_kind) |kind| @as(u32, if (kind == .language) 0 else 110) else null,
        .target_kind = spec.target_kind,
        .target_key = if (spec.target_kind) |kind| aliasTestKey(spec.target, kind) else "",
        .fragment = spec.fragment,
        .presentation = presentation,
    });
}

test "alias overlay preserves order and follows exactly one compiled target" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var definitions: [3]enc.blob_format.RecordInput = undefined;
    for ([_][]const u8{ "animus", "cat", "z" }, 0..) |title, i| definitions[i] = .{
        .title = title,
        .payload = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{ .title = title, .kind = .language, .language = "English", .language_code = "test" } }),
    };
    try writeAliasTestBlob(fixture, root, .language, "English", &definitions);
    try writeAliasTestBlob(fixture, root, .language, "German", &.{});
    const feature = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{ .title = "animal", .kind = .thesaurus } });
    try writeAliasTestBlob(fixture, root, .thesaurus, "", &.{.{ .title = "animal", .payload = feature }});
    const specs = [_]AliasTestSpec{
        .{ .source = "Alpha", .target = "cat", .fragment = "Noun" },
        .{ .source = "Animus", .target = "animus" },
        .{ .source = "Broken", .target = "missing" },
        .{ .source = "ChainA", .target = "ChainB", .fragment = "Incoming" },
        .{ .source = "ChainB", .target = "cat", .fragment = "Noun" },
        .{ .source = "Feature", .target = "Thesaurus:animal", .target_kind = .thesaurus },
        .{ .source = "LoopA", .target = "LoopB" },
        .{ .source = "LoopB", .target = "LoopA" },
        .{ .source = "Self", .target = "Self" },
        .{ .source = "Thesaurus:Old", .target = "Thesaurus:animal", .source_kind = .thesaurus, .target_kind = .thesaurus },
        .{ .source = "Thesaurus:ToMain", .target = "cat", .source_kind = .thesaurus },
        .{ .source = "Unbundled", .target = "File:Cat.svg", .target_kind = null },
        .{ .source = "café", .target = "cat" },
    };
    var aliases: [specs.len]enc.blob_format.RecordInput = undefined;
    for (specs, 0..) |spec, i| aliases[i] = .{ .title = try enc.alias_codec.keyAlloc(fixture, spec.source_kind, aliasTestKey(spec.source, spec.source_kind)), .payload = try aliasTestPayload(fixture, spec) };
    std.mem.sort(enc.blob_format.RecordInput, &aliases, {}, struct {
        fn less(_: void, left: enc.blob_format.RecordInput, right: enc.blob_format.RecordInput) bool {
            return std.mem.order(u8, left.title, right.title) == .lt;
        }
    }.less);
    try writeAliasTestBlob(fixture, root, .alias, "", &aliases);

    var db = try Store.open(std.testing.io, a, root, .language, "English");
    defer db.deinit();
    const titles = [_][]const u8{ "Alpha", "Animus", "Broken", "ChainA", "ChainB", "Feature", "LoopA", "LoopB", "Self", "Unbundled", "animus", "café", "cat", "z" };
    try std.testing.expectEqual(titles.len, db.count());
    try std.testing.expectEqual(@as(usize, 11), db.alias_positions.len);
    try std.testing.expectEqual(@as(usize, 3), db.file.recordCount());
    try std.testing.expectEqual(@as(u64, 0), db.aliases.?.payload_reads);
    const directory_titles = db.aliases.?.directory.titles;
    for (db.alias_positions) |position| try std.testing.expect(@intFromPtr(position.key.ptr) >= @intFromPtr(directory_titles.ptr) and
        @intFromPtr(position.key.ptr) + position.key.len <= @intFromPtr(directory_titles.ptr) + directory_titles.len);
    for (titles, 0..) |title, i| {
        try std.testing.expectEqualStrings(title, try db.titleAt(i));
        try std.testing.expectEqual(i, (try db.find(title)).?);
    }
    try std.testing.expectEqual(Range{ .start = 3, .end = 5 }, try db.prefix("Chain"));
    try std.testing.expectEqual(Range{ .start = 11, .end = 12 }, try db.prefix("café"));
    try std.testing.expectEqual(Range{ .start = 0, .end = titles.len }, try db.prefix(""));
    try std.testing.expectEqual(@as(?usize, null), try db.find("Absent"));
    try std.testing.expectError(error.InvalidRecordIndex, db.recordAlloc(a, db.count()));

    const search = @import("search.zig");
    try std.testing.expectEqual((try db.find("Animus")).?, (try search.find(a, &db, "Animus")).?);
    try std.testing.expectEqual((try db.find("animus")).?, (try search.find(a, &db, "animus")).?);
    {
        // Reusing a warmed task must discard base-file ordinal keys when
        // aliases shift those ordinals, even though the base file is unchanged.
        const path = try pathAlloc(fixture, root, .language, "English");
        var plain: Store = .{ .file = try native_storage.File.open(std.testing.io, a, path), .allocator = a };
        defer plain.file.deinit();
        var task: search.Task = .{ .folded_cache_min_records = 0 };
        defer task.deinit(a);
        try task.begin(a, "a");
        while (!task.complete) try task.step(a, &plain, 4);
        try std.testing.expect(task.folded_cache != null);
        try task.begin(a, "an");
        while (!task.complete) try task.step(a, &db, 4);
        try std.testing.expect(task.folded_cache != null);
        try std.testing.expect(task.folded_builder == null);
        try std.testing.expect(!task.folded_disabled);
        const fingerprint = db.searchFingerprint();
        try std.testing.expectEqualSlices(u8, &fingerprint, &task.folded_source);
        try std.testing.expect(!std.mem.eql(u8, &fingerprint, &plain.file.fingerprint));
        try std.testing.expectEqual(@as(usize, 2), task.total_matches);
    }

    const model = @import("model.zig");
    {
        var raw = try db.recordAlloc(a, (try db.find("Alpha")).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings("cat", doc.entry.title);
        try std.testing.expectEqualStrings("English", doc.entry.language.?);
        try std.testing.expectEqualStrings("Alpha", doc.entry.redirect.?.source_title);
        try std.testing.expectEqualStrings("Noun", doc.entry.redirect.?.fragment);
        try std.testing.expect(doc.entry.redirect.?.followed);
        try std.testing.expect(doc.entry.alias == null);
    }
    for ([_][]const u8{ "ChainA", "LoopA", "Self" }, [_][]const u8{ "ChainB", "LoopB", "Self" }, [_][]const u8{ "cat", "LoopA", "Self" }) |source, displayed, next| {
        var raw = try db.recordAlloc(a, (try db.find(source)).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqual(Kind.alias, doc.entry.kind);
        try std.testing.expectEqualStrings(displayed, doc.entry.title);
        try std.testing.expectEqualStrings(source, doc.entry.redirect.?.source_title);
        try std.testing.expectEqualStrings(displayed, doc.entry.redirect.?.target_title);
        try std.testing.expect(doc.entry.redirect.?.followed);
        try std.testing.expectEqualStrings(next, doc.entry.alias.?.target_title);
        if (std.mem.eql(u8, source, "ChainA")) {
            try std.testing.expectEqualStrings("Incoming", doc.entry.redirect.?.fragment);
            try std.testing.expectEqualStrings("Noun", doc.entry.alias.?.fragment);
            try std.testing.expectEqualStrings("cat#Noun", doc.entry.preamble_spans[0].target);
            try std.testing.expectEqualStrings("Compiled tail", doc.entry.sections[0].blocks[0].spans[0].text);
        }
    }
    for ([_][]const u8{ "Broken", "Unbundled" }) |source| {
        var raw = try db.recordAlloc(a, (try db.find(source)).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings(source, doc.entry.title);
        try std.testing.expectEqual(Kind.alias, doc.entry.kind);
        try std.testing.expect(!doc.entry.redirect.?.followed);
        try std.testing.expect(doc.entry.language == null);
    }
    {
        var raw = try db.recordAlloc(a, (try db.find("Feature")).?);
        defer raw.deinit();
        try std.testing.expect(raw.target_file != null);
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqual(Kind.thesaurus, doc.entry.kind);
        try std.testing.expectEqualStrings("animal", doc.entry.title);
        try std.testing.expectEqualStrings("Thesaurus:animal", doc.entry.redirect.?.target_title);
    }
    {
        var german = try Store.open(std.testing.io, a, root, .language, "German");
        defer german.deinit();
        var raw = try german.recordAlloc(a, (try german.find("Alpha")).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings("Alpha", doc.entry.title);
        try std.testing.expect(!doc.entry.redirect.?.followed);
        try std.testing.expect(doc.entry.language == null);
    }
    {
        var thesaurus = try Store.open(std.testing.io, a, root, .thesaurus, "");
        defer thesaurus.deinit();
        try std.testing.expectEqual(@as(usize, 3), thesaurus.count());
        try std.testing.expectEqual(@as(?usize, null), try thesaurus.find("Alpha"));
        var raw = try thesaurus.recordAlloc(a, (try thesaurus.find("Old")).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings("animal", doc.entry.title);
        try std.testing.expectEqualStrings("Thesaurus:Old", doc.entry.redirect.?.source_title);
        var to_main = try thesaurus.recordAlloc(a, (try thesaurus.find("ToMain")).?);
        defer to_main.deinit();
        var main_doc = try model.fromRecord(a, to_main.record);
        defer main_doc.deinit();
        try std.testing.expectEqualStrings("Thesaurus:ToMain", main_doc.entry.title);
        try std.testing.expect(!main_doc.entry.redirect.?.followed);
    }
    try std.testing.expectEqual(@as(?Kind, null), parseKind("alias"));
    try std.testing.expectEqual(@as(?Kind, .sign_gloss), parseKind("sign-gloss"));
}

test "alias overlay rejects source identity mismatch and ordinary record collision" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const payload_bytes = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{ .title = "cat", .kind = .language, .language = "English", .language_code = "test" } });
    try writeAliasTestBlob(fixture, root, .language, "English", &.{.{ .title = "cat", .payload = payload_bytes }});
    const alias = try aliasTestPayload(fixture, .{ .source = "cat", .target = "dog" });
    try writeAliasTestBlob(fixture, root, .alias, "", &.{.{ .title = "1\tcat", .payload = alias }});
    try std.testing.expectError(error.AliasDefinitionCollision, Store.open(std.testing.io, a, root, .language, "English"));
    try writeAliasTestBlob(fixture, root, .alias, "", &.{.{ .title = "1\tdog", .payload = alias }});
    var db = try Store.open(std.testing.io, a, root, .language, "English");
    defer db.deinit();
    try std.testing.expectEqual(@as(u64, 0), db.aliases.?.payload_reads);
    try std.testing.expectError(error.InvalidAlias, db.recordAlloc(a, (try db.find("dog")).?));
}

test "same-count alias replacement invalidates a warmed folded task and disk cache" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const payload = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{ .title = "cat", .kind = .language, .language = "English", .language_code = "test" } });
    try writeAliasTestBlob(fixture, root, .language, "English", &.{.{ .title = "cat", .payload = payload }});
    try writeAliasTestBlob(fixture, root, .alias, "", &.{.{ .title = "1\tAlpha", .payload = try aliasTestPayload(fixture, .{ .source = "Alpha", .target = "cat" }) }});
    var before = try Store.open(std.testing.io, a, root, .language, "English");
    defer before.deinit();
    var task: @import("search.zig").Task = .{ .folded_cache_min_records = 0 };
    defer task.deinit(a);
    try task.begin(a, "al");
    while (!task.complete) try task.step(a, &before, 8);
    try std.testing.expect(task.folded_cache != null);
    try std.testing.expectEqual(@as(usize, 1), task.total_matches);
    const old_fingerprint = task.folded_source;

    // Publish a replacement inode; the old mapped Store remains immutable.
    const next_root = try std.fs.path.join(fixture, &.{ root, "replacement" });
    try writeAliasTestBlob(fixture, next_root, .alias, "", &.{.{ .title = "1\tZulu", .payload = try aliasTestPayload(fixture, .{ .source = "Zulu", .target = "cat" }) }});
    const alias_path = try pathAlloc(fixture, root, .alias, "");
    const next_path = try pathAlloc(fixture, next_root, .alias, "");
    try std.Io.Dir.cwd().rename(next_path, std.Io.Dir.cwd(), alias_path, std.testing.io);
    var after = try Store.open(std.testing.io, a, root, .language, "English");
    defer after.deinit();
    try std.testing.expectEqual(before.count(), after.count());
    try std.testing.expectEqualSlices(u8, &before.file.fingerprint, &after.file.fingerprint);
    try task.begin(a, "zu");
    while (!task.complete) try task.step(a, &after, 8);
    try std.testing.expect(task.folded_cache != null);
    try std.testing.expect(!std.mem.eql(u8, &old_fingerprint, &task.folded_source));
    try std.testing.expectEqual(@as(usize, 1), task.total_matches);
    try std.testing.expectEqualStrings("Zulu", try after.titleAt(task.matches.items[0].index));
    var reopened: @import("search.zig").Task = .{ .folded_cache_min_records = 0 };
    defer reopened.deinit(a);
    try reopened.begin(a, "al");
    while (!reopened.complete) try reopened.step(a, &after, 8);
    try std.testing.expect(reopened.folded_cache != null);
    try std.testing.expectEqual(@as(usize, 0), reopened.total_matches);
}

test "neutral redirects require an empty manifest and no ordinary language files" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try writeAliasTestBlob(fixture, root, .alias, "", &.{
        .{ .title = "1\tA", .payload = try aliasTestPayload(fixture, .{ .source = "A", .target = "B", .fragment = "Incoming" }) },
        .{ .title = "1\tB", .payload = try aliasTestPayload(fixture, .{ .source = "B", .target = "Missing", .fragment = "Next" }) },
        .{ .title = "2\tOld", .payload = try aliasTestPayload(fixture, .{ .source = "Thesaurus:Old", .source_kind = .thesaurus, .target = "B" }) },
    });
    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.io, a, root, .language, "English"));
    const manifest = try std.fs.path.join(fixture, &.{ root, catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = catalog.manifest_header ++ "\n" });
    {
        var db = try Store.open(std.testing.io, a, root, .language, "English");
        defer db.deinit();
        try std.testing.expect(db.neutral_main);
        try std.testing.expect(db.heading() == null);
        try std.testing.expectEqual(Kind.language, db.selectionKind());
        const label = try db.labelAlloc(a);
        defer a.free(label);
        try std.testing.expectEqualStrings("Redirects", label);
        try std.testing.expectEqual(@as(usize, 2), db.count());
        try std.testing.expectEqual(@as(u64, 0), db.file.payload_reads);
        try std.testing.expectEqualStrings("A", try db.titleAt(0));
        try std.testing.expectEqual(@as(?usize, null), try db.find("Old"));
        const model = @import("model.zig");
        var raw = try db.recordAlloc(a, (try db.find("A")).?);
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expect(doc.entry.language == null);
        try std.testing.expectEqualStrings("B", doc.entry.title);
        try std.testing.expectEqualStrings("A", doc.entry.redirect.?.source_title);
        try std.testing.expectEqualStrings("Incoming", doc.entry.redirect.?.fragment);
        try std.testing.expect(doc.entry.redirect.?.followed);
        try std.testing.expectEqualStrings("Missing", doc.entry.alias.?.target_title);
        try std.testing.expectEqualStrings("Next", doc.entry.alias.?.fragment);
        var missing = try db.recordAlloc(a, (try db.find("B")).?);
        defer missing.deinit();
        var missing_doc = try model.fromRecord(a, missing.record);
        defer missing_doc.deinit();
        try std.testing.expectEqualStrings("B", missing_doc.entry.title);
        try std.testing.expect(!missing_doc.entry.redirect.?.followed);
    }
    try std.testing.expectError(error.InvalidArgument, Store.open(std.testing.io, a, root, .alias, ""));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = "heading\n\n" });
    try std.testing.expectError(error.InvalidManifest, Store.open(std.testing.io, a, root, .language, "English"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = "heading\nEnglish\n" });
    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.io, a, root, .language, "French"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = "heading\n" });
    // Even a manifest which omits an existing language cannot activate neutral mode.
    try writeAliasTestBlob(fixture, root, .language, "English", &.{});
    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.io, a, root, .language, "French"));
}
