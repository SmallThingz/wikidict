//! Build-only selection of declarative gadget CSS from the retained definition.
//! No gadget JavaScript or user preference program is executed or shipped.
const std = @import("std");

pub const Options = struct {
    disable_defaults: bool = false,
    disabled: []const []const u8 = &.{},
};
pub const Module = struct {
    name: []const u8,
    pages: []const []const u8,
    definition_line: usize,
    unknown_applicability: bool,
};
const Definition = struct {
    name: []const u8,
    pages: []const []const u8,
    peers: []const []const u8,
    line: usize,
    enabled_by_default: bool,
    style_type: bool,
    conditional: bool,
};
const max_definitions = 512;
const max_pages = 64;

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}
fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}
fn member(values: []const []const u8, value: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
fn listAlloc(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        const value = trim(part);
        if (!identifier(value) or values.items.len == max_pages or member(values.items, value)) return error.InvalidGadgetDefinition;
        try values.append(a, value);
    }
    return values.toOwnedSlice(a);
}
// MediaWiki removes completed HTML comments before recognizing definition lines.
// Keep original line provenance even when a comment joins two source fragments.
const DefinitionLines = struct {
    source: []const u8,
    offset: usize = 0,
    number: usize = 1,
    no_comment_end: bool = false,

    const Line = struct { text: []const u8, number: usize };

    fn advanceNewline(self: *DefinitionLines) void {
        const byte = self.source[self.offset];
        self.offset += 1;
        if (byte == '\r' and self.offset < self.source.len and self.source[self.offset] == '\n') self.offset += 1;
        self.number += 1;
    }

    fn next(self: *DefinitionLines, a: std.mem.Allocator) !?Line {
        if (self.offset == self.source.len) return null;
        var start = self.offset;
        const fallback_line = self.number;
        var origin: ?usize = null;
        var copied = false;
        var joined: std.ArrayList(u8) = .empty;
        errdefer joined.deinit(a);
        while (self.offset < self.source.len) {
            if (!self.no_comment_end and std.mem.startsWith(u8, self.source[self.offset..], "<!--")) {
                if (std.mem.indexOf(u8, self.source[self.offset + 4 ..], "-->")) |end| {
                    try joined.appendSlice(a, self.source[start..self.offset]);
                    copied = true;
                    const after = self.offset + 4 + end + 3;
                    while (self.offset < after) {
                        const byte = self.source[self.offset];
                        if (byte == '\r' or byte == '\n') self.advanceNewline() else self.offset += 1;
                    }
                    start = self.offset;
                    continue;
                }
                self.no_comment_end = true;
            }
            const byte = self.source[self.offset];
            if (byte == '\r' or byte == '\n') {
                const end = self.offset;
                self.advanceNewline();
                if (!copied) return .{ .text = self.source[start..end], .number = origin orelse fallback_line };
                try joined.appendSlice(a, self.source[start..end]);
                return .{ .text = try joined.toOwnedSlice(a), .number = origin orelse fallback_line };
            }
            if (origin == null and !std.ascii.isWhitespace(byte)) origin = self.number;
            self.offset += 1;
        }
        if (!copied) return .{ .text = self.source[start..], .number = origin orelse fallback_line };
        try joined.appendSlice(a, self.source[start..]);
        return .{ .text = try joined.toOwnedSlice(a), .number = origin orelse fallback_line };
    }
};

// This is only the upstream definition-line shape, not a grant of supported
// option or resource semantics. A recognized definition still goes through all
// parseLine checks; prose and malformed list items are not definitions.
fn definitionText(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '*') return null;
    var start: usize = 1;
    while (start < line.len and line[start] == '*') : (start += 1) {}
    while (start < line.len and line[start] == ' ') : (start += 1) {}
    const text = line[start..];
    const marker = std.mem.indexOfAny(u8, text, "[|") orelse return null;
    const name = std.mem.trimEnd(u8, text[0..marker], " \t\r\n\x0b\x0c");
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return null;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != ':' and byte != '.' and byte != ' ') return null;
    }
    if (text[marker] == '|') return text;
    for (text[marker + 1 ..], 0..) |byte, index| {
        if (byte != ']') continue;
        const rest = std.mem.trimStart(u8, text[marker + 2 + index ..], " \t\r\n\x0b\x0c");
        if (rest.len != 0 and rest[0] == '|') return text;
    }
    return null;
}

