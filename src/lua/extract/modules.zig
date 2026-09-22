const std = @import("std");
const xml_decode = @import("xml_decode");
const lua_usage = @import("lua_usage");
const wikimedia_dump = @import("wikimedia_dump");

const Capture = wikimedia_dump.PageView;

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

const PageItem = struct {
    capture: Capture,
    source: wikimedia_dump.PageSource,
};

fn sliceOffset(container: []const u8, slice: []const u8) !usize {
    if (slice.len == 0) return 0;
    const base = @intFromPtr(container.ptr);
    const ptr = @intFromPtr(slice.ptr);
    if (ptr < base) return error.InvalidXmlSlice;
    const offset = ptr - base;
    if (offset > container.len or slice.len > container.len - offset) return error.InvalidXmlSlice;
    return offset;
}

const InputPages = union(enum) {
    raw: struct {
        mapped: Mapped,
        pages: wikimedia_dump.PageIterator,
    },
    compressed: struct {
        walker: wikimedia_dump.MultistreamWalker,
        pages: wikimedia_dump.PageIterator = .{ .bytes = "" },
        stream_id: u32 = 0,
    },

    fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8, index_path: ?[]const u8) !InputPages {
        if (std.mem.endsWith(u8, path, ".bz2")) {
            const index = index_path orelse return error.MultistreamIndexPathRequired;
            return .{ .compressed = .{ .walker = try wikimedia_dump.MultistreamWalker.open(io, allocator, path, index) } };
        }
        var mapped = try mmapPath(path);
        errdefer mapped.deinit();
        return .{ .raw = .{ .mapped = mapped, .pages = .{ .bytes = mapped.bytes } } };
    }

    fn deinit(self: *InputPages) void {
        switch (self.*) {
            .raw => |*raw| raw.mapped.deinit(),
            .compressed => |*compressed| compressed.walker.deinit(),
        }
        self.* = undefined;
    }

    fn next(self: *InputPages) !?PageItem {
        switch (self.*) {
            .raw => |*raw| {
                const capture = try raw.pages.next() orelse return null;
                const text = capture.text_raw orelse "";
                return .{
                    .capture = capture,
                    .source = .{ .raw_xml = .{
                        .offset = @intCast(try sliceOffset(raw.mapped.bytes, text)),
                        .len = text.len,
                    } },
                };
            },
            .compressed => |*compressed| {
                while (true) {
                    if (try compressed.pages.next()) |capture| {
                        const text = capture.text_raw orelse "";
                        return .{
                            .capture = capture,
                            .source = .{ .multistream_bz2 = .{
                                .stream_id = compressed.stream_id,
                                .offset = try sliceOffset(compressed.pages.bytes, text),
                                .len = text.len,
                            } },
                        };
                    }
                    const member = try compressed.walker.next() orelse return null;
                    compressed.stream_id = member.id;
                    compressed.pages = .{ .bytes = member.bytes };
                }
            },
        }
    }
};

