const builtin = @import("builtin");
const std = @import("std");

const encoder = @import("encoder");
const normalize = @import("normalize");
const compact = encoder.compact_encoding;
const format = encoder.format;
const section_encoding = encoder.section_encoding;
const wikitext = encoder.wikitext;

const cache_magic = "DCTIDX04";
const cache_version: u32 = 4;
const cache_alignment: u32 = 8;

const StringRef = extern struct {
    offset: u32,
    len: u32,
};

const Range = extern struct {
    start: u32,
    len: u32,
};

const CachedEntry = extern struct {
    word: StringRef,
    incoming_aliases: Range,
    record_offset: u32,
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
    incoming_alias_count: u32,
    lookup_count: u32,
    reserved0: u32 = 0,
    entries_offset: u32,
    incoming_aliases_offset: u32,
    lookups_offset: u32,
    strings_offset: u32,
    strings_len: u32,

    fn init(
        cache_key: u64,
        entry_count: u32,
        incoming_alias_count: u32,
        lookup_count: u32,
        entries_offset: u32,
        incoming_aliases_offset: u32,
        lookups_offset: u32,
        strings_offset: u32,
        strings_len: u32,
    ) CacheHeader {
        return .{
            .magic_bytes = cache_magic.*,
            .version = cache_version,
            .header_size = cache_header_size,
            .cache_key = cache_key,
            .entry_count = entry_count,
            .incoming_alias_count = incoming_alias_count,
            .lookup_count = lookup_count,
            .entries_offset = entries_offset,
            .incoming_aliases_offset = incoming_aliases_offset,
            .lookups_offset = lookups_offset,
            .strings_offset = strings_offset,
            .strings_len = strings_len,
        };
    }
};

const cache_header_size = std.mem.alignForward(u32, @sizeOf(CacheHeader), cache_alignment);

const BuildAltForm = struct {
    value: []const u8,
    normalized: []const u8,
};

const BuildEntryData = struct {
    record_offset: u32,
    word: []const u8,
    normalized: []const u8,
    alt_forms: []const BuildAltForm = &.{},
    normalized_targets: []const []const u8 = &.{},
    incoming_aliases: []const u32 = &.{},
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
    incoming_aliases: []const u32,
    lookups: []const CachedLookup,
    strings: []const u8,

    fn deinit(self: *CacheBuildData, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.incoming_aliases);
        allocator.free(self.lookups);
        allocator.free(self.strings);
    }
};

const OpenCache = struct {
    file: std.Io.File,
    mapping: []align(std.heap.page_size_min) const u8,
    header: *const CacheHeader,
    entries: []const CachedEntry,
    incoming_aliases: []const u32,
    lookups: []const CachedLookup,
    strings: []const u8,
};

const EntryRecordView = struct {
    flags: u8,
    encoded_title: []const u8,
    payload: []const u8,
};

pub const EntryDerivedData = struct {
    summary: []const u8,
    alt_forms: std.ArrayListUnmanaged([]const u8) = .empty,
    canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    alias_only: bool,

    pub fn deinit(self: *EntryDerivedData, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.alt_forms.items) |value| allocator.free(value);
        self.alt_forms.deinit(allocator);
        for (self.canonical_targets.items) |value| allocator.free(value);
        self.canonical_targets.deinit(allocator);
    }
};

