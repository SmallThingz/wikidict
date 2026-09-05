const std = @import("std");
const xml_decode = @import("xml_decode");

const cap_values = 4096;

const Mapped = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn deinit(self: *Mapped) void { std.posix.munmap(self.bytes); }
};

fn mmapPath(path: []const u8) !Mapped {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const io = std.Options.debug_io;
    var f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer f.close(io);
    const st = try f.stat(io);
    const len = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    return .{ .bytes = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) };
}

const Interner = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Interner) void { self.strings.deinit(self.allocator); }

    fn intern(self: *Interner, s: []const u8) ![]const u8 {
        if (self.strings.getKey(s)) |key| return key;
        const owned = try self.allocator.dupe(u8, s);
        try self.strings.put(self.allocator, owned, {});
        return owned;
    }
};

const Domain = struct {
    top: bool = false,
    missing: bool = false,
    values: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Domain, a: std.mem.Allocator, value: []const u8) !bool {
        if (self.top) return false;
        if (self.values.contains(value)) return false;
        if (self.values.count() >= cap_values) {
            self.top = true;
            self.values.deinit(a);
            self.values = .empty;
            return true;
        }
        try self.values.put(a, value, {});
        return true;
    }

    fn merge(self: *Domain, a: std.mem.Allocator, other: *const Domain) !bool {
        var changed = false;
        if (other.top and !self.top) {
            self.top = true;
            self.values.deinit(a);
            self.values = .empty;
            changed = true;
        }
        if (!self.top and !other.top) {
            var it = other.values.iterator();
            while (it.next()) |entry| changed = (try self.add(a, entry.key_ptr.*)) or changed;
        }
        if (other.missing and !self.missing) {
            self.missing = true;
            changed = true;
        }
        return changed;
    }

    fn setTop(self: *Domain, a: std.mem.Allocator) bool {
        if (self.top) return false;
        self.top = true;
        self.values.deinit(a);
        self.values = .empty;
        return true;
    }
};

const ArgContext = struct {
    values: std.StringHashMapUnmanaged(*Domain) = .empty,
    dynamic_keys: bool = false,

    fn deinit(self: *ArgContext, a: std.mem.Allocator) void { self.values.deinit(a); }
};

const State = struct {
    contexts: u64 = 0,
    dynamic_keys: bool = false,
    params: std.StringHashMapUnmanaged(*Domain) = .empty,

    fn getOrCreate(self: *State, a: std.mem.Allocator, key: []const u8) !*Domain {
        const gop = try self.params.getOrPut(a, key);
        if (!gop.found_existing) {
            const d = try a.create(Domain);
            d.* = if (self.dynamic_keys) .{ .top = true, .missing = true } else .{ .missing = self.contexts != 0 };
            gop.value_ptr.* = d;
        }
        return gop.value_ptr.*;
    }

    fn mergeContext(self: *State, a: std.mem.Allocator, ctx: *const ArgContext) !bool {
        var changed = false;
        if (ctx.dynamic_keys and !self.dynamic_keys) {
            self.dynamic_keys = true;
            changed = true;
            var all = self.params.iterator();
            while (all.next()) |entry| {
                changed = entry.value_ptr.*.setTop(a) or changed;
                if (!entry.value_ptr.*.missing) { entry.value_ptr.*.missing = true; changed = true; }
            }
        }
        var existing = self.params.iterator();
        while (existing.next()) |entry| {
            if (!ctx.values.contains(entry.key_ptr.*) and !entry.value_ptr.*.missing) {
                entry.value_ptr.*.missing = true;
                changed = true;
            }
        }
        var it = ctx.values.iterator();
        while (it.next()) |entry| {
            const dst = try self.getOrCreate(a, entry.key_ptr.*);
            if (self.dynamic_keys) {
                changed = dst.setTop(a) or changed;
                if (!dst.missing) { dst.missing = true; changed = true; }
            } else {
                changed = (try dst.merge(a, entry.value_ptr.*)) or changed;
            }
        }
        self.contexts += 1;
        return changed;
    }

};

const Edge = struct {
    target_expr: []const u8,
    args: []const []const u8,
};

const DynamicRoot = struct {
    target_expr: []const u8,
    args: []const []const u8,
};

const Invoke = struct {
    host_kind: u8,
    host: []const u8,
    module_expr: []const u8,
    function_expr: []const u8,
    args: []const []const u8,
};

const InvokeKey = struct {
    module: []const u8,
    function: []const u8,
};

