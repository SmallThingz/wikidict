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
// Editing clusters can contain spacing marks with positive terminal width.
// Sum the original width segments so boundary grouping does not change cells.
fn clusterWidth(text: []const u8, start: usize, end: usize) usize {
    var pos = start;
    var result: usize = 0;
    while (pos < end) {
        const next = @min(end, clusterEnd(text, pos, false));
        result += segmentWidth(text, pos, next);
        pos = next;
    }
    return result;
}
fn segmentWidth(text: []const u8, start: usize, end: usize) usize {
    var pos = start;
    var result: usize = 0;
    var regional: usize = 0;
    var emoji_presentation = false;
    while (pos < end) {
        const n: usize = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        if (n > end - pos) break;
        const cp = std.unicode.utf8Decode(text[pos..][0..n]) catch 0xfffd;
        result = @max(result, width(cp));
        if (isRegionalIndicator(cp)) regional += 1;
        if (cp == 0xfe0f or cp == 0x20e3 or cp == 0x200d or (cp >= 0x1f3fb and cp <= 0x1f3ff)) emoji_presentation = true;
        pos += n;
    }
    if (regional >= 2 or emoji_presentation) result = @max(result, 2);
    return result;
}
pub fn prefixBytes(text: []const u8, cells: usize) usize {
    var pos: usize = 0;
    var used: usize = 0;
    while (pos < text.len) {
        if (sgrLength(text[pos..])) |n| {
            pos += n;
            continue;
        }
        const end = nextClusterEnd(text, pos);
        if (end <= pos) break;
        const w = clusterWidth(text, pos, end);
        if (used + w > cells) break;
        used += w;
        pos = end;
    }
    return pos;
}
pub fn cellWidth(text: []const u8) usize {
    var pos: usize = 0;
    var result: usize = 0;
    while (pos < text.len) {
        if (sgrLength(text[pos..])) |n| {
            pos += n;
            continue;
        }
        const end = nextClusterEnd(text, pos);
        if (end <= pos) break;
        result += clusterWidth(text, pos, end);
        pos = end;
    }
    return result;
}

