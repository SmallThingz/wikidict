const std = @import("std");

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

const ManifestRow = struct {
    page_id: u64,
    title: []const u8,
};

const Dep = struct {
    kind: u8,
    function_start: u32,
    span_start: u32,
    span_end: u32,
    target: []const u8,
};
const DynSite = struct {
    kind: u8,
    function_start: u32,
    span_start: u32,
    span_end: u32,
};

const ExportTarget = union(enum) {
    function: u32,
    module_export: struct { module: []const u8, name: []const u8 },
};

const ExportMap = std.StringHashMapUnmanaged(ExportTarget);

const Root = struct {
    module: []const u8,
    function: []const u8,
};

const FnRoot = struct {
    page_id: u64,
    function_start: u32,
    module: []const u8,
    function: []const u8,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    title_to_id: std.StringHashMapUnmanaged(u64) = .empty,
    id_to_title: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    roots: std.ArrayList(Root) = .empty,
    deps: std.AutoHashMapUnmanaged(u64, std.ArrayList(Dep)) = .empty,
    dynamic_sites: std.AutoHashMapUnmanaged(u64, std.ArrayList(DynSite)) = .empty,
    exports: std.AutoHashMapUnmanaged(u64, *ExportMap) = .empty,
    proxies: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    dynamic_top: std.AutoHashMapUnmanaged(u64, void) = .empty,

    reachable: std.AutoHashMapUnmanaged(u64, void) = .empty,
    fn_roots: std.ArrayList(FnRoot) = .empty,
    missing_roots: std.ArrayList(Root) = .empty,
    unresolved_exports: std.ArrayList(Root) = .empty,
    missing_static: std.ArrayList(struct { source: u64, dep: Dep }) = .empty,

    fn parseManifest(self: *Analyzer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len == 0) continue;
            const row = try std.json.parseFromSliceLeaky(ManifestRow, self.allocator, line, .{ .ignore_unknown_fields = true });
            try self.title_to_id.put(self.allocator, row.title, row.page_id);
            try self.id_to_title.put(self.allocator, row.page_id, row.title);
        }
    }

    fn parseUsage(self: *Analyzer, bytes: []const u8) !void {
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
            switch (fields.items[0][0]) {
                'M' => if (fields.items.len >= 3) {
                    const from = try unescapeField(self.allocator, fields.items[1]);
                    const to = try unescapeField(self.allocator, fields.items[2]);
                    try self.redirects.put(self.allocator, from, to);
                },
                'U' => if (fields.items.len >= 3) {
                    try self.roots.append(self.allocator, .{
                        .module = try unescapeField(self.allocator, fields.items[1]),
                        .function = try unescapeField(self.allocator, fields.items[2]),
                    });
                },
                else => {},
            }
        }
    }

    fn parseModuleMap(self: *Analyzer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len < 2) continue;
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(self.allocator);
            var it = std.mem.splitScalar(u8, line, '\t');
            while (it.next()) |field| try fields.append(self.allocator, field);
            if (fields.items.len < 5) continue;
            const kind = fields.items[0][0];
            if (kind != 'R' and kind != 'D' and kind != 'r' and kind != 'd') continue;
            const page_id = std.fmt.parseInt(u64, fields.items[1], 10) catch continue;
            const fn_start = std.fmt.parseInt(u32, fields.items[2], 10) catch 0;
            const span_start = std.fmt.parseInt(u32, fields.items[3], 10) catch 0;
            const span_end = std.fmt.parseInt(u32, fields.items[4], 10) catch 0;
            if (kind == 'R' or kind == 'D') {
                if (fields.items.len < 6) continue;
                const gop = try self.deps.getOrPut(self.allocator, page_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{
                    .kind = kind,
                    .function_start = fn_start,
                    .span_start = span_start,
                    .span_end = span_end,
                    .target = try unescapeField(self.allocator, fields.items[5]),
                });
            } else {
                const gop = try self.dynamic_sites.getOrPut(self.allocator, page_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{
                    .kind = kind,
                    .function_start = fn_start,
                    .span_start = span_start,
                    .span_end = span_end,
                });
            }
        }
    }

    fn parseModuleIndex(self: *Analyzer, bytes: []const u8) !void {
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
            const page_id = std.fmt.parseInt(u64, fields.items[1], 10) catch continue;
            switch (kind) {
                'S' => if (fields.items.len >= 4 and std.mem.eql(u8, fields.items[3], "true")) try self.dynamic_top.put(self.allocator, page_id, {}),
                'R' => if (fields.items.len >= 3) try self.proxies.put(self.allocator, page_id, try unescapeField(self.allocator, fields.items[2])),
                'E' => if (fields.items.len >= 5) {
                    const gop = try self.exports.getOrPut(self.allocator, page_id);
                    if (!gop.found_existing) {
                        const map = try self.allocator.create(ExportMap);
                        map.* = .empty;
                        gop.value_ptr.* = map;
                    }
                    const name = try unescapeField(self.allocator, fields.items[2]);
                    if (std.mem.eql(u8, fields.items[3], "F")) {
                        const fn_start = std.fmt.parseInt(u32, fields.items[4], 10) catch continue;
                        try gop.value_ptr.*.put(self.allocator, name, .{ .function = fn_start });
                    } else if (std.mem.eql(u8, fields.items[3], "M") and fields.items.len >= 6) {
                        try gop.value_ptr.*.put(self.allocator, name, .{ .module_export = .{
                            .module = try unescapeField(self.allocator, fields.items[4]),
                            .name = try unescapeField(self.allocator, fields.items[5]),
                        } });
                    }
                },
                else => {},
            }
        }
    }

    fn redirect(self: *Analyzer, input: []const u8) []const u8 {
        var current = input;
        var n: usize = 0;
        while (n < 32) : (n += 1) {
            const next = self.redirects.get(current) orelse break;
            if (std.mem.eql(u8, next, current)) break;
            current = next;
        }
        return current;
    }
    fn lookupTitle(self: *Analyzer, raw: []const u8) !?u64 {
        const redirected = self.redirect(raw);
        if (self.title_to_id.get(redirected)) |id| return id;
        const normalized = if (std.mem.indexOfScalar(u8, redirected, '_') != null) blk: {
            const copy = try self.allocator.dupe(u8, redirected);
            for (copy) |*c| {
                if (c.* == '_') c.* = ' ';
            }
            break :blk copy;
        } else try self.allocator.dupe(u8, redirected);
        const final = self.redirect(normalized);
        if (self.title_to_id.get(final)) |id| return id;
        const prefix = "Module:";
        if (std.mem.startsWith(u8, final, prefix) and final.len > prefix.len and std.ascii.isAlphabetic(final[prefix.len])) {
            const alternate = try self.allocator.dupe(u8, final);
            alternate[prefix.len] = if (std.ascii.isUpper(alternate[prefix.len]))
                std.ascii.toLower(alternate[prefix.len])
            else
                std.ascii.toUpper(alternate[prefix.len]);
            return self.title_to_id.get(self.redirect(alternate));
        }
        return null;
    }

    fn addReachable(self: *Analyzer, queue: *std.ArrayList(u64), id: u64) !void {
        const gop = try self.reachable.getOrPut(self.allocator, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = {};
            try queue.append(self.allocator, id);
        }
    }

    fn computeModules(self: *Analyzer) !void {
        var queue: std.ArrayList(u64) = .empty;
        for (self.roots.items) |root| {
            if (try self.lookupTitle(root.module)) |id| {
                try self.addReachable(&queue, id);
            } else {
                try self.missing_roots.append(self.allocator, root);
            }
        }
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const source = queue.items[qi];
            if (self.deps.get(source)) |list| for (list.items) |dep| {
                if (try self.lookupTitle(dep.target)) |target| {
                    try self.addReachable(&queue, target);
                } else {
                    try self.missing_static.append(self.allocator, .{ .source = source, .dep = dep });
                }
            };
        }
    }
    fn resolveFunctionRoots(self: *Analyzer) !void {
        for (self.roots.items) |root| {
            var module = root.module;
            var function = root.function;
            var depth: usize = 0;
            var resolved = false;
            while (depth < 32) : (depth += 1) {
                const page_id = try self.lookupTitle(module) orelse break;
                if (self.exports.get(page_id)) |map| {
                    if (map.get(function)) |target| switch (target) {
                        .function => |fn_start| {
                            try self.fn_roots.append(self.allocator, .{
                                .page_id = page_id,
                                .function_start = fn_start,
                                .module = root.module,
                                .function = root.function,
                            });
                            resolved = true;
                            break;
                        },
                        .module_export => |m| {
                            module = m.module;
                            function = m.name;
                            continue;
                        },
                    };
                }
                if (self.proxies.get(page_id)) |target_module| {
                    module = target_module;
                    continue;
                }
                break;
            }
            if (!resolved) try self.unresolved_exports.append(self.allocator, root);
        }
    }

    fn writeReport(self: *Analyzer, w: *std.Io.Writer) !void {
        var reachable_dynamic_sites: usize = 0;
        var reachable_dynamic_top: usize = 0;
        var rit = self.reachable.iterator();
        while (rit.next()) |entry| {
            const id = entry.key_ptr.*;
            if (self.dynamic_sites.get(id)) |sites| reachable_dynamic_sites += sites.items.len;
            if (self.dynamic_top.contains(id)) reachable_dynamic_top += 1;
        }
        try w.print("S\tmodules_total\t{d}\n", .{self.title_to_id.count()});
        try w.print("S\tentrypoints\t{d}\n", .{self.roots.items.len});
        try w.print("S\tstatic_reachable_modules\t{d}\n", .{self.reachable.count()});
        try w.print("S\tstatic_unreachable_modules\t{d}\n", .{self.title_to_id.count() -| self.reachable.count()});
        try w.print("S\tmissing_root_modules\t{d}\n", .{self.missing_roots.items.len});
        try w.print("S\tunresolved_static_dependencies\t{d}\n", .{self.missing_static.items.len});
        try w.print("S\treachable_dynamic_dependency_sites\t{d}\n", .{reachable_dynamic_sites});
        try w.print("S\treachable_dynamic_top_modules\t{d}\n", .{reachable_dynamic_top});
        try w.print("S\tresolved_function_roots\t{d}\n", .{self.fn_roots.items.len});
        try w.print("S\tunresolved_function_roots\t{d}\n", .{self.unresolved_exports.items.len});

        var ids = try self.allocator.alloc(u64, self.id_to_title.count());
        var ii: usize = 0;
        var iit = self.id_to_title.iterator();
        while (iit.next()) |entry| : (ii += 1) ids[ii] = entry.key_ptr.*;
        std.mem.sort(u64, ids, {}, comptime std.sort.asc(u64));
        for (ids) |id| {
            const title = self.id_to_title.get(id).?;
            try w.writeAll(if (self.reachable.contains(id)) "K\t" else "N\t");
            try w.print("{d}\t", .{id});
            try writeField(w, title);
            try w.writeByte('\n');
        }

        for (self.fn_roots.items) |root| {
            try w.print("F\t{d}\t{d}\t", .{ root.page_id, root.function_start });
            try writeField(w, root.module);
            try w.writeByte('\t');
            try writeField(w, root.function);
            try w.writeByte('\n');
        }
        for (self.unresolved_exports.items) |root| {
            try w.writeAll("G\t");
            try writeField(w, root.module);
            try w.writeByte('\t');
            try writeField(w, root.function);
            try w.writeByte('\n');
        }
        for (self.missing_roots.items) |root| {
            try w.writeAll("H\t");
            try writeField(w, root.module);
            try w.writeByte('\t');
            try writeField(w, root.function);
            try w.writeByte('\n');
        }
        for (self.missing_static.items) |item| {
            try w.print("J\t{d}\t{c}\t{d}\t{d}\t{d}\t", .{
                item.source, item.dep.kind, item.dep.function_start, item.dep.span_start, item.dep.span_end,
            });
            try writeField(w, item.dep.target);
            try w.writeByte('\n');
        }
        var dit = self.dynamic_sites.iterator();
        while (dit.next()) |entry| {
            if (!self.reachable.contains(entry.key_ptr.*)) continue;
            for (entry.value_ptr.items) |site| {
                try w.print("X\t{d}\t{c}\t{d}\t{d}\t{d}\n", .{
                    entry.key_ptr.*, site.kind, site.function_start, site.span_start, site.span_end,
                });
            }
        }
    }
};