const InvokeContext = struct {
    module: []const u8,
    function: []const u8,
    state: State = .{},
    parent: State = .{},
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    interner: Interner,
    templates: std.StringHashMapUnmanaged(void) = .empty,
    states: std.StringHashMapUnmanaged(*State) = .empty,
    edges: std.StringHashMapUnmanaged(*std.ArrayList(Edge)) = .empty,
    redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    module_redirects: std.StringHashMapUnmanaged([]const u8) = .empty,
    invokes: std.StringHashMapUnmanaged(*std.ArrayList(Invoke)) = .empty,
    direct_invokes: std.ArrayList(Invoke) = .empty,
    dynamic_root_calls: std.ArrayList(DynamicRoot) = .empty,
    needed: std.StringHashMapUnmanaged(*std.StringHashMapUnmanaged(void)) = .empty,
    invocation_domains: std.StringHashMapUnmanaged(*InvokeContext) = .empty,
    reachable: std.StringHashMapUnmanaged(void) = .empty,
    dynamic_template_edges: u64 = 0,
    pattern_resolved_edges: u64 = 0,
    pattern_target_candidates: u64 = 0,
    broad_patterns: u64 = 0,
    dynamic_invokes: u64 = 0,
    root_calls: u64 = 0,
    dynamic_roots: u64 = 0,

    fn init(a: std.mem.Allocator) Analyzer {
        return .{ .allocator = a, .interner = .{ .allocator = a } };
    }

    fn decode(self: *Analyzer, raw: []const u8) ![]const u8 {
        var unescaped: std.ArrayList(u8) = .empty;
        defer unescaped.deinit(self.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                switch (raw[i + 1]) {
                    '\\' => { try unescaped.append(self.allocator, '\\'); i += 2; continue; },
                    't' => { try unescaped.append(self.allocator, '\t'); i += 2; continue; },
                    'n' => { try unescaped.append(self.allocator, '\n'); i += 2; continue; },
                    'r' => { try unescaped.append(self.allocator, '\r'); i += 2; continue; },
                    else => {},
                }
            }
            try unescaped.append(self.allocator, raw[i]);
            i += 1;
        }
        const decoded = try xml_decode.decodeSinglePassAlloc(self.allocator, unescaped.items);
        defer self.allocator.free(decoded);
        return try self.interner.intern(decoded);
    }

    fn normalizeTitle(self: *Analyzer, raw: []const u8, prefix: []const u8) ![]const u8 {
        var s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) s = std.mem.trim(u8, s[prefix.len..], " \t\r\n");
        if (std.mem.indexOfScalar(u8, s, '_') == null) return self.interner.intern(s);
        const buf = try self.allocator.dupe(u8, s);
        defer self.allocator.free(buf);
        std.mem.replaceScalar(u8, buf, '_', ' ');
        return self.interner.intern(buf);
    }

    fn stateFor(self: *Analyzer, template: []const u8) !*State {
        const gop = try self.states.getOrPut(self.allocator, template);
        if (!gop.found_existing) {
            const s = try self.allocator.create(State); s.* = .{}; gop.value_ptr.* = s;
        }
        return gop.value_ptr.*;
    }

    fn neededFor(self: *Analyzer, template: []const u8) !*std.StringHashMapUnmanaged(void) {
        const gop = try self.needed.getOrPut(self.allocator, template);
        if (!gop.found_existing) {
            const set = try self.allocator.create(std.StringHashMapUnmanaged(void));
            set.* = .empty; gop.value_ptr.* = set;
        }
        return gop.value_ptr.*;
    }

    fn addNeeded(self: *Analyzer, template: []const u8, expr: []const u8) !void {
        const set = try self.neededFor(template);
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, expr, i, "{{{")) |start| {
            const end = findParamEnd(expr, start) orelse break;
            const inside = expr[start + 3 .. end];
            const split = splitParam(inside);
            const key = std.mem.trim(u8, split.key, " \t\r\n");
            if (key.len != 0 and std.mem.indexOf(u8, key, "{{") == null) {
                try set.put(self.allocator, try self.interner.intern(key), {});
            }
            i = end + 3;
        }
    }

    fn parseReduced(self: *Analyzer, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
            const line = bytes[pos..nl]; pos = @min(nl + 1, bytes.len);
            if (line.len == 0) continue;
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(self.allocator);
            var split = std.mem.splitScalar(u8, line, '\t');
            while (split.next()) |f| try fields.append(self.allocator, f);
            if (fields.items.len == 0) continue;
            switch (fields.items[0][0]) {
                'T' => if (fields.items.len >= 2) {
                    const name = try self.normalizeTitle(try self.decode(fields.items[1]), "Template:");
                    try self.templates.put(self.allocator, name, {});
                },
                'A' => if (fields.items.len >= 4) {
                    const name = try self.normalizeTitle(try self.decode(fields.items[1]), "Template:");
                    const calls = std.fmt.parseInt(u64, fields.items[2], 10) catch 0;
                    const dynamic_key = std.mem.eql(u8, fields.items[3], "true");
                    const state = try self.stateFor(name);
                    state.contexts = calls;
                    self.root_calls += calls;
                    if (self.templates.contains(name)) try self.reachable.put(self.allocator, name, {});
                    if (dynamic_key) {
                        state.dynamic_keys = true;
                        var it = state.params.iterator();
                        while (it.next()) |entry| {
                            _ = entry.value_ptr.*.setTop(self.allocator);
                            entry.value_ptr.*.missing = true;
                        }
                    }
                },
                'V' => if (fields.items.len >= 5) {
                    const name = try self.normalizeTitle(try self.decode(fields.items[1]), "Template:");
                    const key = try self.decode(fields.items[2]);
                    const state = try self.stateFor(name);
                    const d = try state.getOrCreate(self.allocator, key);
                    d.top = state.dynamic_keys or std.mem.eql(u8, fields.items[3], "true");
                    d.missing = state.dynamic_keys or std.mem.eql(u8, fields.items[4], "true");
                    if (!d.top) {
                        for (fields.items[5..]) |raw| _ = try d.add(self.allocator, try self.decode(raw));
                    }
                },
                'E' => if (fields.items.len >= 3) {
                    const caller = try self.normalizeTitle(try self.decode(fields.items[1]), "Template:");
                    const target = try self.decode(fields.items[2]);
                    // The scanner deliberately records every {{...}} construct. Parser
                    // functions and magic words are expansions, not template edges.
                    if (isParserOrMagicHead(target)) continue;
                    const args = try self.allocator.alloc([]const u8, fields.items.len - 3);
                    for (fields.items[3..], 0..) |raw, j| args[j] = try self.decode(raw);
                    const gop = try self.edges.getOrPut(self.allocator, caller);
                    if (!gop.found_existing) { const list = try self.allocator.create(std.ArrayList(Edge)); list.* = .empty; gop.value_ptr.* = list; }
                    try gop.value_ptr.*.append(self.allocator, .{ .target_expr = target, .args = args });
                    try self.addNeeded(caller, target);
                    for (args) |arg| try self.addNeeded(caller, arg);
                },
                'X' => if (fields.items.len >= 3) {
                    const from = try self.normalizeTitle(try self.decode(fields.items[1]), "Template:");
                    const to = try self.normalizeTitle(try self.decode(fields.items[2]), "Template:");
                    try self.redirects.put(self.allocator, from, to);
                },
                'M' => if (fields.items.len >= 3) {
                    const from0 = try self.normalizeTitle(try self.decode(fields.items[1]), "Module:");
                    const to0 = try self.normalizeTitle(try self.decode(fields.items[2]), "Module:");
                    const from = try std.fmt.allocPrint(self.allocator, "Module:{s}", .{from0});
                    const to = try std.fmt.allocPrint(self.allocator, "Module:{s}", .{to0});
                    try self.module_redirects.put(self.allocator, try self.interner.intern(from), try self.interner.intern(to));
                },
                'I' => if (fields.items.len >= 5) {
                    const host_kind = std.fmt.parseInt(u8, fields.items[1], 10) catch 0;
                    const host = if (host_kind == 1) try self.normalizeTitle(try self.decode(fields.items[2]), "Template:") else try self.decode(fields.items[2]);
                    const module_expr = try self.decode(fields.items[3]);
                    const function_expr = try self.decode(fields.items[4]);
                    const args = try self.allocator.alloc([]const u8, fields.items.len - 5);
                    for (fields.items[5..], 0..) |raw, j| args[j] = try self.decode(raw);
                    const inv: Invoke = .{ .host_kind = host_kind, .host = host, .module_expr = module_expr, .function_expr = function_expr, .args = args };
                    if (host_kind == 0) try self.direct_invokes.append(self.allocator, inv) else {
                        const gop = try self.invokes.getOrPut(self.allocator, host);
                        if (!gop.found_existing) { const list = try self.allocator.create(std.ArrayList(Invoke)); list.* = .empty; gop.value_ptr.* = list; }
                        try gop.value_ptr.*.append(self.allocator, inv);
                        try self.addNeeded(host, module_expr);
                        try self.addNeeded(host, function_expr);
                        for (args) |arg| try self.addNeeded(host, arg);
                    }
                },
                'Y' => if (fields.items.len >= 2) {
                    const target = try self.decode(fields.items[1]);
                    const args = try self.allocator.alloc([]const u8, fields.items.len - 2);
                    for (fields.items[2..], 0..) |raw, j| args[j] = try self.decode(raw);
                    try self.dynamic_root_calls.append(self.allocator, .{ .target_expr = target, .args = args });
                },
                'Z' => { if (fields.items.len >= 4) self.dynamic_roots = std.fmt.parseInt(u64, fields.items[2], 10) catch 0; },
                else => {},
            }
        }

        try self.resolveDynamicRoots();

        // Root states need explicit missing domains for parameters referenced by
        // their definitions but never supplied by any observed root call.
        var rit = self.reachable.iterator();
        while (rit.next()) |entry| {
            const name = entry.key_ptr.*;
            const state = try self.stateFor(name);
            if (self.needed.get(name)) |set| {
                var nit = set.iterator();
                while (nit.next()) |n| {
                    if (!state.params.contains(n.key_ptr.*)) {
                        const d = try state.getOrCreate(self.allocator, n.key_ptr.*);
                        d.missing = true;
                    }
                }
            }
        }
    }

    fn resolveDynamicRoots(self: *Analyzer) !void {
        var unresolved: u64 = 0;
        for (self.dynamic_root_calls.items) |root| {
            var ctx = try self.staticArgs(root.args);
            defer ctx.deinit(self.allocator);
            const pattern0 = try wildcardTargetPatternAlloc(self.allocator, root.target_expr);
            var pattern = std.mem.trim(u8, pattern0, " \t\r\n");
            if (pattern.len >= 9 and std.ascii.eqlIgnoreCase(pattern[0..9], "Template:")) pattern = pattern[9..];
            if (std.mem.eql(u8, pattern, "*")) {
                unresolved += 1;
                std.debug.print("UNRESOLVED_DYNAMIC_ROOT expr={s}\n", .{root.target_expr});
                continue;
            }
            var matched: u64 = 0;
            var it = self.templates.iterator();
            while (it.next()) |entry| {
                const candidate = entry.key_ptr.*;
                if (!globTitleMatch(pattern, candidate)) continue;
                matched += 1;
                const dst = try self.stateFor(candidate);
                _ = try dst.mergeContext(self.allocator, &ctx);
                try self.reachable.put(self.allocator, candidate, {});
            }
            std.debug.print("DYNAMIC_ROOT_RESOLVED pattern={s} matches={d} expr={s}\n", .{ pattern, matched, root.target_expr });
        }
        self.dynamic_roots = unresolved;
    }

    fn runTemplateFixedPoint(self: *Analyzer) !void {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(self.allocator);
        var queued: std.StringHashMapUnmanaged(void) = .empty;
        defer queued.deinit(self.allocator);
        var rit = self.reachable.iterator();
        while (rit.next()) |entry| { try queue.append(self.allocator, entry.key_ptr.*); try queued.put(self.allocator, entry.key_ptr.*, {}); }

        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const caller = queue.items[cursor];
            _ = queued.remove(caller);
            const state = try self.stateFor(caller);

            if (self.redirects.get(caller)) |target| {
                var ctx: ArgContext = .{ .dynamic_keys = state.dynamic_keys };
                defer ctx.deinit(self.allocator);
                var it = state.params.iterator();
                while (it.next()) |entry| try ctx.values.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
                try self.activateTemplateTarget(target, &ctx, &queue, &queued);
            }

            if (self.edges.get(caller)) |list| for (list.items) |edge| {
                var ctx = try self.evalArgs(edge.args, state, caller);
                defer ctx.deinit(self.allocator);
                var targets = try self.evalExpr(edge.target_expr, state, caller);
                defer targets.values.deinit(self.allocator);
                if (targets.top or targets.missing) {
                    const matched = try self.activatePatternTargets(edge.target_expr, caller, &ctx, &queue, &queued);
                    self.pattern_resolved_edges += 1;
                    self.pattern_target_candidates += matched;
                    continue;
                }
                var tit = targets.values.iterator();
                while (tit.next()) |te| {
                    const target = try self.normalizeTitle(te.key_ptr.*, "Template:");
                    if (target.len == 0) continue;
                    if (isDynamicText(target) or containsInvalidTitleMarkup(target)) {
                        const matched = try self.activatePatternTargets(te.key_ptr.*, caller, &ctx, &queue, &queued);
                        self.pattern_resolved_edges += 1;
                        self.pattern_target_candidates += matched;
                        continue;
                    }
                    // A missing template cannot execute code and therefore does not
                    // add a reachability edge. Redirect pages are in templates too.
                    if (!self.templates.contains(target)) continue;
                    try self.activateTemplateTarget(target, &ctx, &queue, &queued);
                }
            };
        }
    }

    fn activateTemplateTarget(
        self: *Analyzer,
        target: []const u8,
        ctx: *const ArgContext,
        queue: *std.ArrayList([]const u8),
        queued: *std.StringHashMapUnmanaged(void),
    ) !void {
        const dst = try self.stateFor(target);
        const changed = try dst.mergeContext(self.allocator, ctx);
        const was = self.reachable.contains(target);
        try self.reachable.put(self.allocator, target, {});
        if ((!was or changed) and !queued.contains(target)) {
            try queue.append(self.allocator, target);
            try queued.put(self.allocator, target, {});
        }
    }

    fn activatePatternTargets(
        self: *Analyzer,
        raw_expr: []const u8,
        caller: []const u8,
        ctx: *const ArgContext,
        queue: *std.ArrayList([]const u8),
        queued: *std.StringHashMapUnmanaged(void),
    ) !u64 {
        const trimmed_raw = std.mem.trim(u8, raw_expr, " \t\r\n");
        const pattern0 = try wildcardTargetPatternAlloc(self.allocator, raw_expr);
        var pattern = std.mem.trim(u8, pattern0, " \t\r\n");
        if (pattern.len >= 9 and std.ascii.eqlIgnoreCase(pattern[0..9], "Template:")) pattern = pattern[9..];

        // A date parser-function used as the entire target in a template emits
        // a relative subpage (e.g. /2026/March). Preserve the caller prefix
        // rather than widening this to every template in the corpus.
        var relative_date_pattern: ?[]const u8 = null;
        if (std.mem.eql(u8, pattern, "*") and std.ascii.indexOfIgnoreCase(trimmed_raw, "#time:") != null and std.mem.indexOfScalar(u8, trimmed_raw, '/') != null) {
            relative_date_pattern = try std.fmt.allocPrint(self.allocator, "{s}/*", .{caller});
            pattern = relative_date_pattern.?;
        }
        if (std.mem.eql(u8, pattern, "*")) {
            self.broad_patterns += 1;
            self.dynamic_template_edges += 1;
            std.debug.print("UNRESOLVED_BROAD_TEMPLATE_PATTERN caller={s} expr={s}\n", .{ caller, raw_expr });
            return 0;
        }
        var matched: u64 = 0;
        var it = self.templates.iterator();
        while (it.next()) |entry| {
            const candidate = entry.key_ptr.*;
            if (!globTitleMatch(pattern, candidate)) continue;
            matched += 1;
            try self.activateTemplateTarget(candidate, ctx, queue, queued);
        }
        if (matched == 0) std.debug.print("DEAD_DYNAMIC_EDGE caller={s} pattern={s} expr={s}\n", .{ caller, pattern, raw_expr });
        if (matched > 128) std.debug.print("WIDE_DYNAMIC_EDGE caller={s} matches={d} pattern={s} expr={s}\n", .{ caller, matched, pattern, raw_expr });
        return matched;
    }

    fn resolveInvokes(self: *Analyzer) !void {
        for (self.direct_invokes.items) |inv| try self.collectInvoke(inv, null);
        var it = self.invokes.iterator();
        while (it.next()) |entry| {
            if (!self.reachable.contains(entry.key_ptr.*)) continue;
            const state = try self.stateFor(entry.key_ptr.*);
            for (entry.value_ptr.*.items) |inv| try self.collectInvoke(inv, state);
        }
    }

    fn collectInvoke(self: *Analyzer, inv: Invoke, state: ?*State) !void {
        var modules = if (state) |st| try self.evalExpr(inv.module_expr, st, inv.host) else try self.staticExpr(inv.module_expr);
        defer modules.values.deinit(self.allocator);
        var functions = if (state) |st| try self.evalExpr(inv.function_expr, st, inv.host) else try self.staticExpr(inv.function_expr);
        defer functions.values.deinit(self.allocator);
        if (modules.top or modules.missing or functions.top or functions.missing) {
            self.dynamic_invokes += 1;
            std.debug.print("DYNAMIC_INVOKE host_kind={d} host={s} module={s} function={s} module_top={} module_missing={} function_top={} function_missing={}\n", .{
                inv.host_kind, inv.host, inv.module_expr, inv.function_expr, modules.top, modules.missing, functions.top, functions.missing,
            });
            return;
        }

        var mit = modules.values.iterator();
        while (mit.next()) |me| {
            const mod_name0 = try self.normalizeTitle(me.key_ptr.*, "Module:");
            if (mod_name0.len == 0 or isDynamicText(mod_name0)) {
                self.dynamic_invokes += 1;
                std.debug.print("DYNAMIC_INVOKE_VALUE host={s} module={s} function={s} resolved_module={s}\n", .{ inv.host, inv.module_expr, inv.function_expr, me.key_ptr.* });
                continue;
            }
            const full0 = try std.fmt.allocPrint(self.allocator, "Module:{s}", .{mod_name0});
            var module = try self.interner.intern(full0);
            if (self.module_redirects.get(module)) |to| module = to;
            var fit = functions.values.iterator();
            while (fit.next()) |fe| {
                const function = std.mem.trim(u8, fe.key_ptr.*, " \t\r\n");
                if (function.len == 0 or isDynamicText(function)) {
                    self.dynamic_invokes += 1;
                    std.debug.print("DYNAMIC_INVOKE_FUNCTION host={s} module={s} function={s} resolved_function={s}\n", .{ inv.host, inv.module_expr, inv.function_expr, function });
                    continue;
                }
                const key_text = try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}", .{ module, function });
                const key = try self.interner.intern(key_text);
                const gop = try self.invocation_domains.getOrPut(self.allocator, key);
                if (!gop.found_existing) {
                    const ctx = try self.allocator.create(InvokeContext);
                    ctx.* = .{ .module = module, .function = try self.interner.intern(function) };
                    gop.value_ptr.* = ctx;
                }
                var args = if (state) |st| try self.evalArgs(inv.args, st, inv.host) else try self.staticArgs(inv.args);
                defer args.deinit(self.allocator);
                _ = try gop.value_ptr.*.state.mergeContext(self.allocator, &args);
                var parent_ctx: ArgContext = .{ .dynamic_keys = if (state) |s| s.dynamic_keys else false };
                defer parent_ctx.deinit(self.allocator);
                if (state) |s| {
                    var parent_it = s.params.iterator();
                    while (parent_it.next()) |entry| try parent_ctx.values.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
                _ = try gop.value_ptr.*.parent.mergeContext(self.allocator, &parent_ctx);
            }
        }
    }

    fn staticExpr(self: *Analyzer, expr: []const u8) !Domain {
        var d: Domain = .{};
        if (isDynamicText(expr)) { d.top = true; return d; }
        _ = try d.add(self.allocator, try self.interner.intern(expr));
        return d;
    }

    fn evalExpr(self: *Analyzer, expr: []const u8, state: *State, host: []const u8) anyerror!Domain {
        var out = try literalDomain(self, "");
        var pos: usize = 0;
        while (pos < expr.len) {
            const open = std.mem.indexOfPos(u8, expr, pos, "{{") orelse {
                var literal = try literalDomain(self, expr[pos..]);
                defer literal.values.deinit(self.allocator);
                return try concatDomains(self, &out, &literal);
            };
            if (open > pos) {
                var literal = try literalDomain(self, expr[pos..open]);
                defer literal.values.deinit(self.allocator);
                out = try concatDomains(self, &out, &literal);
                if (out.top) return out;
            }
            var piece: Domain = undefined;
            var next: usize = undefined;
            if (open + 2 < expr.len and expr[open + 2] == '{') {
                const close = findParamEnd(expr, open) orelse return .{ .top = true };
                piece = try self.evalParameter(expr[open + 3 .. close], state, host);
                next = close + 3;
            } else {
                const close = findTemplateEnd(expr, open) orelse return .{ .top = true };
                piece = try self.evalConstruct(expr[open + 2 .. close], state, host);
                next = close + 2;
            }
            defer piece.values.deinit(self.allocator);
            out = try concatDomains(self, &out, &piece);
            if (out.top) return out;
            pos = next;
        }
        return out;
    }

    fn evalParameter(self: *Analyzer, inside: []const u8, state: *State, host: []const u8) anyerror!Domain {
        const split = splitParam(inside);
        const key = std.mem.trim(u8, split.key, " \t\r\n");
        if (key.len == 0 or isDynamicText(key)) return .{ .top = true, .missing = true };
        if (state.params.get(key)) |source| {
            if (source.top) {
                if (!source.missing or split.default == null) return .{ .top = true, .missing = source.missing };
                var fallback = try self.evalExpr(split.default.?, state, host);
                fallback.top = true;
                fallback.missing = false;
                return fallback;
            }
            var out: Domain = .{};
            var it = source.values.iterator();
            while (it.next()) |entry| _ = try out.add(self.allocator, entry.key_ptr.*);
            if (source.missing) {
                if (split.default) |default| {
                    var fallback = try self.evalExpr(default, state, host);
                    defer fallback.values.deinit(self.allocator);
                    _ = try out.merge(self.allocator, &fallback);
                } else {
                    // MediaWiki preserves an unspecified triple-brace parameter
                    // without a default as literal {{{name}}}. Keeping that exact
                    // sentinel lets #switch/#ifeq prove their fallback path.
                    const unresolved = try std.fmt.allocPrint(self.allocator, "{{{{{{{s}}}}}}}", .{key});
                    _ = try out.add(self.allocator, try self.interner.intern(unresolved));
                }
            }
            return out;
        }
        if (split.default) |default| return self.evalExpr(default, state, host);
        if (state.dynamic_keys) return .{ .top = true, .missing = true };
        const unresolved = try std.fmt.allocPrint(self.allocator, "{{{{{{{s}}}}}}}", .{key});
        return literalDomain(self, unresolved);
    }

    fn evalConstruct(self: *Analyzer, content: []const u8, state: *State, host: []const u8) anyerror!Domain {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try splitWikitextTop(self.allocator, content, '|', &parts);
        if (parts.items.len == 0) return .{ .top = true };
        const head = std.mem.trim(u8, parts.items[0], " \t\r\n");
        if (head.len == 0) return .{ .top = true };

        if (magicWordValue(self, head, host)) |value| return literalDomain(self, value);

        const colon = findTopDelimiter(head, ':');
        if (colon) |ci| {
            const name = std.mem.trim(u8, head[0..ci], " \t\r\n");
            const first = head[ci + 1 ..];
            if (std.ascii.eqlIgnoreCase(name, "#if"))
                return self.evalIf(first, parts.items[1..], state, host);
            if (std.ascii.eqlIgnoreCase(name, "#ifeq"))
                return self.evalIfEq(first, parts.items[1..], state, host);
            if (std.ascii.eqlIgnoreCase(name, "#switch"))
                return self.evalSwitch(first, parts.items[1..], state, host);
            if (std.ascii.eqlIgnoreCase(name, "lc") or std.ascii.eqlIgnoreCase(name, "uc") or
                std.ascii.eqlIgnoreCase(name, "lcfirst") or std.ascii.eqlIgnoreCase(name, "ucfirst"))
                return self.evalCaseTransform(name, first, state, host);
            if (std.ascii.eqlIgnoreCase(name, "padleft") or std.ascii.eqlIgnoreCase(name, "padright"))
                return self.evalPad(name, first, parts.items[1..], state, host);
        }
        // Ordinary template expansion is deliberately opaque here. Its call edge
        // is tracked independently, but its rendered text cannot be guessed.
        return .{ .top = true };
    }

    fn evalIf(self: *Analyzer, test_expr: []const u8, args: []const []const u8, state: *State, host: []const u8) anyerror!Domain {
        var condition = try self.evalExpr(test_expr, state, host);
        defer condition.values.deinit(self.allocator);
        const shape = domainEmptiness(&condition);
        var out: Domain = .{};
        if (shape.nonempty) {
            var yes = try self.evalExpr(if (args.len > 0) args[0] else "", state, host);
            defer yes.values.deinit(self.allocator);
            _ = try out.merge(self.allocator, &yes);
        }
        if (shape.empty) {
            var no = try self.evalExpr(if (args.len > 1) args[1] else "", state, host);
            defer no.values.deinit(self.allocator);
            _ = try out.merge(self.allocator, &no);
        }
        return out;
    }

    fn evalIfEq(self: *Analyzer, lhs_expr: []const u8, args: []const []const u8, state: *State, host: []const u8) anyerror!Domain {
        if (args.len == 0) return .{ .top = true };
        var lhs = try self.evalExpr(lhs_expr, state, host); defer lhs.values.deinit(self.allocator);
        var rhs = try self.evalExpr(args[0], state, host); defer rhs.values.deinit(self.allocator);
        const eq = domainEquality(&lhs, &rhs);
        var out: Domain = .{};
        if (eq.yes) {
            var yes = try self.evalExpr(if (args.len > 1) args[1] else "", state, host); defer yes.values.deinit(self.allocator);
            _ = try out.merge(self.allocator, &yes);
        }
        if (eq.no) {
            var no = try self.evalExpr(if (args.len > 2) args[2] else "", state, host); defer no.values.deinit(self.allocator);
            _ = try out.merge(self.allocator, &no);
        }
        return out;
    }

    fn evalSwitch(self: *Analyzer, key_expr: []const u8, args: []const []const u8, state: *State, host: []const u8) anyerror!Domain {
        var key_domain = try self.evalExpr(key_expr, state, host); defer key_domain.values.deinit(self.allocator);
        if (key_domain.top or key_domain.missing) return .{ .top = true };
        var out: Domain = .{};
        var kit = key_domain.values.iterator();
        while (kit.next()) |ke| {
            var one = try self.evalSwitchKey(ke.key_ptr.*, args, state, host); defer one.values.deinit(self.allocator);
            _ = try out.merge(self.allocator, &one);
            if (out.top) break;
        }
        return out;
    }

    fn evalSwitchKey(self: *Analyzer, raw_key: []const u8, args: []const []const u8, state: *State, host: []const u8) anyerror!Domain {
        const key = std.mem.trim(u8, raw_key, " \t\r\n");
        var pending_match = false;
        var default_expr: ?[]const u8 = null;
        var trailing_value: ?[]const u8 = null;
        for (args) |raw_case| {
            if (findTopDelimiter(raw_case, '=')) |eq| {
                const label_expr = std.mem.trim(u8, raw_case[0..eq], " \t\r\n");
                const result_expr = raw_case[eq + 1 ..];
                if (std.ascii.eqlIgnoreCase(label_expr, "#default")) {
                    default_expr = result_expr;
                    if (pending_match) return self.evalExpr(result_expr, state, host);
                    continue;
                }
                var label = try self.evalExpr(label_expr, state, host); defer label.values.deinit(self.allocator);
                const matches = domainContainsTrimmed(&label, key);
                if (pending_match or matches.yes) return self.evalExpr(result_expr, state, host);
                if (matches.maybe) return .{ .top = true };
                pending_match = false;
            } else {
                trailing_value = raw_case;
                var label = try self.evalExpr(raw_case, state, host); defer label.values.deinit(self.allocator);
                const matches = domainContainsTrimmed(&label, key);
                if (matches.yes) pending_match = true;
                if (matches.maybe) return .{ .top = true };
            }
        }
        if (default_expr) |expr| return self.evalExpr(expr, state, host);
        // In MediaWiki #switch, a final argument without '=' is the
        // default result as well as a fall-through label.
        if (trailing_value) |expr| return self.evalExpr(expr, state, host);
        return literalDomain(self, "");
    }

    fn evalCaseTransform(self: *Analyzer, name: []const u8, arg: []const u8, state: *State, host: []const u8) anyerror!Domain {
        var input = try self.evalExpr(arg, state, host); defer input.values.deinit(self.allocator);
        if (input.top or input.missing) return .{ .top = true };
        var out: Domain = .{};
        var it = input.values.iterator();
        while (it.next()) |entry| {
            const src = entry.key_ptr.*;
            var buf = try self.allocator.dupe(u8, src);
            if (!std.unicode.utf8ValidateSlice(buf)) return .{ .top = true };
            if (std.ascii.eqlIgnoreCase(name, "lc") or std.ascii.eqlIgnoreCase(name, "uc")) {
                for (buf) |*c| {
                    if (c.* < 0x80) c.* = if (std.ascii.eqlIgnoreCase(name, "lc")) std.ascii.toLower(c.*) else std.ascii.toUpper(c.*);
                }
            } else if (buf.len != 0 and buf[0] < 0x80) {
                buf[0] = if (std.ascii.eqlIgnoreCase(name, "lcfirst")) std.ascii.toLower(buf[0]) else std.ascii.toUpper(buf[0]);
            }
            _ = try out.add(self.allocator, try self.interner.intern(buf));
        }
        return out;
    }

    fn evalPad(self: *Analyzer, name: []const u8, first: []const u8, args: []const []const u8, state: *State, host: []const u8) anyerror!Domain {
        if (args.len == 0) return .{ .top = true };
        var values = try self.evalExpr(first, state, host); defer values.values.deinit(self.allocator);
        var widths = try self.evalExpr(args[0], state, host); defer widths.values.deinit(self.allocator);
        var pads = try self.evalExpr(if (args.len > 1) args[1] else "0", state, host); defer pads.values.deinit(self.allocator);
        if (values.top or widths.top or pads.top or values.missing or widths.missing or pads.missing) return .{ .top = true };
        var out: Domain = .{};
        var vit = values.values.iterator();
        while (vit.next()) |ve| {
            var wit = widths.values.iterator();
            while (wit.next()) |we| {
                const width = std.fmt.parseInt(usize, std.mem.trim(u8, we.key_ptr.*, " \t\r\n"), 10) catch return .{ .top = true };
                var pit = pads.values.iterator();
                while (pit.next()) |pe| {
                    const pad = pe.key_ptr.*;
                    if (pad.len == 0) return .{ .top = true };
                    const src = ve.key_ptr.*;
                    if (src.len >= width) { _ = try out.add(self.allocator, src); continue; }
                    const need = width - src.len;
                    if (need > 4096) return .{ .top = true };
                    const fill = try self.allocator.alloc(u8, need);
                    for (fill, 0..) |*c, i| c.* = pad[i % pad.len];
                    const joined = if (std.ascii.eqlIgnoreCase(name, "padleft"))
                        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ fill, src })
                    else try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ src, fill });
                    _ = try out.add(self.allocator, try self.interner.intern(joined));
                }
            }
        }
        return out;
    }

    fn evalArgs(self: *Analyzer, args: []const []const u8, state: *State, host: []const u8) !ArgContext {
        var out: ArgContext = .{};
        var positional: usize = 1;
        for (args) |raw| {
            const parsed = try parseArg(self, raw, &positional);
            if (isDynamicText(parsed.key)) { out.dynamic_keys = true; continue; }
            const d = try self.allocator.create(Domain);
            d.* = try self.evalExpr(parsed.value, state, host);
            try out.values.put(self.allocator, parsed.key, d);
        }
        return out;
    }

    fn staticArgs(self: *Analyzer, args: []const []const u8) !ArgContext {
        var out: ArgContext = .{};
        var positional: usize = 1;
        for (args) |raw| {
            const parsed = try parseArg(self, raw, &positional);
            if (isDynamicText(parsed.key)) { out.dynamic_keys = true; continue; }
            const d = try self.allocator.create(Domain);
            d.* = try self.staticExpr(parsed.value);
            try out.values.put(self.allocator, parsed.key, d);
        }
        return out;
    }

    fn writeReport(self: *Analyzer, w: *std.Io.Writer) !void {
        try w.print("S\ttemplates_defined\t{d}\n", .{self.templates.count()});
        try w.print("S\troot_calls\t{d}\n", .{self.root_calls});
        try w.print("S\treachable_templates\t{d}\n", .{self.reachable.count()});
        try w.print("S\tunreachable_templates\t{d}\n", .{self.templates.count() -| self.reachable.count()});
        try w.print("S\tdynamic_roots\t{d}\n", .{self.dynamic_roots});
        try w.print("S\tdynamic_template_edges\t{d}\n", .{self.dynamic_template_edges});
        try w.print("S\tpattern_resolved_edges\t{d}\n", .{self.pattern_resolved_edges});
        try w.print("S\tpattern_target_candidates\t{d}\n", .{self.pattern_target_candidates});
        try w.print("S\tbroad_template_patterns\t{d}\n", .{self.broad_patterns});
        try w.print("S\tinvocation_entrypoints\t{d}\n", .{self.invocation_domains.count()});
        try w.print("S\tdynamic_invokes\t{d}\n", .{self.dynamic_invokes});

        var redirect_names = try self.allocator.alloc([]const u8, self.module_redirects.count());
        defer self.allocator.free(redirect_names);
        var ri: usize = 0;
        var rit = self.module_redirects.iterator();
        while (rit.next()) |entry| : (ri += 1) redirect_names[ri] = entry.key_ptr.*;
        std.mem.sort([]const u8, redirect_names, {}, lessStr);
        for (redirect_names) |from| {
            try w.writeAll("M\t"); try writeField(w, from); try w.writeByte('\t');
            try writeField(w, self.module_redirects.get(from).?); try w.writeByte('\n');
        }

        var keys = try self.allocator.alloc([]const u8, self.invocation_domains.count());
        defer self.allocator.free(keys);
        var i: usize = 0; var it = self.invocation_domains.iterator();
        while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
        std.mem.sort([]const u8, keys, {}, lessStr);
        for (keys) |key| {
            const ctx = self.invocation_domains.get(key).?;
            try w.writeAll("U\t"); try writeField(w, ctx.module); try w.writeByte('\t'); try writeField(w, ctx.function); try w.writeByte('\n');
            try w.writeAll("W\t"); try writeField(w, ctx.module); try w.writeByte('\t'); try writeField(w, ctx.function); try w.print("\t{}\t{}\n", .{ ctx.state.dynamic_keys, ctx.parent.dynamic_keys });
            var pnames = try self.allocator.alloc([]const u8, ctx.state.params.count()); defer self.allocator.free(pnames);
            i = 0; var pit = ctx.state.params.iterator(); while (pit.next()) |p| : (i += 1) pnames[i] = p.key_ptr.*;
            std.mem.sort([]const u8, pnames, {}, lessStr);
            for (pnames) |pname| {
                const d = ctx.state.params.get(pname).?;
                try w.writeAll("P\t"); try writeField(w, ctx.module); try w.writeByte('\t'); try writeField(w, ctx.function); try w.writeByte('\t'); try writeField(w, pname);
                try w.print("\t{}\t{}", .{ d.top, d.missing });
                if (!d.top) {
                    var vals = try self.allocator.alloc([]const u8, d.values.count()); defer self.allocator.free(vals);
                    var vi: usize = 0; var vit = d.values.iterator(); while (vit.next()) |v| : (vi += 1) vals[vi] = v.key_ptr.*;
                    std.mem.sort([]const u8, vals, {}, lessStr);
                    for (vals) |v| { try w.writeByte('\t'); try writeField(w, v); }
                }
                try w.writeByte('\n');
            }
            var parent_names = try self.allocator.alloc([]const u8, ctx.parent.params.count()); defer self.allocator.free(parent_names);
            i = 0; var qit = ctx.parent.params.iterator(); while (qit.next()) |p| : (i += 1) parent_names[i] = p.key_ptr.*;
            std.mem.sort([]const u8, parent_names, {}, lessStr);
            for (parent_names) |pname| {
                const d = ctx.parent.params.get(pname).?;
                try w.writeAll("Q\t"); try writeField(w, ctx.module); try w.writeByte('\t'); try writeField(w, ctx.function); try w.writeByte('\t'); try writeField(w, pname);
                try w.print("\t{}\t{}", .{ d.top, d.missing });
                if (!d.top) {
                    var vals = try self.allocator.alloc([]const u8, d.values.count()); defer self.allocator.free(vals);
                    var vi: usize = 0; var vit = d.values.iterator(); while (vit.next()) |v| : (vi += 1) vals[vi] = v.key_ptr.*;
                    std.mem.sort([]const u8, vals, {}, lessStr);
                    for (vals) |v| { try w.writeByte('\t'); try writeField(w, v); }
                }
                try w.writeByte('\n');
            }
        }
    }
};



