const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const html = @import("html.zig");
const tui = @import("tui.zig");

const usage =
    \\dict: local Wiktionary, one language or feature blob at a time
    \\
    \\  dict lookup WORD [options]
    \\  dict search [PREFIX] [options]
    \\  dict languages [--root PATH] [--format text|json]
    \\  dict stats [options]
    \\  dict tui [PREFIX] [options]
    \\
    \\  --root PATH        WIKBLB03 root (default data/wiktionary-blobs)
    \\  --language NAME    Exact language heading (default English)
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss
    \\  --format FORMAT    text, json, source, html (HTML supports lookup and search)
    \\  --limit N          Search page size, 1..1000 (default 20)
    \\  --offset N         Skip N prefix matches
    \\  --with-source      Include exact source in JSON/HTML entries
    \\  --color MODE       auto, always, never; NO_COLOR disables automatic color
    \\  --theme THEME      TUI palette: terminal (default), dark, light
    \\  --trusted          Skip title-order checks for externally verified blobs
    \\  --validate         Validate while indexing (the default)
    \\  --                 End options, for words beginning with a dash
    \\
    \\Search is case-sensitive UTF-8 prefix matching. Results go to stdout.
    \\Diagnostics go to stderr. Exit: 0 success, 1 no matches, 2 usage/data/I/O error.
    \\Unexpanded templates remain explicit. No network or template VM is used.
    \\
;

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        std.debug.print("dict: {s}\n", .{@errorName(err)});
        if (err == error.Usage) std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const opts = try args.parse(argv[1..]);
    var buffer: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const w = &stdout.interface;
    if (opts.help) {
        try w.writeAll(usage);
        try w.flush();
        return 0;
    }
    if (opts.command == .languages) {
        try languages(init.io, a, opts, w);
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
        try tui.run(init.io, init.gpa, &db, label, opts.query, opts.theme, color);
        return 0;
    }
    var response: output.Response = .{
        .operation = opts.command,
        .query = try model.utf8Text(a, opts.query),
        .kind = opts.kind,
        .language = if (opts.kind == .language) try model.utf8Text(a, opts.language) else null,
        .record_count = db.index.recordCount(),
        .total_matches = 0,
    };
    switch (opts.command) {
        .lookup => {
            response.match_mode = "exact-utf8";
            if (try db.index.find(opts.query)) |record| {
                response.total_matches = 1;
                if (opts.format == .source) {
                    const source = try model.sourceAlloc(a, record);
                    try w.writeAll(source);
                } else {
                    var doc = try model.fromRecord(init.gpa, record, opts.with_source);
                    defer doc.deinit();
                    response.entries = &.{doc.entry};
                    if (opts.format == .html) try html.write(w, a, response) else if (opts.format == .json) try output.json(w, response) else try output.entryText(w, doc.entry, color);
                    if (doc.entry.status == .invalid_payload) {
                        try w.flush();
                        return 2;
                    }
                }
            } else if (opts.format == .html) try html.write(w, a, response) else if (opts.format == .json) try output.json(w, response) else if (opts.format == .text) {
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
            for (matches, start..) |*match, index| match.* = .{ .title = try model.utf8Text(a, (try db.index.recordAt(index)).title()) };
            response.matches = matches;
            if (opts.format == .html) {
                var docs: std.ArrayList(model.OwnedEntry) = .empty;
                defer {
                    for (docs.items) |*doc| doc.deinit();
                    docs.deinit(init.gpa);
                }
                const entries = try a.alloc(model.Entry, end - start);
                var invalid = false;
                for (entries, start..) |*entry, index| {
                    var doc = try model.fromRecord(init.gpa, try db.index.recordAt(index), opts.with_source);
                    docs.append(init.gpa, doc) catch |err| {
                        doc.deinit();
                        return err;
                    };
                    entry.* = doc.entry;
                    invalid = invalid or doc.entry.status == .invalid_payload;
                }
                response.entries = entries;
                try html.write(w, a, response);
                if (invalid) {
                    try w.flush();
                    return 2;
                }
            } else if (opts.format == .json) try output.json(w, response) else {
                for (matches) |match| {
                    try output.terminalText(w, match.title);
                    try w.writeByte('\n');
                }
                if (matches.len == 0) try w.writeAll("No prefix matches on this page.\n");
            }
        },
        .stats => {
            response.total_matches = db.index.recordCount();
            if (opts.format == .json) try output.json(w, response) else {
                try output.terminalText(w, if (opts.kind == .language) opts.language else "All languages");
                try w.print(" / {s}\nrecords: {d}\nblob bytes: {d}\nruntime index bytes: {d}\n", .{ @tagName(opts.kind), db.index.recordCount(), db.bytes.len, db.index.recordCount() * @sizeOf(usize) });
            }
        },
        .languages, .tui => unreachable,
    }
    try w.flush();
    return if (response.total_matches == 0 and opts.command != .stats) 1 else 0;
}

fn languages(io: std.Io, a: std.mem.Allocator, opts: args.Options, w: *std.Io.Writer) !void {
    const path = try std.fs.path.join(a, &.{ opts.root, store.catalog.manifest_filename });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    var it = try store.catalog.Iterator.init(bytes);
    var headings: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(a);
    while (try it.next()) |item| {
        const result = try seen.getOrPut(item.heading);
        if (result.found_existing) return error.InvalidManifest;
        try headings.append(a, try model.utf8Text(a, item.heading));
    }
    std.mem.sort([]const u8, headings.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    if (opts.format == .json) {
        try std.json.Stringify.value(.{ .schema = "dict.languages.v1", .languages = headings.items }, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
    } else for (headings.items) |heading| {
        try output.terminalText(w, heading);
        try w.writeByte('\n');
    }
}
test {
    _ = args;
    _ = store;
    _ = model;
    _ = output;
    _ = html;
    _ = tui;
    _ = @import("pipeline_tests.zig");
}
