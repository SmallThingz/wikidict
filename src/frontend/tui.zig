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

const wideHelp = [_][]const u8{ "KEYBOARD", "Type in Search; ↑/↓ moves straight into results", "Enter reads the selected word; Esc steps back", "/ returns to Search from results or reading", "Tab cycles Search → Matches → Reading", "Arrows or j/k move; PgUp/PgDn and Home/End jump", "Ctrl-U clears the query; Ctrl-C/D quits", "[ ] selects a section; e toggles its fold", "d toggles all details; s saves the word", "r random word; 1 Saved 2 History 3 Search", "4 Learn: Tab game; Space reveal; y/n grade", "Quiz: 6-9 answer; Scramble: type then Enter", "v offline speech; m media in desktop player", "5 Settings: arrows adjust limits and appearance", "t cycles terminal/dark/light; q quits outside Search", "Any key closes this help" };
const helpScrollHint = "↑↓ scroll PgUp/Dn Home/End Esc close";
const helpCloseHint = "Any key closes help";
fn helpLines(columns: usize) []const []const u8 {
    for (wideHelp) |line| if (term.cellWidth(line) > columns -| 4) return &.{
        "KEYBOARD",
        "Type in Search; ↑↓ selects results",
        "Enter reads; Esc steps back",
        "/ Search; Tab cycles panes",
        "Arrows/j/k move; PgUp/PgDn page",
        "Home/End jump; Ctrl-U clears",
        "Ctrl-C/D quits",
        "[ ] section; e folds; d all details",
        "s saves; r random word",
        "1 Saved; 2 History; 3 Search",
        "4 Learn: Tab game; Space reveal",
        "y/n grade; Quiz: 6-9 answer",
        "Scramble: type then Enter",
        "v offline speech",
        "m media in desktop player",
        "5 Settings: arrows adjust limits",
        "and appearance",
        "t terminal/dark/light theme",
        "q quits outside Search",
        "Any key closes this help",
    };
    return &wideHelp;
}

fn readingHints(columns: usize) []const u8 {
    const wide = "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  [ ] section  e fold  d all  s save  ? help";
    // Reserve the existing left/right footer margins and measure terminal cells.
    return if (term.cellWidth(wide) <= columns -| 4) wide else "Esc back ↑↓ e fold d details ? help";
}

fn studyMeaning(entry: model.Entry) error{InvalidPresentation}!?model.Block {
    if (entry.organization.lexemes.len != 0) {
        var selected: ?model.Block = null;
        for (entry.organization.lexemes) |lexeme| {
            if (lexeme.section >= entry.sections.len) return error.InvalidPresentation;
            const blocks = entry.sections[lexeme.section].blocks;
            for (lexeme.definitions, 0..) |sense, index| {
                if (sense.parent) |parent| if (parent >= index) return error.InvalidPresentation;
                const block = enc.presentation_types.resolveBlockPath(blocks, sense.block, sense.block_path) orelse
                    return error.InvalidPresentation;
                if (selected == null) selected = block.*;
            }
        }
        // An explicit organization with no senses is not permission to guess
        // a clue from supporting body. Validate all addresses before choosing.
        return selected;
    }
    // Preserve the legacy fallback for records without lexical organization.
    for (entry.sections) |section| if (output.firstDefinition(section.blocks, 0)) |block| return block;
    return null;
}
const Palette = struct { base: []const u8, accent: []const u8, muted: []const u8, selected: []const u8 };
fn palette(theme: Theme, color: bool) Palette {
    if (!color) return .{ .base = "\x1b[0m", .accent = "\x1b[1m", .muted = "\x1b[0m", .selected = "\x1b[7m" };
    return switch (theme) {
        .terminal => .{ .base = "\x1b[0m", .accent = "\x1b[1;36m", .muted = "\x1b[2m", .selected = "\x1b[7m" },
        .dark => .{ .base = "\x1b[0;48;2;23;37;30;38;2;228;231;218m", .accent = "\x1b[1;38;2;233;184;138m", .muted = "\x1b[38;2;167;180;166m", .selected = "\x1b[48;2;76;56;39;38;2;233;184;138m" },
        .light => .{ .base = "\x1b[0;47;30m", .accent = "\x1b[1;34m", .muted = "\x1b[38;5;240m", .selected = "\x1b[48;5;252;30m" },
    };
}
// The query retains its original bytes for search and editing. Measure the
// exact escaped display, and scroll only past complete original clusters.
const QueryDisplay = struct { text: []u8, caret_cells: usize };
fn queryDisplay(a: std.mem.Allocator, query: []const u8, cursor: usize, cells: usize) !QueryDisplay {
    var rendered: std.Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    var boundaries: std.ArrayList(usize) = .empty;
    defer boundaries.deinit(a);
    try boundaries.append(a, 0);
    var raw: usize = 0;
    while (raw < cursor) {
        const end = @min(cursor, term.nextClusterEnd(query, raw));
        try output.terminalText(&rendered.writer, query[raw..end]);
        try boundaries.append(a, rendered.written().len);
        raw = end;
    }
    const rendered_cursor = rendered.written().len;
    try output.terminalText(&rendered.writer, query[cursor..]);
    // Match the single-line field's existing whitespace presentation.
    for (rendered.written()) |*byte| if (byte.* == '\n' or byte.* == '\t') {
        byte.* = ' ';
    };
    var first: usize = 0;
    while (term.cellWidth(rendered.written()[boundaries.items[first]..rendered_cursor]) >= @max(cells, 1)) first += 1;
    const start = boundaries.items[first];
    return .{ .text = try a.dupe(u8, rendered.written()[start..]), .caret_cells = term.cellWidth(rendered.written()[start..rendered_cursor]) };
}

