//! Build-only image-effect facts. These prove a negative timed-media
//! contribution, never successful rendering, dimensions, or all module effects.
const std = @import("std");
const NS = @import("namespace_registry");

pub const filename = "image-effect-catalog.tsv";
pub const max_catalog_bytes = 4 * 1024 * 1024;
pub const max_provider_bytes = 8 * 1024 * 1024;
pub const max_options_bytes = 1024 * 1024;
pub const max_behavior_bytes = 1024 * 1024;
pub const max_entries = 16384;
pub const schema = "normal-it-image-effect-catalog.v1";
pub const grammar = "normal-literal-image-options.v1";
pub const caption_grammar = "normal-image-options-ordinary-caption.v2";
pub const interwiki_caption_grammar = "normal-image-options-interwiki-caption.v3";
pub const header = "# wikidict-image-effect-catalog-v1\n";

pub const Reference = struct {
    schema: []const u8,
    grammar: []const u8,
    sha256: []const u8,
    bytes: usize,
    count: usize,
    namespace_sha256: []const u8,
    image_options_sha256: []const u8,
    behavior_switches_sha256: []const u8,
    file_metadata_sha256: []const u8,
    source_manifest_sha256: []const u8,
    raw_sha256: []const u8,
    projection_sha256: []const u8,
    source_proof_sha256: []const u8,
    feature_source_sha256: []const u8,
    module_selection_sha256: []const u8,
    interwiki_sha256: ?[]const u8 = null,
};

// Actual selected bytes, not a caller-asserted digest. The ordinary loader
// retains physical input custody and this module checks all four byte bodies.
pub const Sources = struct {
    catalog: []const u8,
    file_metadata: []const u8,
    image_options: []const u8,
    behavior_switches: []const u8,
    interwiki_map: ?[]const u8 = null,
};
pub const Effect = struct { thumbnail: bool };
const Media = enum { bitmap, drawing };
const Entry = struct {
    requested: []const u8,
    canonical: []const u8,
    file_sha1: []const u8,
    timestamp: []const u8,
    media: Media,
    mime: []const u8,
};

fn invalid() error{InvalidImageEffectCatalog} { return error.InvalidImageEffectCatalog; }
fn digest(text: []const u8) ![32]u8 {
    if (text.len != 64) return invalid();
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return invalid();
    if (std.mem.allEqual(u8, &out, 0) or !std.mem.eql(u8, text, &std.fmt.bytesToHex(out, .lower))) return invalid();
    return out;
}
fn bound(bytes: []const u8, expected: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &(try digest(expected)))) return invalid();
}
fn lowerHex(bytes: []const u8, len: usize) bool {
    if (bytes.len != len) return false;
    for (bytes) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return !std.mem.allEqual(u8, bytes, '0');
}
fn timestampValid(bytes: []const u8) bool {
    if (bytes.len != 20) return false;
    for (bytes, 0..) |c, i| switch (i) {
        4, 7 => if (c != '-') return false,
        10 => if (c != 'T') return false,
        13, 16 => if (c != ':') return false,
        19 => if (c != 'Z') return false,
        else => if (!std.ascii.isDigit(c)) return false,
    };
    return true;
}
fn pair(media: []const u8, mime: []const u8) ?Media {
    if (std.mem.eql(u8, media, "DRAWING")) return if (std.mem.eql(u8, mime, "image/svg+xml")) .drawing else null;
    if (!std.mem.eql(u8, media, "BITMAP")) return null;
    for ([_][]const u8{ "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp" }) |allowed|
        if (std.mem.eql(u8, mime, allowed)) return .bitmap;
    return null;
}
fn mediaName(media: Media) []const u8 { return if (media == .bitmap) "BITMAP" else "DRAWING"; }
fn fields6(line: []const u8) ![6][]const u8 {
    if (line.len == 0 or line.len > 8192 or !std.unicode.utf8ValidateSlice(line) or
        std.mem.indexOfAny(u8, line, "\r\n\x00") != null) return invalid();
    var fields = std.mem.splitScalar(u8, line, '\t');
    var result: [6][]const u8 = undefined;
    for (&result) |*value| { value.* = fields.next() orelse return invalid(); if (value.len == 0) return invalid(); }
    if (fields.next() != null) return invalid();
    return result;
}
fn normalize(a: std.mem.Allocator, ns: *const NS.Registry, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or raw.len > 4096 or std.mem.indexOfAny(u8, raw, "\t\r\n\x00") != null) return invalid();
    const title = try ns.normalizeTitle(a, raw, 0, .any);
    if (ns.ofTitle(title).id != 6) return invalid();
    return title;
}
fn less(_: void, lhs: Entry, rhs: Entry) bool { return std.mem.lessThan(u8, lhs.requested, rhs.requested); }
fn canonicalLess(_: void, lhs: *const Entry, rhs: *const Entry) bool { return std.mem.lessThan(u8, lhs.canonical, rhs.canonical); }

