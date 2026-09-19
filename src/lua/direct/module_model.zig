const std = @import("std");
const lua = @import("../parser/root.zig");

pub const ModuleExport = struct { module: []const u8, name: []const u8 };
pub const Binding = union(enum) {
    unknown,
    literal: *const lua.Expr,
    function: u32,
    module: []const u8,
    module_export: ModuleExport,
    table: *TableInfo,
};
pub const TableInfo = struct {
    span_start: u32,
    fields: std.StringHashMapUnmanaged(Binding) = .empty,
    shape_eligible: bool = true,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    env: std.StringHashMapUnmanaged(Binding) = .empty,
    return_binding: Binding = .unknown,
    functions: std.AutoHashMapUnmanaged(u32, *const lua.Expr) = .empty,
    dynamic_top_level: bool = false,
    root_pure: bool = true,
    root_bootstrap_safe: bool = true,
    root_requires: std.ArrayList([]const u8) = .empty,
    owned_tables: std.ArrayList(*TableInfo) = .empty,

    pub fn deinit(self: *Builder) void {
        for (self.owned_tables.items) |table| {
            table.fields.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.owned_tables.deinit(self.allocator);
        self.root_requires.deinit(self.allocator);
        self.env.deinit(self.allocator);
        self.functions.deinit(self.allocator);
    }

    pub fn build(self: *Builder, body: lua.Block) !void {
        try self.collectFunctions(body);
        for (body) |stmt| try self.topStmt(stmt);
    }

    fn collectFunctions(self: *Builder, block: lua.Block) anyerror!void {
        for (block) |stmt| switch (stmt.*) {
            .local_function => |s| {
                try self.functions.put(self.allocator, s.function.function.span.start, s.function);
                try self.collectFunctions(s.function.function.body);
            },
            .function_assign => |s| {
                try self.functions.put(self.allocator, s.function.function.span.start, s.function);
                try self.collectFunctions(s.function.function.body);
            },
            .local_assign => |s| for (s.values) |v| try self.collectExprFunctions(v),
            .assign => |s| for (s.values) |v| try self.collectExprFunctions(v),
            .call => |s| try self.collectExprFunctions(s.expr),
            .do_block => |s| try self.collectFunctions(s.body),
            .while_loop => |s| {
                try self.collectExprFunctions(s.cond);
                try self.collectFunctions(s.body);
            },
            .repeat_loop => |s| {
                try self.collectFunctions(s.body);
                try self.collectExprFunctions(s.cond);
            },
            .if_stmt => |s| {
                for (s.branches) |b| {
                    try self.collectExprFunctions(b.cond);
                    try self.collectFunctions(b.body);
                }
                if (s.else_body) |b| try self.collectFunctions(b);
            },
            .numeric_for => |s| {
                try self.collectExprFunctions(s.start);
                try self.collectExprFunctions(s.limit);
                if (s.step) |v| try self.collectExprFunctions(v);
                try self.collectFunctions(s.body);
            },
            .generic_for => |s| {
                for (s.values) |v| try self.collectExprFunctions(v);
                try self.collectFunctions(s.body);
            },
            .return_stmt => |s| for (s.values) |v| try self.collectExprFunctions(v),
            .empty, .break_stmt => {},
        };
    }

    fn collectExprFunctions(self: *Builder, expr: *const lua.Expr) anyerror!void {
        switch (expr.*) {
            .function => |f| {
                try self.functions.put(self.allocator, f.span.start, expr);
                try self.collectFunctions(f.body);
            },
            .index => |e| {
                try self.collectExprFunctions(e.object);
                try self.collectExprFunctions(e.key);
            },
            .call => |e| {
                try self.collectExprFunctions(e.callee);
                for (e.args) |a| try self.collectExprFunctions(a);
            },
            .method_call => |e| {
                try self.collectExprFunctions(e.object);
                for (e.args) |a| try self.collectExprFunctions(a);
            },
            .table => |e| for (e.fields) |field| switch (field) {
                .list => |v| try self.collectExprFunctions(v),
                .named => |v| try self.collectExprFunctions(v.value),
                .keyed => |v| {
                    try self.collectExprFunctions(v.key);
                    try self.collectExprFunctions(v.value);
                },
            },
            .unary => |e| try self.collectExprFunctions(e.expr),
            .binary => |e| {
                try self.collectExprFunctions(e.lhs);
                try self.collectExprFunctions(e.rhs);
            },
            else => {},
        }
    }

    fn topScopedBlock(self: *Builder, block: lua.Block) anyerror!void {
        var saved = try self.env.clone(self.allocator);
        errdefer saved.deinit(self.allocator);
        for (block) |stmt| try self.topStmt(stmt);
        self.env.deinit(self.allocator);
        self.env = saved;
    }

    fn rootRequire(self: *Builder, expr: *const lua.Expr) ?[]const u8 {
        if (expr.* != .call) return null;
        const call = expr.call;
        if (call.callee.* != .name or
            !std.mem.eql(u8, call.callee.name.value, "require") or
            self.env.contains("require") or
            call.args.len != 1)
            return null;
        return stringConst(call.args[0]);
    }

    fn exprBootstrapSafe(self: *Builder, expr: *const lua.Expr) anyerror!bool {
        if (self.rootRequire(expr)) |target| {
            try self.root_requires.append(self.allocator, target);
            return true;
        }
        return switch (expr.*) {
            .nil_lit, .bool_lit, .number, .string, .function => true,
            .name => |name| self.env.contains(name.value),
            .paren => |value| self.exprBootstrapSafe(value.expr),
            .table => |value| blk: {
                for (value.fields) |field| switch (field) {
                    .list => |item| if (!try self.exprBootstrapSafe(item)) break :blk false,
                    .named => |item| if (!try self.exprBootstrapSafe(item.value)) break :blk false,
                    .keyed => |item| if (!try self.exprBootstrapSafe(item.key) or
                        !try self.exprBootstrapSafe(item.value)) break :blk false,
                };
                break :blk true;
            },
            .index, .call, .method_call, .unary, .binary, .vararg => false,
        };
    }

    fn exprPure(self: *Builder, expr: *const lua.Expr) bool {
        return switch (expr.*) {
            .nil_lit, .bool_lit, .number, .string, .function => true,
            .name => |name| self.env.contains(name.value),
            .paren => |value| self.exprPure(value.expr),
            .table => |value| blk: {
                for (value.fields) |field| switch (field) {
                    .list => |item| if (!self.exprPure(item)) break :blk false,
                    .named => |item| if (!self.exprPure(item.value)) break :blk false,
                    .keyed => |item| if (!self.exprPure(item.key) or !self.exprPure(item.value)) break :blk false,
                };
                break :blk true;
            },
            // Indexing, arithmetic/comparison, and calls can invoke metamethods or
            // module/host code. Do not reorder them across program initialization.
            .index, .call, .method_call, .unary, .binary, .vararg => false,
        };
    }

    fn targetPure(self: *Builder, target: lua.LValue) bool {
        return switch (target) {
            .name => |name| self.env.contains(name),
            .index => |idx| blk: {
                const object = self.eval(idx.object) catch break :blk false;
                if (object != .table or stringConst(idx.key) == null) break :blk false;
                break :blk true;
            },
        };
    }

    fn topStmt(self: *Builder, stmt: *const lua.Stmt) !void {
        switch (stmt.*) {
            .local_assign => |s| {
                for (s.values) |value| {
                    if (!self.exprPure(value)) self.root_pure = false;
                    if (!try self.exprBootstrapSafe(value)) self.root_bootstrap_safe = false;
                }
                for (s.names, 0..) |name, i| {
                    const value = if (i < s.values.len) try self.eval(s.values[i]) else Binding.unknown;
                    try self.env.put(self.allocator, name, value);
                }
            },
            .assign => |s| {
                for (s.values) |value| {
                    if (!self.exprPure(value)) self.root_pure = false;
                    if (!try self.exprBootstrapSafe(value)) self.root_bootstrap_safe = false;
                }
                for (s.targets, 0..) |target, i| {
                    if (!self.targetPure(target)) {
                        self.root_pure = false;
                        self.root_bootstrap_safe = false;
                    }
                    const value = if (i < s.values.len) try self.eval(s.values[i]) else Binding.unknown;
                    try self.assign(target, value);
                }
            },
            .local_function => |s| try self.env.put(self.allocator, s.name, .{ .function = s.function.function.span.start }),
            .function_assign => |s| {
                if (!self.targetPure(s.target)) {
                    self.root_pure = false;
                    self.root_bootstrap_safe = false;
                }
                try self.assign(s.target, .{ .function = s.function.function.span.start });
            },
            .return_stmt => |s| {
                for (s.values) |value| {
                    if (!self.exprPure(value)) self.root_pure = false;
                    if (!try self.exprBootstrapSafe(value)) self.root_bootstrap_safe = false;
                }
                if (s.values.len != 0) self.return_binding = try self.eval(s.values[0]);
            },
            .call => |call_stmt| {
                self.root_pure = false;
                if (!try self.exprBootstrapSafe(call_stmt.expr))
                    self.root_bootstrap_safe = false;
            },
            .empty => {},
            .do_block => |s| {
                // Preserve the conservative shape-analysis bit, but an
                // unconditional lexical block can still be side-effect-free.
                self.dynamic_top_level = true;
                try self.topScopedBlock(s.body);
            },
            // Runtime-dependent control flow is not reordered during bootstrap.
            .while_loop, .repeat_loop, .if_stmt, .numeric_for, .generic_for, .break_stmt => {
                self.dynamic_top_level = true;
                self.root_pure = false;
                self.root_bootstrap_safe = false;
            },
        }
    }

    fn eval(self: *Builder, expr: *const lua.Expr) anyerror!Binding {
        return switch (expr.*) {
            .nil_lit, .bool_lit, .number, .string => .{ .literal = expr },
            .name => |n| self.env.get(n.value) orelse .unknown,
            .paren => |p| if (literalExpr(expr)) .{ .literal = expr } else try self.eval(p.expr),
            .function => |f| .{ .function = f.span.start },
            .table => |t| try self.evalTable(t.span.start, t.fields),
            .index => |e| blk: {
                const object = try self.eval(e.object);
                const key = stringConst(e.key) orelse break :blk .unknown;
                break :blk switch (object) {
                    .table => |table| table.fields.get(key) orelse .unknown,
                    .module => |module| .{ .module_export = .{ .module = module, .name = key } },
                    else => .unknown,
                };
            },
            .call => |c| blk: {
                const callee_name = exprPath(c.callee);
                if (callee_name) |name| {
                    if (std.mem.eql(u8, name, "require") and c.args.len != 0) {
                        if (stringConst(c.args[0])) |module| break :blk .{ .module = module };
                    }
                    if (std.mem.eql(u8, name, "mw.loadData") and c.args.len != 0) {
                        if (stringConst(c.args[0])) |module| break :blk .{ .module = module };
                    }
                    if (std.mem.eql(u8, name, "setmetatable") and c.args.len != 0) break :blk try self.eval(c.args[0]);
                }
                break :blk .unknown;
            },
            else => .unknown,
        };
    }

    fn evalTable(self: *Builder, span_start: u32, fields: []const lua.TableField) anyerror!Binding {
        const table = try self.allocator.create(TableInfo);
        table.* = .{ .span_start = span_start };
        self.owned_tables.append(self.allocator, table) catch |err| {
            self.allocator.destroy(table);
            return err;
        };
        for (fields) |field| switch (field) {
            .named => |v| try table.fields.put(self.allocator, v.name, try self.evalField(v.value)),
            .keyed => |v| {
                if (stringConst(v.key)) |key|
                    try table.fields.put(self.allocator, key, try self.evalField(v.value))
                else
                    table.shape_eligible = false;
            },
            .list => table.shape_eligible = false,
        };
        return .{ .table = table };
    }

    fn evalField(self: *Builder, expr: *const lua.Expr) anyerror!Binding {
        if (literalExpr(expr)) return .{ .literal = expr };
        return self.eval(expr);
    }

    fn assign(self: *Builder, target: lua.LValue, value: Binding) !void {
        switch (target) {
            .name => |name| try self.env.put(self.allocator, name, value),
            .index => |idx| {
                const object = try self.eval(idx.object);
                const key = stringConst(idx.key) orelse {
                    self.dynamic_top_level = true;
                    return;
                };
                if (object == .table) try object.table.fields.put(self.allocator, key, value) else self.dynamic_top_level = true;
            },
        }
    }
};

fn literalExpr(expr: *const lua.Expr) bool {
    return switch (expr.*) {
        .nil_lit, .bool_lit, .number, .string => true,
        .paren => |p| literalExpr(p.expr),
        .table => |table| blk: {
            for (table.fields) |field| switch (field) {
                .list => |item| if (!literalExpr(item)) break :blk false,
                .named => |item| if (!literalExpr(item.value)) break :blk false,
                .keyed => |item| if (!literalExpr(item.key) or !literalExpr(item.value)) break :blk false,
            };
            break :blk true;
        },
        else => false,
    };
}

fn stringConst(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |s| s.value,
        .paren => |p| stringConst(p.expr),
        else => null,
    };
}

