const std = @import("std");
const lua = @import("parser/root.zig");
const analysis = @import("direct/analysis.zig");
const emitter = @import("direct/emitter.zig");
const shapes = @import("direct/shapes.zig");
const module_model = @import("direct/module_model.zig");

const A = std.mem.Allocator;
const ManifestRow = struct {
    page_id: u64,
    title: []const u8,
    path: []const u8,
};
const ModuleRecord = struct {
    title: []const u8,
    path: []const u8,
    function_base: u32,
    function_count: u32,
    root_function: u32,
    export_shape_id: ?u32,
};
const ModuleLookupEntry = struct { name: []const u8, id: u32 };

fn readAll(io: std.Io, a: A, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try a.alloc(u8, len);
    if (try file.readPositionalAll(io, bytes, 0) != len) return error.Truncated;
    return bytes;
}
fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn llvmByte(out: *std.ArrayList(u8), a: A, byte: u8) !void {
    if (byte >= 0x20 and byte <= 0x7e and byte != '"' and byte != '\\')
        try out.append(a, byte)
    else {
        const escaped = try std.fmt.allocPrint(a, "\\{X:0>2}", .{byte});
        defer a.free(escaped);
        try out.appendSlice(a, escaped);
    }
}

fn emitLlString(out: *std.ArrayList(u8), a: A, symbol: []const u8, value: []const u8) !void {
    const head = try std.fmt.allocPrint(a, "@{s} = private unnamed_addr constant [{d} x i8] c\"", .{ symbol, value.len });
    defer a.free(head);
    try out.appendSlice(a, head);
    for (value) |byte| try llvmByte(out, a, byte);
    try out.appendSlice(a, "\", align 1\n");
}
fn appendFmt(out: *std.ArrayList(u8), a: A, comptime format: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(a, format, args);
    defer a.free(bytes);
    try out.appendSlice(a, bytes);
}