pub fn validReference(ref: Reference) !void {
    if (!std.mem.eql(u8, ref.schema, schema) or
        (!std.mem.eql(u8, ref.grammar, grammar) and !std.mem.eql(u8, ref.grammar, caption_grammar) and
            !std.mem.eql(u8, ref.grammar, interwiki_caption_grammar)) or
        ref.bytes < header.len or ref.bytes > max_catalog_bytes or ref.count == 0 or ref.count > max_entries) return invalid();
    if (std.mem.eql(u8, ref.grammar, interwiki_caption_grammar)) {
        _ = try digest(ref.interwiki_sha256 orelse return invalid());
    } else if (ref.interwiki_sha256 != null) return invalid();
    inline for (.{ "sha256", "namespace_sha256", "image_options_sha256", "behavior_switches_sha256",
        "file_metadata_sha256", "source_manifest_sha256", "raw_sha256", "projection_sha256",
        "source_proof_sha256", "feature_source_sha256", "module_selection_sha256" }) |name| _ = try digest(@field(ref, name));
}

pub const Catalog = struct {
    entries: []const Entry,
    options: NS.image_options.Registry,
    ordinary_captions: bool = false,
    interwiki_anchors: ?[]const InterwikiAnchor = null,

    // All surviving strings and the option registry belong to the Book arena.
    // Temporary provider normalization is separately freed, not retained per row.
    pub fn prepare(a: std.mem.Allocator, backing: std.mem.Allocator, ref: Reference, sources: Sources,
        ns: *const NS.Registry) !Catalog
    {
        try validReference(ref);
        if (!std.mem.eql(u8, ns.wiki, "itwiktionary") or sources.catalog.len != ref.bytes or
            sources.file_metadata.len == 0 or sources.file_metadata.len > max_provider_bytes or
            sources.image_options.len == 0 or sources.image_options.len > max_options_bytes or
            sources.behavior_switches.len == 0 or sources.behavior_switches.len > max_behavior_bytes or
            !std.mem.eql(u8, &(try digest(ref.namespace_sha256)), &ns.source_sha256)) return invalid();
        try bound(sources.catalog, ref.sha256);
        try bound(sources.file_metadata, ref.file_metadata_sha256);
        try bound(sources.image_options, ref.image_options_sha256);
        try bound(sources.behavior_switches, ref.behavior_switches_sha256);
        const interwiki_anchors: ?[]const InterwikiAnchor = if (std.mem.eql(u8, ref.grammar, interwiki_caption_grammar))
            try prepareInterwikiAnchors(a, backing, ns, sources.interwiki_map orelse return invalid(),
                ref.interwiki_sha256 orelse return invalid()) else null;
        if (!std.mem.startsWith(u8, sources.catalog, header) or !std.mem.endsWith(u8, sources.catalog, "\n")) return invalid();
        var entries: std.ArrayList(Entry) = .empty;
        var lines = std.mem.splitScalar(u8, sources.catalog[header.len..], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) { if (lines.peek() != null) return invalid(); break; }
            if (entries.items.len == ref.count) return invalid();
            const f = try fields6(line);
            const kind = pair(f[4], f[5]) orelse return invalid();
            if (!lowerHex(f[2], 40) or !timestampValid(f[3])) return invalid();
            const requested = try normalize(a, ns, f[0]);
            const canonical = try normalize(a, ns, f[1]);
            // Skin performs whole-output substring selection. A redirect's
            // canonical title can introduce a trigger absent from input text.
            if (!triggerFree(requested) or !triggerFree(canonical)) return invalid();
            try entries.append(a, .{ .requested = requested, .canonical = canonical,
                .file_sha1 = try a.dupe(u8, f[2]), .timestamp = try a.dupe(u8, f[3]),
                .media = kind, .mime = try a.dupe(u8, f[5]) });
        }
        if (entries.items.len != ref.count) return invalid();
        std.mem.sort(Entry, entries.items, {}, less);
        for (entries.items, 0..) |entry, i| if (i != 0 and std.mem.eql(u8, entry.requested, entries.items[i - 1].requested)) return invalid();
        var result: Catalog = .{ .entries = try entries.toOwnedSlice(a), .options = undefined,
            .ordinary_captions = !std.mem.eql(u8, ref.grammar, grammar),
            .interwiki_anchors = interwiki_anchors };
        var scratch = std.heap.ArenaAllocator.init(backing);
        defer scratch.deinit();
        const aliases = try scratch.allocator().alloc(*const Entry, result.entries.len);
        for (result.entries, 0..) |*entry, i| aliases[i] = entry;
        std.mem.sort(*const Entry, aliases, {}, canonicalLess);
        for (aliases, 0..) |entry, i| {
            if (i == 0 or !std.mem.eql(u8, entry.canonical, aliases[i - 1].canonical)) continue;
            const prior = aliases[i - 1];
            if (entry.media != prior.media or !std.mem.eql(u8, entry.mime, prior.mime) or
                !std.mem.eql(u8, entry.file_sha1, prior.file_sha1) or
                !std.mem.eql(u8, entry.timestamp, prior.timestamp)) return invalid();
        }
        try result.checkProvider(scratch.allocator(), ns, sources.file_metadata);
        // Registry checks namespace/language/date and behavior byte identity.
        result.options = try NS.image_options.Registry.init(a, sources.image_options, ns.wiki,
            ns.dump_date, ns.content_language, ns.source_sha256, try digest(ref.behavior_switches_sha256));
        return result;
    }

    fn index(self: Catalog, title: []const u8) ?usize {
        var lo: usize = 0; var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].requested, title)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }
    // A gallery line has a default File namespace and percent-decoded title.
    // The normal observation still supplies the row/caption and exact redirect
    // outcome. Check that outcome against our independently verified provider.
    pub fn matchesGalleryBitmap(self: Catalog, a: std.mem.Allocator, ns: *const NS.Registry,
        operand: []const u8, requested: []const u8, canonical: []const u8) !bool
    {
        const storage = try a.dupe(u8, operand);
        defer a.free(storage);
        const decoded = std.Uri.percentDecodeInPlace(storage);
        if (!std.unicode.utf8ValidateSlice(decoded) or std.mem.indexOfAny(u8, decoded, "<>[]{}|\t\r\n\x00") != null)
            return false;
        const title = ns.normalizeTitle(a, decoded, 6, .any) catch |err| switch (err) {
            error.InvalidPageTitle => return false,
            else => return err,
        };
        defer a.free(title);
        if (!std.mem.eql(u8, title, requested)) return false;
        const entry = self.entries[self.index(title) orelse return false];
        return entry.media == .bitmap and std.mem.eql(u8, entry.canonical, canonical);
    }

    fn checkProvider(self: Catalog, a: std.mem.Allocator, ns: *const NS.Registry, raw: []const u8) !void {
        const provider_header = "# wikidict-file-metadata-v2\n";
        if (!std.mem.startsWith(u8, raw, provider_header)) return invalid();
        const seen = try a.alloc(bool, self.entries.len); @memset(seen, false);
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        var canonical_targets: std.StringHashMapUnmanaged(usize) = .empty;
        for (self.entries, 0..) |entry, i| try canonical_targets.put(a, entry.canonical, i);
        var lines = std.mem.splitScalar(u8, raw[provider_header.len..], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) { if (lines.peek() != null) return invalid(); break; }
            if (keys.count() == 65536) return invalid();
            const f = try fields6(line);
            const title = try normalize(a, ns, f[0]);
            const key = try keys.getOrPut(a, title); if (key.found_existing) return invalid();
            const exists = if (std.mem.eql(u8, f[1], "1")) true else if (std.mem.eql(u8, f[1], "0")) false else return invalid();
            const width = std.fmt.parseInt(u32, f[2], 10) catch return invalid();
            const height = std.fmt.parseInt(u32, f[3], 10) catch return invalid();
            var canonical: ?[]const u8 = null;
            if (exists) {
                const known_media = for ([_][]const u8{ "UNKNOWN", "BITMAP", "DRAWING", "AUDIO", "VIDEO", "MULTIMEDIA", "OFFICE", "TEXT", "EXECUTABLE", "ARCHIVE", "3D" }) |name| {
                    if (std.mem.eql(u8, f[4], name)) break true;
                } else false;
                if (!known_media) return invalid();
                canonical = try normalize(a, ns, f[5]);
                if (!std.mem.eql(u8, canonical.?, f[5])) return invalid();
            } else if (width != 0 or height != 0 or !std.mem.eql(u8, f[4], "-") or !std.mem.eql(u8, f[5], "-")) return invalid();
            if (self.index(title)) |i| {
                const entry = self.entries[i];
                if (!exists or !std.mem.eql(u8, f[4], mediaName(entry.media)) or
                    !std.mem.eql(u8, canonical.?, entry.canonical)) return invalid();
                seen[i] = true;
            }
            // A canonical file need not have been separately requested. If
            // it was, its provider observation must agree with every alias.
            // Missing or different-media canonical rows are contradictions,
            // not ignorable rows outside the requested-key catalog.
            if (canonical_targets.get(title)) |i| {
                const entry = self.entries[i];
                if (!exists or !std.mem.eql(u8, f[4], mediaName(entry.media)) or
                    !std.mem.eql(u8, canonical.?, entry.canonical)) return invalid();
            }
        }
        for (seen) |found| if (!found) return invalid();
    }

    pub fn classify(self: *const Catalog, a: std.mem.Allocator, ns: *const NS.Registry,
        operand: []const u8) !?Effect
    {
        if (operand.len < 5 or operand.len > 4096 or !std.mem.startsWith(u8, operand, "[[") or
            !std.mem.endsWith(u8, operand, "]]")) return null;
        const body = operand[2 .. operand.len - 2];
        if (!self.ordinary_captions and !plain(body)) return null;
        if (self.ordinary_captions and (captionOperandEnd(operand) orelse return null) != operand.len) return null;
        var tokens: CaptionTokens = .{ .body = body };
        const target = std.mem.trim(u8, tokens.next() orelse return null, " \t");
        if (!plain(target) or ns.ofTitle(target).id != 6) return null;
        const title = ns.normalizeTitle(a, target, 0, .any) catch |err| switch (err) {
            error.InvalidPageTitle => return null,
            else => return err,
        };
        defer a.free(title);
        if (self.index(title) == null) return null;
        var used: u32 = 0;
        var thumbnail = false;
        var width_only = false;
        var bare_upright = false;
        var caption = false;
        var options_count: usize = 0;
        while (tokens.next()) |raw| {
            options_count += 1; if (options_count > 32) return null;
            const token = std.mem.trim(u8, raw, " \t");
            if (self.options.match(token, .image)) |match| {
                const group = optionGroup(match.id) orelse return null;
                const mask = @as(u32, 1) << group;
                // Refuse ambiguous duplicate groups rather than approximating
                // the source parser's first-format/last-width decisions.
                if (used & mask != 0) return null;
                used |= mask;
                if (std.mem.eql(u8, match.id, "img_width")) {
                    const dimensions = match.value orelse return null;
                    if (!widthValid(dimensions)) return null;
                    width_only = std.mem.indexOfScalar(u8, dimensions, 'x') == null;
                } else if (std.mem.eql(u8, match.id, "img_thumbnail")) {
                    thumbnail = true;
                } else if (std.mem.eql(u8, match.id, "img_upright")) {
                    if (!self.ordinary_captions or match.value != null) return null;
                    bare_upright = true;
                }
                if (match.value) |value| {
                    if (self.ordinary_captions and std.mem.eql(u8, match.id, "img_link")) {
                        if (!plain(value) and !ordinaryLinkDestination(value)) return null;
                    } else if (!plain(value)) return null;
                }
            } else {
                // Unsupported handler options must not become benign captions.
                if (self.options.match(token, .timed) != null or self.options.match(token, .svg) != null or
                    self.options.match(token, .paged_tiff_probe) != null or std.mem.indexOfScalar(u8, token, '=') != null or
                    std.mem.endsWith(u8, token, "px") or caption) return null;
                if (self.ordinary_captions and !try captionValid(a, ns, token, self.interwiki_anchors)) return null;
                caption = true;
            }
        }
        // A width-only explicit thumbnail uses its authored width;
        // the bare option adds no thumbnail or media effect.
        if (bare_upright and (!thumbnail or !width_only)) return null;
        return .{ .thumbnail = thumbnail };
    }
};

