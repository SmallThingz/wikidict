const std = @import("std");

const decoder = @import("decoder");
const cli_args = @import("cli_args");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        printUsage();
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
        try cmdStats(init.io, args[2..]);
        return;
    }

    printUsage();
}

fn cmdLookup(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const term = cli_args.flagValue(args, "--word") orelse {
        printUsage();
        return;
    };
    const open_options = try openOptionsFromArgs(args);

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
    const db_path = cli_args.flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const prefix = cli_args.flagValue(args, "--prefix") orelse {
        printUsage();
        return;
    };
    const limit = (try cli_args.parseOptionalIntFlag(usize, args, "--limit")) orelse 12;
    const open_options = try openOptionsFromArgs(args);

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

fn cmdStats(io: std.Io, args: []const []const u8) !void {
    const db_path = cli_args.flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const open_options = try openOptionsFromArgs(args);
    var db = try decoder.openDictionaryWithOptions(std.heap.page_allocator, io, db_path, open_options);
    defer db.deinit();

    std.debug.print(
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

fn openOptionsFromArgs(args: []const []const u8) !decoder.OpenOptions {
    return .{
        .index_build_threads = try cli_args.parseOptionalIntFlag(usize, args, "--index-threads"),
    };
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

fn printUsage() void {
    std.debug.print(
        \\dict-decoder lookup  --db data/enwiktionary.bin --word colour [--index-threads 2]
        \\dict-decoder suggest --db data/enwiktionary.bin --prefix col [--limit 12] [--index-threads 2]
        \\dict-decoder stats   --db data/enwiktionary.bin [--index-threads 2]
        \\
    , .{});
}

test "lookupKindName maps known lookup kinds" {
    try std.testing.expectEqualStrings("title", lookupKindName(decoder.format.lookup_kind_title));
    try std.testing.expectEqualStrings("alternative_form", lookupKindName(decoder.format.lookup_kind_alternative_form));
    try std.testing.expectEqualStrings("alias_expansion", lookupKindName(2));
}
