const std = @import("std");
const diagnostics = @import("build_diagnostics");
const namespace_registry = @import("namespace_registry");
const encoder = @import("encoder");
const xml_decode = @import("xml_decode");
const dump_source = @import("wikimedia_dump");
const language_registry = @import("language_registry.zig");
const bundle_expander = @import("bundle_expander.zig");
const expansion_deadline = @import("expansion_deadline.zig");
const reviewed_nonlexical = @import("reviewed_nonlexical.zig");
const max_worker_count: usize = 8;

const Options = struct {
    start_page: usize = 0,
    index_byte_offset: ?usize = null,
    limit_pages: ?usize = null,
    expander_root: []const u8 = "",
    workers: usize = 1,
    expansion_timeout_ms: ?u32 = null,
    now_unix: ?i64 = null,
    shard_pages: ?usize = null,
    audit_presentation_errors: bool = false,
    audit_expanded_bytes: ?usize = null,
    failure_receipt: ?[]const u8 = null,
    invocation_id: ?[]const u8 = null,
    reviewed_nonlexical: ?[]const u8 = null,
};

// Standalone CLI invocation state, read only by the ordered Writer consumer.
// Expansion worker threads do not emit or classify publication failures.
const FailureReceiptContext = struct {
    io: std.Io,
    a: std.mem.Allocator,
    path: []const u8,
    invocation_id: []const u8,
    invocation_args: []const []const u8,
};
var failure_receipt_context: ?FailureReceiptContext = null;

fn writePresentationFailure(context: FailureReceiptContext, job: ExpansionJob) !void {
    const bytes = try std.json.Stringify.valueAlloc(context.a, .{
        .schema = "wikidict.blob-build.failure.v1",
        .error_name = "UncompiledPresentation",
        .failure_class = "deterministic-presentation",
        .invocation_id = context.invocation_id,
        .invocation_args = context.invocation_args,
        .page = .{ .ordinal = job.ordinal, .namespace = job.ns.id, .title = job.title, .page_id = job.page_id, .revision_id = job.revision_id },
    }, .{});
    defer context.a.free(bytes);
    if (bytes.len > 64 * 1024) return error.FailureReceiptTooLarge;
    var file = try std.Io.Dir.cwd().createFile(context.io, context.path, .{ .exclusive = true });
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, bytes);
    try file.sync(context.io);
}

fn recordPresentationFailure(err: anyerror, job: ExpansionJob) anyerror {
    if (err != error.UncompiledPresentation) return err;
    const context = failure_receipt_context orelse return err;
    writePresentationFailure(context, job) catch |receipt_error| {
        // Receipt failure cannot replace the original Writer error. A missing or
        // partial receipt keeps the caller's existing transient retry policy.
        diagnostics.printLine("presentation failure receipt unavailable: error={s}\n", .{@errorName(receipt_error)});
    };
    return err;
}

const PageIndexIdentity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    size: u64,
    mtime_ns: i128,
};

fn fileIdentity(file: std.Io.File) !PageIndexIdentity {
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    if (linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat) != 0 or
        !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME)
    {
        return error.PageIndexStatFailed;
    }
    return .{
        .device_major = stat.dev_major,
        .device_minor = stat.dev_minor,
        .inode = stat.ino,
        .size = stat.size,
        .mtime_ns = @as(i128, stat.mtime.sec) * std.time.ns_per_s + stat.mtime.nsec,
    };
}

fn pathIdentity(io: std.Io, path: []const u8) !PageIndexIdentity {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return fileIdentity(file);
}

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    identity: PageIndexIdentity,

    fn deinit(self: *Mapped) void {
        if (self.bytes.len != 0) std.posix.munmap(self.bytes);
        self.bytes = &.{};
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const identity = try fileIdentity(file);
    const len = std.math.cast(usize, identity.size) orelse return error.FileTooBig;
    const bytes = if (len == 0)
        @as([]align(std.heap.page_size_min) const u8, &.{})
    else
        try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    return .{ .bytes = bytes, .identity = identity };
}

const PageCoverage = struct {
    version: u8 = 1,
    start_page: usize,
    requested_limit: ?usize,
    pages_seen: usize,
    index_byte_offset: usize,
    page_index_identity: PageIndexIdentity,
};

fn pageCoverage(options: Options, selected: usize, identity: PageIndexIdentity) !PageCoverage {
    if (options.limit_pages) |limit| {
        if (selected != limit) return error.ShortPageIndex;
    }
    return .{
        .start_page = options.start_page,
        .requested_limit = options.limit_pages,
        .pages_seen = selected,
        .index_byte_offset = options.index_byte_offset orelse 0,
        .page_index_identity = identity,
    };
}

fn writePageCoverage(
    io: std.Io,
    a: std.mem.Allocator,
    output_root: []const u8,
    coverage: PageCoverage,
) !void {
    const content = try std.json.Stringify.valueAlloc(a, coverage, .{});
    defer a.free(content);
    const path = try std.fs.path.join(a, &.{ output_root, "page-coverage.json" });
    defer a.free(path);
    const temporary = try std.fmt.allocPrint(a, "{s}.part-{d}", .{ path, std.os.linux.getpid() });
    defer a.free(temporary);
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = content });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

const PageIndexStart = struct {
    bytes: []const u8,
    ordinal: usize,
};

fn pageIndexStart(bytes: []const u8, options: Options) !PageIndexStart {
    const offset = options.index_byte_offset orelse 0;
    if (offset > bytes.len or
        (offset != 0 and bytes[offset - 1] != '\n') or
        (options.index_byte_offset != null and (options.start_page == 0) != (offset == 0)))
    {
        return error.InvalidIndexByteOffset;
    }
    if (offset != 0 and offset < bytes.len and (bytes[offset] == '\n' or bytes[offset] == '#')) {
        return error.InvalidIndexByteOffset;
    }
    return .{
        .bytes = bytes[offset..],
        .ordinal = if (options.index_byte_offset != null) options.start_page else 0,
    };
}

fn loadLanguageRegistry(io: std.Io, a: std.mem.Allocator, expander_root: []const u8, namespaces: *const namespace_registry.Registry) !language_registry.Registry {
    var out = language_registry.Registry.empty(a);
    errdefer out.deinit();

    const snapshot_path = try std.fs.path.join(a, &.{ expander_root, "language-registry.tsv" });
    defer a.free(snapshot_path);
    const snapshot = std.Io.Dir.cwd().readFileAlloc(io, snapshot_path, a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (snapshot) |bytes| {
        defer a.free(bytes);
        try out.addTsv(bytes);
    }

    const manifest_path = try std.fs.path.join(a, &.{ expander_root, "manifest.jsonl" });
    defer a.free(manifest_path);
    var manifest = try mmapPath(io, manifest_path);
    defer manifest.deinit();
    const modules = [_]struct { marker: []const u8, local_names: bool }{
        .{ .marker = "\"title\":\"Module:languages/canonical names\"", .local_names = false },
        .{ .marker = "\"title\":\"Module:sprǣcnaman\"", .local_names = true },
    };
    for (modules) |module| {
        const marker = std.mem.indexOf(u8, manifest.bytes, module.marker) orelse continue;
        const line_start = if (std.mem.lastIndexOfScalar(u8, manifest.bytes[0..marker], '\n')) |newline| newline + 1 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, manifest.bytes, marker, '\n') orelse manifest.bytes.len;
        const line = manifest.bytes[line_start..line_end];
        const page_prefix = "{\"page_id\":";
        if (!std.mem.startsWith(u8, line, page_prefix)) return error.InvalidModuleManifest;
        const comma = std.mem.indexOfScalarPos(u8, line, page_prefix.len, ',') orelse return error.InvalidModuleManifest;
        const page_id = std.fmt.parseInt(u64, line[page_prefix.len..comma], 10) catch return error.InvalidModuleManifest;
        const module_path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ expander_root, page_id });
        defer a.free(module_path);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, module_path, a, .limited(64 * 1024 * 1024));
        defer a.free(source);
        if (module.local_names) try out.addLocalNamesLua(source) else try out.addLua(source);
    }
    if (std.mem.eql(u8, out.content_code orelse "", "ar")) {
        try loadArabicLanguageModules(io, a, expander_root, namespaces, manifest.bytes, &out);
        try loadArabicLanguageTemplates(io, a, expander_root, namespaces, &out);
    }
    return out;
}

fn isArabicCanonicalLanguageModule(title: []const u8) bool {
    if (std.mem.eql(u8, title, "languages/data2")) return true;
    const prefix = "languages/data3/";
    return title.len == prefix.len + 1 and std.mem.startsWith(u8, title, prefix) and
        title[prefix.len] >= 'a' and title[prefix.len] <= 'z';
}

fn loadArabicLanguageModules(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, manifest: []const u8, registry: *language_registry.Registry) !void {
    var rows = std.mem.splitScalar(u8, manifest, '\n');
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(struct { page_id: u64, title: []const u8, sha256: []const u8 = "" }, a, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const title = namespaces.ofTitle(parsed.value.title);
        if (title.id != 828) continue;
        const kind: language_registry.LanguageDataKind = if (isArabicCanonicalLanguageModule(title.text))
            .canonical_assignments
        else if (std.mem.eql(u8, title.text, "لغات/بيانات"))
            .named_table
        else
            continue;
        const path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ root, parsed.value.page_id });
        defer a.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(2 * 1024 * 1024));
        defer a.free(source);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        if (!std.mem.eql(u8, parsed.value.sha256, &std.fmt.bytesToHex(digest, .lower))) return error.LanguageSourceIdentityMismatch;
        try registry.addLanguageDataLua(source, kind);
    }
}

fn literalArabicLanguageTemplate(source: []const u8) ?[]const u8 {
    // These dump-local, code-named templates have one literal language link.
    // Require the complete form; documentation, calls, redirects, link labels,
    // and additional content cannot accidentally become language evidence.
    const raw = std.mem.trim(u8, source, " \t\r\n");
    const prefix = "بال[[";
    const suffix = "]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>";
    if (!std.mem.startsWith(u8, raw, prefix) or !std.mem.endsWith(u8, raw, suffix) or raw.len <= prefix.len + suffix.len) return null;
    const label = raw[prefix.len .. raw.len - suffix.len];
    if (std.mem.indexOfAny(u8, label, "[]{}|<>#:\x00\r\n\t") != null or !std.mem.eql(u8, label, std.mem.trim(u8, label, " "))) return null;
    return label;
}

fn loadArabicLanguageTemplates(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, registry: *language_registry.Registry) !void {
    const path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(path);
    var index = mmapPath(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer index.deinit();
    var templates = (try dump_source.TemplateSource.open(io, a, root, index.bytes)) orelse return;
    defer templates.deinit();
    const kind = dump_source.pageIndexKind(index.bytes);
    var rows = std.mem.splitScalar(u8, index.bytes, '\n');
    var ordinal: u64 = 0;
    while (rows.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const row = try dump_source.parsePageIndexLine(kind, line);
        const this_ordinal = ordinal;
        ordinal += 1;
        if (row.ns != 10 or row.redirect != null or !row.has_source) continue;
        const title = namespaces.ofTitle(row.title);
        if (title.id != 10 or !registry.codes.contains(title.text)) continue;
        const raw = (try templates.lookup(this_ordinal, row.page_id, row.revision_id)) orelse return error.MissingLanguageTemplateSource;
        // Only the bounded literal forms above can be language-name evidence.
        if (raw.len > 4096) continue;
        const source = if (row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw) else null;
        defer if (source) |bytes| a.free(bytes);
        if (literalArabicLanguageTemplate(source orelse raw)) |label|
            try registry.addLocalAlias(label, title.text);
    }
}

fn languageCodes(registry: *const language_registry.Registry, namespaces: ?*const namespace_registry.Registry) encoder.blob_builder.LanguageCodes {
    return .{
        .namespace_catalog = namespaces,
        .ctx = registry,
        .get_fn = struct {
            fn get(raw: ?*const anyopaque, heading: []const u8) ?[]const u8 {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                return value.code(heading);
            }
        }.get,
        .resolve_fn = struct {
            fn resolve(raw: ?*const anyopaque, value_text: []const u8) ?encoder.blob_builder.ResolvedLanguage {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                const resolved = value.resolve(value_text) orelse return null;
                return .{ .code = resolved.code, .heading = resolved.heading };
            }
        }.resolve,
        .trusted_fn = struct {
            fn trusted(raw: ?*const anyopaque, value_text: []const u8) ?encoder.blob_builder.ResolvedLanguage {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                const resolved = value.resolveTrusted(value_text) orelse return null;
                return .{ .code = resolved.code, .heading = resolved.heading };
            }
        }.trusted,
        .strong_fn = struct {
            fn strong(raw: ?*const anyopaque, value_text: []const u8) ?encoder.blob_builder.ResolvedLanguage {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                const resolved = value.resolveStrong(value_text) orelse return null;
                return .{ .code = resolved.code, .heading = resolved.heading };
            }
        }.strong,
        .boundary_fn = struct {
            fn boundary(raw: ?*const anyopaque, heading: []const u8) bool {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return false));
                return value.isLanguageBoundary(heading);
            }
        }.boundary,
        .content_fn = struct {
            fn content(raw: ?*const anyopaque) ?encoder.blob_builder.ResolvedLanguage {
                const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return null));
                const resolved = value.content() orelse return null;
                return .{ .code = resolved.code, .heading = resolved.heading };
            }
        }.content,
        .link_trail = .{
            .ctx = registry,
            .end_fn = struct {
                fn end(raw: ?*const anyopaque, input: []const u8, start: usize) usize {
                    const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return start));
                    return value.linkTrailEnd(input, start);
                }
            }.end,
        },
    };
}

const AuditInputContext = struct {
    dump_path: []const u8,
    expander_root: []const u8,
    tool_path: []const u8 = "/proc/self/exe",
    workers: usize = 1,
    timeout_ms: u32 = expansion_deadline.default_ms,
    now_unix: i64 = 0,
    start_page: usize = 0,
    requested_limit: ?usize = null,
    index_byte_offset: ?usize = null,
    expanded_byte_cap: usize = 0,
};

const AuditFileStamp = struct {
    path: []const u8,
    identity: ?PageIndexIdentity,
    sha256: ?[]const u8,
};
const AuditPayload = struct {
    present: bool,
    bytes: usize = 0,
    sha256: ?[]const u8 = null,
    path: ?[]const u8 = null,
    retained_bytes: usize = 0,
    truncated: bool = false,
    unretained: bool = false,
};

fn auditHash(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn auditFileStamp(io: std.Io, a: std.mem.Allocator, path: []const u8) !AuditFileStamp {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = path, .identity = null, .sha256 = null },
        else => return err,
    };
    defer file.close(io);
    const before = try fileIdentity(file);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset = try std.math.add(u64, offset, n);
    }
    if (offset != before.size or !std.meta.eql(before, try fileIdentity(file))) return error.AuditInputsChanged;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .path = path, .identity = before, .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) };
}

// This is a diagnostic sink around the existing Writer, never a publication path.
// Its initial incomplete summary survives aborts, OOM and external termination.
const PresentationAudit = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    scratch_root: []const u8,
    context: AuditInputContext,
    failures_file: std.Io.File,
    inputs: std.ArrayList(AuditFileStamp) = .empty,
    selected: usize = 0,
    dispatched: usize = 0,
    consumed: usize = 0,
    skipped: usize = 0,
    direct_aliases: usize = 0,
    expansion_fallbacks: usize = 0,
    compile_attempts: usize = 0,
    succeeded: usize = 0,
    failed: usize = 0,
    failure_records: usize = 0,
    report_bytes: usize = 0,
    payload_bytes: usize = 0,
    finalized: bool = false,

    fn init(io: std.Io, a: std.mem.Allocator, root: []const u8, context: AuditInputContext) !PresentationAudit {
        if (context.expanded_byte_cap > 2 * 1024 * 1024) return error.Usage;
        const leaf = std.fs.path.basename(root);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.Usage;
        const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(root) orelse ".", a);
        defer a.free(parent);
        const absolute = try std.fs.path.join(a, &.{ parent, leaf });
        var owns_absolute = true;
        errdefer if (owns_absolute) a.free(absolute);
        const retained = try std.Io.Dir.cwd().realPathFileAlloc(io, context.expander_root, a);
        defer a.free(retained);
        if (std.mem.eql(u8, absolute, retained) or (std.mem.startsWith(u8, absolute, retained) and absolute.len > retained.len and absolute[retained.len] == std.fs.path.sep)) return error.AuditRootOverlapsInputs;
        try std.Io.Dir.cwd().createDir(io, absolute, .default_dir);
        const summary_path = try std.fs.path.join(a, &.{ absolute, "audit-summary.json" });
        defer a.free(summary_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = summary_path, .data = "{\"schema\":\"wikidict.presentation-audit.summary.v1\",\"diagnostic_only\":true,\"inventory_complete\":false,\"semantic_acceptance\":false,\"publication_created\":false,\"error_name\":\"started\"}\n" });
        const scratch = try std.fs.path.join(a, &.{ absolute, "compile-scratch" });
        var owns_scratch = true;
        errdefer if (owns_scratch) a.free(scratch);
        const failures_path = try std.fs.path.join(a, &.{ absolute, "failures.jsonl" });
        defer a.free(failures_path);
        var self: PresentationAudit = .{ .io = io, .allocator = a, .root = absolute, .scratch_root = scratch, .context = context, .failures_file = try std.Io.Dir.cwd().createFile(io, failures_path, .{ .exclusive = true }) };
        owns_absolute = false;
        owns_scratch = false;
        errdefer self.deinit();
        self.loadInputs() catch |err| {
            self.abort(err);
            return err;
        };
        return self;
    }

    fn loadInputs(self: *PresentationAudit) !void {
        const io = self.io;
        const a = self.allocator;
        const context = self.context;
        try self.addInput(context.dump_path);
        try self.addInput(context.tool_path);
        // Exact runtime/provider assets plus source files consulted by languageCodes.
        for ([_][]const u8{ "dict-bundle-expander", "page-index.tsv", dump_source.page_title_index_filename, "dump-streams.tsv", "namespace-registry.tsv", "namespace-siteinfo.raw.json", "site-statistics-format.json", "category-statistics-format.json", "language-registry.tsv", "behavior-switches.tsv", "image-options.tsv", "interwiki-map.tsv", "page-redirects.tsv", "transclusion-redirects.tsv", "commons-data.tsv", "category-stats.tsv", "interface-messages.tsv", "category-tree.tsv", "file-metadata.tsv", "wikibase-sitelinks.tsv", "wikibase-entity-text.tsv", "wikibase-page-links.tsv", "wikibase-entities.tsv", "wikibase-entity-terms.tsv", "date-numbering.tsv", "language-names.tsv", "language-fallbacks.tsv", "magic-words.tsv", "template-source.bin", "template-source.idx", "manifest.jsonl" }) |name| {
            const path = try std.fs.path.join(a, &.{ context.expander_root, name });
            defer a.free(path);
            try self.addInput(path);
        }
        const manifest_path = try std.fs.path.join(a, &.{ context.expander_root, "manifest.jsonl" });
        defer a.free(manifest_path);
        if (std.Io.Dir.cwd().openFile(io, manifest_path, .{})) |opened| {
            var manifest = opened;
            defer manifest.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var reader = manifest.reader(io, &buffer);
            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (line.len == 0) continue;
                const row = try std.json.parseFromSlice(struct { page_id: u64 }, a, line, .{ .ignore_unknown_fields = true });
                defer row.deinit();
                if (row.value.page_id == 0) return error.InvalidModuleManifest;
                const path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ context.expander_root, row.value.page_id });
                defer a.free(path);
                try self.addInput(path);
            }
        } else |err| if (err != error.FileNotFound) return err;
        try self.writeJson("audit-inputs.json", .{ .schema = "wikidict.presentation-audit.inputs.v1", .context = context, .files = self.inputs.items });
    }

    fn deinit(self: *PresentationAudit) void {
        self.failures_file.close(self.io);
        for (self.inputs.items) |input| {
            self.allocator.free(input.path);
            if (input.sha256) |value| self.allocator.free(value);
        }
        self.inputs.deinit(self.allocator);
        self.allocator.free(self.scratch_root);
        self.allocator.free(self.root);
    }

    fn addInput(self: *PresentationAudit, path: []const u8) !void {
        for (self.inputs.items) |input| if (std.mem.eql(u8, input.path, path)) return;
        if (self.inputs.items.len >= 8192 or path.len > 4096) return error.AuditInputLimitExceeded;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const stamp = try auditFileStamp(self.io, self.allocator, owned);
        errdefer if (stamp.sha256) |value| self.allocator.free(value);
        try self.inputs.append(self.allocator, stamp);
    }

    fn writeJson(self: *PresentationAudit, name: []const u8, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(bytes);
        const path = try std.fs.path.join(self.allocator, &.{ self.root, name });
        defer self.allocator.free(path);
        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.part", .{path});
        defer self.allocator.free(temporary);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temporary, .data = bytes });
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, self.io);
    }

    fn capture(self: *PresentationAudit, a: std.mem.Allocator, label: []const u8, value: ?[]const u8, cap: usize) !AuditPayload {
        const bytes = value orelse return .{ .present = false };
        const digest = try auditHash(a, bytes);
        if (bytes.len == 0) return .{ .present = true, .sha256 = digest };
        const n = @min(bytes.len, @min(cap, 64 * 1024 * 1024 - self.payload_bytes));
        if (n == 0 and bytes.len != 0) return .{ .present = true, .bytes = bytes.len, .sha256 = digest, .unretained = true };
        const path = try std.fmt.allocPrint(a, "{s}/failure-{d:0>8}-{s}", .{ self.root, self.failed, label });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes[0..n] });
        self.payload_bytes += n;
        return .{ .present = true, .bytes = bytes.len, .sha256 = digest, .path = path, .retained_bytes = n, .truncated = n != bytes.len };
    }

    fn recordSuccess(self: *PresentationAudit) void {
        self.compile_attempts += 1;
        self.succeeded += 1;
    }

    fn recordFailure(self: *PresentationAudit, job: ExpansionJob, expanded: bundle_expander.Expansion) !void {
        self.compile_attempts += 1;
        self.failed += 1;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var title_len = @min(job.title.len, 1024);
        while (title_len != 0 and !std.unicode.utf8ValidateSlice(job.title[0..title_len])) title_len -= 1;
        const alias_bytes = if (job.alias_record) |alias| try std.json.Stringify.valueAlloc(a, alias, .{}) else null;
        const row = .{
            .schema = "wikidict.presentation-audit.failure.v1",
            .error_name = "UncompiledPresentation",
            .ordinal = job.ordinal,
            .namespace = job.ns.id,
            .namespace_kind = @tagName(job.ns.kind),
            .page_id = job.page_id,
            .revision_id = job.revision_id,
            .title = job.title[0..title_len],
            .title_bytes = job.title.len,
            .title_truncated = title_len != job.title.len,
            .title_sha256 = try auditHash(a, job.title),
            .alias = job.alias_record != null,
            .unsupported_parser_function = expanded.unsupported_parser_function,
            .raw_source = try self.capture(a, "raw.wikitext", job.source, 256 * 1024),
            .expanded = try self.capture(a, "expanded.wikitext", expanded.source, self.context.expanded_byte_cap),
            .display_title = try self.capture(a, "display-title.wikitext", expanded.display_title, 256 * 1024),
            .poem_metadata = try self.capture(a, "poem.json", expanded.poem_metadata, 256 * 1024),
            .missing_dependency_metadata = try self.capture(a, "missing-dependency.json", expanded.missing_dependency_metadata, 256 * 1024),
            .index_row = try self.capture(a, "index-row.tsv", job.index_line, 256 * 1024),
            .alias_record = try self.capture(a, "alias.json", alias_bytes, 256 * 1024),
        };
        const line = try std.json.Stringify.valueAlloc(a, row, .{});
        if (line.len > 64 * 1024 or self.report_bytes + line.len + 1 > 256 * 1024 * 1024) return error.AuditReportLimitExceeded;
        var buffer: [4096]u8 = undefined;
        var output = self.failures_file.writerStreaming(self.io, &buffer);
        try output.interface.writeAll(line);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        self.report_bytes += line.len + 1;
        self.failure_records += 1;
    }

    fn writeSummary(self: *PresentationAudit, complete: bool, err: ?[]const u8) !void {
        try self.writeJson("audit-summary.json", .{ .schema = "wikidict.presentation-audit.summary.v1", .diagnostic_only = true, .inventory_complete = complete, .semantic_acceptance = false, .publication_created = false, .selected = self.selected, .dispatched = self.dispatched, .consumed = self.consumed, .skipped = self.skipped, .direct_aliases = self.direct_aliases, .expansion_fallbacks = self.expansion_fallbacks, .compile_attempts = self.compile_attempts, .succeeded = self.succeeded, .failed = self.failed, .failure_records = self.failure_records, .payload_bytes = self.payload_bytes, .error_name = err });
    }

    fn abort(self: *PresentationAudit, err: anyerror) void {
        if (!self.finalized) self.writeSummary(false, @errorName(err)) catch {};
    }

    fn finish(self: *PresentationAudit, eof: bool, drained: bool) !void {
        if (self.finalized or !eof or !drained or self.dispatched != self.consumed or self.selected != self.skipped + self.direct_aliases + self.dispatched or self.failed != self.failure_records) return error.IncompletePresentationAudit;
        for (self.inputs.items) |before| {
            const after = try auditFileStamp(self.io, self.allocator, before.path);
            defer if (after.sha256) |value| self.allocator.free(value);
            if (!std.meta.eql(before.identity, after.identity) or (before.sha256 == null) != (after.sha256 == null) or (before.sha256 != null and !std.mem.eql(u8, before.sha256.?, after.sha256.?))) return error.AuditInputsChanged;
        }
        try self.writeSummary(true, null);
        self.finalized = true;
    }
};

