const std = @import("std");
const A = std.mem.Allocator;
const namespaces = @import("namespace_registry");
const language = @import("page_language.zig");
const table_direction = @import("figure_page_observations.zig");
const invalid = error.InvalidPageLanguageSource;
const NormalContext = language.NormalContext;
// Writer-only eager source projection. Capsules remain owned by metadata until
// every projected parent has been released; no mmap or local Registry pointer
// is retained by a published source-parent capability.
pub const Registry = struct {
    const DirectEntry = struct { capsule: *const language.SourceParentCapsule, parent: ?*const table_direction.SourceParentTextPage };
    metadata: language.Registry,
    backing: A,
    projection: ?*std.heap.ArenaAllocator = null,
    core_revision: ?[]const u8,
    entries: @TypeOf(@as(language.Registry, undefined).entries),
    direct_entries: []const DirectEntry = &.{},

    pub fn init(backing: A, packet: ?[]const u8, responses: ?[]const u8, prefix: ?[]const u8, ns: *const namespaces.Registry) !Registry {
        return materialize(backing, try language.Registry.init(backing, packet, responses, prefix, ns), ns);
    }
    // Consumes metadata on success and failure. The heap-stable arena avoids
    // handing Profile a backing allocator tied to a movable return object.
    fn materialize(backing: A, value: language.Registry, ns: *const namespaces.Registry) !Registry {
        var metadata = value;
        errdefer metadata.deinit();
        if (metadata.direct_entries.len == 0) return .{ .metadata = metadata, .backing = backing,
            .core_revision = metadata.core_revision, .entries = metadata.entries };
        const projection = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(projection);
        projection.* = std.heap.ArenaAllocator.init(backing);
        errdefer projection.deinit();
        const a = projection.allocator();
        const entries = try a.alloc(DirectEntry, metadata.direct_entries.len);
        for (metadata.direct_entries, entries) |entry, *destination| {
            const capsule = entry.capsule;
            // A language-only capsule does not claim any served stylesheet or parent CSS.
            const parent = if (capsule.styles.responses.len == 0 and capsule.styles.receipt.len == 0) null else
                table_direction.sourceParentTextPageAlloc(a, ns, capsule.prefix, capsule.response,
                @intCast(capsule.response.len), &capsule.response_sha256, capsule.page.id, capsule.page.revision,
                capsule.document_url, .{ .responses = capsule.styles.responses, .receipt = capsule.styles.receipt }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory, else => return invalid,
                };
            if (parent) |selected| if (selected.body_skin_responsive != capsule.body_skin_responsive) return invalid;
            destination.* = .{ .capsule = capsule, .parent = parent };
        }
        return .{ .metadata = metadata, .backing = backing, .projection = projection,
            .core_revision = metadata.core_revision, .entries = metadata.entries, .direct_entries = entries };
    }
    pub fn deinit(self: *Registry) void {
        if (self.projection) |projection| { projection.deinit(); self.backing.destroy(projection); }
        self.metadata.deinit();
        self.* = undefined;
    }
    pub fn lookup(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8, raw: []const u8, normal: NormalContext) ?language.Context {
        return self.metadata.lookup(page_id, revision_id, ns, title, raw, normal);
    }
    pub fn capturedSourceMatches(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8, raw: []const u8, expanded: []const u8) bool {
        return self.metadata.capturedSourceMatches(page_id, revision_id, ns, title, raw, expanded);
    }
    // Same direct-record identity checks, without converting a rendered root
    // observation into API page-language metadata or requiring served CSS.
    // Existing style-bearing parent records keep their original consumer path.
    pub fn lookupSourceRootLanguage(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8,
        raw: []const u8, expanded: []const u8, normal: NormalContext) ?*const language.SourceParentCapsule
    {
        const capsule = self.metadata.lookupSourceCapsule(page_id, revision_id, ns, title, raw, expanded, normal) orelse return null;
        if (capsule.styles.responses.len != 0 or capsule.styles.receipt.len != 0) return null;
        return capsule;
    }
    pub fn lookupSourceParent(self: *const Registry, page_id: u64, revision_id: u64, ns: i32, title: []const u8,
        raw: []const u8, expanded: []const u8, normal: NormalContext) ?*const table_direction.SourceParentTextPage
    {
        const capsule = self.metadata.lookupSourceCapsule(page_id, revision_id, ns, title, raw, expanded, normal) orelse return null;
        var low: usize = 0; var high = self.direct_entries.len;
        while (low < high) { const mid = low + (high - low) / 2;
            if (self.direct_entries[mid].capsule.page.id < page_id) low = mid + 1 else high = mid; }
        if (low == self.direct_entries.len or self.direct_entries[low].capsule != capsule) return null;
        return self.direct_entries[low].parent;
    }
};
const DirectGetFixture = language.SourceTesting;
const parseLimited = language.SourceTesting.parse_limited;
const parse = language.SourceTesting.parse_value;
const str = language.SourceTesting.string_field;
const digest = language.SourceTesting.digest_bytes;
const matches = language.SourceTesting.matches_digest;
const directGetTransport = language.SourceTesting.transport;
const DirectGetContext = language.DirectGetContext;
const accepted_core = language.accepted_core;
const max_index_bytes = language.max_index_bytes;

