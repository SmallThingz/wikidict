const std = @import("std");
const lua = @import("root.zig");
const model = @import("module_model.zig");

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const b = try a.alloc(u8, n);
    _ = try f.readPositionalAll(io, b, 0);
    return b;
}

fn pageId(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".lua")) return null;
    const stem = name[0 .. name.len - 4];
    for (stem) |c| if (c < '0' or c > '9') return null;
    return stem;
}

fn writeField(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingDirectory;
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    var out_buf: [256 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    var modules: usize = 0;
    var exports: usize = 0;
    var functions: usize = 0;
    var dynamic: usize = 0;
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const id = pageId(entry.name) orelse continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[1], entry.name });
        const source = try readAll(init.io, a, path);
        var chunk = lua.parse(a, source) catch |err| {
            try w.print("P\t{s}\t{s}\n", .{ id, @errorName(err) });
            continue;
        };
        var b = model.Builder{ .allocator = a, .source = chunk.source };
        try b.build(chunk.body);
        modules += 1;
        functions += b.functions.count();
        if (b.dynamic_top_level) dynamic += 1;
        try w.print("S\t{s}\t{d}\t{}\t{s}\n", .{ id, b.functions.count(), b.dynamic_top_level, @tagName(b.return_binding) });
        switch (b.return_binding) {
            .table => |table| {
                var fit = table.fields.iterator();
                while (fit.next()) |field| switch (field.value_ptr.*) {
                    .function => |fn_id| {
                        try w.writeAll("E\t");
                        try w.writeAll(id);
                        try w.writeByte('\t');
                        try writeField(w, field.key_ptr.*);
                        try w.print("\tF\t{d}\n", .{fn_id});
                        exports += 1;
                    },
                    .module_export => |m| {
                        try w.writeAll("E\t");
                        try w.writeAll(id);
                        try w.writeByte('\t');
                        try writeField(w, field.key_ptr.*);
                        try w.writeAll("\tM\t");
                        try writeField(w, m.module);
                        try w.writeByte('\t');
                        try writeField(w, m.name);
                        try w.writeByte('\n');
                        exports += 1;
                    },
                    else => {},
                };
            },
            .module => |m| {
                try w.writeAll("R\t");
                try w.writeAll(id);
                try w.writeByte('\t');
                try writeField(w, m);
                try w.writeByte('\n');
            },
            else => {},
        }
        b.deinit();
        chunk.deinit();
        if (modules % 5000 == 0) {
            try w.flush();
            std.debug.print("modules={d} functions={d} exports={d} dynamic={d}\n", .{ modules, functions, exports, dynamic });
        }
    }
    try w.flush();
    std.debug.print("TOTAL modules={d} functions={d} exports={d} dynamic_top={d}\n", .{ modules, functions, exports, dynamic });
}
