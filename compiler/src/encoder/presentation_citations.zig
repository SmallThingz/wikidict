//! Build-only temporal Cite state. No source or event registry is serialized.
const std = @import("std");
const missing = @import("missing_dependency");
const A = std.mem.Allocator;
const Text = missing.Text;
const NameKey = struct { name: []const u8, group: []const u8 };
const NameContext = struct {
    pub fn hash(_: @This(), key: NameKey) u64 {
        var value = std.hash.Wyhash.init(0);
        value.update(key.group);
        value.update(&.{0});
        value.update(key.name);
        return value.final();
    }
    pub fn eql(_: @This(), first: NameKey, second: NameKey) bool {
        return std.mem.eql(u8, first.name, second.name) and std.mem.eql(u8, first.group, second.group);
    }
};
const NameMap = std.HashMapUnmanaged(NameKey, usize, NameContext, std.hash_map.default_max_load_percentage);
pub const Error = A.Error || error{ RenderLimit, InvalidPreContext, InvalidMissingDependencyCopy, InvalidLiteralProvenance, LiteralProvenanceLimit };
pub const ValidationError = Error || error{InvalidAuthoredCitation};
pub const Kind = enum { note, fragment };
pub const Item = struct {
    kind: Kind,
    name: []const u8,
    group: []const u8,
    // Source ordinal sorts one flush; readers use owner-local ordinals.
    ordinal: ?u32,
    body: ?Text,
    parts: std.ArrayList(Text) = .empty,
    recovery: ?usize = null,
    recovery_prefix_len: usize = 0,
};
pub const Event = struct {
    tag: enum { ref, references, poem },
    item: ?usize = null,
    marker: bool = false,
    batch: ?usize = null,
    authored_error: bool = false,
};
pub const Recovery = struct { name: []const u8, group: []const u8, body: ?Text };
pub const LocalPoemItem = struct {
    token: []const u8,
    kind: enum { line_break, soft_space, indent, scope, literal },
    indent: u8 = 0,
    tag: []const u8 = "",
    body: []const u8 = "",
};
pub const Batch = struct { items: []const usize, recoveries: []const usize = &.{} };
const Group = struct {
    name: []const u8,
    names: std.StringHashMapUnmanaged(usize) = .empty,
    live: std.ArrayList(usize) = .empty,
    next: u32 = 0,
    recoveries: std.ArrayList(usize) = .empty,
};
pub const Plan = struct {
    attribute: []const u8,
    // Supplied by the compiler's existing max_nodes budget, not a new limit.
    limit: usize = std.math.maxInt(usize),
    definition_events: usize = 0,
    items: std.ArrayList(Item) = .empty,
    events: std.ArrayList(Event) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    final_batches: std.ArrayList(usize) = .empty,
    groups: std.ArrayList(Group) = .empty,
    // Existing product recovery for unused list definitions is not live Cite
    // state: it grants no parent identity, ordinal, marker or follow eligibility.
    recoveries: std.ArrayList(Recovery) = .empty,
    authorities: std.ArrayList(Recovery) = .empty,
    recovery_names: NameMap = .empty,
    authority_names: NameMap = .empty,
    local_poem_items: std.ArrayList(LocalPoemItem) = .empty,

    fn group(self: *Plan, a: A, name: []const u8) Error!usize {
        for (self.groups.items, 0..) |value, index| if (std.mem.eql(u8, value.name, name)) return index;
        if (self.groups.items.len >= self.limit) return error.RenderLimit;
        try self.groups.append(a, .{ .name = try a.dupe(u8, name) });
        return self.groups.items.len - 1;
    }
    fn event(self: *Plan, a: A, value: Event) Error!usize {
        if (self.events.items.len >= self.limit) return error.RenderLimit;
        try self.events.append(a, value);
        return self.events.items.len - 1;
    }
    pub fn invalidReference(self: *Plan, a: A) Error!usize {
        return self.event(a, .{ .tag = .ref, .authored_error = true });
    }
    pub fn preparedPoem(self: *Plan, a: A) Error!usize {
        return self.event(a, .{ .tag = .poem });
    }
    fn appendItem(self: *Plan, a: A, group_index: usize, kind: Kind, name: []const u8, body: ?Text) Error!usize {
        if (self.items.items.len >= self.limit) return error.RenderLimit;
        const active = &self.groups.items[group_index];
        var ordinal: ?u32 = null;
        if (kind == .note) {
            active.next = std.math.add(u32, active.next, 1) catch return error.RenderLimit;
            ordinal = active.next;
        }
        const index = self.items.items.len;
        try self.items.append(a, .{ .kind = kind, .name = try a.dupe(u8, name), .group = active.name, .ordinal = ordinal, .body = body });
        try active.live.append(a, index);
        if (kind == .note and name.len != 0) try active.names.put(a, self.items.items[index].name, index);
        return index;
    }
    fn recovery(self: *const Plan, name: []const u8, group_name: []const u8) ?usize {
        return self.recovery_names.get(.{ .name = name, .group = group_name });
    }
    pub fn authority(self: *Plan, a: A, name: []const u8, group_name: []const u8, body: ?Text) Error!void {
        if (normalizedBody(body) == null) return;
        if (self.authority_names.contains(.{ .name = name, .group = group_name })) return;
        if (self.authorities.items.len >= self.limit) return error.RenderLimit;
        const value: Recovery = .{ .name = try a.dupe(u8, name), .group = try a.dupe(u8, group_name), .body = body };
        try self.authorities.append(a, value);
        try self.authority_names.put(a, .{ .name = value.name, .group = value.group }, self.authorities.items.len - 1);
    }
    pub fn normalizedBody(body: ?Text) ?Text {
        const value = body orelse return null;
        return if (std.mem.trim(u8, value.bytes, " \t\n\r\x00\x0b").len == 0) null else value;
    }
    /// Names/groups have already passed the normal entity/Poem-field decoder.
    pub fn reference(self: *Plan, a: A, name: []const u8, group_name: []const u8, follow: []const u8, raw_body: ?Text) ValidationError!usize {
        const body = normalizedBody(raw_body);
        const g = try self.group(a, group_name);
        if (follow.len != 0) {
            // Cite rejects an unnamed missing/empty body before pushRef.
            if (name.len != 0 or body == null) return error.InvalidAuthoredCitation;
            if (self.groups.items[g].names.get(follow)) |parent| {
                if (self.items.items[parent].body == null) self.items.items[parent].body = Text.untracked("");
                try self.items.items[parent].parts.append(a, body.?);
                return self.event(a, .{ .tag = .ref });
            }
            const orphan = try self.appendItem(a, g, .fragment, "", body);
            return self.event(a, .{ .tag = .ref, .item = orphan });
        }
        if (name.len != 0) if (self.groups.items[g].names.get(name)) |index| {
            // Keep the first accepted non-null body, matching existing conflict
            // policy. An earlier follow may already have supplied that body.
            if (self.items.items[index].body == null) self.items.items[index].body = body;
            return self.event(a, .{ .tag = .ref, .item = index, .marker = true });
        };
        if (name.len == 0 and body == null) return error.InvalidAuthoredCitation;
        var initial_body = body;
        if (name.len != 0) if (self.authority_names.get(.{ .name = name, .group = group_name })) |id| {
            initial_body = self.authorities.items[id].body;
        };
        const recovered = if (name.len != 0 and initial_body == null) self.recovery(name, group_name) else null;
        const index = try self.appendItem(a, g, .note, name, if (recovered) |id| self.recoveries.items[id].body else initial_body);
        self.items.items[index].recovery = recovered;
        if (recovered) |id| self.items.items[index].recovery_prefix_len = if (self.recoveries.items[id].body) |value| value.bytes.len else 0;
        return self.event(a, .{ .tag = .ref, .item = index, .marker = true });
    }
    fn spendDefinition(self: *Plan) Error!void {
        if (self.definition_events >= self.limit) return error.RenderLimit;
        self.definition_events += 1;
    }
    pub fn rejectListDefinition(self: *Plan) ValidationError!void {
        try self.spendDefinition();
        return error.InvalidAuthoredCitation;
    }
    pub fn listDefinition(self: *Plan, a: A, name: []const u8, group_name: []const u8, raw_body: ?Text) ValidationError!void {
        try self.spendDefinition();
        if (name.len == 0) return error.InvalidAuthoredCitation;
        const g = try self.group(a, group_name);
        const index = self.groups.items[g].names.get(name) orelse {
            if (self.recovery(name, group_name) == null) {
                if (self.recoveries.items.len >= self.limit) return error.RenderLimit;
                const id = self.recoveries.items.len;
                try self.recoveries.append(a, .{ .name = try a.dupe(u8, name), .group = self.groups.items[g].name, .body = normalizedBody(raw_body) });
                try self.recovery_names.put(a, .{ .name = self.recoveries.items[id].name, .group = self.recoveries.items[id].group }, id);
                try self.groups.items[g].recoveries.append(a, id);
            }
            return;
        };
        if (self.items.items[index].body == null) self.items.items[index].body = normalizedBody(raw_body);
    }
    fn flushGroup(self: *Plan, a: A, index: usize) Error!usize {
        const active = &self.groups.items[index];
        for (active.live.items) |id| if (self.items.items[id].parts.items.len != 0) {
            var joined: missing.Builder = .{};
            defer joined.deinit(a);
            try joined.append(a, self.items.items[id].body.?);
            for (self.items.items[id].parts.items) |part| {
                try joined.append(a, Text.untracked(" "));
                try joined.append(a, part);
            }
            self.items.items[id].body = try joined.finish(a);
            self.items.items[id].parts.deinit(a);
            self.items.items[id].parts = .empty;
        };
        var ordered: std.ArrayList(usize) = .empty;
        defer ordered.deinit(a);
        // PHP's null ordinal sort places orphan fragments first. Keep tie order.
        for (active.live.items) |id| if (self.items.items[id].kind == .fragment) try ordered.append(a, id);
        for (active.live.items) |id| if (self.items.items[id].kind == .note) try ordered.append(a, id);
        try self.batches.append(a, .{ .items = try ordered.toOwnedSlice(a), .recoveries = try active.recoveries.toOwnedSlice(a) });
        active.live.clearRetainingCapacity();
        active.names.clearRetainingCapacity();
        active.next = 0;
        return self.batches.items.len - 1;
    }
    pub fn references(self: *Plan, a: A, group_name: []const u8) Error!usize {
        const g = try self.group(a, group_name);
        return self.event(a, .{ .tag = .references, .batch = try self.flushGroup(a, g) });
    }
    pub fn finish(self: *Plan, a: A) Error!void {
        for (0..self.groups.items.len) |index| if (self.groups.items[index].live.items.len != 0 or self.groups.items[index].recoveries.items.len != 0) {
            try self.final_batches.append(a, try self.flushGroup(a, index));
        };
    }
};