// A bracket followed only by one to three digits and a space is literal
// caption text. Only the leading caption position can use this boundary.
fn captionLiteralNoteEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '[') return null;
    var end = start + 1;
    while (end < text.len and end - start <= 3 and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == start + 1 or end + 2 >= text.len or text[end] != ']' or text[end + 1] != ' ') return null;
    return end + 1;
}

const empty_caption_small = "<small></small>";

// The retained plain captions have an attribute-free empty SMALL after
// their bold text, followed by a space or the end of the caption.
fn emptyCaptionSmallEnd(text: []const u8, start: usize) ?usize {
    if (start < 3 or !std.mem.eql(u8, text[start - 3 .. start], "'''") or
        !std.mem.startsWith(u8, text[start..], empty_caption_small)) return null;
    const end = start + empty_caption_small.len;
    if (end != text.len and text[end] != ' ' and !std.mem.startsWith(u8, text[end..], "]]")) return null;
    return end;
}

// Extent only: one outer file link and at most one ordinary-link level.
// Classification below still authenticates the file and each caption target.
// Only the exact empty SMALL token is allowed in an outer field.
// Classification still restricts it to plain caption text.
pub fn captionOperandEnd(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, "[[")) return null;
    var depth: u2 = 1;
    var outer_field: ?usize = null;
    var seen_literal_note = false;
    var seen_empty_small = false;
    var i: usize = 2;
    while (i < text.len and i < 4096) {
        switch (text[i]) {
            '[' => {
                if (depth == 1 and !seen_literal_note) if (outer_field) |start| {
                    if (std.mem.trim(u8, text[start..i], " \t").len == 0) {
                        if (captionLiteralNoteEnd(text, i)) |end| {
                            seen_literal_note = true;
                            i = end;
                            continue;
                        }
                    }
                };
                if (depth != 1 or !std.mem.startsWith(u8, text[i..], "[[")) return null;
                depth = 2;
                i += 2;
            },
            ']' => {
                if (!std.mem.startsWith(u8, text[i..], "]]")) return null;
                i += 2;
                depth -= 1;
                if (depth == 0) return if (i <= 4096) i else null;
            },
            '|' => {
                if (depth == 1) outer_field = i + 1;
                i += 1;
            },
            '<' => {
                if (depth != 1 or outer_field == null or seen_empty_small) return null;
                i = emptyCaptionSmallEnd(text, i) orelse return null;
                seen_empty_small = true;
            },
            '>', '{', '}', '\r', '\n', 0 => return null,
            else => i += 1,
        }
    }
    return null;
}