fn previousCodepointStart(text: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var start = end - 1;
    while (start != 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return start;
}
fn codepointAt(text: []const u8, start: usize) u21 {
    if (start >= text.len) return 0xfffd;
    const n: usize = std.unicode.utf8ByteSequenceLength(text[start]) catch return 0xfffd;
    if (n > text.len - start) return 0xfffd;
    return std.unicode.utf8Decode(text[start..][0..n]) catch 0xfffd;
}
fn isClusterExtend(cp: u21) bool {
    if (cp == 0x200d) return false;
    return cellClusterExtend(cp) or @import("unicode_grapheme_data.zig").isExtendOrSpacingMark(cp);
}
fn cellClusterExtend(cp: u21) bool {
    if (cp == 0x200d) return false; // ZWJ joins two bases; it is handled explicitly.
    if (cp >= 0x1f3fb and cp <= 0x1f3ff) return true; // emoji skin-tone modifiers
    if ((cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xe0100 and cp <= 0xe01ef)) return true;
    if (cp >= 0xe0020 and cp <= 0xe007f) return true; // emoji tag sequences
    return width(cp) == 0;
}
fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}
pub fn previousClusterStart(text: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var start = previousCodepointStart(text, @min(end, text.len));
    while (start != 0 and isClusterExtend(codepointAt(text, start))) start = previousCodepointStart(text, start);
    if (isRegionalIndicator(codepointAt(text, start)) and start != 0) {
        var scan = start;
        var preceding: usize = 0;
        while (scan != 0) {
            const previous = previousCodepointStart(text, scan);
            if (!isRegionalIndicator(codepointAt(text, previous))) break;
            preceding += 1;
            scan = previous;
        }
        // Regional indicators form pairs from the beginning of each run. The
        // current indicator joins its predecessor only when an odd number of
        // indicators precede it.
        if (preceding & 1 == 1) start = previousCodepointStart(text, start);
    }
    while (start != 0) {
        const joiner = previousCodepointStart(text, start);
        if (codepointAt(text, joiner) != 0x200d) break;
        start = joiner;
        if (start == 0) break;
        start = previousCodepointStart(text, start);
        while (start != 0 and isClusterExtend(codepointAt(text, start))) start = previousCodepointStart(text, start);
    }
    return start;
}
pub fn nextClusterEnd(text: []const u8, start: usize) usize {
    return clusterEnd(text, start, true);
}
fn clusterEnd(text: []const u8, start: usize, editing_marks: bool) usize {
    if (start >= text.len) return text.len;
    const first_n: usize = std.unicode.utf8ByteSequenceLength(text[start]) catch return @min(start + 1, text.len);
    var end = @min(text.len, start + first_n);
    const first = codepointAt(text, start);
    if (isRegionalIndicator(first) and end < text.len and isRegionalIndicator(codepointAt(text, end))) {
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    }
    while (end < text.len) {
        const cp = codepointAt(text, end);
        if (if (editing_marks) isClusterExtend(cp) else cellClusterExtend(cp)) {
            end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
            continue;
        }
        if (cp != 0x200d) break;
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        if (end >= text.len) break;
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    }
    return @min(end, text.len);
}
// Consume an indivisible first visible cluster, including leading SGR atoms,
// when it exceeds the row budget. Never emit a styling-only overflow row.
fn overflowPrefixEnd(text: []const u8) usize {
    var pos: usize = 0;
    while (pos < text.len) {
        if (sgrLength(text[pos..])) |n| {
            pos += n;
            continue;
        }
        const end = nextClusterEnd(text, pos);
        const cells = clusterWidth(text, pos, end);
        pos = end;
        if (cells != 0) break;
    }
    return pos;
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
            if (end == 0 or (end < rest.len and cellWidth(rest[0..end]) == 0)) end = overflowPrefixEnd(rest);
            if (end < rest.len) {
                if (std.mem.lastIndexOfScalar(u8, rest[0..end], ' ')) |space| {
                    if (nextClusterEnd(rest, space) == space + 1 and
                        (space > end / 2 or moveWholeWord(rest, space, end, @max(columns, 2)))) end = space;
                }
            }
            try rows.append(a, rest[0..end]);
            rest = rest[end..];
            if (rest.len != 0 and rest[0] == ' ' and nextClusterEnd(rest, 0) == 1) rest = rest[1..];
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
// Use Linux ioctls with Linux's termios layout as one matched ABI. The pinned
// toolchain's libc tcgetattr binding shares this type, but glibc writes a larger
// structure; passing it this buffer corrupts adjacent stack storage.
fn getAttributes(fd: L.fd_t) std.posix.TermiosGetError!L.termios {
    while (true) {
        // TCGETS does not populate the extra speed slots on every architecture.
        var attributes = std.mem.zeroes(L.termios);
        switch (L.errno(L.tcgetattr(fd, &attributes))) {
            .SUCCESS => return attributes,
            .INTR => continue,
            .BADF => unreachable,
            .NOTTY => return error.NotATerminal,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
fn setAttributes(fd: L.fd_t, action: L.TCSA, attributes: L.termios) std.posix.TermiosSetError!void {
    while (true) {
        switch (L.errno(L.tcsetattr(fd, action, &attributes))) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub const Session = struct {
    original: L.termios,
    old: [3]std.posix.Sigaction,
    const signals = [_]L.SIG{ .INT, .TERM, .HUP };
    pub fn enter() !Session {
        initLocale();
        interrupted.store(false, .monotonic);
        var session: Session = .{ .original = try getAttributes(0), .old = undefined };
        var term = session.original;
        term.lflag.ECHO = false;
        term.lflag.ICANON = false;
        term.lflag.IEXTEN = false;
        term.lflag.ISIG = false;
        term.iflag.IXON = false;
        term.iflag.ICRNL = false;
        term.iflag.INLCR = false;
        term.oflag.OPOST = false;
        term.cc[@backingInt(L.V.MIN)] = 1;
        term.cc[@backingInt(L.V.TIME)] = 0;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &action, &session.old[i]);
        errdefer for (signals, 0..) |sig, i| std.posix.sigaction(sig, &session.old[i], null);
        try setAttributes(0, .NOW, term);
        errdefer setAttributes(0, .NOW, session.original) catch {};
        try writeAll("\x1b[?1049h\x1b[?25l\x1b[?2004h");
        return session;
    }
    pub fn leave(self: *Session) void {
        writeAll("\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l") catch {};
        setAttributes(0, .NOW, self.original) catch {};
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &self.old[i], null);
    }
    pub fn shouldQuit() bool {
        return interrupted.load(.monotonic);
    }
};

test "cluster cursor boundaries keep combining marks flags and ZWJ emoji intact" {
    initLocale();
    const combining = "éx";
    const first = nextClusterEnd(combining, 0);
    try std.testing.expectEqualStrings("é", combining[0..first]);
    try std.testing.expectEqual(@as(usize, 0), previousClusterStart(combining, first));

    const joined = "👩‍💻x";
    const emoji_end = nextClusterEnd(joined, 0);
    try std.testing.expectEqualStrings("👩‍💻", joined[0..emoji_end]);
    try std.testing.expectEqual(@as(usize, 0), previousClusterStart(joined, emoji_end));
    try std.testing.expectEqual(@as(usize, 2), cellWidth("👩‍💻"));
    try std.testing.expectEqualStrings("👩‍💻", joined[0..prefixBytes(joined, 2)]);

    const flag = "🇦🇺x";
    const flag_end = nextClusterEnd(flag, 0);
    try std.testing.expectEqualStrings("🇦🇺", flag[0..flag_end]);
    try std.testing.expectEqual(@as(usize, 0), previousClusterStart(flag, flag_end));
    try std.testing.expectEqual(@as(usize, 2), cellWidth("🇦🇺"));
    try std.testing.expectEqual(@as(usize, 2), cellWidth("1️⃣"));

    const odd_run = "🇦🇺🇳x";
    const third_end = std.mem.indexOfScalar(u8, odd_run, 'x').?;
    const third_start = previousClusterStart(odd_run, third_end);
    try std.testing.expectEqualStrings("🇳", odd_run[third_start..third_end]);
}

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

test "prose wraps a Malayalam definition at the word boundary when the word fits" {
    initLocale();
    const a = std.testing.allocator;
    const lead = "  1. ക്രിയയെ അകർമ്മകമാക്കി";
    const word = "സൂചിപ്പിക്കാനുപയോഗിക്കുന്ന";
    const tail = word ++ " പ്രത്യയം";
    const plain = try wrap(a, lead ++ " " ++ tail, 41);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqualStrings(lead, plain[0]);
    try std.testing.expectEqualStrings(tail, plain[1]);
    const styled = try wrapStyled(a, lead ++ " \x1b[1m" ++ word ++ "\x1b[0m പ്രത്യയം", 41);
    defer a.free(styled);
    try std.testing.expectEqual(@as(usize, 2), styled.len);
    try std.testing.expectEqualStrings(lead, styled[0].bytes);
    try std.testing.expectEqualStrings("\x1b[1m" ++ word ++ "\x1b[0m പ്രത്യയം", styled[1].bytes);
}

// Only use styled rows for output produced by the renderer, after terminalText
// neutralizes source controls. SGR is zero-width; no cursor/OSC/DCS sequence is accepted.
pub fn sgrLength(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, "\x1b[")) return null;
    var i: usize = 2;
    while (i < @min(text.len, 32)) : (i += 1) {
        if (text[i] == 'm') return i + 1;
        if (!std.ascii.isDigit(text[i]) and text[i] != ';') return null;
    }
    return null;
}
pub const TextStyle = struct {
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    underline: bool = false,
    strike: bool = false,
    link: bool = false,
    foreground: ?[3]u8 = null,
    background: ?[3]u8 = null,
    fn scan(self: *TextStyle, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (sgrLength(text[i..])) |n| {
                var parts = std.mem.splitScalar(u8, text[i + 2 .. i + n - 1], ';');
                while (parts.next()) |part| {
                    const code = std.fmt.parseInt(u8, part, 10) catch 0;
                    switch (code) {
                        0 => self.* = .{},
                        1 => self.bold = true,
                        2 => self.dim = true,
                        3 => self.italic = true,
                        4 => self.underline = true,
                        9 => self.strike = true,
                        36 => {
                            self.link = true;
                            self.foreground = null;
                        },
                        38, 48 => {
                            const mode = std.fmt.parseInt(u8, parts.next() orelse "", 10) catch 0;
                            if (mode == 2) {
                                var rgb: [3]u8 = undefined;
                                var valid = true;
                                for (&rgb) |*channel| {
                                    const value = parts.next() orelse {
                                        valid = false;
                                        break;
                                    };
                                    channel.* = std.fmt.parseInt(u8, value, 10) catch {
                                        valid = false;
                                        continue;
                                    };
                                }
                                if (valid) {
                                    if (code == 38) {
                                        self.foreground = rgb;
                                        self.link = false;
                                    } else self.background = rgb;
                                }
                            } else if (mode == 5) {
                                // Consume an unsupported indexed-color atom as a unit;
                                // its palette number must not become an emphasis code.
                                _ = parts.next();
                            }
                        },
                        22 => {
                            self.bold = false;
                            self.dim = false;
                        },
                        23 => self.italic = false,
                        24 => self.underline = false,
                        29 => self.strike = false,
                        39 => {
                            self.link = false;
                            self.foreground = null;
                        },
                        49 => self.background = null,
                        else => {},
                    }
                }
                i += n;
            } else i += 1;
        }
    }
    pub fn write(self: TextStyle, w: *std.Io.Writer) !void {
        if (self.bold) try w.writeAll("\x1b[1m");
        if (self.italic) try w.writeAll("\x1b[3m");
        if (self.dim) try w.writeAll("\x1b[2m");
        if (self.underline) try w.writeAll("\x1b[4m");
        if (self.strike) try w.writeAll("\x1b[9m");
        if (self.foreground) |rgb|
            try w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] })
        else if (self.link) try w.writeAll("\x1b[36m");
        if (self.background) |rgb| try w.print("\x1b[48;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
    }
};
pub fn styleAfter(initial: TextStyle, text: []const u8) TextStyle {
    var result = initial;
    result.scan(text);
    return result;
}

