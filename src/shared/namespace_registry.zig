//! Immutable, edition-local namespace facts. No English ID or alias guesses.
//! All names are owned by the registry; callers own normalized title results.
const std = @import("std");
pub const magic_words = @import("magic_words.zig");
pub const page_redirects = @import("page_redirects.zig");
const lower = @import("unicode_lower");
const title_case = @import("title_case.zig");

pub const Role = enum { main, compile_only, supplemental, rhymes, thesaurus, citations, sign_gloss, reconstruction };
pub const Spec = struct {
    id: i32,
    name: []const u8,
    canonical_name: []const u8,
    is_capitalized: bool,
    has_subpages: bool,
    is_content: bool,
    is_includable: bool,
    default_content_model: []const u8,
    role: Role,
    reason: []const u8,
    aliases: []const []const u8,
};
const Alias = struct { key: []const u8, index: usize };
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    source_sha256: [32]u8,
    mapper: title_case.Mapper,
    wiki: []const u8,
    dump_date: []const u8,
    content_language: []const u8,
    entries: []const Spec,
    names: []const Alias,

    pub fn load(io: std.Io, a: std.mem.Allocator, root: []const u8) !Registry {
        const path = try std.fs.path.join(a, &.{ root, "namespace-registry.tsv" });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        defer a.free(bytes);
        return init(a, bytes);
    }
    pub fn init(backing: std.mem.Allocator, raw: []const u8) !Registry {
        if (raw.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidNamespaceRegistry;
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const bytes = try a.dupe(u8, raw);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", "# wikidict-namespace-registry-v1")) return error.InvalidNamespaceRegistry;
        const wiki = try header(&lines, "# wiki\t");
        const date = try header(&lines, "# dump-date\t");
        const language = try header(&lines, "# content-language\t");
        var mapper = try title_case.Mapper.init();
        errdefer mapper.deinit();
        var entries: std.ArrayList(Spec) = .empty;
        var names: std.ArrayList(Alias) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0) {
                if (lines.peek() != null) return error.InvalidNamespaceRegistry;
                break;
            }
            var columns = std.mem.splitScalar(u8, line, '\t');
            const id = std.fmt.parseInt(i32, columns.next() orelse return error.InvalidNamespaceRegistry, 10) catch return error.InvalidNamespaceRegistry;
            if (entries.items.len > 0 and entries.items[entries.items.len - 1].id >= id) return error.InvalidNamespaceRegistry;
            const name = try column(&columns);
            const canonical = try column(&columns);
            if ((id == 0) != (name.len == 0) or (id == 0) != (canonical.len == 0)) return error.InvalidNamespaceRegistry;
            const case = try column(&columns);
            const capitalized = if (std.mem.eql(u8, case, "first-letter")) true else if (std.mem.eql(u8, case, "case-sensitive")) false else return error.InvalidNamespaceRegistry;
            const subpages = try boolean(&columns);
            const content = try boolean(&columns);
            const nonincludable = try boolean(&columns);
            const model = try column(&columns);
            const role = std.meta.stringToEnum(Role, try column(&columns)) orelse return error.InvalidNamespaceRegistry;
            if ((id == 0) != (role == .main)) return error.InvalidNamespaceRegistry;
            const reason = try column(&columns);
            if (reason.len == 0) return error.InvalidNamespaceRegistry;
            var aliases: std.ArrayList([]const u8) = .empty;
            while (columns.peek() != null) {
                const alias = try column(&columns);
                if (alias.len == 0) return error.InvalidNamespaceRegistry;
                try aliases.append(a, alias);
            }
            const index = entries.items.len;
            try entries.append(a, .{ .id = id, .name = name, .canonical_name = canonical, .is_capitalized = capitalized, .has_subpages = subpages, .is_content = content, .is_includable = !nonincludable, .default_content_model = model, .role = role, .reason = reason, .aliases = try aliases.toOwnedSlice(a) });
            for ([_][]const u8{ name, canonical }) |alias| try addName(a, &mapper, &names, alias, index);
            for (entries.items[index].aliases) |alias| try addName(a, &mapper, &names, alias, index);
        }
        if (entries.items.len == 0) return error.InvalidNamespaceRegistry;
        std.mem.sort(Alias, names.items, {}, struct {
            fn less(_: void, lhs: Alias, rhs: Alias) bool {
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        }.less);
        var count: usize = 0;
        for (names.items) |alias| {
            if (count > 0 and std.mem.eql(u8, names.items[count - 1].key, alias.key)) {
                if (names.items[count - 1].index != alias.index) return error.AmbiguousNamespaceAlias;
            } else {
                names.items[count] = alias;
                count += 1;
            }
        }
        names.items.len = count;
        var source_sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &source_sha256, .{});
        const result: Registry = .{ .arena = arena, .source_sha256 = source_sha256, .mapper = mapper, .wiki = wiki, .dump_date = date, .content_language = language, .entries = try entries.toOwnedSlice(a), .names = try names.toOwnedSlice(a) };
        for ([_]i32{ 0, 10, 14 }) |id| if (result.byId(id) == null) return error.InvalidNamespaceRegistry;
        return result;
    }
    pub fn deinit(self: *Registry) void {
        self.mapper.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn byId(self: *const Registry, id: i32) ?Spec {
        var lo: usize = 0;
        var hi = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const spec = self.entries[mid];
            if (spec.id < id) lo = mid + 1 else if (spec.id > id) hi = mid else return spec;
        }
        return null;
    }
    pub fn byName(self: *const Registry, raw: []const u8) ?Spec {
        var normalized: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&normalized);
        normalizeSpacing(&w, raw) catch return null;
        var lowered: [8192]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&lowered);
        var nfc_storage: [4097]i32 = undefined;
        const normalized_prefix = self.mapper.nfcInto(w.buffered(), &nfc_storage) catch return null;
        lower.writeLower(&lw, normalized_prefix) catch return null;
        const key = lw.buffered();
        var lo: usize = 0;
        var hi = self.names.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const alias = self.names[mid];
            switch (std.mem.order(u8, alias.key, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.entries[alias.index],
            }
        }
        return null;
    }
    pub fn subjectSpec(self: *const Registry, id: i32) ?Spec {
        const spec = self.byId(id) orelse return null;
        return if (id > 0 and @mod(id, 2) == 1) self.byId(id - 1) orelse spec else spec;
    }
    pub fn talkSpec(self: *const Registry, id: i32) ?Spec {
        if (id < 0 or self.byId(id) == null) return null;
        return self.byId(if (@mod(id, 2) == 1) id else id + 1);
    }
    pub fn ofTitle(self: *const Registry, title: []const u8) struct { id: i32, name: []const u8, text: []const u8 } {
        if (std.mem.indexOfScalar(u8, title, ':')) |colon| {
            if (self.byName(title[0..colon])) |spec| return .{ .id = spec.id, .name = spec.name, .text = title[colon + 1 ..] };
        }
        return .{ .id = 0, .name = "", .text = title };
    }
    pub fn normalizeTransclusion(self: *const Registry, a: std.mem.Allocator, raw: []const u8, host_title: ?[]const u8) ![]u8 {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0) return error.InvalidPageTitle;
        if (name[0] == '/') if (host_title) |host| {
            const base = try self.normalizeTitle(a, host, 0, .any);
            defer a.free(base);
            const spec = self.byId(self.ofTitle(base).id) orelse return error.UnknownNamespace;
            if (spec.has_subpages) {
                const combined = try std.mem.concat(a, u8, &.{ base, name });
                defer a.free(combined);
                return self.normalizeTitle(a, combined, 0, .any);
            }
        };
        return self.normalizeTitle(a, name, 10, .any);
    }

    /// Lua require/loadData are full module titles, unlike bare #invoke names.
    pub fn normalizeModuleLoader(self: *const Registry, a: std.mem.Allocator, raw: []const u8) !?[]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
        const spec = self.byName(trimmed[0..colon]) orelse return null;
        if (spec.id != 828) return null;
        return self.normalizeTitle(a, trimmed, 828, .only_default) catch |err| switch (err) {
            error.InvalidPageTitle, error.InvalidUtf8 => null,
            else => return err,
        };
    }
    pub const PrefixPolicy = enum { any, only_default, literal };
    /// Template transclusions use default=10/any; invoke/loader uses 828/only_default.
    /// A recognized prefix is removed exactly once. Unknown colons stay in suffix.
    pub fn normalizeTitle(self: *const Registry, a: std.mem.Allocator, raw: []const u8, default_id: i32, policy: PrefixPolicy) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        defer w.deinit();
        const nfc = try self.mapper.nfcAlloc(a, raw);
        defer a.free(nfc);
        normalizeSpacing(&w.writer, nfc) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        var suffix: []const u8 = w.written();
        var spec = self.byId(default_id) orelse return error.UnknownNamespace;
        if (policy == .any and std.mem.startsWith(u8, suffix, ":")) {
            spec = self.byId(0).?;
            suffix = std.mem.trim(u8, suffix[1..], " ");
        }
        if (policy != .literal) {
            if (std.mem.indexOfScalar(u8, suffix, ':')) |colon| {
                if (self.byName(suffix[0..colon])) |found| {
                    if (policy == .any or found.id == default_id) {
                        spec = found;
                        suffix = std.mem.trim(u8, suffix[colon + 1 ..], " ");
                    }
                }
            }
        }
        if (suffix.len == 0) return error.InvalidPageTitle;
        const text = if (spec.is_capitalized) try self.mapper.firstAlloc(a, suffix) else try a.dupe(u8, suffix);
        defer a.free(text);
        return if (spec.id == 0) a.dupe(u8, text) else std.fmt.allocPrint(a, "{s}:{s}", .{ spec.name, text });
    }
};

