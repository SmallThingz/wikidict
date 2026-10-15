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
    alias_records: usize = 0,
};

pub const ResolvedLanguage = struct {
    code: []const u8,
    heading: []const u8,
};

fn noLanguageCode(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

pub const LanguageCodes = struct {
    behavior_switches: ?*const @import("namespace_registry").behavior_switches.Registry = null,
    image_options: ?*const @import("namespace_registry").image_options.Registry = null,
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
    aliases: SpoolFile,

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
            .aliases = try initFixed(io, allocator, spool_root, "aliases"),
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
        self.aliases.close(self.io);
    }

    fn cleanup(self: *Spools) void {
        for (&self.language) |*spool| {
            std.Io.Dir.cwd().deleteFile(self.io, spool.path) catch {};
            spool.deinitPath(self.allocator);
        }
        inline for (.{ &self.thesaurus, &self.citations, &self.reconstruction, &self.rhymes, &self.sign_gloss, &self.supplemental, &self.aliases }) |spool| {
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
    if (records.len < 2) return;
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
    // Apostrophes can belong to an exact registered name, such as Urak Lawoi'.
    if (codes.resolve(std.mem.trim(u8, value, " \t\r\n"))) |resolved| return resolved;
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
    const syntax = blobs.wikitext_syntax;
    var search: usize = 0;
    while (search < text.len) {
        if (syntax.protectedEnd(text, search)) |end| {
            search = end;
            continue;
        }
        if (text[search] == '<') if (syntax.tagAt(text, search)) |tag| {
            search = tag.end;
            continue;
        };
        if (!std.mem.startsWith(u8, text[search..], "{{")) {
            search += 1;
            continue;
        }
        const pair = syntax.balanced(text, search) orelse return null;
        const body = text[search + 2 .. pair.inner_end];
        // Nested calls are not independent evidence that the outer call renders a language.
        if (std.mem.indexOf(u8, body, "{{") == null) {
            const name_end = syntax.delimiter(body, "|", 0) orelse body.len;
            if (resolveTemplateName(codes, body[0..name_end])) |resolved| return resolved;
            var field_start = @min(name_end + 1, body.len);
            while (field_start < body.len) {
                const field_end = syntax.delimiter(body, "|", field_start) orelse body.len;
                const field = body[field_start..field_end];
                const eq = syntax.delimiter(field, "=", 0);
                const candidate = if (eq) |at| field[at + 1 ..] else field;
                if (resolveTrimmed(codes, candidate)) |resolved| return resolved;
                field_start = @min(field_end + 1, body.len);
            }
        }
        search = pair.end;
    }
    return null;
}

fn valueConfirmsLanguage(codes: LanguageCodes, value_source: []const u8, wanted: []const u8) bool {
    const exact = std.mem.trim(u8, value_source, " \t\r\n");
    if (exact.len == 0) return false;
    const value = std.mem.trim(u8, value_source, " \t\r\n=-\'\"[]");
    const resolved = codes.resolve(exact) orelse codes.resolve(value) orelse return false;
    return std.mem.eql(u8, resolved.code, wanted);
}

fn sourceConfirmsLanguage(codes: LanguageCodes, source: []const u8, wanted: []const u8) bool {
    const limit = @min(source.len, 4096);
    var search: usize = 0;
    const bounded = source[0..limit];
    while (search < bounded.len) {
        const open = if (std.mem.indexOfAny(u8, bounded[search..], "<{")) |relative| search + relative else break;
        if (bounded[open] == '<') {
            if (blobs.wikitext_syntax.protectedEnd(bounded, open)) |end| {
                search = end;
                continue;
            }
            if (blobs.wikitext_syntax.tagAt(bounded, open)) |tag| {
                search = tag.end;
                continue;
            }
        }
        if (!std.mem.startsWith(u8, bounded[open..], "{{")) {
            search = open + 1;
            continue;
        }
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
    const arabic = if (codes.namespace_catalog) |namespaces| std.mem.eql(u8, namespaces.content_language, "ar") else false;
    const exact_target = codes.resolveStrong(target) orelse codes.resolveTrusted(target);
    var target_buffer: [256]u8 = undefined;
    const resolved = exact_target orelse blk: {
        if (!arabic) return null;
        const normalized = arabicDeclarationToken(target, &target_buffer) orelse return null;
        break :blk codes.resolveStrong(normalized) orelse codes.resolveTrusted(normalized) orelse return null;
    };
    if (pipe < body.len) {
        const label = std.mem.trim(u8, body[pipe + 1 ..], " \t\r\n");
        if (arabic and std.mem.indexOfScalar(u8, label, '|') != null) return null;
        var displayed = codes.resolveStrong(label) orelse codes.resolveTrusted(label);
        var label_buffer: [256]u8 = undefined;
        if (arabic and displayed == null) {
            if (arabicDeclarationToken(label, &label_buffer)) |normalized| {
                displayed = codes.resolveStrong(normalized) orelse codes.resolveTrusted(normalized);
            }
        }
        if (displayed) |language| {
            if (!std.mem.eql(u8, resolved.code, language.code)) return null;
        } else if (exact_target == null) return null;
    }
    return resolved;
}

// Frozen AN language templates emit this complete toc declaration. Resolve the
// banner itself; raw support headings can legitimately change boundary counts.
fn resolveAnBannerHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "an") or value.len > 4096) return null;
    const syntax = blobs.wikitext_syntax;
    const heading = std.mem.trim(u8, value, " \t\r\n");
    const outer = syntax.tagAt(heading, 0) orelse return null;
    if (!outer.is("div") or outer.closing or outer.self_closing or
        !std.mem.eql(u8, outer.attr("id") orelse "", "toc") or
        !std.mem.eql(u8, outer.attr("class") orelse "", "toccolours") or
        !std.mem.endsWith(u8, heading, "</div>") or outer.end + 6 > heading.len) return null;
    var rest = std.mem.trim(u8, heading[outer.end .. heading.len - 6], " \t");
    if (std.mem.startsWith(u8, rest, "[[")) {
        const image = syntax.balanced(rest, 0) orelse return null;
        const body = rest[2..image.inner_end];
        const pipe = syntax.delimiter(body, "|", 0) orelse return null;
        if (namespaces.ofTitle(body[0..pipe]).id != 6 or
            !std.mem.eql(u8, std.mem.trim(u8, body[pipe + 1 ..], " \t"), "40px")) return null;
        rest = std.mem.trimStart(u8, rest[image.end..], " \t");
    }
    if (!std.mem.startsWith(u8, rest, "'''''[[")) return null;
    rest = rest[5..];
    const link = syntax.balanced(rest, 0) orelse return null;
    const body = rest[2..link.inner_end];
    const pipe = syntax.delimiter(body, "|", 0) orelse return null;
    if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null or
        std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return null;
    var target = std.mem.trim(u8, body[0..pipe], " \t");
    if (std.mem.startsWith(u8, target, "Wiktionary:")) target = target[11..];
    const label = std.mem.trim(u8, body[pipe + 1 ..], " \t");
    const language = codes.resolve(label) orelse return null;
    const target_language = codes.resolve(target) orelse return null;
    if (!std.mem.eql(u8, language.code, target_language.code)) return null;
    rest = std.mem.trimStart(u8, rest[link.end..], " \t");
    if (!std.mem.startsWith(u8, rest, "'''''")) return null;
    rest = std.mem.trimStart(u8, rest[5..], " \t");
    if (rest.len < 21 or !std.mem.startsWith(u8, rest, "<small>- ''") or !std.mem.endsWith(u8, rest, "''</small>")) return null;
    const suffix = rest[11 .. rest.len - 10];
    const suffix_language = codes.resolve(suffix) orelse return null;
    if (!std.mem.eql(u8, language.code, suffix_language.code)) return null;
    return language;
}

// The Arabic declaration form links the words "in language" before the
// language itself. Require the whole declaration, rather than treating any
// language link inside an arbitrary heading as attribution evidence.
// Orthographic matching is confined to the complete Arabic declaration.
// Original source bytes remain the renderer's input; never normalize lemmas.
fn arabicDeclarationToken(value: []const u8, scratch: []u8) ?[]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < value.len) {
        if (i + 1 < value.len and value[i] == 0xd9) {
            const next = value[i + 1];
            if ((next >= 0x8b and next <= 0x92) or next == 0xb0) {
                i += 2;
                continue;
            }
            if (next == 0xb1) {
                if (n + 2 > scratch.len) return null;
                scratch[n] = 0xd8;
                scratch[n + 1] = 0xa7;
                n += 2;
                i += 2;
                continue;
            }
        }
        if (n == scratch.len) return null;
        scratch[n] = value[i];
        n += 1;
        i += 1;
    }
    return scratch[0..n];
}

// A complete Arabic "language <name>" heading is an explicit declaration.
// Resolve only an authenticated whole label; never derive ownership from a lemma.
fn resolveArabicLanguageHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar")) return null;
    const heading = std.mem.trim(u8, value, " \t\r\n");
    const prefix = "لغة";
    if (!std.mem.startsWith(u8, heading, prefix) or heading.len <= prefix.len or
        (heading[prefix.len] != ' ' and heading[prefix.len] != '\t')) return null;
    const label = std.mem.trim(u8, heading[prefix.len..], " \t");
    if (label.len == 0 or std.mem.indexOfAny(u8, label, "[]{}<>|=\r\n") != null) return null;
    return codes.resolveStrong(label) orelse codes.resolveTrusted(label);
}

fn resolveLinkedDeclaration(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar")) return null;
    var rest = std.mem.trim(u8, value, " \t\r\n");
    for ([_][]const u8{ "في", "لغة" }) |target| {
        if (!std.mem.startsWith(u8, rest, "[[")) return null;
        const close = std.mem.indexOf(u8, rest, "]]") orelse return null;
        const body = rest[2..close];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        var token_buffer: [256]u8 = undefined;
        const token = arabicDeclarationToken(body[0..pipe], &token_buffer) orelse return null;
        if (!std.mem.eql(u8, token, target)) return null;
        if (std.mem.indexOfAny(u8, body, "[]{}<>") != null or (pipe < body.len and std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null)) return null;
        rest = std.mem.trimStart(u8, rest[close + 2 ..], " \t");
    }
    if (!std.mem.endsWith(u8, rest, ":")) return null;
    const final_link = std.mem.trimEnd(u8, rest[0 .. rest.len - 1], " \t");
    if (!std.mem.startsWith(u8, final_link, "[[") or !std.mem.endsWith(u8, final_link, "]]")) return null;
    const body = final_link[2 .. final_link.len - 2];
    if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return null;
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
    if (pipe < body.len and std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return null;
    var target_buffer: [256]u8 = undefined;
    var label_buffer: [256]u8 = undefined;
    var raw_target = std.mem.trim(u8, body[0..pipe], " \t");
    if (std.mem.startsWith(u8, raw_target, ":")) raw_target = std.mem.trim(u8, raw_target[1..], " \t");
    const target = arabicDeclarationToken(raw_target, &target_buffer) orelse return null;
    const target_language = codes.resolveStrong(target) orelse codes.resolveTrusted(target);
    const label_language = if (pipe < body.len) blk: {
        const label = arabicDeclarationToken(std.mem.trim(u8, body[pipe + 1 ..], " \t"), &label_buffer) orelse return null;
        break :blk codes.resolveStrong(label) orelse codes.resolveTrusted(label);
    } else null;
    if (target_language != null and label_language != null and !std.mem.eql(u8, target_language.?.code, label_language.?.code)) return null;
    return target_language orelse label_language;
}

// Language templates can append invisible category links inside a heading.
// Accept only a whole trusted name followed by categories for that same language.
fn resolveCategorizedHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    const heading = std.mem.trim(u8, value, " \t\r\n");
    const open = std.mem.indexOf(u8, heading, "[[") orelse return null;
    const name = std.mem.trim(u8, heading[0..open], " \t\r\n");
    const language = codes.resolveStrong(name) orelse codes.resolveTrusted(name) orelse return null;
    var rest = heading[open..];
    while (rest.len != 0) {
        if (!std.mem.startsWith(u8, rest, "[[")) return null;
        const close = std.mem.indexOf(u8, rest, "]]") orelse return null;
        const body = rest[2..close];
        if (std.mem.indexOfAny(u8, body, "[]{}<>") != null) return null;
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const target = std.mem.trim(u8, body[0..pipe], " \t\r\n");
        // Leading ':' creates a visible link, rather than hidden category metadata.
        if (std.mem.startsWith(u8, target, ":")) return null;
        const title = namespaces.ofTitle(target);
        if (title.id != 14) return null;
        const category = codes.resolveStrong(std.mem.trim(u8, title.text, " \t\r\n")) orelse
            codes.resolveTrusted(std.mem.trim(u8, title.text, " \t\r\n")) orelse return null;
        if (!std.mem.eql(u8, language.code, category.code)) return null;
        rest = std.mem.trim(u8, rest[close + 2 ..], " \t\r\n");
    }
    return language;
}

// Exact captured AZ Dil declaration output, not arbitrary HTML/template inference.
fn azDecoratedDeclaration(codes: LanguageCodes, raw: []const u8) ?[]const u8 {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "az")) return null;
    const heading = std.mem.trim(u8, raw, " \t\r\n");
    const tag = blobs.wikitext_syntax.tagAt(heading, 0) orelse return null;
    if (!tag.is("div") or tag.closing or tag.self_closing or
        !std.mem.eql(u8, std.mem.trim(u8, tag.attrs, " \t"), "style=\"background:#EEEEFF\"") or
        !std.mem.endsWith(u8, heading, "</div>")) return null;
    const body = heading[tag.end .. heading.len - 6];
    if (!std.mem.startsWith(u8, body, "[[")) return null;
    const close = std.mem.indexOf(u8, body, "]]") orelse return null;
    const link = body[2..close];
    const pipe = std.mem.indexOfScalar(u8, link, '|') orelse return null;
    const label = link[0..pipe];
    if (label.len == 0 or !std.mem.eql(u8, label, link[pipe + 1 ..]) or
        std.mem.indexOfAny(u8, label, "[]{}<>|=:\r\n") != null) return null;
    const category = body[close + 2 ..];
    if (!std.mem.startsWith(u8, category, "[[") or !std.mem.endsWith(u8, category, "]]")) return null;
    const target = category[2 .. category.len - 2];
    if (std.mem.indexOfAny(u8, target, "[]{}<>|") != null or std.mem.startsWith(u8, target, ":")) return null;
    const title = namespaces.ofTitle(target);
    if (title.id != 14 or !std.mem.startsWith(u8, title.text, label) or
        !std.mem.eql(u8, title.text[label.len..], "ndəki sözlər")) return null;
    return label;
}

fn declarationLabel(codes: LanguageCodes, heading: []const u8) ?[]const u8 {
    const namespaces = codes.namespace_catalog orelse return null;
    return language_source.explicitLanguageDeclaration(heading, namespaces.content_language) orelse
        azDecoratedDeclaration(codes, heading);
}

fn arabicLemmaDeclaration(codes: LanguageCodes, section: language_source.Section) language_source.ArabicNounSubtree {
    const namespaces = codes.namespace_catalog orelse return .{};
    if (!std.mem.eql(u8, namespaces.content_language, "ar")) return .{};
    const heading = std.mem.trim(u8, section.heading, " \t\r\n");
    // A trusted L2 language declaration must not be reassigned by nested POS.
    if (codes.resolveStrong(heading) != null or codes.resolveTrusted(heading) != null or
        resolveLinkedHeading(codes, heading) != null or resolveLinkedDeclaration(codes, heading) != null or
        resolveArabicLanguageHeading(codes, heading) != null or
        hasExplicitLanguageDeclaration(codes, section)) return .{};
    const markers: LanguageMarkers = .{ .codes = &codes };
    return language_source.arabicNounSubtree(section, languageSections(section.source, &markers).control_matcher);
}

