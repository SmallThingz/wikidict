const std = @import("std");
const lua = @import("../parser/root.zig");

pub const Fact = struct {
    id: u32,
    fields: []const []const u8,
};

pub const ModuleFacts = std.AutoHashMapUnmanaged(u32, Fact);

const Record = struct {
    module_index: u32,
    span_start: u32,
    fields: []const []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        for (self.records.items) |entry| {
            for (entry.fields) |field| self.allocator.free(field);
            self.allocator.free(entry.fields);
        }
        self.records.deinit(self.allocator);
    }

    pub fn count(self: *const Registry) usize {
        return self.records.items.len;
    }

    pub fn fieldCount(self: *const Registry) usize {
        var total: usize = 0;
        for (self.records.items) |entry| total += entry.fields.len;
        return total;
    }

    pub fn collectRootExpr(self: *Registry, module_index: u32, value: *const lua.Expr) !?u32 {
        return switch (value.*) {
            .paren => |paren| self.collectRootExpr(module_index, paren.expr),
            .table => |table| blk: {
                const before = self.records.items.len;
                try self.maybeTable(module_index, table.span, table.fields);
                break :blk if (self.records.items.len != before) @as(u32, @intCast(before)) else null;
            },
            else => null,
        };
    }

    pub fn record(self: *const Registry, id: u32) Fact {
        const value = self.records.items[id];
        return .{ .id = id, .fields = value.fields };
    }

    pub fn moduleFacts(self: *const Registry, allocator: std.mem.Allocator, module_index: u32) !ModuleFacts {
        var out: ModuleFacts = .empty;
        errdefer out.deinit(allocator);
        for (self.records.items, 0..) |record_value, id| {
            if (record_value.module_index != module_index) continue;
            try out.put(allocator, record_value.span_start, .{ .id = @intCast(id), .fields = record_value.fields });
        }
        return out;
    }
    fn copyFields(self: *Registry, field_names: []const []const u8) ![]const []const u8 {
        const owned = try self.allocator.alloc([]const u8, field_names.len);
        errdefer self.allocator.free(owned);
        var copied: usize = 0;
        errdefer for (owned[0..copied]) |name| self.allocator.free(name);
        for (field_names, 0..) |name, index| {
            owned[index] = try self.allocator.dupe(u8, name);
            copied += 1;
        }
        return owned;
    }

    fn freeFields(self: *Registry, fields: []const []const u8) void {
        for (fields) |field| self.allocator.free(field);
        self.allocator.free(fields);
    }

    pub fn promote(self: *Registry, module_index: u32, span_start: u32, field_names: []const []const u8) !?u32 {
        if (field_names.len == 0) return null;
        const replacement = try self.copyFields(field_names);
        errdefer self.freeFields(replacement);
        for (self.records.items, 0..) |*record_value, id| {
            if (record_value.module_index != module_index or record_value.span_start != span_start) continue;
            self.freeFields(record_value.fields);
            record_value.fields = replacement;
            return @intCast(id);
        }
        if (self.records.items.len >= std.math.maxInt(u32)) return error.TooManyShapes;
        const id: u32 = @intCast(self.records.items.len);
        try self.records.append(self.allocator, .{ .module_index = module_index, .span_start = span_start, .fields = replacement });
        return id;
    }

    pub fn collect(self: *Registry, module_index: u32, body: lua.Block) !void {
        for (body) |stmt| try self.statement(module_index, stmt);
    }

    fn statement(self: *Registry, module_index: u32, stmt: *const lua.Stmt) anyerror!void {
        switch (stmt.*) {
            .assign => |s| for (s.values) |value| try self.expr(module_index, value),
            .local_assign => |s| for (s.values) |value| try self.expr(module_index, value),
            .call => |s| try self.expr(module_index, s.expr),
            .do_block => |s| try self.collect(module_index, s.body),
            .while_loop => |s| {
                try self.expr(module_index, s.cond);
                try self.collect(module_index, s.body);
            },
            .repeat_loop => |s| {
                try self.collect(module_index, s.body);
                try self.expr(module_index, s.cond);
            },
            .if_stmt => |s| {
                for (s.branches) |branch| {
                    try self.expr(module_index, branch.cond);
                    try self.collect(module_index, branch.body);
                }
                if (s.else_body) |body| try self.collect(module_index, body);
            },
            .numeric_for => |s| {
                try self.expr(module_index, s.start);
                try self.expr(module_index, s.limit);
                if (s.step) |step| try self.expr(module_index, step);
                try self.collect(module_index, s.body);
            },
            .generic_for => |s| {
                for (s.values) |value| try self.expr(module_index, value);
                try self.collect(module_index, s.body);
            },
            .function_assign => |s| try self.expr(module_index, s.function),
            .local_function => |s| try self.expr(module_index, s.function),
            .return_stmt => |s| for (s.values) |value| try self.expr(module_index, value),
            .empty, .break_stmt => {},
        }
    }

    fn expr(self: *Registry, module_index: u32, value: *const lua.Expr) anyerror!void {
        switch (value.*) {
            .paren => |v| try self.expr(module_index, v.expr),
            .index => |v| {
                try self.expr(module_index, v.object);
                try self.expr(module_index, v.key);
            },
            .call => |v| {
                try self.expr(module_index, v.callee);
                for (v.args) |arg| try self.expr(module_index, arg);
            },
            .method_call => |v| {
                try self.expr(module_index, v.object);
                for (v.args) |arg| try self.expr(module_index, arg);
            },
            .function => |v| try self.collect(module_index, v.body),
            .table => |v| {
                try self.maybeTable(module_index, v.span, v.fields);
                for (v.fields) |field| switch (field) {
                    .list => |item| try self.expr(module_index, item),
                    .named => |item| try self.expr(module_index, item.value),
                    .keyed => |item| {
                        try self.expr(module_index, item.key);
                        try self.expr(module_index, item.value);
                    },
                };
            },
            .unary => |v| try self.expr(module_index, v.expr),
            .binary => |v| {
                try self.expr(module_index, v.lhs);
                try self.expr(module_index, v.rhs);
            },
            else => {},
        }
    }
    fn maybeTable(self: *Registry, module_index: u32, span: lua.Span, fields: []const lua.TableField) !void {
        if (fields.len == 0) return;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (fields) |field| {
            const name = switch (field) {
                .named => |item| item.name,
                .keyed => |item| staticString(item.key) orelse return,
                .list => return,
            };
            var duplicate = false;
            for (names.items) |existing| if (std.mem.eql(u8, existing, name)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try names.append(self.allocator, name);
        }
        if (names.items.len == 0) return;
        if (names.items.len > std.math.maxInt(u32)) return error.TooManyShapeFields;
        if (self.records.items.len >= std.math.maxInt(u32)) return error.TooManyShapes;

        const owned = try self.copyFields(names.items);
        errdefer self.freeFields(owned);
        try self.records.append(self.allocator, .{ .module_index = module_index, .span_start = span.start, .fields = owned });
    }
};

fn staticString(value: *const lua.Expr) ?[]const u8 {
    return switch (value.*) {
        .string => |v| v.value,
        .paren => |v| staticString(v.expr),
        else => null,
    };
}

test "static root shape collection keeps only top-level table" {
    var chunk = try lua.parse(std.testing.allocator, "return { top = 1, nested = { a = 2, b = 3 } }");
    defer chunk.deinit();
    const root = chunk.body[0].return_stmt.values[0];
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const id = try registry.collectRootExpr(0, root);
    try std.testing.expectEqual(@as(?u32, 0), id);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(@as(usize, 2), registry.fieldCount());
    var facts = try registry.moduleFacts(std.testing.allocator, 0);
    defer facts.deinit(std.testing.allocator);
    try std.testing.expect(facts.get(root.table.span.start) != null);
    const nested = root.table.fields[1].named.value;
    try std.testing.expect(nested.* == .table);
    try std.testing.expect(facts.get(nested.table.span.start) == null);
}
