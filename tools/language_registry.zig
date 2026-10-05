//! Build-time parser for Wiktionary and pinned site language metadata.
const std = @import("std");
const lua_parser = @import("lua_parser");

pub const LanguageDataKind = enum { canonical_assignments, named_table };

pub const Resolved = struct {
    code: []const u8,
    heading: []const u8,
};

pub const LinkTrailRange = struct {
    first: u21,
    last: u21,
};

const default_link_trail_ranges = [_]LinkTrailRange{.{ .first = 'a', .last = 'z' }};

const DerivedPreferredName = struct {
    original_name: []const u8,
    code: []const u8,
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
    arabic_articleless_names: std.StringHashMapUnmanaged(?DerivedPreferredName) = .empty,
    local_aliases: std.StringHashMapUnmanaged(?[]const u8) = .empty,
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
        self.arabic_articleless_names.deinit(self.arena.allocator());
        self.local_aliases.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn code(self: *const Registry, heading: []const u8) ?[]const u8 {
        if (self.names.get(heading)) |value| return value;
        return self.fallbackCode(heading);
    }

    pub fn resolve(self: *const Registry, value: []const u8) ?Resolved {
        const code_value = self.code(value) orelse return null;
        return .{
            .code = code_value,
            .heading = self.headings.get(code_value) orelse value,
        };
    }

    pub fn resolveTrusted(self: *const Registry, value: []const u8) ?Resolved {
        // An exact ordinary alias retains its existing trust level.
        if (self.names.contains(value)) {
            if (!self.trusted_names.contains(value)) return null;
        } else if (self.fallbackCode(value) == null) return null;
        return self.resolve(value);
    }

    pub fn resolveStrong(self: *const Registry, value: []const u8) ?Resolved {
        if (!self.strong_names.contains(value) or !self.names.contains(value)) return null;
        return self.resolve(value);
    }

    fn fallbackCode(self: *const Registry, value: []const u8) ?[]const u8 {
        if (self.names.contains(value) or self.ambiguous.contains(value)) return null;
        const article_code = self.derivedArabicCode(value);
        if (self.local_aliases.get(value)) |candidate| {
            const local_code = candidate orelse return null;
            if (article_code) |other| {
                if (!std.mem.eql(u8, local_code, other)) return null;
            } else if (std.mem.eql(u8, self.content_code orelse "", "ar")) {
                if (self.arabic_articleless_names.get(value)) |article|
                    if (article == null) return null;
            }
            return local_code;
        }
        return article_code;
    }

    fn derivedArabicCode(self: *const Registry, value: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, self.content_code orelse return null, "ar")) return null;
        if (self.names.contains(value) or self.ambiguous.contains(value)) return null;
        const candidate = (self.arabic_articleless_names.get(value) orelse return null) orelse return null;
        if (!self.trusted_names.contains(candidate.original_name)) return null;
        const owner = self.names.get(candidate.original_name) orelse return null;
        if (!std.mem.eql(u8, owner, candidate.code)) return null;
        return owner;
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

    /// Arabic edition headings omit the literal article in site preferred names.
    /// Keep these candidates separate so exact names and their trust always win.
    fn addArabicArticlelessName(self: *Registry, preferred: []const u8, code_value: []const u8) !void {
        const article = "ال";
        if (!std.mem.startsWith(u8, preferred, article) or preferred.len == article.len) return;
        const name = preferred[article.len..];
        if (self.arabic_articleless_names.getPtr(name)) |existing| {
            if (existing.*) |candidate| {
                if (!std.mem.eql(u8, candidate.code, code_value)) existing.* = null;
            }
            return;
        }
        const owned = self.arena.allocator();
        try self.arabic_articleless_names.put(owned, try owned.dupe(u8, name), .{
            .original_name = try owned.dupe(u8, preferred),
            .code = try owned.dupe(u8, code_value),
        });
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
            if (mediawiki_rows) {
                try self.trustAlias(preferred);
                try self.addArabicArticlelessName(preferred, code_value);
            }
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

    fn registeredLocalCode(self: *const Registry, value: []const u8) ?[]const u8 {
        if (self.codes.contains(value)) return value;
        // Only ISO aliases may canonicalize a table key; language labels may not.
        if (value.len != 3) return null;
        for (value) |ch| if (ch < 'a' or ch > 'z') return null;
        const resolved_code = self.names.get(value) orelse return null;
        return if (self.codes.contains(resolved_code)) resolved_code else null;
    }

    /// Import an explicit dump-local label without changing canonical headings
    /// or promoting the trust of an existing exact alias.
    pub fn addLocalAlias(self: *Registry, name: []const u8, registered_code: []const u8) !void {
        if (!validLocalLabel(name)) return error.InvalidLanguageRegistry;
        const code_value = self.registeredLocalCode(registered_code) orelse return;
        if (self.local_aliases.getPtr(name)) |existing| {
            if (existing.*) |code_before| {
                if (!std.mem.eql(u8, code_before, code_value)) existing.* = null;
            }
            return;
        }
        const owned = self.arena.allocator();
        try self.local_aliases.put(owned, try owned.dupe(u8, name), try owned.dupe(u8, code_value));
    }

    /// Read only the literal records in the two pinned language-data shapes.
    /// Unsupported writes invalidate the staged source before any alias is added.
    pub fn addLanguageDataLua(self: *Registry, source: []const u8, kind: LanguageDataKind) !void {
        var chunk = try lua_parser.parse(self.arena.child_allocator, source);
        defer chunk.deinit();
        const temporary = chunk.arena.allocator();
        var pending: std.ArrayList(LocalName) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        var initialized = false;
        var named_table_seen = false;
        const root_name = languageDataRoot(kind);
        for (chunk.body) |stmt| {
            switch (stmt.*) {
                .local_assign => |assignment| {
                    for (assignment.values) |value| if (languageDataExpressionWrite(value, kind) or languageDataReference(value, kind)) return;
                    var relevant = false;
                    for (assignment.names) |name| if (std.mem.eql(u8, name, root_name)) {
                        relevant = true;
                    };
                    if (!relevant) continue;
                    if (initialized or assignment.names.len != 1 or assignment.values.len != 1) return;
                    const fields = literalTable(assignment.values[0]) orelse return;
                    if (fields.len != 0) return;
                    initialized = true;
                },
                .assign => |assignment| {
                    for (assignment.values) |value| if (languageDataExpressionWrite(value, kind) or languageDataReference(value, kind)) return;
                    var relevant = false;
                    for (assignment.targets) |target| if (languageDataTarget(target, kind)) {
                        relevant = true;
                    };
                    if (!relevant) continue;
                    if (!initialized or assignment.targets.len != 1 or assignment.values.len != 1) return;
                    const target = switch (assignment.targets[0]) {
                        .index => |index| index,
                        else => return,
                    };
                    if (!literalName(target.object, root_name)) return;
                    const key = literalString(target.key) orelse return;
                    if (kind == .canonical_assignments) {
                        if (!try self.stageLanguageRecord(temporary, &pending, &seen, key, assignment.values[0], kind)) return;
                    } else {
                        if (!std.mem.eql(u8, key, "lang_table") or named_table_seen) return;
                        named_table_seen = true;
                        const fields = literalTable(assignment.values[0]) orelse return;
                        for (fields) |field| {
                            const row: LuaLiteralField = switch (field) {
                                .named => |named| .{ .key = named.name, .value = named.value },
                                .keyed => |keyed| .{ .key = literalString(keyed.key) orelse return, .value = keyed.value },
                                .list => continue,
                            };
                            if (!try self.stageLanguageRecord(temporary, &pending, &seen, row.key, row.value, kind)) return;
                        }
                    }
                },
                else => if (languageDataNestedWrite(stmt, kind)) return,
            }
        }
        for (pending.items) |entry| try self.addLocalAlias(entry.value, entry.key);
    }

    fn stageLanguageRecord(self: *const Registry, temporary: std.mem.Allocator, pending: *std.ArrayList(LocalName), seen: *std.ArrayList([]const u8), key: []const u8, expression: *const lua_parser.Expr, kind: LanguageDataKind) !bool {
        for (seen.items) |previous| if (std.mem.eql(u8, previous, key)) return false;
        try seen.append(temporary, key);
        const code_value = self.registeredLocalCode(key) orelse return true;
        const fields = literalTable(expression) orelse return true;
        const label_field = if (kind == .canonical_assignments) "canonicalName" else "name";
        var label: ?[]const u8 = null;
        var aliases: ?[]const lua_parser.TableField = null;
        var aliases_seen = false;
        for (fields) |field| {
            const row: LuaLiteralField = switch (field) {
                .named => |named| .{ .key = named.name, .value = named.value },
                .keyed => |keyed| .{ .key = literalString(keyed.key) orelse return true, .value = keyed.value },
                .list => continue,
            };
            if (std.mem.eql(u8, row.key, label_field)) {
                if (label != null) return true;
                label = literalString(row.value) orelse return true;
                if (!validLocalLabel(label.?)) return true;
            } else if (kind == .named_table and std.mem.eql(u8, row.key, "names")) {
                if (aliases_seen) return true;
                aliases_seen = true;
                aliases = literalTable(row.value) orelse return true;
                for (aliases.?) |alias| {
                    const value = switch (alias) {
                        .list => |item| literalString(item) orelse return true,
                        else => return true,
                    };
                    if (!validLocalLabel(value)) return true;
                }
            }
        }
        const name = label orelse return true;
        try pending.append(temporary, .{ .key = code_value, .value = name });
        if (aliases) |items| for (items) |alias| {
            try pending.append(temporary, .{ .key = code_value, .value = literalString(alias.list).? });
        };
        return true;
    }

    /// Import the literal register used by Module:sprǣcnaman, without executing
    /// its functions or importing unregistered language-family codes.
    pub fn addLocalNamesLua(self: *Registry, source: []const u8) !void {
        const owned = self.arena.allocator();
        const names = try localLiteralTable(owned, source, "names");
        const aliases = try localLiteralTable(owned, source, "aliases");
        var entries: std.ArrayList(LocalName) = .empty;
        for (names) |row| {
            if (!validCode(row.key) or row.value.len == 0 or
                std.mem.indexOfAny(u8, row.value, "\x00\n\r\t") != null)
                return error.InvalidLanguageRegistry;
            const code_value = self.registeredLocalCode(row.key) orelse continue;
            var duplicate = false;
            for (entries.items) |entry| {
                if (!std.mem.eql(u8, entry.key, code_value)) continue;
                if (!std.mem.eql(u8, entry.value, row.value)) return error.ConflictingLanguageHeading;
                duplicate = true;
            }
            if (!duplicate) try entries.append(owned, .{ .key = code_value, .value = row.value });
        }
        for (aliases, 0..) |row, index| {
            if (row.key.len == 0 or std.mem.indexOfAny(u8, row.key, "\x00\n\r\t") != null or !validCode(row.value))
                return error.InvalidLanguageRegistry;
            const code_value = self.registeredLocalCode(row.value) orelse continue;
            var imported = false;
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.key, code_value)) imported = true;
                if (std.mem.eql(u8, entry.value, row.key) and !std.mem.eql(u8, entry.key, code_value))
                    return error.ConflictingLanguageHeading;
            }
            if (!imported) return error.InvalidLanguageRegistry;
            for (aliases[0..index]) |previous| {
                if (!std.mem.eql(u8, previous.key, row.key)) continue;
                const previous_code = self.registeredLocalCode(previous.value) orelse return error.ConflictingLanguageHeading;
                if (!std.mem.eql(u8, previous_code, code_value)) return error.ConflictingLanguageHeading;
            }
        }
        for (entries.items) |entry| {
            var ambiguous = false;
            for (entries.items) |other| {
                if (std.mem.eql(u8, other.value, entry.value) and !std.mem.eql(u8, other.key, entry.key))
                    ambiguous = true;
            }
            if (ambiguous) {
                const heading = try self.disambiguatedHeading(entry.value, entry.key);
                try self.addStrongCanonical(heading, entry.key);
            } else {
                try self.addStrongCanonical(entry.value, entry.key);
            }
        }
        for (entries.items) |entry| {
            for (entries.items) |other| {
                if (!std.mem.eql(u8, other.value, entry.value) or std.mem.eql(u8, other.key, entry.key)) continue;
                if (self.codes.contains(entry.value)) return error.ConflictingLanguageHeading;
                if (self.canonical_names.get(entry.value)) |existing|
                    try self.rehomeExternalHeading(entry.value, existing);
                _ = self.names.remove(entry.value);
                _ = self.canonical_names.remove(entry.value);
                _ = self.strong_names.remove(entry.value);
                _ = self.trusted_names.remove(entry.value);
                try self.ambiguous.put(owned, entry.value, {});
            }
        }
        for (aliases) |row| {
            const code_value = self.registeredLocalCode(row.value) orelse continue;
            if (self.codes.contains(row.key) and !std.mem.eql(u8, row.key, code_value))
                return error.ConflictingLanguageHeading;
            if (self.canonical_names.get(row.key)) |existing| {
                if (!std.mem.eql(u8, existing, code_value)) try self.rehomeExternalHeading(row.key, existing);
            }
            try self.reserveCanonical(row.key, code_value);
            try self.trustStrong(row.key);
        }
    }

    pub fn fromLuaAlloc(a: std.mem.Allocator, source: []const u8) !Registry {
        var out = Registry.empty(a);
        errdefer out.deinit();
        try out.addLua(source);
        return out;
    }
};

