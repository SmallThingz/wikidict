//! Build-only native Lua/template expansion worker. This binary is never shipped.
const std = @import("std");
const lua_program = @import("lua_program");
const llvm_abi = @import("lua_llvm_abi");
comptime {
    _ = llvm_abi;
}
const pages = @import("bundle_pages.zig");
const protocol = @import("bundle_protocol.zig");
const RequestAllocator = @import("runtime/request_allocator.zig").RequestAllocator;
const InvokeReuseStats = lua_program.InvokeReuseStats;
const work_stats = lua_program.work_stats;
const A = std.mem.Allocator;
const L = std.os.linux;
const expansion_memory_headroom_bytes: u64 = 512 * 1024 * 1024;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn expansionProfileEnabled() !bool {
    const raw = getenv("WIKIDICT_EXPANSION_PROFILE") orelse return false;
    return work_stats.profileEnabledFromEnv(std.mem.span(raw));
}

pub const Request = protocol.Request;

const Expansion = struct {
    output: []const u8,
    display_title: []const u8,
};

fn limit(resource: std.posix.rlimit_resource, value: u64) !void {
    const old = try std.posix.getrlimit(resource);
    const n = @min(value, old.max);
    try std.posix.setrlimit(resource, .{ .cur = @intCast(n), .max = @intCast(n) });
}

fn currentVirtualBytes(io: std.Io) !u64 {
    var file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const marker = "VmSize:";
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (!std.mem.startsWith(u8, line, marker)) continue;
        var fields = std.mem.tokenizeAny(u8, line[marker.len..], " \t");
        const kib = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcStatus, 10);
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidProcStatus, "kB") or fields.next() != null)
            return error.InvalidProcStatus;
        return std.math.mul(u64, kib, 1024) catch return error.AddressSpaceOverflow;
    }
    return error.MissingProcVmSize;
}

fn limitAddressSpaceAfterAssets(io: std.Io, headroom: u64) !void {
    const used = try currentVirtualBytes(io);
    const desired = std.math.add(u64, used, headroom) catch std.math.maxInt(u64);
    const old = try std.posix.getrlimit(.AS);
    const n = @min(desired, old.cur);
    if (n == old.cur) return;
    try std.posix.setrlimit(.AS, .{ .cur = @intCast(n), .max = old.max });
}

