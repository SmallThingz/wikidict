//! Build-time parser for Wiktionary and pinned site language metadata.
const std = @import("std");
const lua_parser = @import("lua_parser");

// Same full-uppercase ABI used by Lua ustring. Used only while loading TSV;
// no dynamic loading, casing or allocation occurs in resolveTrusted.
const PreferredUpper = struct {
    const CaseFn = *const fn ([*]const u8, usize, ?[*:0]const u8, ?*anyopaque, ?[*]u8, *usize) callconv(.c) ?[*]u8;
    lib: std.DynLib,
    upper: CaseFn,

    fn init() !PreferredUpper {
        var lib = std.DynLib.open("libunistring.so.5") catch try std.DynLib.open("libunistring.so");
        errdefer lib.close();
        return .{ .lib = lib, .upper = lib.lookup(CaseFn, "u8_toupper") orelse return error.UnicodeCaseUnavailable };
    }

    fn deinit(self: *PreferredUpper) void {
        self.lib.close();
    }

    fn firstAlloc(self: *const PreferredUpper, a: std.mem.Allocator, preferred: []const u8) ![]u8 {
        const first_len = try std.unicode.utf8ByteSequenceLength(preferred[0]);
        var buffer: [64]u8 = undefined;
        var length: usize = buffer.len;
        const mapped = self.upper(preferred.ptr, first_len, null, null, &buffer, &length) orelse return error.UnicodeCaseFailed;
        defer if (mapped != &buffer) std.c.free(@ptrCast(mapped));
        return std.mem.concat(a, u8, &.{ mapped[0..length], preferred[first_len..] });
    }
};

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

pub const SourceLanguageBanner = struct {
    heading: []const u8, level: u8, target: []const u8, label: []const u8,
    authority: enum { known_names, literal_code } = .known_names,
};

