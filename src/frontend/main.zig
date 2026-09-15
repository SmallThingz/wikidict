const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const tui = @import("tui.zig");
const expansion = @import("expansion.zig");

const usage =
    \\dict — fast local Wiktionary
    \\
    \\Usage
    \\  dict WORD                         Look up a word
    \\  dict search [PREFIX]              Browse prefix matches
    \\  dict tui [PREFIX]                 Open the interactive reader
    \\  dict export WORD [--format json]  Export frontend-neutral data
    \\  dict languages [WORD]             List installed languages
    \\  dict stats                         Show dataset statistics
    \\  dict render FILE                   Render standalone wikitext; use - for stdin
    \\
    \\Desktop GUI
    \\  dict-qt [--root PATH] [WORD]       Open the native Qt 6 application
    \\
    \\Common options
    \\  --language NAME    Language heading (default: English)
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss
    \\  --root PATH        Dataset root (default: data/wiktionary-blobs)
    \\  --format FORMAT    text, json, source
    \\  --limit N          Search results per page, 1..1000 (default: 20)
    \\  --offset N         Skip N prefix matches
    \\  --details          Include history, quotations, relations and references in text/TUI
    \\  --with-source      Include exact source in JSON
    \\  --color MODE       auto, always, never; NO_COLOR disables automatic color
    \\
    \\Rendering
    \\  --core-only        Read only the compact core; omitted companion sections stay labelled
    \\  --native           Skip Lua/template expansion and show the native core preview
    \\  --runtime PATH     Override the auto-detected native Lua runtime
    \\  --runtime-timeout-ms N  Expansion deadline, 1..60000 (default: 60000)
    \\  --title TITLE      Title for `dict render`
    \\  --theme THEME      TUI palette: terminal, dark, light
    \\  --trusted          Legacy compatibility flag; cached directories are still validated
    \\  --validate         Validate while indexing (default)
    \\  --                 End options, for words beginning with a dash
    \\
    \\Everything is local. The `dict` executable is CLI/TUI only; the desktop GUI is native Qt 6.
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
    const automatic = if (!opts.native and !opts.core_only and opts.runtime == null and (opts.command == .lookup or opts.command == .search or opts.command == .tui)) try defaultRuntime(init.io, a, opts.root) else null;
    const runtime: expansion.Options = .{ .root = opts.runtime orelse automatic, .timeout_ms = opts.runtime_timeout_ms, .dictionary_root = if (opts.command == .render) null else opts.root };
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
    if (opts.command == .render) {
        const source = if (std.mem.eql(u8, opts.query, "-")) blk: {
            var input_buffer: [8192]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
            break :blk try reader.interface.allocRemaining(a, .limited(16 * 1024 * 1024));
        } else try std.Io.Dir.cwd().readFileAlloc(init.io, opts.query, a, .limited(16 * 1024 * 1024));
        if (opts.format == .source) {
            try w.writeAll(source);
            try w.flush();
            return 0;
        }
        var doc = try expansion.fromWikitext(init.io, init.gpa, opts.title, opts.language, source, opts.with_source, runtime);
        defer doc.deinit();
        const response: output.Response = .{ .operation = .render, .query = doc.entry.title, .kind = .language, .language = doc.entry.language, .match_mode = "render-input", .record_count = 1, .total_matches = 1, .entries = &.{doc.entry} };
        const color = opts.color == .always or (opts.color == .auto and !init.environ_map.contains("NO_COLOR") and !(if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false) and try std.Io.File.stdout().isTty(init.io));
        if (opts.format == .json) try output.json(w, response) else try output.entryTextWithDetails(w, doc.entry, color, opts.details);
        try w.flush();
        return if (renderFailed(doc.entry)) 2 else 0;
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
        try tui.run(init.io, init.gpa, &db, label, opts.query, opts.theme, color, runtime, opts.details);
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
                const raw_record = raw.record;
                const core = opts.core_only or (opts.format == .text and !opts.details and !opts.with_source and runtime.root == null);
                var resolved = if (core) try db.resolveCoreAlloc(init.gpa, raw_record) else try db.resolveAlloc(init.gpa, raw_record);
                defer resolved.deinit();
                const record = resolved.record;
                response.total_matches = 1;
                if (opts.format == .source) {
                    const source = try model.sourceAlloc(a, record);
                    try w.writeAll(source);
                } else {
                    var doc = if (core) try model.fromCoreRecord(init.gpa, record) else try expansion.fromRecord(init.io, init.gpa, record, opts.with_source, runtime);
                    defer doc.deinit();
                    response.entries = &.{doc.entry};
                    if (opts.format == .json) try output.json(w, response) else try output.entryTextWithDetails(w, doc.entry, color, opts.details);
                    if (renderFailed(doc.entry)) {
                        try w.flush();
                        return 2;
                    }
                }
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
        .languages, .tui, .render => unreachable,
    }
    try w.flush();
    return if (response.total_matches == 0 and opts.command != .stats) 1 else 0;
}

fn renderFailed(entry: model.Entry) bool {
    return entry.status == .invalid_payload or (if (entry.expansion) |e| e.status == .failed else false);
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

fn defaultRuntime(io: std.Io, a: std.mem.Allocator, root: []const u8) !?[]const u8 {
    for ([_][]const u8{ "dict-native-expansion-worker", "runtime/dict-native-expansion-worker" }) |relative| {
        const path = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(path);
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        file.close(io);
        return root;
    }
    return null;
}