const LocalName = struct { key: []const u8, value: []const u8 };
const LuaLiteralField = struct { key: []const u8, value: *const lua_parser.Expr };

fn validLocalLabel(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "\x00\n\r\t") == null;
}

fn literalString(expression: *const lua_parser.Expr) ?[]const u8 {
    return switch (expression.*) {
        .string => |value| value.value,
        else => null,
    };
}

fn literalTable(expression: *const lua_parser.Expr) ?[]const lua_parser.TableField {
    return switch (expression.*) {
        .table => |value| value.fields,
        else => null,
    };
}

fn literalName(expression: *const lua_parser.Expr, name: []const u8) bool {
    return switch (expression.*) {
        .name => |value| std.mem.eql(u8, value.value, name),
        .paren => |value| literalName(value.expr, name),
        else => false,
    };
}

fn languageDataRoot(kind: LanguageDataKind) []const u8 {
    return if (kind == .canonical_assignments) "m" else "data";
}

fn languageDataContainer(expression: *const lua_parser.Expr, kind: LanguageDataKind) bool {
    return switch (expression.*) {
        .name => |name| kind == .canonical_assignments and std.mem.eql(u8, name.value, "m"),
        .paren => |value| languageDataContainer(value.expr, kind),
        .index => |index| blk: {
            if (kind == .named_table and literalName(index.object, "data")) {
                const key = literalString(index.key) orelse break :blk true;
                break :blk std.mem.eql(u8, key, "lang_table");
            }
            break :blk languageDataContainer(index.object, kind);
        },
        else => false,
    };
}

