const std = @import("std");
const blobs = @import("blob_encoder");
const blob_format = blobs.blob_format;
const blob_catalog = blobs.blob_catalog;
const language_source = @import("language_source.zig");
const presentation_document = @import("presentation_document.zig");

const language_bucket_count = 32;
const ns_main: u32 = 0;
const ns_rhymes: u32 = 106;
const ns_thesaurus: u32 = 110;
const ns_citations: u32 = 114;
const ns_sign_gloss: u32 = 116;
const ns_reconstruction: u32 = 118;

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
    fallback_pages: usize = 0,
};

pub const LanguageCodes = struct {
    ctx: ?*const anyopaque = null,
    get_fn: *const fn (?*const anyopaque, []const u8) ?[]const u8,

    pub fn code(self: LanguageCodes, heading: []const u8) ?[]const u8 {
        return self.get_fn(self.ctx, heading);
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
    path: []const u8,
    kind: blob_format.BlobKind,
    metadata: []const u8,
    records: []blob_format.RecordInput,
) !void {
    try sortAndValidate(records);
    try blob_format.validateMetadata(kind, metadata);
    for (records) |record| try blob_format.validateRecordInput(record);
    const header = blob_format.encodeHeader(kind);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&header);
    try w.writeAll(metadata);
    for (records) |record| {
        try w.writeAll(record.title);
        try w.writeByte(0);
        var length_buf: [blob_format.max_varuint_len]u8 = undefined;
        try w.writeAll(blob_format.encodePayloadLength(record.payload.len, &length_buf));
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
    try writeBlobFile(io, path, kind, "", records);
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
    manifest: *std.ArrayList([]const u8),
    codes: LanguageCodes,
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
        const metadata = try blob_format.buildLanguageMetadataAlloc(allocator, codes.code(group.heading) orelse "", group.heading);
        defer allocator.free(metadata);
        const path = try languageBlobPathAlloc(allocator, output_root, group.heading);
        defer allocator.free(path);
        try writeBlobFile(io, path, .language, metadata, group.records.items);
        const heading = try allocator.dupe(u8, group.heading);
        errdefer allocator.free(heading);
        try manifest.append(allocator, heading);
        count += 1;
    }
    return count;
}