fn header(lines: *std.mem.SplitIterator(u8, .scalar), prefix: []const u8) ![]const u8 {
    const line = lines.next() orelse return error.InvalidNamespaceRegistry;
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidNamespaceRegistry;
    const value = line[prefix.len..];
    try validateField(value);
    if (value.len == 0) return error.InvalidNamespaceRegistry;
    return value;
}
fn validateField(value: []const u8) !void {
    if (value.len > 1024 or std.mem.indexOfAny(u8, value, "\t\r\n\x00") != null) return error.InvalidNamespaceRegistry;
}
fn column(columns: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
    const value = columns.next() orelse return error.InvalidNamespaceRegistry;
    try validateField(value);
    return value;
}
fn boolean(columns: *std.mem.SplitIterator(u8, .scalar)) !bool {
    const value = try column(columns);
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.InvalidNamespaceRegistry;
}
fn addName(a: std.mem.Allocator, mapper: *const title_case.Mapper, names: *std.ArrayList(Alias), raw: []const u8, index: usize) !void {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    normalizeSpacing(&w.writer, raw) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    if (raw.len != 0 and w.written().len == 0) return error.InvalidNamespaceRegistry;
    const normalized = try mapper.nfcAlloc(a, w.written());
    defer a.free(normalized);
    try names.append(a, .{ .key = try lower.lowerAlloc(a, normalized), .index = index });
}
pub fn normalizeSpacing(w: *std.Io.Writer, raw: []const u8) !void {
    var it = (std.unicode.Utf8View.init(raw) catch return error.InvalidPageTitle).iterator();
    var present = false;
    var pending = false;
    while (it.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        if (cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e)) continue;
        const space = cp == ' ' or cp == '_' or cp == '\t' or cp == '\r' or cp == '\n' or cp == 0xa0 or cp == 0x1680 or cp == 0x180e or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000;
        if (space) {
            pending = present;
            continue;
        }
        if (pending) try w.writeByte(' ');
        pending = false;
        present = true;
        try w.writeAll(bytes);
    }
}

