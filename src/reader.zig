const std = @import("std");

const compact = @import("compact_encoding.zig");
const format = @import("format.zig");
const normalize = @import("normalize.zig");
const wikitext = @import("wikitext.zig");

const EntryData = struct {
    word: []const u8,
    normalized: []const u8,
    alt_forms: []const []const u8 = &.{},
    canonical_targets: []const []const u8 = &.{},
    incoming_aliases: []const []const u8 = &.{},
    summary: []const u8 = "",
    raw_encoded: []const u8 = "",
    flags: u8 = 0,
};

const LookupRecord = struct {
    key: []const u8,
    matched: []const u8,
    entry_index: u32,
    kind: u8,
};

pub const LookupHit = struct {
    entry_index: u32,
    matched: []const u8,
    kind: u8,
};

pub const EntryView = struct {
    dict: *const Dictionary,
    index: u32,

    fn record(self: EntryView) *const EntryData {
        return &self.dict.entries[self.index];
    }

    pub fn word(self: EntryView) []const u8 {
        return self.record().word;
    }

    pub fn normalized(self: EntryView) []const u8 {
        return self.record().normalized;
    }

    pub fn altForms(self: EntryView) []const []const u8 {
        return self.record().alt_forms;
    }

    pub fn canonicalTargets(self: EntryView) []const []const u8 {
        return self.record().canonical_targets;
    }

    pub fn incomingAliases(self: EntryView) []const []const u8 {
        return self.record().incoming_aliases;
    }

    pub fn summary(self: EntryView) []const u8 {
        return self.record().summary;
    }

    pub fn hasRaw(self: EntryView) bool {
        return (self.record().flags & format.record_flag_has_raw) != 0;
    }

    pub fn isAliasOnly(self: EntryView) bool {
        return (self.record().flags & format.record_flag_alias_only) != 0;
    }

    pub fn rawEnglishAlloc(self: EntryView, allocator: std.mem.Allocator) !?[]const u8 {
        if (!self.hasRaw()) return null;
        const decoded = try compact.decodeAlloc(allocator, self.record().raw_encoded);
        return decoded;
    }
};

pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    file: std.Io.File,
    mapping: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    entries: []const EntryData,
    lookups: []const LookupRecord,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Dictionary {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        const stat = try file.stat(io);
        const mapped = try std.posix.mmap(
            null,
            std.mem.alignForward(usize, stat.size, std.heap.page_size_min),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(mapped);

        if (stat.size < @sizeOf(format.Header)) return error.InvalidDictionaryFile;
        const header: *const format.Header = @ptrCast(@alignCast(mapped.ptr));
        if (!std.mem.eql(u8, &header.magic_bytes, format.magic)) return error.InvalidDictionaryFile;
        if (header.version != format.version) return error.UnsupportedDictionaryVersion;

        const records_end = header.records_offset + header.records_len;
        if (records_end > stat.size) return error.InvalidDictionaryFile;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var builder = try buildIndex(allocator, arena_allocator, mapped, header);
        try finalizeIncomingAliases(allocator, arena_allocator, &builder);
        try buildLookups(arena_allocator, &builder);

        return .{
            .allocator = allocator,
            .arena = arena,
            .io = io,
            .file = file,
            .mapping = mapped,
            .header = header,
            .entries = try builder.entries.toOwnedSlice(arena_allocator),
            .lookups = try builder.lookups.toOwnedSlice(arena_allocator),
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.arena.deinit();
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
        while (end < self.lookups.len and std.mem.eql(u8, self.lookups[end].key, normalized)) : (end += 1) {}

        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);
        for (self.lookups[start..end]) |lookup| {
            try hits.append(allocator, .{
                .entry_index = lookup.entry_index,
                .matched = lookup.matched,
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
            if (!std.mem.startsWith(u8, lookup.key, normalized)) break;

            const candidate = LookupHit{
                .entry_index = lookup.entry_index,
                .matched = lookup.matched,
                .kind = lookup.kind,
            };
            if (!containsHit(hits.items, candidate)) try hits.append(allocator, candidate);
        }
        return hits.toOwnedSlice(allocator);
    }
};

const BuildState = struct {
    entries: std.ArrayList(EntryData) = .empty,
    lookups: std.ArrayList(LookupRecord) = .empty,
};

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
        var entry = EntryData{
            .word = title,
            .normalized = normalized,
            .flags = flags,
        };

        if ((flags & format.record_flag_has_raw) != 0) {
            entry.raw_encoded = payload;

            const raw = try compact.decodeAlloc(allocator, payload);
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

    std.mem.sort(LookupRecord, state.lookups.items, {}, lessThanLookup);
}

fn lessThanLookup(_: void, lhs: LookupRecord, rhs: LookupRecord) bool {
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
        const mid_key = self.lookups[mid].key;
        if (std.mem.order(u8, mid_key, key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}
