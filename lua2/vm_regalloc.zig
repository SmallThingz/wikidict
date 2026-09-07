const sem = @import("vm_semantics.zig");
const refs = @import("vm_ref.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const lua = @import("root.zig");
const exec = @import("vm_exec.zig");
const rt = @import("vm_runtime.zig");

const cfg = @import("vm_graph.zig");
const liveness = @import("vm_liveness.zig");
const none = std.math.maxInt(u32);

const Unit = struct {
    source_base: u32,
    width: u32,
    start: u64,
    end: u64,
    fixed: bool,
    physical_base: u32 = none,
};

const Active = struct { base: u32, width: u32, end: u64 };

pub const Stats = struct {
    before_regs: u64 = 0,
    after_regs: u64 = 0,
    removed_moves: u64 = 0,
};

fn readPos(pc: usize) u64 {
    return @as(u64, pc) * 2;
}
fn writePos(pc: usize) u64 {
    return @as(u64, pc) * 2 + 1;
}
fn touch(start: []u64, end: []u64, reg: u32, pos: u64) void {
    if (reg >= start.len) return;
    start[reg] = @min(start[reg], pos);
    end[reg] = @max(end[reg], pos);
}
fn markCaptured(allocator: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function) ![]bool {
    const captured = try allocator.alloc(bool, function.reg_count);
    @memset(captured, false);
    for (function.insts.items) |inst| if (sem.captureTarget(inst)) |target| {
        if (program.functions.items[target]) |child| for (child.upvalues.items) |upvalue| {
            if (upvalue.source == .local and upvalue.index < captured.len) captured[upvalue.index] = true;
        };
    };
    return captured;
}

fn noteBundle(owner: []u32, width: []u32, base: u32, count: u32) !void {
    if (count <= 1 or count == ir.multi_count) return;
    if (@as(u64, base) + count > owner.len) return error.BadRegisterRange;
    if (width[base] != 0 and width[base] != count) return error.OverlappingRegisterBundles;
    width[base] = count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const reg = base + i;
        if (owner[reg] != none and owner[reg] != base) return error.OverlappingRegisterBundles;
        owner[reg] = base;
    }
}

fn collectBundles(function: *const ir.Function, owner: []u32, width: []u32) !void {
    @memset(owner, none);
    @memset(width, 0);
    for (function.insts.items) |inst| switch (inst.op) {
        .vararg, .call, .call_vararg, .method_call, .method_call_vararg, .method_call_field, .method_call_field_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .direct_call, .direct_call_vararg, .generic_for_init, .generic_for_next => try noteBundle(owner, width, inst.dst, inst.count),
        else => {},
    };
}

fn lessUnit(_: void, a: Unit, b: Unit) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.fixed != b.fixed) return a.fixed;
    return a.source_base < b.source_base;
}

fn overlaps(a_base: u32, a_width: u32, b_base: u32, b_width: u32) bool {
    return @as(u64, a_base) < @as(u64, b_base) + b_width and @as(u64, b_base) < @as(u64, a_base) + a_width;
}

fn collides(active: []const Active, base: u32, width: u32) bool {
    for (active) |item| if (overlaps(base, width, item.base, item.width)) return true;
    return false;
}

