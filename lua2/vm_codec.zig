const std = @import("std");
const ir = @import("vm_ir.zig");
const lua = @import("root.zig");

pub const magic = "DWVM\x03";
pub fn bytecodeVersion(bytes: []const u8) !u8 {
    if (bytes.len < 5 or !std.mem.eql(u8, bytes[0..4], "DWVM")) return error.BadMagic;
    if (bytes[4] != 2 and bytes[4] != 3) return error.BadMagic;
    return bytes[4];
}

fn putVar(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try out.append(a, @intCast((v & 0x7f) | 0x80));
    try out.append(a, @intCast(v));
}
fn getVar(bytes: []const u8, pos: *usize) !u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= bytes.len) return error.Truncated;
        const b = bytes[pos.*];
        pos.* += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return v;
        if (shift >= 63 - 7) return error.BadVarint;
        shift += 7;
    }
}
fn asU32(v: u64) !u32 {
    return std.math.cast(u32, v) orelse error.IntegerOverflow;
}

pub fn serialize(a: std.mem.Allocator, p: *const ir.Program) ![]u8 {
    return serializeVersion(a, p, 3);
}
pub fn serializeVersion(a: std.mem.Allocator, p: *const ir.Program, version: u8) ![]u8 {
    if (version != 2 and version != 3) return error.BadMagic;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 'D', 'W', 'V', 'M', version });
    try putVar(&out, a, p.root_function);
    try putVar(&out, a, p.strings.items.len);
    try putVar(&out, a, p.constants.items.len);
    try putVar(&out, a, p.const_entries.items.len);
    try putVar(&out, a, p.functions.items.len);
    for (p.strings.items) |s| {
        try putVar(&out, a, s.len);
        try out.appendSlice(a, s);
    }
    for (p.constants.items) |node| switch (node) {
        .nil => try out.append(a, 0),
        .boolean => |v| {
            try out.append(a, 1);
            try out.append(a, @intFromBool(v));
        },
        .number => |id| {
            try out.append(a, 2);
            try putVar(&out, a, id);
        },
        .string => |id| {
            try out.append(a, 3);
            try putVar(&out, a, id);
        },
        .integer => |v| {
            try out.append(a, 4);
            try putVar(&out, a, v);
        },
        .table => |t| {
            try out.append(a, 5);
            try putVar(&out, a, t.first);
            try putVar(&out, a, t.count);
        },
    };
    for (p.const_entries.items) |e| {
        try putVar(&out, a, e.key);
        try putVar(&out, a, e.value);
    }
    for (p.functions.items) |mf| {
        const f = mf orelse return error.IncompleteProgram;
        try putVar(&out, a, f.param_count);
        try out.append(a, @intFromBool(f.is_vararg));
        try putVar(&out, a, f.reg_count);
        try putVar(&out, a, f.upvalues.items.len);
        for (f.upvalues.items) |u| {
            try out.append(a, @intFromEnum(u.source));
            try putVar(&out, a, u.index);
        }
        try putVar(&out, a, f.operands.items.len);
        for (f.operands.items) |v| try putVar(&out, a, v);
        try putVar(&out, a, f.insts.items.len);
        for (f.insts.items) |x| {
            if (version == 2 and @intFromEnum(x.op) > @intFromEnum(ir.Opcode.ret_var)) return error.IncompatibleBytecode;
            try out.append(a, @intFromEnum(x.op));
            try putVar(&out, a, x.dst);
            try putVar(&out, a, x.a);
            try putVar(&out, a, x.b);
            try putVar(&out, a, x.c);
            try putVar(&out, a, x.aux);
            try putVar(&out, a, x.count);
        }
    }
    return out.toOwnedSlice(a);
}

pub fn deserialize(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, true);
}

pub fn deserializeBorrowed(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, false);
}

