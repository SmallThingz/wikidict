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
    page_id: u64 = 0,
    revision_id: u64 = 0,
    core: ?CoreProof = null,
    custom: ?CustomProof = null,
    url: []const u8 = leaf_url,
    joined: bool,
    sources: []const styles.SourceRange = &.{},
    pub fn jsonStringify(self: Proof, jw: anytype) !void {
        if (self.custom) |custom| {
            try jw.write(.{ .schema = "wikidict.custom-property-style-join.v1", .snapshot_sha256 = self.snapshot_sha256[0..], .joined = self.joined, .custom = custom, .sources = self.sources });
            return;
        }
        if (self.core) |core| {
            try jw.write(.{ .schema = "wikidict.core-default-style-join.v1",
                .snapshot_sha256 = self.snapshot_sha256[0..], .projection_sha256 = self.resource_sha256[0..],
                .joined = self.joined, .core = core, .sources = self.sources });
            return;
        }
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
    return joinForTargetAlloc(a, root_css, root, snapshot_bytes, .unknown);
}

pub fn joinForTargetAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8, target: styles.ReadingTarget) !Joined {
    if (snapshot_bytes.len > max_snapshot_bytes) return error.InvalidStylesheetImports;
    const header = try std.json.parseFromSlice(struct { schema: []const u8 }, a, snapshot_bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    if (std.mem.eql(u8, header.value.schema, custom_schema)) return joinCustomAlloc(a, root_css, root, snapshot_bytes, target);
    if (std.mem.eql(u8, header.value.schema, core_schema)) return joinCoreAlloc(a, root_css, root, snapshot_bytes, target);
    return joinImportAlloc(a, root_css, root, snapshot_bytes, target);
}
fn joinImportAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8, target: styles.ReadingTarget) !Joined {
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
    if (!flatLeaf(resource.css)) return .{ .profile = try styles.parseForTargetAlloc(a, root_css, target), .proof = proof };
    const segments = [_]styles.Source{
        .{ .css = root_css[0..value.import.start], .base_url = root_url },
        .{ .css = resource.css, .base_url = resource.base_url },
        .{ .css = root_css[value.import.end..], .base_url = root_url, .byte_start = value.import.end },
    };
    const profile = styles.parseSourcesForTargetAlloc(a, &segments, target) catch |err| switch (err) {
        error.StyleProfileLimit => return .{ .profile = try styles.parseForTargetAlloc(a, root_css, target), .proof = proof },
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

// This reviewed closure is an explicit build-input policy, not a renderer
// class-name rule. It admits only the immutable, variable-independent property
// projection whose complete source/dependency graph was reviewed. It makes no
// claim to implement a skin, LESS evaluation, or unrelated core properties.
const core_schema = "wikidict.core-default-styles.v1";
const core_revision = "79b81ba96674efc8a803fc956bc501d347d440d2";
const core_policy = "mediawiki-79b81-elements-literal-alignment-v1";
const core_url = "https://raw.githubusercontent.com/wikimedia/mediawiki/79b81ba96674efc8a803fc956bc501d347d440d2/resources/src/mediawiki.skinning/elements.less";
const core_siteinfo_hash = "c750bb9f3cfdf543d287ce2a45f87150b8ca35e1fe0944e0636c11a7bcc583bb";
const core_normalized_hash = "62c5d7bdbe3a9df80b178f5346075ac2e1265fbec423859166be439f509ada86";
const core_namespace_hash = "c27eaadbf67364c9eef4848466df97c439fcf36e780f7e47d795a359222e7641";
const core_projection_hash = "1bfe9721e23c539bf6a8c1312f447178cc0c90799f2888578af30313331497ea";
const CoreSourcePin = struct { path: []const u8, bytes: usize, sha256: []const u8 };
const core_source_pins = [_]CoreSourcePin{
    .{ .path = "resources/src/mediawiki.skinning/elements.less", .bytes = 5025, .sha256 = "91b3adb124ea39ea8d3c0f4b4ccabe0b4b407c92a5d4eca495e9f022ed44bb94" },
    .{ .path = "resources/src/mediawiki.less/mediawiki.mixins.less", .bytes = 7459, .sha256 = "3dc08902d9913935a32d341648ad08e856a723efea8f6706733fbd2daacea19a" },
    .{ .path = "resources/src/mediawiki.less/mediawiki.skin.variables.less", .bytes = 206, .sha256 = "a7e87080020f19b64470e7a61b9aa8267dcc0f74ca6a7fa714ea1bbb4a0ea32f" },
    .{ .path = "resources/src/mediawiki.less/mediawiki.skin.defaults.less", .bytes = 19027, .sha256 = "412516b776272f977dd5c54456a4782599b3668ed9bdd2d15ececd0ba119b8a6" },
};
const CoreSnapshot = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    root_css_sha256: []const u8,
    root_page_id: u64,
    root_revision_id: u64,
    core_revision: []const u8,
    coverage_policy: []const u8,
    siteinfo_raw: []const u8,
    siteinfo_normalized: []const u8,
    sources: []const struct { path: []const u8, bytes: usize, sha256: []const u8, text: []const u8 },
    projection: struct { source_index: usize, start: usize, end: usize, sha256: []const u8 },
};
pub const CoreProof = struct {
    siteinfo_sha256: [64]u8,
    normalized_siteinfo_sha256: [64]u8,
    pub fn jsonStringify(self: CoreProof, jw: anytype) !void {
        try jw.write(.{ .kind = "reviewed-core-default-projection", .core_revision = core_revision,
            .coverage_policy = core_policy, .generator = "MediaWiki 1.47.0-wmf.22",
            .siteinfo_sha256 = self.siteinfo_sha256[0..], .normalized_siteinfo_sha256 = self.normalized_siteinfo_sha256[0..],
            .temporal_scope = "version observed 2026-10-06; not a claim of dump-date deployment or skin equivalence",
            .source_graph = core_source_pins,
            .projection = .{ .source_index = 0, .start = 4824, .end = 4927, .sha256 = core_projection_hash },
        });
    }
};
fn joinCoreAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8, target: styles.ReadingTarget) !Joined {
    const parsed = try std.json.parseFromSlice(CoreSnapshot, a, snapshot_bytes, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, core_schema) or !std.mem.eql(u8, value.wiki, root.wiki) or
        !std.mem.eql(u8, value.wiki, "euwiktionary") or !std.mem.eql(u8, value.dump_date, root.dump_date) or
        !std.mem.eql(u8, value.dump_date, "20261001") or !std.mem.eql(u8, value.namespace_sha256, root.namespace_sha256) or
        !std.mem.eql(u8, value.namespace_sha256, core_namespace_hash) or
        value.root_page_id != root.page_id or value.root_revision_id != root.revision_id or
        root.page_id == 0 or root.revision_id == 0 or !std.mem.eql(u8, value.root_css_sha256, &sha256(root_css)) or
        !std.mem.eql(u8, value.core_revision, core_revision) or !std.mem.eql(u8, value.coverage_policy, core_policy) or
        !std.mem.eql(u8, &sha256(value.siteinfo_raw), core_siteinfo_hash) or
        !std.mem.eql(u8, &sha256(value.siteinfo_normalized), core_normalized_hash) or
        value.sources.len != core_source_pins.len or value.projection.source_index != 0 or
        value.projection.start != 4824 or value.projection.end != 4927 or
        !std.mem.eql(u8, value.projection.sha256, core_projection_hash)) return error.InvalidStylesheetImports;
    // The complete immutable source graph, not caller-selected hashes/ranges,
    // determines the allowed projection. Raw and normalized metadata are pinned
    // separately from the namespace-registry hash used by the ordinary loader.
    for (value.sources, core_source_pins) |source, pin| {
        if (!std.mem.eql(u8, source.path, pin.path) or source.bytes != pin.bytes or source.text.len != pin.bytes or
            !std.mem.eql(u8, source.sha256, pin.sha256) or !std.mem.eql(u8, &sha256(source.text), pin.sha256))
            return error.InvalidStylesheetImports;
    }
    const projected = value.sources[0].text[value.projection.start..value.projection.end];
    if (!std.mem.eql(u8, &sha256(projected), core_projection_hash)) return error.InvalidStylesheetImports;
    const common_url = try std.fmt.allocPrint(a, "https://eu.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&oldid={d}", .{root.revision_id});
    defer a.free(common_url);
    // Core defaults precede the COMPLETE actual Common.css. Unknown applicable
    // site declarations remain subject to the ordinary conservative profile.
    const segments = [_]styles.Source{
        .{ .css = projected, .base_url = core_url, .byte_start = value.projection.start },
        .{ .css = root_css, .base_url = common_url },
    };
    const profile = try styles.parseSourcesForTargetAlloc(a, &segments, target);
    return .{ .profile = profile, .proof = .{
        .snapshot_sha256 = sha256(snapshot_bytes), .resource_sha256 = sha256(projected),
        .joined = true, .sources = profile.sources, .url = core_url,
        .core = .{ .siteinfo_sha256 = sha256(value.siteinfo_raw), .normalized_siteinfo_sha256 = sha256(value.siteinfo_normalized) },
    } };
}

