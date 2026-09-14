const std = @import("std");
const lua = @import("../parser/root.zig");

pub const ModuleExport = struct { module: []const u8, name: []const u8 };
pub const Binding = union(enum) {
    unknown,
    function: u32,
    module: []const u8,
    module_export: ModuleExport,
    table: *TableInfo,
};
pub const TableInfo = struct {
    fields: std.StringHashMapUnmanaged(Binding) = .empty,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    env: std.StringHashMapUnmanaged(Binding) = .empty,
    return_binding: Binding = .unknown,
    functions: std.AutoHashMapUnmanaged(u32, *const lua.Expr) = .empty,
    dynamic_top_level: bool = false,
    owned_tables: std.ArrayList(*TableInfo) = .empty,

    pub fn deinit(self: *Builder) void {
        for (self.owned_tables.items) |table| {
            table.fields.deinit(self.allocator);
            self.allocator.destroy(table);
        }
        self.owned_tables.deinit(self.allocator);
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

    fn topStmt(self: *Builder, stmt: *const lua.Stmt) !void {
        switch (stmt.*) {
            .local_assign => |s| {
                for (s.names, 0..) |name, i| {
                    const value = if (i < s.values.len) try self.eval(s.values[i]) else Binding.unknown;
                    try self.env.put(self.allocator, name, value);
                }
            },
            .assign => |s| {
                for (s.targets, 0..) |target, i| {
                    const value = if (i < s.values.len) try self.eval(s.values[i]) else Binding.unknown;
                    try self.assign(target, value);
                }
            },
            .local_function => |s| try self.env.put(self.allocator, s.name, .{ .function = s.function.function.span.start }),
            .function_assign => |s| try self.assign(s.target, .{ .function = s.function.function.span.start }),
            .return_stmt => |s| if (s.values.len != 0) {
                self.return_binding = try self.eval(s.values[0]);
            },
            .call => {},
            .empty => {},
            // `do ... end` is unconditional. Evaluate it in an isolated lexical
            // environment so table mutations (notably export.foo assignments) are
            // visible while block-local names do not escape. Keep the dynamic bit
            // conservative because scalar outer-variable writes are not modeled.
            .do_block => |s| {
                self.dynamic_top_level = true;
                try self.topScopedBlock(s.body);
            },
            // Runtime-dependent top-level control flow is not guessed.
            .while_loop, .repeat_loop, .if_stmt, .numeric_for, .generic_for, .break_stmt => self.dynamic_top_level = true,
        }
    }

    fn eval(self: *Builder, expr: *const lua.Expr) anyerror!Binding {
        return switch (expr.*) {
            .name => |n| self.env.get(n.value) orelse .unknown,
            .function => |f| .{ .function = f.span.start },
            .table => |t| try self.evalTable(t.fields),
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

    fn evalTable(self: *Builder, fields: []const lua.TableField) anyerror!Binding {
        const table = try self.allocator.create(TableInfo);
        table.* = .{};
        self.owned_tables.append(self.allocator, table) catch |err| {
            self.allocator.destroy(table);
            return err;
        };
        for (fields) |field| switch (field) {
            .named => |v| try table.fields.put(self.allocator, v.name, try self.eval(v.value)),
            .keyed => |v| if (stringConst(v.key)) |key| try table.fields.put(self.allocator, key, try self.eval(v.value)),
            .list => {},
        };
        return .{ .table = table };
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

fn stringConst(expr: *const lua.Expr) ?[]const u8 {
    return switch (expr.*) {
        .string => |s| s.value,
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