fn languageDataTarget(target: lua_parser.LValue, kind: LanguageDataKind) bool {
    return switch (target) {
        .name => |name| std.mem.eql(u8, name, languageDataRoot(kind)),
        .index => |index| blk: {
            if (kind == .named_table and literalName(index.object, "data")) {
                const key = literalString(index.key) orelse break :blk true;
                break :blk std.mem.eql(u8, key, "lang_table");
            }
            break :blk languageDataContainer(index.object, kind);
        },
    };
}

fn languageDataBlockWrite(body: lua_parser.Block, kind: LanguageDataKind) bool {
    for (body) |stmt| if (languageDataNestedWrite(stmt, kind)) return true;
    return false;
}

fn languageDataReference(expression: *const lua_parser.Expr, kind: LanguageDataKind) bool {
    if (literalName(expression, languageDataRoot(kind)) or languageDataContainer(expression, kind)) return true;
    switch (expression.*) {
        .paren => |value| return languageDataReference(value.expr, kind),
        .index => |index| return languageDataReference(index.object, kind) or languageDataReference(index.key, kind),
        .unary => |value| return languageDataReference(value.expr, kind),
        .binary => |value| return languageDataReference(value.lhs, kind) or languageDataReference(value.rhs, kind),
        .call => |call| {
            if (languageDataReference(call.callee, kind)) return true;
            for (call.args) |argument| if (languageDataReference(argument, kind)) return true;
        },
        .method_call => |call| {
            if (languageDataReference(call.object, kind)) return true;
            for (call.args) |argument| if (languageDataReference(argument, kind)) return true;
        },
        .table => |table| for (table.fields) |field| {
            switch (field) {
                .list => |value| if (languageDataReference(value, kind)) return true,
                .named => |value| if (languageDataReference(value.value, kind)) return true,
                .keyed => |value| if (languageDataReference(value.key, kind) or languageDataReference(value.value, kind)) return true,
            }
        },
        else => {},
    }
    return false;
}

