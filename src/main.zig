const std = @import("std");

const dict = @import("dict");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "build")) {
        try cmdBuild(init.io, allocator, args[2..]);
        return;
    }
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
    if (std.mem.eql(u8, command, "serve")) {
        try cmdServe(init, args[2..]);
        return;
    }

    printUsage();
}

fn cmdBuild(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const input = flagValue(args, "--input") orelse "enwiktionary.xml";
    const output = flagValue(args, "--output") orelse "data/enwiktionary.bin";
    const limit = if (flagValue(args, "--limit")) |value| try std.fmt.parseInt(usize, value, 10) else null;

    const stats = try dict.buildDictionary(io, allocator, .{
        .input_path = input,
        .output_path = output,
        .limit_entries = limit,
    });

    std.debug.print(
        "built {s}\npages={d}\nns0={d}\nentries={d}\nredirect_aliases={d}\n",
        .{ output, stats.pages_seen, stats.namespace_zero_pages, stats.english_entries, stats.redirect_aliases },
    );
}

fn cmdLookup(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const term = flagValue(args, "--word") orelse {
        printUsage();
        return;
    };

    var db = try dict.Dictionary.open(allocator, io, db_path);
    defer db.deinit();

    const hits = try db.lookupExact(allocator, term);
    if (hits.len == 0) {
        std.debug.print("no matches for {s}\n", .{term});
        return;
    }

    for (hits, 0..) |hit, idx| {
        const entry = db.entryAt(hit.entry_index);
        std.debug.print("\n[{d}] {s}", .{ idx + 1, entry.word() });
        if (!std.mem.eql(u8, hit.matched, entry.word())) {
            std.debug.print(" (matched via {s})", .{hit.matched});
        }
        if (entry.isAliasOnly()) {
            std.debug.print(" [alias]\n", .{});
        } else {
            std.debug.print("\n", .{});
        }

        if (entry.canonicalTargets().len != 0) {
            std.debug.print("canonical: ", .{});
            printStringList(entry.canonicalTargets());
        }
        if (entry.altForms().len != 0) {
            std.debug.print("alternative forms: ", .{});
            printStringList(entry.altForms());
        }
        if (entry.incomingAliases().len != 0) {
            std.debug.print("also spelled as: ", .{});
            printStringList(entry.incomingAliases());
        }
        if (try entry.rawEnglishAlloc(allocator)) |raw| {
            std.debug.print("{s}\n", .{raw});
        }
    }
}

fn cmdSuggest(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
    const prefix = flagValue(args, "--prefix") orelse {
        printUsage();
        return;
    };
    const limit = if (flagValue(args, "--limit")) |value| try std.fmt.parseInt(usize, value, 10) else 12;

    var db = try dict.Dictionary.open(allocator, io, db_path);
    defer db.deinit();

    const hits = try db.suggest(allocator, prefix, limit);
    for (hits) |hit| {
        const entry = db.entryAt(hit.entry_index);
        std.debug.print("{s} -> {s}\n", .{ hit.matched, entry.word() });
    }
}

fn cmdStats(io: std.Io, args: []const []const u8) !void {
    const db_path = flagValue(args, "--db") orelse "data/enwiktionary.bin";
    var db = try dict.Dictionary.open(std.heap.page_allocator, io, db_path);
    defer db.deinit();

    std.debug.print(
        "entries={d}\nraw_entries={d}\nredirects={d}\nlookups={d}\nrecords={d}\n",
        .{
            db.header.entry_count,
            db.header.raw_entry_count,
            db.header.redirect_count,
            db.lookups.len,
            db.header.records_len,
        },
    );
}

fn cmdServe(init: std.process.Init, args: []const []const u8) !void {
    try dict.serveDictionary(init.io, init.gpa, args);
}

fn printStringList(values: []const []const u8) void {
    for (values, 0..) |value, idx| {
        if (idx != 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{value});
    }
    std.debug.print("\n", .{});
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
        \\dict build   --input enwiktionary.xml --output data/enwiktionary.bin [--limit 10000]
        \\dict lookup  --db data/enwiktionary.bin --word colour
        \\dict suggest --db data/enwiktionary.bin --prefix col [--limit 12]
        \\dict stats   --db data/enwiktionary.bin
        \\dict serve   --db data/enwiktionary.bin [--port 3000]
        \\
    , .{});
}
