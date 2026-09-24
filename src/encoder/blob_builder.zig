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

pub const ResolvedLanguage = struct {
    code: []const u8,
    heading: []const u8,
};

fn noLanguageCode(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

pub const LanguageCodes = struct {
    ctx: ?*const anyopaque = null,
    get_fn: *const fn (?*const anyopaque, []const u8) ?[]const u8 = noLanguageCode,
    resolve_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    trusted_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    strong_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    content_fn: ?*const fn (?*const anyopaque) ?ResolvedLanguage = null,

    pub fn code(self: LanguageCodes, heading: []const u8) ?[]const u8 {
        return self.get_fn(self.ctx, heading);
    }

    pub fn resolve(self: LanguageCodes, value: []const u8) ?ResolvedLanguage {
        if (self.resolve_fn) |resolve_fn| return resolve_fn(self.ctx, value);
        const code_value = self.code(value) orelse return null;
        return .{ .code = code_value, .heading = value };
    }

    pub fn resolveTrusted(self: LanguageCodes, value: []const u8) ?ResolvedLanguage {
        if (self.trusted_fn) |trusted_fn| return trusted_fn(self.ctx, value);
        return self.resolve(value);
    }

    pub fn resolveStrong(self: LanguageCodes, value: []const u8) ?ResolvedLanguage {
        if (self.strong_fn) |strong_fn| return strong_fn(self.ctx, value);
        return null;
    }

    pub fn content(self: LanguageCodes) ?ResolvedLanguage {
        const content_fn = self.content_fn orelse return null;
        return content_fn(self.ctx);
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

fn resolveTrimmed(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const candidate = std.mem.trim(u8, value, " \t\r\n'\"[]");
    if (candidate.len == 0) return null;
    return codes.resolve(candidate);
}

fn resolveTemplateName(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const trimmed = std.mem.trim(u8, value, " \t\r\n=-");
    if (resolveTrimmed(codes, trimmed)) |resolved| return resolved;

    var end_at = trimmed.len;
    while (std.mem.lastIndexOfScalar(u8, trimmed[0..end_at], ' ')) |space| {
        const prefix = std.mem.trim(u8, trimmed[0..space], " \t");
        if (resolveTrimmed(codes, prefix)) |resolved| return resolved;
        end_at = space;
    }
    var start_at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, trimmed, start_at, ' ')) |space| {
        start_at = space + 1;
        const suffix = std.mem.trim(u8, trimmed[start_at..], " \t");
        if (resolveTrimmed(codes, suffix)) |resolved| return resolved;
    }
    return null;
}

fn resolveTemplateCandidates(codes: LanguageCodes, text: []const u8) ?ResolvedLanguage {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "}}") orelse return null;
        const body = text[open + 2 .. close];
        if (std.mem.indexOf(u8, body, "{{") == null) {
            var fields = std.mem.splitScalar(u8, body, '|');
            if (fields.next()) |name| {
                if (resolveTemplateName(codes, name)) |resolved| return resolved;
                while (fields.next()) |field| {
                    const eq = std.mem.indexOfScalar(u8, field, '=');
                    const candidate = if (eq) |at| field[at + 1 ..] else field;
                    if (resolveTrimmed(codes, candidate)) |resolved| return resolved;
                }
            }
        }
        search = close + 2;
    }
    return null;
}

fn valueConfirmsLanguage(codes: LanguageCodes, value_source: []const u8, wanted: []const u8) bool {
    const value = std.mem.trim(u8, value_source, " \t\r\n=-\'\"[]");
    if (value.len == 0) return false;
    const resolved = codes.resolve(value) orelse return false;
    return std.mem.eql(u8, resolved.code, wanted);
}

fn sourceConfirmsLanguage(codes: LanguageCodes, source: []const u8, wanted: []const u8) bool {
    const limit = @min(source.len, 4096);
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source[0..limit], search, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, source[0..limit], open + 2, "}}") orelse break;
        const body = source[open + 2 .. close];
        if (std.mem.indexOf(u8, body, "{{") == null) {
            var fields = std.mem.splitScalar(u8, body, '|');
            if (fields.next()) |name| {
                if (valueConfirmsLanguage(codes, name, wanted)) return true;
                const trimmed_name = std.mem.trim(u8, name, " \t\r\n=-");
                if (std.mem.indexOfScalar(u8, trimmed_name, '-')) |dash| {
                    if (valueConfirmsLanguage(codes, trimmed_name[0..dash], wanted)) return true;
                    if (dash + 1 < trimmed_name.len and valueConfirmsLanguage(codes, trimmed_name[dash + 1 ..], wanted)) return true;
                }
                while (fields.next()) |field| {
                    const eq = std.mem.indexOfScalar(u8, field, '=');
                    if (eq == null) {
                        if (valueConfirmsLanguage(codes, field, wanted)) return true;
                        continue;
                    }
                    const key = std.mem.trim(u8, field[0..eq.?], " \t");
                    if (std.ascii.eqlIgnoreCase(key, "lang") or
                        std.ascii.eqlIgnoreCase(key, "language") or
                        std.ascii.eqlIgnoreCase(key, "code"))
                    {
                        if (valueConfirmsLanguage(codes, field[eq.? + 1 ..], wanted)) return true;
                    }
                }
            }
        }
        search = close + 2;
    }
    return false;
}

