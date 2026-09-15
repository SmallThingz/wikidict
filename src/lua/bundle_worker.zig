//! Build-only native Lua/template expansion worker. This binary is never shipped.
const std = @import("std");
const lua_program = @import("lua_program");
const llvm_abi = @import("lua_llvm_abi");
comptime {
    _ = llvm_abi;
}
const pages = @import("bundle_pages.zig");
const protocol = @import("bundle_protocol.zig");
const A = std.mem.Allocator;
const L = std.os.linux;

pub const Request = protocol.Request;
pub const Reply = protocol.Reply;

fn limit(resource: std.posix.rlimit_resource, value: u64) !void {
    const old = try std.posix.getrlimit(resource);
    const n = @min(value, old.max);
    try std.posix.setrlimit(resource, .{ .cur = @intCast(n), .max = @intCast(n) });
}

fn validateRequest(request: Request) !void {
    if (request.source.len > 16 * 1024 * 1024 or request.root.len == 0 or request.root.len > 4096 or request.dump.len == 0 or request.dump.len > 4096 or request.title.len == 0 or request.title.len > 4096) return error.InvalidRequest;
}

const Engine = struct {
    io: std.Io,
    requested_root: []const u8,
    requested_dump: []const u8,
    requested_now_unix: i64,
    program: lua_program.Program,
    provider: pages.Provider,

    fn fileExists(io: std.Io, path: []const u8) !bool {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(io);
        return true;
    }

    fn init(io: std.Io, a: A, requested_root: []const u8, requested_dump: []const u8, requested_now_unix: i64) !Engine {
        const marker = try std.fs.path.join(a, &.{ requested_root, ".incomplete" });
        if (try fileExists(io, marker)) return error.BundleAssetsIncomplete;
        const manifest = try std.fs.path.join(a, &.{ requested_root, "manifest.jsonl" });
        if (!try fileExists(io, manifest)) return error.BundleAssetsMissing;
        var program = try lua_program.Program.init(a);
        errdefer program.deinit();
        var provider = try pages.Provider.init(io, a, requested_root, requested_dump);
        errdefer provider.deinit();
        return .{
            .io = io,
            .requested_root = try a.dupe(u8, requested_root),
            .requested_dump = try a.dupe(u8, requested_dump),
            .requested_now_unix = requested_now_unix,
            .program = program,
            .provider = provider,
        };
    }

    fn deinit(self: *Engine) void {
        self.provider.deinit();
        self.program.deinit();
    }

    fn expand(self: *Engine, page_a: A, request: Request, stage: *[]const u8, detail: *?[]const u8) ![]const u8 {
        if (!std.mem.eql(u8, request.root, self.requested_root)) return error.BundleRootChanged;
        if (!std.mem.eql(u8, request.dump, self.requested_dump)) return error.BundleDumpChanged;
        if (request.now_unix != self.requested_now_unix) return error.BundleTimeChanged;
        stage.* = "install";
        var ctx = try self.program.initContext(page_a);
        defer ctx.deinit();
        var expander = lua_program.initExpander(&ctx, self.provider.api());
        stage.* = "expand";
        return expander.expandFragment(request.title, request.source, self.requested_now_unix) catch |err| {
            detail.* = try page_a.dupe(u8, ctx.aotErrorName() orelse @errorName(err));
            return err;
        };
    }
};

fn writeFrame(w: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > 32 * 1024 * 1024) return error.FrameTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    try w.writeAll(&length);
    try w.writeAll(bytes);
    try w.flush();
}

pub fn run(io: std.Io, persistent: A) !void {
    try limit(.CORE, 0);
    if (L.errno(L.prctl(@intFromEnum(L.PR.SET_PDEATHSIG), @intFromEnum(L.SIG.KILL), 0, 0, 0)) != .SUCCESS) return error.ParentDeathSignalFailed;
    if (L.getppid() == 1) return error.ParentExited;
    try limit(.AS, 4 * 1024 * 1024 * 1024);
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
        if (length == 0 or length > 32 * 1024 * 1024) return error.InvalidFrame;
        var page = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer page.deinit();
        const page_a = page.allocator();
        const bytes = try page_a.alloc(u8, length);
        try input.interface.readSliceAll(bytes);
        var reply: Reply = .{};
        const parsed = std.json.parseFromSlice(Request, page_a, bytes, .{}) catch |err| {
            reply.stage = "request";
            reply.error_name = @errorName(err);
            try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
            continue;
        };
        const request = parsed.value;
        validateRequest(request) catch |err| {
            reply.stage = "request";
            reply.error_name = @errorName(err);
            try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
            continue;
        };
        if (engine == null) {
            reply.stage = "assets";
            engine = Engine.init(io, persistent, request.root, request.dump, request.now_unix) catch |err| {
                reply.error_name = @errorName(err);
                try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
                continue;
            };
        }
        reply.output = engine.?.expand(page_a, request, &reply.stage, &reply.detail) catch |err| blk: {
            reply.error_name = reply.detail orelse @errorName(err);
            break :blk null;
        };
        if (reply.output) |text| if (text.len > 16 * 1024 * 1024) {
            reply.output = null;
            reply.error_name = "ExpandedSourceTooLarge";
        };
        try writeFrame(&output.interface, try std.json.Stringify.valueAlloc(page_a, reply, .{}));
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
