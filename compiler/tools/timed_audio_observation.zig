//! Binds one observed audio player to its ordinary page and live Worker token.
const std = @import("std");
const encoder = @import("encoder");
const NamespaceRegistry = @import("namespace_registry").Registry;
const Selected = encoder.presentation_compile.SelectedTimedAudio;
const invalid = error.InvalidTimedAudioObservation;
const mismatch = error.TimedAudioSourceMismatch;
const max_bytes = 16 * 1024;
const schema = "wikidict.timed-audio-observation.v1";
const thumb_open = "[[File:";
const inline_open = "[[Image:";
const table_open = "<table class=\"audiotable\" style=\"vertical-align: top; display:inline-block; list-style:none;line-height: 1em;\"><tr><td class=\"unicode audiolink\">";
const cell_open = "</td><td class=\"audiofile\">";
const metadata_open = "</td><td class=\"audiometa\" style=\"font-size: 80%;\">([[:Image:";
const metadata_close = "|file]])</td></tr></table>";

const Digest = [32]u8;

pub fn parseDigest(text: []const u8) error{InvalidTimedAudioObservation}!Digest {
    if (text.len != 64) return invalid;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return invalid;
    }
    var result: Digest = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return invalid;
    return result;
}

fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

const Page = struct {
    ordinal: u64,
    index_offset: u64,
    namespace: u32,
    page_id: u64,
    revision_id: u64,
    title: []const u8,
};

const Source = struct {
    sha256: []const u8,
    bytes: usize,
    start: usize,
    end: usize,

    fn valid(self: Source, token_len: usize) bool {
        return self.start < self.end and self.end <= self.bytes and self.end - self.start == token_len;
    }

    fn occurrence(self: Source, expected_digest: Digest, body: []const u8, token: []const u8) ![]const u8 {
        if (body.len != self.bytes or !std.meta.eql(digest(body), expected_digest) or
            !std.mem.eql(u8, body[self.start..self.end], token) or std.mem.count(u8, body, token) != 1)
            return mismatch;
        return body[self.start..self.end];
    }

    fn line(self: Source, body: []const u8) bool {
        return (self.start == 0 or body[self.start - 1] == '\n') and
            (self.end == body.len or body[self.end] == '\n');
    }
};

const Provenance = struct {
    same_revision_render_sha256: []const u8,
    source_contract_sha256: []const u8,
    worker_expansion_receipt_sha256: []const u8,
};

const Packet = struct {
    schema: []const u8,
    wiki: []const u8,
    dump_date: []const u8,
    content_language: []const u8,
    namespace_registry_sha256: []const u8,
    page: Page,
    file: []const u8,
    wire_file: []const u8,
    raw_token: []const u8,
    token: []const u8,
    raw: Source,
    expanded: Source,
    transport: struct {
        mode: enum { inline_player, thumbnail },
        provider: enum { wikimediacommons },
        controls: bool,
        width_css_px: u32,
        height_css_px: ?u32,
    },
    provenance: Provenance,

    fn validShape(self: Packet) bool {
        const transport = self.transport;
        if (!transport.controls or self.file.len == 0 or self.wire_file.len == 0 or
            std.mem.indexOfAny(u8, self.file, "\x00\r\n\t[]{}<>|#") != null or
            std.mem.indexOfAny(u8, self.wire_file, "\x00\r\n\t[]{}<>|") != null or
            !self.raw.valid(self.raw_token.len) or !self.expanded.valid(self.token.len)) return false;
        var option_buffer: [32]u8 = undefined;
        const option = switch (transport.mode) {
            .thumbnail => "|thumb]]",
            .inline_player => std.fmt.bufPrint(&option_buffer, "|noicon|{d}px]]", .{transport.width_css_px}) catch return false,
        };
        const opener = switch (transport.mode) {
            .thumbnail => thumb_open,
            .inline_player => inline_open,
        };
        if (self.token.len != opener.len + self.wire_file.len + option.len or
            !std.mem.startsWith(u8, self.token, opener) or !std.mem.endsWith(u8, self.token, option) or
            !std.mem.eql(u8, self.token[opener.len..][0..self.wire_file.len], self.wire_file)) return false;
        const control: encoder.presentation_types.AudioControl = .{
            .width = .{ .unit = .px, .value = @floatFromInt(transport.width_css_px) },
            .height = if (transport.height_css_px) |height| .{ .unit = .px, .value = @floatFromInt(height) } else null,
        };
        if (!encoder.presentation_types.validAudioControl(control)) return false;
        switch (transport.mode) {
            .thumbnail => return transport.height_css_px != null and
                std.mem.eql(u8, self.file, self.wire_file) and std.mem.eql(u8, self.raw_token, self.token),
            .inline_player => {
                const raw_prefix = "{{audio|";
                if (transport.height_css_px != null or !std.mem.startsWith(u8, self.raw_token, raw_prefix)) return false;
                const args = self.raw_token[raw_prefix.len..];
                return args.len > self.wire_file.len and std.mem.startsWith(u8, args, self.wire_file) and
                    args[self.wire_file.len] == '|' and std.mem.endsWith(u8, args, "}}") and
                    std.mem.indexOfAny(u8, args, "\x00\r\n") == null;
            },
        }
    }

    fn validInlineOwner(self: Packet, expanded: []const u8) bool {
        const before = expanded[0..self.expanded.start];
        if (!std.mem.endsWith(u8, before, cell_open)) return false;
        const first = std.mem.lastIndexOf(u8, before, table_open) orelse return false;
        const label_start = first + table_open.len;
        const label_end = before.len - cell_open.len;
        if (label_start >= label_end) return false;
        const label = before[label_start..label_end];
        if (std.mem.indexOfScalar(u8, label, '<') != null) return false;
        const after = expanded[self.expanded.end..];
        if (!std.mem.startsWith(u8, after, metadata_open)) return false;
        const metadata = after[metadata_open.len..];
        return std.mem.startsWith(u8, metadata, self.wire_file) and
            std.mem.startsWith(u8, metadata[self.wire_file.len..], metadata_close);
    }
};