pub const PoemLine = struct { offset: usize, lead_bytes: usize = 0, lead_cells: usize = 0, left: usize = 0, continuation_left: usize = 0, right: usize = 0 };
pub const RenderRow = struct { bytes: []const u8, carry: TextStyle, left: usize = 0, right: usize = 0 };
pub fn wrapStyled(a: std.mem.Allocator, text: []const u8, columns: usize) ![]RenderRow {
    return wrapStyledProjected(a, text, columns, &.{});
}
// Ignore styling when deciding where an overlong word can break.
fn textByteCount(text: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        if (sgrLength(text[pos..])) |n| {
            pos += n;
        } else {
            pos += 1;
            count += 1;
        }
    }
    return count;
}

// If prose has already started and the next word fits on a fresh line, keep it
// intact. Only inspect at most a line's worth of the following word.
fn moveWholeWord(line: []const u8, space: usize, end: usize, columns: usize) bool {
    if (line[end] == ' ') return false;
    var pos: usize = 0;
    while (pos < space) {
        if (sgrLength(line[pos..space])) |n| {
            pos += n;
        } else if (line[pos] == ' ') {
            pos += 1;
        } else break;
    }
    if (pos == space) return false;
    const following = line[space + 1 ..];
    const fit = prefixBytes(following, columns);
    return fit == following.len or std.mem.indexOfScalar(u8, following[0 .. fit + 1], ' ') != null;
}

