const std = @import("std");
const A = std.mem.Allocator;
pub const generated_link = @import("generated_link.zig");
// This is build-only metadata. None of these values enter a semantic record.
pub const schema = "wikidict.missing-dependency-phase.v1";
// Reuse the existing source/Poem metadata byte ceiling; the enclosing worker
// frame still imposes its aggregate limit. No additional runtime reservation.
pub const max_metadata_bytes = 16 * 1024 * 1024;
pub const Range = struct { start: u32, end: u32, occurrence: u32 };
// In-process expansion provenance only; never serialized as missing metadata.
pub const LiteralRange = struct { start: u32, end: u32 };
pub const Occurrence = struct { id: u32, title: []const u8 };
pub const Coordinates = struct { ranges: []const Range = &.{}, unknown: bool = false };
pub const Text = struct {
    bytes: []const u8,
    ranges: []const Range = &.{},
    literal_curly_ranges: []const LiteralRange = &.{},
    generated_links: []const generated_link.Range = &.{},
    generated_source: ?[]const u8 = null,
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
    if (output.literal_curly_ranges.len != 0 or title.literal_curly_ranges.len != 0)
        return error.UnfinalizedLiteralProvenance;
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
    literal_curly_ranges: std.ArrayList(LiteralRange) = .empty,
    generated_links: std.ArrayList(generated_link.Range) = .empty,
    unknown: bool = false,
    pub fn deinit(self: *Builder, a: A) void {
        self.bytes.deinit(a);
        self.ranges.deinit(a);
        self.literal_curly_ranges.deinit(a);
        self.generated_links.deinit(a);
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
        try validateLiteralRanges(source);
        try generated_link.validateRanges(source.bytes, source.generated_source, source.generated_links);
        const base = self.bytes.items.len;
        if (end - start > std.math.maxInt(u32) -| base) return error.InvalidMissingDependencyCopy;
        if (self.literal_curly_ranges.items.len +| source.literal_curly_ranges.len > max_metadata_bytes / @sizeOf(LiteralRange))
            return error.LiteralProvenanceLimit;
        try self.literal_curly_ranges.ensureUnusedCapacity(a, source.literal_curly_ranges.len);
        for (source.literal_curly_ranges) |r| {
            if (r.end <= start or r.start >= end) continue;
            self.literal_curly_ranges.appendAssumeCapacity(.{
                .start = @intCast(base + @max(start, r.start) - start),
                .end = @intCast(base + @min(end, r.end) - start),
            });
        }
        if (self.generated_links.items.len +| source.generated_links.len > generated_link.max_links) return error.LiteralProvenanceLimit;
        for (source.generated_links) |link| {
            if (link.end <= start or link.start >= end) continue;
            if (link.start < start or link.end > end) return error.InvalidLiteralProvenance;
            try self.generated_links.append(a, .{ .start = @intCast(base + link.start - start), .end = @intCast(base + link.end - start), .bound = link.bound });
        }
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
    pub fn appendLiteralCurly(self: *Builder, a: A, bytes: []const u8) !void {
        const base = self.bytes.items.len;
        if (bytes.len > std.math.maxInt(u32) -| base) return error.LiteralProvenanceLimit;
        var at: usize = 0;
        while (at < bytes.len) {
            if (bytes[at] != '{' and bytes[at] != '}') {
                at += 1;
                continue;
            }
            const start = at;
            while (at < bytes.len and (bytes[at] == '{' or bytes[at] == '}')) : (at += 1) {}
            if (self.literal_curly_ranges.items.len >= max_metadata_bytes / @sizeOf(LiteralRange))
                return error.LiteralProvenanceLimit;
            try self.literal_curly_ranges.append(a, .{ .start = @intCast(base + start), .end = @intCast(base + at) });
        }
        try self.bytes.appendSlice(a, bytes);
    }
    pub fn markLiteralCurly(self: *Builder, a: A, start: usize, end: usize) !void {
        if (start >= end or end > self.bytes.items.len or end > std.math.maxInt(u32))
            return error.InvalidLiteralProvenance;
        for (self.bytes.items[start..end]) |byte|
            if (byte != '{' and byte != '}') return error.InvalidLiteralProvenance;
        if (self.literal_curly_ranges.items.len != 0) {
            const previous = &self.literal_curly_ranges.items[self.literal_curly_ranges.items.len - 1];
            if (start < previous.start) return error.InvalidLiteralProvenance;
            if (start <= previous.end) {
                previous.end = @intCast(@max(previous.end, end));
                return;
            }
        }
        if (self.literal_curly_ranges.items.len >= max_metadata_bytes / @sizeOf(LiteralRange))
            return error.LiteralProvenanceLimit;
        try self.literal_curly_ranges.append(a, .{ .start = @intCast(start), .end = @intCast(end) });
    }
    pub fn finish(self: *Builder, a: A) !Text {
        const bytes = try self.bytes.toOwnedSlice(a);
        errdefer a.free(bytes);
        const ranges = try self.ranges.toOwnedSlice(a);
        errdefer a.free(ranges);
        const links = try self.generated_links.toOwnedSlice(a);
        errdefer a.free(links);
        return .{ .bytes = bytes, .ranges = ranges, .literal_curly_ranges = try self.literal_curly_ranges.toOwnedSlice(a), .generated_links = links, .generated_source = if (links.len == 0) null else bytes, .unknown = self.unknown };
    }
};
fn validateLiteralRanges(source: Text) !void {
    var previous: u32 = 0;
    for (source.literal_curly_ranges) |r| {
        if (r.start < previous or r.start >= r.end or r.end > source.bytes.len)
            return error.InvalidLiteralProvenance;
        for (source.bytes[r.start..r.end]) |byte|
            if (byte != '{' and byte != '}') return error.InvalidLiteralProvenance;
        previous = r.end;
    }
}

// The brace scanner may leave a parameter default's matching literal closes
// immediately after the parameter node. Only its own proven opens own them.
pub fn unclosedLiteralCurly(source: Text) !usize {
    try validateLiteralRanges(source);
    var balance: usize = 0;
    for (source.literal_curly_ranges) |r| {
        for (source.bytes[r.start..r.end]) |byte| {
            if (byte == '{') {
                balance += 1;
            } else if (byte == '}' and balance != 0) balance -= 1;
        }
    }
    return balance;
}

// Publish proven literal braces only after all string consumers have finished.
// Missing-dependency coordinates are rebased independently of literal provenance.
pub fn escapeLiteralCurly(a: A, source: Text) !Text {
    if (source.literal_curly_ranges.len == 0) return source;
    try validateLiteralRanges(source);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var copied: usize = 0;
    for (source.literal_curly_ranges) |r| {
        try out.appendSlice(a, source.bytes[copied..r.start]);
        for (source.bytes[r.start..r.end]) |byte|
            try out.appendSlice(a, if (byte == '{') "&#123;" else "&#125;");
        copied = r.end;
    }
    try out.appendSlice(a, source.bytes[copied..]);
    if (out.items.len > std.math.maxInt(u32)) return error.LiteralProvenanceLimit;
    const ranges = try a.alloc(Range, source.ranges.len);
    errdefer a.free(ranges);
    var literal_at: usize = 0;
    var literal_before: usize = 0;
    var previous: u32 = 0;
    for (source.ranges, ranges) |r, *rebased| {
        if (r.start < previous or r.start >= r.end or r.end > source.bytes.len or r.occurrence == 0)
            return error.InvalidMissingDependencyCopy;
        const start = rebaseLiteralOffset(source.literal_curly_ranges, r.start, &literal_at, &literal_before);
        const end = rebaseLiteralOffset(source.literal_curly_ranges, r.end, &literal_at, &literal_before);
        rebased.* = .{ .start = @intCast(start), .end = @intCast(end), .occurrence = r.occurrence };
        previous = r.end;
    }
    try generated_link.validateRanges(source.bytes, source.generated_source, source.generated_links);
    const links = try a.alloc(generated_link.Range, source.generated_links.len);
    errdefer a.free(links);
    literal_at = 0;
    literal_before = 0;
    for (source.generated_links, links) |link, *rebased| {
        const start = rebaseLiteralOffset(source.literal_curly_ranges, link.start, &literal_at, &literal_before);
        const end = rebaseLiteralOffset(source.literal_curly_ranges, link.end, &literal_at, &literal_before);
        rebased.* = .{ .start = @intCast(start), .end = @intCast(end), .bound = link.bound };
    }
    const bytes = try out.toOwnedSlice(a);
    return .{ .bytes = bytes, .ranges = ranges, .generated_links = links, .generated_source = if (links.len == 0) null else bytes, .unknown = source.unknown };
}
fn rebaseLiteralOffset(ranges: []const LiteralRange, offset: usize, at: *usize, before: *usize) usize {
    while (at.* < ranges.len and ranges[at.*].end <= offset) : (at.* += 1)
        before.* += ranges[at.*].end - ranges[at.*].start;
    const partial = if (at.* < ranges.len and ranges[at.*].start < offset) offset - ranges[at.*].start else 0;
    return offset + 5 * (before.* + partial);
}
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

test "literal curly provenance preserves raw values and exact clipped copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var builder: Builder = .{};
    try builder.appendLiteralCurly(a, "x{{y}}z");
    const source = try builder.finish(a);
    try std.testing.expectEqualStrings("x{{y}}z", source.bytes);
    try std.testing.expectEqual(@as(usize, 7), source.bytes.len);
    const clipped = try slice(a, source, 2, 5);
    try std.testing.expectEqualStrings("{y}", clipped.bytes);
    const published = try escapeLiteralCurly(a, try duplicate(a, clipped));
    try std.testing.expectEqualStrings("&#123;y&#125;", published.bytes);
    try std.testing.expectEqual(@as(usize, 0), published.literal_curly_ranges.len);
    const transformed = Text.transformed(clipped.bytes);
    try std.testing.expectEqual(@as(usize, 0), transformed.literal_curly_ranges.len);
    try std.testing.expect((try escapeLiteralCurly(a, transformed)).bytes.ptr == transformed.bytes.ptr);
}

