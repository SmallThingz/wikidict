//! Stateful, bounded two-pane terminal reader over the same runtime model as HTML/JSON.
const std = @import("std");
const builtin = @import("builtin");
const term = @import("terminal.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const expansion = @import("expansion.zig");
const L = std.os.linux;
pub const Theme = @import("args.zig").Theme;
const Focus = enum { search, matches, entry };
const Palette = struct { base: []const u8, accent: []const u8, muted: []const u8, selected: []const u8 };
fn palette(theme: Theme, color: bool) Palette {
    if (!color) return .{ .base = "\x1b[0m", .accent = "\x1b[1m", .muted = "\x1b[0m", .selected = "\x1b[7m" };
    return switch (theme) {
        .terminal => .{ .base = "\x1b[0m", .accent = "\x1b[1;36m", .muted = "\x1b[2m", .selected = "\x1b[7m" },
        .dark => .{ .base = "\x1b[0;48;5;234;38;5;252m", .accent = "\x1b[1;38;5;75m", .muted = "\x1b[38;5;245m", .selected = "\x1b[48;5;238;38;5;255m" },
        .light => .{ .base = "\x1b[0;47;30m", .accent = "\x1b[1;34m", .muted = "\x1b[38;5;240m", .selected = "\x1b[48;5;252;30m" },
    };
}
const State = struct {
    io: std.Io = undefined,
    runtime: expansion.Options = .{},
    a: std.mem.Allocator,
    db: *store.Store,
    label: []const u8,
    query: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    range: store.Range = .{ .start = 0, .end = 0 },
    selected: usize = 0,
    scroll: usize = 0,
    focus: Focus = .search,
    theme: Theme,
    color: bool,
    source: bool = false,
    details: bool = false,
    help: bool = false,
    loaded: ?usize = null,
    text: []const u8 = &.{},
    rows: []term.RenderRow = &.{},
    wrap_width: usize = 0,
    screen: term.Size = .{},

    fn deinit(self: *State) void {
        self.a.free(self.rows);
        self.a.free(self.text);
    }
    fn count(self: State) usize {
        return self.range.end - self.range.start;
    }
    fn bodyHeight(self: State) usize {
        return self.screen.rows -| 8;
    }
    fn split(self: State) usize {
        return if (self.screen.cols >= 80) @min(36, self.screen.cols / 3) else 0;
    }
    fn page(self: *State, down: bool, amount: usize) void {
        if (self.focus == .entry) self.scroll = if (down) @min(self.scroll +| amount, self.rows.len -| self.bodyHeight()) else self.scroll -| amount else self.selected = if (down) @min(self.selected +| amount, self.count() -| 1) else self.selected -| amount;
    }
    fn changed(self: *State) !void {
        self.range = try self.db.prefix(self.query[0..self.len]);
        self.selected = 0;
        self.scroll = 0;
    }
    fn insert(self: *State, text: []const u8) !void {
        if (self.len + text.len > self.query.len) return;
        std.mem.copyBackwards(u8, self.query[self.cursor + text.len .. self.len + text.len], self.query[self.cursor..self.len]);
        @memcpy(self.query[self.cursor..][0..text.len], text);
        self.len += text.len;
        self.cursor += text.len;
        try self.changed();
    }
    fn previous(self: State) usize {
        return term.previousClusterStart(self.query[0..self.len], self.cursor);
    }
    fn next(self: State) usize {
        return term.nextClusterEnd(self.query[0..self.len], self.cursor);
    }
    fn key(self: *State, event: term.Event) !bool {
        if (event.key == .quit) return false;
        if (self.help) {
            self.help = false;
            return true;
        }
        switch (event.key) {
            .quit => unreachable,
            .escape => self.focus = switch (self.focus) {
                .entry => .matches,
                .matches => .search,
                .search => .search,
            },
            .tab => self.focus = switch (self.focus) {
                .search => .matches,
                .matches => .entry,
                .entry => .search,
            },
            .enter => if (self.count() != 0) {
                self.focus = .entry;
            },
            .up, .down => {
                if (self.focus == .search and self.count() != 0) self.focus = .matches;
                self.page(event.key == .down, 1);
            },
            .page_up => self.page(false, @max(1, self.bodyHeight() -| 1)),
            .page_down => self.page(true, @max(1, self.bodyHeight() -| 1)),
            .left => {
                if (self.focus == .search) self.cursor = self.previous() else self.focus = .matches;
            },
            .right => {
                if (self.focus == .search) self.cursor = self.next() else self.focus = .entry;
            },
            .home => {
                switch (self.focus) {
                    .search => self.cursor = 0,
                    .matches => self.selected = 0,
                    .entry => self.scroll = 0,
                }
            },
            .end => {
                switch (self.focus) {
                    .search => self.cursor = self.len,
                    .matches => self.selected = self.count() -| 1,
                    .entry => self.scroll = self.rows.len -| self.bodyHeight(),
                }
            },
            .clear => {
                self.len = 0;
                self.cursor = 0;
                self.focus = .search;
                try self.changed();
            },
            .backspace => if (self.focus == .search and self.cursor != 0) {
                const p = self.previous();
                std.mem.copyForwards(u8, self.query[p..], self.query[self.cursor..self.len]);
                self.len -= self.cursor - p;
                self.cursor = p;
                try self.changed();
            },
            .delete => if (self.focus == .search and self.cursor < self.len) {
                const end = self.next();
                std.mem.copyForwards(u8, self.query[self.cursor..], self.query[end..self.len]);
                self.len -= end - self.cursor;
                try self.changed();
            },
            .text => {
                const text = event.bytes[0..event.len];
                if (event.pasted) self.focus = .search;
                if (self.focus == .search) try self.insert(text) else if (event.len == 1) switch (text[0]) {
                    'q' => return false,
                    '/' => {
                        self.focus = .search;
                        self.cursor = self.len;
                    },
                    't' => self.theme = switch (self.theme) {
                        .terminal => .dark,
                        .dark => .light,
                        .light => .terminal,
                    },
                    'd' => {
                        self.details = !self.details;
                        self.loaded = null;
                        self.scroll = 0;
                    },
                    's' => {
                        self.source = !self.source;
                        self.loaded = null;
                        self.scroll = 0;
                        self.focus = .entry;
                    },
                    '?' => self.help = true,
                    'j' => self.page(true, 1),
                    'k' => self.page(false, 1),
                    ' ' => self.page(true, @max(1, self.bodyHeight() -| 1)),
                    'b' => self.page(false, @max(1, self.bodyHeight() -| 1)),
                    else => {},
                };
            },
        }
        return true;
    }
    fn prepare(self: *State, width: usize) !void {
        const index: ?usize = if (self.count() == 0) null else self.range.start + self.selected;
        if (index != self.loaded or self.text.len == 0) {
            var formatted: std.Io.Writer.Allocating = .init(self.a);
            defer formatted.deinit();
            if (index) |i| record_block: {
                var source_record = try self.db.recordAlloc(self.a, i);
                defer source_record.deinit();
                const raw = source_record.record;
                const core = !self.source and !self.details and self.runtime.root == null;
                var resolved = if (core) try self.db.resolveCoreAlloc(self.a, raw) else self.db.resolveAlloc(self.a, raw) catch |err| switch (err) {
                    error.MissingSupplement, error.MissingSupplementRecord => {
                        try formatted.writer.writeAll("Supporting material is not installed.\n\nFull details and exact source need the matching companion blobs.\nPress s or d to return to core reading; other entries remain searchable.\n\n");
                        try formatted.writer.print("Data error: {s}\n", .{@errorName(err)});
                        break :record_block;
                    },
                    else => return err,
                };
                defer resolved.deinit();
                const record = resolved.record;
                if (self.source) {
                    const source = model.sourceAlloc(self.a, record) catch |err| switch (err) {
                        error.InvalidEncoding => try self.a.dupe(u8, "Invalid semantic payload. Use JSON output to inspect its original bytes."),
                        else => return err,
                    };
                    defer self.a.free(source);
                    try output.terminalText(&formatted.writer, source);
                } else {
                    var doc = if (core) try model.fromCoreRecord(self.a, record) else try expansion.fromRecord(self.io, self.a, record, false, self.runtime);
                    defer doc.deinit();
                    try output.entryTextWithDetails(&formatted.writer, doc.entry, self.color, self.details);
                }
            } else try formatted.writer.writeAll("No matching entries.\n\nPress / to edit the prefix; Ctrl-U clears it.\nMatching is case-sensitive UTF-8, not fuzzy search.");
            const text = try self.a.dupe(u8, formatted.written());
            for (text) |*b| if (b.* == '\t') {
                b.* = ' ';
            };
            self.a.free(self.rows);
            self.rows = &.{};
            self.a.free(self.text);
            self.text = text;
            self.loaded = index;
            self.wrap_width = 0;
            self.scroll = 0;
        }
        if (self.wrap_width != width) {
            const rows = try term.wrapStyled(self.a, self.text, width);
            self.a.free(self.rows);
            self.rows = rows;
            self.wrap_width = width;
            self.scroll = @min(self.scroll, self.rows.len -| self.bodyHeight());
        }
    }
    fn put(self: State, w: *std.Io.Writer, row: usize, col: usize, cells: usize, text: []const u8, style: []const u8) !void {
        if (cells == 0) return;
        var safe: std.Io.Writer.Allocating = .init(self.a);
        defer safe.deinit();
        try output.terminalText(&safe.writer, text);
        for (safe.written()) |*b| if (b.* == '\n' or b.* == '\t') {
            b.* = ' ';
        };
        try w.print("\x1b[{d};{d}H{s}{s}", .{ row, col, palette(self.theme, self.color).base, style });
        try w.writeAll(safe.written()[0..term.prefixBytes(safe.written(), cells)]);
    }
    fn draw(self: *State) !void {
        const sz = self.screen;
        const p = palette(self.theme, self.color);
        var frame: std.Io.Writer.Allocating = .init(self.a);
        defer frame.deinit();
        const w = &frame.writer;
        try w.writeAll("\x1b[?2026h\x1b[?25l");
        for (0..sz.rows) |i| try w.print("\x1b[{d};1H{s}\x1b[2K", .{ i + 1, p.base });
        if (sz.cols < 40 or sz.rows < 12) {
            if (sz.rows >= 1 and sz.cols >= 1) try self.put(w, 1, 1, sz.cols, "dict: resize to at least 40 x 12", p.accent);
            if (sz.rows >= 3 and sz.cols >= 1) try self.put(w, 3, 1, sz.cols, "Ctrl-C to leave safely.", p.base);
        } else {
            const split_at = self.split();
            const content_col = if (split_at == 0) 3 else split_at + 3;
            const content_width = sz.cols - content_col - 1;
            try self.prepare(content_width);
            try self.put(w, 1, 3, 9, "dict.", p.accent);
            try self.put(w, 1, 13, sz.cols -| 15, self.label, p.muted);
            var buf: [256]u8 = undefined;
            try self.put(w, 2, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "WIKBLB05  /  {d} records  /  {s} theme", .{ self.db.count(), @tagName(self.theme) }), p.muted);
            try self.put(w, 4, 3, 10, "Search /", if (self.focus == .search) p.accent else p.muted);
            // Horizontal input viewport follows the caret, at whole-codepoint boundaries.
            var start: usize = 0;
            const input_width = sz.cols - 15;
            while (term.cellWidth(self.query[start..self.cursor]) >= input_width) {
                const next_start = term.nextClusterEnd(self.query[0..self.len], start);
                if (next_start <= start) break;
                start = next_start;
            }
            try self.put(w, 4, 13, input_width, self.query[start..self.len], p.base);
            const show_matches = split_at != 0 or self.focus != .entry;
            if (show_matches) {
                const cols = if (split_at == 0) sz.cols - 4 else split_at - 4;
                try self.put(w, 6, 3, cols, try std.fmt.bufPrint(&buf, "MATCHES  {d}", .{self.count()}), if (self.focus != .entry) p.accent else p.muted);
                const offset = (self.selected / @max(1, self.bodyHeight())) * @max(1, self.bodyHeight());
                for (0..self.bodyHeight()) |i| {
                    const n = offset + i;
                    if (n >= self.count()) break;
                    const title = try self.db.titleAt(self.range.start + n);
                    try self.put(w, 7 + i, 3, cols, title, if (n == self.selected) p.selected else p.base);
                }
            }
            if (split_at != 0) for (5..sz.rows - 1) |row| try self.put(w, row, split_at, 1, "│", p.muted);
            if (split_at != 0 or self.focus == .entry) {
                try self.put(w, 6, content_col, content_width, if (self.source) "SOURCE" else "READING", if (self.focus == .entry) p.accent else p.muted);
                if (self.count() != 0 and content_width > 12) {
                    const title = try self.db.titleAt(self.range.start + self.selected);
                    try self.put(w, 6, content_col + 10, content_width - 10, title, p.muted);
                }
                for (0..self.bodyHeight()) |i| {
                    if (self.scroll + i >= self.rows.len) break;
                    const row = self.rows[self.scroll + i];
                    try w.print("\x1b[{d};{d}H{s}", .{ 7 + i, content_col, p.base });
                    try row.carry.write(w);
                    try term.writeStyled(w, row.bytes[0..term.prefixBytes(row.bytes, content_width)], p.base);
                    try w.writeAll(p.base);
                }
            }
            const first_line = if (self.rows.len == 0) @as(usize, 0) else self.scroll + 1;
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "{s}  ·  match {d}/{d}  ·  lines {d}-{d}/{d}", .{ @tagName(self.focus), if (self.count() == 0) @as(usize, 0) else self.selected + 1, self.count(), first_line, @min(self.scroll + self.bodyHeight(), self.rows.len), self.rows.len }), p.muted);
            const hints: []const u8 = switch (self.focus) {
                .search => "type to search  ↑↓ results  Enter read  Tab switch  Ctrl-U clear  Ctrl-C quit",
                .matches => "/ search  ↑↓ select  Enter read  PgUp/PgDn page  ? help  q quit",
                .entry => "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  s source  d details  ? help  q quit",
            };
            try self.put(w, sz.rows, 3, sz.cols - 4, hints, p.muted);
            if (self.help) {
                const help = [_][]const u8{ "KEYBOARD", "Type in Search; ↑/↓ moves straight into results", "Enter reads the selected word; Esc steps back", "/ returns to Search from results or reading", "Tab cycles Search → Matches → Reading", "Arrows or j/k move; PgUp/PgDn and Home/End jump", "Ctrl-U clears the query; Ctrl-C/D quits", "s toggles exact source; d toggles full details", "t cycles terminal/dark/light; q quits outside Search", "Any key closes this help" };
                for (help, 0..) |line, i| {
                    if (6 + i >= sz.rows - 1) break;
                    try w.print("\x1b[{d};1H{s}\x1b[2K", .{ 6 + i, p.base });
                    try self.put(w, 6 + i, 3, sz.cols - 4, line, if (i == 0) p.accent else p.base);
                }
            } else if (self.focus == .search) try w.print("\x1b[{d};{d}H\x1b[?25h", .{ 4, 13 + term.cellWidth(self.query[start..self.cursor]) });
        }
        try w.writeAll("\x1b[?2026l");
        try term.writeAll(frame.written());
    }
};

