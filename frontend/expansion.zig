//! Optional native Lua AOT rendering. Source and expanded presentation have distinct lifetimes.
const std = @import("std");
const model = @import("model.zig");
const dec = @import("blob_decoder");
const protocol = @import("expansion_protocol.zig");
const A = std.mem.Allocator;
const L = std.os.linux;
pub const Options = struct { root: ?[]const u8 = null, timeout_ms: u32 = 5000, dictionary_root: ?[]const u8 = null };
const Request = protocol.Request;
const Reply = protocol.Reply;
const Result = struct {
    parsed: ?std.json.Parsed(Reply) = null,
    failure: ?[]const u8 = null,
    backend: []const u8 = "lua-aot",
    fn deinit(self: *Result) void {
        if (self.parsed) |*p| p.deinit();
    }
};
const WorkerExecutable = struct { path: []u8 };
fn workerExecutable(io: std.Io, a: A, root: []const u8) !WorkerExecutable {
    for ([_][]const u8{ "dict-native-expansion-worker", "runtime/dict-native-expansion-worker" }) |relative| {
        const candidate = try std.fs.path.join(a, &.{ root, relative });
        var file = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                a.free(candidate);
                continue;
            },
            else => {
                a.free(candidate);
                return err;
            },
        };
        file.close(io);
        return .{ .path = candidate };
    }
    return error.NativeLuaWorkerMissing;
}

fn parseReply(a: A, bytes: []const u8) !Result {
    var parsed = try std.json.parseFromSlice(Reply, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const reply = parsed.value;
    if (!std.mem.eql(u8, reply.schema, "dict.expansion.v1") or (reply.output == null) == (reply.error_name == null)) return error.InvalidRuntimeResponse;
    if (reply.error_name) |name| {
        if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
        if (!std.mem.eql(u8, reply.stage, "expand") or isIoError(name)) {
            std.debug.print("dict runtime {s}: {s}\n", .{ reply.stage, name });
            return error.RuntimeAssetsFailed;
        }
    }
    return .{ .parsed = parsed, .backend = reply.backend };
}
fn call(io: std.Io, a: A, options: Options, title: []const u8, language: []const u8, source: []const u8) !Result {
    var worker = Worker.init(io, options);
    defer worker.deinit();
    return worker.request(a, title, language, source);
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
    doc.entry.expansion = .{ .backend = result.backend, .status = .failed, .diagnostic = diagnostic };
}
fn documentFromResult(a: A, title: []const u8, language: []const u8, source: []const u8, with_source: bool, result: Result) !model.OwnedEntry {
    if (result.parsed) |parsed| if (parsed.value.output) |expanded| {
        var doc = try model.fromWikitext(a, title, language, expanded, false);
        errdefer doc.deinit();
        try model.restoreFormRelations(a, &doc, source);
        if (with_source) try model.setExactSource(&doc, source);
        doc.entry.expansion = .{ .backend = parsed.value.backend, .status = .ok };
        return doc;
    };
    var doc = try model.fromWikitext(a, title, language, source, with_source);
    errdefer doc.deinit();
    try applyFailure(&doc, result);
    return doc;
}
pub const Worker = struct {
    io: std.Io,
    options: Options,
    child: ?std.process.Child = null,
    starts: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),
    backend: []const u8 = "lua-aot",
    pub fn init(io: std.Io, options: Options) Worker {
        return .{ .io = io, .options = options };
    }
    pub fn deinit(self: *Worker) void {
        self.reset();
    }
    fn reset(self: *Worker) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }
    fn ensure(self: *Worker, a: A) !*std.process.Child {
        if (self.child == null) {
            const root = self.options.root orelse return error.RuntimeAssetsFailed;
            const selected = try workerExecutable(self.io, a, root);
            defer a.free(selected.path);
            self.child = try std.process.spawn(self.io, .{ .argv = &.{selected.path}, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
            _ = self.starts.fetchAdd(1, .monotonic);
        }
        return &self.child.?;
    }
    fn readExact(self: *Worker, file: std.Io.File, out: []u8, deadline: i128) !void {
        var pos: usize = 0;
        while (pos < out.len) {
            const remaining = deadline - std.Io.Clock.awake.now(self.io).toNanoseconds();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ms: i32 = @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, 100));
            if (try std.posix.poll(&fds, ms) == 0) continue;
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
    fn request(self: *Worker, a: A, title: []const u8, language: []const u8, source: []const u8) !Result {
        const root = self.options.root orelse return error.RuntimeAssetsFailed;
        const bytes = try std.json.Stringify.valueAlloc(a, Request{ .root = root, .title = title, .source = source, .dictionary_root = self.options.dictionary_root, .language = language }, .{});
        defer a.free(bytes);
        if (bytes.len == 0 or bytes.len > 32 * 1024 * 1024) return error.RuntimeRequestTooLarge;
        const child = try self.ensure(a);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
        var writer = child.stdin.?.writer(self.io, &.{});
        writer.interface.writeAll(&length) catch {
            self.reset();
            return .{ .failure = "runtime worker failed or crashed", .backend = self.backend };
        };
        writer.interface.writeAll(bytes) catch {
            self.reset();
            return .{ .failure = "runtime worker failed or crashed", .backend = self.backend };
        };
        writer.interface.flush() catch {
            self.reset();
            return .{ .failure = "runtime worker failed or crashed", .backend = self.backend };
        };
        _ = self.requests.fetchAdd(1, .monotonic);
        const deadline = std.Io.Clock.awake.now(self.io).toNanoseconds() + @as(i128, self.options.timeout_ms) * std.time.ns_per_ms;
        var raw_length: [4]u8 = undefined;
        self.readExact(child.stdout.?, &raw_length, deadline) catch |err| {
            self.reset();
            return .{ .failure = if (err == error.Timeout) "Lua expansion timed out" else "runtime worker failed or crashed", .backend = self.backend };
        };
        const response_len = std.mem.readInt(u32, &raw_length, .little);
        if (response_len == 0 or response_len > 32 * 1024 * 1024) {
            self.reset();
            return error.InvalidRuntimeResponse;
        }
        const response = try a.alloc(u8, response_len);
        defer a.free(response);
        self.readExact(child.stdout.?, response, deadline) catch |err| {
            self.reset();
            return .{ .failure = if (err == error.Timeout) "Lua expansion timed out" else "runtime worker failed or crashed", .backend = self.backend };
        };
        return parseReply(a, response);
    }
    pub fn startCount(self: *const Worker) u64 {
        return self.starts.load(.monotonic);
    }
    pub fn requestCount(self: *const Worker) u64 {
        return self.requests.load(.monotonic);
    }
};
pub fn fromWikitext(io: std.Io, a: A, title: []const u8, language: []const u8, source: []const u8, with_source: bool, options: Options) !model.OwnedEntry {
    if (options.root == null) return model.fromWikitext(a, title, language, source, with_source);
    var result = try call(io, a, options, title, language, source);
    defer result.deinit();
    return documentFromResult(a, title, language, source, with_source, result);
}
pub fn fromWikitextWorker(worker: *Worker, a: A, title: []const u8, language: []const u8, source: []const u8, with_source: bool) !model.OwnedEntry {
    if (worker.options.root == null) return model.fromWikitext(a, title, language, source, with_source);
    var result = try worker.request(a, title, language, source);
    defer result.deinit();
    return documentFromResult(a, title, language, source, with_source, result);
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
        .supplement, .symbols, .templates, .redirects, .pages => return error.InvalidEncoding,
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