fn discardAuditPage(writer: *encoder.blob_builder.Writer, a: std.mem.Allocator) !void {
    // The Writer may have appended earlier owners before a later owner failed.
    // Keep only a single page's transient spool footprint; no audit calls finish.
    for (&writer.spools.language) |*spool| if (spool.offset != 0) {
        try spool.file.setLength(writer.io, 0);
        spool.offset = 0;
    };
    inline for (.{ "thesaurus", "citations", "reconstruction", "rhymes", "sign_gloss", "supplemental", "aliases" }) |name| {
        const spool = &@field(writer.spools, name);
        if (spool.offset != 0) {
            try spool.file.setLength(writer.io, 0);
            spool.offset = 0;
        }
    }
    if (writer.stats.fallback_pages != 0) {
        const path = try std.fs.path.join(a, &.{ writer.output_root, "fallback-pages.jsonl" });
        defer a.free(path);
        const replacement = try std.Io.Dir.cwd().createFile(writer.io, path, .{ .truncate = true });
        writer.fallback_file.close(writer.io);
        writer.fallback_file = replacement;
    }
    writer.stats = .{};
}

fn consumeExpandedPage(writer: *encoder.blob_builder.Writer, job: ExpansionJob, expanded: bundle_expander.Expansion, a: std.mem.Allocator, audit: ?*PresentationAudit) !bool {
    const extra_reasons: []const []const u8 = if (expanded.unsupported_parser_function) &.{"unsupported_parser_function"} else &.{};
    if (job.alias_record) |alias| {
        writer.addAliasExpandedWithPhases(a, alias, expanded.source, expanded.display_title, .{}, extra_reasons, expanded.poem_metadata, expanded.missing_dependency_metadata) catch |err| {
            if (audit) |value| if (err == error.UncompiledPresentation) {
                try value.recordFailure(job, expanded);
                try discardAuditPage(writer, a);
                return false;
            };
            return recordPresentationFailure(err, job);
        };
    } else {
        writer.addExpandedPageWithReasonsAndPhases(a, job.ns, job.title, expanded.source, job.source, expanded.display_title, extra_reasons, expanded.poem_metadata, expanded.missing_dependency_metadata) catch |err| {
            diagnostics.printLine("blob add failed title={s} ordinal={d} ns={d} source_bytes={d} expanded_bytes={d} error={s}\n", .{ job.title, job.ordinal, job.ns.id, job.source.len, expanded.source.len, @errorName(err) });
            if (audit) |value| if (err == error.UncompiledPresentation) {
                try value.recordFailure(job, expanded);
                try discardAuditPage(writer, a);
                return false;
            };
            return recordPresentationFailure(err, job);
        };
    }
    if (audit) |value| {
        value.recordSuccess();
        try discardAuditPage(writer, a);
    }
    return true;
}

const ExpansionJob = struct {
    ordinal: u64,
    ns: encoder.blob_builder.PageNamespace,
    title: []const u8,
    source: []const u8,
    alias_record: ?encoder.alias_codec.Record = null,
    page_id: u64 = 0,
    revision_id: u64 = 0,
    index_line: []const u8 = "",
};

fn expansionFallbackReasonAlloc(a: std.mem.Allocator, err: anyerror, failure: ?bundle_expander.Failure) !?[]const u8 {
    switch (err) {
        error.ExpansionFailed, error.RequestTooLarge => {},
        else => return null,
    }
    const precise = if (err == error.ExpansionFailed) failure else null;
    if (precise) |value| {
        if (bundle_expander.operationalFailure(value) != null) return null;
    }
    return if (precise) |value|
        try std.fmt.allocPrint(a, "expansion_error:{s}:{s}", .{ value.stage, value.error_name })
    else
        try std.fmt.allocPrint(a, "expansion_error:{s}", .{@errorName(err)});
}

const ExpansionSlot = struct {
    io: std.Io,
    completion: *std.Io.Event,
    arena: std.heap.ArenaAllocator,
    worker: bundle_expander.Worker,
    thread: ?std.Thread = null,
    job_event: std.Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    busy: bool = false,
    job: ExpansionJob = undefined,
    expansion: ?bundle_expander.Expansion = null,
    failure: ?anyerror = null,

    fn threadMain(self: *ExpansionSlot) void {
        defer self.worker.deinit();
        while (true) {
            self.job_event.waitUncancelable(self.io);
            self.job_event.reset();
            if (self.stop.load(.acquire)) return;
            self.failure = null;
            self.expansion = self.worker.expand(
                self.arena.allocator(),
                self.job.ordinal,
                self.job.title,
                self.job.source,
            ) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.done.store(true, .release);
            self.completion.set(self.io);
        }
    }

    fn dispatch(self: *ExpansionSlot, job: ExpansionJob) void {
        std.debug.assert(!self.busy);
        std.debug.assert(!self.done.load(.acquire));
        self.job = job;
        self.expansion = null;
        self.failure = null;
        self.busy = true;
        self.job_event.set(self.io);
    }

    fn consumeReady(self: *ExpansionSlot, writer: *encoder.blob_builder.Writer, audit: ?*PresentationAudit) !bool {
        if (!self.busy or !self.done.load(.acquire)) return false;
        if (audit) |value| value.consumed += 1;
        defer {
            self.done.store(false, .release);
            self.busy = false;
            self.worker.last_failure = null;
            _ = self.arena.reset(.retain_capacity);
        }
        if (self.failure) |err| {
            diagnostics.printLine(
                "page expansion failed title={s} ordinal={d} ns={d} source_bytes={d} error={s}\n",
                .{ self.job.title, self.job.ordinal, self.job.ns.id, self.job.source.len, @errorName(err) },
            );
            const fallback_reason = (try expansionFallbackReasonAlloc(self.arena.allocator(), err, self.worker.last_failure)) orelse return err;
            // Retain explicitly recoverable expansion failures with their exact
            // audit cause. Operational deadlines propagate through the classifier
            // above rather than masquerading as successfully encoded empty pages.
            if (self.job.alias_record) |alias| {
                try writer.addAliasExpanded(self.arena.allocator(), alias, "", null, .{ .expansion_error = true }, &.{fallback_reason});
                if (audit) |value| {
                    value.expansion_fallbacks += 1;
                    try discardAuditPage(writer, self.arena.allocator());
                }
                return true;
            }
            try writer.addExpansionFailure(self.arena.allocator(), self.job.ns, self.job.title, &.{fallback_reason});
            try writer.namespace_coverage.outcome(self.job.ns.id, .fallback);
            if (audit) |value| {
                value.expansion_fallbacks += 1;
                try discardAuditPage(writer, self.arena.allocator());
            }
            return true;
        }
        if (self.expansion) |expanded| {
            const fallback_before = writer.stats.fallback_pages;
            const compiled = try consumeExpandedPage(writer, self.job, expanded, self.arena.allocator(), audit);
            if (compiled and audit == null and self.job.alias_record == null)
                try writer.namespace_coverage.outcome(self.job.ns.id, if (writer.stats.fallback_pages != fallback_before) .fallback else .expanded);
        } else try writer.namespace_coverage.outcome(self.job.ns.id, .duplicate);
        return true;
    }
};

// The installed versioned site-info snapshot is already pinned by build inputs.
// No English title heuristic and no empty-page heuristic is used here.
const SiteMainPage = struct { title: []const u8, digest: [32]u8 };
fn siteString(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidSiteMainPage;
    const item = value.object.get(name) orelse return error.InvalidSiteMainPage;
    if (item != .string) return error.InvalidSiteMainPage;
    return item.string;
}
fn parseSiteMainPage(a: std.mem.Allocator, bytes: []const u8, namespaces: *const namespace_registry.Registry) !SiteMainPage {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, try siteString(value, "schema"), "wikidict.site-info.v2") or
        !std.mem.eql(u8, try siteString(value, "wiki"), namespaces.wiki) or
        !std.mem.eql(u8, try siteString(value, "date"), namespaces.dump_date) or
        !std.mem.eql(u8, try siteString(value, "content_language"), namespaces.content_language)) return error.InvalidSiteMainPage;
    const expected = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    if (!std.mem.eql(u8, try siteString(value, "namespace_registry_sha256"), &expected)) return error.InvalidSiteMainPage;
    const query = value.object.get("query") orelse return error.InvalidSiteMainPage;
    if (query != .object) return error.InvalidSiteMainPage;
    const general = query.object.get("general") orelse return error.InvalidSiteMainPage;
    if (!std.mem.eql(u8, try siteString(general, "wikiid"), namespaces.wiki)) return error.InvalidSiteMainPage;
    const raw = try siteString(general, "mainpage");
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "\t\r\n#") != null) return error.InvalidSiteMainPage;
    const title = try namespaces.normalizeTitle(a, raw, 0, .any);
    errdefer a.free(title);
    // Direct project-namespace inputs retain ordinary compile-only routing.
    // Their validated terminal identity can still identify main-namespace aliases.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .title = title, .digest = digest };
}
fn loadSiteMainPage(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry) !?SiteMainPage {
    const path = try std.fs.path.join(a, &.{ root, "namespace-siteinfo.raw.json" });
    defer a.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null, // Legacy/no capture remains strict.
        else => return err,
    };
    defer a.free(bytes);
    const format = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer format.deinit();
    if (format.value != .object) return error.InvalidSiteMainPage;
    const schema = format.value.object.get("schema") orelse return null;
    if (schema != .string or !std.mem.eql(u8, schema.string, "wikidict.site-info.v2")) return null;
    return try parseSiteMainPage(a, bytes, namespaces);
}

const ExpansionPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    completion: *std.Io.Event,
    slots: []ExpansionSlot,
    page_index_bytes: []const u8 = "",
    page_title_index: ?dump_source.PageTitleIndex = null,
    page_redirects: ?*const encoder.page_redirects.Snapshot = null,
    site_mainpage: ?SiteMainPage = null,
    reviewed_nonlexical: ?*reviewed_nonlexical.Review = null,
    reviewed_dump_identity: ?PageIndexIdentity = null,
    audit: ?*PresentationAudit = null,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
        executable: []const u8,
        dump: []const u8,
        count: usize,
        now_unix: ?i64,
        timeout_ms: u32,
    ) !ExpansionPool {
        const completion = try allocator.create(std.Io.Event);
        errdefer allocator.destroy(completion);
        completion.* = .unset;
        const slots = try allocator.alloc(ExpansionSlot, count);
        errdefer allocator.free(slots);
        const pinned_now = now_unix orelse std.Io.Clock.real.now(io).toSeconds();
        for (slots) |*slot| {
            var worker = bundle_expander.Worker.init(io, root, executable, dump);
            worker.now_unix = pinned_now;
            worker.timeout_ms = timeout_ms;
            slot.* = .{
                .io = io,
                .completion = completion,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .worker = worker,
            };
        }
        var spawned: usize = 0;
        errdefer {
            for (slots[0..spawned]) |*slot| {
                slot.stop.store(true, .release);
                slot.job_event.set(io);
            }
            for (slots[0..spawned]) |*slot| slot.thread.?.join();
            for (slots) |*slot| slot.arena.deinit();
        }
        for (slots) |*slot| {
            slot.thread = try std.Thread.spawn(.{}, ExpansionSlot.threadMain, .{slot});
            spawned += 1;
        }
        return .{ .io = io, .allocator = allocator, .completion = completion, .slots = slots };
    }

    fn deinit(self: *ExpansionPool) void {
        for (self.slots) |*slot| {
            slot.stop.store(true, .release);
            slot.job_event.set(self.io);
        }
        for (self.slots) |*slot| if (slot.thread) |thread| thread.join();
        for (self.slots) |*slot| slot.arena.deinit();
        self.allocator.free(self.slots);
        self.allocator.destroy(self.completion);
        self.* = undefined;
    }

    fn consumeReady(self: *ExpansionPool, writer: *encoder.blob_builder.Writer) !usize {
        var count: usize = 0;
        for (self.slots) |*slot| if (try slot.consumeReady(writer, self.audit)) {
            count += 1;
        };
        return count;
    }

    fn acquire(self: *ExpansionPool, writer: *encoder.blob_builder.Writer) !*ExpansionSlot {
        while (true) {
            for (self.slots) |*slot| if (!slot.busy) return slot;
            if (try self.consumeReady(writer) != 0) continue;
            self.completion.waitUncancelable(self.io);
            self.completion.reset();
        }
    }

    fn drain(self: *ExpansionPool, writer: *encoder.blob_builder.Writer) !void {
        while (true) {
            var busy = false;
            for (self.slots) |*slot| busy = busy or slot.busy;
            if (!busy) return;
            if (try self.consumeReady(writer) != 0) continue;
            self.completion.waitUncancelable(self.io);
            self.completion.reset();
        }
    }
};

fn parseOptions(args: []const []const u8) !Options {
    var out: Options = .{};
    var index: usize = 3;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--reviewed-nonlexical")) {
            index += 1;
            if (index >= args.len or out.reviewed_nonlexical != null or args[index].len == 0) return error.Usage;
            out.reviewed_nonlexical = args[index];
        } else if (std.mem.eql(u8, arg, "--failure-receipt")) {
            index += 1;
            if (index >= args.len or out.failure_receipt != null or args[index].len == 0) return error.Usage;
            out.failure_receipt = args[index];
        } else if (std.mem.eql(u8, arg, "--invocation-id")) {
            index += 1;
            if (index >= args.len or out.invocation_id != null or args[index].len != 32) return error.Usage;
            for (args[index]) |c| if (!std.ascii.isHex(c)) return error.Usage;
            out.invocation_id = args[index];
        } else if (std.mem.eql(u8, arg, "--audit-presentation-errors")) {
            if (out.audit_presentation_errors) return error.Usage;
            out.audit_presentation_errors = true;
        } else if (std.mem.eql(u8, arg, "--audit-expanded-bytes")) {
            index += 1;
            if (index >= args.len or out.audit_expanded_bytes != null) return error.Usage;
            out.audit_expanded_bytes = try std.fmt.parseInt(usize, args[index], 10);
            if (out.audit_expanded_bytes.? > 2 * 1024 * 1024) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--start-page")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            out.start_page = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--index-byte-offset")) {
            index += 1;
            if (index >= args.len or out.index_byte_offset != null) return error.Usage;
            out.index_byte_offset = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--limit-pages")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            out.limit_pages = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--shard-pages")) {
            index += 1;
            if (index >= args.len or out.shard_pages != null) return error.Usage;
            out.shard_pages = try std.fmt.parseInt(usize, args[index], 10);
            if (out.shard_pages.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            out.workers = try std.fmt.parseInt(usize, args[index], 10);
            if (out.workers == 0 or out.workers > max_worker_count) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--expansion-timeout-ms")) {
            index += 1;
            if (index >= args.len or out.expansion_timeout_ms != null) return error.Usage;
            out.expansion_timeout_ms = try expansion_deadline.parse(args[index]);
        } else if (std.mem.eql(u8, arg, "--now-unix")) {
            index += 1;
            if (index >= args.len or out.now_unix != null) return error.Usage;
            out.now_unix = try std.fmt.parseInt(i64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--expander-root")) {
            index += 1;
            if (index >= args.len or out.expander_root.len != 0) return error.Usage;
            out.expander_root = args[index];
        } else if (out.limit_pages == null) {
            out.limit_pages = std.fmt.parseInt(usize, arg, 10) catch return error.Usage;
        } else return error.Usage;
        index += 1;
    }
    if ((out.failure_receipt == null) != (out.invocation_id == null)) return error.Usage;
    if (out.audit_presentation_errors and out.failure_receipt != null) return error.Usage;
    if (out.expander_root.len == 0 or (out.audit_expanded_bytes != null and !out.audit_presentation_errors) or (out.audit_presentation_errors and (out.shard_pages != null or out.start_page != 0 or out.index_byte_offset != null or out.limit_pages != null))) return error.Usage;
    if (out.shard_pages) |shard_pages| {
        if (out.index_byte_offset == null or out.limit_pages == null or out.limit_pages.? == 0 or
            out.start_page % shard_pages != 0) return error.Usage;
    }
    return out;
}

test "presentation failure receipt round trips exact invocation and page identity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/failure.json", .{tmp.sub_path});
    defer a.free(path);
    const invocation_args = [_][]const u8{ "dump.xml.zst", "out", "--expander-root", "bundle", "--now-unix", "1791731560", "--failure-receipt", path, "--invocation-id", "0123456789abcdef0123456789abcdef" };
    const context: FailureReceiptContext = .{ .io = io, .a = a, .path = path, .invocation_id = "0123456789abcdef0123456789abcdef", .invocation_args = &invocation_args };
    const job: ExpansionJob = .{ .ordinal = 14002, .ns = .{ .id = 114, .kind = .citations }, .title = "Citations:quoted \"fixture\"", .source = "not serialized", .page_id = 7, .revision_id = 9 };
    try writePresentationFailure(context, job);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
    defer a.free(bytes);
    const Receipt = struct {
        schema: []const u8, error_name: []const u8, failure_class: []const u8,
        invocation_id: []const u8, invocation_args: []const []const u8,
        page: struct { ordinal: u64, namespace: u32, title: []const u8, page_id: u64, revision_id: u64 },
    };
    const parsed = try std.json.parseFromSlice(Receipt, a, bytes, .{});
    defer parsed.deinit();
    const row = parsed.value;
    try std.testing.expectEqualStrings("wikidict.blob-build.failure.v1", row.schema);
    try std.testing.expectEqualStrings("UncompiledPresentation", row.error_name);
    try std.testing.expectEqualStrings("deterministic-presentation", row.failure_class);
    try std.testing.expectEqualStrings(context.invocation_id, row.invocation_id);
    try std.testing.expectEqual(invocation_args.len, row.invocation_args.len);
    for (invocation_args, row.invocation_args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(job.ordinal, row.page.ordinal);
    try std.testing.expectEqual(job.ns.id, row.page.namespace);
    try std.testing.expectEqualStrings(job.title, row.page.title);
    try std.testing.expectEqual(job.page_id, row.page.page_id);
    try std.testing.expectEqual(job.revision_id, row.page.revision_id);
    try std.testing.expect(std.mem.indexOf(u8, bytes, job.source) == null);
    try std.testing.expectError(error.PathAlreadyExists, writePresentationFailure(context, job));
    failure_receipt_context = context;
    defer failure_receipt_context = null;
    // Exercise the production error-return helper with an existing receipt:
    // failure to create an exclusive file must retain the Writer's error.
    try std.testing.expect(recordPresentationFailure(error.UncompiledPresentation, job) == error.UncompiledPresentation);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, bytes, after);
}

test "blob shard options preserve explicit byte offset and page limit" {
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dict-blob-build", "dump", "out", "--expander-root", "bundle", "--failure-receipt", "receipt.json",
    }));
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dict-blob-build", "dump", "out", "--expander-root", "bundle", "--audit-presentation-errors",
        "--failure-receipt", "receipt.json", "--invocation-id", "0123456789abcdef0123456789abcdef",
    }));
    const options = try parseOptions(&.{
        "dict-blob-build", "dump.bz2", "out",                 "--expander-root", "bundle",
        "--start-page",    "100",      "--index-byte-offset", "2048",            "--limit-pages",
        "100",
    });
    try std.testing.expectEqual(@as(usize, 100), options.start_page);
    try std.testing.expectEqual(@as(?usize, 2048), options.index_byte_offset);
    try std.testing.expectEqual(@as(?usize, 100), options.limit_pages);
    const continuous = try parseOptions(&.{
        "dict-blob-build", "dump.zst",      "shards",              "--expander-root", "bundle",
        "--start-page",    "100",           "--index-byte-offset", "2048",            "--limit-pages",
        "7",               "--shard-pages", "100",
    });
    try std.testing.expectEqual(@as(?usize, 100), continuous.shard_pages);
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dict-blob-build", "dump.zst",      "shards",              "--expander-root", "bundle",
        "--start-page",    "101",           "--index-byte-offset", "2048",            "--limit-pages",
        "7",               "--shard-pages", "100",
    }));
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dict-blob-build",     "dump.bz2", "out",                 "--expander-root", "bundle",
        "--index-byte-offset", "0",        "--index-byte-offset", "1",
    }));
}

