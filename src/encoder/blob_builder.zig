const std = @import("std");
const blobs = @import("blob_encoder");
const blob_format = blobs.blob_format;
const blob_catalog = blobs.blob_catalog;
const language_source = @import("language_source.zig");
const presentation_document = @import("presentation_document.zig");

const language_bucket_count = 32;
/// Edition-aware routing is resolved once by the caller. Namespace IDs alone
/// cannot identify a lexical feature across different Wiktionaries.
pub const PageNamespace = struct { id: u32, kind: blob_format.BlobKind };

pub const BuildStats = struct {
    pages_seen: usize = 0,
    main_pages: usize = 0,
    language_records: usize = 0,
    thesaurus_records: usize = 0,
    citations_records: usize = 0,
    reconstruction_records: usize = 0,
    rhymes_records: usize = 0,
    sign_gloss_records: usize = 0,
    supplemental_records: usize = 0,
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
    namespace_catalog: ?*const @import("namespace_registry").Registry = null,
    ctx: ?*const anyopaque = null,
    get_fn: *const fn (?*const anyopaque, []const u8) ?[]const u8 = noLanguageCode,
    resolve_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    trusted_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    strong_fn: ?*const fn (?*const anyopaque, []const u8) ?ResolvedLanguage = null,
    content_fn: ?*const fn (?*const anyopaque) ?ResolvedLanguage = null,
    link_trail: blobs.document_ir.LinkTrail = .{},

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
    supplemental: SpoolFile,

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
            .supplemental = try initFixed(io, allocator, spool_root, "supplemental"),
        };
    }

    fn close(self: *Spools) void {
        for (&self.language) |*spool| spool.close(self.io);
        self.thesaurus.close(self.io);
        self.citations.close(self.io);
        self.reconstruction.close(self.io);
        self.rhymes.close(self.io);
        self.sign_gloss.close(self.io);
        self.supplemental.close(self.io);
    }

    fn cleanup(self: *Spools) void {
        for (&self.language) |*spool| {
            std.Io.Dir.cwd().deleteFile(self.io, spool.path) catch {};
            spool.deinitPath(self.allocator);
        }
        inline for (.{ &self.thesaurus, &self.citations, &self.reconstruction, &self.rhymes, &self.sign_gloss, &self.supplemental }) |spool| {
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

fn resolveLinkedHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const heading = std.mem.trim(u8, value, " \t\r\n");
    if (!std.mem.startsWith(u8, heading, "[[") or !std.mem.endsWith(u8, heading, "]]")) return null;
    const body = heading[2 .. heading.len - 2];
    if (std.mem.indexOfAny(u8, body, "[]{}<>") != null) return null;
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    var target = std.mem.trim(u8, body[0..pipe], " \t\r\n");
    if (std.mem.startsWith(u8, target, ":")) target = std.mem.trim(u8, target[1..], " \t");
    if (codes.namespace_catalog) |namespaces| {
        const title = namespaces.ofTitle(target);
        if (title.id == 14 and std.mem.eql(u8, namespaces.content_language, "am"))
            target = std.mem.trim(u8, title.text, " \t\r\n");
    }
    const resolved = codes.resolveStrong(target) orelse codes.resolveTrusted(target) orelse return null;
    if (pipe < body.len) {
        const label = std.mem.trim(u8, body[pipe + 1 ..], " \t\r\n");
        if (codes.resolveStrong(label) orelse codes.resolveTrusted(label)) |displayed|
            if (!std.mem.eql(u8, resolved.code, displayed.code)) return null;
    }
    return resolved;
}

fn resolveSection(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    const classified = language_source.classificationSection(section);

    if (!std.mem.eql(u8, classified, section.heading))
        if (resolveTrimmed(codes, classified)) |resolved| return resolved;

    if (resolveLinkedHeading(codes, classified)) |resolved| return resolved;

    const plain = std.mem.trim(u8, classified, " \t\r\n\'\"[]");
    if (plain.len != 0) {
        if (codes.resolveStrong(plain)) |resolved| return resolved;

        // Exact edition-local MediaWiki preferred names are language evidence.
        // ISO names and other aliases still need an explicit source marker.
        if (codes.resolveTrusted(plain)) |resolved| return resolved;

        if (codes.resolve(plain)) |resolved|
            if (sourceConfirmsLanguage(codes, section.source, resolved.code)) return resolved;
    }

    return resolveTemplateCandidates(codes, section.heading);
}

fn hasExplicitLanguageDeclaration(codes: LanguageCodes, section: language_source.Section) bool {
    const namespaces = codes.namespace_catalog orelse return false;
    return language_source.explicitLanguageDeclaration(section.heading, namespaces.content_language) != null;
}

fn boundaryLanguage(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    const heading = language_source.classificationSection(section);
    if (codes.resolve(std.mem.trim(u8, heading, " \t\r\n\'\""))) |resolved| return resolved;
    if (resolveLinkedHeading(codes, heading)) |resolved| return resolved;
    var cursor: usize = 0;
    var found: ?ResolvedLanguage = null;
    while (std.mem.indexOfPos(u8, heading, cursor, "[[")) |open| {
        const close = std.mem.indexOfPos(u8, heading, open + 2, "]]") orelse return null;
        cursor = close + 2;
        const body = heading[open + 2 .. close];
        if (std.mem.indexOfAny(u8, body, "[]{}<>") != null) return null;
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const target = std.mem.trim(u8, body[0..pipe], " \t\r\n:");
        const target_language = codes.resolve(target);
        const label_language = if (pipe < body.len) codes.resolve(std.mem.trim(u8, body[pipe + 1 ..], " \t\r\n")) else null;
        if (target_language != null and label_language != null and !std.mem.eql(u8, target_language.?.code, label_language.?.code)) return null;
        const language = target_language orelse label_language orelse continue;
        if (found) |previous| if (!std.mem.eql(u8, previous.code, language.code)) return null;
        found = language;
    }
    return found;
}

const LanguageMarkers = struct {
    codes: *const LanguageCodes,
    represented: ?[]const []const u8 = null,
};

fn languageSections(source: []const u8, context: *const LanguageMarkers) language_source.Iterator {
    return language_source.Iterator.initWithMarkerFilter(source, .{
        .ctx = context,
        .accepts = struct {
            fn accepts(raw: ?*const anyopaque, value: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                const language = markers.codes.resolve(value) orelse return false;
                if (markers.represented) |codes| {
                    for (codes) |code| if (std.mem.eql(u8, code, language.code)) return true;
                    return false;
                }
                return true;
            }
        }.accepts,
    });
}

fn unsectionedLanguage(codes: LanguageCodes, source: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    // The pinned Amharic entry form declares its language in a category even
    // when the entry has no language-level heading. Other editions retain
    // their section conventions rather than inheriting this local rule.
    if (!std.mem.eql(u8, namespaces.content_language, "am")) return null;
    var categories: language_source.CategoryIterator = .{ .source = source };
    var found: ?ResolvedLanguage = null;
    while (categories.next()) |target| {
        const title = namespaces.ofTitle(target);
        if (title.id != 14) continue;
        const name = std.mem.trim(u8, title.text, " \t\r\n");
        const language = codes.resolveStrong(name) orelse codes.resolveTrusted(name) orelse continue;
        if (found) |previous| if (!std.mem.eql(u8, previous.code, language.code)) return null;
        found = language;
    }
    return found;
}

// The pinned Bulgarian Noun/Verb/Adjective/Adverb templates have no language
// heading. Their category uses the expanded language-name parameter. Resolve
// only those exact edition-local wrappers through the trusted registry.
fn unsectionedExpandedLanguage(codes: LanguageCodes, source: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "bg")) return null;
    var categories: language_source.CategoryIterator = .{ .source = source };
    var found: ?ResolvedLanguage = null;
    while (categories.next()) |target| {
        const title = namespaces.ofTitle(target);
        if (title.id != 14) continue;
        const name = std.mem.trim(u8, title.text, " \t\r\n");
        const prefix = for ([_][]const u8{
            "Съществителни имена (",
            "Глаголи (",
            "Прилагателни имена (",
            "Наречия (",
        }) |candidate| {
            if (std.mem.startsWith(u8, name, candidate)) break candidate;
        } else continue;
        if (!std.mem.endsWith(u8, name, ")")) return null;
        const label = std.mem.trim(u8, name[prefix.len .. name.len - 1], " \t\r\n");
        const language = codes.resolveStrong(label) orelse codes.resolveTrusted(label) orelse return null;
        if (found) |previous| if (!std.mem.eql(u8, previous.code, language.code)) return null;
        found = language;
    }
    return found;
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
        const payload = try presentation_document.compileReportedWithLinkTrailAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            "",
            null,
            codes.link_trail,
            codes.namespace_catalog,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, language.heading, title, payload);
        stats.language_records += 1;
        return;
    }

    var page_sections: std.ArrayList(language_source.Section) = .empty;
    defer page_sections.deinit(page_allocator);
    const expanded_markers: LanguageMarkers = .{ .codes = &codes };
    var sections = languageSections(source, &expanded_markers);
    while (sections.next()) |section| try page_sections.append(page_allocator, section);

    var raw_sections: std.ArrayList(language_source.Section) = .empty;
    defer raw_sections.deinit(page_allocator);
    if (raw_source) |raw| {
        var represented: std.ArrayList([]const u8) = .empty;
        defer represented.deinit(page_allocator);
        var named_boundaries = page_sections.items.len != 0;
        for (page_sections.items) |section| {
            const language = boundaryLanguage(codes, section) orelse {
                named_boundaries = false;
                break;
            };
            try represented.append(page_allocator, language.code);
        }
        // POS abbreviations can also be real ISO codes (adj is Adioukrou).
        // When every rendered boundary identifies a language, only its codes
        // may supply raw language boundaries. This follows the actual page,
        // without banning a code that another edition uses as a language.
        const raw_markers: LanguageMarkers = .{ .codes = &codes, .represented = if (named_boundaries) represented.items else null };
        var raw_it = languageSections(raw, &raw_markers);
        while (raw_it.next()) |section| try raw_sections.append(page_allocator, section);
    }
    var raw_aligned = raw_sections.items.len != 0 and raw_sections.items.len == page_sections.items.len;
    if (raw_aligned) for (raw_sections.items, page_sections.items) |raw_section, rendered_section| {
        // A short template name can be both a POS marker and an ISO code.
        // Equal section counts do not prove that its expansion is a language
        // boundary: e.g. Aymara's -ay-/-adj- can line up with noun/adjective
        // headings. Require rendered language evidence for hyphen markers;
        // preserve the distinct equals-style language declaration convention.
        if (raw_section.hyphen_marker and boundaryLanguage(codes, rendered_section) == null) {
            raw_aligned = false;
            break;
        }
    };

    if (!raw_aligned) for (raw_sections.items) |section| {
        if (!hasExplicitLanguageDeclaration(codes, section) or resolveSection(codes, section) != null) continue;
        // An unresolved declaration cannot inherit an adjacent language. If
        // expansion changed the boundaries, retain the whole page without
        // guessing which rendered bytes belong to the unknown language.
        fallbacks.unresolved_language_heading = true;
        const payload = try presentation_document.compileReportedWithLinkTrailAlloc(
            page_allocator,
            title,
            .language,
            "Unclassified",
            "",
            source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, "Unclassified", title, payload);
        stats.language_records += 1;
        return;
    };

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
        if (resolved) |raw_language| if (boundaryLanguage(codes, section)) |rendered_language| {
            if (!std.mem.eql(u8, raw_language.code, rendered_language.code)) {
                resolved = null;
                fallbacks.unresolved_language_heading = true;
            }
        };
        if (resolved == null) resolved = resolveSection(codes, section);

        if (resolved == null and (hasExplicitLanguageDeclaration(codes, section) or
            (raw_aligned and hasExplicitLanguageDeclaration(codes, raw_sections.items[index]))))
        {
            fallbacks.unresolved_language_heading = true;
            resolved = .{ .code = "", .heading = "Unclassified" };
        }

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
        // Only use page-wide attribution when no top-level section needs a
        // language decision. Conflicting/unknown headings remain reported.
        const explicit = if (page_sections.items.len == 0)
            unsectionedLanguage(codes, raw_source orelse source) orelse unsectionedExpandedLanguage(codes, source)
        else
            null;
        if (explicit == null) fallbacks.missing_language_heading = true;
        const language = explicit orelse codes.content() orelse ResolvedLanguage{ .code = "", .heading = "Unclassified" };
        const payload = try presentation_document.compileReportedWithLinkTrailAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
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
        const payload = try presentation_document.compileReportedWithLinkTrailAlloc(
            page_allocator,
            title,
            .language,
            group.language.heading,
            group.language.code,
            group.source.items,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
            fallbacks,
        );
        try spools.appendLanguage(page_allocator, group.language.heading, title, payload);
        stats.language_records += 1;
    }
}