const CaptionTokens = struct {
    body: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn next(self: *CaptionTokens) ?[]const u8 {
        if (self.done) return null;
        const start = self.pos;
        var nested = false;
        while (self.pos < self.body.len) {
            const i = self.pos;
            if (std.mem.startsWith(u8, self.body[i..], "[[")) {
                nested = true;
                self.pos += 2;
            } else if (std.mem.startsWith(u8, self.body[i..], "]]")) {
                nested = false;
                self.pos += 2;
            } else if (self.body[i] == '|' and !nested) {
                self.pos += 1;
                return self.body[start..i];
            } else self.pos += 1;
        }
        self.done = true;
        return self.body[start..];
    }
};

fn captionText(value: []const u8) bool {
    // Quote tokens can emit only B/I markup under this already-expanded inline
    // grammar. Strip apostrophes for a conservative additional trigger check;
    // this does not decode entities or authorize markup/options in alt/link.
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "[]<>{}&%|\r\n\x00") != null or
        std.mem.indexOf(u8, value, "__") != null) return false;
    var storage: [4096]u8 = undefined;
    if (value.len > storage.len) return false;
    var n: usize = 0;
    for (value) |c| {
        if (std.ascii.isControl(c)) return false;
        if (c != '\'') { storage[n] = c; n += 1; }
    }
    var utf8 = (std.unicode.Utf8View.init(value) catch return false).iterator();
    while (utf8.nextCodepoint()) |cp| if ((cp >= 0x80 and cp <= 0x9f) or cp == 0x200e or cp == 0x200f or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return false;
    return triggerFree(value) and triggerFree(storage[0..n]);
}

