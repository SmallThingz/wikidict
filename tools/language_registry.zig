//! Build-time parser for Wiktionary and pinned site language metadata.
const std = @import("std");
const lua_parser = @import("lua_parser");
const namespace_registry = @import("namespace_registry");

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

const CapturedPreferredCapitalization = struct {
    preferred: []const u8,
    code: []const u8,
};

const DerivedPreferredName = struct {
    original_name: []const u8,
    code: []const u8,
};

pub const SourceLanguageBannerPrefix = struct {
    category: []const u8,
    suffix: []const u8,

    pub fn matches(self: SourceLanguageBannerPrefix, emitted: []const u8) bool {
        return emitted.len == self.category.len + self.suffix.len and
            std.mem.startsWith(u8, emitted, self.category) and
            std.mem.eql(u8, emitted[self.category.len..], self.suffix);
    }

    fn same(left: ?SourceLanguageBannerPrefix, right: ?SourceLanguageBannerPrefix) bool {
        const a = left orelse return right == null;
        const b = right orelse return false;
        return std.mem.eql(u8, a.category, b.category) and std.mem.eql(u8, a.suffix, b.suffix);
    }
};

pub const SourceLanguageBanner = struct {
    heading: []const u8, level: u8, target: []const u8, label: []const u8,
    authority: enum { known_names, literal_code, category_declaration } = .known_names,
    // Exact static transclusion bytes before this provider's own heading.
    emitted_prefix: ?SourceLanguageBannerPrefix = null,
};

pub const SourceStaticSupport = struct { heading: []const u8, level: u8 };

pub const SourceLanguageParagraph = struct { label: []const u8, category: []const u8 };

