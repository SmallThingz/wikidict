const std = @import("std");
const lua = @import("root.zig");

const ShadowMap = std.StringHashMapUnmanaged(void);
const ShadowFrame = struct { map: *const ShadowMap, parent: ?*const ShadowFrame };

const Analyzer = struct {
    source: []const u8,
    writer: *std.Io.Writer,
    page_id: []const u8,
    string_constants: std.StringHashMapUnmanaged([]const u8) = .empty,
    current_shadows: ?*const ShadowFrame = null,

    fn deinit(self: *Analyzer) void {
        var it = self.string_constants.iterator();
        while (it.next()) |entry| {
            if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '.') != null)
                std.heap.smp_allocator.free(@constCast(entry.key_ptr.*));
        }
        self.string_constants.deinit(std.heap.smp_allocator);
    }

    fn run(self: *Analyzer, body: lua.Block) anyerror!void {
        try self.collectModuleConstants(body);
        try self.walkBlock(body, 0);
    }

    fn walkBlock(self: *Analyzer, block: lua.Block, fn_start: u32) anyerror!void {
        for (block) |stmt| try self.walkStmt(stmt, fn_start);
    }

    fn walkStmt(self: *Analyzer, stmt: *const lua.Stmt, fn_start: u32) anyerror!void {
        switch (stmt.*) {
            .empty, .break_stmt => {},
            .assign => |s| {
                for (s.targets) |t| try self.walkLValue(t, fn_start);
                for (s.values, 0..) |v, i| {
                    const label = if (i < s.targets.len) try self.lvalueName(s.targets[i]) else null;
                    defer if (label) |x| self.freeMaybe(x);
                    try self.walkExprLabeled(v, fn_start, label);
                }
            },
            .local_assign => |s| {
                for (s.values, 0..) |v, i| {
                    const label: ?[]const u8 = if (i < s.names.len) s.names[i] else null;
                    try self.walkExprLabeled(v, fn_start, label);
                }
            },
            .call => |s| try self.walkExpr(s.expr, fn_start),
            .do_block => |s| try self.walkBlock(s.body, fn_start),
            .while_loop => |s| {
                try self.branch("while", s.span, s.cond.span(), fn_start);
                try self.walkExpr(s.cond, fn_start);
                try self.walkBlock(s.body, fn_start);
            },
            .repeat_loop => |s| {
                try self.branch("repeat", s.span, s.cond.span(), fn_start);
                try self.walkBlock(s.body, fn_start);
                try self.walkExpr(s.cond, fn_start);
            },
            .if_stmt => |s| {
                for (s.branches, 0..) |b, i| {
                    try self.branch(if (i == 0) "if" else "elseif", s.span, b.cond.span(), fn_start);
                    try self.walkExpr(b.cond, fn_start);
                    try self.walkBlock(b.body, fn_start);
                }
                if (s.else_body) |b| try self.walkBlock(b, fn_start);
            },
            .numeric_for => |s| {
                try self.walkExpr(s.start, fn_start);
                try self.walkExpr(s.limit, fn_start);
                if (s.step) |v| try self.walkExpr(v, fn_start);
                try self.walkBlock(s.body, fn_start);
            },
            .generic_for => |s| {
                for (s.values) |v| try self.walkExpr(v, fn_start);
                try self.walkBlock(s.body, fn_start);
            },
            .function_assign => |s| {
                const label = try self.lvalueName(s.target);
                defer if (label) |x| self.freeMaybe(x);
                try self.walkLValue(s.target, fn_start);
                try self.walkExprLabeled(s.function, fn_start, label);
            },
            .local_function => |s| try self.walkExprLabeled(s.function, fn_start, s.name),
            .return_stmt => |s| for (s.values) |v| try self.walkExpr(v, fn_start),
        }
    }

    fn walkLValue(self: *Analyzer, lv: lua.LValue, fn_start: u32) anyerror!void {
        switch (lv) {
            .name => {},
            .index => |i| {
                try self.walkExpr(i.object, fn_start);
                try self.walkExpr(i.key, fn_start);
            },
        }
    }

    fn walkExpr(self: *Analyzer, expr: *const lua.Expr, fn_start: u32) anyerror!void {
        try self.walkExprLabeled(expr, fn_start, null);
    }

    fn walkExprLabeled(self: *Analyzer, expr: *const lua.Expr, fn_start: u32, label: ?[]const u8) anyerror!void {
        switch (expr.*) {
            .nil_lit, .bool_lit, .number, .string, .vararg, .name => {},
            .paren => |e| try self.walkExpr(e.expr, fn_start),
            .index => |e| {
                try self.walkExpr(e.object, fn_start);
                try self.walkExpr(e.key, fn_start);
            },
            .call => |e| {
                try self.emitCall(expr, e.callee, e.args, fn_start);
                try self.walkExpr(e.callee, fn_start);
                for (e.args) |a| try self.walkExpr(a, fn_start);
            },
            .method_call => |e| {
                try self.emitMethodCall(expr, e.object, e.method, e.args, fn_start);
                try self.walkExpr(e.object, fn_start);
                for (e.args) |a| try self.walkExpr(a, fn_start);
            },
            .function => |f| {
                const name = label orelse "<anonymous>";
                try self.function(name, f);
                var shadows: ShadowMap = .empty;
                defer shadows.deinit(std.heap.smp_allocator);
                for (f.params) |param| try shadows.put(std.heap.smp_allocator, param, {});
                try collectLocalNames(f.body, &shadows);
                var frame = ShadowFrame{ .map = &shadows, .parent = self.current_shadows };
                const previous = self.current_shadows;
                self.current_shadows = &frame;
                defer self.current_shadows = previous;
                try self.walkBlock(f.body, f.span.start);
            },
            .table => |e| for (e.fields) |field| switch (field) {
                .list => |v| try self.walkExpr(v, fn_start),
                .named => |v| {
                    if (v.value.* == .function) try self.walkExprLabeled(v.value, fn_start, v.name) else try self.walkExpr(v.value, fn_start);
                },
                .keyed => |v| {
                    try self.walkExpr(v.key, fn_start);
                    try self.walkExpr(v.value, fn_start);
                },
            },
            .unary => |e| try self.walkExpr(e.expr, fn_start),
            .binary => |e| {
                try self.walkExpr(e.lhs, fn_start);
                try self.walkExpr(e.rhs, fn_start);
            },
        }
    }

    fn emitCall(self: *Analyzer, whole: *const lua.Expr, callee: *const lua.Expr, args: []const *lua.Expr, fn_start: u32) !void {
        const name = try self.exprName(callee);
        defer if (name) |x| self.freeMaybe(x);
        if (name) |n| {
            try self.row("C", fn_start, whole.span(), n, null);
            if ((std.mem.eql(u8, n, "require") or std.mem.eql(u8, n, "mw.loadData")) and args.len > 0) {
                if (try self.moduleStringAlloc(args[0])) |module| {
                    defer std.heap.smp_allocator.free(module);
                    try self.row(if (std.mem.eql(u8, n, "require")) "R" else "D", fn_start, whole.span(), module, null);
                } else {
                    try self.row(if (std.mem.eql(u8, n, "require")) "r" else "d", fn_start, whole.span(), "<dynamic>", null);
                }
            }
        } else {
            try self.row("C", fn_start, whole.span(), "<dynamic>", null);
        }
    }

    fn emitMethodCall(self: *Analyzer, whole: *const lua.Expr, object: *const lua.Expr, method: []const u8, _: []const *lua.Expr, fn_start: u32) !void {
        const base = try self.exprName(object);
        defer if (base) |x| self.freeMaybe(x);
        if (base) |b| {
            const name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}", .{ b, method });
            defer std.heap.page_allocator.free(name);
            try self.row("C", fn_start, whole.span(), name, null);
        } else try self.row("C", fn_start, whole.span(), "<dynamic-method>", null);
    }

    fn function(self: *Analyzer, name: []const u8, f: lua.FunctionExpr) !void {
        try self.writer.print("F\t{s}\t{d}\t{d}\t", .{ self.page_id, f.span.start, f.span.end });
        try writeEscaped(self.writer, name);
        try self.writer.print("\t{}\t", .{f.is_vararg});
        for (f.params, 0..) |p, i| {
            if (i != 0) try self.writer.writeByte(',');
            try self.writer.writeAll(p);
        }
        try self.writer.writeByte('\n');
    }

    fn branch(self: *Analyzer, kind: []const u8, stmt_span: lua.Span, cond_span: lua.Span, fn_start: u32) !void {
        try self.writer.print("B\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ self.page_id, fn_start, stmt_span.start, stmt_span.end, cond_span.start, cond_span.end, kind });
    }

    fn row(self: *Analyzer, kind: []const u8, fn_start: u32, span: lua.Span, text: []const u8, extra: ?[]const u8) !void {
        try self.writer.print("{s}\t{s}\t{d}\t{d}\t{d}\t", .{ kind, self.page_id, fn_start, span.start, span.end });
        try writeEscaped(self.writer, text);
        if (extra) |e| {
            try self.writer.writeByte('\t');
            try writeEscaped(self.writer, e);
        }
        try self.writer.writeByte('\n');
    }

    fn exprName(self: *Analyzer, expr: *const lua.Expr) !?[]const u8 {
        return switch (expr.*) {
            .name => |n| try std.heap.page_allocator.dupe(u8, n.value),
            .paren => |pval| try self.exprName(pval.expr),
            .index => |i| blk: {
                const key = stringValue(i.key) orelse break :blk null;
                const base = try self.exprName(i.object) orelse break :blk null;
                defer std.heap.page_allocator.free(base);
                break :blk try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}", .{ base, key });
            },
            else => null,
        };
    }

    fn lvalueName(self: *Analyzer, lv: lua.LValue) !?[]const u8 {
        return switch (lv) {
            .name => |n| try std.heap.page_allocator.dupe(u8, n),
            .index => |i| blk: {
                const key = stringValue(i.key) orelse break :blk null;
                const base = try self.exprName(i.object) orelse break :blk null;
                defer std.heap.page_allocator.free(base);
                break :blk try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}", .{ base, key });
            },
        };
    }

    fn collectModuleConstants(self: *Analyzer, body: lua.Block) !void {
        var writes: std.StringHashMapUnmanaged(u32) = .empty;
        defer writes.deinit(std.heap.smp_allocator);
        try collectWriteCounts(body, &writes);
        for (body) |stmt| switch (stmt.*) {
            .local_assign => |assign| {
                for (assign.names, 0..) |name, i| {
                    if (i >= assign.values.len) continue;
                    const value = stringValue(assign.values[i]) orelse continue;
                    if ((writes.get(name) orelse 0) == 1)
                        try self.string_constants.put(std.heap.smp_allocator, name, value);
                }
            },
            .assign => |assign| {
                for (assign.targets, 0..) |target, i| {
                    if (i >= assign.values.len) continue;
                    const value = stringValue(assign.values[i]) orelse continue;
                    const path = try lvalueStaticPathAlloc(target) orelse continue;
                    defer std.heap.smp_allocator.free(path);
                    if ((writes.get(path) orelse 0) == 1) {
                        const key = try std.heap.smp_allocator.dupe(u8, path);
                        try self.string_constants.put(std.heap.smp_allocator, key, value);
                    }
                }
            },
            else => {},
        };
    }

    fn isShadowed(self: *Analyzer, name: []const u8) bool {
        var frame = self.current_shadows;
        while (frame) |f| {
            if (f.map.contains(name)) return true;
            frame = f.parent;
        }
        return false;
    }

    fn moduleStringAlloc(self: *Analyzer, expr: *const lua.Expr) !?[]u8 {
        return switch (expr.*) {
            .string => |value| try std.heap.smp_allocator.dupe(u8, value.value),
            .paren => |pval| try self.moduleStringAlloc(pval.expr),
            .name => |name| blk: {
                if (self.isShadowed(name.value)) break :blk null;
                const value = self.string_constants.get(name.value) orelse break :blk null;
                break :blk try std.heap.smp_allocator.dupe(u8, value);
            },
            .index => blk: {
                const path = try self.exprName(expr) orelse break :blk null;
                defer self.freeMaybe(path);
                const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
                if (self.isShadowed(path[0..root_end])) break :blk null;
                const value = self.string_constants.get(path) orelse break :blk null;
                break :blk try std.heap.smp_allocator.dupe(u8, value);
            },
            .binary => |bin| blk: {
                if (bin.op != .concat) break :blk null;
                const lhs = try self.moduleStringAlloc(bin.lhs) orelse break :blk null;
                defer std.heap.smp_allocator.free(lhs);
                const rhs = try self.moduleStringAlloc(bin.rhs) orelse break :blk null;
                defer std.heap.smp_allocator.free(rhs);
                break :blk try std.mem.concat(std.heap.smp_allocator, u8, &.{ lhs, rhs });
            },
            else => null,
        };
    }

    fn freeMaybe(_: *Analyzer, s: []const u8) void {
        std.heap.page_allocator.free(@constCast(s));
    }
};

