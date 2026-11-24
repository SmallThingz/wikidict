//! Build-only join of an explicitly selected, replayed stylesheet snapshot.
//! No fetching, CSS execution or reader dependency is introduced here.
const std = @import("std");
const styles = @import("encoder").table_style_profile;
const A = std.mem.Allocator;
const leaf_url = "https://www.mediawiki.org/w/index.php?title=MediaWiki:Gadget-enwp-boxes.css&action=raw&ctype=text/css";
const root_url = "https://pt.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css";
const ImportProfile = struct {
    leaf_url: []const u8,
    root_url: []const u8,
    resource_wiki: []const u8,
    resource_title: []const u8,
    media_groups: bool = false,
};
fn importProfile(wiki: []const u8) ?ImportProfile {
    if (std.mem.eql(u8, wiki, "ptwiktionary")) return .{
        .leaf_url = leaf_url, .root_url = root_url,
        .resource_wiki = "mediawikiwiki", .resource_title = "MediaWiki:Gadget-enwp-boxes.css",
    };
    if (std.mem.eql(u8, wiki, "jvwiktionary")) return .{
        .leaf_url = "https://jv.wikipedia.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css",
        .root_url = "https://jv.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css",
        .resource_wiki = "jvwiki", .resource_title = "MédhiaWiki:Common.css", .media_groups = true,
    };
    return null;
}

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
fn firstImportMatches(css: []const u8, selected: Snapshot, import_profile: ImportProfile) bool {
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
        (std.mem.eql(u8, import.authored_url, import_profile.leaf_url) or
        std.mem.eql(u8, import.authored_url, import_profile.leaf_url[6..])) and
        std.mem.eql(u8, import.resolved_url, import_profile.leaf_url);
}
fn flatLeaf(css: []const u8) bool {
    return leafDependenciesKnown(css, false);
}
fn leafDependenciesKnown(css: []const u8, media_groups: bool) bool {
    // Unsupported at-rules, charset/namespace scopes and imports retain the
    // root dependency. Comments and strings do not manufacture import edges.
    // The explicit JV profile additionally carries media groups to the parser.
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
            if (css[at] == '@') {
                // JV's captured leaf contains media groups. The existing profile
                // parser keeps every conditional declaration uncertain; no media
                // condition is stripped or assumed. All other at-rules, including
                // nested imports, keep the original root import unresolved.
                if (!media_groups or css.len - at < 7 or !std.ascii.eqlIgnoreCase(css[at..][0..6], "@media") or
                    std.mem.indexOfScalar(u8, " \t\r\n\x0c", css[at + 6]) == null) return false;
                at += 6;
                continue;
            }
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
    const import_profile = importProfile(root.wiki) orelse return error.InvalidStylesheetImports;
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
    const expected_base = try std.fmt.allocPrint(a, "{s}&oldid={d}", .{ import_profile.leaf_url, revision.revision_id });
    defer a.free(expected_base);
    if (!std.mem.eql(u8, value.schema, "wikidict.stylesheet-imports.v1") or
        !std.mem.eql(u8, value.wiki, root.wiki) or !std.mem.eql(u8, value.dump_date, root.dump_date) or
        !std.mem.eql(u8, value.namespace_sha256, root.namespace_sha256) or
        !std.mem.eql(u8, value.root_css_sha256, &root_hash) or value.root_page_id != root.page_id or value.root_revision_id != root.revision_id or
        !std.mem.eql(u8, resource.url, import_profile.leaf_url) or !std.mem.eql(u8, resource.base_url, expected_base) or
        !std.mem.eql(u8, revision.wiki, import_profile.resource_wiki) or !std.mem.eql(u8, revision.title, import_profile.resource_title) or
        !std.mem.eql(u8, revision.content_model, "css") or revision.page_id == 0 or revision.revision_id == 0 or
        revision.revision_timestamp.len != 20 or !std.mem.eql(u8, revision.source_sha1, &std.fmt.bytesToHex(sha1, .lower)) or
        resource.css.len > 1024 * 1024 or resource.css_bytes != resource.css.len or
        !std.mem.eql(u8, resource.css_sha256, &leaf_hash) or !std.unicode.utf8ValidateSlice(resource.css) or
        !firstImportMatches(root_css, value, import_profile)) return error.InvalidStylesheetImports;
    var proof: Proof = .{ .snapshot_sha256 = sha256(snapshot_bytes), .resource_sha256 = leaf_hash,
        .page_id = revision.page_id, .revision_id = revision.revision_id, .url = import_profile.leaf_url, .joined = false };
    if (!leafDependenciesKnown(resource.css, import_profile.media_groups)) return .{ .profile = try styles.parseForTargetAlloc(a, root_css, target), .proof = proof };
    const segments = [_]styles.Source{
        .{ .css = root_css[0..value.import.start], .base_url = import_profile.root_url },
        .{ .css = resource.css, .base_url = resource.base_url },
        .{ .css = root_css[value.import.end..], .base_url = import_profile.root_url, .byte_start = value.import.end },
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
const article_styles_schema = "wikidict.stylesheet-imports.custom-properties-articles.v1";
const ArticleStyles = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    root_css_sha256: []const u8,
    root_page_id: u64,
    root_revision_id: u64,
    temporal_scope: []const u8,
    articles: []const struct { page_id: u64, revision_id: u64, snapshot: []const u8 },
};
const custom_temporal_scope = "current anonymous screen stylesheet observation applied to retained source; not historical dump deployment";
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
pub const absent_custom_schema = "wikidict.stylesheet-imports.custom-properties-absent-root.v1";
const AbsentCustomSnapshot = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    namespace_sha256: []const u8,
    article_page_id: u64,
    article_revision_id: u64,
    root_absence: struct {
        namespace: i32, dbkey: []const u8, page_table_sha256: []const u8,
        page_table_bytes: u64, dumpstatus_sha256: []const u8, namespace_registry_sha256: []const u8,
    },
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
    article: ?struct { page_id: u64, revision_id: u64 } = null,
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
        if (self.article) |article| { try jw.objectField("article"); try jw.write(article); }
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
    if (!std.mem.eql(u8, value.schema, custom_schema) or !matchesCustomRoot(value, root, &sha256(root_css)))
        return error.InvalidStylesheetImports;
    return buildCustomContext(a, root_css, snapshot_bytes, target, value);
}

