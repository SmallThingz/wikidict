const std = @import("std");
const args = @import("args.zig");
const store = @import("store.zig");
const model = @import("model.zig");
const output = @import("output.zig");
const tui = @import("tui.zig");
const ReadingState = @import("reading_state.zig").State;
const search = @import("search.zig");
const desktop_dispatch = @import("desktop_dispatch.zig");

const usage =
    \\wikidict — fast local Wiktionary
    \\
    \\Usage
    \\  wikidict WORD                         Look up a word
    \\  wikidict search [PREFIX]              Browse prefix matches
    \\  wikidict tui [PREFIX]                 Open the interactive reader
    \\  wikidict saved / wikidict history     List saved or recently viewed words
    \\  wikidict save WORD / wikidict unsave WORD Save or remove a word
    \\  wikidict export WORD                  Export compiled presentation JSON
    \\  wikidict export --batch --case-sensitive -- WORD...  Exact JSON Lines (max 64)
    \\  wikidict languages [WORD]             List installed languages
    \\  wikidict catalog HTTPS_LIST         Read a download catalogue
    \\  wikidict install FILE_OR_HTTPS_URL    Install raw/XZ blob; optional --sha256 HASH
    \\  wikidict stats                        Show dataset statistics
    \\
    \\Desktop GUI
    \\  wikidict-gio [--root PATH] [WORD] Open the native desktop application
    \\
    \\Common options
    \\  --language NAME    Language heading (DICT_LANGUAGE, otherwise English)
    \\                     An interactive reader without English opens an installed language or chooser.
    \\  --kind KIND        language, thesaurus, citations, reconstruction, rhymes, sign-gloss, supplemental
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
    \\Run wikidict without arguments in a terminal to open the interactive reader.
    \\The dict command remains an alias for wikidict.
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
    if (argv.len > 0 and desktop_dispatch.isGuiInvocation(argv[0]))
        return desktop_dispatch.run(init, argv);
    var opts = try args.parseWithDefaults(argv[1..], .{
        .root = init.environ_map.get("DICT_ROOT") orelse (args.Options{}).root,
        .language = init.environ_map.get("DICT_LANGUAGE") orelse (args.Options{}).language,
        .language_explicit = init.environ_map.contains("DICT_LANGUAGE"),
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
            if (err == error.CatalogUrlRequired) {
                std.debug.print("dict: provide an HTTPS catalogue URL: 'dict catalog HTTPS_URL'. You can also install a local dictionary with 'dict install FILE --root DIRECTORY'.\n", .{});
                return 2;
            }
            std.debug.print("dict: catalogue unavailable ({s}). Try 'dict catalog HTTPS_URL', or install a local file with 'dict install FILE --root DIRECTORY'.\n", .{@errorName(err)});
            return 2;
        } else library.install(init.io, init.gpa, opts.root, opts.query, opts.sha256, w) catch |err| {
            if (err == error.DictionaryBuildIncomplete) {
                try reportOpenError(init.io, opts, err);
                return 2;
            }
            if (err == error.EditionScopeMismatch) {
                std.debug.print("dict: choose a separate empty folder for another edition or unlabelled dictionaries.\n", .{});
                return 2;
            }
            if (err == error.InstallReportFailed) {
                std.debug.print("dict: dictionary installed, but confirmation output failed.\n", .{});
                return 2;
            }
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
    var choose_language = false;
    var db = openReader(init.io, init.gpa, a, &opts, &choose_language) catch |err| {
        try reportOpenError(init.io, opts, err);
        return 2;
    };
    defer db.deinit();
    if (opts.batch_session) return exportSession(init.io, init.gpa, &db, w);
    if (opts.batch_queries.len != 0) return exportBatch(init.gpa, &db, opts.batch_queries, opts.batch_audit_hints, false, w);
    const color = switch (opts.color) {
        .always => true,
        .never => false,
        .auto => !init.environ_map.contains("NO_COLOR") and !(if (init.environ_map.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false) and try std.Io.File.stdout().isTty(init.io),
    };
    const label = try db.labelAlloc(a);
    if (opts.command == .tui) {
        try tui.run(init.io, init.gpa, &db, label, opts.query, opts.theme, color, opts.details, opts.case_sensitive, choose_language);
        return 0;
    }
    var response: output.Response = .{
        .operation = opts.command,
        .query = try model.utf8Text(a, opts.query),
        .kind = opts.kind,
        .language = if (db.heading()) |heading| try model.utf8Text(a, heading) else null,
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
            try populateSearch(a, init.gpa, &db, opts, &response);
            const matches = response.matches;
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
                try output.terminalText(w, if (db.neutral_main) "Redirects" else db.heading() orelse "All languages");
                try w.print(" / {s}\nrecords: {d}\nblob bytes: {d}\nruntime index bytes: {d}\nindex heap bytes: {d}\ncache map bytes: {d}\n", .{ @tagName(opts.kind), db.count(), db.file.size, db.file.indexBytes(), db.file.indexHeapBytes(), db.file.cacheMappedBytes() });
            }
        },
        .languages, .tui, .catalog, .install => unreachable,
    }
    try w.flush();
    return if (response.total_matches == 0 and opts.command != .stats) 1 else 0;
}