const fixture = "# wikidict-namespace-registry-v1\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n" ++
    "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
    "2\tBenutzer\tUser\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tinput\n" ++
    "10\tVorlage\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\tV\n" ++
    "14\tKategorie\tCategory\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n" ++
    "106\tReim\tReim\tcase-sensitive\t1\t0\t0\twikitext\trhymes\tverified\n" ++
    "828\tModul\tModule\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tinput\tMÓD\n";

test "edition namespace aliases and title identity" {
    var registry = try Registry.init(std.testing.allocator, fixture);
    defer registry.deinit();
    try std.testing.expectEqual(@as(i32, 828), registry.byName("mód").?.id);
    try std.testing.expectEqual(@as(i32, 106), registry.byName("REIM").?.id);
    try std.testing.expect(registry.byName("Rhymes") == null);
    const cases = .{ .{ "Vorlage:Foo", "Template:Foo", 10, Registry.PrefixPolicy.any }, .{ "Vorlage:foo", "foo", 10, Registry.PrefixPolicy.any }, .{ "Vorlage:Template:nested", "Template:Template:nested", 10, Registry.PrefixPolicy.any }, .{ "Modul:foo", "MÓD:foo", 828, Registry.PrefixPolicy.only_default }, .{ "Vorlage:unknown:name", "unknown:name", 10, Registry.PrefixPolicy.any }, .{ "Kategorie:x", "Category:x", 10, Registry.PrefixPolicy.any }, .{ "plain", ":plain", 10, Registry.PrefixPolicy.any }, .{ "Benutzer:École", "User:école", 0, Registry.PrefixPolicy.any } };
    inline for (cases) |c| {
        const actual = try registry.normalizeTitle(std.testing.allocator, c[1], c[2], c[3]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(c[0], actual);
    }
}
test "ambiguous aliases and malformed records fail closed" {
    try std.testing.expectError(error.AmbiguousNamespaceAlias, Registry.init(std.testing.allocator, fixture ++ "830\tOther\tOther\tcase-sensitive\t0\t0\t0\twikitext\tsupplemental\tunknown\tTemplate\n"));
    try std.testing.expectError(error.InvalidNamespaceRegistry, Registry.init(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidNamespaceRegistry, Registry.init(std.testing.allocator, fixture ++ "1\tBad\tBad\tcase-sensitive\t0\t0\t0\twikitext\tcompile_only\tinput\n"));
}
test "registry allocation failures are cleaned up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var registry = try Registry.init(a, fixture);
            defer registry.deinit();
        }
    }.run, .{});
}

