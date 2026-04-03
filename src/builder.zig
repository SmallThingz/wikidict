const std = @import("std");
const zxml = @import("zxml");

const format = @import("format.zig");
const normalize = @import("normalize.zig");
const wikitext = @import("wikitext.zig");
const xml_decode = @import("xml_decode.zig");

const parse_opts: zxml.ParseOptions = .{
    .mode = .strict,
    .validate_closing_tags = true,
    .drop_whitespace_text_nodes = true,
};
const ztypes = zxml.Types(parse_opts);
const StreamParser = ztypes.StreamParser;
const StreamNode = ztypes.StreamNode;

pub const BuildOptions = struct {
    input_path: []const u8,
    output_path: []const u8,
    limit_entries: ?usize = null,
};

pub const BuildStats = struct {
    pages_seen: usize = 0,
    namespace_zero_pages: usize = 0,
    english_entries: usize = 0,
    redirect_aliases: usize = 0,
};

pub fn build(io: std.Io, allocator: std.mem.Allocator, options: BuildOptions) !BuildStats {
    var builder = try BuildState.init(allocator);
    defer builder.deinit();

    var stats: BuildStats = .{};
    var file = try std.Io.Dir.cwd().openFile(io, options.input_path, .{});
    defer file.close(io);

    var stream_parser = StreamParser.init(allocator);
    defer stream_parser.deinit();

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    var read_buf = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(read_buf);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_offset: u64 = 0;
    var consumed: usize = 0;
    while (true) {
        const read_n = try file.readPositionalAll(io, read_buf, read_offset);
        read_offset += read_n;
        if (read_n != 0) try buffer.appendSlice(allocator, read_buf[0..read_n]);

        while (true) {
            const search_from = consumed;
            const start = std.mem.indexOfPos(u8, buffer.items, search_from, "<page>") orelse break;
            const end_start = std.mem.indexOfPos(u8, buffer.items, start, "</page>") orelse {
                if (start > 0) consumed = start;
                break;
            };
            const page_end = end_start + "</page>".len;

            const page_allocator = page_arena.allocator();
            processPageFragment(page_allocator, &stream_parser, buffer.items[start..page_end], &builder, &stats) catch |err| {
                std.log.warn("skipping page after parse error: {}", .{err});
            };
            consumed = page_end;
            _ = page_arena.reset(.retain_capacity);

            if (options.limit_entries) |limit| {
                if (builder.entries.items.len >= limit) {
                    try builder.finalizeAndWrite(io, options.output_path);
                    stats.english_entries = builder.entries.items.len;
                    return stats;
                }
            }

            if (stats.pages_seen != 0 and stats.pages_seen % 10_000 == 0) {
                std.log.info(
                    "pages={d} ns0={d} entries={d}",
                    .{ stats.pages_seen, stats.namespace_zero_pages, builder.entries.items.len },
                );
            }
        }

        if (consumed != 0 and (consumed > 8 * 1024 * 1024 or consumed == buffer.items.len or read_n == 0)) {
            const remaining = buffer.items.len - consumed;
            std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[consumed..]);
            buffer.items.len = remaining;
            consumed = 0;
        }

        if (read_n == 0) break;
    }

    try builder.finalizeAndWrite(io, options.output_path);
    stats.english_entries = builder.entries.items.len;
    return stats;
}

const PageCapture = struct {
    names_by_depth: [8][]const u8 = [_][]const u8{""} ** 8,
    title_raw: ?[]const u8 = null,
    ns_raw: ?[]const u8 = null,
    text_raw: ?[]const u8 = null,
    redirect_title_raw: ?[]const u8 = null,

    fn onNode(self: *@This(), node: StreamNode) bool {
        if (node.kind != .element) return true;
        if (node.depth < self.names_by_depth.len) self.names_by_depth[node.depth] = node.nameSlice();

        const name = node.nameSlice();
        if (node.depth == 1 and std.mem.eql(u8, name, "title")) {
            self.title_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "ns")) {
            self.ns_raw = node.leadingTextRaw();
        } else if (node.depth == 1 and std.mem.eql(u8, name, "redirect")) {
            self.redirect_title_raw = node.getAttributeValueRaw("title");
        } else if (node.depth == 2 and std.mem.eql(u8, name, "text") and std.mem.eql(u8, self.names_by_depth[1], "revision")) {
            self.text_raw = node.leadingTextRaw();
        }
        return true;
    }
};