const CoreDefaultFixture = struct {
    const snapshot = @embedFile("testdata/core-default-styles/snapshot.json");
    const css = @embedFile("testdata/core-default-styles/common.css");
    const root: Root = .{ .wiki = "euwiktionary", .dump_date = "20261001",
        .namespace_sha256 = core_namespace_hash, .page_id = 4244, .revision_id = 409541 };
    fn withCss(a: A, css_bytes: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(CoreSnapshot, a, snapshot, .{});
        defer parsed.deinit();
        var value = parsed.value;
        const hash = sha256(css_bytes);
        value.root_css_sha256 = &hash;
        return std.json.Stringify.valueAlloc(a, value, .{});
    }
};

test "reviewed core defaults bind complete source closure before exact Common css" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CoreDefaultFixture;
    var joined = try joinAlloc(a, F.css, F.root, F.snapshot);
    defer joined.profile.deinit();
    try std.testing.expect(joined.proof.joined and joined.proof.core != null);
    try std.testing.expectEqual(@as(usize, 2), joined.profile.sources.len);
    try std.testing.expectEqualStrings(core_url, joined.profile.sources[0].base_url);
    try std.testing.expectEqual(@as(usize, 4824), joined.profile.sources[0].byte_start);
    try std.testing.expectEqual(@as(usize, 103), joined.profile.sources[0].bytes);
    try std.testing.expectEqualStrings(core_projection_hash, &joined.profile.sources[0].css_sha256);
    try std.testing.expectEqualStrings(&sha256(F.css), &joined.profile.sources[1].css_sha256);
    try std.testing.expectEqual(@as(usize, 0), joined.profile.sources[1].byte_start);
    try std.testing.expect(joined.profile.sources[1].rule_begin >= joined.profile.sources[0].rule_end);
    const alignment = try joined.profile.resolveAlignment(a, "div", "center", "", null, "");
    try std.testing.expect(alignment.specified and !alignment.unresolved);
    try std.testing.expectEqual(@import("encoder").presentation_types.CellTextAlign.center, alignment.value.?);
    const proof = try std.json.Stringify.valueAlloc(a, joined.proof, .{});
    try std.testing.expect(std.mem.indexOf(u8, proof, "wikidict.core-default-style-join.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proof, "reviewed-core-default-projection") != null);
    // Core git authority must never be represented as an invented wiki page.
    try std.testing.expect(std.mem.indexOf(u8, proof, "\"page_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, proof, "\"revision_id\"") == null);
}

test "core default snapshot refuses altered versions dependencies projections and root joins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CoreDefaultFixture;
    const parsed = try std.json.parseFromSlice(CoreSnapshot, a, F.snapshot, .{});
    defer parsed.deinit();
    for (0..7) |case| {
        var value = parsed.value;
        switch (case) {
            0 => value.core_revision = "unreviewed",
            1 => value.coverage_policy = "caller-claims-complete",
            2 => value.projection.start += 1,
            3 => value.projection.end -= 1,
            4 => value.siteinfo_raw = "{\"query\":{\"general\":{\"generator\":\"MediaWiki 1.48\"}}}",
            5 => value.siteinfo_normalized = "{}",
            6 => {
                const sources = try a.dupe(@TypeOf(value.sources[0]), value.sources);
                sources[1].text = "/* missing actual mixin dependency */";
                const forged_hash = sha256(sources[1].text);
                sources[1].sha256 = try a.dupe(u8, &forged_hash);
                sources[1].bytes = sources[1].text.len;
                value.sources = sources;
            },
            else => unreachable,
        }
        const forged = try std.json.Stringify.valueAlloc(a, value, .{});
        try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, F.root, forged));
    }
    for (0..5) |case| {
        var root = F.root;
        switch (case) {
            0 => root.wiki = "otherwiktionary",
            1 => root.dump_date = "20261002",
            2 => root.namespace_sha256 = core_normalized_hash,
            3 => root.page_id += 1,
            4 => root.revision_id += 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, root, F.snapshot));
    }
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, "changed Common.css", F.root, F.snapshot));
}