fn hasEmptyLanguageCatalog(io: std.Io, root: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return false;
    defer dir.close(io);
    // One extra byte distinguishes a header-only catalog from a populated one.
    var buffer: [store.catalog.manifest_header.len + 2]u8 = undefined;
    const bytes = dir.readFile(io, store.catalog.manifest_filename, &buffer) catch return false;
    return std.mem.eql(u8, bytes, store.catalog.manifest_header ++ "\n");
}

test "empty dataset hint requires the complete header-only language catalog" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    try std.testing.expect(!hasEmptyLanguageCatalog(io, root));
    const h = store.catalog.manifest_header;
    for ([_][]const u8{ "", "head", h, "other\n", h ++ "\n\n", h ++ "\nA", h ++ "\nEnglish\n" }) |contents| {
        try tmp.dir.writeFile(io, .{ .sub_path = store.catalog.manifest_filename, .data = contents });
        try std.testing.expect(!hasEmptyLanguageCatalog(io, root));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = store.catalog.manifest_filename, .data = h ++ "\n" });
    try std.testing.expect(hasEmptyLanguageCatalog(io, root));
}

const InitialCollection = struct { heading: []const u8, show_library: bool };

fn implicitCollection(bytes: []const u8, preferred: []const u8) !?InitialCollection {
    var it = try store.catalog.Iterator.init(bytes);
    const first = (try it.next()) orelse return null;
    var has_preferred = std.mem.eql(u8, first.heading, preferred);
    var multiple = false;
    while (try it.next()) |entry| {
        multiple = true;
        if (std.mem.eql(u8, entry.heading, preferred)) has_preferred = true;
    }
    if (has_preferred) return null; // Its listed file is missing; surface the original error.
    return .{ .heading = first.heading, .show_library = multiple };
}

fn openReader(io: std.Io, a: std.mem.Allocator, arena: std.mem.Allocator, opts: *args.Options, choose_language: *bool) !store.Store {
    return store.Store.open(io, a, opts.root, opts.kind, opts.language) catch |err| {
        if (err != error.FileNotFound or opts.command != .tui or opts.kind != .language or opts.language_explicit) return err;
        const path = try std.fs.path.join(arena, &.{ opts.root, store.catalog.manifest_filename });
        const catalog = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
        const choice = (try implicitCollection(catalog, opts.language)) orelse return err;
        opts.language = choice.heading;
        choose_language.* = choice.show_library;
        return store.Store.open(io, a, opts.root, opts.kind, opts.language);
    };
}