fn containsInvalidTitleMarkup(s: []const u8) bool {
    for (s) |c| switch (c) {
        '[', ']', '{', '}', '<', '>', '|' => return true,
        else => {},
    };
    return false;
}

fn wildcardTargetPatternAlloc(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var star = false;
    while (pos < s.len) {
        if (pos + 2 < s.len and std.mem.eql(u8, s[pos..pos+3], "{{{")) {
            const close = findParamEnd(s, pos) orelse { if (!star) try out.append(a, '*'); break; };
            if (!star) try out.append(a, '*');
            star = true; pos = close + 3; continue;
        }
        if (pos + 1 < s.len and std.mem.eql(u8, s[pos..pos+2], "{{")) {
            const close = findTemplateEnd(s, pos) orelse { if (!star) try out.append(a, '*'); break; };
            if (!star) try out.append(a, '*');
            star = true; pos = close + 2; continue;
        }
        if (pos + 1 < s.len and std.mem.eql(u8, s[pos..pos+2], "[[")) {
            const close = std.mem.indexOfPos(u8, s, pos + 2, "]]" ) orelse { if (!star) try out.append(a, '*'); break; };
            const inside = s[pos + 2 .. close];
            const pipe = std.mem.lastIndexOfScalar(u8, inside, '|');
            var display = if (pipe) |cut| inside[cut + 1 ..] else inside;
            if (std.mem.indexOfScalar(u8, display, '#')) |hash| display = display[0..hash];
            if (display.len != 0 and display[0] == ':') display = display[1..];
            for (display) |dc0| {
                var dc = dc0;
                if (dc == '_') dc = ' ';
                try out.append(a, dc);
            }
            star = false; pos = close + 2; continue;
        }
        var c = s[pos];
        if (c == '_') c = ' ';
        if (c == '*') c = ' ';
        try out.append(a, c);
        star = false;
        pos += 1;
    }
    return out.toOwnedSlice(a);
}