fn resolveSection(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    const noun = arabicLemmaDeclaration(codes, section);
    if (noun.present) return if (noun.code) |code| codes.resolve(code) else null;
    if (codes.namespace_catalog) |namespaces| if (std.mem.eql(u8, namespaces.content_language, "az")) {
        if (declarationLabel(codes, section.heading)) |label| return codes.resolve(label);
    };
    if (resolveAnBannerHeading(codes, section.heading)) |resolved| return resolved;
    const classified = language_source.classificationSection(section);
    if (resolveCategorizedHeading(codes, classified)) |resolved| return resolved;

    if (!std.mem.eql(u8, classified, section.heading))
        if (resolveTrimmed(codes, classified)) |resolved| return resolved;

    if (resolveArabicLanguageHeading(codes, classified)) |resolved| return resolved;
    if (resolveLinkedHeading(codes, classified)) |resolved| return resolved;
    if (resolveLinkedDeclaration(codes, classified)) |resolved| return resolved;

    const candidates = [_][]const u8{
        std.mem.trim(u8, classified, " \t\r\n"),
        std.mem.trim(u8, classified, " \t\r\n\'\"[]"),
    };
    for (candidates) |plain| {
        if (plain.len == 0) continue;
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
    return declarationLabel(codes, section.heading) != null;
}

fn boundaryLanguage(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    const noun = arabicLemmaDeclaration(codes, section);
    if (noun.present) return if (noun.code) |code| codes.resolve(code) else null;
    const heading = language_source.classificationSection(section);
    if (resolveCategorizedHeading(codes, heading)) |resolved| return resolved;
    if (resolveArabicLanguageHeading(codes, heading)) |resolved| return resolved;
    if (codes.resolve(std.mem.trim(u8, heading, " \t\r\n"))) |resolved| return resolved;
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

// Only a purely decorative image prefix may be shared between language entries.
// Retain exact source and let each normal renderer own captions, refs and dedup.
fn sharedImagePrefix(a: std.mem.Allocator, codes: LanguageCodes, prefix: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const namespaces = codes.namespace_catalog orelse return null;
    const syntax = blobs.wikitext_syntax;
    var cursor: usize = 0;
    var found = false;
    var separated = true;
    while (cursor < prefix.len) {
        if (std.ascii.isWhitespace(prefix[cursor])) {
            if (prefix[cursor] == '\n' or prefix[cursor] == '\r') separated = true;
            cursor += 1;
            continue;
        }
        if (std.mem.startsWith(u8, prefix[cursor..], "<!--")) {
            const end = std.mem.indexOfPos(u8, prefix, cursor + 4, "-->") orelse return null;
            if (std.mem.indexOfScalar(u8, prefix[cursor..end], '\n') != null) separated = true;
            cursor = end + 3;
            continue;
        }
        const control_end = if (codes.behavior_switches) |registry|
            try registry.matchAt(a, prefix, cursor)
        else
            syntax.behaviorSwitchEnd(prefix, cursor);
        if (control_end) |end| {
            cursor = end;
            continue;
        }
        if (!separated or !std.mem.startsWith(u8, prefix[cursor..], "[[")) return null;
        const pair = syntax.balanced(prefix, cursor) orelse return null;
        const body = prefix[cursor + 2 .. pair.inner_end];
        const pipe = syntax.delimiter(body, "|", 0) orelse body.len;
        const target = std.mem.trim(u8, body[0..pipe], " \t\r\n");
        if (std.mem.startsWith(u8, target, ":") or std.mem.indexOfAny(u8, target, "[]{}<>") != null) return null;
        const title = namespaces.ofTitle(target);
        if (title.id != 6 or @import("presentation_media.zig").referencedKind(title.text) != .image) return null;
        cursor = pair.end;
        separated = false;
        found = true;
    }
    return if (found) prefix else null;
}

// Project active controls only for language classification. The original section
// source stays intact for rendering; protected bodies, attributes and entity-
// authored spellings follow the same boundary rules as display compilation.
fn classificationControlHeadingAlloc(a: std.mem.Allocator, codes: LanguageCodes, value: []const u8) !?[]u8 {
    const syntax = blobs.wikitext_syntax;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var emitted: usize = 0;
    var scan: usize = 0;
    while (scan < value.len) {
        if (value[scan] == '<') {
            if (syntax.protectedEnd(value, scan)) |end| {
                scan = end;
                continue;
            }
            if (syntax.tagAt(value, scan)) |tag| {
                scan = tag.end;
                continue;
            }
        }
        const matched = if (codes.behavior_switches) |registry|
            try registry.matchAt(a, value, scan)
        else
            syntax.behaviorSwitchEnd(value, scan);
        if (matched) |end| {
            const toc = if (codes.behavior_switches) |registry|
                try registry.tocMatchAt(a, value, scan)
            else if (std.ascii.eqlIgnoreCase(value[scan..end], "__TOC__")) end else null;
            if (toc != null and toc.? == end) {
                scan = end;
                continue;
            }
            try out.appendSlice(a, value[emitted..scan]);
            emitted = end;
            scan = end;
        } else scan += 1;
    }
    if (emitted == 0) return null;
    try out.appendSlice(a, value[emitted..]);
    return try out.toOwnedSlice(a);
}

fn appendClassifiedSection(a: std.mem.Allocator, codes: LanguageCodes, sections: *std.ArrayList(language_source.Section), owned_headings: *std.ArrayList([]u8), section: language_source.Section) !void {
    var projected = section;
    if (try classificationControlHeadingAlloc(a, codes, section.heading)) |heading| {
        errdefer a.free(heading);
        try owned_headings.append(a, heading);
        projected.heading = heading;
    }
    try sections.append(a, projected);
}

const LanguageMarkers = struct {
    codes: *const LanguageCodes,
    represented: ?[]const []const u8 = null,
};

fn languageSections(source: []const u8, context: *const LanguageMarkers) language_source.Iterator {
    var iterator = language_source.Iterator.initWithMarkerFilter(source, .{
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
        .accepts_equals = struct {
            fn accepts(raw: ?*const anyopaque, value: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                // Equals-style declarations cannot be erased by their generic
                // display target. Hyphen/POS markers keep represented filtering.
                return markers.codes.resolve(value) != null;
            }
        }.accepts,
    });
    iterator.control_matcher = .{
        .ctx = context,
        .match = struct {
            fn match(raw: ?*const anyopaque, line: []const u8, at: usize) ?usize {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                // Registry matching uses fixed scratch storage; no allocation.
                if (markers.codes.behavior_switches) |registry|
                    return registry.matchAt(std.heap.page_allocator, line, at) catch null;
                return blobs.wikitext_syntax.behaviorSwitchEnd(line, at);
            }
        }.match,
        .toc_match = struct {
            fn match(raw: ?*const anyopaque, line: []const u8, at: usize) ?usize {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                if (markers.codes.behavior_switches) |registry|
                    return registry.tocMatchAt(std.heap.page_allocator, line, at) catch null;
                const end = blobs.wikitext_syntax.behaviorSwitchEnd(line, at) orelse return null;
                return if (std.ascii.eqlIgnoreCase(line[at..end], "__TOC__")) end else null;
            }
        }.match,
    };
    iterator.heading_filter = .{
        .ctx = context,
        .accepts = struct {
            fn accepts(raw: ?*const anyopaque, heading: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                const normalized = classificationControlHeadingAlloc(std.heap.page_allocator, markers.codes.*, heading) catch return false;
                defer if (normalized) |value| std.heap.page_allocator.free(value);
                const projected = normalized orelse heading;
                const section: language_source.Section = .{ .heading = projected, .source = "" };
                if (hasExplicitLanguageDeclaration(markers.codes.*, section)) return true;
                const classified = language_source.classificationHeading(projected);
                if (resolveCategorizedHeading(markers.codes.*, classified) != null) return true;
                if (resolveLinkedHeading(markers.codes.*, classified) != null or
                    resolveLinkedDeclaration(markers.codes.*, classified) != null) return true;
                // A template name/argument can coincide with an ISO/POS code.
                // Only whole trusted names and actual declarations may change
                // depth; generic template-candidate attribution is not proof.
                // Exact registered punctuation belongs to the name; try it
                // before the legacy decorative quote projection.
                const candidates = [_][]const u8{ std.mem.trim(u8, classified, " \t\r\n"), std.mem.trim(u8, classified, " \t\r\n\'\"") };
                for (candidates) |plain|
                    if (markers.codes.resolveStrong(plain) != null or markers.codes.resolveTrusted(plain) != null) return true;
                return false;
            }
        }.accepts,
    };
    return iterator;
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

// The captured Amharic translation entry uses these two L2 support headings,
// not language declarations. Never extend category attribution to arbitrary
// unknown boundaries or to expanded-only evidence.
fn amharicSupportSections(codes: LanguageCodes, sections: []const language_source.Section) bool {
    if (sections.len != 2) return false;
    var seen: u8 = 0;
    for (sections) |section| {
        if (section.hyphen_marker or hasExplicitLanguageDeclaration(codes, section) or
            resolveSection(codes, section) != null) return false;
        const heading = std.mem.trim(u8, section.heading, " \t\r\n");
        const bit: u8 = if (std.mem.eql(u8, heading, "ተመሳሳይ ቃላት")) 1 else if (std.mem.eql(u8, heading, "ትርጉሞች በየቋንቋው")) 2 else return false;
        if ((seen & bit) != 0) return false;
        seen |= bit;
        const body = std.mem.trimStart(u8, section.source, " \t\r\n");
        if (body.len < 3 or body[0] != '=' or body[1] != '=' or body[2] == '=') return false;
    }
    return seen == 3;
}

fn amharicSupportCategoryLanguage(
    codes: LanguageCodes,
    source: []const u8,
    raw_source: ?[]const u8,
    raw_sections: []const language_source.Section,
    page_sections: []const language_source.Section,
) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "am")) return null;
    const raw = raw_source orelse return null;
    if (!amharicSupportSections(codes, raw_sections) or !amharicSupportSections(codes, page_sections)) return null;
    const raw_language = unsectionedLanguage(codes, raw) orelse return null;
    const expanded_language = unsectionedLanguage(codes, source) orelse return null;
    if (!std.mem.eql(u8, raw_language.code, expanded_language.code)) return null;
    return raw_language;
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

// An exact equals declaration and its expanded heading independently repeat
// the registered canonical code. Display names can collide across languages;
// neither arbitrary raw text nor a hyphen/POS marker supplies this evidence.
fn corroboratedEqualsDeclaration(codes: LanguageCodes, raw: language_source.Section, rendered: language_source.Section, raw_code: []const u8, rendered_code: []const u8) bool {
    const canonical = codes.resolve(raw_code) orelse return false;
    if (!std.mem.eql(u8, canonical.code, raw_code) or raw.hyphen_marker) return false;
    const first_line = std.mem.trim(u8, raw.source[0..(std.mem.indexOfScalar(u8, raw.source, '\n') orelse raw.source.len)], " \t\r");
    if (!std.mem.startsWith(u8, first_line, "{{") or !std.mem.endsWith(u8, first_line, "}}")) return false;
    const marker_body = std.mem.trim(u8, first_line[2 .. first_line.len - 2], " \t");
    if (marker_body.len < 3 or marker_body[0] != '=' or marker_body[marker_body.len - 1] != '=') return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, marker_body[1 .. marker_body.len - 1], " \t"), raw_code)) return false;
    const heading = std.mem.trim(u8, rendered.heading, " \t\r\n");
    if (!std.mem.startsWith(u8, heading, "[[") or !std.mem.endsWith(u8, heading, "]]")) return false;
    const body = heading[2 .. heading.len - 2];
    if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return false;
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return false;
    if (std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return false;
    const target_language = codes.resolve(std.mem.trim(u8, body[0..pipe], " \t")) orelse return false;
    if (!std.mem.eql(u8, target_language.code, rendered_code)) return false;
    const label = std.mem.trim(u8, body[pipe + 1 ..], " \t");
    if (label.len < raw_code.len + 3 or label[label.len - 1] != ')') return false;
    const open = label.len - raw_code.len - 2;
    return label[open] == '(' and open > 0 and std.ascii.isWhitespace(label[open - 1]) and
        std.mem.eql(u8, label[open + 1 .. label.len - 1], raw_code);
}

// ANG constitution rev54826 uses the noun role Nama at language depth.
// Its exact en-nama headword template invokes the English noun module. Only
// this aligned continuation of an explicit English section disambiguates the
// homographic Nama language name; ordinary Nama declarations keep their owner.
fn angEnglishNounContinuation(
    codes: LanguageCodes,
    previous_raw: language_source.Section,
    raw: language_source.Section,
    rendered: language_source.Section,
    current_code: []const u8,
) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ang") or
        !std.mem.eql(u8, current_code, "en") or
        previous_raw.hyphen_marker or raw.hyphen_marker or rendered.hyphen_marker) return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, previous_raw.heading, " \t\r\n"), "{{sprǣc|en}}") or
        !std.mem.eql(u8, std.mem.trim(u8, raw.heading, " \t\r\n"), "Nama") or
        !std.mem.eql(u8, std.mem.trim(u8, rendered.heading, " \t\r\n"), "Nama")) return null;
    const previous_end = std.mem.indexOfScalar(u8, previous_raw.source, '\n') orelse return null;
    const raw_end = std.mem.indexOfScalar(u8, raw.source, '\n') orelse return null;
    const rendered_end = std.mem.indexOfScalar(u8, rendered.source, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, previous_raw.source[0..previous_end], " \t\r"), "=={{sprǣc|en}}==") or
        !std.mem.eql(u8, std.mem.trim(u8, raw.source[0..raw_end], " \t\r"), "==Nama==") or
        !std.mem.eql(u8, std.mem.trim(u8, rendered.source[0..rendered_end], " \t\r"), "==Nama==")) return null;
    // Require the literal first non-whitespace token, not a template inside a
    // comment, protected span, nested template, example or later translation.
    const body = std.mem.trimStart(u8, raw.source[raw_end + 1 ..], " \t\r\n");
    const headword = "{{en-nama}}";
    if (!std.mem.startsWith(u8, body, headword) or
        (body.len > headword.len and !std.ascii.isWhitespace(body[headword.len]))) return null;
    const language = codes.resolve("en") orelse return null;
    return if (std.mem.eql(u8, language.code, "en")) language else null;
}

