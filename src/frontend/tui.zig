//! Stateful, bounded two-pane terminal reader over compiled dictionary presentation data.
const std = @import("std");
const builtin = @import("builtin");
const term = @import("terminal.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const enc = @import("blob_encoder");
const output = @import("output.zig");
const L = std.os.linux;
pub const Theme = @import("args.zig").Theme;
const ReadingState = @import("reading_state.zig").State;
const Search = @import("search.zig").Task;
const MediaJob = @import("media_job.zig");
const Page = enum { saved, history, search, learn, settings, library };
const Focus = enum { search, matches, entry };
const Palette = struct { base: []const u8, accent: []const u8, muted: []const u8, selected: []const u8 };
fn palette(theme: Theme, color: bool) Palette {
    if (!color) return .{ .base = "\x1b[0m", .accent = "\x1b[1m", .muted = "\x1b[0m", .selected = "\x1b[7m" };
    return switch (theme) {
        .terminal => .{ .base = "\x1b[0m", .accent = "\x1b[1;36m", .muted = "\x1b[2m", .selected = "\x1b[7m" },
        .dark => .{ .base = "\x1b[0;48;2;23;37;30;38;2;228;231;218m", .accent = "\x1b[1;38;2;233;184;138m", .muted = "\x1b[38;2;167;180;166m", .selected = "\x1b[48;2;76;56;39;38;2;233;184;138m" },
        .light => .{ .base = "\x1b[0;47;30m", .accent = "\x1b[1;34m", .muted = "\x1b[38;5;240m", .selected = "\x1b[48;5;252;30m" },
    };
}
const State = struct {
    io: std.Io = undefined,
    a: std.mem.Allocator,
    db: *store.Store,
    label: []const u8,
    label_owned: bool = false,
    library_names: std.ArrayList([]const u8) = .empty,
    library_selected: usize = 0,
    query: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    range: store.Range = .{ .start = 0, .end = 0 },
    search: Search = .{},
    folded_search: bool = false,
    case_sensitive: bool = true,
    selected: usize = 0,
    scroll: usize = 0,
    focus: Focus = .search,
    theme: Theme,
    color: bool,
    details: bool = false,
    help: bool = false,
    notice: []const u8 = "",
    media_index: usize = 0,
    media_job: MediaJob.Job = .{},
    reading: ?*ReadingState = null,
    nav: Page = .search,
    filtered: std.ArrayList(usize) = .empty,
    setting: usize = 0,
    confirm_clear_history: bool = false,
    revealed: bool = false,
    section: usize = 0,
    section_count: usize = 0,
    section_indices: std.ArrayList(usize) = .empty,
    section_offset: usize = 0,
    jump_section: bool = false,
    fold_word: ?usize = null,
    game: enum { cards, quiz, scramble } = .cards,
    choices: [4]usize = @splat(0),
    choice_count: usize = 0,
    answer_query: [4096]u8 = undefined,
    answer_len: usize = 0,
    correct_choice: usize = 0,
    answered: bool = false,
    expanded: std.ArrayList(usize) = .empty,
    round: usize = 0,
    correct: usize = 0,
    random: std.Random.DefaultPrng = .init(31337),
    loaded: ?usize = null,
    text: []const u8 = &.{},
    rows: []term.RenderRow = &.{},
    wrap_width: usize = 0,
    screen: term.Size = .{},

    fn deinit(self: *State) void {
        self.media_job.deinit(self.io);
        if (self.label_owned) self.a.free(self.label);
        for (self.library_names.items) |name| self.a.free(name);
        self.library_names.deinit(self.a);
        self.search.deinit(self.a);
        self.filtered.deinit(self.a);
        self.expanded.deinit(self.a);
        self.section_indices.deinit(self.a);
        self.a.free(self.rows);
        self.a.free(self.text);
    }
    fn count(self: State) usize {
        if (self.nav == .search and self.folded_search) return self.search.matches.items.len;
        return if (self.collection()) self.filtered.items.len else self.range.end - self.range.start;
    }
    fn recordIndex(self: State, n: usize) usize {
        if (self.nav == .search and self.folded_search) return self.search.matches.items[n].index;
        return if (self.collection()) self.filtered.items[n] else self.range.start + n;
    }
    fn collection(self: State) bool {
        return self.nav == .saved or self.nav == .history or (self.nav == .learn and self.reading != null and self.reading.?.data.study_pool != .all);
    }
    fn navigate(self: *State, page_name: Page) !void {
        if (page_name == .library) try self.loadLibrary();
        self.notice = "";
        self.confirm_clear_history = false;
        self.nav = page_name;
        self.selected = 0;
        self.scroll = 0;
        self.loaded = null;
        self.focus = if (page_name == .search) .search else .matches;
        self.filtered.clearRetainingCapacity();
        if (self.reading) |r| {
            const words = if (page_name == .saved or (page_name == .learn and r.data.study_pool == .saved)) r.data.saved else if (page_name == .history or (page_name == .learn and r.data.study_pool == .history)) r.data.history else &.{};
            for (words) |word| if (try self.db.find(word)) |index| try self.filtered.append(self.a, index);
        }
        if (page_name == .learn) {
            self.range = .{ .start = 0, .end = self.db.count() };
            self.focus = .entry;
            self.round = 0;
            self.correct = 0;
            self.nextCard();
        }
        if (page_name == .search) try self.changed();
    }
    fn loadLibrary(self: *State) !void {
        const path = try std.fs.path.join(self.a, &.{ self.db.root, store.catalog.manifest_filename });
        defer self.a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(16 * 1024 * 1024));
        defer self.a.free(bytes);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| self.a.free(name);
            names.deinit(self.a);
        }
        var iterator = try store.catalog.Iterator.init(bytes);
        while (try iterator.next()) |entry| {
            const name = try self.a.dupe(u8, entry.heading);
            errdefer self.a.free(name);
            try names.append(self.a, name);
        }
        for (self.library_names.items) |name| self.a.free(name);
        self.library_names.deinit(self.a);
        self.library_names = names;
        self.library_selected = @min(self.library_selected, names.items.len -| 1);
    }
    fn switchDictionary(self: *State, heading: []const u8) !void {
        var next_db = try store.Store.open(self.io, self.a, self.db.root, .language, heading);
        errdefer next_db.deinit();
        const label = try std.fmt.allocPrint(self.a, "{s} / language", .{heading});
        errdefer self.a.free(label);
        var next_reading = ReadingState.init(self.a);
        errdefer next_reading.deinit();
        try next_reading.load(self.io, next_db.root, label);
        const reading = self.reading orelse return error.InvalidArgument;
        try reading.save(self.io);
        self.media_job.cancel(self.io);
        self.db.deinit();
        self.db.* = next_db;
        reading.deinit();
        reading.* = next_reading;
        if (self.label_owned) self.a.free(self.label);
        self.label = label;
        self.label_owned = true;
        self.theme = @enumFromInt(@intFromEnum(reading.data.theme));
        self.details = reading.data.details;
        self.nav = .search;
        self.focus = .search;
        self.len = 0;
        self.cursor = 0;
        self.selected = 0;
        self.scroll = 0;
        self.folded_search = false;
        self.range = .{ .start = 0, .end = self.db.count() };
        self.loaded = null;
        self.fold_word = null;
        self.expanded.clearRetainingCapacity();
        self.a.free(self.text);
        self.text = &.{};
        self.a.free(self.rows);
        self.rows = &.{};
        self.notice = "Dictionary opened.";
    }
    fn nextCard(self: *State) void {
        if (self.roundComplete()) return;
        if (self.count() != 0) self.selected = self.random.random().uintLessThan(usize, self.count());
        self.revealed = false;
        self.answered = false;
        self.loaded = null;
        self.scroll = 0;
        self.answer_len = 0;
        self.choice_count = @min(self.choices.len, self.count());
        if (self.count() != 0) {
            for (self.choices[0..self.choice_count], 0..) |*choice, i| choice.* = (self.selected + i) % self.count();
            self.correct_choice = self.random.random().uintLessThan(usize, self.choice_count);
            std.mem.swap(usize, &self.choices[0], &self.choices[self.correct_choice]);
        }
    }
    fn roundComplete(self: State) bool {
        return if (self.reading) |r| self.round >= r.data.quiz_length else false;
    }
    fn answer(self: *State, correct: bool) !void {
        if (self.answered or self.roundComplete() or self.count() == 0) return;
        self.round += 1;
        if (correct) self.correct += 1;
        if (self.reading) |r| {
            if (correct) r.data.right +|= 1 else r.data.wrong +|= 1;
            try r.save(self.io);
        }
        self.answered = true;
        self.revealed = true;
        self.loaded = null;
    }
    fn mediaAction(self: *State, speech: bool) !void {
        const kind: MediaJob.Kind = if (speech) .speech else .media;
        if (self.media_job.kind() == kind) {
            self.media_job.cancel(self.io);
            self.notice = if (speech) "Speech stopped." else "Media request canceled.";
            return;
        }
        if (self.count() == 0) return;
        var record = try self.db.recordAlloc(self.a, self.recordIndex(self.selected));
        defer record.deinit();
        var doc = try model.fromRecord(self.a, record.record);
        defer doc.deinit();
        if (speech) {
            try self.media_job.start(self.io, self.a, .{ .speech = .{ .word = doc.entry.title, .language = doc.entry.language_code } });
            self.notice = "Speaking offline; v stops.";
            return;
        }
        const preferences = if (self.reading) |r| r.data else return;
        if (doc.entry.media.len == 0) {
            self.notice = "This word has no media.";
            return;
        }
        const item = doc.entry.media[self.media_index % doc.entry.media.len];
        self.media_index += 1;
        if (!(if (item.kind == .image) preferences.allow_images else preferences.allow_audio)) {
            self.notice = "Enable online images/audio in Settings first.";
            return;
        }
        try self.media_job.start(self.io, self.a, .{ .media = .{ .root = self.db.root, .file = item.file, .image = item.kind == .image, .cache_mb = preferences.media_cache_mb } });
        self.notice = "Opening media; m cancels.";
    }
    fn mediaPoll(self: *State) bool {
        const result = self.media_job.poll(self.io) orelse return false;
        self.notice = if (result.err) |err| switch (err) {
            error.Canceled => "Media request canceled.",
            error.FileNotFound => if (result.kind == .speech) "Install espeak-ng or espeak with an offline voice." else "Media needs curl and a desktop viewer (xdg-open).",
            error.UnsupportedMedia => "This media format cannot be opened here; m tries the next item.",
            error.MediaNotFound => "This file is unavailable; m tries the next item.",
            else => if (result.kind == .speech) "Speech failed; check the installed offline voice." else "Media failed; check your connection or try the next item with m.",
        } else if (result.kind == .speech) "Speech finished." else "Opened in desktop player; m opens the next item.";
        return true;
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
        self.nav = .search;
        self.notice = "";
        self.filtered.clearRetainingCapacity();
        self.folded_search = !self.case_sensitive and std.mem.trim(u8, self.query[0..self.len], " \t\r\n").len != 0;
        if (self.folded_search) {
            try self.search.begin(self.a, self.query[0..self.len]);
        } else self.range = try self.db.prefix(if (self.case_sensitive) self.query[0..self.len] else "");
        self.selected = 0;
        self.scroll = 0;
    }
    fn searchPending(self: State) bool {
        return self.nav == .search and self.folded_search and !self.search.complete;
    }
    fn searchStep(self: *State) !bool {
        if (!self.searchPending()) return false;
        const before = self.count();
        const selected: ?usize = if (before != 0) self.recordIndex(self.selected) else null;
        try self.search.step(self.a, self.db, 4096);
        if (self.search.complete) if (selected) |index| {
            for (self.search.matches.items, 0..) |match, i| if (match.index == index) {
                self.selected = i;
                break;
            };
        };
        return self.search.complete or (before == 0 and self.count() != 0) or self.search.cursor % 65536 == 0;
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
        if (self.confirm_clear_history) {
            self.confirm_clear_history = false;
            if (event.key == .enter) {
                const r = self.reading.?;
                self.a.free(r.data.history);
                r.data.history = &.{};
                try r.save(self.io);
                self.notice = "History cleared. Saved words are kept.";
            } else self.notice = "History kept.";
            return true;
        }
        const answering = self.nav == .learn and self.game == .scramble and !self.answered and !self.roundComplete();
        if (event.key == .text and !event.pasted and !answering and self.focus != .search and event.len == 1 and event.bytes[0] == 'L') {
            self.navigate(.library) catch {
                self.notice = "Could not read installed dictionaries. Check the dataset folder.";
            };
            return true;
        }
        if (event.key == .text and !event.pasted and !answering and self.focus != .search and event.len == 1 and event.bytes[0] >= '1' and event.bytes[0] <= '5') {
            try self.navigate(@enumFromInt(event.bytes[0] - '1'));
            return true;
        }
        if (self.nav == .library) {
            switch (event.key) {
                .up => self.library_selected -|= 1,
                .down => self.library_selected = @min(self.library_names.items.len -| 1, self.library_selected + 1),
                .page_up => self.library_selected -|= @max(1, self.bodyHeight()),
                .page_down => self.library_selected = @min(self.library_names.items.len -| 1, self.library_selected +| self.bodyHeight()),
                .enter => if (self.library_names.items.len != 0) {
                    self.switchDictionary(self.library_names.items[self.library_selected]) catch {
                        self.notice = "Could not open this dictionary. Your current word is kept.";
                    };
                },
                .escape => try self.navigate(.search),
                .text => if (event.len == 1 and event.bytes[0] == 'q') return false,
                else => {},
            }
            return true;
        }
        if (self.nav == .settings and self.reading != null) {
            const r = self.reading.?;
            switch (event.key) {
                .up => self.setting -|= 1,
                .down => self.setting = @min(13, self.setting + 1),
                .left, .right, .enter => {
                    const increase = event.key != .left;
                    switch (self.setting) {
                        0 => {
                            self.theme = switch (self.theme) {
                                .terminal => .dark,
                                .dark => .light,
                                .light => .terminal,
                            };
                            r.data.theme = @enumFromInt(@intFromEnum(self.theme));
                        },
                        1 => {
                            self.details = !self.details;
                            r.data.details = self.details;
                            self.loaded = null;
                        },
                        2 => r.data.history_limit = if (increase) @min(100_000, @max(1, r.data.history_limit * 2)) else r.data.history_limit / 2,
                        3 => r.data.quiz_length = if (increase) @min(50, r.data.quiz_length + 1) else @max(3, r.data.quiz_length -| 1),
                        4 => r.data.collapse_pronunciation = !r.data.collapse_pronunciation,
                        5 => r.data.collapse_etymology = !r.data.collapse_etymology,
                        6 => r.data.collapse_other = !r.data.collapse_other,
                        7 => r.data.collapse_notes = !r.data.collapse_notes,
                        8 => {
                            if (event.key == .enter) {
                                self.confirm_clear_history = true;
                                self.notice = "Clear history? Enter confirms; any other key cancels.";
                            }
                        },
                        9 => r.data.allow_images = !r.data.allow_images,
                        10 => r.data.allow_audio = !r.data.allow_audio,
                        11 => r.data.media_cache_mb = if (increase) @min(4096, @max(1, r.data.media_cache_mb * 2)) else r.data.media_cache_mb / 2,
                        12 => self.navigate(.library) catch {
                            self.notice = "Could not read installed dictionaries. Check the dataset folder.";
                        },
                        13 => r.data.study_pool = switch (r.data.study_pool) {
                            .all => if (increase) .history else .saved,
                            .history => if (increase) .saved else .all,
                            .saved => if (increase) .all else .history,
                        },
                        else => {},
                    }
                    try r.save(self.io);
                },
                .escape => try self.navigate(.search),
                .text => if (event.len == 1 and event.bytes[0] == 'q') return false,
                else => {},
            }
            return true;
        }
        if (self.nav == .learn) {
            if (event.key == .escape) {
                try self.navigate(.search);
                return true;
            }
            if (event.key == .tab) {
                self.game = switch (self.game) {
                    .cards => .quiz,
                    .quiz => .scramble,
                    .scramble => .cards,
                };
                self.round = 0;
                self.correct = 0;
                self.nextCard();
                return true;
            }
            if (self.roundComplete()) return !(event.key == .text and event.len == 1 and event.bytes[0] == 'q');
            if (self.game == .scramble and !self.answered) {
                if (event.key == .text) {
                    if (self.answer_len + event.len <= self.answer_query.len) {
                        @memcpy(self.answer_query[self.answer_len..][0..event.len], event.bytes[0..event.len]);
                        self.answer_len += event.len;
                        self.loaded = null;
                    }
                    return true;
                }
                if (event.key == .backspace) {
                    self.answer_len = term.previousClusterStart(self.answer_query[0..self.answer_len], self.answer_len);
                    self.loaded = null;
                    return true;
                }
                if (event.key == .enter and self.count() != 0) {
                    const lower = @import("unicode_lower.zig");
                    const typed = try lower.lowerAlloc(self.a, std.mem.trim(u8, self.answer_query[0..self.answer_len], " \t\r\n"));
                    defer self.a.free(typed);
                    const expected = try lower.lowerAlloc(self.a, try self.db.titleAt(self.recordIndex(self.selected)));
                    defer self.a.free(expected);
                    try self.answer(std.mem.eql(u8, typed, expected));
                    return true;
                }
            }
            if (event.key == .text and event.len == 1) {
                const c = event.bytes[0];
                if (c == ' ' and self.answered) {
                    self.nextCard();
                    return true;
                }
                if (self.game == .quiz and !self.answered and c >= '6' and c < '6' + self.choice_count) {
                    try self.answer(self.choices[c - '6'] == self.selected);
                    return true;
                }
                if (self.game == .cards) {
                    if (c == ' ') {
                        self.revealed = !self.revealed;
                        self.loaded = null;
                        return true;
                    }
                    if ((c == 'y' or c == 'n') and self.revealed) {
                        try self.answer(c == 'y');
                        self.nextCard();
                        return true;
                    }
                }
            }
        }
        switch (event.key) {
            .quit => unreachable,
            .escape => switch (self.focus) {
                .entry => self.focus = .matches,
                .matches, .search => try self.navigate(.search),
            },
            .tab => self.focus = switch (self.focus) {
                .search => .matches,
                .matches => .entry,
                .entry => .search,
            },
            .enter => if (self.count() != 0) {
                self.focus = .entry;
                if (self.reading) |r| {
                    try r.remember(try self.db.titleAt(self.recordIndex(self.selected)));
                    try r.save(self.io);
                }
            },
            .up, .down => {
                if (self.focus == .search and self.count() != 0) self.focus = .matches else self.page(event.key == .down, 1);
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
            .delete => {
                if (self.focus == .search and self.cursor < self.len) {
                    const end = self.next();
                    std.mem.copyForwards(u8, self.query[self.cursor..], self.query[end..self.len]);
                    self.len -= end - self.cursor;
                    try self.changed();
                } else if (self.nav == .history and self.count() != 0) {
                    if (self.reading) |r| {
                        try r.forget(try self.db.titleAt(self.recordIndex(self.selected)));
                        try r.save(self.io);
                        const selected = self.selected;
                        try self.navigate(.history);
                        self.selected = @min(selected, self.count() -| 1);
                        self.notice = "Removed from history.";
                    }
                }
            },
            .text => {
                const text = event.bytes[0..event.len];
                if (event.pasted) self.focus = .search;
                if (self.focus == .search) try self.insert(text) else if (event.len == 1) switch (text[0]) {
                    'q' => return false,
                    '/' => {
                        try self.navigate(.search);
                        self.focus = .search;
                        self.cursor = self.len;
                    },
                    'v' => self.mediaAction(true) catch {
                        self.notice = "Install an offline espeak-ng voice for this language.";
                    },
                    'm' => self.mediaAction(false) catch {
                        self.notice = "Media unavailable; check Settings, network and desktop viewer.";
                    },
                    '[' => {
                        self.section -|= 1;
                        self.loaded = null;
                        self.jump_section = true;
                    },
                    ']' => {
                        self.section = @min(self.section_count -| 1, self.section + 1);
                        self.loaded = null;
                        self.jump_section = true;
                    },
                    'e' => {
                        if (self.section_indices.items.len != 0) {
                            const selected = self.section_indices.items[self.section];
                            if (std.mem.indexOfScalar(usize, self.expanded.items, selected)) |i| _ = self.expanded.orderedRemove(i) else try self.expanded.append(self.a, selected);
                            self.loaded = null;
                            self.jump_section = true;
                        }
                    },
                    's' => {
                        if (self.count() != 0) if (self.reading) |r| {
                            const title = try self.db.titleAt(self.recordIndex(self.selected));
                            const was_saved = ReadingState.contains(r.data.saved, title);
                            try r.bookmark(title);
                            try r.save(self.io);
                            if (self.nav == .saved) {
                                const selected = self.selected;
                                try self.navigate(.saved);
                                self.selected = @min(selected, self.count() -| 1);
                            }
                            self.notice = if (was_saved) "Removed from Saved." else "Saved. Press 1 to see saved words.";
                        };
                    },
                    'r' => {
                        if (self.db.count() != 0) {
                            try self.navigate(.search);
                            self.len = 0;
                            self.cursor = 0;
                            try self.changed();
                            self.selected = self.random.random().uintLessThan(usize, self.count());
                            self.focus = .entry;
                            if (self.reading) |r| {
                                try r.remember(try self.db.titleAt(self.recordIndex(self.selected)));
                                try r.save(self.io);
                            }
                        }
                    },
                    't' => {
                        self.theme = switch (self.theme) {
                            .terminal => .dark,
                            .dark => .light,
                            .light => .terminal,
                        };
                        if (self.reading) |r| {
                            r.data.theme = @enumFromInt(@intFromEnum(self.theme));
                            try r.save(self.io);
                        }
                    },
                    'd' => {
                        self.details = !self.details;
                        self.expanded.clearRetainingCapacity();
                        if (self.reading) |r| {
                            r.data.details = self.details;
                            try r.save(self.io);
                        }
                        self.loaded = null;
                        self.scroll = 0;
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
        const index: ?usize = if (self.count() == 0) null else self.recordIndex(self.selected);
        if (index != self.fold_word) {
            self.expanded.clearRetainingCapacity();
            self.section = 0;
            self.fold_word = index;
        }
        if (index == null or index != self.loaded or self.text.len == 0) {
            var formatted: std.Io.Writer.Allocating = .init(self.a);
            defer formatted.deinit();
            if (index) |i| {
                var source_record = try self.db.recordAlloc(self.a, i);
                defer source_record.deinit();
                var doc = try model.fromRecord(self.a, source_record.record);
                defer doc.deinit();
                if (self.nav == .learn and self.reading != null and self.round >= self.reading.?.data.quiz_length) {
                    try formatted.writer.print("Round complete\n\n{d} / {d} correct\n\n4 starts another round.", .{ self.correct, self.round });
                } else if (self.nav == .learn and !self.revealed) {
                    try formatted.writer.print("{s}  /  {d} correct, {d} answered\n\n", .{ @tagName(self.game), self.correct, self.round });
                    if (self.game == .cards) {
                        try output.terminalText(&formatted.writer, doc.entry.title);
                        try formatted.writer.writeAll("\n\nRecall the meaning.\n\nSpace reveals it; y got it; n again.\nTab changes game.");
                    } else {
                        outer: for (doc.entry.sections) |section| for (section.blocks) |block| if (block.kind == .definition) {
                            for (block.spans) |span| {
                                try output.terminalText(&formatted.writer, span.text);
                                try output.terminalText(&formatted.writer, span.trail);
                            }
                            break :outer;
                        };
                        try formatted.writer.writeAll("\n\n");
                        if (self.game == .quiz) {
                            for (self.choices[0..self.choice_count], 0..) |choice, n| {
                                try formatted.writer.print("{d}  ", .{6 + n});
                                try output.terminalText(&formatted.writer, try self.db.titleAt(self.recordIndex(choice)));
                                try formatted.writer.writeByte('\n');
                            }
                            try formatted.writer.writeAll("\nTab changes game.");
                        } else {
                            var at = doc.entry.title.len;
                            while (at > 0) {
                                const prev = term.previousClusterStart(doc.entry.title, at);
                                try output.terminalText(&formatted.writer, doc.entry.title[prev..at]);
                                at = prev;
                            }
                            try formatted.writer.writeAll("\n\nYour answer: ");
                            try output.terminalText(&formatted.writer, self.answer_query[0..self.answer_len]);
                            try formatted.writer.writeAll("\nEnter checks; Tab changes game.");
                        }
                    }
                } else {
                    self.section_indices.clearRetainingCapacity();
                    for (doc.entry.sections, 0..) |section, s| if (section.blocks.len != 0) try self.section_indices.append(self.a, s);
                    self.section_count = self.section_indices.items.len;
                    self.section = @min(self.section, self.section_count -| 1);
                    if (self.nav == .learn and self.answered) try formatted.writer.writeAll("Space: next word\n\n");
                    if (self.focus == .entry) if (self.reading) |r| {
                        if (r.data.history.len == 0 or !std.mem.eql(u8, r.data.history[0], doc.entry.title)) {
                            try r.remember(doc.entry.title);
                            try r.save(self.io);
                        }
                    };
                    if (self.reading) |r| {
                        var preferences = r.data;
                        preferences.details = self.details;
                        const selected = if (self.section_indices.items.len == 0) 0 else self.section_indices.items[self.section];
                        self.section_offset = try output.entryTextFolded(&formatted, doc.entry, self.color, preferences, self.expanded.items, selected);
                    } else try output.entryTextWithDetails(&formatted.writer, doc.entry, self.color, self.details);
                }
            } else try formatted.writer.writeAll(if (self.searchPending()) "Searching dictionary...\n\nKeep typing to refine the search; Ctrl-U clears it." else switch (self.nav) {
                .saved => "No saved words yet.\n\nOpen a word, then press s to save it.\nPress / to find a word.",
                .history => "No viewed words yet.\n\nOpen a word with Enter to remember it.\nHistory can be enabled in Settings.",
                .learn => "No words in this study pool.\n\nChoose All in Settings, or add words to Saved or History.\nEsc returns to Search.",
                else => "No matching words.\n\nPress / to edit the prefix; Ctrl-U clears it.",
            });
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
        if (self.jump_section) {
            for (self.rows, 0..) |row, i| {
                const offset = @intFromPtr(row.bytes.ptr) - @intFromPtr(self.text.ptr);
                if (offset > self.section_offset) break;
                self.scroll = @min(i, self.rows.len -| self.bodyHeight());
            }
            self.jump_section = false;
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
    fn dock(self: State, w: *std.Io.Writer) !void {
        const labels = if (self.screen.cols < 72) [_][]const u8{ "1Save", "2Hist", "3Find", "4Lrn", "5Set", "L Lib" } else [_][]const u8{ "1 Saved", "2 History", "3 Search", "4 Learn", "5 Settings", "L Library" };
        const width = self.screen.cols / labels.len;
        for (labels, 0..) |label, i| try self.put(w, self.screen.rows, i * width + 1, width, label, if (@intFromEnum(self.nav) == i) palette(self.theme, self.color).selected else palette(self.theme, self.color).muted);
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
        } else if (self.nav == .library) {
            try self.put(w, 2, 3, sz.cols - 4, "Library", p.accent);
            try self.put(w, 3, 3, sz.cols - 4, if (self.notice.len == 0) self.db.root else self.notice, p.muted);
            try self.put(w, 4, 3, sz.cols - 4, "Installed dictionaries", p.muted);
            const visible = @max(1, sz.rows -| 10);
            const begin = self.library_selected / visible * visible;
            for (self.library_names.items[begin..@min(self.library_names.items.len, begin + visible)], begin..) |name, i| {
                try self.put(w, 6 + i - begin, 3, sz.cols - 4, name, if (i == self.library_selected) p.selected else p.base);
            }
            try self.put(w, sz.rows - 3, 3, sz.cols - 4, "Add files: dict install --help", p.muted);
            try self.put(w, sz.rows - 2, 3, sz.cols - 4, "Downloads: dict catalog", p.muted);
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, "↑↓ choose  Enter open  Esc search", p.muted);
            try self.dock(w);
        } else if (self.nav == .settings and self.reading != null) {
            const r = self.reading.?;
            try self.put(w, 2, 3, sz.cols - 4, "Settings", p.accent);
            var buf: [128]u8 = undefined;
            const labels = [_][]const u8{ "Atmosphere", "Supporting details", "Remember words", "Questions per round", "Pronunciation folded", "Etymology folded", "Other sections folded", "Examples & notes folded", "Clear history", "Online images", "Online audio", "Media cache (MiB)", "Dictionaries", "Study pool" };
            const visible = @max(1, (sz.rows -| 8) / 2);
            const begin = self.setting / visible * visible;
            for (labels[begin..@min(labels.len, begin + visible)], begin..) |label, i| {
                const row = 5 + (i - begin) * 2;
                try self.put(w, row, 3, sz.cols - 4, label, if (i == self.setting) p.selected else p.base);
                const value = switch (i) {
                    0 => @tagName(self.theme),
                    1 => if (self.details) "Expanded" else "Folded",
                    2 => if (r.data.history_limit == 0) "Off (existing history kept)" else try std.fmt.bufPrint(&buf, "{d}", .{r.data.history_limit}),
                    3 => try std.fmt.bufPrint(&buf, "{d}", .{r.data.quiz_length}),
                    4 => if (r.data.collapse_pronunciation) "On" else "Off",
                    5 => if (r.data.collapse_etymology) "On" else "Off",
                    6 => if (r.data.collapse_other) "On" else "Off",
                    7 => if (r.data.collapse_notes) "On" else "Off",
                    9 => if (r.data.allow_images) "On" else "Off",
                    10 => if (r.data.allow_audio) "On" else "Off",
                    11 => try std.fmt.bufPrint(&buf, "{d}", .{r.data.media_cache_mb}),
                    13 => switch (r.data.study_pool) {
                        .all => "All words",
                        .history => "History",
                        .saved => "Saved words",
                    },
                    else => "Enter",
                };
                try self.put(w, row + 1, 5, sz.cols - 6, value, p.muted);
            }
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, "↑↓ choose  ←→ adjust  Esc search", p.muted);
            if (self.notice.len != 0) try self.put(w, 3, 3, sz.cols - 4, self.notice, p.accent);
            try self.dock(w);
        } else {
            const split_at = if (self.nav == .learn) 0 else self.split();
            const content_col = if (split_at == 0) 3 else split_at + 3;
            const content_width = sz.cols - content_col - 1;
            try self.prepare(content_width);
            try self.put(w, 1, 3, 9, "dict.", p.accent);
            try self.put(w, 1, 13, sz.cols -| 15, self.label, p.muted);
            var buf: [256]u8 = undefined;
            try self.put(w, 2, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "{s}  /  {d} words  /  {d}/{d}", .{ @tagName(self.nav), self.db.count(), if (self.count() == 0) @as(usize, 0) else self.selected + 1, self.count() }), p.muted);
            if (self.notice.len != 0) try self.put(w, 3, 3, sz.cols - 4, self.notice, p.accent);
            if (self.searchPending()) try self.put(w, 3, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "Searching... {d}%  /  {d} matches", .{ self.search.cursor * 100 / @max(1, self.db.count()), self.count() }), p.muted);
            try self.put(w, 4, 3, 10, if (self.nav == .learn) "Study" else "Search /", if (self.focus == .search) p.accent else p.muted);
            // Horizontal input viewport follows the caret, at whole-codepoint boundaries.
            var start: usize = 0;
            const input_width = sz.cols - 15;
            while (term.cellWidth(self.query[start..self.cursor]) >= input_width) {
                const next_start = term.nextClusterEnd(self.query[0..self.len], start);
                if (next_start <= start) break;
                start = next_start;
            }
            try self.put(w, 4, 13, input_width, if (self.nav == .learn) "Tab game; Esc search" else self.query[start..self.len], p.base);
            const show_matches = split_at != 0 or self.focus != .entry;
            if (show_matches) {
                const cols = if (split_at == 0) sz.cols - 4 else split_at - 4;
                try self.put(w, 6, 3, cols, try std.fmt.bufPrint(&buf, "MATCHES  {d}", .{self.count()}), if (self.focus != .entry) p.accent else p.muted);
                const offset = (self.selected / @max(1, self.bodyHeight())) * @max(1, self.bodyHeight());
                for (0..self.bodyHeight()) |i| {
                    const n = offset + i;
                    if (n >= self.count()) break;
                    const title = try self.db.titleAt(self.recordIndex(n));
                    try self.put(w, 7 + i, 3, cols, title, if (n == self.selected) p.selected else p.base);
                }
                if (self.count() == 0) {
                    try self.put(w, 7, 3, cols, switch (self.nav) {
                        .saved => "No saved words yet.",
                        .history => "No viewed words yet.",
                        else => if (self.searchPending()) "Searching..." else "No matching words.",
                    }, p.muted);
                    try self.put(w, 8, 3, cols, if (self.nav == .saved) "Open a word; s saves it." else "/ search; Ctrl-U clear", p.muted);
                }
            }
            if (split_at != 0) for (5..sz.rows - 1) |row| try self.put(w, row, split_at, 1, "│", p.muted);
            if (split_at != 0 or self.focus == .entry) {
                try self.put(w, 6, content_col, content_width, "READING", if (self.focus == .entry) p.accent else p.muted);
                if (self.count() != 0 and content_width > 12) {
                    const title = try self.db.titleAt(self.recordIndex(self.selected));
                    const saved = if (self.reading) |r| ReadingState.contains(r.data.saved, title) else false;
                    try self.put(w, 6, content_col + 10, content_width - 10, if (saved) "Saved" else "s to save", if (saved) p.accent else p.muted);
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
            const hints: []const u8 = if (self.nav == .learn) "Tab game  Esc search  Ctrl-C quit" else switch (self.focus) {
                .search => "type to search  ↑↓ results  Enter read  Tab switch  Ctrl-U clear  Ctrl-C quit",
                .matches => if (self.nav == .history) "Enter read  Del remove  / search  ? help" else "/ search  ↑↓ select  Enter read  PgUp/PgDn page  ? help  q quit",
                .entry => "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  [ ] section  e fold  d all  s save  ? help",
            };
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, hints, p.muted);
            try self.dock(w);
            if (self.help) {
                const help = [_][]const u8{ "KEYBOARD", "Type in Search; ↑/↓ moves straight into results", "Enter reads the selected word; Esc steps back", "/ returns to Search from results or reading", "Tab cycles Search → Matches → Reading", "Arrows or j/k move; PgUp/PgDn and Home/End jump", "Ctrl-U clears the query; Ctrl-C/D quits", "[ ] selects a section; e toggles its fold", "d toggles all details; s saves the word", "r random word; 1 Saved 2 History 3 Search", "4 Learn: Tab game; Space reveal; y/n grade", "Quiz: 6-9 answer; Scramble: type then Enter", "v offline speech; m media in desktop player", "5 Settings: arrows adjust limits and appearance", "t cycles terminal/dark/light; q quits outside Search", "Any key closes this help" };
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

pub fn run(io: std.Io, a: std.mem.Allocator, db: *store.Store, label: []const u8, query: []const u8, theme: Theme, color: bool, initial_details: bool, case_sensitive: bool) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedTerminalPlatform;
    if (!try std.Io.File.stdin().isTty(io) or !try std.Io.File.stdout().isTty(io)) return error.TerminalRequired;
    if (!std.unicode.utf8ValidateSlice(query) or query.len > 4096) return error.InvalidQuery;
    var reading = ReadingState.init(a);
    defer reading.deinit();
    try reading.load(io, db.root, label);
    defer {
        if (std.fs.path.join(a, &.{ db.root, ".dict-media" })) |cache| {
            defer a.free(cache);
            @import("reader_media.zig").trim(io, a, cache, reading.data.media_cache_mb) catch {};
        } else |_| {}
    }
    var state: State = .{ .reading = &reading, .a = a, .io = io, .db = db, .label = label, .theme = theme, .color = color, .details = initial_details };
    state.case_sensitive = case_sensitive;
    defer state.deinit();
    if (theme == .terminal) state.theme = @enumFromInt(@intFromEnum(reading.data.theme));
    state.details = initial_details or reading.data.details;
    @memcpy(state.query[0..query.len], query);
    state.len = query.len;
    state.cursor = query.len;
    try state.changed();
    if (query.len == 0 and reading.data.last_title.len != 0) if (try db.find(reading.data.last_title)) |index| {
        state.selected = index;
        state.focus = .entry;
    };
    var session = try term.Session.enter();
    defer session.leave();
    var input: term.Input = .{};
    var dirty = true;
    var last_input = std.Io.Clock.awake.now(io).toNanoseconds();
    var running = true;
    while (running and !term.Session.shouldQuit()) {
        dirty = state.mediaPoll() or dirty;
        dirty = try state.searchStep() or dirty;
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
        if (try std.posix.poll(&fds, if (state.searchPending()) 0 else 100) == 0) {
            if (std.Io.Clock.awake.now(io).toNanoseconds() - last_input >= 100_000_000) if (input.flushEscape()) |event| {
                if (!try state.key(event)) break;
                dirty = true;
            };
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
        last_input = std.Io.Clock.awake.now(io).toNanoseconds();
        for (bytes[0..n]) |b| if (input.feed(b)) |event| {
            if (!try state.key(event)) {
                running = false;
                break;
            }
            dirty = true;
        };
    }
    try reading.save(io);
}

test "terminal query editing is bounded and UTF8-aware" {
    const dec = @import("blob_decoder");
    const a = std.testing.allocator;
    const stored: enc.presentation_types.Stored = .{ .entry = .{ .title = "café", .kind = .citations } };
    const payload = try enc.presentation_codec.encodeAlloc(a, stored);
    defer a.free(payload);
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{ .{ .title = "café", .payload = payload }, .{ .title = "cat", .payload = payload } });
    defer a.free(bytes);
    var index = try (try dec.openTrustedBlob(bytes)).buildIndexAlloc(a);
    defer index.deinit(a);
    // Test the pure state; Store's mapping and OS handles are not used by input handling.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sample", .{tmp.sub_path});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
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

    var reading = ReadingState.init(a);
    defer reading.deinit();
    state.reading = &reading;
    state.io = std.testing.io;
    _ = try state.key(.{ .key = .clear });
    try state.insert("ca");
    _ = try state.key(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    _ = try state.key(.{ .key = .enter });
    try state.navigate(.history);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    _ = try state.key(.{ .key = .clear });
    try std.testing.expectEqual(Page.search, state.nav);
    try state.insert("ca");
    try state.navigate(.learn);
    try std.testing.expectEqualStrings("ca", state.query[0..state.len]);
    try std.testing.expectEqual(@as(usize, 2), state.choice_count);
    try std.testing.expect(state.choices[0] != state.choices[1]);
    reading.data.quiz_length = 1;
    try state.answer(true);
    try state.answer(true);
    try std.testing.expectEqual(@as(usize, 1), state.round);
    try std.testing.expectEqual(@as(usize, 1), reading.data.right);
    _ = try state.key(.{ .key = .escape });
    try std.testing.expectEqual(Page.search, state.nav);
    try std.testing.expectEqualStrings("ca", state.query[0..state.len]);
    state.game = .scramble;
    try state.navigate(.learn);
    _ = try state.key(.{ .key = .text, .bytes = .{ '1', 0, 0, 0 }, .len = 1 });
    try std.testing.expectEqual(Page.learn, state.nav);
    try std.testing.expectEqualStrings("1", state.answer_query[0..state.answer_len]);
    _ = try state.key(.{ .key = .escape });
    _ = try state.key(.{ .key = .tab });
    state.help = true;
    _ = try state.key(.{ .key = .text, .bytes = .{ '1', 0, 0, 0 }, .len = 1 });
    try std.testing.expectEqual(Page.search, state.nav);
    try std.testing.expect(!state.help);
    _ = try state.key(.{ .key = .text, .bytes = .{ 't', 0, 0, 0 }, .len = 1 });
    try std.testing.expectEqual(@intFromEnum(state.theme), @intFromEnum(reading.data.theme));
    try state.navigate(.settings);
    state.setting = 8;
    _ = try state.key(.{ .key = .right });
    try std.testing.expectEqual(@as(usize, 1), reading.data.history.len);
    _ = try state.key(.{ .key = .enter });
    try std.testing.expect(state.confirm_clear_history);
    _ = try state.key(.{ .key = .escape });
    try std.testing.expectEqual(@as(usize, 1), reading.data.history.len);
    _ = try state.key(.{ .key = .enter });
    _ = try state.key(.{ .key = .enter });
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
    state.case_sensitive = false;
    try state.navigate(.search);
    _ = try state.key(.{ .key = .clear });
    try state.insert("CA");
    try std.testing.expect(state.searchPending());
    _ = try state.searchStep();
    try std.testing.expect(!state.searchPending());
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expectEqualStrings("café", try state.db.titleAt(state.recordIndex(0)));
    _ = try state.key(.{ .key = .clear });
    try state.insert("missing");
    _ = try state.searchStep();
    try std.testing.expectEqual(@as(usize, 0), state.count());
    try state.prepare(40);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "No matching words") != null);
    // Restricted study pools must never silently draw from the full dictionary.
    reading.data.study_pool = .history;
    try state.navigate(.learn);
    try std.testing.expectEqual(@as(usize, 0), state.count());
    try state.prepare(40);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "No words in this study pool") != null);
    try reading.remember("cat");
    try state.navigate(.learn);
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expectEqualStrings("cat", try state.db.titleAt(state.recordIndex(state.selected)));
    try std.testing.expectEqual(@as(usize, 1), state.choice_count);
}
