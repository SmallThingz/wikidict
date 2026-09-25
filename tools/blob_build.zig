const std = @import("std");
const encoder = @import("encoder");
const xml_decode = @import("xml_decode");
const dump_source = @import("wikimedia_dump");
const language_registry = @import("language_registry.zig");
const bundle_expander = @import("bundle_expander.zig");
const max_worker_count: usize = 8;

const Options = struct {
    start_page: usize = 0,
    index_byte_offset: ?usize = null,
    limit_pages: ?usize = null,
    expander_root: []const u8 = "",
    workers: usize = 1,
    now_unix: ?i64 = null,
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

fn loadLanguageRegistry(io: std.Io, a: std.mem.Allocator, expander_root: []const u8) !language_registry.Registry {
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
    const title_marker = "\"title\":\"Module:languages/canonical names\"";
    const marker = std.mem.indexOf(u8, manifest.bytes, title_marker) orelse return out;
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
    try out.addLua(source);
    return out;
}

const ExpansionJob = struct {
    ordinal: u64,
    ns: u32,
    title: []const u8,
    source: []const u8,
};

fn expansionFallbackReasonAlloc(a: std.mem.Allocator, err: anyerror, failure: ?bundle_expander.Failure) !?[]const u8 {
    switch (err) {
        error.ExpansionFailed, error.Timeout, error.RequestTooLarge => {},
        else => return null,
    }
    const precise = if (err == error.ExpansionFailed) failure else null;
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
                .{ self.job.title, self.job.ordinal, self.job.ns, self.job.source.len, @errorName(err) },
            );
            const fallback_reason = (try expansionFallbackReasonAlloc(self.arena.allocator(), err, self.worker.last_failure)) orelse return err;
            // Ordinary Scribunto failures are already rendered inside the page
            // expander. This outer path is operational failure: retain the page
            // as empty semantic data and keep the exact cause in the audit report.
            try writer.addExpansionFailure(self.arena.allocator(), self.job.ns, self.job.title, &.{fallback_reason});
            return true;
        }
        if (self.expansion) |expanded| {
            writer.addExpandedPage(self.arena.allocator(), self.job.ns, self.job.title, expanded.source, self.job.source, expanded.display_title) catch |err| {
                std.debug.print(
                    "blob add failed title={s} ordinal={d} ns={d} source_bytes={d} expanded_bytes={d} error={s}\n",
                    .{ self.job.title, self.job.ordinal, self.job.ns, self.job.source.len, expanded.source.len, @errorName(err) },
                );
                return err;
            };
        }
        return true;
    }
};

const ExpansionPool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    completion: *std.Io.Event,
    slots: []ExpansionSlot,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
        executable: []const u8,
        dump: []const u8,
        count: usize,
        now_unix: ?i64,
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
            allocator.destroy(completion);
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
        } else if (std.mem.eql(u8, arg, "--workers")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            out.workers = try std.fmt.parseInt(usize, args[index], 10);
            if (out.workers == 0 or out.workers > max_worker_count) return error.Usage;
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

pub fn main(init: std.process.Init) !void {
    const a = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--now-unix UNIX]\n", .{});
        return error.Usage;
    }
    const options = parseOptions(args) catch {
        std.debug.print("usage: dict-blob-build <wiktionary.xml|multistream.xml.bz2> <output-root> --expander-root ROOT [--start-page N] [--index-byte-offset N] [--limit-pages N] [--workers N] [--now-unix UNIX]\n", .{});
        return error.Usage;
    };
    const cpu_limit = @min(max_worker_count, std.Thread.getCpuCount() catch 1);
    if (options.workers > @max(@as(usize, 1), cpu_limit)) {
        std.debug.print("refusing {d} expansion workers; safe limit on this host is {d}\n", .{ options.workers, @max(@as(usize, 1), cpu_limit) });
        return error.ResourceLimit;
    }

    var registry = try loadLanguageRegistry(init.io, a, options.expander_root);
    defer registry.deinit();
    const codes: encoder.blob_builder.LanguageCodes = .{
        .ctx = &registry,
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
            .ctx = &registry,
            .end_fn = struct {
                fn end(raw: ?*const anyopaque, input: []const u8, start: usize) usize {
                    const value: *const @import("language_registry.zig").Registry = @ptrCast(@alignCast(raw orelse return start));
                    return value.linkTrailEnd(input, start);
                }
            }.end,
        },
    };

    const worker_path = try std.fs.path.join(a, &.{ options.expander_root, "dict-bundle-expander" });
    defer a.free(worker_path);
    var pool = try ExpansionPool.init(init.io, a, options.expander_root, worker_path, args[1], options.workers, options.now_unix);
    defer pool.deinit();

    var writer = try encoder.blob_builder.Writer.init(init.io, a, args[2]);
    defer writer.deinit();
    writer.language_codes = codes;
    const page_index_path = try std.fs.path.join(a, &.{ options.expander_root, "page-index.tsv" });
    defer a.free(page_index_path);
    var page_index = try mmapPath(init.io, page_index_path);
    defer page_index.deinit();
    const page_index_kind = dump_source.pageIndexKind(page_index.bytes);
    const stream_index_path = try std.fs.path.join(a, &.{ options.expander_root, "dump-streams.tsv" });
    defer a.free(stream_index_path);
    var dump = try dump_source.SourceReader.open(
        init.io,
        a,
        a,
        args[1],
        page_index_kind,
        if (page_index_kind == .multistream_bz2) stream_index_path else null,
    );
    defer dump.deinit();

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
        const page = try dump_source.parsePageIndexLine(page_index_kind, line);
        if (page.has_source and dump_source.relevantNamespace(page.ns)) {
            const slot = try pool.acquire(&writer);
            const page_allocator = slot.arena.allocator();
            const raw_source = try dump.readAlloc(page_allocator, page.source);
            const source = if (page.source_needs_decode)
                try xml_decode.decodeSinglePassAlloc(page_allocator, raw_source)
            else
                raw_source;
            slot.dispatch(.{
                .ordinal = @intCast(page_ordinal),
                .ns = page.ns,
                .title = page.title,
                .source = source,
            });
        }
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
        "pages={d} main_pages={d} language_records={d} language_blobs={d} thesaurus={d} citations={d} reconstruction={d} rhymes={d} sign_gloss={d} fallback_pages={d}\n",
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
            stats.fallback_pages,
        },
    );
}