fn matchesCustomRoot(value: anytype, root: Root, root_sha256: *const [64]u8) bool {
    return std.mem.eql(u8, value.wiki, root.wiki) and
        std.mem.eql(u8, value.dump_date, root.dump_date) and std.mem.eql(u8, value.namespace_sha256, root.namespace_sha256) and
        std.mem.eql(u8, value.root_css_sha256, root_sha256) and value.root_page_id == root.page_id and value.root_revision_id == root.revision_id and
        root.page_id != 0 and root.revision_id != 0;
}

pub fn deinitArticleStyles(a: A, articles: []Joined) void {
    for (articles) |*article| article.profile.deinit();
    a.free(articles);
}

pub fn joinIndexedArticleStylesAlloc(a: A, root_css: []const u8, root: Root, snapshot_bytes: []const u8,
    target: styles.ReadingTarget, namespaces: anytype, page_index: []const u8, titles: anytype) !?[]Joined
{
    if (snapshot_bytes.len > max_snapshot_bytes) return error.InvalidStylesheetImports;
    const header = try std.json.parseFromSlice(struct { schema: []const u8 }, a, snapshot_bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.schema, article_styles_schema)) return null;
    const parsed = try std.json.parseFromSlice(ArticleStyles, a, snapshot_bytes, .{});
    defer parsed.deinit();
    const root_sha256 = sha256(root_css);
    const value = parsed.value;
    if (target != .screen or value.articles.len == 0 or value.articles.len > 16 or
        !matchesCustomRoot(value, root, &root_sha256) or !std.mem.eql(u8, value.temporal_scope, custom_temporal_scope))
        return error.InvalidStylesheetImports;
    const results = try a.alloc(Joined, value.articles.len);
    var joined_count: usize = 0;
    errdefer {
        for (results[0..joined_count]) |*item| item.profile.deinit();
        a.free(results);
    }
    var last_page: u64 = 0;
    for (value.articles, results) |article, *result| {
        if (article.page_id <= last_page or article.revision_id == 0) return error.InvalidStylesheetImports;
        const child = try std.json.parseFromSlice(CustomSnapshot, a, article.snapshot, .{});
        defer child.deinit();
        const observed = child.value;
        if (!std.mem.eql(u8, observed.schema, custom_schema) or !matchesCustomRoot(observed, root, &root_sha256) or
            observed.ancestors.len < 2 or observed.ancestors[observed.ancestors.len - 1].end > observed.page_html.len or
            !styles.Profile.hasClass(observed.ancestors[0].classes, "client-nojs"))
            return error.InvalidStylesheetImports;
        try requireIndexedArticle(page_index, titles, article.page_id, article.revision_id, observed.page_title);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        try requireArticleUrl(sa, root.wiki, article.revision_id, observed);
        const prefix_end = observed.ancestors[observed.ancestors.len - 1].end;
        const identity = @import("page_language_prefix.zig").parseSelectedOldidAlloc(sa, observed.page_html[0..prefix_end],
            article.page_id, article.revision_id, 0, observed.page_title) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidStylesheetImports,
        };
        if (!std.mem.eql(u8, identity.root_language, namespaces.content_language)) return error.InvalidStylesheetImports;
        result.* = try buildCustomContext(a, root_css, article.snapshot, target, observed);
        result.proof.custom.?.article = .{ .page_id = article.page_id, .revision_id = article.revision_id };
        joined_count += 1;
        last_page = article.page_id;
    }
    return results;
}

