//! One page per subprocess: contain failures and temporary allocations in the evolving VM.
const std = @import("std");
const bridge = @import("runtime_bridge");
pub const Request = struct { root: []const u8, title: []const u8, source: []const u8 };
pub const Reply = struct {
    schema: []const u8 = "dict.expansion.v1",
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
fn expand(init: std.process.Init, request: Request, stage: *[]const u8, detail: *?[]const u8) ![]const u8 {
    const a = init.arena.allocator();
    stage.* = "assets";
    if (try optionalFile(init.io, try std.fs.path.join(a, &.{ request.root, ".incomplete" }))) return error.RuntimeBuildIncomplete;
    const modules = try std.fs.path.join(a, &.{ request.root, "modules" });
    var runtime = bridge.Runtime.init(a, init.io, modules);
    try runtime.loadSiblingTemplates();
    const manifest = try std.fs.path.join(a, &.{ request.root, "manifest.jsonl" });
    if (try optionalFile(init.io, manifest)) {
        try runtime.loadManifest(manifest);
        try runtime.loadBundle(try std.fs.path.join(a, &.{ request.root, "modules.bundle" }));
    }
    const extracted_redirects = try std.fs.path.join(a, &.{ request.root, "module-redirects.tsv" });
    if (try optionalFile(init.io, extracted_redirects)) try runtime.loadRedirects(extracted_redirects);
    const redirects = try std.fs.path.join(a, &.{ request.root, "usage.tsv" });
    if (try optionalFile(init.io, redirects)) try runtime.loadRedirects(redirects);
    if (try optionalFile(init.io, try std.fs.path.join(a, &.{ request.root, "wikibase-sitelinks.tsv" }))) try runtime.loadSiblingWikibaseSitelinks();
    if (try optionalFile(init.io, try std.fs.path.join(a, &.{ request.root, "interwiki-map.tsv" }))) try runtime.loadSiblingInterwikiMap();
    stage.* = "install";
    runtime.beginPage(a, request.title);
    var vm = try bridge.Vm.init(a);
    try runtime.install(&vm);
    stage.* = "expand";
    return runtime.expandFragment(&vm, request.title, request.source) catch |err| {
        detail.* = if (vm.last_error == .string) vm.last_error.string else runtime.last_missing_module orelse runtime.last_missing_template orelse runtime.last_not_implemented orelse runtime.last_unsupported_parser;
        return err;
    };
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
    const request = parsed.value;
    if (request.source.len > 16 * 1024 * 1024 or request.root.len == 0 or request.title.len == 0) return error.InvalidRequest;
    var reply: Reply = .{};
    reply.output = expand(init, request, &reply.stage, &reply.detail) catch |err| blk: {
        reply.error_name = @errorName(err);
        break :blk null;
    };
    if (reply.output) |text| if (text.len > 16 * 1024 * 1024) return error.ExpandedSourceTooLarge;
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try std.json.Stringify.value(reply, .{}, &out.interface);
    try out.interface.flush();
}