fn titleCharEq(a: u8, b: u8) bool {
    if ((a == ' ' and b == '_') or (a == '_' and b == ' ')) return true;
    if (a < 0x80 and b < 0x80) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return a == b;
}

fn globTitleMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] != '*' and titleCharEq(pattern[p], text[t])) {
            p += 1; t += 1; continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star = p; p += 1; retry = t; continue;
        }
        if (star) |sp| {
            retry += 1; t = retry; p = sp + 1; continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const Possibility = struct { yes: bool = false, no: bool = false, maybe: bool = false };
const EmptyShape = struct { empty: bool = false, nonempty: bool = false };

fn literalDomain(self: *Analyzer, text: []const u8) !Domain {
    var out: Domain = .{};
    _ = try out.add(self.allocator, try self.interner.intern(text));
    return out;
}

fn concatDomains(self: *Analyzer, lhs: *Domain, rhs: *const Domain) !Domain {
    if (lhs.top or rhs.top or lhs.missing or rhs.missing) return .{ .top = true, .missing = lhs.missing or rhs.missing };
    if (lhs.values.count() * rhs.values.count() > cap_values) return .{ .top = true };
    var out: Domain = .{};
    var lit = lhs.values.iterator();
    while (lit.next()) |le| {
        var rit = rhs.values.iterator();
        while (rit.next()) |re| {
            const joined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ le.key_ptr.*, re.key_ptr.* });
            _ = try out.add(self.allocator, try self.interner.intern(joined));
        }
    }
    return out;
}