fn requireArticleUrl(a: A, wiki: []const u8, revision_id: u64, observed: CustomSnapshot) !void {
    const suffix = "wiktionary";
    if (!std.mem.endsWith(u8, wiki, suffix) or wiki.len <= suffix.len) return error.InvalidStylesheetImports;
    const prefix = try std.fmt.allocPrint(a, "https://{s}.wiktionary.org/w/index.php?", .{wiki[0 .. wiki.len - suffix.len]});
    if (!std.mem.startsWith(u8, observed.page_url, prefix)) return error.InvalidStylesheetImports;
    var query = std.mem.splitScalar(u8, observed.page_url[prefix.len..], '&');
    const revision = try std.fmt.allocPrint(a, "{d}", .{revision_id});
    var has_title = false;
    var has_revision = false;
    var has_skin = false;
    while (query.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidStylesheetImports;
        const key = part[0..split];
        const raw_value = part[split + 1 ..];
        if (!has_title and std.mem.eql(u8, key, "title")) {
            var at: usize = 0;
            while (at < raw_value.len) : (at += 1) {
                if (raw_value[at] != '%') continue;
                if (raw_value.len - at < 3 or !std.ascii.isHex(raw_value[at + 1]) or !std.ascii.isHex(raw_value[at + 2]))
                    return error.InvalidStylesheetImports;
                at += 2;
            }
            const encoded = try a.dupe(u8, raw_value);
            std.mem.replaceScalar(u8, encoded, '+', ' ');
            if (!std.mem.eql(u8, std.Uri.percentDecodeInPlace(encoded), observed.page_title)) return error.InvalidStylesheetImports;
            has_title = true;
        } else if (!has_revision and std.mem.eql(u8, key, "oldid") and std.mem.eql(u8, raw_value, revision)) {
            has_revision = true;
        } else if (!has_skin and std.mem.eql(u8, key, "useskin") and std.mem.eql(u8, raw_value, observed.skin)) {
            has_skin = true;
        } else return error.InvalidStylesheetImports;
    }
    if (!has_title or !has_revision or !has_skin) return error.InvalidStylesheetImports;
}

