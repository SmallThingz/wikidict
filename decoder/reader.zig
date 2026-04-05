const builtin = @import("builtin");
const std = @import("std");

const normalize = @import("normalize");
const compact = @import("compact_runtime.zig");
const format = @import("format.zig");
const wikitext = @import("wikitext_source");
const testing_encoder = if (builtin.is_test) @import("encoder") else struct {};

const cache_magic = "DCTIDX04";
const cache_version: u32 = 7;
const cache_alignment: u32 = 8;

fn isSupportedDictionaryVersion(dict_version: u32) bool {
    return dict_version == format.version;
}

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
    normalized: StringRef,
    incoming_aliases: Range,
    record_offset: u32,
};

const CachedAltForm = extern struct {
    value: StringRef,
    normalized: StringRef,
};

const CachedLookup = extern struct {
    entry_index: u32,
    source_index: u32,
};

const CacheHeader = extern struct {
    magic_bytes: [8]u8,
    version: u32,
    header_size: u32,
    cache_key: u64,
    entry_count: u32,
    alt_form_count: u32,
    incoming_alias_count: u32,
    lookup_count: u32,
    entries_offset: u32,
    alt_forms_offset: u32,
    incoming_aliases_offset: u32,
    lookups_offset: u32,
    strings_offset: u32,
    strings_len: u32,

    fn init(
        cache_key: u64,
        entry_count: u32,
        alt_form_count: u32,
        incoming_alias_count: u32,
        lookup_count: u32,
        entries_offset: u32,
        alt_forms_offset: u32,
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
            .alt_form_count = alt_form_count,
            .incoming_alias_count = incoming_alias_count,
            .lookup_count = lookup_count,
            .alt_forms_offset = alt_forms_offset,
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
    // Filled during cache materialization so repeated lookup refs can reuse a single interned string.
    value_ref: StringRef = .{ .offset = 0, .len = 0 },
    normalized_ref: StringRef = .{ .offset = 0, .len = 0 },
};

const BuildEntryData = struct {
    record_offset: u32,
    word: []const u8,
    normalized: []const u8,
    alt_forms: []BuildAltForm = &.{},
    // Alias-like entries keep their normalized destinations separately so redirect resolution
    // and lookup expansion do not have to reparse raw metadata during cache builds.
    normalized_targets: []const []const u8 = &.{},
    incoming_aliases: []const u32 = &.{},
    word_ref: StringRef = .{ .offset = 0, .len = 0 },
    normalized_ref: StringRef = .{ .offset = 0, .len = 0 },
};

const BuildLookupRecord = struct {
    entry_index: u32,
    alt_form_index: u32 = 0,
    kind: u8,
    reserved: [3]u8 = [_]u8{0} ** 3,
    // Cached four-byte prefixes let the hot sort comparator reject most unequal keys
    // without touching the longer borrowed slices.
    key_head: u32 = 0,
    matched_head: u32 = 0,
    // These borrowed slices point back into already-owned entry/alt-form strings.
    key_ptr: [*]const u8,
    key_len: u32,
    matched_ptr: [*]const u8,
    matched_len: u32,

    fn key(self: BuildLookupRecord) []const u8 {
        return self.key_ptr[0..self.key_len];
    }

    fn matched(self: BuildLookupRecord) []const u8 {
        return self.matched_ptr[0..self.matched_len];
    }
};

const BuildPayload = struct {
    entries: []BuildEntryData,
    lookups: []const BuildLookupRecord,
    // Parallel scan chunks own the per-thread arenas backing borrowed strings in `entries`.
    scan_chunks: []ScanChunkResult = &.{},

    fn deinitTransient(self: *BuildPayload, allocator: std.mem.Allocator) void {
        for (self.scan_chunks) |*chunk| chunk.deinit();
        if (self.scan_chunks.len != 0) allocator.free(self.scan_chunks);
        self.scan_chunks = &.{};
    }
};

const IndexRangeBuilder = struct {
    start: usize = 0,
    len: usize = 0,
    // Reused as a write cursor while packing dense title->entry index ranges.
    cursor: usize = 0,
};

const LookupRun = struct {
    start: usize,
    end: usize,
};

const CacheBuildData = struct {
    entries: []const CachedEntry,
    alt_forms: []const CachedAltForm,
    incoming_aliases: []const u32,
    lookups: []const CachedLookup,
    strings: []const u8,

    fn deinit(self: *CacheBuildData, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.alt_forms);
        allocator.free(self.incoming_aliases);
        allocator.free(self.lookups);
        allocator.free(self.strings);
    }
};

const OpenCache = struct {
    mapping: []align(std.heap.page_size_min) const u8,
    header: *const CacheHeader,
    entries: []const CachedEntry,
    alt_forms: []const CachedAltForm,
    incoming_aliases: []const u32,
    lookups: []const CachedLookup,
    strings: []const u8,
};

const MappedReadOnlyFile = struct {
    stat: std.Io.File.Stat,
    mapping: []align(std.heap.page_size_min) const u8,

    fn bytes(self: MappedReadOnlyFile) []const u8 {
        return self.mapping[0..@as(usize, @intCast(self.stat.size))];
    }

    fn deinit(self: *MappedReadOnlyFile) void {
        std.posix.munmap(self.mapping);
    }
};

const EntryRecordView = struct {
    flags: u8,
    payload: []const u8,
};

pub const OpenOptions = struct {
    index_build_threads: ?usize = null,
};

pub const EntryDerivedData = struct {
    summary: []const u8,
    alt_forms: std.ArrayListUnmanaged([]const u8) = .empty,
    canonical_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    alias_hint_label: []const u8 = "",
    alias_only: bool,

    pub fn deinit(self: *EntryDerivedData, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.alt_forms.items) |value| allocator.free(value);
        self.alt_forms.deinit(allocator);
        for (self.canonical_targets.items) |value| allocator.free(value);
        self.canonical_targets.deinit(allocator);
        if (self.alias_hint_label.len != 0) allocator.free(self.alias_hint_label);
    }
};

const CacheBuildProgress = struct {
    const refresh_interval_ns = std.time.ns_per_s / 20;

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
    last_render_ns: i96 = 0,

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
        const now_ns = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
        if (!shouldRenderNow(self, phase, now_ns)) return;

        self.phase = phase;
        self.last_percent = percent;
        self.last_primary = primary;
        self.last_secondary = secondary;
        self.last_render_ns = now_ns;

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

    fn shouldRenderNow(self: *const CacheBuildProgress, phase: Phase, now_ns: i96) bool {
        if (phase == .done or phase != self.phase) return true;
        return now_ns - self.last_render_ns >= refresh_interval_ns;
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
    title: []const u8,
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

const lookup_kind_alias_expansion: u8 = 2;
const title_lookup_source = std.math.maxInt(u32);

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
            const stored = (try self.rawStoredTextAlloc(allocator)).?;
            defer allocator.free(stored);
            const raw = wikitext.extractEnglishSection(stored) orelse "";
            const raw_owned = try allocator.dupe(u8, raw);
            errdefer allocator.free(raw_owned);

            var metadata = try wikitext.extractEntryMetadata(allocator, self.word(), raw_owned);
            errdefer metadata.deinit(allocator);

            const summary = try wikitext.extractSummaryAlloc(allocator, raw_owned, 240);
            allocator.free(raw_owned);

            return .{
                .summary = summary,
                .alt_forms = metadata.alt_forms,
                .canonical_targets = metadata.canonical_targets,
                .alias_hint_label = metadata.alias_hint_label,
                .alias_only = metadata.alias_only,
            };
        }

        const target = try format.decodeAliasRecordTargetAllocWithMappings(
            allocator,
            entry_record.payload,
            self.dict.compact_mappings.view(),
        );
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
            .alias_hint_label = try allocator.dupe(u8, "Alias of"),
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
            if (derived.alias_hint_label.len != 0) allocator.free(derived.alias_hint_label);
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
            if (derived.alias_hint_label.len != 0) allocator.free(derived.alias_hint_label);
        }
        const owned = try allocator.alloc([]const u8, derived.canonical_targets.items.len);
        @memcpy(owned, derived.canonical_targets.items);
        derived.canonical_targets = .empty;
        return owned;
    }

    pub fn rawEnglishAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        const stored = (try self.rawStoredTextAlloc(allocator)) orelse return null;
        errdefer allocator.free(stored);
        const english = wikitext.extractEnglishSection(stored) orelse {
            allocator.free(stored);
            return null;
        };
        const owned = try allocator.dupe(u8, english);
        allocator.free(stored);
        return owned;
    }

    pub fn rawStoredAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        return self.rawStoredTextAlloc(allocator);
    }

    fn rawStoredTextAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.hasRaw()) return null;
        const entry_record = try self.dict.entryRecord(self.index);
        const encoded = try format.rawRecordContentPayloadVersion(entry_record.payload, self.dict.header.version);
        const decoded = try compact.decodeAllocWithMappings(allocator, encoded, self.dict.compact_mappings.view());
        return decoded;
    }
};

pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    mapping: []align(std.heap.page_size_min) const u8,
    cache_mapping: []align(std.heap.page_size_min) const u8,
    header: format.Header,
    layout: format.DictionaryLayout,
    compact_mappings: compact.OwnedRuntimeMappings,
    cache_header: *const CacheHeader,
    entries: []const CachedEntry,
    alt_forms: []const CachedAltForm,
    incoming_aliases: []const u32,
    lookups: []const CachedLookup,
    strings: []const u8,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: OpenOptions) !Dictionary {
        const db = try mmapReadOnlyPath(io, path);
        errdefer std.posix.munmap(db.mapping);

        const inspected = format.inspectDictionary(db.mapping) catch |err| switch (err) {
            error.InvalidDictionaryFile => return error.InvalidDictionaryFile,
            error.FileTooBig => return error.FileTooBig,
        };
        if (!isSupportedDictionaryVersion(inspected.header.version)) return error.UnsupportedDictionaryVersion;

        const mapping_blob = db.mapping[@as(usize, @intCast(inspected.layout.mappings_offset))..@as(usize, @intCast(inspected.layout.mappings_offset + inspected.layout.mappings_len))];
        var compact_mappings = format.parseCompactMappingsAlloc(allocator, mapping_blob) catch |err| switch (err) {
            error.InvalidDictionaryFile => return error.InvalidDictionaryFile,
            error.FileTooBig => return error.FileTooBig,
            else => return err,
        };
        errdefer compact_mappings.deinit(allocator);

        const cache = try openOrBuildCache(allocator, io, path, db.stat, db.mapping, &inspected.header, inspected.layout, compact_mappings.view(), options);
        errdefer std.posix.munmap(cache.mapping);

        return .{
            .allocator = allocator,
            .mapping = db.mapping,
            .cache_mapping = cache.mapping,
            .header = inspected.header,
            .layout = inspected.layout,
            .compact_mappings = compact_mappings,
            .cache_header = cache.header,
            .entries = cache.entries,
            .alt_forms = cache.alt_forms,
            .incoming_aliases = cache.incoming_aliases,
            .lookups = cache.lookups,
            .strings = cache.strings,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.compact_mappings.deinit(self.allocator);
        std.posix.munmap(self.cache_mapping);
        std.posix.munmap(self.mapping);
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
        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);
        try hits.ensureTotalCapacityPrecise(allocator, end - start);

        for (self.lookups[start..end]) |lookup| {
            const candidate = LookupHit{
                .entry_index = lookup.entry_index,
                .matched = self.lookupMatched(lookup),
                .kind = self.lookupKind(lookup),
            };
            try appendMergedLookupHit(&hits, allocator, term, candidate);
        }

        const direct_hit_count = hits.items.len;
        var alias_targets: std.ArrayList(u32) = .empty;
        defer alias_targets.deinit(allocator);

        for (hits.items[0..direct_hit_count]) |hit| {
            var entry = self.entryAt(hit.entry_index);
            if (!(try entry.isAliasOnlyAlloc(allocator))) continue;

            try alias_targets.resize(allocator, 0);
            try self.collectCanonicalEntryIndexesAlloc(allocator, hit.entry_index, &alias_targets);
            for (alias_targets.items) |canonical_entry_index| {
                if (canonical_entry_index == hit.entry_index or containsLookupHitForEntry(hits.items, canonical_entry_index)) continue;
                try hits.append(allocator, .{
                    .entry_index = canonical_entry_index,
                    .matched = hit.matched,
                    .kind = lookup_kind_alias_expansion,
                });
            }
        }
        return hits.toOwnedSlice(allocator);
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
                .matched = self.lookupMatched(lookup),
                .kind = self.lookupKind(lookup),
            };
            var seen = false;
            for (hits.items) |item| {
                if (item.entry_index == candidate.entry_index and std.mem.eql(u8, item.matched, candidate.matched) and item.kind == candidate.kind) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try hits.append(allocator, candidate);
        }
        return hits.toOwnedSlice(allocator);
    }

    pub fn resolveLinkTargetAlloc(self: *const Dictionary, allocator: std.mem.Allocator, term: []const u8) !?[]const u8 {
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        const normalized = try normalize.normalizeToList(&key_buf, allocator, term);
        if (normalized.len == 0) return null;

        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(allocator);
        return try self.resolveNormalizedLinkTargetAlloc(allocator, term, normalized, &visited);
    }

    fn resolveNormalizedLinkTargetAlloc(
        self: *const Dictionary,
        allocator: std.mem.Allocator,
        term: []const u8,
        normalized: []const u8,
        visited: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!?[]const u8 {
        if (self.resolveBestEntryIndex(term, normalized)) |entry_index| {
            return try self.resolveCanonicalLinkTargetAlloc(allocator, entry_index, visited);
        }
        return null;
    }

    fn resolveBestEntryIndex(self: *const Dictionary, term: []const u8, normalized: []const u8) ?u32 {
        const Candidate = struct {
            entry_index: u32,
            matched: []const u8,
            word: []const u8,
            kind: u8,
        };

        const start = lowerBoundLookup(self, normalized);
        const end = upperBoundLookup(self, normalized);
        if (start == end) return null;

        var best: ?Candidate = null;
        for (self.lookups[start..end]) |lookup| {
            const candidate: Candidate = .{
                .entry_index = lookup.entry_index,
                .matched = self.lookupMatched(lookup),
                .word = self.entryAt(lookup.entry_index).word(),
                .kind = self.lookupKind(lookup),
            };
            if (best == null or preferLinkTarget(term, candidate, best.?)) {
                best = candidate;
            }
        }

        return if (best) |value| value.entry_index else null;
    }

    fn resolveCanonicalLinkTargetAlloc(
        self: *const Dictionary,
        allocator: std.mem.Allocator,
        entry_index: u32,
        visited: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror![]const u8 {
        if (visited.contains(entry_index)) {
            return @as([]const u8, try allocator.dupe(u8, self.entryAt(entry_index).word()));
        }

        try visited.put(allocator, entry_index, {});
        defer _ = visited.remove(entry_index);

        const entry = self.entryAt(entry_index);
        var derived = try entry.derivedAlloc(allocator);
        defer derived.deinit(allocator);

        if (!derived.alias_only or derived.canonical_targets.items.len == 0) {
            return @as([]const u8, try allocator.dupe(u8, entry.word()));
        }

        if (try self.resolveCanonicalTargetsAlloc(allocator, derived.canonical_targets.items, visited)) |resolved| {
            return resolved;
        }
        return @as([]const u8, try allocator.dupe(u8, entry.word()));
    }

    fn resolveCanonicalTargetsAlloc(
        self: *const Dictionary,
        allocator: std.mem.Allocator,
        targets: []const []const u8,
        visited: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!?[]const u8 {
        for (targets) |target| {
            var key_buf: std.ArrayList(u8) = .empty;
            defer key_buf.deinit(allocator);
            const normalized = try normalize.normalizeToList(&key_buf, allocator, target);
            if (normalized.len == 0) continue;

            if (try self.resolveNormalizedLinkTargetAlloc(allocator, target, normalized, visited)) |resolved| {
                return resolved;
            }
            return @as([]const u8, try allocator.dupe(u8, target));
        }
        return null;
    }

    fn collectCanonicalEntryIndexesAlloc(
        self: *const Dictionary,
        allocator: std.mem.Allocator,
        entry_index: u32,
        out: *std.ArrayList(u32),
    ) !void {
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(allocator);
        try self.collectCanonicalEntryIndexes(allocator, entry_index, &visited, out);
    }

    fn collectCanonicalEntryIndexes(
        self: *const Dictionary,
        allocator: std.mem.Allocator,
        entry_index: u32,
        visited: *std.AutoHashMapUnmanaged(u32, void),
        out: *std.ArrayList(u32),
    ) anyerror!void {
        if (visited.contains(entry_index)) return;

        try visited.put(allocator, entry_index, {});
        defer _ = visited.remove(entry_index);

        const entry = self.entryAt(entry_index);
        var derived = try entry.derivedAlloc(allocator);
        defer derived.deinit(allocator);

        if (!derived.alias_only or derived.canonical_targets.items.len == 0) {
            if (!containsU32(out.items, entry_index)) try out.append(allocator, entry_index);
            return;
        }

        for (derived.canonical_targets.items) |target| {
            var key_buf: std.ArrayList(u8) = .empty;
            defer key_buf.deinit(allocator);
            const normalized = try normalize.normalizeToList(&key_buf, allocator, target);
            if (normalized.len == 0) continue;

            if (self.resolveBestEntryIndex(target, normalized)) |target_entry_index| {
                try self.collectCanonicalEntryIndexes(allocator, target_entry_index, visited, out);
            }
        }
    }

    fn string(self: *const Dictionary, ref: StringRef) []const u8 {
        const start: usize = ref.offset;
        const len: usize = ref.len;
        return self.strings[start .. start + len];
    }

    fn preferExactLookupHit(query: []const u8, candidate: LookupHit, current: LookupHit) bool {
        const candidate_exact = std.mem.eql(u8, candidate.matched, query);
        const current_exact = std.mem.eql(u8, current.matched, query);
        if (candidate_exact != current_exact) return candidate_exact;
        if (candidate.kind != current.kind) return candidate.kind < current.kind;
        return std.mem.order(u8, candidate.matched, current.matched) == .lt;
    }

    fn preferLinkTarget(query: []const u8, candidate: anytype, current: @TypeOf(candidate)) bool {
        const candidate_exact = std.mem.eql(u8, candidate.word, query) or std.mem.eql(u8, candidate.matched, query);
        const current_exact = std.mem.eql(u8, current.word, query) or std.mem.eql(u8, current.matched, query);
        if (candidate_exact != current_exact) return candidate_exact;
        if (candidate.kind != current.kind) return candidate.kind < current.kind;
        const word_order = std.mem.order(u8, candidate.word, current.word);
        if (word_order != .eq) return word_order == .lt;
        return std.mem.order(u8, candidate.matched, current.matched) == .lt;
    }

    fn entryRecordStart(self: *const Dictionary, index: u32) usize {
        return @as(usize, @intCast(self.header.records_offset)) + self.entries[index].record_offset;
    }

    fn entryRecord(self: *const Dictionary, index: u32) !EntryRecordView {
        const length_table = self.mapping[@as(usize, @intCast(self.layout.lengths_offset))..@as(usize, @intCast(self.layout.lengths_offset + self.layout.lengths_len))];
        const payload_len = format.payloadLengthAt(length_table, index) catch return error.InvalidDictionaryFile;
        if (payload_len == 0) return error.InvalidDictionaryFile;

        const start = self.entryRecordStart(index);
        const records_end = std.math.cast(usize, self.header.records_offset + self.header.records_len) orelse return error.InvalidDictionaryFile;
        if (start >= records_end) return error.InvalidDictionaryFile;
        if (payload_len > records_end - start) return error.InvalidDictionaryFile;

        const full_payload = self.mapping[start .. start + payload_len];
        return .{
            .flags = full_payload[0],
            .payload = full_payload[1..],
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
        if (lookup.source_index == title_lookup_source) return self.string(self.entries[lookup.entry_index].normalized);
        return self.string(self.alt_forms[lookup.source_index].normalized);
    }

    fn lookupMatched(self: *const Dictionary, lookup: CachedLookup) []const u8 {
        if (lookup.source_index == title_lookup_source) return self.string(self.entries[lookup.entry_index].word);
        return self.string(self.alt_forms[lookup.source_index].value);
    }

    fn lookupKind(self: *const Dictionary, lookup: CachedLookup) u8 {
        _ = self;
        return if (lookup.source_index == title_lookup_source)
            format.lookup_kind_title
        else
            format.lookup_kind_alternative_form;
    }
};

fn appendMergedLookupHit(
    hits: *std.ArrayList(LookupHit),
    allocator: std.mem.Allocator,
    query: []const u8,
    candidate: LookupHit,
) !void {
    for (hits.items) |*existing| {
        if (existing.entry_index != candidate.entry_index) continue;
        if (Dictionary.preferExactLookupHit(query, candidate, existing.*)) existing.* = candidate;
        return;
    }
    try hits.append(allocator, candidate);
}

fn containsLookupHitForEntry(hits: []const LookupHit, entry_index: u32) bool {
    for (hits) |hit| {
        if (hit.entry_index == entry_index) return true;
    }
    return false;
}

fn containsU32(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

const BuildState = struct {
    entries: std.ArrayList(BuildEntryData) = .empty,
    lookups: std.ArrayList(BuildLookupRecord) = .empty,
    scan_chunks: []ScanChunkResult = &.{},
};

const StringInterner = struct {
    allocator: std.mem.Allocator,
    // Maps borrowed string slices to offsets inside `blob`.
    map: std.StringHashMapUnmanaged(StringRef) = .empty,
    // All cached strings are packed contiguously here before the final mmap-friendly cache image is written.
    blob: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .allocator = allocator,
        };
    }

    fn reserve(self: *StringInterner, string_count: usize, total_bytes: usize) !void {
        try self.map.ensureTotalCapacity(self.allocator, std.math.cast(u32, string_count) orelse return error.StringTooLarge);
        try self.blob.ensureTotalCapacity(self.allocator, total_bytes);
    }

    fn deinit(self: *StringInterner) void {
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
        const gop = self.map.getOrPutAssumeCapacity(value);
        if (gop.found_existing) return gop.value_ptr.*;

        const start = self.blob.items.len;
        self.blob.appendSliceAssumeCapacity(value);

        const ref = StringRef{
            .offset = std.math.cast(u32, start) orelse return error.StringTooLarge,
            .len = std.math.cast(u32, value.len) orelse return error.StringTooLarge,
        };

        gop.key_ptr.* = value;
        gop.value_ptr.* = ref;
        return ref;
    }
};

fn internEntryStrings(interner: *StringInterner, entry: *BuildEntryData) !void {
    entry.word_ref = try interner.intern(entry.word);
    entry.normalized_ref = if (std.mem.eql(u8, entry.normalized, entry.word))
        entry.word_ref
    else
        try interner.intern(entry.normalized);

    for (entry.alt_forms) |*alt_form| {
        alt_form.value_ref = if (std.mem.eql(u8, alt_form.value, entry.word))
            entry.word_ref
        else
            try interner.intern(alt_form.value);

        alt_form.normalized_ref = if (std.mem.eql(u8, alt_form.normalized, alt_form.value))
            alt_form.value_ref
        else if (std.mem.eql(u8, alt_form.normalized, entry.normalized))
            entry.normalized_ref
        else
            try interner.intern(alt_form.normalized);
    }
}

fn openOrBuildCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    db_stat: anytype,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    layout: format.DictionaryLayout,
    mappings: compact.RuntimeMappings,
    options: OpenOptions,
) !OpenCache {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{db_path});
    defer allocator.free(cache_path);

    const expected_key = computeCacheKey(db_stat, header);
    if (try tryOpenCache(io, cache_path, expected_key)) |cache| return cache;

    var progress = CacheBuildProgress.init(std.math.cast(usize, header.records_len) orelse return error.FileTooBig);
    try buildAndWriteCache(allocator, io, cache_path, expected_key, mapped, header, layout, mappings, options, &progress);
    return (try tryOpenCache(io, cache_path, expected_key)) orelse error.InvalidDictionaryCache;
}