test "literal publication rebases missing ranges and refuses unfinalized metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var page: Page = .{};
    const missing = try page.missing(a, "Template:Missing", "[[Template:Missing]]");
    var builder: Builder = .{};
    try builder.append(a, missing);
    try builder.appendLiteralCurly(a, "{x}");
    try builder.append(a, missing);
    const source = try builder.finish(a);
    try std.testing.expectError(error.UnfinalizedLiteralProvenance, encode(a, source, Text.untracked("Title"), page.occurrences.items));
    const published = try escapeLiteralCurly(a, source);
    try std.testing.expectEqualStrings("[[Template:Missing]]&#123;x&#125;[[Template:Missing]]", published.bytes);
    try std.testing.expectEqual(@as(usize, 2), published.ranges.len);
    try std.testing.expectEqual(source.ranges[0].start, published.ranges[0].start);
    try std.testing.expectEqual(source.ranges[0].end, published.ranges[0].end);
    try std.testing.expectEqual(source.ranges[1].start + 10, published.ranges[1].start);
    try std.testing.expectEqual(source.ranges[1].end + 10, published.ranges[1].end);
    const encoded = try encode(a, published, Text.untracked("Title"), page.occurrences.items);
    var decoded = try decode(a, encoded, published.bytes, "Title");
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.output().ranges.len);
}

