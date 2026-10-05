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

fn readEntity(runtime: *rt.Context, id: []const u8) !?*rt.Table {
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
    // flags=0 preserves Lua's one-based arrays. Each call owns a fresh graph;
    // mutations of returned lemmas, forms or statements cannot poison capture.
    const decoded = text.jsonDecodeValue(runtime, source, 0) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidWikibaseEntitySnapshot,
    };
    if (decoded != .table) return error.InvalidWikibaseEntitySnapshot;
    const version = field(decoded.table, "schemaVersion") orelse return error.InvalidWikibaseEntitySnapshot;
    if (version != .number or version.number < 2) return error.InvalidWikibaseEntitySnapshot;
    _ = (try stringField(decoded.table, "id")) orelse return error.InvalidWikibaseEntitySnapshot;
    return decoded.table;
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

pub fn getEntityCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    const entity = (try readEntity(runtime, id)) orelse return one(.nil);
    const kind = (try stringField(entity, "type")) orelse return error.InvalidWikibaseEntitySnapshot;
    try overlayEntityTerms(runtime, id, entity, kind);
    try protectEntity(entity);
    if (std.mem.eql(u8, kind, "lexeme")) {
        const methods = try runtime.newTable();
        try methods.rawSet(runtime.allocator, .{ .string = "getLemmas" }, try runtime.newNative(null, getLemmasCall));
        const metatable = try runtime.newTable();
        try metatable.rawSet(runtime.allocator, .{ .string = "__index" }, .{ .table = methods });
        entity.metatable = metatable;
    }
    return one(.{ .table = entity });
}

pub fn getAllStatementsCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
    const property = (try canonicalEntityId(runtime, args[1].string)) orelse return error.InvalidPropertyId;
    if (property[0] != 'P') return error.InvalidPropertyId;
    const entity = try readEntity(runtime, id);
    if (entity) |value| if (try tableField(value, "claims")) |claims|
        if (try tableField(claims, property)) |statements| {
            try protectStatements(statements);
            return one(.{ .table = statements });
        };
    return one(.{ .table = try runtime.newTable() });
}

pub fn getLabelByLangCall(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const id = try entityId(runtime, args);
    if (args.len < 2 or args[1] != .string) return error.StringExpected;
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