const CacheBuildProgress = struct {
    const Phase = enum {
        reading,
        aliases,
        lookups,
        materialize,
        writing,
        done,
    };

    total_record_bytes: usize,
    scanned_record_bytes: std.atomic.Value(usize) = .init(0),
    scanned_entries: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    phase: Phase = .reading,
    reading_parallel: bool = false,
    last_percent: u8 = 255,
    last_primary: usize = std.math.maxInt(usize),
    last_secondary: usize = std.math.maxInt(usize),

    fn init(total_record_bytes: usize) CacheBuildProgress {
        return .{
            .total_record_bytes = total_record_bytes,
        };
    }

    fn scanAdvance(self: *CacheBuildProgress, record_bytes_delta: usize, entry_delta: usize) void {
        const consumed_record_bytes = self.scanned_record_bytes.fetchAdd(record_bytes_delta, .monotonic) + record_bytes_delta;
        const entries = self.scanned_entries.fetchAdd(entry_delta, .monotonic) + entry_delta;
        const percent = if (self.total_record_bytes == 0)
            70
        else
            @as(u8, @intCast(@min(70, (consumed_record_bytes * 70) / self.total_record_bytes)));
        self.render(.reading, percent, entries, consumed_record_bytes);
    }

    fn setPhase(self: *CacheBuildProgress, phase: Phase, percent: u8, primary: usize, secondary: usize) void {
        self.render(phase, percent, primary, secondary);
    }

    fn setReadingParallel(self: *CacheBuildProgress, reading_parallel: bool) void {
        self.reading_parallel = reading_parallel;
    }

    fn finish(self: *CacheBuildProgress, entries: usize, lookups: usize) void {
        self.render(.done, 100, entries, lookups);
        if (!builtin.is_test) std.debug.print("\n", .{});
    }

    fn render(self: *CacheBuildProgress, phase: Phase, percent: u8, primary: usize, secondary: usize) void {
        if (builtin.is_test) return;
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);

        if (self.phase == phase and self.last_percent == percent and self.last_primary == primary and self.last_secondary == secondary) return;

        self.phase = phase;
        self.last_percent = percent;
        self.last_primary = primary;
        self.last_secondary = secondary;

        var bar: [24]u8 = undefined;
        @memset(&bar, '.');
        const filled = @min(bar.len, (bar.len * percent) / 100);
        @memset(bar[0..filled], '#');

        if (phase == .done) {
            std.debug.print(
                "\rindex build [{s}] {d:>3}% {s} ({d} entries, {d} lookups)",
                .{ &bar, percent, phaseLabel(self, phase), primary, secondary },
            );
            return;
        }

        switch (phase) {
            .reading => std.debug.print(
                "\rindex build [{s}] {d:>3}% {s} ({d} entries, {s})",
                .{ &bar, percent, phaseLabel(self, phase), primary, formatByteCount(secondary).slice() },
            ),
            .aliases, .lookups, .materialize, .writing => std.debug.print(
                "\rindex build [{s}] {d:>3}% {s} ({d}{s})",
                .{ &bar, percent, phaseLabel(self, phase), primary, phaseSuffix(phase) },
            ),
            .done => unreachable,
        }
    }

    fn phaseLabel(self: *const CacheBuildProgress, phase: Phase) []const u8 {
        return switch (phase) {
            .reading => if (self.reading_parallel) "decode records and metadata in parallel" else "decode records and metadata",
            .aliases => "resolve incoming aliases",
            .lookups => "sort normalized lookup keys",
            .materialize => "intern strings and pack cache",
            .writing => "write cache file",
            .done => "ready",
        };
    }

    fn phaseSuffix(phase: Phase) []const u8 {
        return switch (phase) {
            .reading => " entries",
            .aliases => " entries",
            .lookups => " lookups",
            .materialize => " entries",
            .writing => " string bytes",
            .done => unreachable,
        };
    }
};