// An exact selected source formatter, never an ordinary name or target alias.
pub const SourceLinkedHeading = struct { prefix: []const u8, suffix: []const u8 };
pub const SourceFixedLinkedTail = struct { link: SourceLinkedHeading, code: []const u8, tail: []const u8 };

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    ambiguous: std.StringHashMapUnmanaged(void) = .empty,
    language_boundaries: std.StringHashMapUnmanaged(void) = .empty,
    codes: std.StringHashMapUnmanaged(void) = .empty,
    trusted_names: std.StringHashMapUnmanaged(void) = .empty,
    autonym_headings: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    // Names first installed by a translated profile never supply heading trust.
    english_added_aliases: std.StringHashMapUnmanaged(void) = .empty,
    preferred_capitalizations: std.StringHashMapUnmanaged([]const u8) = .empty,
    captured_preferred_capitalizations: std.StringHashMapUnmanaged(?CapturedPreferredCapitalization) = .empty,
    strong_names: std.StringHashMapUnmanaged(void) = .empty,
    canonical_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    // Source canonical-name lookup is distinct from explicit language codes.
    source_canonical_names: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    headings: std.StringHashMapUnmanaged([]const u8) = .empty,
    arabic_articleless_names: std.StringHashMapUnmanaged(?DerivedPreferredName) = .empty,
    local_aliases: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    reviewed_aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    reviewed_varieties: std.StringHashMapUnmanaged(void) = .empty,
    source_banners: std.StringHashMapUnmanaged(?SourceLanguageBanner) = .empty,
    source_static_support: std.StringHashMapUnmanaged(?SourceStaticSupport) = .empty,
    source_equals_labels: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    source_paragraphs: std.StringHashMapUnmanaged(?SourceLanguageParagraph) = .empty,
    source_code_declarations: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    source_linked_heading: ?SourceLinkedHeading = null,
    source_fixed_linked_tail: ?SourceFixedLinkedTail = null,
    source_fixed_linked_tail_conflict: bool = false,
    source_parenthetical_linked_heading: bool = false,
    source_linked_heading_conflict: bool = false,
    source_nom_formatter: bool = false,
    // Independently authenticated name/alias-copy provider and quoted formatter.
    source_nom_name_format: bool = false,
    source_nom_role: bool = false,
    source_naslov_noun: bool = false,
    source_numbered_pos: [2]bool = .{ false, false },
    source_nom_names: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    source_headword_role: bool = false,
    source_headword_static_prefix: ?[]const u8 = null,
    source_headword_codes: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    source_section_prefix: ?[]const u8 = null,
    source_section_conflict: bool = false,
    source_full_names: std.StringHashMapUnmanaged(?[]const u8) = .empty,
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
        self.english_added_aliases.deinit(self.arena.allocator());
        self.preferred_capitalizations.deinit(self.arena.allocator());
        self.captured_preferred_capitalizations.deinit(self.arena.allocator());
        self.strong_names.deinit(self.arena.allocator());
        self.canonical_names.deinit(self.arena.allocator());
        self.source_canonical_names.deinit(self.arena.allocator());
        self.arabic_articleless_names.deinit(self.arena.allocator());
        self.local_aliases.deinit(self.arena.allocator());
        self.reviewed_aliases.deinit(self.arena.allocator());
        self.reviewed_varieties.deinit(self.arena.allocator());
        self.source_banners.deinit(self.arena.allocator());
        self.source_static_support.deinit(self.arena.allocator());
        self.source_equals_labels.deinit(self.arena.allocator());
        self.source_paragraphs.deinit(self.arena.allocator());
        self.source_code_declarations.deinit(self.arena.allocator());
        self.source_headword_codes.deinit(self.arena.allocator());
        self.source_nom_names.deinit(self.arena.allocator());
        self.source_full_names.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn isAmbiguous(self: *const Registry, heading: []const u8) bool {
        return self.ambiguous.contains(heading);
    }

    /// Positive boundary evidence does not resolve, trust or create an owner.
    pub fn isLanguageBoundary(self: *const Registry, heading: []const u8) bool {
        return self.isAmbiguous(heading) or self.hasCodeNameCollision(heading) or self.language_boundaries.contains(heading);
    }

    pub fn code(self: *const Registry, heading: []const u8) ?[]const u8 {
        if (self.names.get(heading)) |value| {
            if (self.english_added_aliases.contains(heading) and !self.sourceBannerNameAllowed(value, heading, false)) return null;
            return value;
        }
        return self.fallbackCode(heading);
    }

    pub fn resolve(self: *const Registry, value: []const u8) ?Resolved {
        const code_value = self.code(value) orelse return null;
        return .{
            .code = code_value,
            // An explicitly reviewed variety retains its own display identity
            // and the installed parent code. Ordinary aliases still canonicalize.
            .heading = if (self.reviewed_varieties.contains(value) and self.isTrustedReviewed(value, code_value))
                self.reviewed_varieties.getKey(value).?
            else
                self.headings.get(code_value) orelse value,
        };
    }

    fn hasCodeNameCollision(self: *const Registry, value: []const u8) bool {
        if (!self.codes.contains(value)) return false;
        const recorded = self.source_canonical_names.get(value) orelse return false;
        const owner = recorded orelse return true;
        return !std.mem.eql(u8, owner, value);
    }

    /// Only callers with an explicit canonical-name role may use this map.
    /// Plain headings still need unambiguous Strong/Trusted authority.
    pub fn resolveCanonicalName(self: *const Registry, value: []const u8) ?Resolved {
        const recorded = self.source_canonical_names.get(value) orelse return null;
        const owner = recorded orelse return null;
        return .{ .code = owner, .heading = value };
    }

    pub fn resolveTrusted(self: *const Registry, value: []const u8) ?Resolved {
        if (self.english_added_aliases.contains(value)) return null;
        if (self.hasCodeNameCollision(value)) return null;
        // The pinned generator includes first-letter capitalizations of its
        // preferred labels. Admit that exact existing alias for the same owner;
        // other ordinary aliases, code aliases, and conflicts retain their trust.
        if (self.names.get(value)) |owner| {
            if (!self.trusted_names.contains(value) and !self.isTrustedReviewed(value, owner) and !self.isTrustedAutonym(value, owner) and
                !self.isCapturedPreferredCapitalization(value, owner))
            {
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
        if (self.english_added_aliases.contains(value)) return null;
        if (self.hasCodeNameCollision(value)) return null;
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

    fn isCapturedPreferredCapitalization(self: *const Registry, value: []const u8, owner: []const u8) bool {
        const captured = (self.captured_preferred_capitalizations.get(value) orelse return false) orelse return false;
        if (!std.mem.eql(u8, captured.code, owner) or !self.trusted_names.contains(captured.preferred)) return false;
        const preferred_owner = self.names.get(captured.preferred) orelse return false;
        return std.mem.eql(u8, preferred_owner, owner);
    }

    fn recordPreferredCapitalization(self: *Registry, mapper: *?PreferredUpper, preferred: []const u8) !void {
        // Invalid UTF-8 does not acquire new trust or change existing TSV parsing.
        if (preferred.len == 0 or
            self.preferred_capitalizations.contains(preferred) or
            !std.unicode.utf8ValidateSlice(preferred)) return;
        const owned = self.arena.allocator();
        const mapped = if (preferred[0] < 0x80) blk: {
            if (!std.ascii.isLower(preferred[0])) return;
            const copy = try owned.dupe(u8, preferred);
            copy[0] = std.ascii.toUpper(copy[0]);
            break :blk copy;
        } else blk: {
            if (mapper.* == null) mapper.* = try PreferredUpper.init();
            break :blk try mapper.*.?.firstAlloc(owned, preferred);
        };
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
        // Only an actual captured MediaWiki preferred row supplies this origin.
        // Strong dump names may later replace the display heading; they must not
        // erase that row's exact capitalization authority. Installed alias and
        // original preferred ownership/trust are rechecked at every resolution.
        const code_value = self.names.get(preferred) orelse return;
        if (!self.trusted_names.contains(preferred)) return;
        if (self.captured_preferred_capitalizations.getPtr(mapped)) |slot| {
            if (slot.*) |previous| {
                if (!std.mem.eql(u8, previous.preferred, preferred) or !std.mem.eql(u8, previous.code, code_value)) slot.* = null;
            }
        } else try self.captured_preferred_capitalizations.put(owned, mapped, .{ .preferred = key, .code = code_value });
    }

    fn fallbackCode(self: *const Registry, value: []const u8) ?[]const u8 {
        if (self.names.contains(value) or self.ambiguous.contains(value)) return null;
        if (self.reviewed_aliases.contains(value) and self.language_boundaries.contains(value)) return null;
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
    pub fn sourceBannerCategoryNameCompatible(self: *const Registry, code_value: []const u8, value: []const u8) bool {
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
        try self.retainSourceLanguageBanner(code_value, proof);
    }
    /// A complete category declaration still proves its physical boundary
    /// when its registered code and local name disagree. Retain the same
    /// immutable proof, but the ordinary owner matcher must continue to refuse.
    pub fn addSourceLanguageBoundary(self: *Registry, code_value: []const u8, proof: SourceLanguageBanner) !void {
        if (proof.authority != .category_declaration or !self.codes.contains(code_value)) return;
        try self.retainSourceLanguageBanner(code_value, proof);
    }
    pub fn matchesSourceLanguageBoundary(self: *const Registry, code_value: []const u8, heading: []const u8, level: u8) bool {
        const proof = (self.source_banners.get(code_value) orelse return false) orelse return false;
        return proof.authority == .category_declaration and proof.level == level and std.mem.eql(u8, proof.heading, heading);
    }
    fn retainSourceLanguageBanner(self: *Registry, code_value: []const u8, proof: SourceLanguageBanner) !void {
        if (self.source_banners.getPtr(code_value)) |stored| {
            if (stored.*) |previous| {
                if (previous.authority != proof.authority or previous.level != proof.level or !std.mem.eql(u8, previous.heading, proof.heading) or
                    !std.mem.eql(u8, previous.target, proof.target) or !std.mem.eql(u8, previous.label, proof.label)) {
                    stored.* = null;
                } else if (!SourceLanguageBannerPrefix.same(previous.emitted_prefix, proof.emitted_prefix)) {
                    // Conflicting prelude bodies do not erase an otherwise exact
                    // heading, but can never grant that heading another prefix.
                    stored.*.?.emitted_prefix = null;
                }
            }
            return;
        }
        const a = self.arena.allocator();
        try self.source_banners.put(a, try a.dupe(u8, code_value), .{
            .heading = try a.dupe(u8, proof.heading), .level = proof.level,
            .target = try a.dupe(u8, proof.target), .label = try a.dupe(u8, proof.label),
            .authority = proof.authority,
            .emitted_prefix = if (proof.emitted_prefix) |prefix| .{
                .category = try a.dupe(u8, prefix.category),
                .suffix = try a.dupe(u8, prefix.suffix),
            } else null,
        });
    }

    pub fn matchesSourceLanguageBannerPrefix(self: *const Registry, code_value: []const u8, heading: []const u8, level: u8, emitted: []const u8) bool {
        if (!self.matchesSourceLanguageBanner(code_value, heading, level)) return false;
        const proof = (self.source_banners.get(code_value) orelse return false) orelse return false;
        const prefix = proof.emitted_prefix orelse return false;
        return prefix.matches(emitted);
    }
    pub fn addSourceLinkedHeading(self: *Registry, proof: SourceLinkedHeading) !void {
        if (self.source_linked_heading_conflict) return;
        if (self.source_linked_heading) |previous| {
            if (!std.mem.eql(u8, previous.prefix, proof.prefix) or !std.mem.eql(u8, previous.suffix, proof.suffix)) {
                self.source_linked_heading = null;
                self.source_linked_heading_conflict = true;
            }
            return;
        }
        const a = self.arena.allocator();
        self.source_linked_heading = .{ .prefix = try a.dupe(u8, proof.prefix), .suffix = try a.dupe(u8, proof.suffix) };
    }

    pub fn addSourceFixedLinkedTail(self: *Registry, proof: SourceFixedLinkedTail) !void {
        if (self.source_fixed_linked_tail_conflict or !self.codes.contains(proof.code) or proof.tail.len == 0) return;
        if (self.source_fixed_linked_tail) |previous| {
            if (!std.mem.eql(u8, previous.link.prefix, proof.link.prefix) or !std.mem.eql(u8, previous.link.suffix, proof.link.suffix) or
                !std.mem.eql(u8, previous.code, proof.code) or !std.mem.eql(u8, previous.tail, proof.tail)) {
                self.source_fixed_linked_tail = null;
                self.source_fixed_linked_tail_conflict = true;
            }
            return;
        }
        const a = self.arena.allocator();
        self.source_fixed_linked_tail = .{ .link = .{ .prefix = try a.dupe(u8, proof.link.prefix), .suffix = try a.dupe(u8, proof.link.suffix) },
            .code = try a.dupe(u8, proof.code), .tail = try a.dupe(u8, proof.tail) };
    }

    pub fn sourceLinkedHeading(self: *const Registry, heading: []const u8) ?Resolved {
        if (self.source_parenthetical_linked_heading) {
            if (self.sourceParentheticalLinkedHeading(heading)) |owner| return owner;
        }
        if (!self.source_linked_heading_conflict) if (self.source_linked_heading) |proof| {
            if (self.matchCanonicalLinkedHeading(heading, proof)) |owner| return owner;
        };
        if (!self.source_fixed_linked_tail_conflict) if (self.source_fixed_linked_tail) |proof| {
            if (heading.len > 4096 or !std.mem.endsWith(u8, heading, proof.tail)) return null;
            const owner = self.matchCanonicalLinkedHeading(heading[0 .. heading.len - proof.tail.len], proof.link) orelse return null;
            return if (std.mem.eql(u8, owner.code, proof.code)) owner else null;
        };
        return null;
    }

    fn matchCanonicalLinkedHeading(self: *const Registry, heading: []const u8, proof: SourceLinkedHeading) ?Resolved {
        if (heading.len > 4096 or !std.unicode.utf8ValidateSlice(heading) or
            !std.mem.startsWith(u8, heading, "[[") or !std.mem.endsWith(u8, heading, "]]")) return null;
        const body = heading[2 .. heading.len - 2];
        if (std.mem.indexOfAny(u8, body, "[]{}<>&#=\"'") != null) return null;
        for (body) |byte| if (byte < 0x20 or byte == 0x7f) return null;
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse return null;
        const target = body[0..pipe]; const label = body[pipe + 1 ..];
        if (std.mem.indexOfScalar(u8, label, '|') != null or !std.mem.startsWith(u8, target, proof.prefix) or
            !std.mem.endsWith(u8, target, proof.suffix) or target.len <= proof.prefix.len + proof.suffix.len) return null;
        const name = target[proof.prefix.len .. target.len - proof.suffix.len];
        if (!std.mem.eql(u8, name, std.mem.trim(u8, name, " ")) or std.mem.indexOfAny(u8, name, ":|") != null or
            self.codes.contains(name) or self.codes.contains(label) or self.isLanguageBoundary(name) or self.isLanguageBoundary(label)) return null;
        const owner = self.resolveStrong(name) orelse self.resolveTrusted(name) orelse return null;
        // getCanonicalName cannot emit an ordinary trusted alias. Keep the
        // independently loaded canonical source identity as a separate gate.
        const canonical = self.resolveCanonicalName(name) orelse return null;
        if (!std.mem.eql(u8, canonical.code, owner.code)) return null;
        // The proved formatter applies ucfirst to this same canonical name;
        // its exact output need not also be a captured standalone alias.
        // An installed competing label still vetoes this source role.
        if (self.local_aliases.get(label)) |local| {
            const local_owner = local orelse return null;
            if (!std.mem.eql(u8, owner.code, local_owner)) return null;
        }
        if (self.reviewed_aliases.get(label)) |reviewed|
            if (!std.mem.eql(u8, owner.code, reviewed)) return null;
        if (!self.names.contains(label) and std.mem.eql(u8, self.content_code orelse "", "ar") and self.arabic_articleless_names.contains(label)) {
            const article_owner = self.derivedArabicCode(label) orelse return null;
            if (!std.mem.eql(u8, owner.code, article_owner)) return null;
        }
        if (self.resolve(label)) |displayed|
            if (!std.mem.eql(u8, owner.code, displayed.code)) return null;
        // The source applies ucfirst to the same canonical-name result. Reuse
        // captured first-character casing; unknown Unicode casing declines.
        const uppercase = if (name[0] < 0x80)
            label.len == name.len and label[0] == std.ascii.toUpper(name[0]) and std.mem.eql(u8, label[1..], name[1..])
        else self.isPreferredCapitalization(name, label);
        if (!uppercase) return null;
        for ([_][]const u8{ target, target[1..] }) |spelling| {
            if (self.isLanguageBoundary(spelling)) return null;
            if (self.resolve(spelling)) |other| if (!std.mem.eql(u8, other.code, owner.code)) return null;
        }
        return owner;
    }

    fn sourceParentheticalLinkedHeading(self: *const Registry, heading: []const u8) ?Resolved {
        if (heading.len > 4096 or !std.unicode.utf8ValidateSlice(heading) or !std.mem.endsWith(u8, heading, "]])")) return null;
        const at = std.mem.indexOf(u8, heading, " ([[") orelse return null;
        const lemma = heading[0..at];
        const name = heading[at + 4 .. heading.len - 3];
        if (lemma.len == 0 or name.len == 0 or
            !std.mem.eql(u8, lemma, std.mem.trim(u8, lemma, " ")) or
            !std.mem.eql(u8, name, std.mem.trim(u8, name, " "))) return null;
        for ([_][]const u8{ lemma, name }) |part| {
            if (std.mem.indexOfAny(u8, part, "[]{}<>&|#=\"'()") != null) return null;
            for (part) |byte| if (byte < 0x20 or byte == 0x7f) return null;
        }
        if (std.mem.indexOfScalar(u8, name, ':') != null or self.codes.contains(name) or self.isLanguageBoundary(name)) return null;
        // The authenticated formatter labels this parameter as the language.
        // The lemma, category and edition supply no owner or new global alias.
        return self.resolveStrong(name) orelse self.resolveTrusted(name);
    }

    pub fn addSourceStaticSupport(self: *Registry, token: []const u8, proof: SourceStaticSupport) !void {
        if (token.len == 0 or token.len > 32 or proof.level < 3 or proof.level > 6 or proof.heading.len == 0) return;
        for (token) |byte| if (!std.ascii.isLower(byte) and byte != '-') return;
        if (self.source_static_support.getPtr(token)) |stored| {
            if (stored.*) |previous| if (previous.level != proof.level or
                !std.mem.eql(u8, previous.heading, proof.heading)) { stored.* = null; };
            return;
        }
        const a = self.arena.allocator();
        try self.source_static_support.put(a, try a.dupe(u8, token), .{
            .heading = try a.dupe(u8, proof.heading), .level = proof.level,
        });
    }
    pub fn sourceStaticSupport(self: *const Registry, token: []const u8) ?SourceStaticSupport {
        return (self.source_static_support.get(token) orelse return null) orelse null;
    }

    /// A complete static =code= template certifies only its exact emitted label.
    /// This map never promotes the label into ordinary aliases or trusted names.
    pub fn addSourceEqualsLabel(self: *Registry, code_value: []const u8, label: []const u8) !void {
        if (!self.codes.contains(code_value) or label.len == 0 or label.len > 256 or
            !std.unicode.utf8ValidateSlice(label) or !std.mem.eql(u8, label, std.mem.trim(u8, label, " \t\r\n")) or
            std.mem.indexOfAny(u8, label, "[]{}<>&|=\"'") != null) return;
        for (label) |byte| if (byte < 0x20 or byte == 0x7f) return;
        if (!self.sourceBannerLiteralCodeNameCompatible(code_value, label) or self.isLanguageBoundary(label)) return;
        if (self.source_equals_labels.getPtr(code_value)) |stored| {
            if (stored.*) |previous| if (!std.mem.eql(u8, previous, label)) { stored.* = null; };
            return;
        }
        const a = self.arena.allocator();
        try self.source_equals_labels.put(a, try a.dupe(u8, code_value), try a.dupe(u8, label));
    }
    pub fn sourceEqualsLabel(self: *const Registry, code_value: []const u8) ?[]const u8 {
        const stored = (self.source_equals_labels.get(code_value) orelse return null) orelse return null;
        return if (!self.isLanguageBoundary(stored) and self.sourceBannerLiteralCodeNameCompatible(code_value, stored)) stored else null;
    }

    pub fn matchesSourceLanguageBanner(self: *const Registry, code_value: []const u8, heading: []const u8, level: u8) bool {
        const proof = (self.source_banners.get(code_value) orelse return false) orelse return false;
        return proof.level == level and std.mem.eql(u8, proof.heading, heading) and
            self.sourceBannerNamesAllowed(code_value, proof);
    }

    /// An authored headword code needs an actual record in the data module used
    /// by the authenticated getByCode source. Snapshot aliases alone cannot seed it.
    pub fn sourceHeadwordLanguage(self: *const Registry, code_value: []const u8) ?Resolved {
        if (!self.source_headword_role) return null;
        const name = (self.source_headword_codes.get(code_value) orelse return null) orelse return null;
        const owned_code = self.codes.getKey(code_value) orelse return null;
        // This exact source role owns its name; it does not promote an ordinary
        // alias into the independent global canonical-name or Strong maps.
        if (self.isLanguageBoundary(name)) return null;
        if (self.source_canonical_names.get(name)) |candidate| {
            const owner = candidate orelse return null;
            if (!std.mem.eql(u8, owner, owned_code)) return null;
        }
        if (self.resolve(name)) |owner| if (!std.mem.eql(u8, owner.code, owned_code)) return null;
        // Installed names can mask fallback conflicts, so check these maps
        // independently rather than treating a missing fallback as agreement.
        if (self.local_aliases.get(name)) |candidate| {
            const owner = candidate orelse return null;
            if (!std.mem.eql(u8, owner, owned_code)) return null;
        }
        if (self.reviewed_aliases.get(name)) |owner| if (!std.mem.eql(u8, owner, owned_code)) return null;
        return .{ .code = owned_code, .heading = name };
    }

    fn rememberSourceHeadwordCode(self: *Registry, code_value: []const u8, name: []const u8) !void {
        if (self.source_headword_codes.getPtr(code_value)) |previous| {
            if (previous.*) |old| if (!std.mem.eql(u8, old, name)) { previous.* = null; };
            return;
        }
        const a = self.arena.allocator();
        try self.source_headword_codes.put(a, try a.dupe(u8, code_value), try a.dupe(u8, name));
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


    /// A selected template source proves this declaration role, not a new alias.
    pub fn addSourceCodeDeclaration(self: *Registry, name: []const u8, category_prefix: []const u8) !void {
        if (name.len == 0 or category_prefix.len == 0) return;
        if (self.source_code_declarations.getPtr(name)) |old| {
            if (old.*) |value| {
                if (!std.mem.eql(u8, value, category_prefix)) old.* = null;
            }
            return;
        }
        const a = self.arena.allocator();
        try self.source_code_declarations.put(a, try a.dupe(u8, name), try a.dupe(u8, category_prefix));
    }

    pub fn matchesSourceParagraphCall(self: *const Registry, code_value: []const u8, template_name: []const u8, line: []const u8) bool {
        if (template_name.len == 0) return self.matchesSourceLanguageParagraph(code_value, line);
        const category = (self.source_code_declarations.get(template_name) orelse return false) orelse return false;
        if (!self.codes.contains(code_value)) return false;
        var rest = line;
        const opening = "==<span id=\"";
        if (!std.mem.startsWith(u8, rest, opening)) return false;
        rest = rest[opening.len..];
        const id_end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
        // The code-named template supplies this opaque display id. It is not
        // ownership evidence; a recognized conflicting spelling still vetoes.
        const id = rest[0..id_end];
        const code_prefix = "\" class=\"lang\" data-code=\"";
        rest = rest[id_end..];
        if (!std.mem.startsWith(u8, rest, code_prefix)) return false;
        rest = rest[code_prefix.len..];
        if (!std.mem.startsWith(u8, rest, code_value)) return false;
        rest = rest[code_value.len..];
        const name_prefix = "\" data-name=\"";
        if (!std.mem.startsWith(u8, rest, name_prefix)) return false;
        rest = rest[name_prefix.len..];
        const name_end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
        const name = rest[0..name_end];
        rest = rest[name_end..];
        const label_prefix = "\">[[";
        if (!std.mem.startsWith(u8, rest, label_prefix)) return false;
        rest = rest[label_prefix.len..];
        const label_end = std.mem.indexOf(u8, rest, "]]</span>\n[[") orelse return false;
        const label = rest[0..label_end];
        rest = rest[label_end + "]]</span>\n[[".len ..];
        if (!std.mem.startsWith(u8, rest, category)) return false;
        rest = rest[category.len..];
        if (!std.mem.startsWith(u8, rest, label) or !std.mem.eql(u8, rest[label.len..], "]]==")) return false;
        // The retained formatter applies lcfirst. The finite profile supports
        // an unchanged label or its ASCII initial; no Unicode name is invented.
        if (!std.mem.eql(u8, name, label) and !(name.len == label.len and name.len != 0 and
            name[0] >= 'A' and name[0] <= 'Z' and label[0] == name[0] + ('a' - 'A') and
            std.mem.eql(u8, name[1..], label[1..]))) return false;
        for ([_][]const u8{ id, name, label }) |spelling| {
            if (spelling.len == 0 or std.mem.indexOfAny(u8, spelling, "[]{}<>|&\"\r\n\t") != null or
                !std.mem.eql(u8, spelling, std.mem.trim(u8, spelling, " ")) or self.isAmbiguous(spelling)) return false;
            if (self.resolve(spelling)) |owner| if (!std.mem.eql(u8, owner.code, code_value)) return false;
        }
        return true;
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
        const source_owned = self.arena.allocator();
        if (self.source_canonical_names.getPtr(heading)) |previous| {
            if (previous.*) |owner| {
                if (!std.mem.eql(u8, owner, code_value)) previous.* = null;
            }
        } else {
            try self.source_canonical_names.put(source_owned, try source_owned.dupe(u8, heading), try source_owned.dupe(u8, code_value));
        }
        if (self.source_canonical_names.get(heading).? == null) {
            // Competing source declarations establish a boundary, never a
            // last-wins owner. Reserved codes remain independently addressable.
            if (!self.codes.contains(heading)) {
                if (self.canonical_names.get(heading)) |owner| try self.rehomeExternalHeading(heading, owner);
                _ = self.names.remove(heading);
                _ = self.canonical_names.remove(heading);
                _ = self.trusted_names.remove(heading);
                _ = self.strong_names.remove(heading);
                try self.ambiguous.put(source_owned, try source_owned.dupe(u8, heading), {});
            }
            return;
        }
        // Keep the explicit-code slot intact. A real source name such as HU
        // "ari" -> aac does not make the independent ari code invalid.
        if (self.codes.contains(heading) and !std.mem.eql(u8, heading, code_value)) return;

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

        // A stronger declaration for the same owner must preserve the trust
        // of an already authenticated preferred name. Foreign-owner replacement
        // still revokes it; Strong alone never creates captured alias trust.
        const retained_trust = self.trusted_names.contains(heading) and
            if (self.names.get(heading)) |previous_owner| std.mem.eql(u8, previous_owner, code_value) else false;
        const owned = self.arena.allocator();
        _ = self.ambiguous.remove(heading);
        _ = self.names.remove(heading);
        if (!retained_trust) _ = self.trusted_names.remove(heading);
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

    // Selected complete source programs establish the named table/provider
    // contract. The data remains independently parsed and staged below.
    pub const NamedSectionProvider = enum { name_copy_alias };
    pub const named_section_program_hashes = [_][]const u8{
        "e6b7e8f78f13c761f52f89c025afb3a11ad31eed08c05355f834d862e7ab331f",
        "185d9fb8ae0c6082627180f2ac442825481a1d995b97690aa75f1de63256b51d",
        "b6d2042cce86f412327e8aaec92fb03dae94c52a84bc8e47dc14aa891b3e8ac8",
        "6aed327508870d7810a97b7d48cdda2797da926c5e4024bc390ea4ba669f53c9",
    };
    pub fn proveNamedSectionProvider(sources: [4][]const u8) ?NamedSectionProvider {
        for (sources, named_section_program_hashes) |source, expected| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
            if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected)) return null;
        }
        return .name_copy_alias;
    }

    // This provider indexes l[raw_code].name and rejects isSpecial/isGroup.
    // aliasOf copies a previous record; it cannot mutate the original or
    // create a new independent language code. Unknown statements decline the
    // whole source before any code or code-specific label is committed.
    pub fn addNamedSectionDataLua(self: *Registry, source: []const u8, _: NamedSectionProvider) !bool {
        var chunk = lua_parser.parse(self.arena.child_allocator, source) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        defer chunk.deinit();
        const temporary = chunk.arena.allocator();
        const Record = struct { label: ?[]const u8 = null, special: bool = false, group: bool = false, alias: bool = false };
        var records: std.StringHashMapUnmanaged(Record) = .empty;
        var schema = try lua_parser.parse(temporary,
            \\local function aliasOf(code)
            \\ local copy = { aliasOf = code }
            \\ for k, v in pairs(l[code]) do copy[k] = v end
            \\ return copy
            \\end
        );
        defer schema.deinit();
        var initialized = false;
        var exported = false;
        var alias_function = false;
        for (chunk.body) |statement| {
            if (statement.* == .empty) continue;
            if (exported) return false;
            switch (statement.*) {
                .local_assign => |v| {
                    if (initialized or v.names.len != 1 or !std.mem.eql(u8, v.names[0], "l") or v.values.len != 1) return false;
                    if ((literalTable(v.values[0]) orelse return false).len != 0) return false;
                    initialized = true;
                },
                .local_function => {
                    if (!initialized or alias_function or !PositionalProviderContract.eq(lua_parser.Stmt, statement.*, schema.body[0].*)) return false;
                    alias_function = true;
                },
                .assign => |v| {
                    if (!initialized or v.targets.len != 1 or v.values.len != 1) return false;
                    const target = switch (v.targets[0]) { .index => |value| value, else => return false };
                    if (!literalName(target.object, "l")) return false;
                    const key = literalString(target.key) orelse return false;
                    var record: Record = .{};
                    switch (v.values[0].*) {
                        .table => |table| {
                            var seen: std.StringHashMapUnmanaged(void) = .empty;
                            for (table.fields) |field| {
                                const item: LuaLiteralField = switch (field) {
                                    .named => |value| .{ .key = value.name, .value = value.value },
                                    .keyed => |value| .{ .key = literalString(value.key) orelse return false, .value = value.value },
                                    .list => return false,
                                };
                                if (seen.contains(item.key) or !nomLiteralValue(item.value, 0)) return false;
                                try seen.put(temporary, item.key, {});
                                if (std.mem.eql(u8, item.key, "name")) {
                                    record.label = literalString(item.value) orelse return false;
                                    if (!validLocalHeading(record.label.?)) return false;
                                } else if (std.mem.eql(u8, item.key, "isSpecial") or std.mem.eql(u8, item.key, "isGroup")) {
                                    const flag = switch (item.value.*) { .nil_lit => false, .bool_lit => |value| value.value, else => return false };
                                    if (std.mem.eql(u8, item.key, "isSpecial")) record.special = flag else record.group = flag;
                                } else if (std.mem.eql(u8, item.key, "aliasOf")) {
                                    _ = literalString(item.value) orelse return false;
                                    record.alias = true;
                                }
                            }
                        },
                        .call => |call| {
                            if (!alias_function or !literalName(call.callee, "aliasOf") or call.args.len != 1) return false;
                            record = records.get(literalString(call.args[0]) orelse return false) orelse return false;
                            record.alias = true;
                        },
                        else => return false,
                    }
                    // Copy the value now: subsequent writes to the original
                    // key do not change the source helper's shallow snapshot.
                    try records.put(temporary, key, record);
                },
                .return_stmt => |v| {
                    if (!initialized or v.values.len != 1 or !literalName(v.values[0], "l")) return false;
                    exported = true;
                },
                else => return false,
            }
        }
        if (!exported) return false;
        var rows = records.iterator();
        while (rows.next()) |row| {
            const record = row.value_ptr.*;
            const label = record.label orelse continue;
            const code_value = row.key_ptr.*;
            if (record.alias or record.special or record.group or !validCode(code_value)) continue;
            // A code-like spelling already owned by another language remains
            // that alias. Source code registration never erases a collision.
            if (self.ambiguous.contains(code_value)) continue;
            if (self.names.get(code_value)) |owner| if (!std.mem.eql(u8, owner, code_value)) continue;
            try self.reserveCode(code_value);
            const owned = self.arena.allocator();
            if (!self.headings.contains(code_value)) {
                const capital = (try nomCapitalizationAlloc(temporary, label)) orelse label;
                try self.headings.put(owned, try owned.dupe(u8, code_value), try owned.dupe(u8, capital));
            }
            // No ordinary display-name alias or default owner is installed.
            if (self.source_nom_names.getPtr(code_value)) |previous| {
                if (previous.*) |old| if (!std.mem.eql(u8, old, label)) { previous.* = null; };
            } else try self.source_nom_names.put(owned, try owned.dupe(u8, code_value), try owned.dupe(u8, label));
        }
        return true;
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
            // Retain code-specific source evidence separately. A colliding
            // global name is not promoted by an explicitly coded source call.
            // get_nom indexes l[raw_code]; an ISO alias key does not prove
            // the canonical key exists. Preserve old alias import separately.
            if (std.mem.eql(u8, row.key_ptr.*, code_value)) {
                const owned = self.arena.allocator();
                if (self.source_nom_names.getPtr(code_value)) |previous| {
                    if (previous.*) |name| {
                        if (!std.mem.eql(u8, name, label)) previous.* = null;
                    }
                } else try self.source_nom_names.put(owned, try owned.dupe(u8, code_value), try owned.dupe(u8, label));
            }
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

    // Only the normal, source-authenticated formatter and an exact raw code
    // may use this role. It never resolves an ambiguous display name.
    pub fn sourceNomLabel(self: *const Registry, code_value: []const u8) ?[]const u8 {
        if (!self.source_nom_role or !self.codes.contains(code_value)) return null;
        return self.source_nom_names.get(code_value) orelse null;
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
            // This table's value is a code, not a displayed name. A captured
            // preferred name may itself spell another code (Ga versus Irish).
            // Preserve registered code identity here without changing name trust.
            const canonical_code = if (self.codes.contains(value)) value else
                if (self.resolve(value)) |resolved| resolved.code else value;
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
            records: []const struct { id: []const u8, code: []const u8, alias: []const u8, authority_kind: []const u8, preserve_heading: bool = false },
        }, self.arena.allocator(), evidence, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "wikidict.reviewed-language-aliases.v1")) return error.InvalidLanguageRegistry;
        var matches: usize = 0;
        var preserve_heading = false;
        for (parsed.value.records) |record| {
            if (std.mem.eql(u8, reference, record.id) and std.mem.eql(u8, code_value, record.code) and
                std.mem.eql(u8, name, record.alias) and std.mem.eql(u8, record.authority_kind, "reviewed_public_reference"))
            {
                matches += 1;
                preserve_heading = record.preserve_heading;
            }
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
        if (preserve_heading) try self.reviewed_varieties.put(owned, try owned.dupe(u8, name), {});
        // Ordinary language headings also capitalize the first ASCII letter.
        // Keep this an editorial alias, with no source-derived trust grant.
        // Exact names, codes, boundaries and conflicting aliases take priority.
        if (!preserve_heading and name.len != 0 and std.ascii.isLower(name[0])) {
            const capitalized = try owned.dupe(u8, name);
            capitalized[0] = std.ascii.toUpper(capitalized[0]);
            if (!self.names.contains(capitalized) and !self.codes.contains(capitalized) and
                !self.isLanguageBoundary(capitalized) and !self.reviewed_aliases.contains(capitalized))
                try self.reviewed_aliases.put(owned, capitalized, try owned.dupe(u8, code_value));
        }
    }


    pub fn isLaoCodeTemplate(self: *const Registry, title: []const u8) bool {
        if (self.codes.contains(title)) return true;
        if (title.len != 2 and title.len != 3) return false;
        for (title) |byte| if (!std.ascii.isLower(byte)) return false;
        return true;
    }

    /// A Lao translation label is a code-named template whose entire expansion
    /// is one link to a language name. The wiki's paired translation template
    /// uses the same code for its `lang` and `xml:lang` attributes.
    pub fn addLaoLanguageLink(self: *Registry, code_value: []const u8, source: []const u8) !void {
        if (!std.mem.eql(u8, self.content_code orelse return, "lo") or !self.isLaoCodeTemplate(code_value)) return;
        const prefix = "ພາສາ";
        const raw = std.mem.trim(u8, source, " \t\r\n");
        if (!std.mem.startsWith(u8, raw, "[[" ++ prefix) or !std.mem.endsWith(u8, raw, "]]")) return;
        const label = raw[2 .. raw.len - 2];
        const name = label[prefix.len..];
        if (name.len == 0) return;
        const text = std.unicode.Utf8View.init(name) catch return;
        var points = text.iterator();
        while (points.nextCodepoint()) |point| switch (point) {
            0x0e81...0x0e82, 0x0e84, 0x0e86...0x0e8a, 0x0e8c...0x0ea3, 0x0ea5,
            0x0ea7...0x0ebd, 0x0ec0...0x0ec4, 0x0ec8...0x0ece, 0x0edc...0x0edf => {},
            else => return,
        };
        // Record competing declarations before testing the shorter name. This
        // makes the result independent of template order, even on a collision.
        try self.addSourceTemplateLabel(label, code_value);
        const conflicting = if (self.local_aliases.get(label)) |owner| owner == null else false;
        if (conflicting or !self.sourceBannerLiteralCodeNameCompatible(code_value, name))
        {
            if (self.local_aliases.getPtr(label)) |slot| slot.* = null;
            if (!self.names.contains(label) and !self.isLanguageBoundary(label)) {
                const owned = self.arena.allocator();
                try self.ambiguous.put(owned, try owned.dupe(u8, label), {});
            }
        }
    }

    /// Import a label proved by an authenticated static hyphen-code template.
    /// Keep canonical names and existing trust unchanged, and retain folded
    /// collisions with every imported name or prior local declaration.
    pub fn addSourceTemplateLabel(self: *Registry, name: []const u8, code_value: []const u8) !void {
        if (!self.codes.contains(code_value) or !validLocalLabel(name)) return;
        var boundaries = self.language_boundaries.iterator();
        while (boundaries.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return;
        }
        var local = self.local_aliases.iterator();
        var conflict = false;
        while (local.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) continue;
            const previous = entry.value_ptr.*;
            if (previous == null or !std.mem.eql(u8, previous.?, code_value)) {
                entry.value_ptr.* = null;
                conflict = true;
            }
        }
        if (conflict) {
            // A third folded spelling with the requested owner is still part
            // of this conflict; ordinary exact lookup must not retain it.
            var folded = self.local_aliases.iterator();
            while (folded.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) entry.value_ptr.* = null;
            }
            // Record this spelling as ambiguous too; subsequent declarations
            // must not resurrect a differently capitalized local alias.
            try self.addLocalAlias(name, code_value);
            if (self.local_aliases.getPtr(name)) |slot| slot.* = null;
            return;
        }
        if (!self.sourceBannerNameAllowed(code_value, name, false)) return;
        try self.addLocalAlias(name, code_value);
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

    /// A code-named Estonian template may attest its already installed preferred
    /// label. This creates no spelling or owner: the scalar source must equal
    /// that label, allowing only its existing first ASCII letter to be lowercase.
    pub fn addSourceLiteralPreferredHeading(self: *Registry, wiki_id: []const u8, code_value: []const u8, source: []const u8) !void {
        if (!std.mem.eql(u8, wiki_id, "etwiktionary") or
            !std.mem.eql(u8, self.content_code orelse "", "et") or !self.codes.contains(code_value)) return;
        const preferred = self.headings.get(code_value) orelse return;
        if (!self.localHeadingMatches(code_value, preferred) or preferred.len == 0 or
            source.len != preferred.len or !validLocalHeading(source)) return;
        if (!std.mem.eql(u8, source, preferred) and !(std.ascii.isUpper(preferred[0]) and
            source[0] == std.ascii.toLower(preferred[0]) and std.mem.eql(u8, source[1..], preferred[1..]))) return;
        // Existing trust and ambiguity rules remain authoritative. In particular,
        // no alternate spelling in the scalar source becomes an alias.
        try self.trustLocalHeading(code_value, preferred);
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

    // This one reviewed Chinese spelling joins the captured local display to
    // the independently parsed canonical field in Languages/data/3/f. Other
    // translated UI names remain unrelated to heading ownership.
    fn capturedZhOldFrench(self: *const Registry, a: std.mem.Allocator, source: []const u8, wiki: []const u8, language: []const u8) !bool {
        if (!std.mem.eql(u8, wiki, "zhwiktionary") or !std.mem.eql(u8, language, "zh")) return false;
        const original = (self.source_full_names.get("fro") orelse return false) orelse return false;
        if (!std.mem.eql(u8, original, "古法語")) return false;
        const local = self.resolveTrusted(original) orelse canonical_source: {
            // The complete dump-local canonical module establishes Strong
            // ownership without granting Trusted aliases. Its presence must not
            // invalidate the independently captured positional/display proof.
            const canonical = self.resolveCanonicalName(original) orelse return false;
            const strong = self.resolveStrong(original) orelse return false;
            if (!std.mem.eql(u8, canonical.code, strong.code) or
                !self.sourceBannerNameAllowed("fro", original, false)) return false;
            break :canonical_source strong;
        };
        if (!std.mem.eql(u8, local.code, "fro") or !self.sourceBannerNameAllowed("fro", "古法语", false)) return false;
        var expected: [2]?usize = .{ null, null };
        var counts: [2]usize = .{ 0, 0 };
        var matched: [2]bool = .{ false, false };
        var seen: [2]std.StringHashMapUnmanaged(void) = .{ .empty, .empty };
        defer for (&seen) |*map| map.deinit(a);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            const tag = fields.next() orelse continue;
            const display = fields.next() orelse continue;
            const scope = fields.next() orelse continue;
            if (!std.mem.eql(u8, display, "zh")) continue;
            const index: usize = if (std.mem.eql(u8, scope, "all")) 0 else if (std.mem.eql(u8, scope, "single")) 1 else continue;
            if (std.mem.eql(u8, tag, "C")) {
                if (expected[index] != null) return false;
                expected[index] = std.fmt.parseInt(usize, fields.next() orelse return false, 10) catch return false;
                if (expected[index].? > 20031 or fields.next() != null) return false;
            } else if (std.mem.eql(u8, tag, "N")) {
                const limit = expected[index] orelse return false;
                const code_value = fields.next() orelse return false;
                const name = try decodeAutonymName(a, fields.next() orelse return false);
                if (fields.next() != null or counts[index] >= limit) return false;
                counts[index] += 1;
                const row = try seen[index].getOrPut(a, code_value);
                if (row.found_existing) return false;
                const old_french = std.mem.eql(u8, code_value, "fro");
                const label = std.mem.eql(u8, name, "古法语");
                if (old_french != label) return false;
                if (old_french) matched[index] = true;
            }
        }
        return matched[0] and matched[1] and counts[0] == expected[0].? and counts[1] == expected[1].?;
    }

    /// Promote installed captured autonyms and their existing same-code ASCII
    /// first-letter capitals. Translated UI profiles are not heading proof.
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
        var english_expected: ?usize = null;
        var english_count: usize = 0;
        var english_codes: std.StringHashMapUnmanaged(void) = .empty;
        var english_names: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        var english_pending: std.ArrayList(struct { code: []const u8, name: []const u8 }) = .empty;
        var codes: std.StringHashMapUnmanaged(void) = .empty;
        var support_codes: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.StringHashMapUnmanaged(?[]const u8) = .empty;
        var pending: std.ArrayList(struct { code: []const u8, name: []const u8 }) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const tag = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            const display = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            const scope = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            if (std.mem.eql(u8, tag, "S")) {
                if (fields.next() != null or !autonymCodeValid(display) or
                    (!std.mem.eql(u8, scope, "1") and !std.mem.eql(u8, scope, "0")) or
                    (std.mem.eql(u8, display, "qqq") and std.mem.eql(u8, scope, "1"))) return error.InvalidLanguageNameSnapshot;
                const seen = try support_codes.getOrPut(a, display);
                if (seen.found_existing) return error.DuplicateLanguageSupport;
                continue; // Support evidence does not grant a language name.
            }
            if (std.mem.eql(u8, tag, "D")) {
                if (fields.next() != null or !autonymCodeValid(display) or
                    (!std.mem.eql(u8, scope, "ltr") and !std.mem.eql(u8, scope, "rtl"))) return error.InvalidLanguageNameSnapshot;
                continue;
            }
            const english = std.mem.eql(u8, display, "en") and std.mem.eql(u8, scope, "all");
            const autonym = std.mem.eql(u8, display, "-") and std.mem.eql(u8, scope, "single");
            const direction = std.mem.eql(u8, display, "-") and std.mem.eql(u8, scope, "dir") and std.mem.eql(u8, tag, "C");
            if (!autonym and !direction and (!autonymCodeValid(display) or
                (!std.mem.eql(u8, scope, "all") and !std.mem.eql(u8, scope, "mw") and !std.mem.eql(u8, scope, "single")))) return error.InvalidLanguageNameSnapshot;
            if (std.mem.eql(u8, tag, "C")) {
                const value = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null) return error.InvalidLanguageNameSnapshot;
                const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLanguageNameSnapshot;
                if (n > 20031) return error.InvalidLanguageNameSnapshot;
                if (english) {
                    if (english_expected != null) return error.DuplicateLanguageNameProfile;
                    english_expected = n;
                }
                if (autonym) {
                    if (expected_count != null) return error.DuplicateLanguageNameProfile;
                    expected_count = n;
                }
            } else if (std.mem.eql(u8, tag, "N")) {
                const code_value = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const raw_name = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null or !autonymCodeValid(code_value)) return error.InvalidLanguageNameSnapshot;
                if (english) {
                    const n = english_expected orelse return error.IncompleteLanguageNameProfile;
                    if (english_count >= n) return error.IncompleteLanguageNameProfile;
                    english_count += 1;
                    const seen = try english_codes.getOrPut(a, code_value);
                    if (seen.found_existing) return error.DuplicateLanguageName;
                    const name = try decodeAutonymName(a, raw_name);
                    if (name.len != 0) {
                        const known = try english_names.getOrPut(a, name);
                        if (known.found_existing) {
                            if (known.value_ptr.*) |owner| if (!std.mem.eql(u8, owner, code_value)) { known.value_ptr.* = null; };
                        } else known.value_ptr.* = code_value;
                        try english_pending.append(a, .{ .code = code_value, .name = name });
                    }
                }
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
        }
        if (english_expected) |n| if (english_count != n) return error.IncompleteLanguageNameProfile;
        const zh_old_french = try self.capturedZhOldFrench(a, source, wiki, language);
        // Validate the complete selected profile before changing any trust.
        // A code alias, missing label, ambiguous name or later local conflict
        // cannot acquire authority from this independent spelling evidence.
        for (pending.items) |row| {
            if (self.english_added_aliases.contains(row.name)) continue;
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
            // The normal registry generator also installs first-letter capitals.
            // Extend only an existing same-code alias of this captured autonym;
            // do not manufacture labels or change the preferred display/code.
            const capitalized = if (std.ascii.isLower(row.name[0])) first_capital: {
                const value = try a.dupe(u8, row.name);
                value[0] = std.ascii.toUpper(value[0]);
                break :first_capital value;
            } else row.name;
            for ([_][]const u8{ row.name, capitalized }) |label| {
                if (self.english_added_aliases.contains(label)) continue;
                // An explicit competing profile spelling remains a veto, including
                // a duplicate spelling whose owner was marked ambiguous above.
                if (names.get(label)) |captured| {
                    const captured_owner = captured orelse continue;
                    if (!std.mem.eql(u8, captured_owner, row.code)) continue;
                }
                if (!self.localHeadingMatches(row.code, label)) continue;
                if (self.autonym_headings.getPtr(label)) |proof| {
                    if (proof.*) |previous| {
                        if (!std.mem.eql(u8, previous, row.code)) proof.* = null;
                    }
                } else {
                    const owned = self.arena.allocator();
                    const key = try owned.dupe(u8, label);
                    errdefer owned.free(key);
                    const code_value = try owned.dupe(u8, row.code);
                    errdefer owned.free(code_value);
                    try self.autonym_headings.put(owned, key, code_value);
                }
            }
        }
        // Complete captured English names supply ordinary aliases only. They
        // do not become Strong/Trusted headings or replace local canonical names.
        for (english_pending.items) |row| {
            const unique = english_names.get(row.name).? orelse continue;
            if (!std.mem.eql(u8, unique, row.code) or !self.codes.contains(row.code) or
                !validLocalHeading(row.name) or !self.sourceBannerNameAllowed(row.code, row.name, false)) continue;
            const existed = self.names.contains(row.name);
            try self.addAlias(row.name, row.code);
            if (!existed) {
                if (self.names.get(row.name)) |installed| {
                    if (std.mem.eql(u8, installed, row.code)) {
                        try self.english_added_aliases.put(self.arena.allocator(), self.names.getKey(row.name).?, {});
                    }
                }
            }
        }
        if (zh_old_french) try self.addLocalAlias("古法语", "fro");
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

    /// A reviewed declaration role, not a claim that arbitrary Lua is pure.
    /// The normal loader authenticates these complete module bodies and
    /// their namespace/model roles before requesting this specialization.
    pub const SourceSectionNameRole = enum { full_category_anchor };

    pub const source_section_name_role_hashes = [_][]const u8{
        "6a1d6dbc4244054c0c988e4ec699c471d838d3c27f5c1423489afe3e66d86ee5",
        "cba69d1a55d3304ae1bd8bf9e22ea550bb7abc186ee76e08408d10fc72be3775",
        "4e48c1836ba6a1d12efd360d7f43e9c926961bde376616feeab6196ad532b72f",
        "289083173a85768300342e633300209a93af49e1d391e7a6495221e6487e78f4",
    };

    pub fn proveSourceSectionNameRole(provider: []const u8, links: []const u8, language_like: []const u8, language_data: []const u8) ?SourceSectionNameRole {
        const sources = [_][]const u8{ provider, links, language_like, language_data };
        for (sources, source_section_name_role_hashes) |source, digest| {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
            if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), digest)) return null;
        }
        return .full_category_anchor;
    }

    /// Only the finite literal full-language data declaration is imported. No
    /// labels are stripped or inferred from a page's edition, script or title.
    pub fn addSourceSectionLanguageDataLua(self: *Registry, source: []const u8, role: SourceSectionNameRole, module_base: []const u8) !void {
        try positionalLanguageDataImportWithSections(self, source, module_base, role);
    }

    /// An authenticated default L2 formatter is a heading role, never an alias.
    pub const SourceSectionHeading = struct { owner: ?Resolved };

    pub fn registerSourceSectionFormatter(self: *Registry, proof: SourceSectionFormatter) !void {
        if (self.source_section_prefix) |old| {
            if (!std.mem.eql(u8, old, proof.prefix)) self.source_section_conflict = true;
            return;
        }
        self.source_section_prefix = try self.arena.allocator().dupe(u8, proof.prefix);
    }

    pub fn sourceSectionHeading(self: *const Registry, heading: []const u8) ?SourceSectionHeading {
        const prefix = self.source_section_prefix orelse return null;
        if (!std.mem.startsWith(u8, heading, prefix)) return null;
        const refused: SourceSectionHeading = .{ .owner = null };
        if (self.source_section_conflict or heading.len == prefix.len) return refused;
        const name = heading[prefix.len..];
        if (self.isLanguageBoundary(heading) or self.isLanguageBoundary(name)) return refused;
        const canonical = self.resolveCanonicalName(name) orelse return refused;
        const strong = self.resolveStrong(name) orelse return refused;
        if (!std.mem.eql(u8, canonical.code, strong.code) or !self.codes.contains(strong.code) or
            std.mem.eql(u8, strong.code, "und")) return refused;
        const full_name = (self.source_full_names.get(strong.code) orelse return refused) orelse return refused;
        if (!std.mem.eql(u8, full_name, name)) return refused;
        for ([_][]const u8{ heading, name }) |label| {
            if (self.resolve(label)) |known| if (!std.mem.eql(u8, known.code, strong.code)) return refused;
        }
        return .{ .owner = strong };
    }

    fn addSourceFullName(self: *Registry, code_value: []const u8, name: ?[]const u8) !void {
        if (self.source_full_names.getPtr(code_value)) |old| {
            if (old.*) |previous| {
                if (name == null or !std.mem.eql(u8, previous, name.?)) old.* = null;
            }
            return;
        }
        const a = self.arena.allocator();
        try self.source_full_names.put(a, try a.dupe(u8, code_value), if (name) |value| try a.dupe(u8, value) else null);
    }

    /// Positional records are names only when the actual normal provider proves
    /// the getter, exported table and field-one-preserving finalizer contract.
    pub const PositionalLanguageProvider = enum { canonical_field_one };

    pub fn provePositionalLanguageProvider(a: std.mem.Allocator, source: []const u8) !?PositionalLanguageProvider {
        return if (try positionalLanguageProviderProof(a, source)) .canonical_field_one else null;
    }

    pub fn provePositionalLanguageProviderWithNamespaces(a: std.mem.Allocator, source: []const u8, namespaces: *const namespace_registry.Registry) !?PositionalLanguageProvider {
        return if (try positionalLanguageProviderProofWithNamespaces(a, source, namespaces)) .canonical_field_one else null;
    }

    // The normal loader obtains this immutable proof once from the authenticated
    // provider source, then independently authenticates each data module.
    pub fn addPositionalLanguageDataLua(self: *Registry, source: []const u8, _: PositionalLanguageProvider, module_base: []const u8) !void {
        try positionalLanguageDataImport(self, source, module_base);
    }

    /// Read only the literal records in the two pinned language-data shapes.
    /// Unsupported writes invalidate the staged source before any alias is added.
    pub fn addLanguageDataLua(self: *Registry, source: []const u8, kind: LanguageDataKind) !void {
        return self.addLanguageDataLuaForHeadwordRole(source, kind, null);
    }

    pub fn addLanguageDataLuaForHeadwordRole(self: *Registry, source: []const u8, kind: LanguageDataKind, module_role: ?[]const u8) !void {
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
        for (pending.items) |entry| {
            try self.addLocalAlias(entry.value, entry.key);
            if (self.source_headword_role and kind == .canonical_assignments and entry.source_key != null and std.mem.eql(u8, entry.source_key.?, entry.key)) if (module_role) |role| {
                // Match the selected getDataModuleName branches, not a merely
                // code-looking key placed in a different data module.
                const matched = if (entry.key.len == 2) std.mem.eql(u8, role, "languages/data2") else
                    entry.key.len == 3 and role.len == "languages/data3/".len + 1 and
                        std.mem.startsWith(u8, role, "languages/data3/") and role[role.len - 1] == entry.key[0];
                var lowercase = true;
                for (entry.key) |byte| if (byte < 'a' or byte > 'z') { lowercase = false; };
                if (matched and lowercase) try self.rememberSourceHeadwordCode(entry.key, entry.value);
            };
        }
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
        try pending.append(temporary, .{ .key = code_value, .value = name, .source_key = key });
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

const LocalName = struct { key: []const u8, value: []const u8, source_key: ?[]const u8 = null };
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

test "Lao code links preserve canonical names and refuse markup and conflicting owners" {
    const a = std.testing.allocator;
    const corpus = "# content-language\tlo\n# mediawiki\nlo\tລາວ\nda\tແດນິຊ\tDansk\nja\tຍີ່ປຸ່ນ\t日本語\nyue\tກວາງຕຸ້ງ\nzh-yue\tCantonese alias\n";
    for ([_]bool{ false, true }) |reverse| {
        var registry = Registry.empty(a);
        defer registry.deinit();
        try registry.addTsv(corpus);
        const danish = "[[ພາສາດານມາກ]]"; // Template:da, page 28059, revision 51433
        const japanese = "[[ພາສາຍີ່ປຸ່ນ]]"; // Template:ja, page 9576, revision 17490
        try registry.addLaoLanguageLink("da", danish);
        try registry.addLaoLanguageLink("ja", japanese);
        try std.testing.expectEqualStrings("da", registry.resolveTrusted("ພາສາດານມາກ").?.code);
        try std.testing.expectEqualStrings("ຍີ່ປຸ່ນ", registry.resolveTrusted("ພາສາຍີ່ປຸ່ນ").?.heading);
        try registry.addLaoLanguageLink("zh-yue", "[[ພາສາກວາງຕຸ້ງ]]");
        try std.testing.expect(registry.resolveTrusted("ພາສາກວາງຕຸ້ງ") == null);
        const conflict = "[[ພາສາກຂ]]";
        try registry.addLaoLanguageLink(if (reverse) "ja" else "da", conflict);
        try registry.addLaoLanguageLink(if (reverse) "da" else "ja", conflict);
        try registry.addLaoLanguageLink("da", conflict);
        try std.testing.expect(registry.resolveTrusted("ພາສາກຂ") == null);
        try std.testing.expect(registry.isLanguageBoundary("ພາສາກຂ"));
        for ([_][]const u8{ "[[ພາສາກ|ກ]]", "[[ພາສາກ#ກ]]", "[[ພາສາກ]]<!--x-->", "[[:ພາສາກ]]", "[[ພາສາກ]][[ກ]]", "*{{da}}: {{ກ|da|ກ}}" }) |source|
            try registry.addLaoLanguageLink("da", source);
        try std.testing.expect(!registry.isLanguageBoundary("ພາສາກ"));
        try registry.addLaoLanguageLink("xx", "[[ພາສາກ]]");
        try std.testing.expect(registry.resolveTrusted("ພາສາກ") == null);
        try std.testing.expect(registry.isLanguageBoundary("ພາສາກ"));
    }
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
    return positionalLanguageProviderProofWithNamespaces(a, source, null);
}

// Only the data-module selector may use the selected localized Module namespace.
// The source itself is never rewritten, and every other contract node stays exact.
fn localizedProviderSelector(a: std.mem.Allocator, namespaces: ?*const namespace_registry.Registry) !?lua_parser.Chunk {
    const registry = namespaces orelse return null;
    for (registry.entries) |spec| {
        if (spec.id != 828 or !std.mem.eql(u8, spec.canonical_name, "Module") or std.mem.eql(u8, spec.name, "Module")) continue;
        if (spec.name.len == 0) return null;
        for (spec.name) |byte| if (byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\\' or byte == ':') return null;
        const literal = try std.fmt.allocPrint(a, "\"{s}:\"", .{spec.name});
        defer a.free(literal);
        const schema = try std.mem.replaceOwned(u8, a, PositionalProviderSchema.source, "\"Module:\"", literal);
        defer a.free(schema);
        return try lua_parser.parse(a, schema);
    }
    return null;
}

// A second exact field-one-preserving finalizer shape used by the selected
// provider. Keep both complete AST contracts; do not normalize arbitrary writes
// or claim identical assignment/metamethod order for arbitrary caller objects.
fn sequentialFinalizerContract(a: std.mem.Allocator) !lua_parser.Chunk {
    const schema = try std.mem.replaceOwned(u8, a, PositionalProviderSchema.source,
        "entity.parent, entity[3], entity.family = entity[3], entity.family",
        "entity.parent, entity[3] = entity[3], entity.family\nentity.family = nil");
    defer a.free(schema);
    return lua_parser.parse(a, schema);
}

fn positionalLanguageProviderProofWithNamespaces(a: std.mem.Allocator, source: []const u8, namespaces: ?*const namespace_registry.Registry) !bool {
    if (source.len > 256 * 1024) return false;
    var actual = lua_parser.parse(a, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer actual.deinit();
    var expected = try lua_parser.parse(a, PositionalProviderSchema.source);
    defer expected.deinit();
    var localized = try localizedProviderSelector(a, namespaces);
    defer if (localized) |*chunk| chunk.deinit();
    var sequential = try sequentialFinalizerContract(a);
    defer sequential.deinit();
    var proof = PositionalProviderContract{ .expected = expected.body, .sequential_finalizer = sequential.body, .localized_selector = if (localized) |chunk| chunk.body else &.{} };
    if (!proof.block(actual.body, 0, true)) return false;
    return proof.export_init == 1 and proof.language_init == 1 and proof.export_return == 1 and
        proof.getter == 1 and proof.selector == 1 and proof.finalizer == 1 and proof.constructor == 1 and
        proof.dependencies == 0b1111111 and proof.libraries == 0b11;
}

const PositionalProviderContract = struct {
    const Expr = lua_parser.Expr;
    const Stmt = lua_parser.Stmt;
    expected: lua_parser.Block,
    localized_selector: lua_parser.Block = &.{},
    sequential_finalizer: lua_parser.Block = &.{},
    export_init: usize = 0,
    language_init: usize = 0,
    export_return: usize = 0,
    getter: usize = 0,
    selector: usize = 0,
    finalizer: usize = 0,
    constructor: usize = 0,
    full_name_contract: bool = false,
    full_object: usize = 0,
    full_code: usize = 0,
    full_name: usize = 0,
    full_unrelated_cache: usize = 0,
    dependencies: u8 = 0,
    libraries: u2 = 0,
    function_depth: usize = 0,
    receiver_aliases: [64][]const u8 = undefined,
    receiver_alias_count: usize = 0,

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
    // Track explicit receiver aliases within the current lexical traversal.
    // Names stay tainted across assignments/branches; function exit restores the
    // outer set so unrelated method-local names do not acquire that identity.
    fn receiverValue(self: *const @This(), e: *const Expr, depth: usize) bool {
        if (depth > 128) return true;
        return switch (e.*) {
            .name => |n| blk: {
                if (std.mem.eql(u8, n.value, "self")) break :blk true;
                for (self.receiver_aliases[0..self.receiver_alias_count]) |name|
                    if (std.mem.eql(u8, n.value, name)) break :blk true;
                break :blk false;
            },
            .paren => |p| self.receiverValue(p.expr, depth + 1),
            .binary => |b| (b.op == .and_ or b.op == .or_) and
                (self.receiverValue(b.lhs, depth + 1) or self.receiverValue(b.rhs, depth + 1)),
            .index => |i| self.receiverValue(i.object, depth + 1) and
                (!literalName(i.object, "self") or i.key.* != .string or std.mem.eql(u8, i.key.string.value, "_fullObject")),
            .table => |t| blk: {
                for (t.fields) |field| {
                    const value = switch (field) { .list => |v| v, .named => |v| v.value, .keyed => |v| v.value };
                    if (self.receiverValue(value, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }
    fn receiverAlias(self: *@This(), name: []const u8) bool {
        for (self.receiver_aliases[0..self.receiver_alias_count]) |old| if (std.mem.eql(u8, old, name)) return true;
        if (self.receiver_alias_count == self.receiver_aliases.len) return false;
        self.receiver_aliases[self.receiver_alias_count] = name;
        self.receiver_alias_count += 1;
        return true;
    }

    fn target(self: *@This(), t: lua_parser.LValue, depth: usize) bool {
        return switch (t) {
            .name => |n| !sensitive(n) and !environment(n) and dependency(n) == null,
            .index => |i| blk: {
                if (isName(i.object, "string") or isName(i.object, "table")) break :blk false;
                if (self.full_name_contract and self.receiverValue(i.object, 0) and i.key.* != .string) break :blk false;
                if (i.key.* == .string) {
                    const key = i.key.string.value;
                    // The authoritative declaration is handled before target().
                    // Unknown roots may be a recovered language prototype.
                    if (std.mem.eql(u8, key, "getCanonicalName")) break :blk false;
                    if (self.full_name_contract) {
                        for ([_][]const u8{ "getFull", "getFullCode", "getFullName", "_fullObject", "_fullCode", "_fullName" }) |field|
                            if (std.mem.eql(u8, key, field)) break :blk false;
                    }
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
        if (self.full_name_contract and e.* == .name and std.mem.eql(u8, e.name.value, "rawset")) return false;
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
        const prior_aliases = self.receiver_alias_count;
        defer self.receiver_alias_count = prior_aliases;
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
                    if (self.full_name_contract) for (v.values, 0..) |value, i| {
                        if (i < v.names.len and self.receiverValue(value, 0) and !self.receiverAlias(v.names[i])) return false;
                    };
                },
                .assign => |v| {
                    for (v.targets) |t| if (!self.target(t, depth + 1)) return false;
                    if (!self.exprs(v.values, depth + 1)) return false;
                    if (self.full_name_contract) for (v.values, 0..) |value, i| {
                        if (i >= v.targets.len or !self.receiverValue(value, 0)) continue;
                        switch (v.targets[i]) {
                            .name => |name| if (!self.receiverAlias(name)) return false,
                            .index => return false,
                        }
                    };
                },
                .function_assign => |v| {
                    if (self.expectedFunction(v.target)) |expected| {
                        if (!admit_contract) return false;
                        if (self.export_init != 1 or self.language_init != 1 or self.dependencies != 0b1111111 or self.libraries != 0b11) return false;
                        if (!eq(Stmt, s.*, expected.*)) {
                            if (v.target != .index or v.target.index.key.* != .string) return false;
                            const alternatives = if (std.mem.eql(u8, v.target.index.key.string.value, "getDataModuleName")) self.localized_selector
                                else if (std.mem.eql(u8, v.target.index.key.string.value, "finalizeData")) self.sequential_finalizer
                                else return false;
                            var alternative_match = false;
                            for (alternatives) |alternative| {
                                if (alternative.* == .function_assign and eq(Stmt, s.*, alternative.*)) { alternative_match = true; break; }
                            }
                            if (!alternative_match) return false;
                        }
                        if (v.target != .index or v.target.index.key.* != .string) return false;
                        const name = v.target.index.key.string.value;
                        if (std.mem.eql(u8, name, "getCanonicalName")) self.getter += 1 else if (std.mem.eql(u8, name, "getDataModuleName")) self.selector += 1 else if (std.mem.eql(u8, name, "finalizeData")) self.finalizer += 1 else if (std.mem.eql(u8, name, "getFull")) self.full_object += 1 else if (std.mem.eql(u8, name, "getFullCode")) self.full_code += 1 else if (std.mem.eql(u8, name, "getFullName")) self.full_name += 1 else self.constructor += 1;
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
                .do_block => |v| {
                    var matched_cache = false;
                    if (self.full_name_contract and admit_contract) {
                        for (self.expected) |contract| if (contract.* == .do_block and eq(Stmt, s.*, contract.*)) {
                            self.full_unrelated_cache += 1; matched_cache = true; break;
                        };
                    }
                    if (!matched_cache and !self.block(v.body, depth + 1, admit_contract)) return false;
                },
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
fn sourceSectionFieldAllowsFull(key: []const u8, value: *const lua_parser.Expr) bool {
    if (std.mem.eql(u8, key, "type")) return std.mem.eql(u8, literalString(value) orelse return false, "regular");
    for ([_][]const u8{ "parent", "_code", "_fullCode", "_types", "_categoryName", "getTypes", "hasType", "getFullCode", "getCategoryName" }) |override|
        if (std.mem.eql(u8, key, override)) return false;
    return true;
}

fn sourceSectionFullLabel(registry: *const Registry, a: std.mem.Allocator, role: Registry.SourceSectionNameRole, code_value: []const u8, label: []const u8, family: ?[]const u8, full: bool) !?[]const u8 {
    _ = role;
    // In the pinned constructor, parentless ordinary language data gives
    // _fullCode == _code; getTypes then marks it full. The ordinary finalizer
    // supplies regular for an absent type. Parent/unknown type/override fields
    // decline above, independently of the module's two/three-letter partition.
    // The pinned languages/data alias table has no keys in that partition, so
    // normalize_code cannot change an admitted record's code.
    if (!full or !validLocalHeading(label) or family == null or std.mem.eql(u8, family.?, "qfa-sub")) return null;
    const canonical = registry.resolveCanonicalName(label) orelse return null;
    // The authenticated canonical module can use a spelling absent from the
    // captured site-preferred names. Its Strong owner is independent authority;
    // this role does not promote that bare spelling to Trusted.
    const owner = registry.resolveStrong(label) orelse registry.resolveTrusted(label) orelse return null;
    if (!std.mem.eql(u8, canonical.code, code_value) or !std.mem.eql(u8, owner.code, code_value)) return null;
    // getCategoryName and Module:links agree on this exact section spelling.
    // Already-prefixed names remain canonical, rather than gaining a prefix.
    if (std.mem.startsWith(u8, label, "ภาษา") or std.mem.startsWith(u8, label, "ภาษณ์")) return null;
    const section = try std.mem.concat(a, u8, &.{ "ภาษา", label });
    return if (validLocalHeading(section)) section else null;
}

fn positionalLanguageDataImport(registry: *Registry, source: []const u8, module_base: []const u8) !void {
    return positionalLanguageDataImportWithSections(registry, source, module_base, null);
}

fn positionalLanguageDataImportWithSections(registry: *Registry, source: []const u8, module_base: []const u8, section_role: ?Registry.SourceSectionNameRole) !void {
    var chunk = lua_parser.parse(registry.arena.child_allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer chunk.deinit();
    const temporary = chunk.arena.allocator();
    const Pending = struct { key: []const u8, value: []const u8, has_parent: bool };
    var pending: std.ArrayList(Pending) = .empty;
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
                var list_count: usize = 0;
                var family: ?[]const u8 = null;
                var full = true;
                var named: ?[]const u8 = null;
                var has_parent = false;
                for (fields) |field| switch (field) {
                    .list => |value| {
                        list_count += 1;
                        if (list_count == 3) family = literalString(value);
                        if (list_seen) continue;
                        list_seen = true;
                        first = literalString(value) orelse return;
                        if (!validLocalLabel(first.?)) return;
                    },
                    .named => |value| {
                        if (std.mem.eql(u8, value.name, "parent")) has_parent = true;
                        if (section_role != null and !sourceSectionFieldAllowsFull(value.name, value.value)) full = false;
                        if (std.mem.eql(u8, value.name, "canonicalName")) {
                            if (named != null) return;
                            named = literalString(value.value) orelse return;
                        }
                    },
                    .keyed => |value| {
                        // A numeric/computed key could replace positional 1.
                        const key_name = literalString(value.key) orelse return;
                        if (std.mem.eql(u8, key_name, "parent")) has_parent = true;
                        if (section_role != null and !sourceSectionFieldAllowsFull(key_name, value.value)) full = false;
                        if (std.mem.eql(u8, key_name, "canonicalName")) {
                            if (named != null) return;
                            named = literalString(value.value) orelse return;
                        }
                    },
                };
                const label = first orelse return;
                if (named) |name| if (!std.mem.eql(u8, name, label)) return;
                if (section_role) |role| {
                    const section = (try sourceSectionFullLabel(registry, temporary, role, key, label, family, full)) orelse continue;
                    try pending.append(temporary, .{ .key = key, .value = section, .has_parent = has_parent });
                } else try pending.append(temporary, .{ .key = key, .value = label, .has_parent = has_parent });
            },
            .return_stmt => |statement| {
                if (!initialized or statement.values.len != 1 or !positionalLanguageDataExport(statement.values[0])) return;
                exported = true;
            },
            else => if (!positionalDataStatementSafe(stmt, false)) return,
        }
    }
    if (!exported) return;
    for (pending.items) |entry| {
        try registry.addLocalAlias(entry.value, entry.key);
        if (section_role == null) try registry.addSourceFullName(entry.key, if (entry.has_parent) null else entry.value);
    }
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

test "reviewed exact Upper Sorbian heading preserves preferred owner and rejects missing or conflicting authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
    const marker = try std.fmt.allocPrint(a, "# reviewed-alias\thsb\thornjoserbšćina\thsb-hornjoserbscina-exact-enwik92963766-v1\t{s}\n", .{std.fmt.bytesToHex(hash, .lower)});
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\nhsb\thornjoserbsce\ndsb\tdelnjoserbšćina\n");
    try std.testing.expect(registry.resolve("hornjoserbšćina") == null);
    try registry.addTsv(marker);
    const actual = registry.resolveTrusted("hornjoserbšćina") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hsb", actual.code);
    try std.testing.expectEqualStrings("hornjoserbsce", actual.heading);
    try std.testing.expect(registry.resolveSourceTrusted("hornjoserbšćina") == null);
    try std.testing.expect(registry.resolve("hornjoserbšćina extra") == null);
    try std.testing.expect(registry.resolve("HORNJOSERBŠĆINA") == null);
    var absent = Registry.empty(a); defer absent.deinit();
    try absent.addTsv("dsb\tdelnjoserbšćina\n");
    try std.testing.expectError(error.InvalidLanguageRegistry, absent.addTsv(marker));
    var conflict = Registry.empty(a); defer conflict.deinit();
    try conflict.addTsv("# mediawiki\nhsb\thornjoserbsce\ndsb\thornjoserbšćina\n");
    try conflict.addTsv(marker);
    try std.testing.expectEqualStrings("dsb", conflict.resolveTrusted("hornjoserbšćina").?.code);
    try registry.addLocalAlias("hornjoserbšćina", "dsb");
    try std.testing.expect(registry.resolveTrusted("hornjoserbšćina") == null);
}


test "captured preferred capitalization survives strong display name replacement" {
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv("# content-language\tsq\n# mediawiki\nsq\tshqip\tShqip\tsq\tAlbanian\tOrdinary alias\nen\tEnglish\n");
    try r.addLua("return { [\"Albanian\"]=\"sq\" }");
    try std.testing.expectEqualStrings("Albanian", r.resolve("sq").?.heading);
    try std.testing.expectEqualStrings("sq", r.resolveTrusted("Shqip").?.code);
    try std.testing.expectEqualStrings("Albanian", r.resolveTrusted("Shqip").?.heading);
    try std.testing.expectEqualStrings("sq", r.resolveSourceTrusted("Shqip").?.code);
    try std.testing.expect(r.resolveStrong("Shqip") == null);
    try std.testing.expect(r.resolveTrusted("Ordinary alias") == null);
    try std.testing.expect(r.resolveTrusted("SHQIP") == null);
    // A captured preferred spelling alone cannot manufacture its absent alias.
    var missing = Registry.empty(std.testing.allocator); defer missing.deinit();
    try missing.addTsv("# mediawiki\nsq\tshqip\n");
    try missing.addLua("return { [\"Albanian\"]=\"sq\" }");
    try std.testing.expect(missing.resolveTrusted("Shqip") == null);
    // ISO and ordinary alias rows cannot acquire the captured-preferred grant.
    var ordinary = Registry.empty(std.testing.allocator); defer ordinary.deinit();
    try ordinary.addTsv("# mediawiki\nsq\tAlbanian\tshqip\tShqip\n# iso-639-3\nfr\tfrançais\tFrançais\n");
    try std.testing.expect(ordinary.resolveTrusted("Shqip") == null);
    try std.testing.expect(ordinary.resolveTrusted("Français") == null);
}

test "captured preferred capitalization rechecks original and installed alias owners" {
    for ([_][]const u8{"Shqip", "shqip"}) |conflict| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv("# mediawiki\nsq\tshqip\tShqip\nen\tEnglish\n");
        try r.addLua("return { [\"Albanian\"]=\"sq\" }");
        try r.addTsv(try std.fmt.allocPrint(r.arena.allocator(), "# mediawiki\nfr\tFrench\t{s}\n", .{conflict}));
        try std.testing.expect(r.resolveTrusted("Shqip") == null);
        try std.testing.expect(r.resolveSourceTrusted("Shqip") == null);
    }
    var unicode = Registry.empty(std.testing.allocator); defer unicode.deinit();
    try unicode.addTsv("# mediawiki\nky\tкыргызча\tКыргызча\nen\tEnglish\n");
    try unicode.addLua("return { [\"Kyrgyz\"]=\"ky\" }");
    try std.testing.expectEqualStrings("ky", unicode.resolveTrusted("Кыргызча").?.code);
    try std.testing.expect(unicode.resolveStrong("Кыргызча") == null);
    try std.testing.expect(unicode.resolveTrusted("КЫРГЫЗЧА") == null);
}

test "reviewed exact Basque Kashubian heading preserves preferred owner and live conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
    const marker = try std.fmt.allocPrint(a, "# reviewed-alias\tcsb\tKaxubiera\teu-kaxubiera-exact-euwiki10723575-v1\t{s}\n", .{std.fmt.bytesToHex(hash, .lower)});
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\ncsb\tKashubian\npl\tpoloniera\n");
    try std.testing.expect(registry.resolve("Kaxubiera") == null);
    try registry.addTsv(marker);
    const actual = registry.resolveTrusted("Kaxubiera") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("csb", actual.code);
    try std.testing.expectEqualStrings("Kashubian", actual.heading);
    try std.testing.expect(registry.resolveSourceTrusted("Kaxubiera") == null);
    try std.testing.expect(registry.resolve("Kaxubiera extra") == null);
    try std.testing.expect(registry.resolve("KAXUBIERA") == null);
    var absent = Registry.empty(a); defer absent.deinit();
    try absent.addTsv("pl\tpoloniera\n");
    try std.testing.expectError(error.InvalidLanguageRegistry, absent.addTsv(marker));
    var conflict = Registry.empty(a); defer conflict.deinit();
    try conflict.addTsv("# mediawiki\ncsb\tKashubian\npl\tKaxubiera\n");
    try conflict.addTsv(marker);
    try std.testing.expectEqualStrings("pl", conflict.resolveTrusted("Kaxubiera").?.code);
    try registry.addLocalAlias("Kaxubiera", "pl");
    try std.testing.expect(registry.resolveTrusted("Kaxubiera") == null);
}


const LiReviewedOwnerTest = struct {
    fn marker(a: std.mem.Allocator, code_value: []const u8, name: []const u8, id: []const u8) ![]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &hash, .{});
        return std.fmt.allocPrint(a, "# reviewed-alias\t{s}\t{s}\t{s}\t{s}\n", .{code_value, name, id, std.fmt.bytesToHex(hash, .lower)});
    }
};

test "reviewed LI varieties retain distinct headings with one installed parent code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var value = Registry.empty(a); defer value.deinit();
    try value.addTsv("# content-language\tfr\n# mediawiki\nfr\tFrench\nli\tLimburgs\n");
    try std.testing.expect(value.resolveTrusted("Mofers") == null);
    try std.testing.expect(value.resolveTrusted("Algemein Gesjreve Limburgs") == null);
    const first = try LiReviewedOwnerTest.marker(a, "li", "Mofers", "li-mofers-variety-p131871-r958780-v1");
    const second = try LiReviewedOwnerTest.marker(a, "li", "Algemein Gesjreve Limburgs", "li-agl-variety-p101567-r983499-v1");
    try value.addTsv(first); try value.addTsv(second);
    for ([_][]const u8{ "Mofers", "Algemein Gesjreve Limburgs" }) |label| {
        try std.testing.expectEqualStrings("li", value.resolve(label).?.code);
        try std.testing.expectEqualStrings(label, value.resolve(label).?.heading);
        try std.testing.expectEqualStrings(label, value.resolveTrusted(label).?.heading);
        try std.testing.expect(value.resolveSourceTrusted(label) == null);
    }
    try std.testing.expectEqualStrings("Limburgs", value.resolve("li").?.heading);
    try std.testing.expect(value.resolveTrusted("mofers") == null);
    try std.testing.expect(value.resolveTrusted("Moferts") == null);
    // Strong authority retains the already reviewed exact variety display too.
    try value.addLua("return { [\"Mofers\"] = \"li\" }");
    try std.testing.expectEqualStrings("Mofers", value.resolveStrong("Mofers").?.heading);
    try std.testing.expectEqualStrings("Algemein Gesjreve Limburgs", value.resolveTrusted("Algemein Gesjreve Limburgs").?.heading);
}

test "reviewed LI varieties reject missing parent and live conflicting owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const marker = try LiReviewedOwnerTest.marker(a, "li", "Mofers", "li-mofers-variety-p131871-r958780-v1");
    var absent = Registry.empty(a); defer absent.deinit();
    try absent.addTsv("fr\tFrench\tli\n");
    try std.testing.expectError(error.InvalidLanguageRegistry, absent.addTsv(marker));
    var collision = Registry.empty(a); defer collision.deinit();
    try collision.addTsv("# mediawiki\nli\tLimburgs\nfr\tMofers\n");
    try collision.addTsv(marker);
    try std.testing.expectEqualStrings("fr", collision.resolveTrusted("Mofers").?.code);
    try std.testing.expect(!collision.reviewed_varieties.contains("Mofers"));
    var late = Registry.empty(a); defer late.deinit();
    try late.addTsv("li\tLimburgs\nfr\tFrench\n"); try late.addTsv(marker);
    try late.addLocalAlias("Mofers", "fr");
    try std.testing.expect(late.resolveTrusted("Mofers") == null);
    var ambiguous = Registry.empty(a); defer ambiguous.deinit();
    try ambiguous.addTsv("li\tLimburgs\nfr\tFrench\n"); try ambiguous.addTsv(marker);
    try ambiguous.addLocalAlias("Mofers", "li"); try ambiguous.addLocalAlias("Mofers", "fr");
    try std.testing.expect(ambiguous.resolveTrusted("Mofers") == null);
}

test "reviewed Nederlandjs alias keeps ordinary Dutch preferred name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var value = Registry.empty(a); defer value.deinit();
    try value.addTsv("# content-language\tfr\n# mediawiki\nfr\tFrench\nnl\tNederlands\n");
    const marker = try LiReviewedOwnerTest.marker(a, "nl", "Nederlandjs", "li-nederlandjs-exact-p26592-r905227-v1");
    try value.addTsv(marker);
    try std.testing.expectEqualStrings("nl", value.resolveTrusted("Nederlandjs").?.code);
    try std.testing.expectEqualStrings("Nederlands", value.resolveTrusted("Nederlandjs").?.heading);
    try std.testing.expect(value.resolveSourceTrusted("Nederlandjs") == null);
    try std.testing.expect(value.resolveTrusted("nederlandjs") == null);
    try std.testing.expect(!value.reviewed_varieties.contains("Nederlandjs"));
}


test "support rows are validated without granting autonym heading authority" {
    var r = Registry.empty(std.testing.allocator);
    defer r.deinit();
    try r.addTsv(AutonymHeadingTest.registry);
    const before = r.codes.count();
    try AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ "S\tnl\t1\nS\tfr\t0\n");
    try std.testing.expectEqual(before, r.codes.count());
    try std.testing.expect(r.resolveTrusted("Dutch") == null);
    try std.testing.expect(!r.codes.contains("nl"));
    try std.testing.expectError(error.DuplicateLanguageSupport, AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ "S\tnl\t1\nS\tnl\t0\n"));
    inline for (.{ "S\tnl\ttrue\n", "S\tNL\t1\n", "S\tqqq\t1\n", "S\tnl\t1\textra\n" }) |row|
        try std.testing.expectError(error.InvalidLanguageNameSnapshot, AutonymHeadingTest.apply(&r, AutonymHeadingTest.header ++ row));
    try std.testing.expectEqual(before, r.codes.count());
}

/// Prove the entire module is one literal forwarding return; execute no Lua.
/// Return an owned target so the parser arena cannot escape into the loader.
pub fn canonicalNameForwardTarget(a: std.mem.Allocator, source: []const u8) !?[]const u8 {
    var p: usize = 0;
    skip(source, &p);
    if (std.mem.startsWith(u8, source[p..], "return")) {
        p += 6;
        skip(source, &p);
        if (p < source.len and source[p] == '{') return null;
    }
    var chunk = try lua_parser.parse(a, source);
    defer chunk.deinit();
    if (chunk.body.len != 1) return null;
    const statement = switch (chunk.body[0].*) { .return_stmt => |v| v, else => return null };
    if (statement.values.len != 1) return null;
    const call = switch (statement.values[0].*) { .call => |v| v, else => return null };
    if (!literalName(call.callee, "require") or call.args.len != 1) return null;
    const target = literalString(call.args[0]) orelse return null;
    if (target.len == 0 or std.mem.indexOfAny(u8, target, "\x00\r\n\t") != null) return null;
    return try a.dupe(u8, target);
}

test "canonical language name and code namespaces preserve HU ari without global heading trust" {
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv("# mediawiki\nhu\tmagyar\nari\tArikara\naac\tAri\naa\tafar\n");
    try r.addLua("return { [\"afar\"] = \"aa\", [\"ari\"] = \"aac\" }");
    try std.testing.expectEqualStrings("ari", r.resolve("ari").?.code);
    try std.testing.expectEqualStrings("Arikara", r.resolve("ari").?.heading);
    try std.testing.expectEqualStrings("aac", r.resolveCanonicalName("ari").?.code);
    try std.testing.expectEqualStrings("ari", r.resolveCanonicalName("ari").?.heading);
    try std.testing.expect(r.resolveStrong("ari") == null);
    try std.testing.expect(r.resolveTrusted("ari") == null);
    try std.testing.expect(r.resolveSourceTrusted("ari") == null);
    try std.testing.expectEqualStrings("aa", r.resolveStrong("afar").?.code);
    try std.testing.expectEqualStrings("hu", r.resolveTrusted("magyar").?.code);
    // A conflicting source declaration is retained as ambiguous, never last-wins.
    try r.addLua("return { [\"ari\"] = \"aa\" }");
    try std.testing.expect(r.resolveCanonicalName("ari") == null);
    try std.testing.expect(r.resolveTrusted("ari") == null);
    try std.testing.expectEqualStrings("ari", r.resolve("ari").?.code);
}

test "canonical language forwarding requires one literal global require return" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "return require [[Modul:ziman/canonical names]]", "return require('Module:Names')", "-- exact forwarding\nreturn require(\"Module:Names\")" }) |source| {
        const target = (try canonicalNameForwardTarget(a, source)).?; defer a.free(target);
        try std.testing.expect(std.mem.startsWith(u8, target, "Modul"));
    }
    for ([_][]const u8{ "local require = function() return {} end; return require('Module:Names')", "return require(name)", "return require('Module:' .. name)", "return require('Module:Names'), 1", "side_effect(); return require('Module:Names')", "return mw.loadData('Module:Names')", "return { [\"English\"] = \"en\" }" }) |source| {
        try std.testing.expect((try canonicalNameForwardTarget(a, source)) == null);
    }
}


