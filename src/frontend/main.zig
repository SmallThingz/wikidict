const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const tui = @import("tui.zig");
const ReadingState = @import("reading_state.zig").State;
const search = @import("search.zig");

const usage =
    \\dict — fast local Wiktionary
    \\
    \\Usage
    \\  dict WORD                         Look up a word
    \\  dict search [PREFIX]              Browse prefix matches
    \\  dict tui [PREFIX]                 Open the interactive reader
    \\  dict saved / dict history         List saved or recently viewed words
    \\  dict save WORD / dict unsave WORD Save or remove a word
    \\  dict export WORD                  Export compiled presentation JSON
    \\  dict languages [WORD]             List installed languages
    \\  dict catalog [HTTPS_LIST]         Read a download catalogue
    \\  dict install FILE_OR_HTTPS_URL    Install raw/XZ blob; optional --sha256 HASH
    \\  dict stats                        Show dataset statistics
    \\
    \\Desktop GUI
    \\  dict-qt [--root PATH] [WORD]      Open the native Qt 6 application
    \\
    \\Common options
    \\  --language NAME    Language heading (DICT_LANGUAGE, otherwise English)
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss
    \\  --root PATH        Dataset root (DICT_ROOT, otherwise data/wiktionary-blobs)
    \\  --format FORMAT    text, json
    \\  --limit N          Words per page, 1..1000 (default: 20)
    \\  --offset N         Skip N words in Search, Saved or History
    \\  --details          Show all compiled supporting details in text/TUI
    \\  --case-sensitive   Use exact UTF-8 case (default: Unicode lowercase matching)
    \\  --color MODE       auto, always, never; NO_COLOR disables automatic color
    \\  --theme THEME      TUI palette: terminal, dark, light
    \\  --                 End options, for words beginning with a dash
    \\
    \\Run dict without arguments in a terminal to open the interactive reader.
    \\Set DICT_ROOT once to use your dictionary from any folder.
    \\Exit status: 0 success, 1 no match, 2 invalid input or an operation failed.