test "blob shard offset begins exactly at a data row" {
    const index = "# meta\nfirst\nsecond\n";
    const first = try pageIndexStart(index, .{ .start_page = 0, .index_byte_offset = 0 });
    try std.testing.expectEqualStrings(index, first.bytes);
    try std.testing.expectEqual(@as(usize, 0), first.ordinal);
    const second = try pageIndexStart(index, .{ .start_page = 1, .index_byte_offset = 13 });
    try std.testing.expectEqualStrings("second\n", second.bytes);
    try std.testing.expectEqual(@as(usize, 1), second.ordinal);
    const legacy = try pageIndexStart(index, .{ .start_page = 1 });
    try std.testing.expectEqualStrings(index, legacy.bytes);
    try std.testing.expectEqual(@as(usize, 0), legacy.ordinal);

    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart(index, .{ .start_page = 1, .index_byte_offset = 12 }));
    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart(index, .{ .start_page = 0, .index_byte_offset = 13 }));
    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart(index, .{ .start_page = 1, .index_byte_offset = 0 }));
    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart(index, .{ .start_page = 1, .index_byte_offset = index.len + 1 }));
    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart("# meta\n# note\nfirst\n", .{ .start_page = 1, .index_byte_offset = 7 }));
    try std.testing.expectError(error.InvalidIndexByteOffset, pageIndexStart("# meta\n\nfirst\n", .{ .start_page = 1, .index_byte_offset = 7 }));
}

test "page coverage rejects short explicit shards and records actual selection" {
    const identity: PageIndexIdentity = .{
        .device_major = 1,
        .device_minor = 2,
        .inode = 3,
        .size = 4,
        .mtime_ns = 5,
    };
    try std.testing.expectError(error.ShortPageIndex, pageCoverage(.{
        .start_page = 100,
        .index_byte_offset = 13,
        .limit_pages = 2,
    }, 1, identity));
    const coverage = try pageCoverage(.{
        .start_page = 100,
        .index_byte_offset = 13,
        .limit_pages = 2,
    }, 2, identity);
    try std.testing.expectEqual(@as(u8, 1), coverage.version);
    try std.testing.expectEqual(@as(usize, 100), coverage.start_page);
    try std.testing.expectEqual(@as(?usize, 2), coverage.requested_limit);
    try std.testing.expectEqual(@as(usize, 2), coverage.pages_seen);
    try std.testing.expectEqual(@as(usize, 13), coverage.index_byte_offset);
    try std.testing.expect(std.meta.eql(identity, coverage.page_index_identity));
    const full = try pageCoverage(.{}, 3, identity);
    try std.testing.expectEqual(@as(?usize, null), full.requested_limit);
    try std.testing.expectEqual(@as(usize, 3), full.pages_seen);
}

fn compiledKind(spec: namespace_registry.Spec) ?encoder.blob_format.BlobKind {
    return switch (spec.role) {
        .main => .language,
        .compile_only => null,
        .supplemental => .supplemental,
        .thesaurus => .thesaurus,
        .citations => .citations,
        .reconstruction => .reconstruction,
        .rhymes => .rhymes,
        .sign_gloss => .sign_gloss,
    };
}
fn compiledKey(title: []const u8, kind: encoder.blob_format.BlobKind) []const u8 {
    if (kind == .language or kind == .supplemental) return title;
    const colon = std.mem.indexOfScalar(u8, title, ':') orelse return title;
    return title[colon + 1 ..];
}
fn aliasTargetPage(pool: *const ExpansionPool, title: []const u8) !?dump_source.IndexedPage {
    const index = pool.page_title_index orelse return error.MissingPageTitleIndex;
    const ref = (try index.lookup(pool.page_index_bytes, title)) orelse return null;
    const start = dump_source.pageRowRefOffset(ref);
    const end = std.mem.indexOfScalarPos(u8, pool.page_index_bytes, start, '\n') orelse pool.page_index_bytes.len;
    return try dump_source.parsePageIndexLine(index.kind, pool.page_index_bytes[start..end]);
}

fn siteTerminalPage(pool: *const ExpansionPool, a: std.mem.Allocator, initial: dump_source.IndexedPage) !?dump_source.IndexedPage {
    var page = initial;
    var seen: [32]u64 = undefined;
    var count: usize = 0;
    while (count < seen.len) : (count += 1) {
        if (!page.has_source) return null;
        for (seen[0..count]) |id| if (id == page.page_id) return null;
        seen[count] = page.page_id;
        const xml_target = page.redirect orelse return page;
        const redirects = pool.page_redirects orelse return error.PageRedirectSnapshotMissing;
        const target = try redirects.lookup(a, page.page_id, xml_target);
        if (target.namespace < 0 or target.interwiki.len != 0) return null;
        const next = (try aliasTargetPage(pool, target.title)) orelse return null;
        if (next.ns != @as(u32, @intCast(target.namespace))) return null;
        page = next;
    }
    return null; // Cyclic/overlong chains keep ordinary strict treatment.
}
fn isSiteMetadata(pool: *const ExpansionPool, a: std.mem.Allocator, initial: dump_source.IndexedPage) !bool {
    // Only main-namespace candidates are reclassified. Project/homepage source
    // rows retain their registry-defined compile-only routing.
    if (initial.ns != 0) return false;
    const site = pool.site_mainpage orelse return false;
    const declared = (try aliasTargetPage(pool, site.title)) orelse return false;
    // The captured official main page may itself redirect to a localized notice.
    const canonical = (try siteTerminalPage(pool, a, declared)) orelse return false;
    const resolved = (try siteTerminalPage(pool, a, initial)) orelse return false;
    return resolved.ns == canonical.ns and resolved.page_id == canonical.page_id and resolved.revision_id == canonical.revision_id and
        std.mem.eql(u8, resolved.title, canonical.title);
}

// Hash the already-open source handle, using bounded memory and checking its
// identity on both sides. The manifest binds these actual native input bytes.
fn reviewedDumpDigest(io: std.Io, file: std.Io.File) !struct { digest: [32]u8, identity: PageIndexIdentity } {
    const before = try fileIdentity(file);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset = try std.math.add(u64, offset, n);
    }
    if (offset != before.size or !std.meta.eql(before, try fileIdentity(file))) return error.ReviewedNonlexicalInputsChanged;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .digest = digest, .identity = before };
}
fn checkReviewedDump(pool: *const ExpansionPool, dump: *const dump_source.SourceReader) !void {
    if (pool.reviewed_dump_identity) |expected| if (!std.meta.eql(expected, try fileIdentity(dump.file))) return error.ReviewedNonlexicalInputsChanged;
}
fn loadReviewedNonlexical(io: std.Io, a: std.mem.Allocator, path: []const u8, namespaces: *const namespace_registry.Registry, page_index: []const u8, kind: dump_source.PageIndexKind, dump_digest: [32]u8) !reviewed_nonlexical.Review {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
    defer a.free(bytes);
    var review = try reviewed_nonlexical.Review.init(a, bytes, namespaces.wiki, namespaces.dump_date, namespaces.source_sha256, dump_digest, page_index);
    errdefer review.deinit();
    var lines = std.mem.splitScalar(u8, page_index, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try review.preflightPage(try dump_source.parsePageIndexLine(kind, line));
    }
    try review.finishPreflight();
    return review;
}

fn dispatchIndexedPage(
    pool: *ExpansionPool,
    writer: *encoder.blob_builder.Writer,
    dump: *dump_source.SourceReader,
    kind: dump_source.PageIndexKind,
    namespaces: *const namespace_registry.Registry,
    line: []const u8,
    ordinal: usize,
) !void {
    const page = try dump_source.parsePageIndexLine(kind, line);
    const spec = namespaces.byId(std.math.cast(i32, page.ns) orelse return error.InvalidNamespace) orelse return error.InvalidNamespace;
    const role = compiledKind(spec);
    try writer.namespace_coverage.input(writer.allocator, page.ns, spec.name, role, page.has_source);
    // Explicit source review precedes ordinary aliases and language ownership.
    // Unlisted pages retain the existing dispatch path without a title heuristic.
    if (pool.reviewed_nonlexical) |review| {
        if (try review.matches(page)) {
            var review_arena = std.heap.ArenaAllocator.init(writer.allocator);
            defer review_arena.deinit();
            const ra = review_arena.allocator();
            try checkReviewedDump(pool, dump);
            const raw_source = try dump.readAlloc(ra, page.source);
            const source = if (page.source_needs_decode) try xml_decode.decodeSinglePassAlloc(ra, raw_source) else raw_source;
            if (!try review.consume(page, source)) return error.ReviewedNonlexicalPageMismatch;
            try checkReviewedDump(pool, dump);
            try writer.namespace_coverage.reviewedNonlexical(writer.allocator, page.ns, review.sha256, page.page_id);
            writer.stats.main_pages += 1;
            if (pool.audit) |audit| audit.skipped += 1;
            return;
        }
    }
    if (!page.has_source or role == null) {
        if (pool.audit) |audit| audit.skipped += 1;
        return;
    }
    if (pool.site_mainpage != null and page.ns == 0) {
        var metadata_arena = std.heap.ArenaAllocator.init(writer.allocator);
        defer metadata_arena.deinit();
        if (try isSiteMetadata(pool, metadata_arena.allocator(), page)) {
            try writer.namespace_coverage.siteMetadata(page.ns, pool.site_mainpage.?.digest);
            writer.stats.main_pages += 1;
            if (pool.audit) |audit| audit.skipped += 1;
            return;
        }
    }
    if (page.redirect) |xml_target| {
        const index = pool.page_title_index orelse return error.MissingPageTitleIndex;
        const own_ref = (try index.lookup(pool.page_index_bytes, page.title)) orelse return error.InvalidPageTitleIndex;
        if (dump_source.pageRowRefOrdinal(own_ref) != ordinal) {
            try writer.namespace_coverage.outcome(page.ns, .duplicate);
            if (pool.audit) |audit| audit.skipped += 1;
            return;
        }
        var arena = std.heap.ArenaAllocator.init(writer.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const raw_source = try dump.readAlloc(a, page.source);
        const source = if (page.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw_source) else raw_source;
        const redirects = pool.page_redirects orelse return error.PageRedirectSnapshotMissing;
        const target = redirects.lookup(a, page.page_id, xml_target) catch |err| {
            diagnostics.printLine("redirect SQL mismatch: page_id={d} title={s} xml_target={s} error={s}\n", .{ page.page_id, page.title, xml_target, @errorName(err) });
            return err;
        };
        const tail = try encoder.redirect_source.tail(source);
        const target_page = if (target.interwiki.len == 0) try aliasTargetPage(pool, target.title) else null;
        if (target_page) |row| if (target.namespace < 0 or row.ns != @as(u32, @intCast(target.namespace))) return error.PageRedirectTargetMismatch;
        const target_kind = if (target_page) |row| if (row.has_source) compiledKind(namespaces.byId(std.math.cast(i32, row.ns) orelse return error.InvalidNamespace) orelse return error.InvalidNamespace) else null else null;
        const alias: encoder.alias_codec.Record = .{
            .source_namespace = page.ns,
            .source_kind = role.?,
            .source_title = page.title,
            .source_key = compiledKey(page.title, role.?),
            .xml_target = xml_target,
            .target_title = target.title,
            .target_namespace = if (target.interwiki.len == 0 and target.namespace >= 0) @intCast(target.namespace) else null,
            .target_kind = target_kind,
            .target_key = if (target_kind) |k| compiledKey(target.title, k) else "",
            .fragment = target.fragment,
            .presentation = "",
        };
        if (tail.len == 0) {
            try writer.addAlias(a, alias);
            if (pool.audit) |audit| {
                audit.direct_aliases += 1;
                try discardAuditPage(writer, a);
            }
        } else {
            const slot = try pool.acquire(writer);
            const retained = slot.arena.allocator();
            var owned = alias;
            owned.target_title = try retained.dupe(u8, alias.target_title);
            owned.target_key = try retained.dupe(u8, alias.target_key);
            owned.fragment = try retained.dupe(u8, alias.fragment);
            if (pool.audit) |audit| audit.dispatched += 1;
            slot.dispatch(.{ .ordinal = @intCast(ordinal), .ns = .{ .id = page.ns, .kind = role.? }, .title = page.title, .source = try retained.dupe(u8, tail), .alias_record = owned, .page_id = page.page_id, .revision_id = page.revision_id, .index_line = line });
        }
        return;
    }
    const slot = try pool.acquire(writer);
    const page_allocator = slot.arena.allocator();
    const raw_source = try dump.readAlloc(page_allocator, page.source);
    const source = if (page.source_needs_decode)
        try xml_decode.decodeSinglePassAlloc(page_allocator, raw_source)
    else
        raw_source;
    if (pool.audit) |audit| audit.dispatched += 1;
    slot.dispatch(.{
        .page_id = page.page_id,
        .revision_id = page.revision_id,
        .index_line = line,
        .ordinal = @intCast(ordinal),
        .ns = .{ .id = page.ns, .kind = role.? },
        .title = page.title,
        .source = source,
    });
}

const PendingShard = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    temporary: []const u8,
    final: []const u8,
    writer: ?encoder.blob_builder.Writer,
    start: usize,
    requested: usize,
    offset: usize,
    selected: usize = 0,
    published: bool = false,

    fn init(io: std.Io, a: std.mem.Allocator, root: []const u8, start: usize, requested: usize, offset: usize, codes: encoder.blob_builder.LanguageCodes) !PendingShard {
        const final = try std.fmt.allocPrint(a, "{s}/{d:0>8}", .{ root, start });
        errdefer a.free(final);
        // The controller holds the edition lock. Refuse an existing final path
        // instead of letting rename replace an unverified or verified shard.
        if (std.Io.Dir.cwd().access(io, final, .{})) |_| return error.ShardAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const temporary = try std.fmt.allocPrint(a, "{s}/.{d:0>8}.part-{d}", .{ root, start, std.os.linux.getpid() });
        errdefer a.free(temporary);
        try std.Io.Dir.cwd().createDir(io, temporary, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
        var writer = try encoder.blob_builder.Writer.init(io, a, temporary);
        writer.language_codes = codes;
        return .{ .io = io, .allocator = a, .temporary = temporary, .final = final, .writer = writer, .start = start, .requested = requested, .offset = offset };
    }

    fn deinit(self: *PendingShard) void {
        if (self.writer) |*writer| writer.deinit();
        if (!self.published) std.Io.Dir.cwd().deleteTree(self.io, self.temporary) catch {};
        self.allocator.free(self.temporary);
        self.allocator.free(self.final);
        self.* = undefined;
    }

    fn publish(self: *PendingShard, pool: *ExpansionPool, dump: *const dump_source.SourceReader, codes: encoder.blob_builder.LanguageCodes, index_path: []const u8, identity: PageIndexIdentity) !void {
        if (self.selected != self.requested) return error.ShortPageIndex;
        const writer = if (self.writer) |*value| value else return error.WriterFinished;
        try pool.drain(writer);
        try checkReviewedDump(pool, dump);
        const stats = try writer.finish(codes);
        if (stats.pages_seen != self.selected) return error.PageCoverageMismatch;
        try writePageCoverage(self.io, self.allocator, self.temporary, .{
            .start_page = self.start,
            .requested_limit = self.requested,
            .pages_seen = self.selected,
            .index_byte_offset = self.offset,
            .page_index_identity = identity,
        });
        if (!std.meta.eql(identity, try pathIdentity(self.io, index_path))) return error.PageIndexChanged;
        writer.deinit();
        self.writer = null;
        if (std.Io.Dir.cwd().access(self.io, self.final, .{})) |_| return error.ShardAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.Dir.cwd().rename(self.temporary, std.Io.Dir.cwd(), self.final, self.io);
        self.published = true;
        diagnostics.printLine("continuous shard published start={d} pages={d} main_pages={d} language_records={d} fallback_pages={d}\n", .{
            self.start, stats.pages_seen, stats.main_pages, stats.language_records, stats.fallback_pages,
        });
    }
};

fn runContinuous(
    io: std.Io,
    a: std.mem.Allocator,
    output_root: []const u8,
    options: Options,
    codes: encoder.blob_builder.LanguageCodes,
    namespaces: *const namespace_registry.Registry,
    pool: *ExpansionPool,
    dump: *dump_source.SourceReader,
    page_index: *const Mapped,
    kind: dump_source.PageIndexKind,
    index_path: []const u8,
) !void {
    const shard_pages = options.shard_pages.?;
    const total = options.limit_pages.?;
    try std.Io.Dir.cwd().createDirPath(io, output_root);
    const index_start = try pageIndexStart(page_index.bytes, options);
    var lines = std.mem.splitScalar(u8, index_start.bytes, '\n');
    var next_byte_offset = options.index_byte_offset.?;
    var ordinal = index_start.ordinal;
    var selected: usize = 0;
    var next_progress = std.Io.Clock.awake.now(io).toNanoseconds() + 10 * std.time.ns_per_s;
    var pending: ?PendingShard = null;
    defer if (pending) |*shard| shard.deinit();
    while (lines.next()) |line| {
        const line_offset = next_byte_offset;
        next_byte_offset += line.len;
        if (next_byte_offset < page_index.bytes.len) next_byte_offset += 1;
        if (line.len == 0 or line[0] == '#') continue;
        const page_ordinal = ordinal;
        ordinal += 1;
        if (page_ordinal < options.start_page) continue;
        if (selected == total) break;
        if (pending != null and pending.?.selected == pending.?.requested) {
            try pending.?.publish(pool, dump, codes, index_path, page_index.identity);
            pending.?.deinit();
            pending = null;
        }
        if (pending == null) {
            const start = options.start_page + selected;
            const requested = @min(shard_pages, total - selected);
            const offset = if (start == 0) 0 else line_offset;
            pending = try PendingShard.init(io, a, output_root, start, requested, offset, codes);
            if (pool.reviewed_nonlexical) |review| pending.?.writer.?.namespace_coverage.reviewed_nonlexical_sha256 = review.sha256;
        }
        const shard = &pending.?;
        shard.selected += 1;
        shard.writer.?.stats.pages_seen = shard.selected;
        selected += 1;
        try dispatchIndexedPage(pool, &shard.writer.?, dump, kind, namespaces, line, page_ordinal);
        const progress_now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (selected % 100_000 == 0 or progress_now >= next_progress) {
            next_progress = progress_now + 10 * std.time.ns_per_s;
            diagnostics.printLine("page compilation progress selected={d} ordinal={d} shard_start={d} main_pages={d} language_records={d} workers={d}\n", .{
                selected,                              page_ordinal,   shard.start, shard.writer.?.stats.main_pages,
                shard.writer.?.stats.language_records, pool.slots.len,
            });
        }
    }
    if (selected != total) return error.ShortPageIndex;
    if (pending != null) {
        try pending.?.publish(pool, dump, codes, index_path, page_index.identity);
        pending.?.deinit();
        pending = null;
    }
    if (!std.meta.eql(page_index.identity, try pathIdentity(io, index_path))) return error.PageIndexChanged;
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        diagnostics.printLine("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2|multistream.xml.zst> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--expansion-timeout-ms N] [--now-unix UNIX] [--shard-pages N] [--audit-presentation-errors [--audit-expanded-bytes N]]\n", .{});
        return error.Usage;
    }
    const options = parseOptions(args) catch {
        diagnostics.printLine("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2|multistream.xml.zst> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--expansion-timeout-ms N] [--now-unix UNIX] [--shard-pages N] [--audit-presentation-errors [--audit-expanded-bytes N]]\n", .{});
        return error.Usage;
    };
    const cpu_limit = @min(max_worker_count, std.Thread.getCpuCount() catch 1);
    if (options.workers > @max(@as(usize, 1), cpu_limit)) {
        diagnostics.printLine("refusing {d} expansion workers; safe limit on this host is {d}\n", .{ options.workers, @max(@as(usize, 1), cpu_limit) });
        return error.ResourceLimit;
    }

    failure_receipt_context = if (options.failure_receipt) |path| .{
        .io = init.io, .a = a, .path = path,
        .invocation_id = options.invocation_id.?, .invocation_args = args[1..],
    } else null;
    defer failure_receipt_context = null;
    var audit_storage: ?PresentationAudit = if (options.audit_presentation_errors)
        try PresentationAudit.init(init.io, a, args[2], .{ .dump_path = args[1], .expander_root = options.expander_root, .workers = options.workers, .timeout_ms = options.expansion_timeout_ms orelse expansion_deadline.default_ms, .now_unix = options.now_unix orelse std.Io.Clock.real.now(init.io).toSeconds(), .start_page = options.start_page, .requested_limit = options.limit_pages, .index_byte_offset = options.index_byte_offset, .expanded_byte_cap = options.audit_expanded_bytes orelse 0 })
    else
        null;
    defer if (audit_storage) |*audit| audit.deinit();
    runBlobBuild(init.io, a, args, options, if (audit_storage) |*audit| audit else null) catch |err| {
        if (audit_storage) |*audit| audit.abort(err);
        return err;
    };
}

