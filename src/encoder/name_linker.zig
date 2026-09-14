//! One shared link step for dictionary, template, redirect, and page call names.
//! Source inputs remain owned by their builders; linked outputs contain IDs.
const std = @import("std");
const enc = @import("blob_encoder");
const symbols = enc.call_symbols;
const format = enc.blob_format;
const files = @import("blob_files.zig");
const A = std.mem.Allocator;
pub const Stats = struct { symbols: usize = 0, templates: usize = 0, functions: usize = 0, modules: usize = 0, parsers: usize = 0, records: usize = 0 };
const Template = struct { name: []const u8, path: []const u8, redirect: ?[]const u8 = null };
const Redirect = struct { from: []const u8, to: []const u8 };
fn read(io: std.Io, a: A, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32 * 1024 * 1024));
}
fn walk(io: std.Io, a: A, root: []const u8, relative: []const u8, list: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > 8) return error.InvalidDirectory;
    const path = try std.fs.path.join(a, &.{ root, relative });
    defer a.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        const sub = try std.fs.path.join(a, &.{ relative, item.name });
        defer a.free(sub);
        if (item.kind == .directory and (depth != 0 or std.mem.eql(u8, item.name, "languages") or std.mem.eql(u8, item.name, "details"))) try walk(io, a, root, sub, list, depth + 1) else if (item.kind == .file and std.mem.endsWith(u8, item.name, ".wikblb")) {
            var generated = false;
            for ([_][]const u8{ "symbols.wikblb", "templates.wikblb", "redirects.wikblb", "pages.wikblb", "pages.source.wikblb" }) |name| if (std.mem.eql(u8, item.name, name)) {
                generated = true;
                break;
            };
            if (generated) continue;
            const value = try a.dupe(u8, sub);
            errdefer a.free(value);
            try list.append(a, value);
        }
    }
}
fn unescape(a: A, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            c = switch (text[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                else => text[i],
            };
        }
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
fn templateName(raw: []const u8) []const u8 {
    return if (std.ascii.startsWithIgnoreCase(raw, "Template:")) raw[9..] else raw;
}
fn templatesAlloc(io: std.Io, a: A, root: []const u8) ![]Template {
    const path = try std.fs.path.join(a, &.{ root, "template-manifest.tsv" });
    defer a.free(path);
    const bytes = read(io, a, path) catch |err| switch (err) {
        error.FileNotFound => return a.alloc(Template, 0),
        else => return err,
    };
    defer a.free(bytes);
    var list: std.ArrayList(Template) = .empty;
    errdefer {
        for (list.items) |t| {
            a.free(t.name);
            a.free(t.path);
            if (t.redirect) |r| a.free(r);
        }
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.InvalidManifest;
        const title = fields.next() orelse return error.InvalidManifest;
        _ = try std.fmt.parseInt(u64, id, 10);
        _ = fields.next();
        const name = try unescape(a, templateName(title));
        errdefer a.free(name);
        const source = try std.fmt.allocPrint(a, "{s}/templates/{s}.wiki", .{ root, id });
        errdefer a.free(source);
        const redirect = fields.next() orelse "";
        const target = if (redirect.len != 0) try unescape(a, templateName(redirect)) else null;
        errdefer if (target) |t| a.free(t);
        try list.append(a, .{ .name = name, .path = source, .redirect = target });
    }
    std.mem.sort(Template, list.items, {}, struct {
        fn less(_: void, l: Template, r: Template) bool {
            return std.mem.order(u8, l.name, r.name) == .lt;
        }
    }.less);
    for (list.items, 0..) |t, i| if (i != 0 and std.mem.eql(u8, t.name, list.items[i - 1].name)) return error.DuplicateTemplate;
    return list.toOwnedSlice(a);
}
fn redirectsAlloc(io: std.Io, a: A, root: []const u8) ![]Redirect {
    var list: std.ArrayList(Redirect) = .empty;
    errdefer {
        for (list.items) |r| {
            a.free(r.from);
            a.free(r.to);
        }
        list.deinit(a);
    }
    for ([_][]const u8{ "module-redirects.tsv", "usage.tsv" }) |name| {
        const path = try std.fs.path.join(a, &.{ root, name });
        defer a.free(path);
        const bytes = read(io, a, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "M\t")) continue;
            var fields = std.mem.splitScalar(u8, line[2..], '\t');
            const from = try unescape(a, fields.next() orelse return error.InvalidRedirect);
            errdefer a.free(from);
            const to = try unescape(a, fields.next() orelse return error.InvalidRedirect);
            errdefer a.free(to);
            var duplicate = false;
            for (list.items) |r| if (std.mem.eql(u8, r.from, from)) {
                if (!std.mem.eql(u8, r.to, to)) return error.ConflictingRedirect;
                duplicate = true;
                break;
            };
            if (duplicate) {
                a.free(from);
                a.free(to);
            } else try list.append(a, .{ .from = from, .to = to });
        }
    }
    std.mem.sort(Redirect, list.items, {}, struct {
        fn less(_: void, l: Redirect, r: Redirect) bool {
            return std.mem.order(u8, l.from, r.from) == .lt;
        }
    }.less);
    return list.toOwnedSlice(a);
}
fn record(w: *std.Io.Writer, title: []const u8, payload: []const u8) !void {
    try w.writeAll(title);
    try w.writeByte(0);
    var length: [format.max_varuint_len]u8 = undefined;
    try w.writeAll(format.encodePayloadLength(payload.len, &length));
    try w.writeAll(payload);
}
fn idKey(id: usize, buf: *[16]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{id});
}
fn outputFile(io: std.Io, a: A, root: []const u8, name: []const u8) !std.Io.File {
    const path = try std.fs.path.join(a, &.{ root, name });
    defer a.free(path);
    return std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}
