//! Build-worker-only, request-scoped counters. The worker processes one request
//! at a time; forked Lua contexts execute on the same thread.
const std = @import("std");
const linux = std.os.linux;

/// The expansion profile is inherited by child workers. Only an explicit 1
/// enables per-invoke diagnostics and sampled CPU timing.
pub fn profileEnabledFromEnv(value_opt: ?[]const u8) !bool {
    const value = value_opt orelse return false;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.InvalidExpansionProfile;
}

test "expansion profile requires an explicit one flag" {
    try std.testing.expect(!(try profileEnabledFromEnv(null)));
    try std.testing.expect(!(try profileEnabledFromEnv("0")));
    try std.testing.expect(try profileEnabledFromEnv("1"));
    try std.testing.expectError(error.InvalidExpansionProfile, profileEnabledFromEnv(""));
    try std.testing.expectError(error.InvalidExpansionProfile, profileEnabledFromEnv("true"));
}

const diagnostic_record_bytes = 4096;
const truncation_marker = " [diagnostic truncated]\n";

// Keep a valid UTF-8 input valid when a bounded record ends inside a codepoint.
// Invalid input bytes elsewhere are retained rather than silently rewritten.
fn completeUtf8Prefix(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var start = bytes.len - 1;
    while (start != 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    const expected = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes.len;
    return if (bytes.len - start < expected) start else bytes.len;
}

fn formatDiagnostic(
    buffer: *[diagnostic_record_bytes]u8,
    pid: ?linux.pid_t,
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    // Fixed Writer retains the filled prefix on overflow. Reserve the suffix
    // before formatting: oversized diagnostics must be visible, never dropped.
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - truncation_marker.len]);
    if (pid) |value| writer.print("pid={d} ", .{value}) catch unreachable;
    var truncated = false;
    writer.print(format, args) catch {
        truncated = true;
    };
    var record_end = writer.end;
    if (truncated) {
        record_end = completeUtf8Prefix(buffer[0..record_end]);
        @memcpy(buffer[record_end..][0..truncation_marker.len], truncation_marker);
        record_end += truncation_marker.len;
    } else if (record_end == 0 or buffer[record_end - 1] != '\n') {
        buffer[record_end] = '\n';
        record_end += 1;
    }
    return buffer[0..record_end];
}

fn writeDiagnostic(fd: linux.fd_t, pid: ?linux.pid_t, comptime format: []const u8, args: anytype) void {
    var buffer: [diagnostic_record_bytes]u8 = undefined;
    const line = formatDiagnostic(&buffer, pid, format, args);
    for (0..4) |_| {
        const written = linux.write(fd, line.ptr, line.len);
        if (linux.errno(written) == .INTR) continue;
        // A <= PIPE_BUF blocking pipe write is atomic. Never retry a partial
        // write as a suffix, which could interleave with a peer. I/O failure
        // remains best-effort diagnostic loss, not a semantic build result.
        return;
    }
}

/// Worker diagnostics retain their process identity in one bounded write.
pub fn logLine(comptime format: []const u8, args: anytype) void {
    writeDiagnostic(2, linux.getpid(), format, args);
}

/// Parent bundle diagnostics preserve their existing text and parser prefixes.
pub fn printLine(comptime format: []const u8, args: anytype) void {
    writeDiagnostic(2, null, format, args);
}

test "bounded diagnostics retain ordinary text and expose oversized records" {
    var buffer: [diagnostic_record_bytes]u8 = undefined;
    const title = "চিত্র:LL-Q9610 (ben)-Aishik Rehman-ইসবগুল.wav";
    const line = formatDiagnostic(&buffer, 123, "warning: file metadata missing: title={s}\n", .{title});
    try std.testing.expectEqualStrings("pid=123 warning: file metadata missing: title=" ++ title ++ "\n", line);
    const parent = formatDiagnostic(&buffer, null, "bundle expansion failed title={s} stage=expand error={s}\n", .{ "ইষ্টি", "FileMetadataSnapshotMissing" });
    try std.testing.expectEqualStrings("bundle expansion failed title=ইষ্টি stage=expand error=FileMetadataSnapshotMissing\n", parent);
    try std.testing.expectEqualStrings("without newline\n", formatDiagnostic(&buffer, null, "without newline", .{}));
    const huge: [6000]u8 = @splat('x');
    const truncated = formatDiagnostic(&buffer, 123, "large={s}\n", .{&huge});
    try std.testing.expect(truncated.len <= diagnostic_record_bytes);
    try std.testing.expect(std.mem.startsWith(u8, truncated, "pid=123 large=xxx"));
    try std.testing.expect(std.mem.endsWith(u8, truncated, truncation_marker));
}

