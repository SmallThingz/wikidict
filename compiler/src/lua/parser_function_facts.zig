//! Sparse, build-only observations for source-dependent parser functions.
const std = @import("std");
const A = std.mem.Allocator;
pub const max_bytes = 8 * 1024 * 1024;
pub const max_records = 65536;
pub const File = struct {
    title: []const u8,
    size_argument: []const u8,
    canonical_title: []const u8,
    exists: bool,
    url: []const u8,
    sha1: []const u8,
};
pub const Page = struct { title: []const u8, namespace: i32, page_id: u64, revision_id: u64, size: u64 };
pub const Format = struct { raw: u64, formatted: []const u8 };
// Language::formatNum at source-identical f458/714 casts through float. Preserve exact integer
// semantics only through 2^53-1; larger explicitly observed values still work.
pub const integer_format_profile = "mw-714-hu-latn-integer-v1";
pub const integer_format_core = "7140a34a88ee294f3b4d8cda0c4f43a880410e20";
pub const hu_wmf5_integer_format_profile = "mw-87f-hu-latn-integer-v1";
pub const hu_wmf5_integer_format_core = "87f311882d8c84ec21e288d0bde8aa289df8dc56";
const hu_wmf5_namespace_sha256 = "68c76ee3cf6c32dcbccccd6afa6be303d4066e78b08eb9fd96fc06bb82c2d3cf";
const hu_wmf5_site_info_sha256 = "60661fb85446842ab46e689307488a4ea9c9b9246810da5eb59dbe8415c78ce8";
pub const max_exact_formatted_integer: u64 = 9_007_199_254_740_991;