fn captionPlainSegment(value: []const u8, seen_empty_small: *bool) bool {
    const start = std.mem.indexOfScalar(u8, value, '<') orelse return captionText(value);
    if (seen_empty_small.*) return false;
    const end = emptyCaptionSmallEnd(value, start) orelse return false;
    // Check both plain ranges on their original bytes. In particular, the
    // required space prevents the empty token from joining trigger words.
    if (!captionText(value[0..start]) or !captionText(value[end..])) return false;
    seen_empty_small.* = true;
    return true;
}

fn captionValid(a: std.mem.Allocator, ns: *const NS.Registry, value: []const u8, interwiki: ?[]const InterwikiAnchor) !bool {
    var pos = captionLiteralNoteEnd(value, 0) orelse 0;
    var links: usize = 0;
    var seen_empty_small = false;
    while (std.mem.indexOfAnyPos(u8, value, pos, "[]")) |start| {
        if (!captionPlainSegment(value[pos..start], &seen_empty_small) or !std.mem.startsWith(u8, value[start..], "[[")) return false;
        const close = std.mem.indexOfAnyPos(u8, value, start + 2, "[]") orelse return false;
        if (!std.mem.startsWith(u8, value[close..], "]]")) return false;
        const body = value[start + 2 .. close];
        const pipe = std.mem.indexOfScalar(u8, body, '|') orelse body.len;
        const target = std.mem.trim(u8, body[0..pipe], " \t");
        // Existing grammars retain mainspace-only captions. V3 additionally
        // permits a source-bound, nonlocal, nonlanguage interwiki A branch.
        // Namespace/media, recursive local-wiki and language hooks stay out.
        if (target.len == 0 or !plain(target) or !captionText(target) or std.mem.indexOfAny(u8, target, "#/|=") != null or
            ns.ofTitle(target).id != 0) return false;
        if (std.mem.indexOfScalar(u8, target, ':') != null and
            (interwiki == null or !ordinaryInterwikiTarget(interwiki.?, target))) return false;
        const normalized = ns.normalizeTitle(a, target, 0, .any) catch |err| switch (err) {
            error.InvalidPageTitle => return false,
            else => return err,
        };
        defer a.free(normalized);
        if (ns.ofTitle(normalized).id != 0 or !triggerFree(normalized)) return false;
        // An authenticated interwiki prefix is not part of its remote title.
        // Check the normalized tail so space and underscore padding cannot
        // turn an invalid dot title into an apparent remote anchor.
        if (std.mem.indexOfScalar(u8, normalized, ':')) |colon| {
            const remote_title = std.mem.trim(u8, normalized[colon + 1 ..], " ");
            if (std.mem.eql(u8, remote_title, ".") or std.mem.eql(u8, remote_title, "..")) return false;
        }
        if (pipe < body.len and (body.len == pipe + 1 or !captionText(body[pipe + 1 ..]))) return false;
        links += 1;
        if (links > 32) return false;
        pos = close + 2;
    }
    return captionPlainSegment(value[pos..], &seen_empty_small);
}

