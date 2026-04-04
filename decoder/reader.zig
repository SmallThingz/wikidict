const std = @import("std");

const encoder = @import("encoder");
const compact = encoder.compact_encoding;
const format = encoder.format;
const normalize = @import("normalize.zig");
const wikitext = encoder.wikitext;

const english_heading = "==English==\n";
const cache_magic = "DCTIDX02";
const cache_version: u32 = 2;
const cache_alignment: u64 = 8;

const StringRef = extern struct {
    offset: u64,
    len: u32,
    reserved: u32 = 0,
};

const Range = extern struct {
    start: u32,
    len: u32,
};

const CachedEntry = extern struct {
    word: StringRef,
    normalized: StringRef,
    summary: StringRef,
    alt_forms: Range,
    canonical_targets: Range,
    incoming_aliases: Range,
    flags: u8,
    reserved0: [7]u8 = [_]u8{0} ** 7,
    raw_offset: u64,
    raw_len: u32,
    reserved1: u32 = 0,
};

const CachedLookup = extern struct {
    key: StringRef,
    matched: StringRef,
    entry_index: u32,
    kind: u8,
    reserved: [3]u8 = [_]u8{0} ** 3,
};

const CacheHeader = extern struct {
    magic_bytes: [8]u8,
    version: u32,
    header_size: u32,
    cache_key: u64,
    entry_count: u32,
    list_count: u32,
    lookup_count: u32,
    reserved0: u32 = 0,
    entries_offset: u64,
    lists_offset: u64,
    lookups_offset: u64,
    strings_offset: u64,
    strings_len: u64,

    fn init(
        cache_key: u64,
        entry_count: u32,
        list_count: u32,
        lookup_count: u32,
        entries_offset: u64,
        lists_offset: u64,
        lookups_offset: u64,
        strings_offset: u64,
        strings_len: u64,
    ) CacheHeader {
        return .{
            .magic_bytes = cache_magic.*,
            .version = cache_version,
            .header_size = cache_header_size,
            .cache_key = cache_key,
            .entry_count = entry_count,
            .list_count = list_count,
            .lookup_count = lookup_count,
            .entries_offset = entries_offset,
            .lists_offset = lists_offset,
            .lookups_offset = lookups_offset,
            .strings_offset = strings_offset,
            .strings_len = strings_len,
        };
    }
};

const cache_header_size = std.mem.alignForward(u64, @sizeOf(CacheHeader), cache_alignment);

const BuildEntryData = struct {
    word: []const u8,
    normalized: []const u8,
    alt_forms: []const []const u8 = &.{},
    canonical_targets: []const []const u8 = &.{},
    incoming_aliases: []const []const u8 = &.{},
    summary: []const u8 = "",
    flags: u8 = 0,
    raw_offset: u64 = 0,
    raw_len: u32 = 0,
};

const BuildLookupRecord = struct {
    key: []const u8,
    matched: []const u8,
    entry_index: u32,
    kind: u8,
};

const BuildPayload = struct {
    entries: []const BuildEntryData,
    lookups: []const BuildLookupRecord,
};

const CacheBuildData = struct {
    entries: []const CachedEntry,
    lists: []const StringRef,
    lookups: []const CachedLookup,
    strings: []const u8,

    fn deinit(self: *CacheBuildData, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.lists);
        allocator.free(self.lookups);
        allocator.free(self.strings);
    }
};

const OpenCache = struct {
    file: std.Io.File,
    mapping: []align(std.heap.page_size_min) const u8,
    header: *const CacheHeader,
    entries: []const CachedEntry,
    lists: []const StringRef,
    lookups: []const CachedLookup,
    strings: []const u8,
};

pub const LookupHit = struct {
    entry_index: u32,
    matched: []const u8,
    kind: u8,
};