test "bounded diagnostics never split valid UTF-8 at truncation" {
    const piece = "বাংলা";
    var text: [piece.len * 400]u8 = undefined;
    for (0..400) |i| @memcpy(text[i * piece.len ..][0..piece.len], piece);
    const padding = "0123456789abcdef";
    var buffer: [diagnostic_record_bytes]u8 = undefined;
    for (0..padding.len) |offset| {
        const line = formatDiagnostic(&buffer, 321, "{s}{s}\n", .{ padding[0..offset], &text });
        try std.testing.expect(line.len <= diagnostic_record_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(std.mem.endsWith(u8, line, truncation_marker));
    }
}

test "independent processes preserve complete concurrent diagnostic records" {
    // Four real processes share one blocking pipe. No process-local mutex can
    // serialize this test. Each record is >64 bytes and carries an independently
    // checked writer, sequence and Unicode payload; loss or mixing fails.
    const count = 4;
    const rounds = 64;
    const title_prefix = "চিত্র:";
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS)
        return error.DiagnosticTestPipeFailed;
    defer _ = linux.close(fds[0]);
    var write_open = true;
    defer if (write_open) {
        _ = linux.close(fds[1]);
    };
    var pids: [count]linux.pid_t = @splat(0);
    defer for (&pids) |*pid| {
        if (pid.* != 0) {
            _ = linux.kill(pid.*, .KILL);
            var status: i32 = undefined;
            while (linux.errno(linux.waitpid(pid.*, &status, 0)) == .INTR) {}
        }
    };
    for (0..count) |index| {
        const forked = linux.fork();
        if (linux.errno(forked) != .SUCCESS) return error.DiagnosticTestForkFailed;
        if (forked == 0) {
            _ = linux.close(fds[0]);
            var payload: [2048]u8 = @splat(@as(u8, @intCast('A' + index)));
            @memcpy(payload[0..title_prefix.len], title_prefix);
            for (0..rounds) |sequence|
                writeDiagnostic(fds[1], linux.getpid(), "writer={d} sequence={d} title={s}\n", .{ index, sequence, &payload });
            _ = linux.close(fds[1]);
            linux.exit_group(0);
        }
        pids[index] = @intCast(forked);
    }
    _ = linux.close(fds[1]);
    write_open = false;
    var seen: [count][rounds]bool = @splat(@splat(false));
    var received: usize = 0;
    var line_buffer: [diagnostic_record_bytes]u8 = undefined;
    var line_len: usize = 0;
    var read_buffer: [8192]u8 = undefined;
    while (true) {
        var ready = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&ready, 5_000) == 0) return error.DiagnosticTestTimeout;
        const n = linux.read(fds[0], &read_buffer, read_buffer.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.DiagnosticTestReadFailed;
        if (n == 0) break;
        for (read_buffer[0..n]) |byte| {
            if (byte != '\n') {
                if (line_len == line_buffer.len) return error.DiagnosticTestOversizedLine;
                line_buffer[line_len] = byte;
                line_len += 1;
                continue;
            }
            const line = line_buffer[0..line_len];
            var fields = std.mem.splitScalar(u8, line, ' ');
            const pid_field = fields.next() orelse return error.DiagnosticTestMalformedLine;
            const writer_field = fields.next() orelse return error.DiagnosticTestMalformedLine;
            const sequence_field = fields.next() orelse return error.DiagnosticTestMalformedLine;
            const title = fields.rest();
            try std.testing.expect(std.mem.startsWith(u8, pid_field, "pid="));
            try std.testing.expect(std.mem.startsWith(u8, writer_field, "writer="));
            try std.testing.expect(std.mem.startsWith(u8, sequence_field, "sequence="));
            const index = try std.fmt.parseInt(usize, writer_field["writer=".len..], 10);
            const sequence = try std.fmt.parseInt(usize, sequence_field["sequence=".len..], 10);
            try std.testing.expect(index < count and sequence < rounds);
            try std.testing.expectEqual(pids[index], try std.fmt.parseInt(linux.pid_t, pid_field["pid=".len..], 10));
            try std.testing.expect(!seen[index][sequence]);
            try std.testing.expectEqual(@as(usize, 2048 + "title=".len), title.len);
            try std.testing.expect(std.mem.startsWith(u8, title, "title=" ++ title_prefix));
            for (title["title=".len + title_prefix.len ..]) |value|
                try std.testing.expectEqual(@as(u8, @intCast('A' + index)), value);
            seen[index][sequence] = true;
            received += 1;
            line_len = 0;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), line_len);
    try std.testing.expectEqual(@as(usize, count * rounds), received);
    for (&pids) |*pid| {
        var status: i32 = undefined;
        while (true) {
            const waited = linux.waitpid(pid.*, &status, 0);
            if (linux.errno(waited) == .INTR) continue;
            if (linux.errno(waited) != .SUCCESS) return error.DiagnosticTestWaitFailed;
            pid.* = 0;
            try std.testing.expectEqual(@as(i32, 0), status);
            break;
        }
    }
}