fn buildMap(allocator: std.mem.Allocator, program: *const ir.Program, function: *const ir.Function) ![]u32 {
    const map = try allocator.alloc(u32, function.reg_count);
    errdefer allocator.free(map);
    @memset(map, none);
    if (function.reg_count == 0) return map;
    const start = try allocator.alloc(u64, function.reg_count);
    defer allocator.free(start);
    const end = try allocator.alloc(u64, function.reg_count);
    defer allocator.free(end);
    @memset(start, std.math.maxInt(u64));
    @memset(end, 0);
    var param: u32 = 0;
    while (param < function.param_count and param < function.reg_count) : (param += 1) touch(start, end, param, 0);
    var access = try sem.Bits.initEmpty(allocator, function.reg_count);
    defer access.deinit(allocator);
    for (function.insts.items, 0..) |inst, pc| {
        access.unsetAll();
        try sem.reads(program, function, inst, &access);
        inline for (sem.fields, 0..) |field, i| if (sem.info(inst.op).addresses & (@as(u8, 1) << i) != 0) {
            const reg_id = @field(inst, field);
            if (reg_id >= function.reg_count) return error.BadRegister;
            touch(start, end, reg_id, readPos(pc));
        };

        var reads = access.iterator(.{});
        while (reads.next()) |reg_id| touch(start, end, @intCast(reg_id), readPos(pc));
        access.unsetAll();
        try sem.writes(inst, null, &access);
        // Allocation reserves every possible definition, including edge-only
        // loop results. A definition starts a lifetime before its first read.
        if (sem.info(inst.op).target) {
            try sem.writes(inst, true, &access);
            try sem.writes(inst, false, &access);
        }
        var writes = access.iterator(.{});
        while (writes.next()) |reg_id| touch(start, end, @intCast(reg_id), writePos(pc));
    }

    // Header-only uses remain live through loop bodies and backedges.
    var graph = try cfg.build(allocator, function);
    defer graph.deinit();
    var live = try liveness.build(allocator, program, function, &graph);
    defer live.deinit();
    for (graph.blocks.items, 0..) |block, bid| {
        var inputs = live.live_in[bid].iterator(.{});
        while (inputs.next()) |r| touch(start, end, @intCast(r), readPos(block.start));
        for (block.succ) |maybe_succ| if (maybe_succ) |succ| {
            var outputs = live.live_in[succ].iterator(.{});
            while (outputs.next()) |r| touch(start, end, @intCast(r), writePos(block.end - 1));
        };
    }
    const captured = try markCaptured(allocator, program, function);
    defer allocator.free(captured);
    const owner = try allocator.alloc(u32, function.reg_count);
    defer allocator.free(owner);
    const widths = try allocator.alloc(u32, function.reg_count);
    defer allocator.free(widths);
    try collectBundles(function, owner, widths);

    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(allocator);
    var reg: u32 = 0;
    while (reg < function.reg_count) {
        if (owner[reg] != none and owner[reg] != reg) {
            reg += 1;
            continue;
        }
        const unit_width = if (owner[reg] == reg) widths[reg] else 1;
        if (reg < function.param_count and unit_width != 1) return error.ParameterBundleConflict;
        var unit_start: u64 = std.math.maxInt(u64);
        var unit_end: u64 = 0;
        var persistent = false;
        var i: u32 = 0;
        while (i < unit_width) : (i += 1) {
            unit_start = @min(unit_start, start[reg + i]);
            unit_end = @max(unit_end, end[reg + i]);
            persistent = persistent or captured[reg + i];
        }
        if (unit_start == std.math.maxInt(u64)) {
            reg += unit_width;
            continue;
        }
        if (persistent) {
            // A cell may survive a backedge before this binding is re-entered.
            // Its physical slot must not alias a different virtual binding.
            unit_start = 0;
            unit_end = @as(u64, function.insts.items.len) * 2 + 2;
        }

        try units.append(allocator, .{
            .source_base = reg,
            .width = unit_width,
            .start = unit_start,
            .end = unit_end,
            .fixed = reg < function.param_count,
        });
        reg += unit_width;
    }

    const preferred = try allocator.alloc(u32, function.reg_count);
    defer allocator.free(preferred);
    @memset(preferred, none);
    for (function.insts.items) |inst| {
        if (inst.op == .move and refs.isRegister(inst.a) and inst.a < preferred.len and
            inst.dst < preferred.len and preferred[inst.dst] == none)
            preferred[inst.dst] = inst.a;
    }
    std.sort.heap(Unit, units.items, {}, lessUnit);
    var active: std.ArrayList(Active) = .empty;
    defer active.deinit(allocator);
    var physical_count: u32 = 0;
    for (units.items) |*unit| {
        var index: usize = 0;
        while (index < active.items.len) {
            if (active.items[index].end < unit.start) {
                _ = active.swapRemove(index);
            } else {
                index += 1;
            }
        }
        var base: u32 = if (unit.fixed) unit.source_base else 0;
        // Prefer the dying source's storage, but never create interference.
        // This erases moves rather than merely reducing the frame size.
        if (!unit.fixed and unit.width == 1) {
            const source = preferred[unit.source_base];
            if (source != none and map[source] != none and !collides(active.items, map[source], 1))
                base = map[source];
        }
        if (unit.fixed) {
            if (collides(active.items, base, unit.width)) return error.FixedRegisterCollision;
        } else {
            while (collides(active.items, base, unit.width)) : (base += 1) {}
        }
        unit.physical_base = base;
        for (0..unit.width) |i| map[unit.source_base + i] = base + @as(u32, @intCast(i));
        physical_count = @max(physical_count, base + unit.width);
        try active.append(allocator, .{ .base = base, .width = unit.width, .end = unit.end });
    }
    for (units.items) |unit| {
        var i: u32 = 0;
        while (i < unit.width) : (i += 1) map[unit.source_base + i] = unit.physical_base + i;
    }
    return map;
}