fn processMain(
    page_allocator: std.mem.Allocator,
    spools: *Spools,
    codes: LanguageCodes,
    title: []const u8,
    source_raw: []const u8,
    raw_source: ?[]const u8,
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
    poem_phase: ?*const presentation_document.PoemPhase,
) !void {
    // MediaWiki's first body TOC is page-scoped, before language-owner regrouping.
    const source = try presentation_document.preparePageTocSourceAlloc(page_allocator, source_raw, codes.behavior_switches);
    defer if (source.ptr != source_raw.ptr) page_allocator.free(source);
    stats.main_pages += 1;

    if (fallbacks.expansion_error and source.len == 0) {
        const language = codes.content() orelse ResolvedLanguage{ .code = "", .heading = "Unclassified" };
        const payload = try presentation_document.compileReportedWithOptionsAndPoemAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            "",
            null,
            codes.link_trail,
            codes.namespace_catalog,
            codes.behavior_switches,
            codes.image_options,
            fallbacks,
            poem_phase,
        );
        try spools.appendLanguage(page_allocator, language.heading, title, payload);
        stats.language_records += 1;
        return;
    }

    // Resolvers may return the supplied heading slice. Keep projections alive
    // through grouping/encoding, including failure paths with a non-arena caller.
    var owned_headings: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_headings.items) |heading| page_allocator.free(heading);
        owned_headings.deinit(page_allocator);
    }
    var page_sections: std.ArrayList(language_source.Section) = .empty;
    defer page_sections.deinit(page_allocator);
    const expanded_markers: LanguageMarkers = .{ .codes = &codes };
    var sections = languageSections(source, &expanded_markers);
    while (sections.next()) |section| try appendClassifiedSection(page_allocator, codes, &page_sections, &owned_headings, section);

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
        while (raw_it.next()) |section| try appendClassifiedSection(page_allocator, codes, &raw_sections, &owned_headings, section);
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
        const payload = try presentation_document.compileReportedWithOptionsAndPoemAlloc(
            page_allocator,
            title,
            .language,
            "Unclassified",
            "",
            source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
            codes.behavior_switches,
            codes.image_options,
            fallbacks,
            poem_phase,
        );
        try spools.appendLanguage(page_allocator, "Unclassified", title, payload);
        stats.language_records += 1;
        return;
    };

    const page_prefix = if (page_sections.items.len != 0)
        source[0 .. @intFromPtr(page_sections.items[0].source.ptr) - @intFromPtr(source.ptr)]
    else
        "";
    const shared_prefix = try sharedImagePrefix(page_allocator, codes, page_prefix);

    var groups: std.ArrayList(PageLanguageGroup) = .empty;
    defer {
        for (groups.items) |*group| group.source.deinit(page_allocator);
        groups.deinit(page_allocator);
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(page_allocator);
    var current: ?usize = null;
    // Mixed-depth language boundaries can reveal an uncertain region even
    // when raw and expanded section counts agree. Keep it separate; pages
    // with only one boundary depth retain their support-heading policy.
    var isolate_arabic_lemmas = false;
    for (page_sections.items) |section| if (arabicLemmaDeclaration(codes, section).present) {
        isolate_arabic_lemmas = true;
        break;
    };
    // Once this convention is present, later unresolved L2 lemmas must not
    // inherit a previous noun owner. Other pages retain their existing policy.
    const isolate_mixed = sections.mixed_levels or isolate_arabic_lemmas;
    const unresolved_before_sections = fallbacks.unresolved_language_heading;

    for (page_sections.items, 0..) |section, index| {
        const ang_continuation = if (raw_aligned and index > 0 and current != null)
            angEnglishNounContinuation(codes, raw_sections.items[index - 1], raw_sections.items[index], section, groups.items[current.?].language.code)
        else
            null;
        var resolved: ?ResolvedLanguage = ang_continuation;
        if (resolved == null and raw_aligned) resolved = resolveSection(codes, raw_sections.items[index]);
        if (ang_continuation == null) if (resolved) |raw_language| if (boundaryLanguage(codes, section)) |rendered_language| {
            if (!std.mem.eql(u8, raw_language.code, rendered_language.code) and
                !corroboratedEqualsDeclaration(codes, raw_sections.items[index], section, raw_language.code, rendered_language.code))
            {
                resolved = null;
                fallbacks.unresolved_language_heading = true;
            }
        };
        if (resolved == null) resolved = resolveSection(codes, section);

        if (resolved == null and (isolate_mixed or hasExplicitLanguageDeclaration(codes, section) or
            (raw_aligned and hasExplicitLanguageDeclaration(codes, raw_sections.items[index]))))
        {
            fallbacks.unresolved_language_heading = true;
            resolved = .{ .code = "", .heading = "Unclassified" };
        }

        if (resolved) |language| {
            const group_index = groupIndex(groups.items, language) orelse blk: {
                try groups.append(page_allocator, .{ .language = language });
                if (shared_prefix) |prefix| try groups.items[groups.items.len - 1].source.appendSlice(page_allocator, prefix);
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
        // Arbitrary unknown headings cannot inherit a page-wide category.
        // The captured AM support-heading convention has separate, corroborated
        // raw/expanded category authority and preserves the whole entry body.
        const am_support = amharicSupportCategoryLanguage(codes, source, raw_source, raw_sections.items, page_sections.items);
        const explicit = if (page_sections.items.len == 0)
            unsectionedLanguage(codes, raw_source orelse source) orelse unsectionedExpandedLanguage(codes, source)
        else
            am_support;
        if (am_support != null) fallbacks.unresolved_language_heading = unresolved_before_sections;
        if (explicit == null) fallbacks.missing_language_heading = true;
        // Unknown candidate headings cannot inherit the edition's language.
        // The captured AY -ay- banner has no heading: its noun/adjective
        // templates instead emit these exact POS headings. Preserve only that
        // corroborated native convention, never an arbitrary AY boundary.
        const native_default: ?ResolvedLanguage = native: {
            const language = codes.content() orelse break :native null;
            if (page_sections.items.len == 0) break :native language;
            if (!std.mem.eql(u8, language.code, "ay") or raw_sections.items.len == 0 or
                !raw_sections.items[0].hyphen_marker or
                !std.mem.eql(u8, raw_sections.items[0].heading, "ay")) break :native null;
            for (raw_sections.items) |section| {
                if (!section.hyphen_marker or
                    !(std.mem.eql(u8, section.heading, "ay") or
                        std.mem.eql(u8, section.heading, "adj"))) break :native null;
            }
            for (page_sections.items) |section| {
                const heading = std.mem.trim(u8, section.heading, " \t\r\n");
                if (!std.mem.eql(u8, heading, "<div><big><big>[[suti|Suti]]</big></big></div>") and
                    !std.mem.eql(u8, heading, "<big><big>[[mayjachiri|Mayjachiri]]</big></big>")) break :native null;
            }
            break :native language;
        };
        const language = explicit orelse native_default orelse ResolvedLanguage{ .code = "", .heading = "Unclassified" };
        const payload = try presentation_document.compileReportedWithOptionsAndPoemAlloc(
            page_allocator,
            title,
            .language,
            language.heading,
            language.code,
            source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
            codes.behavior_switches,
            codes.image_options,
            fallbacks,
            poem_phase,
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

    // Preserve ordinary page context only for one unambiguous language.
    // Repeated resolved sections may share that group; inherited unknown
    // sections and pending unresolved regions must not gain attribution.
    const preserve_prefix = shared_prefix == null and page_prefix.len != 0 and
        groups.items.len == 1 and groups.items[0].language.code.len != 0 and
        !fallbacks.unresolved_language_heading;
    const reference_context = try presentation_document.referenceDefinitionsAlloc(page_allocator, source);
    for (groups.items) |group| {
        const group_source = if (preserve_prefix)
            try std.mem.concat(page_allocator, u8, &.{ page_prefix, group.source.items })
        else
            group.source.items;
        const payload = try presentation_document.compileReportedWithReferencesAndPoemAlloc(
            page_allocator,
            title,
            .language,
            group.language.heading,
            group.language.code,
            group_source,
            if (display_title) |value| .{ .source = value, .page_title = title } else null,
            codes.link_trail,
            codes.namespace_catalog,
            codes.behavior_switches,
            codes.image_options,
            reference_context,
            fallbacks,
            poem_phase,
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
    behavior_switches: ?*const @import("namespace_registry").behavior_switches.Registry,
    image_options: ?*const @import("namespace_registry").image_options.Registry,
    ns: PageNamespace,
    title: []const u8,
    source: []const u8,
    display_title: ?[]const u8,
    stats: *BuildStats,
    fallbacks: *presentation_document.Fallbacks,
    poem_phase: ?*const presentation_document.PoemPhase,
) !void {
    const kind = ns.kind;
    // Supplemental namespaces share one file, so keep their full localized
    // names to avoid collisions between identically named namespace suffixes.
    const local_title = if (kind == .supplemental) title else localNamespaceTitle(title);
    const payload = try presentation_document.compileReportedWithOptionsAndPoemAlloc(
        page_allocator,
        local_title,
        kind,
        null,
        "",
        source,
        if (display_title) |value| .{ .source = value, .page_title = title } else null,
        link_trail,
        namespace_catalog,
        behavior_switches,
        image_options,
        fallbacks,
        poem_phase,
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
        inline for (.{ "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss", "symbols", "templates", "redirects", "pages", "aliases" }) |name| {
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

    /// Compile one XML-classified direct redirect without executing an empty tail.
    pub fn addAlias(self: *Writer, a: std.mem.Allocator, record: blobs.alias_codec.Record) !void {
        return self.addAliasExpanded(a, record, "", null, .{}, &.{});
    }
    pub fn addAliasExpanded(self: *Writer, a: std.mem.Allocator, record: blobs.alias_codec.Record, tail: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks, extra_reasons: []const []const u8) !void {
        return self.addAliasExpandedInternal(a, record, tail, display_title, initial_fallbacks, extra_reasons, null);
    }

    pub fn addAliasExpandedWithPoem(self: *Writer, a: std.mem.Allocator, record: blobs.alias_codec.Record, tail: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks, extra_reasons: []const []const u8, poem_metadata: ?[]const u8) !void {
        var phase_arena = std.heap.ArenaAllocator.init(a);
        defer phase_arena.deinit();
        const phase = try presentation_document.parsePoemPhaseAlloc(phase_arena.allocator(), tail, display_title, poem_metadata);
        return self.addAliasExpandedInternal(a, record, tail, display_title, initial_fallbacks, extra_reasons, phase);
    }

    fn addAliasExpandedInternal(self: *Writer, a: std.mem.Allocator, record: blobs.alias_codec.Record, tail: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks, extra_reasons: []const []const u8, poem_phase: ?*const presentation_document.PoemPhase) !void {
        if (self.finished) return error.WriterFinished;
        var fallbacks = initial_fallbacks;
        const destination = if (record.fragment.len == 0) record.target_title else try std.fmt.allocPrint(a, "{s}#{s}", .{ record.target_title, record.fragment });
        const link: blobs.presentation_types.Span = .{ .kind = .link, .text = destination, .target = destination };
        var entry: blobs.presentation_types.Entry = .{ .title = record.source_title, .kind = .alias, .preamble_spans = &.{link} };
        if (tail.len != 0) {
            const tail_payload = try presentation_document.compileReportedWithOptionsAndPoemAlloc(a, record.source_title, .alias, null, "", tail, if (display_title) |value| .{ .source = value, .page_title = record.source_title } else null, self.language_codes.link_trail, self.language_codes.namespace_catalog, self.language_codes.behavior_switches, self.language_codes.image_options, &fallbacks, poem_phase);
            entry = (try blobs.presentation_codec.decodeAlloc(a, tail_payload, record.source_title, .alias, null)).entry;
            const preamble = try a.alloc(blobs.presentation_types.Span, entry.preamble_spans.len + 2);
            preamble[0] = link;
            preamble[1] = .{ .kind = .line_break };
            @memcpy(preamble[2..], entry.preamble_spans);
            entry.preamble_spans = preamble;
        }
        var compiled = record;
        compiled.presentation = try blobs.presentation_codec.encodeAlloc(a, .{ .entry = entry });
        const payload = try blobs.alias_codec.encodeAlloc(a, compiled);
        const key = try blobs.alias_codec.keyAlloc(a, record.source_kind, record.source_key);
        try self.spools.aliases.append(self.io, a, "", key, payload);
        self.stats.alias_records += 1;
        if (record.source_namespace == 0) self.stats.main_pages += 1;
        try self.reportFallback(a, .{ .id = record.source_namespace, .kind = record.source_kind }, record.source_title, fallbacks, extra_reasons);
        try self.namespace_coverage.alias(record.source_namespace, if (fallbacks.any() or extra_reasons.len != 0) .fallback else .expanded);
    }

    pub fn addPage(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, .{}, &.{}, null);
    }

    pub fn addExpandedPage(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, raw_source: []const u8, display_title: ?[]const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, raw_source, display_title, .{}, &.{}, null);
    }

    pub fn addExpandedPageWithReasons(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, raw_source: []const u8, display_title: ?[]const u8, extra_reasons: []const []const u8) !void {
        return self.addPageInternal(page_allocator, ns, title, source, raw_source, display_title, .{}, extra_reasons, null);
    }

    pub fn addExpandedPageWithReasonsAndPoem(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, raw_source: []const u8, display_title: ?[]const u8, extra_reasons: []const []const u8, poem_metadata: ?[]const u8) !void {
        var phase_arena = std.heap.ArenaAllocator.init(page_allocator);
        defer phase_arena.deinit();
        const phase = try presentation_document.parsePoemPhaseAlloc(phase_arena.allocator(), source, display_title, poem_metadata);
        return self.addPageInternal(page_allocator, ns, title, source, raw_source, display_title, .{}, extra_reasons, phase);
    }

    pub fn addPageWithFallback(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, source: []const u8, display_title: ?[]const u8, initial_fallbacks: presentation_document.Fallbacks) !void {
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, initial_fallbacks, &.{}, null);
    }

    pub fn addExpansionFailure(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, reasons: []const []const u8) !void {
        // Operational expansion failures have no MediaWiki page semantics to
        // synthesize. Retain an empty data-only record and put the exact cause
        // in the build report instead of inventing visible reader content.
        const source = "";
        return self.addPageInternal(page_allocator, ns, title, source, null, null, .{ .expansion_error = true }, reasons, null);
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
        return self.addPageInternal(page_allocator, ns, title, source, source, display_title, initial_fallbacks, extra_reasons, null);
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
        poem_phase: ?*const presentation_document.PoemPhase,
    ) !void {
        if (self.finished) return error.WriterFinished;
        var fallbacks = initial_fallbacks;
        if (ns.kind == .language) {
            try processMain(page_allocator, &self.spools, self.language_codes, title, source, raw_source, display_title, &self.stats, &fallbacks, poem_phase);
        } else {
            try processNamespace(page_allocator, &self.spools, self.language_codes.link_trail, self.language_codes.namespace_catalog, self.language_codes.behavior_switches, self.language_codes.image_options, ns, title, source, display_title, &self.stats, &fallbacks, poem_phase);
        }
        try self.reportFallback(page_allocator, ns, title, fallbacks, extra_reasons);
    }

    fn reportFallback(self: *Writer, page_allocator: std.mem.Allocator, ns: PageNamespace, title: []const u8, fallbacks: presentation_document.Fallbacks, extra_reasons: []const []const u8) !void {
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
        try finalizeFixedSpool(self.io, self.allocator, &self.spools.aliases, self.output_root, "aliases", .alias);
        // Alias-only feature namespaces still have a selected compiled store.
        inline for (.{ blob_format.BlobKind.thesaurus, .citations, .reconstruction, .rhymes, .sign_gloss, .supplemental }) |kind| {
            const spool = &@field(self.spools, @tagName(kind));
            if (spool.offset == 0) {
                var has_alias = false;
                var rows = self.namespace_coverage.rows.valueIterator();
                while (rows.next()) |row| if (row.kind == kind and row.alias_pages != 0) {
                    has_alias = true;
                    break;
                };
                if (has_alias) {
                    const path = try std.fs.path.join(self.allocator, &.{ self.output_root, blob_catalog.featureBlobFilename(kind).? });
                    defer self.allocator.free(path);
                    try writeBlobFile(self.io, path, kind, "", &.{});
                }
            }
        }
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
    var banner_namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer banner_namespaces.deinit();
    var banner_codes = TestLanguages.codes();
    banner_codes.namespace_catalog = &banner_namespaces;
    const banner = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>";
    try std.testing.expect(resolveSection(banner_codes, .{ .heading = banner, .source = "" }) != null);
    try std.testing.expectEqualStrings("an", resolveSection(banner_codes, .{ .heading = banner, .source = "" }).?.code);
    for ([_][]const u8{
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Catalán|Aragonés]]''''' <small>- ''Aragonés''</small></div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Aragonés|Aragonés]]''''' <small>- ''Catalán''</small></div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Unknown|Unknown]]''''' <small>- ''Unknown''</small></div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Aragonés|Aragonés]]''''' <small>- ''</small></div>",
        "<nowiki><div id=\"toc\" class=\"toccolours\" >'''''[[Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div></nowiki>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Aragonés|Aragonés]]''''' extra <small>- ''Aragonés''</small></div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Aragonés|Aragonés]]''''' '''''[[Catalán|Catalán]]''''' <small>- ''Aragonés''</small></div>",
    }) |bad_banner| try std.testing.expect(resolveSection(banner_codes, .{ .heading = bad_banner, .source = "" }) == null);
    try std.testing.expect(resolveSection(TestLanguages.codes(), .{ .heading = banner, .source = "" }) == null);
    var foreign_namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer foreign_namespaces.deinit();
    var foreign_codes = TestLanguages.codes();
    foreign_codes.namespace_catalog = &foreign_namespaces;
    try std.testing.expect(resolveSection(foreign_codes, .{ .heading = banner, .source = "" }) == null);
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
    // A native banner cannot adopt a genuinely unknown heading or another
    // explicit language declaration merely because both use local POS markup.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ay-unknown", "<div>'''[[Aymara aru|AYMARA ARU]]'''</div>\n==Unknown language==\n# unknown definition\n", "{{-ay-}}\n==Unknown language==\n# unknown definition\n", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ay-foreign", "<div>'''[[Aymara aru|AYMARA ARU]]'''</div>\n==<div><big><big>[[suti|Suti]]</big></big></div>==\n# native part\n==<div><big><big>[[suti|Suti]]</big></big></div>==\n# foreign part\n", "{{-ay-}}\n{{-noun-}}\n# native part\n{{-fr-}}\n{{-noun-}}\n# foreign part\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 4), stats.fallback_pages);
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
    try std.testing.expect((try index.find("ay-unknown")) == null);
    try std.testing.expect((try index.find("ay-foreign")) == null);
    var unknown_mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Unclassified"));
    defer unknown_mapped.deinit();
    const unknown_blob = try blob_format.inspect(unknown_mapped.bytes);
    try std.testing.expectEqualStrings("", (try unknown_blob.languageMetadata()).code);
    var unknown_index = try unknown_blob.buildTrustedIndexAlloc(a);
    defer unknown_index.deinit(a);
    const unknown_record = (try unknown_index.find("ay-unknown")).?;
    try std.testing.expect(std.mem.indexOf(u8, unknown_record.payload, "unknown definition") != null);
    const foreign_record = (try unknown_index.find("ay-foreign")).?;
    try std.testing.expect(std.mem.indexOf(u8, foreign_record.payload, "native part") != null);
    try std.testing.expect(std.mem.indexOf(u8, foreign_record.payload, "foreign part") != null);
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

// Archived amwiktionary page 1649 "መሬት", XML offset 547933:
// raw text 1528 B / SHA256 6b8d0f5d5077ef010bd0604eea24b63180a7b428b69bba611c86771811986650.
const AmharicSupportCategoryFixture = struct {
    const body = "==ተመሳሳይ ቃላት==\n*[[🜨]]\n\n== ትርጉሞች በየቋንቋው ==\n* እንግሊዝኛ - Earth\n";
    const source = body ++ "[[መደብ:አማርኛ]]\n";
    fn namespaces(a: std.mem.Allocator) !@import("namespace_registry").Registry {
        return @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tamwiktionary\n# dump-date\t20261001\n# content-language\tam\n" ++
            "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
            "10\tመለጠፊያ\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
            "14\tመደብ\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    }
    fn resolve(a: std.mem.Allocator, codes: LanguageCodes, raw: ?[]const u8, expanded: []const u8) !?ResolvedLanguage {
        var raw_sections: std.ArrayList(language_source.Section) = .empty;
        defer raw_sections.deinit(a);
        var page_sections: std.ArrayList(language_source.Section) = .empty;
        defer page_sections.deinit(a);
        const markers: LanguageMarkers = .{ .codes = &codes };
        if (raw) |text| {
            var it = languageSections(text, &markers);
            while (it.next()) |section| try raw_sections.append(a, section);
        }
        var it = languageSections(expanded, &markers);
        while (it.next()) |section| try page_sections.append(a, section);
        return amharicSupportCategoryLanguage(codes, expanded, raw, raw_sections.items, page_sections.items);
    }
};

test "Amharic corroborated support headings retain language owner and lexical body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try AmharicSupportCategoryFixture.namespaces(a);
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    const source = AmharicSupportCategoryFixture.source;
    try std.testing.expectEqualStrings("am", (try AmharicSupportCategoryFixture.resolve(a, codes, source, source)).?.code);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "መሬት", source, source, null);
    // Exercise the actual writer/report path: corroborated language ownership
    // must not erase an independently supplied parser fallback reason.
    try writer.addPageWithFallback(a, .{ .id = 0, .kind = .language }, "preserved-warning", source, null, .{ .malformed_table = true, .unresolved_language_heading = true });
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "አማርኛ"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("am", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("መሬት")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("am", decoded.entry.language_code);
    for ([_][]const u8{ "ተመሳሳይ ቃላት", "ትርጉሞች በየቋንቋው", "Earth" }) |text|
        try std.testing.expect(std.mem.indexOf(u8, record.payload, text) != null);
    try std.testing.expect((try index.find("preserved-warning")) != null);
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, report, "malformed_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "unresolved_language_heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "missing_language_heading") == null);
}

test "Amharic support attribution refuses ambiguous absent and conflicting evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try AmharicSupportCategoryFixture.namespaces(a);
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    const source = AmharicSupportCategoryFixture.source;
    for ([_][]const u8{
        AmharicSupportCategoryFixture.body,
        AmharicSupportCategoryFixture.body ++ "<!--[[መደብ:አማርኛ]]-->[[:መደብ:አማርኛ]]\n",
        source ++ "[[መደብ:እንግሊዝኛ]]\n",
        source ++ "\n==Unknown language==\n# uncertain\n",
        source ++ "\n==English==\n# foreign declaration\n",
        "==English==\n# foreign declaration\n==ትርጉሞች በየቋንቋው==\n* Earth\n[[መደብ:አማርኛ]]\n",
        "<nowiki>" ++ AmharicSupportCategoryFixture.body ++ "</nowiki>[[መደብ:አማርኛ]]\n",
        "===ተመሳሳይ ቃላት===\n*word\n===ትርጉሞች በየቋንቋው===\n*Earth\n[[መደብ:አማርኛ]]\n",
    }) |uncertain| try std.testing.expect(try AmharicSupportCategoryFixture.resolve(a, codes, uncertain, uncertain) == null);
    try std.testing.expect(try AmharicSupportCategoryFixture.resolve(a, codes, null, source) == null);
    try std.testing.expect(try AmharicSupportCategoryFixture.resolve(a, codes, source, AmharicSupportCategoryFixture.body ++ "[[መደብ:እንግሊዝኛ]]\n") == null);
    var foreign_namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tመደብ\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer foreign_namespaces.deinit();
    codes.namespace_catalog = &foreign_namespaces;
    try std.testing.expect(try AmharicSupportCategoryFixture.resolve(a, codes, source, source) == null);
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

test "unresolved plain language headings preserve bodies without claiming edition language" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Local = struct {
        fn am(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "am", .heading = "አማርኛ" };
        }
        fn af(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "af", .heading = "Afrikaans" };
        }
    };
    var codes = TestLanguages.codes();
    codes.content_fn = Local.am;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;

    // Labels deliberately absent from the fixture registry. Definitions
    // follow AM revisions21797/22112, without inferring a language code.
    const pali = "==ፓሊኛ==\n===ስም===\n'''aggi'''\n# [[እሳት]]\n";
    const russian = "== ሩሲያኛ ==\n=== ስም ===\n'''Максим'''\n# የሩሲያ ወንድ ስም\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "aggi", pali, pali, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Максим", russian, russian, null);
    // A support heading alone is not evidence of a particular language.
    const support = "==Noun==\n# Unresolved support-only body [[lemma]].\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "support-only", support, support, null);
    // Existing language-field convention must still identify English.
    const network = "==ቋንቋ==\n* እንግሊዝኛ\n===ገለፃ/ትርጉም===\n# የሰዎች ማኅበራዊ ቅጥጥሎሽ\n# [[አውታር]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "network", network, network, null);
    // Source-instantiated unsectioned AF beginde body, not a captured expansion.
    writer.language_codes.content_fn = Local.af;
    const beginde = "''Byvoeglike voltooide deelwoord'' van [[begin]].\n::wat mens begin het\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "beginde", beginde, beginde, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 5), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 4), stats.fallback_pages);

    const Expected = struct {
        title: []const u8,
        heading: []const u8,
        code: []const u8,
        body: []const u8,
        later_body: ?[]const u8 = null,
        link: ?[]const u8 = null,
    };
    const expected = [_]Expected{
        .{ .title = "aggi", .heading = "Unclassified", .code = "", .body = "እሳት", .link = "እሳት" },
        .{ .title = "Максим", .heading = "Unclassified", .code = "", .body = "የሩሲያ ወንድ ስም" },
        .{ .title = "support-only", .heading = "Unclassified", .code = "", .body = "Unresolved support-only body", .link = "lemma" },
        .{ .title = "network", .heading = "English", .code = "en", .body = "የሰዎች ማኅበራዊ ቅጥጥሎሽ", .later_body = "አውታር", .link = "አውታር" },
        .{ .title = "beginde", .heading = "Afrikaans", .code = "af", .body = "wat mens begin het", .link = "begin" },
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
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.append(a, '\n');
        };
        const first = std.mem.indexOf(u8, visible.items, item.body) orelse return error.MissingDefinition;
        if (item.later_body) |later| {
            const next = std.mem.indexOf(u8, visible.items, later) orelse return error.MissingSecondDefinition;
            try std.testing.expect(next > first);
        }
        if (item.link) |target| {
            var found = false;
            for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
                found = found or (span.kind == .link and std.mem.eql(u8, span.target, target));
            };
            try std.testing.expect(found);
        }
        if (!std.mem.eql(u8, item.heading, "Unclassified")) {
            inline for (.{ "aggi", "Максим", "support-only" }) |title|
                try std.testing.expect((try index.find(title)) == null);
        } else {
            try std.testing.expect((try index.find("network")) == null);
            try std.testing.expect((try index.find("beginde")) == null);
        }
    }
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, blob_catalog.manifest_filename }), a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "አማርኛ") == null);
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
    try std.testing.expectEqual(@as(usize, 7), stats.language_blobs);

    inline for (.{
        .{ "Nederlands", "nl" },
        .{ "Hrvatski", "hr" },
        .{ "Magyar", "hu" },
        .{ "Middle English", "enm" },
        .{ "Aari", "aiw" },
        .{ "Latyn", "la" },
        .{ "Unclassified", "" },
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
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Unclassified") != null);
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

test "direct XML aliases emit typed data without fabricated language ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/aliases", .{tmp.sub_path});
    defer a.free(root);
    var writer = try Writer.init(io, a, root);
    defer writer.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const cases = [_][2][]const u8{ .{ "Animus", "animus" }, .{ "Combustible", "combustible" }, .{ "County seat", "county seat" }, .{ "Gainst", "gainst" } };
    for (cases) |pair| {
        try writer.namespace_coverage.input(a, 0, "", .language, true);
        try writer.addAlias(arena.allocator(), .{ .source_namespace = 0, .source_kind = .language, .source_title = pair[0], .source_key = pair[0], .xml_target = pair[1], .target_title = pair[1], .target_namespace = 0, .target_kind = .language, .target_key = pair[1], .fragment = "", .presentation = "" });
    }
    try writer.namespace_coverage.input(a, 110, "Thesaurus", .thesaurus, true);
    try writer.addAlias(arena.allocator(), .{ .source_namespace = 110, .source_kind = .thesaurus, .source_title = "Thesaurus:Animus", .source_key = "Animus", .xml_target = "animus", .target_title = "animus", .target_namespace = 0, .target_kind = .language, .target_key = "animus", .fragment = "Latin", .presentation = "" });
    writer.stats.pages_seen = 5;
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 5), stats.alias_records);
    try std.testing.expectEqual(@as(usize, 4), stats.main_pages);
    try std.testing.expectEqual(@as(usize, 0), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const path = try std.fs.path.join(a, &.{ root, "aliases.wikblb" });
    defer a.free(path);
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const view = try blob_format.inspect(mapped.bytes);
    try std.testing.expectEqual(blob_format.BlobKind.alias, view.kind);
    var rows = view.iterator();
    var count: usize = 0;
    while (try rows.next()) |row| {
        const alias = try blobs.alias_codec.decode(row.payload);
        try blobs.alias_codec.validateKey(row.title, alias);
        const doc = try blobs.presentation_codec.decodeAlloc(arena.allocator(), alias.presentation, alias.source_title, .alias, null);
        try std.testing.expect(doc.entry.language == null);
        try std.testing.expectEqual(blobs.presentation_types.InlineKind.link, doc.entry.preamble_spans[0].kind);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    // This empty ordinary feature blob is necessary for opening an alias-only store.
    const feature_path = try std.fs.path.join(a, &.{ root, "thesaurus.wikblb" });
    defer a.free(feature_path);
    var feature = try mmapPath(io, feature_path);
    defer feature.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try blob_format.inspect(feature.bytes)).records.len);
}

