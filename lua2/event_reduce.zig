const std = @import("std");

const cap_values: usize = 256;
const dispatch_cap_values: usize = 65536;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void {
        std.posix.munmap(self.bytes);
    }
};
fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, n, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

const ParamState = struct {
    top: bool = false,
    present_calls: u64 = 0,
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    fn add(self: *ParamState, a: std.mem.Allocator, value: []const u8, cap: usize, retain_dynamic: bool) !void {
        if (self.top) return;
        if (isDynamicValue(value) and !retain_dynamic) {
            self.top = true;
            self.values.deinit(a);
            self.values = .empty;
            return;
        }
        for (self.values.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        if (self.values.items.len >= cap) {
            self.top = true;
            self.values.deinit(a);
            self.values = .empty;
            return;
        }
        try self.values.append(a, value);
    }
};

const RootState = struct {
    calls: u64 = 0,
    dynamic_key: bool = false,
    params: std.StringHashMapUnmanaged(*ParamState) = .empty,
};

const Arg = struct { key: []const u8, value: []const u8, owned_key: bool = false };

const Reducer = struct {
    allocator: std.mem.Allocator,
    roots: std.StringHashMapUnmanaged(*RootState) = .empty,
    needed: std.StringHashMapUnmanaged(*std.StringHashMapUnmanaged(void)) = .empty,
    dynamic_roots: u64 = 0,
    q_events: u64 = 0,
    passthrough: u64 = 0,

    fn deinit(self: *Reducer) void {
        var rit = self.roots.iterator();
        while (rit.next()) |re| {
            var pit = re.value_ptr.*.params.iterator();
            while (pit.next()) |pe| {
                pe.value_ptr.*.values.deinit(self.allocator);
                self.allocator.destroy(pe.value_ptr.*);
            }
            re.value_ptr.*.params.deinit(self.allocator);
            self.allocator.destroy(re.value_ptr.*);
        }
        self.roots.deinit(self.allocator);
        var nit = self.needed.iterator();
        while (nit.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.needed.deinit(self.allocator);
    }

    fn neededFor(self: *Reducer, host: []const u8) !*std.StringHashMapUnmanaged(void) {
        const gop = try self.needed.getOrPut(self.allocator, host);
        if (!gop.found_existing) {
            const set = try self.allocator.create(std.StringHashMapUnmanaged(void));
            set.* = .empty;
            gop.value_ptr.* = set;
        }
        return gop.value_ptr.*;
    }

    fn addNeededExpr(self: *Reducer, host: []const u8, expr: []const u8) !void {
        const set = try self.neededFor(host);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, expr, pos, "{{{")) |open| {
            const close = findParamEnd(expr, open) orelse break;
            const inside = expr[open + 3 .. close];
            const split = splitParam(inside);
            const key = trim(split.key);
            if (key.len != 0 and std.mem.indexOf(u8, key, "{{") == null) try set.put(self.allocator, key, {});
            pos = close + 3;
        }
    }

    fn collectNeeded(self: *Reducer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl];
            pos = @min(nl + 1, bytes.len);
            if (line.len < 2 or (line[0] != 'E' and line[0] != 'I')) continue;
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(self.allocator);
            try splitFields(self.allocator, line, &fields);
            if (line[0] == 'E') {
                if (fields.items.len < 3) continue;
                const host = fields.items[1];
                for (fields.items[2..]) |expr| try self.addNeededExpr(host, expr);
            } else {
                if (fields.items.len < 5 or !std.mem.eql(u8, fields.items[1], "1")) continue;
                const host = fields.items[2];
                for (fields.items[3..]) |expr| try self.addNeededExpr(host, expr);
            }
        }
    }

    fn isNeeded(self: *Reducer, host: []const u8, key: []const u8) bool {
        const set = self.needed.get(host) orelse return false;
        return set.contains(key);
    }

    fn addRoot(self: *Reducer, fields: []const []const u8, w: *std.Io.Writer) !void {
        self.q_events += 1;
        if (fields.len < 2) return;
        const target = fields[1];
        if (isParserOrMagicHead(target)) return;
        if (isDynamicTarget(target)) {
            self.dynamic_roots += 1;
            try w.writeAll("Y");
            for (fields[1..]) |field| {
                try w.writeByte('\t');
                try w.writeAll(field);
            }
            try w.writeByte('\n');
            return;
        }
        const gop = try self.roots.getOrPut(self.allocator, target);
        if (!gop.found_existing) {
            const st = try self.allocator.create(RootState);
            st.* = .{};
            gop.value_ptr.* = st;
        }
        const st = gop.value_ptr.*;

        var args: std.ArrayList(Arg) = .empty;
        defer {
            for (args.items) |arg| if (arg.owned_key) self.allocator.free(arg.key);
            args.deinit(self.allocator);
        }
        var positional: usize = 1;
        for (fields[2..]) |raw| {
            const parsed = try parseArg(self.allocator, raw, &positional);
            if (parsed.key.len == 0 or isDynamicKey(parsed.key)) st.dynamic_key = true;
            try args.append(self.allocator, parsed);
        }

        // MediaWiki parameter semantics are last-write-wins. Process only the
        // final occurrence of a key in this call, and count presence once. We
        // derive missing from present_calls < total calls when writing output,
        // avoiding an O(all-known-params) scan for every root invocation.
        for (args.items, 0..) |arg, arg_index| {
            if (arg.key.len == 0 or isDynamicKey(arg.key)) continue;
            var shadowed = false;
            for (args.items[arg_index + 1 ..]) |later| {
                if (std.mem.eql(u8, later.key, arg.key)) {
                    shadowed = true;
                    break;
                }
            }
            if (shadowed) continue;
            const pg = try st.params.getOrPut(self.allocator, arg.key);
            if (!pg.found_existing) {
                const ps = try self.allocator.create(ParamState);
                ps.* = .{};
                pg.value_ptr.* = ps;
                if (arg.owned_key) pg.key_ptr.* = try self.allocator.dupe(u8, arg.key);
            }
            pg.value_ptr.*.present_calls += 1;
            const dispatch_sensitive = self.isNeeded(target, arg.key);
            const cap = if (dispatch_sensitive) dispatch_cap_values else cap_values;
            try pg.value_ptr.*.add(self.allocator, arg.value, cap, dispatch_sensitive);
        }
        if (st.dynamic_key) {
            var pit = st.params.iterator();
            while (pit.next()) |pe| {
                pe.value_ptr.*.top = true;
                pe.value_ptr.*.values.deinit(self.allocator);
                pe.value_ptr.*.values = .empty;
            }
        }
        st.calls += 1;
    }

    fn writeRoots(self: *Reducer, w: *std.Io.Writer) !void {
        const names = try self.allocator.alloc([]const u8, self.roots.count());
        defer self.allocator.free(names);
        var i: usize = 0;
        var rit = self.roots.iterator();
        while (rit.next()) |e| : (i += 1) names[i] = e.key_ptr.*;
        std.mem.sort([]const u8, names, {}, lessStr);
        for (names) |name| {
            const st = self.roots.get(name).?;
            try w.writeAll("A\t");
            try w.writeAll(name);
            try w.print("\t{d}\t{}\n", .{ st.calls, st.dynamic_key });
            const pnames = try self.allocator.alloc([]const u8, st.params.count());
            defer self.allocator.free(pnames);
            i = 0;
            var pit = st.params.iterator();
            while (pit.next()) |e| : (i += 1) pnames[i] = e.key_ptr.*;
            std.mem.sort([]const u8, pnames, {}, lessStr);
            for (pnames) |pname| {
                const ps = st.params.get(pname).?;
                try w.writeAll("V\t");
                try w.writeAll(name);
                try w.writeByte('\t');
                try w.writeAll(pname);
                const missing = st.dynamic_key or ps.present_calls < st.calls;
                try w.print("\t{}\t{}", .{ ps.top, missing });
                if (!ps.top) {
                    const vals = try self.allocator.dupe([]const u8, ps.values.items);
                    defer self.allocator.free(vals);
                    std.mem.sort([]const u8, vals, {}, lessStr);
                    for (vals) |v| {
                        try w.writeByte('\t');
                        try w.writeAll(v);
                    }
                }
                try w.writeByte('\n');
            }
        }
        try w.print("Z\t{d}\t{d}\t{d}\n", .{ self.q_events, self.dynamic_roots, self.roots.count() });
    }
};