const Engine = struct {
    io: std.Io,
    requested_root: []const u8,
    requested_dump: []const u8,
    requested_now_unix: i64,
    program: lua_program.Program,
    provider: pages.Provider,
    load_data_cache: lua_program.SharedLoadDataCache,
    profile_enabled: bool,
    root_profile: ?work_stats.RootProfile = null,
    invoke_reuse: ?InvokeReuseStats = null,
    native_failures: work_stats.NativeFailures = .{},
    missing_data_requests: work_stats.MissingDataRequests = .{},
    measured_pages: u64 = 0,
    sampled_pages: u64 = 0,
    invoke_histogram: [5]u64 = .{ 0, 0, 0, 0, 0 },
    cache_hit_histogram: [4]u64 = .{ 0, 0, 0, 0 },
    totals: work_stats.Page = .{},

    fn record(self: *Engine, page: *const work_stats.Page) void {
        if (!self.profile_enabled) return;
        const bucket: usize = if (page.invokes == 0) 0 else if (page.invokes == 1) 1 else if (page.invokes < 4) 2 else if (page.invokes < 8) 3 else 4;
        self.invoke_histogram[bucket] +|= 1;
        const hits = self.load_data_cache.hits -| page.cache_hits_before;
        const hit_bucket: usize = if (hits == 0) 0 else if (hits == 1) 1 else if (hits < 4) 2 else 3;
        self.cache_hit_histogram[hit_bucket] +|= 1;
        if (page.sampled) self.sampled_pages +|= 1;
        if (page.root_sampled) {
            if (self.root_profile) |*profile| profile.sampled_pages +|= 1;
        }
        inline for (.{ "invokes", "invoke_attempts", "module_roots", "static_roots", "scan_calls", "scan_bytes", "constructs", "comment_bytes", "template_preprocess_calls", "template_preprocess_bytes", "context_ns", "expand_ns", "comments_ns", "template_preprocess_ns", "invoke_ns", "root_exclusive_ns" }) |field| {
            @field(self.totals, field) +|= @field(page.*, field);
        }
    }

    fn fileExists(io: std.Io, path: []const u8) !bool {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(io);
        return true;
    }

    fn init(io: std.Io, a: A, requested_root: []const u8, requested_dump: []const u8, requested_now_unix: i64, profile_enabled: bool) !Engine {
        const marker = try std.fs.path.join(a, &.{ requested_root, ".incomplete" });
        if (try fileExists(io, marker)) return error.BundleAssetsIncomplete;
        const manifest = try std.fs.path.join(a, &.{ requested_root, "manifest.jsonl" });
        if (!try fileExists(io, manifest)) return error.BundleAssetsMissing;
        var program = try lua_program.Program.init(io, a, requested_root);
        errdefer program.deinit();
        var provider = try pages.Provider.init(io, a, requested_root, requested_dump);
        errdefer provider.deinit();
        var load_data_cache = lua_program.SharedLoadDataCache.init(
            std.heap.smp_allocator,
            lua_program.loadDataCacheability(&program),
        );
        errdefer load_data_cache.deinit();
        var root_profile: ?work_stats.RootProfile = if (profile_enabled)
            try work_stats.RootProfile.init(std.heap.smp_allocator, program.module_count)
        else
            null;
        errdefer if (root_profile) |*profile| profile.deinit();
        return .{
            .io = io,
            .requested_root = try a.dupe(u8, requested_root),
            .requested_dump = try a.dupe(u8, requested_dump),
            .requested_now_unix = requested_now_unix,
            .program = program,
            .provider = provider,
            .load_data_cache = load_data_cache,
            .profile_enabled = profile_enabled,
            .root_profile = root_profile,
            .invoke_reuse = if (profile_enabled) InvokeReuseStats.init(std.heap.smp_allocator) else null,
        };
    }

    fn deinit(self: *Engine) void {
        if (self.profile_enabled) {
            work_stats.logLine("worker work: pages={d} samples={d} invokes={d} attempts={d} roots={d} static_roots={d} scan_calls={d} scan_bytes={d} constructs={d} comments_bytes={d} template_preprocess_calls={d} template_preprocess_bytes={d}\n", .{
                self.measured_pages, self.sampled_pages, self.totals.invokes, self.totals.invoke_attempts, self.totals.module_roots, self.totals.static_roots, self.totals.scan_calls, self.totals.scan_bytes, self.totals.constructs, self.totals.comment_bytes, self.totals.template_preprocess_calls, self.totals.template_preprocess_bytes,
            });
            work_stats.logLine("worker invoke histogram: zero={d} one={d} two_three={d} four_seven={d} eight_plus={d}\n", .{
                self.invoke_histogram[0], self.invoke_histogram[1], self.invoke_histogram[2], self.invoke_histogram[3], self.invoke_histogram[4],
            });
            work_stats.logLine("worker cache hit histogram: zero={d} one={d} two_three={d} four_plus={d}\n", .{
                self.cache_hit_histogram[0], self.cache_hit_histogram[1], self.cache_hit_histogram[2], self.cache_hit_histogram[3],
            });
            work_stats.logLine("worker sampled cpu ns: interval=32 context={d} expand={d} comments={d} template_preprocess={d} invoke_inclusive={d}\n", .{
                self.totals.context_ns, self.totals.expand_ns, self.totals.comments_ns, self.totals.template_preprocess_ns, self.totals.invoke_ns,
            });
            if (self.root_profile) |*profile| profile.logTop(self.program.module_names, self.totals.root_exclusive_ns);
            if (self.invoke_reuse) |*stats| stats.log();
        }
        if (self.invoke_reuse) |*stats| stats.deinit();
        self.native_failures.log();
        self.missing_data_requests.log();
        self.load_data_cache.logDiagnostics(self.program.module_names);
        if (self.root_profile) |*profile| profile.deinit();
        self.load_data_cache.deinit();
        self.provider.deinit();
        self.program.deinit();
    }

    fn expand(self: *Engine, page_a: A, request: Request, stage: *[]const u8, detail: *?[]const u8) !?Expansion {
        if (!std.mem.eql(u8, request.root, self.requested_root)) return error.BundleRootChanged;
        if (!std.mem.eql(u8, request.dump, self.requested_dump)) return error.BundleDumpChanged;
        if (request.now_unix != self.requested_now_unix) return error.BundleTimeChanged;
        if (!self.provider.isCanonicalPage(request.title, request.page_ordinal)) return null;
        var page_work = work_stats.Page{
            .sampled = self.profile_enabled and (self.measured_pages & 31) == 0,
            .root_sampled = self.profile_enabled and (self.measured_pages & 31) == 0,
            .root_profile = if (self.root_profile) |*profile| profile else null,
            .native_failures = &self.native_failures,
            .missing_data_requests = &self.missing_data_requests,
            .cache_hits_before = self.load_data_cache.hits,
        };
        self.measured_pages +|= 1;
        const previous_work = work_stats.begin(&page_work);
        defer work_stats.end(previous_work);
        defer self.record(&page_work);
        stage.* = "install";
        const context_start = work_stats.cpuNow();
        var ctx = try self.program.initPageContext(page_a);
        page_work.context_ns +|= work_stats.elapsed(context_start);
        defer ctx.deinit();
        var expander = lua_program.initExpanderShared(&ctx, self.provider.api(), &self.load_data_cache);
        expander.invoke_reuse = if (self.invoke_reuse) |*stats| stats else null;
        stage.* = "expand";
        const expand_start = work_stats.cpuNow();
        const output = expander.expandFragment(request.title, request.source, self.requested_now_unix) catch |err| {
            page_work.expand_ns +|= work_stats.elapsed(expand_start);
            detail.* = try page_a.dupe(u8, if (ctx.last_error == .string)
                ctx.last_error.string
            else
                ctx.aotErrorName() orelse @errorName(err));
            return err;
        };
        page_work.expand_ns +|= work_stats.elapsed(expand_start);
        return .{ .output = output, .display_title = expander.display_title orelse "" };
    }
};

