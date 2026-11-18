const std = @import("std");
const store = @import("store.zig");
const search = @import("search.zig");
pub const Command = enum { lookup, search, languages, stats, tui, catalog, install, saved, history, save, unsave };
pub const Theme = enum { terminal, dark, light };
pub const Format = enum { text, json };
pub const Color = enum { auto, always, never };
pub const Options = struct {
    command: Command = .lookup,
    root: []const u8 = "data/wiktionary-blobs",
    kind: store.Kind = .language,
    language: []const u8 = "English",
    language_explicit: bool = false,
    query: []const u8 = "",
    // Borrowed literal argv tail; only explicit bounded exact export uses it.
    batch_queries: []const []const u8 = &.{},
    batch_audit_hints: ?[]const u8 = null,
    format: Format = .text,
    color: Color = .auto,
    theme: Theme = .terminal,
    limit: usize = 20,
    offset: usize = 0,
    details: bool = false,
    case_sensitive: bool = false,
    sha256: []const u8 = "",
    help: bool = false,
};
pub fn parse(argv: []const []const u8) !Options {
    return parseWithDefaults(argv, .{});
}
pub fn parseWithDefaults(argv: []const []const u8, defaults: Options) !Options {
    var out = defaults;
    if (argv.len == 0) {
        out.help = true;
        return out;
    }
    if (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        out.help = true;
        return out;
    }
    var pos: usize = 1;
    var has_query = false;
    var batch_export = false;
    var positional_only = false;
    if (std.mem.eql(u8, argv[0], "--")) {
        out.command = .lookup;
        positional_only = true;
    } else if (std.mem.startsWith(u8, argv[0], "-") and !std.mem.eql(u8, argv[0], "-")) {
        // Lookup is the default command, so common options may precede WORD.
        // Command-specific options still use an explicit command first.
        out.command = .lookup;
        pos = 0;
    } else if (std.mem.eql(u8, argv[0], "serve")) {
        return error.Usage;
    } else if (std.mem.eql(u8, argv[0], "export")) {
        out.command = .lookup;
        out.format = .json;
    } else if (std.meta.stringToEnum(Command, argv[0])) |command| out.command = command else {
        out.command = .lookup;
        out.query = argv[0];
        has_query = true;
    }
    while (pos < argv.len) : (pos += 1) {
        const arg = argv[pos];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            if (batch_export) {
                out.batch_queries = argv[pos + 1 ..];
                if (out.batch_queries.len == 0 or out.batch_queries.len > 64) return error.Usage;
                var bytes: usize = 0;
                for (out.batch_queries) |query| {
                    if (query.len == 0 or query.len > 65536 - bytes) return error.Usage;
                    bytes += query.len;
                }
                out.query = out.batch_queries[0];
                has_query = true;
                break;
            }
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                out.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--batch")) {
                if (!std.mem.eql(u8, argv[0], "export") or batch_export or has_query) return error.Usage;
                batch_export = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--details")) {
                out.details = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--case-sensitive")) {
                out.case_sensitive = true;
                continue;
            }
            if (pos + 1 >= argv.len) return error.Usage;
            pos += 1;
            const value = argv[pos];
            if (std.mem.eql(u8, arg, "--audit-reference-hints")) {
                if (out.batch_audit_hints != null) return error.Usage;
                out.batch_audit_hints = value;
            } else if (std.mem.eql(u8, arg, "--sha256")) out.sha256 = value else if (std.mem.eql(u8, arg, "--root")) out.root = value else if (std.mem.eql(u8, arg, "--language")) {
                out.language = value;
                out.language_explicit = true;
            } else if (std.mem.eql(u8, arg, "--kind")) out.kind = store.parseKind(value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--format")) out.format = std.meta.stringToEnum(Format, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--theme")) out.theme = std.meta.stringToEnum(Theme, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--color")) out.color = std.meta.stringToEnum(Color, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--limit")) out.limit = std.fmt.parseInt(usize, value, 10) catch return error.Usage else if (std.mem.eql(u8, arg, "--offset")) out.offset = std.fmt.parseInt(usize, value, 10) catch return error.Usage else return error.Usage;
        } else {
            if (has_query or batch_export) return error.Usage;
            out.query = arg;
            has_query = true;
        }
    }
    if (out.help) return out;
    if (batch_export and (out.batch_queries.len == 0 or !out.case_sensitive or out.format != .json)) return error.Usage;
    if (out.batch_audit_hints) |hints| {
        if (!batch_export or hints.len != out.batch_queries.len * 64) return error.Usage;
        for (hints) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.Usage;
    }
    if (out.limit == 0 or out.limit > 1000 or out.root.len == 0 or out.language.len == 0) return error.Usage;
    if ((out.command == .lookup or out.command == .save or out.command == .unsave or out.command == .install) and (!has_query or out.query.len == 0)) return error.Usage;
    if ((out.command == .stats or out.command == .saved or out.command == .history) and has_query) return error.Usage;
    if (out.command == .tui and out.format != .text) return error.Usage;
    if (out.offset != 0 and out.command != .search and out.command != .saved and out.command != .history) return error.Usage;
    if (out.command == .search and !out.case_sensitive and std.mem.trim(u8, out.query, " \t\r\n").len != 0 and
        (out.offset > search.max_retained_matches or out.limit > search.max_retained_matches - out.offset)) return error.Usage;
    return out;
}
test "CLI options are strict and lookup shorthand is unambiguous" {
    const opts = try parse(&.{ "search", "--format", "json", "--limit", "3", "--", "-a" });
    try std.testing.expectEqualStrings("-a", opts.query);
    try std.testing.expectEqual(@as(usize, 3), opts.limit);
    const dashed = try parse(&.{ "--", "-dash" });
    try std.testing.expectEqual(Command.lookup, dashed.command);
    try std.testing.expectEqualStrings("-dash", dashed.query);
    try std.testing.expectError(error.Usage, parse(&.{ "--", "-dash", "extra" }));
    try std.testing.expectError(error.Usage, parse(&.{"lookup"}));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "--limit", "0" }));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "cat", "--offset", "131000", "--limit", "1000" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "unexpected" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--wat", "yes" }));

    const leading = try parse(&.{ "--language", "French", "--format", "json", "chat" });
    try std.testing.expectEqual(Command.lookup, leading.command);
    try std.testing.expectEqualStrings("chat", leading.query);
    try std.testing.expectEqualStrings("French", leading.language);
    try std.testing.expectEqual(Format.json, leading.format);
    const bare = try parse(&.{ "cat", "--language", "French" });
    try std.testing.expectEqual(Command.lookup, bare.command);
    try std.testing.expectEqualStrings("cat", bare.query);
    try std.testing.expectEqualStrings("French", bare.language);

    // Old positional ROOT/KIND syntax is gone; a non-command first token is always WORD.
    try std.testing.expectError(error.Usage, parse(&.{ ".tmp/blobs", "citations", "example" }));
}

