//! Build-time parser for Wiktionary and pinned site language metadata.
const std = @import("std");

pub const Resolved = struct {
    code: []const u8,
    heading: []const u8,
};

pub const LinkTrailRange = struct {
    first: u21,
    last: u21,
};

const default_link_trail_ranges = [_]LinkTrailRange{.{ .first = 'a', .last = 'z' }};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    ambiguous: std.StringHashMapUnmanaged(void) = .empty,
    codes: std.StringHashMapUnmanaged(void) = .empty,
    trusted_names: std.StringHashMapUnmanaged(void) = .empty,
    strong_names: std.StringHashMapUnmanaged(void) = .empty,
    canonical_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    headings: std.StringHashMapUnmanaged([]const u8) = .empty,
    content_code: ?[]const u8 = null,
    link_trail_ranges: []const LinkTrailRange = &default_link_trail_ranges,
    link_trail_configured: bool = false,
    link_trail_sequences: []const []const u8 = &.{},
    link_trail_sequences_configured: bool = false,
    link_trail_not_double: []const u21 = &.{},
    link_trail_not_double_configured: bool = false,

    pub fn empty(a: std.mem.Allocator) Registry {
        return .{ .arena = .init(a) };
    }

    pub fn deinit(self: *Registry) void {
        self.ambiguous.deinit(self.arena.allocator());
        self.codes.deinit(self.arena.allocator());
        self.trusted_names.deinit(self.arena.allocator());
        self.strong_names.deinit(self.arena.allocator());
        self.canonical_names.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn code(self: *const Registry, heading: []const u8) ?[]const u8 {
        return self.names.get(heading);
    }

    pub fn resolve(self: *const Registry, value: []const u8) ?Resolved {
        const code_value = self.names.get(value) orelse return null;
        return .{
            .code = code_value,
            .heading = self.headings.get(code_value) orelse value,
        };
    }

    pub fn resolveTrusted(self: *const Registry, value: []const u8) ?Resolved {
        if (!self.trusted_names.contains(value)) return null;
        return self.resolve(value);
    }

    pub fn resolveStrong(self: *const Registry, value: []const u8) ?Resolved {
        if (!self.strong_names.contains(value)) return null;
        return self.resolve(value);
    }

    pub fn content(self: *const Registry) ?Resolved {
        return self.resolve(self.content_code orelse return null);
    }

    pub fn linkTrailContains(self: *const Registry, cp: u21) bool {
        for (self.link_trail_ranges) |range| {
            if (cp < range.first) return false;
            if (cp <= range.last) return true;
        }
        return false;
    }

    fn decodeScalarAt(input: []const u8, start: usize) ?struct { cp: u21, end: usize } {
        if (start >= input.len) return null;
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[start]) catch return null;
        if (start + sequence_len > input.len) return null;
        const cp = std.unicode.utf8Decode(input[start .. start + sequence_len]) catch return null;
        return .{ .cp = cp, .end = start + sequence_len };
    }

    pub fn linkTrailEnd(self: *const Registry, input: []const u8, start: usize) usize {
        var cursor = start;
        while (cursor < input.len) {
            var sequence_end: usize = cursor;
            for (self.link_trail_sequences) |sequence| {
                if (std.mem.startsWith(u8, input[cursor..], sequence))
                    sequence_end = @max(sequence_end, cursor + sequence.len);
            }
            if (sequence_end != cursor) {
                cursor = sequence_end;
                continue;
            }

            const decoded = decodeScalarAt(input, cursor) orelse break;
            if (self.linkTrailContains(decoded.cp)) {
                cursor = decoded.end;
                continue;
            }

            var guarded = false;
            for (self.link_trail_not_double) |cp| if (cp == decoded.cp) {
                guarded = true;
                break;
            };
            if (!guarded) break;
            if (decodeScalarAt(input, decoded.end)) |next| {
                if (next.cp == decoded.cp) break;
            }
            cursor = decoded.end;
        }
        return cursor;
    }

    fn parseUnicodeScalar(raw: []const u8) !u21 {
        if (raw.len == 0 or raw.len > 6) return error.InvalidLanguageRegistry;
        const value = std.fmt.parseInt(u32, raw, 16) catch return error.InvalidLanguageRegistry;
        if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff))
            return error.InvalidLanguageRegistry;
        return @intCast(value);
    }

    fn setLinkTrailRanges(self: *Registry, source: []const u8) !void {
        if (self.link_trail_configured) return error.InvalidLanguageRegistry;
        self.link_trail_configured = true;
        if (source.len == 0) {
            self.link_trail_ranges = &.{};
            return;
        }

        const owned = self.arena.allocator();
        var ranges: std.ArrayList(LinkTrailRange) = .empty;
        var fields = std.mem.splitScalar(u8, source, ',');
        var previous_last: ?u21 = null;
        while (fields.next()) |field| {
            if (field.len == 0) return error.InvalidLanguageRegistry;
            const dash = std.mem.indexOfScalar(u8, field, '-');
            const first = try parseUnicodeScalar(if (dash) |at| field[0..at] else field);
            const last = if (dash) |at| blk: {
                if (std.mem.indexOfScalarPos(u8, field, at + 1, '-') != null)
                    return error.InvalidLanguageRegistry;
                break :blk try parseUnicodeScalar(field[at + 1 ..]);
            } else first;
            if (last < first or (first <= 0xdfff and last >= 0xd800))
                return error.InvalidLanguageRegistry;
            if (previous_last) |previous| if (first <= previous)
                return error.InvalidLanguageRegistry;
            try ranges.append(owned, .{ .first = first, .last = last });
            previous_last = last;
        }
        self.link_trail_ranges = try ranges.toOwnedSlice(owned);
    }

    fn setLinkTrailSequences(self: *Registry, source: []const u8) !void {
        if (self.link_trail_sequences_configured or source.len == 0) return error.InvalidLanguageRegistry;
        self.link_trail_sequences_configured = true;
        const owned = self.arena.allocator();
        var sequences: std.ArrayList([]const u8) = .empty;
        var fields = std.mem.splitScalar(u8, source, ',');
        while (fields.next()) |field| {
            if (field.len == 0) return error.InvalidLanguageRegistry;
            var bytes: std.ArrayList(u8) = .empty;
            var scalars = std.mem.splitScalar(u8, field, '+');
            var count: usize = 0;
            while (scalars.next()) |raw| {
                const cp = try parseUnicodeScalar(raw);
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidLanguageRegistry;
                try bytes.appendSlice(owned, encoded[0..len]);
                count += 1;
            }
            if (count < 2) return error.InvalidLanguageRegistry;
            try sequences.append(owned, try bytes.toOwnedSlice(owned));
        }
        self.link_trail_sequences = try sequences.toOwnedSlice(owned);
    }

    fn setLinkTrailNotDouble(self: *Registry, source: []const u8) !void {
        if (self.link_trail_not_double_configured or source.len == 0) return error.InvalidLanguageRegistry;
        self.link_trail_not_double_configured = true;
        const owned = self.arena.allocator();
        var values: std.ArrayList(u21) = .empty;
        var fields = std.mem.splitScalar(u8, source, ',');
        while (fields.next()) |raw| {
            const cp = try parseUnicodeScalar(raw);
            for (values.items) |existing| if (existing == cp) return error.InvalidLanguageRegistry;
            try values.append(owned, cp);
        }
        self.link_trail_not_double = try values.toOwnedSlice(owned);
    }

    fn reserveCode(self: *Registry, code_value: []const u8) !void {
        if (!validCode(code_value)) return error.InvalidLanguageRegistry;
        if (self.codes.contains(code_value)) return;
        const owned = self.arena.allocator();
        const owned_code = try owned.dupe(u8, code_value);
        try self.codes.put(owned, owned_code, {});
        _ = self.ambiguous.remove(code_value);
        _ = self.names.remove(code_value);
        try self.names.put(owned, owned_code, owned_code);
    }

    fn reserveCanonical(self: *Registry, heading: []const u8, code_value: []const u8) !void {
        if (heading.len == 0 or std.mem.indexOfAny(u8, heading, "\x00\n\r\t") != null)
            return error.InvalidLanguageRegistry;
        try self.reserveCode(code_value);
        const owned = self.arena.allocator();
        if (self.canonical_names.get(heading)) |existing| {
            if (!std.mem.eql(u8, existing, code_value)) return error.ConflictingLanguageHeading;
        } else {
            try self.canonical_names.put(owned, try owned.dupe(u8, heading), try owned.dupe(u8, code_value));
        }
        _ = self.ambiguous.remove(heading);
        _ = self.names.remove(heading);
        try self.names.put(owned, try owned.dupe(u8, heading), try owned.dupe(u8, code_value));
        if (self.headings.get(code_value) == null)
            try self.headings.put(owned, try owned.dupe(u8, code_value), try owned.dupe(u8, heading));
    }

    fn addAlias(self: *Registry, name: []const u8, code_value: []const u8) !void {
        if (name.len == 0 or code_value.len == 0 or
            std.mem.indexOfAny(u8, name, "\x00\n\r\t") != null or
            !validCode(code_value))
            return error.InvalidLanguageRegistry;

        if (self.codes.contains(name) and !std.mem.eql(u8, name, code_value)) return;
        if (self.canonical_names.get(name)) |canonical_code|
            if (!std.mem.eql(u8, canonical_code, code_value)) return;
        if (self.ambiguous.contains(name)) return;
        const owned = self.arena.allocator();
        if (self.names.get(name)) |existing| {
            if (std.mem.eql(u8, existing, code_value)) return;
            _ = self.names.remove(name);
            try self.ambiguous.put(owned, try owned.dupe(u8, name), {});
            return;
        }
        try self.names.put(owned, try owned.dupe(u8, name), try owned.dupe(u8, code_value));
    }

    fn trustAlias(self: *Registry, name: []const u8) !void {
        if (name.len == 0 or self.ambiguous.contains(name)) return;
        const owned = self.arena.allocator();
        if (!self.trusted_names.contains(name))
            try self.trusted_names.put(owned, try owned.dupe(u8, name), {});
    }

    fn trustStrong(self: *Registry, name: []const u8) !void {
        if (name.len == 0 or self.ambiguous.contains(name)) return;
        const owned = self.arena.allocator();
        if (!self.strong_names.contains(name))
            try self.strong_names.put(owned, try owned.dupe(u8, name), {});
    }

    fn addCanonical(self: *Registry, heading: []const u8, code_value: []const u8) !void {
        try self.reserveCode(code_value);
        if (self.headings.get(code_value) == null) {
            try self.reserveCanonical(heading, code_value);
        } else {
            try self.addAlias(heading, code_value);
        }
    }

    fn disambiguatedHeading(self: *Registry, heading: []const u8, code_value: []const u8) ![]const u8 {
        const owned = self.arena.allocator();
        var suffix: usize = 1;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 1)
                try std.fmt.allocPrint(owned, "{s} ({s})", .{ heading, code_value })
            else
                try std.fmt.allocPrint(owned, "{s} ({s}) {d}", .{ heading, code_value, suffix });
            if (self.canonical_names.get(candidate)) |existing| {
                if (std.mem.eql(u8, existing, code_value)) return candidate;
                continue;
            }
            return candidate;
        }
    }

    fn rehomeExternalHeading(self: *Registry, heading: []const u8, code_value: []const u8) !void {
        const current = self.headings.get(code_value) orelse return;
        if (!std.mem.eql(u8, current, heading)) return;
        const replacement = try self.disambiguatedHeading(heading, code_value);
        const owned = self.arena.allocator();
        _ = self.canonical_names.remove(heading);
        try self.canonical_names.put(owned, replacement, code_value);
        try self.headings.put(owned, try owned.dupe(u8, code_value), replacement);
        try self.addAlias(replacement, code_value);
    }

    /// Dump-local canonical names outrank siteinfo/ISO aliases. Conflicting
    /// external labels remain addressable under a disambiguated heading/code.
    fn addStrongCanonical(self: *Registry, heading: []const u8, code_value: []const u8) !void {
        if (heading.len == 0 or std.mem.indexOfAny(u8, heading, "\x00\n\r\t") != null)
            return error.InvalidLanguageRegistry;
        try self.reserveCode(code_value);
        if (self.codes.contains(heading) and !std.mem.eql(u8, heading, code_value))
            return error.ConflictingLanguageHeading;

        if (self.canonical_names.get(heading)) |existing| {
            if (!std.mem.eql(u8, existing, code_value))
                try self.rehomeExternalHeading(heading, existing);
        }

        if (self.headings.get(code_value)) |old_heading| {
            if (!std.mem.eql(u8, old_heading, heading)) {
                if (self.canonical_names.get(old_heading)) |owner| {
                    if (std.mem.eql(u8, owner, code_value)) _ = self.canonical_names.remove(old_heading);
                }
            }
        }

        const owned = self.arena.allocator();
        _ = self.ambiguous.remove(heading);
        _ = self.names.remove(heading);
        _ = self.trusted_names.remove(heading);
        _ = self.canonical_names.remove(heading);
        try self.canonical_names.put(owned, try owned.dupe(u8, heading), try owned.dupe(u8, code_value));
        try self.names.put(owned, try owned.dupe(u8, heading), try owned.dupe(u8, code_value));
        try self.headings.put(owned, try owned.dupe(u8, code_value), try owned.dupe(u8, heading));
        try self.trustStrong(heading);
        try self.trustStrong(code_value);
    }

    /// Merge CODE<TAB>PREFERRED_NAME<TAB>ALIAS... rows.
    /// The optional comment "# content-language<TAB>CODE" selects the edition fallback.
    pub fn addTsv(self: *Registry, source: []const u8) !void {
        var reserve_lines = std.mem.splitScalar(u8, source, '\n');
        while (reserve_lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const code_value = fields.next() orelse return error.InvalidLanguageRegistry;
            const preferred = fields.next() orelse return error.InvalidLanguageRegistry;
            if (preferred.len == 0) return error.InvalidLanguageRegistry;
            try self.reserveCode(code_value);
        }

        var mediawiki_rows = true;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "# mediawiki")) {
                mediawiki_rows = true;
                continue;
            }
            if (std.mem.eql(u8, line, "# iso-639-3")) {
                mediawiki_rows = false;
                continue;
            }
            if (line.len == 0) continue;
            if (line[0] == '#') {
                const content_marker = "# content-language\t";
                if (std.mem.startsWith(u8, line, content_marker)) {
                    const code_value = line[content_marker.len..];
                    if (!validCode(code_value) or self.content_code != null) return error.InvalidLanguageRegistry;
                    self.content_code = try self.arena.allocator().dupe(u8, code_value);
                    continue;
                }
                const trail_marker = "# link-trail-ranges\t";
                if (std.mem.startsWith(u8, line, trail_marker)) {
                    try self.setLinkTrailRanges(line[trail_marker.len..]);
                    continue;
                }
                const sequence_marker = "# link-trail-sequences\t";
                if (std.mem.startsWith(u8, line, sequence_marker)) {
                    try self.setLinkTrailSequences(line[sequence_marker.len..]);
                    continue;
                }
                const guarded_marker = "# link-trail-not-double\t";
                if (std.mem.startsWith(u8, line, guarded_marker)) {
                    try self.setLinkTrailNotDouble(line[guarded_marker.len..]);
                }
                continue;
            }
            var fields = std.mem.splitScalar(u8, line, '\t');
            const code_value = fields.next() orelse return error.InvalidLanguageRegistry;
            const preferred = fields.next() orelse return error.InvalidLanguageRegistry;
            try self.addCanonical(preferred, code_value);
            if (mediawiki_rows) try self.trustAlias(preferred);
            while (fields.next()) |alias| try self.addAlias(alias, code_value);
        }
        if (self.content_code) |code_value| {
            if (self.resolve(code_value) == null) return error.InvalidLanguageRegistry;
        }
    }

    pub fn addLua(self: *Registry, source: []const u8) !void {
        const owned = self.arena.allocator();
        var p: usize = 0;
        skip(source, &p);
        if (!std.mem.startsWith(u8, source[p..], "return")) return error.InvalidLanguageRegistry;
        p += 6;
        try expect(source, &p, '{');
        while (true) {
            skip(source, &p);
            if (p < source.len and source[p] == '}') {
                p += 1;
                break;
            }
            try expect(source, &p, '[');
            const name = try string(owned, source, &p);
            try expect(source, &p, ']');
            try expect(source, &p, '=');
            const value = try string(owned, source, &p);
            if (name.len == 0 or value.len == 0) return error.InvalidLanguageRegistry;
            const canonical_code = if (self.resolve(value)) |resolved| resolved.code else value;
            try self.addStrongCanonical(name, canonical_code);
            skip(source, &p);
            if (p < source.len and (source[p] == ',' or source[p] == ';')) p += 1;
        }
        skip(source, &p);
        if (p != source.len) return error.InvalidLanguageRegistry;
    }

    pub fn fromLuaAlloc(a: std.mem.Allocator, source: []const u8) !Registry {
        var out = Registry.empty(a);
        errdefer out.deinit();
        try out.addLua(source);
        return out;
    }
};