pub fn run(io: std.Io, persistent: A) !void {
    const profile_enabled = try expansionProfileEnabled();
    const worker_cpu_start = work_stats.processCpuNow();
    defer {
        if (worker_cpu_start) |start| {
            if (work_stats.processCpuNow()) |stop| {
                work_stats.logLine("worker process cpu ns: total={d}\n", .{stop -| start});
            }
        }
    }
    try limit(.CORE, 0);
    if (L.errno(L.prctl(@intFromEnum(L.PR.SET_PDEATHSIG), @intFromEnum(L.SIG.KILL), 0, 0, 0)) != .SUCCESS) return error.ParentDeathSignalFailed;
    if (L.getppid() == 1) return error.ParentExited;
    var engine: ?Engine = null;
    defer if (engine) |*value| value.deinit();
    var in_buf: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &out_buf);
    while (true) {
        var raw_length: [4]u8 = undefined;
        input.interface.readSliceAll(&raw_length) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const length = std.mem.readInt(u32, &raw_length, .little);
        if (length == 0 or length > protocol.max_frame_bytes) return error.InvalidFrame;
        var page = RequestAllocator.init(std.heap.smp_allocator);
        defer page.deinit();
        const page_a = page.allocator();
        const bytes = try page_a.alloc(u8, length);
        try input.interface.readSliceAll(bytes);
        const request = protocol.decodeRequest(bytes) catch |err| {
            try protocol.writeError(&output.interface, "request", @errorName(err), "");
            continue;
        };
        if (engine == null) {
            engine = Engine.init(io, persistent, request.root, request.dump, request.now_unix, profile_enabled) catch |err| {
                try protocol.writeError(&output.interface, "assets", @errorName(err), "");
                continue;
            };
            // Generated code and the corpus index are trusted build assets and can
            // legitimately occupy several GiB of virtual address space. Cap only
            // additional expansion growth after those assets are resident.
            limitAddressSpaceAfterAssets(io, expansion_memory_headroom_bytes) catch |err| {
                engine.?.deinit();
                engine = null;
                try protocol.writeError(&output.interface, "assets", @errorName(err), "");
                continue;
            };
        }
        var stage: []const u8 = "expand";
        var detail: ?[]const u8 = null;
        const expanded = engine.?.expand(page_a, request, &stage, &detail) catch |err| {
            try protocol.writeError(&output.interface, stage, @errorName(err), detail orelse "");
            continue;
        };
        if (expanded) |value| {
            if (value.output.len > protocol.max_source_bytes or value.display_title.len > protocol.max_display_title_bytes) {
                try protocol.writeError(&output.interface, stage, "ExpandedSourceTooLarge", "");
                continue;
            }
            try protocol.writeSuccess(&output.interface, value.output, value.display_title);
        } else {
            try protocol.writeSkip(&output.interface);
        }
    }
}

pub export fn dict_bundle_expander_main() callconv(.c) u8 {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var persistent = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer persistent.deinit();
    run(threaded.io(), persistent.allocator()) catch return 1;
    return 0;
}
