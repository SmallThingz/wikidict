//! Semantic call-name operands, not a general compression layer. Names occur once
//! in a shared symbol blob. Literal bytes (including non-UTF8) reconstruct exactly.
const std = @import("std");
const syntax = @import("wikitext_syntax.zig");
const format = @import("blob_format.zig");
const A = std.mem.Allocator;
pub const marker: u8 = 0xfe;
pub const filename = "symbols.wikblb";
pub const Kind = enum(u8) { template = 't', parser = 'p', module = 'm', function = 'f' };
pub const Range = struct { start: usize, end: usize, kind: Kind };
fn field(text: []const u8, start: usize, end: usize, kind: Kind) ?Range {
    const trimmed = syntax.trim(text[start..end]);
    if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, "{}[]<>|\x00\xfe") != null or !std.unicode.utf8ValidateSlice(trimmed)) return null;
    const begin = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
    return .{ .start = begin, .end = begin + trimmed.len, .kind = kind };
}
/// Only syntactic call heads are interned. Text, comments, protected literals and
/// dynamic name expressions are not mistaken for statically bound calls.
pub const Scanner = struct {
    text: []const u8,
    cursor: usize = 0,
    pending: [3]Range = undefined,
    length: usize = 0,
    next_pending: usize = 0,
    pub fn next(self: *Scanner) ?Range {
        if (self.next_pending < self.length) {
            const r = self.pending[self.next_pending];
            self.next_pending += 1;
            return r;
        }
        while (self.cursor < self.text.len) {
            const at = self.cursor;
            self.cursor += 1;
            if (self.text[at] == '<') if (syntax.protectedEnd(self.text, at)) |end| {
                self.cursor = end;
                continue;
            };
            if (!syntax.starts(self.text[at..], "{{")) continue;
            if (syntax.starts(self.text[at..], "{{{")) {
                self.cursor = at + 3;
                continue;
            }
            const pair = syntax.balanced(self.text, at) orelse continue;
            const body_start = at + 2;
            const inner = self.text[body_start..pair.inner_end];
            const delimiter = syntax.delimiter(inner, "|", 0) orelse inner.len;
            const end = body_start + delimiter;
            const head = syntax.trim(self.text[body_start..end]);
            self.cursor = body_start;
            self.length = 0;
            self.next_pending = 0;
            if (std.mem.indexOfScalar(u8, head, ':')) |colon| {
                const name = syntax.trim(head[0..colon]);
                if (name.len != 0 and (name[0] == '#' or parserName(name))) {
                    const base = @intFromPtr(head.ptr) - @intFromPtr(self.text.ptr);
                    if (field(self.text, base, base + colon, .parser)) |r| self.add(r);
                    if (std.ascii.eqlIgnoreCase(name, "#invoke")) {
                        if (field(self.text, base + colon + 1, end, .module)) |r| self.add(r);
                        if (delimiter < inner.len) {
                            const fn_start = delimiter + 1;
                            const fn_end = syntax.delimiter(inner, "|", fn_start) orelse inner.len;
                            if (field(self.text, body_start + fn_start, body_start + fn_end, .function)) |r| self.add(r);
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(name, "subst") or std.ascii.eqlIgnoreCase(name, "safesubst")) {
                    const base = @intFromPtr(head.ptr) - @intFromPtr(self.text.ptr);
                    if (field(self.text, base + colon + 1, end, .template)) |r| self.add(r);
                } else if (field(self.text, body_start, end, .template)) |r| self.add(r);
            } else if (field(self.text, body_start, end, if (parserName(head)) .parser else .template)) |r| self.add(r);
            if (self.length != 0) {
                self.next_pending = 1;
                return self.pending[0];
            }
        }
        return null;
    }
    fn add(self: *Scanner, r: Range) void {
        self.pending[self.length] = r;
        self.length += 1;
    }
};
fn parserName(name: []const u8) bool {
    for ([_][]const u8{ "PAGENAME", "FULLPAGENAME", "BASEPAGENAME", "SUBPAGENAME", "NAMESPACE", "PAGENAMEE", "FULLPAGENAMEE", "REVISIONID", "CURRENTYEAR", "CURRENTMONTH", "CURRENTDAY", "CURRENTTIME", "CURRENTTIMESTAMP", "DEFAULTSORT", "DISPLAYTITLE", "!", "=", "uc", "lc", "ucfirst", "lcfirst", "fullurl", "localurl", "canonicalurl", "urlencode", "padleft", "padright" }) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}
pub const Names = struct {
    /// Sorted typed spellings; kind byte followed by the exact original spelling.
    keys: []const []const u8,
    pub fn digest(self: Names) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.keys) |key| {
            hash.update(key);
            hash.update(&.{0});
        }
        return hash.finalResult();
    }
    pub fn get(self: Names, id: usize) error{InvalidSymbol}![]const u8 {
        if (id == 0 or id > self.keys.len) return error.InvalidSymbol;
        const key = self.keys[id - 1];
        if (!validKey(key)) return error.InvalidSymbol;
        return key[1..];
    }
    pub fn find(self: Names, kind: Kind, text: []const u8) ?usize {
        var lo: usize = 0;
        var hi = self.keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const key = self.keys[mid];
            if (key.len < 2) return null;
            const order: std.math.Order = if (key[0] < @intFromEnum(kind)) .lt else if (key[0] > @intFromEnum(kind)) .gt else std.mem.order(u8, key[1..], text);
            switch (order) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid + 1,
            }
        }
        return null;
    }
};
pub fn validKey(key: []const u8) bool {
    if (key.len < 2 or std.mem.indexOfScalar(u8, key, 0) != null or !std.unicode.utf8ValidateSlice(key)) return false;
    return switch (key[0]) {
        't', 'p', 'm', 'f' => true,
        else => false,
    };
}
pub const Builder = struct {
    a: A,
    map: std.StringHashMapUnmanaged(void) = .empty,
    pub fn deinit(self: *Builder) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.a.free(k.*);
        self.map.deinit(self.a);
    }
    pub fn add(self: *Builder, kind: Kind, name: []const u8) !void {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidSymbol;
        const key = try self.a.alloc(u8, name.len + 1);
        key[0] = @intFromEnum(kind);
        @memcpy(key[1..], name);
        errdefer self.a.free(key);
        const item = try self.map.getOrPut(self.a, key);
        if (item.found_existing) self.a.free(key);
    }
    pub fn collect(self: *Builder, text: []const u8) !void {
        var it: Scanner = .{ .text = text };
        while (it.next()) |r| try self.add(r.kind, text[r.start..r.end]);
    }
    /// The caller frees this array before destroying the builder.
    pub fn sorted(self: *Builder) ![][]const u8 {
        const keys = try self.a.alloc([]const u8, self.map.count());
        var it = self.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| {
            keys[i] = k.*;
            i += 1;
        }
        std.mem.sort([]const u8, keys, {}, struct {
            fn less(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.order(u8, l, r) == .lt;
            }
        }.less);
        return keys;
    }
};
fn literal(out: *std.ArrayList(u8), a: A, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |b, i| if (b == marker) {
        try out.appendSlice(a, bytes[start .. i + 1]);
        try out.append(a, 0);
        start = i + 1;
    };
    try out.appendSlice(a, bytes[start..]);
}
pub fn encodeAlloc(a: A, text: []const u8, names: Names) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var it: Scanner = .{ .text = text };
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(a);
    while (it.next()) |r| try ranges.append(a, r);
    std.mem.sort(Range, ranges.items, {}, struct {
        fn less(_: void, l: Range, r: Range) bool {
            return l.start < r.start;
        }
    }.less);
    var pos: usize = 0;
    for (ranges.items) |r| {
        if (r.start < pos) return error.OverlappingCallNames;
        const id = names.find(r.kind, text[r.start..r.end]) orelse return error.UnboundCallName;
        try literal(&out, a, text[pos..r.start]);
        try out.append(a, marker);
        var buf: [format.max_varuint_len]u8 = undefined;
        try out.appendSlice(a, format.encodePayloadLength(id, &buf));
        pos = r.end;
    }
    try literal(&out, a, text[pos..]);
    return out.toOwnedSlice(a);
}
pub fn kindForId(self: Names, id: usize) error{InvalidSymbol}!Kind {
    if (id == 0 or id > self.keys.len) return error.InvalidSymbol;
    const key = self.keys[id - 1];
    if (!validKey(key)) return error.InvalidSymbol;
    return switch (key[0]) {
        't' => .template,
        'p' => .parser,
        'm' => .module,
        'f' => .function,
        else => unreachable,
    };
}