pub const TermListView = struct {
    dict: *const Dictionary,
    range: Range,

    pub fn len(self: TermListView) usize {
        return self.range.len;
    }

    pub fn at(self: TermListView, index: usize) []const u8 {
        return self.dict.listItem(self.range, index);
    }

    pub fn toOwnedSlice(self: TermListView, allocator: std.mem.Allocator) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, self.range.len);
        for (out, 0..) |*slot, idx| slot.* = self.at(idx);
        return out;
    }
};

pub const EntryView = struct {
    dict: *const Dictionary,
    index: u32,

    fn record(self: EntryView) *const CachedEntry {
        return &self.dict.entries[self.index];
    }

    pub fn word(self: EntryView) []const u8 {
        return self.dict.string(self.record().word);
    }

    pub fn normalized(self: EntryView) []const u8 {
        return self.dict.string(self.record().normalized);
    }

    pub fn altForms(self: EntryView) TermListView {
        return .{ .dict = self.dict, .range = self.record().alt_forms };
    }

    pub fn canonicalTargets(self: EntryView) TermListView {
        return .{ .dict = self.dict, .range = self.record().canonical_targets };
    }

    pub fn incomingAliases(self: EntryView) TermListView {
        return .{ .dict = self.dict, .range = self.record().incoming_aliases };
    }

    pub fn summary(self: EntryView) []const u8 {
        return self.dict.string(self.record().summary);
    }

    pub fn hasRaw(self: EntryView) bool {
        return (self.record().flags & format.record_flag_has_raw) != 0;
    }

    pub fn isAliasOnly(self: EntryView) bool {
        return (self.record().flags & format.record_flag_alias_only) != 0;
    }

    pub fn rawEnglishAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.hasRaw()) return null;

        const start = std.math.cast(usize, self.record().raw_offset) orelse return error.InvalidDictionaryFile;
        const len = std.math.cast(usize, self.record().raw_len) orelse return error.InvalidDictionaryFile;
        if (start > self.dict.mapping.len or len > self.dict.mapping.len - start) return error.InvalidDictionaryFile;

        const payload = try compact.decodeAlloc(allocator, self.dict.mapping[start .. start + len]);
        defer allocator.free(payload);
        const raw = try prependEnglishHeadingAlloc(allocator, payload);
        return raw;
    }
};

