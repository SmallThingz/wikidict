const std = @import("std");
const lua = @import("root.zig");
const ir = @import("vm_ir.zig");
const opt = @import("vm_optimize.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");
const codec = @import("vm_codec.zig");
const link = @import("vm_link_image.zig");
const a = std.testing.allocator;
fn append(image: *link.Image, source: []const u8) !void {
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.runSemantics(a, &p);
    _ = try image.appendModule(&p);
}
fn expectNumbers(values: []const rt.Value, expected: []const f64) !void {
    try std.testing.expectEqual(expected.len, values.len);
    for (values, expected) |v, n| {
        try std.testing.expect(v == .number);
        try std.testing.expectEqual(n, v.number);
    }
}
test "linked globals are nameless slots shared across module roots" {
    var image = link.Image.init(a);
    defer image.deinit();
    try append(&image, "private_counter=41;return private_counter");
    try append(&image, "private_counter=private_counter+1;return private_counter");
    const stats = try opt.finalize(a, &image.program);
    try std.testing.expectEqual(@as(u64, 1), stats.globals.user_slots);
    try std.testing.expectEqual(@as(usize, 0), image.program.strings.items.len);
    for (image.program.functions.items) |f| for (f.?.insts.items) |inst| {
        try std.testing.expect(inst.op != .get_global and inst.op != .set_global);
    };
    const bytes = try codec.serialize(a, &image.program);
    defer a.free(bytes);
    var p = try codec.deserialize(a, bytes);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    const first = try vm.execute(&p, p.module_roots.items[0], &.{}, &.{});
    defer exec.Vm.freeResults(first);
    const second = try vm.execute(&p, p.module_roots.items[1], &.{}, &.{});
    defer exec.Vm.freeResults(second);
    try expectNumbers(first, &.{41});
    try expectNumbers(second, &.{42});
    try std.testing.expectEqual(@as(u32, 0), vm.globals.map.count());
}
test "runtime-only environment keys observe the same numeric bindings" {
    var image = link.Image.init(a);
    defer image.deinit();
    try append(&image, "shared=5;local env=_G;local k=...;env[k]=7;return shared,env.shared,rawget(env,k)");
    _ = try opt.finalize(a, &image.program);
    const bytes = try codec.serialize(a, &image.program);
    defer a.free(bytes);
    var p = try codec.deserialize(a, bytes);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    const values = try vm.executeRoot(&p, &.{.{ .string = "shared" }});
    defer exec.Vm.freeResults(values);
    try expectNumbers(values, &.{ 7, 7, 7 });
    try std.testing.expectEqual(@as(u32, 0), vm.globals.map.count());
}
fn checkLocal(source: []const u8, expected: []const f64, minimum_direct: u64, closures: usize) !u64 {
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const stats = try opt.run(a, &p);
    try std.testing.expect(stats.direct.calls >= minimum_direct);
    var count: usize = 0;
    for (p.functions.items) |f| for (f.?.insts.items) |inst| {
        if (inst.op == .closure) count += 1;
    };
    try std.testing.expectEqual(closures, count);
    const bytes = try codec.serialize(a, &p);
    defer a.free(bytes);
    var restored = try codec.deserialize(a, bytes);
    defer restored.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    const values = try vm.executeRoot(&restored, &.{});
    defer exec.Vm.freeResults(values);
    try expectNumbers(values, expected);
    try std.testing.expectEqual(@as(u32, 0), vm.globals.map.count());
    return stats.direct.scoped_calls;
}
test "multiple calls to a known function require zero closures" {
    _ = try checkLocal("local function f(x)return x*2 end;return f(3),f(4)", &.{ 6, 8 }, 2, 0);
}
test "direct vararg calls preserve missing arguments and multi results" {
    _ = try checkLocal("local function f(...)return ... end;local function g()return 2,3 end;local a,b=f(g());return a,b,f(7)", &.{ 2, 3, 7 }, 2, 0);
}
test "escaping function identity is not merged with another closure" {
    _ = try checkLocal("local function f(x)return x+1 end;local function g(x)return x+1 end;local same=(f==g) and 1 or 0;return f(2),g(3),same", &.{ 3, 4, 0 }, 2, 2);
}
test "slot bound builtins remain mutable through the environment" {
    _ = try checkLocal("local saved=tonumber;tonumber=function(x)return 99 end;local v=tonumber('2');_G.tonumber=saved;return v,tonumber('3')", &.{ 99, 3 }, 0, 1);
}

