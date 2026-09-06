//! Loads ID-addressed artifacts into the VM's existing API without changing its
//! compiler/runtime. Name strings are bound once, preserving dynamic Lua keys.
const std = @import("std");
const enc = @import("blob_encoder");
const files = @import("blob_files");
const bridge = @import("runtime_bridge");
const vm_symbols = @import("runtime_symbols");
const A = std.mem.Allocator;
const storage = @import("blob_storage");
pub const Session = struct {
    symbols: files.SymbolSource,
    templates: ?storage.File = null,
    bytecode: ?storage.File = null,
    redirects: ?storage.File = null,
    pub fn deinit(self: *Session) void {
        if (self.templates) |*f| f.deinit();
        if (self.bytecode) |*f| f.deinit();
        if (self.redirects) |*f| f.deinit();
        self.symbols.deinit();
    }
};
fn pathExists(io: std.Io, path: []const u8) !bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const a = std.heap.smp_allocator;
            const compressed = try std.mem.concat(a, u8, &.{ path, ".xz" });
            defer a.free(compressed);
            var zipped = std.Io.Dir.cwd().openFile(io, compressed, .{}) catch |e| switch (e) {
                error.FileNotFound => return false,
                else => return e,
            };
            zipped.close(io);
            return true;
        },
        else => return err,
    };
    f.close(io);
    return true;
}
pub fn rootAlloc(io: std.Io, a: A, requested: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ requested, "bytecode.wikblb" });
    defer a.free(path);
    if (try pathExists(io, path)) return a.dupe(u8, requested);
    // Compatibility with the coordinated build's previously documented path.
    if (std.mem.eql(u8, std.fs.path.basename(requested), "runtime")) if (std.fs.path.dirname(requested)) |parent| {
        const compiled = try std.fs.path.join(a, &.{ parent, "bytecode.wikblb" });
        defer a.free(compiled);
        if (try pathExists(io, compiled)) return a.dupe(u8, parent);
    };
    return a.dupe(u8, requested);
}
fn artifact(io: std.Io, a: A, root: []const u8, name: []const u8, kind: enc.blob_format.BlobKind, identity: [32]u8) !storage.File {
    const path = try std.fs.path.join(a, &.{ root, name });
    defer a.free(path);
    var file = try storage.File.open(io, a, path);
    errdefer file.deinit();
    const view = file.view;
    if (!view.symbolic or view.kind != kind) return error.InvalidRuntimeArtifact;
    if (!std.mem.eql(u8, &view.binding_id, &identity)) return error.SymbolIdentityMismatch;
    return file;
}
fn symbol(names: enc.call_symbols.Names, key: []const u8, kind: enc.call_symbols.Kind) ![]const u8 {
    if (key.len != 16) return error.InvalidSymbolKey;
    const id = try std.fmt.parseInt(usize, key, 16);
    var expected: [16]u8 = undefined;
    if (!std.mem.eql(u8, key, try std.fmt.bufPrint(&expected, "{x:0>16}", .{id}))) return error.InvalidSymbolKey;
    const text = try names.get(id);
    if (names.keys[id - 1][0] != @intFromEnum(kind)) return error.SymbolKindMismatch;
    return text;
}
fn templateName(a: A, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    // Symbol entries for definitions already omit exactly one namespace prefix.
    // A template whose local name starts "Template:" must keep that local prefix.
    const body = trimmed;
    const title = try std.fmt.allocPrint(a, "Template:{s}", .{body});
    std.mem.replaceScalar(u8, title, '_', ' ');
    return title;
}
pub fn load(runtime: *bridge.Runtime, root: []const u8) !?Session {
    const io = runtime.io;
    const a = runtime.persistent_allocator;
    const path = try std.fs.path.join(a, &.{ root, "bytecode.wikblb" });
    defer a.free(path);
    if (!try pathExists(io, path)) return null;
    try files.requireComplete(io, a, root);
    var session: Session = .{ .symbols = .{ .io = io, .a = a, .root = root } };
    errdefer session.deinit();
    const names = try session.symbols.load();
    const identity = names.digest();
    session.templates = try artifact(io, a, root, "templates.wikblb", .templates, identity);
    session.bytecode = try artifact(io, a, root, "bytecode.wikblb", .bytecode, identity);
    session.redirects = try artifact(io, a, root, "redirects.wikblb", .redirects, identity);
    const ModuleSlot = @typeInfo(@TypeOf(runtime.modules.get("").?)).pointer.child;
    const TemplateSlot = @typeInfo(@TypeOf(runtime.templates.get("").?)).pointer.child;
    runtime.bundle_index = .{};
    for (0..session.bytecode.?.recordCount()) |record_index| {
        var r = try session.bytecode.?.readAlloc(std.heap.smp_allocator, record_index);
        defer r.deinit();
        const title = try symbol(names, r.title, .module);
        const bound = try vm_symbols.bindProgramAlloc(a, r.payload, names);
        errdefer a.free(bound);
        const slot = try a.create(ModuleSlot);
        slot.* = .{ .page_id = 0, .title = title };
        const item = try runtime.modules.getOrPut(a, title);
        if (item.found_existing) return error.DuplicateModule;
        item.value_ptr.* = slot;
        try runtime.bundle_index.?.by_title.put(a, title, bound);
        runtime.bundle_index.?.count += 1;
    }
    // The old VM receives rebound program bytes. Drop the linked mapping now
    // instead of retaining two full corpus bytecode mappings during execution.
    session.bytecode.?.deinit();
    session.bytecode = null;
    runtime.templates_dir = ""; // Bodies already loaded. Never read source .wiki files.
    for (0..session.templates.?.recordCount()) |record_index| {
        const r = try session.templates.?.readAlloc(a, record_index);
        const title = try templateName(a, try symbol(names, r.title, .template));
        var pos: usize = 0;
        const redirect_id = try enc.blob_format.readPayloadLength(r.payload, &pos);
        const redirect = if (redirect_id != 0) blk: {
            const target = try names.get(redirect_id);
            if (names.keys[redirect_id - 1][0] != @intFromEnum(enc.call_symbols.Kind.template)) return error.SymbolKindMismatch;
            break :blk try templateName(a, target);
        } else null;
        const body = (try enc.call_symbols.decodeAlloc(a, r.payload[pos..], names)) orelse r.payload[pos..];
        const slot = try a.create(TemplateSlot);
        slot.* = .{ .page_id = 0, .title = title, .redirect = redirect, .body = body };
        const item = try runtime.templates.getOrPut(a, title);
        if (item.found_existing) {
            std.debug.print("Duplicate linked template: {s}\n", .{title});
            return error.DuplicateTemplate;
        }
        item.value_ptr.* = slot;
    }
    for (0..session.redirects.?.recordCount()) |record_index| {
        const r = try session.redirects.?.readAlloc(a, record_index);
        const from = try symbol(names, r.title, .module);
        var pos: usize = 0;
        const id = try enc.blob_format.readPayloadLength(r.payload, &pos);
        const to = try names.get(id);
        if (pos != r.payload.len or names.keys[id - 1][0] != @intFromEnum(enc.call_symbols.Kind.module)) return error.InvalidRedirect;
        try runtime.redirects.put(a, from, to);
    }
    return session;
}
