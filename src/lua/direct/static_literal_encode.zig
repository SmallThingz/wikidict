const std = @import("std");
const lua = @import("../parser/root.zig");
const numbers = @import("numbers.zig");
const shapes = @import("shapes.zig");
const format = @import("../runtime/static_literal_format.zig");

const A = std.mem.Allocator;

pub fn isLiteral(expr: *const lua.Expr) bool {
    return switch (expr.*) {
        .nil_lit, .bool_lit, .number, .string => true,
        .paren => |paren| isLiteral(paren.expr),
        .table => |table_expr| isFields(table_expr.fields),
        else => false,
    };
}

pub fn isFields(fields: []const lua.TableField) bool {
    for (fields) |field| switch (field) {
        .list => |item| if (!isLiteral(item)) return false,
        .named => |item| if (!isLiteral(item.value)) return false,
        .keyed => |item| if (!isLiteral(item.key) or !isLiteral(item.value)) return false,
    };
    return true;
}

pub fn rootLiteral(body: lua.Block) ?*const lua.Expr {
    if (body.len != 1 or body[0].* != .return_stmt) return null;
    const values = body[0].return_stmt.values;
    if (values.len != 1 or !isLiteral(values[0])) return null;
    return values[0];
}

const Encoder = struct {
    allocator: A,
    table_shapes: ?*const shapes.ModuleFacts,
    out: std.ArrayList(u8) = .empty,

    fn writeU32(self: *Encoder, value: usize) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, std.math.cast(u32, value) orelse return error.StaticLiteralTooLarge, .little);
        try self.out.appendSlice(self.allocator, &bytes);
    }

    fn writeRawU32(self: *Encoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.out.appendSlice(self.allocator, &bytes);
    }

    fn writeU64(self: *Encoder, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.out.appendSlice(self.allocator, &bytes);
    }

    fn writeString(self: *Encoder, value: []const u8) !void {
        try self.writeU32(value.len);
        try self.out.appendSlice(self.allocator, value);
    }

    fn expr(self: *Encoder, value: *const lua.Expr, depth: usize) anyerror!void {
        if (depth >= format.max_depth) return error.StaticLiteralTooDeep;
        switch (value.*) {
            .nil_lit => try self.out.append(self.allocator, @intFromEnum(format.ValueTag.nil)),
            .bool_lit => |literal| try self.out.append(
                self.allocator,
                @intFromEnum(if (literal.value) format.ValueTag.true_ else format.ValueTag.false_),
            ),
            .number => |literal| {
                try self.out.append(self.allocator, @intFromEnum(format.ValueTag.number));
                try self.writeU64(@bitCast(try numbers.parse(literal.raw)));
            },
            .string => |literal| {
                try self.out.append(self.allocator, @intFromEnum(format.ValueTag.string));
                try self.writeString(literal.value);
            },
            .paren => |paren| try self.expr(paren.expr, depth),
            .table => |table_expr| {
                try self.out.append(self.allocator, @intFromEnum(format.ValueTag.table));
                const shape_id = if (self.table_shapes) |facts|
                    if (facts.get(table_expr.span.start)) |shape| shape.id else format.no_shape
                else
                    format.no_shape;
                try self.writeRawU32(shape_id);
                try self.writeU32(table_expr.fields.len);
                var list_capacity: usize = 0;
                for (table_expr.fields) |field| if (field == .list) {
                    list_capacity += 1;
                };
                try self.writeU32(list_capacity);
                for (table_expr.fields) |field| switch (field) {
                    .list => |item| {
                        try self.out.append(self.allocator, @intFromEnum(format.FieldTag.list));
                        try self.expr(item, depth + 1);
                    },
                    .named => |item| {
                        try self.out.append(self.allocator, @intFromEnum(format.FieldTag.named));
                        try self.writeString(item.name);
                        try self.expr(item.value, depth + 1);
                    },
                    .keyed => |item| {
                        try self.out.append(self.allocator, @intFromEnum(format.FieldTag.keyed));
                        try self.expr(item.key, depth + 1);
                        try self.expr(item.value, depth + 1);
                    },
                };
            },
            else => return error.NonStaticLiteral,
        }
    }
};

