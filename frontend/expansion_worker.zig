//! Lua expansion worker. CLI calls use one-shot mode; the live server keeps one
//! framed worker alive so linked runtime assets are loaded only once.
const std = @import("std");
const bridge = @import("runtime_bridge");
const linked_runtime = @import("linked_runtime.zig");
const pages = @import("runtime_pages.zig");
const A = std.mem.Allocator;
const L = std.os.linux;
pub const Request = struct { root: []const u8, title: []const u8, source: []const u8, dictionary_root: ?[]const u8 = null, language: []const u8 = "English" };
pub const Reply = struct {
    schema: []const u8 = "dict.expansion.v1",
    backend: []const u8 = "lua-vm",
    output: ?[]const u8 = null,
    stage: []const u8 = "expand",
    error_name: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};
fn limit(resource: std.posix.rlimit_resource, value: u64) !void {
    const old = try std.posix.getrlimit(resource);
    const n = @min(value, old.max);
    try std.posix.setrlimit(resource, .{ .cur = @intCast(n), .max = @intCast(n) });
}
fn optionalFile(io: std.Io, path: []const u8) !bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    f.close(io);
    return true;
}
const Engine = struct {
    io: std.Io,
    requested_root: []const u8,
    root: []const u8,
    runtime: bridge.Runtime,
    linked: ?linked_runtime.Session,
    fn init(io: std.Io, a: A, requested_root: []const u8) !Engine {
        if (try optionalFile(io, try std.fs.path.join(a, &.{ requested_root, ".incomplete" }))) return error.RuntimeBuildIncomplete;
        const root = try linked_runtime.rootAlloc(io, a, requested_root);
        if (try optionalFile(io, try std.fs.path.join(a, &.{ root, ".incomplete" }))) return error.RuntimeBuildIncomplete;
        const modules = try std.fs.path.join(a, &.{ root, "modules" });
        var runtime = bridge.Runtime.init(a, io, modules);
        var linked = try linked_runtime.load(&runtime, root);
        errdefer if (linked) |*state| state.deinit();
        if (linked == null) {
            try runtime.loadSiblingTemplates();
            const manifest = try std.fs.path.join(a, &.{ requested_root, "manifest.jsonl" });
            if (try optionalFile(io, manifest)) {
                try runtime.loadManifest(manifest);
                try runtime.loadBundle(try std.fs.path.join(a, &.{ requested_root, "modules.bundle" }));
            }
            const dependencies = try std.fs.path.join(a, &.{ requested_root, "dependencies", "manifest.jsonl" });
            if (try optionalFile(io, dependencies)) {
                try runtime.loadManifest(dependencies);
                const bundle_bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ requested_root, "dependencies", "modules.bundle" }), a, .limited(128 * 1024 * 1024));
                try bridge.loadAdditionalBundle(&runtime, bundle_bytes);
            }
        }
        const extracted_redirects = try std.fs.path.join(a, &.{ root, "module-redirects.tsv" });
        if (try optionalFile(io, extracted_redirects)) try runtime.loadRedirects(extracted_redirects);
        const redirects = try std.fs.path.join(a, &.{ root, "usage.tsv" });
        if (try optionalFile(io, redirects)) try runtime.loadRedirects(redirects);
        if (try optionalFile(io, try std.fs.path.join(a, &.{ root, "wikibase-sitelinks.tsv" }))) try runtime.loadSiblingWikibaseSitelinks();
        if (try optionalFile(io, try std.fs.path.join(a, &.{ root, "interwiki-map.tsv" }))) try runtime.loadSiblingInterwikiMap();
        return .{ .io = io, .requested_root = try a.dupe(u8, requested_root), .root = root, .runtime = runtime, .linked = linked };
    }
    fn deinit(self: *Engine) void {
        if (self.linked) |*state| state.deinit();
    }
    fn expand(self: *Engine, page_a: A, request: Request, stage: *[]const u8, detail: *?[]const u8) ![]const u8 {
        if (!std.mem.eql(u8, request.root, self.requested_root)) return error.RuntimeRootChanged;
        var provider = try pages.Provider.init(self.io, page_a, &self.runtime, self.root, request.dictionary_root, request.language);
        defer provider.deinit();
        provider.attach();
        defer self.runtime.page_content_provider = null;
        stage.* = "install";
        self.runtime.beginPage(page_a, request.title);
        var vm = try bridge.Vm.init(page_a);
        try self.runtime.install(&vm);
        stage.* = "expand";
        return self.runtime.expandFragment(&vm, request.title, request.source) catch |err| {
            const diagnostic: ?[]const u8 = if (vm.last_error == .string) vm.last_error.string else self.runtime.last_missing_module orelse self.runtime.last_missing_template orelse self.runtime.last_missing_wikibase orelse self.runtime.last_not_implemented orelse self.runtime.last_unsupported_parser;
            detail.* = if (diagnostic) |text| try page_a.dupe(u8, text) else null;
            return err;
        };
    }
};
fn oneShot(init: std.process.Init, request: Request, stage: *[]const u8, detail: *?[]const u8) ![]const u8 {
    stage.* = "assets";
    var engine = try Engine.init(init.io, init.arena.allocator(), request.root);
    defer engine.deinit();
    const output = try engine.expand(init.arena.allocator(), request, stage, detail);
    return init.arena.allocator().dupe(u8, output);
}
fn validateRequest(request: Request) !void {
    if (request.source.len > 16 * 1024 * 1024 or request.root.len == 0 or request.root.len > 4096 or request.title.len == 0 or request.title.len > 4096 or request.language.len > 4096) return error.InvalidRequest;
}
fn replyFor(init: std.process.Init, request: Request) !Reply {
    try validateRequest(request);
    var reply: Reply = .{};
    reply.output = oneShot(init, request, &reply.stage, &reply.detail) catch |err| blk: {
        reply.error_name = @errorName(err);
        break :blk null;
    };
    if (reply.output) |text| if (text.len > 16 * 1024 * 1024) return error.ExpandedSourceTooLarge;
    return reply;
}
pub fn main(init: std.process.Init) !void {
    // These are resource limits, not a security sandbox. Runtime assets must be trusted.
    try limit(.CORE, 0);
    try limit(.AS, 2 * 1024 * 1024 * 1024);
    try limit(.CPU, 60);
    const a = init.arena.allocator();
    var buf: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buf);
    const bytes = try input.interface.allocRemaining(a, .limited(32 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(Request, a, bytes, .{});
    const reply = try replyFor(init, parsed.value);
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try std.json.Stringify.value(reply, .{}, &out.interface);
    try out.interface.flush();
}
fn writeFrame(w: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > 32 * 1024 * 1024) return error.FrameTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    try w.writeAll(&length);
    try w.writeAll(bytes);
    try w.flush();
}
/// Persistent protocol: little-endian u32 byte length followed by compact JSON.
/// The engine allocator lives for the worker; each request has a fresh page arena.
pub fn loop(init: std.process.Init) !void {
    try limit(.CORE, 0);
    // A server crash must not leave a CPU-bound VM child orphaned.
    if (L.errno(L.prctl(@intFromEnum(L.PR.SET_PDEATHSIG), @intFromEnum(L.SIG.KILL), 0, 0, 0)) != .SUCCESS) return error.ParentDeathSignalFailed;
    if (L.getppid() == 1) return error.ParentExited;
    try limit(.AS, 2 * 1024 * 1024 * 1024);
    const persistent = init.arena.allocator();
    var engine: ?Engine = null;
    defer if (engine) |*value| value.deinit();
    var in_buf: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    var out_buf: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &out_buf);
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
            const encoded = try std.json.Stringify.valueAlloc(page_a, reply, .{});
            try writeFrame(&output.interface, encoded);
            continue;
        };
        const request = parsed.value;
        validateRequest(request) catch |err| {
            reply.stage = "request";
            reply.error_name = @errorName(err);
            const encoded = try std.json.Stringify.valueAlloc(page_a, reply, .{});
            try writeFrame(&output.interface, encoded);
            continue;
        };
        if (engine == null) {
            reply.stage = "assets";
            engine = Engine.init(init.io, persistent, request.root) catch |err| {
                reply.error_name = @errorName(err);
                const encoded = try std.json.Stringify.valueAlloc(page_a, reply, .{});
                try writeFrame(&output.interface, encoded);
                continue;
            };
        }
        reply.output = engine.?.expand(page_a, request, &reply.stage, &reply.detail) catch |err| blk: {
            reply.error_name = @errorName(err);
            break :blk null;
        };
        if (reply.output) |text| if (text.len > 16 * 1024 * 1024) {
            reply.output = null;
            reply.error_name = "ExpandedSourceTooLarge";
        };
        const encoded = try std.json.Stringify.valueAlloc(page_a, reply, .{});
        try writeFrame(&output.interface, encoded);
    }
}
