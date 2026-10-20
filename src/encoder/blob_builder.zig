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
    boundary_fn: ?*const fn (?*const anyopaque, []const u8) bool = null,
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

    pub fn isLanguageBoundary(self: LanguageCodes, heading: []const u8) bool {
        const boundary_fn = self.boundary_fn orelse return false;
        return boundary_fn(self.ctx, heading);
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
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        errdefer file.close(io);
        return .{
            .file = file,
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

        const owned_root = try allocator.dupe(u8, spool_root);
        errdefer allocator.free(owned_root);
        const fixed_names = [_][]const u8{ "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss", "supplemental", "aliases" };
        var fixed: [fixed_names.len]SpoolFile = undefined;
        var fixed_built: usize = 0;
        errdefer while (fixed_built != 0) {
            fixed_built -= 1;
            fixed[fixed_built].close(io);
            fixed[fixed_built].deinitPath(allocator);
        };
        for (fixed_names, 0..) |name, idx| {
            fixed[idx] = try initFixed(io, allocator, spool_root, name);
            fixed_built += 1;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .root = owned_root,
            .language = language,
            .thesaurus = fixed[0],
            .citations = fixed[1],
            .reconstruction = fixed[2],
            .rhymes = fixed[3],
            .sign_gloss = fixed[4],
            .supplemental = fixed[5],
            .aliases = fixed[6],
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
    // A section fragment controls navigation, not the language named by the page.
    if (std.mem.indexOfScalar(u8, target, '#')) |fragment|
        target = std.mem.trim(u8, target[0..fragment], " \t\r\n");
    if (target.len == 0) return null;
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

// A mixed plain-text/wikilink AR heading can spell an exact registered
// language (e.g. ال[[عربية]]). Resolve that complete visible spelling, and
// require every link target to independently name the same trusted owner.
// No template expansion, entity decoding, category or script inference.
fn resolveMixedArabicLinkedHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar") or value.len > 4096) return null;
    const heading = std.mem.trim(u8, value, " \t");
    var visible: [4096]u8 = undefined;
    var length: usize = 0;
    var cursor: usize = 0;
    var linked_owner: ?ResolvedLanguage = null;
    var plain = false;
    while (cursor < heading.len) {
        if (std.mem.startsWith(u8, heading[cursor..], "[[")) {
            const pair = blobs.wikitext_syntax.balanced(heading, cursor) orelse return null;
            const body = heading[cursor + 2 .. pair.inner_end];
            if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return null;
            const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
            if (pipe < body.len and std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return null;
            const target = std.mem.trim(u8, body[0..pipe], " \t");
            const label = if (pipe < body.len) body[pipe + 1 ..] else target;
            if (target.len == 0 or label.len == 0) return null;
            const owner = codes.resolveStrong(target) orelse codes.resolveTrusted(target) orelse return null;
            if (linked_owner) |previous| if (!std.mem.eql(u8, previous.code, owner.code)) return null;
            linked_owner = owner;
            @memcpy(visible[length .. length + label.len], label);
            length += label.len;
            cursor = pair.end;
        } else {
            const byte = heading[cursor];
            if (std.mem.indexOfScalar(u8, "[]{}<>|=\r\n'", byte) != null) return null;
            if (!std.ascii.isWhitespace(byte)) plain = true;
            visible[length] = byte;
            length += 1;
            cursor += 1;
        }
    }
    if (!plain or linked_owner == null) return null;
    const whole = std.mem.trim(u8, visible[0..length], " \t");
    const owner = codes.resolveStrong(whole) orelse codes.resolveTrusted(whole) orelse return null;
    return if (std.mem.eql(u8, owner.code, linked_owner.?.code)) owner else null;
}

// Frozen AN language templates emit this complete toc declaration. Resolve the
// banner itself; raw support headings can legitimately change boundary counts.
const AnBannerDeclaration = struct { target: []const u8, label: []const u8, suffix: []const u8 };

fn anBannerDeclaration(codes: LanguageCodes, value: []const u8) ?AnBannerDeclaration {
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
    rest = std.mem.trimStart(u8, rest[link.end..], " \t");
    if (!std.mem.startsWith(u8, rest, "'''''")) return null;
    rest = std.mem.trimStart(u8, rest[5..], " \t");
    if (rest.len == 0) return .{ .target = target, .label = label, .suffix = "" };
    if (rest.len < 21 or !std.mem.startsWith(u8, rest, "<small>- ''") or !std.mem.endsWith(u8, rest, "''</small>")) return null;
    return .{ .target = target, .label = label, .suffix = rest[11 .. rest.len - 10] };
}

fn resolveAnBannerHeading(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const declaration = anBannerDeclaration(codes, value) orelse return null;
    const language = codes.resolve(declaration.label) orelse return null;
    const target_language = codes.resolve(declaration.target) orelse return null;
    // A complete suffixless declaration is independently authored in AN
    // escoltar (page2904/rev29039). The exact target/label must agree; no
    // trailing text, second link or weak category inference can provide it.
    if (declaration.suffix.len == 0) {
        if (!std.mem.eql(u8, declaration.target, declaration.label) or
            !std.mem.eql(u8, language.code, target_language.code)) return null;
        return language;
    }
    const suffix_language = codes.resolve(declaration.suffix) orelse return null;
    if (!std.mem.eql(u8, language.code, target_language.code) or
        !std.mem.eql(u8, language.code, suffix_language.code)) return null;
    return language;
}

// These thirteen complete AN banners are independently captured declarations.
// Their local names are not necessarily registry aliases; the aligned raw
// hyphen code and exact banner together supply the canonical identity. POS
// abbreviations, arbitrary banners and another edition cannot borrow it.
fn corroboratedAnHyphenMarker(codes: LanguageCodes, raw: language_source.Section, rendered: language_source.Section) bool {
    if (!raw.hyphen_marker) return false;
    const declaration = anBannerDeclaration(codes, rendered.heading) orelse return false;
    const declared = codes.resolve(raw.heading) orelse return false;
    if (!std.mem.eql(u8, declared.code, raw.heading)) return false;
    const rows = [_]struct { code: []const u8, target: []const u8, label: []const u8, suffix: []const u8 }{
        .{ .code = "pms", .target = "Piemontés", .label = "Piemontés", .suffix = "Piemontèis" },
        .{ .code = "lad", .target = "Chodigoespañol", .label = "Chodigoespañol", .suffix = "Djudeoespanyol" },
        .{ .code = "fur", .target = "Friulán", .label = "Friulán", .suffix = "Furlan" },
        .{ .code = "ms", .target = "Malayo", .label = "Malayo", .suffix = "Bahasa Melayu بهاس ملايو" },
        .{ .code = "zh", .target = "Chinés", .label = "Chinés", .suffix = "中文" },
        .{ .code = "th", .target = "Tailandés", .label = "Tailandés", .suffix = "Tailandés" },
        .{ .code = "bg", .target = "Bulgaro", .label = "Bulgaro", .suffix = "Български" },
        .{ .code = "lt", .target = "Lituán", .label = "Lituán", .suffix = "Lietuvių kalba" },
        .{ .code = "tk", .target = "Turquemán", .label = "Turquemán", .suffix = "Türkmençe" },
        .{ .code = "mul", .target = "internacional", .label = "Internacional", .suffix = "" },
        .{ .code = "haw", .target = "Hawayán", .label = "Hawayán", .suffix = "‘Ōlelo Hawai‘i" },
        .{ .code = "rap", .target = "Rapanui", .label = "Rapa nui", .suffix = "Vananga Rapa Nui" },
        .{ .code = "sw", .target = "Swahili", .label = "Swahili", .suffix = "Kiswahili" },
    };
    for (rows) |row| {
        if (std.mem.eql(u8, raw.heading, row.code) and
            std.mem.eql(u8, declaration.target, row.target) and
            std.mem.eql(u8, declaration.label, row.label) and
            std.mem.eql(u8, declaration.suffix, row.suffix)) return true;
    }
    return false;
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
    for ([_][]const u8{ "لغة", "اللغة" }) |prefix| {
        if (!std.mem.startsWith(u8, heading, prefix) or heading.len <= prefix.len or
            (heading[prefix.len] != ' ' and heading[prefix.len] != '\t')) continue;
        const label = std.mem.trim(u8, heading[prefix.len..], " \t");
        if (label.len == 0 or std.mem.indexOfAny(u8, label, "[]{}<>|=\r\n") != null) return null;
        return codes.resolveStrong(label) orelse codes.resolveTrusted(label);
    }
    return null;
}

// The two captured AR Norwegian wrappers declare a variant after the umbrella
// language. Parse only their complete linked declaration; never infer an owner
// from an arbitrary parenthesis or from a bare Norwegian heading.
// Complete source-authored Arabic declaration forms used by chrome and
// d’Alembertian. Keep recognition separate from resolution so an unknown or
// conflicting declaration remains a boundary instead of borrowing an owner.
const ArabicLinkedOwner = struct { target: []const u8, label: []const u8, phrase: bool };
fn arabicLinkedOwner(codes: LanguageCodes, value: []const u8) ?ArabicLinkedOwner {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar") or value.len > 4096) return null;
    const Link = struct {
        fn take(rest: *[]const u8) ?struct { target: []const u8, label: []const u8 } {
            if (!std.mem.startsWith(u8, rest.*, "[[")) return null;
            const close = std.mem.indexOf(u8, rest.*, "]]") orelse return null;
            const body = rest.*[2..close];
            if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return null;
            const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
            if (pipe < body.len and std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return null;
            const target = std.mem.trim(u8, body[0..pipe], " \t");
            const label = std.mem.trim(u8, if (pipe < body.len) body[pipe + 1 ..] else target, " \t");
            if (target.len == 0 or label.len == 0) return null;
            rest.* = std.mem.trimStart(u8, rest.*[close + 2 ..], " \t");
            return .{ .target = target, .label = label };
        }
    };
    var rest = std.mem.trim(u8, value, " \t\r\n");
    const first = Link.take(&rest) orelse return null;
    var target_buffer: [256]u8 = undefined;
    var label_buffer: [512]u8 = undefined;
    const first_target = arabicDeclarationToken(first.target, &target_buffer) orelse return null;
    const first_label = arabicDeclarationToken(first.label, &label_buffer) orelse return null;
    if (std.mem.eql(u8, first_target, "لغة") and std.mem.eql(u8, first_label, "لغة")) {
        const language = Link.take(&rest) orelse return null;
        if (rest.len != 0) return null;
        return .{ .target = language.target, .label = language.label, .phrase = false };
    }
    if (!std.mem.eql(u8, rest, ":") or !std.mem.startsWith(u8, first_label, "في اللغة ") or first_label.len == "في اللغة ".len) return null;
    return .{ .target = first.target, .label = first.label, .phrase = true };
}
fn resolveArabicLinkedOwner(codes: LanguageCodes, declaration: ArabicLinkedOwner) ?ResolvedLanguage {
    var target_buffer: [256]u8 = undefined;
    var label_buffer: [512]u8 = undefined;
    const target = arabicDeclarationToken(declaration.target, &target_buffer) orelse return null;
    const whole_label = arabicDeclarationToken(declaration.label, &label_buffer) orelse return null;
    const label = if (declaration.phrase) whole_label["في اللغة ".len..] else whole_label;
    const target_owner = codes.resolveStrong(target) orelse codes.resolveTrusted(target) orelse return null;
    const label_owner = codes.resolveStrong(label) orelse codes.resolveTrusted(label) orelse return null;
    return if (std.mem.eql(u8, target_owner.code, label_owner.code)) target_owner else null;
}

const ArabicNorwegianDeclaration = enum { nb, nn };

fn arabicNorwegianDeclaration(codes: LanguageCodes, value: []const u8) ?ArabicNorwegianDeclaration {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar") or value.len > 1024 or
        std.mem.indexOfAny(u8, value, "\r\n") != null) return null;
    var buffer: [1024]u8 = undefined;
    const normalized = arabicDeclarationToken(value, &buffer) orelse return null;
    var rest = std.mem.trim(u8, normalized, " \t");
    const Link = struct {
        fn take(text: *[]const u8, wanted: []const u8) bool {
            if (!std.mem.startsWith(u8, text.*, "[[")) return false;
            const close = std.mem.indexOf(u8, text.*, "]]") orelse return false;
            const body = text.*[2..close];
            if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return false;
            const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
            if (!std.mem.eql(u8, std.mem.trim(u8, body[0..pipe], " \t"), wanted)) return false;
            // A label cannot silently change the declaration's meaning.
            if (pipe < body.len and !std.mem.eql(u8, std.mem.trim(u8, body[pipe + 1 ..], " \t"), wanted)) return false;
            text.* = std.mem.trimStart(u8, text.*[close + 2 ..], " \t");
            return true;
        }
    };
    if (!Link.take(&rest, "في") or !std.mem.startsWith(u8, rest, "ال")) return null;
    rest = rest["ال".len..];
    if (!Link.take(&rest, "نرويجية") or !std.mem.startsWith(u8, rest, "(")) return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    const variant: ArabicNorwegianDeclaration = if (Link.take(&rest, "بوكمول"))
        .nb
    else if (Link.take(&rest, "نينوشك"))
        .nn
    else
        return null;
    if (!std.mem.startsWith(u8, rest, ")")) return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    if (!std.mem.eql(u8, rest, ":")) return null;
    return variant;
}

fn resolveArabicNorwegianDeclaration(codes: LanguageCodes, value: []const u8) ?ResolvedLanguage {
    const variant = arabicNorwegianDeclaration(codes, value) orelse return null;
    const umbrella = codes.resolveTrusted("نرويجية") orelse return null;
    if (!std.mem.eql(u8, umbrella.code, "no")) return null;
    // These exact combined names are the captured named-table authority:
    // وحدة:لغات/بيانات page214436/rev996464, not invented bare-variant aliases.
    const code = if (variant == .nb) "nb" else "nn";
    const label = if (variant == .nb) "نرويجية بوكمول" else "نرويجية نينوشك";
    const named = codes.resolveTrusted(label) orelse return null;
    const canonical = codes.resolve(code) orelse return null;
    if (!std.mem.eql(u8, named.code, code) or !std.mem.eql(u8, canonical.code, code)) return null;
    return canonical;
}

// Only the combining marks already accepted inside Arabic declaration tokens
// may trail a complete link. Preserve the original heading for presentation.
fn afterArabicDeclarationLink(value: []const u8) []const u8 {
    var rest = value;
    while (rest.len >= 2 and rest[0] == 0xd9) {
        var scratch: [2]u8 = undefined;
        const token = arabicDeclarationToken(rest[0..2], &scratch) orelse break;
        if (token.len != 0) break;
        rest = rest[2..];
    }
    return std.mem.trimStart(u8, rest, " \t");
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
        rest = afterArabicDeclarationLink(rest[close + 2 ..]);
    }
    if (!std.mem.startsWith(u8, rest, "[[")) return null;
    const close = std.mem.indexOf(u8, rest, "]]") orelse return null;
    if (!std.mem.eql(u8, afterArabicDeclarationLink(rest[close + 2 ..]), ":")) return null;
    const body = rest[2..close];
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
        resolveMixedArabicLinkedHeading(codes, heading) != null or
        resolveArabicLanguageHeading(codes, heading) != null or
        hasExplicitLanguageDeclaration(codes, section)) return .{};
    const markers: LanguageMarkers = .{ .codes = &codes };
    return language_source.arabicNounSubtree(section, languageSections(section.source, &markers).control_matcher);
}

fn resolveSection(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    if (arabicLinkedOwner(codes, section.heading)) |declaration| return resolveArabicLinkedOwner(codes, declaration);
    if (codes.namespace_catalog) |namespaces| if (std.mem.eql(u8, namespaces.content_language, "ar")) {
        // Plain "لغة NAME" already has the Strong/Trusted resolver below.
        // Only the literal template declaration adds the generic-code route.
        if (std.mem.startsWith(u8, std.mem.trim(u8, section.heading, " \t\r\n"), "{{"))
            if (declarationLabel(codes, section.heading)) |label| return codes.resolve(label);
    };
    // A balanced standalone equals declaration names its owner in the first
    // field. Sort/display arguments, including nested calls, cannot lend one.
    if (language_source.equalsLanguageDeclaration(section.source)) |code|
        if (std.mem.eql(u8, code, section.heading)) return codes.resolve(code);
    if (arabicNorwegianDeclaration(codes, section.heading) != null)
        return resolveArabicNorwegianDeclaration(codes, section.heading);
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
    if (resolveMixedArabicLinkedHeading(codes, classified)) |resolved| return resolved;
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
    if (arabicLinkedOwner(codes, section.heading) != null) return true;
    if (arabicNorwegianDeclaration(codes, section.heading) != null) return true;
    if (language_source.equalsLanguageDeclaration(section.source)) |code|
        if (std.mem.eql(u8, code, section.heading)) return true;
    return declarationLabel(codes, section.heading) != null;
}

fn boundaryLanguage(codes: LanguageCodes, section: language_source.Section) ?ResolvedLanguage {
    if (arabicLinkedOwner(codes, section.heading)) |declaration| return resolveArabicLinkedOwner(codes, declaration);
    if (arabicNorwegianDeclaration(codes, section.heading) != null)
        return resolveArabicNorwegianDeclaration(codes, section.heading);
    const noun = arabicLemmaDeclaration(codes, section);
    if (noun.present) return if (noun.code) |code| codes.resolve(code) else null;
    const heading = language_source.classificationSection(section);
    if (resolveCategorizedHeading(codes, heading)) |resolved| return resolved;
    if (resolveArabicLanguageHeading(codes, heading)) |resolved| return resolved;
    if (codes.resolve(std.mem.trim(u8, heading, " \t\r\n"))) |resolved| return resolved;
    if (codes.resolve(std.mem.trim(u8, heading, " \t\r\n\'\""))) |resolved| return resolved;
    if (resolveLinkedHeading(codes, heading)) |resolved| return resolved;
    if (resolveMixedArabicLinkedHeading(codes, heading)) |resolved| return resolved;
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

// Complete page-wide hatnotes retain their meaning despite a later heading warning.
// Arbitrary prefix prose and incomplete wrappers keep the existing owner policy.
fn pageWideHatnotePrefix(prefix: []const u8) bool {
    const syntax = blobs.wikitext_syntax;
    var cursor: usize = 0;
    var found = false;
    while (cursor < prefix.len) {
        if (std.ascii.isWhitespace(prefix[cursor])) {
            cursor += 1;
            continue;
        }
        if (std.mem.startsWith(u8, prefix[cursor..], "<!--")) {
            const end = std.mem.indexOfPos(u8, prefix, cursor + 4, "-->") orelse return false;
            cursor = end + 3;
            continue;
        }
        const tag = syntax.tagAt(prefix, cursor) orelse return false;
        if (!tag.is("div") or tag.closing or tag.self_closing) return false;
        const classes = tag.attr("class") orelse return false;
        var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
        const class = tokens.next() orelse return false;
        if ((!std.mem.eql(u8, class, "disambig-see-also") and
            !std.mem.eql(u8, class, "disambig-see-also-2")) or tokens.next() != null) return false;
        const pair = syntax.matchingTag(prefix, tag) orelse return false;
        cursor = pair.end;
        found = true;
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
    expanded_sections: []const language_source.Section = &.{},
    raw_source: ?[]const u8 = null,
    expanded_source: ?[]const u8 = null,
};

// An unknown raw equals marker is a boundary only when actual expanded L2
// independently repeats its code in a whole linked declaration. This does
// not resolve the code or assign the linked target's language to that region.
fn expandedEqualsDeclaration(section: language_source.Section, code: []const u8) bool {
    const source = std.mem.trimStart(u8, section.source, " \t\r");
    if (!std.mem.startsWith(u8, source, "==") or source.len < 3 or source[2] == '=') return false;
    const heading = std.mem.trim(u8, section.heading, " \t\r\n");
    if (!std.mem.startsWith(u8, heading, "[[") or !std.mem.endsWith(u8, heading, "]]")) return false;
    const body = heading[2 .. heading.len - 2];
    if (std.mem.indexOfAny(u8, body, "[]{}<>\r\n") != null) return false;
    const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return false;
    if (std.mem.trim(u8, body[0..pipe], " \t").len == 0 or std.mem.indexOfScalar(u8, body[pipe + 1 ..], '|') != null) return false;
    const label = std.mem.trim(u8, body[pipe + 1 ..], " \t");
    if (label.len < code.len + 3 or label[label.len - 1] != ')') return false;
    const open = label.len - code.len - 2;
    return label[open] == '(' and open > 0 and std.ascii.isWhitespace(label[open - 1]) and
        std.mem.eql(u8, label[open + 1 .. label.len - 1], code);
}

fn arabicTableBoundaryOwner(codes: LanguageCodes, heading: []const u8) ?ResolvedLanguage {
    return resolveCategorizedHeading(codes, heading) orelse codes.resolveStrong(std.mem.trim(u8, heading, " \t\r\n")) orelse codes.resolveTrusted(std.mem.trim(u8, heading, " \t\r\n"));
}
fn corroboratedArabicTableBoundary(markers: *const LanguageMarkers, heading: []const u8) bool {
    const namespaces = markers.codes.namespace_catalog orelse return false;
    if (!std.mem.eql(u8, namespaces.content_language, "ar")) return false;
    const raw_source = markers.raw_source orelse return false;
    const expanded = markers.expanded_source orelse return false;
    const owner = arabicTableBoundaryOwner(markers.codes.*, heading) orelse return false;
    const raw_markers: LanguageMarkers = .{ .codes = markers.codes };
    var raw_sections = languageSections(raw_source, &raw_markers);
    var declarations: usize = 0;
    while (raw_sections.next()) |section| {
        // Only the standalone literal template form, outside raw tables and
        // opaque bodies, corroborates this recovery. Ordinary POS/translation
        // headings and raw heading-like cell text cannot provide evidence.
        const offset = @intFromPtr(section.source.ptr) - @intFromPtr(raw_source.ptr);
        if (!language_source.outsideNestedOrOpaque(raw_source, offset)) continue;
        const label = declarationLabel(markers.codes.*, section.heading) orelse continue;
        const trimmed = std.mem.trim(u8, section.heading, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "{{")) continue;
        const raw_owner = markers.codes.resolve(label) orelse continue;
        if (std.mem.eql(u8, owner.code, raw_owner.code)) declarations += 1;
    }
    if (declarations != 1) return false;
    const Match = struct {
        codes: LanguageCodes,
        code: []const u8,
        fn accepts(ctx: ?*const anyopaque, value: []const u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            const candidate = arabicTableBoundaryOwner(self.codes, value) orelse return false;
            return std.mem.eql(u8, candidate.code, self.code);
        }
    };
    const match: Match = .{ .codes = markers.codes.*, .code = owner.code };
    return language_source.countUnprotectedL2Headings(expanded, null, .{ .ctx = &match, .accepts = Match.accepts }) == 1;
}

fn languageSections(source: []const u8, context: *const LanguageMarkers) language_source.Iterator {
    var iterator = language_source.Iterator.initWithMarkerFilter(source, .{
        .ctx = context,
        .accepts = struct {
            fn accepts(raw: ?*const anyopaque, value: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                const language = markers.codes.resolve(value) orelse return false;
                if (markers.represented) |codes| {
                    for (codes) |code| if (std.mem.eql(u8, code, language.code)) return true;
                    // Exact captured AN banners corroborate their raw codes
                    // even when a local name is absent or collides in the registry.
                    for (markers.expanded_sections) |section| {
                        if (corroboratedAnHyphenMarker(markers.codes.*, .{ .heading = value, .source = "", .hyphen_marker = true }, section)) return true;
                    }
                    return false;
                }
                return true;
            }
        }.accepts,
        .accepts_equals = struct {
            fn accepts(raw: ?*const anyopaque, value: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                if (markers.codes.resolve(value) != null) return true;
                for (markers.expanded_sections) |section|
                    if (expandedEqualsDeclaration(section, value)) return true;
                return false;
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
    iterator.table_boundary_filter = .{
        .ctx = context,
        .accepts = struct {
            fn accepts(raw: ?*const anyopaque, heading: []const u8) bool {
                const markers: *const LanguageMarkers = @ptrCast(@alignCast(raw.?));
                return corroboratedArabicTableBoundary(markers, heading);
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

// Live arwiktionary bit page10972/rev1142865 has one المعاني L2 and an
// explicit language category. Both authored and expanded forms must agree.
fn arabicMeaningsSupportSections(codes: LanguageCodes, source: []const u8, sections: []const language_source.Section) bool {
    if (sections.len != 1 or sections[0].hyphen_marker or
        !std.mem.eql(u8, std.mem.trim(u8, sections[0].heading, " \t\r\n"), "المعاني") or
        hasExplicitLanguageDeclaration(codes, sections[0]) or resolveSection(codes, sections[0]) != null) return false;
    const section = sections[0];
    const prefix_end = @intFromPtr(section.source.ptr) - @intFromPtr(source.ptr);
    if (std.mem.trim(u8, source[0..prefix_end], " \t\r\n").len != 0) return false;
    const first_line = std.mem.trim(u8, section.source[0..(std.mem.indexOfScalar(u8, section.source, '\n') orelse section.source.len)], " \t\r");
    if (first_line.len < 3 or first_line[0] != '=' or first_line[1] != '=' or first_line[2] == '=') return false;
    // Reuse the protected declaration filter at every heading depth: ordinary
    // POS headings stay support content, but an L3+ language cannot be hidden.
    const markers: LanguageMarkers = .{ .codes = &codes };
    var nested = languageSections(source, &markers);
    nested.all_heading_levels = true;
    _ = nested.next() orelse return false;
    return nested.next() == null;
}

fn arabicMeaningsCategory(codes: LanguageCodes, source: []const u8) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
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

fn arabicMeaningsSupportCategoryLanguage(codes: LanguageCodes, source: []const u8, raw_source: ?[]const u8, raw_sections: []const language_source.Section, page_sections: []const language_source.Section) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ar")) return null;
    const raw = raw_source orelse return null;
    if (!arabicMeaningsSupportSections(codes, raw, raw_sections) or
        !arabicMeaningsSupportSections(codes, source, page_sections)) return null;
    const raw_language = arabicMeaningsCategory(codes, raw) orelse return null;
    const expanded_language = arabicMeaningsCategory(codes, source) orelse return null;
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

const PageSourceFragment = struct {
    source: []const u8,
    original_start: ?usize = null,
};

const PageLanguageGroup = struct {
    language: ResolvedLanguage,
    source: std.ArrayList(u8) = .empty,
    fragments: std.ArrayList(PageSourceFragment) = .empty,

    fn appendSource(self: *PageLanguageGroup, a: std.mem.Allocator, fragment: PageSourceFragment) !void {
        try self.source.appendSlice(a, fragment.source);
        if (fragment.source.len != 0) try self.fragments.append(a, fragment);
    }
};

fn preCandidate(input: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, at, '<')) |opening| {
        at = opening + 1;
        if (input.len - at >= 3 and std.ascii.eqlIgnoreCase(input[at .. at + 3], "pre")) return true;
    }
    return false;
}

fn freeObservedScopes(a: std.mem.Allocator, scopes: []const presentation_document.ObservedPreScope) void {
    for (scopes) |scope| {
        a.free(scope.target);
        a.free(scope.attributes.classes);
        a.free(scope.attributes.language);
        a.free(scope.attributes.direction);
        a.free(scope.attributes.explanation);
    }
    if (scopes.len != 0) a.free(scopes);
}

fn freePreObservation(a: std.mem.Allocator, observation: presentation_document.PreObservation) void {
    freeObservedScopes(a, observation.scopes);
    a.free(observation.refused_link_openings);
}

fn linkOpeningsAlloc(a: std.mem.Allocator, scopes: []const presentation_document.ObservedPreScope, refused_link_openings: []const usize) ![]const usize {
    var openings: std.ArrayList(usize) = .empty;
    errdefer openings.deinit(a);
    for (scopes) |scope| if (scope.kind == .link) try openings.append(a, scope.opening_start);
    try openings.appendSlice(a, refused_link_openings);
    std.mem.sort(usize, openings.items, {}, std.sort.asc(usize));
    var unique: usize = 0;
    for (openings.items) |opening| {
        if (unique == 0 or openings.items[unique - 1] != opening) {
            openings.items[unique] = opening;
            unique += 1;
        }
    }
    openings.items = openings.items[0..unique];
    return openings.toOwnedSlice(a);
}

fn refusedOpeningInFragments(source: []const u8, fragments: []const PageSourceFragment, refused_openings: []const usize) !bool {
    for (fragments) |fragment| {
        const start = fragment.original_start orelse continue;
        if (start > source.len or fragment.source.len > source.len - start or fragment.source.ptr != source[start..].ptr)
            return error.InvalidPreContext;
        const index = firstQuoteCutAtOrAfter(refused_openings, start);
        if (index < refused_openings.len and refused_openings[index] < start + fragment.source.len) return true;
    }
    return false;
}

fn lastPreOpeningBefore(scopes: []const presentation_document.ObservedPreScope, at: usize) ?usize {
    var low: usize = 0;
    var high: usize = scopes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (scopes[middle].opening_start < at) low = middle + 1 else high = middle;
    }
    return if (low == 0) null else low - 1;
}

const ScopeQuoteCuts = struct {
    positions: []const usize = &.{},
    seeds: []const presentation_document.QuoteSeed = &.{},
    fn at(self: @This(), position: usize) !presentation_document.QuoteSeed {
        const index = firstQuoteCutAtOrAfter(self.positions, position);
        if (index == self.positions.len or self.positions[index] != position) return error.InvalidPreContext;
        return self.seeds[index];
    }
    fn deinit(self: @This(), a: std.mem.Allocator) void {
        a.free(self.positions);
        a.free(self.seeds);
    }
};
const PageQuoteCuts = struct {
    outer: ScopeQuoteCuts = .{},
    links: []ScopeQuoteCuts = &.{},
    fn deinit(self: @This(), a: std.mem.Allocator) void {
        self.outer.deinit(a);
        for (self.links) |cuts| cuts.deinit(a);
        a.free(self.links);
    }
};
fn firstQuoteCutAtOrAfter(cuts: []const usize, position: usize) usize {
    var low: usize = 0;
    var high = cuts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (cuts[middle] < position) low = middle + 1 else high = middle;
    }
    return low;
}
fn enclosingLinkScope(scopes: []const presentation_document.ObservedPreScope, position: usize) ?usize {
    var cursor = lastPreOpeningBefore(scopes, position);
    while (cursor) |index| {
        const scope = scopes[index];
        if (scope.kind == .link and scope.opening_start < position and position < scope.resume_at) return index;
        cursor = scope.parent;
    }
    return null;
}
fn appendQuoteCut(a: std.mem.Allocator, cuts: *std.ArrayList(usize), position: usize) !void {
    if (cuts.items.len != 0) {
        const previous = cuts.items[cuts.items.len - 1];
        if (position < previous) return error.InvalidPreContext;
        if (position == previous) return;
    }
    try cuts.append(a, position);
}
fn pageQuoteCutsAlloc(a: std.mem.Allocator, source: []const u8, sections: []const language_source.Section, scopes: []const presentation_document.ObservedPreScope, context: presentation_document.QuoteContext) !PageQuoteCuts {
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(a);
    try appendQuoteCut(a, &positions, 0);
    for (sections) |section| {
        const base = @intFromPtr(source.ptr);
        const pointer = @intFromPtr(section.source.ptr);
        if (pointer < base or pointer - base > source.len or section.source.len > source.len - (pointer - base)) return error.InvalidPreContext;
        const start = pointer - base;
        try appendQuoteCut(a, &positions, start);
        try appendQuoteCut(a, &positions, start + section.source.len);
    }
    try appendQuoteCut(a, &positions, source.len);
    var outside: std.ArrayList(usize) = .empty;
    defer outside.deinit(a);
    for (positions.items) |position| if (enclosingLinkScope(scopes, position) == null) try outside.append(a, position);
    const outer_positions = try outside.toOwnedSlice(a);
    errdefer a.free(outer_positions);
    const outer_seeds = try presentation_document.bodyQuoteCutSeedsWithContextAlloc(a, source, outer_positions, context);
    errdefer a.free(outer_seeds);
    if (outer_positions.len != outer_seeds.len) return error.InvalidPreContext;
    const links = try a.alloc(ScopeQuoteCuts, scopes.len);
    @memset(links, .{});
    errdefer {
        for (links) |cuts| cuts.deinit(a);
        a.free(links);
    }
    for (scopes, links) |scope, *output| {
        if (scope.kind != .link) continue;
        const observed = scope.link_quotes orelse return error.InvalidPreContext;
        var cuts: std.ArrayList(usize) = .empty;
        defer cuts.deinit(a);
        try appendQuoteCut(a, &cuts, scope.body_start);
        var cursor = firstQuoteCutAtOrAfter(positions.items, scope.body_start);
        while (cursor < positions.items.len and positions.items[cursor] <= scope.body_end) : (cursor += 1)
            try appendQuoteCut(a, &cuts, positions.items[cursor]);
        try appendQuoteCut(a, &cuts, scope.body_end);
        const relative = try a.alloc(usize, cuts.items.len);
        defer a.free(relative);
        for (cuts.items, relative) |absolute, *offset| offset.* = absolute - scope.body_start;
        const seeds = try presentation_document.linkQuoteCutSeedsWithContextAlloc(a, source[scope.body_start..scope.body_end], relative, observed.entry, context);
        errdefer a.free(seeds);
        if (seeds.len != cuts.items.len) return error.InvalidPreContext;
        output.* = .{ .positions = try cuts.toOwnedSlice(a), .seeds = seeds };
    }
    return .{ .outer = .{ .positions = outer_positions, .seeds = outer_seeds }, .links = links };
}

fn fragmentPreContextAlloc(a: std.mem.Allocator, start: usize, end: usize, scopes: []const presentation_document.ObservedPreScope, quotes: PageQuoteCuts) !presentation_document.FragmentPreContext {
    var initial: std.ArrayList(presentation_document.FragmentPreContext.Initial) = .empty;
    errdefer initial.deinit(a);
    var trailing: std.ArrayList(presentation_document.FragmentPreContext.Trailing) = .empty;
    errdefer trailing.deinit(a);
    var newest_open: ?usize = null;
    var newest_close: usize = 0;
    var cursor = lastPreOpeningBefore(scopes, start);
    // Source-backed body scopes are properly nested. Only ancestors of the
    // last opening can contain this cut, so ordinary earlier roots are skipped.
    while (cursor) |index| {
        const scope = scopes[index];
        if (scope.body_start <= start and start < scope.body_end) {
            try initial.append(a, .{
                .body_end = @min(scope.body_end, end) - start,
                .resume_at = @min(scope.resume_at, end) - start,
                .kind = scope.kind,
                .formatting = scope.formatting,
                .attributes = scope.attributes,
                .target = scope.target,
                .quote = if (scope.kind == .link) try quotes.links[index].at(start) else null,
                .resume_quote = if (scope.kind == .link) (scope.link_quotes orelse return error.InvalidPreContext).resume_quote else null,
            });
            if (scope.kind == .pre) newest_open = @max(newest_open orelse 0, scope.body_start);
        }
        if (scope.kind == .pre and scope.matched and scope.resume_at <= start) newest_close = @max(newest_close, scope.resume_at);
        cursor = scope.parent;
    }
    cursor = lastPreOpeningBefore(scopes, end);
    while (cursor) |index| {
        const scope = scopes[index];
        if (scope.opening_start >= start and scope.body_start <= end and scope.body_end >= end)
            try trailing.append(a, .{ .opening_start = scope.opening_start - start, .body_start = scope.body_start - start, .kind = scope.kind, .formatting = scope.formatting, .attributes = scope.attributes, .target = scope.target, .quote = if (scope.kind == .link) (scope.link_quotes orelse return error.InvalidPreContext).entry else null });
        cursor = scope.parent;
    }
    // Initial ancestors were appended inner-first. Trailing opens need the
    // opposite order so the adapter consumes their actual tag intervals.
    std.mem.reverse(presentation_document.FragmentPreContext.Trailing, trailing.items);
    const initial_owned = try initial.toOwnedSlice(a);
    errdefer a.free(initial_owned);
    const trailing_owned = try trailing.toOwnedSlice(a);
    errdefer a.free(trailing_owned);
    return .{
        .quote = if (enclosingLinkScope(scopes, start)) |index| try quotes.links[index].at(start) else try quotes.outer.at(start),
        .initial = initial_owned,
        .trailing = trailing_owned,
        .initial_block_pre = if (newest_open) |opened| opened > newest_close else false,
    };
}

fn ownerSourceFragmentsAlloc(a: std.mem.Allocator, source: []const u8, fragments: []const PageSourceFragment, prefix: []const u8, scopes: []const presentation_document.ObservedPreScope, quotes: PageQuoteCuts) ![]const presentation_document.SourceFragment {
    var ranges: std.ArrayList(PageSourceFragment) = .empty;
    defer ranges.deinit(a);
    if (prefix.len != 0) try ranges.append(a, .{ .source = prefix, .original_start = 0 });
    for (fragments) |fragment| {
        if (ranges.items.len != 0) {
            const previous = &ranges.items[ranges.items.len - 1];
            if (previous.original_start) |left| if (fragment.original_start) |right| {
                if (left + previous.source.len == right) {
                    previous.source = source[left .. right + fragment.source.len];
                    continue;
                }
            };
        }
        try ranges.append(a, fragment);
    }
    const result = try a.alloc(presentation_document.SourceFragment, ranges.items.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |fragment| {
            a.free(fragment.pre.initial);
            a.free(fragment.pre.trailing);
        }
        a.free(result);
    }
    for (ranges.items, result) |range, *fragment| {
        fragment.* = .{
            .source = range.source,
            .pre = if (range.original_start) |start|
                try fragmentPreContextAlloc(a, start, start + range.source.len, scopes, quotes)
            else
                .{},
        };
        initialized += 1;
    }
    return result;
}

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
    const declaration = language_source.equalsLanguageDeclaration(raw.source) orelse return false;
    if (!std.mem.eql(u8, declaration, raw_code)) return false;
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

// The captured ANG noun-table convention supplies a grammatical cue independent
// of the homographic Nama language label. Keep both the raw and expanded cue,
// the preceding explicit Old English declaration, and the registered code.
fn angNounTableContinuation(
    codes: LanguageCodes,
    preceding_raw: []const language_source.Section,
    raw: language_source.Section,
    rendered: language_source.Section,
    current_code: []const u8,
) ?ResolvedLanguage {
    const namespaces = codes.namespace_catalog orelse return null;
    if (!std.mem.eql(u8, namespaces.content_language, "ang") or
        !std.mem.eql(u8, current_code, "ang") or raw.hyphen_marker or rendered.hyphen_marker or
        !std.mem.eql(u8, raw.heading, "Nama") or !std.mem.eql(u8, rendered.heading, "Nama")) return null;
    var explicit_ang = false;
    var previous = preceding_raw.len;
    while (previous > 0) {
        previous -= 1;
        const section = preceding_raw[previous];
        if (section.hyphen_marker) return null;
        const end = std.mem.indexOfScalar(u8, section.source, '\n') orelse return null;
        const line = std.mem.trim(u8, section.source[0..end], " \t\r");
        if (std.mem.eql(u8, line, "=={{sprǣc|ang}}==")) {
            explicit_ang = true;
            break;
        }
        // This captured adjective heading is a support section, not another
        // language declaration. An arbitrary intervening heading cannot lend
        // the old declaration to a later homograph.
        if (!std.mem.eql(u8, line, "==Tōgeīecendlic==")) return null;
    }
    if (!explicit_ang) return null;
    const raw_end = std.mem.indexOfScalar(u8, raw.source, '\n') orelse return null;
    const rendered_end = std.mem.indexOfScalar(u8, rendered.source, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, raw.source[0..raw_end], " \t\r"), "==Nama==") or
        !std.mem.eql(u8, std.mem.trim(u8, rendered.source[0..rendered_end], " \t\r"), "==Nama==")) return null;
    const body = std.mem.trimStart(u8, raw.source[raw_end + 1 ..], " \t\r\n");
    const heading_end = std.mem.indexOfScalar(u8, body, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, body[0..heading_end], " \t\r"), "=== {{m}} {{Wordcynn|Nama}} ===")) return null;
    const table = std.mem.trimStart(u8, body[heading_end + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, table, "{{Naman-Tabule|")) return null;
    _ = blobs.wikitext_syntax.balanced(table, 0) orelse return null;
    const expanded_body = std.mem.trimStart(u8, rendered.source[rendered_end + 1 ..], " \t\r\n");
    const expanded_heading_end = std.mem.indexOfScalar(u8, expanded_body, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, expanded_body[0..expanded_heading_end], " \t\r"), "=== Werlic [[Help:Wordcynn|Nama]][[Flocc:Nama]] ===")) return null;
    const language = codes.resolve("ang") orelse return null;
    return if (std.mem.eql(u8, language.code, "ang")) language else null;
}