pub const Page = struct {
    native_failures: ?*NativeFailures = null,
    missing_data_requests: ?*MissingDataRequests = null,
    invokes: u64 = 0,
    cache_hits_before: u64 = 0,
    invoke_attempts: u64 = 0,
    module_roots: u64 = 0,
    static_roots: u64 = 0,
    scan_calls: u64 = 0,
    scan_bytes: u64 = 0,
    constructs: u64 = 0,
    comment_bytes: u64 = 0,
    template_preprocess_calls: u64 = 0,
    template_preprocess_bytes: u64 = 0,
    sampled: bool = false,
    context_ns: u64 = 0,
    expand_ns: u64 = 0,
    comments_ns: u64 = 0,
    template_preprocess_ns: u64 = 0,
    invoke_ns: u64 = 0,
    root_profile: ?*RootProfile = null,
    root_sampled: bool = false,
    root_frame: ?*RootFrame = null,
    root_exclusive_ns: u64 = 0,
};

/// Bounded request keys for diagnosing absent external snapshots. Only printable
/// prefixes reach stderr; length and hash distinguish truncated or escaped keys.
const RequestKey = struct {
    len: usize = 0,
    hash: u64 = 0,
    prefix: [64]u8 = @as([64]u8, @splat(0)),

    fn init(value: []const u8) RequestKey {
        var key: RequestKey = .{ .len = value.len, .hash = std.hash.Wyhash.hash(0, value) };
        for (value[0..@min(value.len, key.prefix.len)], 0..) |byte, i|
            key.prefix[i] = if (byte >= 0x21 and byte <= 0x7e) byte else '?';
        return key;
    }

    fn eql(a: RequestKey, b: RequestKey) bool {
        return a.len == b.len and a.hash == b.hash and
            std.mem.eql(u8, &a.prefix, &b.prefix);
    }

    fn visible(self: *const RequestKey) []const u8 {
        return self.prefix[0..@min(self.len, self.prefix.len)];
    }
};

fn RequestBag(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            first: RequestKey = .{},
            second: RequestKey = .{},
            count: u64 = 0,
        };
        entries: [capacity]Entry = @as([capacity]Entry, @splat(.{})),
        len: usize = 0,
        overflow: u64 = 0,

        fn record(self: *Self, first: []const u8, second: []const u8) void {
            const a = RequestKey.init(first);
            const b = RequestKey.init(second);
            for (self.entries[0..self.len]) |*entry| {
                if (entry.first.eql(a) and entry.second.eql(b)) {
                    entry.count +|= 1;
                    return;
                }
            }
            if (self.len == capacity) {
                self.overflow +|= 1;
                return;
            }
            self.entries[self.len] = .{ .first = a, .second = b, .count = 1 };
            self.len += 1;
        }

        fn log(self: *const Self, comptime kind: []const u8) void {
            logLine("external request {s}: distinct={d} overflow={d}\n", .{ kind, self.len, self.overflow });
            for (self.entries[0..self.len]) |*entry| {
                logLine("external request {s}: first={s} first_len={d} first_hash={x} second={s} second_len={d} second_hash={x} count={d}\n", .{
                    kind,                   entry.first.visible(), entry.first.len,   entry.first.hash,
                    entry.second.visible(), entry.second.len,      entry.second.hash, entry.count,
                });
            }
        }
    };
}