pub const SourceLanguageParagraph = struct { label: []const u8, category: []const u8 };

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    ambiguous: std.StringHashMapUnmanaged(void) = .empty,
    language_boundaries: std.StringHashMapUnmanaged(void) = .empty,
    codes: std.StringHashMapUnmanaged(void) = .empty,
    trusted_names: std.StringHashMapUnmanaged(void) = .empty,
    autonym_headings: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    preferred_capitalizations: std.StringHashMapUnmanaged([]const u8) = .empty,
    strong_names: std.StringHashMapUnmanaged(void) = .empty,
    canonical_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    headings: std.StringHashMapUnmanaged([]const u8) = .empty,
    arabic_articleless_names: std.StringHashMapUnmanaged(?DerivedPreferredName) = .empty,
    local_aliases: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    reviewed_aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    source_banners: std.StringHashMapUnmanaged(?SourceLanguageBanner) = .empty,
    source_paragraphs: std.StringHashMapUnmanaged(?SourceLanguageParagraph) = .empty,
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
        self.language_boundaries.deinit(self.arena.allocator());
        self.codes.deinit(self.arena.allocator());
        self.trusted_names.deinit(self.arena.allocator());
        self.autonym_headings.deinit(self.arena.allocator());
        self.preferred_capitalizations.deinit(self.arena.allocator());
        self.strong_names.deinit(self.arena.allocator());
        self.canonical_names.deinit(self.arena.allocator());
        self.arabic_articleless_names.deinit(self.arena.allocator());
        self.local_aliases.deinit(self.arena.allocator());
        self.reviewed_aliases.deinit(self.arena.allocator());
        self.source_banners.deinit(self.arena.allocator());
        self.source_paragraphs.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isAmbiguous(self: *const Registry, heading: []const u8) bool {
        return self.ambiguous.contains(heading);
    }

    /// Positive boundary evidence does not resolve, trust or create an owner.
    pub fn isLanguageBoundary(self: *const Registry, heading: []const u8) bool {
        return self.isAmbiguous(heading) or self.language_boundaries.contains(heading);
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
        // The pinned generator includes first-letter capitalizations of its
        // preferred labels. Admit that exact existing alias for the same owner;
        // other ordinary aliases, code aliases, and conflicts retain their trust.
        if (self.names.get(value)) |owner| {
            if (!self.trusted_names.contains(value) and !self.isTrustedReviewed(value, owner) and !self.isTrustedAutonym(value, owner)) {
                const preferred = self.headings.get(owner) orelse return null;
                const preferred_owner = self.names.get(preferred) orelse return null;
                if (!self.trusted_names.contains(preferred) or
                    !std.mem.eql(u8, owner, preferred_owner) or
                    !self.isPreferredCapitalization(preferred, value)) return null;
            }
        } else if (self.fallbackCode(value) == null) return null;
        return self.resolve(value);
    }

    /// Editorial aliases classify only their exact heading; they cannot seed
    /// source-derived equivalence for additional template names.
    pub fn resolveSourceTrusted(self: *const Registry, value: []const u8) ?Resolved {
        if (self.reviewed_aliases.contains(value)) {
            const owner = self.names.get(value) orelse return null;
            if (!self.trusted_names.contains(value) and !self.isTrustedAutonym(value, owner)) return null;
        }
        return self.resolveTrusted(value);
    }

    pub fn resolveStrong(self: *const Registry, value: []const u8) ?Resolved {
        if (!self.strong_names.contains(value) or !self.names.contains(value)) return null;
        return self.resolve(value);
    }

    fn isPreferredCapitalization(self: *const Registry, preferred: []const u8, value: []const u8) bool {
        if (preferred.len == 0) return false;
        if (preferred[0] < 0x80) return value.len == preferred.len and
            std.ascii.isLower(preferred[0]) and value[0] == std.ascii.toUpper(preferred[0]) and
            std.mem.eql(u8, value[1..], preferred[1..]);
        const expected = self.preferred_capitalizations.get(preferred) orelse return false;
        return std.mem.eql(u8, expected, value);
    }

    fn recordPreferredCapitalization(self: *Registry, mapper: *?PreferredUpper, preferred: []const u8) !void {
        // Invalid UTF-8 does not acquire new trust or change existing TSV parsing.
        if (preferred.len == 0 or preferred[0] < 0x80 or
            self.preferred_capitalizations.contains(preferred) or
            !std.unicode.utf8ValidateSlice(preferred)) return;
        if (mapper.* == null) mapper.* = try PreferredUpper.init();
        const owned = self.arena.allocator();
        const mapped = try mapper.*.?.firstAlloc(owned, preferred);
        errdefer owned.free(mapped);
        // Cache only the expected spelling, not an alias or a trust grant.
        // A later TSV/Lua load may install the alias. resolveTrusted always
        // rechecks actual alias/preferred ownership and preferred trust.
        if (std.mem.eql(u8, mapped, preferred)) {
            owned.free(mapped);
            return;
        }
        const key = try owned.dupe(u8, preferred);
        errdefer owned.free(key);
        try self.preferred_capitalizations.put(owned, key, mapped);
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
            if (self.reviewed_aliases.get(value)) |reviewed|
                if (!std.mem.eql(u8, reviewed, local_code)) return null;
            return local_code;
        }
        if (self.reviewed_aliases.get(value)) |reviewed| {
            if (!self.codes.contains(reviewed)) return null;
            if (article_code) |other| if (!std.mem.eql(u8, other, reviewed)) return null;
            return reviewed;
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

    /// ASCII case tolerance belongs only to an authenticated source-banner proof.
    /// Code aliases and any competing/ambiguous folded spelling provide no proof.
    pub fn sourceBannerNameMatches(self: *const Registry, code_value: []const u8, value: []const u8) bool {
        return self.sourceBannerNameAllowed(code_value, value, true);
    }
    /// Only an authenticated static banner's explicit literal code may use an
    /// unknown local label. This grants no ordinary alias or heading boundary.
    pub fn sourceBannerLiteralCodeNameCompatible(self: *const Registry, code_value: []const u8, value: []const u8) bool {
        return self.sourceBannerNameAllowed(code_value, value, false);
    }
    fn sourceBannerNameAllowed(self: *const Registry, code_value: []const u8, value: []const u8, require_known: bool) bool {
        if (!self.codes.contains(code_value) or value.len == 0) return false;
        var found = false;
        var names = self.names.iterator();
        while (names.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, value)) continue;
            if (!std.mem.eql(u8, entry.value_ptr.*, code_value)) return false;
            if (self.codes.contains(entry.key_ptr.*)) continue;
            found = true;
        }
        var ambiguous = self.ambiguous.iterator();
        while (ambiguous.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, value)) return false;
        var local = self.local_aliases.iterator();
        while (local.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, value)) continue;
            const owner = entry.value_ptr.* orelse return false;
            if (!std.mem.eql(u8, owner, code_value)) return false;
        }
        var reviewed = self.reviewed_aliases.iterator();
        while (reviewed.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, value) and
                !std.mem.eql(u8, entry.value_ptr.*, code_value)) return false;
        }
        return found or !require_known;
    }
    fn sourceBannerNamesAllowed(self: *const Registry, code_value: []const u8, proof: SourceLanguageBanner) bool {
        const require_known = proof.authority == .known_names;
        return self.sourceBannerNameAllowed(code_value, proof.target, require_known) and
            self.sourceBannerNameAllowed(code_value, proof.label, require_known);
    }
    pub fn addSourceLanguageBanner(self: *Registry, code_value: []const u8, proof: SourceLanguageBanner) !void {
        if (!self.sourceBannerNamesAllowed(code_value, proof)) return;
        if (self.source_banners.getPtr(code_value)) |stored| {
            if (stored.*) |previous| {
                if (previous.authority != proof.authority or previous.level != proof.level or !std.mem.eql(u8, previous.heading, proof.heading) or
                    !std.mem.eql(u8, previous.target, proof.target) or !std.mem.eql(u8, previous.label, proof.label)) stored.* = null;
            }
            return;
        }
        const a = self.arena.allocator();
        try self.source_banners.put(a, try a.dupe(u8, code_value), .{
            .heading = try a.dupe(u8, proof.heading), .level = proof.level,
            .target = try a.dupe(u8, proof.target), .label = try a.dupe(u8, proof.label),
            .authority = proof.authority,
        });
    }
    pub fn matchesSourceLanguageBanner(self: *const Registry, code_value: []const u8, heading: []const u8, level: u8) bool {
        const proof = (self.source_banners.get(code_value) orelse return false) orelse return false;
        return proof.level == level and std.mem.eql(u8, proof.heading, heading) and
            self.sourceBannerNamesAllowed(code_value, proof);
    }

    pub fn sourceParagraphNameMatches(self: *const Registry, code_value: []const u8, label: []const u8) bool {
        // A reviewed-only alias cannot seed a source declaration. The exact
        // independently stored name and all ordinary conflict checks are required.
        const owner = self.names.get(label) orelse return false;
        if (self.codes.contains(label) or !std.mem.eql(u8, owner, code_value) or
            !self.sourceBannerNameMatches(code_value, label)) return false;
        const trusted = self.resolveStrong(label) orelse self.resolveSourceTrusted(label) orelse return false;
        return std.mem.eql(u8, trusted.code, code_value);
    }
    pub fn addSourceLanguageParagraph(self: *Registry, code_value: []const u8, proof: SourceLanguageParagraph) !void {
        if (!self.sourceParagraphNameMatches(code_value, proof.label)) return;
        if (self.source_paragraphs.getPtr(code_value)) |stored| {
            if (stored.*) |previous| {
                if (!std.mem.eql(u8, previous.label, proof.label) or
                    !std.mem.eql(u8, previous.category, proof.category)) stored.* = null;
            }
            return;
        }
        const a = self.arena.allocator();
        try self.source_paragraphs.put(a, try a.dupe(u8, code_value), .{
            .label = try a.dupe(u8, proof.label), .category = try a.dupe(u8, proof.category),
        });
    }
    pub fn matchesSourceLanguageParagraph(self: *const Registry, code_value: []const u8, line: []const u8) bool {
        const proof = (self.source_paragraphs.get(code_value) orelse return false) orelse return false;
        return self.sourceParagraphNameMatches(code_value, proof.label) and
            line.len == proof.label.len + proof.category.len and
            std.mem.startsWith(u8, line, proof.label) and std.mem.endsWith(u8, line, proof.category);
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
        var preferred_upper: ?PreferredUpper = null;
        defer if (preferred_upper) |*mapper| mapper.deinit();
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
                const boundary_marker = "# local-language-boundary\t";
                if (std.mem.eql(u8, line, "# local-language-boundary")) return error.InvalidLanguageRegistry;
                if (std.mem.startsWith(u8, line, boundary_marker)) {
                    const label = line[boundary_marker.len..];
                    if (!validLocalHeading(label)) return error.InvalidLanguageRegistry;
                    const owned = self.arena.allocator();
                    try self.language_boundaries.put(owned, try owned.dupe(u8, label), {});
                    continue;
                }
                const heading_marker = "# local-heading\t";
                if (std.mem.eql(u8, line, "# local-heading")) return error.InvalidLanguageRegistry;
                if (std.mem.startsWith(u8, line, heading_marker)) {
                    var fields = std.mem.splitScalar(u8, line[heading_marker.len..], '\t');
                    const code_value = fields.next() orelse return error.InvalidLanguageRegistry;
                    const label = fields.next() orelse return error.InvalidLanguageRegistry;
                    if (fields.next() != null or !validCode(code_value) or !self.codes.contains(code_value) or
                        !validLocalHeading(label)) return error.InvalidLanguageRegistry;
                    continue;
                }
                const local_marker = "# local-alias\t";
                if (std.mem.eql(u8, line, "# local-alias")) return error.InvalidLanguageRegistry;
                if (std.mem.startsWith(u8, line, local_marker)) {
                    var fields = std.mem.splitScalar(u8, line[local_marker.len..], '\t');
                    const code_value = fields.next() orelse return error.InvalidLanguageRegistry;
                    const label = fields.next() orelse return error.InvalidLanguageRegistry;
                    if (fields.next() != null or !validCode(code_value) or !self.codes.contains(code_value) or !validLocalLabel(label)) return error.InvalidLanguageRegistry;
                    continue;
                }
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
            if (mediawiki_rows) try self.recordPreferredCapitalization(&preferred_upper, preferred);
        }
        // Ordinary aliases and canonical ownership must be installed before local directives.
        var local_lines = std.mem.splitScalar(u8, source, '\n');
        while (local_lines.next()) |line| {
            const marker = "# local-alias\t";
            if (!std.mem.startsWith(u8, line, marker)) continue;
            var fields = std.mem.splitScalar(u8, line[marker.len..], '\t');
            const code_value = fields.next().?;
            const label = fields.next().?;
            try self.addLocalAlias(label, code_value);
        }
        // A reviewed heading can trust only an exact pre-existing unique label.
        // Resolve after all ordinary rows, independently of directive placement.
        var heading_lines = std.mem.splitScalar(u8, source, '\n');
        while (heading_lines.next()) |line| {
            const marker = "# local-heading\t";
            if (!std.mem.startsWith(u8, line, marker)) continue;
            var fields = std.mem.splitScalar(u8, line[marker.len..], '\t');
            const code_value = fields.next().?;
            const label = fields.next().?;
            try self.trustLocalHeading(code_value, label);
        }
        var reviewed_lines = std.mem.splitScalar(u8, source, '\n');
        while (reviewed_lines.next()) |line| {
            if (std.mem.eql(u8, line, "# reviewed-alias")) return error.InvalidLanguageRegistry;
            if (std.mem.startsWith(u8, line, "# reviewed-alias\t")) try self.addReviewedMarker(line);
        }
        // Curated ANG historical heading from the 20261001 archive: thirteen
        // uses "Níwe Englisc"; its language category describes Modern English,
        // whose captured Nīwenglisc entry and sprǣcnaman register identify en.
        // This is a reviewed local alias, not a literal upstream alias record.
        // Keep the exact edition/spelling and all existing conflict checks.
        if (std.mem.eql(u8, self.content_code orelse "", "ang")) {
            try self.addLocalAlias("Níwe Englisc", "en");
            // Exact macron spelling is independently attested by the same
            // archive's language category and its acute-category redirect.
            try self.addLocalAlias("Nīwe Englisc", "en");
            // Gast names this exact historical heading; its retained language
            // categories and sprǣcnaman register identify Old High German only.
            try self.addLocalAlias("Eald Hēah Þēodisc", "goh");
            // Land names this exact heading; its noun category and sprǣcnaman
            // register independently identify Old Norse, not Old English.
            try self.addLocalAlias("Ealdnoren", "non");
            // Exact authored Middle heading is only a known unresolved boundary.
            // Do not lend its body to the preceding resolved Old High German.
            const owned = self.arena.allocator();
            try self.language_boundaries.put(owned, try owned.dupe(u8, "Middel Hēah Þēodisc"), {});
            // Dagur and ek attest Faroisc as a distinct language label. Its
            // exact canonical code is unproven; never inherit preceding Icelandic.
            try self.language_boundaries.put(owned, try owned.dupe(u8, "Faroisc"), {});
        }
        // The retained AF Sjabloon:se names this exact Northern Sami heading.
        // Keep canonical names and all existing local/ordinary conflict rules.
        if (std.mem.eql(u8, self.content_code orelse "", "af")) {
            try self.addLocalAlias("Samies (Noord-)", "se");
        }
        // Exact retained KBD template p28/r283 emits this heading. Meta explicitly
        // identifies its name with installed code kbd (not an edition default):
        // https://meta.wikimedia.org/w/index.php?title=Requests_for_new_languages/Wiktionary_Kabardian&oldid=27638979
        // Existing aliases, canonical owners and ambiguities retain precedence.
        if (self.codes.contains("kbd"))
            try self.addLocalAlias("АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)", "kbd");
        if (self.content_code) |code_value| {
            if (self.resolve(code_value) == null) return error.InvalidLanguageRegistry;
        }
    }

    /// Module:langues/data stores literal names in l[code].nom. Its retained
    /// get_nom provider reads that field; aliases copy already-created records.
    /// Stage the complete immutable table before admitting any local evidence.
    pub fn addNomLanguageDataLua(self: *Registry, source: []const u8) !void {
        var chunk = lua_parser.parse(self.arena.child_allocator, source) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer chunk.deinit();
        const temporary = chunk.arena.allocator();
        var labels: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        var initialized = false;
        var exported = false;
        for (chunk.body) |stmt| {
            if (exported) return;
            switch (stmt.*) {
                .local_assign => |v| {
                    if (initialized or v.names.len != 1 or !std.mem.eql(u8, v.names[0], "l") or v.values.len != 1) return;
                    const fields = literalTable(v.values[0]) orelse return;
                    if (fields.len != 0) return;
                    initialized = true;
                },
                .assign => |v| {
                    if (!initialized or v.targets.len != 1 or v.values.len != 1) return;
                    const target = switch (v.targets[0]) { .index => |x| x, else => return };
                    if (!literalName(target.object, "l")) return;
                    const key = literalString(target.key) orelse return;
                    var label: ?[]const u8 = null;
                    switch (v.values[0].*) {
                        .table => |table| {
                            for (table.fields) |field| {
                                const row: LuaLiteralField = switch (field) {
                                    .named => |named| .{ .key = named.name, .value = named.value },
                                    .keyed => |keyed| .{ .key = literalString(keyed.key) orelse return, .value = keyed.value },
                                    .list => return,
                                };
                                if (!nomLiteralValue(row.value, 0)) return;
                                if (std.mem.eql(u8, row.key, "nom")) {
                                    if (label != null) return;
                                    label = literalString(row.value) orelse return;
                                    if (!validLocalHeading(label.?)) return;
                                }
                            }
                        },
                        .index => |alias| {
                            if (!literalName(alias.object, "l")) return;
                            const prior = literalString(alias.key) orelse return;
                            label = labels.get(prior) orelse null;
                        },
                        else => return,
                    }
                    // Sequential overwrites and already-created record aliases
                    // retain Lua table semantics; nested record mutation is absent.
                    try labels.put(temporary, key, label);
                },
                .return_stmt => |v| {
                    if (!initialized or v.values.len != 1 or !literalName(v.values[0], "l")) return;
                    exported = true;
                },
                else => return,
            }
        }
        if (!exported) return;
        var rows = labels.iterator();
        while (rows.next()) |row| {
            const label = row.value_ptr.* orelse continue;
            const code_value = self.registeredLocalCode(row.key_ptr.*) orelse continue;
            try self.addLocalAlias(label, code_value);
            // The heading provider applies ucfirst. Promote only its exact
            // already-registered ASCII first-letter spelling, never casefold.
            if (try nomCapitalizationAlloc(temporary, label)) |capital| {
                if (self.names.get(capital)) |owner| if (std.mem.eql(u8, owner, code_value))
                    try self.addLocalAlias(capital, code_value);
            }
        }
        // Finish competing source rows before promoting any existing alias.
        rows = labels.iterator();
        while (rows.next()) |row| {
            const label = row.value_ptr.* orelse continue;
            const code_value = self.registeredLocalCode(row.key_ptr.*) orelse continue;
            try self.trustNomExisting(code_value, label);
            if (try nomCapitalizationAlloc(temporary, label)) |capital|
                try self.trustNomExisting(code_value, capital);
        }
    }

    fn trustNomExisting(self: *Registry, code_value: []const u8, name: []const u8) !void {
        if (self.localHeadingMatches(code_value, name) and
            self.sourceBannerLiteralCodeNameCompatible(code_value, name))
            try self.trustAlias(name);
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

    fn isTrustedReviewed(self: *const Registry, name: []const u8, owner: []const u8) bool {
        const reviewed = self.reviewed_aliases.get(name) orelse return false;
        if (!self.codes.contains(reviewed) or self.ambiguous.contains(name) or !std.mem.eql(u8, reviewed, owner)) return false;
        if (self.local_aliases.get(name)) |local| {
            const code_value = local orelse return false;
            if (!std.mem.eql(u8, code_value, owner)) return false;
        }
        return true;
    }

    // Editorial evidence is separate from source names and strong banner proof.
    // The marker binds the exact reviewed file, not a claimed upstream capture.
    fn addReviewedMarker(self: *Registry, line: []const u8) !void {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        const code_value = fields.next() orelse return error.InvalidLanguageRegistry;
        const name = fields.next() orelse return error.InvalidLanguageRegistry;
        const reference = fields.next() orelse return error.InvalidLanguageRegistry;
        const digest = fields.next() orelse return error.InvalidLanguageRegistry;
        if (fields.next() != null) return error.InvalidLanguageRegistry;
        const evidence = @embedFile("reviewed_language_aliases.json");
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(evidence, &hash, .{});
        if (!std.mem.eql(u8, digest, &std.fmt.bytesToHex(hash, .lower))) return error.InvalidLanguageRegistry;
        const parsed = try std.json.parseFromSlice(struct {
            schema: []const u8,
            records: []const struct { id: []const u8, code: []const u8, alias: []const u8, authority_kind: []const u8 },
        }, self.arena.allocator(), evidence, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "wikidict.reviewed-language-aliases.v1")) return error.InvalidLanguageRegistry;
        var matches: usize = 0;
        for (parsed.value.records) |record| {
            if (std.mem.eql(u8, reference, record.id) and std.mem.eql(u8, code_value, record.code) and
                std.mem.eql(u8, name, record.alias) and std.mem.eql(u8, record.authority_kind, "reviewed_public_reference")) matches += 1;
        }
        if (matches != 1 or !validLocalHeading(name) or !self.codes.contains(code_value)) return error.InvalidLanguageRegistry;
        if (self.ambiguous.contains(name)) return;
        if (self.names.get(name)) |owner| if (!std.mem.eql(u8, owner, code_value)) return;
        if (self.local_aliases.get(name)) |local| {
            const owner = local orelse return;
            if (!std.mem.eql(u8, owner, code_value)) return;
        }
        const owned = self.arena.allocator();
        try self.reviewed_aliases.put(owned, try owned.dupe(u8, name), try owned.dupe(u8, code_value));
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

    /// Curated edition-local evidence may promote an existing exact label,
    /// never create an alias, change its owner or make unrelated ISO names trusted.
    fn trustLocalHeading(self: *Registry, code_value: []const u8, label: []const u8) !void {
        if (!self.localHeadingMatches(code_value, label)) return error.InvalidLanguageRegistry;
        try self.trustAlias(label);
    }

    fn localHeadingMatches(self: *const Registry, code_value: []const u8, label: []const u8) bool {
        if (!validLocalHeading(label) or !self.codes.contains(code_value) or self.ambiguous.contains(label)) return false;
        const owner = self.names.get(label) orelse return false;
        if (!std.mem.eql(u8, owner, code_value)) return false;
        if (self.local_aliases.get(label)) |candidate| {
            const local_code = candidate orelse return false;
            if (!std.mem.eql(u8, local_code, code_value)) return false;
        }
        return true;
    }

    fn isTrustedAutonym(self: *const Registry, label: []const u8, owner: []const u8) bool {
        const attested = (self.autonym_headings.get(label) orelse return false) orelse return false;
        return std.mem.eql(u8, attested, owner) and self.localHeadingMatches(attested, label);
    }

    /// Promote only exact installed aliases independently present in the captured
    /// null-display autonym profile. Translated UI profiles are not heading proof.
    pub fn trustAutonymSnapshot(self: *Registry, source: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !void {
        if (source.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(source)) return error.InvalidLanguageNameSnapshot;
        if (!std.mem.eql(u8, self.content_code orelse "", language)) return error.InvalidLanguageNameSnapshot;
        var temporary = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        var lines = std.mem.splitScalar(u8, source, '\n');
        const expected_headers = [_][]const u8{
            "# wikidict-language-names-v1",
            try std.fmt.allocPrint(a, "# wiki\t{s}", .{wiki}),
            try std.fmt.allocPrint(a, "# dump-date\t{s}", .{date}),
            try std.fmt.allocPrint(a, "# content-language\t{s}", .{language}),
        };
        for (expected_headers) |expected| {
            if (!std.mem.eql(u8, lines.next() orelse return error.InvalidLanguageNameSnapshot, expected)) return error.InvalidLanguageNameSnapshot;
        }
        var expected_count: ?usize = null;
        var count: usize = 0;
        var codes: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        var pending: std.ArrayList(struct { code: []const u8, name: []const u8 }) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const tag = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            const display = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            const scope = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            if (std.mem.eql(u8, tag, "D")) {
                if (fields.next() != null or !autonymCodeValid(display) or
                    (!std.mem.eql(u8, scope, "ltr") and !std.mem.eql(u8, scope, "rtl"))) return error.InvalidLanguageNameSnapshot;
                continue;
            }
            const autonym = std.mem.eql(u8, display, "-") and std.mem.eql(u8, scope, "single");
            const direction = std.mem.eql(u8, display, "-") and std.mem.eql(u8, scope, "dir") and std.mem.eql(u8, tag, "C");
            if (!autonym and !direction and (!autonymCodeValid(display) or
                (!std.mem.eql(u8, scope, "all") and !std.mem.eql(u8, scope, "mw") and !std.mem.eql(u8, scope, "single")))) return error.InvalidLanguageNameSnapshot;
            if (std.mem.eql(u8, tag, "C")) {
                const value = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null) return error.InvalidLanguageNameSnapshot;
                const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLanguageNameSnapshot;
                if (n > 20031) return error.InvalidLanguageNameSnapshot;
                if (autonym) {
                    if (expected_count != null) return error.DuplicateLanguageNameProfile;
                    expected_count = n;
                }
            } else if (std.mem.eql(u8, tag, "N")) {
                const code_value = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const raw_name = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null or !autonymCodeValid(code_value)) return error.InvalidLanguageNameSnapshot;
                if (!autonym) continue;
                const n = expected_count orelse return error.IncompleteLanguageNameProfile;
                if (count >= n) return error.IncompleteLanguageNameProfile;
                count += 1;
                const seen = try codes.getOrPut(a, code_value);
                if (seen.found_existing) return error.DuplicateLanguageName;
                const name = try decodeAutonymName(a, raw_name);
                if (name.len == 0) continue;
                const known = try names.getOrPut(a, name);
                if (known.found_existing) {
                    if (known.value_ptr.*) |owner| {
                        if (!std.mem.eql(u8, owner, code_value)) known.value_ptr.* = null;
                    }
                } else known.value_ptr.* = code_value;
                try pending.append(a, .{ .code = code_value, .name = name });
            } else return error.InvalidLanguageNameSnapshot;
        }
        if (expected_count) |n| {
            if (count != n) return error.IncompleteLanguageNameProfile;
        } else return; // Older captures have no null-display profile.
        // Validate the complete selected profile before changing any trust.
        // A code alias, missing label, ambiguous name or later local conflict
        // cannot acquire authority from this independent spelling evidence.
        for (pending.items) |row| {
            if (!validLocalHeading(row.name) or !self.codes.contains(row.code) or self.ambiguous.contains(row.name)) continue;
            const profile_owner = names.get(row.name).? orelse continue;
            if (!std.mem.eql(u8, profile_owner, row.code)) continue;
            const owner = self.names.get(row.name) orelse continue;
            if (!std.mem.eql(u8, owner, row.code)) continue;
            if (self.local_aliases.get(row.name)) |local| {
                const local_owner = local orelse continue;
                if (!std.mem.eql(u8, local_owner, row.code)) continue;
            }
            if (!self.localHeadingMatches(row.code, row.name)) continue;
            if (self.autonym_headings.getPtr(row.name)) |proof| {
                if (proof.*) |previous| {
                    if (!std.mem.eql(u8, previous, row.code)) proof.* = null;
                }
            } else {
                const owned = self.arena.allocator();
                const key = try owned.dupe(u8, row.name);
                errdefer owned.free(key);
                const code_value = try owned.dupe(u8, row.code);
                errdefer owned.free(code_value);
                try self.autonym_headings.put(owned, key, code_value);
            }
        }
    }

    fn autonymCodeValid(code_value: []const u8) bool {
        if (code_value.len < 2 or code_value.len > 128) return false;
        for (code_value) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
        return true;
    }

    fn decodeAutonymName(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        if (raw.len > 8192 or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidLanguageNameSnapshot;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\') {
                try out.append(a, raw[i]);
                continue;
            }
            i += 1;
            if (i == raw.len) return error.InvalidLanguageNameSnapshot;
            try out.append(a, switch (raw[i]) {
                '\\' => '\\', 't' => '\t', 'n' => '\n', 'r' => '\r',
                else => return error.InvalidLanguageNameSnapshot,
            });
        }
        if (out.items.len > 4096) return error.InvalidLanguageNameSnapshot;
        return try out.toOwnedSlice(a);
    }

    /// Positional records are names only when the actual normal provider proves
    /// the getter, exported table and field-one-preserving finalizer contract.
    pub const PositionalLanguageProvider = enum { canonical_field_one };

    pub fn provePositionalLanguageProvider(a: std.mem.Allocator, source: []const u8) !?PositionalLanguageProvider {
        return if (try positionalLanguageProviderProof(a, source)) .canonical_field_one else null;
    }

    // The normal loader obtains this immutable proof once from the authenticated
    // provider source, then independently authenticates each data module.
    pub fn addPositionalLanguageDataLua(self: *Registry, source: []const u8, _: PositionalLanguageProvider, module_base: []const u8) !void {
        try positionalLanguageDataImport(self, source, module_base);
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

fn validLocalHeading(value: []const u8) bool {
    if (!validLocalLabel(value) or !std.unicode.utf8ValidateSlice(value) or
        !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n")) or
        std.mem.indexOfAny(u8, value, "{}[]<>|=") != null) return false;
    for (value) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

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
    try std.testing.expect(r.isAmbiguous("Frencisc"));
    try std.testing.expect(!r.isAmbiguous("Unknown topic"));
    try std.testing.expect(!r.isAmbiguous("Nīwenglisc"));
    try std.testing.expect(r.resolve("Frencisc") == null);
    try std.testing.expect(r.resolveStrong("Frencisc") == null);
    try std.testing.expectEqualStrings("Frencisc (fr)", r.resolve("fr").?.heading);
    try std.testing.expectEqualStrings("fr", r.resolve("fra").?.code);
    try std.testing.expectEqualStrings("Frencisc (frk)", r.resolve("frk").?.heading);
    try std.testing.expect(r.resolve("gem-pro") == null);
    try std.testing.expect(r.resolve("Ealdoric Germanisc") == null);
    try std.testing.expect(r.resolve("Englisce") == null);
    const code_count = r.codes.count();
    try r.addTsv("# local-language-boundary\tMiddelhēahþēodisc\n# local-language-boundary\tMiddelhēahþēodisc\n# local-language-boundary\tNīwenglisc\n");
    try std.testing.expect(r.isLanguageBoundary("Middelhēahþēodisc"));
    try std.testing.expect(!r.isAmbiguous("Middelhēahþēodisc"));
    try std.testing.expect(r.resolve("Middelhēahþēodisc") == null);
    try std.testing.expect(!r.names.contains("Middelhēahþēodisc"));
    try std.testing.expectEqual(code_count, r.codes.count());
    try std.testing.expectEqualStrings("en", r.resolveStrong("Nīwenglisc").?.code);
    for ([_][]const u8{
        "# local-language-boundary",            "# local-language-boundary\t",
        "# local-language-boundary\t Label",    "# local-language-boundary\tLabel\textra",
        "# local-language-boundary\tBad|label", "# local-language-boundary\tBad\x00label",
        "# local-language-boundary\t\xff",
    }) |bad| {
        var invalid = Registry.empty(std.testing.allocator);
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidLanguageRegistry, invalid.addTsv(bad));
    }
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

test "capitalized preferred language aliases preserve trust and exact conflicts" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tay\n# mediawiki\nay\tAymar aru\tay\nru\truso\tRuso\tRUSO\trUsO\tRussian\tru\trus\nsyn\tSenaya\tsyn\nnum\tniuafoou\tnum\nadj\tadioukrou\tadj\n# iso-639-3\nxxy\talpha\tAlpha\n");
    try std.testing.expectEqualStrings("ru", r.resolveTrusted("Ruso").?.code);
    try std.testing.expectEqualStrings("ruso", r.resolveTrusted("Ruso").?.heading);
    try std.testing.expectEqualStrings("ru", r.resolveTrusted("ruso").?.code);
    try std.testing.expect(r.resolveStrong("Ruso") == null);
    for ([_][]const u8{ "RUSO", "rUsO", "Russian", "ru", "rus", "syn", "num", "adj", "Alpha", "RusO" }) |label|
        try std.testing.expect(r.resolveTrusted(label) == null);
    try r.addLocalAlias("RUSO", "ru");
    try std.testing.expect(r.resolveTrusted("RUSO") == null);
    try r.addTsv("# mediawiki\nen\tEnglish\tRuso\n");
    try std.testing.expect(r.resolve("Ruso") == null);
    try std.testing.expect(r.resolveTrusted("Ruso") == null);
    try std.testing.expectEqualStrings("ru", r.resolveTrusted("ruso").?.code);

    var exact = Registry.empty(std.testing.allocator);
    defer exact.deinit();
    try exact.addTsv("ru\truso\tRuso\nxx\tRuso\n");
    try std.testing.expectEqualStrings("xx", exact.resolveTrusted("Ruso").?.code);
    try std.testing.expectEqualStrings("ru", exact.resolveTrusted("ruso").?.code);
}