pub fn encode(a: A, value: *const lua.Expr, table_shapes: ?*const shapes.ModuleFacts) ![]u8 {
    var encoder = Encoder{ .allocator = a, .table_shapes = table_shapes };
    errdefer encoder.out.deinit(a);
    try encoder.expr(value, 0);
    return encoder.out.toOwnedSlice(a);
}

pub const NamedLiteralField = struct {
    name: []const u8,
    value: *const lua.Expr,
};

pub fn encodeNamedTable(
    a: A,
    span_start: u32,
    fields: []const NamedLiteralField,
    table_shapes: ?*const shapes.ModuleFacts,
) ![]u8 {
    const table_fields = try a.alloc(lua.TableField, fields.len);
    defer a.free(table_fields);
    for (table_fields, fields) |*out, field| {
        if (!isLiteral(field.value)) return error.NonStaticLiteral;
        out.* = .{ .named = .{ .name = field.name, .value = @constCast(field.value) } };
    }
    var expr: lua.Expr = .{ .table = .{
        .fields = table_fields,
        .span = .{ .start = span_start, .end = span_start },
    } };
    return encode(a, &expr, table_shapes);
}

const StaticValue = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: *StaticTable,
};

const StaticField = union(enum) {
    list: struct { index: u32, value: StaticValue },
    named: struct { name: []const u8, value: StaticValue },
    keyed: struct { key: StaticValue, value: StaticValue },
};

const StaticTable = struct {
    fields: std.ArrayList(StaticField) = .empty,
};

const PreparedTarget = union(enum) {
    local: []const u8,
    table: struct { table: *StaticTable, key: StaticValue },
};

