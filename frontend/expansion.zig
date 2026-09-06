//! Optional Lua-bytecode rendering. Source and expanded presentation have distinct lifetimes.
const std = @import("std");
const model = @import("model.zig");
const dec = @import("blob_decoder");
const A = std.mem.Allocator;
pub const Options = struct { root: ?[]const u8 = null, timeout_ms: u32 = 5000 };
const Request = struct { root: []const u8, title: []const u8, source: []const u8 };
const Reply = struct { schema: []const u8, output: ?[]const u8, stage: []const u8, error_name: ?[]const u8, detail: ?[]const u8 };
const Result = struct {
    parsed: ?std.json.Parsed(Reply) = null,
    failure: ?[]const u8 = null,
    fn deinit(self: *Result) void {
        if (self.parsed) |*p| p.deinit();
    }
};
fn call(io: std.Io, a: A, options: Options, title: []const u8, source: []const u8) !Result {
    const exe = try std.process.executablePathAlloc(io, a);
    defer a.free(exe);
    const request = try std.json.Stringify.valueAlloc(a, Request{ .root = options.root.?, .title = title, .source = source }, .{});
    defer a.free(request);
    if (request.len >= 32 * 1024 * 1024) return error.RuntimeRequestTooLarge;
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(options.timeout_ms), .clock = .awake } }).toDeadline(io);
    var child = try std.process.spawn(io, .{ .argv = &.{ exe, "--internal-expand" }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    // The worker reads its entire request before loading assets or executing any Lua.
    var writer = child.stdin.?.writer(io, &.{});
    const write_result = writer.interface.writeAll(request);
    child.stdin.?.close(io);
    child.stdin = null;
    var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(a, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer readers.deinit();
    while (readers.fill(8192, timeout)) |_| {
        if (readers.reader(0).buffered().len > 32 * 1024 * 1024 or readers.reader(1).buffered().len > 64 * 1024) return .{ .failure = "VM output limit exceeded" };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{ .failure = "VM expansion timed out" },
        else => return err,
    }
    try readers.checkAnyError();
    const exited = try child.wait(io);
    if (exited != .exited or exited.exited != 0) return .{ .failure = "VM worker failed or crashed" };
    try write_result;
    var parsed = try std.json.parseFromSlice(Reply, a, readers.reader(0).buffered(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const reply = parsed.value;
    if (!std.mem.eql(u8, reply.schema, "dict.expansion.v1") or (reply.output == null) == (reply.error_name == null)) return error.InvalidRuntimeResponse;
    if (reply.error_name) |name| {
        if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
        // Missing assets and I/O failures are not silently turned into native successes.
        if (!std.mem.eql(u8, reply.stage, "expand") or isIoError(name)) {
            std.debug.print("dict runtime {s}: {s}\n", .{ reply.stage, name });
            return error.RuntimeAssetsFailed;
        }
    }
    return .{ .parsed = parsed };
}
fn isIoError(name: []const u8) bool {
    for ([_][]const u8{ "FileNotFound", "AccessDenied", "InputOutput", "ReadFailed", "WriteFailed", "SystemResources", "ProcessFdQuotaExceeded", "SystemFdQuotaExceeded" }) |e| if (std.mem.eql(u8, name, e)) return true;
    return false;
}
fn applyFailure(doc: *model.OwnedEntry, result: Result) !void {
    const owned = doc.arena.allocator();
    const diagnostic = if (result.failure) |failure| try owned.dupe(u8, failure) else blk: {
        const reply = result.parsed.?.value;
        break :blk try std.fmt.allocPrint(owned, "{s}: {s}{s}{s}", .{ reply.stage, reply.error_name.?, if (reply.detail != null) ": " else "", reply.detail orelse "" });
    };
    doc.entry.expansion = .{ .status = .failed, .diagnostic = diagnostic };
}
pub fn fromWikitext(io: std.Io, a: A, title: []const u8, language: []const u8, source: []const u8, with_source: bool, options: Options) !model.OwnedEntry {
    if (options.root == null) return model.fromWikitext(a, title, language, source, with_source);
    var result = try call(io, a, options, title, source);
    defer result.deinit();
    if (result.parsed) |parsed| if (parsed.value.output) |expanded| {
        var doc = try model.fromWikitext(a, title, language, expanded, false);
        errdefer doc.deinit();
        if (with_source) try model.setExactSource(&doc, source);
        doc.entry.expansion = .{ .status = .ok };
        return doc;
    };
    var doc = try model.fromWikitext(a, title, language, source, with_source);
    errdefer doc.deinit();
    try applyFailure(&doc, result);
    return doc;
}
pub fn fromRecord(io: std.Io, a: A, record: dec.BlobRecordView, with_source: bool, options: Options) !model.OwnedEntry {
    if (options.root == null) return model.fromRecord(a, record, with_source);
    const source = model.sourceAlloc(a, record) catch |err| switch (err) {
        error.InvalidEncoding => return model.fromRecord(a, record, with_source),
        else => return err,
    };
    defer a.free(source);
    const language = switch (record) {
        .language => |r| r.metadata.heading,
        else => "",
    };
    const prefix = switch (record.kind()) {
        .language => "",
        .thesaurus => "Thesaurus:",
        .citations => "Citations:",
        .reconstruction => "Reconstruction:",
        .rhymes => "Rhymes:",
        .sign_gloss => "Sign gloss:",
        .supplement => return error.InvalidEncoding,
    };
    const title = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, record.title() });
    defer a.free(title);
    var doc = try fromWikitext(io, a, title, language, source, with_source, options);
    errdefer doc.deinit();
    doc.entry.title = try doc.arena.allocator().dupe(u8, record.title());
    doc.entry.kind = record.kind();
    doc.entry.language = if (language.len != 0) try doc.arena.allocator().dupe(u8, language) else null;
    if (record == .language) doc.entry.language_code = try doc.arena.allocator().dupe(u8, record.language.metadata.code);
    return doc;
}
