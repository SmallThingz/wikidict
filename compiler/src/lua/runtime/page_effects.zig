const std = @import("std");
const preprocess = @import("lua_wikitext_preprocess");

// This is an expansion observation, not a normal ParserOutput/module receipt.
// The consumer pairs it with the qualified hook/module rules and final placement.
pub const schema = "wikidict.page-effects.v1";
pub const max_metadata_bytes = 64 * 1024;
pub const max_operations = 4096;
pub const max_style_operands = 128;
pub const max_operand_bytes = 16 * 1024;
pub const max_scan_bytes = 64 * 1024 * 1024;
pub const Origin = enum { extension_call, literal_input, preprocess_result, expanded_output, display_title };
pub const StyleOperand = struct { src: []const u8, origin: Origin };
pub const LiteralAngleCandidate = struct { token: []const u8, origin: Origin };
pub const Identity = struct { title: []const u8, namespace: i32, page_id: u64, revision_id: u64 };
pub const LiteralState = struct { ordinary_open: bool = false, quote: u8 = 0 };

const extension_names = [_][]const u8{ "nowiki", "pre", "poem", "templatestyles", "ref", "references" };

fn isCiteExtension(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "ref") or std.ascii.eqlIgnoreCase(name, "references");
}

fn ordinaryTag(name: []const u8) bool {
    inline for (&.{ "a", "abbr", "b", "bdi", "bdo", "big", "blockquote", "br", "caption", "center", "cite", "code", "dd", "del", "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "ins", "kbd", "li", "mark", "ol", "p", "q", "rb", "rp", "rt", "rtc", "ruby", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "wbr" }) |tag|
        if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn safeOperand(s: []const u8) bool {
    if (s.len == 0 or s.len > 1024 or !std.unicode.utf8ValidateSlice(s)) return false;
    for (s) |c| if (c < 0x20 or c == 0x7f or c == '&' or c == '<' or c == '>' or c == '\\') return false;
    return true;
}

pub const Collector = struct {
    generation: ?u64 = null,
    unknown: bool = false,
    operations: usize = 0,
    scan_bytes: usize = 0,
    seen: [extension_names.len]bool = @splat(false),
    styles: std.ArrayList(StyleOperand) = .empty,
    operand_bytes: usize = 0,
    scan_depth: usize = 0,
    cite_depth: usize = 0,
    gallery_literal: ?[32]u8 = null,
    gallery_span: ?struct { start: usize, end: usize } = null,
    literal_angle_candidates: std.ArrayList(LiteralAngleCandidate) = .empty,
    literal_angle_bytes: usize = 0,

    fn sawCite(self: *const @This()) bool {
        for (extension_names, self.seen) |name, observed| {
            if (observed and isCiteExtension(name)) return true;
        }
        return false;
    }

    fn observeLiteralAngle(self: *@This(), a: std.mem.Allocator, token: []const u8, origin: Origin) void {
        if (self.sawCite()) { self.reject(); return; }
        for (self.literal_angle_candidates.items) |held| {
            if (held.origin == origin and std.mem.eql(u8, held.token, token)) return;
        }
        if (self.literal_angle_candidates.items.len == 128 or token.len > 16 * 1024 - self.literal_angle_bytes) {
            self.reject(); return;
        }
        const held = a.dupe(u8, token) catch { self.reject(); return; };
        self.literal_angle_candidates.append(a, .{ .token = held, .origin = origin }) catch { self.reject(); return; };
        self.literal_angle_bytes += token.len;
    }

    // Storage is page-arena owned. A new page discards all previous observations.
    pub fn begin(self: *@This(), generation: ?u64) void {
        self.* = .{ .generation = generation };
    }

    pub fn reject(self: *@This()) void {
        if (self.generation != null) self.unknown = true;
    }

    fn active(self: *const @This()) bool {
        return self.generation != null and !self.unknown;
    }

    pub fn ordinary(self: *@This(), name: []const u8) void {
        if (self.active() and !ordinaryTag(name)) self.reject();
    }

    pub fn extension(self: *@This(), a: std.mem.Allocator, name: []const u8, src: ?[]const u8, attrs_supported: bool, origin: Origin) void {
        if (!self.active()) return;
        if (self.operations == max_operations) { self.reject(); return; }
        self.operations += 1;
        const index = for (extension_names, 0..) |tag, i| {
            if (std.ascii.eqlIgnoreCase(name, tag)) break i;
        } else { self.reject(); return; };
        // Cite is observed explicitly, never classified as an inactive hook.
        // Only the bounded no-attribute final forms below are accepted. Nested
        // Cite needs a separate ownership model; do not grant it by recursion.
        if (isCiteExtension(name) and
            (origin == .extension_call or self.cite_depth != 0 or self.gallery_literal != null or
                self.literal_angle_candidates.items.len != 0))
        {
            self.reject();
            return;
        }
        self.seen[index] = true;
        if (!attrs_supported) { self.reject(); return; }
        if (!std.ascii.eqlIgnoreCase(name, "templatestyles")) return;
        const value = src orelse { self.reject(); return; };
        if (!attrs_supported or !safeOperand(value)) { self.reject(); return; }
        // This is a set of observed operands/origins, NOT emission/dedup order.
        for (self.styles.items) |old| if (old.origin == origin and std.mem.eql(u8, old.src, value)) return;
        if (self.styles.items.len == max_style_operands or value.len > max_operand_bytes - self.operand_bytes) { self.reject(); return; }
        const held = a.dupe(u8, value) catch { self.reject(); return; };
        self.styles.append(a, .{ .src = held, .origin = origin }) catch { self.reject(); return; };
        self.operand_bytes += value.len;
    }

    fn literalStyle(self: *@This(), a: std.mem.Allocator, attrs: []const u8, origin: Origin) void {
        var i: usize = 0;
        var src: ?[]const u8 = null;
        while (i < attrs.len) {
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            if (i == attrs.len) break;
            const start = i;
            while (i < attrs.len and std.ascii.isAlphanumeric(attrs[i])) : (i += 1) {}
            if (i == start or !std.ascii.eqlIgnoreCase(attrs[start..i], "src") or src != null) { self.reject(); return; }
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            if (i == attrs.len or attrs[i] != '=') { self.reject(); return; }
            i += 1;
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            if (i == attrs.len or (attrs[i] != '"' and attrs[i] != '\'')) { self.reject(); return; }
            const quote = attrs[i]; i += 1;
            const value = i;
            while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
            if (i == attrs.len) { self.reject(); return; }
            src = attrs[value..i]; i += 1;
            if (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) { self.reject(); return; }
        }
        self.extension(a, "templatestyles", src, true, origin);
    }

    // Carry the exact syntax to a module-aware producer. This path supplies
    // operands only, never a complete module list or a successful media fact.
    fn observeLiteralGallery(self: *@This(), text: []const u8, at: usize, origin: Origin) ?usize {
        if (self.sawCite()) return null;
        const opening = "<gallery>\n";
        const closing = "\n</gallery>";
        if (!std.mem.startsWith(u8, text[at..], opening)) return null;
        const d = preprocess.opaqueParserRegionEnd(text, at) orelse return null;
        const region = text[at..d];
        if (region.len > 16384 or region.len <= opening.len + closing.len or
            !std.mem.endsWith(u8, region, closing)) return null;
        const body = region[opening.len .. region.len - closing.len];
        if (!std.unicode.utf8ValidateSlice(body) or std.mem.indexOfAny(u8, body, "<>{}\r\x00") != null) return null;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            const pipe = std.mem.indexOfScalar(u8, line, '|') orelse return null;
            if (pipe == 0 or line.len > 4096 or count == 128) return null;
            count += 1;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(region, &digest, .{});
        if (self.operations == max_operations) return null;
        switch (origin) {
            .literal_input => {
                if (self.scan_depth != 0 or self.gallery_literal != null) return null;
                self.gallery_literal = digest;
            },
            .expanded_output => {
                const observed = self.gallery_literal orelse return null;
                if (self.scan_depth != 1 or self.gallery_span != null or
                    !std.mem.eql(u8, &digest, &observed)) return null;
                self.gallery_span = .{ .start = at, .end = d };
            },
            else => return null,
        }
        self.operations += 1;
        return d;
    }

    // Called on actual literal dispatch slices; branches not evaluated are not
    // scanned. Ordinary opening attributes may straddle child substitutions.
    // Extension attributes/regions must be complete in the authoritative slice.
    pub fn scan(self: *@This(), a: std.mem.Allocator, text: []const u8, state: *LiteralState, origin: Origin) void {
        if (!self.active()) return;
        if (text.len > max_scan_bytes - self.scan_bytes) { self.reject(); return; }
        self.scan_bytes += text.len;
        var i: usize = 0;
        while (i < text.len and self.active()) {
            if (state.ordinary_open) {
                const c = text[i]; i += 1;
                if (state.quote != 0) { if (c == state.quote) state.quote = 0; }
                else if (c == '"' or c == '\'') { state.quote = c; }
                else if (c == '>') { state.ordinary_open = false; }
                continue;
            }
            const at = std.mem.indexOfScalarPos(u8, text, i, '<') orelse break;
            if (std.mem.startsWith(u8, text[at..], "<!--")) {
                const end = std.mem.indexOfPos(u8, text, at + 4, "-->") orelse { self.reject(); return; };
                i = end + 3; continue;
            }
            // Literal dispatch is observed before parsing-text cleanup. Reuse
            // its exact empty inclusion-boundary predicate; this is no hook.
            // Other origins remain conservative, and opaque bodies were skipped
            // by their outer region before this position can be reached.
            if (origin == .literal_input) {
                if (preprocess.parsingBoundaryEnd(text, at)) |end| {
                    i = end;
                    continue;
                }
            }
            if (origin != .display_title and origin != .extension_call) {
                if (preprocess.literalDoubleAngleProseEnd(text, at)) |end| {
                    self.observeLiteralAngle(a, text[at..end], origin);
                    i = end;
                    continue;
                }
            }
            var p = at + 1;
            const closing = p < text.len and text[p] == '/';
            if (closing) p += 1;
            if (p == text.len or !std.ascii.isAlphabetic(text[p])) { i = at + 1; continue; }
            const start = p;
            while (p < text.len and (std.ascii.isAlphanumeric(text[p]) or text[p] == '-' or text[p] == ':' or text[p] == '_')) : (p += 1) {}
            if (p == start) { i = at + 1; continue; }
            if (p == text.len or !(std.ascii.isWhitespace(text[p]) or text[p] == '/' or text[p] == '>')) { self.reject(); return; }
            const name = text[start..p];
            if (closing or ordinaryTag(name)) {
                if (!closing) self.ordinary(name);
                state.ordinary_open = true;
                i = p;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "gallery")) {
                i = self.observeLiteralGallery(text, at, origin) orelse { self.reject(); return; };
                continue;
            }
            const end = preprocess.rawTagEnd(text, at) orelse { self.reject(); return; };
            // Do not grant opaque-body authority if the native decoded parser
            // would terminate this opener earlier than this quote-aware reader.
            if ((preprocess.decodedTagEnd(text, at) orelse { self.reject(); return; }) != end) { self.reject(); return; }
            const trimmed = std.mem.trimEnd(u8, text[p .. end - 1], " \t\r\n");
            const self_close = trimmed.len != 0 and trimmed[trimmed.len - 1] == '/';
            const attrs = if (self_close) trimmed[0 .. trimmed.len - 1] else trimmed;
            const cite_ref = std.ascii.eqlIgnoreCase(name, "ref");
            const cite_references = std.ascii.eqlIgnoreCase(name, "references");
            // Bounded literal Cite: a closed nonempty note, and an empty
            // self-closing references sink. Named/grouped/list-defined forms
            // remain unsupported; extension() also rejects any attributes.
            if ((cite_ref and self_close) or (cite_references and !self_close)) { self.reject(); return; }
            if (std.ascii.eqlIgnoreCase(name, "templatestyles")) self.literalStyle(a, attrs, origin)
            else self.extension(a, name, null, std.mem.trim(u8, attrs, " \t\r\n").len == 0, origin);
            if (!self.active()) return;
            if (self_close) { i = end; continue; }
            const region_end = preprocess.opaqueParserRegionEnd(text, at) orelse { self.reject(); return; };
            if (region_end <= end) { self.reject(); return; }
            if (std.ascii.eqlIgnoreCase(name, "poem") or cite_ref) {
                const close = std.mem.lastIndexOfScalar(u8, text[0..region_end], '<') orelse { self.reject(); return; };
                if (close < end) { self.reject(); return; }
                const body = text[end..close];
                if (cite_ref and std.mem.trim(u8, body, " \t\r\n").len == 0) { self.reject(); return; }
                // Native Cite keeps note contents active. Scan them with the
                // same budgets/opaque rules; never hide gallery/unknown hooks.
                if (cite_ref) self.cite_depth += 1;
                defer {
                    if (cite_ref) self.cite_depth -= 1;
                }
                self.scanComplete(a, body, origin);
            }
            // nowiki/pre bodies are not extension inputs. Poem contents above
            // remain conservative even for a generated, unprocessed return.
            i = region_end;
        }
    }

    pub fn scanComplete(self: *@This(), a: std.mem.Allocator, text: []const u8, origin: Origin) void {
        if (!self.active()) return;
        if (self.scan_depth == 16) { self.reject(); return; }
        self.scan_depth += 1;
        defer self.scan_depth -= 1;
        var state: LiteralState = .{};
        self.scan(a, text, &state, origin);
        if (state.ordinary_open) self.reject();
    }

    pub fn finish(self: *@This(), a: std.mem.Allocator, identity: Identity, source: []const u8, expanded: []const u8, display_title: []const u8) ?[]const u8 {
        if (!self.active() or identity.page_id == 0 or identity.revision_id == 0 or identity.title.len == 0 or
            identity.title.len > 4096 or !std.unicode.utf8ValidateSlice(identity.title)) return null;
        self.scanComplete(a, expanded, .expanded_output);
        self.scanComplete(a, display_title, .display_title);
        if (!self.active()) return null;
        if (self.gallery_literal != null and self.literal_angle_candidates.items.len != 0) { self.reject(); return null; }
        var bound: usize = 2048 + 6 * identity.title.len;
        for (self.styles.items) |item| {
            bound += 128 + 6 * item.src.len;
            if (bound > max_metadata_bytes) { self.reject(); return null; }
        }
        for (self.literal_angle_candidates.items) |item| {
            bound += 128 + 6 * item.token.len;
            if (bound > max_metadata_bytes) { self.reject(); return null; }
        }
        if (bound > max_metadata_bytes) { self.reject(); return null; }
        var hashes: [3][32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &hashes[0], .{});
        std.crypto.hash.sha2.Sha256.hash(expanded, &hashes[1], .{});
        std.crypto.hash.sha2.Sha256.hash(display_title, &hashes[2], .{});
        const raw_hex = std.fmt.bytesToHex(hashes[0], .lower);
        const expanded_hex = std.fmt.bytesToHex(hashes[1], .lower);
        const display_hex = std.fmt.bytesToHex(hashes[2], .lower);
        var seen: [extension_names.len][]const u8 = undefined;
        var count: usize = 0;
        for (extension_names, self.seen) |name, yes| if (yes) { seen[count] = name; count += 1; };
        const record = .{
            .schema = schema,
            .status = if (self.gallery_literal != null) @as([]const u8, "operands_only") else "complete",
            .collector = "native-executed-extensions.v1",
            .generation = self.generation.?,
            .identity = identity,
            .source_sha256 = @as([]const u8, &raw_hex),
            .expanded_sha256 = @as([]const u8, &expanded_hex),
            .display_title_sha256 = @as([]const u8, &display_hex),
            .operation_count = self.operations,
            .observed_extensions = seen[0..count],
            .template_styles = self.styles.items,
            .placement = @as(?bool, null),
        };
        const bytes = if (self.gallery_literal) |digest| gallery: {
            const span = self.gallery_span orelse return null;
            const operand = expanded[span.start..span.end];
            const raw_start = std.mem.indexOf(u8, source, operand) orelse return null;
            if (std.mem.indexOfPos(u8, source, raw_start + 1, operand) != null) return null;
            // Old consumers require complete v1 records; keep this envelope
            // distinguishable even if a JSON reader ignores unknown fields.
            break :gallery std.json.Stringify.valueAlloc(a, .{
                .schema = "wikidict.page-effects.literal-gallery.v1",
                .status = "operands_only",
                .phase = record,
                .gallery = .{
                    .raw_start = raw_start, .expanded_start = span.start,
                    .bytes = operand.len, .sha256 = &std.fmt.bytesToHex(digest, .lower),
                },
            }, .{}) catch { self.reject(); return null; };
        } else if (self.literal_angle_candidates.items.len == 0)
            std.json.Stringify.valueAlloc(a, record, .{}) catch { self.reject(); return null; }
        else std.json.Stringify.valueAlloc(a, .{
            .schema = record.schema,
            .status = "literal-angle-authority-required",
            .collector = record.collector,
            .generation = record.generation,
            .identity = record.identity,
            .source_sha256 = record.source_sha256,
            .expanded_sha256 = record.expanded_sha256,
            .display_title_sha256 = record.display_title_sha256,
            .operation_count = record.operation_count,
            .observed_extensions = record.observed_extensions,
            .template_styles = record.template_styles,
            .placement = record.placement,
            .literal_angle_candidates = self.literal_angle_candidates.items,
        }, .{}) catch { self.reject(); return null; };
        if (bytes.len > max_metadata_bytes) { a.free(bytes); self.reject(); return null; }
        return bytes;
    }
};

const test_identity: Identity = .{ .title = "casa", .namespace = 0, .page_id = 742, .revision_id = 4257826 };

test "page effects collector requires enabled generation and resets unknown and borrowed observations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Collector = .{};
    try std.testing.expect(c.finish(a, test_identity, "raw", "expanded", "") == null);
    c.begin(1);
    c.extension(a, "gallery", null, true, .extension_call);
    try std.testing.expect(c.finish(a, test_identity, "raw", "expanded", "") == null);
    c.begin(2);
    try std.testing.expect(c.finish(a, test_identity, "raw", "expanded", "") != null);
    c.begin(0); // The first request ordinal is a valid generation, not absence.
    try std.testing.expect(c.finish(a, test_identity, "raw", "expanded", "") != null);
    c.begin(null);
    try std.testing.expect(c.finish(a, test_identity, "raw", "expanded", "") == null);
}

test "page effects literal reader separates opaque text attributes ordinary tags and nested poem effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Collector = .{};
    c.begin(3);
    c.scanComplete(a, "<!--<gallery/>--><nowiki><gallery/></nowiki><pre><ref>x</ref></pre><i>x</i><table><tr><td>x</td></tr></table>", .literal_input);
    try std.testing.expect(!c.unknown);
    var state: LiteralState = .{};
    c.scan(a, "<span title=\"<gallery/>", &state, .literal_input);
    try std.testing.expect(state.ordinary_open);
    c.scan(a, "\">text</span>", &state, .literal_input);
    try std.testing.expect(!state.ordinary_open and !c.unknown);
    c.scanComplete(a, "<poem><gallery/></poem>", .expanded_output);
    try std.testing.expect(c.unknown);
}