fn processNamespace(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    link_trail: blobs.document_ir.LinkTrail,
    namespace_catalog: ?*const @import("namespace_registry").Registry,
    ns: PageNamespace,
    title: []const u8,
    source: []const u8,
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
) !void {
    const kind = ns.kind;
    // Supplemental namespaces share one file, so keep their full localized
    // names to avoid collisions between identically named namespace suffixes.
    const local_title = if (kind == .supplemental) title else localNamespaceTitle(title);
    const payload = try presentation_document.compileReportedWithLinkTrailAlloc(
        page_allocator,
        local_title,
        kind,
        null,
        "",
        source,
        if (display_title) |value| .{ .source = value, .page_title = title } else null,
        link_trail,
        namespace_catalog,
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
        .supplemental => {
            try spools.supplemental.append(spools.io, page_allocator, "", local_title, payload);
            stats.supplemental_records += 1;
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
    namespace_coverage: blobs.namespace_coverage.Table = .{},
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
        self.namespace_coverage.deinit(self.allocator);
        if (!self.closed) self.spools.close();
        self.fallback_file.close(self.io);
        self.spools.cleanup();
        self.allocator.free(self.output_root);
        self.* = undefined;
    }

    pub fn addPage(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, .{}, &.{});
    }

    pub fn addExpandedPage(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, raw_source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, raw_source, display_title, .{}, &.{});
    }

    pub fn addPageWithFallback(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks) !void {
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, initial_fallbacks, &.{});
    }

    pub fn addExpansionFailure(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, reasons: []const []const u8) !void {
        // Operational expansion failures have no MediaWiki page semantics to
        // synthesize. Retain an empty data-only record and put the exact cause
        // in the build report instead of inventing visible reader content.
        const source = "";
        return self.addPageInternal(page_allocator, ns, title, source, null, null, .{ .expansion_error = true }, reasons);
    }

    pub fn addPageWithFallbackReasons(
        self: *Writer,
        page_allocator: std.mem.Allocator,
        ns: PageNamespace,
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
        ns: PageNamespace,
        title: []const u8,
        source: []const u8,
        raw_source: ?[]const u8,
        display_title: ?[]const u8,
        initial_fallbacks: presentation_document.Fallbacks,
        extra_reasons: []const []const u8,
    ) !void {
        if (self.finished) return error.WriterFinished;
        var fallbacks = initial_fallbacks;
        if (ns.kind == .language) {
            try processMain(page_allocator, &self.spools, self.language_codes, title, source, raw_source, display_title, &self.stats, &fallbacks);
        } else {
            try processNamespace(page_allocator, &self.spools, self.language_codes.link_trail, self.language_codes.namespace_catalog, ns, title, source, display_title, &self.stats, &fallbacks);
        }
        if (fallbacks.any() or extra_reasons.len != 0) {
            var reasons: std.ArrayList([]const u8) = .empty;
            defer reasons.deinit(page_allocator);
            inline for (@typeInfo(presentation_document.Fallbacks).@"struct".field_names) |field|
                if (@field(fallbacks, field)) try reasons.append(page_allocator, field);
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
                .namespace = ns.id,
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
        if (self.namespace_coverage.rows.count() != 0) try self.namespace_coverage.validate(self.stats.pages_seen);
        self.namespace_coverage.registry_sha256 = if (codes.namespace_catalog) |registry| registry.source_sha256 else null;
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
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.supplemental, self.output_root, "supplemental", .supplemental);
        try self.namespace_coverage.write(self.io, self.allocator, self.output_root);
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
    try writer.addPage(page_arena.allocator(), .{ .id = 0, .kind = .language }, "cat", "==English==\n===Noun===\n# [[cat]]\n==French==\n===Nom===\n# [[chat]]\n==English==\n===Verb===\n# purr\n", "<i>cat</i>");
    _ = page_arena.reset(.retain_capacity);
    try writer.addPage(page_arena.allocator(), .{ .id = 114, .kind = .citations }, "Citations:cat", "citation raw", null);
    _ = page_arena.reset(.retain_capacity);
    try writer.addPage(page_arena.allocator(), .{ .id = 118, .kind = .reconstruction }, "Reconstruction:Proto-Germanic/kattuz", "==Proto-Germanic==\n===Noun===\n# cat\n", null);
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
            .{ "en", "en", "English" },
            .{ "እንግሊዝኛ", "en", "English" },
            .{ "French", "fr", "French" },
            .{ "fr", "fr", "French" },
            .{ "ፈረንሳይኛ", "fr", "French" },
            .{ "am", "am", "አማርኛ" },
            .{ "አማርኛ", "am", "አማርኛ" },
            .{ "af", "af", "Afrikaans" },
            .{ "Afrikaans", "af", "Afrikaans" },
            .{ "an", "an", "aragonés" },
            .{ "aragonés", "an", "aragonés" },
            .{ "Aragonés", "an", "aragonés" },
            .{ "ca", "ca", "catalán" },
            .{ "catalán", "ca", "catalán" },
            .{ "Catalán", "ca", "catalán" },
            .{ "adj", "adj", "Adioukrou" },
            .{ "Adioukrou", "adj", "Adioukrou" },
            .{ "ay", "ay", "Aymar aru" },
            .{ "Aymar aru", "ay", "Aymar aru" },
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
            .{ "እንግሊዝኛ", "en", "English" },
            .{ "ፈረንሳይኛ", "fr", "French" },
            .{ "አማርኛ", "am", "አማርኛ" },
            .{ "Afrikaans", "af", "Afrikaans" },
            .{ "aragonés", "an", "aragonés" },
            .{ "catalán", "ca", "catalán" },
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
        .{ .id = 0, .kind = .language },
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

test "grammar markers cannot erase Afrikaans or Aragonese language attribution" {
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
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "hulpwenk", "== [[Afrikaans|Afrikaans (af)]] ==\n===Uitspraak===\n===Woordafbreking===\n# Afrikaans meaning\n==[[Nederlands|Nederlands (nl)]]==\n===Naamwoord===\n# Dutch meaning\n", "{{=af=}}\n{{-uitspraak-}}\n{{-woordafbreking-}}\n# Afrikaans meaning\n{{=nl=}}\n{{-noun-}}\n# Dutch meaning\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "trobar", "=<div>''[[Wiktionary:Aragonés|Aragonés]]''</div>=\n==<H3>Verbo</H3>==\n# Aragonese meaning\n=<div>''[[Wiktionary:Catalán|Catalán]]''</div>=\n==<H3>Verbo</H3>==\n# Catalan meaning\n", "{{-an-}}\n{{-verb-}}\n# Aragonese meaning\n{{-trans-}}\n{{-ca-}}\n{{-verb-}}\n# Catalan meaning\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "pirinenco", "=<div>''[[Wiktionary:Aragonés|Aragonés]]''</div>=\n==[[Wiktionary:Adchectivo|Adchectivo]]==\n# Aragonese adjective\n", "{{-an-}}\n{{-adj-}}\n# Aragonese adjective\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "sample-adj", "==Adioukrou==\n===Noun===\n# Adioukrou meaning\n", "{{-adj-}}\n{{-noun-}}\n# Adioukrou meaning\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    inline for (.{
        .{ "Afrikaans", "af", "hulpwenk", "Afrikaans meaning", "Dutch meaning" },
        .{ "Nederlands", "nl", "hulpwenk", "Dutch meaning", "Afrikaans meaning" },
        .{ "aragonés", "an", "trobar", "Aragonese meaning", "Catalan meaning" },
        .{ "catalán", "ca", "trobar", "Catalan meaning", "Aragonese meaning" },
        .{ "aragonés", "an", "pirinenco", "Aragonese adjective", "Adioukrou meaning" },
        .{ "Adioukrou", "adj", "sample-adj", "Adioukrou meaning", "Aragonese adjective" },
    }) |expected| {
        const path = try languageBlobPathAlloc(a, root, expected[0]);
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        try std.testing.expectEqualStrings(expected[1], (try blob.languageMetadata()).code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(expected[2])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(expected[1], decoded.entry.language_code);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, expected[3]) != null);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, expected[4]) == null);
        if (std.mem.eql(u8, expected[1], "adj")) try std.testing.expect((try index.find("pirinenco")) == null);
    }
}

