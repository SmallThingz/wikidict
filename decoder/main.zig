const std = @import("std");

const decoder = @import("decoder");

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
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const term = flagValue(args, "--word") orelse {
        printUsage();
        return;
    };
    const open_options = try openOptionsFromArgs(args);

    var db = try decoder.openDictionaryWithOptions(allocator, io, db_path, open_options);
    defer db.deinit();

    const hits = try db.lookupExact(allocator, term);
    if (hits.len == 0) {
        std.debug.print("No matches for {s}\n", .{term});
        return;
    }

    for (hits, 0..) |hit, idx| {
        if (idx != 0) std.debug.print("\n", .{});
        const entry = db.entryAt(hit.entry_index);
        try printHit(allocator, entry, hit, idx + 1);
    }
}

fn cmdSuggest(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const prefix = flagValue(args, "--prefix") orelse {
        printUsage();
        return;
    };
    const limit = if (flagValue(args, "--limit")) |value| try std.fmt.parseInt(usize, value, 10) else 12;
    const open_options = try openOptionsFromArgs(args);

    var db = try decoder.openDictionaryWithOptions(allocator, io, db_path, open_options);
    defer db.deinit();

    const hits = try db.suggest(allocator, prefix, limit);
    for (hits, 0..) |hit, idx| {
        const entry = db.entryAt(hit.entry_index);
        std.debug.print(
            "{d:>2}. {s} -> {s} [{s}]\n",
            .{ idx + 1, hit.matched, entry.word(), lookupKindString(hit.kind) },
        );
    }
}

fn cmdStats(io: std.Io, args: []const []const u8) !void {
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
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
        .index_build_threads = if (flagValue(args, "--index-threads")) |value|
            try std.fmt.parseInt(usize, value, 10)
        else
            null,
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
    std.debug.print("Matched: {s} ({s})\n", .{ hit.matched, lookupKindString(hit.kind) });
    std.debug.print("Normalized: {s}\n", .{normalized});
    if (derived.alias_only) std.debug.print("Entry type: alias-style\n", .{});
    if (derived.summary.len != 0) std.debug.print("Summary: {s}\n", .{derived.summary});
    printOwnedList("Canonical", derived.canonical_targets.items);
    printOwnedList("Alternative forms", derived.alt_forms.items);
    printList("Incoming aliases", entry.incomingAliases());

    if (try entry.rawEnglishAlloc(allocator)) |raw| {
        defer allocator.free(raw);
        std.debug.print("\nSource\n------\n{s}\n", .{raw});
    } else {
        std.debug.print("\nSource\n------\n<no raw English section stored>\n", .{});
    }
}

fn printOwnedList(label: []const u8, values: []const []const u8) void {
    if (values.len == 0) return;
    std.debug.print("{s}: ", .{label});
    for (values, 0..) |value, idx| {
        if (idx != 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{value});
    }
    std.debug.print("\n", .{});
}

fn printList(label: []const u8, values: decoder.TermListView) void {
    if (values.len() == 0) return;
    std.debug.print("{s}: ", .{label});
    for (0..values.len()) |idx| {
        if (idx != 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{values.at(idx)});
    }
    std.debug.print("\n", .{});
}

fn lookupKindString(kind: u8) []const u8 {
    return if (kind == decoder.format.lookup_kind_alternative_form) "alternative_form" else "title";
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn printUsage() void {
    std.debug.print(
        \\dict-decoder lookup  --db data/enwiktionary.bin --word colour [--index-threads 2]
        \\dict-decoder suggest --db data/enwiktionary.bin --prefix col [--limit 12] [--index-threads 2]
        \\dict-decoder stats   --db data/enwiktionary.bin [--index-threads 2]
        \\
    , .{});
}