fn validCode(code: []const u8) bool {
    if (code.len == 0) return false;
    for (code) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-')) return false;
    return true;
}

fn skip(source: []const u8, p: *usize) void {
    while (p.* < source.len) {
        if (std.ascii.isWhitespace(source[p.*])) {
            p.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[p.*..], "--")) {
            const open = p.* + 2;
            if (open < source.len and source[open] == '[') {
                var end = open + 1;
                while (end < source.len and source[end] == '=') : (end += 1) {}
                if (end < source.len and source[end] == '[') {
                    const equals = source[open + 1 .. end];
                    var scan = end + 1;
                    while (std.mem.indexOfScalarPos(u8, source, scan, ']')) |close| {
                        const last = close + 1 + equals.len;
                        if (last < source.len and source[last] == ']' and
                            std.mem.eql(u8, source[close + 1 .. last], equals))
                        {
                            p.* = last + 1;
                            break;
                        }
                        scan = close + 1;
                    } else p.* = source.len;
                    continue;
                }
            }
            p.* = std.mem.indexOfScalarPos(u8, source, p.*, '\n') orelse source.len;
            continue;
        }
        break;
    }
}

fn expect(source: []const u8, p: *usize, ch: u8) !void {
    skip(source, p);
    if (p.* == source.len or source[p.*] != ch) return error.InvalidLanguageRegistry;
    p.* += 1;
}

