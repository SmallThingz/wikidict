const std = @import("std");
const ir = @import("vm_ir.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");
const codec = @import("vm_codec.zig");
const lua = @import("root.zig");
const abi = @import("vm_global_abi.zig");
const a = std.testing.allocator;
fn check(source: []const u8, expected: []const rt.Value) !void {
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const bytes = try codec.serialize(a, &program);
    defer a.free(bytes);
    var restored = try codec.deserializeBorrowed(a, bytes);
    defer restored.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    const actual = try vm.executeRoot(&restored, &.{});
    defer exec.Vm.freeResults(actual);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |x, y| try std.testing.expect(rt.rawEqual(x, y));
}
test "native global names disappear during lowering and need no hash storage" {
    var chunk = try lua.parse(a, "return type,tonumber,tostring,table,string,math,require,mw");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.strings.items.len);
    var loads: usize = 0;
    for (p.functions.items[0].?.insts.items) |inst| {
        try std.testing.expect(inst.op != .get_global);
        loads += @intFromBool(inst.op == .get_global_slot);
    }
    try std.testing.expectEqual(@as(usize, 8), loads);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    try std.testing.expectEqual(@as(u32, 0), vm.globals.map.capacity());
    try std.testing.expect(vm.getGlobal("tonumber").? == .native);
    const table = try rt.newTable(arena.allocator());
    try table.rawSet(arena.allocator(), .{ .string = "type" }, .{ .number = 7 });
    try std.testing.expectEqual(@as(usize, 0), table.slots.len);
    try std.testing.expectEqual(@as(u32, 1), table.map.count());
}
test "dynamic environment aliases mutate the same statically bound global" {
    try check("local old=tonumber;local k='to'..'number';_G[k]=function()return 9 end;" ++
        "local n=tonumber('7');rawset(_G,k,old);return n,tonumber('7'),_G==rawget(_G,'_G')", &.{ .{ .number = 9 }, .{ .number = 7 }, .{ .boolean = true } });
}
test "global slots preserve nil deletion shadowing and rebinding of the _G value" {
    try check("local env=_G;_G={tonumber=function()return 99 end};" ++
        "local n=tonumber('7');_G=env;type=nil;return n,type,rawget(_G,'type')", &.{ .{ .number = 7 }, .nil, .nil });
    try check("local type=function()return 3 end;return type(),_G.type(0)", &.{ .{ .number = 3 }, .{ .string = "number" } });
}
test "pairs observes every live global slot exactly once" {
    try check("local n=0;for k,v in pairs(_G) do if k=='tonumber' then n=n+1 end end;return n", &.{.{ .number = 1 }});
}
test "v2 global reads execute against the current numeric native environment" {
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    try p.strings.append(a, "type");
    var f = ir.Function{ .reg_count = 1 };
    try f.operands.append(a, 0);
    try f.insts.appendSlice(a, &.{ .{ .op = .get_global, .dst = 0, .aux = 0 }, .{ .op = .ret, .count = 1 } });
    try p.functions.append(a, f);
    const bytes = try codec.serializeVersion(a, &p, 2);
    defer a.free(bytes);
    var old = try codec.deserializeBorrowed(a, bytes);
    defer old.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try vm.setGlobal("type", .{ .number = 33 });
    const out = try vm.executeRoot(&old, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 33), out[0].number);
}
test "numeric native opcodes cannot masquerade as v2 or address outside the ABI" {
    var chunk = try lua.parse(a, "return type");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    try std.testing.expectError(error.IncompatibleBytecode, codec.serializeVersion(a, &p, 2));
    const bytes = try codec.serialize(a, &p);
    defer a.free(bytes);
    bytes[4] = 2;
    if (codec.deserialize(a, bytes)) |bad| {
        var owned = bad;
        owned.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    p.functions.items[0].?.insts.items[0].aux = abi.count;
    const bad_slot = try codec.serialize(a, &p);
    defer a.free(bad_slot);
    try std.testing.expectError(error.BadGlobalSlot, codec.deserialize(a, bad_slot));
}
