const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("shared_xml_decode");
const blobs = @import("blob_encoder");
const blob_format = blobs.blob_format;
const blob_catalog = blobs.blob_catalog;
const language_encoding = blobs.language_blob_encoding;
const thesaurus_encoding = blobs.thesaurus_encoding;
const reconstruction_encoding = blobs.reconstruction_encoding;
const rhymes_encoding = blobs.rhymes_encoding;

const language_bucket_count = 32;
const ns_main: u32 = 0;
const ns_rhymes: u32 = 106;
const ns_thesaurus: u32 = 110;
const ns_citations: u32 = 114;
const ns_sign_gloss: u32 = 116;
const ns_reconstruction: u32 = 118;

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = false,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

pub const BuildOptions = struct {
    input_path: []const u8,
    output_root: []const u8,
    limit_pages: ?usize = null,
};

pub const BuildStats = struct {
    pages_seen: usize = 0,
    main_pages: usize = 0,
    language_records: usize = 0,
    thesaurus_records: usize = 0,
    citations_records: usize = 0,
    reconstruction_records: usize = 0,
    rhymes_records: usize = 0,
    sign_gloss_records: usize = 0,
    language_blobs: usize = 0,
};

const Capture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();
        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 2 and std.mem.eql(u8, self.names_by_depth[1], "revision") and std.mem.eql(u8, name, "text")) {
            self.text_raw = node.leadingTextRaw();
        }
        return true;
    }
};

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return .{ .bytes = &.{} };
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

const SpoolFile = struct {
    file: std.Io.File,
    path: []const u8,
    offset: u64 = 0,

    fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !SpoolFile {
        return .{
            .file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }),
            .path = try allocator.dupe(u8, path),
        };
    }

    fn close(self: *SpoolFile, io: std.Io) void {
        self.file.close(io);
    }

    fn deinitPath(self: *SpoolFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.path = "";
    }

    fn append(
        self: *SpoolFile,
        io: std.Io,
        allocator: std.mem.Allocator,
        key: []const u8,
        title: []const u8,
        payload: []const u8,
    ) !void {
        const key_len = std.math.cast(u32, key.len) orelse return error.RecordTooBig;
        const title_len = std.math.cast(u32, title.len) orelse return error.RecordTooBig;
        const payload_len = std.math.cast(u32, payload.len) orelse return error.RecordTooBig;
        const total = std.math.add(usize, 12, key.len + title.len + payload.len) catch return error.RecordTooBig;
        const frame = try allocator.alloc(u8, total);
        std.mem.writeInt(u32, frame[0..4], key_len, .little);
        std.mem.writeInt(u32, frame[4..8], title_len, .little);
        std.mem.writeInt(u32, frame[8..12], payload_len, .little);
        var cursor: usize = 12;
        @memcpy(frame[cursor .. cursor + key.len], key);
        cursor += key.len;
        @memcpy(frame[cursor .. cursor + title.len], title);
        cursor += title.len;
        @memcpy(frame[cursor .. cursor + payload.len], payload);
        try self.file.writePositionalAll(io, frame, self.offset);
        self.offset += frame.len;
    }
};

const SpoolFrame = struct {
    key: []const u8,
    title: []const u8,
    payload: []const u8,
};

const SpoolIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn next(self: *SpoolIterator) error{InvalidSpool}!?SpoolFrame {
        if (self.cursor == self.bytes.len) return null;
        if (self.cursor > self.bytes.len or 12 > self.bytes.len - self.cursor) return error.InvalidSpool;
        const key_len = std.mem.readInt(u32, self.bytes[self.cursor .. self.cursor + 4][0..4], .little);
        const title_len = std.mem.readInt(u32, self.bytes[self.cursor + 4 .. self.cursor + 8][0..4], .little);
        const payload_len = std.mem.readInt(u32, self.bytes[self.cursor + 8 .. self.cursor + 12][0..4], .little);
        self.cursor += 12;
        const total = std.math.add(usize, key_len, @as(usize, title_len) + payload_len) catch return error.InvalidSpool;
        if (total > self.bytes.len - self.cursor) return error.InvalidSpool;
        const key = self.bytes[self.cursor .. self.cursor + key_len];
        self.cursor += key_len;
        const title = self.bytes[self.cursor .. self.cursor + title_len];
        self.cursor += title_len;
        const payload = self.bytes[self.cursor .. self.cursor + payload_len];
        self.cursor += payload_len;
        if (title.len == 0) return error.InvalidSpool;
        return .{ .key = key, .title = title, .payload = payload };
    }
};

