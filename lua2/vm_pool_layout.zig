const std = @import("std");
const ir = @import("vm_ir.zig");
const refs = @import("vm_ref.zig");
const sem = @import("vm_semantics.zig");

// Every pooled string already has an identity. A second serialized string
// constant record duplicates that identity and can be omitted entirely.
pub const Layout = struct {
    allocator: std.mem.Allocator,
    constants: []u32,
    records: u32,
    pub fn init(a: std.mem.Allocator, p: *const ir.Program) !Layout {
        const map = try a.alloc(u32, p.constants.items.len);
        errdefer a.free(map);
        const strings = std.math.cast(u32, p.strings.items.len) orelse return error.ReferenceOverflow;
        var next = strings;
        for (p.constants.items, 0..) |node, id| {
            if (node == .string) {
                if (node.string >= strings) return error.BadStringReference;
                map[id] = node.string;
            } else {
                map[id] = next;
                next = std.math.add(u32, next, 1) catch return error.ReferenceOverflow;
            }
        }
        return .{ .allocator = a, .constants = map, .records = next - strings };
    }
    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.constants);
    }
    pub fn constant(self: *const Layout, id: u32) !u32 {
        if (id >= self.constants.len) return error.BadConstantReference;
        return self.constants[id];
    }
    pub fn reference(self: *const Layout, value: u32) !u32 {
        return if (refs.tag(value) == .constant)
            try refs.constant(try self.constant(refs.index(value)))
        else
            value;
    }
    pub fn instruction(self: *const Layout, original: ir.Inst) !ir.Inst {
        var out = original;
        if (out.op == .load_const) out.aux = try self.constant(out.aux);
        inline for (sem.fields, 0..) |field, i| {
            if (refs.mask(out.op) & (@as(u8, 1) << i) != 0)
                @field(out, field) = try self.reference(@field(out, field));
        }
        return out;
    }
};

test "string constants share the existing string identity" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    try p.strings.appendSlice(a, &.{ "unused", "live" });
    try p.constants.appendSlice(a, &.{ .nil, .{ .string = 1 }, .{ .number_bits = @bitCast(@as(f64, 3)) } });
    var layout = try Layout.init(a, &p);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u32, 2), layout.records);
    try std.testing.expectEqual(@as(u32, 1), try layout.constant(1));
    try std.testing.expectEqual(try refs.constant(3), try layout.reference(try refs.constant(2)));
}