fn languageDataNestedWrite(stmt: *const lua_parser.Stmt, kind: LanguageDataKind) bool {
    switch (stmt.*) {
        .assign => |assignment| {
            for (assignment.targets) |target| if (languageDataTarget(target, kind)) return true;
            for (assignment.values) |value| if (languageDataExpressionWrite(value, kind) or languageDataReference(value, kind)) return true;
        },
        .local_assign => |assignment| {
            for (assignment.names) |name| if (std.mem.eql(u8, name, languageDataRoot(kind))) return true;
            for (assignment.values) |value| if (languageDataExpressionWrite(value, kind) or languageDataReference(value, kind)) return true;
        },
        .function_assign => |assignment| {
            if (languageDataTarget(assignment.target, kind)) return true;
            return languageDataExpressionWrite(assignment.function, kind);
        },
        .local_function => |function| {
            if (std.mem.eql(u8, function.name, languageDataRoot(kind))) return true;
            return languageDataExpressionWrite(function.function, kind);
        },
        .call => |call| return languageDataExpressionWrite(call.expr, kind),
        .do_block => |block| return languageDataBlockWrite(block.body, kind),
        .while_loop => |loop| return languageDataExpressionWrite(loop.cond, kind) or languageDataBlockWrite(loop.body, kind),
        .repeat_loop => |loop| return languageDataExpressionWrite(loop.cond, kind) or languageDataBlockWrite(loop.body, kind),
        .numeric_for => |loop| return languageDataExpressionWrite(loop.start, kind) or languageDataExpressionWrite(loop.limit, kind) or
            (if (loop.step) |step| languageDataExpressionWrite(step, kind) else false) or languageDataBlockWrite(loop.body, kind),
        .generic_for => |loop| {
            for (loop.values) |value| if (languageDataExpressionWrite(value, kind)) return true;
            return languageDataBlockWrite(loop.body, kind);
        },
        .if_stmt => |conditional| {
            for (conditional.branches) |branch|
                if (languageDataExpressionWrite(branch.cond, kind) or languageDataBlockWrite(branch.body, kind)) return true;
            if (conditional.else_body) |body| return languageDataBlockWrite(body, kind);
        },
        .return_stmt => |statement| {
            for (statement.values) |value| if (languageDataExpressionWrite(value, kind)) return true;
        },
        .empty, .break_stmt => {},
    }
    return false;
}

fn languageDataExpressionWrite(expression: *const lua_parser.Expr, kind: LanguageDataKind) bool {
    switch (expression.*) {
        .function => |function| return languageDataBlockWrite(function.body, kind),
        .paren => |value| return languageDataExpressionWrite(value.expr, kind),
        .index => |index| return languageDataExpressionWrite(index.object, kind) or languageDataExpressionWrite(index.key, kind),
        .unary => |value| return languageDataExpressionWrite(value.expr, kind),
        .binary => |value| return languageDataExpressionWrite(value.lhs, kind) or languageDataExpressionWrite(value.rhs, kind),
        .call => |call| {
            if (languageDataExpressionWrite(call.callee, kind)) return true;
            const read_iterator = literalName(call.callee, "pairs") or literalName(call.callee, "ipairs");
            for (call.args) |argument| {
                if (languageDataExpressionWrite(argument, kind)) return true;
                if (!read_iterator and (literalName(argument, languageDataRoot(kind)) or languageDataContainer(argument, kind))) return true;
            }
        },
        .method_call => |call| {
            if (literalName(call.object, languageDataRoot(kind)) or languageDataContainer(call.object, kind) or languageDataExpressionWrite(call.object, kind)) return true;
            for (call.args) |argument|
                if (languageDataExpressionWrite(argument, kind) or literalName(argument, languageDataRoot(kind)) or languageDataContainer(argument, kind)) return true;
        },
        .table => |table| for (table.fields) |field| {
            switch (field) {
                .list => |value| if (languageDataExpressionWrite(value, kind)) return true,
                .named => |value| if (languageDataExpressionWrite(value.value, kind)) return true,
                .keyed => |value| if (languageDataExpressionWrite(value.key, kind) or languageDataExpressionWrite(value.value, kind)) return true,
            }
        },
        else => {},
    }
    return false;
}