fn tryOpenCache(io: std.Io, cache_path: []const u8, expected_key: u64) !?OpenCache {
    const cache = mmapReadOnlyPath(io, cache_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer std.posix.munmap(cache.mapping);
    if (cache.stat.size < cache_header_size) return null;

    const header: *const CacheHeader = @ptrCast(@alignCast(cache.mapping.ptr));
    if (!std.mem.eql(u8, &header.magic_bytes, cache_magic) or
        header.version != cache_version or
        header.header_size != cache_header_size or
        header.cache_key != expected_key)
    {
        return null;
    }

    const entries = viewArray(CachedEntry, cache.mapping, header.entries_offset, header.entry_count) catch {
        return null;
    };
    const alt_forms = viewArray(CachedAltForm, cache.mapping, header.alt_forms_offset, header.alt_form_count) catch {
        return null;
    };
    const incoming_aliases = viewArray(u32, cache.mapping, header.incoming_aliases_offset, header.incoming_alias_count) catch {
        return null;
    };
    const lookups = viewArray(CachedLookup, cache.mapping, header.lookups_offset, header.lookup_count) catch {
        return null;
    };
    const strings_offset: usize = header.strings_offset;
    const strings_len: usize = header.strings_len;
    const strings = if (strings_offset <= cache.mapping.len and strings_len <= cache.mapping.len - strings_offset)
        cache.mapping[strings_offset .. strings_offset + strings_len]
    else {
        return null;
    };

    return .{
        .mapping = cache.mapping,
        .header = header,
        .entries = entries,
        .alt_forms = alt_forms,
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
    layout: format.DictionaryLayout,
    mappings: compact.RuntimeMappings,
    options: OpenOptions,
    progress: *CacheBuildProgress,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var build_payload = buildCachePayload(allocator, arena.allocator(), mapped, header, layout, mappings, options, progress) catch |err| {
        std.log.err("failed to build dictionary cache payload: {s}", .{@errorName(err)});
        return err;
    };
    defer build_payload.deinitTransient(allocator);
    progress.setPhase(.materialize, 92, build_payload.entries.len, build_payload.lookups.len);
    var cache_data = materializeCacheData(allocator, &build_payload) catch |err| {
        std.log.err("failed to materialize dictionary cache: {s}", .{@errorName(err)});
        return err;
    };
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
    layout: format.DictionaryLayout,
    mappings: compact.RuntimeMappings,
    options: OpenOptions,
    progress: *CacheBuildProgress,
) !BuildPayload {
    var state = buildIndex(allocator, arena_allocator, mapped, header, layout, mappings, options, progress) catch |err| {
        std.log.err("failed during record scan/index build: {s}", .{@errorName(err)});
        return err;
    };
    progress.setPhase(.aliases, 75, state.entries.items.len, 0);
    finalizeIncomingAliases(allocator, arena_allocator, &state) catch |err| {
        std.log.err("failed while resolving incoming aliases: {s}", .{@errorName(err)});
        return err;
    };
    progress.setPhase(.lookups, 84, state.entries.items.len, 0);
    buildLookups(allocator, arena_allocator, &state, indexBuildThreadCount(state.entries.items.len, options.index_build_threads)) catch |err| {
        std.log.err("failed while sorting/building lookups: {s}", .{@errorName(err)});
        return err;
    };
    return .{
        .entries = try state.entries.toOwnedSlice(arena_allocator),
        .lookups = try state.lookups.toOwnedSlice(arena_allocator),
        .scan_chunks = state.scan_chunks,
    };
}

fn materializeCacheData(allocator: std.mem.Allocator, payload: *BuildPayload) !CacheBuildData {
    var interner = StringInterner.init(allocator);
    defer interner.deinit();

    var intern_call_count: usize = 0;
    var total_string_bytes: usize = 0;
    for (payload.entries) |entry| {
        intern_call_count += 2 + (entry.alt_forms.len * 2);
        total_string_bytes += entry.word.len + entry.normalized.len;
        for (entry.alt_forms) |alt_form| {
            total_string_bytes += alt_form.value.len + alt_form.normalized.len;
        }
    }
    try interner.reserve(intern_call_count, total_string_bytes);

    var incoming_alias_count: usize = 0;
    for (payload.entries) |entry| {
        incoming_alias_count += entry.incoming_aliases.len;
    }

    const entries = try allocator.alloc(CachedEntry, payload.entries.len);
    errdefer allocator.free(entries);
    var alt_form_count: usize = 0;
    for (payload.entries) |entry| alt_form_count += entry.alt_forms.len;
    const alt_forms = try allocator.alloc(CachedAltForm, alt_form_count);
    errdefer allocator.free(alt_forms);
    const incoming_aliases = try allocator.alloc(u32, incoming_alias_count);
    errdefer allocator.free(incoming_aliases);

    var incoming_cursor: usize = 0;
    const entry_alt_bases = try allocator.alloc(u32, payload.entries.len);
    defer allocator.free(entry_alt_bases);
    var alt_form_cursor: usize = 0;
    for (payload.entries, 0..) |*entry, idx| {
        try internEntryStrings(&interner, entry);
        entry_alt_bases[idx] = std.math.cast(u32, alt_form_cursor) orelse return error.StringListTooLarge;

        for (entry.alt_forms) |alt_form| {
            alt_forms[alt_form_cursor] = .{
                .value = alt_form.value_ref,
                .normalized = alt_form.normalized_ref,
            };
            alt_form_cursor += 1;
        }

        const incoming_len = entry.incoming_aliases.len;
        if (incoming_len != 0) {
            @memcpy(
                incoming_aliases[incoming_cursor .. incoming_cursor + incoming_len],
                entry.incoming_aliases,
            );
        }
        entries[idx] = .{
            .word = entry.word_ref,
            .normalized = entry.normalized_ref,
            .incoming_aliases = .{
                .start = std.math.cast(u32, incoming_cursor) orelse return error.StringListTooLarge,
                .len = std.math.cast(u32, incoming_len) orelse return error.StringListTooLarge,
            },
            .record_offset = entry.record_offset,
        };
        incoming_cursor += incoming_len;
    }

    const lookups = try allocator.alloc(CachedLookup, payload.lookups.len);
    errdefer allocator.free(lookups);

    for (payload.lookups, 0..) |lookup, idx| {
        lookups[idx] = .{
            .entry_index = lookup.entry_index,
            .source_index = switch (lookup.kind) {
                format.lookup_kind_title => title_lookup_source,
                format.lookup_kind_alternative_form => entry_alt_bases[lookup.entry_index] + lookup.alt_form_index,
                else => return error.InvalidDictionaryCache,
            },
        };
    }

    return .{
        .entries = entries,
        .alt_forms = alt_forms,
        .incoming_aliases = incoming_aliases,
        .lookups = lookups,
        .strings = try interner.intoOwnedBlob(),
    };
}

fn writeCacheFile(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8, cache_key: u64, cache: CacheBuildData) !void {
    const entries_offset = std.mem.alignForward(u32, cache_header_size, @alignOf(CachedEntry));
    const entries_len = std.math.cast(u32, std.math.mul(usize, cache.entries.len, @sizeOf(CachedEntry)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const alt_forms_offset = std.mem.alignForward(u32, entries_offset + entries_len, @alignOf(CachedAltForm));
    const alt_forms_len = std.math.cast(u32, std.math.mul(usize, cache.alt_forms.len, @sizeOf(CachedAltForm)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const incoming_aliases_offset = std.mem.alignForward(u32, alt_forms_offset + alt_forms_len, @alignOf(u32));
    const incoming_aliases_len = std.math.cast(u32, std.math.mul(usize, cache.incoming_aliases.len, @sizeOf(u32)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const lookups_offset = std.mem.alignForward(u32, incoming_aliases_offset + incoming_aliases_len, @alignOf(CachedLookup));
    const lookups_len = std.math.cast(u32, std.math.mul(usize, cache.lookups.len, @sizeOf(CachedLookup)) catch return error.FileTooBig) orelse return error.FileTooBig;
    const strings_offset = lookups_offset + lookups_len;
    const strings_len = std.math.cast(u32, cache.strings.len) orelse return error.FileTooBig;
    const total_len = strings_offset + strings_len;

    const header = CacheHeader.init(
        cache_key,
        std.math.cast(u32, cache.entries.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.alt_forms.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.incoming_aliases.len) orelse return error.FileTooBig,
        std.math.cast(u32, cache.lookups.len) orelse return error.FileTooBig,
        entries_offset,
        alt_forms_offset,
        incoming_aliases_offset,
        lookups_offset,
        strings_offset,
        strings_len,
    );

    const temp_cache_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path});
    defer allocator.free(temp_cache_path);
    try deleteFileIfExists(io, temp_cache_path);
    defer deleteFileIfExists(io, temp_cache_path) catch {};

    var mapped_file = try createMappedWritableFile(temp_cache_path, total_len);
    defer mapped_file.deinit();

    const mapped = mapped_file.bytes();
    @memcpy(mapped[0..@sizeOf(CacheHeader)], std.mem.asBytes(&header));
    if (cache.entries.len != 0) @memcpy(mapped[entries_offset .. entries_offset + entries_len], std.mem.sliceAsBytes(cache.entries));
    if (cache.alt_forms.len != 0) @memcpy(mapped[alt_forms_offset .. alt_forms_offset + alt_forms_len], std.mem.sliceAsBytes(cache.alt_forms));
    if (cache.incoming_aliases.len != 0) @memcpy(mapped[incoming_aliases_offset .. incoming_aliases_offset + incoming_aliases_len], std.mem.sliceAsBytes(cache.incoming_aliases));
    if (cache.lookups.len != 0) @memcpy(mapped[lookups_offset .. lookups_offset + lookups_len], std.mem.sliceAsBytes(cache.lookups));
    if (cache.strings.len != 0) @memcpy(mapped[strings_offset .. strings_offset + strings_len], cache.strings);
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

fn buildIndex(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    layout: format.DictionaryLayout,
    mappings: compact.RuntimeMappings,
    options: OpenOptions,
    progress: *CacheBuildProgress,
) !BuildState {
    const descriptors = try collectRecordDescriptors(arena_allocator, mapped, header, layout);

    var state: BuildState = .{};
    try state.entries.ensureTotalCapacity(arena_allocator, descriptors.len);

    const thread_count = indexBuildThreadCount(descriptors.len, options.index_build_threads);
    progress.setReadingParallel(thread_count > 1);
    if (thread_count == 1) {
        for (descriptors) |descriptor| {
            const entry = buildEntryFromRecord(arena_allocator, descriptor, header.version, mappings) catch |err| {
                std.log.err("failed to decode dictionary record at offset {d}: {s}", .{ descriptor.record_offset, @errorName(err) });
                return err;
            };
            state.entries.appendAssumeCapacity(entry);
            progress.scanAdvance(descriptor.record_len, 1);
        }
        return state;
    }

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);
    const chunks = try allocator.alloc(ScanChunkResult, thread_count);
    for (chunks) |*chunk| chunk.* = ScanChunkResult.init();

    var started_threads: usize = 0;
    errdefer {
        for (threads[0..started_threads]) |thread| thread.join();
        for (chunks) |*chunk| chunk.deinit();
        allocator.free(chunks);
    }
    var start: usize = 0;
    for (chunks, threads, 0..) |*chunk, *thread, i| {
        const end = partitionEnd(descriptors.len, thread_count, i);
        thread.* = try std.Thread.spawn(.{}, scanRecordChunk, .{
            descriptors[start..end],
            chunk,
            progress,
            header.version,
            mappings,
        });
        started_threads += 1;
        start = end;
    }
    for (threads) |thread| thread.join();

    for (chunks) |*chunk| {
        if (chunk.err) |err| return err;
        for (chunk.entries) |entry| {
            state.entries.appendAssumeCapacity(entry);
        }
    }
    state.scan_chunks = chunks;

    return state;
}

fn collectRecordDescriptors(
    allocator: std.mem.Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    layout: format.DictionaryLayout,
) ![]const RecordDescriptor {
    const entry_count: usize = header.entry_count;
    const descriptors = try allocator.alloc(RecordDescriptor, entry_count);
    errdefer allocator.free(descriptors);

    const length_bytes = mapped[@as(usize, @intCast(layout.lengths_offset))..@as(usize, @intCast(layout.lengths_offset + layout.lengths_len))];
    const titles_end: usize = @intCast(layout.titles_offset + layout.titles_len);
    const records_start: usize = @intCast(layout.records_offset);
    const records_end: usize = @intCast(layout.records_offset + layout.records_len);

    var title_cursor: usize = @intCast(layout.titles_offset);
    var payload_cursor: usize = records_start;
    for (descriptors, 0..) |*descriptor, idx| {
        const title = try readNullTerminatedSlice(mapped, &title_cursor, titles_end);
        const payload_len = format.payloadLengthAt(length_bytes, idx) catch return error.InvalidDictionaryFile;
        if (payload_len == 0 or payload_len > records_end - payload_cursor) return error.InvalidDictionaryFile;
        const full_payload = mapped[payload_cursor .. payload_cursor + payload_len];
        const record_offset = payload_cursor - records_start;
        payload_cursor += payload_len;

        descriptor.* = .{
            .record_offset = std.math.cast(u32, record_offset) orelse return error.InvalidDictionaryFile,
            .flags = full_payload[0],
            .title = title,
            .payload = full_payload[1..],
            .record_len = payload_len,
        };
    }
    if (title_cursor != titles_end or payload_cursor != records_end) return error.InvalidDictionaryFile;
    return descriptors;
}

fn buildEntryFromRecord(
    allocator: std.mem.Allocator,
    descriptor: RecordDescriptor,
    dictionary_version: u32,
    mappings: compact.RuntimeMappings,
) !BuildEntryData {
    if (dictionary_version != format.version) return error.InvalidDictionaryFile;
    const word = try allocator.dupe(u8, descriptor.title);
    const normalized = if (normalize.isIdentity(word))
        word
    else
        try normalize.normalizeAlloc(allocator, word);
    var entry = BuildEntryData{
        .record_offset = descriptor.record_offset,
        .word = word,
        .normalized = normalized,
    };

    if ((descriptor.flags & format.record_flag_has_raw) != 0) {
        const metadata = try decodeBuildRawMetadataAlloc(allocator, descriptor.payload, dictionary_version, mappings);
        entry.alt_forms = metadata.alt_forms;
        entry.normalized_targets = metadata.canonical_targets;
        return entry;
    }

    const target = format.decodeAliasRecordTargetAllocWithMappings(allocator, descriptor.payload, mappings) catch return error.InvalidDictionaryFile;
    const normalized_target = if (normalize.isIdentity(target)) blk: {
        break :blk target;
    } else blk: {
        defer allocator.free(target);
        break :blk try normalize.normalizeAlloc(allocator, target);
    };
    const targets = try allocator.alloc([]const u8, 1);
    targets[0] = normalized_target;
    entry.normalized_targets = targets;
    return entry;
}

const BuildRawMetadata = struct {
    alt_forms: []BuildAltForm,
    canonical_targets: []const []const u8,
};

fn decodeBuildRawMetadataAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
    dictionary_version: u32,
    mappings: compact.RuntimeMappings,
) !BuildRawMetadata {
    if (dictionary_version != format.version) return error.InvalidDictionaryFile;
    const metadata = format.decodeRawRecordMetadataAllocWithMappings(allocator, payload, mappings) catch return error.InvalidDictionaryFile;
    const alt_forms = try allocator.alloc(BuildAltForm, metadata.alt_forms.len);
    errdefer allocator.free(alt_forms);
    var alt_index: usize = 0;
    errdefer {
        while (alt_index < metadata.alt_forms.len) : (alt_index += 1) allocator.free(metadata.alt_forms[alt_index]);
        allocator.free(metadata.alt_forms);
        for (metadata.canonical_targets) |target| allocator.free(target);
        allocator.free(metadata.canonical_targets);
    }
    errdefer {
        while (alt_index > 0) : (alt_index -= 1) {
            allocator.free(alt_forms[alt_index - 1].value);
            if (!std.mem.eql(u8, alt_forms[alt_index - 1].normalized, alt_forms[alt_index - 1].value)) {
                allocator.free(alt_forms[alt_index - 1].normalized);
            }
        }
    }
    for (metadata.alt_forms, 0..) |value, idx| {
        const normalized = if (normalize.isIdentity(value))
            value
        else
            try normalize.normalizeAlloc(allocator, value);
        alt_forms[idx] = .{
            .value = value,
            .normalized = normalized,
        };
        alt_index += 1;
    }
    allocator.free(metadata.alt_forms);

    return .{
        .alt_forms = alt_forms,
        .canonical_targets = metadata.canonical_targets,
    };
}

fn scanRecordChunk(
    descriptors: []const RecordDescriptor,
    chunk: *ScanChunkResult,
    progress: *CacheBuildProgress,
    dictionary_version: u32,
    mappings: compact.RuntimeMappings,
) void {
    const allocator = chunk.arena.allocator();
    chunk.entries = allocator.alloc(BuildEntryData, descriptors.len) catch |err| {
        chunk.err = err;
        return;
    };

    var pending_entries: usize = 0;
    var pending_bytes: usize = 0;
    for (descriptors, 0..) |descriptor, idx| {
        chunk.entries[idx] = buildEntryFromRecord(allocator, descriptor, dictionary_version, mappings) catch |err| {
            std.log.err("failed to decode dictionary record at offset {d}: {s}", .{ descriptor.record_offset, @errorName(err) });
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

fn partitionEnd(total: usize, part_count: usize, part_index: usize) usize {
    return @divTrunc(total * (part_index + 1), part_count);
}

fn indexBuildThreadCount(entry_count: usize, thread_override: ?usize) usize {
    if (builtin.single_threaded or entry_count < 128) return 1;
    if (thread_override) |requested| return @max(@as(usize, 1), requested);
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(cpu_count, entry_count / 64));
}

fn mapWholeFile(file: std.Io.File, size_u64: u64) ![]align(std.heap.page_size_min) const u8 {
    const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
    if (size == 0) return error.InvalidDictionaryFile;

    return try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

fn mmapReadOnlyPath(io: std.Io, path: []const u8) !MappedReadOnlyFile {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    var file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const mapping = try mapWholeFile(file, stat.size);
    return .{
        .stat = stat,
        .mapping = mapping,
    };
}

const MappedWritableFile = struct {
    fd: std.posix.fd_t,
    mapping: []align(std.heap.page_size_min) u8,
    finished: bool = false,

    fn bytes(self: *MappedWritableFile) []u8 {
        return self.mapping;
    }

    fn finish(self: *MappedWritableFile, final_len: usize) !void {
        if (self.finished) return;
        std.posix.munmap(self.mapping);
        self.mapping = undefined;
        try truncateFd(self.fd, final_len);
        _ = std.os.linux.close(self.fd);
        self.finished = true;
    }

    fn deinit(self: *MappedWritableFile) void {
        if (self.finished) return;
        std.posix.munmap(self.mapping);
        _ = std.os.linux.close(self.fd);
        self.finished = true;
    }
};

fn createMappedWritableFile(path: []const u8, len: u32) !MappedWritableFile {
    const len_usize = std.math.cast(usize, len) orelse return error.FileTooBig;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o666);
    errdefer _ = std.os.linux.close(fd);

    try truncateFd(fd, len_usize);
    const mapping = try std.posix.mmap(
        null,
        len_usize,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    return .{
        .fd = fd,
        .mapping = mapping,
    };
}

fn writeMappedFile(path: []const u8, bytes: []const u8) !void {
    const len = std.math.cast(u32, @max(bytes.len, 1)) orelse return error.FileTooBig;
    var mapped_file = try createMappedWritableFile(path, len);
    defer mapped_file.deinit();
    @memcpy(mapped_file.bytes()[0..bytes.len], bytes);
    try mapped_file.finish(bytes.len);
}

fn truncateFd(fd: std.posix.fd_t, length: usize) !void {
    const signed_length = std.math.cast(i64, length) orelse return error.FileTooBig;
    switch (builtin.os.tag) {
        .linux => switch (std.posix.errno(std.os.linux.ftruncate(fd, signed_length))) {
            .SUCCESS => {},
            .INTR => return truncateFd(fd, length),
            .ACCES => return error.AccessDenied,
            .BADF => return error.FileNotFound,
            .FBIG => return error.FileTooBig,
            .INVAL => return error.InvalidArgument,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.FileBusy,
            else => |err| return std.posix.unexpectedErrno(err),
        },
        else => @compileError("truncateFd is only implemented for Linux"),
    }
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

fn computeCacheKey(stat: anytype, header: *const format.Header) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const size: u64 = @intCast(stat.size);
    const mtime_ns: i128 = stat.mtime.nanoseconds;
    const version: u32 = header.version;
    const reserved0: u32 = header.reserved0;
    const entry_count: u32 = header.entry_count;
    const raw_entry_count: u32 = header.raw_entry_count;
    const redirect_count: u32 = header.redirect_count;
    const lengths_offset: u64 = header.lengths_offset;
    const lengths_len: u64 = header.lengths_len;
    const mappings_offset: u64 = header.mappings_offset;
    const mappings_len: u64 = header.mappings_len;
    const titles_offset: u64 = header.titles_offset;
    const titles_len: u64 = header.titles_len;
    const records_offset: u64 = header.records_offset;
    const records_len: u64 = header.records_len;

    inline for (.{
        size,
        mtime_ns,
        version,
        reserved0,
        entry_count,
        raw_entry_count,
        redirect_count,
        lengths_offset,
        lengths_len,
        mappings_offset,
        mappings_len,
        titles_offset,
        titles_len,
        records_offset,
        records_len,
    }) |value| hasher.update(std.mem.asBytes(&value));
    return hasher.final();
}

fn readNullTerminatedSlice(bytes: []const u8, cursor: *usize, limit: usize) ![]const u8 {
    if (cursor.* >= limit) return error.InvalidDictionaryFile;
    const terminator = std.mem.indexOfScalarPos(u8, bytes, cursor.*, 0) orelse return error.InvalidDictionaryFile;
    if (terminator >= limit) return error.InvalidDictionaryFile;
    const out = bytes[cursor.*..terminator];
    cursor.* = terminator + 1;
    return out;
}

fn finalizeIncomingAliases(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    state: *BuildState,
) !void {
    var title_map = std.StringHashMapUnmanaged(IndexRangeBuilder).empty;
    defer title_map.deinit(allocator);
    try title_map.ensureTotalCapacity(allocator, std.math.cast(u32, state.entries.items.len) orelse return error.InvalidDictionaryFile);

    for (state.entries.items) |entry| {
        const gop = try title_map.getOrPut(allocator, entry.normalized);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.len += 1;
    }

    var title_indices_cursor: usize = 0;
    var title_it = title_map.iterator();
    while (title_it.next()) |entry| {
        entry.value_ptr.start = title_indices_cursor;
        entry.value_ptr.cursor = 0;
        title_indices_cursor += entry.value_ptr.len;
    }

    const title_indices = try allocator.alloc(u32, title_indices_cursor);
    defer allocator.free(title_indices);

    for (state.entries.items, 0..) |entry, idx| {
        const range = title_map.getPtr(entry.normalized).?;
        title_indices[range.start + range.cursor] = @intCast(idx);
        range.cursor += 1;
    }

    const incoming_counts = try allocator.alloc(usize, state.entries.items.len);
    defer allocator.free(incoming_counts);
    @memset(incoming_counts, 0);

    for (state.entries.items) |entry| {
        for (entry.normalized_targets) |normalized_target| {
            if (title_map.get(normalized_target)) |range| {
                const target_indices = title_indices[range.start .. range.start + range.len];
                for (target_indices) |target_idx| incoming_counts[target_idx] += 1;
            }
        }
    }

    const incoming_offsets = try allocator.alloc(usize, state.entries.items.len + 1);
    defer allocator.free(incoming_offsets);
    incoming_offsets[0] = 0;
    for (incoming_counts, 0..) |count, idx| {
        incoming_offsets[idx + 1] = incoming_offsets[idx] + count;
    }

    const incoming_refs = try allocator.alloc(u32, incoming_offsets[state.entries.items.len]);
    defer allocator.free(incoming_refs);
    const incoming_cursors = try allocator.alloc(usize, state.entries.items.len);
    defer allocator.free(incoming_cursors);
    @memcpy(incoming_cursors, incoming_offsets[0..state.entries.items.len]);

    for (state.entries.items, 0..) |entry, source_idx| {
        for (entry.normalized_targets) |normalized_target| {
            if (title_map.get(normalized_target)) |range| {
                const target_indices = title_indices[range.start .. range.start + range.len];
                for (target_indices) |target_idx| {
                    const cursor = incoming_cursors[target_idx];
                    incoming_refs[cursor] = @intCast(source_idx);
                    incoming_cursors[target_idx] = cursor + 1;
                }
            }
        }
    }

    for (state.entries.items, 0..) |*entry, idx| {
        const start = incoming_offsets[idx];
        const end = incoming_offsets[idx + 1];
        if (start == end) continue;

        const refs = incoming_refs[start..end];
        var out_len: usize = 1;
        for (refs[1..]) |value| {
            if (value == refs[out_len - 1]) continue;
            refs[out_len] = value;
            out_len += 1;
        }
        const unique_slice = refs[0..out_len];
        const owned = try arena_allocator.alloc(u32, unique_slice.len);
        @memcpy(owned, unique_slice);
        entry.incoming_aliases = owned;
    }
}

fn buildLookups(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    state: *BuildState,
    thread_count: usize,
) !void {
    const lookup_count = lookupCountForEntries(state.entries.items);
    try state.lookups.ensureTotalCapacity(arena_allocator, lookup_count);
    state.lookups.items.len = lookup_count;

    const worker_count = if (thread_count < 2 or state.entries.items.len < 1024)
        1
    else
        @min(thread_count, @max(@as(usize, 1), state.entries.items.len / 1024));
    if (worker_count == 1) {
        fillLookupChunk(state.entries.items, 0, state.lookups.items);
        try sortLookups(allocator, state.lookups.items, 1);
        return;
    }

    const runs = try allocator.alloc(LookupRun, worker_count);
    defer allocator.free(runs);

    var entry_start: usize = 0;
    var lookup_start: usize = 0;
    for (runs, 0..) |*run, idx| {
        const entry_end = partitionEnd(state.entries.items.len, worker_count, idx);
        const chunk_entries = state.entries.items[entry_start..entry_end];
        const chunk_lookup_count = lookupCountForEntries(chunk_entries);
        run.* = .{
            .start = lookup_start,
            .end = lookup_start + chunk_lookup_count,
        };
        lookup_start += chunk_lookup_count;
        entry_start = entry_end;
    }

    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    entry_start = partitionEnd(state.entries.items.len, worker_count, 0);
    var started_threads: usize = 0;
    errdefer for (threads[0..started_threads]) |thread| thread.join();
    for (runs[1..], threads, 1..) |run, *thread, idx| {
        const entry_end = partitionEnd(state.entries.items.len, worker_count, idx);
        thread.* = try std.Thread.spawn(.{}, fillAndSortLookupChunk, .{
            state.entries.items[entry_start..entry_end],
            entry_start,
            state.lookups.items[run.start..run.end],
        });
        started_threads += 1;
        entry_start = entry_end;
    }

    fillAndSortLookupChunk(
        state.entries.items[0..partitionEnd(state.entries.items.len, worker_count, 0)],
        0,
        state.lookups.items[runs[0].start..runs[0].end],
    );
    for (threads[0..started_threads]) |thread| thread.join();

    try mergeLookupRuns(allocator, state.lookups.items, runs, worker_count);
}

fn lookupCountForEntries(entries: []const BuildEntryData) usize {
    var count: usize = entries.len;
    for (entries) |entry| count += entry.alt_forms.len;
    return count;
}

fn fillAndSortLookupChunk(
    entries: []const BuildEntryData,
    base_entry_index: usize,
    out: []BuildLookupRecord,
) void {
    fillLookupChunk(entries, base_entry_index, out);
    std.mem.sort(BuildLookupRecord, out, {}, lessThanLookup);
}

fn fillLookupChunk(entries: []const BuildEntryData, base_entry_index: usize, out: []BuildLookupRecord) void {
    var out_index: usize = 0;
    for (entries, 0..) |entry, local_idx| {
        std.debug.assert(entry.normalized.len <= std.math.maxInt(u32));
        std.debug.assert(entry.word.len <= std.math.maxInt(u32));
        out[out_index] = .{
            .entry_index = @intCast(base_entry_index + local_idx),
            .alt_form_index = 0,
            .kind = format.lookup_kind_title,
            .key_head = packedSortPrefix(entry.normalized),
            .matched_head = packedSortPrefix(entry.word),
            .key_ptr = entry.normalized.ptr,
            .key_len = @intCast(entry.normalized.len),
            .matched_ptr = entry.word.ptr,
            .matched_len = @intCast(entry.word.len),
        };
        out_index += 1;

        for (entry.alt_forms, 0..) |alt_form, alt_form_idx| {
            std.debug.assert(alt_form.normalized.len <= std.math.maxInt(u32));
            std.debug.assert(alt_form.value.len <= std.math.maxInt(u32));
            out[out_index] = .{
                .entry_index = @intCast(base_entry_index + local_idx),
                .alt_form_index = @intCast(alt_form_idx),
                .kind = format.lookup_kind_alternative_form,
                .key_head = packedSortPrefix(alt_form.normalized),
                .matched_head = packedSortPrefix(alt_form.value),
                .key_ptr = alt_form.normalized.ptr,
                .key_len = @intCast(alt_form.normalized.len),
                .matched_ptr = alt_form.value.ptr,
                .matched_len = @intCast(alt_form.value.len),
            };
            out_index += 1;
        }
    }
    std.debug.assert(out_index == out.len);
}

fn packedSortPrefix(value: []const u8) u32 {
    var out: u32 = 0;
    const len = @min(value.len, 4);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        out = (out << 8) | value[i];
    }
    while (i < 4) : (i += 1) {
        out <<= 8;
    }
    return out;
}

fn lessThanLookup(_: void, lhs: BuildLookupRecord, rhs: BuildLookupRecord) bool {
    if (lhs.key_head != rhs.key_head) return lhs.key_head < rhs.key_head;
    switch (std.mem.order(u8, lhs.key(), rhs.key())) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
    if (lhs.matched_head != rhs.matched_head) return lhs.matched_head < rhs.matched_head;
    return std.mem.order(u8, lhs.matched(), rhs.matched()) == .lt;
}

fn sortLookups(
    allocator: std.mem.Allocator,
    lookups: []BuildLookupRecord,
    thread_count: usize,
) !void {
    _ = allocator;
    _ = thread_count;
    std.mem.sort(BuildLookupRecord, lookups, {}, lessThanLookup);
}

fn mergeLookupRuns(
    allocator: std.mem.Allocator,
    lookups: []BuildLookupRecord,
    runs: []const LookupRun,
    thread_count: usize,
) !void {
    if (runs.len <= 1) return;

    const temp = try allocator.alloc(BuildLookupRecord, lookups.len);
    defer allocator.free(temp);
    var src = lookups;
    var dst = temp;

    var current_runs = try allocator.alloc(LookupRun, runs.len);
    defer allocator.free(current_runs);
    @memcpy(current_runs, runs);
    var next_runs = try allocator.alloc(LookupRun, runs.len);
    defer allocator.free(next_runs);

    var run_count = runs.len;
    var src_is_primary = true;
    while (run_count > 1) {
        const pair_count = run_count / 2;
        const merge_threads = if (thread_count < 2 or pair_count < 2) 0 else pair_count - 1;
        const jobs = try allocator.alloc(LookupMergeJob, pair_count);
        defer allocator.free(jobs);
        const threads = try allocator.alloc(std.Thread, merge_threads);
        defer allocator.free(threads);

        var next_count: usize = 0;
        var started_threads: usize = 0;
        errdefer for (threads[0..started_threads]) |thread| thread.join();

        for (0..pair_count) |pair_idx| {
            const left = current_runs[pair_idx * 2];
            const right = current_runs[pair_idx * 2 + 1];
            jobs[pair_idx] = .{
                .left = src[left.start..left.end],
                .right = src[right.start..right.end],
                .out = dst[left.start..right.end],
            };
            if (pair_idx == 0 or pair_idx > merge_threads) {
                jobs[pair_idx].run();
            } else {
                threads[started_threads] = try std.Thread.spawn(.{}, runLookupMergeJob, .{&jobs[pair_idx]});
                started_threads += 1;
            }
            next_runs[next_count] = .{
                .start = left.start,
                .end = right.end,
            };
            next_count += 1;
        }
        for (threads[0..started_threads]) |thread| thread.join();

        if (run_count % 2 != 0) {
            const trailing = current_runs[run_count - 1];
            @memcpy(dst[trailing.start..trailing.end], src[trailing.start..trailing.end]);
            next_runs[next_count] = trailing;
            next_count += 1;
        }

        const tmp_slice = src;
        src = dst;
        dst = tmp_slice;
        const tmp_runs = current_runs;
        current_runs = next_runs;
        next_runs = tmp_runs;
        run_count = next_count;
        src_is_primary = !src_is_primary;
    }

    if (!src_is_primary) @memcpy(lookups, src);
}

const LookupMergeJob = struct {
    left: []const BuildLookupRecord,
    right: []const BuildLookupRecord,
    out: []BuildLookupRecord,

    fn run(self: *const LookupMergeJob) void {
        mergeSortedLookups(self.left, self.right, self.out);
    }
};

fn runLookupMergeJob(job: *const LookupMergeJob) void {
    job.run();
}

fn mergeSortedLookups(
    left: []const BuildLookupRecord,
    right: []const BuildLookupRecord,
    out: []BuildLookupRecord,
) void {
    var left_index: usize = 0;
    var right_index: usize = 0;
    var out_index: usize = 0;

    while (left_index < left.len and right_index < right.len) {
        if (lessThanLookup({}, right[right_index], left[left_index])) {
            out[out_index] = right[right_index];
            right_index += 1;
        } else {
            out[out_index] = left[left_index];
            left_index += 1;
        }
        out_index += 1;
    }

    if (left_index < left.len) {
        @memcpy(out[out_index .. out_index + (left.len - left_index)], left[left_index..]);
        out_index += left.len - left_index;
    }
    if (right_index < right.len) {
        @memcpy(out[out_index .. out_index + (right.len - right_index)], right[right_index..]);
    }
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
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(CachedEntry));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CachedAltForm));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CachedLookup));
}

test "packedSortPrefix preserves lexicographic order for short ascii prefixes" {
    try std.testing.expect(packedSortPrefix("a") < packedSortPrefix("aa"));
    try std.testing.expect(packedSortPrefix("ab") < packedSortPrefix("ac"));
    try std.testing.expect(packedSortPrefix("abcd") < packedSortPrefix("abce"));
}

test "internEntryStrings reuses equivalent local refs" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    try interner.reserve(8, 64);

    var alt_forms = [_]BuildAltForm{
        .{ .value = "alpha", .normalized = "alpha" },
        .{ .value = "Beta", .normalized = "alpha" },
    };
    var entry = BuildEntryData{
        .record_offset = 0,
        .word = "alpha",
        .normalized = "alpha",
        .alt_forms = &alt_forms,
    };

    try internEntryStrings(&interner, &entry);

    try std.testing.expectEqualDeep(entry.word_ref, entry.normalized_ref);
    try std.testing.expectEqualDeep(entry.word_ref, entry.alt_forms[0].value_ref);
    try std.testing.expectEqualDeep(entry.alt_forms[0].value_ref, entry.alt_forms[0].normalized_ref);
    try std.testing.expectEqualDeep(entry.normalized_ref, entry.alt_forms[1].normalized_ref);
}

test "decodeBuildRawMetadataAlloc matches format metadata decode" {
    const payload = try testing_encoder.format.encodeRawRecordPayloadAlloc(
        std.testing.allocator,
        &.{
            "colour",
            "Co lor",
        },
        &.{ "color", "colour" },
        false,
        "encoded-english",
    );
    defer std.testing.allocator.free(payload);

    const mapping_blob = try testing_encoder.format.encodeCurrentCompactMappingsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(mapping_blob);
    var mappings = try format.parseCompactMappingsAlloc(std.testing.allocator, mapping_blob);
    defer mappings.deinit(std.testing.allocator);

    const actual = try decodeBuildRawMetadataAlloc(std.testing.allocator, payload, format.version, mappings.view());
    defer {
        for (actual.alt_forms) |alt_form| {
            std.testing.allocator.free(alt_form.value);
            if (!std.mem.eql(u8, alt_form.normalized, alt_form.value)) std.testing.allocator.free(alt_form.normalized);
        }
        std.testing.allocator.free(actual.alt_forms);
        for (actual.canonical_targets) |target| std.testing.allocator.free(target);
        std.testing.allocator.free(actual.canonical_targets);
    }

    try std.testing.expectEqual(@as(usize, 2), actual.alt_forms.len);
    const expected_alt_forms = [_][]const u8{ "colour", "Co lor" };
    for (expected_alt_forms, actual.alt_forms) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs.value);
        const normalized = try normalize.normalizeAlloc(std.testing.allocator, lhs);
        defer std.testing.allocator.free(normalized);
        try std.testing.expectEqualStrings(normalized, rhs.normalized);
    }
    const expected_targets = [_][]const u8{ "color", "colour" };
    try std.testing.expectEqual(expected_targets.len, actual.canonical_targets.len);
    for (expected_targets, actual.canonical_targets) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }
}

