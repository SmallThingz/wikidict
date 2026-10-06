const std = @import("std");
const namespace_registry = @import("namespace_registry");
const encoder = @import("encoder");
const xml_decode = @import("xml_decode");
const dump_source = @import("wikimedia_dump");
const language_registry = @import("language_registry.zig");
const bundle_expander = @import("bundle_expander.zig");
const expansion_deadline = @import("expansion_deadline.zig");
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
};

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

const ExpansionJob = struct {
    ordinal: u64,
    ns: encoder.blob_builder.PageNamespace,
    title: []const u8,
    source: []const u8,
    alias_record: ?encoder.alias_codec.Record = null,
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

    fn consumeReady(self: *ExpansionSlot, writer: *encoder.blob_builder.Writer) !bool {
        if (!self.busy or !self.done.load(.acquire)) return false;
        defer {
            self.done.store(false, .release);
            self.busy = false;
            self.worker.last_failure = null;
            _ = self.arena.reset(.retain_capacity);
        }
        if (self.failure) |err| {
            std.debug.print(
                "page expansion failed title={s} ordinal={d} ns={d} source_bytes={d} error={s}\n",
                .{ self.job.title, self.job.ordinal, self.job.ns.id, self.job.source.len, @errorName(err) },
            );
            const fallback_reason = (try expansionFallbackReasonAlloc(self.arena.allocator(), err, self.worker.last_failure)) orelse return err;
            // Retain explicitly recoverable expansion failures with their exact
            // audit cause. Operational deadlines propagate through the classifier
            // above rather than masquerading as successfully encoded empty pages.
            if (self.job.alias_record) |alias| {
                try writer.addAliasExpanded(self.arena.allocator(), alias, "", null, .{ .expansion_error = true }, &.{fallback_reason});
                return true;
            }
            try writer.addExpansionFailure(self.arena.allocator(), self.job.ns, self.job.title, &.{fallback_reason});
            try writer.namespace_coverage.outcome(self.job.ns.id, .fallback);
            return true;
        }
        if (self.expansion) |expanded| {
            if (self.job.alias_record) |alias| {
                try writer.addAliasExpanded(self.arena.allocator(), alias, expanded.source, expanded.display_title, .{}, &.{});
                return true;
            }
            const fallback_before = writer.stats.fallback_pages;
            writer.addExpandedPage(self.arena.allocator(), self.job.ns, self.job.title, expanded.source, self.job.source, expanded.display_title) catch |err| {
                std.debug.print(
                    "blob add failed title={s} ordinal={d} ns={d} source_bytes={d} expanded_bytes={d} error={s}\n",
                    .{ self.job.title, self.job.ordinal, self.job.ns.id, self.job.source.len, expanded.source.len, @errorName(err) },
                );
                return err;
            };
            try writer.namespace_coverage.outcome(self.job.ns.id, if (writer.stats.fallback_pages != fallback_before) .fallback else .expanded);
        } else try writer.namespace_coverage.outcome(self.job.ns.id, .duplicate);
        return true;
    }
};

const ExpansionPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    completion: *std.Io.Event,
    slots: []ExpansionSlot,
    page_index_bytes: []const u8 = "",
    page_title_index: ?dump_source.PageTitleIndex = null,
    page_redirects: ?*const encoder.page_redirects.Snapshot = null,

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
        for (self.slots) |*slot| if (try slot.consumeReady(writer)) {
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
        if (std.mem.eql(u8, arg, "--start-page")) {
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
    if (out.expander_root.len == 0) return error.Usage;
    if (out.shard_pages) |shard_pages| {
        if (out.index_byte_offset == null or out.limit_pages == null or out.limit_pages.? == 0 or
            out.start_page % shard_pages != 0) return error.Usage;
    }
    return out;
}

test "blob shard options preserve explicit byte offset and page limit" {
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
    if (!page.has_source or role == null) return;
    if (page.redirect) |xml_target| {
        const index = pool.page_title_index orelse return error.MissingPageTitleIndex;
        const own_ref = (try index.lookup(pool.page_index_bytes, page.title)) orelse return error.InvalidPageTitleIndex;
        if (dump_source.pageRowRefOrdinal(own_ref) != ordinal) {
            try writer.namespace_coverage.outcome(page.ns, .duplicate);
            return;
        }
        var arena = std.heap.ArenaAllocator.init(writer.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const raw_source = try dump.readAlloc(a, page.source);
        const source = if (page.source_needs_decode) try xml_decode.decodeSinglePassAlloc(a, raw_source) else raw_source;
        const redirects = pool.page_redirects orelse return error.PageRedirectSnapshotMissing;
        const target = redirects.lookup(a, page.page_id, xml_target) catch |err| {
            std.debug.print("redirect SQL mismatch: page_id={d} title={s} xml_target={s} error={s}\n", .{ page.page_id, page.title, xml_target, @errorName(err) });
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
        } else {
            const slot = try pool.acquire(writer);
            const retained = slot.arena.allocator();
            var owned = alias;
            owned.target_title = try retained.dupe(u8, alias.target_title);
            owned.target_key = try retained.dupe(u8, alias.target_key);
            owned.fragment = try retained.dupe(u8, alias.fragment);
            slot.dispatch(.{ .ordinal = @intCast(ordinal), .ns = .{ .id = page.ns, .kind = role.? }, .title = page.title, .source = try retained.dupe(u8, tail), .alias_record = owned });
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
    slot.dispatch(.{
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

    fn publish(self: *PendingShard, pool: *ExpansionPool, codes: encoder.blob_builder.LanguageCodes, index_path: []const u8, identity: PageIndexIdentity) !void {
        if (self.selected != self.requested) return error.ShortPageIndex;
        const writer = if (self.writer) |*value| value else return error.WriterFinished;
        try pool.drain(writer);
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
        std.debug.print("continuous shard published start={d} pages={d} main_pages={d} language_records={d} fallback_pages={d}\n", .{
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
            try pending.?.publish(pool, codes, index_path, page_index.identity);
            pending.?.deinit();
            pending = null;
        }
        if (pending == null) {
            const start = options.start_page + selected;
            const requested = @min(shard_pages, total - selected);
            const offset = if (start == 0) 0 else line_offset;
            pending = try PendingShard.init(io, a, output_root, start, requested, offset, codes);
        }
        const shard = &pending.?;
        shard.selected += 1;
        shard.writer.?.stats.pages_seen = shard.selected;
        selected += 1;
        try dispatchIndexedPage(pool, &shard.writer.?, dump, kind, namespaces, line, page_ordinal);
        const progress_now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (selected % 100_000 == 0 or progress_now >= next_progress) {
            next_progress = progress_now + 10 * std.time.ns_per_s;
            std.debug.print("page compilation progress selected={d} ordinal={d} shard_start={d} main_pages={d} language_records={d} workers={d}\n", .{
                selected,                              page_ordinal,   shard.start, shard.writer.?.stats.main_pages,
                shard.writer.?.stats.language_records, pool.slots.len,
            });
        }
    }
    if (selected != total) return error.ShortPageIndex;
    if (pending != null) {
        try pending.?.publish(pool, codes, index_path, page_index.identity);
        pending.?.deinit();
        pending = null;
    }
    if (!std.meta.eql(page_index.identity, try pathIdentity(io, index_path))) return error.PageIndexChanged;
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2|multistream.xml.zst> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--expansion-timeout-ms N] [--now-unix UNIX] [--shard-pages N]\n", .{});
        return error.Usage;
    }
    const options = parseOptions(args) catch {
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2|multistream.xml.zst> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--expansion-timeout-ms N] [--now-unix UNIX] [--shard-pages N]\n", .{});
        return error.Usage;
    };
    const cpu_limit = @min(max_worker_count, std.Thread.getCpuCount() catch 1);
    if (options.workers > @max(@as(usize, 1), cpu_limit)) {
        std.debug.print("refusing {d} expansion workers; safe limit on this host is {d}\n", .{ options.workers, @max(@as(usize, 1), cpu_limit) });
        return error.ResourceLimit;
    }

    var namespaces = try namespace_registry.Registry.load(init.io, a, options.expander_root);
    defer namespaces.deinit();
    var registry = try loadLanguageRegistry(init.io, a, options.expander_root, &namespaces);
    defer registry.deinit();
    const codes = languageCodes(&registry, &namespaces);

    const page_index_path = try std.fs.path.join(a, &.{ options.expander_root, "page-index.tsv" });
    defer a.free(page_index_path);
    var page_index = try mmapPath(init.io, page_index_path);
    defer page_index.deinit();
    const page_index_kind = dump_source.pageIndexKind(page_index.bytes);
    const page_title_index_path = try std.fs.path.join(a, &.{ options.expander_root, dump_source.page_title_index_filename });
    defer a.free(page_title_index_path);
    var page_title_index = try mmapPath(init.io, page_title_index_path);
    defer page_title_index.deinit();
    const title_index = try dump_source.PageTitleIndex.init(page_title_index.bytes);
    if (title_index.page_index_size != page_index.bytes.len or title_index.kind != page_index_kind) return error.PageTitleIndexMismatch;
    const redirects_path = try std.fs.path.join(a, &.{ options.expander_root, "page-redirects.tsv" });
    defer a.free(redirects_path);
    var redirects_storage: ?Mapped = mmapPath(init.io, redirects_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (redirects_storage) |*mapped| mapped.deinit();
    var redirects: ?encoder.page_redirects.Snapshot = if (redirects_storage) |mapped| try encoder.page_redirects.Snapshot.init(a, mapped.bytes, &namespaces) else null;
    defer if (redirects) |*snapshot| snapshot.deinit();
    const stream_index_path = try std.fs.path.join(a, &.{ options.expander_root, "dump-streams.tsv" });
    defer a.free(stream_index_path);
    var dump = try dump_source.SourceReader.open(
        init.io,
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
    var pool = try ExpansionPool.init(init.io, a, options.expander_root, worker_path, args[1], options.workers, options.now_unix, options.expansion_timeout_ms orelse expansion_deadline.default_ms);
    defer pool.deinit();
    pool.page_index_bytes = page_index.bytes;
    pool.page_title_index = title_index;
    pool.page_redirects = if (redirects) |*snapshot| snapshot else null;
    if (options.shard_pages != null) {
        try runContinuous(init.io, a, args[2], options, codes, &namespaces, &pool, &dump, &page_index, page_index_kind, page_index_path);
        return;
    }

    var writer = try encoder.blob_builder.Writer.init(init.io, a, args[2]);
    defer writer.deinit();
    writer.language_codes = codes;
    const index_start = try pageIndexStart(page_index.bytes, options);
    var lines = std.mem.splitScalar(u8, index_start.bytes, '\n');
    var corpus_ordinal: usize = index_start.ordinal;
    var pages_selected: usize = 0;
    var next_progress = std.Io.Clock.awake.now(init.io).toNanoseconds() + 10 * std.time.ns_per_s;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const page_ordinal = corpus_ordinal;
        corpus_ordinal += 1;
        if (page_ordinal < options.start_page) continue;
        if (options.limit_pages) |limit| if (pages_selected >= limit) break;
        pages_selected += 1;
        writer.stats.pages_seen = pages_selected;
        try dispatchIndexedPage(&pool, &writer, &dump, page_index_kind, &namespaces, line, page_ordinal);
        const progress_now = std.Io.Clock.awake.now(init.io).toNanoseconds();
        if (pages_selected % 100_000 == 0 or progress_now >= next_progress) {
            next_progress = progress_now + 10 * std.time.ns_per_s;
            std.debug.print(
                "page compilation progress selected={d} ordinal={d} main_pages={d} language_records={d} workers={d}\n",
                .{ pages_selected, page_ordinal, writer.stats.main_pages, writer.stats.language_records, pool.slots.len },
            );
        }
    }
    try pool.drain(&writer);
    const coverage = try pageCoverage(options, pages_selected, page_index.identity);
    const stats = try writer.finish(codes);
    if (stats.pages_seen != coverage.pages_seen) return error.PageCoverageMismatch;
    if (!std.meta.eql(page_index.identity, try pathIdentity(init.io, page_index_path))) {
        return error.PageIndexChanged;
    }
    try writePageCoverage(init.io, a, args[2], coverage);

    std.debug.print(
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