// Raw AN pages retain ordinary L2 support headings while the captured
// language templates expand to L1 banners. Preserve those support bytes in
// their explicit raw-marker region, but only after every rendered region
// independently agrees with exactly one canonical hyphen marker.
fn coalesceCorroboratedAnRawRegions(codes: LanguageCodes, raw: []const u8, sections: *std.ArrayList(language_source.Section), rendered: []const language_source.Section) void {
    const namespaces = codes.namespace_catalog orelse return;
    if (!std.mem.eql(u8, namespaces.content_language, "an") or sections.items.len == rendered.len) return;
    var count: usize = 0;
    for (sections.items) |section| {
        if (!section.hyphen_marker) {
            if (count == 0 or hasExplicitLanguageDeclaration(codes, section) or resolveSection(codes, section) != null) return;
            continue;
        }
        if (count >= rendered.len) return;
        const owner = codes.resolve(section.heading) orelse return;
        if (!std.mem.eql(u8, owner.code, section.heading)) return;
        const exact_banner = corroboratedAnHyphenMarker(codes, section, rendered[count]);
        const other = boundaryLanguage(codes, rendered[count]);
        if (!exact_banner and (other == null or !std.mem.eql(u8, owner.code, other.?.code))) return;
        count += 1;
    }
    if (count != rendered.len or count == 0) return;
    var written: usize = 0;
    for (sections.items) |section| {
        if (section.hyphen_marker) {
            sections.items[written] = section;
            written += 1;
        } else {
            const previous = &sections.items[written - 1];
            const start = @intFromPtr(previous.source.ptr) - @intFromPtr(raw.ptr);
            const end = @intFromPtr(section.source.ptr) - @intFromPtr(raw.ptr) + section.source.len;
            previous.source = raw[start..end];
        }
    }
    sections.items.len = written;
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
    raw_poem_phase: ?*const presentation_document.PoemPhase,
) !void {
    const numbered = try presentation_document.preparePageExternalLinksAlloc(page_allocator, source_raw, .{
        .title = title,
        .link_trail = codes.link_trail,
        .namespace_catalog = codes.namespace_catalog,
        .behavior_switches = codes.behavior_switches,
        .image_options = codes.image_options,
        .poem_phase = raw_poem_phase,
    });
    const poem_phase = numbered.poem_phase;
    // MediaWiki's first body TOC is page-scoped, before language-owner regrouping.
    const may_cross_pre = preCandidate(numbered.source) or presentation_document.mayHaveFormattingScopes(numbered.source);
    const may_cross_link = presentation_document.mayHaveMultilineLinks(numbered.source);
    const body_source: presentation_document.PreparedBodySource = if (may_cross_pre or may_cross_link)
        try presentation_document.prepareBodySourceAlloc(page_allocator, title, numbered.source)
    else
        .{ .source = numbered.source, .fallbacks = .{} };
    defer if (body_source.source.ptr != numbered.source.ptr) page_allocator.free(body_source.source);
    fallbacks.merge(body_source.fallbacks);
    const source = try presentation_document.preparePageTocSourceAlloc(page_allocator, body_source.source, codes.behavior_switches);
    defer if (source.ptr != body_source.source.ptr) page_allocator.free(source);
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
    const reference_context = try presentation_document.referenceDefinitionsAlloc(page_allocator, source);
    // Ordinary navigation admission is established by the actual renderer,
    // before ownership cuts. The same raw-domain map later carries rendering.
    const early_observation: presentation_document.PreObservation = if (may_cross_link)
        try presentation_document.observePreScopesAlloc(page_allocator, title, source, codes.link_trail, codes.namespace_catalog, codes.behavior_switches, codes.image_options, reference_context, poem_phase)
    else
        .{ .scopes = &.{}, .unclosed_formatting = false };
    defer freePreObservation(page_allocator, early_observation);
    const expanded_link_openings = try linkOpeningsAlloc(page_allocator, early_observation.scopes, early_observation.refused_link_openings);
    defer page_allocator.free(expanded_link_openings);
    const expanded_markers: LanguageMarkers = .{ .codes = &codes, .raw_source = raw_source, .expanded_source = source };
    var sections = languageSections(source, &expanded_markers);
    if (may_cross_link) sections.link_headings = .{ .source = source, .openings = expanded_link_openings };
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
        const raw_markers: LanguageMarkers = .{ .codes = &codes, .represented = if (named_boundaries) represented.items else null, .expanded_sections = page_sections.items };
        var raw_it = languageSections(raw, &raw_markers);
        var raw_observation: presentation_document.PreObservation = .{ .scopes = &.{}, .unclosed_formatting = false };
        defer freePreObservation(page_allocator, raw_observation);
        var raw_link_openings: []const usize = &.{};
        defer if (raw_link_openings.len != 0) page_allocator.free(raw_link_openings);
        if (presentation_document.mayHaveMultilineLinks(raw)) {
            const raw_prepared = try presentation_document.prepareBodySourceAlloc(page_allocator, title, raw);
            defer if (raw_prepared.source.ptr != raw.ptr) page_allocator.free(raw_prepared.source);
            const raw_toc = try presentation_document.preparePageTocSourceAlloc(page_allocator, raw_prepared.source, codes.behavior_switches);
            defer if (raw_toc.ptr != raw_prepared.source.ptr) page_allocator.free(raw_toc);
            // Authored raw text remains the corroboration authority. A changed
            // preparation domain cannot lend offsets to the original Iterator.
            if (std.mem.eql(u8, raw, raw_toc)) {
                const raw_references = try presentation_document.referenceDefinitionsAlloc(page_allocator, raw);
                raw_observation = try presentation_document.observePreScopesAlloc(page_allocator, title, raw, codes.link_trail, codes.namespace_catalog, codes.behavior_switches, codes.image_options, raw_references, null);
                raw_link_openings = try linkOpeningsAlloc(page_allocator, raw_observation.scopes, raw_observation.refused_link_openings);
                raw_it.link_headings = .{ .source = raw, .openings = raw_link_openings };
            }
        }
        while (raw_it.next()) |section| try appendClassifiedSection(page_allocator, codes, &raw_sections, &owned_headings, section);
    }
    if (raw_source) |raw| coalesceCorroboratedAnRawRegions(codes, raw, &raw_sections, page_sections.items);
    var raw_aligned = raw_sections.items.len != 0 and raw_sections.items.len == page_sections.items.len;
    if (raw_aligned) for (raw_sections.items, page_sections.items) |raw_section, rendered_section| {
        // A short template name can be both a POS marker and an ISO code.
        // Equal section counts do not prove that its expansion is a language
        // boundary: e.g. Aymara's -ay-/-adj- can line up with noun/adjective
        // headings. Require rendered language evidence for hyphen markers;
        // preserve the distinct equals-style language declaration convention.
        if (raw_section.hyphen_marker and boundaryLanguage(codes, rendered_section) == null and
            !corroboratedAnHyphenMarker(codes, raw_section, rendered_section))
        {
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
    // A complete page-wide hatnote is context for every emitted owner, even
    // Unclassified; only its prefix is shared, never another owner's body.
    const shared_prefix: ?[]const u8 = if (pageWideHatnotePrefix(page_prefix))
        page_prefix
    else
        try sharedImagePrefix(page_allocator, codes, page_prefix);

    var groups: std.ArrayList(PageLanguageGroup) = .empty;
    defer {
        for (groups.items) |*group| {
            group.source.deinit(page_allocator);
            group.fragments.deinit(page_allocator);
        }
        groups.deinit(page_allocator);
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(page_allocator);
    var pending_fragments: std.ArrayList(PageSourceFragment) = .empty;
    defer pending_fragments.deinit(page_allocator);
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
            angEnglishNounContinuation(codes, raw_sections.items[index - 1], raw_sections.items[index], section, groups.items[current.?].language.code) orelse
                angNounTableContinuation(codes, raw_sections.items[0..index], raw_sections.items[index], section, groups.items[current.?].language.code)
        else
            null;
        var resolved: ?ResolvedLanguage = ang_continuation;
        if (resolved == null and raw_aligned) resolved = resolveSection(codes, raw_sections.items[index]);
        if (ang_continuation == null) if (resolved) |raw_language| if (boundaryLanguage(codes, section)) |rendered_language| {
            if (!std.mem.eql(u8, raw_language.code, rendered_language.code) and
                !corroboratedEqualsDeclaration(codes, raw_sections.items[index], section, raw_language.code, rendered_language.code) and
                !corroboratedAnHyphenMarker(codes, raw_sections.items[index], section))
            {
                resolved = null;
                fallbacks.unresolved_language_heading = true;
            }
        };
        if (resolved == null) resolved = resolveSection(codes, section);

        // A collision or explicit boundary-only label is a boundary without
        // an owner. Ordinary unknown support/POS headings keep their policy.
        const known_boundary = codes.isLanguageBoundary(std.mem.trim(u8, section.heading, " \t\r\n")) or
            (raw_aligned and codes.isLanguageBoundary(std.mem.trim(u8, raw_sections.items[index].heading, " \t\r\n")));
        if (resolved == null and (known_boundary or isolate_mixed or hasExplicitLanguageDeclaration(codes, section) or
            (raw_aligned and hasExplicitLanguageDeclaration(codes, raw_sections.items[index]))))
        {
            fallbacks.unresolved_language_heading = true;
            resolved = .{ .code = "", .heading = "Unclassified" };
        }

        // Admitting an unknown equals marker established a boundary, not an
        // owner. Its linked rendered target cannot lend a different language.
        if (raw_aligned) if (language_source.equalsLanguageDeclaration(raw_sections.items[index].source)) |code| {
            if (codes.resolve(code) == null) {
                fallbacks.unresolved_language_heading = true;
                resolved = .{ .code = "", .heading = "Unclassified" };
            }
        };

        if (resolved) |language| {
            const group_index = groupIndex(groups.items, language) orelse blk: {
                try groups.append(page_allocator, .{ .language = language });
                if (shared_prefix) |prefix| try groups.items[groups.items.len - 1].appendSource(page_allocator, .{ .source = prefix });
                break :blk groups.items.len - 1;
            };
            current = group_index;
            if (pending.items.len != 0) {
                for (pending_fragments.items) |fragment| try groups.items[group_index].appendSource(page_allocator, fragment);
                pending.clearRetainingCapacity();
                pending_fragments.clearRetainingCapacity();
            }
            try groups.items[group_index].appendSource(page_allocator, .{ .source = section.source, .original_start = @intFromPtr(section.source.ptr) - @intFromPtr(source.ptr) });
        } else if (current) |group_index| {
            fallbacks.unresolved_language_heading = true;
            try groups.items[group_index].appendSource(page_allocator, .{ .source = section.source, .original_start = @intFromPtr(section.source.ptr) - @intFromPtr(source.ptr) });
        } else {
            fallbacks.unresolved_language_heading = true;
            try pending.appendSlice(page_allocator, section.source);
            try pending_fragments.append(page_allocator, .{ .source = section.source, .original_start = @intFromPtr(section.source.ptr) - @intFromPtr(source.ptr) });
        }
    }

    if (groups.items.len == 0) {
        // Arbitrary unknown headings cannot inherit a page-wide category.
        // Captured edition-local support forms require corroborated raw and
        // expanded category authority and preserve the whole entry body.
        const support = amharicSupportCategoryLanguage(codes, source, raw_source, raw_sections.items, page_sections.items) orelse
            arabicMeaningsSupportCategoryLanguage(codes, source, raw_source, raw_sections.items, page_sections.items);
        const explicit = if (page_sections.items.len == 0)
            unsectionedLanguage(codes, raw_source orelse source) orelse unsectionedExpandedLanguage(codes, source)
        else
            support;
        if (support != null) fallbacks.unresolved_language_heading = unresolved_before_sections;
        if (explicit == null) fallbacks.missing_language_heading = true;
        // Unknown candidate headings cannot inherit the edition's language.
        // The captured AY -ay- banner has no heading: its noun/adjective
        // templates instead emit these exact POS headings. Preserve only that
        // corroborated native convention, never an arbitrary AY boundary.
        const native_default: ?ResolvedLanguage = native: {
            const language = codes.content() orelse break :native null;
            // The edition language alone cannot identify an unsectioned entry.
            // Existing explicit/support rules above and the corroborated AY
            // convention below remain the only attribution in this branch.
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
        for (pending_fragments.items) |fragment| try groups.items[0].appendSource(page_allocator, fragment);
        pending.clearRetainingCapacity();
        pending_fragments.clearRetainingCapacity();
    }

    const pre_observation: presentation_document.PreObservation = if (may_cross_link)
        early_observation
    else if (may_cross_pre and (groups.items.len > 1 or page_prefix.len != 0))
        try presentation_document.observePreScopesAlloc(page_allocator, title, source, codes.link_trail, codes.namespace_catalog, codes.behavior_switches, codes.image_options, reference_context, poem_phase)
    else
        .{ .scopes = &.{}, .unclosed_formatting = false };
    defer if (!may_cross_link) freePreObservation(page_allocator, pre_observation);
    fallbacks.unclosed_formatting = fallbacks.unclosed_formatting or pre_observation.unclosed_formatting;
    const quote_cuts: PageQuoteCuts = if (pre_observation.scopes.len != 0)
        try pageQuoteCutsAlloc(page_allocator, source, page_sections.items, pre_observation.scopes, .{
            .title = title,
            .language = "English",
            .link_trail = codes.link_trail,
            .namespace_catalog = codes.namespace_catalog,
            .behavior_switches = codes.behavior_switches,
            .image_options = codes.image_options,
            .poem_phase = poem_phase,
        })
    else
        .{};
    defer quote_cuts.deinit(page_allocator);
    // Preserve ordinary page context only for one unambiguous language.
    // Repeated resolved sections may share that group; inherited unknown
    // sections and pending unresolved regions must not gain attribution.
    const preserve_prefix = shared_prefix == null and page_prefix.len != 0 and
        groups.items.len == 1 and groups.items[0].language.code.len != 0 and
        !fallbacks.unresolved_language_heading;
    // A prefix cannot disappear merely because a later language boundary is
    // uncertain. Keep meaningful unowned context exactly once, never lending it
    // to a resolved language. Invisible categories/comments/controls add no row.
    if (!preserve_prefix and shared_prefix == null and std.mem.trim(u8, page_prefix, " \t\r\n").len != 0) {
        var probe_arena = std.heap.ArenaAllocator.init(page_allocator);
        defer probe_arena.deinit();
        const probe_allocator = probe_arena.allocator();
        const prefix_fragments = if (pre_observation.scopes.len != 0)
            try ownerSourceFragmentsAlloc(probe_allocator, source, &.{.{ .source = page_prefix, .original_start = 0 }}, "", pre_observation.scopes, quote_cuts)
        else
            &.{};
        if (try presentation_document.hasBodyContentWithReferencesAndPoemFragmentsAlloc(
            probe_allocator,
            title,
            "Unclassified",
            page_prefix,
            codes.link_trail,
            codes.namespace_catalog,
            codes.behavior_switches,
            codes.image_options,
            reference_context,
            poem_phase,
            prefix_fragments,
        )) {
            const unowned: ResolvedLanguage = .{ .code = "", .heading = "Unclassified" };
            const index = groupIndex(groups.items, unowned) orelse blk: {
                try groups.append(page_allocator, .{ .language = unowned });
                break :blk groups.items.len - 1;
            };
            try groups.items[index].source.insertSlice(page_allocator, 0, page_prefix);
            try groups.items[index].fragments.insert(page_allocator, 0, .{ .source = page_prefix, .original_start = 0 });
            fallbacks.missing_language_heading = true;
        }
    }
    for (groups.items) |group| {
        // Only expanded source facts inside a real emitted owner range can
        // preserve this exact page-level diagnostic after an ownership cut.
        if (try refusedOpeningInFragments(source, group.fragments.items, pre_observation.refused_link_openings))
            fallbacks.literal_markup = true;
        const group_source = if (preserve_prefix)
            try std.mem.concat(page_allocator, u8, &.{ page_prefix, group.source.items })
        else
            group.source.items;
        const fragments = if (pre_observation.scopes.len != 0)
            try ownerSourceFragmentsAlloc(page_allocator, source, group.fragments.items, if (preserve_prefix) page_prefix else "", pre_observation.scopes, quote_cuts)
        else
            &.{};
        defer {
            for (fragments) |fragment| {
                page_allocator.free(fragment.pre.initial);
                page_allocator.free(fragment.pre.trailing);
            }
            if (fragments.len != 0) page_allocator.free(fragments);
        }
        const payload = try presentation_document.compileReportedWithReferencesAndPoemFragmentsAlloc(
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
            fragments,
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
        fn ar(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "ar", .heading = "Arabic" };
        }
        fn ab(_: ?*const anyopaque) ?ResolvedLanguage {
            return .{ .code = "ab", .heading = "Abkhaz" };
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
    // Current AR source forms have no authoritative language boundary. The
    // category text in Able follows malformed link syntax; arti mixes language
    // material despite one category. Neither may inherit the edition language.
    writer.language_codes.content_fn = Local.ar;
    const able_raw = "{{أيضا|able}}\nمعناها بالعربي (قادر )\n[[ru:Able}}\n[[تصنيف:إنجليزية]]\n";
    const able = "انظر أيضا: [[able]]\nمعناها بالعربي (قادر )\n[[ru:Able}}\n[[تصنيف:إنجليزية]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Able", able, able_raw, null);
    const segments = "قالب:Segment\n=== اسم ===\n# plural of [[segment]]\n=== اسم ===\n# third-person singular of [[segment]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "segments", segments, segments, null);
    const arti = "=== Etymology ===\nCompare Italian [[arte]]\n=== اسم ===\n# [[meaning]]\n=== Etymology 2 ===\nFrom Sanskrit\n==== فعل ====\n# to [[plough]]\n[[تصنيف:إنجليزية]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "arti", arti, arti, null);
    // A nonlexical unsectioned notice is conserved without a guessed owner;
    // the separate controller notice policy still reviews its exact source.
    writer.language_codes.content_fn = Local.ab;
    const notice = "Welcome to this dictionary.\n* [[help|Read the help]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "notice", notice, notice, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 9), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 8), stats.fallback_pages);

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
        .{ .title = "beginde", .heading = "Unclassified", .code = "", .body = "wat mens begin het", .link = "begin" },
        .{ .title = "Able", .heading = "Unclassified", .code = "", .body = "معناها بالعربي (قادر )", .link = "able" },
        .{ .title = "segments", .heading = "Unclassified", .code = "", .body = "plural of", .later_body = "third-person singular of", .link = "segment" },
        .{ .title = "arti", .heading = "Unclassified", .code = "", .body = "Compare Italian", .later_body = "From Sanskrit", .link = "plough" },
        .{ .title = "notice", .heading = "Unclassified", .code = "", .body = "Welcome to this dictionary.", .later_body = "Read the help", .link = "help" },
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
            inline for (.{ "aggi", "Максим", "support-only", "beginde", "Able", "segments", "arti", "notice" }) |title|
                try std.testing.expect((try index.find(title)) == null);
        } else {
            try std.testing.expect((try index.find("network")) == null);
        }
    }
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, blob_catalog.manifest_filename }), a, .unlimited);
    inline for (.{ "አማርኛ", "Afrikaans", "Arabic", "Abkhaz" }) |unproven|
        try std.testing.expect(std.mem.indexOf(u8, manifest, unproven) == null);
}

