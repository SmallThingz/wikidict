//! Native Wikibase reads from immutable, explicitly captured build inputs.
const std = @import("std");
const rt = @import("zig_runtime");
const host_api = @import("host.zig");
const text = @import("text.zig");
const Value = rt.Value;

fn one(value: Value) ![]const Value {
    const result = try std.heap.smp_allocator.alloc(Value, 1);
    result[0] = value;
    return result;
}

fn two(first: Value, second: Value) ![]const Value {
    const result = try std.heap.smp_allocator.alloc(Value, 2);
    result[0] = first;
    result[1] = second;
    return result;
}

fn validNumericPart(digits: []const u8) bool {
    if (digits.len == 0 or digits[0] == '0') return false;
    const value = std.fmt.parseInt(u32, digits, 10) catch return false;
    return value <= 2_147_483_647;
}

pub fn canonicalEntityId(runtime: *rt.Context, raw: []const u8) !?[]const u8 {
    if (raw.len < 2) return null;
    if (raw[0] == 'L') {
        if (std.mem.indexOfScalar(u8, raw, '-')) |dash| {
            if (dash <= 1 or dash + 2 >= raw.len) return null;
            if (raw[dash + 1] != 'F' and raw[dash + 1] != 'S') return null;
            if (!std.ascii.isDigit(raw[1]) or raw[1] == '0') return null;
            for (raw[1..dash]) |c| if (!std.ascii.isDigit(c)) return null;
            const suffix = raw[dash + 2 ..];
            if (suffix.len == 0 or suffix[0] == '0') return null;
            for (suffix) |c| if (!std.ascii.isDigit(c)) return null;
            return try runtime.allocator.dupe(u8, raw);
        }
    }
    const prefix = std.ascii.toUpper(raw[0]);
    if (prefix != 'Q' and prefix != 'P' and prefix != 'L') return null;
    if (!validNumericPart(raw[1..])) return null;
    const out = try runtime.allocator.alloc(u8, raw.len);
    out[0] = prefix;
    @memcpy(out[1..], raw[1..]);
    return out;
}

fn entityId(runtime: *rt.Context, args: []const Value) ![]const u8 {
    if (args.len == 0 or args[0] == .nil) return error.NotImplemented;
    if (args[0] != .string) return error.StringExpected;
    return (try canonicalEntityId(runtime, args[0].string)) orelse error.InvalidEntityId;
}

fn field(table: *rt.Table, key: []const u8) ?Value {
    return table.rawGet(.{ .string = key });
}

fn tableField(table: *rt.Table, key: []const u8) !?*rt.Table {
    const value = field(table, key) orelse return null;
    if (value == .nil) return null;
    if (value != .table) return error.InvalidWikibaseEntitySnapshot;
    return value.table;
}

fn stringField(table: *rt.Table, key: []const u8) !?[]const u8 {
    const value = field(table, key) orelse return null;
    if (value == .nil) return null;
    if (value != .string) return error.InvalidWikibaseEntitySnapshot;
    return value.string;
}

fn logSnapshotFailure(id: []const u8, comptime kind: []const u8, comptime status: []const u8) void {
    const prefix = "Wikibase " ++ kind ++ " snapshot " ++ status ++ " entity=";
    // Include logLine's maximum 15-byte PID prefix and the final newline in
    // the 128-byte record limit. Valid ordinary IDs are emitted in full.
    const id_limit = 128 - 15 - prefix.len - 1;
    const truncated = id.len > id_limit;
    const visible = id[0..@min(id.len, if (truncated) id_limit - 3 else id_limit)];
    rt.work_stats.logLine(prefix ++ "{s}{s}\n", .{ visible, if (truncated) "..." else "" });
}

fn snapshotFailure(runtime: *rt.Context, id: []const u8, comptime kind: []const u8) !void {
    logSnapshotFailure(id, kind, "missing");
    runtime.last_error = .{ .string = try std.fmt.allocPrint(
        runtime.allocator,
        "Wikibase {s} snapshot missing entity={s}",
        .{ kind, id },
    ) };
    return error.LuaRaised;
}

fn readEntity(runtime: *rt.Context, id: []const u8) anyerror!?*rt.Table {
    const host = host_api.getForStablePageRead(runtime) orelse {
        logSnapshotFailure(id, "entity", "unavailable");
        return error.MissingScribuntoHost;
    };
    const get = host.wikibase_entity orelse {
        logSnapshotFailure(id, "entity", "unavailable");
        return error.NotImplemented;
    };
    const entry = get(host.ctx, id) catch |err| {
        if (err == error.WikibaseEntitySnapshotMissing) {
            if (id[0] == 'L') if (std.mem.indexOfScalar(u8, id, '-')) |dash|
                return readCapturedSubentity(runtime, id, dash);
            try snapshotFailure(runtime, id, "entity");
        }
        return err;
    };
    const source = entry.source orelse return null;
    // flags=0 preserves Lua's one-based arrays. Each call owns a fresh graph;
    // mutations of returned lemmas, forms or statements cannot poison capture.
    const decoded = (if (entry.parsed) |parsed|
        text.jsonToLua(runtime, parsed.*, false)
    else
        text.jsonDecodeValue(runtime, source, 0)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidWikibaseEntitySnapshot,
    };
    if (decoded != .table) return error.InvalidWikibaseEntitySnapshot;
    const version = field(decoded.table, "schemaVersion") orelse return error.InvalidWikibaseEntitySnapshot;
    if (version != .number or version.number < 2) return error.InvalidWikibaseEntitySnapshot;
    _ = (try stringField(decoded.table, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
    return decoded.table;
}

fn readCapturedSubentity(runtime: *rt.Context, id: []const u8, dash: usize) anyerror!?*rt.Table {
    // A full captured Lexeme is authoritative for its embedded Forms/Senses.
    // Missing parent evidence still fails through readEntity; only explicit
    // parent absence or an absent child within a captured parent returns nil.
    const parent = (try readEntity(runtime, id[0..dash])) orelse return null;
    const parent_id = (try stringField(parent, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
    const canonical = try std.fmt.allocPrint(runtime.allocator, "{s}{s}", .{ parent_id, id[dash..] });
    const is_form = id[dash + 1] == 'F';
    const children = (try tableField(parent, if (is_form) "forms" else "senses")) orelse return null;
    var it = children.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
        const child = entry.value_ptr.table;
        const child_id = (try stringField(child, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
        if (!std.mem.eql(u8, child_id, canonical)) continue;
        try child.rawSet(runtime.allocator, .{ .string = "schemaVersion" }, .{ .number = 2 });
        try child.rawSet(runtime.allocator, .{ .string = "type" }, .{ .string = if (is_form) "form" else "sense" });
        return child;
    }
    return null;
}

// A lease either borrows immutable snapshot backing or owns one request parse.
// Returned Lua graphs/scalars always own fresh copies. Forms/Senses retain
// readEntity's captured-parent fallback and canonical-child handling.
const EntityProjection = struct {
    value: std.json.Value,
    owned: ?std.json.Parsed(std.json.Value) = null,

    fn deinit(self: *EntityProjection) void {
        if (self.owned) |*parsed| parsed.deinit();
    }
};

const projectionNumber = @import("wikibase_entity_cache.zig").projectionNumber;
const validateProjectionNumbers = @import("wikibase_entity_cache.zig").validateProjectionNumbers;

fn projectionField(table: std.json.Value, key: []const u8) ?std.json.Value {
    // jsonToLua turns canonical i64 object keys into numeric Lua keys. These
    // string lookups cannot find those keys, or an array's numeric indices.
    if (table != .object) return null;
    const integer = std.fmt.parseInt(i64, key, 10) catch return table.object.get(key);
    var buffer: [32]u8 = undefined;
    const canonical = std.fmt.bufPrint(&buffer, "{d}", .{integer}) catch unreachable;
    if (std.mem.eql(u8, canonical, key)) return null;
    return table.object.get(key);
}

fn projectionTableField(table: std.json.Value, key: []const u8) !?std.json.Value {
    const value = projectionField(table, key) orelse return null;
    return switch (value) {
        .null => null,
        .array, .object => value,
        else => error.InvalidWikibaseEntitySnapshot,
    };
}

fn projectionStringField(table: std.json.Value, key: []const u8) !?[]const u8 {
    const value = projectionField(table, key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |string| string,
        else => error.InvalidWikibaseEntitySnapshot,
    };
}

fn readProjectedEntity(runtime: *rt.Context, id: []const u8) !?EntityProjection {
    std.debug.assert(std.mem.indexOfScalar(u8, id, '-') == null);
    const host = host_api.getForStablePageRead(runtime) orelse {
        logSnapshotFailure(id, "entity", "unavailable");
        return error.MissingScribuntoHost;
    };
    const get = host.wikibase_entity orelse {
        logSnapshotFailure(id, "entity", "unavailable");
        return error.NotImplemented;
    };
    const entry = get(host.ctx, id) catch |err| {
        if (err == error.WikibaseEntitySnapshotMissing) try snapshotFailure(runtime, id, "entity");
        return err;
    };
    const source = entry.source orelse return null;
    var parsed: EntityProjection = if (entry.parsed) |borrowed| .{ .value = borrowed.* } else blk: {
        const owned = std.json.parseFromSlice(std.json.Value, runtime.allocator, source, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidWikibaseEntitySnapshot,
        };
        break :blk .{ .value = owned.value, .owned = owned };
    };
    errdefer parsed.deinit();
    if (entry.parsed == null or !entry.parsed_numbers_validated)
        try validateProjectionNumbers(parsed.value);
    if (parsed.value != .object) return error.InvalidWikibaseEntitySnapshot;
    const version = projectionField(parsed.value, "schemaVersion") orelse return error.InvalidWikibaseEntitySnapshot;
    if (try projectionNumber(version) < 2) return error.InvalidWikibaseEntitySnapshot;
    _ = (try projectionStringField(parsed.value, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
    return parsed;
}

fn protectStatement(statement: *rt.Table) !void {
    if (try tableField(statement, "qualifiers")) |qualifiers| qualifiers.read_only = true;
    if (try tableField(statement, "references")) |references| references.read_only = true;
}

fn protectStatements(statements: *rt.Table) !void {
    var it = statements.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
        try protectStatement(entry.value_ptr.table);
    }
}

fn protectEntity(entity: *rt.Table) !void {
    if (try tableField(entity, "claims")) |claims| {
        var it = claims.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
            try protectStatements(entry.value_ptr.table);
        }
    }
    inline for (.{ "claims", "labels", "sitelinks", "descriptions", "aliases" }) |key|
        if (try tableField(entity, key)) |table| {
            table.read_only = true;
        };
}

fn getLemmasCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    const lemmas = (try tableField(args[0].table, "lemmas")) orelse return error.InvalidWikibaseEntitySnapshot;
    const result = try runtime.newTable();
    var it = lemmas.iterator();
    var index: usize = 1;
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
        const lemma = entry.value_ptr.table;
        const value = (try stringField(lemma, "value")) orelse return error.InvalidWikibaseEntitySnapshot;
        const language = (try stringField(lemma, "language")) orelse return error.InvalidWikibaseEntitySnapshot;
        const pair = try runtime.newTable();
        try pair.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = value });
        try pair.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = language });
        try result.rawSet(runtime.allocator, .{ .number = @floatFromInt(index) }, .{ .table = pair });
        index += 1;
    }
    return one(.{ .table = result });
}