test "competing source canonical names never choose an owner in either declaration order" {
    for ([_]bool{ false, true }) |reverse| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv("# mediawiki\nen\tEnglish\nfr\tFrench\n");
        const first = if (reverse) "fr" else "en";
        const second = if (reverse) "en" else "fr";
        try r.addStrongCanonical("Shared", first);
        try r.addStrongCanonical("Shared", second);
        try std.testing.expect(r.resolveCanonicalName("Shared") == null);
        try std.testing.expect(r.resolveStrong("Shared") == null);
        try std.testing.expect(r.resolveTrusted("Shared") == null);
        try std.testing.expect(r.resolve("Shared") == null);
        try std.testing.expect(r.isLanguageBoundary("Shared"));
        try std.testing.expectEqualStrings("en", r.resolve("en").?.code);
        try std.testing.expectEqualStrings("fr", r.resolve("fr").?.code);
        try r.addStrongCanonical("Shared", first);
        try std.testing.expect(r.resolveStrong("Shared") == null);
    }
}

/// A source-equivalent default language-section formatter. This token grants
/// only the physical L2 classification role, not an ordinary name alias.
pub const SourceSectionFormatter = struct { prefix: []const u8 };

pub fn proveSourceSectionFormatter(a: std.mem.Allocator, provider: []const u8, links: []const u8) !?SourceSectionFormatter {
    return proveSourceSectionFormatterWithNamespaces(a, provider, links, null);
}