test "buildEntryFromRecord normalizes redirect targets during cache build" {
    const payload = try testing_encoder.format.encodeAliasRecordPayloadAlloc(std.testing.allocator, "Color");
    defer std.testing.allocator.free(payload);

    const mapping_blob = try testing_encoder.format.encodeCurrentCompactMappingsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(mapping_blob);
    var mappings = try format.parseCompactMappingsAlloc(std.testing.allocator, mapping_blob);
    defer mappings.deinit(std.testing.allocator);

    const entry = try buildEntryFromRecord(std.testing.allocator, .{
        .record_offset = 0,
        .flags = 0,
        .title = "color",
        .payload = payload,
        .record_len = 0,
    }, format.version, mappings.view());
    defer {
        std.testing.allocator.free(entry.word);
        std.testing.allocator.free(entry.normalized_targets[0]);
        std.testing.allocator.free(entry.normalized_targets);
    }

    try std.testing.expectEqualStrings("color", entry.word);
    try std.testing.expectEqual(@intFromPtr(entry.word.ptr), @intFromPtr(entry.normalized.ptr));
    try std.testing.expectEqualStrings("color", entry.normalized_targets[0]);
}

test "tryOpenCache rejects stale cache versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cache_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin.idx", .{tmp.sub_path});
    defer std.testing.allocator.free(cache_path);

    var header = CacheHeader.init(1234, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    header.version = cache_version - 1;
    var bytes: [cache_header_size]u8 = [_]u8{0} ** cache_header_size;
    @memcpy(bytes[0..@sizeOf(CacheHeader)], std.mem.asBytes(&header));
    try writeMappedFile(cache_path, &bytes);

    try std.testing.expect((try tryOpenCache(std.testing.io, cache_path, 1234)) == null);
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

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    const hits = try dict.lookupExact(std.testing.allocator, "ring");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);

    const raw = (try dict.entryAt(hits[0].entry_index).rawEnglishAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(raw_english, raw);
}