pub fn joinIndexedAbsentCustomAlloc(a: A, snapshot_bytes: []const u8, target: styles.ReadingTarget, namespaces: anytype, page_index: []const u8, titles: anytype) !Joined {
    if (target != .screen or snapshot_bytes.len > max_snapshot_bytes) return error.InvalidStylesheetImports;
    const parsed = try std.json.parseFromSlice(AbsentCustomSnapshot, a, snapshot_bytes, .{});
    defer parsed.deinit();
    const value = parsed.value;
    const ns_hash = std.fmt.bytesToHex(namespaces.source_sha256, .lower);
    const absence = value.root_absence;
    if (!std.mem.eql(u8, value.schema, absent_custom_schema) or !std.mem.eql(u8, value.wiki, namespaces.wiki) or
        !std.mem.eql(u8, value.dump_date, namespaces.dump_date) or !std.mem.eql(u8, value.namespace_sha256, &ns_hash) or
        !std.mem.eql(u8, absence.namespace_registry_sha256, &ns_hash) or absence.namespace != 8 or !std.mem.eql(u8, absence.dbkey, "Common.css") or
        absence.page_table_bytes == 0 or value.article_page_id == 0 or value.article_revision_id == 0) return error.InvalidStylesheetImports;
    for ([_][]const u8{absence.page_table_sha256, absence.dumpstatus_sha256}) |hash| {
        if (hash.len != 64) return error.InvalidStylesheetImports;
        for (hash) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return error.InvalidStylesheetImports;
    }
    try requireIndexedArticle(page_index, titles, value.article_page_id, value.article_revision_id, value.page_title);
    var result = try buildCustomContext(a, null, snapshot_bytes, target, value);
    result.proof.custom.?.article = .{ .page_id = value.article_page_id, .revision_id = value.article_revision_id };
    return result;
}

fn requireIndexedArticle(page_index: []const u8, titles: anytype, page_id: u64, revision_id: u64, title: []const u8) !void {
    const dump_source = @import("wikimedia_dump");
    const ref = (try titles.lookup(page_index, title)) orelse return error.InvalidStylesheetImports;
    const at = dump_source.pageRowRefOffset(ref);
    if (at >= page_index.len or (at != 0 and page_index[at - 1] != '\n')) return error.InvalidStylesheetImports;
    const end = std.mem.indexOfScalarPos(u8, page_index, at, '\n') orelse page_index.len;
    const row = try dump_source.parsePageIndexLine(titles.kind, page_index[at..end]);
    if (row.ns != 0 or !row.has_source or row.redirect != null or !std.mem.eql(u8, row.content_model, "wikitext") or
        !std.mem.eql(u8, row.title, title) or row.page_id != page_id or row.revision_id != revision_id) return error.InvalidStylesheetImports;
}