test "audit references require one lowercase digest per exact batch query" {
    const hint = "0000000000000000000000000000000000000000000000000000000000000000";
    const parsed = try parse(&.{ "export", "--case-sensitive", "--batch", "--audit-reference-hints", hint, "--", "old" });
    try std.testing.expectEqualStrings(hint, parsed.batch_audit_hints.?);
    try std.testing.expectError(error.Usage, parse(&.{ "export", "--case-sensitive", "--batch", "--audit-reference-hints", hint, "--", "old", "another" }));
    try std.testing.expectError(error.Usage, parse(&.{ "export", "--case-sensitive", "--batch", "--audit-reference-hints", hint[1..] ++ "G", "--", "old" }));
    try std.testing.expectError(error.Usage, parse(&.{ "export", "--audit-reference-hints", hint, "--", "old" }));
}

test "frontend formats and terminal options reject invalid combinations" {
    try std.testing.expectEqual(Command.tui, (try parse(&.{ "tui", "cat", "--theme", "dark" })).command);
    try std.testing.expectEqual(Format.json, (try parse(&.{ "search", "cat", "--format", "json" })).format);
    try std.testing.expectError(error.Usage, parse(&.{ "tui", "--format", "json" }));
    try std.testing.expectError(error.Usage, parse(&.{ "languages", "--format", "html" }));
    try std.testing.expectError(error.Usage, parse(&.{ "tui", "--theme", "unknown" }));
}

test "removed runtime and web options stay rejected" {
    try std.testing.expectError(error.Usage, parse(&.{ "serve", "--root", "data" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--runtime", "runtime" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--runtime-timeout-ms", "200" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--native" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--trusted" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--validate" }));
}

test "language accounting can be scoped to a spelling rather than the whole catalog" {
    const opts = try parse(&.{ "languages", "cat", "--format", "json" });
    try std.testing.expectEqualStrings("cat", opts.query);
    try std.testing.expectEqual(Command.languages, opts.command);
}

test "export remains a JSON lookup alias" {
    const json = try parse(&.{ "export", "cats" });
    try std.testing.expectEqual(Command.lookup, json.command);
    try std.testing.expectEqual(Format.json, json.format);
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--format", "html" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--port", "5" }));
}