test "nonescaping captured functions use direct cell arguments not closures" {
    const n = try checkLocal("local n=1;local function f(x)n=n+x;return n end;local a=f(2);local b=f(3);return a,b,n", &.{ 3, 6, 6 }, 0, 0);
    try std.testing.expectEqual(@as(u64, 2), n);
}
test "scoped call observes shared mutations by a reentrant callback" {
    const n = try checkLocal("local n=0;local function f(cb)n=n+1;cb();return n end;local function g()n=n+10 end;return f(g),f(g),n", &.{ 11, 22, 22 }, 0, 1);
    try std.testing.expectEqual(@as(u64, 2), n);
}
test "scoped capture cells belong to each parent activation" {
    const n = try checkLocal("local function run(x)local function f(y)x=x+y;return x end;return f(1),f(2) end;return run(5),run(8)", &.{ 6, 9, 11 }, 2, 0);
    try std.testing.expectEqual(@as(u64, 2), n);
}
test "environment reflection enumerates fixed slots without hash storage" {
    _ = try checkLocal("local found=0;for k,v in pairs(_G) do if k=='tonumber' and v==tonumber then found=found+1 end end;return found", &.{1}, 0, 0);
}

test "scoped lowering refuses a captured cell detached since closure creation" {
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    try p.constants.appendSlice(a, &.{ .{ .number_bits = @bitCast(@as(f64, 2)) }, .{ .number_bits = @bitCast(@as(f64, 9)) } });
    var root = ir.Function{ .reg_count = 4 };
    try root.operands.appendSlice(a, &.{ 2, 3, 0 });
    try root.insts.appendSlice(a, &.{
        .{ .op = .load_const, .dst = 0, .aux = 0 },
        .{ .op = .closure, .dst = 1, .aux = 1 },
        .{ .op = .detach_cell, .a = 0 },
        .{ .op = .load_const, .dst = 0, .aux = 1 },
        .{ .op = .call, .dst = 2, .a = 1, .count = 1 },
        .{ .op = .call, .dst = 3, .a = 1, .count = 1 },
        .{ .op = .ret, .count = 3 },
    });
    try p.functions.append(a, root);
    var child = ir.Function{ .reg_count = 1 };
    try child.upvalues.append(a, .{ .source = .local, .index = 0 });
    try child.operands.append(a, 0);
    try child.insts.appendSlice(a, &.{ .{ .op = .get_upvalue, .dst = 0, .a = 0 }, .{ .op = .ret, .count = 1 } });
    try p.functions.append(a, child);
    const stats = try opt.run(a, &p);
    try std.testing.expectEqual(@as(u64, 0), stats.direct.scoped_calls);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(values);
    try expectNumbers(values, &.{ 2, 2, 9 });
}

test "ordinary tables never alias the numeric global layout sentinel" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ordinary = try rt.newTable(alloc);
    try ordinary.rawSet(alloc, .{ .string = "getmetatable" }, .{ .number = 7 });
    try ordinary.rawSet(alloc, .{ .string = "type" }, .{ .number = 11 });
    try std.testing.expectEqual(@as(usize, 0), ordinary.slots.len);
    try std.testing.expectEqual(@as(u32, 2), ordinary.map.count());
    try std.testing.expectEqual(@as(f64, 7), ordinary.rawGet(.{ .string = "getmetatable" }).?.number);
    var vm = try exec.Vm.init(alloc);
    try vm.setGlobal("type", .{ .number = 13 });
    try std.testing.expectEqual(@as(u32, 0), vm.globals.map.count());
    try std.testing.expectEqual(@as(f64, 13), vm.getGlobal("type").?.number);
}

test "captured calls across branches and loop backedges do not allocate closures" {
    const n = try checkLocal("local n=0;local function add(x)n=n+x;return n end;" ++
        "local a;if tonumber('1')==1 then a=add(2) else a=add(3) end;" ++
        "local s=0;for i=1,3 do s=s+add(i) end;return a,s,n", &.{ 2, 16, 8 }, 0, 0);
    try std.testing.expectEqual(@as(u64, 3), n);
}
test "loop scoped calls observe reentrant mutations of the same outer cell" {
    const n = try checkLocal("local n=0;local function add(cb)n=n+1;cb();return n end;" ++
        "local function bump()n=n+10 end;add(bump);local s=0;" ++
        "for i=1,3 do s=s+add(bump) end;return s,n", &.{ 99, 44 }, 0, 1);
    try std.testing.expectEqual(@as(u64, 2), n);
}
test "captured functions in distinct parent activations keep separate cells across branches" {
    const n = try checkLocal("local function run(x)local function add(y)x=x+y;return x end;" ++
        "if x>0 then add(1) else add(2) end;return add(3) end;return run(5),run(-4)", &.{ 9, 1 }, 2, 0);
    try std.testing.expectEqual(@as(u64, 3), n);
}