fn buildCustomContext(a: A, css: ?[]const u8, snapshot_bytes: []const u8, target: styles.ReadingTarget, value: anytype) !Joined {
    const scope = if (css != null) custom_temporal_scope else "current anonymous server-emitted screen styles before client scripts applied to retained source; not historical dump deployment";
    if (!std.mem.eql(u8, value.temporal_scope, scope) or
        value.observed_utc.len < 20 or value.generator.len == 0 or value.skin.len == 0 or value.page_title.len == 0 or
        !std.mem.startsWith(u8, value.page_url, "https://") or
        value.page_html.len > 1024 * 1024 or !std.mem.eql(u8, value.page_sha256, &sha256(value.page_html)) or
        value.sources.len == 0 or value.sources.len > 32 or value.ancestors.len < 2 or value.ancestors.len > 32)
        return error.InvalidStylesheetImports;
    if (css == null and !styles.Profile.hasClass(value.ancestors[0].classes, "client-nojs")) return error.InvalidStylesheetImports;
    var profile = if (css) |raw| try styles.parseForTargetAlloc(a, raw, target) else try styles.parseSourcesForTargetAlloc(a, &.{}, target);
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
    const sources = try pa.alloc(styles.Source, value.sources.len + @intFromBool(css != null));
    const hashes = try pa.alloc([64]u8, value.sources.len);
    var total: usize = if (css) |raw| raw.len else 0;
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
    if (css) |raw| sources[value.sources.len] = .{ .css = raw, .base_url = "" };
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


const JvStylesheetJoinFixture = struct {
    const css = @embedFile("testdata/jv-css-imports/root.css");
    const snapshot = @embedFile("testdata/jv-css-imports/snapshot.json");
    const root: Root = .{ .wiki = "jvwiktionary", .dump_date = "20261001",
        .namespace_sha256 = "2b85c196fee979c1205821943a9a9b41b6058e6cb52a5e25014aa3b347dfb4d8",
        .page_id = 2634, .revision_id = 111278 };
    fn replacement(a: A, body: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(Snapshot, a, snapshot, .{});
        defer parsed.deinit();
        var value = parsed.value;
        value.resource.css = body;
        value.resource.css_bytes = body.len;
        const hash = sha256(body); value.resource.css_sha256 = &hash;
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(body, &digest, .{});
        const sha1 = std.fmt.bytesToHex(digest, .lower); value.resource.revision.source_sha1 = &sha1;
        return std.json.Stringify.valueAlloc(a, value, .{});
    }
};

test "actual JV imported stylesheet preserves source order table paint media uncertainty and codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = JvStylesheetJoinFixture;
    try std.testing.expectEqual(@as(usize, 517), F.css.len);
    try std.testing.expectEqualStrings("b6b63e49daaff945308beb48a2aa069e9574b4eefc3c39476ff6b01321ef66da", &sha256(F.css));
    try std.testing.expectEqualStrings("f03ba0d96e360d7b9dc216f5c171d7966082fa8f5b323f3e74805011e623e382", &sha256(F.snapshot));
    var joined = try joinAlloc(a, F.css, F.root, F.snapshot); defer joined.profile.deinit();
    try std.testing.expect(joined.proof.joined and !joined.profile.globally_unresolved);
    try std.testing.expect(joined.profile.has_unsupported_rules);
    try std.testing.expectEqual(@as(u64, 4259), joined.proof.page_id);
    try std.testing.expectEqual(@as(u64, 1737301), joined.proof.revision_id);
    try std.testing.expectEqualStrings("02923edddf2833e25353180e85fc5ec20c666a61c4256540a3cc7e845a10081a", &joined.proof.resource_sha256);
    try std.testing.expectEqualStrings("https://jv.wikipedia.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css", joined.proof.url);
    try std.testing.expectEqual(@as(usize, 3), joined.profile.sources.len);
    try std.testing.expectEqual(@as(usize, 0), joined.profile.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 35148), joined.profile.sources[1].bytes);
    try std.testing.expectEqualStrings("https://jv.wikipedia.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css&oldid=1737301", joined.profile.sources[1].base_url);
    const parsed = try std.json.parseFromSlice(Snapshot, a, F.snapshot, .{}); defer parsed.deinit();
    try std.testing.expectEqual(parsed.value.import.end, joined.profile.sources[2].byte_start);
    try std.testing.expectEqual(F.css.len - parsed.value.import.end, joined.profile.sources[2].bytes);
    const unknown = try joined.profile.resolveTableWithContext(a, 0, "portal-column-left", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expect(unknown.unresolved);
    // The retained width-dependent media rule can override float:left. No
    // viewport or media condition has been proved by this source-only join.
    try std.testing.expect(unknown.style == null or unknown.style.?.float_side == null);
    const encoder = @import("encoder");
    for ([_]struct { classes: []const u8, color: []const u8 }{
        .{ .classes = "cmbox", .color = "#dfe8ff" },
        .{ .classes = "cmbox cmbox-notice", .color = "#d8e8ff" },
    }) |case| {
        errdefer std.debug.print("JV imported table classes={s}, background={s}\n", .{ case.classes, case.color });
        const resolved = try joined.profile.resolveTableWithContext(a, 0, case.classes, .{ .ancestor_classes = "", .own_id = "" }, null, "");
        try std.testing.expectEqualStrings(case.color, resolved.style.?.background.?);
        try std.testing.expectEqual(encoder.presentation_types.BorderCollapse.collapse, resolved.style.?.collapse.?);
        const source = try std.fmt.allocPrint(a, "{{| class='{s}'\n| [[Visible|paint]] [https://example.test action]\n|}}", .{case.classes});
        const reference = try std.fmt.allocPrint(a, "{{| class='{s}' style='background:{s}!important'\n| [[Visible|paint]] [https://example.test action]\n|}}", .{ case.classes, case.color });
        var renderer: encoder.presentation_compile.Renderer = .{ .a = a, .context = .{ .table_styles = &joined.profile } };
        var control: encoder.presentation_compile.Renderer = .{ .a = a, .context = .{ .table_styles = &joined.profile } };
        const blocks = try renderer.renderBody(source); const reference_blocks = try control.renderBody(reference);
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        const table = blocks[0].table.?;
        try std.testing.expectEqualStrings(case.color, table.style.?.background.?);
        try std.testing.expectEqual(encoder.presentation_types.BorderCollapse.collapse, table.style.?.collapse.?);
        try std.testing.expectEqual(@as(usize, 1), table.rows.len);
        try std.testing.expectEqual(@as(usize, 1), table.rows[0].cells.len);
        var internal: usize = 0; var external: usize = 0; var visible: std.ArrayList(u8) = .empty;
        for (table.rows[0].cells[0].spans) |span| {
            try visible.appendSlice(a, span.text);
            if (span.kind == .link) { internal += 1; try std.testing.expectEqualStrings("Visible", span.target); }
            if (span.kind == .external_link) { external += 1; try std.testing.expectEqualStrings("https://example.test", span.target); }
        }
        try std.testing.expectEqualStrings("paint action", visible.items);
        try std.testing.expectEqual(@as(usize, 1), internal); try std.testing.expectEqual(@as(usize, 1), external);
        const Section = struct { level: u8 = 2, title: []const u8 = "Unclassified", blocks: @TypeOf(blocks) };
        const sections = [_]Section{.{ .blocks = blocks }}; const reference_sections = [_]Section{.{ .blocks = reference_blocks }};
        const bytes = try encoder.presentation_codec.encodeBuildAlloc(a, &[_]encoder.presentation_compile.Span{}, &sections, encoder.presentation_types.Layout{}, try renderer.finishReferences(), renderer.media.items);
        const expected_bytes = try encoder.presentation_codec.encodeBuildAlloc(a, &[_]encoder.presentation_compile.Span{}, &reference_sections, encoder.presentation_types.Layout{}, try control.finishReferences(), control.media.items);
        try std.testing.expectEqualSlices(u8, expected_bytes, bytes);
        const decoded = try encoder.presentation_codec.decodeAlloc(a, bytes, "JV imported paint", .language, .{ .code = "", .heading = "Unclassified" });
        try std.testing.expectEqualSlices(u8, bytes, try encoder.presentation_codec.encodeAlloc(a, decoded));
        try std.testing.expectEqual(@as(usize, 0), decoded.entry.media.len); try std.testing.expectEqual(@as(usize, 0), decoded.entry.references.len);
    }
}

