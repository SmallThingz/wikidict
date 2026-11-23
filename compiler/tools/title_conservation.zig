const std = @import("std");
const dump = @import("wikimedia_dump");
const encoder = @import("encoder");
const Kind = encoder.blob_format.BlobKind;

/// One ordinary Writer interval. Text keys borrow the producer's pinned page index.
/// A namespace-stripped fixed key needs its original row reference because the
/// corresponding WIKBLB08 frame has no namespace prefix. DAL1 retains that prefix.
const Self = @This();
allocator: std.mem.Allocator,
pages: []const u8,
titles: dump.PageTitleIndex,
start: usize,
required: std.DynamicBitSetUnmanaged,
seen: std.DynamicBitSetUnmanaged,
fixed: std.enums.EnumArray(Kind, std.StringHashMapUnmanaged(u64)) = .initFill(.empty),
roles: std.AutoHashMapUnmanaged(u32, Kind) = .empty,

pub fn init(a: std.mem.Allocator, pages: []const u8, titles: dump.PageTitleIndex, start: usize, limit: ?usize) !Self {
    if (pages.len != titles.page_index_size or dump.pageIndexKind(pages) != titles.kind) return error.PageTitleIndexMismatch;
    // Preserve the ordinary short-input/empty interval behavior of the caller.
    const count = @min(titles.row_count -| start, limit orelse titles.row_count);
    var required = try std.DynamicBitSetUnmanaged.initEmpty(a, count);
    errdefer required.deinit(a);
    return .{ .allocator = a, .pages = pages, .titles = titles, .start = start, .required = required, .seen = try std.DynamicBitSetUnmanaged.initEmpty(a, count) };
}

pub fn deinit(self: *Self) void {
    self.required.deinit(self.allocator);
    self.seen.deinit(self.allocator);
    for (&self.fixed.values) |*map| map.deinit(self.allocator);
    self.roles.deinit(self.allocator);
}

fn position(self: *const Self, ordinal: usize) !usize {
    if (ordinal < self.start or ordinal - self.start >= self.required.capacity()) return error.SourceTitleOutsideInterval;
    return ordinal - self.start;
}

fn stripped(kind: Kind) bool {
    return kind != .language and kind != .supplemental and kind != .alias;
}

/// Called only after the real dispatcher's explicit source exclusions. Even a
/// recoverable fallback still owes a record. Only the indexed winning row owes one.
pub fn expect(self: *Self, ordinal: usize, line: []const u8, page: dump.IndexedPage, kind: Kind, key: []const u8) !void {
    const ref = (try self.titles.lookup(self.pages, page.title)) orelse return error.InvalidPageTitleIndex;
    if (dump.pageRowRefOrdinal(ref) != ordinal) return;
    if (@intFromPtr(line.ptr) - @intFromPtr(self.pages.ptr) != dump.pageRowRefOffset(ref)) return error.PageTitleIndexMismatch;
    const bit = try self.position(ordinal);
    if (self.required.isSet(bit)) return error.RepeatedSourceDisposition;
    const role = try self.roles.getOrPut(self.allocator, page.ns);
    if (role.found_existing and role.value_ptr.* != kind) return error.NamespaceTitleCollision;
    role.value_ptr.* = kind;
    if (page.redirect == null and stripped(kind)) {
        const stored = try self.fixed.getPtr(kind).getOrPut(self.allocator, key);
        if (stored.found_existing) return error.DuplicateRecord;
        stored.value_ptr.* = ref;
    }
    self.required.set(bit);
}

/// Observe the same title and payload slices that the normal Writer serializes.
pub fn observe(ctx: *anyopaque, kind: Kind, record: encoder.blob_format.RecordInput) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const alias = if (kind == .alias) try encoder.alias_codec.decode(record.payload) else null;
    if (alias) |value| try encoder.alias_codec.validateKey(record.title, value);
    const source_title = if (alias) |value| value.source_title else record.title;
    const ref = (if (stripped(kind)) self.fixed.getPtr(kind).get(record.title) else try self.titles.lookup(self.pages, source_title)) orelse return error.UnexpectedSourceTitle;
    const start = dump.pageRowRefOffset(ref);
    if (start >= self.pages.len) return error.InvalidPageTitleIndex;
    const end = std.mem.indexOfScalarPos(u8, self.pages, start, '\n') orelse self.pages.len;
    const page = try dump.parsePageIndexLine(self.titles.kind, self.pages[start..end]);
    const bit = try self.position(dump.pageRowRefOrdinal(ref));
    if (!self.required.isSet(bit) or !page.has_source or (page.redirect != null) != (alias != null)) return error.UnexpectedSourceTitle;
    const source_kind = self.roles.get(page.ns) orelse return error.UnexpectedSourceTitle;
    if (alias) |value| {
        if (source_kind != value.source_kind or value.source_namespace != page.ns or !std.mem.eql(u8, value.xml_target, page.redirect.?)) return error.UnexpectedAliasSource;
    } else if (kind != source_kind) return error.UnexpectedSourceKind;
    if (self.seen.isSet(bit) and kind != .language) return error.DuplicateSourceRecord;
    self.seen.set(bit);
}

