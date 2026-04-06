const std = @import("std");

const decoder = @import("decoder");
const cli_args = @import("cli_args");
const required_path = @import("required_path");
const tool_paths = @import("tool_paths");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        try printUsage(init.io, allocator);
        return;
    }
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "help") or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
        try printUsage(init.io, allocator);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "lookup")) {
        try cmdLookup(init.io, allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "suggest")) {
        try cmdSuggest(init.io, allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "stats")) {
        try cmdStats(init.io, allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "index")) {
        try cmdIndex(init.io, allocator, args[2..]);
        return;
    }

    try printUsage(init.io, allocator);
}

fn cmdLookup(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/wiktionary.bin";
    const input_path = cli_args.flagValue(args, "--input") orelse "data/wiktionary.xml";
    const term = cli_args.flagValue(args, "--word") orelse {
        try printUsage(io, allocator);
        return;
    };
    const open_options = try openOptionsFromArgs(args);
    ensureDictionaryExists(io, allocator, input_path, db_path, null);

    var db = try decoder.openDictionaryWithOptions(allocator, io, db_path, open_options);
    defer db.deinit();

    const hits = try db.lookupExact(allocator, term);
    if (hits.len == 0) {
        std.debug.print("No matches for {s}\n", .{term});
        try printLookupJson(allocator, db_path, term, &.{}, &db);
        return;
    }

    for (hits, 0..) |hit, idx| {
        if (idx != 0) std.debug.print("\n", .{});
        const entry = db.entryAt(hit.entry_index);
        try printHit(allocator, entry, hit, idx + 1);
    }

    try printLookupJson(allocator, db_path, term, hits, &db);
}

fn cmdSuggest(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/wiktionary.bin";
    const input_path = cli_args.flagValue(args, "--input") orelse "data/wiktionary.xml";
    const prefix = cli_args.flagValue(args, "--prefix") orelse {
        try printUsage(io, allocator);
        return;
    };
    const limit = (try cli_args.parseOptionalIntFlag(usize, args, "--limit")) orelse 12;
    const open_options = try openOptionsFromArgs(args);
    ensureDictionaryExists(io, allocator, input_path, db_path, null);

    var db = try decoder.openDictionaryWithOptions(allocator, io, db_path, open_options);
    defer db.deinit();

    const hits = try db.suggest(allocator, prefix, limit);
    for (hits, 0..) |hit, idx| {
        const entry = db.entryAt(hit.entry_index);
        std.debug.print(
            "{d:>2}. {s} -> {s} [{s}]\n",
            .{
                idx + 1,
                hit.matched,
                entry.word(),
                switch (hit.kind) {
                    decoder.format.lookup_kind_alternative_form => "alternative_form",
                    2 => "alias_expansion",
                    else => "title",
                },
            },
        );
    }
}

fn cmdStats(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/wiktionary.bin";
    const input_path = cli_args.flagValue(args, "--input") orelse "data/wiktionary.xml";
    const open_options = try openOptionsFromArgs(args);
    ensureDictionaryExists(io, allocator, input_path, db_path, null);
    var db = try decoder.openDictionaryWithOptions(std.heap.page_allocator, io, db_path, open_options);
    defer db.deinit();

    try printStdOut(
        io,
        allocator,
        "path: {s}\nentries: {d}\nraw entries: {d}\nredirects: {d}\nlookups: {d}\nrecord bytes: {d}\n",
        .{
            db_path,
            db.header.entry_count,
            db.header.raw_entry_count,
            db.header.redirect_count,
            db.lookups.len,
            db.header.records_len,
        },
    );
}

fn cmdIndex(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/wiktionary.bin";
    const input_path = cli_args.flagValue(args, "--input") orelse "data/wiktionary.xml";
    const build_limit = try cli_args.parseOptionalIntFlag(usize, args, "--limit");
    const open_options = try openOptionsFromArgs(args);
    ensureDictionaryExists(io, allocator, input_path, db_path, build_limit);

    var db = try decoder.openDictionaryWithOptions(std.heap.page_allocator, io, db_path, open_options);
    defer db.deinit();

    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{db_path});
    defer allocator.free(idx_path);
    try printStdOut(io, allocator, "indexed {s}\ncache: {s}\nlookups: {d}\n", .{ db_path, idx_path, db.lookups.len });
}