pub const MissingDataRequests = struct {
    sitelinks: RequestBag(32) = .{},
    commons: RequestBag(8) = .{},
    categories: RequestBag(8) = .{},

    pub fn log(self: *const MissingDataRequests) void {
        self.sitelinks.log("sitelink");
        self.commons.log("commons");
        self.categories.log("category");
    }
};

pub fn noteSitelink(entity: []const u8, site: []const u8) void {
    const page = active orelse return;
    if (page.missing_data_requests) |requests| requests.sitelinks.record(entity, site);
}

pub fn noteCommons(title: []const u8, language: []const u8) void {
    const page = active orelse return;
    if (page.missing_data_requests) |requests| requests.commons.record(title, language);
}

pub fn noteCategory(key: []const u8, which: []const u8) void {
    const page = active orelse return;
    if (page.missing_data_requests) |requests| requests.categories.record(key, which);
}

/// Diagnostic only: bounded distinct native entry addresses, no per-call output.
pub const NativeFailures = struct {
    const Entry = struct {
        address: usize = 0,
        count: u64 = 0,
    };
    entries: [64]Entry = @as([64]Entry, @splat(.{})),
    len: usize = 0,
    overflow: u64 = 0,

    pub fn record(self: *NativeFailures, address: usize) void {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.address == address) {
                entry.count +|= 1;
                return;
            }
        }
        if (self.len == self.entries.len) {
            self.overflow +|= 1;
            return;
        }
        self.entries[self.len] = .{ .address = address, .count = 1 };
        self.len += 1;
    }

    pub fn log(self: *const NativeFailures) void {
        logLine("native NotImplemented failures: distinct={d} overflow={d}\n", .{ self.len, self.overflow });
        for (self.entries[0..self.len]) |entry|
            logLine("native NotImplemented entry: address=0x{x} count={d}\n", .{ entry.address, entry.count });
    }
};

pub fn noteNativeFailure(address: usize, name: []const u8) void {
    if (!std.mem.eql(u8, name, "NotImplemented")) return;
    const page = active orelse return;
    if (page.native_failures) |failures| failures.record(address);
}

/// Worker-lifetime aggregation of caught pcall diagnostics. These are Lua
/// results, not uncaught build failures. Exact bounded keys own their page text;
/// excess or oversized keys retain ordinary diagnostics and an untracked count.
pub const ProtectedCalls = struct {
    pub const entry_limit = 16;
    pub const detail_limit = 512;
    const kind_limit = 32;
    const Entry = struct {
        err: anyerror,
        kind: [kind_limit]u8,
        kind_len: u8,
        detail: [detail_limit]u8,
        detail_len: u16,
        count: u64 = 1,
    };
    const Notice = enum { none, example, overflow };

    entries: [entry_limit]Entry = undefined,
    len: usize = 0,
    total: u64 = 0,
    tracked: u64 = 0,
    untracked: u64 = 0,
    counter_overflow: bool = false,
    overflow_reported: bool = false,

    fn increment(self: *ProtectedCalls, counter: *u64) void {
        if (counter.* == std.math.maxInt(u64)) {
            self.counter_overflow = true;
        } else counter.* += 1;
    }

    fn record(self: *ProtectedCalls, err: anyerror, kind: []const u8, detail: []const u8) Notice {
        self.increment(&self.total);
        for (self.entries[0..self.len]) |*entry| {
            if (entry.err == err and
                std.mem.eql(u8, entry.kind[0..entry.kind_len], kind) and
                std.mem.eql(u8, entry.detail[0..entry.detail_len], detail))
            {
                self.increment(&entry.count);
                self.increment(&self.tracked);
                return .none;
            }
        }
        if (self.len == entry_limit or kind.len > kind_limit or detail.len > detail_limit) {
            self.increment(&self.untracked);
            if (self.overflow_reported) return .example;
            self.overflow_reported = true;
            return .overflow;
        }
        const entry = &self.entries[self.len];
        entry.* = .{
            .err = err,
            .kind = undefined,
            .kind_len = @intCast(kind.len),
            .detail = undefined,
            .detail_len = @intCast(detail.len),
        };
        @memcpy(entry.kind[0..kind.len], kind);
        @memcpy(entry.detail[0..detail.len], detail);
        self.len += 1;
        self.increment(&self.tracked);
        return .example;
    }

    pub fn note(self: *ProtectedCalls, err: anyerror, kind: []const u8, detail: []const u8) void {
        self.noteToFd(2, err, kind, detail);
    }

    fn noteToFd(self: *ProtectedCalls, fd: linux.fd_t, err: anyerror, kind: []const u8, detail: []const u8) void {
        const notice = self.record(err, kind, detail);
        if (notice == .none) return;
        if (notice == .overflow)
            writeDiagnostic(fd, linux.getpid(), "protected Lua call profile overflow: untracked_events_logged=true entry_limit={d} kind_limit={d} detail_limit={d}\n", .{ entry_limit, kind_limit, detail_limit });
        // Only an exact retained key may suppress an event. Untracked details
        // keep the ordinary bounded writer, including its truncation marker.
        writeDiagnostic(fd, linux.getpid(), "protected Lua call failed: error={s} value_kind={s} detail={s}\n", .{ @errorName(err), kind, detail });
    }

    pub fn log(self: *const ProtectedCalls) void {
        logLine("worker protected calls: total={d} tracked={d} untracked={d} tracked_distinct={d} counter_overflow={} entry_limit={d} detail_limit={d}\n", .{
            self.total, self.tracked, self.untracked, self.len, self.counter_overflow, entry_limit, detail_limit,
        });
        for (self.entries[0..self.len]) |entry| {
            logLine("worker protected call count: count={d} error={s} value_kind={s} detail={s}\n", .{
                entry.count, @errorName(entry.err), entry.kind[0..entry.kind_len], entry.detail[0..entry.detail_len],
            });
        }
    }
};