test "site cascade overrides reviewed core defaults and matching unknown rules stay unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const F = CoreDefaultFixture;
    // Controlled site successors use the same verified core closure. These
    // declarations are synthetic cascade controls, not captured EU Common.css.
    for ([_]struct { css: []const u8, unresolved: bool }{
        .{ .css = ".center { text-align: right; }", .unresolved = false },
        .{ .css = ".center:hover { text-align: right; }", .unresolved = true },
    }) |case| {
        var joined = try joinAlloc(a, case.css, F.root, try F.withCss(a, case.css));
        defer joined.profile.deinit();
        const resolved = try joined.profile.resolveAlignment(a, "div", "center", "", null, "");
        try std.testing.expect(resolved.specified);
        try std.testing.expectEqual(case.unresolved, resolved.unresolved);
        if (case.unresolved) try std.testing.expect(resolved.value == null) else
            try std.testing.expectEqual(@import("encoder").presentation_types.CellTextAlign.right, resolved.value.?);
    }
    // Existing PT proof variant still has its original schema/page identity.
    var pt = try joinAlloc(a, StylesheetJoinFixture.css, StylesheetJoinFixture.root, StylesheetJoinFixture.snapshot);
    defer pt.profile.deinit();
    try std.testing.expect(pt.proof.core == null and pt.proof.joined);
    const json = try std.json.Stringify.valueAlloc(a, pt.proof, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "wikidict.stylesheet-import-join.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"page_id\":93693") != null);
}