const State = struct {
    io: std.Io = undefined,
    a: std.mem.Allocator,
    db: *store.Store,
    label: []const u8,
    label_owned: bool = false,
    library_names: std.ArrayList([]const u8) = .empty,
    library_selected: usize = 0,
    startup_library: bool = false,
    query: [4096]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    range: store.Range = .{ .start = 0, .end = 0 },
    search: Search = .{},
    folded_search: bool = false,
    exact_title_index: ?usize = null,
    displayed_match_count: usize = 0,
    case_sensitive: bool = true,
    selected: usize = 0,
    scroll: usize = 0,
    focus: Focus = .search,
    theme: Theme,
    color: bool,
    details: bool = false,
    help: bool = false,
    help_offset: usize = 0,
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
    study_meaning_index: ?usize = null,
    study_has_meaning: bool = false,
    expanded: std.ArrayList(usize) = .empty,
    round: usize = 0,
    correct: usize = 0,
    random: std.Random.DefaultPrng = .init(31337),
    loaded: ?usize = null,
    text: []const u8 = &.{},
    rows: []term.RenderRow = &.{},
    visual_text: []const u8 = &.{},
    row_origins: []output.FlowOrigin = &.{},
    flow_events: std.ArrayList(output.FlowEvent) = .empty,
    float_unsupported: usize = 0,
    poem_lines: std.ArrayList(term.PoemLine) = .empty,
    wrap_width: usize = 0,
    format_width: usize = 0,
    format_theme: ?Theme = null,
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
        self.poem_lines.deinit(self.a);
        self.a.free(self.rows);
        self.a.free(self.visual_text);
        self.a.free(self.row_origins);
        self.flow_events.deinit(self.a);
        self.a.free(self.text);
    }
    fn count(self: State) usize {
        return if (self.usesFilteredRecords()) self.filtered.items.len else self.range.end - self.range.start;
    }
    fn recordIndex(self: State, n: usize) usize {
        return if (self.usesFilteredRecords()) self.filtered.items[n] else self.range.start + n;
    }
    fn usesFilteredRecords(self: State) bool {
        return (self.nav == .search and self.folded_search) or self.nav == .saved or self.nav == .history or
            (self.nav == .learn and self.reading != null and self.reading.?.data.study_pool != .all);
    }
    fn navigate(self: *State, page_name: Page) !void {
        if (page_name == .library) try self.loadLibrary() else self.startup_library = false;
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
        const label = try next_db.labelAlloc(self.a);
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
        self.theme = @fromBackingInt(@intCast(@backingInt(reading.data.theme)));
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
        self.study_meaning_index = null;
        self.expanded.clearRetainingCapacity();
        self.a.free(self.text);
        self.text = &.{};
        self.poem_lines.clearRetainingCapacity();
        self.a.free(self.rows);
        self.rows = &.{};
        self.notice = "Dictionary opened.";
    }
    fn nextCard(self: *State) void {
        if (self.roundComplete()) return;
        if (self.count() != 0) self.selected = self.random.random().uintLessThan(usize, self.count());
        self.revealed = false;
        self.answered = false;
        self.study_meaning_index = null;
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
    fn hasStudyMeaning(self: *State) !bool {
        if (self.count() == 0) return false;
        const index = self.recordIndex(self.selected);
        if (self.study_meaning_index != index) {
            var record = try self.db.recordAlloc(self.a, index);
            defer record.deinit();
            var doc = try model.fromRecord(self.a, record.record);
            defer doc.deinit();
            self.study_has_meaning = (try studyMeaning(doc.entry)) != null;
            self.study_meaning_index = index;
        }
        return self.study_has_meaning;
    }
    fn answer(self: *State, correct: bool) !void {
        if (self.answered or self.roundComplete() or self.count() == 0) return;
        // Reading material is not automatically a structured study clue.
        if (!try self.hasStudyMeaning()) return;
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
        if (item.kind == .image and try output.mediaRequiresPoster(doc.entry, item.file)) {
            self.notice = "3D preview unavailable here; its text label and File action are retained.";
            return;
        }
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
    fn libraryPageSize(self: State) usize {
        return @max(1, self.screen.rows -| 10);
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
            self.exact_title_index = try self.db.find(std.mem.trim(u8, self.query[0..self.len], " \t\r\n"));
            self.displayed_match_count = 0;
            if (self.exact_title_index) |index| try self.filtered.append(self.a, index);
        } else self.range = try self.db.prefix(if (self.case_sensitive) self.query[0..self.len] else "");
        self.selected = 0;
        self.scroll = 0;
    }
    fn searchPending(self: State) bool {
        return self.nav == .search and self.folded_search and !self.search.complete;
    }
    fn searchStep(self: *State, budget: usize) !bool {
        if (!self.searchPending()) return false;
        const before = self.count();
        try self.search.step(self.a, self.db, budget);
        if (!self.search.complete and (self.displayed_match_count != 0 or self.search.matches.items.len == 0) and self.search.cursor % 65536 != 0) return false;
        if (self.displayed_match_count == self.search.total_matches) return true;
        const selected = if (self.focus != .search and before != 0) self.recordIndex(self.selected) else null;
        try self.search.rankedRecordIndices(self.a, &self.filtered);
        if (self.exact_title_index) |exact| {
            // Case-folded peers stay searchable. The user's exact spelling leads even before the scan reaches it.
            if (std.mem.indexOfScalar(usize, self.filtered.items, exact)) |slot| {
                std.mem.copyBackwards(usize, self.filtered.items[1 .. slot + 1], self.filtered.items[0..slot]);
                self.filtered.items[0] = exact;
            } else {
                if (self.filtered.items.len == self.search.max_matches) _ = self.filtered.pop();
                try self.filtered.insert(self.a, 0, exact);
            }
        }
        self.displayed_match_count = self.search.total_matches;
        self.selected = if (selected) |index| std.mem.indexOfScalar(usize, self.filtered.items, index) orelse 0 else 0;
        return true;
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
    fn openSelected(self: *State) !void {
        self.focus = .entry;
        if (self.count() != 0) if (self.reading) |r| {
            try r.remember(try self.db.titleAt(self.recordIndex(self.selected)));
            try r.save(self.io);
        };
    }
    fn key(self: *State, event: term.Event) !bool {
        if (event.key == .quit) return false;
        if (self.help) {
            const maximum = self.helpMaxOffset();
            self.help_offset = @min(self.help_offset, maximum);
            // Full-height Help keeps its existing any-key-close behavior.
            if (maximum != 0) {
                const step = @max(1, self.helpCapacity() -| 1);
                switch (event.key) {
                    .up => self.help_offset -|= 1,
                    .down => self.help_offset = @min(maximum, self.help_offset +| 1),
                    .page_up => self.help_offset -|= step,
                    .page_down => self.help_offset = @min(maximum, self.help_offset +| step),
                    .home => self.help_offset = 0,
                    .end => self.help_offset = maximum,
                    else => {
                        self.help = false;
                        self.help_offset = 0;
                    },
                }
            } else {
                self.help = false;
                self.help_offset = 0;
            }
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
        const missing_meaning = self.nav == .learn and !self.answered and !self.roundComplete() and self.count() != 0 and !try self.hasStudyMeaning();
        const answering = self.nav == .learn and self.game == .scramble and !self.answered and !self.roundComplete() and !missing_meaning;
        if (event.key == .text and !event.pasted and !answering and self.focus != .search and event.len == 1 and event.bytes[0] == 'L') {
            self.navigate(.library) catch {
                self.notice = "Could not read installed dictionaries. Check the dataset folder.";
            };
            return true;
        }
        if (event.key == .text and !event.pasted and !answering and self.focus != .search and event.len == 1 and event.bytes[0] >= '1' and event.bytes[0] <= '5') {
            try self.navigate(@fromBackingInt(@intCast(event.bytes[0] - '1')));
            return true;
        }
        if (self.nav == .library) {
            switch (event.key) {
                .up => self.library_selected -|= 1,
                .down => self.library_selected = @min(self.library_names.items.len -| 1, self.library_selected + 1),
                .page_up => self.library_selected -|= self.libraryPageSize(),
                .page_down => self.library_selected = @min(self.library_names.items.len -| 1, self.library_selected +| self.libraryPageSize()),
                .home => self.library_selected = 0,
                .end => self.library_selected = self.library_names.items.len -| 1,
                .enter => if (self.library_names.items.len != 0) {
                    const prefix_len = if (self.startup_library) self.len else 0;
                    self.switchDictionary(self.library_names.items[self.library_selected]) catch {
                        self.notice = "Could not open this dictionary. Your current word is kept.";
                        return true;
                    };
                    self.startup_library = false;
                    if (prefix_len != 0) {
                        self.len = prefix_len;
                        self.cursor = prefix_len;
                        try self.changed();
                    }
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
                            r.data.theme = @fromBackingInt(@intCast(@backingInt(self.theme)));
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
            if (missing_meaning) {
                if (event.key == .text and !event.pasted and event.len == 1) switch (event.bytes[0]) {
                    'c' => {
                        self.game = .cards;
                        self.revealed = false;
                        self.answer_len = 0;
                        self.loaded = null;
                        return true;
                    },
                    'o' => {
                        self.revealed = true;
                        self.loaded = null;
                        return true;
                    },
                    ' ' => {
                        if (self.game == .cards) {
                            self.revealed = !self.revealed;
                            self.loaded = null;
                        } else self.nextCard();
                        return true;
                    },
                    'n' => {
                        self.nextCard();
                        return true;
                    },
                    'q' => return false,
                    else => {},
                };
                // Open entry keeps ordinary body navigation, never answer input.
                if (!self.revealed or event.key == .enter or event.key == .backspace or event.pasted) return true;
                if (event.key == .text and event.len == 1 and (event.bytes[0] == 'y' or (event.bytes[0] >= '6' and event.bytes[0] <= '9'))) return true;
            }
            if (self.game == .scramble and !self.answered and !missing_meaning) {
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
                    const lower = @import("unicode_lower");
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
                if (self.game == .quiz and !self.answered and !missing_meaning and c >= '6' and c < '6' + self.choice_count) {
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
            .tab => switch (self.focus) {
                .search => self.focus = .matches,
                .matches => try self.openSelected(),
                .entry => self.focus = .search,
            },
            .enter => if (self.count() != 0) try self.openSelected(),
            .up, .down => {
                if (self.focus == .search and self.count() != 0) self.focus = .matches else self.page(event.key == .down, 1);
            },
            .page_up => self.page(false, @max(1, self.bodyHeight() -| 1)),
            .page_down => self.page(true, @max(1, self.bodyHeight() -| 1)),
            .left => {
                if (self.focus == .search) self.cursor = self.previous() else self.focus = .matches;
            },
            .right => {
                if (self.focus == .search) self.cursor = self.next() else if (self.focus != .entry and self.nav != .learn) try self.openSelected() else self.focus = .entry;
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
                            r.data.theme = @fromBackingInt(@intCast(@backingInt(self.theme)));
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
                    '?' => {
                        self.help = true;
                        self.help_offset = 0;
                    },
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
        if (index == null or index != self.loaded or self.text.len == 0 or self.format_width != width or self.format_theme != self.theme) {
            const preserve_scroll = index != null and index == self.loaded and self.text.len != 0;
            const previous_scroll = self.scroll;
            var formatted: std.Io.Writer.Allocating = .init(self.a);
            defer formatted.deinit();
            var poem_lines: std.ArrayList(term.PoemLine) = .empty;
            defer poem_lines.deinit(self.a);
            var float_flow: output.FloatProjection = .{ .allocator = self.a, .frame = &formatted, .columns = width };
            defer float_flow.events.deinit(self.a);
            var projection: output.PoemProjection = .{ .frame = &formatted, .allocator = self.a, .lines = &poem_lines, .table_columns = width, .float_flow = &float_flow, .viewport_columns = width, .dark_theme = switch (self.theme) { .dark => true, .light => false, .terminal => null } };
            if (index) |i| {
                var source_record = try self.db.recordAlloc(self.a, i);
                defer source_record.deinit();
                var doc = try model.fromRecord(self.a, source_record.record);
                defer doc.deinit();
                const meaning = try studyMeaning(doc.entry);
                self.study_meaning_index = i;
                self.study_has_meaning = meaning != null;
                if (self.nav == .learn and self.reading != null and self.round >= self.reading.?.data.quiz_length) {
                    try formatted.writer.print("Round complete\n\n{d} / {d} correct\n\n4 starts another round.", .{ self.correct, self.round });
                } else if (self.nav == .learn and !self.revealed) {
                    try formatted.writer.print("{s}  /  {d} correct, {d} answered\n\n", .{ @tagName(self.game), self.correct, self.round });
                    if (self.game == .cards) {
                        try output.terminalText(&formatted.writer, doc.entry.title);
                        try formatted.writer.writeAll(if (meaning == null)
                            "\n\nNo structured meaning for a scored question.\n\nSpace reveals the entry; n skips.\nTab changes game."
                        else
                            "\n\nRecall the meaning.\n\nSpace reveals it; y got it; n again.\nTab changes game.");
                    } else if (meaning == null) {
                        try formatted.writer.writeAll("No structured meaning for a scored question.\n\nc Cards   o Open entry\nSpace skips without scoring.\nTab changes game.");
                    } else {
                        try output.spansPlainText(&formatted.writer, meaning.?.spans);
                        try formatted.writer.writeAll("\n\n");
                        if (self.game == .quiz) {
                            for (self.choices[0..self.choice_count], 0..) |choice, n| {
                                try formatted.writer.print("{d}  ", .{6 + n});
                                try output.terminalText(&formatted.writer, try self.db.titleAt(self.recordIndex(choice)));
                                try formatted.writer.writeByte('\n');
                            }
                            try formatted.writer.writeAll("\nTab changes game.");
                        } else {
                            const answer_title = try self.db.titleAt(self.recordIndex(self.selected));
                            var at = answer_title.len;
                            while (at > 0) {
                                const prev = term.previousClusterStart(answer_title, at);
                                try output.terminalText(&formatted.writer, answer_title[prev..at]);
                                at = prev;
                            }
                            try formatted.writer.writeAll("\n\nYour answer: ");
                            try output.terminalText(&formatted.writer, self.answer_query[0..self.answer_len]);
                            try formatted.writer.writeAll("\nEnter checks; Tab changes game.");
                        }
                    }
                } else {
                    self.section_indices.clearRetainingCapacity();
                    for (doc.entry.sections, 0..) |section, s| if (output.foldedSectionVisible(section)) try self.section_indices.append(self.a, s);
                    self.section_count = self.section_indices.items.len;
                    self.section = @min(self.section, self.section_count -| 1);
                    if (self.nav == .learn and self.answered) try formatted.writer.writeAll("Space: next word\n\n");
                    if (self.nav == .learn and meaning == null) try formatted.writer.writeAll("Unscored entry: no structured meaning.\nc Cards   n Skip   Esc search\n\n");
                    if (!preserve_scroll and self.focus == .entry) if (self.reading) |r| {
                        const selected_title = try self.db.titleAt(i);
                        if (r.data.history.len == 0 or !std.mem.eql(u8, r.data.history[0], selected_title)) {
                            try r.remember(selected_title);
                            try r.save(self.io);
                        }
                    };
                    if (self.reading) |r| {
                        var preferences = r.data;
                        preferences.details = self.details;
                        const selected = if (self.section_indices.items.len == 0) 0 else self.section_indices.items[self.section];
                        self.section_offset = try output.entryTextFoldedProjected(&formatted, doc.entry, self.color, preferences, self.expanded.items, selected, &projection);
                    } else try output.entryTextWithDetailsProjected(&formatted.writer, doc.entry, self.color, self.details, &projection);
                    if (self.nav != .learn) try output.writeEmptyLanguageNotice(&formatted.writer, doc.entry);
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
            self.a.free(self.visual_text);
            self.visual_text = &.{};
            self.a.free(self.row_origins);
            self.row_origins = &.{};
            self.a.free(self.text);
            self.text = text;
            self.poem_lines.deinit(self.a);
            self.poem_lines = poem_lines;
            poem_lines = .empty;
            self.flow_events.deinit(self.a);
            self.flow_events = float_flow.events;
            float_flow.events = .empty;
            self.loaded = index;
            self.format_width = width;
            self.format_theme = self.theme;
            self.wrap_width = 0;
            self.scroll = if (preserve_scroll) previous_scroll else 0;
        }
        if (self.wrap_width != width) {
            if (self.flow_events.items.len != 0) {
                const layout = try output.floatLayoutAlloc(self.a, self.text, width, self.poem_lines.items, self.flow_events.items, self.color);
                self.a.free(self.rows);
                self.a.free(self.visual_text);
                self.a.free(self.row_origins);
                self.rows = layout.rows;
                self.visual_text = layout.text;
                self.row_origins = layout.origins;
                self.float_unsupported = layout.unsupported;
            } else {
                const rows = try term.wrapPaneProse(self.a, self.text, width, self.poem_lines.items);
                self.a.free(self.rows);
                self.a.free(self.visual_text);
                self.visual_text = &.{};
                self.a.free(self.row_origins);
                self.row_origins = &.{};
                self.float_unsupported = 0;
                self.rows = rows;
            }
            self.wrap_width = width;
        }
        self.scroll = @min(self.scroll, self.rows.len -| self.bodyHeight());
        if (self.jump_section) {
            if (self.row_origins.len != 0) {
                self.scroll = @min(output.flowRowForOffset(self.row_origins, self.section_offset), self.rows.len -| self.bodyHeight());
            } else for (self.rows, 0..) |row, i| {
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
    fn helpCapacity(self: State) usize {
        return self.screen.rows -| 7;
    }
    fn helpMaxOffset(self: State) usize {
        return helpLines(self.screen.cols).len -| self.helpCapacity();
    }
    fn drawHelp(self: *State, w: *std.Io.Writer) !void {
        const sz = self.screen;
        const p = palette(self.theme, self.color);
        const lines = helpLines(sz.cols);
        const maximum = self.helpMaxOffset();
        // Resize changes both line count and capacity without a key event.
        self.help_offset = @min(self.help_offset, maximum);
        if (sz.rows <= 7) return;
        for (6..sz.rows - 1) |row| try w.print("\x1b[{d};1H{s}\x1b[2K", .{ row, p.base });
        for (lines[self.help_offset..], 0..) |line, i| {
            if (i >= self.helpCapacity()) break;
            const index = self.help_offset + i;
            const visible = if (maximum != 0 and index + 1 == lines.len) "Other keys close this help" else line;
            try self.put(w, 6 + i, 3, sz.cols -| 4, visible, if (index == 0) p.accent else p.base);
        }
        try w.print("\x1b[{d};1H{s}\x1b[2K", .{ sz.rows - 1, p.base });
        try self.put(w, sz.rows - 1, 3, sz.cols -| 4, if (maximum != 0) helpScrollHint else helpCloseHint, p.muted);
    }
    fn dock(self: State, w: *std.Io.Writer) !void {
        const labels = if (self.screen.cols < 72) [_][]const u8{ "1Save", "2Hist", "3Find", "4Lrn", "5Set", "L Lib" } else [_][]const u8{ "1 Saved", "2 History", "3 Search", "4 Learn", "5 Settings", "L Library" };
        const width = self.screen.cols / labels.len;
        for (labels, 0..) |label, i| try self.put(w, self.screen.rows, i * width + 1, width, label, if (@backingInt(self.nav) == i) palette(self.theme, self.color).selected else palette(self.theme, self.color).muted);
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
            const visible = self.libraryPageSize();
            const begin = self.library_selected / visible * visible;
            for (self.library_names.items[begin..@min(self.library_names.items.len, begin + visible)], begin..) |name, i| {
                try self.put(w, 6 + i - begin, 3, sz.cols - 4, name, if (i == self.library_selected) p.selected else p.base);
            }
            try self.put(w, sz.rows - 3, 3, sz.cols - 4, "Add files: dict install --help", p.muted);
            try self.put(w, sz.rows - 2, 3, sz.cols - 4, "Downloads: dict catalog", p.muted);
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, if (sz.cols < 72) "↑↓ PgUp/Dn Home/End  Enter  Esc" else "↑↓ choose  PgUp/PgDn page  Home/End  Enter open  Esc search", p.muted);
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
            const empty_personal_list = (self.nav == .saved or self.nav == .history) and self.count() == 0;
            const split_at = if (self.nav == .learn or empty_personal_list) 0 else self.split();
            const content_col = if (split_at == 0) 3 else split_at + 3;
            const content_width = sz.cols - content_col - 1;
            try self.prepare(content_width);
            try self.put(w, 1, 3, 9, "dict.", p.accent);
            try self.put(w, 1, 13, sz.cols -| 15, self.label, p.muted);
            var buf: [256]u8 = undefined;
            const words = self.db.count();
            try self.put(w, 2, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "{s}  /  {d} {s}  /  {d}/{d}", .{
                @tagName(self.nav), words, if (words == 1) "word" else "words",
                if (self.count() == 0) @as(usize, 0) else self.selected + 1, self.count(),
            }), p.muted);
            if (self.notice.len != 0) try self.put(w, 3, 3, sz.cols - 4, self.notice, p.accent);
            if (self.searchPending()) try self.put(w, 3, 3, sz.cols - 4, try std.fmt.bufPrint(&buf, "Searching... {d}%  /  {d} matches", .{ self.search.cursor * 100 / @max(1, self.db.count()), self.count() }), p.muted);
            try self.put(w, 4, 3, 10, if (self.nav == .learn) "Study" else "Search /", if (self.focus == .search) p.accent else p.muted);
            const input_width = sz.cols - 15;
            const query_view = try queryDisplay(self.a, self.query[0..self.len], self.cursor, input_width);
            defer self.a.free(query_view.text);
            try self.put(w, 4, 13, input_width, if (self.nav == .learn) "Tab game; Esc search" else query_view.text, p.base);
            const show_matches = !empty_personal_list and (split_at != 0 or self.focus != .entry);
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
                    try self.put(w, 7, 3, cols, if (self.searchPending()) "Searching..." else "No matching words.", p.muted);
                    try self.put(w, 8, 3, cols, "/ search; Ctrl-U clear", p.muted);
                }
            }
            if (split_at != 0) for (5..sz.rows - 1) |row| try self.put(w, row, split_at, 1, "│", p.muted);
            const empty_search_in_matches = show_matches and self.nav == .search and self.count() == 0;
            if ((empty_personal_list or split_at != 0 or self.focus == .entry) and !empty_search_in_matches) {
                const heading = if (!empty_personal_list) "READING" else if (self.nav == .saved) "SAVED" else "HISTORY";
                try self.put(w, 6, content_col, content_width, heading, if (self.focus == .entry) p.accent else p.muted);
                if (self.count() != 0 and content_width > 12) {
                    const title = try self.db.titleAt(self.recordIndex(self.selected));
                    const saved = if (self.reading) |r| ReadingState.contains(r.data.saved, title) else false;
                    try self.put(w, 6, content_col + 10, content_width - 10, if (saved) "Saved" else "s to save", if (saved) p.accent else p.muted);
                }
                for (0..self.bodyHeight()) |i| {
                    if (self.scroll + i >= self.rows.len) break;
                    const row = self.rows[self.scroll + i];
                    try w.print("\x1b[{d};{d}H{s}", .{ 7 + i, content_col, p.base });
                    try term.writeRenderRow(w, row, content_width, p.base);
                    try w.writeAll(p.base);
                }
            }
            const hints: []const u8 = if (self.nav == .learn)
                (if (self.count() != 0 and !self.study_has_meaning and !self.roundComplete()) "c Cards  o Open  n Skip  Esc search" else "Tab game  Esc search  Ctrl-C quit")
            else if (empty_personal_list) "/ search  5 Settings  ? help  q quit" else switch (self.focus) {
                .search => if (sz.cols < 81) "type  ↑↓ select  Enter read  ^C quit" else "type to search  ↑↓ results  Enter read  Tab switch  Ctrl-U clear  Ctrl-C quit",
                .matches => if (self.nav == .history) "Enter read  Del remove  / search  ? help" else "/ search  ↑↓ select  Enter read  PgUp/PgDn page  ? help  q quit",
                .entry => readingHints(sz.cols),
            };
            try self.put(w, sz.rows - 1, 3, sz.cols - 4, hints, p.muted);
            try self.dock(w);
            if (self.help) {
                try self.drawHelp(w);
            } else if (self.focus == .search) try w.print("\x1b[{d};{d}H\x1b[?25h", .{ 4, 13 + query_view.caret_cells });
        }
        try w.writeAll("\x1b[?2026l");
        try term.writeAll(frame.written());
    }
};

pub fn run(io: std.Io, a: std.mem.Allocator, db: *store.Store, label: []const u8, query: []const u8, theme: Theme, color: bool, initial_details: bool, case_sensitive: bool, choose_language: bool) !void {
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
    if (theme == .terminal) state.theme = @fromBackingInt(@intCast(@backingInt(reading.data.theme)));
    state.details = initial_details or reading.data.details;
    @memcpy(state.query[0..query.len], query);
    state.len = query.len;
    state.cursor = query.len;
    try state.changed();
    if (query.len == 0 and reading.data.last_title.len != 0) if (try db.find(reading.data.last_title)) |index| {
        state.selected = index;
        state.focus = .entry;
    };
    if (choose_language) {
        state.startup_library = true;
        try state.navigate(.library);
    }
    var session = try term.Session.enter();
    defer session.leave();
    var input: term.Input = .{};
    var dirty = true;
    var last_input = std.Io.Clock.awake.now(io).toNanoseconds();
    var running = true;
    while (running and !term.Session.shouldQuit()) {
        dirty = state.mediaPoll() or dirty;
        dirty = try state.searchStep(4096) or dirty;
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

test "terminal partial prefix results rank exact titles and preserve an explicit selection" {
    const a = std.testing.allocator;
    const titles = [_][]const u8{ "FOB", "FOOBAR", "fo", "fox", "խեղճ", "խեղճուկրակություն", "տուն" };
    var records: [titles.len]enc.blob_format.RecordInput = undefined;
    for (&records, titles) |*record, title| record.* = .{ .title = title, .payload = "" };
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &records);
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "titles", .data = bytes });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/titles", .{tmp.sub_path});
    defer a.free(path);
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .label = "Titles", .theme = .terminal, .color = false, .case_sensitive = false };
    defer state.deinit();
    try state.insert("խեղճ");
    try std.testing.expect(try state.searchStep(6));
    try std.testing.expect(state.searchPending());
    try std.testing.expectEqualStrings("խեղճ", try db.titleAt(state.recordIndex(0)));
    try std.testing.expectEqualStrings("խեղճուկրակություն", try db.titleAt(state.recordIndex(1)));
    for ([_]bool{ false, true }) |select_second| {
        _ = try state.key(.{ .key = .clear });
        try state.insert("fO");
        try std.testing.expect(try state.searchStep(2));
        try std.testing.expectEqualStrings("FOB", try db.titleAt(state.recordIndex(0)));
        if (select_second) {
            _ = try state.key(.{ .key = .down });
            _ = try state.key(.{ .key = .down });
            _ = try state.key(.{ .key = .enter });
        }
        try std.testing.expect(try state.searchStep(titles.len));
        try std.testing.expect(!state.searchPending());
        try std.testing.expectEqualStrings("fo", try db.titleAt(state.recordIndex(0)));
        try std.testing.expectEqualStrings(if (select_second) "FOOBAR" else "fo", try db.titleAt(state.recordIndex(state.selected)));
    }
}

test "terminal exact spelling leads folded peers before and after scanning" {
    const a = std.testing.allocator;
    const bytes = try enc.blob_format.buildAlloc(a, .citations, "", &.{
        .{ .title = "Aabo", .payload = "" }, .{ .title = "aabayeelid", .payload = "" }, .{ .title = "aabo", .payload = "" },
    });
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "titles", .data = bytes });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/titles", .{tmp.sub_path});
    defer a.free(path);
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .label = "Titles", .theme = .terminal, .color = false, .case_sensitive = false };
    defer state.deinit();
    try state.insert("aabo");
    try std.testing.expectEqualStrings("aabo", try db.titleAt(state.recordIndex(0)));
    try std.testing.expect(try state.searchStep(1));
    try std.testing.expect(state.searchPending());
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expectEqualStrings("aabo", try db.titleAt(state.recordIndex(0)));
    try std.testing.expectEqualStrings("Aabo", try db.titleAt(state.recordIndex(1)));
    _ = try state.key(.{ .key = .down });
    _ = try state.key(.{ .key = .down });
    try std.testing.expect(try state.searchStep(2));
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expectEqualStrings("aabo", try db.titleAt(state.recordIndex(0)));
    try std.testing.expectEqualStrings("Aabo", try db.titleAt(state.recordIndex(state.selected)));
}

test "terminal neutral redirect selection has no invented library heading" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var aliases: [2]enc.blob_format.RecordInput = undefined;
    for ([_][]const u8{ "A", "B" }, [_][]const u8{ "B", "Missing" }, 0..) |source, target, i| {
        const presentation = try enc.presentation_codec.encodeAlloc(fixture, .{ .entry = .{
            .title = source,
            .kind = .alias,
            .preamble_spans = &.{.{ .kind = .link, .text = target, .target = target }},
        } });
        aliases[i] = .{ .title = try enc.alias_codec.keyAlloc(fixture, .language, source), .payload = try enc.alias_codec.encodeAlloc(fixture, .{
            .source_namespace = 0,
            .source_kind = .language,
            .source_title = source,
            .source_key = source,
            .xml_target = target,
            .target_title = target,
            .target_namespace = 0,
            .target_kind = .language,
            .target_key = target,
            .fragment = "",
            .presentation = presentation,
        }) };
    }
    const bytes = try enc.blob_format.buildAlloc(fixture, .alias, "", &aliases);
    const path = try store.pathAlloc(fixture, root, .alias, "");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    const manifest = try std.fs.path.join(fixture, &.{ root, store.catalog.manifest_filename });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest, .data = store.catalog.manifest_header ++ "\n" });
    var db = try store.Store.open(std.testing.io, a, root, .language, "English");
    defer db.deinit();
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .label = try db.labelAlloc(a), .label_owned = true, .theme = .terminal, .color = false };
    defer state.deinit();
    try std.testing.expectEqualStrings("Redirects", state.label);
    try state.loadLibrary();
    try std.testing.expectEqual(@as(usize, 0), state.library_names.items.len);
    try state.insert("A");
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expectEqualStrings("A", try db.titleAt(state.recordIndex(0)));
    try state.prepare(80);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "Missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "English") == null);
    try std.testing.expect(db.heading() == null);
}