fn resolveSection(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    const classified = language_source.classificationSection(section);

    if (!std.mem.eql(u8, classified, section.heading))
        if (resolveTrimmed(codes, classified)) |resolved| return resolved;

    const plain = std.mem.trim(u8, classified, " \t\r\n\'\"[]");
    if (plain.len != 0) {
        if (codes.resolveStrong(plain)) |resolved| return resolved;

        if (codes.resolveTrusted(plain)) |resolved| {
            const content = codes.content();
            if (content != null and std.mem.eql(u8, content.?.code, resolved.code)) return resolved;
            if (codes.resolveStrong(resolved.code) != null) return resolved;
            if (sourceConfirmsLanguage(codes, section.source, resolved.code)) return resolved;
        }

        if (codes.resolve(plain)) |resolved|
            if (sourceConfirmsLanguage(codes, section.source, resolved.code)) return resolved;
    }

    return resolveTemplateCandidates(codes, section.heading);
}

const PageLanguageGroup = struct {
    language: ResolvedLanguage,
    source: std.ArrayList(u8) = .empty,
};

fn groupIndex(groups: []PageLanguageGroup, language: ResolvedLanguage) ?usize {
    for (groups, 0..) |group, index| {
        if (std.mem.eql(u8, group.language.code, language.code)) return index;
    }
    return null;
}

