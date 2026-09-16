const std = @import("std");
const zxml = @import("zxml");
const xml_decode = @import("xml_decode");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = false,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

const Capture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    redirect_raw: ?[]const u8 = null,
    page_id_raw: ?[]const u8 = null,
    revision_id_raw: ?[]const u8 = null,
    revision_timestamp_raw: ?[]const u8 = null,
    revision_user_raw: ?[]const u8 = null,
    model_raw: ?[]const u8 = null,
    format_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();
        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "redirect")) {
            self.redirect_raw = node.getAttributeValueRaw("title");
        } else if (node.depth == 1 and std.mem.eql(u8, name, "id")) {
            self.page_id_raw = node.leadingTextRaw();
        } else if (node.depth == 2 and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            if (std.mem.eql(u8, name, "id")) self.revision_id_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "timestamp")) self.revision_timestamp_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "model")) self.model_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "format")) self.format_raw = node.leadingTextRaw() else if (std.mem.eql(u8, name, "text")) self.text_raw = node.leadingTextRaw();
        } else if (node.depth == 3 and std.mem.eql(u8, self.names_by_depth[1], "revision") and std.mem.eql(u8, self.names_by_depth[2], "contributor") and (std.mem.eql(u8, name, "username") or std.mem.eql(u8, name, "ip"))) {
            self.revision_user_raw = node.leadingTextRaw();
        }
        return true;
    }
};

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

