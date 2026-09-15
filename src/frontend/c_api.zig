const std = @import("std");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");

const A = std.mem.Allocator;
const allocator = std.heap.c_allocator;

const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    invalid_argument = 2,
    io_error = 3,
    out_of_memory = 4,
    internal_error = 5,
};

pub const Buffer = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
};

const Selected = struct {
    db: store.Store,
    language: []u8,
    kind: store.Kind,
};
const Handle = struct {
    threaded: std.Io.Threaded,
    root: []u8,
    selected: ?Selected = null,
    last_error: [512]u8 = [_]u8{0} ** 512,
    error_len: usize = 0,

    fn io(self: *Handle) std.Io {
        return self.threaded.io();
    }

    fn clearError(self: *Handle) void {
        self.error_len = 0;
    }

    fn fail(self: *Handle, context: []const u8, err: anyerror) Status {
        const text = std.fmt.bufPrint(self.last_error[0 .. self.last_error.len - 1], "{s}: {s}", .{ context, @errorName(err) }) catch blk: {
            const fallback = "dictionary operation failed";
            @memcpy(self.last_error[0..fallback.len], fallback);
            break :blk self.last_error[0..fallback.len];
        };
        self.error_len = text.len;
        self.last_error[self.error_len] = 0;
        return statusFor(err);
    }
};
fn statusFor(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidArgument, error.InvalidUtf8, error.InvalidEncoding, error.UnexpectedBlobKind, error.UnexpectedLanguageBlob, error.InvalidManifest => .invalid_argument,
        error.FileNotFound, error.AccessDenied, error.InputOutput, error.ReadFailed, error.WriteFailed => .io_error,
        else => .internal_error,
    };
}

fn input(ptr: ?[*]const u8, len: usize, max: usize) ![]const u8 {
    if (len > max) return error.InvalidArgument;
    if (len == 0) return "";
    const bytes = (ptr orelse return error.InvalidArgument)[0..len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn selected(handle: *Handle) !*Selected {
    return if (handle.selected) |*value| value else error.InvalidArgument;
}

fn resetBuffer(out: *Buffer) void {
    out.* = .{};
}
fn jsonBuffer(handle: *Handle, value: anytype, out: *Buffer) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer.writer);
    try writer.writer.writeByte('\n');
    const bytes = try writer.toOwnedSlice();
    out.* = .{ .data = bytes.ptr, .len = bytes.len };
    handle.clearError();
}

export fn dict_abi_version() callconv(.c) u32 {
    return 1;
}

fn openHandle(root: []const u8) !*Handle {
    const copy = try allocator.dupe(u8, root);
    errdefer allocator.free(copy);
    const handle = try allocator.create(Handle);
    errdefer allocator.destroy(handle);
    handle.* = .{ .threaded = std.Io.Threaded.init(allocator, .{}), .root = copy };
    errdefer handle.threaded.deinit();
    return handle;
}

export fn dict_open(root_ptr: ?[*]const u8, root_len: usize, out_handle: *?*Handle) callconv(.c) c_int {
    out_handle.* = null;
    const root = input(root_ptr, root_len, 4096) catch |err| return @intFromEnum(statusFor(err));
    if (root.len == 0) return @intFromEnum(Status.invalid_argument);
    const handle = openHandle(root) catch |err| return @intFromEnum(statusFor(err));
    out_handle.* = handle;
    return @intFromEnum(Status.ok);
}

export fn dict_close(handle: ?*Handle) callconv(.c) void {
    const h = handle orelse return;
    if (h.selected) |*value| {
        value.db.deinit();
        allocator.free(value.language);
    }
    allocator.free(h.root);
    h.threaded.deinit();
    allocator.destroy(h);
}
fn selectImpl(h: *Handle, language: []const u8, kind: store.Kind) !void {
    const copy = try allocator.dupe(u8, language);
    errdefer allocator.free(copy);
    var db = try store.Store.open(h.io(), allocator, h.root, kind, language, false);
    errdefer db.deinit();
    if (h.selected) |*old| {
        old.db.deinit();
        allocator.free(old.language);
    }
    h.selected = .{ .db = db, .language = copy, .kind = kind };
}

