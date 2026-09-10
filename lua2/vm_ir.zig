const std = @import("std");
const global_abi = @import("vm_global_abi.zig");
const lua = @import("root.zig");

pub const multi_count: u32 = std.math.maxInt(u32);

pub const Opcode = enum(u8) {
    load_nil,
    load_bool,
    load_number,
    load_string,
    load_const,
    get_global,
    set_global,
    get_upvalue,
    set_upvalue,
    move,
    vararg,
    new_table,
    table_set,
    table_append,
    table_append_var,
    get_index,
    set_index,
    closure,
    neg,
    not_,
    len,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    jump,
    jump_if_false,
    call,
    call_vararg,
    method_call,
    method_call_vararg,
    numeric_for_init,
    numeric_for_next,
    generic_for_init,
    generic_for_next,
    ret,
    ret_var,
    init_module,
    register_function,
    direct_call,
    direct_call_vararg,
    get_field,
    set_field,
    method_call_field,
    method_call_field_vararg,
    new_table_shape,
    get_slot,
    set_slot,
    get_choice_slot,
    set_choice_slot,
    add_number,
    sub_number,
    mul_number,
    div_number,
    mod_number,
    pow_number,
    eq_number,
    ne_number,
    lt_number,
    le_number,
    gt_number,
    ge_number,
    neg_number,
    len_string,
    check_table_key,
    branch_compare,
    detach_cell,
    get_global_slot,
    set_global_slot,
    call_local,
    call_local_vararg,
    call_scoped,
    call_scoped_vararg,
    load_function,
};

pub const Inst = struct {
    op: Opcode,
    dst: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    aux: u32 = 0,
    count: u32 = 0,
    aot_hint: u32 = 0, // compiler-only; never serialized
};

pub const no_shape: u32 = std.math.maxInt(u32);
pub const ConstNode = union(enum) {
    nil,
    boolean: bool,
    number: u32, // legacy source spelling; removed by final scalar compaction
    number_bits: u64,
    string: u32,
    integer: u32,
    table: struct { first: u32, count: u32, shape: u32 = no_shape },
};
pub const implicit_list_key: u32 = std.math.maxInt(u32);
pub const ConstEntry = struct { key: u32, value: u32 };

pub const Shape = struct {
    field_count: u32 = 0,
    field_keys: std.ArrayList(u32) = .empty,
    choice_count: u32 = 0,
    open: bool = false,

    pub fn deinit(self: *Shape, a: std.mem.Allocator) void {
        self.field_keys.deinit(a);
    }
};

pub const UpvalueSource = enum(u8) { local, upvalue };
pub const Upvalue = struct { source: UpvalueSource, index: u32 };

pub const Function = struct {
    source_start: u32 = 0,
    source_end: u32 = 0,
    param_count: u32 = 0,
    is_vararg: bool = false,
    reg_count: u32 = 0,
    upvalues: std.ArrayList(Upvalue) = .empty,
    operands: std.ArrayList(u32) = .empty,
    insts: std.ArrayList(Inst) = .empty,

    pub fn deinit(self: *Function, a: std.mem.Allocator) void {
        self.upvalues.deinit(a);
        self.operands.deinit(a);
        self.insts.deinit(a);
    }
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    folded_numbers: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    interned_strings: std.StringHashMapUnmanaged(u32) = .empty,
    functions: std.ArrayList(?Function) = .empty,
    constants: std.ArrayList(ConstNode) = .empty,
    const_entries: std.ArrayList(ConstEntry) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    module_roots: std.ArrayList(u32) = .empty,
    function_modules: std.ArrayList(u32) = .empty,
    root_function: u32 = 0,
    global_shape: ?u32 = null,
    references_lowered: bool = false, // compiler phase, not runtime type metadata

    pub fn deinit(self: *Program) void {
        for (self.functions.items) |*maybe| if (maybe.*) |*f| f.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.const_entries.deinit(self.allocator);
        for (self.shapes.items) |*shape| shape.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.module_roots.deinit(self.allocator);
        self.function_modules.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        for (self.owned_strings.items) |text| self.allocator.free(text);
        self.owned_strings.deinit(self.allocator);
        self.folded_numbers.deinit(self.allocator);
        self.interned_strings.deinit(self.allocator);
    }

    pub fn internOwned(self: *Program, text: []const u8) !u32 {
        if (self.interned_strings.get(text)) |id| return id;
        const owned = try self.allocator.dupe(u8, text);
        self.owned_strings.append(self.allocator, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        return self.intern(owned);
    }
    fn internTaking(self: *Program, text: []u8) !u32 {
        if (self.interned_strings.get(text)) |id| {
            self.allocator.free(text);
            return id;
        }
        self.owned_strings.append(self.allocator, text) catch |err| {
            self.allocator.free(text);
            return err;
        };
        return self.intern(text);
    }
    pub fn numberConstant(self: *Program, bits: u64) !u32 {
        if (self.folded_numbers.get(bits)) |id| return id;
        const id: u32 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, .{ .number_bits = bits });
        try self.folded_numbers.put(self.allocator, bits, id);
        return id;
    }
    fn intern(self: *Program, s: []const u8) !u32 {
        if (self.interned_strings.get(s)) |id| return id;
        const id: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, s);
        try self.interned_strings.put(self.allocator, s, id);
        return id;
    }
};

