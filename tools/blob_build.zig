const std = @import("std");
const diagnostics = @import("build_diagnostics");
const namespace_registry = @import("namespace_registry");
const encoder = @import("encoder");
const xml_decode = @import("xml_decode");
const dump_source = @import("wikimedia_dump");
const language_registry = @import("language_registry.zig");
const source_language_banner = @import("source_language_banner.zig");
const source_category_language = @import("source_category_language.zig");
const bundle_expander = @import("bundle_expander.zig");
const expansion_deadline = @import("expansion_deadline.zig");
const reviewed_nonlexical = @import("reviewed_nonlexical.zig");
const max_worker_count: usize = 8;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Process CPU would charge concurrent protocol threads to the consumer too.
fn parentThreadCpuNow() ?u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.THREAD_CPUTIME_ID, &ts)) != .SUCCESS) return null;
    const seconds = std.math.cast(u64, ts.sec) orelse return null;
    const nanos = std.math.cast(u64, ts.nsec) orelse return null;
    return std.math.add(u64, std.math.mul(u64, seconds, std.time.ns_per_s) catch return null, nanos) catch null;
}

const ParentProfileStamp = struct {
    cpu_ns: ?u64,
    wall_ns: i128,

    fn now(io: std.Io) ParentProfileStamp {
        return .{ .cpu_ns = parentThreadCpuNow(), .wall_ns = std.Io.Clock.awake.now(io).toNanoseconds() };
    }
};

const ParentPhaseTotals = struct {
    calls: u64 = 0,
    cpu_ns: u64 = 0,
    wall_ns: u64 = 0,
    cpu_clock_misses: u64 = 0,

    fn record(self: *ParentPhaseTotals, started: ParentProfileStamp, stopped: ParentProfileStamp) void {
        self.calls +|= 1;
        self.wall_ns +|= std.math.cast(u64, @max(0, stopped.wall_ns - started.wall_ns)) orelse std.math.maxInt(u64);
        if (started.cpu_ns) |before| {
            if (stopped.cpu_ns) |after| {
                self.cpu_ns +|= after -| before;
                return;
            }
        }
        self.cpu_clock_misses +|= 1;
    }

    fn merge(self: *ParentPhaseTotals, other: ParentPhaseTotals) void {
        self.calls +|= other.calls;
        self.cpu_ns +|= other.cpu_ns;
        self.wall_ns +|= other.wall_ns;
        self.cpu_clock_misses +|= other.cpu_clock_misses;
    }

    fn log(self: ParentPhaseTotals, phase: []const u8) void {
        diagnostics.printLine("parent phase profile: phase={s} calls={d} thread_cpu_ns={d} wall_ns={d} cpu_clock_misses={d} wall_semantics=sum-of-calls\n", .{
            phase, self.calls, self.cpu_ns, self.wall_ns, self.cpu_clock_misses,
        });
    }
};

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

const FirstFailureCaptureContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    input: AuditInputContext,
    requested_now_unix: ?i64,
    invocation_args: []const []const u8,
    invocation_id: ?[]const u8,
    failure_evidence_root: ?[]const u8 = null,
    attempted: bool = false,
    continuous_output_active: bool = false,

    fn fromCli(io: std.Io, a: std.mem.Allocator, args: []const []const u8, options: Options) FirstFailureCaptureContext {
        const evidence_root: ?[]const u8 = if (options.failure_receipt) |path| blk: {
            const parent = std.fs.path.dirname(path) orelse break :blk null;
            const invocation_id = options.invocation_id orelse break :blk null;
            // Match the existing sharded driver's private invocation directory.
            // Other receipt destinations retain the ordinary marker contract.
            break :blk if (std.mem.eql(u8, std.fs.path.basename(parent), invocation_id)) parent else null;
        } else null;
        return .{
            .io = io, .allocator = a, .output_root = args[2],
            .input = .{ .dump_path = args[1], .expander_root = options.expander_root,
                .workers = options.workers, .timeout_ms = options.expansion_timeout_ms orelse expansion_deadline.default_ms,
                .now_unix = 0,
                .start_page = options.start_page, .requested_limit = options.limit_pages,
                .index_byte_offset = options.index_byte_offset },
            .requested_now_unix = options.now_unix,
            .invocation_args = args[1..], .invocation_id = options.invocation_id,
            .failure_evidence_root = evidence_root,
        };
    }
};
var first_failure_capture_context: ?FirstFailureCaptureContext = null;

// Continuous builds own the raw-shard container while this scope is active.
// That container has no .incomplete marker; failed shard directories beneath
// it are removed during unwinding, so diagnostics must stay in the container.
const ContinuousFailureCaptureScope = struct {
    context: ?*FirstFailureCaptureContext = null,
    previous: bool = false,

    fn begin(output_root: []const u8) ContinuousFailureCaptureScope {
        const context = if (first_failure_capture_context) |*value| value else return .{};
        if (!std.mem.eql(u8, context.output_root, output_root)) return .{};
        const previous = context.continuous_output_active;
        context.continuous_output_active = true;
        return .{ .context = context, .previous = previous };
    }

    fn deinit(self: ContinuousFailureCaptureScope) void {
        if (self.context) |context| context.continuous_output_active = self.previous;
    }
};

fn invocationArgumentsHash(a: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (args) |arg| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(arg.len), .little);
        hash.update(&length);
        hash.update(arg);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn captureFirstPresentationFailure(err: anyerror, job: ExpansionJob, expanded: bundle_expander.Expansion) void {
    if (err != error.UncompiledPresentation and err != error.UncompiledTemplate and err != error.InvalidPreContext and err != error.InvalidHeadingProjection) return;
    const context = if (first_failure_capture_context) |*value| value else return;
    if (context.attempted) return;
    context.attempted = true;
    writeFirstPresentationFailure(err, context.*, job, expanded) catch |capture_error| {
        diagnostics.printLine("presentation failure capture unavailable: error={s}\n", .{@errorName(capture_error)});
    };
}

fn writeFirstPresentationFailure(err: anyerror, context: FirstFailureCaptureContext, job: ExpansionJob, expanded: bundle_expander.Expansion) !void {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The ordinary sharded driver creates a private per-invocation receipt
    // directory outside its disposable workspace and raw shard. Use that same
    // explicit destination for capture; otherwise retain the marker/scope guard.
    if (context.failure_evidence_root == null and !context.continuous_output_active) {
        const marker = try std.fs.path.join(a, &.{ context.output_root, ".incomplete" });
        const marker_file = try std.Io.Dir.cwd().openFile(context.io, marker, .{});
        marker_file.close(context.io);
    }
    const root = try std.fs.path.join(a, &.{ context.failure_evidence_root orelse context.output_root, ".presentation-first-failure" });
    try std.Io.Dir.cwd().createDir(context.io, root, .default_dir);
    try writeDiagnosticJson(context.io, a, root, "capture.json", .{
        .schema = "wikidict.presentation-first-failure.v1", .record_complete = false,
        .diagnostic_only = true, .publication_created = false,
    }, 64 * 1024);
    const payload_limit = 4 * 1024 * 1024;
    var payload_bytes: usize = 0;
    var title_len = @min(job.title.len, 1024);
    while (title_len != 0 and !std.unicode.utf8ValidateSlice(job.title[0..title_len])) title_len -= 1;
    const alias_bytes = if (job.alias_record) |alias| blk: {
        const buffer = try a.alloc(u8, 256 * 1024);
        var output = std.Io.Writer.fixed(buffer);
        try std.json.Stringify.value(alias, .{}, &output);
        break :blk buffer[0..output.end];
    } else null;
    const row = .{
        .schema = "wikidict.presentation-first-failure.v1",
        .record_complete = true, .diagnostic_only = true,
        .publication_created = false, .semantic_acceptance = false,
        .error_name = @errorName(err),
        .ordinal = job.ordinal, .index_offset = job.index_offset, .namespace = job.ns.id,
        .namespace_kind = @tagName(job.ns.kind),
        .page_id = job.page_id, .revision_id = job.revision_id,
        .title = job.title[0..title_len], .title_bytes = job.title.len,
        .title_truncated = title_len != job.title.len,
        .title_sha256 = try auditHash(a, job.title),
        .alias = job.alias_record != null,
        .unsupported_parser_function = expanded.unsupported_parser_function,
        .input = .{ .dump_path = context.input.dump_path, .expander_root = context.input.expander_root,
            .tool_path = context.input.tool_path, .workers = context.input.workers,
            .timeout_ms = context.input.timeout_ms, .now_unix = context.requested_now_unix,
            .start_page = context.input.start_page, .requested_limit = context.input.requested_limit,
            .index_byte_offset = context.input.index_byte_offset },
        .invocation_id = context.invocation_id,
        .invocation_args_sha256 = try invocationArgumentsHash(a, context.invocation_args),
        .invocation_args_hash_framing = "each argv item: u64 little-endian byte length then exact bytes",
        .provenance_scope = "borrowed job inputs and CLI context; outer source/input qualification remains separate; no input-file scan",
        .payload_limit_bytes = payload_limit,
        .raw_source = try captureDiagnosticPayload(context.io, a, root, 1, "raw.wikitext", job.source, 256 * 1024, payload_limit, &payload_bytes),
        .expanded = try captureDiagnosticPayload(context.io, a, root, 1, "expanded.wikitext", expanded.source, 2 * 1024 * 1024, payload_limit, &payload_bytes),
        .display_title = try captureDiagnosticPayload(context.io, a, root, 1, "display-title.wikitext", expanded.display_title, 256 * 1024, payload_limit, &payload_bytes),
        .poem_metadata = try captureDiagnosticPayload(context.io, a, root, 1, "poem.json", expanded.poem_metadata, 256 * 1024, payload_limit, &payload_bytes),
        .missing_dependency_metadata = try captureDiagnosticPayload(context.io, a, root, 1, "missing-dependency.json", expanded.missing_dependency_metadata, 256 * 1024, payload_limit, &payload_bytes),
        .index_row = try captureDiagnosticPayload(context.io, a, root, 1, "index-row.tsv", job.index_line, 256 * 1024, payload_limit, &payload_bytes),
        .alias_record = try captureDiagnosticPayload(context.io, a, root, 1, "alias.json", alias_bytes, 256 * 1024, payload_limit, &payload_bytes),
    };
    try writeDiagnosticJson(context.io, a, root, "capture.json", row, 64 * 1024);
}

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
    const modules = [_]struct { name: []const u8, local_names: bool, nom_names: bool = false }{
        .{ .name = "languages/canonical names", .local_names = false },
        .{ .name = "sprǣcnaman", .local_names = true },
        // Retained SHY langues p4217/r6746 reads l[code].nom from this data module.
        .{ .name = "langues/data", .local_names = false, .nom_names = true },
    };
    for (modules) |module| {
        var rows = std.mem.splitScalar(u8, manifest.bytes, '\n');
        var found = false;
        while (rows.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(struct { page_id: u64, title: []const u8, sha256: []const u8 = "" }, a, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const title = namespaces.ofTitle(parsed.value.title);
            if (title.id != 828 or !std.mem.eql(u8, title.text, module.name)) continue;
            if (found) return error.DuplicateLanguageMetadataModule;
            found = true;
            const module_path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ expander_root, parsed.value.page_id });
            defer a.free(module_path);
            const source = try std.Io.Dir.cwd().readFileAlloc(io, module_path, a, .limited(64 * 1024 * 1024));
            defer a.free(source);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
            if (!std.mem.eql(u8, parsed.value.sha256, &std.fmt.bytesToHex(digest, .lower))) return error.LanguageSourceIdentityMismatch;
            if (module.nom_names) try out.addNomLanguageDataLua(source) else if (module.local_names) try out.addLocalNamesLua(source) else try out.addLua(source);
        }
    }
    try loadPositionalLanguageModules(io, a, expander_root, namespaces, manifest.bytes, &out);
    try loadNamedLanguageModules(io, a, expander_root, namespaces, manifest.bytes, &out);
    if (std.mem.eql(u8, out.content_code orelse "", "ar")) {
        try loadLiteralLanguageTemplates(io, a, expander_root, namespaces, &out, .arabic);
    } else if (std.mem.eql(u8, out.content_code orelse "", "za")) {
        try loadLiteralLanguageTemplates(io, a, expander_root, namespaces, &out, .zhuang);
    } else if (std.mem.eql(u8, out.content_code orelse "", "gor")) {
        try loadLiteralLanguageTemplates(io, a, expander_root, namespaces, &out, .documented_literal);
    }
    try loadSourceLanguageBanners(io, a, expander_root, namespaces, &out);
    const names_path = try std.fs.path.join(a, &.{ expander_root, "language-names.tsv" });
    defer a.free(names_path);
    const names = std.Io.Dir.cwd().readFileAlloc(io, names_path, a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (names) |bytes| {
        defer a.free(bytes);
        try out.trustAutonymSnapshot(bytes, namespaces.wiki, namespaces.dump_date, namespaces.content_language);
    }
    try loadSourceEquivalentLanguageTemplates(io, a, expander_root, namespaces, &out);
    return out;
}

fn isPositionalLanguageModule(title: []const u8) bool {
    if (std.mem.eql(u8, title, "languages/data/2")) return true;
    const prefix = "languages/data/3/";
    return title.len == prefix.len + 1 and std.mem.startsWith(u8, title, prefix) and
        title[prefix.len] >= 'a' and title[prefix.len] <= 'z';
}

fn loadPositionalLanguageModules(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, manifest: []const u8, registry: *language_registry.Registry) !void {
    const Record = struct { page_id: u64, title: []const u8, sha256: []const u8 = "" };
    var provider_page: ?u64 = null;
    var provider_digest: [64]u8 = undefined;
    var provider_count: usize = 0;
    var has_data = false;
    var rows = std.mem.splitScalar(u8, manifest, '\n');
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, a, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const title = namespaces.ofTitle(parsed.value.title);
        if (title.id != 828) continue;
        if (isPositionalLanguageModule(title.text)) has_data = true;
        if (!std.mem.eql(u8, title.text, "languages")) continue;
        provider_count += 1;
        if (parsed.value.sha256.len != provider_digest.len) continue;
        @memcpy(&provider_digest, parsed.value.sha256);
        provider_page = parsed.value.page_id;
    }
    if (!has_data) return;
    const page = provider_page orelse return;
    if (provider_count != 1) return error.DuplicateLanguageMetadataModule;
    const provider_path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ root, page });
    defer a.free(provider_path);
    const provider_source = try std.Io.Dir.cwd().readFileAlloc(io, provider_path, a, .limited(64 * 1024 * 1024));
    defer a.free(provider_source);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(provider_source, &hash, .{});
    if (!std.mem.eql(u8, &provider_digest, &std.fmt.bytesToHex(hash, .lower))) return error.LanguageSourceIdentityMismatch;
    const provider_proof = (try language_registry.Registry.provePositionalLanguageProvider(a, provider_source)) orelse return;
    var names: std.StringHashMap(void) = .init(a);
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        names.deinit();
    }
    rows = std.mem.splitScalar(u8, manifest, '\n');
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, a, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const title = namespaces.ofTitle(parsed.value.title);
        if (title.id != 828 or !isPositionalLanguageModule(title.text)) continue;
        if (names.contains(title.text)) return error.DuplicateLanguageMetadataModule;
        const owned_name = try a.dupe(u8, title.text);
        names.put(owned_name, {}) catch |err| { a.free(owned_name); return err; };
        const path = try std.fmt.allocPrint(a, "{s}/modules/{d}.lua", .{ root, parsed.value.page_id });
        defer a.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(2 * 1024 * 1024));
        defer a.free(source);
        std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
        if (!std.mem.eql(u8, parsed.value.sha256, &std.fmt.bytesToHex(hash, .lower))) return error.LanguageSourceIdentityMismatch;
        try registry.addPositionalLanguageDataLua(source, provider_proof, title.text);
    }
}

fn isCanonicalLanguageDataModule(title: []const u8) bool {
    if (std.mem.eql(u8, title, "languages/data2")) return true;
    const prefix = "languages/data3/";
    return title.len == prefix.len + 1 and std.mem.startsWith(u8, title, prefix) and
        title[prefix.len] >= 'a' and title[prefix.len] <= 'z';
}

fn loadNamedLanguageModules(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, manifest: []const u8, registry: *language_registry.Registry) !void {
    var rows = std.mem.splitScalar(u8, manifest, '\n');
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(struct { page_id: u64, title: []const u8, sha256: []const u8 = "" }, a, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const title = namespaces.ofTitle(parsed.value.title);
        if (title.id != 828) continue;
        const kind: language_registry.LanguageDataKind = if (isCanonicalLanguageDataModule(title.text))
            .canonical_assignments
        else if (std.mem.eql(u8, registry.content_code orelse "", "ar") and std.mem.eql(u8, title.text, "لغات/بيانات"))
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

fn literalZhuangLanguageTemplate(source: []const u8, code: []const u8) ?[]const u8 {
    // Captured ZA hyphen banners repeat one literal label and their title's
    // registered code. Parameters, calls and additional content supply no alias.
    const raw = std.mem.trim(u8, source, " \t\r\n");
    const prefix = "<includeonly>[[Category:";
    const separator = "]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[";
    if (!std.mem.startsWith(u8, raw, prefix)) return null;
    const split = std.mem.indexOfPos(u8, raw, prefix.len, separator) orelse return null;
    const label = raw[prefix.len..split];
    if (label.len == 0 or std.mem.indexOfAny(u8, label, "[]{}|<>#:&\x00\r\n\t") != null or
        !std.mem.eql(u8, label, std.mem.trim(u8, label, " "))) return null;
    var rest = raw[split + separator.len ..];
    if (!std.mem.startsWith(u8, rest, label)) return null;
    rest = rest[label.len..];
    const code_prefix = "]] <small><small>(";
    if (!std.mem.startsWith(u8, rest, code_prefix)) return null;
    rest = rest[code_prefix.len..];
    if (!std.mem.startsWith(u8, rest, code)) return null;
    return if (std.mem.eql(u8, rest[code.len..], ")</small></small></big></div>=")) label else null;
}

// Only one complete literal prefix and one fully excluded documentation block.
// No other '<' permits nested onlyinclude, comments or protected-tag ambiguity;
// ordinary transclusion therefore removes the entire suffix before any calls.
fn literalDocumentedLanguageTemplate(source: []const u8) ?[]const u8 {
    const raw = std.mem.trim(u8, source, " \t\r\n");
    const open = std.mem.indexOfScalar(u8, raw, '<') orelse return null;
    const suffix = raw[open..];
    const prefix = "<noinclude>";
    const close = "</noinclude>";
    if (!std.mem.startsWith(u8, suffix, prefix) or !std.mem.endsWith(u8, suffix, close) or
        suffix.len < prefix.len + close.len) return null;
    if (std.mem.indexOfScalar(u8, suffix[prefix.len .. suffix.len - close.len], '<') != null) return null;
    const label = raw[0..open];
    if (label.len == 0 or !std.mem.eql(u8, label, std.mem.trim(u8, label, " ")) or
        std.mem.indexOfAny(u8, label, "[]{}|<>&#:='") != null) return null;
    for (label) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    return label;
}

const LiteralLanguageTemplateKind = enum { arabic, zhuang, documented_literal };

fn loadLiteralLanguageTemplates(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, registry: *language_registry.Registry, kind: LiteralLanguageTemplateKind) !void {
    const path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    defer a.free(path);
    var index = mmapPath(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer index.deinit();
    var templates = (try dump_source.TemplateSource.open(io, a, root, index.bytes)) orelse return;
    defer templates.deinit();
    const index_kind = dump_source.pageIndexKind(index.bytes);
    var rows = std.mem.splitScalar(u8, index.bytes, '\n');
    var ordinal: u64 = 0;
    while (rows.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const row = try dump_source.parsePageIndexLine(index_kind, line);
        const this_ordinal = ordinal;
        ordinal += 1;
        if (row.ns != 10 or row.redirect != null or !row.has_source) continue;
        const title = namespaces.ofTitle(row.title);
        if (title.id != 10) continue;
        const code = switch (kind) {
            .arabic, .documented_literal => title.text,
            .zhuang => blk: {
                if (title.text.len <= 2 or title.text[0] != '-' or title.text[title.text.len - 1] != '-') continue;
                break :blk title.text[1 .. title.text.len - 1];
            },
        };
        if (!registry.codes.contains(code)) continue;
        const raw = (try templates.lookup(this_ordinal, row.page_id, row.revision_id)) orelse return error.MissingLanguageTemplateSource;
        // Only the bounded literal forms above can be language-name evidence.
        if (raw.len > 4096) continue;
        const source = if (row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw) else null;
        defer if (source) |bytes| a.free(bytes);
        const label = switch (kind) {
            .arabic => literalArabicLanguageTemplate(source orelse raw),
            .zhuang => literalZhuangLanguageTemplate(source orelse raw, code),
            .documented_literal => literalDocumentedLanguageTemplate(source orelse raw),
        };
        if (label) |name| try registry.addLocalAlias(name, code);
    }
}

// A complete codetolang table declares parameter-1 codes as literal names.
// Validate every row before importing any; this is source data, not #switch execution.
fn importLiteralLanguageNameSwitch(a: std.mem.Allocator, registry: *language_registry.Registry, source: []const u8) !bool {
    const prefix = "{{#switch:{{{1|}}}|";
    const raw = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, raw, prefix) or !std.mem.endsWith(u8, raw, "}}") or raw.len > 4096) return false;
    const Row = struct { code: []const u8, label: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    var fields = std.mem.splitScalar(u8, raw[prefix.len .. raw.len - 2], '|');
    var default_seen = false;
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        const code = field[0..equals];
        const label = field[equals + 1 ..];
        if (label.len == 0 or !std.unicode.utf8ValidateSlice(label) or
            !std.mem.eql(u8, label, std.mem.trim(u8, label, " \t\r\n")) or
            std.mem.indexOfAny(u8, label, "[]{}<>&#='~\x00\r\n\t") != null or
            std.mem.indexOf(u8, label, "__") != null) return false;
        if (std.mem.eql(u8, code, "#default")) {
            if (default_seen) return false;
            default_seen = true;
            continue;
        }
        if (code.len < 2 or code.len > 16) return false;
        for (code) |byte| if (!(byte >= 'a' and byte <= 'z') and byte != '-') return false;
        for (rows.items) |row| if (std.mem.eql(u8, row.code, code)) return false;
        if (rows.items.len == 64) return false;
        try rows.append(a, .{ .code = code, .label = label });
    }
    if (!default_seen or rows.items.len == 0) return false;
    for (rows.items) |row| if (registry.codes.contains(row.code)) try registry.addLocalAlias(row.label, row.code);
    return true;
}

// Discover authenticated source banners without changing ordinary registry trust.
// Open/checksum template data only for a registered code or hyphen-code title.
fn loadSourceLanguageBanners(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, registry: *language_registry.Registry) !void {
    const path = try std.fs.path.join(a, &.{ root, "page-index.tsv" }); defer a.free(path);
    var index = mmapPath(io, path) catch |err| switch (err) { error.FileNotFound => return, else => return err };
    defer index.deinit();
    var templates: ?dump_source.TemplateSource = null;
    defer if (templates) |*value| value.deinit();
    var behavior: ?namespace_registry.behavior_switches.Registry = null;
    defer if (behavior) |*value| value.deinit();
    const index_kind = dump_source.pageIndexKind(index.bytes);
    var rows = std.mem.splitScalar(u8, index.bytes, '\n');
    var ordinal: u64 = 0;
    while (rows.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const row = try dump_source.parsePageIndexLine(index_kind, line);
        const this_ordinal = ordinal; ordinal += 1;
        if (row.ns != 10 or row.redirect != null or !row.has_source) continue;
        const title = namespaces.ofTitle(row.title);
        if (title.id != 10) continue;
        const name_table = std.mem.eql(u8, title.text, "codetolang");
        const message_link = !name_table and registry.codes.contains(title.text);
        const code = if (name_table) "" else if (message_link) title.text else blk: {
            if (title.text.len < 3 or title.text[0] != '-' or title.text[title.text.len - 1] != '-') continue;
            break :blk title.text[1 .. title.text.len - 1];
        };
        if (!name_table and !registry.codes.contains(code)) continue;
        if (templates == null) {
            templates = (try dump_source.TemplateSource.open(io, a, root, index.bytes)) orelse return;
            const behavior_path = try std.fs.path.join(a, &.{ root, "behavior-switches.tsv" }); defer a.free(behavior_path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, behavior_path, a, .limited(1024 * 1024)) catch |err| switch (err) { error.FileNotFound => null, else => return err };
            defer if (bytes) |value| a.free(value);
            if (bytes) |value| behavior = try namespace_registry.behavior_switches.Registry.init(a, value, namespaces.wiki, namespaces.dump_date, namespaces.content_language, namespaces.source_sha256);
        }
        const raw = (try templates.?.lookup(this_ordinal, row.page_id, row.revision_id)) orelse return error.MissingLanguageTemplateSource;
        if (raw.len > 4096) continue;
        const decoded = if (row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw) else null;
        defer if (decoded) |value| a.free(value);
        if (name_table) {
            _ = try importLiteralLanguageNameSwitch(a, registry, decoded orelse raw);
        } else if (message_link) {
            if (source_language_banner.messageLinkTarget(decoded orelse raw, namespaces, code)) |target|
                try registry.addLocalAlias(target, code);
        } else {
            if (source_language_banner.parse(decoded orelse raw, namespaces, if (behavior) |*value| value else null, registry, code)) |proof|
                try registry.addSourceLanguageBanner(code, proof);
            if (source_language_banner.parseParagraph(decoded orelse raw, namespaces, if (behavior) |*value| value else null, registry, code)) |proof|
                try registry.addSourceLanguageParagraph(code, proof);
        }
    }
}

// A trusted language-named template and another parameter-independent template
// may share one authenticated wrapper. Import only that source equivalence, not
// an arbitrary code-named literal template as a new language authority.
const SourceEquivalentTemplate = struct { row: dump_source.IndexedPage, ordinal: u64 };

fn sourceEquivalentTerminal(rows: []const SourceEquivalentTemplate, names: *const std.StringHashMapUnmanaged(usize), namespaces: *const namespace_registry.Registry, start: usize) ?usize {
    var current = start;
    var seen: [8]usize = undefined;
    var count: usize = 0;
    while (true) {
        for (seen[0..count]) |before| if (before == current) return null;
        if (count == seen.len) return null;
        seen[count] = current;
        count += 1;
        const row = rows[current].row;
        const redirect = row.redirect orelse return if (row.has_source and std.mem.eql(u8, row.content_model, "wikitext")) current else null;
        const target = namespaces.ofTitle(redirect);
        if (target.id != 10 or std.mem.indexOfAny(u8, target.text, "#|") != null) return null;
        current = names.get(target.text) orelse return null;
    }
}

fn sourceEquivalentWrapperCode(source: []const u8, namespaces: *const namespace_registry.Registry) ?[]const u8 {
    const raw = std.mem.trim(u8, source, " \t\r\n");
    const prefix = "[[{{";
    const separator = "}}]]<includeonly>[[";
    if (!std.mem.startsWith(u8, raw, prefix)) return null;
    const split = std.mem.indexOfPos(u8, raw, prefix.len, separator) orelse return null;
    const code = raw[prefix.len..split];
    if (code.len == 0 or std.mem.indexOfAny(u8, code, "{}[]<>|=:# \t\r\n") != null) return null;
    var rest = raw[split + separator.len ..];
    const included_end = std.mem.indexOf(u8, rest, "]]</includeonly><noinclude>[[") orelse return null;
    const category = rest[0..included_end];
    const call = std.mem.indexOf(u8, category, "{{") orelse return null;
    if (!std.mem.endsWith(u8, category, "}}") or category.len != call + code.len + 4 or
        !std.mem.eql(u8, category[call + 2 .. category.len - 2], code) or
        std.mem.indexOfAny(u8, category[0..call], "{}[]<>|\r\n") != null or
        namespaces.ofTitle(category[0..call]).id != 14) return null;
    rest = rest[included_end + "]]</includeonly><noinclude>[[".len ..];
    const suffix = "]]</noinclude>";
    if (!std.mem.endsWith(u8, rest, suffix)) return null;
    const documentation = rest[0 .. rest.len - suffix.len];
    if (std.mem.indexOfAny(u8, documentation, "{}[]<>|\r\n") != null or namespaces.ofTitle(documentation).id != 14) return null;
    return code;
}

fn sourceEquivalentLiteral(source: []const u8) bool {
    const raw = std.mem.trim(u8, source, " \t\r\n");
    if (raw.len == 0 or !std.mem.eql(u8, raw, source) or std.mem.indexOfAny(u8, raw, "{}[]<>|=&#:\r\n\t'\"_~*;!") != null) return false;
    for (raw) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn loadSourceEquivalentLanguageTemplates(io: std.Io, a: std.mem.Allocator, root: []const u8, namespaces: *const namespace_registry.Registry, registry: *language_registry.Registry) !void {
    const path = try std.fs.path.join(a, &.{ root, "page-index.tsv" }); defer a.free(path);
    var index = mmapPath(io, path) catch |err| switch (err) { error.FileNotFound => return, else => return err };
    defer index.deinit();
    var templates: ?dump_source.TemplateSource = null;
    defer if (templates) |*value| value.deinit();
    var rows: std.ArrayList(SourceEquivalentTemplate) = .empty; defer rows.deinit(a);
    var names: std.StringHashMapUnmanaged(usize) = .empty; defer names.deinit(a);
    var lines = std.mem.splitScalar(u8, index.bytes, '\n');
    var ordinal: u64 = 0;
    const kind = dump_source.pageIndexKind(index.bytes);
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const row = try dump_source.parsePageIndexLine(kind, line);
        const current = ordinal; ordinal += 1;
        if (row.ns != 10) continue;
        const title = namespaces.ofTitle(row.title);
        if (title.id != 10) continue;
        const entry = try names.getOrPut(a, title.text);
        if (entry.found_existing) return error.DuplicateLanguageTemplateSource;
        entry.value_ptr.* = rows.items.len;
        try rows.append(a, .{ .row = row, .ordinal = current });
    }
    var owners: std.AutoHashMapUnmanaged(usize, ?[]const u8) = .empty; defer owners.deinit(a);
    var proven: std.AutoHashMapUnmanaged(usize, void) = .empty; defer proven.deinit(a);
    // Finish all trusted seeds before adding aliases; a new alias cannot seed
    // another proof, and competing original owners make the wrapper ambiguous.
    for (rows.items, 0..) |entry, i| {
        const title = namespaces.ofTitle(entry.row.title);
        const trusted = registry.resolveStrong(title.text) orelse registry.resolveSourceTrusted(title.text) orelse continue;
        const terminal = sourceEquivalentTerminal(rows.items, &names, namespaces, i) orelse continue;
        const owner = try owners.getOrPut(a, terminal);
        if (!owner.found_existing) owner.value_ptr.* = trusted.code else if (owner.value_ptr.*) |before| {
            if (!std.mem.eql(u8, before, trusted.code)) owner.value_ptr.* = null;
        }
        const wrapper = rows.items[terminal];
        if (templates == null) templates = (try dump_source.TemplateSource.open(io, a, root, index.bytes)) orelse return;
        const raw = (try templates.?.lookup(wrapper.ordinal, wrapper.row.page_id, wrapper.row.revision_id)) orelse return error.MissingLanguageTemplateSource;
        if (raw.len > 4096) continue;
        const decoded = if (wrapper.row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw) else null; defer if (decoded) |value| a.free(value);
        const code = sourceEquivalentWrapperCode(decoded orelse raw, namespaces) orelse continue;
        if (!std.mem.eql(u8, code, trusted.code)) continue;
        const leaf_index = names.get(code) orelse continue;
        const leaf = rows.items[leaf_index];
        if (leaf.row.redirect != null or !leaf.row.has_source or !std.mem.eql(u8, leaf.row.content_model, "wikitext")) continue;
        const leaf_raw = (try templates.?.lookup(leaf.ordinal, leaf.row.page_id, leaf.row.revision_id)) orelse return error.MissingLanguageTemplateSource;
        if (leaf_raw.len > 4096) continue;
        const leaf_decoded = if (leaf.row.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, leaf_raw) else null; defer if (leaf_decoded) |value| a.free(value);
        if (!sourceEquivalentLiteral(leaf_decoded orelse leaf_raw)) continue;
        try proven.put(a, terminal, {});
    }
    for (rows.items, 0..) |entry, i| {
        const terminal = sourceEquivalentTerminal(rows.items, &names, namespaces, i) orelse continue;
        if (!proven.contains(terminal)) continue;
        const code = (owners.get(terminal) orelse continue) orelse continue;
        const title = namespaces.ofTitle(entry.row.title);
        try registry.addLocalAlias(title.text, code);
    }
}

fn languageCodes(registry: *const language_registry.Registry, namespaces: ?*const namespace_registry.Registry) encoder.blob_builder.LanguageCodes {
    return .{
        .namespace_catalog = namespaces,
        .ctx = registry,
        .source_paragraph_fn = struct {
            fn matches(raw: ?*const anyopaque, code_value: []const u8, line: []const u8) bool {
                const value: *const language_registry.Registry = @ptrCast(@alignCast(raw orelse return false));
                return value.matchesSourceLanguageParagraph(code_value, line);
            }
        }.matches,
        .source_banner_fn = struct {
            fn matches(raw: ?*const anyopaque, code_value: []const u8, heading: []const u8, level: u8) bool {
                const value: *const language_registry.Registry = @ptrCast(@alignCast(raw orelse return false));
                return value.matchesSourceLanguageBanner(code_value, heading, level);
            }
        }.matches,
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

fn captureDiagnosticPayload(io: std.Io, a: std.mem.Allocator, root: []const u8, failure: usize, label: []const u8, value: ?[]const u8, cap: usize, total_cap: usize, payload_bytes: *usize) !AuditPayload {
    const bytes = value orelse return .{ .present = false };
    const digest = try auditHash(a, bytes);
    if (bytes.len == 0) return .{ .present = true, .sha256 = digest };
    const n = @min(bytes.len, @min(cap, total_cap - payload_bytes.*));
    if (n == 0 and bytes.len != 0) return .{ .present = true, .bytes = bytes.len, .sha256 = digest, .unretained = true };
    const path = try std.fmt.allocPrint(a, "{s}/failure-{d:0>8}-{s}", .{ root, failure, label });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes[0..n] });
    payload_bytes.* += n;
    return .{ .present = true, .bytes = bytes.len, .sha256 = digest, .path = path, .retained_bytes = n, .truncated = n != bytes.len };
}

fn writeDiagnosticJson(io: std.Io, a: std.mem.Allocator, root: []const u8, name: []const u8, value: anytype, byte_limit: usize) !void {
    if (byte_limit != std.math.maxInt(usize)) {
        const buffer = try a.alloc(u8, byte_limit);
        defer a.free(buffer);
        var output = std.Io.Writer.fixed(buffer);
        try std.json.Stringify.value(value, .{}, &output);
        return writeDiagnosticBytes(io, a, root, name, buffer[0..output.end]);
    }
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    return writeDiagnosticBytes(io, a, root, name, bytes);
}

fn writeDiagnosticBytes(io: std.Io, a: std.mem.Allocator, root: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, name });
    defer a.free(path);
    const temporary = try std.fmt.allocPrint(a, "{s}.part", .{path});
    defer a.free(temporary);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
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
fn auditablePresentationError(err: anyerror) bool {
    return err == error.UncompiledPresentation or err == error.InvalidPreContext or err == error.InvalidHeadingProjection;
}

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
        return writeDiagnosticJson(self.io, self.allocator, self.root, name, value, std.math.maxInt(usize));
    }

    fn capture(self: *PresentationAudit, a: std.mem.Allocator, label: []const u8, value: ?[]const u8, cap: usize) !AuditPayload {
        return captureDiagnosticPayload(self.io, a, self.root, self.failed, label, value, cap, 64 * 1024 * 1024, &self.payload_bytes);
    }

    fn recordSuccess(self: *PresentationAudit) void {
        self.compile_attempts += 1;
        self.succeeded += 1;
    }

    fn recordFailure(self: *PresentationAudit, err: anyerror, job: ExpansionJob, expanded: bundle_expander.Expansion) !void {
        // Reject nonselected errors before any counter, allocation or file edit.
        if (!auditablePresentationError(err)) return err;
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
            .error_name = @errorName(err),
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

// Shared post-Writer error seam. Only the explicit diagnostic audit class may
// discard one failed page and continue; ordinary builds return the original error.
fn consumePresentationFailure(writer: *encoder.blob_builder.Writer, job: ExpansionJob, expanded: bundle_expander.Expansion, a: std.mem.Allocator, audit: ?*PresentationAudit, err: anyerror) !bool {
    if (audit) |value| if (auditablePresentationError(err)) {
        try value.recordFailure(err, job, expanded);
        try discardAuditPage(writer, a);
        return false;
    };
    captureFirstPresentationFailure(err, job, expanded);
    return recordPresentationFailure(err, job);
}

fn consumeExpandedPage(writer: *encoder.blob_builder.Writer, job: ExpansionJob, expanded: bundle_expander.Expansion, a: std.mem.Allocator, audit: ?*PresentationAudit) !bool {
    const extra_reasons: []const []const u8 = if (expanded.unsupported_parser_function) &.{"unsupported_parser_function"} else &.{};
    if (job.alias_record) |alias| {
        writer.addAliasExpandedWithPhases(a, alias, expanded.source, expanded.display_title, .{}, extra_reasons, expanded.poem_metadata, expanded.missing_dependency_metadata) catch |err| {
            return consumePresentationFailure(writer, job, expanded, a, audit, err);
        };
    } else {
        writer.addExpandedPageWithReasonsAndPhases(a, job.ns, job.title, expanded.source, job.source, expanded.display_title, extra_reasons, expanded.poem_metadata, expanded.missing_dependency_metadata) catch |err| {
            diagnostics.printLine("blob add failed title={s} ordinal={d} ns={d} source_bytes={d} expanded_bytes={d} error={s}\n", .{ job.title, job.ordinal, job.ns.id, job.source.len, expanded.source.len, @errorName(err) });
            return consumePresentationFailure(writer, job, expanded, a, audit, err);
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
    index_offset: u64,
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
    profile_enabled: bool = false,
    protocol_profile: ParentPhaseTotals = .{},
    consumer_profile: ParentPhaseTotals = .{},

    fn threadMain(self: *ExpansionSlot) void {
        defer self.worker.deinit();
        while (true) {
            self.job_event.waitUncancelable(self.io);
            self.job_event.reset();
            if (self.stop.load(.acquire)) return;
            self.failure = null;
            const profile_start = if (self.profile_enabled) ParentProfileStamp.now(self.io) else null;
            self.expansion = self.worker.expand(
                self.arena.allocator(),
                self.job.ordinal,
                .{ .index_offset = self.job.index_offset, .page_id = self.job.page_id, .revision_id = self.job.revision_id, .namespace = self.job.ns.id },
                self.job.title,
                self.job.source,
            ) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            if (profile_start) |started| self.protocol_profile.record(started, ParentProfileStamp.now(self.io));
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
            const compiled = blk: {
                const profile_start = if (self.profile_enabled) ParentProfileStamp.now(self.io) else null;
                defer if (profile_start) |started| self.consumer_profile.record(started, ParentProfileStamp.now(self.io));
                break :blk try consumeExpandedPage(writer, self.job, expanded, self.arena.allocator(), audit);
            };
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
    profile_enabled: bool = false,
    finish_profile: ParentPhaseTotals = .{},

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
        if (self.profile_enabled) {
            var consumer: ParentPhaseTotals = .{};
            var protocol: ParentPhaseTotals = .{};
            for (self.slots) |slot| {
                consumer.merge(slot.consumer_profile);
                protocol.merge(slot.protocol_profile);
            }
            // Protocol wall includes child wait and overlaps consumer/peer calls.
            consumer.log("expanded-consume-compile-encode-spool");
            protocol.log("worker-protocol-including-child-wait");
            self.finish_profile.log("writer-finish");
        }
        for (self.slots) |*slot| slot.arena.deinit();
        self.allocator.free(self.slots);
        self.allocator.destroy(self.completion);
        self.* = undefined;
    }

    fn finishWriter(self: *ExpansionPool, writer: *encoder.blob_builder.Writer, codes: encoder.blob_builder.LanguageCodes) !encoder.blob_builder.BuildStats {
        const profile_start = if (self.profile_enabled) ParentProfileStamp.now(self.io) else null;
        defer if (profile_start) |started| self.finish_profile.record(started, ParentProfileStamp.now(self.io));
        return writer.finish(codes);
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
    const job: ExpansionJob = .{ .index_offset = 0, .ordinal = 14002, .ns = .{ .id = 114, .kind = .citations }, .title = "Citations:quoted \"fixture\"", .source = "not serialized", .page_id = 7, .revision_id = 9 };
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

// Only an exact row slice of the pinned mapping may become a wire address.
fn mappedPageIndexOffset(mapped: []const u8, line: []const u8) !u64 {
    const base = @intFromPtr(mapped.ptr);
    const start = @intFromPtr(line.ptr);
    if (start < base) return error.InvalidPageIndex;
    const offset = start - base;
    if (offset > mapped.len or line.len > mapped.len - offset) return error.InvalidPageIndex;
    if (line.len == 0 or line[0] == '#' or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidPageIndex;
    if (offset != 0 and mapped[offset - 1] != '\n') return error.InvalidPageIndex;
    const end = offset + line.len;
    if (end != mapped.len and mapped[end] != '\n') return error.InvalidPageIndex;
    return std.math.cast(u64, offset) orelse error.InvalidPageIndex;
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
        const own_offset = dump_source.pageRowRefOffset(own_ref);
        if (own_offset >= pool.page_index_bytes.len) return error.InvalidPageIndex;
        const own_end = std.mem.indexOfScalarPos(u8, pool.page_index_bytes, own_offset, '\n') orelse pool.page_index_bytes.len;
        const own_page = try dump_source.parsePageIndexLine(kind, pool.page_index_bytes[own_offset..own_end]);
        if (own_page.ns != page.ns) return error.NamespaceTitleCollision;
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
            slot.dispatch(.{ .ordinal = @intCast(ordinal), .index_offset = try mappedPageIndexOffset(pool.page_index_bytes, line), .ns = .{ .id = page.ns, .kind = role.? }, .title = page.title, .source = try retained.dupe(u8, tail), .alias_record = owned, .page_id = page.page_id, .revision_id = page.revision_id, .index_line = line });
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
        .index_offset = try mappedPageIndexOffset(pool.page_index_bytes, line),
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
        const stats = try pool.finishWriter(writer, codes);
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
    const capture_scope = ContinuousFailureCaptureScope.begin(output_root);
    defer capture_scope.deinit();
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
    first_failure_capture_context = if (options.audit_presentation_errors) null else FirstFailureCaptureContext.fromCli(init.io, a, args, options);
    defer first_failure_capture_context = null;
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
    const profile_env = getenv("WIKIDICT_EXPANSION_PROFILE");
    const profile_enabled = try diagnostics.profileEnabledFromEnv(if (profile_env) |value| std.mem.span(value) else null);
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

    // Lazy proof reads borrow the same authenticated normal input/index and
    // remain alive through Writer/worker completion. No corpus-wide preload.
    var category_languages: source_category_language.Context = .{
        .allocator = a, .registry = &registry, .namespace_catalog = &namespaces,
        .source = &dump, .page_index = page_index.bytes, .title_index = title_index,
    };
    codes.source_category_ctx = &category_languages;
    codes.source_category_fn = source_category_language.Context.callback;

    // Jobs borrow their titles from page_index. Join every worker before
    // releasing those mapped bytes, including fatal expansion-error unwinds
    // while another worker is retrying a request after a remote OOM.
    const worker_path = try std.fs.path.join(a, &.{ options.expander_root, "dict-bundle-expander" });
    defer a.free(worker_path);
    var pool = try ExpansionPool.init(io, a, options.expander_root, worker_path, args[1], options.workers, if (audit) |value| value.context.now_unix else options.now_unix, options.expansion_timeout_ms orelse expansion_deadline.default_ms);
    defer pool.deinit();
    pool.profile_enabled = profile_enabled;
    for (pool.slots) |*slot| slot.profile_enabled = profile_enabled;
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
    const stats = try pool.finishWriter(&writer, codes);
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
    try std.testing.expect(isCanonicalLanguageDataModule("languages/data2"));
    for ("abcdefghijklmnopqrstuvwxyz") |letter| {
        var title = "languages/data3/a".*;
        title[title.len - 1] = letter;
        try std.testing.expect(isCanonicalLanguageDataModule(&title));
    }
    for ([_][]const u8{ "languages/data3", "languages/data3/", "languages/data3/M", "languages/data3/mm", "languages/data3/m/doc", "languages/data3/1", "languages/data3/م", "languages/data3/m ", "Languages/data3/m", "other/languages/data3/m", "languages/data2/doc" }) |title|
        try std.testing.expect(!isCanonicalLanguageDataModule(title));
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
        try loadNamedLanguageModules(io, a, root, &namespaces, manifest, &registry);
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
    const lexical_offset = std.mem.indexOf(u8, index_text, row_lines[4]) orelse return error.InvalidPageIndex;
    const lexical_row = index_text[lexical_offset .. lexical_offset + row_lines[4].len];
    try dispatchIndexedPage(&pool, &control_writer, &dump, .raw_xml, &namespaces, lexical_row, 4);
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
    const job: ExpansionJob = .{ .index_offset = 0, .ordinal = 1, .ns = .{ .id = 0, .kind = .language }, .title = "Strict fixture", .source = "raw fixture" };
    try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = "[https:// broken" }, a, null));
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
        const source = "==English==\n# first owner is valid\n==French==\n# [https:// broken\n";
        const job: ExpansionJob = .{ .index_offset = 0, .ordinal = 2, .ns = .{ .id = 0, .kind = .language }, .title = "Partial owners", .source = source };
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = source }, a, null));
        try std.testing.expect(writer.stats.language_records > 0);
        const later: ExpansionJob = .{ .index_offset = 0, .ordinal = 3, .ns = .{ .id = 0, .kind = .language }, .title = "Later valid", .source = "==English==\n# later valid" };
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
    const bad_external = "[https:// broken unretained-expanded-A";
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
            const job: ExpansionJob = .{ .index_offset = 0, .ordinal = @intCast(ordinal), .ns = .{ .id = 0, .kind = .language }, .title = page.title, .source = raw_request };
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
        const job: ExpansionJob = .{ .index_offset = 0, .ordinal = 7, .ns = .{ .id = 0, .kind = .language }, .title = "Operational control", .source = "valid [[allocation]] source" };
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

const ZaLiteralTemplateTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tzawiktionary\n# dump-date\t20261001\n# content-language\tza\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\t模板\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\t分类\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tza\n# mediawiki\n" ++
        "za\tVahcuengh\tza\tZhuang\tzha\n" ++
        "en\tYinghyij\tEnglish\ten\n" ++
        "es\tVah Sihbanhyaz\tEspañol\tespañol\tes\tSpanish\tspa\n" ++
        "th\tDaiyij\tไทย\tth\tThai\ttha\n" ++
        "pt\tVah Buzdauzyaz\tPortuguês\tportuguês\tpt\tPortuguese\tpor\n" ++
        "zh-min-nan\t闽南语 (zh-min-nan)\t闽南语\t闽南语\tBân-lâm-gú\tzh-min-nan\tnan\tMin Nan Chinese\n";
    // Complete literal bodies from ZA 20261001, in page/revision order below.
    const templates = [_]struct { code: []const u8, label: []const u8, page: u64, revision: u64, source: []const u8 }{
        .{ .code = "th", .label = "Vahdai", .page = 8702, .revision = 11175, .source = "<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai]] <small><small>(th)</small></small></big></div>=" },
        .{ .code = "es", .label = "Sihbanhyazyij", .page = 8865, .revision = 11531, .source = "<includeonly>[[Category:Sihbanhyazyij]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Sihbanhyazyij]] <small><small>(es)</small></small></big></div>=" },
        .{ .code = "zh-min-nan", .label = "Vah Hozloz", .page = 8936, .revision = 11761, .source = "<includeonly>[[Category:Vah Hozloz]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vah Hozloz]] <small><small>(zh-min-nan)</small></small></big></div>=" },
        .{ .code = "en", .label = "Yinghyij", .page = 8687, .revision = 11152, .source = "<includeonly>[[Category:Yinghyij]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Yinghyij]] <small><small>(en)</small></small></big></div>=" },
    };

    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        var index: std.ArrayList(u8) = .empty;
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root);
        defer writer.deinit();
        for (templates, 0..) |row, ordinal| {
            try index.appendSlice(a, try std.fmt.allocPrint(a, "0\t0\t模板:-{s}-\t\t{d}\t{d}\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n", .{ row.code, row.page, row.revision }));
            try writer.append(ordinal, row.page, row.revision, row.source);
        }
        const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index.items });
        try writer.finish(index_path);
    }

    fn banner(a: std.mem.Allocator, row: @TypeOf(templates[0])) ![]const u8 {
        // Source-instantiated transclusion fixture, not saved runtime output.
        // Only includeonly's literal category wrapper changes in these bodies.
        return std.fmt.allocPrint(a, "[[Category:{s}]]{s}", .{ row.label, row.source[("<includeonly>[[Category:".len + row.label.len + "]]</includeonly>".len)..] });
    }

    fn missingMetadata(a: std.mem.Allocator, source: []const u8, unknown: bool) ![]const u8 {
        const Range = struct { start: u32, end: u32, occurrence: u32 };
        const Occurrence = struct { id: u32, title: []const u8 };
        const Coordinates = struct { ranges: []const Range, unknown: bool };
        const ranges = [_]Range{.{ .start = 0, .end = "[[:模板:-pt-]]".len, .occurrence = 1 }};
        const occurrences = [_]Occurrence{.{ .id = 1, .title = "模板:-pt-" }};
        const found: []const Occurrence = if (unknown) &.{} else &occurrences;
        return std.json.Stringify.valueAlloc(a, .{
            .schema = "wikidict.missing-dependency-phase.v1",
            .output_sha256 = try auditControlHash(a, source),
            .display_title_sha256 = try auditControlHash(a, ""),
            .occurrences = found,
            .output = Coordinates{ .ranges = if (unknown) &.{} else &ranges, .unknown = unknown },
            .display_title = Coordinates{ .ranges = &.{}, .unknown = unknown },
        }, .{});
    }
};

test "ZA literal banner alias proof rejects dynamic malformed and mixed declarations" {
    for (ZaLiteralTemplateTest.templates) |row|
        try std.testing.expectEqualStrings(row.label, literalZhuangLanguageTemplate(row.source, row.code).?);
    try std.testing.expect(literalZhuangLanguageTemplate(ZaLiteralTemplateTest.templates[0].source, "es") == null);
    for ([_][]const u8{
        "<includeonly>[[Category:{{{1}}}]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[{{{1}}}]] <small><small>(th)</small></small></big></div>=",
        "<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Other]] <small><small>(th)</small></small></big></div>=",
        "<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai|Other]] <small><small>(th)</small></small></big></div>=",
        "<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai]] [[Yinghyij]] <small><small>(th)</small></small></big></div>=",
        "<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai]] <small><small>(th)</small></big></div>=",
        "<nowiki><includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai]] <small><small>(th)</small></small></big></div>=</nowiki>",
        "<!--<includeonly>[[Category:Vahdai]]</includeonly>__NOEDITSECTION__\n<br>\n=<div id=\"toc\" class=\"toccolours\" ><big>[[Vahdai]] <small><small>(th)</small></small></big></div>=-->",
        "#REDIRECT [[Template:-th-]]",
        "[[Vahdai]]",
        "Vah{{{1}}}[[Category:Vah{{{1}}}]]",
    }) |source| try std.testing.expect(literalZhuangLanguageTemplate(source, "th") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const extra = try std.fmt.allocPrint(arena.allocator(), "{s}\nextra", .{ZaLiteralTemplateTest.templates[0].source});
    try std.testing.expect(literalZhuangLanguageTemplate(extra, "th") == null);
}

test "ZA indexed static aliases preserve registry conflicts and edition scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try ZaLiteralTemplateTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, ZaLiteralTemplateTest.namespaces);
    defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    for (ZaLiteralTemplateTest.templates) |row| {
        try std.testing.expectEqualStrings(row.code, registry.resolveTrusted(row.label).?.code);
        try std.testing.expectEqualStrings(row.code, registry.resolve(row.code).?.code);
    }
    try std.testing.expectEqualStrings("Daiyij", registry.resolveTrusted("Vahdai").?.heading);
    try std.testing.expectEqualStrings("Vah Sihbanhyaz", registry.resolveTrusted("Sihbanhyazyij").?.heading);
    try std.testing.expect(registry.resolveTrusted("Thai") == null);
    try std.testing.expect(registry.resolve("dai") == null);
    // A later competing local source makes the new alias unresolved forever.
    try registry.addLocalAlias("Vahdai", "es");
    try registry.addLocalAlias("Vahdai", "th");
    try std.testing.expect(registry.resolveTrusted("Vahdai") == null);
    var conflict = language_registry.Registry.empty(a);
    defer conflict.deinit();
    try conflict.addTsv(ZaLiteralTemplateTest.registry ++ "fr\tFazyij\tSihbanhyazyij\n");
    try loadLiteralLanguageTemplates(io, a, root, &namespaces, &conflict, .zhuang);
    try std.testing.expectEqualStrings("fr", conflict.resolve("Sihbanhyazyij").?.code);
    try std.testing.expect(conflict.resolveTrusted("Sihbanhyazyij") == null);
    // The same indexed templates are not ingested by a different edition.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\ten\n# mediawiki\nen\tEnglish\nes\tSpanish\nth\tThai\nzh-min-nan\tMin Nan Chinese\n" });
    var foreign = try loadLanguageRegistry(io, a, root, &namespaces);
    defer foreign.deinit();
    try std.testing.expect(foreign.resolveTrusted("Vahdai") == null);
    try std.testing.expect(foreign.resolveTrusted("Sihbanhyazyij") == null);
    try std.testing.expect(foreign.resolveTrusted("Vah Hozloz") == null);
}

test "ZA captured aliases retain two Australia owners and unresolved source controls through DPR2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try ZaLiteralTemplateTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, ZaLiteralTemplateTest.namespaces);
    defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    // Lexical regions from Australia p8796/r12635. Metadata-only interwiki
    // tails are omitted; both identical definitions must remain single-owner.
    const australia_raw = "{{-es-}}\n'''Australia''' \n\n# [[Audaihleihya]]\n\n{{-en-}}\n'''Australia''' \n\n# [[Audaihleihya]]\n\n";
    const australia_expanded = try std.fmt.allocPrint(a, "{s}\n'''Australia''' \n\n# [[Audaihleihya]]\n\n{s}\n'''Australia''' \n\n# [[Audaihleihya]]\n\n", .{ try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[1]), try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[3]) });
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Australia", australia_expanded, australia_raw, null);
    // ลม p8654/r12479 has this exact active L2 and parameterized L3.
    const lom_raw = "==Vahdai==\n\n==={{vah|dai}}===\n{{pn}} (lom)\n\n# [[rumz]]\n\n";
    const lom_expanded = "==Vahdai==\n\n===Vahdai[[Category:Vahdai]]===\n'''ลม''' (lom)\n\n# [[rumz]]\n\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ลม", lom_expanded, lom_raw, null);
    const pase_raw = "{{-zh-min-nan-}}\n'''Pa-se''' \n\n# [[Bahsih]]\n\n";
    const pase_expanded = try std.fmt.allocPrint(a, "{s}\n'''Pa-se''' \n\n# [[Bahsih]]\n\n", .{try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[2])});
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Pa-se", pase_expanded, pase_raw, null);
    // 广州 p8275/r11843 declares -zh- only in a comment. 壮语 p8269/r12470
    // has no declaration. Neither title/script nor interwiki links lend owners.
    const guangzhou = "<!--{{-zh-}}-->\n'''广州''' ([[廣州]])\n\n#[[Gvangjcouh]]\n\n[[en:广州]]\n[[fr:广州]]\n[[hu:广州]]\n[[mg:广州]]\n[[zh:广州]]";
    const zhuang = ":[saɯ˨˦ ʃu˨˦ eŋ˧]\n#[[Sawcuengh]]\n\n[[zh:壮语]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "广州", guangzhou, guangzhou, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "壮语", zhuang, zhuang, null);
    // New trusted labels must preserve a genuine owner at a different depth,
    // while heading-looking protected/table text stays within its live owner.
    const mixed_raw = "{{-es-}}\n# [[SpanishMixed]]\n==Vahdai==\n# [[ThaiMixed]]\n";
    const mixed_expanded = try std.fmt.allocPrint(a, "{s}\n# [[SpanishMixed]]\n==Vahdai==\n# [[ThaiMixed]]\n", .{try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[1])});
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed-depth-control", mixed_expanded, mixed_raw, null);
    const protected_body = "\n# [[ProtectedOwner]]\n<nowiki>\n==Vahdai==\n# [[protected-action]]\n</nowiki>\n<pre>\n==Vahdai==\n# [[pre-action]]\n</pre>\n{|\n|\n==Vahdai==\n[[table-action]]\n|}\n";
    const protected_raw = try std.fmt.allocPrint(a, "{{{{-es-}}}}{s}", .{protected_body});
    const protected_expanded = try std.fmt.allocPrint(a, "{s}{s}", .{ try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[1]), protected_body });
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "protected-control", protected_expanded, protected_raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 9), stats.language_records);
    const expected = [_][4][]const u8{
        .{ "es", "Vah Sihbanhyaz", "Australia", "Audaihleihya" },
        .{ "en", "Yinghyij", "Australia", "Audaihleihya" },
        .{ "th", "Daiyij", "ลม", "rumz" },
        .{ "zh-min-nan", "闽南语 (zh-min-nan)", "Pa-se", "Bahsih" },
        .{ "", "Unclassified", "广州", "Gvangjcouh" },
        .{ "", "Unclassified", "壮语", "Sawcuengh" },
        .{ "es", "Vah Sihbanhyaz", "mixed-depth-control", "SpanishMixed" },
        .{ "th", "Daiyij", "mixed-depth-control", "ThaiMixed" },
        .{ "es", "Vah Sihbanhyaz", "protected-control", "ProtectedOwner" },
    };
    for (expected) |entry| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(entry[1], &filename) }));
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(entry[0], metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(entry[2])).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(entry[0], decoded.entry.language_code);
        if (std.mem.eql(u8, entry[2], "Australia") or std.mem.eql(u8, entry[2], "Pa-se")) {
            const spanish = std.mem.eql(u8, entry[0], "es");
            const min_nan = std.mem.eql(u8, entry[0], "zh-min-nan");
            const label = if (spanish) "Sihbanhyazyij" else if (min_nan) "Vah Hozloz" else "Yinghyij";
            const heading = if (spanish) "Sihbanhyazyij (es)" else if (min_nan) "Vah Hozloz (zh-min-nan)" else "Yinghyij (en)";
            const anchor = if (spanish) "Sihbanhyazyij_(es)" else if (min_nan) "Vah_Hozloz_(zh-min-nan)" else "Yinghyij_(en)";
            const legacy = if (spanish) "Sihbanhyazyij_.28es.29" else if (min_nan) "Vah_Hozloz_.28zh-min-nan.29" else "Yinghyij_.28en.29";
            const iso = if (spanish) "(es)" else if (min_nan) "(zh-min-nan)" else "(en)";
            var headings: usize = 0;
            var companion_links: usize = 0;
            var small_codes: usize = 0;
            var bold_titles: usize = 0;
            for (decoded.entry.sections) |section| {
                if (std.mem.eql(u8, section.title, heading)) {
                    headings += 1;
                    try std.testing.expectEqual(@as(u8, 1), section.level);
                    try std.testing.expectEqualStrings(anchor, section.anchor);
                    try std.testing.expectEqualStrings(legacy, section.anchor_fallback);
                }
                for (section.blocks) |block| {
                    if (block.kind == .heading) {
                        try std.testing.expectEqual(@as(u8, 1), block.level);
                        try std.testing.expectEqualStrings(anchor, block.anchor);
                        try std.testing.expectEqualStrings(legacy, block.anchor_fallback);
                    }
                    for (block.spans) |span| {
                        if (std.mem.eql(u8, span.target, label)) {
                            companion_links += 1;
                            try std.testing.expectEqualStrings("toccolours", span.classes);
                        }
                        if (std.mem.eql(u8, span.text, iso)) {
                            small_codes += 1;
                            try std.testing.expect(!span.small);
                            try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 1.2), span.font_scale orelse return error.TestUnexpectedResult, 0.000001);
                            try std.testing.expectEqualStrings("toccolours", span.classes);
                        }
                        if (std.mem.eql(u8, span.text, entry[2]) and span.bold) bold_titles += 1;
                    }
                }
            }
            try std.testing.expectEqual(@as(usize, 1), headings);
            try std.testing.expectEqual(@as(usize, 1), companion_links);
            try std.testing.expectEqual(@as(usize, 1), small_codes);
            try std.testing.expectEqual(@as(usize, 1), bold_titles);
        }
        if (std.mem.eql(u8, entry[2], "ลม")) {
            var l2: usize = 0;
            var l3: usize = 0;
            var bold_title: usize = 0;
            var pronunciation: usize = 0;
            for (decoded.entry.sections) |section| {
                if (section.level == 2 and std.mem.eql(u8, section.title, "Vahdai")) {
                    l2 += 1;
                    try std.testing.expectEqualStrings("Vahdai", section.anchor);
                    try std.testing.expectEqual(@as(usize, 0), section.blocks.len);
                }
                if (section.level == 3 and std.mem.eql(u8, section.title, "Vahdai")) {
                    l3 += 1;
                    try std.testing.expectEqualStrings("Vahdai_2", section.anchor);
                }
                for (section.blocks) |block| for (block.spans) |span| {
                    if (std.mem.eql(u8, span.text, "ลม") and span.bold) bold_title += 1;
                    if (std.mem.eql(u8, span.text, " (lom)") and !span.bold) pronunciation += 1;
                };
            }
            try std.testing.expectEqual(@as(usize, 1), l2);
            try std.testing.expectEqual(@as(usize, 1), l3);
            try std.testing.expectEqual(@as(usize, 1), bold_title);
            try std.testing.expectEqual(@as(usize, 1), pronunciation);
        }
        var definitions: usize = 0;
        var target_links: usize = 0;
        for (decoded.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) {
                definitions += 1;
                try std.testing.expectEqualStrings("#", block.list_path);
                try std.testing.expectEqualStrings("1", block.number);
            }
            for (block.spans) |span| {
                try std.testing.expect(std.mem.indexOf(u8, span.text, "__NOEDITSECTION__") == null);
                if (std.mem.eql(u8, span.target, entry[3])) target_links += 1;
                if (std.mem.eql(u8, entry[0], "es")) try std.testing.expect(!std.mem.eql(u8, span.target, "Yinghyij"));
                if (std.mem.eql(u8, entry[0], "en")) try std.testing.expect(!std.mem.eql(u8, span.target, "Sihbanhyazyij"));
                if (std.mem.eql(u8, entry[2], "mixed-depth-control"))
                    try std.testing.expect(!std.mem.eql(u8, span.target, if (std.mem.eql(u8, entry[0], "es")) "ThaiMixed" else "SpanishMixed"));
                try std.testing.expect(!std.mem.eql(u8, span.target, "protected-action"));
                try std.testing.expect(!std.mem.eql(u8, span.target, "pre-action"));
            }
        };
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), target_links);
        if (entry[0].len == 0) try std.testing.expect((try index.find("Australia")) == null);
        if (!std.mem.eql(u8, entry[0], "es")) try std.testing.expect((try index.find("protected-control")) == null);
    }
}

test "ZA missing Portuguese prefix cannot be absorbed by a later Spanish alias" {
    const Mode = enum { tracked, absent, unknown };
    for ([_]Mode{ .tracked, .absent, .unknown }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try ZaLiteralTemplateTest.install(io, a, root);
        var namespaces = try namespace_registry.Registry.init(a, ZaLiteralTemplateTest.namespaces);
        defer namespaces.deinit();
        var registry = try loadLanguageRegistry(io, a, root, &namespaces);
        defer registry.deinit();
        const codes = languageCodes(&registry, &namespaces);
        const output = try std.fs.path.join(a, &.{ root, "blobs" });
        var writer = try encoder.blob_builder.Writer.init(io, a, output);
        defer writer.deinit();
        writer.language_codes = codes;
        // Brasil p8869/r12263: captured -pt- is absent. The actual baseline keeps
        // its missing-template link and first definition before the Spanish banner.
        // This source-instantiated fixture permits whole Unclassified retention or
        // a correct split; alias recovery must neither lose nor adopt that prefix.
        const raw = "{{-pt-}}\n'''Brasil''' \n\n# [[Bahsih]]\n\n{{-es-}}\n'''Brasil''' \n\n# [[Bahsih]]\n\n";
        const expanded = try std.fmt.allocPrint(a, "[[:模板:-pt-]]\n'''Brasil''' \n\n# [[Bahsih]]\n\n{s}\n'''Brasil''' \n\n# [[Bahsih]]\n\n", .{try ZaLiteralTemplateTest.banner(a, ZaLiteralTemplateTest.templates[1])});
        if (mode == .absent) {
            // Retain the original untracked regression, without weaker body counts.
            try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "Brasil", expanded, raw, null);
        } else {
            const metadata = try ZaLiteralTemplateTest.missingMetadata(a, expanded, mode == .unknown);
            try writer.addExpandedPageWithReasonsAndPhases(a, .{ .id = 0, .kind = .language }, "Brasil", expanded, raw, null, &.{}, null, metadata);
        }
        const stats = try writer.finish(codes);
        try std.testing.expect(stats.language_records == 1 or stats.language_records == 2);
        var unowned_filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var unowned_mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("Unclassified", &unowned_filename) }));
        defer unowned_mapped.deinit();
        const unowned_blob = try encoder.blob_format.inspect(unowned_mapped.bytes);
        const unowned_metadata = try unowned_blob.languageMetadata();
        var unowned_index = try unowned_blob.buildTrustedIndexAlloc(a);
        defer unowned_index.deinit(a);
        const unowned_record = (try unowned_index.find("Brasil")).?;
        const unowned = try encoder.presentation_codec.decodeAlloc(a, unowned_record.payload, unowned_record.title, .language, unowned_metadata);
        try std.testing.expectEqualStrings("", unowned.entry.language_code);
        var missing_links: usize = 0;
        var unowned_definitions: usize = 0;
        for (unowned.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) {
                unowned_definitions += 1;
                try std.testing.expectEqualStrings("Bahsih", block.spans[0].target);
            }
            for (block.spans) |span| if (std.mem.eql(u8, span.target, "模板:-pt-")) {
                missing_links += 1;
            };
        };
        try std.testing.expectEqual(@as(usize, 1), missing_links);
        try std.testing.expectEqual(@as(usize, if (stats.language_records == 1) 2 else 1), unowned_definitions);
        if (stats.language_records == 2) {
            var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
            var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("Vah Sihbanhyaz", &filename) }));
            defer mapped.deinit();
            const blob = try encoder.blob_format.inspect(mapped.bytes);
            const metadata = try blob.languageMetadata();
            var index = try blob.buildTrustedIndexAlloc(a);
            defer index.deinit(a);
            const record = (try index.find("Brasil")).?;
            const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expectEqualStrings("es", decoded.entry.language_code);
            var definitions: usize = 0;
            for (decoded.entry.sections) |section| for (section.blocks) |block| {
                if (block.kind == .definition) {
                    definitions += 1;
                    try std.testing.expectEqualStrings("Bahsih", block.spans[0].target);
                }
                for (block.spans) |span| try std.testing.expect(!std.mem.eql(u8, span.target, "模板:-pt-"));
            };
            try std.testing.expectEqual(@as(usize, 1), definitions);
        }
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
        const job: ExpansionJob = .{ .index_offset = 0, .ordinal = 99, .ns = .{ .id = 0, .kind = .language }, .title = "budget control", .source = source };
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

// Source-derived lexical control and typed invocation-error contract; not a
// captured expansion or an edition-based owner/pronunciation inference.
test "Writer retains typed invocation error beside MNI definition and translation" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const raw = "==[[ꯃꯤꯇꯩꯂꯣꯟ|ꯃꯤꯇꯩꯂꯣꯟ]]==\n\n==={{꯱}}===\n\n===ꯈꯣꯟꯊꯣꯛ===\n{{mni-pron|ꯂꯩꯌꯥꯠ}}\n\n# ꯂꯩꯄꯥꯛ ꯉꯥꯛꯄꯗ ꯌꯥꯎꯒꯗꯕ ꯃꯤꯍꯨꯠ ꯑꯃꯝ ꯑꯃꯝꯅ ꯀꯣꯟꯕ ꯃꯐꯝ ꯫\n----\n\n====ꯑꯇꯩ ꯂꯣꯟꯁꯤꯡꯗ====\n* [[ꯏꯪꯂꯤꯁ|ꯏꯪꯂꯤꯁ]]: {{t|en|Constituency}}\n\n[[ꯃꯆꯥꯈꯥꯏꯕ:ꯃꯤꯇꯩꯂꯣꯟ]]";
    const definition = "ꯂꯩꯄꯥꯛ ꯉꯥꯛꯄꯗ ꯌꯥꯎꯒꯗꯕ ꯃꯤꯍꯨꯠ ꯑꯃꯝ ꯑꯃꯝꯅ ꯀꯣꯟꯕ ꯃꯐꯝ ꯫";
    const expanded = "==[[ꯃꯤꯇꯩꯂꯣꯟ|ꯃꯤꯇꯩꯂꯣꯟ]]==\n===ꯈꯣꯟꯊꯣꯛ===\n<strong class=\"error\"><span class=\"scribunto-error\">Lua error in Module:mni-pron: The module did not return an export table.</span></strong>\n# ꯂꯩꯄꯥꯛ ꯉꯥꯛꯄꯗ ꯌꯥꯎꯒꯗꯕ ꯃꯤꯍꯨꯠ ꯑꯃꯝ ꯑꯃꯝꯅ ꯀꯣꯟꯕ ꯃꯐꯝ ꯫\n----\n====ꯑꯇꯩ ꯂꯣꯟꯁꯤꯡꯗ====\n* [[ꯏꯪꯂꯤꯁ|ꯏꯪꯂꯤꯁ]]: <span lang=\"en\">[[Constituency#English|Constituency]]</span>\n";
    const message = "Lua error in Module:mni-pron: The module did not return an export table.";
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# wikidict-language-registry-v2\n# content-language\tmni\n# mediawiki\nen\tꯏꯪꯂꯤꯁ\tEnglish\ten\teng\nmni\tꯃꯤꯇꯩ ꯂꯣꯟ\tmni\tManipuri\n");
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\tmniwiktionary\n# dump-date\t20261001\n# content-language\tmni\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n10\tꯇꯦꯝꯄ꯭ꯂꯦꯠ\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tTemplate\n14\tꯃꯆꯥꯈꯥꯏꯕ\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tCategory\n"); defer namespaces.deinit();
    try std.testing.expect(registry.resolve("ꯃꯤꯇꯩꯂꯣꯟ") == null);
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mni-invoke-body", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ꯂꯩꯌꯥꯠ", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    const path = try encoder.blob_builder.languageBlobPathAlloc(a, output, "Unclassified");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    const blob = try encoder.blob_format.inspect(bytes);
    var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
    const record = (try index.find("ꯂꯩꯌꯥꯠ")).?;
    const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
    try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
    try std.testing.expectEqualStrings("", stored.entry.language_code);
    try std.testing.expectEqual(@as(usize, 3), stored.entry.sections.len);
    var errors: usize = 0;
    var definitions: usize = 0;
    var translations: usize = 0;
    for (stored.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
        if (std.mem.eql(u8, span.text, message)) {
            errors += 1;
            try std.testing.expect(span.bold);
            try std.testing.expectEqualStrings("error scribunto-error", span.classes);
            try std.testing.expect(span.kind == .text);
            try std.testing.expectEqualStrings("", span.target);
        }
        if (std.mem.eql(u8, span.text, definition)) definitions += 1;
        if (span.kind == .link and std.mem.eql(u8, span.text, "Constituency")) {
            translations += 1;
            try std.testing.expectEqualStrings("Constituency#English", span.target);
            try std.testing.expectEqualStrings("en", span.language);
        }
        try std.testing.expect(std.mem.indexOf(u8, span.text, "{{") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), errors);
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), translations);
    const fallback = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{output, "fallback-pages.jsonl"}), a, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, fallback, "rendered_lua_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "expansion_error") == null);
}

const GnRegistryApplicabilityFixture = struct {
    // Exact relevant GN snapshot rows; aliases retain the real Registry trust policy.
    const registry = "# content-language\tgn\n# mediawiki\ngn\tAvañe'ẽ\tgn\tGuarani\tgrn\nen\tinglés\tInglés\tEnglish\ten\teng\n";
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tgnwiktionary\n# dump-date\t20261001\n# content-language\tgn\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n" ++
        "10\tTembiecharã\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "14\tÑemohenda\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n";
    fn load(io: std.Io, a: std.mem.Allocator, root: []const u8, ns: *const namespace_registry.Registry) !language_registry.Registry {
        try std.Io.Dir.cwd().createDirPath(io, root);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        return loadLanguageRegistry(io, a, root, ns);
    }
    fn entry(io: std.Io, a: std.mem.Allocator, output: []const u8, heading: []const u8, title: []const u8) !encoder.presentation_types.Entry {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        const blob = try encoder.blob_format.inspect(bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)).?;
        const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
        return stored.entry;
    }
};

test "GN captured registry and namespace do not promote ordinary target aliases" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var ns = try namespace_registry.Registry.init(a, GnRegistryApplicabilityFixture.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gn-input", .{tmp.sub_path});
    var registry = try GnRegistryApplicabilityFixture.load(io, a, input, &ns); defer registry.deinit();
    try std.testing.expectEqualStrings("gn", registry.resolve("Guarani").?.code);
    try std.testing.expect(registry.resolve("guarani") == null);
    try std.testing.expect(registry.resolveTrusted("Guarani") == null);
    try std.testing.expect(registry.resolveTrusted("guarani") == null);
    try std.testing.expect(registry.resolveStrong("Guarani") == null);
    try std.testing.expect(registry.resolveStrong("guarani") == null);
    try std.testing.expectEqualStrings("gn", registry.resolveTrusted("Avañe'ẽ").?.code);
    const normalized = try ns.normalizeTitle(a, "guarani", 0, .any);
    try std.testing.expectEqualStrings("guarani", normalized);
    try std.testing.expect(registry.resolve(normalized) == null);
    const codes = languageCodes(&registry, &ns);
    try std.testing.expect(codes.resolveTrusted("guarani") == null);
    try std.testing.expectEqualStrings("gn", codes.resolveTrusted("Avañe'ẽ").?.code);
}


const GnRawBannerFixture = struct {
    const banner = "<div id=\"gn\" class=\"toccolours\" >'''[[guarani|Avañe'ẽ]]'''</div>";
    const lexical = "\n==Tero==\n;1: '''[[tembiapo|Tembiapo]]''' ipýpe [[ava]] oiko hag̃ua.\n;2: [[tapỹi|Tapỹi]] guasu. [[#Tero_2|later]]\n";
    const expanded = "=" ++ banner ++ "=" ++ lexical;
    const raw = "{{-gn-}}" ++ lexical;
    fn full(a: std.mem.Allocator, title: []const u8, source: []const u8, ns: *const namespace_registry.Registry) !encoder.presentation_types.Entry {
        const payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, title, .language, "Unclassified", "", source, null, .{}, ns, null);
        return (try encoder.presentation_codec.decodeAlloc(a, payload, title, .language, .{ .code = "", .heading = "Unclassified" })).entry;
    }
};

test "Writer raw prefix corroborates real registry banner and preserves later language regions" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var ns = try namespace_registry.Registry.init(a, GnRegistryApplicabilityFixture.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gn-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gn-output", .{tmp.sub_path});
    var registry = try GnRegistryApplicabilityFixture.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    const F = GnRawBannerFixture;
    // Exact template-derived frame with synthetic lexical controls. These
    // complete pages are not claimed as retained native expansions.
    const later = "==inglés==\n===Tero===\n# [[house]] [[#Tero|earlier]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "single-banner", F.expanded, F.raw, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed-banner", F.expanded ++ later, F.raw ++ later, null);
    const literal = "==Avañe'ẽ==\n# LITERAL_OWNER\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "literal-control", literal, literal, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    const single = try GnRegistryApplicabilityFixture.entry(io, a, output, "Avañe'ẽ", "single-banner");
    const gn = try GnRegistryApplicabilityFixture.entry(io, a, output, "Avañe'ẽ", "mixed-banner");
    const en = try GnRegistryApplicabilityFixture.entry(io, a, output, "inglés", "mixed-banner");
    const known = try GnRegistryApplicabilityFixture.entry(io, a, output, "Avañe'ẽ", "literal-control");
    try std.testing.expectEqualStrings("gn", single.language_code);
    try std.testing.expectEqualStrings("gn", gn.language_code);
    try std.testing.expectEqualStrings("en", en.language_code);
    try std.testing.expectEqualStrings("gn", known.language_code);
    const whole_single = try F.full(a, "single-banner", F.expanded, &ns);
    const whole_mixed = try F.full(a, "mixed-banner", F.expanded ++ later, &ns);
    try std.testing.expectEqual(@as(usize, 2), whole_single.sections.len);
    try std.testing.expectEqual(@as(usize, 4), whole_mixed.sections.len);
    try std.testing.expectEqualDeep(whole_single.sections, single.sections);
    try std.testing.expectEqualDeep(whole_mixed.sections[0..2], gn.sections);
    try std.testing.expectEqualDeep(whole_mixed.sections[2..], en.sections);
    try std.testing.expectEqualStrings("Tero_2", en.sections[1].anchor);
    try std.testing.expect(registry.resolve("guarani") == null);
    try std.testing.expect(registry.resolveTrusted("Guarani") == null);
}

test "Writer banner fallback rejects missing raw authority conflicts and unresolved peers" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var ns = try namespace_registry.Registry.init(a, GnRegistryApplicabilityFixture.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gn-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gn-negative", .{tmp.sub_path});
    var registry = try GnRegistryApplicabilityFixture.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    const F = GnRawBannerFixture;
    const Case = struct { title: []const u8, raw: []const u8, source: []const u8 };
    const cases = [_]Case{
        .{ .title = "no-raw", .raw = "", .source = F.expanded },
        .{ .title = "prefix-prose", .raw = "PROSE\n" ++ F.raw, .source = F.expanded },
        .{ .title = "protected-raw", .raw = "<nowiki>{{-gn-}}</nowiki>" ++ F.lexical, .source = F.expanded },
        .{ .title = "commented-raw", .raw = "<!--{{-gn-}}-->" ++ F.lexical, .source = F.expanded },
        .{ .title = "wrong-raw-code", .raw = "{{-en-}}" ++ F.lexical, .source = F.expanded },
        .{ .title = "wrong-id", .raw = F.raw, .source = "=<div id=\"en\" class=\"toccolours\" >'''[[guarani|Avañe'ẽ]]'''</div>=" ++ F.lexical },
        .{ .title = "ordinary-conflicting-target", .raw = F.raw, .source = "=<div id=\"gn\" class=\"toccolours\" >'''[[English|Avañe'ẽ]]'''</div>=" ++ F.lexical },
        .{ .title = "ordinary-display", .raw = F.raw, .source = "=<div id=\"gn\" class=\"toccolours\" >'''[[guarani|Guarani]]'''</div>=" ++ F.lexical },
        .{ .title = "wrong-display", .raw = F.raw, .source = "=<div id=\"gn\" class=\"toccolours\" >'''[[guarani|inglés]]'''</div>=" ++ F.lexical },
        .{ .title = "extra-text", .raw = F.raw, .source = "=" ++ F.banner ++ " EXTRA=" ++ F.lexical },
        .{ .title = "incomplete-wrapper", .raw = F.raw, .source = "=<div id=\"gn\" class=\"toccolours\" >'''[[guarani|Avañe'ẽ]]'''=" ++ F.lexical },
        .{ .title = "protected-heading", .raw = F.raw, .source = "=<nowiki>" ++ F.banner ++ "</nowiki>=" ++ F.lexical },
        .{ .title = "entity-frame", .raw = F.raw, .source = "=&lt;div id=\"gn\" class=\"toccolours\" &gt;'''[[guarani|Avañe'ẽ]]'''&lt;/div&gt;=" ++ F.lexical },
        .{ .title = "later-unresolved-peer", .raw = F.raw ++ "==Other support==\n# SUPPORT\n=Unresolved peer=\n# UNKNOWN\n", .source = F.expanded ++ "==Other support==\n# SUPPORT\n=Unresolved peer=\n# UNKNOWN\n" },
    };
    for (cases) |case| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.raw, null);
    var no_trust = codes; no_trust.trusted_fn = null; no_trust.strong_fn = null;
    writer.language_codes = no_trust;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "no-trust", F.expanded, F.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, cases.len + 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    for (cases) |case| {
        const actual = try GnRegistryApplicabilityFixture.entry(io, a, output, "Unclassified", case.title);
        try std.testing.expectEqualStrings("", actual.language_code);
        const whole = try F.full(a, case.title, case.source, &ns);
        try std.testing.expectEqualDeep(whole.sections, actual.sections);
    }
    const untrusted = try GnRegistryApplicabilityFixture.entry(io, a, output, "Unclassified", "no-trust");
    try std.testing.expectEqualStrings("", untrusted.language_code);
}

const TemplateCollisionFixture = struct {
    // Exact relevant JBO snapshot rows; aliases retain the real Registry trust policy.
    const registry = "# content-language\tjbo\n# mediawiki\nbau\tBada (Nigeria)\tbau\njbo\tla .lojban.\tLa .lojban.\tjbo\tLojban\nen\tEnglish\ten\teng\nde\tGerman\tDeutsch\tde\tdeu\tger\n";
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tjbowiktionary\n# dump-date\t20261001\n# content-language\tjbo\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n" ++
        "10\ttermo'a\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n" ++
        "14\tklesi\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n";
    fn load(io: std.Io, a: std.mem.Allocator, root: []const u8, ns: *const namespace_registry.Registry) !language_registry.Registry {
        try std.Io.Dir.cwd().createDirPath(io, root);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        return loadLanguageRegistry(io, a, root, ns);
    }
    fn entry(io: std.Io, a: std.mem.Allocator, output: []const u8, heading: []const u8, title: []const u8) !encoder.presentation_types.Entry {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        const blob = try encoder.blob_format.inspect(bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)).?;
        const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
        return stored.entry;
    }
};

test "Writer real registry isolates conflicting template codes without assigning the argument" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const F = TemplateCollisionFixture;
    var ns = try namespace_registry.Registry.init(a, F.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/collision-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/collision-output", .{tmp.sub_path});
    var registry = try F.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    try std.testing.expectEqualStrings("bau", registry.resolve("bau").?.code);
    try std.testing.expectEqualStrings("Bada (Nigeria)", registry.resolve("bau").?.heading);
    try std.testing.expectEqualStrings("jbo", registry.resolve("jbo").?.code);
    try std.testing.expect(registry.resolve("lojban.") == null);
    try std.testing.expect(registry.resolve("lojbo") == null);
    try std.testing.expect(registry.resolve("lojban") == null);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    // Source-derived heading and lexical excerpt, with synthetic mixed-page
    // controls. This is not a claim to replay an exact captured expansion.
    const lexical = "\n===gismu===\n'''nakni''' (rafsi [[nak#lojban.|nak]])\n# \n====xelfanva====\n* glibau: [[male#en|male]]\n";
    const raw = "== {{bau|jbo}} ==" ++ lexical;
    const expanded = "== lojban. ==" ++ lexical;
    const before = "==English==\n===gismu===\n# [[before]] [[#gismu_2|middle]]\n";
    const after = "==German==\n===gismu===\n# [[after]] [[#gismu_2|middle]]\n";
    const literal = "==Bada (Nigeria)==\n# [[literal]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "single-collision", expanded, raw, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed-collision", before ++ expanded ++ after, before ++ raw ++ after, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "literal-control", literal, literal, null);
    // An unrelated argument can have the same shape. Conservative isolation
    // does not prove that German owns this hypothetical English wrapper.
    const ambiguous = "==Decorative English label==\n# [[retained]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "generic-ambiguity", ambiguous, "=={{en|de}}==\n# [[retained]]\n", null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 6), stats.language_records);
    try std.testing.expectEqual(@as(usize, 4), stats.language_blobs);
    const single = try F.entry(io, a, output, "Unclassified", "single-collision");
    const unknown = try F.entry(io, a, output, "Unclassified", "mixed-collision");
    const en = try F.entry(io, a, output, "English", "mixed-collision");
    const de = try F.entry(io, a, output, "German", "mixed-collision");
    const known = try F.entry(io, a, output, "Bada (Nigeria)", "literal-control");
    const generic = try F.entry(io, a, output, "Unclassified", "generic-ambiguity");
    try std.testing.expectEqualStrings("", generic.language_code);
    try std.testing.expectEqualStrings("", single.language_code);
    try std.testing.expectEqualStrings("", unknown.language_code);
    try std.testing.expectEqualStrings("en", en.language_code);
    try std.testing.expectEqualStrings("de", de.language_code);
    try std.testing.expectEqualStrings("bau", known.language_code);
    const whole = struct {
        fn entry(alloc: std.mem.Allocator, title: []const u8, text: []const u8, catalog: *const namespace_registry.Registry) !encoder.presentation_types.Entry {
            const payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(alloc, title, .language, "Unclassified", "", text, null, .{}, catalog, null);
            return (try encoder.presentation_codec.decodeAlloc(alloc, payload, title, .language, .{ .code = "", .heading = "Unclassified" })).entry;
        }
    };
    const full_single = try whole.entry(a, "single-collision", expanded, &ns);
    const full_mixed = try whole.entry(a, "mixed-collision", before ++ expanded ++ after, &ns);
    try std.testing.expectEqualDeep((try whole.entry(a, "generic-ambiguity", ambiguous, &ns)).sections, generic.sections);
    try std.testing.expectEqual(@as(usize, 3), full_single.sections.len);
    try std.testing.expectEqual(@as(usize, 7), full_mixed.sections.len);
    try std.testing.expectEqualDeep(full_single.sections, single.sections);
    try std.testing.expectEqualDeep(full_mixed.sections[0..2], en.sections);
    try std.testing.expectEqualDeep(full_mixed.sections[2..5], unknown.sections);
    try std.testing.expectEqualDeep(full_mixed.sections[5..], de.sections);
    try std.testing.expectEqualStrings("gismu_2", unknown.sections[1].anchor);
    try std.testing.expectEqualStrings("gismu_3", de.sections[1].anchor);
    try std.testing.expect(registry.resolve("lojban.") == null);
}


test "Writer template code collision preserves corroborated owners and unrelated forms" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const F = TemplateCollisionFixture;
    var ns = try namespace_registry.Registry.init(a, F.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/controls-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/controls-output", .{tmp.sub_path});
    var registry = try F.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    const Case = struct { name: []const u8, raw: ?[]const u8, rendered: []const u8, owner: []const u8, code: []const u8 };
    const cases = [_]Case{
        .{ .name = "known-name-owner", .raw = "=={{bau|jbo}}==", .rendered = "Bada (Nigeria)", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "known-argument-owner", .raw = "=={{bau|jbo}}==", .rendered = "la .lojban.", .owner = "la .lojban.", .code = "jbo" },
        .{ .name = "known-other-owner", .raw = "=={{bau|jbo}}==", .rendered = "German", .owner = "German", .code = "de" },
        .{ .name = "ordinary-parameter", .raw = "=={{bau|plural}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "same-code", .raw = "=={{bau|bau}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "no-parameter", .raw = "=={{bau}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "ordinary-alias-argument", .raw = "=={{bau|Lojban}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "noncanonical-name", .raw = "=={{Bada (Nigeria)|jbo}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "named-argument", .raw = "=={{bau|lang=jbo}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "extra-argument", .raw = "=={{bau|jbo|plural}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "multiple-calls", .raw = "=={{bau}}{{jbo}}==", .rendered = "decorative label", .owner = "Bada (Nigeria)", .code = "bau" },
        .{ .name = "nested-call", .raw = "=={{bau|{{jbo}}}}==", .rendered = "decorative label", .owner = "Unclassified", .code = "" },
        .{ .name = "protected-call", .raw = "==<nowiki>{{bau|jbo}}</nowiki>==", .rendered = "decorative label", .owner = "Unclassified", .code = "" },
        .{ .name = "entity-call", .raw = "==&#123;&#123;bau|jbo&#125;&#125;==", .rendered = "decorative label", .owner = "Unclassified", .code = "" },
        .{ .name = "incomplete-call", .raw = "=={{bau|jbo==", .rendered = "decorative label", .owner = "Unclassified", .code = "" },
        .{ .name = "no-raw-authority", .raw = null, .rendered = "decorative label", .owner = "Unclassified", .code = "" },
    };
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "=={s}==\n# '''[[retained|body]]'''\n", .{case.rendered});
        const raw: ?[]const u8 = if (case.raw) |heading| try std.fmt.allocPrint(a, "{s}\n# '''[[retained|body]]'''\n", .{heading}) else null;
        if (raw) |raw_source| {
            try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.name, source, raw_source, null);
        } else {
            // This direct authored-source control supplies no template authority.
            try writer.addPage(a, .{ .id = 0, .kind = .language }, case.name, source, null);
        }
    }
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, cases.len), stats.language_records);
    for (cases) |case| {
        const stored = try F.entry(io, a, output, case.owner, case.name);
        try std.testing.expectEqualStrings(case.code, stored.language_code);
        const source = try std.fmt.allocPrint(a, "=={s}==\n# '''[[retained|body]]'''\n", .{case.rendered});
        const payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, case.name, .language, "Unclassified", "", source, null, .{}, &ns, null);
        const whole = try encoder.presentation_codec.decodeAlloc(a, payload, case.name, .language, .{ .code = "", .heading = "Unclassified" });
        try std.testing.expectEqualDeep(whole.entry.sections, stored.sections);
    }
}

test "Writer composed hidden template conflicts refuse unproved page ownership" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var ns = try namespace_registry.Registry.init(a, GnRegistryApplicabilityFixture.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/interaction-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/interaction-output", .{tmp.sub_path});
    var registry = try GnRegistryApplicabilityFixture.load(io, a, input, &ns); defer registry.deinit();
    // Additional exact rows from the same authenticated GN snapshot.
    try registry.addTsv("bau\tBada (Nigeria)\tbau\njbo\tlojban\tLojban\tLa .lojban.\tla .lojban.\tjbo\nde\talemán\tAlemán\tDeutsch\tde\tGerman\tdeu\tger\nadj\tAdioukrou\tadj\n");
    const codes = languageCodes(&registry, &ns);
    try std.testing.expect(registry.resolve("lojban.") == null);
    try std.testing.expectEqualStrings("bau", registry.resolve("bau").?.code);
    const F = GnRawBannerFixture;
    const raw_collision = "=={{bau|jbo}}==\n===gismu===\n# COLLISION_BODY [[#gismu_2|later]]\n";
    const rendered_collision = "==lojban.==\n===gismu===\n# COLLISION_BODY [[#gismu_2|later]]\n";
    const first = "==inglés==\n===gismu===\n# ENGLISH_BODY\n";
    const last = "==alemán==\n===gismu===\n# GERMAN_BODY\n";
    const Case = struct { title: []const u8, raw: []const u8, source: []const u8, unknown: bool };
    // Exact existing fixture shapes composed synthetically; these are not
    // retained native expansions or proof of positive JBO ownership.
    const cases = [_]Case{
        .{ .title = "gn-hidden", .raw = F.raw ++ raw_collision, .source = F.expanded ++ rendered_collision, .unknown = true },
        .{ .title = "known-l1-hidden", .raw = "=inglés=\n# ENGLISH_BODY\n" ++ raw_collision, .source = "=inglés=\n# ENGLISH_BODY\n" ++ rendered_collision, .unknown = true },
        .{ .title = "selected-argument", .raw = first ++ raw_collision ++ "{{#if:1|\n===<!--selected-->===\n# after|BAD}}\n" ++ last, .source = first ++ rendered_collision ++ "======\n# after\n" ++ last, .unknown = true },
        .{ .title = "protected", .raw = F.raw ++ "<nowiki>\n" ++ raw_collision ++ "</nowiki>\n", .source = F.expanded ++ "<nowiki>\n" ++ raw_collision ++ "</nowiki>\n", .unknown = false },
        .{ .title = "commented", .raw = F.raw ++ "<!--\n" ++ raw_collision ++ "-->\n", .source = F.expanded ++ "<!--\n" ++ raw_collision ++ "-->\n", .unknown = false },
        .{ .title = "nested", .raw = F.raw ++ "{{#if:|\n" ++ raw_collision ++ "|# KEPT\n}}", .source = F.expanded ++ "# KEPT\n", .unknown = false },
        .{ .title = "entity", .raw = F.raw ++ "==&#123;&#123;bau|jbo&#125;&#125;==\n# ENTITY\n", .source = F.expanded ++ "==&#123;&#123;bau|jbo&#125;&#125;==\n# ENTITY\n", .unknown = false },
        .{ .title = "noncanonical-name", .raw = F.raw ++ "=={{Bada (Nigeria)|jbo}}==\n# LABEL\n", .source = F.expanded ++ "==Decorative label==\n# LABEL\n", .unknown = false },
        .{ .title = "ordinary-argument", .raw = F.raw ++ "=={{bau|ordinary}}==\n# ORDINARY\n", .source = F.expanded ++ "==Decorative label==\n# ORDINARY\n", .unknown = false },
        .{ .title = "pos-support", .raw = F.raw ++ "{{-adj-}}\n# ADJECTIVE\n", .source = F.expanded ++ "==Adjective==\n# ADJECTIVE\n", .unknown = false },
    };
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    for (cases) |case| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, case.title, case.source, case.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, cases.len), stats.language_records);
    try std.testing.expectEqual(@as(usize, 2), stats.language_blobs);
    for (cases) |case| {
        const actual = try GnRegistryApplicabilityFixture.entry(io, a, output, if (case.unknown) "Unclassified" else "Avañe'ẽ", case.title);
        try std.testing.expectEqualStrings(if (case.unknown) "" else "gn", actual.language_code);
        const whole = try F.full(a, case.title, case.source, &ns);
        try std.testing.expectEqualDeep(whole.sections, actual.sections);
        if (std.mem.eql(u8, case.title, "selected-argument")) {
            try std.testing.expectEqual(@as(usize, 7), actual.sections.len);
            try std.testing.expectEqualStrings("gismu_2", actual.sections[3].anchor);
            try std.testing.expectEqualStrings("gismu_3", actual.sections[6].anchor);
        }
    }
}

const GorLiteralHeadingTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tgorwiktionary\n# dump-date\t20261001\n# content-language\tgor\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplat\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tDalala\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tgor\n# mediawiki\ngor\tBahasa Hulontalo\tgor\tGorontalo\nen\tEnglish\tOrdinary English alias\n";
    // Retained Templat:gor p2925/r10737. Documentation is excluded before calls.
    const source = "bahasa Hulontalo<noinclude>[[Dalala:{{kat:kode bahasa}}]]</noinclude>";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tTemplat:gor\t\t2925\t10737\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root);
        defer writer.deinit();
        try writer.append(0, 2925, 10737, source);
        try writer.finish(index_path);
    }
};

test "GOR literal code template proves exact prefix and excludes complete documentation" {
    try std.testing.expectEqualStrings("bahasa Hulontalo", literalDocumentedLanguageTemplate(GorLiteralHeadingTest.source).?);
    try std.testing.expectEqualStrings("Literal Name", literalDocumentedLanguageTemplate("Literal Name<noinclude>{{any documentation}} [[Category:Any topic]]</noinclude>").?);
    for ([_][]const u8{
        "{{dynamic}}<noinclude>docs</noinclude>", "Label&amp;Other<noinclude>docs</noinclude>",
        "''Label''<noinclude>docs</noinclude>",
        "[[Label]]<noinclude>docs</noinclude>", "Label<noinclude>docs", "Label<noinclude>docs</noinclude>extra",
        "Label<noinclude><onlyinclude>Other</onlyinclude></noinclude>",
        "Label<noinclude><!-- </noinclude> -->", "Label<noinclude>nested<noinclude>other</noinclude></noinclude>",
        "Label<noinclude/>", "Label<noinclude attr='x'>docs</noinclude>", "Label\nOther<noinclude>docs</noinclude>",
    }) |source| try std.testing.expect(literalDocumentedLanguageTemplate(source) == null);
}

test "GOR indexed literal alias preserves ordinary aliases conflicts and edition scope" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try GorLiteralHeadingTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, GorLiteralHeadingTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    try std.testing.expectEqualStrings("gor", registry.resolveTrusted("bahasa Hulontalo").?.code);
    try std.testing.expectEqualStrings("Bahasa Hulontalo", registry.resolveTrusted("bahasa Hulontalo").?.heading);
    try std.testing.expect(registry.resolveTrusted("Gorontalo") == null);
    try std.testing.expect(registry.resolveTrusted("Ordinary English alias") == null);
    try registry.addLocalAlias("bahasa Hulontalo", "en");
    try registry.addLocalAlias("bahasa Hulontalo", "gor");
    try std.testing.expect(registry.resolveTrusted("bahasa Hulontalo") == null);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\ten\n# mediawiki\ngor\tBahasa Hulontalo\nen\tEnglish\n" });
    var foreign = try loadLanguageRegistry(io, a, root, &namespaces); defer foreign.deinit();
    try std.testing.expect(foreign.resolveTrusted("bahasa Hulontalo") == null);
}

test "Writer trusted language link ignores only hidden category metadata and preserves typed content" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try GorLiteralHeadingTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, GorLiteralHeadingTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const behavior_source = "# wikidict-behavior-switches-v1\n# wiki\tgorwiktionary\n# dump-date\t20261001\n# content-language\tgor\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\nnotoc\t0\t__NOTOC__\nnotoc\t1\tSoft\nnotoc\t0\t＿＿目次非表示＿＿\n";
    var behavior = try namespace_registry.behavior_switches.Registry.init(a, behavior_source, "gorwiktionary", "20261001", "gor", @splat(0)); defer behavior.deinit();
    var codes = languageCodes(&registry, &namespaces); codes.behavior_switches = &behavior;
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    // Source-instantiated heading fixture from Hulontalo + gor, not runtime expansion.
    const positive = "==[[bahasa Hulontalo]][[Dalala:Tahe bahasa Hulontalo]]==\n# [[tuwawu]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "retained-heading", positive, "=={{Hulontalo}}==\n# [[tuwawu]]\n", null);
    // A registered different language inside hidden metadata cannot choose the owner.
    const topic = "==[[bahasa Hulontalo]][[Dalala:English|sort]][[Category:Unrelated topic]]==\n# [[tuwawu]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "topic-control", topic, topic, null);
    const negatives = [_][]const u8{
        "[[bahasa Hulontalo]][[:Dalala:Topic]]", "[[bahasa Hulontalo]][[Dalala:Topic]]trail",
        "[[bahasa Hulontalo]] prose [[Dalala:Topic]]", "[[bahasa Hulontalo]][[English]]",
        "[[Gorontalo]][[Dalala:Bahasa Hulontalo]]", "[[Unknown]][[Dalala:Bahasa Hulontalo]]",
        "[[bahasa Hulontalo|visible prose]][[Dalala:Topic]]", "[[bahasa Hulontalo]][[Dalala:Topic|[[nested]]]]",
        "[[bahasa Hulontalo]][[Dalala:Topic", "[[bahasa Hulontalo]][[NotCategory:Topic]]",
        "[[bahasa Hulontalo]][[Dalala:bad&lt;target]]",
        "[[bahasa Hulontalo]][[Dalala:__NOTOC__]]",
        "[[bahasa Hulontalo]][[Dalala:Soft]]",
        "[[bahasa Hulontalo]][[Dalala:＿＿目次非表示＿＿]]",
        "[[bahasa Hulontalo]][[Dalala:Topic]]''",
        "[[bahasa Hulontalo]][[Dalala:Topic]] \t'' [[Dalala:Other]]",
    };
    for (negatives, 0..) |heading, i| {
        const source = try std.fmt.allocPrint(a, "=={s}==\n# [[tuwawu]]\n", .{heading});
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "negative-{d}", .{i}), source, source, null);
    }
    const protected = "==English==\n# [[outer-meaning]]\n<nowiki>\n==[[bahasa Hulontalo]][[Dalala:Topic]]==\n</nowiki>\n{|\n|\n==[[bahasa Hulontalo]][[Dalala:Topic]]==\n|}\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "protected", protected, protected, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, negatives.len + 3), stats.language_records);
    for (0..negatives.len + 3) |i| {
        const language = if (i < 2) "Bahasa Hulontalo" else if (i == negatives.len + 2) "English" else "Unclassified";
        const code = if (i < 2) "gor" else if (i == negatives.len + 2) "en" else "";
        const title = if (i == 0) "retained-heading" else if (i == 1) "topic-control" else if (i == negatives.len + 2) "protected" else try std.fmt.allocPrint(a, "negative-{d}", .{i - 2});
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(language, &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find(title)).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(code, decoded.entry.language_code);
        const original_source = if (i == 0) positive else if (i == 1) topic else if (i == negatives.len + 2) protected else try std.fmt.allocPrint(a, "=={s}==\n# [[tuwawu]]\n", .{negatives[i - 2]});
        const whole_payload = try encoder.presentation_document.compileReportedWithBehaviorAlloc(a, title, .language, "Unclassified", "", original_source, null, .{}, &namespaces, &behavior, null);
        const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, title, .language, .{ .code = "", .heading = "Unclassified" });
        try std.testing.expectEqualDeep(whole.entry.sections, decoded.entry.sections);
        var meanings: usize = 0; var language_links: usize = 0; var heading_language_links: usize = 0;
        // Decoded Section stores the plain title; navigable title spans are a heading block.
        for (decoded.entry.sections) |section| {
            if (i < 2) try std.testing.expect(std.mem.indexOf(u8, section.title, "Tahe ") == null);
        }
        for (decoded.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, if (i == negatives.len + 2) "outer-meaning" else "tuwawu")) meanings += 1;
            if (std.mem.eql(u8, span.target, "bahasa Hulontalo")) {
                language_links += 1;
                if (block.kind == .heading) heading_language_links += 1;
            }
            if (i < 2) try std.testing.expect(std.mem.indexOf(u8, span.text, "Tahe ") == null);
        };
        try std.testing.expectEqual(@as(usize, 1), meanings);
        if (i < 2) {
            try std.testing.expectEqual(@as(usize, 1), language_links);
            try std.testing.expectEqual(@as(usize, 1), heading_language_links);
        }
        const encoded = try encoder.presentation_codec.encodeAlloc(a, decoded);
        try std.testing.expectEqualSlices(u8, record.payload, encoded);
    }
}

const QuSourceBannerTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tquwiktionary\n# dump-date\t20261001\n# content-language\tqu\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n10\tPlantilla\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tKatiguriya\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tqu\n# mediawiki\nqu\tRuna Simi\tqu\tQuechua\tque\nen\tEnglish\nsyn\tSenaya\nfr\tFrench\n";
    const template_raw = "__NOEDITSECTION__&lt;noinclude&gt;[[Category:Template|qu]]&lt;/noinclude&gt;&lt;includeonly&gt;[[Katiguriya:Runa simi|Runa]]&lt;/includeonly&gt;\n= [[runa simi|Runa simi]] (Qhichwa rimay) =";
    const raw = "{{-qu-}}\n{{-noun-}}\n{{pn}}\n# q'ispi [[puriqlla]], [[yakuchaq]]pa [[muksi]]n, [[upyay|upyanapaq]]\n{{-trad-}}\n{{(}}\n* {{de}}: {{trad|de|Wasser}}\n* {{chr}}: {{trad|chr|ᎠᎹ}}\n* {{fr}}: {{trad|fr|eau}}\n* {{el}}: {{trad|el|νερό}}\n* {{en}}: {{trad|en|water}}\n{{-}}\n* {{es}}: {{trad|es|agua}}\n* {{eo}}: {{trad|eo|akvo}}\n* {{nci}}: {{trad|nci|atl}}\n* {{vi}}: {{trad|vi|nước}}\n* {{pt}}: {{trad|pt|água}}\n{{)}}";
    const expanded = "__NOEDITSECTION__[[Katiguriya:Runa simi|Runa]]\n= [[runa simi|Runa simi]] (Qhichwa rimay) =\n__NOEDITSECTION__\n===Suti===\n'''yaku'''\n# q'ispi [[puriqlla]], [[yakuchaq]]pa [[muksi]]n, [[upyay|upyanapaq]]\n__NOEDITSECTION__\n====T'ikray Kay====\n{| border=0  width=100%\n|-\n|bgcolor=\"#FFFFE0\" valign=top width=48%|\n{|\n\n* Alimanya: <span lang=\"de\" xml:lang=\"de\">[[Wasser]]</span> <sup>[[:de:Wasser|(de)]]</sup>\n* Chiruki: <span lang=\"chr\" xml:lang=\"chr\">[[ᎠᎹ]]</span> <sup>[[:chr:ᎠᎹ|(chr)]]</sup>\n* Fransiya: <span lang=\"fr\" xml:lang=\"fr\">[[eau]]</span> <sup>[[:fr:eau|(fr)]]</sup>\n* Grigu: <span lang=\"el\" xml:lang=\"el\">[[νερό]]</span> <sup>[[:el:νερό|(el)]]</sup>\n* Inlish: <span lang=\"en\" xml:lang=\"en\">[[water]]</span> <sup>[[:en:water|(en)]]</sup>\n|}\n| width=1% |\n|bgcolor=\"#FFFFE0\" valign=top width=48%|\n{|\n\n* Ispaña: <span lang=\"es\" xml:lang=\"es\">[[agua]]</span> <sup>[[:es:agua|(es)]]</sup>\n* Ispirantu: <span lang=\"eo\" xml:lang=\"eo\">[[akvo]]</span> <sup>[[:eo:akvo|(eo)]]</sup>\n* Astika nawa: <span lang=\"nci\" xml:lang=\"nci\">[[atl]]</span> <sup>[[:nci:atl|(nci)]]</sup>\n* Witnam: <span lang=\"vi\" xml:lang=\"vi\">[[nước]]</span> <sup>[[:vi:nước|(vi)]]</sup>\n* Purtugal: <span lang=\"pt\" xml:lang=\"pt\">[[água]]</span> <sup>[[:pt:água|(pt)]]</sup>\n|}\n|}\n";
    const heading = "[[runa simi|Runa simi]] (Qhichwa rimay)";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tPlantilla:-qu-\t\t1739\t13231\t2021-08-03T10:16:49Z\tA\twikitext\t10\t1\t1\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root); defer writer.deinit();
        try writer.append(0, 1739, 13231, template_raw); try writer.finish(index_path);
    }
};

test "source language banner requires complete literal body and registry name agreement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var namespaces = try namespace_registry.Registry.init(a, QuSourceBannerTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(QuSourceBannerTest.registry);
    const decoded = try xml_decode.decodeSinglePassAlloc(a, QuSourceBannerTest.template_raw);
    const proof = source_language_banner.parse(decoded, &namespaces, null, &registry, "qu").?;
    try std.testing.expectEqualStrings(QuSourceBannerTest.heading, proof.heading); try std.testing.expectEqual(@as(u8, 1), proof.level);
    const l2 = source_language_banner.parse("== [[runa simi|Runa simi]] (Qhichwa rimay) ==", &namespaces, null, &registry, "qu").?;
    try std.testing.expectEqual(@as(u8, 2), l2.level);
    for ([_][]const u8{
        "= [[Noun|Noun]] =", "= [[English|English]] =", "= [[qu|qu]] =", "= [[runa simi|English]] =",
        "= [[runa simi|Runa simi]] ({{dynamic}}) =", "= [[{{{1}}}|Runa simi]] =",
        "<nowiki>= [[runa simi|Runa simi]] =</nowiki>", "<ref>= [[runa simi|Runa simi]] =</ref>",
        "{|\n|\n= [[runa simi|Runa simi]] =\n|}", "= [[runa simi|Runa simi]] =\nvisible extra",
        "= [[runa simi|Runa simi]] =\n= [[runa simi|Runa simi]] =",
        "<noinclude><onlyinclude>Wrong</onlyinclude></noinclude>\n= [[runa simi|Runa simi]] =",
        "<includeonly>[[:Katiguriya:Topic]]</includeonly>\n= [[runa simi|Runa simi]] =",
        "<includeonly>[[Katiguriya:__NOTOC__]]</includeonly>\n= [[runa simi|Runa simi]] =",
        "__TOC__\n= [[runa simi|Runa simi]] =",
    }) |source| try std.testing.expect(source_language_banner.parse(source, &namespaces, null, &registry, "qu") == null);
    try std.testing.expect(source_language_banner.parse("= [[Noun|Noun]] =", &namespaces, null, &registry, "syn") == null);
    // Captured aliases are syntactically unrestricted. Recognition alone must
    // not erase constructs interpreted earlier by ordinary transclusion.
    const behavior_header = "# wikidict-behavior-switches-v1\n# wiki\tquwiktionary\n# dump-date\t20261001\n# content-language\tqu\n# namespace-registry-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n";
    for ([_][]const u8{
        "<onlyinclude>Wrong</onlyinclude>", "<onlyinclude>", "</onlyinclude>",
        "{{dynamic}}", "[[Visible]]", "<noinclude>hidden</noinclude>", "&amp;", "''styled''", "|cell", "=heading",
    }) |alias| {
        const captured = try std.fmt.allocPrint(a, "{s}noeditsection\t1\t{s}\n", .{ behavior_header, alias });
        var behavior = try namespace_registry.behavior_switches.Registry.init(a, captured, "quwiktionary", "20261001", "qu", @splat(0));
        defer behavior.deinit();
        const input = try std.fmt.allocPrint(a, "{s}\n= [[runa simi|Runa simi]] (Qhichwa rimay) =", .{alias});
        try std.testing.expectEqual(@as(?usize, alias.len), try behavior.matchAt(a, input, 0));
        try std.testing.expect(source_language_banner.parse(input, &namespaces, &behavior, &registry, "qu") == null);
    }
    var normal_behavior = try namespace_registry.behavior_switches.Registry.init(a, behavior_header ++ "noeditsection\t1\t__NOEDITSECTION__\n", "quwiktionary", "20261001", "qu", @splat(0));
    defer normal_behavior.deinit();
    try std.testing.expect(source_language_banner.parse(decoded, &namespaces, &normal_behavior, &registry, "qu") != null);
    try registry.addTsv("xx\tConflicting\tRUNA SIMI\n");
    try std.testing.expect(source_language_banner.parse(decoded, &namespaces, null, &registry, "qu") == null);
}

test "indexed source banner proof does not promote aliases and retains later conflicts" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); try QuSourceBannerTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, QuSourceBannerTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    try std.testing.expect(registry.matchesSourceLanguageBanner("qu", QuSourceBannerTest.heading, 1));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("syn", QuSourceBannerTest.heading, 1));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("qu", QuSourceBannerTest.heading, 2));
    try std.testing.expect(registry.resolveTrusted("Runa simi") == null);
    try std.testing.expect(registry.resolveTrusted(QuSourceBannerTest.heading) == null);
    try registry.addLocalAlias("runa simi", "fr");
    try std.testing.expect(!registry.matchesSourceLanguageBanner("qu", QuSourceBannerTest.heading, 1));
}

test "Writer captured Quechua banner requires exact root invocation and preserves all typed source" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); try QuSourceBannerTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, QuSourceBannerTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces); const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    // Exact saved raw410/expanded1273 witness. This test replays captured data;
    // it does not claim a new template expansion or a whole-corpus build.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "yaku", QuSourceBannerTest.expanded, QuSourceBannerTest.raw, null);
    const controls = [_][]const u8{
        "", "{{-syn-}}\n", "{{-qu-|parameter}}\n", "prefix\n{{-qu-}}\n",
        "<!--{{-qu-}}-->\n", "<nowiki>{{-qu-}}</nowiki>\n", "<ref>{{-qu-}}</ref>\n", "{|\n|{{-qu-}}\n|}\n",
    };
    for (controls, 0..) |raw, i| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "root-control-{d}", .{i}), QuSourceBannerTest.expanded, raw, null);
    const stats = try writer.finish(codes); try std.testing.expectEqual(@as(usize, controls.len + 1), stats.language_records);
    for (0..controls.len + 1) |i| {
        const heading = if (i == 0) "Runa Simi" else "Unclassified";
        const title = if (i == 0) "yaku" else try std.fmt.allocPrint(a, "root-control-{d}", .{i - 1});
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata(); var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find(title)).?; const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (i == 0) "qu" else "", decoded.entry.language_code);
        var report: encoder.presentation_document.Fallbacks = .{};
        const whole_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, title, .language, heading, metadata.code, QuSourceBannerTest.expanded, null, .{}, &namespaces, &report);
        const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, title, .language, metadata);
        try std.testing.expectEqualDeep(whole.entry.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(whole.entry.references, decoded.entry.references);
        try std.testing.expectEqualDeep(whole.entry.media, decoded.entry.media);
        try std.testing.expectEqualStrings("Runa simi (Qhichwa rimay)", decoded.entry.sections[0].title);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}


test "Writer preserves same line noinclude table rows and stored actions" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    // Reuse the retained GN registry fixture solely as a portable declared-en
    // control. This does not assign any language to the WO failed page.
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv(GnRegistryApplicabilityFixture.registry);
    var namespaces = try namespace_registry.Registry.init(a, GnRegistryApplicabilityFixture.namespaces); defer namespaces.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/noinclude-table", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    const plain = "==inglés==\n===Noun===\n{| class=wikitable style=\"background-color:#e6e6fa\"\n| [[A|cell]] ''kept''\n|}\n# after [[B]]\n";
    const wrapped = "==inglés==\n===Noun===\n<noinclude>{| class=wikitable style=\"background-color:#e6e6fa\"</noinclude>\n| [[A|cell]] ''kept''\n|}\n# after [[B]]\n";
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "plain", plain, null);
    try writer.addPage(a, .{ .id = 0, .kind = .language }, "wrapped", wrapped, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
    const expected = try GnRegistryApplicabilityFixture.entry(io, a, output, "inglés", "plain");
    const actual = try GnRegistryApplicabilityFixture.entry(io, a, output, "inglés", "wrapped");
    try std.testing.expectEqualStrings("en", actual.language_code);
    try std.testing.expectEqualDeep(expected.sections, actual.sections);
    try std.testing.expectEqual(@as(usize, 2), actual.sections.len);
    try std.testing.expectEqual(@as(usize, 0), actual.sections[0].blocks.len);
    try std.testing.expectEqualStrings("Noun", actual.sections[1].title);
    try std.testing.expectEqual(@as(usize, 2), actual.sections[1].blocks.len);
    const table = actual.sections[1].blocks[0].table.?;
    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows[0].cells.len);
    var linked = false; var italic = false; var after = false;
    for (table.rows[0].cells[0].spans) |span| {
        if (span.kind == .link and std.mem.eql(u8, span.target, "A") and std.mem.eql(u8, span.text, "cell")) linked = true;
        if (std.mem.eql(u8, span.text, "kept") and span.italic) italic = true;
    }
    for (actual.sections[1].blocks[1].spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "B")) { after = true; };
    try std.testing.expect(linked and italic and after);
}

test "Writer classified owner survives Hausa support headings without changing source semantics" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\tha\n# mediawiki\nha\tHausa\nen\tEnglish\n" });
    var namespaces = try namespace_registry.Registry.init(a, "# wikidict-namespace-registry-v1\n# wiki\thawiktionary\n# dump-date\t20261001\n# content-language\tha\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n"); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    // Exact selected literal lines from kura p1824/r46648. Audio/reflist and
    // intervening paragraphs are not an executed expansion fixture. The source
    // has no numbered definition list: the Noun definitions must remain empty.
    const selected = "== Hausa ==\n==Suna==\n'''Ƙura''' tashin turbaya dalilin iska shine ƙura\n=== Noun ===\n'''kura''' ''f'', pl. '''kuraya'''\n==Misali==\n*Kura ta cinye rago a bayan gari\n";
    const english = "==English==\n===Verb===\n# [[english-meaning]]\n";
    const mixed = try std.mem.concat(a, u8, &.{ selected, english });
    const unresolved = "==Unknown label==\n===Noun===\n# [[unresolved-meaning]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "kura-selected", selected, selected, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed-control", mixed, mixed, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unresolved-control", unresolved, unresolved, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    const cases = [_]struct { title: []const u8, heading: []const u8, code: []const u8, source: []const u8, pos: []const u8, definitions: usize }{
        .{ .title = "kura-selected", .heading = "Hausa", .code = "ha", .source = selected, .pos = "Noun", .definitions = 0 },
        .{ .title = "mixed-control", .heading = "Hausa", .code = "ha", .source = selected, .pos = "Noun", .definitions = 0 },
        .{ .title = "mixed-control", .heading = "English", .code = "en", .source = english, .pos = "Verb", .definitions = 1 },
        .{ .title = "unresolved-control", .heading = "Unclassified", .code = "", .source = unresolved, .pos = "Noun", .definitions = 1 },
    };
    for (cases) |case| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(case.heading, &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find(case.title)).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(case.code, decoded.entry.language_code);
        try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes.len);
        const lexeme = decoded.entry.organization.lexemes[0];
        try std.testing.expectEqualStrings(if (case.code.len == 0) "" else case.heading, lexeme.language);
        try std.testing.expectEqualStrings(case.pos, lexeme.kind);
        try std.testing.expectEqual(case.definitions, lexeme.definitions.len);
        const whole_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, case.title, .language, case.heading, case.code, case.source, null, .{}, &namespaces, null);
        const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, case.title, .language, metadata);
        try std.testing.expectEqualDeep(whole.entry.sections, decoded.entry.sections);
        try std.testing.expectEqual(whole.entry.organization.lexemes[0].section, lexeme.section);
        try std.testing.expectEqualDeep(whole.entry.organization.lexemes[0].definitions, lexeme.definitions);
        try std.testing.expectEqualDeep(whole.entry.organization.lexemes[0].introduction, lexeme.introduction);
        try std.testing.expectEqualDeep(whole.entry.organization.lexemes[0].other_blocks, lexeme.other_blocks);
        try std.testing.expectEqualDeep(whole.entry.organization.lexemes[0].related_sections, lexeme.related_sections);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

// Private, unapplied normal Writer regression proposal. Static GA t/en header
// contract plus synthetic POS/fragment controls; no native capture is claimed.
const GaHtmlLanguageBoundaryFixture = struct {
    const registry = "# content-language\tga\n# mediawiki\nen\tBéarla\tEnglish\ten\teng\nga\tGaeilge\tga\tIrish\tgle\n";
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tgawiktionary\n# dump-date\t20261001\n# content-language\tga\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n" ++
        "6\tÍomhá\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n" ++
        "10\tTeimpléad\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tMúnla\n" ++
        "14\tCatagóir\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tRang\n";
    fn load(io: std.Io, a: std.mem.Allocator, root: []const u8, ns: *namespace_registry.Registry) !language_registry.Registry {
        try std.Io.Dir.cwd().createDirPath(io, root);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        return loadLanguageRegistry(io, a, root, ns);
    }
    fn entry(io: std.Io, a: std.mem.Allocator, root: []const u8, heading: []const u8, title: []const u8) !?encoder.presentation_types.Entry {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ root, "languages", encoder.blob_catalog.languageBlobFilename(heading, &filename) });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        const blob = try encoder.blob_format.inspect(bytes);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find(title)) orelse return null;
        const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, try blob.languageMetadata());
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
        return stored.entry;
    }
    fn requiredEntry(io: std.Io, a: std.mem.Allocator, root: []const u8, heading: []const u8, title: []const u8) !encoder.presentation_types.Entry {
        const actual = (try entry(io, a, root, heading, title)) orelse {
            std.debug.print("missing required language record: heading={s}, title={s}\n", .{ heading, title });
            return error.TestUnexpectedResult;
        };
        return actual;
    }
    fn whole(a: std.mem.Allocator, title: []const u8, text: []const u8, ns: *namespace_registry.Registry) !encoder.presentation_types.Entry {
        const payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, title, .language, "Unclassified", "", text, null, .{}, ns, null);
        return (try encoder.presentation_codec.decodeAlloc(a, payload, title, .language, .{ .code = "", .heading = "Unclassified" })).entry;
    }
    fn targetCount(value: encoder.presentation_types.Entry, target: []const u8) usize {
        var count: usize = 0;
        for (value.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, target)) count += 1;
        };
        return count;
    }
};

test "Writer admitted plain HTML h2 preserves trusted language and complete typed meanings" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io; const F = GaHtmlLanguageBoundaryFixture;
    var ns = try namespace_registry.Registry.init(a, F.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-output", .{tmp.sub_path});
    var registry = try F.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    try std.testing.expectEqualStrings("en", registry.resolveTrusted("Béarla").?.code);
    try std.testing.expect(registry.resolveTrusted("English") == null);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    // Static t|en header with synthetic POS headings; the three numbered
    // meanings are retained from Irish p1640/r53353.
    const source = "<h2 title=\"English\">Béarla</h2>\n===Noun===\n'''Irish'''\n#[[Gaeilge]].\n===Adjective===\n'''Irish'''\n#[[Éireannach]].\n#[[Gaelach]].\n";
    const raw = "{{t|en}}\n{{-ainm-|en}}\n'''Irish'''\n#[[Gaeilge]].\n{{-aid-|en}}\n'''Irish'''\n#[[Éireannach]].\n#[[Gaelach]].\n";
    inline for (.{ "Irish", "unrelated-title" }) |title|
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, title, source, raw, null);
    const equals = "==Béarla==\n# [[existing]]\n";
    const unknown = "==Unresolved label==\n# [[unknown]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "equals", equals, equals, null);
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unknown", unknown, unknown, null);
    _ = try writer.finish(codes);
    inline for (.{ "Irish", "unrelated-title" }) |title| {
        const actual = (try F.requiredEntry(io, a, output, "Béarla", title));
        try std.testing.expectEqualStrings("en", actual.language_code);
        try std.testing.expectEqualDeep((try F.whole(a, title, source, &ns)).sections, actual.sections);
        inline for (.{ "Gaeilge", "Éireannach", "Gaelach" }) |target|
            try std.testing.expectEqual(@as(usize, 1), F.targetCount(actual, target));
        try std.testing.expect((try F.entry(io, a, output, "Unclassified", title)) == null);
    }
    try std.testing.expectEqualStrings("en", (try F.requiredEntry(io, a, output, "Béarla", "equals")).language_code);
}

test "Writer HTML h2 boundary proposal preserves page domains and ordinary alias trust" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io; const F = GaHtmlLanguageBoundaryFixture;
    var ns = try namespace_registry.Registry.init(a, F.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-controls-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-controls-output", .{tmp.sub_path});
    var registry = try F.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    const known = "==Béarla==\n# [[known]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "known", known, known, null);
    const cases = [_][]const u8{
        "<h2>English</h2>\n# [[control]]\n", // Ordinary alias remains untrusted.
        "<h2>Unknown language label</h2>\n# [[control]]\n",
        "<!--\n<h2>Béarla</h2>\n-->\n# [[control]]\n",
        "<nowiki>\n<h2>Béarla</h2>\n</nowiki>\n# [[control]]\n",
        "<pre>\n<h2>Béarla</h2>\n</pre>\n# [[control]]\n",
        "<ref>\n<h2>Béarla</h2>\nreference text</ref>\n# [[control]]\n<references/>\n",
        "<span title='&lt;h2&gt;Béarla&lt;/h2&gt;'>attribute</span>\n# [[control]]\n",
        "<span title='<h2>Béarla</h2>'>attribute</span>\n# [[control]]\n",
        "&lt;h2&gt;Béarla&lt;/h2&gt;\n# [[control]]\n",
        "<h2>Béarla\n# [[control]]\n", // No complete pair.
        "<h2>Béarla<h2>Gaeilge</h2>\n# [[control]]\n",
        "prefix<h2>Béarla</h2>\n# [[control]]\n", // Initial scope is a whole line.
        "<h2>Béarla</h2>suffix\n# [[control]]\n",
        "<h2>\nBéarla\n</h2>\n# [[control]]\n",
        "<h1>Béarla</h1>\n# [[control]]\n",
        "<h3>Béarla</h3>\n# [[control]]\n",
        "<h2>Noun</h2>\n# [[control]]\n",
        "{|\n|\n<h2>Béarla</h2>\n|}\n# [[control]]\n",
        "<table><tr><td>\n<h2>Béarla</h2>\n</td></tr></table>\n# [[control]]\n",
        // A layout-shaped wrapper must keep its direct heading cell-local.
        "{|\n|\n{| class=wikitable\n| nested\n|}\n<h2>Béarla</h2>\n|}\n# [[control]]\n",
        // The layout precheck skips a balanced label; recursive rendering still
        // cannot lend this cell's label heading to the original page domain.
        "{|\n|\n{| class=wikitable\n| nested\n|}\n[[link|\n<h2>Béarla</h2>\nlabel]]\n|}\n# [[control]]\n",
        "[[File:Uncaptured.svg|thumb|\n<h2>Béarla</h2>\ncaption]]\n# [[control]]\n",
        "[[Catagóir:Unknown|\n<h2>Béarla</h2>\n]]\n# [[control]]\n",
        // Q06 inline noinclude block splicing recurses; its h2 stays non-root.
        "prefix<noinclude>\n<h2>Béarla</h2>\n# [[inside]]\n</noinclude>\n# [[control]]\n",
    };
    for (cases, 0..) |source, index| {
        const title = try std.fmt.allocPrint(a, "control-{d}", .{index});
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, title, source, source, null);
    }
    // Two admitted raw regions include an exact en/ga template-code collision.
    // One rendered HTML region cannot pair them: existing whole-page recovery
    // must preserve both meanings as Unclassified, before rendered-owner fallback.
    const conflicting_raw = "=={{en|ga}}==\n# [[first-meaning]]\n==Gaeilge==\n# [[second-meaning]]\n";
    const conflicting_html = "<h2>Béarla</h2>\n# [[first-meaning]]\n# [[second-meaning]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "raw-conflict", conflicting_html, conflicting_raw, null);
    // Preserve the distinct existing policy for an unadmitted unknown marker.
    // It does not become a raw boundary or force the whole-page collision path.
    const unsupported_raw = "{{=unknown=}}\n# [[first-meaning]]\n{{=ga=}}\n# [[second-meaning]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unsupported-raw", conflicting_html, unsupported_raw, null);
    _ = try writer.finish(codes);
    const conflicting = (try F.requiredEntry(io, a, output, "Unclassified", "raw-conflict"));
    try std.testing.expectEqualStrings("", conflicting.language_code);
    try std.testing.expect((try F.entry(io, a, output, "Béarla", "raw-conflict")) == null);
    try std.testing.expectEqualDeep((try F.whole(a, "raw-conflict", conflicting_html, &ns)).sections, conflicting.sections);
    inline for (.{ "first-meaning", "second-meaning" }) |target|
        try std.testing.expectEqual(@as(usize, 1), F.targetCount(conflicting, target));
    const unsupported = try F.requiredEntry(io, a, output, "Béarla", "unsupported-raw");
    try std.testing.expectEqualStrings("en", unsupported.language_code);
    try std.testing.expect((try F.entry(io, a, output, "Unclassified", "unsupported-raw")) == null);
    try std.testing.expectEqualDeep((try F.whole(a, "unsupported-raw", conflicting_html, &ns)).sections, unsupported.sections);
    inline for (.{ "first-meaning", "second-meaning" }) |target|
        try std.testing.expectEqual(@as(usize, 1), F.targetCount(unsupported, target));
    const reports = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ output, "fallback-pages.jsonl" }), a, .limited(1024 * 1024));
    var report_lines = std.mem.splitScalar(u8, reports, '\n');
    var unsupported_warning = false;
    while (report_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"title\":\"unsupported-raw\"") != null and
            std.mem.indexOf(u8, line, "\"unresolved_language_heading\"") != null) unsupported_warning = true;
    }
    try std.testing.expect(unsupported_warning);
    for (cases, 0..) |source, index| {
        const title = try std.fmt.allocPrint(a, "control-{d}", .{index});
        const actual = (try F.requiredEntry(io, a, output, "Unclassified", title));
        try std.testing.expectEqualStrings("", actual.language_code);
        try std.testing.expect((try F.entry(io, a, output, "Béarla", title)) == null);
        try std.testing.expectEqualDeep((try F.whole(a, title, source, &ns)).sections, actual.sections);
    }
    try std.testing.expect(registry.resolveTrusted("English") == null);
}

test "Writer mixed HTML and equals language boundaries keep typed regions and global anchors" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io; const F = GaHtmlLanguageBoundaryFixture;
    var ns = try namespace_registry.Registry.init(a, F.namespaces); defer ns.deinit();
    const input = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-mixed-input", .{tmp.sub_path});
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ga-html-mixed-output", .{tmp.sub_path});
    var registry = try F.load(io, a, input, &ns); defer registry.deinit();
    const codes = languageCodes(&registry, &ns);
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    const source = "<h2 title=\"English\">Béarla</h2>\n===Noun===\n# [[Gaeilge]] [[#Noun_2|later]]\n==Gaeilge==\n===Noun===\n# [[Éireannach]] [[#Noun|earlier]]\n";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "mixed", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    const english = (try F.requiredEntry(io, a, output, "Béarla", "mixed"));
    const irish = (try F.requiredEntry(io, a, output, "Gaeilge", "mixed"));
    const full = try F.whole(a, "mixed", source, &ns);
    try std.testing.expectEqualDeep(full.sections[0..2], english.sections);
    try std.testing.expectEqualDeep(full.sections[2..], irish.sections);
    try std.testing.expectEqualStrings("Noun_2", irish.sections[1].anchor);
    try std.testing.expectEqual(@as(usize, 1), F.targetCount(english, "Gaeilge"));
    try std.testing.expectEqual(@as(usize, 0), F.targetCount(irish, "Gaeilge"));
    try std.testing.expectEqual(@as(usize, 0), F.targetCount(english, "Éireannach"));
    try std.testing.expectEqual(@as(usize, 1), F.targetCount(irish, "Éireannach"));
}

test "worker row address requires exact mapped row boundaries" {
    const rows = "# header\nfirst\nsecond";
    try std.testing.expectEqual(@as(u64, 9), try mappedPageIndexOffset(rows, rows[9..14]));
    try std.testing.expectEqual(@as(u64, 15), try mappedPageIndexOffset(rows, rows[15..]));
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, rows[0..8]));
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, rows[10..14]));
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, rows[9..13]));
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, rows[9..15]));
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, rows[rows.len..]));
    const detached = try std.testing.allocator.dupe(u8, rows[9..14]);
    defer std.testing.allocator.free(detached);
    try std.testing.expectError(error.InvalidPageIndex, mappedPageIndexOffset(rows, detached));
}

const FirstFailureControl = struct {
    const io = std.testing.io;
    const args = [_][]const u8{ "fixture.xml", "owned-output", "--workers", "1" };

    fn context(a: std.mem.Allocator, root: []const u8) FirstFailureCaptureContext {
        return .{ .io = io, .allocator = a, .output_root = root,
            // Deliberately nonexistent: capture must not scan input/tool files.
            .input = .{ .dump_path = "not-opened.xml", .expander_root = "not-opened-inputs", .tool_path = "not-opened-tool" },
            .requested_now_unix = 1791731560, .invocation_args = &args,
            .invocation_id = "0123456789abcdef0123456789abcdef" };
    }
    fn marker(a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, ".incomplete" }), .data = "building" });
    }
    fn manifest(a: std.mem.Allocator, root: []const u8) !std.json.Value {
        const path = try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "capture.json" });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024));
        return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    }
    fn absent(path: []const u8) !void {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return error.TestUnexpectedResult else |err|
            try std.testing.expect(err == error.FileNotFound);
    }
    fn noPublication(a: std.mem.Allocator, root: []const u8) !void {
        inline for (.{ encoder.blob_catalog.manifest_filename, "complete.json", "page-coverage.json", "namespace-coverage.json", "aliases.wikblb", "thesaurus.wikblb", "citations.wikblb", "supplemental.wikblb" }) |name|
            try absent(try std.fs.path.join(a, &.{ root, name }));
        const languages_path = try std.fs.path.join(a, &.{ root, "languages" });
        if (std.Io.Dir.cwd().openDir(io, languages_path, .{ .iterate = true })) |opened| {
            var languages = opened; defer languages.close(io);
            var entries = languages.iterate();
            try std.testing.expect(try entries.next(io) == null);
        } else |err| try std.testing.expect(err == error.FileNotFound);
    }
    fn payload(a: std.mem.Allocator, row: std.json.Value, name: []const u8, original: []const u8, cap: usize) !void {
        const value = row.object.get(name).?;
        const n = @min(cap, original.len);
        try std.testing.expect(value.object.get("present").?.bool);
        try std.testing.expectEqual(@as(i64, @intCast(original.len)), value.object.get("bytes").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(n)), value.object.get("retained_bytes").?.integer);
        try std.testing.expectEqual(n != original.len, value.object.get("truncated").?.bool);
        try std.testing.expectEqualStrings(try auditControlHash(a, original), value.object.get("sha256").?.string);
        if (original.len == 0) {
            try std.testing.expect(value.object.get("path").? == .null);
        } else {
            const path = value.object.get("path").?.string;
            try std.testing.expect(std.mem.startsWith(u8, std.fs.path.basename(path), "failure-00000001-"));
            const retained = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(cap + 1));
            try std.testing.expectEqualSlices(u8, original[0..n], retained);
        }
    }
    fn ignoreFileSize(_: std.posix.SIG) callconv(.c) void {}
    fn sameTree(a: std.mem.Allocator, left: []const u8, right: []const u8) anyerror!void {
        var ldir = try std.Io.Dir.cwd().openDir(io, left, .{ .iterate = true }); defer ldir.close(io);
        var rdir = try std.Io.Dir.cwd().openDir(io, right, .{ .iterate = true }); defer rdir.close(io);
        var entries = ldir.iterate(); var left_count: usize = 0;
        while (try entries.next(io)) |entry| {
            left_count += 1;
            const lpath = try std.fs.path.join(a, &.{ left, entry.name });
            const rpath = try std.fs.path.join(a, &.{ right, entry.name });
            switch (entry.kind) {
                .directory => try sameTree(a, lpath, rpath),
                .file => {
                    const lbytes = try std.Io.Dir.cwd().readFileAlloc(io, lpath, a, .limited(4 * 1024 * 1024));
                    const rbytes = try std.Io.Dir.cwd().readFileAlloc(io, rpath, a, .limited(4 * 1024 * 1024));
                    try std.testing.expectEqualSlices(u8, lbytes, rbytes);
                },
                else => return error.TestUnexpectedResult,
            }
        }
        var right_entries = rdir.iterate(); var right_count: usize = 0;
        while (try right_entries.next(io)) |_| right_count += 1;
        try std.testing.expectEqual(left_count, right_count);
    }
};

test "first failure snapshot retains normal Writer error inputs and outer receipt" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-normal");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    try std.testing.expect(first_failure_capture_context == null and failure_receipt_context == null);
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    const receipt = try std.fs.path.join(a, &.{ root, "outer-failure.json" });
    failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt, .invocation_id = F.context(a, root).invocation_id.?, .invocation_args = &F.args };
    defer failure_receipt_context = null;
    var writer = try encoder.blob_builder.Writer.init(F.io, a, root); defer writer.deinit();
    const job: ExpansionJob = .{ .ordinal = 17, .index_offset = 0, .ns = .{ .id = 0, .kind = .language },
        .title = "Fixture/../title", .source = "raw fixture", .page_id = 71, .revision_id = 91, .index_line = "exact index row\t71\t91" };
    const expanded: bundle_expander.Expansion = .{ .source = "[https:// broken", .display_title = "" };
    try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, expanded, a, null));
    const row = try F.manifest(a, root);
    try std.testing.expect(row.object.get("record_complete").?.bool);
    try std.testing.expect(!row.object.get("publication_created").?.bool);
    try std.testing.expectEqualStrings("UncompiledPresentation", row.object.get("error_name").?.string);
    try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 17), row.object.get("ordinal").?.integer);
    try std.testing.expectEqual(@as(i64, 0), row.object.get("index_offset").?.integer);
    try std.testing.expectEqual(@as(i64, 0), row.object.get("namespace").?.integer);
    try std.testing.expectEqual(@as(i64, 71), row.object.get("page_id").?.integer);
    try std.testing.expectEqual(@as(i64, 91), row.object.get("revision_id").?.integer);
    try F.payload(a, row, "raw_source", job.source, 256 * 1024);
    try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
    try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
    try F.payload(a, row, "display_title", "", 256 * 1024);
    try std.testing.expect(!row.object.get("poem_metadata").?.object.get("present").?.bool);
    const receipt_bytes = try std.Io.Dir.cwd().readFileAlloc(F.io, receipt, a, .limited(64 * 1024));
    const outer = try std.json.parseFromSliceLeaky(std.json.Value, a, receipt_bytes, .{});
    try std.testing.expectEqualStrings(outer.object.get("invocation_id").?.string, row.object.get("invocation_id").?.string);
    try std.testing.expectEqualStrings("UncompiledPresentation", outer.object.get("error_name").?.string);
    try std.testing.expectEqual(@as(i64, 71), outer.object.get("page").?.object.get("page_id").?.integer);
    // Retain the first capture even if a test caller deliberately supplies another failure.
    const before = try std.Io.Dir.cwd().readFileAlloc(F.io, try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "capture.json" }), a, .limited(64 * 1024));
    captureFirstPresentationFailure(error.UncompiledPresentation, job, .{ .source = "replacement" });
    const after = try std.Io.Dir.cwd().readFileAlloc(F.io, try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "capture.json" }), a, .limited(64 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expect(!std.mem.eql(u8, try invocationArgumentsHash(a, &.{ "a", "bc" }), try invocationArgumentsHash(a, &.{ "ab", "c" })));
    try F.noPublication(a, root);
    try std.Io.Dir.cwd().access(F.io, try std.fs.path.join(a, &.{ root, ".incomplete" }), .{});
}

test "first failure snapshot survives normal failed shard cleanup" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-shard");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    const shards = try std.fs.path.join(a, &.{ root, "shards" });
    try std.Io.Dir.cwd().createDir(F.io, shards, .default_dir);
    var shard = try PendingShard.init(F.io, a, shards, 0, 1, 0, .{});
    var closed = false; defer if (!closed) shard.deinit();
    const temporary = try a.dupe(u8, shard.temporary);
    const final = try a.dupe(u8, shard.final);
    const job: ExpansionJob = .{ .ordinal = 0, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = "Failed shard", .source = "raw fixture", .page_id = 1, .revision_id = 2 };
    try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&shard.writer.?, job, .{ .source = "before |} after" }, a, null));
    shard.deinit(); closed = true;
    try F.absent(temporary); try F.absent(final);
    try std.testing.expect((try F.manifest(a, root)).object.get("record_complete").?.bool);
    try std.Io.Dir.cwd().access(F.io, try std.fs.path.join(a, &.{ root, ".incomplete" }), .{});
    try F.noPublication(a, root);
}

test "ordinary sharded CLI capture survives raw shard and workspace retirement" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root = try auditControlFreshRoot(a, "ordinary-sharded-capture");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    const workspace = try std.fs.path.join(a, &.{ root, "edition.shards" });
    const raw = try std.fs.path.join(a, &.{ root, "edition.raw-shards" });
    const shard = try std.fs.path.join(a, &.{ raw, "00000000" });
    const evidence = try std.fs.path.join(a, &.{ root, "edition.shards.failures", "0123456789abcdef0123456789abcdef" });
    const receipt = try std.fs.path.join(a, &.{ evidence, "failure.json" });
    try std.Io.Dir.cwd().createDirPath(F.io, workspace);
    try std.Io.Dir.cwd().createDirPath(F.io, evidence);
    // This is the ordinary Python driver's argv shape, not --shard-pages.
    // Neither the writer nor that driver creates a marker in the raw shard.
    const args = [_][]const u8{ "dict-blob-build", "not-opened.xml", shard,
        "--expander-root", "not-opened-inputs", "--start-page", "0",
        "--limit-pages", "100000", "--index-byte-offset", "0", "--workers", "1",
        "--now-unix", "1791731560", "--failure-receipt", receipt,
        "--invocation-id", "0123456789abcdef0123456789abcdef" };
    const options = try parseOptions(&args);
    try std.testing.expect(options.shard_pages == null);
    try std.testing.expect(first_failure_capture_context == null and failure_receipt_context == null);
    first_failure_capture_context = FirstFailureCaptureContext.fromCli(F.io, a, &args, options);
    defer first_failure_capture_context = null;
    failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt,
        .invocation_id = options.invocation_id.?, .invocation_args = args[1..] };
    defer failure_receipt_context = null;
    try std.testing.expectEqualStrings(shard, first_failure_capture_context.?.output_root);
    try std.testing.expectEqualStrings(evidence, first_failure_capture_context.?.failure_evidence_root.?);
    try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
    const job: ExpansionJob = .{ .ordinal = 17, .index_offset = 9,
        .ns = .{ .id = 0, .kind = .language }, .title = "Synthetic shard failure",
        .source = "exact raw fixture", .page_id = 71, .revision_id = 91,
        .index_line = "exact synthetic index row" };
    const expanded: bundle_expander.Expansion = .{ .source = "before |} after" };
    {
        var writer = try encoder.blob_builder.Writer.init(F.io, a, shard); defer writer.deinit();
        try F.absent(try std.fs.path.join(a, &.{ shard, ".incomplete" }));
        try F.absent(try std.fs.path.join(a, &.{ workspace, ".incomplete" }));
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, expanded, a, null));
    }
    const capture = try std.fs.path.join(a, &.{ evidence, ".presentation-first-failure", "capture.json" });
    const before = try std.Io.Dir.cwd().readFileAlloc(F.io, capture, a, .limited(64 * 1024));
    const outer_before = try std.Io.Dir.cwd().readFileAlloc(F.io, receipt, a, .limited(64 * 1024));
    try F.absent(try std.fs.path.join(a, &.{ shard, ".presentation-first-failure" }));
    // Model normal retry/workspace retirement after the process exits. No
    // generated shard, input or workspace directory owns these diagnostics.
    try std.Io.Dir.cwd().deleteTree(F.io, raw);
    try std.Io.Dir.cwd().deleteTree(F.io, workspace);
    try F.absent(raw); try F.absent(workspace);
    const row = try F.manifest(a, evidence);
    try std.testing.expect(row.object.get("record_complete").?.bool);
    try std.testing.expect(row.object.get("diagnostic_only").?.bool);
    try std.testing.expect(!row.object.get("publication_created").?.bool);
    try std.testing.expect(!row.object.get("semantic_acceptance").?.bool);
    try std.testing.expectEqualStrings("UncompiledPresentation", row.object.get("error_name").?.string);
    try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 17), row.object.get("ordinal").?.integer);
    try std.testing.expectEqual(@as(i64, 9), row.object.get("index_offset").?.integer);
    try std.testing.expectEqual(@as(i64, 0), row.object.get("namespace").?.integer);
    try std.testing.expectEqual(@as(i64, 71), row.object.get("page_id").?.integer);
    try std.testing.expectEqual(@as(i64, 91), row.object.get("revision_id").?.integer);
    try F.payload(a, row, "raw_source", job.source, 256 * 1024);
    try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
    try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
    const outer = try std.json.parseFromSliceLeaky(std.json.Value, a, outer_before, .{});
    try std.testing.expectEqualStrings("wikidict.blob-build.failure.v1", outer.object.get("schema").?.string);
    try std.testing.expectEqualStrings("deterministic-presentation", outer.object.get("failure_class").?.string);
    const outer_args = outer.object.get("invocation_args").?.array.items;
    try std.testing.expectEqual(args.len - 1, outer_args.len);
    for (outer_args, args[1..]) |actual, expected| try std.testing.expectEqualStrings(expected, actual.string);
    try std.testing.expectEqualStrings(outer.object.get("invocation_id").?.string, row.object.get("invocation_id").?.string);
    try std.testing.expectEqualStrings(try invocationArgumentsHash(a, args[1..]), row.object.get("invocation_args_sha256").?.string);
    try std.testing.expectEqualStrings("UncompiledPresentation", outer.object.get("error_name").?.string);
    try std.testing.expectEqual(@as(i64, 71), outer.object.get("page").?.object.get("page_id").?.integer);
    captureFirstPresentationFailure(error.UncompiledPresentation, job, .{ .source = "replacement" });
    const after = try std.Io.Dir.cwd().readFileAlloc(F.io, capture, a, .limited(64 * 1024));
    const outer_after = try std.Io.Dir.cwd().readFileAlloc(F.io, receipt, a, .limited(64 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqualSlices(u8, outer_before, outer_after);
    try F.noPublication(a, evidence);
}

test "sharded capture destination requires matching invocation directory" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root = try auditControlFreshRoot(a, "ordinary-sharded-capture-scope");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    const shard = try std.fs.path.join(a, &.{ root, "00000000" });
    const unrelated = try std.fs.path.join(a, &.{ root, "other-invocation" });
    try std.Io.Dir.cwd().createDirPath(F.io, shard);
    try std.Io.Dir.cwd().createDirPath(F.io, unrelated);
    const receipt = try std.fs.path.join(a, &.{ unrelated, "failure.json" });
    const args = [_][]const u8{ "dict-blob-build", "not-opened.xml", shard,
        "--expander-root", "not-opened-inputs", "--failure-receipt", receipt,
        "--invocation-id", "0123456789abcdef0123456789abcdef" };
    const options = try parseOptions(&args);
    const context = FirstFailureCaptureContext.fromCli(F.io, a, &args, options);
    try std.testing.expect(context.failure_evidence_root == null);
    const job: ExpansionJob = .{ .ordinal = 0, .index_offset = 0,
        .ns = .{ .id = 0, .kind = .language }, .title = "Scope fixture", .source = "raw" };
    try std.testing.expectError(error.FileNotFound, writeFirstPresentationFailure(error.UncompiledPresentation, context, job, .{ .source = "expanded" }));
    try F.absent(try std.fs.path.join(a, &.{ shard, ".presentation-first-failure" }));
    try F.absent(try std.fs.path.join(a, &.{ unrelated, ".presentation-first-failure" }));
    // The pre-existing ordinary destination still works with its own marker.
    try F.marker(a, shard);
    try writeFirstPresentationFailure(error.UncompiledPresentation, context, job, .{ .source = "expanded" });
    try std.testing.expect((try F.manifest(a, shard)).object.get("record_complete").?.bool);
    try F.absent(try std.fs.path.join(a, &.{ unrelated, ".presentation-first-failure" }));
    try F.noPublication(a, shard);
}

test "first failure snapshot caps payloads with full hashes and bounded serialization" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-caps");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    const small = try a.alloc(u8, 256 * 1024 + 1); @memset(small, 'r');
    const large = try a.alloc(u8, 2 * 1024 * 1024 + 1); @memset(large, 'e');
    const title = try a.alloc(u8, 1025); @memset(title, 't');
    const job: ExpansionJob = .{ .ordinal = 4, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = title, .source = small, .index_line = small };
    try writeFirstPresentationFailure(error.UncompiledPresentation, F.context(a, root), job, .{ .source = large, .display_title = small, .poem_metadata = small, .missing_dependency_metadata = small });
    const row = try F.manifest(a, root);
    try std.testing.expect(row.object.get("record_complete").?.bool);
    try std.testing.expect(row.object.get("title_truncated").?.bool);
    try std.testing.expectEqualStrings(title[0..1024], row.object.get("title").?.string);
    try std.testing.expectEqualStrings(try auditControlHash(a, title), row.object.get("title_sha256").?.string);
    try F.payload(a, row, "raw_source", small, 256 * 1024);
    try F.payload(a, row, "expanded", large, 2 * 1024 * 1024);
    inline for (.{ "index_row", "display_title", "poem_metadata", "missing_dependency_metadata" }) |field|
        try F.payload(a, row, field, small, 256 * 1024);
    var total: i64 = 0;
    inline for (.{ "raw_source", "expanded", "index_row", "display_title", "poem_metadata", "missing_dependency_metadata", "alias_record" }) |field|
        total += row.object.get(field).?.object.get("retained_bytes").?.integer;
    try std.testing.expect(total <= 4 * 1024 * 1024);
    try std.testing.expectError(error.WriteFailed, writeDiagnosticJson(F.io, a, root, "too-large.json", .{ .oversized = small }, 64 * 1024));
    try F.absent(try std.fs.path.join(a, &.{ root, "too-large.json" }));
    const alias_root = try std.fs.path.join(a, &.{ root, "oversized-alias" });
    try std.Io.Dir.cwd().createDir(F.io, alias_root, .default_dir); try F.marker(a, alias_root);
    var alias_job = job;
    alias_job.alias_record = .{ .source_namespace = 0, .source_kind = .language,
        .source_title = small, .source_key = small, .xml_target = small, .target_title = small,
        .target_namespace = null, .target_kind = null, .target_key = "", .fragment = "", .presentation = "" };
    try std.testing.expectError(error.WriteFailed, writeFirstPresentationFailure(error.UncompiledPresentation, F.context(a, alias_root), alias_job, .{ .source = "reply" }));
    try std.testing.expect(!(try F.manifest(a, alias_root)).object.get("record_complete").?.bool);
    try F.noPublication(a, alias_root);
    try F.noPublication(a, root);
}

test "first failure snapshot I O refusal preserves the primary Writer error" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "missing-marker", "existing-capture" }) |label| {
        const root = try auditControlFreshRoot(a, "first-failure-" ++ label);
        defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
        const path = try std.fs.path.join(a, &.{ root, ".presentation-first-failure" });
        if (comptime std.mem.eql(u8, label, "existing-capture")) {
            try F.marker(a, root);
            try std.Io.Dir.cwd().writeFile(F.io, .{ .sub_path = path, .data = "do not overwrite" });
        }
        first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
        var writer = try encoder.blob_builder.Writer.init(F.io, a, root); defer writer.deinit();
        const job: ExpansionJob = .{ .ordinal = 8, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = "IO failure", .source = "raw" };
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = "[https:// broken" }, a, null));
        try std.testing.expect(first_failure_capture_context.?.attempted);
        if (comptime std.mem.eql(u8, label, "existing-capture")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(F.io, path, a, .limited(1024));
            try std.testing.expectEqualStrings("do not overwrite", bytes);
        } else try F.absent(path);
        try F.noPublication(a, root);
    }
}

test "first failure partial file write retains incomplete snapshot and primary error" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-partial");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    var writer = try encoder.blob_builder.Writer.init(F.io, a, root); defer writer.deinit();
    const raw = try a.alloc(u8, 2048); @memset(raw, 'x');
    const job: ExpansionJob = .{ .ordinal = 3, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = "Partial write", .source = raw };
    {
        // The repository test runner isolates each test in its own child. Never
        // lower a hard limit, and restore this child's soft limit and handler.
        const previous = try std.posix.getrlimit(.FSIZE);
        try std.testing.expect(previous.cur >= 1024 and previous.max >= 1024);
        var previous_action: std.posix.Sigaction = undefined;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = F.ignoreFileSize }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.XFSZ, &action, &previous_action);
        defer std.posix.sigaction(std.posix.SIG.XFSZ, &previous_action, null);
        try std.posix.setrlimit(.FSIZE, .{ .cur = 1024, .max = previous.max });
        defer std.posix.setrlimit(.FSIZE, previous) catch unreachable;
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&writer, job, .{ .source = "[https:// broken" }, a, null));
    }
    try std.testing.expect(!(try F.manifest(a, root)).object.get("record_complete").?.bool);
    const partial = try std.Io.Dir.cwd().readFileAlloc(F.io, try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "failure-00000001-raw.wikitext" }), a, .limited(2048));
    try std.testing.expect(partial.len > 0 and partial.len < raw.len);
    try std.testing.expectEqualSlices(u8, raw[0..partial.len], partial);
    try F.noPublication(a, root);
    try std.Io.Dir.cwd().access(F.io, try std.fs.path.join(a, &.{ root, ".incomplete" }), .{});
}

test "first failure capture leaves success unrelated errors and audit continuation unchanged" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-parity");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    var writer = try encoder.blob_builder.Writer.init(F.io, a, root); defer writer.deinit();
    const job: ExpansionJob = .{ .ordinal = 2, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = "ordinary control", .source = "valid text" };
    try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = job.source }, a, null));
    try std.testing.expectError(error.InvalidPoemMetadata, consumeExpandedPage(&writer, job, .{ .source = job.source, .poem_metadata = "{" }, a, null));
    try std.testing.expect(!first_failure_capture_context.?.attempted);
    try F.absent(try std.fs.path.join(a, &.{ root, ".presentation-first-failure" }));
    // Reuse the existing real audit sequence, including two strict failures,
    // successes, discarded partial owners, complete summary and capped payloads.
    try auditControlSequence(a, "first-failure-audit-parity", 8);
    try std.testing.expect(!first_failure_capture_context.?.attempted);
    try F.absent(try std.fs.path.join(a, &.{ root, ".presentation-first-failure" }));
    try F.noPublication(a, root);
}

test "first failure capture preserves complete successful Writer output bytes" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const root = try auditControlFreshRoot(a, "first-failure-success-bytes");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    const without = try std.fs.path.join(a, &.{ root, "without-capture" });
    const with = try std.fs.path.join(a, &.{ root, "with-capture" });
    const source = "==English==\n# valid [[control]] source\n";
    const job: ExpansionJob = .{ .ordinal = 0, .index_offset = 0, .ns = .{ .id = 0, .kind = .language }, .title = "Success", .source = source };
    try std.testing.expect(first_failure_capture_context == null);
    const baseline = blk: {
        var writer = try encoder.blob_builder.Writer.init(F.io, a, without); defer writer.deinit();
        writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
        try F.marker(a, without);
        try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = source }, a, null));
        break :blk try writer.finish(writer.language_codes);
    };
    {
        var writer = try encoder.blob_builder.Writer.init(F.io, a, with); defer writer.deinit();
        writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
        try F.marker(a, with);
        first_failure_capture_context = F.context(a, with); defer first_failure_capture_context = null;
        try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = source }, a, null));
        try std.testing.expectEqualDeep(baseline, try writer.finish(writer.language_codes));
        try std.testing.expect(!first_failure_capture_context.?.attempted);
    }
    try F.sameTree(a, without, with);
    try F.absent(try std.fs.path.join(a, &.{ with, ".presentation-first-failure" }));
}


test "Writer captured Macedonian z retains protected text and orphan math closers" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    // Exact production p3423/r47486/ordinal1351; raw and expanded are identical.
    const source = "[[Медија:\n== Пример.ogg ==\n[[''Наслов на врска''<nowiki>--~~~~Овде внесете неформатиран текст\n----\n<math>[[Медија:Овде вметни формула]]<math><nowiki>Овде вметни формула</nowiki>[[[Наслов на врска]]]</math></math></nowiki>]]]]";
    // Exact retained namespace snapshot, including the Media alias Медија.
    // Language callbacks are deliberately unbound: this is not language-ownership evidence.
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tmkwiktionary\n# dump-date\t20261001\n# content-language\tmk\n-2\tМедиум\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tМедија\n-1\tСпецијална\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tСпецијални\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tРазговор\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tКорисник\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n3\tРазговор со корисник\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n4\tВикиречник\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\n5\tРазговор за Викиречник\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tПодатотека\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tСлика\n7\tРазговор за податотека\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tРазговор за слика\n8\tМедијаВики\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tРазговор за МедијаВики\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n10\tПредлошка\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tШаблон\n11\tРазговор за предлошка\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tРазговор за шаблон\n12\tПомош\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tРазговор за помош\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n14\tКатегорија\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tРазговор за категорија\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tМодул\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tРазговор за модул\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    var ns = try namespace_registry.Registry.init(a, namespaces); defer ns.deinit();
    const codes: encoder.blob_builder.LanguageCodes = .{ .namespace_catalog = &ns };
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/mk-orphan-math", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "z", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    // Existing helper exercises normal Writer finish, trusted blob index, decoder and codec roundtrip.
    const entry = try GaHtmlLanguageBoundaryFixture.requiredEntry(io, a, output, "Unclassified", "z");
    try std.testing.expectEqual(@as(usize, 0), entry.media.len);
    var visible: std.ArrayList(u8) = .empty;
    for (entry.sections) |section| {
        try visible.appendSlice(a, section.title);
        for (section.blocks) |block| for (block.spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link or span.kind == .external_link) {
                try std.testing.expect(std.mem.indexOfAny(u8, span.target, "\r\n") == null);
                try std.testing.expect(std.mem.indexOf(u8, span.target, "Медија:") == null);
            }
        };
    }
    for ([_][]const u8{ "Пример.ogg", "Наслов на врска", "--~~~~", "Овде внесете неформатиран текст", "----", "<math>[[Медија:Овде вметни формула]]<math><nowiki>Овде вметни формула" }) |authored|
        try std.testing.expect(std.mem.indexOf(u8, visible.items, authored) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, visible.items, "</math>"));
}


test "Writer captured BCL malformed single-brace suffix retains body and actions" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    // Exact p8910/r30738/ordinal8466 captured input and output; no expansion replay.
    const raw = "===Pagsayod===\n/pag.ti.ri.pon/\n{{ png.|} pagpupulong\n\n===Pinaghalian===\n{{pref|bcl|pag|tiripon}}\n\n===Dakitaramon===\n*'''Ingles:''' assembly\n*'''Tagalog:''' pagpupulong";
    const expanded = "===Pagsayod===\n/pag.ti.ri.pon/\n{{ png.|} pagpupulong\n\n===Pinaghalian===\n<i class=\"Latn mention\" lang=\"bcl\">[[pag-#Bikol Sentral|pag-]]</i> +&lrm; <i class=\"Latn mention\" lang=\"bcl\">[[tiripon#Bikol Sentral|tiripon]]</i>[[Kategorya:Bikol Sentral tataramon na may prefixong pag-|TIRIPON]] \n\n===Dakitaramon===\n*'''Ingles:''' assembly\n*'''Tagalog:''' pagpupulong";
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tbclwiktionary\n# dump-date\t20261001\n# content-language\tbcl\n-2\tMedio\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tEspesyal\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tOlay\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n2\tParagamit\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n3\tOlay kan paragamit\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n4\tWiksyunaryo\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWiktionary\n5\tOlay sa Wiksyunaryo\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\n6\tLadawan\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n7\tOlay sa ladawan\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\n8\tMediaWiki\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n9\tOlay sa MediaWiki\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n10\tPlantilya\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n11\tOlay sa plantilya\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n12\tTabang\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tOlay sa tabang\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n14\tKategorya\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tOlay sa kategorya\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tModule\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tModule talk\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    var ns = try namespace_registry.Registry.init(a, namespaces); defer ns.deinit();
    // Callbacks intentionally unbound: this tests rendering, not language ownership.
    const codes: encoder.blob_builder.LanguageCodes = .{ .namespace_catalog = &ns };
    const output = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bcl-malformed-template", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "pagtiripon", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_pages);
    // Existing helper exercises Writer finish, trusted index, decoding and codec roundtrip.
    const entry = try GaHtmlLanguageBoundaryFixture.requiredEntry(io, a, output, "Unclassified", "pagtiripon");
    var visible: std.ArrayList(u8) = .empty;
    var actions: usize = 0;
    const expected_headings = [_][]const u8{ "Pagsayod", "Pinaghalian", "Dakitaramon" };
    var heading_count: usize = 0;
    for (entry.sections) |section| {
        if (section.title.len != 0) {
            try std.testing.expect(heading_count < expected_headings.len);
            try std.testing.expectEqualStrings(expected_headings[heading_count], section.title);
            try std.testing.expectEqual(@as(u8, 3), section.level);
            heading_count += 1;
        }
        try visible.appendSlice(a, section.title);
        for (section.blocks) |block| {
            for (block.spans) |span| {
                try visible.appendSlice(a, span.text);
                if (span.kind == .link or span.kind == .external_link) {
                    try std.testing.expect(span.kind == .link);
                    const expected_target: []const u8 = if (actions == 0) "pag-#Bikol Sentral" else "tiripon#Bikol Sentral";
                    const expected_label: []const u8 = if (actions == 0) "pag-" else "tiripon";
                    try std.testing.expectEqualStrings(expected_target, span.target);
                    try std.testing.expectEqualStrings(expected_label, span.text);
                    try std.testing.expect(span.italic);
                    actions += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), actions);
    try std.testing.expectEqual(@as(usize, 3), heading_count);
    for ([_][]const u8{ "Pagsayod", "Pinaghalian", "Dakitaramon", "/pag.ti.ri.pon/", "[malformed template] pagpupulong", "Ingles:", "assembly", "Tagalog:" }) |kept|
        try std.testing.expect(std.mem.indexOf(u8, visible.items, kept) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible.items, "[malformed template]"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, visible.items, "pagpupulong"));
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Kategorya:") == null);
    const report = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ output, "fallback-pages.jsonl" }), a, .limited(8192));
    var rows = std.mem.tokenizeScalar(u8, report, '\n');
    const row = try std.json.parseFromSlice(std.json.Value, a, rows.next() orelse return error.TestUnexpectedResult, .{});
    defer row.deinit();
    var literal_reason = false;
    for (row.value.object.get("reasons").?.array.items) |reason| if (std.mem.eql(u8, reason.string, "literal_markup")) { literal_reason = true; };
    try std.testing.expect(literal_reason and rows.next() == null);
}


test "Writer captured Punjabi act preserves escaped iframe and ordinary page actions" {
    var pa_tmp = std.testing.tmpDir(.{}); defer pa_tmp.cleanup();
    var pa_arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer pa_arena.deinit();
    const pa_alloc = pa_arena.allocator(); const pa_io = std.testing.io;
    // Exact PA02 p5034/r34824/ordinal2834; retained expansion, never replayed.
    const pa_raw_source = "==ਅੰਗਰੇਜ਼ੀ==\n===ਉਚਾਰਨ===\n{{pronunciation-audio-us-BE}}\n* \n\n\n<iframe src=\"//commons.wikimedia.org/wiki/File:En-us-act.ogg?embedplayer=yes\" width=\"175\" height=\"20\" frameborder=\"0\" webkitAllowFullScreen mozallowfullscreen allowFullScreen></iframe>\n\n===ਨਾਂਵ===\n'''act''' ਪੁਲਿੰਗ\n#[[ਕਨੂੰਨ]], ਅਧਿਨਿਯਮ,\n#ਕੰਮ, ਕਾਰਜ\n\n===ਕਿਰਿਆ===\n#ਕੰੰਮ ਕਰਨਾ , ਕਾਰਜ ਕਰਨਾ, ਵਿਹਾਰ ਕਰਨਾ, ਅਭਿਨੈ ਕਰਨਾ\n===ਹਵਾਲੇ===\n<ref>[https://web.archive.org/web/20190714163445/http://pupdepartments.ac.in/e2p/ ਅੰ-ਪੰ ਸ਼ਬਦ ਕੋਸ਼ , ਪੰਜਾਬੀ ਯੂਨੀਵਰਸਿਟੀ , ਪਟਿਆਲਾ]</ref>\n<ref>[http://dic.learnpunjabi.org/default.aspx ਪੰਜਾਬੀ ਸ਼ਬਦ ਕੋਸ਼ , ਪੰਜਾਬੀ ਯੂਨੀਵਰਸਿਟੀ , ਪਟਿਆਲਾ]</ref>";
    const pa_expanded_source = "==ਅੰਗਰੇਜ਼ੀ==\n===ਉਚਾਰਨ===\n*<strong class=\"error\"><span class=\"scribunto-error\">Lua error in ਮੌਡਿਊਲ:audio: Parameter 1 must be a valid language or etymology language code; the value \"En-us-act.ogg\" is not valid. See [[WT:LOL]] and [[WT:LOL/E]].</span></strong> [[ਸ਼੍ਰੇਣੀ:1000BasicEnglish+audio-us]]\n* \n\n\n<iframe src=\"//commons.wikimedia.org/wiki/File:En-us-act.ogg?embedplayer=yes\" width=\"175\" height=\"20\" frameborder=\"0\" webkitAllowFullScreen mozallowfullscreen allowFullScreen></iframe>\n\n===ਨਾਂਵ===\n'''act''' ਪੁਲਿੰਗ\n#[[ਕਨੂੰਨ]], ਅਧਿਨਿਯਮ,\n#ਕੰਮ, ਕਾਰਜ\n\n===ਕਿਰਿਆ===\n#ਕੰੰਮ ਕਰਨਾ , ਕਾਰਜ ਕਰਨਾ, ਵਿਹਾਰ ਕਰਨਾ, ਅਭਿਨੈ ਕਰਨਾ\n===ਹਵਾਲੇ===\n<ref>[https://web.archive.org/web/20190714163445/http://pupdepartments.ac.in/e2p/ ਅੰ-ਪੰ ਸ਼ਬਦ ਕੋਸ਼ , ਪੰਜਾਬੀ ਯੂਨੀਵਰਸਿਟੀ , ਪਟਿਆਲਾ]</ref>\n<ref>[http://dic.learnpunjabi.org/default.aspx ਪੰਜਾਬੀ ਸ਼ਬਦ ਕੋਸ਼ , ਪੰਜਾਬੀ ਯੂਨੀਵਰਸਿਟੀ , ਪਟਿਆਲਾ]</ref>";
    const pa_namespaces_source = "# wikidict-namespace-registry-v1\n# wiki\tpawiktionary\n# dump-date\t20261001\n# content-language\tpa\n-2\tਮੀਡੀਆ\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n-1\tਖ਼ਾਸ\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tਖਾਸ\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tਗੱਲ-ਬਾਤ\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਚਰਚਾ\n2\tਵਰਤੋਂਕਾਰ\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tਮੈਂਬਰ\tਵਰਤੌਂਕਾਰ\n3\tਵਰਤੋਂਕਾਰ ਗੱਲ-ਬਾਤ\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਮੈਂਬਰ ਚਰਚਾ\tਵਰਤੌਂਕਾਰ ਗੱਲ-ਬਾਤ\n4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\n5\tWiktionary ਗੱਲ-ਬਾਤ\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWiktionary talk\tWiktionary ਚਰਚਾ\n6\tਤਸਵੀਰ\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n7\tਤਸਵੀਰ ਗੱਲ-ਬਾਤ\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tਤਸਵੀਰ ਚਰਚਾ\n8\tਮੀਡੀਆਵਿਕੀ\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tਮੀਡੀਆਵਿਕਿ\n9\tਮੀਡੀਆਵਿਕੀ ਗੱਲ-ਬਾਤ\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਮੀਡੀਆਵਿਕਿ ਚਰਚਾ\n10\tਫਰਮਾ\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tਨਮੂਨਾ\n11\tਫਰਮਾ ਗੱਲ-ਬਾਤ\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਨਮੂਨਾ ਚਰਚਾ\n12\tਮਦਦ\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n13\tਮਦਦ ਗੱਲ-ਬਾਤ\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਮਦਦ ਚਰਚਾ\n14\tਸ਼੍ਰੇਣੀ\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\n15\tਸ਼੍ਰੇਣੀ ਗੱਲ-ਬਾਤ\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tਸ਼੍ਰੇਣੀ ਚਰਚਾ\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tਮੌਡਿਊਲ\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tਮੌਡਿਊਲ ਗੱਲ-ਬਾਤ\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvent\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvent talk\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    var pa_namespaces = try namespace_registry.Registry.init(pa_alloc, pa_namespaces_source); defer pa_namespaces.deinit();
    // No language-ownership claim: callbacks are deliberately unbound.
    const pa_codes: encoder.blob_builder.LanguageCodes = .{ .namespace_catalog = &pa_namespaces };
    const pa_output = try std.fmt.allocPrint(pa_alloc, ".zig-cache/tmp/{s}/pa-act-iframe", .{pa_tmp.sub_path});
    var pa_writer = try encoder.blob_builder.Writer.init(pa_io, pa_alloc, pa_output); defer pa_writer.deinit();
    pa_writer.language_codes = pa_codes;
    // Writer API is (title, expanded/source, raw_source), not the reverse.
    try pa_writer.addExpandedPage(pa_alloc, .{ .id = 0, .kind = .language }, "act", pa_expanded_source, pa_raw_source, null);
    const pa_stats = try pa_writer.finish(pa_codes);
    try std.testing.expectEqual(@as(usize, 1), pa_stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), pa_stats.fallback_pages);
    const pa_entry = try GaHtmlLanguageBoundaryFixture.requiredEntry(pa_io, pa_alloc, pa_output, "Unclassified", "act");
    var pa_visible: std.ArrayList(u8) = .empty;
    var pa_definitions: usize = 0;
    var pa_dictionary_actions: usize = 0;
    var pa_wt_actions: usize = 0;
    var pa_reference_markers: usize = 0;
    for (pa_entry.sections) |pa_section| {
        try pa_visible.appendSlice(pa_alloc, pa_section.title);
        for (pa_section.blocks) |pa_block| {
            if (pa_block.kind == .definition) pa_definitions += 1;
            for (pa_block.spans) |pa_span| {
                try pa_visible.appendSlice(pa_alloc, pa_span.text);
                if (pa_span.kind == .link) {
                    if (std.mem.eql(u8, pa_span.target, "ਕਨੂੰਨ")) {
                        pa_dictionary_actions += 1; try std.testing.expectEqualStrings("ਕਨੂੰਨ", pa_span.text);
                    } else if (std.mem.eql(u8, pa_span.target, "WT:LOL") or std.mem.eql(u8, pa_span.target, "WT:LOL/E")) {
                        pa_wt_actions += 1; try std.testing.expectEqualStrings(pa_span.target, pa_span.text); try std.testing.expect(pa_span.bold);
                    } else if (std.mem.startsWith(u8, pa_span.target, "#reference-")) {
                        try std.testing.expect(pa_reference_markers < 2);
                        try std.testing.expectEqualStrings(if (pa_reference_markers == 0) "#reference-1" else "#reference-2", pa_span.target);
                        try std.testing.expect(pa_span.role == .reference and pa_span.superscript);
                        pa_reference_markers += 1;
                    } else return error.TestUnexpectedResult;
                }
                if (std.mem.indexOf(u8, pa_span.text, "<iframe") != null or std.mem.indexOf(u8, pa_span.text, "</iframe>") != null)
                    try std.testing.expect(pa_span.kind == .text and pa_span.target.len == 0);
                try std.testing.expect(pa_span.kind != .external_link);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), pa_definitions);
    try std.testing.expectEqual(@as(usize, 1), pa_dictionary_actions);
    try std.testing.expectEqual(@as(usize, 2), pa_wt_actions);
    try std.testing.expectEqual(@as(usize, 2), pa_reference_markers);
    for ([_][]const u8{ "ਅੰਗਰੇਜ਼ੀ", "ਉਚਾਰਨ", "ਨਾਂਵ", "ਕਿਰਿਆ", "ਹਵਾਲੇ", "Lua error in ਮੌਡਿਊਲ:audio:", "En-us-act.ogg", "ਅਧਿਨਿਯਮ", "ਕੰਮ, ਕਾਰਜ", "ਅਭਿਨੈ ਕਰਨਾ" }) |pa_kept|
        try std.testing.expect(std.mem.indexOf(u8, pa_visible.items, pa_kept) != null);
    try std.testing.expect(std.mem.indexOf(u8, pa_visible.items, "<iframe src=\"//commons.wikimedia.org/wiki/File:En-us-act.ogg?embedplayer=yes\" width=\"175\" height=\"20\" frameborder=\"0\" webkitAllowFullScreen mozallowfullscreen allowFullScreen></iframe>") != null);
    try std.testing.expect(std.mem.indexOf(u8, pa_visible.items, "ਸ਼੍ਰੇਣੀ:") == null);
    try std.testing.expectEqual(@as(usize, 0), pa_entry.media.len);
    try std.testing.expectEqual(@as(usize, 2), pa_entry.references.len);
    const pa_urls = [_][]const u8{ "https://web.archive.org/web/20190714163445/http://pupdepartments.ac.in/e2p/", "http://dic.learnpunjabi.org/default.aspx" };
    for (pa_entry.references, 0..) |pa_reference, pa_index| {
        var pa_ref_actions: usize = 0;
        var pa_ref_visible: std.ArrayList(u8) = .empty;
        for (pa_reference.spans) |pa_span| {
            try pa_ref_visible.appendSlice(pa_alloc, pa_span.text);
            if (pa_span.kind == .external_link) {
                pa_ref_actions += 1; try std.testing.expectEqualStrings(pa_urls[pa_index], pa_span.target);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), pa_ref_actions);
        try std.testing.expect(std.mem.indexOf(u8, pa_ref_visible.items, "ਪੰਜਾਬੀ ਯੂਨੀਵਰਸਿਟੀ") != null);
    }
    const pa_report = try std.Io.Dir.cwd().readFileAlloc(pa_io, try std.fs.path.join(pa_alloc, &.{ pa_output, "fallback-pages.jsonl" }), pa_alloc, .limited(8192));
    var pa_rows = std.mem.tokenizeScalar(u8, pa_report, '\n');
    const pa_row = try std.json.parseFromSlice(std.json.Value, pa_alloc, pa_rows.next() orelse return error.TestUnexpectedResult, .{}); defer pa_row.deinit();
    var pa_unsupported = false; var pa_lua_error = false;
    for (pa_row.value.object.get("reasons").?.array.items) |pa_reason| {
        if (std.mem.eql(u8, pa_reason.string, "unsupported_element")) pa_unsupported = true;
        if (std.mem.eql(u8, pa_reason.string, "rendered_lua_error")) pa_lua_error = true;
    }
    try std.testing.expect(pa_unsupported and pa_lua_error and pa_rows.next() == null);
}


test "Writer captured Nahuatl Wolke retains restored IPA close and nested child ownership" {
    var nah_tmp = std.testing.tmpDir(.{}); defer nah_tmp.cleanup();
    var nah_arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer nah_arena.deinit();
    const nah_a = nah_arena.allocator(); const nah_io = std.testing.io;
    // Exact NAH p2503/r93751/ordinal516 retained input; no expansion replay.
    const nah_raw = "{{-de-}}\n\n{{-noun-de-}}\n* [1] [[mixtli]]\n\n{{-pron-}}\n[[:es:AFI|AFI]] → {{IPA| [ 'vɔlkə ]}}; {{plural}}: {{IPA|[ 'vɔlkn̩ ]}}\n\n{{-ety-}}";
    const nah_expanded = "[[Category:Alemaniatlahtolli]]__NOEDITSECTION__\n<br>\n== Alemaniatlahtolli ==\n\n=== Tlatocaxtiliztli ===\n[[Category:DE:Tlatocaxtiliztli]]\n[[Category:DE:Hueymachiyotlahtoliztli]]\n\n* [1] [[mixtli]]\n\n=== Tlatlaliliztli ===\n\n[[:es:AFI|AFI]] → <small></small>\n* IPA: <span style=\"font-family:lucida sans unicode\">[[Wiktionary:IPA|[ [ 'vɔlkə ]]]]</span>; <span style=\"font-size:95%;\">[[miaccayotl|Miaccayotl]]</span>: <small></small>\n* IPA: <span style=\"font-family:lucida sans unicode\">[[Wiktionary:IPA|[[ 'vɔlkn̩ ]]]]</span>\n\n=== Yollotlahtolli ===\n";
    const nah_namespaces = "# wikidict-namespace-registry-v1\n# wiki\tnahwiktionary\n# dump-date\t20261001\n# content-language\tnah\n-2\tMēdiatl\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tMedia\n-1\tNōncuahquīzqui\tSpecial\tfirst-letter\t0\t0\t0\t\tcompile_only\tvirtual_namespace\tEspecial\n0\t\t\tcase-sensitive\t0\t1\t0\t\tmain\tdictionary_entries\n1\tTēixnāmiquiliztli\tTalk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tDiscusión\n2\tTlatequitiltilīlli\tUser\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tUsuario\n3\tTlatequitiltilīlli tēixnāmiquiliztli\tUser talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tUsuario Discusión\n4\tWiktionary\tProject\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tWT\tWikipedia\n5\tWiktionary tēixnāmiquiliztli\tProject talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tWikipedia Discusión\tWiktionary talk\n6\tĪxiptli\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\tImagen\n7\tĪxiptli tēixnāmiquiliztli\tFile talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tImage talk\tImagen Discusión\tImagen discusión\n8\tHuiquimedia\tMediaWiki\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\tMediaWiki\n9\tHuiquimedia tēixnāmiquiliztli\tMediaWiki talk\tfirst-letter\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tMediaWiki Discusión\n10\tNemachiyōtīlli\tTemplate\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tPlantilla\n11\tNemachiyōtīlli tēixnāmiquiliztli\tTemplate talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tPlantilla Discusión\n12\tTēpalēhuiliztli\tHelp\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\tAyuda\n13\tTēpalēhuiliztli tēixnāmiquiliztli\tHelp talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tAyuda Discusión\n14\tNeneuhcāyōtl\tCategory\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tCategoría\n15\tNeneuhcāyōtl tēixnāmiquiliztli\tCategory talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\tCategoría Discusión\n710\tTimedText\tTimedText\tcase-sensitive\t0\t0\t0\t\tcompile_only\tancillary_site_input\n711\tTimedText talk\tTimedText talk\tcase-sensitive\t0\t0\t0\t\tcompile_only\tdiscussion_namespace\n828\tMódulo\tModule\tcase-sensitive\t1\t0\t0\t\tcompile_only\tstandard_build_input\n829\tMódulo discusión\tModule talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n1728\tEvento\tEvent\tcase-sensitive\t1\t0\t0\t\tcompile_only\tancillary_site_input\n1729\tEvento discusión\tEvent talk\tcase-sensitive\t1\t0\t0\t\tcompile_only\tdiscussion_namespace\n";
    var nah_ns = try namespace_registry.Registry.init(nah_a, nah_namespaces); defer nah_ns.deinit();
    // Unbound language callbacks keep the unresolved owner separate from this
    // presentation regression; the expanded heading grants no language trust.
    const nah_codes: encoder.blob_builder.LanguageCodes = .{ .namespace_catalog = &nah_ns };
    const nah_output = try std.fmt.allocPrint(nah_a, ".zig-cache/tmp/{s}/nah-restored-output", .{nah_tmp.sub_path});
    var nah_writer = try encoder.blob_builder.Writer.init(nah_io, nah_a, nah_output); defer nah_writer.deinit();
    nah_writer.language_codes = nah_codes;
    try nah_writer.addExpandedPage(nah_a, .{ .id = 0, .kind = .language }, "Wolke", nah_expanded, nah_raw, null);
    const nah_stats = try nah_writer.finish(nah_codes);
    try std.testing.expectEqual(@as(usize, 1), nah_stats.language_records);
    try std.testing.expectEqual(@as(usize, 1), nah_stats.fallback_pages);
    // Existing helper verifies trusted index lookup and exact codec roundtrip.
    const nah_entry = try GaHtmlLanguageBoundaryFixture.requiredEntry(nah_io, nah_a, nah_output, "Unclassified", "Wolke");
    try std.testing.expectEqualDeep((try GaHtmlLanguageBoundaryFixture.whole(nah_a, "Wolke", nah_expanded, &nah_ns)).sections, nah_entry.sections);
    var nah_ipa: std.ArrayList(u8) = .empty;
    var nah_visible: std.ArrayList(u8) = .empty;
    var nah_child_seen = false;
    var nah_meaning_seen = false;
    var nah_plural_seen = false;
    var nah_afi_seen = false;
    var nah_headings: usize = 0;
    for (nah_entry.sections) |nah_section| {
        for ([_][]const u8{ "Tlatocaxtiliztli", "Tlatlaliliztli", "Yollotlahtolli" }) |nah_heading| {
            if (std.mem.eql(u8, nah_section.title, nah_heading)) nah_headings += 1;
        }
        for (nah_section.blocks) |nah_block| for (nah_block.spans) |nah_span| {
            try nah_visible.appendSlice(nah_a, nah_span.text);
            if (std.mem.eql(u8, nah_span.target, "Wiktionary:IPA")) try nah_ipa.appendSlice(nah_a, nah_span.text);
            if (std.mem.eql(u8, nah_span.target, "mixtli")) nah_meaning_seen = true;
            if (std.mem.eql(u8, nah_span.target, "miaccayotl")) nah_plural_seen = true;
            if (std.mem.eql(u8, nah_span.target, "es:AFI")) nah_afi_seen = true;
            if (std.mem.eql(u8, nah_span.target, "'vɔlkn̩")) nah_child_seen = true;
        };
    }
    try std.testing.expectEqual(@as(usize, 3), nah_headings);
    try std.testing.expectEqualStrings("[ [ 'vɔlkə ]", nah_ipa.items);
    try std.testing.expect(nah_meaning_seen and nah_plural_seen and nah_afi_seen and nah_child_seen);
    try std.testing.expect(std.mem.indexOf(u8, nah_visible.items, "[ [ 'vɔlkə ]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, nah_visible.items, "[malformed link]") != null);
}

// Append only to a private tools/blob_build.zig. Synthetic source, NOT captured
// KY а/аалам output or raw-page equivalence. Uses the normal loader/callbacks,
// Writer, language blob index and presentation codec already used by this file.
fn kyCapitalizedWriterCodecControl(tsv: []const u8, heading: []const u8, expected_code: []const u8, expected_owner: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\tkywiktionary\n# dump-date\t20261001\n# content-language\tky\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    // These deliberately minimal synthetic loader inputs provide no Lua name,
    // source-banner template, category declaration or template corroboration.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = tsv });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "\n" });
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    const source = try std.fmt.allocPrint(a, "== {s} ==\n# Definition '''bold''' [[target|label]] and ''italic''.\n=== Examples ===\nKeep suffix.\n", .{heading});
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "synthetic-capitalization", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    try std.testing.expectEqual(@as(usize, if (expected_code.len == 0) 1 else 0), stats.fallback_pages);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(expected_owner, &filename) });
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings(expected_code, metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("synthetic-capitalization")) orelse return error.TestUnexpectedResult;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings(expected_code, decoded.entry.language_code);
    try std.testing.expectEqualStrings("synthetic-capitalization", decoded.entry.title);
    var definitions: usize = 0;
    var links: usize = 0;
    var bold: usize = 0;
    var italic: usize = 0;
    var language_headings: usize = 0;
    var examples: usize = 0;
    var visible: std.ArrayList(u8) = .empty;
    for (decoded.entry.sections) |section| {
        if (section.level == 2 and std.mem.eql(u8, section.title, heading)) language_headings += 1;
        if (section.level == 3 and std.mem.eql(u8, section.title, "Examples")) examples += 1;
        for (section.blocks) |block| {
            if (block.kind == .definition) definitions += 1;
            for (block.spans) |span| {
                try visible.appendSlice(a, span.text);
                if (std.mem.eql(u8, span.target, "target")) {
                    try std.testing.expect(span.kind == .link);
                    try std.testing.expectEqualStrings("label", span.text);
                    links += 1;
                }
                if (std.mem.eql(u8, span.text, "bold") and span.bold) bold += 1;
                if (std.mem.eql(u8, span.text, "italic") and span.italic) italic += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), links);
    try std.testing.expectEqual(@as(usize, 1), bold);
    try std.testing.expectEqual(@as(usize, 1), italic);
    try std.testing.expectEqual(@as(usize, 1), language_headings);
    try std.testing.expectEqual(@as(usize, 1), examples);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Definition bold label and italic.") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "Keep suffix.") != null);
}

test "KY capitalized preferred ownership survives normal Writer and codec with exact body" {
    try kyCapitalizedWriterCodecControl("# content-language\tky\n# mediawiki\nky\tкыргызча\tКыргызча\tky\tKirghiz\tkir\n", "Кыргызча", "ky", "кыргызча");
    // The established ASCII contract still works through the same real path.
    try kyCapitalizedWriterCodecControl("# content-language\tky\n# mediawiki\nky\tкыргызча\tКыргызча\tky\tKirghiz\tkir\nru\truso\tRuso\tru\n", "Ruso", "ru", "ruso");
}

test "KY absent and conflicting aliases preserve Unclassified body through Writer codec" {
    try kyCapitalizedWriterCodecControl("# content-language\tky\n# mediawiki\nky\tкыргызча\tky\n", "Кыргызча", "", "Unclassified");
    try kyCapitalizedWriterCodecControl("# content-language\tky\n# mediawiki\nky\tкыргызча\tКыргызча\tky\nen\tEnglish\tКыргызча\ten\n", "Кыргызча", "", "Unclassified");
}

test "continuous capture uses exact raw shard root and survives failed shard cleanup" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root = try auditControlFreshRoot(a, "continuous-capture-root");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    // Match the real CLI topology: args[2] IS the shard container, and no
    // .incomplete marker is manufactured in it or in a parent fixture.
    try F.absent(try std.fs.path.join(a, &.{ root, ".incomplete" }));
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    const job: ExpansionJob = .{ .ordinal = 17, .index_offset = 9,
        .ns = .{ .id = 0, .kind = .language }, .title = "Continuous fixture",
        .source = "exact raw", .page_id = 71, .revision_id = 91,
        .index_line = "exact index row" };
    const expanded: bundle_expander.Expansion = .{ .source = "before |} after" };
    {
        const scope = ContinuousFailureCaptureScope.begin(root); defer scope.deinit();
        var shard = try PendingShard.init(F.io, a, root, 0, 1, 0, .{});
        var closed = false; defer if (!closed) shard.deinit();
        const temporary = try a.dupe(u8, shard.temporary);
        const final = try a.dupe(u8, shard.final);
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&shard.writer.?, job, expanded, a, null));
        shard.deinit(); closed = true;
        try F.absent(temporary); try F.absent(final);
        const row = try F.manifest(a, root);
        try std.testing.expect(row.object.get("record_complete").?.bool);
        try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
        try std.testing.expectEqual(@as(i64, 17), row.object.get("ordinal").?.integer);
        try F.payload(a, row, "raw_source", job.source, 256 * 1024);
        try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
        try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
        try F.noPublication(a, root);
    }
    try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
    const capture = try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "capture.json" });
    const before = try std.Io.Dir.cwd().readFileAlloc(F.io, capture, a, .limited(64 * 1024));
    // A distinct invocation also cannot overwrite the retained first capture.
    first_failure_capture_context = F.context(a, root);
    {
        const scope = ContinuousFailureCaptureScope.begin(root); defer scope.deinit();
        var shard = try PendingShard.init(F.io, a, root, 0, 1, 0, .{}); defer shard.deinit();
        try std.testing.expectError(error.UncompiledPresentation, consumeExpandedPage(&shard.writer.?, job, .{ .source = "[https:// broken" }, a, null));
        try std.testing.expect(first_failure_capture_context.?.attempted);
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(F.io, capture, a, .limited(64 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
    try F.absent(try std.fs.path.join(a, &.{ root, ".incomplete" }));
    try F.noPublication(a, root);
}

test "continuous capture scope rejects other roots and restores on every exit" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root = try auditControlFreshRoot(a, "continuous-capture-scope");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    const other = try std.fs.path.join(a, &.{ root, "other" });
    const job: ExpansionJob = .{ .ordinal = 0, .index_offset = 0,
        .ns = .{ .id = 0, .kind = .language }, .title = "scope", .source = "raw" };
    {
        const wrong = ContinuousFailureCaptureScope.begin(other); defer wrong.deinit();
        try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
        try std.testing.expectError(error.FileNotFound, writeFirstPresentationFailure(error.UncompiledPresentation, first_failure_capture_context.?, job, .{ .source = "expanded" }));
    }
    const Probe = struct {
        fn exit(root_path: []const u8, fail: bool) !void {
            const scope = ContinuousFailureCaptureScope.begin(root_path); defer scope.deinit();
            try std.testing.expect(first_failure_capture_context.?.continuous_output_active);
            {
                const nested = ContinuousFailureCaptureScope.begin(root_path); defer nested.deinit();
                try std.testing.expect(first_failure_capture_context.?.continuous_output_active);
            }
            try std.testing.expect(first_failure_capture_context.?.continuous_output_active);
            if (fail) return error.ControlledFailure;
        }
    };
    try Probe.exit(root, false);
    try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
    try std.testing.expectError(error.ControlledFailure, Probe.exit(root, true));
    try std.testing.expect(!first_failure_capture_context.?.continuous_output_active);
    try std.testing.expectError(error.FileNotFound, writeFirstPresentationFailure(error.UncompiledPresentation, first_failure_capture_context.?, job, .{ .source = "expanded" }));
    try F.absent(try std.fs.path.join(a, &.{ root, ".presentation-first-failure" }));
    // Outside the active continuous scope the original marker contract remains.
    try F.marker(a, root);
    try writeFirstPresentationFailure(error.UncompiledPresentation, first_failure_capture_context.?, job, .{ .source = "expanded" });
    try std.testing.expect((try F.manifest(a, root)).object.get("record_complete").?.bool);
    try F.noPublication(a, root);
}

test "InvalidPreContext capture retains typed error and context without retry reclassification" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const root = try auditControlFreshRoot(a, "invalid-precontext-capture");
    defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
    try F.marker(a, root);
    try std.testing.expect(first_failure_capture_context == null and failure_receipt_context == null);
    first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
    const receipt = try std.fs.path.join(a, &.{ root, "outer-failure.json" });
    failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt,
        .invocation_id = F.context(a, root).invocation_id.?, .invocation_args = &F.args };
    defer failure_receipt_context = null;
    const job: ExpansionJob = .{ .ordinal = 23, .index_offset = 19,
        .ns = .{ .id = 0, .kind = .language }, .title = "Synthetic context failure",
        .source = "exact raw fixture", .page_id = 31, .revision_id = 47,
        .index_line = "exact synthetic index row" };
    const expanded: bundle_expander.Expansion = .{ .source = "exact expanded fixture",
        .display_title = "display fixture", .poem_metadata = "[]",
        .missing_dependency_metadata = "{}" };
    // This exercises the diagnostic boundary, not a claimed WA parser cause.
    captureFirstPresentationFailure(error.OutOfMemory, job, expanded);
    try std.testing.expect(!first_failure_capture_context.?.attempted);
    try F.absent(try std.fs.path.join(a, &.{ root, ".presentation-first-failure" }));
    captureFirstPresentationFailure(error.InvalidPreContext, job, expanded);
    try std.testing.expect(first_failure_capture_context.?.attempted);
    const row = try F.manifest(a, root);
    try std.testing.expect(row.object.get("record_complete").?.bool);
    try std.testing.expect(row.object.get("diagnostic_only").?.bool);
    try std.testing.expect(!row.object.get("publication_created").?.bool);
    try std.testing.expect(!row.object.get("semantic_acceptance").?.bool);
    try std.testing.expectEqualStrings("InvalidPreContext", row.object.get("error_name").?.string);
    try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 23), row.object.get("ordinal").?.integer);
    try std.testing.expectEqual(@as(i64, 19), row.object.get("index_offset").?.integer);
    try std.testing.expectEqual(@as(i64, 31), row.object.get("page_id").?.integer);
    try std.testing.expectEqual(@as(i64, 47), row.object.get("revision_id").?.integer);
    try F.payload(a, row, "raw_source", job.source, 256 * 1024);
    try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
    try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
    try F.payload(a, row, "display_title", expanded.display_title.?, 256 * 1024);
    try F.payload(a, row, "poem_metadata", expanded.poem_metadata.?, 256 * 1024);
    try F.payload(a, row, "missing_dependency_metadata", expanded.missing_dependency_metadata.?, 256 * 1024);
    try std.testing.expect(recordPresentationFailure(error.InvalidPreContext, job) == error.InvalidPreContext);
    try F.absent(receipt);
    const capture_path = try std.fs.path.join(a, &.{ root, ".presentation-first-failure", "capture.json" });
    const before = try std.Io.Dir.cwd().readFileAlloc(F.io, capture_path, a, .limited(64 * 1024));
    captureFirstPresentationFailure(error.UncompiledPresentation, job, .{ .source = "replacement" });
    const after = try std.Io.Dir.cwd().readFileAlloc(F.io, capture_path, a, .limited(64 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
    try F.noPublication(a, root);
}

test "InvalidPreContext capture IO refusal preserves error and existing capture" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "missing-marker", "existing-capture" }) |label| {
        const root = try auditControlFreshRoot(a, "invalid-precontext-" ++ label);
        defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
        const capture_path = try std.fs.path.join(a, &.{ root, ".presentation-first-failure" });
        if (comptime std.mem.eql(u8, label, "existing-capture")) {
            try F.marker(a, root);
            try std.Io.Dir.cwd().writeFile(F.io, .{ .sub_path = capture_path, .data = "retained bytes" });
        }
        first_failure_capture_context = F.context(a, root); defer first_failure_capture_context = null;
        const receipt = try std.fs.path.join(a, &.{ root, "outer-failure.json" });
        failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt,
            .invocation_id = F.context(a, root).invocation_id.?, .invocation_args = &F.args };
        defer failure_receipt_context = null;
        const job: ExpansionJob = .{ .ordinal = 0, .index_offset = 0,
            .ns = .{ .id = 0, .kind = .language }, .title = "IO control", .source = "raw" };
        captureFirstPresentationFailure(error.InvalidPreContext, job, .{ .source = "expanded" });
        try std.testing.expect(first_failure_capture_context.?.attempted);
        try std.testing.expect(recordPresentationFailure(error.InvalidPreContext, job) == error.InvalidPreContext);
        try F.absent(receipt);
        if (comptime std.mem.eql(u8, label, "existing-capture")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(F.io, capture_path, a, .limited(64));
            try std.testing.expectEqualStrings("retained bytes", bytes);
        } else try F.absent(capture_path);
        try F.noPublication(a, root);
    }
}
// Append to tools/blob_build.zig privately. Synthetic normal-loader/Writer/codec
// controls; actual captured кхъухь must separately pass its saved-page oracle.
fn kbdHeadingPosWriterControl(tsv: []const u8, raw: []const u8, expanded: []const u8, expected_code: []const u8, expected_owner: []const u8, lexeme_count: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // A different edition rules out content-language inference. Every TSV has en
    // to satisfy the strict normal loader, even when kbd is deliberately absent.
    var namespaces = try namespace_registry.Registry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = tsv });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "\n" });
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "synthetic-kbd-declarations", expanded, raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(expected_owner, &filename) });
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings(expected_code, metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a);
    defer index.deinit(a);
    const record = (try index.find("synthetic-kbd-declarations")) orelse return error.TestUnexpectedResult;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings(expected_code, decoded.entry.language_code);
    try std.testing.expect(decoded.entry.language != null);
    try std.testing.expectEqualStrings(expected_owner, decoded.entry.language.?);
    try std.testing.expectEqual(lexeme_count, decoded.entry.organization.lexemes.len);
    for (decoded.entry.organization.lexemes) |lexeme| {
        try std.testing.expectEqualStrings("Noun", lexeme.kind);
        try std.testing.expectEqualStrings(if (expected_code.len == 0) "" else expected_owner, lexeme.language);
        try std.testing.expectEqualStrings("ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ", decoded.entry.sections[lexeme.section].title);
    }
    var definitions: usize = 0;
    var targets: usize = 0;
    var bold: usize = 0;
    var italic: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        for (block.spans) |span| {
            if (std.mem.eql(u8, span.target, "target")) {
                try std.testing.expect(span.kind == .link);
                try std.testing.expectEqualStrings("label", span.text);
                targets += 1;
            }
            if (std.mem.eql(u8, span.text, "bold") and span.bold) bold += 1;
            if (std.mem.eql(u8, span.text, "italic") and span.italic) italic += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), targets);
    try std.testing.expectEqual(@as(usize, 1), bold);
    try std.testing.expectEqual(@as(usize, 1), italic);
}
const kbdHeadingPosBody = "# Definition '''bold''' [[target|label]] and ''italic''.\n";
const kbdHeadingPosExpanded = "=='''АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)'''==\n===ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ===\n====МЫХЬЭНЭ====\n" ++ kbdHeadingPosBody;
const kbdHeadingPosRaw = "{{псалъащхьэ}}\n{{псалъ-лъэпкъ|kbd|лъэпкъыгъуэ=ЩЫӀЭЦӀЭ}}\n====МЫХЬЭНЭ====\n" ++ kbdHeadingPosBody;
const kbdHeadingPosRegistry = "# content-language\ten\n# mediawiki\nen\tEnglish\nkbd\tадыгэбзэ\tАдыгэбзэ\tkbd\tKabardian\n";

test "KBD exact curated owner and noun survive normal Writer codec without edition default" {
    try kbdHeadingPosWriterControl(kbdHeadingPosRegistry, kbdHeadingPosRaw, kbdHeadingPosExpanded, "kbd", "адыгэбзэ", 1);
}

test "KBD normal Writer preserves absence and competing language authority" {
    try kbdHeadingPosWriterControl("# content-language\ten\n# mediawiki\nen\tEnglish\n", kbdHeadingPosRaw, kbdHeadingPosExpanded, "", "Unclassified", 1);
    try kbdHeadingPosWriterControl(kbdHeadingPosRegistry ++ "fr\tFrench\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", kbdHeadingPosRaw, kbdHeadingPosExpanded, "", "Unclassified", 1);
    try kbdHeadingPosWriterControl(kbdHeadingPosRegistry ++ "fr\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", kbdHeadingPosRaw, kbdHeadingPosExpanded, "fr", "АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)", 1);
}

test "KBD literal protected headings cannot create owner or noun lexeme" {
    const headings = "==АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)==\n===ПСАЛЪЭ ЛЪЭПКЪЫГЪУЭ: ЩЫӀЭЦӀЭ===\n";
    const nowiki = "<nowiki>\n" ++ headings ++ "</nowiki>\n" ++ kbdHeadingPosBody;
    try kbdHeadingPosWriterControl(kbdHeadingPosRegistry, nowiki, nowiki, "", "Unclassified", 0);
    const pre = "<pre>\n" ++ headings ++ "</pre>\n" ++ kbdHeadingPosBody;
    try kbdHeadingPosWriterControl(kbdHeadingPosRegistry, pre, pre, "", "Unclassified", 0);
}


const OcH1ExpectedOwner = struct { code: []const u8, heading: []const u8, targets: []const []const u8 };
fn ocH1WriterControl(registry_tsv: []const u8, raw: ?[]const u8, expanded: []const u8, expected: []const OcH1ExpectedOwner) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategoria\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer namespaces.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry_tsv });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "\n" });
    var registry = try loadLanguageRegistry(io, a, root, &namespaces);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "html-language-owner", expanded, raw orelse expanded, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(expected.len, stats.language_records);
    for (expected) |owner| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner.heading, &filename) });
        var mapped = try mmapPath(io, path);
        defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(owner.code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a);
        defer index.deinit(a);
        const record = (try index.find("html-language-owner")) orelse return error.TestUnexpectedResult;
        const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
        try std.testing.expectEqualStrings(owner.code, stored.entry.language_code);
        try std.testing.expectEqualStrings(owner.heading, stored.entry.language.?);
        var matched = std.StringHashMap(void).init(a);
        var definitions: usize = 0;
        var bold = false;
        var italic = false;
        for (stored.entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) definitions += 1;
            for (block.spans) |span| {
                if (span.bold and std.mem.eql(u8, span.text, "bold")) bold = true;
                if (span.italic and std.mem.eql(u8, span.text, "italic")) italic = true;
                if (span.kind == .link) for (expected) |candidate| for (candidate.targets) |target| {
                    if (!std.mem.eql(u8, span.target, target)) continue;
                    try std.testing.expectEqualStrings(owner.code, candidate.code);
                    try matched.put(target, {});
                };
            }
        };
        try std.testing.expect(definitions >= owner.targets.len and bold and italic);
        try std.testing.expectEqual(owner.targets.len, @as(usize, matched.count()));
        for (owner.targets) |target| try std.testing.expect(matched.contains(target));
    }
}

test "root linked HTML H1 owners use normal trusted registry and keep repeated language bodies separate" {
    const registry = "# content-language\ten\n# mediawiki\nen\tEnglish\nfr\tFrench\n";
    const english = "<h1>[[English|English]]</h1>[[Categoria:English]]\n";
    const french = "<h1>[[French|French]]</h1>[[Category:French|entry]]\n";
    const first = "# '''bold''' [[english-one|one]] ''italic''.\n";
    const second = "# '''bold''' [[french-one|deux]] ''italic''.\n";
    const third = "# '''bold''' [[english-two|three]] ''italic''.\n";
    try ocH1WriterControl(registry, "{{=en=}}\n" ++ first ++ "{{=fr=}}\n" ++ second ++ "{{=en=}}\n" ++ third,
        english ++ first ++ french ++ second ++ english ++ third,
        &.{ .{ .code = "en", .heading = "English", .targets = &.{ "english-one", "english-two" } }, .{ .code = "fr", .heading = "French", .targets = &.{"french-one"} } });
    // A trusted linked heading does not depend on a raw template-name guess.
    try ocH1WriterControl(registry, null, french ++ second, &.{.{ .code = "fr", .heading = "French", .targets = &.{"french-one"} }});
    // Unknown linked H1 support under an established owner is not promoted to
    // a new language boundary; its original typed heading/body remain intact.
    try ocH1WriterControl(registry, null, english ++ first ++ "<h1>[[Regional vocabulary]]</h1>[[Category:Words]]\n" ++ third,
        &.{.{ .code = "en", .heading = "English", .targets = &.{ "english-one", "english-two" } }});
    inline for ([_][]const u8{
        "<h1>[[Unknown]]</h1>[[Category:Unknown]]\n",
        "<h1>[[English|French]]</h1>[[Category:English]]\n",
        "<h1>[[English]]</h1>[[:Category:English]]\n",
    }) |heading| try ocH1WriterControl(registry, null, heading ++ first,
        &.{.{ .code = "", .heading = "Unclassified", .targets = &.{"english-one"} }});
}


const TeCategoryCaptured = @import("te-category-owner-captured-inputs.zig");
const TeCategoryCase = struct {
    category_source: ?[]const u8 = TeCategoryCaptured.category,
    template_source: ?[]const u8 = TeCategoryCaptured.topic_template,
    category_namespace: u32 = 14,
    category_model: []const u8 = "wikitext",
    template_model: []const u8 = "wikitext",
    raw: []const u8 = TeCategoryCaptured.raw,
    expanded: []const u8 = TeCategoryCaptured.expanded,
    extra_category: ?[]const u8 = null,
    owned: bool = false,
};
const TeCategoryFixture = struct {
    a: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    index: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    fn page(self: *@This(), title: []const u8, ns: u32, text: []const u8, model: []const u8) !void {
        const offset = self.source.items.len;
        try self.source.appendSlice(self.a, text);
        const row = try std.fmt.allocPrint(self.a, "{d}\t{d}\t{s}\t\t{d}\t{d}\t2026-10-01T00:00:00Z\tfixture\t{s}\t{d}\t1\t0\n", .{ offset, text.len, title, self.next_id, self.next_id, model, ns });
        try self.index.appendSlice(self.a, row);
        self.next_id += 1;
    }
};
fn teCategoryOwnerCase(value: TeCategoryCase) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ns = try namespace_registry.Registry.init(a,
        "# wikidict-namespace-registry-v1\n# wiki\ttewiktionary\n# dump-date\t20261001\n# content-language\tte\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tమూస\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tవర్గం\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n");
    defer ns.deinit();
    var fixture: TeCategoryFixture = .{ .a = a };
    if (value.template_source) |source| try fixture.page("మూస:topic cat", 10, source, value.template_model);
    if (value.category_source) |source| try fixture.page("వర్గం:తెలుగు పదాలు", value.category_namespace, source, value.category_model);
    if (value.extra_category) |source| try fixture.page("వర్గం:English పదాలు", 14, source, "wikitext");
    const input_path = try std.fs.path.join(a, &.{ root, "input.xml" });
    const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
    const title_path = try std.fs.path.join(a, &.{ root, dump_source.page_title_index_filename });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = fixture.source.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = fixture.index.items });
    try dump_source.buildPageTitleIndex(io, a, index_path, title_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\tte\n# mediawiki\nte\tతెలుగు\tte\tTelugu\nen\tEnglish\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "\n" });
    var registry = try loadLanguageRegistry(io, a, root, &ns);
    defer registry.deinit();
    var index = try mmapPath(io, index_path);
    defer index.deinit();
    var title_storage = try mmapPath(io, title_path);
    defer title_storage.deinit();
    const titles = try dump_source.PageTitleIndex.init(title_storage.bytes);
    var reader = try dump_source.SourceReader.open(io, a, a, input_path, .raw_xml, null);
    defer reader.deinit();
    var proof: source_category_language.Context = .{ .allocator = a, .registry = &registry, .namespace_catalog = &ns, .source = &reader, .page_index = index.bytes, .title_index = titles };
    var codes = languageCodes(&registry, &ns);
    codes.source_category_ctx = &proof;
    codes.source_category_fn = source_category_language.Context.callback;
    if (value.owned) {
        // A resolve call destroys its own scratch arena before returning. Both
        // cached owner slices must point into immutable registry storage.
        const first = (try proof.resolve("వర్గం:తెలుగు పదాలు")) orelse return error.TestUnexpectedResult;
        try std.testing.expect(first.code.ptr == registry.codes.getKey("te").?.ptr);
        try std.testing.expect(first.heading.ptr == registry.headings.get("te").?.ptr);
        const key = proof.cache[0].?.title;
        const base = @intFromPtr(index.bytes.ptr);
        const pointer = @intFromPtr(key.ptr);
        try std.testing.expect(pointer >= base and pointer - base <= index.bytes.len and key.len <= index.bytes.len - (pointer - base));
        const noise = try a.alloc(u8, 8192);
        @memset(noise, 0xa5);
        const again = (try proof.resolve("వర్గం:తెలుగు పదాలు")) orelse return error.TestUnexpectedResult;
        try std.testing.expect(first.code.ptr == again.code.ptr and first.heading.ptr == again.heading.ptr);
        try std.testing.expectEqualStrings("te", again.code);
        var mismatch = proof;
        mismatch.title_index.page_index_size += 1;
        try std.testing.expectError(error.PageTitleIndexMismatch, mismatch.resolve("వర్గం:తెలుగు పదాలు"));
    }
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output);
    defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "బంకముచ్చు", value.expanded, value.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 1), stats.language_records);
    const expected = if (value.owned) registry.resolveTrusted("తెలుగు").? else language_registry.Resolved{ .code = "", .heading = "Unclassified" };
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(expected.heading, &filename) });
    var mapped = try mmapPath(io, path);
    defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes);
    const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings(expected.code, metadata.code);
    var blob_index = try blob.buildTrustedIndexAlloc(a);
    defer blob_index.deinit(a);
    const record = (try blob_index.find("బంకముచ్చు")) orelse return error.TestUnexpectedResult;
    const stored = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, stored));
    try std.testing.expectEqualStrings(expected.code, stored.entry.language_code);
    try std.testing.expectEqual(@as(usize, 0), stored.entry.organization.lexemes.len);
    const Seen = struct {
        text: std.ArrayList(u8) = .empty,
        links: std.StringHashMap(void),
        tables: usize = 0,
        fn visit(self: *@This(), alloc: std.mem.Allocator, comptime T: type, item: T) anyerror!void {
            if (T == encoder.presentation_types.Span) {
                try self.text.appendSlice(alloc, item.text);
                if (item.kind == .link or item.kind == .external_link) try self.links.put(item.target, {});
                return;
            }
            if (T == encoder.presentation_types.Table) self.tables += 1;
            if (T == encoder.presentation_types.Cell) {
                if (item.blocks) |blocks| return self.visit(alloc, @TypeOf(blocks), blocks);
                if (item.nested_table) |table| return self.visit(alloc, @TypeOf(table), table);
                return self.visit(alloc, @TypeOf(item.spans), item.spans);
            }
            switch (@typeInfo(T)) {
                .@"struct" => |info| inline for (info.field_names) |name| try self.visit(alloc, @TypeOf(@field(item, name)), @field(item, name)),
                .pointer => |info| {
                    if (info.size != .slice) @compileError("Unsupported TE category witness pointer");
                    if (info.child != u8) for (item) |child| try self.visit(alloc, info.child, child);
                },
                .optional => |info| if (item) |child| { try self.visit(alloc, info.child, child); },
                .array => |info| for (item) |child| try self.visit(alloc, info.child, child),
                .@"enum", .int, .bool => {},
                else => @compileError("Unhandled TE category witness type: " ++ @typeName(T)),
            }
        }
    };
    var seen: Seen = .{ .links = std.StringHashMap(void).init(a) };
    try seen.visit(a, @TypeOf(stored.entry), stored.entry);
    try std.testing.expectEqual(@as(usize, 1), seen.tables);
    for ([_][]const u8{ "ఇంగ్లీషు", "ఫ్రెంచి", "చైనీస్", "సంస్కృతం", "హిందీ", "అస్సామీ", "పంజాబీ", "తమిళం", "కన్నడం", "మలయాళం", "మరాఠీ", "గుజరాతీ", "ఒరియా", "బెంగాలి" }) |target| try std.testing.expect(seen.links.contains(target));
    try std.testing.expect(std.mem.indexOf(u8, seen.text.items, "| width=1% |") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.text.items, "|}"));
}

test "TE category owner requires current source language declaration and preserves captured zero-lexeme body" {
    try std.testing.expect(source_category_language.topicTemplateForwardsLanguage(TeCategoryCaptured.topic_template));
    try teCategoryOwnerCase(.{ .owned = true });
    try teCategoryOwnerCase(.{ .category_source = null });
    try teCategoryOwnerCase(.{ .template_source = null });
    try teCategoryOwnerCase(.{ .category_namespace = 0 });
    try teCategoryOwnerCase(.{ .category_model = "text" });
    try teCategoryOwnerCase(.{ .template_model = "text" });
    try teCategoryOwnerCase(.{ .category_source = "{{topic cat|en|తెలుగు పదాలు}}" });
    try teCategoryOwnerCase(.{ .category_source = "{{topic cat|te|Forged పదాలు}}" });
    try teCategoryOwnerCase(.{ .category_source = "<!--{{topic cat|te|తెలుగు పదాలు}}-->" });
    try teCategoryOwnerCase(.{ .category_source = "<nowiki>{{topic cat|te|తెలుగు పదాలు}}</nowiki>" });
    try teCategoryOwnerCase(.{ .category_source = "[[Target|{{topic cat|te|తెలుగు పదాలు}}]]" });
    try teCategoryOwnerCase(.{ .category_source = "{{topic cat|te|తెలుగు పదాలు}}{{topic cat|en|తెలుగు పదాలు}}" });
    try teCategoryOwnerCase(.{ .template_source = "<noinclude>doc</noinclude><includeonly>{{topic cat description|lang={{{2|}}}}}{{topic cat parents|lang={{{1|}}}}}</includeonly>" });
    const raw_without_category = TeCategoryCaptured.raw[0 .. std.mem.indexOf(u8, TeCategoryCaptured.raw, "[[వర్గం:తెలుగు పదాలు]]").?];
    try teCategoryOwnerCase(.{ .raw = raw_without_category });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = "\n[[వర్గం:English పదాలు]]";
    try teCategoryOwnerCase(.{ .raw = try std.mem.concat(a, u8, &.{ TeCategoryCaptured.raw, other }), .expanded = try std.mem.concat(a, u8, &.{ TeCategoryCaptured.expanded, other }), .extra_category = "{{topic cat|en|English పదాలు}}" });
    try teCategoryOwnerCase(.{ .raw = try std.mem.concat(a, u8, &.{ "==Unknown topic==\n", TeCategoryCaptured.raw }) });
    // A fresh context cannot inherit the earlier positive resolver's proof.
    try teCategoryOwnerCase(.{ .category_source = "{{topic cat|en|తెలుగు పదాలు}}" });
    try teCategoryOwnerCase(.{ .owned = true });
}


const ChrLiteralCodeBannerTest = struct {
    // Foreign content-language fixture proves that neither edition nor UI language owns the page.
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\ten\n# mediawiki\nen\tEnglish\ntr\tᎠᎬᎾ\tTürkçe\ttr\tTurkish\ttur\nfr\tFrench\nchr\tᏣᎳᎩ\tchr\tCherokee\n";
    const heading = "<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ]] <small><small>(tr)</small></small></big></div>";
    // XML encoding of the observed Template:-tr- p2282/r777320 body, used as a
    // synthetic normal-loader fixture. This is not a new captured expansion.
    const template_raw = "&lt;includeonly&gt;[[Category:ᏚᎸᎩ]]&lt;/includeonly&gt;__NOEDITSECTION__\n&lt;br&gt;\n=&lt;div id=\"toc\" class=\"toccolours\" &gt;&lt;big&gt;[[ᏚᎸᎩ]] &lt;small&gt;&lt;small&gt;(tr)&lt;/small&gt;&lt;/small&gt;&lt;/big&gt;&lt;/div&gt;=\n&lt;br&gt;&lt;noinclude&gt;\n&lt;!--[[Category:Language headings]] Please translate \"language headings\" and remove this warning--&gt;\n\n[[Category:Wiktionary/translate]]\n\n\n&lt;/noinclude&gt;";
    const raw = "{{-tr-}}\n'''elma''' \n\n:[1] [[ᏒᎦᏔ]] (sv-ga-ta)";
    const expanded = "[[Category:ᏚᎸᎩ]]__NOEDITSECTION__\n<br>\n=" ++ heading ++ "=\n<br>\n'''elma''' \n\n:[1] [[ᏒᎦᏔ]] (sv-ga-ta)";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tTemplate:-tr-\t\t2282\t777320\t2021-08-03T10:16:49Z\tA\twikitext\t10\t1\t1\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root); defer writer.deinit();
        try writer.append(0, 2282, 777320, template_raw); try writer.finish(index_path);
    }
};

test "indexed literal code banner admits exact static template without registering localized name" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try ChrLiteralCodeBannerTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, ChrLiteralCodeBannerTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const decoded = try xml_decode.decodeSinglePassAlloc(a, ChrLiteralCodeBannerTest.template_raw);
    const proof = source_language_banner.parse(decoded, &namespaces, null, &registry, "tr").?;
    try std.testing.expect(proof.authority == .literal_code);
    try std.testing.expectEqualStrings(ChrLiteralCodeBannerTest.heading, proof.heading);
    try std.testing.expect(registry.matchesSourceLanguageBanner("tr", proof.heading, 1));
    try std.testing.expect(registry.resolve("ᏚᎸᎩ") == null);
    try std.testing.expect(registry.resolveTrusted("ᏚᎸᎩ") == null);
    try std.testing.expect(!registry.isLanguageBoundary("ᏚᎸᎩ"));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("tr", "ᏚᎸᎩ (tr)", 1));
    try registry.addLocalAlias("ᏚᎸᎩ", "fr");
    try std.testing.expect(!registry.matchesSourceLanguageBanner("tr", proof.heading, 1));
}

test "literal code static banner rejects hidden projected conflicting and incomplete authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var namespaces = try namespace_registry.Registry.init(a, ChrLiteralCodeBannerTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(ChrLiteralCodeBannerTest.registry);
    const H = ChrLiteralCodeBannerTest.heading;
    for ([_][]const u8{
        "=" ++ H ++ "=\nvisible extra",
        "=" ++ H ++ "=\n=" ++ H ++ "=",
        "prefix=" ++ H ++ "=",
        "<nowiki>=" ++ H ++ "=</nowiki>",
        "<ref>=" ++ H ++ "=</ref>",
        "{|\n|\n=" ++ H ++ "=\n|}",
        "{{outer|\n=" ++ H ++ "=\n}}",
        "<div>\n=" ++ H ++ "=\n</div>",
        "<onlyinclude>=" ++ H ++ "=</onlyinclude>",
        "<includeonly>[[Category:ᏚᎸᎩ]]</includeonly>",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ]] <small>(fr)</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ]] <small>(tr) (fr)</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ]] <small>({{{1|tr}}})</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[English]] <small>(tr)</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ|English]] <small>(tr)</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" style=\"display:none\"><big>[[ᏚᎸᎩ]] <small>(tr)</small></big></div>=",
        "=<div id=\"toc\" class=\"hidden\"><big>[[ᏚᎸᎩ]] <small>(tr)</small></big></div>=",
        "=<div id=\"toc\" class=\"toccolours\" ><big>[[ᏚᎸᎩ]] <small>(tr)</big></div>=",
        "=" ++ H ++ "=\n<noinclude><!--broken</noinclude>",
        "=" ++ H ++ "=\n<noinclude><onlyinclude>wrong</onlyinclude></noinclude>",
        "=" ++ H ++ "=\n<noinclude>excluded</noinclude>emitted",
        "__TOC__\n=" ++ H ++ "=",
    }) |source| try std.testing.expect(source_language_banner.parse(source, &namespaces, null, &registry, "tr") == null);
    var absent = language_registry.Registry.empty(a); defer absent.deinit(); try absent.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\nfr\tFrench\ttr\n");
    const decoded = try xml_decode.decodeSinglePassAlloc(a, ChrLiteralCodeBannerTest.template_raw);
    try std.testing.expect(source_language_banner.parse(decoded, &namespaces, null, &absent, "tr") == null);
    try registry.addTsv("fr\tFrench\tᏚᎸᎩ\n");
    try std.testing.expect(source_language_banner.parse(decoded, &namespaces, null, &registry, "tr") == null);
}

test "Writer literal code banner requires exact root invocation and preserves typed body without inferred POS" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); try ChrLiteralCodeBannerTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, ChrLiteralCodeBannerTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit(); const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    // Synthetic expansion from the observed static template, not a saved Worker reply.
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "elma", ChrLiteralCodeBannerTest.expanded, ChrLiteralCodeBannerTest.raw, null);
    const raw_controls = [_][]const u8{
        "", "{{-en-}}\n", "{{-tr-|parameter}}\n", "prefix\n{{-tr-}}\n",
        "<!--{{-tr-}}-->\n", "<nowiki>{{-tr-}}</nowiki>\n", "<ref>{{-tr-}}</ref>\n",
        "{|\n|{{-tr-}}\n|}\n", "{{outer|{{-tr-}}}}\n",
    };
    for (raw_controls, 0..) |raw, i| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "root-negative-{d}", .{i}), ChrLiteralCodeBannerTest.expanded, raw, null);
    const headerless = "'''Ꮢ''' ''(sv)''\n\n*[[ᏒᎦᏔ]]";
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "headerless", headerless, headerless, null);
    _ = try writer.finish(codes);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("ᎠᎬᎾ", &filename) })); defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
    try std.testing.expectEqualStrings("tr", metadata.code);
    var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
    const record = (try index.find("elma")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("tr", decoded.entry.language_code);
    try std.testing.expectEqual(@as(usize, 0), decoded.entry.organization.lexemes.len);
    try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    var report: encoder.presentation_document.Fallbacks = .{};
    const whole_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, "elma", .language, "Unclassified", "", ChrLiteralCodeBannerTest.expanded, null, .{}, &namespaces, &report);
    const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, "elma", .language, .{ .code = "", .heading = "Unclassified" });
    var preserved: usize = 0;
    for (decoded.entry.sections) |section| if (section.level == 1 and std.mem.eql(u8, section.title, "ᏚᎸᎩ (tr)")) {
        for (whole.entry.sections) |original| if (original.level == 1 and std.mem.eql(u8, original.title, section.title)) {
            try std.testing.expectEqualDeep(original, section); preserved += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 1), preserved);
    for (raw_controls, 0..) |_, i| try std.testing.expect(try index.find(try std.fmt.allocPrint(a, "root-negative-{d}", .{i})) == null);
    try std.testing.expect(try index.find("headerless") == null);
    var unclassified = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("Unclassified", &filename) })); defer unclassified.deinit();
    const other_blob = try encoder.blob_format.inspect(unclassified.bytes); const other_metadata = try other_blob.languageMetadata();
    try std.testing.expectEqualStrings("", other_metadata.code);
    var other_index = try other_blob.buildTrustedIndexAlloc(a); defer other_index.deinit(a);
    for (raw_controls, 0..) |_, i| try std.testing.expect(try other_index.find(try std.fmt.allocPrint(a, "root-negative-{d}", .{i})) != null);
    try std.testing.expect(try other_index.find("headerless") != null);
    // Any separately retained pre-heading prefix may contain only its original
    // whitespace/breaks, never a duplicate lexical body or a second owner claim.
    if (try other_index.find("elma")) |prefix_record| {
        const prefix = try encoder.presentation_codec.decodeAlloc(a, prefix_record.payload, prefix_record.title, .language, other_metadata);
        for (prefix.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span|
            try std.testing.expect(span.target.len == 0 and std.mem.trim(u8, span.text, " \t\r\n").len == 0);
        try std.testing.expectEqual(@as(usize, 0), prefix.entry.organization.lexemes.len);
    }
}

// Append to tools/blob_build.zig after diagnostic-capture.patch.
// Synthetic diagnostic boundaries, not a reproduction of the unavailable UK page.
test "heading projection capture preserves complete identity and refuses IO replacement" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "complete", "missing-marker", "existing-capture" }) |mode| {
        const root = try auditControlFreshRoot(a, "projection-capture-" ++ mode);
        defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
        const capture_root = try std.fs.path.join(a, &.{ root, ".presentation-first-failure" });
        if (comptime !std.mem.eql(u8, mode, "missing-marker")) try F.marker(a, root);
        if (comptime std.mem.eql(u8, mode, "existing-capture"))
            try std.Io.Dir.cwd().writeFile(F.io, .{ .sub_path = capture_root, .data = "retained first capture" });
        try std.testing.expect(first_failure_capture_context == null and failure_receipt_context == null);
        first_failure_capture_context = F.context(a, root);
        defer first_failure_capture_context = null;
        const receipt = try std.fs.path.join(a, &.{ root, "outer-failure.json" });
        failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt,
            .invocation_id = F.context(a, root).invocation_id.?, .invocation_args = &F.args };
        defer failure_receipt_context = null;
        const job: ExpansionJob = .{ .ordinal = 23, .index_offset = 19,
            .ns = .{ .id = 0, .kind = .language }, .title = "Synthetic projection failure",
            .source = "exact raw fixture", .page_id = 31, .revision_id = 47,
            .index_line = "exact synthetic index row" };
        const expanded: bundle_expander.Expansion = .{ .source = "exact expanded fixture",
            .display_title = "display fixture", .poem_metadata = "[]", .missing_dependency_metadata = "{}" };
        var writer = try encoder.blob_builder.Writer.init(F.io, a, try std.fs.path.join(a, &.{ root, "writer" }));
        defer writer.deinit();
        captureFirstPresentationFailure(error.OutOfMemory, job, expanded);
        try std.testing.expect(!first_failure_capture_context.?.attempted);
        try std.testing.expectError(error.InvalidHeadingProjection, consumePresentationFailure(&writer, job, expanded, a, null, error.InvalidHeadingProjection));
        try std.testing.expect(first_failure_capture_context.?.attempted);
        try std.testing.expect(recordPresentationFailure(error.InvalidHeadingProjection, job) == error.InvalidHeadingProjection);
        try F.absent(receipt);
        if (comptime std.mem.eql(u8, mode, "complete")) {
            const row = try F.manifest(a, root);
            try std.testing.expect(row.object.get("record_complete").?.bool and row.object.get("diagnostic_only").?.bool);
            try std.testing.expect(!row.object.get("publication_created").?.bool and !row.object.get("semantic_acceptance").?.bool);
            try std.testing.expectEqualStrings("InvalidHeadingProjection", row.object.get("error_name").?.string);
            try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
            try std.testing.expectEqual(@as(i64, 23), row.object.get("ordinal").?.integer);
            try std.testing.expectEqual(@as(i64, 19), row.object.get("index_offset").?.integer);
            try std.testing.expectEqual(@as(i64, 31), row.object.get("page_id").?.integer);
            try std.testing.expectEqual(@as(i64, 47), row.object.get("revision_id").?.integer);
            try F.payload(a, row, "raw_source", job.source, 256 * 1024);
            try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
            try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
            try F.payload(a, row, "display_title", expanded.display_title.?, 256 * 1024);
            try F.payload(a, row, "poem_metadata", expanded.poem_metadata.?, 256 * 1024);
            try F.payload(a, row, "missing_dependency_metadata", expanded.missing_dependency_metadata.?, 256 * 1024);
            const path = try std.fs.path.join(a, &.{ capture_root, "capture.json" });
            const before = try std.Io.Dir.cwd().readFileAlloc(F.io, path, a, .limited(64 * 1024));
            captureFirstPresentationFailure(error.UncompiledPresentation, job, .{ .source = "replacement" });
            const after = try std.Io.Dir.cwd().readFileAlloc(F.io, path, a, .limited(64 * 1024));
            try std.testing.expectEqualSlices(u8, before, after);
        } else if (comptime std.mem.eql(u8, mode, "existing-capture")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(F.io, capture_root, a, .limited(64));
            try std.testing.expectEqualStrings("retained first capture", bytes);
        } else try F.absent(capture_root);
        try F.noPublication(a, root);
    }
}

fn projectionAuditPayload(a: std.mem.Allocator, row: std.json.Value, name: []const u8, original: []const u8) !void {
    const value = row.object.get(name).?;
    try std.testing.expect(value.object.get("present").?.bool);
    try std.testing.expect(!value.object.get("truncated").?.bool and !value.object.get("unretained").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(original.len)), value.object.get("bytes").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(original.len)), value.object.get("retained_bytes").?.integer);
    try std.testing.expectEqualStrings(try auditControlHash(a, original), value.object.get("sha256").?.string);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, value.object.get("path").?.string, a, .limited(4096));
    try std.testing.expectEqualStrings(original, bytes);
}

test "audit records three presentation errors for page and alias boundaries and discards scratch state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const inputs = try auditControlInputs(a, "three-presentation-errors", 4096);
    defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
    var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
    defer audit.deinit();
    var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
    defer writer.deinit();
    writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
    const seed: ExpansionJob = .{ .index_offset = 0, .ordinal = 1, .ns = .{ .id = 0, .kind = .language },
        .title = "scratch", .source = "==English==\n# retained [[child]]" };
    try std.testing.expect(try consumeExpandedPage(&writer, seed, .{ .source = seed.source }, a, &audit));
    try auditControlEmptySpools(&writer);
    for ([_]bool{ false, true }) |is_alias| {
        var job: ExpansionJob = .{ .index_offset = 29, .ordinal = 17, .ns = .{ .id = 0, .kind = .language },
            .title = "diagnostic boundary", .source = "{{raw request}}", .page_id = 31, .revision_id = 47,
            .index_line = "synthetic exact index row" };
        if (is_alias) job.alias_record = .{ .source_namespace = 0, .source_kind = .language,
            .source_title = job.title, .source_key = job.title, .xml_target = "Destination", .target_title = "Destination",
            .target_namespace = null, .target_kind = null, .target_key = "", .fragment = "", .presentation = "" };
        // Real Writer failure reaches each actual catch site, not just the helper.
        try std.testing.expect(!try consumeExpandedPage(&writer, job, .{ .source = "before |} after" }, a, &audit));
        try auditControlEmptySpools(&writer);
        for ([_]anyerror{ error.UncompiledPresentation, error.InvalidPreContext, error.InvalidHeadingProjection }) |err| {
            // Seed partial work before the common post-Writer boundary. The two
            // invariant errors are injected here; no UK parser reproduction is claimed.
            try std.testing.expect(try consumeExpandedPage(&writer, seed, .{ .source = seed.source }, a, null));
            try std.testing.expect(writer.stats.language_records != 0);
            try std.testing.expect(!try consumePresentationFailure(&writer, job, .{ .source = "expanded boundary fixture",
                .display_title = "display", .poem_metadata = "[]", .missing_dependency_metadata = "{}" }, a, &audit, err));
            try auditControlEmptySpools(&writer);
            try std.testing.expectEqual(@as(usize, 0), writer.stats.alias_records);
            try std.testing.expectEqual(@as(usize, 0), writer.stats.main_pages);
        }
    }
    try std.testing.expect(try consumeExpandedPage(&writer, seed, .{ .source = seed.source }, a, &audit));
    try auditControlEmptySpools(&writer);
    try std.testing.expectEqual(@as(usize, 10), audit.compile_attempts);
    try std.testing.expectEqual(@as(usize, 2), audit.succeeded);
    try std.testing.expectEqual(@as(usize, 8), audit.failed);
    try std.testing.expectEqual(@as(usize, 8), audit.failure_records);
    audit.selected = 10; audit.dispatched = 10; audit.consumed = 10;
    try audit.finish(true, true);
    const summary = try auditControlSummary(a, inputs.audit_root);
    try std.testing.expect(summary.object.get("inventory_complete").?.bool and summary.object.get("diagnostic_only").?.bool);
    try std.testing.expect(!summary.object.get("semantic_acceptance").?.bool and !summary.object.get("publication_created").?.bool);
    try std.testing.expectEqual(@as(i64, 8), summary.object.get("failed").?.integer);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" }), a, .limited(256 * 1024));
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    for ([_]bool{ false, true }) |is_alias| {
        for ([_][]const u8{ "UncompiledPresentation", "UncompiledPresentation", "InvalidPreContext", "InvalidHeadingProjection" }, 0..) |name, index| {
            const row = try std.json.parseFromSliceLeaky(std.json.Value, a, lines.next().?, .{});
            try std.testing.expectEqualStrings(name, row.object.get("error_name").?.string);
            try std.testing.expectEqual(is_alias, row.object.get("alias").?.bool);
            try std.testing.expectEqualStrings("diagnostic boundary", row.object.get("title").?.string);
            try std.testing.expectEqual(@as(i64, 17), row.object.get("ordinal").?.integer);
            try std.testing.expectEqual(@as(i64, 0), row.object.get("namespace").?.integer);
            try std.testing.expectEqual(@as(i64, 31), row.object.get("page_id").?.integer);
            try std.testing.expectEqual(@as(i64, 47), row.object.get("revision_id").?.integer);
            try projectionAuditPayload(a, row, "raw_source", "{{raw request}}");
            try projectionAuditPayload(a, row, "expanded", if (index == 0) "before |} after" else "expanded boundary fixture");
            try projectionAuditPayload(a, row, "index_row", "synthetic exact index row");
            if (index != 0) {
                try projectionAuditPayload(a, row, "display_title", "display");
                try projectionAuditPayload(a, row, "poem_metadata", "[]");
                try projectionAuditPayload(a, row, "missing_dependency_metadata", "{}");
            }
            const alias_payload = row.object.get("alias_record").?;
            try std.testing.expectEqual(is_alias, alias_payload.object.get("present").?.bool);
            if (is_alias) {
                const retained = try std.Io.Dir.cwd().readFileAlloc(io, alias_payload.object.get("path").?.string, a, .limited(4096));
                try std.testing.expectEqualStrings(try auditControlHash(a, retained), alias_payload.object.get("sha256").?.string);
                const alias = try std.json.parseFromSliceLeaky(std.json.Value, a, retained, .{});
                try std.testing.expectEqualStrings("diagnostic boundary", alias.object.get("source_title").?.string);
                try std.testing.expectEqualStrings("Destination", alias.object.get("target_title").?.string);
            }
        }
    }
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
    try auditControlNoPublishedFiles(a, inputs.writer_root);
}

test "audit refuses nonpresentation errors without mutating records or scratch work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const inputs = try auditControlInputs(a, "nonpresentation-errors", 4096);
    defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
    var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
    defer audit.deinit();
    var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
    defer writer.deinit();
    writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
    const job: ExpansionJob = .{ .ordinal = 1, .index_offset = 0, .ns = .{ .id = 0, .kind = .language },
        .title = "operational boundary", .source = "==English==\n# [[retained]]" };
    try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = job.source }, a, null));
    const stats = writer.stats;
    const spool_count = writer.spools.language.len;
    try std.testing.expect(stats.language_records != 0 and spool_count != 0);
    const first_offset = writer.spools.language[0].offset;
    const first_size = (try writer.spools.language[0].file.stat(io)).size;
    const report = try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" });
    const before = try std.Io.Dir.cwd().readFileAlloc(io, report, a, .limited(64));
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.FileNotFound, error.WriteFailed,
        error.Timeout, error.ExpansionWorkerDied, error.InvalidPoemMetadata, error.InvalidPresentation,
        error.RenderLimit, error.PageIndexChanged, error.AuditReportLimitExceeded }) |err| {
        try std.testing.expect(!auditablePresentationError(err));
        try std.testing.expectError(err, audit.recordFailure(err, job, .{ .source = job.source }));
        try std.testing.expectError(err, consumePresentationFailure(&writer, job, .{ .source = job.source }, a, &audit, err));
        try std.testing.expectEqual(@as(usize, 0), audit.compile_attempts);
        try std.testing.expectEqual(@as(usize, 0), audit.failed);
        try std.testing.expectEqual(@as(usize, 0), audit.failure_records);
        try std.testing.expectEqual(@as(usize, 0), audit.payload_bytes);
        try std.testing.expectEqual(@as(usize, 0), audit.report_bytes);
        try std.testing.expectEqualDeep(stats, writer.stats);
        try std.testing.expectEqual(spool_count, writer.spools.language.len);
        try std.testing.expectEqual(first_offset, writer.spools.language[0].offset);
        try std.testing.expectEqual(first_size, (try writer.spools.language[0].file.stat(io)).size);
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(io, report, a, .limited(64));
    try std.testing.expectEqualSlices(u8, before, after);
    audit.abort(error.Canceled);
    const summary = try auditControlSummary(a, inputs.audit_root);
    try std.testing.expect(!summary.object.get("inventory_complete").?.bool);
    try std.testing.expectEqualStrings("Canceled", summary.object.get("error_name").?.string);
    try auditControlNoPublishedFiles(a, inputs.writer_root);
}

test "audit capture IO failure propagates and retains incomplete inventory and partial spool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const inputs = try auditControlInputs(a, "projection-capture-io", 4096);
    defer std.Io.Dir.cwd().deleteTree(io, inputs.root) catch {};
    var audit = try PresentationAudit.init(io, a, inputs.audit_root, inputs.context);
    defer audit.deinit();
    var writer = try encoder.blob_builder.Writer.init(io, a, inputs.writer_root);
    defer writer.deinit();
    writer.language_codes = .{ .get_fn = auditControlLanguages, .boundary_fn = auditControlBoundary };
    const job: ExpansionJob = .{ .ordinal = 7, .index_offset = 0, .ns = .{ .id = 0, .kind = .language },
        .title = "IO boundary", .source = "==English==\n# [[retained]]" };
    try std.testing.expect(try consumeExpandedPage(&writer, job, .{ .source = job.source }, a, null));
    const stats = writer.stats;
    const first_offset = writer.spools.language[0].offset;
    // A directory at the exact first payload pathname makes ordinary writeFile
    // fail. The error must leave the page undiscarded and the inventory incomplete.
    const obstruction = try std.fs.path.join(a, &.{ inputs.audit_root, "failure-00000001-raw.wikitext" });
    try std.Io.Dir.cwd().createDir(io, obstruction, .default_dir);
    if (consumePresentationFailure(&writer, job, .{ .source = job.source }, a, &audit, error.InvalidHeadingProjection)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(!auditablePresentationError(err));
        audit.abort(err);
        const summary = try auditControlSummary(a, inputs.audit_root);
        try std.testing.expect(!summary.object.get("inventory_complete").?.bool);
        try std.testing.expectEqualStrings(@errorName(err), summary.object.get("error_name").?.string);
    }
    try std.testing.expectEqual(@as(usize, 1), audit.compile_attempts);
    try std.testing.expectEqual(@as(usize, 1), audit.failed);
    try std.testing.expectEqual(@as(usize, 0), audit.failure_records);
    try std.testing.expectEqual(@as(usize, 0), audit.payload_bytes);
    try std.testing.expectEqualDeep(stats, writer.stats);
    try std.testing.expectEqual(first_offset, writer.spools.language[0].offset);
    const report = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ inputs.audit_root, "failures.jsonl" }), a, .limited(64));
    try std.testing.expectEqual(@as(usize, 0), report.len);
    try auditControlNoPublishedFiles(a, inputs.writer_root);
}

const AutonymLoaderTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tskrwiktionary\n# dump-date\t20261001\n# content-language\tskr\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tskr\n# mediawiki\nskr\tسرائیکی\nur\tUrdu\tاردو\tاُردو\tUnreviewed alias\n";
    const header = "# wikidict-language-names-v1\n# wiki\tskrwiktionary\n# dump-date\t20261001\n# content-language\tskr\n";
    const names = header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, table: ?[]const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "\n" });
        if (table) |bytes| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-names.tsv" }), .data = bytes });
    }
};

test "normal language loader imports only complete same-source autonym heading evidence" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, AutonymLoaderTest.namespaces); defer namespaces.deinit();
    try AutonymLoaderTest.install(io, a, root, null);
    {
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        try std.testing.expect(registry.resolveTrusted("اردو") == null);
    }
    try AutonymLoaderTest.install(io, a, root, AutonymLoaderTest.names);
    {
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        const resolved = registry.resolveTrusted("اردو") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("ur", resolved.code);
        try std.testing.expectEqualStrings("Urdu", resolved.heading);
        try std.testing.expect(registry.resolveTrusted("اُردو") == null);
        try std.testing.expect(registry.resolveTrusted("Unreviewed alias") == null);
    }
    try AutonymLoaderTest.install(io, a, root, AutonymLoaderTest.header ++ "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\n");
    try std.testing.expectError(error.IncompleteLanguageNameProfile, loadLanguageRegistry(io, a, root, &namespaces));
}

test "normal Writer autonym heading preserves display body actions and codec without edition ownership" {
    for ([_]bool{ false, true }) |attested| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, AutonymLoaderTest.namespaces); defer namespaces.deinit();
        try AutonymLoaderTest.install(io, a, root, if (attested) AutonymLoaderTest.names else null);
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        const codes = languageCodes(&registry, &namespaces);
        const output = try std.fs.path.join(a, &.{ root, "blobs" });
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
        writer.language_codes = codes;
        const source = "== اردو ==\n# Definition '''bold''' [[target|label]].\n";
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "synthetic-autonym", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const owner = if (attested) "Urdu" else "Unclassified";
        const expected_code = if (attested) "ur" else "";
        const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename) });
        var mapped = try mmapPath(io, path); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(expected_code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("synthetic-autonym")) orelse return error.TestUnexpectedResult;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(expected_code, decoded.entry.language_code);
        try std.testing.expectEqualStrings("synthetic-autonym", decoded.entry.title);
        var headings: usize = 0; var definitions: usize = 0; var links: usize = 0; var bold: usize = 0;
        for (decoded.entry.sections) |section| {
            if (section.level == 2 and std.mem.eql(u8, section.title, "اردو")) headings += 1;
            for (section.blocks) |block| {
                if (block.kind == .definition) definitions += 1;
                for (block.spans) |span| {
                    if (std.mem.eql(u8, span.target, "target")) {
                        try std.testing.expect(span.kind == .link);
                        try std.testing.expectEqualStrings("label", span.text);
                        links += 1;
                    }
                    if (std.mem.eql(u8, span.text, "bold") and span.bold) bold += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 1), headings);
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), links);
        try std.testing.expectEqual(@as(usize, 1), bold);
        const encoded = try encoder.presentation_codec.encodeAlloc(a, decoded);
        try std.testing.expectEqualSlices(u8, record.payload, encoded);
    }
}

const LocalizedModuleTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tmywiktionary\n# dump-date\t20261001\n# content-language\tmy\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tတမ်းပလိတ်\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "828\tမော်ဂျူး\tModule\tcase-sensitive\t1\t0\t0\tScribunto\tcompile_only\tmodules\n" ++
        "829\tမော်ဂျူး ဆွေးနွေးချက်\tModule talk\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\ttalk\n";
    const registry = "# content-language\tmy\n# mediawiki\nmy\tမြန်မာဘာသာ\nru\tရုရှ\nbe\tဘီလာရုစ်\nuk\tယူကရိန်း\nsh\tSerbo-Croatian\nfr\tFrench\n";
    const source = "return { [\"မြန်မာ\"] = \"my\", [\"ရုရှား\"] = \"ru\", [\"Belarusian\"] = \"be\", [\"Ukrainian\"] = \"uk\", [\"Serbo-Croatian\"] = \"sh\" }";
    fn row(a: std.mem.Allocator, title: []const u8, module_source: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(module_source, &hash, .{});
        const encoded = std.fmt.bytesToHex(hash, .lower);
        // JSON formatting is immaterial; namespace identity supplies the selector.
        return std.json.Stringify.valueAlloc(a, .{ .title = title, .revision_id = @as(u64, 941151), .page_id = @as(u64, 127617), .sha256 = encoded[0..] }, .{ .whitespace = .minified });
    }
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, title: []const u8, module_source: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "modules" }));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "127617.lua" }), .data = module_source });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = try row(a, title, module_source) });
    }
};

test "normal language metadata loader resolves localized and canonical Module namespace titles" {
    for ([_][]const u8{ "မော်ဂျူး:languages/canonical names", "Module:languages/canonical names" }) |title| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
        try LocalizedModuleTest.install(io, a, root, title, LocalizedModuleTest.source);
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        for ([_]struct { label: []const u8, code_value: []const u8 }{
            .{ .label = "မြန်မာ", .code_value = "my" }, .{ .label = "ရုရှား", .code_value = "ru" },
        }) |expected| {
            const actual = registry.resolveStrong(expected.label) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(expected.code_value, actual.code);
            try std.testing.expectEqualStrings(expected.label, actual.heading);
        }
        try std.testing.expectEqualStrings("be", registry.resolveTrusted("ဘီလာရုစ်").?.code);
        try std.testing.expectEqualStrings("Belarusian", registry.resolve("be").?.heading);
        try std.testing.expectEqualStrings("Ukrainian", registry.resolve("uk").?.heading);
        // Canonical module does not attest the localized sh spelling.
        try std.testing.expect(registry.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    }
}

test "language metadata selector excludes nonmodule wrong base and duplicate normalized module roles" {
    for ([_][]const u8{ "languages/canonical names", "တမ်းပလိတ်:languages/canonical names", "Module talk:languages/canonical names", "မော်ဂျူး:languages/canonical names/doc", "Unknown:languages/canonical names" }) |title| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
        try LocalizedModuleTest.install(io, a, root, title, LocalizedModuleTest.source);
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        try std.testing.expect(registry.resolve("မြန်မာ") == null);
        try std.testing.expectEqualStrings("မြန်မာဘာသာ", registry.resolve("my").?.heading);
    }
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
    try LocalizedModuleTest.install(io, a, root, "မော်ဂျူး:languages/canonical names", LocalizedModuleTest.source);
    const duplicate = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{
        try LocalizedModuleTest.row(a, "မော်ဂျူး:languages/canonical names", LocalizedModuleTest.source),
        try LocalizedModuleTest.row(a, "Module:languages/canonical names", LocalizedModuleTest.source),
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = duplicate });
    try std.testing.expectError(error.DuplicateLanguageMetadataModule, loadLanguageRegistry(io, a, root, &namespaces));
}

test "localized module authority retains source identity and reserved code conflict failures" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
    try LocalizedModuleTest.install(io, a, root, "မော်ဂျူး:languages/canonical names", LocalizedModuleTest.source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "127617.lua" }), .data = "return {}" });
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &namespaces));
    try LocalizedModuleTest.install(io, a, root, "မော်ဂျူး:languages/canonical names", "return { [\"fr\"] = \"ru\" }");
    try std.testing.expectError(error.ConflictingLanguageHeading, loadLanguageRegistry(io, a, root, &namespaces));
}

const PositionalModuleTest = struct {
    const data = "local m = {}\nm[\"sh\"] = {\"ဆာဘို-ခရိုအေးရှား\", 9301, \"zls\"}\nreturn require(\"Module:languages\").finalizeData(m, \"language\")";
    fn row(a: std.mem.Allocator, title: []const u8, page: u64, source: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
        const digest = std.fmt.bytesToHex(hash, .lower);
        return std.json.Stringify.valueAlloc(a, .{ .title = title, .page_id = page, .sha256 = digest[0..] }, .{ .whitespace = .minified });
    }
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, provider_title: ?[]const u8, data_title: []const u8, provider_source: []const u8) !void {
        try LocalizedModuleTest.install(io, a, root, "မော်ဂျူး:languages/canonical names", LocalizedModuleTest.source);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "127326.lua" }), .data = provider_source });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "132659.lua" }), .data = data });
        const manifest = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{
            try LocalizedModuleTest.row(a, "မော်ဂျူး:languages/canonical names", LocalizedModuleTest.source),
            if (provider_title) |title| try row(a, title, 127326, provider_source) else "",
            try row(a, data_title, 132659, data),
        });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = manifest });
    }
};

test "normal positional language loader uses localized module provider proof and live registry conflicts" {
    for ([_][]const u8{ "မော်ဂျူး", "Module" }) |prefix| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
        try PositionalModuleTest.install(io, a, root,
            try std.fmt.allocPrint(a, "{s}:languages", .{prefix}),
            try std.fmt.allocPrint(a, "{s}:languages/data/2", .{prefix}), language_registry.PositionalProviderSchema.source);
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        const sh = registry.resolveTrusted("ဆာဘို-ခရိုအေးရှား") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("sh", sh.code);
        try std.testing.expectEqualStrings("Serbo-Croatian", sh.heading);
        try std.testing.expectEqualStrings("my", registry.resolveStrong("မြန်မာ").?.code);
        try std.testing.expectEqualStrings("ru", registry.resolveStrong("ရုရှား").?.code);
        try registry.addTsv("# mediawiki\nfr\tFrench\tဆာဘို-ခရိုအေးရှား\n");
        try std.testing.expectEqualStrings("fr", registry.resolve("ဆာဘို-ခရိုအေးရှား").?.code);
        try std.testing.expect(registry.resolveTrusted("ဆာဘို-ခရိုအေးရှား") == null);
    }
}

test "normal positional language loader declines absent foreign or unproved provider and retains source hash guard" {
    for ([_]?[]const u8{ null, "တမ်းပလိတ်:languages", "languages", "Unknown:languages" }) |provider_title| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
        try PositionalModuleTest.install(io, a, root, provider_title, "မော်ဂျူး:languages/data/2", language_registry.PositionalProviderSchema.source);
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        try std.testing.expect(registry.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    }
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LocalizedModuleTest.namespaces); defer namespaces.deinit();
    const wrong_getter = try std.mem.replaceOwned(u8, a, language_registry.PositionalProviderSchema.source, "self._data[1]", "self._data[2]");
    try PositionalModuleTest.install(io, a, root, "မော်ဂျူး:languages", "မော်ဂျူး:languages/data/2", wrong_getter);
    var declined = try loadLanguageRegistry(io, a, root, &namespaces); defer declined.deinit();
    try std.testing.expect(declined.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    try PositionalModuleTest.install(io, a, root, "မော်ဂျူး:languages", "မော်ဂျူး:languages/data/4", language_registry.PositionalProviderSchema.source);
    var wrong_family = try loadLanguageRegistry(io, a, root, &namespaces); defer wrong_family.deinit();
    try std.testing.expect(wrong_family.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    try PositionalModuleTest.install(io, a, root, "မော်ဂျူး:languages", "မော်ဂျူး:languages/data/2", language_registry.PositionalProviderSchema.source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "132659.lua" }), .data = "return {}" });
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &namespaces));
}

const KyFlagBannerTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tkywiktionary\n# dump-date\t20261001\n# content-language\tky\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n6\tФайл\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tfiles\n10\tКалып\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tКатегория\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tky\n# mediawiki\nky\tкыргызча\tКыргызча\tky\tKirghiz\tkir\nen\tEnglish\n";
    // Exact XML text bytes of retained Калып:-ky-, page82285/revision203294.
    const template_raw = "==[[File:Flag of Kyrgyzstan.svg|50px]] Кыргызча==\n\n&lt;includeonly&gt;[[Category:Кыргыз тили]]&lt;/includeonly&gt;";
    const heading = "[[File:Flag of Kyrgyzstan.svg|50px]] Кыргызча";
    // Synthetic body exercises nested definitions and stored links; this is not
    // an actual аалам expansion capture or a native producer acceptance claim.
    const expanded = "==[[File:Flag of Kyrgyzstan.svg|50px]] Кыргызча==\n[[Category:Кыргыз тили]]\n=== Семантикалык касиеттери ===\n==== Мааниси ====\n# [[дүйнө]], дүйнө жүзү.\n# Асман мейкиндиги.\n";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, source: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        const index = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index, .data = "0\t0\tКалып:-ky-\t\t82285\t203294\t2025-01-01T00:00:00Z\tA\twikitext\t10\t1\t1\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root); defer writer.deinit();
        try writer.append(0, 82285, 203294, source); try writer.finish(index);
    }
};

test "source flagged language banner requires literal neutral icon and known exact name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var namespaces = try namespace_registry.Registry.init(a, KyFlagBannerTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(KyFlagBannerTest.registry);
    const source = try xml_decode.decodeSinglePassAlloc(a, KyFlagBannerTest.template_raw);
    const proof = source_language_banner.parse(source, &namespaces, null, &registry, "ky").?;
    try std.testing.expectEqualStrings(KyFlagBannerTest.heading, proof.heading);
    try std.testing.expectEqual(@as(u8, 2), proof.level);
    try std.testing.expect(source_language_banner.parse(try std.mem.concat(a, u8, &.{ "\n", source }), &namespaces, null, &registry, "ky") != null);
    for ([_][]const u8{ " ", "\t", "\n ", "\n\t" }) |indent|
        try std.testing.expect(source_language_banner.parse(try std.mem.concat(a, u8, &.{ indent, source }), &namespaces, null, &registry, "ky") == null);
    for ([_][]const u8{
        "==[[File:Flag of Kyrgyzstan.svg|50px]] English==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[File:Flag of Kyrgyzstan.svg|50px]] Unknown==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[English|50px]] Кыргызча==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[File:Flag.svg|50px|link=English]] Кыргызча==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[File:Flag.svg|thumb]] Кыргызча==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[File:{{{1}}}|50px]] Кыргызча==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
        "==[[File:Flag.svg|50px]] Кыргызча==\n<includeonly>[[:Category:Кыргыз тили]]</includeonly>",
        "==[[File:Flag.svg|50px]] Кыргызча==\n<includeonly>[[Category:Кыргыз тили]]</includeonly>prose",
        "<onlyinclude>==[[File:Flag.svg|50px]] Кыргызча==</onlyinclude>\n<includeonly>[[Category:Кыргыз тили]]</includeonly>",
    }) |bad| try std.testing.expect(source_language_banner.parse(bad, &namespaces, null, &registry, "ky") == null);
    try registry.addTsv("xx\tOther\tКыргызча\n");
    try std.testing.expect(source_language_banner.parse(source, &namespaces, null, &registry, "ky") == null);
}

test "Writer source flagged banner owns exact root and preserves complete typed body" {
    // Trusted plain labels independently own a neutral image heading. Ordinary
    // aliases still require the exact source-banner root; every rejected raw
    // root below must remain Unclassified in that isolated authority case.
    for ([_]bool{ true, false }) |independent_heading| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try KyFlagBannerTest.install(io, a, root, KyFlagBannerTest.template_raw);
        // Keep the retained source and complete expanded body unchanged. This
        // synthetic registry variant makes the visible name only an ordinary alias,
        // so the exact authenticated raw template root is its sole owner proof.
        if (!independent_heading) try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }),
            .data = "# content-language\tky\n# mediawiki\nky\tKirghiz\tКыргызча\tky\tkir\nen\tEnglish\n",
        });
        var namespaces = try namespace_registry.Registry.init(a, KyFlagBannerTest.namespaces); defer namespaces.deinit();
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        try std.testing.expect(registry.matchesSourceLanguageBanner("ky", KyFlagBannerTest.heading, 2));
        try std.testing.expect(registry.resolveTrusted(KyFlagBannerTest.heading) == null);
        try std.testing.expectEqualStrings("ky", registry.resolve("Кыргызча").?.code);
        try std.testing.expect(registry.resolveStrong("Кыргызча") == null);
        try std.testing.expectEqual(independent_heading, registry.resolveTrusted("Кыргызча") != null);
        const preferred = if (independent_heading) "кыргызча" else "Kirghiz";
        try std.testing.expectEqualStrings(preferred, registry.resolve("ky").?.heading);
        const codes = languageCodes(&registry, &namespaces); const output = try std.fs.path.join(a, &.{ root, "blobs" });
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
        const roots = [_][]const u8{ "{{-ky-}}\n# body", "", "{{-en-}}\n", "{{-ky-|parameter}}\n", "prefix\n{{-ky-}}\n", "<!--{{-ky-}}-->\n", "<nowiki>{{-ky-}}</nowiki>\n" };
        for (roots, 0..) |raw, i| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "flag-control-{d}", .{i}), KyFlagBannerTest.expanded, raw, null);
        const stats = try writer.finish(codes); try std.testing.expectEqual(@as(usize, roots.len), stats.language_records);
        try std.testing.expectEqual(@as(usize, if (independent_heading) 1 else 2), stats.language_blobs);
        for (roots, 0..) |_, i| {
            const owner = if (independent_heading or i == 0) preferred else "Unclassified";
            var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
            var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(owner, &filename) })); defer mapped.deinit();
            const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata(); var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
            const title = try std.fmt.allocPrint(a, "flag-control-{d}", .{i}); const record = (try index.find(title)).?;
            const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            try std.testing.expectEqualStrings(if (independent_heading or i == 0) "ky" else "", decoded.entry.language_code);
            var report: encoder.presentation_document.Fallbacks = .{};
            const whole_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, title, .language, owner, metadata.code, KyFlagBannerTest.expanded, null, .{}, &namespaces, &report);
            const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, title, .language, metadata);
            try std.testing.expectEqualDeep(whole.entry.sections, decoded.entry.sections);
            try std.testing.expectEqualDeep(whole.entry.references, decoded.entry.references);
            try std.testing.expectEqualDeep(whole.entry.media, decoded.entry.media);
            try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
        }
    }
}

const SourceEquivalentLanguageTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tmadwiktionary\n# dump-date\t20261001\n# content-language\tmad\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tBhengkek\tFile\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tfiles\n" ++
        "10\tCèṭa'an\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tBhângsa\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tmad\n# mediawiki\nmad\tMadhurâ\tmad\tMadurese\nen\tEnglish\ten\n";
    // Exact retained p6033/r27385 and p6034/r14091; the redirect identities
    // below are retained p6035/r14092 and p6037/r14094.
    const wrapper = "[[{{mad}}]]<includeonly>[[Category:Oca' {{mad}}]]</includeonly><noinclude>[[Category:Cèta'an]]</noinclude>";
    const leaf = "Bhâsa Madhurâ";
    const Variant = enum { ordinary, wrong, missing, cycle, wrapper_parameter, leaf_parameter, leaf_markup, conflicting_seed, conflicting_alias, no_seed };
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, variant: Variant) !void {
        const registry_text = switch (variant) {
            .conflicting_seed => registry ++ "fr\tFrench\tFrench\n",
            .conflicting_alias => registry ++ "fr\tFrench\tMadura\n",
            .no_seed => "# content-language\tmad\n# mediawiki\nmad\tOther Madurese\nen\tEnglish\ten\n",
            else => registry,
        };
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry_text });
        const wrapper_source = if (variant == .wrapper_parameter) "[[{{mad|{{{1}}}}}]]<includeonly>[[Category:Oca' {{mad}}]]</includeonly><noinclude>[[Category:Cèta'an]]</noinclude>" else wrapper;
        const leaf_source = switch (variant) { .leaf_parameter => "Bhâsa {{{1|Madhurâ}}}", .leaf_markup => "'''Bhâsa Madhurâ'''", else => leaf };
        const alias_target = switch (variant) { .wrong => "Cèṭa'an:other", .missing => "Cèṭa'an:absent", .cycle => "Cèṭa'an:Madura", else => "Cèṭa'an:madura" };
        var index: std.ArrayList(u8) = .empty;
        try index.appendSlice(a, "0\t0\tCèṭa'an:madura\t\t6033\t27385\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n");
        try index.appendSlice(a, "0\t0\tCèṭa'an:mad\t\t6034\t14091\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n");
        try index.appendSlice(a, "0\t0\tCèṭa'an:Madhurâ\tCèṭa'an:madura\t6035\t14092\t2026-10-01T00:00:00Z\tA\twikitext\t10\t0\t0\n");
        try index.appendSlice(a, try std.fmt.allocPrint(a, "0\t0\tCèṭa'an:Madura\t{s}\t6037\t14094\t2026-10-01T00:00:00Z\tA\twikitext\t10\t0\t0\n", .{alias_target}));
        try index.appendSlice(a, "0\t0\tCèṭa'an:other\t\t9001\t9001\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n");
        if (variant == .conflicting_seed) try index.appendSlice(a, "0\t0\tCèṭa'an:French\tCèṭa'an:madura\t9000\t9000\t2026-10-01T00:00:00Z\tA\twikitext\t10\t0\t0\n");
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root);
        defer writer.deinit();
        try writer.append(0, 6033, 27385, wrapper_source);
        try writer.append(1, 6034, 14091, leaf_source);
        try writer.append(4, 9001, 9001, wrapper_source);
        const path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = index.items });
        try writer.finish(path);
    }
};

test "source-equivalent language templates require trusted seed wrapper leaf and acyclic redirects" {
    for (std.meta.tags(SourceEquivalentLanguageTest.Variant)) |variant| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try SourceEquivalentLanguageTest.install(io, a, root, variant);
        var namespaces = try namespace_registry.Registry.init(a, SourceEquivalentLanguageTest.namespaces); defer namespaces.deinit();
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        switch (variant) {
            .ordinary => {
                try std.testing.expectEqualStrings("mad", registry.resolveTrusted("Madura").?.code);
                try std.testing.expectEqualStrings("mad", registry.resolveTrusted("madura").?.code);
                try std.testing.expectEqualStrings("mad", registry.resolveTrusted("Madhurâ").?.code);
                try std.testing.expect(registry.resolveTrusted("Bhâsa Madhurâ") == null);
                try registry.addLocalAlias("Madura", "en");
                try registry.addLocalAlias("Madura", "mad");
                try std.testing.expect(registry.resolveTrusted("Madura") == null);
            },
            .conflicting_alias => try std.testing.expectEqualStrings("fr", registry.resolve("Madura").?.code),
            else => try std.testing.expect(registry.resolve("Madura") == null),
        }
        try std.testing.expectEqualStrings("en", registry.resolveTrusted("English").?.code);
        try std.testing.expect(registry.resolve("Unrelated") == null);
    }
}

test "source-equivalent MAD headings retain both real aliases unrelated owners and full compiled bodies" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try SourceEquivalentLanguageTest.install(io, a, root, .ordinary);
    var namespaces = try namespace_registry.Registry.init(a, SourceEquivalentLanguageTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    // Complete retained adsak p118/r26802 body after its language heading.
    const raw_body = "\n\n=== Carakan ===\n[[ꦲꦢ꧀ꦱꦏ꧀]]\n\n=== Oca' lako ===\n\n=== Keccap ===\n[[Bhengkek:LL-Q36213 (mad)-WiniSJ-adsak.wav|jmpl|nir]]\n\n; Pertalan\n\n* bhâsa Indonesia: datang\n\n; Conto\n\n# Hj. Maimunah '''adsak''' dâri umroh\n\n== Sombher ==\nPrawitra, Adrian. \"Kamus Lengkap Bahasa Madura Indonesia\".Dian Rakyat. 2009. hal. 6";
    const expanded = "== [[Bhâsa Madhurâ]][[Category:Oca' Bhâsa Madhurâ]] ==" ++ raw_body;
    for ([_][]const u8{ "Madura", "Madhurâ" }) |name| {
        const raw = try std.fmt.allocPrint(a, "== {{{{{s}}}}} =={s}", .{ name, raw_body });
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, name, expanded, raw, null);
    }
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "unrelated", "==English==\n===Noun===\n# unrelated owner body\n", "==English==\n===Noun===\n# unrelated owner body\n", null);
    _ = try writer.finish(codes);
    for ([_][]const u8{ "mad", "en" }) |code| {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(if (std.mem.eql(u8, code, "mad")) "Madhurâ" else "English", &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        if (std.mem.eql(u8, code, "mad")) {
            const new_record = (try index.find("Madura")).?;
            const trusted_record = (try index.find("Madhurâ")).?;
            const actual = try encoder.presentation_codec.decodeAlloc(a, new_record.payload, new_record.title, .language, metadata);
            var expected = try encoder.presentation_codec.decodeAlloc(a, trusted_record.payload, trusted_record.title, .language, metadata);
            // Record identity is the sole intentional difference. Deep equality
            // covers all sections, block/list/layout relations, styles, link
            // actions, references, media, display title, preamble and metadata.
            expected.entry.title = actual.entry.title;
            try std.testing.expectEqualDeep(expected, actual);
            var bold_adsak: usize = 0;
            var audio: usize = 0;
            var visible: std.ArrayList(u8) = .empty;
            for (actual.entry.sections) |section| {
                try visible.appendSlice(a, section.title);
                for (section.blocks) |block| for (block.spans) |span| {
                    try visible.appendSlice(a, span.text);
                    if (std.mem.eql(u8, span.text, "adsak")) {
                        try std.testing.expect(span.bold);
                        bold_adsak += 1;
                    }
                    try std.testing.expect(!std.mem.startsWith(u8, span.target, "Category:"));
                    try std.testing.expect(!std.mem.startsWith(u8, span.target, "Bhângsa:"));
                };
            }
            for (actual.entry.media) |media| {
                if (std.mem.eql(u8, media.file, "LL-Q36213 (mad)-WiniSJ-adsak.wav")) audio += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), bold_adsak);
            try std.testing.expectEqual(@as(usize, 1), audio);
            try std.testing.expect(std.mem.indexOf(u8, visible.items, "Prawitra, Adrian. \"Kamus Lengkap Bahasa Madura Indonesia\".Dian Rakyat. 2009. hal. 6") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible.items, "Oca' Bhâsa Madhurâ") == null);
        }
        for ([_][]const u8{ "Madura", "Madhurâ", "unrelated" }) |title| {
            const record = try index.find(title);
            const expected = std.mem.eql(u8, code, if (std.mem.eql(u8, title, "unrelated")) "en" else "mad");
            try std.testing.expectEqual(expected, record != null);
            if (record) |value| {
                const decoded = try encoder.presentation_codec.decodeAlloc(a, value.payload, value.title, .language, metadata);
                try std.testing.expectEqualStrings(code, decoded.entry.language_code);
                const bodies: []const []const u8 = if (std.mem.eql(u8, code, "mad")) &.{ "datang", "Hj. Maimunah", "dâri umroh", "Prawitra, Adrian." } else &.{"unrelated owner body"};
                for (bodies) |text|
                    try std.testing.expect(std.mem.indexOf(u8, value.payload, text) != null);
            }
        }
    }
}

// Synthetic diagnostic boundary; does not reconstruct the lost YI expansion.
test "UncompiledTemplate capture preserves exact payload and propagation without retry reclassification" {
    const F = FirstFailureControl;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "complete", "missing-marker", "existing-capture" }) |mode| {
        const root = try auditControlFreshRoot(a, "uncompiled-template-capture-" ++ mode);
        defer std.Io.Dir.cwd().deleteTree(F.io, root) catch {};
        const capture_root = try std.fs.path.join(a, &.{ root, ".presentation-first-failure" });
        if (comptime !std.mem.eql(u8, mode, "missing-marker")) try F.marker(a, root);
        if (comptime std.mem.eql(u8, mode, "existing-capture"))
            try std.Io.Dir.cwd().writeFile(F.io, .{ .sub_path = capture_root, .data = "retained first capture" });
        try std.testing.expect(first_failure_capture_context == null and failure_receipt_context == null);
        first_failure_capture_context = F.context(a, root);
        defer first_failure_capture_context = null;
        const receipt = try std.fs.path.join(a, &.{ root, "outer-failure.json" });
        failure_receipt_context = .{ .io = F.io, .a = a, .path = receipt,
            .invocation_id = F.context(a, root).invocation_id.?, .invocation_args = &F.args };
        defer failure_receipt_context = null;
        const job: ExpansionJob = .{ .ordinal = 23, .index_offset = 19,
            .ns = .{ .id = 0, .kind = .language }, .title = "Synthetic uncompiled template failure",
            .source = "raw {{fixture|x}}\n[[target|label]]", .page_id = 31, .revision_id = 47,
            .index_line = "exact synthetic index row" };
        const expanded: bundle_expander.Expansion = .{ .source = "expanded {{unexpanded|x}}\n[[target|label]]",
            .display_title = "display fixture", .poem_metadata = "[]", .missing_dependency_metadata = "{}" };
        var writer = try encoder.blob_builder.Writer.init(F.io, a, try std.fs.path.join(a, &.{ root, "writer" }));
        defer writer.deinit();
        try std.testing.expect(!auditablePresentationError(error.UncompiledTemplate));
        captureFirstPresentationFailure(error.OutOfMemory, job, expanded);
        try std.testing.expect(!first_failure_capture_context.?.attempted);
        try std.testing.expectError(error.UncompiledTemplate, consumePresentationFailure(&writer, job, expanded, a, null, error.UncompiledTemplate));
        try std.testing.expect(first_failure_capture_context.?.attempted);
        try std.testing.expect(recordPresentationFailure(error.UncompiledTemplate, job) == error.UncompiledTemplate);
        try F.absent(receipt);
        if (comptime std.mem.eql(u8, mode, "complete")) {
            const row = try F.manifest(a, root);
            try std.testing.expect(row.object.get("record_complete").?.bool and row.object.get("diagnostic_only").?.bool);
            try std.testing.expect(!row.object.get("publication_created").?.bool and !row.object.get("semantic_acceptance").?.bool);
            try std.testing.expectEqualStrings("UncompiledTemplate", row.object.get("error_name").?.string);
            try std.testing.expectEqualStrings(job.title, row.object.get("title").?.string);
            try std.testing.expectEqual(@as(i64, 23), row.object.get("ordinal").?.integer);
            try std.testing.expectEqual(@as(i64, 19), row.object.get("index_offset").?.integer);
            try std.testing.expectEqual(@as(i64, 31), row.object.get("page_id").?.integer);
            try std.testing.expectEqual(@as(i64, 47), row.object.get("revision_id").?.integer);
            try F.payload(a, row, "raw_source", job.source, 256 * 1024);
            try F.payload(a, row, "expanded", expanded.source, 2 * 1024 * 1024);
            try F.payload(a, row, "index_row", job.index_line, 256 * 1024);
            try F.payload(a, row, "display_title", expanded.display_title.?, 256 * 1024);
            try F.payload(a, row, "poem_metadata", expanded.poem_metadata.?, 256 * 1024);
            try F.payload(a, row, "missing_dependency_metadata", expanded.missing_dependency_metadata.?, 256 * 1024);
            const path = try std.fs.path.join(a, &.{ capture_root, "capture.json" });
            const before = try std.Io.Dir.cwd().readFileAlloc(F.io, path, a, .limited(64 * 1024));
            captureFirstPresentationFailure(error.UncompiledPresentation, job, .{ .source = "replacement" });
            const after = try std.Io.Dir.cwd().readFileAlloc(F.io, path, a, .limited(64 * 1024));
            try std.testing.expectEqualSlices(u8, before, after);
        } else if (comptime std.mem.eql(u8, mode, "existing-capture")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(F.io, capture_root, a, .limited(64));
            try std.testing.expectEqualStrings("retained first capture", bytes);
        } else try F.absent(capture_root);
        try F.noPublication(a, root);
    }
}

test "normal Writer reviewed exact heading preserves complete body actions and codec" {
    for ([_]bool{ false, true }) |attested| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, AutonymLoaderTest.namespaces); defer namespaces.deinit();
        try AutonymLoaderTest.install(io, a, root, null);
        if (attested) {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
            const rows = try std.fmt.allocPrint(a, "{s}# reviewed-alias\tur\tاُردو\tnwe-urdu-exact-v1\t{s}\n", .{AutonymLoaderTest.registry, std.fmt.bytesToHex(hash, .lower)});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, "language-registry.tsv"}), .data = rows });
        }
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        const codes = languageCodes(&registry, &namespaces);
        const output = try std.fs.path.join(a, &.{ root, "blobs" });
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
        writer.language_codes = codes;
        const source = "== اُردو ==\n# Definition '''bold''' [[target|label]].\n";
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "synthetic-autonym", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const owner = if (attested) "Urdu" else "Unclassified";
        const expected_code = if (attested) "ur" else "";
        const path = try std.fs.path.join(a, &.{ output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename) });
        var mapped = try mmapPath(io, path); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes);
        const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings(expected_code, metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("synthetic-autonym")) orelse return error.TestUnexpectedResult;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(expected_code, decoded.entry.language_code);
        try std.testing.expectEqualStrings("synthetic-autonym", decoded.entry.title);
        var headings: usize = 0; var definitions: usize = 0; var links: usize = 0; var bold: usize = 0;
        for (decoded.entry.sections) |section| {
            if (section.level == 2 and std.mem.eql(u8, section.title, "اُردو")) headings += 1;
            for (section.blocks) |block| {
                if (block.kind == .definition) definitions += 1;
                for (block.spans) |span| {
                    if (std.mem.eql(u8, span.target, "target")) {
                        try std.testing.expect(span.kind == .link);
                        try std.testing.expectEqualStrings("label", span.text);
                        links += 1;
                    }
                    if (std.mem.eql(u8, span.text, "bold") and span.bold) bold += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 1), headings);
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), links);
        try std.testing.expectEqual(@as(usize, 1), bold);
        const encoded = try encoder.presentation_codec.encodeAlloc(a, decoded);
        try std.testing.expectEqualSlices(u8, record.payload, encoded);
    }
}

test "reviewed exact alias retains complete p10 r229761 section payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    // Exact partition: Saraiki stays owned; Urdu leaves the old unclassified
    // record; the meaningful pre-language prefix remains unclassified.
    var baseline_sections: [3]?[]const u8 = .{null, null, null};
    for ([_]bool{false, true}) |reviewed| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var namespaces = try namespace_registry.Registry.init(a, AutonymLoaderTest.namespaces); defer namespaces.deinit();
        try AutonymLoaderTest.install(io, a, root, null);
        if (reviewed) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &digest, .{});
            const rows = try std.fmt.allocPrint(a, "{s}# reviewed-alias\tur\tاُردو\tnwe-urdu-exact-v1\t{s}\n", .{AutonymLoaderTest.registry, std.fmt.bytesToHex(digest, .lower)});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, "language-registry.tsv"}), .data = rows });
        }
        var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
        const codes = languageCodes(&registry, &namespaces);
        const output = try std.fs.path.join(a, &.{root, "blobs"});
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
        writer.language_codes = codes;
        const source = @embedFile("reviewed_alias_p10_r229761.wikitext");
        try std.testing.expectEqual(@as(usize, 1660), source.len);
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ہَݙا", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, if (reviewed) 3 else 2), stats.language_records);
        const owners: []const []const u8 = if (reviewed)
            &.{"سرائیکی", "Urdu", "Unclassified"}
        else
            &.{"سرائیکی", "Unclassified"};
        for (owners, 0..) |owner, ordinal| {
            var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
            const path = try std.fs.path.join(a, &.{output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename)});
            var mapped = try mmapPath(io, path); defer mapped.deinit();
            const blob = try encoder.blob_format.inspect(mapped.bytes);
            const metadata = try blob.languageMetadata();
            try std.testing.expectEqualStrings(if (ordinal == 0) "skr" else if (reviewed and ordinal == 1) "ur" else "", metadata.code);
            var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
            const record = (try index.find("ہَݙا")) orelse return error.TestUnexpectedResult;
            const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            const sections = decoded.entry.sections;
            if (!reviewed and ordinal == 1) {
                // The prefix and final unresolved reference heading remain
                // unclassified. All middle Urdu sections stay complete, including
                // the second H1 inside the first Urdu range.
                try std.testing.expect(sections.len > 2);
                try std.testing.expectEqual(@as(u8, 1), sections[0].level);
                try std.testing.expectEqualStrings("ہَݙا", sections[0].title);
                try std.testing.expectEqual(@as(usize, 2), sections[0].blocks.len);
                try std.testing.expectEqual(@as(u8, 2), sections[1].level);
                try std.testing.expectEqualStrings("اُردو", sections[1].title);
                const last = sections.len - 1;
                try std.testing.expectEqual(@as(u8, 2), sections[last].level);
                try std.testing.expectEqualStrings("حوالہ", sections[last].title);
                const unclassified = try a.alloc(@TypeOf(sections[0]), 2);
                unclassified[0] = sections[0];
                unclassified[1] = sections[last];
                baseline_sections[2] = try std.json.Stringify.valueAlloc(a, unclassified, .{});
                baseline_sections[1] = try std.json.Stringify.valueAlloc(a, sections[1..last], .{});
            } else {
                const complete = try std.json.Stringify.valueAlloc(a, sections, .{});
                if (!reviewed) baseline_sections[ordinal] = complete else
                    try std.testing.expectEqualStrings(baseline_sections[ordinal].?, complete);
            }
            const encoded = try encoder.presentation_codec.encodeAlloc(a, decoded);
            try std.testing.expectEqualSlices(u8, record.payload, encoded);
        }
    }
}

const IsParagraphTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tiswiktionary\n# dump-date\t20261001\n# content-language\tis\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n10\tSnið\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tFlokkur\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tis\n# mediawiki\nis\tíslenska\nde\tþýska\tÞýska\nen\tEnglish\n";
    // Exact XML text of Snið:-de-, p2831/r393255, verified selected dump.
    const template_raw = "Þýska&lt;noinclude&gt;[[Flokkur:Tungumálasnið]]&lt;/noinclude&gt;&lt;includeonly&gt;[[Flokkur:Þýska]]&lt;/includeonly&gt;";
    const emission = "Þýska[[Flokkur:Þýska]]";
    // Marked synthetic expanded body; no actual native expansion is claimed.
    const expanded = emission ++ "\n{| class=\"wikitable\"\n| '''bold''' [[target|label]] || ''italic''\n|}\n:[[Auto]] [[Versicherung|versicherung]] <sup>2</sup>.\n";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = "" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = registry });
        const index = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index, .data = "0\t0\tSnið:-de-\t\t2831\t393255\t2025-01-01T00:00:00Z\tA\twikitext\t10\t1\t1\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root); defer writer.deinit();
        try writer.append(0, 2831, 393255, template_raw); try writer.finish(index);
    }
};

test "literal paragraph declaration requires exact known name and same owner hidden category" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator();
    var namespaces = try namespace_registry.Registry.init(a, IsParagraphTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(IsParagraphTest.registry);
    const source = try xml_decode.decodeSinglePassAlloc(a, IsParagraphTest.template_raw);
    const proof = source_language_banner.parseParagraph(source, &namespaces, null, &registry, "de").?;
    try std.testing.expectEqualStrings("Þýska", proof.label);
    try std.testing.expectEqualStrings("[[Flokkur:Þýska]]", proof.category);
    try std.testing.expect(source_language_banner.parse(source, &namespaces, null, &registry, "de") == null);
    try registry.addSourceLanguageParagraph("de", proof);
    try std.testing.expect(registry.matchesSourceLanguageParagraph("de", IsParagraphTest.emission));
    try std.testing.expect(!registry.matchesSourceLanguageParagraph("de", "Þýska"));
    try std.testing.expect(!registry.matchesSourceLanguageParagraph("en", IsParagraphTest.emission));
    for ([_][]const u8{
        " Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska]]</includeonly>",
        "prefix Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska]]</includeonly>",
        "<nowiki>Þýska</nowiki><noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska]]</includeonly>",
        "Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:English]]</includeonly>",
        "Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[:Flokkur:Þýska]]</includeonly>",
        "Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska|sort]]</includeonly>",
        "Þýska<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska]]</includeonly>extra",
        "{{{name|Þýska}}}<noinclude>[[Flokkur:Doc]]</noinclude><includeonly>[[Flokkur:Þýska]]</includeonly>",
    }) |bad| try std.testing.expect(source_language_banner.parseParagraph(bad, &namespaces, null, &registry, "de") == null);
    try registry.addTsv("# mediawiki\nen\tEnglish\tÞýska\n");
    try std.testing.expect(source_language_banner.parseParagraph(source, &namespaces, null, &registry, "de") == null);
    try std.testing.expect(!registry.matchesSourceLanguageParagraph("de", IsParagraphTest.emission));
}

test "Writer literal paragraph owner preserves complete original body styles links and codec" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try IsParagraphTest.install(io, a, root);
    var namespaces = try namespace_registry.Registry.init(a, IsParagraphTest.namespaces); defer namespaces.deinit();
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    try std.testing.expectEqualStrings("en", (registry.resolve("English") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings("de", (registry.resolve("Þýska") orelse return error.TestUnexpectedResult).code);
    try std.testing.expect(registry.matchesSourceLanguageParagraph("de", IsParagraphTest.emission));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("de", "Þýska", 2));
    const codes = languageCodes(&registry, &namespaces); const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    const cases = [_]struct { raw: []const u8, expanded: []const u8, owned: bool = false }{
        .{ .raw = "{{-de-}}\n{{body}}\n", .expanded = IsParagraphTest.expanded, .owned = true },
        .{ .raw = "\n{{-de-}}\n{{body}}\n", .expanded = "\n" ++ IsParagraphTest.expanded, .owned = true },
        .{ .raw = " {{-de-}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "\t{{-de-}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "prefix {{-de-}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "<nowiki>{{-de-}}</nowiki>\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "<!--{{-de-}}-->\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "{{-de-|parameter}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "{{-en-}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "{{-de-}}\n{{-en-}}\n", .expanded = IsParagraphTest.expanded },
        .{ .raw = "{{-de-}}\n", .expanded = "prefix\n" ++ IsParagraphTest.expanded },
        .{ .raw = "{{-de-}}\n", .expanded = " " ++ IsParagraphTest.expanded },
        .{ .raw = "{{-de-}}\n", .expanded = "Þýska\nbody\n" },
        .{ .raw = "{{-de-}}\n", .expanded = "Þýska[[Flokkur:English]]\nbody\n" },
        .{ .raw = "{{-de-}}\n", .expanded = IsParagraphTest.expanded ++ "[[Flokkur:English]]\n" },
        .{ .raw = "{{-de-}}\n== Unknown boundary ==\n", .expanded = IsParagraphTest.expanded ++ "== Unknown boundary ==\nbody\n" },
    };
    for (cases, 0..) |case, i| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "paragraph-control-{d}", .{i}), case.expanded, case.raw, null);
    const stats = try writer.finish(codes); try std.testing.expectEqual(@as(usize, cases.len), stats.language_records);
    for (cases, 0..) |case, i| {
        const owner = if (case.owned) "þýska" else "Unclassified";
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename(owner, &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata(); var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const title = try std.fmt.allocPrint(a, "paragraph-control-{d}", .{i});
        const record = (try index.find(title)) orelse {
            std.debug.print("missing required paragraph record: title={s}, expected owner={s}\n", .{ title, owner });
            return error.TestUnexpectedResult;
        };
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (case.owned) "de" else "", decoded.entry.language_code);
        var report: encoder.presentation_document.Fallbacks = .{};
        const whole_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, title, .language, owner, metadata.code, case.expanded, null, .{}, &namespaces, &report);
        const whole = try encoder.presentation_codec.decodeAlloc(a, whole_payload, title, .language, metadata);
        try std.testing.expectEqualDeep(whole.entry.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(whole.entry.references, decoded.entry.references);
        try std.testing.expectEqualDeep(whole.entry.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
        if (case.owned) {
            try std.testing.expectEqual(@as(usize, 1), decoded.entry.sections.len);
            const first = decoded.entry.sections[0].blocks[0];
            try std.testing.expect(first.kind == .paragraph);
            try std.testing.expectEqualStrings("Þýska", first.spans[0].text);
        }
    }
}

const DvShyOwnerTest = struct {
    const ns_shy = "# wikidict-namespace-registry-v1\n# wiki\tshywiktionary\n# dump-date\t20261001\n# content-language\tshy\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n6\tBhengkek\tFile\tcase-sensitive\t1\t0\t0\t\tcompile_only\tfiles\n10\tTamudemt\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tTaggayt\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n828\tAmṣada\tModule\tcase-sensitive\t1\t0\t0\tScribunto\tcompile_only\tmodules\n";
    const ns_dv = "# wikidict-namespace-registry-v1\n# wiki\tdvwiktionary\n# dump-date\t20261001\n# content-language\tdv\n0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n6\tފައިލް\tFile\tcase-sensitive\t1\t0\t0\t\tcompile_only\tfiles\n10\tފަންވަތް\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n14\tޤިސްމު\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const dv_registry = "# content-language\tdv\n# mediawiki\ndv\tދިވެހިބަސް\tdv\nen\tEnglish\n";
    const shy_registry = "# content-language\tshy\n# mediawiki\nshy\tShawiya\tTacawit\ttacawit\nen\tEnglish\n";
    fn file(io: std.Io, a: std.mem.Allocator, root: []const u8, name: []const u8, bytes: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, name}), .data = bytes });
    }
    fn nom(io: std.Io, a: std.mem.Allocator, root: []const u8, title: []const u8, source: []const u8, tamper: bool) !void {
        try file(io, a, root, "language-registry.tsv", shy_registry);
        try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{root, "modules"}));
        try file(io, a, root, "modules/4218.lua", if (tamper) "return {}" else source);
        var hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
        const digest = std.fmt.bytesToHex(hash, .lower);
        try file(io, a, root, "manifest.jsonl", try std.json.Stringify.valueAlloc(a, .{ .title = title, .page_id = @as(u64, 4218), .sha256 = digest[0..] }, .{}));
    }
};

test "DV bare source banner retains explicit code proof without a new alias or fake root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    var ns = try namespace_registry.Registry.init(a, DvShyOwnerTest.ns_dv); defer ns.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(DvShyOwnerTest.dv_registry);
    const source = @embedFile("testdata/dv-bare-banner.wikitext");
    const proof = source_language_banner.parse(source, &ns, null, &registry, "dv") orelse return error.TestUnexpectedResult;
    try std.testing.expect(proof.authority == .literal_code and proof.level == 1);
    try std.testing.expectEqualStrings("ދިވެހި", proof.label);
    try std.testing.expect(registry.resolveTrusted("ދިވެހި") == null);
    const fake = try std.mem.replaceOwned(u8, a, source, "(dv)", "(en)");
    try std.testing.expect(source_language_banner.parse(fake, &ns, null, &registry, "dv") == null);
    for ([_][]const u8{ "English", "{{{label}}}", "<nowiki>ދިވެހި</nowiki>", "<big>ދިވެހި</big>" }) |label| {
        const bad = try std.mem.replaceOwned(u8, a, source, "<big>ދިވެހި<small>", try std.fmt.allocPrint(a, "<big>{s}<small>", .{label}));
        try std.testing.expect(source_language_banner.parse(bad, &ns, null, &registry, "dv") == null);
    }
    const indented = try std.mem.replaceOwned(u8, a, source, "=<div", " =<div");
    try std.testing.expect(source_language_banner.parse(indented, &ns, null, &registry, "dv") == null);
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try DvShyOwnerTest.file(io, a, root, "language-registry.tsv", DvShyOwnerTest.dv_registry);
    try DvShyOwnerTest.file(io, a, root, "manifest.jsonl", "");
    const index_path = try std.fs.path.join(a, &.{root, "page-index.tsv"});
    try DvShyOwnerTest.file(io, a, root, "page-index.tsv", "0\t0\tފަންވަތް:-dv-\t\t2048\t3925\t2026-10-01T00:00:00Z\tA\twikitext\t10\t1\t0\n");
    var templates = try dump_source.TemplateSourceWriter.init(io, a, root); defer templates.deinit();
    try templates.append(0, 2048, 3925, source); try templates.finish(index_path);
    var loaded = try loadLanguageRegistry(io, a, root, &ns); defer loaded.deinit();
    try std.testing.expect(loaded.matchesSourceLanguageBanner("dv", proof.heading, 1));
    try std.testing.expect(loaded.resolveTrusted(proof.label) == null);
    const codes = languageCodes(&loaded, &ns); const output = try std.fs.path.join(a, &.{root, "blobs"});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    const body = "\n'''lemma'''\n:[1] ...\n{|\n| [[chair]] || '''bold''' [https://example.test label]\n|}\n";
    const expanded = try std.mem.concat(a, u8, &.{source, body});
    const roots = [_][]const u8{ "{{-dv-}}\nbody", "{{-dv-|parameter}}", "<nowiki>{{-dv-}}</nowiki>", "prefix\n{{-dv-}}" };
    for (roots, 0..) |raw, i| try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, try std.fmt.allocPrint(a, "dv-{d}", .{i}), expanded, raw, null);
    _ = try writer.finish(codes);
    for (roots, 0..) |_, i| {
        const owner = if (i == 0) "ދިވެހިބަސް" else "Unclassified";
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{output, "languages", encoder.blob_catalog.languageBlobFilename(owner, &filename)})); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata(); var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find(try std.fmt.allocPrint(a, "dv-{d}", .{i}))).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings(if (i == 0) "dv" else "", decoded.entry.language_code);
        try std.testing.expectEqual(@as(usize, 0), decoded.entry.organization.lexemes.len);
        var report: encoder.presentation_document.Fallbacks = .{};
        const expected_bytes = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, record.title, .language, owner, metadata.code, expanded, null, .{}, &ns, &report);
        const expected = try encoder.presentation_codec.decodeAlloc(a, expected_bytes, record.title, .language, metadata);
        try std.testing.expectEqualDeep(expected.entry.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(expected.entry.media, decoded.entry.media);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

test "normal nom provider loader authenticates complete source and retains typed body without POS inference" {
    const source = @embedFile("testdata/shy-nom-data.lua");
    for ([_][]const u8{ "Amṣada:langues/data", "Module:langues/data", "Amṣada:langues/data/doc", "Tamudemt:langues/data" }) |title| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup(); var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try DvShyOwnerTest.nom(io, a, root, title, source, false);
        var ns = try namespace_registry.Registry.init(a, DvShyOwnerTest.ns_shy); defer ns.deinit();
        var registry = try loadLanguageRegistry(io, a, root, &ns); defer registry.deinit();
        const accepted = std.mem.eql(u8, title, "Amṣada:langues/data") or std.mem.eql(u8, title, "Module:langues/data");
        if (!accepted) { try std.testing.expect(registry.resolveTrusted("Tacawit") == null); continue; }
        try std.testing.expectEqualStrings("shy", registry.resolveTrusted("Tacawit").?.code);
        const codes = languageCodes(&registry, &ns); const output = try std.fs.path.join(a, &.{root, "blobs"});
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
        const expanded = "==<span class=\"sectionlangue\" id=\"shy\">[[tacawit|Tacawit]]</span>==\n===Awal===\n'''axeddam'''\n# ''Iwafen ig khussan.''\n#* ''Ulac amedya.''\n{|\n! Asuf !! Asget\n|-\n| '''axeddam''' || [[travailleur]]\n|}\n[[File:LL-Q33274 (shy)-Reda Kerbouche-axeddam.wav]]\n";
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "axeddam", expanded, "=={{langue|shy}}==", null);
        _ = try writer.finish(codes);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{output, "languages", encoder.blob_catalog.languageBlobFilename("Shawiya", &filename)})); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata(); var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("axeddam")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualStrings("shy", decoded.entry.language_code);
        try std.testing.expectEqual(@as(usize, 0), decoded.entry.organization.lexemes.len);
        var report: encoder.presentation_document.Fallbacks = .{};
        const expected_bytes = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, record.title, .language, metadata.heading, metadata.code, expanded, null, .{}, &ns, &report);
        const expected = try encoder.presentation_codec.decodeAlloc(a, expected_bytes, record.title, .language, metadata);
        try std.testing.expectEqualDeep(expected.entry.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(expected.entry.media, decoded.entry.media);
        try std.testing.expectEqualDeep(expected.entry.references, decoded.entry.references);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup(); var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try DvShyOwnerTest.nom(io, a, root, "Amṣada:langues/data", source, true);
    var ns = try namespace_registry.Registry.init(a, DvShyOwnerTest.ns_shy); defer ns.deinit();
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &ns));
}

const LaSourceLanguageTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tlawiktionary\n# dump-date\t20261001\n# content-language\tla\n" ++
        "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tFasciculus\tFile\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tmedia\n" ++
        "10\tFormula\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "12\tAuxilium\tHelp\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tother\n" ++
        "14\tCategoria\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
        "828\tModulus\tModule\tfirst-letter\t1\t0\t0\tScribunto\tcompile_only\tmodules\n";
    const language_template = "[[Auxilium:Lingua Latina|{{int:wikt-la}}]]<noinclude>\n[[Categoria:Formulae linguarum|la]]\n</noinclude>";
    const banner = "<span class=\"caput-linguae\">[[Auxilium:Lingua Latina|Latine]][[Categoria:Index inversus|sunihpled]][[Categoria:Lingua Latina|delphinus]][[Categoria:Linguae Latinae index inversus|sunihpled]]</span>";
    // Source-instantiated banner and lexical body, not a captured expansion.
    // Extra expanded support boundaries deliberately prevent raw count alignment.
    const raw = "{{caput|la|delphinus}}\n=={{-lingua-|la|delphinus}}==\n{{substantivum|la}}\n# Animal mammiferum aquaticum.\n";
    const body = "==" ++ banner ++ "==\n===Nomen substantivum===\n'''delphinus'''\n# Animal mammiferum [[aquaticum]].<ref>Bibliographia ''Latina''.</ref>\n# Sidus forma delphinis.\n==Loci==\n''delphinus'' [[Gaius Plinius Secundus|Plinii]]\n==Fontes==\n<references/>\n";
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, module_source: []const u8, template_source: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "modules" }));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "language-registry.tsv" }), .data = "# content-language\tla\n# mediawiki\nla\tLatina\nen\tEnglish\n" });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(module_source, &digest, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "manifest.jsonl" }), .data = try std.fmt.allocPrint(a, "{{\"page_id\":24123,\"revision_id\":221631,\"title\":\"Modulus:languages/data2\",\"sha256\":\"{s}\"}}\n", .{std.fmt.bytesToHex(digest, .lower)}) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "24123.lua" }), .data = module_source });
        const index_path = try std.fs.path.join(a, &.{ root, "page-index.tsv" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tFormula:la\t\t959\t141120\t2016-06-03T21:47:32Z\tYaganZ\twikitext\t10\t1\t0\n" });
        var templates = try dump_source.TemplateSourceWriter.init(io, a, root);
        defer templates.deinit();
        try templates.append(0, 959, 141120, template_source);
        try templates.finish(index_path);
    }
};

test "named canonical language modules and exact message targets preserve independent source authority" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LaSourceLanguageTest.namespaces); defer namespaces.deinit();
    try LaSourceLanguageTest.install(io, a, root, laNamedCanonicalCapturedSource, LaSourceLanguageTest.language_template);
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    for ([_][]const u8{ "Latine", "Auxilium:Lingua Latina" }) |label| {
        const resolved = registry.resolveTrusted(label).?;
        try std.testing.expectEqualStrings("la", resolved.code);
        try std.testing.expectEqualStrings("Latina", resolved.heading);
    }
    for ([_][]const u8{ "Latinus", "Latinarum", "Auxilium:Latina", "Lingua Latina" }) |label|
        try std.testing.expect(registry.resolveTrusted(label) == null);
    try std.testing.expectEqualStrings("Auxilium:Lingua Latina", source_language_banner.messageLinkTarget(LaSourceLanguageTest.language_template, &namespaces, "la").?);
    for ([_][]const u8{
        "[[Auxilium:Lingua Latina|{{int:wikt-en}}]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Auxilium:Lingua Latina|{{int:wikt-la|x}}]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Auxilium:Lingua Latina|Latine]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Latina|{{int:wikt-la}}]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Auxilium:Lingua Latina#part|{{int:wikt-la}}]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Auxilium:Lingua Latina|{{int:wikt-la}}]]extra<noinclude>[[Categoria:Formulae linguarum]]</noinclude>",
        "[[Auxilium:Lingua Latina|{{int:wikt-la}}]]<noinclude><onlyinclude>[[Categoria:Formulae linguarum]]</onlyinclude></noinclude>",
    }) |source| try std.testing.expect(source_language_banner.messageLinkTarget(source, &namespaces, "la") == null);
    // Same original target assigned to a second source code remains ambiguous.
    try registry.addLocalAlias("Auxilium:Lingua Latina", "en");
    try std.testing.expect(registry.resolveTrusted("Auxilium:Lingua Latina") == null);
    try std.testing.expectEqualStrings("la", registry.resolveTrusted("Latine").?.code);
    // A code-named message template cannot attest a different hyphen template.
    const paragraph_root = try std.fs.path.join(a, &.{ root, "code-named-paragraph" });
    const paragraph_source = "Latina<noinclude>[[Categoria:Doc]]</noinclude><includeonly>[[Categoria:Latina]]</includeonly>";
    try LaSourceLanguageTest.install(io, a, paragraph_root, laNamedCanonicalCapturedSource, paragraph_source);
    var paragraph_registry = try loadLanguageRegistry(io, a, paragraph_root, &namespaces);
    defer paragraph_registry.deinit();
    // Prove this would be a valid paragraph shape if its template identity matched.
    try std.testing.expect(source_language_banner.parseParagraph(paragraph_source, &namespaces, null, &paragraph_registry, "la") != null);
    try std.testing.expect(!paragraph_registry.matchesSourceLanguageParagraph("la", "Latina[[Categoria:Latina]]"));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "modules", "24123.lua" }), .data = "return {}" });
    try std.testing.expectError(error.LanguageSourceIdentityMismatch, loadLanguageRegistry(io, a, root, &namespaces));
}

test "Latin source declared Help banner reaches Writer without changing body actions or codec" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LaSourceLanguageTest.namespaces); defer namespaces.deinit();
    try LaSourceLanguageTest.install(io, a, root, laNamedCanonicalCapturedSource, LaSourceLanguageTest.language_template);
    var registry = try loadLanguageRegistry(io, a, root, &namespaces); defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);
    const output = try std.fs.path.join(a, &.{ root, "blobs" });
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
    try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "delphinus", LaSourceLanguageTest.body, LaSourceLanguageTest.raw, null);
    _ = try writer.finish(codes);
    var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
    var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("Latina", &filename) })); defer mapped.deinit();
    const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
    var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
    const record = (try index.find("delphinus")).?;
    const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
    try std.testing.expectEqualStrings("la", decoded.entry.language_code);
    try std.testing.expectEqualStrings("Latina", metadata.heading);
    const reference_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, "delphinus", .language, "Latina", "la", LaSourceLanguageTest.body, null, .{}, &namespaces, null);
    const reference = try encoder.presentation_codec.decodeAlloc(a, reference_payload, "delphinus", .language, metadata);
    try std.testing.expectEqualDeep(reference.entry.sections, decoded.entry.sections);
    try std.testing.expectEqualDeep(reference.entry.references, decoded.entry.references);
    try std.testing.expectEqualDeep(reference.entry.media, decoded.entry.media);
    try std.testing.expectEqualDeep(reference.entry.organization, decoded.entry.organization);
    try std.testing.expectEqualStrings("Latine", decoded.entry.sections[0].title);
    var help_actions: usize = 0;
    var definitions: usize = 0;
    for (decoded.entry.sections) |section| for (section.blocks) |block| {
        if (block.kind == .definition) definitions += 1;
        for (block.spans) |span| if (span.kind == .link and std.mem.eql(u8, span.target, "Auxilium:Lingua Latina")) {
            try std.testing.expectEqualStrings("Latine", span.text);
            try std.testing.expectEqualStrings("caput-linguae", span.classes);
            help_actions += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 1), help_actions);
    try std.testing.expectEqual(@as(usize, 2), definitions);
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.references.len);
    try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
}

test "source declared Help banners decline missing conflicting and decorated authority" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var namespaces = try namespace_registry.Registry.init(a, LaSourceLanguageTest.namespaces); defer namespaces.deinit();
    const cases = [_]struct { module: []const u8 = "local m={};m['la']={canonicalName='Latine'};return m", template: []const u8 = LaSourceLanguageTest.language_template, heading: []const u8 = LaSourceLanguageTest.banner, conflict: bool = false }{
        .{ .module = "local m={};m['la']={otherNames={'Latine'}};return m" },
        .{ .module = "local m={};m['la']={canonicalName='Latine'};m['la'].canonicalName=change();return m" },
        .{ .template = "[[Auxilium:Lingua Latina|Latine]]<noinclude>[[Categoria:Formulae linguarum]]</noinclude>" },
        .{ .conflict = true },
        .{ .heading = "<span class=\"caput-linguae\">[[Auxilium:Lingua Latina|English]]</span>" },
        .{ .heading = "<span class=\"caput-linguae\">[[Auxilium:Other|Latine]]</span>" },
        .{ .heading = "<span class=\"caput-linguae\">[[Auxilium:Lingua Latina|Latine]] visible</span>" },
        .{ .heading = "<span class=\"caput-linguae\">[[Auxilium:Lingua Latina|Latine]][[:Categoria:visible]]</span>" },
        .{ .heading = "<span class=\"caput-linguae\" style=\"display:none\">[[Auxilium:Lingua Latina|Latine]]</span>" },
        .{ .heading = "<nowiki>" ++ LaSourceLanguageTest.banner ++ "</nowiki>" },
    };
    for (cases, 0..) |case, number| {
        const input = try std.fmt.allocPrint(a, "{s}/input-{d}", .{ root, number });
        try LaSourceLanguageTest.install(io, a, input, case.module, case.template);
        var registry = try loadLanguageRegistry(io, a, input, &namespaces); defer registry.deinit();
        if (case.conflict) try registry.addLocalAlias("Auxilium:Lingua Latina", "en");
        const codes = languageCodes(&registry, &namespaces);
        const output = try std.fs.path.join(a, &.{ input, "blobs" });
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit(); writer.language_codes = codes;
        const source = try std.fmt.allocPrint(a, "=={s}==\n# Preserved [[Target|body]]\n", .{case.heading});
        // No raw declaration is supplied: these are checks of the new source
        // authority route, not of the pre-existing raw-template alignment path.
        try writer.addPage(a, .{ .id = 0, .kind = .language }, "negative", source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        try std.testing.expectEqual(@as(usize, 1), stats.language_blobs);
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        var mapped = try mmapPath(io, try std.fs.path.join(a, &.{ output, "languages", encoder.blob_catalog.languageBlobFilename("Unclassified", &filename) })); defer mapped.deinit();
        const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
        try std.testing.expectEqualStrings("", metadata.code);
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("negative")).?;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        const reference_payload = try encoder.presentation_document.compileReportedWithLinkTrailAlloc(a, "negative", .language, "Unclassified", "", source, null, .{}, &namespaces, null);
        const reference = try encoder.presentation_codec.decodeAlloc(a, reference_payload, "negative", .language, metadata);
        try std.testing.expectEqualDeep(reference.entry.sections, decoded.entry.sections);
        try std.testing.expectEqualDeep(reference.entry.organization, decoded.entry.organization);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }
}

// Complete authenticated Modulus:languages/data2 p24123/r221631.
const laNamedCanonicalCapturedSource = "-- Module:languages/data2\n-- imported from en.wiktionary\n-- 2023-04-09 -- V28 -- +ia, last modified by Usor:YaganZ\n-- 2022-12-12 -- V27 -- +mh, ml, last modified by Usor:YaganZ\n-- 2022-08-20 -- V26 -- fa-translit module experimental, last modified by Usor:YaganZ\n-- 2022-08-14 -- V25 -- sh-translit module, last modified by Usor:YaganZ\n-- 2021-12-27 -- V24 -- bn, ma, sc experimental, last modified by Usor:YaganZ\n-- 2021-03-14 -- V23 -- +kv = kpv = Komiense, last modified by Usor:YaganZ\n-- 2020-12-06 -- V22 -- +cu, last modified by Usor:YaganZ\n-- 2020-10-14 -- V21 -- +oj, last modified by Usor:YaganZ\n-- 2020-07-16 -- V20 -- +genplf, last modified by Usor:YaganZ\n-- canonicalNames are translated into Latin adverbial, ablative or neuter forms (if available in Categoria:Formulae linguarum),\n-- missing entries added.\n-- otherNames 1-6 are used for mostly used inflected forms, 7=own name, 8=non-inflected form, 9-n are rarely used inflected forms:\n-- 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf, 7=ipsa, 8=nomsgm, 9=ablsgf, 10=genplf\n\nlocal u = mw.ustring.char\n\n-- UTF-8 encoded strings for some commonly-used diacritics\nlocal GRAVE     = u(0x0300)\nlocal ACUTE     = u(0x0301)\nlocal CIRC      = u(0x0302)\nlocal TILDE     = u(0x0303)\nlocal MACRON    = u(0x0304)\nlocal BREVE     = u(0x0306)\nlocal DOTABOVE  = u(0x0307)\nlocal DIAER     = u(0x0308)\nlocal CARON     = u(0x030C)\nlocal DGRAVE    = u(0x030F)\nlocal INVBREVE  = u(0x0311)\nlocal DOTBELOW  = u(0x0323)\nlocal RINGBELOW = u(0x0325)\nlocal CEDILLA   = u(0x0327)\n\n-- Puncuation to be used for standardChars field\n-- local PUNCTUATION = ' \\!\\#\\$\\%\\&\\*\\+\\,\\-\\.\\/\\:\\;\\<\\=\\>\\?\\@\\^\\_\\`\\|\\~\\'\\(\\)'\n\n-- UTF-8 encoded strings for some commonly-used diacritics.\nlocal c = {\n\tgrave\t\t\t= u(0x0300),\n\tacute\t\t\t= u(0x0301),\n\tcirc\t\t\t= u(0x0302),\n\ttilde\t\t\t= u(0x0303),\n\tmacron\t\t\t= u(0x0304),\n\toverline\t\t= u(0x0305),\n\tbreve\t\t\t= u(0x0306),\n\tdotabove\t\t= u(0x0307),\n\tdiaer\t\t\t= u(0x0308),\n\tringabove\t\t= u(0x030A),\n\tdacute\t\t\t= u(0x030B),\n\tcaron\t\t\t= u(0x030C),\n\tlineabove\t\t= u(0x030D),\n\tdgrave\t\t\t= u(0x030F),\n\tinvbreve\t\t= u(0x0311),\n\tcommaabove\t\t= u(0x0313),\n\trevcommaabove\t= u(0x0314),\n\tdotbelow\t\t= u(0x0323),\n\tdiaerbelow\t\t= u(0x0324),\n\tringbelow\t\t= u(0x0325),\n\tcedilla\t\t\t= u(0x0327),\n\togonek\t\t\t= u(0x0328),\n\tbrevebelow\t\t= u(0x032E),\n\tmacronbelow\t\t= u(0x0331),\n\tperispomeni\t\t= u(0x0342),\n\typogegrammeni\t= u(0x0345),\n\tCGJ\t\t\t\t= u(0x034F), -- combining grapheme joiner\n\tdbrevebelow\t\t= u(0x035C),\n\tdinvbreve\t\t= u(0x0361),\n\tkamora          = u(0x0484),\n\tdasiapneumata   = u(0x0485),\n\tpsilipneumata   = u(0x0486),\n\tkashida\t\t\t= u(0x0640),\n\tfathatan\t\t= u(0x064B),\n\tdammatan\t\t= u(0x064C),\n\tkasratan\t\t= u(0x064D),\n\tfatha\t\t\t= u(0x064E),\n\tdamma\t\t\t= u(0x064F),\n\tkasra\t\t\t= u(0x0650),\n\tshadda\t\t\t= u(0x0651),\n\tsukun\t\t\t= u(0x0652),\n\thamzaabove\t\t= u(0x0654),\n\tnunghunna\t\t= u(0x0658),\n\tsmallv\t\t\t= u(0x065A),\n\tsuperalef\t\t= u(0x0670),\n\tpsili\t\t\t= u(0x1FBD),\n\tcoronis\t\t\t= u(0x1FBF),\n\tZWNJ\t\t\t= u(0x200C), -- zero width non-joiner\n\tZWJ\t\t\t\t= u(0x200D), -- zero width joiner\n\tRSQuo\t\t\t= u(0x2019), -- right single quote\n\tVS01\t\t\t= u(0xFE00), -- variation selector 1\n\t-- Punctuation to be used for standardChars field.\n\tpunc\t\t\t= \" !#%%&'%(%)%*%+,%-%./:;<=>%?@%[\\\\%]^_`{|}~∅\"\n}\n\nlocal m = {}\n\nm[\"aa\"] = {\n\tcanonicalName = \"Afarice\",\n\totherNames = {\"Afarica\", \"Afaricae\", \"Afarici\", \"Afaricum\", \"Afarica\", \"Afaricae\", \"Qafaraf\",  \n\t\t\"Afaricus\", \"Afarica\", \"Afaricarum\", \"Qafar\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cus\",\n}\n\nm[\"ab\"] = {\n\tcanonicalName = \"Abasce\",\n\totherNames = {\"Abasca\", \"Abascae\", \"Abasci\", \"Abascum\", \"Abasca\", \"Abascae\", \"аҧсшәа\", \n\t\t\"Abascus\", \"Abasca\", \"Abascarum\", \"Abkhazian\", \"Abxazo\"},\n\tscripts = {\"Cyrl\", \"Geor\", \"Latn\"},\n\tfamily = \"cau-abz\",\n\ttranslit_module = \"ab-translit\",\n\tentry_name = {\n\t\tfrom = {GRAVE, ACUTE},\n\t\tto   = {}} ,\n}\n\nm[\"ae\"] = {\n\tcanonicalName = \"Avestane\",\n\totherNames = {\"Avestana\", \"Avestanae\", \"Avestani\", \"Avestanum\", \"Avestana\", \"Avestanae\", \"zend\", \n\t\t\"Avestanus\", \"Avestana\", \"Avestanarum\", \"Old Bactrian\"},\n\tscripts = {\"Avst\", \"Gujr\"},\n\tfamily = \"ira-eas\",\n\ttranslit_module = \"Avst-translit\",\n}\n\nm[\"af\"] = {\n\tcanonicalName = \"Africanice\",\n\totherNames = {\"Africanica\", \"Africanicae\", \"Africanici\", \"Africanicum\", \"Africanica\", \"Africanicae\", \"Afrikaans\", \n\t\t\"Africanicus\", \"Africanica\", \"Africanicarum\"},\n\tscripts = {\"Latn\", \"Arab\"},\n\tfamily = \"gmw\",\n\tancestors = {\"nl\"},\n\tsort_key = {\n\t\tfrom = {\"[äáâà]\", \"[ëéêè]\", \"[ïíîì]\", \"[öóôò]\", \"[üúûù]\", \"[ÿýŷỳ]\", \"^-\", \"'\"},\n\t\tto   = {\"a\"\t , \"e\"\t, \"i\"\t, \"o\"\t, \"u\"  , \"y\" }} ,\n}\n\nm[\"ak\"] = {\n\tcanonicalName = \"Akan\",\n\totherNames = {\"Twi-Fante\", \"Twi\", \"Fante\", \"Fanti\", \"Asante\", \"Akuapem\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"alv-kwa\",\n}\n\nm[\"am\"] = {\n\tcanonicalName = \"Aethiopice\",\n\totherNames = {\"Aethiopica\", \"Aethiopicae\", \"Aethiopici\", \"Aethiopicum\", \"Aethiopica\", \"Aethiopicae\", \"አማርኛ\", \n\t\t\"Aethiopicus\", \"Aethiopica\", \"Aethiopicarum\", \"Amharica\"},\n\tscripts = {\"Ethi\"},\n\tfamily = \"sem-eth\",\n\ttranslit_module = \"Ethi-translit\",\n}\n\nm[\"an\"] = {\n\tcanonicalName = \"Aragonice\",\n\totherNames = {\"Aragonica\", \"Aragonicae\", \"Aragonici\", \"Aragonicum\", \"Aragonica\", \"Aragonicae\", \"aragonés\", \n\t\t\"Aragonicus\", \"Aragonica\", \"Aragonicarum\", \"Aragonensis\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"roa-oan\"},\n}\n\nm[\"ar\"] = {\n\tcanonicalName = \"Arabice\",\n\totherNames = {\"Arabica\", \"Arabicae\", \"Arabici\", \"Arabicum\", \"Arabica\", \"Arabicae\", \"العربية\", \n\t\t\"Arabicus\", \"Arabica\", \"Arabicarum\", \"Modern Standard Arabic\", \"Standard Arabic\", \"Literary Arabic\", \"Classical Arabic\"},\n\tscripts = {\"Arab\"},\n\tfamily = \"sem-arb\",\n\tentry_name = {\n\t\tfrom = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},\n\t\tto   = {u(0x0627)}},\n\ttranslit_module = \"ar-translit\",\n}\n\nm[\"as\"] = {\n\tcanonicalName = \"Assamice\",\n\totherNames = {\"Assamica\", \"Assamicae\", \"Assamici\", \"Assamicum\", \"Assamica\", \"Assamicae\", \"অসমীয়া\", \n\t\t\"Assamicus\", \"Assamica\", \"Assamicarum\", \"Asamiya\"},\n\tscripts = {\"Beng\"},\n\tfamily = \"inc\",\n\tancestors = {\"pka\"},\n}\n\nm[\"av\"] = {\n\tcanonicalName = \"Avar\",\n\totherNames = {\"Avaric\"},\n\tscripts = {\"Cyrl\"},\n\tfamily = \"cau-nec\",\n\tancestors = {\"oav\"},\n\ttranslit_module = \"av-translit\",\n}\n\nm[\"ay\"] = {\n\tcanonicalName = \"Aymare\",\n\totherNames = {\"Southern Aymara\", \"Central Aymara\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"sai-aym\",\n}\n\nm[\"az\"] = {\n\tcanonicalName = \"Atropatenice\",\n\totherNames = {\"Atropatenica\", \"Atropatenicae\", \"Atropatenici\", \"Atropatenicum\", \"Atropatenica\", \"Atropatenicae\", \"Azərbaycan dili\",\n\t\t\"Atropatenicus\", \"Atropatenica\", \"Atropatenicarum\",  \"Azerbaijani\", \"Azari\", \"Azeri Turkic\", \"Azerbaijani Turkic\", \"North Azerbaijani\", \"South Azerbaijani\"},\n\tscripts = {\"Latn\", \"Cyrl\", \"fa-Arab\"},\n\tfamily = \"trk-ogz\",\n}\n\nm[\"ba\"] = {\n\tcanonicalName = \"Baschkirice\",\n\totherNames = {\"Baschkirica\", \"Baschkiricae\", \"Baschkirici\", \"Baschkiricum\", \"Baschkirica\", \"Baschkiricae\", \"башҡортса\", \n\t\t\"Baschkiricus\", \"Baschkirica\", \"Baschkiricarum\", \"Bashkir\"},\n\tscripts = {\"Cyrl\"},\n\tfamily = \"trk-kip\",\n\ttranslit_module = \"ba-translit\",\n}\n\nm[\"be\"] = {\n\tcanonicalName = \"Albaruthenice\",\n\totherNames = {\"Albaruthenica\", \"Albaruthenicae\", \"Albaruthenici\", \"Albaruthenicum\", \"Albaruthenica\", \"Albaruthenicae\", \"беларуская мова\", \n\t\t\"Albaruthenicus\", \"Albaruthenica\", \"Albaruthenicarum\", \"Belorussian\", \"Belarusan\", \"Bielorussian\", \"Byelorussian\", \"Belarussian\", \"White Russian\"},\n\tscripts = {\"Cyrl\"},\n\tfamily = \"zle\",\n\ttranslit_module = \"be-translit\",\n\tsort_key = {\n\t\tfrom = {\"Ё\", \"ё\"},\n\t\tto   = {\"Е\" , \"е\"}},\n\tentry_name = {\n\t\tfrom = {\"Ѐ\", \"ѐ\", GRAVE, ACUTE},\n\t\tto   = {\"Е\", \"е\"}},\n}\n\nm[\"bg\"] = {\n\tcanonicalName = \"Bulgarice\",\n\totherNames = {\"Bulgarica\", \"Bulgaricae\", \"Bulgarici\", \"Bulgaricum\", \"Bulgarica\", \"Bulgaricae\", \"български език\", \n\t\t\"Bulgaricus\", \"Bulgarica\", \"Bulgaricarum\" },\n\tscripts = {\"Cyrl\"},\n\tfamily = \"zls\",\n\ttranslit_module = \"bg-translit\",\n\tentry_name = {\n\t\tfrom = {\"Ѐ\", \"ѐ\", \"Ѝ\", \"ѝ\", GRAVE, ACUTE},\n\t\tto   = {\"Е\", \"е\", \"И\", \"и\"}},\n}\n\nm[\"bh\"] = {\n\tcanonicalName = \"Bihari\",\n\tscripts = {\"Deva\"},\n\tfamily = \"inc\",\n\tancestors = {\"pka\"},\n}\n\nm[\"bi\"] = {\n\tcanonicalName = \"Bislama\",\n\tscripts = {\"Latn\"},\n\tfamily = \"crp\",\n\tancestors = {\"en\"},\n}\n\nm[\"bm\"] = {\n\tcanonicalName = \"Bambara\",\n\totherNames = {\"Bamanankan\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"dmn\",\n}\n\nm[\"bn\"] = {\n\t\"Bengale\", \"Q9610\", \"inc-eas\",\n\tcanonicalName = \"Bengale\",\n\totherNames = {\"Bengala\", \"Bengalae\", \"Bengali\", \"Bengalum\", \"Bengala\", \"Bengalae\", \"বাংলা\", \n\t\t\"Bengalus\", \"Bengala\", \"Bengalarum\", \"Bangla\", \"Bengali\"},\n\tscripts = {\"Beng\", \"Newa\"},\n\tancestors = {\"inc-mbn\"},\n\ttranslit_module = \"bn-translit\",\n}\n\nm[\"bo\"] = {\n\tcanonicalName = \"Tibetane\",\n\totherNames = {\"Tibetana\", \"Tibetanae\", \"Tibetani\", \"Tibetanum\", \"Tibetana\", \"Tibetanae\", \"བོད་སྐད།\",\n\t\t\"Tibetanus\", \"Tibetana\", \"Tibetanarum\"}, \n\tscripts = {\"Tibt\"},\n\tfamily = \"tbq\",\n\tancestors = {\"xct\"},\n\ttranslit_module = \"bo-translit\",\n}\n\nm[\"br\"] = {\n\tcanonicalName = \"Britonice\",\n\totherNames = {\"Britonica\", \"Britonicae\", \"Britonici\", \"Britonicum\", \"Britonica\", \"Britonicae\", \"brezhoneg\", \n\t\t\"Britonicus\", \"Britonica\", \"Britonicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-bry\",\n\tancestors = {\"xbm\"},\n}\n\nm[\"bs\"] = {\n\tcanonicalName = \"Bosnice\",\n\totherNames = {\"Bosnica\", \"Bosnicae\", \"Bosnici\", \"Bosnicum\", \"Bosnica\", \"Bosnicae\", \"Bosnian\", \"bosanski jezik\",\n\t\t\"Bosnicus\", \"Bosnica\", \"Bosnicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zlw\",\n}\n\nm[\"ca\"] = {\n\tcanonicalName = \"Catalane\",\n\totherNames = {\"Catalana\", \"Catalanae\", \"Catalani\", \"Catalanum\", \"Catalana\", \"Catalanae\", \"català\", \n\t\t\t\"Catalanus\", \"Catalana\", \"Catalanarum\", \"Valencian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"roa-oca\"},\n\tsort_key = {\n\t\tfrom = {\"à\", \"[èé]\", \"[íï]\", \"[òó]\", \"[úü]\", \"ç\", \"l·l\"},\n\t\tto   = {\"a\", \"e\"   , \"i\"   , \"o\"   , \"u\"   , \"c\", \"ll\" }} ,\n}\n\nm[\"ce\"] = {\n\tcanonicalName = \"Chechen\",\n\tscripts = {\"Cyrl\"},\n\tfamily = \"cau-nkh\",\n\ttranslit_module = \"ce-translit\",\n\tentry_name = {\n\t\tfrom = {MACRON},\n\t\tto   = {}},\n}\n\nm[\"ch\"] = {\n\tcanonicalName = \"Chamorre\",\n\totherNames = {\"Chamoru\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-sus\",\n}\n\nm[\"co\"] = {\n\tcanonicalName = \"Corse\",\n\totherNames = {\"Corsa\", \"Corsae\", \"Corsi\", \"Corsum\", \"Corsa\", \"Corsae\", \"corsu\", \n\t\t\"Corsus\", \"Corsa\", \"Corsarum\", \"Corsican\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n}\n\nm[\"cr\"] = {\n\tcanonicalName = \"Cree\",\n\tscripts = {\"Cans\", \"Latn\"},\n\tfamily = \"alg\",\n\ttranslit_module = \"cr-translit\",\n}\n\nm[\"cs\"] = {\n\tcanonicalName = \"Bohemice\",\n\totherNames = {\"Bohemica\", \"Bohemicae\", \"Bohemici\", \"Bohemicum\", \"Bohemica\", \"Bohemicae\", \"čeština\", \n\t\t\"Bohemicus\", \"Bohemica\", \"Bohemicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zlw\",\n\tancestors = {\"zlw-ocs\"},\n\tsort_key = {\n\t\tfrom = {\"á\", \"é\", \"í\", \"ó\", \"[úů]\", \"ý\"},\n\t\tto   = {\"a\", \"e\", \"i\", \"o\", \"u\"   , \"y\"}} ,\n}\n\nm[\"cu\"] = {\n\t\"Slavica Antiqua\", \"Q35499\", \"zls\",\n\totherNames = {\"Slavica Antiqua\", \"Slavicae Antiquae\", \"Slavici Antiqui\", \"Slavicum Antiquum\", \"Slavica Antiqua\", \"Slavicae Antiquae\", \"словѣньскъ ѩзыкъ\",\n\t\t\"Slavicus Antiquus\", \"Slavica Antiqua\", \"Slavicarum Antiquarum\", \"Old Church Slavic\", \"Old Church Slavonic\"},\n\tscripts = {\"Cyrs\", \"Glag\"},\n\ttranslit_module = \"Cyrs-Glag-translit\",\n\tentry_name = {\n\t\tfrom = {u(0x0484)}, -- kamora\n\t\tto   = {}},\n\tsort_key = {\n\t\tfrom = {\"оу\", \"є\"},\n\t\tto   = {\"у\" , \"е\"}} ,\n}\n\nm[\"cv\"] = {\n\tcanonicalName = \"Chuvash\",\n\tscripts = {\"Cyrl\"},\n\tfamily = \"trk-ogr\",\n\ttranslit_module = \"cv-translit\",\n}\n\nm[\"cy\"] = {\n\tcanonicalName = \"Cambrice\",\n\totherNames = {\"Cambrica\", \"Cambricae\", \"Cambrici\", \"Cambricum\", \"Cambrica\", \"Cambricae\", \"Cymraeg\", \n\t\t\"Cambricus\", \"Cambrica\", \"Cambricarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-bry\",\n\tancestors = {\"wlm\"},\n\tsort_key = {\n\t\tfrom = {\"[âáàä]\", \"[êéèë]\", \"[îíìï]\", \"[ôóòö]\", \"[ûúùü]\", \"[ŵẃẁẅ]\", \"[ŷýỳÿ]\", \"'\"},\n\t\tto   = {\"a\"\t , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t , \"w\"\t , \"y\"\t }} ,\n}\n\nm[\"da\"] = {\n\tcanonicalName = \"Danice\",\n\totherNames = {\"Danica\", \"Danicae\", \"Danici\", \"Danicum\", \"Danica\", \"Danicae\", \"dansk\", \n\t\t\"Danicus\", \"Danica\", \"Danicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"gmq-oda\"},\n}\n\nm[\"de\"] = {\n\t\"Germanice\", \"Q188\", \"gmw\",\n\totherNames = {\"Germanica\", \"Germanicae\", \"Germanici\", \"Germanicum\", \"Germanica\", \"Germanicae\", \"Deutsch\", \n\t\t\"Germanicus\", \"Germanica\", \"Germanicarum\", \"High German\", \"New High German\", \"Deutsch\"}, -- the last name is indeed also used in English\n\tscripts = {\"Latn\", \"Latf\"},\n\tancestors = {\"gmh\"},\n\tsort_key = {\n\t\tfrom = {\"[äàáâå]\", \"[ëèéê]\", \"[ïìíî]\", \"[öòóô]\", \"[üùúû]\", \"ß\" },\n\t\tto   = {\"a\"\t  , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t , \"ss\"}} ,\n}\n\nm[\"dv\"] = {\n\tcanonicalName = \"Dhivehi\",\n\totherNames = {\"Divehi\", \"Mahal\", \"Mahl\", \"Maldivian\"},\n\tscripts = {\"Thaa\"},\n\tfamily = \"inc\",\n\tancestors = {\"pmh\"},\n\ttranslit_module = \"dv-translit\",\n}\n\nm[\"dz\"] = {\n\tcanonicalName = \"Dzongkha\",\n\tscripts = {\"Tibt\"},\n\tfamily = \"tbq\",\n\tancestors = {\"xct\"},\n\ttranslit_module = \"bo-translit\",\n}\n\nm[\"ee\"] = {\n\tcanonicalName = \"Ewe\",\n\tscripts = {\"Latn\"},\n\tfamily = \"alv\",\n}\n\nm[\"el\"] = {\n\tcanonicalName = \"Neograece\",\n\totherNames = {\"Neograeca\", \"Neograecae\", \"Neograeci\", \"Neograecum\", \"Neograeca\", \"Neograecae\", \"Νέα Ελληνικά\", \n\t\t\"Neograecus\", \"Neograeca\", \"Neograecarum\", \"Modern Greek\", \"Neo-Hellenic\"},\n\tscripts = {\"Grek\"},\n\tfamily = \"grk\",\n\tancestors = {\"grc\"},\n\ttranslit_module = \"el-translit\",\n\tsort_key = {  -- Keep this synchronized with grc, cpg, pnt\n\t\tfrom = {\"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]\", \"[έὲἐἔἒἑἕἓ]\", \"[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]\", \"[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]\", \"[όὸὀὄὂὁὅὃ]\", \"[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]\", \"[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]\", \"ῥ\", \"ς\"},\n\t\tto   = {\"α\"\t\t\t\t\t\t, \"ε\"\t\t , \"η\"\t\t\t\t\t\t, \"ι\"\t\t\t\t, \"ο\"\t\t , \"υ\"\t\t\t\t, \"ω\"\t\t\t\t\t\t, \"ρ\", \"σ\"}} ,\n}\n\nm[\"en\"] = {\n\tcanonicalName = \"Anglice\",\n\totherNames = {\"Anglica\", \"Anglicae\", \"Anglici\", \"Anglicum\", \"Anglica\", \"Anglicae\", \"English\", \n\t\t\"Anglicus\", \"Anglica\", \"Anglicarum\", \"Modern English\", \"New English\", \"Hawaiian Creole English\", \"Hawai'ian Creole English\", \"Hawaiian Creole\", \"Hawai'ian Creole\", \"Polari\", \"Yinglish\"}, -- all but the first three are names and alt names of subsumed dialects which once had ISO codes\n\tscripts = {\"Latn\", \"Shaw\", \"Dsrt\"}, -- last two are rare but probably attested; entries in them might require community approval, but it's good for the script codes not to be orphans\n\tfamily = \"gmw\",\n\tancestors = {\"enm\"},\n\tsort_key = {\n\t\tfrom = {\"[äàáâåā]\", \"[ëèéêē]\", \"[ïìíîī]\", \"[öòóôō]\", \"[üùúûū]\", \"æ\" , \"œ\" , \"[çč]\", \"ñ\", \"'\"},\n\t\tto   = {\"a\"       , \"e\"      , \"i\"      , \"o\"      , \"u\"      , \"ae\", \"oe\", \"c\"   , \"n\"}},\n\twikimedia_codes = {\"en\", \"simple\"},\n\tstandardChars = \"A-Za-z0-9\" .. c.punc .. u(0x2800) .. \"-\" .. u(0x28FF)\n}\n\nm[\"eo\"] = {\n\tcanonicalName = \"Esperantice\",\n\totherNames = {\"Esperantica\", \"Esperanticae\", \"Esperantici\", \"Esperanticum\", \"Esperantica\", \"Esperanticae\", \"Esperanto\", \n\t\t\"Esperanticus\", \"Esperantica\", \"Esperanticarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"art\",\n\tsort_key = {\n\t\tfrom = {\"[áà]\", \"[éè]\", \"[íì]\", \"[óò]\", \"[úù]\", \"[ĉ]\", \"[ĝ]\", \"[ĥ]\", \"[ĵ]\", \"[ŝ]\", \"[ŭ]\"},\n\t\tto   = {\"a\"\t   , \"e\"  , \"i\"  , \"o\"  , \"u\", \"cĉ\", \"gĉ\", \"hĉ\", \"jĉ\", \"sĉ\", \"uĉ\"}} ,\n}\n\nm[\"es\"] = {\n\tcanonicalName = \"Hispanice\",\n\totherNames = {\"Hispanica\", \"Hispanicae\", \"Hispanici\", \"Hispanicum\", \"Hispanica\", \"Hispanicae\", \"español\", \n\t\t\"Hispanicus\", \"Hispanica\", \"Hispanicarum\", \"Castilian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"osp\"},\n\tsort_key = {\n\t\tfrom = {\"á\", \"é\", \"í\", \"ó\", \"[úü]\", \"ç\", \"ñ\"},\n\t\tto   = {\"a\", \"e\", \"i\", \"o\", \"u\"   , \"c\", \"n\"}},\n\tstandardChars = \"A-VXYZa-vxyz0-9ÁáÉéÍíÓóÚúÑñ¿¡\" .. c.punc,\n}\n\nm[\"et\"] = {\n\tcanonicalName = \"Estonice\",\n\totherNames = {\"Estonica\", \"Estonicae\", \"Estonici\", \"Estonicum\", \"Estonica\", \"Estonicae\", \"eesti keel\", \n\t\t\"Estonicus\", \"Estonica\", \"Estonicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"fiu-fin\",\n}\n\nm[\"eu\"] = {\n\tcanonicalName = \"Vasconice\",\n\totherNames = {\"Vasconica\", \"Vasconicae\", \"Vasconici\", \"Vasconicum\", \"Vasconica\", \"Vasconicae\", \"Euskara\", \n\t\t\"Vasconicus\", \"Vasconica\", \"Vasconicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"euq\",\n}\n\nm[\"fa\"] = {\n\tcanonicalName = \"Persice\",\n\totherNames = {\"Persica\", \"Persicae\", \"Persici\", \"Persicum\", \"Persica\", \"Persicae\", \"فارسی\", \n\t\t\"Persicus\", \"Persica\", \"Persicarum\", \"Farsi\", \"New Persian\", \"Modern Persian\", \"Western Persian\", \"Iranian Persian\", \"Eastern Persian\", \"Dari\", \"Aimaq\", \"Aimak\", \"Aymaq\", \"Eimak\"},\n\tscripts = {\"fa-Arab\"},\n\tfamily = \"ira-wes\",\n\tancestors = {\"pal\"},\n\ttranslit_module = \"fa-translit\",\n\tentry_name = {\n\t\tfrom = {u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652)},\n\t\tto   = {}} ,\n}\n\nm[\"ff\"] = {\n\tcanonicalName = \"Fula\",\n\totherNames = {\"Adamawa Fulfulde\", \"Bagirmi Fulfulde\", \"Borgu Fulfulde\", \"Central-Eastern Niger Fulfulde\", \"Fulani\", \"Fulfulde\", \"Maasina Fulfulde\", \"Nigerian Fulfulde\", \"Pular\", \"Pulaar\", \"Western Niger Fulfulde\"}, -- Maasina, etc are dialects, subsumed into this code\n\tscripts = {\"Latn\"},\n\tfamily = \"alv-sng\",\n}\n\nm[\"fi\"] = {\n\tcanonicalName = \"Finnice\",\n\totherNames = {\"Finnica\", \"Finnicae\", \"Finnici\", \"Finnicum\", \"Finnica\", \"Finnicae\", \"suomi\", \n\t\t\"Finnicus\", \"Finnica\", \"Finnicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"fiu-fin\",\n\tentry_name = {\n\t\tfrom = {\"ˣ\"},  -- Used to indicate gemination of the next consonant\n\t\tto   = {}},\n\tsort_key = {\n\t\tfrom = {\"[áàâã]\", \"[éèêẽ]\", \"[íìîĩ]\", \"[óòôõ]\", \"[úùûũ]\", \"[ýỳŷüű]\", \"[øõő]\", \"æ\" , \"œ\" , \"[čç]\", \"š\", \"ž\", \"ß\" , \"[':]\"},\n\t\tto   = {\"a\"\t , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t ,  \"y\"\t , \"ö\"\t, \"ae\", \"oe\", \"c\"   , \"s\", \"z\", \"ss\"}} ,\n}\n\nm[\"fj\"] = {\n\tcanonicalName = \"Fidziane\",\n\totherNames = {\"Fidziana\", \"Fidzianae\", \"Fidziani\", \"Fidzianum\", \"Fidziana\", \"Fidzianae\", \"?\", \n\t\t\"Fidzianus\", \"Fidziana\", \"Fidzianarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-occ\",\n}\n\nm[\"fo\"] = {\n\tcanonicalName = \"Faeroice\",\n\totherNames = {\"Faeroica\", \"Faeroicae\", \"Faeroici\", \"Faeroicum\", \"Faeroica\", \"Faeroicae\", \"føroyskt\", \n\t\t\"Faeroicus\", \"Faeroica\", \"Faeroicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"non\"},\n}\n\nm[\"fr\"] = {\n\tcanonicalName = \"Francogallice\",\n\totherNames = {\"Francogallica\", \"Francogallicae\", \"Francogallici\", \"Francogallicum\", \"Francogallica\", \"Francogallicae\", \"français\", \n\t\t\"Francogallicus\", \"Francogallica\", \"Francogallicarum\", \"Modern French\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"frm\"},\n\tsort_key = {\n\t\tfrom = {\"[áàâä]\", \"[éèêë]\", \"[íìîï]\", \"[óòôö]\", \"[úùûü]\", \"[ýỳŷÿ]\", \"ç\", \"æ\" , \"œ\" , \"'\"},\n\t\tto   = {\"a\"\t , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t , \"y\"\t , \"c\", \"ae\", \"oe\"}},\n\tstandardChars = \"A-Za-z0-9ÀÂÇÉÈÊËÎÏÔŒÛÙÜàâçéèêëîïôœûùü\" .. c.punc,\n}\n\nm[\"fy\"] = {\n\tcanonicalName = \"Frisice\",\n\totherNames = {\"Frisica\", \"Frisicae\", \"Frisici\", \"Frisicum\", \"Frisica\", \"Frisicae\", \"?\", \n\t\t\"Frisicus\", \"Frisica\", \"Frisicarum\", \"Western Frisian\", \"Frisian\", \"Frysk\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmw-fri\",\n\tancestors = {\"ofs\"},\n}\n\nm[\"ga\"] = {\n\tcanonicalName = \"Hibernice\",\n\totherNames = {\"Hibernica\", \"Hibernicae\", \"Hibernici\", \"Hibernicum\", \"Hibernica\", \"Hibernicae\", \"Gaeilge\", \n\t\t\"Hibernicus\", \"Hibernica\", \"Hibernicarum\", \"Irish Gaelic\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-gae\",\n\tancestors = {\"mga\"},\n\tsort_key = {\n\t\tfrom = {\"á\", \"é\", \"í\", \"ó\", \"ú\", \"ý\", \"ḃ\" , \"ċ\" , \"ḋ\" , \"ḟ\" , \"ġ\" , \"ṁ\" , \"ṗ\" , \"ṡ\" , \"ṫ\" },\n\t\tto   = {\"a\", \"e\", \"i\", \"o\", \"u\", \"y\", \"bh\", \"ch\", \"dh\", \"fh\", \"gh\", \"mh\", \"ph\", \"sh\", \"th\"}} ,\n}\n\nm[\"gd\"] = {\n\tcanonicalName = \"Gaelice\",\n\totherNames = {\"Gaelica\", \"Gaelicae\", \"Gaelici\", \"Gaelicum\", \"Gaelica\", \"Gaelicae\", \"Gàidhlig\", \n\t\t\"Gaelicus\", \"Gaelica\", \"Gaelicarum\", \"Highland Gaelic\", \"Scots Gaelic\", \"Scottish\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-gae\",\n\tancestors = {\"mga\"},\n\tsort_key = {\n\t\tfrom = {\"[áà]\", \"[éè]\", \"[íì]\", \"[óò]\", \"[úù]\", \"[ýỳ]\"},\n\t\tto   = {\"a\"   , \"e\"   , \"i\"   , \"o\"   , \"u\"   , \"y\"   }} ,\n}\n\nm[\"gl\"] = {\n\tcanonicalName = \"Gallaice\",\n\totherNames = {\"Gallaica\", \"Gallaicae\", \"Gallaici\", \"Gallaicum\", \"Gallaica\", \"Gallaicae\", \"galego\", \n\t\t\"Gallaicus\", \"Gallaica\", \"Gallaicarum\", \"Galician\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"roa-opt\"},\n\tsort_key = {\n\t\tfrom = {\"á\", \"é\", \"í\", \"ó\", \"ú\"},\n\t\tto   = {\"a\", \"e\", \"i\", \"o\", \"u\"}} ,\n}\n\nm[\"gn\"] = {\n\tcanonicalName = \"Guaraní\",\n\tscripts = {\"Latn\"},\n\tfamily = \"tup\",\n}\n\nm[\"gu\"] = {\n\tcanonicalName = \"Gujarati\",\n\tscripts = {\"Gujr\"},\n\tfamily = \"inc\",\n\tancestors = {\"inc-ogu\"},\n\ttranslit_module = \"gu-translit\",\n}\n\nm[\"gv\"] = {\n\tcanonicalName = \"Manx\",\n\totherNames = {\"Manx Gaelic\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-gae\",\n\tancestors = {\"mga\"},\n\tsort_key = {\n\t\tfrom = {\"ç\", \"-\"},\n\t\tto   = {\"c\"}} ,\n}\n\nm[\"ha\"] = {\n\tcanonicalName = \"Hausa\",\n\tscripts = {\"Latn\", \"Arab\"},\n\tfamily = \"cdc-wst\",\n}\n\nm[\"he\"] = {\n\tcanonicalName = \"Hebraice\",\n\totherNames = {\"Hebraica\", \"Hebraicae\", \"Hebraici\", \"Hebraicum\", \"Hebraica\", \"Hebraicae\", \"עִבְרִית\", \n\t\t\"Hebraicus\", \"Hebraica\", \"Hebraicarum\", \"Ivrit\"},\n\tscripts = {\"Hebr\", \"Phnx\"},\n\tfamily = \"sem-can\",\n\tentry_name = {\n\t\tfrom = {\"[\" .. u(0x0591) .. \"-\" .. u(0x05BD) .. u(0x05BF) .. \"-\" .. u(0x05C5) .. u(0x05C7) .. \"]\"},\n\t\tto   = {}} ,\n}\n\nm[\"hi\"] = {\n\tcanonicalName = \"Hindice\",\n\totherNames = {\"Hindica\", \"Hindicae\", \"Hindici\", \"Hindicum\", \"Hindica\", \"Hindicae\", \"हिन्दी\", \n\t\t\"Hindicus\", \"Hindica\", \"Hindicarum\", \"hindī\"},\n\tscripts = {\"Deva\"},\n\tfamily = \"inc\",\n\tancestors = {\"inc-ohi\"},\n\ttranslit_module = \"hi-translit\",\n}\n\nm[\"ho\"] = {\n\tcanonicalName = \"Hiri Motu\",\n\totherNames = {\"Pidgin Motu\", \"Police Motu\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"crp\",\n\tancestors = {\"meu\"},\n}\n\nm[\"hr\"] = {\n\tcanonicalName = \"Croate\",\n\totherNames = {\"Croata\", \"Croatae\", \"Croati\", \"Croatum\", \"Croata\", \"Croatae\", \"hrvatski\", \n\t\t\"Croatus\", \"Croata\", \"Croatarum\", \"Croatian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zlw\",\n}\n\nm[\"ht\"] = {\n\tcanonicalName = \"Haitiane\",\n\totherNames = {\"Haitiana\", \"Haitianae\", \"Haitiani\", \"Haitianum\", \"Haitiana\", \"Haitianae\", \"kreyòl\", \n\t\t\"Haitianus\", \"Haitiana\", \"Haitianarum\", \"Creole\", \"Haitian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"crp\",\n}\n\nm[\"hu\"] = {\n\tcanonicalName = \"Hungarice\",\n\totherNames = {\"Hungarica\", \"Hungaricae\", \"Hungarici\", \"Hungaricum\", \"Hungarica\", \"Hungaricae\", \"magyar\", \n\t\t\"Hungaricus\", \"Hungarica\", \"Hungaricarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"fiu-ugr\",\n\tancestors = {\"ohu\"},\n\tsort_key = {\n\t\tfrom = {\"á\", \"é\", \"í\", \"ó\", \"ú\", \"ő\", \"ű\"},\n\t\tto   = {\"a\", \"e\", \"i\", \"o\", \"u\", \"ö\", \"ü\"}} ,\n}\n\nm[\"hy\"] = {\n\tcanonicalName = \"Armenie\",\n\totherNames = {\"Armenia\", \"Armeniae\", \"Armenii\", \"Armenium\", \"Armenia\", \"Armeniae\", \"Հայերէն\", \n\t\t\"Armenius\", \"Armenia\", \"Armeniarum\", \"Modern Armenian\", \"Eastern Armenian\", \"Western Armenian\"},\n\tscripts = {\"Armn\"},\n\tfamily = \"hyx\",\n\tancestors = {\"axm\"},\n\ttranslit_module = \"Armn-translit\",\n\tsort_key = {\n\t\tfrom = {\"ու\", \"և\", \"եւ\"},\n\t\tto   = {\"ւ\", \"եվ\", \"եվ\"}},\n\tentry_name = {\n\t\tfrom = {\"՞\", \"՜\", \"՛\", \"՟\", \"և\", \"<sup>յ</sup>\", \"<sup>ի</sup>\"},\n\t\tto   = {\"\", \"\", \"\", \"\", \"եւ\", \"յ\", \"ի\"}} ,\n}\n\nm[\"hz\"] = {\n\tcanonicalName = \"Herero\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\n-- 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf, 7=ipsa, 8=nomsgm, 9=ablsgf, 10=genplf\nm[\"ia\"] = {\n\t\"Interlingua\", 35934, \"art\",\n\totherNames = {\"Interlingua\", \"Interlinguae\", \"Interlinguae\", \"Interlinguae\", \"Interlinguae\", \"Interlinguae\", \"Interlingua\",\n\t\t\"Interlinguae\", \"Interlingua\", \"Interlinguae\"},\n\tscripts = {\"Latn\"},\n}\n\nm[\"id\"] = {\n\tcanonicalName = \"Indonesie\",\n\totherNames = {\"Indonesia\", \"Indonesiae\", \"Indonesii\", \"Indonesium\", \"Indonesia\", \"Indonesiae\", \"Bahasa Indonesia\", \n\t\t\"Indonesius\", \"Indonesia\", \"Indonesiarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-mly\",\n\tancestors = {\"ms\"},\n}\n\nm[\"ie\"] = {\n\tcanonicalName = \"Interlingue\",\n\totherNames = {\"Occidental\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"art\",\n}\n\nm[\"ig\"] = {\n\tcanonicalName = \"Igbo\",\n\tscripts = {\"Latn\"},\n\tfamily = \"nic-bco\",\n}\n\nm[\"ii\"] = {\n\tcanonicalName = \"Sichuan Yi\",\n\totherNames = {\"Nuosu\", \"Nosu\", \"Northern Yi\", \"Liangshan Yi\"},\n\tscripts = {\"Yiii\"},\n\tfamily = \"tbq-lol\",\n}\n\nm[\"ik\"] = {\n\tcanonicalName = \"Inupiak\",\n\totherNames = {\"Inupiaq\", \"Iñupiaq\", \"Inupiatun\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"esx-inu\",\n}\n\nm[\"io\"] = {\n\tcanonicalName = \"Ido\",\n\tscripts = {\"Latn\"},\n\tfamily = \"art\",\n}\n\nm[\"is\"] = {\n\tcanonicalName = \"Islandice\",\n\totherNames = {\"Islandica\", \"Islandicae\", \"Islandici\", \"Islandicum\", \"Islandica\", \"Islandicae\", \"íslenska\", \n\t\t\"Islandica\", \"Islandica\", \"Islandicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"non\"},\n}\n\nm[\"it\"] = {\n\tcanonicalName = \"Italice\",\n\totherNames = {\"Italica\", \"Italicae\", \"Italici\", \"Italicum\", \"Italica\", \"Italicae\", \"italiano\", \n\t\t\"Italicus\", \"Italica\", \"Italicarum\", \"Italiana\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"roa-oit\"},\n\tsort_key = {\n\t\tfrom = {\"[àáâäå]\", \"[èéêë]\", \"[ìíîï]\", \"[òóôö]\", \"[ùúûü]\"},\n\t\tto   = {\"a\"\t  , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t }} ,\n}\n\nm[\"iu\"] = {\n\tcanonicalName = \"Inuktitut\",\n\totherNames = {\"Eastern Canadian Inuktitut\", \"Eastern Canadian Inuit\", \"Western Canadian Inuktitut\", \"Western Canadian Inuit\", \"Western Canadian Inuktun\", \"Inuinnaq\", \"Inuinnaqtun\", \"Inuvialuk\", \"Inuvialuktun\", \"Nunavimmiutit\", \"Nunatsiavummiut\", \"Aivilimmiut\", \"Natsilingmiut\", \"Kivallirmiut\", \"Siglit\", \"Siglitun\"},\n\tscripts = {\"Cans\", \"Latn\"},\n\tfamily = \"esx-inu\",\n\ttranslit_module = \"iu-translit\",\n}\n\nm[\"ja\"] = {\n\tcanonicalName = \"Iaponice\",\n\totherNames = {\"Iaponica\", \"Iaponicae\", \"Iaponici\", \"Iaponicum\", \"Iaponica\", \"Iaponicae\", \"日本語\", \n\t\"Iaponicus\", \"Iaponica\", \"Iaponicarum\", \"Nihongo\", \"Modern Japanese\", \"Nipponese\"},\n\tscripts = {\"Jpan\", \"Latn\", \"Hira\"},\n\tfamily = \"jpx\",\n\tancestors = {\"ojp\"},\n}\n\nm[\"jv\"] = {\n\tcanonicalName = \"Iavense\",\n\totherNames = {\"Iavensis\", \"Iavenses\", \"Iavenses\", \"Iavense\", \"Iavensia\", \"Iavensis\", \"basa Jawa\", \n\t\t\"Iavensis\", \"Iavensi\", \"Iavensium\"},\n\tscripts = {\"Latn\", \"Java\"},\n\tfamily = \"poz-sus\",\n\ttranslit_module = \"jv-translit\",\n\tancestors = {\"kaw\"},\n\tlink_tr = true,\n}\n\nm[\"ka\"] = {\n\tcanonicalName = \"Georgiane\",\n\totherNames = {\"Georgiana\", \"Georgianae\", \"Georgiani\", \"Georgianum\", \"Georgiana\", \"Georgianae\", \"ქართული\", \n\t\t\"Georgianus\", \"Georgiana\", \"Georgianarum\", \"Kartvelian\"},\n\tscripts = {\"Geor\", \"Geok\"},\n\tfamily = \"ccs-gzn\",\n\tancestors = {\"oge\"},\n\ttranslit_module = \"Geor-translit\",\n\tentry_name = {\n\t\tfrom = {\"̂\"},\n\t\tto   = {\"\"}},\n}\n\nm[\"kg\"] = {\n\tcanonicalName = \"Kongo\",\n\totherNames = {\"Kikongo\", \"Koongo\", \"Laari\", \"San Salvador Kongo\", \"Yombe\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"ki\"] = {\n\tcanonicalName = \"Kikuyu\",\n\totherNames = {\"Gikuyu\", \"Gĩkũyũ\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"kj\"] = {\n\tcanonicalName = \"Kwanyama\",\n\totherNames = {\"Kuanyama\", \"Oshikwanyama\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"kk\"] =\n\t{\n\t\"Kazachice\", \"Q9252\", \"trk-kno\",\n\totherNames = {\"Kazachica\", \"Kazachicae\", \"Kazachici\", \"Kazachicum\", \"Kazachica\", \"Kazachicae\", \"Қазақ тілі\", \n\t\t\"Kazachicus\", \"Kazachica\", \"Kazachicarum\"},\n\tscripts = {\"Cyrl\", \"Latn\", \"kk-Arab\"},\n\ttranslit_module = \"kk-translit\",\n\toverride_translit = true,\n\t}\n\nm[\"kl\"] = {\n\tcanonicalName = \"Groenlandice\",\n\totherNames = {\"Groenlandica\", \"Groenlandicae\", \"Groenlandici\", \"Groenlandicum\", \"Groenlandica\", \"Groenlandicae\", \"Kalaallisut\", \n\t\t\"Groenlandicus\", \"Groenlandica\", \"Groenlandicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"esx-inu\",\n}\n\nm[\"km\"] = {\n\tcanonicalName = \"Khmer\",\n\totherNames = {\"Cambodian\"},\n\tscripts = {\"Khmr\"},\n\tfamily = \"mkh\",\n\tancestors = {\"mkh-mkm\"},\n\ttranslit_module = \"km-translit\",\n}\n\nm[\"kn\"] = {\n\tcanonicalName = \"Kannada\",\n\tscripts = {\"Knda\"},\n\tfamily = \"dra\",\n\ttranslit_module = \"kn-translit\",\n}\n\nm[\"ko\"] = {\n\tcanonicalName = \"Coreane\",\n\totherNames = {\"Coreana\", \"Coreanae\", \"Coreani\", \"Coreanum\", \"Coreana\", \"Coreanae\", \"한국어\", \n\t\t\"Coreanus\", \"Coreana\", \"Coreanarum\", \"Modern Korean\"},\n\tscripts = {\"Kore\"},\n\tfamily = \"qfa-kor\",\n\tancestors = {\"okm\"},\n\ttranslit_module = \"ko-translit\",\n}\n\nm[\"kr\"] = {\n\tcanonicalName = \"Kanuri\",\n\totherNames = {\"Kanembu\", \"Bilma Kanuri\", \"Central Kanuri\", \"Manga Kanuri\", \"Tumari Kanuri\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"ssa\",\n}\n\nm[\"ks\"] = {\n\tcanonicalName = \"Caspirice\",\n\totherNames = {\"Caspirica\", \"Caspiricae\", \"Caspirici\", \"Caspiricum\", \"Caspirica\", \"Caspiricae\", \"कॉशुर / کٲشُر\", \n\t\t\"Caspiricus\", \"Caspirica\", \"Caspiricarum\", \"Kashmiri\"},\n\tscripts = {\"ks-Arab\", \"Deva\"},\n\tfamily = \"inc-dar\",\n}\n\nm[\"ku\"] = {\n\tcanonicalName = \"Corduene\",\n\totherNames = {\"Corduena\", \"Corduenae\", \"Cordueni\", \"Corduenum\", \"Corduena\", \"Corduenae\", \"kurdî\", \n\t\t\"Corduenus\", \"Corduena\", \"Corduenarum\"},\n\tscripts = {\"Latn\", \"ku-Arab\", \"Armn\", \"Cyrl\"},\n\tfamily = \"ira-wes\",\n}\n\nm[\"kv\"] = {\n\t\"Komiense\",\n\t\"Q34114\",\n\t\"urj-prm\",\n\totherNames = {\"Komiensis\", \"Komienses\", \"Komienses\", \"Komiense\", \"Komiensia\", \"Komiensis\", \"Коми кыв\", \n\t\"Komiensis\", \"Komiensi\", \"Komiensium\", \"Komi\", \"Komi-Zyryan\"},\n\tscripts = Cyrl,\n\ttranslit_module = \"kv-translit\",\n\toverride_translit = true,\n}\n\nm[\"kw\"] = {\n\tcanonicalName = \"Cornubice\",\n\totherNames = {\"Cornubica\", \"Cornubicae\", \"Cornubici\", \"Cornubicum\", \"Cornubica\", \"Cornubicae\", \"Kernowek\", \n\t\t\"Cornubicus\", \"Cornubica\", \"Cornubicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"cel-bry\",\n\tancestors = {\"cnx\"},\n}\n\nm[\"ky\"] = {\n\tcanonicalName = \"Kyrgesse\",\n\totherNames = {\"Kyrgessa\", \"Kyrgessae\", \"Kyrgessi\", \"Kyrgessum\", \"Kyrgessa\", \"Kyrgessae\", \"кыргызча\", \n\t\t\"Kyrgessus\", \"Kyrgessa\", \"Kyrgessarum\", \"Chirgisica\", \"Kirghiz\", \"Kirgiz\"},\n\tscripts = {\"Cyrl\", \"Latn\", \"Arab\"},\n\tfamily = \"trk-kip\",\n\ttranslit_module = \"ky-translit\",\n}\n\nm[\"la\"] = {\n\tcanonicalName = \"Latine\",\n\totherNames = {\"Latina\", \"Latinae\", \"Latini\", \"Latinum\", \"Latina\", \"Latinae\", \"Latine\", \n\t\t\"Latinus\", \"Latina\", \"Latinarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"itc\",\n\tancestors = {\"itc-ola\"},\n\tentry_name = {\n\t\tfrom = {\"[ĀĂ]\", \"[āă]\", \"[ĒĔ]\", \"[ēĕë]\", \"[ĪĬÏ]\", \"[īĭï]\", \"[ŌŎ]\", \"[ōŏ]\", \"[ŪŬÜ]\", \"[ūŭü]\", \"Ȳ\", \"ȳ\", MACRON, BREVE, DIAER},\n\t\tto   = {\"A\", \"a\", \"E\", \"e\", \"I\", \"i\", \"O\", \"o\", \"U\", \"u\", \"Y\", \"y\"}},\n}\n\nm[\"lb\"] = {\n\tcanonicalName = \"Luxemburgice\",\n\totherNames = {\"Luxemburgica\", \"Luxemburgicae\", \"Luxemburgici\", \"Luxemburgicum\", \"Luxemburgica\", \"Luxemburgicae\", \"Lëtzebuergesch\", \n\t\t\"Luxemburgicus\", \"Luxemburgica\", \"Luxemburgicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmw\",\n\tancestors = {\"gmh\"},\n}\n\nm[\"lg\"] = {\n\tcanonicalName = \"Luganda\",\n\totherNames = {\"Ganda\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"li\"] = {\n\tcanonicalName = \"Limburgice\",\n\totherNames = {\"Limburgica\", \"Limburgicae\", \"Limburgici\", \"Limburgicum\", \"Limburgica\", \"Limburgicae\", \"Limburgs\", \n\t\t\"Limburgicus\", \"Limburgica\", \"Limburgicarum\", \"Limburgan\", \"Limburgian\", \"Limburgic\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmw\",\n\tancestors = {\"dum\"},\n}\n\nm[\"ln\"] = {\n\tcanonicalName = \"Lingala\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"lo\"] = {\n\tcanonicalName = \"Lao\",\n\totherNames = {\"Laotian\"},\n\tscripts = {\"Laoo\"},\n\tfamily = \"tai-swe\",\n\ttranslit_module = \"lo-translit\",\n}\n\nm[\"lt\"] = {\n\tcanonicalName = \"Lithuanice\",\n\totherNames = {\"Lithuanica\", \"Lithuanicae\", \"Lithuanici\", \"Lithuanicum\", \"Lithuanica\", \"Lithuanicae\", \"lietuvių\", \n\t\t\"Lithuanicus\", \"Lithuanica\", \"Lithuanicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bat\",\n\tancestors = {\"olt\"},\n\tentry_name = {\n\t\tfrom = {\"[áãà]\", \"[ÁÃÀ]\", \"[éẽè]\", \"[ÉẼÈ]\", \"[íĩì]\", \"[ÍĨÌ]\", \"[ýỹ]\", \"[ÝỸ]\", \"ñ\", \"[óõò]\", \"[ÓÕÒ]\", \"[úũù]\", \"[ÚŨÙ]\", ACUTE, GRAVE, TILDE},\n\t\tto   = {\"a\",       \"A\",     \"e\",     \"E\",     \"i\",     \"I\",     \"y\",   \"Y\",   \"n\",   \"o\",    \"O\",     \"u\",      \"U\"}} ,\n}\n\nm[\"lu\"] = {\n\tcanonicalName = \"Luba-Katanga\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"lv\"] = {\n\tcanonicalName = \"Lettice\",\n\totherNames = {\"Lettica\", \"Letticae\", \"Lettici\", \"Letticum\", \"Lettica\", \"Letticae\", \"latviešu\", \n\t\t\"Letticus\", \"Lettica\", \"Letticarum\", \"Lettonica\", \"Lettish\", \"Lett\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bat\",\n}\n\n-- 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf, 7=ipsa, 8=nomsgm, 9=ablsgf, 10=genplf\nm[\"ma\"] = {\n\tcanonicalName = \"Magare\",\n\totherNames = {\"Magara\", \"Magarae\", \"Magari\", \"Magarum\", \"Magara\", \"Magarae\", \"léngua magara\", \n\t\t\"Magarus\", \"Magara\", \"Magararum\", \"Magarian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa-itd\",\n}\n\nm[\"mg\"] = {\n\t\"Madagascariense\", 7930, \"poz-bre\",\n\totherNames = {\"Madagascariensis\", \"Madagascarienses\", \"Madagascarienses\", \"Madagascariense\", \"Madagascariensia\", \"Madagascariensis\", \"malagasy\", \n\t\t\"Madagascariensis\", \"Madagascariensi\", \"Madagascariensium\", \"Betsimisaraka Malagasy\", \"Betsimisaraka\", \"Northern Betsimisaraka Malagasy\", \"Northern Betsimisaraka\", \"Southern Betsimisaraka Malagasy\", \"Southern Betsimisaraka\", \"Bara Malagasy\", \"Bara\", \"Masikoro Malagasy\", \"Masikoro\", \"Antankarana\", \"Antankarana Malagasy\", \"Plateau Malagasy\", \"Sakalava\", \"Tandroy Malagasy\", \"Tandroy\", \"Tanosy\", \"Tanosy Malagasy\", \"Tesaka\", \"Tsimihety\", \"Tsimihety Malagasy\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-bre\",\n}\n\nm[\"mh\"] = {\n\t\"Marsaliense\", 36280, \"poz-mic\",\n\totherNames = {\"Marsaliensis\", \"Marsalienses\", \"Marsalienses\", \"Marsaliense\", \"Marsaliensia\", \"Marsaliensis\", \"Kajin M̧ajeļ\", \n\t\"Marsaliensis\", \"Marsaliensi\", \"Marsaliensium\", \"Kajin Majōl\", \"Marshallese\", \"Ebon\"},\n\tscripts = {\"Latn\"},\n\tsort_key = {\n\t\tfrom = {\"ā\" , \"ļ\" , \"m̧\" , \"ņ\" , \"n̄\"  , \"o̧\" , \"ō\"  , \"ū\" },\n\t\tto   = {\"a~\", \"l~\", \"m~\", \"n~\", \"n~~\", \"o~\", \"o~~\", \"u~\"}} ,\n}\n\nm[\"mi\"] = {\n\t\"Maorice\", 36451, \"poz-pep\",\n\totherNames = {\"Maorica\", \"Maoricae\", \"Maorici\", \"Maoricum\", \"Maorica\", \"Maoricae\", \"Māori\", \n\t\t\"Maoricus\", \"Maorica\", \"Maoricarum\"},\n\tscripts = {\"Latn\"},\n}\n\nm[\"mk\"] = {\n\t\"Macedonice\", 9296, \"zls\",\n\totherNames = {\"Macedonica\", \"Macedonicae\", \"Macedonici\", \"Macedonicum\", \"Macedonica\", \"Macedonicae\", \"Македонски јазик\", \n\t\"Macedonicus\", \"Macedonica\", \"Macedonicarum\" },\n\tscripts = {\"Cyrl\"},\n\ttranslit_module = \"mk-translit\",\n\tentry_name = {\n\t\tfrom = {ACUTE},\n\t\tto   = {}},\n}\n\nm[\"ml\"] = {\n\t\"Malabarice\", 36236, \"dra\",\n\totherNames = {\"Malabarica\", \"Malabaricae\", \"Malabarici\", \"Malabaricum\", \"Malabarica\", \"Malabaricae\", \"മലയാളം\", \n\t\"Malabaricus\", \"Malabarica\", \"Malabaricarum\", \"Malayalam\" },\n\tscripts = {\"Mlym\"},\n\ttranslit_module = \"ml-translit\",\n}\n\nm[\"mn\"] = {\n\tcanonicalName = \"Mogolice\",\n\totherNames = {\"Mogolica\", \"Mogolicae\", \"Mogolici\", \"Mogolicum\", \"Mogolica\", \"Mogolicae\", \"Монгол хэл\", \n\t\t\"Mogolicus\", \"Mogolica\", \"Mogolicarum\", \"Khalkha Mongolian\"},\n\tscripts = {\"Cyrl\", \"Mong\"},\n\tfamily = \"xgn\",\n\tancestors = {\"cmg\"},\n\ttranslit_module = \"mn-translit\",\n}\n\nm[\"mr\"] = {\n\tcanonicalName = \"Marathi\",\n\tscripts = {\"Deva\", \"Modi\"},\n\tfamily = \"inc\",\n\tancestors = {\"omr\"},\n\ttranslit_module = \"hi-translit\",\n}\n\nm[\"ms\"] = {\n\tcanonicalName = \"Malaice\",\n\totherNames = {\"Malaica\", \"Malaicae\", \"Malaici\", \"Malaicum\", \"Malaica\", \"Malaicae\", \"Bahasa Melayu\", \n\t\t\"Malaicus\", \"Malaica\", \"Malaicarum\"},\n\tscripts = {\"Latn\", \"Arab\"},\n\tfamily = \"poz-mly\",\n}\n\nm[\"mt\"] = {\n\tcanonicalName = \"Melitense\",\n\totherNames = {\"Melitensis\", \"Melitenses\", \"Melitenses\", \"Melitense\", \"Melitensia\", \"Melitensis\", \"Malti\", \n\t\"Melitensis\", \"Melitensi\", \"Melitensium\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"sem-arb\",\n\tancestors = {\"sqr\"},\n}\n\nm[\"my\"] = {\n\tcanonicalName = \"Birmanice\",\n\totherNames = {\"Birmanica\", \"Birmanicae\", \"Birmanici\", \"Birmanicum\", \"Birmanica\", \"Birmanicae\", \"မ္ရန္‌မာစာ\", \n\t\t\"Birmanicus\", \"Birmanica\", \"Birmanicarum\", \"Burmese\", \"Myanmar\"},\n\tscripts = {\"Mymr\"},\n\tfamily = \"tbq-brm\",\n\tancestors = {\"obr\"},\n\ttranslit_module = \"my-translit\",\n}\n\nm[\"na\"] = {\n\tcanonicalName = \"Nauruane\",\n\totherNames = {\"Nauruana\", \"Nauruanae\", \"Nauruani\", \"Nauruanum\", \"Nauruana\", \"Nauruanae\", \"Nauru\", \n\t\t\"Nauruanus\", \"Nauruana\", \"Nauruanarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-mic\",\n}\n\nm[\"nb\"] = {\n\tcanonicalName = \"Dano-Norvegice\",\n\totherNames = {\"Dano-Norvegica\", \"Dano-Norvegicae\", \"Dano-Norvegici\", \"Dano-Norvegicum\", \"Dano-Norvegica\", \"Dano-Norvegicae\", \"Bokmål\",\n\t\"Dano-Norvegicus\", \"Dano-Norvegica\", \"Dano-Norvegicarum\", \"Norwegian\", \"Norsk\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"gmq-mno\"},\n\twikimedia_codes = {\"no\"},\n}\n\nm[\"nd\"] = {\n\tcanonicalName = \"Northern Ndebele\",\n\totherNames = {\"North Ndebele\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt-ngu\",\n}\n\nm[\"ne\"] = {\n\tcanonicalName = \"Nepalense\",\n\totherNames = {\"Nepalensis\", \"Nepalenses\", \"Nepalenses\", \"Nepalense\", \"Nepalensia\", \"Nepalensis\", \"नेपाली\", \n\t\t\"Nepalensis\", \"Nepalensi\", \"Nepalensium\", \"Nepalese\"},\n\tscripts = {\"Deva\"},\n\tfamily = \"inc\",\n\ttranslit_module = \"ne-translit\",\n}\n\nm[\"ng\"] = {\n\tcanonicalName = \"Ndonga\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"nl\"] = {\n\tcanonicalName = \"Batave\",\n\totherNames = {\"Batava\", \"Batavae\", \"Batavi\", \"Batavum\", \"Batava\", \"Batavae\", \"Nederlands\", \n\t\t\"Batavus\", \"Batava\", \"Batavarum\", \"Netherlandic\", \"Flemish\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmw\",\n\tancestors = {\"dum\"},\n\tsort_key = {\n\t\tfrom = {\"[äáâå]\", \"[ëéê]\", \"[ïíî]\", \"[öóô]\", \"[üúû]\", \"ç\", \"ñ\", \"^-\"},\n\t\tto   = {\"a\"\t , \"e\"\t, \"i\"\t, \"o\"\t, \"u\"\t, \"c\", \"n\"}} ,\n}\n\nm[\"nn\"] = {\n\tcanonicalName = \"Neonorvegice\",\n\totherNames = {\"Neonorvegica\", \"Neonorvegicae\", \"Neonorvegici\", \"Neonorvegicum\", \"Neonorvegica\", \"Neonorvegicae\", \"Nynorsk\", \n\t\t\"Neonorvegicus\", \"Neonorvegica\", \"Neonorvegicarum\", \"New Norwegian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"gmq-mno\"},\n}\n\nm[\"no\"] = {\n\tcanonicalName = \"Norvegice\",\n\totherNames = {\"Norvegica\", \"Norvegicae\", \"Norvegici\", \"Norvegicum\", \"Norvegica\", \"Norvegicae\", \"Norsk\", \n\t\t\"Norvegicus\", \"Norvegica\", \"Norvegicarum\", \"Norwegian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"gmq-mno\"},\n}\n\nm[\"nr\"] = {\n\tcanonicalName = \"Southern Ndebele\",\n\totherNames = {\"South Ndebele\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt-ngu\",\n}\n\nm[\"nv\"] = {\n\tcanonicalName = \"Navajo\",\n\tscripts = {\"nv-Latn\"},\n\tfamily = \"apa\",\n\tsort_key = {\n\t\tfrom = {\"[áą]\", \"[éę]\", \"[íį]\", \"[óǫ]\", \"ń\", \"^n([djlt])\", \"ł\" , \"[ʼ’']\", ACUTE},\n\t\tto   = {\"a\"   , \"e\"   , \"i\"   , \"o\"   , \"n\", \"ni%1\"\t  , \"l\"}}, -- the copyright sign is used to guarantee that ł will always be sorted after all other words with l\n}\n\nm[\"ny\"] = {\n\tcanonicalName = \"Chichewa\",\n\totherNames = {\"Chicheŵa\", \"Chinyanja\", \"Nyanja\", \"Chewa\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n\tentry_name = {\n\t\tfrom = {ACUTE},\n\t\tto   = {}},\n}\n\nm[\"oc\"] = {\n\tcanonicalName = \"Occitane\",\n\totherNames = {\"Occitana\", \"Occitanae\", \"Occitani\", \"Occitanum\", \"Occitana\", \"Occitanae\", \"occitan\", \n\t\t\"Occitanus\", \"Occitana\", \"Occitanarum\",\n\t\t\"Provençal\", \"Auvergnat\", \"Auvernhat\", \"Gascon\", \"Languedocien\", \"Lengadocian\", \"Shuadit\", \"Chouhadite\", \"Chouhadit\", \"Chouadite\", \"Chouadit\", \"Shuhadit\", \"Judeo-Provençal\", \"Judeo-Provencal\", \"Judeo-Comtadin\"},\n\tscripts = {\"Latn\", \"Hebr\"},\n\tfamily = \"roa\",\n\tancestors = {\"pro\"},\n\tsort_key = {\n\t\tfrom = {\"[àá]\", \"[èé]\", \"[íï]\", \"[òó]\", \"[úü]\", \"ç\", \"([lns])·h\"},\n\t\tto   = {\"a\"   , \"e\"   , \"i\"   , \"o\"   , \"u\"   , \"c\", \"%1h\"\t  }} ,\n}\n\nm[\"oj\"] = {\n\t\"Ojibwayense\",\n\t\"Q33875\",\n\t\"alg\",\n\totherNames = {\"Ojibwayensis\", \"Ojibwayenses\", \"Ojibwayenses\", \"Ojibwayense\", \"Ojibwayensia\", \"Ojibwayensis\", \"Anishinaabemowin / ᐊᓂᔑᓈᐯᒧᐎᓐ\", \n\t\"Ojibwayensis\", \"Ojibwayensi\", \"Ojibwayensium\"},\n\taliases = {\"Ojibway\", \"Ojibwa\"},\n\tvarieties = {{\"Chippewa\", \"Ojibwemowin\", \"Southwestern Ojibwa\"}},\n\tscripts = {\"Cans\", \"Latn\"},\n\tsort_key = {\n\t\tfrom = {\"aa\", \"ʼ\",  \"ii\", \"oo\", \"sh\", \"zh\"},\n\t\tto   = {\"a~\", \"h~\", \"i~\", \"o~\", \"s~\", \"z~\"}} ,\n}\n\nm[\"om\"] = {\n\tcanonicalName = \"Oromo\",\n\totherNames = {\"Orma\", \"Borana-Arsi-Guji Oromo\", \"West Central Oromo\"},\n\tscripts = {\"Latn\", \"Ethi\"},\n\tfamily = \"cus\",\n}\n\nm[\"or\"] = {\n\tcanonicalName = \"Oriya\",\n\totherNames = {\"Odia\", \"Oorya\"},\n\tscripts = {\"Orya\"},\n\tfamily = \"inc\",\n\tancestors = {\"pka\"},\n}\n\nm[\"os\"] = {\n\tcanonicalName = \"Alane\",\n\totherNames = {\"Ossete\", \"Ossetic\", \"Digor\", \"Iron\"},\n\tscripts = {\"Cyrl\", \"Geor\", \"Latn\"},\n\tfamily = \"ira\",\n\ttranslit_module = \"os-translit\",\n\tancestors = {\"oos\"},\n\tentry_name = {\n\t\tfrom = {GRAVE, ACUTE},\n\t\tto   = {}} ,\n}\n\nm[\"pa\"] = {\n\tcanonicalName = \"Punjabi\",\n\totherNames = {\"Panjabi\"},\n\tscripts = {\"Guru\", \"Arab\", \"Deva\"},\n\tfamily = \"inc\",\n\ttranslit_module = \"pa-translit\",\n\tancestors = {\"psu\"},\n}\n\nm[\"pi\"] = {\n\tcanonicalName = \"Pali\",\n\tscripts = {\"Latn\", \"Deva\", \"Sinh\", \"Mymr\", \"Khmr\", \"Thai\"},\n\tfamily = \"inc\",\n\tancestors = {\"bh\"},\n\tsort_key = {\n\t\tfrom = {\"ā\", \"ī\", \"ū\", \"ḍ\", \"ḷ\", \"[ṁṃ]\", \"[ṇñṅ]\", \"ṭ\"},\n\t\tto   = {\"a\", \"i\", \"u\", \"d\", \"l\", \"m\"   , \"n\"\t, \"t\"}} ,\n}\n\nm[\"pl\"] = {\n\tcanonicalName = \"Polonice\",\n\totherNames = {\"Polonica\", \"Polonicae\", \"Polonici\", \"Polonicum\", \"Polonica\", \"Polonicae\", \"język polski\",\n\t\t\"Polonicus\", \"Polonica\", \"Polonicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zlw\",\n\tancestors = {\"zlw-opl\"},\n\tsort_key = {\n\t\tfrom = {\"[Ąą]\", \"[Ćć]\", \"[Ęę]\", \"[Łł]\", \"[Ńń]\", \"[Óó]\", \"[Śś]\", \"[Żż]\", \"[Źź]\"},\n\t\tto   = {\n\t\t\t\"a\" .. u(0x10FFFF),\n\t\t\t\"c\" .. u(0x10FFFF),\n\t\t\t\"e\" .. u(0x10FFFF),\n\t\t\t\"l\" .. u(0x10FFFF),\n\t\t\t\"n\" .. u(0x10FFFF),\n\t\t\t\"o\" .. u(0x10FFFF),\n\t\t\t\"s\" .. u(0x10FFFF),\n\t\t\t\"z\" .. u(0x10FFFF),\n\t\t\t\"z\" .. u(0x10FFFE)}} ,\n}\n\nm[\"ps\"] = {\n\tcanonicalName = \"Afganice\",\n\totherNames = {\"Afganica\", \"Afganicae\", \"Afganici\", \"Afganicum\", \"Afganica\", \"Afganicae\", \"پښتو\", \n\t\t\"Afganicus\", \"Afganica\", \"Afganicarum\", \"Pashtun\", \"Pushto\", \"Pashtu\", \"Central Pashto\", \"Northern Pashto\", \"Southern Pashto\", \"Pukhto\", \"Pakhto\", \"Pakkhto\", \"Afghani\"},\n\tscripts = {\"ps-Arab\"},\n\tfamily = \"ira-eas\",\n}\n\nm[\"pt\"] = {\n\tcanonicalName = \"Lusitane\",\n\totherNames = {\"Lusitana\", \"Lusitanae\", \"Lusitani\", \"Lusitanum\", \"Lusitana\", \"Lusitanae\", \"português\", \n\t\t\"Lusitanus\", \"Lusitana\", \"Lusitanarum\", \"Modern Portuguese\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"roa-opt\"},\n\tsort_key = {\n\t\tfrom = {\"[àãáâä]\", \"[èẽéêë]\", \"[ìĩíï]\", \"[òóôõö]\", \"[üúùũ]\", \"ç\", \"ñ\"},\n\t\tto   = {\"a\"\t  , \"e\"\t  , \"i\"\t , \"o\"\t  , \"u\"\t , \"c\", \"n\"}} ,\n}\n\nm[\"qu\"] = {\n\tcanonicalName = \"Quechua\",\n\totherNames = {\"Quechua\", \"Quechuae\", \"Quechui\", \"Quechuum\", \"Quechua\", \"Quechuae\", \"Runasimi\", \n\t\t\"Quechuus\", \"Quechua\", \"Quechuarum\", \"Qhichwa simi\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"qwe\",\n}\n\nm[\"rm\"] = {\n\tcanonicalName = \"Raetice\",\n\totherNames = {\"Raetica\", \"Raeticae\", \"Raetici\", \"Raeticum\", \"Raetica\", \"Raeticae\", \"rumantsch\", \n\t\t\"Raeticus\", \"Raetica\", \"Raeticarum\", \"Romansh\", \"Romanche\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n}\n\nm[\"rn\"] = {\n\tcanonicalName = \"Kirundi\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"ro\"] = {\n\tcanonicalName = \"Dacoromane\",\n\totherNames = {\"Dacoromana\", \"Dacoromanae\", \"Dacoromani\", \"Dacoromanum\", \"Dacoromana\", \"Dacoromanae\", \"româna\", \n\t\t\"Dacoromanus\", \"Dacoromana\", \"Dacoromanarum\", \"Daco-Romanian\", \"Roumanian\", \"Rumanian\"},\n\tscripts = {\"Latn\", \"Cyrl\"},\n\tfamily = \"roa\",\n\tsort_key = {\n        from = {\"ă\" , \"â\"  , \"î\" , \"ș\" , \"ț\" },\n        to   = {\"a~\", \"a~~\", \"i~\", \"s~\", \"t~\"}},\n}\n\nm[\"ru\"] = {\n\tcanonicalName = \"Ruthenice\",\n\totherNames = {\"Ruthenica\", \"Ruthenicae\", \"Ruthenici\", \"Ruthenicum\", \"Ruthenica\", \"Ruthenicae\", \"русский язык\", \n\t\t\"Ruthenicus\", \"Ruthenica\", \"Ruthenicarum\"},\n\tscripts = {\"Cyrl\"},\n\tfamily = \"zle\",\n\ttranslit_module = \"ru-translit\",\n\tsort_key = {\n\t\tfrom = {\"ё\"},\n\t\tto   = {\"е\" .. mw.ustring.char(0x10FFFF)}},\n\tentry_name = {\n\t\tfrom = {\"Ѐ\", \"ѐ\", \"Ѝ\", \"ѝ\", GRAVE, ACUTE},\n\t\tto   = {\"Е\", \"е\", \"И\", \"и\"}},\n}\n\nm[\"rw\"] = {\n\tcanonicalName = \"Kinyarwanda\",\n\totherNames = {\"Rwanda\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"sa\"] = {\n\tcanonicalName = \"Sanscrite\",\n\totherNames = {\"Sanscrita\", \"Sanscritae\", \"Sanscriti\", \"Sanscritum\", \"Sanscrita\", \"Sanscritae\", \"संस्कृत\", \n\t\t\"Sanscritus\", \"Sanscrita\", \"Sanscritarum\"},\n\tscripts = {\"Deva\", \"Beng\", \"Brah\", \"Gran\", \"Gujr\", \"Guru\", \"Khar\", \"Knda\", \"Mlym\", \"Mymr\", \"Orya\", \"Shrd\", \"Sinh\", \"Taml\", \"Telu\", \"Thai\", \"Tibt\"},\n\tfamily = \"inc\",\n\ttranslit_module = \"sa-translit\",\n}\n\n-- 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf, 7=ipsa, 8=nomsgm, 9=ablsgf, 10=genplf\nm[\"sc\"] = {\n\t\"Sarde\", \"Q33976\", \"roa\",\n\totherNames = {\"Sarda\", \"Sardae\", \"Sardi\", \"Sardum\", \"Sarda\", \"Sardae\", \"sarda\", \n\t\t\"Sardus\", \"Sarda\", \"Sardarum\", \"Campidanese\", \"Campidanese Sardinian\", \"Logudorese\", \"Logudorese Sardinian\", \"Nuorese\", \"Nuorese Sardinian\"},\n\tscripts = {\"Latn\"},\n}\n\nm[\"sd\"] = {\n\tcanonicalName = \"Sindhi\",\n\tscripts = {\"sd-Arab\", \"Deva\"},\n\tfamily = \"inc\",\n}\n\n-- otherNames is used for inflected forms: 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf\nm[\"se\"] = {\n\tcanonicalName = \"Lapponica Septentrionali\",\n\totherNames = {\"Lapponica Septentrionalis\", \"Lapponicae Septentrionales\", \"Lapponici Septentrionales\", \"Lapponicum Septentrionale\", \"Lapponica Septentrionalia\", \"Lapponicae Septentrionalis\", \"Davvisámegiella\",\n\t\t\"Lapponicus Septentrionalis\", \"Lapponica Septentrionali\", \"Lapponicarum Septentrionalium\", \"Samica septentrionalis\", \"North Sami\", \"Northern Saami\", \"North Saami\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"smi\",\n\tentry_name = {\n\t\tfrom = {\"([đflmnŋrsšŧv])'%1\"},\n\t\tto   = {\"%1%1\"} },\n}\n\nm[\"sg\"] = {\n\tcanonicalName = \"Sango\",\n\tscripts = {\"Latn\"},\n\tfamily = \"crp\",\n}\n\nm[\"sh\"] = {\n\tcanonicalName = \"Servocroate\",\n\totherNames = {\"Servocroata\", \"Servocroatae\", \"Servocroati\", \"Servocroatum\", \"Servocroata\", \"Servocroatae\", \"srpskohrvatski\", \n\t\t\"Servocroatus\", \"Servocroata\", \"Servocroatarum\", \"BCS\", \"Croato-Serbian\", \"Serbocroatian\", \"Bosnian\", \"Croatian\", \"Montenegrin\", \"Serbian\"},\n\tscripts = {\"Latn\", \"Cyrl\"},\n\tfamily = \"zls\",\n\tentry_name = {\n\t\tfrom = {\"[ȀÀȂÁĀ]\", \"[ȁàȃáā]\", \"[ȄÈȆÉĒ]\", \"[ȅèȇéē]\", \"[ȈÌȊÍĪ]\", \"[ȉìȋíī]\", \"[ȌÒȎÓŌ]\", \"[ȍòȏóō]\", \"[ȐȒŔ]\", \"[ȑȓŕ]\", \"[ȔÙȖÚŪ]\", \"[ȕùȗúū]\", \"Ѐ\", \"ѐ\", \"[ӢЍ]\", \"[ӣѝ]\", \"[Ӯ]\", \"[ӯ]\", GRAVE, ACUTE, DGRAVE, INVBREVE, MACRON},\n\t\tto   = {\"A\"\t  , \"a\"\t  , \"E\"\t  , \"e\"\t  , \"I\"\t  , \"i\"\t  , \"O\"\t  , \"o\"\t  , \"R\"\t, \"r\"\t, \"U\"\t  , \"u\"\t  , \"Е\", \"е\", \"И\"   , \"и\", \"У\", \"у\"   }},\n\twikimedia_codes = {\"sh\", \"bs\", \"hr\", \"sr\"},\n}\n\nm[\"si\"] = {\n\tcanonicalName = \"Sinhalese\",\n\totherNames = {\"Singhalese\", \"Sinhala\"},\n\tscripts = {\"Sinh\"},\n\tfamily = \"inc\",\n\tancestors = {\"pmh\"},\n\ttranslit_module = \"si-translit\",\n}\n\nm[\"sk\"] = {\n\tcanonicalName = \"Slovace\",\n\totherNames = {\"Slovaca\", \"Slovacae\", \"Slovaci\", \"Slovacum\", \"Slovaca\", \"Slovacae\", \"slovenčina\", \n\t\t\"Slovacus\", \"Slovaca\", \"Slovacarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zlw\",\n\tsort_key = {\n\t\tfrom = {\"[áä]\", \"é\", \"í\", \"[óô]\", \"ú\", \"ý\", \"ŕ\", \"ĺ\"},\n\t\tto   = {\"a\"   , \"e\", \"i\", \"o\"   , \"u\", \"y\", \"r\", \"l\"}} ,\n}\n\nm[\"sl\"] = {\n\tcanonicalName = \"Slovene\",\n\totherNames = {\"Slovena\", \"Slovenae\", \"Sloveni\", \"Slovenum\", \"Slovena\", \"Slovenae\", \"slovenščina\", \n\t\t\"Slovenus\", \"Slovena\", \"Slovenarum\", \"Slovenian\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"zls\",\n\tentry_name = {\n\t\tfrom = {\"[ÁÀÂȂȀ]\", \"[áàâȃȁ]\", \"[ÉÈÊȆȄỆẸ]\", \"[éèêȇȅệẹə]\", \"[ÍÌÎȊȈ]\", \"[íìîȋȉ]\", \"[ÓÒÔȎȌỘỌ]\", \"[óòôȏȍộọ]\", \"[ŔȒȐ]\", \"[ŕȓȑ]\", \"[ÚÙÛȖȔ]\", \"[úùûȗȕ]\", \"ł\", GRAVE, ACUTE, DGRAVE, INVBREVE, CIRC, DOTBELOW},\n\t\tto   = {\"A\"\t  , \"a\"\t  , \"E\"\t\t, \"e\"\t\t , \"I\"\t  , \"i\"\t  , \"O\"\t\t, \"o\"\t\t, \"R\"\t, \"r\"\t, \"U\"\t  , \"u\"\t  , \"l\"}} ,\n}\n\nm[\"sm\"] = {\n\tcanonicalName = \"Samoane\",\n\totherNames = {\"Samoana\", \"Samoanae\", \"Samoani\", \"Samoanum\", \"Samoana\", \"Samoanae\", \"gagana Sāmoa\", \n\t\t\"Samoanus\", \"Samoana\", \"Samoanarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-pol\",\n}\n\nm[\"sn\"] = {\n\tcanonicalName = \"Shona\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"so\"] = {\n\tcanonicalName = \"Somali\",\n\tscripts = {\"Latn\", \"Arab\", \"Osma\"},\n\tfamily = \"cus\",\n\tentry_name = {\n\t\tfrom = {\"[ÁÀÂ]\", \"[áàâ]\", \"[ÉÈÊ]\", \"[éèê]\", \"[ÍÌÎ]\", \"[íìî]\", \"[ÓÒÔ]\", \"[óòô]\", \"[ÚÙÛ]\", \"[úùû]\", \"[ÝỲ]\", \"[ýỳ]\"},\n\t\tto   = {\"A\"\t  , \"a\"\t  , \"E\"\t, \"e\" , \"I\"\t  , \"i\"\t  , \"O\"\t, \"o\"\t, \"U\"  , \"u\", \"Y\", \"y\"}} ,\n}\n\nm[\"sq\"] = {\n\tcanonicalName = \"Illyrice\",\n\totherNames = {\"Illyrica\", \"Illyricae\", \"Illyrici\", \"Illyricum\", \"Illyrica\", \"Illyricae\", \"shqipja\", \n\t\t\"Illyricus\", \"Illyrica\", \"Illyricarum\"},\n\tscripts = {\"Latn\", \"Elba\"},\n\tfamily = \"sqj\",\n\tsort_key = {\n\t\tfrom = { '[âãä]', '[ÂÃÄ]', '[êẽë]', '[ÊẼË]', 'ĩ', 'Ĩ', 'õ', 'Õ', 'ũ', 'Ũ', 'ỹ', 'Ỹ', 'ç', 'Ç' },\n\t\tto   = {     'a',     'A',     'e',     'E', 'i', 'I', 'o', 'O', 'u', 'U', 'y', 'Y', 'c', 'C' } } ,\n}\n\nm[\"sr\"] = {\n\tcanonicalName = \"Service\",\n\totherNames = {\"Servica\", \"Servicae\", \"Servici\", \"Servicum\", \"Servica\", \"Servicae\", \"српски / srpski\", \n\t\t\"Servicus\", \"Servica\", \"Servicarum\"},\n\tscripts = {\"Latn\", \"Cyrl\"},\n\tfamily = \"zls\",\n\ttranslit_module = \"sh-translit\",\n\tentry_name = {\n\t\tfrom = {\"[ȀÀȂÁĀ]\", \"[ȁàȃáā]\", \"[ȄÈȆÉĒ]\", \"[ȅèȇéē]\", \"[ȈÌȊÍĪ]\", \"[ȉìȋíī]\", \"[ȌÒȎÓŌ]\", \"[ȍòȏóō]\", \"[ȐȒŔ]\", \"[ȑȓŕ]\", \"[ȔÙȖÚŪ]\", \"[ȕùȗúū]\", \"Ѐ\", \"ѐ\", \"[ӢЍ]\", \"[ӣѝ]\", \"[Ӯ]\", \"[ӯ]\", GRAVE, ACUTE, DGRAVE, INVBREVE, MACRON},\n\t\tto   = {\"A\"\t  , \"a\"\t  , \"E\"\t  , \"e\"\t  , \"I\"\t  , \"i\"\t  , \"O\"\t  , \"o\"\t  , \"R\"\t, \"r\"\t, \"U\"\t  , \"u\"\t  , \"Е\", \"е\", \"И\"   , \"и\", \"У\", \"у\"   }},\n\twikimedia_codes = {\"sh\", \"bs\", \"hr\", \"sr\"},\n}\n\nm[\"ss\"] = {\n\tcanonicalName = \"Swazi\",\n\totherNames = {\"Swati\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt-ngu\",\n}\n\nm[\"st\"] = {\n\tcanonicalName = \"Sotho Meridionali\",\n\totherNames = {\"Sesotho\", \"Southern Sesotho\", \"Southern Sotho\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"su\"] = {\n\tcanonicalName = \"Sondaice\",\n\tscripts = {\"Latn\", \"Sund\"},\n\tfamily = \"poz-msa\",\n\ttranslit_module = \"su-translit\",\n}\n\nm[\"sv\"] = {\n\tcanonicalName = \"Suecice\",\n\totherNames = {\"Suecica\", \"Suecicae\", \"Suecici\", \"Suecicum\", \"Suecica\", \"Suecicae\", \"svenska\", \n\t\t\"Suecicus\", \"Suecica\", \"Suecicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"gmq\",\n\tancestors = {\"gmq-osw\"},\n}\n\nm[\"sw\"] = {\n\tcanonicalName = \"Suahelice\",\n\totherNames = {\"Suahelica\", \"Suahelicae\", \"Suahelici\", \"Suahelicum\", \"Suahelica\", \"Suahelicae\", \"Kiswahili\", \n\t\t\"Suahelicus\", \"Suahelica\", \"Suahelicarum\", \"Settler Swahili\", \"KiSetla\", \"KiSettla\", \"Setla\", \"Settla\", \"Kitchen Swahili\", \"Kihindi\", \"Indian Swahili\", \"KiShamba\", \"Kishamba\", \"Field Swahili\", \"Kibabu\", \"Asian Swahili\", \"Kimanga\", \"Arab Swahili\", \"Kitvita\", \"Army Swahili\"},\n\tscripts = {\"Latn\", \"Arab\"},\n\tfamily = \"bnt\",\n\tsort_key = {\n\t\tfrom = {\"ng'\", \"^-\"},\n\t\tto   = {\"ngz\"}} ,\n}\n\nm[\"ta\"] = {\n\tcanonicalName = \"Tamulice\",\n\totherNames = {\"Tamulica\", \"Tamulicae\", \"Tamulici\", \"Tamulicum\", \"Tamulica\", \"Tamulicae\", \"தமிழ்\", \n\t\t\"Tamulicus\", \"Tamulica\", \"Tamulicarum\", \"Tamil\"},\n\tscripts = {\"Taml\"},\n\tfamily = \"dra\",\n\tancestors = {\"oty\"},\n\ttranslit_module = \"ta-translit\",\n}\n\nm[\"te\"] = {\n\tcanonicalName = \"Teluguice\",\n\tscripts = {\"Telu\"},\n\tfamily = \"dra\",\n\ttranslit_module = \"te-translit\",\n}\n\nm[\"tg\"] = {\n\tcanonicalName = \"Tadzikice\",\n\totherNames = {\"Tadzikica\", \"Tadzikicae\", \"Tadzikici\", \"Tadzikicum\", \"Tadzikica\", \"Tadzikicae\", \"Тоҷикӣ\", \n\t\t\"Tadzikicus\", \"Tadzikica\", \"Tadzikicarum\", \"Tajik\", \"Tadjik\", \"Tadzhik\", \"Tajiki\", \"Tajik Persian\"},\n\tscripts = {\"Cyrl\", \"fa-Arab\", \"Latn\"},\n\tfamily = \"ira-wes\",\n\tancestors = {\"fa\"},\n\ttranslit_module = \"tg-translit\",\n\t\tsort_key = {\n\t\tfrom = {\"Ё\", \"ё\"},\n\t\tto   = {\"Е\" , \"е\"}} ,\n\tentry_name = {\n\t\tfrom = {ACUTE},\n\t\tto   = {}} ,\n}\n\nm[\"th\"] = {\n\tcanonicalName = \"Siamense\",\n\totherNames = {\"Siamensis\", \"Siamenses\", \"Siamenses\", \"Siamense\", \"Siamensia\", \"Siamensis\", \"ภาษาไทย\", \n\t\t\"Siamensis\", \"Siamensi\", \"Siamensium\", \"Thai\"},\n\tscripts = {\"Thai\"},\n\tfamily = \"tai-swe\",\n\ttranslit_module = \"th-translit\",\n\tentry_name = {\n\t\tfrom = { \"-\" },\n\t\tto = {}} ,\n}\n\nm[\"ti\"] = {\n\tcanonicalName = \"Tigrinya\",\n\tscripts = {\"Ethi\"},\n\tfamily = \"sem-eth\",\n\ttranslit_module = \"Ethi-translit\",\n}\n\nm[\"tk\"] = {\n\tcanonicalName = \"Turcomannice\",\n\totherNames = {\"Turcomannica\", \"Turcomannicae\", \"Turcomannici\", \"Turcomannicum\", \"Turcomannica\", \"Turcomannicae\", \"Türkmençe\", \n\t\t\"Turcomannicus\", \"Turcomannica\", \"Turcomannicarum\", \"Tүркменче\", \"Türkmen dili\", \"تورکمن ﺗﻴﻠی\"},\n\tscripts = {\"Latn\", \"Cyrl\"},\n\tfamily = \"trk-ogz\",\n}\n\nm[\"tl\"] = {\n\tcanonicalName = \"Tagale\",\n\totherNames = {\"Tagala\", \"Tagalae\", \"Tagali\", \"Tagalum\", \"Tagala\", \"Tagalae\", \"Wikang Tagalog\", \n\t\t\"Tagalus\", \"Tagala\", \"Tagalarum\"},\n\tscripts = {\"Latn\", \"Tglg\"},\n\tfamily = \"phi\",\n}\n\nm[\"tn\"] = {\n\tcanonicalName = \"Tswana\",\n\totherNames = {\"Setswana\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"to\"] = {\n\tcanonicalName = \"Tongane\",\n\totherNames = {\"Tongana\", \"Tonganae\", \"Tongani\", \"Tonganum\", \"Tongana\", \"Tonganae\", \"lea fakatonga\", \n\t\t\"Tonganus\", \"Tongana\", \"Tonganarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-pol\",\n}\n\nm[\"tr\"] = {\n\tcanonicalName = \"Turcice\",\n\totherNames = {\"Turcica\", \"Turcicae\", \"Turcici\", \"Turcicum\", \"Turcica\", \"Turcicae\", \"Türkçe\", \n\t\t\"Turcicus\", \"Turcica\", \"Turcicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"trk-ogz\",\n\tancestors = {\"ota\"},\n}\n\nm[\"ts\"] = {\n\tcanonicalName = \"Tsonga\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\nm[\"tt\"] = {\n\tcanonicalName = \"Tatarice\",\n\totherNames = {\"Tatarica\", \"Tataricae\", \"Tatarici\", \"Tataricum\", \"Tatarica\", \"Tataricae\", \"татарча / tatarça\", \n\t\t\"Tataricus\", \"Tatarica\", \"Tataricarum\"},\n\tscripts = {\"Cyrl\", \"Latn\", \"Arab\", \"tt-Arab\"},\n\tfamily = \"trk-kip\",\n\ttranslit_module = \"tt-translit\",\n}\n\nm[\"ty\"] = {\n\tcanonicalName = \"Tahitiane\",\n\totherNames = {\"Tahitiana\", \"Tahitianae\", \"Tahitiani\", \"Tahitianum\", \"Tahitiana\", \"Tahitianae\", \"reo Mā’ohi\",\n\t\t\"Tahitianus\", \"Tahitiana\", \"Tahitianarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"poz-pol\",\n}\n\nm[\"ug\"] = {\n\tcanonicalName = \"Uyghur\",\n\totherNames = {\"Uigur\", \"Uighur\", \"Uygur\"},\n\tscripts = {\"ug-Arab\", \"Latn\", \"Cyrl\"},\n\tfamily = \"trk\",\n\tancestors = {\"chg\"},\n\ttranslit_module = \"ug-translit\",\n}\n\nm[\"uk\"] = {\n\tcanonicalName = \"Ucrainice\",\n\totherNames = {\"Ucrainica\", \"Ucrainicae\", \"Ucrainici\", \"Ucrainicum\", \"Ucrainica\", \"Ucrainicae\", \"українська\", \n\t\t\"Ucrainicus\", \"Ucrainica\", \"Ucrainicarum\"},\n\tscripts = {\"Cyrl\"},\n\tfamily = \"zle\",\n\ttranslit_module = \"uk-translit\",\n\tentry_name = {\n\t\tfrom = {\"Ѐ\", \"ѐ\", \"Ѝ\", \"ѝ\", GRAVE, ACUTE},\n\t\tto   = {\"Е\", \"е\", \"И\", \"и\"}},\n} \nm[\"ur\"] = {\n\tcanonicalName = \"Urdu\",\n\totherNames = {\"Urdu\"},\n\tscripts = {\"ur-Arab\"},\n\tfamily = \"inc\",\n\tancestors = {\"psu\"},\n\tentry_name = {\n\t\tfrom = {u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652)},\n\t\tto   = {}} ,\n}\n\nm[\"uz\"] = {\n\tcanonicalName = \"Usbece\",\n\totherNames = {\"Northern Uzbek\", \"Southern Uzbek\"},\n\tscripts = {\"Latn\", \"Cyrl\", \"fa-Arab\"},\n\tfamily = \"trk\",\n\tancestors = {\"chg\"},\n}\n\nm[\"ve\"] = {\n\tcanonicalName = \"Venda\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt\",\n}\n\n-- otherNames is used for inflected forms: 1=nomsgf, 2=nomplf, 3=nomplm, 4=nomsgn, 5=nompln, 6=gensgf\nm[\"vi\"] = {\n\tcanonicalName = \"Vietnamice\",\n\totherNames = {\"Vietnamica\", \"Vietnamicae\", \"Vietnamici\", \"Vietnamicum\", \"Vietnamica\", \"Vietnamicae\", \"tiếng Việt\", \n\t\t\"Vietnamicus\", \"Vietnamica\", \"Vietnamicarum\", \"Annamese\", \"Annamite\"},\n\tscripts = {\"Latn\", \"Hani\"},\n\tfamily = \"mkh-vie\",\n\tancestors = {\"mkh-mvi\"},\n}\n\nm[\"vo\"] = {\n\tcanonicalName = \"Volapük\",\n\tscripts = {\"Latn\"},\n\tfamily = \"art\",\n}\n\nm[\"wa\"] = {\n\tcanonicalName = \"Vallonice\",\n\totherNames = {\"Vallonica\", \"Vallonicae\", \"Vallonici\", \"Vallonicum\", \"Vallonica\", \"Vallonicae\", \"walon\", \n\t\t\"Vallonicus\", \"Vallonica\", \"Vallonicarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"roa\",\n\tancestors = {\"fro\"},\n\tsort_key = {\n\t\tfrom = {\"[áàâäå]\", \"[éèêë]\", \"[íìîï]\", \"[óòôö]\", \"[úùûü]\", \"[ýỳŷÿ]\", \"ç\", \"'\"},\n\t\tto   = {\"a\"\t  , \"e\"\t , \"i\"\t , \"o\"\t , \"u\"\t , \"y\"\t , \"c\"}} ,\n}\n\nm[\"wo\"] = {\n\tcanonicalName = \"Wolof\",\n\totherNames = {\"Gambian Wolof\"}, -- the subsumed dialect 'wof'\n\tscripts = {\"Latn\", \"Arab\"},\n\tfamily = \"alv-sng\",\n}\n\nm[\"xh\"] = {\n\tcanonicalName = \"Xhosa\",\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt-ngu\",\n}\n\nm[\"yi\"] = {\n\tcanonicalName = \"Iudaeogermanice\",\n\totherNames = {\"Iudaeogermanica\", \"Iudaeogermanicae\", \"Iudaeogermanici\", \"Iudaeogermanicum\", \"Iudaeogermanica\", \"Iudaeogermanicae\", \"יידיש\", \n\t\t\"Iudaeogermanicus\", \"Iudaeogermanica\", \"Iudaeogermanicarum\", \"Jiddisch\"},\n\tscripts = {\"Hebr\"},\n\tfamily = \"gmw\",\n\tancestors = {\"gmh\"},\n\ttranslit_module = \"yi-translit\",\n}\n\nm[\"yo\"] = {\n\tcanonicalName = \"Yoruba\",\n\tscripts = {\"Latn\"},\n\tfamily = \"alv-von\",\n}\n\nm[\"za\"] = {\n\tcanonicalName = \"Zhuang\",\n\tscripts = {\"Latn\", \"Hani\"},\n\tfamily = \"tai\",\n}\n\nm[\"zh\"] = {\n\tcanonicalName = \"Sinice\",\n\totherNames = {\"Sinica\", \"Sinicae\", \"Sinici\", \"Sinicum\", \"Sinica\", \"Sinicae\", \"中文\", \n\t\t\"Sinicus\", \"Sinica\", \"Sinicarum\"},\n\tscripts = {\"Hani\"},\n\tfamily = \"sit\",\n\tancestors = {\"ltc\"},\n}\n\nm[\"zu\"] = {\n\tcanonicalName = \"Zuluane\",\n\totherNames = {\"Zuluana\", \"Zuluanae\", \"Zuluani\", \"Zuluanum\", \"Zuluana\", \"Zuluanae\", \"isiZulu\", \n\t\t\"Zuluanus\", \"Zuluana\", \"Zuluanarum\"},\n\tscripts = {\"Latn\"},\n\tfamily = \"bnt-ngu\",\n}\n\nreturn m";


test "parent phase profile retains unavailable CPU separately from elapsed wall" {
    var consume: ParentPhaseTotals = .{};
    consume.record(.{ .cpu_ns = 40, .wall_ns = 100 }, .{ .cpu_ns = 70, .wall_ns = 180 });
    consume.record(.{ .cpu_ns = null, .wall_ns = 200 }, .{ .cpu_ns = 90, .wall_ns = 240 });
    var total: ParentPhaseTotals = .{};
    total.merge(consume);
    try std.testing.expectEqual(@as(u64, 2), total.calls);
    try std.testing.expectEqual(@as(u64, 30), total.cpu_ns);
    try std.testing.expectEqual(@as(u64, 120), total.wall_ns);
    try std.testing.expectEqual(@as(u64, 1), total.cpu_clock_misses);
}

const LoLiteralSwitchTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tlowiktionary\n# dump-date\t20261001\n# content-language\tlo\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tແມ່ແບບ\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
        "14\tໝວດ\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n";
    const registry = "# content-language\tlo\n# mediawiki\nlo\tລາວ\nen\tEnglish\nfr\tFrench\nde\tGerman\nth\tThai\n";
    const authority = @embedFile("lo-codetolang-p64415-r458666.wikitext");
    fn install(io: std.Io, a: std.mem.Allocator, root: []const u8, source: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, "language-registry.tsv"}), .data = registry });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, "manifest.jsonl"}), .data = "" });
        const index_path = try std.fs.path.join(a, &.{root, "page-index.tsv"});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = "0\t0\tແມ່ແບບ:codetolang\t\t64415\t458666\t2017-01-01T00:00:00Z\tA\twikitext\t10\t1\t0\n" });
        var writer = try dump_source.TemplateSourceWriter.init(io, a, root); defer writer.deinit();
        try writer.append(0, 64415, 458666, source);
        try writer.finish(index_path);
    }
};

test "literal code language switch validates complete source and existing owners" {
    const a = std.testing.allocator;
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv(LoLiteralSwitchTest.registry);
    try std.testing.expect(try importLiteralLanguageNameSwitch(a, &registry, LoLiteralSwitchTest.authority));
    try std.testing.expectEqualStrings("lo", registry.resolveTrusted("ພາສາລາວ").?.code);
    try std.testing.expectEqualStrings("ລາວ", registry.resolveTrusted("ພາສາລາວ").?.heading);
    try std.testing.expect(registry.resolveTrusted("ກະລຸນາຊ່ອຍເພີ່ມຂໍ້ມູນ") == null);
    try std.testing.expect(registry.resolveTrusted("unknown") == null);
    try std.testing.expect(try importLiteralLanguageNameSwitch(a, &registry, "{{#switch:{{{1|}}}|zz=Unregistered label|#default=Default label}}"));
    try std.testing.expect(registry.resolveTrusted("Unregistered label") == null);
    try std.testing.expect(registry.resolveTrusted("Default label") == null);
    for ([_][]const u8{
        "{{#switch:{{{1|}}}|lo=New literal|en={{dynamic}}|#default=Default}}",
        "{{#switch:{{{1|}}}|lo=New literal|lo=Duplicate|#default=Default}}",
        "{{#switch:{{{2|}}}|lo=New literal|#default=Default}}",
        "{{#switch:{{{1|}}}|lo=New literal|#default=Default}}extra",
    }) |source| {
        try std.testing.expect(!try importLiteralLanguageNameSwitch(a, &registry, source));
        try std.testing.expect(registry.resolveTrusted("New literal") == null);
    }
    var conflict = language_registry.Registry.empty(a); defer conflict.deinit();
    try conflict.addTsv(LoLiteralSwitchTest.registry ++ "fr\tFrench\tພາສາລາວ\n");
    try std.testing.expect(try importLiteralLanguageNameSwitch(a, &conflict, LoLiteralSwitchTest.authority));
    try std.testing.expectEqualStrings("fr", conflict.resolve("ພາສາລາວ").?.code);
    try std.testing.expect(conflict.resolveTrusted("ພາສາລາວ") == null);
    try registry.addLocalAlias("ພາສາລາວ", "fr");
    try std.testing.expect(registry.resolveTrusted("ພາສາລາວ") == null);
}

test "normal literal language switch loader authenticates template source bytes" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ns = try namespace_registry.Registry.init(a, LoLiteralSwitchTest.namespaces); defer ns.deinit();
    try LoLiteralSwitchTest.install(io, a, root, LoLiteralSwitchTest.authority);
    var registry = try loadLanguageRegistry(io, a, root, &ns); defer registry.deinit();
    try std.testing.expectEqualStrings("lo", registry.resolveTrusted("ພາສາລາວ").?.code);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{root, "template-source.bin"}), .data = "mutated authority" });
    try std.testing.expectError(error.InvalidTemplateSourceIndex, loadLanguageRegistry(io, a, root, &ns));
}

test "normal literal switch Writer preserves complete actual Lao page and unowned prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    var expected: [2]?[]const u8 = .{null, null};
    for ([_]bool{false, true}) |normal_loader| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        var ns = try namespace_registry.Registry.init(a, LoLiteralSwitchTest.namespaces); defer ns.deinit();
        try LoLiteralSwitchTest.install(io, a, root, if (normal_loader) LoLiteralSwitchTest.authority else "unsupported");
        var registry = try loadLanguageRegistry(io, a, root, &ns); defer registry.deinit();
        // Independently stated exact source declaration is the body oracle;
        // the second branch must acquire the same owner through normal loading.
        if (!normal_loader) try registry.addLocalAlias("ພາສາລາວ", "lo");
        const codes = languageCodes(&registry, &ns);
        const output = try std.fs.path.join(a, &.{root, "blobs"});
        var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
        writer.language_codes = codes;
        const source = @embedFile("lo-actual-p10416-r458986.wikitext");
        try std.testing.expectEqual(@as(usize, 460), source.len);
        try writer.addExpandedPage(a, .{ .id = 0, .kind = .language }, "ອ", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        for ([_][]const u8{"ລາວ"}, 0..) |owner, ordinal| {
            var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
            const path = try std.fs.path.join(a, &.{output, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename)});
            var mapped = try mmapPath(io, path); defer mapped.deinit();
            const blob = try encoder.blob_format.inspect(mapped.bytes); const metadata = try blob.languageMetadata();
            try std.testing.expectEqualStrings("lo", metadata.code);
            var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
            const record = (try index.find("ອ")) orelse return error.TestUnexpectedResult;
            const doc = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
            const complete = try std.json.Stringify.valueAlloc(a, doc, .{});
            if (!normal_loader) expected[ordinal] = complete else try std.testing.expectEqualStrings(expected[ordinal].?, complete);
            var links: usize = 0; var bold: usize = 0;
            for (doc.entry.sections) |section| for (section.blocks) |block| for (block.spans) |span| {
                if (span.kind == .link) links += 1;
                if (span.bold) bold += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), links);
            try std.testing.expectEqual(@as(usize, 1), bold);
            try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, doc));
        }
    }
}

const SdLeadingLanguageTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\tfr\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "6\tFile\tFile\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\tImage\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tزمرو\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n";
    const raw =
        \\=== سنڌي ===
        \\# ڏيکاءُ
        \\# مَڪر
        \\
        \\== انگريزي ==
        \\# Something that is showy or pretentious, often used to describe empty talk
        \\# Deceit or trickery, suitable for situations where "claptrap" implies something misleading or insincere
        \\
        \\===لاڳاپيل لفظ ۽ اصطلاح===
        \\{{-ترجما-}}
        \\== رومن سنڌي / (لپي مَٽَ) =={{)}}
        \\''Ddekhhau''
        \\''Makar''
        \\
        \\
        \\{{سنڌو رومن سنڌي}}
        \\
        \\
        \\[[زمرو:اصطلاح]]
        \\[[زمرو: رومن سنڌي]]
        \\[[Category: Transliteration]]
    ;
    const expanded =
        \\=== سنڌي ===
        \\# ڏيکاءُ
        \\# مَڪر
        \\
        \\== انگريزي ==
        \\# Something that is showy or pretentious, often used to describe empty talk
        \\# Deceit or trickery, suitable for situations where "claptrap" implies something misleading or insincere
        \\
        \\===لاڳاپيل لفظ ۽ اصطلاح===
        \\=== [[Image:trans.png|30px]] ترجما ===
        \\== رومن سنڌي / (لپي مَٽَ) ==|}
        \\''Ddekhhau''
        \\''Makar''
        \\
        \\
        \\[[زمرو:انڊس رومن سنڌي]]
        \\[[زمرو:سنڌو رومن سنڌي]]
        \\[[category:Indus Roman Sindhi]]
        \\
        \\
        \\
        \\[[زمرو:اصطلاح]]
        \\[[زمرو: رومن سنڌي]]
        \\[[Category: Transliteration]]
    ;
    fn read(a: std.mem.Allocator, root: []const u8, owner: []const u8) !encoder.presentation_types.Stored {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename)});
        // All decoded backing bytes have the enclosing test arena lifetime.
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(16 * 1024 * 1024));
        const blob = try encoder.blob_format.inspect(bytes);
        const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("claptrap")) orelse return error.TestUnexpectedResult;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
        return decoded;
    }
};

test "normal Writer leading registered Sindhi H3 separates complete claptrap body from English" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    var namespaces = try namespace_registry.Registry.init(a, SdLeadingLanguageTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\nsd\tسنڌي\tsd\tSindhi\tsnd\nen\tانگريزي\tEnglish\ten\teng\nfr\tFrench\n");
    const codes = languageCodes(&registry, &namespaces);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const output = try std.fs.path.join(a, &.{base, "actual"});
    var writer = try encoder.blob_builder.Writer.init(io, a, output); defer writer.deinit();
    writer.language_codes = codes;
    try writer.addExpandedPage(a, .{.id = 0, .kind = .language}, "claptrap", SdLeadingLanguageTest.expanded, SdLeadingLanguageTest.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    const sindhi = try SdLeadingLanguageTest.read(a, output, "سنڌي");
    const english = try SdLeadingLanguageTest.read(a, output, "انگريزي");
    try std.testing.expectEqualStrings("sd", sindhi.entry.language_code);
    try std.testing.expectEqualStrings("en", english.entry.language_code);
    try std.testing.expectEqual(@as(usize, 1), sindhi.entry.sections.len);
    try std.testing.expectEqual(@as(u8, 3), sindhi.entry.sections[0].level);
    try std.testing.expectEqualStrings("سنڌي", sindhi.entry.sections[0].title);
    try std.testing.expectEqual(@as(u8, 2), english.entry.sections[0].level);
    try std.testing.expectEqualStrings("انگريزي", english.entry.sections[0].title);
    const meanings = [_][]const u8{"ڏيکاءُ", "مَڪر"};
    try std.testing.expectEqual(@as(usize, 2), sindhi.entry.sections[0].blocks.len);
    for (sindhi.entry.sections[0].blocks, meanings) |block, meaning| {
        try std.testing.expect(block.kind == .definition);
        try std.testing.expectEqual(@as(usize, 1), block.spans.len);
        try std.testing.expectEqualStrings(meaning, block.spans[0].text);
    }
    try std.testing.expectEqual(@as(usize, 2), english.entry.sections[0].blocks.len);
    for (english.entry.sections[0].blocks) |block| try std.testing.expect(block.kind == .definition);
    try std.testing.expectEqual(@as(usize, 0), sindhi.entry.organization.lexemes.len);
    try std.testing.expectEqual(@as(usize, 0), english.entry.organization.lexemes.len);

    // Control: a real preceding L2 keeps the exact same H3 subordinate. Compare
    // every resulting section/block/span/action/style against this normal Writer
    // path; ownership splitting must not silently change the retained body.
    const control = try std.fs.path.join(a, &.{base, "control"});
    var nested = try encoder.blob_builder.Writer.init(io, a, control); defer nested.deinit(); nested.language_codes = codes;
    try nested.addExpandedPage(a, .{.id = 0, .kind = .language}, "claptrap", "== French ==\n" ++ SdLeadingLanguageTest.expanded, "== French ==\n" ++ SdLeadingLanguageTest.raw, null);
    const nested_stats = try nested.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), nested_stats.language_records);
    const subordinate = try SdLeadingLanguageTest.read(a, control, "French");
    const reference = try SdLeadingLanguageTest.read(a, control, "انگريزي");
    try std.testing.expectEqualStrings("fr", subordinate.entry.language_code);
    try std.testing.expectEqual(@as(usize, 2), subordinate.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 0), subordinate.entry.sections[0].blocks.len);
    try std.testing.expectEqualDeep(sindhi.entry.sections[0], subordinate.entry.sections[1]);
    try std.testing.expectEqualDeep(english.entry.sections, reference.entry.sections);
    try std.testing.expectEqualDeep(reference.entry.media, english.entry.media);
    try std.testing.expectEqualDeep(reference.entry.references, english.entry.references);
    try std.testing.expectEqual(@as(usize, 0), sindhi.entry.media.len);
    try std.testing.expectEqual(@as(usize, 0), sindhi.entry.references.len);
}

test "normal Writer deeper heading requires trusted registry authority not code edition or ordinary alias" {
    for ([_][]const u8{
        "# mediawiki\nen\tانگريزي\nfr\tFrench\n",
        "# mediawiki\nsd\tSindhi\tسنڌي\nen\tانگريزي\nfr\tFrench\n",
    }) |rows| {
        var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
        const a = arena.allocator(); const io = std.testing.io;
        var namespaces = try namespace_registry.Registry.init(a, SdLeadingLanguageTest.namespaces); defer namespaces.deinit();
        var registry = language_registry.Registry.empty(a); defer registry.deinit(); try registry.addTsv(rows);
        try std.testing.expect(registry.resolveTrusted("سنڌي") == null and registry.resolveStrong("سنڌي") == null);
        const codes = languageCodes(&registry, &namespaces);
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
        var writer = try encoder.blob_builder.Writer.init(io, a, root); defer writer.deinit(); writer.language_codes = codes;
        const source = "=== سنڌي ===\n# untouched prefix\n== انگريزي ==\n# English\n";
        try writer.addExpandedPage(a, .{.id = 0, .kind = .language}, "claptrap", source, source, null);
        const stats = try writer.finish(codes);
        try std.testing.expectEqual(@as(usize, 1), stats.language_records);
        const entry = try SdLeadingLanguageTest.read(a, root, "انگريزي");
        try std.testing.expectEqualStrings("en", entry.entry.language_code);
        try std.testing.expectEqual(@as(usize, 2), entry.entry.sections.len);
        try std.testing.expectEqualStrings("سنڌي", entry.entry.sections[0].title);
    }
}

test "normal Writer two trusted H3 peers keep separate owners and nested H4 body through codec" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    var namespaces = try namespace_registry.Registry.init(a, SdLeadingLanguageTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\nsd\tسنڌي\nen\tانگريزي\nfr\tFrench\n");
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, root); defer writer.deinit(); writer.language_codes = codes;
    const source = "=== سنڌي ===\n# [[sd-target|Sindhi]] '''bold'''\n==== انگريزي ====\n[[nested-target|nested]]\n=== انگريزي ===\n# [[en-target|English]] ''italic''\n";
    try writer.addExpandedPage(a, .{.id = 0, .kind = .language}, "claptrap", source, source, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 2), stats.language_records);
    const sindhi = try SdLeadingLanguageTest.read(a, root, "سنڌي");
    const english = try SdLeadingLanguageTest.read(a, root, "انگريزي");
    try std.testing.expectEqualStrings("sd", sindhi.entry.language_code);
    try std.testing.expectEqualStrings("en", english.entry.language_code);
    try std.testing.expectEqual(@as(usize, 2), sindhi.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 1), english.entry.sections.len);
    try std.testing.expectEqual(@as(u8, 3), sindhi.entry.sections[0].level);
    try std.testing.expectEqual(@as(u8, 4), sindhi.entry.sections[1].level);
    try std.testing.expectEqualStrings("انگريزي", sindhi.entry.sections[1].title);
    try std.testing.expectEqual(@as(u8, 3), english.entry.sections[0].level);
    var sd_links: usize = 0; var child_links: usize = 0; var en_links: usize = 0;
    var bold = false; var italic = false; var definitions: [2]usize = .{0, 0};
    for ([_]encoder.presentation_types.Entry{sindhi.entry, english.entry}, 0..) |entry, owner_index| {
        for (entry.sections) |section| for (section.blocks) |block| {
            if (block.kind == .definition) definitions[owner_index] += 1;
            for (block.spans) |span| {
                if (std.mem.eql(u8, span.target, "sd-target")) {
                    try std.testing.expect(owner_index == 0 and span.kind == .link);
                    try std.testing.expectEqualStrings("Sindhi", span.text); sd_links += 1;
                }
                if (std.mem.eql(u8, span.target, "nested-target")) {
                    try std.testing.expect(owner_index == 0 and section.level == 4 and span.kind == .link);
                    try std.testing.expectEqualStrings("nested", span.text); child_links += 1;
                }
                if (std.mem.eql(u8, span.target, "en-target")) {
                    try std.testing.expect(owner_index == 1 and span.kind == .link);
                    try std.testing.expectEqualStrings("English", span.text); en_links += 1;
                }
                bold = bold or (owner_index == 0 and span.bold and std.mem.eql(u8, span.text, "bold"));
                italic = italic or (owner_index == 1 and span.italic and std.mem.eql(u8, span.text, "italic"));
            }
        };
    }
    try std.testing.expectEqualSlices(usize, &.{1, 1}, &definitions);
    try std.testing.expectEqual(@as(usize, 1), sd_links);
    try std.testing.expectEqual(@as(usize, 1), child_links);
    try std.testing.expectEqual(@as(usize, 1), en_links);
    try std.testing.expect(bold and italic);
}

const HsbExactHeadingTest = struct {
    const namespaces = "# wikidict-namespace-registry-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\tfr\n" ++
        "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
        "10\tTemplate\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
        "14\tCategory\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n";
    const rows = "# mediawiki\nhsb\thornjoserbsce\ndsb\tdelnjoserbšćina\npl\tpólšćina\nfr\tFrench\n";
    // Synthetic body; exact real heading syntax and authenticated rěč projection.
    // This is not a captured full stary expansion.
    const raw = "'''stary'''\n== stary ({{rěč|hornjoserbšćina}}) ==\n# [[hsb-target|Upper]] '''bold'''\n# second\n# third\n# fourth\n== stary ({{rěč|delnjoserbšćina}}) ==\n# [[dsb-target|Lower]] ''italic''\n== stary ({{rěč|pólšćina}}) ==\n# [[pl-target|Polish]]\n";
    const expanded = "'''stary'''\n== stary ([[hornjoserbšćina|hornjoserbšćina]][[Category:hornjoserbšćina]]) ==\n# [[hsb-target|Upper]] '''bold'''\n# second\n# third\n# fourth\n== stary ([[delnjoserbšćina|delnjoserbšćina]][[Category:delnjoserbšćina]]) ==\n# [[dsb-target|Lower]] ''italic''\n== stary ([[pólšćina|pólšćina]][[Category:pólšćina]]) ==\n# [[pl-target|Polish]]\n";
    fn read(a: std.mem.Allocator, root: []const u8, owner: []const u8) !encoder.presentation_types.Stored {
        var filename: [encoder.blob_catalog.language_blob_filename_len]u8 = undefined;
        const path = try std.fs.path.join(a, &.{root, encoder.blob_catalog.language_directory, encoder.blob_catalog.languageBlobFilename(owner, &filename)});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(16 * 1024 * 1024));
        const blob = try encoder.blob_format.inspect(bytes); const metadata = try blob.languageMetadata();
        var index = try blob.buildTrustedIndexAlloc(a); defer index.deinit(a);
        const record = (try index.find("stary")) orelse return error.TestUnexpectedResult;
        const decoded = try encoder.presentation_codec.decodeAlloc(a, record.payload, record.title, .language, metadata);
        try std.testing.expectEqualSlices(u8, record.payload, try encoder.presentation_codec.encodeAlloc(a, decoded));
        return decoded;
    }
};

test "normal Writer exact reviewed Upper Sorbian template argument separates physical regions and prefix through codec" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const io = std.testing.io;
    var namespaces = try namespace_registry.Registry.init(a, HsbExactHeadingTest.namespaces); defer namespaces.deinit();
    var registry = language_registry.Registry.empty(a); defer registry.deinit();
    try registry.addTsv(HsbExactHeadingTest.rows);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &digest, .{});
    const marker = try std.fmt.allocPrint(a, "# reviewed-alias\thsb\thornjoserbšćina\thsb-hornjoserbscina-exact-enwik92963766-v1\t{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
    try registry.addTsv(marker);
    const codes = languageCodes(&registry, &namespaces);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/hsb", .{tmp.sub_path});
    var writer = try encoder.blob_builder.Writer.init(io, a, root); defer writer.deinit(); writer.language_codes = codes;
    try writer.addExpandedPage(a, .{.id=0, .kind=.language}, "stary", HsbExactHeadingTest.expanded, HsbExactHeadingTest.raw, null);
    const stats = try writer.finish(codes);
    try std.testing.expectEqual(@as(usize, 4), stats.language_records);
    const owners = [_][]const u8{"hornjoserbsce", "delnjoserbšćina", "pólšćina", "Unclassified"};
    const expected_codes = [_][]const u8{"hsb", "dsb", "pl", ""};
    const expected_definitions = [_]usize{4,1,1,0};
    const targets = [_][]const u8{"hsb-target", "dsb-target", "pl-target"};
    var bold = false; var italic = false; var prefix = false;
    for (owners, 0..) |owner, owner_index| {
        const stored = try HsbExactHeadingTest.read(a, root, owner);
        try std.testing.expectEqualStrings(expected_codes[owner_index], stored.entry.language_code);
        var definitions: usize = 0; var own_links: usize = 0;
        for (stored.entry.sections) |section| {
            if (owner_index < 3) try std.testing.expectEqual(@as(u8, 2), section.level);
            for (section.blocks) |block| {
                if (block.kind == .definition) definitions += 1;
                for (block.spans) |span| {
                    for (targets, 0..) |target, target_owner| if (std.mem.eql(u8, span.target, target)) {
                        try std.testing.expectEqual(target_owner, owner_index);
                        try std.testing.expect(span.kind == .link); own_links += 1;
                    };
                    bold = bold or (owner_index == 0 and span.bold and std.mem.eql(u8, span.text, "bold"));
                    italic = italic or (owner_index == 1 and span.italic and std.mem.eql(u8, span.text, "italic"));
                    prefix = prefix or (owner_index == 3 and span.bold and std.mem.eql(u8, span.text, "stary"));
                }
            }
        }
        try std.testing.expectEqual(expected_definitions[owner_index], definitions);
        try std.testing.expectEqual(@as(usize, if (owner_index < 3) 1 else 0), own_links);
    }
    try std.testing.expect(bold and italic and prefix);
    // The same complete fixture without the reviewed row reproduces the owner
    // leak. Its section bodies must survive redistribution byte-for-byte in
    // typed form, rather than being replaced by a shorter successful fixture.
    var unreviewed = language_registry.Registry.empty(a); defer unreviewed.deinit();
    try unreviewed.addTsv(HsbExactHeadingTest.rows);
    const old_codes = languageCodes(&unreviewed, &namespaces);
    const old_root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/without-alias", .{tmp.sub_path});
    var old_writer = try encoder.blob_builder.Writer.init(io, a, old_root); defer old_writer.deinit(); old_writer.language_codes = old_codes;
    try old_writer.addExpandedPage(a, .{.id=0, .kind=.language}, "stary", HsbExactHeadingTest.expanded, HsbExactHeadingTest.raw, null);
    try std.testing.expectEqual(@as(usize, 3), (try old_writer.finish(old_codes)).language_records);
    const old_lower = try HsbExactHeadingTest.read(a, old_root, "delnjoserbšćina");
    const new_upper = try HsbExactHeadingTest.read(a, root, "hornjoserbsce");
    const new_lower = try HsbExactHeadingTest.read(a, root, "delnjoserbšćina");
    try std.testing.expectEqual(@as(usize, 2), old_lower.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 1), new_upper.entry.sections.len);
    try std.testing.expectEqual(@as(usize, 1), new_lower.entry.sections.len);
    try std.testing.expectEqualDeep(old_lower.entry.sections[0], new_upper.entry.sections[0]);
    try std.testing.expectEqualDeep(old_lower.entry.sections[1], new_lower.entry.sections[0]);
    for ([_][]const u8{"pólšćina", "Unclassified"}) |unchanged_owner| {
        const old_record = try HsbExactHeadingTest.read(a, old_root, unchanged_owner);
        const new_record = try HsbExactHeadingTest.read(a, root, unchanged_owner);
        try std.testing.expectEqualDeep(old_record, new_record);
    }
}
