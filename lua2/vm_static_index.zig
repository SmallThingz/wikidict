const std = @import("std");
const ir = @import("vm_ir.zig");
const ssa = @import("vm_ssa.zig");
const static_key = @import("vm_static_key_abi.zig");
const exec = @import("vm_exec.zig");

const none = std.math.maxInt(u32);

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
};

fn literalRef(program: *const ir.Program, function: *const ir.Function, node: ssa.Value) ?u32 {
    if (node.kind != .instruction or node.pc >= function.insts.items.len) return null;
    const inst = function.insts.items[node.pc];
    const number: f64 = switch (inst.op) {
        .load_number => if (inst.aux < program.strings.items.len)
            exec.Vm.parseLuaNumber(program.strings.items[inst.aux]) catch return null
        else
            return null,
        .load_const => if (inst.aux < program.constants.items.len) switch (program.constants.items[inst.aux]) {
            .integer => |n| @floatFromInt(n),
            .number_bits => |bits| @bitCast(bits),
            .number => |sid| if (sid < program.strings.items.len)
                exec.Vm.parseLuaNumber(program.strings.items[sid]) catch return null
            else
                return null,
            else => return null,
        } else return null,
        else => return null,
    };
    return static_key.refForNumber(number);
}
fn mergePhi(analysis: *const ssa.Function, refs: []const u32, phi: ssa.Phi) u32 {
    var selected: u32 = none;
    for (phi.inputs.items) |raw| {
        const id = analysis.canonicalValue(raw);
        if (id == phi.value) continue;
        if (id == ssa.invalid_value or id >= refs.len or refs[id] == none) return none;
        if (selected == none) selected = refs[id] else if (selected != refs[id]) return none;
    }
    return selected;
}

fn buildRefs(analysis: *const ssa.Function, program: *const ir.Program, function: *const ir.Function, refs: []u32) void {
    @memset(refs, none);
    for (analysis.values.items, 0..) |node, id| {
        if (literalRef(program, function, node)) |ref| refs[id] = ref;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (analysis.phis.items) |phi| {
            const id = analysis.canonicalValue(phi.value);
            if (id != phi.value or refs[id] != none) continue;
            const ref = mergePhi(analysis, refs, phi);
            if (ref != none) {
                refs[id] = ref;
                changed = true;
            }
        }
    }
}

fn refForReg(analysis: *const ssa.Function, refs: []const u32, state: []const ssa.ValueId, reg: u32) ?u32 {
    if (reg >= state.len or analysis.captured[reg]) return null;
    const id = analysis.canonicalValue(state[reg]);
    if (id == ssa.invalid_value or id >= refs.len or refs[id] == none) return null;
    return refs[id];
}
fn hasIndex(function: *const ir.Function) bool {
    for (function.insts.items) |inst| switch (inst.op) {
        .get_index, .set_index, .table_set => return true,
        else => {},
    };
    return false;
}

fn runFunction(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function) !Stats {
    if (!hasIndex(function)) return .{};
    var analysis = try ssa.build(allocator, program, function);
    defer analysis.deinit();
    const refs = try allocator.alloc(u32, analysis.values.items.len);
    defer if (refs.len != 0) allocator.free(refs);
    buildRefs(&analysis, program, function, refs);
    const state = try allocator.alloc(ssa.ValueId, function.reg_count);
    defer if (state.len != 0) allocator.free(state);
    var stats = Stats{};
    for (analysis.graph.blocks.items, 0..) |block, block_id| {
        const entry = analysis.entry_states[block_id] orelse continue;
        @memcpy(state, entry);
        for (block.start..block.end) |pc_usize| {
            const pc: u32 = @intCast(pc_usize);
            const inst = &function.insts.items[pc];
            if (inst.op == .get_index or inst.op == .set_index or inst.op == .table_set) {
                if (refForReg(&analysis, refs, state, inst.b)) |ref| {
                    inst.aux = ref;
                    if (inst.op == .get_index) {
                        inst.op = .get_slot;
                        stats.reads += 1;
                    } else {
                        inst.op = .set_slot;
                        stats.writes += 1;
                    }
                }
            }
            try ssa.applyWrites(&analysis, function, state, pc, null);
        }
    }
    return stats;
}
pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    if (program.references_lowered) return error.LateStaticIndexAnalysis;
    var stats = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*function| {
        const one = try runFunction(allocator, program, function);
        stats.reads += one.reads;
        stats.writes += one.writes;
    };
    return stats;
}