fn openOptionsFromArgs(args: []const []const u8) !decoder.OpenOptions {
    return .{
        .index_build_threads = try cli_args.parseOptionalIntFlag(usize, args, "--index-threads"),
        .structure_path = cli_args.flagValue(args, "--structure"),
    };
}

fn ensureDictionaryExists(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8, db_path: []const u8, build_limit: ?usize) void {
    const found = required_path.exists(io, db_path) catch |err| {
        std.debug.print("failed to access dictionary at {s}: {s}\n", .{ db_path, @errorName(err) });
        std.process.exit(1);
    };
    if (found) return;

    std.debug.print("dictionary not found: {s}; running {s}\n", .{ db_path, tool_paths.encoder_bin_path });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "--input") catch unreachable;
    argv.append(allocator, input_path) catch unreachable;
    argv.append(allocator, "--output") catch unreachable;
    argv.append(allocator, db_path) catch unreachable;
    if (build_limit) |limit| {
        const limit_text = std.fmt.allocPrint(allocator, "{d}", .{limit}) catch unreachable;
        defer allocator.free(limit_text);
        argv.append(allocator, "--limit") catch unreachable;
        argv.append(allocator, limit_text) catch unreachable;
    }
    required_path.runToolOrExit(io, allocator, tool_paths.encoder_bin_path, "encoder binary", argv.items);
}

fn printHit(
    allocator: std.mem.Allocator,
    entry: decoder.EntryView,
    hit: decoder.LookupHit,
    rank: usize,
) !void {
    var derived = try entry.derivedAlloc(allocator);
    defer derived.deinit(allocator);
    const normalized = try entry.normalizedAlloc(allocator);
    defer allocator.free(normalized);

    std.debug.print("========== Match {d} ==========\n", .{rank});
    std.debug.print("Word: {s}\n", .{entry.word()});
    std.debug.print("Matched: {s} ({s})\n", .{
        hit.matched,
        lookupKindName(hit.kind),
    });
    std.debug.print("Normalized: {s}\n", .{normalized});
    if (derived.alias_only) std.debug.print("Entry type: alias-style\n", .{});
    if (derived.alias_hint_label.len != 0) std.debug.print("Alias hint: {s}\n", .{derived.alias_hint_label});
    if (derived.summary.len != 0) std.debug.print("Summary: {s}\n", .{derived.summary});
    if (derived.canonical_targets.items.len != 0) {
        std.debug.print("Canonical: ", .{});
        for (derived.canonical_targets.items, 0..) |value, idx| {
            if (idx != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{value});
        }
        std.debug.print("\n", .{});
    }
    if (derived.alt_forms.items.len != 0) {
        std.debug.print("Alternative forms: ", .{});
        for (derived.alt_forms.items, 0..) |value, idx| {
            if (idx != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{value});
        }
        std.debug.print("\n", .{});
    }
    const incoming_aliases = entry.incomingAliases();
    if (incoming_aliases.len() != 0) {
        std.debug.print("Incoming aliases: ", .{});
        for (0..incoming_aliases.len()) |idx| {
            if (idx != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{incoming_aliases.at(idx)});
        }
        std.debug.print("\n", .{});
    }

    if (try entry.rawEnglishAlloc(allocator)) |raw| {
        defer allocator.free(raw);
        std.debug.print("\nSource\n------\n{s}\n", .{raw});
    } else {
        std.debug.print("\nSource\n------\n<no raw English section stored>\n", .{});
    }
}

