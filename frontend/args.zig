const std = @import("std");
const store = @import("store.zig");
pub const Command = enum { lookup, search, languages, stats, tui, render };
pub const Theme = enum { terminal, dark, light };
pub const Format = enum { text, json, source, html };
pub const Color = enum { auto, always, never };
pub const Options = struct {
    runtime: ?[]const u8 = null,
    media_dir: ?[]const u8 = null,
    runtime_timeout_ms: u32 = 60000,
    native: bool = false,
    command: Command = .lookup,
    root: []const u8 = "data/wiktionary-blobs",
    kind: store.Kind = .language,
    language: []const u8 = "English",
    query: []const u8 = "",
    title: []const u8 = "Entry",
    format: Format = .text,
    color: Color = .auto,
    theme: Theme = .terminal,
    limit: usize = 20,
    offset: usize = 0,
    with_source: bool = false,
    details: bool = false,
    core_only: bool = false,
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
        if (!positional_only and std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                out.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--core-only")) {
                out.core_only = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--native")) {
                out.native = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--details")) {
                out.details = true;
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
            if (std.mem.eql(u8, arg, "--media-dir")) out.media_dir = value else if (std.mem.eql(u8, arg, "--runtime")) out.runtime = value else if (std.mem.eql(u8, arg, "--runtime-timeout-ms")) out.runtime_timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.Usage else if (std.mem.eql(u8, arg, "--title")) out.title = value else if (std.mem.eql(u8, arg, "--root")) out.root = value else if (std.mem.eql(u8, arg, "--language")) out.language = value else if (std.mem.eql(u8, arg, "--kind")) out.kind = store.parseKind(value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--format")) out.format = std.meta.stringToEnum(Format, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--theme")) out.theme = std.meta.stringToEnum(Theme, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--color")) out.color = std.meta.stringToEnum(Color, value) orelse return error.Usage else if (std.mem.eql(u8, arg, "--limit")) out.limit = std.fmt.parseInt(usize, value, 10) catch return error.Usage else if (std.mem.eql(u8, arg, "--offset")) out.offset = std.fmt.parseInt(usize, value, 10) catch return error.Usage else return error.Usage;
        } else {
            if (has_query) return error.Usage;
            out.query = arg;
            has_query = true;
        }
    }
    if (out.help) return out;
    if (out.core_only and (out.command != .lookup and out.command != .search)) return error.Usage;
    if (out.core_only and (out.format == .source or out.with_source or out.runtime != null or out.details)) return error.Usage;
    if (out.native and out.runtime != null) return error.Usage;
    if (out.media_dir) |path| if (path.len == 0) return error.Usage;
    if (out.runtime_timeout_ms == 0 or out.runtime_timeout_ms > 60000) return error.Usage;
    if (out.runtime) |root| if (root.len == 0 or out.command == .stats or out.command == .languages) return error.Usage;
    if (out.limit == 0 or out.limit > 1000 or out.root.len == 0 or out.language.len == 0) return error.Usage;
    if ((out.command == .lookup or out.command == .render) and (!has_query or out.query.len == 0)) return error.Usage;
    if (out.command == .stats and has_query) return error.Usage;
    if (out.format == .source and out.command != .lookup and out.command != .render) return error.Usage;
    if (out.format == .html and out.command != .lookup and out.command != .search and out.command != .render) return error.Usage;
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

test "standalone render accepts stdin and needs no blob path" {
    const stdin = try parse(&.{ "render", "-", "--title", "Example", "--format", "html" });
    try std.testing.expectEqual(Command.render, stdin.command);
    try std.testing.expectEqualStrings("-", stdin.query);
    try std.testing.expectEqualStrings("Example", stdin.title);
    try std.testing.expectError(error.Usage, parse(&.{"render"}));
    try std.testing.expectError(error.Usage, parse(&.{ "render", "a", "b" }));
}

test "runtime options are bounded and excluded from metadata-only commands" {
    const selected = try parse(&.{ "lookup", "cat", "--runtime", "runtime", "--runtime-timeout-ms", "200" });
    try std.testing.expectEqualStrings("runtime", selected.runtime.?);
    try std.testing.expectEqual(@as(u32, 200), selected.runtime_timeout_ms);
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--runtime-timeout-ms", "0" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--runtime-timeout-ms", "60001" }));
    try std.testing.expectError(error.Usage, parse(&.{ "languages", "--runtime", "runtime" }));
}

test "language accounting can be scoped to a spelling rather than the whole catalog" {
    const opts = try parse(&.{ "languages", "cat", "--format", "json" });
    try std.testing.expectEqualStrings("cat", opts.query);
    try std.testing.expectEqual(Command.languages, opts.command);
}

test "core-only export cannot silently replace exact source or VM expansion" {
    try std.testing.expect((try parse(&.{ "lookup", "cat", "--core-only", "--format", "html" })).core_only);
    try std.testing.expect((try parse(&.{ "search", "cat", "--core-only", "--format", "json" })).core_only);
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--core-only", "--format", "source" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--core-only", "--with-source" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--core-only", "--runtime", "runtime" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--core-only", "--details" }));
    try std.testing.expectError(error.Usage, parse(&.{ "render", "a.wiki", "--core-only" }));
}

test "explicit native rendering cannot accidentally enable a configured VM" {
    try std.testing.expect((try parse(&.{ "lookup", "cat", "--native" })).native);
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--native", "--runtime", "runtime" }));
    try std.testing.expectError(error.Usage, parse(&.{ "lookup", "cat", "--media-dir", "" }));
}