;

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        if (err == error.Usage)
            std.debug.print("dict: invalid arguments\n\n{s}", .{usage})
        else
            std.debug.print("dict: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    var opts = try args.parseWithDefaults(argv[1..], .{
        .root = init.environ_map.get("DICT_ROOT") orelse (args.Options{}).root,
        .language = init.environ_map.get("DICT_LANGUAGE") orelse (args.Options{}).language,
    });
    const interactive = try std.Io.File.stdin().isTty(init.io) and try std.Io.File.stdout().isTty(init.io) and !(if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false);
    if (argv.len == 1 and interactive) {
        opts.help = false;
        opts.command = .tui;
    }
    var buffer: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const w = &stdout.interface;
    if (opts.help) {
        try w.writeAll(usage);
        try w.flush();
        return 0;
    }
    if (opts.command == .catalog or opts.command == .install) {
        const library = @import("library.zig");
        if (opts.command == .catalog) library.catalog(init.io, init.gpa, opts.query, w) catch |err| {
            std.debug.print("dict: catalogue unavailable ({s}). Try 'dict catalog HTTPS_URL', or install a local file with 'dict install FILE --root DIRECTORY'.\n", .{@errorName(err)});
            return 2;
        } else library.install(init.io, init.gpa, opts.root, opts.query, opts.sha256, w) catch |err| {
            std.debug.print("dict: installation failed ({s}). Check the file or HTTPS URL, destination permissions, and optional SHA-256; then retry.\n", .{@errorName(err)});
            return 2;
        };
        try w.flush();
        return 0;
    }
    if (opts.command == .languages) {
        @import("languages.zig").write(init.io, a, init.gpa, opts, w) catch |err| {
            try reportOpenError(init.io, opts, err);
            return 2;
        };
        try w.flush();
        return 0;
    }
    if (opts.command == .tui and !interactive) {
        std.debug.print("dict: the interactive reader needs a terminal. Use 'dict WORD' or 'dict search PREFIX' in a pipe.\n", .{});
        return 2;
    }
    if (opts.command == .tui) std.debug.print("Opening dictionary...\n", .{});
    var db = store.Store.open(init.io, init.gpa, opts.root, opts.kind, opts.language) catch |err| {
        try reportOpenError(init.io, opts, err);
        return 2;
    };
    defer db.deinit();
    const color = switch (opts.color) {
        .always => true,
        .never => false,
        .auto => !init.environ_map.contains("NO_COLOR") and !(if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false) and try std.Io.File.stdout().isTty(init.io),
    };
    const label = try std.fmt.allocPrint(a, "{s} / {s}", .{ if (opts.kind == .language) opts.language else "Features", @tagName(opts.kind) });
    if (opts.command == .tui) {
        try tui.run(init.io, init.gpa, &db, label, opts.query, opts.theme, color, opts.details, opts.case_sensitive);
        return 0;
    }
    var response: output.Response = .{
        .operation = opts.command,
        .query = try model.utf8Text(a, opts.query),
        .kind = opts.kind,
        .language = if (opts.kind == .language) try model.utf8Text(a, opts.language) else null,
        .record_count = db.count(),
        .total_matches = 0,
    };
    switch (opts.command) {
        .lookup => {
            response.match_mode = if (opts.case_sensitive) "exact-utf8" else "unicode-lowercase";
            if (if (opts.case_sensitive) try db.find(opts.query) else try search.find(init.gpa, &db, opts.query)) |record_index| {
                var raw = try db.recordAlloc(init.gpa, record_index);
                defer raw.deinit();
                response.total_matches = 1;
                var doc = try model.fromRecord(init.gpa, raw.record);
                defer doc.deinit();
                response.entries = &.{doc.entry};
                if (opts.format == .json) try output.json(w, response) else try output.entryTextWithDetails(w, doc.entry, color, opts.details);
            } else if (opts.format == .json) try output.json(w, response) else if (opts.format == .text) {
                try w.writeAll("No exact match: ");
                try output.terminalText(w, opts.query);
                try w.writeAll("\nUse 'dict search PREFIX' to browse words.\n");
            }
        },
        .search => {
            var task: search.Task = .{};
            defer task.deinit(init.gpa);
            const insensitive = !opts.case_sensitive and std.mem.trim(u8, opts.query, " \t\r\n").len != 0;
            const range = if (insensitive) blk: {
                const wanted = std.math.add(usize, opts.offset, opts.limit) catch return error.SearchWindowTooLarge;
                try task.beginLimited(init.gpa, opts.query, wanted);
                while (!task.complete) try task.step(init.gpa, &db, 4096);
                break :blk store.Range{ .start = 0, .end = task.matches.items.len };
            } else try db.prefix(if (opts.case_sensitive) opts.query else "");
            response.match_mode = if (insensitive) "unicode-lowercase-prefix" else "exact-utf8-prefix";
            response.total_matches = if (insensitive) task.total_matches else range.end - range.start;
            response.offset = opts.offset;
            const retained_total = range.end - range.start;
            const start = range.start + @min(opts.offset, retained_total);
            const end = start + @min(opts.limit, range.end - start);
            const returned = end - start;
            response.has_more = opts.offset +| returned < response.total_matches;
            const matches = try a.alloc(output.Match, returned);
            for (matches, start..) |*match, index| match.* = .{ .title = try model.utf8Text(a, try db.titleAt(if (insensitive) task.matches.items[index].index else index)) };
            response.matches = matches;
            if (opts.format == .json) try output.json(w, response) else {
                for (matches) |match| {
                    try output.terminalText(w, match.title);
                    try w.writeByte('\n');
                }
                if (response.total_matches == 0) std.debug.print("No matching words. Try a shorter prefix.\n", .{}) else try pageHint(init.io, opts, response.total_matches, matches.len);
            }
        },
        .saved, .history, .save, .unsave => {
            var reading = ReadingState.init(init.gpa);
            defer reading.deinit();
            try reading.load(init.io, opts.root, label);
            response.match_mode = "saved-title";
            if (opts.command == .save or opts.command == .unsave) {
                const wanted = opts.command == .save;
                const index = if (opts.case_sensitive) try db.find(opts.query) else try search.find(init.gpa, &db, opts.query);
                const title = if (index) |i| try db.titleAt(i) else opts.query;
                const saved = ReadingState.contains(reading.data.saved, title);
                if (wanted and index == null) {
                    if (opts.format == .json) try output.json(w, response) else try w.writeAll("That word is not in this dictionary. Use 'dict search PREFIX' to find its spelling.\n");
                } else {
                    if (saved != wanted) {
                        try reading.bookmark(title);
                        try reading.save(init.io);
                    }
                    response.total_matches = 1;
                    response.matches = &.{.{ .title = try model.utf8Text(a, title) }};
                    if (opts.format == .json) try output.json(w, response) else {
                        try w.writeAll(if (wanted) "Saved: " else "Removed from Saved: ");
                        try output.terminalText(w, title);
                        try w.writeByte('\n');
                    }
                }
            } else {
                const words = if (opts.command == .saved) reading.data.saved else reading.data.history;
                response.total_matches = words.len;
                response.offset = opts.offset;
                const start = @min(opts.offset, words.len);
                const end = start + @min(opts.limit, words.len - start);
                response.has_more = end < words.len;
                const matches = try a.alloc(output.Match, end - start);
                for (matches, words[start..end]) |*match, word| match.* = .{ .title = try model.utf8Text(a, word) };
                response.matches = matches;
                if (opts.format == .json) try output.json(w, response) else {
                    for (matches) |match| {
                        try output.terminalText(w, match.title);
                        try w.writeByte('\n');
                    }
                    if (words.len == 0) std.debug.print("{s}", .{if (opts.command == .saved) "No saved words yet. Use 'dict save WORD' or press s in the reader.\n" else "No viewed words yet. Open a word in 'dict tui' to remember it.\n"}) else try pageHint(init.io, opts, words.len, matches.len);
                }
            }
        },
        .stats => {
            response.total_matches = db.count();
            if (opts.format == .json) try output.json(w, response) else {
                try output.terminalText(w, if (opts.kind == .language) opts.language else "All languages");
                try w.print(" / {s}\nrecords: {d}\nblob bytes: {d}\nruntime index bytes: {d}\nindex heap bytes: {d}\ncache map bytes: {d}\n", .{ @tagName(opts.kind), db.count(), db.file.size, db.file.indexBytes(), db.file.indexHeapBytes(), db.file.cacheMappedBytes() });
            }
        },
        .languages, .tui, .catalog, .install => unreachable,
    }
    try w.flush();
    return if (response.total_matches == 0 and opts.command != .stats) 1 else 0;
}