fn processMain(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    title: []const u8,
    source: []const u8,
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
) !void {
    stats.main_pages += 1;
    var page_sections: std.ArrayList(language_source.Section) = .empty;
    defer page_sections.deinit(page_allocator);
    var sections = language_source.Iterator.init(source);
    while (sections.next()) |section| try page_sections.append(page_allocator, section);
    if (page_sections.items.len == 0 and std.mem.trim(u8, source, " \t\r\n").len != 0) {
        fallbacks.missing_language_heading = true;
        try page_sections.append(page_allocator, .{ .heading = "Unclassified", .source = source });
    }

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
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(page_allocator);
        const expanded = if (repeated) blk: {
            for (page_sections.items) |candidate| if (std.mem.eql(u8, candidate.heading, section.heading))
                try joined.appendSlice(page_allocator, candidate.source);
            break :blk joined.items;
        } else section.source;
        const payload = try presentation_document.compileReportedAlloc(
            page_allocator,
            title,
            .language,
            section.heading,
            "",
            expanded,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            fallbacks,
        );
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
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
) !void {
    const local_title = localNamespaceTitle(title);
    const kind: blob_format.BlobKind = switch (ns) {
        ns_thesaurus => .thesaurus,
        ns_citations => .citations,
        ns_reconstruction => .reconstruction,
        ns_rhymes => .rhymes,
        ns_sign_gloss => .sign_gloss,
        else => unreachable,
    };
    const payload = try presentation_document.compileReportedAlloc(
        page_allocator,
        local_title,
        kind,
        null,
        "",
        source,
        if (display_title) |value| .{ .source = value, .page_title = title } else null,
        fallbacks,
    );
    switch (kind) {
        .thesaurus => {
            try spools.thesaurus.append(spools.io, page_allocator, "", local_title, payload);
            stats.thesaurus_records += 1;
        },
        .citations => {
            try spools.citations.append(spools.io, page_allocator, "", local_title, payload);
            stats.citations_records += 1;
        },
        .reconstruction => {
            try spools.reconstruction.append(spools.io, page_allocator, "", local_title, payload);
            stats.reconstruction_records += 1;
        },
        .rhymes => {
            try spools.rhymes.append(spools.io, page_allocator, "", local_title, payload);
            stats.rhymes_records += 1;
        },
        .sign_gloss => {
            try spools.sign_gloss.append(spools.io, page_allocator, "", local_title, payload);
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

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    spools: Spools,
    fallback_file: std.Io.File,
    stats: BuildStats = .{},
    closed: bool = false,
    finished: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, output_root: []const u8) !Writer {
        try std.Io.Dir.cwd().createDirPath(io, output_root);
        const languages_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, blob_catalog.language_directory });
        defer allocator.free(languages_dir);
        try std.Io.Dir.cwd().deleteTree(io, languages_dir);
        try std.Io.Dir.cwd().createDirPath(io, languages_dir);
        inline for (.{ "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss", "symbols", "templates", "redirects", "pages" }) |name| {
            const stale = try fixedBlobPathAlloc(allocator, output_root, name);
            defer allocator.free(stale);
            try deleteFileIfExists(io, stale);
        }
        const stale_manifest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, blob_catalog.manifest_filename });
        defer allocator.free(stale_manifest);
        try deleteFileIfExists(io, stale_manifest);

        const owned_root = try allocator.dupe(u8, output_root);
        errdefer allocator.free(owned_root);
        var spools = try Spools.init(io, allocator, output_root);
        errdefer {
            spools.close();
            spools.cleanup();
        }
        const report_path = try std.fs.path.join(allocator, &.{ output_root, "fallback-pages.jsonl" });
        defer allocator.free(report_path);
        return .{
            .io = io,
            .allocator = allocator,
            .output_root = owned_root,
            .spools = spools,
            .fallback_file = try std.Io.Dir.cwd().createFile(io, report_path, .{ .truncate = true }),
        };
    }

    pub fn deinit(self: *Writer) void {
        if (!self.closed) self.spools.close();
        self.fallback_file.close(self.io);
        self.spools.cleanup();
        self.allocator.free(self.output_root);
        self.* = undefined;
    }

    pub fn addPage(self: *Writer, page_allocator: std.mem.Allocator, ns: u32, title: []const u8, source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageWithFallbackReasons(page_allocator, ns, title, source, display_title, .{}, &.{});
    }

    pub fn addPageWithFallback(self: *Writer, page_allocator: std.mem.Allocator, ns: u32, title: []const u8, source: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks) !void {
        return self.addPageWithFallbackReasons(page_allocator, ns, title, source, display_title, initial_fallbacks, &.{});
    }

    pub fn addPageWithFallbackReasons(
        self: *Writer,
        page_allocator: std.mem.Allocator,
        ns: u32,
        title: []const u8,
        source: []const u8,
        display_title: ?[]const u8,
        initial_fallbacks: presentation_document.Fallbacks,
        extra_reasons: []const []const u8,
    ) !void {
        if (self.finished) return error.WriterFinished;
        var fallbacks = initial_fallbacks;
        if (ns == ns_main) {
            try processMain(page_allocator, &self.spools, title, source, display_title, &self.stats, &fallbacks);
        } else if (ns == ns_rhymes or ns == ns_thesaurus or ns == ns_citations or ns == ns_sign_gloss or ns == ns_reconstruction) {
            try processNamespace(page_allocator, &self.spools, ns, title, source, display_title, &self.stats, &fallbacks);
        }
        if (fallbacks.any() or extra_reasons.len != 0) {
            var reasons: std.ArrayList([]const u8) = .empty;
            defer reasons.deinit(page_allocator);
            inline for (@typeInfo(presentation_document.Fallbacks).@"struct".fields) |field|
                if (@field(fallbacks, field.name)) try reasons.append(page_allocator, field.name);
            for (extra_reasons) |reason| {
                if (reason.len == 0) continue;
                var duplicate = false;
                for (reasons.items) |existing| if (std.mem.eql(u8, existing, reason)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) try reasons.append(page_allocator, reason);
            }
            const line = try std.json.Stringify.valueAlloc(page_allocator, .{
                .namespace = ns,
                .title = title,
                .reasons = reasons.items,
            }, .{});
            defer page_allocator.free(line);
            var buffer: [4096]u8 = undefined;
            var output = self.fallback_file.writerStreaming(self.io, &buffer);
            try output.interface.writeAll(line);
            try output.interface.writeByte('\n');
            try output.interface.flush();
            self.stats.fallback_pages += 1;
        }
    }

    pub fn finish(self: *Writer, codes: LanguageCodes) !BuildStats {
        if (self.finished) return error.WriterFinished;
        if (!self.closed) {
            self.spools.close();
            self.closed = true;
        }

        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.output_root, blob_catalog.manifest_filename });
        defer self.allocator.free(manifest_path);
        var manifest_file = try std.Io.Dir.cwd().createFile(self.io, manifest_path, .{ .truncate = true });
        defer manifest_file.close(self.io);
        var manifest_buffer: [64 * 1024]u8 = undefined;
        var manifest_writer = manifest_file.writer(self.io, &manifest_buffer);
        const manifest = &manifest_writer.interface;
        var headings: std.ArrayList([]const u8) = .empty;
        defer {
            for (headings.items) |heading| self.allocator.free(heading);
            headings.deinit(self.allocator);
        }
        for (&self.spools.language) |*spool|
            self.stats.language_blobs += try finalizeLanguageBucket(self.io, self.allocator, spool, self.output_root, &headings, codes);
        std.mem.sort([]const u8, headings.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        try manifest.writeAll(blob_catalog.manifest_header ++ "\n");
        for (headings.items) |heading| try blob_catalog.writeEntry(manifest, heading);
        try manifest.flush();

        try finalizeFixedSpool(self.io, self.allocator, &self.spools.thesaurus, self.output_root, "thesaurus", .thesaurus);
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.citations, self.output_root, "citations", .citations);
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.reconstruction, self.output_root, "reconstruction", .reconstruction);
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.rhymes, self.output_root, "rhymes", .rhymes);
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.sign_gloss, self.output_root, "sign-gloss", .sign_gloss);
        self.finished = true;
        return self.stats;
    }
};