test "language resolution rejects fake headings without guessing edition ownership" {
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

    // A POS template name alone does not establish the edition as owner.
    var unknown_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Unclassified"));
    defer unknown_map.deinit();
    const unknown_blob = try blob_format.inspect(unknown_map.bytes);
    const unknown_metadata = try unknown_blob.languageMetadata();
    var unknown_index = try unknown_blob.buildTrustedIndexAlloc(a);
    defer unknown_index.deinit(a);
    const unsectioned = (try unknown_index.find("ház")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, unsectioned.payload, unsectioned.title, .language, unknown_metadata);
    try std.testing.expectEqualStrings("", decoded.entry.language_code);
    var kept_house = false;
    for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
        kept_house = kept_house or std.mem.indexOf(u8, span.text, "house") != null;
    };
    try std.testing.expect(kept_house);

    const manifest_path = try std.fs.path.join(a, &.{ root, blob_catalog.manifest_filename });
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Nederlandse vervoeging") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Unclassified") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Magyar") == null);
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
    try writer.addAliasExpanded(pa, alias, "Tail <abbr title=\"retained meaning\">[[retained]]</abbr>.\n===Details===\nVisible body.", null, .{}, &.{});
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
    try std.testing.expect(std.mem.startsWith(u8, first.presentation, "DPR3"));
    var explained_links: usize = 0;
    for (doc.entry.preamble_spans) |span| if (std.mem.eql(u8, span.target, "retained")) {
        try std.testing.expectEqualStrings("retained", span.text);
        try std.testing.expectEqualStrings("retained meaning", span.explanation);
        explained_links += 1;
    };
    for (doc.entry.sections) |section| for (section.blocks) |block| {
        for (block.spans) |span| if (std.mem.eql(u8, span.target, "retained")) {
            try std.testing.expectEqualStrings("retained", span.text);
            try std.testing.expectEqualStrings("retained meaning", span.explanation);
            explained_links += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 1), explained_links);
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
    try std.testing.expectEqual(@as(usize, 5), (try writer.finish(codes)).language_records);
    // Only the meaningful prose/image prefix gains an unowned record. The
    // ordinary image-only page prefix remains shared by its two known owners.
    {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Unclassified"));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        try std.testing.expect((try index.find("prefix")) == null);
        const rec = (try index.find("prose-prefix")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, rec.payload, rec.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings("", decoded.entry.language_code);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.media.len);
        try std.testing.expectEqualStrings("Shared.svg", decoded.entry.media[0].file);
        try std.testing.expectEqualStrings("Shared label[1]", decoded.entry.media[0].caption);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
        var reference_text: std.ArrayList(u8) = .empty;
        for (decoded.entry.references[0].spans) |span| try reference_text.appendSlice(a, span.text);
        try std.testing.expectEqualStrings("caption reference", reference_text.items);
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            try visible.appendSlice(a, span.trail);
        };
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "visible prose"));
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "english") == null);
        try std.testing.expect(std.mem.indexOf(u8, visible.items, "french") == null);
    }
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
            if (std.mem.eql(u8, value, "الرومانية")) return .{ .code = "ro", .heading = "الرومانية" };
            if (std.mem.eql(u8, value, "الإنجليزية")) return .{ .code = "en", .heading = "الإنجليزية" };
            if (std.mem.eql(u8, value, "ألمانية")) return .{ .code = "de", .heading = "الألمانية" };
            if (std.mem.eql(u8, value, "إنجليزية")) return .{ .code = "en", .heading = "الإنجليزية" };
            if (std.mem.eql(u8, value, "عربية")) return .{ .code = "ar", .heading = "العربية" };
            return null;
        }
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
    };
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const exact = "[[فِي]] [[لُغَة|ٱللُّغَةِ]] [[كردي|ٱلْكُرْدِيَّةِ]]:";
    // cald p9815/r1106013, captured template p9663/r988308: case
    // endings are authored outside the language links, not part of the lemma.
    const cald_heading = "[[فِي]] [[لُغَة|ٱلْلُغَة]]ِ [[الرُّومَانِيَّة|ٱلرُّومَانِيَّة]]ِ:";
    try std.testing.expectEqualStrings("ro", resolveLinkedDeclaration(codes, cald_heading).?.code);
    for ([_][]const u8{
        "[[فِي]] [[لُغَة|ٱلْلُغَة]]ِ [[الرُّومَانِيَّة|الإنجليزية]]ِ:",
        "[[فِي]] [[لُغَة|ٱلْلُغَة]]ِ [[مجهولة|مجهولة]]ِ:",
        "[[فِي]] [[لُغَة|ٱلْلُغَة]]ِ [[الرُّومَانِيَّة|ٱلرُّومَانِيَّة]]ِ: trailing",
        "[[فِي]] [[لُغَة|ٱلْلُغَة]]x [[الرُّومَانِيَّة|ٱلرُّومَانِيَّة]]ِ:",
        "[[فِي]] [[لُغَة|ٱلْلُغَة]] ِ[[الرُّومَانِيَّة|ٱلرُّومَانِيَّة]]ِ:",
        "topic [[الرُّومَانِيَّة]]ِ:",
    }) |negative| try std.testing.expect(resolveLinkedDeclaration(codes, negative) == null);
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
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/cald", .{tmp.sub_path});
        var writer = try Writer.init(std.testing.io, alloc, root);
        defer writer.deinit();
        writer.language_codes = codes;
        const expanded = "=" ++ cald_heading ++ "=\n\n[[تصنيف:رومانية]]\n[[تصنيف:لغة رومانية]]\n=== صفة ===\n* [[حار]]\n";
        try writer.addExpandedPage(alloc, .{ .id = 0, .kind = .language }, "cald", expanded, "{{رومانية}}\n\n=== صفة ===\n* [[حار]]", null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(alloc, root, "الرومانية"));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings("ro", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(alloc);
        defer index.deinit(alloc);
        const record = (try index.find("cald")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(alloc, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("ro", decoded.entry.language_code);
        var definitions: usize = 0;
        var actions: usize = 0;
        var pos: usize = 0;
        for (decoded.entry.sections) |section| {
            if (std.mem.eql(u8, section.title, "صفة")) pos += 1;
            for (section.blocks) |block| for (block.spans) |span| {
                if (std.mem.eql(u8, span.text, "حار")) definitions += 1;
                if (std.mem.eql(u8, span.target, "حار")) actions += 1;
            };
        }
        try std.testing.expectEqual(@as(usize, 1), pos);
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), actions);
    }
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

test "typed unowned prefix emptiness ignores invisible-only render results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").englishTestRegistry(a);
    defer namespaces.deinit();
    // The renderer's generated language section is level2, not level0.
    // Only authored heading spans count when its blocks contain no content.
    const cases = .{
        .{ "", false },
        .{ " \n", false },
        .{ "<!-- hidden -->\n[[Category:Hidden]]\n__NOEDITSECTION__\n", false },
        .{ "==Unclassified==\n", true },
        .{ "===Authored heading===\n", true },
        .{ "[[sun]]", true },
        .{ "<nowiki>__NOEDITSECTION__</nowiki>", true },
        .{ "----\n", true },
        .{ "{|\n| [[sun]]\n|}\n", true },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("PREFIX_CONTENT_CASE source={s}\n", .{case[0]});
        try std.testing.expectEqual(case[1], try presentation_document.hasBodyContentWithReferencesAndPoemFragmentsAlloc(
            a,
            "probe",
            "Unclassified",
            case[0],
            .{},
            &namespaces,
            null,
            null,
            .{},
            null,
            &.{},
        ));
    }
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
        fn ambiguous(_: ?*const anyopaque, heading: []const u8) bool {
            return std.mem.eql(u8, heading, "Frencisc") or
                std.mem.eql(u8, heading, "Middelhēahþēodisc") or
                std.mem.eql(u8, heading, "English");
        }
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
    const codes: LanguageCodes = .{ .namespace_catalog = &namespaces, .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve, .boundary_fn = Local.ambiguous };
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
    // saule p158979/r1068128: category-only first wrapper plus unresolved
    // declaration leaves two authored sun definitions before the French L2.
    const saule_prefix = "[[تصنيف:لاتفية]]\n=== اسم ===\n* كوكب ال[[شمس]]\n=== اسم ===\n* كوكب ال[[شمس]]\n==French==\n# [[صفصاف]]\n==Unknown topic==\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "saule-prefix", saule_prefix, saule_prefix, null);
    const invisible_prefix = "<!-- no content -->\n[[تصنيف:لاتفية]]\n__NOEDITSECTION__\n==French==\n# kept\n==Unknown topic==\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "invisible-prefix", invisible_prefix, invisible_prefix, null);
    // Retained Template:also module-derived output for authored {{أيضا|مِنْجَار}}.
    const hatnote = "<div class=\"disambig-see-also\">''انظر أيضًا:'' '''[[مِنْجَار]]'''</div>\n";
    const later_unknown = "==عربية==\n# known body\n==Unknown topic==\n# unknown body\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "hatnote-warning", hatnote ++ later_unknown, "{{أيضا|مِنْجَار}}\n" ++ later_unknown, null);
    // Page-wide context is shared once per owner, including an unknown owner;
    // lexical bodies still follow their own exact resolved/unknown boundaries.
    const multilingual_hatnote = "<div class=\"disambig-see-also\">''انظر أيضًا:'' '''[[M]]'''</div>\n";
    const hatnote_owners = "==English==\n# EN_FIRST\n==French==\n# FR_ONLY\n==English==\n# EN_REPEATED\n==لغة مجهولة==\n# UNKNOWN_ONLY\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "hatnote-multilingual", multilingual_hatnote ++ hatnote_owners, "{{أيضا|M}}\n" ++ hatnote_owners, null);
    inline for (.{
        .{ "hatnote-prose", hatnote ++ "unscoped prefix\n" },
        .{ "hatnote-partial", "<div class=\"disambig-see-also\">''انظر أيضًا:'' '''[[مِنْجَار]]'''\n" },
        .{ "hatnote-unrelated", "<div class=\"disambig-see-also-other\">[[مِنْجَار]]</div>\n" },
    }) |row| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row[0], row[1] ++ later_unknown, row[1] ++ later_unknown, null);
    inline for (.{
        .{ "boundary-leading", "==Middelhēahþēodisc==\n# [[FOREIGN_ACTION|FOREIGN_BODY]]\n==English==\n# [[KNOWN_ACTION|KNOWN_BODY]]\n" },
        .{ "boundary-trailing", "==English==\n# [[KNOWN_ACTION|KNOWN_BODY]]\n==Middelhēahþēodisc==\n# [[FOREIGN_ACTION|FOREIGN_BODY]]\n" },
        .{ "ambiguous-leading", "==Frencisc==\n# [[FOREIGN_ACTION|FOREIGN_BODY]]\n==English==\n# [[KNOWN_ACTION|KNOWN_BODY]]\n" },
        .{ "ambiguous-trailing", "==English==\n# [[KNOWN_ACTION|KNOWN_BODY]]\n==Frencisc==\n# [[FOREIGN_ACTION|FOREIGN_BODY]]\n" },
    }) |row| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row[0], row[1], row[1], null);
    _ = try writer.finish(codes);
    inline for (.{ "ambiguous-leading", "ambiguous-trailing", "boundary-leading", "boundary-trailing" }) |title| {
        const unknown = try Local.entry(a, root_path, "Unclassified", title);
        const known = try Local.entry(a, root_path, "English", title);
        try std.testing.expectEqualStrings("", unknown.language_code);
        try std.testing.expectEqualStrings("en", known.language_code);
        const unknown_text = try Local.text(a, unknown);
        const known_text = try Local.text(a, known);
        try std.testing.expect(std.mem.indexOf(u8, unknown_text, "FOREIGN_BODY") != null);
        try std.testing.expect(std.mem.indexOf(u8, unknown_text, "KNOWN_BODY") == null);
        try std.testing.expect(std.mem.indexOf(u8, known_text, "KNOWN_BODY") != null);
        try std.testing.expect(std.mem.indexOf(u8, known_text, "FOREIGN_BODY") == null);
        var foreign_actions: usize = 0;
        var known_actions: usize = 0;
        for (unknown.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, "FOREIGN ACTION")) foreign_actions += 1;
            try std.testing.expect(!std.mem.eql(u8, span.target, "KNOWN ACTION"));
        };
        for (known.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, "KNOWN ACTION")) known_actions += 1;
            try std.testing.expect(!std.mem.eql(u8, span.target, "FOREIGN ACTION"));
        };
        try std.testing.expectEqual(@as(usize, 1), foreign_actions);
        try std.testing.expectEqual(@as(usize, 1), known_actions);
    }

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
    inline for (.{ .{ "English", "multilingual" }, .{ "French", "multilingual" }, .{ "English", "unknown-group" }, .{ "English", "inherited-unknown" }, .{ "English", "pending-unknown" } }) |row| {
        std.debug.print("QATAR_NEGATIVE owner={s} title={s}\n", .{ row[0], row[1] });
        const entry_value = try Local.entry(a, root_path, row[0], row[1]);
        try std.testing.expect(std.mem.indexOf(u8, try Local.text(a, entry_value), "unscoped prefix") == null);
    }
    inline for (.{ "multilingual", "unknown-group", "inherited-unknown", "pending-unknown" }) |title| {
        errdefer std.debug.print("UNOWNED_PREFIX_FAILED title={s}\n", .{title});
        const unowned = try Local.entry(a, root_path, "Unclassified", title);
        const text = try Local.text(a, unowned);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "unscoped prefix"));
        try std.testing.expect(std.mem.indexOf(u8, text, "english") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "french") == null);
    }
    std.debug.print("PREFIX_STAGE sun-actions\n", .{});
    const saule_unowned = try Local.entry(a, root_path, "Unclassified", "saule-prefix");
    var sun_actions: usize = 0;
    for (saule_unowned.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "شمس")) {
            try std.testing.expectEqualStrings("*", block.list_path);
            sun_actions += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), sun_actions);
    const saule_french = try Local.entry(a, root_path, "French", "saule-prefix");
    const french_text = try Local.text(a, saule_french);
    try std.testing.expect(std.mem.indexOf(u8, french_text, "صفصاف") != null);
    try std.testing.expect(std.mem.indexOf(u8, french_text, "شمس") == null);
    std.debug.print("PREFIX_STAGE invisible-prefix\n", .{});
    const empty_entry = try Local.entry(a, root_path, "French", "invisible-prefix");
    try std.testing.expect(std.mem.indexOf(u8, try Local.text(a, empty_entry), "kept") != null);
    var unowned_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root_path, "Unclassified"));
    defer unowned_map.deinit();
    const unowned_blob = try blob_format.inspect(unowned_map.bytes);
    var unowned_index = try unowned_blob.buildTrustedIndexAlloc(a);
    defer unowned_index.deinit(a);
    try std.testing.expect((try unowned_index.find("invisible-prefix")) == null);
    std.debug.print("PREFIX_STAGE hatnote-warning\n", .{});
    const hatnote_entry = try Local.entry(a, root_path, "العربية", "hatnote-warning");
    var hatnote_target = false;
    for (hatnote_entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "مِنْجَار") and span.bold) hatnote_target = true;
    };
    try std.testing.expect(hatnote_target);
    const hatnote_text = try Local.text(a, hatnote_entry);
    try std.testing.expect(std.mem.indexOf(u8, hatnote_text, "known body") != null);
    try std.testing.expect(std.mem.indexOf(u8, hatnote_text, "unknown body") != null);
    inline for (.{ "hatnote-prose", "hatnote-partial", "hatnote-unrelated" }) |title| {
        const entry_value = try Local.entry(a, root_path, "العربية", title);
        try std.testing.expect(std.mem.indexOf(u8, try Local.text(a, entry_value), "مِنْجَار") == null);
    }
    inline for (.{ "English", "French", "Unclassified" }) |owner| {
        const entry_value = try Local.entry(a, root_path, owner, "hatnote-multilingual");
        var global_actions: usize = 0;
        for (entry_value.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, "M")) {
                try std.testing.expect(span.bold);
                global_actions += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), global_actions);
        const owner_text = try Local.text(a, entry_value);
        inline for (.{ "EN_FIRST", "EN_REPEATED", "FR_ONLY", "UNKNOWN_ONLY" }) |body| {
            const belongs = if (std.mem.eql(u8, owner, "English"))
                std.mem.startsWith(u8, body, "EN_")
            else if (std.mem.eql(u8, owner, "French"))
                std.mem.eql(u8, body, "FR_ONLY")
            else
                std.mem.eql(u8, body, "UNKNOWN_ONLY");
            try std.testing.expectEqual(belongs, std.mem.indexOf(u8, owner_text, body) != null);
        }
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, owner, "Unclassified")) "" else if (std.mem.eql(u8, owner, "English")) "en" else "fr", entry_value.language_code);
    }
    const prefix_report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root_path, "fallback-pages.jsonl" }), a, .unlimited);
    var report_lines = std.mem.splitScalar(u8, prefix_report, '\n');
    var hatnote_warning = false;
    var multilingual_warning = false;
    var boundary_warnings: usize = 0;
    while (report_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "ambiguous-leading") != null or
            std.mem.indexOf(u8, line, "ambiguous-trailing") != null or
            std.mem.indexOf(u8, line, "boundary-leading") != null or
            std.mem.indexOf(u8, line, "boundary-trailing") != null)
        {
            try std.testing.expect(std.mem.indexOf(u8, line, "unresolved_language_heading") != null);
            boundary_warnings += 1;
        }
        if (std.mem.indexOf(u8, line, "hatnote-warning") != null) {
            hatnote_warning = std.mem.indexOf(u8, line, "unresolved_language_heading") != null;
        }
        if (std.mem.indexOf(u8, line, "hatnote-multilingual") != null) {
            multilingual_warning = std.mem.indexOf(u8, line, "unresolved_language_heading") != null;
        }
    }
    try std.testing.expect(hatnote_warning);
    try std.testing.expect(multilingual_warning);
    try std.testing.expectEqual(@as(usize, 4), boundary_warnings);
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

test "unmatched extension openers preserve published language owners" {
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
    for ([_][]const u8{ "pre", "source", "syntaxhighlight", "ref", "math", "gallery", "poem" }) |tag| {
        const source = try std.fmt.allocPrint(a, "==English==\n# [[cat|English sense]]\n<{s}>unclosed\n==French==\n# [[chat|French sense]]\n", .{tag});
        try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, tag, source, source, null, &.{});
        const closed = try std.fmt.allocPrint(a, "==English==\n# [[cat|English sense]]\n<{s}>\n==French==\n# [[chat|literal French sense]]\n</{s}>\n", .{ tag, tag });
        const closed_title = try std.fmt.allocPrint(a, "closed-{s}", .{tag});
        try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, closed_title, closed, closed, null, &.{});
    }
    // Inclusion preprocessing can remove a raw tail; it must not publish its
    // raw French heading as a rendered owner.
    const inclusion_raw = "==English==\n# [[cat|English sense]]\n<includeonly>\n==French==\n# [[chat|excluded French sense]]\n";
    const inclusion_expanded = "==English==\n# [[cat|English sense]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "included-tail", inclusion_expanded, inclusion_raw, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 22), stats.language_records);
    inline for (.{ .{ "English", "cat", "English sense", "chat" }, .{ "French", "chat", "French sense", "cat" } }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, owner[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for ([_][]const u8{ "pre", "source", "syntaxhighlight", "ref", "math", "gallery", "poem" }) |tag| {
            const record = (try index.find(tag)).?;
            const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            var matched: usize = 0;
            for (decoded.entry.sections) |section| for (section.blocks) |block_value| for (block_value.spans) |span| {
                if (span.kind == .link and std.mem.eql(u8, span.target, owner[1]) and std.mem.eql(u8, span.text, owner[2])) matched += 1;
                try std.testing.expect(span.kind != .link or !std.mem.eql(u8, span.target, owner[3]));
            };
            try std.testing.expectEqual(@as(usize, 1), matched);
            const closed_title = try std.fmt.allocPrint(a, "closed-{s}", .{tag});
            const closed_record = try index.find(closed_title);
            if (std.mem.eql(u8, owner[0], "French")) try std.testing.expect(closed_record == null) else try std.testing.expect(closed_record != null);
        }
        const inclusion_record = try index.find("included-tail");
        if (std.mem.eql(u8, owner[0], "French")) try std.testing.expect(inclusion_record == null) else try std.testing.expect(inclusion_record != null);
    }
}

// Live raw source retrieved2026-10-15, not October dump/revision equality.
const ArabicMeaningsCategoryFixture = struct {
    const body = "== المعاني ==\n# [[cat|Retained definition]]\n";
    const category = "[[تصنيف:إنجليزية]]\n";
    const source = body ++ category;
    const bit_source = "== المعاني ==\n# ال[[لِجَام]]، قطعة من معدن توضع في فم الحصان أو غيره وتربط بال[[سَيْر]].\n# آلة معدنية تَدُور تربط بال[[مِثْقَاب]]، تستخدم لل[[ثَقْب]].\n# جزء من ثمانية أجزاء من ال[[دُولار]]. استخدام قديم وحاليا لا يوجد قطعة نقدية مثل هذه.\n# [[جُزْء]] من شيء، سواء كان كبيرا أو صغيرا.\n# ال[[قَلِيل]] جدا، ال[[قُلَيْل]] أو ال[[شُوَيَّة]] أو ال[[شُوَيُّونَة]]\n\n[[تصنيف:إنجليزية]]";
    fn namespaces(a: std.mem.Allocator) !@import("namespace_registry").Registry {
        return @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
            "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
            "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
            "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    }
    fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        inline for (.{ .{ "إنجليزية", "en", "الإنجليزية" }, .{ "الإنجليزية", "en", "الإنجليزية" }, .{ "English", "en", "الإنجليزية" }, .{ "untrusted English", "en", "الإنجليزية" }, .{ "فرنسية", "fr", "French" }, .{ "French", "fr", "French" }, .{ "العربية", "ar", "العربية" } }) |entry|
            if (std.mem.eql(u8, value, entry[0])) return .{ .code = entry[1], .heading = entry[2] };
        return null;
    }
    fn trusted(ctx: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        if (std.mem.eql(u8, value, "untrusted English")) return null;
        return resolve(ctx, value);
    }
    fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
        return if (resolve(ctx, value)) |language| language.code else null;
    }
    fn content(_: ?*const anyopaque) ?ResolvedLanguage {
        return .{ .code = "ar", .heading = "العربية" };
    }
    fn codes(ns: *const @import("namespace_registry").Registry) LanguageCodes {
        // Production tools/blob_build.zig275–286 also installs an explicit
        // Registry.resolveTrusted/resolveStrong callback, not permissive get.
        return .{ .namespace_catalog = ns, .get_fn = get, .resolve_fn = resolve, .trusted_fn = trusted, .content_fn = content };
    }
};

test "Arabic corroborated meanings category publishes its whole English entry through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = ArabicMeaningsCategoryFixture;
    var namespaces = try F.namespaces(a);
    defer namespaces.deinit();
    const codes = F.codes(&namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "bit", F.bit_source, F.bit_source, null);
    const pos = F.body ++ "=== اسم ===\n# [[tail|Tail survives]]\n" ++ F.category;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ordinary-pos", pos, pos, null);
    const protected = F.body ++ "<nowiki>\n===French===\n</nowiki>\n<!--\n=== {{اللغة|Unlisted spelling}} ===\n-->\n" ++ F.category;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "protected-headings", protected, protected, null);
    const html_pre = F.body ++ "<pre/ data=x>" ++ F.category ++ "</pre>\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "html-pre-category", html_pre, html_pre, null);
    try writer.addPageWithFallback(a, .{ .id = 0, .kind = .language }, "preserved-warning", F.source, null, .{ .malformed_table = true, .unresolved_language_heading = true });
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 5), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "الإنجليزية"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("en", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    for ([_][]const u8{ "bit", "ordinary-pos", "protected-headings", "html-pre-category", "preserved-warning" }) |title| {
        const record = (try index.find(title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("en", decoded.entry.language_code);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, "المعاني") != null);
        if (std.mem.eql(u8, title, "bit")) {
            for ([_][]const u8{ "لِجَام", "مِثْقَاب", "دُولار", "قُلَيْل" }) |target| {
                var found = false;
                for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                    if (span.kind == .link and std.mem.eql(u8, span.target, target)) found = true;
                };
                try std.testing.expect(found);
            }
        }
        if (std.mem.eql(u8, title, "ordinary-pos")) try std.testing.expect(std.mem.indexOf(u8, record.payload, "Tail survives") != null);
    }
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, report, "preserved-warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "malformed_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "unresolved_language_heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "missing_language_heading") == null);
}

