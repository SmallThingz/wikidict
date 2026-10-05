//! Immutable, explicitly complete captured language-name profiles.
const std = @import("std");
const Provider = @import("lua_program").WikitextProvider;
pub const Row = Provider.LanguageNameRow;
pub const Scope = Provider.LanguageNameScope;
pub const Direction = Provider.LanguageDirection;
const A = std.mem.Allocator;
const Profile = struct {
    expected: usize,
    rows: std.ArrayList(Row) = .empty,
    index: std.StringHashMapUnmanaged([]const u8) = .empty,
};

fn header(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8, value: []const u8) !void {
    const line = lines.next() orelse return error.InvalidLanguageNameSnapshot;
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.eql(u8, line[prefix.len..], value))
        return error.InvalidLanguageNameSnapshot;
}
fn codeValid(code: []const u8) bool {
    if (code.len < 2 or code.len > 128) return false;
    for (code) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}
fn kindValid(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "all") or std.mem.eql(u8, kind, "mw") or std.mem.eql(u8, kind, "single");
}
fn decodeName(a: A, raw: []const u8) ![]const u8 {
    if (raw.len > 8192 or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidLanguageNameSnapshot;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\') {
            try out.append(a, raw[i]);
            continue;
        }
        i += 1;
        if (i == raw.len) return error.InvalidLanguageNameSnapshot;
        try out.append(a, switch (raw[i]) {
            '\\' => '\\',
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            else => return error.InvalidLanguageNameSnapshot,
        });
    }
    if (out.items.len > 4096) return error.InvalidLanguageNameSnapshot;
    return try out.toOwnedSlice(a);
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    profiles: std.StringHashMapUnmanaged(Profile) = .empty,
    directions: std.StringHashMapUnmanaged(Direction) = .empty,
    direction_count: ?usize = null,

    pub fn init(allocator: A, bytes: []const u8, wiki: []const u8, date: []const u8, language: []const u8) !Registry {
        if (bytes.len > 32 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidLanguageNameSnapshot;
        var self: Registry = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        const source = try a.dupe(u8, bytes);
        var lines = std.mem.splitScalar(u8, source, '\n');
        try header(&lines, "", "# wikidict-language-names-v1");
        try header(&lines, "# wiki\t", wiki);
        try header(&lines, "# dump-date\t", date);
        try header(&lines, "# content-language\t", language);
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const row_kind = fields.next() orelse return error.InvalidLanguageNameSnapshot;
            if (std.mem.eql(u8, row_kind, "C")) {
                const display = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const kind = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const raw_count = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null) return error.InvalidLanguageNameSnapshot;
                const count = std.fmt.parseInt(usize, raw_count, 10) catch return error.InvalidLanguageNameSnapshot;
                // The capture allows 20,000 API codes plus its 31 pinned aliases.
                if (count > 20031) return error.InvalidLanguageNameSnapshot;
                if (std.mem.eql(u8, display, "-") and std.mem.eql(u8, kind, "dir")) {
                    if (self.direction_count != null) return error.DuplicateLanguageNameProfile;
                    self.direction_count = count;
                } else {
                    if (!codeValid(display) or !kindValid(kind) or self.profiles.count() >= 64) return error.InvalidLanguageNameSnapshot;
                    const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ display, kind });
                    const entry = try self.profiles.getOrPut(a, key);
                    if (entry.found_existing) return error.DuplicateLanguageNameProfile;
                    entry.value_ptr.* = .{ .expected = count };
                }
            } else if (std.mem.eql(u8, row_kind, "N")) {
                const display = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const kind = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const code = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const raw_name = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null or !codeValid(display) or !kindValid(kind) or !codeValid(code)) return error.InvalidLanguageNameSnapshot;
                var key_buffer: [144]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "{s}\t{s}", .{ display, kind });
                const profile = self.profiles.getPtr(key) orelse return error.IncompleteLanguageNameProfile;
                if (profile.rows.items.len >= profile.expected) return error.IncompleteLanguageNameProfile;
                const decoded_name = try decodeName(a, raw_name);
                if (decoded_name.len == 0 and !std.mem.eql(u8, kind, "single")) return error.InvalidLanguageNameSnapshot;
                const entry = try profile.index.getOrPut(a, code);
                if (entry.found_existing) return error.DuplicateLanguageName;
                entry.value_ptr.* = decoded_name;
                try profile.rows.append(a, .{ .code = code, .name = decoded_name });
            } else if (std.mem.eql(u8, row_kind, "D")) {
                const code = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                const value = fields.next() orelse return error.InvalidLanguageNameSnapshot;
                if (fields.next() != null or !codeValid(code) or self.direction_count == null) return error.InvalidLanguageNameSnapshot;
                const parsed_direction: Direction = if (std.mem.eql(u8, value, "ltr")) .ltr else if (std.mem.eql(u8, value, "rtl")) .rtl else return error.InvalidLanguageNameSnapshot;
                const entry = try self.directions.getOrPut(a, code);
                if (entry.found_existing) return error.DuplicateLanguageDirection;
                entry.value_ptr.* = parsed_direction;
            } else return error.InvalidLanguageNameSnapshot;
        }
        var profiles = self.profiles.valueIterator();
        while (profiles.next()) |profile| if (profile.rows.items.len != profile.expected) return error.IncompleteLanguageNameProfile;
        if (self.direction_count) |expected| if (self.directions.count() != expected) return error.IncompleteLanguageNameProfile;
        return self;
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }
    fn lookupProfile(self: *const Registry, display: ?[]const u8, kind: []const u8) !Profile {
        const language = display orelse return error.LanguageNameSnapshotMissing;
        if (language.len > 128) return error.LanguageNameSnapshotMissing;
        var key_buffer: [144]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "{s}\t{s}", .{ language, kind });
        return self.profiles.get(key) orelse error.LanguageNameSnapshotMissing;
    }
    pub fn names(self: *const Registry, display: ?[]const u8, scope: Scope) ![]const Row {
        return (try self.lookupProfile(display, @tagName(scope))).rows.items;
    }
    pub fn name(self: *const Registry, code: []const u8, display: ?[]const u8) ![]const u8 {
        const selected = try self.lookupProfile(display, "single");
        return selected.index.get(code) orelse "";
    }
    pub fn direction(self: *const Registry, code: []const u8) !Direction {
        return self.directions.get(code) orelse error.LanguageDirectionSnapshotMissing;
    }
};