const ByteCountLabel = struct {
    buffer: [16]u8,
    len: usize,

    fn slice(self: *const ByteCountLabel) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn formatByteCount(bytes: usize) ByteCountLabel {
    var label: ByteCountLabel = .{
        .buffer = undefined,
        .len = 0,
    };
    if (bytes >= 1024 * 1024) {
        label.len = (std.fmt.bufPrint(&label.buffer, "{d} MiB", .{bytes / (1024 * 1024)}) catch unreachable).len;
        return label;
    }
    if (bytes >= 1024) {
        label.len = (std.fmt.bufPrint(&label.buffer, "{d} KiB", .{bytes / 1024}) catch unreachable).len;
        return label;
    }
    label.len = (std.fmt.bufPrint(&label.buffer, "{d} B", .{bytes}) catch unreachable).len;
    return label;
}

const RecordDescriptor = struct {
    record_offset: u32,
    flags: u8,
    encoded_title: []const u8,
    payload: []const u8,
    record_len: u32,
};

const ScanChunkResult = struct {
    arena: std.heap.ArenaAllocator,
    entries: []BuildEntryData = &.{},
    err: ?anyerror = null,

    fn init() ScanChunkResult {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        };
    }

    fn deinit(self: *ScanChunkResult) void {
        self.arena.deinit();
    }
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
        return self.dict.incomingAliasItem(self.range, index);
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

    pub fn normalizedAlloc(self: EntryView, allocator: std.mem.Allocator) ![]const u8 {
        return normalize.normalizeAlloc(allocator, self.word());
    }

    pub fn incomingAliases(self: EntryView) TermListView {
        return .{ .dict = self.dict, .range = self.record().incoming_aliases };
    }

    pub fn derivedAlloc(self: EntryView, allocator: std.mem.Allocator) !EntryDerivedData {
        const entry_record = try self.dict.entryRecord(self.index);
        if ((entry_record.flags & format.record_flag_has_raw) != 0) {
            const encoded_english = try format.rawRecordEnglishPayload(entry_record.payload);
            const raw = try section_encoding.decodeEnglishAlloc(allocator, encoded_english);
            errdefer allocator.free(raw);

            var metadata = try wikitext.extractEntryMetadata(allocator, self.word(), raw);
            errdefer metadata.deinit(allocator);

            const summary = try wikitext.extractSummaryAlloc(allocator, raw, 240);
            allocator.free(raw);

            return .{
                .summary = summary,
                .alt_forms = metadata.alt_forms,
                .canonical_targets = metadata.canonical_targets,
                .alias_only = metadata.alias_only,
            };
        }

        const target = try format.decodeAliasRecordTargetAlloc(allocator, entry_record.payload);
        errdefer allocator.free(target);

        var canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (canonical_targets.items) |value| allocator.free(value);
            canonical_targets.deinit(allocator);
        }
        try canonical_targets.append(allocator, target);

        return .{
            .summary = try std.fmt.allocPrint(allocator, "Alias of {s}.", .{target}),
            .canonical_targets = canonical_targets,
            .alias_only = true,
        };
    }

    pub fn hasRaw(self: EntryView) bool {
        const offset = self.dict.entryRecordStart(self.index);
        return (self.dict.mapping[offset] & format.record_flag_has_raw) != 0;
    }

    pub fn isAliasOnlyAlloc(self: EntryView, allocator: std.mem.Allocator) !bool {
        if (!self.hasRaw()) return true;
        var derived = try self.derivedAlloc(allocator);
        defer derived.deinit(allocator);
        return derived.alias_only;
    }

    pub fn summaryAlloc(self: EntryView, allocator: std.mem.Allocator) ![]const u8 {
        var derived = try self.derivedAlloc(allocator);
        defer {
            derived.summary = "";
            derived.deinit(allocator);
        }
        return derived.summary;
    }

    pub fn altFormsAlloc(self: EntryView, allocator: std.mem.Allocator) ![]const []const u8 {
        var derived = try self.derivedAlloc(allocator);
        defer {
            allocator.free(derived.summary);
            for (derived.canonical_targets.items) |value| allocator.free(value);
            derived.canonical_targets.deinit(allocator);
            derived.alt_forms.deinit(allocator);
        }
        const owned = try allocator.alloc([]const u8, derived.alt_forms.items.len);
        @memcpy(owned, derived.alt_forms.items);
        derived.alt_forms = .empty;
        return owned;
    }

    pub fn canonicalTargetsAlloc(self: EntryView, allocator: std.mem.Allocator) ![]const []const u8 {
        var derived = try self.derivedAlloc(allocator);
        defer {
            allocator.free(derived.summary);
            for (derived.alt_forms.items) |value| allocator.free(value);
            derived.alt_forms.deinit(allocator);
            derived.canonical_targets.deinit(allocator);
        }
        const owned = try allocator.alloc([]const u8, derived.canonical_targets.items.len);
        @memcpy(owned, derived.canonical_targets.items);
        derived.canonical_targets = .empty;
        return owned;
    }

    pub fn rawEnglishAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.hasRaw()) return null;
        const entry_record = try self.dict.entryRecord(self.index);
        const encoded_english = try format.rawRecordEnglishPayload(entry_record.payload);
        return try section_encoding.decodeEnglishAlloc(allocator, encoded_english);
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
    incoming_aliases: []const u32,
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

        const records_end = std.math.add(u64, header.records_offset, header.records_len) catch return error.InvalidDictionaryFile;
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
            .incoming_aliases = cache.incoming_aliases,
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
        const end = upperBoundLookup(self, normalized);
        const hits = try allocator.alloc(LookupHit, end - start);
        for (self.lookups[start..end], hits) |lookup, *hit| {
            hit.* = .{
                .entry_index = lookup.entry_index,
                .matched = self.string(lookup.matched),
                .kind = lookup.kind,
            };
        }
        return hits;
    }

    pub fn suggest(self: *const Dictionary, allocator: std.mem.Allocator, prefix: []const u8, limit: usize) ![]LookupHit {
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        const normalized = try normalize.normalizeToList(&key_buf, allocator, prefix);
        if (normalized.len == 0) return allocator.alloc(LookupHit, 0);

        const start = lowerBoundLookup(self, normalized);
        const end = upperBoundPrefixLookup(self, normalized);
        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);

        var i = start;
        while (i < end and hits.items.len < limit) : (i += 1) {
            const lookup = self.lookups[i];
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
        const start: usize = ref.offset;
        const len: usize = ref.len;
        return self.strings[start .. start + len];
    }

    fn entryRecordStart(self: *const Dictionary, index: u32) usize {
        return @as(usize, @intCast(self.header.records_offset)) + self.entries[index].record_offset;
    }

    fn entryRecord(self: *const Dictionary, index: u32) !EntryRecordView {
        var cursor = self.entryRecordStart(index);
        const records_end = std.math.cast(usize, self.header.records_offset + self.header.records_len) orelse return error.InvalidDictionaryFile;
        if (cursor >= records_end) return error.InvalidDictionaryFile;

        const flags = self.mapping[cursor];
        cursor += 1;

        const encoded_title = try readLengthPrefixedSlice(self.mapping, &cursor, records_end);
        const payload = try readLengthPrefixedSlice(self.mapping, &cursor, records_end);
        return .{
            .flags = flags,
            .encoded_title = encoded_title,
            .payload = payload,
        };
    }

    fn incomingAliasList(self: *const Dictionary, range: Range) []const u32 {
        const start: usize = range.start;
        const len: usize = range.len;
        return self.incoming_aliases[start .. start + len];
    }

    fn incomingAliasItem(self: *const Dictionary, range: Range, index: usize) []const u8 {
        return self.string(self.entries[self.incomingAliasList(range)[index]].word);
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
            .offset = std.math.cast(u32, start) orelse return error.StringTooLarge,
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

    var progress = CacheBuildProgress.init(std.math.cast(usize, header.records_len) orelse return error.FileTooBig);
    try buildAndWriteCache(allocator, io, cache_path, expected_key, mapped, header, &progress);
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
    const incoming_aliases = viewArray(u32, mapped, header.incoming_aliases_offset, header.incoming_alias_count) catch {
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
        .incoming_aliases = incoming_aliases,
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
    progress: *CacheBuildProgress,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const build_payload = try buildCachePayload(allocator, arena.allocator(), mapped, header, progress);
    progress.setPhase(.materialize, 92, build_payload.entries.len, build_payload.lookups.len);
    var cache_data = try materializeCacheData(allocator, build_payload);
    defer cache_data.deinit(allocator);

    progress.setPhase(.writing, 97, cache_data.strings.len, 0);
    try writeCacheFile(allocator, io, cache_path, cache_key, cache_data);
    progress.finish(cache_data.entries.len, cache_data.lookups.len);
}

fn buildCachePayload(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    progress: *CacheBuildProgress,
) !BuildPayload {
    var state = try buildIndex(allocator, arena_allocator, mapped, header, progress);
    progress.setPhase(.aliases, 75, state.entries.items.len, 0);
    try finalizeIncomingAliases(allocator, arena_allocator, &state);
    progress.setPhase(.lookups, 84, state.entries.items.len, 0);
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

    var incoming_aliases: std.ArrayList(u32) = .empty;
    defer incoming_aliases.deinit(allocator);
    var incoming_alias_count: usize = 0;
    for (payload.entries) |entry| {
        incoming_alias_count += entry.incoming_aliases.len;
    }
    try incoming_aliases.ensureTotalCapacity(allocator, incoming_alias_count);

    for (payload.entries) |entry| {
        const incoming_range = try appendIncomingAliasList(allocator, &incoming_aliases, entry.incoming_aliases);

        try entries.append(allocator, .{
            .word = try interner.intern(entry.word),
            .incoming_aliases = incoming_range,
            .record_offset = entry.record_offset,
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
        .incoming_aliases = try incoming_aliases.toOwnedSlice(allocator),
        .lookups = try lookups.toOwnedSlice(allocator),
        .strings = try interner.intoOwnedBlob(),
    };
}

fn appendIncomingAliasList(
    allocator: std.mem.Allocator,
    indices: *std.ArrayList(u32),
    values: []const u32,
) !Range {
    const start = indices.items.len;
    try indices.ensureUnusedCapacity(allocator, values.len);
    for (values) |value| {
        indices.appendAssumeCapacity(value);
    }
    return .{
        .start = std.math.cast(u32, start) orelse return error.StringListTooLarge,
        .len = std.math.cast(u32, values.len) orelse return error.StringListTooLarge,
    };
}

fn writeCacheFile(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8, cache_key: u64, cache: CacheBuildData) !void {
    const entries_offset = std.mem.alignForward(u32, cache_header_size, @alignOf(CachedEntry));
    const entries_len = std.math.cast(u32, std.math.mul(usize, cache.entries.len, @sizeOf(CachedEntry)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const incoming_aliases_offset = std.mem.alignForward(u32, entries_offset + entries_len, @alignOf(u32));
    const incoming_aliases_len = std.math.cast(u32, std.math.mul(usize, cache.incoming_aliases.len, @sizeOf(u32)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const lookups_offset = std.mem.alignForward(u32, incoming_aliases_offset + incoming_aliases_len, @alignOf(CachedLookup));
    const lookups_len = std.math.cast(u32, std.math.mul(usize, cache.lookups.len, @sizeOf(CachedLookup)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const strings_offset = lookups_offset + lookups_len;
    const strings_len = std.math.cast(u32, cache.strings.len) orelse return error.FileTooBig;

    const header = CacheHeader.init(
        cache_key,
        std.math.cast(u32, cache.entries.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.incoming_aliases.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.lookups.len) orelse return error.FileTooBig,
        entries_offset,
        incoming_aliases_offset,
        lookups_offset,
        strings_offset,
        strings_len,
    );

    const temp_cache_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path});
    defer allocator.free(temp_cache_path);
    try deleteFileIfExists(io, temp_cache_path);
    defer deleteFileIfExists(io, temp_cache_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, temp_cache_path, .{ .truncate = true });
    defer file.close(io);

    try file.writePositionalAll(io, std.mem.asBytes(&header), 0);
    try writePadding(io, file, @sizeOf(CacheHeader), entries_offset);
    if (cache.entries.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.entries), entries_offset);
    try writePadding(io, file, entries_offset + entries_len, incoming_aliases_offset);
    if (cache.incoming_aliases.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.incoming_aliases), incoming_aliases_offset);
    try writePadding(io, file, incoming_aliases_offset + incoming_aliases_len, lookups_offset);
    if (cache.lookups.len != 0) try file.writePositionalAll(io, std.mem.sliceAsBytes(cache.lookups), lookups_offset);
    try writePadding(io, file, lookups_offset + lookups_len, strings_offset);
    if (cache.strings.len != 0) try file.writePositionalAll(io, cache.strings, strings_offset);
    try replaceFile(io, temp_cache_path, cache_path);
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn replaceFile(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    try std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, io);
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
    progress: *CacheBuildProgress,
) !BuildState {
    const descriptors = try collectRecordDescriptors(arena_allocator, mapped, header);

    var state: BuildState = .{};
    try state.entries.ensureTotalCapacity(arena_allocator, descriptors.len);

    const thread_count = indexBuildThreadCount(descriptors.len);
    progress.setReadingParallel(thread_count > 1);
    if (thread_count == 1) {
        for (descriptors) |descriptor| {
            const entry = try buildEntryFromRecord(arena_allocator, descriptor);
            state.entries.appendAssumeCapacity(entry);
            progress.scanAdvance(descriptor.record_len, 1);
        }
        return state;
    }

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);
    const chunks = try allocator.alloc(ScanChunkResult, thread_count);
    defer {
        for (chunks) |*chunk| chunk.deinit();
        allocator.free(chunks);
    }
    for (chunks) |*chunk| chunk.* = ScanChunkResult.init();

    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();
    var start: usize = 0;
    for (chunks, threads, 0..) |*chunk, *thread, i| {
        const end = partitionEnd(descriptors.len, thread_count, i);
        thread.* = try std.Thread.spawn(.{}, scanRecordChunk, .{
            descriptorSlice(descriptors, start, end),
            chunk,
            progress,
        });
        started_threads += 1;
        start = end;
    }
    for (threads) |thread| thread.join();

    for (chunks) |*chunk| {
        if (chunk.err) |err| return err;
        for (chunk.entries) |entry| {
            state.entries.appendAssumeCapacity(try cloneEntryData(arena_allocator, entry));
        }
    }

    return state;
}

fn collectRecordDescriptors(
    allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
) ![]const RecordDescriptor {
    const entry_count: usize = header.entry_count;
    const descriptors = try allocator.alloc(RecordDescriptor, entry_count);
    errdefer allocator.free(descriptors);

    var cursor: usize = @intCast(header.records_offset);
    const records_end: usize = @intCast(header.records_offset + header.records_len);
    var count: usize = 0;
    while (cursor < records_end) {
        if (count >= descriptors.len) return error.InvalidDictionaryFile;
        const record_start = cursor;
        const record_offset = cursor - @as(usize, @intCast(header.records_offset));
        const flags = mapped[cursor];
        cursor += 1;

        const encoded_title = try readLengthPrefixedSlice(mapped, &cursor, records_end);
        const payload = try readLengthPrefixedSlice(mapped, &cursor, records_end);
        descriptors[count] = .{
            .record_offset = std.math.cast(u32, record_offset) orelse return error.InvalidDictionaryFile,
            .flags = flags,
            .encoded_title = encoded_title,
            .payload = payload,
            .record_len = std.math.cast(u32, cursor - record_start) orelse return error.InvalidDictionaryFile,
        };
        count += 1;
    }

    if (count != descriptors.len) return error.InvalidDictionaryFile;
    return descriptors;
}

fn buildEntryFromRecord(allocator: std.mem.Allocator, descriptor: RecordDescriptor) !BuildEntryData {
    const title = try compact.decodeAlloc(allocator, descriptor.encoded_title);
    const normalized = try normalize.normalizeAlloc(allocator, title);
    var entry = BuildEntryData{
        .record_offset = descriptor.record_offset,
        .word = title,
        .normalized = normalized,
    };

    if ((descriptor.flags & format.record_flag_has_raw) != 0) {
        const encoded_english = try format.rawRecordEnglishPayload(descriptor.payload);
        const raw = try section_encoding.decodeEnglishAlloc(allocator, encoded_english);
        defer allocator.free(raw);

        var metadata = try wikitext.extractEntryMetadata(allocator, title, raw);
        defer metadata.deinit(allocator);

        entry.alt_forms = try adoptAltForms(allocator, metadata.alt_forms.items);
        metadata.alt_forms = .empty;
        entry.normalized_targets = try normalizeTargets(allocator, metadata.canonical_targets.items);
        return entry;
    }

    const normalized_target = try format.decodeAliasRecordNormalizedTargetAlloc(allocator, descriptor.payload);
    const targets = try allocator.alloc([]const u8, 1);
    targets[0] = normalized_target;
    entry.normalized_targets = targets;
    return entry;
}

fn adoptAltForms(allocator: std.mem.Allocator, values: []const []const u8) ![]const BuildAltForm {
    const out = try allocator.alloc(BuildAltForm, values.len);
    errdefer allocator.free(out);

    var count: usize = 0;
    errdefer while (count > 0) : (count -= 1) {
        allocator.free(out[count - 1].normalized);
    };

    for (values, 0..) |value, idx| {
        out[idx] = .{
            .value = value,
            .normalized = try normalize.normalizeAlloc(allocator, value),
        };
        count += 1;
    }
    return out;
}

fn normalizeTargets(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);

    var count: usize = 0;
    errdefer while (count > 0) : (count -= 1) {
        allocator.free(out[count - 1]);
    };

    for (values, 0..) |value, idx| {
        out[idx] = try normalize.normalizeAlloc(allocator, value);
        count += 1;
    }
    return out;
}

fn cloneEntryData(allocator: std.mem.Allocator, source: BuildEntryData) !BuildEntryData {
    const alt_forms = try cloneAltForms(allocator, source.alt_forms);
    errdefer freeAltForms(allocator, alt_forms);
    const normalized_targets = try cloneStringSlice(allocator, source.normalized_targets);
    errdefer freeStringSlice(allocator, normalized_targets);
    const word = try allocator.dupe(u8, source.word);
    errdefer allocator.free(word);
    const normalized = try allocator.dupe(u8, source.normalized);
    errdefer allocator.free(normalized);

    return .{
        .record_offset = source.record_offset,
        .word = word,
        .normalized = normalized,
        .alt_forms = alt_forms,
        .normalized_targets = normalized_targets,
    };
}

fn cloneAltForms(allocator: std.mem.Allocator, values: []const BuildAltForm) ![]const BuildAltForm {
    const out = try allocator.alloc(BuildAltForm, values.len);
    errdefer allocator.free(out);
    var count: usize = 0;
    errdefer while (count > 0) : (count -= 1) {
        allocator.free(out[count - 1].value);
        allocator.free(out[count - 1].normalized);
    };
    for (values, 0..) |value, idx| {
        out[idx] = .{
            .value = try allocator.dupe(u8, value.value),
            .normalized = try allocator.dupe(u8, value.normalized),
        };
        count += 1;
    }
    return out;
}

fn freeAltForms(allocator: std.mem.Allocator, values: []const BuildAltForm) void {
    for (values) |value| {
        allocator.free(value.value);
        allocator.free(value.normalized);
    }
    allocator.free(values);
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
    }
    return out;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn scanRecordChunk(descriptors: []const RecordDescriptor, chunk: *ScanChunkResult, progress: *CacheBuildProgress) void {
    const allocator = chunk.arena.allocator();
    chunk.entries = allocator.alloc(BuildEntryData, descriptors.len) catch |err| {
        chunk.err = err;
        return;
    };

    var pending_entries: usize = 0;
    var pending_bytes: usize = 0;
    for (descriptors, 0..) |descriptor, idx| {
        chunk.entries[idx] = buildEntryFromRecord(allocator, descriptor) catch |err| {
            chunk.err = err;
            return;
        };
        pending_entries += 1;
        pending_bytes += descriptor.record_len;
        if (pending_entries >= 16 or pending_bytes >= 128 * 1024) {
            progress.scanAdvance(pending_bytes, pending_entries);
            pending_entries = 0;
            pending_bytes = 0;
        }
    }

    if (pending_entries != 0 or pending_bytes != 0) {
        progress.scanAdvance(pending_bytes, pending_entries);
    }
}

fn descriptorSlice(descriptors: []const RecordDescriptor, start: usize, end: usize) []const RecordDescriptor {
    return descriptors[start..end];
}

fn partitionEnd(total: usize, part_count: usize, part_index: usize) usize {
    return @divTrunc(total * (part_index + 1), part_count);
}

fn indexBuildThreadCount(entry_count: usize) usize {
    if (builtin.single_threaded or entry_count < 128) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(cpu_count, entry_count / 64));
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

fn viewArray(comptime T: type, mapped: []align(std.heap.page_size_min) const u8, offset_u32: u32, count_u32: u32) ![]const T {
    const offset = std.math.cast(usize, offset_u32) orelse return error.InvalidDictionaryCache;
    const count = std.math.cast(usize, count_u32) orelse return error.InvalidDictionaryCache;
    if (offset % @alignOf(T) != 0) return error.InvalidDictionaryCache;
    const byte_len = try std.math.mul(usize, count, @sizeOf(T));
    if (offset > mapped.len or byte_len > mapped.len - offset) return error.InvalidDictionaryCache;

    const slice = mapped[offset .. offset + byte_len];
    const ptr: [*]const T = @ptrCast(@alignCast(slice.ptr));
    return ptr[0..count];
}

fn viewBytes(mapped: []align(std.heap.page_size_min) const u8, offset_u32: u32, len_u32: u32) ![]const u8 {
    const offset = std.math.cast(usize, offset_u32) orelse return error.InvalidDictionaryCache;
    const len = std.math.cast(usize, len_u32) orelse return error.InvalidDictionaryCache;
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
    try title_map.ensureTotalCapacity(allocator, std.math.cast(u32, state.entries.items.len) orelse return error.InvalidDictionaryFile);

    for (state.entries.items, 0..) |entry, idx| {
        const gop = try title_map.getOrPut(allocator, entry.normalized);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, @intCast(idx));
    }

    const incoming = try allocator.alloc(std.ArrayListUnmanaged(u32), state.entries.items.len);
    defer {
        for (incoming) |*list| list.deinit(allocator);
        allocator.free(incoming);
    }
    for (incoming) |*list| list.* = .empty;

    for (state.entries.items, 0..) |entry, source_idx| {
        for (entry.normalized_targets) |normalized_target| {
            if (title_map.get(normalized_target)) |indices| {
                for (indices.items) |target_idx| {
                    try appendUniqueIndex(allocator, &incoming[target_idx], @intCast(source_idx));
                }
            }
        }
    }

    for (incoming, 0..) |list, idx| {
        if (list.items.len == 0) continue;
        const owned = try arena_allocator.alloc(u32, list.items.len);
        @memcpy(owned, list.items);
        state.entries.items[idx].incoming_aliases = owned;
    }
}

fn appendUniqueIndex(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u32), value: u32) !void {
    for (list.items) |existing| {
        if (existing == value) return;
    }
    try list.append(allocator, value);
}

fn buildLookups(arena_allocator: std.mem.Allocator, state: *BuildState) !void {
    var lookup_count: usize = state.entries.items.len;
    for (state.entries.items) |entry| lookup_count += entry.alt_forms.len;
    try state.lookups.ensureTotalCapacity(arena_allocator, lookup_count);

    for (state.entries.items, 0..) |entry, idx| {
        state.lookups.appendAssumeCapacity(.{
            .key = entry.normalized,
            .matched = entry.word,
            .entry_index = @intCast(idx),
            .kind = format.lookup_kind_title,
        });

        for (entry.alt_forms) |alt_form| {
            state.lookups.appendAssumeCapacity(.{
                .key = alt_form.normalized,
                .matched = alt_form.value,
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

fn upperBoundLookup(self: *const Dictionary, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = self.lookups.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_key = self.lookupKey(self.lookups[mid]);
        if (std.mem.order(u8, mid_key, key) == .gt) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return lo;
}

fn upperBoundPrefixLookup(self: *const Dictionary, prefix: []const u8) usize {
    var next_buf: [256]u8 = undefined;
    const next = nextPrefixKey(prefix, &next_buf) orelse return self.lookups.len;
    return lowerBoundLookup(self, next);
}

fn nextPrefixKey(prefix: []const u8, buffer: *[256]u8) ?[]const u8 {
    if (prefix.len == 0 or prefix.len > 256) return null;

    @memcpy(buffer[0..prefix.len], prefix);
    var i = prefix.len;
    while (i != 0) {
        i -= 1;
        if (buffer[i] != std.math.maxInt(u8)) {
            buffer[i] += 1;
            return buffer[0 .. i + 1];
        }
    }
    return null;
}

test "nextPrefixKey computes the exclusive upper bound for ascii prefixes" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("abd", nextPrefixKey("abc", &buffer).?);
    try std.testing.expectEqualStrings("b", nextPrefixKey("a\xff", &buffer).?);
    try std.testing.expect(nextPrefixKey("\xff\xff", &buffer) == null);
}

test "viewArray rejects misaligned offsets" {
    var bytes: [32]u8 align(std.heap.page_size_min) = [_]u8{0} ** 32;
    try std.testing.expectError(error.InvalidDictionaryCache, viewArray(u32, &bytes, 1, 1));
}

test "cache structs stay compact" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StringRef));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Range));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(CachedEntry));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CachedLookup));
}

