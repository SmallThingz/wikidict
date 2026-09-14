const std = @import("std");
const language = @import("language_blob_encoding.zig");
const format = @import("blob_format.zig");
pub const kinds = @import("part_kind.zig");
pub const Kind = kinds.Kind;
pub const count = kinds.count;
pub const Bodies = [count]?[]const u8;
pub const Split = struct {
    core: []u8,
    bodies: [count][]u8,
    pub fn deinit(self: *Split, a: std.mem.Allocator) void {
        a.free(self.core);
        for (self.bodies) |bytes| a.free(bytes);
        self.* = undefined;
    }
};
/// Companion payloads contain necessary varint framing only. Section association and
/// order come from semantic placeholders in core; there are no stored offsets/counts.
pub fn splitAlloc(a: std.mem.Allocator, payload: []const u8, context: language.LanguageContext) !Split {
    var core: std.ArrayList(u8) = .empty;
    defer core.deinit(a);
    var parts: [count]std.ArrayList(u8) = @splat(.empty);
    defer for (&parts) |*part| part.deinit(a);
    var it = try language.SectionIterator.init(payload, context);
    var cursor: usize = 0;
    while (try it.next()) |section| {
        if (section.external != null) return error.AlreadySplit;
        const start = @intFromPtr(section.raw_body.ptr) - @intFromPtr(payload.ptr);
        try core.appendSlice(a, payload[cursor..start]);
        if (kinds.classify(section.title)) |kind| {
            if (section.level > 2 and section.raw_body.len != 0) {
                try core.appendSlice(a, &kinds.reference);
                var length: [format.max_varuint_len]u8 = undefined;
                try parts[kinds.index(kind)].appendSlice(a, format.encodePayloadLength(section.raw_body.len, &length));
                try parts[kinds.index(kind)].appendSlice(a, section.raw_body);
            } else try core.appendSlice(a, section.raw_body);
        } else try core.appendSlice(a, section.raw_body);
        cursor = start + section.raw_body.len;
    }
    try core.appendSlice(a, payload[cursor..]);
    var result: Split = .{ .core = try core.toOwnedSlice(a), .bodies = @splat(&.{}) };
    errdefer result.deinit(a);
    for (&parts, &result.bodies) |*part, *body| body.* = try part.toOwnedSlice(a);
    return result;
}
pub fn required(payload: []const u8, context: language.LanguageContext) ![count]bool {
    var result: [count]bool = @splat(false);
    var it = try language.SectionIterator.init(payload, context);
    while (try it.next()) |section| if (section.external) |kind| {
        result[kinds.index(kind)] = true;
    };
    return result;
}
pub fn joinAlloc(a: std.mem.Allocator, core: []const u8, context: language.LanguageContext, bodies: Bodies) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var cursors: [count]usize = @splat(0);
    var cursor: usize = 0;
    var it = try language.SectionIterator.init(core, context);
    while (try it.next()) |section| {
        const start = @intFromPtr(section.raw_body.ptr) - @intFromPtr(core.ptr);
        try out.appendSlice(a, core[cursor..start]);
        if (section.external) |kind| {
            const i = kinds.index(kind);
            const bytes = bodies[i] orelse return error.MissingSupplement;
            const len = try format.readPayloadLength(bytes, &cursors[i]);
            if (len > bytes.len - cursors[i]) return error.InvalidSupplement;
            const body = bytes[cursors[i]..][0..len];
            if (std.mem.indexOfScalar(u8, body, 0) != null) return error.InvalidSupplement;
            try out.appendSlice(a, body);
            cursors[i] += len;
            cursor = start + kinds.reference.len;
        } else {
            try out.appendSlice(a, section.raw_body);
            cursor = start + section.raw_body.len;
        }
    }
    try out.appendSlice(a, core[cursor..]);
    for (bodies, cursors) |bytes, used| if (bytes) |b| {
        if (used != b.len) return error.UnusedSupplement;
    };
    return out.toOwnedSlice(a);
}
test "separate bodies rejoin byte exactly with repeated etymologies and nested definitions" {
    const a = std.testing.allocator;
    const source = "==English==\r\n===Etymology 1===\nOrigin one.\n====Noun====\n# sense one\n=====Translations=====\nlarge list\n===Etymology 2===\nOrigin two.\n====Verb====\n# sense two\n===References===\nBooks.\n";
    const context: language.LanguageContext = .{ .heading = "English" };
    const payload = try language.encodeAlloc(a, source, context);
    defer a.free(payload);
    var split = try splitAlloc(a, payload, context);
    defer split.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, split.core, "Origin one") == null);
    try std.testing.expect(std.mem.indexOf(u8, split.core, "sense one") != null);
    var bodies: Bodies = @splat(null);
    for (split.bodies, &bodies) |b, *slot| if (b.len != 0) {
        slot.* = b;
    };
    const joined = try joinAlloc(a, split.core, context, bodies);
    defer a.free(joined);
    try std.testing.expectEqualSlices(u8, payload, joined);
    bodies[0] = null;
    try std.testing.expectError(error.MissingSupplement, joinAlloc(a, split.core, context, bodies));
}

test "supplement framing rejects truncation noncanonical lengths missing and extra chunks" {
    const a = std.testing.allocator;
    const context: language.LanguageContext = .{ .heading = "English" };
    const payload = try language.encodeAlloc(a, "==English==\n===Etymology===\ntext\n===Noun===\n# kept\n", context);
    defer a.free(payload);
    var split = try splitAlloc(a, payload, context);
    defer split.deinit(a);
    var bodies: Bodies = @splat(null);
    bodies[0] = "\x80\x00";
    try std.testing.expectError(error.InvalidBlob, joinAlloc(a, split.core, context, bodies));
    bodies[0] = "\x08a";
    try std.testing.expectError(error.InvalidSupplement, joinAlloc(a, split.core, context, bodies));
    bodies[0] = "\x01\x00";
    try std.testing.expectError(error.InvalidSupplement, joinAlloc(a, split.core, context, bodies));
    bodies[0] = try std.mem.concat(a, u8, &.{ split.bodies[0], "\x00" });
    defer a.free(bodies[0].?);
    try std.testing.expectError(error.UnusedSupplement, joinAlloc(a, split.core, context, bodies));
    try std.testing.expectError(error.InvalidEncoding, language.decodeAlloc(a, split.core, context));
}
fn allocationCase(a: std.mem.Allocator) !void {
    const context: language.LanguageContext = .{ .heading = "English" };
    const encoded = try language.encodeAlloc(a, "==English==\n===Etymology===\norigin\n===Noun===\n# definition\n", context);
    defer a.free(encoded);
    var split = try splitAlloc(a, encoded, context);
    defer split.deinit(a);
    var bodies: Bodies = @splat(null);
    bodies[0] = split.bodies[0];
    const joined = try joinAlloc(a, split.core, context, bodies);
    defer a.free(joined);
    try std.testing.expectEqualSlices(u8, encoded, joined);
}
test "split and rejoin free all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