const Evaluator = struct {
    allocator: A,
    env: std.StringHashMapUnmanaged(StaticValue) = .empty,
    tables: std.ArrayList(*StaticTable) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Evaluator) void {
        for (self.tables.items) |owned_table| {
            owned_table.fields.deinit(self.allocator);
            self.allocator.destroy(owned_table);
        }
        self.tables.deinit(self.allocator);
        for (self.owned_strings.items) |owned| self.allocator.free(owned);
        self.owned_strings.deinit(self.allocator);
        self.env.deinit(self.allocator);
    }

    fn newTable(self: *Evaluator) !*StaticTable {
        const new_table = try self.allocator.create(StaticTable);
        new_table.* = .{};
        errdefer self.allocator.destroy(new_table);
        try self.tables.append(self.allocator, new_table);
        return new_table;
    }

    fn evalValue(self: *Evaluator, expr: *const lua.Expr) anyerror!StaticValue {
        return switch (expr.*) {
            .nil_lit => .nil,
            .bool_lit => |literal| .{ .boolean = literal.value },
            .number => |literal| .{ .number = try numbers.parse(literal.raw) },
            .string => |literal| .{ .string = literal.value },
            .name => |name| self.env.get(name.value) orelse error.NonStaticData,
            .paren => |paren| self.evalValue(paren.expr),
            .index => self.evalIndex(expr),
            .table => |table_expr| try self.evalTable(table_expr.fields),
            .unary => |unary| try self.evalUnary(unary.op, unary.expr),
            .binary => |binary| try self.evalBinary(binary.op, binary.lhs, binary.rhs),
            else => error.NonStaticData,
        };
    }

    fn truthy(value: StaticValue) bool {
        return switch (value) {
            .nil => false,
            .boolean => |item| item,
            .number, .string, .table => true,
        };
    }

    fn denseListLength(table_value: *const StaticTable) ?usize {
        var expected: u32 = 1;
        for (table_value.fields.items) |field| switch (field) {
            .list => |item| {
                if (item.index != expected) return null;
                expected = std.math.add(u32, expected, 1) catch return null;
            },
            else => return null,
        };
        return expected - 1;
    }

    fn evalUnary(self: *Evaluator, op: lua.UnaryOp, operand_expr: *const lua.Expr) anyerror!StaticValue {
        const operand = try self.evalValue(operand_expr);
        return switch (op) {
            .not_ => .{ .boolean = !truthy(operand) },
            .neg => if (operand == .number)
                .{ .number = -operand.number }
            else
                error.NonStaticData,
            .len => switch (operand) {
                .string => |item| .{ .number = @floatFromInt(item.len) },
                .table => |table_value| if (denseListLength(table_value)) |len|
                    .{ .number = @floatFromInt(len) }
                else
                    error.NonStaticData,
                else => error.NonStaticData,
            },
        };
    }

    fn evalBinary(
        self: *Evaluator,
        op: lua.BinaryOp,
        lhs_expr: *const lua.Expr,
        rhs_expr: *const lua.Expr,
    ) anyerror!StaticValue {
        const lhs = try self.evalValue(lhs_expr);
        return switch (op) {
            .and_ => if (!truthy(lhs)) lhs else try self.evalValue(rhs_expr),
            .or_ => if (truthy(lhs)) lhs else try self.evalValue(rhs_expr),
            .concat => blk: {
                const rhs = try self.evalValue(rhs_expr);
                if (lhs != .string or rhs != .string) return error.NonStaticData;
                const combined = try std.mem.concat(self.allocator, u8, &.{ lhs.string, rhs.string });
                errdefer self.allocator.free(combined);
                try self.owned_strings.append(self.allocator, combined);
                break :blk .{ .string = combined };
            },
            else => error.NonStaticData,
        };
    }

    fn evalTable(self: *Evaluator, fields: []const lua.TableField) anyerror!StaticValue {
        const table_value = try self.newTable();
        var list_index: u32 = 1;
        for (fields) |field| switch (field) {
            .list => |item| {
                try table_value.fields.append(self.allocator, .{ .list = .{
                    .index = list_index,
                    .value = try self.evalValue(item),
                } });
                list_index = std.math.add(u32, list_index, 1) catch return error.NonStaticData;
            },
            .named => |item| try table_value.fields.append(self.allocator, .{ .named = .{
                .name = item.name,
                .value = try self.evalValue(item.value),
            } }),
            .keyed => |item| {
                const key = try self.evalValue(item.key);
                if (!validKey(key)) return error.NonStaticData;
                try table_value.fields.append(self.allocator, .{ .keyed = .{
                    .key = key,
                    .value = try self.evalValue(item.value),
                } });
            },
        };
        return .{ .table = table_value };
    }

    fn validKey(key_value: StaticValue) bool {
        return switch (key_value) {
            .boolean, .number, .string => true,
            .nil, .table => false,
        };
    }

    fn equalKey(lhs: StaticValue, rhs: StaticValue) bool {
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
        return switch (lhs) {
            .boolean => |lhs_value| lhs_value == rhs.boolean,
            .number => |lhs_value| lhs_value == rhs.number,
            .string => |lhs_value| std.mem.eql(u8, lhs_value, rhs.string),
            .nil, .table => false,
        };
    }

    fn fieldKey(field: StaticField) StaticValue {
        return switch (field) {
            .list => |item| .{ .number = @floatFromInt(item.index) },
            .named => |item| .{ .string = item.name },
            .keyed => |item| item.key,
        };
    }

    fn fieldValue(field: StaticField) StaticValue {
        return switch (field) {
            .list => |item| item.value,
            .named => |item| item.value,
            .keyed => |item| item.value,
        };
    }

    fn get(table_value: *StaticTable, key: StaticValue) ?StaticValue {
        var field_index = table_value.fields.items.len;
        while (field_index != 0) {
            field_index -= 1;
            const field = table_value.fields.items[field_index];
            if (equalKey(fieldKey(field), key)) return fieldValue(field);
        }
        return null;
    }

    fn evalIndex(self: *Evaluator, expr: *const lua.Expr) anyerror!StaticValue {
        if (expr.* != .index) return self.evalValue(expr);
        const object = try self.evalIndex(expr.index.object);
        if (object != .table) return error.NonStaticData;
        const key = try self.evalValue(expr.index.key);
        if (!validKey(key)) return error.NonStaticData;
        return get(object.table, key) orelse error.NonStaticData;
    }

    fn prepareTarget(self: *Evaluator, target: lua.LValue) anyerror!PreparedTarget {
        return switch (target) {
            .name => |name| if (self.env.contains(name))
                .{ .local = name }
            else
                error.NonStaticData,
            .index => |index_expr| blk: {
                const object = try self.evalIndex(index_expr.object);
                if (object != .table) return error.NonStaticData;
                const key = try self.evalValue(index_expr.key);
                if (!validKey(key)) return error.NonStaticData;
                break :blk .{ .table = .{ .table = object.table, .key = key } };
            },
        };
    }

    fn assign(self: *Evaluator, target: PreparedTarget, assigned_value: StaticValue) !void {
        switch (target) {
            .local => |name| try self.env.put(self.allocator, name, assigned_value),
            .table => |item| try item.table.fields.append(self.allocator, .{ .keyed = .{
                .key = item.key,
                .value = assigned_value,
            } }),
        }
    }

    fn localAssign(self: *Evaluator, stmt: anytype) anyerror!void {
        if (stmt.values.len > stmt.names.len) return error.NonStaticData;
        const values = try self.allocator.alloc(StaticValue, stmt.names.len);
        defer self.allocator.free(values);
        for (values, 0..) |*out, value_index| out.* = if (value_index < stmt.values.len)
            try self.evalValue(stmt.values[value_index])
        else
            .nil;
        for (stmt.names, values) |name, value| try self.env.put(self.allocator, name, value);
    }

    fn assignment(self: *Evaluator, stmt: anytype) anyerror!void {
        if (stmt.values.len > stmt.targets.len) return error.NonStaticData;
        const targets = try self.allocator.alloc(PreparedTarget, stmt.targets.len);
        defer self.allocator.free(targets);
        for (stmt.targets, 0..) |target, target_index| targets[target_index] = try self.prepareTarget(target);
        const values = try self.allocator.alloc(StaticValue, stmt.targets.len);
        defer self.allocator.free(values);
        for (values, 0..) |*out, value_index| out.* = if (value_index < stmt.values.len)
            try self.evalValue(stmt.values[value_index])
        else
            .nil;
        for (targets, values) |target, value| try self.assign(target, value);
    }

    fn root(self: *Evaluator, body: lua.Block) anyerror!StaticValue {
        var result: ?StaticValue = null;
        for (body) |stmt| switch (stmt.*) {
            .empty => {},
            .local_assign => |assignment_stmt| try self.localAssign(assignment_stmt),
            .assign => |assignment_stmt| try self.assignment(assignment_stmt),
            .return_stmt => |return_stmt| {
                if (result != null or return_stmt.values.len != 1) return error.NonStaticData;
                result = try self.evalValue(return_stmt.values[0]);
            },
            else => return error.NonStaticData,
        };
        return result orelse error.NonStaticData;
    }
};