test "AZ declaration aliases stay ordinary and conflicting source aliases remain unresolved" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\taz\naz\tazərbaycanca\tAzərbaycan dili\nen\tingilis\tİngilis dili\tConflicted dili\ntr\ttürk\tConflicted dili\nadj\tAdioukrou\nsyn\tSenaya\n");
    try std.testing.expectEqualStrings("en", r.resolve("İngilis dili").?.code);
    try std.testing.expectEqualStrings("az", r.resolve("Azərbaycan dili").?.code);
    try std.testing.expect(r.resolveTrusted("İngilis dili") == null);
    try std.testing.expect(r.resolveStrong("İngilis dili") == null);
    try std.testing.expect(r.resolveTrusted("Azərbaycan dili") == null);
    try std.testing.expect(r.resolve("Conflicted dili") == null);
    try std.testing.expect(r.resolveTrusted("Conflicted dili") == null);
    try std.testing.expect(r.resolve("Adjective") == null);
    try std.testing.expect(r.resolve("Synonyms") == null);
}

test "explicit local alias directives preserve registry identity and trust" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# local-alias\tceb\tSinugbuanon\nceb\tCebuano\tOrdinary alias\ncts\tNorthern Catanduanes Bikol\n# local-alias\tcts\tBikol Catanduanes\n# local-alias\tcts\tOrdinary alias\n# local-alias\tcts\tCebuano\n");
    try std.testing.expectEqualStrings("ceb", r.resolveTrusted("Sinugbuanon").?.code);
    try std.testing.expectEqualStrings("Cebuano", r.resolveTrusted("Sinugbuanon").?.heading);
    try std.testing.expectEqualStrings("cts", r.resolveTrusted("Bikol Catanduanes").?.code);
    try std.testing.expect(r.resolveTrusted("Ordinary alias") == null);
    try std.testing.expectEqualStrings("ceb", r.resolve("Ordinary alias").?.code);
    try std.testing.expectEqualStrings("ceb", r.resolveTrusted("Cebuano").?.code);
    try std.testing.expectEqual(@as(usize, 2), r.codes.count());
    try r.addTsv("# local-alias\tceb\tConflicting\n# local-alias\tcts\tConflicting\n");
    try std.testing.expect(r.resolveTrusted("Conflicting") == null);
}

test "explicit local alias directives reject malformed or unregistered inputs" {
    for ([_][]const u8{
        "# local-alias",                "# local-alias\tceb",              "# local-alias\tceb\t",
        "# local-alias\tunknown\tName", "# local-alias\tceb\tName\textra", "# local-alias\tceb\tBad\x00Name",
    }) |directive| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv("ceb\tCebuano\n");
        try std.testing.expectError(error.InvalidLanguageRegistry, r.addTsv(directive));
    }
}

test "explicit local alias directives do not depend on row order" {
    for ([_]bool{ false, true }) |before| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        const directives = "# local-alias\tcts\tOrdinary\n# local-alias\tcts\tCebuano\n# local-alias\tceb\tAmbiguous\n";
        const rows = "ceb\tCebuano\tOrdinary\tAmbiguous\ncts\tNorthern Catanduanes Bikol\tAmbiguous\n";
        const source = if (before) directives ++ rows else rows ++ directives;
        try r.addTsv(source);
        try std.testing.expect(r.resolveTrusted("Ordinary") == null);
        try std.testing.expectEqualStrings("ceb", r.resolve("Ordinary").?.code);
        try std.testing.expectEqualStrings("ceb", r.resolveTrusted("Cebuano").?.code);
        try std.testing.expect(r.resolveTrusted("Ambiguous") == null);
        try std.testing.expectEqual(@as(usize, 2), r.codes.count());
    }
}

test "curated ANG historical heading resolves through the captured canonical register" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tang\nang\tÆnglisc\tang\nen\tEnglish\ten\n");
    // Exact archived Module:sprǣcnaman literals (page 8074); the older heading
    // is deliberately absent from that module's own aliases table.
    try r.addLocalNamesLua("local names = { ang = \"Englisc\", en = \"Nīwenglisc\" }\nlocal aliases = { [\"Ænglisc\"] = \"ang\" }\n");
    for ([_][]const u8{ "Níwe Englisc", "Nīwe Englisc" }) |heading| {
        const resolved = r.resolveTrusted(heading).?;
        try std.testing.expectEqualStrings("en", resolved.code);
        try std.testing.expectEqualStrings("Nīwenglisc", resolved.heading);
    }
    try std.testing.expectEqualStrings("Englisc", r.resolve("ang").?.heading);
    try std.testing.expectEqual(@as(usize, 2), r.codes.count());
    for ([_][]const u8{ "Niwe Englisc", "níwe englisc", "Níwe  Englisc", "nīwe englisc", "Nīwe  Englisc" }) |other|
        try std.testing.expect(r.resolve(other) == null);
}

test "curated ANG heading requires the exact edition and a registered English code" {
    var other = Registry.empty(std.testing.allocator);
    defer other.deinit();
    try other.addTsv("# content-language\ten\nen\tEnglish\nenm\tMiddle English\n");
    for ([_][]const u8{ "Níwe Englisc", "Nīwe Englisc" }) |heading|
        try std.testing.expect(other.resolve(heading) == null);
    var missing = Registry.empty(std.testing.allocator);
    defer missing.deinit();
    try missing.addTsv("# content-language\tang\nang\tÆnglisc\n");
    for ([_][]const u8{ "Níwe Englisc", "Nīwe Englisc" }) |heading|
        try std.testing.expect(missing.resolve(heading) == null);
    try std.testing.expectEqual(@as(usize, 1), missing.codes.count());
}

test "curated ANG heading cannot replace or promote captured aliases" {
    inline for (.{ "Níwe Englisc", "Nīwe Englisc" }) |heading| {
        var ordinary = Registry.empty(std.testing.allocator);
        defer ordinary.deinit();
        try ordinary.addTsv("# content-language\tang\nang\tÆnglisc\nen\tEnglish\nfr\tFrench\t" ++ heading ++ "\n");
        try std.testing.expectEqualStrings("fr", ordinary.resolve(heading).?.code);
        try std.testing.expect(ordinary.resolveTrusted(heading) == null);
        var conflict = Registry.empty(std.testing.allocator);
        defer conflict.deinit();
        try conflict.addTsv("# content-language\tang\nang\tÆnglisc\nen\tEnglish\nfr\tFrench\n# local-alias\tfr\t" ++ heading ++ "\n");
        try std.testing.expect(conflict.resolve(heading) == null);
        var identical = Registry.empty(std.testing.allocator);
        defer identical.deinit();
        try identical.addTsv("# content-language\tang\nang\tÆnglisc\nen\tEnglish\n# local-alias\ten\t" ++ heading ++ "\n");
        try std.testing.expectEqualStrings("en", identical.resolveTrusted(heading).?.code);
    }
}

test "reviewed local heading trusts only its existing exact registered owner" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tam\n# mediawiki\nam\tአማርኛ\n# iso-639-3\nngh\tNǁng\tNǀuu\nen\tEnglish\tOrdinary alias\n");
    try std.testing.expectEqualStrings("ngh", r.resolve("Nǁng").?.code);
    try std.testing.expect(r.resolveTrusted("Nǁng") == null);
    const name_count = r.names.count();
    try r.addTsv("# local-heading\tngh\tNǁng\n# local-heading\tngh\tNǁng\n");
    try std.testing.expectEqualStrings("ngh", r.resolveTrusted("Nǁng").?.code);
    try std.testing.expectEqualStrings("Nǁng", r.resolveTrusted("Nǁng").?.heading);
    try std.testing.expect(r.resolveStrong("Nǁng") == null);
    try std.testing.expectEqual(name_count, r.names.count());
    try std.testing.expect(r.resolveTrusted("Nǀuu") == null);
    try std.testing.expect(r.resolveTrusted("English") == null);
    try std.testing.expect(r.resolveTrusted("Ordinary alias") == null);
    try r.addLocalAlias("Ordinary alias", "en");
    try std.testing.expect(r.resolveTrusted("Ordinary alias") == null);
    try r.addLocalAlias("New local alias", "en");
    try std.testing.expectEqualStrings("en", r.resolveTrusted("New local alias").?.code);
}