test "protected call profile owns keys and aggregates repeated events" {
    var profile: ProtectedCalls = .{};
    var kind = "string".*;
    var detail = "TableExpected".*;
    try std.testing.expectEqual(ProtectedCalls.Notice.example, profile.record(error.AotCallFailed, &kind, &detail));
    @memset(&kind, 'x');
    @memset(&detail, 'x');
    for (0..99_999) |_| try std.testing.expectEqual(ProtectedCalls.Notice.none, profile.record(error.AotCallFailed, "string", "TableExpected"));
    try std.testing.expectEqual(@as(usize, 1), profile.len);
    try std.testing.expectEqual(@as(u64, 100_000), profile.total);
    try std.testing.expectEqual(profile.total, profile.tracked);
    try std.testing.expectEqual(profile.total, profile.entries[0].count);
    try std.testing.expectEqual(@as(u64, 0), profile.untracked);
    try std.testing.expect(!profile.counter_overflow);
    try std.testing.expectEqualStrings("TableExpected", profile.entries[0].detail[0..profile.entries[0].detail_len]);
}

test "protected call profile deduplicates tracked keys and preserves untracked diagnostics" {
    const Capture = struct {
        fn note(profile: *ProtectedCalls, kind: []const u8, detail: []const u8, buffer: *[2048]u8) ![]const u8 {
            // Each selected event is under 1 KiB, including its optional notice.
            // A private pipe observes the real writer without replacing stderr.
            var fds: [2]linux.fd_t = undefined;
            if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS)
                return error.DiagnosticTestPipeFailed;
            defer _ = linux.close(fds[0]);
            profile.noteToFd(fds[1], error.LuaRaised, kind, detail);
            _ = linux.close(fds[1]);
            var used: usize = 0;
            while (true) {
                if (used == buffer.len) return error.DiagnosticTestOversizedLine;
                const n = linux.read(fds[0], buffer[used..].ptr, buffer.len - used);
                if (linux.errno(n) == .INTR) continue;
                if (linux.errno(n) != .SUCCESS) return error.DiagnosticTestReadFailed;
                if (n == 0) break;
                used += n;
            }
            return buffer[0..used];
        }
    };
    var profile: ProtectedCalls = .{};
    var buffer: [32]u8 = undefined;
    for (0..ProtectedCalls.entry_limit) |index| {
        const detail = try std.fmt.bufPrint(&buffer, "failure-{d}", .{index});
        try std.testing.expectEqual(ProtectedCalls.Notice.example, profile.record(error.LuaRaised, "string", detail));
    }
    var output: [2048]u8 = undefined;
    const first = try Capture.note(&profile, "string", "beyond-capacity", &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "protected Lua call profile overflow:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "protected Lua call failed:"));
    try std.testing.expect(std.mem.endsWith(u8, first, "detail=beyond-capacity\n"));
    const distinct = try Capture.note(&profile, "string", "different-untracked-detail", &output);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, distinct, "protected Lua call profile overflow:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, distinct, "protected Lua call failed:"));
    try std.testing.expect(std.mem.endsWith(u8, distinct, "detail=different-untracked-detail\n"));
    const repeated = try Capture.note(&profile, "string", "beyond-capacity", &output);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, repeated, "protected Lua call profile overflow:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, repeated, "protected Lua call failed:"));
    try std.testing.expect(std.mem.endsWith(u8, repeated, "detail=beyond-capacity\n"));
    for (0..97) |_| try std.testing.expectEqual(ProtectedCalls.Notice.example, profile.record(error.LuaRaised, "string", "beyond-capacity"));
    try std.testing.expectEqual(@as(usize, 0), (try Capture.note(&profile, "string", "failure-0", &output)).len);
    try std.testing.expectEqual(@as(usize, ProtectedCalls.entry_limit), profile.len);
    try std.testing.expectEqual(@as(u64, 100), profile.untracked);
    try std.testing.expectEqual(@as(u64, ProtectedCalls.entry_limit + 1), profile.tracked);
    try std.testing.expectEqual(profile.tracked + profile.untracked, profile.total);
    try std.testing.expectEqual(@as(u64, 2), profile.entries[0].count);

    var oversized: ProtectedCalls = .{};
    const long: [ProtectedCalls.detail_limit + 1]u8 = @splat('q');
    const oversized_first = try Capture.note(&oversized, "string", &long, &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, oversized_first, "protected Lua call profile overflow:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, oversized_first, "protected Lua call failed:"));
    try std.testing.expect(std.mem.indexOf(u8, oversized_first, &long) != null);
    var other_long = long;
    other_long[other_long.len - 1] = 'r';
    const oversized_distinct = try Capture.note(&oversized, "string", &other_long, &output);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, oversized_distinct, "protected Lua call profile overflow:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, oversized_distinct, "protected Lua call failed:"));
    try std.testing.expect(std.mem.indexOf(u8, oversized_distinct, &other_long) != null);
    // A long key must not consume a tracked slot or merge into its prefix.
    try std.testing.expectEqual(ProtectedCalls.Notice.example, oversized.record(error.LuaRaised, "string", long[0..ProtectedCalls.detail_limit]));
    try std.testing.expectEqual(@as(u64, 2), oversized.untracked);
    try std.testing.expectEqual(@as(u64, 1), oversized.tracked);
    try std.testing.expectEqual(@as(usize, 1), oversized.len);
    const long_kind: [ProtectedCalls.kind_limit + 1]u8 = @splat('k');
    const oversized_kind = try Capture.note(&oversized, &long_kind, "oversized-kind", &output);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, oversized_kind, "protected Lua call profile overflow:"));
    try std.testing.expect(std.mem.indexOf(u8, oversized_kind, &long_kind) != null);
    try std.testing.expect(std.mem.endsWith(u8, oversized_kind, "detail=oversized-kind\n"));
    try std.testing.expectEqual(@as(u64, 3), oversized.untracked);
    try std.testing.expectEqual(@as(usize, 1), oversized.len);

    profile.total = std.math.maxInt(u64);
    profile.tracked = std.math.maxInt(u64);
    profile.entries[0].count = std.math.maxInt(u64);
    _ = profile.record(error.LuaRaised, "string", "failure-0");
    try std.testing.expect(profile.counter_overflow);
    try std.testing.expectEqual(std.math.maxInt(u64), profile.total);
    try std.testing.expectEqual(std.math.maxInt(u64), profile.entries[0].count);
}