export fn dict_select(
    handle: ?*Handle,
    language_ptr: ?[*]const u8,
    language_len: usize,
    kind_ptr: ?[*]const u8,
    kind_len: usize,
) callconv(.c) c_int {
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    const language = input(language_ptr, language_len, 4096) catch |err| return @intFromEnum(h.fail("language", err));
    const kind_text = input(kind_ptr, kind_len, 64) catch |err| return @intFromEnum(h.fail("kind", err));
    const kind = store.parseKind(kind_text) orelse return @intFromEnum(h.fail("kind", error.InvalidArgument));
    if (kind == .language and language.len == 0) return @intFromEnum(h.fail("language", error.InvalidArgument));
    selectImpl(h, language, kind) catch |err| return @intFromEnum(h.fail("select", err));
    h.clearError();
    return @intFromEnum(Status.ok);
}
fn lookupInternal(handle: *Handle, query: []const u8, out: *Buffer) !bool {
    const current = try selected(handle);
    var response: output.Response = .{
        .operation = .lookup,
        .query = query,
        .kind = current.kind,
        .language = if (current.kind == .language) current.language else null,
        .record_count = current.db.count(),
        .total_matches = 0,
        .match_mode = "exact-utf8",
    };
    const index = (try current.db.find(query)) orelse {
        try jsonBuffer(handle, response, out);
        return false;
    };
    var raw = try current.db.recordAlloc(allocator, index);
    defer raw.deinit();
    var doc = try model.fromRecord(allocator, raw.record);
    defer doc.deinit();
    response.entries = &.{doc.entry};
    response.total_matches = 1;
    try jsonBuffer(handle, response, out);
    return true;
}


export fn dict_lookup_json(
    handle: ?*Handle,
    query_ptr: ?[*]const u8,
    query_len: usize,
    out: *Buffer,
) callconv(.c) c_int {
    resetBuffer(out);
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    const query = input(query_ptr, query_len, 4096) catch |err| return @intFromEnum(h.fail("lookup", err));
    if (query.len == 0) return @intFromEnum(h.fail("lookup", error.InvalidArgument));
    const found = lookupInternal(h, query, out) catch |err| return @intFromEnum(h.fail("lookup", err));
    return @intFromEnum(if (found) Status.ok else Status.not_found);
}

export fn dict_search_json(
    handle: ?*Handle,
    query_ptr: ?[*]const u8,
    query_len: usize,
    limit: usize,
    offset: usize,
    out: *Buffer,
) callconv(.c) c_int {
    resetBuffer(out);
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    const query = input(query_ptr, query_len, 4096) catch |err| return @intFromEnum(h.fail("search", err));
    if (limit == 0 or limit > 1000) return @intFromEnum(h.fail("search", error.InvalidArgument));
    const current = selected(h) catch |err| return @intFromEnum(h.fail("search", err));
    const range = current.db.prefix(query) catch |err| return @intFromEnum(h.fail("search", err));
    const total = range.end - range.start;
    const start = range.start + @min(offset, total);
    const end = start + @min(limit, range.end - start);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const matches = a.alloc(output.Match, end - start) catch |err| return @intFromEnum(h.fail("search", err));
    for (matches, start..) |*match, index| {
        match.* = .{ .title = current.db.titleAt(index) catch |err| return @intFromEnum(h.fail("search", err)) };
    }
    const response: output.Response = .{
        .operation = .search,
        .query = query,
        .kind = current.kind,
        .language = if (current.kind == .language) current.language else null,
        .record_count = current.db.count(),
        .total_matches = total,
        .offset = offset,
        .has_more = end < range.end,
        .matches = matches,
    };
    jsonBuffer(h, response, out) catch |err| return @intFromEnum(h.fail("search", err));
    return @intFromEnum(Status.ok);
}

