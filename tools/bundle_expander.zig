const std = @import("std");
const A = std.mem.Allocator;
const L = std.os.linux;
const protocol = @import("bundle_protocol");
const expansion_deadline = @import("expansion_deadline.zig");

pub const Expansion = struct {
    source: []const u8,
    display_title: ?[]const u8 = null,
};

pub const Failure = protocol.ErrorReply;

// Transporting an error must not turn resource exhaustion into a semantic
// fallback. Keep this shared with the blob writer's defensive classification.
pub fn operationalFailure(failure: Failure) ?anyerror {
    if (std.mem.eql(u8, failure.error_name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, failure.error_name, "Timeout")) return error.Timeout;
    return null;
}

pub const Worker = struct {
    io: std.Io,
    root: []const u8,
    executable: []const u8,
    dump: []const u8,
    now_unix: i64,
    timeout_ms: u32 = expansion_deadline.default_ms,
    child: ?std.process.Child = null,
    last_failure: ?Failure = null,

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
                    std.debug.print("bundle worker closed pid={d} ordinal={d} title={s} wait_error={s}\n", .{ pid, ordinal, title, @errorName(err) });
                    return;
                };
                std.debug.print("bundle worker closed pid={d} ordinal={d} title={s} termination={any}\n", .{ pid, ordinal, title, term });
                self.child = null;
                return;
            }
        }
        // EOF can precede process exit or be an explicit stdout close. Do not
        // block indefinitely waiting for a worker whose pipe has disappeared.
        std.debug.print("bundle worker closed pid={d} ordinal={d} title={s} termination=not-ready\n", .{ pid, ordinal, title });
    }

    fn ensure(self: *Worker) !*std.process.Child {
        if (self.child == null) {
            self.child = try std.process.spawn(self.io, .{
                .argv = &.{self.executable},
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
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
        const child = try self.ensure();
        self.writeRequest(child, page_ordinal, title, source) catch |err| {
            self.reset();
            return err;
        };
        const deadline = std.Io.Clock.awake.now(self.io).toNanoseconds() + @as(i128, self.timeout_ms) * std.time.ns_per_ms;
        var raw_length: [4]u8 = undefined;
        self.readExact(child.stdout.?, &raw_length, deadline) catch |err| {
            if (err == error.WorkerClosed) self.reportClosed(page_ordinal, title);
            if (err == error.Timeout) std.debug.print(
                "bundle expansion timed out title={s} ordinal={d} source_bytes={d} timeout_ms={d}\n",
                .{ title, page_ordinal, source.len, self.timeout_ms },
            );
            self.reset();
            return err;
        };
        const response_len = std.mem.readInt(u32, &raw_length, .little);
        if (response_len == 0 or response_len > protocol.max_frame_bytes) {
            self.reset();
            return error.InvalidResponse;
        }
        const response = try a.alloc(u8, response_len);
        self.readExact(child.stdout.?, response, deadline) catch |err| {
            if (err == error.WorkerClosed) self.reportClosed(page_ordinal, title);
            if (err == error.Timeout) std.debug.print(
                "bundle expansion response timed out title={s} ordinal={d} source_bytes={d} response_bytes={d} timeout_ms={d}\n",
                .{ title, page_ordinal, source.len, response_len, self.timeout_ms },
            );
            self.reset();
            return err;
        };
        const reply = protocol.decodeReply(response) catch return error.InvalidResponse;
        switch (reply) {
            .output => |success| return .{
                .source = success.output,
                .display_title = if (success.display_title.len == 0) null else success.display_title,
            },
            .skip => return null,
            .failure => |failure| {
                self.last_failure = failure;
                std.debug.print("bundle expansion failed title={s} stage={s} error={s}{s}{s}\n", .{
                    title,
                    failure.stage,
                    failure.error_name,
                    if (failure.detail.len != 0) ": " else "",
                    failure.detail,
                });
                if (operationalFailure(failure)) |err| {
                    // Persistent promotion may have failed partway through.
                    // Never reuse that process after an operational failure.
                    self.reset();
                    return err;
                }
                return error.ExpansionFailed;
            },
        }
    }
};

test "remote operational failures retain their error identity" {
    try std.testing.expectEqual(error.OutOfMemory, operationalFailure(.{ .stage = "expand", .error_name = "OutOfMemory", .detail = "" }).?);
    try std.testing.expectEqual(error.Timeout, operationalFailure(.{ .stage = "assets", .error_name = "Timeout", .detail = "" }).?);
    try std.testing.expect(operationalFailure(.{ .stage = "expand", .error_name = "NotImplemented", .detail = "" }) == null);
}

test "worker restart preserves the pinned bundle timestamp" {
    var worker = Worker.init(std.testing.io, "root", "unused", "dump.xml");
    const pinned = worker.now_unix;
    worker.reset();
    try std.testing.expectEqual(pinned, worker.now_unix);
}