// Explicit fixture for synthetic compiler tests; never an edition fallback.
pub const english_test_fixture = @embedFile("fixtures/en-namespace-registry.tsv");

/// Process-lifetime immutable fixture for synthetic unit-test Contexts only.
/// Production Contexts must receive their owning Program's verified registry.
pub fn englishTestRegistry() !*const Registry {
    if (!@import("builtin").is_test) @compileError("test registry is not a production fallback");
    const State = struct {
        var registry: Registry = undefined;
        var failure: ?anyerror = null;
        var status = std.atomic.Value(u8).init(0);
        fn initialize() void {
            registry = Registry.init(std.heap.page_allocator, english_test_fixture) catch |err| {
                failure = err;
                return;
            };
        }
    };
    if (State.status.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        State.initialize();
        State.status.store(2, .release);
    } else while (State.status.load(.acquire) != 2) std.atomic.spinLoopHint();
    if (State.failure) |err| return err;
    return &State.registry;
}

pub const french_test_fixture = @embedFile("fixtures/fr-namespace-registry.tsv");

test "NFC leading colons and relative transclusion names share one identity" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, fixture);
    defer registry.deinit();
    const full = try registry.normalizeTitle(a, ":Template:cafe\u{301}", 10, .any);
    defer a.free(full);
    try std.testing.expectEqualStrings("Vorlage:café", full);
    const child = try registry.normalizeTransclusion(a, "/Child", "Vorlage:Parent");
    defer a.free(child);
    try std.testing.expectEqualStrings("Vorlage:Parent/Child", child);
    const literal = try registry.normalizeTransclusion(a, "/Child", "word");
    defer a.free(literal);
    try std.testing.expectEqualStrings("Vorlage:/Child", literal);
}

test "qualified loaders never shadow bare builtins or other namespaces" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, fixture);
    defer registry.deinit();
    for ([_][]const u8{ "math", "strict", "foo", ":Module:foo", "User:foo", "Unknown:foo", "Module:", "" }) |raw|
        try std.testing.expect((try registry.normalizeModuleLoader(a, raw)) == null);
    const actual = (try registry.normalizeModuleLoader(a, "  mód:cafe\u{301}_small  ")).?;
    defer a.free(actual);
    try std.testing.expectEqualStrings("Modul:café small", actual);
    const nested = (try registry.normalizeModuleLoader(a, "Module:User:foo")).?;
    defer a.free(nested);
    try std.testing.expectEqualStrings("Modul:User:foo", nested);
}

test "Chinese module case policy applies only to the first codepoint" {
    const a = std.testing.allocator;
    var registry = try Registry.init(a, @embedFile("fixtures/zh-namespace-registry.tsv"));
    defer registry.deinit();
    try std.testing.expect(registry.byId(828).?.is_capitalized);
    const title = try registry.normalizeTitle(a, "Module:fooBar", 828, .only_default);
    defer a.free(title);
    const parsed = registry.ofTitle(title);
    try std.testing.expectEqual(@as(i32, 828), parsed.id);
    try std.testing.expectEqualStrings("FooBar", parsed.text);
    const main = try registry.normalizeTitle(a, "fooBar", 0, .any);
    defer a.free(main);
    try std.testing.expectEqualStrings("fooBar", main);
}

pub const german_test_fixture = @embedFile("fixtures/de-namespace-registry.tsv");