test "terminal empty language body distinguishes a title from entry content" {
    const title: model.Entry = .{ .kind = .language, .title = "czytać", .language = "polski", .language_code = "pl" };
    try std.testing.expect(output.emptyLanguageBody(title));
    var entry = title;
    entry.display_title = &.{.{ .text = "Czytać" }};
    try std.testing.expect(output.emptyLanguageBody(entry));
    entry.kind = .supplemental;
    try std.testing.expect(!output.emptyLanguageBody(entry));
    entry = title;
    entry.sections = &.{.{ .level = 2, .title = "wymowa" }};
    try std.testing.expect(!output.emptyLanguageBody(entry));
    entry = title;
    entry.preamble_spans = &.{.{ .text = "wstęp" }};
    try std.testing.expect(!output.emptyLanguageBody(entry));
    entry = title;
    entry.media = &.{.{ .file = "Pl-czytać.ogg", .kind = .audio, .caption = "" }};
    try std.testing.expect(!output.emptyLanguageBody(entry));
    entry = title;
    entry.references = &.{.{ .number = 1, .group_number = null, .spans = &.{.{ .text = "przypis" }} }};
    try std.testing.expect(!output.emptyLanguageBody(entry));
}

test "terminal missing structured meaning preserves body and cannot grade quiz typing or cards" {
    const a = std.testing.allocator;
    const T = enc.presentation_types;
    // Same list-item shape and Greek gloss as the retained ancient entry;
    // this controlled fixture never promotes that bullet to a definition.
    const gloss = "συνώνυμο του λέκος πιάτο, κατσαρόλα, δοχείο σαν κύπελλο";
    const bullet: T.Stored = .{ .entry = .{ .title = "bullet", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 3, .title = "Ουσιαστικό", .blocks = &.{.{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{.{ .text = gloss }} }} }} } };
    const normal: T.Stored = .{ .entry = .{ .title = "café", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 3, .title = "Noun", .blocks = &.{.{ .kind = .container, .container = .{ .blocks = &.{.{ .kind = .definition, .depth = 1, .list_path = "#", .number = "1", .spans = &.{.{ .text = "A place to drink coffee." }} }} } }} }} } };
    const bullet_payload = try enc.presentation_codec.encodeAlloc(a, bullet);
    defer a.free(bullet_payload);
    const normal_payload = try enc.presentation_codec.encodeAlloc(a, normal);
    defer a.free(normal_payload);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English");
    defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{ .{ .title = "bullet", .payload = bullet_payload }, .{ .title = "café", .payload = normal_payload } });
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "sample" });
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var reading = ReadingState.init(a);
    defer reading.deinit();
    try reading.load(std.testing.io, root, "English");
    reading.data.history_limit = 0;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "English", .theme = .terminal, .color = false, .screen = .{ .cols = 80, .rows = 32 } };
    defer state.deinit();
    for ([_]usize{ 36, 76, 116 }) |width| {
        for (0..2) |game| {
            state.game = if (game == 0) .quiz else .scramble;
            state.details = false;
            try state.navigate(.learn);
            state.selected = (try db.find("bullet")).?;
            // Direct grading is refused even before the first paint.
            try state.answer(true);
            try state.answer(false);
            try state.prepare(width);
            try std.testing.expect(std.mem.indexOf(u8, state.text, "No structured meaning") != null);
            try std.testing.expect(std.mem.indexOf(u8, state.text, "6  ") == null);
            try std.testing.expect(std.mem.indexOf(u8, state.text, "Your answer:") == null);
            _ = try state.key(.{ .key = .text, .bytes = .{ '6', 0, 0, 0 }, .len = 1 });
            _ = try state.key(.{ .key = .text, .bytes = .{ 0xc3, 0xa9, 0, 0 }, .len = 2, .pasted = true });
            _ = try state.key(.{ .key = .enter });
            try std.testing.expectEqual(@as(usize, 0), state.answer_len);
            try std.testing.expectEqual(@as(usize, 0), state.round);
            try std.testing.expect(!state.answered);
            _ = try state.key(.{ .key = .text, .bytes = .{ 'o', 0, 0, 0 }, .len = 1 });
            try state.prepare(width);
            try std.testing.expect(std.mem.indexOf(u8, state.text, gloss) == null);
            // Ordinary Open entry honors folds; d explicitly opens supporting body.
            _ = try state.key(.{ .key = .text, .bytes = .{ 'd', 0, 0, 0 }, .len = 1 });
            try state.prepare(width);
            try std.testing.expect(std.mem.indexOf(u8, state.text, gloss) != null);
            try std.testing.expect(std.mem.indexOf(u8, state.text, "Unscored entry") != null);
            _ = try state.key(.{ .key = .enter });
            _ = try state.key(.{ .key = .text, .bytes = .{ '6', 0, 0, 0 }, .len = 1 });
            _ = try state.key(.{ .key = .text, .bytes = .{ 'c', 0, 0, 0 }, .len = 1 });
            try std.testing.expectEqualStrings("bullet", try db.titleAt(state.recordIndex(state.selected)));
            _ = try state.key(.{ .key = .text, .bytes = .{ ' ', 0, 0, 0 }, .len = 1 });
            try state.prepare(width);
            try std.testing.expect(std.mem.indexOf(u8, state.text, gloss) != null);
            _ = try state.key(.{ .key = .text, .bytes = .{ 'y', 0, 0, 0 }, .len = 1 });
            _ = try state.key(.{ .key = .text, .bytes = .{ 'n', 0, 0, 0 }, .len = 1 });
            try std.testing.expectEqual(@as(usize, 0), state.round);
            try std.testing.expectEqual(@as(usize, 0), reading.data.right);
            try std.testing.expectEqual(@as(usize, 0), reading.data.wrong);
        }
    }
    // Replacing the selected record must discard the unavailable-clue cache.
    state.game = .quiz;
    try state.navigate(.learn);
    state.selected = (try db.find("café")).?;
    try state.prepare(76);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "A place to drink coffee.") != null);
    try state.answer(true);
    try state.answer(true);
    try std.testing.expectEqual(@as(usize, 1), reading.data.right);
    state.game = .scramble;
    try state.navigate(.learn);
    state.selected = (try db.find("café")).?;
    for ([_]term.Event{
        .{ .key = .text, .bytes = .{ 'c', 0, 0, 0 }, .len = 1 },
        .{ .key = .text, .bytes = .{ 'a', 0, 0, 0 }, .len = 1 },
        .{ .key = .text, .bytes = .{ 'f', 0, 0, 0 }, .len = 1 },
        .{ .key = .text, .bytes = .{ 0xc3, 0xa9, 0, 0 }, .len = 2 },
        .{ .key = .enter },
    }) |event| _ = try state.key(event);
    try std.testing.expect(state.answered);
    try std.testing.expectEqual(@as(usize, 2), reading.data.right);
    state.nextCard();
    state.selected = (try db.find("café")).?;
    _ = try state.key(.{ .key = .enter });
    try std.testing.expectEqual(@as(usize, 1), reading.data.wrong);
    var restored = ReadingState.init(a);
    defer restored.deinit();
    try restored.load(std.testing.io, root, "English");
    try std.testing.expectEqual(@as(usize, 2), restored.data.right);
    try std.testing.expectEqual(@as(usize, 1), restored.data.wrong);
    var original = try db.recordAlloc(a, (try db.find("bullet")).?);
    defer original.deinit();
    var doc = try model.fromRecord(a, original.record);
    defer doc.deinit();
    try std.testing.expect((try studyMeaning(doc.entry)) == null);
    try std.testing.expectEqual(T.BlockKind.list_item, doc.entry.sections[0].blocks[0].kind);
    try std.testing.expectEqualStrings(gloss, doc.entry.sections[0].blocks[0].spans[0].text);
    const roundtrip = try enc.presentation_codec.encodeAlloc(a, .{ .entry = doc.entry });
    defer a.free(roundtrip);
    try std.testing.expectEqualSlices(u8, bullet_payload, roundtrip);
}