const custom_schema = "wikidict.custom-property-styles.v1";
const CustomSnapshot = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    root_css_sha256: []const u8,
    root_page_id: u64,
    root_revision_id: u64,
    temporal_scope: []const u8,
    observed_utc: []const u8,
    page_url: []const u8,
    page_title: []const u8,
    page_html: []const u8,
    page_sha256: []const u8,
    generator: []const u8,
    skin: []const u8,
    dark: ?bool,
    ancestors: []const struct { tag: []const u8, classes: []const u8, id: []const u8, inline_css: []const u8, root: bool, start: usize, end: usize },
    sources: []const struct { url: []const u8, css: []const u8, bytes: usize, sha256: []const u8 },
};
pub const CustomProof = struct {
    temporal_scope: []const u8,
    observed_utc: []const u8,
    page_url: []const u8,
    page_title: []const u8,
    page_sha256: [64]u8,
    generator: []const u8,
    skin: []const u8,
    dark: ?bool,
    source_hashes: []const [64]u8,
    pub fn jsonStringify(self: CustomProof, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("temporal_scope"); try jw.write(self.temporal_scope);
        try jw.objectField("observed_utc"); try jw.write(self.observed_utc);
        try jw.objectField("page_url"); try jw.write(self.page_url);
        try jw.objectField("page_title"); try jw.write(self.page_title);
        try jw.objectField("page_sha256"); try jw.write(self.page_sha256[0..]);
        try jw.objectField("generator"); try jw.write(self.generator);
        try jw.objectField("skin"); try jw.write(self.skin);
        try jw.objectField("dark"); try jw.write(self.dark);
        try jw.objectField("source_sha256"); try jw.beginArray();
        for (self.source_hashes) |hash| try jw.write(hash[0..]);
        try jw.endArray(); try jw.endObject();
    }
};
fn joinCustomAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8, target: styles.ReadingTarget) !Joined {
    const parsed = try std.json.parseFromSlice(CustomSnapshot, a, snapshot_bytes, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, custom_schema) or !std.mem.eql(u8, value.wiki, root.wiki) or
        !std.mem.eql(u8, value.dump_date, root.dump_date) or !std.mem.eql(u8, value.namespace_sha256, root.namespace_sha256) or
        !std.mem.eql(u8, value.root_css_sha256, &sha256(root_css)) or value.root_page_id != root.page_id or value.root_revision_id != root.revision_id or
        root.page_id == 0 or root.revision_id == 0 or
        !std.mem.eql(u8, value.temporal_scope, "current anonymous screen stylesheet observation applied to retained source; not historical dump deployment") or
        value.observed_utc.len < 20 or value.generator.len == 0 or value.skin.len == 0 or value.page_title.len == 0 or
        !std.mem.startsWith(u8, value.page_url, "https://") or
        value.page_html.len > 1024 * 1024 or !std.mem.eql(u8, value.page_sha256, &sha256(value.page_html)) or
        value.sources.len == 0 or value.sources.len > 32 or value.ancestors.len < 2 or value.ancestors.len > 32)
        return error.InvalidStylesheetImports;
    var profile = try styles.parseForTargetAlloc(a, root_css, target);
    errdefer profile.deinit();
    const pa = profile.arena.allocator();
    const syntax = @import("encoder").wikitext_syntax;
    const ancestors = try pa.alloc(styles.CustomElement, value.ancestors.len);
    var preceding: usize = 0;
    for (value.ancestors, 0..) |item, i| {
        if (item.start < preceding or item.start >= item.end or item.end > value.page_html.len or
            item.root != (i == 0) or (i == 0 and !std.mem.eql(u8, item.tag, "html")) or
            (i == 1 and !std.mem.eql(u8, item.tag, "body"))) return error.InvalidStylesheetImports;
        const tag = syntax.tagAt(value.page_html, item.start) orelse return error.InvalidStylesheetImports;
        if (tag.end != item.end or tag.closing or tag.self_closing or !std.mem.eql(u8, tag.name, item.tag) or
            !std.mem.eql(u8, tag.attr("class") orelse "", item.classes) or !std.mem.eql(u8, tag.attr("id") orelse "", item.id) or
            !std.mem.eql(u8, tag.attr("style") orelse "", item.inline_css))
            return error.InvalidStylesheetImports;
        ancestors[i] = .{ .tag = try pa.dupe(u8, item.tag), .classes = try pa.dupe(u8, item.classes), .id = try pa.dupe(u8, item.id), .root = item.root, .inline_css = try pa.dupe(u8, item.inline_css) };
        preceding = item.end;
    }
    const sources = try pa.alloc(styles.Source, value.sources.len + 1);
    const hashes = try pa.alloc([64]u8, value.sources.len);
    var total: usize = root_css.len;
    for (value.sources, 0..) |source, i| {
        total = std.math.add(usize, total, source.css.len) catch return error.InvalidStylesheetImports;
        if (source.bytes != source.css.len or source.css.len > 1024 * 1024 or total > 1024 * 1024 or
            !std.unicode.utf8ValidateSlice(source.css) or !std.mem.eql(u8, source.sha256, &sha256(source.css)) or
            !std.mem.startsWith(u8, source.url, "https://")) return error.InvalidStylesheetImports;
        sources[i] = .{ .css = try pa.dupe(u8, source.css), .base_url = try pa.dupe(u8, source.url) };
        hashes[i] = sha256(source.css);
    }
    // The retained source's complete Common.css is still consulted; the selected
    // external context does not replace or silently rewrite the dump's input.
    sources[value.sources.len] = .{ .css = root_css, .base_url = "" };
    try styles.attachCustomProperties(&profile, sources, .{ .dark = value.dark, .ancestors = ancestors });
    @constCast(profile.custom_properties.?).page_title = try pa.dupe(u8, value.page_title);
    return .{ .profile = profile, .proof = .{
        .snapshot_sha256 = sha256(snapshot_bytes), .resource_sha256 = sha256(snapshot_bytes), .joined = true,
        .sources = profile.sources, .url = try pa.dupe(u8, value.page_url),
        .custom = .{ .temporal_scope = try pa.dupe(u8, value.temporal_scope), .observed_utc = try pa.dupe(u8, value.observed_utc),
            .page_url = try pa.dupe(u8, value.page_url), .page_title = try pa.dupe(u8, value.page_title), .page_sha256 = sha256(value.page_html),
            .generator = try pa.dupe(u8, value.generator), .skin = try pa.dupe(u8, value.skin), .dark = value.dark, .source_hashes = hashes },
    } };
}

