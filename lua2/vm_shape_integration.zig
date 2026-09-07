const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const codec = @import("vm_codec.zig");
const exec = @import("vm_exec.zig");
const lib = @import("lua_stdlib.zig");

fn check(source: []const u8, expected: []const f64) !void {
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const stats = try opt.run(std.testing.allocator, &p);
    try std.testing.expect(stats.shapes.shaped_tables != 0);
    const bytes = try codec.serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(bytes);
    var q = try codec.deserializeBorrowed(std.testing.allocator, bytes);
    defer q.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try lib.install(&vm);
    const out = try vm.executeRoot(&q, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(expected.len, out.len);
    for (out, expected) |value, n| try std.testing.expectEqual(n, value.number);
}

test "escaped fixed fields survive pairs rawget and codec" {
    try check("local t={}; t.alpha=2; t.beta=3; local n=0; local s=0; for k,v in pairs(t) do n=n+1;s=s+v end; return n,s,rawget(t,'alpha')", &.{ 2, 5, 2 });
}
test "rawset updates and deletes slots without duplicate iteration" {
    try check("local t={}; t.a=2;t.b=3;rawset(t,'a',7);rawset(t,'b',nil);rawset(t,'c',11);local n=0;local s=0;for k,v in pairs(t) do n=n+1;s=s+v end;return n,s,t.a", &.{ 2, 18, 7 });
}
test "slot and generic stores preserve metatable effects" {
    try check("local t={};t.x=2;setmetatable(t,{__newindex=function(self,k,v) rawset(self,k,v*2) end,__index=function() return 17 end});t.x=3;t.y=4;rawset(t,'x',nil);t.x=5;return t.x,t.y,t.z", &.{ 10, 8, 17 });
}
test "fixed fields coexist with array elements and maxn" {
    try check("local t={};t.x=9;table.insert(t,2);table.insert(t,3);local n=0;local s=0;for k,v in pairs(t) do n=n+1;s=s+v end;return n,s,#t,table.maxn(t)", &.{ 3, 14, 2, 2 });
}
test "escaping fixed object does not allocate hash storage" {
    var chunk = try lua.parse(std.testing.allocator, "local t={};t.x=2;t.y=3;return t");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    _ = try opt.run(std.testing.allocator, &p);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(usize, 2), out[0].table.slots.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].table.map.capacity());
}

test "object stored into an already specialized slot retains observable keys" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    try p.strings.appendSlice(a, &.{ "x", "child" });
    var shape = ir.Shape{ .field_count = 1, .open = true };
    try shape.field_keys.append(a, 1);
    try p.shapes.append(a, shape);
    var f = ir.Function{ .reg_count = 3 };
    try f.operands.append(a, 0);
    try f.insts.appendSlice(a, &.{
        .{ .op = .new_table_shape, .dst = 0, .aux = 0 },
        .{ .op = .new_table, .dst = 1 },
        .{ .op = .load_bool, .dst = 2, .a = 1 },
        .{ .op = .set_field, .a = 1, .c = 2, .aux = 0 },
        .{ .op = .set_slot, .a = 0, .c = 1, .aux = 0 },
        .{ .op = .ret, .aux = 0, .count = 1 },
    });
    try p.functions.append(a, f);
    _ = try @import("vm_shape_opt.zig").run(a, &p);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    const child = out[0].table.rawGet(.{ .string = "child" }).?.table;
    const value = child.rawGet(.{ .string = "x" }) orelse return error.LostObservableField;
    try std.testing.expect(value.boolean);
}