test "dictionary open reuses an up-to-date cache file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>ring</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[circle]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    const cache_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.idx", .{db_path});
    defer std.testing.allocator.free(cache_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    {
        var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
        defer dict.deinit();
    }

    const first_stat = try std.Io.Dir.cwd().statFile(std.testing.io, cache_path, .{});

    {
        var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
        defer dict.deinit();
    }

    const second_stat = try std.Io.Dir.cwd().statFile(std.testing.io, cache_path, .{});
    try std.testing.expectEqual(first_stat.size, second_stat.size);
    try std.testing.expectEqual(first_stat.mtime.nanoseconds, second_stat.mtime.nanoseconds);
}

test "dictionary build drops non-English entries by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>चूत</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==Hindi==
        \\===Noun===
        \\# [[cunt]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    const hits = try dict.lookupExact(std.testing.allocator, "चूत");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
    try std.testing.expectEqual(@as(u32, 0), dict.header.entry_count);
    try std.testing.expectEqual(@as(u32, 0), dict.header.raw_entry_count);
}

test "dictionary cache rebuild recomputes normalized alias metadata" {
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

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
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
    try std.testing.expectEqual(@as(usize, 2), redirect_hits.len);
    try std.testing.expectEqual(format.lookup_kind_title, redirect_hits[0].kind);
    try std.testing.expectEqualStrings("colour", dict.entryAt(redirect_hits[0].entry_index).word());
    try std.testing.expectEqual(lookup_kind_alias_expansion, redirect_hits[1].kind);
    try std.testing.expectEqualStrings("color", dict.entryAt(redirect_hits[1].entry_index).word());
}