fn unescapeField(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        const next = s[i + 1];
        switch (next) {
            't' => try out.append(a, '\t'),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            '\\' => try out.append(a, '\\'),
            else => {
                try out.append(a, '\\');
                try out.append(a, next);
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
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5) return error.MissingInput;
    var manifest = try mmapPath(args[1]);
    defer manifest.deinit();
    var usage = try mmapPath(args[2]);
    defer usage.deinit();
    var module_map = try mmapPath(args[3]);
    defer module_map.deinit();
    var module_index = try mmapPath(args[4]);
    defer module_index.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var analyzer = Analyzer{ .allocator = arena.allocator() };
    try analyzer.parseManifest(manifest.bytes);
    try analyzer.parseUsage(usage.bytes);
    try analyzer.parseModuleMap(module_map.bytes);
    try analyzer.parseModuleIndex(module_index.bytes);
    try analyzer.computeModules();
    try analyzer.resolveFunctionRoots();

    var out_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try analyzer.writeReport(&stdout.interface);
    try stdout.interface.flush();
    std.debug.print(
        "modules={d}/{d} entrypoints={d} fn_roots={d} unresolved_fn={d} missing_static={d}\n",
        .{
            analyzer.reachable.count(),
            analyzer.title_to_id.count(),
            analyzer.roots.items.len,
            analyzer.fn_roots.items.len,
            analyzer.unresolved_exports.items.len,
            analyzer.missing_static.items.len,
        },
    );
}