fn parseLine(a: std.mem.Allocator, text: []const u8, line: usize) !Definition {
    const start = trim(text);
    const marker = std.mem.indexOfAny(u8, start, "[|") orelse return error.InvalidGadgetDefinition;
    var name = trim(start[0..marker]);
    if (name.len > 256) return error.InvalidGadgetDefinition;
    // Gadgets-definition normalizes spaces in the module name, independently
    // of the resource-page spelling. Other identifier domains are unchanged.
    if (std.mem.indexOfScalar(u8, name, ' ') != null) {
        const normalized = try a.dupe(u8, name);
        for (normalized) |*byte| {
            if (byte.* == ' ') byte.* = '_';
        }
        name = normalized;
    }
    if (!identifier(name)) return error.InvalidGadgetDefinition;
    var rest = start[marker..];
    var enabled = false;
    var conditional = false;
    var explicit_type: ?bool = null;
    var peers: []const []const u8 = &.{};
    if (rest[0] == '[') {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidGadgetDefinition;
        var options = std.mem.splitScalar(u8, rest[1..end], '|');
        var keys: std.ArrayList([]const u8) = .empty;
        while (options.next()) |raw| {
            const option = trim(raw);
            if (option.len == 0) continue;
            const equal = std.mem.indexOfScalar(u8, option, '=');
            const key = trim(if (equal) |pos| option[0..pos] else option);
            const value: ?[]const u8 = if (equal) |pos| trim(option[pos + 1 ..]) else null;
            if (!identifier(key) or member(keys.items, key)) return error.InvalidGadgetDefinition;
            try keys.append(a, key);
            if (std.mem.eql(u8, key, "default")) {
                if (value != null) return error.InvalidGadgetDefinition;
                enabled = true;
            } else if (std.mem.eql(u8, key, "hidden") or std.mem.eql(u8, key, "package") or std.mem.eql(u8, key, "ResourceLoader")) {
                if (value != null) return error.InvalidGadgetDefinition;
            } else if (std.mem.eql(u8, key, "type")) {
                const kind = value orelse return error.InvalidGadgetDefinition;
                explicit_type = if (std.mem.eql(u8, kind, "styles")) true else if (std.mem.eql(u8, kind, "general")) false else return error.InvalidGadgetDefinition;
            } else if (std.mem.eql(u8, key, "peers")) {
                peers = try listAlloc(a, value orelse return error.InvalidGadgetDefinition);
            } else if (std.mem.eql(u8, key, "dependencies") or std.mem.eql(u8, key, "messages") or std.mem.eql(u8, key, "codexIcons")) {
                if (value == null or value.?.len == 0) return error.InvalidGadgetDefinition;
                // General-module dependencies do not become server-loaded CSS.
            } else if (std.mem.eql(u8, key, "supportsUrlLoad")) {
                // No withgadget URL override is part of ordinary default input.
                if (value) |flag| if (!std.mem.eql(u8, flag, "true") and !std.mem.eql(u8, flag, "false")) return error.InvalidGadgetDefinition;
            } else {
                // Scope predicates need the concrete page/user/skin. Preserve
                // their CSS as conditional; absence of context is not false.
                conditional = true;
                if (value != null and value.?.len == 0) return error.InvalidGadgetDefinition;
            }
        }
        rest = trim(rest[end + 1 ..]);
    }
    if (rest.len == 0 or rest[0] != '|') return error.InvalidGadgetDefinition;
    var pages: std.ArrayList([]const u8) = .empty;
    var has_script = false;
    var page_count: usize = 0;
    var parts = std.mem.splitScalar(u8, rest[1..], '|');
    while (parts.next()) |raw| {
        if (page_count == max_pages) return error.InvalidGadgetDefinition;
        page_count += 1;
        const page = trim(raw);
        if (page.len == 0 or page.len > 1024 or std.mem.indexOfAny(u8, page, "[]{}<>:#\\\x00") != null or
            !std.unicode.utf8ValidateSlice(page) or pages.items.len == max_pages) return error.InvalidGadgetDefinition;
        if (std.mem.endsWith(u8, page, ".css")) {
            if (member(pages.items, page)) return error.InvalidGadgetDefinition;
            try pages.append(a, page);
        } else if (std.mem.endsWith(u8, page, ".js") or std.mem.endsWith(u8, page, ".json") or std.mem.endsWith(u8, page, ".vue")) {
            has_script = true;
        } else return error.InvalidGadgetDefinition;
    }
    return .{ .name = name, .pages = try pages.toOwnedSlice(a), .peers = peers, .line = line,
        .enabled_by_default = enabled, .style_type = explicit_type orelse !has_script, .conditional = conditional };
}
fn addModule(a: std.mem.Allocator, modules: *std.ArrayList(Module), def: Definition, conditional: bool) !void {
    if (!def.style_type or def.pages.len == 0) return;
    for (modules.items) |*existing| {
        if (std.mem.eql(u8, existing.name, def.name)) {
            // An unconditional inclusion is enough even if another owner is
            // conditional. This does not evaluate that owner's predicate.
            existing.unknown_applicability = existing.unknown_applicability and conditional;
            return;
        }
    }
    try modules.append(a, .{ .name = def.name, .pages = def.pages, .definition_line = def.line, .unknown_applicability = conditional });
}
fn lessThan(_: void, left: Module, right: Module) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