fn mapReg(map: []const u32, reg: u32) !u32 {
    if (!refs.isRegister(reg)) return reg;
    if (reg >= map.len) return error.BadRegister;
    return if (map[reg] == none) 0 else map[reg];
}

fn remapInst(map: []const u32, inst: *ir.Inst) !void {
    const description = sem.info(inst.op);
    var mask = description.reads | description.addresses;
    if (description.defines or description.results) mask |= sem.dst;
    switch (inst.op) {
        .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => mask |= sem.dst,
        else => {},
    }
    inline for (sem.fields, 0..) |field, i| {
        if (mask & (@as(u8, 1) << i) != 0)
            @field(inst, field) = try mapReg(map, @field(inst, field));
    }
}

fn compactSelfMoves(allocator: std.mem.Allocator, function: *ir.Function) !u32 {
    const old_len = function.insts.items.len;
    const map = try allocator.alloc(u32, old_len + 1);
    defer allocator.free(map);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(allocator);
    var patches: std.ArrayList(struct { index: usize, target: u32 }) = .empty;
    defer patches.deinit(allocator);
    var removed: u32 = 0;
    for (function.insts.items, 0..) |inst, pc| {
        map[pc] = @intCast(out.items.len);
        if (inst.op == .move and inst.dst == inst.a) {
            removed += 1;
            continue;
        }
        const index = out.items.len;
        var copy = inst;
        const jump = switch (inst.op) {
            .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => true,
            else => false,
        };
        if (jump) {
            try patches.append(allocator, .{ .index = index, .target = inst.aux });
            copy.aux = 0;
        }
        try out.append(allocator, copy);
    }
    map[old_len] = @intCast(out.items.len);
    for (patches.items) |patch| {
        if (patch.target > old_len) return error.BadJumpTarget;
        out.items[patch.index].aux = map[patch.target];
    }
    function.insts.deinit(allocator);
    function.insts = out;
    return removed;
}

pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    const child_seen = try allocator.alloc(bool, program.functions.items.len);
    defer allocator.free(child_seen);
    for (program.functions.items) |*maybe_function| if (maybe_function.*) |*function| {
        stats.before_regs += function.reg_count;
        const map = try buildMap(allocator, program, function);
        defer allocator.free(map);
        @memset(child_seen, false);
        for (function.insts.items) |inst| if (sem.captureTarget(inst)) |target| {
            if (target >= program.functions.items.len) return error.BadFunctionReference;
            if (child_seen[target]) continue;
            child_seen[target] = true;
            if (program.functions.items[target]) |*child| for (child.upvalues.items) |*upvalue| {
                if (upvalue.source == .local) upvalue.index = try mapReg(map, upvalue.index);
            };
        };
        for (function.operands.items) |*reg| reg.* = try mapReg(map, reg.*);
        for (function.insts.items) |*inst| try remapInst(map, inst);
        var max_reg: u32 = 0;
        for (map) |physical| if (physical != none) {
            max_reg = @max(max_reg, physical + 1);
        };
        function.reg_count = max_reg;
        stats.after_regs += function.reg_count;
        stats.removed_moves += try compactSelfMoves(allocator, function);
    };
    return stats;
}