test "reader commands and configured defaults remain explicit" {
    const defaults: Options = .{ .root = "my dictionaries", .language = "French" };
    const configured = try parseWithDefaults(&.{"chat"}, defaults);
    try std.testing.expectEqualStrings(defaults.root, configured.root);
    const override = try parseWithDefaults(&.{ "chat", "--root", "local", "--language", "English" }, defaults);
    try std.testing.expectEqualStrings("local", override.root);
    try std.testing.expectEqualStrings("English", override.language);
    try std.testing.expect(override.language_explicit);
    try std.testing.expect(!(try parse(&.{"tui"})).language_explicit);
    try std.testing.expect((try parseWithDefaults(&.{"tui"}, .{ .language = "English", .language_explicit = true })).language_explicit);
    try std.testing.expectEqual(Command.save, (try parse(&.{ "save", "cat" })).command);
    try std.testing.expectEqual(@as(usize, 20), (try parse(&.{ "saved", "--offset", "20" })).offset);
    try std.testing.expectError(error.Usage, parse(&.{"save"}));
    try std.testing.expectError(error.Usage, parse(&.{"install"}));
    try std.testing.expectError(error.Usage, parse(&.{ "history", "cat" }));
}

test "direct prefix pagination bypasses only the folded retention limit" {
    const a = std.testing.allocator;
    const boundary = try std.fmt.allocPrint(a, "{d}", .{search.max_retained_matches});
    defer a.free(boundary);
    const last_retained = try std.fmt.allocPrint(a, "{d}", .{search.max_retained_matches - 1});
    defer a.free(last_retained);
    const maximum_offset = try std.fmt.allocPrint(a, "{d}", .{std.math.maxInt(usize)});
    defer a.free(maximum_offset);

    // Browsing uses a direct prefix range, without retaining preceding matches.
    const browse = try parse(&.{ "search", "--offset", boundary, "--limit", "1000" });
    try std.testing.expectEqualStrings("", browse.query);
    try std.testing.expectEqual(search.max_retained_matches, browse.offset);
    try std.testing.expectEqual(@as(usize, 1000), browse.limit);
    inline for (.{ "", " \t\r\n" }) |query| {
        const empty = try parse(&.{ "search", query, "--offset", maximum_offset, "--limit", "1000" });
        try std.testing.expectEqualStrings(query, empty.query);
        try std.testing.expect(!empty.case_sensitive);
        try std.testing.expectEqual(std.math.maxInt(usize), empty.offset);
    }
    const exact = try parse(&.{ "search", "cat", "--case-sensitive", "--offset", maximum_offset, "--limit", "1000" });
    try std.testing.expect(exact.case_sensitive);
    try std.testing.expectEqualStrings("cat", exact.query);
    try std.testing.expectEqual(std.math.maxInt(usize), exact.offset);

    // Folded search still retains offset + limit, including its last valid slot.
    inline for (.{ "cat", " cat " }) |query| {
        const folded = try parse(&.{ "search", query, "--offset", last_retained, "--limit", "1" });
        try std.testing.expect(!folded.case_sensitive);
        try std.testing.expectEqual(search.max_retained_matches - 1, folded.offset);
        try std.testing.expectEqual(@as(usize, 1), folded.limit);
        try std.testing.expectError(error.Usage, parse(&.{ "search", query, "--offset", last_retained, "--limit", "2" }));
        try std.testing.expectError(error.Usage, parse(&.{ "search", query, "--offset", boundary, "--limit", "1" }));
        try std.testing.expectError(error.Usage, parse(&.{ "search", query, "--offset", maximum_offset, "--limit", "1" }));
    }
    try std.testing.expectError(error.Usage, parse(&.{ "search", "--offset", boundary, "--limit", "1001" }));
}

test "bounded exact export batches preserve literal order duplicates and dash titles" {
    const selected = try parse(&.{ "export", "--batch", "--case-sensitive", "--", "猫", "-dash", "猫" });
    try std.testing.expectEqual(@as(usize, 3), selected.batch_queries.len);
    for ([_][]const u8{ "猫", "-dash", "猫" }, selected.batch_queries) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings("猫", selected.query);
    try std.testing.expect((try parse(&.{ "export", "cat" })).batch_queries.len == 0);
    for ([_][]const []const u8{
        &.{ "lookup", "--batch", "--case-sensitive", "--", "cat" },
        &.{ "export", "--batch", "--", "cat" },
        &.{ "export", "--batch", "--case-sensitive", "cat" },
        &.{ "export", "--batch", "cat", "--case-sensitive", "--", "dog" },
        &.{ "export", "--batch", "--case-sensitive", "--" },
        &.{ "export", "--batch", "--case-sensitive", "--", "" },
        &.{ "export", "--batch", "--case-sensitive", "--format", "text", "--", "cat" },
        &.{ "export", "cat", "--batch", "--case-sensitive", "--", "dog" },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid));
    var many: [69][]const u8 = @splat("cat");
    many[0] = "export"; many[1] = "--batch"; many[2] = "--case-sensitive"; many[3] = "--";
    try std.testing.expectError(error.Usage, parse(&many));
    const long: [65537]u8 = @splat('x');
    try std.testing.expectError(error.Usage, parse(&.{ "export", "--batch", "--case-sensitive", "--", &long }));
}