pub const Dictionary = struct {
    io: std.Io,
    file: std.Io.File,
    cache_file: std.Io.File,
    mapping: []align(std.heap.page_size_min) const u8,
    cache_mapping: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    cache_header: *const CacheHeader,
    entries: []const CachedEntry,
    list_refs: []const StringRef,
    lookups: []const CachedLookup,
    strings: []const u8,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Dictionary {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        const stat = try file.stat(io);
        const mapped = try mapWholeFile(file, stat.size);
        errdefer std.posix.munmap(mapped);

        if (stat.size < @sizeOf(format.Header)) return error.InvalidDictionaryFile;
        const header: *const format.Header = @ptrCast(@alignCast(mapped.ptr));
        if (!std.mem.eql(u8, &header.magic_bytes, format.magic)) return error.InvalidDictionaryFile;
        if (header.version != format.version) return error.UnsupportedDictionaryVersion;

        const records_end = header.records_offset + header.records_len;
        if (records_end > stat.size) return error.InvalidDictionaryFile;

        const cache = try openOrBuildCache(allocator, io, path, stat, mapped, header);
        errdefer {
            std.posix.munmap(cache.mapping);
            cache.file.close(io);
        }

        return .{
            .io = io,
            .file = file,
            .cache_file = cache.file,
            .mapping = mapped,
            .cache_mapping = cache.mapping,
            .header = header,
            .cache_header = cache.header,
            .entries = cache.entries,
            .list_refs = cache.lists,
            .lookups = cache.lookups,
            .strings = cache.strings,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        std.posix.munmap(self.cache_mapping);
        self.cache_file.close(self.io);
        std.posix.munmap(self.mapping);
        self.file.close(self.io);
    }

    pub fn entryAt(self: *const Dictionary, index: u32) EntryView {
        return .{
            .dict = self,
            .index = index,
        };
    }

    pub fn lookupExact(self: *const Dictionary, allocator: std.mem.Allocator, term: []const u8) ![]LookupHit {
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        const normalized = try normalize.normalizeToList(&key_buf, allocator, term);
        if (normalized.len == 0) return allocator.alloc(LookupHit, 0);

        const start = lowerBoundLookup(self, normalized);
        var end = start;
        while (end < self.lookups.len and std.mem.eql(u8, self.lookupKey(self.lookups[end]), normalized)) : (end += 1) {}

        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);
        for (self.lookups[start..end]) |lookup| {
            try hits.append(allocator, .{
                .entry_index = lookup.entry_index,
                .matched = self.string(lookup.matched),
                .kind = lookup.kind,
            });
        }
        return hits.toOwnedSlice(allocator);
    }

    pub fn suggest(self: *const Dictionary, allocator: std.mem.Allocator, prefix: []const u8, limit: usize) ![]LookupHit {
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        const normalized = try normalize.normalizeToList(&key_buf, allocator, prefix);
        if (normalized.len == 0) return allocator.alloc(LookupHit, 0);

        const start = lowerBoundLookup(self, normalized);
        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);

        var i = start;
        while (i < self.lookups.len and hits.items.len < limit) : (i += 1) {
            const lookup = self.lookups[i];
            if (!std.mem.startsWith(u8, self.lookupKey(lookup), normalized)) break;

            const candidate = LookupHit{
                .entry_index = lookup.entry_index,
                .matched = self.string(lookup.matched),
                .kind = lookup.kind,
            };
            if (!containsHit(hits.items, candidate)) try hits.append(allocator, candidate);
        }
        return hits.toOwnedSlice(allocator);
    }

    fn string(self: *const Dictionary, ref: StringRef) []const u8 {
        const start = @as(usize, @intCast(ref.offset));
        const len = ref.len;
        return self.strings[start .. start + len];
    }

    fn list(self: *const Dictionary, range: Range) []const StringRef {
        const start = range.start;
        const len = range.len;
        return self.list_refs[start .. start + len];
    }

    fn listItem(self: *const Dictionary, range: Range, index: usize) []const u8 {
        return self.string(self.list(range)[index]);
    }

    fn lookupKey(self: *const Dictionary, lookup: CachedLookup) []const u8 {
        return self.string(lookup.key);
    }
};

const BuildState = struct {
    entries: std.ArrayList(BuildEntryData) = .empty,
    lookups: std.ArrayList(BuildLookupRecord) = .empty,
};

const StringInterner = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(StringRef) = .empty,
    blob: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *StringInterner) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.deinit(self.allocator);
        self.blob.deinit(self.allocator);
    }

    fn intoOwnedBlob(self: *StringInterner) ![]u8 {
        const out = try self.blob.toOwnedSlice(self.allocator);
        self.blob = .empty;
        return out;
    }

    fn intern(self: *StringInterner, value: []const u8) !StringRef {
        if (value.len == 0) return .{ .offset = 0, .len = 0 };
        if (self.map.get(value)) |existing| return existing;

        const key = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(key);

        const start = self.blob.items.len;
        try self.blob.appendSlice(self.allocator, value);

        const ref = StringRef{
            .offset = start,
            .len = std.math.cast(u32, value.len) orelse return error.StringTooLarge,
        };

        try self.map.put(self.allocator, key, ref);
        return ref;
    }
};

fn openOrBuildCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    db_stat: anytype,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
) !OpenCache {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{db_path});
    defer allocator.free(cache_path);

    const expected_key = computeCacheKey(db_stat, header);
    if (try tryOpenCache(io, cache_path, expected_key)) |cache| return cache;

    try buildAndWriteCache(allocator, io, cache_path, expected_key, mapped, header);
    return (try tryOpenCache(io, cache_path, expected_key)) orelse error.InvalidDictionaryCache;
}

