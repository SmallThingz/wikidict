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
    if (argv.len != 5) return error.Usage;
    const dir = try std.fmt.allocPrint(a, "{s}/reader-integration-{d}", .{ argv[4], std.Io.Clock.awake.now(init.io).toNanoseconds() });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const dump = try std.fs.path.join(a, &.{ dir, "source.xml" });
    const root = try std.fs.path.join(a, &.{ dir, "blobs" });
    const xml = try std.fmt.allocPrint(a, "<mediawiki><page><title>cat</title><ns>0</ns><revision><text>{s}</text></revision></page></mediawiki>", .{source});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dump, .data = xml });
    var h: Harness = .{ .a = a, .io = init.io };
    const bin = argv[1];
    const ffi_test = argv[3];
    _ = try h.run(&.{ argv[2], dump, root }, 0);
    const ffi_output = try h.run(&.{ ffi_test, root, "cat" }, 0);
    try h.require(std.mem.indexOf(u8, ffi_output, "FFI_INTEGRATION_PASS") != null, "data-only C ABI");
    const complete = try h.entry(try h.run(&.{ bin, "lookup", "cat", "--root", root, "--format", "json" }, 0));
    try h.require(complete.object.get("sections").?.array.items.len != 0, "complete compiled document");
    const text = try h.run(&.{ bin, "lookup", "cat", "--root", root }, 0);
    try h.require(std.mem.indexOf(u8, text, "small animal") != null, "compiled definition renders");
    const details_text = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, details_text, "Historical source") != null, "compiled supporting material renders");

    // No reader-side companion package is required any more. Removing the legacy
    // directory must not change lookups because each record is self-contained.
    const details = try std.fs.path.join(a, &.{ root, "details" });
    try std.Io.Dir.cwd().deleteTree(init.io, details);
    const after_delete = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, after_delete, "Historical source") != null, "compiled record is self-contained");

    _ = try h.run(&.{ bin, "lookup", "cat", "--root", root, "--core-only" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--format", "source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--with-source" }, 2);
    _ = try h.run(&.{ bin, "lookup", "cat", "--runtime", "not-present" }, 2);
    std.debug.print("READER_INTEGRATION_PASS checks={d}: self-contained compiled presentation, data-only JSON/CLI/FFI, no source/runtime/core fallback. Artifacts: {s}\n", .{ h.checks, dir });
}