test "literal publication requires exact valid curly ranges" {
    const bad = Text{ .bytes = "{x}", .literal_curly_ranges = &.{.{ .start = 0, .end = 3 }} };
    try std.testing.expectError(error.InvalidLiteralProvenance, escapeLiteralCurly(std.testing.allocator, bad));
}

test "generated semantic links survive only complete proven copies slices and literal offset edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argument = "9781234567890[[data|only]]";
    const target = try generated_link.targetAlloc(a, argument);
    const label = try std.fmt.allocPrint(a, "ISBN {s}", .{argument});
    const token = try generated_link.tokenAlloc(a, 0, argument, target, label);
    const bytes = try std.mem.concat(a, u8, &.{ "{", token });
    const links = try generated_link.bindAlloc(a, bytes, &.{.{ .start = 1, .end = @intCast(bytes.len), .value = .{ .token = token, .argument = argument, .target = target, .label = label } }});
    const source: Text = .{ .bytes = bytes, .generated_links = links, .generated_source = bytes, .literal_curly_ranges = &.{.{ .start = 0, .end = 1 }} };
    var out: Builder = .{};
    defer out.deinit(a);
    try out.append(a, try slice(a, source, 1, bytes.len));
    try out.append(a, try duplicate(a, try slice(a, source, 1, bytes.len)));
    const copied = try out.finish(a);
    try generated_link.validateRanges(copied.bytes, copied.generated_source, copied.generated_links);
    try std.testing.expectEqual(@as(usize, 2), copied.generated_links.len);
    try std.testing.expect(copied.generated_links[0].bound == links[0].bound);
    try std.testing.expect(copied.generated_links[1].bound == links[0].bound);
    try std.testing.expectError(error.InvalidLiteralProvenance, slice(a, source, 2, bytes.len));
    var detached = source;
    detached.bytes = try a.dupe(u8, bytes);
    try std.testing.expectError(error.InvalidLiteralProvenance, duplicate(a, detached));
    const untrusted_copy = Text.transformed(bytes);
    try std.testing.expectEqual(@as(usize, 0), untrusted_copy.generated_links.len);
    const escaped = try escapeLiteralCurly(a, source);
    try std.testing.expectEqualStrings("&#123;", escaped.bytes[0..6]);
    try std.testing.expectEqual(@as(u32, 6), escaped.generated_links[0].start);
    try generated_link.validateRanges(escaped.bytes, escaped.generated_source, escaped.generated_links);
}