fn runBlobBuild(io: std.Io, a: std.mem.Allocator, args: []const []const u8, options: Options, audit: ?*PresentationAudit) !void {
    var namespaces = try namespace_registry.Registry.load(io, a, options.expander_root);
    defer namespaces.deinit();
    const interwiki_path = try std.fs.path.join(a, &.{ options.expander_root, "interwiki-map.tsv" });
    defer a.free(interwiki_path);
    const interwiki_bytes = std.Io.Dir.cwd().readFileAlloc(io, interwiki_path, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (interwiki_bytes) |bytes| a.free(bytes);
    if (interwiki_bytes) |bytes| try namespaces.attachInterwikiMap(bytes);
    var registry = try loadLanguageRegistry(io, a, options.expander_root, &namespaces);
    defer registry.deinit();
    const behavior_path = try std.fs.path.join(a, &.{ options.expander_root, "behavior-switches.tsv" });
    defer a.free(behavior_path);
    const behavior_bytes = std.Io.Dir.cwd().readFileAlloc(io, behavior_path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (behavior_bytes) |bytes| a.free(bytes);
    var behavior: ?namespace_registry.behavior_switches.Registry = if (behavior_bytes) |bytes| try namespace_registry.behavior_switches.Registry.init(a, bytes, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256) else null;
    defer if (behavior) |*value| value.deinit();
    const image_path = try std.fs.path.join(a, &.{ options.expander_root, "image-options.tsv" });
    defer a.free(image_path);
    const image_bytes = std.Io.Dir.cwd().readFileAlloc(io, image_path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (image_bytes) |bytes| a.free(bytes);
    var behavior_digest: [32]u8 = undefined;
    if (image_bytes != null and behavior_bytes == null) return error.ImageIdentityMismatch;
    std.crypto.hash.sha2.Sha256.hash(behavior_bytes orelse "", &behavior_digest, .{});
    var images: ?namespace_registry.image_options.Registry = if (image_bytes) |bytes| try namespace_registry.image_options.Registry.init(a, bytes, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256, behavior_digest) else null;
    defer if (images) |*value| value.deinit();
    var codes = languageCodes(&registry, &namespaces);
    codes.behavior_switches = if (behavior) |*value| value else null;
    codes.image_options = if (images) |*value| value else null;

    const page_index_path = try std.fs.path.join(a, &.{ options.expander_root, "page-index.tsv" });
    defer a.free(page_index_path);
    var page_index = try mmapPath(io, page_index_path);
    defer page_index.deinit();
    const page_index_kind = dump_source.pageIndexKind(page_index.bytes);
    const page_title_index_path = try std.fs.path.join(a, &.{ options.expander_root, dump_source.page_title_index_filename });
    defer a.free(page_title_index_path);
    var page_title_index = try mmapPath(io, page_title_index_path);
    defer page_title_index.deinit();
    const title_index = try dump_source.PageTitleIndex.init(page_title_index.bytes);
    if (title_index.page_index_size != page_index.bytes.len or title_index.kind != page_index_kind) return error.PageTitleIndexMismatch;
    const redirects_path = try std.fs.path.join(a, &.{ options.expander_root, "page-redirects.tsv" });
    defer a.free(redirects_path);
    var redirects_storage: ?Mapped = mmapPath(io, redirects_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (redirects_storage) |*mapped| mapped.deinit();
    var redirects: ?encoder.page_redirects.Snapshot = if (redirects_storage) |mapped| try encoder.page_redirects.Snapshot.init(a, mapped.bytes, &namespaces) else null;
    defer if (redirects) |*snapshot| snapshot.deinit();
    const stream_index_path = try std.fs.path.join(a, &.{ options.expander_root, "dump-streams.tsv" });
    defer a.free(stream_index_path);
    var dump = try dump_source.SourceReader.open(
        io,
        a,
        a,
        args[1],
        page_index_kind,
        if (dump_source.isMultistream(page_index_kind)) stream_index_path else null,
    );
    defer dump.deinit();

    // Jobs borrow their titles from page_index. Join every worker before
    // releasing those mapped bytes, including fatal expansion-error unwinds
    // while another worker is retrying a request after a remote OOM.
    const worker_path = try std.fs.path.join(a, &.{ options.expander_root, "dict-bundle-expander" });
    defer a.free(worker_path);
    var pool = try ExpansionPool.init(io, a, options.expander_root, worker_path, args[1], options.workers, if (audit) |value| value.context.now_unix else options.now_unix, options.expansion_timeout_ms orelse expansion_deadline.default_ms);
    defer pool.deinit();
    pool.audit = audit;
    pool.page_index_bytes = page_index.bytes;
    pool.page_title_index = title_index;
    pool.page_redirects = if (redirects) |*snapshot| snapshot else null;
    const site_mainpage = try loadSiteMainPage(io, a, options.expander_root, &namespaces);
    defer if (site_mainpage) |site| a.free(site.title);
    pool.site_mainpage = site_mainpage;
    var reviewed_storage: ?reviewed_nonlexical.Review = null;
    defer if (reviewed_storage) |*review| review.deinit();
    if (options.reviewed_nonlexical) |path| {
        const actual_dump = try reviewedDumpDigest(io, dump.file);
        reviewed_storage = try loadReviewedNonlexical(io, a, path, &namespaces, page_index.bytes, page_index_kind, actual_dump.digest);
        pool.reviewed_nonlexical = &reviewed_storage.?;
        pool.reviewed_dump_identity = actual_dump.identity;
    }
    if (options.shard_pages != null) {
        try runContinuous(io, a, args[2], options, codes, &namespaces, &pool, &dump, &page_index, page_index_kind, page_index_path);
        return;
    }

    var writer = try encoder.blob_builder.Writer.init(io, a, if (audit) |value| value.scratch_root else args[2]);
    defer writer.deinit();
    writer.language_codes = codes;
    if (pool.reviewed_nonlexical) |review| writer.namespace_coverage.reviewed_nonlexical_sha256 = review.sha256;
    const index_start = try pageIndexStart(page_index.bytes, options);
    var lines = std.mem.splitScalar(u8, index_start.bytes, '\n');
    var corpus_ordinal: usize = index_start.ordinal;
    var pages_selected: usize = 0;
    var reached_eof = true;
    var next_progress = std.Io.Clock.awake.now(io).toNanoseconds() + 10 * std.time.ns_per_s;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const page_ordinal = corpus_ordinal;
        corpus_ordinal += 1;
        if (page_ordinal < options.start_page) continue;
        if (options.limit_pages) |limit| if (pages_selected >= limit) {
            reached_eof = false;
            break;
        };
        pages_selected += 1;
        if (audit) |value| value.selected += 1;
        writer.stats.pages_seen = pages_selected;
        try dispatchIndexedPage(&pool, &writer, &dump, page_index_kind, &namespaces, line, page_ordinal);
        const progress_now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (pages_selected % 100_000 == 0 or progress_now >= next_progress) {
            next_progress = progress_now + 10 * std.time.ns_per_s;
            if (audit) |value| {
                diagnostics.printLine("presentation audit progress selected={d} consumed={d} failures={d} workers={d}\n", .{ value.selected, value.consumed, value.failed, pool.slots.len });
            } else diagnostics.printLine(
                "page compilation progress selected={d} ordinal={d} main_pages={d} language_records={d} workers={d}\n",
                .{ pages_selected, page_ordinal, writer.stats.main_pages, writer.stats.language_records, pool.slots.len },
            );
        }
    }
    try pool.drain(&writer);
    try checkReviewedDump(&pool, &dump);
    if (audit) |value| {
        // No finish, coverage, shard publication or normal success path in audit mode.
        if (!std.meta.eql(page_index.identity, try pathIdentity(io, page_index_path))) return error.AuditInputsChanged;
        try value.finish(reached_eof, true);
        diagnostics.printLine("presentation audit complete selected={d} failures={d}; no corpus publication\n", .{ value.selected, value.failed });
        if (value.failed != 0) return error.PresentationAuditFailures;
        return;
    }
    const coverage = try pageCoverage(options, pages_selected, page_index.identity);
    const stats = try writer.finish(codes);
    if (stats.pages_seen != coverage.pages_seen) return error.PageCoverageMismatch;
    if (!std.meta.eql(page_index.identity, try pathIdentity(io, page_index_path))) {
        return error.PageIndexChanged;
    }
    try writePageCoverage(io, a, args[2], coverage);

    diagnostics.printLine(
        "pages={d} main_pages={d} language_records={d} language_blobs={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d} supplemental={d} fallback_pages={d} alias_records={d}\n",
        .{
            stats.pages_seen,
            stats.main_pages,
            stats.language_records,
            stats.language_blobs,
            stats.thesaurus_records,
            stats.citations_records,
            stats.reconstruction_records,
            stats.rhymes_records,
            stats.sign_gloss_records,
            stats.supplemental_records,
            stats.fallback_pages,
            stats.alias_records,
        },
    );
}

test "Arabic dump local literal language evidence reaches decoded records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "modules" }));
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
        "828\tوحدة\tModule\tfirst-letter\t1\t0\t0\tScribunto\tcompile_only\tmodules\n");
    defer namespaces.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\tar\n# mediawiki\n" ++
        "ar\tالعربية\npi\tالبالية\nban\tالبالينية\nur\tالأوردية\nda\tالدانمركية\nhu\tالهنغارية\nmnw\tMon\n" });
    const module_sources = [_][2][]const u8{
        .{ "وحدة:languages/data2", "local m = {}; m['pi'] = { canonicalName = 'بالي' }; return m" },
        .{ "Module:لغات/بيانات", "local data = {}; data.lang_table = { ['hu'] = { name = 'مجرية' }, ['ban'] = { name = 'بالية' }, ['pi'] = { name = 'بالية' }, ['ca-valencia'] = { name = 'بلنسية' } }; return data" },
        .{ "وحدة:languages/data3/m", "local m = {}; m['mnw'] = { canonicalName = 'مون', otherNames = {'Unselected Mon alias'} }; return m" },
        .{ "قالب:languages/data3/m", "local m = {}; m['mnw'] = { canonicalName = 'Wrong namespace' }; return m" },
        .{ "وحدة:languages/data3/M", "local m = {}; m['mnw'] = { canonicalName = 'Wrong shard case' }; return m" },
        .{ "وحدة:languages/data3/mm", "local m = {}; m['mnw'] = { canonicalName = 'Long shard' }; return m" },
        .{ "وحدة:languages/data3/m/doc", "local m = {}; m['mnw'] = { canonicalName = 'Shard documentation' }; return m" },
    };
    var manifest: std.ArrayList(u8) = .empty;
    for (module_sources, 1..) |module, page_id| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(module[1], &digest, .{});
        try manifest.appendSlice(a, try std.fmt.allocPrint(a, "{{\"page_id\":{d},\"title\":\"{s}\",\"sha256\":\"{s}\"}}\n", .{ page_id, module[0], std.fmt.bytesToHex(digest, .lower) }));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ root, page_id }), .data = module[1] });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = manifest.items });
    const page_index = "0\t0\tentry\t\t10\t100\t2026-10-01T00:00:00Z\tA\twikitext\t0\t1\t0\n" ++
        "0\t0\tقالب:ur\t\t20\t200\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t1\n" ++
        "0\t0\tTemplate:da\t\t21\t210\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n" ++
        "0\t0\tقالب:PI\t\t22\t220\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n" ++
        "0\t0\tقالب:pi\t\t23\t230\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n";
    const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = page_index });
    {
        var templates = try dump_source.TemplateSourceWriter.init(io, a, root);
        defer templates.deinit();
        try templates.append(1, 20, 200, "بال[[أردية]]:&lt;noinclude&gt;[[تصنيف:قوالب لغات]]&lt;/noinclude&gt;");
        try templates.append(2, 21, 210, "بال[[دانماركية]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>");
        try templates.append(3, 22, 220, "بال[[Wrong case]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>");
        try templates.append(4, 23, 230, "بال[[Pali local alias]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>");
        try templates.finish(index_path);
    }
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    try std.testing.expect(registry.resolve("بالية") == null);
    try std.testing.expect(registry.resolve("بلنسية") == null);
    try std.testing.expect(registry.resolve("Wrong case") == null);
    for ([_][]const u8{ "Unselected Mon alias", "Wrong namespace", "Wrong shard case", "Long shard", "Shard documentation" }) |label|
        try std.testing.expect(registry.resolveTrusted(label) == null);
    try std.testing.expectEqualStrings("pi", registry.resolveTrusted("Pali local alias").?.code);
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    const expected = [_][4][]const u8{
        .{ "pi", "البالية", "بالي", "Pali definition" },
        .{ "hu", "الهنغارية", "مجرية", "Hungarian definition" },
        .{ "ur", "الأوردية", "أردية", "Urdu definition" },
        .{ "da", "الدانمركية", "دانماركية", "Danish definition" },
        .{ "mnw", "Mon", "مون", "Mon definition" },
    };
    var expanded: std.ArrayList(u8) = .empty;
    var raw: std.ArrayList(u8) = .empty;
    for (expected) |language| {
        try std.testing.expectEqualStrings(language[1], registry.resolveTrusted(language[2]).?.heading);
        try expanded.appendSlice(a, try std.fmt.allocPrint(a, "== {s} ==\n# {s}\n", .{ language[2], language[3] }));
        try raw.appendSlice(a, try std.fmt.allocPrint(a, "== {{{{اللغة|{s}}}}} ==\n# {s}\n", .{ language[2], language[3] }));
    }
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "shared", expanded.items, raw.items, null);
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "mon-plain", "== مون ==\n# Plain Mon definition\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 5), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    for (expected) |language| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(language[1], &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("shared")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(language[0], decoded.entry.language_code);
        for (expected) |other|
            try std.testing.expectEqual(std.mem.eql(u8, language[0], other[0]), std.mem.indexOf(u8, record.payload, other[3]) != null);
        const plain = try index.find("mon-plain");
        try std.testing.expectEqual(std.mem.eql(u8, language[0], "mnw"), plain != null);
        if (plain) |mon| {
            const mon_decoded = try encoder.presentation_codec.decodeAlloc(a, mon.payload, mon.title, .language, metadata);
            try std.testing.expectEqualStrings("mnw", mon_decoded.entry.language_code);
            try std.testing.expect(std.mem.indexOf(u8, mon.payload, "Plain Mon definition") != null);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "1.lua" }), .data = "return {}" });
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &namespaces));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "1.lua" }), .data = module_sources[0][1] });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "3.lua" }), .data = "return {}" });
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &namespaces));
}

test "Arabic canonical source admission accepts only bounded data shards" {
    try std.testing.expect(isArabicCanonicalLanguageModule("languages/data2"));
    for ("abcdefghijklmnopqrstuvwxyz") |letter| {
        var title = "languages/data3/a".*;
        title[title.len - 1] = letter;
        try std.testing.expect(isArabicCanonicalLanguageModule(&title));
    }
    for ([_][]const u8{ "languages/data3", "languages/data3/", "languages/data3/M", "languages/data3/mm", "languages/data3/m/doc", "languages/data3/1", "languages/data3/م", "languages/data3/m ", "Languages/data3/m", "other/languages/data3/m", "languages/data2/doc" }) |title|
        try std.testing.expect(!isArabicCanonicalLanguageModule(title));
}

test "Arabic data3 loader rejects later mutation before trusting a canonical label" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "modules" }));
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
        "828\tوحدة\tModule\tfirst-letter\t1\t0\t0\tScribunto\tcompile_only\tmodules\n");
    defer namespaces.deinit();
    for ([_][]const u8{
        "m['mnw'].canonicalName=make_name()",
        "m[key]={canonicalName='Dynamic key'}",
        "local alias=m; alias['mnw']={canonicalName='Changed'}",
    }) |later| {
        var registry = language_registry.Registry.empty(a);
        defer registry.deinit();
        try registry.addTsv("# content-language\tar\nar\tالعربية\nmnw\tMon\n");
        const source = try std.fmt.allocPrint(a, "local m={{}}; m['mnw']={{canonicalName='مون'}}; {s}; return m", .{later});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        const manifest = try std.fmt.allocPrint(a, "{{\"page_id\":161772,\"title\":\"وحدة:languages/data3/m\",\"sha256\":\"{s}\"}}\n", .{std.fmt.bytesToHex(digest, .lower)});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "161772.lua" }), .data = source });
        try loadArabicLanguageModules(io, a, root, &namespaces, manifest, &registry);
        try std.testing.expect(registry.resolveTrusted("مون") == null);
        try std.testing.expectEqualStrings("mnw", registry.resolveTrusted("Mon").?.code);
    }
}

test "literal Arabic language template proof rejects executable or ambiguous text" {
    try std.testing.expectEqualStrings("أردية", literalArabicLanguageTemplate("بال[[أردية]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>\n").?);
    for ([_][]const u8{
        "بال[[{{اسم}}]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>",
        "بال[[أردية|Other]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude>",
        "بال[[أردية]]: extra<noinclude>[[تصنيف:قوالب لغات]]</noinclude>",
        "#REDIRECT [[قالب:ur]]",
        "<noinclude>بال[[أردية]]:<noinclude>[[تصنيف:قوالب لغات]]</noinclude></noinclude>",
    }) |source| try std.testing.expect(literalArabicLanguageTemplate(source) == null);
}

test "Arabic edition heading aliases preserve distinct decoded language records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    // Pinned arwiktionary preferred names include the definite article, while
    // قالب:اللغة echoes its indefinite argument in the page heading.
    try registry.addTsv("# wikidict-language-registry-v2\n# content-language\tar\n# mediawiki\n" ++
        "ar\tالعربية\tar\tArabic\tara\n" ++
        "en\tالإنجليزية\tEnglish\ten\teng\n" ++
        "fr\tالفرنسية\tFrançais\tfrançais\tfr\tFrench\tfra\tfre\n");
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const arabic_definition = "# مجموعة من الأوراق أو الصحف مجموعة مع بعضها البعض.\n";
    const english_definition = "# An English definition.\n";
    const french_definition = "# Une définition française.\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "كِتَاب", "== عربية[[تصنيف:عربية]] ==\n" ++ arabic_definition, "== {{اللغة|عربية}} ==\n" ++ arabic_definition, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "shared", "== عربية[[تصنيف:عربية]] ==\n" ++ arabic_definition ++
        "== إنجليزية[[تصنيف:إنجليزية]] ==\n" ++ english_definition ++
        "== فرنسية[[تصنيف:فرنسية]] ==\n" ++ french_definition, "== {{اللغة|عربية}} ==\n" ++ arabic_definition ++
        "== {{اللغة|إنجليزية}} ==\n" ++ english_definition ++
        "== {{اللغة|فرنسية}} ==\n" ++ french_definition, null);
    // With no template-bearing raw source, the rendered heading still has to
    // pass the trusted-name check instead of falling back to the edition's ar.
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "plain", "== إنجليزية ==\n" ++ english_definition, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 5), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);

    const expected = [_][3][]const u8{
        .{ "ar", "العربية", arabic_definition[2..] },
        .{ "en", "الإنجليزية", english_definition[2..] },
        .{ "fr", "الفرنسية", french_definition[2..] },
    };
    for (expected) |language| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(language[1], &filename) });
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(language[0], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("shared")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(language[0], decoded.entry.language_code);
        for (expected) |definition| {
            const content = std.mem.trim(u8, definition[2], "\n");
            try std.testing.expectEqual(std.mem.eql(u8, language[0], definition[0]), std.mem.indexOf(u8, record.payload, content) != null);
        }
        try std.testing.expectEqual(std.mem.eql(u8, language[0], "ar"), (try index.find("كِتَاب")) != null);
        try std.testing.expectEqual(std.mem.eql(u8, language[0], "en"), (try index.find("plain")) != null);
    }
}

test "blob expansion timeout is explicit bounded and rejects duplicates" {
    const defaults = try parseOptions(&.{ "dict-blob-build", "dump.bz2", "out", "--expander-root", "root" });
    try std.testing.expect(defaults.expansion_timeout_ms == null);
    const configured = try parseOptions(&.{ "dict-blob-build", "dump.bz2", "out", "--expander-root", "root", "--expansion-timeout-ms", "600000" });
    try std.testing.expectEqual(@as(?u32, 600_000), configured.expansion_timeout_ms);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dict-blob-build", "dump.bz2", "out", "--expander-root", "root", "--expansion-timeout-ms" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dict-blob-build", "dump.bz2", "out", "--expander-root", "root", "--expansion-timeout-ms", "0" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dict-blob-build", "dump.bz2", "out", "--expander-root", "root", "--expansion-timeout-ms", "100", "--expansion-timeout-ms", "200" }));
}

test "operational expansion timeouts cannot become successful empty pages" {
    const a = std.testing.allocator;
    try std.testing.expect((try expansionFallbackReasonAlloc(a, error.Timeout, null)) == null);
    try std.testing.expect((try expansionFallbackReasonAlloc(a, error.StartupTimeout, null)) == null);
    try std.testing.expect((try expansionFallbackReasonAlloc(a, error.OutOfMemory, null)) == null);
    inline for (.{ "OutOfMemory", "Timeout" }) |name| {
        try std.testing.expect((try expansionFallbackReasonAlloc(a, error.ExpansionFailed, .{
            .stage = "expand",
            .error_name = name,
            .detail = "",
        })) == null);
    }
    const semantic = (try expansionFallbackReasonAlloc(a, error.ExpansionFailed, .{
        .stage = "expand",
        .error_name = "NotImplemented",
        .detail = "",
    })).?;
    defer a.free(semantic);
    try std.testing.expectEqualStrings("expansion_error:expand:NotImplemented", semantic);
    const recoverable = (try expansionFallbackReasonAlloc(a, error.ExpansionFailed, null)).?;
    defer a.free(recoverable);
    try std.testing.expectEqualStrings("expansion_error:ExpansionFailed", recoverable);
}

test "indexed XML redirects bypass workers and preserve source namespace accounting" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tbgwiktionary\n# dump-date\t20261001\n# content-language\tbg\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tШаблон\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tКатегория\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    const pairs = [_][2][]const u8{ .{ "Animus", "animus" }, .{ "Combustible", "combustible" }, .{ "County seat", "county seat" }, .{ "Gainst", "gainst" } };
    var text: std.ArrayList(u8) = .empty;
    var index_text: std.ArrayList(u8) = .empty;
    var selected: std.ArrayList([]const u8) = .empty;
    for (pairs, 0..) |pair, i| {
        const source = try std.fmt.allocPrint(pa, "#REDIRECT [[{s}]]\n", .{pair[1]});
        const row = try std.fmt.allocPrint(pa, "{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0", .{ text.items.len, source.len, pair[0], pair[1], i + 1, i + 11 });
        try selected.append(pa, row);
        try index_text.appendSlice(pa, row);
        try index_text.append(pa, '\n');
        try text.appendSlice(pa, source);
    }
    for (pairs, 0..) |pair, i| {
        const row = try std.fmt.allocPrint(pa, "0\t0\t{s}\t\t{d}\t{d}\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0\n", .{ pair[1], i + 101, i + 201 });
        try index_text.appendSlice(pa, row);
    }
    const compile_only = "0\t0\tШаблон:Alias\tanimus\t900\t901\t2026-10-01T00:00:00Z\tUser\twikitext\t10\t1\t0";
    try index_text.appendSlice(pa, compile_only);
    try index_text.append(pa, '\n');
    const dump_path = try std.fs.path.join(pa, &.{ root, "pages.xml" });
    const index_path = try std.fs.path.join(pa, &.{ root, "page-index.tsv" });
    const titles_path = try std.fs.path.join(pa, &.{ root, dump_source.page_title_index_filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = text.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_text.items });
    try dump_source.buildPageTitleIndex(io, a, index_path, titles_path);
    const title_bytes = try std.Io.Dir.cwd().readFileAlloc(io, titles_path, pa, .limited(4096));
    var dump = try dump_source.SourceReader.open(io, a, a, dump_path, .raw_xml, null);
    defer dump.deinit();
    // There is no executable, event, or worker: an accidental dispatch cannot pass.
    var redirects = try encoder.page_redirects.Snapshot.init(a, "# wikidict-page-redirects-v1\n# wiki\tbgwiktionary\n# dump-date\t20261001\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n" ++
        "1\t0\t616e696d7573\t\t\n2\t0\t636f6d6275737469626c65\t\t\n3\t0\t636f756e74795f73656174\t\t\n4\t0\t6761696e7374\t\t\n# end\t4\n", &namespaces);
    defer redirects.deinit();
    var pool: ExpansionPool = .{ .io = io, .allocator = a, .completion = undefined, .slots = &.{}, .page_index_bytes = index_text.items, .page_title_index = try dump_source.PageTitleIndex.init(title_bytes), .page_redirects = &redirects };
    const out = try std.fs.path.join(pa, &.{ root, "dictionary" });
    var writer = try encoder.blob_builder.Writer.init(io, a, out);
    defer writer.deinit();
    for (selected.items, 0..) |row, i| try dispatchIndexedPage(&pool, &writer, &dump, .raw_xml, &namespaces, row, i);
    try dispatchIndexedPage(&pool, &writer, &dump, .raw_xml, &namespaces, compile_only, 8);
    writer.stats.pages_seen = 5;
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 4), stats.alias_records);
    try std.testing.expectEqual(@as(usize, 0), stats.language_records);
    try std.testing.expectEqual(@as(u64, 4), writer.namespace_coverage.rows.get(0).?.alias_pages);
    try std.testing.expectEqual(@as(u64, 0), writer.namespace_coverage.rows.get(10).?.alias_pages);
    try std.testing.expectEqual(@as(u64, 1), writer.namespace_coverage.rows.get(10).?.compile_only_rows);
}