test "Arabic meanings category refuses uncorroborated ambiguous protected and nested declarations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = ArabicMeaningsCategoryFixture;
    var namespaces = try F.namespaces(a);
    defer namespaces.deinit();
    const codes = F.codes(&namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const cases = [_]struct { title: []const u8, expanded: []const u8, raw: ?[]const u8 = null }{
        .{ .title = "absent-category", .expanded = F.body },
        .{ .title = "topic-only", .expanded = F.body ++ "[[تصنيف:أثاث]]" },
        .{ .title = "translations-only", .expanded = F.body ++ "{{en}} {{t|en|word}}" },
        .{ .title = "comment-category", .expanded = F.body ++ "<!--" ++ F.category ++ "-->" },
        .{ .title = "nowiki-category", .expanded = F.body ++ "<nowiki>" ++ F.category ++ "</nowiki>" },
        .{ .title = "pre-category", .expanded = F.body ++ "<pre>" ++ F.category ++ "</pre>" },
        .{ .title = "source-category", .expanded = F.body ++ "<source>" ++ F.category ++ "</source>" },
        .{ .title = "escaped-category", .expanded = F.body ++ "[[:تصنيف:إنجليزية]]" },
        .{ .title = "ordinary-link", .expanded = F.body ++ "[[إنجليزية]]" },
        .{ .title = "untrusted-alias", .expanded = F.body ++ "[[تصنيف:untrusted English]]" },
        .{ .title = "ambiguous", .expanded = F.source ++ "[[تصنيف:فرنسية]]" },
        .{ .title = "different-category", .expanded = F.body ++ "[[تصنيف:فرنسية]]", .raw = F.source },
        .{ .title = "expanded-only-category", .expanded = F.source, .raw = F.body },
        .{ .title = "raw-only-category", .expanded = F.body, .raw = F.source },
        .{ .title = "missing-raw", .expanded = F.source, .raw = "" },
        .{ .title = "unknown-raw-heading", .expanded = F.source, .raw = "== Unknown ==\n# Retained definition\n" ++ F.category },
        .{ .title = "unknown-expanded-heading", .expanded = "== Unknown ==\n# Retained definition\n" ++ F.category, .raw = F.source },
        .{ .title = "extra-unknown-boundary", .expanded = F.source ++ "== Notes ==\nRetained tail" },
        .{ .title = "known-nested-language", .expanded = F.body ++ "===French===\n# Retained foreign definition\n" ++ F.category },
        .{ .title = "deep-known-language", .expanded = F.body ++ "======French======\n# Retained foreign definition\n" ++ F.category },
        .{ .title = "explicit-unknown-nested", .expanded = F.body ++ "=== {{اللغة|Unlisted spelling}} ===\n# Retained unknown definition\n" ++ F.category },
        .{ .title = "explicit-nested-raw-only", .expanded = F.source, .raw = F.body ++ "=== {{اللغة|Unlisted spelling}} ===\n# Retained unknown definition\n" ++ F.category },
        .{ .title = "nonempty-prefix", .expanded = "Retained unscoped prefix\n" ++ F.source },
    };
    for (cases) |case| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, case.expanded, case.raw orelse case.expanded, null);
    const foreign = F.body ++ "==French==\n# [[chien|Foreign definition]]\n" ++ F.category;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "explicit-foreign", foreign, foreign, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, cases.len + 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Unclassified"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    for (cases) |case| {
        const record = (try index.find(case.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("", decoded.entry.language_code);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, "Retained") != null);
    }
    var foreign_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "French"));
    defer foreign_map.deinit();
    const foreign_blob = try blob_format.inspect(foreign_map.bytes);
    const foreign_metadata = try foreign_blob.languageMetadata();
    try std.testing.expectEqualStrings("fr", foreign_metadata.code);
    var foreign_index = try foreign_blob.buildTrustedIndexAlloc(a);
    defer foreign_index.deinit(a);
    const record = (try foreign_index.find("explicit-foreign")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, foreign_metadata);
    try std.testing.expectEqualStrings("fr", decoded.entry.language_code);
    try std.testing.expect(std.mem.indexOf(u8, record.payload, "Foreign definition") != null);
}

test "Writer language fragments preserve parsed pre scope through DPR2" {
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
    const cases = [_]struct { title: []const u8, source: []const u8, french_code: bool, retained_state: bool = false, quoted: bool = false, inherited_bold: bool = false, nested: bool = false, whitespace: bool = false, unclosed: bool = false }{
        .{ .title = "fragment-pre", .source = "==English==\n<pre/ >\n[[cat]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true },
        .{ .title = "inline-fragment-pre", .source = "==English==\nprefix <pre/ >[[cat]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true },
        .{ .title = "protected-fragment-pre", .source = "==English==\n<pre/ >\n[[cat]]\n==French==\n<nowiki></pre></nowiki><source></pre></source>[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true },
        .{ .title = "stateful-fragment-pre", .source = "==English==\n<pre/ >\n[[cat]]<ref name=keep>alpha</ref>[[File:One.png]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]<ref name=keep/><ref>beta</ref>[[File:Two.png]]\n", .french_code = true, .retained_state = true },
        .{ .title = "page-prefix-pre", .source = "<pre/ >\n==English==\n[[cat]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true },
        .{ .title = "quoted-prefix-pre", .source = "==English==\n'''bold <pre/ >[[cat]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true, .quoted = true },
        .{ .title = "inherited-bold-pre", .source = "==English==\n<b>\n<pre/ >\n[[cat]]\n==French==\n[[chat]]\n</pre>\n</b>[[chien]]\n==English==\n[[dog]]\n", .french_code = true, .inherited_bold = true },
        .{ .title = "nested-block-pre", .source = "==English==\n<pre/ >outer\n<pre/ >[[cat]]\n==French==\n[[chat]]</pre>\n* [[middle]]\n</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true, .nested = true },
        .{ .title = "whitespace-fragment-pre", .source = "==English==\n<pre/ >\n[[cat]]  \tA  \n\n==French==\n[[chat]]  \tB  \n</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = true, .whitespace = true },
        .{ .title = "malformed-fragment-pre", .source = "==English==\n<pre/ >\n[[cat]]\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]<math>bad\n", .french_code = true, .unclosed = true },
        // A table cell is a local inline domain in the complete renderer.
        // Its parsed pre cannot extend to the later page-level closing tag.
        // That cell-local opener is genuinely unclosed in its own domain.
        .{ .title = "cell-local-pre", .source = "==English==\n<table><tr><td><pre/ >[[cat]]</td></tr></table>\n==French==\n[[chat]]</pre> [[chien]]\n==English==\n[[dog]]\n", .french_code = false, .unclosed = true },
    };
    for (cases) |case| try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.source, null, &.{});
    const opaque_source = "==English==\n<pre>\n==French==\n[[chat]]\n</pre>\n[[dog]]\n";
    try writer.addExpandedPageWithReasons(a, .{ .id = 0, .kind = .language }, "opaque-pre-control", opaque_source, opaque_source, null, &.{});
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(cases.len * 2 + 1, stats.language_records);
    var fallback_map = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ out_root, "fallback-pages.jsonl" }));
    defer fallback_map.deinit();
    var lines = std.mem.splitScalar(u8, fallback_map.bytes, '\n');
    var diagnosed_malformed = false;
    var diagnosed_cell = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const reported_title = parsed.value.object.get("title").?.string;
        var unclosed = false;
        for (parsed.value.object.get("reasons").?.array.items) |reason|
            unclosed = unclosed or std.mem.eql(u8, reason.string, "unclosed_formatting");
        for (cases) |case| if (std.mem.eql(u8, case.title, reported_title)) {
            try std.testing.expectEqual(case.unclosed, unclosed);
            if (case.unclosed and std.mem.eql(u8, case.title, "malformed-fragment-pre")) diagnosed_malformed = true;
            if (case.unclosed and std.mem.eql(u8, case.title, "cell-local-pre")) diagnosed_cell = true;
        };
    }
    try std.testing.expect(diagnosed_malformed);
    try std.testing.expect(diagnosed_cell);
    for ([_][]const u8{ "English", "French" }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for (cases) |case| {
            const record = (try index.find(case.title)).?;
            const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            const english = std.mem.eql(u8, owner, "English");
            if (case.retained_state and english) {
                try std.testing.expectEqual(@as(usize, 2), decoded.entry.references.len);
                try std.testing.expectEqualStrings("keep", decoded.entry.references[0].name);
                try std.testing.expectEqual(@as(usize, 1), decoded.entry.references[0].number);
                try std.testing.expectEqual(@as(usize, 2), decoded.entry.references[1].number);
                var reference_text: std.ArrayList(u8) = .empty;
                for (decoded.entry.references[0].spans) |span| try reference_text.appendSlice(a, span.text);
                try std.testing.expectEqualStrings("alpha", reference_text.items);
                reference_text.clearRetainingCapacity();
                for (decoded.entry.references[1].spans) |span| try reference_text.appendSlice(a, span.text);
                try std.testing.expectEqualStrings("beta", reference_text.items);
                try std.testing.expectEqual(@as(usize, 2), decoded.entry.media.len);
                try std.testing.expectEqualStrings("One.png", decoded.entry.media[0].file);
                try std.testing.expectEqualStrings("Two.png", decoded.entry.media[1].file);
            }
            const expected = if (english) [_][]const u8{ "cat", "dog" } else [_][]const u8{ "chat", "chien" };
            var counts = [_]usize{ 0, 0 };
            var middle_count: usize = 0;
            var code_text: std.ArrayList(u8) = .empty;
            for (decoded.entry.sections) |section| for (section.blocks) |block_value| {
                for (block_value.spans) |span| {
                    if (span.code) try code_text.appendSlice(a, span.text);
                    if (span.kind == .link and std.mem.eql(u8, span.target, "middle")) {
                        try std.testing.expect(case.nested and !english);
                        try std.testing.expect(block_value.kind == .list_item);
                        try std.testing.expect(span.code);
                        middle_count += 1;
                    }
                    if (span.kind != .link) continue;
                    for (expected, 0..) |target, i| if (std.mem.eql(u8, span.target, target)) {
                        counts[i] += 1;
                        try std.testing.expectEqual(i == 0 and (english or case.french_code), span.code);
                        try std.testing.expectEqual(i == 0 and (case.inherited_bold or (english and case.quoted)), span.bold);
                    };
                    if (english) try std.testing.expect(!std.mem.eql(u8, span.target, "chat") and !std.mem.eql(u8, span.target, "chien")) else try std.testing.expect(!std.mem.eql(u8, span.target, "cat") and !std.mem.eql(u8, span.target, "dog"));
                }
                if (block_value.table) |table| for (table.rows) |row| for (row.cells) |cell| for (cell.spans) |span| {
                    if (span.kind == .link and std.mem.eql(u8, span.target, "cat")) {
                        try std.testing.expect(english);
                        try std.testing.expect(span.code);
                        counts[0] += 1;
                    }
                };
            };
            try std.testing.expectEqual(@as(usize, 1), counts[0]);
            try std.testing.expectEqual(@as(usize, 1), counts[1]);
            try std.testing.expectEqual(@as(usize, if (case.nested and !english) 1 else 0), middle_count);
            if (case.whitespace) try std.testing.expect(std.mem.indexOf(u8, code_text.items, if (english) "cat  \tA  \n\n" else "chat  \tB  \n") != null);
        }
        const opaque_record = try index.find("opaque-pre-control");
        if (std.mem.eql(u8, owner, "French")) try std.testing.expect(opaque_record == null) else try std.testing.expect(opaque_record != null);
    }
}

test "unmatched template and link roots retain distinct published language bodies through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const english = "==English==\n# [[cat|English definition]]\n";
    const french = "==French==\n# [[chat|French definition]]\n===Verb===\n# [[v|French verb tail]]\n";
    const active = [_]struct { title: []const u8, middle: []const u8, following: []const u8 = french }{
        .{ .title = "broken-template", .middle = "{{open|\n" },
        .{ .title = "broken-link", .middle = "[[open\n" },
        .{ .title = "broken-template-inner", .middle = "{{open|\n{{closed|\n==French==\n# [[hidden|Hidden French definition]]\n}}\n" },
        .{ .title = "broken-link-inner", .middle = "[[open\n{{closed|\n==French==\nHidden French definition\n}}\n" },
        .{ .title = "broken-template-protected", .middle = "{{open|\n<nowiki>}}</nowiki>\n" },
        .{ .title = "broken-link-comment", .middle = "[[open\n<!-- ]] -->\n" },
        .{ .title = "balanced-link-heading", .middle = "[[Target|\n", .following = "==French==\n]]\n# [[chat|French definition]]\n===Verb===\n# [[v|French verb tail]]\n" },
        .{ .title = "balanced-link-inner-template", .middle = "[[Target|\n{{closed|\n==German==\nHidden German definition\n}}\n", .following = "==French==\n]]\n# [[chat|French definition]]\n===Verb===\n# [[v|French verb tail]]\n" },
    };
    for (active) |case| {
        const source = try std.mem.concat(a, u8, &.{ english, case.middle, case.following });
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, source, source, null);
    }
    const protected = [_]struct { title: []const u8, middle: []const u8 }{
        .{ .title = "balanced-template", .middle = "{{closed|\n==French==\nHidden French definition\n}}\n" },
        .{ .title = "balanced-parameter", .middle = "{{{value|\n==French==\nHidden French definition\n}}}\n" },
    };
    for (protected) |case| {
        const source = try std.mem.concat(a, u8, &.{ english, case.middle, "# English tail\n" });
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, source, source, null);
    }
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, active.len * 2 + protected.len), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    inline for (.{ .{ "English", "en", "cat", "chat" }, .{ "French", "fr", "chat", "cat" } }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(owner[1], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for (active) |case| {
            const record = (try index.find(case.title)).?;
            const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expectEqualStrings(owner[1], decoded.entry.language_code);
            var expected_link = false;
            var verb = false;
            for (decoded.entry.sections) |section| {
                verb = verb or std.mem.eql(u8, section.title, "Verb");
                for (section.blocks) |block| for (block.spans) |span| if (span.kind == .link) {
                    expected_link = expected_link or std.mem.eql(u8, span.target, owner[2]);
                    try std.testing.expect(!std.mem.eql(u8, span.target, owner[3]));
                };
            }
            try std.testing.expect(expected_link);
            if (std.mem.eql(u8, owner[1], "fr")) {
                try std.testing.expect(verb);
                try std.testing.expect(std.mem.indexOf(u8, record.payload, "French verb tail") != null);
                try std.testing.expect(std.mem.indexOf(u8, record.payload, "Hidden French definition") == null);
            }
        }
        for (protected) |case| {
            if (std.mem.eql(u8, owner[1], "fr")) try std.testing.expect((try index.find(case.title)) == null) else {
                const record = (try index.find(case.title)).?;
                const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
                try std.testing.expectEqualStrings("en", decoded.entry.language_code);
                try std.testing.expect(std.mem.indexOf(u8, record.payload, "English tail") != null);
            }
        }
    }
}

test "Writer ordinary multiline links retain heading navigation without category or caption owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const ordinary = [_]struct { title: []const u8, authored: []const u8, target: []const u8 }{
        .{ .title = "ordinary-linked-owner", .authored = "Target", .target = "Target" },
        .{ .title = "escaped-category-linked-owner", .authored = ":Category:English_nouns", .target = "Category:English nouns" },
        .{ .title = "escaped-file-linked-owner", .authored = ":File:Example.jpg", .target = "File:Example.jpg" },
    };
    for (ordinary) |case| {
        const source = try std.fmt.allocPrint(a, "==English==\nEnglish only\n[[{s}|\n==French==\nFrench body\n]]\nOutside body\n", .{case.authored});
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, source, source, null);
    }
    const local = [_]struct { title: []const u8, source: []const u8, file: bool }{
        .{ .title = "category-local-heading", .source = "==English==\nEnglish only\n[[Category:English nouns|\n==French==\nHidden sort key\n]]\nOutside body\n", .file = false },
        .{ .title = "caption-local-heading", .source = "==English==\nEnglish only\n[[File:Example.jpg|thumb|80px|\n==French==\nCaption body\n]]\nOutside body\n", .file = true },
    };
    for (local) |case| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, ordinary.len * 2 + local.len), stats.language_records);
    for ([_][]const u8{ "English", "French" }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const french = std.mem.eql(u8, owner, "French");
        for (ordinary) |case| {
            const record = (try index.find(case.title)).?;
            const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expectEqual(@as(usize, 0), page.entry.media.len);
            var heading_count: usize = 0;
            var linked_body = false;
            var outside = false;
            for (page.entry.sections) |section| {
                for (section.blocks) |block| for (block.spans) |span| {
                    if (std.mem.eql(u8, span.text, "French")) {
                        try std.testing.expect(french);
                        try std.testing.expectEqualStrings("French", section.title);
                        try std.testing.expectEqual(@as(u8, 2), section.level);
                        try std.testing.expect(block.kind == .heading);
                        try std.testing.expectEqual(@as(u8, 2), block.level);
                        try std.testing.expect(span.kind == .link);
                        try std.testing.expectEqualStrings(case.target, span.target);
                        heading_count += 1;
                    }
                    if (std.mem.indexOf(u8, span.text, "French body") != null) {
                        try std.testing.expect(french);
                        try std.testing.expect(span.kind == .link);
                        try std.testing.expectEqualStrings(case.target, span.target);
                        linked_body = true;
                    }
                    if (std.mem.indexOf(u8, span.text, "Outside body") != null) {
                        try std.testing.expect(french);
                        try std.testing.expect(span.kind == .text);
                        outside = true;
                    }
                    if (!french) try std.testing.expect(std.mem.indexOf(u8, span.text, "English only") != null or span.text.len == 0);
                };
            }
            try std.testing.expectEqual(@as(usize, if (french) 1 else 0), heading_count);
            try std.testing.expectEqual(french, linked_body);
            try std.testing.expectEqual(french, outside);
        }
        for (local) |case| {
            if (french) {
                try std.testing.expect((try index.find(case.title)) == null);
                continue;
            }
            const record = (try index.find(case.title)).?;
            const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expect(std.mem.indexOf(u8, record.payload, "Outside body") != null);
            try std.testing.expect(std.mem.indexOf(u8, record.payload, "Hidden sort key") == null);
            try std.testing.expectEqual(@as(usize, if (case.file) 1 else 0), page.entry.media.len);
            if (case.file) {
                try std.testing.expectEqualStrings("Example.jpg", page.entry.media[0].file);
                try std.testing.expect(std.mem.indexOf(u8, page.entry.media[0].caption, "Caption body") != null);
            }
        }
    }
}

test "Writer publishes authored table group literals with cells links and fallback evidence" {
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
    const cases = [_]struct { title: []const u8, source: []const u8, outside: []const u8, cell: []const u8, label: []const u8, rows: usize }{
        .{
            .title = "authored-table-groups",
            .source = "==English==\n<table>before<thead><tr><th>head</th></tr></thead><tbody><tr><td>[[cat|body]]</td></tr></tbody><tfoot><tr><td>tail</td></tr></tfoot>after</table>",
            .outside = "before<thead></thead><tbody></tbody><tfoot></tfoot>after",
            .cell = "body",
            .label = "body",
            .rows = 3,
        },
        .{
            .title = "authored-cell-group",
            .source = "==English==\n<table>before<TBODY data-x='keep  &amp; value'><tr><td>in<TFOOT title=\"cell\">[[cat|cell]]</TFOOT>out</td></tr></TBODY>after</table>",
            .outside = "before<TBODY data-x='keep  & value'></TBODY>after",
            .cell = "in<TFOOT title=\"cell\">cell</TFOOT>out",
            .label = "cell",
            .rows = 1,
        },
        .{
            .title = "authored-translations-group",
            .source = "==English==\n<table class=\"translations\"><tbody><tr><td>[[cat|inside]]</td></tr></tbody></table>",
            .outside = "<tbody></tbody>",
            .cell = "inside",
            .label = "inside",
            .rows = 1,
        },
    };
    for (cases) |case| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 3), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 3), stats.fallback_pages);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "English"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("en", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    for (cases, 0..) |case, case_index| {
        const record = (try index.find(case.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("en", decoded.entry.language_code);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
        const blocks = decoded.entry.sections[0].blocks;
        try std.testing.expectEqual(@as(usize, 2), blocks.len);
        try std.testing.expectEqual(blobs.presentation_types.BlockKind.paragraph, blocks[0].kind);
        var outside: std.ArrayList(u8) = .empty;
        for (blocks[0].spans) |span| {
            try std.testing.expectEqual(blobs.presentation_types.InlineKind.text, span.kind);
            try outside.appendSlice(a, span.text);
            try std.testing.expectEqualStrings("", span.target);
            try std.testing.expectEqualStrings("", span.trail);
        }
        try std.testing.expectEqualStrings(case.outside, outside.items);
        const table = blocks[1].table.?;
        try std.testing.expectEqual(case.rows, table.rows.len);
        for (table.rows) |row| try std.testing.expectEqual(@as(usize, 1), row.cells.len);
        const linked_row: usize = if (case_index == 0) 1 else 0;
        var cell_text: std.ArrayList(u8) = .empty;
        var links: usize = 0;
        for (table.rows[linked_row].cells[0].spans) |span| {
            try cell_text.appendSlice(a, span.text);
            try cell_text.appendSlice(a, span.trail);
            if (span.kind == .link) {
                links += 1;
                try std.testing.expectEqualStrings("cat", span.target);
                try std.testing.expectEqualStrings(case.label, span.text);
            }
        }
        try std.testing.expectEqualStrings(case.cell, cell_text.items);
        try std.testing.expectEqual(@as(usize, 1), links);
        if (case_index == 0) {
            try std.testing.expect(table.rows[0].cells[0].header);
            try std.testing.expectEqualStrings("head", table.rows[0].cells[0].spans[0].text);
            try std.testing.expectEqualStrings("tail", table.rows[2].cells[0].spans[0].text);
        }
    }
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    for (cases) |case| {
        const line = lines.next() orelse return error.TestUnexpectedResult;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.title, parsed.value.object.get("title").?.string);
        const reasons = parsed.value.object.get("reasons").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), reasons.len);
        try std.testing.expectEqualStrings("literal_markup", reasons[0].string);
    }
    try std.testing.expect(lines.next() == null);
}

test "Writer quote scopes preserve linked owner styles and outside suffix through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const source = "==English==\n'''before [[Target|''one\n==French==\nbody'']] after''' plain";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "quoted linked owner", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const expected = [_]struct { text: []const u8, french: bool, bold: bool, italic: bool, linked: bool }{
        .{ .text = "before", .french = false, .bold = true, .italic = false, .linked = false },
        .{ .text = "one", .french = false, .bold = true, .italic = true, .linked = true },
        .{ .text = "French", .french = true, .bold = true, .italic = true, .linked = true },
        .{ .text = "body", .french = true, .bold = true, .italic = true, .linked = true },
        .{ .text = "after", .french = true, .bold = true, .italic = false, .linked = false },
        .{ .text = "plain", .french = true, .bold = false, .italic = false, .linked = false },
    };
    var seen: [expected.len]usize = @splat(0);
    for ([_][]const u8{ "English", "French" }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("quoted linked owner")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, owner, "French")) "fr" else "en", decoded.entry.language_code);
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            const visible = std.mem.trim(u8, span.text, " \t\r\n");
            for (expected, 0..) |item, item_index| {
                if (!std.mem.eql(u8, item.text, visible)) continue;
                try std.testing.expectEqual(item.french, std.mem.eql(u8, owner, "French"));
                try std.testing.expectEqual(item.bold, span.bold);
                try std.testing.expectEqual(item.italic, span.italic);
                try std.testing.expect(!span.code);
                try std.testing.expectEqualStrings("", span.trail);
                if (item.linked) {
                    try std.testing.expect(span.kind == .link);
                    try std.testing.expectEqualStrings("Target", span.target);
                } else {
                    try std.testing.expect(span.kind == .text);
                    try std.testing.expectEqualStrings("", span.target);
                }
                if (std.mem.eql(u8, item.text, "French")) {
                    try std.testing.expectEqualStrings("French", section.title);
                    try std.testing.expectEqual(@as(u8, 2), section.level);
                    try std.testing.expect(block.kind == .heading);
                    try std.testing.expectEqual(@as(u8, 2), block.level);
                }
                seen[item_index] += 1;
            }
        };
    }
    for (seen) |count| try std.testing.expectEqual(@as(usize, 1), count);
}

test "Writer refused ordinary roots expose language owners without inheriting navigation through DPR2" {
    const compiler = @import("presentation_compile.zig");
    const Part = struct { text: []const u8, target: []const u8 = "", bold: bool = false };
    const Check = struct {
        parts: []const Part,
        part: usize = 0,
        byte: usize = 0,
        forbidden: []const u8,
        fn advance(self: *@This()) void {
            while (self.part < self.parts.len and self.byte == self.parts[self.part].text.len) {
                self.part += 1;
                self.byte = 0;
            }
        }
        fn spans(self: *@This(), values: anytype, allowed: []const []const u8) !void {
            for (values) |span| {
                try std.testing.expect(!std.mem.eql(u8, span.target, self.forbidden));
                if (span.target.len != 0) {
                    try std.testing.expect(span.kind == .link);
                    var found = false;
                    for (allowed) |target| if (std.mem.eql(u8, target, span.target)) {
                        found = true;
                        break;
                    };
                    try std.testing.expect(found);
                }
                if (comptime @hasField(@TypeOf(span), "trail")) try std.testing.expectEqualStrings("", span.trail);
                for (span.text) |byte| {
                    if (std.ascii.isWhitespace(byte)) continue;
                    self.advance();
                    try std.testing.expect(self.part < self.parts.len);
                    const expected = self.parts[self.part];
                    try std.testing.expectEqual(expected.text[self.byte], byte);
                    try std.testing.expectEqualStrings(expected.target, span.target);
                    if (expected.target.len == 0) try std.testing.expect(span.kind == .text) else try std.testing.expect(span.kind == .link);
                    const bold = if (comptime @hasField(@TypeOf(span), "flags")) span.flags.bold else span.bold;
                    const italic = if (comptime @hasField(@TypeOf(span), "flags")) span.flags.italic else span.italic;
                    const code = if (comptime @hasField(@TypeOf(span), "flags")) span.flags.code else span.code;
                    try std.testing.expectEqual(expected.bold, bold);
                    try std.testing.expect(!italic and !code);
                    self.byte += 1;
                }
            }
        }
        fn finish(self: *@This()) !void {
            self.advance();
            try std.testing.expectEqual(self.parts.len, self.part);
        }
    };
    const rows = [_]struct { title: []const u8, source: []const u8, forbidden: []const u8, nested: bool }{
        .{ .title = "refused-owner", .source = "==English==\n[[First|one\nfirst]]\n[[Target|lead\n==French==\nbody [[cat|explicit]]\nend]] '''after''' plain", .forbidden = "Target", .nested = false },
        .{ .title = "refused-inner-owner", .source = "==English==\n[[Outer|lead [[Inner|one\n==French==\nbody]] tail]] outside", .forbidden = "Outer", .nested = true },
    };
    const english = [_]Part{ .{ .text = "one", .target = "First" }, .{ .text = "first", .target = "First" }, .{ .text = "[[Target|lead" } };
    const french = [_]Part{ .{ .text = "body" }, .{ .text = "explicit", .target = "cat" }, .{ .text = "end]]" }, .{ .text = "after", .bold = true }, .{ .text = "plain" } };
    const nested_english = [_]Part{ .{ .text = "[[Outer|lead" }, .{ .text = "one", .target = "Inner" } };
    const nested_french = [_]Part{ .{ .text = "French", .target = "Inner" }, .{ .text = "body", .target = "Inner" }, .{ .text = "tail]]" }, .{ .text = "outside" } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    for (rows) |row| {
        var renderer: compiler.Renderer = .{ .a = a, .context = .{ .title = row.title, .language = "English", .link_trail = codes.link_trail, .namespace_catalog = codes.namespace_catalog, .behavior_switches = codes.behavior_switches, .image_options = codes.image_options } };
        const blocks = try renderer.renderBody(row.source);
        const prefix = [_]Part{.{ .text = "English" }};
        const plain_french = [_]Part{.{ .text = "French" }};
        var expected: std.ArrayList(Part) = .empty;
        try expected.appendSlice(a, &prefix);
        try expected.appendSlice(a, if (row.nested) &nested_english else &english);
        if (!row.nested) try expected.appendSlice(a, &plain_french);
        try expected.appendSlice(a, if (row.nested) &nested_french else &french);
        var native: Check = .{ .parts = expected.items, .forbidden = row.forbidden };
        var headings: usize = 0;
        for (blocks) |block| {
            var allowed: []const []const u8 = if (row.nested) &.{"Inner"} else &.{ "First", "cat" };
            if (block.kind == .heading) {
                headings += 1;
                try std.testing.expectEqual(@as(u8, 2), block.level);
                const title = try compiler.plainText(a, block.spans);
                allowed = if (row.nested and std.mem.eql(u8, title, "French")) &.{"Inner"} else &.{};
            } else try std.testing.expect(block.kind == .paragraph);
            try native.spans(block.spans, allowed);
        }
        try native.finish();
        try std.testing.expectEqual(@as(usize, 2), headings);
        try std.testing.expect(renderer.fallbacks.literal_markup);
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row.title, row.source, row.source, null);
    }
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 2), stats.fallback_pages);
    for ([_][]const u8{ "English", "French" }) |owner| {
        const is_french = std.mem.eql(u8, owner, "French");
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(if (is_french) "fr" else "en", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for (rows) |row| {
            const record = (try index.find(row.title)).?;
            const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expectEqualStrings(metadata.code, decoded.entry.language_code);
            try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
            const section = decoded.entry.sections[0];
            try std.testing.expectEqualStrings(owner, section.title);
            try std.testing.expectEqual(@as(u8, 2), section.level);
            const parts: []const Part = if (row.nested) (if (is_french) &nested_french else &nested_english) else (if (is_french) &french else &english);
            var decoded_check: Check = .{ .parts = parts, .forbidden = row.forbidden };
            var companions: usize = 0;
            for (section.blocks) |block| {
                const allowed: []const []const u8 = if (row.nested) &.{"Inner"} else if (is_french) &.{"cat"} else &.{"First"};
                if (block.kind == .heading) {
                    try std.testing.expect(row.nested and is_french);
                    try std.testing.expectEqual(@as(u8, 2), block.level);
                    companions += 1;
                } else try std.testing.expect(block.kind == .paragraph);
                try decoded_check.spans(block.spans, allowed);
            }
            try decoded_check.finish();
            try std.testing.expectEqual(@as(usize, if (row.nested and is_french) 1 else 0), companions);
        }
    }
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    var lines = std.mem.tokenizeScalar(u8, report, '\n');
    for (rows) |row| {
        const line = lines.next() orelse return error.TestUnexpectedResult;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(row.title, parsed.value.object.get("title").?.string);
        const reasons = parsed.value.object.get("reasons").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), reasons.len);
        try std.testing.expectEqualStrings("literal_markup", reasons[0].string);
    }
    try std.testing.expect(lines.next() == null);
}