pub fn run(io: std.Io, a: std.mem.Allocator, db: *store.Store, label: []const u8, query: []const u8, theme: Theme, color: bool, runtime: expansion.Options, initial_details: bool) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedTerminalPlatform;
    if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) return error.TerminalRequired;
    if (!std.unicode.utf8ValidateSlice(query) or query.len > 4096) return error.InvalidQuery;
    var state: State = .{ .a = a, .io = io, .runtime = runtime, .db = db, .label = label, .theme = theme, .color = color, .details = initial_details };
    defer state.deinit();
    @memcpy(state.query[0..query.len], query);
    state.len = query.len;
    state.cursor = query.len;
    try state.changed();
    var session = try term.Session.enter();
    defer session.leave();
    var input: term.Input = .{};
    var dirty = true;
    while (!term.Session.shouldQuit()) {
        const sz = term.size();
        if (!std.meta.eql(sz, state.screen)) {
            state.screen = sz;
            dirty = true;
        }
        if (dirty) {
            try state.draw();
            dirty = false;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 100) == 0) {
            if (input.flushEscape()) |event| {
                if (!try state.key(event)) break;
                dirty = true;
            }
            continue;
        }
        if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) break;
        var bytes: [256]u8 = undefined;
        const n = L.read(0, &bytes, bytes.len);
        switch (L.errno(n)) {
            .SUCCESS => {},
            .INTR, .AGAIN => continue,
            else => return error.TerminalReadFailed,
        }
        if (n == 0) break;
        for (bytes[0..n]) |b| if (input.feed(b)) |event| {
            if (!try state.key(event)) return;
            dirty = true;
        };
    }
}