fn writeNames(io: std.Io, a: A, root: []const u8, names: symbols.Names) !void {
    var file = try outputFile(io, a, root, symbols.filename);
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeLinkedHeader(.symbols, names.digest()));
    for (names.keys) |key| try record(w, key, "");
    try w.flush();
}
fn linkFile(io: std.Io, a: A, path: []const u8, names: symbols.Names, identity: [32]u8) !usize {
    var input = try files.File.open(io, a, path);
    defer input.deinit();
    if (input.index.blob.symbolic) return error.AlreadyLinked;
    const temporary = try std.fmt.allocPrint(a, "{s}.binding", .{path});
    defer a.free(temporary);
    var out = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true });
    defer out.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    var buffer: [256 * 1024]u8 = undefined;
    var writer = out.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeLinkedHeader(input.index.blob.kind, identity));
    try w.writeAll(input.index.blob.metadata);
    var count: usize = 0;
    var it = input.index.blob.iterator();
    while (try it.next()) |r| {
        const encoded = try symbols.encodeAlloc(a, r.payload, names);
        defer a.free(encoded);
        try record(w, r.title, encoded);
        count += 1;
    }
    try w.flush();
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
    return count;
}
fn writeTemplates(io: std.Io, a: A, root: []const u8, list: []const Template, names: symbols.Names) !void {
    var file = try outputFile(io, a, root, "templates.wikblb");
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeLinkedHeader(.templates, names.digest()));
    for (list) |t| {
        const id = names.find(.template, t.name) orelse return error.UnboundCallName;
        var key: [16]u8 = undefined;
        const body = try read(io, a, t.path);
        defer a.free(body);
        const encoded = try symbols.encodeAlloc(a, body, names);
        defer a.free(encoded);
        // Redirect identity is semantic, not a source-text guess at load time.
        const target = if (t.redirect) |r| names.find(.template, r) orelse return error.UnboundRedirect else 0;
        var prefix: [format.max_varuint_len]u8 = undefined;
        const payload = try std.mem.concat(a, u8, &.{ format.encodePayloadLength(target, &prefix), encoded });
        defer a.free(payload);
        try record(w, try idKey(id, &key), payload);
    }
    try w.flush();
}
fn writeRedirects(io: std.Io, a: A, root: []const u8, list: []const Redirect, names: symbols.Names) !void {
    var file = try outputFile(io, a, root, "redirects.wikblb");
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeLinkedHeader(.redirects, names.digest()));
    for (list) |r| {
        var key: [16]u8 = undefined;
        var value: [format.max_varuint_len]u8 = undefined;
        const from = names.find(.module, r.from) orelse return error.UnboundModule;
        const to = names.find(.module, r.to) orelse return error.UnboundModule;
        try record(w, try idKey(from, &key), format.encodePayloadLength(to, &value));
    }
    try w.flush();
}
pub fn linkRoot(io: std.Io, a: A, root: []const u8, runtime_root: ?[]const u8) !Stats {
    const existing_symbols = try std.fs.path.join(a, &.{ root, symbols.filename });
    defer a.free(existing_symbols);
    if (std.Io.Dir.cwd().openFile(io, existing_symbols, .{})) |existing| {
        existing.close(io);
        return error.AlreadyLinked;
    } else |err| if (err != error.FileNotFound) return err;
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |p| a.free(p);
        list.deinit(a);
    }
    try walk(io, a, root, "", &list, 0);
    // Refuse existing linked artifacts BEFORE creating an incomplete marker.
    for (list.items) |relative| {
        const path = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(path);
        var f = try files.File.open(io, a, path);
        defer f.deinit();
        if (f.index.blob.symbolic) return error.AlreadyLinked;
    }
    const runtime = if (runtime_root) |r| try a.dupe(u8, r) else try std.fs.path.join(a, &.{ root, "runtime" });
    defer a.free(runtime);
    const templates = try templatesAlloc(io, a, runtime);
    defer {
        for (templates) |t| {
            a.free(t.name);
            a.free(t.path);
            if (t.redirect) |r| a.free(r);
        }
        a.free(templates);
    }
    const redirects = try redirectsAlloc(io, a, runtime);
    defer {
        for (redirects) |r| {
            a.free(r.from);
            a.free(r.to);
        }
        a.free(redirects);
    }
    const page_path = try std.fs.path.join(a, &.{ runtime, "pages.source.wikblb" });
    defer a.free(page_path);
    var pages: ?files.File = files.File.open(io, a, page_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (pages) |*file| file.deinit();
    if (pages) |file| if (file.index.blob.kind != .pages or file.index.blob.symbolic) return error.InvalidSourcePages;
    var builder: symbols.Builder = .{ .a = a };
    defer builder.deinit();
    for (list.items) |relative| {
        const path = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(path);
        var f = try files.File.open(io, a, path);
        defer f.deinit();
        var it = f.index.blob.iterator();
        while (try it.next()) |r| try builder.collect(r.payload);
    }
    for (templates) |t| {
        try builder.add(.template, t.name);
        if (t.redirect) |r| try builder.add(.template, r);
        const body = try read(io, a, t.path);
        defer a.free(body);
        try builder.collect(body);
    }
    for (redirects) |r| {
        try builder.add(.module, r.from);
        try builder.add(.module, r.to);
    }
    if (pages) |file| {
        var it = file.index.blob.iterator();
        while (try it.next()) |r| try builder.collect(r.payload);
    }
    const keys = try builder.sorted();
    defer a.free(keys);
    const names: symbols.Names = .{ .keys = keys };
    const identity = names.digest();
    const marker = try std.fs.path.join(a, &.{ root, ".binding-incomplete" });
    defer a.free(marker);
    var marker_file = try std.Io.Dir.cwd().createFile(io, marker, .{ .exclusive = true });
    marker_file.close(io);
    try writeNames(io, a, root, names);
    try writeTemplates(io, a, root, templates, names);
    try writeRedirects(io, a, root, redirects, names);
    try writePages(io, a, root, pages, names);
    var stats: Stats = .{ .symbols = keys.len, .templates = templates.len };
    for (keys) |key| switch (key[0]) {
        'f' => stats.functions += 1,
        'm' => stats.modules += 1,
        'p' => stats.parsers += 1,
        else => {},
    };
    for (list.items) |relative| {
        const path = try std.fs.path.join(a, &.{ root, relative });
        defer a.free(path);
        stats.records += try linkFile(io, a, path, names, identity);
    }
    // These are semantic external datasets, not call names. No network is used here.
    if (!std.mem.eql(u8, root, runtime)) for ([_][]const u8{ "wikibase-sitelinks.tsv", "interwiki-map.tsv" }) |name| {
        const from = try std.fs.path.join(a, &.{ runtime, name });
        defer a.free(from);
        const bytes = read(io, a, from) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer a.free(bytes);
        const to = try std.fs.path.join(a, &.{ root, name });
        defer a.free(to);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = bytes });
    };
    try std.Io.Dir.cwd().deleteFile(io, marker);
    return stats;
}

fn writePages(io: std.Io, a: A, root: []const u8, source: ?files.File, names: symbols.Names) !void {
    var file = try outputFile(io, a, root, "pages.wikblb");
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(&format.encodeLinkedHeader(.pages, names.digest()));
    if (source) |input| {
        var it = input.index.blob.iterator();
        while (try it.next()) |r| {
            const encoded = try symbols.encodeAlloc(a, r.payload, names);
            defer a.free(encoded);
            try record(w, r.title, encoded);
        }
    }
    try w.flush();
}