test "standalone POS markers cannot align by count with unrecognized rendered headings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var codes = TestLanguages.codes();
    codes.content_fn = struct {
        fn content(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "ay", .heading = "Aymar aru" };
        }
    }.content;
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;

    // These pinned AY entries have noun and adjective definitions. The -ay-
    // template emits a banner, while -noun- and -adj- emit level-two headings.
    // The two raw language-code candidates therefore match the two rendered
    // POS boundaries by count without sharing their meaning.
    const cases = .{
        .{ "wila", "Jaqina, uywana sirka chiqawa", "Janchi wilaru uñtata samiwa." },
        .{ "chinchilla", "Wisk’acharu uñtata", "Qhana uqi samiwa." },
    };
    inline for (cases) |entry| {
        const raw = try std.fmt.allocPrint(a, "{{{{-ay-}}}}\n{{{{-noun-}}}}\n# {s}\n{{{{-adj-}}}}\n# {s}\n", .{ entry[1], entry[2] });
        const expanded = try std.fmt.allocPrint(a, "<div>'''[[Aymara aru|AYMARA ARU]]'''</div>\n==<div><big><big>[[suti|Suti]]</big></big></div>==\n# {s}\n==<big><big>[[mayjachiri|Mayjachiri]]</big></big>==\n# {s}\n", .{ entry[1], entry[2] });
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, entry[0], expanded, raw, null);
    }
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 2), stats.fallback_pages);
    const path = try languageBlobPathAlloc(a, root, "Aymar aru");
    var mapped = try mmapPath(std.testing.io, path);
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("ay", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    inline for (cases) |entry| {
        const record = (try index.find(entry[0])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("ay", decoded.entry.language_code);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, entry[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, entry[2]) != null);
    }
}