test "terminal query editing is bounded and UTF8-aware" {
    const dec = @import("blob_decoder");
    const a = std.testing.allocator;
    const stored: enc.presentation_types.Stored = .{ .entry = .{ .title = "café", .kind = .citations, .sections = &.{.{ .level = 2, .title = "Meaning", .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .text = "A place to drink coffee." }} }} }} } };
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

    // Opening an already formatted preview must persist just like Enter.
    for ([_]term.Key{ .tab, .right }) |key| {
        for ([_]usize{ 36, 50, 92 }) |width| {
            for ([_]usize{ 0, 1000 }) |history_limit| {
                const label = try std.fmt.allocPrint(a, "focus-{s}-{d}-{d}", .{ @tagName(key), width, history_limit });
                defer a.free(label);
                const root = std.fs.path.dirname(path).?;
                var focused_reading = ReadingState.init(a);
                defer focused_reading.deinit();
                try focused_reading.load(std.testing.io, root, label);
                focused_reading.data.history_limit = history_limit;
                var focused: State = .{
                    .io = std.testing.io,
                    .a = a,
                    .db = &db,
                    .reading = &focused_reading,
                    .label = label,
                    .theme = .terminal,
                    .color = false,
                    .focus = .matches,
                    .range = .{ .start = 0, .end = db.count() },
                };
                defer focused.deinit();
                try focused.prepare(width);
                const preview = focused.text.ptr;
                try std.testing.expectEqual(@as(usize, 0), focused_reading.data.history.len);
                try std.testing.expectEqualStrings("", focused_reading.data.last_title);
                _ = try focused.key(.{ .key = key });
                try focused.prepare(width);
                try std.testing.expectEqual(Focus.entry, focused.focus);
                try std.testing.expect(focused.text.ptr == preview);
                _ = try focused.key(.{ .key = .escape });
                _ = try focused.key(.{ .key = .escape });
                try std.testing.expectEqual(Focus.search, focused.focus);
                var restored_focus = ReadingState.init(a);
                defer restored_focus.deinit();
                try restored_focus.load(std.testing.io, root, label);
                try std.testing.expectEqualStrings("café", restored_focus.data.last_title);
                try std.testing.expectEqual(@as(usize, if (history_limit == 0) 0 else 1), restored_focus.data.history.len);
                if (history_limit != 0) try std.testing.expectEqualStrings("café", restored_focus.data.history[0]);
            }
        }
    }

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
    try std.testing.expectEqual(@backingInt(state.theme), @backingInt(reading.data.theme));
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
    _ = try state.searchStep(4096);
    try std.testing.expect(!state.searchPending());
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expectEqualStrings("café", try state.db.titleAt(state.recordIndex(0)));
    _ = try state.key(.{ .key = .clear });
    try state.insert("missing");
    _ = try state.searchStep(4096);
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