test "AY source Russian heading keeps Maksim in the Russian record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    // Exact two rows from AY's pinned registry; source page 5074/revision 18725.
    try registry.addTsv("# wikidict-language-registry-v2\n# content-language\tay\n# mediawiki\nay\tAymar aru\tay\tAymara\taym\nru\truso\tRuso\tРусский\tрусский\tru\tRussian\trus\n");
    const codes = languageCodes(&registry, null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Raw source SHA256 1306af4e73c20e79525534c6d1fac66474df7be644998002a6de663f49f91cce.
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "Максим", "== Ruso ==\n'''Макси́м'''\n#Rusiya jaqiqapa", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename("ruso", &filename) }));
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("ru", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("Максим")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("ru", decoded.entry.language_code);
    try std.testing.expectEqualStrings("Максим", decoded.entry.title);
    var name_count: usize = 0;
    var definition_count: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.text, "Макси́м")) {
            name_count += 1;
            try std.testing.expect(span.bold);
        }
        if (std.mem.eql(u8, span.text, "Rusiya jaqiqapa")) {
            definition_count += 1;
            try std.testing.expect(block.kind == .definition);
            try std.testing.expectEqualStrings("1", block.number);
        }
    };
    try std.testing.expectEqual(@as(usize, 1), name_count);
    try std.testing.expectEqual(@as(usize, 1), definition_count);
}

test "explicit locale aliases separate source backed BCL lexical sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tbclwiktionary\n# dump-date\t20261001\n# content-language\tbcl\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tPlantilya\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();

    var registry = language_registry.Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("bcl\tBikol Central\nceb\tCebuano\ncts\tNorthern Catanduanes Bikol\n# local-alias\tceb\tSinugbuanon\n# local-alias\tcts\tBikol Catanduanes\n# local-alias\tbcl\tBikol Sentral\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact source heading roles; the small lexical expansion is source-instantiated, not captured runtime output.
    const talisay_raw = "==Sinugbuanon==\n===Toltol na pangngaran===\n{{head|ceb|toltol na pangngaran}}\n# sarong [[syudad]] sa [[Cebu]], [[Filipinas]]\n# sarong [[barangay]] sa [[Santander]], Cebu\n==Bikol Central==\n{{bcl-tng-png}}\n# sarong ikaapat na klase nin [[banwaan]] sa [[probinsya]] kan [[Camarines Norte]]\n";
    const talisay_expanded = "==Sinugbuanon==\n===Toltol na pangngaran===\n# sarong [[syudad]] sa [[Cebu]], [[Filipinas]]\n# sarong [[barangay]] sa [[Santander]], Cebu\n==Bikol Central==\n# sarong ikaapat na klase nin [[banwaan]] sa [[probinsya]] kan [[Camarines Norte]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Talisay", talisay_expanded, talisay_raw, null);
    const angog_raw = "==Bikol Sentral==\n{{bcl-png.|}} An parte kan lalawgon\n==Bikol Catanduanes==\n{{head|cts|pangngaran}}\n#An parte kan lalawgon\n";
    const angog_expanded = "==Bikol Sentral==\n# [[local-owner]]\n==Bikol Catanduanes==\n# [[foreign-owner]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "angog", angog_expanded, angog_raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    inline for (.{ .{ "Cebuano", "Talisay", "Cebu", "Camarines Norte", "ceb" }, .{ "Bikol Central", "Talisay", "Camarines Norte", "Santander", "bcl" }, .{ "Bikol Central", "angog", "local-owner", "foreign-owner", "bcl" }, .{ "Northern Catanduanes Bikol", "angog", "foreign-owner", "local-owner", "cts" } }) |entry| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(entry[0], &filename) });
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(entry[4], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(entry[1])).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var own_links: usize = 0;
        var second_foreign_links: usize = 0;
        var definition_count: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) definition_count += 1;
            for (block.spans) |span| {
                if (std.mem.eql(u8, span.target, "Santander")) second_foreign_links += 1;
                if (std.mem.eql(u8, span.target, entry[2])) own_links += 1;
                try std.testing.expect(!std.mem.eql(u8, span.target, entry[3]));
            }
        };
        const is_foreign = std.mem.eql(u8, entry[4], "ceb");
        try std.testing.expectEqual(@as(usize, if (is_foreign) 2 else 1), definition_count);
        try std.testing.expectEqual(@as(usize, if (is_foreign) 1 else 0), second_foreign_links);
        try std.testing.expectEqual(@as(usize, 1), own_links);
    }
}

test "AF barn equals declarations keep Bokmal and Nynorsk lexical bodies separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    // Exact preferred AF rows; aliases shortened for this hermetic fixture.
    try registry.addTsv("nb\tBoeknoors\nno\tNoors\nnn\tNuwe Noors\nadj\tAdioukrou\n");
    const codes = languageCodes(&registry, null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact source declaration/template heading bytes; lexical markup below
    // is source-instantiated from barn rev200895, not captured full expansion.
    const raw = "{{=nb=}}\n{{-adj-}}\n{{IPA|baːɳ}}\n:{{H|kind}}\n{{=nn=}}\n{{IPA|baːrn}}\n:{{H|kind}}\n";
    const expanded = "==[[Noors|Noors boekmaal (nb)]]==\n===Uitspraak===\n:[[Hulp:IPA|IPA]]: baːɳ\n===Betekenisse===\n:[[kind|Kind]]\n===Vorme===\n* børn\n" ++
        "==[[Noors|Nieu-Noors (nn)]]==\n===Uitspraak===\n:[[Hulp:IPA|IPA]]: baːrn\n===Betekenisse===\n:[[kind|Kind]]\n===Vorme===\n* born\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "barn", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    for ([_][]const u8{ "Boeknoors", "Nuwe Noors" }, 0..) |heading, which| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(if (which == 0) "nb" else "nn", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("barn")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var text: std.ArrayList(u8) = .empty;
        var definition_links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.target, "kind")) definition_links += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), definition_links);
        try std.testing.expect(std.mem.indexOf(u8, text.items, if (which == 0) "baːɳ" else "baːrn") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, if (which == 0) "baːrn" else "baːɳ") == null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, if (which == 0) "børn" else "born") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, if (which == 0) "born" else "børn") == null);
    }
}

test "AN source declared bilingual headings keep four lexical languages separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    // Actual preferred/code rows; finite alias is proven by -ast- rev32603,
    // not inferred from the spelling of the entry or its lexical body.
    try registry.addTsv("# content-language\tan\nan\taragonés\tAragonés\tan\n" ++
        "es\tespanyol\tEspanyol\tEspañol\tes\n" ++
        "gl\tgallego\tGallego\tGalego\tgl\n" ++
        "ast\tasturiano\tAsturiano\tAsturianu\tast\tAstur-leyonés\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact raw revision28570 and exact declaration template bytes. Lexical/POS
    // expansion below is source-instantiated; no captured full-page claim.
    const raw = "{{-an-}}\n{{Prenunziazión|/a.ɾa.γo'nes/}}\n{{Etimolochía}}\n\n{{-adj.masc-}}\n{{inflect.an.adj.masc.-s|aragones}} \n'''aragonés'''\n\n1. Que ye u fa referenzia á Aragón, á la Corona d'Aragón, á la luenga aragonesa, á la bariedat aragonesa d'o castellán, u á bela cosa u persona relazionata con iste territorio europeu.\n\n{{-noun.masc-}}\n{{inflect.sust.masc.-s|aragones|aragones|a|aragonesiello}}\n'''aragonés'''\n\n2. Persona naxita d'Aragón u que en ostenta la ziudadanía.\n\n3. ''Per estensión''  Persona natural de belún d'os territorios que conformaban l'antiga Corona d'Aragón.\n\n''m''\n\n4. Luenga romanica, orichinata en Nabarra e Aragón, charrata actualmén en l'Alto Aragón.\n\n* '''Sinonimos''': ''nabarroaragonés; altoaragonés; fabla aragonesa''\n\n5. Bariedat d'o español peninsular oriental u \"castellán aragonés\", con sustrato e influyenzia d'o nabarroaragonés, que se charra en buena part d'Aragón.\n\n{{-trans-}}\n* {{en}}: [1][2][3][4]{{trans|en|Aragonese|5}}\n* {{ast}}: [1][2][3][4]{{trans|ast|aragonés|5}}\n* {{eu}}: [1]{{trans|eu|aragoiar|2}}; {{trans|eu|aragoiko|4}}; [4]{{trans|eu|aragoiera|5}}\n* {{ca}}: [1][2]{{trans|ca|aragonès|3}} ''m'', -esa ''f''; [4]{{trans|ca|aragonès|5}} ''m''\n* {{es}}: [1][2]{{trans|es|aragonés|3}} ''m'', -esa ''f''; [4]{{trans|es|aragonés|5}} ''m''\n* {{fi}}: [4] {{trans|fi|aragonia}}\n|valign=\"top\"|\n* {{nds}}: [1] {{trans|nds|aragoneesch}}; [4] {{trans|nds|Aragoneesch}}\n* {{fr}}: [1][2]{{trans|fr|aragonais|3}}''m'', -e ''f'' [4]{{trans|fr|aragonais|5}} ''m''\n* {{gl}}: [1][2]{{trans|gl|aragonés|3}} ''m'', -esa ''f''; [4]{{trans|gl|aragonés|5}} ''m''\n* {{it}}: [1][2]{{trans|it|aragonese|3}} ''m'', -esa ''f''; [4]{{trans|it|aragonese|5}} ''m''\n* {{pt}}: [1][2]{{trans|pt|aragonês|3}} ''m'', -esa ''f''; [4]{{trans|pt|aragonês|5}} ''m''\n* {{scn}}: [1][2]{{trans|scn|aragunisi|3}} ''m'', -isa ''f''; [4]{{trans|scn|aragunisi|5}} ''m''\n|}\n\n{{-es-}}\n{{Prenunziazión|/a.ɾa.γo'nes/}}\n{{Etimolochía}}\n{{-adj.masc-}}[[Categoría:ES:Alchetibos masculins]]\n'''aragonés'''\n\n1. [[aragonés]]\n\n{{-noun.masc-}}[[Categoría:ES:Sustantibos masculins]]\n'''aragonés'''\n\n2. [[aragonés]]\n\n{{-gl-}}\n{{Prenunziazión}}\n{{Etimolochía}}\n\n{{-adj.masc-}}[[Categoría:GL:Alchetibos masculins]]\n'''aragonés'''\n\n1. [[aragonés]]\n\n{{-noun.masc-}}[[Categoría:GL:Sustantibos masculins]]\n'''aragonés'''\n\n2. [[aragonés]]\n\n{{-ast-}}\n{{Prenunziazión}}\n{{Etimolochía}}\n\n{{-adj.masc-}}[[Categoría:AST:Alchetibos masculins]]\n'''aragonés'''\n\n1. [[aragonés]]\n\n{{-noun.masc-}}[[Categoría:AST:Sustantibos masculins]]\n'''aragonés'''\n\n2. [[aragonés]]";
    const expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en aragonés]]\n==Adchectivo masculín==\n'''aragonés'''\n\n1. Que ye u fa referenzia á Aragón, á la Corona d'Aragón, á la luenga aragonesa, á la bariedat aragonesa d'o castellán, u á bela cosa u persona relazionata con iste territorio europeu.\n\n==Sustantivo masculín==\n'''aragonés'''\n\n2. Persona naxita d'Aragón u que en ostenta la ziudadanía.\n\n3. ''Per estensión'' Persona natural de belún d'os territorios que conformaban l'antiga Corona d'Aragón.\n\n4. Luenga romanica, orichinata en Nabarra e Aragón, charrata actualmén en l'Alto Aragón.\n\n5. Bariedat d'o español peninsular oriental u \"castellán aragonés\", con sustrato e influyenzia d'o nabarroaragonés, que se charra en buena part d'Aragón.\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Lang-es.gif|40px]] '''''[[espanyol|Espanyol]]''''' <small>- ''Español''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en español]]\n==Adchectivo masculín==\n'''aragonés'''\n\n1. [[aragonés]]\n\n==Sustantivo masculín==\n'''aragonés'''\n\n2. [[aragonés]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Galicia.svg|40px]] '''''[[Wiktionary:Gallego|Gallego]]''''' <small>- ''Galego''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en gallego]]\n==Adchectivo masculín==\n'''aragonés'''\n\n1. [[aragonés]]\n\n==Sustantivo masculín==\n'''aragonés'''\n\n2. [[aragonés]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of Asturias (indoor).svg|40px]] '''''[[Wiktionary:Astur-leyonés|Astur-leyonés]]''''' <small>- ''Asturlleonés''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en asturlionés]]\n==Adchectivo masculín==\n'''aragonés'''\n\n1. [[aragonés]]\n\n==Sustantivo masculín==\n'''aragonés'''\n\n2. [[aragonés]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "aragonés", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 4), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const headings = [_][]const u8{ "aragonés", "espanyol", "gallego", "asturiano" };
    const expected_codes = [_][]const u8{ "an", "es", "gl", "ast" };
    const declaration_titles = [_][]const u8{ "Aragonés - Aragonés", "Espanyol - Español", "Gallego - Galego", "Astur-leyonés - Asturlleonés" };
    for (headings, 0..) |heading, which| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(expected_codes[which], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("aragonés")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var language_sections: usize = 0;
        var numbered_bodies: usize = 0;
        var lexical_links: usize = 0;
        var lexical_self_links: usize = 0;
        var visible: std.ArrayList(u8) = .empty;
        for (decoded.entry.sections) |section| {
            if (section.level == 1) {
                language_sections += 1;
                try std.testing.expectEqualStrings(declaration_titles[which], section.title);
            }
            for (section.blocks) |block| {
                if (block.spans.len > 0 and block.spans[0].text.len >= 3 and
                    std.ascii.isDigit(block.spans[0].text[0]) and std.mem.startsWith(u8, block.spans[0].text[1..], ". ")) numbered_bodies += 1;
                for (block.spans) |span| {
                    try visible.appendSlice(a, span.text);
                    if (std.mem.eql(u8, span.target, "aragonés")) lexical_links += 1;
                    if (std.mem.eql(u8, span.text, "aragonés") and std.mem.eql(u8, span.classes, "mw-selflink selflink")) {
                        try std.testing.expect(span.kind == .text and span.target.len == 0 and span.bold);
                        lexical_self_links += 1;
                    }
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 1), language_sections);
        try std.testing.expectEqual(@as(usize, if (which == 0) 5 else 2), numbered_bodies);
        try std.testing.expectEqual(@as(usize, 0), lexical_links);
        try std.testing.expectEqual(@as(usize, if (which == 0) 0 else 2), lexical_self_links);
        for ([_][]const u8{ "Que ye u fa referenzia", "Persona naxita d'Aragón", "Persona natural de belún", "Luenga romanica", "Bariedat d'o español" }) |body|
            try std.testing.expect((std.mem.indexOf(u8, visible.items, body) != null) == (which == 0));
    }
}

test "AF explicit ln declaration preserves loba ownership and lexical body through codec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv("ln\tLingaals\nnud\tNgala\n");
    const codes = languageCodes(&registry, null);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact raw revision185929; heading from =ln= revision175727. Lexical
    // markup is source-instantiated, not a captured full-page expansion.
    const raw = "{{=ln=}}\n\n{{-ln-werkw-|\n1 = loba\n}}\n\n{{-uitspraak-}}\n:[[Hulp:IPA|IPA]]: {{IPA|ˈlo˨ba˨}}\n\n{{-ww.-}}\n\n{{betekenisse}} \n#{{H|praat}}\n#{{H|sê}}\n\n[[Kategorie:Woorde in Ngala|loba-]]";
    const expanded = "==[[Ngala|Ngala (ln)]]==\n===Uitspraak===\n:[[Hulp:IPA|IPA]]: ˈlo˨ba˨\n===Betekenisse===\n#[[praat|Praat]]\n#[[sê|Sê]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "-loba", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename("Lingaals", &filename) }));
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("ln", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("-loba")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    var text: std.ArrayList(u8) = .empty;
    var praat: usize = 0;
    var se: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.target, "praat")) praat += 1;
        if (std.mem.eql(u8, span.target, "sê")) se += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), praat);
    try std.testing.expectEqual(@as(usize, 1), se);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "ˈlo˨ba˨") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "Praat") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "Sê") != null);
}

test "Arabic vocalized linked declaration preserves Belcika Kurdish body through codec" {
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

    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv("ku\tالكردية\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact source revision1118625; no template expansion is required.
    const raw = "== [[فِي]] [[لُغَة|ٱللُّغَةِ]] [[كردي|ٱلْكُرْدِيَّةِ]]: ==\n=== اَلْمَعْنَى: ===\n* [[بلجيكا|بلْجِيكَا]]، وَهِيَ دَوْلَةٌ أُورُبِيَّةٌ.\n\n[[تصنيف:B]]";
    const expanded = raw;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Belçîka", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename("الكردية", &filename) }));
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("ku", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("Belçîka")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    var text: std.ArrayList(u8) = .empty;
    var links: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try text.appendSlice(a, span.text);
        if (std.mem.eql(u8, span.target, "بلجيكا")) links += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "بِلْ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "بلْجِيكَا") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "وَهِيَ دَوْلَةٌ أُورُبِيَّةٌ") != null);
}

test "AN artiga source headers and exact Occitan alias preserve four owned definitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var namespaces = try @import("namespace_registry").Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv("# content-language\tan\nan\taragonés\tAragonés\tan\tAragonese\targ\nca\tcatalán\tCatalán\tCatalà\tcatalà\tca\tCatalan\tcat\nes\tespanyol\tEspanyol\tEspañol\tespañol\tes\tSpanish\tspa\noc\toccitano\tOccitano\tOccitan\toccitan\toc\tOccitan (post 1500)\toci\tOccitán\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/artiga", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Raw artiga rev28602 is exact. Declaration templates are frozen bytes.
    // POS/inflection/translation expansion is source-instantiated, not a runtime replay.
    // Preserve original raw |}; instantiated translation table owns its matching opener.
    const raw = "{{-an-}}\n{{Prenunziazión|/arˈti.ga/}}\n:*'''Etimolochía''': Parola prerromana frecuent eno lecsico d'as rechions que embironan o Perineu.\n\n{{-noun.fem-}}\n{{inflect.sust.fem|artig|artigu|a|artiguiella}}\n'''artiga'''\n# Terreno [[artigar|artigato]], ixo ye, que s'ha [[rancar|rancato]] u [[cremar|cremato]] la [[broza|broza]] e dimpués s'ha [[aladrar|aladrato]] ta poner-lo de cautibo.\n{{-trans-}} \n* {{ca}}: {{trans|ca|artiga}} \n* {{es}}: {{trans|es|artiga}}\n* {{en}}: {{trans|en|slash-and-burn}}\n* {{fr}}: {{trans|fr|brûlis}}\n* {{oc}}: {{trans|oc|artiga}}\n|}\n===Bariant dialeutal===\n*[[xartica]]\n*[[artica]]\n\n{{-ca-}}\n{{-noun-}}\n'''artiga'''\n# [[artica]]\n\n{{-es-}}\n{{-noun-}}\n'''artiga'''\n# [[artica]]\n\n{{-oc-}}\n{{-noun-}}\n'''artiga'''\n# [[artica]]";
    const expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en aragonés]]\n:*Prenunciación: /arˈti.ga/ (AFI)\n:*'''Etimolochía''': Parola prerromana frecuent eno lecsico d'as rechions que embironan o Perineu.\n\n==Sustantivo femenín==\n{|\n| artiga || artigas\n|}\n'''artiga'''\n# Terreno [[artigar|artigato]], ixo ye, que s'ha [[rancar|rancato]] u [[cremar|cremato]] la [[broza|broza]] e dimpués s'ha [[aladrar|aladrato]] ta poner-lo de cautibo.\n==Traduccions==\n{|\n| \n* ca: <span lang=\"ca\">[[artiga]]</span> \n* es: <span lang=\"es\">[[artiga]]</span>\n* en: <span lang=\"en\">[[slash-and-burn]]</span>\n* fr: <span lang=\"fr\">[[brûlis]]</span>\n* oc: <span lang=\"oc\">[[artiga]]</span>\n|}\n===Bariant dialeutal===\n*[[xartica]]\n*[[artica]]\n\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Catalonia.svg|40px]] '''''[[Wiktionary:Catalán|Catalán]]''''' <small>- ''Català''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n[[Category:Parabras en catalán]]\n==Sustantivo==\n'''artiga'''\n# [[artica]]\n\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Lang-es.gif|40px]] '''''[[espanyol|Espanyol]]''''' <small>- ''Español''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en español]]\n==Sustantivo==\n'''artiga'''\n# [[artica]]\n\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Occitania.svg|40px]] '''''[[Wiktionary:Occitán|Occitán]]''''' <small>- ''Occitan''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en oczitán]]\n==Sustantivo==\n'''artiga'''\n# [[artica]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "artiga", expanded, raw, null);
    // templar rev30170 has an ordinary L2 support heading between raw an/es
    // markers. Reduced expansion below uses frozen declaration-template bytes;
    // it is source-instantiated, not a retained expanded-output capture.
    const templar_raw = "{{-an-}}\n# Aragonese templar meaning\n==Se beiga tamién==\n*[[templato|Templato]]\n{{-es-}}\n# Spanish templar meaning\n";
    const templar_expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Aragon.svg|40px]] '''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n==Verbo transitivo==\n# Aragonese templar meaning\n==Se beiga tamién==\n*[[templato|Templato]]\n=<div id=\"toc\" class=\"toccolours\" >[[Image:Lang-es.gif|40px]] '''''[[espanyol|Espanyol]]''''' <small>- ''Español''</small></div>=\n==Verbo transitivo==\n# Spanish templar meaning\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "templar", templar_expanded, templar_raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 4), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const headings = [_][]const u8{ "aragonés", "catalán", "espanyol", "occitano" };
    const expected_codes = [_][]const u8{ "an", "ca", "es", "oc" };
    for (headings, 0..) |heading, which| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(expected_codes[which], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        if (which == 0 or which == 2) {
            try std.testing.expect((try index.find("templar")) != null);
            const templar_record = (try index.find("templar")).?;
            try std.testing.expect(std.mem.indexOf(u8, templar_record.payload, if (which == 0) "Aragonese templar meaning" else "Spanish templar meaning") != null);
            try std.testing.expect(std.mem.indexOf(u8, templar_record.payload, if (which == 0) "Spanish templar meaning" else "Aragonese templar meaning") == null);
            try std.testing.expectEqual(which == 0, std.mem.indexOf(u8, templar_record.payload, "templato") != null);
        } else try std.testing.expect((try index.find("templar")) == null);
        const record = (try index.find("artiga")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var definitions: usize = 0;
        var native_links: usize = 0;
        var foreign_links: usize = 0;
        var native_body = false;
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind != .definition) continue;
            definitions += 1;
            for (block.spans) |span| {
                if (std.mem.indexOf(u8, span.text, "Terreno ") != null) native_body = true;
                for ([_][]const u8{ "artigar", "rancar", "cremar", "broza", "aladrar" }) |target|
                    if (std.mem.eql(u8, span.target, target)) {
                        native_links += 1;
                    };
                if (std.mem.eql(u8, span.target, "artica")) foreign_links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(which == 0, native_body);
        try std.testing.expectEqual(@as(usize, if (which == 0) 5 else 0), native_links);
        try std.testing.expectEqual(@as(usize, if (which == 0) 0 else 1), foreign_links);
    }
    // A registered POS-shaped ISO code still cannot turn an uncorroborated
    // hyphen template into a language boundary. No generic trust expansion.
    try registry.addTsv("adj\tAdioukrou\tadj\n");
    const negative_codes = languageCodes(&registry, &namespaces);
    const negative_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pos", .{tmp.sub_path});
    var negative = try encoder.blob_builder.Writer.init(std.testing.io, a, negative_root);
    defer negative.deinit();
    negative.language_codes = negative_codes;
    try negative.addExpandedPage(a, .{ .id = 0, .kind = .language }, "pos-control", "=Adjective=\n# preserved lexical control\n", "{{-adj-}}\n# preserved lexical control\n", null);
    const negative_stats = try negative.finish(negative_codes);
    try std.testing.expectEqual(@as(usize, 1), negative_stats.language_records);
    var negative_filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var negative_mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ negative_root, "languages", encoder.blob_catalog.languageBlobFilename("Unclassified", &negative_filename) }));
    defer negative_mapped.deinit();
    const negative_blob = try encoder.blob_format.inspect(negative_mapped.bytes);
    try std.testing.expectEqualStrings("", (try negative_blob.languageMetadata()).code);
}

