//! Build-only join of an explicitly selected, replayed stylesheet snapshot.
//! No fetching, CSS execution or reader dependency is introduced here.
const std = @import("std");
const styles = @import("encoder").table_style_profile;
const A = std.mem.Allocator;
const leaf_url = "https://www.mediawiki.org/w/index.php?title=MediaWiki:Gadget-enwp-boxes.css&action=raw&ctype=text/css";
const root_url = "https://pt.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css";
pub const max_snapshot_bytes = 2 * 1024 * 1024;

pub const Root = struct {
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    page_id: u64,
    revision_id: u64,
};
pub const Proof = struct {
    snapshot_sha256: [64]u8,
    resource_sha256: [64]u8,
    page_id: u64,
    revision_id: u64,
    url: []const u8 = leaf_url,
    joined: bool,
    sources: []const styles.SourceRange = &.{},
    pub fn jsonStringify(self: Proof, jw: anytype) !void {
        try jw.write(.{ .schema = "wikidict.stylesheet-import-join.v1",
            .snapshot_sha256 = self.snapshot_sha256[0..], .resource_sha256 = self.resource_sha256[0..],
            .page_id = self.page_id, .revision_id = self.revision_id, .url = self.url, .joined = self.joined, .sources = self.sources });
    }
};
pub const Joined = struct { profile: styles.Profile, proof: Proof };
const Snapshot = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    root_css_sha256: []const u8,
    root_page_id: u64,
    root_revision_id: u64,
    import: struct { start: usize, end: usize, authored_url: []const u8, resolved_url: []const u8 },
    resource: struct {
        url: []const u8,
        base_url: []const u8,
        css_bytes: usize,
        css_sha256: []const u8,
        css: []const u8,
        revision: struct {
            wiki: []const u8,
            title: []const u8,
            page_id: u64,
            revision_id: u64,
            revision_timestamp: []const u8,
            content_model: []const u8,
            source_sha1: []const u8,
        },
    },
};
fn sha256(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn skipSpaceComments(css: []const u8, start: usize) ?usize {
    var at = start;
    while (at < css.len) {
        if (std.mem.indexOfScalar(u8, " \t\r\n\x0c", css[at]) != null) {
            at += 1;
        } else if (std.mem.startsWith(u8, css[at..], "/*")) {
            at = (std.mem.indexOfPos(u8, css, at + 2, "*/") orelse return null) + 2;
        } else break;
    }
    return at;
}
fn firstImportMatches(css: []const u8, selected: Snapshot) bool {
    const import = selected.import;
    if (import.start >= import.end or import.end > css.len or
        (skipSpaceComments(css, 0) orelse return false) != import.start) return false;
    var at = import.start;
    if (css.len - at < 8 or !std.ascii.eqlIgnoreCase(css[at..][0..7], "@import") or
        std.mem.indexOfScalar(u8, " \t\r\n\x0c", css[at + 7]) == null) return false;
    at = skipSpaceComments(css, at + 7) orelse return false;
    if (at >= css.len or (css[at] != '"' and css[at] != '\'')) return false;
    const quote = css[at];
    at += 1;
    const begin = at;
    while (at < css.len and css[at] != quote) : (at += 1) {
        if (css[at] < 32 or css[at] == '\\') return false;
    }
    if (at >= css.len or !std.mem.eql(u8, css[begin..at], import.authored_url)) return false;
    at = skipSpaceComments(css, at + 1) orelse return false;
    return at < css.len and css[at] == ';' and at + 1 == import.end and
        (std.mem.eql(u8, import.authored_url, leaf_url) or
        std.mem.eql(u8, import.authored_url, leaf_url[6..])) and
        std.mem.eql(u8, import.resolved_url, leaf_url);
}
fn flatLeaf(css: []const u8) bool {
    // A bounded initial domain: no imported at-rules, conditional groups,
    // charset/namespace scopes or cycles. Comments and quoted strings do not
    // manufacture dependency edges. Unsupported leaves retain the root import.
    var at: usize = 0;
    while (at < css.len) {
        if (std.mem.startsWith(u8, css[at..], "/*")) {
            at = (std.mem.indexOfPos(u8, css, at + 2, "*/") orelse return false) + 2;
        } else if (css[at] == '"' or css[at] == '\'') {
            const quote = css[at];
            at += 1;
            while (at < css.len and css[at] != quote) {
                if (css[at] == '\\') {
                    if (at + 1 >= css.len) return false;
                    at += 2;
                } else at += 1;
            }
            if (at == css.len) return false;
            at += 1;
        } else {
            if (css[at] == '@') return false;
            at += 1;
        }
    }
    return true;
}

pub fn joinAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8) !Joined {
    if (snapshot_bytes.len > max_snapshot_bytes) return error.InvalidStylesheetImports;
    const parsed = try std.json.parseFromSlice(Snapshot, a, snapshot_bytes, .{});
    defer parsed.deinit();
    const value = parsed.value;
    const resource = value.resource;
    const revision = resource.revision;
    const root_hash = sha256(root_css);
    const leaf_hash = sha256(resource.css);
    var sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(resource.css, &sha1, .{});
    const expected_base = try std.fmt.allocPrint(a, "{s}&oldid={d}", .{ leaf_url, revision.revision_id });
    defer a.free(expected_base);
    if (!std.mem.eql(u8, value.schema, "wikidict.stylesheet-imports.v1") or
        !std.mem.eql(u8, value.wiki, root.wiki) or !std.mem.eql(u8, value.dump_date, root.dump_date) or
        !std.mem.eql(u8, value.namespace_sha256, root.namespace_sha256) or
        !std.mem.eql(u8, value.root_css_sha256, &root_hash) or value.root_page_id != root.page_id or value.root_revision_id != root.revision_id or
        !std.mem.eql(u8, value.wiki, "ptwiktionary") or
        !std.mem.eql(u8, resource.url, leaf_url) or !std.mem.eql(u8, resource.base_url, expected_base) or
        !std.mem.eql(u8, revision.wiki, "mediawikiwiki") or !std.mem.eql(u8, revision.title, "MediaWiki:Gadget-enwp-boxes.css") or
        !std.mem.eql(u8, revision.content_model, "css") or revision.page_id == 0 or revision.revision_id == 0 or
        revision.revision_timestamp.len != 20 or !std.mem.eql(u8, revision.source_sha1, &std.fmt.bytesToHex(sha1, .lower)) or
        resource.css.len > 1024 * 1024 or resource.css_bytes != resource.css.len or
        !std.mem.eql(u8, resource.css_sha256, &leaf_hash) or !std.unicode.utf8ValidateSlice(resource.css) or
        !firstImportMatches(root_css, value)) return error.InvalidStylesheetImports;
    var proof: Proof = .{ .snapshot_sha256 = sha256(snapshot_bytes), .resource_sha256 = leaf_hash,
        .page_id = revision.page_id, .revision_id = revision.revision_id, .joined = false };
    if (!flatLeaf(resource.css)) return .{ .profile = try styles.parseAlloc(a, root_css), .proof = proof };
    const segments = [_]styles.Source{
        .{ .css = root_css[0..value.import.start], .base_url = root_url },
        .{ .css = resource.css, .base_url = resource.base_url },
        .{ .css = root_css[value.import.end..], .base_url = root_url, .byte_start = value.import.end },
    };
    const profile = styles.parseSourcesAlloc(a, &segments) catch |err| switch (err) {
        error.StyleProfileLimit => return .{ .profile = try styles.parseAlloc(a, root_css), .proof = proof },
        else => return err,
    };
    proof.joined = true;
    proof.sources = profile.sources;
    return .{ .profile = profile, .proof = proof };
}

