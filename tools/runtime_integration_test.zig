//! End-to-end tests use the real extractor, compiler, and native AOT worker.
const std = @import("std");
const source = "==English==\n===Noun===\n{{forms-alias|mouse}}\n# A small rodent.\n{{Template:Template:nested}}\n{{nested}}\n";
const module_source =
    \\local forms = require('Module:IntegrationFormsAlias')
    \\local alias_name = 'Module:IntegrationFormsAlias'
    \\local dynamic_forms = require(alias_name)
    \\assert(dynamic_forms.mouse == 'mice')
    \\local suffix = '!'
    \\local decorate = function(value) return value .. suffix end
    \\local identity = function(value) return value end
    \\local function plain(value) return value end
    \\return { render_dictionary_fixture = function(frame)
    \\    assert(decorate('static') == 'static!')
    \\    assert(identity('direct') == 'direct')
    \\    assert(plain('local-function') == 'local-function')
    \\    assert(mw.title.new('Appendix:IntegrationFixture'):getContent() == 'a real auxiliary source page')
    \\    local word = frame.args[1]
    \\    local plural = forms[word]
    \\    if not plural then error('No supplied plural for '..word) end
    \\    return "'''"..word.."''' (plural ''"..plural.."'')\n\n<div><table><caption>Forms from native Lua</caption><tr><th>Singular</th><th>Plural</th></tr><tr><td>"..word.."</td><td>"..plural.."</td></tr></table></div>\n"
    \\end }
