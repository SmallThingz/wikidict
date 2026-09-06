//! Versioned link adapter, not a replacement compiler. The existing compiler's
//! register/function operands stay intact; symbolic string-pool entries use the
//! same IDs as dictionary/template calls. Rebinding preserves reflective Lua.
const std = @import("std");
const enc = @import("blob_encoder");
const bridge = @import("runtime_bridge");
const symbols = enc.call_symbols;
const format = enc.blob_format;
const A = std.mem.Allocator;
const ir = bridge.ir;
const codec = bridge.codec;
pub const linked_magic = "DWSY\x02";
pub fn isLinkedProgram(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, linked_magic) or std.mem.startsWith(u8, bytes, "DWSY\x01");
}

fn mark(marked: []bool, index: u32) !void {
    if (index >= marked.len) return error.InvalidProgramString;
    marked[index] = true;
}
/// Static global/member names can also be observed as ordinary Lua strings.
/// They are interned, not alpha-renamed, so reflection sees the original spelling.
fn memberStrings(a: A, p: *const ir.Program) ![]bool {
    const marked = try a.alloc(bool, p.strings.items.len);
    errdefer a.free(marked);
    @memset(marked, false);
    for (p.functions.items) |maybe| {
        const f = maybe orelse return error.IncompleteProgram;
        if (f.reg_count > 4 * 1024 * 1024) return error.ProgramLimit;
        const regs = try a.alloc(?u32, f.reg_count);
        defer a.free(regs);
        @memset(regs, null);
        for (f.insts.items) |x| {
            switch (x.op) {
                .get_global, .set_global => try mark(marked, x.aux),
                .get_index, .set_index, .table_set => {
                    if (x.b >= regs.len) return error.InvalidProgramRegister;
                    if (regs[x.b]) |s| try mark(marked, s);
                },
                .method_call, .method_call_vararg => {
                    if (x.aux >= f.operands.items.len) return error.InvalidProgramOperand;
                    const reg = f.operands.items[x.aux];
                    if (reg >= regs.len) return error.InvalidProgramRegister;
                    if (regs[reg]) |s| try mark(marked, s);
                },
                else => {},
            }
            switch (x.op) {
                .load_string => {
                    if (x.dst >= regs.len or x.aux >= marked.len) return error.InvalidProgramRegister;
                    regs[x.dst] = x.aux;
                },
                .move => {
                    if (x.dst >= regs.len or x.a >= regs.len) return error.InvalidProgramRegister;
                    regs[x.dst] = regs[x.a];
                },
                .jump, .jump_if_false, .numeric_for_next, .generic_for_next => @memset(regs, null),
                // Conservatively lose facts across any other write. Missing a
                // candidate leaves a literal, never changes execution semantics.
                .set_global, .set_global_slot, .set_upvalue, .set_index, .table_set, .table_append, .table_append_var, .ret, .ret_var => {},
                .call, .call_vararg, .method_call, .method_call_vararg => @memset(regs, null),
                else => if (x.dst < regs.len) {
                    regs[x.dst] = null;
                },
            }
        }
    }
    return marked;
}
fn isModule(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "Module:") and s.len > 7 and std.mem.indexOfAny(u8, s, "\x00\r\n") == null and std.unicode.utf8ValidateSlice(s);
}
fn validName(s: []const u8) bool {
    return s.len != 0 and std.mem.indexOfAny(u8, s, "\x00\r\n\xfe") == null and std.unicode.utf8ValidateSlice(s);
}
pub fn collectProgram(a: A, builder: *symbols.Builder, bytes: []const u8) !void {
    var p = try codec.deserializeBorrowed(a, bytes);
    defer p.deinit();
    const members = try memberStrings(a, &p);
    defer a.free(members);
    for (p.strings.items, members) |s, member| {
        if (member and validName(s)) try builder.add(.function, s);
        if (isModule(s)) try builder.add(.module, s);
        try builder.collect(s);
    }
}
fn wholeSymbol(names: symbols.Names, value: []const u8) ?usize {
    if (isModule(value)) return names.find(.module, value);
    return names.find(.function, value) orelse names.find(.template, value);
}
pub fn linkProgramAlloc(a: A, bytes: []const u8, names: symbols.Names) ![]u8 {
    var p = try codec.deserializeBorrowed(a, bytes);
    defer p.deinit();
    const strings = try a.alloc([]u8, p.strings.items.len);
    var done: usize = 0;
    defer {
        for (strings[0..done]) |s| a.free(s);
        a.free(strings);
    }
    for (p.strings.items, 0..) |s, i| {
        strings[i] = if (wholeSymbol(names, s)) |id| blk: {
            var buf: [format.max_varuint_len + 1]u8 = undefined;
            buf[0] = symbols.marker;
            const n = format.encodePayloadLength(id, buf[1..]);
            break :blk try a.dupe(u8, buf[0 .. n.len + 1]);
        } else try symbols.encodeAlloc(a, s, names);
        done += 1;
        p.strings.items[i] = strings[i];
    }
    const source_version = try codec.bytecodeVersion(bytes);
    const result = try codec.serializeVersion(a, &p, source_version);
    errdefer a.free(result);
    if (try codec.bytecodeVersion(result) != source_version) return error.UnsupportedVmCodec;
    @memcpy(result[0..4], "DWSY");
    result[4] = source_version - 1;

    return result;
}
fn putVar(out: *std.ArrayList(u8), a: A, value: usize) !void {
    var buf: [format.max_varuint_len]u8 = undefined;
    try out.appendSlice(a, format.encodePayloadLength(value, &buf));
}
/// Only the version-checked string-pool envelope is adapted. The instruction,
/// constant and function body emitted by the owner codec is copied unchanged.
pub fn bindProgramAlloc(a: A, bytes: []const u8, names: symbols.Names) ![]u8 {
    if (!isLinkedProgram(bytes)) return error.UnsupportedLinkedVmCodec;
    const source_version = bytes[4] + 1;
    var pos: usize = linked_magic.len;
    _ = try format.readPayloadLength(bytes, &pos); // root function
    const strings = try format.readPayloadLength(bytes, &pos);
    for (0..3) |_| _ = try format.readPayloadLength(bytes, &pos); // codec counts
    if (strings > bytes.len - pos) return error.InvalidLinkedProgram;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, &.{ 'D', 'W', 'V', 'M', source_version });
    try out.appendSlice(a, bytes[linked_magic.len..pos]);
    for (0..strings) |_| {
        const len = try format.readPayloadLength(bytes, &pos);
        if (len > bytes.len - pos) return error.InvalidLinkedProgram;
        const bound = try symbols.decodeAlloc(a, bytes[pos..][0..len], names);
        defer if (bound) |s| a.free(s);
        const value = bound orelse bytes[pos..][0..len];
        try putVar(&out, a, value.len);
        try out.appendSlice(a, value);
        pos += len;
    }
    try out.appendSlice(a, bytes[pos..]);
    return out.toOwnedSlice(a);
}

