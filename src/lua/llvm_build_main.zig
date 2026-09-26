const std = @import("std");
const lua = @import("parser/root.zig");
const analysis = @import("direct/analysis.zig");
const emitter = @import("direct/emitter.zig");
const program = @import("direct/program.zig");
const shapes = @import("direct/shapes.zig");
const module_model = @import("direct/module_model.zig");
const static_encode = @import("direct/static_literal_encode.zig");
const usage = @import("usage.zig");
const usage_profile = @import("direct/usage_profile.zig");

const parse_pipeline = @import("parse_pipeline.zig");
const A = std.mem.Allocator;
const ManifestRow = parse_pipeline.Row;
const ModuleRecord = program.ModuleRecord;
const NamedModuleEdge = struct {
    from: u32,
    target: []const u8,
};
const FunctionAnalysisStats = struct {
    functions: usize = 0,
    dead: usize = 0,
    pure_data_roots: usize = 0,
    synth_callable_roots: usize = 0,
};

fn readAll(io: std.Io, a: A, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try a.alloc(u8, len);
    if (try file.readPositionalAll(io, bytes, 0) != len) return error.Truncated;
    return bytes;
}
fn sourcePath(a: A, root: []const u8, relative: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, relative });
}

fn batchSuffix(mode: usage_profile.CompileMode) []const u8 {
    return switch (mode) {
        .o0 => "o0",
        .o1 => "o1",
        .o2 => "o2",
    };
}

fn outputBatchPath(
    a: A,
    root: []const u8,
    mode: usage_profile.CompileMode,
    batch_index: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        a,
        "{s}/module_batch_{s}_{d:0>6}.bc",
        .{ root, batchSuffix(mode), batch_index },
    );
}

fn outputBatchName(
    a: A,
    mode: usage_profile.CompileMode,
    batch_index: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        a,
        "module_batch_{s}_{d:0>6}.bc",
        .{ batchSuffix(mode), batch_index },
    );
}