pub const CompileError = error{
    TooManyRegisters,
    TooManyOperands,
    TooManyFunctions,
    TooManyUpvalues,
    InvalidBreak,
} || std.mem.Allocator.Error;

const Capture = union(enum) { global, local: u32, upvalue: u32 };
const BindingSave = struct { name: []const u8, previous: ?u32 };
const BreakFrame = struct { patches: std.ArrayList(usize) = .empty };

const Lowerer = struct {
    allocator: std.mem.Allocator,
    program: *Program,
    parent: ?*Lowerer,
    function: Function,
    locals: std.StringHashMapUnmanaged(u32) = .empty,
    binding_saves: std.ArrayList(BindingSave) = .empty,
    breaks: std.ArrayList(BreakFrame) = .empty,
    next_reg: u32 = 0,

    fn deinit(self: *Lowerer) void {
        self.locals.deinit(self.allocator);
        self.binding_saves.deinit(self.allocator);
        for (self.breaks.items) |*b| b.patches.deinit(self.allocator);
        self.breaks.deinit(self.allocator);
    }

    fn newReg(self: *Lowerer) CompileError!u32 {
        if (self.next_reg >= std.math.maxInt(u32)) return error.TooManyRegisters;
        const r: u32 = self.next_reg;
        self.next_reg += 1;
        return r;
    }

    fn newRegs(self: *Lowerer, n: usize) CompileError!u32 {
        if (n == 0) return self.newReg();
        if (self.next_reg + n > std.math.maxInt(u32)) return error.TooManyRegisters;
        const base: u32 = self.next_reg;
        self.next_reg += @intCast(n);
        return base;
    }

    fn emit(self: *Lowerer, inst: Inst) CompileError!usize {
        try self.function.insts.append(self.allocator, inst);
        return self.function.insts.items.len - 1;
    }

    fn appendOperands(self: *Lowerer, regs: []const u32) CompileError!u32 {
        if (self.function.operands.items.len + regs.len > std.math.maxInt(u32)) return error.TooManyOperands;
        const at: u32 = @intCast(self.function.operands.items.len);
        try self.function.operands.appendSlice(self.allocator, regs);
        return at;
    }

    fn bindLocal(self: *Lowerer, name: []const u8, reg: u32) CompileError!void {
        try self.binding_saves.append(self.allocator, .{ .name = name, .previous = self.locals.get(name) });
        try self.locals.put(self.allocator, name, reg);
    }

    fn endScope(self: *Lowerer, mark: usize) void {
        var i = self.binding_saves.items.len;
        while (i > mark) {
            i -= 1;
            const save = self.binding_saves.items[i];
            if (save.previous) |old| self.locals.put(self.allocator, save.name, old) catch unreachable else _ = self.locals.remove(save.name);
        }
        self.binding_saves.shrinkRetainingCapacity(mark);
    }

    fn ensureUpvalue(self: *Lowerer, source: Upvalue) CompileError!u32 {
        for (self.function.upvalues.items, 0..) |old, i| {
            if (old.source == source.source and old.index == source.index) return @intCast(i);
        }
        if (self.function.upvalues.items.len >= std.math.maxInt(u32)) return error.TooManyUpvalues;
        try self.function.upvalues.append(self.allocator, source);
        return @intCast(self.function.upvalues.items.len - 1);
    }

    fn captureForChild(self: *Lowerer, name: []const u8) CompileError!Capture {
        if (self.locals.get(name)) |reg| return .{ .local = reg };
        const p = self.parent orelse return .global;
        const outer = try p.captureForChild(name);
        return switch (outer) {
            .global => .global,
            .local => |idx| .{ .upvalue = try self.ensureUpvalue(.{ .source = .local, .index = idx }) },
            .upvalue => |idx| .{ .upvalue = try self.ensureUpvalue(.{ .source = .upvalue, .index = idx }) },
        };
    }

    fn resolve(self: *Lowerer, name: []const u8) CompileError!Capture {
        if (self.locals.get(name)) |reg| return .{ .local = reg };
        const p = self.parent orelse return .global;
        const outer = try p.captureForChild(name);
        return switch (outer) {
            .global => .global,
            .local => |idx| .{ .upvalue = try self.ensureUpvalue(.{ .source = .local, .index = idx }) },
            .upvalue => |idx| .{ .upvalue = try self.ensureUpvalue(.{ .source = .upvalue, .index = idx }) },
        };
    }

    fn loadName(self: *Lowerer, name: []const u8) CompileError!u32 {
        return switch (try self.resolve(name)) {
            .local => |reg| blk: {
                // Read an expression before later arguments can mutate its binding.
                // Ordinary immutable aliases disappear in SSA optimization.
                const dst = try self.newReg();
                _ = try self.emit(.{ .op = .move, .dst = dst, .a = reg });
                break :blk dst;
            },
            .upvalue => |idx| blk: {
                const dst = try self.newReg();
                _ = try self.emit(.{ .op = .get_upvalue, .dst = dst, .a = idx });
                break :blk dst;
            },
            .global => blk: {
                const dst = try self.newReg();
                if (global_abi.find(name)) |slot| {
                    _ = try self.emit(.{ .op = .get_global_slot, .dst = dst, .aux = slot });
                } else {
                    _ = try self.emit(.{ .op = .get_global, .dst = dst, .aux = try self.program.intern(name) });
                }
                break :blk dst;
            },
        };
    }

    fn storeName(self: *Lowerer, name: []const u8, src: u32) CompileError!void {
        switch (try self.resolve(name)) {
            .local => |dst| _ = try self.emit(.{ .op = .move, .dst = dst, .a = src }),
            .upvalue => |idx| _ = try self.emit(.{ .op = .set_upvalue, .a = idx, .b = src }),
            .global => {
                if (global_abi.find(name)) |slot| {
                    _ = try self.emit(.{ .op = .set_global_slot, .a = src, .aux = slot });
                } else {
                    _ = try self.emit(.{ .op = .set_global, .a = src, .aux = try self.program.intern(name) });
                }
            },
        }
    }

    fn nilReg(self: *Lowerer) CompileError!u32 {
        const r = try self.newReg();
        _ = try self.emit(.{ .op = .load_nil, .dst = r });
        return r;
    }

    fn lowerExpr(self: *Lowerer, expr: *const lua.Expr) CompileError!u32 {
        return switch (expr.*) {
            .nil_lit => try self.nilReg(),
            .bool_lit => |v| blk: {
                const r = try self.newReg();
                _ = try self.emit(.{ .op = .load_bool, .dst = r, .a = @intFromBool(v.value) });
                break :blk r;
            },
            .number => |v| blk: {
                const r = try self.newReg();
                _ = try self.emit(.{ .op = .load_number, .dst = r, .aux = try self.program.intern(v.raw) });
                break :blk r;
            },
            .string => |v| blk: {
                const r = try self.newReg();
                _ = try self.emit(.{ .op = .load_string, .dst = r, .aux = try self.program.intern(v.value) });
                break :blk r;
            },
            .name => |v| try self.loadName(v.value),
            .paren => |v| try self.lowerExpr(v.expr),
            .vararg => blk: {
                const r = try self.newReg();
                _ = try self.emit(.{ .op = .vararg, .dst = r, .count = 1 });
                break :blk r;
            },
            .index => |v| blk: {
                const obj = try self.lowerExpr(v.object);
                const r = try self.newReg();
                if (v.key.* == .string) {
                    _ = try self.emit(.{ .op = .get_field, .dst = r, .a = obj, .aux = try self.program.intern(v.key.string.value) });
                } else {
                    const key = try self.lowerExpr(v.key);
                    _ = try self.emit(.{ .op = .get_index, .dst = r, .a = obj, .b = key });
                }
                break :blk r;
            },
            .call => |v| try self.lowerCall(v.callee, null, v.args, 1),
            .method_call => |v| try self.lowerCall(v.object, v.method, v.args, 1),
            .function => |f| blk: {
                const fn_id = try compileFunction(self.program, self, f);
                const r = try self.newReg();
                _ = try self.emit(.{ .op = .closure, .dst = r, .aux = fn_id });
                break :blk r;
            },
            .table => |v| blk: {
                if (v.fields.len != 0) {
                    if (try self.tryConstTable(v.fields)) |id| {
                        const r = try self.newReg();
                        _ = try self.emit(.{ .op = .load_const, .dst = r, .aux = id });
                        break :blk r;
                    }
                }
                break :blk try self.lowerTable(v.fields);
            },
            .unary => |v| blk: {
                const src = try self.lowerExpr(v.expr);
                const r = try self.newReg();
                const op: Opcode = switch (v.op) {
                    .neg => .neg,
                    .not_ => .not_,
                    .len => .len,
                };
                _ = try self.emit(.{ .op = op, .dst = r, .a = src });
                break :blk r;
            },
            .binary => |v| try self.lowerBinary(v.op, v.lhs, v.rhs),
        };
    }

    fn lowerBinary(self: *Lowerer, op: lua.BinaryOp, lhs_expr: *const lua.Expr, rhs_expr: *const lua.Expr) CompileError!u32 {
        if (op == .and_ or op == .or_) {
            const lhs = try self.lowerExpr(lhs_expr);
            const out = try self.newReg();
            _ = try self.emit(.{ .op = .move, .dst = out, .a = lhs });
            if (op == .and_) {
                const done = try self.emit(.{ .op = .jump_if_false, .a = lhs });
                const rhs = try self.lowerExpr(rhs_expr);
                _ = try self.emit(.{ .op = .move, .dst = out, .a = rhs });
                self.function.insts.items[done].aux = @intCast(self.function.insts.items.len);
            } else {
                const eval_rhs = try self.emit(.{ .op = .jump_if_false, .a = lhs });
                const skip = try self.emit(.{ .op = .jump });
                self.function.insts.items[eval_rhs].aux = @intCast(self.function.insts.items.len);
                const rhs = try self.lowerExpr(rhs_expr);
                _ = try self.emit(.{ .op = .move, .dst = out, .a = rhs });
                self.function.insts.items[skip].aux = @intCast(self.function.insts.items.len);
            }
            return out;
        }
        if (op == .concat) return self.lowerConcat(lhs_expr, rhs_expr);
        const lhs = try self.lowerExpr(lhs_expr);
        const rhs = try self.lowerExpr(rhs_expr);
        const out = try self.newReg();
        const vmop: Opcode = switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => unreachable,
        };
        _ = try self.emit(.{ .op = vmop, .dst = out, .a = lhs, .b = rhs });
        return out;
    }

    fn collectConcat(self: *Lowerer, expr: *const lua.Expr, out: *std.ArrayList(u32)) CompileError!void {
        if (expr.* == .binary and expr.binary.op == .concat) {
            try self.collectConcat(expr.binary.lhs, out);
            try self.collectConcat(expr.binary.rhs, out);
        } else try out.append(self.allocator, try self.lowerExpr(expr));
    }

    fn lowerConcat(self: *Lowerer, lhs: *const lua.Expr, rhs: *const lua.Expr) CompileError!u32 {
        var regs: std.ArrayList(u32) = .empty;
        defer regs.deinit(self.allocator);
        try self.collectConcat(lhs, &regs);
        try self.collectConcat(rhs, &regs);
        const at = try self.appendOperands(regs.items);
        const out = try self.newReg();
        _ = try self.emit(.{ .op = .concat, .dst = out, .aux = at, .count = @intCast(regs.items.len) });
        return out;
    }

    fn appendConst(self: *Lowerer, node: ConstNode) CompileError!u32 {
        if (self.program.constants.items.len >= std.math.maxInt(u32)) return error.TooManyOperands;
        try self.program.constants.append(self.allocator, node);
        return @intCast(self.program.constants.items.len - 1);
    }

    fn tryConstExpr(self: *Lowerer, expr: *const lua.Expr) CompileError!?u32 {
        return switch (expr.*) {
            .nil_lit => try self.appendConst(.nil),
            .bool_lit => |v| try self.appendConst(.{ .boolean = v.value }),
            .number => |v| try self.appendConst(.{ .number = try self.program.intern(v.raw) }),
            .string => |v| try self.appendConst(.{ .string = try self.program.intern(v.value) }),
            .unary => |v| if (v.op == .neg and v.expr.* == .number) blk: {
                const raw = v.expr.number.raw;
                const neg = try std.fmt.allocPrint(self.allocator, "-{s}", .{raw});
                break :blk try self.appendConst(.{ .number = try self.program.internTaking(neg) });
            } else null,
            .table => |v| try self.tryConstTable(v.fields),
            else => null,
        };
    }

    fn tryConstTable(self: *Lowerer, fields: []const lua.TableField) CompileError!?u32 {
        const node_mark = self.program.constants.items.len;
        const entry_mark = self.program.const_entries.items.len;
        var own_entries: std.ArrayList(ConstEntry) = .empty;
        defer own_entries.deinit(self.allocator);
        errdefer {
            self.program.constants.shrinkRetainingCapacity(node_mark);
            self.program.const_entries.shrinkRetainingCapacity(entry_mark);
        }

        for (fields) |field| {
            var key_id: u32 = undefined;
            var value_id: u32 = undefined;
            switch (field) {
                .list => |v| {
                    key_id = implicit_list_key;

                    value_id = (try self.tryConstExpr(v)) orelse {
                        self.program.constants.shrinkRetainingCapacity(node_mark);
                        self.program.const_entries.shrinkRetainingCapacity(entry_mark);
                        return null;
                    };
                },
                .named => |v| {
                    key_id = try self.appendConst(.{ .string = try self.program.intern(v.name) });
                    value_id = (try self.tryConstExpr(v.value)) orelse {
                        self.program.constants.shrinkRetainingCapacity(node_mark);
                        self.program.const_entries.shrinkRetainingCapacity(entry_mark);
                        return null;
                    };
                },
                .keyed => |v| {
                    key_id = (try self.tryConstExpr(v.key)) orelse {
                        self.program.constants.shrinkRetainingCapacity(node_mark);
                        self.program.const_entries.shrinkRetainingCapacity(entry_mark);
                        return null;
                    };
                    value_id = (try self.tryConstExpr(v.value)) orelse {
                        self.program.constants.shrinkRetainingCapacity(node_mark);
                        self.program.const_entries.shrinkRetainingCapacity(entry_mark);
                        return null;
                    };
                },
            }
            try own_entries.append(self.allocator, .{ .key = key_id, .value = value_id });
        }
        if (self.program.const_entries.items.len + own_entries.items.len > std.math.maxInt(u32)) return error.TooManyOperands;
        const first: u32 = @intCast(self.program.const_entries.items.len);
        try self.program.const_entries.appendSlice(self.allocator, own_entries.items);
        return try self.appendConst(.{ .table = .{ .first = first, .count = @intCast(own_entries.items.len) } });
    }

    fn lowerTable(self: *Lowerer, fields: []const lua.TableField) CompileError!u32 {
        const table = try self.newReg();
        _ = try self.emit(.{ .op = .new_table, .dst = table });
        for (fields, 0..) |field, i| switch (field) {
            .named => |v| {
                const value = try self.lowerExpr(v.value);
                _ = try self.emit(.{ .op = .set_field, .a = table, .c = value, .aux = try self.program.intern(v.name) });
            },
            .keyed => |v| {
                const key = try self.lowerExpr(v.key);
                const value = try self.lowerExpr(v.value);
                _ = try self.emit(.{ .op = .table_set, .a = table, .b = key, .c = value });
            },
            .list => |v| {
                if (i + 1 == fields.len and isMultiExpr(v)) {
                    const base = try self.lowerMulti(v, multi_count);
                    _ = try self.emit(.{ .op = .table_append_var, .a = table, .b = base });
                } else {
                    const value = try self.lowerExpr(v);
                    _ = try self.emit(.{ .op = .table_append, .a = table, .b = value });
                }
            },
        };
        return table;
    }

    fn lowerCall(self: *Lowerer, callee_expr: *const lua.Expr, method: ?[]const u8, args: []const *lua.Expr, ret_count: u32) CompileError!u32 {
        const callee = try self.lowerExpr(callee_expr);
        var regs: std.ArrayList(u32) = .empty;
        defer regs.deinit(self.allocator);
        const has_multi_tail = args.len != 0 and isMultiExpr(args[args.len - 1]);
        const fixed_args = if (has_multi_tail) args[0 .. args.len - 1] else args;
        if (method) |name| {
            // Method lookup must precede argument evaluation.
            const target = try self.newReg();
            _ = try self.emit(.{ .op = .get_field, .dst = target, .a = callee, .aux = try self.program.intern(name) });
            try regs.append(self.allocator, callee);
            for (fixed_args) |arg| try regs.append(self.allocator, try self.lowerExpr(arg));
            const var_base = if (has_multi_tail) try self.lowerMulti(args[args.len - 1], multi_count) else 0;
            const at = try self.appendOperands(regs.items);
            const dst = try self.newRegs(if (ret_count == multi_count or ret_count == 0) 1 else ret_count);
            _ = try self.emit(.{ .op = if (has_multi_tail) .call_vararg else .call, .dst = dst, .a = target, .b = @intCast(regs.items.len), .c = var_base, .aux = at, .count = ret_count });
            return dst;
        }
        for (fixed_args) |arg| try regs.append(self.allocator, try self.lowerExpr(arg));
        const var_base = if (has_multi_tail) try self.lowerMulti(args[args.len - 1], multi_count) else 0;
        const at = try self.appendOperands(regs.items);
        const dst = try self.newRegs(if (ret_count == multi_count or ret_count == 0) 1 else ret_count);
        _ = try self.emit(.{ .op = if (has_multi_tail) .call_vararg else .call, .dst = dst, .a = callee, .b = @intCast(regs.items.len), .c = var_base, .aux = at, .count = ret_count });
        return dst;
    }

    fn lowerMulti(self: *Lowerer, expr: *const lua.Expr, count: u32) CompileError!u32 {
        return switch (expr.*) {
            .call => |v| try self.lowerCall(v.callee, null, v.args, count),
            .method_call => |v| try self.lowerCall(v.object, v.method, v.args, count),
            .vararg => blk: {
                const base = try self.newRegs(if (count == multi_count) 1 else count);
                _ = try self.emit(.{ .op = .vararg, .dst = base, .count = count });
                break :blk base;
            },
            else => blk: {
                const first = try self.lowerExpr(expr);
                if (count == multi_count or count <= 1) break :blk first;
                const base = try self.newRegs(count);
                _ = try self.emit(.{ .op = .move, .dst = base, .a = first });
                var i: u32 = 1;
                while (i < count) : (i += 1) _ = try self.emit(.{ .op = .load_nil, .dst = base + i });
                break :blk base;
            },
        };
    }

    fn lowerRhsFixed(self: *Lowerer, values: []const *lua.Expr, needed: usize) CompileError![]u32 {
        const out = try self.allocator.alloc(u32, needed);
        if (needed == 0) return out;
        var oi: usize = 0;
        for (values, 0..) |expr, i| {
            if (oi >= needed) {
                _ = try self.lowerExpr(expr);
                continue;
            }
            const is_last = i + 1 == values.len;
            if (is_last and isMultiExpr(expr)) {
                const remain: u32 = @intCast(needed - oi);
                const base = try self.lowerMulti(expr, remain);
                for (0..remain) |j| out[oi + j] = base + @as(u32, @intCast(j));
                oi = needed;
            } else {
                out[oi] = try self.lowerExpr(expr);
                oi += 1;
            }
        }
        while (oi < needed) : (oi += 1) out[oi] = try self.nilReg();
        return out;
    }

    const PreparedLValue = union(enum) {
        name: []const u8,
        field: struct { object: u32, key: u32 },
        index: struct { object: u32, key: u32 },
    };

    fn isLocalReg(self: *const Lowerer, reg: u32) bool {
        var it = self.locals.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == reg) return true;
        return false;
    }

    fn snapshotLocalReg(self: *Lowerer, reg: u32) CompileError!u32 {
        if (!self.isLocalReg(reg)) return reg;
        const snapshot = try self.newReg();
        _ = try self.emit(.{ .op = .move, .dst = snapshot, .a = reg });
        return snapshot;
    }

    fn prepareLValue(self: *Lowerer, target: lua.LValue) CompileError!PreparedLValue {
        return switch (target) {
            .name => |name| .{ .name = name },
            .index => |v| blk: {
                const object = try self.snapshotLocalReg(try self.lowerExpr(v.object));
                if (v.key.* == .string) break :blk .{ .field = .{
                    .object = object,
                    .key = try self.program.intern(v.key.string.value),
                } };
                break :blk .{ .index = .{
                    .object = object,
                    .key = try self.snapshotLocalReg(try self.lowerExpr(v.key)),
                } };
            },
        };
    }

    fn storePreparedLValue(self: *Lowerer, target: PreparedLValue, value: u32) CompileError!void {
        switch (target) {
            .name => |name| try self.storeName(name, value),
            .field => |v| _ = try self.emit(.{ .op = .set_field, .a = v.object, .c = value, .aux = v.key }),
            .index => |v| _ = try self.emit(.{ .op = .set_index, .a = v.object, .b = v.key, .c = value }),
        }
    }

    fn pushBreak(self: *Lowerer) CompileError!void {
        try self.breaks.append(self.allocator, .{});
    }
    fn emitBreak(self: *Lowerer) CompileError!void {
        if (self.breaks.items.len == 0) return error.InvalidBreak;
        const j = try self.emit(.{ .op = .jump });
        try self.breaks.items[self.breaks.items.len - 1].patches.append(self.allocator, j);
    }
    fn popBreak(self: *Lowerer, target: u32) void {
        var frame = self.breaks.pop().?;
        for (frame.patches.items) |p| self.function.insts.items[p].aux = target;
        frame.patches.deinit(self.allocator);
    }

    fn lowerScopedBlock(self: *Lowerer, body: lua.Block) CompileError!bool {
        const mark = self.binding_saves.items.len;
        defer self.endScope(mark);
        return self.lowerBlock(body);
    }

    fn lowerBlock(self: *Lowerer, body: lua.Block) CompileError!bool {
        for (body) |stmt| if (try self.lowerStmt(stmt)) return true;
        return false;
    }

    fn lowerStmt(self: *Lowerer, stmt: *const lua.Stmt) CompileError!bool {
        switch (stmt.*) {
            .empty => return false,
            .break_stmt => {
                try self.emitBreak();
                return true;
            },
            .local_assign => |s| {
                const values = try self.lowerRhsFixed(s.values, s.names.len);
                defer self.allocator.free(values);
                for (s.names, 0..) |name, i| {
                    if (!self.isLocalReg(values[i])) {
                        try self.bindLocal(name, values[i]);
                    } else {
                        const dst = try self.newReg();
                        try self.bindLocal(name, dst);
                        _ = try self.emit(.{ .op = .move, .dst = dst, .a = values[i] });
                    }
                }
                return false;
            },
            .assign => |s| {
                // Lua captures indexed LHS operands before evaluating the RHS, then performs all stores.
                const targets = try self.allocator.alloc(PreparedLValue, s.targets.len);
                defer self.allocator.free(targets);
                for (s.targets, 0..) |target, i| targets[i] = try self.prepareLValue(target);

                const values = try self.lowerRhsFixed(s.values, s.targets.len);
                defer self.allocator.free(values);
                // A plain local expression aliases its register. Snapshot it before an earlier store can clobber it.
                for (values) |*value| value.* = try self.snapshotLocalReg(value.*);
                for (targets, values) |target, value| try self.storePreparedLValue(target, value);
                return false;
            },
            .call => |s| {
                _ = switch (s.expr.*) {
                    .call => |v| try self.lowerCall(v.callee, null, v.args, 0),
                    .method_call => |v| try self.lowerCall(v.object, v.method, v.args, 0),
                    else => try self.lowerExpr(s.expr),
                };
                return false;
            },
            .do_block => |s| return try self.lowerScopedBlock(s.body),
            .if_stmt => |s| return try self.lowerIf(s),
            .while_loop => |s| {
                const start: u32 = @intCast(self.function.insts.items.len);
                const cond = try self.lowerExpr(s.cond);
                const exit = try self.emit(.{ .op = .jump_if_false, .a = cond });
                try self.pushBreak();
                _ = try self.lowerScopedBlock(s.body);
                _ = try self.emit(.{ .op = .jump, .aux = start });
                const end: u32 = @intCast(self.function.insts.items.len);
                self.function.insts.items[exit].aux = end;
                self.popBreak(end);
                return false;
            },
            .repeat_loop => |s| {
                const start: u32 = @intCast(self.function.insts.items.len);
                const mark = self.binding_saves.items.len;
                try self.pushBreak();
                _ = try self.lowerBlock(s.body);
                const cond = try self.lowerExpr(s.cond);
                _ = try self.emit(.{ .op = .jump_if_false, .a = cond, .aux = start });
                const end: u32 = @intCast(self.function.insts.items.len);
                self.popBreak(end);
                self.endScope(mark);
                return false;
            },
            .numeric_for => |s| {
                const start_v = try self.lowerExpr(s.start);
                const limit_v = try self.lowerExpr(s.limit);
                const step_v = if (s.step) |v| try self.lowerExpr(v) else blk: {
                    const r = try self.newReg();
                    _ = try self.emit(.{ .op = .load_number, .dst = r, .aux = try self.program.intern("1") });
                    break :blk r;
                };
                const mark = self.binding_saves.items.len;
                const control_reg = try self.newReg();
                _ = try self.emit(.{ .op = .move, .dst = control_reg, .a = start_v });
                const var_reg = try self.newReg();
                try self.bindLocal(s.name, var_reg);
                const prep = try self.emit(.{ .op = .numeric_for_init, .dst = var_reg, .a = control_reg, .b = limit_v, .c = step_v });
                const body_start: u32 = @intCast(self.function.insts.items.len);
                try self.pushBreak();
                _ = try self.lowerBlock(s.body);
                _ = try self.emit(.{ .op = .numeric_for_next, .dst = var_reg, .a = control_reg, .b = limit_v, .c = step_v, .aux = body_start });
                const end: u32 = @intCast(self.function.insts.items.len);
                self.function.insts.items[prep].aux = end;
                self.popBreak(end);
                self.endScope(mark);
                return false;
            },
            .generic_for => |s| {
                const iter_values = try self.lowerRhsFixed(s.values, 3);
                defer self.allocator.free(iter_values);
                const mark = self.binding_saves.items.len;
                const vars_base = try self.newRegs(s.names.len);
                for (s.names, 0..) |name, i| try self.bindLocal(name, vars_base + @as(u32, @intCast(i)));
                const init = try self.emit(.{ .op = .generic_for_init, .dst = vars_base, .a = iter_values[0], .b = iter_values[1], .c = iter_values[2], .count = @intCast(s.names.len) });
                const body_start: u32 = @intCast(self.function.insts.items.len);
                try self.pushBreak();
                _ = try self.lowerBlock(s.body);
                _ = try self.emit(.{ .op = .generic_for_next, .dst = vars_base, .a = iter_values[0], .b = iter_values[1], .c = iter_values[2], .count = @intCast(s.names.len), .aux = body_start });
                const end: u32 = @intCast(self.function.insts.items.len);
                self.function.insts.items[init].aux = end;
                self.popBreak(end);
                self.endScope(mark);
                return false;
            },
            .function_assign => |s| {
                const target = try self.prepareLValue(s.target);
                const closure = try self.lowerExpr(s.function);
                try self.storePreparedLValue(target, closure);
                return false;
            },
            .local_function => |s| {
                const dst = try self.newReg();
                try self.bindLocal(s.name, dst);
                // Lua local-function declarations bind the local before the
                // closure is created, so recursive captures initially see nil.
                _ = try self.emit(.{ .op = .load_nil, .dst = dst });
                const fn_id = try compileFunction(self.program, self, s.function.function);
                const closure = try self.newReg();
                _ = try self.emit(.{ .op = .closure, .dst = closure, .aux = fn_id });
                _ = try self.emit(.{ .op = .move, .dst = dst, .a = closure });
                return false;
            },
            .return_stmt => |s| {
                try self.lowerReturn(s.values);
                return true;
            },
        }
    }

    fn lowerIf(self: *Lowerer, s: anytype) CompileError!bool {
        var end_jumps: std.ArrayList(usize) = .empty;
        defer end_jumps.deinit(self.allocator);
        var all_terminate = s.else_body != null;
        for (s.branches) |branch| {
            const cond = try self.lowerExpr(branch.cond);
            const jf = try self.emit(.{ .op = .jump_if_false, .a = cond });
            const term = try self.lowerScopedBlock(branch.body);
            all_terminate = all_terminate and term;
            if (!term) try end_jumps.append(self.allocator, try self.emit(.{ .op = .jump }));
            self.function.insts.items[jf].aux = @intCast(self.function.insts.items.len);
        }
        if (s.else_body) |body| {
            const else_terminates = try self.lowerScopedBlock(body);
            all_terminate = all_terminate and else_terminates;
        } else all_terminate = false;
        const end: u32 = @intCast(self.function.insts.items.len);
        for (end_jumps.items) |j| self.function.insts.items[j].aux = end;
        return all_terminate;
    }

    fn lowerReturn(self: *Lowerer, values: []const *lua.Expr) CompileError!void {
        if (values.len == 0) {
            _ = try self.emit(.{ .op = .ret, .count = 0 });
            return;
        }
        var prefix: std.ArrayList(u32) = .empty;
        defer prefix.deinit(self.allocator);
        for (values[0 .. values.len - 1]) |v| try prefix.append(self.allocator, try self.lowerExpr(v));
        const last = values[values.len - 1];
        if (isMultiExpr(last)) {
            const base = try self.lowerMulti(last, multi_count);
            const at = try self.appendOperands(prefix.items);
            _ = try self.emit(.{ .op = .ret_var, .a = base, .aux = at, .count = @intCast(prefix.items.len) });
        } else {
            try prefix.append(self.allocator, try self.lowerExpr(last));
            const at = try self.appendOperands(prefix.items);
            _ = try self.emit(.{ .op = .ret, .aux = at, .count = @intCast(prefix.items.len) });
        }
    }
};