fn writeAllFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeTsvField(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => {
            try w.writeAll("\\u00");
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0x0f]);
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeManifestRow(
    w: *std.Io.Writer,
    page_id: u64,
    revision_id: ?u64,
    title: []const u8,
    model: []const u8,
    format: ?[]const u8,
    source: []const u8,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    try w.print("{{\"page_id\":{d},\"revision_id\":", .{page_id});
    if (revision_id) |id| try w.print("{d}", .{id}) else try w.writeAll("null");
    try w.writeAll(",\"title\":");
    try writeJsonString(w, title);
    try w.writeAll(",\"model\":");
    try writeJsonString(w, model);
    try w.writeAll(",\"format\":");
    if (format) |value| try writeJsonString(w, value) else try w.writeAll("null");
    try w.print(",\"bytes\":{d},\"sha256\":\"{s}\",\"path\":\"modules/{d}.lua\"}}\n", .{
        source.len,
        &digest_hex,
        page_id,
    });
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) return error.Usage;
    const emit_page_index = if (args.len == 4) blk: {
        if (!std.mem.eql(u8, args[3], "--page-index")) return error.Usage;
        break :blk true;
    } else false;
    const input_path = args[1];
    const output_root = args[2];
    const modules_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/modules", .{output_root});
    const manifest_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/manifest.jsonl", .{output_root});
    const redirects_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/module-redirects.tsv", .{output_root});
    const page_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/page-index.tsv", .{output_root});
    try std.Io.Dir.cwd().createDirPath(init.io, modules_dir);

    var page_index_file: ?std.Io.File = if (emit_page_index)
        try std.Io.Dir.cwd().createFile(init.io, page_index_path, .{ .truncate = true })
    else
        null;
    defer if (page_index_file) |*file| file.close(init.io);
    var page_index_buf: [256 * 1024]u8 = undefined;
    var page_index_writer = if (page_index_file) |*file| file.writer(init.io, &page_index_buf) else null;
    const pw: ?*std.Io.Writer = if (page_index_writer) |*writer| &writer.interface else null;

    var redirects_file = try std.Io.Dir.cwd().createFile(init.io, redirects_path, .{ .truncate = true });
    defer redirects_file.close(init.io);
    var redirects_buf: [64 * 1024]u8 = undefined;
    var redirects_writer = redirects_file.writer(init.io, &redirects_buf);
    const rw = &redirects_writer.interface;

    var manifest_file = try std.Io.Dir.cwd().createFile(init.io, manifest_path, .{ .truncate = true });
    defer manifest_file.close(init.io);
    var manifest_buf: [256 * 1024]u8 = undefined;
    var manifest_writer = manifest_file.writer(init.io, &manifest_buf);
    const mw = &manifest_writer.interface;

    var mapped = try mmapPath(input_path);
    defer mapped.deinit();
    var parser = StreamParser.init(std.heap.smp_allocator);
    defer parser.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var pos: usize = 0;
    var pages: usize = 0;
    var modules: usize = 0;
    var redirects: usize = 0;
    var source_bytes: u64 = 0;
    while (std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>")) |start| {
        const end_start = std.mem.indexOfPos(u8, mapped.bytes, start, "</page>") orelse return error.TruncatedXml;
        const page_end = end_start + "</page>".len;
        const page = mapped.bytes[start..page_end];
        pos = page_end;
        pages += 1;
        const looks_like_module = std.mem.indexOf(u8, page, "<ns>828</ns>") != null;
        if (!emit_page_index and !looks_like_module) continue;

        var capture: Capture = .{};
        try parser.parse(page, &capture, Capture.onNode);
        var decoded_title: ?[]const u8 = null;
        var decoded_redirect: ?[]const u8 = null;
        var indexed_page_id: ?u64 = null;
        var indexed_revision_id: ?u64 = null;

        if (pw) |page_writer| {
            const ns_raw = capture.ns_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const parsed_ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const title_raw = capture.title_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            const page_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.page_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_id = std.fmt.parseInt(u64, std.mem.trim(u8, capture.revision_id_raw orelse return error.InvalidPageMetadata, " \t\r\n"), 10) catch return error.InvalidPageMetadata;
            const revision_timestamp_raw = capture.revision_timestamp_raw orelse return error.InvalidPageMetadata;
            const model_raw = capture.model_raw orelse return error.InvalidPageMetadata;
            const text_raw = capture.text_raw orelse "";
            const source_offset: u64 = if (text_raw.len == 0) 0 else blk: {
                const base = @intFromPtr(mapped.bytes.ptr);
                const ptr = @intFromPtr(text_raw.ptr);
                if (ptr < base) return error.InvalidXmlSlice;
                const offset = ptr - base;
                if (offset > mapped.bytes.len or text_raw.len > mapped.bytes.len - offset) return error.InvalidXmlSlice;
                break :blk @intCast(offset);
            };
            const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
            const revision_timestamp = try xml_decode.decodeSinglePassAlloc(arena.allocator(), revision_timestamp_raw);
            const revision_user = try xml_decode.decodeSinglePassAlloc(arena.allocator(), capture.revision_user_raw orelse "");
            const content_model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
            const redirect = if (capture.redirect_raw) |raw| try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw) else null;
            if (std.mem.indexOfAny(u8, title, "\t\r\n") != null) return error.InvalidPageTitle;
            if (redirect) |target| if (std.mem.indexOfAny(u8, target, "\t\r\n") != null) return error.InvalidPageTitle;
            if (content_model.len == 0 or std.mem.indexOfAny(u8, revision_timestamp, "\t\r\n") != null or std.mem.indexOfAny(u8, revision_user, "\t\r\n") != null or std.mem.indexOfAny(u8, content_model, "\t\r\n") != null) return error.InvalidPageMetadata;
            try page_writer.print("{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
                source_offset,
                text_raw.len,
                title,
                redirect orelse "",
                page_id,
                revision_id,
                revision_timestamp,
                revision_user,
                content_model,
                parsed_ns,
                @intFromBool(capture.text_raw != null),
                @intFromBool(std.mem.indexOfScalar(u8, text_raw, '&') != null),
            });
            decoded_title = title;
            decoded_redirect = redirect;
            indexed_page_id = page_id;
            indexed_revision_id = revision_id;
            if (parsed_ns != 828) {
                _ = arena.reset(.retain_capacity);
                continue;
            }
        }

        if (capture.redirect_raw) |target_raw| {
            if (capture.title_raw) |title_raw| {
                const title = decoded_title orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
                const target = decoded_redirect orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), target_raw);
                try rw.writeAll("M\t");
                try writeTsvField(rw, title);
                try rw.writeByte('\t');
                try writeTsvField(rw, target);
                try rw.writeByte('\n');
                redirects += 1;
                decoded_title = title;
            }
        }
        const page_id = indexed_page_id orelse blk: {
            const page_id_raw = capture.page_id_raw orelse {
                _ = arena.reset(.retain_capacity);
                continue;
            };
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, page_id_raw, " \t\r\n"), 10) catch {
                _ = arena.reset(.retain_capacity);
                continue;
            };
        };
        const model_raw = capture.model_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
        if (!std.mem.eql(u8, model, "Scribunto")) {
            _ = arena.reset(.retain_capacity);
            continue;
        }
        const title_raw = capture.title_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const text_raw = capture.text_raw orelse {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        const title = decoded_title orelse try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
        const source = try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw);
        const revision_id = indexed_revision_id orelse if (capture.revision_id_raw) |raw|
            std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null
        else
            null;
        const format = if (capture.format_raw) |raw|
            try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw)
        else
            null;
        const module_path = try std.fmt.allocPrint(arena.allocator(), "{s}/{d}.lua", .{ modules_dir, page_id });
        try writeAllFile(init.io, module_path, source);
        try writeManifestRow(mw, page_id, revision_id, title, model, format, source);

        modules += 1;
        source_bytes += source.len;
        if (modules % 1000 == 0) {
            try mw.flush();
            try rw.flush();
            if (pw) |page_writer| try page_writer.flush();
            std.debug.print("modules={d} redirects={d} pages={d} source_bytes={d}\n", .{ modules, redirects, pages, source_bytes });
        }
        _ = arena.reset(.retain_capacity);
    }
    try mw.flush();
    try rw.flush();
    if (pw) |page_writer| try page_writer.flush();
    std.debug.print("TOTAL pages={d} modules={d} redirects={d} source_bytes={d}\n", .{ pages, modules, redirects, source_bytes });
}