const StylesheetJoinFixture = struct {
    const css = @embedFile("testdata/pt-css-imports/root.css");
    const snapshot = @embedFile("testdata/pt-css-imports/snapshot.json");
    const root: Root = .{ .wiki = "ptwiktionary", .dump_date = "20261001",
        .namespace_sha256 = "0be9885f8402569c0f3195705b605628871f8c5e98e0f683cd3b6e72450f20a8",
        .page_id = 56264, .revision_id = 3258806 };
    fn replacement(a: A, body: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(Snapshot, a, snapshot, .{});
        defer parsed.deinit();
        var value = parsed.value;
        value.resource.css = body;
        value.resource.css_bytes = body.len;
        const hash = sha256(body);
        value.resource.css_sha256 = &hash;
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(body, &digest, .{});
        const sha1 = std.fmt.bytesToHex(digest, .lower);
        value.resource.revision.source_sha1 = &sha1;
        return std.json.Stringify.valueAlloc(a, value, .{});
    }
};

test "actual PT stylesheet snapshot binds exact root source revision and imported table paint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = StylesheetJoinFixture;
    var joined = try joinAlloc(a, F.css, F.root, F.snapshot);
    defer joined.profile.deinit();
    try std.testing.expect(joined.proof.joined);
    try std.testing.expect(!joined.profile.globally_unresolved);
    try std.testing.expectEqual(@as(u64, 93693), joined.proof.page_id);
    try std.testing.expectEqual(@as(u64, 8118810), joined.proof.revision_id);
    try std.testing.expectEqualStrings("46589d15c0d8d2d7835b084afae90188691ab029d9e4cb1c890a26031045722c", &joined.proof.resource_sha256);
    const table = try joined.profile.resolveTableWithContext(a, 0, "cmbox", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    const unknown = try joined.profile.resolveTable(a, 0, "cmbox", null, "");
    try std.testing.expect(unknown.unresolved);
    try std.testing.expect(unknown.style == null or unknown.style.?.background == null);
    const matching = try joined.profile.resolveTableWithContext(a, 0, "cmbox", .{ .ancestor_classes = "", .own_id = "nsselect" }, null, "");
    try std.testing.expectEqualStrings("#f8fcff", matching.style.?.background.?);
    try std.testing.expectEqualStrings("#dfe8ff", table.style.?.background.?);
    try std.testing.expectEqual(@import("encoder").presentation_types.BorderCollapse.collapse, table.style.?.collapse.?);
    // Bind the authenticated imported rule through ordinary parsed table tags,
    // not only the explicit low-level context API. The reference adds only the
    // already-proved paint as an inline declaration, preserving IDs and actions.
    const encoder = @import("encoder");
    for ([_]struct { attrs: []const u8, color: []const u8 }{
        .{ .attrs = "class=cmbox", .color = "#dfe8ff" },
        .{ .attrs = "class=cmbox id=nsselect", .color = "#f8fcff" },
        .{ .attrs = "class=cmbox id=Nsselect", .color = "#dfe8ff" },
    }) |case| {
        errdefer std.debug.print("joined PT table attrs={s} paint={s}\n", .{ case.attrs, case.color });
        const source = try std.fmt.allocPrint(a, "{{| {s}\n| [[Visible|paint]] [https://example.test action]\n|}}", .{case.attrs});
        const reference = try std.fmt.allocPrint(a, "{{| {s} style='background:{s}!important'\n| [[Visible|paint]] [https://example.test action]\n|}}", .{case.attrs, case.color});
        var renderer: encoder.presentation_compile.Renderer = .{ .a = a, .context = .{ .table_styles = &joined.profile } };
        var control: encoder.presentation_compile.Renderer = .{ .a = a, .context = .{ .table_styles = &joined.profile } };
        const blocks = try renderer.renderBody(source);
        const control_blocks = try control.renderBody(reference);
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        const rendered = blocks[0].table.?;
        try std.testing.expectEqualStrings(case.color, rendered.style.?.background.?);
        try std.testing.expectEqual(encoder.presentation_types.BorderCollapse.collapse, rendered.style.?.collapse.?);
        try std.testing.expectEqual(@as(usize, 1), rendered.rows.len);
        try std.testing.expectEqual(@as(usize, 1), rendered.rows[0].cells.len);
        var internal: usize = 0;
        var external: usize = 0;
        var text: std.ArrayList(u8) = .empty;
        for (rendered.rows[0].cells[0].spans) |span| {
            try text.appendSlice(a, span.text);
            if (span.kind == .link) {
                try std.testing.expectEqualStrings("Visible", span.target);
                internal += 1;
            }
            if (span.kind == .external_link) {
                try std.testing.expectEqualStrings("https://example.test", span.target);
                external += 1;
            }
        }
        try std.testing.expectEqualStrings("paint action", text.items);
        try std.testing.expectEqual(@as(usize, 1), internal);
        try std.testing.expectEqual(@as(usize, 1), external);
        const Section = struct { level: u8 = 2, title: []const u8 = "Portuguese", blocks: @TypeOf(blocks) };
        const sections = [_]Section{.{ .blocks = blocks }};
        const reference_sections = [_]Section{.{ .blocks = control_blocks }};
        const bytes = try encoder.presentation_codec.encodeBuildAlloc(a, &[_]encoder.presentation_compile.Span{}, &sections, encoder.presentation_types.Layout{}, try renderer.finishReferences(), renderer.media.items);
        const reference_bytes = try encoder.presentation_codec.encodeBuildAlloc(a, &[_]encoder.presentation_compile.Span{}, &reference_sections, encoder.presentation_types.Layout{}, try control.finishReferences(), control.media.items);
        try std.testing.expectEqualSlices(u8, reference_bytes, bytes);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, "joined paint", .language, .{ .code = "pt", .heading = "Portuguese" });
        try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
    }

    var absent = try styles.parseAlloc(a, F.css);
    defer absent.deinit();
    try std.testing.expect(absent.globally_unresolved);
    try std.testing.expect((try absent.resolveTable(a, 0, "cmbox", null, "")).style == null);
}