pub fn proveSourceSectionFormatterWithNamespaces(a: std.mem.Allocator, provider: []const u8, links: []const u8, namespaces: ?*const namespace_registry.Registry) !?SourceSectionFormatter {
    if (!try positionalFullLanguageProviderProof(a, provider, namespaces) or links.len > 256 * 1024) return null;
    var actual = lua_parser.parse(a, links) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer actual.deinit();
    var expected = try lua_parser.parse(a, SourceSectionFormatterSchema.links);
    defer expected.deinit();
    var matched: u3 = 0;
    for (actual.body) |statement| {
        var selected = false;
        for (expected.body, 0..) |contract, i| {
            const same_binding = switch (contract.*) {
                .local_function => |f| statement.* == .local_function and std.mem.eql(u8, statement.local_function.name, f.name),
                .local_assign => |v| statement.* == .local_assign and statement.local_assign.names.len == 1 and
                    std.mem.eql(u8, statement.local_assign.names[0], v.names[0]),
                else => unreachable,
            };
            if (!same_binding) continue;
            const bit = @as(u3, 1) << @as(u2, @intCast(i));
            if (matched & bit != 0 or !PositionalProviderContract.eq(lua_parser.Stmt, statement.*, contract.*)) return null;
            matched |= bit;
            selected = true;
            break;
        }
        if (!selected and !sectionFormatterSafe(lua_parser.Stmt, statement.*, 0)) return null;
    }
    return if (matched == 0b111) .{ .prefix = "Bahasa " } else null;
}

