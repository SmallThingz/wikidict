const refs = @import("vm_ref.zig");
const sem = @import("vm_semantics.zig");
const std = @import("std");
const ir = @import("vm_ir.zig");
const wire = @import("vm_wire.zig");
const legacy = @import("vm_codec_v2.zig");
const legacy_v3 = @import("vm_codec_v3.zig");
const exec = @import("vm_exec.zig");
const verify = @import("vm_verify.zig");
const static_fields = @import("vm_static_field_abi.zig");
const shape_key = @import("vm_shape_key.zig");
pub const magic = "DWVM\x10";
const putVar = wire.putVar;
const getVar = wire.getVar;
const asU32 = wire.asU32;

pub fn bytecodeVersion(bytes: []const u8) !u8 {
    if (bytes.len < 5 or !std.mem.eql(u8, bytes[0..4], "DWVM")) return error.BadMagic;
    return switch (bytes[4]) {
        2, 3, 9, 10, 11, 12, 13, 14, 15, 16 => bytes[4],
        else => error.BadMagic,
    };
}

fn putNumber(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bits: u64) !void {
    const n: f64 = @bitCast(bits);
    if (std.math.isFinite(n) and @floor(n) == n and n >= -9223372036854775808.0 and n < 9223372036854775808.0 and bits != 0x8000000000000000) {
        try out.append(allocator, 7);
        try putVar(out, allocator, wire.zigzag(@intFromFloat(n)));
    } else {
        try out.append(allocator, 6);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, bits, .little);
        try out.appendSlice(allocator, &bytes);
    }
}
fn hasStaticFieldRefs(p: *const ir.Program) bool {
    for (p.functions.items) |maybe| if (maybe) |f| {
        for (f.insts.items) |inst| {
            if ((inst.op == .get_slot or inst.op == .set_slot) and static_fields.nameForRef(inst.aux) != null) return true;
        }
    };
    return false;
}

fn hasNumericShapeKeys(p: *const ir.Program) bool {
    for (p.shapes.items) |shape| for (shape.field_keys.items) |key|
        if (shape_key.integerValue(key) != null) return true;
    return false;
}

pub fn serializeVersion(allocator: std.mem.Allocator, p: *const ir.Program, version: u8) ![]u8 {
    if (version == 2 or version == 3) return legacy_v3.serializeVersion(allocator, p, version);
    if (version == 16) return serialize(allocator, p);
    if (version == 15) {
        if (hasNumericShapeKeys(p)) return error.BadShapeKeyVersion;
        const out = try serialize(allocator, p);
        out[4] = 15;
        return out;
    }
    if (version == 14) {
        if (hasStaticFieldRefs(p) or hasNumericShapeKeys(p)) return error.BadOpcodeVersion;
        const out = try serialize(allocator, p);
        out[4] = 14;
        return out;
    }
    return error.BadMagic;
}