fn printLookupJson(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    query: []const u8,
    hits: []const decoder.LookupHit,
    db: *const decoder.Dictionary,
) !void {
    var entries = std.ArrayList(MachineLookupHit).empty;
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    try entries.ensureTotalCapacity(allocator, hits.len);
    for (hits, 0..) |hit, idx| {
        const entry = db.entryAt(hit.entry_index);
        try entries.append(allocator, try machineLookupHitAlloc(allocator, entry, hit, idx + 1));
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var json_stream: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json_stream.write(.{
        .command = "lookup",
        .db_path = db_path,
        .query = query,
        .match_count = hits.len,
        .matches = entries.items,
    });

    std.debug.print(
        "\nMachine\n-------\n{s}\n",
        .{writer.written()},
    );
}

const MachineLookupHit = struct {
    rank: usize,
    entry_index: u32,
    word: []const u8,
    matched: []const u8,
    match_kind: []const u8,
    normalized: []const u8,
    alias_only: bool,
    alias_hint_label: []const u8,
    summary: []const u8,
    canonical_targets: [][]const u8,
    alternative_forms: [][]const u8,
    incoming_aliases: []const []const u8,
    raw_english: ?[]const u8,

    fn deinit(self: *MachineLookupHit, allocator: std.mem.Allocator) void {
        allocator.free(self.normalized);
        allocator.free(self.alias_hint_label);
        allocator.free(self.summary);
        allocator.free(self.canonical_targets);
        allocator.free(self.alternative_forms);
        allocator.free(self.incoming_aliases);
        if (self.raw_english) |raw| allocator.free(raw);
    }
};

fn machineLookupHitAlloc(
    allocator: std.mem.Allocator,
    entry: decoder.EntryView,
    hit: decoder.LookupHit,
    rank: usize,
) !MachineLookupHit {
    var derived = try entry.derivedAlloc(allocator);
    defer derived.deinit(allocator);

    const normalized = try entry.normalizedAlloc(allocator);
    errdefer allocator.free(normalized);

    const alias_hint_label = try allocator.dupe(u8, derived.alias_hint_label);
    errdefer allocator.free(alias_hint_label);

    const summary = try allocator.dupe(u8, derived.summary);
    errdefer allocator.free(summary);

    const canonical_targets = try dupSliceOfSlices(allocator, derived.canonical_targets.items);
    errdefer allocator.free(canonical_targets);

    const alternative_forms = try dupSliceOfSlices(allocator, derived.alt_forms.items);
    errdefer allocator.free(alternative_forms);

    const incoming_aliases = try entry.incomingAliases().toOwnedSlice(allocator);
    errdefer allocator.free(incoming_aliases);

    const raw_english = try entry.rawEnglishAlloc(allocator);
    errdefer if (raw_english) |raw| allocator.free(raw);

    return .{
        .rank = rank,
        .entry_index = hit.entry_index,
        .word = entry.word(),
        .matched = hit.matched,
        .match_kind = lookupKindName(hit.kind),
        .normalized = normalized,
        .alias_only = derived.alias_only,
        .alias_hint_label = alias_hint_label,
        .summary = summary,
        .canonical_targets = canonical_targets,
        .alternative_forms = alternative_forms,
        .incoming_aliases = incoming_aliases,
        .raw_english = raw_english,
    };
}

fn dupSliceOfSlices(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    @memcpy(out, values);
    return out;
}

fn lookupKindName(kind: u8) []const u8 {
    return switch (kind) {
        decoder.format.lookup_kind_alternative_form => "alternative_form",
        2 => "alias_expansion",
        else => "title",
    };
}

fn printUsage(io: std.Io, allocator: std.mem.Allocator) !void {
    try printStdOut(io, allocator,
        \\dict-decoder lookup  --db data/wiktionary.bin [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json] --word colour [--index-threads 2]
        \\dict-decoder suggest --db data/wiktionary.bin [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json] --prefix col [--limit 12] [--index-threads 2]
        \\dict-decoder index   --db data/wiktionary.bin [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json] [--index-threads 2]
        \\dict-decoder stats   --db data/wiktionary.bin [--input data/wiktionary.xml] [--structure data/wiktionary-structure.json] [--index-threads 2]
        \\
    , .{});
}

fn printStdOut(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

test "lookupKindName maps known lookup kinds" {
    try std.testing.expectEqualStrings("title", lookupKindName(decoder.format.lookup_kind_title));
    try std.testing.expectEqualStrings("alternative_form", lookupKindName(decoder.format.lookup_kind_alternative_form));
    try std.testing.expectEqualStrings("alias_expansion", lookupKindName(2));
}
