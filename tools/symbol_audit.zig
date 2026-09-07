//! Verify persisted shared IDs against the exact original owner-compiled programs.
const std = @import("std");
const enc = @import("blob_encoder");
const files = @import("blob_files");
const vm = @import("runtime_symbols");
const A = std.mem.Allocator;
const Map = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    fn open(io: std.Io, path: []const u8) !Map {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        const n = std.math.cast(usize, (try f.stat(io)).size) orelse return error.FileTooBig;
        return .{ .bytes = try std.posix.mmap(null, n, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0) };
    }
    fn deinit(self: Map) void {
        std.posix.munmap(self.bytes);
    }
};
fn key(names: enc.call_symbols.Names, title: []const u8, kind: enc.call_symbols.Kind) ![]const u8 {
    if (title.len != 16) return error.InvalidKey;
    const id = try std.fmt.parseInt(usize, title, 16);
    const text = try names.get(id);
    if (names.keys[id - 1][0] != @intFromEnum(kind)) return error.WrongSymbolKind;
    return text;
}
fn poolReferences(a: A, bytes: []const u8, names: enc.call_symbols.Names) !usize {
    return vm.countLinkedPoolReferences(a, bytes, names);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    var source: files.SymbolSource = .{ .io = init.io, .a = init.gpa, .root = args[1] };
    defer source.deinit();
    const names = try source.load();
    const identity = names.digest();
    var original = std.StringHashMap([]const u8).init(a);
    var maps: [2]?Map = @splat(null);
    defer for (maps) |m| if (m) |v| v.deinit();
    for ([_][]const u8{ "modules.bundle", "dependencies/modules.bundle" }, 0..) |name, i| {
        const path = try std.fs.path.join(a, &.{ args[2], name });
        maps[i] = Map.open(init.io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        var it = try vm.BundleIterator.init(maps[i].?.bytes);
        while (try it.next()) |r| try original.put(r.title, r.program);
    }
    var programs = try files.File.open(init.io, init.gpa, try std.fs.path.join(a, &.{ args[1], "bytecode.wikblb" }));
    defer programs.deinit();
    if (programs.index.blob.kind != .bytecode or !std.mem.eql(u8, &programs.index.blob.binding_id, &identity)) return error.SymbolIdentityMismatch;
    var it = programs.index.blob.iterator();
    var n: usize = 0;
    var operands: usize = 0;
    while (try it.next()) |r| {
        const title = try key(names, r.title, .module);
        const expected = original.get(title) orelse return error.MissingOriginalProgram;
        const bound = try vm.bindProgramAlloc(init.gpa, r.payload, names);
        defer init.gpa.free(bound);
        if (!std.mem.eql(u8, bound, expected)) {
            std.debug.print("Mismatched module {s}\n", .{title});
            return error.ProgramMismatch;
        }
        operands += try poolReferences(init.gpa, r.payload, names);
        n += 1;
    }
    if (n != original.count()) return error.MissingLinkedProgram;
    var templates = try files.File.open(init.io, init.gpa, try std.fs.path.join(a, &.{ args[1], "templates.wikblb" }));
    defer templates.deinit();
    if (templates.index.blob.kind != .templates or !std.mem.eql(u8, &templates.index.blob.binding_id, &identity)) return error.SymbolIdentityMismatch;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ args[2], "template-manifest.tsv" }), a, .limited(32 * 1024 * 1024));
    var rows = std.mem.splitScalar(u8, manifest, '\n');
    var count: usize = 0;
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const pageid = f.next().?;
        const name = f.next().?;
        const local = try manifestText(a, if (std.ascii.startsWithIgnoreCase(name, "Template:")) name[9..] else name);
        // Manifest escaping is rare but remains significant; audit source rows used by linker.
        const id = names.find(.template, local) orelse return error.UnboundTemplate;
        var k: [16]u8 = undefined;
        const r = (try templates.index.find(try std.fmt.bufPrint(&k, "{x:0>16}", .{id}))) orelse return error.MissingTemplate;
        var pos: usize = 0;
        const redirect = try enc.blob_format.readPayloadLength(r.payload, &pos);
        if (redirect != 0) _ = try names.get(redirect);
        const bound = try enc.call_symbols.decodeAlloc(init.gpa, r.payload[pos..], names);
        defer if (bound) |b| init.gpa.free(b);
        const path = try std.fmt.allocPrint(a, "{s}/templates/{s}.wiki", .{ args[2], pageid });
        const body = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(32 * 1024 * 1024));
        defer init.gpa.free(body);
        if (!std.mem.eql(u8, bound orelse r.payload[pos..], body)) return error.TemplateSourceMismatch;
        var scan: enc.call_symbols.Scanner = .{ .text = r.payload[pos..] };
        if (scan.next() != null) return error.UnlinkedTemplateCall;
        count += 1;
    }
    if (count != templates.index.recordCount()) return error.TemplateCountMismatch;
    std.debug.print("SYMBOL_AUDIT_PASS symbols={d} programs={d} bytecode_symbol_operands={d} templates={d} owner_bytecode_exact=true template_source_exact=true shared_identity=true\n", .{ names.keys.len, n, operands, count });
}

fn manifestText(a: A, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            c = switch (text[i]) {
                't' => '\t',
                'r' => '\r',
                'n' => '\n',
                else => text[i],
            };
        }
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
