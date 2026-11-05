const std = @import("std");
const diagnostics = @import("build_diagnostics");
const A = std.mem.Allocator;
const L = std.os.linux;
const protocol = @import("bundle_protocol");
const expansion_deadline = @import("expansion_deadline.zig");
extern "c" fn clock_getcpuclockid(pid: std.posix.pid_t, clock_id: *L.clockid_t) c_int;

// One page owns one CPU allowance across worker generations. Startup is not
// page work; completed replies carry a stamp so exited workers remain auditable.
const PageCpuBudget = struct {
    remaining_ns: u64,
    last_cpu_ns: ?u64 = null,
    live_cpu_highwater: ?u64 = null,

    fn begin(self: *PageCpuBudget, stamp: u64) !void {
        if (self.remaining_ns == 0) return error.Timeout;
        if (self.last_cpu_ns != null) return error.InvalidResponse;
        self.last_cpu_ns = stamp;
        self.live_cpu_highwater = stamp;
    }

    fn observe(self: *PageCpuBudget, stamp: u64) !void {
        const previous = self.last_cpu_ns orelse return error.InvalidResponse;
        if (stamp < previous) return error.InvalidResponse;
        const used = stamp - previous;
        self.last_cpu_ns = stamp;
        if (used >= self.remaining_ns) {
            self.remaining_ns = 0;
            return error.Timeout;
        }
        self.remaining_ns -= used;
    }

    fn check(self: *PageCpuBudget, stamp: u64) !void {
        const baseline = self.last_cpu_ns orelse return error.InvalidResponse;
        if (stamp < baseline or stamp < (self.live_cpu_highwater orelse baseline)) return error.InvalidResponse;
        self.live_cpu_highwater = stamp;
        if (stamp - baseline >= self.remaining_ns) return error.Timeout;
    }

    fn newGeneration(self: *PageCpuBudget) void {
        self.last_cpu_ns = null;
        self.live_cpu_highwater = null;
    }
};

// Available pipe bytes take priority over a process clock: an exited worker
// can leave a complete stamped reply queued. On an idle poll, unavailable CPU
// accounting is a fatal operational error, never an unlimited allowance.
fn checkPollCpu(budget: *PageCpuBudget, readable: bool, source: anytype) !void {
    if (!readable and budget.last_cpu_ns != null) try budget.check(try source.processCpuNow());
}

// A worker can queue its final frame and exit between an idle poll and the
// clock lookup. One zero-time repoll preserves that frame without permitting
// an unbounded wait. Proven quota expiry, regression and unavailable clocks
// remain fatal even if bytes subsequently become readable.
fn afterIdlePoll(budget: *PageCpuBudget, source: anytype, pipe: anytype) !bool {
    checkPollCpu(budget, false, source) catch |err| {
        if (err == error.WorkerClosed and try pipe.readyNow()) return true;
        return err;
    };
    return false;
}

pub const Expansion = struct {
    source: []const u8,
    display_title: ?[]const u8 = null,
    unsupported_parser_function: bool = false,
    poem_metadata: ?[]const u8 = null,
    missing_dependency_metadata: ?[]const u8 = null,
};

pub const Failure = protocol.ErrorReply;
pub const PageIdentity = protocol.PageIdentity;

// Transporting an error must not turn resource exhaustion into a semantic
// fallback. Keep this shared with the blob writer's defensive classification.
pub fn operationalFailure(failure: Failure) ?anyerror {
    if (std.mem.eql(u8, failure.error_name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, failure.error_name, "Timeout")) return error.Timeout;
    // Asset loading, protocol validation and bootstrap are compiler operations,
    // not per-page MediaWiki semantics. Never publish empty pages for them.
    if (!std.mem.eql(u8, failure.stage, "expand")) return error.BundleInfrastructureFailed;
    // An uncaptured pair is missing build input, not an upstream M or V-empty result.
    if (std.mem.eql(u8, failure.error_name, "InterfaceMessageSnapshotMissing")) return error.InterfaceMessageSnapshotMissing;
    inline for (&.{ "BundleRootChanged", "BundleDumpChanged", "BundleTimeChanged", "InvalidPageIndex", "InvalidPageTitleIndex", "NamespaceTitleCollision", "NamespaceTitleMismatch", "InvalidNamespace", "UnsupportedStoredInterwikiNamespace", "UnsupportedStoredLocalInterwiki", "InvalidStoredRedirectTarget", "PageIndexChanged", "InvalidProgramMetadata", "InvalidPoemMetadata", "MissingPoemMetadata", "OrphanPoemMarker", "FrameTooLarge" }) |name|
        if (std.mem.eql(u8, failure.error_name, name)) return error.BundleInfrastructureFailed;
    return null;
}