// A separate arena lets the existing authoritative map parser validate the
// exact byte body without modifying the caller's immutable namespace registry.
// Only attachInterwikiMap uses this copy; never deinit its borrowed mapper.
fn checkInterwikiSource(backing: std.mem.Allocator, ns: *const NS.Registry, raw: []const u8,
    expected: []const u8) !void
{
    if (raw.len == 0 or raw.len > 4 * 1024 * 1024) return invalid();
    try bound(raw, expected);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        var columns: usize = 0;
        while (fields.next() != null) columns += 1;
        // Six-column legacy maps do not authenticate language-prefix absence.
        if (columns != 7 or count == 10000) return invalid();
        count += 1;
    }
    if (count == 0) return invalid();
    var mirror = ns.*;
    mirror.arena = std.heap.ArenaAllocator.init(backing);
    defer mirror.arena.deinit();
    mirror.interwiki_rows = &.{};
    mirror.interwiki_magic = null;
    try mirror.attachInterwikiMap(raw);
    if (mirror.interwiki_magic == null or mirror.interwiki_magic != ns.interwiki_magic or
        mirror.interwiki_rows.len != ns.interwiki_rows.len) return invalid();
    for (mirror.interwiki_rows, ns.interwiki_rows) |observed, attached| {
        if (!std.mem.eql(u8, observed.prefix, attached.prefix) or
            !std.mem.eql(u8, observed.url, attached.url) or
            observed.is_current_wiki != attached.is_current_wiki or
            observed.is_interlanguage != attached.is_interlanguage) return invalid();
    }
}