pub const BundleRecord = struct { title: []const u8, program: []const u8 };
pub const BundleIterator = struct {
    bytes: []const u8,
    pos: usize = 12,
    remaining: u32,
    pub fn init(bytes: []const u8) !BundleIterator {
        if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, bridge.bundle.magic)) return error.BadBundleMagic;
        return .{ .bytes = bytes, .remaining = std.mem.readInt(u32, bytes[8..12], .little) };
    }
    pub fn next(self: *BundleIterator) !?BundleRecord {
        if (self.remaining == 0) {
            if (self.pos != self.bytes.len) return error.TrailingBundleData;
            return null;
        }
        if (self.pos > self.bytes.len or self.bytes.len - self.pos < 12) return error.TruncatedBundle;
        const title_len = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        const program_len = std.math.cast(usize, std.mem.readInt(u64, self.bytes[self.pos + 4 ..][0..8], .little)) orelse return error.ProgramTooBig;
        self.pos += 12;
        if (title_len == 0 or title_len > self.bytes.len - self.pos) return error.TruncatedBundle;
        const title = self.bytes[self.pos..][0..title_len];
        self.pos += title_len;
        if (program_len > self.bytes.len - self.pos) return error.TruncatedBundle;
        const program = self.bytes[self.pos..][0..program_len];
        self.pos += program_len;
        self.remaining -= 1;
        return .{ .title = title, .program = program };
    }
};

