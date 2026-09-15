const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const tui = @import("tui.zig");

const usage =
    \\dict — fast local Wiktionary
    \\
    \\Usage
    \\  dict WORD                         Look up a word
    \\  dict search [PREFIX]              Browse prefix matches
    \\  dict tui [PREFIX]                 Open the interactive reader
    \\  dict export WORD                  Export compiled presentation JSON
    \\  dict languages [WORD]             List installed languages
    \\  dict stats                        Show dataset statistics
    \\
    \\Desktop GUI
    \\  dict-qt [--root PATH] [WORD]      Open the native Qt 6 application
    \\
    \\Common options
    \\  --language NAME    Language heading (default: English)
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss
    \\  --root PATH        Dataset root (default: data/wiktionary-blobs)
    \\  --format FORMAT    text, json
    \\  --limit N          Search results per page, 1..1000 (default: 20)
    \\  --offset N         Skip N prefix matches
    \\  --details          Show all compiled supporting details in text/TUI
    \\  --color MODE       auto, always, never; NO_COLOR disables automatic color
    \\  --theme THEME      TUI palette: terminal, dark, light
    \\  --trusted          Legacy compatibility flag; cached directories are still validated
    \\  --validate         Validate while indexing (default)
    \\  --                 End options, for words beginning with a dash
    \\
    \\Readers consume compiled dictionary data only. No wikitext, templates, or Lua execute at runtime.
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
    const opts = try args.parse(argv[1..]);
    var buffer: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const w = &stdout.interface;
    if (opts.help) {
        try w.writeAll(usage);
        try w.flush();
        return 0;
    }
    if (opts.command == .languages) {
        try @import("languages.zig").write(init.io, a, init.gpa, opts, w);
        try w.flush();
        return 0;
    }
    if (opts.command == .tui and (!try std.Io.File.stdin().isTty(init.io) or !try std.Io.File.stdout().isTty(init.io) or (if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false))) return error.TerminalRequired;
    var db = try store.Store.open(init.io, init.gpa, opts.root, opts.kind, opts.language, opts.trusted);
    defer db.deinit();
    const color = switch (opts.color) {
        .always => true,
        .never => false,
        .auto => !init.environ_map.contains("NO_COLOR") and !(if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false) and try std.Io.File.stdout().isTty(init.io),
    };
    if (opts.command == .tui) {
        const label = try std.fmt.allocPrint(a, "{s} / {s}", .{ if (opts.kind == .language) opts.language else "Features", @tagName(opts.kind) });
        try tui.run(init.io, init.gpa, &db, label, opts.query, opts.theme, color, opts.details);
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
            response.match_mode = "exact-utf8";
            if (try db.find(opts.query)) |record_index| {
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
                try w.writeByte('\n');
            }
        },
        .search => {
            const range = try db.prefix(opts.query);
            response.total_matches = range.end - range.start;
            response.offset = opts.offset;
            const start = range.start + @min(opts.offset, response.total_matches);
            const end = start + @min(opts.limit, range.end - start);
            response.has_more = end < range.end;
            const matches = try a.alloc(output.Match, end - start);
            for (matches, start..) |*match, index| match.* = .{ .title = try model.utf8Text(a, try db.titleAt(index)) };
            response.matches = matches;
            if (opts.format == .json) try output.json(w, response) else {
                for (matches) |match| {
                    try output.terminalText(w, match.title);
                    try w.writeByte('\n');
                }
                if (matches.len == 0) try w.writeAll("No prefix matches on this page.\n");
            }
        },
        .stats => {
            response.total_matches = db.count();
            if (opts.format == .json) try output.json(w, response) else {
                try output.terminalText(w, if (opts.kind == .language) opts.language else "All languages");
                try w.print(" / {s}\nrecords: {d}\nblob bytes: {d}\nruntime index bytes: {d}\nindex heap bytes: {d}\ncache map bytes: {d}\n", .{ @tagName(opts.kind), db.count(), db.file.size, db.file.indexBytes(), db.file.indexHeapBytes(), db.file.cacheMappedBytes() });
            }
        },
        .languages, .tui => unreachable,
    }
    try w.flush();
    return if (response.total_matches == 0 and opts.command != .stats) 1 else 0;
}

test {
    _ = args;
    _ = store;
    _ = model;
    _ = output;
    _ = tui;
    _ = @import("pipeline_tests.zig");
    _ = @import("blob_storage");
}
