//! Terminal input and display primitives. Never emits source-controlled escapes.
const std = @import("std");
const L = std.os.linux;
extern "c" fn wcwidth(c: c_int) c_int;
extern "c" fn setlocale(category: c_int, locale: ?[*:0]const u8) ?[*:0]const u8;

pub fn initLocale() void {
    // Only character classification; never alter numeric formatting.
    if (setlocale(0, "") == null or wcwidth(0x732b) != 2) _ = setlocale(0, "C.UTF-8");
}
pub fn width(cp: u21) usize {
    const cells = wcwidth(@intCast(cp));
    return if (cells < 0) 1 else @intCast(cells);
}
pub fn prefixBytes(text: []const u8, cells: usize) usize {
    var pos: usize = 0;
    var used: usize = 0;
    while (pos < text.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(text[pos]) catch return pos;
        if (n > text.len - pos) break;
        const cp = std.unicode.utf8Decode(text[pos..][0..n]) catch return pos;
        const w = width(cp);
        if (used + w > cells) break;
        used += w;
        pos += n;
    }
    return pos;
}
pub fn cellWidth(text: []const u8) usize {
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    var result: usize = 0;
    while (it.nextCodepoint()) |cp| result += width(cp);
    return result;
}
pub fn wrap(a: std.mem.Allocator, text: []const u8, columns: usize) ![][]const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try rows.append(a, "");
            continue;
        }
        var rest = line;
        while (rest.len != 0) {
            var end = prefixBytes(rest, @max(columns, 2));
            if (end == 0) end = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
            if (end < rest.len) {
                if (std.mem.lastIndexOfScalar(u8, rest[0..end], ' ')) |space| {
                    if (space > end / 2) end = space;
                }
            }
            try rows.append(a, rest[0..end]);
            rest = rest[end..];
            if (rest.len != 0 and rest[0] == ' ') rest = rest[1..];
        }
    }
    return rows.toOwnedSlice(a);
}

pub const Key = enum { text, up, down, left, right, home, end, page_up, page_down, backspace, delete, enter, tab, escape, quit, clear };
pub const Event = struct { key: Key, bytes: [4]u8 = @splat(0), len: usize = 0, pasted: bool = false };
pub const Input = struct {
    escape: [24]u8 = undefined,
    escape_len: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_need: usize = 0,
    paste: bool = false,
    pub fn flushEscape(self: *Input) ?Event {
        if (self.escape_len == 0) return null;
        self.escape_len = 0;
        return .{ .key = .escape };
    }
    pub fn feed(self: *Input, byte: u8) ?Event {
        if (self.escape_len != 0) {
            if (self.escape_len == self.escape.len) {
                self.escape_len = 0;
                return null;
            }
            self.escape[self.escape_len] = byte;
            self.escape_len += 1;
            if (self.escape_len == 2 and (byte == '[' or byte == 'O')) return null;
            if (self.escape_len > 2 and byte >= 0x30 and byte <= 0x3f) return null;
            const sequence = self.escape[0..self.escape_len];
            self.escape_len = 0;
            if (std.mem.eql(u8, sequence, "\x1b[200~")) {
                self.paste = true;
                return null;
            }
            if (std.mem.eql(u8, sequence, "\x1b[201~")) {
                self.paste = false;
                return null;
            }
            if (self.paste) return null;
            if (sequence.len == 3 and (sequence[1] == '[' or sequence[1] == 'O')) {
                return .{ .key = switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => return null,
                } };
            }
            const mappings = .{ .{ "\x1b[5~", Key.page_up }, .{ "\x1b[6~", Key.page_down }, .{ "\x1b[1~", Key.home }, .{ "\x1b[4~", Key.end }, .{ "\x1b[3~", Key.delete } };
            inline for (mappings) |mapping| if (std.mem.eql(u8, sequence, mapping[0])) return .{ .key = mapping[1] };
            return null;
        }
        if (byte == 0x1b) {
            self.utf8_len = 0;
            self.escape[0] = byte;
            self.escape_len = 1;
            return null;
        }
        if (byte < 32 or byte == 127) {
            self.utf8_len = 0;
            if (self.paste) return null;
            return .{ .key = switch (byte) {
                3, 4 => .quit,
                9 => .tab,
                10, 13 => .enter,
                8, 127 => .backspace,
                21 => .clear,
                else => return null,
            } };
        }
        if (self.utf8_len == 0) {
            self.utf8_need = std.unicode.utf8ByteSequenceLength(byte) catch return null;
        } else if (byte & 0xc0 != 0x80) {
            self.utf8_len = 0;
            return self.feed(byte);
        }
        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len != self.utf8_need) return null;
        self.utf8_len = 0;
        if (!std.unicode.utf8ValidateSlice(self.utf8[0..self.utf8_need])) return null;
        return .{ .key = .text, .bytes = self.utf8, .len = self.utf8_need, .pasted = self.paste };
    }
};