fn identifier(source: []const u8, p: *usize) ![]const u8 {
    skip(source, p);
    const start = p.*;
    if (start == source.len or !(std.ascii.isAlphabetic(source[start]) or source[start] == '_'))
        return error.InvalidLanguageRegistry;
    p.* += 1;
    while (p.* < source.len and (std.ascii.isAlphanumeric(source[p.*]) or source[p.*] == '_')) : (p.* += 1) {}
    return source[start..p.*];
}

fn skipQuoted(source: []const u8, p: *usize) !void {
    const quote = source[p.*];
    p.* += 1;
    while (p.* < source.len) {
        const ch = source[p.*];
        p.* += 1;
        if (ch == quote) return;
        if (ch == '\\' and p.* < source.len) p.* += 1;
    }
    return error.InvalidLanguageRegistry;
}

fn localLiteralTable(a: std.mem.Allocator, source: []const u8, wanted: []const u8) ![]const LocalName {
    var rows: std.ArrayList(LocalName) = .empty;
    var found = false;
    var p: usize = 0;
    while (true) {
        skip(source, &p);
        if (p == source.len) break;
        if (source[p] == '"' or source[p] == '\'') {
            try skipQuoted(source, &p);
            continue;
        }
        if (!(std.ascii.isAlphabetic(source[p]) or source[p] == '_')) {
            // Long Lua strings must not expose apparent local declarations.
            if (source[p] == '[') {
                var end = p + 1;
                while (end < source.len and source[end] == '=') : (end += 1) {}
                if (end < source.len and source[end] == '[') {
                    const equals = source[p + 1 .. end];
                    var scan = end + 1;
                    while (std.mem.indexOfScalarPos(u8, source, scan, ']')) |close| {
                        const last = close + 1 + equals.len;
                        if (last < source.len and source[last] == ']' and std.mem.eql(u8, source[close + 1 .. last], equals)) {
                            p = last + 1;
                            break;
                        }
                        scan = close + 1;
                    } else return error.InvalidLanguageRegistry;
                    continue;
                }
            }
            p += 1;
            continue;
        }
        const token = try identifier(source, &p);
        if (!std.mem.eql(u8, token, "local")) continue;
        const name = try identifier(source, &p);
        if (!std.mem.eql(u8, name, wanted)) continue;
        if (found) return error.InvalidLanguageRegistry;
        found = true;
        try expect(source, &p, '=');
        try expect(source, &p, '{');
        while (true) {
            skip(source, &p);
            if (p == source.len) return error.InvalidLanguageRegistry;
            if (source[p] == '}') {
                p += 1;
                break;
            }
            const key = if (source[p] == '[') blk: {
                p += 1;
                const value = try string(a, source, &p);
                try expect(source, &p, ']');
                break :blk value;
            } else try identifier(source, &p);
            try expect(source, &p, '=');
            const value = try string(a, source, &p);
            for (rows.items) |row| {
                if (std.mem.eql(u8, row.key, key) and !std.mem.eql(u8, row.value, value))
                    return error.ConflictingLanguageHeading;
            }
            try rows.append(a, .{ .key = key, .value = value });
            skip(source, &p);
            if (p == source.len) return error.InvalidLanguageRegistry;
            if (source[p] == ',' or source[p] == ';') {
                p += 1;
            } else if (source[p] != '}') return error.InvalidLanguageRegistry;
        }
    }
    if (!found) return error.InvalidLanguageRegistry;
    return rows.items;
}

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

test "dump local literal names preserve aliases and ambiguous language labels" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("ang\tÆnglisc\tang\nen\tEnglish\ten\nfr\tFrench\tfr\tfra\nfrk\tFrankish\tfrk\n");
    try r.addLua("return { [\"English\"] = \"en\" }");
    try r.addLocalNamesLua(
        "--[=[ local names = { ang = \"Wrong\" } ]=]\n" ++
            "local ignored = [==[ local names = {} ]==]\n" ++
            "local names = { ang = \"Englisc\", en = \"Nīwenglisc\", fr = \"Frencisc\", " ++
            "fra = \"Frencisc\", frk = \"Frencisc\", [\"gem-pro\"] = \"Ealdoric Germanisc\" }\n" ++
            "local of_names = { ang = \"Englisce\" }\n" ++
            "local aliases = { [\"Ænglisc\"] = \"ang\" }\n" ++
            "local function get_name(code) return names[code] end\nreturn { get_name = get_name }",
    );
    try std.testing.expectEqualStrings("Englisc", r.resolve("ang").?.heading);
    try std.testing.expectEqualStrings("ang", r.resolveStrong("Englisc").?.code);
    try std.testing.expectEqualStrings("Englisc", r.resolveStrong("Ænglisc").?.heading);
    try std.testing.expectEqualStrings("en", r.resolveStrong("Nīwenglisc").?.code);
    try std.testing.expectEqualStrings("Nīwenglisc", r.resolve("English").?.heading);
    try std.testing.expect(r.resolve("Frencisc") == null);
    try std.testing.expect(r.resolveStrong("Frencisc") == null);
    try std.testing.expectEqualStrings("Frencisc (fr)", r.resolve("fr").?.heading);
    try std.testing.expectEqualStrings("fr", r.resolve("fra").?.code);
    try std.testing.expectEqualStrings("Frencisc (frk)", r.resolve("frk").?.heading);
    try std.testing.expect(r.resolve("gem-pro") == null);
    try std.testing.expect(r.resolve("Ealdoric Germanisc") == null);
    try std.testing.expect(r.resolve("Englisce") == null);
}