test "Writer attributed formatting crosses language owners and restores scope through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const source = "==English==\nlead\n<b class=\"Egyp IPA nyms\" lang=egy dir=rtl>\nalpha [[cat]]\n==French==\nbeta [[chat]]\n<i lang=\"\" dir=ltr>reset [[chien]]</i>\n==English==\ndelta [[dog]]\n</b> trailer [[wolf]]\nsoft [[fox]]\n\nOutside [[bear]]";
    const observation = try presentation_document.observePreScopesAlloc(a, "attributed owner scope", source, .{}, null, null, null, .{}, null);
    defer freePreObservation(a, observation);
    var attributed_scope = false;
    for (observation.scopes) |scope| {
        if (std.mem.indexOf(u8, scope.attributes.classes, "Egyp") == null) continue;
        try std.testing.expect(scope.attributes.role == .pronunciation);
        try std.testing.expect(scope.attributes.relation_note);
        if (scope.attributes.language.len == 0) {
            try std.testing.expectEqualStrings("ltr", scope.attributes.direction);
        } else {
            try std.testing.expectEqualStrings("egy", scope.attributes.language);
            try std.testing.expectEqualStrings("rtl", scope.attributes.direction);
            attributed_scope = true;
        }
    }
    try std.testing.expect(attributed_scope);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "attributed owner scope", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const expected = [_]struct { text: []const u8, owner: []const u8, target: []const u8 = "", scoped: bool = false, reset: bool = false }{
        .{ .text = "lead", .owner = "English" },
        .{ .text = "alpha", .owner = "English", .scoped = true },
        .{ .text = "cat", .owner = "English", .target = "cat", .scoped = true },
        .{ .text = "beta", .owner = "French", .scoped = true },
        .{ .text = "chat", .owner = "French", .target = "chat", .scoped = true },
        .{ .text = "reset", .owner = "French", .scoped = true, .reset = true },
        .{ .text = "chien", .owner = "French", .target = "chien", .scoped = true, .reset = true },
        .{ .text = "delta", .owner = "English", .scoped = true },
        .{ .text = "dog", .owner = "English", .target = "dog", .scoped = true },
        .{ .text = "trailer", .owner = "English" },
        .{ .text = "wolf", .owner = "English", .target = "wolf" },
        .{ .text = "soft", .owner = "English" },
        .{ .text = "fox", .owner = "English", .target = "fox" },
        .{ .text = "Outside", .owner = "English" },
        .{ .text = "bear", .owner = "English", .target = "bear" },
    };
    var seen: [expected.len]usize = @splat(0);
    var joined_suffix = false;
    for ([_][]const u8{ "English", "French" }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("attributed owner scope")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, owner, "French")) "fr" else "en", decoded.entry.language_code);
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            var delta = false;
            var trailer = false;
            var soft = false;
            for (block.spans) |span| {
                var words = std.mem.tokenizeAny(u8, span.text, " \t\r\n");
                while (words.next()) |word| {
                    delta = delta or std.mem.eql(u8, word, "delta");
                    trailer = trailer or std.mem.eql(u8, word, "trailer");
                    soft = soft or std.mem.eql(u8, word, "soft");
                    for (expected, 0..) |item, item_index| {
                        if (!std.mem.eql(u8, item.text, word)) continue;
                        errdefer std.debug.print("OWNER-SPAN owner={s} word={s} bold={} italic={} code={} role={s} classes={s} lang={s} dir={s} target={s}\n", .{ owner, word, span.bold, span.italic, span.code, @tagName(span.role), span.classes, span.language, span.direction, span.target });
                        try std.testing.expectEqualStrings(item.owner, owner);
                        try std.testing.expectEqualStrings(item.target, span.target);
                        try std.testing.expect(if (item.target.len != 0) span.kind == .link else span.kind == .text);
                        try std.testing.expectEqual(item.scoped, span.bold);
                        try std.testing.expectEqual(item.reset, span.italic);
                        try std.testing.expect(!span.code);
                        try std.testing.expectEqualStrings(if (item.scoped and !item.reset) "egy" else "", span.language);
                        try std.testing.expectEqualStrings(if (!item.scoped) "" else if (item.reset) "ltr" else "rtl", span.direction);
                        try std.testing.expectEqualStrings(if (item.scoped) "pronunciation" else "normal", @tagName(span.role));
                        var egyp = false;
                        var ipa = false;
                        var nyms = false;
                        var classes = std.mem.tokenizeAny(u8, span.classes, " \t\r\n");
                        while (classes.next()) |class| {
                            egyp = egyp or std.mem.eql(u8, class, "Egyp");
                            ipa = ipa or std.mem.eql(u8, class, "IPA");
                            nyms = nyms or std.mem.eql(u8, class, "nyms");
                        }
                        try std.testing.expectEqual(item.scoped, egyp);
                        try std.testing.expectEqual(item.scoped, ipa);
                        try std.testing.expectEqual(item.scoped, nyms);
                        seen[item_index] += 1;
                    }
                }
            }
            if (delta and trailer and soft) {
                try std.testing.expect(block.kind == .paragraph);
                joined_suffix = true;
            }
        };
    }
    for (seen) |count| try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(joined_suffix);
}

test "Writer external link numbering precedes owner regrouping and resets per page through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = TestLanguages.codes();
    const out_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, out_root);
    defer writer.deinit();
    writer.language_codes = codes;
    const first = "==English==\n===Noun===\n# first [https://example.test/first]\n==French==\n===Noun===\n# second [https://example.test/second]\n==English==\n===Verb===\n# third [https://example.test/third]\n";
    const next = "==French==\n===Noun===\n# next [https://example.test/next]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "numbered first", first, first, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "numbered next", next, next, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 3), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const expected = [_]struct {
        owner: []const u8,
        code: []const u8,
        title: []const u8,
        targets: []const []const u8,
        labels: []const []const u8,
    }{
        .{ .owner = "English", .code = "en", .title = "numbered first", .targets = &.{ "https://example.test/first", "https://example.test/third" }, .labels = &.{ "[1]", "[3]" } },
        .{ .owner = "French", .code = "fr", .title = "numbered first", .targets = &.{"https://example.test/second"}, .labels = &.{"[2]"} },
        .{ .owner = "French", .code = "fr", .title = "numbered next", .targets = &.{"https://example.test/next"}, .labels = &.{"[1]"} },
    };
    for (expected) |case| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, out_root, case.owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(case.code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(case.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(case.title, decoded.entry.title);
        try std.testing.expectEqualStrings(case.code, decoded.entry.language_code);
        var actions: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind != .external_link) continue;
            try std.testing.expect(actions < case.targets.len);
            try std.testing.expectEqualStrings(case.targets[actions], span.target);
            try std.testing.expectEqualStrings(case.labels[actions], span.text);
            actions += 1;
        };
        try std.testing.expectEqual(case.targets.len, actions);
    }
}

test "unknown equals declaration preserves adjacent Norwegian variant ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "nb", "Bokmal" }, .{ "nn", "Nynorsk" }, .{ "no", "Noors" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]))
                    return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Captured AF ja uses these declarations and linked variant headings;
    // qmg is intentionally absent from its captured language register.
    const raw = "{{=nb=}}\n# BOKMAL_ONLY\n{{=qmg=}}\n# UNKNOWN_ONLY\n{{=nn=}}\n# NYNORSK_ONLY\n";
    const expanded = "==[[Noors|Noors boekmaal (nb)]]==\n# BOKMAL_ONLY\n" ++
        "==[[Middelsaksies|Middelsaksies (qmg)]]==\n# UNKNOWN_ONLY\n" ++
        "==[[Noors|Nieu-Noors (nn)]]==\n# NYNORSK_ONLY\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ja", expanded, raw, null);
    try std.testing.expectEqual(@as(usize, 3), (try writer.finish(codes)).language_records);
    inline for (.{ .{ "Bokmal", "nb", "BOKMAL_ONLY" }, .{ "Nynorsk", "nn", "NYNORSK_ONLY" }, .{ "Unclassified", "", "UNKNOWN_ONLY" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("ja")).?;
        const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row[1], page.entry.language_code);
        var text: std.ArrayList(u8) = .empty;
        for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
            try text.appendSlice(a, span.text);
        inline for (.{ "BOKMAL_ONLY", "NYNORSK_ONLY", "UNKNOWN_ONLY" }) |sentinel|
            try std.testing.expectEqual(std.mem.eql(u8, sentinel, row[2]), std.mem.indexOf(u8, text.items, sentinel) != null);
    }
}

test "undefined equals support does not erase registered neighboring owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "nl", "Nederlands" }, .{ "nn", "Nynorsk" }, .{ "no", "Noors" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]))
                    return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve };
    // voetbalploeg rev193320 puts undefined {{=fm2=}} after its Dutch
    // inflection and before pronunciation. No language declaration backs it.
    const raw = "{{=nl=}}\n# DUTCH_ONLY\n{{=fm2=}}\n# SUPPORT_ONLY\n{{=nn=}}\n# NYNORSK_ONLY\n";
    inline for (.{ "literal", "support" }) |mode| {
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, mode });
        var writer = try Writer.init(std.testing.io, a, root);
        defer writer.deinit();
        writer.language_codes = codes;
        const middle = if (std.mem.eql(u8, mode, "literal")) "{{=fm2=}}\n" else "===Support===\n";
        const expanded = try std.mem.concat(a, u8, &.{
            "==[[Nederlands|Nederlands (nl)]]==\n# DUTCH_ONLY\n",
            middle,
            "# SUPPORT_ONLY\n==[[Noors|Nieu-Noors (nn)]]==\n# NYNORSK_ONLY\n",
        });
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "voetbalploeg", expanded, raw, null);
        try std.testing.expectEqual(@as(usize, 2), (try writer.finish(codes)).language_records);
        inline for (.{ .{ "Nederlands", "nl" }, .{ "Nynorsk", "nn" } }) |row| {
            var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
            defer mapped.deinit();
            const blob = try blob_format.inspect(mapped.bytes);
            var index = try blob.buildTrustedIndexAlloc(a);
            defer index.deinit(a);
            const record = (try index.find("voetbalploeg")).?;
            const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
            try std.testing.expectEqualStrings(row[1], page.entry.language_code);
            var text: std.ArrayList(u8) = .empty;
            for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
                try text.appendSlice(a, span.text);
            const dutch = std.mem.eql(u8, row[1], "nl");
            try std.testing.expectEqual(dutch, std.mem.indexOf(u8, text.items, "DUTCH_ONLY") != null);
            try std.testing.expectEqual(dutch, std.mem.indexOf(u8, text.items, "SUPPORT_ONLY") != null);
            try std.testing.expectEqual(!dutch, std.mem.indexOf(u8, text.items, "NYNORSK_ONLY") != null);
        }
    }
}

test "unknown equals boundaries require exact expanded linked L2 corroboration" {
    const positive: language_source.Section = .{ .heading = "[[Middelsaksies|Middelsaksies (qmg)]]", .source = "==[[Middelsaksies|Middelsaksies (qmg)]]==\n# body" };
    try std.testing.expect(expandedEqualsDeclaration(positive, "qmg"));
    for ([_]language_source.Section{
        .{ .heading = "[[Middelsaksies|Middelsaksies (qmg)]]", .source = "===[[Middelsaksies|Middelsaksies (qmg)]]===\n# body" },
        .{ .heading = "[[Middelsaksies|Middelsaksies (gmh)]]", .source = "==heading==\n" },
        .{ .heading = "[[Middelsaksies|Middelsaksies (qmg)]] trailing", .source = "==heading==\n" },
        .{ .heading = "[[Middelsaksies|Middelsaksies (qmg)|extra]]", .source = "==heading==\n" },
        .{ .heading = "Support", .source = "==Support==\n" },
    }) |section| try std.testing.expect(!expandedEqualsDeclaration(section, "qmg"));
}

test "unknown equals declaration cannot borrow a registered rendered target owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "nb", "Bokmal" }, .{ "nn", "Nynorsk" }, .{ "no", "Noors" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]))
                    return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Instantiated conflicting target: qmg is absent, but Noors is registered.
    // Corroborated boundary syntax must never promote that target to owner.
    const raw = "{{=nb=}}\n# BOKMAL_ONLY\n{{=qmg=}}\n# UNKNOWN_ONLY\n{{=nn=}}\n# NYNORSK_ONLY\n";
    const expanded = "==[[Noors|Noors boekmaal (nb)]]==\n# BOKMAL_ONLY\n" ++
        "==[[Noors|Different (qmg)]]==\n# UNKNOWN_ONLY\n" ++
        "==[[Noors|Nieu-Noors (nn)]]==\n# NYNORSK_ONLY\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ja", expanded, raw, null);
    try std.testing.expectEqual(@as(usize, 3), (try writer.finish(codes)).language_records);
    inline for (.{ .{ "Bokmal", "nb", "BOKMAL_ONLY" }, .{ "Nynorsk", "nn", "NYNORSK_ONLY" }, .{ "Unclassified", "", "UNKNOWN_ONLY" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("ja")).?;
        const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row[1], page.entry.language_code);
        var text: std.ArrayList(u8) = .empty;
        for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
            try text.appendSlice(a, span.text);
        inline for (.{ "BOKMAL_ONLY", "NYNORSK_ONLY", "UNKNOWN_ONLY" }) |sentinel|
            try std.testing.expectEqual(std.mem.eql(u8, sentinel, row[2]), std.mem.indexOf(u8, text.items, sentinel) != null);
    }
}

test "standalone equals owner ignores nested arguments and refuses unknown codes" {
    const Local = struct {
        fn trusted(_: ?*const anyopaque, _: []const u8) ?ResolvedLanguage {
            return null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "ett")) return .{ .code = "ett", .heading = "Etruscan" };
            if (std.mem.eql(u8, value, "en")) return .{ .code = "en", .heading = "English" };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .resolve_fn = Local.resolve, .trusted_fn = Local.trusted };
    const declared = resolveSection(codes, .{ .heading = "ett", .source = "{{=ett=|{{sort|en}}|display=[[English]]}}\n# BODY" }).?;
    try std.testing.expectEqualStrings("ett", declared.code);
    try std.testing.expectEqualStrings("Etruscan", declared.heading);
    try std.testing.expect(resolveSection(codes, .{ .heading = "unknown", .source = "{{=unknown=|{{sort|en}}|display=[[English]]}}\n# BODY" }) == null);
    try std.testing.expect(resolveSection(codes, .{ .heading = "ett", .source = "{{=unknown=|{{sort|en}}}}\n# BODY" }) == null);
}

test "AN complete identical suffixless declaration resolves but malformed ambiguous and mixed labels do not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.namespace_catalog = &namespaces;
    const banner = "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]'''''</div>";
    try std.testing.expectEqualStrings("ca", resolveAnBannerHeading(codes, banner).?.code);
    const bad = [_][]const u8{
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Aragonés]]'''''</div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Unknown|Unknown]]'''''</div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]''''</div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]''''' tail</div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]''''' [[Aragonés]]</div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]''''' <small>- ''Aragonés''</small></div>",
        "<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]'''''",
    };
    for (bad) |value| try std.testing.expect(resolveAnBannerHeading(codes, value) == null);
    // Missing AN namespace authority cannot use the new direct grammar.
    try std.testing.expect(resolveAnBannerHeading(TestLanguages.codes(), banner) == null);
}

fn ownedSpoolHandlesForTest(io: std.Io, a: std.mem.Allocator, paths: []const []const u8) ![]std.Io.File {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var dir = try std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var handles: std.ArrayList(std.Io.File) = .empty;
    defer handles.deinit(a);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        var buffer: [8192]u8 = undefined;
        const len = dir.readLink(io, entry.name, &buffer) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const target = buffer[0..len];
        for (paths) |path| {
            if (!std.mem.eql(u8, target, path)) continue;
            const fd = try std.fmt.parseInt(std.posix.fd_t, entry.name, 10);
            try handles.append(a, .{ .handle = fd, .flags = .{ .nonblocking = false } });
            break;
        }
    }
    return handles.toOwnedSlice(a);
}

fn expectOwnedSpoolsClosedForTest(io: std.Io, a: std.mem.Allocator, paths: []const []const u8) !void {
    const handles = try ownedSpoolHandlesForTest(io, a, paths);
    defer a.free(handles);
    // On an unfixed parent, close only the exact owned leaks before failing so
    // this regression cannot contaminate the remaining test process.
    defer for (handles) |file| file.close(io);
    try std.testing.expectEqual(@as(usize, 0), handles.len);
}

test "SpoolFile allocation failure closes owned descriptor before same process retry" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(relative);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "leaf.tmp" });
    defer a.free(path);
    const owned = [_][]const u8{path};
    for (0..3) |_| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        if (SpoolFile.init(io, failing.allocator(), path)) |value| {
            var unexpected = value;
            unexpected.close(io);
            unexpected.deinitPath(failing.allocator());
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try expectOwnedSpoolsClosedForTest(io, a, &owned);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    var spool = try SpoolFile.init(io, a, path);
    defer spool.deinitPath(a);
    {
        defer spool.close(io);
        const handles = try ownedSpoolHandlesForTest(io, a, &owned);
        defer a.free(handles);
        try std.testing.expectEqual(@as(usize, 1), handles.len);
        var page = std.heap.ArenaAllocator.init(a);
        defer page.deinit();
        try spool.append(io, page.allocator(), "", "title", "payload");
    }
    try expectOwnedSpoolsClosedForTest(io, a, &owned);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    defer a.free(bytes);
    const expected = [_]u8{ 0, 0, 0, 0, 5, 0, 0, 0, 7, 0, 0, 0 } ++ "titlepayload".*;
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "Spools allocation failures unwind all owned slots root path and retry" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(relative);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, a);
    defer a.free(root);
    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned.items) |path| a.free(path);
        owned.deinit(a);
    }
    for (0..language_bucket_count) |idx|
        try owned.append(a, try std.fmt.allocPrint(a, "{s}/.spool/lang-{d:0>2}.tmp", .{ root, idx }));
    for ([_][]const u8{ "thesaurus", "citations", "reconstruction", "rhymes", "sign-gloss", "supplemental", "aliases" }) |name|
        try owned.append(a, try std.fmt.allocPrint(a, "{s}/.spool/{s}.tmp", .{ root, name }));
    var measured = std.testing.FailingAllocator.init(a, .{});
    const allocation_count = initial_scope: {
        var initial = try Spools.init(io, measured.allocator(), root);
        var closed = false;
        defer {
            if (!closed) initial.close();
            initial.cleanup();
        }
        const count = measured.alloc_index;
        initial.close();
        closed = true;
        try expectOwnedSpoolsClosedForTest(io, a, owned.items);
        break :initial_scope count;
    };
    try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);
    // Derive all real failure indices from the successful acquisition, including
    // the root path and every later fixed-slot filename/path allocation.
    try std.testing.expect(allocation_count > 2 * language_bucket_count + 1);
    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (Spools.init(io, failing.allocator(), root)) |value| {
            var unexpected = value;
            unexpected.close();
            unexpected.cleanup();
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        // No unlink/cleanup happens before this exact owned-file fd assertion.
        try expectOwnedSpoolsClosedForTest(io, a, owned.items);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        {
            var retry = try Spools.init(io, a, root);
            var closed = false;
            defer {
                if (!closed) retry.close();
                retry.cleanup();
            }
            const handles = try ownedSpoolHandlesForTest(io, a, owned.items);
            defer a.free(handles);
            try std.testing.expectEqual(owned.items.len, handles.len);
            retry.close();
            closed = true;
            try expectOwnedSpoolsClosedForTest(io, a, owned.items);
        }
    }
}

// Test authority: exact six raw articles and wrappers are retained in
// captured-six-source-fixtures01.json. Expanded strings are source-instantiated
// fixtures, not live Lua output or current Reader acceptance.
const ArabicNorwegianTest = struct {
    const namespace_tsv = "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const Mode = enum { normal, missing_named, wrong_named, wrong_umbrella, wrong_canonical };
    fn mode(ctx: ?*const anyopaque) Mode {
        const value: *const Mode = @ptrCast(@alignCast(ctx orelse return .normal));
        return value.*;
    }
    fn resolve(ctx: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        inline for (.{ .{ "no", "النرويجية" }, .{ "nb", "النرويجية بوكمال" }, .{ "nn", "النرويجية نينورسك" }, .{ "en", "English" }, .{ "fr", "French" } }) |row| {
            if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1])) {
                if (mode(ctx) == .wrong_canonical and std.mem.eql(u8, value, "nb")) return .{ .code = "nn", .heading = "النرويجية نينورسك" };
                return .{ .code = row[0], .heading = row[1] };
            }
        }
        return trusted(ctx, value);
    }
    fn trusted(ctx: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
        // Exact selected module214436/rev996464 names, with no bare-variant aliases.
        if (std.mem.eql(u8, value, "نرويجية")) return .{ .code = if (mode(ctx) == .wrong_umbrella) "en" else "no", .heading = "النرويجية" };
        if (std.mem.eql(u8, value, "نرويجية بوكمول")) {
            if (mode(ctx) == .missing_named) return null;
            return .{ .code = if (mode(ctx) == .wrong_named) "nn" else "nb", .heading = "النرويجية بوكمال" };
        }
        if (std.mem.eql(u8, value, "نرويجية نينوشك")) return .{ .code = "nn", .heading = "النرويجية نينورسك" };
        inline for (.{ .{ "en", "English" }, .{ "fr", "French" } }) |row|
            if (std.mem.eql(u8, value, row[1])) return .{ .code = row[0], .heading = row[1] };
        return null;
    }
    fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
        return if (resolve(ctx, value)) |language| language.code else null;
    }
    fn codes(namespaces: *const @import("namespace_registry").Registry, state: ?*const Mode) LanguageCodes {
        return .{ .namespace_catalog = namespaces, .ctx = state, .get_fn = get, .resolve_fn = resolve, .trusted_fn = trusted };
    }
};

test "Arabic Norwegian declarations require exact variant and canonical authority" {
    var namespaces = try @import("namespace_registry").Registry.init(std.testing.allocator, ArabicNorwegianTest.namespace_tsv);
    defer namespaces.deinit();
    const codes = ArabicNorwegianTest.codes(&namespaces, null);
    inline for (.{ .{ "[[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]):", "nb" }, .{ "[[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]):", "nn" }, .{ "[[في|في]] ال[[نرويجية|نرويجية]] ([[بوكمول|بوكمول]]):", "nb" } }) |row| {
        const section: language_source.Section = .{ .heading = row[0], .source = "" };
        try std.testing.expectEqualStrings(row[1], resolveArabicNorwegianDeclaration(codes, row[0]).?.code);
        try std.testing.expectEqualStrings(row[1], resolveSection(codes, section).?.code);
        try std.testing.expectEqualStrings(row[1], boundaryLanguage(codes, section).?.code);
        try std.testing.expect(hasExplicitLanguageDeclaration(codes, section));
        const markers: LanguageMarkers = .{ .codes = &codes };
        const iterator = languageSections("", &markers);
        const filter = iterator.heading_filter.?;
        try std.testing.expect(filter.accepts(filter.ctx, row[0]));
    }
    inline for (.{
        "[[في]] ال[[نرويجية]] ([[بوكمول|نينوشك]]):",
        "[[في|French]] ال[[نرويجية]] ([[بوكمول]]):",
        "[[في]] ال[[نرويجية|English]] ([[بوكمول]]):",
        "[[في]] ال[[نرويجية]] ([[بوكمول|بوكمول|extra]]):",
        "[[في]] ال[[نرويجية]] ([[بوكمول]] [[نينوشك]]):",
        "[[في]] ال[[نرويجية]] ([[Unknown]]):",
        "[[في]] ال[[English]] ([[بوكمول]]):",
        "[[في]] ال[[نرويجية]] ([[بوكمول]])",
        "[[في]] ال[[نرويجية]] ([[بوكمول]]): trailing",
        "[[في]] ال[[نرويجية]] ([[بوكمول]]):[[English]]",
        "[[في]] ال[[نرويجية]] ([[بوكمول]]):[[تصنيف:نرويجية بوكمول]]",
        "[[نرويجية]] ([[بوكمول]])",
        "Norwegian (Bokmål)",
        "<nowiki>[[في]] ال[[نرويجية]] ([[بوكمول]]):</nowiki>",
        "[[في]] ال[[نرويجية]] ([[بوكمول]]):\n",
    }) |bad| try std.testing.expect(resolveArabicNorwegianDeclaration(codes, bad) == null);
    inline for ([_]ArabicNorwegianTest.Mode{ .missing_named, .wrong_named, .wrong_umbrella, .wrong_canonical }) |state| {
        const guarded = ArabicNorwegianTest.codes(&namespaces, &state);
        const heading = "[[في]] ال[[نرويجية]] ([[بوكمول]]):";
        try std.testing.expect(arabicNorwegianDeclaration(guarded, heading) != null);
        try std.testing.expect(resolveArabicNorwegianDeclaration(guarded, heading) == null);
        try std.testing.expect(resolveSection(guarded, .{ .heading = heading, .source = "" }) == null);
        try std.testing.expect(boundaryLanguage(guarded, .{ .heading = heading, .source = "" }) == null);
    }
    var foreign = try @import("namespace_registry").Registry.init(std.testing.allocator, @import("namespace_registry").english_test_fixture);
    defer foreign.deinit();
    try std.testing.expect(resolveArabicNorwegianDeclaration(ArabicNorwegianTest.codes(&foreign, null), "[[في]] ال[[نرويجية]] ([[بوكمول]]):") == null);
}