const lua = @import("root.zig");
const stdlib = @import("lua_stdlib.zig");

fn execute(source: []const u8) !struct { program: ir.Program, values: []const exec.Value, arena: std.heap.ArenaAllocator, stats: Stats } {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, source);
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    errdefer program.deinit();
    const stats = try run(a, &program);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    try stdlib.install(&vm);
    const values = try vm.executeRoot(&program, &.{});
    return .{ .program = program, .values = values, .arena = arena, .stats = stats };
}

test "constant numeric indexes become guarded static key refs" {
    var result = try execute("local t={};local k=1;t[k]=4;return t[1]");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 1), result.stats.reads);
    try std.testing.expectEqual(@as(u64, 1), result.stats.writes);
    try std.testing.expectEqual(@as(f64, 4), result.values[0].number);
    var refs_seen: u32 = 0;
    for (result.program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| {
            if ((inst.op == .get_slot or inst.op == .set_slot) and static_key.integerForRef(inst.aux) != null)
                refs_seen += 1;
        }
    };
    try std.testing.expectEqual(@as(u32, 2), refs_seen);
}

test "static numeric read preserves index metamethod fallback" {
    var result = try execute("local t=setmetatable({},{__index=function(_,k)return k+10 end});return t[2]");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 1), result.stats.reads);
    try std.testing.expectEqual(@as(f64, 12), result.values[0].number);
}

test "static numeric write preserves newindex metamethod fallback" {
    var result = try execute("local seen=0;local t=setmetatable({},{__newindex=function(_,k,v)seen=k+v end});t[2]=7;return seen");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expectEqual(@as(u64, 1), result.stats.writes);
    try std.testing.expectEqual(@as(f64, 9), result.values[0].number);
}

test "equal numeric branch keys merge to one static ref" {
    var result = try execute("local x=...;local k;if x then k=1 else k=1 end;local t={};t[1]=7;return t[k]");
    defer result.program.deinit();
    defer result.arena.deinit();
    defer exec.Vm.freeResults(result.values);
    try std.testing.expect(result.stats.reads >= 1);
    try std.testing.expectEqual(@as(f64, 7), result.values[0].number);
}

test "unknown parameter keys remain generic indexes" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local function get(t,k)return t[k] end;return get({[1]=4},1)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try run(a, &program);
    var dynamic: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| dynamic += @intFromBool(inst.op == .get_index);
    };
    try std.testing.expectEqual(@as(u32, 1), dynamic);
}

test "static numeric ref uses a shaped slot through an escaping helper" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local function get(t)return t[1] end;saved=get;local t={};t[1]=4;return get(t)");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try @import("vm_flow.zig").run(a, &program);
    _ = try @import("vm_shape_opt.zig").run(a, &program);
    const stats = try run(a, &program);
    try std.testing.expect(stats.reads >= 1);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 4), values[0].number);
}

test "noninteger and out of range numeric keys stay dynamic" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local t={};return t[1.5],t[600000000]");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    const stats = try run(a, &program);
    try std.testing.expectEqual(@as(u64, 0), stats.reads);
    var dynamic: u32 = 0;
    for (program.functions.items) |maybe| if (maybe) |function| {
        for (function.insts.items) |inst| dynamic += @intFromBool(inst.op == .get_index);
    };
    try std.testing.expectEqual(@as(u32, 2), dynamic);
}

test "static numeric write shares shaped raw storage" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local function put(t)t[1]=4 end;saved=put;local t={};t[1]=3;put(t);return t");
    defer chunk.deinit();
    var program = try ir.lowerChunk(a, &chunk);
    defer program.deinit();
    _ = try @import("vm_flow.zig").run(a, &program);
    _ = try @import("vm_shape_opt.zig").run(a, &program);
    const stats = try run(a, &program);
    try std.testing.expect(stats.writes >= 1);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&program, &.{});
    defer exec.Vm.freeResults(values);
    const table = values[0].table;
    try std.testing.expectEqual(@as(f64, 4), table.rawGet(.{ .number = 1 }).?.number);
    try std.testing.expectEqual(@as(usize, 1), table.rawLen());
}