/// Module-root calls are counted on every page; CPU time is sampled on 1/32 pages.
pub const RootProfile = struct {
    allocator: std.mem.Allocator,
    hits: []u64,
    exclusive_ns: []u64,
    sampled_pages: u64 = 0,
    protected_calls: ProtectedCalls = .{},

    pub fn init(allocator: std.mem.Allocator, module_count: usize) !RootProfile {
        const hits = try allocator.alloc(u64, module_count);
        errdefer allocator.free(hits);
        const exclusive_ns = try allocator.alloc(u64, module_count);
        @memset(hits, 0);
        @memset(exclusive_ns, 0);
        return .{ .allocator = allocator, .hits = hits, .exclusive_ns = exclusive_ns };
    }

    pub fn deinit(self: *RootProfile) void {
        self.allocator.free(self.hits);
        self.allocator.free(self.exclusive_ns);
        self.* = undefined;
    }

    pub fn logTop(self: *const RootProfile, names: []const []const u8, total_ns: u64) void {
        self.protected_calls.log();
        logLine("worker module roots: cpu_sample_interval=32 sampled_pages={d} exclusive_ns={d} modules={d}\n", .{
            self.sampled_pages, total_ns, self.hits.len,
        });
        var selected: [16]usize = undefined;
        var selected_len: usize = 0;
        while (selected_len < selected.len) {
            var best: ?usize = null;
            for (self.exclusive_ns, 0..) |ns, id| {
                if (ns == 0) continue;
                var already_selected = false;
                for (selected[0..selected_len]) |prior| {
                    if (prior == id) {
                        already_selected = true;
                        break;
                    }
                }
                if (already_selected) continue;
                if (best) |prior| {
                    if (ns < self.exclusive_ns[prior] or
                        (ns == self.exclusive_ns[prior] and self.hits[id] <= self.hits[prior])) continue;
                }
                best = id;
            }
            const id = best orelse break;
            selected[selected_len] = id;
            selected_len += 1;
            const name = if (id < names.len) names[id] else "";
            logLine("worker module root top: rank={d} id={d} hits={d} sampled_exclusive_ns={d} name={s}\n", .{
                selected_len, id, self.hits[id], self.exclusive_ns[id], name[0..@min(name.len, 512)],
            });
        }
    }
};