test "O0 batch names are distinct" {
    const name = try outputBatchName(std.testing.allocator, .o0, 3);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("module_batch_o0_000003.bc", name);
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

fn buildModuleIds(io: std.Io, a: A, source_root: []const u8, records: anytype) !emitter.ModuleIdMap {
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
fn resolveModuleEdges(
    a: A,
    named_edges: []const NamedModuleEdge,
    module_ids: *const emitter.ModuleIdMap,
) ![]usage_profile.ModuleEdge {
    var edges: std.ArrayList(usage_profile.ModuleEdge) = .empty;
    errdefer edges.deinit(a);
    for (named_edges) |edge| {
        const to = module_ids.get(edge.target) orelse continue;
        try edges.append(a, .{ .from = edge.from, .to = to });
    }
    return edges.toOwnedSlice(a);
}

const EagerEdge = struct {
    from: u32,
    to: u32,
};

fn eagerEdgeLess(_: void, lhs: EagerEdge, rhs: EagerEdge) bool {
    return lhs.from < rhs.from or (lhs.from == rhs.from and lhs.to < rhs.to);
}

fn resolveEagerModule(
    a: A,
    module_ids: *const emitter.ModuleIdMap,
    raw: []const u8,
) !?u32 {
    const canonical = (try usage.canonicalModule(a, raw)) orelse return null;
    defer a.free(canonical);
    return module_ids.get(canonical);
}

fn planEagerInit(
    a: A,
    records: []ModuleRecord,
    module_ids: *const emitter.ModuleIdMap,
    stable_require: bool,
    eager_seed: []const bool,
) !usize {
    if (eager_seed.len != records.len) return error.InvalidEagerPlan;
    const candidate = try a.alloc(bool, records.len);
    defer a.free(candidate);
    const blocked = try a.alloc(bool, records.len);
    defer a.free(blocked);
    @memset(blocked, false);
    for (candidate, records) |*out, record|
        out.* = record.root_bootstrap_safe and
            (record.root_requires.len == 0 or stable_require);

    // Eager preparation is an optimization for hot executable roots. O2 already
    // denotes the corpus-usage coverage set; colder O1 modules stay available
    // through lazy require. Retain the exact bootstrap-safe dependency closure
    // of the hot seeds.
    const needed = try a.alloc(bool, records.len);
    defer a.free(needed);
    @memset(needed, false);
    var needed_queue: std.ArrayList(u32) = .empty;
    defer needed_queue.deinit(a);
    for (candidate, eager_seed, records, 0..) |can, seed, record, index| {
        if (can and seed and !record.static_root and !record.synth_root) {
            needed[index] = true;
            try needed_queue.append(a, @intCast(index));
        }
    }
    var needed_read: usize = 0;
    while (needed_read < needed_queue.items.len) : (needed_read += 1) {
        const module_id: usize = @intCast(needed_queue.items[needed_read]);
        for (records[module_id].root_requires) |raw| {
            const dependency = (try resolveEagerModule(a, module_ids, raw)) orelse continue;
            if (dependency >= records.len or !candidate[dependency] or needed[dependency]) continue;
            needed[dependency] = true;
            try needed_queue.append(a, dependency);
        }
    }

    var edges: std.ArrayList(EagerEdge) = .empty;
    defer edges.deinit(a);
    for (records, 0..) |record, module_index| {
        if (!candidate[module_index] or !needed[module_index]) continue;
        for (record.root_requires) |raw| {
            const dependency = (try resolveEagerModule(a, module_ids, raw)) orelse {
                blocked[module_index] = true;
                continue;
            };
            if (dependency >= records.len or !candidate[dependency] or !needed[dependency]) {
                blocked[module_index] = true;
                continue;
            }
            try edges.append(a, .{
                .from = dependency,
                .to = @intCast(module_index),
            });
        }
    }

    std.mem.sort(EagerEdge, edges.items, {}, eagerEdgeLess);
    if (edges.items.len > 1) {
        var write: usize = 1;
        var previous = edges.items[0];
        for (edges.items[1..]) |edge| {
            if (edge.from == previous.from and edge.to == previous.to) continue;
            edges.items[write] = edge;
            write += 1;
            previous = edge;
        }
        edges.items.len = write;
    }

    const indegree = try a.alloc(u32, records.len);
    defer a.free(indegree);
    @memset(indegree, 0);
    const offsets = try a.alloc(u32, records.len + 1);
    defer a.free(offsets);
    @memset(offsets, 0);
    for (edges.items) |edge| {
        indegree[edge.to] += 1;
        offsets[edge.from + 1] += 1;
    }
    for (1..offsets.len) |index|
        offsets[index] += offsets[index - 1];

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (candidate, needed, blocked, indegree, 0..) |can, is_needed, is_blocked, degree, index|
        if (can and is_needed and !is_blocked and degree == 0)
            try queue.append(a, @intCast(index));

    var read: usize = 0;
    var eager_count: usize = 0;
    while (read < queue.items.len) : (read += 1) {
        const module_id = queue.items[read];
        records[module_id].eager_order = @intCast(eager_count);
        eager_count += 1;
        for (edges.items[offsets[module_id]..offsets[module_id + 1]]) |edge| {
            if (!needed[edge.to]) continue;
            indegree[edge.to] -= 1;
            if (indegree[edge.to] == 0 and
                candidate[edge.to] and needed[edge.to] and !blocked[edge.to])
                try queue.append(a, edge.to);
        }
    }

    for (records) |*record| {
        if (record.eager_order == std.math.maxInt(u32)) {
            record.eager_requirements = &.{};
            continue;
        }
        const requirements = try a.alloc(program.EagerRequirement, record.root_requires.len);
        for (requirements, record.root_requires) |*requirement, raw| {
            const dependency = (try resolveEagerModule(a, module_ids, raw)) orelse
                return error.InvalidEagerPlan;
            requirement.* = .{
                .module_id = dependency,
                .requested = raw,
            };
        }
        record.eager_requirements = requirements;
    }

    return eager_count;
}

fn compilePlanLabel(keep: bool, static_root: bool, mode: usage_profile.CompileMode) []const u8 {
    if (!keep) return "drop";
    if (static_root) return "data";
    return mode.flag();
}

test "compile plan keeps data-only roots out of O0 batches" {
    try std.testing.expectEqualStrings("data", compilePlanLabel(true, true, .o0));
    try std.testing.expectEqualStrings("-O0", compilePlanLabel(true, false, .o0));
    try std.testing.expectEqualStrings("drop", compilePlanLabel(false, false, .o0));
}

fn writeCompilePlan(
    io: std.Io,
    a: A,
    output_root: []const u8,
    records: []const ModuleRecord,
    modes: []const usage_profile.CompileMode,
    profile: usage_profile.Profile,
    reachable: []const bool,
) !void {
    if (modes.len != records.len or profile.page_reach.len != modes.len or
        reachable.len != records.len)
        return error.InvalidCompilePlan;

    const path = try std.fs.path.join(a, &.{ output_root, "compile-plan.tsv" });
    defer a.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll("# dict-llvm-compile-plan-v3\n");
    try w.writeAll("# index\topt\tdirect_pages\tpage_reach\tdirect_module_fanin\tmodule_reach\tsource_bytes\n");

    var o0_count: usize = 0;
    var o1_count: usize = 0;
    var o2_count: usize = 0;
    var data_count: usize = 0;
    var pruned_count: usize = 0;
    for (modes, records, reachable, 0..) |mode, record, keep, index| {
        if (!keep) {
            pruned_count += 1;
        } else if (record.static_root) {
            data_count += 1;
        } else switch (mode) {
            .o0 => o0_count += 1,
            .o1 => o1_count += 1,
            .o2 => o2_count += 1,
        }
        try w.print("{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            index,
            compilePlanLabel(keep, record.static_root, mode),
            profile.direct_page_reach[index],
            profile.page_reach[index],
            profile.direct_module_fanin[index],
            profile.module_reach[index],
            record.source_bytes,
        });
    }
    try w.flush();
    std.debug.print(
        "LLVM_OPT_PLAN o0={d} o1={d} o2={d} data={d} pruned={d}\n",
        .{ o0_count, o1_count, o2_count, data_count, pruned_count },
    );
}

const ManifestAnalysis = struct {
    records: []ModuleRecord,
    page_seed: usage_profile.PageSeeds,
};

fn analyzeManifest(
    io: std.Io,
    a: A,
    manifest: []const u8,
    source_root: []const u8,
    globals: *analysis.Globals,
    shape_registry: *shapes.Registry,
    named_module_edges: *std.ArrayList(NamedModuleEdge),
    named_load_data_targets: *std.ArrayList([]const u8),
    function_stats: *FunctionAnalysisStats,
    dead_functions_by_module: *std.ArrayList(u32),
    parse_workers: usize,
) !ManifestAnalysis {
    var records: std.ArrayList(ModuleRecord) = .empty;
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    var function_base: u32 = 0;
    var rows: std.ArrayList(ManifestRow) = .empty;
    defer rows.deinit(a);
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try rows.append(a, try std.json.parseFromSliceLeaky(ManifestRow, a, line, .{ .ignore_unknown_fields = true }));
    }
    var ids = try buildModuleIds(io, a, source_root, rows.items);
    defer ids.deinit(a);
    const usage_path = try std.fs.path.join(a, &.{ source_root, "lua-usage.tsv" });
    defer a.free(usage_path);
    var seeds = try usage_profile.pageSeeds(io, a, usage_path, &ids, rows.items.len);
    defer seeds.deinit(a);
    const queued = try a.alloc(bool, rows.items.len);
    defer a.free(queued);
    @memset(queued, false);
    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(a);
    for (seeds.values, 0..) |reach, id| {
        if (reach != 0 or seeds.dynamic_module_target) {
            try pending.append(a, id);
            queued[id] = true;
        }
    }
    var all_reachable = seeds.dynamic_module_target;
    var pool = try parse_pipeline.Pool.init(io, source_root, parse_workers);
    defer pool.deinit();
    var scheduled: usize = 0;
    var index: usize = 0;
    while (index < pending.items.len) : (index += 1) {
        while (scheduled < @min(index + pool.slots.len, pending.items.len)) : (scheduled += 1)
            pool.slots[scheduled % pool.slots.len].dispatch(rows.items[pending.items[scheduled]]);
        const slot = &pool.slots[index % pool.slots.len];
        try slot.wait();
        defer slot.release();
        const row = slot.row;
        if (slot.dynamic and !all_reachable) {
            all_reachable = true;
            for (queued, 0..) |*seen, id| {
                if (!seen.*) {
                    try pending.append(a, id);
                    seen.* = true;
                }
            }
        } else if (!all_reachable) {
            for (slot.requires.items) |target| {
                const id = ids.get(target) orelse continue;
                if (!queued[id]) {
                    try pending.append(a, id);
                    queued[id] = true;
                }
            }
        }
        const sa = scratch.allocator();
        const chunk = &slot.chunk.?;
        const module_index: u32 = @intCast(records.items.len);

        if (static_encode.rootLiteral(chunk.body)) |literal| {
            const export_shape_id = try shape_registry.collectRootExpr(module_index, literal);
            var table_shapes = try shape_registry.moduleFacts(sa, module_index);
            // scratch.reset below frees the arena-backed map in one step.
            // Deinitializing it after that reset would access freed storage.
            const blob = try static_encode.encode(sa, literal, &table_shapes);
            try records.append(a, .{
                .title = try a.dupe(u8, row.title),
                .path = try a.dupe(u8, row.path),
                .source_bytes = row.bytes,
                .source_index = module_index,
                .function_base = function_base,
                .function_count = 1,
                .root_function = function_base,
                .export_shape_id = export_shape_id,
                .root_pure = true,
                .root_bootstrap_safe = true,
                .static_root = true,
                .static_root_blob = try a.dupe(u8, blob),
            });
            try dead_functions_by_module.append(a, 0);
            function_base = std.math.add(u32, function_base, 1) catch return error.TooManyFunctions;
            _ = scratch.reset(.retain_capacity);
            continue;
        }

        if (try static_encode.encodePureDataRoot(sa, chunk.body, shape_registry, module_index)) |evaluated| {
            try records.append(a, .{
                .title = try a.dupe(u8, row.title),
                .path = try a.dupe(u8, row.path),
                .source_bytes = row.bytes,
                .source_index = module_index,
                .function_base = function_base,
                .function_count = 1,
                .root_function = function_base,
                .export_shape_id = evaluated.export_shape_id,
                .root_pure = true,
                .root_bootstrap_safe = true,
                .static_root = true,
                .static_root_blob = try a.dupe(u8, evaluated.blob),
            });
            function_stats.pure_data_roots += 1;
            try dead_functions_by_module.append(a, 0);
            function_base = std.math.add(u32, function_base, 1) catch return error.TooManyFunctions;
            _ = scratch.reset(.retain_capacity);
            continue;
        }

        try shape_registry.collect(module_index, chunk.body);

        const static_requires = slot.requires;
        const static_load_data = slot.load_data;
        const dynamic_module_load = slot.dynamic;
        for (static_load_data.items) |target|
            try named_load_data_targets.append(a, try a.dupe(u8, target));
        var seen_requires: std.StringHashMapUnmanaged(void) = .empty;
        for (static_requires.items) |target| {
            if (seen_requires.contains(target)) continue;
            try seen_requires.put(sa, target, {});
            try named_module_edges.append(a, .{
                .from = module_index,
                .target = try a.dupe(u8, target),
            });
        }

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
        var module = try analysis.analyze(sa, globals, chunk, function_base);
        const count: u32 = @intCast(module.functions.items.len);
        function_stats.functions += module.functions.items.len;
        var module_dead_functions: u32 = 0;
        for (module.functions.items) |info| module_dead_functions += @intFromBool(info.dead);
        function_stats.dead += module_dead_functions;
        try dead_functions_by_module.append(a, module_dead_functions);

        var direct_exports: std.ArrayList(emitter.DirectExport) = .empty;
        if (!model.dynamic_top_level) switch (model.return_binding) {
            .table => |table| {
                var fields = table.fields.iterator();
                while (fields.next()) |entry| switch (entry.value_ptr.*) {
                    .function => |span_start| {
                        var target: ?*const analysis.FunctionInfo = null;
                        for (module.functions.items[1..]) |info| {
                            if (info.span.start == span_start) {
                                target = info;
                                break;
                            }
                        }
                        const info = target orelse continue;
                        try direct_exports.append(a, .{
                            .name = try a.dupe(u8, entry.key_ptr.*),
                            .function_id = info.id,
                            .capture_count = @intCast(info.upvalues.len),
                        });
                    },
                    else => {},
                };
            },
            else => {},
        };

        std.mem.sort(emitter.DirectExport, direct_exports.items, {}, struct {
            fn lessThan(_: void, lhs: emitter.DirectExport, rhs: emitter.DirectExport) bool {
                return std.mem.order(u8, lhs.name, rhs.name) == .lt;
            }
        }.lessThan);

        var synth_literals: std.ArrayList(static_encode.NamedLiteralField) = .empty;
        if (!model.dynamic_top_level) switch (model.return_binding) {
            .table => |table| {
                var fields = table.fields.iterator();
                while (fields.next()) |entry| switch (entry.value_ptr.*) {
                    .literal => |value| try synth_literals.append(sa, .{
                        .name = entry.key_ptr.*,
                        .value = value,
                    }),
                    else => {},
                };
            },
            else => {},
        };
        std.mem.sort(static_encode.NamedLiteralField, synth_literals.items, {}, struct {
            fn lessThan(_: void, lhs: static_encode.NamedLiteralField, rhs: static_encode.NamedLiteralField) bool {
                return std.mem.order(u8, lhs.name, rhs.name) == .lt;
            }
        }.lessThan);

        var synth_callable_root = false;
        var synth_callable_blob: []const u8 = &.{};
        if (model.root_pure and model.root_bootstrap_safe and !model.dynamic_top_level and
            direct_exports.items.len == 0) switch (model.return_binding) {
            .function => |span_start| {
                var target: ?*const analysis.FunctionInfo = null;
                for (module.functions.items[1..]) |info| if (info.span.start == span_start) {
                    target = info;
                    break;
                };
                if (target) |info| if (info.parent_id == module.root.id) {
                    var capture_exprs: std.ArrayList(*const lua.Expr) = .empty;
                    defer capture_exprs.deinit(sa);
                    var captures_valid = true;
                    for (info.upvalues) |upvalue| {
                        if (upvalue.mutated) {
                            captures_valid = false;
                            break;
                        }
                        const binding = switch (upvalue.source) {
                            .local => |id| id,
                            .upvalue => {
                                captures_valid = false;
                                break;
                            },
                        };
                        if (!captures_valid or binding >= module.root.bindings.len) {
                            captures_valid = false;
                            break;
                        }
                        const name = module.root.bindings[binding].name;
                        const final_binding = model.env.get(name) orelse {
                            captures_valid = false;
                            break;
                        };
                        const literal = switch (final_binding) {
                            .literal => |value| value,
                            else => {
                                captures_valid = false;
                                break;
                            },
                        };
                        if (!static_encode.isScalarLiteral(literal)) {
                            captures_valid = false;
                            break;
                        }
                        try capture_exprs.append(sa, literal);
                    }
                    if (captures_valid and capture_exprs.items.len == info.upvalues.len) {
                        const captures = try static_encode.encodeScalarLiteralList(sa, capture_exprs.items);
                        const owned = try a.alloc(u8, captures.len + 1);
                        owned[0] = static_encode.synth_callable_marker;
                        @memcpy(owned[1..], captures);
                        synth_callable_blob = owned;
                        try direct_exports.append(a, .{
                            .name = "",
                            .function_id = info.id,
                            .capture_count = @intCast(info.upvalues.len),
                        });
                        synth_callable_root = true;
                        function_stats.synth_callable_roots += 1;
                    }
                };
            },
            else => {},
        };

        var synth_root = synth_callable_root;
        if (!synth_callable_root and model.root_pure and !model.dynamic_top_level) switch (model.return_binding) {
            .table => |table| {
                synth_root = table.shape_eligible and
                    table.fields.count() == direct_exports.items.len + synth_literals.items.len;
                if (synth_root) for (direct_exports.items) |entry| {
                    if (entry.capture_count != 0) {
                        synth_root = false;
                        break;
                    }
                };
            },
            else => {},
        };

        var synth_seed_blob: []const u8 = synth_callable_blob;
        if (!synth_callable_root and synth_root and synth_literals.items.len != 0) switch (model.return_binding) {
            .table => |table| {
                var table_shapes = try shape_registry.moduleFacts(sa, module_index);
                defer table_shapes.deinit(sa);
                const seed = try static_encode.encodeNamedTable(
                    sa,
                    table.span_start,
                    synth_literals.items,
                    &table_shapes,
                );
                synth_seed_blob = try a.dupe(u8, seed);
            },
            else => unreachable,
        };

        const root_requires = try a.alloc([]const u8, model.root_requires.items.len);
        for (root_requires, model.root_requires.items) |*owned, raw|
            owned.* = try a.dupe(u8, raw);

        try records.append(a, .{
            .title = try a.dupe(u8, row.title),
            .path = try a.dupe(u8, row.path),
            .source_bytes = row.bytes,
            .source_index = module_index,
            .function_base = function_base,
            .function_count = count,
            .root_function = module.root.id,
            .export_shape_id = export_shape_id,
            .dynamic_module_load = dynamic_module_load,
            .root_pure = model.root_pure,
            .root_bootstrap_safe = model.root_bootstrap_safe,
            .root_requires = root_requires,
            .direct_exports = try direct_exports.toOwnedSlice(a),
            .static_root_blob = synth_seed_blob,
            .synth_root = synth_root,
            .synth_callable_root = synth_callable_root,
        });
        function_base = std.math.add(u32, function_base, count) catch return error.TooManyFunctions;
        module.deinit();
        model.deinit();
        _ = scratch.reset(.retain_capacity);
    }
    std.debug.print("LLVM_PARSE selected={d}/{d} workers={d}\n", .{ records.items.len, rows.items.len, parse_workers });
    const selected_seeds = try a.alloc(u64, records.items.len);
    for (selected_seeds, pending.items) |*value, id| value.* = seeds.values[id];
    return .{
        .records = try records.toOwnedSlice(a),
        .page_seed = .{ .values = selected_seeds, .dynamic_module_target = seeds.dynamic_module_target },
    };
}
const modules_per_batch: usize = 64;
// Bound batch codegen memory independently of the O1/O2 usage policy.
// Large individual modules may exceed this and are emitted alone.
const max_batch_source_bytes: u64 = 1 * 1024 * 1024;