/// Rows continue borrowing the original text; section offsets remain valid.
pub fn wrapStyledProjected(a: std.mem.Allocator, text: []const u8, columns: usize, poem_lines: []const PoemLine) ![]RenderRow {
    return wrapStyledProjectedFromStyle(a, text, columns, poem_lines, .{});
}
/// Continue wrapping an original slice without losing its incoming SGR state.
pub fn wrapStyledProjectedFromStyle(a: std.mem.Allocator, text: []const u8, columns: usize, poem_lines: []const PoemLine, initial: TextStyle) ![]RenderRow {
    return wrapRows(a, text, columns, poem_lines, initial, false);
}

/// Table rows retain every byte, including the separator when a word wraps.
pub fn wrapStyledCell(a: std.mem.Allocator, text: []const u8, columns: usize) ![]RenderRow {
    return wrapRows(a, text, columns, &.{}, .{}, true);
}

fn wrapRows(a: std.mem.Allocator, text: []const u8, columns: usize, poem_lines: []const PoemLine, initial: TextStyle, cell: bool) ![]RenderRow {
    var rows: std.ArrayList(RenderRow) = .empty;
    errdefer rows.deinit(a);
    var style: TextStyle = initial;
    var line_offset: usize = 0;
    var metadata_index: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        while (metadata_index < poem_lines.len and poem_lines[metadata_index].offset < line_offset) metadata_index += 1;
        const poem = if (metadata_index < poem_lines.len and poem_lines[metadata_index].offset == line_offset) poem_lines[metadata_index] else null;
        var rest = line;
        var first = true;
        while (true) {
            const requested_left = if (poem) |p| if (first) p.left else p.continuation_left else 0;
            const lead_cells = if (poem) |p| if (first) p.lead_cells else 0 else 0;
            const left = @min(requested_left, columns -| (lead_cells + 2));
            const right = @min(if (poem) |p| p.right else 0, columns -| (left + lead_cells + 2));
            const available = @max(columns -| (left + right), 2);
            var end = prefixBytes(rest, available);
            if (rest.len != 0 and (end == 0 or (end < rest.len and cellWidth(rest[0..end]) == 0))) end = overflowPrefixEnd(rest);
            if (end < rest.len) if (std.mem.lastIndexOfScalar(u8, rest[0..end], ' ')) |space| {
                const lead_bytes = if (poem) |p| if (first) p.lead_bytes else 0 else 0;
                if ((poem == null or space > lead_bytes) and nextClusterEnd(rest, space) == space + 1) {
                    if (cell) {
                        if (moveWholeWord(rest, space, end, available)) end = space + 1;
                    } else if (textByteCount(rest[0..space]) > textByteCount(rest[0..end]) / 2 or
                        (poem == null and moveWholeWord(rest, space, end, available))) end = space;
                }
            };
            const slice = rest[0..end];
            try rows.append(a, .{ .bytes = slice, .carry = style, .left = left, .right = right });
            style.scan(slice);
            rest = rest[end..];
            if (!cell and poem == null and rest.len != 0 and rest[0] == ' ' and nextClusterEnd(rest, 0) == 1) rest = rest[1..];
            if (rest.len == 0) break;
            first = false;
        }
        line_offset += line.len + 1;
    }
    return rows.toOwnedSlice(a);
}
pub fn writeRenderRow(w: *std.Io.Writer, row: RenderRow, columns: usize, base: []const u8) !void {
    const left = @min(row.left, columns);
    const right = @min(row.right, columns - left);
    try w.splatByteAll(' ', left);
    try row.carry.write(w);
    try writeStyled(w, row.bytes[0..prefixBytes(row.bytes, columns - left - right)], base);
}