test "Cite follow preserves raw quote scope group identity and temporal epochs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite" };
    const first = try plan.reference(a, "n", "", "", Text.untracked("''A"));
    const follower = try plan.reference(a, "", "", "n", Text.untracked("B''"));
    _ = try plan.reference(a, "n", "other", "", Text.untracked("Other"));
    _ = try plan.references(a, "");
    const later = try plan.reference(a, "n", "", "", Text.untracked("New"));
    try plan.finish(a);
    try std.testing.expect(plan.events.items[first].marker);
    try std.testing.expect(!plan.events.items[follower].marker);
    try std.testing.expectEqualStrings("''A B''", plan.items.items[plan.events.items[first].item.?].body.?.bytes);
    try std.testing.expect(plan.events.items[first].item.? != plan.events.items[later].item.?);
    try std.testing.expectEqualStrings("New", plan.items.items[plan.events.items[later].item.?].body.?.bytes);
}

test "Cite orphan never binds forward and sorts before notes without consuming ordinal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite" };
    _ = try plan.reference(a, "first", "", "", Text.untracked("First"));
    const orphan = try plan.reference(a, "", "", "later", Text.untracked("Second"));
    _ = try plan.reference(a, "later", "", "", Text.untracked("Third"));
    const flush = try plan.references(a, "");
    const batch = plan.batches.items[plan.events.items[flush].batch.?];
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, batch.items);
    try std.testing.expectEqual(Kind.fragment, plan.items.items[plan.events.items[orphan].item.?].kind);
    try std.testing.expectEqual(@as(?u32, null), plan.items.items[1].ordinal);
    try std.testing.expectEqual(@as(?u32, 2), plan.items.items[2].ordinal);
    try std.testing.expectEqualStrings("Second", plan.items.items[1].body.?.bytes);
    try std.testing.expectEqualStrings("Third", plan.items.items[2].body.?.bytes);
}

