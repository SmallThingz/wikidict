const std = @import("std");
const diagnostics = @import("build_diagnostics");
const A = std.mem.Allocator;
const L = std.os.linux;
const protocol = @import("bundle_protocol");
const expansion_deadline = @import("expansion_deadline.zig");

pub const Expansion = struct {
    source: []const u8,
    display_title: ?[]const u8 = null,
    unsupported_parser_function: bool = false,
    poem_metadata: ?[]const u8 = null,
};

pub const Failure = protocol.ErrorReply;

// Transporting an error must not turn resource exhaustion into a semantic
// fallback. Keep this shared with the blob writer's defensive classification.
pub fn operationalFailure(failure: Failure) ?anyerror {
    if (std.mem.eql(u8, failure.error_name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, failure.error_name, "Timeout")) return error.Timeout;
    // Asset loading, protocol validation and bootstrap are compiler operations,
    // not per-page MediaWiki semantics. Never publish empty pages for them.
    if (!std.mem.eql(u8, failure.stage, "expand")) return error.BundleInfrastructureFailed;
    inline for (&.{ "BundleRootChanged", "BundleDumpChanged", "BundleTimeChanged", "InvalidPageIndex", "InvalidPageTitleIndex", "PageIndexChanged", "InvalidProgramMetadata", "InvalidPoemMetadata", "MissingPoemMetadata", "OrphanPoemMarker", "FrameTooLarge" }) |name|
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

    fn readExact(self: *Worker, file: std.Io.File, out: []u8, deadline: i128) !void {
        var pos: usize = 0;
        while (pos < out.len) {
            const remaining = deadline - std.Io.Clock.awake.now(self.io).toNanoseconds();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const wait_ms: i32 = @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, 100));
            if (try std.posix.poll(&fds, wait_ms) == 0) continue;
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

    fn writeRequest(self: *Worker, child: *std.process.Child, page_ordinal: u64, title: []const u8, source: []const u8) !void {
        var buffer: [8192]u8 = undefined;
        var writer = child.stdin.?.writer(self.io, &buffer);
        try protocol.writeRequest(&writer.interface, .{
            .root = self.root,
            .dump = self.dump,
            .now_unix = self.now_unix,
            .page_ordinal = page_ordinal,
            .title = title,
            .source = source,
        });
    }

    pub fn expand(self: *Worker, a: A, page_ordinal: u64, title: []const u8, source: []const u8) !?Expansion {
        self.last_failure = null;
        if (source.len > protocol.max_source_bytes) return error.RequestTooLarge;
        // Both attempts share the page budget; each new generation has a
        // separately bounded startup response. Blocking request transmission
        // still requires the outer watchdog for a stuck/non-reading child.
        var remaining_page_ns = @as(i128, self.timeout_ms) * std.time.ns_per_ms;
        var remote_oom = false;
        return self.expandOnce(a, page_ordinal, title, source, &remaining_page_ns, &remote_oom) catch |err| {
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
            const recovered = self.expandOnce(a, page_ordinal, title, source, &remaining_page_ns, &remote_oom) catch |cold_err| {
                self.reset();
                self.oom_retry_failed +|= 1;
                diagnostics.printLine("bundle OOM recovery failed ordinal={d} generation={d} error={s}\n", .{ page_ordinal, self.generation, @errorName(cold_err) });
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

    fn expandOnce(self: *Worker, a: A, page_ordinal: u64, title: []const u8, source: []const u8, remaining_page_ns: *i128, remote_oom: *bool) !?Expansion {
        if (remaining_page_ns.* <= 0) return error.Timeout;
        const start = std.Io.Clock.awake.now(self.io).toNanoseconds();
        var page_started: ?i128 = if (self.child != null and self.ready_received) start else null;
        defer if (page_started) |began| {
            const elapsed = std.Io.Clock.awake.now(self.io).toNanoseconds() - began;
            remaining_page_ns.* = @max(0, remaining_page_ns.* - elapsed);
        };
        var deadline = start + if (page_started != null) remaining_page_ns.* else @as(i128, self.startup_timeout_ms) * std.time.ns_per_ms;
        const child = try self.ensure();
        self.writeRequest(child, page_ordinal, title, source) catch |err| {
            self.reset();
            return err;
        };
        while (true) {
            var raw_length: [4]u8 = undefined;
            self.readExact(child.stdout.?, &raw_length, deadline) catch |err| {
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
            var ready_storage: [1]u8 = undefined;
            const response: []u8 = if (!self.ready_received and response_len == 1) &ready_storage else a.alloc(u8, response_len) catch |err| {
                self.reset();
                return err;
            };
            self.readExact(child.stdout.?, response, deadline) catch |err| {
                if (err == error.WorkerClosed) self.reportClosed(page_ordinal, title);
                if (err == error.Timeout) diagnostics.printLine(
                    "bundle {s} response timed out title={s} ordinal={d} source_bytes={d} response_bytes={d} timeout_ms={d}\n",
                    .{ if (self.ready_received) "expansion" else "startup", title, page_ordinal, source.len, response_len, if (self.ready_received) self.timeout_ms else self.startup_timeout_ms },
                );
                const startup_timeout = !self.ready_received and err == error.Timeout;
                self.reset();
                return if (startup_timeout) error.StartupTimeout else err;
            };
            const reply = protocol.decodeReply(response) catch {
                self.reset();
                return error.InvalidResponse;
            };
            validateReplyPhase(reply, !self.ready_received) catch |err| {
                self.reset();
                return err;
            };
            switch (reply) {
                .ready => {
                    self.ready_received = true;
                    page_started = std.Io.Clock.awake.now(self.io).toNanoseconds();
                    deadline = page_started.? + remaining_page_ns.*;
                    diagnostics.printLine("bundle worker ready generation={d} startup_ms={d} page_budget_ms={d}\n", .{ self.generation, @divTrunc(page_started.? - start, std.time.ns_per_ms), @divTrunc(remaining_page_ns.*, std.time.ns_per_ms) });
                    continue;
                },
                .output => |success| return .{
                    .source = success.output,
                    .poem_metadata = success.poem_metadata,
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
    try std.testing.expectEqual(error.OutOfMemory, operationalFailure(.{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" }).?);
    try std.testing.expectEqual(error.Timeout, operationalFailure(.{ .stage = "assets", .error_name = "Timeout", .detail = "" }).?);
    try std.testing.expect(operationalFailure(.{ .stage = "expand", .error_name = "NotImplemented", .detail = "" }) == null);
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