fn overlayTerm(runtime: *rt.Context, entity: *rt.Table, key: []const u8, language: []const u8, term: ?host_api.WikibaseTerm) !void {
    const captured = term orelse return;
    const terms = (try tableField(entity, key)) orelse blk: {
        const created = try runtime.newTable();
        try entity.rawSet(runtime.allocator, .{ .string = key }, .{ .table = created });
        break :blk created;
    };
    if (field(terms, language) != null) return;
    const value = try runtime.newTable();
    try value.rawSet(runtime.allocator, .{ .string = "value" }, .{ .string = captured.value });
    try value.rawSet(runtime.allocator, .{ .string = "language" }, .{ .string = captured.language });
    if (captured.source_language) |source_language|
        try value.rawSet(runtime.allocator, .{ .string = "source-language" }, .{ .string = source_language });
    try terms.rawSet(runtime.allocator, .{ .string = language }, .{ .table = value });
}

fn overlayEntityTerms(runtime: *rt.Context, id: []const u8, entity: *rt.Table, kind: []const u8) !void {
    if (!std.mem.eql(u8, kind, "item") and !std.mem.eql(u8, kind, "property")) return;
    const language = (runtime.namespace_catalog orelse return error.MissingNamespaceRegistry).content_language;
    const labels = try tableField(entity, "labels");
    const descriptions = try tableField(entity, "descriptions");
    if (labels != null and field(labels.?, language) != null and
        descriptions != null and field(descriptions.?, language) != null) return;
    const terms = try readTerms(runtime, id);
    try overlayTerm(runtime, entity, "labels", language, terms.label);
    try overlayTerm(runtime, entity, "descriptions", language, terms.description);
}

fn entityReceiver(args: []const Value) !*rt.Table {
    if (args.len == 0 or args[0] != .table) return error.TableExpected;
    return args[0].table;
}

fn getIdMethodCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    return one(field(try entityReceiver(args), "id") orelse .nil);
}

fn getLanguageMethodCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    return one(field(try entityReceiver(args), "language") orelse .nil);
}

fn getLexicalCategoryMethodCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    return one(field(try entityReceiver(args), "lexicalCategory") orelse .nil);
}

fn getGrammaticalFeaturesMethodCall(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    // Wikibase returns this exact table, unlike the fresh list from getForms.
    return one(field(try entityReceiver(args), "grammaticalFeatures") orelse .nil);
}

fn termPairs(runtime: *rt.Context, entity: *rt.Table, key: []const u8) !*rt.Table {
    const terms = (try tableField(entity, key)) orelse return error.InvalidWikibaseEntitySnapshot;
    const result = try runtime.newTable();
    var it = terms.iterator();
    var index: usize = 1;
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
        const term = entry.value_ptr.table;
        const value = (try stringField(term, "value")) orelse return error.InvalidWikibaseEntitySnapshot;
        const language = (try stringField(term, "language")) orelse return error.InvalidWikibaseEntitySnapshot;
        const pair = try runtime.newTable();
        try pair.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = value });
        try pair.rawSet(runtime.allocator, .{ .number = 2 }, .{ .string = language });
        try result.rawSet(runtime.allocator, .{ .number = @floatFromInt(index) }, .{ .table = pair });
        index += 1;
    }
    return result;
}

fn singleTerm(runtime: *rt.Context, args: []const Value, key: []const u8) ![]const Value {
    const entity = try entityReceiver(args);
    const language = if (args.len < 2 or args[1] == .nil)
        (runtime.namespace_catalog orelse return error.MissingNamespaceRegistry).content_language
    else if (args[1] == .string)
        args[1].string
    else
        return error.StringExpected;
    const terms = (try tableField(entity, key)) orelse return error.InvalidWikibaseEntitySnapshot;
    const term = (try tableField(terms, language)) orelse return one(.nil);
    return two(
        field(term, "value") orelse .nil,
        field(term, "language") orelse .nil,
    );
}

fn getGlossesMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return one(.{ .table = try termPairs(runtime, try entityReceiver(args), "glosses") });
}

fn getGlossMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return singleTerm(runtime, args, "glosses");
}

fn getRepresentationsMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return one(.{ .table = try termPairs(runtime, try entityReceiver(args), "representations") });
}

fn getRepresentationMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return singleTerm(runtime, args, "representations");
}

fn cloneEntityStatementValue(runtime: *rt.Context, value: Value, seen: *std.AutoHashMapUnmanaged(*rt.Table, *rt.Table)) anyerror!Value {
    if (value != .table) return value;
    if (seen.get(value.table)) |copy| return .{ .table = copy };
    const copy = try runtime.newTable();
    try seen.put(runtime.allocator, value.table, copy);
    var it = value.table.iterator();
    while (it.next()) |entry| {
        const cloned = try cloneEntityStatementValue(runtime, entry.value_ptr.*, seen);
        try copy.rawSet(runtime.allocator, entry.key_ptr.*, cloned);
    }
    copy.append_index = value.table.append_index;
    if (value.table.metatable) |metatable|
        copy.metatable = (try cloneEntityStatementValue(runtime, .{ .table = metatable }, seen)).table;
    return .{ .table = copy };
}

fn getAllStatementsMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const entity = try entityReceiver(args);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const claims = (try tableField(entity, "claims")) orelse return one(.{ .table = try runtime.newTable() });
    const property = (try canonicalEntityId(runtime, args[1].string)) orelse return error.InvalidPropertyId;
    if (property[0] != 'P') return error.InvalidPropertyId;
    const statements = (try tableField(claims, property)) orelse return one(.{ .table = try runtime.newTable() });
    // The object method reads this object's current fields, and deep-clones
    // every statement on every call. It never fetches the entity again.
    var seen: std.AutoHashMapUnmanaged(*rt.Table, *rt.Table) = .empty;
    defer seen.deinit(runtime.allocator);
    const copy = (try cloneEntityStatementValue(runtime, .{ .table = statements }, &seen)).table;
    try protectStatements(copy);
    return one(.{ .table = copy });
}

fn getSitelinkMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const entity = try entityReceiver(args);
    const sitelinks = (try tableField(entity, "sitelinks")) orelse return one(.nil);
    const site = if (args.len < 2 or args[1] == .nil)
        (runtime.namespace_catalog orelse return error.MissingNamespaceRegistry).wiki
    else if (args[1] == .string)
        args[1].string
    else
        return error.StringExpected;
    const sitelink = (try tableField(sitelinks, site)) orelse return one(.nil);
    return one(field(sitelink, "title") orelse .nil);
}

