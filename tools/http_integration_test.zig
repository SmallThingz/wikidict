//! Tests the actual local server, persistent HTTP/1.1 connection and raw/XZ stores.
const std = @import("std");
const enc = @import("blob_encoder");
const A = std.mem.Allocator;
const L = std.os.linux;
fn require(ok: bool) !void {
    if (!ok) return error.AssertionFailed;
}
fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}
fn languagePath(a: A, root: []const u8, heading: []const u8) ![]u8 {
    var name: [enc.blob_catalog.language_blob_filename_len]u8 = undefined;
    return std.fs.path.join(a, &.{ root, "languages", enc.blob_catalog.languageBlobFilename(heading, &name) });
}
fn fixture(io: std.Io, a: A, root: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "languages" }));
    try write(io, try std.fs.path.join(a, &.{ root, "languages.tsv" }), "heading\nEnglish\nFrench\n");
    const rows = try a.alloc(enc.blob_format.RecordInput, 205);
    const titles = [_][]const u8{ "cat", "cats", "dog" };
    for (titles, 0..) |title, i| rows[i] = .{ .title = title, .payload = try enc.language_blob_encoding.encodeAlloc(a, try std.fmt.allocPrint(a, "==English==\n===Noun===\n# Meaning of [[{s}]].\n#: A usage example.\n", .{title}), .{ .heading = "English" }) };
    for (3..203) |i| rows[i] = .{ .title = try std.fmt.allocPrint(a, "word-{d:0>4}", .{i}), .payload = try enc.language_blob_encoding.encodeAlloc(a, "==English==\n===Noun===\n# A fixture word with enough text for independently compressed blocks.\n", .{ .heading = "English" }) };
    rows[203] = .{ .title = "éclair", .payload = try enc.language_blob_encoding.encodeAlloc(a, "==English==\n===Noun===\n# A pastry.\n", .{ .heading = "English" }) };
    rows[204] = .{ .title = "猫", .payload = try enc.language_blob_encoding.encodeAlloc(a, "==English==\n===Symbol===\n# A Unicode fixture.\n", .{ .heading = "English" }) };
    try write(io, try languagePath(a, root, "English"), try enc.blob_format.buildAlloc(a, .language, try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English"), rows));
    const fr = try enc.language_blob_encoding.encodeAlloc(a, "==French==\n===Noun===\n# A French fixture.\n", .{ .heading = "French" });
    try write(io, try languagePath(a, root, "French"), try enc.blob_format.buildAlloc(a, .language, try enc.blob_format.buildLanguageMetadataAlloc(a, "fr", "French"), &.{.{ .title = "chat", .payload = fr }}));
    try write(io, try std.fs.path.join(a, &.{ root, "citations.wikblb" }), try enc.blob_format.buildAlloc(a, .citations, "", &.{.{ .title = "cat", .payload = "# A citation fixture.\n" }}));
}
fn checked(rc: usize) !usize {
    return if (L.errno(rc) == .SUCCESS) rc else error.NetworkError;
}
const Client = struct {
    fd: i32,
    port: u16,
    a: A,
    io: std.Io,
    fn init(a: A, io: std.Io, port: u16) !Client {
        const fd: i32 = @intCast(try checked(L.socket(L.AF.INET, L.SOCK.STREAM | L.SOCK.CLOEXEC, 0)));
        errdefer _ = L.close(fd);
        const addr: L.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        _ = try checked(L.connect(fd, &addr, @sizeOf(@TypeOf(addr))));
        return .{ .fd = fd, .port = port, .a = a, .io = io };
    }
    fn close(self: *Client) void {
        _ = L.close(self.fd);
    }
    fn send(self: *Client, bytes: []const u8) !void {
        var p: usize = 0;
        while (p < bytes.len) {
            const n = try checked(L.sendto(self.fd, bytes.ptr + p, bytes.len - p, L.MSG.NOSIGNAL, null, 0));
            if (n == 0) return error.Closed;
            p += n;
        }
    }
    fn receive(self: *Client, bytes: []u8) !void {
        var p: usize = 0;
        while (p < bytes.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, 15000) == 0) return error.Timeout;
            const n = try checked(L.read(self.fd, bytes.ptr + p, bytes.len - p));
            if (n == 0) return error.Closed;
            p += n;
        }
    }
    const Response = struct { status: u16, body: []const u8, headers: []const u8 };
    fn response(self: *Client, head: bool) !Response {
        var header: std.ArrayList(u8) = .empty;
        while (header.items.len < 32768) {
            var b: [1]u8 = undefined;
            try self.receive(&b);
            try header.append(self.a, b[0]);
            if (std.mem.endsWith(u8, header.items, "\r\n\r\n")) break;
        }
        try require(std.mem.startsWith(u8, header.items, "HTTP/1.1 "));
        const status = try std.fmt.parseInt(u16, header.items[9..12], 10);
        var length: ?usize = null;
        var lines = std.mem.splitSequence(u8, header.items, "\r\n");
        while (lines.next()) |line| if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10);
        };
        const n = length orelse return error.NoFraming;
        try require(n <= 32 * 1024 * 1024);
        const body = try self.a.alloc(u8, if (head) 0 else n);
        try self.receive(body);
        return .{ .status = status, .body = body, .headers = header.items };
    }
    fn get(self: *Client, target: []const u8) !Response {
        try self.send(try std.fmt.allocPrint(self.a, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{ target, self.port }));
        return self.response(false);
    }
};
fn json(a: A, bytes: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value;
}
fn exercise(io: std.Io, a: A, bin: []const u8, root: []const u8, out: []const u8, compressed: bool) !void {
    var log = try std.Io.Dir.cwd().createFile(io, out, .{});
    defer log.close(io);
    var child = try std.process.spawn(io, .{ .argv = &.{ bin, "serve", "--port", "0", "--native", "--root", root }, .stdout = .ignore, .stderr = .{ .file = log } });
    defer child.kill(io);
    var port: ?u16 = null;
    for (0..300) |_| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, out, a, .limited(1024 * 1024));
        if (std.mem.indexOf(u8, bytes, "http://127.0.0.1:")) |p| {
            const start = p + 17;
            const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
            port = try std.fmt.parseInt(u16, bytes[start..end], 10);
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    const bound = port orelse return error.StartFailed;
    var c = try Client.init(a, io, bound);
    defer c.close();
    // Two requests in one TCP write, two independently framed keep-alive responses.
    try c.send(try std.fmt.allocPrint(a, "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\nGET /api/search?q=cat&limit=1 HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{ bound, bound }));
    try require((try c.response(false)).status == 200);
    const first = try c.response(false);
    try require(first.status == 200);
    const results = try json(a, first.body);
    try require(results.object.get("total_matches").?.integer == 2 and results.object.get("has_more").?.bool);
    const paged = try json(a, (try c.get("/api/search?q=cat&limit=1&offset=1")).body);
    try require(std.mem.eql(u8, paged.object.get("matches").?.array.items[0].object.get("title").?.string, "cats"));
    const unicode = try json(a, (try c.get("/api/search?q=%E7%8C%AB")).body);
    try require(unicode.object.get("total_matches").?.integer == 1);
    const language = try json(a, (try c.get("/api/search?q=chat&language=fr")).body);
    try require(std.mem.eql(u8, language.object.get("language").?.string, "French"));
    const random = try json(a, (try c.get("/api/random?language=English&kind=language")).body);
    try require(random.object.get("total_matches").?.integer == 1 and random.object.get("matches").?.array.items.len == 1);
    try require(random.object.get("matches").?.array.items[0].object.get("title").?.string.len != 0);
    const entry = try c.get("/api/entry?q=cat");
    try require(entry.status == 200);
    const ev = (try json(a, entry.body)).object.get("entries").?.array.items[0];
    try require(std.mem.indexOf(u8, ev.object.get("source").?.string, "Meaning of [[cat]]") != null);
    try require((try c.get("/api/entry?q=cat&kind=citations")).status == 200);
    const before = try json(a, (try c.get("/api/stats")).body);
    _ = try c.get("/api/search?q=word&limit=100");
    const after = try json(a, (try c.get("/api/stats")).body);
    try require(before.object.get("index_builds").?.integer == after.object.get("index_builds").?.integer);
    if (compressed) try require(after.object.get("xz_blocks").?.integer > 1 and after.object.get("decoded_blocks").?.integer < after.object.get("xz_blocks").?.integer);
    try require((try c.get("/api/search?q=cat&q=dog")).status == 400);
    try require((try c.get("/api/entry?q=absent")).status == 404);
    try require((try c.get("/api/search?language=absent")).status == 404);
    try require((try c.get("/not-a-route")).status == 404);
    try c.send(try std.fmt.allocPrint(a, "HEAD /api/health HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{bound}));
    try require((try c.response(true)).status == 200);
    const shell = try c.get("/");
    try require(shell.status == 200 and std.mem.indexOf(u8, shell.body, "\"mode\":\"live\"") != null and std.mem.indexOf(u8, shell.headers, "Content-Security-Policy") != null);
    {
        var blocked = try Client.init(a, io, bound);
        defer blocked.close();
        try blocked.send("GET /api/health HTTP/1.1\r\nHost: unrelated.invalid\r\n\r\n");
        try require((try blocked.response(false)).status == 403);
    }
    {
        var post = try Client.init(a, io, bound);
        defer post.close();
        try post.send(try std.fmt.allocPrint(a, "POST /api/search HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Length: 0\r\n\r\n", .{bound}));
        try require((try post.response(false)).status == 405);
    }
    _ = try checked(L.kill(child.id.?, .TERM));
    const finished = try child.wait(io);
    try require(finished == .exited and finished.exited == 0);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    const root = try std.fmt.allocPrint(a, "{s}/http-integration-{d}-{d}", .{ args[2], std.os.linux.getpid(), std.Io.Clock.awake.now(io).toNanoseconds() });
    try fixture(io, a, root);
    try exercise(io, a, args[1], root, try std.fs.path.join(a, &.{ root, "raw-server.log" }), false);
    // Compress already-built logical blobs, remove only our owned original fixture files.
    for ([_][]const u8{ "English", "French" }) |lang| {
        const p = try languagePath(a, root, lang);
        const result = try std.process.run(a, io, .{ .argv = &.{ "xz", "-0", "--threads=1", "--block-size=4KiB", p } });
        try require(result.term == .exited and result.term.exited == 0);
    }
    try exercise(io, a, args[1], root, try std.fs.path.join(a, &.{ root, "xz-server.log" }), true);
    try exercise(io, a, args[1], root, try std.fs.path.join(a, &.{ root, "warm-server.log" }), true);
    std.debug.print("HTTP_INTEGRATION_PASS: live search/entry/random/languages/collections, pagination/Unicode, one-connection pipelining, HEAD, bounded invalid queries, origin/method rejection, retained indexes, compressed-only + warm restart, clean SIGTERM\nArtifacts: {s}\n", .{root});
}
