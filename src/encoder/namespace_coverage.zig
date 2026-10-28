//! Data-only audit of selected rows and their edition-specific routing.
const std = @import("std");
const Kind = @import("blob_format.zig").BlobKind;
const A = std.mem.Allocator;
pub const filename = "namespace-coverage.json";
pub const Counts = struct {
    id: u32,
    name: []const u8,
    kind: ?Kind,
    input_rows: u64 = 0,
    compile_only_rows: u64 = 0,
    source_unavailable_rows: u64 = 0,
    site_metadata_rows: u64 = 0,
    reviewed_nonlexical_rows: u64 = 0,
    dispatched_rows: u64 = 0,
    expanded_pages: u64 = 0,
    fallback_pages: u64 = 0,
    duplicate_rows: u64 = 0,
    alias_pages: u64 = 0,
};
const counter_fields = .{ "input_rows", "compile_only_rows", "source_unavailable_rows", "site_metadata_rows", "reviewed_nonlexical_rows", "dispatched_rows", "expanded_pages", "fallback_pages", "duplicate_rows", "alias_pages" };
pub const Outcome = enum { expanded, fallback, duplicate };
pub const Report = struct { version: u32 = 1, registry_sha256: ?[]const u8 = null, site_info_sha256: ?[]const u8 = null, reviewed_nonlexical_sha256: ?[]const u8 = null, reviewed_nonlexical_page_ids: []const u64 = &.{}, namespaces: []const Counts };
pub const Table = struct {
    registry_sha256: ?[32]u8 = null,
    site_info_sha256: ?[32]u8 = null,
    reviewed_nonlexical_sha256: ?[32]u8 = null,
    merge_initialized: bool = false,
    reviewed_nonlexical_page_ids: std.AutoHashMapUnmanaged(u64, void) = .empty,
    rows: std.AutoHashMapUnmanaged(u32, Counts) = .empty,
    pub fn deinit(self: *Table, a: A) void {
        var it = self.rows.valueIterator();
        while (it.next()) |row| a.free(row.name);
        self.rows.deinit(a);
        self.reviewed_nonlexical_page_ids.deinit(a);
        self.* = .{};
    }
    pub fn input(self: *Table, a: A, id: u32, name: []const u8, kind: ?Kind, has_source: bool) !void {
        const result = try self.rows.getOrPut(a, id);
        if (!result.found_existing) {
            const owned = a.dupe(u8, name) catch |err| {
                _ = self.rows.remove(id);
                return err;
            };
            result.value_ptr.* = .{ .id = id, .name = owned, .kind = kind };
        }
        const row = result.value_ptr;
        if (row.kind != kind or !std.mem.eql(u8, row.name, name)) return error.NamespaceCoverageIdentityMismatch;
        row.input_rows = try std.math.add(u64, row.input_rows, 1);
        if (kind == null) row.compile_only_rows += 1 else if (!has_source) row.source_unavailable_rows += 1 else row.dispatched_rows += 1;
    }
    /// Reclassify one already-counted main-namespace input, before dispatch.
    pub fn siteMetadata(self: *Table, id: u32, digest: [32]u8) !void {
        const row = self.rows.getPtr(id) orelse return error.NamespaceCoverageMissingInput;
        if (id != 0 or row.kind != .language or row.dispatched_rows == 0) return error.NamespaceCoverageMismatch;
        if (self.site_info_sha256) |previous| if (!std.meta.eql(previous, digest)) return error.NamespaceCoverageIdentityMismatch;
        self.site_info_sha256 = digest;
        row.dispatched_rows -= 1;
        row.site_metadata_rows = try std.math.add(u64, row.site_metadata_rows, 1);
    }
    pub fn reviewedNonlexical(self: *Table, a: A, id: u32, digest: [32]u8, page_id: u64) !void {
        const row = self.rows.getPtr(id) orelse return error.NamespaceCoverageMissingInput;
        if (id != 0 or row.kind != .language or row.dispatched_rows == 0) return error.NamespaceCoverageMismatch;
        if (self.reviewed_nonlexical_sha256) |previous| if (!std.meta.eql(previous, digest)) return error.NamespaceCoverageIdentityMismatch;
        const next = try std.math.add(u64, row.reviewed_nonlexical_rows, 1);
        const slot = try self.reviewed_nonlexical_page_ids.getOrPut(a, page_id);
        if (slot.found_existing) return error.DuplicateReviewedNonlexicalPage;
        self.reviewed_nonlexical_sha256 = digest;
        row.dispatched_rows -= 1;
        row.reviewed_nonlexical_rows = next;
    }
    pub fn outcome(self: *Table, id: u32, result: Outcome) !void {
        const row = self.rows.getPtr(id) orelse return error.NamespaceCoverageMissingInput;
        const value = switch (result) {
            .expanded => &row.expanded_pages,
            .fallback => &row.fallback_pages,
            .duplicate => &row.duplicate_rows,
        };
        value.* = try std.math.add(u64, value.*, 1);
    }
    pub fn alias(self: *Table, id: u32, outcome_value: Outcome) !void {
        const row = self.rows.getPtr(id) orelse return error.NamespaceCoverageMissingInput;
        if (row.kind == null) return error.NamespaceCoverageMismatch;
        if (outcome_value == .duplicate) return error.NamespaceCoverageMismatch;
        try self.outcome(id, outcome_value);
        row.alias_pages = try std.math.add(u64, row.alias_pages, 1);
    }
    pub fn validate(self: *const Table, expected: ?u64) !void {
        var total: u64 = 0;
        var reviewed: u64 = 0;
        var it = self.rows.valueIterator();
        while (it.next()) |row| {
            if (row.kind == .alias) return error.NamespaceCoverageMismatch;
            const selected = try std.math.add(u64, try std.math.add(u64, try std.math.add(u64, row.compile_only_rows, row.source_unavailable_rows), row.site_metadata_rows), try std.math.add(u64, row.reviewed_nonlexical_rows, row.dispatched_rows));
            if (row.site_metadata_rows != 0 and (row.id != 0 or row.kind != .language or self.site_info_sha256 == null)) return error.NamespaceCoverageMismatch;
            if (row.reviewed_nonlexical_rows != 0 and (row.id != 0 or row.kind != .language or self.reviewed_nonlexical_sha256 == null)) return error.NamespaceCoverageMismatch;
            reviewed = try std.math.add(u64, reviewed, row.reviewed_nonlexical_rows);
            const completed = try std.math.add(u64, try std.math.add(u64, row.expanded_pages, row.fallback_pages), row.duplicate_rows);
            if (row.alias_pages > try std.math.add(u64, row.expanded_pages, row.fallback_pages) or (row.kind == null and row.alias_pages != 0)) return error.NamespaceCoverageMismatch;
            if (selected != row.input_rows or completed != row.dispatched_rows) return error.NamespaceCoverageMismatch;
            if (row.kind == null and row.compile_only_rows != row.input_rows) return error.NamespaceCoverageMismatch;
            if (row.kind != null and row.compile_only_rows != 0) return error.NamespaceCoverageMismatch;
            total = try std.math.add(u64, total, row.input_rows);
        }
        if (reviewed != self.reviewed_nonlexical_page_ids.count()) return error.NamespaceCoverageMismatch;
        if (expected) |count| if (count != total) return error.NamespaceCoverageMismatch;
    }
    pub fn merge(self: *Table, a: A, other: *const Table) !void {
        try other.validate(null);
        if (self.registry_sha256 == null and self.rows.count() == 0) self.registry_sha256 = other.registry_sha256 else if (!std.meta.eql(self.registry_sha256, other.registry_sha256)) return error.NamespaceCoverageRegistryMismatch;
        if (other.site_info_sha256) |digest| {
            if (self.site_info_sha256) |previous| if (!std.meta.eql(previous, digest)) return error.NamespaceCoverageIdentityMismatch;
            self.site_info_sha256 = digest;
        }
        if (!self.merge_initialized and self.rows.count() == 0 and self.reviewed_nonlexical_sha256 == null) self.reviewed_nonlexical_sha256 = other.reviewed_nonlexical_sha256 else if (!std.meta.eql(self.reviewed_nonlexical_sha256, other.reviewed_nonlexical_sha256)) return error.NamespaceCoverageIdentityMismatch;
        self.merge_initialized = true;
        var ids = other.reviewed_nonlexical_page_ids.keyIterator();
        while (ids.next()) |page_id| {
            const slot = try self.reviewed_nonlexical_page_ids.getOrPut(a, page_id.*);
            if (slot.found_existing) return error.DuplicateReviewedNonlexicalPage;
        }
        var it = other.rows.valueIterator();
        while (it.next()) |row| {
            const slot = try self.rows.getOrPut(a, row.id);
            if (!slot.found_existing) {
                const name = a.dupe(u8, row.name) catch |err| {
                    _ = self.rows.remove(row.id);
                    return err;
                };
                slot.value_ptr.* = row.*;
                slot.value_ptr.name = name;
            } else {
                if (slot.value_ptr.kind != row.kind or !std.mem.eql(u8, slot.value_ptr.name, row.name)) return error.NamespaceCoverageIdentityMismatch;
                inline for (counter_fields) |key| @field(slot.value_ptr, key) = try std.math.add(u64, @field(slot.value_ptr, key), @field(row, key));
            }
        }
    }
    pub fn write(self: *const Table, io: std.Io, a: A, root: []const u8) !void {
        try self.validate(null);
        const rows = try a.alloc(Counts, self.rows.count());
        defer a.free(rows);
        var it = self.rows.valueIterator();
        var at: usize = 0;
        while (it.next()) |row| : (at += 1) rows[at] = row.*;
        std.mem.sort(Counts, rows, {}, struct {
            fn less(_: void, l: Counts, r: Counts) bool {
                return l.id < r.id;
            }
        }.less);
        const hash = if (self.registry_sha256) |digest| std.fmt.bytesToHex(digest, .lower) else @as([64]u8, undefined);
        const site_hash = if (self.site_info_sha256) |digest| std.fmt.bytesToHex(digest, .lower) else @as([64]u8, undefined);
        const registry: ?[]const u8 = if (self.registry_sha256 != null) &hash else null;
        const site: ?[]const u8 = if (self.site_info_sha256 != null) &site_hash else null;
        const json = if (self.reviewed_nonlexical_sha256) |digest| blk: {
            const ids = try a.alloc(u64, self.reviewed_nonlexical_page_ids.count());
            defer a.free(ids);
            var keys = self.reviewed_nonlexical_page_ids.keyIterator();
            var i: usize = 0;
            while (keys.next()) |key| : (i += 1) ids[i] = key.*;
            std.mem.sort(u64, ids, {}, std.sort.asc(u64));
            const reviewed_hash = std.fmt.bytesToHex(digest, .lower);
            break :blk try std.json.Stringify.valueAlloc(a, Report{ .version = 2, .registry_sha256 = registry, .site_info_sha256 = site, .reviewed_nonlexical_sha256 = &reviewed_hash, .reviewed_nonlexical_page_ids = ids, .namespaces = rows }, .{});
        } else blk: {
            const LegacyCounts = struct { id: u32, name: []const u8, kind: ?Kind, input_rows: u64, compile_only_rows: u64, source_unavailable_rows: u64, site_metadata_rows: u64, dispatched_rows: u64, expanded_pages: u64, fallback_pages: u64, duplicate_rows: u64, alias_pages: u64 };
            const legacy = try a.alloc(LegacyCounts, rows.len);
            defer a.free(legacy);
            for (rows, 0..) |row, i| legacy[i] = .{ .id = row.id, .name = row.name, .kind = row.kind, .input_rows = row.input_rows, .compile_only_rows = row.compile_only_rows, .source_unavailable_rows = row.source_unavailable_rows, .site_metadata_rows = row.site_metadata_rows, .dispatched_rows = row.dispatched_rows, .expanded_pages = row.expanded_pages, .fallback_pages = row.fallback_pages, .duplicate_rows = row.duplicate_rows, .alias_pages = row.alias_pages };
            break :blk try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .registry_sha256 = registry, .site_info_sha256 = site, .namespaces = legacy }, .{});
        };
        defer a.free(json);
        const path = try std.fs.path.join(a, &.{ root, filename });
        defer a.free(path);
        const part = try std.fmt.allocPrint(a, "{s}.part", .{path});
        defer a.free(part);
        defer std.Io.Dir.cwd().deleteFile(io, part) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = json });
        try std.Io.Dir.cwd().rename(part, .cwd(), path, io);
    }
    pub fn read(io: std.Io, a: A, root: []const u8) !Table {
        const path = try std.fs.path.join(a, &.{ root, filename });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024));
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Report, a, bytes, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1 and parsed.value.version != 2) return error.InvalidNamespaceCoverage;
        if ((parsed.value.version == 1 and (parsed.value.reviewed_nonlexical_sha256 != null or parsed.value.reviewed_nonlexical_page_ids.len != 0)) or (parsed.value.version == 2 and parsed.value.reviewed_nonlexical_sha256 == null)) return error.InvalidNamespaceCoverage;
        var result: Table = .{};
        errdefer result.deinit(a);
        if (parsed.value.registry_sha256) |raw| {
            if (raw.len != 64) return error.InvalidNamespaceCoverage;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, raw) catch return error.InvalidNamespaceCoverage;
            result.registry_sha256 = digest;
        }
        if (parsed.value.site_info_sha256) |raw| {
            if (raw.len != 64) return error.InvalidNamespaceCoverage;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, raw) catch return error.InvalidNamespaceCoverage;
            result.site_info_sha256 = digest;
        }
        if (parsed.value.reviewed_nonlexical_sha256) |raw| {
            if (raw.len != 64) return error.InvalidNamespaceCoverage;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, raw) catch return error.InvalidNamespaceCoverage;
            result.reviewed_nonlexical_sha256 = digest;
        }
        for (parsed.value.reviewed_nonlexical_page_ids, 0..) |page_id, i| {
            if (i != 0 and page_id <= parsed.value.reviewed_nonlexical_page_ids[i - 1]) return error.InvalidNamespaceCoverage;
            try result.reviewed_nonlexical_page_ids.put(a, page_id, {});
        }
        for (parsed.value.namespaces) |row| {
            const slot = try result.rows.getOrPut(a, row.id);
            if (slot.found_existing) return error.DuplicateNamespaceCoverage;
            const name = a.dupe(u8, row.name) catch |err| {
                _ = result.rows.remove(row.id);
                return err;
            };
            slot.value_ptr.* = row;
            slot.value_ptr.name = name;
        }
        try result.validate(null);
        return result;
    }
};

