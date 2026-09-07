const std = @import("std");

const FnKey = struct { page_id: u64, start: u32 };
const FnInfo = struct {
    start: u32,
    end: u32,
    name: []const u8,
};
const Call = struct {
    caller: u32,
    span_start: u32,
    span_end: u32,
    callee: []const u8,
};
const DynSite = struct {
    kind: u8,
    caller: u32,
    span_start: u32,
    span_end: u32,
};
const StartList = std.ArrayList(u32);

const ModuleInfo = struct {
    functions: std.ArrayList(FnInfo) = .empty,
    names: std.StringHashMapUnmanaged(*StartList) = .empty,
    calls: std.AutoHashMapUnmanaged(u32, std.ArrayList(Call)) = .empty,
    dynamic_sites: std.AutoHashMapUnmanaged(u32, std.ArrayList(DynSite)) = .empty,
};
const Analyzer = struct {
    allocator: std.mem.Allocator,
    modules: std.AutoHashMapUnmanaged(u64, *ModuleInfo) = .empty,
    static_modules: std.AutoHashMapUnmanaged(u64, void) = .empty,
    roots: std.AutoHashMapUnmanaged(FnKey, void) = .empty,
    reachable: std.AutoHashMapUnmanaged(FnKey, void) = .empty,
    queue: std.ArrayList(FnKey) = .empty,

    fn module(self: *Analyzer, id: u64) !*ModuleInfo {
        const gop = try self.modules.getOrPut(self.allocator, id);
        if (!gop.found_existing) {
            const m = try self.allocator.create(ModuleInfo);
            m.* = .{};
            gop.value_ptr.* = m;
        }
        return gop.value_ptr.*;
    }

    fn parseReach(self: *Analyzer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len < 3) continue;
            var it = std.mem.splitScalar(u8, line, '\t');
            const kind = (it.next() orelse continue)[0];
            if (kind == 'K') {
                const id = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
                try self.static_modules.put(self.allocator, id, {});
            } else if (kind == 'F') {
                const id = std.fmt.parseInt(u64, it.next() orelse continue, 10) catch continue;
                const start = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
                try self.roots.put(self.allocator, .{ .page_id = id, .start = start }, {});
            }
        }
    }
    fn parseMap(self: *Analyzer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len < 3) continue;
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(self.allocator);
            var it = std.mem.splitScalar(u8, line, '\t');
            while (it.next()) |field| try fields.append(self.allocator, field);
            if (fields.items.len < 2) continue;
            const kind = fields.items[0][0];
            const id = std.fmt.parseInt(u64, fields.items[1], 10) catch continue;
            if (!self.static_modules.contains(id)) continue;
            const m = try self.module(id);
            switch (kind) {
                'F' => if (fields.items.len >= 6) {
                    const start = std.fmt.parseInt(u32, fields.items[2], 10) catch continue;
                    const end = std.fmt.parseInt(u32, fields.items[3], 10) catch continue;
                    const name = try unescape(self.allocator, fields.items[4]);
                    try m.functions.append(self.allocator, .{ .start = start, .end = end, .name = name });
                    const ng = try m.names.getOrPut(self.allocator, name);
                    if (!ng.found_existing) {
                        const list = try self.allocator.create(StartList);
                        list.* = .empty;
                        ng.value_ptr.* = list;
                    }
                    try ng.value_ptr.*.append(self.allocator, start);
                },
                'C' => if (fields.items.len >= 6) {
                    const caller = std.fmt.parseInt(u32, fields.items[2], 10) catch 0;
                    const sg = try m.calls.getOrPut(self.allocator, caller);
                    if (!sg.found_existing) sg.value_ptr.* = .empty;
                    try sg.value_ptr.append(self.allocator, .{
                        .caller = caller,
                        .span_start = std.fmt.parseInt(u32, fields.items[3], 10) catch 0,
                        .span_end = std.fmt.parseInt(u32, fields.items[4], 10) catch 0,
                        .callee = try unescape(self.allocator, fields.items[5]),
                    });
                },
                'r', 'd' => if (fields.items.len >= 5) {
                    const caller = std.fmt.parseInt(u32, fields.items[2], 10) catch 0;
                    const dg = try m.dynamic_sites.getOrPut(self.allocator, caller);
                    if (!dg.found_existing) dg.value_ptr.* = .empty;
                    try dg.value_ptr.append(self.allocator, .{
                        .kind = kind,
                        .caller = caller,
                        .span_start = std.fmt.parseInt(u32, fields.items[3], 10) catch 0,
                        .span_end = std.fmt.parseInt(u32, fields.items[4], 10) catch 0,
                    });
                },
                else => {},
            }
        }
    }

    fn mark(self: *Analyzer, key: FnKey) !void {
        const gop = try self.reachable.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = {};
            try self.queue.append(self.allocator, key);
        }
    }

    fn run(self: *Analyzer) !void {
        var mit = self.static_modules.iterator();
        while (mit.next()) |entry| try self.mark(.{ .page_id = entry.key_ptr.*, .start = 0 });
        var rit = self.roots.iterator();
        while (rit.next()) |entry| try self.mark(entry.key_ptr.*);

        var qi: usize = 0;
        while (qi < self.queue.items.len) : (qi += 1) {
            const key = self.queue.items[qi];
            const m = self.modules.get(key.page_id) orelse continue;
            const calls = m.calls.get(key.start) orelse continue;
            for (calls.items) |call| {
                if (m.names.get(call.callee)) |targets| {
                    for (targets.items) |target| try self.mark(.{ .page_id = key.page_id, .start = target });
                }
            }
        }
    }
    fn writeReport(self: *Analyzer, w: *std.Io.Writer) !void {
        var functions_total: usize = 0;
        var functions_live: usize = 0;
        var dyn_total: usize = 0;
        var dyn_live: usize = 0;
        var calls_live: usize = 0;
        var calls_resolved_local: usize = 0;
        var mit = self.modules.iterator();
        while (mit.next()) |entry| {
            const id = entry.key_ptr.*;
            const m = entry.value_ptr.*;
            functions_total += m.functions.items.len;
            for (m.functions.items) |f| {
                if (self.reachable.contains(.{ .page_id = id, .start = f.start })) functions_live += 1;
            }
            var dit = m.dynamic_sites.iterator();
            while (dit.next()) |sites| {
                dyn_total += sites.value_ptr.items.len;
                if (self.reachable.contains(.{ .page_id = id, .start = sites.key_ptr.* })) dyn_live += sites.value_ptr.items.len;
            }
            var cit = m.calls.iterator();
            while (cit.next()) |calls| {
                if (!self.reachable.contains(.{ .page_id = id, .start = calls.key_ptr.* })) continue;
                calls_live += calls.value_ptr.items.len;
                for (calls.value_ptr.items) |call| if (m.names.contains(call.callee)) {
                    calls_resolved_local += 1;
                };
            }
        }

        try w.print("S\tstatic_modules\t{d}\n", .{self.static_modules.count()});
        try w.print("S\tfunctions_total\t{d}\n", .{functions_total});
        try w.print("S\tsyntactic_reachable_functions\t{d}\n", .{functions_live});
        try w.print("S\tsyntactic_unreached_functions\t{d}\n", .{functions_total -| functions_live});
        try w.print("S\troot_functions\t{d}\n", .{self.roots.count()});
        try w.print("S\tlive_call_sites\t{d}\n", .{calls_live});
        try w.print("S\tlive_calls_resolved_local_name\t{d}\n", .{calls_resolved_local});
        try w.print("S\tdynamic_dependency_sites_total\t{d}\n", .{dyn_total});
        try w.print("S\tdynamic_dependency_sites_in_syntactic_reachable_functions\t{d}\n", .{dyn_live});
        var ids = try self.allocator.alloc(u64, self.modules.count());
        var ii: usize = 0;
        mit = self.modules.iterator();
        while (mit.next()) |entry| : (ii += 1) ids[ii] = entry.key_ptr.*;
        std.mem.sort(u64, ids, {}, comptime std.sort.asc(u64));
        for (ids) |id| {
            const m = self.modules.get(id).?;
            for (m.functions.items) |f| {
                try w.writeAll(if (self.reachable.contains(.{ .page_id = id, .start = f.start })) "K\t" else "N\t");
                try w.print("{d}\t{d}\t{d}\t", .{ id, f.start, f.end });
                try writeField(w, f.name);
                try w.writeByte('\n');
            }
            var dit = m.dynamic_sites.iterator();
            while (dit.next()) |sites| for (sites.value_ptr.items) |site| {
                try w.writeAll(if (self.reachable.contains(.{ .page_id = id, .start = site.caller })) "X\t" else "x\t");
                try w.print("{d}\t{c}\t{d}\t{d}\t{d}\n", .{ id, site.kind, site.caller, site.span_start, site.span_end });
            };
        }
    }
};

fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        switch (s[i + 1]) {
            't' => try out.append(a, '\t'),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            '\\' => try out.append(a, '\\'),
            else => {
                try out.append(a, '\\');
                try out.append(a, s[i + 1]);
            },
        }
        i += 2;
    }
    return out.toOwnedSlice(a);
}
fn writeField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

fn mmapPath(path: []const u8) ![]align(std.heap.page_size_min) const u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    return try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.MissingInput;
    const reach_bytes = try mmapPath(args[1]);
    defer std.posix.munmap(reach_bytes);
    const map_bytes = try mmapPath(args[2]);
    defer std.posix.munmap(map_bytes);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var analyzer = Analyzer{ .allocator = arena.allocator() };
    try analyzer.parseReach(reach_bytes);
    try analyzer.parseMap(map_bytes);
    try analyzer.run();
    var out_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try analyzer.writeReport(&stdout.interface);
    try stdout.interface.flush();
}