test "redirect tail presentation and recoverable tail failures retain exact accounting" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}/tail", .{tmp.sub_path});
    var writer = try Writer.init(io, a, root);
    defer writer.deinit();
    const alias: blobs.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language, .source_title = "A", .source_key = "A", .xml_target = "Missing", .target_title = "Missing", .target_namespace = null, .target_kind = null, .target_key = "", .fragment = "Part", .presentation = "" };
    try writer.namespace_coverage.input(a, 0, "", .language, true);
    try writer.addAliasExpanded(pa, alias, "Tail [[retained]].\n===Details===\nVisible body.", null, .{}, &.{});
    var failed = alias;
    failed.source_title = "B";
    failed.source_key = "B";
    try writer.namespace_coverage.input(a, 0, "", .language, true);
    try writer.addAliasExpanded(pa, failed, "", null, .{ .expansion_error = true }, &.{"expansion_error:expand:SourceFailure"});
    writer.stats.pages_seen = 2;
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 2), stats.alias_records);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    const row = writer.namespace_coverage.rows.get(0).?;
    try std.testing.expectEqual(@as(u64, 2), row.alias_pages);
    try std.testing.expectEqual(@as(u64, 1), row.expanded_pages);
    try std.testing.expectEqual(@as(u64, 1), row.fallback_pages);
    const path = try std.fs.path.join(pa, &.{ root, "aliases.wikblb" });
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const view = try blob_format.inspect(mapped.bytes);
    var rows = view.iterator();
    const first = try blobs.alias_codec.decode((try rows.next()).?.payload);
    const doc = try blobs.presentation_codec.decodeAlloc(pa, first.presentation, first.source_title, .alias, null);
    try std.testing.expectEqualStrings("Missing#Part", doc.entry.preamble_spans[0].target);
    try std.testing.expect(std.mem.indexOf(u8, first.presentation, "Visible body.") != null);
    const report = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(pa, &.{ root, "fallback-pages.jsonl" }), pa, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, report, "expansion_error:expand:SourceFailure") != null);
}

test "mixed linked declarations separate exact Arabic bodies" {
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

    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "إنجليزية", "en", "English" }, .{ "فرنسية", "fr", "French" }, .{ "لاتينية", "la", "Latin" } }) |entry|
                if (std.mem.eql(u8, value, entry[0])) return .{ .code = entry[1], .heading = entry[2] };
            return TestLanguages.resolve(null, value);
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const heading = "=[[في|فِي]] [[لغة|ٱللُّغَةِ]] [[إنجليزية|ٱلْإِنْجْلِيزِيَّةِ]]:=\n";
    try std.testing.expect(resolveLinkedDeclaration(codes, "topic [[إنجليزية]]:") == null);
    try std.testing.expect(resolveLinkedDeclaration(codes, "[[في]] [[لغة]] [[إنجليزية]]: extra") == null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Ohm", heading ++ "[[تصنيف:إنجليزية]]\n* [[أوم]]\n\n== فرنسية[[تصنيف:فرنسية]] ==\n* [[وهم]]", "{{علمي}}\n{{إنكليزية}}\n* [[أوم]]\n\n== {{اللغة|فرنسية}} ==\n* [[وهم]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "alpha", heading ++ "[[تصنيف:إنجليزية]] '''alpha'''\n# ألفا\n== لاتينية[[تصنيف:لاتينية]] ==\n=== اسم ===\n# [[ألف]]", "{{علمي}}\n{{إنكليزية}} '''alpha'''\n# ألفا\n== {{اللغة|لاتينية}} ==\n=== اسم ===\n# [[ألف]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "uncertain", "=topic [[إنجليزية]]=\n# uncertain-only\n==French==\n# french-only", "==French==\n# french-only", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "support", "==English==\n# meaning\n==References==\nsupport-only", "==English==\n# meaning\n==References==\nsupport-only", null);
    const aligned_uncertain = "=topic [[English]]=\n# uncertain-equal\n==French==\n# french-equal";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "equal", aligned_uncertain, aligned_uncertain, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 9), stats.language_records);
    inline for (.{ .{ "English", "Ohm", "أوم", "وهم" }, .{ "French", "Ohm", "وهم", "أوم" }, .{ "English", "alpha", "ألفا", "ألف" }, .{ "Latin", "alpha", "ألف", "ألفا" }, .{ "Unclassified", "uncertain", "uncertain-only", "french-only" }, .{ "French", "uncertain", "french-only", "uncertain-only" }, .{ "English", "support", "support-only", "uncertain-only" }, .{ "Unclassified", "equal", "uncertain-equal", "french-equal" }, .{ "French", "equal", "french-equal", "uncertain-equal" } }) |entry| {
        const path = try languageBlobPathAlloc(a, root, entry[0]);
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(entry[1])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(metadata.code, decoded.entry.language_code);
        var own_body_count: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.text, entry[2])) own_body_count += 1;
            try std.testing.expect(!std.mem.eql(u8, span.text, entry[3]));
            try std.testing.expect(!std.mem.eql(u8, span.target, entry[3]));
        };
        try std.testing.expectEqual(@as(usize, 1), own_body_count);
    }
}

test "mixed boundaries reject arbitrary POS ISO template candidates" {
    const codes = TestLanguages.codes();
    const markers: LanguageMarkers = .{ .codes = &codes };
    const english = "=English=\n=={{-adj-}}==\n# adjective\n=={{example|fr}}==\n# example\n";
    const french = "==French==\n# french\n";
    var it = languageSections(english ++ french, &markers);
    try std.testing.expectEqualStrings(english, it.next().?.source);
    try std.testing.expectEqualStrings(french, it.next().?.source);
    try std.testing.expect(it.next() == null);
}