fn entityChildren(runtime: *rt.Context, entity: *rt.Table, key: []const u8, kind: []const u8) !*rt.Table {
    const result = try runtime.newTable();
    // Empty top-level forms/senses are omitted by canonical capture. A
    // captured entity with no such field therefore has an empty list.
    const children = (try tableField(entity, key)) orelse return result;
    var it = children.iterator();
    var index: usize = 1;
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .table) return error.InvalidWikibaseEntitySnapshot;
        const child = entry.value_ptr.table;
        _ = (try stringField(child, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
        try child.rawSet(runtime.allocator, .{ .string = "schemaVersion" }, .{ .number = 2 });
        try installEntityMethods(runtime, child, kind);
        // Preserve subentity identity across calls; only the list is new.
        try result.rawSet(runtime.allocator, .{ .number = @floatFromInt(index) }, .{ .table = child });
        index += 1;
    }
    return result;
}

fn getSensesMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return one(.{ .table = try entityChildren(runtime, try entityReceiver(args), "senses", "sense") });
}

fn getFormsMethodCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    return one(.{ .table = try entityChildren(runtime, try entityReceiver(args), "forms", "form") });
}

fn installEntityMethods(runtime: *rt.Context, entity: *rt.Table, kind: []const u8) anyerror!void {
    try protectEntity(entity);
    const methods = try runtime.newTable();
    try methods.rawSet(runtime.allocator, .{ .string = "getId" }, try runtime.newNative(null, getIdMethodCall));
    try methods.rawSet(runtime.allocator, .{ .string = "getAllStatements" }, try runtime.newNative(null, getAllStatementsMethodCall));
    try methods.rawSet(runtime.allocator, .{ .string = "getSitelink" }, try runtime.newNative(null, getSitelinkMethodCall));
    if (std.mem.eql(u8, kind, "lexeme")) {
        try methods.rawSet(runtime.allocator, .{ .string = "getLemmas" }, try runtime.newNative(null, getLemmasCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getLanguage" }, try runtime.newNative(null, getLanguageMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getLexicalCategory" }, try runtime.newNative(null, getLexicalCategoryMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getSenses" }, try runtime.newNative(null, getSensesMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getForms" }, try runtime.newNative(null, getFormsMethodCall));
    } else if (std.mem.eql(u8, kind, "sense")) {
        try methods.rawSet(runtime.allocator, .{ .string = "getGlosses" }, try runtime.newNative(null, getGlossesMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getGloss" }, try runtime.newNative(null, getGlossMethodCall));
    } else if (std.mem.eql(u8, kind, "form")) {
        try methods.rawSet(runtime.allocator, .{ .string = "getRepresentations" }, try runtime.newNative(null, getRepresentationsMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getRepresentation" }, try runtime.newNative(null, getRepresentationMethodCall));
        try methods.rawSet(runtime.allocator, .{ .string = "getGrammaticalFeatures" }, try runtime.newNative(null, getGrammaticalFeaturesMethodCall));
    }
    const metatable = try runtime.newTable();
    try metatable.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = methods });
    entity.metatable = metatable;
}

pub fn getEntityCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    const entity = (try readEntity(runtime, id)) orelse return one(.nil);
    const kind = (try stringField(entity, "type")) orelse return error.InvalidWikibaseEntitySnapshot;
    try overlayEntityTerms(runtime, id, entity, kind);
    try installEntityMethods(runtime, entity, kind);
    return one(.{ .table = entity });
}

pub fn getAllStatementsCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const property = (try canonicalEntityId(runtime, args[1].string)) orelse return error.InvalidPropertyId;
    if (property[0] != 'P') return error.InvalidPropertyId;
    if (std.mem.indexOfScalar(u8, id, '-') == null) {
        var parsed = (try readProjectedEntity(runtime, id)) orelse return one(.{ .table = try runtime.newTable() });
        defer parsed.deinit();
        if (try projectionTableField(parsed.value, "claims")) |claims|
            if (try projectionTableField(claims, property)) |source| {
                const decoded = text.jsonToLua(runtime, source, false) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidWikibaseEntitySnapshot,
                };
                if (decoded != .table) return error.InvalidWikibaseEntitySnapshot;
                try protectStatements(decoded.table);
                return one(decoded);
            };
        return one(.{ .table = try runtime.newTable() });
    }
    const entity = try readEntity(runtime, id);
    if (entity) |value| if (try tableField(value, "claims")) |claims|
        if (try tableField(claims, property)) |statements| {
            try protectStatements(statements);
            return one(.{ .table = statements });
        };
    return one(.{ .table = try runtime.newTable() });
}

pub fn getBestStatementsCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    // getAllStatements provides a fresh graph and the established shallow
    // qualifier/reference protections. Rank selection must not consult terms.
    const all = try getAllStatementsCall(null, runtime, args);
    defer rt.freeResults(all);
    const statements = all[0].table;
    const count = statements.rawLen();
    var preferred = false;
    for (0..count) |index| {
        const statement = statements.rawGet(.{ .number = @floatFromInt(index + 1) }) orelse return error.InvalidWikibaseEntitySnapshot;
        if (statement != .table) return error.InvalidWikibaseEntitySnapshot;
        const rank = (try stringField(statement.table, "rank")) orelse return error.InvalidWikibaseEntitySnapshot;
        if (std.mem.eql(u8, rank, "preferred")) {
            preferred = true;
        } else if (!std.mem.eql(u8, rank, "normal") and !std.mem.eql(u8, rank, "deprecated")) {
            return error.InvalidWikibaseEntitySnapshot;
        }
    }
    const result = try runtime.newTable();
    var selected: usize = 0;
    for (0..count) |index| {
        const statement = statements.rawGet(.{ .number = @floatFromInt(index + 1) }).?;
        const rank = (try stringField(statement.table, "rank")).?;
        if (!std.mem.eql(u8, rank, if (preferred) "preferred" else "normal")) continue;
        selected += 1;
        try result.rawSet(runtime.allocator, .{ .number = @floatFromInt(selected) }, statement);
    }
    return one(.{ .table = result });
}

pub fn getLabelByLangCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    if (std.mem.indexOfScalar(u8, id, '-') == null) {
        var parsed = (try readProjectedEntity(runtime, id)) orelse return one(.nil);
        defer parsed.deinit();
        const labels = (try projectionTableField(parsed.value, "labels")) orelse return one(.nil);
        const label = (try projectionTableField(labels, args[1].string)) orelse return one(.nil);
        const value = (try projectionStringField(label, "value")) orelse return one(.nil);
        return one(.{ .string = try runtime.allocator.dupe(u8, value) });
    }
    const entity = (try readEntity(runtime, id)) orelse return one(.nil);
    const labels = (try tableField(entity, "labels")) orelse return one(.nil);
    const label = (try tableField(labels, args[1].string)) orelse return one(.nil);
    return one(if (try stringField(label, "value")) |value| .{ .string = value } else .nil);
}

fn readTerms(runtime: *rt.Context, id: []const u8) !host_api.WikibaseEntityTerms {
    const host = host_api.getForStablePageRead(runtime) orelse {
        logSnapshotFailure(id, "entity-term", "unavailable");
        return error.MissingScribuntoHost;
    };
    const get = host.wikibase_entity_terms orelse {
        logSnapshotFailure(id, "entity-term", "unavailable");
        return error.NotImplemented;
    };
    return get(host.ctx, id) catch |err| {
        if (err == error.WikibaseEntityTermSnapshotMissing) try snapshotFailure(runtime, id, "entity-term");
        return err;
    };
}

pub fn getLabelWithLangCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const terms = try readTerms(runtime, try entityId(runtime, args));
    const label = terms.label orelse return two(.nil, .nil);
    return two(.{ .string = label.value }, .{ .string = label.language });
}

pub fn getLabelCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const terms = try readTerms(runtime, try entityId(runtime, args));
    return one(if (terms.label) |label| .{ .string = label.value } else .nil);
}

pub fn getDescriptionCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const terms = try readTerms(runtime, try entityId(runtime, args));
    return one(if (terms.description) |description| .{ .string = description.value } else .nil);
}

pub fn getGlobalSiteIdCall(_: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const registry = runtime.namespace_catalog orelse return error.MissingNamespaceRegistry;
    return one(.{ .string = registry.wiki });
}

