//! End-to-end bundle test: Lua/templates execute before data blobs are published.
const std = @import("std");
const expander = @import("bundle_expander.zig");

const source =
    "==English==\n===Noun===\n{{forms-alias|mouse}}\n" ++
    "# A small rodent.\n{{Template:Template:nested}}\n{{nested}}\n{{T:nested}}\n" ++
    "{{:SharedAlias}}\n{{WT:Sandbox}}\n" ++
    "# Title magic: {{SUBJECTSPACE:Wiktionary talk:Sandbox}} / {{TALKSPACE:WT:Sandbox}}\n" ++
    "# Parser functions: {{#time:Y M d|2013-3-31 +8 days}} / {{#sub:αβγ|-1}} / {{#iferror:{{#expr:bogus}}|ERR|OK}}\n" ++
    "# Formatting magic: {{formatnum:11000}} / {{formatnum:1,234.50|R}} / {{anchorencode:[[foo|A B]] <b>x</b>&nbsp;C}}\n" ++
    "# Title parts: {{#titleparts:A/B/C|1|2}} / {{#titleparts:A/B/C|-1}}\n" ++
    "# Escaped title: {{PAGENAMEE:Appendix:A B/é?x}} / {{FULLPAGENAMEE:Appendix:A B/é?x}}\n" ++
    "# Subpage namespaces: {{BASEPAGENAME:Template:foo/bar}} / {{BASEPAGENAME:Category:foo/bar}}\n" ++
    "# Revision metadata: {{PAGEID}} / {{REVISIONID}} / {{REVISIONTIMESTAMP}} / {{REVISIONUSER}} / {{PAGEID:rat}} / {{REVISIONUSER:rat}}\n";