// Raw witness retained separately; the citation expansion below is explicitly synthetic.
test "cross language named references retain page scoped definitions without body leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "أكادية") or std.mem.eql(u8, value, "Akkadian")) return .{ .code = "akk", .heading = "Akkadian" };
            if (std.mem.eql(u8, value, "سومرية") or std.mem.eql(u8, value, "Sumerian")) return .{ .code = "sux", .heading = "Sumerian" };
            return null;
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "𒂗", "== أكادية ==\n=== المعاني ===\n* '''𒂗''' ([[bēlu]])\n# [[مَالِك]]<ref name=\"a\">𒂗 | Definition of 𒂗 at Definify</ref>\n# [[رَبّ]]<ref name=\"a\"/>\n# [[سَيِّد]]<ref name=\"a\"/>\n# [[حَاكِم]]<ref name=\"a\"/>\n# لقب لآلهة بابلية، منها ''بعل'' و''مردوخ''.<ref name=\"a\"/>\n\n* '''𒂗''' ([[enu]])\n# [[رَئِيس]] [[كَاهِن|اَلْكَهَنَة]]<ref name=\"a\"/>\n# [[إيرل]]<ref name=\"a\"/>\n\n=== الأصل والاشتقاق ===\n* ([[bēlu]]) مشتقة من ''[[*baʿl-]]'' السامية البدائية.<ref name=\"a\"/>\n* ([[enu]]) مشتقة من ''[[𒂗#سومرية|𒂗]]'' السومرية.<ref name=\"a\"/>\n\n== سومرية ==\n=== المعاني ===\n'''𒂗'''\n# شكل بديل من [[𒂗𒈾]].\n# [[رَبّ]]<ref name=\"a\"/>\n# [[مَلِك]]<ref name=\"a\"/>\n# [[سَيِّد]]<ref name=\"a\"/>\n\n=== الأصل والاشتقاق ===\n==== الاشتقاق ====\nأشتقت من '''𒂗''' الكلمات التالية:\n* [[𒂗#آكادية|𒂗]] الآكادية\n\n== المراجع ==\n<references/>", "== {{اللغة|أكادية}} ==\n=== المعاني ===\n* '''𒂗''' ([[bēlu]])\n# [[مَالِك]]<ref name=\"a\">{{استشهاد ويب|عنوان=𒂗 {{!}} Definition of 𒂗 at Definify|مسار=https://www.definify.com/word/%F0%92%82%97|تاريخ الوصول=2024-10-17|موقع=www.definify.com}}</ref>\n# [[رَبّ]]<ref name=\"a\"/>\n# [[سَيِّد]]<ref name=\"a\"/>\n# [[حَاكِم]]<ref name=\"a\"/>\n# لقب لآلهة بابلية، منها ''بعل'' و''مردوخ''.<ref name=\"a\"/>\n\n* '''𒂗''' ([[enu]])\n# [[رَئِيس]] [[كَاهِن|اَلْكَهَنَة]]<ref name=\"a\"/>\n# [[إيرل]]<ref name=\"a\"/>\n\n=== الأصل والاشتقاق ===\n* ([[bēlu]]) مشتقة من ''[[*baʿl-]]'' السامية البدائية.<ref name=\"a\"/>\n* ([[enu]]) مشتقة من ''[[𒂗#سومرية|𒂗]]'' السومرية.<ref name=\"a\"/>\n\n== {{اللغة|سومرية}} ==\n=== المعاني ===\n'''𒂗'''\n# شكل بديل من [[𒂗𒈾]].\n# [[رَبّ]]<ref name=\"a\"/>\n# [[مَلِك]]<ref name=\"a\"/>\n# [[سَيِّد]]<ref name=\"a\"/>\n\n=== الأصل والاشتقاق ===\n==== الاشتقاق ====\nأشتقت من '''𒂗''' الكلمات التالية:\n* [[𒂗#آكادية|𒂗]] الآكادية\n\n== المراجع ==\n{{مراجع}}", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    const path = try languageBlobPathAlloc(a, root, "Sumerian");
    var mapped = try mmapPath(std.testing.io, path);
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("𒂗")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("sux", decoded.entry.language_code);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    try std.testing.expectEqualStrings("a", decoded.entry.references[0].name);
    var references_text: std.ArrayList(u8) = .empty;
    for (decoded.entry.references[0].spans) |span| try references_text.appendSlice(a, span.text);
    try std.testing.expectEqualStrings("𒂗 | Definition of 𒂗 at Definify", references_text.items);
    var markers: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.target, "#reference-1")) markers += 1;
        try std.testing.expect(std.mem.indexOf(u8, span.text, "bēlu") == null);
        try std.testing.expect(std.mem.indexOf(u8, span.text, "enu") == null);
    };
    try std.testing.expectEqual(@as(usize, 3), markers);
}

test "categorized language headings require matching hidden language metadata" {
    var namespaces = try @import("namespace_registry").Registry.init(std.testing.allocator, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    try std.testing.expectEqualStrings("fr", resolveCategorizedHeading(codes, "French[[تصنيف:French|sort]]").?.code);
    inline for (.{ "French[[تصنيف:English]]", "French[[:تصنيف:French]]", "French[[French]]", "French[[تصنيف:French]] extra", "French[[تصنيف:French]", "{{-adj-}}[[تصنيف:French]]", "topic French[[تصنيف:French]]", "French<nowiki>[[تصنيف:French]]</nowiki>" }) |heading|
        try std.testing.expect(resolveCategorizedHeading(codes, heading) == null);
}

test "categorized Russian Bulgarian headings preserve Macedonian and audio" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tملف\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();

    // Exact raw revision 1069817; expanded input is source-instantiated, NOT captured.
    // Language-template categories follow pinned revision1048305. Macedonian
    // heading/audio are synthetic markup matching retained current decoded values.
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "روسية", "ru", "الروسية" }, .{ "بلغارية", "bg", "البلغارية" }, .{ "مقدونية", "mk", "المقدونية" } }) |row|
                if ((std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[2]))) return .{ .code = row[1], .heading = row[2] };
            return null;
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |r| r.code else null;
        }
    };
    var codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const profile_digest: [32]u8 = @splat(0);
    const image_tsv = try std.fmt.allocPrint(a, "# wikidict-image-options-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n# namespace-registry-sha256\t{s}\n# behavior-switches-sha256\t{s}\nimg_thumbnail\t1\t\"تصغير\"\n", .{ std.fmt.bytesToHex(namespaces.source_sha256, .lower), std.fmt.bytesToHex(profile_digest, .lower) });
    var image_options = try @import("namespace_registry").image_options.Registry.init(a, image_tsv, "arwiktionary", "20261001", "ar", namespaces.source_sha256, profile_digest);
    defer image_options.deinit();
    codes.image_options = &image_options;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const raw = "[[ملف:Aptenodytes patagonicus.JPG|تصغير]]\n== {{اللغة|روسية}} ==\n=== اللفظ ===\nألفبائية صوتية دولية: [pʲɪnˈgvʲin] {{لفظ روسي}}\n=== اسم ===\nпингви́н اسم مذكر يجمع على пингви́ны.\n* [[بِطْرِيق]] (طائِرٌ مائِيّ)\n\n== {{اللغة|بلغارية}} ==\n=== اسم ===\nпингвин اسم مذكر يجمع على пингвини.\n* [[بِطْرِيق]] (طائِرٌ مائِيّ)\n{{مقدونية}}\n=== اسم ===\n[[بِطْرِيق]] (طائِرٌ مائِيّ)";
    const expanded = "[[ملف:Aptenodytes patagonicus.JPG|تصغير]]\n== روسية[[تصنيف:روسية]] ==\n=== اللفظ ===\nألفبائية صوتية دولية: [pʲɪnˈgvʲin] [[ملف:Ru-пингвин.ogg]]\n=== اسم ===\nпингви́н اسم مذكر يجمع على пингви́ны.\n* [[بِطْرِيق]] (طائِرٌ مائِيّ)\n\n== بلغارية[[تصنيف:بلغارية]] ==\n=== اسم ===\nпингвин اسم مذكر يجمع على пингвини.\n* [[بِطْرِيق]] (طائِرٌ مائِيّ)\n=مقدونية=\n\n=== اسم ===\n[[بِطْرِيق]] (طائِرٌ مائِيّ)";
    const markers: LanguageMarkers = .{ .codes = &codes };
    var raw_it = languageSections(raw, &markers);
    var raw_count: usize = 0;
    while (raw_it.next() != null) raw_count += 1;
    var expanded_it = languageSections(expanded, &markers);
    var expanded_count: usize = 0;
    while (expanded_it.next() != null) expanded_count += 1;
    try std.testing.expectEqual(@as(usize, 2), raw_count);
    try std.testing.expectEqual(@as(usize, 3), expanded_count);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "пингвин", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 3), stats.language_records);
    inline for (.{ .{ "الروسية", "ru" }, .{ "البلغارية", "bg" }, .{ "المقدونية", "mk" } }) |row| {
        const path = try languageBlobPathAlloc(a, root, row[0]);
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("пингвин")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(row[1], decoded.entry.language_code);
        var text: std.ArrayList(u8) = .empty;
        var definitions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.target, "بِطْرِيق")) definitions += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(std.mem.eql(u8, row[1], "ru"), std.mem.indexOf(u8, text.items, "пингви́ны") != null);
        try std.testing.expectEqual(std.mem.eql(u8, row[1], "bg"), std.mem.indexOf(u8, text.items, "пингвини") != null);
        try std.testing.expectEqual(std.mem.eql(u8, row[1], "ru"), std.mem.indexOf(u8, text.items, "[pʲɪnˈgvʲin]") != null);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, row[1], "ru")) 2 else 1), decoded.entry.media.len);
        try std.testing.expectEqualStrings("Aptenodytes patagonicus.JPG", decoded.entry.media[0].file);
        try std.testing.expectEqualStrings("Aptenodytes patagonicus.JPG", decoded.entry.media[0].caption);
        if (std.mem.eql(u8, row[1], "ru")) try std.testing.expectEqualStrings("Ru-пингвин.ogg", decoded.entry.media[1].file);
    }
}

test "image only page prefixes preserve per language captions and reference ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tملف\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    const image = "[[ملف:Shared.svg|240px|alt=Alt|Shared [[label]]<ref name=shared>caption reference</ref>]]\n";
    const prefix = "<!-- [[ملف:Hidden.png]] -->\n" ++ image;
    try std.testing.expectEqualStrings(prefix, (try sharedImagePrefix(a, codes, prefix)).?);
    inline for (.{ "prose\n" ++ image, image ++ "[[:ملف:Visible.png]]\n", image ++ "[[ordinary]]\n", "<nowiki>" ++ image ++ "</nowiki>\n", "<pre>" ++ image ++ "</pre>\n", image ++ "<ref>standalone reference</ref>\n", image ++ "[[ملف:broken\n", image ++ "[[تصنيف:French]]\n", "[[ملف:Audio.ogg]]\n", "[[ملف:One.png]] [[ملف:Two.png]]\n" }) |bad|
        try std.testing.expect(try sharedImagePrefix(a, codes, bad) == null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const body = "==English==\n# english<ref name=en>english reference</ref>\n[[ملف:Shared.svg|body caption]]\n==French==\n# french<ref name=fr>french reference</ref>\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "prefix", prefix ++ body, prefix ++ body, null);
    const rejected = "visible prose\n" ++ image ++ body;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "prose-prefix", rejected, rejected, null);
    try std.testing.expectEqual(@as(usize, 4), (try writer.finish(codes)).language_records);
    inline for (.{ .{ "English", "en", "english reference", "french reference" }, .{ "French", "fr", "french reference", "english reference" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const metadata = try blob.languageMetadata();
        const rec = (try index.find("prefix")).?;
        const page = try blobs.presentation_codec.decodeAlloc(a, rec.payload, rec.title, .language, metadata);
        try std.testing.expectEqual(@as(usize, 1), page.entry.media.len);
        try std.testing.expectEqualStrings("Shared.svg", page.entry.media[0].file);
        try std.testing.expect(std.mem.startsWith(u8, page.entry.media[0].caption, "Shared label"));
        try std.testing.expectEqual(@as(usize, 2), page.entry.references.len);
        var own: usize = 0;
        var caption_refs: usize = 0;
        for (page.entry.references) |reference| {
            var visible: std.ArrayList(u8) = .empty;
            for (reference.spans) |span| {
                if (span.kind == .line_break) try visible.append(a, '\n');
                try visible.appendSlice(a, span.text);
                try visible.appendSlice(a, span.trail);
            }
            const text = visible.items;
            if (std.mem.eql(u8, text, row[2])) own += 1;
            if (std.mem.eql(u8, text, "caption reference")) caption_refs += 1;
            try std.testing.expect(!std.mem.eql(u8, text, row[3]));
        }
        try std.testing.expectEqual(@as(usize, 1), own);
        try std.testing.expectEqual(@as(usize, 1), caption_refs);
        // Existing mediaLabel flattens caption links into the outer File link.
        try std.testing.expectEqualStrings("Shared label[1]", page.entry.media[0].caption);
        var caption_labels: usize = 0;
        for (page.entry.sections) |section| for (section.blocks) |block| {
            var visible: std.ArrayList(u8) = .empty;
            var media_target = false;
            for (block.spans) |span| {
                if (std.mem.eql(u8, span.target, "File:Shared.svg")) media_target = true;
                if (span.kind == .line_break) try visible.append(a, '\n');
                try visible.appendSlice(a, span.text);
                try visible.appendSlice(a, span.trail);
            }
            if (media_target and std.mem.eql(u8, std.mem.trim(u8, visible.items, " \t\r\n"), "Shared label[1]")) caption_labels += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), caption_labels);
        const rejected_rec = (try index.find("prose-prefix")).?;
        const rejected_page = try blobs.presentation_codec.decodeAlloc(a, rejected_rec.payload, rejected_rec.title, .language, metadata);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, row[1], "en")) 1 else 0), rejected_page.entry.media.len);
        if (std.mem.eql(u8, row[1], "en")) try std.testing.expectEqualStrings("body caption", rejected_page.entry.media[0].caption);
        try std.testing.expectEqual(@as(usize, 1), rejected_page.entry.references.len);
    }
}

test "image only page prefixes retain images across active behavior controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tLêer\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const namespace_hex = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const behavior_raw = try std.fmt.allocPrint(a, "# wikidict-behavior-switches-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n# namespace-registry-sha256\t{s}\nnoeditsection\t0\t__NOEDITSECTION__\nnoeditsection\t0\t__GEENNUWEAFDELING__\nindex\t1\t__INDEX__\n", .{namespace_hex});
    var behavior = try @import("namespace_registry").behavior_switches.Registry.init(a, behavior_raw, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256);
    defer behavior.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    codes.behavior_switches = &behavior;
    const image = "[[Lêer:Iris - left eye of a girl.jpg|duimnael|280px|[1] 'n Menslike oog (kyk hoe kyk hy vir jou).]]\n";
    const prefix = image ++ "__NOEDITSECTION__\n";
    inline for (.{ prefix, "__noeditsection__\n" ++ image, image ++ "__geennuweafdeling__\n", image ++ "__INDEX__\n" }) |value|
        try std.testing.expectEqualStrings(value, (try sharedImagePrefix(a, codes, value)).?);
    inline for (.{ "__NOEDITSECTION__\n", image ++ "__UNKNOWN__\n", image ++ "__index__\n", image ++ "<nowiki>__NOEDITSECTION__</nowiki>\n", image ++ "<pre>__NOEDITSECTION__</pre>\n", image ++ "visible prose\n", image ++ "[[__NOEDITSECTION__]]\n" }) |value|
        try std.testing.expect(try sharedImagePrefix(a, codes, value) == null);
    // Caption content remains inside its balanced image, not scanned as a control.
    const literal_caption = "[[Lêer:Caption.jpg|<nowiki>__NOEDITSECTION__</nowiki>]]\n";
    try std.testing.expectEqualStrings(literal_caption, (try sharedImagePrefix(a, codes, literal_caption)).?);
    codes.behavior_switches = null;
    try std.testing.expectEqualStrings(prefix, (try sharedImagePrefix(a, codes, prefix)).?);
    try std.testing.expect(try sharedImagePrefix(a, codes, image ++ "__GEENNUWEAFDELING__\n") == null);
}