pub fn getSitelinkCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    const site = if (args.len < 2 or args[1] == .nil)
        (runtime.namespace_catalog orelse return error.MissingNamespaceRegistry).wiki
    else if (args[1] == .string)
        args[1].string
    else
        return error.StringExpected;
    rt.work_stats.noteSitelink(id, site);
    if (std.mem.indexOfScalar(u8, id, '-') == null) {
        var parsed = (try readProjectedEntity(runtime, id)) orelse return one(.nil);
        defer parsed.deinit();
        const sitelinks = (try projectionTableField(parsed.value, "sitelinks")) orelse return one(.nil);
        const sitelink = (try projectionTableField(sitelinks, site)) orelse return one(.nil);
        const value = (try projectionStringField(sitelink, "title")) orelse return one(.nil);
        return one(.{ .string = try runtime.allocator.dupe(u8, value) });
    }
    const entity = (try readEntity(runtime, id)) orelse return one(.nil);
    const sitelinks = (try tableField(entity, "sitelinks")) orelse return one(.nil);
    const sitelink = (try tableField(sitelinks, site)) orelse return one(.nil);
    return one(if (try stringField(sitelink, "title")) |value| .{ .string = value } else .nil);
}

const Probe = struct {
    const lexeme =
        \\{"id":"L1","type":"lexeme","schemaVersion":2,
        \\"lemmas":{"ar":{"language":"ar","value":"كتب"}},
        \\"forms":[{"id":"L1-F1","representations":{"ar":{"language":"ar","value":"كَتَبَ"}}}],
        \\"senses":[{"id":"L1-S1","glosses":{}}],
        \\"claims":{"P1":[
        \\{"rank":"preferred","mainsnak":{"snaktype":"value"},"qualifiers":{"P2":[{"snaktype":"somevalue"}]},"references":[{"snaks":{"P3":[{"snaktype":"novalue"}]}}]},
        \\{"rank":"normal","mainsnak":{"snaktype":"somevalue"}},
        \\{"rank":"deprecated","mainsnak":{"snaktype":"novalue"}}]}}
    ;
    const item =
        \\{"id":"Q1","type":"item","schemaVersion":2,
        \\"labels":{"fr":{"language":"fr","value":"bonjour"}},
        \\"descriptions":{"de":{"language":"de","value":"Beschreibung"}},
        \\"aliases":{"fr":[{"language":"fr","value":"salut"}]},
        \\"sitelinks":{"enwiktionary":{"site":"enwiktionary","title":"word"}}}
    ;

    fn entity(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
        if (std.mem.eql(u8, id, "L1")) return .{ .source = lexeme };
        if (std.mem.eql(u8, id, "Q1")) return .{ .source = item };
        if (std.mem.eql(u8, id, "Q9")) return .{ .source = null };
        if (std.mem.eql(u8, id, "Q8")) return .{ .source = "[]" };
        if (std.mem.eql(u8, id, "Q7")) return error.AccessDenied;
        return error.WikibaseEntitySnapshotMissing;
    }

    fn terms(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntityTerms {
        if (std.mem.eql(u8, id, "Q1")) return .{
            .label = .{ .value = "bonjour", .language = "fr" },
            .description = .{ .value = "Beschreibung", .language = "de", .source_language = "de" },
        };
        if (std.mem.eql(u8, id, "Q9")) return .{ .label = null, .description = null };
        if (std.mem.eql(u8, id, "Q7")) return error.AccessDenied;
        return error.WikibaseEntityTermSnapshotMissing;
    }
};

test "Wikibase lexeme arrays methods and shallow protections preserve independent mutable children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    // Lexeme loading never requires fallback term evidence.
    var host = host_api.Host{ .wikibase_entity = Probe.entity };
    host_api.set(&runtime, &host);
    const first = try getEntityCall(null, &runtime, &.{.{ .string = "L1" }});
    defer rt.freeResults(first);
    const entity = first[0].table;
    const forms = (try tableField(entity, "forms")).?;
    try std.testing.expect(forms.rawGet(.{ .number = 0 }) == null);
    const form = forms.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expectEqualStrings("L1-F1", (try stringField(form, "id")).?);
    const method = try runtime.getIndex(first[0], .{ .string = "getLemmas" });
    const lemmas = try runtime.callValue(method, &.{first[0]});
    defer rt.freeResults(lemmas);
    const pair = lemmas[0].table.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expectEqualStrings("كتب", pair.rawGet(.{ .number = 1 }).?.string);
    try std.testing.expectEqualStrings("ar", pair.rawGet(.{ .number = 2 }).?.string);
    try pair.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "changed pair" });
    const next_lemmas = try runtime.callValue(method, &.{first[0]});
    defer rt.freeResults(next_lemmas);
    try std.testing.expectEqualStrings("كتب", next_lemmas[0].table.rawGet(.{ .number = 1 }).?.table.rawGet(.{ .number = 1 }).?.string);

    const claims = (try tableField(entity, "claims")).?;
    try std.testing.expectError(error.ReadOnlyTable, claims.rawSet(runtime.allocator, .{ .string = "P4" }, .nil));
    const statements = (try tableField(claims, "P1")).?;
    const statement = statements.rawGet(.{ .number = 1 }).?.table;
    const qualifiers = (try tableField(statement, "qualifiers")).?;
    const references = (try tableField(statement, "references")).?;
    try std.testing.expectError(error.ReadOnlyTable, qualifiers.rawSet(runtime.allocator, .{ .string = "P4" }, .nil));
    try std.testing.expectError(error.ReadOnlyTable, references.rawSet(runtime.allocator, .{ .number = 2 }, .nil));
    const qualifier_snaks = (try tableField(qualifiers, "P2")).?;
    try qualifier_snaks.rawSet(runtime.allocator, .{ .number = 2 }, .{ .number = 7 });
    try references.rawGet(.{ .number = 1 }).?.table.rawSet(runtime.allocator, .{ .string = "mutable" }, .{ .boolean = true });
    try (try tableField(statement, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "changed" });
    try form.rawSet(runtime.allocator, .{ .string = "id" }, .{ .string = "changed form" });
    try (try tableField((try tableField(entity, "lemmas")).?, "ar")).?.rawSet(runtime.allocator, .{ .string = "value" }, .{ .string = "changed lemma" });

    const second = try getEntityCall(null, &runtime, &.{.{ .string = "L1" }});
    defer rt.freeResults(second);
    const second_forms = (try tableField(second[0].table, "forms")).?;
    try std.testing.expectEqualStrings("L1-F1", (try stringField(second_forms.rawGet(.{ .number = 1 }).?.table, "id")).?);
    try std.testing.expectEqualStrings("كتب", (try stringField((try tableField((try tableField(second[0].table, "lemmas")).?, "ar")).?, "value")).?);
    const second_claims = (try tableField((try tableField(second[0].table, "claims")).?, "P1")).?;
    try std.testing.expectEqualStrings("value", (try stringField((try tableField(second_claims.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?, "snaktype")).?);
}

test "Wikibase all statements preserves every rank order and does not reuse prior results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .wikibase_entity = Probe.entity };
    host_api.set(&runtime, &host);
    const first = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L1" }, .{ .string = "P1" } });
    defer rt.freeResults(first);
    for ([_][]const u8{ "preferred", "normal", "deprecated" }, 1..) |rank, index| {
        const statement = first[0].table.rawGet(.{ .number = @floatFromInt(index) }).?.table;
        try std.testing.expectEqualStrings(rank, (try stringField(statement, "rank")).?);
    }
    try std.testing.expect(first[0].table.rawGet(.{ .number = 4 }) == null);
    const first_statement = first[0].table.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expect((try tableField(first_statement, "qualifiers")).?.read_only);
    try std.testing.expect((try tableField(first_statement, "references")).?.read_only);
    try first[0].table.rawSet(runtime.allocator, .{ .number = 1 }, .nil);
    const second = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L1" }, .{ .string = "P1" } });
    defer rt.freeResults(second);
    try std.testing.expectEqualStrings("preferred", (try stringField(second[0].table.rawGet(.{ .number = 1 }).?.table, "rank")).?);
    inline for (.{ "L1", "Q9" }) |id| {
        const absent = try getAllStatementsCall(null, &runtime, &.{ .{ .string = id }, .{ .string = "P9" } });
        defer rt.freeResults(absent);
        try std.testing.expect(absent[0] == .table and absent[0].table.rawGet(.{ .number = 1 }) == null);
    }
}