pub const Observation = struct {
    parsed: std.json.Parsed(Packet),
    raw_digest: Digest,
    expanded_digest: Digest,

    // Independently supplied SHA binds the packet, including evidence pins.
    pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8, expected: Digest, registry: *const NamespaceRegistry) !Observation {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
        defer a.free(bytes);
        return parse(a, bytes, expected, registry);
    }

    fn parse(a: std.mem.Allocator, bytes: []const u8, expected: Digest, registry: *const NamespaceRegistry) !Observation {
        if (bytes.len > max_bytes or !std.unicode.utf8ValidateSlice(bytes) or !std.meta.eql(digest(bytes), expected))
            return invalid;
        const parsed = try std.json.parseFromSlice(Packet, a, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
        });
        errdefer parsed.deinit();
        const packet = parsed.value;
        if (!std.mem.eql(u8, packet.schema, schema) or !std.mem.eql(u8, packet.wiki, registry.wiki) or
            !std.mem.eql(u8, packet.dump_date, registry.dump_date) or
            !std.mem.eql(u8, packet.content_language, registry.content_language) or
            !std.meta.eql(try parseDigest(packet.namespace_registry_sha256), registry.source_sha256)) return invalid;
        if (packet.page.namespace != 0 or packet.page.page_id == 0 or packet.page.revision_id == 0 or
            packet.page.title.len == 0 or std.mem.indexOfAny(u8, packet.page.title, "\x00\r\n\t") != null or
            !packet.validShape()) return invalid;
        inline for (@typeInfo(Provenance).@"struct".field_names) |field_name| {
            _ = try parseDigest(@field(packet.provenance, field_name));
        }
        return .{ .parsed = parsed, .raw_digest = try parseDigest(packet.raw.sha256), .expanded_digest = try parseDigest(packet.expanded.sha256) };
    }

    pub fn deinit(self: *Observation) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn requireSelection(self: *const Observation, ordinal: u64, index_offset: u64) !void {
        const page = self.parsed.value.page;
        if (page.ordinal != ordinal or page.index_offset != index_offset) return mismatch;
    }

    pub fn claims(self: *const Observation, ordinal: u64, page_id: u64) bool {
        return self.parsed.value.page.ordinal == ordinal or self.parsed.value.page.page_id == page_id;
    }

    pub fn bind(self: *const Observation, page: Page, raw: []const u8, expanded: []const u8, completed: *bool, ordinary: bool) !?Selected {
        if (!self.claims(page.ordinal, page.page_id)) return null;
        const packet = self.parsed.value;
        const held = packet.page;
        if (!ordinary or held.namespace != page.namespace or held.ordinal != page.ordinal or
            held.index_offset != page.index_offset or held.page_id != page.page_id or
            held.revision_id != page.revision_id or !std.mem.eql(u8, held.title, page.title)) return mismatch;
        _ = try packet.raw.occurrence(self.raw_digest, raw, packet.raw_token);
        const live_token = try packet.expanded.occurrence(self.expanded_digest, expanded, packet.token);
        if (!packet.raw.line(raw)) return mismatch;
        switch (packet.transport.mode) {
            .thumbnail => {
                if (!packet.expanded.line(expanded) or
                    !std.mem.eql(u8, raw[0..packet.raw.end], expanded[0..packet.expanded.end])) return mismatch;
            },
            .inline_player => if (!packet.validInlineOwner(expanded)) return mismatch,
        }
        return .{
            .source = live_token,
            .file = packet.file,
            .width_px = packet.transport.width_css_px,
            .height_px = packet.transport.height_css_px,
            .mode = switch (packet.transport.mode) {
                .inline_player => .inline_player,
                .thumbnail => .thumbnail,
            },
            .completed = completed,
        };
    }
};