fn string(a: std.mem.Allocator, source: []const u8, p: *usize) ![]const u8 {
    skip(source, p);
    const begin = p.*;
    try expect(source, p, '"');
    while (p.* < source.len) {
        const ch = source[p.*];
        p.* += 1;
        if (ch == '"') return std.json.parseFromSliceLeaky([]const u8, a, source[begin..p.*], .{ .allocate = .alloc_always });
        if (ch == '\\' and p.* < source.len) p.* += 1;
    }
    return error.InvalidLanguageRegistry;
}

test "language metadata resolves canonical headings and codes" {
    var r = try Registry.fromLuaAlloc(std.testing.allocator, "return { [\"English\"] = \"en\", [\"Translingual\"] = \"mul\" }");
    defer r.deinit();
    const english = r.resolve("English").?;
    try std.testing.expectEqualStrings("en", english.code);
    try std.testing.expectEqualStrings("English", english.heading);
    try std.testing.expectEqualStrings("English", r.resolve("en").?.heading);
    try std.testing.expect(r.resolve("Noun") == null);
}

test "canonical registry permits Lua long comments with equals delimiters" {
    var r = try Registry.fromLuaAlloc(std.testing.allocator, "--[==[ header ]=] still comment ]==]\nreturn { [\"English\"] = \"en\" }\n--[=[\nlocal export = {}\nreturn export\n]=]");
    defer r.deinit();
    try std.testing.expectEqualStrings("en", r.code("English").?);
}