test "Wikibase best statements select ranks in order and preserve fresh mutable results" {
    const BestProbe = struct {
        const source =
            \\{"id":"Q1","type":"item","schemaVersion":2,"claims":{
            \\"P1":[{"id":"n1","rank":"normal","mainsnak":{"snaktype":"value"}},
            \\{"id":"p1","rank":"preferred","mainsnak":{"snaktype":"novalue"},"qualifiers":{"P2":[{"snaktype":"somevalue"}]},"references":[]},
            \\{"id":"d1","rank":"deprecated","mainsnak":{"snaktype":"value"}},
            \\{"id":"p2","rank":"preferred","mainsnak":{"snaktype":"somevalue"}},
            \\{"id":"n2","rank":"normal","mainsnak":{"snaktype":"value"}}],
            \\"P2":[{"id":"d1","rank":"deprecated"},{"id":"n1","rank":"normal"},{"id":"n2","rank":"normal"}],
            \\"P3":[{"rank":"deprecated"}],"P4":[]}}
        ;
        fn entity(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
            if (std.mem.eql(u8, id, "Q1")) return .{ .source = source };
            if (std.mem.eql(u8, id, "Q9")) return .{ .source = null };
            if (std.mem.eql(u8, id, "Q7")) return error.AccessDenied;
            if (std.mem.eql(u8, id, "Q6")) return error.OutOfMemory;
            return error.WikibaseEntitySnapshotMissing;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    // Deliberately no entity-term provider: best statements need claims only.
    var host = host_api.Host{ .wikibase_entity = BestProbe.entity };
    host_api.set(&runtime, &host);
    const first = try getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
    defer rt.freeResults(first);
    try std.testing.expectEqual(@as(usize, 2), first[0].table.rawLen());
    for ([_][]const u8{ "p1", "p2" }, 1..) |id, index| {
        const statement = first[0].table.rawGet(.{ .number = @floatFromInt(index) }).?.table;
        try std.testing.expectEqualStrings(id, (try stringField(statement, "id")).?);
    }
    const selected = first[0].table.rawGet(.{ .number = 1 }).?.table;
    const qualifiers = (try tableField(selected, "qualifiers")).?;
    const references = (try tableField(selected, "references")).?;
    try std.testing.expect(qualifiers.read_only and references.read_only);
    try (try tableField(qualifiers, "P2")).?.rawSet(runtime.allocator, .{ .number = 2 }, .{ .number = 7 });
    try (try tableField(selected, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "changed" });
    try first[0].table.rawSet(runtime.allocator, .{ .number = 1 }, .nil);
    const fresh = try getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
    defer rt.freeResults(fresh);
    const fresh_first = fresh[0].table.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expectEqualStrings("novalue", (try stringField((try tableField(fresh_first, "mainsnak")).?, "snaktype")).?);
    try std.testing.expect((try tableField((try tableField(fresh_first, "qualifiers")).?, "P2")).?.rawGet(.{ .number = 2 }) == null);
    const normal = try getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P2" } });
    defer rt.freeResults(normal);
    try std.testing.expectEqual(@as(usize, 2), normal[0].table.rawLen());
    for ([_][]const u8{ "n1", "n2" }, 1..) |id, index|
        try std.testing.expectEqualStrings(id, (try stringField(normal[0].table.rawGet(.{ .number = @floatFromInt(index) }).?.table, "id")).?);
    for ([_][]const u8{ "P3", "P4", "P9" }) |property| {
        const empty = try getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = property } });
        defer rt.freeResults(empty);
        try std.testing.expectEqual(@as(usize, 0), empty[0].table.rawLen());
    }
    const missing = try getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q9" }, .{ .string = "P1" } });
    defer rt.freeResults(missing);
    try std.testing.expectEqual(@as(usize, 0), missing[0].table.rawLen());
    try std.testing.expectError(error.LuaRaised, getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q10" }, .{ .string = "P1" } }));
    try std.testing.expectEqualStrings("Wikibase entity snapshot missing entity=Q10", runtime.last_error.string);
    try std.testing.expectError(error.AccessDenied, getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q7" }, .{ .string = "P1" } }));
    try std.testing.expectError(error.OutOfMemory, getBestStatementsCall(null, &runtime, &.{ .{ .string = "Q6" }, .{ .string = "P1" } }));
}

test "Wikibase entity term overlays leave exact language lookups and sitelinks independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
    var host = host_api.Host{ .wikibase_entity = Probe.entity, .wikibase_entity_terms = Probe.terms };
    host_api.set(&runtime, &host);
    const entity = try getEntityCall(null, &runtime, &.{.{ .string = "q1" }});
    defer rt.freeResults(entity);
    const labels = (try tableField(entity[0].table, "labels")).?;
    const overlay = (try tableField(labels, "en")).?;
    try std.testing.expectEqualStrings("bonjour", (try stringField(overlay, "value")).?);
    try std.testing.expectEqualStrings("fr", (try stringField(overlay, "language")).?);
    const descriptions = (try tableField(entity[0].table, "descriptions")).?;
    try std.testing.expectEqualStrings("de", (try stringField((try tableField(descriptions, "en")).?, "source-language")).?);
    inline for (.{ "labels", "descriptions", "sitelinks", "aliases" }) |key|
        try std.testing.expect((try tableField(entity[0].table, key)).?.read_only);
    const exact_missing = try getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "en" } });
    defer rt.freeResults(exact_missing);
    try std.testing.expect(exact_missing[0] == .nil);
    const exact = try getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "fr" } });
    defer rt.freeResults(exact);
    try std.testing.expectEqualStrings("bonjour", exact[0].string);
    const fallback = try getLabelWithLangCall(null, &runtime, &.{.{ .string = "Q1" }});
    defer rt.freeResults(fallback);
    try std.testing.expectEqual(@as(usize, 2), fallback.len);
    try std.testing.expectEqualStrings("bonjour", fallback[0].string);
    try std.testing.expectEqualStrings("fr", fallback[1].string);
    const description = try getDescriptionCall(null, &runtime, &.{.{ .string = "Q1" }});
    defer rt.freeResults(description);
    try std.testing.expectEqualStrings("Beschreibung", description[0].string);
    host.wikibase_entity_terms = null;
    const sitelink = try getSitelinkCall(null, &runtime, &.{.{ .string = "Q1" }});
    defer rt.freeResults(sitelink);
    try std.testing.expectEqualStrings("word", sitelink[0].string);
    const site = try getGlobalSiteIdCall(null, &runtime, &.{});
    defer rt.freeResults(site);
    try std.testing.expectEqualStrings("enwiktionary", site[0].string);
    try std.testing.expectError(error.NotImplemented, getEntityCall(null, &runtime, &.{.{ .string = "Q1" }}));
}

test "Wikibase captured absence unknown inputs and provider failures stay distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .wikibase_entity = Probe.entity, .wikibase_entity_terms = Probe.terms };
    host_api.set(&runtime, &host);
    const absent = try getEntityCall(null, &runtime, &.{.{ .string = "Q9" }});
    defer rt.freeResults(absent);
    try std.testing.expect(absent[0] == .nil);
    const no_terms = try getLabelWithLangCall(null, &runtime, &.{.{ .string = "Q9" }});
    defer rt.freeResults(no_terms);
    try std.testing.expect(no_terms.len == 2 and no_terms[0] == .nil and no_terms[1] == .nil);
    try std.testing.expectError(error.LuaRaised, getEntityCall(null, &runtime, &.{.{ .string = "Q10" }}));
    try std.testing.expectEqualStrings("Wikibase entity snapshot missing entity=Q10", runtime.last_error.string);
    try std.testing.expectError(error.LuaRaised, getLabelCall(null, &runtime, &.{.{ .string = "Q10" }}));
    try std.testing.expectEqualStrings("Wikibase entity-term snapshot missing entity=Q10", runtime.last_error.string);
    try std.testing.expectError(error.AccessDenied, getEntityCall(null, &runtime, &.{.{ .string = "Q7" }}));
    try std.testing.expectError(error.AccessDenied, getDescriptionCall(null, &runtime, &.{.{ .string = "Q7" }}));
    try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getEntityCall(null, &runtime, &.{.{ .string = "Q8" }}));
    try std.testing.expectError(error.NotImplemented, getEntityCall(null, &runtime, &.{}));
    try std.testing.expectError(error.InvalidEntityId, getEntityCall(null, &runtime, &.{.{ .string = "Q0" }}));
    try std.testing.expectEqualStrings("Q42", (try canonicalEntityId(&runtime, "q42")).?);
    try std.testing.expectEqualStrings("L12-F2", (try canonicalEntityId(&runtime, "L12-F2")).?);
    try std.testing.expect((try canonicalEntityId(&runtime, "L12-S0")) == null);

    host_api.set(&runtime, null);
    try std.testing.expectError(error.MissingScribuntoHost, getEntityCall(null, &runtime, &.{.{ .string = "L1" }}));
    try std.testing.expectError(error.MissingScribuntoHost, getLabelCall(null, &runtime, &.{.{ .string = "Q1" }}));
    host = .{};
    host_api.set(&runtime, &host);
    try std.testing.expectError(error.NotImplemented, getEntityCall(null, &runtime, &.{.{ .string = "L1" }}));
    try std.testing.expectError(error.NotImplemented, getLabelCall(null, &runtime, &.{.{ .string = "Q1" }}));
}