pub fn finish(self: *const Self) !void {
    if (self.seen.eql(self.required)) return;
    var expected = self.required.iterator(.{});
    while (expected.next()) |bit| {
        if (self.seen.isSet(bit)) continue;
        std.debug.print("missing compiled source page ordinal={d}\n", .{self.start + bit});
        return error.MissingCompiledSourceTitle;
    }
    return error.UnexpectedSourceTitle;
}

test "source title conservation binds only canonical dispatched identities and all record kinds" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const prefix = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{temp.sub_path});
    defer a.free(prefix);
    const input = try std.fs.path.join(a, &.{ prefix, "page-index.tsv" });
    defer a.free(input);
    const output = try std.fs.path.join(a, &.{ prefix, dump.page_title_index_filename });
    defer a.free(output);
    // First Chongzuo is superseded; the final three rows have no dispatch obligation.
    const pages = "0\t1\tChongzuo\t\t42\t43\tT\tA\twikitext\t0\t1\t0\n" ++
        "0\t1\tChongzuo\t\t8688\t11169\tT\tA\twikitext\t0\t1\t0\n" ++
        "0\t1\tfootball\t\t8713\t12510\tT\tA\twikitext\t0\t1\t0\n" ++
        "0\t1\tLink\tfootball\t4\t4\tT\tA\twikitext\t0\t1\t0\n" ++
        "0\t1\t附錄:X\t\t5\t5\tT\tA\twikitext\t111\t1\t0\n" ++
        "0\t1\tSõnastik:X\t\t6\t6\tT\tA\twikitext\t110\t1\t0\n" ++
        "0\t1\tTemplate:T\t\t7\t7\tT\tA\twikitext\t10\t1\t0\n" ++
        "0\t1\tHome\t\t8\t8\tT\tA\twikitext\t0\t1\t0\n" ++
        "0\t0\tSuppressed\t\t9\t9\tT\tA\twikitext\t0\t0\t0\n";
    try temp.dir.writeFile(io, .{ .sub_path = "page-index.tsv", .data = pages });
    try dump.buildPageTitleIndex(io, a, input, output);
    const bytes = try temp.dir.readFileAlloc(io, dump.page_title_index_filename, a, .limited(4096));
    defer a.free(bytes);
    const titles = try dump.PageTitleIndex.init(bytes);
    var proof = try Self.init(a, pages, titles, 0, null);
    defer proof.deinit();
    var rows = std.mem.tokenizeScalar(u8, pages, '\n');
    for ([_]Kind{ .language, .language, .language, .language, .supplemental, .thesaurus }, 0..) |kind, ordinal| {
        const line = rows.next().?;
        const page = try dump.parsePageIndexLine(.raw_xml, line);
        try proof.expect(ordinal, line, page, kind, if (kind == .thesaurus) "X" else page.title);
    }
    try std.testing.expectEqual(@as(usize, 5), proof.required.count());
    for ([_][]const u8{ "Chongzuo", "Chongzuo" }) |title| try observe(&proof, .language, .{ .title = title, .payload = "" });
    for ([_][]const u8{ "Template:T", "Home", "Suppressed", "unexpected", "Link", "chongzuo" }) |title|
        try std.testing.expectError(error.UnexpectedSourceTitle, observe(&proof, .language, .{ .title = title, .payload = "" }));
    try std.testing.expectError(error.UnexpectedSourceKind, observe(&proof, .language, .{ .title = "附錄:X", .payload = "" }));
    try observe(&proof, .supplemental, .{ .title = "附錄:X", .payload = "" });
    try observe(&proof, .thesaurus, .{ .title = "X", .payload = "" });
    try std.testing.expectError(error.DuplicateSourceRecord, observe(&proof, .thesaurus, .{ .title = "X", .payload = "" }));
    var alias: encoder.alias_codec.Record = .{ .source_namespace = 0, .source_kind = .language, .source_title = "Link", .source_key = "Link", .xml_target = "football", .target_title = "football", .target_namespace = 0, .target_kind = .language, .target_key = "football", .fragment = "", .presentation = "presentation fixture" };
    const payload = try encoder.alias_codec.encodeAlloc(a, alias);
    defer a.free(payload);
    try observe(&proof, .alias, .{ .title = "1\tLink", .payload = payload });
    alias.xml_target = "different";
    const wrong = try encoder.alias_codec.encodeAlloc(a, alias);
    defer a.free(wrong);
    try std.testing.expectError(error.UnexpectedAliasSource, observe(&proof, .alias, .{ .title = "1\tLink", .payload = wrong }));
    alias.xml_target = "football";
    alias.source_kind = .supplemental;
    alias.source_namespace = 111;
    const wrong_kind = try encoder.alias_codec.encodeAlloc(a, alias);
    defer a.free(wrong_kind);
    try std.testing.expectError(error.UnexpectedAliasSource, observe(&proof, .alias, .{ .title = "7\tLink", .payload = wrong_kind }));
    try std.testing.expectError(error.MissingCompiledSourceTitle, proof.finish());
    try observe(&proof, .language, .{ .title = "football", .payload = "" });
    try proof.finish();
    var empty = try Self.init(a, pages, titles, 6, 3);
    defer empty.deinit();
    try empty.finish();
    try std.testing.expectError(error.SourceTitleOutsideInterval, observe(&empty, .language, .{ .title = "Chongzuo", .payload = "" }));
}