const ParamSplit = struct { key: []const u8, default: ?[]const u8 };
fn splitParam(s: []const u8) ParamSplit {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}") and depth != 0) {
            depth -= 1;
            i += 3;
            continue;
        }
        if (s[i] == '|' and depth == 0) return .{ .key = s[0..i], .default = s[i + 1 ..] };
        i += 1;
    }
    return .{ .key = s, .default = null };
}
fn findParamEnd(s: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start + 3;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            depth += 1;
            i += 3;
            continue;
        }
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 3;
            continue;
        }
        i += 1;
    }
    return null;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn isParserOrMagicHead(raw: []const u8) bool {
    const s = std.mem.trim(u8, raw, " \\t\\r\\n");
    if (s.len == 0) return false;
    if (s[0] == '#') return true;
    const exact = [_][]const u8{
        "PAGENAME",          "PAGENAMEE",     "FULLPAGENAME",    "FULLPAGENAMEE",
        "BASEPAGENAME",      "BASEPAGENAMEE", "SUBPAGENAME",     "SUBPAGENAMEE",
        "NAMESPACE",         "NAMESPACEE",    "NAMESPACENUMBER", "TALKSPACE",
        "SUBJECTSPACE",      "TALKPAGENAME",  "SUBJECTPAGENAME", "ARTICLEPAGENAME",
        "ROOTPAGENAME",      "CURRENTYEAR",   "CURRENTMONTH",    "CURRENTMONTH1",
        "CURRENTMONTHNAME",  "CURRENTDAY",    "CURRENTDAY2",     "CURRENTDOW",
        "CURRENTTIME",       "CURRENTHOUR",   "REVISIONID",      "REVISIONUSER",
        "REVISIONTIMESTAMP", "SITENAME",      "SERVER",          "SERVERNAME",
    };
    for (exact) |name| if (std.ascii.eqlIgnoreCase(s, name)) return true;
    const prefixes = [_][]const u8{
        "lc:",            "uc:",               "lcfirst:",       "ucfirst:",             "urlencode:",       "anchorencode:",
        "fullurl:",       "localurl:",         "filepath:",      "formatnum:",           "padleft:",         "padright:",
        "plural:",        "grammar:",          "gender:",        "int:",                 "ns:",              "nse:",
        "canonicalurl:",  "displaytitle:",     "defaultsort:",   "defaultcategorysort:", "pagesincategory:", "pagesinnamespace:",
        "numberofpages:", "numberofarticles:", "numberoffiles:",
    };
    for (prefixes) |prefix| {
        if (s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn isDynamicTarget(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "[[") != null;
}
fn isDynamicKey(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "[[") != null;
}
fn isDynamicValue(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "[[") != null;
}

