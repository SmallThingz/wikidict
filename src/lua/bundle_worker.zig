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

const Expansion = struct {
    output: []const u8,
    display_title: []const u8,
};

fn limit(resource: std.posix.rlimit_resource, value: u64) !void {
    const old = try std.posix.getrlimit(resource);
    const n = @min(value, old.max);
    try std.posix.setrlimit(resource, .{ .cur = @intCast(n), .max = @intCast(n) });
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

    fn expand(self: *Engine, page_a: A, request: Request, stage: *[]const u8, detail: *?[]const u8) !Expansion {
        if (!std.mem.eql(u8, request.root, self.requested_root)) return error.BundleRootChanged;
        if (!std.mem.eql(u8, request.dump, self.requested_dump)) return error.BundleDumpChanged;
        if (request.now_unix != self.requested_now_unix) return error.BundleTimeChanged;
        stage.* = "install";
        var ctx = try self.program.initContext(page_a);
        defer ctx.deinit();
        var expander = lua_program.initExpander(&ctx, self.provider.api());
        stage.* = "expand";
        const output = expander.expandFragment(request.title, request.source, self.requested_now_unix) catch |err| {
            detail.* = try page_a.dupe(u8, ctx.aotErrorName() orelse @errorName(err));
            return err;
        };
        return .{ .output = output, .display_title = expander.display_title orelse "" };
    }
};

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
        if (length == 0 or length > protocol.max_frame_bytes) return error.InvalidFrame;
        var page = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer page.deinit();
        const page_a = page.allocator();
        const bytes = try page_a.alloc(u8, length);
        try input.interface.readSliceAll(bytes);
        const request = protocol.decodeRequest(bytes) catch |err| {
            try protocol.writeError(&output.interface, "request", @errorName(err), "");
            continue;
        };
        if (engine == null) {
            engine = Engine.init(io, persistent, request.root, request.dump, request.now_unix) catch |err| {
                try protocol.writeError(&output.interface, "assets", @errorName(err), "");
                continue;
            };
        }
        var stage: []const u8 = "expand";
        var detail: ?[]const u8 = null;
        const expanded = engine.?.expand(page_a, request, &stage, &detail) catch |err| {
            try protocol.writeError(&output.interface, stage, detail orelse @errorName(err), detail orelse "");
            continue;
        };
        if (expanded.output.len > protocol.max_source_bytes or expanded.display_title.len > protocol.max_display_title_bytes) {
            try protocol.writeError(&output.interface, stage, "ExpandedSourceTooLarge", "");
            continue;
        }
        try protocol.writeSuccess(&output.interface, expanded.output, expanded.display_title);
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
