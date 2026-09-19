const std = @import("std");

const Edge = struct {
    from: u32,
    to: u32,
};

pub const ModuleEdge = Edge;

pub const Profile = struct {
    page_reach: []u64,
    module_reach: []u64,
    direct_page_reach: []u64,
    direct_module_fanin: []u32,
};

pub const CompileMode = enum {
    o1,
    o2,

    pub fn flag(self: CompileMode) []const u8 {
        return switch (self) {
            .o1 => "-O1",
            .o2 => "-O2",
        };
    }
};

const TemplateInvoke = struct {
    template: u32,
    module: u32,
};

const NameGraph = struct {
    names: std.StringHashMapUnmanaged(u32) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    root_seed: std.ArrayList(u64) = .empty,

    fn deinit(self: *NameGraph, a: std.mem.Allocator) void {
        var keys = self.names.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.names.deinit(a);
        self.edges.deinit(a);
        self.root_seed.deinit(a);
    }

    fn id(self: *NameGraph, a: std.mem.Allocator, raw: []const u8) !u32 {
        if (self.names.get(raw)) |existing| return existing;
        const owned = try a.dupe(u8, raw);
        errdefer a.free(owned);
        const id_value: u32 = @intCast(self.names.count());
        try self.names.put(a, owned, id_value);
        try self.root_seed.append(a, 0);
        return id_value;
    }
};

fn saturatingAdd(lhs: u64, rhs: u64) u64 {
    return std.math.add(u64, lhs, rhs) catch std.math.maxInt(u64);
}

fn edgeLess(_: void, lhs: Edge, rhs: Edge) bool {
    return lhs.from < rhs.from or (lhs.from == rhs.from and lhs.to < rhs.to);
}

fn dedupeEdges(edges: *std.ArrayList(Edge)) void {
    if (edges.items.len < 2) return;
    std.mem.sort(Edge, edges.items, {}, edgeLess);
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

const Csr = struct {
    offsets: []u32,
    targets: []u32,

    fn deinit(self: *Csr, a: std.mem.Allocator) void {
        a.free(self.offsets);
        a.free(self.targets);
    }

    fn neighbors(self: *const Csr, node: u32) []const u32 {
        return self.targets[self.offsets[node]..self.offsets[node + 1]];
    }
};

fn buildCsr(a: std.mem.Allocator, node_count: usize, edges: []const Edge, reverse: bool) !Csr {
    const offsets = try a.alloc(u32, node_count + 1);
    @memset(offsets, 0);
    for (edges) |edge| {
        const from = if (reverse) edge.to else edge.from;
        offsets[from + 1] += 1;
    }
    for (1..offsets.len) |index| offsets[index] += offsets[index - 1];

    const targets = try a.alloc(u32, edges.len);
    const cursor = try a.dupe(u32, offsets[0..node_count]);
    defer a.free(cursor);
    for (edges) |edge| {
        const from = if (reverse) edge.to else edge.from;
        const to = if (reverse) edge.from else edge.to;
        targets[cursor[from]] = to;
        cursor[from] += 1;
    }
    return .{ .offsets = offsets, .targets = targets };
}

const DfsFrame = struct {
    node: u32,
    next: usize,
};

fn components(
    a: std.mem.Allocator,
    node_count: usize,
    edges: []const Edge,
) !struct { ids: []u32, count: usize } {
    if (node_count == 0) return .{ .ids = try a.alloc(u32, 0), .count = 0 };
    var forward = try buildCsr(a, node_count, edges, false);
    defer forward.deinit(a);
    var reverse = try buildCsr(a, node_count, edges, true);
    defer reverse.deinit(a);

    const seen = try a.alloc(bool, node_count);
    defer a.free(seen);
    @memset(seen, false);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(a);
    var stack: std.ArrayList(DfsFrame) = .empty;
    defer stack.deinit(a);

    for (0..node_count) |root_usize| {
        if (seen[root_usize]) continue;
        const root: u32 = @intCast(root_usize);
        seen[root] = true;
        try stack.append(a, .{ .node = root, .next = 0 });
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            const neighbors = forward.neighbors(frame.node);
            if (frame.next < neighbors.len) {
                const next = neighbors[frame.next];
                frame.next += 1;
                if (seen[next]) continue;
                seen[next] = true;
                try stack.append(a, .{ .node = next, .next = 0 });
                continue;
            }
            const done = stack.pop().?;
            try order.append(a, done.node);
        }
    }

    const ids = try a.alloc(u32, node_count);
    @memset(ids, std.math.maxInt(u32));
    var component_count: u32 = 0;
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(a);
    var oi = order.items.len;
    while (oi != 0) {
        oi -= 1;
        const root = order.items[oi];
        if (ids[root] != std.math.maxInt(u32)) continue;
        ids[root] = component_count;
        try nodes.append(a, root);
        while (nodes.pop()) |node| {
            for (reverse.neighbors(node)) |next| {
                if (ids[next] != std.math.maxInt(u32)) continue;
                ids[next] = component_count;
                try nodes.append(a, next);
            }
        }
        component_count += 1;
    }

    return .{ .ids = ids, .count = component_count };
}

