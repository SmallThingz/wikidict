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
const refs = bridge.refs;
pub const linked_magic = "DWSY\x02";
const linked_header_len = 5;
fn linkedSourceVersion(bytes: []const u8) ?u8 {
    if (bytes.len < linked_header_len or !std.mem.eql(u8, bytes[0..4], "DWSY")) return null;
    const source: u8 = bytes[4] +| 1;
    return switch (source) {
        2, 3, 14, 15 => source,
        else => null,
    };
}
pub fn isLinkedProgram(bytes: []const u8) bool {
    return linkedSourceVersion(bytes) != null;
}
pub fn countLinkedPoolReferences(a: A, bytes: []const u8, names: symbols.Names) !usize {
    const source_version = linkedSourceVersion(bytes) orelse return error.UnsupportedLinkedVmCodec;
    const owner = try a.dupe(u8, bytes);
    defer a.free(owner);
    @memcpy(owner[0..4], "DWVM");
    owner[4] = source_version;
    var p = try codec.deserializeBorrowed(a, owner);
    defer p.deinit();
    var refs_count: usize = 0;
    for (p.strings.items) |text| {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, at, symbols.marker)) |start| {
            at = start + 1;
            const id = try format.readPayloadLength(text, &at);
            if (id != 0) {
                _ = try names.get(id);
                refs_count += 1;
            }
        }
    }
    return refs_count;
}
fn mark(marked: []bool, index: u32) !void {
    if (index >= marked.len) return error.InvalidProgramString;
    marked[index] = true;
}
/// Static global/member names can also be observed as ordinary Lua strings.
/// They are interned, not alpha-renamed, so reflection sees the original spelling.
fn refString(value: u32) ?u32 {
    return if (refs.tag(value) == .string) refs.index(value) else null;
}
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
                .get_global, .set_global, .get_field, .set_field => try mark(marked, x.aux),
                .method_call_field, .method_call_field_vararg => try mark(marked, x.a),
                .get_index, .set_index, .table_set => {
                    if (refString(x.b)) |sid| try mark(marked, sid) else if (refs.isRegister(x.b)) {
                        if (x.b >= regs.len) return error.InvalidProgramRegister;
                        if (regs[x.b]) |sid| try mark(marked, sid);
                    }
                },
                .method_call, .method_call_vararg => {
                    if (x.aux >= f.operands.items.len) return error.InvalidProgramOperand;
                    const key = f.operands.items[x.aux];
                    if (refString(key)) |sid| try mark(marked, sid) else if (refs.isRegister(key)) {
                        if (key >= regs.len) return error.InvalidProgramRegister;
                        if (regs[key]) |sid| try mark(marked, sid);
                    }
                },
                else => {},
            }
            if (x.op == .load_string and x.dst < regs.len) {
                regs[x.dst] = x.aux;
            } else if (x.op == .move and x.dst < regs.len) {
                if (refString(x.a)) |sid| {
                    regs[x.dst] = sid;
                } else if (refs.isRegister(x.a)) {
                    if (x.a >= regs.len) return error.InvalidProgramRegister;
                    regs[x.dst] = regs[x.a];
                } else regs[x.dst] = null;
            } else switch (x.op) {
                .jump, .jump_if_false, .numeric_for_next, .generic_for_next => @memset(regs, null),
                else => {
                    if (x.dst < regs.len) regs[x.dst] = null;
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
    const source_version = linkedSourceVersion(bytes) orelse return error.UnsupportedLinkedVmCodec;
    const owner = try a.dupe(u8, bytes);
    defer a.free(owner);
    @memcpy(owner[0..4], "DWVM");
    owner[4] = source_version;

    var p = try codec.deserializeBorrowed(a, owner);
    defer p.deinit();
    const decoded = try a.alloc(?[]u8, p.strings.items.len);
    defer {
        for (decoded) |item| if (item) |text| a.free(text);
        a.free(decoded);
    }
    @memset(decoded, null);
    for (p.strings.items, 0..) |text, i| {
        if (try symbols.decodeAlloc(a, text, names)) |plain| {
            decoded[i] = plain;
            p.strings.items[i] = plain;
        }
    }
    const result = try codec.serializeVersion(a, &p, source_version);
    errdefer a.free(result);
    if (try codec.bytecodeVersion(result) != source_version) return error.UnsupportedVmCodec;
    return result;
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
    const linked_owner = try a.dupe(u8, linked);
    defer a.free(linked_owner);
    @memcpy(linked_owner[0..4], "DWVM");
    linked_owner[4] += 1;
    var linked_program = try codec.deserializeBorrowed(temp, linked_owner);
    defer linked_program.deinit();
    for (linked_program.strings.items) |text| try std.testing.expect(!std.mem.eql(u8, text, "show"));
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

test "shared symbol envelopes preserve supported owner codec versions" {
    const a = std.testing.allocator;
    for ([_]u8{ 2, 3, 14, 15 }) |version| {
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