fn processMain(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    codes: LanguageCodes,
    title: []const u8,
    source: []const u8,
    raw_source: ?[]const u8,
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
) !void {
    stats.main_pages += 1;

    if (fallbacks.expansion_error and source.len == 0) {
        const language = codes.content() orelse ResolvedLanguage{ .code = "", .heading = "Unclassified" };
        const payload = try presentation_document.compileReportedAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            "",
            null,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, language.heading, title, payload);
        stats.language_records += 1;
        return;
    }

    var page_sections: std.ArrayList(language_source.Section) = .empty;
    defer page_sections.deinit(page_allocator);
    var sections = language_source.Iterator.init(source);
    while (sections.next()) |section| try page_sections.append(page_allocator, section);

    var raw_sections: std.ArrayList(language_source.Section) = .empty;
    defer raw_sections.deinit(page_allocator);
    if (raw_source) |raw| {
        var raw_it = language_source.Iterator.init(raw);
        while (raw_it.next()) |section| try raw_sections.append(page_allocator, section);
    }
    const raw_aligned = raw_sections.items.len != 0 and raw_sections.items.len == page_sections.items.len;

    var groups: std.ArrayList(PageLanguageGroup) = .empty;
    defer {
        for (groups.items) |*group| group.source.deinit(page_allocator);
        groups.deinit(page_allocator);
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(page_allocator);
    var current: ?usize = null;

    for (page_sections.items, 0..) |section, index| {
        var resolved: ?ResolvedLanguage = null;
        if (raw_aligned) resolved = resolveSection(codes, raw_sections.items[index]);
        if (resolved == null) resolved = resolveSection(codes, section);

        if (resolved) |language| {
            const group_index = groupIndex(groups.items, language) orelse blk: {
                try groups.append(page_allocator, .{ .language = language });
                break :blk groups.items.len - 1;
            };
            current = group_index;
            if (pending.items.len != 0) {
                try groups.items[group_index].source.appendSlice(page_allocator, pending.items);
                pending.clearRetainingCapacity();
            }
            try groups.items[group_index].source.appendSlice(page_allocator, section.source);
        } else if (current) |group_index| {
            fallbacks.unresolved_language_heading = true;
            try groups.items[group_index].source.appendSlice(page_allocator, section.source);
        } else {
            fallbacks.unresolved_language_heading = true;
            try pending.appendSlice(page_allocator, section.source);
        }
    }

    if (groups.items.len == 0) {
        fallbacks.missing_language_heading = true;
        const language = codes.content() orelse ResolvedLanguage{ .code = "", .heading = "Unclassified" };
        const payload = try presentation_document.compileReportedAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, language.heading, title, payload);
        stats.language_records += 1;
        return;
    }

    // Page-level material before the first resolved language belongs with the
    // first language instead of becoming a synthetic language of its own.
    if (pending.items.len != 0) {
        try groups.items[0].source.appendSlice(page_allocator, pending.items);
        pending.clearRetainingCapacity();
    }

    for (groups.items) |group| {
        const payload = try presentation_document.compileReportedAlloc(
            page_allocator,
            title,
            .language,
            group.language.heading,
            group.language.code,
            group.source.items,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, group.language.heading, title, payload);
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
    language_codes: LanguageCodes = .{},
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
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, .{}, &.{});
    }

    pub fn addExpandedPage(self: *Writer, page_allocator: std.mem.Allocator, ns: u32, title: []const u8, source: []const u8, raw_source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, raw_source, display_title, .{}, &.{});
    }

    pub fn addPageWithFallback(self: *Writer, page_allocator: std.mem.Allocator, ns: u32, title: []const u8, source: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks) !void {
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, initial_fallbacks, &.{});
    }

    pub fn addExpansionFailure(self: *Writer, page_allocator: std.mem.Allocator, ns: u32, title: []const u8, reasons: []const []const u8) !void {
        // Operational expansion failures have no MediaWiki page semantics to
        // synthesize. Retain an empty data-only record and put the exact cause
        // in the build report instead of inventing visible reader content.
        const source = "";
        return self.addPageInternal(page_allocator, ns, title, source, null, null, .{ .expansion_error = true }, reasons);
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
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, initial_fallbacks, extra_reasons);
    }

    fn addPageInternal(
        self: *Writer,
        page_allocator: std.mem.Allocator,
        ns: u32,
        title: []const u8,
        source: []const u8,
        raw_source: ?[]const u8,
        display_title: ?[]const u8,
        initial_fallbacks: presentation_document.Fallbacks,
        extra_reasons: []const []const u8,
    ) !void {
        if (self.finished) return error.WriterFinished;
        var fallbacks = initial_fallbacks;
        if (ns == ns_main) {
            try processMain(page_allocator, &self.spools, self.language_codes, title, source, raw_source, display_title, &self.stats, &fallbacks);
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
        .strong_fn = struct {
            fn strong(_: ?*const anyopaque, heading: []const u8) ?ResolvedLanguage {
                if (std.mem.eql(u8, heading, "English")) return .{ .code = "en", .heading = "English" };
                if (std.mem.eql(u8, heading, "French")) return .{ .code = "fr", .heading = "French" };
                return null;
            }
        }.strong,
    };
    var writer = try Writer.init(std.testing.io, std.testing.allocator, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
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

const TestLanguages = struct {
    fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
        return if (resolve(null, value)) |language| language.code else null;
    }

    fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        inline for (.{
            .{ "English", "en", "English" },
            .{ "French", "fr", "French" },
            .{ "Deutsch", "de", "Deutsch" },
            .{ "de", "de", "Deutsch" },
            .{ "Nederlands", "nl", "Nederlands" },
            .{ "nl", "nl", "Nederlands" },
            .{ "nld", "nl", "Nederlands" },
            .{ "enm", "enm", "Middle English" },
            .{ "Middle English", "enm", "Middle English" },
            .{ "hrvatski", "hr", "Hrvatski" },
            .{ "Hrvatski", "hr", "Hrvatski" },
            .{ "hr", "hr", "Hrvatski" },
            .{ "עברית", "he", "עברית" },
            .{ "he", "he", "עברית" },
            .{ "Magyar", "hu", "Magyar" },
            .{ "hu", "hu", "Magyar" },
            .{ "Aari", "aiw", "Aari" },
            .{ "aiw", "aiw", "Aari" },
            .{ "Latyn", "la", "Latyn" },
            .{ "la", "la", "Latyn" },
            .{ "Ak", "akq", "Ak" },
            .{ "akq", "akq", "Ak" },
        }) |entry| {
            if (std.mem.eql(u8, value, entry[0]))
                return .{ .code = entry[1], .heading = entry[2] };
        }
        return null;
    }

    fn trusted(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        inline for (.{
            .{ "English", "en", "English" },
            .{ "French", "fr", "French" },
            .{ "Deutsch", "de", "Deutsch" },
            .{ "Nederlands", "nl", "Nederlands" },
            .{ "Hrvatski", "hr", "Hrvatski" },
            .{ "עברית", "he", "עברית" },
            .{ "Magyar", "hu", "Magyar" },
            .{ "Latyn", "la", "Latyn" },
        }) |entry| if (std.mem.eql(u8, value, entry[0]))
            return .{ .code = entry[1], .heading = entry[2] };
        return null;
    }

    fn strong(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        if (std.mem.eql(u8, value, "English")) return .{ .code = "en", .heading = "English" };
        if (std.mem.eql(u8, value, "French")) return .{ .code = "fr", .heading = "French" };
        if (std.mem.eql(u8, value, "la")) return .{ .code = "la", .heading = "Latyn" };
        return null;
    }

    fn content(_: ?*const anyopaque) ?ResolvedLanguage {
        return .{ .code = "hu", .heading = "Magyar" };
    }

    fn codes() LanguageCodes {
        return .{ .get_fn = get, .resolve_fn = resolve, .trusted_fn = trusted, .strong_fn = strong, .content_fn = content };
    }
};

