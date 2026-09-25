//! Build-worker-only, request-scoped counters. The worker processes one request
//! at a time; forked Lua contexts execute on the same thread.
const std = @import("std");
const linux = std.os.linux;

/// Emit one bounded stderr record so concurrent workers cannot interleave its bytes.
pub fn logLine(comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "pid={d} ", .{linux.getpid()}) catch return;
    const body = std.fmt.bufPrint(buffer[prefix.len..], format, args) catch return;
    const line = buffer[0 .. prefix.len + body.len];
    for (0..4) |_| {
        const written = linux.write(2, line.ptr, line.len);
        if (linux.errno(written) == .INTR) continue;
        // A <= PIPE_BUF blocking pipe write is atomic. Do not split a partial
        // write into another syscall, which could interleave with a peer.
        return;
    }
}

pub const Page = struct {
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

/// Module-root calls are counted on every page; CPU time is sampled on 1/32 pages.
pub const RootProfile = struct {
    allocator: std.mem.Allocator,
    hits: []u64,
    exclusive_ns: []u64,
    sampled_pages: u64 = 0,

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
    frame.start_ns = rawCpuNow() orelse return;
    frame.parent = page.root_frame;
    page.root_frame = frame;
}

pub fn endRoot(frame: *RootFrame) void {
    const page = frame.page orelse return;
    const start = frame.start_ns orelse return;
    page.root_frame = frame.parent;
    const now = rawCpuNow() orelse return;
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
    return rawCpuNow();
}

fn rawCpuNow() ?u64 {
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
