const std = @import("std");
const analysis = @import("analysis.zig");
const emitter = @import("emitter.zig");
const llvm = @import("llvm.zig");
const shapes = @import("shapes.zig");
const metadata = @import("../program_metadata.zig");

const A = std.mem.Allocator;

pub const EagerRequirement = struct {
    module_id: u32,
    requested: []const u8,
};

pub const ModuleRecord = struct {
    title: []const u8,
    path: []const u8,
    source_bytes: u64,
    source_index: u32,
    function_base: u32,
    function_count: u32,
    root_function: u32,
    export_shape_id: ?u32,
    dynamic_module_load: bool = false,
    root_pure: bool = false,
    root_bootstrap_safe: bool = false,
    root_requires: []const []const u8 = &.{},
    eager_order: u32 = std.math.maxInt(u32),
    eager_requirements: []const EagerRequirement = &.{},
    load_data_snapshot: bool = false,
    direct_exports: []const emitter.DirectExport = &.{},
    static_root: bool = false,
    static_root_blob: []const u8 = &.{},
    synth_root: bool = false,
};

pub fn needsLlvmBatch(record: ModuleRecord) bool {
    if (record.static_root) return false;
    return !(record.synth_root and record.function_count == 1);
}

const ModuleLookupEntry = struct {
    name: []const u8,
    id: u32,
};

fn requireU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.ProgramMetadataTooLarge;
}

fn validateRecords(a: A, records: []const ModuleRecord) !void {
    const sorted = try a.alloc(u32, records.len);
    defer a.free(sorted);
    for (sorted, 0..) |*id, index| id.* = @intCast(index);
    std.mem.sort(u32, sorted, records, struct {
        fn lessThan(items: []const ModuleRecord, lhs: u32, rhs: u32) bool {
            return std.mem.order(u8, items[lhs].title, items[rhs].title) == .lt;
        }
    }.lessThan);
    for (sorted[1..], sorted[0..sorted.len -| 1]) |id, previous| {
        if (std.mem.eql(u8, records[id].title, records[previous].title))
            return error.DuplicateModuleName;
    }
}