test "reviewed local headings reject absent conflicted and malformed labels or codes" {
    const rows = "# iso-639-3\nngh\tNǁng\tShared\tBad|label\tBad\x01label\t\xff\nen\tEnglish\tShared\teng\n";
    for ([_][]const u8{
        "# local-heading",                 "# local-heading\tngh",               "# local-heading\tngh\t",
        "# local-heading\tunknown\tNǁng",
        "# local-heading\ten\tNǁng",
        "# local-heading\tngh\tAbsent",    "# local-heading\tngh\tShared",       "# local-heading\teng\tEnglish",
        "# local-heading\tngh\tNǁng\textra",
        "# local-heading\tngh\t Nǁng",
        "# local-heading\tngh\tBad|label", "# local-heading\tngh\tBad\x01label", "# local-heading\tngh\t\xff",
        "# local-heading\tngh\tNǁng\n# local-heading\ten\tNǁng",
        "# local-alias\ten\tNǁng\n# local-heading\tngh\tNǁng",
    }) |directive| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv(rows);
        try std.testing.expectError(error.InvalidLanguageRegistry, r.addTsv(directive));
    }
    var local_only = Registry.empty(std.testing.allocator);
    defer local_only.deinit();
    try local_only.addTsv("ngh\tNǁng\n# local-alias\tngh\tNot captured\n");
    try std.testing.expectError(error.InvalidLanguageRegistry, local_only.addTsv("# local-heading\tngh\tNot captured\n"));
}

test "reviewed local heading directives are independent of ordinary row order" {
    const rows = "# iso-639-3\nngh\tNǁng\tNǀuu\nen\tEnglish\n";
    const directive = "# local-heading\tngh\tNǁng\n";
    for ([_]bool{ false, true }) |before| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv(if (before) directive ++ rows else rows ++ directive);
        try std.testing.expectEqualStrings("ngh", r.resolveTrusted("Nǁng").?.code);
        try std.testing.expect(r.resolveTrusted("Nǀuu") == null);
        try std.testing.expect(r.resolveTrusted("English") == null);
    }
    // A same-text ordinary alias for another owner remains ambiguous, regardless of placement.
    const ambiguous_rows = "# iso-639-3\nngh\tNǁng\tShared\nen\tEnglish\tShared\n";
    const ambiguous_directive = "# local-heading\tngh\tShared\n";
    for ([_]bool{ false, true }) |before| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try std.testing.expectError(error.InvalidLanguageRegistry, r.addTsv(if (before) ambiguous_directive ++ ambiguous_rows else ambiguous_rows ++ ambiguous_directive));
    }
}

test "curated ANG Old High German heading resolves exactly without broad German inference" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tang\nang\tÆnglisc\ngoh\tOld High German\nnon\tOld Norse\ngmh\tMiddle High German\nde\tGerman\n");
    try r.addLocalNamesLua("local names = { ang = \"Englisc\", goh = \"Ealdhēahþēodisc\", non = \"Eald Noren\" }\nlocal aliases = {}\n");
    const resolved = r.resolveTrusted("Eald Hēah Þēodisc").?;
    try std.testing.expectEqualStrings("goh", resolved.code);
    try std.testing.expectEqualStrings("Ealdhēahþēodisc", resolved.heading);
    const norse = r.resolveTrusted("Ealdnoren").?;
    try std.testing.expectEqualStrings("non", norse.code);
    try std.testing.expectEqualStrings("Eald Noren", norse.heading);
    try std.testing.expect(r.resolve("ealdnoren") == null);
    try std.testing.expect(r.resolve("Eald noren") == null);
    try std.testing.expect(r.isLanguageBoundary("Middel Hēah Þēodisc"));
    try std.testing.expect(r.resolve("Middel Hēah Þēodisc") == null);
    try std.testing.expect(r.resolveTrusted("Middel Hēah Þēodisc") == null);
    try std.testing.expect(!r.isLanguageBoundary("Unrelated topic"));
    try std.testing.expect(!r.isLanguageBoundary("Middel Hēah  Þēodisc"));
    try std.testing.expect(r.resolve("Hēah Þēodisc") == null);
    try std.testing.expect(r.resolve("Eald Hēah  Þēodisc") == null);
    try std.testing.expectEqualStrings("de", r.resolve("German").?.code);
    var other = Registry.empty(std.testing.allocator);
    defer other.deinit();
    try other.addTsv("# content-language\ten\nen\tEnglish\ngoh\tOld High German\nnon\tOld Norse\n");
    try std.testing.expect(other.resolve("Eald Hēah Þēodisc") == null);
    try std.testing.expect(other.resolve("Ealdnoren") == null);
    try std.testing.expect(other.resolveTrusted("Ealdnoren") == null);
    try std.testing.expect(!other.isLanguageBoundary("Middel Hēah Þēodisc"));
    try std.testing.expect(other.resolveTrusted("Middel Hēah Þēodisc") == null);
    var missing = Registry.empty(std.testing.allocator);
    defer missing.deinit();
    try missing.addTsv("# content-language\tang\nang\tÆnglisc\nde\tGerman\n");
    try std.testing.expect(missing.resolve("Eald Hēah Þēodisc") == null);
    try std.testing.expect(missing.resolve("Ealdnoren") == null);
    try std.testing.expect(missing.resolveTrusted("Ealdnoren") == null);
    try std.testing.expect(missing.isLanguageBoundary("Middel Hēah Þēodisc"));
    try std.testing.expect(missing.resolve("Middel Hēah Þēodisc") == null);
}

test "exact ANG Faroisc remains an ownerless language boundary beside registered Icelandic and Faroese" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tang\nang\tOld English\nis\tIcelandic\nfo\tFaroese\n");
    try r.addLocalNamesLua("local names = { ang = \"Englisc\", is = \"Īslendisc\", fo = \"Faerisc\" }\nlocal aliases = {}\n");
    try std.testing.expectEqualStrings("is", r.resolveStrong("Īslendisc").?.code);
    try std.testing.expectEqualStrings("fo", r.resolveStrong("Faerisc").?.code);
    try std.testing.expect(r.isLanguageBoundary("Faroisc"));
    try std.testing.expect(r.resolve("Faroisc") == null);
    try std.testing.expect(r.resolveTrusted("Faroisc") == null);
    try std.testing.expect(!r.isLanguageBoundary("faroisc"));
    try std.testing.expect(!r.isLanguageBoundary("Faro isc"));
    try std.testing.expect(!r.isLanguageBoundary("Unrelated topic"));
    var other = Registry.empty(std.testing.allocator);
    defer other.deinit();
    try other.addTsv("# content-language\ten\nen\tEnglish\nis\tIcelandic\nfo\tFaroese\n");
    try std.testing.expect(!other.isLanguageBoundary("Faroisc"));
    try std.testing.expect(other.resolveTrusted("Faroisc") == null);
    var missing = Registry.empty(std.testing.allocator);
    defer missing.deinit();
    try missing.addTsv("# content-language\tang\nang\tOld English\nis\tIcelandic\n");
    try std.testing.expect(missing.isLanguageBoundary("Faroisc"));
    try std.testing.expect(missing.resolve("Faroisc") == null);
    try std.testing.expect(missing.resolveTrusted("Faroisc") == null);
}

test "AF Northern Sami source heading resolves through ordinary TSV initialization" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv(
        "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\nmul\tMeertalig\n" ++
            "# local-language-boundary\tInternasionaal\n",
    );
    const resolved = registry.resolveTrusted("Samies (Noord-)");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("se", resolved.?.code);
    try std.testing.expectEqualStrings("Noord-Sami", resolved.?.heading);
    try std.testing.expectEqualStrings("Noord-Sami", registry.resolve("se").?.heading);
    try std.testing.expect(registry.resolveStrong("Samies (Noord-)") == null);
    try std.testing.expect(registry.resolveTrusted("Samies") == null);
    try std.testing.expect(registry.resolveTrusted("Samies (Noord)") == null);
    try std.testing.expect(registry.resolveTrusted("Internasionaal") == null);
    try std.testing.expect(registry.isLanguageBoundary("Internasionaal"));
}

test "AF Northern Sami curated alias preserves captured trust conflicts and edition boundaries" {
    const cases = [_]struct { source: []const u8, trusted: ?[]const u8, ordinary: ?[]const u8 }{
        .{ .source = "# content-language\ten\n# mediawiki\nen\tEngels\naf\tAfrikaans\nse\tNoord-Sami\n", .trusted = null, .ordinary = null },
        .{ .source = "# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\n", .trusted = null, .ordinary = null },
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nsme\tNorthern Sami\n", .trusted = null, .ordinary = null },
        // A literal preferred name for another owner keeps its captured authority.
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\nfr\tSamies (Noord-)\n", .trusted = "fr", .ordinary = "fr" },
        // Ordinary aliases must not become trusted merely due to the curated alias.
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\nfr\tFrans\tSamies (Noord-)\n", .trusted = null, .ordinary = "fr" },
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\tSamies (Noord-)\n", .trusted = null, .ordinary = "se" },
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\nfr\tFrans\tSamies (Noord-)\nen\tEngels\tSamies (Noord-)\n", .trusted = null, .ordinary = null },
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\nfr\tFrans\n# local-alias\tfr\tSamies (Noord-)\n", .trusted = null, .ordinary = null },
        .{ .source = "# content-language\taf\n# mediawiki\naf\tAfrikaans\nse\tNoord-Sami\n# local-alias\tse\tSamies (Noord-)\n", .trusted = "se", .ordinary = "se" },
    };
    for (cases) |case| {
        var registry = Registry.empty(std.testing.allocator);
        defer registry.deinit();
        try registry.addTsv(case.source);
        const trusted = registry.resolveTrusted("Samies (Noord-)");
        if (case.trusted) |code_value| {
            try std.testing.expect(trusted != null);
            try std.testing.expectEqualStrings(code_value, trusted.?.code);
        } else try std.testing.expect(trusted == null);
        const ordinary = registry.resolve("Samies (Noord-)");
        if (case.ordinary) |code_value| {
            try std.testing.expect(ordinary != null);
            try std.testing.expectEqualStrings(code_value, ordinary.?.code);
        } else try std.testing.expect(ordinary == null);
        if (registry.resolve("se")) |canonical| try std.testing.expectEqualStrings("Noord-Sami", canonical.heading);
        try std.testing.expect(registry.resolveTrusted("Samies") == null);
        try std.testing.expect(registry.resolveTrusted("Internasionaal") == null);
    }
}

// Append to tools/language_registry.zig in a private qualification source only.
// Actual KY registry row289 is reproduced exactly. UNRUN; first test is expected
// to fail on current eca805 because resolveTrusted uses an ASCII-only check.
// This is a Registry contract regression, not a full-page Writer repair proof.
test "KY installed capitalized preferred alias distinguishes boundary resolution from trusted ownership" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# content-language\tky\n# mediawiki\nky\tкыргызча\tКыргызча\tky\tKirghiz\tkir\n");
    // boundaryLanguage uses ordinary resolution; resolveSection separately
    // requires strong/trusted ownership or explicit source corroboration.
    const boundary_candidate = r.resolve("Кыргызча") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ky", boundary_candidate.code);
    try std.testing.expectEqualStrings("кыргызча", boundary_candidate.heading);
    try std.testing.expect(!r.isAmbiguous("Кыргызча"));
    try std.testing.expect(r.resolveStrong("Кыргызча") == null);
    try std.testing.expectEqualStrings("ky", r.resolveTrusted("кыргызча").?.code);
    const trusted = r.resolveTrusted("Кыргызча");
    try std.testing.expect(trusted != null);
    try std.testing.expectEqualStrings("ky", trusted.?.code);
    try std.testing.expectEqualStrings("кыргызча", trusted.?.heading);
    for ([_][]const u8{ "ky", "kir", "Kirghiz", "КЫРГЫЗЧА", "кЫргызча", "КыргызчА" }) |label|
        try std.testing.expect(r.resolveTrusted(label) == null);
}

test "KY capitalized alias keeps installed identity and competing alias veto" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# mediawiki\nky\tкыргызча\tКыргызча\tky\nru\truso\tRuso\tRUSO\trUsO\tRussian\tru\trus\n# iso-639-3\nxxy\talpha\tAlpha\n");
    try std.testing.expectEqualStrings("ru", r.resolveTrusted("Ruso").?.code);
    for ([_][]const u8{ "RUSO", "rUsO", "Russian", "ru", "rus", "Alpha", "RusO" }) |label|
        try std.testing.expect(r.resolveTrusted(label) == null);
    try r.addTsv("# mediawiki\nen\tEnglish\tКыргызча\tRuso\n");
    try std.testing.expect(r.isAmbiguous("Кыргызча"));
    try std.testing.expect(r.resolve("Кыргызча") == null);
    try std.testing.expect(r.resolveTrusted("Кыргызча") == null);
    try std.testing.expect(r.resolveTrusted("Ruso") == null);
    try std.testing.expectEqualStrings("ky", r.resolveTrusted("кыргызча").?.code);
    var absent = Registry.empty(std.testing.allocator);
    defer absent.deinit();
    try absent.addTsv("# mediawiki\nky\tкыргызча\tky\n");
    try std.testing.expect(absent.resolve("Кыргызча") == null);
    try std.testing.expect(absent.resolveTrusted("Кыргызча") == null);
}