const EsCustomPropertyFixture = struct {
    const snapshot = @embedFile("testdata/es-custom-properties/snapshot.json");
    const css = @embedFile("testdata/es-ousia/es-common.css");
    const root: Root = .{ .wiki = "eswiktionary", .dump_date = "20261001", .namespace_sha256 = "2aa89ef33ec87dd31c0f5b43a4cc2e56efd890764a958eab8d49249432bc8fde", .page_id = 20385, .revision_id = 5909987 };
};
test "ordinary selected stylesheet join resolves observed Spanish day token without authored fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = EsCustomPropertyFixture;
    var joined = try joinAlloc(a, F.css, F.root, F.snapshot); defer joined.profile.deinit();
    try std.testing.expect(joined.proof.joined and joined.proof.custom != null);
    try std.testing.expectEqualStrings("MediaWiki 1.48.0-wmf.3", joined.proof.custom.?.generator);
    try std.testing.expectEqualStrings("vector-2022", joined.proof.custom.?.skin);
    try std.testing.expect(joined.proof.custom.?.dark == null);
    const custom = joined.profile.custom_properties.?;
    try std.testing.expect(custom.appliesTo("ataujía") and !custom.appliesTo("another title"));
    const value = try styles.customColorValue(a, custom.root_environment, "var(--color-option-lime,#ff00ff)");
    try std.testing.expect(value == .known);
    try std.testing.expectEqualStrings("#1f7a39", value.known);
    const proof = try std.json.Stringify.valueAlloc(a, joined.proof, .{});
    try std.testing.expect(std.mem.indexOf(u8, proof, "not historical dump deployment") != null);
    try std.testing.expect(std.mem.indexOf(u8, proof, "current anonymous screen") != null);
}
test "ordinary custom stylesheet join refuses changed root source context and property bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = EsCustomPropertyFixture;
    const parsed = try std.json.parseFromSlice(CustomSnapshot, a, F.snapshot, .{}); defer parsed.deinit();
    for (0..5) |case| {
        var value = parsed.value;
        switch (case) {
            0 => value.root_revision_id += 1,
            1 => value.namespace_sha256 = "wrong",
            2 => value.page_html = "<html></html>",
            3 => {
                const sources = try a.dupe(@TypeOf(value.sources[0]), value.sources);
                sources[0].css = ":root{--color-option-lime:#ff0000}";
                value.sources = sources;
            },
            4 => {
                const ancestors = try a.dupe(@TypeOf(value.ancestors[0]), value.ancestors);
                ancestors[0].classes = "skin-theme-clientpref-night";
                value.ancestors = ancestors;
            },
            else => unreachable,
        }
        const invalid = try std.json.Stringify.valueAlloc(a, value, .{});
        try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, F.root, invalid));
    }
}

