//! Build-time parser for Wiktionary and pinned site language metadata.
const std = @import("std");

pub const Resolved = struct {
    code: []const u8,
    heading: []const u8,
};

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
                const marker = "# content-language\t";
                if (std.mem.startsWith(u8, line, marker)) {
                    const code_value = line[marker.len..];
                    if (!validCode(code_value) or self.content_code != null) return error.InvalidLanguageRegistry;
                    self.content_code = try self.arena.allocator().dupe(u8, code_value);
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
            "fi\tSuomi\tfi\tfin\tFinnish\tsuomi\n" ++
            "en\tEnglanti\ten\teng\tEnglish\n",
    );
    try std.testing.expectEqualStrings("fi", r.resolve("fin").?.code);
    try std.testing.expectEqualStrings("Suomi", r.resolve("Finnish").?.heading);
    try std.testing.expectEqualStrings("English", r.resolve("Englanti").?.heading);
    try std.testing.expectEqualStrings("Suomi", r.content().?.heading);
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