fn tryOpenCache(io: std.Io, cache_path: []const u8, expected_key: u64) !?OpenCache {
    var file = std.Io.Dir.cwd().openFile(io, cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const stat = file.stat(io) catch |err| {
        file.close(io);
        return err;
    };
    if (stat.size < cache_header_size) {
        file.close(io);
        return null;
    }

    const mapped = mapWholeFile(file, stat.size) catch |err| {
        file.close(io);
        return err;
    };
    errdefer std.posix.munmap(mapped);

    const header: *const CacheHeader = @ptrCast(@alignCast(mapped.ptr));
    if (!std.mem.eql(u8, &header.magic_bytes, cache_magic) or
        header.version != cache_version or
        header.header_size != cache_header_size or
        header.cache_key != expected_key)
    {
        std.posix.munmap(mapped);
        file.close(io);
        return null;
    }

    const entries = viewArray(CachedEntry, mapped, header.entries_offset, header.entry_count) catch {
        std.posix.munmap(mapped);
        file.close(io);
        return null;
    };
    const lists = viewArray(StringRef, mapped, header.lists_offset, header.list_count) catch {
        std.posix.munmap(mapped);
        file.close(io);
        return null;
    };
    const lookups = viewArray(CachedLookup, mapped, header.lookups_offset, header.lookup_count) catch {
        std.posix.munmap(mapped);
        file.close(io);
        return null;
    };
    const strings = viewBytes(mapped, header.strings_offset, header.strings_len) catch {
        std.posix.munmap(mapped);
        file.close(io);
        return null;
    };

    return .{
        .file = file,
        .mapping = mapped,
        .header = header,
        .entries = entries,
        .lists = lists,
        .lookups = lookups,
        .strings = strings,
    };
}

fn buildAndWriteCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    cache_key: u64,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const build_payload = try buildCachePayload(allocator, arena.allocator(), mapped, header);
    var cache_data = try materializeCacheData(allocator, build_payload);
    defer cache_data.deinit(allocator);

    try writeCacheFile(io, cache_path, cache_key, cache_data);
}

fn buildCachePayload(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
) !BuildPayload {
    var state = try buildIndex(allocator, arena_allocator, mapped, header);
    try finalizeIncomingAliases(allocator, arena_allocator, &state);
    try buildLookups(arena_allocator, &state);
    return .{
        .entries = try state.entries.toOwnedSlice(arena_allocator),
        .lookups = try state.lookups.toOwnedSlice(arena_allocator),
    };
}

fn materializeCacheData(allocator: std.mem.Allocator, payload: BuildPayload) !CacheBuildData {
    var interner = StringInterner.init(allocator);
    defer interner.deinit();

    var entries: std.ArrayList(CachedEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, payload.entries.len);

    var lists: std.ArrayList(StringRef) = .empty;
    defer lists.deinit(allocator);

    for (payload.entries) |entry| {
        const alt_forms = try appendStringList(allocator, &interner, &lists, entry.alt_forms);
        const canonical_targets = try appendStringList(allocator, &interner, &lists, entry.canonical_targets);
        const incoming_aliases = try appendStringList(allocator, &interner, &lists, entry.incoming_aliases);

        try entries.append(allocator, .{
            .word = try interner.intern(entry.word),
            .normalized = try interner.intern(entry.normalized),
            .summary = try interner.intern(entry.summary),
            .alt_forms = alt_forms,
            .canonical_targets = canonical_targets,
            .incoming_aliases = incoming_aliases,
            .flags = entry.flags,
            .raw_offset = entry.raw_offset,
            .raw_len = entry.raw_len,
        });
    }

    var lookups: std.ArrayList(CachedLookup) = .empty;
    defer lookups.deinit(allocator);
    try lookups.ensureTotalCapacity(allocator, payload.lookups.len);

    for (payload.lookups) |lookup| {
        try lookups.append(allocator, .{
            .key = try interner.intern(lookup.key),
            .matched = try interner.intern(lookup.matched),
            .entry_index = lookup.entry_index,
            .kind = lookup.kind,
        });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .lists = try lists.toOwnedSlice(allocator),
        .lookups = try lookups.toOwnedSlice(allocator),
        .strings = try interner.intoOwnedBlob(),
    };
}