pub fn selectAlloc(a: std.mem.Allocator, source: []const u8, options: Options) ![]const Module {
    if (source.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(source)) return error.InvalidGadgetDefinition;
    var definitions: std.ArrayList(Definition) = .empty;
    var lines: DefinitionLines = .{ .source = source };
    while (try lines.next(a)) |line| {
        const text = definitionText(line.text) orelse continue;
        if (definitions.items.len == max_definitions) return error.InvalidGadgetDefinition;
        const def = try parseLine(a, text, line.number);
        for (definitions.items) |old| if (std.mem.eql(u8, old.name, def.name)) return error.InvalidGadgetDefinition;
        try definitions.append(a, def);
    }
    var modules: std.ArrayList(Module) = .empty;
    if (!options.disable_defaults) for (definitions.items) |def| {
        if (!def.enabled_by_default or member(options.disabled, def.name)) continue;
        if (def.style_type) {
            try addModule(a, &modules, def, def.conditional);
        } else {
            for (def.peers) |peer| {
                for (definitions.items) |peer_def| {
                    if (std.mem.eql(u8, peer, peer_def.name)) {
                        try addModule(a, &modules, peer_def, def.conditional or peer_def.conditional);
                        break;
                    }
                }
            }
        }
    };
    // ResourceLoader sorts module names; definition order is not cascade order.
    std.mem.sort(Module, modules.items, {}, lessThan);
    return modules.toOwnedSlice(a);
}

test "retained KU defaults select static styles and peers without running general gadgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = @embedFile("testdata/ku-default-gadgets/Gadgets-definition.wikitext");
    const selected = try selectAlloc(a, source, .{});
    try std.testing.expectEqual(@as(usize, 5), selected.len);
    const names = [_][]const u8{ "LanguagesAndScripts", "Palette", "Site", "TreeDescs-pagestyles", "charinsert-styles" };
    for (selected, names, 0..) |module, name, index| {
        try std.testing.expectEqualStrings(name, module.name);
        try std.testing.expectEqual(index == 3, module.unknown_applicability);
        try std.testing.expectEqual(@as(usize, 1), module.pages.len);
    }
    try std.testing.expectEqualStrings("Site.css", selected[2].pages[0]);
    const disabled = try selectAlloc(a, source, .{ .disabled = &.{"Site"} });
    try std.testing.expectEqual(@as(usize, 4), disabled.len);
    for (disabled) |module| try std.testing.expect(!std.mem.eql(u8, module.name, "Site"));
    try std.testing.expectEqual(@as(usize, 0), (try selectAlloc(a, source, .{ .disable_defaults = true })).len);
}

test "default gadget conditional and nondefault inputs do not grant unconditional CSS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = "* Off|Off.css\n* Hidden[hidden]|Hidden.css\n* Js[default]|code.js|general.css\n* Explicit[default|type=styles]|ignored.js|explicit.css\n" ++
        "* Scope[default|namespaces=0|actions=view|skins=vector|rights=read|categories=Test|contentModels=wikitext]|scope.css\n" ++
        "* Parent[default|peers=Peer]|parent.js\n* Peer[hidden|type=styles]|peer.css\n";
    const selected = try selectAlloc(a, source, .{});
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    try std.testing.expectEqualStrings("Explicit", selected[0].name);
    try std.testing.expectEqualStrings("Peer", selected[1].name);
    try std.testing.expectEqualStrings("Scope", selected[2].name);
    try std.testing.expect(!selected[0].unknown_applicability and !selected[1].unknown_applicability);
    try std.testing.expect(selected[2].unknown_applicability);
    try std.testing.expectError(error.InvalidGadgetDefinition, selectAlloc(a, "* A[default=0]|a.css", .{}));
    try std.testing.expectError(error.InvalidGadgetDefinition, selectAlloc(a, "* A[default]|a.css\n* A|b.css", .{}));
}