test "dump local names reject computed and conflicting table input" {
    for ([_][]const u8{
        "local names = { ang = make_name() } local aliases = {}",
        "local names = { ang = \"Old\" .. \" English\" } local aliases = {}",
        "local names = { ang = \"Old\" en = \"English\" } local aliases = {}",
        "local names = {} local names = {} local aliases = {}",
        "local names = {}",
        "local names = {} local aliases = { [\"Old\"] = code }",
    }) |source| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ang\tOld English\tang\nen\tEnglish\ten\n");
        try std.testing.expectError(error.InvalidLanguageRegistry, r.addLocalNamesLua(source));
    }
    for ([_][]const u8{
        "local names = { ang = \"Old\", ang = \"Other\" } local aliases = {}",
        "local names = { ang = \"Old\", en = \"English\" } local aliases = { [\"Old\"] = \"en\" }",
        "local names = { ang = \"Old\", en = \"English\" } local aliases = { [\"Alias\"] = \"ang\", [\"Alias\"] = \"en\" }",
    }) |source| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ang\tOld English\tang\nen\tEnglish\ten\n");
        try std.testing.expectError(error.ConflictingLanguageHeading, r.addLocalNamesLua(source));
    }
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

test "Arabic preferred articleless headings retain canonical language names" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(
        "# mediawiki\n" ++
            "ar\tالعربية\tar\tArabic\tara\n" ++
            "en\tالإنجليزية\ten\tEnglish\teng\n" ++
            "fr\tالفرنسية\tfr\tFrench\tfra\n" ++
            "ar\tالعربية\tar\n" ++
            "# content-language\tar\n",
    );
    inline for (.{
        .{ "عربية", "ar", "العربية" },
        .{ "إنجليزية", "en", "الإنجليزية" },
        .{ "فرنسية", "fr", "الفرنسية" },
    }) |expected| {
        try std.testing.expectEqualStrings(expected[1], r.code(expected[0]).?);
        try std.testing.expectEqualStrings(expected[1], r.resolve(expected[0]).?.code);
        try std.testing.expectEqualStrings(expected[2], r.resolveTrusted(expected[0]).?.heading);
        try std.testing.expectEqualStrings(expected[2], r.resolve(expected[1]).?.heading);
        try std.testing.expect(r.resolveStrong(expected[0]) == null);
        try std.testing.expect(!r.names.contains(expected[0]));
    }
}

test "Arabic articleless aliases require the Arabic edition and preferred provenance" {
    for ([_][]const u8{ "", "# content-language\ten\n" }) |metadata| {
        var other = Registry.empty(std.testing.allocator);
        defer other.deinit();
        try other.addTsv("ar\tالعربية\nen\tEnglish\n");
        try other.addTsv(metadata);
        try std.testing.expect(other.code("عربية") == null);
        try std.testing.expect(other.resolve("عربية") == null);
        try std.testing.expect(other.resolveTrusted("عربية") == null);
        try std.testing.expectEqualStrings("ar", other.resolve("العربية").?.code);
    }

    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(
        "# content-language\tar\n" ++
            "# mediawiki\n" ++
            "ar\tالعربية\tالإضافية\n" ++
            "en\tال\n" ++
            "# iso-639-3\n" ++
            "fr\tالفرنسية\n",
    );
    for ([_][]const u8{ "إضافية", "فرنسية", "", "مجهولة", "عَرَبِيَّة", " عربية", "عربية ", "الْعربية" }) |name| {
        try std.testing.expect(r.code(name) == null);
        try std.testing.expect(r.resolve(name) == null);
        try std.testing.expect(r.resolveTrusted(name) == null);
    }
    try std.testing.expectEqualStrings("ar", r.resolve("الإضافية").?.code);
    try std.testing.expectEqualStrings("fr", r.resolve("الفرنسية").?.code);
    try std.testing.expect(r.resolveTrusted("الإضافية") == null);
    try std.testing.expect(r.resolveTrusted("الفرنسية") == null);
}