const module_source =
    \\local forms = require('Module:IntegrationFormsAlias')
    \\local alias_name = 'Module:IntegrationFormsAlias'
    \\assert(require(alias_name).mouse == 'mice')
    \\return {
    \\frame_probe = function(frame) return frame.args.x end,
    \\render_dictionary_fixture = function(frame)
    \\    assert(mw.title.new('Appendix:IntegrationFixture'):getContent() == 'a real auxiliary source page')
    \\    assert(string.find(mw.title.new('Template:forms-alias'):getContent(), '#REDIRECT', 1, true))
    \\    assert(string.find(mw.title.new('SharedAlias'):getContent(), '#REDIRECT', 1, true))
    \\    local shared_alias = mw.title.new('SharedAlias')
    \\    assert(shared_alias.isRedirect and shared_alias.redirectTarget.prefixedText == 'Shared')
    \\    assert(shared_alias.id == 24 and shared_alias.redirectTarget.id == 23)
    \\    assert(mw.title.new('rat').contentModel == 'wikitext')
    \\    assert(not mw.title.new('rat').isExternal and mw.title.new('rat').isLocal)
    \\    local interwiki_ok = pcall(mw.title.new, 'w:Example')
    \\    assert(not interwiki_ok)
    \\    assert(mw.title.new('Module:IntegrationForms').contentModel == 'Scribunto')
    \\    assert(mw.title.new('Module:IntegrationForms', 10).prefixedText == 'Module:IntegrationForms')
    \\    assert(mw.title.makeTitle(10, 'Module:IntegrationForms').prefixedText == 'Template:Module:IntegrationForms')
    \\    assert(mw.title.new('Foo&amp;Bar').prefixedText == 'Foo&Bar')
    \\    assert(mw.title.new('Module&#58;IntegrationForms', 10).prefixedText == 'Module:IntegrationForms')
    \\    assert(mw.title.makeTitle(0, 'Foo&amp;Bar') == nil)
    \\    assert(mw.title.new('Foo&amp;amp;Bar') == nil)
    \\    assert(mw.title.new('  foo__  bar  ').prefixedText == 'foo bar')
    \\    assert(mw.title.new(':foo', 10).prefixedText == 'foo')
    \\    assert(mw.title.new('Template : Foo').prefixedText == 'Template:Foo')
    \\    assert(mw.title.new('foo[bar') == nil and mw.title.new('foo%20bar') == nil and mw.title.new('foo/../bar') == nil)
    \\    assert(mw.title.new('Cafe&#x301;').prefixedText == 'Café')
    \\    local bad_namespace = pcall(mw.title.new, 'Thing', 'not-a-namespace')
    \\    assert(not bad_namespace)
    \\    assert(mw.title.new('Module:DefinitelyMissing').contentModel == 'Scribunto')
    \\    assert(mw.title.new('User:Example/common.css').contentModel == 'css')
    \\    assert(mw.hash.hashValue('md5', 'abc') == '900150983cd24fb0d6963f7d28e17f72')
    \\    assert(mw.ustring.upper('straße ﬃ') == 'STRASSE FFI')
    \\    assert(mw.ustring.lower('İ') == 'i̇')
    \\    assert(mw.text.truncate('wako', -2, '') == 'ko')
    \\    assert(mw.text.decode('can&#39;t &amp; stay') == [[can't & stay]])
    \\    local official_uri = mw.uri.new('https://main.knesset.gov.il/apps/smartprotocol/session/123/456?itemid=7')
    \\    assert(mw.uri.validate(official_uri))
    \\    assert(official_uri.protocol == 'https' and official_uri.host == 'main.knesset.gov.il')
    \\    assert(official_uri.path == '/apps/smartprotocol/session/123/456' and official_uri.query.itemid == '7')
    \\    assert(type(mw.site.stats.pagesInCategory) == 'function')
    \\    assert(tostring(mw.html.create('div'):tag('br'):allDone()) == '<div><br /></div>')
    \\    assert(mw.text.encode('a&b') == 'a&amp;b')
    \\    assert(mw.text.tag('div', {class = 'chart'}, 'x') == '<div class=\"chart\">x</div>')
    \\    assert(mw.text.tag('div', {class = 'chart'}) == '<div class=\"chart\">')
    \\    local strip_marker = frame:extensionTag('nowiki', 'hidden')
    \\    assert(mw.text.killMarkers('a' .. strip_marker .. 'b') == 'ab')
    \\    local json_value = mw.text.jsonDecode('{"x":[1,2]}', mw.text.JSON_TRY_FIXING)
    \\    assert(json_value.x[2] == 2 and mw.text.jsonEncode(json_value) == '{"x":[1,2]}')
    \\    local json_data = mw.loadJsonData('Module:IntegrationFormsData.json')
    \\    assert(json_data.cuts[2] == 2 and json_data.nested.ok)
    \\    assert(json_data == mw.loadJsonData('Module:IntegrationFormsData.json'))
    \\    local json_write_ok = pcall(function() json_data.cuts[1] = 9 end)
    \\    assert(not json_write_ok)
    \\    assert(mw.getContentLanguage():ucfirst('hello') == 'Hello')
    \\    local unicode_case_ok = pcall(function() return mw.getContentLanguage():ucfirst('éclair') end)
    \\    assert(not unicode_case_ok)
    \\    local locale_registry_ok = pcall(mw.language.isKnownLanguageTag, 'fr')
    \\    assert(not locale_registry_ok)
    \\    local batch = mw.title.newBatch({'rat', 'definitely-not-a-real-entry'}):lookupExistence():getTitles()
    \\    assert(batch[1].exists and not batch[2].exists)
    \\    local media = mw.title.new('Media:Remote.svg')
    \\    assert(media.prefixedText == 'Media:Remote.svg')
    \\    local media_ok = pcall(function() return media.exists end)
    \\    assert(not media_ok)
    \\    local media_batch = mw.title.newBatch({'Media:Remote.svg'}):lookupExistence():getTitles()
    \\    local media_batch_ok = pcall(function() return media_batch[1].exists end)
    \\    assert(not media_batch_ok)
    \\    assert(frame:callParserFunction{ name = '#invoke', args = {'IntegrationForms', 'frame_probe', x = 'frame-parser'} } == 'frame-parser')
    \\    assert(frame:callParserFunction{ name = '#tag:syntaxhighlight', args = {'x', lang = 'text'} } == '<syntaxhighlight lang="text">x</syntaxhighlight>')
    \\    assert(frame:callParserFunction{ name = '#tag', args = {'ref', 'body', 'name=n'} } == '<ref name="n">body</ref>')
    \\    assert(mw.title.new('rat'):fullUrl({action = 'view'}, 'https') == 'https://en.wiktionary.org/w/index.php?title=rat&action=view')
    \\    assert(mw.title.new('rat').exists)
    \\    assert(string.find(mw.title.new('rat'):getContent(), 'Another rodent', 1, true))
    \\    assert(not mw.title.new('definitely-not-a-real-entry').exists)
    \\    local word = frame.args[1]
    \\    local plural = forms[word]
    \\    frame:callParserFunction("DISPLAYTITLE", "''" .. word .. "''")
    \\    return "'''"..word.."''' (plural ''"..plural.."'')\n\n" ..
    \\        "<table><caption>Forms from native Lua</caption><tr><td>"..plural.."</td></tr></table>\n"
    \\end }
;
const template_source =
    "<includeonly>{{#invoke:IntegrationForms|render_dictionary_fixture|{{{1}}}}}</includeonly>" ++
    "<noinclude>Documentation must not leak.</noinclude>";

const Page = struct { title: []const u8, ns: u16, id: u32, body: []const u8, user: []const u8 = "Fixture editor", redirect: ?[]const u8 = null, model: ?[]const u8 = null };
fn xml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}

fn writeFixture(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    const pages = [_]Page{
        .{ .title = "mouse", .ns = 0, .id = 20, .body = source },
        .{ .title = "rat", .ns = 0, .id = 22, .body = "==English==\n===Noun===\n# Another rodent.\n", .user = "Rat editor" },
        .{ .title = "Shared", .ns = 0, .id = 23, .body = "shared main transclusion" },
        .{ .title = "SharedAlias", .ns = 0, .id = 24, .body = "#REDIRECT [[Shared]]", .redirect = "Shared" },
        .{ .title = "Wiktionary:Sandbox", .ns = 4, .id = 25, .body = "project namespace transclusion" },
        .{ .title = "Appendix:IntegrationFixture", .ns = 100, .id = 21, .body = "a real auxiliary source page" },
        .{ .title = "Template:show-forms", .ns = 10, .id = 10, .body = template_source },
        .{ .title = "Template:forms-alias", .ns = 10, .id = 11, .body = "#REDIRECT [[Template:show-forms]]", .redirect = "Template:show-forms" },
        .{ .title = "Template:Template:nested", .ns = 10, .id = 12, .body = "nested namespace retained" },
        .{ .title = "Template:nested", .ns = 10, .id = 13, .body = "ordinary namespace distinct" },
        .{ .title = "Module:IntegrationForms", .ns = 828, .id = 1, .body = module_source },
        .{ .title = "Module:languages/canonical names", .ns = 828, .id = 3, .body = "return { [\"English\"] = \"en\" }" },
        .{ .title = "Module:IntegrationFormsData", .ns = 828, .id = 2, .body = "return { mouse = 'mice' }" },
        .{ .title = "Module:IntegrationFormsData.json", .ns = 828, .id = 5, .body = "{\"cuts\":[1,2],\"nested\":{\"ok\":true}}", .model = "json" },
        .{ .title = "Module:IntegrationFormsAlias", .ns = 828, .id = 4, .body = "#REDIRECT [[Module:IntegrationFormsData]]", .redirect = "Module:IntegrationFormsData" },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<mediawiki>\n");
    for (pages) |page| {
        try w.print("<page><title>{s}</title><ns>{d}</ns><id>{d}</id>", .{ page.title, page.ns, page.id });
        if (page.redirect) |target| try w.print("<redirect title=\"{s}\"/>", .{target});
        try w.print("<revision><id>{d}</id><timestamp>2024-03-04T05:06:07Z</timestamp><contributor><username>", .{page.id + 100});
        try xml(w, page.user);
        const model = page.model orelse if (page.ns == 828 and page.redirect == null) "Scribunto" else "wikitext";
        try w.print("</username></contributor><model>{s}</model><text>", .{model});
        try xml(w, page.body);
        try w.writeAll("</text></revision></page>\n");
    }
    try w.writeAll("</mediawiki>\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

const Harness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,

    fn run(self: *Harness, argv: []const []const u8, expected: u8) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } }).toDeadline(self.io),
        });
        if (result.term != .exited or result.term.exited != expected) {
            std.debug.print("bundle integration child failed: {any}, expected {d}\n{s}\n{s}\n", .{
                result.term, expected, result.stdout, result.stderr,
            });
            return error.ChildFailed;
        }
        self.checks += 1;
        return result.stdout;
    }

    fn require(self: *Harness, ok: bool, label: []const u8) !void {
        if (ok) return;
        std.debug.print("bundle integration assertion failed after {d} checks: {s}\n", .{ self.checks, label });
        return error.AssertionFailed;
    }
};