fn sortedLookupEntries(
    a: A,
    module_ids: *const emitter.ModuleIdMap,
) ![]ModuleLookupEntry {
    const entries = try a.alloc(ModuleLookupEntry, module_ids.count());
    errdefer a.free(entries);
    var it = module_ids.iterator();
    var at: usize = 0;
    while (it.next()) |entry| : (at += 1)
        entries[at] = .{ .name = entry.key_ptr.*, .id = entry.value_ptr.* };
    std.mem.sort(ModuleLookupEntry, entries, {}, struct {
        fn lessThan(_: void, lhs: ModuleLookupEntry, rhs: ModuleLookupEntry) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);
    return entries;
}

fn shapeFieldTotal(shape_registry: *const shapes.Registry) !u32 {
    var total: usize = 0;
    for (0..shape_registry.count()) |shape_index| {
        total = std.math.add(
            usize,
            total,
            shape_registry.record(@intCast(shape_index)).fields.len,
        ) catch return error.ProgramMetadataTooLarge;
    }
    return requireU32(total);
}

pub fn generate(a: A, records: []const ModuleRecord) !llvm.Module {
    try validateRecords(a, records);
    var m = try llvm.Module.init("dict_lua_program_roots");
    errdefer m.deinit();

    const generated_fn_ty = try m.functionType(m.types.function_result, &.{
        m.types.ptr,
        m.types.ptr,
        m.types.ptr,
        m.types.i64,
        m.types.ptr,
        m.types.i64,
    });
    const roots = try a.alloc(llvm.ValueRef, records.len);
    defer a.free(roots);
    const static_stub = try m.addFunction("dict_lua_static_module_root_unreachable", generated_fn_ty);
    for (records, 0..) |record, index| {
        if (record.static_root or record.synth_root) {
            roots[index] = static_stub;
            continue;
        }
        const root_name = try std.fmt.allocPrint(a, "lua_f_{d}", .{record.root_function});
        defer a.free(root_name);
        roots[index] = try m.addFunction(root_name, generated_fn_ty);
    }

    const roots_ty = try llvm.arrayType(m.types.ptr, roots.len);
    const roots_value = try m.addGlobal(
        "module_roots",
        roots_ty,
        try llvm.constArray(m.types.ptr, roots),
        .private,
        8,
    );
    const accessor_ty = try m.functionType(m.types.ptr, &.{});
    const accessor = try m.addFunction("dict_lua_program_module_roots", accessor_ty);
    const block = try llvm.appendBlock(m.context, accessor, "entry");
    const builder = try llvm.createBuilder(m.context);
    defer llvm.disposeBuilder(builder);
    llvm.position(builder, block);
    try llvm.ret(builder, roots_value);

    var synth_entries: std.ArrayList(llvm.ValueRef) = .empty;
    defer synth_entries.deinit(a);
    for (records) |record| if (record.synth_root) {
        for (record.direct_exports) |entry| {
            if (entry.capture_count != 0) return error.InvalidSyntheticRootCapture;
            const name = try std.fmt.allocPrint(a, "lua_f_{d}", .{entry.function_id});
            defer a.free(name);
            const function = m.getFunction(name) orelse try m.addFunction(name, generated_fn_ty);
            try synth_entries.append(a, function);
        }
    };
    const synth_accessor = try m.addFunction("dict_lua_program_synth_export_entries", accessor_ty);
    const synth_block = try llvm.appendBlock(m.context, synth_accessor, "entry");
    llvm.position(builder, synth_block);
    if (synth_entries.items.len == 0) {
        try llvm.ret(builder, try llvm.constNull(m.types.ptr));
    } else {
        const synth_ty = try llvm.arrayType(m.types.ptr, synth_entries.items.len);
        const synth_value = try m.addGlobal(
            "synth_export_entries",
            synth_ty,
            try llvm.constArray(m.types.ptr, synth_entries.items),
            .private,
            8,
        );
        try llvm.ret(builder, synth_value);
    }

    const preinit_ty = try m.functionType(m.types.i32, &.{
        m.types.ptr,
        m.types.i32,
        m.types.i32,
        m.types.ptr,
        m.types.i64,
        m.types.i32,
        m.types.i32,
    });
    const preinit = try m.addFunction("dict_lua_preinitialize_module", preinit_ty);
    const special_preinit_ty = try m.functionType(m.types.i32, &.{ m.types.ptr, m.types.i32, m.types.i32 });
    const special_preinit = try m.addFunction("dict_lua_preinitialize_special_module", special_preinit_ty);
    const eager_ty = try m.functionType(m.types.i32, &.{m.types.ptr});
    const eager = try m.addFunction("dict_lua_program_eager_init", eager_ty);
    const eager_ctx = try llvm.param(eager, 0);
    const eager_entry = try llvm.appendBlock(m.context, eager, "entry");
    llvm.position(builder, eager_entry);
    const null_ptr = try llvm.constNull(m.types.ptr);
    const zero_i64 = try llvm.constInt(m.types.i64, 0);

    var eager_modules: std.ArrayList(u32) = .empty;
    defer eager_modules.deinit(a);
    for (records, 0..) |record, module_id|
        if (record.eager_order != std.math.maxInt(u32))
            try eager_modules.append(a, @intCast(module_id));
    std.mem.sort(u32, eager_modules.items, records, struct {
        fn lessThan(items: []const ModuleRecord, lhs: u32, rhs: u32) bool {
            return items[lhs].eager_order < items[rhs].eager_order;
        }
    }.lessThan);

    for (eager_modules.items) |module_id_u32| {
        const module_id: usize = @intCast(module_id_u32);
        const record = records[module_id];
        const status = if (record.static_root or record.synth_root)
            try llvm.call(builder, special_preinit, &.{
                eager_ctx,
                try llvm.constInt(m.types.i32, module_id),
                try llvm.constInt(m.types.i32, @intFromBool(record.load_data_snapshot)),
            })
        else blk: {
            const root = roots[module_id];
            const result = try llvm.call(builder, root, &.{
                eager_ctx,
                null_ptr,
                null_ptr,
                zero_i64,
                null_ptr,
                zero_i64,
            });
            const values_ptr = try llvm.extractValue(builder, result, 0);
            const values_len = try llvm.extractValue(builder, result, 1);
            const raw_status = try llvm.extractValue(builder, result, 2);
            const reserved = try llvm.extractValue(builder, result, 3);
            break :blk try llvm.call(builder, preinit, &.{
                eager_ctx,
                try llvm.constInt(m.types.i32, module_id),
                try llvm.constInt(m.types.i32, @intFromBool(record.load_data_snapshot)),
                values_ptr,
                values_len,
                raw_status,
                reserved,
            });
        };
        const ok = try llvm.icmp(builder, .eq, status, try llvm.constInt(m.types.i32, 0));
        const next = try llvm.appendBlock(m.context, eager, "eager_next");
        const fail = try llvm.appendBlock(m.context, eager, "eager_fail");
        try llvm.condBr(builder, ok, next, fail);
        llvm.position(builder, fail);
        try llvm.ret(builder, status);
        llvm.position(builder, next);
    }
    try llvm.ret(builder, try llvm.constInt(m.types.i32, 0));

    if (std.debug.runtime_safety) try m.verify(a);
    return m;
}

pub fn writeMetadata(
    io: std.Io,
    a: A,
    path: []const u8,
    records: []const ModuleRecord,
    globals: *const analysis.Globals,
    shape_registry: *const shapes.Registry,
    module_ids: *const emitter.ModuleIdMap,
) !void {
    try validateRecords(a, records);
    const lookup_entries = try sortedLookupEntries(a, module_ids);
    defer a.free(lookup_entries);

    const module_count = try requireU32(records.len);
    const module_lookup_count = try requireU32(lookup_entries.len);
    const global_count = try requireU32(globals.names.items.len);
    const shape_count = try requireU32(shape_registry.count());
    const shape_field_total = try shapeFieldTotal(shape_registry);
    var module_requirement_total_usize: usize = 0;
    for (records) |record|
        module_requirement_total_usize = std.math.add(
            usize,
            module_requirement_total_usize,
            record.eager_requirements.len,
        ) catch return error.ProgramMetadataTooLarge;
    const module_requirement_total = try requireU32(module_requirement_total_usize);
    var synth_export_total_usize: usize = 0;
    for (records) |record| {
        if (!record.synth_root) continue;
        synth_export_total_usize = std.math.add(
            usize,
            synth_export_total_usize,
            record.direct_exports.len,
        ) catch return error.ProgramMetadataTooLarge;
    }
    const synth_export_total = try requireU32(synth_export_total_usize);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;

    try w.writeAll(metadata.magic);
    try metadata.writeU32(w, module_count);
    try metadata.writeU32(w, module_lookup_count);
    try metadata.writeU32(w, global_count);
    try metadata.writeU32(w, shape_count);
    try metadata.writeU32(w, shape_field_total);
    try metadata.writeU32(w, module_requirement_total);
    try metadata.writeU32(w, synth_export_total);

    for (records) |record| try metadata.writeString(w, record.title);

    for (lookup_entries) |entry| {
        if (entry.id >= module_count) return error.InvalidModuleLookupId;
        try metadata.writeString(w, entry.name);
        try metadata.writeU32(w, entry.id);
    }

    for (records) |record|
        try metadata.writeU32(w, record.export_shape_id orelse std.math.maxInt(u32));

    for (records) |record| {
        try metadata.writeU32(w, record.function_base);
        try metadata.writeU32(w, record.function_count);
    }

    for (records) |record| {
        try metadata.writeU32(w, try requireU32(record.eager_requirements.len));
        for (record.eager_requirements) |requirement| {
            if (requirement.module_id >= module_count)
                return error.InvalidModuleRequirementId;
            try metadata.writeU32(w, requirement.module_id);
            try metadata.writeString(w, requirement.requested);
        }
    }

    for (records) |record| {
        try metadata.writeU32(w, @intFromBool(record.load_data_snapshot));
        try metadata.writeString(w, record.static_root_blob);
    }

    for (records) |record| {
        try metadata.writeU32(w, @intFromBool(record.synth_root));
        const exports = if (record.synth_root) record.direct_exports else &.{};
        try metadata.writeU32(w, try requireU32(exports.len));
        for (exports) |entry| {
            if (entry.capture_count != 0) return error.InvalidSyntheticRootCapture;
            try metadata.writeString(w, entry.name);
            try metadata.writeU32(w, entry.function_id);
        }
    }

    for (globals.names.items) |name| try metadata.writeString(w, name);

    for (0..shape_registry.count()) |shape_index| {
        const shape = shape_registry.record(@intCast(shape_index));
        try metadata.writeU32(w, try requireU32(shape.fields.len));
        for (shape.fields) |field| try metadata.writeString(w, field);

        const slots = try a.alloc(u32, shape.fields.len);
        defer a.free(slots);
        for (slots, 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u32, slots, shape.fields, struct {
            fn lessThan(fields: []const []const u8, lhs: u32, rhs: u32) bool {
                return std.mem.order(u8, fields[lhs], fields[rhs]) == .lt;
            }
        }.lessThan);
        for (slots) |slot| try metadata.writeU32(w, slot);
    }
    try w.flush();
}