test "stylesheet join rejects mismatched authority hashes and wrong exact import target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = StylesheetJoinFixture;
    var wrong_root = F.root;
    wrong_root.revision_id += 1;
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, wrong_root, F.snapshot));
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css[0 .. F.css.len - 1], F.root, F.snapshot));
    const parsed = try std.json.parseFromSlice(Snapshot, a, F.snapshot, .{});
    defer parsed.deinit();
    var value = parsed.value;
    value.resource.css = "changed without a matching digest";
    const changed = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, F.root, changed));
    value = parsed.value;
    value.resource.url = "https://www.mediawiki.org/unrequested.css";
    const redirected = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, F.root, redirected));
    value = parsed.value;
    value.import.start += 1;
    const moved = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, F.root, moved));
}

test "nested missing conditional cyclic and sheet-local at rules keep original import unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = StylesheetJoinFixture;
    for ([_][]const u8{
        "@import 'missing.css'; table.cmbox{background:#ffffff;}",
        "@import '" ++ leaf_url ++ "'; table.cmbox{background:#ffffff;}",
        "@media print {table.cmbox{background:#ffffff;}}",
        "@namespace url(https://example.test/ns); table.cmbox{background:#ffffff;}",
        "@charset 'UTF-8'; table.cmbox{background:#ffffff;}",
    }) |body| {
        const synthetic = try F.replacement(a, body);
        var joined = try joinAlloc(a, F.css, F.root, synthetic);
        defer joined.profile.deinit();
        try std.testing.expect(!joined.proof.joined);
        try std.testing.expect(joined.profile.globally_unresolved);
    }
    try std.testing.expect(flatLeaf("/* @import 'not-an-edge'; */ table.X{background:#fff;}"));
    try std.testing.expect(flatLeaf("table.X{content:'@namespace';}"));
}