fn exprStaticPathAlloc(expr: *const lua.Expr) !?[]u8 {
    return switch (expr.*) {
        .name => |n| try std.heap.smp_allocator.dupe(u8, n.value),
        .paren => |pval| try exprStaticPathAlloc(pval.expr),
        .index => |idx| blk: {
            const key = stringValue(idx.key) orelse break :blk null;
            const base = try exprStaticPathAlloc(idx.object) orelse break :blk null;
            defer std.heap.smp_allocator.free(base);
            break :blk try std.fmt.allocPrint(std.heap.smp_allocator, "{s}.{s}", .{ base, key });
        },
        else => null,
    };
}

fn lvalueStaticPathAlloc(lv: lua.LValue) !?[]u8 {
    return switch (lv) {
        .name => |name| try std.heap.smp_allocator.dupe(u8, name),
        .index => |idx| blk: {
            const key = stringValue(idx.key) orelse break :blk null;
            const base = try exprStaticPathAlloc(idx.object) orelse break :blk null;
            defer std.heap.smp_allocator.free(base);
            break :blk try std.fmt.allocPrint(std.heap.smp_allocator, "{s}.{s}", .{ base, key });
        },
    };
}

fn bumpLValueWrite(map: *std.StringHashMapUnmanaged(u32), target: lua.LValue) !void {
    const path = try lvalueStaticPathAlloc(target) orelse return;
    defer std.heap.smp_allocator.free(path);
    if (map.getPtr(path)) |count| {
        count.* += 1;
        return;
    }
    try map.put(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, path), 1);
}

