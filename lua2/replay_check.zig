const std = @import("std");
const host = @import("wiktionary_runtime.zig");
const exec = @import("vm_exec.zig");
const xml_decode = @import("xml_decode");

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
fn unescape(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        const c = raw[i];
        i += 1;
        try out.append(a, switch (c) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            else => c,
        });
    }
    return out.toOwnedSlice(a);
}

fn decodeField(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const tsv = try unescape(a, raw);
    return xml_decode.decodeSinglePassAlloc(a, tsv);
}
const Failure = struct {
    count: usize = 0,
    page: []const u8 = "",
    inner_module: []const u8 = "<native>",
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
        if (vm.failure) |failure| {
            gop.value_ptr.inner_module = host.titleForProgram(runtime, failure.program) orelse "<unknown>";
            gop.value_ptr.function_id = failure.function_id;
            gop.value_ptr.pc = failure.pc;
        }
    }
    gop.value_ptr.count += 1;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 6) return error.Usage;
    const limit = if (args.len > 6)
        try std.fmt.parseInt(usize, args[6], 10)
    else
        std.math.maxInt(usize);

    var persistent_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer persistent_arena.deinit();
    const persistent = persistent_arena.allocator();
    var page_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer page_arena.deinit();

    var runtime = host.Runtime.init(persistent, init.io, args[3]);
    try runtime.loadManifest(args[1]);
    try runtime.loadRedirects(args[2]);
    try runtime.loadSiblingTemplates();
    try runtime.loadBundle(args[5]);

    var mapped = try mmapPath(init.io, args[4]);
    defer mapped.deinit();
    var failures: std.StringHashMapUnmanaged(Failure) = .empty;
    var attempted: usize = 0;
    var success: usize = 0;
    var pages: usize = 0;
    var hash = std.hash.Wyhash.init(0);
    var current_page_raw: ?[]const u8 = null;
    var vm: exec.Vm = undefined;
    var page_title: []const u8 = "";
    var pos: usize = 0;

    while (pos < mapped.bytes.len and attempted < limit) {
        const nl = std.mem.indexOfScalarPos(u8, mapped.bytes, pos, '\n') orelse mapped.bytes.len;
        const line = mapped.bytes[pos..nl];
        pos = @min(nl + 1, mapped.bytes.len);
        if (line.len < 3 or !std.mem.startsWith(u8, line, "W\t")) continue;
        const split = std.mem.indexOfScalarPos(u8, line, 2, '\t') orelse continue;
        const page_raw = line[2..split];
        if (current_page_raw == null or !std.mem.eql(u8, current_page_raw.?, page_raw)) {
            _ = page_arena.reset(.retain_capacity);
            const page_alloc = page_arena.allocator();
            page_title = try decodeField(page_alloc, page_raw);
            runtime.beginPage(page_alloc, page_title);
            vm = try exec.Vm.init(page_alloc);
            try runtime.install(&vm);
            current_page_raw = page_raw;
            pages += 1;
        }
        const source = try decodeField(page_arena.allocator(), line[split + 1 ..]);
        attempted += 1;
        vm.failure = null;
        vm.last_error = .nil;
        if (runtime.expandFragment(&vm, page_title, source)) |rendered| {
            success += 1;
            hash.update(rendered);
        } else |err| try recordFailure(persistent, &failures, &runtime, &vm, page_title, err);
        if (attempted % 10000 == 0)
            std.debug.print("checked={d} pages={d} ok={d} fail={d}\n", .{ attempted, pages, success, attempted - success });
    }

    std.debug.print("TOTAL attempted={d} pages={d} success={d} fail={d} hash={x}\n", .{
        attempted, pages, success, attempted - success, hash.final(),
    });
    var rows: std.ArrayList(struct { name: []const u8, failure: Failure }) = .empty;
    var it = failures.iterator();
    while (it.next()) |entry| try rows.append(persistent, .{ .name = entry.key_ptr.*, .failure = entry.value_ptr.* });
    std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
        fn less(_: void, x: @TypeOf(rows.items[0]), y: @TypeOf(rows.items[0])) bool {
            return x.failure.count > y.failure.count;
        }
    }.less);
    for (rows.items) |row| std.debug.print(
        "FAIL\t{d}\t{s}\tpage={s}\tinner={s}\tfn={d}\tpc={d}\n",
        .{ row.failure.count, row.name, row.failure.page, row.failure.inner_module, row.failure.function_id, row.failure.pc },
    );
}