test "six captured Arabic Norwegian entries retain separate senses gender and actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, ArabicNorwegianTest.namespace_tsv);
    defer namespaces.deinit();
    const codes = ArabicNorwegianTest.codes(&namespaces, null);
    const Fixture = struct { title: []const u8, raw: []const u8, expanded: []const u8, nb_targets: []const []const u8, nn_targets: []const []const u8 };
    const fixtures = [_]Fixture{
        .{ .title = "bruke", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|فِعْلٌ.}}\n# [[اِسْتَخْدَمَ]]، [[استعمل|اِسْتَعْمَلَ]].\n# [[اِعْتَادَ]].\n# [[اِسْتَهْلَكَ]].\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|فِعْلٌ.}}\n# [[اِسْتَخْدَمَ]]، [[استعمل|اِسْتَعْمَلَ]].\n# [[اِعْتَادَ]].\n# [[اِسْتَهْلَكَ]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:br]]\n[[تصنيف:أفعال (بوكمول)]]\n[[تصنيف:أفعال (نينوشك)]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nفِعْلٌ.\n# [[اِسْتَخْدَمَ]]، [[استعمل|اِسْتَعْمَلَ]].\n# [[اِعْتَادَ]].\n# [[اِسْتَهْلَكَ]].\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nفِعْلٌ.\n# [[اِسْتَخْدَمَ]]، [[استعمل|اِسْتَعْمَلَ]].\n# [[اِعْتَادَ]].\n# [[اِسْتَهْلَكَ]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:br]]\n[[تصنيف:أفعال (بوكمول)]]\n[[تصنيف:أفعال (نينوشك)]]", .nb_targets = &.{ "استعمل", "اِسْتَخْدَمَ", "اِسْتَهْلَكَ", "اِعْتَادَ" }, .nn_targets = &.{ "استعمل", "اِسْتَخْدَمَ", "اِسْتَهْلَكَ", "اِعْتَادَ" } },
        .{ .title = "bensinstasjon", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[مَحَطَّة]] ٱلْ[[وَقُود]].\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[مَحَطَّة]] ٱلْ[[وَقُود]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:be]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[مَحَطَّة]] ٱلْ[[وَقُود]].\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[مَحَطَّة]] ٱلْ[[وَقُود]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:be]]", .nb_targets = &.{ "مَحَطَّة", "وَقُود" }, .nn_targets = &.{ "مَحَطَّة", "وَقُود" } },
        .{ .title = "bety", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|فِعْلٌ: [[betyr]] لِلْحَاضِرِ، [[betydde]] أَوْ [[betød]] لِلْمَاضِي ٱلْبَسِيطِ.}}\n# [[عَنَى]]، [[دَلَّ]] عَلَى.\n# [[يُفْهَمُ]] مِنْهُ.\n# [[لَمَّحَ]].\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|فِعْلٌ: [[betyr]] لِلْحَاضِرِ، [[betydde]] لِلْمَاضِي.}}\n# [[عَنَى]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:be]]\n[[تصنيف:أفعال (بوكمول)]]\n[[تصنيف:أفعال (نينوشك)]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nفِعْلٌ: [[betyr]] لِلْحَاضِرِ، [[betydde]] أَوْ [[betød]] لِلْمَاضِي ٱلْبَسِيطِ.\n# [[عَنَى]]، [[دَلَّ]] عَلَى.\n# [[يُفْهَمُ]] مِنْهُ.\n# [[لَمَّحَ]].\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nفِعْلٌ: [[betyr]] لِلْحَاضِرِ، [[betydde]] لِلْمَاضِي.\n# [[عَنَى]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:be]]\n[[تصنيف:أفعال (بوكمول)]]\n[[تصنيف:أفعال (نينوشك)]]", .nb_targets = &.{ "betydde", "betyr", "betød", "دَلَّ", "عَنَى", "لَمَّحَ", "يُفْهَمُ" }, .nn_targets = &.{ "betydde", "betyr", "عَنَى" } },
        .{ .title = "bussjåfør", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[سَائِق]] ٱلْ[[حَافِلَة]].\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[سَائِق]] ٱلْ[[حَافِلَة]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[سَائِق]] ٱلْ[[حَافِلَة]].\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[سَائِق]] ٱلْ[[حَافِلَة]].\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .nb_targets = &.{ "حَافِلَة", "سَائِق" }, .nn_targets = &.{ "حَافِلَة", "سَائِق" } },
        .{ .title = "bussrute", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ وَمُؤَنَّثٌ عَلَى حَدٍّ سَوَاء.}}\n# خَطُّ ٱلْحَافِلَة ([[طَرِيق]] ٱلْحَافِلَةِ).\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُؤَنَّثٌ.}}\n# خَطُّ ٱلْحَافِلَة ([[طَرِيق]] ٱلْحَافِلَةِ).\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ وَمُؤَنَّثٌ عَلَى حَدٍّ سَوَاء.\n# خَطُّ ٱلْحَافِلَة ([[طَرِيق]] ٱلْحَافِلَةِ).\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nاِسْمٌ مُؤَنَّثٌ.\n# خَطُّ ٱلْحَافِلَة ([[طَرِيق]] ٱلْحَافِلَةِ).\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .nb_targets = &.{"طَرِيق"}, .nn_targets = &.{"طَرِيق"} },
        .{ .title = "busstur", .raw = "{{نرويجية (بوكمول)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[رِحْلَة]] بِٱلْحَافِلَةِ.\n{{نرويجية (نينوشك)}}\n{{المعاني}}\n{{النوع|اِسْمٌ مُذَكَّرٌ.}}\n# [[رِحْلَة]] بِٱلْحَافِلَةِ.\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .expanded = "= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[بُوكْمُول]]): =\n[[تصنيف:نرويجية (بوكمول)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[رِحْلَة]] بِٱلْحَافِلَةِ.\n= [[فِي]] ٱل[[نَرْوِيجِيَّة]] ([[نِينُوشْك]]): =\n[[تصنيف:نرويجية (نينوشك)]]\n== المعاني ==\nاِسْمٌ مُذَكَّرٌ.\n# [[رِحْلَة]] بِٱلْحَافِلَةِ.\n\n[[تصنيف:b (نرويجية)]]\n[[تصنيف:bu]]\n[[تصنيف:نقل (نرويجية)]]", .nb_targets = &.{"رِحْلَة"}, .nn_targets = &.{"رِحْلَة"} },
    };
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/six", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    for (fixtures) |fixture| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, fixture.title, fixture.expanded, fixture.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 12), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    inline for (.{ .{ "nb", "النرويجية بوكمال" }, .{ "nn", "النرويجية نينورسك" } }) |owner| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner[1]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        for (fixtures) |fixture| {
            const record = (try index.find(fixture.title)).?;
            const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
            try std.testing.expectEqualStrings(owner[0], page.entry.language_code);
            var text: std.ArrayList(u8) = .empty;
            var targets: std.ArrayList([]const u8) = .empty;
            for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                try text.appendSlice(a, span.text);
                if (span.target.len != 0) try targets.append(a, span.target);
            };
            const bokmal = std.mem.eql(u8, owner[0], "nb");
            for (if (bokmal) fixture.nb_targets else fixture.nn_targets) |wanted| {
                var found = false;
                for (targets.items) |target| if (std.mem.eql(u8, target, wanted)) {
                    found = true;
                    break;
                };
                try std.testing.expect(found);
            }
            if (std.mem.eql(u8, fixture.title, "bety")) {
                try std.testing.expectEqual(bokmal, std.mem.indexOf(u8, text.items, "betød") != null);
                try std.testing.expectEqual(bokmal, std.mem.indexOf(u8, text.items, "لِلْمَاضِي ٱلْبَسِيطِ") != null);
                try std.testing.expectEqual(bokmal, std.mem.indexOf(u8, text.items, "لَمَّحَ") != null);
                if (!bokmal) for (targets.items) |target| try std.testing.expect(!std.mem.eql(u8, target, "دَلَّ") and !std.mem.eql(u8, target, "betød") and !std.mem.eql(u8, target, "لَمَّحَ"));
            }
            if (std.mem.eql(u8, fixture.title, "bussrute")) {
                try std.testing.expectEqual(bokmal, std.mem.indexOf(u8, text.items, "مُذَكَّرٌ") != null);
                try std.testing.expect(std.mem.indexOf(u8, text.items, "مُؤَنَّثٌ") != null);
            }
        }
    }
}

test "Arabic Norwegian declarations isolate neighbors and missing variant authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, ArabicNorwegianTest.namespace_tsv);
    defer namespaces.deinit();
    inline for ([_]ArabicNorwegianTest.Mode{ .normal, .missing_named }) |state| {
        const codes = ArabicNorwegianTest.codes(&namespaces, &state);
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, @tagName(state) });
        var writer = try Writer.init(std.testing.io, a, root);
        defer writer.deinit();
        writer.language_codes = codes;
        const source = "==English==\n# EN_ONLY [[english-action]]\n= [[في]] ال[[نرويجية]] ([[بوكمول]]): =\n# NB_ONLY [[bokmal-action]]\n= [[في]] ال[[نرويجية]] ([[نينوشك]]): =\n# NN_ONLY [[nynorsk-action]]\n==French==\n# FR_ONLY [[french-action]]\n";
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "neighbors", source, source, null);
        try std.testing.expectEqual(@as(usize, 4), (try writer.finish(codes)).language_records);
        const nb_heading = if (state == .normal) "النرويجية بوكمال" else "Unclassified";
        const nb_code = if (state == .normal) "nb" else "";
        const owners = [_]struct { heading: []const u8, code: []const u8, sentinel: []const u8, target: []const u8 }{
            .{ .heading = "English", .code = "en", .sentinel = "EN_ONLY", .target = "english-action" },
            .{ .heading = nb_heading, .code = nb_code, .sentinel = "NB_ONLY", .target = "bokmal-action" },
            .{ .heading = "النرويجية نينورسك", .code = "nn", .sentinel = "NN_ONLY", .target = "nynorsk-action" },
            .{ .heading = "French", .code = "fr", .sentinel = "FR_ONLY", .target = "french-action" },
        };
        for (owners) |owner| {
            var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, owner.heading));
            defer mapped.deinit();
            const blob = try blob_format.inspect(mapped.bytes);
            var index = try blob.buildTrustedIndexAlloc(a);
            defer index.deinit(a);
            const record = (try index.find("neighbors")).?;
            const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
            try std.testing.expectEqualStrings(owner.code, page.entry.language_code);
            var text: std.ArrayList(u8) = .empty;
            var action = false;
            for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                try text.appendSlice(a, span.text);
                if (std.mem.eql(u8, span.target, owner.target)) action = true;
            };
            try std.testing.expect(action);
            for (owners) |other| try std.testing.expectEqual(std.mem.eql(u8, owner.sentinel, other.sentinel), std.mem.indexOf(u8, text.items, other.sentinel) != null);
        }
    }
}

test "captured AN hyphen banners keep canonical owners despite local alias gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            // Canonical current registry rows; intentionally omit the missing
            // local Piemontés/Chodigoespañol/Friulán aliases and retain the
            // Malayo display-name collision independently from canonical ms.
            inline for (.{ .{ "pms", "Piedmontese" }, .{ "lad", "ladino" }, .{ "fur", "friulano" }, .{ "ms", "malayo" }, .{ "scn", "siciliano" }, .{ "an", "aragonés" }, .{ "fr", "francés" }, .{ "oc", "occitano" }, .{ "zh", "chino" }, .{ "th", "tai" }, .{ "bg", "búlgaro" }, .{ "lt", "lituano" }, .{ "tk", "turcomano" }, .{ "mul", "Multiple languages" }, .{ "haw", "hawaiano" }, .{ "rap", "Rapanui" }, .{ "sw", "suajili" }, .{ "ca", "catalán" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1])) return .{ .code = row[0], .heading = row[1] };
            if (std.mem.eql(u8, value, "Malayo")) return .{ .code = "mbp", .heading = "Malayo" };
            inline for (.{ .{ "Aragonés", "an", "aragonés" }, .{ "Francés", "fr", "francés" }, .{ "Franzés", "fr", "francés" }, .{ "Français", "fr", "francés" }, .{ "Occitán", "oc", "occitano" }, .{ "Occitan", "oc", "occitano" }, .{ "Secilián", "scn", "siciliano" }, .{ "secilián", "scn", "siciliano" }, .{ "Sicilianu", "scn", "siciliano" }, .{ "Catalán", "ca", "catalán" } }) |row|
                if (std.mem.eql(u8, value, row[0])) return .{ .code = row[1], .heading = row[2] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .namespace_catalog = &namespaces };
    const banner_pms = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Piedmont.svg|40px]] '''''[[Wiktionary:Piemontés|Piemontés]]''''' <small>- ''Piemontèis''</small></div>";
    const banner_lad = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of Thessaloniki.svg|40px]] '''''[[Wiktionary:Chodigoespañol|Chodigoespañol]]''''' <small>- ''Djudeoespanyol''</small></div>";
    const banner_fur = "<div id=\"toc\" class=\"toccolours\" >[[Image:Bandiere_dal_Friûl.svg|40px]] '''''[[Wiktionary:Friulán|Friulán]]''''' <small>- ''Furlan''</small></div>";
    const banner_ms = "<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>";
    const banner_an = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>";
    const banner_zh = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the People's Republic of China.svg|40px]] '''''[[Wiktionary:Chinés|Chinés]]''''' <small>- ''中文''</small></div>";
    const banner_th = "<div id=\"toc\" class=\"toccolours\" > '''''[[Wiktionary:Tailandés|Tailandés]]''''' <small>- ''Tailandés''</small></div>";
    const banner_bg = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Bulgaria.svg|40px]] '''''[[Wiktionary:Bulgaro|Bulgaro]]''''' <small>- ''Български''</small></div>";
    const banner_lt = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Lithuania.svg|40px]] '''''[[Wiktionary:Lituán|Lituán]]''''' <small>- ''Lietuvių kalba''</small></div>";
    const banner_tk = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Turkmenistan.svg|40px]] '''''[[Wiktionary:Turquemán|Turquemán]]''''' <small>- ''Türkmençe''</small></div>";
    const banner_mul = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the United Nations.svg|40px]] '''''[[internacional|Internacional]]''''' </div>";
    const banner_haw = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Hawaii.svg|40px]] '''''[[Wiktionary:Hawayán|Hawayán]]''''' <small>- ''‘Ōlelo Hawai‘i''</small></div>";
    const banner_rap = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Rapa_Nui,_Chile.svg|40px]] '''''[[Wiktionary:Rapanui|Rapa nui]]''''' <small>- ''Vananga Rapa Nui''</small></div>";
    const banner_sw = "<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Kenya.svg|40px]] '''''[[Wiktionary:Swahili|Swahili]]''''' <small>- ''Kiswahili''</small></div>";
    for ([_]struct { code: []const u8, banner: []const u8 }{ .{ .code = "pms", .banner = banner_pms }, .{ .code = "lad", .banner = banner_lad }, .{ .code = "fur", .banner = banner_fur }, .{ .code = "ms", .banner = banner_ms }, .{ .code = "zh", .banner = banner_zh }, .{ .code = "th", .banner = banner_th }, .{ .code = "bg", .banner = banner_bg }, .{ .code = "lt", .banner = banner_lt }, .{ .code = "tk", .banner = banner_tk }, .{ .code = "mul", .banner = banner_mul }, .{ .code = "haw", .banner = banner_haw }, .{ .code = "rap", .banner = banner_rap }, .{ .code = "sw", .banner = banner_sw } }) |row| {
        const raw: language_source.Section = .{ .heading = row.code, .source = "", .hyphen_marker = true };
        try std.testing.expect(corroboratedAnHyphenMarker(codes, raw, .{ .heading = row.banner, .source = "" }));
        try std.testing.expect(!corroboratedAnHyphenMarker(codes, .{ .heading = "adj", .source = "", .hyphen_marker = true }, .{ .heading = row.banner, .source = "" }));
        try std.testing.expect(!corroboratedAnHyphenMarker(codes, .{ .heading = row.code, .source = "" }, .{ .heading = row.banner, .source = "" }));
        try std.testing.expect(!corroboratedAnHyphenMarker(codes, raw, .{ .heading = banner_an, .source = "" }));
        var absent = codes;
        absent.namespace_catalog = null;
        try std.testing.expect(!corroboratedAnHyphenMarker(absent, raw, .{ .heading = row.banner, .source = "" }));
    }
    // Raw L2 support headings stay inside the independently corroborated
    // hyphen region; neither a real neighboring owner nor an unresolved
    // explicit declaration may be folded into it.
    const support_raw = "{{-haw-}}\n# [[yo]]\n==Se beiga tamién==\n* [[support]]\n{{-sw-}}\n# [[ó]]\n";
    const raw_context: LanguageMarkers = .{ .codes = &codes };
    var support_iterator = languageSections(support_raw, &raw_context);
    var support_sections: std.ArrayList(language_source.Section) = .empty;
    defer support_sections.deinit(a);
    while (support_iterator.next()) |section| try support_sections.append(a, section);
    try std.testing.expectEqual(@as(usize, 3), support_sections.items.len);
    const rendered_support = [_]language_source.Section{ .{ .heading = banner_haw, .source = "" }, .{ .heading = banner_sw, .source = "" } };
    var conflict_sections: std.ArrayList(language_source.Section) = .empty;
    defer conflict_sections.deinit(a);
    try conflict_sections.appendSlice(a, support_sections.items);
    conflict_sections.items[1].heading = "Francés";
    coalesceCorroboratedAnRawRegions(codes, support_raw, &conflict_sections, &rendered_support);
    try std.testing.expectEqual(@as(usize, 3), conflict_sections.items.len);
    // Use a valid declaration and real slices of the same supplied raw page.
    // A detached malformed literal violates the coalescer's iterator contract.
    const unknown_raw = "{{-haw-}}\n# [[yo]]\n{{=zz=}}\n# unknown\n{{-sw-}}\n# [[ó]]\n";
    // This direct coalescer check keeps syntactic boundaries before filtering.
    var unknown_iterator = language_source.Iterator.init(unknown_raw);
    conflict_sections.clearRetainingCapacity();
    while (unknown_iterator.next()) |section| try conflict_sections.append(a, section);
    try std.testing.expectEqual(@as(usize, 3), conflict_sections.items.len);
    try std.testing.expectEqualStrings("zz", conflict_sections.items[1].heading);
    try std.testing.expectEqualStrings("zz", language_source.equalsLanguageDeclaration(conflict_sections.items[1].source).?);
    coalesceCorroboratedAnRawRegions(codes, unknown_raw, &conflict_sections, &rendered_support);
    try std.testing.expectEqual(@as(usize, 3), conflict_sections.items.len);
    const wrong_rendered = [_]language_source.Section{ .{ .heading = banner_haw, .source = "" }, .{ .heading = banner_an, .source = "" } };
    coalesceCorroboratedAnRawRegions(codes, support_raw, &support_sections, &wrong_rendered);
    try std.testing.expectEqual(@as(usize, 3), support_sections.items.len);
    coalesceCorroboratedAnRawRegions(codes, support_raw, &support_sections, &rendered_support);
    try std.testing.expectEqual(@as(usize, 2), support_sections.items.len);
    try std.testing.expectEqualStrings("{{-haw-}}\n# [[yo]]\n==Se beiga tamién==\n* [[support]]\n", support_sections.items[0].source);
    try std.testing.expectEqualStrings("{{-sw-}}\n# [[ó]]\n", support_sections.items[1].source);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Source-instantiated banner expansions, not a claimed Lua execution.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mùsica", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Piedmont.svg|40px]] '''''[[Wiktionary:Piemontés|Piemontés]]''''' <small>- ''Piemontèis''</small></div>=\n==Sustantivo==\n# [[mosica]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of Sicily.svg|40px]] '''''[[secilián|Secilián]]''''' <small>- ''Sicilianu''</small></div>=\n==Sustantivo==\n# [[mosica]]\n", "{{-pms-}}\n{{-noun-}}\n'''mùsica'''\n# [[mosica]]\n\n{{-scn-}}\n{{-noun-}}\n'''mùsica'''\n# [[mosica]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "diya", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n==Sustantivo==\n1. Unidat de tiempo equibalent d'un periodo de 24 oras.\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of Thessaloniki.svg|40px]] '''''[[Wiktionary:Chodigoespañol|Chodigoespañol]]''''' <small>- ''Djudeoespanyol''</small></div>=\n==Sustantivo==\n1. Unidat de tiempo equibalent d'un periodo de 24 oras.\n", "{{-an-}}\n[[Categoría:AN:Sustantivos masculins]]\n* '''Prenunziazión''': /'di.ʝa/ /'di.a/\n* '''Bariant''': día\n\n{{-noun.masc-}}\n'''diya''' ''m''\n\n1. Unidat de tiempo equibalent d'un periodo de 24 oras.\n\n{{-trans-}}\n* {{ca}}: [[dia]]\n* {{en}}: [[day]]\n* {{es}}: [[día]]\n* {{fr}}: [[jour]]\n* {{it}}: [[giorno]]\n* {{lad}}: [[diya]]\n* {{oc}}: [[jorn]]\n* {{scn}}: [[jornu]]\n|valign=\"top\"|\n|}\n\n{{-lad-}}\n\n{{Prenunziazión}}\n{{Etimolochía}}\n\n{{-noun.masc-}}[[Categoría:LAD:Sustantibos masculins]]\n'''diya''' ''m''\n\n1. Unidat de tiempo equibalent d'un periodo de 24 oras.", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "an", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_France.svg|40px]] '''''[[Wiktionary:Franzés|Francés]]''''' <small>- ''Français''</small></div>=\n==Sustantivo==\n# [[año]], [[añada]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Bandiere_dal_Friûl.svg|40px]] '''''[[Wiktionary:Friulán|Friulán]]''''' <small>- ''Furlan''</small></div>=\n==Sustantivo==\n# [[año]], [[añada]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Occitania.svg|40px]] '''''[[Wiktionary:Occitán|Occitán]]''''' <small>- ''Occitan''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en oczitán]]\n==Sustantivo==\n# [[año]], [[añada]]\n", "{{-fr-}}\n{{-noun-}}\n'''an'''\n# [[año]], [[añada]]\n\n{{-fur-}}\n{{-noun-}}\n'''an'''\n# [[año]], [[añada]]\n\n{{-oc-}}\n{{-noun-}}\n'''an'''\n# [[año]], [[añada]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "جون", "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=\n==Sustantivo==\n# [[chunio]].\n", "{{-ms-}}\n{{Prenunziazión|/dʒun/}}\n{{Etimolochía|anglés|June}}\n{{grafíaalt|[[Jun]]}}\n{{-noun-}}[[Categoría:MS:Sustantibos]]\n'''جون'''\n# [[chunio]].\n\n==Se beigan también==\n* (''mes''): Dezaga: [[مي]]. Debant: [[جولاي]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Jun", "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=\n==Sustantivo==\n# [[chunio]].\n", "{{-ms-}}\n{{Prenunziazión|/dʒun/}}\n{{Etimolochía|anglés|June}}\n{{grafíaalt|[[جون]]}}\n{{-noun-}}[[Categoría:MS:Sustantibos]]\n'''Jun'''\n# [[chunio]].\n\n==Se beigan también==\n* (''mes''): Dezaga: [[Mei]]. Debant: [[Julai]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "波蘭語", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the People's Republic of China.svg|40px]] '''''[[Wiktionary:Chinés|Chinés]]''''' <small>- ''中文''</small></div>=\n==Sustantivo==\n# [[polonés]]\n", "{{-zh-}}\n\n{{-adj-}}[[Categoría:ZH:Adchectivos]]\n# [[polonés]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "รู้จักมักคุ้น", "=<div id=\"toc\" class=\"toccolours\" > '''''[[Wiktionary:Tailandés|Tailandés]]''''' <small>- ''Tailandés''</small></div>=\n==Sustantivo==\n# [[conocer]].\n", "{{-th-}}\n{{Prenunziazión|/rúː.tɕàk.mák.kʰún/}}\n{{-verb-}}\n#[[conocer]].\n\n[[categoría:TH:Berbos]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "играя", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Bulgaria.svg|40px]] '''''[[Wiktionary:Bulgaro|Bulgaro]]''''' <small>- ''Български''</small></div>=\n==Sustantivo==\n# [[chugar]]\n", "{{-bg-}}\n{{-verb-}}\n'''играя'''\n# [[chugar]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "šonkaulis", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Lithuania.svg|40px]] '''''[[Wiktionary:Lituán|Lituán]]''''' <small>- ''Lietuvių kalba''</small></div>=\n==Sustantivo==\n# [[costiella]]\n", "{{-lt-}}\n{{-noun-}}\n'''šonkaulis'''\n# [[costiella]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "bürgüt", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Turkmenistan.svg|40px]] '''''[[Wiktionary:Turquemán|Turquemán]]''''' <small>- ''Türkmençe''</small></div>=\n==Sustantivo==\n# [[alica]]\n", "{{-tk-}}\n{{Prenunziazión}}\n{{Etimolochía}}\n{{-noun-}}\n[[Categoría:TK:Sustantibos]]\n'''bürgüt'''\n# [[alica]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "☉", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the United Nations.svg|40px]] '''''[[internacional|Internacional]]''''' </div>=\n==Sustantivo==\n# (astronomía, astrolochía) o [[sol|Sol]]\n# (alquimia) lo metal planetario [[oro]]\n", "{{-mul-}}\n[[Imachen:Sun symbol (fixed width).svg|80px|right|frameless|{{PAGENAME}}]]\n{{-symbol-}}\n# (astronomía, astrolochía) o [[sol|Sol]]\n# (alquimia) lo metal planetario [[oro]]\n\n===Eixemplos d'emplego===\n:[1]: [[L☉|''L''<sub>☉</sub>]], [[M☉|''M''<sub>☉</sub>]], [[R☉|''R''<sub>☉</sub>]]\n\n==Se veigan tamién==\n{{simbolos planetarios}}", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "au", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n==Sustantivo==\n# [[Animal]] bertebrato amniota.\n=Catalán=\n==Sustantivo==\n# [[au]].\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_France.svg|40px]] '''''[[Wiktionary:Franzés|Francés]]''''' <small>- ''Français''</small></div>=\n==Sustantivo==\n# Contrazión de ''à le'', [[ta|Ta]] [[lo|lo]].\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Hawaii.svg|40px]] '''''[[Wiktionary:Hawayán|Hawayán]]''''' <small>- ''‘Ōlelo Hawai‘i''</small></div>=\n==Sustantivo==\n# Pronombre presonal: [[yo]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Rapa_Nui,_Chile.svg|40px]] '''''[[Wiktionary:Rapanui|Rapa nui]]''''' <small>- ''Vananga Rapa Nui''</small></div>=\n==Sustantivo==\n# Pronombre presonal. [[yo]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Kenya.svg|40px]] '''''[[Wiktionary:Swahili|Swahili]]''''' <small>- ''Kiswahili''</small></div>=\n==Sustantivo==\n# [[ó]], [[u]]\n", "[[Image:Flying mallard duck - female.jpg|150px|right|thumb|Fembra d'[[anedo]] (un '''au''') aturando-se en l'[[augua]].]]\n{{-an-}}\n{{Prenunziazión|[ˈaw]}}\n{{Etimolochía|latín|avis}}\n\n{{-noun.fem-}}\n'''au'''\n\n1.[[Animal]] bertebrato amniota de [[sangre]] calient, con o cuerpo cobierto de [[pluma]]s, [[pipón]] sin de garra [[dient]] e las estremidaz anteriors con forma d'[[ala]]s.\n{{inflect.sust.fem|ab|ab|a}}\n*'''<u>Forma castellanizata</u>''': '''abe''' (''pl.'' '''abes''')\n*'''<u>Sinonimo parzial</u>''': '''[[paxaro]]''' ([[Project:Notazión de sinonimias dialeutals|OCC.]]), '''[[muixón]]''' ([[Project:Notazión de sinonimias dialeutals|SOB + RIB.]]).\n\n{{-interj-}}\n'''au'''\n\n2. Enfatiza ta que s'emprenzipie un mobimient.\n*''p.ex. <u>Au!</u> Marcha!''\n\n{{-trans-}}  \n:*{{ast}}: ''sust.'' {{trans|ast|ave|1}} ''f''\n:*{{ca}}: ''sust.'' {{trans|ca|au|1}} ''f''; ''interj.'' {{trans|ca|au|2}}\n:*{{de}}: ''sust.'' {{trans|de|Vogel|1}} ''n''; ''interj.'' {{trans|de|komm|2}}\n:*{{es}}: ''sust.'' {{trans|es|ave|1}} ''f''; ''interj.'' {{trans|es|venga|2}}\n:*{{en}}: ''sust.'' {{trans|en|bird|1}}; ''interj.'' {{trans|en|come on|2}}\n:*{{fr}}: ''sust.'' {{trans|fr|oiseau|1}}; ''interj.'' {{trans|fr|allez|2}}\n:*{{la}}: ''sust.'' {{trans|la|avis|1}}\n:*{{it}}: ''sust.'' {{trans|it|uccello|1}}; ''interj.'' {{trans|it|vieni|2}}\n:*{{oc}}: ''sust.'' {{trans|oc|aucèl|1}}; ''interj.'' {{trans|oc|au|2}}\n:*{{pl}}: ''sust.'' {{trans|pl|ptak|1}} ''m''\n:*{{pt}}: ''sust.'' {{trans|pt|ave|1}} ''f''; ''interj.'' {{trans|pt|vem|2}}\n:*{{scn}}: ''sust.'' {{trans|scn|auceddu|1}}; ''interj.'' {{trans|scn|veni|2}}\n|}\n\n==Se beiga tamién==\n\n*[[muixón]] ó [[muxón]]\n\n==Enrastres esternos==\n{{Wikipedia|Au|aus}}\n{{Wikispecies_line|Aves|Aves}}\n{{Commonscat|Aves|aus}}\n|\n\n{{-ca-}}\n{{Prenunziazión|[ˈaw]}}\n{{Etimolochía|latín|avis}}\n\n{{-noun.fem-}}[[categoría:CA:Sustantibos femenins]]\n'''au'''\n\n*'''<u>Chenero</u>:''' femenino\n*'''<u>Plural</u>:''' ''aus''\n\n#[[au]].\n\n*'''<u>Sinonimo parzial</u>''': '''[[ocell]]''', '''[[moixó]]''' (catalán d'Aragón).\n\n{{-trans-}} \n:*{{an}}: ''sust.'' [[au]]\n:*{{de}}: ''sust.'' {{trans|de|Vogel}} ''n''\n:*{{es}}: ''sust.'' {{trans|es|ave}} ''f''\n:*{{en}}: ''sust.'' {{trans|en|bird}}\n:*{{fr}}: ''sust.'' {{trans|fr|oiseau}}\n:*{{it}}: ''sust.'' {{trans|it|uccello}}\n:*{{la}}: ''sust.'' {{trans|la|avis}}\n:*{{oc}}: ''sust.'' {{trans|oc|aucèl}}\n:*{{pt}}: ''sust.'' {{trans|pt|ave}} ''f''\n:*{{scn}}: ''sust.'' {{trans|scn|auceddu}}\n|}\n\n{{-fr-}}\n{{Prenunziazión|[o]}}\n{{PrenAudio|Fr-au.ogg}} (Francia)\n\n{{-prep-}}[[categoría:FR:Preposizions]]\n'''au'''\n#Contrazión de ''à le'', [[ta|Ta]] [[lo|lo]] (ta'l, ta'o, t'o).\n*'''Exemplo:''' ''Je [[vais]] au [[marché]]''. \"Yo boi ta'l [[mercato]]\".\n\n#[[en|En]].\n*'''Exemplo:''' ''Ce train s’arrête au Mans''. \"Este tren s'atura en Mans\".\n\n{{-adverb-}}[[categoría:FR:Alberbios]]\n'''au'''\n#[[tan|Tan]].\n*'''Exemplo:''' ''Elle est au belle que sa mère''. \"Ela ye tan berroya como la suya maire\".\n\n{{-haw-}}\n{{-pron-}}[[categoría:HAW:Pronombres]]\n'''au'''\n#Pronombre presonal: [[yo]]\n\n{{-rap-}}\n{{-pron-}}[[categoría:RAP:Pronombres]]\n'''au'''\n#Pronombre presonal. [[yo]]\n\n{{-sw-}}\n{{-conj-}}[[categoría:SW:Conchunzions]]\n'''au'''\n#[[ó]], [[u]]", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 21), stats.language_records);
    try std.testing.expectEqual(@as(usize, 18), stats.language_blobs);
    const expected = [_]struct { title: []const u8, owner: []const u8, code: []const u8, own_heading: []const u8, forbidden: []const u8 }{
        .{ .title = "mùsica", .owner = "Piedmontese", .code = "pms", .own_heading = "Piemontés", .forbidden = "Secilián" },
        .{ .title = "mùsica", .owner = "siciliano", .code = "scn", .own_heading = "Secilián", .forbidden = "Piemontés" },
        .{ .title = "diya", .owner = "aragonés", .code = "an", .own_heading = "Aragonés", .forbidden = "Chodigoespañol" },
        .{ .title = "diya", .owner = "ladino", .code = "lad", .own_heading = "Chodigoespañol", .forbidden = "Aragonés" },
        .{ .title = "an", .owner = "francés", .code = "fr", .own_heading = "Francés", .forbidden = "Friulán" },
        .{ .title = "an", .owner = "friulano", .code = "fur", .own_heading = "Friulán", .forbidden = "Francés" },
        .{ .title = "an", .owner = "occitano", .code = "oc", .own_heading = "Occitán", .forbidden = "Friulán" },
        .{ .title = "جون", .owner = "malayo", .code = "ms", .own_heading = "Malayo", .forbidden = "Piemontés" },
        .{ .title = "Jun", .owner = "malayo", .code = "ms", .own_heading = "Malayo", .forbidden = "Friulán" },
        .{ .title = "波蘭語", .owner = "chino", .code = "zh", .own_heading = "Chinés", .forbidden = "Aragonés" },
        .{ .title = "รู้จักมักคุ้น", .owner = "tai", .code = "th", .own_heading = "Tailandés", .forbidden = "Aragonés" },
        .{ .title = "играя", .owner = "búlgaro", .code = "bg", .own_heading = "Bulgaro", .forbidden = "Aragonés" },
        .{ .title = "šonkaulis", .owner = "lituano", .code = "lt", .own_heading = "Lituán", .forbidden = "Aragonés" },
        .{ .title = "bürgüt", .owner = "turcomano", .code = "tk", .own_heading = "Turquemán", .forbidden = "Aragonés" },
        .{ .title = "☉", .owner = "Multiple languages", .code = "mul", .own_heading = "Internacional", .forbidden = "Aragonés" },
        .{ .title = "au", .owner = "aragonés", .code = "an", .own_heading = "Aragonés", .forbidden = "Hawayán" },
        .{ .title = "au", .owner = "catalán", .code = "ca", .own_heading = "Catalán", .forbidden = "Hawayán" },
        .{ .title = "au", .owner = "francés", .code = "fr", .own_heading = "Francés", .forbidden = "Hawayán" },
        .{ .title = "au", .owner = "hawaiano", .code = "haw", .own_heading = "Hawayán", .forbidden = "Swahili" },
        .{ .title = "au", .owner = "Rapanui", .code = "rap", .own_heading = "Rapa nui", .forbidden = "Hawayán" },
        .{ .title = "au", .owner = "suajili", .code = "sw", .own_heading = "Swahili", .forbidden = "Hawayán" },
    };
    for (expected) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row.owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row.code, decoded.entry.language_code);
        var own: usize = 0;
        var definitions: usize = 0;
        var actions: usize = 0;
        for (decoded.entry.sections) |section| {
            try std.testing.expect(std.mem.indexOf(u8, section.title, row.forbidden) == null);
            if (std.mem.indexOf(u8, section.title, row.own_heading) != null) own += 1;
            for (section.blocks) |block| {
                if (block.kind == .definition or (block.kind == .paragraph and block.spans.len != 0 and std.mem.indexOf(u8, block.spans[0].text, "24 oras") != null)) definitions += 1;
                for (block.spans) |span| if (span.kind == .link and (std.mem.eql(u8, span.target, "mosica") or std.mem.eql(u8, span.target, "año") or std.mem.eql(u8, span.target, "añada") or std.mem.eql(u8, span.target, "chunio") or std.mem.eql(u8, span.target, "polonés") or std.mem.eql(u8, span.target, "conocer") or std.mem.eql(u8, span.target, "chugar") or std.mem.eql(u8, span.target, "costiella") or std.mem.eql(u8, span.target, "alica") or std.mem.eql(u8, span.target, "sol") or std.mem.eql(u8, span.target, "oro") or std.mem.eql(u8, span.target, "Animal") or std.mem.eql(u8, span.target, "au") or std.mem.eql(u8, span.target, "ta") or std.mem.eql(u8, span.target, "lo") or std.mem.eql(u8, span.target, "yo") or std.mem.eql(u8, span.target, "ó") or std.mem.eql(u8, span.target, "u"))) {
                    actions += 1;
                };
            }
        }
        try std.testing.expectEqual(@as(usize, 1), own);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, row.title, "☉")) 2 else 1), definitions);
        if (std.mem.eql(u8, row.title, "au")) {
            var own_targets: usize = 0;
            for (decoded.entry.sections) |section| {
                if (!std.mem.eql(u8, row.code, "haw")) try std.testing.expect(std.mem.indexOf(u8, section.title, "Hawayán") == null);
                if (!std.mem.eql(u8, row.code, "rap")) try std.testing.expect(std.mem.indexOf(u8, section.title, "Rapa nui") == null);
                if (!std.mem.eql(u8, row.code, "sw")) try std.testing.expect(std.mem.indexOf(u8, section.title, "Swahili") == null);
                for (section.blocks) |block| for (block.spans) |span| {
                    if (span.kind != .link) continue;
                    if ((std.mem.eql(u8, row.code, "haw") or std.mem.eql(u8, row.code, "rap")) and std.mem.eql(u8, span.target, "yo")) own_targets += 1;
                    if (std.mem.eql(u8, row.code, "sw") and (std.mem.eql(u8, span.target, "ó") or std.mem.eql(u8, span.target, "u"))) own_targets += 1;
                };
            }
            if (std.mem.eql(u8, row.code, "haw") or std.mem.eql(u8, row.code, "rap")) try std.testing.expectEqual(@as(usize, 1), own_targets);
            if (std.mem.eql(u8, row.code, "sw")) try std.testing.expectEqual(@as(usize, 2), own_targets);
        }
        if (!std.mem.eql(u8, row.title, "diya")) try std.testing.expect(actions > 0);
    }
}