fn sectionFormatterBinding(name: []const u8) bool {
    return std.mem.eql(u8, name, "make_link") or std.mem.eql(u8, name, "anchor_encode") or
        std.mem.eql(u8, name, "memoize_module") or PositionalProviderContract.environment(name);
}

// The complete formatter and lazy anchor helper above are matched as units.
// No other declaration or write may replace those lexical bindings; environment
// escape APIs are excluded. Unrelated module functions are not executed here.
fn sectionFormatterSafe(comptime T: type, value: T, depth: usize) bool {
    if (depth > 256) return false;
    if (T == lua_parser.Span) return true;
    if (T == lua_parser.LValue) switch (value) {
        .name => |name| if (sectionFormatterBinding(name)) return false,
        .index => {},
    };
    if (T == lua_parser.Expr) if (value == .name and PositionalProviderContract.environment(value.name.value)) return false;
    if (T == lua_parser.Stmt) switch (value) {
        .local_assign => |v| for (v.names) |name| { if (sectionFormatterBinding(name)) return false; },
        .local_function => |v| if (sectionFormatterBinding(v.name)) return false,
        .numeric_for => |v| if (sectionFormatterBinding(v.name)) return false,
        .generic_for => |v| for (v.names) |name| { if (sectionFormatterBinding(name)) return false; },
        else => {},
    };
    if (T == lua_parser.FunctionExpr) for (value.params) |name| { if (sectionFormatterBinding(name)) return false; };
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                if (!sectionFormatterSafe(@TypeOf(@field(value, name)), @field(value, name), depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => blk: {
            inline for (@typeInfo(T).@"union".field_names) |name| {
                if (std.meta.activeTag(value) == @field(std.meta.Tag(T), name))
                    break :blk sectionFormatterSafe(@TypeOf(@field(value, name)), @field(value, name), depth + 1);
            }
            unreachable;
        },
        .pointer => |p| switch (p.size) {
            .one => sectionFormatterSafe(p.child, value.*, depth + 1),
            .slice => blk: {
                if (p.child == u8) break :blk true;
                for (value) |item| if (!sectionFormatterSafe(p.child, item, depth + 1)) break :blk false;
                break :blk true;
            },
            else => @compileError("unsupported formatter AST pointer"),
        },
        .optional => |o| if (value) |item| sectionFormatterSafe(o.child, item, depth + 1) else true,
        .bool, .int, .@"enum" => true,
        else => @compileError("unsupported formatter AST value"),
    };
}

fn positionalFullLanguageProviderProof(a: std.mem.Allocator, source: []const u8, namespaces: ?*const namespace_registry.Registry) !bool {
    if (source.len > 256 * 1024) return false;
    var actual = lua_parser.parse(a, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer actual.deinit();
    const schema = try std.mem.replaceOwned(u8, a, PositionalProviderSchema.source, "return export", SourceSectionFormatterSchema.full_name ++ "\n" ++ SourceSectionFormatterSchema.unrelated_cache ++ "\nreturn export");
    defer a.free(schema);
    var expected = try lua_parser.parse(a, schema);
    defer expected.deinit();
    var localized = try localizedProviderSelector(a, namespaces);
    defer if (localized) |*chunk| chunk.deinit();
    var sequential = try sequentialFinalizerContract(a);
    defer sequential.deinit();
    var proof = PositionalProviderContract{ .expected = expected.body, .sequential_finalizer = sequential.body, .localized_selector = if (localized) |chunk| chunk.body else &.{}, .full_name_contract = true };
    if (!proof.block(actual.body, 0, true)) return false;
    return proof.export_init == 1 and proof.language_init == 1 and proof.export_return == 1 and
        proof.getter == 1 and proof.selector == 1 and proof.finalizer == 1 and proof.constructor == 1 and
        proof.full_object == 1 and proof.full_code == 1 and proof.full_name == 1 and proof.full_unrelated_cache == 1 and
        proof.dependencies == 0b1111111 and proof.libraries == 0b11;
}

const SourceSectionFormatterSchema = struct {
    const links =
        "local memoize_module = \"Module:memoize\"\n" ++
        "local function anchor_encode(...)\n" ++
        "\tanchor_encode = require(memoize_module)(mw.uri.anchorEncode, true)\n" ++
        "\treturn anchor_encode(...)\n" ++
        "end\n" ++
        "local function make_link(link, lang, sc, id, isolated, cats, no_alt_ast, plain)\n" ++
        "\t-- Convert percent encoding to plaintext.\n" ++
        "\tlink.target = link.target and decode_uri(link.target, \"PATH\")\n" ++
        "\tlink.fragment = link.fragment and decode_uri(link.fragment, \"PATH\")\n" ++
        "\n" ++
        "\t-- Find fragments (if one isn't already set).\n" ++
        "\t-- Prevents {{l|en|word#Etymology 2|word}} from linking to [[word#Etymology 2#English]].\n" ++
        "\t-- # can be escaped as \\#.\n" ++
        "\tif link.target and link.fragment == nil then\n" ++
        "\t\tlink.target, link.fragment = get_fragment(link.target)\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- Process the target\n" ++
        "\tlocal auto_display, escaped\n" ++
        "\tlink.target, auto_display, escaped = export.get_link_page_with_auto_display(link.target, lang, sc, plain)\n" ++
        "\n" ++
        "\t-- Create a default display form.\n" ++
        "\t-- If the target is \"\" then it's a link like [[#English]], which refers to the current page.\n" ++
        "\tif auto_display == \"\" then\n" ++
        "\t\tauto_display = (m_headword_data or get_headword_data()).pagename\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- If the display is the target and the reconstruction * has been escaped, remove the escaping backslash.\n" ++
        "\tif escaped then\n" ++
        "\t\tauto_display = auto_display:gsub(\"\\\\([^\\\\]*%*)\", \"%1\", 1)\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- Process the display form.\n" ++
        "\tif link.display then\n" ++
        "\t\tlocal orig_display = link.display\n" ++
        "\t\tlink.display = lang:makeDisplayText(link.display, sc, true)\n" ++
        "\t\tif cats then\n" ++
        "\t\t\tauto_display = lang:makeDisplayText(auto_display, sc)\n" ++
        "\t\t\t-- If the alt text is the same as what would have been automatically generated, then the alt parameter is\n" ++
        "\t\t\t-- redundant (e.g. {{l|en|foo|foo}}, {{l|en|w:foo|foo}}, but not {{l|en|w:foo|w:foo}}). If they're\n" ++
        "\t\t\t-- different, but the alt text could have been entered as the term parameter without it affecting the target\n" ++
        "\t\t\t-- page, then the target parameter is redundant (e.g. {{l|ru|фу|фу́}}). If `no_alt_ast` is true, use pcall\n" ++
        "\t\t\t-- to catch the error which will be thrown if this is a reconstructed lang and the alt text doesn't have *.\n" ++
        "\t\t\tif link.display == auto_display then\n" ++
        "\t\t\t\tinsert(cats, \"Pautan dengan parameter alt lewah bahasa \" .. lang:getFullName())\n" ++
        "\t\t\telse\n" ++
        "\t\t\t\tlocal ok, check\n" ++
        "\t\t\t\tif no_alt_ast then\n" ++
        "\t\t\t\t\tok, check = pcall(export.get_link_page, orig_display, lang, sc, plain)\n" ++
        "\t\t\t\telse\n" ++
        "\t\t\t\t\tok = true\n" ++
        "\t\t\t\t\tcheck = export.get_link_page(orig_display, lang, sc, plain)\n" ++
        "\t\t\t\tend\n" ++
        "\t\t\t\tif ok and link.target == check then\n" ++
        "\t\t\t\t\tinsert(cats, \"Pautan dengan parameter sasaran lewah bahasa \" .. lang:getFullName())\n" ++
        "\t\t\t\tend\n" ++
        "\t\t\tend\n" ++
        "\t\tend\n" ++
        "\telse\n" ++
        "\t\tlink.display = lang:makeDisplayText(auto_display, sc)\n" ++
        "\tend\n" ++
        "\n" ++
        "\tif not link.target then\n" ++
        "\t\treturn link.display\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- If the target is the same as the current page, there is no sense id\n" ++
        "\t-- and either the language code is \"und\" or the current L2 is the current\n" ++
        "\t-- language then return a \"self-link\" like the software does.\n" ++
        "\tif link.target == get_current_title().prefixedText then\n" ++
        "\t\tlocal fragment, current_L2 = link.fragment, get_current_L2()\n" ++
        "\t\tif (\n" ++
        "\t\t\t\tfragment and fragment == current_L2 or\n" ++
        "\t\t\t\tnot (id or fragment) and (lang:getFullCode() == \"und\" or lang:getFullName() == current_L2)\n" ++
        "\t\t\t) then\n" ++
        "\t\t\treturn tostring(mw.html.create(\"strong\")\n" ++
        "\t\t\t\t:addClass(\"selflink\")\n" ++
        "\t\t\t\t:wikitext(link.display))\n" ++
        "\t\tend\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- Add fragment. Do not add a section link to \"Undetermined\", as such sections do not exist and are invalid.\n" ++
        "\t-- TabbedLanguages handles links without a section by linking to the \"last visited\" section, but adding\n" ++
        "\t-- \"Undetermined\" would break that feature. For localized prefixes that make syntax error, please use the\n" ++
        "\t-- format: [\"xyz\"] = true.\n" ++
        "\tlocal prefix = link.target:match(\"^:*([^:]+):\")\n" ++
        "\tprefix = prefix and ulower(prefix)\n" ++
        "\n" ++
        "\tif prefix ~= \"category\" and not (prefix and load_data(\"Module:data/interwikis\")[prefix]) then\n" ++
        "\t\tif (link.fragment or link.target:sub(-1) == \"#\") and not plain then\n" ++
        "\t\t\ttrack(\"fragment\", lang:getFullCode())\n" ++
        "\t\t\tif cats then\n" ++
        "\t\t\t\tinsert(cats, \"Pautan dengan serpihan manual bahasa \" .. lang:getFullName())\n" ++
        "\t\t\tend\n" ++
        "\t\tend\n" ++
        "\n" ++
        "\t\tif not link.fragment then\n" ++
        "\t\t\tif id then\n" ++
        "\t\t\t\tlink.fragment = lang:getFullCode() == \"und\" and anchor_encode(id) or language_anchor(lang, id)\n" ++
        "\t\t\telseif lang:getFullCode() ~= \"und\" and not (link.target:match(\"^Lampiran:\") or link.target:match(\"^Rekonstruksi:\")) then\n" ++
        "\t\t\t\tlink.fragment = anchor_encode(\"Bahasa \" .. lang:getFullName())\n" ++
        "\t\t\tend\n" ++
        "\t\tend\n" ++
        "\tend\n" ++
        "\n" ++
        "\t-- Put inward-facing square brackets around a link to isolated spacing character(s).\n" ++
        "\tif isolated and link.display[1] and not umatch(decode_entities(link.display), \"%S\") then\n" ++
        "\t\tlink.display = \"&#x5D;\" .. link.display .. \"&#x5B;\"\n" ++
        "\tend\n" ++
        "\n" ++
        "\tlink.target = link.target:gsub(\"^(:?)(.*)\", function(m1, m2)\n" ++
        "\t\treturn m1 .. encode_entities(m2, \"#%&+/:<=>@[\\\\]_{|}\")\n" ++
        "\tend)\n" ++
        "\n" ++
        "\tlink.fragment = link.fragment and encode_entities(remove_formatting(link.fragment), \"#%&+/:<=>@[\\\\]_{|}\")\n" ++
        "\treturn \"[[\" ..\n" ++
        "\tlink.target:gsub(\"^[^:]\", \":%0\") .. (link.fragment and \"#\" .. link.fragment or \"\") .. \"|\" .. link.display .. \"]]\"\n" ++
        "end"
    ;
    const full_name =
        "function Language:getFull()\n" ++
        "\tlocal full = self._fullObject\n" ++
        "\tif full == nil then\n" ++
        "\t\tfull = self:getFullCode()\n" ++
        "\t\tfull = full == self._code and self or get_by_code(full)\n" ++
        "\t\tself._fullObject = full\n" ++
        "\tend\n" ++
        "\treturn full\n" ++
        "end\n" ++
        "function Language:getFullCode()\n" ++
        "\treturn self._fullCode or self._code\n" ++
        "end\n" ++
        "function Language:getFullName()\n" ++
        "\tlocal full = self._fullName\n" ++
        "\tif full == nil then\n" ++
        "\t\tfull = self:getFull():getCanonicalName()\n" ++
        "\t\tself._fullName = full\n" ++
        "\tend\n" ++
        "\treturn full\n" ++
        "end"
    ;
    const unrelated_cache =
        "do\n" ++
        "\tlocal function handle_language_spec(self, spec, sc)\n" ++
        "\t\tlocal ret = self[\"_\" .. spec]\n" ++
        "\t\tif ret == nil then\n" ++
        "\t\t\tret = self._data[spec]\n" ++
        "\t\t\tif type(ret) == \"string\" then\n" ++
        "\t\t\t\tret = list_to_set(split(ret, \",\", true, true))\n" ++
        "\t\t\tend\n" ++
        "\t\t\tself[\"_\" .. spec] = ret\n" ++
        "\t\tend\n" ++
        "\t\tif type(ret) == \"table\" then\n" ++
        "\t\t\tret = ret[sc:getCode()]\n" ++
        "\t\tend\n" ++
        "\t\treturn not not ret\n" ++
        "\tend\n" ++
        "\n" ++
        "\tfunction Language:overrideManualTranslit(sc)\n" ++
        "\t\treturn handle_language_spec(self, \"override_translit\", sc)\n" ++
        "\tend\n" ++
        "\n" ++
        "\tfunction Language:link_tr(sc)\n" ++
        "\t\treturn handle_language_spec(self, \"link_tr\", sc)\n" ++
        "\tend\n" ++
        "end"
    ;
};

test "source L2 formatter requires matched full-name provider canonical identity and conflict-free literal data" {
    const provider = @embedFile("testdata/ms-section-formatter/languages.lua");
    const links = @embedFile("testdata/ms-section-formatter/links.lua");
    const data = @embedFile("testdata/ms-section-formatter/data2.lua");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try Registry.provePositionalLanguageProvider(a, PositionalProviderSchema.source) != null);
    const namespace_bytes = @embedFile("testdata/ms-february/namespace-registry.tsv");
    var ns = try namespace_registry.Registry.init(a, namespace_bytes); defer ns.deinit();
    // The localized source needs independent namespace authority; canonical-only
    // callers still refuse it. A different selected local name cannot authorize it.
    try std.testing.expect(try proveSourceSectionFormatter(a, provider, links) == null);
    try std.testing.expect(try Registry.provePositionalLanguageProvider(a, provider) == null);
    const wrong_bytes = try std.mem.replaceOwned(u8, a, namespace_bytes, "828\tModul\tModule\t", "828\tOther\tModule\t");
    var wrong_ns = try namespace_registry.Registry.init(a, wrong_bytes); defer wrong_ns.deinit();
    try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, provider, links, &wrong_ns) == null);
    try std.testing.expect(try Registry.provePositionalLanguageProviderWithNamespaces(a, provider, &wrong_ns) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provider, "return \"Modul:\" .. ("));
    const canonical_provider = try std.mem.replaceOwned(u8, a, provider, "return \"Modul:\" .. (", "return \"Module:\" .. (");
    try std.testing.expect(try proveSourceSectionFormatter(a, canonical_provider, links) != null);
    try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, canonical_provider, links, &ns) != null);
    for ([_][2][]const u8{
        .{ "return \"Modul:\" .. (", "return \"Other:\" .. (" },
        .{ "\"languages/data/2\"", "\"languages/data/other\"" },
        .{ "name = self._data[1]", "name = self._data[2]" },
        .{ "entity.family = nil", "entity[1] = nil" },
        .{ "entity.parent, entity[3] = entity[3], entity.family", "entity.parent, entity[1] = entity[3], entity.family" },
        .{ "entity.parent, entity[3] = entity[3], entity.family", "entity.parent, entity[3] = 'fr', entity.family" },
    }) |change| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provider, change[0]));
        const modified = try std.mem.replaceOwned(u8, a, provider, change[0], change[1]);
        try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, modified, links, &ns) == null);
        try std.testing.expect(try Registry.provePositionalLanguageProviderWithNamespaces(a, modified, &ns) == null);
    }
    const formatter = (try proveSourceSectionFormatterWithNamespaces(a, provider, links, &ns)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Bahasa ", formatter.prefix);
    const positional = (try Registry.provePositionalLanguageProviderWithNamespaces(a, provider, &ns)) orelse return error.TestUnexpectedResult;
    var actual = Registry.empty(a); defer actual.deinit();
    try actual.addTsv("# mediawiki\nen\tInggeris\tEnglish\nfr\tPerancis\n");
    try actual.addStrongCanonical("Inggeris", "en");
    try actual.addPositionalLanguageDataLua(data, positional, "languages/data/2");
    try std.testing.expect(actual.sourceSectionHeading("Bahasa Inggeris") == null);
    try actual.registerSourceSectionFormatter(formatter);
    const owner = actual.sourceSectionHeading("Bahasa Inggeris").?.owner orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("en", owner.code);
    try std.testing.expectEqualStrings("Inggeris", owner.heading);
    try std.testing.expect(actual.resolve("Bahasa Inggeris") == null);
    try std.testing.expect(actual.resolveTrusted("Bahasa Inggeris") == null);
    try std.testing.expect(actual.sourceSectionHeading("Inggeris") == null);
    try std.testing.expect(actual.sourceSectionHeading("Bahasa Unknown").?.owner == null);
    try std.testing.expect(actual.sourceSectionHeading("Bahasa ").?.owner == null);
    // An installed or trusted ordinary alias is not source canonical authority.
    var weak = Registry.empty(a); defer weak.deinit();
    try weak.addTsv("# mediawiki\nen\tInggeris\n");
    try weak.addPositionalLanguageDataLua(data, positional, "languages/data/2");
    try weak.registerSourceSectionFormatter(formatter);
    try std.testing.expect(weak.resolveTrusted("Inggeris") != null);
    try std.testing.expect(weak.resolveCanonicalName("Inggeris") == null);
    try std.testing.expect(weak.sourceSectionHeading("Bahasa Inggeris").?.owner == null);
    for ([_][]const u8{
        "local m={} m['en']={'Inggeris',parent='fr'} return require('Module:languages').finalizeData(m,'language')",
        "local m={} m['en']={'Inggeris',['parent']='fr'} return require('Module:languages').finalizeData(m,'language')",
        "local m={} m['en']={'Other'} return require('Module:languages').finalizeData(m,'language')",
    }) |source| {
        var r = Registry.empty(a); defer r.deinit();
        try r.addTsv("# mediawiki\nen\tInggeris\nfr\tPerancis\n");
        try r.addStrongCanonical("Inggeris", "en");
        try r.addPositionalLanguageDataLua(source, positional, "languages/data/2");
        try r.registerSourceSectionFormatter(formatter);
        try std.testing.expect(r.sourceSectionHeading("Bahasa Inggeris").?.owner == null);
        // A later matching row cannot erase a parent/conflicting-name record.
        try r.addPositionalLanguageDataLua(data, positional, "languages/data/2");
        try std.testing.expect(r.sourceSectionHeading("Bahasa Inggeris").?.owner == null);
    }
    // Both formatted and canonical source labels independently veto collisions.
    for ([_][]const u8{ "Bahasa Inggeris", "Inggeris" }) |label| {
        var r = Registry.empty(a); defer r.deinit();
        try r.addTsv("# mediawiki\nen\tInggeris\nfr\tPerancis\n");
        try r.addStrongCanonical("Inggeris", "en");
        try r.addPositionalLanguageDataLua(data, positional, "languages/data/2");
        try r.registerSourceSectionFormatter(formatter);
        try r.addStrongCanonical(label, "fr");
        try std.testing.expect(r.sourceSectionHeading("Bahasa Inggeris").?.owner == null);
    }
    for ([_][2][]const u8{
        .{ "return self._fullCode or self._code", "return 'fr'" },
        .{ "full = self:getFull():getCanonicalName()", "full = 'Other'" },
        .{ "full = full == self._code and self or get_by_code(full)", "full = self" },
        .{ "\nreturn export", "\nLanguage.getFullName = function() return 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate() self._fullName = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate(key) self[key] = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate(key) local alias = self; alias[key] = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate(key) local alias = (self); local other = alias; other[key] = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate(key) local alias = self or {}; alias[key] = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate(key) local box = {self}; local alias = box[1]; alias[key] = 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nfunction Language:mutate() rawset(self, '_fullName', 'Other') end\nreturn export" },
        .{ "handle_language_spec(self, \"link_tr\", sc)", "handle_language_spec(self, \"fullName\", sc)" },
        .{ "\nreturn export", "\nlocal escaped = Language\nreturn export" },
    }) |change| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, provider, change[0]));
        const modified = try std.mem.replaceOwned(u8, a, provider, change[0], change[1]);
        try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, modified, links, &ns) == null);
    }
    for ([_][2][]const u8{
        .{ "anchor_encode(\"Bahasa \" .. lang:getFullName())", "anchor_encode(\"Other \" .. lang:getFullName())" },
        .{ "anchor_encode(\"Bahasa \" .. lang:getFullName())", "anchor_encode(\"Bahasa \" .. lang:getCanonicalName())" },
        .{ "local memoize_module = \"Module:memoize\"", "local memoize_module = \"Module:other\"" },
        .{ "\nreturn export", "\nmake_link = function() return '' end\nreturn export" },
        .{ "\nreturn export", "\nanchor_encode = function(x) return 'Other' end\nreturn export" },
        .{ "\nreturn export", "\nlocal memoize_module = 'Other'\nreturn export" },
        .{ "\nreturn export", "\nlocal d = debug\nreturn export" },
    }) |change| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, links, change[0]));
        const modified = try std.mem.replaceOwned(u8, a, links, change[0], change[1]);
        try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, provider, modified, &ns) == null);
    }
    try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, provider, "local function make_link() end", &ns) == null);
    const safe_alias = try std.mem.replaceOwned(u8, a, provider, "\nreturn export", "\nfunction Language:readAlias() local alias = self; return alias:getCode() end\nreturn export");
    try std.testing.expect(try proveSourceSectionFormatterWithNamespaces(a, safe_alias, links, &ns) != null);
}