fn formatProvenInteger(output: *[32]u8, raw: u64) ![]const u8 {
    if (raw > max_exact_formatted_integer) return error.PageSizeFormatSnapshotMissing;
    var buffer: [20]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buffer, "{d}", .{raw});
    const groups = (digits.len - 1) / 3;
    const result = output[0 .. digits.len + groups * 2];
    var position: usize = 0;
    for (digits, 0..) |digit, i| {
        if (i != 0 and (digits.len - i) % 3 == 0) {
            @memcpy(result[position..][0..2], "\u{a0}");
            position += 2;
        }
        result[position] = digit;
        position += 1;
    }
    return result;
}
const Document = struct {
    schema: []const u8,
    wiki: []const u8,
    date: []const u8,
    content_language: []const u8,
    namespace_sha256: []const u8,
    site_info_sha256: []const u8,
    files: []const File,
    pages: []const Page,
    formats: []const Format,
    number_format_profile: ?[]const u8 = null,
    number_format_witness_title: ?[]const u8 = null,
};
fn clean(value: []const u8, max: usize, empty: bool) bool {
    if ((!empty and value.len == 0) or value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
fn digestMatches(bytes: []const u8, expected: []const u8) bool {
    if (expected.len != 64) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, expected);
}
fn validUrl(value: []const u8) bool {
    if (!clean(value, 16384, false)) return false;
    const body = if (std.mem.startsWith(u8, value, "https://")) value[8..]
        else if (std.mem.startsWith(u8, value, "http://")) value[7..]
        else if (std.mem.startsWith(u8, value, "//")) value[2..]
        else return false;
    if (body.len == 0 or body[0] == '/') return false;
    for (value) |c| if (std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "<>\"'{}[]\\", c) != null) return false;
    return true;
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidParserFunctionFacts;
    return value.object.get(name) orelse error.InvalidParserFunctionFacts;
}
fn decodeDocument(a: A, value: std.json.Value) !Document {
    var total: usize = 0;
    inline for (.{ "files", "pages", "formats" }) |name| {
        const rows = try field(value, name);
        if (rows != .array or rows.array.items.len > max_records - total) return error.ParserFunctionFactsLimit;
        total += rows.array.items.len;
        for (rows.array.items) |row| {
            if (comptime std.mem.eql(u8, name, "pages")) {
                inline for (.{ "namespace", "page_id", "revision_id", "size" }) |key| {
                    const number = try field(row, key);
                    if (number != .integer or number.integer < 0) return error.InvalidParserFunctionFacts;
                }
            } else if (comptime std.mem.eql(u8, name, "formats")) {
                const number = try field(row, "raw");
                if (number != .integer or number.integer < 0) return error.InvalidParserFunctionFacts;
            } else {
                if (try field(row, "exists") != .bool) return error.InvalidParserFunctionFacts;
            }
        }
    }
    return std.json.parseFromValueLeaky(Document, a, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidParserFunctionFacts,
    };
}
pub const Snapshot = struct {
    a: A,
    parsed: std.json.Parsed(std.json.Value),
    document: Document,
    files: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(usize)) = .empty,
    pages: std.StringHashMapUnmanaged(usize) = .empty,
    formats: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    number_format_core: ?[]const u8 = null,

    pub fn init(a: A, bytes: []const u8, site: []const u8, namespace_sha: [32]u8, wiki: []const u8, date: []const u8, language: []const u8) !Snapshot {
        if (bytes.len > max_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidParserFunctionFacts;
        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidParserFunctionFacts,
        };
        // Check numeric token kinds before typed conversion, which otherwise
        // accepts quoted numbers. Keep the decoded document in the same arena.
        const d = decodeDocument(parsed.arena.allocator(), parsed.value) catch |err| {
            parsed.deinit();
            return err;
        };
        var result: Snapshot = .{ .a = a, .parsed = parsed, .document = d };
        errdefer result.deinit();
        if (!std.mem.eql(u8, d.schema, "wikidict.parser-function-facts.v1") or
            !std.mem.eql(u8, d.wiki, wiki) or !std.mem.eql(u8, d.date, date) or
            !std.mem.eql(u8, d.content_language, language) or !std.mem.eql(u8, d.namespace_sha256, &std.fmt.bytesToHex(namespace_sha, .lower)) or
            !digestMatches(site, d.site_info_sha256)) return error.ParserFunctionFactsIdentityMismatch;
        if (d.number_format_profile) |profile| {
            if (!std.mem.eql(u8, language, "hu")) return error.InvalidParserFunctionFormatProfile;
            result.number_format_core = if (std.mem.eql(u8, profile, integer_format_profile))
                integer_format_core
            else if (std.mem.eql(u8, profile, hu_wmf5_integer_format_profile) and
                std.mem.eql(u8, wiki, "huwiktionary") and std.mem.eql(u8, date, "20261001") and
                std.mem.eql(u8, d.namespace_sha256, hu_wmf5_namespace_sha256) and
                std.mem.eql(u8, d.site_info_sha256, hu_wmf5_site_info_sha256))
                hu_wmf5_integer_format_core
            else
                return error.InvalidParserFunctionFormatProfile;
            if (!clean(d.number_format_witness_title orelse return error.InvalidParserFunctionFormatProfile, 1024, false))
                return error.InvalidParserFunctionFormatProfile;
        } else if (d.number_format_witness_title != null) return error.InvalidParserFunctionFormatProfile;
        if (d.files.len > max_records or d.pages.len > max_records - d.files.len or d.formats.len > max_records - d.files.len - d.pages.len) return error.ParserFunctionFactsLimit;
        // File keys are tuples; never use separator-concatenation with authored titles.
        try result.files.ensureTotalCapacity(a, @intCast(d.files.len));
        for (d.files, 0..) |file_fact, i| {
            if (!clean(file_fact.title, 1024, false) or !clean(file_fact.size_argument, 1024, true)) return error.InvalidParserFunctionFacts;
            if (file_fact.exists) {
                if (!clean(file_fact.canonical_title, 1024, false) or !validUrl(file_fact.url) or file_fact.sha1.len != 40) return error.InvalidParserFunctionFacts;
                for (file_fact.sha1) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.InvalidParserFunctionFacts;
            } else if (file_fact.canonical_title.len != 0 or file_fact.url.len != 0 or file_fact.sha1.len != 0) return error.InvalidParserFunctionFacts;
            const by_title = try result.files.getOrPut(a, file_fact.title);
            if (!by_title.found_existing) by_title.value_ptr.* = .empty;
            const entry = try by_title.value_ptr.getOrPut(a, file_fact.size_argument);
            if (entry.found_existing) return error.DuplicateParserFunctionFact;
            entry.value_ptr.* = i;
        }
        try result.pages.ensureTotalCapacity(a, @intCast(d.pages.len));
        for (d.pages, 0..) |page_fact, i| {
            if (!clean(page_fact.title, 1024, false) or page_fact.namespace < 0 or page_fact.page_id == 0 or page_fact.revision_id == 0) return error.InvalidParserFunctionFacts;
            const entry = try result.pages.getOrPut(a, page_fact.title);
            if (entry.found_existing) return error.DuplicateParserFunctionFact;
            entry.value_ptr.* = i;
        }
        try result.formats.ensureTotalCapacity(a, @intCast(d.formats.len));
        for (d.formats, 0..) |format_fact, i| {
            if (!clean(format_fact.formatted, 1024, false)) return error.InvalidParserFunctionFacts;
            const entry = try result.formats.getOrPut(a, format_fact.raw);
            if (entry.found_existing) return error.DuplicateParserFunctionFact;
            entry.value_ptr.* = i;
        }
        return result;
    }
    pub fn deinit(self: *Snapshot) void {
        var files = self.files.valueIterator();
        while (files.next()) |entry| entry.deinit(self.a);
        self.files.deinit(self.a);
        self.pages.deinit(self.a);
        self.formats.deinit(self.a);
        self.parsed.deinit();
    }
    pub fn file(self: *const Snapshot, title: []const u8, size_argument: []const u8) ?File {
        const by_title = self.files.get(title) orelse return null;
        return self.document.files[by_title.get(size_argument) orelse return null];
    }
    pub fn page(self: *const Snapshot, title: []const u8) ?Page {
        return self.document.pages[self.pages.get(title) orelse return null];
    }
    pub fn format(self: *const Snapshot, raw: u64) ?[]const u8 {
        return self.document.formats[self.formats.get(raw) orelse return null].formatted;
    }

    // Observations remain snapshot-borrowed; computed strings belong to the
    // caller's page allocator. No per-call corpus-lived allocation or scratch
    // slice escapes, including when an observed value conflicts.
    pub fn formatPageSize(self: *const Snapshot, page_allocator: A, raw: u64, effective_host_language: ?[]const u8) ![]const u8 {
        const observed_value = self.format(raw);
        if (self.number_format_core != null and
            std.mem.eql(u8, effective_host_language orelse "", "hu") and raw <= max_exact_formatted_integer) {
            var buffer: [32]u8 = undefined;
            const derived = try formatProvenInteger(&buffer, raw);
            if (observed_value) |value| {
                if (!std.mem.eql(u8, value, derived)) return error.PageSizeFormatAuthorityConflict;
                return value;
            }
            return try page_allocator.dupe(u8, derived);
        }
        return observed_value orelse error.PageSizeFormatSnapshotMissing;
    }
};