pub fn serialize(allocator: std.mem.Allocator, p: *const ir.Program) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try putVar(&out, allocator, p.root_function);
    try putVar(&out, allocator, p.strings.items.len);
    try putVar(&out, allocator, p.constants.items.len);
    try putVar(&out, allocator, p.const_entries.items.len);
    try putVar(&out, allocator, p.functions.items.len);
    try putVar(&out, allocator, p.shapes.items.len);
    try putVar(&out, allocator, p.module_roots.items.len);
    try putVar(&out, allocator, if (p.global_shape) |id| @as(u64, id) + 1 else 0);
    // Offsets are derived during loading, not duplicated in the artifact.
    for (p.strings.items) |text| try putVar(&out, allocator, text.len);
    for (p.strings.items) |text| try out.appendSlice(allocator, text);
    for (p.constants.items) |node| switch (node) {
        .nil => try out.append(allocator, 0),
        .boolean => |v| {
            try out.append(allocator, 1);
            try out.append(allocator, @intFromBool(v));
        },
        .number => |sid| try putNumber(&out, allocator, @bitCast(try exec.Vm.parseLuaNumber(p.strings.items[sid]))),
        .number_bits => |bits| try putNumber(&out, allocator, bits),
        .string => |sid| {
            try out.append(allocator, 3);
            try putVar(&out, allocator, sid);
        },
        .integer => |n| {
            try out.append(allocator, 4);
            try putVar(&out, allocator, n);
        },
        .table => |table| {
            try out.append(allocator, 5);
            try putVar(&out, allocator, table.first);
            try putVar(&out, allocator, table.count);
        },
    };
    for (p.const_entries.items) |entry| {
        try putVar(&out, allocator, if (entry.key == ir.implicit_list_key) 0 else @as(u64, entry.key) + 1);
        try putVar(&out, allocator, entry.value);
    }
    for (p.shapes.items) |shape| {
        try putVar(&out, allocator, shape.field_count);
        try putVar(&out, allocator, shape.choice_count);
        try out.append(allocator, @as(u8, @intFromBool(shape.open)) | (if (shape.field_keys.items.len != 0) @as(u8, 2) else 0));
        for (shape.field_keys.items) |sid| try putVar(&out, allocator, sid);
    }
    for (p.module_roots.items) |root| try putVar(&out, allocator, root);
    if (p.module_roots.items.len != 0 and p.function_modules.items.len != p.functions.items.len) return error.BadModuleMap;
    for (p.functions.items, 0..) |maybe, id| {
        const f = maybe orelse return error.IncompleteProgram;
        if (p.module_roots.items.len != 0) try putVar(&out, allocator, p.function_modules.items[id]);
        try putVar(&out, allocator, f.param_count);
        var packed_operands = true;
        var reference_operands = false;
        for (f.operands.items) |value| {
            packed_operands = packed_operands and value < 16;
            reference_operands = reference_operands or !refs.isRegister(value);
        }
        try out.append(allocator, @as(u8, @intFromBool(f.is_vararg)) | (if (packed_operands) @as(u8, 2) else 0) | (if (reference_operands) @as(u8, 4) else 0));
        try putVar(&out, allocator, f.reg_count);
        try putVar(&out, allocator, f.upvalues.items.len);
        for (f.upvalues.items) |up| {
            try putVar(&out, allocator, (@as(u64, up.index) << 1) | @intFromEnum(up.source));
        }
        try putVar(&out, allocator, f.operands.items.len);
        if (packed_operands) {
            var i: usize = 0;
            while (i < f.operands.items.len) : (i += 2) {
                const lo = f.operands.items[i];
                const hi = if (i + 1 < f.operands.items.len) f.operands.items[i + 1] else 0;
                if (lo >= 16 or hi >= 16) return error.BadRegister;
                try out.append(allocator, @intCast(lo | (hi << 4)));
            }
        } else for (f.operands.items) |value| try putVar(&out, allocator, if (reference_operands) try refs.encode(value) else value);
        try putVar(&out, allocator, f.insts.items.len);
        for (f.insts.items, 0..) |inst, pc| try wire.writeInst(&out, allocator, @intCast(pc), inst);
    }
    return out.toOwnedSlice(allocator);
}
pub fn deserialize(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, true);
}
pub fn deserializeBorrowed(a: std.mem.Allocator, bytes: []const u8) !ir.Program {
    return deserializeImpl(a, bytes, false);
}
fn byteAt(bytes: []const u8, pos: *usize) !u8 {
    if (pos.* >= bytes.len) return error.Truncated;
    const byte = bytes[pos.*];
    pos.* += 1;
    return byte;
}
fn boundedCount(bytes: []const u8, pos: *usize) !u32 {
    const n = try asU32(try getVar(bytes, pos));
    if (n > bytes.len - pos.*) return error.Truncated;
    return n;
}
fn deserializeImpl(a: std.mem.Allocator, bytes: []const u8, copy: bool) !ir.Program {
    if (bytes.len >= 5 and std.mem.eql(u8, bytes[0..5], "DWVM\x02"))
        return if (copy) legacy.deserialize(a, bytes) else legacy.deserializeBorrowed(a, bytes);
    if (bytes.len >= 5 and std.mem.eql(u8, bytes[0..5], "DWVM\x03"))
        return if (copy) legacy_v3.deserialize(a, bytes) else legacy_v3.deserializeBorrowed(a, bytes);
    const has_reference_format = bytes.len >= 5 and (std.mem.eql(u8, bytes[0..5], magic) or std.mem.eql(u8, bytes[0..5], "DWVM\x0f") or std.mem.eql(u8, bytes[0..5], "DWVM\x0e") or std.mem.eql(u8, bytes[0..5], "DWVM\x0d") or std.mem.eql(u8, bytes[0..5], "DWVM\x0c") or std.mem.eql(u8, bytes[0..5], "DWVM\x0b") or std.mem.eql(u8, bytes[0..5], "DWVM\x0a"));
    const old_v9 = bytes.len >= 5 and std.mem.eql(u8, bytes[0..5], "DWVM\x09");
    if (!has_reference_format and !old_v9) return error.BadMagic;
    var pos: usize = magic.len;
    var p = ir.Program{ .allocator = a, .root_function = try asU32(try getVar(bytes, &pos)) };
    errdefer p.deinit();
    const ns = try boundedCount(bytes, &pos);
    const nc = try boundedCount(bytes, &pos);
    const ne = try boundedCount(bytes, &pos);
    const nf = try boundedCount(bytes, &pos);
    const nsh = try boundedCount(bytes, &pos);
    const nm = try boundedCount(bytes, &pos);
    if (bytes[4] >= 13) {
        const shape = try getVar(bytes, &pos);
        if (shape > nsh) return error.BadGlobalLayout;
        p.global_shape = if (shape == 0) null else try asU32(shape - 1);
    }
    const lengths = try a.alloc(u32, ns);
    defer a.free(lengths);
    var string_bytes: usize = 0;
    for (lengths) |*len| {
        len.* = try asU32(try getVar(bytes, &pos));
        string_bytes = try std.math.add(usize, string_bytes, len.*);
    }
    if (string_bytes > bytes.len - pos) return error.Truncated;
    const storage = if (copy) try a.dupe(u8, bytes[pos..][0..string_bytes]) else bytes[pos..][0..string_bytes];
    if (copy) p.owned_strings.append(a, @constCast(storage)) catch |err| {
        a.free(storage);
        return err;
    };
    var offset: usize = 0;
    for (lengths) |len| {
        try p.strings.append(a, storage[offset..][0..len]);
        offset += len;
    }
    pos += string_bytes;
    for (0..nc) |_| {
        const tag = try byteAt(bytes, &pos);
        const node: ir.ConstNode = switch (tag) {
            0 => .nil,
            1 => blk: {
                const b = try byteAt(bytes, &pos);
                if (b > 1) return error.BadBoolean;
                break :blk .{ .boolean = b != 0 };
            },
            3 => .{ .string = try asU32(try getVar(bytes, &pos)) },
            4 => .{ .integer = try asU32(try getVar(bytes, &pos)) },
            5 => .{ .table = .{ .first = try asU32(try getVar(bytes, &pos)), .count = try asU32(try getVar(bytes, &pos)) } },
            6 => blk: {
                if (bytes.len - pos < 8) return error.Truncated;
                const bits = std.mem.readInt(u64, bytes[pos..][0..8], .little);
                pos += 8;
                break :blk .{ .number_bits = bits };
            },
            7 => blk: {
                const n: f64 = @floatFromInt(wire.unzigzag(try getVar(bytes, &pos)));
                break :blk .{ .number_bits = @bitCast(n) };
            },
            else => return error.BadConstTag,
        };
        try p.constants.append(a, node);
    }
    for (0..ne) |_| {
        const key = try getVar(bytes, &pos);
        try p.const_entries.append(a, .{ .key = if (key == 0) ir.implicit_list_key else try asU32(key - 1), .value = try asU32(try getVar(bytes, &pos)) });
    }
    for (0..nsh) |_| {
        var shape = ir.Shape{ .field_count = try asU32(try getVar(bytes, &pos)), .choice_count = try asU32(try getVar(bytes, &pos)) };
        errdefer shape.deinit(a);
        const flags = try byteAt(bytes, &pos);
        if (flags > 3) return error.BadShape;
        shape.open = flags & 1 != 0;
        if (flags & 2 != 0) {
            if (shape.field_count > bytes.len - pos) return error.Truncated;
            for (0..shape.field_count) |_| {
                const key = try asU32(try getVar(bytes, &pos));
                if (bytes[4] < 16 and shape_key.integerValue(key) != null) return error.BadShapeKeyVersion;
                try shape.field_keys.append(a, key);
            }
        }
        try p.shapes.append(a, shape);
    }
    for (0..nm) |_| try p.module_roots.append(a, try asU32(try getVar(bytes, &pos)));
    for (0..nf) |_| {
        var f = ir.Function{};
        errdefer f.deinit(a);
        if (nm != 0) try p.function_modules.append(a, try asU32(try getVar(bytes, &pos)));
        f.param_count = try asU32(try getVar(bytes, &pos));
        const flags = try byteAt(bytes, &pos);
        if (flags > (if (has_reference_format) @as(u8, 7) else 3)) return error.BadFunctionFlags;
        f.is_vararg = flags & 1 != 0;
        f.reg_count = try asU32(try getVar(bytes, &pos));
        const nu = try boundedCount(bytes, &pos);
        for (0..nu) |_| {
            const up = try getVar(bytes, &pos);
            try f.upvalues.append(a, .{ .source = @enumFromInt(up & 1), .index = try asU32(up >> 1) });
        }
        const no = try asU32(try getVar(bytes, &pos));
        if (flags & 2 != 0) {
            if ((@as(u64, no) + 1) / 2 > bytes.len - pos) return error.Truncated;
            var i: u32 = 0;
            while (i < no) : (i += 2) {
                const byte = try byteAt(bytes, &pos);
                try f.operands.append(a, byte & 15);
                if (i + 1 < no) try f.operands.append(a, byte >> 4) else if (byte >> 4 != 0) return error.BadRegisterPadding;
            }
        } else {
            if (no > bytes.len - pos) return error.Truncated;
            for (0..no) |_| {
                const value = try getVar(bytes, &pos);
                try f.operands.append(a, if (flags & 4 != 0) try refs.decode(value) else try asU32(value));
            }
        }
        const ni = try boundedCount(bytes, &pos);
        for (0..ni) |pc| {
            const inst = try wire.readInstVersion(bytes, &pos, @intCast(pc), ni, has_reference_format);
            if (bytes[4] < 13 and @intFromEnum(inst.op) >= @intFromEnum(ir.Opcode.get_global_slot)) return error.BadOpcodeVersion;
            if (bytes[4] < 14 and inst.op == .load_function) return error.BadOpcodeVersion;
            if (bytes[4] < 15 and (inst.op == .get_slot or inst.op == .set_slot) and static_fields.nameForRef(inst.aux) != null)
                return error.BadOpcodeVersion;
            try f.insts.append(a, inst);
        }
        for (f.operands.items) |value| if (!refs.isRegister(value)) {
            p.references_lowered = true;
        };
        for (f.insts.items) |inst| inline for (sem.fields, 0..) |field, i| {
            if (refs.mask(inst.op) & (@as(u8, 1) << i) != 0 and !refs.isRegister(@field(inst, field))) p.references_lowered = true;
        };
        try p.functions.append(a, f);
    }
    if (pos != bytes.len) return error.TrailingData;
    try verify.run(a, &p);
    return p;
}