test "captured preferred case retains trust only across same owner strong promotion" {
    var same = Registry.empty(std.testing.allocator); defer same.deinit();
    try same.addTsv("# content-language\thu\n# mediawiki\nhu\tmagyar\tMagyar\thu\tHungarian\thun\nen\tangol\tAngol\tEnglish\ten\teng\n");
    try same.addLua("return { [\"angol\"]=\"en\" }");
    try same.addLua("return { [\"angol\"]=\"en\" }");
    const trusted = same.resolveTrusted("Angol") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("en", trusted.code);
    try std.testing.expectEqualStrings("angol", trusted.heading);
    try std.testing.expectEqualStrings("en", (same.resolveSourceTrusted("Angol") orelse return error.TestUnexpectedResult).code);
    try std.testing.expect(same.resolveStrong("Angol") == null);
    try std.testing.expect(same.resolveTrusted("ANGOL") == null and same.resolveTrusted("English") == null);

    var absent = Registry.empty(std.testing.allocator); defer absent.deinit();
    try absent.addTsv("# mediawiki\nen\tangol\n");
    try absent.addLua("return { [\"angol\"]=\"en\" }");
    try std.testing.expect(absent.resolveTrusted("Angol") == null);

    var foreign = Registry.empty(std.testing.allocator); defer foreign.deinit();
    try foreign.addTsv("# mediawiki\nen\tangol\tAngol\nfr\tFrench\n");
    try foreign.addLua("return { [\"angol\"]=\"fr\" }");
    try std.testing.expect(foreign.resolveTrusted("Angol") == null);
    try std.testing.expect(!foreign.trusted_names.contains("angol"));

    var ambiguous = Registry.empty(std.testing.allocator); defer ambiguous.deinit();
    try ambiguous.addTsv("# mediawiki\nen\tangol\tAngol\nfr\tFrench\n");
    try ambiguous.addLua("return { [\"angol\"]=\"en\" }");
    try ambiguous.addLua("return { [\"angol\"]=\"fr\" }");
    try std.testing.expect(ambiguous.resolveTrusted("Angol") == null);
    try std.testing.expect(ambiguous.resolveStrong("angol") == null);
}

const SourceSectionNameRoleTest = struct {
    const provider = @embedFile("testdata/th-kip-role/module-36388.lua");
    const links = @embedFile("testdata/th-kip-role/module-36044.lua");
    const language_like = @embedFile("testdata/th-kip-role/module-272817.lua");
    const language_data = @embedFile("testdata/th-kip-role/module-324680.lua");
    const finish = "\nreturn require(\"Module:languages\").finalizeData(m, \"language\")";
    fn proof() !Registry.SourceSectionNameRole {
        return Registry.proveSourceSectionNameRole(provider, links, language_like, language_data) orelse error.TestUnexpectedResult;
    }
    fn registry(a: std.mem.Allocator) !Registry {
        var out = Registry.empty(a);
        errdefer out.deinit();
        // The declared content code must have its captured row even though the
        // section-role controls below exercise independently installed owners.
        try out.addTsv("# content-language\tth\n# mediawiki\nth\tไทย\tth\tThai\ttha\nen\tอังกฤษ\nnl\tดัตช์\nde\tเยอรมัน\nfr\tฝรั่งเศส\nit\tอิตาลี\nes\tสเปน\npt\tโปรตุเกส\nda\tภาษาเดนมาร์ก\ntr\tภาษณ์ตุรกี\nno\tนอร์เวย์\npl\tโปแลนด์\nru\tรัสเซีย\nar\tอาหรับ\nfi\tฟินแลนด์\nycr\tครีโอล\n");
        try out.addLua("return { [\"อังกฤษ\"]=\"en\", [\"ดัตช์\"]=\"nl\", [\"เยอรมัน\"]=\"de\", [\"ฝรั่งเศส\"]=\"fr\", [\"อิตาลี\"]=\"it\", [\"สเปน\"]=\"es\", [\"โปรตุเกส\"]=\"pt\", [\"ภาษาเดนมาร์ก\"]=\"da\", [\"ภาษณ์ตุรกี\"]=\"tr\", [\"นอร์เวย์\"]=\"no\", [\"โปแลนด์\"]=\"pl\", [\"รัสเซีย\"]=\"ru\", [\"อาหรับ\"]=\"ar\", [\"ฟินแลนด์\"]=\"fi\", [\"ครีโอล\"]=\"ycr\" }");
        return out;
    }
};

test "section name declaration role requires all exact reviewed provider helper bodies" {
    const F = SourceSectionNameRoleTest;
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.provider, F.links, F.language_like, F.language_data) != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const changed_provider = try std.mem.concat(a, u8, &.{ F.provider, "\n" });
    const changed_links = try std.mem.replaceOwned(u8, a, F.links, "anchor_encode(lang:getCategoryName())", "anchor_encode(lang:getFullName())");
    const changed_types = try std.mem.replaceOwned(u8, a, F.language_like, "local types = self:getTypes()", "local types = {} ");
    try std.testing.expect(!std.mem.eql(u8, changed_links, F.links));
    try std.testing.expect(!std.mem.eql(u8, changed_types, F.language_like));
    try std.testing.expect(Registry.proveSourceSectionNameRole(changed_provider, F.links, F.language_like, F.language_data) == null);
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.provider, changed_links, F.language_like, F.language_data) == null);
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.provider, F.links, changed_types, F.language_data) == null);
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.links, F.provider, F.language_like, F.language_data) == null);
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.provider, F.links, "", F.language_data) == null);
    const changed_aliases = try std.mem.replaceOwned(u8, a, F.language_data, "[\"EL.\"] = \"la-ecc\"", "[\"en\"] = \"nl\"");
    try std.testing.expect(!std.mem.eql(u8, changed_aliases, F.language_data));
    try std.testing.expect(Registry.proveSourceSectionNameRole(F.provider, F.links, F.language_like, changed_aliases) == null);
}