fn visitTree(
    a: A,
    value: StaticValue,
    seen: *std.AutoHashMapUnmanaged(*StaticTable, void),
) anyerror!void {
    if (value != .table) return;
    const result = try seen.getOrPut(a, value.table);
    if (result.found_existing) return error.NonStaticData;
    for (value.table.fields.items) |field| {
        switch (field) {
            .keyed => |item| try visitTree(a, item.key, seen),
            else => {},
        }
        try visitTree(a, switch (field) {
            .list => |item| item.value,
            .named => |item| item.value,
            .keyed => |item| item.value,
        }, seen);
    }
}

fn rootStringFields(a: A, value: StaticValue) !?[]const []const u8 {
    if (value != .table or value.table.fields.items.len == 0) return null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (value.table.fields.items) |field| {
        const name = switch (field) {
            .named => |item| item.name,
            .keyed => |item| if (item.key == .string) item.key.string else return null,
            .list => return null,
        };
        if (seen.contains(name)) continue;
        try seen.put(a, name, {});
        try names.append(a, name);
    }
    return try names.toOwnedSlice(a);
}

fn staticValue(self: *Encoder, value: StaticValue, depth: usize, shape_id: ?u32) anyerror!void {
    if (depth >= format.max_depth) return error.StaticLiteralTooDeep;
    switch (value) {
        .nil => try self.out.append(self.allocator, @intFromEnum(format.ValueTag.nil)),
        .boolean => |item| try self.out.append(
            self.allocator,
            @intFromEnum(if (item) format.ValueTag.true_ else format.ValueTag.false_),
        ),
        .number => |item| {
            try self.out.append(self.allocator, @intFromEnum(format.ValueTag.number));
            try self.writeU64(@bitCast(item));
        },
        .string => |item| {
            try self.out.append(self.allocator, @intFromEnum(format.ValueTag.string));
            try self.writeString(item);
        },
        .table => |table_value| {
            try self.out.append(self.allocator, @intFromEnum(format.ValueTag.table));
            try self.writeRawU32(shape_id orelse format.no_shape);
            try self.writeU32(table_value.fields.items.len);
            var list_capacity: usize = 0;
            for (table_value.fields.items) |field| {
                if (field == .list) list_capacity += 1;
            }
            try self.writeU32(list_capacity);
            for (table_value.fields.items) |field| switch (field) {
                .list => |item| {
                    try self.out.append(self.allocator, @intFromEnum(format.FieldTag.list));
                    try staticValue(self, item.value, depth + 1, null);
                },
                .named => |item| {
                    try self.out.append(self.allocator, @intFromEnum(format.FieldTag.named));
                    try self.writeString(item.name);
                    try staticValue(self, item.value, depth + 1, null);
                },
                .keyed => |item| {
                    try self.out.append(self.allocator, @intFromEnum(format.FieldTag.keyed));
                    try staticValue(self, item.key, depth + 1, null);
                    try staticValue(self, item.value, depth + 1, null);
                },
            };
        },
    }
}