fn bumpWrite(map: *std.StringHashMapUnmanaged(u32), name: []const u8) !void {
    const gop = try map.getOrPut(std.heap.smp_allocator, name);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

fn collectWriteCounts(block: lua.Block, out: *std.StringHashMapUnmanaged(u32)) anyerror!void {
    for (block) |stmt| switch (stmt.*) {
        .assign => |s| for (s.targets) |target| try bumpLValueWrite(out, target),
        .local_assign => |s| for (s.names) |name| try bumpWrite(out, name),
        .local_function => |s| {
            try bumpWrite(out, s.name);
            try collectWriteCounts(s.function.function.body, out);
        },
        .function_assign => |s| {
            try bumpLValueWrite(out, s.target);
            try collectWriteCounts(s.function.function.body, out);
        },
        .do_block => |s| try collectWriteCounts(s.body, out),
        .while_loop => |s| try collectWriteCounts(s.body, out),
        .repeat_loop => |s| try collectWriteCounts(s.body, out),
        .if_stmt => |s| {
            for (s.branches) |b| try collectWriteCounts(b.body, out);
            if (s.else_body) |b| try collectWriteCounts(b, out);
        },
        .numeric_for => |s| {
            try bumpWrite(out, s.name);
            try collectWriteCounts(s.body, out);
        },
        .generic_for => |s| {
            for (s.names) |name| try bumpWrite(out, name);
            try collectWriteCounts(s.body, out);
        },
        .call, .return_stmt, .empty, .break_stmt => {},
    };
}

fn collectLocalNames(block: lua.Block, out: *ShadowMap) anyerror!void {
    for (block) |stmt| switch (stmt.*) {
        .local_assign => |s| for (s.names) |name| try out.put(std.heap.smp_allocator, name, {}),
        .local_function => |s| try out.put(std.heap.smp_allocator, s.name, {}),
        .do_block => |s| try collectLocalNames(s.body, out),
        .while_loop => |s| try collectLocalNames(s.body, out),
        .repeat_loop => |s| try collectLocalNames(s.body, out),
        .if_stmt => |s| {
            for (s.branches) |b| try collectLocalNames(b.body, out);
            if (s.else_body) |b| try collectLocalNames(b, out);
        },
        .numeric_for => |s| {
            try out.put(std.heap.smp_allocator, s.name, {});
            try collectLocalNames(s.body, out);
        },
        .generic_for => |s| {
            for (s.names) |name| try out.put(std.heap.smp_allocator, name, {});
            try collectLocalNames(s.body, out);
        },
        .assign, .function_assign, .call, .return_stmt, .empty, .break_stmt => {},
    };
}

fn stringValue(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |sval| sval.value,
        .paren => |pval| stringValue(pval.expr),
        else => null,
    };
}
fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

fn pageId(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".lua")) return null;
    const stem = name[0 .. name.len - 4];
    for (stem) |c| if (c < '0' or c > '9') return null;
    return stem;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const base = if (args.len >= 2) args[1] else ".zig-cache/wiktionary-lua-2026-04-01/modules";
    var dir = try std.Io.Dir.cwd().openDir(init.io, base, .{ .iterate = true });
    defer dir.close(init.io);
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const w = &stdout.interface;
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const id = pageId(entry.name) orelse continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, entry.name });
        defer arena.free(path);
        var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
        defer file.close(init.io);
        const stat = try file.stat(init.io);
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const source = try arena.alloc(u8, len);
        defer arena.free(source);
        _ = try file.readPositionalAll(init.io, source, 0);
        var chunk = try lua.parse(arena, source);
        defer chunk.deinit();
        var a = Analyzer{ .source = chunk.source, .writer = w, .page_id = id };
        defer a.deinit();
        try a.run(chunk.body);
        count += 1;
        if (count % 1000 == 0) try w.flush();
    }
    try w.flush();
}
