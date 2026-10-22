const std = @import("std");
const A = std.mem.Allocator;
// This is build-only metadata. None of these values enter a semantic record.
pub const schema = "wikidict.missing-dependency-phase.v1";
// Reuse the existing source/Poem metadata byte ceiling; the enclosing worker
// frame still imposes its aggregate limit. No additional runtime reservation.
pub const max_metadata_bytes = 16 * 1024 * 1024;
pub const Range = struct { start: u32, end: u32, occurrence: u32 };
pub const Occurrence = struct { id: u32, title: []const u8 };
pub const Coordinates = struct { ranges: []const Range = &.{}, unknown: bool = false };
pub const Text = struct {
    bytes: []const u8,
    ranges: []const Range = &.{},
    unknown: bool = false,
    pub fn coordinates(self: Text) Coordinates {
        return .{ .ranges = self.ranges, .unknown = self.unknown };
    }
    pub fn untracked(bytes: []const u8) Text {
        return .{ .bytes = bytes };
    }
    pub fn transformed(bytes: []const u8) Text {
        return .{ .bytes = bytes, .unknown = true };
    }
};
pub const Metadata = struct {
    schema: []const u8 = "wikidict.missing-dependency-phase.v1",
    output_sha256: []const u8,
    display_title_sha256: []const u8,
    occurrences: []const Occurrence,
    output: Coordinates,
    display_title: Coordinates,
};
fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn validateCoordinates(coordinates: Coordinates, bytes: []const u8, occurrences: []const Occurrence) !void {
    var previous: u32 = 0;
    for (coordinates.ranges) |r| {
        if (r.start < previous or r.start >= r.end or r.end > bytes.len or r.occurrence == 0 or r.occurrence > occurrences.len)
            return error.InvalidMissingDependencyMetadata;
        previous = r.end;
    }
}
fn validate(m: Metadata, output: []const u8, title: []const u8) !void {
    if (!std.mem.eql(u8, m.schema, schema)) return error.InvalidMissingDependencyMetadata;
    const output_hash = digest(output);
    const title_hash = digest(title);
    if (!std.mem.eql(u8, m.output_sha256, &output_hash) or !std.mem.eql(u8, m.display_title_sha256, &title_hash))
        return error.InvalidMissingDependencyMetadata;
    for (m.occurrences, 0..) |o, i| {
        if (o.id != i + 1 or o.title.len == 0) return error.InvalidMissingDependencyMetadata;
    }
    try validateCoordinates(m.output, output, m.occurrences);
    try validateCoordinates(m.display_title, title, m.occurrences);
}
pub const Phase = struct {
    parsed: std.json.Parsed(Metadata),
    output_bytes: []const u8,
    title_bytes: []const u8,
    pub fn deinit(self: *Phase) void {
        self.parsed.deinit();
    }
    pub fn output(self: *const Phase) Text {
        return .{ .bytes = self.output_bytes, .ranges = self.parsed.value.output.ranges, .unknown = self.parsed.value.output.unknown };
    }
    pub fn displayTitle(self: *const Phase) Text {
        return .{ .bytes = self.title_bytes, .ranges = self.parsed.value.display_title.ranges, .unknown = self.parsed.value.display_title.unknown };
    }
    pub fn occurrences(self: *const Phase) []const Occurrence {
        return self.parsed.value.occurrences;
    }
};
pub fn decode(a: A, bytes: []const u8, output: []const u8, title: []const u8) !Phase {
    if (bytes.len == 0 or bytes.len > max_metadata_bytes) return error.InvalidMissingDependencyMetadata;
    var parsed = std.json.parseFromSlice(Metadata, a, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMissingDependencyMetadata,
    };
    errdefer parsed.deinit();
    try validate(parsed.value, output, title);
    return .{ .parsed = parsed, .output_bytes = output, .title_bytes = title };
}
pub fn encode(a: A, output: Text, title: Text, occurrences: []const Occurrence) ![]const u8 {
    return encodeWithin(a, output, title, occurrences, max_metadata_bytes);
}
fn encodeWithin(a: A, output: Text, title: Text, occurrences: []const Occurrence, budget: usize) ![]const u8 {
    // JSON escaping is at most six bytes per input byte. Check before allocation.
    var bound: usize = 512 +| (output.ranges.len +| title.ranges.len) *| 96;
    for (occurrences) |o| bound +|= 64 +| o.title.len *| 6;
    if (bound > @min(budget, max_metadata_bytes)) return error.MissingDependencyMetadataLimit;
    const output_hash = digest(output.bytes);
    const title_hash = digest(title.bytes);
    const m: Metadata = .{ .output_sha256 = &output_hash, .display_title_sha256 = &title_hash, .occurrences = occurrences, .output = output.coordinates(), .display_title = title.coordinates() };
    try validate(m, output.bytes, title.bytes);
    const bytes = try std.json.Stringify.valueAlloc(a, m, .{});
    errdefer a.free(bytes);
    if (bytes.len > @min(budget, max_metadata_bytes)) return error.MissingDependencyMetadataLimit;
    return bytes;
}
pub const Encoding = struct { metadata: ?[]const u8, limited: bool };
// Caller supplies capacity remaining after the unchanged frame headers, Poem,
// source and title. Absence never certifies complete provenance.
pub fn encodeBudgeted(a: A, output: Text, title: Text, occurrences: []const Occurrence, budget: usize) !Encoding {
    if (encodeWithin(a, output, title, occurrences, budget)) |bytes| return .{ .metadata = bytes, .limited = false } else |err| switch (err) {
        error.MissingDependencyMetadataLimit => {},
        else => return err,
    }
    const unknown_output = Text.transformed(output.bytes);
    const unknown_title = Text.transformed(title.bytes);
    // Unknown phase serialization contains only fixed keys, two 64-byte
    // hashes and empty arrays. Allocate that bounded small value so the exact
    // byte length, rather than the full-phase estimate, decides final fit.
    const minimal = try encode(a, unknown_output, unknown_title, &.{});
    if (minimal.len <= budget) return .{ .metadata = minimal, .limited = true };
    a.free(minimal);
    return .{ .metadata = null, .limited = true };
}
pub const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    unknown: bool = false,
    pub fn deinit(self: *Builder, a: A) void {
        self.bytes.deinit(a);
        self.ranges.deinit(a);
    }
    pub fn append(self: *Builder, a: A, source: Text) !void {
        try self.appendSlice(a, source, 0, source.bytes.len);
    }
    pub fn appendSlice(self: *Builder, a: A, source: Text, start: usize, end: usize) !void {
        if (start > end or end > source.bytes.len) return error.InvalidMissingDependencyCopy;
        var previous: u32 = 0;
        for (source.ranges) |r| {
            if (r.start < previous or r.start >= r.end or r.end > source.bytes.len or r.occurrence == 0) return error.InvalidMissingDependencyCopy;
            previous = r.end;
        }
        const base = self.bytes.items.len;
        if (end - start > std.math.maxInt(u32) -| base) return error.InvalidMissingDependencyCopy;
        try self.bytes.ensureUnusedCapacity(a, end - start);
        // Optional provenance stays within the existing metadata ceiling. If
        // repeated copies exceed it, retain bytes and explicitly decline ranges.
        if (self.ranges.items.len +| source.ranges.len > max_metadata_bytes / @sizeOf(Range)) {
            self.bytes.appendSliceAssumeCapacity(source.bytes[start..end]);
            self.unknown = true;
            return;
        }
        try self.ranges.ensureUnusedCapacity(a, source.ranges.len);
        self.bytes.appendSliceAssumeCapacity(source.bytes[start..end]);
        self.unknown = self.unknown or source.unknown;
        for (source.ranges) |r| {
            if (r.end <= start or r.start >= end) continue;
            if (r.start < start or r.end > end) {
                self.unknown = true;
                continue;
            }
            self.ranges.appendAssumeCapacity(.{ .start = @intCast(base + r.start - start), .end = @intCast(base + r.end - start), .occurrence = r.occurrence });
        }
    }
    pub fn finish(self: *Builder, a: A) !Text {
        const bytes = try self.bytes.toOwnedSlice(a);
        errdefer a.free(bytes);
        return .{ .bytes = bytes, .ranges = try self.ranges.toOwnedSlice(a), .unknown = self.unknown };
    }
};
pub fn slice(a: A, source: Text, start: usize, end: usize) !Text {
    var out: Builder = .{};
    errdefer out.deinit(a);
    try out.appendSlice(a, source, start, end);
    return out.finish(a);
}
pub fn duplicate(a: A, source: Text) !Text {
    return slice(a, source, 0, source.bytes.len);
}

