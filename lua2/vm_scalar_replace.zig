const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const sem = @import("vm_semantics.zig");
pub const Stats = struct { objects: u64 = 0, reads: u64 = 0, writes: u64 = 0 };
const Object = struct { value: u32, pc: u32, shape: u32, allowed: u32 = 0, escaped: bool = false, base: u32 = 0 };
fn objectAt(map: *const std.AutoHashMapUnmanaged(u32, u32), analysis: *const ssa.Function, state: []const u32, reg: u32) ?u32 {
    if (reg >= state.len) return null;
    return map.get(analysis.canonicalValue(state[reg]));
}
fn runFunction(allocator: std.mem.Allocator, p: *ir.Program, f: *ir.Function) !Stats {
    var analysis = try ssa.build(allocator, p, f);
    defer analysis.deinit();
    var objects: std.ArrayList(Object) = .empty;
    defer objects.deinit(allocator);
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(allocator);
    const state = try allocator.alloc(u32, f.reg_count);
    defer allocator.free(state);
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        const input = analysis.entry_states[bid] orelse continue;
        @memcpy(state, input);
        for (block.start..block.end) |pc| {
            const inst = f.insts.items[pc];
            try ssa.applyWrites(&analysis, f, state, @intCast(pc), null);
            if (inst.op != .new_table_shape or analysis.captured[inst.dst]) continue;
            const shape = p.shapes.items[inst.aux];
            if (shape.open or shape.field_keys.items.len != 0) continue;
            const value = analysis.canonicalValue(state[inst.dst]);
            try map.put(allocator, value, @intCast(objects.items.len));
            try objects.append(allocator, .{ .value = value, .pc = @intCast(pc), .shape = inst.aux });
        }
    }
    if (objects.items.len == 0) return .{};
    for (analysis.phis.items) |phi| for (phi.inputs.items) |raw| {
        if (map.get(analysis.canonicalValue(raw))) |index| objects.items[index].escaped = true;
    };
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        const input = analysis.entry_states[bid] orelse continue;
        @memcpy(state, input);
        for (block.start..block.end) |pc| {
            const inst = f.insts.items[pc];
            switch (inst.op) {
                .get_slot, .set_slot, .get_choice_slot, .set_choice_slot => if (objectAt(&map, &analysis, state, inst.a)) |index| {
                    objects.items[index].allowed += 1;
                },
                else => {},
            }
            try ssa.applyWrites(&analysis, f, state, @intCast(pc), null);
        }
    }
    var stats = Stats{};
    var next_reg = f.reg_count;
    for (objects.items) |*object| {
        if (object.escaped or analysis.values.items[object.value].uses != object.allowed) {
            object.escaped = true;
            continue;
        }
        const shape = p.shapes.items[object.shape];
        object.base = next_reg;
        next_reg = try std.math.add(u32, next_reg, try std.math.add(u32, shape.field_count, shape.choice_count));
        stats.objects += 1;
    }
    if (stats.objects == 0) return stats;
    const remap = try allocator.alloc(u32, f.insts.items.len + 1);
    defer allocator.free(remap);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(allocator);
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        const input = analysis.entry_states[bid];
        if (input) |s| @memcpy(state, s);
        for (block.start..block.end) |pc| {
            remap[pc] = @intCast(out.items.len);
            const inst = f.insts.items[pc];
            var replacement: ?ir.Inst = inst;
            if (input != null) switch (inst.op) {
                .new_table_shape => {
                    const raw = analysis.def_ids.get((@as(u64, pc) << 32) | inst.dst) orelse ssa.invalid_value;
                    if (map.get(analysis.canonicalValue(raw))) |index| {
                        const object = objects.items[index];
                        if (!object.escaped) {
                            const shape = p.shapes.items[object.shape];
                            for (0..shape.field_count + shape.choice_count) |i| try out.append(allocator, .{ .op = .load_nil, .dst = object.base + @as(u32, @intCast(i)) });
                            replacement = null;
                        }
                    }
                },
                .move => if (objectAt(&map, &analysis, state, inst.a)) |index| {
                    if (!objects.items[index].escaped) replacement = null;
                },
                .get_slot, .set_slot, .get_choice_slot, .set_choice_slot => if (objectAt(&map, &analysis, state, inst.a)) |index| {
                    const object = objects.items[index];
                    if (!object.escaped) {
                        const choice = inst.op == .get_choice_slot or inst.op == .set_choice_slot;
                        const slot = object.base + inst.aux + (if (choice) p.shapes.items[object.shape].field_count else 0);
                        if (inst.op == .get_slot or inst.op == .get_choice_slot) {
                            replacement = .{ .op = .move, .dst = inst.dst, .a = slot };
                            stats.reads += 1;
                        } else {
                            if (choice) try out.append(allocator, .{ .op = .check_table_key, .a = inst.b });
                            replacement = .{ .op = .move, .dst = slot, .a = inst.c };
                            stats.writes += 1;
                        }
                    }
                },
                else => {},
            };
            if (replacement) |copy| try out.append(allocator, sem.canonical(copy));
            if (input != null) try ssa.applyWrites(&analysis, f, state, @intCast(pc), null);
        }
    }
    remap[f.insts.items.len] = @intCast(out.items.len);
    for (out.items) |*inst| if (sem.info(inst.op).target) {
        inst.aux = remap[inst.aux];
    };
    f.insts.deinit(allocator);
    f.insts = out;
    f.reg_count = next_reg;
    return stats;
}
pub fn run(allocator: std.mem.Allocator, p: *ir.Program) !Stats {
    var stats = Stats{};
    for (p.functions.items) |*maybe| if (maybe.*) |*f| {
        const one = try runFunction(allocator, p, f);
        stats.objects += one.objects;
        stats.reads += one.reads;
        stats.writes += one.writes;
    };
    return stats;
}
const lua = @import("root.zig");
const shape_pass = @import("vm_shape_opt.zig");
const verify = @import("vm_verify.zig");
const exec = @import("vm_exec.zig");
fn compile(allocator: std.mem.Allocator, chunk: *const lua.Chunk) !ir.Program {
    var p = try ir.lowerChunk(allocator, chunk);
    errdefer p.deinit();
    _ = try shape_pass.run(allocator, &p);
    _ = try run(allocator, &p);
    try verify.run(allocator, &p);
    return p;
}
test "closed record is completely scalar replaced" {
    var chunk = try lua.parse(std.testing.allocator, "local t={}; t.x=2; t.y=3; return t.x+t.y");
    defer chunk.deinit();
    var p = try compile(std.testing.allocator, &chunk);
    defer p.deinit();
    for (p.functions.items) |maybe| if (maybe) |f| for (f.insts.items) |inst| {
        try std.testing.expect(inst.op != .new_table_shape and inst.op != .get_slot and inst.op != .set_slot);
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 5), out[0].number);
}
test "exclusive key object becomes one scalar not an enumerated layout" {
    const source = "local function f(k,v) local t={}; t[k]=v; return t[k] end; return f('en',7),f('fr',9)";
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var p = try compile(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 7), out[0].number);
    try std.testing.expectEqual(@as(f64, 9), out[1].number);
}
test "scalar replacement preserves invalid key errors" {
    var chunk = try lua.parse(std.testing.allocator, "local function f(k) local t={}; t[k]=1; return t[k] end; return f(nil)");
    defer chunk.deinit();
    var p = try compile(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try std.testing.expectError(error.NilTableKey, vm.executeRoot(&p, &.{}));
}