fn processPageFragment(
    allocator: std.mem.Allocator,
    parser: *StreamParser,
    page_fragment: []const u8,
    builder: *BuildState,
    stats: *BuildStats,
) !void {
    var capture: PageCapture = .{};
    try parser.parse(page_fragment, &capture, PageCapture.onNode);
    stats.pages_seen += 1;

    const ns_raw = capture.ns_raw orelse return;
    const ns = std.fmt.parseInt(u32, std.mem.trim(u8, ns_raw, " \t\r\n"), 10) catch return;
    if (ns != 0) return;
    stats.namespace_zero_pages += 1;

    const title = try xml_decode.decodeAlloc(allocator, capture.title_raw orelse return);
    const redirect_title = if (capture.redirect_title_raw) |raw| try xml_decode.decodeAlloc(allocator, raw) else null;

    if (capture.text_raw) |text_raw| {
        if (std.mem.indexOf(u8, text_raw, "==English==") != null) {
            const text = try xml_decode.decodeAlloc(allocator, text_raw);
            if (try wikitext.parseEnglishEntry(allocator, title, text)) |entry| {
                try builder.addEntry(allocator, entry);
                return;
            }
        }
    }

    if (redirect_title) |target| {
        var entry: wikitext.ParsedEntry = .{
            .word = try allocator.dupe(u8, title),
            .alias_only = true,
        };
        try entry.canonical_targets.append(allocator, try allocator.dupe(u8, target));
        try builder.addEntry(allocator, entry);
        stats.redirect_aliases += 1;
    }
}

