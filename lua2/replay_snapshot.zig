pub const vm_instruction_limit: u64 = 50_000_000;
const std = @import("std");
const host = @import("wiktionary_runtime.zig");
const exec = @import("vm_exec.zig");
const xml_decode = @import("xml_decode");
const page_index = @import("page_store_index.zig");

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};

fn mmapPath(io: std.Io, path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}
fn between(hay: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const a = std.mem.indexOf(u8, hay, open) orelse return null;
    const begin = a + open.len;
    const b = std.mem.indexOfPos(u8, hay, begin, close) orelse return null;
    return hay[begin..b];
}

fn pageText(page: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, page, "<text") orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, page, start, '>') orelse return null;
    const begin = gt + 1;
    const end = std.mem.indexOfPos(u8, page, begin, "</text>") orelse return null;
    return page[begin..end];
}

fn decode(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    return xml_decode.decodeSinglePassAlloc(a, raw);
}

const PageStore = struct {
    xml: []const u8,
    index: []const u8,
    count: usize,

    fn pageAt(self: *const PageStore, offset64: u64) ?[]const u8 {
        const offset = std.math.cast(usize, offset64) orelse return null;
        if (offset >= self.xml.len or !std.mem.startsWith(u8, self.xml[offset..], "<page>")) return null;
        const close = std.mem.indexOfPos(u8, self.xml, offset + 6, "</page>") orelse return null;
        return self.xml[offset .. close + 7];
    }

    fn firstHash(self: *const PageStore, hash: u64) usize {
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (page_index.entryAt(self.index, mid).hash < hash) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn findPage(self: *const PageStore, a: std.mem.Allocator, title: []const u8) !?[]const u8 {
        const hash = page_index.titleHash(title);
        var i = self.firstHash(hash);
        while (i < self.count) : (i += 1) {
            const entry = page_index.entryAt(self.index, i);
            if (entry.hash != hash) break;
            const page = self.pageAt(entry.page_offset) orelse return error.BadPageIndex;
            const raw = between(page, "<title>", "</title>") orelse return error.BadPageIndex;
            const decoded = try decode(a, raw);
            if (std.mem.eql(u8, decoded, title)) return page;
        }
        return null;
    }

    fn exists(ctx: *anyopaque, a: std.mem.Allocator, title: []const u8) anyerror!bool {
        const self: *PageStore = @ptrCast(@alignCast(ctx));
        return (try self.findPage(a, title)) != null;
    }

    fn get(ctx: *anyopaque, a: std.mem.Allocator, title: []const u8) anyerror!?[]const u8 {
        const self: *PageStore = @ptrCast(@alignCast(ctx));
        const page = try self.findPage(a, title) orelse return null;
        const raw = pageText(page) orelse return null;
        return try decode(a, raw);
    }
};

const Failure = struct {
    count: usize = 0,
    page: []const u8 = "",
    module: []const u8 = "<native>",
    detail: []const u8 = "",
    function_id: u32 = 0,
    pc: usize = 0,
};
fn recordFailure(
    a: std.mem.Allocator,
    failures: *std.StringHashMapUnmanaged(Failure),
    runtime: *const host.Runtime,
    vm: *const exec.Vm,
    page: []const u8,
    err: anyerror,
) !void {
    const name = @errorName(err);
    const gop = try failures.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = .{ .page = try a.dupe(u8, page) };
        if (err == error.ModuleNotFound) {
            if (runtime.last_missing_module) |missing| gop.value_ptr.detail = try a.dupe(u8, missing);
        } else if (err == error.TemplateNotFound) {
            if (runtime.last_missing_template) |missing| gop.value_ptr.detail = try a.dupe(u8, missing);
        } else if (err == error.WikibaseDataMissing) {
            if (runtime.last_missing_wikibase) |missing| gop.value_ptr.detail = try a.dupe(u8, missing);
        } else if (err == error.MalformedWikitext) {
            if (runtime.last_malformed_wikitext) |detail| gop.value_ptr.detail = try a.dupe(u8, detail);
        } else if (err == error.UnsupportedParserFunction) {
            if (runtime.last_unsupported_parser) |detail| gop.value_ptr.detail = try a.dupe(u8, detail);
        } else if (err == error.NotImplemented) {
            if (runtime.last_not_implemented) |detail| gop.value_ptr.detail = try a.dupe(u8, detail);
        } else if (err == error.LuaRaised and vm.last_error == .string) {
            gop.value_ptr.detail = try a.dupe(u8, vm.last_error.string);
        }
        if (vm.failure) |failure| {
            gop.value_ptr.module = host.titleForProgram(runtime, failure.program) orelse "<unknown>";
            gop.value_ptr.function_id = failure.function_id;
            gop.value_ptr.pc = failure.pc;
        }
    }
    gop.value_ptr.count += 1;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 6) return error.Usage;
    const limit = if (args.len > 6) try std.fmt.parseInt(usize, args[6], 10) else std.math.maxInt(usize);
    var persistent_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer persistent_arena.deinit();
    const persistent = persistent_arena.allocator();
    var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer page_arena.deinit();

    var runtime = host.Runtime.init(persistent, init.io, args[3]);
    try runtime.loadManifest(args[1]);
    try runtime.loadRedirects(args[2]);
    try runtime.loadSiblingTemplates();
    runtime.loadSiblingWikibaseSitelinks() catch |err| {
        if (err != error.FileNotFound) return err;
        std.debug.print("SNAPSHOT_ONLY missing loadSiblingWikibaseSitelinks; historical gate unavailable\n", .{});
    };
    runtime.loadSiblingInterwikiMap() catch |err| {
        if (err != error.FileNotFound) return err;
        std.debug.print("SNAPSHOT_ONLY missing loadSiblingInterwikiMap; historical gate unavailable\n", .{});
    };
    try runtime.loadBundle(args[5]);

    var mapped = try mmapPath(init.io, args[4]);
    defer mapped.deinit();
    const manifest_dir = std.fs.path.dirname(args[1]) orelse ".";
    const page_index_path = try std.fs.path.join(persistent, &.{ manifest_dir, "page-index.dwpi" });
    var mapped_index = try mmapPath(init.io, page_index_path);
    defer mapped_index.deinit();
    var page_store = PageStore{
        .xml = mapped.bytes,
        .index = mapped_index.bytes,
        .count = try page_index.count(mapped_index.bytes),
    };
    runtime.setPageContentProvider(.{ .ctx = &page_store, .get = PageStore.get, .exists = PageStore.exists });
    var failures: std.StringHashMapUnmanaged(Failure) = .empty;
    var hash = std.hash.Wyhash.init(0);
    var scanned: usize = 0;
    var pages: usize = 0;
    var success: usize = 0;
    var pos: usize = 0;
    var released: usize = 0;
    if (args.len > 7) {
        const target_page = try page_store.findPage(persistent, args[7]) orelse return error.PageNotFound;
        pos = @intFromPtr(target_page.ptr) - @intFromPtr(mapped.bytes.ptr);
        released = pos - (pos % std.heap.page_size_min);
    }

    while (pages < limit) {
        const start = std.mem.indexOfPos(u8, mapped.bytes, pos, "<page>") orelse break;
        const close = std.mem.indexOfPos(u8, mapped.bytes, start + 6, "</page>") orelse break;
        const end = close + 7;
        const page = mapped.bytes[start..end];
        pos = end;
        scanned += 1;
        if (pos - released >= 64 * 1024 * 1024) {
            const page_size = std.heap.page_size_min;
            const release_end = (start / page_size) * page_size;
            if (release_end > released) {
                const base: [*]u8 = @ptrCast(@constCast(mapped.bytes.ptr));
                const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(base + released);
                std.posix.madvise(ptr, release_end - released, std.posix.MADV.DONTNEED) catch {};
                released = release_end;
            }
        }
        const ns = between(page, "<ns>", "</ns>") orelse continue;
        if (!std.mem.eql(u8, ns, "0")) continue;
        const title_raw = between(page, "<title>", "</title>") orelse continue;
        const text_raw = pageText(page) orelse continue;

        _ = page_arena.reset(.retain_capacity);
        const a = page_arena.allocator();
        const title = try decode(a, title_raw);
        const text = try decode(a, text_raw);
        runtime.beginPage(a, title);
        if (between(page, "<revision>", "</revision>")) |revision|
            if (between(revision, "<id>", "</id>")) |revision_id| runtime.setCurrentRevisionId(revision_id);
        var vm = try exec.Vm.init(a);
        try runtime.install(&vm);
        pages += 1;
        vm.failure = null;
        vm.last_error = .nil;
        if (runtime.expandFragment(&vm, title, text)) |rendered| {
            success += 1;
            hash.update(rendered);
            std.debug.print("PAGE_OK\t{s}\t{d}\t{x}\n", .{ title, rendered.len, std.hash.Wyhash.hash(0, rendered) });
        } else |err| {
            std.debug.print("PAGE_FAIL\t{s}\t{s}\n", .{ title, @errorName(err) });
            try recordFailure(persistent, &failures, &runtime, &vm, title, err);
        }
        if (pages % 1000 == 0)
            std.debug.print("pages={d} scanned={d} ok={d} fail={d} offset={d}\n", .{
                pages,
                scanned,
                success,
                pages - success,
                pos,
            });
    }

    std.debug.print("TOTAL pages={d} scanned={d} success={d} fail={d} hash={x}\n", .{
        pages,
        scanned,
        success,
        pages - success,
        hash.final(),
    });
    var rows: std.ArrayList(struct { name: []const u8, failure: Failure }) = .empty;
    var it = failures.iterator();
    while (it.next()) |entry|
        try rows.append(persistent, .{ .name = entry.key_ptr.*, .failure = entry.value_ptr.* });
    std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
        fn less(_: void, lhs: @TypeOf(rows.items[0]), rhs: @TypeOf(rows.items[0])) bool {
            return lhs.failure.count > rhs.failure.count;
        }
    }.less);
    for (rows.items) |row| std.debug.print(
        "FAIL\t{d}\t{s}\tpage={s}\tinner={s}\tfn={d}\tpc={d}\tdetail={s}\n",
        .{
            row.failure.count,
            row.name,
            row.failure.page,
            row.failure.module,
            row.failure.function_id,
            row.failure.pc,
            row.failure.detail,
        },
    );
}