const FactsTest = struct {
    const site = "exact test site bytes";
    const ns: [32]u8 = @splat(0x12);
    fn fixture(a: A) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(site, &digest, .{});
        const ns_hex = std.fmt.bytesToHex(ns, .lower);
        const site_hex = std.fmt.bytesToHex(digest, .lower);
        return std.json.Stringify.valueAlloc(a, .{
            .schema = "wikidict.parser-function-facts.v1", .wiki = "testwiktionary", .date = "20261001", .content_language = "test",
            .namespace_sha256 = ns_hex[0..], .site_info_sha256 = site_hex[0..],
            .files = [_]File{
                .{ .title = "File:A.svg", .size_argument = "", .canonical_title = "File:A.svg", .exists = true, .url = "https://media.example/A.svg", .sha1 = "0123456789012345678901234567890123456789" },
                .{ .title = "File:A.svg", .size_argument = "100", .canonical_title = "File:A.svg", .exists = true, .url = "//media.example/thumb/A.svg/100px-A.svg.png", .sha1 = "0123456789012345678901234567890123456789" },
                .{ .title = "File:Absent.svg", .size_argument = "", .canonical_title = "", .exists = false, .url = "", .sha1 = "" },
            },
            .pages = [_]Page{.{ .title = "Page", .namespace = 0, .page_id = 42, .revision_id = 420, .size = 1234 }},
            .formats = [_]Format{ .{ .raw = 0, .formatted = "0" }, .{ .raw = 1234, .formatted = "1\u{202f}234" } },
        }, .{});
    }
    fn allocation(a: A, input: []const u8) !void {
        var snapshot = try Snapshot.init(a, input, site, ns, "testwiktionary", "20261001", "test");
        defer snapshot.deinit();
        try std.testing.expectEqualStrings("https://media.example/A.svg", snapshot.file("File:A.svg", "").?.url);
        try std.testing.expectEqual(@as(u64, 1234), snapshot.page("Page").?.size);
    }
};