test "dump canonical names override conflicting external headings" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(
        "# wikidict-language-registry-v2\n" ++
            "# content-language\taf\n" ++
            "# mediawiki\n" ++
            "af\tAfrikaans\taf\n" ++
            "roa-rup\tAromanian\troa-rup\trup\n" ++
            "yue\tKantonees\tyue\n" ++
            "zh-yue\tCantonese\tzh-yue\tyue\n" ++
            "# iso-639-3\n" ++
            "rup\tAromanies\trup\n",
    );
    try r.addLua("return { [\"Aromanian\"] = \"rup\", [\"Cantonese\"] = \"yue\" }");
    try std.testing.expectEqualStrings("rup", r.resolveStrong("Aromanian").?.code);
    try std.testing.expectEqualStrings("rup", r.resolveStrong("rup").?.code);
    try std.testing.expectEqualStrings("Aromanian", r.resolve("rup").?.heading);
    try std.testing.expectEqualStrings("Aromanian (roa-rup)", r.resolve("roa-rup").?.heading);
    try std.testing.expectEqualStrings("yue", r.resolveStrong("Cantonese").?.code);
    try std.testing.expectEqualStrings("Cantonese", r.resolve("yue").?.heading);
    try std.testing.expectEqualStrings("Cantonese (zh-yue)", r.resolve("zh-yue").?.heading);
}