test "terminal redirected reading preserves selected identity in history saved and resume" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(fixture, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const Fixture = struct {
        fn write(alloc: std.mem.Allocator, directory: []const u8, kind: store.Kind, records: []const enc.blob_format.RecordInput) !void {
            const metadata = if (kind == .language) try enc.blob_format.buildLanguageMetadataAlloc(alloc, "en", "English") else "";
            const bytes = try enc.blob_format.buildAlloc(alloc, kind, metadata, records);
            const path = try store.pathAlloc(alloc, directory, kind, if (kind == .language) "English" else "");
            try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
        }
        fn payload(alloc: std.mem.Allocator, kind: store.Kind, title: []const u8, body: []const u8) ![]const u8 {
            return enc.presentation_codec.encodeAlloc(alloc, .{ .entry = .{
                .title = title,
                .kind = kind,
                .language = if (kind == .language) "English" else null,
                .language_code = if (kind == .language) "en" else "",
                .sections = &.{.{ .level = 2, .title = "Entry", .blocks = &.{.{
                    .kind = .definition,
                    .spans = &.{.{ .text = body }},
                }} }},
            } });
        }
    };
    try Fixture.write(fixture, root, .language, &.{.{
        .title = "cat",
        .payload = try Fixture.payload(fixture, .language, "cat", "ordinary redirect body"),
    }});
    try Fixture.write(fixture, root, .thesaurus, &.{.{
        .title = "animal",
        .payload = try Fixture.payload(fixture, .thesaurus, "animal", "feature redirect body"),
    }});
    const sources = [_][]const u8{ "Alpha", "Feature" };
    const targets = [_][]const u8{ "cat", "Thesaurus:animal" };
    const displayed = [_][]const u8{ "cat", "animal" };
    const bodies = [_][]const u8{ "ordinary redirect body", "feature redirect body" };
    var aliases: [3]enc.blob_format.RecordInput = undefined;
    for (sources, targets, 0..) |source, target, i| {
        const feature = i == 1;
        aliases[i] = .{
            .title = try enc.alias_codec.keyAlloc(fixture, .language, source),
            .payload = try enc.alias_codec.encodeAlloc(fixture, .{
                .source_namespace = 0,
                .source_kind = .language,
                .source_title = source,
                .source_key = source,
                .xml_target = target,
                .target_title = target,
                .target_namespace = if (feature) 110 else 0,
                .target_kind = if (feature) .thesaurus else .language,
                .target_key = displayed[i],
                .fragment = "",
                .presentation = try Fixture.payload(fixture, .alias, source, "compiled redirect"),
            }),
        };
    }
    aliases[2] = .{
        .title = try enc.alias_codec.keyAlloc(fixture, .thesaurus, "Old"),
        .payload = try enc.alias_codec.encodeAlloc(fixture, .{
            .source_namespace = 110,
            .source_kind = .thesaurus,
            .source_title = "Thesaurus:Old",
            .source_key = "Old",
            .xml_target = "Thesaurus:animal",
            .target_title = "Thesaurus:animal",
            .target_namespace = 110,
            .target_kind = .thesaurus,
            .target_key = "animal",
            .fragment = "",
            .presentation = try Fixture.payload(fixture, .alias, "Thesaurus:Old", "compiled feature redirect"),
        }),
    };
    std.mem.sort(enc.blob_format.RecordInput, &aliases, {}, struct {
        fn less(_: void, left: enc.blob_format.RecordInput, right: enc.blob_format.RecordInput) bool {
            return std.mem.order(u8, left.title, right.title) == .lt;
        }
    }.less);
    try Fixture.write(fixture, root, .alias, &aliases);
    var db = try store.Store.open(std.testing.io, a, root, .language, "English");
    defer db.deinit();
    const label = try db.labelAlloc(fixture);
    var reading = ReadingState.init(a);
    defer reading.deinit();
    try reading.load(std.testing.io, root, label);
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = label, .theme = .terminal, .color = false, .details = true };
    defer state.deinit();
    for (sources, displayed, bodies, 0..) |source, target, body, n| {
        _ = try state.key(.{ .key = .clear });
        try state.insert(source);
        _ = try state.key(.{ .key = .enter });
        try state.prepare(80);
        try std.testing.expectEqualStrings(source, reading.data.last_title);
        try std.testing.expectEqual(n + 1, reading.data.history.len);
        try std.testing.expectEqualStrings(source, reading.data.history[0]);
        try std.testing.expect(!ReadingState.contains(reading.data.history, target));
        try std.testing.expect(std.mem.indexOf(u8, state.text, body) != null);
        var raw = try db.recordAlloc(a, state.recordIndex(state.selected));
        defer raw.deinit();
        var doc = try model.fromRecord(a, raw.record);
        defer doc.deinit();
        try std.testing.expectEqualStrings(target, doc.entry.title);
        try std.testing.expectEqualStrings(source, doc.entry.redirect.?.source_title);
        try std.testing.expect(doc.entry.redirect.?.followed);
        // Saving and reopening retain the same source selection as History.
        _ = try state.key(.{ .key = .text, .bytes = .{ 's', 0, 0, 0 }, .len = 1 });
        try std.testing.expect(ReadingState.contains(reading.data.saved, source));
        try std.testing.expect(!ReadingState.contains(reading.data.saved, target));
        try state.navigate(.saved);
        _ = try state.key(.{ .key = .enter });
        try state.prepare(80);
        try std.testing.expectEqualStrings(source, try db.titleAt(state.recordIndex(state.selected)));
        try std.testing.expectEqualStrings(source, reading.data.last_title);
        try state.navigate(.history);
        _ = try state.key(.{ .key = .enter });
        try state.prepare(80);
        try std.testing.expectEqualStrings(source, try db.titleAt(state.recordIndex(state.selected)));
        try std.testing.expectEqual(n + 1, reading.data.history.len);
    }
    // Study the selected alias spelling while retaining the resolved definition.
    {
        var study_reading = ReadingState.init(a);
        defer study_reading.deinit();
        study_reading.data.study_pool = .saved;
        for (sources) |source| try study_reading.bookmark(source);
        var study: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &study_reading, .label = label, .theme = .terminal, .color = false };
        defer study.deinit();
        for (sources, [_][]const u8{ "\nahplA\n", "\nerutaeF\n" }) |source, reversed| {
            study.game = .cards;
            try study.navigate(.learn);
            _ = try study.key(.{ .key = .tab });
            _ = try study.key(.{ .key = .tab });
            study.selected = std.mem.indexOfScalar(usize, study.filtered.items, (try db.find(source)).?).?;
            try study.prepare(80);
            try std.testing.expectEqualStrings(source, try db.titleAt(study.recordIndex(study.selected)));
            try std.testing.expect(std.mem.indexOf(u8, study.text, reversed) != null);
            const before_right = study_reading.data.right;
            const before_wrong = study_reading.data.wrong;
            for (source) |c| {
                _ = try study.key(.{ .key = .text, .bytes = .{ c, 0, 0, 0 }, .len = 1 });
            }
            _ = try study.key(.{ .key = .enter });
            try std.testing.expect(study.answered);
            try std.testing.expectEqual(before_right + 1, study_reading.data.right);
            try std.testing.expectEqual(before_wrong, study_reading.data.wrong);
        }
    }
    // The startup path resolves the persisted source title, not the body title.
    {
        var restored = ReadingState.init(a);
        defer restored.deinit();
        try restored.load(std.testing.io, root, label);
        try std.testing.expectEqualStrings("Feature", restored.data.last_title);
        try std.testing.expectEqual(@as(usize, 2), restored.data.history.len);
        try std.testing.expectEqualStrings("Feature", restored.data.history[0]);
        try std.testing.expectEqualStrings("Alpha", restored.data.history[1]);
        var resumed: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &restored, .label = label, .theme = .terminal, .color = false, .details = true };
        defer resumed.deinit();
        try resumed.changed();
        resumed.selected = (try db.find(restored.data.last_title)).?;
        resumed.focus = .entry;
        try resumed.prepare(40);
        try std.testing.expectEqualStrings("Feature", restored.data.last_title);
        try std.testing.expectEqual(@as(usize, 2), restored.data.history.len);
        try std.testing.expect(std.mem.indexOf(u8, resumed.text, "feature redirect body") != null);
    }
    // Disabling new history still keeps the selected source as the resume title.
    reading.data.history_limit = 0;
    _ = try state.key(.{ .key = .clear });
    try state.insert("Alpha");
    _ = try state.key(.{ .key = .enter });
    try state.prepare(40);
    try std.testing.expectEqualStrings("Alpha", reading.data.last_title);
    try std.testing.expectEqual(@as(usize, 2), reading.data.history.len);
    try std.testing.expectEqualStrings("Feature", reading.data.history[0]);
    // A feature dictionary stores its local navigation key, not the XML namespace spelling.
    {
        var feature_db = try store.Store.open(std.testing.io, a, root, .thesaurus, "");
        defer feature_db.deinit();
        const feature_label = try feature_db.labelAlloc(fixture);
        var feature_reading = ReadingState.init(a);
        defer feature_reading.deinit();
        try feature_reading.load(std.testing.io, root, feature_label);
        var feature_state: State = .{ .io = std.testing.io, .a = a, .db = &feature_db, .reading = &feature_reading, .label = feature_label, .theme = .terminal, .color = false, .details = true };
        defer feature_state.deinit();
        try feature_state.insert("Old");
        _ = try feature_state.key(.{ .key = .enter });
        try feature_state.prepare(80);
        try std.testing.expectEqualStrings("Old", feature_reading.data.last_title);
        try std.testing.expectEqual(@as(usize, 1), feature_reading.data.history.len);
        try std.testing.expectEqualStrings("Old", feature_reading.data.history[0]);
        try std.testing.expect(!ReadingState.contains(feature_reading.data.history, "animal"));
        try std.testing.expect(!ReadingState.contains(feature_reading.data.history, "Thesaurus:Old"));
        try std.testing.expect(std.mem.indexOf(u8, feature_state.text, "feature redirect body") != null);
        _ = try feature_state.key(.{ .key = .text, .bytes = .{ 's', 0, 0, 0 }, .len = 1 });
        try std.testing.expect(ReadingState.contains(feature_reading.data.saved, "Old"));
        var feature_restored = ReadingState.init(a);
        defer feature_restored.deinit();
        try feature_restored.load(std.testing.io, root, feature_label);
        try std.testing.expectEqualStrings("Old", feature_restored.data.last_title);
        try std.testing.expect((try feature_db.find(feature_restored.data.last_title)) != null);
        try std.testing.expectEqual(@as(usize, 1), feature_restored.data.history.len);
    }
}

test "terminal table resize preserves folds scroll and disabled history state" {
    const a = std.testing.allocator;
    const types = enc.presentation_types;
    const title = "እንኳን ወደ ዊኪ መዝገበ ቃላት በደህና መጡ";
    const header = [_]types.Cell{.{ .header = true, .spans = &.{.{ .text = "translation" }} }};
    const french = [_]types.Cell{.{ .spans = &.{ .{ .text = "French : " }, .{ .kind = .link, .text = "Bienvenue sur le Wiktionnaire", .target = "Bienvenue sur le Wiktionnaire" } } }};
    const greek = [_]types.Cell{.{ .spans = &.{ .{ .text = "greek : " }, .{ .kind = .link, .text = "καλωσορίσατε στο Βικιλεξικό", .target = "καλωσορίσατε στο Βικιλεξικό" }, .{ .text = "!" } } }};
    const rows = [_]types.Row{ .{ .cells = &header }, .{ .cells = &french }, .{ .cells = &greek } };
    const sections = [_]model.Section{
        .{ .level = 3, .title = "Pronunciation", .blocks = &.{.{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{ .{ .text = "IPA" }, .{ .text = "(", .superscript = true }, .{ .kind = .external_link, .text = "am", .target = "https://en.wikipedia.org/wiki/Amharic#Phonology", .superscript = true }, .{ .text = ")", .superscript = true } } }} },
        .{ .level = 3, .title = "ትርጉም", .blocks = &.{.{ .kind = .table, .table = .{ .rows = &rows } }} },
    };
    const payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = title, .kind = .language, .language = "አማርኛ", .language_code = "am", .sections = &sections } });
    defer a.free(payload);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "am", "አማርኛ");
    defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = title, .payload = payload }});
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/sample", .{root});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var reading = ReadingState.init(a);
    defer reading.deinit();
    try reading.load(std.testing.io, root, "አማርኛ");
    reading.data.history_limit = 0;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "አማርኛ", .theme = .terminal, .color = true, .details = true, .focus = .entry, .screen = .{ .cols = 40, .rows = 10 } };
    defer state.deinit();
    try state.changed();
    try state.prepare(36);
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
    try std.testing.expectEqualStrings(title, reading.data.last_title);
    // Fold one section before the resize baseline; keep the table expanded.
    try state.expanded.append(a, 0);
    state.section = 1;
    state.loaded = null;
    try state.prepare(36);
    const initial = try a.dupe(u8, state.text);
    defer a.free(initial);
    const saved_path_address = @intFromPtr(reading.path.ptr);
    const persisted = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, reading.path, a, .limited(1024 * 1024));
    defer a.free(persisted);
    state.scroll = 3;
    for ([_]usize{ 50, 80, 36 }) |width| {
        const old_scroll = state.scroll;
        try state.prepare(width);
        try std.testing.expectEqual(width, state.format_width);
        try std.testing.expectEqual(@min(old_scroll, state.rows.len -| state.bodyHeight()), state.scroll);
        try std.testing.expect(state.scroll != 0);
        try std.testing.expectEqual(@as(usize, 1), state.section);
        try std.testing.expectEqualSlices(usize, &.{0}, state.expanded.items);
        try std.testing.expectEqual(@as(usize, 0), state.selected);
        try std.testing.expectEqual(saved_path_address, @intFromPtr(reading.path.ptr));
        try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
        try std.testing.expectEqualStrings(title, reading.data.last_title);
        if (width >= 44) try std.testing.expect(std.mem.indexOf(u8, state.text, "Bienvenue sur le Wiktionnaire") != null);
    }
    try std.testing.expectEqualStrings(initial, state.text);
    // A taller terminal changes the scroll limit even when width and cached
    // formatted rows are unchanged. Reuse this entry and preserve its state.
    const text_address = @intFromPtr(state.text.ptr);
    const rows_address = @intFromPtr(state.rows.ptr);
    const previous_height = state.screen.rows;
    state.scroll = state.rows.len -| state.bodyHeight();
    try std.testing.expect(state.scroll > 0);
    state.screen.rows = @max(12, state.rows.len + 8);
    try state.prepare(36);
    try std.testing.expectEqual(@as(usize, 0), state.scroll);
    try std.testing.expectEqual(text_address, @intFromPtr(state.text.ptr));
    try std.testing.expectEqual(rows_address, @intFromPtr(state.rows.ptr));
    try std.testing.expectEqual(@as(usize, 36), state.format_width);
    try std.testing.expectEqual(@as(usize, 1), state.section);
    try std.testing.expectEqualSlices(usize, &.{0}, state.expanded.items);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectEqual(saved_path_address, @intFromPtr(reading.path.ptr));
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
    try std.testing.expectEqualStrings(title, reading.data.last_title);
    state.screen.rows = previous_height;
    try state.prepare(36);
    try std.testing.expectEqual(@as(usize, 0), state.scroll);
    try std.testing.expectEqualStrings(initial, state.text);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, reading.path, a, .limited(1024 * 1024));
    defer a.free(after);
    try std.testing.expectEqualStrings(persisted, after);
}

