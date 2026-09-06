//! Local HTTP/1.1 application. Persistent indexes are shared; VM work never holds
//! the store lock. Only fixed read-only API routes are exposed, never arbitrary files.
const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const expansion = @import("expansion.zig");
const output = @import("output.zig");
const html = @import("html.zig");
const storage = @import("blob_storage");
const enc = @import("blob_encoder");
const A = std.mem.Allocator;
const L = std.os.linux;
const Language = struct { heading: []const u8, code: []const u8 };
const Slot = struct { db: store.Store, language: []u8, kind: store.Kind, tick: u64 };
const Answer = struct { body: []const u8, status: std.http.Status = .ok, mime: []const u8 = "application/json; charset=utf-8" };
const Query = struct { path: []const u8, q: []const u8 = "", language: []const u8 = "", kind: ?store.Kind = null, offset: usize = 0, limit: usize = 40 };
fn decode(a: A, text: []const u8) ![]const u8 {
    if (text.len > 12288) return error.BadRequest;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = if (text[i] == '%') blk: {
            if (text.len - i < 3) return error.BadRequest;
            const value = std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16) catch return error.BadRequest;
            i += 2;
            break :blk value;
        } else if (text[i] == '+') @as(u8, ' ') else text[i];
        if (b < 32 or b == 127) return error.BadRequest;
        try result.append(a, b);
    }
    if (!std.unicode.utf8ValidateSlice(result.items) or result.items.len > 4096) return error.BadRequest;
    return result.toOwnedSlice(a);
}
fn query(a: A, target: []const u8) !Query {
    if (target.len > 16384 or target.len == 0 or target[0] != '/' or std.mem.startsWith(u8, target, "//") or std.mem.indexOfScalar(u8, target, '#') != null) return error.BadRequest;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    var r: Query = .{ .path = target[0..q] };
    if (q == target.len) return r;
    var fields = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.BadRequest;
        const key = try decode(a, field[0..eq]);
        const value = try decode(a, field[eq + 1 ..]);
        const g = try seen.getOrPut(a, key);
        if (g.found_existing) return error.BadRequest;
        if (std.mem.eql(u8, key, "q")) r.q = value else if (std.mem.eql(u8, key, "language")) r.language = value else if (std.mem.eql(u8, key, "kind")) r.kind = store.parseKind(value) orelse return error.BadRequest else if (std.mem.eql(u8, key, "offset")) r.offset = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest else if (std.mem.eql(u8, key, "limit")) r.limit = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest else return error.BadRequest;
    }
    if (r.limit == 0 or r.limit > 100) return error.BadRequest;
    return r;
}
const State = struct {
    io: std.Io,
    a: A,
    opts: args.Options,
    runtime: expansion.Options,
    media: ?[]const u8,
    languages: []const Language,
    lock: std.Io.Mutex = .init,
    slots: [4]?Slot = @splat(null),
    tick: u64 = 0,
    index_builds: u64 = 0,
    index_hits: u64 = 0,
    vm_lock: std.Io.Mutex = .init,
    vm_worker: expansion.Worker,
    fn init(io: std.Io, a: A, opts: args.Options, runtime: expansion.Options, media: ?[]const u8) !State {
        const path = try std.fs.path.join(a, &.{ opts.root, enc.blob_catalog.manifest_filename });
        defer a.free(path);
        const catalog = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
        defer a.free(catalog);
        var list: std.ArrayList(Language) = .empty;
        errdefer {
            for (list.items) |l| {
                a.free(l.heading);
                a.free(l.code);
            }
            list.deinit(a);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        var it = try enc.blob_catalog.Iterator.init(catalog);
        while (try it.next()) |item| {
            const found = try seen.getOrPut(a, item.heading);
            if (found.found_existing) return error.InvalidManifest;
            const p = try store.pathAlloc(a, opts.root, .language, item.heading);
            defer a.free(p);
            const h = try storage.headerAlloc(io, a, p);
            defer a.free(h);
            const view = try enc.blob_format.openTrusted(h);
            if (view.kind != .language) return error.UnexpectedLanguageBlob;
            const meta = try view.languageMetadata();
            if (!std.mem.eql(u8, meta.heading, item.heading)) return error.UnexpectedLanguageBlob;
            const heading = try a.dupe(u8, item.heading);
            errdefer a.free(heading);
            const code = try a.dupe(u8, meta.code);
            errdefer a.free(code);
            try list.append(a, .{ .heading = heading, .code = code });
        }
        return .{ .io = io, .a = a, .opts = opts, .runtime = runtime, .media = media, .languages = try list.toOwnedSlice(a), .vm_worker = expansion.Worker.init(io, runtime) };
    }
    fn deinit(self: *State) void {
        self.vm_worker.deinit();
        for (&self.slots) |*slot| if (slot.*) |*s| {
            s.db.deinit();
            self.a.free(s.language);
        };
        for (self.languages) |l| {
            self.a.free(l.heading);
            self.a.free(l.code);
        }
        self.a.free(self.languages);
    }
    fn resolveLanguage(self: *State, name: []const u8) ![]const u8 {
        if (name.len == 0) return self.opts.language;
        for (self.languages) |l| if (std.mem.eql(u8, name, l.heading)) return l.heading;
        for (self.languages) |l| if (l.code.len != 0 and std.mem.eql(u8, name, l.code)) return l.heading;
        return error.UnknownLanguage;
    }
    // Caller holds lock. Fixed LRU bounds retained mappings, including compressed block caches.
    fn db(self: *State, language: []const u8, kind: store.Kind) !*store.Store {
        self.tick +%= 1;
        var candidate: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.slots, 0..) |*slot, i| {
            if (slot.*) |*s| {
                if (s.kind == kind and std.mem.eql(u8, s.language, language)) {
                    if (try s.db.file.unchanged()) {
                        s.tick = self.tick;
                        return &s.db;
                    }
                    s.db.deinit();
                    self.a.free(s.language);
                    slot.* = null;
                    candidate = i;
                    oldest = 0;
                } else if (s.tick < oldest) {
                    candidate = i;
                    oldest = s.tick;
                }
            } else {
                candidate = i;
                oldest = 0;
            }
        }
        var loaded = try store.Store.open(self.io, self.a, self.opts.root, kind, language, false);
        errdefer loaded.deinit();
        const copy = try self.a.dupe(u8, language);
        if (self.slots[candidate]) |*s| {
            s.db.deinit();
            self.a.free(s.language);
        }
        if (loaded.file.cache_hit) self.index_hits += 1 else self.index_builds += 1;
        self.slots[candidate] = .{ .db = loaded, .language = copy, .kind = kind, .tick = self.tick };
        return &self.slots[candidate].?.db;
    }
    fn answer(self: *State, a: A, target: []const u8) !Answer {
        const q = try query(a, target);
        if (std.mem.eql(u8, q.path, "/")) {
            var out: std.Io.Writer.Allocating = .init(a);
            try html.live(&out.writer, a, self.opts.language, self.opts.kind);
            return .{ .body = try out.toOwnedSlice(), .mime = "text/html; charset=utf-8" };
        }
        if (std.mem.eql(u8, q.path, "/favicon.ico")) return .{ .body = "", .status = .no_content };
        if (std.mem.eql(u8, q.path, "/api/health")) return .{ .body = "{\"status\":\"ok\",\"protocol\":\"HTTP/1.1\"}" };
        if (std.mem.eql(u8, q.path, "/api/languages")) return .{ .body = try std.json.Stringify.valueAlloc(a, .{ .schema = "dict.catalog.v1", .languages = self.languages }, .{}) };
        const search = std.mem.eql(u8, q.path, "/api/search");
        const entry = std.mem.eql(u8, q.path, "/api/entry");
        const stats = std.mem.eql(u8, q.path, "/api/stats");
        if (!search and !entry and !stats) return .{ .body = "{\"error\":\"Not found\"}", .status = .not_found };
        const language = try self.resolveLanguage(q.language);
        const kind = q.kind orelse self.opts.kind;
        if (entry and q.q.len == 0) return error.BadRequest;
        var response: output.Response = .{ .operation = if (search) .search else if (stats) .stats else .lookup, .query = q.q, .kind = kind, .language = if (kind == .language) language else null, .total_matches = 0, .record_count = 0 };
        var source: []const u8 = "";
        var language_code: []const u8 = "";
        {
            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);
            const dbp = try self.db(language, kind);
            response.record_count = dbp.count();
            if (stats) {
                const x = dbp.file.compressed;
                return .{ .body = try std.json.Stringify.valueAlloc(a, .{ .records = dbp.count(), .index_bytes = dbp.file.indexBytes(), .index_heap_bytes = dbp.file.indexHeapBytes(), .cache_map_bytes = dbp.file.cacheMappedBytes(), .payload_reads = dbp.file.payload_reads, .disk_cache_hit = dbp.file.cache_hit, .disk_cache_saved = dbp.file.cache_saved, .index_builds = self.index_builds, .index_cache_hits = self.index_hits, .xz_blocks = if (x) |v| v.blocks else 0, .decoded_blocks = if (x) |v| v.decoded_blocks else 0, .vm_worker_starts = self.vm_worker.startCount(), .vm_requests = self.vm_worker.requestCount() }, .{}) };
            }
            if (search) {
                const range = try dbp.prefix(q.q);
                response.total_matches = range.end - range.start;
                response.offset = q.offset;
                const start = range.start + @min(q.offset, response.total_matches);
                const end = start + @min(q.limit, range.end - start);
                response.has_more = end < range.end;
                const matches = try a.alloc(output.Match, end - start);
                for (matches, start..) |*m, i| m.* = .{ .title = try a.dupe(u8, try dbp.titleAt(i)) };
                response.matches = matches;
                return .{ .body = try std.json.Stringify.valueAlloc(a, response, .{}) };
            }
            const i = (try dbp.find(q.q)) orelse return .{ .body = try std.json.Stringify.valueAlloc(a, response, .{}), .status = .not_found };
            var raw = try dbp.recordAlloc(a, i);
            defer raw.deinit();
            var resolved = try dbp.resolveAlloc(a, raw.record);
            defer resolved.deinit();
            source = try model.sourceAlloc(a, resolved.record);
            if (dbp.metadata()) |meta| language_code = try a.dupe(u8, meta.code);
        }
        // Search stays independent while one persistent VM worker serializes entry expansion.

        const prefix = if (kind == .language) "" else switch (kind) {
            .thesaurus => "Thesaurus:",
            .citations => "Citations:",
            .reconstruction => "Reconstruction:",
            .rhymes => "Rhymes:",
            .sign_gloss => "Sign gloss:",
            else => return error.BadRequest,
        };
        const expanded_title = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, q.q });
        var doc = if (self.runtime.root != null) blk: {
            try self.vm_lock.lock(self.io);
            defer self.vm_lock.unlock(self.io);
            break :blk try expansion.fromWikitextWorker(&self.vm_worker, self.a, expanded_title, if (kind == .language) language else "", source, true);
        } else try expansion.fromWikitext(self.io, self.a, expanded_title, if (kind == .language) language else "", source, true, self.runtime);
        defer doc.deinit();
        doc.entry.title = q.q;
        doc.entry.kind = kind;
        doc.entry.language = if (kind == .language) language else null;
        doc.entry.language_code = language_code;
        if (self.media) |root| doc.entry.media = try @import("media_assets.zig").attach(self.io, a, root, doc.entry.media);
        response.entries = &.{doc.entry};
        response.total_matches = 1;
        const failed = doc.entry.status == .invalid_payload or if (doc.entry.expansion) |e| e.status == .failed else false;
        const body = try std.json.Stringify.valueAlloc(a, response, .{});
        if (body.len > 64 * 1024 * 1024) return error.ResponseLimit;
        return .{ .body = body, .status = if (failed) .unprocessable_entity else .ok };
    }
};
var stop: std.atomic.Value(bool) = .init(false);
fn onSignal(_: L.SIG) callconv(.c) void {
    stop.store(true, .release);
}
const SocketIO = struct {
    fd: i32,
    io: std.Io,
    deadline: i128 = 0,
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    fn wait(self: *SocketIO, events: i16) !void {
        while (!stop.load(.acquire)) {
            const remaining = self.deadline - std.Io.Clock.awake.now(self.io).toNanoseconds();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
            const n = try std.posix.poll(&fds, @intCast(@min(@divTrunc(remaining, 1000000) + 1, 100)));
            if (n != 0) return;
        }
        return error.Stopped;
    }
    fn recv(self: *SocketIO, buffer: []u8) !usize {
        while (true) {
            try self.wait(std.posix.POLL.IN);
            const rc = L.recvfrom(self.fd, buffer.ptr, buffer.len, L.MSG.DONTWAIT, null, null);
            switch (L.errno(rc)) {
                .SUCCESS => return rc,
                .INTR, .AGAIN => continue,
                else => return error.SocketFailed,
            }
        }
    }
    fn send(self: *SocketIO, bytes: []const u8) !void {
        var p: usize = 0;
        while (p < bytes.len) {
            try self.wait(std.posix.POLL.OUT);
            const rc = L.sendto(self.fd, bytes.ptr + p, bytes.len - p, L.MSG.DONTWAIT | L.MSG.NOSIGNAL, null, 0);
            switch (L.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.SocketFailed;
                    p += rc;
                },
                .INTR, .AGAIN => continue,
                else => return error.SocketFailed,
            }
        }
    }
    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SocketIO = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = self.recv(dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SocketIO = @alignCast(@fieldParentPtr("writer", w));
        var n: usize = w.buffered().len;
        self.send(w.buffered()) catch return error.WriteFailed;
        for (data, 0..) |slice, i| {
            const count = if (i + 1 == data.len) splat else 1;
            for (0..count) |_| {
                self.send(slice) catch return error.WriteFailed;
                n += slice.len;
            }
        }
        return w.consume(n);
    }
};
fn allowed(request: *std.http.Server.Request, port: u16) !void {
    var host: bool = false;
    var scratch: [64]u8 = undefined;
    const authority = try std.fmt.bufPrint(&scratch, "127.0.0.1:{d}", .{port});
    var localhost_buf: [64]u8 = undefined;
    const localhost = try std.fmt.bufPrint(&localhost_buf, "localhost:{d}", .{port});
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Host")) {
            if (host or (!std.mem.eql(u8, h.value, authority) and !std.mem.eql(u8, h.value, localhost))) return error.BadHost;
            host = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Origin")) {
            if (!std.mem.startsWith(u8, h.value, "http://") or (!std.mem.eql(u8, h.value[7..], authority) and !std.mem.eql(u8, h.value[7..], localhost))) return error.BadOrigin;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Sec-Fetch-Site") and std.mem.eql(u8, h.value, "cross-site")) return error.BadOrigin;
    }
    if (!host) return error.BadHost;
}
fn connection(state: *State, fd: i32, port: u16) !void {
    var input: [16384]u8 = undefined;
    var output_buffer: [16384]u8 = undefined;
    var socket: SocketIO = .{ .fd = fd, .io = state.io, .reader = .{ .vtable = &.{ .stream = SocketIO.stream }, .buffer = &input, .seek = 0, .end = 0 }, .writer = .{ .vtable = &.{ .drain = SocketIO.drain }, .buffer = &output_buffer } };
    var http = std.http.Server.init(&socket.reader, &socket.writer);
    for (0..100) |_| {
        socket.deadline = std.Io.Clock.awake.now(state.io).toNanoseconds() + 10 * std.time.ns_per_s;
        var req = http.receiveHead() catch return;
        const body_present = (req.head.content_length orelse 0) != 0 or req.head.transfer_encoding != .none;
        if (allowed(&req, port)) |_| {} else |_| {
            try req.respond("Forbidden local origin", .{ .status = .forbidden, .keep_alive = false });
            return;
        }
        if ((req.head.method != .GET and req.head.method != .HEAD) or body_present) {
            try req.respond("Read-only GET/HEAD API", .{ .status = .method_not_allowed, .keep_alive = false });
            return;
        }
        var arena = std.heap.ArenaAllocator.init(state.a);
        defer arena.deinit();
        const a = arena.allocator();
        const answer = state.answer(a, req.head.target) catch |err| Answer{ .body = try std.json.Stringify.valueAlloc(a, .{ .error_name = @errorName(err) }, .{}), .status = switch (err) {
            error.BadRequest => .bad_request,
            error.UnknownLanguage, error.FileNotFound => .not_found,
            else => .internal_server_error,
        } };
        socket.deadline = std.Io.Clock.awake.now(state.io).toNanoseconds() + 30 * std.time.ns_per_s;
        try req.respond(answer.body, .{ .status = answer.status, .extra_headers = &.{ .{ .name = "Content-Type", .value = answer.mime }, .{ .name = "Cache-Control", .value = "no-store" }, .{ .name = "X-Content-Type-Options", .value = "nosniff" }, .{ .name = "Referrer-Policy", .value = "no-referrer" }, .{ .name = "Content-Security-Policy", .value = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; media-src data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'" } } });
        if (!req.head.keep_alive or stop.load(.acquire)) return;
    }
}
fn worker(state: *State, fd: i32, port: u16) void {
    while (!stop.load(.acquire)) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&fds, 100) catch return) == 0) continue;
        const rc = L.accept4(fd, null, null, L.SOCK.CLOEXEC | L.SOCK.NONBLOCK);
        switch (L.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => continue,
            else => return,
        }
        const client: i32 = @intCast(rc);
        defer _ = L.close(client);
        connection(state, client, port) catch {};
    }
}
pub fn run(io: std.Io, a: A, opts: args.Options, runtime: expansion.Options, media: ?[]const u8) !void {
    var state = try State.init(io, a, opts, runtime, media);
    defer state.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(opts.port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const fd = listener.socket.handle;
    const flags = L.fcntl(fd, L.F.GETFL, @as(usize, 0));
    if (L.errno(flags) != .SUCCESS or L.errno(L.fcntl(fd, L.F.SETFL, flags | @as(u32, @bitCast(L.O{ .NONBLOCK = true })))) != .SUCCESS) return error.SocketFailed;
    const port = listener.socket.address.getPort();
    stop.store(false, .release);
    var old: [2]std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
    for ([_]L.SIG{ .INT, .TERM }, 0..) |sig, i| std.posix.sigaction(sig, &action, &old[i]);
    defer for ([_]L.SIG{ .INT, .TERM }, 0..) |sig, i| std.posix.sigaction(sig, &old[i], null);
    var threads: [8]std.Thread = undefined;
    var n: usize = 0;
    errdefer {
        stop.store(true, .release);
        for (threads[0..n]) |t| t.join();
    }
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &state, fd, port });
        n += 1;
    }
    std.debug.print("Dictionary listening on http://127.0.0.1:{d}\n", .{port});
    for (threads) |t| t.join();
}
test "HTTP queries reject ambiguous malformed and overlarge input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try query(a, "/api/search?q=%E7%8C%AB&limit=10&offset=2");
    try std.testing.expectEqualStrings("猫", q.q);
    for ([_][]const u8{ "/api/search?q=%", "/api/search?q=%00", "/api/search?q=a&q=b", "/api/search?limit=0", "//elsewhere/", "/api/search?limit=999", "/api/search?unknown=1" }) |bad| try std.testing.expectError(error.BadRequest, query(a, bad));
}