test "exact aliases and ambiguity take precedence over Arabic derived trust" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(
        "# content-language\tar\n" ++
            "ar\tالعربية\n" ++
            "en\tالإنجليزية\tعربية\tإنجليزية\n" ++
            "fr\tالفرنسية\n",
    );
    try std.testing.expectEqualStrings("en", r.code("عربية").?);
    try std.testing.expectEqualStrings("الإنجليزية", r.resolve("عربية").?.heading);
    try std.testing.expectEqualStrings("en", r.resolve("إنجليزية").?.code);
    try std.testing.expect(r.resolveTrusted("عربية") == null);
    try std.testing.expect(r.resolveTrusted("إنجليزية") == null);

    try r.addTsv("fr\tالفرنسية\tعربية\n");
    try std.testing.expect(r.ambiguous.contains("عربية"));
    try std.testing.expect(r.code("عربية") == null);
    try std.testing.expect(r.resolve("عربية") == null);
    try std.testing.expect(r.resolveTrusted("عربية") == null);
}

test "conflicting preferred Arabic derived candidates remain rejected" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(
        "# content-language\tar\n" ++
            "ar\tالعربية\n" ++
            "en\tEnglish\n" ++
            "en\tالعربية\n" ++
            "ar\tالعربية\n",
    );
    // The exact canonical name remains reserved, but conflicting derived rows
    // are rejected even if another copy of the first row appears later.
    try std.testing.expectEqualStrings("ar", r.resolveTrusted("العربية").?.code);
    try std.testing.expect(r.code("عربية") == null);
    try std.testing.expect(r.resolve("عربية") == null);
    try std.testing.expect(r.resolveTrusted("عربية") == null);
}

test "Arabic derived names follow current headings and reject stale provenance" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tar\nar\tالعربية\nen\tEnglish\n");
    try r.addLua("return { [\"Arabic\"] = \"ar\" }");
    try std.testing.expectEqualStrings("Arabic", r.resolve("عربية").?.heading);
    try std.testing.expectEqualStrings("Arabic", r.resolveTrusted("عربية").?.heading);

    try r.addLua("return { [\"العربية\"] = \"en\" }");
    try std.testing.expectEqualStrings("en", r.resolveStrong("العربية").?.code);
    try std.testing.expect(r.code("عربية") == null);
    try std.testing.expect(r.resolveTrusted("عربية") == null);
    // Even a lingering trust marker cannot validate changed source ownership.
    try r.trustAlias("العربية");
    try std.testing.expect(r.resolve("عربية") == null);
    try std.testing.expect(r.resolveTrusted("عربية") == null);
}

test "literal canonical language records add aliases without changing preferred headings" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tar\nar\tالعربية\npi\tالبالية\nmg\tالملغاشي\nen\tالإنجليزية\n");
    try r.addLanguageDataLua(
        "--[=[ m['pi']={canonicalName='Comment only'} ]=]\n" ++
            "local u=mw.ustring.char; local mark=u(0x0300); local m={}\n" ++
            "m['pi']={canonicalName='بالي',otherNames={'Unselected alias'},sort_key={from={mark},to={u(97)}}}\n" ++
            "m[\"mg\"]={[\"canonicalName\"]='ملغاشية'}\n" ++
            "m['en']={canonicalName=make_name()}\n" ++
            "m['ca-valencia']={canonicalName='Unknown code'}\nreturn m",
        .canonical_assignments,
    );
    try std.testing.expectEqualStrings("pi", r.code("بالي").?);
    try std.testing.expectEqualStrings("البالية", r.resolveTrusted("بالي").?.heading);
    try std.testing.expectEqualStrings("mg", r.resolveTrusted("ملغاشية").?.code);
    try std.testing.expectEqualStrings("الملغاشي", r.resolve("mg").?.heading);
    try std.testing.expect(r.resolveStrong("بالي") == null);
    for ([_][]const u8{ "Comment only", "Unselected alias", "Unknown code" }) |label|
        try std.testing.expect(r.resolve(label) == null);
}

test "literal named language table ignores code arrays and rejects label collisions" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tar\nar\tالعربية\npi\tالبالية\nban\tالبالينية\nms\tالماليزية\nota\tOttoman Turkish\n");
    try r.addLanguageDataLua(
        "--[[ data.lang_table={['ar']={name='Comment only'}} ]]\n" ++
            "local data={}; data['lang_table']={\n" ++
            " ['pi']={name='بالية',names={'بالي'},codes={'ignored-code'}},\n" ++
            " ['ban']={name='بالية'},\n" ++
            " ['ms']={name='ملايوية',names={'Malay local'},codes={'ar','invented'}},\n" ++
            " ['ota']={name='تركية عثمانية'},\n" ++
            " ['ca-valencia']={name='Unregistered dialect'},\n" ++
            " ['ar_001']={name='Unsupported key'} }\n" ++
            "data.lang_codes={}; for code,v in pairs(data.lang_table) do data.lang_codes[v.name]=code end\nreturn data",
        .named_table,
    );
    try std.testing.expect(r.resolve("بالية") == null);
    try std.testing.expect(r.resolveTrusted("بالية") == null);
    try std.testing.expectEqualStrings("pi", r.resolveTrusted("بالي").?.code);
    try std.testing.expectEqualStrings("ms", r.resolveTrusted("ملايوية").?.code);
    try std.testing.expectEqualStrings("الماليزية", r.resolveTrusted("Malay local").?.heading);
    try std.testing.expectEqualStrings("ota", r.resolveTrusted("تركية عثمانية").?.code);
    try std.testing.expectEqualStrings("ar", r.code("ar").?);
    for ([_][]const u8{ "ignored-code", "invented", "Unregistered dialect", "Unsupported key", "Comment only" }) |label|
        try std.testing.expect(r.resolve(label) == null);
}