test "page effects operation scan and operand limits fail closed without fabricated empty record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Collector = .{};
    c.begin(4);
    for (0..max_operations) |_| c.extension(a, "pre", null, true, .extension_call);
    try std.testing.expect(!c.unknown);
    c.extension(a, "pre", null, true, .extension_call);
    try std.testing.expect(c.unknown);
    try std.testing.expect(c.finish(a, test_identity, "raw", "text", "") == null);
    c.begin(5);
    c.scan_bytes = max_scan_bytes;
    c.scanComplete(a, "x", .literal_input);
    try std.testing.expect(c.unknown);
    c.begin(6);
    for (0..max_style_operands + 1) |i| {
        const src = try std.fmt.allocPrint(a, "Template:Style{d}.css", .{i});
        c.extension(a, "templatestyles", src, true, .extension_call);
    }
    try std.testing.expect(c.unknown);
    try std.testing.expect(c.finish(a, test_identity, "raw", "text", "") == null);
}

test "page effects serialized metadata observes 64 KiB ceiling and strict TS operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Collector = .{};
    c.begin(7);
    const padding: [100]u8 = @splat('a');
    for (0..max_style_operands) |i| {
        const src = try std.fmt.allocPrint(a, "{s}{d}.css", .{ &padding, i });
        c.extension(a, "templatestyles", src, true, .extension_call);
    }
    try std.testing.expect(!c.unknown);
    try std.testing.expect(c.finish(a, test_identity, "raw", "text", "") == null);
    try std.testing.expect(c.unknown);
    for ([_][]const u8{
        "<templatestyles src='Mbox/common.css' wrapper='.x'/>",
        "<templatestyles src='Mbox/common.css' bad='x'/>",
        "<templatestyles src='Mbox/common.css' src='Ambox/styles.css'/>",
        "<templatestyles src='Mbox/common.css'", "<unregistered-extension/>",
    }) |source| {
        c.begin(8);
        c.scanComplete(a, source, .literal_input);
        try std.testing.expect(c.unknown);
    }
    c.begin(9);
    c.scanComplete(a, "<templatestyles src='Mbox/common.css' />", .literal_input);
    const bytes = c.finish(a, test_identity, "raw", "text", "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bytes.len <= max_metadata_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("placement").? == .null);
}