test "Aal exact Arabic noun subtrees preserve exclusive English German bodies and unknown reset" {
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
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv("# content-language\tar\nen\tالإنجليزية\tإنجليزي\nde\tالألمانية\nar\tالعربية\naal\tAfade\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/aal", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Aal rev1429569 exact source; no expansion is needed for these headings.
    const raw = "== aal ==\n=== اسم إنجليزي ===\nآل - شجيرة من [[الهند]]\n\n== der Aal ==\n=== اسم ألماني ===\nاسم مذكر (der Aal (m\n\n=== المعنى ===\nحيوان مائي يعيش في البحار والأنهار ، وله شكل الثعبان وجلده زلق (ثعبان الماء) .\n\n=== الجمع ===\ndie Aale\n\n=== تطبيقات أخرى ===\nمثال : glatt wie ein Aal\nيعني : مراوغ مثل الثعبان .\n\n=== المراجع ===\n# http://www.duden.de/rechtschreibung/Aal\n\n[[تصنيف:إنجليزية]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Aal", raw, raw, null);
    const scopes = "== lemma ==\n=== اسم إنجليزي ===\n# EN_SENTINEL\n== en ==\n=== اسم ===\n# UNDECLARED_SENTINEL\n== foreign ==\n=== اسم مجهول ===\n# UNKNOWN_SENTINEL\n== conflict ==\n=== اسم إنجليزي ===\n# CONFLICT_FIRST\n=== اسم ألماني ===\n# CONFLICT_SECOND\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "scopes", scopes, scopes, null);
    const native = "# NATIVE_UNSECTIONED_SENTINEL";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "native", native, native, null);
    const role = "== اَلْمَعَانِي ==\n# ROLE_ONLY_SENTINEL";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "role", role, role, null);
    // Beeb rev1430527 exact authored source: proper-noun POS is not a language adjective.
    // No templates require expansion; retain the real linked English boundary and ordinary alias.
    const beeb = "== [[إنجليزية]] ==\n== إنجليزي ==\n\n=== اسم عَلَم ===\n\n# هيئة الإذاعة البريطانية\n\n[[تصنيف:إنجليزية]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Beeb", beeb, beeb, null);
    // aalen rev1135343 supplies the whole literal German-language heading.
    // The conflicting nested declaration is a controlled precedence negative.
    const prefix_conflict = "== لغة ألمانية ==\n=== اسم إنجليزي ===\n# DE_PREFIX_OWNER_SENTINEL\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "aalen-prefix-conflict", prefix_conflict, prefix_conflict, null);
    // An explicit unknown whole-label declaration resets a previous valid owner.
    const prefix_reset = "== لغة ألمانية ==\n# KNOWN_PREFIX_SENTINEL\n== لغة مجهولة ==\n# UNKNOWN_PREFIX_RESET_SENTINEL\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "prefix-reset", prefix_reset, prefix_reset, null);
    _ = try writer.finish(codes);
    const Expected = struct { heading: []const u8, code: []const u8, title: []const u8, required: []const []const u8, excluded: []const []const u8 };
    const cases = [_]Expected{
        .{ .heading = "الإنجليزية", .code = "en", .title = "Aal", .required = &.{ "شجيرة", "الهند" }, .excluded = &.{ "die Aale", "glatt wie ein Aal", "ثعبان الماء" } },
        .{ .heading = "الألمانية", .code = "de", .title = "Aal", .required = &.{ "اسم مذكر", "ثعبان الماء", "die Aale", "glatt wie ein Aal", "مراوغ مثل الثعبان" }, .excluded = &.{ "شجيرة", "الهند" } },
        .{ .heading = "الإنجليزية", .code = "en", .title = "scopes", .required = &.{"EN_SENTINEL"}, .excluded = &.{ "UNDECLARED_SENTINEL", "UNKNOWN_SENTINEL", "CONFLICT_FIRST", "CONFLICT_SECOND" } },
        .{ .heading = "Unclassified", .code = "", .title = "scopes", .required = &.{ "UNDECLARED_SENTINEL", "UNKNOWN_SENTINEL", "CONFLICT_FIRST", "CONFLICT_SECOND" }, .excluded = &.{"EN_SENTINEL"} },
        .{ .heading = "Unclassified", .code = "", .title = "role", .required = &.{"ROLE_ONLY_SENTINEL"}, .excluded = &.{} },
        .{ .heading = "Unclassified", .code = "", .title = "native", .required = &.{"NATIVE_UNSECTIONED_SENTINEL"}, .excluded = &.{} },
        .{ .heading = "الإنجليزية", .code = "en", .title = "Beeb", .required = &.{"هيئة الإذاعة البريطانية"}, .excluded = &.{ "DE_PREFIX_OWNER_SENTINEL", "die Aale", "UNKNOWN_SENTINEL" } },
        .{ .heading = "الألمانية", .code = "de", .title = "aalen-prefix-conflict", .required = &.{"DE_PREFIX_OWNER_SENTINEL"}, .excluded = &.{ "هيئة الإذاعة البريطانية", "شجيرة", "UNKNOWN_SENTINEL" } },
        .{ .heading = "الألمانية", .code = "de", .title = "prefix-reset", .required = &.{"KNOWN_PREFIX_SENTINEL"}, .excluded = &.{"UNKNOWN_PREFIX_RESET_SENTINEL"} },
        .{ .heading = "Unclassified", .code = "", .title = "prefix-reset", .required = &.{"UNKNOWN_PREFIX_RESET_SENTINEL"}, .excluded = &.{"KNOWN_PREFIX_SENTINEL"} },
    };
    for (cases) |expected| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(expected.heading, &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(expected.code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const found = try index.find(expected.title);
        try std.testing.expect(found != null);
        const record = found.?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        var text: std.ArrayList(u8) = .empty;
        var india: usize = 0;
        var duden: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.target, "الهند")) india += 1;
            if (std.mem.eql(u8, span.target, "http://www.duden.de/rechtschreibung/Aal")) duden += 1;
        };
        for (expected.required) |value| try std.testing.expect(std.mem.indexOf(u8, text.items, value) != null);
        for (expected.excluded) |value| try std.testing.expect(std.mem.indexOf(u8, text.items, value) == null);
        if (std.mem.eql(u8, expected.title, "Aal")) {
            try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, expected.code, "en")) 1 else 0), india);
            try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, expected.code, "de")) 1 else 0), duden);
        }
    }
    // Every decoded positive is exclusive: no fallback or second owner can duplicate it.
    inline for (.{ "الإنجليزية", "الألمانية", "Unclassified" }) |heading| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(std.testing.io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        if (!std.mem.eql(u8, heading, "Unclassified")) try std.testing.expect((try index.find("native")) == null);
        if (!std.mem.eql(u8, heading, "الإنجليزية")) try std.testing.expect((try index.find("Beeb")) == null);
        if (!std.mem.eql(u8, heading, "الألمانية")) try std.testing.expect((try index.find("aalen-prefix-conflict")) == null);
        if (std.mem.eql(u8, heading, "الإنجليزية") or std.mem.eql(u8, heading, "العربية")) try std.testing.expect((try index.find("prefix-reset")) == null);
    }
    // No heading or corroborated declaration proves an Arabic-owned record.
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, encoder.blob_catalog.manifest_filename }), a, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "العربية") == null);
}

test "reviewed nonlexical rows authenticate all four sources before skipping aliases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n# content-language\ttest\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    const titles = [_][]const u8{ "Notice", "Alias one", "Alias two", "Alias three" };
    // These are independently authored regression bodies, unrelated to corpus text.
    const bodies = [_][]const u8{ "authored &amp; notice", "#REDIRECT[[Notice]]", "#REDIRECT[[Notice]]", "#REDIRECT[[Notice]]" };
    var row_lines: [5][]const u8 = undefined;
    var review_rows: [4]reviewed_nonlexical.Row = undefined;
    var offset: usize = 0;
    for (titles, bodies, 0..) |title, body, i| {
        const target = if (i == 0) "" else "Notice";
        row_lines[i] = try std.fmt.allocPrint(pa, "{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t{d}", .{ offset, body.len, title, target, i + 1, i + 101, @intFromBool(i == 0) });
        const hash = std.fmt.bytesToHex(reviewed_nonlexical.digest(if (i == 0) "authored & notice" else body), .lower);
        review_rows[i] = .{ .namespace = 0, .page_id = @intCast(i + 1), .revision_id = @intCast(i + 101), .title = title, .decoded_source_sha256 = try pa.dupe(u8, &hash) };
        offset += body.len;
    }
    const lexical_body = "==English==\n# authored independent lexical definition";
    row_lines[4] = try std.fmt.allocPrint(pa, "{d}\t{d}\tIndependent word\t\t99\t199\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0", .{ offset, lexical_body.len });
    const reviewed_source = try std.mem.concat(pa, u8, &bodies);
    const source = try std.fmt.allocPrint(pa, "{s}{s}", .{ reviewed_source, lexical_body });
    const index_text = try std.mem.join(pa, "\n", &row_lines);
    const dump_path = try std.fs.path.join(pa, &.{ root, "pages.xml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = source });
    var dump = try dump_source.SourceReader.open(io, a, a, dump_path, .raw_xml, null);
    defer dump.deinit();
    const actual_dump = try reviewedDumpDigest(io, dump.file);
    const registry_hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const dump_hash = std.fmt.bytesToHex(actual_dump.digest, .lower);
    const index_hash = std.fmt.bytesToHex(reviewed_nonlexical.digest(index_text), .lower);
    const review_hash = std.fmt.bytesToHex(reviewed_nonlexical.digest("authored independent review evidence"), .lower);
    const manifest = try std.json.Stringify.valueAlloc(pa, reviewed_nonlexical.Manifest{ .schema = "wikidict.reviewed-nonlexical.v1", .wiki = namespaces.wiki, .date = namespaces.dump_date, .namespace_registry_sha256 = &registry_hash, .dump_sha256 = &dump_hash, .page_index_sha256 = &index_hash, .source_review_sha256 = &review_hash, .rows = &review_rows }, .{});
    const manifest_path = try std.fs.path.join(pa, &.{ root, "review.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    var review = try loadReviewedNonlexical(io, a, manifest_path, &namespaces, index_text, .raw_xml, actual_dump.digest);
    defer review.deinit();
    var completion: std.Io.Event = .unset;
    var slots = [_]ExpansionSlot{.{ .io = io, .completion = &completion, .arena = std.heap.ArenaAllocator.init(a), .worker = undefined }};
    const slot = &slots[0];
    defer slot.arena.deinit();
    var pool: ExpansionPool = .{ .io = io, .allocator = a, .completion = &completion, .slots = &slots, .page_index_bytes = index_text, .reviewed_nonlexical = &review, .reviewed_dump_identity = actual_dump.identity };
    const out = try std.fs.path.join(pa, &.{ root, "dictionary" });
    var writer = try encoder.blob_builder.Writer.init(io, a, out);
    defer writer.deinit();
    writer.namespace_coverage.reviewed_nonlexical_sha256 = review.sha256;
    // An idle slot captures dispatch without executing a worker. Reviewed rows
    // must leave it idle, including the separately enumerated alias sources.
    for (row_lines[0..4], 0..) |line, i| {
        writer.stats.pages_seen += 1;
        try dispatchIndexedPage(&pool, &writer, &dump, .raw_xml, &namespaces, line, i);
        try std.testing.expect(!slot.busy);
    }
    try checkReviewedDump(&pool, &dump);
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 4), stats.pages_seen);
    try std.testing.expectEqual(@as(usize, 0), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.alias_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    const counts = writer.namespace_coverage.rows.get(0).?;
    try std.testing.expectEqual(@as(u64, 4), counts.input_rows);
    try std.testing.expectEqual(@as(u64, 4), counts.reviewed_nonlexical_rows);
    try std.testing.expectEqual(@as(u64, 0), counts.dispatched_rows);
    try std.testing.expect(writer.namespace_coverage.site_info_sha256 == null);
    const lexical = try dump_source.parsePageIndexLine(.raw_xml, row_lines[4]);
    try std.testing.expect(!try review.matches(lexical));
    const control_out = try std.fs.path.join(pa, &.{ root, "control" });
    var control_writer = try encoder.blob_builder.Writer.init(io, a, control_out);
    defer control_writer.deinit();
    control_writer.namespace_coverage.reviewed_nonlexical_sha256 = review.sha256;
    try dispatchIndexedPage(&pool, &control_writer, &dump, .raw_xml, &namespaces, row_lines[4], 4);
    try std.testing.expect(slot.busy);
    try std.testing.expectEqualStrings("Independent word", slot.job.title);
    try std.testing.expectEqualStrings(lexical_body, slot.job.source);
    try std.testing.expectEqual(@as(u64, 1), control_writer.namespace_coverage.rows.get(0).?.dispatched_rows);
    try std.testing.expectEqual(@as(u64, 0), control_writer.namespace_coverage.rows.get(0).?.reviewed_nonlexical_rows);
}

test "captured main page identity and SQL-bound aliases are metadata not lexical pages" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\taawiktionary\n# dump-date\t20261001\n# content-language\taa\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    const registry_hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const site_bytes = try std.json.Stringify.valueAlloc(pa, .{
        .schema = "wikidict.site-info.v2",
        .wiki = "aawiktionary",
        .date = "20261001",
        .content_language = "aa",
        .namespace_registry_sha256 = @as([]const u8, &registry_hash),
        .query = .{ .general = .{ .wikiid = "aawiktionary", .mainpage = "Main_Page" } },
    }, .{});
    const site = try parseSiteMainPage(pa, site_bytes, &namespaces);
    try std.testing.expectEqualStrings("Main Page", site.title);
    const source_rows = [_][]const u8{
        "0\t0\tMain Page\t\t1511\t6705\t2009-02-21T23:10:42Z\tUser\twikitext\t0\t1\t0",
        "0\t22\tmain Page\tMain Page\t941\t6285\t2009-02-21T23:10:42Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tOther empty\t\t2000\t2001\t2009-02-21T23:10:42Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tChain\tmain Page\t3000\t3001\t2009-02-21T23:10:42Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tCycle\tCycle\t4000\t4001\t2009-02-21T23:10:42Z\tUser\twikitext\t0\t1\t0",
    };
    const index_text = try std.mem.join(pa, "\n", &source_rows);
    const index_path = try std.fs.path.join(pa, &.{ root, "page-index.tsv" });
    const titles_path = try std.fs.path.join(pa, &.{ root, dump_source.page_title_index_filename });
    const dump_path = try std.fs.path.join(pa, &.{ root, "pages.xml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = "#REDIRECT[[Main Page]]" });
    try dump_source.buildPageTitleIndex(io, a, index_path, titles_path);
    const title_bytes = try std.Io.Dir.cwd().readFileAlloc(io, titles_path, pa, .limited(4096));
    var redirects = try encoder.page_redirects.Snapshot.init(a, "# wikidict-page-redirects-v1\n# wiki\taawiktionary\n# dump-date\t20261001\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n" ++
        "941\t0\t4d61696e5f50616765\t\t\n3000\t0\t6d61696e5f50616765\t\t\n4000\t0\t4379636c65\t\t\n# end\t3\n", &namespaces);
    defer redirects.deinit();
    var pool: ExpansionPool = .{ .io = io, .allocator = a, .completion = undefined, .slots = &.{}, .page_index_bytes = index_text, .page_title_index = try dump_source.PageTitleIndex.init(title_bytes), .page_redirects = &redirects, .site_mainpage = site };
    for (source_rows, 0..) |row, i| {
        const page = try dump_source.parsePageIndexLine(.raw_xml, row);
        try std.testing.expectEqual(i == 0 or i == 1 or i == 3, try isSiteMetadata(&pool, pa, page));
    }
    // Captured official title can redirect to the actual landing page (Abkhaz).
    pool.site_mainpage = .{ .title = "Chain", .digest = site.digest };
    try std.testing.expect(try isSiteMetadata(&pool, pa, try dump_source.parsePageIndexLine(.raw_xml, source_rows[0])));
    try std.testing.expect(try isSiteMetadata(&pool, pa, try dump_source.parsePageIndexLine(.raw_xml, source_rows[1])));
    const canonical = try dump_source.parsePageIndexLine(.raw_xml, source_rows[0]);
    pool.site_mainpage = null;
    try std.testing.expect(!try isSiteMetadata(&pool, pa, canonical));
    pool.site_mainpage = site;
    const out = try std.fs.path.join(pa, &.{ root, "dictionary" });
    var writer = try encoder.blob_builder.Writer.init(io, a, out);
    defer writer.deinit();
    var dump = try dump_source.SourceReader.open(io, a, a, dump_path, .raw_xml, null);
    defer dump.deinit();
    // No worker exists: either erroneous lexical dispatch would fail this fixture.
    for (source_rows[0..2], 0..) |row, i| {
        writer.stats.pages_seen += 1;
        try dispatchIndexedPage(&pool, &writer, &dump, .raw_xml, &namespaces, row, i);
    }
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 2), stats.main_pages);
    try std.testing.expectEqual(@as(usize, 0), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 0), stats.alias_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    try std.testing.expectEqual(@as(u64, 2), writer.namespace_coverage.rows.get(0).?.site_metadata_rows);
}

test "site mainpage authority rejects wrong registry wiki and missing captured identity" {
    const a = std.testing.allocator;
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\taawiktionary\n# dump-date\t20261001\n# content-language\taa\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    const hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const cases = [_]struct { wiki: []const u8, digest: []const u8, title: []const u8 }{
        .{ .wiki = "otherwiktionary", .digest = &hash, .title = "Main Page" },
        .{ .wiki = "aawiktionary", .digest = "0000000000000000000000000000000000000000000000000000000000000000", .title = "Main Page" },
        .{ .wiki = "aawiktionary", .digest = &hash, .title = "" },
        .{ .wiki = "aawiktionary", .digest = &hash, .title = "Main Page#Section" },
    };
    for (cases) |case| {
        const bytes = try std.json.Stringify.valueAlloc(a, .{
            .schema = "wikidict.site-info.v2",
            .wiki = case.wiki,
            .date = "20261001",
            .content_language = "aa",
            .namespace_registry_sha256 = case.digest,
            .query = .{ .general = .{ .wikiid = case.wiki, .mainpage = case.title } },
        }, .{});
        defer a.free(bytes);
        try std.testing.expectError(error.InvalidSiteMainPage, parseSiteMainPage(a, bytes, &namespaces));
    }
}

test "valid project namespace mainpage capture does not invalidate ordinary routing" {
    const a = std.testing.allocator;
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    const hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .schema = "wikidict.site-info.v2",
        .wiki = "enwiktionary",
        .date = "20261001",
        .content_language = "en",
        .namespace_registry_sha256 = @as([]const u8, &hash),
        .query = .{ .general = .{ .wikiid = "enwiktionary", .mainpage = "Wiktionary:Main Page" } },
    }, .{});
    defer a.free(bytes);
    const site = try parseSiteMainPage(a, bytes, &namespaces);
    defer a.free(site.title);
    try std.testing.expectEqualStrings("Wiktionary:Main Page", site.title);
    try std.testing.expectEqual(@as(i32, 4), namespaces.ofTitle(site.title).id);
    try std.testing.expect(compiledKind(namespaces.byId(4).?) == null);
    const page = try dump_source.parsePageIndexLine(.raw_xml, "0\t0\tWiktionary:Main Page\t\t1\t2\t2026-10-01T00:00:00Z\tUser\twikitext\t4\t1\t0");
    const pool: ExpansionPool = .{ .io = std.testing.io, .allocator = a, .completion = undefined, .slots = &.{}, .site_mainpage = site };
    const terminal = (try siteTerminalPage(&pool, a, page)) orelse return error.ExpectedProjectHomepage;
    try std.testing.expectEqual(@as(u32, 4), terminal.ns);
    try std.testing.expectEqual(page.page_id, terminal.page_id);
    try std.testing.expect(!try isSiteMetadata(&pool, a, page));
}

