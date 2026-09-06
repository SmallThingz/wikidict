const std = @import("std");
const zxml = @import("zxml");
const encoder = @import("encoder");

const blob_format = encoder.blob_format;
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
    mapped: Mapped,
    view: blob_format.BlobView,
};

const LanguageBlobs = struct {
    allocator: std.mem.Allocator,
    manifest: Mapped,
    map: std.StringHashMap(BlobFile),
    expected_records: u64 = 0,

    fn deinit(self: *LanguageBlobs) void {
        var it = self.map.valueIterator();
        while (it.next()) |blob| blob.mapped.deinit();
        self.map.deinit();
        self.manifest.deinit();
    }
    fn init(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !LanguageBlobs {
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/languages.tsv", .{root});
        defer allocator.free(manifest_path);
        var manifest = try mmapPath(io, manifest_path);
        errdefer manifest.deinit();
        var map = std.StringHashMap(BlobFile).init(allocator);
        errdefer {
            var it = map.valueIterator();
            while (it.next()) |blob| blob.mapped.deinit();
            map.deinit();
        }

        var expected_records: u64 = 0;
        var lines = std.mem.splitScalar(u8, manifest.bytes, '\n');
        const header = lines.next() orelse return error.EmptyManifest;
        if (!std.mem.eql(u8, header, "heading\tfile\trecords")) return error.InvalidManifest;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const heading = fields.next() orelse return error.InvalidManifest;
            const filename = fields.next() orelse return error.InvalidManifest;
            const count_text = fields.next() orelse return error.InvalidManifest;
            if (fields.next() != null) return error.InvalidManifest;
            const expected = try std.fmt.parseInt(u32, count_text, 10);
            const path = try std.fmt.allocPrint(allocator, "{s}/languages/{s}", .{ root, filename });
            defer allocator.free(path);
            var mapped = try mmapPath(io, path);
            errdefer mapped.deinit();
            const view = try blob_format.inspect(mapped.bytes);
            if (view.kind != .language) return error.InvalidLanguageBlob;
            const metadata = try view.languageMetadata();
            if (!std.mem.eql(u8, metadata.heading, heading)) return error.InvalidLanguageBlob;
            if (view.header.record_count != expected) return error.InvalidLanguageBlob;
            try map.putNoClobber(heading, .{ .mapped = mapped, .view = view });
            expected_records += expected;
        }
        return .{
            .allocator = allocator,
            .manifest = manifest,
            .map = map,
            .expected_records = expected_records,
        };
    }

    fn find(self: *const LanguageBlobs, heading: []const u8) ?blob_format.BlobView {
        const file = self.map.get(heading) orelse return null;
        return file.view;
    }
};

const FixedBlobs = struct {
    thesaurus: BlobFile,
    citations: BlobFile,
    reconstruction: BlobFile,
    rhymes: BlobFile,
    sign_gloss: BlobFile,
    fn deinit(self: *FixedBlobs) void {
        self.thesaurus.mapped.deinit();
        self.citations.mapped.deinit();
        self.reconstruction.mapped.deinit();
        self.rhymes.mapped.deinit();
        self.sign_gloss.mapped.deinit();
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
    const view = try blob_format.inspect(mapped.bytes);
    if (view.kind != kind) return error.InvalidFeatureBlob;
    return .{ .mapped = mapped, .view = view };
}

fn loadFixedBlobs(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !FixedBlobs {
    var thesaurus = try loadFixedBlob(io, allocator, root, "thesaurus", .thesaurus);
    errdefer thesaurus.mapped.deinit();
    var citations = try loadFixedBlob(io, allocator, root, "citations", .citations);
    errdefer citations.mapped.deinit();
    var reconstruction = try loadFixedBlob(io, allocator, root, "reconstruction", .reconstruction);
    errdefer reconstruction.mapped.deinit();
    var rhymes = try loadFixedBlob(io, allocator, root, "rhymes", .rhymes);
    errdefer rhymes.mapped.deinit();
    var sign_gloss = try loadFixedBlob(io, allocator, root, "sign-gloss", .sign_gloss);
    errdefer sign_gloss.mapped.deinit();
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
        const decoded = try language_encoding.decodeAlloc(page_allocator, record.payload, language);

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
    ns: u32,
    title: []const u8,
    source: []const u8,
    stats: *Stats,
) !void {
    const local_title = localNamespaceTitle(title);
    const blob = switch (ns) {
        ns_thesaurus => fixed.thesaurus.view,
        ns_citations => fixed.citations.view,
        ns_reconstruction => fixed.reconstruction.view,
        ns_rhymes => fixed.rhymes.view,
        ns_sign_gloss => fixed.sign_gloss.view,
        else => unreachable,
    };
    const record = (try blob.find(local_title)) orelse {
        std.debug.print("missing feature record ns={d} title={s}\n", .{ ns, local_title });
        return error.MissingFeatureRecord;
    };

    switch (ns) {
        ns_thesaurus => {
            const decoded = try thesaurus_encoding.decodeAlloc(page_allocator, record.payload);
            try requireEqual(local_title, "thesaurus", source, decoded);
            stats.thesaurus_records += 1;
        },
        ns_citations => {
            try requireEqual(local_title, "citations", source, record.payload);
            stats.citations_records += 1;
        },
        ns_reconstruction => {
            const decoded = try reconstruction_encoding.decodeAlloc(page_allocator, record.payload, local_title);
            try requireEqual(local_title, "reconstruction", source, decoded);
            stats.reconstruction_records += 1;
        },
        ns_rhymes => {
            const decoded = try rhymes_encoding.decodeAlloc(page_allocator, record.payload);
            try requireEqual(local_title, "rhymes", source, decoded);
            stats.rhymes_records += 1;
        },
        ns_sign_gloss => {
            try requireEqual(local_title, "sign-gloss", source, record.payload);
            stats.sign_gloss_records += 1;
        },
        else => unreachable,
    }
}

fn requireCount(label: []const u8, expected: u64, actual: usize) !void {
    if (expected == actual) return;
    std.debug.print("blob count mismatch {s}: expected={d} actual={d}\n", .{ label, expected, actual });
    return error.RecordCountMismatch;
}
fn verifyCounts(language_blobs: *const LanguageBlobs, fixed: *const FixedBlobs, stats: Stats) !void {
    try requireCount("languages", language_blobs.expected_records, stats.language_records);
    try requireCount("thesaurus", fixed.thesaurus.view.header.record_count, stats.thesaurus_records);
    try requireCount("citations", fixed.citations.view.header.record_count, stats.citations_records);
    try requireCount("reconstruction", fixed.reconstruction.view.header.record_count, stats.reconstruction_records);
    try requireCount("rhymes", fixed.rhymes.view.header.record_count, stats.rhymes_records);
    try requireCount("sign-gloss", fixed.sign_gloss.view.header.record_count, stats.sign_gloss_records);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: dict-blob-verify <wiktionary.xml> <output-root>\n", .{});
        return error.Usage;
    }

    const allocator = std.heap.smp_allocator;
    var language_blobs = try LanguageBlobs.init(init.io, allocator, args[2]);
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
            try verifyNamespace(page_allocator, &fixed, ns, title, source, &stats);
        }
        _ = page_arena.reset(.retain_capacity);
    }
    try verifyCounts(&language_blobs, &fixed, stats);
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