fn expectSame(source: []const u8) !void {
    var chunk_a = try lua.parse(std.testing.allocator, source);
    defer chunk_a.deinit();
    var chunk_b = try lua.parse(std.testing.allocator, source);
    defer chunk_b.deinit();
    var baseline = try ir.lowerChunk(std.testing.allocator, &chunk_a);
    defer baseline.deinit();
    var optimized = try ir.lowerChunk(std.testing.allocator, &chunk_b);
    defer optimized.deinit();
    _ = try run(std.testing.allocator, &optimized);
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    var vm_a = try exec.Vm.init(arena_a.allocator());
    var vm_b = try exec.Vm.init(arena_b.allocator());
    const a = try vm_a.executeRoot(&baseline, &.{});
    defer exec.Vm.freeResults(a);
    const b = try vm_b.executeRoot(&optimized, &.{});
    defer exec.Vm.freeResults(b);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |lhs, rhs| try std.testing.expect(rt.rawEqual(lhs, rhs));
}

test "register allocator reuses sequential temporary slots" {
    var program = ir.Program{ .allocator = std.testing.allocator };
    defer program.deinit();
    var function = ir.Function{ .reg_count = 4 };
    try function.insts.appendSlice(std.testing.allocator, &.{
        .{ .op = .load_bool, .dst = 0, .a = 1 },
        .{ .op = .not_, .dst = 1, .a = 0 },
        .{ .op = .not_, .dst = 2, .a = 1 },
        .{ .op = .not_, .dst = 3, .a = 2 },
        .{ .op = .ret, .count = 0 },
    });
    try program.functions.append(std.testing.allocator, function);
    const stats = try run(std.testing.allocator, &program);
    try std.testing.expect(stats.after_regs < stats.before_regs);
}

test "register allocator preserves multi-result contiguity" {
    try expectSame(
        \\local function pair() return 1, 2 end
        \\local a, b = pair()
        \\return a, b
    );
}

test "register allocator preserves captured cells" {
    try expectSame(
        \\local x = 1
        \\local function get() return x end
        \\x = 4
        \\return get(), x
    );
}

test "move destination prefers a dying source over a lower free slot" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    var f = ir.Function{ .param_count = 3, .reg_count = 4 };
    try f.operands.append(a, 3);
    try f.insts.appendSlice(a, &.{
        .{ .op = .move, .dst = 3, .a = 2 },
        .{ .op = .ret, .aux = 0, .count = 1 },
    });
    try p.functions.append(a, f);
    const stats = try run(a, &p);
    try std.testing.expectEqual(@as(u64, 1), stats.removed_moves);
    try std.testing.expectEqual(@as(usize, 1), p.functions.items[0].?.insts.items.len);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 3), out[0].number);
}

test "every specialized result starts its lifetime at its definition" {
    const a = std.testing.allocator;
    inline for (@typeInfo(ir.Opcode).@"enum".fields) |field| {
        if (comptime (std.mem.endsWith(u8, field.name, "_number") and !std.mem.eql(u8, field.name, "load_number")) or std.mem.eql(u8, field.name, "len_string")) {
            const op: ir.Opcode = @enumFromInt(field.value);
            var p = ir.Program{ .allocator = a };
            defer p.deinit();
            try p.constants.append(a, .{ .number_bits = @bitCast(@as(f64, 99)) });
            var f = ir.Function{ .param_count = 2, .reg_count = 4 };
            try f.operands.append(a, 2);
            try f.insts.appendSlice(a, &.{
                sem.canonical(.{ .op = op, .dst = 2, .a = 0, .b = 1 }),
                .{ .op = .load_const, .dst = 3, .aux = 0 },
                .{ .op = .jump_if_false, .a = 3, .aux = 3 },
                .{ .op = .ret, .aux = 0, .count = 1 },
            });
            try p.functions.append(a, f);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var vm = try exec.Vm.init(arena.allocator());
            const args = [_]rt.Value{ if (op == .len_string) .{ .string = "abcd" } else .{ .number = 7 }, .{ .number = 2 } };
            const expected = try vm.executeRoot(&p, &args);
            defer exec.Vm.freeResults(expected);
            _ = try run(a, &p);
            const actual = try vm.executeRoot(&p, &args);
            defer exec.Vm.freeResults(actual);
            try std.testing.expect(rt.rawEqual(expected[0], actual[0]));
        }
    }
}