test "targeted import join preserves selected source order and media on root and fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const F = StylesheetJoinFixture;
    const css = try std.fmt.allocPrint(a, "{s}\n@media print{{.readingOnly{{display:none}}}}@media screen{{.readingOnly{{text-align:right}}}}", .{F.css});
    const parsed = try std.json.parseFromSlice(Snapshot, a, F.snapshot, .{}); defer parsed.deinit();
    var value = parsed.value;
    const root_hash = sha256(css); value.root_css_sha256 = &root_hash;
    const snapshot = try std.json.Stringify.valueAlloc(a, value, .{});
    var screen = try joinForTargetAlloc(a, css, F.root, snapshot, .screen); defer screen.profile.deinit();
    try std.testing.expect(screen.proof.joined and !screen.profile.globally_unresolved);
    try std.testing.expectEqual(styles.ReadingTarget.screen, screen.profile.reading_target);
    try std.testing.expectEqual(@as(usize, 3), screen.profile.sources.len);
    const align_value = try screen.profile.resolveAlignment(a, "div", "readingOnly", "", null, "");
    try std.testing.expect(!align_value.unresolved and align_value.value.? == .right);
    var legacy = try joinAlloc(a, css, F.root, snapshot); defer legacy.profile.deinit();
    try std.testing.expect((try legacy.profile.resolveAlignment(a, "div", "readingOnly", "", null, "")).unresolved);
    const altered_leaf = try F.replacement(a, "@media screen{.other{display:none}}");
    const fallback_parsed = try std.json.parseFromSlice(Snapshot, a, altered_leaf, .{}); defer fallback_parsed.deinit();
    var fallback_value = fallback_parsed.value; fallback_value.root_css_sha256 = &root_hash;
    const fallback_snapshot = try std.json.Stringify.valueAlloc(a, fallback_value, .{});
    var fallback = try joinForTargetAlloc(a, css, F.root, fallback_snapshot, .screen); defer fallback.profile.deinit();
    try std.testing.expect(!fallback.proof.joined and fallback.profile.globally_unresolved);
    try std.testing.expectEqual(styles.ReadingTarget.screen, fallback.profile.reading_target);
    var rules = fallback.profile.displayRules("div", "readingOnly", "");
    const only = rules.next().?;
    try std.testing.expect(!only.uncertain and std.mem.indexOf(u8, only.css, "text-align:right") != null);
    try std.testing.expect(rules.next() == null);
    // The retained unresolved import still refuses an otherwise known alignment.
    try std.testing.expect((try fallback.profile.resolveAlignment(a, "div", "readingOnly", "", null, "")).unresolved);
}