test "Wikibase native entity decode preserves allocation failure and recovers on a fresh read" {
    const AllocationProbe = struct {
        runtime: *rt.Context,
        allocator: std.mem.Allocator,
        calls: usize = 0,

        fn entity(raw: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            // ID normalization has already succeeded. Fail inside the fresh
            // JSON decode rather than in the native argument conversion.
            self.runtime.allocator = self.allocator;
            return Probe.entity(null, id);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const original = runtime.allocator;
    defer runtime.allocator = original;
    var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
    var probe = AllocationProbe{ .runtime = &runtime, .allocator = failing.allocator() };
    var host = host_api.Host{ .ctx = &probe, .wikibase_entity = AllocationProbe.entity };
    host_api.set(&runtime, &host);
    try std.testing.expectError(error.OutOfMemory, getEntityCall(null, &runtime, &.{.{ .string = "L1" }}));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(failing.has_induced_failure);

    runtime.allocator = original;
    host = .{ .wikibase_entity = Probe.entity };
    const recovered = try getEntityCall(null, &runtime, &.{.{ .string = "L1" }});
    defer rt.freeResults(recovered);
    const forms = (try tableField(recovered[0].table, "forms")).?;
    try std.testing.expectEqualStrings("L1-F1", (try stringField(forms.rawGet(.{ .number = 1 }).?.table, "id")).?);
}

const EntityObjectProbe = struct {
    const source =
        \\{"id":"L2","type":"lexeme","schemaVersion":2,"language":"Q13955","lexicalCategory":"Q24905",
        \\"lemmas":{"ar":{"language":"ar","value":"ثابت"}},
        \\"forms":[{"id":"L2-F1","representations":{"ar":{"language":"ar","value":"ثَابَتَ"}},"grammaticalFeatures":["Q1","Q2"],"claims":{}}],
        \\"senses":[{"id":"L2-S1","glosses":{"ar":{"language":"ar","value":"معنى"}},"claims":{"P1":[
        \\{"rank":"normal","mainsnak":{"snaktype":"value","datavalue":{"value":"original"}},
        \\"qualifiers":{"P2":[{"snaktype":"somevalue"}]},"references":[{"snaks":{"P3":[{"snaktype":"novalue"}]}}]}]}}]}
    ;
    const empty =
        \\{"id":"L3","type":"lexeme","schemaVersion":2,"language":"Q13955","lexicalCategory":"Q24905","lemmas":{"ar":{"language":"ar","value":"ثابت"}}}
    ;
    fn entity(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
        if (std.mem.eql(u8, id, "L2")) return .{ .source = source };
        if (std.mem.eql(u8, id, "L3")) return .{ .source = empty };
        if (std.mem.eql(u8, id, "Q1")) return .{ .source = Probe.item };
        if (std.mem.eql(u8, id, "Q9")) return .{ .source = null };
        return error.WikibaseEntitySnapshotMissing;
    }
    fn method(runtime: *rt.Context, object: Value, name: []const u8, tail: []const Value) ![]const Value {
        var args: [3]Value = undefined;
        if (tail.len > 2) return error.TooManyArguments;
        args[0] = object;
        @memcpy(args[1 .. tail.len + 1], tail);
        const callable = try runtime.getIndex(object, .{ .string = name });
        return runtime.callValue(callable, args[0 .. tail.len + 1]);
    }
};

test "Wikibase entity object methods preserve subentity identity and clone statement graphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .wikibase_entity = EntityObjectProbe.entity, .wikibase_entity_terms = Probe.terms };
    host_api.set(&runtime, &host);
    const loaded = try getEntityCall(null, &runtime, &.{.{ .string = "L2" }});
    defer rt.freeResults(loaded);
    const entity = loaded[0];
    const language = try EntityObjectProbe.method(&runtime, entity, "getLanguage", &.{});
    defer rt.freeResults(language);
    try std.testing.expectEqualStrings("Q13955", language[0].string);
    const id = try EntityObjectProbe.method(&runtime, entity, "getId", &.{});
    defer rt.freeResults(id);
    try std.testing.expectEqualStrings("L2", id[0].string);
    const category = try EntityObjectProbe.method(&runtime, entity, "getLexicalCategory", &.{});
    defer rt.freeResults(category);
    try std.testing.expectEqualStrings("Q24905", category[0].string);

    const senses = try EntityObjectProbe.method(&runtime, entity, "getSenses", &.{});
    defer rt.freeResults(senses);
    const again = try EntityObjectProbe.method(&runtime, entity, "getSenses", &.{});
    defer rt.freeResults(again);
    try std.testing.expect(senses[0].table != again[0].table);
    const sense = senses[0].table.rawGet(.{ .number = 1 }).?;
    try std.testing.expect(sense.table == again[0].table.rawGet(.{ .number = 1 }).?.table);
    try std.testing.expect(sense.table == (try tableField(entity.table, "senses")).?.rawGet(.{ .number = 1 }).?.table);
    const gloss = try EntityObjectProbe.method(&runtime, sense, "getGloss", &.{.{ .string = "ar" }});
    defer rt.freeResults(gloss);
    try std.testing.expectEqual(@as(usize, 2), gloss.len);
    try std.testing.expectEqualStrings("معنى", gloss[0].string);
    try std.testing.expectEqualStrings("ar", gloss[1].string);
    const absent = try EntityObjectProbe.method(&runtime, sense, "getGloss", &.{.{ .string = "en" }});
    defer rt.freeResults(absent);
    try std.testing.expect(absent.len == 1 and absent[0] == .nil);
    const glosses = try EntityObjectProbe.method(&runtime, sense, "getGlosses", &.{});
    defer rt.freeResults(glosses);
    const gloss_pair = glosses[0].table.rawGet(.{ .number = 1 }).?.table;
    try gloss_pair.rawSet(runtime.allocator, .{ .number = 1 }, .{ .string = "only this pair" });
    const fresh_gloss = try EntityObjectProbe.method(&runtime, sense, "getGloss", &.{.{ .string = "ar" }});
    defer rt.freeResults(fresh_gloss);
    try std.testing.expectEqualStrings("معنى", fresh_gloss[0].string);

    const statements = try EntityObjectProbe.method(&runtime, sense, "getAllStatements", &.{.{ .string = "P1" }});
    defer rt.freeResults(statements);
    const statement = statements[0].table.rawGet(.{ .number = 1 }).?.table;
    const value = (try tableField((try tableField(statement, "mainsnak")).?, "datavalue")).?;
    try value.rawSet(runtime.allocator, .{ .string = "value" }, .{ .string = "changed" });
    const references = (try tableField(statement, "references")).?;
    try std.testing.expect(references.read_only);
    const reference = references.rawGet(.{ .number = 1 }).?.table;
    try reference.rawSet(runtime.allocator, .{ .string = "changed" }, .{ .boolean = true });
    const next_statements = try EntityObjectProbe.method(&runtime, sense, "getAllStatements", &.{.{ .string = "P1" }});
    defer rt.freeResults(next_statements);
    const next_statement = next_statements[0].table.rawGet(.{ .number = 1 }).?.table;
    try std.testing.expect(next_statement != statement);
    try std.testing.expectEqualStrings("original", (try stringField((try tableField((try tableField(next_statement, "mainsnak")).?, "datavalue")).?, "value")).?);
    try std.testing.expect((try tableField(next_statement, "references")).?.rawGet(.{ .number = 1 }).?.table.rawGet(.{ .string = "changed" }) == null);
    // The method observes mutations to this entity, not a fresh provider read.
    const raw_statement = (try tableField((try tableField(sense.table, "claims")).?, "P1")).?.rawGet(.{ .number = 1 }).?.table;
    try (try tableField(raw_statement, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "somevalue" });
    const changed_source = try EntityObjectProbe.method(&runtime, sense, "getAllStatements", &.{.{ .string = "P1" }});
    defer rt.freeResults(changed_source);
    try std.testing.expectEqualStrings("somevalue", (try stringField((try tableField(changed_source[0].table.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?, "snaktype")).?);

    const global_sense = try getEntityCall(null, &runtime, &.{.{ .string = "L2-S1" }});
    defer rt.freeResults(global_sense);
    try std.testing.expect(global_sense[0].table != sense.table);
    const global_sense_id = try EntityObjectProbe.method(&runtime, global_sense[0], "getId", &.{});
    defer rt.freeResults(global_sense_id);
    try std.testing.expectEqualStrings("L2-S1", global_sense_id[0].string);
    const global_statements = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L2-S1" }, .{ .string = "P1" } });
    defer rt.freeResults(global_statements);
    try std.testing.expectEqualStrings("value", (try stringField((try tableField(global_statements[0].table.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?, "snaktype")).?);
    const absent_child = try getEntityCall(null, &runtime, &.{.{ .string = "L3-S1" }});
    defer rt.freeResults(absent_child);
    try std.testing.expect(absent_child[0] == .nil);

    const forms = try EntityObjectProbe.method(&runtime, entity, "getForms", &.{});
    defer rt.freeResults(forms);
    const form = forms[0].table.rawGet(.{ .number = 1 }).?;
    const representation = try EntityObjectProbe.method(&runtime, form, "getRepresentation", &.{.{ .string = "ar" }});
    defer rt.freeResults(representation);
    try std.testing.expectEqualStrings("ثَابَتَ", representation[0].string);
    try std.testing.expectEqualStrings("ar", representation[1].string);
    const features = try EntityObjectProbe.method(&runtime, form, "getGrammaticalFeatures", &.{});
    defer rt.freeResults(features);
    try std.testing.expect(features[0].table == (try tableField(form.table, "grammaticalFeatures")).?);

    const empty_entity = try getEntityCall(null, &runtime, &.{.{ .string = "L3" }});
    defer rt.freeResults(empty_entity);
    const no_senses = try EntityObjectProbe.method(&runtime, empty_entity[0], "getSenses", &.{});
    defer rt.freeResults(no_senses);
    try std.testing.expect(no_senses[0].table.rawGet(.{ .number = 1 }) == null);
    const missing = try getEntityCall(null, &runtime, &.{.{ .string = "Q9" }});
    defer rt.freeResults(missing);
    try std.testing.expect(missing[0] == .nil);
    try std.testing.expectError(error.LuaRaised, getEntityCall(null, &runtime, &.{.{ .string = "L999" }}));
}

const ProjectionProbe = struct {
    source: []const u8,
    parsed: ?*const std.json.Value = null,
    parsed_numbers_validated: bool = false,

    fn entity(raw: ?*anyopaque, _: []const u8) !host_api.WikibaseEntity {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return .{ .source = self.source, .parsed = self.parsed, .parsed_numbers_validated = self.parsed_numbers_validated };
    }

    fn scalar(runtime: *rt.Context, selector: []const u8, comptime sitelink: bool) ![]const Value {
        const args = [_]Value{ .{ .string = "Q1" }, .{ .string = selector } };
        return if (sitelink) getSitelinkCall(null, runtime, &args) else getLabelByLangCall(null, runtime, &args);
    }
};

test "Wikibase projections retain numeric key conversion and copied escaped scalar values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const fields =
        \\{"12":{"value":"numeric","title":"numeric"},
        \\"-12":{"value":"negative","title":"negative"},
        \\"012":{"value":"leading zero","title":"leading zero"},
        \\"-0":{"value":"negative zero","title":"negative zero"},
        \\"9223372036854775808":{"value":"outside i64","title":"outside i64"},
        \\"en":{"value":"caf\u00e9","title":"caf\u00e9"},
        \\"missing":null,"array":[],"null":{"value":null,"title":null},
        \\"scalar":7,"bad":{"value":7,"title":7}}
    ;
    // The native read contract accepts a numeric version >=2 and a string ID;
    // it does not impose the production Provider's stricter exact-version rule.
    const source = "{\"id\":\"\",\"schemaVersion\":2.5,\"labels\":" ++ fields ++ ",\"sitelinks\":" ++ fields ++ "}";
    var probe = ProjectionProbe{ .source = source };
    var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity };
    host_api.set(&runtime, &host);
    inline for (.{ false, true }) |sitelink| {
        for ([_][]const u8{ "12", "-12", "missing", "array", "null", "absent" }) |key| {
            const result = try ProjectionProbe.scalar(&runtime, key, sitelink);
            defer rt.freeResults(result);
            try std.testing.expect(result[0] == .nil);
        }
        const cases = .{
            .{ "012", "leading zero" },
            .{ "-0", "negative zero" },
            .{ "9223372036854775808", "outside i64" },
            .{ "en", "café" },
        };
        inline for (cases) |case| {
            const result = try ProjectionProbe.scalar(&runtime, case[0], sitelink);
            defer rt.freeResults(result);
            // The parse lease has already been destroyed when the call returns.
            try std.testing.expectEqualStrings(case[1], result[0].string);
        }
        inline for (.{ "scalar", "bad" }) |key|
            try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, ProjectionProbe.scalar(&runtime, key, sitelink));
    }
}

test "Wikibase projections preserve null array and scalar intermediate fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var probe = ProjectionProbe{ .source = undefined };
    var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity };
    host_api.set(&runtime, &host);
    inline for (.{ "null", "[]", "{}" }) |value| {
        probe.source = "{\"id\":\"Q1\",\"schemaVersion\":2,\"labels\":" ++ value ++ ",\"sitelinks\":" ++ value ++ ",\"claims\":" ++ value ++ "}";
        inline for (.{ false, true }) |sitelink| {
            const result = try ProjectionProbe.scalar(&runtime, "en", sitelink);
            defer rt.freeResults(result);
            try std.testing.expect(result[0] == .nil);
        }
        const statements = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
        defer rt.freeResults(statements);
        try std.testing.expectEqual(@as(usize, 0), statements[0].table.rawLen());
    }
    probe.source = "{\"id\":\"Q1\",\"schemaVersion\":2,\"labels\":false,\"sitelinks\":3,\"claims\":\"bad\"}";
    inline for (.{ false, true }) |sitelink|
        try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, ProjectionProbe.scalar(&runtime, "en", sitelink));
    try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } }));

    // Runtime table lookup also accepts object-shaped statement collections.
    // Production capture validation is a separate, stricter boundary.
    probe.source = "{\"id\":\"Q1\",\"schemaVersion\":2,\"claims\":{\"P1\":{\"1\":{\"rank\":\"normal\"}},\"P2\":null,\"P3\":7}}";
    const object_statements = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
    defer rt.freeResults(object_statements);
    try std.testing.expectEqualStrings("normal", (try stringField(object_statements[0].table.rawGet(.{ .number = 1 }).?.table, "rank")).?);
    const null_statements = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P2" } });
    defer rt.freeResults(null_statements);
    try std.testing.expectEqual(@as(usize, 0), null_statements[0].table.rawLen());
    try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P3" } }));
}