test "ANG noun tables retain Old English ownership without claiming genuine Nama" {
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
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "nmx")) return .{ .code = "nmx", .heading = "Nama" };
            if (std.mem.eql(u8, value, "Englisc") or std.mem.eql(u8, value, "ang")) return .{ .code = "ang", .heading = "Englisc" };
            return TestLanguages.resolve(null, value);
        }
        fn trusted(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "Englisc")) return resolve(null, value);
            return TestLanguages.trusted(null, value);
        }
        fn strong(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            if (std.mem.eql(u8, value, "Nama") or std.mem.eql(u8, value, "Englisc")) return resolve(null, value);
            return TestLanguages.strong(null, value);
        }
    };
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tangwiktionary\n# dump-date\t20261001\n# content-language\tang\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tBysen\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tFlocc\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var codes = TestLanguages.codes();
    codes.get_fn = Local.get;
    codes.resolve_fn = Local.resolve;
    codes.trusted_fn = Local.trusted;
    codes.strong_fn = Local.strong;
    codes.namespace_catalog = &namespaces;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ang-noun-table", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact seaxisc7072/rev53032 source; representative expansion retains its
    // observed three tables, two noun definitions, headings and lexical links.
    // This is a Writer/codec ownership test, not a fresh Lua expansion claim.
    const raw = "=={{sprǣc|ang}}==\n\n==Tōgeīecendlic==\n\n=== {{Wordcynn|Tōgeīecendlic}} ===\n{{Tógeíecendlic-Tabule|\n1. Stæpe=Seaxisc\n|2. Stæpe= -\n|3. Stæpe= -\n|Othera_declinunga=Seaxisc (declīnung)\n}}\n\n* of landum þāra Seaxa, oþþe of þǣre þēode Seaxes (þā þe on grēatum worulddǣle belifon)\n\n==Nama==\n=== {{m}} {{Wordcynn|Nama}} ===\n{{Naman-Tabule|\nHwā oþþe hwæt? (Ānfeald)=se Seaxisc\n|Hwā oþþe hwæt? (Manigfeald)=þā Seaxisce\n|Hwæs? (Ānfeald)=þæs Seaxisces\n|Hwæs? (Manigfeald)=þāra Seaxisca\n|Hwǣm? (Ānfeald)=þǣm Seaxisce\n|Hwǣm? (Manigfeald)=þǣm Seaxiscum\n|Hwȳ? (Ānfeald)=þȳ Seaxisce\n|Hwȳ? (Manigfeald)=þǣm Seaxiscum\n|Hwone? (Ānfeald)=þone Seaxisc\n|Hwone? (Manigfeald)=þā Seaxisce\n\n}}\n\n* <small>'''''lēoda'''''</small>, (þā) Seaxa, sum mann þe of Seaxe cymþ\n\n\n\n\n\n\n\n\n\n\n\n\n=== {{n}} {{Wordcynn|Nama}} ===\n{{Naman-Tabule|\nHwā oþþe hwæt? (Ānfeald)=þæt Seaxisc\n|Hwā oþþe hwæt? (Manigfeald)=þā Seaxisc\n|Hwæs? (Ānfeald)=þæs Seaxisces\n|Hwæs? (Manigfeald)=þāra Seaxiscra\n|Hwǣm? (Ānfeald)=þǣm Seaxisce\n|Hwǣm? (Manigfeald)=þǣm Seaxiscum\n|Hwȳ? (Ānfeald)=þȳ Seaxisce\n|Hwȳ? (Manigfeald)=þǣm Seaxiscum\n|Hwone? (Ānfeald)=þæt Seaxisc\n|Hwone? (Manigfeald)=þā Seaxisc\n\n}}\n\n#Sēo sprǣc gesprecen of þǣm lēodum on Seaxe (wierþþ [[Sahsisk]] on seaxisc gecweden)\n#Þæt Seaxisce blēo sumes wordes\n\n====Wordstǣr====\nOfcymþ þæt word [[Seaxe]] and [[-isc]].\n\n\n[[Category:Englisc tōgeīecendlic]]\n[[Category:Tōgeīecendlic ofgangen mid -isc]]\n[[Category:Englisc nama]]\n[[Category:Englisc werlic nama]]\n[[Category:Englisc nāhwæðer nama]]\n[[Category:Mennisc]]\n[[Category:Þēodhād]]";
    const expanded = "==Englisc==\n\n==Tōgeīecendlic==\n\n=== [[Help:Wordcynn|Tōgeīecendlic]][[Flocc:Tōgeīecendlic]] ===\n{|\n! Grundword !! Wiþmetendlic !! Oferstīgendlic\n|-\n| Seaxisc || - || -\n|-\n| colspan=\"3\" | Ealla ōðra ansīena: [[Seaxisc (declīnung)]]\n|}\n\n* of landum þāra Seaxa, oþþe of þǣre þēode Seaxes (þā þe on grēatum worulddǣle belifon)\n\n==Nama==\n=== Werlic [[Help:Wordcynn|Nama]][[Flocc:Nama]] ===\n{| style=\"float:right; border:1px solid #AAAAAA; margin-left:0.5em; margin-bottom:0.5em;\" rules=\"all\" cellpadding=\"3\" cellspacing=\"0\"\n! width=\"65\" bgcolor=\"#F4F4F4\" | [[Help:Cāsus|Cāsus]]\n! bgcolor=\"#FFFFE0\" | [[Help:Ānfeald|Ānfeald]]\n! bgcolor=\"#FFFFE0\" | [[Help:Manigfeald|Manigfeald]]\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Nemniendlic|Nemniendlic]]'''\n| '''se Seaxisc''' || '''þā Seaxisce'''\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Wrēgendlic|Wrēgendlic]]'''\n| þone Seaxisc || þā Seaxisce\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Āgniendlic|Āgniendlic]]'''\n| þæs Seaxisces || þāra Seaxisca\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Forgifendlic|Forgifendlic]]'''\n| þǣm Seaxisce || þǣm Seaxiscum\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Tōllic|Tōllic]]'''\n| þȳ Seaxisce || þǣm Seaxiscum\n|}\n\n* <small>'''''lēoda'''''</small>, (þā) Seaxa, sum mann þe of Seaxe cymþ\n\n\n\n\n\n\n\n\n\n\n\n\n=== Nāhwæðer [[Help:Wordcynn|Nama]][[Flocc:Nama]] ===\n{| style=\"float:right; border:1px solid #AAAAAA; margin-left:0.5em; margin-bottom:0.5em;\" rules=\"all\" cellpadding=\"3\" cellspacing=\"0\"\n! width=\"65\" bgcolor=\"#F4F4F4\" | [[Help:Cāsus|Cāsus]]\n! bgcolor=\"#FFFFE0\" | [[Help:Ānfeald|Ānfeald]]\n! bgcolor=\"#FFFFE0\" | [[Help:Manigfeald|Manigfeald]]\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Nemniendlic|Nemniendlic]]'''\n| '''þæt Seaxisc''' || '''þā Seaxisc'''\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Wrēgendlic|Wrēgendlic]]'''\n| þæt Seaxisc || þā Seaxisc\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Āgniendlic|Āgniendlic]]'''\n| þæs Seaxisces || þāra Seaxiscra\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Forgifendlic|Forgifendlic]]'''\n| þǣm Seaxisce || þǣm Seaxiscum\n|-\n| bgcolor=\"#F4F4F4\" | '''[[Help:Tōllic|Tōllic]]'''\n| þȳ Seaxisce || þǣm Seaxiscum\n|}\n\n#Sēo sprǣc gesprecen of þǣm lēodum on Seaxe (wierþþ [[Sahsisk]] on seaxisc gecweden)\n#Þæt Seaxisce blēo sumes wordes\n\n====Wordstǣr====\nOfcymþ þæt word [[Seaxe]] and [[-isc]].\n\n\n[[Category:Englisc tōgeīecendlic]]\n[[Category:Tōgeīecendlic ofgangen mid -isc]]\n[[Category:Englisc nama]]\n[[Category:Englisc werlic nama]]\n[[Category:Englisc nāhwæðer nama]]\n[[Category:Mennisc]]\n[[Category:Þēodhād]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "seaxisc", expanded, raw, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "seaxisc-with-nama", expanded ++ "\n==Nama==\n# TRUE_NAMA\n", raw ++ "\n=={{sprǣc|nmx}}==\n# TRUE_NAMA\n", null);
    const prefix_raw = "=={{sprǣc|ang}}==\n# ANG_PREFIX\n";
    const prefix_expanded = "==Englisc==\n# ANG_PREFIX\n";
    const cue = "=== {{m}} {{Wordcynn|Nama}} ===\n{{Naman-Tabule|case=form}}\n";
    const rendered_cue = "=== Werlic [[Help:Wordcynn|Nama]][[Flocc:Nama]] ===\n";
    const cases = .{
        .{ "missing-cue", prefix_raw ++ "==Nama==\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "missing-table", prefix_raw ++ "==Nama==\n=== {{m}} {{Wordcynn|Nama}} ===\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
        .{ "unclosed-table", prefix_raw ++ "==Nama==\n=== {{m}} {{Wordcynn|Nama}} ===\n{{Naman-Tabule|case=form\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
        .{ "protected-cue", prefix_raw ++ "==Nama==\n<nowiki>" ++ cue ++ "</nowiki>\n# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" },
        .{ "late-cue", prefix_raw ++ "==Nama==\n# NAMA_BODY\n" ++ cue, prefix_expanded ++ "==Nama==\n# NAMA_BODY\n" ++ rendered_cue },
        .{ "uncorroborated-expansion", prefix_raw ++ "==Nama==\n" ++ cue ++ "# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n=== Different heading ===\n# NAMA_BODY\n" },
        .{ "implicit-prior-owner", prefix_expanded ++ "==Nama==\n" ++ cue ++ "# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
        .{ "intervening-owner", prefix_raw ++ "==French==\n# FR_PREFIX\n==Nama==\n" ++ cue ++ "# NAMA_BODY\n", prefix_expanded ++ "==French==\n# FR_PREFIX\n==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
        .{ "intervening-unknown", prefix_raw ++ "==Unknown heading==\n# UNKNOWN\n==Nama==\n" ++ cue ++ "# NAMA_BODY\n", prefix_expanded ++ "==Unknown heading==\n# UNKNOWN\n==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
        .{ "explicit-nama", prefix_raw ++ "=={{sprǣc|nmx}}==\n" ++ cue ++ "# NAMA_BODY\n", prefix_expanded ++ "==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n" },
    };
    inline for (cases) |row| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, row[0], row[2], row[1], null);
    var other_codes = codes;
    other_codes.namespace_catalog = null;
    writer.language_codes = other_codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "without-edition", prefix_expanded ++ "==Nama==\n" ++ rendered_cue ++ "# NAMA_BODY\n", prefix_raw ++ "==Nama==\n" ++ cue ++ "# NAMA_BODY\n", null);
    writer.language_codes = codes;
    _ = try writer.finish(codes);
    var english_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Englisc"));
    defer english_map.deinit();
    const english = try blob_format.inspect(english_map.bytes);
    const metadata = try english.languageMetadata();
    try std.testing.expectEqualStrings("ang", metadata.code);
    var english_index = try english.buildTrustedIndexAlloc(a);
    defer english_index.deinit(a);
    var nama_map = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "Nama"));
    defer nama_map.deinit();
    const nama = try blob_format.inspect(nama_map.bytes);
    try std.testing.expectEqualStrings("nmx", (try nama.languageMetadata()).code);
    var nama_index = try nama.buildTrustedIndexAlloc(a);
    defer nama_index.deinit(a);
    try std.testing.expect((try nama_index.find("seaxisc")) == null);
    for ([_][]const u8{ "seaxisc", "seaxisc-with-nama" }) |title| {
        const record = (try english_index.find(title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var tables: usize = 0;
        var definitions: usize = 0;
        var lexical_links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            if (block.table != null) tables += 1;
            if (block.kind == .definition) definitions += 1;
            for (block.spans) |span| {
                if (std.mem.eql(u8, span.target, "Sahsisk") or std.mem.eql(u8, span.target, "Seaxe") or std.mem.eql(u8, span.target, "-isc")) lexical_links += 1;
                try std.testing.expect(std.mem.indexOf(u8, span.text, "TRUE_NAMA") == null);
            }
        };
        try std.testing.expectEqual(@as(usize, 3), tables);
        try std.testing.expectEqual(@as(usize, 2), definitions);
        try std.testing.expectEqual(@as(usize, 3), lexical_links);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, "se Seaxisc") != null);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, "þæt Seaxisc") != null);
        try std.testing.expect(std.mem.indexOf(u8, record.payload, "Þæt Seaxisce blēo") != null);
    }
    const genuine = (try nama_index.find("seaxisc-with-nama")).?;
    try std.testing.expect(std.mem.indexOf(u8, genuine.payload, "TRUE_NAMA") != null);
    try std.testing.expect(std.mem.indexOf(u8, genuine.payload, "se Seaxisc") == null);
    inline for (cases) |row| {
        try std.testing.expect(std.mem.indexOf(u8, (try nama_index.find(row[0])).?.payload, "NAMA_BODY") != null);
        if (try english_index.find(row[0])) |record| try std.testing.expect(std.mem.indexOf(u8, record.payload, "NAMA_BODY") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, (try nama_index.find("without-edition")).?.payload, "NAMA_BODY") != null);
}