test "namespace coverage partitions rows and rejects incomplete dispatch" {
    const a = std.testing.allocator;
    var table: Table = .{};
    defer table.deinit(a);
    try table.input(a, 0, "", .language, true);
    try table.input(a, 10, "Modèle", null, true);
    try table.input(a, 116, "Conjugaison", .supplemental, false);
    try std.testing.expectError(error.NamespaceCoverageMismatch, table.validate(3));
    try table.outcome(0, .expanded);
    try table.validate(3);
    try std.testing.expectError(error.NamespaceCoverageIdentityMismatch, table.input(a, 116, "Sign gloss", .sign_gloss, true));
    try std.testing.expectError(error.NamespaceCoverageMissingInput, table.outcome(999, .expanded));
}

test "namespace coverage merge retains duplicate and fallback accounting" {
    const a = std.testing.allocator;
    var first: Table = .{};
    defer first.deinit(a);
    var second: Table = .{};
    defer second.deinit(a);
    try first.input(a, 0, "", .language, true);
    try first.outcome(0, .fallback);
    try second.input(a, 0, "", .language, true);
    try second.outcome(0, .duplicate);
    try first.merge(a, &second);
    try first.validate(2);
    try std.testing.expectEqual(@as(u64, 1), first.rows.get(0).?.fallback_pages);
    try std.testing.expectEqual(@as(u64, 1), first.rows.get(0).?.duplicate_rows);
}

