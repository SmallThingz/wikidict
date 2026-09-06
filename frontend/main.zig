const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const html = @import("html.zig");
const tui = @import("tui.zig");
const expansion = @import("expansion.zig");

const usage =
    \\dict: local Wiktionary, one language or feature blob at a time
    \\
    \\  dict lookup WORD [options]
    \\  dict search [PREFIX] [options]
    \\  dict languages [WORD] [--root PATH] [--format text|json]
    \\  dict stats [options]
    \\  dict tui [PREFIX] [options]
    \\  dict render FILE [--title TITLE] [--format text|json|html|source]
    \\       Use - for stdin. No database is needed.
    \\
    \\  --root PATH        WIKBLB05 root (default data/wiktionary-blobs)
    \\  --language NAME    Exact language heading (default English)
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss
    \\  --format FORMAT    text, json, source, html (HTML supports lookup and search)
    \\  --limit N          Search page size, 1..1000 (default 20)
    \\  --offset N         Skip N prefix matches
    \\  --with-source      Include exact source in JSON/HTML entries
    \\  --details          Load all supporting material in human text; TUI uses d
    \\  --core-only        Export native core without reading optional companion blobs
    \\  --color MODE       auto, always, never; NO_COLOR disables automatic color
    \\  --theme THEME      TUI palette: terminal (default), dark, light
    \\  --native           Use native core preview instead of the linked Lua runtime
    \\  --media-dir PATH   Embed verified local media in HTML (default ROOT/media)
    \\  --runtime PATH     Override auto-detected shared template/Lua runtime
    \\  --runtime-timeout-ms N  Per-page VM deadline, 1..60000 (default 60000)
    \\  --trusted          Skip title-order checks for externally verified blobs
    \\  --validate         Validate while indexing (the default)
    \\  --                 End options, for words beginning with a dash
    \\
    \\Search is case-sensitive UTF-8 prefix matching. Results go to stdout.
    \\Diagnostics go to stderr. Exit: 0 success, 1 no matches, 2 usage/data/I/O error.
    \\Wikitext and core Wiktionary templates render locally. Unsupported templates are marked.
    \\No network is used. Linked datasets automatically use their local Lua-bytecode VM.
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
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--internal-expand")) {
        try @import("expansion_worker.zig").main(init);
        return 0;
    }
    const opts = try args.parse(argv[1..]);
    const media_root: ?[]const u8 = opts.media_dir orelse (if (opts.command == .render) null else try std.fs.path.join(a, &.{ opts.root, "media" }));
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
        if (opts.format == .html) try html.writeLocal(w, a, init.io, response, media_root) else if (opts.format == .json) try output.json(w, response) else try output.entryTextWithDetails(w, doc.entry, color, opts.details);
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
        .record_count = db.index.recordCount(),
        .total_matches = 0,
    };
    switch (opts.command) {
        .lookup => {
            response.match_mode = "exact-utf8";
            if (try db.index.find(opts.query)) |raw_record| {
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
                    if (opts.format == .html) try htmlWithLemmas(init.io, a, init.gpa, &db, w, response, opts.with_source, runtime, opts.core_only, media_root) else if (opts.format == .json) try output.json(w, response) else try output.entryTextWithDetails(w, doc.entry, color, opts.details);
                    if (renderFailed(doc.entry)) {
                        try w.flush();
                        return 2;
                    }
                }
            } else if (opts.format == .html) try html.writeLocal(w, a, init.io, response, media_root) else if (opts.format == .json) try output.json(w, response) else if (opts.format == .text) {
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
                    // The export arena retains resolved bodies until every borrowed document is written.
                    const raw = try db.index.recordAt(index);
                    const resolved = if (opts.core_only) try db.resolveCoreAlloc(a, raw) else try db.resolveAlloc(a, raw);
                    var doc = if (opts.core_only) try model.fromCoreRecord(init.gpa, resolved.record) else try expansion.fromRecord(init.io, init.gpa, resolved.record, opts.with_source, runtime);
                    docs.append(init.gpa, doc) catch |err| {
                        doc.deinit();
                        return err;
                    };
                    entry.* = doc.entry;
                    invalid = invalid or renderFailed(doc.entry);
                }
                response.entries = entries;
                try html.writeLocal(w, a, init.io, response, media_root);
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
    _ = html;
    _ = tui;
    _ = @import("pipeline_tests.zig");
    _ = @import("runtime_symbols");
}

fn htmlWithLemmas(io: std.Io, arena: std.mem.Allocator, a: std.mem.Allocator, db: *store.Store, w: *std.Io.Writer, response: output.Response, with_source: bool, runtime: expansion.Options, core_only: bool, media_root: ?[]const u8) !void {
    var entries: std.ArrayList(model.Entry) = .empty;
    var related_failed = false;
    var docs: std.ArrayList(model.OwnedEntry) = .empty;
    defer {
        for (docs.items) |*doc| doc.deinit();
        docs.deinit(a);
    }
    try entries.appendSlice(arena, response.entries);
    const metadata = db.index.blob.languageMetadata() orelse return html.writeLocal(w, arena, io, response, media_root);
    for (response.entries) |entry| for (entry.organization.lexemes) |lexeme| for (lexeme.definitions) |sense| if (sense.form) |form| {
        if (!std.mem.eql(u8, form.language, metadata.code) or entries.items.len >= 9) continue;
        var seen = false;
        for (entries.items) |present| if (std.mem.eql(u8, present.title, form.target)) {
            seen = true;
            break;
        };
        if (seen) continue;
        const raw = (try db.index.find(form.target)) orelse continue;
        const resolved = if (core_only) try db.resolveCoreAlloc(arena, raw) else try db.resolveAlloc(arena, raw);
        var doc = if (core_only) try model.fromCoreRecord(a, resolved.record) else try expansion.fromRecord(io, a, resolved.record, with_source, runtime);
        docs.append(a, doc) catch |err| {
            doc.deinit();
            return err;
        };
        related_failed = related_failed or renderFailed(doc.entry);
        try entries.append(arena, doc.entry);
    };
    var expanded = response;
    expanded.entries = entries.items;
    try html.writeLocal(w, arena, io, expanded, media_root);
    if (related_failed) {
        try w.flush();
        return error.RelatedEntryRenderingFailed;
    }
}

fn defaultRuntime(io: std.Io, a: std.mem.Allocator, root: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(a, &.{ root, "bytecode.wikblb" });
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    file.close(io);
    return root;
}