test "official project homepage identifies only its SQL-bound main-namespace aliases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const pa = arena.allocator();
    const root = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n# content-language\ttest\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    const registry_hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const site_bytes = try std.json.Stringify.valueAlloc(pa, .{
        .schema = "wikidict.site-info.v2", .wiki = namespaces.wiki, .date = namespaces.dump_date,
        .content_language = namespaces.content_language, .namespace_registry_sha256 = @as([]const u8, &registry_hash),
        .query = .{ .general = .{ .wikiid = namespaces.wiki, .mainpage = "Wiktionary:Home" } },
    }, .{});
    const site = try parseSiteMainPage(pa, site_bytes, &namespaces);
    const control_source = "#REDIRECT[[Wiktionary:Other]]";
    const source_rows = [_][]const u8{
        "0\t0\tWiktionary:Home\t\t1\t101\t2026-10-01T00:00:00Z\tUser\twikitext\t4\t1\t0",
        "0\t0\tHome alias\tWiktionary:Home\t2\t102\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tHome chain\tHome alias\t3\t103\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0",
        try std.fmt.allocPrint(pa, "0\t{d}\tLexical alias\tWiktionary:Other\t4\t104\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0", .{control_source.len}),
        "0\t0\tWiktionary:Other\t\t5\t105\t2026-10-01T00:00:00Z\tUser\twikitext\t4\t1\t0",
        "0\t0\tCycle\tCycle\t6\t106\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tRemote home\tw:Wiktionary:Home\t7\t107\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0",
        "0\t0\tUnavailable\t\t8\t108\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t0\t0",
    };
    const index_text = try std.mem.join(pa, "\n", &source_rows);
    const index_path = try std.fs.path.join(pa, &.{ root, "page-index.tsv" });
    const titles_path = try std.fs.path.join(pa, &.{ root, dump_source.page_title_index_filename });
    const dump_path = try std.fs.path.join(pa, &.{ root, "pages.xml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index_text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = control_source });
    try dump_source.buildPageTitleIndex(io, a, index_path, titles_path);
    const title_bytes = try std.Io.Dir.cwd().readFileAlloc(io, titles_path, pa, .limited(4096));
    var redirects = try encoder.page_redirects.Snapshot.init(a, "# wikidict-page-redirects-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n" ++
        "2\t4\t486f6d65\t\t\n3\t0\t486f6d655f616c696173\t\t\n4\t4\t4f74686572\t\t\n6\t0\t4379636c65\t\t\n7\t4\t486f6d65\t77\t\n# end\t5\n", &namespaces);
    defer redirects.deinit();
    var pool: ExpansionPool = .{ .io = io, .allocator = a, .completion = undefined, .slots = &.{}, .page_index_bytes = index_text, .page_title_index = try dump_source.PageTitleIndex.init(title_bytes), .page_redirects = &redirects, .site_mainpage = site };
    for (source_rows, 0..) |line, i| {
        const page = try dump_source.parsePageIndexLine(.raw_xml, line);
        try std.testing.expectEqual(i == 1 or i == 2, try isSiteMetadata(&pool, pa, page));
    }
    // An indexed target namespace mismatch must not satisfy SQL authority.
    var mismatch_rows = source_rows;
    mismatch_rows[0] = "0\t0\tWiktionary:Home\t\t1\t101\t2026-10-01T00:00:00Z\tUser\twikitext\t0\t1\t0";
    pool.page_index_bytes = try std.mem.join(pa, "\n", &mismatch_rows);
    try std.testing.expect(!try isSiteMetadata(&pool, pa, try dump_source.parsePageIndexLine(.raw_xml, source_rows[1])));
    // Source-unavailable official terminals cannot authorize alias exclusion.
    mismatch_rows[0] = "0\t0\tWiktionary:Home\t\t1\t101\t2026-10-01T00:00:00Z\tUser\twikitext\t4\t0\t0";
    pool.page_index_bytes = try std.mem.join(pa, "\n", &mismatch_rows);
    try std.testing.expect(!try isSiteMetadata(&pool, pa, try dump_source.parsePageIndexLine(.raw_xml, source_rows[1])));
    pool.page_index_bytes = index_text;
    // Official captured home may itself name a main-namespace redirect chain.
    pool.site_mainpage = .{ .title = "Home chain", .digest = site.digest };
    try std.testing.expect(try isSiteMetadata(&pool, pa, try dump_source.parsePageIndexLine(.raw_xml, source_rows[1])));
    pool.site_mainpage = site;
    const out = try std.fs.path.join(pa, &.{ root, "dictionary" });
    var writer = try encoder.blob_builder.Writer.init(io, a, out);
    defer writer.deinit();
    var dump = try dump_source.SourceReader.open(io, a, a, dump_path, .raw_xml, null);
    defer dump.deinit();
    // Direct project input remains compile-only. The unrelated cross-namespace
    // lexical alias follows ordinary alias dispatch and retains its target.
    for (source_rows[0..4], 0..) |line, i| {
        writer.stats.pages_seen += 1;
        try dispatchIndexedPage(&pool, &writer, &dump, .raw_xml, &namespaces, line, i);
    }
    const stats = try writer.finish(.{});
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.alias_records);
    const main_counts = writer.namespace_coverage.rows.get(0).?;
    try std.testing.expectEqual(@as(u64, 3), main_counts.input_rows);
    try std.testing.expectEqual(@as(u64, 2), main_counts.site_metadata_rows);
    try std.testing.expectEqual(@as(u64, 1), main_counts.dispatched_rows);
    try std.testing.expectEqual(@as(u64, 1), main_counts.alias_pages);
    try std.testing.expectEqual(@as(u64, 1), writer.namespace_coverage.rows.get(4).?.compile_only_rows);
}

test "reviewed exact local heading owns the captured Amharic language entry without global ISO trust" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tamwiktionary\n# dump-date\t20261001\n# content-language\tam\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tአብነት\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tመደብ\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    // Exact saved source page4837. The reviewed directive is explicit local
    // policy backed by its language definition and category; no category inference runs here.
    const source = "==Nǁng==\n===መንበብ===\n*[[IPA]]: [ᵑǁŋ]\n===ስም===\n#[[መሰል]] የ[[ደቡብ አፍሪካ]] [[ቋንቋ]]\n===ተመሳሳይ===\n*<small>(''[[casual]]'')</small> [[Nǀuu]]\n*[[Nǁŋ-ǂe]] (Nǁng people)\n[[መደብ:Nǁng]][[መደብ:Nǁng ስም]]";
    for ([_]bool{ false, true }) |reviewed| {
        var registry = language_registry.Registry.empty(a);
        defer registry.deinit();
        try registry.addTsv("# content-language\tam\n# mediawiki\nam\tአማርኛ\n# iso-639-3\nngh\tNǁng\tNǀuu\nen\tEnglish\n");
        if (reviewed) try registry.addTsv("# local-heading\tngh\tNǁng\n");
        try std.testing.expect(registry.resolveTrusted("English") == null);
        try std.testing.expect(registry.resolveTrusted("Nǀuu") == null);
        const codes = languageCodes(&registry, &namespaces);
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, if (reviewed) "reviewed" else "ordinary" });
        var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
        defer writer.deinit();
        writer.language_codes = codes;
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Nǁng", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        try std.testing.expectEqual(@as(usize, if (reviewed) 0 else 1), stats.fallback_pages);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(if (reviewed) "Nǁng" else "Unclassified", &filename) });
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(if (reviewed) "ngh" else "", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("Nǁng")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (reviewed) "ngh" else "", decoded.entry.language_code);
        var definitions: usize = 0;
        var language_links: usize = 0;
        var country_links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) definitions += 1;
            for (block.spans) |span| {
                if (span.kind != .link) continue;
                if (std.mem.eql(u8, span.target, "ቋንቋ")) language_links += 1;
                if (std.mem.eql(u8, span.target, "ደቡብ አፍሪካ")) country_links += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), language_links);
        try std.testing.expectEqual(@as(usize, 1), country_links);
    }
}

test "AF parameterized Etruscan declaration keeps actual record with uncaptured local heading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    // Captured rows: Etruskies deliberately absent, adj present as Adioukrou.
    try registry.addTsv("# wikidict-language-registry-v2\n# content-language\taf\naf\tAfrikaans\taf\nett\tEtruscan\tett\nadj\tAdioukrou\tadj\nen\tEnglish\ten\n");
    const codes = languageCodes(&registry, null);
    const title = "𐌄𐌕𐌉𐌈𐌋𐌄𐌅";
    // Original170B sourceSHA2e5b5faa7125fb036ff2d39d2cb9d5d8a11f676baefad96751c8f729dab071c7.
    const body = "'''velθite''', wisselvorm van '''𐌉𐌕𐌄𐌈𐌋𐌄𐌅''' (velθeti), lokatief enkelvoud van  ☞ [[𐌀𐌈𐌋𐌄𐌅]].";
    const original = "{{=ett=|𐌅𐌄𐌋𐌈𐌉𐌕𐌄}}\n" ++ body;
    const nested = "{{=ett=|{{sort|en}}|display=[[English]]}}\n" ++ body;
    const expanded = "==[[Etruskies|Etruskies (ett)]]==\n" ++ body;
    inline for (.{ original, nested }) |raw| {
        const suffix = if (std.mem.eql(u8, raw, original)) "original" else "nested";
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
        var writer = try encoder.blob_builder.Writer.init(io, a, root);
        defer writer.deinit();
        writer.language_codes = codes;
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, title, expanded, raw, null);
        try std.testing.expectEqual(@as(usize, 1), (try writer.finish(codes)).language_records);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename("Etruscan", &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings("ett", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)).?;
        const page = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("ett", page.entry.language_code);
        var text: std.ArrayList(u8) = .empty;
        var link_found = false;
        for (page.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try text.appendSlice(a, span.text);
            if (std.mem.eql(u8, span.target, "𐌀𐌈𐌋𐌄𐌅")) link_found = true;
        };
        try std.testing.expect(std.mem.indexOf(u8, text.items, "velθite") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "lokatief enkelvoud") != null);
        try std.testing.expect(link_found);
    }
}

// Actual captured AN language declaration bytes, with clearly synthetic lexical
// bodies. No frozen full-page expansion or post-repair production acceptance is claimed.
const AnScopedBannerRegression = struct {
    const Fixture = struct { code: []const u8, raw: []const u8, expanded: []const u8 };
    const registry_source = "# content-language\tan\n# mediawiki\nan\taragonés\tAragonés\tan\nit\titaliano\tItaliano\tit\nscn\tsiciliano\tSiciliano\tSicilianu\tscn\npl\tpolaco\tPolaco\tPolski\tpl\nbe\tbielorruso\tBielorruso\tБеларуская\tbe\neu\teuskera\tEuskera\tEuskara\teu\nfi\tfinés\tFinés\tSuomi\tfi\nms\tmalayo\tMalayo\tBahasa Melayu\tms\n# iso-639-3\nmbp\tMalayo\tmbp\nnci\tClassical Nahuatl\tnci\nnah\tNāhuatl\tnah\nmul\tMultiple languages\tmul\nadj\tAdioukrou\tadj\n";
    const reviewed_aliases = "# local-alias\tit\tItalián\n# local-alias\tscn\tSecilián\n# local-alias\tscn\tsecilián\n# local-alias\tpl\tPolonés\n# local-alias\tbe\tBelarruso\n# local-alias\teu\tVasco\n# local-alias\tfi\tFinlandés\n# local-alias\tfi\tSuomen kieli\n# local-alias\tnci\tNáhuatl clásico\n# local-alias\tnci\tNahuatlahtolli\n# local-alias\tmul\tInternacional\n# local-alias\tmul\tinternacional\n# local-alias\tms\tBahasa Melayu بهاس ملايو\n";
    const namespace_source = "# wikidict-namespace-registry-v1\n# wiki\tanwiktionary\n# dump-date\t20261001\n# content-language\tan\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const fixtures = [_]Fixture{
        .{ .code = "it", .raw = "{{-it-}}\n# [[retained-it|Owner body it]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Italy.svg|40px]] '''''[[Wiktionary:Italián|Italián]]''''' <small>- ''Italiano''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en italiano]]\n==Sustantivo==\n# [[retained-it|Owner body it]]\n" },
        .{ .code = "scn", .raw = "{{-scn-}}\n# [[retained-scn|Owner body scn]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of Sicily.svg|40px]] '''''[[secilián|Secilián]]''''' <small>- ''Sicilianu''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en seziliano]]\n==Sustantivo==\n# [[retained-scn|Owner body scn]]\n" },
        .{ .code = "pl", .raw = "{{-pl-}}\n# [[retained-pl|Owner body pl]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Poland.svg|40px]] '''''[[Wiktionary:Polonés|Polonés]]''''' <small>- ''Polski''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en polonés]]\n==Sustantivo==\n# [[retained-pl|Owner body pl]]\n" },
        .{ .code = "be", .raw = "{{-be-}}\n# [[retained-be|Owner body be]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Belarus.svg|40px]] '''''[[Wiktionary:Belarruso|Belarruso]]''''' <small>- ''Беларуская''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en belarruso]]\n==Sustantivo==\n# [[retained-be|Owner body be]]\n" },
        .{ .code = "eu", .raw = "{{-eu-}}\n# [[retained-eu|Owner body eu]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the_Basque_Country.svg|40px]] '''''[[Wiktionary:Vasco|Vasco]]''''' <small>- ''Euskara''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en basco]]\n==Sustantivo==\n# [[retained-eu|Owner body eu]]\n" },
        .{ .code = "fi", .raw = "{{-fi-}}\n# [[retained-fi|Owner body fi]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Finland.svg|40px]] '''''[[Wiktionary:Finlandés|Finlandés]]''''' <small>- ''Suomen kieli''</small></div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en finlandés]]\n==Sustantivo==\n# [[retained-fi|Owner body fi]]\n" },
        .{ .code = "nci", .raw = "{{-nci-}}\n# [[retained-nci|Owner body nci]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of the Nahuas.svg|40px]] '''''[[Wiktionary:Nāhuatl|Náhuatl clásico]]''''' <small>- ''Nahuatlahtolli''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en náhuatl clásico]]\n==Sustantivo==\n# [[retained-nci|Owner body nci]]\n" },
        .{ .code = "mul", .raw = "{{-mul-}}\n# [[retained-mul|Owner body mul]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the United Nations.svg|40px]] '''''[[internacional|Internacional]]''''' </div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras internacionales]]\n==Sustantivo==\n# [[retained-mul|Owner body mul]]\n" },
        .{ .code = "ms", .raw = "{{-ms-}}\n# [[retained-ms|Owner body ms]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en malayo]]\n==Sustantivo==\n# [[retained-ms|Owner body ms]]\n" },
    };

    fn registry(a: std.mem.Allocator, reviewed: bool) !language_registry.Registry {
        var value = language_registry.Registry.empty(a);
        errdefer value.deinit();
        try value.addTsv(registry_source);
        if (reviewed) try value.addTsv(reviewed_aliases);
        return value;
    }

    fn assertRecord(a: std.mem.Allocator, root: []const u8, heading: []const u8, title: []const u8, code: []const u8, body: []const u8) !void {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(heading, &filename) });
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(code, decoded.entry.language_code);
        var found = false;
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, body)) found = true;
        };
        try std.testing.expect(found);
    }
};

test "AN captured aliases and raw ms banner preserve all nine owners through real Registry Writer DPR2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const F = AnScopedBannerRegression;
    var namespaces = try namespace_registry.Registry.init(a, F.namespace_source);
    defer namespaces.deinit();
    for ([_]bool{ false, true }) |reviewed| {
        var registry = try F.registry(a, reviewed);
        defer registry.deinit();
        // These exact globally conflicting/broader labels must never be reassigned.
        try std.testing.expectEqualStrings("mbp", registry.resolve("Malayo").?.code);
        try std.testing.expect(registry.resolveTrusted("Malayo") == null);
        try std.testing.expectEqualStrings("nah", registry.resolve("Nāhuatl").?.code);
        try std.testing.expect(registry.resolveTrusted("Adioukrou") == null);
        const codes = languageCodes(&registry, &namespaces);
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, if (reviewed) "reviewed" else "unreviewed" });
        var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
        defer writer.deinit();
        writer.language_codes = codes;
        for (F.fixtures) |fixture| {
            const title = try std.fmt.allocPrint(a, "fixture-{s}", .{fixture.code});
            try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, title, fixture.expanded, fixture.raw, null);
        }
        // Existing generic linked-language evidence also permits this ordinary
        // suffixless Italian banner. With reviewed identical target/label, the
        // complete AN declaration grammar now also corroborates that same owner.
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ordinary-suffixless-it", "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_Italy.svg|40px]] '''''[[Wiktionary:Italián|Italián]]'''''</div>=\n__NOTOC__\n__NOEDITSECTION__\n\n[[Category:Parabras en italiano]]\n# [[ordinary-it|Independent linked Italian body]]\n", "{{-it-}}\n# [[ordinary-it|Independent linked Italian body]]\n", null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, F.fixtures.len + 1), stats.language_records);
        // Complete ms/mul banners independently corroborate their raw codes;
        // the other seven fixtures and suffixless Italian still need aliases.
        try std.testing.expectEqual(@as(usize, if (reviewed) F.fixtures.len else 3), stats.language_blobs);
        try std.testing.expectEqual(@as(usize, if (reviewed) 0 else F.fixtures.len - 1), stats.fallback_pages);
        for (F.fixtures) |fixture| {
            const title = try std.fmt.allocPrint(a, "fixture-{s}", .{fixture.code});
            const body = try std.fmt.allocPrint(a, "retained-{s}", .{fixture.code});
            const corroborated = std.mem.eql(u8, fixture.code, "ms") or std.mem.eql(u8, fixture.code, "mul");
            const retained_owner = reviewed or corroborated;
            const heading = if (retained_owner) registry.resolve(fixture.code).?.heading else "Unclassified";
            try F.assertRecord(a, root, heading, title, if (retained_owner) fixture.code else "", body);
        }
        try F.assertRecord(a, root, if (reviewed) registry.resolve("it").?.heading else "Unclassified", "ordinary-suffixless-it", if (reviewed) "it" else "", "ordinary-it");
        try std.testing.expectEqualStrings("mbp", registry.resolve("Malayo").?.code);
        try std.testing.expect(registry.resolveTrusted("Malayo") == null);
        try std.testing.expectEqualStrings("nah", registry.resolve("Nāhuatl").?.code);
    }
}

test "AN scoped banner preserves canonical mbp evidence and refuses unsupported conflicting declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const F = AnScopedBannerRegression;
    var namespaces = try namespace_registry.Registry.init(a, F.namespace_source);
    defer namespaces.deinit();
    var registry = try F.registry(a, true);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/rejected", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const negatives = [_]struct { title: []const u8, raw: []const u8, expanded: []const u8, expected_code: []const u8 = "" }{
        .{ .title = "canonical-mbp-raw-code", .expected_code = "mbp", .raw = "{{-mbp-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en malayo]]\n# [[negative-body|Retained negative body]]\n" },
        .{ .title = "pos-code", .raw = "{{-adj-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en malayo]]\n# [[negative-body|Retained negative body]]\n" },
        .{ .title = "wrong-ms-suffix", .raw = "{{-ms-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Malayo|Malayo]]''''' <small>- ''English''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en malayo]]\n# [[negative-body|Retained negative body]]\n" },
        .{ .title = "wrong-ms-label", .raw = "{{-ms-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" > [[Image:Flag of Malaysia.svg|40px]] '''''[[Wiktionary:Polonés|Polonés]]''''' <small>- ''Bahasa Melayu بهاس ملايو''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en malayo]]\n# [[negative-body|Retained negative body]]\n" },
        .{ .title = "wrong-nci-code", .raw = "{{-nah-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag of the Nahuas.svg|40px]] '''''[[Wiktionary:Nāhuatl|Náhuatl clásico]]''''' <small>- ''Nahuatlahtolli''</small></div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras en náhuatl clásico]]\n# [[negative-body|Retained negative body]]\n" },
        .{ .title = "mismatched-mul-target", .raw = "{{-mul-}}\n# [[negative-body|Retained negative body]]\n", .expanded = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_the United Nations.svg|40px]] '''''[[Italián|Internacional]]''''' </div>=__NOTOC__ __NOEDITSECTION__\n\n[[Category:Parabras internacionales]]\n# [[negative-body|Retained negative body]]\n" },
    };
    for (negatives) |fixture| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, fixture.title, fixture.expanded, fixture.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, negatives.len), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, negatives.len - 1), stats.fallback_pages);
    // Canonical Malayo is mbp, not an ambiguous ms alias. Its explicit raw
    // -mbp- and linked rendered Malayo agree under the existing generic path;
    // the contradictory suffix does not grant the AN-specific ms exception.
    for (negatives) |fixture| {
        const canonical_mbp = std.mem.eql(u8, fixture.expected_code, "mbp");
        const heading = if (canonical_mbp) registry.resolve("mbp").?.heading else "Unclassified";
        try F.assertRecord(a, root, heading, fixture.title, fixture.expected_code, "negative-body");
        const other_heading = if (canonical_mbp) "Unclassified" else registry.resolve("mbp").?.heading;
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const other_path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(other_heading, &filename) });
        var mapped = try mmapPath(std.testing.io, other_path);
        defer mapped.deinit();
        const other_blob = try encoder.blob_format.inspect(mapped.bytes);
        var other_index = try other_blob.buildTrustedIndexAlloc(a);
        defer other_index.deinit(a);
        try std.testing.expect((try other_index.find(fixture.title)) == null);
    }
    try std.testing.expectEqualStrings("mbp", registry.resolve("Malayo").?.code);
    try std.testing.expect(registry.resolveTrusted("Malayo") == null);
    try std.testing.expectEqualStrings("nah", registry.resolve("Nāhuatl").?.code);
}

test "AN Malay corroboration is edition scoped and preserves ordinary generic linked owner evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const F = AnScopedBannerRegression;
    const foreign = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n6\tImage\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tmedia\n10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    var namespaces = try namespace_registry.Registry.init(a, foreign);
    defer namespaces.deinit();
    var registry = try F.registry(a, true);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/foreign", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Reviewed nci/mul labels remain ordinary generic evidence in any edition;
    // only ambiguous Malay needs the new AN-specific corroboration.
    for (F.fixtures[6..9]) |fixture| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, fixture.code, fixture.expanded, fixture.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 3), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    for (F.fixtures[6..9]) |fixture| {
        const body = try std.fmt.allocPrint(a, "retained-{s}", .{fixture.code});
        const ordinary = !std.mem.eql(u8, fixture.code, "ms");
        try F.assertRecord(a, root, if (ordinary) registry.resolve(fixture.code).?.heading else "Unclassified", fixture.code, if (ordinary) fixture.code else "", body);
    }
}

