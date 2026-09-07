const std = @import("std");
const ir = @import("vm_ir.zig");

const magic = "DWVM\x02";

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

pub fn deserialize(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, true);
}

pub fn deserializeBorrowed(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, false);
}

fn deserializeImpl(a: std.mem.Allocator, bytes: []const u8, copy_strings: bool) !ir.Program {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
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
            if (ot > @intFromEnum(ir.Opcode.ret_var)) return error.BadOpcode;
            try f.insts.append(a, .{ .op = @enumFromInt(ot), .dst = try asU32(try getVar(bytes, &pos)), .a = try asU32(try getVar(bytes, &pos)), .b = try asU32(try getVar(bytes, &pos)), .c = try asU32(try getVar(bytes, &pos)), .aux = try asU32(try getVar(bytes, &pos)), .count = try asU32(try getVar(bytes, &pos)) });
        }
        try p.functions.append(a, f);
    }
    if (pos != bytes.len) return error.TrailingData;
    return p;
}
