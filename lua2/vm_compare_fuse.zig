const std = @import("std");
const ir = @import("vm_ir.zig");
const sem = @import("vm_semantics.zig");
const cfg = @import("vm_graph.zig");
const liveness = @import("vm_liveness.zig");
pub const Stats = struct { branches: u64 = 0 };
fn runFunction(a: std.mem.Allocator, p: *const ir.Program, f: *ir.Function) !u64 {
    var graph = try cfg.build(a, f);
    defer graph.deinit();
    var live = try liveness.build(a, p, f, &graph);
    defer live.deinit();
    const captured = try a.alloc(bool, f.reg_count);
    defer a.free(captured);
    @memset(captured, false);
    for (f.insts.items) |inst| if (inst.op == .closure) {
        for (p.functions.items[inst.aux].?.upvalues.items) |up| if (up.source == .local) {
            captured[up.index] = true;
        };
    };
    const remove = try a.alloc(bool, f.insts.items.len);
    defer a.free(remove);
    @memset(remove, false);
    var fused: u64 = 0;
    for (f.insts.items, 0..) |inst, pc| {
        if (!sem.isComparison(inst.op) or pc + 1 >= f.insts.items.len) continue;
        if (captured[inst.dst]) continue;
        const next = f.insts.items[pc + 1];
        if (next.op != .jump_if_false or next.a != inst.dst) continue;
        const bid = graph.block_of_pc[pc];
        if (graph.block_of_pc[pc + 1] != bid) continue;
        var live_after = false;
        for (graph.blocks.items[bid].succ) |succ| if (succ) |s| {
            live_after = live_after or live.isLiveIn(s, inst.dst);
        };
        if (live_after) continue;
        // Preserve comparison evaluation and metamethod effects, but do not
        // materialize a boolean whose sole use is this branch.
        f.insts.items[pc] = .{ .op = .branch_compare, .a = inst.a, .b = inst.b, .aux = next.aux, .count = @intFromEnum(inst.op) };
        remove[pc + 1] = true;
        fused += 1;
    }
    if (fused == 0) return 0;
    const map = try a.alloc(u32, f.insts.items.len + 1);
    defer a.free(map);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(a);
    for (f.insts.items, 0..) |inst, pc| {
        map[pc] = @intCast(out.items.len);
        if (!remove[pc]) try out.append(a, inst);
    }
    map[f.insts.items.len] = @intCast(out.items.len);
    for (out.items) |*inst| if (sem.info(inst.op).target) {
        inst.aux = map[inst.aux];
    };
    f.insts.deinit(a);
    f.insts = out;
    return fused;
}
pub fn run(a: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        stats.branches += try runFunction(a, p, f);
    };
    return stats;
}

fn check(source: []const u8, expected: []const f64) !u64 {
    const lua = @import("root.zig");
    const exec = @import("vm_exec.zig");
    const codec = @import("vm_codec.zig");
    const opt = @import("vm_optimize.zig");
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const stats = try opt.run(a, &p);
    const bytes = try codec.serialize(a, &p);
    defer a.free(bytes);
    var restored = try codec.deserializeBorrowed(a, bytes);
    defer restored.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try @import("lua_stdlib.zig").install(&vm);
    const out = try vm.executeRoot(&restored, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(expected.len, out.len);
    for (expected, out) |want, got| try std.testing.expectEqual(want, got.number);
    return stats.comparisons.branches;
}
test "comparison branches discard unobservable boolean results" {
    const n = try check("local function f(x) if x<4 then return 7 else return 9 end end; return f(3),f(5)", &.{ 7, 9 });
    try std.testing.expect(n > 0);
}
test "comparison branches preserve metamethod effects" {
    const n = try check("local n=0;local mt={__lt=function(a,b) n=n+1;return a.x<b.x end};local a=setmetatable({x=1},mt);local b=setmetatable({x=2},mt);if a<b then return n else return -1 end", &.{1});
    try std.testing.expect(n > 0);
}

test "comparison result used by either successor is retained" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    var f = ir.Function{ .param_count = 2, .reg_count = 3 };
    try f.operands.append(a, 2);
    try f.insts.appendSlice(a, &.{
        .{ .op = .lt, .dst = 2, .a = 0, .b = 1 },
        .{ .op = .jump_if_false, .a = 2, .aux = 3 },
        .{ .op = .ret, .count = 1 },
        .{ .op = .ret, .count = 1 },
    });
    try p.functions.append(a, f);
    try std.testing.expectEqual(@as(u64, 0), (try run(a, &p)).branches);
}
test "independently reachable consuming branch cannot be fused" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    var f = ir.Function{ .param_count = 3, .reg_count = 3 };
    try f.insts.appendSlice(a, &.{
        .{ .op = .jump, .aux = 2 },                  .{ .op = .lt, .dst = 2, .a = 0, .b = 1 },
        .{ .op = .jump_if_false, .a = 2, .aux = 4 }, .{ .op = .ret },
        .{ .op = .ret },
    });
    try p.functions.append(a, f);
    try std.testing.expectEqual(@as(u64, 0), (try run(a, &p)).branches);
}