const lua = @import("root.zig");
const opt = @import("vm_optimize.zig");
test "compact typed program roundtrips and executes" {
    var chunk = try lua.parse(std.testing.allocator, "local n=0; for i=1,7 do n=n+i end; return n, 'same', -0, 1/0");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    _ = try opt.run(std.testing.allocator, &p);
    const bytes = try serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(bytes);
    var q = try deserialize(std.testing.allocator, bytes);
    defer q.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&q, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(f64, 28), values[0].number);
    try std.testing.expectEqualStrings("same", values[1].string);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(values[2].number)));
    try std.testing.expect(std.math.isInf(values[3].number));
}
test "legacy v2 bytecode remains readable" {
    // v2 empty root function with one ret0 instruction, no pools.
    const bytes = "DWVM\x02" ++ "\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x00\x00\x01" ++ "\x2c\x00\x00\x00\x00\x00\x00";
    var p = try deserialize(std.testing.allocator, bytes);
    defer p.deinit();
    try std.testing.expectEqual(ir.Opcode.ret, p.functions.items[0].?.insts.items[0].op);
}
test "compact codec rejects every truncated prefix" {
    var chunk = try lua.parse(std.testing.allocator, "return 17, 'retained'");
    defer chunk.deinit();
    var p = try ir.lowerChunk(std.testing.allocator, &chunk);
    defer p.deinit();
    const bytes = try serialize(std.testing.allocator, &p);
    defer std.testing.allocator.free(bytes);
    for (0..bytes.len) |n| {
        if (deserialize(std.testing.allocator, bytes[0..n])) |program| {
            var bad = program;
            bad.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
}

test "v9 empty function remains readable after reference encoding change" {
    const fixture = [_]u8{
        'D', 'W', 'V', 'M', 9,
        0, 0, 0, 0, 1, 0, 0, // root and section counts
        0, 2,                           0, 0, 0, // no params, packed operands, no registers/upvalues/operands
        1, @intFromEnum(ir.Opcode.ret), 0, 0,
    };
    var p = try deserializeBorrowed(std.testing.allocator, &fixture);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.functions.items.len);
    try std.testing.expect(!p.references_lowered);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const values = try vm.executeRoot(&p, &.{});
    defer exec.Vm.freeResults(values);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "v13 cannot silently decode v14 static function opcodes" {
    const a = std.testing.allocator;
    var p = ir.Program{ .allocator = a };
    defer p.deinit();
    var root = ir.Function{ .reg_count = 1 };
    try root.insts.appendSlice(a, &.{
        .{ .op = .load_function, .dst = 0, .aux = 1 },
        .{ .op = .ret, .count = 0 },
    });
    try p.functions.append(a, root);
    var child = ir.Function{};
    try child.insts.append(a, .{ .op = .ret, .count = 0 });
    try p.functions.append(a, child);
    try p.module_roots.append(a, 0);
    try p.function_modules.appendSlice(a, &.{ 0, 0 });
    const bytes = try serialize(a, &p);
    defer a.free(bytes);
    const old = try a.dupe(u8, bytes);
    defer a.free(old);
    old[4] = 13;
    try std.testing.expectError(error.BadOpcodeVersion, deserialize(a, old));
}

test "v14 cannot silently decode v15 static field refs" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "return type(table.insert)");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.run(a, &p);
    try std.testing.expect(hasStaticFieldRefs(&p));
    const bytes = try serialize(a, &p);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u8, 16), try bytecodeVersion(bytes));
    const old = try a.dupe(u8, bytes);
    defer a.free(old);
    old[4] = 14;
    try std.testing.expectError(error.BadOpcodeVersion, deserialize(a, old));
    try std.testing.expectError(error.BadOpcodeVersion, serializeVersion(a, &p, 14));
}