fn emitProgram(
    a: A,
    records: []const ModuleRecord,
    globals: *const analysis.Globals,
    shape_registry: *const shapes.Registry,
    module_ids: *const emitter.ModuleIdMap,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const sorted_ids = try a.alloc(u32, records.len);
    defer a.free(sorted_ids);
    for (sorted_ids, 0..) |*id, index| id.* = @intCast(index);
    std.mem.sort(u32, sorted_ids, records, struct {
        fn lessThan(items: []const ModuleRecord, lhs: u32, rhs: u32) bool {
            return std.mem.order(u8, items[lhs].title, items[rhs].title) == .lt;
        }
    }.lessThan);
    for (sorted_ids[1..], sorted_ids[0..sorted_ids.len -| 1]) |id, previous| {
        if (std.mem.eql(u8, records[id].title, records[previous].title)) return error.DuplicateModuleName;
    }
    const lookup_entries = try a.alloc(ModuleLookupEntry, module_ids.count());
    defer a.free(lookup_entries);
    var lookup_it = module_ids.iterator();
    var lookup_at: usize = 0;
    while (lookup_it.next()) |entry| : (lookup_at += 1)
        lookup_entries[lookup_at] = .{ .name = entry.key_ptr.*, .id = entry.value_ptr.* };
    std.mem.sort(ModuleLookupEntry, lookup_entries, {}, struct {
        fn lessThan(_: void, lhs: ModuleLookupEntry, rhs: ModuleLookupEntry) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);
    try out.appendSlice(a, "%FunctionResult = type { ptr, i64, i32, i32 }\n\n");
    for (records) |record|
        try appendFmt(&out, a, "declare %FunctionResult @lua_f_{d}(ptr, ptr, ptr, i64, ptr, i64)\n", .{record.root_function});
    try out.append(a, '\n');
    for (records, 0..) |record, index| {
        const symbol = try std.fmt.allocPrint(a, "module_name_{d}", .{index});
        defer a.free(symbol);
        try emitLlString(&out, a, symbol, record.title);
    }
    for (lookup_entries, 0..) |entry, index| {
        const symbol = try std.fmt.allocPrint(a, "module_lookup_name_{d}", .{index});
        defer a.free(symbol);
        try emitLlString(&out, a, symbol, entry.name);
    }
    for (globals.names.items, 0..) |name, index| {
        const symbol = try std.fmt.allocPrint(a, "global_name_{d}", .{index});
        defer a.free(symbol);
        try emitLlString(&out, a, symbol, name);
    }
    var shape_field_total: usize = 0;
    for (0..shape_registry.count()) |shape_index| {
        const shape = shape_registry.record(@intCast(shape_index));
        for (shape.fields, 0..) |field, field_index| {
            const symbol = try std.fmt.allocPrint(a, "shape_{d}_field_{d}", .{ shape_index, field_index });
            defer a.free(symbol);
            try emitLlString(&out, a, symbol, field);
            shape_field_total += 1;
        }
    }
    try appendFmt(&out, a, "\n@module_roots = private constant [{d} x ptr] [", .{records.len});
    for (records, 0..) |record, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "ptr @lua_f_{d}", .{record.root_function});
    }
    try out.appendSlice(a, "]\n@module_names = private constant [");
    try appendFmt(&out, a, "{d} x ptr] [", .{records.len});
    for (records, 0..) |_, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "ptr @module_name_{d}", .{index});
    }
    try out.appendSlice(a, "]\n@module_name_lens = private constant [");
    try appendFmt(&out, a, "{d} x i64] [", .{records.len});
    for (records, 0..) |record, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i64 {d}", .{record.title.len});
    }
    try out.appendSlice(a, "]\n@module_lookup_names = private constant [");
    try appendFmt(&out, a, "{d} x ptr] [", .{lookup_entries.len});
    for (lookup_entries, 0..) |_, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "ptr @module_lookup_name_{d}", .{index});
    }
    try out.appendSlice(a, "]\n@module_lookup_name_lens = private constant [");
    try appendFmt(&out, a, "{d} x i64] [", .{lookup_entries.len});
    for (lookup_entries, 0..) |entry, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i64 {d}", .{entry.name.len});
    }
    try out.appendSlice(a, "]\n@module_lookup_ids = private constant [");
    try appendFmt(&out, a, "{d} x i32] [", .{lookup_entries.len});
    for (lookup_entries, 0..) |entry, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i32 {d}", .{entry.id});
    }
    try out.appendSlice(a, "]\n@module_export_shape_ids = private constant [");
    try appendFmt(&out, a, "{d} x i32] [", .{records.len});
    for (records, 0..) |record, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i32 {d}", .{record.export_shape_id orelse std.math.maxInt(u32)});
    }
    try out.appendSlice(a, "]\n@global_names = private constant [");
    try appendFmt(&out, a, "{d} x ptr] [", .{globals.names.items.len});
    for (globals.names.items, 0..) |_, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "ptr @global_name_{d}", .{index});
    }
    try out.appendSlice(a, "]\n@global_name_lens = private constant [");
    try appendFmt(&out, a, "{d} x i64] [", .{globals.names.items.len});
    for (globals.names.items, 0..) |name, index| {
        if (index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i64 {d}", .{name.len});
    }
    try out.appendSlice(a, "]\n@shape_field_names = private constant [");
    try appendFmt(&out, a, "{d} x ptr] [", .{shape_field_total});
    var flat_field: usize = 0;
    for (0..shape_registry.count()) |shape_index| {
        const shape = shape_registry.record(@intCast(shape_index));
        for (shape.fields, 0..) |_, field_index| {
            if (flat_field != 0) try out.appendSlice(a, ", ");
            try appendFmt(&out, a, "ptr @shape_{d}_field_{d}", .{ shape_index, field_index });
            flat_field += 1;
        }
    }
    try out.appendSlice(a, "]\n@shape_field_lens = private constant [");
    try appendFmt(&out, a, "{d} x i64] [", .{shape_field_total});
    flat_field = 0;
    for (0..shape_registry.count()) |shape_index| {
        const shape = shape_registry.record(@intCast(shape_index));
        for (shape.fields) |field| {
            if (flat_field != 0) try out.appendSlice(a, ", ");
            try appendFmt(&out, a, "i64 {d}", .{field.len});
            flat_field += 1;
        }
    }
    try out.appendSlice(a, "]\n@shape_sorted_slots = private constant [");
    try appendFmt(&out, a, "{d} x i32] [", .{shape_field_total});
    flat_field = 0;
    for (0..shape_registry.count()) |shape_index| {
        const shape = shape_registry.record(@intCast(shape_index));
        const slots = try a.alloc(u32, shape.fields.len);
        defer a.free(slots);
        for (slots, 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u32, slots, shape.fields, struct {
            fn lessThan(fields: []const []const u8, lhs: u32, rhs: u32) bool {
                return std.mem.order(u8, fields[lhs], fields[rhs]) == .lt;
            }
        }.lessThan);
        for (slots) |slot| {
            if (flat_field != 0) try out.appendSlice(a, ", ");
            try appendFmt(&out, a, "i32 {d}", .{slot});
            flat_field += 1;
        }
    }
    try out.appendSlice(a, "]\n@shape_offsets = private constant [");
    try appendFmt(&out, a, "{d} x i32] [", .{shape_registry.count()});
    var shape_offset: usize = 0;
    for (0..shape_registry.count()) |shape_index| {
        if (shape_index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i32 {d}", .{shape_offset});
        shape_offset += shape_registry.record(@intCast(shape_index)).fields.len;
    }
    try out.appendSlice(a, "]\n@shape_counts = private constant [");
    try appendFmt(&out, a, "{d} x i32] [", .{shape_registry.count()});
    for (0..shape_registry.count()) |shape_index| {
        if (shape_index != 0) try out.appendSlice(a, ", ");
        try appendFmt(&out, a, "i32 {d}", .{shape_registry.record(@intCast(shape_index)).fields.len});
    }
    try out.appendSlice(a, "]\n\n");
    try emitAccessors(&out, a, records.len, lookup_entries.len, globals.names.items.len, shape_registry.count(), shape_field_total);
    return out.toOwnedSlice(a);
}
fn emitAccessors(out: *std.ArrayList(u8), a: A, module_count: usize, module_lookup_count: usize, global_count: usize, shape_count: usize, shape_field_total: usize) !void {
    try appendFmt(out, a, "define i32 @dict_lua_program_module_count() {{ ret i32 {d} }}\n", .{module_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_global_count() {{ ret i32 {d} }}\n", .{global_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_shape_count() {{ ret i32 {d} }}\n", .{shape_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_shape_field_total() {{ ret i32 {d} }}\n", .{shape_field_total});
    try appendFmt(out, a, "define ptr @dict_lua_program_module_root(i32 %id) {{\n  %p = getelementptr [{d} x ptr], ptr @module_roots, i32 0, i32 %id\n  %v = load ptr, ptr %p, align 8\n  ret ptr %v\n}}\n", .{module_count});
    try appendFmt(out, a, "define ptr @dict_lua_program_module_roots() {{ ret ptr @module_roots }}\n", .{});
    try appendFmt(out, a, "define ptr @dict_lua_program_module_name(i32 %id) {{\n  %p = getelementptr [{d} x ptr], ptr @module_names, i32 0, i32 %id\n  %v = load ptr, ptr %p, align 8\n  ret ptr %v\n}}\n", .{module_count});
    try appendFmt(out, a, "define i64 @dict_lua_program_module_name_len(i32 %id) {{\n  %p = getelementptr [{d} x i64], ptr @module_name_lens, i32 0, i32 %id\n  %v = load i64, ptr %p, align 8\n  ret i64 %v\n}}\n", .{module_count});
    try appendFmt(out, a, "define ptr @dict_lua_program_module_export_shape_ids() {{ ret ptr @module_export_shape_ids }}\n", .{});
    try appendFmt(out, a, "define i32 @dict_lua_program_module_lookup_count() {{ ret i32 {d} }}\n", .{module_lookup_count});
    try appendFmt(out, a, "define ptr @dict_lua_program_module_lookup_name(i32 %index) {{\n  %p = getelementptr [{d} x ptr], ptr @module_lookup_names, i32 0, i32 %index\n  %v = load ptr, ptr %p, align 8\n  ret ptr %v\n}}\n", .{module_lookup_count});
    try appendFmt(out, a, "define i64 @dict_lua_program_module_lookup_name_len(i32 %index) {{\n  %p = getelementptr [{d} x i64], ptr @module_lookup_name_lens, i32 0, i32 %index\n  %v = load i64, ptr %p, align 8\n  ret i64 %v\n}}\n", .{module_lookup_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_module_lookup_id(i32 %index) {{\n  %p = getelementptr [{d} x i32], ptr @module_lookup_ids, i32 0, i32 %index\n  %v = load i32, ptr %p, align 4\n  ret i32 %v\n}}\n", .{module_lookup_count});
    try appendFmt(out, a, "define ptr @dict_lua_program_global_name(i32 %id) {{\n  %p = getelementptr [{d} x ptr], ptr @global_names, i32 0, i32 %id\n  %v = load ptr, ptr %p, align 8\n  ret ptr %v\n}}\n", .{global_count});
    try appendFmt(out, a, "define i64 @dict_lua_program_global_name_len(i32 %id) {{\n  %p = getelementptr [{d} x i64], ptr @global_name_lens, i32 0, i32 %id\n  %v = load i64, ptr %p, align 8\n  ret i64 %v\n}}\n", .{global_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_shape_field_count(i32 %id) {{\n  %p = getelementptr [{d} x i32], ptr @shape_counts, i32 0, i32 %id\n  %v = load i32, ptr %p, align 4\n  ret i32 %v\n}}\n", .{shape_count});
    try appendFmt(out, a, "define i32 @dict_lua_program_shape_sorted_slot(i32 %id, i32 %rank) {{\n  %op = getelementptr [{d} x i32], ptr @shape_offsets, i32 0, i32 %id\n  %o = load i32, ptr %op, align 4\n  %i = add i32 %o, %rank\n  %p = getelementptr [{d} x i32], ptr @shape_sorted_slots, i32 0, i32 %i\n  %v = load i32, ptr %p, align 4\n  ret i32 %v\n}}\n", .{ shape_count, shape_field_total });
    try appendFmt(out, a, "define ptr @dict_lua_program_shape_field_name(i32 %id, i32 %field) {{\n  %op = getelementptr [{d} x i32], ptr @shape_offsets, i32 0, i32 %id\n  %o = load i32, ptr %op, align 4\n  %i = add i32 %o, %field\n  %p = getelementptr [{d} x ptr], ptr @shape_field_names, i32 0, i32 %i\n  %v = load ptr, ptr %p, align 8\n  ret ptr %v\n}}\n", .{ shape_count, shape_field_total });
    try appendFmt(out, a, "define i64 @dict_lua_program_shape_field_name_len(i32 %id, i32 %field) {{\n  %op = getelementptr [{d} x i32], ptr @shape_offsets, i32 0, i32 %id\n  %o = load i32, ptr %op, align 4\n  %i = add i32 %o, %field\n  %p = getelementptr [{d} x i64], ptr @shape_field_lens, i32 0, i32 %i\n  %v = load i64, ptr %p, align 8\n  ret i64 %v\n}}\n", .{ shape_count, shape_field_total });
}

fn sourcePath(a: A, root: []const u8, relative: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, relative });
}

fn outputModulePath(a: A, root: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/module_{d:0>6}.ll", .{ root, index });
}

fn unescapeTsv(a: A, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(a, raw[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (raw[i]) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            else => raw[i],
        });
    }
    return out.toOwnedSlice(a);
}

fn buildModuleIds(io: std.Io, a: A, source_root: []const u8, records: []const ModuleRecord) !emitter.ModuleIdMap {
    var ids: emitter.ModuleIdMap = .empty;
    errdefer ids.deinit(a);
    for (records, 0..) |record, index| try ids.put(a, record.title, @intCast(index));

    const redirect_path = try std.fs.path.join(a, &.{ source_root, "module-redirects.tsv" });
    const bytes = readAll(io, a, redirect_path) catch |err| switch (err) {
        error.FileNotFound => return ids,
        else => return err,
    };
    var redirects: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer redirects.deinit(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "M\t")) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        const from_raw = fields.next() orelse continue;
        const to_raw = fields.next() orelse continue;
        try redirects.put(a, try unescapeTsv(a, from_raw), try unescapeTsv(a, to_raw));
    }
    var it = redirects.iterator();
    while (it.next()) |entry| {
        var current = entry.value_ptr.*;
        var depth: usize = 0;
        while (redirects.get(current)) |next| {
            depth += 1;
            if (depth > 32) break;
            current = next;
        }
        if (depth > 32) continue;
        if (ids.get(current)) |id| try ids.put(a, entry.key_ptr.*, id);
    }
    return ids;
}
fn analyzeManifest(
    io: std.Io,
    a: A,
    manifest: []const u8,
    source_root: []const u8,
    globals: *analysis.Globals,
    shape_registry: *shapes.Registry,
) ![]ModuleRecord {
    var records: std.ArrayList(ModuleRecord) = .empty;
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    var function_base: u32 = 0;
    var pos: usize = 0;
    while (pos < manifest.len) {
        const nl = std.mem.indexOfScalarPos(u8, manifest, pos, '\n') orelse manifest.len;
        const line = manifest[pos..nl];
        pos = @min(nl + 1, manifest.len);
        if (line.len == 0) continue;
        const sa = scratch.allocator();
        const row = try std.json.parseFromSliceLeaky(ManifestRow, sa, line, .{ .ignore_unknown_fields = true });
        const path = try sourcePath(sa, source_root, row.path);
        const source = try readAll(io, sa, path);
        var chunk = try lua.parse(sa, source);
        const module_index: u32 = @intCast(records.items.len);
        try shape_registry.collect(module_index, chunk.body);
        var model = module_model.Builder{ .allocator = sa, .source = chunk.source };
        try model.build(chunk.body);
        var export_shape_id: ?u32 = null;
        if (!model.dynamic_top_level) switch (model.return_binding) {
            .table => |table| if (table.shape_eligible) {
                var fields: std.ArrayList([]const u8) = .empty;
                var keys = table.fields.keyIterator();
                while (keys.next()) |key| try fields.append(sa, key.*);
                std.mem.sort([]const u8, fields.items, {}, struct {
                    fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.order(u8, lhs, rhs) == .lt;
                    }
                }.lessThan);
                export_shape_id = try shape_registry.promote(module_index, table.span_start, fields.items);
            },
            else => {},
        };
        var module = try analysis.analyze(sa, globals, &chunk, function_base);
        const count: u32 = @intCast(module.functions.items.len);
        try records.append(a, .{
            .title = try a.dupe(u8, row.title),
            .path = try a.dupe(u8, row.path),
            .function_base = function_base,
            .function_count = count,
            .root_function = module.root.id,
            .export_shape_id = export_shape_id,
        });
        function_base = std.math.add(u32, function_base, count) catch return error.TooManyFunctions;
        module.deinit();
        model.deinit();
        chunk.deinit();
        _ = scratch.reset(.retain_capacity);
    }
    return records.toOwnedSlice(a);
}
fn emitModules(
    io: std.Io,
    a: A,
    records: []const ModuleRecord,
    source_root: []const u8,
    output_root: []const u8,
    globals: *analysis.Globals,
    module_ids: *const emitter.ModuleIdMap,
    shape_registry: *const shapes.Registry,
) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const frozen_global_count = globals.names.items.len;
    for (records, 0..) |record, index| {
        const sa = scratch.allocator();
        const path = try sourcePath(sa, source_root, record.path);
        const source = try readAll(io, sa, path);
        var chunk = try lua.parse(sa, source);
        var module = try analysis.analyze(sa, globals, &chunk, record.function_base);
        if (globals.names.items.len != frozen_global_count) return error.GlobalAnalysisMismatch;
        if (module.root.id != record.root_function or module.functions.items.len != record.function_count)
            return error.FunctionAnalysisMismatch;
        var table_shapes = try shape_registry.moduleFacts(sa, @intCast(index));
        const facts = emitter.ProgramFacts{ .module_ids = module_ids, .table_shapes = &table_shapes };
        const generated = try emitter.generate(sa, globals, &module, facts);
        const output = try outputModulePath(sa, output_root, index);
        try writeAll(io, output, generated.source);
        table_shapes.deinit(sa);
        module.deinit();
        chunk.deinit();
        if ((index + 1) % 1000 == 0)
            std.debug.print("LLVM_EMIT modules={d} functions={d}\n", .{ index + 1, record.function_base + record.function_count });
        _ = scratch.reset(.retain_capacity);
    }
    _ = a;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) {
        std.debug.print("usage: dict-llvm-build MANIFEST SOURCE_ROOT OUTPUT_DIR\n", .{});
        return error.Usage;
    }
    const manifest_path = args[1];
    const source_root = args[2];
    const output_root = args[3];
    try std.Io.Dir.cwd().createDirPath(init.io, output_root);
    const manifest = try readAll(init.io, a, manifest_path);
    var globals = try analysis.Globals.init(a);
    defer globals.deinit();
    var shape_registry = shapes.Registry.init(a);
    defer shape_registry.deinit();
    const records = try analyzeManifest(init.io, a, manifest, source_root, &globals, &shape_registry);
    if (records.len == 0) return error.EmptyManifest;
    if (records.len > std.math.maxInt(u32) - 2) return error.TooManyModules;
    std.debug.print("LLVM_ANALYZE modules={d} globals={d} functions={d}\n", .{
        records.len,
        globals.names.items.len,
        records[records.len - 1].function_base + records[records.len - 1].function_count,
    });
    var module_ids = try buildModuleIds(init.io, a, source_root, records);
    defer module_ids.deinit(a);
    if (module_ids.count() > std.math.maxInt(u32)) return error.TooManyModuleNames;
    if (shape_registry.count() > std.math.maxInt(u32)) return error.TooManyShapes;
    try emitModules(init.io, a, records, source_root, output_root, &globals, &module_ids, &shape_registry);
    const program = try emitProgram(a, records, &globals, &shape_registry, &module_ids);
    const program_path = try std.fs.path.join(a, &.{ output_root, "program.ll" });
    try writeAll(init.io, program_path, program);
    std.debug.print("LLVM_DONE modules={d} globals={d}\n", .{ records.len, globals.names.items.len });
}