fn isMultiExpr(expr: *const lua.Expr) bool {
    return switch (expr.*) {
        .call, .method_call, .vararg => true,
        else => false,
    };
}

fn compileFunction(program: *Program, parent: ?*Lowerer, f: lua.FunctionExpr) CompileError!u32 {
    if (program.functions.items.len >= std.math.maxInt(u32)) return error.TooManyFunctions;
    const id: u32 = @intCast(program.functions.items.len);
    try program.functions.append(program.allocator, null);
    var l = Lowerer{ .allocator = program.allocator, .program = program, .parent = parent, .function = .{ .source_start = f.span.start, .source_end = f.span.end, .param_count = @intCast(f.params.len), .is_vararg = f.is_vararg } };
    errdefer l.function.deinit(program.allocator);
    defer l.deinit();
    for (f.params) |name| {
        const r = try l.newReg();
        try l.bindLocal(name, r);
    }
    const term = try l.lowerBlock(f.body);
    if (!term) _ = try l.emit(.{ .op = .ret, .count = 0 });
    l.function.reg_count = @intCast(l.next_reg);
    program.functions.items[id] = l.function;
    return id;
}

pub fn lowerChunk(allocator: std.mem.Allocator, chunk: *const lua.Chunk) CompileError!Program {
    var p = Program{ .allocator = allocator };
    errdefer p.deinit();
    const synthetic = lua.FunctionExpr{ .params = &.{}, .is_vararg = true, .body = chunk.body, .span = .{ .start = 0, .end = @intCast(chunk.source.len) } };
    p.root_function = try compileFunction(&p, null, synthetic);
    return p;
}

test "lower complete syntax surface" {
    const source =
        \\local x = 1
        \\local function f(a, ...)
        \\  local t = {a, x = 2, [a] = 3}
        \\  while a < 3 do a = a + 1; if a == 2 then break end end
        \\  repeat a = a - 1 until a <= 0
        \\  for i = 1, 3 do t[i] = i end
        \\  for k,v in pairs(t) do t[k] = v end
        \\  return t[a], ...
        \\end
        \\return f
    ;
    var chunk = try lua.parse(std.testing.allocator, source);
    defer chunk.deinit();
    var p = try lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    try std.testing.expect(p.functions.items.len >= 2);
}
test "generated negative literals are interned with program ownership" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return {-0, -0, -12, -12}");
    defer chunk.deinit();
    var p = try lowerChunk(a, &chunk);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.owned_strings.items.len);
    try std.testing.expectEqualStrings("-0", p.owned_strings.items[0]);
    try std.testing.expectEqualStrings("-12", p.owned_strings.items[1]);
}