const Spools = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    language: [language_bucket_count]SpoolFile,
    thesaurus: SpoolFile,
    citations: SpoolFile,
    reconstruction: SpoolFile,
    rhymes: SpoolFile,
    sign_gloss: SpoolFile,

    fn init(io: std.Io, allocator: std.mem.Allocator, output_root: []const u8) !Spools {
        const spool_root = try std.fmt.allocPrint(allocator, "{s}/.spool", .{output_root});
        defer allocator.free(spool_root);
        try std.Io.Dir.cwd().createDirPath(io, spool_root);

        var language: [language_bucket_count]SpoolFile = undefined;
        var built: usize = 0;
        errdefer while (built != 0) {
            built -= 1;
            language[built].close(io);
            language[built].deinitPath(allocator);
        };
        for (&language, 0..) |*slot, idx| {
            const path = try std.fmt.allocPrint(allocator, "{s}/lang-{d:0>2}.tmp", .{ spool_root, idx });
            defer allocator.free(path);
            slot.* = try SpoolFile.init(io, allocator, path);
            built += 1;
        }

        const initFixed = struct {
            fn f(io2: std.Io, a: std.mem.Allocator, root: []const u8, name: []const u8) !SpoolFile {
                const path = try std.fmt.allocPrint(a, "{s}/{s}.tmp", .{ root, name });
                defer a.free(path);
                return SpoolFile.init(io2, a, path);
            }
        }.f;

        return .{
            .allocator = allocator,
            .io = io,
            .root = try allocator.dupe(u8, spool_root),
            .language = language,
            .thesaurus = try initFixed(io, allocator, spool_root, "thesaurus"),
            .citations = try initFixed(io, allocator, spool_root, "citations"),
            .reconstruction = try initFixed(io, allocator, spool_root, "reconstruction"),
            .rhymes = try initFixed(io, allocator, spool_root, "rhymes"),
            .sign_gloss = try initFixed(io, allocator, spool_root, "sign-gloss"),
        };
    }

    fn close(self: *Spools) void {
        for (&self.language) |*spool| spool.close(self.io);
        self.thesaurus.close(self.io);
        self.citations.close(self.io);
        self.reconstruction.close(self.io);
        self.rhymes.close(self.io);
        self.sign_gloss.close(self.io);
    }

    fn cleanup(self: *Spools) void {
        for (&self.language) |*spool| {
            std.Io.Dir.cwd().deleteFile(self.io, spool.path) catch {};
            spool.deinitPath(self.allocator);
        }
        inline for (.{ &self.thesaurus, &self.citations, &self.reconstruction, &self.rhymes, &self.sign_gloss }) |spool| {
            std.Io.Dir.cwd().deleteFile(self.io, spool.path) catch {};
            spool.deinitPath(self.allocator);
        }
        std.Io.Dir.cwd().deleteDir(self.io, self.root) catch {};
        self.allocator.free(self.root);
        self.root = "";
    }

    fn appendLanguage(self: *Spools, allocator: std.mem.Allocator, heading: []const u8, title: []const u8, payload: []const u8) !void {
        const bucket: usize = @intCast(std.hash.Wyhash.hash(0, heading) % language_bucket_count);
        try self.language[bucket].append(self.io, allocator, heading, title, payload);
    }
};

fn isRelevantPage(page: []const u8) bool {
    inline for ([_][]const u8{
        "<ns>0</ns>",
        "<ns>106</ns>",
        "<ns>110</ns>",
        "<ns>114</ns>",
        "<ns>116</ns>",
        "<ns>118</ns>",
    }) |needle| if (std.mem.indexOf(u8, page, needle) != null) return true;
    return false;
}

fn localNamespaceTitle(title: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, title, ':') orelse return title;
    if (colon + 1 >= title.len) return title;
    return title[colon + 1 ..];
}