test "retained SR gadget definition accepts spaced general name without granting script CSS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = @embedFile("testdata/sr-default-gadgets/Gadgets-definition.wikitext");
    try std.testing.expectEqual(@as(usize, 4224), source.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("d6327992bc24f0e14557ab8f56665ffb00b91d161a26c3f8b2c8ced76cbd01db", &hex);
    try std.testing.expect(std.mem.indexOf(u8, source, "* Quick patrol|Quick patrol.js\n") != null);
    const named = try parseLine(a, " Quick patrol|Quick patrol.js", 39);
    try std.testing.expectEqualStrings("Quick_patrol", named.name);
    try std.testing.expect(!named.enabled_by_default and !named.style_type and named.pages.len == 0);
    const selected = try selectAlloc(a, source, .{});
    const names = [_][]const u8{ "SubtleUpdatemarker", "WatchlistBase", "WatchlistGreenIndicators", "WatchlistGreenIndicatorsMono", "charinsert-styles" };
    try std.testing.expectEqual(names.len, selected.len);
    for (selected, names, 0..) |module, name, i| {
        try std.testing.expectEqualStrings(name, module.name);
        try std.testing.expectEqual(i != 4, module.unknown_applicability);
        try std.testing.expectEqual(@as(usize, 1), module.pages.len);
    }
    try std.testing.expectEqualStrings("charinsert-styles.css", selected[4].pages[0]);
    try std.testing.expectEqual(@as(usize, 0), (try selectAlloc(a, source, .{ .disable_defaults = true })).len);
}

test "canonical spaced gadget names preserve resources defaults peers order and disabling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = "* Quick z[default|namespaces=0]|Quick z.css\n* Quick patrol[default]|Quick patrol.css\n* A[default]|a.css\n";
    const selected = try selectAlloc(a, source, .{});
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    try std.testing.expectEqualStrings("A", selected[0].name);
    try std.testing.expectEqualStrings("Quick_patrol", selected[1].name);
    try std.testing.expectEqualStrings("Quick patrol.css", selected[1].pages[0]);
    try std.testing.expectEqualStrings("Quick_z", selected[2].name);
    try std.testing.expectEqualStrings("Quick z.css", selected[2].pages[0]);
    try std.testing.expect(!selected[0].unknown_applicability and !selected[1].unknown_applicability and selected[2].unknown_applicability);
    const disabled = try selectAlloc(a, source, .{ .disabled = &.{"Quick_patrol"} });
    try std.testing.expectEqual(@as(usize, 2), disabled.len);
    for (disabled) |module| try std.testing.expect(!std.mem.eql(u8, module.name, "Quick_patrol"));
    const peers = try selectAlloc(a, "* Parent[default|peers=Quick_patrol]|parent.js\n* Quick patrol[hidden|type=styles]|Quick patrol.css\n", .{});
    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqualStrings("Quick_patrol", peers[0].name);
    try std.testing.expectEqualStrings("Quick patrol.css", peers[0].pages[0]);
    try std.testing.expect(!peers[0].unknown_applicability);
}

test "spaced gadget normalization does not normalize option keys paths or canonical collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "* Quick patrol[de fault]|x.css\n",
        "* Quick patrol[default=0]|x.css\n",
        "* Quick patrol[default]|bad:resource.css\n",
        "* Quick patrol[default]|x.css\n* Quick_patrol|y.css\n",
    }) |source| try std.testing.expectError(error.InvalidGadgetDefinition, selectAlloc(a, source, .{}));
}

test "retained FR gadget documentation and empty options preserve all seven default CSS sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = @embedFile("testdata/fr-default-gadgets/Gadgets-definition.wikitext");
    try std.testing.expectEqual(@as(usize, 11551), source.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("9f9911fddc655c1e25feef1675db74ce8209c632b92f9a2ef0efc207fcd2ca9f", &hex);
    var lines: DefinitionLines = .{ .source = source };
    var definition_count: usize = 0;
    while (try lines.next(a)) |line| {
        if (definitionText(line.text) != null) definition_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 78), definition_count);
    const selected = try selectAlloc(a, source, .{});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("StyleWiktionnaire", selected[0].name);
    try std.testing.expectEqual(@as(usize, 70), selected[0].definition_line);
    try std.testing.expect(!selected[0].unknown_applicability);
    const pages = [_][]const u8{ "NavFrame.css", "CadreOnglet.css", "StyleScripts.css", "StyleArticles.css", "Accueil2.css", "Common-edit.css", "Flexions.css" };
    try std.testing.expectEqual(pages.len, selected[0].pages.len);
    for (pages, selected[0].pages) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(usize, 0), (try selectAlloc(a, source, .{ .disable_defaults = true })).len);
    try std.testing.expectEqual(@as(usize, 0), (try selectAlloc(a, source, .{ .disabled = &.{"StyleWiktionnaire"} })).len);
}

