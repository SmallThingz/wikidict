//! Pinned redirect-table facts. Raw bytes and the namespace registry are
//! immutable borrowed inputs; only the compact page-id index is retained.
const std = @import("std");
const Registry = @import("namespace_registry.zig").Registry;
const A = std.mem.Allocator;

pub const header = "# wikidict-page-redirects-v1";
pub const max_bytes = 256 * 1024 * 1024;
pub const max_rows = 4_000_000;
pub const Target = struct {
    namespace: i32,
    /// Exact full XML target, verified against the SQL components.
    title: []const u8,
    fragment: []const u8,
    interwiki: []const u8,

    pub fn deinit(self: *Target, a: A) void {
        a.free(self.title);
        a.free(self.fragment);
        a.free(self.interwiki);
        self.* = undefined;
    }
};

const Row = struct { id: u64, offset: usize };
const Fields = struct {
    id: u64,
    namespace: i32,
    title_hex: []const u8,
    interwiki_hex: []const u8,
    fragment_hex: []const u8,
};

const Lines = struct {
    raw: []const u8,
    offset: usize = 0,

    fn next(self: *Lines) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.raw, self.offset, '\n') orelse return error.InvalidPageRedirectSnapshot;
        const line = self.raw[self.offset..end];
        self.offset = end + 1;
        return line;
    }
};

pub const Snapshot = struct {
    allocator: A,
    raw: []const u8,
    registry: *const Registry,
    rows: []const Row,
    sql_sha256: [32]u8,

    /// The caller keeps raw and registry immutable and at stable addresses
    /// until deinit. Headers bind this snapshot to that registry's edition.
    pub fn init(a: A, raw: []const u8, registry: *const Registry) !Snapshot {
        if (raw.len == 0 or raw.len > max_bytes or raw[raw.len - 1] != '\n') return error.InvalidPageRedirectSnapshot;
        var lines: Lines = .{ .raw = raw };
        if (!std.mem.eql(u8, try lines.next(), header)) return error.InvalidPageRedirectSnapshot;
        try identity(try lines.next(), "# wiki\t", registry.wiki);
        const date_line = try lines.next();
        try identity(date_line, "# dump-date\t", registry.dump_date);
        const date = date_line["# dump-date\t".len..];
        if (date.len != 8) return error.InvalidPageRedirectSnapshot;
        for (date) |byte| if (byte < '0' or byte > '9') return error.InvalidPageRedirectSnapshot;
        const hash_line = try lines.next();
        const hash_prefix = "# sql-sha256\t";
        if (!std.mem.startsWith(u8, hash_line, hash_prefix)) return error.InvalidPageRedirectSnapshot;
        const hash = hash_line[hash_prefix.len..];
        if (hash.len != 64) return error.InvalidPageRedirectSnapshot;
        for (hash) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidPageRedirectSnapshot;
        var sql_sha256: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&sql_sha256, hash) catch return error.InvalidPageRedirectSnapshot;

        var rows: std.ArrayList(Row) = .empty;
        errdefer rows.deinit(a);
        while (lines.offset < raw.len) {
            const offset = lines.offset;
            const line = try lines.next();
            const footer = "# end\t";
            if (std.mem.startsWith(u8, line, footer)) {
                const count = try decimal(u64, line[footer.len..], true);
                if (count != rows.items.len or lines.offset != raw.len) return error.InvalidPageRedirectSnapshot;
                return .{ .allocator = a, .raw = raw, .registry = registry, .rows = try rows.toOwnedSlice(a), .sql_sha256 = sql_sha256 };
            }
            const fields = try parseFields(line);
            if (registry.byId(fields.namespace) == null) return error.UnknownNamespace;
            if (rows.items.len != 0 and rows.items[rows.items.len - 1].id >= fields.id) return error.InvalidPageRedirectSnapshot;
            if (rows.items.len == max_rows) return error.InvalidPageRedirectSnapshot;
            try rows.append(a, .{ .id = fields.id, .offset = offset });
        }
        return error.InvalidPageRedirectSnapshot;
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.rows);
        self.* = undefined;
    }

    /// SQL rd_title is a DB key: replace underscores by spaces only. No
    /// normalization, capitalization, entity decoding or fragment rewriting.
    pub fn lookup(self: *const Snapshot, a: A, page_id: u64, xml_target: []const u8) !Target {
        var lo: usize = 0;
        var hi = self.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rows[mid].id < page_id) lo = mid + 1 else hi = mid;
        }
        if (lo == self.rows.len or self.rows[lo].id != page_id) return error.PageRedirectSnapshotMissing;
        var lines: Lines = .{ .raw = self.raw, .offset = self.rows[lo].offset };
        const fields = try parseFields(try lines.next());
        if (fields.id != page_id) return error.InvalidPageRedirectSnapshot;
        const spec = self.registry.byId(fields.namespace) orelse return error.UnknownNamespace;
        const interwiki = try decodeHex(a, fields.interwiki_hex);
        errdefer a.free(interwiki);
        var at: usize = 0;
        if (interwiki.len != 0) {
            try matchBytes(xml_target, &at, interwiki);
            try matchBytes(xml_target, &at, ":");
        }
        if (fields.namespace != 0) {
            try matchBytes(xml_target, &at, spec.name);
            try matchBytes(xml_target, &at, ":");
        }
        var hex_at: usize = 0;
        while (hex_at < fields.title_hex.len) : (hex_at += 2) {
            const byte = try hexByte(fields.title_hex[hex_at..][0..2]);
            const normalized = if (byte == '_') @as(u8, ' ') else byte;
            if (at == xml_target.len or xml_target[at] != normalized) return error.PageRedirectTargetMismatch;
            at += 1;
        }
        if (at != xml_target.len) return error.PageRedirectTargetMismatch;
        const title = try a.dupe(u8, xml_target);
        errdefer a.free(title);
        const fragment = try decodeHex(a, fields.fragment_hex);
        return .{ .namespace = fields.namespace, .title = title, .fragment = fragment, .interwiki = interwiki };
    }
};

