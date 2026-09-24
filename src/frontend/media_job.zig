//! One owned, cancellable media action for the terminal UI.
//! Call Job methods only from the UI thread. The supplied Io provider and
//! allocator must outlive the job; deinit before tearing either down.

const std = @import("std");
const A = std.mem.Allocator;

pub const Request = union(enum) {
    speech: struct { word: []const u8, language: []const u8 },
    media: struct { root: []const u8, file: []const u8, image: bool, cache_mb: usize },
};
pub const Kind = std.meta.Tag(Request);
pub const Result = struct { kind: Kind, err: ?anyerror = null };
pub const Job = JobFor(@import("reader_media.zig"));

fn JobFor(comptime media: type) type {
    return struct {
        const Self = @This();
        task: ?*Task = null,

        /// Copies every argument before returning. Replaces an existing job by
        /// canceling and joining it first. Concurrency failure never runs inline.
        pub fn start(self: *Self, io: std.Io, a: A, request: Request) !void {
            self.cancel(io);
            const task = try a.create(Task);
            task.* = .{ .a = a, .io = io, .inputs = .init(a), .request = undefined };
            errdefer task.destroy();
            task.request = try copyRequest(task.inputs.allocator(), request);
            task.future = try io.concurrent(run, .{task});
            self.task = task;
        }

        /// Returns each completion once. It only joins after the media function
        /// and its cleanup have finished; it never waits for active media I/O.
        pub fn poll(self: *Self, io: std.Io) ?Result {
            const task = self.task orelse return null;
            if (!task.done.load(.acquire)) return null;
            const result = task.future.await(io);
            self.task = null;
            task.destroy();
            return result;
        }

        /// Includes completed jobs until poll consumes their result.
        pub fn kind(self: *const Self) ?Kind {
            return if (self.task) |task| std.meta.activeTag(task.request) else null;
        }

        /// Cancels owned I/O and joins before freeing arguments. Idempotent.
        /// reader_media must propagate error.Canceled from its I/O operations.
        pub fn cancel(self: *Self, io: std.Io) void {
            const task = self.task orelse return;
            _ = task.future.cancel(io);
            self.task = null;
            task.destroy();
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.cancel(io);
        }

        const Task = struct {
            a: A,
            io: std.Io,
            inputs: std.heap.ArenaAllocator,
            request: Request,
            done: std.atomic.Value(bool) = .init(false),
            future: std.Io.Future(Result) = undefined,

            fn destroy(task: *Task) void {
                const a = task.a;
                task.inputs.deinit();
                a.destroy(task);
            }
        };

        fn copyRequest(a: A, request: Request) !Request {
            return switch (request) {
                .speech => |s| .{ .speech = .{
                    .word = try a.dupe(u8, s.word),
                    .language = try a.dupe(u8, s.language),
                } },
                .media => |m| .{ .media = .{
                    .root = try a.dupe(u8, m.root),
                    .file = try a.dupe(u8, m.file),
                    .image = m.image,
                    .cache_mb = m.cache_mb,
                } },
            };
        }

        fn run(task: *Task) Result {
            // The UI allocator is never called by the worker. This arena also
            // bounds all media allocations to this action, including failures.
            defer task.done.store(true, .release);
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            const action_kind = std.meta.activeTag(task.request);
            perform(task.io, scratch.allocator(), task.request) catch |err| return .{ .kind = action_kind, .err = err };
            return .{ .kind = action_kind };
        }

        fn perform(io: std.Io, a: A, request: Request) !void {
            try io.checkCancel();
            switch (request) {
                .speech => |s| try media.speak(io, a, s.word, s.language),
                .media => |m| try media.open(io, a, m.root, m.file, m.image, m.cache_mb),
            }
        }
    };
}