test "query viewport measures escaped controls while retaining raw clusters" {
    term.initLocale();
    const a = std.testing.allocator;
    const query = "a\u{9b}b";
    for ([_]usize{ 40, 80 }) |columns| {
        const view = try queryDisplay(a, query, query.len, columns - 15);
        defer a.free(view.text);
        try std.testing.expectEqualStrings("a\\u{9b}b", view.text);
        try std.testing.expectEqual(@as(usize, 8), view.caret_cells);
        const home = try queryDisplay(a, query, 0, columns - 15);
        defer a.free(home.text);
        try std.testing.expectEqualStrings("a\\u{9b}b", home.text);
        try std.testing.expectEqual(@as(usize, 0), home.caret_cells);
    }
    const narrow_query = "\u{9b}\u{9b}\u{9b}\u{9b}x";
    const narrow = try queryDisplay(a, narrow_query, narrow_query.len, 40 - 15);
    defer a.free(narrow.text);
    try std.testing.expectEqualStrings("\\u{9b}\\u{9b}\\u{9b}x", narrow.text);
    try std.testing.expectEqual(@as(usize, 19), narrow.caret_cells);
    const wide_query = "\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}\u{9b}x";
    const wide = try queryDisplay(a, wide_query, wide_query.len, 80 - 15);
    defer a.free(wide.text);
    try std.testing.expectEqualStrings("\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}\\u{9b}x", wide.text);
    try std.testing.expectEqual(@as(usize, 61), wide.caret_cells);
    // The combining accent stays with its original control-containing cluster;
    // the viewport never starts inside either the escape spelling or the mark.
    const combined = "e\u{301}\u{9b}\u{301}x";
    const combined_view = try queryDisplay(a, combined, combined.len, 7);
    defer a.free(combined_view.text);
    try std.testing.expectEqualStrings("x", combined_view.text);
    try std.testing.expectEqual(@as(usize, 1), combined_view.caret_cells);
    const middle = try queryDisplay(a, query, 3, 25);
    defer a.free(middle.text);
    try std.testing.expectEqualStrings("a\\u{9b}b", middle.text);
    try std.testing.expectEqual(@as(usize, 7), middle.caret_cells);
}


test "terminal cross section float preserves actual section jumps resize folds record and media routes" {
    const a = std.testing.allocator;
    const types = enc.presentation_types;
    const rows = [_]types.Row{
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_A" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_B" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_C" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_D" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_E" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_F" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_G" }} }} },
        .{ .cells = &.{.{ .spans = &.{.{ .text = "FLOAT_H" }} }} },
    };
    const sections = [_]model.Section{
        .{ .level = 2, .title = "Poloniera", .blocks = &.{.{ .kind = .table, .table = .{
            .rows = &rows, .geometry = .{ .width = .{ .unit = .px, .value = 250 } },
            .style = .{ .float_side = .right, .margins = .{ .top = .{ .unit = .px, .value = 0 }, .right = .{ .unit = .px, .value = 0 }, .bottom = .{ .unit = .px, .value = 0 }, .left = .{ .unit = .px, .value = 20 } } },
        } }} },
        .{ .level = 3, .title = "Ahoskera", .blocks = &.{
            .{ .kind = .list_item, .depth = 2, .list_path = ":*", .spans = &.{.{ .text = "AHO_A" }} },
            .{ .kind = .list_item, .depth = 2, .list_path = ":*", .spans = &.{.{ .text = "AHO_B" }} },
        } },
        .{ .level = 3, .title = "Adjektiboa", .blocks = &.{
            .{ .kind = .indent, .depth = 1, .list_path = ":", .spans = &.{.{ .text = "ADJ_I" }} },
            .{ .kind = .list_item, .depth = 2, .list_path = ":#", .spans = &.{.{ .text = "ADJ_L" }} },
        } },
    };
    // Synthetic source-derived shape, not the pending genuine E Reader artifact.
    const payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "dwa", .kind = .language, .language = "poloniera", .language_code = "pl", .sections = &sections, .media = &.{.{ .file = "Icon.svg", .kind = .image, .caption = "" }} } });
    defer a.free(payload);
    const other = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "another", .kind = .language, .language = "poloniera", .language_code = "pl", .sections = &.{.{ .level = 2, .title = "Other", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "OTHER_RECORD" }} }} }} } });
    defer a.free(other);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "pl", "poloniera");
    defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{ .{ .title = "another", .payload = other }, .{ .title = "dwa", .payload = payload } });
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/sample", .{root});
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var reading = ReadingState.init(a);
    defer reading.deinit();
    try reading.load(std.testing.io, root, "poloniera");
    reading.data.history_limit = 0;
    reading.data.allow_images = false;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "poloniera", .theme = .terminal, .color = true, .details = true, .screen = .{ .cols = 56, .rows = 20 } };
    defer state.deinit();
    try state.changed();
    state.selected = (try db.find("dwa")).?;
    state.focus = .entry;
    try state.prepare(52);
    try std.testing.expect(state.row_origins.len != 0 and state.visual_text.len != 0);
    try std.testing.expectEqual(@as(usize, 0), state.float_unsupported);
    _ = try state.key(.{ .key = .text, .bytes = .{ ']', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expectEqual(@as(usize, 1), state.section);
    const expected_row = output.flowRowForOffset(state.row_origins, state.section_offset);
    try std.testing.expectEqual(@min(expected_row, state.rows.len -| state.bodyHeight()), state.scroll);
    try std.testing.expect(std.mem.indexOf(u8, state.rows[expected_row].bytes, "Ahoskera") != null);
    state.scroll = 2;
    state.screen.cols = 40;
    try state.prepare(36);
    try std.testing.expectEqual(@as(usize, 1), state.float_unsupported);
    try std.testing.expectEqual(@min(@as(usize, 2), state.rows.len -| state.bodyHeight()), state.scroll);
    state.screen.cols = 56;
    try state.prepare(52);
    try std.testing.expectEqual(@as(usize, 0), state.float_unsupported);
    state.section = 0;
    _ = try state.key(.{ .key = .text, .bytes = .{ 'e', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "FLOAT_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "[+]") != null);
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
    _ = try state.key(.{ .key = .text, .bytes = .{ 'm', 0, 0, 0 }, .len = 1 });
    try std.testing.expectEqual(@as(usize, 1), state.media_index);
    try std.testing.expectEqualStrings("Enable online images/audio in Settings first.", state.notice);
    state.focus = .matches;
    _ = try state.key(.{ .key = .up });
    _ = try state.key(.{ .key = .enter });
    try state.prepare(52);
    try std.testing.expectEqualStrings("another", try db.titleAt(state.recordIndex(state.selected)));
    try std.testing.expect(state.visual_text.len == 0 and state.row_origins.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "OTHER_RECORD") != null);
}

test "terminal nested container keeps section fold keyboard resize and record navigation" {
    const a = std.testing.allocator;
    const sections = [_]model.Section{
        .{ .level = 2, .title = "Nested", .blocks = &.{.{ .kind = .container, .container = .{ .style = .{ .padding = enc.presentation_types.StyleEdges.all(.{ .unit = .px, .value = 8 }), .width = .{ .length = .{ .unit = .percent, .value = 80 } } }, .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "BOX_LINK", .target = "another" }} },
            .{ .kind = .container, .container = .{ .style = .{}, .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .text = "BOX_DEFINITION full retained body" }} }} } },
        } } }} },
        .{ .level = 3, .title = "Following", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "AFTER_BOX" }} }} },
    };
    const payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "boxes", .kind = .language, .language = "English", .language_code = "en", .sections = &sections } });
    defer a.free(payload);
    const other = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "another", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 2, .title = "Other", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "OTHER_RECORD" }} }} }} } });
    defer a.free(other);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English"); defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{ .{ .title = "another", .payload = other }, .{ .title = "boxes", .payload = payload } }); defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/sample", .{root}); defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a }; defer db.file.deinit();
    var reading = ReadingState.init(a); defer reading.deinit();
    try reading.load(std.testing.io, root, "English");
    reading.data.history_limit = 0;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "English", .theme = .terminal, .color = true, .details = true, .screen = .{ .cols = 56, .rows = 12 } }; defer state.deinit();
    try state.changed();
    state.selected = (try db.find("boxes")) orelse return error.TestUnexpectedResult;
    state.focus = .entry;
    try state.prepare(52);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_LINK") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_DEFINITION") != null);
    _ = try state.key(.{ .key = .text, .bytes = .{ ']', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expectEqual(@as(usize, 1), state.section);
    state.screen.cols = 14;
    try state.prepare(10);
    for (state.rows) |row| try std.testing.expect(term.cellWidth(row.bytes) + row.left + row.right <= 10);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "AFTER_BOX") != null);
    state.section = 0;
    _ = try state.key(.{ .key = .text, .bytes = .{ 'e', 0, 0, 0 }, .len = 1 });
    try state.prepare(10);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_LINK") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "[+]") != null);
    state.focus = .matches;
    _ = try state.key(.{ .key = .up });
    _ = try state.key(.{ .key = .enter });
    try state.prepare(10);
    try std.testing.expectEqualStrings("another", try db.titleAt(state.recordIndex(state.selected)));
    try std.testing.expect(std.mem.indexOf(u8, state.text, "OTHER_RECORD") != null);
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
}

test "terminal typed flex preserves theme keyboard reflow folds actions and record navigation" {
    const a = std.testing.allocator;
    const sections = [_]model.Section{
        .{ .level = 2, .title = "Nested", .blocks = &.{.{ .kind = .container, .container = .{ .style = .{
            .layout = .flex_row, .align_items = .center,
            .width = .{ .length = .{ .unit = .px, .value = 240 } },
            .background = .{ .light_dark = .{ .light = "#abcdef", .dark = "#123456" } },
            .screen_max_width = .{ .max_width_px = 719, .width = .{ .length = .{ .unit = .percent, .value = 100 } }, .box_sizing = .border_box },
        }, .blocks = &.{
            .{ .kind = .container, .container = .{ .style = .{ .flex_item = .none }, .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .kind = .link, .text = "BOX_LINK", .target = "another" }} }} } },
            .{ .kind = .container, .container = .{ .style = .{}, .blocks = &.{.{ .kind = .definition, .spans = &.{.{ .text = "BOX_DEFINITION full retained body" }} }} } },
        } } }} },
        .{ .level = 3, .title = "Following", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "AFTER_BOX" }} }} },
    };
    const payload = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "boxes", .kind = .language, .language = "English", .language_code = "en", .sections = &sections } });
    defer a.free(payload);
    const other = try enc.presentation_codec.encodeAlloc(a, .{ .entry = .{ .title = "another", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 2, .title = "Other", .blocks = &.{.{ .kind = .paragraph, .spans = &.{.{ .text = "OTHER_RECORD" }} }} }} } });
    defer a.free(other);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English"); defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{ .{ .title = "another", .payload = other }, .{ .title = "boxes", .payload = payload } }); defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/sample", .{root}); defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a }; defer db.file.deinit();
    var reading = ReadingState.init(a); defer reading.deinit();
    try reading.load(std.testing.io, root, "English");
    reading.data.history_limit = 0;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "English", .theme = .terminal, .color = true, .details = true, .screen = .{ .cols = 56, .rows = 12 } }; defer state.deinit();
    try state.changed();
    state.selected = (try db.find("boxes")) orelse return error.TestUnexpectedResult;
    state.focus = .entry;
    try state.prepare(52);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_LINK") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_DEFINITION") != null);
    try std.testing.expect(state.float_unsupported > 0);
    _ = try state.key(.{ .key = .text, .bytes = .{ 't', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expect(state.theme == .dark and state.format_theme.? == .dark);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "48;2;18;52;86m") != null);
    // Theme change must invalidate the formatted container paint at the same width.
    _ = try state.key(.{ .key = .text, .bytes = .{ 't', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expect(state.theme == .light and state.format_theme.? == .light);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "48;2;171;205;239m") != null);

    _ = try state.key(.{ .key = .text, .bytes = .{ ']', 0, 0, 0 }, .len = 1 });
    try state.prepare(52);
    try std.testing.expectEqual(@as(usize, 1), state.section);
    state.screen.cols = 14;
    try state.prepare(10);
    for (state.rows) |row| try std.testing.expect(term.cellWidth(row.bytes) + row.left + row.right <= 10);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "AFTER_BOX") != null);
    state.section = 0;
    _ = try state.key(.{ .key = .text, .bytes = .{ 'e', 0, 0, 0 }, .len = 1 });
    try state.prepare(10);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "BOX_LINK") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.text, "[+]") != null);
    state.focus = .matches;
    _ = try state.key(.{ .key = .up });
    _ = try state.key(.{ .key = .enter });
    try state.prepare(10);
    try std.testing.expectEqualStrings("another", try db.titleAt(state.recordIndex(state.selected)));
    try std.testing.expect(std.mem.indexOf(u8, state.text, "OTHER_RECORD") != null);
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
}


