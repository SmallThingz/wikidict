const global_abi = @import("vm_global_abi.zig");
const refs = @import("vm_ref.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const rt = @import("vm_runtime.zig");
const static_fields = @import("vm_static_field_abi.zig");
const static_keys = @import("vm_static_key_abi.zig");
const lua = @import("root.zig");

pub const Value = rt.Value;
const instruction_limit: u64 = if (@hasDecl(@import("root"), "vm_instruction_limit"))
    @import("root").vm_instruction_limit
else
    0;

pub const Failure = struct { program: *const ir.Program, function_id: u32, pc: usize };

const Frame = struct {
    program: *const ir.Program,
    regs: []Value,
    cells: ?[]?*rt.Cell = null,
    cells_owned: bool = false,
    module_id: ?u32 = null,
    module_env: ?*rt.ModuleEnv = null,
    varargs: []const Value,
    upvalues: []const *rt.Cell,
    multi: []const Value = &.{},
    multi_base: u32 = std.math.maxInt(u32),
    multi_owned: bool = false,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    globals: *rt.Table,
    global_program: ?*const ir.Program = null,
    string_metatable: ?*rt.Table = null,
    depth: usize = 0,
    max_depth: usize = 1000,
    // Diagnostic replay opt-in. No storage or dispatch work in production.
    instructions_left: if (instruction_limit != 0) u64 else void = if (instruction_limit != 0) instruction_limit else {},

    last_error: Value = .nil,
    failure: ?Failure = null,
    string_intern: std.StringHashMapUnmanaged([]const u8) = .empty,
    linked_program: ?*const ir.Program = null,
    module_state: []u8 = &.{},
    static_functions: []Value = &.{},

    pub fn init(allocator: std.mem.Allocator) !Vm {
        const globals = try rt.newTable(allocator);
        errdefer {
            globals.deinit(allocator);
            allocator.destroy(globals);
        }
        globals.shape_id = global_abi.native_shape;
        globals.slots = try allocator.alloc(Value, global_abi.count);
        @memset(globals.slots, .nil);
        const vm = Vm{ .allocator = allocator, .globals = globals };
        try globals.rawSetSlot(global_abi.id("_G"), .{ .table = globals });
        return vm;
    }

    pub fn getGlobal(self: *const Vm, comptime name: []const u8) ?Value {
        return self.globals.rawGetSlot(global_abi.id(name));
    }
    pub fn setGlobal(self: *Vm, comptime name: []const u8, value: Value) !void {
        try self.globals.rawSetSlot(global_abi.id(name), value);
    }
    fn bindGlobals(self: *Vm, p: *const ir.Program) !void {
        const id = p.global_shape orelse return;
        if (self.global_program == p) return;
        if (self.global_program != null) return error.MultipleGlobalLayouts;
        const shape = p.shapes.items[id];
        if (shape.field_count < global_abi.count) return error.BadGlobalLayout;
        if (self.globals.map.count() != 0) return error.UnlinkedGlobalBindings;
        const slots = try self.allocator.alloc(Value, shape.field_count);
        @memset(slots, .nil);
        @memcpy(slots[0..global_abi.count], self.globals.slots[0..global_abi.count]);
        self.allocator.free(self.globals.slots);
        self.globals.slots = slots;
        self.globals.shape_program = p;
        self.globals.shape_id = id;
        self.global_program = p;
    }

    fn rawFreeSlice(comptime T: type, allocator: std.mem.Allocator, values: []T) void {
        if (values.len == 0) return;
        const bytes = std.mem.sliceAsBytes(values);
        allocator.rawFree(bytes, .of(T), @returnAddress());
    }

    pub fn freeResults(values: []const Value) void {
        rawFreeSlice(Value, std.heap.smp_allocator, @constCast(values));
    }

    inline fn getReg(_: *Vm, f: *const Frame, r: u32) Value {
        switch (refs.tag(r)) {
            .register => {},
            .integer => return .{ .number = @floatFromInt(refs.integerValue(r)) },
            .string => return .{ .string = f.program.strings.items[refs.index(r)] },
            .special => return switch (r) {
                refs.nil => .nil,
                refs.false_value => .{ .boolean = false },
                refs.true_value => .{ .boolean = true },
                else => unreachable,
            },
            .constant => return switch (f.program.constants.items[refs.index(r)]) {
                .nil => .nil,
                .boolean => |v| .{ .boolean = v },
                .number_bits => |v| .{ .number = @bitCast(v) },
                .integer => |v| .{ .number = @floatFromInt(v) },
                .string => |v| .{ .string = f.program.strings.items[v] },
                else => unreachable,
            },
            else => unreachable,
        }
        if (f.cells) |cells| if (cells[r]) |cell| return cell.value;
        return f.regs[r];
    }
    // These opcodes carry a compile-time numeric proof. Do not construct or
    // inspect a generic Value when fetching their numeric operands.
    inline fn getNumber(_: *Vm, f: *const Frame, r: u32) f64 {
        return switch (refs.tag(r)) {
            .register => blk: {
                if (f.cells) |cells| if (cells[r]) |cell| break :blk cell.value.number;
                break :blk f.regs[r].number;
            },
            .integer => @floatFromInt(refs.integerValue(r)),
            .constant => switch (f.program.constants.items[refs.index(r)]) {
                .number_bits => |bits| @bitCast(bits),
                .integer => |n| @floatFromInt(n),
                else => unreachable,
            },
            else => unreachable,
        };
    }
    fn setReg(_: *Vm, f: *Frame, r: u32, v: Value) void {
        if (f.cells) |cells| if (cells[r]) |cell| {
            cell.value = v;
            return;
        };
        f.regs[r] = v;
    }
    fn ensureModuleEnvironment(self: *Vm, f: *Frame) !*rt.ModuleEnv {
        if (f.module_env) |env| return env;
        const module_id = f.module_id orelse return error.NotModuleRoot;
        const cells = try self.allocator.alloc(?*rt.Cell, f.regs.len);
        @memset(cells, null);
        if (f.cells) |old| {
            @memcpy(cells, old);
            if (f.cells_owned) rawFreeSlice(?*rt.Cell, std.heap.smp_allocator, old);
        }
        const env = try self.allocator.create(rt.ModuleEnv);
        env.* = .{ .program = f.program, .module_id = module_id, .cells = cells };
        f.module_env = env;
        f.cells = cells;
        f.cells_owned = false;
        return env;
    }
    fn ensureCell(self: *Vm, f: *Frame, r: u32) !*rt.Cell {
        if (f.cells) |cells| {
            if (cells[r]) |cell| return cell;
        } else {
            const cells = try std.heap.smp_allocator.alloc(?*rt.Cell, f.regs.len);
            @memset(cells, null);
            f.cells = cells;
            f.cells_owned = true;
        }
        const cell = try self.allocator.create(rt.Cell);
        cell.* = .{ .value = f.regs[r] };
        f.cells.?[r] = cell;
        return cell;
    }
    pub fn parseLuaNumber(raw: []const u8) !f64 {
        var s = raw;
        var sign: f64 = 1;
        if (s.len != 0 and s[0] == '-') {
            sign = -1;
            s = s[1..];
        }
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            s = s[2..];
            var mantissa = s;
            var exp2: i32 = 0;
            if (std.mem.indexOfAny(u8, s, "pP")) |p| {
                mantissa = s[0..p];
                exp2 = try std.fmt.parseInt(i32, s[p + 1 ..], 10);
            }
            var value: f64 = 0;
            var frac_scale: f64 = 1;
            var after_dot = false;
            for (mantissa) |c| {
                if (c == '.') {
                    after_dot = true;
                    continue;
                }
                const digit: u8 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidNumber;
                if (!after_dot) value = value * 16 + @as(f64, @floatFromInt(digit)) else {
                    frac_scale /= 16;
                    value += @as(f64, @floatFromInt(digit)) * frac_scale;
                }
            }
            return sign * value * std.math.pow(f64, 2, @floatFromInt(exp2));
        }
        return sign * (std.fmt.parseFloat(f64, s) catch return error.InvalidNumber);
    }

    pub fn materializeConst(self: *Vm, p: *const ir.Program, id: u32) anyerror!Value {
        return switch (p.constants.items[id]) {
            .nil => .nil,
            .boolean => |b| .{ .boolean = b },
            .number => |sid| .{ .number = try parseLuaNumber(p.strings.items[sid]) },
            .number_bits => |bits| .{ .number = @bitCast(bits) },
            .string => |sid| .{ .string = p.strings.items[sid] },
            .integer => |n| .{ .number = @floatFromInt(n) },
            .table => |tinfo| blk: {
                const t = if (tinfo.shape == ir.no_shape)
                    try rt.newTable(self.allocator)
                else
                    try rt.newShapedTable(self.allocator, p, tinfo.shape);
                var list_index: u32 = 1;
                for (p.const_entries.items[tinfo.first .. tinfo.first + tinfo.count]) |e| {
                    const key: Value = if (e.key == ir.implicit_list_key) list_key: {
                        const n = list_index;
                        list_index += 1;
                        break :list_key .{ .number = @floatFromInt(n) };
                    } else try self.materializeConst(p, e.key);
                    const value = try self.materializeConst(p, e.value);
                    try t.rawSet(self.allocator, key, value);
                }
                break :blk .{ .table = t };
            },
        };
    }

    pub fn metamethod(_: *Vm, value: Value, name: []const u8) ?Value {
        const mt: ?*rt.Table = switch (value) {
            .table => |t| t.metatable,
            else => null,
        };
        return if (mt) |t| t.rawGet(.{ .string = name }) else null;
    }

    pub fn getIndex(self: *Vm, object: Value, key: Value) anyerror!Value {
        switch (object) {
            .table => |t| {
                if (t.rawGet(key)) |v| return v;
                if (t.metatable) |mt| if (mt.rawGet(.{ .string = "__index" })) |idx| return switch (idx) {
                    .table => |other| self.getIndex(.{ .table = other }, key),
                    else => blk: {
                        const vals = try self.callValue(idx, &.{ object, key });
                        defer freeResults(vals);
                        break :blk if (vals.len == 0) .nil else vals[0];
                    },
                };
                return .nil;
            },
            .string => {
                if (self.string_metatable) |mt| if (mt.rawGet(.{ .string = "__index" })) |idx| {
                    if (idx == .table) return idx.table.rawGet(key) orelse .nil;
                    const vals = try self.callValue(idx, &.{ object, key });
                    defer freeResults(vals);
                    return if (vals.len == 0) .nil else vals[0];
                };
                return error.IndexType;
            },
            else => return error.IndexType,
        }
    }

    pub fn setIndex(self: *Vm, object: Value, key: Value, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        const t = object.table;
        if (t.rawGet(key) != null or t.metatable == null) return t.rawSet(self.allocator, key, value);
        if (t.metatable.?.rawGet(.{ .string = "__newindex" })) |ni| switch (ni) {
            .table => |other| return self.setIndex(.{ .table = other }, key, value),
            else => {
                const out = try self.callValue(ni, &.{ object, key, value });
                defer freeResults(out);
                return;
            },
        };
        try t.rawSet(self.allocator, key, value);
    }

    fn getLocalSlot(self: *Vm, object: Value, slot: u32) anyerror!Value {
        if (object != .table) return error.IndexType;
        const t = object.table;
        if (t.rawGetSlot(slot)) |value| return value;
        if (t.metatable == null) return .nil;
        const key = t.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.getIndex(object, key);
    }

    fn getSlot(self: *Vm, object: Value, slot: u32) anyerror!Value {
        if (static_keys.integerForRef(slot)) |integer| {
            const key: Value = .{ .number = @floatFromInt(integer) };
            if (object == .table) if (object.table.slotForKey(key)) |local| return self.getLocalSlot(object, local);
            return self.getIndex(object, key);
        }
        if (static_fields.nameForRef(slot)) |name| {
            if (object == .table) if (object.table.native_namespace) |namespace| {
                if (static_fields.slotForRef(namespace, slot)) |local| return self.getLocalSlot(object, local);
            };
            return self.getIndex(object, .{ .string = name });
        }
        return self.getLocalSlot(object, slot);
    }

    fn setLocalSlot(self: *Vm, object: Value, slot: u32, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        const t = object.table;
        if (t.rawGetSlot(slot) != null or t.metatable == null) return t.rawSetSlot(slot, value);
        const key = t.fieldKey(slot) orelse return error.BadAnonymousShapeMetatable;
        return self.setIndex(object, key, value);
    }

    fn setSlot(self: *Vm, object: Value, slot: u32, value: Value) anyerror!void {
        if (static_keys.integerForRef(slot)) |integer| {
            const key: Value = .{ .number = @floatFromInt(integer) };
            if (object == .table) if (object.table.slotForKey(key)) |local| return self.setLocalSlot(object, local, value);
            return self.setIndex(object, key, value);
        }
        if (static_fields.nameForRef(slot)) |name| {
            if (object == .table) if (object.table.native_namespace) |namespace| {
                if (static_fields.slotForRef(namespace, slot)) |local| return self.setLocalSlot(object, local, value);
            };
            return self.setIndex(object, .{ .string = name }, value);
        }
        return self.setLocalSlot(object, slot, value);
    }

    fn getChoice(self: *Vm, object: Value, choice: u32, key: Value) anyerror!Value {
        if (object != .table) return error.IndexType;
        const t = object.table;
        if (t.rawGetChoice(choice, key)) |value| return value;
        if (t.metatable == null) return .nil;
        return self.getIndex(object, key);
    }
    fn setChoice(self: *Vm, object: Value, choice: u32, key: Value, value: Value) anyerror!void {
        if (object != .table) return error.IndexType;
        const t = object.table;
        if (t.rawGetChoice(choice, key) != null or t.metatable == null)
            return t.rawSetChoice(choice, key, value);
        return self.setIndex(object, key, value);
    }

    fn callFunctionValue(self: *Vm, value: rt.FunctionValue, args: []const Value) anyerror![]const Value {
        const p = value.env.program;
        if (value.function_id >= p.functions.items.len) return error.BadBytecode;
        const target = p.functions.items[value.function_id] orelse return error.BadBytecode;
        if (target.upvalues.items.len == 0) return self.execute(p, value.function_id, &.{}, args);
        var scratch = std.heap.stackFallback(8 * @sizeOf(*rt.Cell), std.heap.smp_allocator);
        const a = scratch.get();
        const captures = try a.alloc(*rt.Cell, target.upvalues.items.len);
        defer a.free(captures);
        for (target.upvalues.items, 0..) |up, i| {
            if (up.source != .local or up.index >= value.env.cells.len) return error.BadStaticEnvironment;
            captures[i] = value.env.cells[up.index] orelse return error.BadStaticEnvironment;
        }
        return self.execute(p, value.function_id, captures, args);
    }

    pub fn callValue(self: *Vm, callable: Value, args: []const Value) anyerror![]const Value {
        return switch (callable) {
            .closure => |c| try self.execute(c.program, c.function_id, c.upvalues, args),
            .function => |f| try self.callFunctionValue(f, args),
            .native => |n| try n.call(n.ctx, self, args, self.allocator),
            .table => blk: {
                const mm = self.metamethod(callable, "__call") orelse return error.NotCallable;
                const all = try std.heap.smp_allocator.alloc(Value, args.len + 1);
                defer rawFreeSlice(Value, std.heap.smp_allocator, all);
                all[0] = callable;
                @memcpy(all[1..], args);
                break :blk try self.callValue(mm, all);
            },
            else => error.NotCallable,
        };
    }

    pub fn binaryArith(self: *Vm, op: ir.Opcode, a: Value, b: Value) anyerror!Value {
        if (rt.toNumber(a) != null and rt.toNumber(b) != null) return rt.arithmetic(op, a, b);
        const name = switch (op) {
            .add => "__add",
            .sub => "__sub",
            .mul => "__mul",
            .div => "__div",
            .mod => "__mod",
            .pow => "__pow",
            else => unreachable,
        };
        const mm = self.metamethod(a, name) orelse self.metamethod(b, name) orelse return error.ArithmeticType;
        const vals = try self.callValue(mm, &.{ a, b });
        defer freeResults(vals);
        return if (vals.len == 0) .nil else vals[0];
    }
    fn internString(self: *Vm, text: []const u8) ![]const u8 {
        if (self.string_intern.get(text)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, text);
        try self.string_intern.put(self.allocator, owned, owned);
        return owned;
    }

    fn appendConcatNumber(out: *std.ArrayList(u8), a: std.mem.Allocator, n: f64) !void {
        if (std.math.isNan(n)) return out.appendSlice(a, "nan");
        if (std.math.isInf(n)) return out.appendSlice(a, if (n < 0) "-inf" else "inf");
        var buf: [128]u8 = undefined;
        const text = if (@floor(n) == n and n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(n))})
        else
            try std.fmt.bufPrint(&buf, "{d}", .{n});
        try out.appendSlice(a, text);
    }

    fn concatSimpleIntern(self: *Vm, vals: []const Value) !Value {
        var scratch = std.heap.stackFallback(1024, std.heap.smp_allocator);
        const a = scratch.get();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        for (vals) |v| switch (v) {
            .string => |text| try out.appendSlice(a, text),
            .number => |n| try appendConcatNumber(&out, a, n),
            else => return error.ConcatType,
        };
        return .{ .string = try self.internString(out.items) };
    }

    pub fn concatValues(self: *Vm, vals: []const Value) anyerror!Value {
        // Lua 5.1 interns strings. Build concat output in short-lived scratch
        // storage, then retain only one canonical copy per distinct result.
        // This matters for memoization-heavy modules, which repeatedly build
        // the same keys and otherwise retain every duplicate for the page.
        var simple = true;
        for (vals) |v| if (v != .string and v != .number) {
            simple = false;
            break;
        };
        if (simple) return self.concatSimpleIntern(vals);
        if (vals.len != 2) {
            var acc = vals[vals.len - 1];
            var i = vals.len - 1;
            while (i > 0) {
                i -= 1;
                acc = try self.concatValues(&.{ vals[i], acc });
            }
            return acc;
        }
        const mm = self.metamethod(vals[0], "__concat") orelse self.metamethod(vals[1], "__concat") orelse return error.ConcatType;
        const out = try self.callValue(mm, vals);
        defer freeResults(out);
        return if (out.len == 0) .nil else out[0];
    }

    pub fn comparison(self: *Vm, op: ir.Opcode, a: Value, b: Value) anyerror!bool {
        if (op == .eq or op == .ne) {
            if (rt.rawEqual(a, b)) return op == .eq;
            if (a == .table and b == .table) {
                const ma = self.metamethod(a, "__eq");
                const mb = self.metamethod(b, "__eq");
                if (ma != null and mb != null and rt.rawEqual(ma.?, mb.?)) {
                    const out = try self.callValue(ma.?, &.{ a, b });
                    defer freeResults(out);
                    const e = out.len != 0 and out[0].truthy();
                    return if (op == .eq) e else !e;
                }
            }
            return op == .ne;
        }
        if ((a == .number and b == .number) or (a == .string and b == .string)) return rt.compare(op, a, b);
        const name = if (op == .lt or op == .gt) "__lt" else "__le";
        const left = if (op == .gt or op == .ge) b else a;
        const right = if (op == .gt or op == .ge) a else b;
        if (self.metamethod(left, name) orelse self.metamethod(right, name)) |mm| {
            const out = try self.callValue(mm, &.{ left, right });
            defer freeResults(out);
            return out.len != 0 and out[0].truthy();
        }
        // Lua 5.1 falls back from __le to not (b < a).
        if (op == .le or op == .ge) if (self.metamethod(right, "__lt") orelse self.metamethod(left, "__lt")) |mm| {
            const out = try self.callValue(mm, &.{ right, left });
            defer freeResults(out);
            return !(out.len != 0 and out[0].truthy());
        };
        return error.CompareType;
    }

    fn storeResults(self: *Vm, f: *Frame, base: u32, count: u32, values: []const Value, owned: bool) void {
        if (count == 0) {
            if (owned) freeResults(values);
            return;
        }
        if (count == ir.multi_count) {
            if (f.multi_owned) freeResults(f.multi);
            f.multi = values;
            f.multi_base = base;
            f.multi_owned = owned;
            if (values.len != 0) self.setReg(f, base, values[0]) else self.setReg(f, base, .nil);
            return;
        }
        var i: u32 = 0;
        while (i < count) : (i += 1) self.setReg(f, base + i, if (i < values.len) values[i] else .nil);
        if (owned) freeResults(values);
    }

    fn multiAt(_: *Vm, f: *const Frame, base: u32) []const Value {
        return if (f.multi_base == base) f.multi else &.{};
    }

    fn buildArgs(self: *Vm, f: *const Frame, fun: *const ir.Function, inst: ir.Inst, skip: usize, with_tail: bool) ![]Value {
        const fixed = fun.operands.items[inst.aux .. inst.aux + inst.b];
        const tail = if (with_tail) self.multiAt(f, inst.c) else &.{};
        if (fixed.len < skip) return error.BadBytecode;
        const out = try std.heap.smp_allocator.alloc(Value, fixed.len - skip + tail.len);
        for (fixed[skip..], 0..) |r, i| out[i] = self.getReg(f, r);
        @memcpy(out[fixed.len - skip ..], tail);
        return out;
    }

    fn makeClosure(self: *Vm, p: *const ir.Program, child_id: u32, f: *Frame) !Value {
        const child = p.functions.items[child_id] orelse return error.BadBytecode;
        const ups = try self.allocator.alloc(*rt.Cell, child.upvalues.items.len);
        for (child.upvalues.items, 0..) |u, i| ups[i] = switch (u.source) {
            .local => try self.ensureCell(f, u.index),
            .upvalue => f.upvalues[u.index],
        };
        const c = try self.allocator.create(rt.Closure);
        c.* = .{ .program = p, .function_id = child_id, .upvalues = ups };
        return .{ .closure = c };
    }

    fn ensureLinkedTables(self: *Vm, p: *const ir.Program) !void {
        if (self.linked_program == p) return;
        if (self.linked_program != null) return error.MultipleLinkedPrograms;
        if (p.function_modules.items.len != p.functions.items.len) return error.NotLinkedProgram;
        self.module_state = try self.allocator.alloc(u8, p.module_roots.items.len);
        @memset(self.module_state, 0);
        self.static_functions = try self.allocator.alloc(Value, p.functions.items.len);
        @memset(self.static_functions, .nil);
        self.linked_program = p;
    }

    fn ensureModule(self: *Vm, p: *const ir.Program, module_id: u32) anyerror!void {
        try self.ensureLinkedTables(p);
        if (module_id >= p.module_roots.items.len) return error.BadBytecode;
        if (self.module_state[module_id] == 2) return;
        if (self.module_state[module_id] == 1) return error.ModuleLoadLoop;
        self.module_state[module_id] = 1;
        errdefer self.module_state[module_id] = 0;
        const init_out = try self.execute(p, p.module_roots.items[module_id], &.{}, &.{});
        freeResults(init_out);
        self.module_state[module_id] = 2;
    }

    fn directFunction(self: *Vm, p: *const ir.Program, function_id: u32) anyerror!Value {
        try self.ensureLinkedTables(p);
        if (function_id >= self.static_functions.len) return error.BadBytecode;
        const module_id = p.function_modules.items[function_id];
        try self.ensureModule(p, module_id);
        if (self.static_functions[function_id] == .nil) return error.UnregisteredStaticFunction;
        return self.static_functions[function_id];
    }

    pub fn executeRoot(self: *Vm, p: *const ir.Program, args: []const Value) anyerror![]const Value {
        return self.execute(p, p.root_function, &.{}, args);
    }

    pub fn execute(self: *Vm, p: *const ir.Program, function_id: u32, upvalues: []const *rt.Cell, args: []const Value) anyerror![]const Value {
        try self.bindGlobals(p);
        if (self.depth >= self.max_depth) return error.CallDepth;
        self.depth += 1;
        defer self.depth -= 1;
        var pc: usize = 0;
        errdefer {
            if (self.failure == null) self.failure = .{ .program = p, .function_id = function_id, .pc = if (pc == 0) 0 else pc - 1 };
        }
        const fun = p.functions.items[function_id] orelse return error.BadBytecode;
        // Register and cell-pointer arrays are call-frame storage. Keep the
        // common case on the native stack: parser-heavy pages execute millions
        // of short Lua calls, and routing every frame through a slab allocator
        // creates large resident freelists. Oversized frames fall back to
        // page-backed storage which is unmapped when the call returns.
        var frame_scratch = std.heap.stackFallback(2048, std.heap.page_allocator);
        const frame_allocator = frame_scratch.get();
        const regs = try frame_allocator.alloc(Value, fun.reg_count);
        defer rawFreeSlice(Value, frame_allocator, regs);
        const param_count: usize = @intCast(fun.param_count);
        if (param_count > regs.len) return error.BadBytecode;
        const nparams = @min(param_count, args.len);
        @memcpy(regs[0..nparams], args[0..nparams]);
        @memset(regs[nparams..param_count], .nil);
        const varargs = if (fun.is_vararg and args.len > fun.param_count) args[fun.param_count..] else &.{};
        var module_id: ?u32 = null;
        if (p.function_modules.items.len == p.functions.items.len and function_id < p.function_modules.items.len) {
            const candidate = p.function_modules.items[function_id];
            if (candidate < p.module_roots.items.len and p.module_roots.items[candidate] == function_id) module_id = candidate;
        }
        var frame = Frame{ .program = p, .regs = regs, .module_id = module_id, .varargs = varargs, .upvalues = upvalues };
        defer if (frame.cells_owned) if (frame.cells) |cells| rawFreeSlice(?*rt.Cell, std.heap.smp_allocator, cells);
        defer if (frame.multi_owned) freeResults(frame.multi);
        while (pc < fun.insts.items.len) {
            const inst = fun.insts.items[pc];
            pc += 1;
            if (comptime instruction_limit != 0) {
                if (self.instructions_left == 0) return error.InstructionLimit;
                self.instructions_left -= 1;
            }

            if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
                switch (inst.op) {
                    .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number, .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => {
                        const x = self.getReg(&frame, inst.a);
                        const y = self.getReg(&frame, inst.b);
                        if (x != .number or y != .number) {
                            std.debug.print("TYPE_PROOF_FAILURE function={d} pc={d} op={s} a={x}:{s} b={x}:{s}\n", .{ function_id, pc - 1, @tagName(inst.op), inst.a, @tagName(x), inst.b, @tagName(y) });
                            return error.InvalidNumberSpecialization;
                        }
                    },
                    .neg_number => if (self.getReg(&frame, inst.a) != .number) {
                        std.debug.print("TYPE_PROOF_FAILURE function={d} pc={d} op={s}\n", .{ function_id, pc - 1, @tagName(inst.op) });
                        return error.InvalidNumberSpecialization;
                    },
                    .len_string => if (self.getReg(&frame, inst.a) != .string) {
                        return error.InvalidStringSpecialization;
                    },
                    else => {},
                }
            }
            switch (inst.op) {
                .detach_cell => {
                    // Old closures retain their heap cell. A subsequent capture
                    // of this local belongs to the new inlined activation.
                    if (frame.cells) |cells| if (cells[inst.a]) |cell| {
                        frame.regs[inst.a] = cell.value;
                        cells[inst.a] = null;
                    };
                },
                .load_nil => self.setReg(&frame, inst.dst, .nil),
                .load_bool => self.setReg(&frame, inst.dst, .{ .boolean = inst.a != 0 }),
                .load_number => self.setReg(&frame, inst.dst, .{ .number = try parseLuaNumber(p.strings.items[inst.aux]) }),
                .load_string => {
                    const value: Value = .{ .string = p.strings.items[inst.aux] };
                    self.setReg(&frame, inst.dst, value);
                    if (pc < fun.insts.items.len) {
                        const next = fun.insts.items[pc];
                        if (next.op == .get_index and next.b == inst.dst) {
                            pc += 1;
                            self.setReg(&frame, next.dst, try self.getIndex(self.getReg(&frame, next.a), value));
                        }
                    }
                },
                .load_const => self.setReg(&frame, inst.dst, try self.materializeConst(p, inst.aux)),
                .get_global_slot => self.setReg(&frame, inst.dst, self.globals.rawGetSlot(inst.aux) orelse .nil),
                .set_global_slot => try self.globals.rawSetSlot(inst.aux, self.getReg(&frame, inst.a)),
                .call_scoped, .call_scoped_vararg => {
                    const target = p.functions.items[inst.a] orelse return error.BadBytecode;
                    var scratch = std.heap.stackFallback(8 * @sizeOf(*rt.Cell), std.heap.smp_allocator);
                    const capture_allocator = scratch.get();
                    const captures = try capture_allocator.alloc(*rt.Cell, target.upvalues.items.len);
                    defer capture_allocator.free(captures);
                    for (target.upvalues.items, 0..) |up, i| captures[i] = switch (up.source) {
                        .local => try self.ensureCell(&frame, up.index),
                        .upvalue => frame.upvalues[up.index],
                    };
                    const argv = try self.buildArgs(&frame, &fun, inst, 0, inst.op == .call_scoped_vararg);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const out = try self.execute(p, inst.a, captures, argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .call_local, .call_local_vararg => {
                    const argv = try self.buildArgs(&frame, &fun, inst, 0, inst.op == .call_local_vararg);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const out = try self.execute(p, inst.a, &.{}, argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .get_global => self.setReg(&frame, inst.dst, self.globals.rawGet(.{ .string = p.strings.items[inst.aux] }) orelse .nil),
                .set_global => try self.globals.rawSet(self.allocator, .{ .string = p.strings.items[inst.aux] }, self.getReg(&frame, inst.a)),
                .get_upvalue => {
                    const value = upvalues[inst.a].value;
                    self.setReg(&frame, inst.dst, value);
                    if (pc < fun.insts.items.len) {
                        const next = fun.insts.items[pc];
                        if ((next.op == .call or next.op == .call_vararg) and next.a == inst.dst) {
                            pc += 1;
                            const argv = try self.buildArgs(&frame, &fun, next, 0, next.op == .call_vararg);
                            defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                            const out = try self.callValue(value, argv);
                            self.storeResults(&frame, next.dst, next.count, out, true);
                        }
                    }
                },
                .set_upvalue => upvalues[inst.a].value = self.getReg(&frame, inst.b),
                .move => {
                    const value = self.getReg(&frame, inst.a);
                    self.setReg(&frame, inst.dst, value);
                    if (pc < fun.insts.items.len) {
                        const next = fun.insts.items[pc];
                        if (next.op == .jump_if_false and next.a == inst.dst) {
                            pc += 1;
                            if (!value.truthy()) pc = next.aux;
                        }
                    }
                },
                .vararg => self.storeResults(&frame, inst.dst, inst.count, varargs, false),
                .new_table => self.setReg(&frame, inst.dst, .{ .table = try rt.newTable(self.allocator) }),
                .new_table_shape => self.setReg(&frame, inst.dst, .{ .table = try rt.newShapedTable(self.allocator, p, inst.aux) }),
                .table_set, .set_index => try self.setIndex(self.getReg(&frame, inst.a), self.getReg(&frame, inst.b), self.getReg(&frame, inst.c)),
                .set_slot => try self.setSlot(self.getReg(&frame, inst.a), inst.aux, self.getReg(&frame, inst.c)),
                .set_choice_slot => try self.setChoice(self.getReg(&frame, inst.a), inst.aux, self.getReg(&frame, inst.b), self.getReg(&frame, inst.c)),
                .table_append => {
                    const t = self.getReg(&frame, inst.a);
                    if (t != .table) return error.TableExpected;
                    try t.table.append(self.allocator, self.getReg(&frame, inst.b));
                },
                .table_append_var => {
                    const t = self.getReg(&frame, inst.a);
                    if (t != .table) return error.TableExpected;
                    for (self.multiAt(&frame, inst.b)) |v| try t.table.append(self.allocator, v);
                },
                .get_index => self.setReg(&frame, inst.dst, try self.getIndex(self.getReg(&frame, inst.a), self.getReg(&frame, inst.b))),
                .get_slot => self.setReg(&frame, inst.dst, try self.getSlot(self.getReg(&frame, inst.a), inst.aux)),
                .get_choice_slot => self.setReg(&frame, inst.dst, try self.getChoice(self.getReg(&frame, inst.a), inst.aux, self.getReg(&frame, inst.b))),
                .get_field => {
                    if (inst.aux >= p.strings.items.len) return error.BadBytecode;
                    self.setReg(&frame, inst.dst, try self.getIndex(self.getReg(&frame, inst.a), .{ .string = p.strings.items[inst.aux] }));
                },
                .set_field => {
                    if (inst.aux >= p.strings.items.len) return error.BadBytecode;
                    try self.setIndex(self.getReg(&frame, inst.a), .{ .string = p.strings.items[inst.aux] }, self.getReg(&frame, inst.c));
                },
                .closure => self.setReg(&frame, inst.dst, try self.makeClosure(p, inst.aux, &frame)),
                .load_function => {
                    const target = p.functions.items[inst.aux] orelse return error.BadBytecode;
                    const env = try self.ensureModuleEnvironment(&frame);
                    for (target.upvalues.items) |up| {
                        if (up.source != .local) return error.BadStaticEnvironment;
                        _ = try self.ensureCell(&frame, up.index);
                    }
                    self.setReg(&frame, inst.dst, .{ .function = .{ .env = env, .function_id = inst.aux } });
                },
                .register_function => {
                    try self.ensureLinkedTables(p);
                    if (inst.aux >= self.static_functions.len) return error.BadBytecode;
                    self.static_functions[inst.aux] = self.getReg(&frame, inst.a);
                },
                .neg => self.setReg(&frame, inst.dst, try rt.unaryNeg(self.getReg(&frame, inst.a))),
                .not_ => {
                    const value: Value = .{ .boolean = !self.getReg(&frame, inst.a).truthy() };
                    self.setReg(&frame, inst.dst, value);
                    if (pc < fun.insts.items.len) {
                        const next = fun.insts.items[pc];
                        if (next.op == .jump_if_false and next.a == inst.dst) {
                            pc += 1;
                            if (!value.boolean) pc = next.aux;
                        }
                    }
                },
                .len => self.setReg(&frame, inst.dst, try rt.len(self.getReg(&frame, inst.a))),
                .add, .sub, .mul, .div, .mod, .pow => self.setReg(&frame, inst.dst, try self.binaryArith(inst.op, self.getReg(&frame, inst.a), self.getReg(&frame, inst.b))),
                .concat => {
                    const rr = fun.operands.items[inst.aux .. inst.aux + inst.count];
                    const vals = try std.heap.smp_allocator.alloc(Value, rr.len);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, vals);
                    for (rr, 0..) |r, i| vals[i] = self.getReg(&frame, r);
                    self.setReg(&frame, inst.dst, try self.concatValues(vals));
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const result = try self.comparison(inst.op, self.getReg(&frame, inst.a), self.getReg(&frame, inst.b));
                    self.setReg(&frame, inst.dst, .{ .boolean = result });
                    if (pc < fun.insts.items.len) {
                        const next = fun.insts.items[pc];
                        if (next.op == .jump_if_false and next.a == inst.dst) {
                            pc += 1;
                            if (!result) pc = next.aux;
                        }
                    }
                },
                .branch_compare => {
                    const op = try @import("vm_semantics.zig").comparisonOpcode(inst.count);
                    const result = switch (op) {
                        .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => blk: {
                            const x = self.getNumber(&frame, inst.a);
                            const y = self.getNumber(&frame, inst.b);
                            break :blk switch (op) {
                                .eq_number => x == y,
                                .ne_number => x != y,
                                .lt_number => x < y,
                                .le_number => x <= y,
                                .gt_number => x > y,
                                .ge_number => x >= y,
                                else => unreachable,
                            };
                        },
                        .eq, .ne, .lt, .le, .gt, .ge => try self.comparison(op, self.getReg(&frame, inst.a), self.getReg(&frame, inst.b)),
                        else => return error.BadBytecode,
                    };
                    if (!result) pc = inst.aux;
                },
                .jump => pc = inst.aux,

                .jump_if_false => {
                    if (!self.getReg(&frame, inst.a).truthy()) pc = inst.aux;
                },
                .check_table_key => {
                    const key = self.getReg(&frame, inst.a);
                    if (key == .nil) return error.NilTableKey;
                    if (key == .number and std.math.isNan(key.number)) return error.NaNTableKey;
                },
                .add_number, .sub_number, .mul_number, .div_number, .mod_number, .pow_number => {
                    const x = self.getNumber(&frame, inst.a);
                    const y = self.getNumber(&frame, inst.b);
                    const z = switch (inst.op) {
                        .add_number => x + y,
                        .sub_number => x - y,
                        .mul_number => x * y,
                        .div_number => x / y,
                        .mod_number => x - @floor(x / y) * y,
                        .pow_number => std.math.pow(f64, x, y),
                        else => unreachable,
                    };
                    self.setReg(&frame, inst.dst, .{ .number = z });
                },
                .eq_number, .ne_number, .lt_number, .le_number, .gt_number, .ge_number => {
                    const x = self.getNumber(&frame, inst.a);
                    const y = self.getNumber(&frame, inst.b);
                    const z = switch (inst.op) {
                        .eq_number => x == y,
                        .ne_number => x != y,
                        .lt_number => x < y,
                        .le_number => x <= y,
                        .gt_number => x > y,
                        .ge_number => x >= y,
                        else => unreachable,
                    };
                    self.setReg(&frame, inst.dst, .{ .boolean = z });
                },
                .neg_number => self.setReg(&frame, inst.dst, .{ .number = -self.getNumber(&frame, inst.a) }),
                .len_string => self.setReg(&frame, inst.dst, .{ .number = @floatFromInt(self.getReg(&frame, inst.a).string.len) }),
                .init_module => try self.ensureModule(p, inst.aux),
                .call, .call_vararg => {
                    const argv = try self.buildArgs(&frame, &fun, inst, 0, inst.op == .call_vararg);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const out = try self.callValue(self.getReg(&frame, inst.a), argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .direct_call, .direct_call_vararg => {
                    const argv = try self.buildArgs(&frame, &fun, inst, 0, inst.op == .direct_call_vararg);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const callable = try self.directFunction(p, inst.a);
                    const out = try self.callValue(callable, argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .method_call, .method_call_vararg => {
                    const fixed = fun.operands.items[inst.aux .. inst.aux + inst.b];
                    if (fixed.len < 2) return error.BadBytecode;
                    const key = self.getReg(&frame, fixed[0]);
                    const object = self.getReg(&frame, fixed[1]);
                    const method = try self.getIndex(object, key);
                    const argv = try self.buildArgs(&frame, &fun, inst, 1, inst.op == .method_call_vararg); // skip method-key, retain self
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const out = try self.callValue(method, argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .method_call_field, .method_call_field_vararg => {
                    if (inst.a >= p.strings.items.len) return error.BadBytecode;
                    const fixed = fun.operands.items[inst.aux .. inst.aux + inst.b];
                    if (fixed.len < 1) return error.BadBytecode;
                    const object = self.getReg(&frame, fixed[0]);
                    const method = try self.getIndex(object, .{ .string = p.strings.items[inst.a] });
                    const argv = try self.buildArgs(&frame, &fun, inst, 0, inst.op == .method_call_field_vararg);
                    defer rawFreeSlice(Value, std.heap.smp_allocator, argv);
                    const out = try self.callValue(method, argv);
                    self.storeResults(&frame, inst.dst, inst.count, out, true);
                },
                .numeric_for_init => {
                    const cur = rt.toNumber(self.getReg(&frame, inst.a)) orelse return error.NumericForType;
                    const lim = rt.toNumber(self.getReg(&frame, inst.b)) orelse return error.NumericForType;
                    const step = rt.toNumber(self.getReg(&frame, inst.c)) orelse return error.NumericForType;
                    if ((step > 0 and cur <= lim) or (step <= 0 and cur >= lim)) self.setReg(&frame, inst.dst, .{ .number = cur }) else pc = inst.aux;
                },
                .numeric_for_next => {
                    const cur = (rt.toNumber(self.getReg(&frame, inst.a)) orelse return error.NumericForType) + (rt.toNumber(self.getReg(&frame, inst.c)) orelse return error.NumericForType);
                    self.setReg(&frame, inst.a, .{ .number = cur });
                    const lim = rt.toNumber(self.getReg(&frame, inst.b)) orelse return error.NumericForType;
                    const step = rt.toNumber(self.getReg(&frame, inst.c)) orelse return error.NumericForType;
                    if ((step > 0 and cur <= lim) or (step <= 0 and cur >= lim)) {
                        self.setReg(&frame, inst.dst, .{ .number = cur });
                        pc = inst.aux;
                    }
                },
                .generic_for_init, .generic_for_next => {
                    const iterator = self.getReg(&frame, inst.a);
                    const state = self.getReg(&frame, inst.b);
                    const control = self.getReg(&frame, inst.c);
                    const out = try self.callValue(iterator, &.{ state, control });
                    defer freeResults(out);
                    const first = if (out.len == 0) Value.nil else out[0];
                    if (first == .nil) {
                        if (inst.op == .generic_for_init) pc = inst.aux;
                    } else {
                        self.setReg(&frame, inst.c, first);
                        var i: u32 = 0;
                        while (i < inst.count) : (i += 1) self.setReg(&frame, inst.dst + i, if (i < out.len) out[i] else .nil);
                        if (inst.op == .generic_for_next) pc = inst.aux;
                    }
                },
                .ret => {
                    const out = try std.heap.smp_allocator.alloc(Value, inst.count);
                    for (fun.operands.items[inst.aux .. inst.aux + inst.count], 0..) |r, i| out[i] = self.getReg(&frame, r);
                    return out;
                },
                .ret_var => {
                    const tail = self.multiAt(&frame, inst.a);
                    const out = try std.heap.smp_allocator.alloc(Value, inst.count + tail.len);
                    for (fun.operands.items[inst.aux .. inst.aux + inst.count], 0..) |r, i| out[i] = self.getReg(&frame, r);
                    @memcpy(out[inst.count..], tail);
                    return out;
                },
            }
        }
        return &.{};
    }
};

fn nativePairs(_: ?*anyopaque, vm_raw: *anyopaque, args: []const Value, a: std.mem.Allocator) anyerror![]const Value {
    _ = vm_raw;
    _ = args;
    _ = a;
    return error.NotImplemented;
}

fn installMinimalGlobals(vm: *Vm) !void {
    _ = nativePairs;
    const type_fn = try rt.newNative(vm.allocator, null, struct {
        fn call(_: ?*anyopaque, _: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
            const name = if (args.len == 0) "nil" else switch (args[0]) {
                .nil => "nil",
                .boolean => "boolean",
                .number => "number",
                .string => "string",
                .table => "table",
                .closure, .function, .native => "function",
            };
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = .{ .string = name };
            return out;
        }
    }.call);
    try vm.setGlobal("type", type_fn);
}

fn installMetatableGlobalsForTest(vm: *Vm) !void {
    const get_mt = try rt.newNative(vm.allocator, null, struct {
        fn call(_: ?*anyopaque, _: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            if (args.len == 0 or args[0] != .table or args[0].table.metatable == null) {
                out[0] = .nil;
                return out;
            }
            const mt = args[0].table.metatable.?;
            out[0] = mt.rawGet(.{ .string = "__metatable" }) orelse .{ .table = mt };
            return out;
        }
    }.call);
    const set_mt = try rt.newNative(vm.allocator, null, struct {
        fn call(_: ?*anyopaque, _: *anyopaque, args: []const Value, _: std.mem.Allocator) ![]const Value {
            if (args.len < 2 or args[0] != .table) return error.TableExpected;
            args[0].table.metatable = switch (args[1]) {
                .nil => null,
                .table => |t| t,
                else => return error.TableExpected,
            };
            const out = try std.heap.smp_allocator.alloc(Value, 1);
            out[0] = args[0];
            return out;
        }
    }.call);
    try vm.setGlobal("getmetatable", get_mt);
    try vm.setGlobal("setmetatable", set_mt);
}

test "concat values intern duplicate strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    const first = try vm.concatValues(&.{ .{ .string = "memo" }, .{ .number = 42 } });
    const second = try vm.concatValues(&.{ .{ .string = "memo" }, .{ .number = 42 } });
    try std.testing.expect(first == .string and second == .string);
    try std.testing.expectEqualStrings("memo42", first.string);
    try std.testing.expectEqual(@intFromPtr(first.string.ptr), @intFromPtr(second.string.ptr));
}

test "execute closures, tables, loops, and multi return" {
    const src =
        \\local x = 3
        \\local function pair(a) return a, a .. "!" end
        \\local function f(s)
        \\  local t = {k = x}
        \\  local a,b = pair(s)
        \\  local sum = 0
        \\  for i=1,3 do sum = sum + i end
        \\  return a .. b, t.k, sum
        \\end
        \\return f("q")
    ;
    var chunk = try lua.parse(std.testing.allocator, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    try installMinimalGlobals(&vm);
    const out = try vm.executeRoot(&p, &.{});
    try std.testing.expectEqualStrings("qq!", out[0].string);
    try std.testing.expectEqual(@as(f64, 3), out[1].number);
    try std.testing.expectEqual(@as(f64, 6), out[2].number);
}

test "if else bodies are always lowered" {
    const src =
        \\local function f(x)
        \\  local y = "unset"
        \\  if x == 1 then y = "one" else y = "other" end
        \\  return y
        \\end
        \\return f(2), f(1)
    ;
    var chunk = try lua.parse(std.testing.allocator, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    try std.testing.expectEqualStrings("other", out[0].string);
    try std.testing.expectEqualStrings("one", out[1].string);
}

test "assignment snapshots locals and indexed lvalues" {
    const src =
        \\local i = 1
        \\local t = {}
        \\i, t[i] = 2, "old"
        \\return i, t[1], t[2]
    ;
    var chunk = try lua.parse(std.testing.allocator, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    const out = try vm.executeRoot(&p, &.{});
    try std.testing.expectEqual(@as(f64, 2), out[0].number);
    try std.testing.expectEqualStrings("old", out[1].string);
    try std.testing.expect(out[2] == .nil);
}

test "make_stack function-valued __index keeps raw layers" {
    const src =
        \\local function make_stack(data)
        \\  local function __index(self, k)
        \\    local stack = getmetatable(self)
        \\    local n = stack[make_stack]
        \\    while true do
        \\      local layer = stack[n]
        \\      if not layer then return nil end
        \\      local v = layer[k]
        \\      if v ~= nil then return v end
        \\      n = n - 1
        \\    end
        \\  end
        \\  function make_stack(data)
        \\    local stack = {data, [make_stack] = 1, __index = __index}
        \\    stack.__metatable = stack
        \\    return setmetatable({}, stack), stack
        \\  end
        \\  return make_stack(data)
        \\end
        \\local base, stack = make_stack({parent = "P"})
        \\local data = {child = "C"}
        \\local n = stack[make_stack] + 1
        \\data, stack[n], stack[make_stack] = base, data, n
        \\return data.child, data.parent, stack[n] == data
    ;
    var chunk = try lua.parse(std.testing.allocator, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    try installMetatableGlobalsForTest(&vm);
    const out = try vm.executeRoot(&p, &.{});
    try std.testing.expectEqualStrings("C", out[0].string);
    try std.testing.expectEqualStrings("P", out[1].string);
    try std.testing.expect(out[2] == .boolean and !out[2].boolean);
}