test "wikitext writer emits only data blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    defer std.testing.allocator.free(out_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, out_root);

    const codes: LanguageCodes = .{
        .get_fn = struct {
            fn get(_: ?*const anyopaque, heading: []const u8) ?[]const u8 {
                if (std.mem.eql(u8, heading, "English")) return "en";
                if (std.mem.eql(u8, heading, "French")) return "fr";
                return null;
            }
        }.get,
    };
    var writer = try Writer.init(std.testing.io, std.testing.allocator, out_root);
    defer writer.deinit();
    writer.stats.pages_seen = 3;
    var page_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer page_arena.deinit();
    try writer.addPage(page_arena.allocator(), 0, "cat", "==English==\n===Noun===\n# [[cat]]\n==French==\n===Nom===\n# [[chat]]\n==English==\n===Verb===\n# purr\n", "<i>cat</i>");
    _ = page_arena.reset(.retain_capacity);
    try writer.addPage(page_arena.allocator(), 114, "Citations:cat", "citation raw", null);
    _ = page_arena.reset(.retain_capacity);
    try writer.addPage(page_arena.allocator(), 118, "Reconstruction:Proto-Germanic/kattuz", "==Proto-Germanic==\n===Noun===\n# cat\n", null);
    _ = page_arena.reset(.retain_capacity);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);

    const english_path = try languageBlobPathAlloc(std.testing.allocator, out_root, "English");
    defer std.testing.allocator.free(english_path);
    var english_map = try mmapPath(std.testing.io, english_path);
    defer english_map.deinit();
    const english_blob = try blob_format.inspect(english_map.bytes);
    const metadata = try english_blob.languageMetadata();
    try std.testing.expectEqualStrings("en", metadata.code);
    var english_index = try english_blob.buildTrustedIndexAlloc(std.testing.allocator);
    defer english_index.deinit(std.testing.allocator);
    const cat = (try english_index.find("cat")).?;
    var decode_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decode_arena.deinit();
    const parsed = try blobs.presentation_codec.decodeAlloc(decode_arena.allocator(), cat.payload, "cat", .language, metadata);
    try std.testing.expectEqualStrings(blobs.presentation_types.schema, parsed.schema);
    try std.testing.expectEqualStrings("cat", parsed.entry.title);
    try std.testing.expectEqual(@as(usize, 1), parsed.entry.display_title.len);
    try std.testing.expect(parsed.entry.display_title[0].italic);
    try std.testing.expectEqualStrings("cat", parsed.entry.display_title[0].text);
    try std.testing.expectEqual(blob_format.BlobKind.language, parsed.entry.kind);
    var saw_noun = false;
    var saw_verb = false;
    for (parsed.entry.sections) |section| {
        saw_noun = saw_noun or std.mem.eql(u8, section.title, "Noun");
        saw_verb = saw_verb or std.mem.eql(u8, section.title, "Verb");
    }
    try std.testing.expect(saw_noun and saw_verb);

    inline for (.{ "symbols", "templates", "redirects", "pages" }) |name| {
        const path = try fixedBlobPathAlloc(std.testing.allocator, out_root, name);
        defer std.testing.allocator.free(path);
        const opened = std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
        if (opened) |file| {
            file.close(std.testing.io);
            return error.RuntimeArtifactLeaked;
        } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    }
}

test "fallback report names every recovered page and retains unclassified entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    try writer.addPage(a, 0, "quoted\"title", "No heading, but readable content.", null);
    try writer.addPage(a, 0, "broken", "==English==\nB ]]word]]", null);
    try writer.addPageWithFallbackReasons(a, 0, "timeout", "==English==\nScript error: Timeout", null, .{ .expansion_error = true }, &.{"expansion_error:Timeout"});
    try writer.addPage(a, 0, "normal", "==English==\n# Normal definition.", null);
    const stats = try writer.finish(.{ .get_fn = struct {
        fn get(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    }.get });
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.fallback_pages);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const first = try std.json.parseFromSlice(std.json.Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("quoted\"title", first.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("missing_language_heading", first.value.object.get("reasons").?.array.items[0].string);
    const second = try std.json.parseFromSlice(std.json.Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("broken", second.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("literal_markup", second.value.object.get("reasons").?.array.items[0].string);
    const third = try std.json.parseFromSlice(std.json.Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("timeout", third.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("expansion_error", third.value.object.get("reasons").?.array.items[0].string);
    try std.testing.expectEqualStrings("expansion_error:Timeout", third.value.object.get("reasons").?.array.items[1].string);
    try std.testing.expect(lines.next() == null);
}