const runtime_token_hex_len = @sizeOf(usize) * 2;
const runtime_token_len = 2 + runtime_token_hex_len;

fn appendRuntimeToken(out: *std.ArrayList(u8), a: A, kind: Kind, id: usize) !void {
    const digits = "0123456789abcdef";
    try out.ensureUnusedCapacity(a, runtime_token_len);
    out.appendAssumeCapacity(marker);
    out.appendAssumeCapacity(@intFromEnum(kind));
    for (0..runtime_token_hex_len) |index| {
        const shift = (runtime_token_hex_len - 1 - index) * 4;
        const nibble: u4 = @truncate(id >> @intCast(shift));
        out.appendAssumeCapacity(digits[nibble]);
    }
}

pub fn preservedId(encoded: []const u8, names: Names, expected: Kind) !?usize {
    var start: usize = 0;
    while (start < encoded.len and std.ascii.isWhitespace(encoded[start])) : (start += 1) {}
    if (encoded.len - start < runtime_token_len or encoded[start] != marker or encoded[start + 1] != @intFromEnum(expected)) return null;
    const token_end = start + runtime_token_len;
    var id: usize = 0;
    for (encoded[start + 2 .. token_end]) |byte| {
        const nibble: usize = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            else => return null,
        };
        id = (id << 4) | nibble;
    }
    if (id == 0 or try kindForId(names, id) != expected) return null;
    for (encoded[token_end..]) |byte| if (!std.ascii.isWhitespace(byte)) return null;
    return id;
}

