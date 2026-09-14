const std = @import("std");
/// Canonical headings/codes from the exact input dump's Module:languages/canonical names.
/// Does not infer a language from template arguments, translations, or interwiki links.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    pub fn empty(a: std.mem.Allocator) Registry {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn code(self: *const Registry, heading: []const u8) ?[]const u8 {
        return self.names.get(heading);
    }
    pub fn fromLuaAlloc(a: std.mem.Allocator, source: []const u8) !Registry {
        var out = Registry.empty(a);
        errdefer out.deinit();
        const owned = out.arena.allocator();
        var p: usize = 0;
        skip(source, &p);
        if (!std.mem.startsWith(u8, source[p..], "return")) return error.InvalidLanguageRegistry;
        p += 6;
        try expect(source, &p, '{');
        while (true) {
            skip(source, &p);
            if (p < source.len and source[p] == '}') {
                p += 1;
                break;
            }
            try expect(source, &p, '[');
            const name = try string(owned, source, &p);
            try expect(source, &p, ']');
            try expect(source, &p, '=');
            const value = try string(owned, source, &p);
            if (name.len == 0 or value.len == 0 or std.mem.indexOfAny(u8, name, "\x00\n\r\t") != null) return error.InvalidLanguageRegistry;
            const slot = try out.names.getOrPut(owned, name);
            if (slot.found_existing) return error.DuplicateLanguageHeading;
            slot.value_ptr.* = value;
            skip(source, &p);
            if (p < source.len and (source[p] == ',' or source[p] == ';')) p += 1;
        }
        skip(source, &p);
        if (p != source.len) return error.InvalidLanguageRegistry;
        return out;
    }
};
fn skip(source: []const u8, p: *usize) void {
    while (p.* < source.len) {
        if (std.ascii.isWhitespace(source[p.*])) {
            p.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[p.*..], "--")) {
            p.* = std.mem.indexOfScalarPos(u8, source, p.*, '\n') orelse source.len;
            continue;
        }
        break;
    }
}
fn expect(source: []const u8, p: *usize, ch: u8) !void {
    skip(source, p);
    if (p.* == source.len or source[p.*] != ch) return error.InvalidLanguageRegistry;
    p.* += 1;
}
fn string(a: std.mem.Allocator, source: []const u8, p: *usize) ![]const u8 {
    skip(source, p);
    const begin = p.*;
    try expect(source, p, '"');
    while (p.* < source.len) {
        const ch = source[p.*];
        p.* += 1;
        if (ch == '"') return std.json.parseFromSliceLeaky([]const u8, a, source[begin..p.*], .{ .allocate = .alloc_always });
        if (ch == '\\' and p.* < source.len) p.* += 1;
    }
    return error.InvalidLanguageRegistry;
}
test "language metadata uses canonical registry rather than guessed template codes" {
    var r = try Registry.fromLuaAlloc(std.testing.allocator, "return { [\"English\"] = \"en\", [\"Translingual\"] = \"mul\" }");
    defer r.deinit();
    try std.testing.expectEqualStrings("en", r.code("English").?);
    try std.testing.expect(r.code("Noun") == null);
    try std.testing.expectError(error.DuplicateLanguageHeading, Registry.fromLuaAlloc(std.testing.allocator, "return { [\"a\"]=\"x\", [\"a\"]=\"y\" }"));
}