const InterwikiAnchor = struct { prefix: []const u8, url: []const u8 };

// Keep the authenticated caption map in the Book arena. NamespaceRegistry's
// projection deliberately drops protorel/trans flags and can be reattached;
// neither discarded flags nor a later caller map can grant an anchor here.
fn prepareInterwikiAnchors(a: std.mem.Allocator, backing: std.mem.Allocator,
    ns: *const NS.Registry, raw: []const u8, expected: []const u8) ![]const InterwikiAnchor
{
    try checkInterwikiSource(backing, ns, raw, expected);
    var anchors: std.ArrayList(InterwikiAnchor) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        var row: [7][]const u8 = undefined;
        for (&row) |*field| field.* = fields.next() orelse return invalid();
        if (fields.next() != null) return invalid();
        // localinterwiki, protorel, transclusion, language: this family has
        // only literal HTTPS remote anchors, without recursive dispatch.
        if (!std.mem.eql(u8, row[2], "0") or !std.mem.eql(u8, row[3], "0") or
            !std.mem.eql(u8, row[4], "0") or !std.mem.eql(u8, row[6], "0")) continue;
        const anchor: InterwikiAnchor = .{ .prefix = row[0], .url = row[5] };
        if (!ordinaryInterwikiAnchor(anchor)) continue;
        try anchors.append(a, .{ .prefix = try a.dupe(u8, anchor.prefix), .url = try a.dupe(u8, anchor.url) });
    }
    return anchors.toOwnedSlice(a);
}