fn appendModuleToBatch(
    io: std.Io,
    scratch: A,
    index: usize,
    record: ModuleRecord,
    source_root: []const u8,
    globals: *analysis.Globals,
    module_ids: *const emitter.ModuleIdMap,
    shape_registry: *const shapes.Registry,
    module_facts: []const emitter.ModuleFact,
    method_candidates: []const emitter.MethodCandidate,
    batch: *emitter.Batch,
    frozen_global_count: usize,
) !void {
    const path = try sourcePath(scratch, source_root, record.path);
    const source = try readAll(io, scratch, path);
    var chunk = try lua.parse(scratch, source);
    defer chunk.deinit();
    var module = try analysis.analyze(scratch, globals, &chunk, record.function_base);
    defer module.deinit();

    if (globals.names.items.len != frozen_global_count)
        return error.GlobalAnalysisMismatch;
    if (module.root.id != record.root_function or
        module.functions.items.len != record.function_count)
        return error.FunctionAnalysisMismatch;

    var table_shapes = try shape_registry.moduleFacts(scratch, record.source_index);
    defer table_shapes.deinit(scratch);
    const facts = emitter.ProgramFacts{
        .module_ids = module_ids,
        .module_facts = module_facts,
        .method_candidates = method_candidates,
        .table_shapes = &table_shapes,
        .synth_root = record.synth_root,
        .current_module_id = @intCast(index),
    };
    const result = try batch.append(scratch, globals, &module, facts);
    if (result.root_function != record.root_function or
        result.function_count != record.function_count)
        return error.FunctionAnalysisMismatch;
}