fn propagate(
    a: std.mem.Allocator,
    node_count: usize,
    edges_in: []const Edge,
    seeds: []const u64,
) ![]u64 {
    std.debug.assert(seeds.len == node_count);
    var edges = std.ArrayList(Edge).fromOwnedSlice(try a.dupe(Edge, edges_in));
    defer edges.deinit(a);
    dedupeEdges(&edges);

    const scc = try components(a, node_count, edges.items);
    defer a.free(scc.ids);
    if (scc.count == 0) return a.alloc(u64, 0);

    const component_seed = try a.alloc(u64, scc.count);
    defer a.free(component_seed);
    @memset(component_seed, 0);
    for (seeds, 0..) |seed, node|
        component_seed[scc.ids[node]] = saturatingAdd(component_seed[scc.ids[node]], seed);

    var dag: std.ArrayList(Edge) = .empty;
    defer dag.deinit(a);
    for (edges.items) |edge| {
        const from = scc.ids[edge.from];
        const to = scc.ids[edge.to];
        if (from != to) try dag.append(a, .{ .from = from, .to = to });
    }
    dedupeEdges(&dag);

    const indegree = try a.alloc(u32, scc.count);
    defer a.free(indegree);
    @memset(indegree, 0);
    for (dag.items) |edge| indegree[edge.to] += 1;

    var csr = try buildCsr(a, scc.count, dag.items, false);
    defer csr.deinit(a);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(a);
    for (indegree, 0..) |degree, node| if (degree == 0) try queue.append(a, @intCast(node));

    const component_usage = try a.dupe(u64, component_seed);
    defer a.free(component_usage);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const from = queue.items[qi];
        for (csr.neighbors(from)) |to| {
            component_usage[to] = saturatingAdd(component_usage[to], component_usage[from]);
            indegree[to] -= 1;
            if (indegree[to] == 0) try queue.append(a, to);
        }
    }
    if (queue.items.len != scc.count) return error.UsageGraphCycle;

    const out = try a.alloc(u64, node_count);
    for (out, 0..) |*value, node| value.* = component_usage[scc.ids[node]];
    return out;
}