test "AN authored direct Catalan banner and French Franzes alias keep separate Writer owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const F = AnScopedBannerRegression;
    var namespaces = try namespace_registry.Registry.init(a, F.namespace_source);
    defer namespaces.deinit();
    var registry = try F.registry(a, true);
    defer registry.deinit();
    try registry.addTsv("ca\tcatalán\tCatalán\tCatalà\tcatalà\tca\tCatalan\tcat\nfr\tfrancés\tFrancés\tFrançais\tfrançais\tfr\tFrench\tfra\tfre\n");
    try std.testing.expect(registry.resolve("Franzés") == null);
    try registry.addTsv("# local-alias\tfr\tFranzés\n");
    try std.testing.expectEqualStrings("fr", registry.resolve("Franzés").?.code);
    try std.testing.expectEqualStrings("mbp", registry.resolve("Malayo").?.code);
    try std.testing.expect(registry.resolveTrusted("Malayo") == null);
    try std.testing.expectEqualStrings("nah", registry.resolve("Nāhuatl").?.code);
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/direct", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    // Exact source banner from escoltar2904/rev29039; original authored body
    // links retained as a compact source excerpt, no -ca- marker invented.
    const catalan = "=<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Catalán|Catalán]]'''''</div>=\n*[[ascuitar|Ascuitar]]\n*[[ascuitar|Ascuitar]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "escoltar", catalan, catalan, null);
    // Captured -fr- and ordinary -an- declaration bytes, synthetic body actions
    // explicitly separate. This is not an actual frozen mai expansion claim.
    const french = "=<div id=\"toc\" class=\"toccolours\" >[[Image:Flag_of_France.svg|40px]] '''''[[Wiktionary:Franzés|Francés]]''''' <small>- ''Français''</small></div>=\n# [[french-only|French body]]\n";
    const aragonese = "=<div id=\"toc\" class=\"toccolours\" >'''''[[Wiktionary:Aragonés|Aragonés]]''''' <small>- ''Aragonés''</small></div>=\n# [[aragonese-only|Aragonese body]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed-fr", aragonese ++ french, "{{-an-}}\n# [[aragonese-only|Aragonese body]]\n{{-fr-}}\n# [[french-only|French body]]\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 3), stats.language_records);
    try std.testing.expectEqual(@as(usize, 3), stats.language_blobs);
    try F.assertRecord(a, root, registry.resolve("ca").?.heading, "escoltar", "ca", "ascuitar");
    try F.assertRecord(a, root, registry.resolve("fr").?.heading, "mixed-fr", "fr", "french-only");
    try F.assertRecord(a, root, registry.resolve("an").?.heading, "mixed-fr", "an", "aragonese-only");
    for ([_][]const u8{ "fr", "an" }) |code| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(registry.resolve(code).?.heading, &filename) });
        var mapped = try mmapPath(std.testing.io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("mixed-fr")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        const forbidden = if (std.mem.eql(u8, code, "fr")) "aragonese-only" else "french-only";
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            try std.testing.expect(!std.mem.eql(u8, span.target, forbidden));
        };
    }
}

test "selected interwiki metadata survives real Registry Writer and DPR2 alongside Newton math" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tafwiktionary\n# dump-date\t20261001\n# content-language\taf\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tSjabloon\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tKategorie\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n");
    defer namespaces.deinit();
    try namespaces.attachInterwikiMap("w\t1\t0\t0\t0\thttps://af.wikipedia.org/wiki/$1\nen\t1\t0\t0\t0\thttps://en.wiktionary.org/wiki/$1\nnl\t1\t0\t0\t0\thttps://nl.wiktionary.org/wiki/$1\n");
    var registry = language_registry.Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv("af\tAfrikaans\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/interwiki", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(std.testing.io, a, root);
    defer writer.deinit();
    writer.language_codes = codes;
    const raw = "{{=af=}}\n[[w:Isaac Newton]] [[w:Newton (eenheid)|Wikipedia]] [[en:newton|(en)]] [[nl:newton|(nl)]] <math>1\\, \\mathrm{N}=1\\, \\mathrm{kg} \\cdot \\mathrm{m} / \\mathrm{s}^{2}</math> [[N]]";
    const expanded = "==Afrikaans==\n[[w:Isaac Newton]] [[w:Newton (eenheid)|Wikipedia]] [[en:newton|(en)]] [[nl:newton|(nl)]] <math>1\\, \\mathrm{N}=1\\, \\mathrm{kg} \\cdot \\mathrm{m} / \\mathrm{s}^{2}</math> [[N]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "newton", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_pages);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename("Afrikaans", &filename) });
    var mapped = try mmapPath(std.testing.io, path);
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("newton")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    var targets: std.ArrayList([]const u8) = .empty;
    var visible: std.ArrayList(u8) = .empty;
    var superscript_two: usize = 0;
    var local_n: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        try visible.appendSlice(a, span.text);
        if (span.kind == .external_link) try targets.append(a, span.target);
        if (span.kind == .link and std.mem.eql(u8, span.target, "N")) {
            local_n += 1;
            try std.testing.expect(!span.superscript and !span.italic);
        }
        if (span.superscript and std.mem.eql(u8, span.text, "2")) superscript_two += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), targets.items.len);
    inline for (.{ "https://af.wikipedia.org/wiki/Isaac_Newton", "https://af.wikipedia.org/wiki/Newton_(eenheid)", "https://en.wiktionary.org/wiki/newton", "https://nl.wiktionary.org/wiki/newton" }, 0..) |expected, i| try std.testing.expectEqualStrings(expected, targets.items[i]);
    try std.testing.expectEqual(@as(usize, 1), local_n);
    try std.testing.expectEqual(@as(usize, 1), superscript_two);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "\u{2066}1\u{2009}N=1\u{2009}kg·m/s2\u{2069}") != null);
}

test "language code bridge preserves positive ambiguous labels without inventing owners" {
    var registry = language_registry.Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("en\tEnglish\ten\nfr\tFrench\tfr\nfrk\tFrankish\tfrk\n");
    try registry.addLocalNamesLua("local names = { en = \"Nīwenglisc\", fr = \"Frencisc\", frk = \"Frencisc\" } local aliases = {}");
    try registry.addTsv("# local-language-boundary\tMiddelhēahþēodisc\n# local-language-boundary\tNīwenglisc\n");
    const codes = languageCodes(&registry, null);
    try std.testing.expect(codes.isLanguageBoundary("Frencisc"));
    try std.testing.expect(codes.resolve("Frencisc") == null);
    try std.testing.expect(!codes.isLanguageBoundary("Unknown topic"));
    try std.testing.expect(codes.isLanguageBoundary("Nīwenglisc"));
    try std.testing.expect(codes.isLanguageBoundary("Middelhēahþēodisc"));
    try std.testing.expect(codes.resolve("Middelhēahþēodisc") == null);
    try std.testing.expectEqualStrings("en", codes.resolve("Nīwenglisc").?.code);
}

fn auditControlFreshRoot(a: std.mem.Allocator, label: []const u8) ![]const u8 {
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, ".tmp");
    const root = try std.fmt.allocPrint(a, ".tmp/presentation-audit-{s}-{d}", .{ label, std.os.linux.getpid() });
    // Refuse an old root instead of deleting anything this test did not create.
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    return root;
}

fn auditControlNoPublishedFiles(a: std.mem.Allocator, root: []const u8) !void {
    const io = std.testing.io;
    for ([_][]const u8{ encoder.blob_catalog.manifest_filename, "complete.json", "page-coverage.json", "namespace-coverage.json", "aliases.wikblb", "thesaurus.wikblb", "citations.wikblb", "supplemental.wikblb" }) |name| {
        const path = try std.fs.path.join(a, &.{ root, name });
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return error.TestUnexpectedResult else |err| {
            try std.testing.expect(err == error.FileNotFound);
        }
    }
    var languages = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ root, "languages" }), .{ .iterate = true });
    defer languages.close(io);
    var entries = languages.iterate();
    try std.testing.expect(try entries.next(io) == null);
}

fn auditControlLanguages(_: ?*const anyopaque, heading: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, heading, "English")) return "en";
    if (std.mem.eql(u8, heading, "French")) return "fr";
    return null;
}
fn auditControlBoundary(_: ?*const anyopaque, heading: []const u8) bool {
    return std.mem.eql(u8, heading, "English") or std.mem.eql(u8, heading, "French");
}

test "diagnostic seam with nil audit retains real Writer strict guards and provenance errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try auditControlFreshRoot(a, "ordinary");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var writer = try encoder.blob_builder.Writer.init(io, a, root);
    defer writer.deinit();
    const job: ExpansionJob = .{ .ordinal = 1, .ns = .{ .id = 0, .kind = .language }, .title = "Strict fixture", .source = "raw fixture" };
    try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = "[https://example.test broken" }, a, null));
    try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = "before |} after" }, a, null));
    try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = "<nowiki>before |} after</nowiki>" }, a, null));
    try std.testing.expectError(error.InvalidPoemMetadata, consumeExpandedPage(&writer, job, .{ .source = "valid text", .poem_metadata = "{" }, a, null));
    try auditControlNoPublishedFiles(a, root);
    // Deliberately never call Writer.finish: this is not a publishable build.
}

test "failed multi-owner page can touch scratch spools but never becomes a publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try auditControlFreshRoot(a, "partial-owner");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        var writer = try encoder.blob_builder.Writer.init(io, a, root);
        defer writer.deinit();
        writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
        const source = "==English==\n# first owner is valid\n==French==\n# [https://example.test broken\n";
        const job: ExpansionJob = .{ .ordinal = 2, .ns = .{ .id = 0, .kind = .language }, .title = "Partial owners", .source = source };
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = source }, a, null));
        try std.testing.expect(writer.stats.language_records > 0);
        const later: ExpansionJob = .{ .ordinal = 3, .ns = .{ .id = 0, .kind = .language }, .title = "Later valid", .source = "==English==\n# later valid" };
        try std.testing.expect(try consumeExpandedPage(&writer, later, .{ .source = later.source }, a, null));
        try auditControlNoPublishedFiles(a, root);
    }
    try auditControlNoPublishedFiles(a, root);
    if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ root, ".spool" }), .{})) |_| return error.TestUnexpectedResult else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
}

test "audit leaves operational expansion classification unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]anyerror{ error.OutOfMemory, error.Timeout, error.ExpansionWorkerDied, error.InvalidPoemMetadata, error.PageIndexChanged }) |err| {
        try std.testing.expect(try expansionFallbackReasonAlloc(a, err, null) == null);
    }
    try std.testing.expect(try expansionFallbackReasonAlloc(a, error.ExpansionFailed, .{ .stage = "expand", .error_name = "Timeout", .detail = "deadline" }) == null);
    // A real semantic expansion error retains the preexisting positive classifier.
    try std.testing.expect(try expansionFallbackReasonAlloc(a, error.ExpansionFailed, .{ .stage = "expand", .error_name = "ExampleLuaError", .detail = "semantic fixture" }) != null);
}

const AuditControlInputs = struct {
    root: []const u8,
    audit_root: []const u8,
    writer_root: []const u8,
    context: AuditInputContext,
};

fn auditControlInputs(a: std.mem.Allocator, label: []const u8, cap: usize) !AuditControlInputs {
    const io = std.testing.io;
    const root = try auditControlFreshRoot(a, label);
    errdefer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const dump = try std.fs.path.join(a, &.{ root, "input.xml" });
    const tool = try std.fs.path.join(a, &.{ root, "tool-identity" });
    const inputs = try std.fs.path.join(a, &.{ root, "retained-inputs" });
    try std.Io.Dir.cwd().createDir(io, inputs, .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dump, .data = "<mediawiki><page><title>fixture</title></page></mediawiki>" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tool, .data = "owned diagnostic unit-control identity; never executed" });
    return .{
        .root = root,
        .audit_root = try std.fs.path.join(a, &.{ root, "audit" }),
        .writer_root = try std.fs.path.join(a, &.{ root, "discarded-writer" }),
        .context = .{ .dump_path = dump, .expander_root = inputs, .tool_path = tool, .expanded_byte_cap = cap },
    };
}

fn auditControlSummary(a: std.mem.Allocator, root: []const u8) !std.json.Value {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(a, &.{ root, "audit-summary.json" }), a, .limited(64 * 1024));
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
}
fn auditControlHash(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn auditControlEmptySpools(writer: *encoder.blob_builder.Writer) !void {
    for (writer.spools.language) |spool| {
        try std.testing.expectEqual(@as(u64, 0), spool.offset);
        try std.testing.expectEqual(@as(u64, 0), (try spool.file.stat(std.testing.io)).size);
    }
    inline for (.{ "thesaurus", "citations", "reconstruction", "rhymes", "sign_gloss", "supplemental", "aliases" }) |field| {
        const spool = @field(writer.spools, field);
        try std.testing.expectEqual(@as(u64, 0), spool.offset);
        try std.testing.expectEqual(@as(u64, 0), (try spool.file.stat(std.testing.io)).size);
    }
    try std.testing.expectEqual(@as(usize, 0), writer.stats.language_records);
    try std.testing.expectEqual(@as(usize, 0), writer.stats.fallback_pages);
}

fn auditControlSequence(a: std.mem.Allocator, label: []const u8, cap: usize) !void {
    const io = std.testing.io;
    const inputs = try auditControlInputs(a, label, cap);
    defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
    var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
    defer audit.deinit();
    const before = try auditControlSummary(a, inputs.audit_root);
    try std.testing.expect(!before.object.get("inventory_complete").?.bool);
    const raw_request = "{{retained caller}}";
    const bad_external = "[https://example.test broken unretained-expanded-A";
    const bad_inline = "==English==\n# valid partial owner\n==French==\n# before |} after unretained-expanded-B\n";
    const pages = [_]struct { title: []const u8, source: []const u8, valid: bool }{
        .{ .title = "valid-before", .source = "==English==\n# valid before [[first]]", .valid = true },
        .{ .title = "bad-external", .source = bad_external, .valid = false },
        .{ .title = "valid-protected-middle", .source = "==English==\n# <nowiki>before |} after</nowiki>", .valid = true },
        .{ .title = "bad-inline-close", .source = bad_inline, .valid = false },
        .{ .title = "valid-after", .source = "==English==\n# valid after [[last]]", .valid = true },
    };
    {
        var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
        defer writer.deinit();
        writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
        for (pages, 1000..) |page, ordinal| {
            const job: ExpansionJob = .{ .ordinal = @intCast(ordinal), .ns = .{ .id = 0, .kind = .language }, .title = page.title, .source = raw_request };
            try std.testing.expectEqual(page.valid, try consumeExpandedPage(&writer, job, .{ .source = page.source }, a, &audit));
            // Includes a failure after English was already appended: diagnostic
            // continuation must discard that partial owner before the next page.
            try auditControlEmptySpools(&writer);
        }
        try std.testing.expectEqual(@as(usize, 5), audit.compile_attempts);
        try std.testing.expectEqual(@as(usize, 3), audit.succeeded);
        try std.testing.expectEqual(@as(usize, 2), audit.failed);
        // Direct helper controls have no worker threads: all five supplied jobs
        // were dispatched and consumed synchronously; no selected row was skipped.
        audit.selected = 5;
        audit.dispatched = 5;
        audit.consumed = 5;
        try audit.finish(true, true);
        try auditControlNoPublishedFiles(a, inputs.writer_root);
    }
    try auditControlNoPublishedFiles(a, inputs.writer_root);
    const summary = try auditControlSummary(a, inputs.audit_root);
    try std.testing.expect(summary.object.get("inventory_complete").?.bool);
    try std.testing.expect(summary.object.get("diagnostic_only").?.bool);
    try std.testing.expect(!summary.object.get("semantic_acceptance").?.bool);
    try std.testing.expect(!summary.object.get("publication_created").?.bool);
    try std.testing.expectEqual(@as(i64, 5), summary.object.get("compile_attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 3), summary.object.get("succeeded").?.integer);
    try std.testing.expectEqual(@as(i64, 2), summary.object.get("failed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), summary.object.get("failure_records").?.integer);
    const lines = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" }), a, .limited(128 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, lines, "unretained-expanded-A") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "unretained-expanded-B") == null);
    var split = std.mem.splitScalar(u8, lines, '\n');
    const titles = [_][]const u8{ "bad-external", "bad-inline-close" };
    const ordinals = [_]i64{ 1001, 1003 };
    const sources = [_][]const u8{ bad_external, bad_inline };
    for (titles, ordinals, sources) |title, ordinal, source| {
        const line = split.next().?;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        try std.testing.expectEqualStrings("wikidict.presentation-audit.failure.v1", value.object.get("schema").?.string);
        try std.testing.expectEqualStrings("UncompiledPresentation", value.object.get("error_name").?.string);
        try std.testing.expectEqualStrings(title, value.object.get("title").?.string);
        try std.testing.expectEqual(ordinal, value.object.get("ordinal").?.integer);
        try std.testing.expectEqual(@as(i64, 0), value.object.get("namespace").?.integer);
        const raw = value.object.get("raw_source").?;
        try std.testing.expectEqualStrings(try auditControlHash(a, raw_request), raw.object.get("sha256").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(raw_request.len)), raw.object.get("bytes").?.integer);
        const expanded = value.object.get("expanded").?;
        try std.testing.expect(expanded.object.get("present").?.bool);
        try std.testing.expectEqualStrings(try auditControlHash(a, source), expanded.object.get("sha256").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(source.len)), expanded.object.get("bytes").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(cap)), expanded.object.get("retained_bytes").?.integer);
        if (cap == 0) {
            try std.testing.expect(expanded.object.get("unretained").?.bool);
            try std.testing.expect(expanded.object.get("path").? == .null);
        } else {
            try std.testing.expect(expanded.object.get("truncated").?.bool);
            try std.testing.expect(!expanded.object.get("unretained").?.bool);
            const retained = try std.Io.Dir.cwd().readFileAlloc(io, expanded.object.get("path").?.string, a, .limited(32));
            try std.testing.expectEqualStrings(source[0..cap], retained);
        }
    }
    try std.testing.expectEqualStrings("", split.next().?);
    try std.testing.expect(split.next() == null);
    // No catalog, coverage or complete artifact exists in the diagnostic root.
    for ([_][]const u8{ encoder.blob_catalog.manifest_filename, "complete.json", "page-coverage.json", "namespace-coverage.json" }) |name| {
        if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ inputs.audit_root, name }), .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expect(err == error.FileNotFound);
    }
}

test "audit collects two real strict failures separated by success and remains nonpublishing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try auditControlSequence(arena.allocator(), "sequence-no-expanded", 0);
    try auditControlSequence(arena.allocator(), "sequence-capped-expanded", 8);
}

test "audit propagates real Writer phase and allocator failures and seals only incomplete inventory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    inline for (.{ "provenance", "allocation" }) |label| {
        const inputs = try auditControlInputs(a, label, 0);
        defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
        var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
        defer audit.deinit();
        var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
        defer writer.deinit();
        const job: ExpansionJob = .{ .ordinal = 7, .ns = .{ .id = 0, .kind = .language }, .title = "Operational control", .source = "valid [[allocation]] source" };
        if (comptime std.mem.eql(u8, label, "provenance")) {
            try std.testing.expectError(error.InvalidPoemMetadata, consumeExpandedPage(&writer, job, .{ .source = job.source, .poem_metadata = "{" }, a, &audit));
            audit.abort(error.InvalidPoemMetadata);
        } else {
            var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            try std.testing.expectError(error.OutOfMemory, consumeExpandedPage(&writer, job, .{ .source = job.source }, failing.allocator(), &audit));
            try std.testing.expect(failing.has_induced_failure);
            audit.abort(error.OutOfMemory);
        }
        try std.testing.expectEqual(@as(usize, 0), audit.failed);
        const summary = try auditControlSummary(a, inputs.audit_root);
        try std.testing.expect(!summary.object.get("inventory_complete").?.bool);
        try std.testing.expect(!summary.object.get("publication_created").?.bool);
        const lines = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" }), a, .limited(1024));
        try std.testing.expectEqual(@as(usize, 0), lines.len);
        try auditControlNoPublishedFiles(a, inputs.writer_root);
    }
}

test "audit requires EOF drained routing and unchanged actual input bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    inline for (.{ "no-eof", "not-drained", "routing-mismatch", "changed-dump", "appeared-input" }) |label| {
        const inputs = try auditControlInputs(a, label, 0);
        defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
        var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
        defer audit.deinit();
        if (comptime std.mem.eql(u8, label, "changed-dump")) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inputs.context.dump_path, .data = "changed retained dump bytes" });
            try std.testing.expectError(error.AuditInputsChanged, audit.finish(true, true));
            audit.abort(error.AuditInputsChanged);
        } else if (comptime std.mem.eql(u8, label, "appeared-input")) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ inputs.context.expander_root, "page-index.tsv" }), .data = "newly appeared retained index" });
            try std.testing.expectError(error.AuditInputsChanged, audit.finish(true, true));
            audit.abort(error.AuditInputsChanged);
        } else {
            if (comptime std.mem.eql(u8, label, "routing-mismatch")) audit.dispatched = 1;
            try std.testing.expectError(error.IncompletePresentationAudit, audit.finish(!std.mem.eql(u8, label, "no-eof"), !std.mem.eql(u8, label, "not-drained")));
            audit.abort(error.IncompletePresentationAudit);
        }
        const summary = try auditControlSummary(a, inputs.audit_root);
        try std.testing.expect(!summary.object.get("inventory_complete").?.bool);
        try std.testing.expect(!summary.object.get("publication_created").?.bool);
    }
}

test "audit refuses a preexisting output root before any ordinary Writer initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const inputs = try auditControlInputs(a, "existing-root", 0);
    defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ inputs.audit_root, "languages" }));
    const sentinel = try std.fs.path.join(a, &.{ inputs.audit_root, "languages", "existing-owned-sentinel" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sentinel, .data = "must survive refusal" });
    if (PresentationAudit.init(io, a, inputs.audit_root, inputs.context)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqualStrings("must survive refusal", try std.Io.Dir.cwd().readFileAlloc(io, sentinel, a, .limited(1024)));
}

test "audit payload exhaustion retains hashes while report exhaustion aborts incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    inline for (.{ "payload-budget", "report-budget" }) |label| {
        const inputs = try auditControlInputs(a, label, 8);
        defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
        var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
        defer audit.deinit();
        var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
        defer writer.deinit();
        const source = "before |} after";
        const job: ExpansionJob = .{ .ordinal = 99, .ns = .{ .id = 0, .kind = .language }, .title = "budget control", .source = source };
        if (comptime std.mem.eql(u8, label, "payload-budget")) {
            // Exercise the boundary without allocating a giant payload.
            audit.payload_bytes = 64 * 1024 * 1024;
            try std.testing.expect(!try consumeExpandedPage(&writer, job, .{ .source = source }, a, &audit));
            try auditControlEmptySpools(&writer);
            audit.selected = 1;
            audit.dispatched = 1;
            audit.consumed = 1;
            try audit.finish(true, true);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" }), a, .limited(64 * 1024));
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.trim(u8, bytes, "\n"), .{});
            inline for (.{ "raw_source", "expanded" }) |field| {
                const capture = value.object.get(field).?;
                try std.testing.expect(capture.object.get("present").?.bool);
                try std.testing.expect(capture.object.get("unretained").?.bool);
                try std.testing.expectEqual(@as(i64, 0), capture.object.get("retained_bytes").?.integer);
                try std.testing.expect(capture.object.get("path").? == .null);
                try std.testing.expectEqualStrings(try auditControlHash(a, source), capture.object.get("sha256").?.string);
            }
        } else {
            audit.report_bytes = 256 * 1024 * 1024;
            try std.testing.expectError(error.AuditReportLimitExceeded, consumeExpandedPage(&writer, job, .{ .source = source }, a, &audit));
            audit.abort(error.AuditReportLimitExceeded);
            try std.testing.expectEqual(@as(usize, 0), audit.failure_records);
            const summary = try auditControlSummary(a, inputs.audit_root);
            try std.testing.expect(!summary.object.get("inventory_complete").?.bool);
            try std.testing.expectEqualStrings("AuditReportLimitExceeded", summary.object.get("error_name").?.string);
        }
        try auditControlNoPublishedFiles(a, inputs.writer_root);
    }
}