test "targeted reviewed core join evaluates medium without changing source closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = CoreDefaultFixture;
    const css = try std.fmt.allocPrint(a, "{s}\n@media print{{.readingOnly{{text-align:left}}}}@media screen{{.readingOnly{{text-align:right}}}}", .{F.css});
    const snapshot = try F.withCss(a, css);
    for ([_]styles.ReadingTarget{ .screen, .print }) |target| {
        var joined = try joinForTargetAlloc(a, css, F.root, snapshot, target); defer joined.profile.deinit();
        try std.testing.expect(joined.proof.joined and joined.proof.core != null);
        try std.testing.expectEqual(target, joined.profile.reading_target);
        try std.testing.expectEqualStrings(core_projection_hash, &joined.profile.sources[0].css_sha256);
        try std.testing.expectEqualStrings(&sha256(css), &joined.profile.sources[1].css_sha256);
        const result = try joined.profile.resolveAlignment(a, "div", "readingOnly", "", null, "");
        try std.testing.expect(!result.unresolved);
        try std.testing.expectEqual(if (target == .screen) @import("encoder").presentation_types.CellTextAlign.right else .left, result.value.?);
    }
    var legacy = try joinAlloc(a, css, F.root, snapshot); defer legacy.profile.deinit();
    try std.testing.expect((try legacy.profile.resolveAlignment(a, "div", "readingOnly", "", null, "")).unresolved);
}

test "targeted custom join preserves independent screen theme authority and refuses print attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = EsCustomPropertyFixture;
    const css = try std.fmt.allocPrint(a, "{s}\n@media print{{.readingOnly{{display:none}}}}", .{F.css});
    const parsed = try std.json.parseFromSlice(CustomSnapshot, a, F.snapshot, .{}); defer parsed.deinit();
    var value = parsed.value; const hash = sha256(css); value.root_css_sha256 = &hash;
    const snapshot = try std.json.Stringify.valueAlloc(a, value, .{});
    var joined = try joinForTargetAlloc(a, css, F.root, snapshot, .screen); defer joined.profile.deinit();
    try std.testing.expectEqual(styles.ReadingTarget.screen, joined.profile.reading_target);
    var rules = joined.profile.displayRules("div", "readingOnly", "");
    try std.testing.expect(rules.next() == null);
    const custom = joined.profile.custom_properties.?;
    const paint = try styles.customColorValue(a, custom.root_environment, "var(--color-option-lime,#ff00ff)");
    try std.testing.expect(paint == .known);
    try std.testing.expectEqualStrings("#1f7a39", paint.known);
    try std.testing.expect(custom.appliesTo("ataujía") and !custom.appliesTo("another title"));
    try std.testing.expectError(error.InvalidStyleProfile, joinForTargetAlloc(a, css, F.root, snapshot, .print));
}


const MaiObservedCustomFixture = struct {
    const snapshot = @embedFile("testdata/de-mai-palette/context-snapshot.json");
    const css = @embedFile("testdata/de-polish-states/common.css");
    const root: Root = .{ .wiki = "dewiktionary", .dump_date = "20261001", .namespace_sha256 = "c83026f854b69c0e7157a2c8ef850d4a803c3f2155d2affdd3eac692235e70b8", .page_id = 18861, .revision_id = 10743844 };
};