;
const template_source = "<includeonly>{{#invoke:IntegrationForms|render_dictionary_fixture|{{{1}}}}}</includeonly><noinclude>Documentation must not leak.</noinclude>";
const Page = struct { title: []const u8, ns: u16, id: u32, body: []const u8, redirect: ?[]const u8 = null };
fn xml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}
fn fixture(io: std.Io, a: std.mem.Allocator, path: []const u8, broken: bool) !void {
    const pages = [_]Page{
        .{ .title = "mouse", .ns = 0, .id = 20, .body = source },
        .{ .title = "loop", .ns = 0, .id = 22, .body = "==English==\n===Noun===\n{{#invoke:IntegrationLoop|main}}\n# Never completes.\n" },
        .{ .title = "badcall", .ns = 0, .id = 23, .body = "==English==\n===Noun===\n{{#invoke:IntegrationBadCall|main}}\n" },
        .{ .title = "Appendix:IntegrationFixture", .ns = 100, .id = 21, .body = "a real auxiliary source page" },
        .{ .title = "Template:show-forms", .ns = 10, .id = 10, .body = template_source },
        .{ .title = "Template:forms-alias", .ns = 10, .id = 11, .body = "#REDIRECT [[Template:show-forms]]", .redirect = "Template:show-forms" },
        .{ .title = "Template:Template:nested", .ns = 10, .id = 12, .body = "nested namespace retained" },
        .{ .title = "Template:nested", .ns = 10, .id = 13, .body = "ordinary namespace distinct" },
        .{ .title = "Module:IntegrationForms", .ns = 828, .id = 1, .body = if (broken) "function {{{ invalid" else module_source },
        .{ .title = "Module:IntegrationFormsData", .ns = 828, .id = 2, .body = "return { mouse = 'mice', child = 'children' }" },
        .{ .title = "Module:IntegrationFormsAlias", .ns = 828, .id = 4, .body = "#REDIRECT [[Module:IntegrationFormsData]]", .redirect = "Module:IntegrationFormsData" },
        .{ .title = "Module:IntegrationLoop", .ns = 828, .id = 3, .body = "return { main = function() while true do end end }" },
        .{ .title = "Module:IntegrationBadCall", .ns = 828, .id = 5, .body = "return { main = function() local missing = nil; return missing() end }" },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<mediawiki>\n");
    for (pages) |p| {
        try w.print("<page><title>{s}</title><ns>{d}</ns><id>{d}</id>", .{ p.title, p.ns, p.id });
        if (p.redirect) |target| try w.print("<redirect title=\"{s}\"/>", .{target});
        try w.print("<revision><id>{d}</id><model>{s}</model><text>", .{ p.id + 100, if (p.ns == 828 and p.redirect == null) "Scribunto" else "wikitext" });
        try xml(w, p.body);
        try w.writeAll("</text></revision></page>\n");
    }
    try w.writeAll("</mediawiki>\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}
const Harness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,
    fn run(self: *Harness, argv: []const []const u8, code: u8) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } }).toDeadline(self.io) });
        if (result.term != .exited or result.term.exited != code) {
            std.debug.print("Unexpected child result {any}, expected {d}: {s}\n{s}\n{s}\n", .{ result.term, code, argv[0], result.stdout, result.stderr });
            return error.ChildFailed;
        }
        self.checks += 1;
        return result.stdout;
    }
    fn require(self: *Harness, condition: bool) !void {
        if (!condition) {
            std.debug.print("Runtime assertion failed after check {d}\n", .{self.checks});
            return error.AssertionFailed;
        }
    }
    fn entry(self: *Harness, bytes: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.a, bytes, .{});
        return parsed.value.object.get("entries").?.array.items[0];
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 5) return error.Usage;
    const bin = argv[1];
    const pipeline = argv[2];
    const ffi_test = argv[3];
    const dir = try std.fmt.allocPrint(a, "{s}/runtime-integration-{d}-{d}", .{ argv[4], std.os.linux.getpid(), std.Io.Clock.awake.now(init.io).toNanoseconds() });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    var h: Harness = .{ .a = a, .io = init.io };
    const dump = try std.fs.path.join(a, &.{ dir, "fixture.xml" });
    const root = try std.fs.path.join(a, &.{ dir, "dictionary" });
    const runtime = try std.fs.path.join(a, &.{ root, "runtime" });
    const input = try std.fs.path.join(a, &.{ dir, "input.wiki" });
    try fixture(init.io, a, dump, false);
    _ = try h.run(&.{ pipeline, "--with-blobs", dump, root }, 0);
    // Published runtime is self-sufficient: remove only this fixture's owned
    // extraction/build inputs, leaving the linked .wikblb artifacts at root.
    try std.Io.Dir.cwd().deleteTree(init.io, runtime);
    try std.Io.Dir.cwd().createDir(init.io, runtime, .default_dir);
    // The C ABI owns one long-lived worker. Exercise reuse, timeout-driven restart,
    // stable errors, search, random, and catalog access through the public ABI.
    const ffi_output = try h.run(&.{ ffi_test, root }, 0);
    try h.require(std.mem.indexOf(u8, ffi_output, "FFI_INTEGRATION_PASS") != null);
    const data = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--runtime", root, "--format", "json", "--with-source" }, 0);
    const entry = try h.entry(data);
    try h.require(std.mem.eql(u8, entry.object.get("expansion").?.object.get("status").?.string, "ok"));
    try h.require(std.mem.eql(u8, entry.object.get("expansion").?.object.get("backend").?.string, "lua-aot"));
    try h.require(std.mem.eql(u8, entry.object.get("source").?.string, source));
    const text = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--runtime", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, text, "mouse (plural mice)") != null);
    try h.require(std.mem.indexOf(u8, text, "Forms from native Lua") != null);
    try h.require(std.mem.indexOf(u8, text, "nested namespace retained") != null and std.mem.indexOf(u8, text, "ordinary namespace distinct") != null);
    const automatic = try h.entry(try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--format", "json" }, 0));
    try h.require(std.mem.eql(u8, automatic.object.get("expansion").?.object.get("status").?.string, "ok"));
    try h.require(std.mem.eql(u8, automatic.object.get("expansion").?.object.get("backend").?.string, "lua-aot"));
    const worker_path = try std.fs.path.join(a, &.{ root, "dict-native-expansion-worker" });
    const parked_worker = try std.fs.path.join(a, &.{ root, "dict-native-expansion-worker.off" });
    try std.Io.Dir.cwd().rename(worker_path, std.Io.Dir.cwd(), parked_worker, init.io);
    _ = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--runtime", root }, 2);
    try std.Io.Dir.cwd().rename(parked_worker, std.Io.Dir.cwd(), worker_path, init.io);
    try h.require(std.mem.indexOf(u8, text, "show-forms") == null and std.mem.indexOf(u8, text, "Documentation") == null);
    const raw = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--runtime", root, "--format", "source" }, 0);
    try h.require(std.mem.eql(u8, raw, source));
    _ = try h.run(&.{ pipeline, "--with-blobs", dump, root }, 1);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = input, .data = "{{#invoke:Missing|main}}" });
    const missing = try h.entry(try h.run(&.{ bin, "render", input, "--runtime", root, "--format", "json" }, 2));
    try h.require(std.mem.eql(u8, missing.object.get("expansion").?.object.get("status").?.string, "failed"));
    try h.require(std.mem.eql(u8, missing.object.get("expansion").?.object.get("backend").?.string, "lua-aot"));
    const missing_path = try std.fs.path.join(a, &.{ dir, "does-not-exist" });
    _ = try h.run(&.{ bin, "render", input, "--runtime", missing_path }, 2);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = input, .data = "{{#invoke:IntegrationLoop|main}}" });
    const timed = try h.entry(try h.run(&.{ bin, "render", input, "--runtime", root, "--runtime-timeout-ms", "200", "--format", "json" }, 2));
    try h.require(std.mem.eql(u8, timed.object.get("expansion").?.object.get("backend").?.string, "lua-aot"));
    try h.require(std.mem.indexOf(u8, timed.object.get("expansion").?.object.get("diagnostic").?.string, "timed out") != null);
    const marker = try std.fs.path.join(a, &.{ runtime, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = "unfinished" });
    _ = try h.run(&.{ bin, "render", input, "--runtime", root }, 2);
    try std.Io.Dir.cwd().deleteFile(init.io, marker);
    const bad_dump = try std.fs.path.join(a, &.{ dir, "invalid.xml" });
    const bad_root = try std.fs.path.join(a, &.{ dir, "invalid-runtime" });
    try fixture(init.io, a, bad_dump, true);
    _ = try h.run(&.{ pipeline, bad_dump, bad_root }, 1);
    var marker_file = try std.Io.Dir.cwd().openFile(init.io, try std.fs.path.join(a, &.{ bad_root, ".incomplete" }), .{});
    marker_file.close(init.io);
    std.debug.print("RUNTIME_INTEGRATION_PASS checks={d}: XML extraction, native AOT execution, mandatory native worker selection, persistent FFI worker reuse/restart, require, stable cross-shard errors, template transclusion, table rendering, raw source, explicit failures, deadline, incomplete-build refusal. Artifacts: {s}\n", .{ h.checks, dir });
}
