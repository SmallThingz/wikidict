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
    dispatched_rows: u64 = 0,
    expanded_pages: u64 = 0,
    fallback_pages: u64 = 0,
    duplicate_rows: u64 = 0,
    alias_pages: u64 = 0,
};
const counter_fields = .{ "input_rows", "compile_only_rows", "source_unavailable_rows", "dispatched_rows", "expanded_pages", "fallback_pages", "duplicate_rows", "alias_pages" };
pub const Outcome = enum { expanded, fallback, duplicate };
pub const Report = struct { version: u32 = 1, registry_sha256: ?[]const u8 = null, namespaces: []const Counts };
pub const Table = struct {
    registry_sha256: ?[32]u8 = null,
    rows: std.AutoHashMapUnmanaged(u32, Counts) = .empty,
    pub fn deinit(self: *Table, a: A) void {
        var it = self.rows.valueIterator();
        while (it.next()) |row| a.free(row.name);
        self.rows.deinit(a);
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
        var it = self.rows.valueIterator();
        while (it.next()) |row| {
            if (row.kind == .alias) return error.NamespaceCoverageMismatch;
            const selected = try std.math.add(u64, try std.math.add(u64, row.compile_only_rows, row.source_unavailable_rows), row.dispatched_rows);
            const completed = try std.math.add(u64, try std.math.add(u64, row.expanded_pages, row.fallback_pages), row.duplicate_rows);
            if (row.alias_pages > try std.math.add(u64, row.expanded_pages, row.fallback_pages) or (row.kind == null and row.alias_pages != 0)) return error.NamespaceCoverageMismatch;
            if (selected != row.input_rows or completed != row.dispatched_rows) return error.NamespaceCoverageMismatch;
            if (row.kind == null and row.compile_only_rows != row.input_rows) return error.NamespaceCoverageMismatch;
            if (row.kind != null and row.compile_only_rows != 0) return error.NamespaceCoverageMismatch;
            total = try std.math.add(u64, total, row.input_rows);
        }
        if (expected) |count| if (count != total) return error.NamespaceCoverageMismatch;
    }
    pub fn merge(self: *Table, a: A, other: *const Table) !void {
        try other.validate(null);
        if (self.registry_sha256 == null and self.rows.count() == 0) self.registry_sha256 = other.registry_sha256 else if (!std.meta.eql(self.registry_sha256, other.registry_sha256)) return error.NamespaceCoverageRegistryMismatch;
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
        const json = try std.json.Stringify.valueAlloc(a, Report{ .namespaces = rows, .registry_sha256 = if (self.registry_sha256 != null) &hash else null }, .{});
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
        if (parsed.value.version != 1) return error.InvalidNamespaceCoverage;
        var result: Table = .{};
        errdefer result.deinit(a);
        if (parsed.value.registry_sha256) |raw| {
            if (raw.len != 64) return error.InvalidNamespaceCoverage;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, raw) catch return error.InvalidNamespaceCoverage;
            result.registry_sha256 = digest;
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