test "M terminal poster preflight preserves reading and File action without starting media or cache work" {
    const a = std.testing.allocator; const T = enc.presentation_types;
    const image: model.Span = .{ .kind = .link, .target = "File:Model.stl", .image = .{ .file = "Model.stl", .width_px = 4, .height_px = 3,
        .static_poster = .{ .policy = .three_d_stl_v1, .label = "3D model", .file_sha1 = "0000000000000000000000000000000000000000", .file_timestamp = "2026-10-01T00:00:00Z" } } };
    const entry: model.Entry = .{ .title = "poster", .kind = .language, .language = "English", .language_code = "en", .sections = &.{.{ .level = 2, .title = "English", .blocks = &.{
        .{ .kind = .container, .container = .{ .style = .{ .height = .{ .unit = .px, .value = 0 }, .owner_font_scale = 0.9 }, .blocks = &.{
            .{ .kind = .paragraph, .spans = &.{.{ .text = "VISIBLE_BODY " }, image} },
        } } },
    } }} , .media = &.{.{ .file = "Model.stl", .kind = .image, .caption = "original model" }} };
    const encoded = try enc.presentation_codec.encodeAlloc(a, .{ .entry = entry }); defer a.free(encoded);
    try std.testing.expectEqualStrings(enc.presentation_codec.container_fonts_magic, encoded[0..4]);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, "en", "English"); defer a.free(metadata);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = "poster", .payload = encoded }}); defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/sample", .{root}); defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a }; defer db.file.deinit();
    var reading = ReadingState.init(a); defer reading.deinit(); try reading.load(std.testing.io, root, "English");
    reading.data.history_limit = 0;
    // Even a broken poster guard cannot start a network request in this test:
    // the ordinary media branch remains disabled independently.
    reading.data.allow_images = false;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = "English", .theme = .terminal, .color = false, .details = true, .screen = .{ .cols = 56, .rows = 20 } };
    defer state.deinit(); try state.changed(); state.selected = (try db.find("poster")).?; state.focus = .entry;
    try state.prepare(52);
    for ([_][]const u8{ "layout unavailable", "VISIBLE_BODY", "3D model" }) |needle| try std.testing.expect(std.mem.indexOf(u8, state.text, needle) != null);
    try std.testing.expect(state.float_unsupported != 0);
    try state.mediaAction(false);
    try std.testing.expectEqualStrings("3D preview unavailable here; its text label and File action are retained.", state.notice);
    try std.testing.expectEqual(@as(usize, 1), state.media_index);
    try std.testing.expect(state.media_job.kind() == null);
    try std.testing.expectEqual(@as(usize, 0), reading.data.history.len);
    var record = try db.recordAlloc(a, state.recordIndex(state.selected)); defer record.deinit();
    var document = try model.fromRecord(a, record.record); defer document.deinit();
    try std.testing.expect(try output.mediaRequiresPoster(document.entry, "Model.stl"));
    const restored: T.Entry = document.entry;
    try std.testing.expectEqualStrings("File:Model.stl", restored.sections[0].blocks[0].container.?.blocks[0].spans[1].target);
    try std.testing.expectEqualStrings("3D model", restored.sections[0].blocks[0].container.?.blocks[0].spans[1].image.?.static_poster.?.label);
    try std.testing.expectEqual(@as(f32, 0), restored.sections[0].blocks[0].container.?.style.height.?.value);
}


test "terminal study follows validated organized sense addresses and preserves unstructured refusal" {
    const T = enc.presentation_types;
    const marked: T.Block = .{ .kind = .list_item, .depth = 1, .list_path = "*", .spans = &.{
        .{ .kind = .link, .text = "συνώνυμο", .target = "συνώνυμο", .italic = true },
        .{ .text = " του ", .italic = true },
        .{ .kind = .link, .text = "λέκος", .target = "λέκος#Αρχαία ελληνικά (grc)", .bold = true },
        .{ .text = " πιάτο, κατσαρόλα, δοχείο σαν κύπελλο" },
    } };
    const blocks = [_]T.Block{
        .{ .kind = .definition, .spans = &.{.{ .text = "Unselected ordinary definition" }} },
        .{ .kind = .container, .container = .{ .blocks = &.{marked} } },
    };
    const entry: T.Entry = .{ .title = "λεκάνη", .kind = .language, .language = "Αρχαία Ελληνικά", .language_code = "grc",
        .sections = &.{.{ .level = 3, .title = "Ουσιαστικό", .blocks = &blocks }},
        .organization = .{ .lexemes = &.{.{ .language = "Αρχαία Ελληνικά", .kind = "Noun", .section = 0,
            .definitions = &.{.{ .block = 1, .block_path = &.{0} }}, .other_blocks = &.{0} }} },
    };
    const payload = try enc.presentation_codec.encodeAlloc(std.testing.allocator, .{ .entry = entry });
    defer std.testing.allocator.free(payload);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const decoded = try enc.presentation_codec.decodeAlloc(arena.allocator(), payload, entry.title, .language, .{ .heading = entry.language.?, .code = "grc" });
    try std.testing.expectEqualDeep(marked, (try studyMeaning(decoded.entry)).?);
    try std.testing.expectEqualDeep(entry, decoded.entry);
    var changed = entry;
    changed.organization = .{};
    try std.testing.expectEqualDeep(blocks[0], (try studyMeaning(changed)).?);
    changed.sections = &.{.{ .level = 3, .title = "Ουσιαστικό", .blocks = &.{marked} }};
    try std.testing.expect((try studyMeaning(changed)) == null);
    changed = entry;
    changed.organization = .{ .lexemes = &.{.{ .language = "Αρχαία Ελληνικά", .kind = "Noun", .section = 0 }} };
    try std.testing.expect((try studyMeaning(changed)) == null);
    for (0..4) |mode| {
        var senses = [_]T.Sense{.{ .block = 1, .block_path = &.{0} }, .{ .block = 1, .block_path = &.{0} }};
        var lexical: T.Lexeme = .{ .language = "Αρχαία Ελληνικά", .kind = "Noun", .section = 0, .definitions = &senses };
        switch (mode) {
            0 => lexical.section = 9,
            1 => senses[1].block = 9,
            2 => senses[1].block_path = &.{9},
            3 => senses[1].parent = 1,
            else => unreachable,
        }
        changed = entry; changed.organization = .{ .lexemes = &.{lexical} };
        try std.testing.expectError(error.InvalidPresentation, studyMeaning(changed));
    }
}

test "terminal Learn scores compiled Greek synonym sense without rewriting the literal bullet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = "===Ουσιαστικό===\n'''λεκάνη''' ''θηλυκό''\n" ++
        "* ''[[συνώνυμο|συνώνυμο]] του '''''[[λέκος#Αρχαία ελληνικά (grc)|λέκος]]''' πιάτο, κατσαρόλα, δοχείο σαν κύπελλο\n" ++
        "*: <span style=\"background:#ffffff; color:#002000;\">''άλλες μορφές:''</span> [[λεκάνιον#Αρχαία ελληνικά (grc)|λεκάνιον]]\n";
    const document_compiler = @import("encoder").presentation_document;
    const owner: document_compiler.ClassifiedLanguage = .{ .heading = "Αρχαία Ελληνικά", .code = "grc" };
    const payload = try document_compiler.compileClassifiedWithHeadingAnchorsAlloc(a, "λεκάνη", .language,
        owner.heading, owner.code, document_compiler.MissingText.untracked(source), null, .{}, null, null, null,
        .{}, null, null, &.{}, null, &.{}, owner);
    const decoded = try enc.presentation_codec.decodeAlloc(a, payload, "λεκάνη", .language, .{ .heading = owner.heading, .code = owner.code });
    try std.testing.expectEqual(@as(usize, 1), decoded.entry.organization.lexemes[0].definitions.len);
    const clue = (try studyMeaning(decoded.entry)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(enc.presentation_types.BlockKind.list_item, clue.kind);
    try std.testing.expectEqualStrings("*", clue.list_path);
    try std.testing.expectEqualStrings("λέκος#Αρχαία ελληνικά (grc)", clue.spans[2].target);
    const metadata = try enc.blob_format.buildLanguageMetadataAlloc(a, owner.code, owner.heading);
    const bytes = try enc.blob_format.buildAlloc(a, .language, metadata, &.{.{ .title = "λεκάνη", .payload = payload }});
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ root, "sample" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    var db: store.Store = .{ .file = try @import("blob_storage").File.open(std.testing.io, a, path), .allocator = a };
    defer db.file.deinit();
    var reading = ReadingState.init(a); defer reading.deinit();
    try reading.load(std.testing.io, root, owner.heading);
    reading.data.history_limit = 0;
    var state: State = .{ .io = std.testing.io, .a = a, .db = &db, .reading = &reading, .label = owner.heading,
        .theme = .terminal, .color = false, .screen = .{ .cols = 80, .rows = 32 } };
    defer state.deinit();
    for (0..3) |game| {
        state.game = switch (game) { 0 => .quiz, 1 => .scramble, else => .cards };
        try state.navigate(.learn);
        try state.prepare(76);
        try std.testing.expect(state.study_has_meaning);
        try std.testing.expect(std.mem.indexOf(u8, state.text, "No structured meaning") == null);
        if (game == 2) {
            try std.testing.expect(std.mem.indexOf(u8, state.text, "Recall the meaning") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, state.text, "πιάτο, κατσαρόλα, δοχείο σαν κύπελλο") != null);
        }
        const previous = reading.data.right;
        try state.answer(true);
        try state.answer(true);
        try std.testing.expectEqual(previous + 1, reading.data.right);
        try std.testing.expect(state.answered);
    }
    var record = try db.recordAlloc(a, 0); defer record.deinit();
    var document = try model.fromRecord(a, record.record); defer document.deinit();
    try std.testing.expectEqualDeep(decoded.entry, document.entry);
    try std.testing.expectEqualSlices(u8, payload, try enc.presentation_codec.encodeAlloc(a, .{ .entry = document.entry }));
}


test "terminal narrow reading footer keeps back scroll fold details and help discoverable" {
    const a = std.testing.allocator;
    const compact = "Esc back ↑↓ e fold d details ? help";
    // The UTF-8 byte count exceeds 40-column capacity, but every display cell fits.
    try std.testing.expectEqual(@as(usize, 39), compact.len);
    try std.testing.expectEqual(@as(usize, 35), term.cellWidth(compact));
    for ([_]usize{ 39, 40, 56, 80 }) |columns| {
        const hint = readingHints(columns);
        var safe: std.Io.Writer.Allocating = .init(a);
        defer safe.deinit();
        try output.terminalText(&safe.writer, hint);
        const visible = safe.written()[0..term.prefixBytes(safe.written(), columns - 4)];
        try std.testing.expectEqualStrings(compact, visible);
        for ([_][]const u8{ "Esc back", "↑↓", "e fold", "d details", "? help" }) |action|
            try std.testing.expect(std.mem.indexOf(u8, visible, action) != null);
        try std.testing.expect(term.cellWidth(visible) <= columns - 4);
    }
    const wide = "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  [ ] section  e fold  d all  s save  ? help";
    const threshold = term.cellWidth(wide) + 4;
    try std.testing.expectEqualStrings(compact, readingHints(threshold - 1));
    try std.testing.expectEqualStrings(wide, readingHints(threshold));
    try std.testing.expectEqualStrings(wide, readingHints(120));
}