fn exprPath(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .name => |n| n.value,
        // Only the two globals needed during top-level modeling are recognized
        // without allocating a synthesized path.
        .index => |i| blk: {
            const key = stringConst(i.key) orelse break :blk null;
            if (i.object.* == .name and std.mem.eql(u8, i.object.name.value, "mw") and std.mem.eql(u8, key, "loadData")) break :blk "mw.loadData";
            break :blk null;
        },
        else => null,
    };
}

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const b = try a.alloc(u8, n);
    _ = try f.readPositionalAll(io, b, 0);
    return b;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.MissingInput;
    const source = try readAll(init.io, a, args[1]);
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var b = Builder{ .allocator = a, .source = chunk.source };
    defer b.deinit();
    try b.build(chunk.body);

    std.debug.print("functions={d} dynamic_top_level={} return={s}\n", .{ b.functions.count(), b.dynamic_top_level, @tagName(b.return_binding) });
    switch (b.return_binding) {
        .table => |table| {
            var it = table.fields.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.*) {
                .function => |id| std.debug.print("export\t{s}\tfn:{d}\n", .{ entry.key_ptr.*, id }),
                .module_export => |m| std.debug.print("export\t{s}\tmodule:{s}.{s}\n", .{ entry.key_ptr.*, m.module, m.name }),
                else => {},
            };
        },
        .module => |m| std.debug.print("proxy-module\t{s}\n", .{m}),
        else => {},
    }
}