/// Runtime binding keeps statically scanned template and #invoke operands typed
/// so the execution layer can retain symbol identity instead of
/// round-tripping them through strings. Other symbols are decoded normally.
pub fn decodeRuntimeAlloc(a: A, encoded: []const u8, names: Names) !?[]u8 {
    var pos = std.mem.indexOfScalar(u8, encoded, marker) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, encoded[0..pos]);
    while (pos < encoded.len) {
        std.debug.assert(encoded[pos] == marker);
        pos += 1;
        const id = try format.readPayloadLength(encoded, &pos);
        if (id == 0) {
            try out.append(a, marker);
        } else {
            const kind = try kindForId(names, id);
            switch (kind) {
                .template, .module, .function => try appendRuntimeToken(&out, a, kind, id),
                .parser => try out.appendSlice(a, try names.get(id)),
            }
        }
        const end = std.mem.indexOfScalarPos(u8, encoded, pos, marker) orelse encoded.len;
        try out.appendSlice(a, encoded[pos..end]);
        pos = end;
    }
    return try out.toOwnedSlice(a);
}

/// Null preserves borrowing when no encoded operand/literal escape is present.
pub fn decodeAlloc(a: A, encoded: []const u8, names: Names) !?[]u8 {
    var pos = std.mem.indexOfScalar(u8, encoded, marker) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, encoded[0..pos]);
    while (pos < encoded.len) {
        std.debug.assert(encoded[pos] == marker);
        pos += 1;
        const id = try format.readPayloadLength(encoded, &pos);
        if (id == 0) try out.append(a, marker) else try out.appendSlice(a, try names.get(id));
        const end = std.mem.indexOfScalarPos(u8, encoded, pos, marker) orelse encoded.len;
        try out.appendSlice(a, encoded[pos..end]);
        pos = end;
    }
    return try out.toOwnedSlice(a);
}
test "symbol operands replace only static template parser module and function names" {
    const a = std.testing.allocator;
    const input = "{{en-noun}} {{#invoke:links|show|{{m|en|cat}}}} prose en-noun show <nowiki>{{literal}}</nowiki><!--{{hidden}}--> \xfe\x00";
    var builder: Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect(input);
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: Names = .{ .keys = keys };
    try std.testing.expect(names.find(.template, "en-noun") != null);
    try std.testing.expect(names.find(.function, "show") != null);
    try std.testing.expect(names.find(.module, "links") != null);
    try std.testing.expect(names.find(.parser, "#invoke") != null);
    try std.testing.expect(names.find(.template, "literal") == null);
    const encoded = try encodeAlloc(a, input, names);
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "{{en-noun") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "|show") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "prose en-noun show") != null);
    const decoded = (try decodeAlloc(a, encoded, names)).?;
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}
test "dynamic call heads and nested parameter defaults remain exact" {
    const a = std.testing.allocator;
    const input = "{{{{choose}}|x}} {{#invoke:{{module}}|{{method}}|{{{arg|{{fallback}}}}}}} {{broken";
    var b: Builder = .{ .a = a };
    defer b.deinit();
    try b.collect(input);
    const keys = try b.sorted();
    defer a.free(keys);
    const names: Names = .{ .keys = keys };
    const encoded = try encodeAlloc(a, input, names);
    defer a.free(encoded);
    const plain = (try decodeAlloc(a, encoded, names)).?;
    defer a.free(plain);
    try std.testing.expectEqualStrings(input, plain);
}
test "symbol decoding rejects unknown truncated overflowing and noncanonical operands" {
    const a = std.testing.allocator;
    const names: Names = .{ .keys = &.{"tcat"} };
    for ([_][]const u8{ "\xfe", "\xfe\x02", "\xfe\x80\x00", "\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02" }) |bytes| {
        if (decodeAlloc(a, bytes, names)) |result| {
            if (result) |b| a.free(b);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
fn allocCase(a: A) !void {
    var b: Builder = .{ .a = a };
    defer b.deinit();
    try b.collect("{{a}} {{#invoke:b|c}}");
    const keys = try b.sorted();
    defer a.free(keys);
    const n: Names = .{ .keys = keys };
    const e = try encodeAlloc(a, "{{a}} {{#invoke:b|c}}", n);
    defer a.free(e);
    const d = (try decodeAlloc(a, e, n)).?;
    defer a.free(d);
}
test "symbol bindings release every failing allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocCase, .{});
}

test "dynamic invoke modules still bind nested static call heads before method names" {
    const a = std.testing.allocator;
    const source = "{{#invoke:{{choose_module}}|show|{{m|en|cat}}}}";
    var b: Builder = .{ .a = a };
    defer b.deinit();
    try b.collect(source);
    const keys = try b.sorted();
    defer a.free(keys);
    const names: Names = .{ .keys = keys };
    const encoded = try encodeAlloc(a, source, names);
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "choose_module") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "show") == null);
    const decoded = (try decodeAlloc(a, encoded, names)).?;
    defer a.free(decoded);
    try std.testing.expectEqualStrings(source, decoded);
}