fn domainEmptiness(d: *const Domain) EmptyShape {
    if (d.top or d.missing) return .{ .empty = true, .nonempty = true };
    var out: EmptyShape = .{};
    var it = d.values.iterator();
    while (it.next()) |entry| {
        if (std.mem.trim(u8, entry.key_ptr.*, " \t\r\n").len == 0) out.empty = true else out.nonempty = true;
    }
    return out;
}

fn domainEquality(a: *const Domain, b: *const Domain) Possibility {
    if (a.top or b.top or a.missing or b.missing) return .{ .yes = true, .no = true, .maybe = true };
    var yes = false;
    var no = false;
    var ai = a.values.iterator();
    while (ai.next()) |ae| {
        const av = std.mem.trim(u8, ae.key_ptr.*, " \t\r\n");
        var bi = b.values.iterator();
        while (bi.next()) |be| {
            const bv = std.mem.trim(u8, be.key_ptr.*, " \t\r\n");
            if (std.mem.eql(u8, av, bv)) yes = true else no = true;
        }
    }
    return .{ .yes = yes, .no = no };
}

fn domainContainsTrimmed(d: *const Domain, key: []const u8) Possibility {
    if (d.top or d.missing) return .{ .yes = true, .no = true, .maybe = true };
    var yes = false;
    var no = false;
    var it = d.values.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry.key_ptr.*, " \t\r\n"), key)) yes = true else no = true;
    }
    return .{ .yes = yes, .no = no };
}

