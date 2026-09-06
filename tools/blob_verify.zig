const std = @import("std");
const zxml = @import("zxml");
const encoder = @import("encoder");

const blob_format = encoder.blob_format;
const blob_catalog = encoder.blob_catalog;
const language_encoding = encoder.language_blob_encoding;
const reconstruction_encoding = encoder.reconstruction_encoding;
const thesaurus_encoding = encoder.thesaurus_encoding;
const rhymes_encoding = encoder.rhymes_encoding;
const xml_decode = encoder.xml_decode;

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

const BlobFile = struct {
    allocator: std.mem.Allocator,
    mapped: Mapped,
    indexed: blob_format.IndexedBlobView,
    resolver: ?encoder.blob_files.Resolver = null,

    fn deinit(self: *BlobFile) void {
        if (self.resolver) |*r| r.deinit();
        self.indexed.deinit(self.allocator);
        self.mapped.deinit();
    }

    fn find(self: BlobFile, title: []const u8) error{InvalidBlob}!?blob_format.RecordView {
        return self.indexed.find(title);
    }

    fn recordCount(self: BlobFile) usize {
        return self.indexed.recordCount();
    }
};

const LanguageBlobs = struct {
    manifest: Mapped,
    map: std.StringHashMap(BlobFile),
    expected_records: usize = 0,

    fn deinit(self: *LanguageBlobs) void {
        var it = self.map.valueIterator();
        while (it.next()) |blob| blob.deinit();
        self.map.deinit();
        self.manifest.deinit();
    }
    fn init(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !LanguageBlobs {
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, blob_catalog.manifest_filename });
        defer allocator.free(manifest_path);
        var manifest = try mmapPath(io, manifest_path);
        errdefer manifest.deinit();
        var map = std.StringHashMap(BlobFile).init(allocator);
        errdefer {
            var it = map.valueIterator();
            while (it.next()) |blob| blob.deinit();
            map.deinit();
        }

        var expected_records: usize = 0;
        var entries = try blob_catalog.Iterator.init(manifest.bytes);
        while (try entries.next()) |entry| {
            var filename_buf: [blob_catalog.language_blob_filename_len]u8 = undefined;
            const filename = blob_catalog.languageBlobFilename(entry.heading, &filename_buf);
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root, blob_catalog.language_directory, filename });
            defer allocator.free(path);
            var mapped = try mmapPath(io, path);
            errdefer mapped.deinit();
            const view = try blob_format.openTrusted(mapped.bytes);
            if (view.kind != .language) return error.InvalidLanguageBlob;
            const metadata = try view.languageMetadata();
            if (!std.mem.eql(u8, metadata.heading, entry.heading)) return error.InvalidLanguageBlob;
            var indexed = try view.buildIndexAlloc(allocator);
            errdefer indexed.deinit(allocator);
            const gop = try map.getOrPut(entry.heading);
            if (gop.found_existing) return error.InvalidManifest;
            gop.value_ptr.* = .{ .allocator = allocator, .mapped = mapped, .indexed = indexed, .resolver = .{ .io = io, .a = allocator, .root = root, .metadata = metadata } };
            expected_records += indexed.recordCount();
        }
        return .{
            .manifest = manifest,
            .map = map,
            .expected_records = expected_records,
        };
    }

    fn find(self: *const LanguageBlobs, heading: []const u8) ?*BlobFile {
        return self.map.getPtr(heading);
    }
};

const FixedBlobs = struct {
    thesaurus: ?BlobFile,
    citations: ?BlobFile,
    reconstruction: ?BlobFile,
    rhymes: ?BlobFile,
    sign_gloss: ?BlobFile,

    fn deinit(self: *FixedBlobs) void {
        if (self.thesaurus) |*blob| blob.deinit();
        if (self.citations) |*blob| blob.deinit();
        if (self.reconstruction) |*blob| blob.deinit();
        if (self.rhymes) |*blob| blob.deinit();
        if (self.sign_gloss) |*blob| blob.deinit();
    }

    fn fileForNamespace(self: *const FixedBlobs, ns: u32) ?BlobFile {
        return switch (ns) {
            ns_thesaurus => self.thesaurus,
            ns_citations => self.citations,
            ns_reconstruction => self.reconstruction,
            ns_rhymes => self.rhymes,
            ns_sign_gloss => self.sign_gloss,
            else => unreachable,
        };
    }

    fn recordCount(self: *const FixedBlobs, ns: u32) usize {
        const file = self.fileForNamespace(ns) orelse return 0;
        return file.recordCount();
    }
};

fn loadFixedBlob(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    kind: blob_format.BlobKind,
) !BlobFile {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.wikblb", .{ root, name });
    defer allocator.free(path);
    var mapped = try mmapPath(io, path);
    errdefer mapped.deinit();
    const view = try blob_format.openTrusted(mapped.bytes);
    if (view.kind != kind) return error.InvalidFeatureBlob;
    var indexed = try view.buildIndexAlloc(allocator);
    errdefer indexed.deinit(allocator);
    return .{ .allocator = allocator, .mapped = mapped, .indexed = indexed };
}