test "runtime binding preserves typed invoke operands" {
    const a = std.testing.allocator;
    const input = "{{#invoke:links|show|{{m|en|cat}}}}";
    var builder: Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect(input);
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: Names = .{ .keys = keys };
    const encoded = try encodeAlloc(a, input, names);
    defer a.free(encoded);
    const runtime = (try decodeRuntimeAlloc(a, encoded, names)).?;
    defer a.free(runtime);
    try std.testing.expect(std.mem.startsWith(u8, runtime, "{{#invoke:"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, runtime, &.{marker}));
    const module_start = "{{#invoke:".len;
    const module_end = std.mem.indexOfScalarPos(u8, runtime, module_start, '|').?;
    const function_end = std.mem.indexOfScalarPos(u8, runtime, module_end + 1, '|').?;
    const module_id = (try preservedId(runtime[module_start..module_end], names, .module)).?;
    const function_id = (try preservedId(runtime[module_end + 1 .. function_end], names, .function)).?;
    try std.testing.expectEqualStrings("links", try names.get(module_id));
    try std.testing.expectEqualStrings("show", try names.get(function_id));
    try std.testing.expect((try preservedId(runtime[module_start..module_end], names, .function)) == null);
    const nested_start = std.mem.indexOf(u8, runtime, "{{") orelse unreachable;
    const second_open = std.mem.indexOfPos(u8, runtime, nested_start + 2, "{{") orelse unreachable;
    const nested_end = std.mem.indexOfScalarPos(u8, runtime, second_open + 2, '|').?;
    const template_id = (try preservedId(runtime[second_open + 2 .. nested_end], names, .template)).?;
    try std.testing.expectEqualStrings("m", try names.get(template_id));
}