// An immutable page-native value. Lua conversions must use transformed(), never
// recover this object through string pointers or matching values.
pub const Page = struct {
    occurrences: std.ArrayList(Occurrence) = .empty,
    metadata_unknown: bool = false,
    metadata_bound: usize = 512,
    pub fn missing(self: *Page, a: A, title: []const u8, bytes: []const u8) !Text {
        const next_bound = self.metadata_bound +| 160 +| title.len *| 6;
        if (next_bound > max_metadata_bytes or self.occurrences.items.len >= max_metadata_bytes / @sizeOf(Occurrence) or bytes.len > std.math.maxInt(u32)) {
            self.metadata_unknown = true;
            return Text.transformed(bytes);
        }
        self.metadata_bound = next_bound;
        const id: u32 = @intCast(self.occurrences.items.len + 1);
        try self.occurrences.append(a, .{ .id = id, .title = try a.dupe(u8, title) });
        const ranges = try a.alloc(Range, 1);
        ranges[0] = .{ .start = 0, .end = @intCast(bytes.len), .occurrence = id };
        return .{ .bytes = bytes, .ranges = ranges };
    }
};

test "native occurrence copy duplication clipping and identical authored bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: Page = .{};
    const generated = try page.missing(a, "Bysen:language", "[[:Bysen:language]]");
    var out: Builder = .{};
    try out.append(a, Text.untracked(generated.bytes));
    try out.append(a, generated);
    try out.append(a, try slice(a, generated, 0, generated.bytes.len));
    try out.append(a, try slice(a, generated, 1, generated.bytes.len));
    const result = try out.finish(a);
    try std.testing.expectEqual(@as(usize, 2), result.ranges.len);
    try std.testing.expectEqual(@as(u32, @intCast(generated.bytes.len)), result.ranges[0].start);
    try std.testing.expect(result.unknown);
}
test "build-only metadata body and display title are separately bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: Page = .{};
    const generated = try page.missing(a, "Bysen:language", "[[:Bysen:language]]");
    const bytes = try encode(a, generated, Text.untracked("Title"), page.occurrences.items);
    var phase = try decode(a, bytes, generated.bytes, "Title");
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 1), phase.output().ranges.len);
    try std.testing.expectEqual(@as(usize, 0), phase.displayTitle().ranges.len);
    try std.testing.expectError(error.InvalidMissingDependencyMetadata, decode(a, bytes, generated.bytes, "Other"));
    const unknown = Text.transformed(generated.bytes);
    try std.testing.expectEqual(@as(usize, 0), unknown.ranges.len);
    try std.testing.expect(unknown.unknown);
}

test "optional provenance capacity degrades to explicit unknown then absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: Page = .{};
    const generated = try page.missing(a, "Template:language", "[[:Template:language]]");
    const complete = try encodeBudgeted(a, generated, Text.untracked(""), page.occurrences.items, max_metadata_bytes);
    try std.testing.expect(!complete.limited and complete.metadata != null);
    const limited = try encodeBudgeted(a, generated, Text.untracked(""), page.occurrences.items, 512);
    try std.testing.expect(limited.limited and limited.metadata != null);
    var phase = try decode(a, limited.metadata.?, generated.bytes, "");
    defer phase.deinit();
    try std.testing.expect(phase.output().unknown);
    try std.testing.expectEqual(@as(usize, 0), phase.output().ranges.len);
    const exact = try encodeBudgeted(a, generated, Text.untracked(""), page.occurrences.items, limited.metadata.?.len);
    try std.testing.expect(exact.limited and exact.metadata != null);
    try std.testing.expectEqual(limited.metadata.?.len, exact.metadata.?.len);
    const absent = try encodeBudgeted(a, generated, Text.untracked(""), page.occurrences.items, limited.metadata.?.len - 1);
    try std.testing.expect(absent.limited and absent.metadata == null);
}