test "dictionary open preserves raw etymology and pronunciation sections through cache rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw_english =
        \\==English==
        \\
        \\===Pronunciation===
        \\* {{enPR|rĭng|a=RP,GA}}; {{IPA|en|/ɹɪŋ/}}
        \\** {{audio|en|en-us-ring.ogg|a=US}}
        \\
        \\===Etymology 1===
        \\{{root|en|ine-pro|*(s)ker- (turn)}}
        \\From {{inh|en|enm|ryng}}, from {{inh|en|ang|hring||ring, circle}}.
        \\
        \\{{col-top|2|cog}}
        \\* {{cog|fy|ring}}
        \\* {{cog|de|Ring}}
        \\{{col-bottom}}
        \\
        \\====Noun====
        \\{{en-noun}}
        \\
        \\# {{lb|en|physical}} A solid object in the shape of a circle.
        \\
    ;
    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>ring</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">
    ++ raw_english ++
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    var xml_file = try tmp.dir.createFile(std.testing.io, "sample.xml", .{ .truncate = true });
    defer xml_file.close(std.testing.io);
    try xml_file.writePositionalAll(std.testing.io, xml, 0);

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path);
    defer dict.deinit();

    const hits = try dict.lookupExact(std.testing.allocator, "ring");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);

    const raw = (try dict.entryAt(hits[0].entry_index).rawEnglishAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(raw_english, raw);
}