test "raw language markers canonicalize templated headings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;

    try writer.addExpandedPage(
        a,
        0,
        "Hallo",
        "== Hallo ([[:Template:Sprache]]) ==\n===Wortart===\n# greeting\n",
        "== Hallo ({{Sprache|Deutsch}}) ==\n===Wortart===\n# greeting\n",
        null,
    );
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    const german_path = try languageBlobPathAlloc(a, root, "Deutsch");
    var german = try mmapPath(std.testing.io, german_path);
    defer german.deinit();
    const blob = try blob_format.inspect(german.bytes);
    try std.testing.expectEqualStrings("de", (try blob.languageMetadata()).code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    try std.testing.expect((try index.find("Hallo")) != null);
}

test "language resolution rejects fake top-level headings and uses real fallback language" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;

    try writer.addExpandedPage(
        a,
        0,
        "springen/vervoeging",
        "==Nederlands==\n# conjugation\n==Nederlandse vervoeging==\n# support\n",
        "{{=nld=}}\n# conjugation\n==Nederlandse vervoeging==\n# support\n",
        null,
    );
    try writer.addExpandedPage(
        a,
        0,
        "kuća",
        "== kuća ([[:Template:hrvatski jezik]]) ==\n# house\n",
        "== kuća ({{hrvatski jezik}}) ==\n# house\n",
        null,
    );
    try writer.addPage(a, 0, "ház", "{{hunfn}}\n# house\n", null);
    try writer.addExpandedPage(
        a,
        0,
        "ik",
        "==Middelengels==\n# I\n",
        "{{=enm=}}\n# I\n",
        null,
    );
    try writer.addPage(
        a,
        0,
        "tamma",
        "==Aari==\n===Numeraali===\n{{num-k|aiw}}\n# ten\n",
        null,
    );
    try writer.addPage(
        a,
        0,
        "Kazalo:Hrvatski/a",
        "==Ak==\n* index material without an akq language marker\n",
        null,
    );
    try writer.addPage(
        a,
        0,
        "fatuus",
        "==Latyn==\n# foolish\n",
        null,
    );

    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_blobs);

    inline for (.{
        .{ "Nederlands", "nl" },
        .{ "Hrvatski", "hr" },
        .{ "Magyar", "hu" },
        .{ "Middle English", "enm" },
        .{ "Aari", "aiw" },
        .{ "Latyn", "la" },
    }) |expected| {
        const path = try languageBlobPathAlloc(a, root, expected[0]);
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        try std.testing.expectEqualStrings(expected[1], (try blob.languageMetadata()).code);
    }

    const manifest_path = try std.fs.path.join(a, &.{ root, blob_catalog.manifest_filename });
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Nederlandse vervoeging") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Unclassified") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\nAk\n") == null);
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
    writer.language_codes = .{
        .get_fn = struct {
            fn get(_: ?*const anyopaque, heading: []const u8) ?[]const u8 {
                return if (std.mem.eql(u8, heading, "English")) "en" else null;
            }
        }.get,
        .strong_fn = struct {
            fn strong(_: ?*const anyopaque, heading: []const u8) ?ResolvedLanguage {
                return if (std.mem.eql(u8, heading, "English")) .{ .code = "en", .heading = "English" } else null;
            }
        }.strong,
    };
    try writer.addPage(a, 0, "quoted\"title", "No heading, but readable content.", null);
    try writer.addPage(a, 0, "broken", "==English==\nB ]]word]]", null);
    try writer.addExpansionFailure(a, 0, "timeout", &.{"expansion_error:Timeout"});
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

    const unclassified_path = try languageBlobPathAlloc(a, root, "Unclassified");
    var unclassified_map = try mmapPath(std.testing.io, unclassified_path);
    defer unclassified_map.deinit();
    const unclassified_blob = try blob_format.inspect(unclassified_map.bytes);
    const metadata = try unclassified_blob.languageMetadata();
    var index = try unclassified_blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const timeout = (try index.find("timeout")).?;
    const parsed = try blobs.presentation_codec.decodeAlloc(a, timeout.payload, "timeout", .language, metadata);
    try std.testing.expectEqual(@as(usize, 0), parsed.entry.sections.len);
    try std.testing.expect(std.mem.indexOf(u8, timeout.payload, "Script error") == null);
}