fn ordinaryInterwikiAnchor(entry: InterwikiAnchor) bool {
    if (entry.prefix.len == 0 or !triggerFree(entry.url)) return false;
    for (entry.prefix) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    const scheme = "https://";
    const suffix = "/wiki/$1";
    if (!std.mem.startsWith(u8, entry.url, scheme) or !std.mem.endsWith(u8, entry.url, suffix) or
        entry.url.len <= scheme.len + suffix.len) return false;
    const host = entry.url[scheme.len .. entry.url.len - suffix.len];
    if (host[0] == '.' or host[host.len - 1] == '.' or std.mem.indexOf(u8, host, "..") != null) return false;
    for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    return true;
}

fn ordinaryInterwikiTarget(anchors: []const InterwikiAnchor, target: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    if (colon == 0 or colon + 1 == target.len or
        std.mem.indexOfScalar(u8, target[colon + 1 ..], ':') != null) return false;
    const prefix = target[0..colon];
    for (prefix) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    for (anchors) |entry| {
        if (std.ascii.eqlIgnoreCase(prefix, entry.prefix)) return ordinaryInterwikiAnchor(entry);
    }
    return false;
}

fn optionGroup(id: []const u8) ?u5 {
    for ([_][]const u8{ "img_left", "img_right", "img_center", "img_none" }) |v| if (std.mem.eql(u8, id, v)) return 0;
    for ([_][]const u8{ "img_baseline", "img_sub", "img_super", "img_top", "img_text_top", "img_middle", "img_bottom", "img_text_bottom" }) |v| if (std.mem.eql(u8, id, v)) return 1;
    for ([_][]const u8{ "img_thumbnail", "img_framed", "img_frameless" }) |v| if (std.mem.eql(u8, id, v)) return 2;
    if (std.mem.eql(u8, id, "img_border")) return 3;
    if (std.mem.eql(u8, id, "img_width")) return 4;
    if (std.mem.eql(u8, id, "img_alt")) return 5;
    if (std.mem.eql(u8, id, "img_link")) return 6;
    if (std.mem.eql(u8, id, "img_upright")) return 7;
    return null;
}

fn ordinaryLinkDestination(value: []const u8) bool {
    // A single literal query separator in the authenticated normal route.
    // No URL/entity decoding, aliases, extra query, or caption/alt permission.
    // This modifies navigation only; the separately authenticated file still
    // selects the IMAGE handler before the anchor destination is applied.
    const prefix = "//it.wiktionary.org/w/index.php?title=";
    const suffix = "&uselang=it";
    if (!std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, suffix) or
        value.len <= prefix.len + suffix.len or !triggerFree(value) or
        std.mem.indexOf(u8, value, "__") != null) return false;
    const title = value[prefix.len .. value.len - suffix.len];
    var pieces = std.mem.splitScalar(u8, title, ':');
    var count: usize = 0;
    while (pieces.next()) |piece| {
        count += 1;
        if (count > 2 or piece.len == 0 or !std.ascii.isAlphabetic(piece[0])) return false;
        for (piece) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return count == 2;
}
fn widthValid(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, 'x');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1; if (count > 2 or part.len == 0 or part.len > 6) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        const value = std.fmt.parseInt(u32, part, 10) catch return false;
        if (value == 0 or value > 100000) return false;
    }
    return count != 0;
}
fn plain(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "[]<>{}&%\r\n\x00") != null or
        std.mem.indexOf(u8, value, "''") != null or std.mem.indexOf(u8, value, "__") != null) return false;
    for (value) |c| if (std.ascii.isControl(c)) return false;
    // Title normalization strips bidi controls. Do not erase disallowed
    // operand syntax before deciding membership in this literal grammar.
    var utf8 = (std.unicode.Utf8View.init(value) catch return false).iterator();
    while (utf8.nextCodepoint()) |cp| if (cp == 0x200e or cp == 0x200f or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return false;
    return triggerFree(value);
}
fn triggerFree(value: []const u8) bool {
    for ([_][]const u8{ "sortable", "mw-ui-button", "mw-message-box", "floatright", "floatleft", "thumbinner", "mw-tempuserlink", "cdx-message" }) |word|
        if (std.ascii.findIgnoreCase(value, word) != null) return false;
    return true;
}
