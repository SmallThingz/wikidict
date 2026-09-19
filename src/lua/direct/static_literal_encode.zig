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

test "static root literal detection excludes executable values" {
    const a = std.testing.allocator;
    var static_chunk = try lua.parse(a, "return { a = 1, { true, 'x' } }");
    defer static_chunk.deinit();
    try std.testing.expect(rootLiteral(static_chunk.body) != null);

    var dynamic_chunk = try lua.parse(a, "return { a = function() return 1 end }");
    defer dynamic_chunk.deinit();
    try std.testing.expect(rootLiteral(dynamic_chunk.body) == null);
}