// Append after registry-regression.append.zig. Private/unrun.
test "preferred capitalization uses full first-codepoint upper and unchanged suffix" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# mediawiki\nxaa\tßprache\tSSprache\tẞprache\tSSPRACHE\nxab\tǆname\tǄname\tǅname\nxac\técole\tÉcole\tÉCOLE\n");
    // Python str(first).upper(), as used by the snapshot generator, expands ß
    // and uppercases ǆ to Ǆ; MediaWiki titlecase would produce different text.
    try std.testing.expectEqualStrings("xaa", r.resolveTrusted("SSprache").?.code);
    try std.testing.expectEqualStrings("xab", r.resolveTrusted("Ǆname").?.code);
    try std.testing.expectEqualStrings("xac", r.resolveTrusted("École").?.code);
    for ([_][]const u8{ "ẞprache", "SSPRACHE", "ǅname", "ÉCOLE" }) |label| {
        try std.testing.expect(r.resolve(label) != null);
        try std.testing.expect(r.resolveTrusted(label) == null);
    }
}

test "preferred capitalization survives later alias installation and rechecks conflicts" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv("# mediawiki\nky\tкыргызча\tky\n");
    try std.testing.expect(r.resolve("Кыргызча") == null);
    try std.testing.expect(r.resolveTrusted("Кыргызча") == null);
    // The later row installs the alias without changing the first preferred
    // heading. Cached expected spelling alone must never register it early.
    try r.addTsv("# mediawiki\nky\tКыргыз тили\tКыргызча\n");
    try std.testing.expectEqualStrings("ky", r.resolveTrusted("Кыргызча").?.code);
    try std.testing.expectEqualStrings("кыргызча", r.resolveTrusted("Кыргызча").?.heading);
    try r.addTsv("# mediawiki\nen\tEnglish\tКыргызча\n");
    try std.testing.expect(r.isAmbiguous("Кыргызча"));
    try std.testing.expect(r.resolveTrusted("Кыргызча") == null);
    try std.testing.expectEqualStrings("ky", r.resolveTrusted("кыргызча").?.code);
}
// Append to tools/language_registry.zig in a private qualification source.
// No test execution is claimed by this source artifact.
test "KBD exact curated language heading requires installed code and preserves canonical name" {
    const label = "АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)";
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    // Deliberately not KBD content-language: the named authority is independent
    // of edition inference. This reproduces the actual captured kbd row.
    try r.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\nkbd\tадыгэбзэ\tАдыгэбзэ\tkbd\tKabardian\n");
    try std.testing.expectEqualStrings("kbd", r.resolveTrusted(label).?.code);
    try std.testing.expectEqualStrings("адыгэбзэ", r.resolveTrusted(label).?.heading);
    try std.testing.expectEqualStrings("адыгэбзэ", r.resolve("kbd").?.heading);
    try std.testing.expect(r.resolveStrong(label) == null);
    for ([_][]const u8{ "АДЫГЭБЗЭ", "АДЫГЭБЗЭ (OTHER)", "Адыгэбзэ (Къэбэрдей-Шэрджэсыбзэ)", "АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ) 2" }) |other|
        try std.testing.expect(r.resolveTrusted(other) == null);
    var absent = Registry.empty(std.testing.allocator);
    defer absent.deinit();
    try absent.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\n");
    try std.testing.expect(absent.resolve(label) == null);
    try std.testing.expect(absent.resolveTrusted(label) == null);
    // A three-letter alias on another code is not an installed kbd code.
    try absent.addTsv("# mediawiki\nfr\tFrench\tkbd\n");
    try std.testing.expectEqualStrings("fr", absent.resolve("kbd").?.code);
    try std.testing.expect(absent.resolve(label) == null);
    try std.testing.expect(absent.resolveTrusted(label) == null);
}

test "KBD exact curated language heading cannot override existing or later conflicts" {
    const label = "АДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)";
    const cases = [_]struct { source: []const u8, ordinary: ?[]const u8, trusted: ?[]const u8 }{
        .{ .source = "# mediawiki\nkbd\tадыгэбзэ\nfr\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", .ordinary = "fr", .trusted = "fr" },
        .{ .source = "# mediawiki\nkbd\tадыгэбзэ\nfr\tFrench\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", .ordinary = "fr", .trusted = null },
        .{ .source = "# mediawiki\nkbd\tадыгэбзэ\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", .ordinary = "kbd", .trusted = null },
        .{ .source = "# mediawiki\nkbd\tадыгэбзэ\nfr\tFrench\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\nen\tEnglish\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", .ordinary = null, .trusted = null },
        .{ .source = "# mediawiki\nkbd\tадыгэбзэ\nfr\tFrench\n# local-alias\tfr\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n", .ordinary = null, .trusted = null },
    };
    for (cases) |case| {
        var r = Registry.empty(std.testing.allocator);
        defer r.deinit();
        try r.addTsv(case.source);
        const ordinary = r.resolve(label);
        if (case.ordinary) |code| {
            try std.testing.expect(ordinary != null);
            try std.testing.expectEqualStrings(code, ordinary.?.code);
        } else try std.testing.expect(ordinary == null);
        const trusted = r.resolveTrusted(label);
        if (case.trusted) |code| {
            try std.testing.expect(trusted != null);
            try std.testing.expectEqualStrings(code, trusted.?.code);
        } else try std.testing.expect(trusted == null);
    }
    var later = Registry.empty(std.testing.allocator);
    defer later.deinit();
    try later.addTsv("# mediawiki\nkbd\tадыгэбзэ\n");
    try std.testing.expectEqualStrings("kbd", later.resolveTrusted(label).?.code);
    try later.addTsv("# mediawiki\nfr\tFrench\tАДЫГЭБЗЭ (КЪЭБЭРДЕЙ-ШЭРДЖЭСЫБЗЭ)\n");
    try std.testing.expectEqualStrings("fr", later.resolve(label).?.code);
    try std.testing.expect(later.resolveTrusted(label) == null);
}


test "literal code source banners preserve unknown names and recheck live owner conflicts" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\ntr\tTurkish\nfr\tFrench\nde\tGerman\n");
    const proof: SourceLanguageBanner = .{ .heading = "decorated exact source (tr)", .level = 1, .target = "Unknown local label", .label = "Unknown local label", .authority = .literal_code };
    try registry.addSourceLanguageBanner("tr", proof);
    try std.testing.expect(registry.matchesSourceLanguageBanner("tr", proof.heading, 1));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("tr", proof.heading, 2));
    try std.testing.expect(!registry.matchesSourceLanguageBanner("en", proof.heading, 1));
    try std.testing.expect(registry.resolve(proof.label) == null);
    try std.testing.expect(registry.resolveTrusted(proof.label) == null);
    try std.testing.expect(!registry.isLanguageBoundary(proof.label));
    try std.testing.expect(!registry.sourceBannerNameMatches("tr", proof.label));
    // A later same-owner alias need not invalidate a proof, but another owner must.
    try registry.addTsv("tr\tTurkish\tUnknown local label\n");
    try std.testing.expect(registry.matchesSourceLanguageBanner("tr", proof.heading, 1));
    try registry.addTsv("fr\tFrench\tUnknown local label\n");
    try std.testing.expect(!registry.matchesSourceLanguageBanner("tr", proof.heading, 1));

    var local = Registry.empty(std.testing.allocator);
    defer local.deinit();
    try local.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\ntr\tTurkish\nfr\tFrench\n");
    try local.addSourceLanguageBanner("tr", proof);
    try local.addLocalAlias(proof.label, "fr");
    try std.testing.expect(!local.matchesSourceLanguageBanner("tr", proof.heading, 1));
}

test "literal code banner requires an installed code and does not override known names or contradictory proofs" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\nfr\tFrench\ttr\n");
    const proof: SourceLanguageBanner = .{ .heading = "exact source (tr)", .level = 1, .target = "Unknown local label", .label = "Unknown local label", .authority = .literal_code };
    try std.testing.expectEqualStrings("fr", registry.resolve("tr").?.code);
    try registry.addSourceLanguageBanner("tr", proof);
    try std.testing.expect(!registry.matchesSourceLanguageBanner("tr", proof.heading, 1));

    var installed = Registry.empty(std.testing.allocator);
    defer installed.deinit();
    try installed.addTsv("# content-language\ten\n# mediawiki\nen\tEnglish\ntr\tTurkish\nfr\tFrench\n");
    var conflict = proof;
    conflict.label = "English";
    try installed.addSourceLanguageBanner("tr", conflict);
    try std.testing.expect(!installed.matchesSourceLanguageBanner("tr", proof.heading, 1));
    var known_only = proof;
    known_only.authority = .known_names;
    try installed.addSourceLanguageBanner("tr", known_only);
    try std.testing.expect(!installed.matchesSourceLanguageBanner("tr", proof.heading, 1));
    try installed.addSourceLanguageBanner("tr", proof);
    try std.testing.expect(installed.matchesSourceLanguageBanner("tr", proof.heading, 1));
    var contradictory = proof;
    contradictory.heading = "different exact source (tr)";
    try installed.addSourceLanguageBanner("tr", contradictory);
    try std.testing.expect(!installed.matchesSourceLanguageBanner("tr", proof.heading, 1));
    try std.testing.expect(!installed.matchesSourceLanguageBanner("tr", contradictory.heading, 1));
}

const AutonymHeadingTest = struct {
    const header = "# wikidict-language-names-v1\n# wiki\tskrwiktionary\n# dump-date\t20261001\n# content-language\tskr\n";
    const registry = "# content-language\tskr\n# mediawiki\nskr\tسرائیکی\nen\tسرائیکی ► skr\tEnglish\nenx\tOther\nur\tUrdu\tاردو\tUndifferentiated alias\tاُردو\n";
    fn apply(r: *Registry, source: []const u8) !void {
        try r.trustAutonymSnapshot(source, "skrwiktionary", "20261001", "skr");
    }
};

test "captured autonym profile trusts exact installed heading without rewriting preferred display" {
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv(AutonymHeadingTest.registry);
    try std.testing.expect(r.resolve("اردو") != null);
    try std.testing.expect(r.resolveTrusted("اردو") == null);
    try AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++
        "C\tskr\tsingle\t1\nN\tskr\tsingle\tenx\tUndifferentiated alias\n" ++
        "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\nN\t-\tsingle\ten\tEnglish\n");
    const ur = r.resolveTrusted("اردو") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ur", ur.code);
    try std.testing.expectEqualStrings("Urdu", ur.heading);
    try std.testing.expectEqualStrings("سرائیکی ► skr", r.resolveTrusted("English").?.heading);
    try std.testing.expect(r.resolveTrusted("Undifferentiated alias") == null);
    try std.testing.expect(r.resolveTrusted("اُردو") == null);
    try std.testing.expect(r.resolveTrusted("اردو ") == null);
    try std.testing.expect(r.resolveTrusted("اردُو") == null);
}

test "autonym heading evidence preserves missing codes aliases and live conflicts" {
    for ([_][]const u8{
        "# content-language\tskr\nskr\tسرائیکی\nfr\tFrench\tur\tاردو\n", // ur is only an alias of fr.
        "# content-language\tskr\nskr\tسرائیکی\nur\tUrdu\n", // No installed label.
        "# content-language\tskr\nskr\tسرائیکی\nur\tUrdu\tاردو\nfr\tFrench\tاردو\n", // Ambiguous.
    }) |source| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv(source);
        try AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n");
        try std.testing.expect(r.resolveTrusted("اردو") == null);
    }
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv(AutonymHeadingTest.registry ++ "fr\tFrench\n");
    try r.addLocalAlias("اردو", "fr");
    try AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n");
    try std.testing.expect(r.resolveTrusted("اردو") == null);
    var late = Registry.empty(std.testing.allocator); defer late.deinit();
    try late.addTsv(AutonymHeadingTest.registry);
    try AutonymHeadingTest.apply(&late, AutonymHeadingTest.header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n");
    try std.testing.expect(late.resolveTrusted("اردو") != null);
    try late.addTsv("fr\tFrench\tاردو\n");
    try std.testing.expect(late.resolveTrusted("اردو") == null);
    var duplicate = Registry.empty(std.testing.allocator); defer duplicate.deinit();
    try duplicate.addTsv(AutonymHeadingTest.registry ++ "fr\tFrench\n");
    try AutonymHeadingTest.apply(&duplicate, AutonymHeadingTest.header ++ "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\nN\t-\tsingle\tfr\tاردو\n");
    try std.testing.expect(duplicate.resolveTrusted("اردو") == null);
    for ([_]bool{ false, true }) |make_ambiguous| {
        var live = Registry.empty(std.testing.allocator); defer live.deinit();
        try live.addTsv(AutonymHeadingTest.registry ++ "fr\tFrench\n");
        try AutonymHeadingTest.apply(&live, AutonymHeadingTest.header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n");
        try std.testing.expect(live.resolveTrusted("اردو") != null);
        if (make_ambiguous) try live.addLocalAlias("اردو", "ur");
        try live.addLocalAlias("اردو", "fr");
        try std.testing.expectEqualStrings("ur", live.resolve("اردو").?.code);
        try std.testing.expect(live.resolveTrusted("اردو") == null);
        // Do not retroactively weaken trust originating in the original TSV.
        try live.addLocalAlias("Urdu", "fr");
        try std.testing.expectEqualStrings("ur", live.resolveTrusted("Urdu").?.code);
    }
}

test "autonym trust requires complete exact identity profile before mutation" {
    const Case = struct { body: []const u8, err: anyerror };
    for ([_]Case{
        .{ .body = "C\t-\tall\t1\nN\t-\tall\tur\tاردو\n", .err = error.InvalidLanguageNameSnapshot },
        .{ .body = "N\t-\tsingle\tur\tاردو\n", .err = error.IncompleteLanguageNameProfile },
        .{ .body = "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\n", .err = error.IncompleteLanguageNameProfile },
        .{ .body = "C\t-\tsingle\t1\nC\t-\tsingle\t1\n", .err = error.DuplicateLanguageNameProfile },
        .{ .body = "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\nN\t-\tsingle\tur\tOther\n", .err = error.DuplicateLanguageName },
        .{ .body = "C\t-\tsingle\t2\nN\t-\tsingle\tur\tاردو\nN\t-\tsingle\ten\tbad\\q\n", .err = error.InvalidLanguageNameSnapshot },
    }) |case| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv(AutonymHeadingTest.registry);
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ AutonymHeadingTest.header, case.body });
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case.err, AutonymHeadingTest.apply(&r, source));
        try std.testing.expect(r.resolveTrusted("اردو") == null);
    }
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv(AutonymHeadingTest.registry);
    const source = AutonymHeadingTest.header ++ "C\t-\tsingle\t1\nN\t-\tsingle\tur\tاردو\n";
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(source, "enwiktionary", "20261001", "skr"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(source, "skrwiktionary", "20261002", "skr"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(source, "skrwiktionary", "20261001", "en"));
    try AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ "C\tskr\tsingle\t1\nN\tskr\tsingle\tur\tاردو\n");
    try std.testing.expect(r.resolveTrusted("اردو") == null); // Legacy profile remains optional.
}