test "pinned TSV aliases merge and expose content language" {
    var r = try Registry.fromLuaAlloc(std.testing.allocator, "return { [\"English\"] = \"en\" }");
    defer r.deinit();
    try r.addTsv(
        "# wikidict-language-registry-v2\n" ++
            "# content-language\tfi\n" ++
            "# link-trail-ranges\t0061-007A,00E4,00F6\n" ++
            "fi\tSuomi\tfi\tfin\tFinnish\tsuomi\n" ++
            "en\tEnglanti\ten\teng\tEnglish\n",
    );
    try std.testing.expectEqualStrings("fi", r.resolve("fin").?.code);
    try std.testing.expectEqualStrings("Suomi", r.resolve("Finnish").?.heading);
    try std.testing.expectEqualStrings("English", r.resolve("Englanti").?.heading);
    try std.testing.expectEqualStrings("Suomi", r.content().?.heading);
    try std.testing.expect(r.linkTrailContains('a'));
    try std.testing.expect(r.linkTrailContains('ä'));
    try std.testing.expect(r.linkTrailContains('ö'));
    try std.testing.expect(!r.linkTrailContains('å'));
    try std.testing.expect(r.resolveTrusted("Suomi") != null);
    try std.testing.expect(r.resolveTrusted("Finnish") == null);
    try r.addTsv("roa-rup\tAromanian\trup\nrup\tArmãneashti\trup\n");
    try std.testing.expectEqualStrings("rup", r.resolve("rup").?.code);
    var kbd = Registry.empty(std.testing.allocator);
    defer kbd.deinit();
    try kbd.addTsv("kbd\tАдыгэбзэ\tkbd\nkbd-cyrl\tKabardian (Cyrillic script)\tАдыгэбзэ\n");
    try std.testing.expectEqualStrings("kbd", kbd.resolve("Адыгэбзэ").?.code);
    try r.addTsv("fr\tFrench\tEnglish\n");
    try std.testing.expectEqualStrings("en", r.resolve("English").?.code);
    try std.testing.expectEqualStrings("fr", r.resolve("French").?.code);
    try std.testing.expectError(error.InvalidLanguageRegistry, r.addTsv("bad code\tBad\n"));
    try std.testing.expectError(error.InvalidLanguageRegistry, r.addTsv("fr\t\n"));
}