fn parseArg(a: std.mem.Allocator, raw: []const u8, positional: *usize) !Arg {
    var curly: i32 = 0;
    var square: i32 = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 2 < raw.len and std.mem.eql(u8, raw[i .. i + 3], "{{{")) {
            curly += 3;
            i += 3;
            continue;
        }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i .. i + 2], "{{")) {
            curly += 2;
            i += 2;
            continue;
        }
        if (i + 2 < raw.len and std.mem.eql(u8, raw[i .. i + 3], "}}}") and curly >= 3) {
            curly -= 3;
            i += 3;
            continue;
        }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i .. i + 2], "}}") and curly >= 2) {
            curly -= 2;
            i += 2;
            continue;
        }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i .. i + 2], "[[")) {
            square += 2;
            i += 2;
            continue;
        }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i .. i + 2], "]]") and square >= 2) {
            square -= 2;
            i += 2;
            continue;
        }
        if (raw[i] == '=' and curly == 0 and square == 0) {
            const key = trim(raw[0..i]);
            if (key.len != 0) return .{ .key = key, .value = trim(raw[i + 1 ..]) };
            break;
        }
        i += 1;
    }
    var buf: [32]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{d}", .{positional.*});
    positional.* += 1;
    return .{ .key = try a.dupe(u8, tmp), .value = trim(raw), .owned_key = true };
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn splitFields(a: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| try out.append(a, f);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingInput;
    var mapped = try mmapPath(args[1]);
    defer mapped.deinit();
    const a = std.heap.smp_allocator;
    var reducer = Reducer{ .allocator = a };
    defer reducer.deinit();
    try reducer.collectNeeded(mapped.bytes);
    std.debug.print("needed_hosts={d}\n", .{reducer.needed.count()});
    var out_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    var pos: usize = 0;
    var lines: u64 = 0;
    var released: usize = 0;
    while (pos < mapped.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, mapped.bytes, pos, '\n') orelse mapped.bytes.len;
        const line = mapped.bytes[pos..nl];
        pos = @min(nl + 1, mapped.bytes.len);
        lines += 1;
        if (line.len == 0) continue;
        if (line[0] == 'Q') {
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(a);
            try splitFields(a, line, &fields);
            try reducer.addRoot(fields.items, w);
        } else {
            try w.writeAll(line);
            try w.writeByte('\n');
            reducer.passthrough += 1;
        }
        if (pos - released >= 128 * 1024 * 1024) {
            const ps = std.heap.page_size_min;
            const end = (pos / ps) * ps;
            if (end > released) {
                const base: [*]u8 = @ptrCast(@constCast(mapped.bytes.ptr));
                const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(base + released);
                std.posix.madvise(ptr, end - released, std.posix.MADV.DONTNEED) catch {};
                released = end;
            }
        }
        if (lines % 5_000_000 == 0) std.debug.print("lines={d} q={d} roots={d} dynamic={d}\n", .{ lines, reducer.q_events, reducer.roots.count(), reducer.dynamic_roots });
    }
    try reducer.writeRoots(w);
    try w.flush();
    std.debug.print("TOTAL lines={d} q={d} passthrough={d} roots={d} dynamic={d}\n", .{ lines, reducer.q_events, reducer.passthrough, reducer.roots.count(), reducer.dynamic_roots });
}