test "preferred foreign names resolve while unconfirmed ISO names remain guarded" {
    const codes = TestLanguages.codes();
    try std.testing.expectEqualStrings("nl", resolveSection(codes, .{ .heading = "Nederlands", .source = "==Nederlands==\n# Dutch entry\n" }).?.code);
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "እንግሊዝኛ", .source = "==እንግሊዝኛ==\n# English entry\n" }).?.code);
    try std.testing.expect(resolveSection(codes, .{ .heading = "Ak", .source = "==Ak==\n* alphabetical index\n" }) == null);
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "ቋንቋ", .source = "==ቋንቋ==\nእንግሊዝኛ\n" }).?.code);
    try std.testing.expectEqualStrings("af", resolveSection(codes, .{ .heading = "[[Afrikaans|Afrikaans (af)]]", .source = "==[[Afrikaans|Afrikaans (af)]]==\n# entry\n" }).?.code);
    try std.testing.expect(resolveLinkedHeading(codes, "[[English|French]]") == null);
}

test "unsectioned Amharic entries use unique explicit language categories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tamwiktionary\n# dump-date\t20261001\n# content-language\tam\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tመለጠፊያ\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tመደብ\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{
        .heading = "[[:መደብ:እንግሊዝኛ|እንግሊዝኛ]]",
        .source = "==[[:መደብ:እንግሊዝኛ|እንግሊዝኛ]]== \n# English definition\n",
    }).?.code);
    try std.testing.expect(resolveLinkedHeading(codes, "[[:መደብ:እንግሊዝኛ|ፈረንሳይኛ]]") == null);
    const source = "door (noun) በር / መዝጊያ (ስም)\n[[መደብ:እንግሊዝኛ]]\n";
    try std.testing.expectEqualStrings("en", unsectionedLanguage(codes, source).?.code);
    try std.testing.expectEqualStrings("am", unsectionedLanguage(codes, "በቅደም ተከተል መቆም ወይም መሄድ\n[[መደብ:አማርኛ]]\n").?.code);
    try std.testing.expect(unsectionedLanguage(codes, "[[መደብ:እንግሊዝኛ]][[መደብ:ፈረንሳይኛ]]") == null);
    try std.testing.expect(unsectionedLanguage(codes, "<!--[[መደብ:እንግሊዝኛ]]-->[[:መደብ:አማርኛ]]") == null);
    try std.testing.expect(unsectionedLanguage(codes, "A portal with no language attribution.") == null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "door", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const path = try languageBlobPathAlloc(a, root, "English");
    var mapped = try mmapPath(std.testing.io, path);
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("door")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
    try std.testing.expectEqualStrings("en", decoded.entry.language_code);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "door (noun)") != null);
}