pub fn languageBlobPathAlloc(allocator: std.mem.Allocator, output_root: []const u8, heading: []const u8) ![]u8 {
    var filename_buf: [blob_catalog.language_blob_filename_len]u8 = undefined;
    const filename = blob_catalog.languageBlobFilename(heading, &filename_buf);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ output_root, blob_catalog.language_directory, filename });
}

fn fixedBlobPathAlloc(allocator: std.mem.Allocator, output_root: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.wikblb", .{ output_root, name });
}

fn recordLess(_: void, lhs: blob_format.RecordInput, rhs: blob_format.RecordInput) bool {
    return std.mem.order(u8, lhs.title, rhs.title) == .lt;
}

fn sortAndValidate(records: []blob_format.RecordInput) !void {
    std.sort.pdq(blob_format.RecordInput, records, {}, recordLess);
    for (records[1..], records[0..records.len -| 1]) |current, previous| {
        if (std.mem.order(u8, previous.title, current.title) != .lt) return error.DuplicateRecord;
    }
}

fn writeBlobFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    kind: blob_format.BlobKind,
    metadata: []const u8,
    records: []blob_format.RecordInput,
) !void {
    try sortAndValidate(records);
    const metadata_len = std.math.cast(u16, metadata.len) orelse return error.BlobTooBig;
    const record_count = std.math.cast(u32, records.len) orelse return error.BlobTooBig;
    const offsets_len = std.math.mul(usize, records.len + 1, @sizeOf(u32)) catch return error.BlobTooBig;
    const offsets = try allocator.alloc(u8, offsets_len);
    defer allocator.free(offsets);

    var records_len: usize = 0;
    for (records, 0..) |record, idx| {
        const off = std.math.cast(u32, records_len) orelse return error.BlobTooBig;
        std.mem.writeInt(u32, offsets[idx * 4 .. idx * 4 + 4][0..4], off, .little);
        records_len = std.math.add(usize, records_len, record.title.len + 1 + record.payload.len) catch return error.BlobTooBig;
    }
    const final_off = std.math.cast(u32, records_len) orelse return error.BlobTooBig;
    std.mem.writeInt(u32, offsets[records.len * 4 .. records.len * 4 + 4][0..4], final_off, .little);
    const header = blob_format.encodeHeader(blob_format.Header.init(kind, metadata_len, record_count, final_off));

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&header);
    try w.writeAll(metadata);
    try w.writeAll(offsets);
    for (records) |record| {
        try w.writeAll(record.title);
        try w.writeByte(0);
        try w.writeAll(record.payload);
    }
    try w.flush();
}

fn collectFixedRecordsAlloc(allocator: std.mem.Allocator, mapped: []const u8) ![]blob_format.RecordInput {
    var records: std.ArrayList(blob_format.RecordInput) = .empty;
    defer records.deinit(allocator);
    var it: SpoolIterator = .{ .bytes = mapped };
    while (try it.next()) |frame| {
        if (frame.key.len != 0) return error.InvalidSpool;
        try records.append(allocator, .{ .title = frame.title, .payload = frame.payload });
    }
    return records.toOwnedSlice(allocator);
}

fn finalizeFixedSpool(
    io: std.Io,
    allocator: std.mem.Allocator,
    spool: *const SpoolFile,
    output_root: []const u8,
    name: []const u8,
    kind: blob_format.BlobKind,
) !void {
    var mapped = try mmapPath(io, spool.path);
    defer mapped.deinit();
    const records = try collectFixedRecordsAlloc(allocator, mapped.bytes);
    defer allocator.free(records);
    if (records.len == 0) return;
    const path = try fixedBlobPathAlloc(allocator, output_root, name);
    defer allocator.free(path);
    try writeBlobFile(io, allocator, path, kind, "", records);
}

const LanguageGroup = struct {
    heading: []const u8,
    records: std.ArrayListUnmanaged(blob_format.RecordInput) = .empty,
};