fn reportOpenError(io: std.Io, opts: args.Options, err: anyerror) !void {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    const w = &stderr.interface;
    try w.writeAll("dict: could not open ");
    try output.terminalText(w, if (opts.kind == .language) opts.language else @tagName(opts.kind));
    try w.writeAll(" in ");
    try output.terminalText(w, opts.root);
    try w.print(" ({s}).\n", .{@errorName(err)});
    try w.writeAll(switch (err) {
        error.FileNotFound => "Choose an installed dataset with --root PATH.\nUse 'dict languages --root PATH' to check its language names.\nFor a new dictionary, run 'dict catalog', then 'dict install URL --root PATH'.\n",
        error.DictionaryBuildIncomplete => "This dataset is still being built. Wait for its build to finish or choose a completed dataset with --root PATH.\n",
        error.AccessDenied => "Check that you can read the dataset folder and its files, or choose another folder with --root PATH.\n",
        else => "Check the selected language with 'dict languages --root PATH', or choose a valid compiled dataset with --root PATH.\n",
    });
    try w.flush();
}

fn pageHint(io: std.Io, opts: args.Options, total: usize, count: usize) !void {
    if (opts.offset == 0 and count == total) return;
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    const w = &stderr.interface;
    const start = @min(opts.offset, total);
    if (count == 0) try w.print("No words at offset {d}; {d} total. Use --offset 0 to start again.\n", .{ opts.offset, total }) else {
        try w.print("Words {d}-{d} of {d}.", .{ start + 1, start + count, total });
        if (start + count < total) try w.print(" Next page: repeat with --offset {d}.", .{start + count});
        try w.writeByte('\n');
    }
    try w.flush();
}

test {
    _ = args;
    _ = store;
    _ = model;
    _ = output;
    _ = tui;
    _ = @import("media_job.zig");
    _ = @import("pipeline_tests.zig");
    _ = @import("blob_storage");
}