pub const EvaluatedRoot = struct {
    blob: []u8,
    export_shape_id: ?u32,
};

pub fn encodePureDataRoot(
    a: A,
    body: lua.Block,
    shape_registry: *shapes.Registry,
    module_index: u32,
) !?EvaluatedRoot {
    var evaluator = Evaluator{ .allocator = a };
    defer evaluator.deinit();
    const root = evaluator.root(body) catch |err| switch (err) {
        error.NonStaticData => return null,
        else => return err,
    };
    var seen: std.AutoHashMapUnmanaged(*StaticTable, void) = .empty;
    defer seen.deinit(a);
    visitTree(a, root, &seen) catch |err| switch (err) {
        error.NonStaticData => return null,
        else => return err,
    };

    var export_shape_id: ?u32 = null;
    if (try rootStringFields(a, root)) |fields| {
        defer a.free(fields);
        export_shape_id = try shape_registry.promote(module_index, 0, fields);
    }
    var encoder = Encoder{ .allocator = a, .table_shapes = null };
    errdefer encoder.out.deinit(a);
    try staticValue(&encoder, root, 0, export_shape_id);
    return .{
        .blob = try encoder.out.toOwnedSlice(a),
        .export_shape_id = export_shape_id,
    };
}

test "pure incremental data builder lowers to static literal" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a,
        \\local m = {}
        \\m["alpha"] = {1, 2}
        \\m.beta = { ok = true }
        \\m.beta.extra = "x" .. "y"
        \\m.coords = {-27.5, 153.0}
        \\m.coords.length = #m.coords
        \\return m
    );
    defer chunk.deinit();
    var registry = shapes.Registry.init(a);
    defer registry.deinit();
    const result = (try encodePureDataRoot(a, chunk.body, &registry, 0)) orelse
        return error.ExpectedStaticData;
    defer a.free(result.blob);
    try std.testing.expect(result.export_shape_id != null);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(result.blob.len != 0);
}

test "pure data evaluator rejects calls loops and shared table identity" {
    const a = std.testing.allocator;
    inline for (.{
        "local m={}; m.x=f(); return m",
        "local m={}; for i=1,2 do m[i]=i end; return m",
        "local t={}; local m={a=t,b=t}; return m",
    }) |source| {
        var chunk = try lua.parse(a, source);
        defer chunk.deinit();
        var registry = shapes.Registry.init(a);
        defer registry.deinit();
        try std.testing.expect((try encodePureDataRoot(a, chunk.body, &registry, 0)) == null);
    }
}

test "static root literal detection excludes executable values" {
    const a = std.testing.allocator;
    var static_chunk = try lua.parse(a, "return { a = 1, { true, 'x' } }");
    defer static_chunk.deinit();
    try std.testing.expect(rootLiteral(static_chunk.body) != null);

    var dynamic_chunk = try lua.parse(a, "return { a = function() return 1 end }");
    defer dynamic_chunk.deinit();
    try std.testing.expect(rootLiteral(dynamic_chunk.body) == null);
}