test "normal Mai stylesheet join binds actual day context and retained Common aliases without fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = MaiObservedCustomFixture;
    var joined = try joinForTargetAlloc(a, F.css, F.root, F.snapshot, .screen); defer joined.profile.deinit();
    try std.testing.expect(joined.proof.joined and joined.proof.custom != null);
    const proof = joined.proof.custom.?;
    try std.testing.expectEqualStrings("MediaWiki 1.48.0-wmf.4", proof.generator);
    try std.testing.expectEqualStrings("vector-2022", proof.skin);
    try std.testing.expect(proof.dark == false);
    try std.testing.expectEqualStrings("Mai", proof.page_title);
    try std.testing.expectEqualStrings("https://de.wiktionary.org/w/index.php?title=Mai&oldid=10777072&useskin=vector-2022", proof.page_url);
    try std.testing.expectEqualStrings("2c30aac1fd1ea02a05528647a99cf2ac650f51e30b848014af3b01b316edd387", &proof.page_sha256);
    try std.testing.expectEqual(@as(usize, 3), proof.source_hashes.len);
    try std.testing.expectEqualStrings("04f054a2123759416e4f7934df96d14ef63945e80f04ab831a8c77d170a99922", &proof.source_hashes[0]);
    try std.testing.expectEqualStrings("3d2b0b96116abbbbc0c1777ff54f5ee1a2d62d6cebce8125136b887e46479d29", &proof.source_hashes[1]);
    try std.testing.expectEqualStrings("3ba3d0aad75479a1b521d9d937ed01b21157c2ddfc8592a0e5636712ad32406c", &proof.source_hashes[2]);
    const custom = joined.profile.custom_properties.?;
    try std.testing.expect(custom.appliesTo("Mai") and !custom.appliesTo("another page"));
    for ([_]struct { expression: []const u8, value: []const u8 }{
        .{ .expression = "var(--border-color-base,#ff00ff)", .value = "#a2a9b1" },
        .{ .expression = "var(--border-color-divider,#ff00ff)", .value = "#a2a9b1" },
        .{ .expression = "var(--background-color-neutral,#ff00ff)", .value = "#eaecf0" },
        .{ .expression = "var(--background-color-base,#ff00ff)", .value = "#fff" },
        .{ .expression = "var(--hintergrundfarbe2,#ff00ff)", .value = "#fff" },
        .{ .expression = "var(--rahmenfarbe1,#ff00ff)", .value = "#a2a9b1" },
    }) |expected| {
        const value = try styles.customColorValue(a, custom.root_environment, expected.expression);
        try std.testing.expect(value == .known);
        try std.testing.expectEqualStrings(expected.value, value.known);
    }
    // The current GET is context evidence only; its parsed body never replaces
    // the retained source or grants TemplateStyles geometry/full-page rendering.
    const encoded = try std.json.Stringify.valueAlloc(a, joined.proof, .{});
    try std.testing.expect(std.mem.indexOf(u8, encoded, "not historical dump deployment") != null);
}

test "normal Mai custom context rejects stale bytes and retains a possible palette override as unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit(); const a = arena.allocator(); const F = MaiObservedCustomFixture;
    const parsed = try std.json.parseFromSlice(CustomSnapshot, a, F.snapshot, .{}); defer parsed.deinit();
    for (0..4) |mode| {
        var changed = parsed.value;
        switch (mode) {
            0 => changed.root_revision_id += 1,
            1 => changed.page_html = "<html><body>different context</body></html>",
            2 => {
                const ancestors = try a.dupe(@TypeOf(changed.ancestors[0]), changed.ancestors);
                ancestors[0].classes = "skin-theme-clientpref-night"; changed.ancestors = ancestors;
            },
            3 => {
                const sources = try a.dupe(@TypeOf(changed.sources[0]), changed.sources);
                sources[0].css = ":root{--border-color-base:red}"; changed.sources = sources;
            },
            else => unreachable,
        }
        const snapshot = try std.json.Stringify.valueAlloc(a, changed, .{});
        try std.testing.expectError(error.InvalidStylesheetImports, joinForTargetAlloc(a, F.css, F.root, snapshot, .screen));
    }
    // A controlled, reauthenticated source contrast is not served evidence.
    // Unproved applicability must not select the authored magenta fallback.
    var changed = parsed.value;
    const sources = try a.dupe(@TypeOf(changed.sources[0]), changed.sources);
    sources[2].css = try std.mem.concat(a, u8, &.{ sources[2].css, "html:future-palette{--border-color-base:red!important}" });
    sources[2].bytes = sources[2].css.len;
    const digest = sha256(sources[2].css); sources[2].sha256 = &digest; changed.sources = sources;
    var unknown = try joinForTargetAlloc(a, F.css, F.root, try std.json.Stringify.valueAlloc(a, changed, .{}), .screen); defer unknown.profile.deinit();
    const color = try styles.customColorValue(a, unknown.profile.custom_properties.?.root_environment, "var(--border-color-base,#ff00ff)");
    try std.testing.expect(color == .unknown);
}