fn unescapeField(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
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

fn parseCount(raw: []const u8) !u64 {
    return std.fmt.parseInt(u64, raw, 10);
}

pub fn pageSeeds(
    io: std.Io,
    a: std.mem.Allocator,
    path: []const u8,
    module_ids: *const std.StringHashMapUnmanaged(u32),
    module_count: usize,
) ![]u64 {
    const direct_page = try a.alloc(u64, module_count);
    @memset(direct_page, 0);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const len = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (len == 0) return direct_page;
    defer a.free(direct_page);

    const bytes = try std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(bytes);

    var templates: NameGraph = .{};
    defer templates.deinit(a);
    var invokes: std.ArrayList(TemplateInvoke) = .empty;
    defer invokes.deinit(a);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const sa = scratch.allocator();
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind_raw = fields.next() orelse return error.InvalidUsageSnapshot;
        if (kind_raw.len != 1) return error.InvalidUsageSnapshot;
        switch (kind_raw[0]) {
            'T' => {
                const source = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                const target = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                if (fields.next() != null) return error.InvalidUsageSnapshot;
                try templates.edges.append(a, .{
                    .from = try templates.id(a, source),
                    .to = try templates.id(a, target),
                });
            },
            'I' => {
                const source = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                const module_name = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                if (fields.next() != null) return error.InvalidUsageSnapshot;
                if (module_ids.get(module_name)) |module_id| {
                    try invokes.append(a, .{
                        .template = try templates.id(a, source),
                        .module = module_id,
                    });
                }
            },
            'R' => {
                const target = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                const count = try parseCount(fields.next() orelse return error.InvalidUsageSnapshot);
                if (fields.next() != null) return error.InvalidUsageSnapshot;
                const id = try templates.id(a, target);
                templates.root_seed.items[id] = saturatingAdd(templates.root_seed.items[id], count);
            },
            'P' => {
                const module_name = try unescapeField(sa, fields.next() orelse return error.InvalidUsageSnapshot);
                const count = try parseCount(fields.next() orelse return error.InvalidUsageSnapshot);
                if (fields.next() != null) return error.InvalidUsageSnapshot;
                if (module_ids.get(module_name)) |module_id|
                    direct_page[module_id] = saturatingAdd(direct_page[module_id], count);
            },
            else => return error.InvalidUsageSnapshot,
        }
        _ = scratch.reset(.retain_capacity);
    }

    dedupeEdges(&templates.edges);
    const template_usage = try propagate(
        a,
        templates.root_seed.items.len,
        templates.edges.items,
        templates.root_seed.items,
    );
    defer a.free(template_usage);

    const page_seed = try a.dupe(u64, direct_page);
    for (invokes.items) |invoke|
        page_seed[invoke.module] = saturatingAdd(page_seed[invoke.module], template_usage[invoke.template]);

    return page_seed;
}

pub fn buildProfile(
    a: std.mem.Allocator,
    page_seed: []const u64,
    module_edges_in: []const ModuleEdge,
) !Profile {
    const module_count = page_seed.len;
    var module_edges = std.ArrayList(Edge).fromOwnedSlice(try a.dupe(Edge, module_edges_in));
    defer module_edges.deinit(a);
    dedupeEdges(&module_edges);

    const page_reach = try propagate(a, module_count, module_edges.items, page_seed);
    errdefer a.free(page_reach);

    const module_seed = try a.alloc(u64, module_count);
    defer a.free(module_seed);
    @memset(module_seed, 0);
    for (module_edges.items) |edge|
        module_seed[edge.to] = saturatingAdd(module_seed[edge.to], 1);
    const module_reach = try propagate(a, module_count, module_edges.items, module_seed);
    errdefer a.free(module_reach);

    const direct_page = try a.dupe(u64, page_seed);
    errdefer a.free(direct_page);
    const fanin = try a.alloc(u32, module_count);
    errdefer a.free(fanin);
    @memset(fanin, 0);
    for (module_edges.items) |edge| fanin[edge.to] += 1;

    return .{
        .page_reach = page_reach,
        .module_reach = module_reach,
        .direct_page_reach = direct_page,
        .direct_module_fanin = fanin,
    };
}

const Ranked = struct {
    id: u32,
    usage: u64,
    size: u64,
};

// Rank by usage / (1 + source_bytes / 128 MiB). Size only breaks near-usage ties;
// it is not a production optimization cutoff.
const size_priority_base: u128 = 128 * 1024 * 1024;

fn rankedLess(_: void, lhs: Ranked, rhs: Ranked) bool {
    const lhs_score = @as(u128, lhs.usage) * (size_priority_base + rhs.size);
    const rhs_score = @as(u128, rhs.usage) * (size_priority_base + lhs.size);
    if (lhs_score != rhs_score) return lhs_score > rhs_score;
    if (lhs.usage != rhs.usage) return lhs.usage > rhs.usage;
    if (lhs.size != rhs.size) return lhs.size < rhs.size;
    return lhs.id < rhs.id;
}