fn identity(line: []const u8, prefix: []const u8, expected: []const u8) !void {
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidPageRedirectSnapshot;
    const value = line[prefix.len..];
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "\t\r\x00") != null) return error.InvalidPageRedirectSnapshot;
    if (!std.mem.eql(u8, value, expected)) return error.PageRedirectIdentityMismatch;
}

fn decimal(comptime T: type, value: []const u8, allow_zero: bool) !T {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidPageRedirectSnapshot;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidPageRedirectSnapshot;
    const result = std.fmt.parseInt(T, value, 10) catch return error.InvalidPageRedirectSnapshot;
    if (!allow_zero and result == 0) return error.InvalidPageRedirectSnapshot;
    return result;
}

fn namespaceId(value: []const u8) !i32 {
    if (value.len == 0) return error.InvalidPageRedirectSnapshot;
    const negative = value[0] == '-';
    const magnitude = try decimal(u32, if (negative) value[1..] else value, true);
    if (negative and magnitude == 0) return error.InvalidPageRedirectSnapshot;
    return std.fmt.parseInt(i32, value, 10) catch return error.InvalidPageRedirectSnapshot;
}

fn parseFields(line: []const u8) !Fields {
    var columns = std.mem.splitScalar(u8, line, '\t');
    const fields: Fields = .{
        .id = try decimal(u64, columns.next() orelse return error.InvalidPageRedirectSnapshot, false),
        .namespace = try namespaceId(columns.next() orelse return error.InvalidPageRedirectSnapshot),
        .title_hex = columns.next() orelse return error.InvalidPageRedirectSnapshot,
        .interwiki_hex = columns.next() orelse return error.InvalidPageRedirectSnapshot,
        .fragment_hex = columns.next() orelse return error.InvalidPageRedirectSnapshot,
    };
    if (columns.next() != null or fields.title_hex.len == 0 or fields.title_hex.len > 4096 * 2 or
        fields.interwiki_hex.len > 255 * 2 or fields.fragment_hex.len > 255 * 2) return error.InvalidPageRedirectSnapshot;
    try validateHex(fields.title_hex);
    try validateHex(fields.interwiki_hex);
    try validateHex(fields.fragment_hex);
    return fields;
}

fn nibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.InvalidPageRedirectSnapshot,
    };
}

fn hexByte(bytes: *const [2]u8) !u8 {
    return (try nibble(bytes[0])) * 16 + try nibble(bytes[1]);
}