test "AZ finite Dil declarations isolate unknown labels and reject nonlanguage wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tazwiktionary\n# dump-date\t20261001\n# content-language\taz\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tŞəkil\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tŞablon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tKateqoriya\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    const unknown = "<div style=\"background:#EEEEFF\">[[Unknown dili|Unknown dili]][[Kateqoriya:Unknown dilindəki sözlər]]</div>";
    try std.testing.expect(hasExplicitLanguageDeclaration(codes, .{ .heading = unknown, .source = "" }));
    try std.testing.expect(resolveSection(codes, .{ .heading = unknown, .source = "# retained" }) == null);
    try std.testing.expect(hasExplicitLanguageDeclaration(codes, .{ .heading = "{{Dil|Unknown dili}}", .source = "" }));
    inline for (.{ "{{adj|English}}", "{{syn|English}}", "{{Dil|English|extra}}", "{{Dil|lang=English}}", "<div>[[English|English]][[Kateqoriya:Englishndəki sözlər]]</div>", "<div style=\"background:#EEEEFF\">[[English|French]][[Kateqoriya:Englishndəki sözlər]]</div>", "<div style=\"background:#EEEEFF\">[[English|English]][[:Kateqoriya:Englishndəki sözlər]]</div>", "<div style=\"background:#EEEEFF\">[[English|English]][[Kateqoriya:Frenchndəki sözlər]]</div>", "<div style=\"background:#EEEEFF\">[[English|English]][[Kateqoriya:Englishndəki sözlər]]extra</div>", "<nowiki>{{Dil|English}}</nowiki>" }) |bad|
        try std.testing.expect(!hasExplicitLanguageDeclaration(codes, .{ .heading = bad, .source = "" }));
}

test "AZ source proven English declaration retains separate lexical audio and unknown body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tazwiktionary\n# dump-date\t20261001\n# content-language\taz\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tŞəkil\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tŞablon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tKateqoriya\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "Azərbaycan dili", "az", "azərbaycanca" }, .{ "İngilis dili", "en", "English" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[2])) return .{ .code = row[1], .heading = row[2] };
            return null;
        }
        fn trusted(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Azərbaycan dili") or std.mem.eql(u8, value, "İngilis dili")) return null;
            return resolve(null, value);
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |r| r.code else null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.trusted };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact raw Dil labels and lexical excerpts from it revision 358640;
    // wrapper/audio are source-instantiated, not captured expanded wikitext.
    const raw = "=={{Dil|Azərbaycan dili}}==\n# native [[köpək]]\n=={{Dil|Unknown dili}}==\n# unknown-only\n=={{Dil|İngilis dili}}==\n# O (orta cins)\n# Onu, ona (orta cins)\n";
    const expanded = "==<div style=\"background:#EEEEFF\">[[Azərbaycan dili|Azərbaycan dili]][[Kateqoriya:Azərbaycan dilindəki sözlər]]</div>==\n# native [[köpək]]\n" ++
        "==<div style=\"background:#EEEEFF\">[[Unknown dili|Unknown dili]][[Kateqoriya:Unknown dilindəki sözlər]]</div>==\n# unknown-only\n" ++
        "==<div style=\"background:#EEEEFF\">[[İngilis dili|İngilis dili]][[Kateqoriya:İngilis dilindəki sözlər]]</div>==\n# O (orta cins)\n# Onu, ona (orta cins)\n* [ɪt]\n[[Şəkil:En-us-it.ogg|audio (ABŞ)]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "it", expanded, raw, null);
    try std.testing.expectEqual(@as(usize, 3), (try writer.finish(codes)).language_records);
    inline for (.{ .{ "azərbaycanca", "az", "native", "O (orta cins)" }, .{ "English", "en", "O (orta cins)", "native" }, .{ "Unclassified", "", "unknown-only", "native" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("it")).?;
        const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row[1], page.entry.language_code);
        var text: std.ArrayList(u8) = .empty;
        var definitions: usize = 0;
        var native_links: usize = 0;
        for (page.entry.sections) |section| for (section.blocks) |block| {
            if (std.mem.eql(u8, block.list_path, "#")) definitions += 1;
            for (block.spans) |span| {
                try text.appendSlice(a, span.text);
                try text.appendSlice(a, span.trail);
                if (std.mem.eql(u8, span.target, "köpək")) native_links += 1;
            }
        };
        const english = std.mem.eql(u8, row[1], "en");
        const native = std.mem.eql(u8, row[1], "az");
        try std.testing.expectEqual(@as(usize, if (english) 2 else 1), definitions);
        try std.testing.expectEqual(@as(usize, if (native) 1 else 0), native_links);
        try std.testing.expectEqual(english, std.mem.indexOf(u8, text.items, "O (orta cins)") != null);
        try std.testing.expectEqual(english, std.mem.indexOf(u8, text.items, "Onu, ona (orta cins)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, row[2]) != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, row[3]) == null);
        if (row[1].len != 0) try std.testing.expect(std.mem.indexOf(u8, text.items, "unknown-only") == null);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, row[1], "en")) 1 else 0), page.entry.media.len);
        if (page.entry.media.len != 0) try std.testing.expectEqualStrings("En-us-it.ogg", page.entry.media[0].file);
    }
}

test "equals language declarations require exact Norwegian umbrella corroboration" {
    const Codes = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, value, "nb") or std.mem.eql(u8, value, "nn")) return value;
            if (std.mem.eql(u8, value, "Noors")) return "no";
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Codes.get };
    const nb: language_source.Section = .{ .heading = "nb", .source = "{{=nb=}}\n# body\n" };
    const nn: language_source.Section = .{ .heading = "nn", .source = "{{=nn=}}\n# body\n" };
    const bokmal: language_source.Section = .{ .heading = "[[Noors|Noors boekmaal (nb)]]", .source = "" };
    const nynorsk: language_source.Section = .{ .heading = "[[Noors|Nieu-Noors (nn)]]", .source = "" };
    try std.testing.expect(corroboratedEqualsDeclaration(codes, nb, bokmal, "nb", "no"));
    try std.testing.expect(corroboratedEqualsDeclaration(codes, .{ .heading = "nb", .source = "  {{ = nb = }}\n# body\n" }, bokmal, "nb", "no"));
    try std.testing.expect(corroboratedEqualsDeclaration(codes, nn, nynorsk, "nn", "no"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, nb, nynorsk, "nb", "no"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, nb, bokmal, "nb", "en"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, .{ .heading = "nb", .source = "{{-nb-}}\n# body\n", .hyphen_marker = true }, bokmal, "nb", "no"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, nb, .{ .heading = "[[Noors|Noors boekmaal (nb)]] trailing", .source = "" }, "nb", "no"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, nb, .{ .heading = "[[Noors|Noors (nb)|extra]]", .source = "" }, "nb", "no"));
}

test "equals declarations corroborate canonical codes despite colliding display names" {
    const Codes = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, value, "ln") or std.mem.eql(u8, value, "Lingaals")) return "ln";
            if (std.mem.eql(u8, value, "Ngala")) return "nud";
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Codes.get };
    const raw: language_source.Section = .{ .heading = "ln", .source = "{{=ln=}}\n# Praat; Sê.\n" };
    const rendered: language_source.Section = .{ .heading = "[[Ngala|Ngala (ln)]]", .source = "" };
    try std.testing.expect(corroboratedEqualsDeclaration(codes, raw, rendered, "ln", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, raw, rendered, "nud", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, raw, .{ .heading = "[[Ngala|Ngala (nud)]]", .source = "" }, "ln", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, .{ .heading = "ln", .source = "{{-ln-}}\n# body\n", .hyphen_marker = true }, rendered, "ln", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, raw, .{ .heading = "[[Ngala|Ngala (ln)]] trailing", .source = "" }, "ln", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, raw, .{ .heading = "[[Ngala|Ngala (ln)|extra]]", .source = "" }, "ln", "nud"));
    try std.testing.expect(!corroboratedEqualsDeclaration(codes, .{ .heading = "ln", .source = "{{=ln=}} trailing\n# body\n" }, rendered, "ln", "nud"));
}

test "Arabic whole linked declarations match vocalized language labels without guessing lemmas" {
    const a = std.testing.allocator;
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "الكردية")) return .{ .code = "ku", .heading = "الكردية" };
            if (std.mem.eql(u8, value, "الإنجليزية")) return .{ .code = "en", .heading = "الإنجليزية" };
            if (std.mem.eql(u8, value, "ألمانية")) return .{ .code = "de", .heading = "الألمانية" };
            if (std.mem.eql(u8, value, "إنجليزية")) return .{ .code = "en", .heading = "الإنجليزية" };
            if (std.mem.eql(u8, value, "عربية")) return .{ .code = "ar", .heading = "العربية" };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .trusted_fn = Local.resolve };
    const exact = "[[فِي]] [[لُغَة|ٱللُّغَةِ]] [[كردي|ٱلْكُرْدِيَّةِ]]:";
    const resolved = resolveLinkedDeclaration(codes, exact).?;
    try std.testing.expectEqualStrings("ku", resolved.code);
    try std.testing.expectEqualStrings("الكردية", resolved.heading);
    try std.testing.expectEqualStrings("ku", resolveLinkedDeclaration(codes, "[[في]] [[لغة]] [[:الكردية]]:").?.code);
    for ([_][]const u8{
        "[[في]] [[لغة]] [[الكردية|الإنجليزية]]:",
        "[[في]] [[لغة]] [[كردي|مجهولة]]:",
        "[[في]] [[لغة]] [[كردي|ٱلْكُرْدِيَّةِ|extra]]:",
        "[[في]] [[لغة]] [[كردي|ٱلْكُرْدِيَّةِ]]: trailing",
        "[[في]] [[لغة]] [[كردي|ٱلْكُرْدِيَّةِ]] [[الإنجليزية]]:",
        "<nowiki>[[في]] [[لغة]] [[الكردية]]:</nowiki>",
        "aal",
        "اَلْمَعَانِي",
    }) |negative| try std.testing.expect(resolveLinkedDeclaration(codes, negative) == null);
    // aalen revision 1135343: the whole L2 is an explicit German declaration.
    const aalen_source = "== لغة ألمانية ==\n=== المعنى ===\nاستلقى أو تمدد ليرتاح .\n";
    try std.testing.expect(resolveSection(codes, .{ .heading = "لغة ألمانية", .source = aalen_source }) != null);
    try std.testing.expectEqualStrings("de", resolveSection(codes, .{ .heading = "لغة ألمانية", .source = aalen_source }).?.code);
    for ([_][]const u8{
        "لغة مجهولة",
        "لغة ألمانية الإنجليزية",
        "لغة [[ألمانية|الإنجليزية]]",
        "لغة ألمانية [[الإنجليزية]]",
        "لغة ألمانية|الإنجليزية",
        "لغة",
        "لغةألمانية",
        "اسم ألماني",
        "اسم عَلَم",
        "اَلْمَعَانِي",
        "<nowiki>لغة ألمانية</nowiki>",
    }) |heading| try std.testing.expect(resolveSection(codes, .{ .heading = heading, .source = "" }) == null);
    var other_codes = codes;
    other_codes.namespace_catalog = null;
    try std.testing.expect(resolveSection(other_codes, .{ .heading = "لغة ألمانية", .source = aalen_source }) == null);
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "[[إِنْجْلِيزِيَّة|إِنْجِلِيْزِيَّة]]", .source = "" }).?.code);
    try std.testing.expectEqualStrings("ar", resolveSection(codes, .{ .heading = "[[عَرَبِيَّة]]", .source = "" }).?.code);
    for ([_][]const u8{ "[[أَلْمَانِيَّة|إِنْجِلِيزِيَّة]]", "[[عَرَبِيَّة|مجهولة]]", "[[عَرَبِيَّة|عَرَبِيَّة|extra]]", "[[عَرَبِيَّة]] [[إنجليزية]]" }) |heading|
        try std.testing.expect(resolveSection(codes, .{ .heading = heading, .source = "" }) == null);
    try std.testing.expect(!language_source.arabicNounSubtree(.{ .heading = "إنجليزي", .source = "== إنجليزي ==\n=== اسم عَلَم ===\n# هيئة الإذاعة البريطانية\n" }, null).present);
    try std.testing.expect(!language_source.arabicNounSubtree(.{ .heading = "إنجليزي", .source = "== إنجليزي ==\n=== اسم علم ===\n# proper noun\n" }, null).present);
    try std.testing.expectEqualStrings("de", resolveSection(codes, .{ .heading = "[[ألمانية|arbitrary display text]]", .source = "" }).?.code);
    try std.testing.expect(resolveSection(codes, .{ .heading = "[[ألمانية|إِنْجِلِيزِيَّة]]", .source = "" }) == null);
    var tiny: [1]u8 = undefined;
    try std.testing.expect(arabicDeclarationToken("الكردية", &tiny) == null);
}

test "unsupported parser reason retains normal raw ownership and alias body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/unsupported", .{tmp.sub_path});
    var writer = try Writer.init(io, a, root);
    defer writer.deinit();
    const codes = TestLanguages.codes();
    writer.language_codes = codes;
    const reasons: []const []const u8 = &.{ "unsupported_parser_function", "unsupported_parser_function" };
    try writer.namespace_coverage.input(a, 0, "", .language, true);
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "word", "== Hallo ([[:Template:Sprache]]) ==\n# [[retained]] <nowiki>{{#unknown:x}}</nowiki>\n", "== Hallo ({{Sprache|Deutsch}}) ==\n# [[retained]] {{#unknown:x}}\n", null, reasons);
    try writer.namespace_coverage.outcome(0, .fallback);
    const alias: blobs.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language, .source_title = "alias", .source_key = "alias", .xml_target = "word", .target_title = "word", .target_namespace = null, .target_kind = null, .target_key = "", .fragment = "", .presentation = "" };
    try writer.namespace_coverage.input(a, 0, "", .language, true);
    try writer.addAliasExpanded(a, alias, "Tail [[retained]] <nowiki>{{#unknown:x}}</nowiki>", null, .{}, reasons);
    writer.stats.pages_seen = 2;
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.fallback_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.alias_records);
    const report = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const actual = parsed.value.object.get("reasons").?.array.items;
        var reason_count: usize = 0;
        for (actual) |reason| if (std.mem.eql(u8, reason.string, "unsupported_parser_function")) {
            reason_count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), reason_count);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    var english = try mmapPath(io, try languageBlobPathAlloc(a, root, "Deutsch"));
    defer english.deinit();
    try std.testing.expectEqualStrings("de", (try (try blob_format.inspect(english.bytes)).languageMetadata()).code);
    try std.testing.expect(std.mem.indexOf(u8, english.bytes, "retained") != null);
    try std.testing.expect(std.mem.indexOf(u8, english.bytes, "{{#unknown:x}}") != null);
    var aliases = try mmapPath(io, try std.fs.path.join(a, &.{ root, "aliases.wikblb" }));
    defer aliases.deinit();
    const view = try blob_format.inspect(aliases.bytes);
    var rows = view.iterator();
    const decoded = try blobs.alias_codec.decode((try rows.next()).?.payload);
    try std.testing.expect(std.mem.indexOf(u8, decoded.presentation, "Tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded.presentation, "{{#unknown:x}}") != null);
}

test "protected template arguments cannot corroborate an untrusted language alias" {
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Example alias") or std.mem.eql(u8, value, "en"))
                return .{ .code = "en", .heading = "English" };
            return null;
        }
        fn untrusted(_: ?*const anyopaque, _: []const u8) ?ResolvedLanguage {
            return null;
        }
    };
    const codes: LanguageCodes = .{ .resolve_fn = Local.resolve, .strong_fn = Local.untrusted, .trusted_fn = Local.untrusted };
    inline for (.{ "<nowiki>{{x|lang=en}}</nowiki>", "<!--{{x|lang=en}}-->", "<pre>{{x|lang=en}}</pre>", "<span title=\"{{x|lang=en}}\">plain</span>" }) |source| {
        try std.testing.expect(!sourceConfirmsLanguage(codes, source, "en"));
        try std.testing.expect(resolveSection(codes, .{ .heading = "Example alias", .source = source }) == null);
    }
    const active = "<nowiki>{{x|lang=fr}}</nowiki>{{x|lang=en}}";
    try std.testing.expect(sourceConfirmsLanguage(codes, active, "en"));
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "Example alias", .source = active }).?.code);
}