test "build drops alias entries whose destination is not stored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<redirect title="Missing target"/>
        \\</page>
        \\<page>
        \\<title>Fresnel reflections</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\
        \\# {{plural of|en|Missing target}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    try std.testing.expectEqual(@as(u32, 1), dict.header.entry_count);
    try std.testing.expectEqual(@as(u32, 0), dict.header.redirect_count);

    const valid_hits = try dict.lookupExact(std.testing.allocator, "color");
    defer std.testing.allocator.free(valid_hits);
    try std.testing.expectEqual(@as(usize, 1), valid_hits.len);

    const redirect_hits = try dict.lookupExact(std.testing.allocator, "colour");
    defer std.testing.allocator.free(redirect_hits);
    try std.testing.expectEqual(@as(usize, 0), redirect_hits.len);

    const alias_hits = try dict.lookupExact(std.testing.allocator, "Fresnel reflections");
    defer std.testing.allocator.free(alias_hits);
    try std.testing.expectEqual(@as(usize, 0), alias_hits.len);
}

test "lookupExact collapses duplicate entry hits and prefers the exact raw match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>hellfire</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Alternative forms===
        \\* [[Hellfire]]
        \\===Noun===
        \\# [[fire]]
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    const lower_hits = try dict.lookupExact(std.testing.allocator, "hellfire");
    defer std.testing.allocator.free(lower_hits);
    try std.testing.expectEqual(@as(usize, 1), lower_hits.len);
    try std.testing.expectEqual(format.lookup_kind_title, lower_hits[0].kind);
    try std.testing.expectEqualStrings("hellfire", lower_hits[0].matched);

    const capitalized_hits = try dict.lookupExact(std.testing.allocator, "Hellfire");
    defer std.testing.allocator.free(capitalized_hits);
    try std.testing.expectEqual(@as(usize, 1), capitalized_hits.len);
    try std.testing.expectEqual(format.lookup_kind_alternative_form, capitalized_hits[0].kind);
    try std.testing.expectEqualStrings("Hellfire", capitalized_hits[0].matched);

    const upper_hits = try dict.lookupExact(std.testing.allocator, "HELLFIRE");
    defer std.testing.allocator.free(upper_hits);
    try std.testing.expectEqual(@as(usize, 1), upper_hits.len);
    try std.testing.expectEqual(format.lookup_kind_title, upper_hits[0].kind);
    try std.testing.expectEqualStrings("hellfire", upper_hits[0].matched);
}