const BuildState = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList(u8) = .empty,
    string_lists: std.ArrayList(format.StringRef) = .empty,
    sections: std.ArrayList(format.SectionRecord) = .empty,
    senses: std.ArrayList(format.SenseRecord) = .empty,
    entries: std.ArrayList(format.EntryRecord) = .empty,
    lookups: std.ArrayList(format.LookupRecord) = .empty,

    fn init(allocator: std.mem.Allocator) !BuildState {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *BuildState) void {
        self.strings.deinit(self.allocator);
        self.string_lists.deinit(self.allocator);
        self.sections.deinit(self.allocator);
        self.senses.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.lookups.deinit(self.allocator);
    }

    fn addEntry(self: *BuildState, scratch_allocator: std.mem.Allocator, entry: wikitext.ParsedEntry) !void {
        const word_ref = try self.storeString(entry.word);
        const normalized_value = try normalize.normalizeAlloc(scratch_allocator, entry.word);
        const normalized_ref = try self.storeString(normalized_value);

        const alt_forms = try self.storeStringList(entry.alt_forms.items);
        const canonical_targets = try self.storeStringList(entry.canonical_targets.items);
        const sections = try self.storeSections(entry.sections.items);
        const senses = try self.storeSenses(entry.senses.items);

        const flags: u32 = if (entry.alias_only) format.flag_alias_only else 0;
        const entry_index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{
            .word = word_ref,
            .normalized = normalized_ref,
            .alt_forms = alt_forms,
            .canonical_targets = canonical_targets,
            .incoming_aliases = .{},
            .sections = sections,
            .senses = senses,
            .flags = flags,
        });

        try self.lookups.append(self.allocator, .{
            .key = normalized_ref,
            .display = word_ref,
            .entry_index = entry_index,
            .kind = format.lookup_kind_title,
        });

        for (entry.alt_forms.items) |alt_form| {
            const alt_norm = try normalize.normalizeAlloc(scratch_allocator, alt_form);
            try self.lookups.append(self.allocator, .{
                .key = try self.storeString(alt_norm),
                .display = try self.storeString(alt_form),
                .entry_index = entry_index,
                .kind = format.lookup_kind_alternative_form,
            });
        }
    }

    fn storeString(self: *BuildState, value: []const u8) !format.StringRef {
        if (value.len == 0) return .{};
        if (self.strings.items.len + value.len > std.math.maxInt(u32)) return error.StringPoolTooLarge;

        const offset: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.allocator, value);
        return .{
            .offset = offset,
            .len = @intCast(value.len),
        };
    }

    fn storeStringList(self: *BuildState, values: []const []const u8) !format.Range {
        if (values.len == 0) return .{};
        if (self.string_lists.items.len + values.len > std.math.maxInt(u32)) return error.TooManyStringRefs;

        const start: u32 = @intCast(self.string_lists.items.len);
        for (values) |value| {
            try self.string_lists.append(self.allocator, try self.storeString(value));
        }
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    fn storeSections(self: *BuildState, values: []const wikitext.TempSection) !format.Range {
        if (values.len == 0) return .{};
        if (self.sections.items.len + values.len > std.math.maxInt(u32)) return error.TooManySections;

        const start: u32 = @intCast(self.sections.items.len);
        for (values) |section| {
            try self.sections.append(self.allocator, .{
                .group = try self.storeString(section.group),
                .title = try self.storeString(section.title),
                .body = try self.storeString(section.body),
            });
        }
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    fn storeSenses(self: *BuildState, values: []const wikitext.TempSense) !format.Range {
        if (values.len == 0) return .{};
        if (self.senses.items.len + values.len > std.math.maxInt(u32)) return error.TooManySenses;

        const start: u32 = @intCast(self.senses.items.len);
        for (values) |sense| {
            try self.senses.append(self.allocator, .{
                .group = try self.storeString(sense.group),
                .pos = try self.storeString(sense.pos),
                .gloss = try self.storeString(sense.gloss),
                .examples = try self.storeString(sense.examples),
                .depth = sense.depth,
            });
        }
        return .{
            .start = start,
            .len = @intCast(values.len),
        };
    }

    fn stringSlice(self: *const BuildState, ref: format.StringRef) []const u8 {
        if (ref.len == 0) return "";
        return self.strings.items[ref.offset .. ref.offset + ref.len];
    }

    fn finalizeIncomingAliases(self: *BuildState) !void {
        var title_map = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)).empty;
        defer {
            var it = title_map.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            title_map.deinit(self.allocator);
        }

        for (self.entries.items, 0..) |entry, idx| {
            const normalized = self.stringSlice(entry.normalized);
            const gop = try title_map.getOrPut(self.allocator, normalized);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, @intCast(idx));
        }

        const incoming = try self.allocator.alloc(std.ArrayListUnmanaged(format.StringRef), self.entries.items.len);
        defer {
            for (incoming) |*list| list.deinit(self.allocator);
            self.allocator.free(incoming);
        }
        for (incoming) |*list| list.* = .empty;

        var norm_buf: std.ArrayList(u8) = .empty;
        defer norm_buf.deinit(self.allocator);

        for (self.entries.items, 0..) |entry, source_idx| {
            const source_word = self.entries.items[source_idx].word;
            const targets = self.string_lists.items[entry.canonical_targets.start .. entry.canonical_targets.start + entry.canonical_targets.len];
            for (targets) |target_ref| {
                const target_word = self.stringSlice(target_ref);
                const normalized_target = try normalize.normalizeToList(&norm_buf, self.allocator, target_word);
                if (title_map.get(normalized_target)) |indices| {
                    for (indices.items) |target_idx| {
                        try incoming[target_idx].append(self.allocator, source_word);
                    }
                }
            }
        }

        for (incoming, 0..) |list, idx| {
            if (list.items.len == 0) continue;
            const deduped = try self.storeIncomingAliasList(list.items);
            self.entries.items[idx].incoming_aliases = deduped;
        }
    }

    fn storeIncomingAliasList(self: *BuildState, refs: []const format.StringRef) !format.Range {
        if (refs.len == 0) return .{};
        const start: u32 = @intCast(self.string_lists.items.len);
        for (refs) |candidate| {
            var exists = false;
            for (self.string_lists.items[start..]) |existing| {
                if (std.mem.eql(u8, self.stringSlice(existing), self.stringSlice(candidate))) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try self.string_lists.append(self.allocator, candidate);
        }
        return .{
            .start = start,
            .len = @intCast(self.string_lists.items.len - start),
        };
    }

    fn sortLookups(self: *BuildState) void {
        std.mem.sort(format.LookupRecord, self.lookups.items, self, lessThanLookup);
    }

    fn lessThanLookup(self: *BuildState, lhs: format.LookupRecord, rhs: format.LookupRecord) bool {
        const lhs_key = self.stringSlice(lhs.key);
        const rhs_key = self.stringSlice(rhs.key);
        switch (std.mem.order(u8, lhs_key, rhs_key)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
        return std.mem.order(u8, self.stringSlice(lhs.display), self.stringSlice(rhs.display)) == .lt;
    }

    fn finalizeAndWrite(self: *BuildState, io: std.Io, output_path: []const u8) !void {
        try self.finalizeIncomingAliases();
        self.sortLookups();

        var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
        defer file.close(io);

        const entries_offset = alignForward(@sizeOf(format.Header), 8);
        const string_lists_offset = alignForward(entries_offset + self.entries.items.len * @sizeOf(format.EntryRecord), 8);
        const sections_offset = alignForward(string_lists_offset + self.string_lists.items.len * @sizeOf(format.StringRef), 8);
        const senses_offset = alignForward(sections_offset + self.sections.items.len * @sizeOf(format.SectionRecord), 8);
        const lookups_offset = alignForward(senses_offset + self.senses.items.len * @sizeOf(format.SenseRecord), 8);
        const strings_offset = alignForward(lookups_offset + self.lookups.items.len * @sizeOf(format.LookupRecord), 8);

        const header = format.Header.init(
            @intCast(self.entries.items.len),
            @intCast(self.string_lists.items.len),
            @intCast(self.sections.items.len),
            @intCast(self.senses.items.len),
            @intCast(self.lookups.items.len),
            entries_offset,
            string_lists_offset,
            sections_offset,
            senses_offset,
            lookups_offset,
            strings_offset,
            self.strings.items.len,
        );

        var cursor: u64 = 0;
        cursor += try writeAt(io, file, cursor, std.mem.asBytes(&header));
        cursor += try writePadding(io, file, cursor, entries_offset - @sizeOf(format.Header));
        cursor += try writeAt(io, file, cursor, std.mem.sliceAsBytes(self.entries.items));
        cursor += try writePadding(io, file, cursor, string_lists_offset - (entries_offset + self.entries.items.len * @sizeOf(format.EntryRecord)));
        cursor += try writeAt(io, file, cursor, std.mem.sliceAsBytes(self.string_lists.items));
        cursor += try writePadding(io, file, cursor, sections_offset - (string_lists_offset + self.string_lists.items.len * @sizeOf(format.StringRef)));
        cursor += try writeAt(io, file, cursor, std.mem.sliceAsBytes(self.sections.items));
        cursor += try writePadding(io, file, cursor, senses_offset - (sections_offset + self.sections.items.len * @sizeOf(format.SectionRecord)));
        cursor += try writeAt(io, file, cursor, std.mem.sliceAsBytes(self.senses.items));
        cursor += try writePadding(io, file, cursor, lookups_offset - (senses_offset + self.senses.items.len * @sizeOf(format.SenseRecord)));
        cursor += try writeAt(io, file, cursor, std.mem.sliceAsBytes(self.lookups.items));
        cursor += try writePadding(io, file, cursor, strings_offset - (lookups_offset + self.lookups.items.len * @sizeOf(format.LookupRecord)));
        _ = try writeAt(io, file, cursor, self.strings.items);
    }
};

fn alignForward(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, alignment);
}

fn writeAt(io: std.Io, file: std.Io.File, offset: u64, bytes: []const u8) !u64 {
    try file.writePositionalAll(io, bytes, offset);
    return bytes.len;
}

fn writePadding(io: std.Io, file: std.Io.File, offset: u64, count: usize) !u64 {
    if (count == 0) return 0;
    var zeros: [64]u8 = [_]u8{0} ** 64;
    var remaining = count;
    var cursor = offset;
    while (remaining != 0) {
        const chunk = @min(remaining, zeros.len);
        try file.writePositionalAll(io, zeros[0..chunk], cursor);
        cursor += chunk;
        remaining -= chunk;
    }
    return @intCast(count);
}