test "Wikibase projections reject invalid numbers outside the selected subtree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var probe = ProjectionProbe{ .source = undefined };
    var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity };
    host_api.set(&runtime, &host);
    const invalid_sources = .{
        "{\"id\":\"Q1\",\"schemaVersion\":2,\"unrelated\":[{\"number\":1e9999}]}",
        "{\"id\":\"Q1\",\"schemaVersion\":2,\"unrelated\":-1e9999}",
        "{\"id\":\"Q1\",\"schemaVersion\":\"2\"}",
        "{\"id\":null,\"schemaVersion\":2}",
        "{\"id\":\"Q1\",\"schemaVersion\":1.9}",
        "[]",
        "{",
    };
    inline for (invalid_sources) |source| {
        probe.source = source;
        try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, readEntity(&runtime, "Q1"));
        inline for (.{ false, true }) |sitelink|
            try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, ProjectionProbe.scalar(&runtime, "en", sitelink));
        try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } }));
    }
}

test "Wikibase projections propagate allocation failure after ID validation and recover" {
    const AllocationProbe = struct {
        runtime: *rt.Context,
        allocator: std.mem.Allocator,

        fn entity(raw: ?*anyopaque, _: []const u8) !host_api.WikibaseEntity {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.runtime.allocator = self.allocator;
            return .{ .source = Probe.item };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const original = runtime.allocator;
    defer runtime.allocator = original;
    inline for (0..3) |operation| {
        runtime.allocator = original;
        var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
        var probe = AllocationProbe{ .runtime = &runtime, .allocator = failing.allocator() };
        var host = host_api.Host{ .ctx = &probe, .wikibase_entity = AllocationProbe.entity };
        host_api.set(&runtime, &host);
        // The host switches allocators only after entity/property IDs have
        // been validated. The failure is inside the ordinary projection read.
        switch (operation) {
            0 => try std.testing.expectError(error.OutOfMemory, getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "fr" } })),
            1 => try std.testing.expectError(error.OutOfMemory, getSitelinkCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "enwiktionary" } })),
            2 => try std.testing.expectError(error.OutOfMemory, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } })),
            else => unreachable,
        }
        try std.testing.expect(failing.has_induced_failure);
        runtime.allocator = original;
    }
    var host = host_api.Host{ .wikibase_entity = Probe.entity };
    host_api.set(&runtime, &host);
    const recovered = try getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "fr" } });
    defer rt.freeResults(recovered);
    try std.testing.expectEqualStrings("bonjour", recovered[0].string);
}