test "lookupExact appends canonical hits for alias-only entries and redirects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<redirect title="color"/>
        \\</page>
        \\<page>
        \\<title>colours</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|colour}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>alpha</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|beta}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>beta</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{singular of|en|alpha}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    const redirect_hits = try dict.lookupExact(std.testing.allocator, "colour");
    defer std.testing.allocator.free(redirect_hits);
    try std.testing.expectEqual(@as(usize, 2), redirect_hits.len);
    try std.testing.expectEqualStrings("colour", dict.entryAt(redirect_hits[0].entry_index).word());
    try std.testing.expectEqual(format.lookup_kind_title, redirect_hits[0].kind);
    try std.testing.expectEqualStrings("color", dict.entryAt(redirect_hits[1].entry_index).word());
    try std.testing.expectEqual(lookup_kind_alias_expansion, redirect_hits[1].kind);
    try std.testing.expectEqualStrings("colour", redirect_hits[1].matched);

    const plural_hits = try dict.lookupExact(std.testing.allocator, "colours");
    defer std.testing.allocator.free(plural_hits);
    try std.testing.expectEqual(@as(usize, 2), plural_hits.len);
    try std.testing.expectEqualStrings("colours", dict.entryAt(plural_hits[0].entry_index).word());
    try std.testing.expectEqualStrings("color", dict.entryAt(plural_hits[1].entry_index).word());
    try std.testing.expectEqual(lookup_kind_alias_expansion, plural_hits[1].kind);
    try std.testing.expectEqualStrings("colours", plural_hits[1].matched);

    const cycle_hits = try dict.lookupExact(std.testing.allocator, "alpha");
    defer std.testing.allocator.free(cycle_hits);
    try std.testing.expectEqual(@as(usize, 0), cycle_hits.len);
}