test "narrow translation cells keep fitting labels whole and retain literal spacing and style" {
    initLocale();
    const a = std.testing.allocator;
    const source = "  • \x1b[1m[image] indonezcə\x1b[0m  \n\nABCDEFGHIJK";
    const rows = try wrapStyledCell(a, source, 9);
    defer a.free(rows);
    const expected = [_][]const u8{ "  • ", "\x1b[1m[image] ", "indonezcə\x1b[0m", "  ", "", "ABCDEFGHI", "JK" };
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, row| {
        try std.testing.expectEqualStrings(want, row.bytes);
        try std.testing.expect(cellWidth(row.bytes) <= 9);
    }
    try std.testing.expect(rows[2].carry.bold);
    try std.testing.expect(!rows[3].carry.bold);
}

test "styled wrapping preserves generated emphasis across Unicode cell boundaries" {
    initLocale();
    const rows = try wrapStyled(std.testing.allocator, "\x1b[1;36m猫abcd\x1b[0m", 3);
    defer std.testing.allocator.free(rows);
    try std.testing.expect(rows.len >= 2);
    try std.testing.expect(rows[1].carry.bold and rows[1].carry.link);
    for (rows) |row| try std.testing.expect(cellWidth(row.bytes) <= 3);
    try std.testing.expect(sgrLength("\x1b[2J") == null);
    try std.testing.expect(sgrLength("\x1b]0;unsafe\x07") == null);

    // The old raw-byte midpoint moved breaks when zero-width styling was added.
    // Keep the exact plain rows, including the captured Arabic label/trail split.
    const cases = [_][2][]const u8{
        .{ "alpha betaTRAIL", "\x1b[1malpha \x1b[0m\x1b[1;38;2;18;52;86mbeta\x1b[0m\x1b[1mTRAIL\x1b[0m" },
        .{ "أسماء فاعلTRAIL\nNEXT ومفعولABCDEFGHIJKLMNO", "\x1b[1mأسماء \x1b[0m\x1b[1mفاعل\x1b[0m\x1b[1mTRAIL\x1b[0m\n\x1b[1mNEXT\x1b[0m \x1b[1;48;2;171;205;239mومفعول\x1b[0m\x1b[1mABCDEFGHIJKLMNO\x1b[0m" },
        .{ "prefix αβgamma tail", "\x1b[1mprefix \x1b[0m\x1b[38;2;0;3;36mαβgamma\x1b[0m tail" },
    };
    for (cases) |pair| {
        const plain = try wrapStyled(std.testing.allocator, pair[0], 10);
        defer std.testing.allocator.free(plain);
        const styled = try wrapStyled(std.testing.allocator, pair[1], 10);
        defer std.testing.allocator.free(styled);
        try std.testing.expectEqual(plain.len, styled.len);
        for (plain, styled) |expected, actual| {
            var visible: std.ArrayList(u8) = .empty;
            defer visible.deinit(std.testing.allocator);
            var pos: usize = 0;
            while (pos < actual.bytes.len) {
                if (sgrLength(actual.bytes[pos..])) |n| pos += n else {
                    try visible.append(std.testing.allocator, actual.bytes[pos]);
                    pos += 1;
                }
            }
            try std.testing.expectEqualStrings(expected.bytes, visible.items);
            try std.testing.expect(cellWidth(actual.bytes) <= 10);
        }
    }
}