fn emitBatches(
    io: std.Io,
    a: A,
    records: []const ModuleRecord,
    modes: []const usage_profile.CompileMode,
    source_root: []const u8,
    output_root: []const u8,
    globals: *analysis.Globals,
    module_ids: *const emitter.ModuleIdMap,
    shape_registry: *const shapes.Registry,
    module_facts: []const emitter.ModuleFact,
    method_candidates: []const emitter.MethodCandidate,
    value_leaf_bc: []const u8,
) !void {
    if (records.len != modes.len) return error.InvalidCompilePlan;

    const batch_plan_path = try std.fs.path.join(a, &.{ output_root, "batch-plan.tsv" });
    defer a.free(batch_plan_path);
    var batch_plan_file = try std.Io.Dir.cwd().createFile(
        io,
        batch_plan_path,
        .{ .truncate = true },
    );
    defer batch_plan_file.close(io);
    var batch_plan_buffer: [64 * 1024]u8 = undefined;
    var batch_plan_writer = batch_plan_file.writer(io, &batch_plan_buffer);
    const plan = &batch_plan_writer.interface;
    try plan.writeAll("# dict-llvm-batch-plan-v1\n");
    try plan.writeAll("# opt\tfile\tcount\tfirst\tlast\tsource_bytes\n");

    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch_arena.deinit();
    const frozen_global_count = globals.names.items.len;
    var emitted: usize = 0;

    inline for (&.{ usage_profile.CompileMode.o2, usage_profile.CompileMode.o1, usage_profile.CompileMode.o0 }) |mode| {
        var selected: std.ArrayList(usize) = .empty;
        defer selected.deinit(a);
        for (modes, records, 0..) |candidate, record, index|
            if (candidate == mode and program.needsLlvmBatch(record)) try selected.append(a, index);

        var position: usize = 0;
        var batch_index: usize = 0;
        while (position < selected.items.len) : (batch_index += 1) {
            const batch_started_ns = std.Io.Clock.awake.now(io).toNanoseconds();
            var batch = try emitter.Batch.init();
            errdefer batch.deinit();
            if (mode != .o0) try batch.importValueLeafBitcode(a, value_leaf_bc);

            const first_index = selected.items[position];
            var last_index = first_index;
            var batch_count: usize = 0;
            var batch_source_bytes: u64 = 0;

            while (position < selected.items.len and batch_count < modules_per_batch) {
                const index = selected.items[position];
                const source_bytes = records[index].source_bytes;
                if (batch_count != 0 and
                    batch_source_bytes +| source_bytes > max_batch_source_bytes)
                    break;

                const scratch = scratch_arena.allocator();
                try appendModuleToBatch(
                    io,
                    scratch,
                    index,
                    records[index],
                    source_root,
                    globals,
                    module_ids,
                    shape_registry,
                    module_facts,
                    method_candidates,
                    &batch,
                    frozen_global_count,
                );
                _ = scratch_arena.reset(.retain_capacity);

                last_index = index;
                batch_count += 1;
                batch_source_bytes +|= source_bytes;
                position += 1;
                emitted += 1;
                if (emitted % 1000 == 0)
                    std.debug.print("LLVM_EMIT modules={d}/{d}\n", .{ emitted, records.len });
            }

            const output = try outputBatchPath(a, output_root, mode, batch_index);
            defer a.free(output);
            const name = try outputBatchName(a, mode, batch_index);
            defer a.free(name);
            try batch.writeBitcode(a, output);
            batch.deinit();

            try plan.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                mode.flag(),
                name,
                batch_count,
                first_index,
                last_index,
                batch_source_bytes,
            });
            try plan.flush();
            const batch_elapsed_ms = @divTrunc(std.Io.Clock.awake.now(io).toNanoseconds() - batch_started_ns, std.time.ns_per_ms);
            std.debug.print("LLVM_EMIT_BATCH mode={s} count={d} source_bytes={d} elapsed_ms={d}\n", .{
                mode.flag(), batch_count, batch_source_bytes, batch_elapsed_ms,
            });
        }
    }
    try plan.flush();
    var static_roots: usize = 0;
    var bodyless_synth_roots: usize = 0;
    for (records) |record| {
        static_roots += @intFromBool(record.static_root);
        bodyless_synth_roots += @intFromBool(record.synth_root and !program.needsLlvmBatch(record));
    }
    std.debug.print("LLVM_STATIC_ROOTS modules={d} emitted={d}\n", .{ static_roots, emitted });
    std.debug.print("LLVM_BODYLESS_SYNTH_ROOTS modules={d}\n", .{bodyless_synth_roots});
    if (emitted + static_roots + bodyless_synth_roots != records.len)
        return error.IncompleteLlvmEmission;
}