test "retained HU direct GET contexts bind exact raw expansion and owned source without API metadata" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    const scratch = try a.dupe(u8, DirectGetFixture.packet);
    var registry = Registry.init(a, scratch, "", null, &ns) catch |err| { a.free(scratch); return err; };
    defer registry.deinit();
    a.free(scratch);
    try std.testing.expect(registry.core_revision == null and registry.entries.len == 0);
    try std.testing.expectEqual(@as(usize, 3), registry.direct_entries.len);
    inline for (DirectGetFixture.pages) |page| {
        try std.testing.expect(registry.lookup(page[0], page[1], 0, page[2], page[3], DirectGetFixture.normal) == null);
        const parent = registry.lookupSourceParent(page[0], page[1], 0, page[2], page[3], page[4], DirectGetFixture.normal) orelse return error.TestUnexpectedResult;
        try std.testing.expect(parent.html.len > 0 and parent.styles.reading_target == .screen);
        try std.testing.expectEqual(@as(?bool, true), parent.body_skin_responsive);
        var temporary = std.heap.ArenaAllocator.init(a); defer temporary.deinit();
        const bound = try table_direction.bindSourceParentTextAlloc(temporary.allocator(), parent, page[4], null);
        try std.testing.expect(bound.source.ptr == page[4].ptr and bound.source.len == page[4].len);
        try std.testing.expect(bound.observe_parent != null and bound.parent_context != null);
        try std.testing.expectEqual(@as(?bool, true), bound.source_parent_responsive);
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1] + 1, 0, page[2], page[3], page[4], DirectGetFixture.normal) == null);
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 1, page[2], page[3], page[4], DirectGetFixture.normal) == null);
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, "different title", page[3], page[4], DirectGetFixture.normal) == null);
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, page[2], "different raw", page[4], DirectGetFixture.normal) == null);
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, page[2], page[3], "different expansion", DirectGetFixture.normal) == null);
        var wrong = DirectGetFixture.normal; wrong.normal_no_target = false;
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, page[2], page[3], page[4], wrong) == null);
        wrong = DirectGetFixture.normal; wrong.interface_message = true;
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, page[2], page[3], page[4], wrong) == null);
        wrong = DirectGetFixture.normal; wrong.target_language_override = "hu";
        try std.testing.expect(registry.lookupSourceParent(page[0], page[1], 0, page[2], page[3], page[4], wrong) == null);
    }
}