test "runtime tokens safely convert whitespace-valued stored varints" {
    const a = std.testing.allocator;
    var keys: [32][]const u8 = @splat("mx");
    keys[31] = "mtarget";
    const names: Names = .{ .keys = &keys };
    const stored = [_]u8{ marker, 0x20 };
    const runtime = (try decodeRuntimeAlloc(a, &stored, names)).?;
    defer a.free(runtime);
    try std.testing.expectEqual(@as(?usize, 32), try preservedId(runtime, names, .module));
    try std.testing.expectEqual(@as(?usize, null), try preservedId(runtime, names, .function));
    try std.testing.expectEqual(@as(usize, runtime_token_len), runtime.len);
}

test "runtime template IDs preserve subst prefixes outside the token" {
    const a = std.testing.allocator;
    const input = "{{subst:foo}} {{safesubst:bar}}";
    var builder: Builder = .{ .a = a };
    defer builder.deinit();
    try builder.collect(input);
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: Names = .{ .keys = keys };
    try std.testing.expect(names.find(.template, "foo") != null);
    try std.testing.expect(names.find(.template, "bar") != null);
    try std.testing.expect(names.find(.template, "subst:foo") == null);
    const encoded = try encodeAlloc(a, input, names);
    defer a.free(encoded);
    const runtime = (try decodeRuntimeAlloc(a, encoded, names)).?;
    defer a.free(runtime);
    try std.testing.expect(std.mem.startsWith(u8, runtime, "{{subst:"));
    const first_end = std.mem.indexOf(u8, runtime, "}}") orelse unreachable;
    const colon = std.mem.indexOfScalar(u8, runtime[0..first_end], ':').?;
    try std.testing.expect((try preservedId(runtime[colon + 1 .. first_end], names, .template)) != null);
    const decoded = (try decodeAlloc(a, encoded, names)).?;
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "runtime tokens cannot alias wikitext delimiter bytes" {
    const a = std.testing.allocator;
    var keys: [124][]const u8 = @splat("mx");
    keys[57] = "mcolon";
    keys[123] = "mpipe";
    const names: Names = .{ .keys = &keys };
    inline for (.{ @as(u8, 58), @as(u8, 124) }) |stored_id| {
        const stored = [_]u8{ marker, stored_id };
        const runtime = (try decodeRuntimeAlloc(a, &stored, names)).?;
        defer a.free(runtime);
        try std.testing.expect(std.mem.indexOfScalar(u8, runtime, ':') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, runtime, '|') == null);
        try std.testing.expectEqual(@as(?usize, stored_id), try preservedId(runtime, names, .module));
    }
}