/// Pilot source-derived class method targets. A call site still tests the
/// exact live callable ID, so an override or unrelated receiver is safe.
fn languageMethodCandidates(io: std.Io, a: A, source_root: []const u8, records: []const ModuleRecord) ![]const emitter.MethodCandidate {
    for (records, 0..) |record, module_id| {
        if (!std.mem.eql(u8, record.title, "Module:languages")) continue;
        const path = try sourcePath(a, source_root, record.path);
        defer a.free(path);
        const source = try readAll(io, a, path);
        defer a.free(source);
        var chunk = try lua.parse(a, source);
        defer chunk.deinit();
        var globals = try analysis.Globals.init(a);
        defer globals.deinit();
        var module = try analysis.analyze(a, &globals, &chunk, record.function_base);
        defer module.deinit();
        var candidates: std.ArrayList(emitter.MethodCandidate) = .empty;
        errdefer candidates.deinit(a);
        for (chunk.body) |statement| {
            if (statement.* != .function_assign) continue;
            const assignment = statement.function_assign;
            if (assignment.target != .index or assignment.function.* != .function) continue;
            const target = assignment.target.index;
            if (target.object.* != .name or target.key.* != .string) continue;
            if (!std.mem.eql(u8, target.object.name.value, "Language")) continue;
            const method_name = target.key.string.value;
            const name: []const u8 = if (std.mem.eql(u8, method_name, "getCode"))
                "getCode"
            else if (std.mem.eql(u8, method_name, "getCanonicalName"))
                "getCanonicalName"
            else
                continue;
            const span = assignment.function.function.span;
            for (module.functions.items[1..]) |info| {
                if (info.span.start != span.start or info.span.end != span.end) continue;
                try candidates.append(a, .{
                    .name = name,
                    .function_id = info.id,
                    .module_id = @intCast(module_id),
                    .capture_count = @intCast(info.upvalues.len),
                });
                break;
            }
        }
        return candidates.toOwnedSlice(a);
    }
    return &.{};
}