test "Arabic exact nested noun declarations classify only one untrusted L2 lemma subtree" {
    const a = std.testing.allocator;
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "en") or std.mem.eql(u8, value, "الإنجليزية")) return .{ .code = "en", .heading = "الإنجليزية" };
            if (std.mem.eql(u8, value, "de") or std.mem.eql(u8, value, "الألمانية")) return .{ .code = "de", .heading = "الألمانية" };
            if (std.mem.eql(u8, value, "aal")) return .{ .code = "aal", .heading = "Afade" };
            return null;
        }
        fn trusted(ctx: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "الإنجليزية") or std.mem.eql(u8, value, "الألمانية")) return resolve(ctx, value);
            return null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .resolve_fn = Local.resolve, .trusted_fn = Local.trusted, .strong_fn = Local.trusted };
    const english: language_source.Section = .{ .heading = "aal", .source = "== aal ==\n=== اسم إنجليزي ===\nآل - شجيرة من [[الهند]]\n" };
    const german: language_source.Section = .{ .heading = "der Aal", .source = "== der Aal ==\n=== اسم ألماني ===\nاسم مذكر\n=== المعنى ===\nثعبان الماء\n=== الجمع ===\ndie Aale\n" };
    try std.testing.expect(resolveSection(codes, english) != null);
    try std.testing.expectEqualStrings("en", resolveSection(codes, english).?.code);
    try std.testing.expectEqualStrings("en", boundaryLanguage(codes, english).?.code);
    try std.testing.expectEqualStrings("de", resolveSection(codes, german).?.code);
    inline for (.{
        "== lemma ==\n=== اسم مجهول ===\n# unknown",
        "== lemma ==\n=== اسم إنجليزي وألماني ===\n# multiple",
        "== lemma ==\n=== اسم إنجليزي ===\n# first\n=== اسم ألماني ===\n# second",
        "== lemma ==\n=== المعنى ===\n# first\n=== اسم إنجليزي ===\n# late",
        "== lemma ==\n<nowiki>\n=== اسم ألماني ===\n</nowiki>\n# literal",
        "== lemma ==\n<pre>\n=== اسم ألماني ===\n</pre>\n# literal",
        "== lemma ==\n<!--\n=== اسم ألماني ===\n-->\n# literal",
        "== lemma ==\n{{x|\n=== اسم ألماني ===\n}}\n# literal",
        "== lemma ==\n<span title=\"\n=== اسم ألماني ===\n\">visible</span>\n",
    }) |raw| try std.testing.expect(resolveSection(codes, .{ .heading = "lemma", .source = raw }) == null);
    try std.testing.expect(resolveSection(codes, .{ .heading = "aal", .source = "== aal ==\n=== اسم ===\n# no language" }) == null);
    try std.testing.expect(resolveSection(codes, .{ .heading = "اَلْمَعَانِي", .source = "== اَلْمَعَانِي ==\n# role-only" }) == null);
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "الإنجليزية", .source = "== الإنجليزية ==\n=== اسم ألماني ===\n# trusted outer owner" }).?.code);
    var other = codes;
    other.namespace_catalog = null;
    try std.testing.expect(resolveSection(other, english) == null);
    var non_arabic = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer non_arabic.deinit();
    other.namespace_catalog = &non_arabic;
    try std.testing.expect(resolveSection(other, english) == null);
    try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = "aal", .source = "== aal ==__NOEDITSECTION__\n=== اسم إنجليزي === __NOEDITSECTION__\n# controlled body" }).?.code);
    try std.testing.expect(resolveSection(codes, .{ .heading = "aal", .source = "== aal ==\n=== اسم إنجليزي === __UNKNOWN_SWITCH__\n# unknown suffix" }) == null);
}

test "ANG explicit English noun continuation does not steal genuine Nama" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Local = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "nmx"))
                return .{ .code = "nmx", .heading = "Nama" };
            if (std.mem.eql(u8, value, "Nīwenglisc") or std.mem.eql(u8, value, "en"))
                return .{ .code = "en", .heading = "Nīwenglisc" };
            return TestLanguages.resolve(null, value);
        }
        fn trusted(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "Nīwenglisc")) return resolve(null, value);
            return TestLanguages.trusted(null, value);
        }
        fn strong(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "Nīwenglisc")) return resolve(null, value);
            return TestLanguages.strong(null, value);
        }
    };
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tangwiktionary\n# dump-date\t20261001\n# content-language\tang\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tBysen\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tFlocc\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var other_namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer other_namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.get_fn = Local.get;
    codes.resolve_fn = Local.resolve;
    codes.trusted_fn = Local.trusted;
    codes.strong_fn = Local.strong;
    codes.namespace_catalog = &namespaces;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ang-nama", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact raw constitution rev54826; the representative expanded fixture
    // retains its observed visible Lua error, noun body and typed link. The
    // ownership repair must not claim to repair the absent Module:spraeca.
    const constitution_raw = "=={{sprǣc|en}}==\n===Rihtstefn===\n* IPA: /ˌkɒn.stɪˈtjuː.ʃ(ə)n/\n===Wordstǣr===\nOf {{ier|en|enm|constitucioun}}\n==Nama==\n{{en-nama}} (mnf. constitutions)\n# [[gesetnes]]\n====Wendunga====\nEnglisc: [[gesetnes]]";
    const error_text = "Lua error in Module:en-hēafodword: ModuleNotFound";
    const constitution_expanded = "==Nīwenglisc==\n===Rihtstefn===\n* IPA: /ˌkɒn.stɪˈtjuː.ʃ(ə)n/\n===Wordstǣr===\nOf constitucioun\n==Nama==\n<strong class=\"error scribunto-error\">" ++ error_text ++ "</strong> (mnf. constitutions)\n# [[gesetnes]]\n====Wendunga====\nEnglisc: [[gesetnes]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "constitution", constitution_expanded, constitution_raw, null);
    const prefix_raw = "=={{sprǣc|en}}==\n# EN_PREFIX\n";
    const prefix_expanded = "==Nīwenglisc==\n# EN_PREFIX\n";
    const cases = .{
        .{ "genuine-nama", "==Nama==\n# NAMA_BODY\n", "==Nama==\n# NAMA_BODY\n" },
        .{ "missing-cue", prefix_raw ++ "==Nama==\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "wrong-cue", prefix_raw ++ "==Nama==\n{{en-verb}}\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "protected-cue", prefix_raw ++ "==Nama==\n<nowiki>{{en-nama}}</nowiki>\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n<nowiki>{{en-nama}}</nowiki>\n# NAMA_BODY\n" },
        .{ "comment-cue", prefix_raw ++ "==Nama==\n<!--{{en-nama}}-->\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "nested-cue", prefix_raw ++ "==Nama==\n{{quote|{{en-nama}}}}\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "current-nama", "=={{sprǣc|nmx}}==\n# NAMA_PREFIX\n==Nama==\n{{en-nama}}\n# NAMA_BODY\n", "==Nama==\n# NAMA_PREFIX\n==Nama==\n# NAMA_BODY\n" },
        .{ "explicit-nama", prefix_raw ++ "=={{sprǣc|nmx}}==\n{{en-nama}}\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "intervening-owner", prefix_raw ++ "==French==\n# FR_PREFIX\n==Nama==\n{{en-nama}}\n# NAMA_BODY\n", prefix_expanded ++ "==French==\n# FR_PREFIX\n==Nama==\n# NAMA_BODY\n" },
        .{ "unaligned", prefix_raw ++ "==Nama==\n{{en-nama}}\n# NAMA_BODY\n", prefix_expanded ++ "==French==\n# FR_PREFIX\n==Nama==\n# NAMA_BODY\n" },
        .{ "later-cue", prefix_raw ++ "==Nama==\n# NAMA_BODY\n{{en-nama}}\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
    };
    inline for (cases) |row|
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row[0], row[2], row[1], null);
    var other_codes = codes;
    other_codes.namespace_catalog = &other_namespaces;
    writer.language_codes = other_codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "other-edition", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n", prefix_raw ++ "==Nama==\n{{en-nama}}\n# NAMA_BODY\n", null);
    writer.language_codes = codes;
    _ = try writer.finish(codes);

    var english_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Nīwenglisc"));
    defer english_map.deinit();
    const english = try blob_format.inspect(english_map.bytes);
    const english_metadata = try english.languageMetadata();
    try std.testing.expectEqualStrings("en", english_metadata.code);
    var english_index = try english.buildTrustedIndexAlloc(a);
    defer english_index.deinit(a);
    const record = (try english_index.find("constitution")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, english_metadata);
    var visible: std.ArrayList(u8) = .empty;
    var noun_heading = false;
    var links: usize = 0;
    for (decoded.entry.sections) |section| {
        noun_heading = noun_heading or std.mem.eql(u8, section.title, "Nama");
        for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.target, "gesetnes")) links += 1;
        };
    }
    try std.testing.expect(noun_heading);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, error_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "constitutions") != null);
    try std.testing.expectEqual(@as(usize, 2), links);
    var nama_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Nama"));
    defer nama_map.deinit();
    const nama = try blob_format.inspect(nama_map.bytes);
    try std.testing.expectEqualStrings("nmx", (try nama.languageMetadata()).code);
    var nama_index = try nama.buildTrustedIndexAlloc(a);
    defer nama_index.deinit(a);
    try std.testing.expect((try nama_index.find("constitution")) == null);
    inline for (cases) |row| {
        const native_record = (try nama_index.find(row[0])).?;
        try std.testing.expect(std.mem.indexOf(u8, native_record.payload, "NAMA_BODY") != null);
        if (try english_index.find(row[0])) |foreign_record|
            try std.testing.expect(std.mem.indexOf(u8, foreign_record.payload, "NAMA_BODY") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, (try nama_index.find("other-edition")).?.payload, "NAMA_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try english_index.find("other-edition")).?.payload, "NAMA_BODY") == null);
}

test "single resolved language preserves structured prefix without ambiguous attribution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tملف\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn resolve(ctx: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "عربية") or std.mem.eql(u8, value, "عَرَبِيَّة") or std.mem.eql(u8, value, "العربية")) return .{ .code = "ar", .heading = "العربية" };
            return TestLanguages.resolve(ctx, value);
        }
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn entry(allocator: std.mem.Allocator, root_path: []const u8, language: []const u8, title: []const u8) !blobs.presentation_types.Entry {
            var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(allocator, root_path, language));
            defer mapped.deinit();
            const owned_bytes = try allocator.dupe(u8, mapped.bytes);
            const blob = try blob_format.inspect(owned_bytes);
            var index = try blob.buildTrustedIndexAlloc(allocator);
            defer index.deinit(allocator);
            const found = try index.find(title);
            try std.testing.expect(found != null);
            const rec = found.?;
            return (try blobs.presentation_codec.decodeAlloc(allocator, rec.payload, rec.title, .language, try blob.languageMetadata())).entry;
        }
        fn text(allocator: std.mem.Allocator, entry_value: blobs.presentation_types.Entry) ![]const u8 {
            var result: std.ArrayList(u8) = .empty;
            for (entry_value.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                try result.appendSlice(allocator, span.text);
                try result.appendSlice(allocator, span.trail);
            };
            return result.items;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root_path);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact retained Qatar revision1430987; raw equals rendered (no templates).
    const qatar = "قطار جمعه قطارات.\n\n== [[عَرَبِيَّة]] ==\nالقطار هو المركبة المعروفة التي تسير على سكة من الحديد لنقل البضائع أو المسافرين.\n\n[[تصنيف:ق ط ر]]\n[[تصنيف:فِعَال]]\n[[تصنيف:وسائل نقل]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "قِطَار", qatar, qatar, null);
    const structured = "<b>bold prefix</b>\nsecond line\n\n* prefix item\n==English==\n# first body\n==English==\n# repeated body\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "structured", structured, structured, null);
    inline for (.{
        .{ "multilingual", "unscoped prefix\n==English==\n# english\n==French==\n# french\n" },
        .{ "unknown-group", "unscoped prefix\n==English==\n# english\n==لغة مجهولة==\n# unknown\n" },
        .{ "inherited-unknown", "unscoped prefix\n==English==\n# english\n==Unknown topic==\n# unknown\n" },
        .{ "pending-unknown", "unscoped prefix\n==Unknown topic==\n# unknown\n==English==\n# english\n" },
        .{ "only-unknown", "unscoped prefix\n==[[Unknown language]]==\n# unknown\n" },
    }) |row| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row[0], row[1], row[1], null);
    _ = try writer.finish(codes);
    std.debug.print("QATAR_STAGE actual prefix\n", .{});
    const qatar_entry = try Local.entry(a, root_path, "العربية", "قِطَار");
    try std.testing.expectEqualStrings("ar", qatar_entry.language_code);
    const qatar_text = try Local.text(a, qatar_entry);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, qatar_text, "قطار جمعه قطارات."));
    try std.testing.expect(std.mem.indexOf(u8, qatar_text, "القطار هو المركبة المعروفة التي تسير على سكة من الحديد لنقل البضائع أو المسافرين.") != null);
    std.debug.print("QATAR_STAGE structured prefix\n", .{});
    const structured_entry = try Local.entry(a, root_path, "English", "structured");
    const structured_text = try Local.text(a, structured_entry);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, structured_text, "bold prefix"));
    inline for (.{ "second line", "first body", "repeated body" }) |value| try std.testing.expect(std.mem.indexOf(u8, structured_text, value) != null);
    var paragraph_prefix = false;
    var bold_prefix = false;
    var list_prefix = false;
    for (structured_entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.text, "bold prefix") and span.bold) {
            bold_prefix = true;
            if (block.kind == .paragraph) paragraph_prefix = true;
        }
        if (std.mem.eql(u8, span.text, "prefix item") and std.mem.eql(u8, block.list_path, "*")) list_prefix = true;
    };
    std.debug.print("QATAR_STRUCTURE paragraph={any} bold={any} list={any}\n", .{ paragraph_prefix, bold_prefix, list_prefix });
    try std.testing.expect(paragraph_prefix and bold_prefix and list_prefix);
    inline for (.{ .{ "English", "multilingual" }, .{ "French", "multilingual" }, .{ "English", "unknown-group" }, .{ "Unclassified", "unknown-group" }, .{ "English", "inherited-unknown" }, .{ "English", "pending-unknown" } }) |row| {
        std.debug.print("QATAR_NEGATIVE owner={s} title={s}\n", .{ row[0], row[1] });
        const entry_value = try Local.entry(a, root_path, row[0], row[1]);
        try std.testing.expect(std.mem.indexOf(u8, try Local.text(a, entry_value), "unscoped prefix") == null);
    }
    // A page without any resolved boundary retains its whole source as Unclassified.
    std.debug.print("QATAR_STAGE whole-source unknown preservation\n", .{});
    const unknown_entry = try Local.entry(a, root_path, "Unclassified", "only-unknown");
    try std.testing.expectEqualStrings("", unknown_entry.language_code);
    const unknown_text = try Local.text(a, unknown_entry);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, unknown_text, "unscoped prefix"));
    try std.testing.expect(std.mem.indexOf(u8, unknown_text, "unknown") != null);
}

test "expanded behavior-prefix page retains English bucket and typed lexical blob record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const Local = struct {
        fn get(_: ?*const anyopaque, heading: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, heading, "English")) "en" else null;
        }
        fn strong(_: ?*const anyopaque, heading: []const u8) ?ResolvedLanguage {
            return if (std.mem.eql(u8, heading, "English")) .{ .code = "en", .heading = "English" } else null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .strong_fn = Local.strong };
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact bytes asserted by runtime's expanded authored-prefix regression.
    const expanded = "__NOEDITSECTION__==English==\n__NOEDITSECTION__===Noun===\n__NOEDITSECTION__# [[cat|lexical sense]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "entry", expanded, "<!--hidden-->" ++ expanded, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, "English"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("en", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("entry")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, "entry", .language, metadata);
    var definitions: usize = 0;
    var linked = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
        if (std.mem.eql(u8, block_value.list_path, "#")) {
            definitions += 1;
            try std.testing.expect(block_value.kind == .definition);
            for (block_value.spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "cat") and std.mem.eql(u8, span.text, "lexical sense")) {
                linked = true;
            };
        }
    };
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expect(linked);
}