fn findTemplateEnd(s: []const u8, start: usize) ?usize {
    if (start + 1 >= s.len or !std.mem.eql(u8, s[start .. start + 2], "{{")) return null;
    var stack: [128]u8 = undefined;
    var depth: usize = 1;
    stack[0] = 2;
    var i = start + 2;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "{{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 3; depth += 1; i += 3; continue;
        }
        if (i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "{{")) {
            if (depth == stack.len) return null;
            stack[depth] = 2; depth += 1; i += 2; continue;
        }
        if (depth != 0 and stack[depth - 1] == 3 and i + 2 < s.len and std.mem.eql(u8, s[i .. i + 3], "}}}")) {
            depth -= 1; i += 3; continue;
        }
        if (depth != 0 and stack[depth - 1] == 2 and i + 1 < s.len and std.mem.eql(u8, s[i .. i + 2], "}}")) {
            depth -= 1;
            if (depth == 0) return i;
            i += 2; continue;
        }
        i += 1;
    }
    return null;
}

fn findTopDelimiter(s: []const u8, needle: u8) ?usize {
    var curly: i32 = 0;
    var square: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "{{{")) { curly += 3; i += 3; continue; }
        if (i + 1 < s.len and std.mem.eql(u8, s[i..i+2], "{{")) { curly += 2; i += 2; continue; }
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "}}}") and curly >= 3) { curly -= 3; i += 3; continue; }
        if (i + 1 < s.len and std.mem.eql(u8, s[i..i+2], "}}") and curly >= 2) { curly -= 2; i += 2; continue; }
        if (i + 1 < s.len and std.mem.eql(u8, s[i..i+2], "[[")) { square += 2; i += 2; continue; }
        if (i + 1 < s.len and std.mem.eql(u8, s[i..i+2], "]]" ) and square >= 2) { square -= 2; i += 2; continue; }
        if (s[i] == needle and curly == 0 and square == 0) return i;
        i += 1;
    }
    return null;
}