const Probe = struct {
    var entered: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    var active: std.atomic.Value(bool) = .init(false);

    fn reset() void {
        entered.store(false, .release);
        released.store(false, .release);
        active.store(false, .release);
    }

    fn wait(io: std.Io) !void {
        active.store(true, .release);
        defer active.store(false, .release);
        entered.store(true, .release);
        while (!released.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    }

    fn speak(io: std.Io, _: A, word: []const u8, language: []const u8) !void {
        try wait(io);
        if (std.mem.eql(u8, word, "fail")) return error.FixtureFailure;
        if (!std.mem.eql(u8, word, "word") or !std.mem.eql(u8, language, "lang")) return error.BadSnapshot;
    }

    fn open(io: std.Io, _: A, root: []const u8, file: []const u8, image: bool, cache_mb: usize) !void {
        try wait(io);
        if (!std.mem.eql(u8, root, "root") or !std.mem.eql(u8, file, "file") or !image or cache_mb != 42) return error.BadSnapshot;
    }
};

const ProbeJob = JobFor(Probe);

fn waitForProbe(io: std.Io) !void {
    for (0..1000) |_| {
        if (Probe.entered.load(.acquire)) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FixtureDidNotStart;
}

fn waitForResult(job: *ProbeJob, io: std.Io) !Result {
    for (0..1000) |_| {
        if (job.poll(io)) |result| return result;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FixtureDidNotFinish;
}

test "speech arguments are owned, polling remains responsive, result consumed once" {
    Probe.reset();
    const io = std.testing.io;
    var job: ProbeJob = .{};
    defer job.deinit(io);
    var word = "word".*;
    var language = "lang".*;
    try job.start(io, std.testing.allocator, .{ .speech = .{ .word = &word, .language = &language } });
    @memset(&word, 'x');
    @memset(&language, 'x');
    try waitForProbe(io);
    for (0..10) |_| try std.testing.expect(job.poll(io) == null);
    try std.testing.expectEqual(Kind.speech, job.kind().?);
    Probe.released.store(true, .release);
    const result = try waitForResult(&job, io);
    try std.testing.expectEqual(Kind.speech, result.kind);
    try std.testing.expect(result.err == null);
    try std.testing.expect(job.poll(io) == null and job.kind() == null);
}

test "media arguments are owned" {
    Probe.reset();
    const io = std.testing.io;
    var job: ProbeJob = .{};
    defer job.deinit(io);
    var root = "root".*;
    var file = "file".*;
    try job.start(io, std.testing.allocator, .{ .media = .{ .root = &root, .file = &file, .image = true, .cache_mb = 42 } });
    @memset(&root, 'x');
    @memset(&file, 'x');
    try waitForProbe(io);
    Probe.released.store(true, .release);
    const result = try waitForResult(&job, io);
    try std.testing.expectEqual(Kind.media, result.kind);
    try std.testing.expect(result.err == null);
}

test "cancel and replacement join the old job before releasing its input" {
    Probe.reset();
    const io = std.testing.io;
    var job: ProbeJob = .{};
    defer job.deinit(io);
    const request: Request = .{ .speech = .{ .word = "word", .language = "lang" } };
    try job.start(io, std.testing.allocator, request);
    try waitForProbe(io);
    try std.testing.expect(Probe.active.load(.acquire));
    job.cancel(io);
    try std.testing.expect(!Probe.active.load(.acquire) and job.kind() == null);
    job.cancel(io);
    Probe.reset();
    try job.start(io, std.testing.allocator, request);
    try waitForProbe(io);
    try job.start(io, std.testing.allocator, request);
    Probe.released.store(true, .release);
    const result = try waitForResult(&job, io);
    try std.testing.expect(result.err == null);
}

test "errors are published only after task completion" {
    Probe.reset();
    const io = std.testing.io;
    var job: ProbeJob = .{};
    defer job.deinit(io);
    try job.start(io, std.testing.allocator, .{ .speech = .{ .word = "fail", .language = "lang" } });
    try waitForProbe(io);
    Probe.released.store(true, .release);
    try std.testing.expectEqual(error.FixtureFailure, (try waitForResult(&job, io)).err.?);
}

test "unavailable concurrency and allocation failure leave no active job" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var job: ProbeJob = .{};
    defer job.deinit(io);
    const request: Request = .{ .speech = .{ .word = "word", .language = "lang" } };
    try std.testing.expectError(error.ConcurrencyUnavailable, job.start(io, std.testing.allocator, request));
    try std.testing.expect(job.kind() == null);
    try std.testing.expectError(error.OutOfMemory, job.start(io, std.testing.failing_allocator, request));
    try std.testing.expect(job.kind() == null);
}
