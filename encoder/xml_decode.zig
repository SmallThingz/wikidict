const std = @import("std");
const html_entities = @import("html_entities.zig");

const max_decode_passes = 8;

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try decodeInto(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

pub fn decodeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    if (std.mem.indexOfScalar(u8, input, '&') == null) {
        out.items.len = 0;
        try out.appendSlice(allocator, input);
        return;
    }

    var temp: std.ArrayList(u8) = .empty;
    defer temp.deinit(allocator);

    var current = input;
    var pass: usize = 0;
    while (true) : (pass += 1) {
        const target = if ((pass & 1) == 0) out else &temp;
        const changed = try decodePass(target, allocator, current);
        if (!changed or pass + 1 >= max_decode_passes or std.mem.indexOfScalar(u8, target.items, '&') == null) {
            if (target != out) {
                out.items.len = 0;
                try out.appendSlice(allocator, target.items);
            }
            return;
        }
        current = target.items;
    }
}

fn decodePass(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !bool {
    out.items.len = 0;
    var i: usize = 0;
    var changed = false;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        var semi = i + 1;
        while (semi < input.len and (std.ascii.isAlphanumeric(input[semi]) or input[semi] == '#')) : (semi += 1) {}
        if (semi == i + 1 or semi >= input.len or input[semi] != ';') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        const entity = input[i + 1 .. semi];
        if (entity.len == 0) {
            changed = true;
            i = semi + 1;
            continue;
        }

        if (try decodeEntity(out, allocator, entity)) {
            changed = true;
            i = semi + 1;
            continue;
        }

        try out.appendSlice(allocator, input[i .. semi + 1]);
        i = semi + 1;
    }
    return changed;
}

fn decodeEntity(out: *std.ArrayList(u8), allocator: std.mem.Allocator, entity: []const u8) !bool {
    if (std.mem.startsWith(u8, entity, "amp#")) {
        return decodeEntity(out, allocator, entity[3..]);
    }

    if (entity[0] == '#') {
        const codepoint = if (entity.len >= 2 and (entity[1] == 'x' or entity[1] == 'X'))
            std.fmt.parseInt(u21, entity[2..], 16) catch return false
        else
            std.fmt.parseInt(u21, entity[1..], 10) catch return false;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return false;
        try out.appendSlice(allocator, buf[0..len]);
        return true;
    }

    const replacement = lookupNamedEntity(entity) orelse return false;

    try out.appendSlice(allocator, replacement);
    return true;
}

fn lookupNamedEntity(entity: []const u8) ?[]const u8 {
    if (html_entities.named_entities.get(entity)) |replacement| return replacement;

    // The dump contains a small set of misspelled entity aliases that still need to round-trip cleanly.
    if (std.mem.eql(u8, entity, "emdash")) return "—";
    if (std.mem.eql(u8, entity, "endash")) return "–";
    if (std.mem.eql(u8, entity, "mdsash")) return "—";
    if (std.mem.eql(u8, entity, "dmash")) return "—";
    if (std.mem.eql(u8, entity, "squo")) return "’";
    if (std.mem.eql(u8, entity, "bnsp")) return " ";
    if (std.mem.eql(u8, entity, "nsbp")) return " ";
    if (std.mem.eql(u8, entity, "egravre")) return "è";
    return null;
}

test "decode xml entities" {
    const got = try decodeAlloc(std.testing.allocator, "a &amp; b &lt;c&gt; &#x1F4A1;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a & b <c> 💡", got);
}

test "decode xml entities recursively decodes double-escaped named and numeric references" {
    const got = try decodeAlloc(std.testing.allocator, "&amp;copy; &amp;#169; &amp;#xA9; &amp;amp;copy;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("© © © ©", got);
}

test "decode xml entities handles known malformed aliases from the dump" {
    const got = try decodeAlloc(std.testing.allocator, "&emdash; &endash; &squo; &amp#91; &nsbp;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("— – ’ [  ", got);
}

test "decode xml entities does not let literal ampersands swallow later valid entities" {
    const got = try decodeAlloc(
        std.testing.allocator,
        "|publisher=John Wiley &amp; Sons, Inc.\n|year=&amp;copy;1999\n|section=&amp;sect;1.2",
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "|publisher=John Wiley & Sons, Inc.\n|year=©1999\n|section=§1.2",
        got,
    );
}