test "link trail ranges reject malformed or overlapping registry metadata" {
    var default = Registry.empty(std.testing.allocator);
    defer default.deinit();
    try default.addTsv("en\tEnglish\ten\n");
    try std.testing.expect(default.linkTrailContains('a'));
    try std.testing.expect(!default.linkTrailContains('ä'));

    var empty = Registry.empty(std.testing.allocator);
    defer empty.deinit();
    try empty.addTsv("# link-trail-ranges\t\nen\tEnglish\ten\n");
    try std.testing.expect(!empty.linkTrailContains('a'));

    for ([_][]const u8{
        "# link-trail-ranges\t0061-007A,0070-0080\nen\tEnglish\ten\n",
        "# link-trail-ranges\tD800\nen\tEnglish\ten\n",
        "# link-trail-ranges\tD7FF-E000\nen\tEnglish\ten\n",
        "# link-trail-ranges\t110000\nen\tEnglish\ten\n",
        "# link-trail-ranges\t007A-0061\nen\tEnglish\ten\n",
    }) |source| {
        var invalid = Registry.empty(std.testing.allocator);
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidLanguageRegistry, invalid.addTsv(source));
    }
}

test "link trail sequences and guarded apostrophes match MediaWiki rules" {
    var breton = Registry.empty(std.testing.allocator);
    defer breton.deinit();
    try breton.addTsv(
        "# link-trail-ranges\t0041-005A,0061-007A\n" ++
            "# link-trail-sequences\t0063+0027+0068,0043+0027+0048,0063+2019+0068\n" ++
            "br\tBrezhoneg\tbr\n",
    );
    try std.testing.expectEqual("c'h".len, breton.linkTrailEnd("c'h!", 0));
    try std.testing.expectEqual("c’h".len, breton.linkTrailEnd("c’h!", 0));
    try std.testing.expectEqual(@as(usize, 1), breton.linkTrailEnd("c'Z", 0));

    var catalan = Registry.empty(std.testing.allocator);
    defer catalan.deinit();
    try catalan.addTsv(
        "# link-trail-ranges\t0061-007A\n" ++
            "# link-trail-not-double\t0027\n" ++
            "ca\tCatalà\tca\n",
    );
    try std.testing.expectEqual(@as(usize, 2), catalan.linkTrailEnd("a'Z", 0));
    try std.testing.expectEqual(@as(usize, 1), catalan.linkTrailEnd("a''Z", 0));
}