test "terminal query editing is bounded and UTF8-aware" {
    const enc = @import("blob_encoder");
    const dec = @import("blob_decoder");
    const a = std.testing.allocator;
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{.{ .title = "café", .payload = "entry" }});
    defer a.free(bytes);
    var index = try (try dec.openTrustedBlob(bytes)).buildIndexAlloc(a);
    defer index.deinit(a);
    // Test the pure state; Store's mapping and OS handles are not used by input handling.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sample", .{tmp.sub_path});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a, .symbols = .{ .io = std.testing.io, .a = a, .root = "" } };
    defer db.file.deinit();
    var state: State = .{ .a = a, .db = &db, .label = "test", .theme = .terminal, .color = false };
    defer state.deinit();
    try state.insert("café");
    try std.testing.expectEqual(@as(usize, 1), state.count());
    _ = try state.key(.{ .key = .backspace });
    try std.testing.expectEqualStrings("caf", state.query[0..state.len]);
    _ = try state.key(.{ .key = .home });
    try state.insert("x");
    try std.testing.expectEqualStrings("xcaf", state.query[0..state.len]);
    _ = try state.key(.{ .key = .delete });
    try std.testing.expectEqualStrings("xaf", state.query[0..state.len]);
    _ = try state.key(.{ .key = .clear });
    try std.testing.expectEqual(@as(usize, 0), state.len);
    term.initLocale();
    try state.insert("é👩‍💻");
    _ = try state.key(.{ .key = .backspace });
    try std.testing.expectEqualStrings("é", state.query[0..state.len]);
    _ = try state.key(.{ .key = .backspace });
    try std.testing.expectEqual(@as(usize, 0), state.len);
    try state.insert("c");
    try std.testing.expectEqual(Focus.search, state.focus);
    _ = try state.key(.{ .key = .down });
    try std.testing.expectEqual(Focus.matches, state.focus);
    _ = try state.key(.{ .key = .enter });
    try std.testing.expectEqual(Focus.entry, state.focus);
    _ = try state.key(.{ .key = .escape });
    try std.testing.expectEqual(Focus.matches, state.focus);
    _ = try state.key(.{ .key = .escape });
    try std.testing.expectEqual(Focus.search, state.focus);
    _ = try state.key(.{ .key = .clear });
    _ = try state.key(.{ .key = .tab });
    try std.testing.expectEqual(Focus.matches, state.focus);
    try std.testing.expect(!try state.key(.{ .key = .text, .bytes = .{ 'q', 0, 0, 0 }, .len = 1 }));
    try std.testing.expect(try state.key(.{ .key = .text, .bytes = .{ 'q', 0, 0, 0 }, .len = 1, .pasted = true }));
    try std.testing.expectEqual(Focus.search, state.focus);
    try std.testing.expectEqualStrings("q", state.query[0..state.len]);
}
