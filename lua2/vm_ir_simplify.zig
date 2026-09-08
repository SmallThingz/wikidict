const refs = @import("vm_ref.zig");
fn markStringReference(used: []bool, value: u32) !u32 {
    if (refs.tag(value) == .string) {
        if (refs.index(value) >= used.len) return error.BadStringReference;
        used[refs.index(value)] = true;
    }
    return value;
}
const std = @import("std");
const ir = @import("vm_ir.zig");
const shape_key = @import("vm_shape_key.zig");
const sem = @import("vm_semantics.zig");
const cfg = @import("vm_graph.zig");
const liveness = @import("vm_liveness.zig");

pub const Stats = struct {
    removed_instructions: u32 = 0,
    removed_operands: u32 = 0,
    removed_strings: u32 = 0,
};

fn compactInstructions(allocator: std.mem.Allocator, function: *ir.Function, remove: []const bool) !u32 {
    const old_len = function.insts.items.len;
    const remap = try allocator.alloc(u32, old_len + 1);
    defer allocator.free(remap);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(allocator);
    for (function.insts.items, 0..) |inst, pc| {
        remap[pc] = @intCast(out.items.len);
        if (!remove[pc]) try out.append(allocator, inst);
    }
    remap[old_len] = @intCast(out.items.len);
    for (out.items) |*inst| switch (inst.op) {
        .jump, .jump_if_false, .branch_compare, .numeric_for_init, .numeric_for_next, .generic_for_init, .generic_for_next => {
            if (inst.aux > old_len) return error.BadJump;
            inst.aux = remap[inst.aux];
        },
        else => {},
    };
    var removed: u32 = 0;
    for (remove) |dead| removed += @intFromBool(dead);
    function.insts.deinit(allocator);
    function.insts = out;
    return removed;
}
fn pure(program: *const ir.Program, inst: ir.Inst) bool {
    return switch (inst.op) {
        .load_nil, .load_bool, .load_string, .get_global, .get_global_slot, .get_upvalue, .new_table, .new_table_shape, .vararg, .move, .not_, .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number, .neg_number, .len_string => true,
        .load_const => program.constants.items[inst.aux] != .table,
        .closure => program.functions.items[inst.aux].?.upvalues.items.len == 0,
        .load_function => true,
        else => false,
    };
}
fn removeDeadPure(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function) !u32 {
    var total: u32 = 0;
    var captured = try sem.Bits.initEmpty(allocator, function.reg_count);
    defer captured.deinit(allocator);
    for (function.insts.items) |inst| if (sem.captureTarget(inst)) |target| {
        const child = program.functions.items[target] orelse return error.IncompleteProgram;
        for (child.upvalues.items) |up| if (up.source == .local) {
            captured.set(up.index);
        };
    };
    var current = try sem.Bits.initEmpty(allocator, function.reg_count);
    defer current.deinit(allocator);
    var defs = try sem.Bits.initEmpty(allocator, function.reg_count);
    defer defs.deinit(allocator);
    var needed = try sem.Bits.initEmpty(allocator, function.reg_count);
    defer needed.deinit(allocator);
    while (true) {
        var graph = try cfg.build(allocator, function);
        defer graph.deinit();
        var live = try liveness.build(allocator, program, function, &graph);
        defer live.deinit();
        const remove = try allocator.alloc(bool, function.insts.items.len);
        defer allocator.free(remove);
        @memset(remove, false);
        var any = false;
        for (graph.blocks.items, 0..) |block, bid| {
            _ = bid;
            current.unsetAll();
            current.setUnion(captured);
            for (block.succ) |succ| if (succ) |s| current.setUnion(live.live_in[s]);
            var pc: usize = block.end;
            while (pc > block.start) {
                pc -= 1;
                const inst = function.insts.items[pc];
                defs.unsetAll();
                try sem.writes(inst, null, &defs);
                needed.unsetAll();
                needed.setUnion(defs);
                needed.setIntersection(current);
                if (pure(program, inst) and needed.count() == 0) {
                    remove[pc] = true;
                    any = true;
                    continue;
                }
                defs.toggleAll();
                current.setIntersection(defs);
                try sem.reads(program, function, inst, &current);
                current.setUnion(captured);
            }
        }
        if (!any) break;
        total += try compactInstructions(allocator, function, remove);
    }
    return total;
}

fn operandCount(inst: ir.Inst) ?u32 {
    return switch (inst.op) {
        .concat, .ret, .ret_var => inst.count,
        .call, .call_vararg, .method_call, .method_call_vararg, .call_scoped, .call_scoped_vararg, .call_local, .call_local_vararg, .direct_call, .direct_call_vararg, .method_call_field, .method_call_field_vararg => inst.b,
        else => null,
    };
}

fn findSlice(haystack: []const u32, needle: []const u32) ?u32 {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.mem.eql(u32, haystack[start .. start + needle.len], needle)) return @intCast(start);
    }
    return null;
}