pub const RootFrame = struct {
    page: ?*Page = null,
    parent: ?*RootFrame = null,
    module_id: u32 = 0,
    start_ns: ?u64 = null,
    child_ns: u64 = 0,
};

pub fn beginRoot(frame: *RootFrame, module_id: u32) void {
    const page = active orelse return;
    const profile = page.root_profile orelse return;
    if (module_id >= profile.hits.len) return;
    profile.hits[module_id] +|= 1;
    frame.* = .{ .page = page, .module_id = module_id };
    if (!page.root_sampled) return;
    frame.start_ns = processCpuNow() orelse return;
    frame.parent = page.root_frame;
    page.root_frame = frame;
}

pub fn endRoot(frame: *RootFrame) void {
    const page = frame.page orelse return;
    const start = frame.start_ns orelse return;
    page.root_frame = frame.parent;
    const now = processCpuNow() orelse return;
    const elapsed_ns = now -| start;
    const exclusive_ns = elapsed_ns -| frame.child_ns;
    page.root_profile.?.exclusive_ns[frame.module_id] +|= exclusive_ns;
    page.root_exclusive_ns +|= exclusive_ns;
    if (frame.parent) |parent| parent.child_ns +|= elapsed_ns;
}

threadlocal var active: ?*Page = null;

pub fn begin(page: *Page) ?*Page {
    const previous = active;
    active = page;
    return previous;
}

pub fn end(previous: ?*Page) void {
    active = previous;
}

pub fn current() ?*Page {
    return active;
}

pub fn cpuNow() ?u64 {
    const page = active orelse return null;
    if (!page.sampled) return null;
    return processCpuNow();
}

/// Full worker process CPU clock, independent of page timing cohorts.
pub fn processCpuNow() ?u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.PROCESS_CPUTIME_ID, &ts)) != .SUCCESS) return null;
    const seconds = std.math.cast(u64, ts.sec) orelse return null;
    const nanos = std.math.cast(u64, ts.nsec) orelse return null;
    return std.math.add(u64, std.math.mul(u64, seconds, 1_000_000_000) catch return null, nanos) catch null;
}

pub fn elapsed(start: ?u64) u64 {
    const before = start orelse return 0;
    const after = cpuNow() orelse return 0;
    return after -| before;
}

// Shared parent profiling primitives; process CPU remains separate below.
// Process CPU would charge concurrent protocol threads to the consumer too.
pub fn threadCpuNow() ?u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.THREAD_CPUTIME_ID, &ts)) != .SUCCESS) return null;
    const seconds = std.math.cast(u64, ts.sec) orelse return null;
    const nanos = std.math.cast(u64, ts.nsec) orelse return null;
    return std.math.add(u64, std.math.mul(u64, seconds, std.time.ns_per_s) catch return null, nanos) catch null;
}