test "Wikibase projected globals preserve redirected parent and captured missing child semantics" {
    const ChildProbe = struct {
        const source =
            \\{"id":"L2","type":"lexeme","schemaVersion":2,"senses":[
            \\{"id":"L2-S1","claims":{"P1":[{"rank":"normal","mainsnak":{"snaktype":"value"}}]},
            \\"labels":{"en":{"value":"child label"}},"sitelinks":{"en":{"title":"child link"}}},
            \\{"id":"L2-S2","claims":{"P1":[{"rank":"normal"}]}}],
            \\"forms":[{"id":"L2-F1","claims":{"P1":[{"rank":"normal"}]}}]}
        ;
        fn entity(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
            if (std.mem.eql(u8, id, "L4") or std.mem.eql(u8, id, "L2")) return .{ .source = source };
            if (std.mem.eql(u8, id, "L4-S2") or std.mem.eql(u8, id, "L9")) return .{ .source = null };
            return error.WikibaseEntitySnapshotMissing;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var host = host_api.Host{ .wikibase_entity = ChildProbe.entity };
    host_api.set(&runtime, &host);
    const first = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L4-S1" }, .{ .string = "P1" } });
    defer rt.freeResults(first);
    try (try tableField(first[0].table.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "changed" });
    const again = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L4-S1" }, .{ .string = "P1" } });
    defer rt.freeResults(again);
    try std.testing.expectEqualStrings("value", (try stringField((try tableField(again[0].table.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?, "snaktype")).?);
    const label = try getLabelByLangCall(null, &runtime, &.{ .{ .string = "L4-S1" }, .{ .string = "en" } });
    defer rt.freeResults(label);
    try std.testing.expectEqualStrings("child label", label[0].string);
    const sitelink = try getSitelinkCall(null, &runtime, &.{ .{ .string = "L4-S1" }, .{ .string = "en" } });
    defer rt.freeResults(sitelink);
    try std.testing.expectEqualStrings("child link", sitelink[0].string);
    const form = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "L4-F1" }, .{ .string = "P1" } });
    defer rt.freeResults(form);
    try std.testing.expectEqual(@as(usize, 1), form[0].table.rawLen());
    for ([_][]const u8{ "L4-S2", "L4-S3", "L9-S1" }) |id| {
        const missing = try getAllStatementsCall(null, &runtime, &.{ .{ .string = id }, .{ .string = "P1" } });
        defer rt.freeResults(missing);
        try std.testing.expectEqual(@as(usize, 0), missing[0].table.rawLen());
    }
    try std.testing.expectError(error.LuaRaised, getAllStatementsCall(null, &runtime, &.{ .{ .string = "L999-S1" }, .{ .string = "P1" } }));
    try std.testing.expectEqualStrings("Wikibase entity snapshot missing entity=L999", runtime.last_error.string);
}

test "Wikibase cached JSON remains immutable across fresh mutable entities and page teardown" {
    const Cache = @import("wikibase_entity_cache.zig").Cache;
    const source =
        \\{"id":"Q1","type":"item","schemaVersion":2,
        \\"labels":{"fr":{"language":"fr","value":"bonjour"}},
        \\"sitelinks":{"enwiktionary":{"site":"enwiktionary","title":"word"}},
        \\"claims":{"P1":[{"rank":"normal","mainsnak":{"snaktype":"value"},
        \\"qualifiers":{"P2":[{"snaktype":"somevalue"}]},"references":[{"snaks":{}}]}]}}
    ;
    const cache = try Cache.create(std.testing.allocator, Cache.max_bytes, Cache.max_entries);
    defer cache.destroy();
    const backing = cache.lookupOrAdmit(source).?;
    var probe = ProjectionProbe{ .source = source, .parsed = backing, .parsed_numbers_validated = true };
    for (0..2) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var runtime = try rt.Context.init(arena.allocator(), 0);
        defer runtime.deinit();
        runtime.namespace_catalog = try rt.namespace_registry.englishTestRegistry();
        var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity, .wikibase_entity_terms = Probe.terms };
        host_api.set(&runtime, &host);
        const first = try getEntityCall(null, &runtime, &.{.{ .string = "Q1" }});
        defer rt.freeResults(first);
        const labels = (try tableField(first[0].table, "labels")).?;
        const label = (try tableField(labels, "fr")).?;
        try std.testing.expectEqualStrings("bonjour", (try stringField(label, "value")).?);
        try label.rawSet(runtime.allocator, .{ .string = "value" }, .{ .string = "changed entity" });
        const claims = (try tableField(first[0].table, "claims")).?;
        const statement = (try tableField(claims, "P1")).?.rawGet(.{ .number = 1 }).?.table;
        try (try tableField(statement, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "changed entity" });
        const all = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
        defer rt.freeResults(all);
        const projected = all[0].table.rawGet(.{ .number = 1 }).?.table;
        try std.testing.expectEqualStrings("value", (try stringField((try tableField(projected, "mainsnak")).?, "snaktype")).?);
        try std.testing.expect((try tableField(projected, "qualifiers")).?.read_only);
        try std.testing.expect((try tableField(projected, "references")).?.read_only);
        try (try tableField(projected, "mainsnak")).?.rawSet(runtime.allocator, .{ .string = "snaktype" }, .{ .string = "changed result" });
        const next = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } });
        defer rt.freeResults(next);
        try std.testing.expectEqualStrings("value", (try stringField((try tableField(next[0].table.rawGet(.{ .number = 1 }).?.table, "mainsnak")).?, "snaktype")).?);
        const exact = try getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "fr" } });
        defer rt.freeResults(exact);
        try std.testing.expectEqualStrings("bonjour", exact[0].string);
        const site = try getSitelinkCall(null, &runtime, &.{.{ .string = "Q1" }});
        defer rt.freeResults(site);
        try std.testing.expectEqualStrings("word", site[0].string);
        try std.testing.expect(cache.lookupOrAdmit(source).? == backing);
    }
    try std.testing.expectEqualStrings("bonjour", backing.object.get("labels").?.object.get("fr").?.object.get("value").?.string);
    try std.testing.expect(backing.object.get("labels").?.object.get("en") == null);
}

test "Wikibase borrowed JSON preserves schema nonfinite and captured absence boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const invalid_sources = .{
        "{\"id\":\"Q1\",\"schemaVersion\":2,\"unrelated\":1e9999}",
        "{\"id\":\"Q1\",\"schemaVersion\":\"2\"}",
        "{\"id\":null,\"schemaVersion\":2}",
        "{\"id\":\"Q1\",\"schemaVersion\":1.9}",
        "[]",
    };
    inline for (invalid_sources) |source| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
        defer parsed.deinit();
        var probe = ProjectionProbe{ .source = source, .parsed = &parsed.value };
        var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity };
        host_api.set(&runtime, &host);
        try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getEntityCall(null, &runtime, &.{.{ .string = "Q1" }}));
        try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } }));
        inline for (.{ false, true }) |sitelink|
            try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, ProjectionProbe.scalar(&runtime, "en", sitelink));
    }
    const Missing = struct {
        fn entity(_: ?*anyopaque, id: []const u8) !host_api.WikibaseEntity {
            if (std.mem.eql(u8, id, "Q9")) return .{ .source = null };
            return error.WikibaseEntitySnapshotMissing;
        }
    };
    var missing_host = host_api.Host{ .wikibase_entity = Missing.entity };
    host_api.set(&runtime, &missing_host);
    const absent = try getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q9" }, .{ .string = "P1" } });
    defer rt.freeResults(absent);
    try std.testing.expectEqual(@as(usize, 0), absent[0].table.rawLen());
    try std.testing.expectError(error.LuaRaised, getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q10" }, .{ .string = "en" } }));
    try std.testing.expectEqualStrings("Wikibase entity snapshot missing entity=Q10", runtime.last_error.string);
}

test "Wikibase borrowed JSON does not suppress page conversion allocation failure" {
    const AllocationProbe = struct {
        runtime: *rt.Context,
        allocator: std.mem.Allocator,
        parsed: *const std.json.Value,
        fn entity(raw: ?*anyopaque, _: []const u8) !host_api.WikibaseEntity {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.runtime.allocator = self.allocator;
            return .{ .source = Probe.item, .parsed = self.parsed };
        }
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, Probe.item, .{});
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    runtime.useContextAllocatorForStrings();
    const original = runtime.allocator;
    defer runtime.allocator = original;
    inline for (0..4) |operation| {
        runtime.allocator = original;
        var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
        var probe = AllocationProbe{ .runtime = &runtime, .allocator = failing.allocator(), .parsed = &parsed.value };
        var host = host_api.Host{ .ctx = &probe, .wikibase_entity = AllocationProbe.entity };
        host_api.set(&runtime, &host);
        switch (operation) {
            0 => try std.testing.expectError(error.OutOfMemory, getEntityCall(null, &runtime, &.{.{ .string = "Q1" }})),
            1 => try std.testing.expectError(error.OutOfMemory, getLabelByLangCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "fr" } })),
            2 => try std.testing.expectError(error.OutOfMemory, getSitelinkCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "enwiktionary" } })),
            3 => try std.testing.expectError(error.OutOfMemory, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } })),
            else => unreachable,
        }
        try std.testing.expect(failing.has_induced_failure);
        runtime.allocator = original;
    }
}

test "Wikibase finite-number attestation does not bypass raw-source validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    var probe = ProjectionProbe{
        .source = "{\"id\":\"Q1\",\"schemaVersion\":2,\"unused\":[{\"n\":1e9999}]}",
        .parsed_numbers_validated = true,
    };
    var host = host_api.Host{ .ctx = &probe, .wikibase_entity = ProjectionProbe.entity };
    host_api.set(&runtime, &host);
    try std.testing.expectError(error.InvalidWikibaseEntitySnapshot, getAllStatementsCall(null, &runtime, &.{ .{ .string = "Q1" }, .{ .string = "P1" } }));
}