fn appendStringList(
    allocator: std.mem.Allocator,
    interner: *StringInterner,
    lists: *std.ArrayList(StringRef),
    values: []const []const u8,
) !Range {
    const start = lists.items.len;
    try lists.ensureUnusedCapacity(allocator, values.len);
    for (values) |value| {
        lists.appendAssumeCapacity(try interner.intern(value));
    }
    return .{
        .start = std.math.cast(u32, start) orelse return error.StringListTooLarge,
        .len = std.math.cast(u32, values.len) orelse return error.StringListTooLarge,
    };
}

fn writeCacheFile(io: std.Io, cache_path: []const u8, cache_key: u64, cache: CacheBuildData) !void {
    const entries_offset = std.mem.alignForward(u64, cache_header_size, @alignOf(CachedEntry));
    const entries_len = bytesLen(CachedEntry, cache.entries.len) catch return error.FileTooBig;
    const lists_offset = std.mem.alignForward(u64, entries_offset + entries_len, @alignOf(StringRef));
    const lists_len = bytesLen(StringRef, cache.lists.len) catch return error.FileTooBig;
    const lookups_offset = std.mem.alignForward(u64, lists_offset + lists_len, @alignOf(CachedLookup));
    const lookups_len = bytesLen(CachedLookup, cache.lookups.len) catch return error.FileTooBig;
    const strings_offset = std.mem.alignForward(u64, lookups_offset + lookups_len, 1);
    const strings_len: u64 = cache.strings.len;

    const header = CacheHeader.init(
        cache_key,
        std.math.cast(u32, cache.entries.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.lists.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.lookups.len) orelse return error.FileTooBig,
        entries_offset,
        lists_offset,
        lookups_offset,
        strings_offset,
        strings_len,
    );

    var file = try std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true });
    defer file.close(io);

    try file.writePositionalAll(io, std.mem.asBytes(&header), 0);
    try writePadding(io, file, @sizeOf(CacheHeader), entries_offset);
    if (cache.entries.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.entries), entries_offset);
    try writePadding(io, file, entries_offset + entries_len, lists_offset);
    if (cache.lists.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.lists), lists_offset);
    try writePadding(io, file, lists_offset + lists_len, lookups_offset);
    if (cache.lookups.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.lookups), lookups_offset);
    try writePadding(io, file, lookups_offset + lookups_len, strings_offset);
    if (cache.strings.len != 0) try file.writePositionalAll(io, cache.strings, strings_offset);
}

fn bytesLen(comptime T: type, count: usize) !u64 {
    const byte_len = try std.math.mul(usize, count, @sizeOf(T));
    return byte_len;
}

fn writePadding(io: std.Io, file: std.Io.File, start: u64, end: u64) !void {
    if (end <= start) return;
    var zeros: [4096]u8 = [_]u8{0} ** 4096;
    var cursor = start;
    while (cursor < end) {
        const remaining = end - cursor;
        const chunk_len = @min(remaining, zeros.len);
        try file.writePositionalAll(io, zeros[0..chunk_len], cursor);
        cursor += chunk_len;
    }
}