fn validateReplyPhase(reply: protocol.Reply, awaiting_ready: bool) !void {
    if (!awaiting_ready) {
        if (reply == .ready) return error.InvalidResponse;
        return;
    }
    switch (reply) {
        .ready => {},
        .failure => |failure| {
            if (!std.mem.eql(u8, failure.stage, "assets") and !std.mem.eql(u8, failure.stage, "request")) return error.InvalidResponse;
        },
        .output, .skip => return error.InvalidResponse,
    }
}

pub const Worker = struct {
    io: std.Io,
    root: []const u8,
    executable: []const u8,
    dump: []const u8,
    now_unix: i64,
    timeout_ms: u32 = expansion_deadline.default_ms,
    // Response bound includes spawn/send elapsed if blocking transmission returns;
    // a pipe stuck in writeRequest remains bounded by the outer watchdog.
    startup_timeout_ms: u32 = 900_000,
    ready_received: bool = false,
    child: ?std.process.Child = null,
    last_failure: ?Failure = null,
    generation: u64 = 0,
    oom_retry_attempts: u64 = 0,
    oom_retry_recovered: u64 = 0,
    oom_retry_failed: u64 = 0,

    pub fn init(io: std.Io, root: []const u8, executable: []const u8, dump: []const u8) Worker {
        return .{
            .io = io,
            .root = root,
            .executable = executable,
            .dump = dump,
            .now_unix = std.Io.Clock.real.now(io).toSeconds(),
        };
    }

    pub fn deinit(self: *Worker) void {
        if (self.oom_retry_attempts != 0) diagnostics.printLine("bundle OOM recovery totals attempted={d} recovered={d} failed={d}\n", .{
            self.oom_retry_attempts, self.oom_retry_recovered, self.oom_retry_failed,
        });
        if (self.child) |*child| {
            // Normal EOF lets the worker print its bounded shutdown counters.
            // A stuck child is still reaped after the deadline below.
            if (child.stdin) |stdin| {
                stdin.close(self.io);
                child.stdin = null;
            }
            if (child.id) |pid| {
                const raw_fd = L.pidfd_open(pid, 0);
                if (L.errno(raw_fd) == .SUCCESS) {
                    const pidfd: std.posix.fd_t = @intCast(raw_fd);
                    defer _ = L.close(pidfd);
                    var fds = [_]std.posix.pollfd{.{ .fd = pidfd, .events = std.posix.POLL.IN, .revents = 0 }};
                    const ready = std.posix.poll(&fds, 5_000) catch 0;
                    if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
                        _ = child.wait(self.io) catch {
                            child.kill(self.io);
                            self.child = null;
                            return;
                        };
                        self.child = null;
                        return;
                    }
                }
            }
            child.kill(self.io);
        }
        self.child = null;
    }

    fn reset(self: *Worker) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
        self.ready_received = false;
    }

    fn reportClosed(self: *Worker, ordinal: u64, title: []const u8) void {
        const child = if (self.child) |*value| value else return;
        const pid = child.id orelse return;
        const raw_fd = L.pidfd_open(pid, 0);
        if (L.errno(raw_fd) == .SUCCESS) {
            const fd: std.posix.fd_t = @intCast(raw_fd);
            defer _ = L.close(fd);
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch 0;
            if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
                const term = child.wait(self.io) catch |err| {
                    diagnostics.printLine("bundle worker closed pid={d} ordinal={d} title={s} wait_error={s}\n", .{ pid, ordinal, title, @errorName(err) });
                    return;
                };
                diagnostics.printLine("bundle worker closed pid={d} ordinal={d} title={s} termination={any}\n", .{ pid, ordinal, title, term });
                self.child = null;
                return;
            }
        }
        // EOF can precede process exit or be an explicit stdout close. Do not
        // block indefinitely waiting for a worker whose pipe has disappeared.
        diagnostics.printLine("bundle worker closed pid={d} ordinal={d} title={s} termination=not-ready\n", .{ pid, ordinal, title });
    }

    fn ensure(self: *Worker) !*std.process.Child {
        if (self.child == null) {
            self.child = try std.process.spawn(self.io, .{
                .argv = &.{self.executable},
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
            self.ready_received = false;
            self.generation +|= 1;
        }
        return &self.child.?;
    }

    fn processCpuNow(self: *Worker) !u64 {
        const child = if (self.child) |*value| value else return error.WorkerClosed;
        const pid = child.id orelse return error.WorkerClosed;
        var clock_id: L.clockid_t = undefined;
        const rc = clock_getcpuclockid(pid, &clock_id);
        if (rc != 0) return if (rc == @intFromEnum(L.E.SRCH)) error.WorkerClosed else error.WorkerCpuClockUnavailable;
        var ts: L.timespec = undefined;
        switch (L.errno(L.clock_gettime(clock_id, &ts))) {
            .SUCCESS => {},
            .SRCH => return error.WorkerClosed,
            .INVAL => {
                // A valid process clock can disappear between clock lookup
                // and sampling. Only confirmed owned-child exit permits the
                // queued-reply recovery; unsupported clocks remain fatal.
                const raw_fd = L.pidfd_open(pid, 0);
                if (L.errno(raw_fd) == .SUCCESS) {
                    const fd: std.posix.fd_t = @intCast(raw_fd);
                    defer _ = L.close(fd);
                    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                    const ready = std.posix.poll(&fds, 0) catch return error.WorkerCpuClockUnavailable;
                    if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) return error.WorkerClosed;
                }
                return error.WorkerCpuClockUnavailable;
            },
            else => return error.WorkerCpuClockUnavailable,
        }
        if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= std.time.ns_per_s) return error.WorkerCpuClockUnavailable;
        return std.math.cast(u64, @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec) orelse error.WorkerCpuClockUnavailable;
    }

    fn readExact(self: *Worker, file: std.Io.File, out: []u8, startup_deadline: i128, budget: *PageCpuBudget) !void {
        var pos: usize = 0;
        while (pos < out.len) {
            const remaining = if (budget.last_cpu_ns == null)
                startup_deadline - std.Io.Clock.awake.now(self.io).toNanoseconds()
            else
                100 * std.time.ns_per_ms;
            if (remaining <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const wait_ms: i32 = @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, 100));
            if (try std.posix.poll(&fds, wait_ms) == 0) {
                const ReadyPipe = struct {
                    fds: *[1]std.posix.pollfd,
                    fn readyNow(pipe: @This()) !bool {
                        pipe.fds[0].revents = 0;
                        return try std.posix.poll(pipe.fds, 0) != 0;
                    }
                };
                if (!try afterIdlePoll(budget, self, ReadyPipe{ .fds = &fds })) continue;
            }
            try checkPollCpu(budget, true, self);
            // Drain readable bytes before querying a possibly exited child.
            // A complete queued OOM reply provides its own final CPU stamp.
            const rc = L.read(file.handle, out.ptr + pos, out.len - pos);
            switch (L.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.WorkerClosed;
                    pos += rc;
                },
                .INTR, .AGAIN => continue,
                else => return error.WorkerClosed,
            }
        }
    }

    fn writeRequest(self: *Worker, child: *std.process.Child, page_ordinal: u64, identity: PageIdentity, title: []const u8, source: []const u8) !void {
        var buffer: [8192]u8 = undefined;
        var writer = child.stdin.?.writer(self.io, &buffer);
        try protocol.writeRequest(&writer.interface, .{
            .root = self.root,
            .dump = self.dump,
            .now_unix = self.now_unix,
            .page_ordinal = page_ordinal,
            .identity = identity,
            .title = title,
            .source = source,
        });
    }

    pub fn expand(self: *Worker, a: A, page_ordinal: u64, identity: PageIdentity, title: []const u8, source: []const u8) !?Expansion {
        self.last_failure = null;
        if (source.len > protocol.max_source_bytes) return error.RequestTooLarge;
        // Both attempts share the page budget; each new generation has a
        // separately bounded startup response. Blocking request transmission
        // still requires the outer watchdog for a stuck/non-reading child.
        var budget: PageCpuBudget = .{ .remaining_ns = @as(u64, self.timeout_ms) * std.time.ns_per_ms };
        var remote_oom = false;
        return self.expandOnce(a, page_ordinal, identity, title, source, &budget, &remote_oom) catch |err| {
            if (!remote_oom) return err;
            // Only a fully decoded remote OOM reaches here. Local allocator,
            // transport, semantic and deadline failures never authorize replay.
            const retired_generation = self.generation;
            self.oom_retry_attempts +|= 1;
            diagnostics.printLine("bundle OOM recovery start ordinal={d} retired_generation={d} source_bytes={d} now_unix={d}\n", .{
                page_ordinal, retired_generation, source.len, self.now_unix,
            });
            self.last_failure = null;
            remote_oom = false;
            const recovered = self.expandOnce(a, page_ordinal, identity, title, source, &budget, &remote_oom) catch |cold_err| {
                self.reset();
                self.oom_retry_failed +|= 1;
                diagnostics.printLine("bundle OOM recovery failed ordinal={d} generation={d} error={s}\n", .{ page_ordinal, self.generation, @errorName(cold_err) });
                if (cold_err == error.InterfaceMessageSnapshotMissing) return cold_err;
                return if (remote_oom and cold_err == error.OutOfMemory) error.OutOfMemory else error.ColdRetryFailed;
            };
            if (recovered) |output| {
                self.last_failure = null;
                self.oom_retry_recovered +|= 1;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(output.source, &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                diagnostics.printLine("bundle OOM recovery success ordinal={d} generation={d} output_bytes={d} output_sha256={s}\n", .{
                    page_ordinal, self.generation, output.source.len, hex,
                });
                return output;
            }
            self.reset();
            self.oom_retry_failed +|= 1;
            diagnostics.printLine("bundle OOM recovery failed ordinal={d} generation={d} error=UnexpectedSkip\n", .{ page_ordinal, self.generation });
            return error.ColdRetryFailed;
        };
    }

    fn expandOnce(self: *Worker, a: A, page_ordinal: u64, identity: PageIdentity, title: []const u8, source: []const u8, budget: *PageCpuBudget, remote_oom: *bool) !?Expansion {
        if (budget.remaining_ns == 0) return error.Timeout;
        const start = std.Io.Clock.awake.now(self.io).toNanoseconds();
        budget.newGeneration();
        if (self.child != null and self.ready_received) {
            const baseline = self.processCpuNow() catch |err| {
                self.reset();
                return err;
            };
            try budget.begin(baseline);
        }
        const startup_deadline = start + @as(i128, self.startup_timeout_ms) * std.time.ns_per_ms;
        const child = try self.ensure();
        self.writeRequest(child, page_ordinal, identity, title, source) catch |err| {
            self.reset();
            return err;
        };
        while (true) {
            var raw_length: [4]u8 = undefined;
            self.readExact(child.stdout.?, &raw_length, startup_deadline, budget) catch |err| {
                if (err == error.WorkerClosed) self.reportClosed(page_ordinal, title);
                if (err == error.Timeout) diagnostics.printLine(
                    "bundle {s} timed out title={s} ordinal={d} source_bytes={d} timeout_ms={d}\n",
                    .{ if (self.ready_received) "expansion" else "startup", title, page_ordinal, source.len, if (self.ready_received) self.timeout_ms else self.startup_timeout_ms },
                );
                const startup_timeout = !self.ready_received and err == error.Timeout;
                self.reset();
                return if (startup_timeout) error.StartupTimeout else err;
            };
            const response_len = std.mem.readInt(u32, &raw_length, .little);
            if (response_len == 0 or response_len > protocol.max_frame_bytes) {
                self.reset();
                return error.InvalidResponse;
            }
            var ready_storage: [10]u8 = undefined;
            const response: []u8 = if (!self.ready_received and response_len == ready_storage.len) &ready_storage else a.alloc(u8, response_len) catch |err| {
                self.reset();
                return err;
            };
            self.readExact(child.stdout.?, response, startup_deadline, budget) catch |err| {
                if (err == error.WorkerClosed) self.reportClosed(page_ordinal, title);
                if (err == error.Timeout) diagnostics.printLine(
                    "bundle {s} response timed out title={s} ordinal={d} source_bytes={d} response_bytes={d} timeout_ms={d}\n",
                    .{ if (self.ready_received) "expansion" else "startup", title, page_ordinal, source.len, response_len, if (self.ready_received) self.timeout_ms else self.startup_timeout_ms },
                );
                const startup_timeout = !self.ready_received and err == error.Timeout;
                self.reset();
                return if (startup_timeout) error.StartupTimeout else err;
            };
            const timed = protocol.decodeTimedReply(response) catch {
                self.reset();
                return error.InvalidResponse;
            };
            const reply = timed.reply;
            validateReplyPhase(reply, !self.ready_received) catch |err| {
                self.reset();
                return err;
            };
            if (self.ready_received) budget.observe(timed.cpu_ns) catch |err| {
                self.reset();
                return err;
            };
            switch (reply) {
                .ready => {
                    budget.begin(timed.cpu_ns) catch |err| {
                        self.reset();
                        return err;
                    };
                    self.ready_received = true;
                    diagnostics.printLine("bundle worker ready generation={d} startup_ms={d} page_cpu_budget_ms={d}\n", .{ self.generation, @divTrunc(std.Io.Clock.awake.now(self.io).toNanoseconds() - start, std.time.ns_per_ms), @divTrunc(budget.remaining_ns, std.time.ns_per_ms) });
                    continue;
                },
                .output => |success| return .{
                    .source = success.output,
                    .poem_metadata = success.poem_metadata,
                    .missing_dependency_metadata = success.missing_dependency_metadata,
                    .unsupported_parser_function = success.unsupported_parser_function,
                    .display_title = if (success.display_title.len == 0) null else success.display_title,
                },
                .skip => return null,
                .failure => |failure| {
                    self.last_failure = failure;
                    diagnostics.printLine("bundle expansion failed title={s} stage={s} error={s}{s}{s}\n", .{
                        title,
                        failure.stage,
                        failure.error_name,
                        if (failure.detail.len != 0) ": " else "",
                        failure.detail,
                    });
                    if (operationalFailure(failure)) |err| {
                        // Persistent promotion may have failed partway through.
                        // Never reuse that process after an operational failure.
                        remote_oom.* = err == error.OutOfMemory;
                        self.reset();
                        return err;
                    }
                    return error.ExpansionFailed;
                },
            }
        }
    }
};

