const std = @import("std");

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, input, '&') == null) return allocator.dupe(u8, input);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try decodeInto(&out, allocator, input);
    return out.toOwnedSlice(allocator);
}

pub fn decodeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    out.items.len = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        const semi = std.mem.indexOfScalarPos(u8, input, i + 1, ';') orelse {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        };

        const entity = input[i + 1 .. semi];
        if (entity.len == 0) {
            i = semi + 1;
            continue;
        }

        if (try decodeEntity(out, allocator, entity)) {
            i = semi + 1;
            continue;
        }

        try out.appendSlice(allocator, input[i .. semi + 1]);
        i = semi + 1;
    }
}

fn decodeEntity(out: *std.ArrayList(u8), allocator: std.mem.Allocator, entity: []const u8) !bool {
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

    const replacement = if (std.mem.eql(u8, entity, "amp"))
        "&"
    else if (std.mem.eql(u8, entity, "lt"))
        "<"
    else if (std.mem.eql(u8, entity, "gt"))
        ">"
    else if (std.mem.eql(u8, entity, "quot"))
        "\""
    else if (std.mem.eql(u8, entity, "apos"))
        "'"
    else if (std.mem.eql(u8, entity, "nbsp"))
        " "
    else if (std.mem.eql(u8, entity, "ndash"))
        "-"
    else if (std.mem.eql(u8, entity, "mdash"))
        "-"
    else if (std.mem.eql(u8, entity, "minus"))
        "-"
    else if (std.mem.eql(u8, entity, "middot"))
        "·"
    else if (std.mem.eql(u8, entity, "bull"))
        "•"
    else if (std.mem.eql(u8, entity, "hellip"))
        "..."
    else if (std.mem.eql(u8, entity, "lsquo"))
        "'"
    else if (std.mem.eql(u8, entity, "rsquo"))
        "'"
    else if (std.mem.eql(u8, entity, "ldquo"))
        "\""
    else if (std.mem.eql(u8, entity, "rdquo"))
        "\""
    else
        return false;

    try out.appendSlice(allocator, replacement);
    return true;
}

test "decode xml entities" {
    const got = try decodeAlloc(std.testing.allocator, "a &amp; b &lt;c&gt; &#x1F4A1;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a & b <c> 💡", got);
}