// Private source-only candidate. Append beside the existing lua_parser import.
// This proves positional interpretation and local provider identity, not purity
// of arbitrary later callers of getData() or inherited language objects.
fn positionalLanguageProviderProof(a: std.mem.Allocator, source: []const u8) !bool {
    if (source.len > 256 * 1024) return false;
    var actual = lua_parser.parse(a, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer actual.deinit();
    var expected = try lua_parser.parse(a, PositionalProviderSchema.source);
    defer expected.deinit();
    var proof = PositionalProviderContract{ .expected = expected.body };
    if (!proof.block(actual.body, 0, true)) return false;
    return proof.export_init == 1 and proof.language_init == 1 and proof.export_return == 1 and
        proof.getter == 1 and proof.selector == 1 and proof.finalizer == 1 and proof.constructor == 1 and
        proof.dependencies == 0b1111111 and proof.libraries == 0b11;
}

const PositionalProviderContract = struct {
    const Expr = lua_parser.Expr;
    const Stmt = lua_parser.Stmt;
    expected: lua_parser.Block,
    export_init: usize = 0,
    language_init: usize = 0,
    export_return: usize = 0,
    getter: usize = 0,
    selector: usize = 0,
    finalizer: usize = 0,
    constructor: usize = 0,
    dependencies: u8 = 0,
    libraries: u2 = 0,
    function_depth: usize = 0,

    fn eq(comptime T: type, left: T, right: T) bool {
        if (T == lua_parser.Span) return true;
        return switch (@typeInfo(T)) {
            .@"struct" => blk: {
                inline for (@typeInfo(T).@"struct".field_names) |name| {
                    if (!eq(@TypeOf(@field(left, name)), @field(left, name), @field(right, name))) break :blk false;
                }
                break :blk true;
            },
            .@"union" => blk: {
                if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :blk false;
                inline for (@typeInfo(T).@"union".field_names) |name| {
                    if (std.meta.activeTag(left) == @field(std.meta.Tag(T), name))
                        break :blk eq(@TypeOf(@field(left, name)), @field(left, name), @field(right, name));
                }
                unreachable;
            },
            .pointer => |p| switch (p.size) {
                .one => eq(p.child, left.*, right.*),
                .slice => blk: {
                    if (left.len != right.len) break :blk false;
                    for (left, right) |x, y| if (!eq(p.child, x, y)) break :blk false;
                    break :blk true;
                },
                else => @compileError("unsupported provider AST pointer"),
            },
            .optional => |o| if (left) |x| (if (right) |y| eq(o.child, x, y) else false) else right == null,
            .bool, .int, .@"enum" => left == right,
            else => @compileError("unsupported provider AST value"),
        };
    }
    fn isName(e: *const Expr, name: []const u8) bool {
        return e.* == .name and std.mem.eql(u8, e.name.value, name);
    }
    fn sensitive(name: []const u8) bool {
        return std.mem.eql(u8, name, "export") or std.mem.eql(u8, name, "Language") or
            std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "table");
    }
    fn environment(name: []const u8) bool {
        const names = [_][]const u8{ "_G", "_ENV", "getfenv", "setfenv", "load", "loadstring", "loadfile", "dofile", "debug", "package" };
        for (names) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }
    fn dependency(name: []const u8) ?u3 {
        const names = [_][]const u8{ "next", "insert", "gsub", "type", "match", "require", "setmetatable" };
        for (names, 0..) |n, i| if (std.mem.eql(u8, name, n)) return @intCast(i);
        return null;
    }
    fn expectedFunction(self: *const @This(), expected_target: lua_parser.LValue) ?*const Stmt {
        for (self.expected) |s| if (s.* == .function_assign and eq(lua_parser.LValue, s.function_assign.target, expected_target)) return s;
        return null;
    }
    fn expectedDependency(self: *const @This(), s: *const Stmt) bool {
        for (self.expected) |e| if (e.* == .local_assign and eq(Stmt, s.*, e.*)) return true;
        return false;
    }
    fn target(self: *@This(), t: lua_parser.LValue, depth: usize) bool {
        return switch (t) {
            .name => |n| !sensitive(n) and !environment(n) and dependency(n) == null,
            .index => |i| blk: {
                if (isName(i.object, "string") or isName(i.object, "table")) break :blk false;
                if (i.key.* == .string) {
                    const key = i.key.string.value;
                    // The authoritative declaration is handled before target().
                    // Unknown roots may be a recovered language prototype.
                    if (std.mem.eql(u8, key, "getCanonicalName")) break :blk false;
                    if (isName(i.object, "Language") and (std.mem.eql(u8, key, "getCanonicalName") or
                        std.mem.eql(u8, key, "_name") or std.mem.eql(u8, key, "_data") or std.mem.eql(u8, key, "__index"))) break :blk false;
                    if (isName(i.object, "export") and (std.mem.eql(u8, key, "finalizeData") or
                        std.mem.eql(u8, key, "getDataModuleName") or std.mem.eql(u8, key, "makeObject"))) break :blk false;
                }
                break :blk self.index(i.object, i.key, depth);
            },
        };
    }
    fn index(self: *@This(), object: *const Expr, key: *const Expr, depth: usize) bool {
        if (object.* == .name and sensitive(object.name.value)) {
            if (key.* != .string) return false;
            // The constructor installs Language itself at this slot. Reading it
            // would provide an untracked mutable alias of the prototype.
            if (isName(object, "Language") and std.mem.eql(u8, key.string.value, "__index")) return false;
            return true;
        }
        return self.expr(object, depth + 1) and self.expr(key, depth + 1);
    }
    fn expr(self: *@This(), e: *const Expr, depth: usize) bool {
        if (depth > 128) return false;
        return switch (e.*) {
            .name => |n| !sensitive(n.value) and !environment(n.value),
            .nil_lit, .bool_lit, .number, .string, .vararg => true,
            .paren => |p| self.expr(p.expr, depth + 1),
            .index => |i| self.index(i.object, i.key, depth),
            .unary => |u| self.expr(u.expr, depth + 1),
            .binary => |b| self.expr(b.lhs, depth + 1) and self.expr(b.rhs, depth + 1),
            .call => |c| blk: {
                // At module evaluation no arbitrary helper may execute before
                // export. Lazy ordinary method bodies are not evaluated here.
                if (self.function_depth == 0) {
                    if (!isName(c.callee, "require") or c.args.len != 1) break :blk false;
                    if (self.libraries != 0b11 or self.dependencies != 0b1111111) break :blk false;
                    if (c.args[0].* != .string and c.args[0].* != .name) break :blk false;
                }
                break :blk self.expr(c.callee, depth + 1) and self.exprs(c.args, depth + 1);
            },
            .method_call => |c| self.function_depth != 0 and self.expr(c.object, depth + 1) and self.exprs(c.args, depth + 1),
            .function => |f| self.function(f, depth + 1),
            .table => |t| blk: {
                for (t.fields) |field| switch (field) {
                    .list => |v| if (!self.expr(v, depth + 1)) break :blk false,
                    .named => |v| if (!self.expr(v.value, depth + 1)) break :blk false,
                    .keyed => |v| if (!self.expr(v.key, depth + 1) or !self.expr(v.value, depth + 1)) break :blk false,
                };
                break :blk true;
            },
        };
    }
    fn exprs(self: *@This(), es: []const *Expr, depth: usize) bool {
        for (es) |e| if (!self.expr(e, depth)) return false;
        return true;
    }
    fn function(self: *@This(), f: lua_parser.FunctionExpr, depth: usize) bool {
        for (f.params) |p| if (sensitive(p) or environment(p)) return false;
        self.function_depth += 1;
        defer self.function_depth -= 1;
        return self.block(f.body, depth + 1, false);
    }
    fn block(self: *@This(), body: lua_parser.Block, depth: usize, admit_contract: bool) bool {
        if (depth > 128) return false;
        for (body, 0..) |s, position| {
            switch (s.*) {
                .empty, .break_stmt => {},
                .local_assign => |v| {
                    var special = false;
                    for (v.names) |n| {
                        if (environment(n)) return false;
                        if (std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "table")) {
                            if (depth != 0 or v.names.len != 1 or v.values.len != 1 or !isName(v.values[0], n)) return false;
                            const bit: u2 = if (std.mem.eql(u8, n, "string")) 1 else 2;
                            if (self.libraries & bit != 0) return false;
                            self.libraries |= bit;
                            special = true;
                        } else if (sensitive(n)) {
                            if (depth != 0 or v.names.len != 1 or v.values.len != 1 or v.values[0].* != .table or v.values[0].table.fields.len != 0) return false;
                            if (std.mem.eql(u8, n, "export")) self.export_init += 1 else self.language_init += 1;
                            special = true;
                        } else if (dependency(n)) |bit| {
                            // A method-local shadow cannot replace the outer alias.
                            if (self.function_depth == 0) {
                                if (depth != 0 or self.libraries != 0b11 or !self.expectedDependency(s) or self.dependencies & (@as(u8, 1) << bit) != 0) return false;
                                self.dependencies |= @as(u8, 1) << bit;
                                special = true;
                            }
                        }
                    }
                    if (!special and !self.exprs(v.values, depth + 1)) return false;
                },
                .assign => |v| {
                    for (v.targets) |t| if (!self.target(t, depth + 1)) return false;
                    if (!self.exprs(v.values, depth + 1)) return false;
                },
                .function_assign => |v| {
                    if (self.expectedFunction(v.target)) |expected| {
                        if (!admit_contract) return false;
                        if (self.export_init != 1 or self.language_init != 1 or self.dependencies != 0b1111111 or self.libraries != 0b11) return false;
                        if (!eq(Stmt, s.*, expected.*)) return false;
                        if (v.target != .index or v.target.index.key.* != .string) return false;
                        const name = v.target.index.key.string.value;
                        if (std.mem.eql(u8, name, "getCanonicalName")) self.getter += 1 else if (std.mem.eql(u8, name, "getDataModuleName")) self.selector += 1 else if (std.mem.eql(u8, name, "finalizeData")) self.finalizer += 1 else self.constructor += 1;
                    } else {
                        if (!self.target(v.target, depth + 1) or !self.expr(v.function, depth + 1)) return false;
                    }
                },
                .local_function => |v| {
                    if (sensitive(v.name) or environment(v.name) or (self.function_depth == 0 and dependency(v.name) != null) or !self.expr(v.function, depth + 1)) return false;
                },
                .return_stmt => |v| {
                    if (self.function_depth == 0) {
                        if (depth != 0 or position + 1 != body.len or v.values.len != 1 or !isName(v.values[0], "export")) return false;
                        self.export_return += 1;
                    } else if (!self.exprs(v.values, depth + 1)) return false;
                },
                .call => |v| if (!self.expr(v.expr, depth + 1)) return false,
                .do_block => |v| if (!self.block(v.body, depth + 1, admit_contract)) return false,
                .while_loop => |v| if (!self.expr(v.cond, depth + 1) or !self.block(v.body, depth + 1, false)) return false,
                .repeat_loop => |v| if (!self.expr(v.cond, depth + 1) or !self.block(v.body, depth + 1, false)) return false,
                .if_stmt => |v| {
                    for (v.branches) |branch| if (!self.expr(branch.cond, depth + 1) or !self.block(branch.body, depth + 1, false)) return false;
                    if (v.else_body) |b| if (!self.block(b, depth + 1, false)) return false;
                },
                .numeric_for => |v| {
                    if (sensitive(v.name) or environment(v.name) or !self.expr(v.start, depth + 1) or !self.expr(v.limit, depth + 1)) return false;
                    if (v.step) |step| if (!self.expr(step, depth + 1)) return false;
                    if (!self.block(v.body, depth + 1, false)) return false;
                },
                .generic_for => |v| {
                    for (v.names) |n| if (sensitive(n) or environment(n)) return false;
                    if (!self.exprs(v.values, depth + 1) or !self.block(v.body, depth + 1, false)) return false;
                },
            }
        }
        return true;
    }
};