/// Validate all decoded UTF-8 using constant stack space, without retaining
/// decoded strings or allocating a transient buffer for each SQL row.
fn validateHex(encoded: []const u8) !void {
    if (encoded.len % 2 != 0) return error.InvalidPageRedirectSnapshot;
    var at: usize = 0;
    while (at < encoded.len) {
        var bytes: [4]u8 = undefined;
        bytes[0] = try hexByte(encoded[at..][0..2]);
        if (bytes[0] == 0) return error.InvalidPageRedirectSnapshot;
        const n: usize = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return error.InvalidPageRedirectSnapshot;
        if (n > (encoded.len - at) / 2) return error.InvalidPageRedirectSnapshot;
        for (1..n) |i| bytes[i] = try hexByte(encoded[at + 2 * i ..][0..2]);
        _ = std.unicode.utf8Decode(bytes[0..n]) catch return error.InvalidPageRedirectSnapshot;
        at += n * 2;
    }
}

fn decodeHex(a: A, encoded: []const u8) ![]u8 {
    const decoded = try a.alloc(u8, encoded.len / 2);
    errdefer a.free(decoded);
    for (decoded, 0..) |*byte, i| byte.* = try hexByte(encoded[i * 2 ..][0..2]);
    return decoded;
}

fn matchBytes(xml: []const u8, at: *usize, expected: []const u8) !void {
    if (expected.len > xml.len - at.* or !std.mem.eql(u8, xml[at.*..][0..expected.len], expected)) return error.PageRedirectTargetMismatch;
    at.* += expected.len;
}

const registry_fixture = "# wikidict-namespace-registry-v1\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n" ++
    "-1\tSpezial\tSpecial\tfirst-letter\t0\t0\t1\twikitext\tcompile_only\tinput\n" ++
    "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
    "10\tVorlage\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
    "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n";
const snapshot_header = header ++ "\n# wiki\tdewiktionary\n# dump-date\t20261001\n# sql-sha256\t0000000000000000000000000000000000000000000000000000000000000000\n";
const snapshot_fixture = snapshot_header ++
    "5\t0\t616c7068615f62657461\t\t65cc815f26616d7023\n" ++
    "12\t10\t73686f772d666f726d73\t\t4e6f756e\n" ++
    "19\t0\t436174\t77\t50617274\n" ++
    "20\t-1\t526563656e744368616e676573\t\t\n" ++
    "30\t0\t43616665cc81\t\t\n" ++
    "# end\t5\n";

test "redirect SQL snapshot retains exact fragments and checks full XML identity" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, registry_fixture);
    defer registry.deinit();
    var snapshot = try Snapshot.init(a, snapshot_fixture, &registry);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 5), snapshot.rows.len);
    try std.testing.expectEqual(@intFromPtr(@as([]const u8, snapshot_fixture).ptr), @intFromPtr(snapshot.raw.ptr));
    var main = try snapshot.lookup(a, 5, "alpha beta");
    defer main.deinit(a);
    try std.testing.expectEqualStrings("alpha beta", main.title);
    try std.testing.expectEqualStrings("e\u{301}_&amp#", main.fragment);
    try std.testing.expectEqualStrings("", main.interwiki);
    var template = try snapshot.lookup(a, 12, "Vorlage:show-forms");
    defer template.deinit(a);
    try std.testing.expectEqual(@as(i32, 10), template.namespace);
    try std.testing.expectEqualStrings("Noun", template.fragment);
    var external = try snapshot.lookup(a, 19, "w:Cat");
    defer external.deinit(a);
    try std.testing.expectEqualStrings("w", external.interwiki);
    try std.testing.expectEqualStrings("Part", external.fragment);
    var special = try snapshot.lookup(a, 20, "Spezial:RecentChanges");
    defer special.deinit(a);
    try std.testing.expectEqual(@as(i32, -1), special.namespace);
    var decomposed = try snapshot.lookup(a, 30, "Cafe\u{301}");
    defer decomposed.deinit(a);
    try std.testing.expectEqualStrings("Cafe\u{301}", decomposed.title);
    try std.testing.expectError(error.PageRedirectTargetMismatch, snapshot.lookup(a, 30, "Café"));
    for ([_][]const u8{ "Template:show-forms", "Vorlage:Show-forms", "Vorlage:show-forms#Noun", "Vorlage:show_forms" }) |wrong|
        try std.testing.expectError(error.PageRedirectTargetMismatch, snapshot.lookup(a, 12, wrong));
    try std.testing.expectError(error.PageRedirectSnapshotMissing, snapshot.lookup(a, 11, "anything"));
}