test "dictionary cache rebuild reuses precomputed normalized alias metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Alternative forms===
        \\* [[co lor]]
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<redirect title="Color"/>
        \\</page>
        \\</mediawiki>
    ;

    var xml_file = try tmp.dir.createFile(std.testing.io, "sample.xml", .{ .truncate = true });
    defer xml_file.close(std.testing.io);
    try xml_file.writePositionalAll(std.testing.io, xml, 0);

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);

    _ = try encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path);
    defer dict.deinit();

    const alt_hits = try dict.lookupExact(std.testing.allocator, "CO_LOR");
    defer std.testing.allocator.free(alt_hits);
    try std.testing.expectEqual(@as(usize, 1), alt_hits.len);
    try std.testing.expectEqual(format.lookup_kind_alternative_form, alt_hits[0].kind);
    try std.testing.expectEqualStrings("co lor", alt_hits[0].matched);

    const color_hits = try dict.lookupExact(std.testing.allocator, "color");
    defer std.testing.allocator.free(color_hits);
    try std.testing.expectEqual(@as(usize, 1), color_hits.len);

    const incoming = dict.entryAt(color_hits[0].entry_index).incomingAliases();
    try std.testing.expectEqual(@as(usize, 1), incoming.len());
    try std.testing.expectEqualStrings("colour", incoming.at(0));

    const redirect_hits = try dict.lookupExact(std.testing.allocator, "colour");
    defer std.testing.allocator.free(redirect_hits);
    try std.testing.expectEqual(@as(usize, 1), redirect_hits.len);
    try std.testing.expectEqual(format.lookup_kind_title, redirect_hits[0].kind);
}

test "replaceFile overwrites an existing cache target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source = try tmp.dir.createFile(std.testing.io, "fresh.idx.tmp", .{ .truncate = true });
    defer source.close(std.testing.io);
    try source.writePositionalAll(std.testing.io, "fresh", 0);

    var target = try tmp.dir.createFile(std.testing.io, "cache.idx", .{ .truncate = true });
    defer target.close(std.testing.io);
    try target.writePositionalAll(std.testing.io, "stale", 0);

    const source_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/fresh.idx.tmp", .{tmp.sub_path});
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/cache.idx", .{tmp.sub_path});
    defer std.testing.allocator.free(target_path);

    try replaceFile(std.testing.io, source_path, target_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target_path, std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("fresh", contents);
}
