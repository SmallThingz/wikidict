const std = @import("std");
const A = std.mem.Allocator;
const L = std.os.linux;

const Request = struct {
    root: []const u8,
    title: []const u8,
    source: []const u8,
};

const Reply = struct {
    schema: []const u8 = "dict.expansion.v1",
    backend: []const u8 = "lua-aot",
    output: ?[]const u8 = null,
    stage: []const u8 = "expand",
    error_name: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const Worker = struct {
    io: std.Io,
    root: []const u8,
    executable: []const u8,
    timeout_ms: u32 = 60_000,
    child: ?std.process.Child = null,

    pub fn init(io: std.Io, root: []const u8, executable: []const u8) Worker {
        return .{ .io = io, .root = root, .executable = executable };
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

    fn writeRequest(self: *Worker, child: *std.process.Child, bytes: []const u8) !void {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
        var writer = child.stdin.?.writer(self.io, &.{});
        try writer.interface.writeAll(&length);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    pub fn expand(self: *Worker, a: A, title: []const u8, source: []const u8) ![]u8 {
        const request = Request{ .root = self.root, .title = title, .source = source };
        const bytes = try std.json.Stringify.valueAlloc(a, request, .{});
        defer a.free(bytes);
        if (bytes.len == 0 or bytes.len > 32 * 1024 * 1024) return error.RequestTooLarge;

        const child = try self.ensure();
        self.writeRequest(child, bytes) catch |err| {
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
        if (response_len == 0 or response_len > 32 * 1024 * 1024) {
            self.reset();
            return error.InvalidResponse;
        }
        const response = try a.alloc(u8, response_len);
        defer a.free(response);
        self.readExact(child.stdout.?, response, deadline) catch |err| {
            self.reset();
            return err;
        };

        const parsed = try std.json.parseFromSlice(Reply, a, response, .{});
        defer parsed.deinit();
        const reply = parsed.value;
        if (!std.mem.eql(u8, reply.schema, "dict.expansion.v1")) return error.InvalidResponse;
        if (reply.error_name) |name| {
            std.debug.print("bundle expansion failed title={s} stage={s} error={s}{s}{s}\n", .{
                title,
                reply.stage,
                name,
                if (reply.detail != null) ": " else "",
                reply.detail orelse "",
            });
            return error.ExpansionFailed;
        }
        const output = reply.output orelse return error.InvalidResponse;
        return a.dupe(u8, output);
    }
};