test "redirect SQL snapshot rejects malformed framing ordering and decoded fields" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, registry_fixture);
    defer registry.deinit();
    const invalid = [_][]const u8{
        snapshot_header,
        snapshot_header ++ "# end\t0",
        snapshot_header ++ "# end\t0\n\n",
        snapshot_header ++ "# end\t0\n1\t0\t41\t\t\n",
        snapshot_header ++ "# end\t1\n",
        snapshot_header ++ "# end\t00\n",
        snapshot_header ++ "1\t0\t41\t\t\n# end\t0\n",
        snapshot_header ++ "1\t0\t41\t\t\n1\t0\t42\t\t\n# end\t2\n",
        snapshot_header ++ "2\t0\t41\t\t\n1\t0\t42\t\t\n# end\t2\n",
        snapshot_header ++ "0\t0\t41\t\t\n# end\t1\n",
        snapshot_header ++ "01\t0\t41\t\t\n# end\t1\n",
        snapshot_header ++ "+1\t0\t41\t\t\n# end\t1\n",
        snapshot_header ++ "1\t-0\t41\t\t\n# end\t1\n",
        snapshot_header ++ "1\t2147483648\t41\t\t\n# end\t1\n",
        snapshot_header ++ "18446744073709551616\t0\t41\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\t41\t\textra\tfield\n# end\t1\n",
        snapshot_header ++ "1\t0\t\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\t4\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\tgg\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\tAA\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\t00\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\tc080\t\t\n# end\t1\n",
        snapshot_header ++ "1\t0\t41\t80\t\n# end\t1\n",
        snapshot_header ++ "1\t0\t41\t\teda080\n# end\t1\n",
        snapshot_header ++ "1\t0\t41\t\tf4908080\n# end\t1\n",
    };
    for (invalid) |raw| try std.testing.expectError(error.InvalidPageRedirectSnapshot, Snapshot.init(a, raw, &registry));
    try std.testing.expectError(error.UnknownNamespace, Snapshot.init(a, snapshot_header ++ "1\t999\t41\t\t\n# end\t1\n", &registry));
    const changed = try a.dupe(u8, snapshot_fixture);
    defer a.free(changed);
    changed[std.mem.indexOf(u8, changed, "dewiktionary").?] = 'x';
    try std.testing.expectError(error.PageRedirectIdentityMismatch, Snapshot.init(a, changed, &registry));
    @memcpy(changed, snapshot_fixture);
    changed[std.mem.indexOf(u8, changed, "20261001").? + 7] = '2';
    try std.testing.expectError(error.PageRedirectIdentityMismatch, Snapshot.init(a, changed, &registry));
    @memcpy(changed, snapshot_fixture);
    changed[std.mem.indexOf(u8, changed, "# sql-sha256\t").? + "# sql-sha256\t".len] = 'A';
    try std.testing.expectError(error.InvalidPageRedirectSnapshot, Snapshot.init(a, changed, &registry));
    var empty = try Snapshot.init(a, snapshot_header ++ "# end\t0\n", &registry);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.rows.len);
    const fragment_hex: [512]u8 = @splat('6');
    const oversized = try std.fmt.allocPrint(a, "{s}1\t0\t41\t\t{s}\n# end\t1\n", .{ snapshot_header, &fragment_hex });
    defer a.free(oversized);
    try std.testing.expectError(error.InvalidPageRedirectSnapshot, Snapshot.init(a, oversized, &registry));
    const boundary_raw = try std.fmt.allocPrint(a, "{s}1\t0\t41\t\t{s}\n# end\t1\n", .{ snapshot_header, fragment_hex[0..510] });
    defer a.free(boundary_raw);
    var boundary = try Snapshot.init(a, boundary_raw, &registry);
    defer boundary.deinit();
    var target = try boundary.lookup(a, 1, "A");
    defer target.deinit(a);
    try std.testing.expectEqual(@as(usize, 255), target.fragment.len);
}

test "redirect SQL snapshot allocation failures release index and selected fields" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, registry_fixture);
    defer registry.deinit();
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(backing: A, namespaces: *const Registry) !void {
            var snapshot = try Snapshot.init(backing, snapshot_fixture, namespaces);
            defer snapshot.deinit();
            var target = try snapshot.lookup(backing, 19, "w:Cat");
            defer target.deinit(backing);
        }
    }.run, .{&registry});
}