fn writeStreamTable(io: std.Io, allocator: std.mem.Allocator, dump_path: []const u8, index_path: []const u8, output_path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [128 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(wikimedia_dump.stream_index_header ++ "\n");
    var streams = try wikimedia_dump.StreamIterator.open(io, allocator, dump_path, index_path);
    defer streams.close();
    while (try streams.next()) |stream|
        try writer.interface.print("{d}\t{d}\t{d}\n", .{ stream.id, stream.span.offset, stream.span.len });
    try writer.interface.flush();
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

fn writePageIndexRow(
    w: *std.Io.Writer,
    source: wikimedia_dump.PageSource,
    title: []const u8,
    redirect: ?[]const u8,
    page_id: u64,
    revision_id: u64,
    revision_timestamp: []const u8,
    revision_user: []const u8,
    content_model: []const u8,
    ns: u32,
    has_source: bool,
    source_needs_decode: bool,
) !void {
    switch (source) {
        .raw_xml => |loc| try w.print("{d}\t{d}\t", .{ loc.offset, loc.len }),
        .multistream_bz2 => |loc| try w.print("{d}\t{d}\t{d}\t", .{ loc.stream_id, loc.offset, loc.len }),
    }
    try w.print("{s}\t{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
        title,
        redirect orelse "",
        page_id,
        revision_id,
        revision_timestamp,
        revision_user,
        content_model,
        ns,
        @intFromBool(has_source),
        @intFromBool(source_needs_decode),
    });
}

const UsageCountMap = std.StringHashMapUnmanaged(u64);

fn incrementUsageCount(a: std.mem.Allocator, counts: *UsageCountMap, key: []const u8) !void {
    if (counts.getPtr(key)) |value| {
        value.* = std.math.add(u64, value.*, 1) catch std.math.maxInt(u64);
        return;
    }
    const owned = try a.dupe(u8, key);
    errdefer a.free(owned);
    try counts.put(a, owned, 1);
}

fn writeUsageEdge(w: *std.Io.Writer, kind: u8, source: []const u8, target: []const u8) !void {
    try w.writeByte(kind);
    try w.writeByte('\t');
    try writeTsvField(w, source);
    try w.writeByte('\t');
    try writeTsvField(w, target);
    try w.writeByte('\n');
}

fn writeDynamicUsage(w: *std.Io.Writer, kind: []const u8, source: ?[]const u8) !void {
    try w.writeAll("D\t");
    try w.writeAll(kind);
    if (source) |name| {
        try w.writeByte('\t');
        try writeTsvField(w, name);
    }
    try w.writeByte('\n');
}

fn writeUsageCounts(
    a: std.mem.Allocator,
    w: *std.Io.Writer,
    kind: u8,
    counts: *const UsageCountMap,
) !void {
    const keys = try a.alloc([]const u8, counts.count());
    defer a.free(keys);
    var it = counts.keyIterator();
    var at: usize = 0;
    while (it.next()) |key| : (at += 1) keys[at] = key.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    for (keys) |key| {
        try w.writeByte(kind);
        try w.writeByte('\t');
        try writeTsvField(w, key);
        try w.print("\t{d}\n", .{counts.get(key).?});
    }
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
    const option = if (args.len == 4) args[3] else "";
    const emit_page_index = std.mem.eql(u8, option, "--page-index");
    const usage_only = std.mem.eql(u8, option, "--usage-only");
    if (args.len == 4 and !emit_page_index and !usage_only) return error.Usage;
    const input_path = args[1];
    const output_root = args[2];
    const compressed = std.mem.endsWith(u8, input_path, ".bz2");
    const multistream_index_path: ?[]const u8 = if (compressed)
        try wikimedia_dump.deriveMultistreamIndexPath(init.arena.allocator(), input_path)
    else
        null;
    const modules_dir = try std.fmt.allocPrint(init.arena.allocator(), "{s}/modules", .{output_root});
    const manifest_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/manifest.jsonl", .{output_root});
    const redirects_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/module-redirects.tsv", .{output_root});
    const page_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/page-index.tsv", .{output_root});
    const stream_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/dump-streams.tsv", .{output_root});
    const title_index_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ output_root, wikimedia_dump.page_title_index_filename });
    const usage_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/lua-usage.tsv", .{output_root});
    try std.Io.Dir.cwd().createDirPath(init.io, modules_dir);
    if (emit_page_index and compressed)
        try writeStreamTable(init.io, init.arena.allocator(), input_path, multistream_index_path.?, stream_index_path);

    var page_index_file: ?std.Io.File = if (emit_page_index)
        try std.Io.Dir.cwd().createFile(init.io, page_index_path, .{ .truncate = true })
    else
        null;
    defer if (page_index_file) |*file| file.close(init.io);
    var page_index_buf: [256 * 1024]u8 = undefined;
    var page_index_writer = if (page_index_file) |*file| file.writer(init.io, &page_index_buf) else null;
    const pw: ?*std.Io.Writer = if (page_index_writer) |*writer| &writer.interface else null;
    if (compressed) if (pw) |writer| try writer.writeAll(wikimedia_dump.page_index_v2_header ++ "\n");

    var usage_file: ?std.Io.File = if (emit_page_index or usage_only)
        try std.Io.Dir.cwd().createFile(init.io, usage_path, .{ .truncate = true })
    else
        null;
    defer if (usage_file) |*file| file.close(init.io);
    var usage_buf: [256 * 1024]u8 = undefined;
    var usage_writer = if (usage_file) |*file| file.writer(init.io, &usage_buf) else null;
    const uw: ?*std.Io.Writer = if (usage_writer) |*writer| &writer.interface else null;
    if (uw) |writer| try writer.writeAll("# dict-lua-usage-v1\n");

    var root_template_usage: UsageCountMap = .empty;
    defer root_template_usage.deinit(init.arena.allocator());
    var root_module_usage: UsageCountMap = .empty;
    defer root_module_usage.deinit(init.arena.allocator());
    var dynamic_root_module = false;
    var dynamic_root_template = false;

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

    var input = try InputPages.open(init.io, std.heap.smp_allocator, input_path, multistream_index_path);
    defer input.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var pages: usize = 0;
    var modules: usize = 0;
    var redirects: usize = 0;
    var source_bytes: u64 = 0;
    while (try input.next()) |item| {
        const capture = item.capture;
        const page = capture.raw;
        pages += 1;
        const looks_like_module = std.mem.indexOf(u8, page, "<ns>828</ns>") != null;
        if (!emit_page_index and !usage_only and !looks_like_module) continue;

        var decoded_title: ?[]const u8 = null;
        var decoded_redirect: ?[]const u8 = null;
        var indexed_page_id: ?u64 = null;
        var indexed_revision_id: ?u64 = null;

        if (pw != null or usage_only) {
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
            const title = try xml_decode.decodeSinglePassAlloc(arena.allocator(), title_raw);
            const revision_timestamp = try xml_decode.decodeSinglePassAlloc(arena.allocator(), revision_timestamp_raw);
            const revision_user = try xml_decode.decodeSinglePassAlloc(arena.allocator(), capture.revision_user_raw orelse "");
            const content_model = try xml_decode.decodeSinglePassAlloc(arena.allocator(), model_raw);
            const redirect = if (capture.redirect_raw) |raw| try xml_decode.decodeSinglePassAlloc(arena.allocator(), raw) else null;
            if (std.mem.indexOfAny(u8, title, "\t\r\n") != null) return error.InvalidPageTitle;
            if (redirect) |target| if (std.mem.indexOfAny(u8, target, "\t\r\n") != null) return error.InvalidPageTitle;
            if (content_model.len == 0 or std.mem.indexOfAny(u8, revision_timestamp, "\t\r\n") != null or std.mem.indexOfAny(u8, revision_user, "\t\r\n") != null or std.mem.indexOfAny(u8, content_model, "\t\r\n") != null) return error.InvalidPageMetadata;
            if (pw) |page_writer| try writePageIndexRow(
                page_writer,
                item.source,
                title,
                redirect,
                page_id,
                revision_id,
                revision_timestamp,
                revision_user,
                content_model,
                parsed_ns,
                capture.text_raw != null,
                std.mem.indexOfScalar(u8, text_raw, '&') != null,
            );
            decoded_title = title;
            decoded_redirect = redirect;
            indexed_page_id = page_id;
            indexed_revision_id = revision_id;

            if (uw) |usage_out| if (parsed_ns == 10 and redirect != null)
                try writeUsageEdge(usage_out, 'T', title, redirect.?);

            if (uw) |usage_out| if (redirect == null and std.mem.eql(u8, content_model, "wikitext") and
                std.mem.indexOf(u8, text_raw, "{{") != null)
            {
                const usage_source = if (std.mem.indexOfScalar(u8, text_raw, '&') != null)
                    try xml_decode.decodeSinglePassAlloc(arena.allocator(), text_raw)
                else
                    text_raw;
                var refs: std.ArrayList(lua_usage.Ref) = .empty;
                const scan_flags = if (parsed_ns == 10)
                    try lua_usage.scanTemplateWikitextFlags(arena.allocator(), usage_source, &refs)
                else if (parsed_ns != 828)
                    try lua_usage.scanWikitextFlags(arena.allocator(), usage_source, &refs)
                else
                    lua_usage.ScanFlags{};
                if (parsed_ns == 10) {
                    if (scan_flags.dynamic_module_target)
                        try writeDynamicUsage(usage_out, "module", title);
                    if (scan_flags.dynamic_template_target)
                        try writeDynamicUsage(usage_out, "template", title);
                    var seen_templates: std.StringHashMapUnmanaged(void) = .empty;
                    var seen_modules: std.StringHashMapUnmanaged(void) = .empty;
                    for (refs.items) |ref| switch (ref.kind) {
                        .template => {
                            if (seen_templates.contains(ref.target)) continue;
                            try seen_templates.put(arena.allocator(), ref.target, {});
                            try writeUsageEdge(usage_out, 'T', title, ref.target);
                        },
                        .module => {
                            if (seen_modules.contains(ref.target)) continue;
                            try seen_modules.put(arena.allocator(), ref.target, {});
                            try writeUsageEdge(usage_out, 'I', title, ref.target);
                        },
                    };
                } else if (parsed_ns != 828) {
                    dynamic_root_module = dynamic_root_module or scan_flags.dynamic_module_target;
                    dynamic_root_template = dynamic_root_template or scan_flags.dynamic_template_target;
                    var seen_templates: std.StringHashMapUnmanaged(void) = .empty;
                    var seen_modules: std.StringHashMapUnmanaged(void) = .empty;
                    for (refs.items) |ref| switch (ref.kind) {
                        .template => {
                            if (seen_templates.contains(ref.target)) continue;
                            try seen_templates.put(arena.allocator(), ref.target, {});
                            try incrementUsageCount(init.arena.allocator(), &root_template_usage, ref.target);
                        },
                        .module => {
                            if (seen_modules.contains(ref.target)) continue;
                            try seen_modules.put(arena.allocator(), ref.target, {});
                            try incrementUsageCount(init.arena.allocator(), &root_module_usage, ref.target);
                        },
                    };
                }
            };

            if (usage_only or parsed_ns != 828) {
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
    if (uw) |usage_out| {
        try writeUsageCounts(init.arena.allocator(), usage_out, 'R', &root_template_usage);
        try writeUsageCounts(init.arena.allocator(), usage_out, 'P', &root_module_usage);
        if (dynamic_root_module) try writeDynamicUsage(usage_out, "module", null);
        if (dynamic_root_template) try writeDynamicUsage(usage_out, "template", null);
        try usage_out.flush();
    }
    try mw.flush();
    try rw.flush();
    if (pw) |page_writer| try page_writer.flush();
    // Publish only after every compiler input is complete. Title-index sorting
    // is independent of Lua parsing/analysis and may continue concurrently.
    if (emit_page_index) {
        const ready_path = try std.fs.path.join(init.arena.allocator(), &.{ output_root, "compiler-inputs.ready" });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = "complete\n" });
    }
    if (emit_page_index)
        try wikimedia_dump.buildPageTitleIndex(init.io, std.heap.smp_allocator, page_index_path, title_index_path);
    std.debug.print(
        "TOTAL pages={d} modules={d} redirects={d} source_bytes={d} root_templates={d} root_modules={d}\n",
        .{ pages, modules, redirects, source_bytes, root_template_usage.count(), root_module_usage.count() },
    );
}