fn suffixOverlap(haystack: []const u32, needle: []const u32) usize {
    var n = @min(haystack.len, needle.len);
    while (n != 0) : (n -= 1) {
        if (std.mem.eql(u32, haystack[haystack.len - n ..], needle[0..n])) return n;
    }
    return 0;
}
fn compactOperands(allocator: std.mem.Allocator, function: *ir.Function) !u32 {
    const old_len = function.operands.items.len;
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    for (function.insts.items) |*inst| {
        const count = operandCount(inst.*) orelse continue;
        if (@as(usize, inst.aux) + count > function.operands.items.len) return error.BadOperandRange;
        const slice = function.operands.items[inst.aux .. inst.aux + count];
        if (findSlice(out.items, slice)) |at| {
            inst.aux = at;
            continue;
        }
        const overlap = suffixOverlap(out.items, slice);
        const at: u32 = @intCast(out.items.len - overlap);
        try out.appendSlice(allocator, slice[overlap..]);
        inst.aux = at;
    }
    function.operands.deinit(allocator);
    function.operands = out;
    return @intCast(old_len - function.operands.items.len);
}
pub fn compactStrings(allocator: std.mem.Allocator, program: *ir.Program) !u32 {
    const used = try allocator.alloc(bool, program.strings.items.len);
    defer allocator.free(used);
    @memset(used, false);
    for (program.functions.items) |maybe_function| if (maybe_function) |function| {
        for (function.insts.items) |inst| switch (inst.op) {
            .load_number, .load_string, .get_global, .set_global => {
                if (inst.aux >= used.len) return error.BadStringReference;
                used[inst.aux] = true;
            },
            .get_field, .set_field => {
                if (inst.aux >= used.len) return error.BadStringReference;
                used[inst.aux] = true;
            },
            .method_call_field, .method_call_field_vararg => {
                if (inst.a >= used.len) return error.BadStringReference;
                used[inst.a] = true;
            },
            else => {},
        };
    };
    for (program.functions.items) |*maybe| if (maybe.*) |*f| try refs.visit(f, used, markStringReference);
    for (program.shapes.items) |shape| for (shape.field_keys.items) |key| {
        if (shape_key.stringId(key)) |sid| {
            if (sid >= used.len) return error.BadStringReference;
            used[sid] = true;
        }
    };
    for (program.constants.items) |node| switch (node) {
        .number, .string => |sid| {
            if (sid >= used.len) return error.BadStringReference;
            used[sid] = true;
        },
        else => {},
    };
    const remap = try allocator.alloc(u32, used.len);
    defer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (used, 0..) |keep, old| if (keep) {
        remap[old] = @intCast(out.items.len);
        try out.append(allocator, program.strings.items[old]);
    };
    for (program.functions.items) |*maybe_function| if (maybe_function.*) |*function| {
        for (function.insts.items) |*inst| switch (inst.op) {
            .load_number, .load_string, .get_global, .set_global => inst.aux = remap[inst.aux],
            .get_field, .set_field => inst.aux = remap[inst.aux],
            .method_call_field, .method_call_field_vararg => inst.a = remap[inst.a],
            else => {},
        };
    };
    for (program.shapes.items) |*shape| for (shape.field_keys.items) |*key| {
        if (shape_key.stringId(key.*)) |sid| key.* = try shape_key.string(remap[sid]);
    };
    for (program.constants.items) |*node| switch (node.*) {
        .number => |sid| node.* = .{ .number = remap[sid] },
        .string => |sid| node.* = .{ .string = remap[sid] },
        else => {},
    };
    for (program.functions.items) |*maybe| if (maybe.*) |*f| try refs.visit(f, @as([]const u32, remap), refs.remapString);
    const removed: u32 = @intCast(program.strings.items.len - out.items.len);
    program.strings.deinit(allocator);
    program.strings = out;
    program.interned_strings.deinit(allocator);
    program.interned_strings = .empty;
    for (program.strings.items, 0..) |text, sid| {
        try program.interned_strings.put(allocator, text, @intCast(sid));
    }
    return removed;
}
pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var stats = Stats{};
    for (program.functions.items) |*maybe_function| if (maybe_function.*) |*function| {
        stats.removed_instructions += try removeDeadPure(allocator, program, function);
        stats.removed_operands += try compactOperands(allocator, function);
    };
    stats.removed_strings = try compactStrings(allocator, program);
    return stats;
}

const lua = @import("root.zig");

test "simplifier removes dead values and their strings" {
    var chunk = try lua.parse(std.testing.allocator, "local dead='dead-name'; return 'live-value'");
    defer chunk.deinit();
    var program = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer program.deinit();
    const before = program.strings.items.len;
    const stats = try run(std.testing.allocator, &program);
    try std.testing.expect(stats.removed_instructions != 0);
    try std.testing.expect(stats.removed_strings != 0);
    try std.testing.expect(program.strings.items.len < before);
    for (program.strings.items) |text| try std.testing.expect(!std.mem.eql(u8, text, "dead-name"));
}
