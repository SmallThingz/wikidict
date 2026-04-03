const std = @import("std");

const format = @import("format.zig");
const normalize = @import("normalize.zig");

pub const LookupHit = struct {
    entry_index: u32,
    matched: []const u8,
    kind: u8,
};

pub const EntryView = struct {
    dict: *const Dictionary,
    index: u32,

    fn record(self: EntryView) *const format.EntryRecord {
        return &self.dict.entries[self.index];
    }

    pub fn word(self: EntryView) []const u8 {
        return self.dict.string(self.record().word);
    }

    pub fn normalized(self: EntryView) []const u8 {
        return self.dict.string(self.record().normalized);
    }

    pub fn altForms(self: EntryView) []const format.StringRef {
        const range = self.record().alt_forms;
        return self.dict.string_lists[range.start .. range.start + range.len];
    }

    pub fn canonicalTargets(self: EntryView) []const format.StringRef {
        const range = self.record().canonical_targets;
        return self.dict.string_lists[range.start .. range.start + range.len];
    }

    pub fn incomingAliases(self: EntryView) []const format.StringRef {
        const range = self.record().incoming_aliases;
        return self.dict.string_lists[range.start .. range.start + range.len];
    }

    pub fn sections(self: EntryView) []const format.SectionRecord {
        const range = self.record().sections;
        return self.dict.sections[range.start .. range.start + range.len];
    }

    pub fn senses(self: EntryView) []const format.SenseRecord {
        const range = self.record().senses;
        return self.dict.senses[range.start .. range.start + range.len];
    }

    pub fn isAliasOnly(self: EntryView) bool {
        return (self.record().flags & format.flag_alias_only) != 0;
    }
};

pub const Dictionary = struct {
    io: std.Io,
    file: std.Io.File,
    mapping: []align(std.heap.page_size_min) const u8,
    header: *const format.Header,
    entries: []const format.EntryRecord,
    string_lists: []const format.StringRef,
    sections: []const format.SectionRecord,
    senses: []const format.SenseRecord,
    lookups: []const format.LookupRecord,
    strings: []const u8,

    pub fn open(io: std.Io, path: []const u8) !Dictionary {
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

        const strings_end = header.strings_offset + header.strings_len;
        if (strings_end > stat.size) return error.InvalidDictionaryFile;

        return .{
            .io = io,
            .file = file,
            .mapping = mapped,
            .header = header,
            .entries = sliceFor(format.EntryRecord, mapped, header.entries_offset, header.entry_count),
            .string_lists = sliceFor(format.StringRef, mapped, header.string_lists_offset, header.string_list_count),
            .sections = sliceFor(format.SectionRecord, mapped, header.sections_offset, header.section_count),
            .senses = sliceFor(format.SenseRecord, mapped, header.senses_offset, header.sense_count),
            .lookups = sliceFor(format.LookupRecord, mapped, header.lookups_offset, header.lookup_count),
            .strings = mapped[header.strings_offset .. header.strings_offset + header.strings_len],
        };
    }

    pub fn deinit(self: *Dictionary) void {
        std.posix.munmap(self.mapping);
        self.file.close(self.io);
    }

    pub fn entryAt(self: *const Dictionary, index: u32) EntryView {
        return .{
            .dict = self,
            .index = index,
        };
    }

    pub fn string(self: *const Dictionary, ref: format.StringRef) []const u8 {
        if (ref.len == 0) return "";
        return self.strings[ref.offset .. ref.offset + ref.len];
    }

    pub fn lookupExact(self: *const Dictionary, allocator: std.mem.Allocator, term: []const u8) ![]LookupHit {
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(allocator);
        const normalized = try normalize.normalizeToList(&key_buf, allocator, term);
        if (normalized.len == 0) return allocator.alloc(LookupHit, 0);

        const start = lowerBoundLookup(self, normalized);
        var end = start;
        while (end < self.lookups.len and std.mem.eql(u8, self.string(self.lookups[end].key), normalized)) : (end += 1) {}

        var hits: std.ArrayList(LookupHit) = .empty;
        defer hits.deinit(allocator);
        for (self.lookups[start..end]) |lookup| {
            try hits.append(allocator, .{
                .entry_index = lookup.entry_index,
                .matched = self.string(lookup.display),
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
            const key = self.string(self.lookups[i].key);
            if (!std.mem.startsWith(u8, key, normalized)) break;

            const candidate = LookupHit{
                .entry_index = self.lookups[i].entry_index,
                .matched = self.string(self.lookups[i].display),
                .kind = self.lookups[i].kind,
            };
            if (!containsHit(hits.items, candidate)) {
                try hits.append(allocator, candidate);
            }
        }
        return hits.toOwnedSlice(allocator);
    }
};

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
        const mid_key = self.string(self.lookups[mid].key);
        if (std.mem.order(u8, mid_key, key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn sliceFor(comptime T: type, bytes: []align(std.heap.page_size_min) const u8, offset: u64, count: u32) []const T {
    if (count == 0) return &.{};
    const start: usize = @intCast(offset);
    const aligned: [*]align(@alignOf(T)) const u8 = @alignCast(bytes[start..].ptr);
    const typed: [*]const T = @ptrCast(aligned);
    return typed[0..count];
}
