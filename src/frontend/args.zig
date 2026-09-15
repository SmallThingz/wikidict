const std = @import("std");
const store = @import("store.zig");
pub const Command = enum { lookup, search, languages, stats, tui };
pub const Theme = enum { terminal, dark, light };
pub const Format = enum { text, json };
pub const Color = enum { auto, always, never };
pub const Options = struct {
    command: Command = .lookup,
    root: []const u8 = "data/wiktionary-blobs",
    kind: store.Kind = .language,
    language: []const u8 = "English",
    query: []const u8 = "",
    format: Format = .text,
    color: Color = .auto,
    theme: Theme = .terminal,
    limit: usize = 20,
    offset: usize = 0,
    details: bool = false,
    help: bool = false,
};
pub fn parse(argv: []const []const u8) !Options {
    var out: Options = .{};
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
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                out.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--details")) {
                out.details = true;
                continue;
            }
            if (pos + 1 >= argv.len) return error.Usage;
            pos += 1;
            const value = argv[pos];
            if (std.mem.eql(u8, arg, "--root")) out.root = value else if (std.mem.eql(u8, arg, "--language")) out.language = value else if (std.mem.eql(u8, arg, "--kind")) out.kind = store.parseKind(value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--format")) out.format = std.meta.stringToEnum(Format, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--theme")) out.theme = std.meta.stringToEnum(Theme, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--color")) out.color = std.meta.stringToEnum(Color, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--limit")) out.limit = std.fmt.parseInt(usize, value, 10) catch return error.Usage else if (std.mem.eql(u8, arg, "--offset")) out.offset = std.fmt.parseInt(usize, value, 10) catch return error.Usage else return error.Usage;
        } else {
            if (has_query) return error.Usage;
            out.query = arg;
            has_query = true;
        }
    }
    if (out.help) return out;
    if (out.limit == 0 or out.limit > 1000 or out.root.len == 0 or out.language.len == 0) return error.Usage;
    if (out.command == .lookup and (!has_query or out.query.len == 0)) return error.Usage;
    if (out.command == .stats and has_query) return error.Usage;
    if (out.command == .tui and out.format != .text) return error.Usage;
    if (out.offset != 0 and out.command != .search) return error.Usage;
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