test "gadget comment removal preserves original definition lines and valid noinclude definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const source = "<noinclude>\n" ++
        "* [[Special:Gadgets]] prose\n" ++
        "* Inside[default]|inside.css\n" ++
        "</noinclude>\n" ++
        "<!--\n* Hidden[default]|hidden.css\n-->\n" ++
        "* Join<!--\ncomment\n-->ed[default]|joined.css\n" ++
        "<!-- preface\n-->** Empty[||default||type=styles||]|empty.css\n" ++
        "* Plain [] | plain.js\n* White[ \t ]|white.js\n" ++
        "* Broken[default|broken.css\n* 1 Invalid[default]|bad.css\n" ++
        "* Tab\tInside[default]|bad.css\n * Indented[default]|bad.css\n";
    const selected = try selectAlloc(a, source, .{});
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    const names = [_][]const u8{ "Empty", "Inside", "Joined" };
    const numbers = [_]usize{ 12, 3, 8 };
    const pages = [_][]const u8{ "empty.css", "inside.css", "joined.css" };
    for (selected, names, numbers, pages) |module, name, number, page| {
        try std.testing.expectEqualStrings(name, module.name);
        try std.testing.expectEqual(number, module.definition_line);
        try std.testing.expectEqual(@as(usize, 1), module.pages.len);
        try std.testing.expectEqualStrings(page, module.pages[0]);
        try std.testing.expect(!module.unknown_applicability);
    }
    const unclosed = try selectAlloc(a, "<!-- unclosed\n* Visible[default]|visible.css\n", .{});
    try std.testing.expectEqual(@as(usize, 1), unclosed.len);
    try std.testing.expectEqualStrings("Visible", unclosed[0].name);
    try std.testing.expectEqual(@as(usize, 2), unclosed[0].definition_line);
    const cr = try selectAlloc(a, "* CR[default]|cr.css\r* CRLF[default]|crlf.css\r\n* LF[default]|lf.css\n", .{});
    try std.testing.expectEqual(@as(usize, 3), cr.len);
    for (cr, 1..) |module, number| try std.testing.expectEqual(number, module.definition_line);
}

test "gadget definition eligibility does not waive unsupported selected semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "* Quick\tpatrol|x.css\n", "* 1 Quick|x.css\n", "* [[Special:Gadgets]] prose\n",
        "* Missing pipe[default]\n", "* Broken[default|x.css\n", "* Tail-[default]|x.css\n",
    }) |source| {
        try std.testing.expectEqual(@as(usize, 0), (try selectAlloc(a, source, .{})).len);
    }
    for ([_][]const u8{
        "* Wiki:name[default]|a.css", "* A[default=0]|a.css", "* A[default|type=unknown]|a.css",
        "* A[default|namespaces=]|a.css", "* A[default]|a.wasm", "* A[default]|bad:resource.css",
        "* A[default]|", "* A[default||default]|a.css", "* A[default]garbage]|a.css",
        "* A[default]|a.css\n* A|b.css",
    }) |source| try std.testing.expectError(error.InvalidGadgetDefinition, selectAlloc(a, source, .{}));
    const conditional = try selectAlloc(a, "* Conditional[||default||namespaces=0||]|a.css", .{});
    try std.testing.expectEqual(@as(usize, 1), conditional.len);
    try std.testing.expect(conditional[0].unknown_applicability);
    try std.testing.expectError(error.InvalidGadgetDefinition, selectAlloc(a, "<!--\xff-->\n* A[default]|a.css", .{}));
}

fn gadgetCommentAllocationCheck(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing); defer arena.deinit();
    const selected = try selectAlloc(arena.allocator(), "<!-- preface\n-->** Quick<!--\njoin\n--> style[||default||]|first.css|second.css\n", .{});
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("Quick_style", selected[0].name);
    try std.testing.expectEqual(@as(usize, 2), selected[0].definition_line);
    try std.testing.expectEqual(@as(usize, 2), selected[0].pages.len);
    try std.testing.expectEqualStrings("first.css", selected[0].pages[0]);
    try std.testing.expectEqualStrings("second.css", selected[0].pages[1]);
}

test "gadget comment normalization propagates allocation failures without losing source ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, gadgetCommentAllocationCheck, .{});
}