test "retained HU direct GET evidence rejects identity receipt gzip style and neutral envelope substitutions" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    for (0..12) |which| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var packet = try parseLimited(t, DirectGetFixture.packet, max_index_bytes);
        const contexts = packet.object.getPtr("direct_get_contexts").?;
        const first = &contexts.array.items[0];
        switch (which) {
            0 => try packet.object.put(t, "core_revision", .{ .string = accepted_core }),
            1 => try packet.object.put(t, "source_profile", .{ .string = "invented API profile" }),
            2 => try contexts.array.append(first.*),
            3 => try first.object.getPtr("page").?.object.put(t, "id", .{ .integer = 1154 }),
            4 => try first.object.getPtr("page").?.object.put(t, "revision", .{ .integer = 3369676 }),
            5 => try first.object.getPtr("page").?.object.put(t, "title", .{ .string = "different" }),
            6 => try first.object.put(t, "response", .{ .string = "changed complete HTML" }),
            7 => try first.object.put(t, "mode", .{ .string = "current-canonical" }),
            8 => {
                const receipt = try parse(t, try str(first.*, "receipt"));
                try receipt.object.getPtr("sources").?.array.items[0].object.put(t, "sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" });
                try first.object.put(t, "receipt", .{ .string = try std.json.Stringify.valueAlloc(t, receipt, .{}) });
            },
            9 => try contexts.array.items[1].object.put(t, "encoded_gzip_base64", .{ .string = "AAAA" }),
            10 => {
                const saved = &contexts.array.items[1];
                var receipt = try parse(t, try str(saved.*, "receipt"));
                try receipt.object.put(t, "accepted", .{ .bool = true });
                try saved.object.put(t, "receipt", .{ .string = try std.json.Stringify.valueAlloc(t, receipt, .{}) });
            },
            11 => first.object.getPtr("styles").?.object.getPtr("responses").?.array.items[0].string = "changed stylesheet",
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(t, packet, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed, "", null, &ns));
    }
    try std.testing.expectError(invalid, Registry.init(a, DirectGetFixture.packet, "unclaimed API bytes", null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, DirectGetFixture.packet, "", "unclaimed prefix bytes", &ns));
}


test "direct GET transport requires exact current and saved receipt members" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    const current_fields = [_][]const u8{ "accept_encoding", "content_encoding", "encoded", "user_agent" };
    const saved_fields = [_][]const u8{ "error", "detail", "input_data", "started_utc", "ended_utc", "elapsed_seconds", "started_unix", "same_response_core_observed", "socket_buffering_measured" };
    inline for (.{ current_fields[0..], saved_fields[0..] }, 0..) |fields, kind| {
        for (fields) |name| for (0..2) |mutation| {
            var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
            const packet = try parseLimited(t, DirectGetFixture.packet, max_index_bytes);
            const record = &packet.object.getPtr("direct_get_contexts").?.array.items[if (kind == 0) 2 else 1];
            var receipt = try parse(t, try str(record.*, "receipt"));
            const subject = if (kind == 0) &receipt.object.getPtr("sources").?.array.items[0] else &receipt;
            if (mutation == 0) {
                const old = subject.object.fetchSwapRemove(name) orelse return error.TestUnexpectedResult;
                try subject.object.put(t, "unknown_replacement", old.value);
            } else try subject.object.put(t, name, .null);
            try record.object.put(t, "receipt", .{ .string = try std.json.Stringify.valueAlloc(t, receipt, .{}) });
            const bytes = try std.json.Stringify.valueAlloc(t, record.*, .{});
            const typed = try std.json.parseFromSlice(DirectGetContext, t, bytes, .{ .allocate = .alloc_always });
            try std.testing.expectError(invalid, directGetTransport(t, &ns, typed.value));
        };
    }
}


test "historical URL direct context requires retained current revision identity with held parser" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    const packet = try parseLimited(t, DirectGetFixture.packet, max_index_bytes);
    const record = &packet.object.getPtr("direct_get_contexts").?.array.items[0];
    const original = try std.json.parseFromSlice(DirectGetContext, t, try std.json.Stringify.valueAlloc(t, record.*, .{}), .{ .allocate = .alloc_always });
    _ = try directGetTransport(t, &ns, original.value);
    const marker = "\"wgCurRevisionId\":3369675";
    const response = try str(record.*, "response");
    const prefix = try str(record.*, "prefix");
    try std.testing.expect(std.mem.count(u8, response, marker) == 1 and std.mem.count(u8, prefix, marker) == 1);
    const changed_response = try std.mem.replaceOwned(u8, t, response, marker, "\"wgCurRevisionId\":3369676");
    const changed_prefix = try std.mem.replaceOwned(u8, t, prefix, marker, "\"wgCurRevisionId\":3369676");
    try record.object.put(t, "response", .{ .string = changed_response });
    try record.object.put(t, "prefix", .{ .string = changed_prefix });
    var receipt = try parse(t, try str(record.*, "receipt"));
    const source = &receipt.object.getPtr("sources").?.array.items[0];
    try source.object.put(t, "bytes", .{ .integer = @intCast(changed_response.len) });
    // digest already returns64 lowercase hexadecimal bytes; do not hex them again.
    try source.object.put(t, "sha256", .{ .string = try t.dupe(u8, &digest(changed_response)) });
    try std.testing.expectEqual(@as(usize, 64), (try str(source.*, "sha256")).len);
    try std.testing.expect(matches(changed_response, try str(source.*, "sha256")));
    try record.object.put(t, "receipt", .{ .string = try std.json.Stringify.valueAlloc(t, receipt, .{}) });
    const changed = try std.json.parseFromSlice(DirectGetContext, t, try std.json.Stringify.valueAlloc(t, record.*, .{}), .{ .allocate = .alloc_always });
    try std.testing.expectError(error.InvalidPageLanguagePrefix, directGetTransport(t, &ns, changed.value));
}

