const std = @import("std");
const A = std.mem.Allocator;
const L = std.os.linux;
const protocol = @import("bundle_protocol");

pub const Worker = struct {
    io: std.Io,
    root: []const u8,
    executable: []const u8,
    dump: []const u8,
    now_unix: i64,
    timeout_ms: u32 = 60_000,
    child: ?std.process.Child = null,

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
        self.reset();
    }

    fn reset(self: *Worker) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
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

    fn writeRequest(self: *Worker, child: *std.process.Child, title: []const u8, source: []const u8) !void {
        var buffer: [8192]u8 = undefined;
        var writer = child.stdin.?.writer(self.io, &buffer);
        try protocol.writeRequest(&writer.interface, .{
            .root = self.root,
            .dump = self.dump,
            .now_unix = self.now_unix,
            .title = title,
            .source = source,
        });
    }

    pub fn expand(self: *Worker, a: A, title: []const u8, source: []const u8) ![]u8 {
        if (source.len > protocol.max_source_bytes) return error.RequestTooLarge;
        const child = try self.ensure();
        self.writeRequest(child, title, source) catch |err| {
            self.reset();
            return err;
        };
        const deadline = std.Io.Clock.awake.now(self.io).toNanoseconds() + @as(i128, self.timeout_ms) * std.time.ns_per_ms;
        var raw_length: [4]u8 = undefined;
        self.readExact(child.stdout.?, &raw_length, deadline) catch |err| {
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
            self.reset();
            return err;
        };
        const reply = protocol.decodeReply(response) catch return error.InvalidResponse;
        switch (reply) {
            .output => |output| return @constCast(output),
            .failure => |failure| {
                std.debug.print("bundle expansion failed title={s} stage={s} error={s}{s}{s}\n", .{
                    title,
                    failure.stage,
                    failure.error_name,
                    if (failure.detail.len != 0) ": " else "",
                    failure.detail,
                });
                return error.ExpansionFailed;
            },
        }
    }
};

test "worker restart preserves the pinned bundle timestamp" {
    var worker = Worker.init(std.testing.io, "root", "unused", "dump.xml");
    const pinned = worker.now_unix;
    worker.reset();
    try std.testing.expectEqual(pinned, worker.now_unix);
}
