//! Real installed CLI behavior against a freshly built split dictionary.
const std = @import("std");
const source = "==English==\n===Etymology===\nHistorical source.\n===Noun===\n{{en-noun}}\n# A small animal.\n#: The cat sleeps.\n====Translations====\nFrench: chat\n====Synonyms====\nFeline\n===Quotations===\nA printed quotation\n===References===\nBook, 2020.\n";
const Harness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,
    fn run(self: *Harness, args: []const []const u8, expected: u8) ![]const u8 {
        const r = try std.process.run(self.a, self.io, .{ .argv = args, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
        if (r.term != .exited or r.term.exited != expected) {
            std.debug.print("Reader command failed: {s} {s} => {any}, expected {d}\n{s}\n{s}\n", .{ args[0], args[1], r.term, expected, r.stdout, r.stderr });
            return error.ChildFailed;
        }
        self.checks += 1;
        return r.stdout;
    }
    fn require(_: *Harness, ok: bool, label: []const u8) !void {
        if (!ok) {
            std.debug.print("Reader assertion failed: {s}\n", .{label});
            return error.AssertionFailed;
        }
    }
    fn entry(self: *Harness, text: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.a, text, .{});
        return parsed.value.object.get("entries").?.array.items[0];
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 4) return error.Usage;
    const dir = try std.fmt.allocPrint(a, "{s}/reader-integration-{d}", .{ argv[3], std.Io.Clock.awake.now(init.io).toNanoseconds() });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const dump = try std.fs.path.join(a, &.{ dir, "source.xml" });
    const root = try std.fs.path.join(a, &.{ dir, "blobs" });
    const xml = try std.fmt.allocPrint(a, "<mediawiki><page><title>cat</title><ns>0</ns><revision><text>{s}</text></revision></page></mediawiki>", .{source});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dump, .data = xml });
    var h: Harness = .{ .a = a, .io = init.io };
    const bin = argv[1];
    _ = try h.run(&.{ argv[2], dump, root }, 0);
    const complete = try h.entry(try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json", "--with-source" }, 0));
    try h.require(std.mem.eql(u8, complete.object.get("content").?.string, "complete"), "complete document");
    try h.require(std.mem.eql(u8, complete.object.get("source").?.string, source), "exact original source");
    const partial = try h.entry(try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json", "--core-only" }, 0));
    try h.require(std.mem.eql(u8, partial.object.get("content").?.string, "core"), "explicit partial document");
    try h.require(partial.object.get("source").? == .null, "partial document has no fake source");
    var deferred: usize = 0;
    for (partial.object.get("sections").?.array.items) |section| if (section.object.get("deferred").? != .null) {
        deferred += 1;
    };
    try h.require(deferred == 5, "all five families visibly deferred");
    const raw = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "source" }, 0);
    try h.require(std.mem.eql(u8, raw, source), "raw source round trip");
    const full_text = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, full_text, "Historical source") != null, "full details fetched");
    const details = try std.fs.path.join(a, &.{ root, "details" });
    const offline = try std.fs.path.join(a, &.{ root, "offline-details" });
    try std.Io.Dir.cwd().rename(details, std.Io.Dir.cwd(), offline, init.io);
    const core_text = try h.run(&.{ bin, "lookup", "cat", "--root", root }, 0);
    try h.require(std.mem.indexOf(u8, core_text, "small animal") != null and std.mem.indexOf(u8, core_text, "not loaded") != null, "default text works without companions");
    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--core-only", "--format", "json" }, 0);
    const page = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--core-only", "--format", "html" }, 0);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "core.html" }), .data = page });
    _ = try h.run(&.{ bin, "search", "cat", "--root", root, "--core-only", "--format", "html" }, 0);
    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--core-only", "--with-source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--core-only", "--runtime", "not-present" }, 2);
    try std.Io.Dir.cwd().rename(offline, std.Io.Dir.cwd(), details, init.io);
    const restored = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "source" }, 0);
    try h.require(std.mem.eql(u8, restored, source), "reinstalled companions preserve source");
    std.debug.print("READER_INTEGRATION_PASS checks={d}: core-only reading/JSON/HTML, all 5 deferred families, strict full/source/runtime requests, reinstall and exact reconstruction. Artifacts: {s}\n", .{ h.checks, dir });
}