fn markCoverage(
    a: std.mem.Allocator,
    selected: []bool,
    usage: []const u64,
    sizes: []const u64,
    numerator: u32,
    denominator: u32,
) !void {
    if (denominator == 0 or numerator > denominator) return error.InvalidCoverageTarget;

    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(a);
    var total: u128 = 0;
    for (usage, sizes, 0..) |value, size, id| {
        if (value == 0) continue;
        total += value;
        try ranked.append(a, .{
            .id = @intCast(id),
            .usage = value,
            .size = size,
        });
    }
    if (ranked.items.len == 0 or total == 0) return;

    std.mem.sort(Ranked, ranked.items, {}, rankedLess);
    const target = (total * numerator + denominator - 1) / denominator;
    var covered: u128 = 0;
    for (ranked.items) |item| {
        selected[item.id] = true;
        covered += item.usage;
        if (covered >= target) break;
    }
}

pub fn chooseModes(
    a: std.mem.Allocator,
    profile: Profile,
    source_sizes: []const u64,
) ![]CompileMode {
    if (profile.page_reach.len != source_sizes.len or
        profile.module_reach.len != source_sizes.len) return error.InvalidUsageProfile;

    const selected = try a.alloc(bool, source_sizes.len);
    defer a.free(selected);
    @memset(selected, false);

    // O2 is reserved for the modules that cover nearly all observed corpus use.
    // Module fan-in gets its own coverage pass so shared libraries remain hot
    // even when direct page invokes are sparse.
    try markCoverage(a, selected, profile.page_reach, source_sizes, 995, 1000);
    try markCoverage(a, selected, profile.module_reach, source_sizes, 980, 1000);

    const modes = try a.alloc(CompileMode, source_sizes.len);
    for (modes, selected) |*mode, hot| mode.* = if (hot) .o2 else .o1;
    return modes;
}

pub fn deinitProfile(a: std.mem.Allocator, profile: *Profile) void {
    a.free(profile.page_reach);
    a.free(profile.module_reach);
    a.free(profile.direct_page_reach);
    a.free(profile.direct_module_fanin);
    profile.* = undefined;
}

test "usage propagation collapses cycles before accumulating reach" {
    const a = std.testing.allocator;
    const edges = [_]ModuleEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 0 },
        .{ .from = 1, .to = 2 },
    };
    const seed = [_]u64{ 5, 0, 0 };
    var profile = try buildProfile(a, &seed, &edges);
    defer deinitProfile(a, &profile);
    try std.testing.expectEqual(@as(u64, 5), profile.page_reach[0]);
    try std.testing.expectEqual(@as(u64, 5), profile.page_reach[1]);
    try std.testing.expectEqual(@as(u64, 5), profile.page_reach[2]);
    try std.testing.expectEqual(@as(u64, 2), profile.module_reach[0]);
    try std.testing.expectEqual(@as(u64, 2), profile.module_reach[1]);
    try std.testing.expectEqual(@as(u64, 3), profile.module_reach[2]);
}

test "mode selection is usage first with a modest size penalty" {
    const a = std.testing.allocator;
    var profile = Profile{
        .page_reach = try a.dupe(u64, &.{ 10_000, 100, 1 }),
        .module_reach = try a.dupe(u64, &.{ 1, 1_000, 1 }),
        .direct_page_reach = try a.dupe(u64, &.{ 10_000, 100, 1 }),
        .direct_module_fanin = try a.dupe(u32, &.{ 0, 10, 0 }),
    };
    defer deinitProfile(a, &profile);
    const sizes = [_]u64{ 64 * 1024 * 1024, 1 * 1024 * 1024, 64 * 1024 };
    const modes = try chooseModes(a, profile, &sizes);
    defer a.free(modes);
    try std.testing.expectEqual(CompileMode.o2, modes[0]);
    try std.testing.expectEqual(CompileMode.o2, modes[1]);
    try std.testing.expectEqual(CompileMode.o1, modes[2]);
}