pub const PhaseStamp = struct {
    cpu_ns: ?u64,
    wall_ns: i128,

    pub fn now(io: std.Io) PhaseStamp {
        return .{ .cpu_ns = threadCpuNow(), .wall_ns = std.Io.Clock.awake.now(io).toNanoseconds() };
    }
};

pub const PhaseTotals = struct {
    calls: u64 = 0,
    cpu_ns: u64 = 0,
    wall_ns: u64 = 0,
    cpu_clock_misses: u64 = 0,

    pub fn record(self: *PhaseTotals, started: PhaseStamp, stopped: PhaseStamp) void {
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

    pub fn merge(self: *PhaseTotals, other: PhaseTotals) void {
        self.calls +|= other.calls;
        self.cpu_ns +|= other.cpu_ns;
        self.wall_ns +|= other.wall_ns;
        self.cpu_clock_misses +|= other.cpu_clock_misses;
    }

    pub fn cpuStatus(self: PhaseTotals) []const u8 {
        if (self.calls == 0) return "unmeasured";
        if (self.cpu_clock_misses == self.calls) return "unavailable";
        return if (self.cpu_clock_misses == 0) "available" else "partial";
    }

    pub fn log(self: PhaseTotals, phase: []const u8) void {
        printLine("parent phase profile: phase={s} calls={d} thread_cpu_ns={d} wall_ns={d} cpu_clock_misses={d} wall_semantics=sum-of-calls\n", .{
            phase, self.calls, self.cpu_ns, self.wall_ns, self.cpu_clock_misses,
        });
    }
};


// Enabled only around synchronous parent consumption; protocol workers use
// separate thread-local state. Uncovered consumer work remains in the aggregate.
pub const ConsumePhase = enum { presentation, codec, spool, organization, heading_observation, scope_observation };
pub const ConsumePhaseTotals = struct {
    totals: [@typeInfo(ConsumePhase).@"enum".field_names.len]PhaseTotals = @splat(.{}),
    active: ?ConsumePhase = null,
    started: ?PhaseStamp = null,
    fn phase(self: *ConsumePhaseTotals, io: std.Io, next: ?ConsumePhase) void {
        if (self.active == next) return;
        const now = PhaseStamp.now(io);
        if (self.active) |active_phase| self.totals[@intFromEnum(active_phase)].record(self.started.?, now);
        self.active = next;
        self.started = if (next != null) now else null;
    }
    pub fn merge(self: *ConsumePhaseTotals, other: ConsumePhaseTotals) void {
        for (&self.totals, other.totals) |*total, value| total.merge(value);
    }
    pub fn log(self: ConsumePhaseTotals) void {
        const phase_info = @typeInfo(ConsumePhase).@"enum";
        inline for (phase_info.field_names, phase_info.field_values) |field_name, field_value| {
            const total = self.totals[field_value];
            printLine("parent consume phase profile: phase={s} segments={d} thread_cpu_ns={d} thread_cpu_status={s} wall_ns={d} cpu_clock_misses={d} wall_semantics=exclusive-sum-of-scoped-intervals\n", .{
                field_name, total.calls, total.cpu_ns, total.cpuStatus(), total.wall_ns, total.cpu_clock_misses,
            });
        }
    }
};
pub const ConsumeContext = struct { io: std.Io, totals: *ConsumePhaseTotals };
threadlocal var parent_consume_context: ?ConsumeContext = null;
pub fn setParentConsumeProfile(context: ?ConsumeContext) ?ConsumeContext {
    const previous = parent_consume_context;
    parent_consume_context = context;
    return previous;
}
pub const ConsumeScope = struct { context: ConsumeContext, previous: ?ConsumePhase };
pub fn beginConsumePhase(phase: ConsumePhase) ?ConsumeScope {
    const context = parent_consume_context orelse return null;
    const previous = context.totals.active;
    context.totals.phase(context.io, phase);
    return .{ .context = context, .previous = previous };
}
pub fn endConsumePhase(scope: ?ConsumeScope) void {
    if (scope) |value| value.context.totals.phase(value.context.io, value.previous);
}