test "classification control projection follows the selected edition and protected source" {
    const a = std.testing.allocator;
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tLêer\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const namespace_hex = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const behavior_raw = try std.fmt.allocPrint(a, "# wikidict-behavior-switches-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n# namespace-registry-sha256\t{s}\nnoeditsection\t0\t__GEENNUWEAFDELING__\nindex\t1\t__INDEX__\n", .{namespace_hex});
    defer a.free(behavior_raw);
    var behavior = try @import("namespace_registry").behavior_switches.Registry.init(a, behavior_raw, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256);
    defer behavior.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    codes.behavior_switches = &behavior;
    inline for (.{ "__GEENNUWEAFDELING__English", "En__geennuweafdeling__glish", "English__INDEX__" }) |value| {
        const projected = (try classificationControlHeadingAlloc(a, codes, value)).?;
        defer a.free(projected);
        try std.testing.expectEqualStrings("English", projected);
    }
    inline for (.{ "__index__English", "__NOTOC__English", "__UNKNOWN__English", "<nowiki>__GEENNUWEAFDELING__</nowiki>English", "<pre>__GEENNUWEAFDELING__</pre>English", "<span title=\"__GEENNUWEAFDELING__\">English</span>", "&#95;&#95;GEENNUWEAFDELING&#95;&#95;English" }) |value|
        try std.testing.expect(try classificationControlHeadingAlloc(a, codes, value) == null);
    codes.behavior_switches = null;
    try std.testing.expect(try classificationControlHeadingAlloc(a, codes, "__GEENNUWEAFDELING__English") == null);
    const builtin = (try classificationControlHeadingAlloc(a, codes, "En__NOGALLERY__glish")).?;
    defer a.free(builtin);
    try std.testing.expectEqualStrings("English", builtin);
}

test "active controls inside language headings preserve real blob ownership and mixed depth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    const first = "==__NOTOC__English==\n# [[cat|first lexical sense]]\n";
    const second = "==En__NOGALLERY__glish==\n# [[cat|second lexical sense]]\n";
    const mixed = "==French==\n# [[chat|French sense]]\n=En__NOGALLERY__glish=\n# [[cat|English sense]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "first", first, first, null, &.{});
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "second", second, second, null, &.{});
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "mixed", mixed, mixed, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    inline for (.{ .{ "English", "en", "first", "first lexical sense", "cat" }, .{ "English", "en", "second", "second lexical sense", "cat" }, .{ "English", "en", "mixed", "English sense", "cat" }, .{ "French", "fr", "mixed", "French sense", "chat" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(row[1], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row[2])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var definitions: usize = 0;
        var linked: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
            if (std.mem.eql(u8, block_value.list_path, "#")) {
                definitions += 1;
                try std.testing.expect(block_value.kind == .definition);
                for (block_value.spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, row[4]) and std.mem.eql(u8, span.text, row[3])) {
                    linked += 1;
                };
            }
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), linked);
    }
}

test "protected and entity authored heading controls cannot manufacture an English owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    const protected = "==<nowiki>__NOTOC__</nowiki>English==\n# [[cat|retained sense]]\n";
    const entities = "==&#95;&#95;NOTOC&#95;&#95;English==\n# [[cat|retained sense]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "protected", protected, protected, null, &.{});
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "entities", entities, entities, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 2), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, "Unclassified"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    inline for (.{ "protected", "entities" }) |title| {
        const record = (try index.find(title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var linked: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "cat") and std.mem.eql(u8, span.text, "retained sense")) linked += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), linked);
    }
}

test "protected Sprache headings retain content without inventing a language owner" {
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
    const rows = .{
        .{ "protected", "Unclassified", "", "==Lemma <nowiki>{{Sprache|Deutsch}}</nowiki>==\n# [[cat|retained sense]]\n", "==Lemma <nowiki>{{Sprache|Deutsch}}</nowiki>==\n# [[cat|retained sense]]\n" },
        .{ "comment", "Unclassified", "", "==Lemma <!--{{Sprache|Deutsch}}-->==\n# [[cat|retained sense]]\n", "==Lemma ==\n# [[cat|retained sense]]\n" },
        .{ "attribute", "Unclassified", "", "==Lemma <span title=\"{{Sprache|Deutsch}}\">literal</span>==\n# [[cat|retained sense]]\n", "==Lemma <span title=\"{{Sprache|Deutsch}}\">literal</span>==\n# [[cat|retained sense]]\n" },
        .{ "nested-hidden", "Unclassified", "", "==Lemma ({{unknown|{{Sprache|Deutsch}}}})==\n# [[cat|retained sense]]\n", "==Lemma==\n# [[cat|retained sense]]\n" },
        .{ "protected-argument", "Unclassified", "", "==Lemma ({{unknown|<nowiki>x|Deutsch|y</nowiki>}})==\n# [[cat|retained sense]]\n", "==Lemma <nowiki>x|Deutsch|y</nowiki>==\n# [[cat|retained sense]]\n" },
        .{ "markup-language-argument", "Unclassified", "", "==Lemma ({{Sprache|Deutsch<nowiki>|French</nowiki>}})==\n# [[cat|retained sense]]\n", "==Lemma (Deutsch<nowiki>|French</nowiki>)==\n# [[cat|retained sense]]\n" },
        .{ "markup-then-active", "Deutsch", "de", "==Lemma ({{Sprache|Deutsch<nowiki>|French</nowiki>}}) ({{Sprache|Deutsch}})==\n# [[cat|retained sense]]\n", "==Lemma (Deutsch<nowiki>|French</nowiki>) ([[:Template:Sprache]])==\n# [[cat|retained sense]]\n" },
        .{ "active", "Deutsch", "de", "==Lemma ({{Sprache|Deutsch}})==\n# [[cat|retained sense]]\n", "==Lemma ([[:Template:Sprache]])==\n# [[cat|retained sense]]\n" },
        .{ "later-active", "Deutsch", "de", "==Lemma <nowiki>{{Sprache|French}}</nowiki> ({{Sprache|Deutsch}})==\n# [[cat|retained sense]]\n", "==Lemma <nowiki>{{Sprache|French}}</nowiki> ([[:Template:Sprache]])==\n# [[cat|retained sense]]\n" },
    };
    inline for (rows) |row|
        try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, row[0], row[4], row[3], null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 9), stats.language_records);
    try std.testing.expectEqual(@as(usize, 6), stats.fallback_pages);
    inline for (rows) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[1]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(row[2], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row[0])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var linked: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "cat") and std.mem.eql(u8, span.text, "retained sense")) linked += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), linked);
    }
}

test "registered language-name punctuation precedes legacy wrapper trimming" {
    const Local = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            // Exact selected English registry rows, not new aliases.
            inline for (.{ .{ "Urak Lawoi'", "urk" }, .{ "K'iche'", "quc" }, .{ "Yanesha'", "ame" }, .{ "Fe'fe'", "fmp" }, .{ "English", "en" } }) |row| {
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]))
                    return .{ .code = row[1], .heading = row[0] };
            }
            return null;
        }
        fn untrusted(_: ?*const anyopaque, _: []const u8) ?ResolvedLanguage {
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .strong_fn = Local.resolve };
    inline for (.{ .{ "Urak Lawoi'", "urk" }, .{ "K'iche'", "quc" }, .{ "Yanesha'", "ame" }, .{ "Fe'fe'", "fmp" } }) |row| {
        try std.testing.expectEqualStrings(row[1], resolveTrimmed(codes, " \t" ++ row[0] ++ "\n").?.code);
        const section: language_source.Section = .{ .heading = row[0], .source = "" };
        try std.testing.expectEqualStrings(row[1], resolveSection(codes, section).?.code);
        try std.testing.expectEqualStrings(row[1], boundaryLanguage(codes, section).?.code);
        try std.testing.expectEqualStrings(row[1], resolveTemplateCandidates(codes, "{{language|" ++ row[0] ++ "}}").?.code);
        try std.testing.expect(valueConfirmsLanguage(codes, row[0], row[1]));
        try std.testing.expect(!valueConfirmsLanguage(codes, row[0], "en"));
    }
    inline for (.{ " English ", "''English''", "'''English'''", "\"English\"", "[[English]]" }) |heading| {
        try std.testing.expectEqualStrings("en", resolveTrimmed(codes, heading).?.code);
        try std.testing.expectEqualStrings("en", resolveSection(codes, .{ .heading = heading, .source = "" }).?.code);
        try std.testing.expectEqualStrings("en", boundaryLanguage(codes, .{ .heading = heading, .source = "" }).?.code);
    }
    try std.testing.expect(resolveSection(codes, .{ .heading = "Urak Lawoi", .source = "" }) == null);
    try std.testing.expect(resolveSection(codes, .{ .heading = "Unknown'", .source = "" }) == null);
    const weak: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.untrusted };
    try std.testing.expect(resolveSection(weak, .{ .heading = "Urak Lawoi'", .source = "" }) == null);
    try std.testing.expectEqualStrings("urk", resolveSection(weak, .{ .heading = "Urak Lawoi'", .source = "{{head|Urak Lawoi'|verb}}" }).?.code);
    try std.testing.expect(resolveSection(weak, .{ .heading = "Urak Lawoi'", .source = "<nowiki>{{head|Urak Lawoi'|verb}}</nowiki>" }) == null);
}

test "Urak Lawoi apostrophe preserves real Writer ownership and lexical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Local = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Urak Lawoi'") or std.mem.eql(u8, value, "urk"))
                return .{ .code = "urk", .heading = "Urak Lawoi'" };
            if (std.mem.eql(u8, value, "English") or std.mem.eql(u8, value, "en"))
                return .{ .code = "en", .heading = "English" };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .strong_fn = Local.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Verbatim heading/verb excerpt: enwiktionary page10504101, revision81906835.
    // Archived full source SHA256 89f8df3f95f6aa202dbe92ca71b59e67fce6e882da423184946acc6ccf9ec12e.
    // The expanded fixture removes the head template; it is not a native expansion claim.
    const raw = "==Urak Lawoi'==\n===Verb===\n{{head|urk|verb|tr=jahëq}}\n# to [[sew]]\n";
    const expanded = "==Urak Lawoi'==\n===Verb===\n# to [[sew]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "ยฺาเฮะ", expanded, raw, null, &.{});
    const wrapped = "==''English''==\n# [[thread|English wrapper sense]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "wrapped-English", wrapped, wrapped, null, &.{});
    const mixed = "==English==\n# [[thread|English mixed sense]]\n=Urak Lawoi'=\n===Verb===\n# to [[sew]]\n";
    // A differently deep exact registered name must form a boundary before
    // Writer groups lexical bodies; the nested Verb is not a language.
    const markers: LanguageMarkers = .{ .codes = &codes };
    var boundaries = languageSections(mixed, &markers);
    try std.testing.expectEqualStrings("English", boundaries.next().?.heading);
    try std.testing.expectEqualStrings("Urak Lawoi'", boundaries.next().?.heading);
    try std.testing.expect(boundaries.next() == null);
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "mixed", mixed, mixed, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    inline for (.{
        .{ "ยฺาเฮะ", "Urak Lawoi'", "urk", "sew", "sew" },
        .{ "wrapped-English", "English", "en", "thread", "English wrapper sense" },
        .{ "mixed", "English", "en", "thread", "English mixed sense" },
        .{ "mixed", "Urak Lawoi'", "urk", "sew", "sew" },
    }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[1]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(row[2], metadata.code);
        try std.testing.expectEqualStrings(row[1], metadata.heading);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row[0])).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(row[2], decoded.entry.language_code);
        var definitions: usize = 0;
        var linked: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
            if (std.mem.eql(u8, block_value.list_path, "#")) {
                definitions += 1;
                try std.testing.expect(block_value.kind == .definition);
                for (block_value.spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, row[3]) and std.mem.eql(u8, span.text, row[4])) {
                    linked += 1;
                };
            }
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), linked);
    }
}

test "page-body TOC order crosses preamble headings and language owner regrouping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    const sources = [_][]const u8{
        "__TOC__\n==English==\n# English body\n==French==\n# ISBN 97803__TOC__06406157\n",
        "==English==\n===__TOC__Noun===\n# English body\n==French==\n# ISBN 97803__TOC__06406157\n",
    };
    for (sources, 0..) |source, i| {
        const title = if (i == 0) "preamble" else "heading";
        try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, title, source, source, null, &.{});
    }
    const rule_cases = [_]struct { title: []const u8, source: []const u8, visible: []const u8, rules: usize }{
        .{ .title = "rule-created", .source = "__TOC__----[[cat]]", .visible = "----cat", .rules = 0 },
        .{ .title = "rule-joined", .source = "--__TOC__--[[cat]]", .visible = "----cat", .rules = 0 },
        .{ .title = "rule-extended", .source = "----__TOC__-[[cat]]", .visible = "-cat", .rules = 1 },
        .{ .title = "rule-longer", .source = "------__TOC__--[[cat]]", .visible = "--cat", .rules = 1 },
        .{ .title = "rule-adjacent", .source = "__TOC____TOC__----[[cat]]", .visible = "----cat", .rules = 0 },
    };
    for (rule_cases) |case| {
        const source = try std.fmt.allocPrint(a, "__TOC__\n==English==\n# English body\n==French==\n{s}\n# ISBN 97803__TOC__06406157\n", .{case.source});
        try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, case.title, source, source, null, &.{});
    }
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4 + 2 * rule_cases.len), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, "French"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("fr", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    for ([_][]const u8{ "preamble", "heading" }) |title| {
        const record = (try index.find(title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "Special:BookSources/9780306406157")) links += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), links);
    }
    for (rule_cases) |case| {
        const record = (try index.find(case.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var visible: std.ArrayList(u8) = .empty;
        var rules: usize = 0;
        var lexical_links: usize = 0;
        var isbn_links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
            if (block_value.kind == .rule) rules += 1;
            for (block_value.spans) |span| {
                if (block_value.kind == .paragraph) try visible.appendSlice(a, span.text);
                try std.testing.expect(std.mem.indexOf(u8, span.text, "__TOC__") == null);
                if (span.kind != .link) continue;
                if (std.mem.eql(u8, span.target, "cat")) {
                    lexical_links += 1;
                    try std.testing.expectEqualStrings("cat", span.text);
                } else if (std.mem.eql(u8, span.target, "Special:BookSources/9780306406157")) {
                    isbn_links += 1;
                } else try std.testing.expect(false);
            }
        };
        try std.testing.expectEqual(case.rules, rules);
        try std.testing.expectEqualStrings(case.visible, std.mem.trim(u8, visible.items, " \t\r\n"));
        try std.testing.expectEqual(@as(usize, 1), lexical_links);
        try std.testing.expectEqual(@as(usize, 1), isbn_links);
    }
}

test "split heading controls preserve actual owner publication and first TOC boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    const codes = TestLanguages.codes();
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    const positives = [_]struct { title: []const u8, source: []const u8 }{
        .{ .title = "split-open", .source = "==English==\n# [[cat|English sense]]\n=__NOEDITSECTION__=French==\n# [[chat|French sense]]\n" },
        .{ .title = "split-close", .source = "==English==\n# [[cat|English sense]]\n==French=__NOGALLERY__=\n# [[chat|French sense]]\n" },
        .{ .title = "split-both", .source = "==English==\n# [[cat|English sense]]\n=__NOEDITSECTION__=French=__NOTOC__=\n# [[chat|French sense]]\n" },
        .{ .title = "later-toc", .source = "==English==\n__TOC__\n# [[cat|English sense]]\n=__TOC__=French=__TOC__=\n# [[chat|French sense]]\n" },
    };
    for (positives) |case| try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.source, null, &.{});
    const negatives = [_]struct { title: []const u8, source: []const u8 }{
        .{ .title = "first-toc", .source = "==English==\n# [[cat|English sense]]\n__TOC__==French==\n# [[chat|literal French sense]]\n" },
        .{ .title = "protected-split", .source = "==English==\n# [[cat|English sense]]\n=<nowiki>__NOEDITSECTION__</nowiki>=French==\n# [[chat|literal French sense]]\n" },
        .{ .title = "space-split", .source = "==English==\n# [[cat|English sense]]\n=__NOEDITSECTION__ =French==\n# [[chat|literal French sense]]\n" },
    };
    for (negatives) |case| try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.source, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, positives.len * 2 + negatives.len), stats.language_records);
    inline for (.{ .{ "English", "cat", "English sense", "chat" }, .{ "French", "chat", "French sense", "cat" } }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, owner[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for (positives) |case| {
            const record = (try index.find(case.title)).?;
            const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            var matched: usize = 0;
            for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
                if (span.kind == .link and std.mem.eql(u8, span.target, owner[1]) and std.mem.eql(u8, span.text, owner[2])) matched += 1;
                try std.testing.expect(span.kind != .link or !std.mem.eql(u8, span.target, owner[3]));
            };
            try std.testing.expectEqual(@as(usize, 1), matched);
        }
        for (negatives) |case| {
            const record = try index.find(case.title);
            if (std.mem.eql(u8, owner[0], "French")) {
                try std.testing.expect(record == null);
            } else try std.testing.expect(record != null);
        }
    }
}