test "compiled aliases remain a strict expanded subset and never compile-only" {
    const a = std.testing.allocator;
    var coverage: Table = .{};
    defer coverage.deinit(a);
    try coverage.input(a, 0, "", .language, true);
    try coverage.alias(0, .expanded);
    try coverage.input(a, 10, "Template", null, true);
    try std.testing.expectError(error.NamespaceCoverageMismatch, coverage.alias(10, .expanded));
    try coverage.validate(2);
    try std.testing.expectEqual(@as(u64, 1), coverage.rows.get(0).?.alias_pages);
    coverage.rows.getPtr(0).?.alias_pages = 2;
    try std.testing.expectError(error.NamespaceCoverageMismatch, coverage.validate(2));
}

test "site metadata remains counted without language dispatch or fallback" {
    const a = std.testing.allocator;
    var table: Table = .{};
    defer table.deinit(a);
    try table.input(a, 0, "", .language, true);
    try table.siteMetadata(0, @splat(1));
    try table.input(a, 0, "", .language, true);
    try table.siteMetadata(0, @splat(1));
    try table.validate(2);
    const row = table.rows.get(0).?;
    try std.testing.expectEqual(@as(u64, 2), row.input_rows);
    try std.testing.expectEqual(@as(u64, 2), row.site_metadata_rows);
    try std.testing.expectEqual(@as(u64, 0), row.dispatched_rows);
    try std.testing.expectEqual(@as(u64, 0), row.fallback_pages);
    try std.testing.expectEqual(@as(u64, 0), row.alias_pages);
    try std.testing.expectError(error.NamespaceCoverageMismatch, table.siteMetadata(0, @splat(1)));
}

test "reviewed nonlexical rows retain input accounting and reject duplicate or mixed authority" {
    const a = std.testing.allocator;
    var left: Table = .{};
    defer left.deinit(a);
    var right: Table = .{};
    defer right.deinit(a);
    try left.input(a, 0, "", .language, true);
    try left.reviewedNonlexical(a, 0, @splat(1), 7);
    try left.input(a, 0, "", .language, true);
    try left.outcome(0, .expanded);
    try left.validate(2);
    try std.testing.expectEqual(@as(u64, 1), left.rows.get(0).?.reviewed_nonlexical_rows);
    try right.input(a, 0, "", .language, true);
    try right.reviewedNonlexical(a, 0, @splat(1), 7);
    try std.testing.expectError(error.DuplicateReviewedNonlexicalPage, left.merge(a, &right));
    var merged: Table = .{};
    defer merged.deinit(a);
    try merged.merge(a, &left);
    right.reviewed_nonlexical_sha256 = @splat(2);
    try std.testing.expectError(error.NamespaceCoverageIdentityMismatch, merged.merge(a, &right));
}