test "unsectioned Bulgarian POS categories retain English identity and their whole body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tbgwiktionary\n# dump-date\t20261001\n# content-language\tbg\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tШаблон\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tКатегория\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const LocalLanguages = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "английски")) return .{ .code = "en", .heading = "английски" };
            if (std.mem.eql(u8, value, "български")) return .{ .code = "bg", .heading = "български" };
            return null;
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
        fn content(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "bg", .heading = "български" };
        }
    };
    const codes: LanguageCodes = .{
        .namespace_catalog = &namespaces,
        .get_fn = LocalLanguages.get,
        .resolve_fn = LocalLanguages.resolve,
        .trusted_fn = LocalLanguages.resolve,
        .content_fn = LocalLanguages.content,
    };
    const category = "[[Категория:Съществителни имена (английски)]]";
    try std.testing.expectEqualStrings("en", unsectionedExpandedLanguage(codes, category).?.code);
    try std.testing.expectEqualStrings("en", unsectionedExpandedLanguage(codes, category ++ category).?.code);
    inline for (.{ "Глаголи", "Прилагателни имена", "Наречия" }) |pos| {
        try std.testing.expectEqualStrings("en", unsectionedExpandedLanguage(codes, "[[Категория:" ++ pos ++ " (английски)]]").?.code);
        try std.testing.expectEqualStrings("en", unsectionedExpandedLanguage(codes, category ++ "[[Категория:" ++ pos ++ " (английски)]]").?.code);
        try std.testing.expect(unsectionedExpandedLanguage(codes, category ++ "[[Категория:" ++ pos ++ " (български)]]") == null);
    }
    inline for (.{
        "<!--" ++ category ++ "-->",
        "<nowiki>" ++ category ++ "</nowiki>",
        "[[:Категория:Съществителни имена (английски)]]",
        "[[Категория:английски]]",
        "[[Категория:Съществителни имена (unknown-language)]]",
        category ++ "[[Категория:Съществителни имена (български)]]",
        category ++ "[[Категория:Съществителни имена (unknown-language)]]",
        category ++ "[[Категория:Съществителни имена (английски]]",
    }) |source| try std.testing.expect(unsectionedExpandedLanguage(codes, source) == null);
    var no_edition = codes;
    no_edition.namespace_catalog = null;
    try std.testing.expect(unsectionedExpandedLanguage(no_edition, category) == null);

    // Minimal fixture of the pinned Noun expansion, with emitted etymology
    // prose after the definition to guard whole-body preservation.
    const definition = "Почесване по главата с дланта или с кокалчетата на ръцете.";
    const tail = "A retained etymology paragraph.";
    const raw = "{{Noun|ID=noogie|ЕЗИК=en|ЗНАЧЕНИЕ=\n# " ++ definition ++ "\n|ЕТИМОЛОГИЯ=" ++ tail ++ "}}";
    const expanded = "<div>\n" ++ category ++ "\n=== Съществително име ===\n# " ++ definition ++ "\n==== Етимология ====\n" ++ tail ++ "\n</div>";
    try std.testing.expect(unsectionedExpandedLanguage(codes, raw) == null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "noogie", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const path = try languageBlobPathAlloc(a, root, "английски");
    var mapped = try mmapPath(std.testing.io, path);
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("en", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("noogie")).?;
    try std.testing.expectEqualStrings("noogie", record.title);
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("en", decoded.entry.language_code);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, definition) != null);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "Съществително име") != null);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "Етимология") != null);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, tail) != null);
}