fn finalizeLanguageBucket(
    io: std.Io,
    allocator: std.mem.Allocator,
    spool: *const SpoolFile,
    output_root: []const u8,
    manifest: *std.Io.Writer,
) !usize {
    var mapped = try mmapPath(io, spool.path);
    defer mapped.deinit();
    if (mapped.bytes.len == 0) return 0;

    var groups = std.StringHashMapUnmanaged(LanguageGroup){};
    defer {
        var values = groups.valueIterator();
        while (values.next()) |group| group.records.deinit(allocator);
        groups.deinit(allocator);
    }
    var it: SpoolIterator = .{ .bytes = mapped.bytes };
    while (try it.next()) |frame| {
        if (frame.key.len == 0) return error.InvalidSpool;
        const gop = try groups.getOrPut(allocator, frame.key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .heading = frame.key };
        try gop.value_ptr.records.append(allocator, .{ .title = frame.title, .payload = frame.payload });
    }

    var ordered: std.ArrayList(*LanguageGroup) = .empty;
    defer ordered.deinit(allocator);
    var values = groups.valueIterator();
    while (values.next()) |group| try ordered.append(allocator, group);
    const lessGroup = struct {
        fn f(_: void, lhs: *LanguageGroup, rhs: *LanguageGroup) bool {
            return std.mem.order(u8, lhs.heading, rhs.heading) == .lt;
        }
    }.f;
    std.sort.pdq(*LanguageGroup, ordered.items, {}, lessGroup);

    var count: usize = 0;
    for (ordered.items) |group| {
        const metadata = try blob_format.buildLanguageMetadataAlloc(allocator, "", group.heading);
        defer allocator.free(metadata);
        const path = try languageBlobPathAlloc(allocator, output_root, group.heading);
        defer allocator.free(path);
        try writeBlobFile(io, allocator, path, .language, metadata, group.records.items);
        const base = std.fs.path.basename(path);
        try blob_catalog.writeEntry(manifest, group.heading, base, @intCast(group.records.items.len));
        count += 1;
    }
    return count;
}

fn processMain(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    title: []const u8,
    source: []const u8,
    stats: *BuildStats,
) !void {
    stats.main_pages += 1;
    var page_sections: std.ArrayList(language_encoding.SourceLanguageSection) = .empty;
    defer page_sections.deinit(page_allocator);
    var sections = language_encoding.SourceLanguageIterator.init(source);
    while (sections.next()) |section| try page_sections.append(page_allocator, section);

    for (page_sections.items, 0..) |section, index| {
        var seen_before = false;
        for (page_sections.items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.heading, section.heading)) {
                seen_before = true;
                break;
            }
        }
        if (seen_before) continue;

        var repeated = false;
        for (page_sections.items[index + 1 ..]) |later| {
            if (std.mem.eql(u8, later.heading, section.heading)) {
                repeated = true;
                break;
            }
        }
        const language: language_encoding.LanguageContext = .{ .heading = section.heading };
        const payload = if (repeated)
            try language_encoding.encodeRepeatedSectionsFallbackAlloc(page_allocator, page_sections.items, language)
        else
            try language_encoding.encodeRobustAlloc(page_allocator, section.source, language);
        try spools.appendLanguage(page_allocator, section.heading, title, payload);
        stats.language_records += 1;
    }
}