test "local aliases preserve exact trust and reject local or article conflicts" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tar\nar\tالعربية\ten\nfr\tالفرنسية\tExact ordinary\nen\tالإنجليزية\tAmbiguous\npi\tالبالية\tAmbiguous\n");
    try r.addLocalAlias("Exact ordinary", "en");
    try std.testing.expectEqualStrings("fr", r.resolve("Exact ordinary").?.code);
    try std.testing.expect(r.resolveTrusted("Exact ordinary") == null);
    try r.addLocalAlias("العربية", "en");
    try std.testing.expectEqualStrings("ar", r.resolveTrusted("العربية").?.code);
    try r.addLocalAlias("Ambiguous", "en");
    try std.testing.expect(r.resolve("Ambiguous") == null);
    try r.addLocalAlias("عربية", "en");
    try std.testing.expect(r.resolve("عربية") == null);
    try r.addLocalAlias("فرنسية", "fr");
    try std.testing.expectEqualStrings("fr", r.resolveTrusted("فرنسية").?.code);
    try r.addLocalAlias("Repeated", "pi");
    try r.addLocalAlias("Repeated", "pi");
    try std.testing.expectEqualStrings("pi", r.code("Repeated").?);
    try r.addLocalAlias("Repeated", "en");
    try r.addLocalAlias("Repeated", "pi");
    try std.testing.expect(r.resolve("Repeated") == null);
    try r.addLocalAlias("xyz", "ar");
    try r.addLocalAlias("Manufactured code", "xyz");
    try std.testing.expect(r.resolve("Manufactured code") == null);
    try std.testing.expect(r.resolveStrong("xyz") == null);
}

test "dynamic relevant fields never supply literal language aliases" {
    for ([_][]const u8{
        "canonicalName='Rejected',canonicalName=make_name()",
        "canonicalName=make_name(),canonicalName='Rejected'",
        "canonicalName='Rejected',['canonicalName']='Other'",
        "canonicalName='Rejected',[field]='Other'",
    }) |fields| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ca\tCatalan\npi\tPali\n");
        const source = try std.fmt.allocPrint(std.testing.allocator, "local m={{}}; m['ca']={{{s}}}; m['pi']={{canonicalName='Accepted'}}; return m", .{fields});
        defer std.testing.allocator.free(source);
        try r.addLanguageDataLua(source, .canonical_assignments);
        try std.testing.expect(r.resolve("Rejected") == null);
        try std.testing.expect(r.resolve("Other") == null);
        try std.testing.expectEqualStrings("pi", r.resolveTrusted("Accepted").?.code);
    }
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("ca\tCatalan\npi\tPali\n");
    try r.addLanguageDataLua("local data={}; data.lang_table={ca={name='Rejected',names={'Literal',make_name()}},pi={name='Accepted'}}; return data", .named_table);
    try std.testing.expect(r.resolve("Rejected") == null);
    try std.testing.expect(r.resolve("Literal") == null);
    try std.testing.expectEqualStrings("pi", r.resolveTrusted("Accepted").?.code);
}

test "later writes and escaped canonical data invalidate staged aliases" {
    for ([_][]const u8{
        "m['ca']=make_record()",
        "m['ca'].canonicalName=make_name()",
        "m[key]={canonicalName='Dynamic key'}",
        "m={}",
        "m['ca'],m['pi']=make_records()",
        "if condition then m['ca'].canonicalName='Changed' end",
        "local function mutate() m['ca'].canonicalName='Changed' end",
        "local x=mutate(m)",
        "x=mutate(m)",
        "local alias=m; alias['ca']={canonicalName='Changed'}",
        "m['pi']={canonicalName='Other',callback=function() m['ca']=make_record() end}",
    }) |later| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ca\tCatalan\npi\tPali\n");
        const source = try std.fmt.allocPrint(std.testing.allocator, "local m={{}}; m['ca']={{canonicalName='Staged'}}; {s}; return m", .{later});
        defer std.testing.allocator.free(source);
        try r.addLanguageDataLua(source, .canonical_assignments);
        try std.testing.expect(r.resolve("Staged") == null);
    }
}

test "named language table replacement and dynamic rows invalidate staged aliases" {
    for ([_][]const u8{
        "data.lang_table=make_table()",
        "data.lang_table['ca']={name='Changed'}",
        "(data)['lang_table']['ca'].name=make_name()",
        "if condition then data.lang_table['ca'].names={'Changed'} end",
        "local alias=data.lang_table; alias.ca={name='Changed'}",
        "local x=mutate(data)",
    }) |later| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ca\tCatalan\n");
        const source = try std.fmt.allocPrint(std.testing.allocator, "local data={{}}; data.lang_table={{ca={{name='Staged'}}}}; {s}; return data", .{later});
        defer std.testing.allocator.free(source);
        try r.addLanguageDataLua(source, .named_table);
        try std.testing.expect(r.resolve("Staged") == null);
    }
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("ca\tCatalan\n");
    try r.addLanguageDataLua("local data={}; data.lang_table={ca={name='Staged'},[key]={name='Dynamic key'}}; return data", .named_table);
    try std.testing.expect(r.resolve("Staged") == null);
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