pub const Size = struct { rows: usize = 24, cols: usize = 80 };
pub fn size() Size {
    var ws: std.posix.winsize = undefined;
    if (L.errno(L.ioctl(1, L.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.row == 0 or ws.col == 0) return .{};
    return .{ .rows = @min(ws.row, 200), .cols = @min(ws.col, 512) };
}
pub fn writeAll(bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const rc = L.write(1, bytes.ptr + pos, bytes.len - pos);
        switch (L.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TerminalClosed;
                pos += rc;
            },
            .INTR => continue,
            else => return error.TerminalWriteFailed,
        }
    }
}
var interrupted = std.atomic.Value(bool).init(false);
fn onSignal(_: L.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);
}
pub const Session = struct {
    original: std.posix.termios,
    old: [3]std.posix.Sigaction,
    const signals = [_]L.SIG{ .INT, .TERM, .HUP };
    pub fn enter() !Session {
        initLocale();
        interrupted.store(false, .monotonic);
        var session: Session = .{ .original = try std.posix.tcgetattr(0), .old = undefined };
        var term = session.original;
        term.lflag.ECHO = false;
        term.lflag.ICANON = false;
        term.lflag.IEXTEN = false;
        term.lflag.ISIG = false;
        term.iflag.IXON = false;
        term.iflag.ICRNL = false;
        term.iflag.INLCR = false;
        term.oflag.OPOST = false;
        term.cc[@intFromEnum(L.V.MIN)] = 1;
        term.cc[@intFromEnum(L.V.TIME)] = 0;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &action, &session.old[i]);
        errdefer for (signals, 0..) |sig, i| std.posix.sigaction(sig, &session.old[i], null);
        try std.posix.tcsetattr(0, .NOW, term);
        errdefer std.posix.tcsetattr(0, .NOW, session.original) catch {};
        try writeAll("\x1b[?1049h\x1b[?25l\x1b[?2004h");
        return session;
    }
    pub fn leave(self: *Session) void {
        writeAll("\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(0, .NOW, self.original) catch {};
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &self.old[i], null);
    }
    pub fn shouldQuit() bool {
        return interrupted.load(.monotonic);
    }
};

test "terminal input survives split escape sequences and multibyte paste" {
    var input: Input = .{};
    try std.testing.expect(input.feed(27) == null);
    try std.testing.expect(input.feed('[') == null);
    try std.testing.expectEqual(Key.down, input.feed('B').?.key);
    try std.testing.expect(input.feed(0xc3) == null);
    const e = input.feed(0xa9).?;
    try std.testing.expectEqualStrings("é", e.bytes[0..e.len]);
    for ("\x1b[200~") |b| _ = input.feed(b);
    try std.testing.expect(input.paste);
    try std.testing.expect(input.feed('q').?.pasted);
    try std.testing.expect(input.feed(3) == null);
    for ("\x1b[201~") |b| _ = input.feed(b);
    try std.testing.expect(!input.paste);
    try std.testing.expectEqual(Key.quit, input.feed(3).?.key);
    _ = input.feed(27);
    try std.testing.expectEqual(Key.escape, input.flushEscape().?.key);
}
test "cell wrapping preserves CJK and combining marks without splitting UTF8" {
    initLocale();
    try std.testing.expectEqual(@as(usize, 5), cellWidth("猫é猫"));
    try std.testing.expectEqualStrings("猫é", "猫é猫"[0..prefixBytes("猫é猫", 3)]);
    const rows = try wrap(std.testing.allocator, "猫é猫\nwords with a tail", 5);
    defer std.testing.allocator.free(rows);
    for (rows) |row| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(row));
        try std.testing.expect(cellWidth(row) <= 5);
    }
}