fn processNamespace(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    ns: u32,
    title: []const u8,
    source: []const u8,
    stats: *BuildStats,
) !void {
    const local_title = localNamespaceTitle(title);
    switch (ns) {
        ns_thesaurus => {
            const payload = try thesaurus_encoding.encodeAlloc(page_allocator, source);
            try spools.thesaurus.append(spools.io, page_allocator, "", local_title, payload);
            stats.thesaurus_records += 1;
        },
        ns_citations => {
            try spools.citations.append(spools.io, page_allocator, "", local_title, source);
            stats.citations_records += 1;
        },
        ns_reconstruction => {
            const payload = try reconstruction_encoding.encodeAlloc(page_allocator, source, local_title);
            try spools.reconstruction.append(spools.io, page_allocator, "", local_title, payload);
            stats.reconstruction_records += 1;
        },
        ns_rhymes => {
            const payload = try rhymes_encoding.encodeAlloc(page_allocator, source);
            try spools.rhymes.append(spools.io, page_allocator, "", local_title, payload);
            stats.rhymes_records += 1;
        },
        ns_sign_gloss => {
            try spools.sign_gloss.append(spools.io, page_allocator, "", local_title, source);
            stats.sign_gloss_records += 1;
        },
        else => unreachable,
    }
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn build(io: std.Io, allocator: std.mem.Allocator, options: BuildOptions) !BuildStats {
    try std.Io.Dir.cwd().createDirPath(io, options.output_root);
    const languages_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.output_root, blob_catalog.language_directory });
    defer allocator.free(languages_dir);
    try std.Io.Dir.cwd().deleteTree(io, languages_dir);
    try std.Io.Dir.cwd().createDirPath(io, languages_dir);
    inline for (.{ "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss" }) |name| {
        const stale = try fixedBlobPathAlloc(allocator, options.output_root, name);
        defer allocator.free(stale);
        try deleteFileIfExists(io, stale);
    }
    const stale_manifest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.output_root, blob_catalog.manifest_filename });
    defer allocator.free(stale_manifest);
    try deleteFileIfExists(io, stale_manifest);

    var spools = try Spools.init(io, allocator, options.output_root);
    defer spools.cleanup();
    var spools_closed = false;
    defer if (!spools_closed) spools.close();

    var mapped = try mmapPath(io, options.input_path);
    defer mapped.deinit();
    var parser = StreamParser.init(allocator);
    defer parser.deinit();
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    var stats: BuildStats = .{};
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>")) |start| {
        if (options.limit_pages) |limit| if (stats.pages_seen >= limit) break;
        const end_start = std.mem.indexOfPos(u8, mapped.bytes, start, "</page>") orelse return error.TruncatedXml;
        const page_end = end_start + "</page>".len;
        const page = mapped.bytes[start..page_end];
        pos = page_end;
        stats.pages_seen += 1;
        if (!isRelevantPage(page)) continue;

        var capture: Capture = .{};
        try parser.parse(page, &capture, Capture.onNode);
        const ns_raw = capture.ns_raw orelse continue;
        const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch continue;
        if (ns != ns_main and ns != ns_rhymes and ns != ns_thesaurus and ns != ns_citations and ns != ns_sign_gloss and ns != ns_reconstruction) continue;
        const title_raw = capture.title_raw orelse continue;
        const text_raw = capture.text_raw orelse continue;
        const page_allocator = page_arena.allocator();
        const title = try xml_decode.decodeSinglePassAlloc(page_allocator, title_raw);
        const source = try xml_decode.decodeSinglePassAlloc(page_allocator, text_raw);
        if (ns == ns_main) {
            try processMain(page_allocator, &spools, title, source, &stats);
        } else {
            try processNamespace(page_allocator, &spools, ns, title, source, &stats);
        }
        _ = page_arena.reset(.retain_capacity);
    }

    spools.close();
    spools_closed = true;

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.output_root, blob_catalog.manifest_filename });
    defer allocator.free(manifest_path);
    var manifest_file = try std.Io.Dir.cwd().createFile(io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(io);
    var manifest_buffer: [64 * 1024]u8 = undefined;
    var manifest_writer = manifest_file.writer(io, &manifest_buffer);
    const manifest = &manifest_writer.interface;
    try manifest.writeAll(blob_catalog.manifest_header ++ "\n");
    for (&spools.language) |*spool| stats.language_blobs += try finalizeLanguageBucket(io, allocator, spool, options.output_root, manifest);
    try manifest.flush();

    try finalizeFixedSpool(io, allocator, &spools.thesaurus, options.output_root, "thesaurus", .thesaurus);
    try finalizeFixedSpool(io, allocator, &spools.citations, options.output_root, "citations", .citations);
    try finalizeFixedSpool(io, allocator, &spools.reconstruction, options.output_root, "reconstruction", .reconstruction);
    try finalizeFixedSpool(io, allocator, &spools.rhymes, options.output_root, "rhymes", .rhymes);
    try finalizeFixedSpool(io, allocator, &spools.sign_gloss, options.output_root, "sign-gloss", .sign_gloss);
    return stats;
}

