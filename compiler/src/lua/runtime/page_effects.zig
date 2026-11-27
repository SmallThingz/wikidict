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
pub const Identity = struct { title: []const u8, namespace: i32, page_id: u64, revision_id: u64 };
pub const LiteralState = struct { ordinary_open: bool = false, quote: u8 = 0 };

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
    seen: [4]bool = @splat(false),
    styles: std.ArrayList(StyleOperand) = .empty,
    operand_bytes: usize = 0,
    scan_depth: usize = 0,

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
        const names = [_][]const u8{ "nowiki", "pre", "poem", "templatestyles" };
        const index = for (names, 0..) |tag, i| {
            if (std.ascii.eqlIgnoreCase(name, tag)) break i;
        } else { self.reject(); return; };
        self.seen[index] = true;
        if (!attrs_supported) { self.reject(); return; }
        if (index != 3) return;
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
            const end = preprocess.rawTagEnd(text, at) orelse { self.reject(); return; };
            // Do not grant opaque-body authority if the native decoded parser
            // would terminate this opener earlier than this quote-aware reader.
            if ((preprocess.decodedTagEnd(text, at) orelse { self.reject(); return; }) != end) { self.reject(); return; }
            const trimmed = std.mem.trimEnd(u8, text[p .. end - 1], " \t\r\n");
            const self_close = trimmed.len != 0 and trimmed[trimmed.len - 1] == '/';
            const attrs = if (self_close) trimmed[0 .. trimmed.len - 1] else trimmed;
            if (std.ascii.eqlIgnoreCase(name, "templatestyles")) self.literalStyle(a, attrs, origin)
            else self.extension(a, name, null, std.mem.trim(u8, attrs, " \t\r\n").len == 0, origin);
            if (!self.active()) return;
            if (self_close) { i = end; continue; }
            const region_end = preprocess.opaqueParserRegionEnd(text, at) orelse { self.reject(); return; };
            if (region_end <= end) { self.reject(); return; }
            if (std.ascii.eqlIgnoreCase(name, "poem")) {
                const close = std.mem.lastIndexOfScalar(u8, text[0..region_end], '<') orelse { self.reject(); return; };
                if (close < end) { self.reject(); return; }
                self.scanComplete(a, text[end..close], origin);
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
        var bound: usize = 2048 + 6 * identity.title.len;
        for (self.styles.items) |item| {
            bound += 128 + 6 * item.src.len;
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
        const names = [_][]const u8{ "nowiki", "pre", "poem", "templatestyles" };
        var seen: [4][]const u8 = undefined;
        var count: usize = 0;
        for (names, self.seen) |name, yes| if (yes) { seen[count] = name; count += 1; };
        const record = .{
            .schema = schema,
            .status = "complete",
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
        const bytes = std.json.Stringify.valueAlloc(a, record, .{}) catch { self.reject(); return null; };
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