fn buildIndex(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
) !BuildState {
    var state: BuildState = .{};

    var cursor: usize = @intCast(header.records_offset);
    const records_end: usize = @intCast(header.records_offset + header.records_len);
    while (cursor < records_end) {
        const flags = mapped[cursor];
        cursor += 1;

        const encoded_title = try readLengthPrefixedSlice(mapped, &cursor, records_end);
        const payload = try readLengthPrefixedSlice(mapped, &cursor, records_end);
        const title = try compact.decodeAlloc(arena_allocator, encoded_title);
        const normalized = try normalize.normalizeAlloc(arena_allocator, title);
        var entry = BuildEntryData{
            .word = title,
            .normalized = normalized,
            .flags = flags,
        };

        if ((flags & format.record_flag_has_raw) != 0) {
            entry.raw_offset = @intCast(@intFromPtr(payload.ptr) - @intFromPtr(mapped.ptr));
            entry.raw_len = std.math.cast(u32, payload.len) orelse return error.InvalidDictionaryFile;

            const raw_payload = try compact.decodeAlloc(allocator, payload);
            defer allocator.free(raw_payload);
            const raw = try prependEnglishHeadingAlloc(allocator, raw_payload);
            defer allocator.free(raw);

            var metadata = try wikitext.extractEntryMetadata(arena_allocator, title, raw);
            errdefer metadata.deinit(arena_allocator);

            entry.alt_forms = metadata.alt_forms.items;
            metadata.alt_forms = .empty;

            entry.canonical_targets = metadata.canonical_targets.items;
            metadata.canonical_targets = .empty;

            entry.summary = try wikitext.extractSummaryAlloc(arena_allocator, raw, 240);
            if (metadata.alias_only) entry.flags |= format.record_flag_alias_only;
        } else {
            const target = try compact.decodeAlloc(arena_allocator, payload);
            const targets = try arena_allocator.alloc([]const u8, 1);
            targets[0] = target;
            entry.canonical_targets = targets;
            entry.summary = try std.fmt.allocPrint(arena_allocator, "Alias of {s}.", .{target});
            entry.flags |= format.record_flag_alias_only;
        }

        try state.entries.append(arena_allocator, entry);
    }

    if (state.entries.items.len != header.entry_count) return error.InvalidDictionaryFile;
    return state;
}

fn mapWholeFile(file: std.Io.File, size_u64: u64) ![]align(std.heap.page_size_min) const u8 {
    const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
    if (size == 0) return error.InvalidDictionaryFile;

    return try std.posix.mmap(
        null,
        std.mem.alignForward(usize, size, std.heap.page_size_min),
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

fn viewArray(comptime T: type, mapped: []align(std.heap.page_size_min) const u8, offset_u64: u64, count_u32: u32) ![]const T {
    const offset = std.math.cast(usize, offset_u64) orelse return error.InvalidDictionaryCache;
    const count = std.math.cast(usize, count_u32) orelse return error.InvalidDictionaryCache;
    const byte_len = try std.math.mul(usize, count, @sizeOf(T));
    if (offset > mapped.len or byte_len > mapped.len - offset) return error.InvalidDictionaryCache;

    const slice = mapped[offset .. offset + byte_len];
    const ptr: [*]const T = @ptrCast(@alignCast(slice.ptr));
    return ptr[0..count];
}

fn viewBytes(mapped: []align(std.heap.page_size_min) const u8, offset_u64: u64, len_u64: u64) ![]const u8 {
    const offset = std.math.cast(usize, offset_u64) orelse return error.InvalidDictionaryCache;
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidDictionaryCache;
    if (offset > mapped.len or len > mapped.len - offset) return error.InvalidDictionaryCache;
    return mapped[offset .. offset + len];
}

fn computeCacheKey(stat: anytype, header: *const format.Header) u64 {
    var hasher = std.hash.Wyhash.init(0);

    addHashValue(&hasher, stat.size);
    addHashValue(&hasher, stat.mtime.nanoseconds);
    addHashValue(&hasher, header.version);
    addHashValue(&hasher, header.entry_count);
    addHashValue(&hasher, header.raw_entry_count);
    addHashValue(&hasher, header.redirect_count);
    addHashValue(&hasher, header.records_offset);
    addHashValue(&hasher, header.records_len);
    return hasher.final();
}

fn addHashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    const local = value;
    hasher.update(std.mem.asBytes(&local));
}

fn readLengthPrefixedSlice(bytes: []const u8, cursor: *usize, limit: usize) ![]const u8 {
    const len_u64 = format.readVarUInt(bytes, cursor, limit) catch return error.InvalidDictionaryFile;
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidDictionaryFile;
    if (cursor.* > limit or len > limit - cursor.*) return error.InvalidDictionaryFile;
    const start = cursor.*;
    cursor.* += len;
    return bytes[start .. start + len];
}

fn prependEnglishHeadingAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, payload, english_heading)) return allocator.dupe(u8, payload);

    var out = try std.ArrayList(u8).initCapacity(allocator, english_heading.len + payload.len);
    errdefer out.deinit(allocator);
    out.appendSliceAssumeCapacity(english_heading);
    out.appendSliceAssumeCapacity(payload);
    return out.toOwnedSlice(allocator);
}