/// Keep palette background/foreground after a renderer-owned reset inside a row.
pub fn writeStyled(w: *std.Io.Writer, text: []const u8, base: []const u8) !void {
    var pos: usize = 0;
    var start: usize = 0;
    while (pos < text.len) {
        if (sgrLength(text[pos..])) |n| {
            try w.writeAll(text[start..pos]);
            const sgr = text[pos .. pos + n];
            if (std.mem.eql(u8, sgr, "\x1b[0m") or std.mem.eql(u8, sgr, "\x1b[m")) try w.writeAll(base) else try w.writeAll(sgr);
            pos += n;
            start = pos;
        } else pos += 1;
    }
    try w.writeAll(text[start..]);
}

test "Poem terminal wrapping preserves spaces blank lines and bounded borrowed offsets" {
    initLocale();
    const text = "abcdef\n\n  z\n";
    const metadata = [_]PoemLine{ .{ .offset = 0, .left = 2, .continuation_left = 2 }, .{ .offset = 7 }, .{ .offset = 8 } };
    const rows = try wrapStyledProjected(std.testing.allocator, text, 5, &metadata);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("abc", rows[0].bytes);
    try std.testing.expectEqualStrings("def", rows[1].bytes);
    try std.testing.expectEqual(@as(usize, 2), rows[0].left);
    try std.testing.expectEqual(@as(usize, 2), rows[1].left);
    try std.testing.expectEqualStrings("", rows[2].bytes);
    try std.testing.expectEqualStrings("  z", rows[3].bytes);
    try std.testing.expectEqualStrings("", rows[4].bytes);
    const clipped = try wrapStyledProjected(std.testing.allocator, "猫xy", 3, &.{.{ .offset = 0, .left = 32, .continuation_left = 32 }});
    defer std.testing.allocator.free(clipped);
    try std.testing.expectEqual(@as(usize, 1), clipped[0].left);
    for (clipped) |row| try std.testing.expect(cellWidth(row.bytes) + row.left <= 3);
    var rendered: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rendered.deinit();
    try writeRenderRow(&rendered.writer, rows[1], 5, "");
    try std.testing.expectEqualStrings("  def", rendered.written());
}