const fixture = "# wikidict-language-names-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
    "C\tar\tall\t2\nN\tar\tall\tar\tالعربية\nN\tar\tall\tals\tAlemannic\n" ++
    "C\tar\tmw\t1\nN\tar\tmw\tar\tالعربية\n" ++
    "C\tar\tsingle\t2\nN\tar\tsingle\tar\tالعربية\nN\tar\tsingle\tals\tالألمانية السويسرية\n" ++
    "C\t-\tdir\t2\nD\tar\trtl\nD\ten\tltr\n";
fn allocationProbe(a: A) !void {
    var registry = try Registry.init(a, fixture, "arwiktionary", "20261001", "ar");
    defer registry.deinit();
    try std.testing.expectEqualStrings("Alemannic", (try registry.names("ar", .all))[1].name);
    try std.testing.expectEqualStrings("الألمانية السويسرية", try registry.name("als", "ar"));
    try std.testing.expectEqualStrings("", try registry.name("unknown", "ar"));
    try std.testing.expectEqual(Direction.rtl, try registry.direction("ar"));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, registry.names(null, .mw));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, registry.names("en", .all));
    try std.testing.expectError(error.LanguageNameSnapshotMissing, registry.names("ar", .mwfile));
    try std.testing.expectError(error.LanguageDirectionSnapshotMissing, registry.direction("zz"));
}
test "captured language profiles distinguish singular aliases and missing profiles with allocation cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
test "captured language profiles reject incomplete duplicate and foreign identity rows" {
    try std.testing.expectError(error.IncompleteLanguageNameProfile, Registry.init(std.testing.allocator, fixture ++ "C\ten\tall\t1\n", "arwiktionary", "20261001", "ar"));
    try std.testing.expectError(error.DuplicateLanguageNameProfile, Registry.init(std.testing.allocator, fixture ++ "C\tar\tall\t0\n", "arwiktionary", "20261001", "ar"));
    try std.testing.expectError(error.InvalidLanguageNameSnapshot, Registry.init(std.testing.allocator, fixture, "enwiktionary", "20261001", "en"));
    try std.testing.expectError(error.DuplicateLanguageDirection, Registry.init(std.testing.allocator, fixture ++ "D\tar\trtl\n", "arwiktionary", "20261001", "ar"));
}