export fn dict_random_json(handle: ?*Handle, out: *Buffer) callconv(.c) c_int {
    resetBuffer(out);
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    const current = selected(h) catch |err| return @intFromEnum(h.fail("random", err));
    if (current.db.count() == 0) return @intFromEnum(Status.not_found);
    const entropy: u128 = @intCast(std.Io.Clock.awake.now(h.io()).toNanoseconds());
    const index: usize = @intCast(entropy % @as(u128, current.db.count()));
    const title = current.db.titleAt(index) catch |err| return @intFromEnum(h.fail("random", err));
    const found = lookupInternal(h, title, out) catch |err| return @intFromEnum(h.fail("random", err));
    return @intFromEnum(if (found) Status.ok else Status.not_found);
}
export fn dict_languages_json(handle: ?*Handle, out: *Buffer) callconv(.c) c_int {
    resetBuffer(out);
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = std.fs.path.join(a, &.{ h.root, store.catalog.manifest_filename }) catch |err| return @intFromEnum(h.fail("languages", err));
    const bytes = std.Io.Dir.cwd().readFileAlloc(h.io(), path, a, .limited(16 * 1024 * 1024)) catch |err| return @intFromEnum(h.fail("languages", err));
    var it = store.catalog.Iterator.init(bytes) catch |err| return @intFromEnum(h.fail("languages", err));
    var names: std.ArrayList([]const u8) = .empty;
    while (it.next() catch |err| return @intFromEnum(h.fail("languages", err))) |entry| {
        names.append(a, entry.heading) catch |err| return @intFromEnum(h.fail("languages", err));
    }
    const payload = .{ .schema = "dict.languages.v1", .languages = names.items };
    jsonBuffer(h, payload, out) catch |err| return @intFromEnum(h.fail("languages", err));
    return @intFromEnum(Status.ok);
}

export fn dict_stats_json(handle: ?*Handle, out: *Buffer) callconv(.c) c_int {
    resetBuffer(out);
    const h = handle orelse return @intFromEnum(Status.invalid_argument);
    const current = selected(h) catch |err| return @intFromEnum(h.fail("stats", err));
    const payload = .{
        .schema = "dict.stats.v1",
        .kind = @tagName(current.kind),
        .language = if (current.kind == .language) current.language else null,
        .records = current.db.count(),
        .index_bytes = current.db.file.indexBytes(),
        .index_heap_bytes = current.db.file.indexHeapBytes(),
        .cache_map_bytes = current.db.file.cacheMappedBytes(),
    };
    jsonBuffer(h, payload, out) catch |err| return @intFromEnum(h.fail("stats", err));
    return @intFromEnum(Status.ok);
}
export fn dict_buffer_free(handle: ?*Handle, buffer: ?*Buffer) callconv(.c) void {
    _ = handle;
    const out = buffer orelse return;
    if (out.data) |ptr| allocator.free(ptr[0..out.len]);
    out.* = .{};
}

export fn dict_last_error(handle: ?*const Handle, out_len: ?*usize) callconv(.c) [*:0]const u8 {
    const h = handle orelse {
        if (out_len) |len| len.* = 0;
        return "";
    };
    if (out_len) |len| len.* = h.error_len;
    return @ptrCast(&h.last_error);
}

export fn dict_status_name(raw_status: c_int) callconv(.c) [*:0]const u8 {
    return switch (raw_status) {
        @intFromEnum(Status.ok) => "ok",
        @intFromEnum(Status.not_found) => "not_found",
        @intFromEnum(Status.invalid_argument) => "invalid_argument",
        @intFromEnum(Status.io_error) => "io_error",
        @intFromEnum(Status.out_of_memory) => "out_of_memory",
        @intFromEnum(Status.internal_error) => "internal_error",
        else => "unknown",
    };
}