test "parser function facts own exact sparse keys and distinguish missing rows from explicit absence" {
    const a = std.testing.allocator;
    const bytes = try FactsTest.fixture(a); defer a.free(bytes);
    var snapshot = try Snapshot.init(a, bytes, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "test");
    defer snapshot.deinit();
    @memset(bytes, '?');
    try std.testing.expectEqualStrings("https://media.example/A.svg", snapshot.file("File:A.svg", "").?.url);
    try std.testing.expectEqualStrings("//media.example/thumb/A.svg/100px-A.svg.png", snapshot.file("File:A.svg", "100").?.url);
    try std.testing.expect(snapshot.file("File:A.svg", "100px") == null);
    try std.testing.expect(snapshot.file("File:Unknown.svg", "") == null);
    try std.testing.expect(!snapshot.file("File:Absent.svg", "").?.exists);
    try std.testing.expectEqual(@as(u64, 420), snapshot.page("Page").?.revision_id);
    try std.testing.expect(snapshot.page("Other") == null);
    try std.testing.expectEqualStrings("1\u{202f}234", snapshot.format(1234).?);
    try std.testing.expect(snapshot.format(1235) == null);
}

test "parser function facts reject identity conflicts duplicate tuples and noninteger authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const bytes = try FactsTest.fixture(a);
    try std.testing.expectError(error.ParserFunctionFactsIdentityMismatch, Snapshot.init(a, bytes, "other", FactsTest.ns, "testwiktionary", "20261001", "test"));
    try std.testing.expectError(error.ParserFunctionFactsIdentityMismatch, Snapshot.init(a, bytes, FactsTest.site, FactsTest.ns, "otherwiki", "20261001", "test"));
    try std.testing.expectError(error.ParserFunctionFactsIdentityMismatch, Snapshot.init(a, bytes, FactsTest.site, @as([32]u8, @splat(0)), "testwiktionary", "20261001", "test"));
    for ([_]std.json.Value{ .{ .number_string = "1234.0" }, .{ .string = "1234" }, .{ .integer = -1 }, .{ .bool = true }, .null }) |bad| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{}); defer parsed.deinit();
        const row = &parsed.value.object.getPtr("pages").?.array.items[0];
        try row.object.put(a, "size", bad);
        const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        try std.testing.expectError(error.InvalidParserFunctionFacts, Snapshot.init(a, changed, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "test"));
    }
    for ([_][]const u8{ "files", "pages", "formats" }) |name| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{}); defer parsed.deinit();
        const array = &parsed.value.object.getPtr(name).?.array;
        try array.append(array.items[0]);
        const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        try std.testing.expectError(error.DuplicateParserFunctionFact, Snapshot.init(a, changed, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "test"));
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{}); defer parsed.deinit();
    const row = &parsed.value.object.getPtr("files").?.array.items[0];
    try row.object.put(a, "exists", .{ .bool = false });
    const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    try std.testing.expectError(error.InvalidParserFunctionFacts, Snapshot.init(a, changed, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "test"));
}

test "parser function fact storage releases owned documents and tuple maps on every allocation failure" {
    const bytes = try FactsTest.fixture(std.testing.allocator); defer std.testing.allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FactsTest.allocation, .{bytes});
}

const IntegerFormatTest = struct {
    fn fixture(a: A, profile: []const u8, language: []const u8) ![]u8 {
        const original = try FactsTest.fixture(a);
        defer a.free(original);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, original, .{});
        defer parsed.deinit();
        try parsed.value.object.put(parsed.arena.allocator(), "content_language", .{ .string = language });
        try parsed.value.object.put(parsed.arena.allocator(), "number_format_profile", .{ .string = profile });
        try parsed.value.object.put(parsed.arena.allocator(), "number_format_witness_title", .{ .string = "Page" });
        const formats = &parsed.value.object.getPtr("formats").?.array;
        formats.clearRetainingCapacity();
        return std.json.Stringify.valueAlloc(a, parsed.value, .{});
    }
};