fn writeFixture(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

test "blob builder routes main languages and feature namespaces into separate blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(base);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sample.xml", .{base});
    defer std.testing.allocator.free(xml_path);
    const out_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs", .{base});
    defer std.testing.allocator.free(out_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, base);

    const xml =
        "<mediawiki>" ++
        "<page><title>cat</title><ns>0</ns><revision><text xml:space=\"preserve\">==English==\n===Noun===\n# [[cat]]\n==French==\n===Nom===\n# [[chat]]\n==English==\n===Verb===\n# purr\n</text></revision></page>" ++
        "<page><title>Thesaurus:cat</title><ns>110</ns><revision><text xml:space=\"preserve\">==English==\n===Noun===\n====Synonyms====\n{{ws beginlist}}\n{{ws|feline}}\n{{ws endlist}}\n</text></revision></page>" ++
        "<page><title>Rhymes:English/æt</title><ns>106</ns><revision><text xml:space=\"preserve\">==English==\n* {{l|en|cat}}\n</text></revision></page>" ++
        "<page><title>Citations:cat</title><ns>114</ns><revision><text xml:space=\"preserve\">citation raw</text></revision></page>" ++
        "<page><title>Sign gloss:CAT</title><ns>116</ns><revision><text xml:space=\"preserve\">sign raw</text></revision></page>" ++
        "<page><title>Reconstruction:Proto-Germanic/kattuz</title><ns>118</ns><revision><text xml:space=\"preserve\">{{reconstructed}}\n==Proto-Germanic==\n===Noun===\n# cat\n</text></revision></page>" ++
        "<page><title>Reconstruction:no-slash</title><ns>118</ns><revision><text xml:space=\"preserve\">raw malformed reconstruction</text></revision></page>" ++
        "</mediawiki>";
    try writeFixture(std.testing.io, xml_path, xml);
    const stats = try build(std.testing.io, std.testing.allocator, .{ .input_path = xml_path, .output_root = out_root });
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.reconstruction_records);

    const english_path = try languageBlobPathAlloc(std.testing.allocator, out_root, "English");
    defer std.testing.allocator.free(english_path);
    var english_map = try mmapPath(std.testing.io, english_path);
    defer english_map.deinit();
    const english_blob = try blob_format.inspect(english_map.bytes);
    const english_meta = try english_blob.languageMetadata();
    try std.testing.expectEqualStrings("English", english_meta.heading);
    const cat = (try english_blob.find("cat")).?;
    const english_source = try language_encoding.decodeAlloc(std.testing.allocator, cat.payload, .{ .heading = "English" });
    defer std.testing.allocator.free(english_source);
    try std.testing.expectEqualStrings("==English==\n===Noun===\n# [[cat]]\n==English==\n===Verb===\n# purr\n", english_source);

    const recon_path = try fixedBlobPathAlloc(std.testing.allocator, out_root, "reconstruction");
    defer std.testing.allocator.free(recon_path);
    var recon_map = try mmapPath(std.testing.io, recon_path);
    defer recon_map.deinit();
    const recon_blob = try blob_format.inspect(recon_map.bytes);
    const reconstruction = (try recon_blob.find("Proto-Germanic/kattuz")).?;
    const recon_source = try reconstruction_encoding.decodeAlloc(std.testing.allocator, reconstruction.payload, "Proto-Germanic/kattuz");
    defer std.testing.allocator.free(recon_source);
    try std.testing.expectEqualStrings("{{reconstructed}}\n==Proto-Germanic==\n===Noun===\n# cat\n", recon_source);
    const raw_reconstruction = (try recon_blob.find("no-slash")).?;
    const raw_recon_source = try reconstruction_encoding.decodeAlloc(std.testing.allocator, raw_reconstruction.payload, "no-slash");
    defer std.testing.allocator.free(raw_recon_source);
    try std.testing.expectEqualStrings("raw malformed reconstruction", raw_recon_source);

    const citations_path = try fixedBlobPathAlloc(std.testing.allocator, out_root, "citations");
    defer std.testing.allocator.free(citations_path);
    var citations_map = try mmapPath(std.testing.io, citations_path);
    defer citations_map.deinit();
    const citations_blob = try blob_format.inspect(citations_map.bytes);
    try std.testing.expectEqualStrings("citation raw", (try citations_blob.find("cat")).?.payload);

    const stale_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/languages/stale.wikblb", .{out_root});
    defer std.testing.allocator.free(stale_path);
    try writeFixture(std.testing.io, stale_path, "stale");
    _ = try build(std.testing.io, std.testing.allocator, .{ .input_path = xml_path, .output_root = out_root });
    const stale_file = std.Io.Dir.cwd().openFile(std.testing.io, stale_path, .{});
    if (stale_file) |file| {
        file.close(std.testing.io);
        return error.StaleOutputSurvived;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
}