test "Arabic explicit linked declarations and raw corroborated table boundaries preserve owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |owner| owner.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "en", "الإنجليزية", "إنجليزية" }, .{ "fr", "الفرنسية", "فرنسية" }, .{ "ca", "الكتالانية", "كاتالونية" }, .{ "de", "الألمانية", "ألمانية" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]) or std.mem.eql(u8, value, row[2])) return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve, .strong_fn = Local.resolve, .namespace_catalog = &namespaces };
    const chrome_heading = "[[إِنْجْلِيزِيَّة|فِي ٱللُّغَةِ ٱلْإِنْجْلِيزِيَّةِ]]:";
    const dalembert_heading = "[[لُغَة|لغة]] [[إِنْجْلِيزِيَّة|إنجليزية]]";
    for ([_][]const u8{ chrome_heading, dalembert_heading }) |heading| {
        const section: language_source.Section = .{ .heading = heading, .source = "" };
        try std.testing.expectEqualStrings("en", resolveSection(codes, section).?.code);
        try std.testing.expectEqualStrings("en", boundaryLanguage(codes, section).?.code);
        try std.testing.expect(hasExplicitLanguageDeclaration(codes, section));
        var foreign = codes;
        foreign.namespace_catalog = null;
        try std.testing.expect(arabicLinkedOwner(foreign, heading) == null);
    }
    for ([_][]const u8{
        "[[إِنْجْلِيزِيَّة|فِي ٱللُّغَةِ ٱلْأَلْمَانِيَّةِ]]:",
        "[[لغة|لغة]] [[إنجليزية|ألمانية]]",
        "[[لغة|لغة]] [[unknown|unknown]]",
    }) |heading| {
        const section: language_source.Section = .{ .heading = heading, .source = "" };
        try std.testing.expect(hasExplicitLanguageDeclaration(codes, section));
        try std.testing.expect(resolveSection(codes, section) == null);
        try std.testing.expect(boundaryLanguage(codes, section) == null);
    }
    for ([_][]const u8{
        "[[لغة|أخرى]] [[إنجليزية|إنجليزية]]",
        "prefix [[لغة]] [[إنجليزية]]",
        "[[إنجليزية|في اللغة الإنجليزية]]: extra",
        "[[إنجليزية|في اللغة الإنجليزية|extra]]:",
        "<nowiki>[[لغة]] [[إنجليزية]]</nowiki>",
        "[[لغة]] [[إنجليزية]] [[فرنسية]]",
    }) |heading| try std.testing.expect(arabicLinkedOwner(codes, heading) == null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "chrome", "=[[إِنْجْلِيزِيَّة|فِي ٱللُّغَةِ ٱلْإِنْجْلِيزِيَّةِ]]:=\n=== الكلمة ===\n'''chrome'''\n=== مادة ===\nمصطلح علمي\n=== [[لُغَة|لغة]] ===\n[[إِنْجْلِيزِيَّة|إنجليزية]]\n=== عربية ===\nالمعنى:\n# كروم\n", "{{انجليزية}}\n=== الكلمة ===\n'''chrome'''\n=== مادة ===\nمصطلح علمي\n\n=== [[لُغَة|لغة]] ===\n[[إِنْجْلِيزِيَّة|إنجليزية]]\n\n=== عربية ===\nالمعنى:\n# كروم\n\n[[تصنيف:قاموس علمي]]\n[[تصنيف:إنجليزية]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "d’Alembertian", "== الكلمة ==\n'''d’Alembertian'''\n\n== [[لُغَة|لغة]] [[إِنْجْلِيزِيَّة|إنجليزية]] ==\nd’Alembertian هي مصطلح علمي في اللغة الإنجليزية\n\n== ترجمة المعنى الإنجليزي ==\n\n=== اللغة [[عربية|العربية]] ===\n# مؤشر دالمبير\n\n[[تصنيف:قاموس علمي]]\n[[تصنيف:إنجليزية]]", "== الكلمة ==\n'''d’Alembertian'''\n\n== [[لُغَة|لغة]] [[إِنْجْلِيزِيَّة|إنجليزية]] ==\nd’Alembertian هي مصطلح علمي في اللغة الإنجليزية\n\n== ترجمة المعنى الإنجليزي ==\n\n=== اللغة [[عربية|العربية]] ===\n# مؤشر دالمبير\n\n[[تصنيف:قاموس علمي]]\n[[تصنيف:إنجليزية]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "or", "== إنجليزية ==\n=== المعاني ===\n# [[أَوْ]]\n# [[أم]]\n== فرنسية ==\n=== المعاني ===\n# [[ذَهَبَ]]\n# [[لَكِنْ]]\n=== انظر أيضا ===\n{| class=\"wikitable\" style=\"text-align:center; order\n|+ ''{{أزرق|أدوات ربط فرنسية}}''\n! scope=\"row\" | الحرف\n|[[mais]]||[[ou]]||[[et]]||[[donc]]||[[or]]||[[ni]]||[[car]]\n|-}\n</center><includeonly>[[تصنيف:قوالب تحرير الكلمات الفرنسية]]</includeonly>\n<noinclude>[[تصنيف:قوالب الجداول]]</noinclude>\n== كاتالونية[[تصنيف:كاتالونية]] ==\n=== المعاني ===\n* [[ذَهَبَ]]\n", "== {{اللغة|إنجليزية}} ==\n=== المعاني ===\n# [[أَوْ]]\n# [[أم]]\n==== ترجمات ====\n{{trans-top|conjunction}}\n* {{af}}: {{t+|af|of}}\n* {{sq}}: {{t+|sq|ose}}, {{t+|sq|apo}}, {{t+|sq|a}}\n* Amharic: {{t|am|ወይስ|sc=Ethi}}\n* Arabic: {{t|ar|أَو}}, {{t+|ar|أَم}} {{qualifier|in questions}}, {{t|ar|إِمَّا}}\n* Aragonese: {{t+|an|u}}\n* Aramaic:\n*: {{he}}: [[או]] (’āw)\n*: Syriac: [[ܐܘ]] (’āw)\n* Armenian: {{t+|hy|կամ}}\n* Aromanian: {{t|rup|icã}}\n* Assamese: {{l|as|বা}}\n* Asturian: {{t+|ast|o}}\n* Azeri: {{t+|az|ya}}, {{t+|az|və ya}}\n* Bashkir: {{t|ba|йәки}}, {{t|ba|йә}}\n* Basque: {{t+|eu|edo}}, {{t+|eu|ala}}\n* Belarusian: {{t|be|або́}}\n* Bengali: {{t|bn|বা|tr=ba|sc=Beng}}, {{t+|bn|অথবা|tr=ôthôba|sc=Beng}}, {{t|bn|কিংবা|tr=kingba|sc=Beng}}\n* Breton: {{t+|br|pe}}\n* Bulgarian: {{t+|bg|и́ли}}\n* Burmese: {{t+|my|သို့မဟုတ်|sc=Mymr}}\n* Catalan: {{t+|ca|o}}, {{t|ca|o bé}}\n* Chechen: {{t|ce|я}}\n* Chinese:\n*: Cantonese: {{t|yue|定係|tr=ding6 hai6|sc=Hani}}\n*: Mandarin: {{t+|cmn|或|tr=huò|sc=Hani}}, {{t+|cmn|或者|tr=huòzhě|sc=Hani}}; {{t+|cmn|還是|sc=Hani}}, {{t+|cmn|还是|tr=háishi|sc=Hani}} {{qualifier|in questions}}\n* Chuvash: {{t|cv|е}}\n* Cornish: {{t|kw|po}}\n* Crimean Tatar: {{t|crh|ya}}\n* Czech: {{t+|cs|nebo}}\n* Danish: {{t+|da|eller}}\n* Dutch: {{t+|nl|of}}\n* Egyptian: usually null; sometimes {{t|egy|r-pw}}\n*: <hiero>r: Z1-p-w</hiero>\n* Esperanto: {{t+|eo|aŭ}}\n* Estonian: {{t+|et|või}}\n* Faroese: {{t|fo|ella}}\n* Finnish: {{t+|fi|tai}} {{qualifier|exclusive, only in affirmative clauses}}; {{t+|fi|vai}} (''inclusive, only in '''question''' clauses'')\n* French: {{t+|fr|ou}}\n*: Old French: {{t|fro|ou}}\n* Galician: {{t+|gl|ou}}\n* Georgian: {{t|ka|ანუ}}\n* German: {{t+|de|oder}}\n* Gothic: {{t|got|𐍅𐌰𐌿}}\n* Greek: {{t+|el|ή}}, {{t+|el|είτε}}\n*: Ancient: {{t|grc|ἤ}}\n* Hawaiian: {{t|haw|paha|alt=ā ... paha}}, {{t|haw|a i ʻole}}\n* Hebrew: {{t+|he|אוֹ|tr='o}}\n* Hindi: {{t+|hi|या|tr=yā}}, {{t+|hi|कि|tr=ki|sc=Deva}}, {{t+|hi|वा|tr=vā|sc=Deva}}, {{t+|hi|अथवा|sc=Deva}}\n* Hungarian: {{t+|hu|vagy}}\n* Icelandic: {{t+|is|eða}}\n* Ido: {{t+|io|od}}, {{t+|io|o}}\n* Indonesian: {{t+|id|atau}}\n* Interlingua: {{t+|ia|o}}\n* Irish: {{t|ga|nó}}\n* Italian: {{t+|it|o}}, {{t|it|od}} (''euphonic alt. form used before a vowel''), {{t+|it|oppure}}\n* Japanese: {{t+|ja|または|tr=mata wa}} ({{t+|ja|又は}}), {{t+|ja|あるいは|tr=arui wa}}, {{t+|ja|か|tr=ka}}, {{t+|ja|それとも|tr=soretomo}}\n* Javanese: {{t+|jv|utawa}}, {{t+|jv|utawi}}, {{t|jv|atawa}}\n* Kannada: {{t+|kn|ಅಥವಾ|sc=Knda}}\n* Kashubian: {{t|csb|abò}}\n* Kazakh: {{t+|kk|не}}, {{t+|kk|немесе}}, {{t+|kk|я}}, {{t|kk|яки}}\n* Khmer: {{t+|km|ឬ|tr=reu|sc=Khmr}}\n* Korean: {{t+|ko|또는}}\n* Kurdish:\n*: Sorani: {{t+|ku|یا|tr=ya|sc=ku-Arab}}, {{t|ku|یان|tr=yan|sc=ku-Arab}}\n* Kyrgyz: {{t+|ky|же}}\n* Lao: {{t|lo|ບໍ້|sc=Laoo}}, {{t|lo|ຫລື|sc=Laoo}}, {{t|lo|ຫຼື|sc=Laoo}}\n* Latgalian: {{t|ltg|ci}}, {{t|ltg|voi}}, {{t|ltg|aba}}\n{{trans-mid}}\n* Latin: {{t+|la|aut}}, {{t+|la|seu}}, {{t+|la|vel}}\n* Latvian: {{t|lv|vai}}, {{t|lv|jeb}}\n* Lithuanian: {{t+|lt|arba}}\n* Livonian: {{t|liv|või}}\n* Luxembourgish: {{t|lb|oder}}\n* Lü: {{t-needed|khb}}\n* Macedonian: {{t|mk|или}}\n* Malagasy: {{t+|mg|na}}, {{t+|mg|sa}}\n* Malay: {{t|ms|atau}}\n* Maltese: {{t|mt|jew}}\n* Maori: {{t|mi|rānei}}\n* Mongolian: {{t+|mn|эсвэл}}, {{t+|mn|буюу}}\n* Navajo: {{t|nv|éí doodaiiʼ éí}}, {{t|nv|doodaiiʼ}}\n* Neapolitan: {{t|nap|o}}\n* Northern Thai: {{t-needed|nod}}\n* Norwegian: {{t+|no|eller}}\n*: Bokmål: {{t|nb|ellers}} ''(otherwise)''\n*: Nynorsk: {{t|nn|elles}} ''(otherwise)''\n* Novial: {{t|nov|o}}\n* Old English: {{t|ang|hwæþer þe}}, {{t|ang|oþþe}}\n* Old Prussian: {{t|prg|anga, adder}}\n* Ottoman Turkish: {{t|ota|ویا|tr=veyā|sc=ota-Arab}}\n* Pashto: {{t+|ps|که|tr=ka}}, {{t|ps|لا|tr=lâ}}, {{t+|ps|يا|tr=yâ}}\n* Persian: {{t+|fa|یا|tr=yâ}}\n* Polish: {{t+|pl|albo}}, {{t+|pl|lub}}, {{t+|pl|czy}}\n* Portuguese: {{t+|pt|ou}}\n* Quechua: {{t|qu|icha}}\n* Rapa Nui: {{t|rap|o}}\n* Romanian: {{t+|ro|ori}}, {{t+|ro|sau}}\n* Russian: {{t+|ru|и́ли}}, {{t+|ru|ли́бо}}\n* Sardinian: {{t|sc|o}}\n* Scots: {{t|sco|or}}\n* Scottish Gaelic: {{t|gd|no}}, {{t|gd|neo}}, {{t|gd|air neo}}\n* Serbo-Croatian:\n*: Cyrillic: {{t|sh|или}}\n*: Roman: {{t+|sh|ili}}\n* Shan: {{t-needed|shn}}\n* Sindhi: {{t|sd|یا|tr=yā}}\n* Sinhalese: {{t|si|හෝ|sc=Sinh}}\n* Slovak: {{t|sk|alebo}}, {{t|sk|abo}}\n* Slovene: {{t+|sl|àli}}\n* Sorbian:\n*: Lower Sorbian: {{t|dsb|abo}}\n*: Upper Sorbian: {{t+|hsb|abo}}\n* Spanish: {{t+|es|o}}, {{qualifier|before words beginning in 'o-' or 'ho-'}} {{t+|es|u}}\n* Sudovian: {{t|xsv|ader}}\n* Swahili: {{t|sw|au}}\n* Swedish: {{t+|sv|eller}}\n* Tagalog: {{t|tl|o}}\n* Tajik: {{t+|tg|ё}}\n* Tamil: {{t+|ta|அல்லது|sc=Taml}}\n* Tatar: {{t|tt|яки}}, {{t|tt|яисә}}, {{t|tt|я}}\n* Telugu: {{t+|te|లేదా}}, {{t+|te|గాని}}\n* Thai: {{t+|th|หรือ}}, {{t|th|หรือว่า|tr=rĕu-wâa}}\n* Turkish: {{t+|tr|veya}}, {{t+|tr|ya da}}\n* Turkmen: {{t|tk|ýa}}, {{t|tk|ýada}}\n* Ukrainian: {{t+|uk|чи}}, {{t+|uk|або́}}\n* Urdu: {{t|ur|يا|tr=yā}}\n* Uyghur: {{t+|ug|ياكى|sc=ug-Arab}}\n* Uzbek: {{t+|uz|yoki}}\n* Vietnamese: {{t+|vi|hay}}, {{t|vi|hay là}}, {{t+|vi|hoặc}}\n* Vilamovian: {{t|wym|ober}}\n* Volapük: (before consonants) {{t+|vo|u}}, (before vowels) {{t+|vo|ud}}\n* Welsh: {{t|cy|neu}}\n* West Frisian: {{t+|fy|of}}\n* Yagnobi: {{t|yai|ё}}\n* Yiddish: {{t|yi|אָדער|tr=oder|sc=Hebr}}\n* Zhuang: {{t|za|rox}}, {{t|za|roxnaeuz}}\n{{trans-bottom}}\n\n== {{اللغة|فرنسية}} ==\n=== المعاني ===\n# [[ذَهَبَ]]\n# [[لَكِنْ]]\n=== انظر أيضا ===\n{{أدوات ربط فرنسية}}\n\n== {{اللغة|كاتالونية}} ==\n=== المعاني ===\n* [[ذَهَبَ]]", null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "heading-cell-negative", "== فرنسية ==\n{|\n|\n== كاتالونية ==\n# cell-only\n|}\n", "== {{اللغة|فرنسية}} ==\n{|\n|\n== {{اللغة|كاتالونية}} ==\n# cell-only\n|}\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    const expected = [_]struct { owner: []const u8, code: []const u8, title: []const u8 }{
        .{ .owner = "الإنجليزية", .code = "en", .title = "chrome" },
        .{ .owner = "الإنجليزية", .code = "en", .title = "d’Alembertian" },
        .{ .owner = "الإنجليزية", .code = "en", .title = "or" },
        .{ .owner = "الفرنسية", .code = "fr", .title = "or" },
        .{ .owner = "الكتالانية", .code = "ca", .title = "or" },
        .{ .owner = "الفرنسية", .code = "fr", .title = "heading-cell-negative" },
    };
    for (expected) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row.owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row.title)).?;
        const page = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row.code, page.entry.language_code);
        if (std.mem.eql(u8, row.title, "chrome") or std.mem.eql(u8, row.title, "d’Alembertian")) {
            const meaning = if (std.mem.eql(u8, row.title, "chrome")) "كروم" else "مؤشر دالمبير";
            var exact_meanings: usize = 0;
            var heading_actions: usize = 0;
            for (page.entry.sections) |section| for (section.blocks) |block| {
                if (block.kind == .definition and block.spans.len == 1 and std.mem.eql(u8, block.spans[0].text, meaning)) exact_meanings += 1;
                for (block.spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "إِنْجْلِيزِيَّة")) {
                    heading_actions += 1;
                };
            };
            try std.testing.expectEqual(@as(usize, 1), exact_meanings);
            try std.testing.expect(heading_actions >= 1);
        }
        if (std.mem.eql(u8, row.title, "or")) {
            var gold: usize = 0;
            var but: usize = 0;
            var english: usize = 0;
            for (page.entry.sections) |section| {
                if (std.mem.eql(u8, row.code, "fr")) try std.testing.expect(std.mem.indexOf(u8, section.title, "كاتالونية") == null);
                for (section.blocks) |block| for (block.spans) |span| {
                    if (span.kind != .link) continue;
                    if (std.mem.eql(u8, span.target, "ذَهَبَ")) gold += 1;
                    if (std.mem.eql(u8, span.target, "لَكِنْ")) but += 1;
                    if (std.mem.eql(u8, span.target, "أَوْ")) english += 1;
                };
            }
            const en = std.mem.eql(u8, row.code, "en");
            try std.testing.expectEqual(@as(usize, if (en) 0 else 1), gold);
            try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, row.code, "fr")) 1 else 0), but);
            try std.testing.expectEqual(@as(usize, if (en) 1 else 0), english);
        }
        if (std.mem.eql(u8, row.code, "ca")) try std.testing.expect((try index.find("heading-cell-negative")) == null);
    }
    const marker_codes: LanguageMarkers = .{ .codes = &codes, .raw_source = "== {{اللغة|كاتالونية}} ==\n# body\n", .expanded_source = "{|\n== كاتالونية ==\n|}\n== كاتالونية ==\n# body\n" };
    try std.testing.expect(!corroboratedArabicTableBoundary(&marker_codes, "كاتالونية"));
    for ([_][]const u8{ "<nowiki>\n== {{اللغة|كاتالونية}} ==\n</nowiki>", "{{outer|\n== {{اللغة|كاتالونية}} ==\n}}", "<!--\n== {{اللغة|كاتالونية}} ==\n-->" }) |raw| {
        const protected: LanguageMarkers = .{ .codes = &codes, .raw_source = raw, .expanded_source = "{|\n== كاتالونية ==\n" };
        try std.testing.expect(!corroboratedArabicTableBoundary(&protected, "كاتالونية"));
    }
    const report = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "fallback-pages.jsonl" }), a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, report, "malformed_table") != null);
}

test "captured definite Arabic language declarations retain trusted owners and unknown boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tملف\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const Local = struct {
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "en", "الإنجليزية", "إنجليزية" }, .{ "fr", "الفرنسية", "فرنسية" }, .{ "ar", "العربية", "عربية" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]) or std.mem.eql(u8, value, row[2])) return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    // Only the selected canonical TSV/local-name suffixes are authoritative;
    // the unhamza spelling is an explicit unknown, never a guessed alias.
    const codes: LanguageCodes = .{ .get_fn = Local.get, .namespace_catalog = &namespaces, .resolve_fn = Local.resolve, .trusted_fn = Local.resolve };
    const complete = language_source.Section{ .heading = "اللغة الإنجليزية", .source = "== اللغة الإنجليزية ==\n# meaning\n[[تصنيف:عربية]]" };
    try std.testing.expectEqualStrings("en", resolveSection(codes, complete).?.code);
    try std.testing.expectEqualStrings("en", boundaryLanguage(codes, complete).?.code);
    try std.testing.expect(hasExplicitLanguageDeclaration(codes, complete));
    const unknown = language_source.Section{ .heading = "اللغة الانجليزية", .source = "== اللغة الانجليزية ==\n# unknown\n" };
    try std.testing.expect(resolveSection(codes, unknown) == null);
    try std.testing.expect(boundaryLanguage(codes, unknown) == null);
    try std.testing.expect(hasExplicitLanguageDeclaration(codes, unknown));
    inline for (.{ "اللغة", "اللغةالإنجليزية", "اللغة [[إنجليزية|فرنسية]]", "اللغة إنجليزية|فرنسية", "اللغة إنجليزية فرنسية" }) |heading|
        try std.testing.expect(resolveArabicLanguageHeading(codes, heading) == null);
    var foreign = codes;
    foreign.namespace_catalog = null;
    try std.testing.expect(resolveArabicLanguageHeading(foreign, complete.heading) == null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const raw_napa = "{{أيضا|ملفوف نابا }}\n== اللغة الإنجليزية ==\n=== Napa cabbage ===\n'''الكلمة''' نوعها.\n# [[اسْم|اسم]].\n#* «Napa or napa cabbage is a type of Chinese cabbage originating near the Beijing region of China and is widely used in East Asian cuisine.» <ref>en.wikipedia.org/wiki/Napa_cabbage</ref>\n#: نابا أو الملفوف نابا هو نوع من الملفوف الصيني تنشأ بالقرب من بكين المنطقة من الصين، ويستخدم على نطاق واسع في المطبخ شرق آسيا ..\n\n=== المراجع ===\n{{المراجع}}\n\n[[(Brassica rapa subsp. pekinensis or Brassica rapa Pekinensis Group)]]\n\n[[تصنيف:عربية]]";
    const raw_catecholamine = "== اللغة الانجليزية ==\n{{wikipedia}}\n\n=== التأصيل ===\nمن {{لاحقة|en|catechol|-amine}}.\n\n=== النطق ===\n* {{أصد|/katəˈkəʊləmiːn/|/katəˈkɒləmiːn/}}\n\n=== اسم ===\n# مجموعة من المركبات المشتقة من الحمض الأميني تيروسين.\n== انظر أيضًا ==\n* [[dopamine]]\n\n[[تصنيف:C (إنجليزية)]]";
    const raw_dopamine = "== اللغة الإنجليزية ==\n[[ملف:Dopamine.svg|تصغير|البنية الكيميائية '''لل[[دُوبَامِين|دوبامين]]''']]\n{{wikipedia}}\n\n=== التأصيل ===\nمن {{لاحقة|en|dopa|-amine}}.\n\n=== اسم ===\n* هرمونٌ وناقلٌ عصبيٌ يُصنَّف كيميائياً ضمن الكاتيكولامينات والفينئيثيلامينات ويَلعب دورًا محوريًا في التَّحفيز والرغبة والإدمان.\n=== النطق ===\n* {{أصد|/ˈdəʊ.pə.miːn/}}\n* {{audio|LL-Q1860 (eng)-Back ache-dopamine.wav|lang=en|النطق الإنجليزي}}\n==== مرادفات ====\n* [[DA]]\n=== من نفس الجذر ===\n* [[-dopa]]\n* [[dopaminergic]]\n* [[dopaminoceptive]]\n* [[hydroxydopamine]]\n\n[[تصنيف:d (إنجليزية)]]\n[[تصنيف:أسماء إنجليزية]]\n[[تصنيف:نواقل عصبية (إنجليزية)]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ملفوف نابا", "== اللغة الإنجليزية ==\n=== Napa cabbage ===\n# [[اسْم|اسم]].\n#: نابا أو الملفوف نابا هو نوع من الملفوف الصيني\n[[تصنيف:عربية]]\n", raw_napa, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "catecholamine", "== اللغة الانجليزية ==\n=== اسم ===\n# مجموعة من المركبات المشتقة من الحمض الأميني تيروسين.\n== انظر أيضًا ==\n* [[dopamine]]\n", raw_catecholamine, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "dopamine", "== اللغة الإنجليزية ==\n=== اسم ===\n* هرمونٌ وناقلٌ عصبيٌ يُصنَّف كيميائياً ضمن الكاتيكولامينات والفينئيثيلامينات ويَلعب دورًا محوريًا في التَّحفيز والرغبة والإدمان.\n=== من نفس الجذر ===\n* [[dopaminergic]]\n", raw_dopamine, null);
    const neighbors = "== اللغة الإنجليزية ==\n# [[first]]\n== اللغة مجهولة ==\n# [[middle]]\n== اللغة الفرنسية ==\n# [[last]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "neighbors", neighbors, neighbors, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    const expected = [_]struct { title: []const u8, owner: []const u8, code: []const u8, target: []const u8, forbidden: []const u8 }{
        .{ .title = "ملفوف نابا", .owner = "الإنجليزية", .code = "en", .target = "اسْم", .forbidden = "" },
        .{ .title = "dopamine", .owner = "الإنجليزية", .code = "en", .target = "dopaminergic", .forbidden = "" },
        .{ .title = "catecholamine", .owner = "Unclassified", .code = "", .target = "dopamine", .forbidden = "" },
        .{ .title = "neighbors", .owner = "الإنجليزية", .code = "en", .target = "first", .forbidden = "middle" },
        .{ .title = "neighbors", .owner = "Unclassified", .code = "", .target = "middle", .forbidden = "first" },
        .{ .title = "neighbors", .owner = "الفرنسية", .code = "fr", .target = "last", .forbidden = "middle" },
    };
    for (expected) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row.owner));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(row.title)).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualStrings(row.code, decoded.entry.language_code);
        var found: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, row.target)) found += 1;
            if (row.forbidden.len != 0) try std.testing.expect(!std.mem.eql(u8, span.target, row.forbidden));
        };
        try std.testing.expectEqual(@as(usize, 1), found);
    }
}

test "captured mixed Arabic linked heading resolves exact trusted visible owner" {
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
        fn get(ctx: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(ctx, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "ar", "العربية", "عربية" }, .{ "fr", "الفرنسية", "فرنسية" }, .{ "en", "الإنجليزية", "إنجليزية" } }) |row|
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]) or std.mem.eql(u8, value, row[2])) return .{ .code = row[0], .heading = row[1] };
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .namespace_catalog = &namespaces, .trusted_fn = Local.resolve };
    const section = language_source.Section{ .heading = "ال[[عربية]]", .source = "== ال[[عربية]] ==\n# meaning\n[[تصنيف:فرنسية]]" };
    try std.testing.expectEqualStrings("ar", resolveSection(codes, section).?.code);
    try std.testing.expectEqualStrings("ar", boundaryLanguage(codes, section).?.code);
    const nested = language_source.Section{ .heading = "ال[[فرنسية]]", .source = "== ال[[فرنسية]] ==\n=== اسم إنجليزي ===\n# [[retained]]\n" };
    try std.testing.expectEqualStrings("en", language_source.arabicNounSubtree(nested, null).code.?);
    try std.testing.expect(!arabicLemmaDeclaration(codes, nested).present);
    try std.testing.expectEqualStrings("fr", resolveSection(codes, nested).?.code);
    try std.testing.expectEqualStrings("fr", boundaryLanguage(codes, nested).?.code);
    inline for (.{ "ال[[عربية|فرنسية]]", "ال[[مجهولة|عربية]]", "ال[[عربية]] extra", "ال[[عربية]] [[فرنسية]]", "ال[[عربية|عربية|extra]]", "ال{{عربية}}", "<nowiki>ال[[عربية]]</nowiki>", "ال[[عربية]]\n", "[[عربية]]" }) |heading|
        try std.testing.expect(resolveMixedArabicLinkedHeading(codes, heading) == null);
    var absent = codes;
    absent.namespace_catalog = null;
    try std.testing.expect(resolveMixedArabicLinkedHeading(absent, section.heading) == null);
    const raw = "== ال[[عربية]] ==\n\n=== تأصيل ===\nكلمة نادرة تعود للجذر هبرز. استخدمها العرب لوصف الأشياء النفيسة والخالصة التي لا تشوبها شائبة، وهي من الكلمات التي توحي بالفخامة والقيمة العالية.\n\n=== نطق ===\n* النطق: هِبْرِزيّ (بكسر الهاء وسكون الباء وكسر الراء).\n\n=== اسم ===\n'''الهِبْرِزيّ'''\n\n# وصف لكل ما هو خالص ونفيس، مثل الذهب النقي الذي لا غش فيه.\n# يُطلق أيضاً على الرجل الجميل الحسن الوجه والهيئة، أو الكريم الذي صفت أخلاقه.\n#: مثال: قدم التاجر لزبونه معدناً هبرزياً نادراً.\n\n==== مرادفات ====\n* نفيس\n* خالص\n* وسيم\n\n==== أضداد ====\n* زائف\n* قبيح\n* رخيص\n\n==== ترجمات ====\n* الإنجليزية: Pure gold\n* الفرنسية: Pur\n\n[[تصنيف:عربية]]";
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // This captured page has no templates: the exact full authored source
    // itself is the native rendering input, not a claimed Lua replay.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "هبرزي", raw, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, "العربية"));
    defer mapped.deinit();
    const blob = try blob_format.inspect(mapped.bytes);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("هبرزي")).?;
    const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
    try std.testing.expectEqualStrings("ar", decoded.entry.language_code);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var definitions: usize = 0;
    var heading_action: usize = 0;
    for (decoded.entry.sections) |part| for (part.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (span.kind == .link and std.mem.eql(u8, span.target, "عربية")) heading_action += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), definitions);
    try std.testing.expectEqual(@as(usize, 1), heading_action);
    inline for (.{ "وصف لكل ما هو خالص ونفيس", "يُطلق أيضاً على الرجل الجميل", "قدم التاجر لزبونه", "الهِبْرِزيّ", "وسيم", "زائف", "Pure gold", "Pur" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, text.items, expected) != null);
}

test "linked language headings ignore navigation fragments without borrowing labels" {
    const Local = struct {
        fn get(_: ?*const anyopaque, value: []const u8) ?[]const u8 {
            return if (resolve(null, value)) |language| language.code else null;
        }
        fn resolve(_: ?*const anyopaque, value: []const u8) ?ResolvedLanguage {
            inline for (.{ .{ "Limburgs", "li" }, .{ "English", "en" }, .{ "French", "fr" } }) |row| {
                if (std.mem.eql(u8, value, row[0]) or std.mem.eql(u8, value, row[1]))
                    return .{ .heading = row[0], .code = row[1] };
            }
            return null;
        }
    };
    const codes: LanguageCodes = .{ .get_fn = Local.get, .resolve_fn = Local.resolve, .strong_fn = Local.resolve };
    // Exact afwiktionary p16150/r227668 heading. The captured registry names Limburgs as li.
    const heading = "[[Limburgs#Afrikaans (af)|Limburgs (Standaard-) (li)]]";
    try std.testing.expectEqualStrings("li", resolveLinkedHeading(codes, heading).?.code);
    try std.testing.expectEqualStrings("en", resolveLinkedHeading(codes, "[[English#French|English]]").?.code);
    inline for (.{ "[[Limburgs#Afrikaans (af)|English]]", "[[Unknown#Limburgs|Limburgs]]", "[[#Limburgs|Limburgs]]", "[[#|English]]" }) |value|
        try std.testing.expect(resolveLinkedHeading(codes, value) == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // The authored heading and direct definition survive ordinary Writer -> DPR2.
    // This focused fixture does not claim native expansion of the full source page.
    const source = "==" ++ heading ++ "==\n# [[Sondag]]\n==English==\n# [[Sunday]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "zönjig", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    inline for (.{ .{ "Limburgs", "li", "Sondag", "Sunday" }, .{ "English", "en", "Sunday", "Sondag" } }) |row| {
        var mapped = try mmapPath(std.testing.io, try languageBlobPathAlloc(a, root, row[0]));
        defer mapped.deinit();
        const blob = try blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(row[1], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("zönjig")).?;
        const decoded = try blobs.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var kept = false;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (span.kind == .link and std.mem.eql(u8, span.target, row[2])) {
                try std.testing.expectEqualStrings("#", block.list_path);
                kept = true;
            }
            try std.testing.expect(!std.mem.eql(u8, span.target, row[3]));
        };
        try std.testing.expect(kept);
    }
}