test "page effects parsing boundary collector keeps omitted nodes distinct from extension effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Collector = .{};
    // Use the real preprocessing producer, not a guessed sentinel spelling.
    const prepared = try preprocess.transcludeDecodedForParsingAlloc(a, "A<noinclude>excluded</noinclude>B");
    try std.testing.expectEqualStrings("A<noinclude/>B", prepared);
    c.begin(72);
    c.scanComplete(a, prepared, .literal_input);
    const metadata = c.finish(a, test_identity, "raw", "AB", "");
    std.debug.print("boundary-collector: receipt_present={any} unknown={any}\n", .{ metadata != null, c.unknown });
    try std.testing.expect(metadata != null);
    try std.testing.expectEqual(@as(usize, 0), c.operations);
    for (c.seen) |seen| try std.testing.expect(!seen);

    for ([_][]const u8{ "<noinclude/>", "<NoInclude/>", "<noinclude />", "<noinclude attr=x/>" }) |boundary| {
        try std.testing.expectEqual(@as(?usize, boundary.len), preprocess.parsingBoundaryEnd(boundary, 0));
        c.begin(73);
        c.scanComplete(a, boundary, .literal_input);
        try std.testing.expect(!c.unknown and c.operations == 0);
    }
    // This exception belongs only to pre-cleanup literal dispatch.
    for ([_]Origin{ .preprocess_result, .expanded_output, .display_title }) |origin| {
        c.begin(74);
        c.scanComplete(a, "<noinclude/>", origin);
        try std.testing.expect(c.unknown);
    }
    // Unknown extensions are still observed before/after an omitted boundary.
    for ([_][]const u8{
        "<noinclude/><gallery/>", "<gallery/><noinclude/>",
        "<noinclude/><unknown-extension/>", "<noinclude>body</noinclude>",
        "<noinclude", "<noinclude/", "<noincludeX/>",
    }) |bad| {
        c.begin(75);
        c.scanComplete(a, bad, .literal_input);
        try std.testing.expect(c.unknown);
        try std.testing.expect(c.finish(a, test_identity, "raw", "AB", "") == null);
    }
    c.begin(76);
    c.extension(a, "noinclude", null, true, .extension_call);
    try std.testing.expect(c.unknown);

    // Opaque bodies retain literal marker/extension text and their hook count.
    c.begin(77);
    const opaque_text = "<nowiki><noinclude/><gallery/></nowiki><pre><noinclude/><gallery/></pre>";
    c.scanComplete(a, opaque_text, .literal_input);
    try std.testing.expect(!c.unknown and c.operations == 2 and c.seen[0] and c.seen[1]);
    var plain: std.ArrayList(u8) = .empty;
    try preprocess.appendParsingText(a, &plain, opaque_text);
    try std.testing.expectEqualStrings(opaque_text, plain.items);
    c.scanComplete(a, "<poem><noinclude/><gallery/></poem>", .literal_input);
    try std.testing.expect(c.unknown);

    // A marker-looking substring in an ordinary quoted attribute is inert.
    c.begin(78);
    var state: LiteralState = .{};
    c.scan(a, "<span title=\"<noinclude/>", &state, .literal_input);
    try std.testing.expect(state.ordinary_open and state.quote == '"');
    c.scan(a, "\">AB</span>", &state, .literal_input);
    try std.testing.expect(!state.ordinary_open and !c.unknown and c.operations == 0);
    c.begin(79);
    c.scan_bytes = max_scan_bytes;
    c.scanComplete(a, "<noinclude/>", .literal_input);
    try std.testing.expect(c.unknown);
    std.debug.print("boundary-collector: phase-opacity-unknown-budget-negatives=pass\n", .{});
}