fn run(io: std.Io, a: A, args: []const []const u8) !void {
    if (args.len < 4) return error.Usage;
    var analysis_only = false;
    var parse_workers: usize = @min(4, std.Thread.getCpuCount() catch 1);
    var value_leaf_path: ?[]const u8 = null;
    var option: usize = 4;
    while (option < args.len) : (option += 1) {
        if (std.mem.eql(u8, args[option], "--analysis-only")) {
            analysis_only = true;
        } else if (std.mem.eql(u8, args[option], "--parse-workers")) {
            option += 1;
            if (option == args.len) return error.Usage;
            parse_workers = try std.fmt.parseInt(usize, args[option], 10);
            if (parse_workers == 0 or parse_workers > 64) return error.Usage;
        } else if (std.mem.eql(u8, args[option], "--value-leaf-bc")) {
            option += 1;
            if (option == args.len or value_leaf_path != null) return error.Usage;
            value_leaf_path = args[option];
        } else return error.Usage;
    }
    const manifest_path = args[1];
    const source_root = args[2];
    const output_root = args[3];

    try std.Io.Dir.cwd().createDirPath(io, output_root);
    const manifest = try readAll(io, a, manifest_path);
    var globals = try analysis.Globals.init(a);
    defer globals.deinit();
    var shape_registry = shapes.Registry.init(a);
    defer shape_registry.deinit();
    var named_module_edges: std.ArrayList(NamedModuleEdge) = .empty;
    defer named_module_edges.deinit(a);
    var named_load_data_targets: std.ArrayList([]const u8) = .empty;
    defer named_load_data_targets.deinit(a);
    var function_stats: FunctionAnalysisStats = .{};
    var dead_functions_by_module: std.ArrayList(u32) = .empty;
    defer dead_functions_by_module.deinit(a);
    const analyzed = try analyzeManifest(
        io,
        a,
        manifest,
        source_root,
        &globals,
        &shape_registry,
        &named_module_edges,
        &named_load_data_targets,
        &function_stats,
        &dead_functions_by_module,
        parse_workers,
    );
    const records = analyzed.records;
    var page_seed = analyzed.page_seed;
    defer page_seed.deinit(a);
    if (dead_functions_by_module.items.len != records.len) return error.FunctionAnalysisMismatch;
    if (records.len > std.math.maxInt(u32) - 2) return error.TooManyModules;
    std.debug.print("LLVM_ANALYZE modules={d} globals={d} functions={d}\n", .{
        records.len,
        globals.names.items.len,
        if (records.len == 0) @as(u32, 0) else records[records.len - 1].function_base + records[records.len - 1].function_count,
    });
    std.debug.print("LLVM_FUNCTION_LIVENESS dead={d}/{d}\n", .{
        function_stats.dead,
        function_stats.functions,
    });
    std.debug.print("LLVM_PURE_DATA_ROOTS modules={d}\n", .{function_stats.pure_data_roots});
    var synth_root_count: usize = 0;
    for (records) |record| synth_root_count += @intFromBool(record.synth_root);
    std.debug.print("LLVM_SYNTH_ROOTS modules={d}\n", .{synth_root_count});
    std.debug.print("LLVM_SYNTH_CALLABLE_ROOTS modules={d}\n", .{function_stats.synth_callable_roots});
    std.debug.print("LLVM_SHAPES count={d} fields={d}\n", .{
        shape_registry.count(),
        shape_registry.fieldCount(),
    });

    var module_ids = try buildModuleIds(io, a, source_root, records);
    defer module_ids.deinit(a);
    if (module_ids.count() > std.math.maxInt(u32)) return error.TooManyModuleNames;
    if (shape_registry.count() > std.math.maxInt(u32)) return error.TooManyShapes;

    const module_edges = try resolveModuleEdges(a, named_module_edges.items, &module_ids);
    defer a.free(module_edges);
    var profile = try usage_profile.buildProfile(a, page_seed.values, module_edges);
    defer usage_profile.deinitProfile(a, &profile);

    const module_sizes = try a.alloc(u64, records.len);
    defer a.free(module_sizes);
    const dynamic_module_load = try a.alloc(bool, records.len);
    defer a.free(dynamic_module_load);
    for (module_sizes, dynamic_module_load, records) |*size, *dynamic, record| {
        size.* = record.source_bytes;
        dynamic.* = record.dynamic_module_load;
    }
    const modes = try usage_profile.chooseModes(a, profile, module_sizes);
    defer a.free(modes);
    const reachable = try usage_profile.reachableModules(
        a,
        profile,
        dynamic_module_load,
        page_seed.dynamic_module_target,
    );
    defer a.free(reachable);
    try writeCompilePlan(io, a, output_root, records, modes, profile, reachable);

    var selected_records: std.ArrayList(ModuleRecord) = .empty;
    defer selected_records.deinit(a);
    var selected_modes: std.ArrayList(usage_profile.CompileMode) = .empty;
    defer selected_modes.deinit(a);
    var selected_eager_seed: std.ArrayList(bool) = .empty;
    defer selected_eager_seed.deinit(a);
    for (records, modes, reachable) |record, mode, keep| if (keep) {
        try selected_records.append(a, record);
        try selected_modes.append(a, mode);
        try selected_eager_seed.append(a, mode == .o2);
    };

    var selected_module_ids = try buildModuleIds(io, a, source_root, selected_records.items);
    defer selected_module_ids.deinit(a);
    if (selected_module_ids.count() > std.math.maxInt(u32)) return error.TooManyModuleNames;

    const eager_count = try planEagerInit(
        a,
        selected_records.items,
        &selected_module_ids,
        globals.stable("require"),
        selected_eager_seed.items,
    );
    std.debug.print("LLVM_EAGER_INIT modules={d}/{d}\n", .{
        eager_count,
        selected_records.items.len,
    });

    for (named_load_data_targets.items) |target| {
        const id = selected_module_ids.get(target) orelse continue;
        if (id < selected_records.items.len and selected_records.items[id].root_pure)
            selected_records.items[id].load_data_snapshot = true;
    }
    std.debug.print(
        "LLVM_REACHABLE modules={d}/{d} dynamic_fallback={}\n",
        .{ selected_records.items.len, records.len, page_seed.dynamic_module_target },
    );

    var reachable_static: usize = 0;
    var reachable_synth: usize = 0;
    var reachable_llvm: usize = 0;
    var executable_o0: usize = 0;
    var executable_o1: usize = 0;
    var executable_o2: usize = 0;
    var reachable_analysis_functions: usize = 0;
    var reachable_dead_functions: usize = 0;
    var selected_index: usize = 0;
    for (records, modes, reachable, dead_functions_by_module.items) |record, mode, keep, dead_count| {
        if (!keep) continue;
        reachable_static += @intFromBool(record.static_root);
        reachable_synth += @intFromBool(record.synth_root);
        if (!record.static_root) {
            reachable_analysis_functions += record.function_count;
            reachable_dead_functions += dead_count;
        }
        if (program.needsLlvmBatch(record)) {
            reachable_llvm += 1;
            switch (mode) {
                .o0 => executable_o0 += 1,
                .o1 => executable_o1 += 1,
                .o2 => executable_o2 += 1,
            }
        }
        if (selected_index >= selected_records.items.len or
            !std.mem.eql(u8, selected_records.items[selected_index].title, record.title))
            return error.InvalidCompilePlan;
        selected_index += 1;
    }
    if (selected_index != selected_records.items.len) return error.InvalidCompilePlan;
    std.debug.print(
        "LLVM_REACHABLE_ROOTS static={d} synth={d} llvm={d}\n",
        .{ reachable_static, reachable_synth, reachable_llvm },
    );
    std.debug.print(
        "LLVM_EXEC_OPT o0={d} o1={d} o2={d}\n",
        .{ executable_o0, executable_o1, executable_o2 },
    );
    std.debug.print(
        "LLVM_REACHABLE_FUNCTION_LIVENESS dead={d}/{d}\n",
        .{ reachable_dead_functions, reachable_analysis_functions },
    );
    if (analysis_only) {
        std.debug.print("LLVM_ANALYSIS_ONLY_DONE modules={d}\n", .{selected_records.items.len});
        return;
    }

    const leaf_path = value_leaf_path orelse return error.MissingValueLeafBitcode;
    var leaf_file = try std.Io.Dir.cwd().openFile(io, leaf_path, .{});
    defer leaf_file.close(io);
    const leaf_stat = try leaf_file.stat(io);
    if (leaf_stat.size == 0 or leaf_stat.size > 1024 * 1024) return error.InvalidLeafBitcodeSize;
    const leaf_bc = try a.alloc(u8, @intCast(leaf_stat.size));
    if (try leaf_file.readPositionalAll(io, leaf_bc, 0) != leaf_bc.len)
        return error.TruncatedLeafBitcode;

    const selected_module_facts = try a.alloc(emitter.ModuleFact, selected_records.items.len);
    defer a.free(selected_module_facts);
    for (selected_module_facts, selected_records.items) |*fact, record| {
        fact.* = .{
            .root_pure = record.root_pure,
            .eager_prepared = record.eager_order != std.math.maxInt(u32),
            .canonical_name = record.title,
            .exports = record.direct_exports,
        };
    }

    const method_candidates = try languageMethodCandidates(io, a, source_root, selected_records.items);
    defer if (method_candidates.len != 0) a.free(method_candidates);
    std.debug.print("LLVM_METHOD_CANDIDATES count={d}\n", .{method_candidates.len});
    for (method_candidates) |candidate| std.debug.print(
        "LLVM_METHOD_CANDIDATE name={s} id={d} module={d} captures={d}\n",
        .{ candidate.name, candidate.function_id, candidate.module_id, candidate.capture_count },
    );

    try emitBatches(
        io,
        a,
        selected_records.items,
        selected_modes.items,
        source_root,
        output_root,
        &globals,
        &selected_module_ids,
        &shape_registry,
        selected_module_facts,
        method_candidates,
        leaf_bc,
    );

    var program_module = try program.generate(a, selected_records.items);
    defer program_module.deinit();
    const program_path = try std.fs.path.join(a, &.{ output_root, "program.bc" });
    try program_module.writeBitcode(a, program_path);

    const metadata_path = try std.fs.path.join(a, &.{ output_root, "program.meta" });
    try program.writeMetadata(
        io,
        a,
        metadata_path,
        selected_records.items,
        &globals,
        &shape_registry,
        &selected_module_ids,
    );
    std.debug.print("LLVM_DONE modules={d} globals={d}\n", .{ selected_records.items.len, globals.names.items.len });
}

pub export fn dict_llvm_build_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc < 4 or argc > 9) {
        std.debug.print("usage: dict-llvm-build MANIFEST SOURCE_ROOT OUTPUT_DIR [--analysis-only] [--parse-workers N] [--value-leaf-bc PATH]\n", .{});
        return 2;
    }

    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    var args: [9][]const u8 = undefined;
    for (args[0..@intCast(argc)], 0..) |*arg, index| arg.* = std.mem.span(argv[index]);
    run(threaded.io(), arena.allocator(), args[0..@intCast(argc)]) catch |err| {
        std.debug.print("dict-llvm-build: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