fn exists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn deadlineProbe(io: std.Io, a: std.mem.Allocator, dir: []const u8) !void {
    var worker = expander.Worker.init(io, dir, "tail", "missing-dump.xml");
    worker.timeout_ms = 100;
    defer worker.deinit();
    try std.testing.expectError(error.Timeout, worker.expand(a, "probe", "==English==\n"));
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 5) return error.Usage;
    const bin = argv[1];
    const pipeline = argv[2];
    const verifier = argv[3];
    const dir = try std.fmt.allocPrint(a, "{s}/bundle-integration-{d}-{d}", .{
        argv[4], std.os.linux.getpid(), std.Io.Clock.awake.now(init.io).toNanoseconds(),
    });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    var h: Harness = .{ .a = a, .io = init.io };

    try deadlineProbe(init.io, a, dir);
    h.checks += 1;

    const dump = try std.fs.path.join(a, &.{ dir, "fixture.xml" });
    try writeFixture(init.io, a, dump);

    const existing_root = try std.fs.path.join(a, &.{ dir, "existing-dictionary" });
    try std.Io.Dir.cwd().createDir(init.io, existing_root, .default_dir);
    _ = try h.run(&.{ pipeline, dump, existing_root }, 1);
    const existing_marker = try std.fs.path.join(a, &.{ existing_root, ".incomplete" });
    try h.require(!exists(init.io, existing_marker), "existing output directory stays untouched");

    const failed_root = try std.fs.path.join(a, &.{ dir, "failed-dictionary" });
    const missing_dump = try std.fs.path.join(a, &.{ dir, "missing.xml" });
    _ = try h.run(&.{ pipeline, missing_dump, failed_root }, 1);
    const failed_marker = try std.fs.path.join(a, &.{ failed_root, ".incomplete" });
    try h.require(exists(init.io, failed_marker), "failed build retains incomplete marker");

    const root = try std.fs.path.join(a, &.{ dir, "dictionary" });
    _ = try h.run(&.{ pipeline, dump, root }, 0);
    _ = try h.run(&.{ verifier, root }, 0);

    const forbidden = [_][]const u8{
        ".bundle-expander", "runtime",          "dict-bundle-expander",
        "symbols.wikblb",   "templates.wikblb", "redirects.wikblb",
        "pages.wikblb",
    };
    for (forbidden) |name| {
        const path = try std.fs.path.join(a, &.{ root, name });
        try h.require(!exists(init.io, path), name);
    }
    const incomplete = try std.fs.path.join(a, &.{ root, ".incomplete" });
    try h.require(!exists(init.io, incomplete), "completed bundle marker removed");

    const text = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, text, "plural mice") != null, "Lua result is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Forms from native Lua") != null, "template result is baked into data");
    try h.require(std.mem.indexOf(u8, text, "shared main transclusion") != null, "main-page redirect transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "project namespace transclusion") != null, "namespace-alias transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Title magic: Wiktionary / Wiktionary talk") != null, "title magic words are resolved before publication");
    try h.require(std.mem.indexOf(u8, text, "Parser functions: 2013 Apr 08 / γ / ERR") != null, "corpus parser functions are baked into data");
    try h.require(std.mem.indexOf(u8, text, "Formatting magic: 11,000 / 1234.50 / A_B_x_C") != null, "formatting magic is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Title parts: B / A/B") != null, "titleparts is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Escaped title: A_B/%C3%A9%3Fx / Appendix:A_B/%C3%A9%3Fx") != null, "escaped title magic is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Subpage namespaces: foo / foo/bar") != null, "namespace subpage semantics are baked into data");
    try h.require(std.mem.indexOf(u8, text, "Revision metadata: 20 / 120 / 20240304050607 / Fixture editor / 22 / Rat editor") != null, "page revision metadata is baked into data");
    try h.require(std.mem.indexOf(u8, text, "ordinary namespace distinct") != null, "Template namespace alias resolves through corpus transclusion");
    try h.require(std.mem.indexOf(u8, text, "Documentation") == null, "noinclude does not leak");
    try h.require(std.mem.indexOf(u8, text, "#invoke") == null, "no executable invoke syntax survives");

    const exported = try h.run(&.{ bin, "export", "mouse", "--root", root }, 0);
    var exported_json = try std.json.parseFromSlice(std.json.Value, a, exported, .{});
    defer exported_json.deinit();
    const exported_entries = exported_json.value.object.get("entries") orelse return error.InvalidExport;
    try h.require(exported_entries == .array and exported_entries.array.items.len == 1, "compiled export contains the requested entry");
    const exported_entry = exported_entries.array.items[0].object;
    const display_title = exported_entry.get("display_title") orelse return error.InvalidExport;
    try h.require(display_title == .array and display_title.array.items.len == 1, "DISPLAYTITLE survives publication as semantic spans");
    const display_span = display_title.array.items[0].object;
    try h.require(std.mem.eql(u8, display_span.get("text").?.string, "mouse"), "display-title text remains the canonical page name");
    try h.require(display_span.get("italic").?.bool, "display-title emphasis is compiled into presentation data");
    try h.require(std.mem.eql(u8, exported_entry.get("title").?.string, "mouse"), "display title does not replace the canonical lookup key");
    try h.require(std.mem.eql(u8, exported_entry.get("language_code").?.string, "en"), "language code comes from extracted canonical-name module metadata");

    std.debug.print(
        "BUNDLE_INTEGRATION_PASS checks={d}: destination refusal, incomplete failure marker, verified pre-expanded Lua/templates, data-only final tree. Artifacts: {s}\n",
        .{ h.checks, dir },
    );
}