test "linked bytecode uses shared function IDs and preserves reflective execution" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var chunk = try bridge.lua.parse(temp, "local t={show=function(self) return 'show' end}; return t:show(), t['sh'..'ow'](t)");
    var p = try ir.lowerChunk(temp, &chunk);
    const raw = try codec.serialize(temp, &p);
    var builder: symbols.Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect("{{#invoke:Example|show}}");
    try collectProgram(temp, &builder, raw);
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: symbols.Names = .{ .keys = keys };
    const linked = try linkProgramAlloc(a, raw, names);
    defer a.free(linked);
    try std.testing.expect(std.mem.indexOf(u8, linked, "show") == null);
    const bound = try bindProgramAlloc(a, linked, names);
    defer a.free(bound);
    try std.testing.expectEqualSlices(u8, raw, bound);
    var program = try codec.deserializeBorrowed(temp, bound);
    var vm = try bridge.Vm.init(temp);
    const values = try vm.executeRoot(&program, &.{});
    defer bridge.Vm.freeResults(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    for (values) |value| try std.testing.expectEqualStrings("show", value.string);
}

test "bytecode name table and Wikitext invoke operands use the identical shared function ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chunk = try bridge.lua.parse(a, "return { shared_dispatch = function() return 9 end }");
    var program = try ir.lowerChunk(a, &chunk);
    const raw = try codec.serialize(a, &program);
    var builder: symbols.Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect("{{#invoke:Fixture|shared_dispatch}}");
    try collectProgram(a, &builder, raw);
    const names: symbols.Names = .{ .keys = try builder.sorted() };
    const id = names.find(.function, "shared_dispatch").?;
    var varint: [format.max_varuint_len]u8 = undefined;
    const operand = try std.mem.concat(a, u8, &.{ &.{symbols.marker}, format.encodePayloadLength(id, &varint) });
    const linked = try linkProgramAlloc(a, raw, names);
    const source = try symbols.encodeAlloc(a, "{{#invoke:Fixture|shared_dispatch}}", names);
    try std.testing.expect(std.mem.indexOf(u8, source, operand) != null);
    try std.testing.expect(std.mem.indexOf(u8, linked, operand) != null);
    try std.testing.expect(std.mem.indexOf(u8, linked, "shared_dispatch") == null);
    const bound = try bindProgramAlloc(a, linked, names);
    try std.testing.expectEqualSlices(u8, raw, bound);
}

test "linked VM string envelope rejects truncated and unsupported versions" {
    const names: symbols.Names = .{ .keys = &.{"fmain"} };
    for ([_][]const u8{ "DWVM\x02", "DWSY\x01", "DWSY\x01\x00\x81\x00", "DWSY\x01\x00\x01\x00\x00\x00\x09a" }) |bytes| {
        if (bindProgramAlloc(std.testing.allocator, bytes, names)) |out| {
            std.testing.allocator.free(out);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "shared symbol envelopes preserve both supported owner codec versions" {
    const a = std.testing.allocator;
    for ([_]u8{ 2, 3 }) |version| {
        var chunk = try bridge.lua.parse(a, "return 'retained'");
        defer chunk.deinit();
        var p = try ir.lowerChunk(a, &chunk);
        defer p.deinit();
        const raw = try codec.serializeVersion(a, &p, version);
        defer a.free(raw);
        const names: symbols.Names = .{ .keys = &.{"fretained"} };
        const linked = try linkProgramAlloc(a, raw, names);
        defer a.free(linked);
        try std.testing.expectEqual(version - 1, linked[4]);
        const bound = try bindProgramAlloc(a, linked, names);
        defer a.free(bound);
        try std.testing.expectEqualSlices(u8, raw, bound);
    }
}