fn splitWikitextTop(a: std.mem.Allocator, s: []const u8, delimiter: u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const rel = findTopDelimiter(s[pos..], delimiter) orelse break;
        const cut = pos + rel;
        try out.append(a, s[start..cut]);
        start = cut + 1;
        pos = start;
    }
    try out.append(a, s[start..]);
}

fn magicWordValue(self: *Analyzer, head: []const u8, host: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(head, "PAGENAME")) return self.interner.intern(host) catch null;
    if (std.ascii.eqlIgnoreCase(head, "FULLPAGENAME")) return self.interner.intern(std.fmt.allocPrint(self.allocator, "Template:{s}", .{host}) catch return null) catch null;
    if (std.ascii.eqlIgnoreCase(head, "NAMESPACE")) return "Template";
    if (std.ascii.eqlIgnoreCase(head, "BASEPAGENAME")) {
        const slash = std.mem.lastIndexOfScalar(u8, host, '/') orelse return self.interner.intern(host) catch null;
        return self.interner.intern(host[0..slash]) catch null;
    }
    if (std.ascii.eqlIgnoreCase(head, "SUBPAGENAME")) {
        const slash = std.mem.lastIndexOfScalar(u8, host, '/') orelse return self.interner.intern(host) catch null;
        return self.interner.intern(host[slash + 1 ..]) catch null;
    }
    return null;
}