test "explicit unresolved Arabic language sections retain unverified ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const LocalLanguages = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{
                .{ "كرواتية", "hr", "Hrvatski" },
                .{ "أيسلندية", "is", "Íslenska" },
                .{ "Íslenska", "is", "Íslenska" },
                .{ "برتغالية", "pt", "Português" },
                .{ "Português", "pt", "Português" },
                .{ "لاتينية", "la", "Latyn" },
                .{ "العربية", "ar", "العربية" },
            }) |entry| if (std.mem.eql(u8, value, entry[0]))
                return .{ .code = entry[1], .heading = entry[2] };
            return TestLanguages.resolve(null, value);
        }

        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }

        fn content(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "ar", .heading = "العربية" };
        }
    };
    const codes: LanguageCodes = .{
        .namespace_catalog = &namespaces,
        .get_fn = LocalLanguages.get,
        .resolve_fn = LocalLanguages.resolve,
        .trusted_fn = LocalLanguages.resolve,
        .content_fn = LocalLanguages.content,
    };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;

    // The Danish/Catalan declarations and their neighboring languages follow
    // the pinned Arabic Sin and sol pages; labels are deliberately unresolved.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Sin", "==كرواتية[[تصنيف:كرواتية]]==\n# Croatian definition\n==دانماركية[[تصنيف:دانماركية]]==\n# لَهُ Danish definition\n==اسم==\n# Danish noun detail\n==أيسلندية[[تصنيف:أيسلندية]]==\n# Icelandic definition\n", "=={{اللغة|كرواتية}}==\n# Croatian definition\n=={{اللغة|دانماركية}}==\n# لَهُ Danish definition\n==اسم==\n# Danish noun detail\n=={{اللغة|أيسلندية}}==\n# Icelandic definition\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "sol", "==برتغالية[[تصنيف:برتغالية]]==\n# Portuguese definition\n==كتالونية[[تصنيف:كتالونية]]==\n# Catalan definition\n==لاتينية[[تصنيف:لاتينية]]==\n# Latin definition\n", "=={{اللغة|برتغالية}}==\n# Portuguese definition\n=={{اللغة|كتالونية}}==\n# Catalan definition\n=={{اللغة|لاتينية}}==\n# Latin definition\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unknown-first", "==Notes==\n# Introductory material\n==دانماركية==\n# Unknown first definition\n==English==\n# English later definition\n", "==Notes==\n# Introductory material\n=={{اللغة|دانماركية}}==\n# Unknown first definition\n=={{اللغة|English}}==\n# English later definition\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "only-unknown", "==دانماركية==\n# First unknown definition\n===اسم===\n# First unknown noun\n==كتالونية==\n# Second unknown definition\n", "=={{اللغة|دانماركية}}==\n# First unknown definition\n===اسم===\n# First unknown noun\n=={{اللغة|كتالونية}}==\n# Second unknown definition\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unaligned", "==English==\n# Known text before changed boundary\n# Unknown text after changed boundary\n", "=={{اللغة|English}}==\n# Known text before changed boundary\n=={{اللغة|دانماركية}}==\n# Unknown text after changed boundary\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "rendered-resolves", "==French==\n# Rendered language evidence\n", "=={{اللغة|Unlisted spelling}}==\n# Rendered language evidence\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "support", "==English==\n# English definition\n==Conjugation==\n# Ordinary support content\n", "=={{اللغة|English}}==\n# English definition\n==Conjugation==\n# Ordinary support content\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unaligned-known", "==English==\n# Known content across structural expansion\n", "=={{اللغة|English}}==\n# Known content\n==Conjugation==\n# Across structural expansion\n", null);

    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 13), stats.language_records);
    try std.testing.expectEqual(@as(usize, 7), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 6), stats.fallback_pages);

    const Expected = struct {
        heading: []const u8,
        code: []const u8,
        title: []const u8,
        contains: []const u8,
        excludes: ?[]const u8 = null,
        section_heading: ?[]const u8 = null,
    };
    const expected = [_]Expected{
        .{ .heading = "Hrvatski", .code = "hr", .title = "Sin", .contains = "Croatian definition", .excludes = "Danish" },
        .{ .heading = "Íslenska", .code = "is", .title = "Sin", .contains = "Icelandic definition", .excludes = "Danish" },
        .{ .heading = "Unclassified", .code = "", .title = "Sin", .contains = "Danish noun detail", .excludes = "Croatian definition", .section_heading = "دانماركية" },
        .{ .heading = "Português", .code = "pt", .title = "sol", .contains = "Portuguese definition", .excludes = "Catalan definition" },
        .{ .heading = "Latyn", .code = "la", .title = "sol", .contains = "Latin definition", .excludes = "Catalan definition" },
        .{ .heading = "Unclassified", .code = "", .title = "sol", .contains = "Catalan definition", .excludes = "Portuguese definition", .section_heading = "كتالونية" },
        .{ .heading = "English", .code = "en", .title = "unknown-first", .contains = "English later definition", .excludes = "Unknown first definition" },
        .{ .heading = "Unclassified", .code = "", .title = "unknown-first", .contains = "Unknown first definition", .excludes = "English later definition", .section_heading = "دانماركية" },
        .{ .heading = "Unclassified", .code = "", .title = "only-unknown", .contains = "First unknown definition", .section_heading = "دانماركية" },
        .{ .heading = "Unclassified", .code = "", .title = "only-unknown", .contains = "Second unknown definition", .section_heading = "كتالونية" },
        .{ .heading = "Unclassified", .code = "", .title = "unaligned", .contains = "Known text before changed boundary" },
        .{ .heading = "Unclassified", .code = "", .title = "unaligned", .contains = "Unknown text after changed boundary" },
        .{ .heading = "French", .code = "fr", .title = "rendered-resolves", .contains = "Rendered language evidence" },
        .{ .heading = "English", .code = "en", .title = "support", .contains = "Ordinary support content" },
        .{ .heading = "English", .code = "en", .title = "unaligned-known", .contains = "Known content across structural expansion" },
    };
    for (expected) |item| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, item.heading));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(item.code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(item.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(item.code, decoded.entry.language_code);
        const json = try std.json.Stringify.valueAlloc(a, decoded, .{});
        try std.testing.expect(std.mem.indexOf(u8, json, item.contains) != null);
        if (item.excludes) |excluded| try std.testing.expect(std.mem.indexOf(u8, json, excluded) == null);
        if (item.section_heading) |heading| {
            var found = false;
            for (decoded.entry.sections) |section| found = found or std.mem.eql(u8, section.title, heading);
            try std.testing.expect(found);
        }
        if (std.mem.eql(u8, item.heading, "Unclassified")) {
            inline for (.{ "rendered-resolves", "support", "unaligned-known" }) |title|
                try std.testing.expect((try index.find(title)) == null);
        }
        if (std.mem.eql(u8, item.heading, "English"))
            try std.testing.expect((try index.find("unaligned")) == null);
    }

    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, blob_catalog.manifest_filename }), a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "العربية") == null);
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    var isolated_pages: usize = 0;
    while (lines.next()) |line| {
        const row = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        const title = row.value.object.get("title").?.string;
        if (std.mem.eql(u8, title, "support")) continue;
        var unresolved = false;
        for (row.value.object.get("reasons").?.array.items) |reason| {
            unresolved = unresolved or std.mem.eql(u8, reason.string, "unresolved_language_heading");
            try std.testing.expect(!std.mem.eql(u8, reason.string, "missing_language_heading"));
        }
        try std.testing.expect(unresolved);
        isolated_pages += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), isolated_pages);
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
        .{ .id = 0, .kind = .language },
        "springen/vervoeging",
        "==Nederlands==\n# conjugation\n==Nederlandse vervoeging==\n# support\n",
        "{{=nld=}}\n# conjugation\n==Nederlandse vervoeging==\n# support\n",
        null,
    );
    try writer.addExpandedPage(
        a,
        .{ .id = 0, .kind = .language },
        "kuća",
        "== kuća ([[:Template:hrvatski jezik]]) ==\n# house\n",
        "== kuća ({{hrvatski jezik}}) ==\n# house\n",
        null,
    );
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "ház", "{{hunfn}}\n# house\n", null);
    try writer.addExpandedPage(
        a,
        .{ .id = 0, .kind = .language },
        "ik",
        "==Middelengels==\n# I\n",
        "{{=enm=}}\n# I\n",
        null,
    );
    try writer.addPage(
        a,
        .{ .id = 0, .kind = .language },
        "tamma",
        "==Aari==\n===Numeraali===\n{{num-k|aiw}}\n# ten\n",
        null,
    );
    try writer.addPage(
        a,
        .{ .id = 0, .kind = .language },
        "Kazalo:Hrvatski/a",
        "==Ak==\n* index material without an akq language marker\n",
        null,
    );
    try writer.addPage(
        a,
        .{ .id = 0, .kind = .language },
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
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "quoted\"title", "No heading, but readable content.", null);
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "broken", "==English==\nB ]]word]]", null);
    try writer.addExpansionFailure(a, .{ .id = 0, .kind = .language }, "timeout", &.{"expansion_error:Timeout"});
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "normal", "==English==\n# Normal definition.", null);
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

test "supplemental namespaces keep full titles and cannot collide by suffix" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var writer = try Writer.init(io, a, root);
    defer writer.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try writer.addPage(arena.allocator(), .{ .id = 116, .kind = .supplemental }, "Conjugaison:aller", "A conjugation.", null);
    try writer.addPage(arena.allocator(), .{ .id = 118, .kind = .supplemental }, "Racine:aller", "A root.", null);
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 2), stats.supplemental_records);
    const path = try std.fs.path.join(a, &.{ root, "supplemental.wikblb" });
    defer a.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    const blob = try blob_format.inspect(bytes);
    try std.testing.expectEqual(blob_format.BlobKind.supplemental, blob.kind);
    var iterator = blob.iterator();
    try std.testing.expectEqualStrings("Conjugaison:aller", (try iterator.next()).?.title);
    try std.testing.expectEqualStrings("Racine:aller", (try iterator.next()).?.title);
    try std.testing.expect((try iterator.next()) == null);
}