test "truecolor SGR atoms preserve independent channels styles and wrap carry" {
    initLocale();
    const a = std.testing.allocator;
    const source = "\x1b[1;38;2;0;3;36;48;2;1;0;9m猫ABCDEFGHIJ\x1b[0mplain";
    const rows = try wrapStyled(a, source, 4);
    defer a.free(rows);
    try std.testing.expect(rows.len >= 3);
    const carried = rows[1].carry;
    try std.testing.expect(carried.bold);
    try std.testing.expect(!carried.italic and !carried.dim and !carried.link and !carried.strike);
    try std.testing.expectEqual([3]u8{ 0, 3, 36 }, carried.foreground.?);
    try std.testing.expectEqual([3]u8{ 1, 0, 9 }, carried.background.?);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try carried.write(&out.writer);
    try std.testing.expectEqualStrings("\x1b[1m\x1b[38;2;0;3;36m\x1b[48;2;1;0;9m", out.written());
    var style = carried;
    style.scan("\x1b[39m");
    try std.testing.expect(style.foreground == null and style.background != null and style.bold);
    style.scan("\x1b[49m");
    try std.testing.expect(style.background == null and style.bold);
    style.scan("\x1b[36m");
    try std.testing.expect(style.link and style.foreground == null);
    style.scan("\x1b[38;2;1;2;3m");
    try std.testing.expect(!style.link and style.foreground != null);
    style.scan("\x1b[0m");
    try std.testing.expect(!style.bold and !style.italic and !style.link and style.foreground == null and style.background == null);
    style.scan("\x1b[38;5;1m");
    try std.testing.expect(!style.bold and style.foreground == null);
    for (rows) |row| try std.testing.expect(cellWidth(row.bytes) <= 4);
}

test "spacing marks preserve editing boundaries and terminal cells" {
    initLocale();
    // Devanagari and Tamil SpacingMark; Bengali Extend despite category Mc.
    for ([_][]const u8{ "\u{915}\u{93e}", "\u{b95}\u{bbf}", "\u{995}\u{9be}" }) |cluster| {
        try std.testing.expectEqual(cluster.len, nextClusterEnd(cluster, 0));
        try std.testing.expectEqual(@as(usize, 0), previousClusterStart(cluster, cluster.len));
        const base_end: usize = try std.unicode.utf8ByteSequenceLength(cluster[0]);
        const expected_cells = width(codepointAt(cluster, 0)) + width(codepointAt(cluster, base_end));
        try std.testing.expectEqual(expected_cells, cellWidth(cluster));
        try std.testing.expectEqual(@as(usize, 0), prefixBytes(cluster, expected_cells - 1));
        try std.testing.expectEqual(cluster.len, prefixBytes(cluster, expected_cells));
    }
    try std.testing.expectEqual(@as(usize, 2), cellWidth("👍🏽"));
    try std.testing.expectEqual(@as(usize, 2), cellWidth("👩‍💻"));
    try std.testing.expectEqual(@as(usize, 2), cellWidth("🇦🇺"));
}