fn deserializeImpl(a: std.mem.Allocator, bytes: []const u8, copy_strings: bool) !ir.Program {
    const version = try bytecodeVersion(bytes);
    var pos: usize = magic.len;
    var p = ir.Program{ .allocator = a, .root_function = try asU32(try getVar(bytes, &pos)) };
    errdefer p.deinit();
    const ns = try asU32(try getVar(bytes, &pos));
    const nc = try asU32(try getVar(bytes, &pos));
    const ne = try asU32(try getVar(bytes, &pos));
    const nf = try asU32(try getVar(bytes, &pos));
    try p.strings.ensureTotalCapacity(a, ns);
    for (0..ns) |_| {
        const n = try asU32(try getVar(bytes, &pos));
        if (pos + n > bytes.len) return error.Truncated;
        const value = if (copy_strings) try a.dupe(u8, bytes[pos .. pos + n]) else bytes[pos .. pos + n];
        if (copy_strings) p.owned_strings.append(a, @constCast(value)) catch |err| {
            a.free(value);
            return err;
        };
        try p.strings.append(a, value);

        pos += n;
    }
    try p.constants.ensureTotalCapacity(a, nc);
    for (0..nc) |_| {
        if (pos >= bytes.len) return error.Truncated;
        const tag = bytes[pos];
        pos += 1;
        const node: ir.ConstNode = switch (tag) {
            0 => .nil,
            1 => blk: {
                if (pos >= bytes.len) return error.Truncated;
                const b = bytes[pos];
                pos += 1;
                break :blk .{ .boolean = b != 0 };
            },
            2 => .{ .number = try asU32(try getVar(bytes, &pos)) },
            3 => .{ .string = try asU32(try getVar(bytes, &pos)) },
            4 => .{ .integer = try asU32(try getVar(bytes, &pos)) },
            5 => .{ .table = .{ .first = try asU32(try getVar(bytes, &pos)), .count = try asU32(try getVar(bytes, &pos)) } },
            else => return error.BadConstTag,
        };
        try p.constants.append(a, node);
    }
    try p.const_entries.ensureTotalCapacity(a, ne);
    for (0..ne) |_| try p.const_entries.append(a, .{ .key = try asU32(try getVar(bytes, &pos)), .value = try asU32(try getVar(bytes, &pos)) });
    try p.functions.ensureTotalCapacity(a, nf);
    for (0..nf) |_| {
        var f = ir.Function{};
        errdefer f.deinit(a);
        f.param_count = try asU32(try getVar(bytes, &pos));
        if (pos >= bytes.len) return error.Truncated;
        f.is_vararg = bytes[pos] != 0;
        pos += 1;
        f.reg_count = try asU32(try getVar(bytes, &pos));
        const nu = try asU32(try getVar(bytes, &pos));
        try f.upvalues.ensureTotalCapacity(a, nu);
        for (0..nu) |_| {
            if (pos >= bytes.len) return error.Truncated;
            const st = bytes[pos];
            pos += 1;
            if (st > @intFromEnum(ir.UpvalueSource.upvalue)) return error.BadUpvalue;
            try f.upvalues.append(a, .{ .source = @enumFromInt(st), .index = try asU32(try getVar(bytes, &pos)) });
        }
        const no = try asU32(try getVar(bytes, &pos));
        try f.operands.ensureTotalCapacity(a, no);
        for (0..no) |_| try f.operands.append(a, try asU32(try getVar(bytes, &pos)));
        const ni = try asU32(try getVar(bytes, &pos));
        try f.insts.ensureTotalCapacity(a, ni);
        for (0..ni) |_| {
            if (pos >= bytes.len) return error.Truncated;
            const ot = bytes[pos];
            pos += 1;
            if (ot > @intFromEnum(if (version == 2) ir.Opcode.ret_var else ir.Opcode.set_global_slot)) return error.BadOpcode;
            const inst = ir.Inst{ .op = @enumFromInt(ot), .dst = try asU32(try getVar(bytes, &pos)), .a = try asU32(try getVar(bytes, &pos)), .b = try asU32(try getVar(bytes, &pos)), .c = try asU32(try getVar(bytes, &pos)), .aux = try asU32(try getVar(bytes, &pos)), .count = try asU32(try getVar(bytes, &pos)) };
            if (inst.op == .get_global_slot or inst.op == .set_global_slot) {
                if (inst.aux >= @import("vm_global_abi.zig").count) return error.BadGlobalSlot;
                const reg = if (inst.op == .get_global_slot) inst.dst else inst.a;
                if (reg >= f.reg_count) return error.BadRegister;
            }
            try f.insts.append(a, inst);
        }
        try p.functions.append(a, f);
    }
    if (pos != bytes.len) return error.TrailingData;
    return p;
}

test "full IR codec roundtrip" {
    const src = "local function f(x, ...) local t={x, k='v'} if x then return t, ... end return nil end return f";
    var chunk = try lua.parse(std.testing.allocator, src);
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const blob = try serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(blob);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try deserialize(arena.allocator(), blob);
    try std.testing.expectEqual(p.functions.items.len, q.functions.items.len);
    try std.testing.expectEqual(p.constants.items.len, q.constants.items.len);
    try std.testing.expectEqual(p.strings.items.len, q.strings.items.len);
}

test "owning decode releases copied strings while borrowed decode does not own them" {
    const a = std.testing.allocator;
    var chunk = try @import("root.zig").parse(a, "return 'retained'");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    const bytes = try serialize(a, &p);
    defer a.free(bytes);
    var owned = try deserialize(a, bytes);
    defer owned.deinit();
    var borrowed = try deserializeBorrowed(a, bytes);
    defer borrowed.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.owned_strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), borrowed.owned_strings.items.len);
    try std.testing.expectEqualStrings(owned.strings.items[0], borrowed.strings.items[0]);
    try std.testing.expect(owned.strings.items[0].ptr != borrowed.strings.items[0].ptr);
}