const ParamSplit = struct { key: []const u8, default: ?[]const u8 };
fn splitParam(s: []const u8) ParamSplit {
    var depth: usize = 0; var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "{{{")) { depth += 1; i += 3; continue; }
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "}}}") and depth != 0) { depth -= 1; i += 3; continue; }
        if (s[i] == '|' and depth == 0) return .{ .key = s[0..i], .default = s[i+1..] };
        i += 1;
    }
    return .{ .key = s, .default = null };
}

fn findParamEnd(s: []const u8, start: usize) ?usize {
    var depth: usize = 1; var i = start + 3;
    while (i < s.len) {
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "{{{")) { depth += 1; i += 3; continue; }
        if (i + 2 < s.len and std.mem.eql(u8, s[i..i+3], "}}}")) {
            depth -= 1; if (depth == 0) return i; i += 3; continue;
        }
        i += 1;
    }
    return null;
}

fn containsNonParamTemplate(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, "{{")) |p| {
        if (p + 2 >= s.len or s[p + 2] != '{') return true;
        const e = findParamEnd(s, p) orelse return true;
        i = e + 3;
    }
    return std.mem.indexOf(u8, s, "[[") != null;
}


fn isParserOrMagicHead(raw: []const u8) bool {
    const s = std.mem.trim(u8, raw, " \\t\\r\\n");
    if (s.len == 0) return false;
    if (s[0] == '#') return true;
    const exact = [_][]const u8{
        "PAGENAME", "PAGENAMEE", "FULLPAGENAME", "FULLPAGENAMEE",
        "BASEPAGENAME", "BASEPAGENAMEE", "SUBPAGENAME", "SUBPAGENAMEE",
        "NAMESPACE", "NAMESPACEE", "NAMESPACENUMBER", "TALKSPACE", "SUBJECTSPACE",
        "TALKPAGENAME", "SUBJECTPAGENAME", "ARTICLEPAGENAME", "ROOTPAGENAME",
        "CURRENTYEAR", "CURRENTMONTH", "CURRENTMONTH1", "CURRENTMONTHNAME",
        "CURRENTDAY", "CURRENTDAY2", "CURRENTDOW", "CURRENTTIME", "CURRENTHOUR",
        "REVISIONID", "REVISIONUSER", "REVISIONTIMESTAMP", "SITENAME", "SERVER", "SERVERNAME",
    };
    for (exact) |name| if (std.ascii.eqlIgnoreCase(s, name)) return true;
    const prefixes = [_][]const u8{
        "lc:", "uc:", "lcfirst:", "ucfirst:", "urlencode:", "anchorencode:",
        "fullurl:", "fullurle:", "localurl:", "filepath:", "formatnum:", "padleft:", "padright:",
        "pagename:", "pagenamee:", "fullpagename:", "fullpagenamee:",
        "basepagename:", "basepagenamee:", "subpagename:", "subpagenamee:",
        "namespace:", "namespacee:", "talkpagename:", "subjectpagename:", "rootpagename:",
        "plural:", "grammar:", "gender:", "int:", "ns:", "nse:", "canonicalurl:",
        "displaytitle:", "defaultsort:", "defaultcategorysort:", "pagesincategory:",
        "pagesinnamespace:", "numberofpages:", "numberofarticles:", "numberoffiles:",
    };
    for (prefixes) |prefix| {
        if (s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn isDynamicText(s: []const u8) bool { return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "[[") != null; }

fn appendLiteral(a: std.mem.Allocator, values: *std.ArrayList([]const u8), literal: []const u8) !void {
    if (literal.len == 0) return;
    for (values.items, 0..) |base, i| values.items[i] = try std.fmt.allocPrint(a, "{s}{s}", .{ base, literal });
}

const ParsedArg = struct { key: []const u8, value: []const u8 };
fn parseArg(self: *Analyzer, raw: []const u8, positional: *usize) !ParsedArg {
    var curly: i32 = 0; var square: i32 = 0; var i: usize = 0;
    while (i < raw.len) {
        if (i + 2 < raw.len and std.mem.eql(u8, raw[i..i+3], "{{{")) { curly += 3; i += 3; continue; }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i..i+2], "{{")) { curly += 2; i += 2; continue; }
        if (i + 2 < raw.len and std.mem.eql(u8, raw[i..i+3], "}}}") and curly >= 3) { curly -= 3; i += 3; continue; }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i..i+2], "}}") and curly >= 2) { curly -= 2; i += 2; continue; }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i..i+2], "[[")) { square += 2; i += 2; continue; }
        if (i + 1 < raw.len and std.mem.eql(u8, raw[i..i+2], "]]" ) and square >= 2) { square -= 2; i += 2; continue; }
        if (raw[i] == '=' and curly == 0 and square == 0) {
            const key = std.mem.trim(u8, raw[0..i], " \t\r\n");
            if (key.len != 0) return .{ .key = try self.interner.intern(key), .value = std.mem.trim(u8, raw[i+1..], " \t\r\n") };
            break;
        }
        i += 1;
    }
    var buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "{d}", .{positional.*}); positional.* += 1;
    return .{ .key = try self.interner.intern(key), .value = std.mem.trim(u8, raw, " \t\r\n") };
}

fn writeField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"), '\t' => try w.writeAll("\\t"), '\n' => try w.writeAll("\\n"), '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}
fn lessStr(_: void, a: []const u8, b: []const u8) bool { return std.mem.order(u8, a, b) == .lt; }

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingInput;
    var mapped = try mmapPath(args[1]); defer mapped.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator); defer arena.deinit();
    const a = arena.allocator();
    var analyzer = Analyzer.init(a);
    try analyzer.parseReduced(mapped.bytes);
    try analyzer.runTemplateFixedPoint();
    try analyzer.resolveInvokes();

    var out_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try analyzer.writeReport(&stdout.interface);
    try stdout.interface.flush();
    std.debug.print("templates={d}/{d} roots={d} dynamic_roots={d} dynamic_edges={d} invoke_entrypoints={d} dynamic_invokes={d}\n", .{
        analyzer.reachable.count(), analyzer.templates.count(), analyzer.root_calls, analyzer.dynamic_roots, analyzer.dynamic_template_edges, analyzer.invocation_domains.count(), analyzer.dynamic_invokes,
    });
}