test "Cite paired empty named body is null and follow fills it before later definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite" };
    _ = try plan.reference(a, "n", "", "", Text.untracked(" \n"));
    _ = try plan.reference(a, "n", "", "", null);
    _ = try plan.reference(a, "", "", "n", Text.untracked("Follow"));
    try plan.listDefinition(a, "n", "", Text.untracked("Later"));
    try plan.finish(a);
    try std.testing.expectEqualStrings(" Follow", plan.items.items[0].body.?.bytes);
    try std.testing.expectError(error.InvalidAuthoredCitation, plan.reference(a, "", "", "n", null));
    try std.testing.expectError(error.InvalidAuthoredCitation, plan.reference(a, "", "", "n", Text.untracked(" ")));
}

test "unused definition recovery never creates a live follow parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite" };
    try plan.listDefinition(a, "n", "", Text.untracked("Recovered"));
    _ = try plan.references(a, "");
    const orphan = try plan.reference(a, "", "", "n", Text.untracked("Orphan"));
    const note = try plan.reference(a, "n", "", "", null);
    _ = try plan.reference(a, "", "", "n", Text.untracked("Tail"));
    try plan.finish(a);
    try std.testing.expect(plan.items.items[plan.events.items[orphan].item.?].kind == .fragment);
    try std.testing.expectEqualStrings("Orphan", plan.items.items[plan.events.items[orphan].item.?].body.?.bytes);
    const item = plan.items.items[plan.events.items[note].item.?];
    try std.testing.expectEqualStrings("Recovered Tail", item.body.?.bytes);
    try std.testing.expectEqual(@as(usize, "Recovered".len), item.recovery_prefix_len);
    try std.testing.expectEqual(@as(?u32, 1), item.ordinal);
}