test "writer source projection rejects a malformed unused direct record before any page lookup" {
    const a = std.testing.allocator;
    var temporary = std.heap.ArenaAllocator.init(a); defer temporary.deinit(); const t = temporary.allocator();
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    var packet = try parseLimited(t, DirectGetFixture.packet, max_index_bytes);
    const last = &packet.object.getPtr("direct_get_contexts").?.array.items[2];
    last.object.getPtr("styles").?.object.getPtr("responses").?.array.items[0].string = "changed unused stylesheet";
    const bytes = try std.json.Stringify.valueAlloc(t, packet, .{});
    // A capsule carries no CSS projection authority. Writer init must validate
    // every record eagerly, even when no lookup for this third page occurs.
    var metadata = try language.Registry.init(a, bytes, "", null, &ns); defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 3), metadata.direct_entries.len);
    try std.testing.expectError(invalid, Registry.init(a, bytes, "", null, &ns));
}
test "writer source projection propagates initial allocation failure and consumes capsule backing exactly once" {
    const a = std.testing.allocator;
    var ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer ns.deinit();
    const metadata = try language.Registry.init(a, DirectGetFixture.packet, "", null, &ns);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Registry.materialize(failing.allocator(), metadata, &ns));
}


const FrSourceRootLanguageControl = struct {
    const normal: NormalContext = .{ .normal_no_target = true, .interface_message = false };
    fn packet(a: A) ![]const u8 { return a.dupe(u8, @embedFile("testdata/fr-source-root-language01/page-language.json")); }
    fn raw(a: A) ![]const u8 { return a.dupe(u8, @embedFile("testdata/fr-source-root-language01/raw.wikitext")); }
    fn expanded(a: A) ![]const u8 { return a.dupe(u8, @embedFile("testdata/fr-source-root-language01/expanded.wikitext")); }
};