test "source pinned HU integer formatting keeps exact grouping range and caller owned values" {
    const a = std.testing.allocator;
    const bytes = try IntegerFormatTest.fixture(a, integer_format_profile, "hu");
    defer a.free(bytes);
    var snapshot = try Snapshot.init(a, bytes, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "hu");
    defer snapshot.deinit();
    @memset(bytes, '?');
    const cases = .{
        .{ @as(u64, 0), "0" }, .{ @as(u64, 1), "1" },
        .{ @as(u64, 999), "999" }, .{ @as(u64, 1000), "1\u{a0}000" },
        .{ @as(u64, 9999), "9\u{a0}999" }, .{ @as(u64, 10000), "10\u{a0}000" },
        .{ @as(u64, 23220), "23\u{a0}220" },
        .{ @as(u64, 1234567890), "1\u{a0}234\u{a0}567\u{a0}890" },
        .{ max_exact_formatted_integer, "9\u{a0}007\u{a0}199\u{a0}254\u{a0}740\u{a0}991" },
    };
    var page_arena = std.heap.ArenaAllocator.init(a); defer page_arena.deinit();
    const page_a = page_arena.allocator();
    const retained = try snapshot.formatPageSize(page_a, 23220, "hu");
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, snapshot.formatPageSize(page_a, 23220, null));
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, snapshot.formatPageSize(page_a, 23220, "fr"));
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try snapshot.formatPageSize(page_a, case[0], "hu"));
    try std.testing.expectEqualStrings("23\u{a0}220", retained);
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, snapshot.formatPageSize(page_a, max_exact_formatted_integer + 1, "hu"));
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, snapshot.formatPageSize(page_a, std.math.maxInt(u64), "hu"));
    try std.testing.expect(snapshot.format(23220) == null); // Computed values are not observations.
    var fixed_bytes: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    for (0..1024) |_| {
        fixed.reset();
        try std.testing.expectEqualStrings("23\u{a0}220", try snapshot.formatPageSize(fixed.allocator(), 23220, "hu"));
    }
}

test "HU formatting preserves explicit authority and refuses conflicts unsupported profiles and languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ordinary = try FactsTest.fixture(a);
    var legacy = try Snapshot.init(a, ordinary, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "test");
    defer legacy.deinit();
    try std.testing.expectEqualStrings("1\u{202f}234", try legacy.formatPageSize(a, 1234, "hu"));
    try std.testing.expectError(error.PageSizeFormatSnapshotMissing, legacy.formatPageSize(a, 23220, "hu"));
    for ([_][]const u8{ "mw-other-hu-latn-integer-v1", "", "mw-f458-en-latn-integer-v1", hu_wmf5_integer_format_profile }) |profile| {
        const bytes = try IntegerFormatTest.fixture(a, profile, "hu");
        try std.testing.expectError(error.InvalidParserFunctionFormatProfile, Snapshot.init(a, bytes, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "hu"));
    }
    const wrong_language = try IntegerFormatTest.fixture(a, integer_format_profile, "en");
    try std.testing.expectError(error.InvalidParserFunctionFormatProfile, Snapshot.init(a, wrong_language, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "en"));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, ordinary, .{});
    defer parsed.deinit();
    try parsed.value.object.put(parsed.arena.allocator(), "content_language", .{ .string = "hu" });
    try parsed.value.object.put(parsed.arena.allocator(), "number_format_profile", .{ .string = integer_format_profile });
    try parsed.value.object.put(parsed.arena.allocator(), "number_format_witness_title", .{ .string = "Page" });
    const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    var conflict = try Snapshot.init(a, changed, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "hu");
    defer conflict.deinit();
    try std.testing.expectError(error.PageSizeFormatAuthorityConflict, conflict.formatPageSize(a, 1234, "hu"));
    try std.testing.expectEqualStrings("1\u{202f}234", conflict.format(1234).?);
    try std.testing.expectEqualStrings("0", try conflict.formatPageSize(a, 0, "hu"));
    const row = &parsed.value.object.getPtr("formats").?.array.items[1];
    try row.object.put(parsed.arena.allocator(), "raw", .{ .integer = max_exact_formatted_integer + 1 });
    const outside = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    var observed_outside = try Snapshot.init(a, outside, FactsTest.site, FactsTest.ns, "testwiktionary", "20261001", "hu");
    defer observed_outside.deinit();
    try std.testing.expectEqualStrings("1\u{202f}234", try observed_outside.formatPageSize(a, max_exact_formatted_integer + 1, "hu"));
}