test "implicit terminal catalog choice preserves explicit or listed languages" {
    const h = store.catalog.manifest_header ++ "\n";
    try std.testing.expect(try implicitCollection(h, "English") == null);
    try std.testing.expect(try implicitCollection(h ++ "Aymar aru\nEnglish\n", "English") == null);
    try std.testing.expectError(error.InvalidManifest, implicitCollection(h ++ "Aymar aru\n\n", "English"));
    const single = (try implicitCollection(h ++ "română\n", "English")).?;
    try std.testing.expectEqualStrings("română", single.heading);
    try std.testing.expect(!single.show_library);
    const multi = (try implicitCollection(h ++ "Aymar aru\nRuso\n", "English")).?;
    try std.testing.expectEqualStrings("Aymar aru", multi.heading);
    try std.testing.expect(multi.show_library);
}

fn reportOpenError(io: std.Io, opts: args.Options, err: anyerror) !void {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    const w = &stderr.interface;
    if (err == error.FileNotFound and opts.kind == .language and opts.command != .install and
        opts.command != .languages and hasEmptyLanguageCatalog(io, opts.root))
    {
        try w.writeAll("dict: this dataset lists no language entries. Choose another dataset with --root PATH.\n");
        try w.flush();
        return;
    }
    if (opts.command == .install) {
        try w.writeAll("dict: could not install in ");
    } else if (opts.command == .languages) {
        try w.writeAll("dict: could not read the language catalogue in ");
    } else {
        try w.writeAll("dict: could not open ");
        try output.terminalText(w, if (opts.kind == .language) opts.language else @tagName(opts.kind));
        try w.writeAll(" in ");
    }
    try output.terminalText(w, opts.root);
    try w.print(" ({s}).\n", .{@errorName(err)});
    try w.writeAll(switch (err) {
        error.FileNotFound => if (opts.command == .languages)
            "The language catalogue or a listed dictionary file is missing. Reinstall missing dictionaries, or choose a completed dataset with --root PATH.\n"
        else
            "Choose an installed dataset with --root PATH.\nUse 'dict languages --root PATH' to check its language names.\nFor a new dictionary, run 'dict catalog', then 'dict install URL --root PATH'.\n",
        error.DictionaryBuildIncomplete => "This dataset is still being built. Wait for its build to finish or choose a completed dataset with --root PATH.\n",
        error.AccessDenied => "Check that you can read the dataset folder and its files, or choose another folder with --root PATH.\n",
        else => if (opts.command == .languages)
            "Check the language catalogue and its listed dictionary files, or choose a valid compiled dataset with --root PATH.\n"
        else
            "Check the selected language with 'dict languages --root PATH', or choose a valid compiled dataset with --root PATH.\n",
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
    _ = @import("terminal.zig");
    _ = desktop_dispatch;
    _ = args;
    _ = @import("languages.zig");
    _ = store;
    _ = model;
    _ = output;
    _ = tui;
    _ = @import("media_job.zig");
    _ = @import("reader_media.zig");
    _ = @import("media_types.zig");
    _ = @import("pipeline_tests.zig");
    _ = @import("library.zig");
    _ = @import("blob_storage");
}

fn populateSearch(a: std.mem.Allocator, gpa: std.mem.Allocator, db: *store.Store, opts: args.Options, response: *output.Response) !void {
    var task: search.Task = .{};
    defer task.deinit(gpa);
    const insensitive = !opts.case_sensitive and std.mem.trim(u8, opts.query, " \t\r\n").len != 0;
    const range = if (insensitive) blk: {
        const wanted = std.math.add(usize, opts.offset, opts.limit) catch return error.SearchWindowTooLarge;
        try task.beginLimited(gpa, opts.query, wanted);
        while (!task.complete) try task.step(gpa, db, 4096);
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
}

fn exportSession(io: std.Io, gpa: std.mem.Allocator, db: *store.Store, w: *std.Io.Writer) !u8 {
    var input_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &input_buffer);
    const r = &input.interface;
    var titles: [65536]u8 = undefined;
    var queries: [64][]const u8 = undefined;
    var hints: [64 * 64]u8 = undefined;
    while (true) {
        // Only EOF at a request boundary is an orderly stop.
        const count = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return err,
        };
        // Zero titles tags an empty-query browse at the following little-endian offset.
        if (count == 0) {
            const offset = std.math.cast(usize, try r.takeInt(u64, .little)) orelse return error.InvalidExportRequest;
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            try db.requireUnchanged();
            var page: output.Response = .{
                .operation = .search,
                .query = "",
                .kind = db.selectionKind(),
                .language = if (db.heading()) |heading| try model.utf8Text(a, heading) else null,
                .record_count = db.count(),
                .total_matches = 0,
            };
            try populateSearch(a, gpa, db, .{ .case_sensitive = true, .limit = 1000, .offset = offset }, &page);
            try output.json(w, page);
            try db.requireUnchanged();
            try w.writeByte('\n');
            try w.flush();
            continue;
        }
        if (count > queries.len) return error.InvalidExportRequest;
        const mode = try r.takeByte();
        if (mode > 2) return error.InvalidExportRequest;
        const batch_hints = if (mode != 0) hints[0 .. @as(usize, count) * 64] else null;
        if (batch_hints) |bytes| {
            try r.readSliceAll(bytes);
            for (bytes) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidExportRequest;
        }
        var offset: usize = 0;
        for (queries[0..count]) |*query| {
            var bytes: [4]u8 = undefined;
            try r.readSliceAll(&bytes);
            const length = std.mem.readInt(u32, &bytes, .little);
            if (length == 0 or length > titles.len - offset) return error.InvalidExportRequest;
            const title = titles[offset..][0..length];
            try r.readSliceAll(title);
            if (!std.unicode.utf8ValidateSlice(title) or std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidExportRequest;
            query.* = title;
            offset += length;
        }
        try db.requireUnchanged();
        const code = try exportBatch(gpa, db, queries[0..count], batch_hints, mode == 2, w);
        if (code != 0) return code;
        try db.requireUnchanged();
        // JSON lines cannot be empty. The verifier can commit one batch only
        // after receiving this separate completion record.
        try w.writeByte('\n');
        try w.flush();
    }
}

// One ordinary Store selection and the same exact lookup/decoder/Response as
// single export. Each line is independently associated by its unchanged query;
// duplicates remain duplicates. Stop after the first empty result or error.
fn exportBatch(gpa: std.mem.Allocator, db: *store.Store, queries: []const []const u8, hints: ?[]const u8, reuse_missing_language_target: bool, w: *std.Io.Writer) !u8 {
    for (queries, 0..) |query, position| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var response: output.Response = .{
            .operation = .lookup,
            .query = try model.utf8Text(a, query),
            .kind = db.selectionKind(),
            .language = if (db.heading()) |heading| try model.utf8Text(a, heading) else null,
            .record_count = db.count(),
            .total_matches = 0,
            .match_mode = "exact-utf8",
        };
        var audit: store.Store.AuditReference = .{
            .arena = a,
            .hint = if (hints) |values| values[position * 64 ..][0..64] else "",
            .reuse_missing_language_target = reuse_missing_language_target,
        };
        if (try db.find(query)) |index| {
            response.total_matches = 1;
            if (try db.recordAuditAlloc(gpa, index, if (hints != null) &audit else null)) |found| {
                var raw = found;
                defer raw.deinit();
                var doc = try model.fromRecord(gpa, raw.record);
                defer doc.deinit();
                response.entries = &.{doc.entry};
                try writeBatchResponse(w, response, if (hints != null) &audit else null);
            } else try writeBatchResponse(w, response, &audit);
        } else {
            try writeBatchResponse(w, response, if (hints != null) &audit else null);
            return 1;
        }
    }
    return 0;
}

fn writeBatchResponse(w: *std.Io.Writer, response: output.Response, audit: ?*const store.Store.AuditReference) !void {
    if (audit) |value| {
        try std.json.Stringify.value(.{
            .response = response,
            .reference = if (value.id) |*id| @as(?[]const u8, id) else null,
            .reused = value.reused,
        }, .{}, w);
    } else try std.json.Stringify.value(response, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}