test "raw follow materialization rebases missing and intentional-curly provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite" };
    _ = try plan.reference(a, "n", "", "", Text.untracked("A"));
    const tail: Text = .{ .bytes = "{{x", .ranges = &.{.{ .start = 2, .end = 3, .occurrence = 1 }}, .literal_curly_ranges = &.{.{ .start = 0, .end = 2 }} };
    _ = try plan.reference(a, "", "", "n", tail);
    try plan.finish(a);
    const joined = plan.items.items[0].body.?;
    try std.testing.expectEqualStrings("A {{x", joined.bytes);
    try std.testing.expectEqual(@as(u32, 4), joined.ranges[0].start);
    try std.testing.expectEqual(@as(u32, 5), joined.ranges[0].end);
    try std.testing.expectEqual(@as(u32, 2), joined.literal_curly_ranges[0].start);
    try std.testing.expectEqual(@as(u32, 4), joined.literal_curly_ranges[0].end);
    try std.testing.expect(!joined.unknown);
}

test "definition budget is global across lists and repeated definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite", .limit = 2 };
    try plan.listDefinition(a, "n", "", Text.untracked("Body"));
    _ = try plan.references(a, "");
    try plan.listDefinition(a, "n", "", Text.untracked("Repeated"));
    const items_before = plan.items.items.len;
    const recoveries_before = plan.recoveries.items.len;
    try std.testing.expectError(error.RenderLimit, plan.listDefinition(a, "other", "new-group", Text.untracked("Rejected")));
    try std.testing.expectEqual(items_before, plan.items.items.len);
    try std.testing.expectEqual(recoveries_before, plan.recoveries.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.groups.items.len);
}

test "authored citation failures consume budgets without creating false identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan: Plan = .{ .attribute = "data-test-cite", .limit = 1 };
    try std.testing.expectError(error.InvalidAuthoredCitation, plan.reference(a, "", "", "", null));
    try std.testing.expectEqual(@as(usize, 0), plan.items.items.len);
    const id = try plan.invalidReference(a);
    try std.testing.expect(plan.events.items[id].authored_error);
    try std.testing.expect(plan.events.items[id].item == null and !plan.events.items[id].marker);
    try std.testing.expectError(error.RenderLimit, plan.invalidReference(a));
    try std.testing.expectError(error.InvalidAuthoredCitation, plan.listDefinition(a, "", "", Text.untracked("rejected")));
    try std.testing.expectEqual(@as(usize, 1), plan.definition_events);
    try std.testing.expectError(error.RenderLimit, plan.listDefinition(a, "valid", "", Text.untracked("body")));
    try std.testing.expectError(error.RenderLimit, plan.rejectListDefinition());
    try std.testing.expectEqual(@as(usize, 0), plan.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.recoveries.items.len);
}