fn loadFixedBlobOptional(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    kind: blob_format.BlobKind,
) !?BlobFile {
    return loadFixedBlob(io, allocator, root, name, kind) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn loadFixedBlobs(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !FixedBlobs {
    var thesaurus = try loadFixedBlobOptional(io, allocator, root, "thesaurus", .thesaurus);
    errdefer if (thesaurus) |*blob| blob.deinit();
    var citations = try loadFixedBlobOptional(io, allocator, root, "citations", .citations);
    errdefer if (citations) |*blob| blob.deinit();
    var reconstruction = try loadFixedBlobOptional(io, allocator, root, "reconstruction", .reconstruction);
    errdefer if (reconstruction) |*blob| blob.deinit();
    var rhymes = try loadFixedBlobOptional(io, allocator, root, "rhymes", .rhymes);
    errdefer if (rhymes) |*blob| blob.deinit();
    var sign_gloss = try loadFixedBlobOptional(io, allocator, root, "sign-gloss", .sign_gloss);
    errdefer if (sign_gloss) |*blob| blob.deinit();
    return .{
        .thesaurus = thesaurus,
        .citations = citations,
        .reconstruction = reconstruction,
        .rhymes = rhymes,
        .sign_gloss = sign_gloss,
    };
}

const Stats = struct {
    pages_seen: usize = 0,
    main_pages: usize = 0,
    language_records: usize = 0,
    thesaurus_records: usize = 0,
    citations_records: usize = 0,
    reconstruction_records: usize = 0,
    rhymes_records: usize = 0,
    sign_gloss_records: usize = 0,
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

fn mismatchOffset(expected: []const u8, actual: []const u8) usize {
    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common and expected[i] == actual[i]) : (i += 1) {}
    return i;
}

fn requireEqual(title: []const u8, context: []const u8, expected: []const u8, actual: []const u8) !void {
    if (std.mem.eql(u8, expected, actual)) return;
    std.debug.print("blob mismatch title={s} context={s} expected={d} actual={d} first_diff={d}\n", .{
        title, context, expected.len, actual.len, mismatchOffset(expected, actual),
    });
    return error.PayloadMismatch;
}
fn verifyMain(
    page_allocator: std.mem.Allocator,
    language_blobs: *const LanguageBlobs,
    title: []const u8,
    source: []const u8,
    stats: *Stats,
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

        const blob = language_blobs.find(section.heading) orelse {
            std.debug.print("missing language blob heading={s} title={s}\n", .{ section.heading, title });
            return error.MissingLanguageBlob;
        };
        const record = (try blob.find(title)) orelse {
            std.debug.print("missing language record heading={s} title={s}\n", .{ section.heading, title });
            return error.MissingLanguageRecord;
        };
        const language: language_encoding.LanguageContext = .{ .heading = section.heading };
        const joined = try blob.resolver.?.resolveAlloc(page_allocator, title, record.payload);
        const decoded = try language_encoding.decodeAlloc(page_allocator, joined orelse record.payload, language);

        var repeated = false;
        for (page_sections.items[index + 1 ..]) |later| {
            if (std.mem.eql(u8, later.heading, section.heading)) {
                repeated = true;
                break;
            }
        }
        if (!repeated) {
            try requireEqual(title, section.heading, section.source, decoded);
        } else {
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(page_allocator);
            for (page_sections.items) |part| {
                if (std.mem.eql(u8, part.heading, section.heading)) {
                    try expected.appendSlice(page_allocator, part.source);
                }
            }
            try requireEqual(title, section.heading, expected.items, decoded);
        }
        stats.language_records += 1;
    }
}
fn verifyNamespace(
    page_allocator: std.mem.Allocator,
    fixed: *const FixedBlobs,
    symbols: *encoder.blob_files.SymbolSource,
    ns: u32,
    title: []const u8,
    source: []const u8,
    stats: *Stats,
) !void {
    const local_title = localNamespaceTitle(title);
    const blob = fixed.fileForNamespace(ns) orelse {
        std.debug.print("missing feature blob ns={d} title={s}\n", .{ ns, local_title });
        return error.MissingFeatureBlob;
    };
    const record = (try blob.find(local_title)) orelse {
        std.debug.print("missing feature record ns={d} title={s}\n", .{ ns, local_title });
        return error.MissingFeatureRecord;
    };

    const bound = try symbols.bindAlloc(page_allocator, record.payload, blob.indexed.blob.symbolic, blob.indexed.blob.binding_id);
    const payload = bound orelse record.payload;
    switch (ns) {
        ns_thesaurus => {
            const decoded = try thesaurus_encoding.decodeAlloc(page_allocator, payload);
            try requireEqual(local_title, "thesaurus", source, decoded);
            stats.thesaurus_records += 1;
        },
        ns_citations => {
            try requireEqual(local_title, "citations", source, payload);
            stats.citations_records += 1;
        },
        ns_reconstruction => {
            const decoded = try reconstruction_encoding.decodeAlloc(page_allocator, payload, local_title);
            try requireEqual(local_title, "reconstruction", source, decoded);
            stats.reconstruction_records += 1;
        },
        ns_rhymes => {
            const decoded = try rhymes_encoding.decodeAlloc(page_allocator, payload);
            try requireEqual(local_title, "rhymes", source, decoded);
            stats.rhymes_records += 1;
        },
        ns_sign_gloss => {
            try requireEqual(local_title, "sign-gloss", source, payload);
            stats.sign_gloss_records += 1;
        },
        else => unreachable,
    }
}

fn requireCount(label: []const u8, expected: usize, actual: usize) !void {
    if (expected == actual) return;
    std.debug.print("blob count mismatch {s}: expected={d} actual={d}\n", .{ label, expected, actual });
    return error.RecordCountMismatch;
}
fn verifyCounts(language_blobs: *const LanguageBlobs, fixed: *const FixedBlobs, stats: Stats) !void {
    try requireCount("languages", language_blobs.expected_records, stats.language_records);
    try requireCount("thesaurus", fixed.recordCount(ns_thesaurus), stats.thesaurus_records);
    try requireCount("citations", fixed.recordCount(ns_citations), stats.citations_records);
    try requireCount("reconstruction", fixed.recordCount(ns_reconstruction), stats.reconstruction_records);
    try requireCount("rhymes", fixed.recordCount(ns_rhymes), stats.rhymes_records);
    try requireCount("sign-gloss", fixed.recordCount(ns_sign_gloss), stats.sign_gloss_records);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) {
        std.debug.print("usage: dict-blob-verify <wiktionary.xml> <output-root> [limit-pages]\n", .{});
        return error.Usage;
    }
    const limit_pages = if (args.len == 4) try std.fmt.parseInt(usize, args[3], 10) else null;

    const allocator = std.heap.smp_allocator;
    try encoder.blob_files.requireComplete(init.io, allocator, args[2]);
    var symbols: encoder.blob_files.SymbolSource = .{ .io = init.io, .a = allocator, .root = args[2] };
    defer symbols.deinit();
    var language_blobs = try LanguageBlobs.init(init.io, allocator, args[2]);
    var symbol_files = language_blobs.map.valueIterator();
    while (symbol_files.next()) |file| {
        file.resolver.?.symbols = &symbols;
        file.resolver.?.symbolic = file.indexed.blob.symbolic;
        file.resolver.?.binding_id = file.indexed.blob.binding_id;
    }
    defer language_blobs.deinit();
    var fixed = try loadFixedBlobs(init.io, allocator, args[2]);
    defer fixed.deinit();

    var dump = try mmapPath(init.io, args[1]);
    defer dump.deinit();
    var parser = StreamParser.init(allocator);
    defer parser.deinit();
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    var stats: Stats = .{};
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, dump.bytes, pos, "<page>")) |start| {
        if (limit_pages) |limit| if (stats.pages_seen >= limit) break;
        const end_start = std.mem.indexOfPos(u8, dump.bytes, start, "</page>") orelse return error.TruncatedXml;
        const page_end = end_start + "</page>".len;
        const page = dump.bytes[start..page_end];
        pos = page_end;
        stats.pages_seen += 1;
        if (stats.pages_seen % 1_000_000 == 0) {
            std.debug.print("verified pages={d} language_records={d}\n", .{ stats.pages_seen, stats.language_records });
        }
        if (!isRelevantPage(page)) continue;

        var capture: Capture = .{};
        try parser.parse(page, &capture, Capture.onNode);
        const ns_raw = capture.ns_raw orelse continue;
        const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch continue;
        if (ns != ns_main and ns != ns_rhymes and ns != ns_thesaurus and ns != ns_citations and
            ns != ns_sign_gloss and ns != ns_reconstruction) continue;
        const title_raw = capture.title_raw orelse continue;
        const text_raw = capture.text_raw orelse continue;
        const page_allocator = page_arena.allocator();
        const title = try xml_decode.decodeSinglePassAlloc(page_allocator, title_raw);
        const source = try xml_decode.decodeSinglePassAlloc(page_allocator, text_raw);
        if (ns == ns_main) {
            try verifyMain(page_allocator, &language_blobs, title, source, &stats);
        } else {
            try verifyNamespace(page_allocator, &fixed, &symbols, ns, title, source, &stats);
        }
        _ = page_arena.reset(.retain_capacity);
    }
    try verifyCounts(&language_blobs, &fixed, stats);
    var language_files = language_blobs.map.valueIterator();
    while (language_files.next()) |file| try file.resolver.?.verifyCounts();
    std.debug.print(
        "pages={d} main_pages={d} language_records={d} language_blobs={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d}\n",
        .{
            stats.pages_seen,
            stats.main_pages,
            stats.language_records,
            language_blobs.map.count(),
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
        },
    );
}
