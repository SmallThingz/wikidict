const std = @import("std");
const ir = @import("ir.zig");
const cfg = @import("graph.zig");
const sem = @import("semantics.zig");
const numbers = @import("numbers.zig");

pub const nil_type: u8 = 1;
pub const bool_type: u8 = 2;
pub const number_type: u8 = 4;
pub const string_type: u8 = 8;
pub const table_type: u8 = 16;
pub const function_type: u8 = 32;
pub const any_type: u8 = 63;
pub const Range = struct { low: f64, high: f64 };
pub const Literal = union(enum) { none, nil, boolean: bool, number: u64, string: u32 };
const Scalar = union(enum) { nil, boolean: bool, number: f64, string: []const u8 };
pub const Fact = struct {
    types: u8 = any_type,
    literal: Literal = .none,
    integer_range: ?Range = null,
};
pub const Stats = struct { folded: u64 = 0, branches: u64 = 0, removed_control: u64 = 0, specialized: u64 = 0 };
fn number(n: f64) Fact {
    return .{ .types = number_type, .literal = .{ .number = @bitCast(n) }, .integer_range = if (std.math.isFinite(n) and @floor(n) == n and @abs(n) <= 9007199254740991.0) .{ .low = n, .high = n } else null };
}
fn boolean(v: bool) Fact {
    return .{ .types = bool_type, .literal = .{ .boolean = v } };
}
fn string(sid: u32) Fact {
    return .{ .types = string_type, .literal = .{ .string = sid } };
}
pub fn merge(lhs: Fact, rhs: Fact, widen: bool) Fact {
    var out = Fact{ .types = lhs.types | rhs.types };
    if (std.meta.eql(lhs.literal, rhs.literal)) out.literal = lhs.literal;
    if (lhs.integer_range) |x| if (rhs.integer_range) |y| {
        const r = Range{ .low = @min(x.low, y.low), .high = @max(x.high, y.high) };
        if (!widen or (r.low >= x.low and r.high <= x.high)) out.integer_range = r;
    };
    return out;
}
pub fn truth(fact: Fact) ?bool {
    return switch (fact.literal) {
        .nil => false,
        .boolean => |v| v,
        .number, .string => true,
        .none => if (fact.types == nil_type) false else if (fact.types & (nil_type | bool_type) == 0) true else null,
    };
}
fn scalar(program: *const ir.Program, fact: Fact) ?Scalar {
    return switch (fact.literal) {
        .none => null,
        .nil => .nil,
        .boolean => |v| .{ .boolean = v },
        .number => |bits| .{ .number = @bitCast(bits) },
        .string => |sid| if (sid < program.strings.items.len) .{ .string = program.strings.items[sid] } else null,
    };
}
fn numeric(program: *const ir.Program, fact: Fact) ?f64 {
    const value = scalar(program, fact) orelse return null;
    return switch (value) {
        .number => |n| n,
        .string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}
fn scalarEqual(a: Scalar, b: Scalar) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nil => true,
        .boolean => |v| v == b.boolean,
        .number => |v| v == b.number,
        .string => |v| std.mem.eql(u8, v, b.string),
    };
}
fn scalarCompare(op: ir.Opcode, a: Scalar, b: Scalar) !bool {
    if (op == .eq or op == .ne) {
        const equal = scalarEqual(a, b);
        return if (op == .eq) equal else !equal;
    }
    if (a == .number and b == .number) return switch (op) {
        .lt => a.number < b.number,
        .le => a.number <= b.number,
        .gt => a.number > b.number,
        .ge => a.number >= b.number,
        else => unreachable,
    };
    if (a == .string and b == .string) {
        const order = std.mem.order(u8, a.string, b.string);
        return switch (op) {
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
            else => unreachable,
        };
    }
    return error.CompareType;
}
fn read(state: []const Fact, captured: []const bool, reg: u32) Fact {
    return if (reg >= state.len or captured[reg]) .{} else state[reg];
}
pub fn generic(op: ir.Opcode) ir.Opcode {
    return switch (op) {
        .add_number => .add,
        .sub_number => .sub,
        .mul_number => .mul,
        .div_number => .div,
        .mod_number => .mod,
        .pow_number => .pow,
        .eq_number => .eq,
        .ne_number => .ne,
        .lt_number => .lt,
        .le_number => .le,
        .gt_number => .gt,
        .ge_number => .ge,
        .neg_number => .neg,
        .len_string => .len,
        else => op,
    };
}
fn arithmetic(program: *const ir.Program, op: ir.Opcode, x: Fact, y: Fact) Fact {
    if (numeric(program, x)) |nx| if (numeric(program, y)) |ny| {
        const value = switch (op) {
            .add => nx + ny,
            .sub => nx - ny,
            .mul => nx * ny,
            .div => nx / ny,
            .mod => nx - @floor(nx / ny) * ny,
            .pow => std.math.pow(f64, nx, ny),
            else => unreachable,
        };
        return number(value);
    };
    const coercible = number_type | string_type;
    if (x.types & ~coercible != 0 or y.types & ~coercible != 0) return .{};
    var result = Fact{ .types = number_type };
    if (x.integer_range) |rx| if (y.integer_range) |ry| {
        var r: Range = undefined;
        switch (op) {
            .add => r = .{ .low = rx.low + ry.low, .high = rx.high + ry.high },
            .sub => r = .{ .low = rx.low - ry.high, .high = rx.high - ry.low },
            .mul => {
                const vals = [_]f64{ rx.low * ry.low, rx.low * ry.high, rx.high * ry.low, rx.high * ry.high };
                r = .{ .low = vals[0], .high = vals[0] };
                for (vals) |v| {
                    r.low = @min(r.low, v);
                    r.high = @max(r.high, v);
                }
            },
            else => return result,
        }
        if (@abs(r.low) <= 9007199254740991.0 and @abs(r.high) <= 9007199254740991.0) result.integer_range = r;
    };
    return result;
}
fn evaluate(allocator: std.mem.Allocator, program: *ir.Program, f: *const ir.Function, captured: []const bool, state: []const Fact, inst: ir.Inst) !Fact {
    const x = read(state, captured, inst.a);
    const y = read(state, captured, inst.b);
    const op = generic(inst.op);
    return switch (op) {
        .load_nil => .{ .types = nil_type, .literal = .nil },
        .load_bool => boolean(inst.a != 0),
        .load_string => string(inst.aux),
        .load_number => number(numbers.parse(program.strings.items[inst.aux]) catch return .{}),
        .load_const => switch (program.constants.items[inst.aux]) {
            .nil => .{ .types = nil_type, .literal = .nil },
            .boolean => |v| boolean(v),
            .string => |sid| string(sid),
            .number => |sid| number(numbers.parse(program.strings.items[sid]) catch return .{}),
            .number_bits => |bits| number(@bitCast(bits)),
            .integer => |n| number(@floatFromInt(n)),
            .table => .{ .types = table_type },
        },
        .move => x,
        .new_table, .new_table_shape => .{ .types = table_type },
        .closure, .load_function => .{ .types = function_type },
        .not_ => if (truth(x)) |v| boolean(!v) else .{ .types = bool_type },
        .neg => if (numeric(program, x)) |n| number(-n) else if (x.types & ~(number_type | string_type) == 0) .{ .types = number_type } else .{},
        .len => if (x.literal == .string) number(@floatFromInt(program.strings.items[x.literal.string].len)) else .{ .types = number_type },
        .add, .sub, .mul, .div, .mod, .pow => arithmetic(program, op, x, y),
        .eq, .ne, .lt, .le, .gt, .ge => blk: {
            if (scalar(program, x)) |vx| if (scalar(program, y)) |vy| {
                if (scalarCompare(op, vx, vy)) |v| break :blk boolean(v) else |_| {}
            };
            if ((op == .eq or op == .ne) and x.types & y.types == 0) break :blk boolean(op == .ne);
            break :blk .{ .types = bool_type };
        },
        .concat => blk: {
            const regs = try sem.operands(f, inst);
            var all_constant = true;
            for (regs) |r| {
                const v = read(state, captured, r);
                if (v.types & ~(string_type | number_type) != 0) break :blk .{};
                all_constant = all_constant and v.literal == .string;
            }
            if (!all_constant) break :blk .{ .types = string_type };
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            for (regs) |r| {
                const part = program.strings.items[read(state, captured, r).literal.string];
                if (part.len > 1024 * 1024 -| text.items.len) break :blk .{ .types = string_type };
                try text.appendSlice(allocator, part);
            }
            break :blk string(try program.internOwned(text.items));
        },
        else => .{},
    };
}
fn set(state: []Fact, captured: []const bool, reg: u32, value: Fact) !void {
    if (reg >= state.len) return error.BadRegister;
    state[reg] = if (captured[reg]) .{} else value;
}
fn setRange(state: []Fact, captured: []const bool, base: u32, n: u32, value: Fact) !void {
    const width = if (n == ir.multi_count) 1 else n;
    for (0..width) |i| try set(state, captured, base + @as(u32, @intCast(i)), value);
}
fn transfer(allocator: std.mem.Allocator, program: *ir.Program, f: *const ir.Function, captured: []const bool, state: []Fact, inst: ir.Inst, taken: ?bool) !void {
    const description = sem.info(inst.op);
    if (description.defines) return set(state, captured, inst.dst, try evaluate(allocator, program, f, captured, state, inst));
    if (description.results) return setRange(state, captured, inst.dst, inst.count, .{});
    switch (inst.op) {
        .numeric_for_init => if (taken == false) {
            try set(state, captured, inst.dst, .{ .types = number_type });
        },
        .numeric_for_next => {
            try set(state, captured, inst.a, .{ .types = number_type });
            if (taken == true) try set(state, captured, inst.dst, .{ .types = number_type });
        },
        .generic_for_init, .generic_for_next => if (taken != null and taken.? == (inst.op == .generic_for_next)) {
            try set(state, captured, inst.c, .{});
            try setRange(state, captured, inst.dst, inst.count, .{});
        },
        else => {},
    }
}
pub const Analysis = struct {
    allocator: std.mem.Allocator,
    graph: cfg.Graph,
    captured: []bool,
    entry: []?[]Fact,
    pub fn deinit(self: *Analysis) void {
        for (self.entry) |state| if (state) |s| self.allocator.free(s);
        self.allocator.free(self.entry);
        self.allocator.free(self.captured);
        self.graph.deinit();
    }
};
pub fn analyze(allocator: std.mem.Allocator, program: *ir.Program, f: *const ir.Function, parameters: []const Fact) !Analysis {
    var graph = try cfg.build(allocator, f);
    errdefer graph.deinit();
    const captured = try allocator.alloc(bool, f.reg_count);
    errdefer allocator.free(captured);
    @memset(captured, false);
    for (f.insts.items) |inst| if (sem.captureTarget(inst)) |target| {
        const child = program.functions.items[target] orelse return error.IncompleteProgram;
        for (child.upvalues.items) |up| if (up.source == .local) {
            captured[up.index] = true;
        };
    };
    const entries = try allocator.alloc(?[]Fact, graph.blocks.items.len);
    @memset(entries, null);
    const out = Analysis{ .allocator = allocator, .graph = graph, .captured = captured, .entry = entries };
    var owned = true;
    errdefer if (owned) {
        for (entries) |entry| if (entry) |state| allocator.free(state);
        allocator.free(entries);
    };
    if (entries.len == 0) {
        owned = false;
        return out;
    }
    entries[0] = try allocator.alloc(Fact, f.reg_count);
    @memset(entries[0].?, .{});
    for (parameters[0..@min(parameters.len, f.param_count)], 0..) |fact, r| if (!captured[r]) {
        entries[0].?[r] = fact;
    };
    const queued = try allocator.alloc(bool, entries.len);
    defer allocator.free(queued);
    @memset(queued, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, 0);
    queued[0] = true;
    const state = try allocator.alloc(Fact, f.reg_count);
    defer allocator.free(state);
    const edge = try allocator.alloc(Fact, f.reg_count);
    defer allocator.free(edge);
    while (queue.pop()) |bid| {
        queued[bid] = false;
        @memcpy(state, entries[bid].?);
        const block = graph.blocks.items[bid];
        for (block.start..block.end) |pc| try transfer(allocator, program, f, captured, state, f.insts.items[pc], null);
        const last = f.insts.items[block.end - 1];
        const branch = if (last.op == .jump_if_false) truth(read(state, captured, last.a)) else null;
        for (block.succ) |maybe_succ| if (maybe_succ) |succ| {
            if (branch) |v| {
                const dest = if (v) block.end else last.aux;
                if (dest >= f.insts.items.len or graph.block_of_pc[dest] != succ) continue;
            }
            @memcpy(edge, state);
            const taken = sem.info(last.op).target and last.aux < f.insts.items.len and graph.block_of_pc[last.aux] == succ;
            if (sem.info(last.op).target) try transfer(allocator, program, f, captured, edge, last, taken);
            var changed = false;
            if (entries[succ]) |prior| {
                for (prior, edge) |*old, new| {
                    const joined = merge(old.*, new, succ <= bid);
                    if (!std.meta.eql(old.*, joined)) {
                        old.* = joined;
                        changed = true;
                    }
                }
            } else {
                entries[succ] = try allocator.dupe(Fact, edge);
                changed = true;
            }
            if (changed and !queued[succ]) {
                try queue.append(allocator, succ);
                queued[succ] = true;
            }
        };
    }
    owned = false;
    return out;
}
fn typed(op: ir.Opcode, x: Fact, y: Fact) ir.Opcode {
    if (x.types == string_type and op == .len) return .len_string;
    if (x.types == number_type and op == .neg) return .neg_number;
    if (x.types != number_type or y.types != number_type) return op;
    return switch (op) {
        .add => .add_number,
        .sub => .sub_number,
        .mul => .mul_number,
        .div => .div_number,
        .mod => .mod_number,
        .pow => .pow_number,
        .eq => .eq_number,
        .ne => .ne_number,
        .lt => .lt_number,
        .le => .le_number,
        .gt => .gt_number,
        .ge => .ge_number,
        else => op,
    };
}
fn load(program: *ir.Program, dst_reg: u32, literal: Literal) !ir.Inst {
    return switch (literal) {
        .nil => .{ .op = .load_nil, .dst = dst_reg },
        .boolean => |v| .{ .op = .load_bool, .dst = dst_reg, .a = @intFromBool(v) },
        .number => |bits| .{ .op = .load_const, .dst = dst_reg, .aux = try program.numberConstant(bits) },
        .string => |sid| .{ .op = .load_string, .dst = dst_reg, .aux = sid },
        .none => unreachable,
    };
}
fn validKey(program: *const ir.Program, fact: Fact) bool {
    if (fact.types & (nil_type | number_type) == 0 or fact.integer_range != null) return true;
    if (scalar(program, fact)) |value| return value != .nil and (value != .number or !std.math.isNan(value.number));
    return false;
}
pub fn rewrite(allocator: std.mem.Allocator, program: *ir.Program, f: *ir.Function, analysis: *const Analysis) !Stats {
    var stats = Stats{};
    const remap = try allocator.alloc(u32, f.insts.items.len + 1);
    defer allocator.free(remap);
    const state = try allocator.alloc(Fact, f.reg_count);
    defer allocator.free(state);
    var out: std.ArrayList(ir.Inst) = .empty;
    errdefer out.deinit(allocator);
    for (analysis.graph.blocks.items, 0..) |block, bid| {
        if (analysis.entry[bid]) |input| @memcpy(state, input) else {
            for (block.start..block.end) |pc| remap[pc] = @intCast(out.items.len);
            stats.removed_control += block.end - block.start;
            continue;
        }
        for (block.start..block.end) |pc| {
            remap[pc] = @intCast(out.items.len);
            const original = f.insts.items[pc];
            var inst = original;
            const x = read(state, analysis.captured, inst.a);
            const y = read(state, analysis.captured, inst.b);
            if (sem.info(inst.op).defines) {
                const value = try evaluate(allocator, program, f, analysis.captured, state, original);
                if (value.literal != .none and original.op != .move) {
                    inst = try load(program, inst.dst, value.literal);
                    if (!std.meta.eql(sem.canonical(original), inst)) stats.folded += 1;
                } else {
                    inst.op = typed(inst.op, x, y);
                    if (inst.op != original.op) stats.specialized += 1;
                }
            }
            if (original.op == .jump_if_false) if (truth(x)) |v| {
                inst = .{ .op = .jump, .aux = if (v) @intCast(pc + 1) else original.aux };
                stats.branches += 1;
            };
            if ((original.op == .get_index or original.op == .set_index or original.op == .table_set) and y.literal == .string) {
                inst.op = if (original.op == .get_index) .get_field else .set_field;
                inst.aux = y.literal.string;
                inst.b = 0;
                stats.specialized += 1;
            }
            if ((original.op == .method_call or original.op == .method_call_vararg) and original.b >= 2) {
                const args = try sem.operands(f, original);
                const key = read(state, analysis.captured, args[0]);
                if (key.literal == .string) {
                    inst.op = if (original.op == .method_call) .method_call_field else .method_call_field_vararg;
                    inst.a = key.literal.string;
                    inst.aux += 1;
                    inst.b -= 1;
                    stats.specialized += 1;
                }
            }
            try transfer(allocator, program, f, analysis.captured, state, original, null);
            if (original.op == .check_table_key and validKey(program, x)) {
                stats.folded += 1;
                continue;
            }
            if ((inst.op == .jump or inst.op == .jump_if_false) and inst.aux == pc + 1) {
                stats.removed_control += 1;
                continue;
            }
            try out.append(allocator, sem.canonical(inst));
        }
    }
    remap[f.insts.items.len] = @intCast(out.items.len);
    for (out.items) |*inst| if (sem.info(inst.op).target) {
        inst.aux = remap[inst.aux];
    };
    f.insts.deinit(allocator);
    f.insts = out;
    return stats;
}
pub fn run(allocator: std.mem.Allocator, program: *ir.Program) !Stats {
    var total = Stats{};
    for (program.functions.items) |*maybe| if (maybe.*) |*f| {
        var analysis = try analyze(allocator, program, f, &.{});
        defer analysis.deinit();
        const stats = try rewrite(allocator, program, f, &analysis);
        inline for (@typeInfo(Stats).@"struct".fields) |field| @field(total, field.name) += @field(stats, field.name);
    };
    return total;
}

pub fn stateBefore(allocator: std.mem.Allocator, program: *ir.Program, f: *const ir.Function, analysis: *const Analysis, pc: u32, state: []Fact) !void {
    if (pc >= f.insts.items.len or state.len != f.reg_count) return error.BadState;
    const bid = analysis.graph.block_of_pc[pc];
    const entry = analysis.entry[bid] orelse return error.UnreachableBlock;
    @memcpy(state, entry);
    for (analysis.graph.blocks.items[bid].start..pc) |prior| try transfer(allocator, program, f, analysis.captured, state, f.insts.items[prior], null);
}
