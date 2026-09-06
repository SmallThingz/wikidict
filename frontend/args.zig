const std = @import("std");
const store = @import("store.zig");
pub const Command = enum { lookup, search, languages, stats, tui };
pub const Theme = enum { terminal, dark, light };
pub const Format = enum { text, json, source, html };
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
    with_source: bool = false,
    trusted: bool = false,
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
    if (std.meta.stringToEnum(Command, argv[0])) |command| out.command = command else {
        // Retain the documented query-blobs positional entrypoint; remove its old diagnostic renderer.
        if (argv.len < 3) return error.Usage;
        out.root = argv[0];
        out.kind = store.parseKind(argv[1]) orelse return error.Usage;
        pos = 2;
        if (out.kind == .language) {
            if (argv.len < 4) return error.Usage;
            out.language = argv[pos];
            pos += 1;
        }
        out.query = argv[pos];
        pos += 1;
        has_query = true;
    }
    var positional_only = false;
    while (pos < argv.len) : (pos += 1) {
        const arg = argv[pos];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                out.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--with-source")) {
                out.with_source = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--trusted")) {
                out.trusted = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--validate")) {
                out.trusted = false;
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
    if ((out.command == .stats or out.command == .languages) and has_query) return error.Usage;
    if (out.format == .source and out.command != .lookup) return error.Usage;
    if (out.format == .html and out.command != .lookup and out.command != .search) return error.Usage;
    if (out.command == .tui and out.format != .text) return error.Usage;
    if (out.offset != 0 and out.command != .search) return error.Usage;
    return out;
}
test "CLI options are strict and legacy query syntax still works" {
    const old = try parse(&.{ ".tmp/blobs", "language", "French", "chat", "--validate" });
    try std.testing.expectEqualStrings("chat", old.query);
    try std.testing.expectEqualStrings("French", old.language);
    const opts = try parse(&.{ "search", "--format", "json", "--limit", "3", "--", "-a" });
    try std.testing.expectEqualStrings("-a", opts.query);
    try std.testing.expectEqual(@as(usize, 3), opts.limit);
    try std.testing.expectError(error.Usage, parse(&.{"lookup"}));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "--format", "source" }));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "--limit", "0" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "unexpected" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--wat", "yes" }));
}

test "frontend formats and terminal options reject invalid combinations" {
    try std.testing.expectEqual(Command.tui, (try parse(&.{ "tui", "cat", "--theme", "dark" })).command);
    try std.testing.expectEqual(Format.html, (try parse(&.{ "search", "cat", "--format", "html" })).format);
    try std.testing.expectError(error.Usage, parse(&.{ "tui", "--format", "json" }));
    try std.testing.expectError(error.Usage, parse(&.{ "languages", "--format", "html" }));
    try std.testing.expectError(error.Usage, parse(&.{ "tui", "--theme", "unknown" }));
}