// Shared finite production schema. Unrelated provider methods are deliberately not
// required: only these four public contracts plus stable built-in bindings.
pub const PositionalProviderSchema = struct {
    pub const source =
        \\local export = {}
        \\local Language = {}
        \\local string = string
        \\local table = table
        \\local next = next
        \\local insert = table.insert
        \\local gsub = string.gsub
        \\local type = type
        \\local match = string.match
        \\local require = require
        \\local setmetatable = setmetatable
        \\function Language:getCanonicalName()
        \\ local name = self._name
        \\ if name == nil then
        \\  name = self._data[1]
        \\  self._name = name
        \\ end
        \\ return name
        \\end
        \\function export.getDataModuleName(code)
        \\ local letter = match(code, "^(%l)%l%l?$")
        \\ return "Module:" .. (letter == nil and "languages/data/exceptional" or #code == 2 and "languages/data/2" or "languages/data/3/" .. letter)
        \\end
        \\function export.makeObject(code, data, dontCanonicalizeAliases)
        \\ local data_type = type(data)
        \\ if data_type ~= "table" then error(("bad argument #2 to 'makeObject' (table expected, got %s)"):format(data_type)) end
        \\ local input_code = code
        \\ code = normalize_code(code)
        \\ input_code = dontCanonicalizeAliases and input_code or code
        \\ local parent
        \\ if data.parent then parent = get_by_code(data.parent, nil, true, true) else parent = Language end
        \\ parent.__index = parent
        \\ local lang = {_code = input_code}
        \\ if code ~= input_code then lang._mainCode = code end
        \\ local parent_data = parent._data
        \\ if parent_data == nil then lang._fullCode = parent._code or code else
        \\  lang._fullCode = parent._fullCode
        \\  local stack = get_stack(parent_data)
        \\  if stack == nil then parent_data, stack = make_stack(parent_data) end
        \\  local n = stack[make_stack] + 1
        \\  data, stack[n], stack[make_stack] = parent_data, data, n
        \\ end
        \\ lang._data = data
        \\ return setmetatable(lang, parent)
        \\end
        \\function export.finalizeData(data, main_type, variety)
        \\ local fields = {"type"}
        \\ if main_type == "language" then
        \\  insert(fields, 4)
        \\  insert(fields, "ancestors")
        \\  insert(fields, "link_tr")
        \\  insert(fields, "override_translit")
        \\  insert(fields, "wikimedia_codes")
        \\ elseif main_type == "script" then insert(fields, 3) end
        \\ local fields_len = #fields
        \\ for _, entity in next, data do
        \\  if variety then entity.parent, entity[3], entity.family = entity[3], entity.family
        \\  elseif not (entity.type or entity.parent) then entity.type = "regular" end
        \\  for i = 1, fields_len do
        \\   local key = fields[i]
        \\   local field = entity[key]
        \\   if field and type(field) == "string" then entity[key] = gsub(field, "%s*,%s*", ",") end
        \\  end
        \\ end
        \\ return data
        \\end
        \\return export
    ;
};

test "positional provider proves finite getter finalizer selector and local identity" {
    try std.testing.expect(try positionalLanguageProviderProof(std.testing.allocator, PositionalProviderSchema.source));
    const unrelated = try std.mem.replaceOwned(u8, std.testing.allocator, PositionalProviderSchema.source, "return export", "function Language:getDataModuleName() return self._dataModuleName end\nlocal mt = {}\nmt.__index = function() return nil end\nreturn export");
    defer std.testing.allocator.free(unrelated);
    try std.testing.expect(try positionalLanguageProviderProof(std.testing.allocator, unrelated));
    const changes = [_][2][]const u8{
        .{ "self._data[1]", "self._data[2]" },
        .{ "return data\nend\nreturn export", "return {}\nend\nreturn export" },
        .{ "insert(fields, 4)", "insert(fields, 1)" },
        .{ "return export", "export.finalizeData = function(data) return data end\nreturn export" },
        .{ "return export", "local alias = Language\nreturn export" },
        .{ "return export", "local alias = Language.__index\nreturn export" },
        .{ "return export", "local object = export.makeObject('sh', {})\nreturn export" },
        .{ "return export", "mutate(export)\nreturn export" },
        .{ "return export", "Language[unknown] = function() end\nreturn export" },
        .{ "return export", "next = evil\nreturn export" },
        .{ "local string = string", "local string = evil" },
        .{ "local next = next", "_G.next = function(...) return nil end\nlocal next = next" },
        .{ "local next = next", "local x = require('mutator')\nlocal next = next" },
        .{ "local insert = table.insert", "_G.table.insert = evil\nlocal insert = table.insert" },
        .{ "local insert = table.insert", "(_ENV)['table'].insert = evil\nlocal insert = table.insert" },
        .{ "local next = next", "local env = (getfenv)()\nlocal next = next" },
        .{ "local next = next", "local env = (_G)\nlocal next = next" },
        .{ "local next = next", "local f = loadstring('return 1')\nlocal next = next" },
        .{ "return export", "local p = package.loaded\nreturn export" },
        .{ "return export", "local d = (debug)['getupvalue']\nreturn export" },
        .{ "local insert = table.insert", "table.insert = evil\nlocal insert = table.insert" },
        .{ "return export", "escape(string)\nreturn export" },
        .{ "return export", "Language.__index = evil\nreturn export" },
        .{ "return export", "Language._data = {'wrong'}\nreturn export" },
        .{ "return export", "if unknown then return {} end\nreturn export" },
        .{ "return export", "return Language" },
    };
    for (changes) |change| {
        const modified = try std.mem.replaceOwned(u8, std.testing.allocator, PositionalProviderSchema.source, change[0], change[1]);
        defer std.testing.allocator.free(modified);
        try std.testing.expect(!try positionalLanguageProviderProof(std.testing.allocator, modified));
    }
    try std.testing.expect(!try positionalLanguageProviderProof(std.testing.allocator, "function ???"));
}

// Finite positional-table proof; never evaluate Lua or follow aliases.
// Commit names only after proving the complete literal table and export.
fn positionalLanguageDataImport(registry: *Registry, source: []const u8, module_base: []const u8) !void {
    var chunk = lua_parser.parse(registry.arena.child_allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer chunk.deinit();
    const temporary = chunk.arena.allocator();
    var pending: std.ArrayList(LocalName) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var initialized = false;
    var exported = false;
    for (chunk.body) |stmt| {
        if (stmt.* == .empty) continue;
        if (exported) return;
        switch (stmt.*) {
            .local_assign => |assignment| {
                var relevant = false;
                for (assignment.names) |name| if (std.mem.eql(u8, name, "m")) { relevant = true; };
                if (!relevant) {
                    if (!positionalDataStatementSafe(stmt, false)) return;
                    continue;
                }
                if (initialized or assignment.names.len != 1 or assignment.values.len != 1) return;
                const fields = literalTable(assignment.values[0]) orelse return;
                if (fields.len != 0) return;
                initialized = true;
            },
            .assign => |assignment| {
                var relevant = false;
                for (assignment.targets) |target| if (languageDataTarget(target, .canonical_assignments)) { relevant = true; };
                if (!relevant) {
                    if (!positionalDataStatementSafe(stmt, false)) return;
                    continue;
                }
                if (!initialized or assignment.targets.len != 1 or assignment.values.len != 1) return;
                const target = switch (assignment.targets[0]) { .index => |index| index, else => return };
                if (!literalName(target.object, "m")) return;
                const key = literalString(target.key) orelse return;
                if (!positionalDataExpressionSafe(assignment.values[0])) return;
                for (seen.items) |previous| if (std.mem.eql(u8, previous, key)) return;
                try seen.append(temporary, key);
                if (!registry.codes.contains(key) or !positionalDataCodeMatches(module_base, key)) continue;
                const fields = literalTable(assignment.values[0]) orelse return;
                var first: ?[]const u8 = null;
                var list_seen = false;
                var named: ?[]const u8 = null;
                for (fields) |field| switch (field) {
                    .list => |value| {
                        if (list_seen) continue;
                        list_seen = true;
                        first = literalString(value) orelse return;
                        if (!validLocalLabel(first.?)) return;
                    },
                    .named => |value| if (std.mem.eql(u8, value.name, "canonicalName")) {
                        if (named != null) return;
                        named = literalString(value.value) orelse return;
                    },
                    .keyed => |value| {
                        // A numeric/computed key could replace positional 1.
                        const key_name = literalString(value.key) orelse return;
                        if (std.mem.eql(u8, key_name, "canonicalName")) {
                            if (named != null) return;
                            named = literalString(value.value) orelse return;
                        }
                    },
                };
                const label = first orelse return;
                if (named) |name| if (!std.mem.eql(u8, name, label)) return;
                try pending.append(temporary, .{ .key = key, .value = label });
            },
            .return_stmt => |statement| {
                if (!initialized or statement.values.len != 1 or !positionalLanguageDataExport(statement.values[0])) return;
                exported = true;
            },
            else => if (!positionalDataStatementSafe(stmt, false)) return,
        }
    }
    if (!exported) return;
    for (pending.items) |entry| try registry.addLocalAlias(entry.value, entry.key);
}

fn positionalDataCodeMatches(module_base: []const u8, code_value: []const u8) bool {
    for (code_value) |byte| if (byte < 'a' or byte > 'z') return false;
    if (std.mem.eql(u8, module_base, "languages/data/2")) return code_value.len == 2;
    const prefix = "languages/data/3/";
    return code_value.len == 3 and module_base.len == prefix.len + 1 and
        std.mem.startsWith(u8, module_base, prefix) and module_base[prefix.len] == code_value[0];
}

fn positionalLanguageDataExport(expression: *const lua_parser.Expr) bool {
    const call = switch (expression.*) { .call => |value| value, else => return false };
    if (call.args.len != 2 or !literalName(call.args[0], "m") or
        !std.mem.eql(u8, literalString(call.args[1]) orelse return false, "language")) return false;
    const member = switch (call.callee.*) { .index => |value| value, else => return false };
    if (!std.mem.eql(u8, literalString(member.key) orelse return false, "finalizeData")) return false;
    const require_call = switch (member.object.*) { .call => |value| value, else => return false };
    return literalName(require_call.callee, "require") and require_call.args.len == 1 and
        std.mem.eql(u8, literalString(require_call.args[0]) orelse return false, "Module:languages");
}

fn positionalDataProtectedName(name: []const u8) bool {
    for ([_][]const u8{ "m", "require", "_G", "_ENV", "package", "debug", "setfenv", "getfenv", "load", "loadstring" }) |protected|
        if (std.mem.eql(u8, name, protected)) return true;
    return false;
}

fn positionalDataExpressionSafe(expression: *const lua_parser.Expr) bool {
    return switch (expression.*) {
        .name => |value| !positionalDataProtectedName(value.value),
        .string => |value| !std.mem.eql(u8, value.value, "Module:languages"),
        .paren => |value| positionalDataExpressionSafe(value.expr),
        .index => |value| positionalDataExpressionSafe(value.object) and positionalDataExpressionSafe(value.key),
        .unary => |value| positionalDataExpressionSafe(value.expr),
        .binary => |value| positionalDataExpressionSafe(value.lhs) and positionalDataExpressionSafe(value.rhs),
        .call => |value| blk: {
            if (literalName(value.callee, "require")) {
                if (value.args.len != 1) break :blk false;
                const module_name = literalString(value.args[0]) orelse break :blk false;
                break :blk !std.mem.eql(u8, module_name, "Module:languages");
            }
            if (!positionalDataExpressionSafe(value.callee)) break :blk false;
            for (value.args) |argument| if (!positionalDataExpressionSafe(argument)) break :blk false;
            break :blk true;
        },
        .method_call => |value| blk: {
            if (!positionalDataExpressionSafe(value.object)) break :blk false;
            for (value.args) |argument| if (!positionalDataExpressionSafe(argument)) break :blk false;
            break :blk true;
        },
        .table => |value| blk: {
            for (value.fields) |field| switch (field) {
                .list => |item| if (!positionalDataExpressionSafe(item)) break :blk false,
                .named => |item| if (!positionalDataExpressionSafe(item.value)) break :blk false,
                .keyed => |item| if (!positionalDataExpressionSafe(item.key) or !positionalDataExpressionSafe(item.value)) break :blk false,
            };
            break :blk true;
        },
        .function => |value| blk: {
            for (value.params) |name| if (positionalDataProtectedName(name)) break :blk false;
            for (value.body) |statement| if (!positionalDataStatementSafe(statement, true)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

fn positionalDataTargetSafe(target: lua_parser.LValue) bool {
    return switch (target) {
        .name => |name| !positionalDataProtectedName(name),
        .index => |index| positionalDataExpressionSafe(index.object) and positionalDataExpressionSafe(index.key),
    };
}

fn positionalDataStatementSafe(statement: *const lua_parser.Stmt, in_function: bool) bool {
    switch (statement.*) {
        .assign => |value| {
            for (value.targets) |target| if (!positionalDataTargetSafe(target)) return false;
            for (value.values) |expression| if (!positionalDataExpressionSafe(expression)) return false;
        },
        .local_assign => |value| {
            for (value.names) |name| if (positionalDataProtectedName(name)) return false;
            for (value.values) |expression| if (!positionalDataExpressionSafe(expression)) return false;
        },
        .call => |value| return positionalDataExpressionSafe(value.expr),
        .function_assign => |value| return positionalDataTargetSafe(value.target) and positionalDataExpressionSafe(value.function),
        .local_function => |value| return !positionalDataProtectedName(value.name) and positionalDataExpressionSafe(value.function),
        .do_block => |value| { for (value.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false; },
        .while_loop => |value| {
            if (!positionalDataExpressionSafe(value.cond)) return false;
            for (value.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
        },
        .repeat_loop => |value| {
            if (!positionalDataExpressionSafe(value.cond)) return false;
            for (value.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
        },
        .numeric_for => |value| {
            if (positionalDataProtectedName(value.name) or !positionalDataExpressionSafe(value.start) or !positionalDataExpressionSafe(value.limit)) return false;
            if (value.step) |step| if (!positionalDataExpressionSafe(step)) return false;
            for (value.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
        },
        .generic_for => |value| {
            for (value.names) |name| if (positionalDataProtectedName(name)) return false;
            for (value.values) |expression| if (!positionalDataExpressionSafe(expression)) return false;
            for (value.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
        },
        .if_stmt => |value| {
            for (value.branches) |branch| {
                if (!positionalDataExpressionSafe(branch.cond)) return false;
                for (branch.body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
            }
            if (value.else_body) |body| for (body) |inner| if (!positionalDataStatementSafe(inner, in_function)) return false;
        },
        .return_stmt => |value| {
            // An early module return bypasses the proved terminal export.
            if (!in_function) return false;
            for (value.values) |expression| if (!positionalDataExpressionSafe(expression)) return false;
        },
        .empty, .break_stmt => {},
    }
    return true;
}

const PositionalDataTest = struct {
    const table = "local m = {}\nm[\"sh\"] = { \"ဆာဘို-ခရိုအေးရှား\", 9301, \"zls\", \"Latn, Cyrl\" }\n";
    const finish = "return require(\"Module:languages\").finalizeData(m, \"language\")";
    const registry = "# mediawiki\nsh\tSerbo-Croatian\nfr\tFrench\n";
};

test "positional language data preserves installed code canonical display and live conflicts" {
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv(PositionalDataTest.registry);
    try positionalLanguageDataImport(&registry, PositionalDataTest.table ++ PositionalDataTest.finish, "languages/data/2");
    const actual = registry.resolveTrusted("ဆာဘို-ခရိုအေးရှား") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sh", actual.code);
    try std.testing.expectEqualStrings("Serbo-Croatian", actual.heading);
    try std.testing.expectEqualStrings("Serbo-Croatian", registry.resolve("sh").?.heading);
    try registry.addTsv("# mediawiki\nfr\tFrench\tဆာဘို-ခရိုအေးရှား\n");
    try std.testing.expectEqualStrings("fr", registry.resolve("ဆာဘို-ခရိုအေးရှား").?.code);
    try std.testing.expect(registry.resolveTrusted("ဆာဘို-ခရိုအေးရှား") == null);

    var missing = Registry.empty(std.testing.allocator); defer missing.deinit();
    try missing.addTsv("# mediawiki\nfr\tFrench\tsh\n");
    try positionalLanguageDataImport(&missing, PositionalDataTest.table ++ PositionalDataTest.finish, "languages/data/2");
    try std.testing.expect(missing.resolve("ဆာဘို-ခရိုအေးရှား") == null);

    var conflict = Registry.empty(std.testing.allocator); defer conflict.deinit();
    try conflict.addTsv("# mediawiki\nsh\tSerbo-Croatian\nfr\tFrench\tဆာဘို-ခရိုအေးရှား\n");
    try positionalLanguageDataImport(&conflict, PositionalDataTest.table ++ PositionalDataTest.finish, "languages/data/2");
    try std.testing.expectEqualStrings("fr", conflict.resolve("ဆာဘို-ခရိုအေးရှား").?.code);
    try std.testing.expect(conflict.resolveTrusted("ဆာဘို-ခရိုအေးရှား") == null);

    var local_conflict = Registry.empty(std.testing.allocator); defer local_conflict.deinit();
    try local_conflict.addTsv(PositionalDataTest.registry);
    try positionalLanguageDataImport(&local_conflict, PositionalDataTest.table ++ PositionalDataTest.finish, "languages/data/2");
    try local_conflict.addLocalAlias("ဆာဘို-ခရိုအေးရှား", "fr");
    try std.testing.expect(local_conflict.resolve("ဆာဘို-ခရိုအေးရှား") == null);

    for ([_][]const u8{ "languages/data/3/s", "languages/data/2/doc", "other/data/2" }) |wrong_module| {
        var wrong = Registry.empty(std.testing.allocator); defer wrong.deinit();
        try wrong.addTsv(PositionalDataTest.registry);
        try positionalLanguageDataImport(&wrong, PositionalDataTest.table ++ PositionalDataTest.finish, wrong_module);
        try std.testing.expect(wrong.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    }
    try std.testing.expect(positionalDataCodeMatches("languages/data/3/s", "skr"));
    try std.testing.expect(!positionalDataCodeMatches("languages/data/3/m", "skr"));
    try std.testing.expect(!positionalDataCodeMatches("languages/data/3/s", "SKR"));
}

test "positional language data rejects root escapes early exports mutations and conflicting field one" {
    const invalid = [_][]const u8{
        PositionalDataTest.table,
        PositionalDataTest.table ++ "return m",
        PositionalDataTest.table ++ "return require(\"Module:other\").finalizeData(m, \"language\")",
        PositionalDataTest.table ++ "return require(\"Module:languages\").finalizeData(m, \"script\")",
        PositionalDataTest.table ++ "return require(\"Module:languages\").finalizeData({}, \"language\")",
        PositionalDataTest.table ++ "m[\"sh\"][1] = \"replacement\"\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "local alias = m; alias[\"sh\"][1] = \"replacement\"\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "if true then m[\"sh\"][1] = \"replacement\" end\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "mutate(m)\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "local function get() return m end; local alias = get(); alias[\"sh\"][1] = \"replacement\"\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "for _, row in pairs(m) do row[1] = \"replacement\" end\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "for _, row in ipairs(m) do row[1] = \"replacement\" end\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "sink[mutate(m)] = true\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "if true then return {} end\n" ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "do return {} end\n" ++ PositionalDataTest.finish,
        "local require = replacement; " ++ PositionalDataTest.table ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "require = replacement; " ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "do _G.require = replacement end; " ++ PositionalDataTest.finish,
        "local provider = require(\"Module:languages\"); provider.finalizeData = replacement; " ++ PositionalDataTest.table ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "require(\"Module:languages\").finalizeData = replacement; " ++ PositionalDataTest.finish,
        PositionalDataTest.table ++ "m[\"sh\"] = {\"different\"}\n" ++ PositionalDataTest.finish,
        "local m = {}; m[\"sh\"] = { getName(), 9301 }; " ++ PositionalDataTest.finish,
        "local m = {}; m[\"sh\"] = { \"ဆာဘို-ခရိုအေးရှား\", canonicalName = \"different\" }; " ++ PositionalDataTest.finish,
        "local m = {}; m[\"sh\"] = { \"ဆာဘို-ခရိုအေးရှား\", [1] = \"different\" }; " ++ PositionalDataTest.finish,
    };
    for (invalid) |source| {
        var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
        try registry.addTsv(PositionalDataTest.registry);
        try positionalLanguageDataImport(&registry, source, "languages/data/2");
        try std.testing.expect(registry.resolve("ဆာဘို-ခရိုအေးရှား") == null);
    }
    // An unrelated helper's local return does not bypass the module export.
    var valid = Registry.empty(std.testing.allocator); defer valid.deinit();
    try valid.addTsv(PositionalDataTest.registry);
    try positionalLanguageDataImport(&valid, "local function unrelated() return {} end; " ++ PositionalDataTest.table ++ PositionalDataTest.finish, "languages/data/2");
    try std.testing.expectEqualStrings("sh", valid.resolveTrusted("ဆာဘို-ခရိုအေးရှား").?.code);
}

const ReviewedAliasTest = struct {
    fn marker(a: std.mem.Allocator) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
        return std.fmt.allocPrint(a, "# reviewed-alias\tur\tاُردو\tnwe-urdu-exact-v1\t{s}\n", .{std.fmt.bytesToHex(hash, .lower)});
    }
};

test "reviewed exact alias is provenance-bound and preserves source conflicts" {
    const a = std.testing.allocator;
    const marker = try ReviewedAliasTest.marker(a); defer a.free(marker);
    const rows = try std.mem.concat(a, u8, &.{"# mediawiki\nur\tUrdu\tاردو\n", marker}); defer a.free(rows);
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv(rows);
    try std.testing.expectEqualStrings("ur", registry.resolveTrusted("اُردو").?.code);
    try std.testing.expectEqualStrings("Urdu", registry.resolveTrusted("اُردو").?.heading);
    try std.testing.expect(registry.resolveStrong("اُردو") == null);
    try std.testing.expect(registry.resolveSourceTrusted("اُردو") == null);
    try std.testing.expect(!registry.sourceBannerNameMatches("ur", "اُردو"));
    try registry.addTsv("# mediawiki\nfr\tFrench\n");
    try std.testing.expect(registry.sourceBannerLiteralCodeNameCompatible("ur", "اُردو"));
    try std.testing.expect(!registry.sourceBannerLiteralCodeNameCompatible("fr", "اُردو"));
    try std.testing.expect(!registry.sourceBannerNameMatches("fr", "اُردو"));
    for ([_][]const u8{"اُردُو", "اُرْدُو", "unknown"}) |name| try std.testing.expect(registry.resolveTrusted(name) == null);
    try registry.addLocalAlias("اُردو", "ur");
    try registry.addTsv("# mediawiki\nfr\tFrench\tاُردو\n");
    try std.testing.expect(registry.resolveTrusted("اُردو") == null);
    var wrong = Registry.empty(a); defer wrong.deinit();
    try std.testing.expectError(error.InvalidLanguageRegistry, wrong.addTsv(marker));
    var malformed = Registry.empty(a); defer malformed.deinit();
    try std.testing.expectError(error.InvalidLanguageRegistry, malformed.addTsv("ur\tUrdu\n# reviewed-alias\tur\tاُردو\twrong\tbad\n"));
    var conflict = Registry.empty(a); defer conflict.deinit();
    try conflict.addTsv("# mediawiki\nur\tUrdu\nfr\tFrench\tاُردو\n");
    try conflict.addTsv(rows);
    try std.testing.expectEqualStrings("fr", conflict.resolve("اُردو").?.code);
    var ambiguous = Registry.empty(a); defer ambiguous.deinit();
    try ambiguous.addTsv("# mediawiki\nur\tUrdu\tاُردو\nfr\tFrench\tاُردو\n");
    try ambiguous.addTsv(rows);
    try std.testing.expect(ambiguous.isAmbiguous("اُردو"));
    try std.testing.expect(ambiguous.resolveTrusted("اُردو") == null);
}

fn nomCapitalizationAlloc(a: std.mem.Allocator, source: []const u8) !?[]const u8 {
    if (source.len == 0 or !std.ascii.isLower(source[0])) return null;
    const result = try a.dupe(u8, source);
    result[0] = std.ascii.toUpper(result[0]);
    return result;
}
fn nomLiteralValue(expression: *const lua_parser.Expr, depth: usize) bool {
    if (depth > 32) return false;
    return switch (expression.*) {
        .nil_lit, .bool_lit, .number, .string => true,
        .table => |value| valid: {
            for (value.fields) |field| switch (field) {
                .list => |item| if (!nomLiteralValue(item, depth + 1)) break :valid false,
                .named => |item| if (!nomLiteralValue(item.value, depth + 1)) break :valid false,
                .keyed => |item| if (!nomLiteralValue(item.key, depth + 1) or !nomLiteralValue(item.value, depth + 1)) break :valid false,
            };
            break :valid true;
        },
        else => false,
    };
}

test "literal nom language data stages immutable records and preserves existing conflicts" {
    const a = std.testing.allocator;
    const source = "local l={}\nl['shy']={nom='tacawit'}\nl['en']={nom='taglizit'}\nl['eng']=l['en']\nreturn l";
    var r = Registry.empty(a); defer r.deinit();
    try r.addTsv("# mediawiki\nshy\tShawiya\tTacawit\ttacawit\nen\tEnglish\teng\n");
    try r.addNomLanguageDataLua(source);
    try std.testing.expectEqualStrings("shy", r.resolveTrusted("Tacawit").?.code);
    try std.testing.expectEqualStrings("shy", r.resolveTrusted("tacawit").?.code);
    try std.testing.expectEqualStrings("Shawiya", r.resolveTrusted("Tacawit").?.heading);
    try std.testing.expect(r.resolveTrusted("TACAWIT") == null);
    try std.testing.expectEqualStrings("en", r.resolveTrusted("taglizit").?.code);
    try r.addLocalAlias("Tacawit", "en");
    // Ordinary already-trusted metadata keeps its original owner; conflicting
    // local evidence must not become a source-banner owner for another code.
    try std.testing.expect(!r.sourceBannerNameMatches("en", "Tacawit"));
    var conflict = Registry.empty(a); defer conflict.deinit();
    try conflict.addTsv("# mediawiki\nshy\tShawiya\nen\tEnglish\tTacawit\ttacawit\n");
    try conflict.addNomLanguageDataLua(source);
    try std.testing.expectEqualStrings("en", conflict.resolve("Tacawit").?.code);
    try std.testing.expect(conflict.resolveTrusted("tacawit") == null);
    for ([_][]const u8{
        "local l={}; l['shy']={nom=dynamic()}; return l",
        "local l={}; l['shy']={nom='tacawit'}; mutate(l); return l",
        "local l={}; l['shy']={nom='tacawit'}; l['shy'].nom='French'; return l",
        "local l={}; l['shy']={nom='tacawit'}; local alias=l; return l",
        "local l={}; l['shy']={nom='tacawit'}; return {}",
        "local l={}; l['shy']={nom='tacawit',nom='French'}; return l",
        "local l={}; l['shy']={nom='tacawit',extra=dynamic()}; return l",
        "local l={}; l['shy']={nom='{{{label}}}'}; return l",
        "local l={}; l['shy']={nom='<nowiki>tacawit</nowiki>'}; return l",
        "local l={}; l['shy']={nom=' tacawit'}; return l",
        "local l={}; if test then l['shy']={nom='tacawit'} end; return l",
    }) |bad| {
        var declined = Registry.empty(a); defer declined.deinit();
        try declined.addTsv("# mediawiki\nshy\tShawiya\tTacawit\ttacawit\n");
        try declined.addNomLanguageDataLua(bad);
        try std.testing.expect(declined.resolveTrusted("Tacawit") == null);
    }
}

test "retained complete nom provider data supports source aliases and sequential overwrites" {
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv("# mediawiki\nshy\tShawiya\tTacawit\ttacawit\nen\tEnglish\n");
    // Exact Amṣada:langues/data p4218/r16379; retained get_nom p4217/r6746
    // reads this literal nom, and section langue p4232/r6830 applies ucfirst.
    const source = @embedFile("testdata/shy-nom-data.lua");
    try std.testing.expectEqual(@as(usize, 208324), source.len);
    try r.addNomLanguageDataLua(source);
    try std.testing.expectEqualStrings("shy", r.resolveTrusted("Tacawit").?.code);
    try std.testing.expectEqualStrings("Shawiya", r.resolveTrusted("Tacawit").?.heading);
    try std.testing.expect(r.resolve("Unrelated") == null);
}

test "reviewed TG Dutch label preserves preferred name exact trust and conflict veto" {
    const a = std.testing.allocator;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
    const marker = try std.fmt.allocPrint(a, "# reviewed-alias\tnl\tНидерландӣ\ttg-niderlandi-wikidata-category-v1\t{s}\n", .{std.fmt.bytesToHex(hash, .lower)});
    defer a.free(marker);
    const original = "# mediawiki\nnl\tҳолландӣ\tҲолландӣ\tNederlands\tnl\tDutch\tnld\tdut\nen\tEnglish\n";
    var registry = Registry.empty(a);
    defer registry.deinit();
    try registry.addTsv(original);
    try std.testing.expect(registry.resolveTrusted("Нидерландӣ") == null);
    try registry.addTsv(marker);
    const owner = registry.resolveTrusted("Нидерландӣ") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("nl", owner.code);
    try std.testing.expectEqualStrings("ҳолландӣ", owner.heading);
    try std.testing.expect(registry.resolveStrong("Нидерландӣ") == null);
    try std.testing.expect(registry.resolveSourceTrusted("Нидерландӣ") == null);
    try std.testing.expect(registry.resolveTrusted("нидерландӣ") == null);
    try std.testing.expect(!registry.sourceBannerNameMatches("nl", "Нидерландӣ"));
    try std.testing.expectEqualStrings("en", (registry.resolveTrusted("English") orelse return error.TestUnexpectedResult).code);
    try registry.addLocalAlias("Нидерландӣ", "en");
    try std.testing.expect(registry.resolveTrusted("Нидерландӣ") == null);
    var ambiguous = Registry.empty(a);
    defer ambiguous.deinit();
    try ambiguous.addTsv("# mediawiki\nnl\tҳолландӣ\tНидерландӣ\nen\tEnglish\tНидерландӣ\n");
    try ambiguous.addTsv(marker);
    try std.testing.expect(ambiguous.resolveTrusted("Нидерландӣ") == null);
}