test "terminal narrow help preserves bindings and clears the complete reading area" {
    const a = std.testing.allocator;
    const compact = helpLines(40);
    try std.testing.expect(compact.len <= 32 - 7);
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (compact) |line| {
        var safe: std.Io.Writer.Allocating = .init(a);
        defer safe.deinit();
        try output.terminalText(&safe.writer, line);
        try std.testing.expect(term.cellWidth(safe.written()) <= 36);
        try std.testing.expectEqual(safe.written().len, term.prefixBytes(safe.written(), 36));
        try text.writer.print("{s}\n", .{line});
    }
    for ([_][]const u8{ "↑↓", "Enter", "Esc", "/ Search", "Tab cycles", "Arrows/j/k", "PgUp/PgDn", "Home/End", "Ctrl-U", "Ctrl-C/D", "[ ] section", "e folds", "d all details", "s saves", "r random", "1 Saved", "2 History", "3 Search", "4 Learn", "Tab game", "Space reveal", "y/n", "6-9", "Scramble", "then Enter", "v offline speech", "m media", "5 Settings", "arrows adjust limits", "appearance", "t terminal/dark/light", "q quits outside Search", "Any key closes" }) |binding|
        try std.testing.expect(std.mem.indexOf(u8, text.written(), binding) != null);
    const wide = helpLines(120);
    try std.testing.expectEqualStrings("[ ] selects a section; e toggles its fold", wide[7]);
    try std.testing.expectEqualStrings("d toggles all details; s saves the word", wide[8]);
    var threshold: usize = 0;
    for (wide) |line| threshold = @max(threshold, term.cellWidth(line) + 4);
    try std.testing.expectEqualDeep(wide, helpLines(threshold));
    try std.testing.expectEqualDeep(compact, helpLines(threshold - 1));
    for ([_]usize{ 40, 120 }) |columns| {
        // This rendering seam uses allocator/theme/screen only, never the Store.
        var state: State = .{ .a = a, .db = undefined, .label = "", .theme = .terminal, .color = false,
            .screen = .{ .cols = columns, .rows = 32 } };
        var rendered: std.Io.Writer.Allocating = .init(a);
        defer rendered.deinit();
        try state.drawHelp(&rendered.writer);
        const title = std.mem.indexOf(u8, rendered.written(), "KEYBOARD").?;
        for (6..31) |row| {
            const clear = try std.fmt.allocPrint(a, "\x1b[{d};1H\x1b[0m\x1b[2K", .{row});
            defer a.free(clear);
            try std.testing.expect(std.mem.indexOf(u8, rendered.written(), clear).? < title);
            if (row >= 6 + helpLines(columns).len) {
                const paint = try std.fmt.allocPrint(a, "\x1b[{d};3H", .{row});
                defer a.free(paint);
                try std.testing.expect(std.mem.indexOf(u8, rendered.written(), paint) == null);
            }
        }
        try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "\x1b[31;1H\x1b[0m\x1b[2K") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.written(), helpCloseHint) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.written(), "e fold d details") == null);
    }
}


test "terminal short help reaches every binding clamps resize and preserves reader state" {
    const a = std.testing.allocator;
    var state: State = .{ .a = a, .db = undefined, .label = "", .theme = .terminal, .color = false,
        .screen = .{ .cols = 40, .rows = 12 }, .help = true, .scroll = 17, .selected = 3, .section = 2,
        .focus = .entry, .details = true };
    try std.testing.expectEqual(@as(usize, 5), state.helpCapacity());
    try std.testing.expectEqual(@as(usize, 15), state.helpMaxOffset());
    try std.testing.expectEqual(@as(usize, 36), term.cellWidth(helpScrollHint));
    try std.testing.expectEqual(helpScrollHint.len, term.prefixBytes(helpScrollHint, 36));
    for ([_]struct { key: term.Key, offset: usize }{
        .{ .key = .down, .offset = 1 }, .{ .key = .up, .offset = 0 },
        .{ .key = .page_down, .offset = 4 }, .{ .key = .page_down, .offset = 8 },
        .{ .key = .end, .offset = 15 }, .{ .key = .down, .offset = 15 },
        .{ .key = .page_up, .offset = 11 }, .{ .key = .home, .offset = 0 },
        .{ .key = .up, .offset = 0 },
    }) |step| {
        try std.testing.expect(try state.key(.{ .key = step.key }));
        try std.testing.expect(state.help);
        try std.testing.expectEqual(step.offset, state.help_offset);
        try std.testing.expectEqual(@as(usize, 17), state.scroll);
        try std.testing.expectEqual(@as(usize, 3), state.selected);
        try std.testing.expectEqual(@as(usize, 2), state.section);
        try std.testing.expect(state.details and state.focus == .entry);
    }
    var seen: [20]bool = @splat(false);
    try std.testing.expectEqual(seen.len, helpLines(40).len);
    while (true) {
        var frame: std.Io.Writer.Allocating = .init(a);
        defer frame.deinit();
        try state.drawHelp(&frame.writer);
        try std.testing.expect(std.mem.indexOf(u8, frame.written(), helpScrollHint) != null);
        try std.testing.expect(std.mem.indexOf(u8, frame.written(), "\x1b[11;1H\x1b[0m\x1b[2K") != null);
        for (0..state.helpCapacity()) |row| {
            const index = state.help_offset + row;
            const expected = if (index + 1 == seen.len) "Other keys close this help" else helpLines(40)[index];
            try std.testing.expect(std.mem.indexOf(u8, frame.written(), expected) != null);
            seen[index] = true;
        }
        if (state.help_offset == state.helpMaxOffset()) break;
        try std.testing.expect(try state.key(.{ .key = .page_down }));
    }
    for (seen) |visible| try std.testing.expect(visible);
    state.screen.cols = 120;
    var resized: std.Io.Writer.Allocating = .init(a);
    defer resized.deinit();
    try state.drawHelp(&resized.writer);
    try std.testing.expectEqual(@as(usize, 11), state.help_offset);
    state.screen.rows = 40;
    var tall: std.Io.Writer.Allocating = .init(a);
    defer tall.deinit();
    try state.drawHelp(&tall.writer);
    try std.testing.expectEqual(@as(usize, 0), state.help_offset);
    try std.testing.expect(std.mem.indexOf(u8, tall.written(), helpScrollHint) == null);
    try std.testing.expect(std.mem.indexOf(u8, tall.written(), helpCloseHint) != null);
    try std.testing.expect(std.mem.indexOf(u8, tall.written(), "Any key closes this help") != null);
    try std.testing.expect(try state.key(.{ .key = .down }));
    try std.testing.expect(!state.help); // Original full-height any-key close.
    state.help = true;
    state.screen = .{ .cols = 40, .rows = 12 };
    var short_again: std.Io.Writer.Allocating = .init(a);
    defer short_again.deinit();
    try state.drawHelp(&short_again.writer);
    try std.testing.expectEqual(@as(usize, 0), state.help_offset);
    for ([_]term.Event{ .{ .key = .escape }, .{ .key = .text, .bytes = .{ 'd', 0, 0, 0 }, .len = 1 } }) |close| {
        state.help = true;
        state.help_offset = 9;
        try std.testing.expect(try state.key(close));
        try std.testing.expect(!state.help);
        try std.testing.expectEqual(@as(usize, 0), state.help_offset);
    }
    state.help = true;
    try std.testing.expect(!try state.key(.{ .key = .quit }));
    try std.testing.expectEqual(@as(usize, 17), state.scroll);
    try std.testing.expectEqual(@as(usize, 3), state.selected);
    try std.testing.expectEqual(@as(usize, 2), state.section);
    try std.testing.expect(state.details and state.focus == .entry);
}

test "terminal Library paging uses displayed capacity and Home End preserve startup state" {
    const a = std.testing.allocator;
    var state: State = .{ .a = a, .db = undefined, .label = "", .theme = .terminal, .color = false,
        .screen = .{ .cols = 40, .rows = 12 }, .nav = .library, .focus = .entry,
        .startup_library = true, .len = 6, .cursor = 3, .selected = 19, .scroll = 27, .section = 2 };
    @memcpy(state.query[0..6], "prefix");
    defer state.library_names.deinit(a);
    for ([_][]const u8{ "A", "B", "C", "D", "E", "F", "G" }) |name|
        try state.library_names.append(a, name);
    try std.testing.expectEqual(@as(usize, 2), state.libraryPageSize());
    for ([_]struct { key: term.Key, index: usize }{
        .{ .key = .page_down, .index = 2 }, .{ .key = .page_down, .index = 4 },
        .{ .key = .page_down, .index = 6 }, .{ .key = .page_down, .index = 6 },
        .{ .key = .page_up, .index = 4 }, .{ .key = .home, .index = 0 },
        .{ .key = .up, .index = 0 }, .{ .key = .end, .index = 6 },
        .{ .key = .down, .index = 6 },
    }) |step| {
        try std.testing.expect(try state.key(.{ .key = step.key }));
        try std.testing.expectEqual(step.index, state.library_selected);
        try std.testing.expect(state.nav == .library and state.focus == .entry and state.startup_library);
        try std.testing.expectEqual(@as(usize, 19), state.selected);
        try std.testing.expectEqual(@as(usize, 27), state.scroll);
        try std.testing.expectEqual(@as(usize, 2), state.section);
        try std.testing.expectEqual(@as(usize, 6), state.len);
        try std.testing.expectEqual(@as(usize, 3), state.cursor);
        try std.testing.expectEqualStrings("prefix", state.query[0..state.len]);
    }
    // The same source-selected item survives resizing; only the next step changes.
    state.screen = .{ .cols = 90, .rows = 30 };
    try std.testing.expectEqual(@as(usize, 20), state.libraryPageSize());
    try std.testing.expectEqual(@as(usize, 6), state.library_selected);
    try std.testing.expect(try state.key(.{ .key = .page_up }));
    try std.testing.expectEqual(@as(usize, 0), state.library_selected);
    try std.testing.expect(try state.key(.{ .key = .page_down }));
    try std.testing.expectEqual(@as(usize, 6), state.library_selected);
}

test "terminal Library paging clamps empty singleton partial pages and large catalogs" {
    const a = std.testing.allocator;
    var state: State = .{ .a = a, .db = undefined, .label = "", .theme = .terminal, .color = false,
        .screen = .{ .cols = 45, .rows = 24 }, .nav = .library };
    defer state.library_names.deinit(a);
    for ([_]usize{ 0, 1 }) |count| {
        if (count != 0) try state.library_names.append(a, "only");
        for ([_]term.Key{ .page_up, .page_down, .home, .end, .up, .down }) |key| {
            try std.testing.expect(try state.key(.{ .key = key }));
            try std.testing.expectEqual(@as(usize, 0), state.library_selected);
        }
    }
    while (state.library_names.items.len < 31) try state.library_names.append(a, "heading");
    try std.testing.expectEqual(@as(usize, 14), state.libraryPageSize());
    for ([_]usize{ 14, 28, 30, 30 }) |index| {
        try std.testing.expect(try state.key(.{ .key = .page_down }));
        try std.testing.expectEqual(index, state.library_selected);
    }
    try std.testing.expect(try state.key(.{ .key = .page_up }));
    try std.testing.expectEqual(@as(usize, 16), state.library_selected);
    state.screen.rows = 12;
    try std.testing.expect(try state.key(.{ .key = .page_up }));
    try std.testing.expectEqual(@as(usize, 14), state.library_selected);
    while (state.library_names.items.len < 1399) try state.library_names.append(a, "heading");
    try std.testing.expect(try state.key(.{ .key = .end }));
    try std.testing.expectEqual(@as(usize, 1398), state.library_selected);
    try std.testing.expect(try state.key(.{ .key = .home }));
    try std.testing.expectEqual(@as(usize, 0), state.library_selected);
}