test "resolveLinkTargetAlloc follows alias-only form chains and breaks cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const xml =
        \\<mediawiki>
        \\<page>
        \\<title>color</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\# [[light]]
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colour</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{alternative spelling of|en|color}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>colours</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|colour}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>alpha</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|beta}}
        \\</text></revision>
        \\</page>
        \\<page>
        \\<title>beta</title>
        \\<ns>0</ns>
        \\<revision><text xml:space="preserve">==English==
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{singular of|en|alpha}}
        \\</text></revision>
        \\</page>
        \\</mediawiki>
    ;

    const db_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dict.bin", .{tmp.sub_path});
    defer std.testing.allocator.free(db_path);
    const xml_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sample.xml", .{tmp.sub_path});
    defer std.testing.allocator.free(xml_path);
    try writeMappedFile(xml_path, xml);

    _ = try testing_encoder.buildDictionary(std.testing.io, std.testing.allocator, .{
        .input_path = xml_path,
        .output_path = db_path,
    });

    var dict = try Dictionary.open(std.testing.allocator, std.testing.io, db_path, .{});
    defer dict.deinit();

    const chained = (try dict.resolveLinkTargetAlloc(std.testing.allocator, "colours")).?;
    defer std.testing.allocator.free(chained);
    try std.testing.expectEqualStrings("color", chained);

    try std.testing.expectEqual(@as(?[]const u8, null), try dict.resolveLinkTargetAlloc(std.testing.allocator, "alpha"));
    try std.testing.expectEqual(@as(?[]const u8, null), try dict.resolveLinkTargetAlloc(std.testing.allocator, "beta"));
}

test "replaceFile overwrites an existing cache target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/fresh.idx.tmp", .{tmp.sub_path});
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/cache.idx", .{tmp.sub_path});
    defer std.testing.allocator.free(target_path);
    try writeMappedFile(source_path, "fresh");
    try writeMappedFile(target_path, "stale");

    try replaceFile(std.testing.io, source_path, target_path);

    var mapped_target = try mmapReadOnlyPath(std.testing.io, target_path);
    defer mapped_target.deinit();
    try std.testing.expectEqualStrings("fresh", mapped_target.bytes());
}

test "indexBuildThreadCount honors explicit overrides" {
    try std.testing.expectEqual(@as(usize, 1), indexBuildThreadCount(1024, 1));
    try std.testing.expectEqual(@as(usize, 2), indexBuildThreadCount(1024, 2));
    try std.testing.expectEqual(@as(usize, 1), indexBuildThreadCount(1024, 0));
}

test "sortLookups matches serial ordering" {
    var alpha_alt_forms = [_]BuildAltForm{.{ .value = "able", .normalized = "alpha" }};
    var beta_alt_forms = [_]BuildAltForm{.{ .value = "able", .normalized = "beta" }};
    const alt_forms = [_][]BuildAltForm{
        &.{},
        &.{},
        alpha_alt_forms[0..],
        &.{},
        beta_alt_forms[0..],
    };
    const entries = [_]BuildEntryData{
        .{ .record_offset = 0, .word = "beta", .normalized = "beta", .alt_forms = alt_forms[0] },
        .{ .record_offset = 0, .word = "zeta", .normalized = "alpha", .alt_forms = alt_forms[1] },
        .{ .record_offset = 0, .word = "entry3", .normalized = "unused", .alt_forms = alt_forms[2] },
        .{ .record_offset = 0, .word = "alpha", .normalized = "alpha", .alt_forms = alt_forms[3] },
        .{ .record_offset = 0, .word = "entry5", .normalized = "unused", .alt_forms = alt_forms[4] },
    };
    const lookup_count = 7;
    var parallel: [lookup_count]BuildLookupRecord = undefined;
    fillLookupChunk(&entries, 0, &parallel);
    var serial = parallel;

    try sortLookups(std.testing.allocator, &parallel, 2);
    std.mem.sort(BuildLookupRecord, &serial, {}, lessThanLookup);

    for (parallel, serial) |lhs, rhs| {
        try std.testing.expectEqualStrings(rhs.key(), lhs.key());
        try std.testing.expectEqualStrings(rhs.matched(), lhs.matched());
        try std.testing.expectEqual(rhs.entry_index, lhs.entry_index);
        try std.testing.expectEqual(rhs.kind, lhs.kind);
    }
}

test "mergeSortedLookups preserves lookup ordering" {
    var beta_alt_forms = [_]BuildAltForm{.{ .value = "able", .normalized = "beta" }};
    var alpha_alt_forms = [_]BuildAltForm{.{ .value = "able", .normalized = "alpha" }};
    const alt_forms = [_][]BuildAltForm{
        &.{},
        beta_alt_forms[0..],
        alpha_alt_forms[0..],
        &.{},
    };
    const entries = [_]BuildEntryData{
        .{ .record_offset = 0, .word = "alpha", .normalized = "alpha", .alt_forms = alt_forms[0] },
        .{ .record_offset = 0, .word = "entry2", .normalized = "unused", .alt_forms = alt_forms[1] },
        .{ .record_offset = 0, .word = "entry3", .normalized = "unused", .alt_forms = alt_forms[2] },
        .{ .record_offset = 0, .word = "gamma", .normalized = "gamma", .alt_forms = alt_forms[3] },
    };
    var all = [_]BuildLookupRecord{ undefined, undefined, undefined, undefined, undefined, undefined };
    fillLookupChunk(&entries, 0, &all);
    const left = all[0..3];
    const right = all[3..6];
    var merged: [left.len + right.len]BuildLookupRecord = undefined;
    std.mem.sort(BuildLookupRecord, left, {}, lessThanLookup);
    std.mem.sort(BuildLookupRecord, right, {}, lessThanLookup);
    mergeSortedLookups(left, right, &merged);

    const expected = [_][2][]const u8{
        .{ "alpha", "alpha" },
        .{ "alpha", "able" },
        .{ "beta", "able" },
        .{ "gamma", "gamma" },
        .{ "unused", "entry2" },
        .{ "unused", "entry3" },
    };
    for (merged, expected) |item, pair| {
        try std.testing.expectEqualStrings(pair[0], item.key());
        try std.testing.expectEqualStrings(pair[1], item.matched());
    }
}

test "buildLookups partitions threaded workers without overlapping slices" {
    const entries = try std.testing.allocator.alloc(BuildEntryData, 2048);
    defer std.testing.allocator.free(entries);

    for (entries, 0..) |*entry, idx| {
        entry.* = .{
            .record_offset = 0,
            .word = try std.fmt.allocPrint(std.testing.allocator, "word-{d}", .{idx}),
            .normalized = try std.fmt.allocPrint(std.testing.allocator, "word-{d}", .{idx}),
            .alt_forms = &.{},
            .normalized_targets = &.{},
            .incoming_aliases = &.{},
        };
    }
    defer for (entries) |entry| {
        std.testing.allocator.free(entry.word);
        std.testing.allocator.free(entry.normalized);
    };

    var state: BuildState = .{};
    defer state.lookups.deinit(std.testing.allocator);
    try state.entries.ensureTotalCapacity(std.testing.allocator, entries.len);
    for (entries) |entry| try state.entries.append(std.testing.allocator, entry);
    defer state.entries.deinit(std.testing.allocator);

    try buildLookups(std.testing.allocator, std.testing.allocator, &state, 2);
    try std.testing.expectEqual(@as(usize, entries.len), state.lookups.items.len);

    const seen = try std.testing.allocator.alloc(bool, entries.len);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);

    for (state.lookups.items) |lookup| {
        try std.testing.expectEqual(format.lookup_kind_title, lookup.kind);
        try std.testing.expect(lookup.entry_index < entries.len);
        try std.testing.expect(!seen[lookup.entry_index]);
        seen[lookup.entry_index] = true;
    }

    for (seen) |was_seen| {
        try std.testing.expect(was_seen);
    }
}