test "JV imported media admission retains unresolved dependency and cross-profile guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator(); const F = JvStylesheetJoinFixture;
    const media = "@media only screen and (max-width:800px) { table.cmbox { background:#ffffff; } }";
    try std.testing.expect(!flatLeaf(media));
    try std.testing.expect(leafDependenciesKnown(media, true));
    var conditional = try joinAlloc(a, F.css, F.root, try F.replacement(a, media)); defer conditional.profile.deinit();
    try std.testing.expect(conditional.proof.joined and !conditional.profile.globally_unresolved);
    const unknown = try conditional.profile.resolveTableWithContext(a, 0, "cmbox", .{ .ancestor_classes = "", .own_id = "" }, null, "");
    try std.testing.expect(unknown.unresolved and (unknown.style == null or unknown.style.?.background == null));
    for ([_][]const u8{
        "@import 'missing.css'; table.cmbox{background:#fff;}",
        "@import 'https://jv.wikipedia.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css'; table.cmbox{background:#fff;}",
        "@media screen { @import 'nested.css'; table.cmbox{background:#fff;} }",
        "@supports (display:grid) { table.cmbox{background:#fff;} }",
        "@namespace svg 'https://example.test'; table.cmbox{background:#fff;}",
        "@mediax screen { table.cmbox{background:#fff;} }",
    }) |body| {
        try std.testing.expect(!leafDependenciesKnown(body, true));
        var missing = try joinAlloc(a, F.css, F.root, try F.replacement(a, body)); defer missing.profile.deinit();
        try std.testing.expect(!missing.proof.joined and missing.profile.globally_unresolved);
    }
    // Preserve the current normal ReadingTarget contract through the new
    // profile: medium selection is proved independently of captured ownership.
    const target_snapshot = try F.replacement(a,
        "@media screen{.readingOnly{text-align:right}}@media print{.readingOnly{text-align:left}}");
    var screen = try joinForTargetAlloc(a, F.css, F.root, target_snapshot, .screen); defer screen.profile.deinit();
    var print = try joinForTargetAlloc(a, F.css, F.root, target_snapshot, .print); defer print.profile.deinit();
    var target_unknown = try joinAlloc(a, F.css, F.root, target_snapshot); defer target_unknown.profile.deinit();
    try std.testing.expect(screen.proof.joined and print.proof.joined and target_unknown.proof.joined);
    try std.testing.expectEqual(styles.ReadingTarget.screen, screen.profile.reading_target);
    try std.testing.expectEqual(styles.ReadingTarget.print, print.profile.reading_target);
    const screen_alignment = try screen.profile.resolveAlignment(a, "div", "readingOnly", "", null, "");
    const print_alignment = try print.profile.resolveAlignment(a, "div", "readingOnly", "", null, "");
    try std.testing.expect(!screen_alignment.unresolved and screen_alignment.value.? == .right);
    try std.testing.expect(!print_alignment.unresolved and print_alignment.value.? == .left);
    try std.testing.expect((try target_unknown.profile.resolveAlignment(a, "div", "readingOnly", "", null, "")).unresolved);
    var unresolved_screen = try joinForTargetAlloc(a, F.css, F.root,
        try F.replacement(a, "@supports(display:grid){.readingOnly{text-align:right}}"), .screen);
    defer unresolved_screen.profile.deinit();
    try std.testing.expect(!unresolved_screen.proof.joined and unresolved_screen.profile.globally_unresolved);
    try std.testing.expectEqual(styles.ReadingTarget.screen, unresolved_screen.profile.reading_target);
    var wrong_root = F.root; wrong_root.wiki = "ptwiktionary";
    try std.testing.expectError(error.InvalidStylesheetImports, joinAlloc(a, F.css, wrong_root, F.snapshot));
    var absent = try styles.parseAlloc(a, F.css); defer absent.deinit();
    try std.testing.expect(absent.globally_unresolved);
}