test "remote operational failures retain their error identity" {
    try std.testing.expectEqual(error.InterfaceMessageSnapshotMissing, operationalFailure(.{ .stage = "expand", .error_name = "InterfaceMessageSnapshotMissing", .detail = "" }).?);
    try std.testing.expectEqual(error.OutOfMemory, operationalFailure(.{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" }).?);
    try std.testing.expectEqual(error.Timeout, operationalFailure(.{ .stage = "assets", .error_name = "Timeout", .detail = "" }).?);
    try std.testing.expect(operationalFailure(.{ .stage = "expand", .error_name = "NotImplemented", .detail = "" }) == null);
    try std.testing.expect(operationalFailure(.{ .stage = "expand", .error_name = "UnsupportedScriptTimeoutMessage", .detail = "" }) == null);
    inline for (&.{ "request", "assets", "install", "unknown" }) |stage|
        try std.testing.expectEqual(error.BundleInfrastructureFailed, operationalFailure(.{ .stage = stage, .error_name = "FileNotFound", .detail = "" }).?);
}

test "worker restart preserves the pinned bundle timestamp" {
    var worker = Worker.init(std.testing.io, "root", "unused", "dump.xml");
    const pinned = worker.now_unix;
    worker.ready_received = true;
    worker.reset();
    try std.testing.expectEqual(pinned, worker.now_unix);
    try std.testing.expect(!worker.ready_received);
}

test "startup accepts readiness or bootstrap failure and rejects page output" {
    try validateReplyPhase(.ready, true);
    try validateReplyPhase(.{ .failure = .{ .stage = "assets", .error_name = "OutOfMemory", .detail = "" } }, true);
    try std.testing.expectError(error.InvalidResponse, validateReplyPhase(.skip, true));
    try std.testing.expectError(error.InvalidResponse, validateReplyPhase(.{ .output = .{ .output = "x", .display_title = "" } }, true));
    try std.testing.expectError(error.InvalidResponse, validateReplyPhase(.{ .failure = .{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" } }, true));
    try std.testing.expectError(error.InvalidResponse, validateReplyPhase(.ready, false));
    try validateReplyPhase(.skip, false);
}

test "Poem provenance failures are operational rather than semantic fallback" {
    inline for (&.{ "InvalidPoemMetadata", "MissingPoemMetadata", "OrphanPoemMarker", "FrameTooLarge" }) |name| {
        try std.testing.expectEqual(error.BundleInfrastructureFailed, operationalFailure(.{ .stage = "expand", .error_name = name, .detail = "" }).?);
    }
}

test "page identity failures are operational rather than fallback" {
    inline for (&.{ "InvalidPageIndex", "NamespaceTitleCollision", "NamespaceTitleMismatch", "InvalidNamespace", "UnsupportedStoredInterwikiNamespace", "UnsupportedStoredLocalInterwiki", "InvalidStoredRedirectTarget" }) |name|
        try std.testing.expectEqual(error.BundleInfrastructureFailed, operationalFailure(.{ .stage = "expand", .error_name = name, .detail = "" }).?);
    try std.testing.expect(operationalFailure(.{ .stage = "expand", .error_name = "LuaRaised", .detail = "UnsupportedStoredInterwikiNamespace" }) == null);
}

test "page CPU accounting excludes idle wall and charges delayed ready consumption" {
    var budget: PageCpuBudget = .{ .remaining_ns = 60_000 };
    // Worker stamp predates parent consumption; all intervening worker CPU is
    // charged even when the parent did not run until after expansion completed.
    try budget.begin(900_000);
    try budget.observe(912_000);
    try std.testing.expectEqual(@as(u64, 48_000), budget.remaining_ns);
    for (0..100) |_| try budget.observe(912_000); // Arbitrarily long idle/wall wait.
    try std.testing.expectEqual(@as(u64, 48_000), budget.remaining_ns);
    try std.testing.expectError(error.Timeout, budget.observe(960_000));
    try std.testing.expectEqual(@as(u64, 0), budget.remaining_ns);
}

test "queued complete OOM debits CPU before exited generation is replaced" {
    var budget: PageCpuBudget = .{ .remaining_ns = 60_000 };
    try budget.begin(100_000);
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try protocol.writeTimedReply(&bytes.writer, 140_000, .{ .failure = .{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" } });
    // No live-child clock read is needed to consume a complete queued reply.
    const queued = try protocol.decodeTimedReply(bytes.written()[4..]);
    try budget.observe(queued.cpu_ns);
    try std.testing.expectEqual(error.OutOfMemory, operationalFailure(queued.reply.failure).?);
    budget.newGeneration();
    try budget.begin(2_000_000); // Cold startup CPU is independently excluded.
    try budget.observe(2_019_999);
    try std.testing.expectEqual(@as(u64, 1), budget.remaining_ns);
    try std.testing.expectError(error.Timeout, budget.observe(2_020_000));
}

test "CPU accounting rejects regressing samples and duplicate baselines" {
    var budget: PageCpuBudget = .{ .remaining_ns = 60 };
    try budget.begin(100);
    try std.testing.expectError(error.InvalidResponse, budget.begin(101));
    try std.testing.expectError(error.InvalidResponse, budget.observe(99));
    try std.testing.expectEqual(@as(u64, 60), budget.remaining_ns);
    budget.newGeneration();
    try std.testing.expectError(error.InvalidResponse, budget.observe(1));
}

test "idle polling uses fake process CPU and fails closed without charging elapsed wait" {
    const FakeClock = struct {
        stamp: u64 = 100,
        failure: ?anyerror = null,
        calls: usize = 0,
        fn processCpuNow(clock: *@This()) !u64 {
            clock.calls += 1;
            if (clock.failure) |err| return err;
            return clock.stamp;
        }
    };
    var budget: PageCpuBudget = .{ .remaining_ns = 60 };
    try budget.begin(100);
    var clock: FakeClock = .{};
    for (0..100) |_| try checkPollCpu(&budget, false, &clock);
    try std.testing.expectEqual(@as(u64, 60), budget.remaining_ns);
    clock.stamp = 159;
    try checkPollCpu(&budget, false, &clock);
    clock.stamp = 158;
    try std.testing.expectError(error.InvalidResponse, checkPollCpu(&budget, false, &clock));
    clock.stamp = 160;
    try std.testing.expectError(error.Timeout, checkPollCpu(&budget, false, &clock));
    clock.failure = error.WorkerCpuClockUnavailable;
    try std.testing.expectError(error.WorkerCpuClockUnavailable, checkPollCpu(&budget, false, &clock));
    const calls = clock.calls;
    try checkPollCpu(&budget, true, &clock);
    try std.testing.expectEqual(calls, clock.calls);
    clock.failure = error.WorkerClosed;
    try std.testing.expectError(error.WorkerClosed, checkPollCpu(&budget, false, &clock));
}

test "complete queued reply survives exited child while EOF and partial replies remain WorkerClosed" {
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try protocol.writeTimedReply(&encoded.writer, 140, .{ .failure = .{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" } });
    for ([_]usize{ encoded.written().len, encoded.written().len - 1, 0 }) |length| {
        var fds: [2]std.posix.fd_t = undefined;
        if (L.errno(L.pipe2(&fds, .{})) != .SUCCESS) return error.PipeFailed;
        defer _ = L.close(fds[0]);
        if (length != 0) {
            const written = L.write(fds[1], encoded.written().ptr, length);
            if (L.errno(written) != .SUCCESS or written != length) {
                _ = L.close(fds[1]);
                return error.WriteFailed;
            }
        }
        _ = L.close(fds[1]); // No live child or CPU clock remains.
        var worker = Worker.init(std.testing.io, "root", "unused", "dump");
        var budget: PageCpuBudget = .{ .remaining_ns = 60 };
        try budget.begin(100);
        const file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        const out = try std.testing.allocator.alloc(u8, encoded.written().len);
        defer std.testing.allocator.free(out);
        if (length == out.len) {
            try worker.readExact(file, out, 0, &budget);
            const reply = try protocol.decodeTimedReply(out[4..]);
            try budget.observe(reply.cpu_ns);
            try std.testing.expectEqual(@as(u64, 20), budget.remaining_ns);
            try std.testing.expectEqual(error.OutOfMemory, operationalFailure(reply.reply.failure).?);
        } else {
            try std.testing.expectError(error.WorkerClosed, worker.readExact(file, out, 0, &budget));
        }
    }
}

test "idle poll clock race preserves newly queued reply with one bounded repoll" {
    const Clock = struct {
        fn processCpuNow(_: @This()) !u64 {
            return error.WorkerClosed; // Exit after the original poll timed out.
        }
    };
    const Pipe = struct {
        readable: bool,
        checks: *usize,
        fn readyNow(pipe: @This()) !bool {
            pipe.checks.* += 1;
            return pipe.readable;
        }
    };
    var budget: PageCpuBudget = .{ .remaining_ns = 60 };
    try budget.begin(100);
    var checks: usize = 0;
    try std.testing.expect(try afterIdlePoll(&budget, Clock{}, Pipe{ .readable = true, .checks = &checks }));
    try std.testing.expectEqual(@as(usize, 1), checks);
    // The complete queued reply is authenticated/debited, without consulting
    // the vanished process. EOF/partial draining is covered by the pipe test.
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try protocol.writeTimedReply(&bytes.writer, 140, .{ .failure = .{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" } });
    const reply = try protocol.decodeTimedReply(bytes.written()[4..]);
    try budget.observe(reply.cpu_ns);
    try std.testing.expectEqual(@as(u64, 20), budget.remaining_ns);
    try std.testing.expectError(error.WorkerClosed, afterIdlePoll(&budget, Clock{}, Pipe{ .readable = false, .checks = &checks }));
    try std.testing.expectEqual(@as(usize, 2), checks);
    const ErrorClock = struct {
        failure: anyerror,
        fn processCpuNow(clock: @This()) !u64 {
            return clock.failure;
        }
    };
    for ([_]anyerror{error.WorkerCpuClockUnavailable}) |err| {
        checks = 0;
        try std.testing.expectError(err, afterIdlePoll(&budget, ErrorClock{ .failure = err }, Pipe{ .readable = true, .checks = &checks }));
        try std.testing.expectEqual(@as(usize, 0), checks);
    }
    const SampleClock = struct {
        stamp: u64,
        fn processCpuNow(clock: @This()) !u64 {
            return clock.stamp;
        }
    };
    const Case = struct { stamp: u64, failure: anyerror };
    for ([_]Case{ .{ .stamp = 139, .failure = error.InvalidResponse }, .{ .stamp = 160, .failure = error.Timeout } }) |case| {
        checks = 0;
        try std.testing.expectError(case.failure, afterIdlePoll(&budget, SampleClock{ .stamp = case.stamp }, Pipe{ .readable = true, .checks = &checks }));
        try std.testing.expectEqual(@as(usize, 0), checks);
    }
}