test "v15 cannot silently decode v16 numeric shape keys" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local t={};t[2]=7;return t");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.run(a, &p);
    try std.testing.expect(hasNumericShapeKeys(&p));
    const bytes = try serialize(a, &p);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u8, 16), try bytecodeVersion(bytes));
    const old = try a.dupe(u8, bytes);
    defer a.free(old);
    old[4] = 15;
    try std.testing.expectError(error.BadShapeKeyVersion, deserialize(a, old));
    try std.testing.expectError(error.BadShapeKeyVersion, serializeVersion(a, &p, 15));
}

test "v16 numeric shape keys roundtrip and execute" {
    const a = std.testing.allocator;
    var chunk = try lua.parse(a, "local t={};t[1]=4;t[2]=5;return t[1],t[2],#t");
    defer chunk.deinit();
    var p = try ir.lowerChunk(a, &chunk);
    defer p.deinit();
    _ = try opt.run(a, &p);
    try std.testing.expect(hasNumericShapeKeys(&p));
    const bytes = try serialize(a, &p);
    defer a.free(bytes);
    var restored = try deserialize(a, bytes);
    defer restored.deinit();
    try std.testing.expect(hasNumericShapeKeys(&restored));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var vm = try exec.Vm.init(arena.allocator());
    const out = try vm.executeRoot(&restored, &.{});
    defer exec.Vm.freeResults(out);
    try std.testing.expectEqual(@as(f64, 4), out[0].number);
    try std.testing.expectEqual(@as(f64, 5), out[1].number);
    try std.testing.expectEqual(@as(f64, 2), out[2].number);
}