test "direct GET root language retains genuine FR source identity without API language or parent CSS" {
    const a = std.testing.allocator;
    const F = FrSourceRootLanguageControl;
    var ns = try namespaces.Registry.init(a, namespaces.french_test_fixture); defer ns.deinit();
    const raw_bytes = try F.raw(a); defer a.free(raw_bytes);
    const expanded_bytes = try F.expanded(a); defer a.free(expanded_bytes);
    const packet_bytes = try F.packet(a);
    var registry = Registry.init(a, packet_bytes, "", null, &ns) catch |err| { a.free(packet_bytes); return err; };
    defer registry.deinit();
    a.free(packet_bytes);
    try std.testing.expect(registry.core_revision == null and registry.entries.len == 0);
    try std.testing.expectEqual(@as(usize, 1), registry.direct_entries.len);
    try std.testing.expect(registry.direct_entries[0].parent == null);
    try std.testing.expect(registry.lookup(1500057, 39726739, 0, "kobliha", raw_bytes, F.normal) == null);
    try std.testing.expect(!registry.capturedSourceMatches(1500057, 39726739, 0, "kobliha", raw_bytes, expanded_bytes));
    try std.testing.expect(registry.lookupSourceParent(1500057, 39726739, 0, "kobliha", raw_bytes, expanded_bytes, F.normal) == null);
    const root = registry.lookupSourceRootLanguage(1500057, 39726739, 0, "kobliha", raw_bytes, expanded_bytes, F.normal) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fr", root.root_language);
    try std.testing.expectEqualSlices(u8, &ns.source_sha256, &root.namespace_sha256);
    try std.testing.expectEqual(@as(usize, 75417), root.response.len);
    try std.testing.expect(matches(root.response, "756047a0b48e44d272a26a20b8531607eab00b27ff6f35960bfd6b3ff554e96d"));
    try std.testing.expectEqual(@as(usize, 42694), root.prefix.len);
    try std.testing.expect(std.mem.startsWith(u8, root.response, root.prefix));
    try std.testing.expect(root.styles.responses.len == 0 and root.styles.receipt.len == 0);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500058, 39726739, 0, "kobliha", raw_bytes, expanded_bytes, F.normal) == null);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726740, 0, "kobliha", raw_bytes, expanded_bytes, F.normal) == null);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726739, 1, "kobliha", raw_bytes, expanded_bytes, F.normal) == null);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726739, 0, "違う", raw_bytes, expanded_bytes, F.normal) == null);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726739, 0, "kobliha", "changed raw", expanded_bytes, F.normal) == null);
    try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726739, 0, "kobliha", raw_bytes, "changed expansion", F.normal) == null);
    for (0..5) |which| {
        var wrong = F.normal;
        switch (which) {
            0 => wrong.normal_no_target = false,
            1 => wrong.interface_message = true,
            2 => wrong.interface_message = null,
            3 => wrong.target_language_override = "fr",
            4 => wrong.variant_override = "fr",
            else => unreachable,
        }
        try std.testing.expect(registry.lookupSourceRootLanguage(1500057, 39726739, 0, "kobliha", raw_bytes, expanded_bytes, wrong) == null);
    }
    var parent_ns = try namespaces.Registry.init(a, DirectGetFixture.namespace_bytes); defer parent_ns.deinit();
    var parent_registry = try Registry.init(a, DirectGetFixture.packet, "", null, &parent_ns); defer parent_registry.deinit();
    const parent_page = DirectGetFixture.pages[0];
    try std.testing.expect(parent_registry.lookupSourceParent(parent_page[0], parent_page[1], 0, parent_page[2], parent_page[3], parent_page[4], DirectGetFixture.normal) != null);
    try std.testing.expect(parent_registry.lookupSourceRootLanguage(parent_page[0], parent_page[1], 0, parent_page[2], parent_page[3], parent_page[4], DirectGetFixture.normal) == null);
}

test "language-only direct GET still rejects stale transport namespace and partial stylesheet authority" {
    const a = std.testing.allocator;
    const F = FrSourceRootLanguageControl;
    var ns = try namespaces.Registry.init(a, namespaces.french_test_fixture); defer ns.deinit();
    const packet_bytes = try F.packet(a); defer a.free(packet_bytes);
    for (0..7) |which| {
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const t = arena.allocator();
        var packet_value = try parseLimited(t, packet_bytes, max_index_bytes);
        const record = &packet_value.object.getPtr("direct_get_contexts").?.array.items[0];
        switch (which) {
            0 => try packet_value.object.put(t, "namespace_registry_sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" }),
            1 => try record.object.getPtr("page").?.object.put(t, "revision", .{ .integer = 39726740 }),
            2 => try record.object.put(t, "response", .{ .string = "changed complete HTML" }),
            3 => try record.object.put(t, "prefix", .{ .string = "<html lang=fr>" }),
            4 => try record.object.getPtr("styles").?.object.put(t, "receipt", .{ .string = "{}" }),
            5 => try record.object.getPtr("styles").?.object.getPtr("responses").?.array.append(.{ .string = "div{color:red}" }),
            6 => {
                var receipt = try parse(t, try str(record.*, "receipt"));
                try receipt.object.getPtr("sources").?.array.items[0].object.put(t, "sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" });
                try record.object.put(t, "receipt", .{ .string = try std.json.Stringify.valueAlloc(t, receipt, .{}) });
            },
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(t, packet_value, .{});
        try std.testing.expectError(invalid, Registry.init(a, changed, "", null, &ns));
    }
    try std.testing.expectError(invalid, Registry.init(a, packet_bytes, "unclaimed API payload", null, &ns));
    try std.testing.expectError(invalid, Registry.init(a, packet_bytes, "", "unclaimed API prefix", &ns));
}