fn finalizeIncomingAliases(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    state: *BuildState,
) !void {
    var title_map = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)).empty;
    defer {
        var it = title_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        title_map.deinit(allocator);
    }

    for (state.entries.items, 0..) |entry, idx| {
        const gop = try title_map.getOrPut(allocator, entry.normalized);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, @intCast(idx));
    }

    const incoming = try allocator.alloc(std.ArrayListUnmanaged([]const u8), state.entries.items.len);
    defer {
        for (incoming) |*list| list.deinit(allocator);
        allocator.free(incoming);
    }
    for (incoming) |*list| list.* = .empty;

    var norm_buf: std.ArrayList(u8) = .empty;
    defer norm_buf.deinit(allocator);

    for (state.entries.items, 0..) |entry, source_idx| {
        for (entry.canonical_targets) |target| {
            const normalized_target = try normalize.normalizeToList(&norm_buf, allocator, target);
            if (title_map.get(normalized_target)) |indices| {
                for (indices.items) |target_idx| {
                    try appendUniqueSlice(allocator, &incoming[target_idx], state.entries.items[source_idx].word);
                }
            }
        }
    }

    for (incoming, 0..) |list, idx| {
        if (list.items.len == 0) continue;
        const owned = try arena_allocator.alloc([]const u8, list.items.len);
        @memcpy(owned, list.items);
        state.entries.items[idx].incoming_aliases = owned;
    }
}

fn appendUniqueSlice(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(allocator, value);
}

fn buildLookups(arena_allocator: std.mem.Allocator, state: *BuildState) !void {
    for (state.entries.items, 0..) |entry, idx| {
        try state.lookups.append(arena_allocator, .{
            .key = entry.normalized,
            .matched = entry.word,
            .entry_index = @intCast(idx),
            .kind = format.lookup_kind_title,
        });

        for (entry.alt_forms) |alt_form| {
            try state.lookups.append(arena_allocator, .{
                .key = try normalize.normalizeAlloc(arena_allocator, alt_form),
                .matched = alt_form,
                .entry_index = @intCast(idx),
                .kind = format.lookup_kind_alternative_form,
            });
        }
    }

    std.mem.sort(BuildLookupRecord, state.lookups.items, {}, lessThanLookup);
}

fn lessThanLookup(_: void, lhs: BuildLookupRecord, rhs: BuildLookupRecord) bool {
    switch (std.mem.order(u8, lhs.key, rhs.key)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
    return std.mem.order(u8, lhs.matched, rhs.matched) == .lt;
}

fn containsHit(items: []const LookupHit, candidate: LookupHit) bool {
    for (items) |item| {
        if (item.entry_index == candidate.entry_index and std.mem.eql(u8, item.matched, candidate.matched) and item.kind == candidate.kind) {
            return true;
        }
    }
    return false;
}

fn lowerBoundLookup(self: *const Dictionary, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = self.lookups.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_key = self.lookupKey(self.lookups[mid]);
        if (std.mem.order(u8, mid_key, key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}