test "section name role admits proved full rows and preserves canonical prefixed and nonfull labels" {
    const F = SourceSectionNameRoleTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var r = try F.registry(a); defer r.deinit();
    try r.addTsv("# mediawiki\nsv\tunsafe<label>\n");
    try r.addLua("return { [\"unsafe<label>\"] = \"sv\" }");
    const before_heading = (r.resolve("en") orelse return error.TestUnexpectedResult).heading;
    const data =
        \\local m = {}
        \\m["en"] = {"อังกฤษ", 1860, "gmw-ang", metadata = {"literal", 1, {flag = true}}}
        \\m["nl"] = {"ดัตช์", 7411, "gmw-frk", type = "regular"}
        \\m["de"] = {"เยอรมัน", 188, "gmw", parent = "en"}
        \\m["fr"] = {"ฝรั่งเศส", 150, "roa", type = "etymology-only"}
        \\m["it"] = {"อิตาลี", 652, "roa", type = unknown}
        \\m["es"] = {"สเปน", 1321, "roa", getCategoryName = function() return "other" end}
        \\m["pt"] = {"โปรตุเกส", 5146, "qfa-sub"}
        \\m["da"] = {"ภาษาเดนมาร์ก", 9035, "gmw"}
        \\m["tr"] = {"ภาษณ์ตุรกี", 256, "trk"}
        \\m["no"] = {"นอร์เวย์", 9043, "gmw", type = "reconstructed"}
        \\m["pl"] = {"โปแลนด์", 809, "zlw", _fullCode = "other"}
        \\m["ru"] = {"Russian wrong", 7737, "zle"}
        \\m["ar"] = {"อาหรับ", 13955, "sem", parent = nil}
        \\m["fi"] = {"ฟินแลนด์", 1412, "urj", type = nil}
        \\m["sv"] = {"unsafe<label>", 9027, "gmw"}
    ;
    try r.addSourceSectionLanguageDataLua(data ++ F.finish, try F.proof(), "languages/data/2");
    try std.testing.expect(r.resolveTrusted("ภาษาunsafe<label>") == null);
    try std.testing.expectEqualStrings("en", (r.resolveTrusted("ภาษาอังกฤษ") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings("nl", (r.resolveTrusted("ภาษาดัตช์") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings(before_heading, (r.resolve("en") orelse return error.TestUnexpectedResult).heading);
    try std.testing.expectEqualStrings("en", (r.resolveStrong("อังกฤษ") orelse return error.TestUnexpectedResult).code);
    try std.testing.expect(r.resolveStrong("ภาษาอังกฤษ") == null);
    try std.testing.expectEqualStrings("da", (r.resolveTrusted("ภาษาเดนมาร์ก") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings("tr", (r.resolveTrusted("ภาษณ์ตุรกี") orelse return error.TestUnexpectedResult).code);
    for ([_][]const u8{ "ภาษาเยอรมัน", "ภาษาฝรั่งเศส", "ภาษาอิตาลี", "ภาษาสเปน", "ภาษาโปรตุเกส", "ภาษานอร์เวย์", "ภาษาโปแลนด์", "ภาษาRussian wrong", "ภาษาอาหรับ", "ภาษาฟินแลนด์", "ภาษาภาษาเดนมาร์ก", "ภาษาภาษณ์ตุรกี", "ภาษาคำนาม", "ภาษาEnglish", "ภาษาอังกฤษเพิ่มเติม" }) |unknown|
        try std.testing.expect(r.resolveTrusted(unknown) == null);
    try r.addSourceSectionLanguageDataLua("local m = {}\nm[\"ycr\"] = {\"ครีโอล\", 1, \"crp\"}" ++ F.finish, try F.proof(), "languages/data/3/y");
    try std.testing.expectEqualStrings("ycr", (r.resolveTrusted("ภาษาครีโอล") orelse return error.TestUnexpectedResult).code);
}

test "section name declarations keep ambiguity sticky and refuse unproved data exports" {
    const F = SourceSectionNameRoleTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var checkpoint: []const u8 = "sticky local conflict";
    errdefer std.debug.print("section-name ambiguity checkpoint={s}\n", .{checkpoint});
    const data = "local m = {}\nm[\"en\"] = {\"อังกฤษ\", 1860, \"gmw-ang\"}";
    var collision = try F.registry(a); defer collision.deinit();
    try collision.addLocalAlias("ภาษาอังกฤษ", "nl");
    try collision.addSourceSectionLanguageDataLua(data ++ F.finish, try F.proof(), "languages/data/2");
    try std.testing.expect(collision.resolveTrusted("ภาษาอังกฤษ") == null);
    try collision.addLocalAlias("ภาษาอังกฤษ", "en");
    try std.testing.expect(collision.resolveTrusted("ภาษาอังกฤษ") == null);
    checkpoint = "independent Strong canonical owner";
    var exact_owner = try F.registry(a); defer exact_owner.deinit();
    try exact_owner.addLua("return { [\"ภาษาอังกฤษ\"] = \"nl\" }");
    try exact_owner.addSourceSectionLanguageDataLua(data ++ F.finish, try F.proof(), "languages/data/2");
    // A new canonical source name is Strong, not a captured Trusted alias.
    // Its exact owner still outranks the lower-authority section alias.
    try std.testing.expectEqualStrings("nl", (exact_owner.resolveStrong("ภาษาอังกฤษ") orelse return error.TestUnexpectedResult).code);
    try std.testing.expect(exact_owner.resolveTrusted("ภาษาอังกฤษ") == null);
    for ([_][]const u8{
        data ++ "\nreturn m",
        data ++ "\nm[\"en\"][1] = \"replacement\"" ++ F.finish,
        data ++ "\nm[\"nl\"] = {\"ดัตช์\", 7411, \"gmw\", poison = (function() m[\"en\"].parent = \"nl\"; return true end)()}" ++ F.finish,
        "local m = {}\nm[\"en\"] = {\"อังกฤษ\", 1860, \"gmw-ang\", [1] = \"other\"}" ++ F.finish,
        "local m = {}\nm[\"en\"] = {\"อังกฤษ\", 1860, \"gmw-ang\"}\nm[\"en\"] = {\"อังกฤษ\", 1860, \"gmw-ang\"}" ++ F.finish,
    }, 0..) |unproved, index| {
        checkpoint = switch (index) {
            0 => "unproved bare export",
            1 => "field-one replacement",
            2 => "foreign row mutation",
            3 => "numeric field override",
            4 => "duplicate row",
            else => unreachable,
        };
        var r = try F.registry(a); defer r.deinit();
        try r.addSourceSectionLanguageDataLua(unproved, try F.proof(), "languages/data/2");
        try std.testing.expect(r.resolveTrusted("ภาษาอังกฤษ") == null);
    }
}


test "section aliases do not overwrite positional full name authority or parent refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const F = SourceSectionNameRoleTest;
    const role = try F.proof();
    const positional = (try Registry.provePositionalLanguageProvider(a, PositionalProviderSchema.source)) orelse return error.TestUnexpectedResult;
    const data = "local m={} m['en']={'อังกฤษ',1860,'gmw-ang'} m['nl']={'ดัตช์',7411,'gmw-frk',parent='en'}" ++ F.finish;
    for ([_]bool{ false, true }) |section_first| {
        var registry = try F.registry(a); defer registry.deinit();
        if (section_first) {
            try registry.addSourceSectionLanguageDataLua(data, role, "languages/data/2");
            try std.testing.expectEqual(@as(usize, 0), registry.source_full_names.count());
            try std.testing.expectEqualStrings("en", (registry.resolveTrusted("ภาษาอังกฤษ") orelse return error.TestUnexpectedResult).code);
        }
        try registry.addPositionalLanguageDataLua(data, positional, "languages/data/2");
        const original_name = (registry.source_full_names.get("en") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("อังกฤษ", original_name);
        try std.testing.expect(registry.source_full_names.contains("nl"));
        try std.testing.expect(registry.source_full_names.get("nl").? == null);
        try registry.addSourceSectionLanguageDataLua(data, role, "languages/data/2");
        try std.testing.expectEqual(@as(usize, 2), registry.source_full_names.count());
        try std.testing.expectEqualStrings(original_name, (registry.source_full_names.get("en") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult);
        try std.testing.expect(registry.source_full_names.get("nl").? == null);
        try std.testing.expectEqualStrings("en", (registry.resolveTrusted("ภาษาอังกฤษ") orelse return error.TestUnexpectedResult).code);
        try std.testing.expectEqualStrings("en", (registry.resolveStrong("อังกฤษ") orelse return error.TestUnexpectedResult).code);
        try std.testing.expect(registry.resolveStrong("ภาษาอังกฤษ") == null);
        try std.testing.expect(registry.resolveTrusted("ภาษาดัตช์") == null);
        const parented = "local m={} m['en']={'อังกฤษ',1860,'gmw-ang',parent='nl'}" ++ F.finish;
        try registry.addPositionalLanguageDataLua(parented, positional, "languages/data/2");
        try std.testing.expect(registry.source_full_names.get("en").? == null);
        try registry.addSourceSectionLanguageDataLua(data, role, "languages/data/2");
        try std.testing.expect(registry.source_full_names.get("en").? == null);
    }
}


test "authored head codes require exact source data role canonical key and immutable owned names" {
    const data = "local m = {}\nm['xag'] = {canonicalName='Aghwan'}\nreturn m";
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv("# content-language\taz\naz\tAzerbaijani\taz\nxag\tAghwan\txag\nen\tEnglish\teng\n");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
    try registry.addLanguageDataLuaForHeadwordRole(data, .canonical_assignments, "languages/data3/x");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
    registry.source_headword_role = true; // Isolated callback capability; loader proves it separately.
    for ([_]?[]const u8{ null, "languages/data2", "languages/data3/a", "other/data3/x" }) |role| {
        try registry.addLanguageDataLuaForHeadwordRole(data, .canonical_assignments, role);
        try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
    }
    const borrowed = try std.testing.allocator.dupe(u8, data);
    try registry.addLanguageDataLuaForHeadwordRole(borrowed, .canonical_assignments, "languages/data3/x");
    @memset(borrowed, 'x'); std.testing.allocator.free(borrowed);
    const owner = registry.sourceHeadwordLanguage("xag") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xag", owner.code);
    try std.testing.expectEqualStrings("Aghwan", owner.heading);
    try std.testing.expect(registry.sourceHeadwordLanguage("Qafqaz albanlarının dili") == null);
    try registry.addLanguageDataLuaForHeadwordRole("local m={} m['eng']={canonicalName='English'} return m", .canonical_assignments, "languages/data3/e");
    try std.testing.expect(registry.sourceHeadwordLanguage("en") == null);
    try std.testing.expect(registry.sourceHeadwordLanguage("eng") == null);
    try registry.addLanguageDataLuaForHeadwordRole("local m={} m['xag']={canonicalName='Other'} return m", .canonical_assignments, "languages/data3/x");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
    try registry.addLanguageDataLuaForHeadwordRole(data, .canonical_assignments, "languages/data3/x");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null); // Sticky disagreement.
}

test "authored head source data does not admit duplicate records or a conflicting canonical owner" {
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv("# content-language\taz\naz\tAzerbaijani\taz\nxag\tAghwan\txag\nen\tEnglish\ten\n");
    registry.source_headword_role = true;
    try registry.addLanguageDataLuaForHeadwordRole("local m={} m['xag']={canonicalName='Aghwan'} m['xag']={canonicalName='Aghwan'} return m", .canonical_assignments, "languages/data3/x");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
    try registry.addLanguageDataLuaForHeadwordRole("local m={} m['xag']={canonicalName='English'} return m", .canonical_assignments, "languages/data3/x");
    try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
}

fn headwordRegistryAllocationControl(a: std.mem.Allocator) !void {
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# content-language\taz\naz\tAzerbaijani\taz\nxag\tAghwan\txag\n");
    registry.source_headword_role = true;
    try registry.addLanguageDataLuaForHeadwordRole("local m={} m['xag']={canonicalName='Aghwan'} return m", .canonical_assignments, "languages/data3/x");
    const owner = registry.sourceHeadwordLanguage("xag") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xag", owner.code);
    try std.testing.expectEqualStrings("Aghwan", owner.heading);
}

test "authored head registry allocation failures preserve owned map cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, headwordRegistryAllocationControl, .{});
}


test "authored head source ownership preserves independent conflict vetoes without global name promotion" {
    const Conflict = enum { boundary, canonical_ambiguous, canonical_other, installed_other, local_other, local_ambiguous, reviewed_other };
    for (std.enums.values(Conflict)) |conflict| {
        var registry = Registry.empty(std.testing.allocator);
        defer registry.deinit();
        try registry.addTsv("# content-language\taz\naz\tAzerbaijani\taz\nxag\tAghwan\txag\nen\tEnglish\ten\n");
        registry.source_headword_role = true;
        try registry.addLanguageDataLuaForHeadwordRole("local m={} m['xag']={canonicalName='Aghwan'} return m", .canonical_assignments, "languages/data3/x");
        const owner = registry.sourceHeadwordLanguage("xag") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("xag", owner.code);
        try std.testing.expectEqualStrings("Aghwan", owner.heading);
        try std.testing.expect(registry.resolveCanonicalName("Aghwan") == null);
        try std.testing.expect(registry.resolveStrong("Aghwan") == null);
        const a = registry.arena.allocator();
        // Isolate each existing conflict channel after an otherwise valid role.
        switch (conflict) {
            .boundary => try registry.language_boundaries.put(a, "Aghwan", {}),
            .canonical_ambiguous => try registry.source_canonical_names.put(a, "Aghwan", null),
            .canonical_other => try registry.source_canonical_names.put(a, "Aghwan", "en"),
            .installed_other => try registry.names.put(a, "Aghwan", "en"),
            .local_other => try registry.local_aliases.put(a, "Aghwan", "en"),
            .local_ambiguous => try registry.local_aliases.put(a, "Aghwan", null),
            .reviewed_other => try registry.reviewed_aliases.put(a, "Aghwan", "en"),
        }
        try std.testing.expect(registry.sourceHeadwordLanguage("xag") == null);
        try std.testing.expect(registry.sourceHeadwordLanguage("Qafqaz albanlarının dili") == null);
    }
}


test "captured TT full profile admits installed first-letter capital without collapsing variety or preferred owner" {
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    const registry = @embedFile("testdata/tt-autonym-capitalization/language-registry.tsv");
    const names = @embedFile("testdata/tt-autonym-capitalization/language-names.tsv");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(registry, &digest, .{});
    try std.testing.expectEqualStrings("35e331bd5ce9b9483bbc8064fbb96afba74e6f610ebe2a8567552d664af3be01", &std.fmt.bytesToHex(digest, .lower));
    std.crypto.hash.sha2.Sha256.hash(names, &digest, .{});
    try std.testing.expectEqualStrings("30a8ccea39f213973921b971aa26284dbb97713b82dfb471c06766043c0d431c", &std.fmt.bytesToHex(digest, .lower));
    try r.addTsv(registry);
    try std.testing.expectEqualStrings("tt-latn", r.resolve("Tatarça").?.code);
    try std.testing.expect(r.resolveTrusted("Tatarça") == null);
    try r.trustAutonymSnapshot(names, "ttwiktionary", "20261001", "tt");
    for ([_][]const u8{ "tatarça", "Tatarça" }) |label| {
        const owner = r.resolveTrusted(label) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("tt-latn", owner.code);
        try std.testing.expectEqualStrings("татарский (латинский алфавит)", owner.heading);
    }
    try std.testing.expectEqualStrings("tt", r.resolveTrusted("татарча / tatarça").?.code);
    try std.testing.expect(r.resolveTrusted("TATARÇA") == null);
    try std.testing.expect(r.resolveTrusted("Tatarça ") == null);
    try std.testing.expect(r.resolveTrusted("Tatarca") == null);
}

test "autonym first-letter capital requires both exact installed aliases and unconflicted complete source authority" {
    const header = "# wikidict-language-names-v1\n# wiki\tttwiktionary\n# dump-date\t20261001\n# content-language\ttt\n";
    const profile = header ++ "C\t-\tsingle\t1\nN\t-\tsingle\ttt-latn\ttatarça\n";
    const normal = "# content-language\ttt\n# mediawiki\ntt\tCombined Tatar\ntt-latn\tLatin Tatar\ttatarça\tTatarça\tTATARÇA\nfr\tFrench\n";
    for ([_][]const u8{
        "# content-language\ttt\ntt\tCombined Tatar\ntt-latn\tLatin Tatar\ttatarça\n", // capital absent
        "# content-language\ttt\ntt\tCombined Tatar\ntt-latn\tLatin Tatar\tTatarça\n", // attested lowercase absent
        "# content-language\ttt\ntt\tCombined Tatar\ntt-latn\tLatin Tatar\ttatarça\nfr\tFrench\tTatarça\n", // different owner
        normal ++ "fr\tFrench\tTatarça\n", // ambiguous installed capital
    }) |registry| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv(registry);
        try r.trustAutonymSnapshot(profile, "ttwiktionary", "20261001", "tt");
        try std.testing.expect(r.resolveTrusted("Tatarça") == null);
    }
    for (0..4) |case| {
        var r = Registry.empty(std.testing.allocator); defer r.deinit();
        try r.addTsv(normal);
        if (case == 0) try r.addLocalAlias("Tatarça", "fr");
        const selected = if (case == 2)
            header ++ "C\t-\tsingle\t2\nN\t-\tsingle\ttt-latn\ttatarça\nN\t-\tsingle\tfr\tTatarça\n"
        else if (case == 3)
            header ++ "C\t-\tsingle\t2\nN\t-\tsingle\ttt-latn\ttatarça\nN\t-\tsingle\tfr\ttatarça\n"
        else profile;
        try r.trustAutonymSnapshot(selected, "ttwiktionary", "20261001", "tt");
        if (case == 1) {
            try std.testing.expect(r.resolveTrusted("Tatarça") != null);
            try r.addLocalAlias("Tatarça", "fr");
        }
        try std.testing.expect(r.resolveTrusted("Tatarça") == null);
        try std.testing.expect(r.resolveTrusted("TATARÇA") == null);
    }
    var r = Registry.empty(std.testing.allocator); defer r.deinit();
    try r.addTsv(normal);
    try std.testing.expectError(error.IncompleteLanguageNameProfile, r.trustAutonymSnapshot(header ++ "C\t-\tsingle\t2\nN\t-\tsingle\ttt-latn\ttatarça\n", "ttwiktionary", "20261001", "tt"));
    try std.testing.expect(r.resolveTrusted("Tatarça") == null);
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(profile, "enwiktionary", "20261001", "tt"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(profile, "ttwiktionary", "20261002", "tt"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, r.trustAutonymSnapshot(profile, "ttwiktionary", "20261001", "en"));
    try std.testing.expect(r.resolveTrusted("Tatarça") == null);
}

test "nom code evidence retains full captured registry collisions without global promotion" {
    const a = std.testing.allocator;
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv(@embedFile("testdata/shy-nom-owner/language-registry.tsv"));
    try registry.addNomLanguageDataLua(@embedFile("testdata/shy-nom-data.lua"));
    try std.testing.expect(registry.isAmbiguous("Tacawit"));
    try std.testing.expect(registry.resolveTrusted("Tacawit") == null);
    try std.testing.expectEqualStrings("shy-latn", registry.resolve("tacawit").?.code);
    try std.testing.expect(registry.sourceNomLabel("shy") == null);
    registry.source_nom_role = true;
    try std.testing.expectEqualStrings("tacawit", registry.sourceNomLabel("shy").?);
    try std.testing.expect(registry.sourceNomLabel("shy-latn") == null);
    try std.testing.expect(registry.sourceNomLabel("Tacawit") == null);
    try std.testing.expect(registry.sourceNomLabel("SHY") == null);
    try std.testing.expect(!registry.sourceBannerLiteralCodeNameCompatible("shy", "Tacawit"));
    try std.testing.expect(!registry.sourceBannerLiteralCodeNameCompatible("shy", "tacawit"));
    try std.testing.expect(registry.resolveTrusted("Tacawit") == null);
    var rejected = Registry.empty(a); defer rejected.deinit();
    try rejected.addTsv("# mediawiki\nshy\tShawiya\n");
    try rejected.addNomLanguageDataLua("local l={}\nl['shy']={nom='tacawit'}\nmutate(l)\nreturn l");
    rejected.source_nom_role = true;
    try std.testing.expect(rejected.sourceNomLabel("shy") == null);
    var alias_only = Registry.empty(a); defer alias_only.deinit();
    try alias_only.addTsv("# mediawiki\nen\tEnglish\teng\n");
    try alias_only.addNomLanguageDataLua("local l={}\nl['eng']={nom='english'}\nreturn l");
    alias_only.source_nom_role = true;
    try std.testing.expectEqualStrings("en", alias_only.resolve("eng").?.code);
    try std.testing.expect(alias_only.sourceNomLabel("en") == null);
    try std.testing.expect(alias_only.sourceNomLabel("eng") == null);
    try alias_only.addNomLanguageDataLua("local l={}\nl['en']={nom='english'}\nreturn l");
    try std.testing.expectEqualStrings("english", alias_only.sourceNomLabel("en").?);
    try alias_only.addNomLanguageDataLua("local l={}\nl['en']={nom='different'}\nreturn l");
    try std.testing.expect(alias_only.sourceNomLabel("en") == null);
}

test "section name role accepts independent Strong canonical spelling without promoting bare alias trust" {
    const F = SourceSectionNameRoleTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const data = "local m = {}\nm[\"hy\"] = {\"อาร์มีเนีย\", 8785, \"hyx\", ancestors = \"axm\"}" ++ F.finish;
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# content-language\tth\n# mediawiki\nth\tไทย\nhy\tอาร์เมเนีย\nen\tอังกฤษ\n");
    try registry.addLua("return { [\"อาร์มีเนีย\"] = \"hy\" }");
    try std.testing.expectEqualStrings("hy", (registry.resolveCanonicalName("อาร์มีเนีย") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings("hy", (registry.resolveStrong("อาร์มีเนีย") orelse return error.TestUnexpectedResult).code);
    try std.testing.expect(registry.resolveTrusted("อาร์มีเนีย") == null);
    try std.testing.expect(registry.resolveTrusted("ภาษาอาร์มีเนีย") == null);
    const canonical_heading = (registry.resolve("hy") orelse return error.TestUnexpectedResult).heading;
    try registry.addSourceSectionLanguageDataLua(data, try F.proof(), "languages/data/2");
    try std.testing.expectEqualStrings("hy", (registry.resolveTrusted("ภาษาอาร์มีเนีย") orelse return error.TestUnexpectedResult).code);
    try std.testing.expectEqualStrings(canonical_heading, (registry.resolve("hy") orelse return error.TestUnexpectedResult).heading);
    try std.testing.expect(registry.resolveTrusted("อาร์มีเนีย") == null);
    try std.testing.expect(registry.resolveStrong("ภาษาอาร์มีเนีย") == null);

    for (0..7) |case| {
        var refused = Registry.empty(a); defer refused.deinit();
        try refused.addTsv("# content-language\tth\n# mediawiki\nth\tไทย\nhy\tอาร์เมเนีย\nen\tอังกฤษ\n");
        if (case != 0) try refused.addLua("return { [\"อาร์มีเนีย\"] = \"hy\" }");
        var selected_data: []const u8 = data;
        switch (case) {
            0 => try refused.addLocalAlias("อาร์มีเนีย", "hy"),
            1 => try refused.addLua("return { [\"อาร์มีเนีย\"] = \"en\" }"),
            2 => try refused.addLocalAlias("ภาษาอาร์มีเนีย", "en"),
            3 => selected_data = "local m = {}\nm[\"hy\"] = {\"อาร์มีเนีย\", 8785, \"hyx\", parent = \"axm\"}" ++ F.finish,
            4 => selected_data = "local m = {}\nm[\"en\"] = {\"อาร์มีเนีย\", 8785, \"hyx\"}" ++ F.finish,
            5 => {
                try refused.addLua("return { [\"en\"] = \"hy\" }");
                selected_data = "local m = {}\nm[\"hy\"] = {\"en\", 8785, \"hyx\"}" ++ F.finish;
            },
            6 => selected_data = "local m = {}\nm[\"hy\"] = {\"อาร์มีเนีย\", 8785, \"qfa-sub\"}" ++ F.finish,
            else => unreachable,
        }
        try refused.addSourceSectionLanguageDataLua(selected_data, try F.proof(), "languages/data/2");
        try std.testing.expect(refused.resolveTrusted("ภาษาอาร์มีเนีย") == null);
        try std.testing.expect(refused.resolveTrusted("ภาษาen") == null);
    }
}

test "reviewed language alias first letter retains exact conflicts boundaries and source trust limits" {
    const a = std.testing.allocator;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("reviewed_language_aliases.json"), &digest, .{});
    const marker = try std.fmt.allocPrint(a, "# reviewed-alias\thsb\thornjoserbšćina\thsb-hornjoserbscina-exact-enwik92963766-v1\t{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(marker);
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\nhsb\thornjoserbsce\ndsb\tdelnjoserbšćina\n");
    try std.testing.expect(registry.resolveTrusted("Hornjoserbšćina") == null);
    try registry.addTsv(marker);
    const owner = registry.resolveTrusted("Hornjoserbšćina") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hsb", owner.code);
    try std.testing.expectEqualStrings("hornjoserbsce", owner.heading);
    try std.testing.expect(registry.resolveSourceTrusted("Hornjoserbšćina") == null);
    for ([_][]const u8{ "HORNJOSERBŠĆINA", "Hornjoserbšćina extra", "hornjoserbŠćina" }) |name|
        try std.testing.expect(registry.resolveTrusted(name) == null);
    try registry.addLocalAlias("Hornjoserbšćina", "dsb");
    try std.testing.expect(registry.resolveTrusted("Hornjoserbšćina") == null);
    var conflicting = Registry.empty(a); defer conflicting.deinit();
    try conflicting.addTsv("# mediawiki\nhsb\thornjoserbsce\ndsb\tHornjoserbšćina\n");
    try conflicting.addTsv(marker);
    try std.testing.expectEqualStrings("dsb", conflicting.resolveTrusted("Hornjoserbšćina").?.code);
    var bounded = Registry.empty(a); defer bounded.deinit();
    try bounded.addTsv("# mediawiki\nhsb\thornjoserbsce\n");
    try bounded.addTsv(marker);
    try bounded.addLocalAlias("Hornjoserbšćina", "hsb");
    try bounded.addTsv("# local-language-boundary\tHornjoserbšćina\n");
    try std.testing.expect(bounded.resolveTrusted("Hornjoserbšćina") == null);
}

test "source parenthesized linked language role preserves independent owner and exact heading grammar" {
    const a = std.testing.allocator;
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("# mediawiki\neo\tesperanto\nhsb\thornjoserbsce\nen\tEnglish\n");
    try std.testing.expect(registry.sourceLinkedHeading("ŝarko ([[esperanto]])") == null);
    registry.source_parenthetical_linked_heading = true;
    const owner = registry.sourceLinkedHeading("ŝarko ([[esperanto]])") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("eo", owner.code);
    try std.testing.expectEqualStrings("esperanto", owner.heading);
    try std.testing.expectEqualStrings("en", registry.sourceLinkedHeading("word ([[English]])").?.code);
    try std.testing.expect(registry.resolve("ŝarko ([[esperanto]])") == null);
    for ([_][]const u8{
        "([[esperanto]])", "ŝarko ([[unknown]])", "ŝarko ([[eo]])", "ŝarko ([[esperanto|English]])",
        "ŝarko ([[:esperanto]])", "ŝarko ([[esperanto#part]])", "ŝarko ([[esperanto]]) tail",
        "ŝarko ([[esperanto]]) ([[English]])", "<b>ŝarko</b> ([[esperanto]])", "ŝarko\n([[esperanto]])",
        " ŝarko ([[esperanto]])", "ŝarko ([[ esperanto]])", "ŝarko ([[esperanto]]) ",
        "ŝarko ([[esperanto&#93;]])", "{{word}} ([[esperanto]])",
    }) |heading| try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
    try registry.addTsv("# local-language-boundary\tesperanto\n");
    try std.testing.expect(registry.sourceLinkedHeading("ŝarko ([[esperanto]])") == null);
}


test "canonical module code values preserve Irish while captured Ga name trust remains distinct" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |reverse_rows| for ([_]bool{ false, true }) |reverse_module| {
        var registry = Registry.empty(a); defer registry.deinit();
        const rows = if (reverse_rows)
            "gaa\tga\tGa\tgaa\nga\tír\tÍr\tGaeilge\tga\tIrish\tgle\n"
        else
            "ga\tír\tÍr\tGaeilge\tga\tIrish\tgle\ngaa\tga\tGa\tgaa\n";
        const tsv = try std.mem.concat(a, u8, &.{ "# content-language\thu\n# mediawiki\nhu\tmagyar\n", rows });
        defer a.free(tsv);
        try registry.addTsv(tsv);
        // The ordinary name slot is genuinely Ga, while ga is independently
        // registered as the Irish code. Neither role may borrow the other.
        try std.testing.expect(registry.codes.contains("ga"));
        try std.testing.expectEqualStrings("gaa", registry.resolve("ga").?.code);
        try std.testing.expectEqualStrings("gaa", registry.resolveTrusted("Ga").?.code);
        try std.testing.expectEqualStrings("gaa", registry.captured_preferred_capitalizations.get("Ga").?.?.code);
        try std.testing.expectEqualStrings("ga", registry.resolveTrusted("Ír").?.code);
        // Both assignments occur literally in retained HU module
        // languages/canonical names p412054/r3216114.
        try registry.addLua(if (reverse_module)
            "return { [\"ga\"] = \"gaa\", [\"ír\"] = \"ga\" }"
        else
            "return { [\"ír\"] = \"ga\", [\"ga\"] = \"gaa\" }");
        try std.testing.expectEqualStrings("ga", registry.resolveCanonicalName("ír").?.code);
        try std.testing.expectEqualStrings("gaa", registry.resolveCanonicalName("ga").?.code);
        try std.testing.expectEqualStrings("ga", registry.resolveStrong("ír").?.code);
        try std.testing.expectEqualStrings("ga", registry.resolveTrusted("Ír").?.code);
        try std.testing.expectEqualStrings("gaa", registry.resolveTrusted("Ga").?.code);
        try std.testing.expectEqualStrings("gaa", registry.resolve("ga").?.code);
        try std.testing.expectEqualStrings("ga", registry.resolve("gaa").?.heading);
        try std.testing.expect(registry.isLanguageBoundary("ga"));
        try std.testing.expect(registry.resolveStrong("ga") == null);
        try std.testing.expect(registry.resolveTrusted("ga") == null);
        // Isolate the existing source-linked formatter consumer; this installs
        // neither a normal template role nor a physical-root certificate.
        try registry.addSourceLinkedHeading(.{ .prefix = ":w:", .suffix = " nyelv" });
        try std.testing.expectEqualStrings("ga", registry.sourceLinkedHeading("[[:w:ír nyelv|Ír]]").?.code);
        try std.testing.expect(registry.sourceLinkedHeading("[[:w:ga nyelv|Ga]]") == null);
        try std.testing.expect(registry.sourceLinkedHeading("[[:w:ír nyelv|Ga]]") == null);
        try std.testing.expect(registry.sourceLinkedHeading("[[:w:ír nyelv|Ír]] extra") == null);
        // Genuine competing source declarations must still remove ownership.
        try registry.addLua("return { [\"ír\"] = \"gaa\" }");
        try std.testing.expect(registry.resolveCanonicalName("ír") == null);
        try std.testing.expect(registry.sourceLinkedHeading("[[:w:ír nyelv|Ír]]") == null);
        try std.testing.expectEqualStrings("gaa", registry.resolveTrusted("Ga").?.code);
    };
}

test "canonical code preference preserves existing aliases new codes and conflicting-name refusals" {
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv("# mediawiki\nen\tEnglish\teng\nfr\tFrench\n");
    try registry.addLua("return { [\"angol\"] = \"eng\", [\"new label\"] = \"qzz\" }");
    try std.testing.expectEqualStrings("en", registry.resolveCanonicalName("angol").?.code);
    try std.testing.expectEqualStrings("qzz", registry.resolveCanonicalName("new label").?.code);
    try std.testing.expect(registry.codes.contains("qzz"));
    try std.testing.expectEqualStrings("en", registry.resolveTrusted("English").?.code);
    try registry.addLua("return { [\"angol\"] = \"fr\" }");
    try std.testing.expect(registry.resolveCanonicalName("angol") == null);
    try std.testing.expect(registry.resolveStrong("angol") == null);
    try std.testing.expect(registry.isLanguageBoundary("angol"));
    try std.testing.expectError(error.InvalidLanguageRegistry, registry.addLua("return { [\"invalid code\"] = \"not a code\" }"));
    try std.testing.expectEqualStrings("en", registry.resolveTrusted("English").?.code);
}


test "proved linked canonical formatter derives exact capitalized label without installing an alias" {
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv("# content-language\thu\n# mediawiki\nhu\tmagyar\nnb\tnorvég (bokmål)\tNorvég (bokmål)\nen\tEnglish\nfr\tFrench\n");
    try registry.addLua("return { [\"norvég bokmål\"] = \"nb\" }");
    const heading = "[[:w:norvég bokmål nyelv|Norvég bokmål]]";
    try std.testing.expect(registry.resolve("Norvég bokmål") == null);
    try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
    try registry.addSourceLinkedHeading(.{ .prefix = ":w:", .suffix = " nyelv" });
    const owner = registry.sourceLinkedHeading(heading) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("nb", owner.code);
    try std.testing.expectEqualStrings("norvég bokmål", owner.heading);
    try std.testing.expect(registry.resolve("Norvég bokmål") == null);
    try std.testing.expect(registry.resolveTrusted("Norvég bokmål") == null);
    try std.testing.expect(registry.resolveStrong("Norvég bokmål") == null);
    for ([_][]const u8{
        "[[:w:norvég bokmål nyelv|norvég bokmål]]",
        "[[:w:norvég bokmål nyelv|NORVÉG BOKMÅL]]",
        "[[:w:norvég bokmål nyelv|Norvég (bokmål)]]",
        "[[:w:norvég bokmål nyelv|Norvég bokmål]] extra",
        "[[:w:unknown nyelv|Unknown]]",
    }) |bad| try std.testing.expect(registry.sourceLinkedHeading(bad) == null);
    // Ordinary aliases remain insufficient for the canonical-name role.
    try registry.addTsv("nb\tnorvég (bokmål)\tnorvég\n");
    try std.testing.expect(registry.sourceLinkedHeading("[[:w:norvég nyelv|Norvég]]") == null);
    // Even an untrusted installed competing owner vetoes the derived label.
    try registry.addTsv("en\tEnglish\tNorvég bokmål\n");
    try std.testing.expectEqualStrings("en", registry.resolve("Norvég bokmål").?.code);
    try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
    try registry.addTsv("fr\tFrench\tNorvég bokmål\n");
    try std.testing.expect(registry.isLanguageBoundary("Norvég bokmål"));
    try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
}


test "derived linked heading distinguishes missing label from conflicting local alias evidence" {
    for ([_]u8{ 0, 1, 2 }) |case| {
        var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
        try registry.addTsv("# mediawiki\nnb\tnorvég (bokmål)\tNorvég (bokmål)\nen\tEnglish\n");
        try registry.addLua("return { [\"norvég bokmål\"] = \"nb\" }");
        try registry.addSourceLinkedHeading(.{ .prefix = ":w:", .suffix = " nyelv" });
        const label = "Norvég bokmål";
        const heading = "[[:w:norvég bokmål nyelv|Norvég bokmål]]";
        try std.testing.expect(registry.names.get(label) == null);
        try std.testing.expect(registry.sourceLinkedHeading(heading) != null);
        try registry.addLocalAlias(label, if (case == 0) "en" else "nb");
        if (case == 2) try registry.addLocalAlias(label, "en");
        if (case == 1) {
            try std.testing.expectEqualStrings("nb", registry.sourceLinkedHeading(heading).?.code);
        } else {
            try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
        }
        if (case == 2) {
            try std.testing.expect(registry.local_aliases.contains(label));
            try std.testing.expect(registry.local_aliases.get(label).? == null);
            try std.testing.expect(registry.resolve(label) == null);
        }
        try std.testing.expect(registry.names.get(label) == null);
    }
}


test "derived linked heading preserves reviewed and articleless fallback conflict refusals" {
    const label = "Norvég bokmål";
    const heading = "[[:w:norvég bokmål nyelv|Norvég bokmål]]";
    for ([_]u8{ 0, 1, 2, 3 }) |case| {
        var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
        try registry.addTsv("# mediawiki\nnb\tnorvég (bokmål)\nen\tEnglish\n");
        // No source role is inferred from this controlled fallback map.
        try registry.addLua("return { [\"norvég bokmål\"] = \"nb\" }");
        try registry.addSourceLinkedHeading(.{ .prefix = ":w:", .suffix = " nyelv" });
        try registry.reviewed_aliases.put(registry.arena.allocator(), label, if (case == 1 or case == 2) "en" else "nb");
        if (case == 1) try registry.addLocalAlias(label, "nb");
        if (case == 3) try registry.addLocalAlias(label, "en");
        if (case == 0) {
            try std.testing.expectEqualStrings("nb", registry.sourceLinkedHeading(heading).?.code);
        } else {
            try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
        }
        if (case == 1) try std.testing.expect(registry.resolve(label) == null);
        try std.testing.expect(!registry.names.contains(label));
    }
    for ([_]u8{ 0, 1, 2, 3 }) |case| {
        var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
        try registry.addTsv("# content-language\tar\n# mediawiki\nar\tالعربية\nnb\tnorvég (bokmål)\nen\tEnglish\n");
        try registry.addLua("return { [\"norvég bokmål\"] = \"nb\" }");
        try registry.addSourceLinkedHeading(.{ .prefix = ":w:", .suffix = " nyelv" });
        try std.testing.expect(registry.sourceLinkedHeading(heading) != null);
        // Exercise the existing fallback metadata representation directly:
        // ambiguity, foreign owner, valid same owner, and lost original trust.
        const article: ?DerivedPreferredName = switch (case) {
            0 => null,
            1 => .{ .original_name = "English", .code = "en" },
            2 => .{ .original_name = "norvég (bokmål)", .code = "nb" },
            else => .{ .original_name = "not-installed", .code = "nb" },
        };
        try registry.arabic_articleless_names.put(registry.arena.allocator(), label, article);
        if (case == 2) {
            try std.testing.expectEqualStrings("nb", registry.sourceLinkedHeading(heading).?.code);
        } else {
            try std.testing.expect(registry.sourceLinkedHeading(heading) == null);
        }
        try std.testing.expect(!registry.names.contains(label));
    }
}

const NamedSectionProviderTest = struct {
    const programs = [4][]const u8{
        @embedFile("testdata/fr-named-owner/langues.lua"), @embedFile("testdata/fr-named-owner/section-langue.lua"),
        @embedFile("testdata/fr-named-owner/bases.lua"), @embedFile("testdata/fr-named-owner/parametres.lua"),
    };
    const alias_source =
        \\local function aliasOf(code)
        \\ local copy = { aliasOf = code }
        \\ for k, v in pairs(l[code]) do copy[k] = v end
        \\ return copy
        \\end
    ;
};

test "named section source stages complete retained language data and registers only direct ordinary codes" {
    const a = std.testing.allocator;
    const F = NamedSectionProviderTest;
    const proof = Registry.proveNamedSectionProvider(F.programs) orelse return error.TestUnexpectedResult;
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv(@embedFile("testdata/fr-named-owner/language-registry.tsv"));
    try std.testing.expect(!registry.codes.contains("conv"));
    try std.testing.expect(try registry.addNamedSectionDataLua(@embedFile("testdata/fr-named-owner/langues-data.lua"), proof));
    try std.testing.expectEqualStrings("conv", registry.resolve("conv").?.code);
    try std.testing.expectEqualStrings("Conventions internationales", registry.resolve("conv").?.heading);
    try std.testing.expect(registry.sourceNomLabel("conv") == null);
    registry.source_nom_role = true;
    try std.testing.expectEqualStrings("conventions internationales", registry.sourceNomLabel("conv").?);
    try std.testing.expect(registry.resolveTrusted("Conventions internationales") == null);
    try std.testing.expect(registry.sourceNomLabel("wikispecies") == null);
    try std.testing.expect(registry.sourceNomLabel("CONV") == null);
    try std.testing.expect(registry.sourceNomLabel("Caractère") == null);
    try std.testing.expect(registry.sourceNomLabel("eng") == null);
    // Each program is authority, not just a metadata role or module title.
    for (0..F.programs.len) |i| {
        var changed = F.programs;
        changed[i] = "return {}";
        try std.testing.expect(Registry.proveNamedSectionProvider(changed) == null);
    }
    var swapped = F.programs; std.mem.swap([]const u8, &swapped[0], &swapped[1]);
    try std.testing.expect(Registry.proveNamedSectionProvider(swapped) == null);
}

test "named source code admission preserves alias snapshots special group collision and whole program refusals" {
    const a = std.testing.allocator;
    const proof = Registry.proveNamedSectionProvider(NamedSectionProviderTest.programs).?;
    const source = "local l={}\nl['fresh']={name='fresh name'}\nl['special']={name='special name',isSpecial=true}\nl['group']={name='group name',isGroup=true}\n" ++
        NamedSectionProviderTest.alias_source ++ "\nl['copied']=aliasOf('fresh')\nl['fresh']={name='updated name'}\nreturn l";
    var registry = Registry.empty(a); defer registry.deinit();
    try registry.addTsv("en\tEnglish\tcollision\n");
    try std.testing.expect(try registry.addNamedSectionDataLua(source, proof));
    registry.source_nom_role = true;
    try std.testing.expectEqualStrings("updated name", registry.sourceNomLabel("fresh").?);
    for ([_][]const u8{ "copied", "special", "group" }) |code_value| {
        try std.testing.expect(!registry.codes.contains(code_value));
        try std.testing.expect(registry.sourceNomLabel(code_value) == null);
    }
    try std.testing.expect(try registry.addNamedSectionDataLua("local l={} l['collision']={name='wrong'} return l", proof));
    try std.testing.expectEqualStrings("en", registry.resolve("collision").?.code);
    try std.testing.expect(registry.sourceNomLabel("collision") == null);
    try std.testing.expect(try registry.addNamedSectionDataLua("local l={} l['fresh']={name='disagreement'} return l", proof));
    try std.testing.expect(registry.sourceNomLabel("fresh") == null);
    for ([_][]const u8{
        "local l={} l['unearned']={name='literal'} mutate(l) return l",
        "local l={} l['unearned']={name='literal'} l[dynamic]={name='other'} return l",
        "local l={} l['unearned']={name='literal'} l['later']={name=makeName()} return l",
        "local l={} l['unearned']={name='literal',name='other'} return l",
        "local l={} l['unearned']={name='literal',isSpecial='truthy'} return l",
        "local l={} l['unearned']={name='literal'} l['unearned'].name='changed' return l",
        "local l={} l['unearned']={name='literal'} return {}",
        "local l={} l['unearned']={name='literal'} local function aliasOf(code) return l[code] end return l",
        "local l={} l['unearned']={name='literal'} " ++ NamedSectionProviderTest.alias_source ++ " l['x']=aliasOf('absent') return l",
    }) |bad| {
        var declined = Registry.empty(a); defer declined.deinit();
        try std.testing.expect(!try declined.addNamedSectionDataLua(bad, proof));
        try std.testing.expectEqual(@as(usize, 0), declined.codes.count());
        try std.testing.expectEqual(@as(usize, 0), declined.source_nom_names.count());
    }
}

test "complete English name profile adds only weak aliases and preserves canonical owners" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\tsr\n# mediawiki\nsr\tсрпски\ncs\tчешки\tCzech\nenm\tMiddle English (1100-1500)\n");
    try registry.addLua("return { [\"Чешки\"] = \"cs\", [\"Средњи Енглески\"] = \"enm\" }");
    const profile = "# wikidict-language-names-v1\n# wiki\tsrwiktionary\n# dump-date\t20261001\n# content-language\tsr\n" ++
        "C\ten\tall\t2\nN\ten\tall\tcs\tCzech\nN\ten\tall\tenm\tMiddle English\n";
    try std.testing.expect(registry.resolve("Middle English") == null);
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    const owner = registry.resolve("Middle English") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("enm", owner.code);
    try std.testing.expectEqualStrings("Средњи Енглески", owner.heading);
    try std.testing.expect(registry.resolveStrong("Middle English") == null);
    try std.testing.expect(registry.resolveTrusted("Middle English") == null);
    try std.testing.expectEqualStrings("cs", registry.resolve("Czech").?.code);
    try std.testing.expect(registry.resolveStrong("Czech") == null);
    try std.testing.expect(registry.resolveTrusted("Czech") == null);
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, registry.trustAutonymSnapshot(profile, "enwiktionary", "20261001", "sr"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, registry.trustAutonymSnapshot(profile, "srwiktionary", "20261002", "sr"));
}

test "English name aliases refuse incomplete duplicate and competing source profiles" {
    const header = "# wikidict-language-names-v1\n# wiki\tsrwiktionary\n# dump-date\t20261001\n# content-language\tsr\n";
    const rows = "# content-language\tsr\n# mediawiki\nsr\tсрпски\nenm\tСредњи Енглески\ncs\tЧешки\nen\tЕнглески\n";
    for ([_][]const u8{
        header ++ "C\ten\tall\t2\nN\ten\tall\tenm\tMiddle English\n",
        header ++ "C\ten\tall\t1\nN\ten\tall\tenm\tMiddle English\nN\ten\tall\tcs\tCzech\n",
        header ++ "C\ten\tall\t2\nN\ten\tall\tenm\tMiddle English\nN\ten\tall\tenm\tOther\n",
        header ++ "C\ten\tall\t0\nC\ten\tall\t0\n",
    }) |bad| {
        var registry = Registry.empty(std.testing.allocator);
        defer registry.deinit();
        try registry.addTsv(rows);
        if (registry.trustAutonymSnapshot(bad, "srwiktionary", "20261001", "sr")) |_| return error.TestUnexpectedResult else |_| {}
        try std.testing.expect(registry.resolve("Middle English") == null);
    }
    var ambiguous = Registry.empty(std.testing.allocator);
    defer ambiguous.deinit();
    try ambiguous.addTsv(rows);
    try ambiguous.trustAutonymSnapshot(header ++ "C\ten\tall\t2\nN\ten\tall\tenm\tShared\nN\ten\tall\tcs\tShared\n", "srwiktionary", "20261001", "sr");
    try std.testing.expect(ambiguous.resolve("Shared") == null);
    var conflict = Registry.empty(std.testing.allocator);
    defer conflict.deinit();
    try conflict.addTsv(rows);
    try conflict.addLocalAlias("Middle English", "en");
    try conflict.trustAutonymSnapshot(header ++ "C\ten\tall\t1\nN\ten\tall\tenm\tMiddle English\n", "srwiktionary", "20261001", "sr");
    try std.testing.expectEqualStrings("en", conflict.resolve("Middle English").?.code);
    try std.testing.expect(!conflict.names.contains("Middle English"));
}

test "English weak aliases cannot seed heading trust across repeated loads" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\tsr\n# mediawiki\nsr\tсрпски\nenm\tСредњи Енглески\n");
    const profile = "# wikidict-language-names-v1\n# wiki\tsrwiktionary\n# dump-date\t20261001\n# content-language\tsr\n" ++
        "C\ten\tall\t1\nN\ten\tall\tenm\tMiddle English\nC\t-\tsingle\t1\nN\t-\tsingle\tenm\tMiddle English\n";
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try std.testing.expectEqualStrings("enm", registry.resolve("Middle English").?.code);
    try std.testing.expect(registry.english_added_aliases.contains("Middle English"));
    try std.testing.expect(!registry.autonym_headings.contains("Middle English"));
    try std.testing.expect(registry.resolveStrong("Middle English") == null);
    try std.testing.expect(registry.resolveTrusted("Middle English") == null);
    try registry.addLocalAlias("Middle English", "sr");
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try std.testing.expect(registry.resolve("Middle English") == null);
    try std.testing.expect(registry.resolveTrusted("Middle English") == null);
    try std.testing.expect(registry.resolveStrong("Middle English") == null);

    // An alias independently installed before the English profile retains the
    // existing captured-autonym trust behavior, including repeated loads.
    var prior = Registry.empty(std.testing.allocator);
    defer prior.deinit();
    try prior.addTsv("# content-language\tsr\n# mediawiki\nsr\tсрпски\nenm\tСредњи Енглески\tMiddle English\n");
    try prior.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try prior.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try std.testing.expect(!prior.english_added_aliases.contains("Middle English"));
    try std.testing.expectEqualStrings("enm", prior.resolveTrusted("Middle English").?.code);
}


test "English-only capitalization cannot inherit preferred heading trust" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\tsr\n# mediawiki\nsr\tсрпски\nenm\tmiddle english\n");
    // Isolate the existing preferred-capitalization fallback from a label that
    // the TSV generator independently installed. The source profile now creates it.
    _ = registry.names.remove("Middle english");
    _ = registry.trusted_names.remove("Middle english");
    const profile = "# wikidict-language-names-v1\n# wiki\tsrwiktionary\n# dump-date\t20261001\n# content-language\tsr\n" ++
        "C\ten\tall\t1\nN\ten\tall\tenm\tMiddle english\n";
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
    try std.testing.expectEqualStrings("enm", registry.resolve("Middle english").?.code);
    try std.testing.expect(registry.isPreferredCapitalization("middle english", "Middle english"));
    try std.testing.expect(registry.trusted_names.contains("middle english"));
    try std.testing.expect(registry.resolveTrusted("Middle english") == null);
    try std.testing.expect(registry.resolveStrong("Middle english") == null);
}


test "English-only autonym bases cannot promote pre-existing capitalized aliases on repeat" {
    var registry = Registry.empty(std.testing.allocator);
    defer registry.deinit();
    try registry.addTsv("# content-language\tsr\n# mediawiki\nsr\tсрпски\nenm\tСредњи Енглески\n");
    try registry.addAlias("Middle english", "enm");
    try std.testing.expect(registry.resolveTrusted("Middle english") == null);
    try std.testing.expect(registry.resolve("middle english") == null);
    const profile = "# wikidict-language-names-v1\n# wiki\tsrwiktionary\n# dump-date\t20261001\n# content-language\tsr\n" ++
        "C\ten\tall\t1\nN\ten\tall\tenm\tmiddle english\nC\t-\tsingle\t1\nN\t-\tsingle\tenm\tmiddle english\n";
    for (0..2) |_| {
        try registry.trustAutonymSnapshot(profile, "srwiktionary", "20261001", "sr");
        try std.testing.expectEqualStrings("enm", registry.resolve("middle english").?.code);
        try std.testing.expectEqualStrings("enm", registry.resolve("Middle english").?.code);
        try std.testing.expect(registry.english_added_aliases.contains("middle english"));
        try std.testing.expect(!registry.english_added_aliases.contains("Middle english"));
        try std.testing.expect(!registry.autonym_headings.contains("Middle english"));
        try std.testing.expect(registry.resolveTrusted("middle english") == null);
        try std.testing.expect(registry.resolveTrusted("Middle english") == null);
        try std.testing.expect(registry.resolveStrong("Middle english") == null);
    }
}

// Retained Наслов p2519/r697248 and Значење p1102/r452726. The
// Serbian branch declares noun; arg3 has no meaning in that branch.
pub const NaslovTemplateRole = enum { header, meaning };
pub fn sourceNaslovTemplateRole(source: []const u8, role: NaslovTemplateRole) bool {
    const expected = switch (role) {
        .header => "a6ab92577e51e93d0e0d408c2a6ea440fa67540dfcd927d5d5bedff1837f5d1b",
        .meaning => "e8aef090c4c8aa3ae270a630a1efb1ddd01056a9ea8672e07bf7d9b904fe1715",
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}

test "MG exact equals template labels remain source bound and reject collisions" {
    var registry = Registry.empty(std.testing.allocator); defer registry.deinit();
    try registry.addTsv("# mediawiki\nbr\tbreton\nen\tEnglish\n");
    try std.testing.expect(registry.sourceEqualsLabel("br") == null);
    try registry.addSourceEqualsLabel("br", "Bretôna");
    try std.testing.expectEqualStrings("Bretôna", registry.sourceEqualsLabel("br").?);
    try std.testing.expect(registry.resolve("Bretôna") == null);
    try std.testing.expect(registry.resolveTrusted("Bretôna") == null);
    try std.testing.expect(registry.resolveStrong("Bretôna") == null);
    try std.testing.expect(registry.sourceEqualsLabel("en") == null);
    for ([_][]const u8{ "{{Bretôna}}", "<span>Bretôna</span>", "Bretôna\n", " Bretôna", "Bretôna[[Category:br]]", "Bretôna\x7f", "Bretôna&x;", "English" }) |bad| {
        var isolated = Registry.empty(std.testing.allocator); defer isolated.deinit();
        try isolated.addTsv("# mediawiki\nbr\tbreton\nen\tEnglish\n");
        try isolated.addSourceEqualsLabel("br", bad);
        try std.testing.expect(isolated.sourceEqualsLabel("br") == null);
    }
    try registry.addSourceEqualsLabel("br", "Other local label");
    try std.testing.expect(registry.sourceEqualsLabel("br") == null);
    try registry.addSourceEqualsLabel("br", "Bretôna");
    try std.testing.expect(registry.sourceEqualsLabel("br") == null);
    var changed = Registry.empty(std.testing.allocator); defer changed.deinit();
    try changed.addTsv("# mediawiki\nbr\tbreton\nen\tEnglish\n");
    try changed.addSourceEqualsLabel("br", "Bretôna");
    try changed.addTsv("# mediawiki\nen\tEnglish\tBretôna\n");
    try std.testing.expect(changed.sourceEqualsLabel("br") == null);
}

// Local static providers -noun- p1959/r4738 and -adj- p1960/r4739.
// These exact bodies declare a role; they never select a language owner.
pub fn sourceNumberedPosTemplate(source: []const u8, role: usize) bool {
    const expected: []const u8 = switch (role) {
        0 => "8c143433b042950fcbcaac1a244bc2a9e2bea28022ee26c7c9ba14b74497c1a9",
        1 => "d9a254105b54665dfc7e05926bc4557f22bafb6412a1379da09f18cf68d114d0",
        else => return false,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected);
}

test "captured Chinese Old French spelling requires complete source and profile agreement" {
    const a = std.testing.allocator;
    const header = "# wikidict-language-names-v1\n# wiki\tzhwiktionary\n# dump-date\t20261001\n# content-language\tzh\n";
    const rows = "C\tzh\tall\t1\nN\tzh\tall\tfro\t古法语\nC\tzh\tsingle\t1\nN\tzh\tsingle\tfro\t古法语\n";
    const tsv = "# content-language\tzh\n# mediawiki\nzh\t中文\tzh\tChinese\tzho\tchi\nfro\tOld French (842-ca. 1400)\tfro\nfr\tFrench\n";
    const data = @embedFile("testdata/zh-fro-owner11/module-1363222.lua");
    for (0..10) |arm| {
        var registry = Registry.empty(a); defer registry.deinit();
        try registry.addTsv(tsv);
        if (arm != 1) try positionalLanguageDataImport(&registry, data, "languages/data/3/f");
        if (arm == 2) try registry.addLocalAlias("古法語", "fr");
        if (arm == 3) try registry.addLocalAlias("古法语", "fr");
        if (arm == 4) try registry.addTsv("fr\tFrench\t古法语\n");
        if (arm == 5) try registry.addSourceFullName("fro", null);
        const profile = switch (arm) {
            6 => header ++ "C\tzh\tall\t1\nN\tzh\tall\tfro\t古法语\n",
            7 => header ++ rows ++ "N\tzh\tsingle\tfr\t古法语\n",
            8 => header ++ "C\tzh\tall\t2\nN\tzh\tall\tfro\t古法语\nN\tzh\tall\tfr\t古法语\nC\tzh\tsingle\t1\nN\tzh\tsingle\tfro\t古法语\n",
            9 => header ++ "C\tzh\tall\t1\nN\tzh\tall\tfro\t古法语\nC\tzh\tsingle\t1\nN\tzh\tsingle\tfro\tOther\n",
            else => header ++ rows,
        };
        try registry.trustAutonymSnapshot(profile, "zhwiktionary", "20261001", "zh");
        if (arm == 0) {
            const owner = registry.resolveTrusted("古法语") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("fro", owner.code);
            try std.testing.expectEqualStrings("Old French (842-ca. 1400)", owner.heading);
            try std.testing.expect(registry.resolveStrong("古法语") == null);
            try registry.addLocalAlias("古法语", "fr");
            try std.testing.expect(registry.resolveTrusted("古法语") == null);
        } else if (arm == 3) {
            // A conflicting explicit local alias stays French; this profile
            // must neither erase that authority nor promote it to Old French.
            const conflict = registry.resolveTrusted("古法语") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("fr", conflict.code);
            try std.testing.expectEqualStrings("French", conflict.heading);
        } else try std.testing.expect(registry.resolveTrusted("古法语") == null);
    }
    var foreign = Registry.empty(a); defer foreign.deinit();
    try foreign.addTsv(tsv);
    try positionalLanguageDataImport(&foreign, data, "languages/data/3/f");
    const foreign_profile = "# wikidict-language-names-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\tzh\n" ++ rows;
    try foreign.trustAutonymSnapshot(foreign_profile, "enwiktionary", "20261001", "zh");
    try std.testing.expect(foreign.resolveTrusted("古法语") == null);
    const other = header ++ "C\tzh\tall\t1\nN\tzh\tall\tfr\t法语\nC\tzh\tsingle\t1\nN\tzh\tsingle\tfr\t法语\n";
    try foreign.trustAutonymSnapshot(other, "zhwiktionary", "20261001", "zh");
    try std.testing.expect(foreign.resolveTrusted("法语") == null);
}

test "captured Chinese spelling joins canonical source without generic trust or conflict loss" {
    const a = std.testing.allocator;
    const header = "# wikidict-language-names-v1\n# wiki\tzhwiktionary\n# dump-date\t20261001\n# content-language\tzh\n";
    const rows = "C\tzh\tall\t1\nN\tzh\tall\tfro\t古法语\nC\tzh\tsingle\t1\nN\tzh\tsingle\tfro\t古法语\n";
    for (0..10) |arm| {
        var registry = Registry.empty(a); defer registry.deinit();
        try registry.addTsv(@embedFile("testdata/zh-fro-owner11/language-registry.tsv"));
        try registry.addLua(@embedFile("testdata/zh-fro-canonical01/module-1368467.lua"));
        if (arm != 1) try positionalLanguageDataImport(&registry, @embedFile("testdata/zh-fro-owner11/module-1363222.lua"), "languages/data/3/f");
        if (arm == 2) try registry.addLua("return {[\"古法語\"]=\"fr\"}");
        if (arm == 3) try registry.addLocalAlias("古法語", "fr");
        if (arm == 4) try registry.addLocalAlias("古法语", "fr");
        if (arm == 5) try registry.addSourceFullName("fro", null);
        if (arm == 7) _ = registry.source_canonical_names.remove("古法語");
        if (arm == 8) _ = registry.strong_names.remove("古法語");
        if (arm == 9) try registry.english_added_aliases.put(registry.arena.allocator(), "古法語", {});
        if (arm == 0) {
            try std.testing.expect(registry.resolveTrusted("古法語") == null);
            try std.testing.expectEqualStrings("fro", registry.resolveStrong("古法語").?.code);
            try std.testing.expect(registry.resolveTrusted("古法语") == null);
        }
        const profile = if (arm == 6) header ++ "C\tzh\tall\t1\nN\tzh\tall\tfro\t古法语\n" else header ++ rows;
        try registry.trustAutonymSnapshot(profile, "zhwiktionary", "20261001", "zh");
        if (arm == 0) {
            const owner = registry.resolveTrusted("古法语") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("fro", owner.code);
            try std.testing.expectEqualStrings("古法語", owner.heading);
            try std.testing.expect(registry.resolveStrong("古法语") == null);
            try std.testing.expect(registry.resolveTrusted("古法語") == null);
            try registry.addLocalAlias("古法语", "fr");
            try std.testing.expect(registry.resolveTrusted("古法语") == null);
        } else if (arm == 4) {
            try std.testing.expectEqualStrings("fr", registry.resolveTrusted("古法语").?.code);
        } else try std.testing.expect(registry.resolveTrusted("古法语") == null);
    }
}