test "overwide spacing mark clusters survive plain and styled wrapping" {
    initLocale();
    const cluster = "\u{915}\u{93e}\u{93e}\u{93e}";
    try std.testing.expect(cellWidth(cluster) > 2);
    const text = cluster ++ "x";
    const plain = try wrap(std.testing.allocator, text, 2);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqualStrings(cluster, plain[0]);
    try std.testing.expectEqualStrings("x", plain[1]);
    const styled = try wrapStyled(std.testing.allocator, text, 2);
    defer std.testing.allocator.free(styled);
    try std.testing.expectEqual(@as(usize, 2), styled.len);
    try std.testing.expectEqualStrings(cluster, styled[0].bytes);
    try std.testing.expectEqualStrings("x", styled[1].bytes);
}

test "SGR overflow and soft spaces retain complete spacing mark clusters" {
    initLocale();
    const cluster = "\u{915}\u{93e}\u{93e}\u{93e}";
    const colored = "\x1b[31m" ++ cluster ++ "x\x1b[0m";
    const plain = try wrap(std.testing.allocator, colored, 2);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqualStrings("\x1b[31m" ++ cluster, plain[0]);
    const styled = try wrapStyled(std.testing.allocator, colored, 2);
    defer std.testing.allocator.free(styled);
    try std.testing.expectEqual(@as(usize, 2), styled.len);
    try std.testing.expectEqualStrings("\x1b[31m" ++ cluster, styled[0].bytes);
    try std.testing.expectEqualStrings("x\x1b[0m", styled[1].bytes);
    var expected_style: TextStyle = .{};
    expected_style.scan("\x1b[31m");
    try std.testing.expectEqualDeep(expected_style, styled[1].carry);
    const spaced = "abcdef \u{93e}x";
    for ([_]usize{ 6, 8 }) |columns| {
        const rows = try wrap(std.testing.allocator, spaced, columns);
        defer std.testing.allocator.free(rows);
        const rendered = try wrapStyled(std.testing.allocator, spaced, columns);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqual(@as(usize, 2), rows.len);
        try std.testing.expectEqual(@as(usize, 2), rendered.len);
        const first = if (columns == 6) "abcdef" else "abcdef \u{93e}";
        const second = if (columns == 6) " \u{93e}x" else "x";
        try std.testing.expectEqualStrings(first, rows[0]);
        try std.testing.expectEqualStrings(second, rows[1]);
        try std.testing.expectEqualStrings(first, rendered[0].bytes);
        try std.testing.expectEqualStrings(second, rendered[1].bytes);
    }
}


test "seeded terminal wrapping preserves existing row policy and continuation style" {
    initLocale();
    const a = std.testing.allocator;
    const source = "猫é 👩‍💻 אב cats";
    const initial = styleAfter(.{}, "\x1b[1;38;2;18;52;86m");
    const seeded = try wrapStyledProjectedFromStyle(a, source, 6, &.{}, initial);
    defer a.free(seeded);
    try std.testing.expect(seeded.len > 1);
    for (seeded) |row| {
        try std.testing.expect(row.carry.bold);
        try std.testing.expectEqualDeep(@as(?[3]u8, .{ 18, 52, 86 }), row.carry.foreground);
        try std.testing.expect(cellWidth(row.bytes) <= 6);
        try std.testing.expect(@intFromPtr(row.bytes.ptr) >= @intFromPtr(source.ptr));
        try std.testing.expect(@intFromPtr(row.bytes.ptr) + row.bytes.len <= @intFromPtr(source.ptr) + source.len);
    }
    const legacy = try wrapStyledProjected(a, source, 6, &.{});
    defer a.free(legacy);
    const default_seed = try wrapStyledProjectedFromStyle(a, source, 6, &.{}, .{});
    defer a.free(default_seed);
    try std.testing.expectEqualDeep(legacy, default_seed);
}
