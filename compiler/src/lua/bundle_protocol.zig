const std = @import("std");

pub const max_frame_bytes: usize = 32 * 1024 * 1024;
pub const max_source_bytes: usize = 16 * 1024 * 1024;
pub const max_display_title_bytes: usize = 64 * 1024;
pub const max_path_bytes: usize = 4096;
pub const max_title_bytes: usize = 4096;
const request_version: u8 = 5;
const effect_request_version: u8 = 6;
pub const max_page_effect_bytes: usize = 64 * 1024;
// Disjoint from all legacy reply payload tags (0..6).
const reply_envelope_version: u8 = 0x85;
const cpu_envelope_len: usize = 9;
pub const max_poem_metadata_bytes: usize = 16 * 1024 * 1024;
// Encoder-only occurrence provenance; independent from Poem and never DPR data.
pub const max_missing_dependency_metadata_bytes: usize = 16 * 1024 * 1024;
const request_header_len: usize = 1 + 8 + 8 + 8 + 8 + 8 + 4 + 4 * 4;
const success_header_len: usize = 1 + 4 * 2 + 1;
const error_header_len: usize = 1 + 4 * 3;

pub const PageIdentity = struct {
    index_offset: u64,
    page_id: u64,
    revision_id: u64,
    namespace: u32,
};

pub const Request = struct {
    effect_profile: ?[32]u8 = null,
    root: []const u8,
    dump: []const u8,
    now_unix: i64,
    page_ordinal: u64,
    identity: PageIdentity,
    title: []const u8,
    source: []const u8,
};

// Correlation across both sides of one worker job. The build verifies the
// worker binary separately. This digest detects substitution, and binds the
// collector payload even if phases/identity happen to have equal lengths.
pub fn pageEffectBinding(profile: [32]u8, ordinal: u64, id: PageIdentity, title: []const u8,
    raw: []const u8, expanded: []const u8, collector: []const u8) [32]u8
{
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("wikidict.worker-page-effects.v1");
    h.update(&profile);
    var word: [8]u8 = undefined;
    for ([_]u64{ ordinal, id.index_offset, id.page_id, id.revision_id, id.namespace }) |value| {
        std.mem.writeInt(u64, &word, value, .little);
        h.update(&word);
    }
    for ([_][]const u8{ title, raw, expanded, collector }) |part| {
        std.mem.writeInt(u64, &word, @intCast(part.len), .little);
        h.update(&word);
        h.update(part);
    }
    return h.finalResult();
}

pub const BoundPageEffects = struct {
    binding: [32]u8,
    collector: []const u8,
};

pub const SuccessReply = struct {
    page_effect_metadata: ?BoundPageEffects = null,
    output: []const u8,
    display_title: []const u8,
    unsupported_parser_function: bool = false,
    poem_metadata: ?[]const u8 = null,
    missing_dependency_metadata: ?[]const u8 = null,
};

pub const ErrorReply = struct {
    stage: []const u8,
    error_name: []const u8,
    detail: []const u8,
};

pub const Reply = union(enum) {
    output: SuccessReply,
    failure: ErrorReply,
    skip,
    ready,
};

fn checkedFramePayload(parts: []const usize) !u32 {
    var total: usize = 0;
    for (parts) |part| total = std.math.add(usize, total, part) catch return error.FrameTooLarge;
    if (total == 0 or total > max_frame_bytes) return error.FrameTooLarge;
    return std.math.cast(u32, total) orelse return error.FrameTooLarge;
}

fn putU32(out: []u8, value: usize) !void {
    std.mem.writeInt(u32, out[0..4], std.math.cast(u32, value) orelse return error.FrameTooLarge, .little);
}

pub fn validateRequest(request: Request) !void {
    if (request.source.len > max_source_bytes or
        request.root.len == 0 or request.root.len > max_path_bytes or
        request.dump.len == 0 or request.dump.len > max_path_bytes or
        request.title.len == 0 or request.title.len > max_title_bytes)
        return error.InvalidRequest;
}

pub fn writeRequest(w: *std.Io.Writer, request: Request) !void {
    try validateRequest(request);
    const profile_bytes: usize = if (request.effect_profile != null) 32 else 0;
    const payload_len = try checkedFramePayload(&.{ request_header_len, profile_bytes, request.root.len, request.dump.len, request.title.len, request.source.len });
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, payload_len, .little);
    var header: [request_header_len]u8 = undefined;
    header[0] = if (request.effect_profile == null) request_version else effect_request_version;
    std.mem.writeInt(i64, header[1..9], request.now_unix, .little);
    std.mem.writeInt(u64, header[9..17], request.page_ordinal, .little);
    std.mem.writeInt(u64, header[17..25], request.identity.index_offset, .little);
    std.mem.writeInt(u64, header[25..33], request.identity.page_id, .little);
    std.mem.writeInt(u64, header[33..41], request.identity.revision_id, .little);
    std.mem.writeInt(u32, header[41..45], request.identity.namespace, .little);
    try putU32(header[45..49], request.root.len);
    try putU32(header[49..53], request.dump.len);
    try putU32(header[53..57], request.title.len);
    try putU32(header[57..61], request.source.len);
    try w.writeAll(&outer);
    try w.writeAll(&header);
    if (request.effect_profile) |profile| try w.writeAll(&profile);
    try w.writeAll(request.root);
    try w.writeAll(request.dump);
    try w.writeAll(request.title);
    try w.writeAll(request.source);
    try w.flush();
}

fn take(bytes: []const u8, cursor: *usize, len: usize) ![]const u8 {
    const end = std.math.add(usize, cursor.*, len) catch return error.InvalidFrame;
    if (end > bytes.len) return error.InvalidFrame;
    const out = bytes[cursor.*..end];
    cursor.* = end;
    return out;
}

fn takeU32(bytes: []const u8, cursor: *usize) !usize {
    return std.mem.readInt(u32, (try take(bytes, cursor, 4))[0..4], .little);
}

pub fn decodeRequest(bytes: []const u8) !Request {
    if (bytes.len < request_header_len or (bytes[0] != request_version and bytes[0] != effect_request_version)) return error.InvalidFrame;
    var cursor: usize = 1;
    const now_unix = std.mem.readInt(i64, (try take(bytes, &cursor, 8))[0..8], .little);
    const page_ordinal = std.mem.readInt(u64, (try take(bytes, &cursor, 8))[0..8], .little);
    const identity: PageIdentity = .{
        .index_offset = std.mem.readInt(u64, (try take(bytes, &cursor, 8))[0..8], .little),
        .page_id = std.mem.readInt(u64, (try take(bytes, &cursor, 8))[0..8], .little),
        .revision_id = std.mem.readInt(u64, (try take(bytes, &cursor, 8))[0..8], .little),
        .namespace = std.mem.readInt(u32, (try take(bytes, &cursor, 4))[0..4], .little),
    };
    const root_len = try takeU32(bytes, &cursor);
    const dump_len = try takeU32(bytes, &cursor);
    const title_len = try takeU32(bytes, &cursor);
    const source_len = try takeU32(bytes, &cursor);
    const request: Request = .{
        .effect_profile = if (bytes[0] == effect_request_version) (try take(bytes, &cursor, 32))[0..32].* else null,
        .root = try take(bytes, &cursor, root_len),
        .dump = try take(bytes, &cursor, dump_len),
        .title = try take(bytes, &cursor, title_len),
        .source = try take(bytes, &cursor, source_len),
        .now_unix = now_unix,
        .page_ordinal = page_ordinal,
        .identity = identity,
    };
    if (cursor != bytes.len) return error.InvalidFrame;
    try validateRequest(request);
    return request;
}

fn writeSuccess(w: *std.Io.Writer, output: []const u8, display_title: []const u8, unsupported_parser_function: bool) !void {
    return writeSuccessWithPoem(w, output, display_title, unsupported_parser_function, null);
}

fn writeSuccessWithPoem(w: *std.Io.Writer, output: []const u8, display_title: []const u8, unsupported_parser_function: bool, poem_metadata: ?[]const u8) !void {
    return writeSuccessWithMetadata(w, output, display_title, unsupported_parser_function, poem_metadata, null, false);
}

// Missing-dependency phase bytes are opaque here. The shared phase decoder
// authenticates occurrence IDs/ranges against these exact output/title bytes.
fn writeSuccessWithMetadata(w: *std.Io.Writer, output: []const u8, display_title: []const u8, unsupported_parser_function: bool, poem_metadata: ?[]const u8, missing_dependency_metadata: ?[]const u8, timed: bool) !void {
    return writeSuccessPayload(w, .{ .output = output, .display_title = display_title,
        .unsupported_parser_function = unsupported_parser_function, .poem_metadata = poem_metadata,
        .missing_dependency_metadata = missing_dependency_metadata }, timed);
}

fn writeSuccessPayload(w: *std.Io.Writer, reply: SuccessReply, timed: bool) !void {
    const output = reply.output;
    const display_title = reply.display_title;
    const poem_metadata = reply.poem_metadata;
    const missing_dependency_metadata = reply.missing_dependency_metadata;
    if (poem_metadata) |metadata| {
        if (metadata.len == 0 or metadata.len > max_poem_metadata_bytes or !std.unicode.utf8ValidateSlice(metadata)) return error.InvalidPoemMetadata;
    }
    if (missing_dependency_metadata) |metadata| {
        if (metadata.len == 0 or metadata.len > max_missing_dependency_metadata_bytes or !std.unicode.utf8ValidateSlice(metadata)) return error.InvalidMissingDependencyMetadata;
    }
    if (output.len > max_source_bytes or display_title.len > max_display_title_bytes) return error.FrameTooLarge;
    const payload_len = try checkedFramePayload(&.{ success_header_len, if (poem_metadata != null) @as(usize, 4) else 0, if (missing_dependency_metadata != null) @as(usize, 4) else 0, output.len, display_title.len, if (poem_metadata) |metadata| metadata.len else 0, if (missing_dependency_metadata) |metadata| metadata.len else 0 });
    // The optional field may use only the space left after the ordinary
    // payload and CPU trailer. A tight frame preserves every existing field.
    const envelope: usize = if (timed) cpu_envelope_len else 0;
    const spare = max_frame_bytes -| envelope -| @as(usize, payload_len);
    const effects: ?BoundPageEffects = if (reply.page_effect_metadata) |v| blk: {
        if (v.collector.len == 0 or v.collector.len > max_page_effect_bytes or v.collector.len + 36 > spare) break :blk null;
        if (!std.unicode.utf8ValidateSlice(v.collector)) break :blk null;
        break :blk v;
    } else null;
    var header: [success_header_len]u8 = undefined;
    // Existing success0/4 are byte-for-byte unchanged without the new phase.
    header[0] = if (missing_dependency_metadata != null) (if (poem_metadata != null) @as(u8, 6) else 5) else (if (poem_metadata != null) @as(u8, 4) else 0);
    try putU32(header[1..5], output.len);
    try putU32(header[5..9], display_title.len);
    header[9] = @intFromBool(reply.unsupported_parser_function);
    if (effects != null) header[0] |= 0x10;
    const extended_len = try checkedFramePayload(&.{ payload_len, if (effects) |v| 36 + v.collector.len else 0 });
    try writeReplyHeader(w, extended_len, timed);
    try w.writeAll(&header);
    if (poem_metadata) |metadata| {
        var length: [4]u8 = undefined;
        try putU32(&length, metadata.len);
        try w.writeAll(&length);
    }
    if (missing_dependency_metadata) |metadata| {
        var length: [4]u8 = undefined;
        try putU32(&length, metadata.len);
        try w.writeAll(&length);
    }
    if (effects) |v| {
        var length: [4]u8 = undefined;
        try putU32(&length, v.collector.len);
        try w.writeAll(&length);
    }
    try w.writeAll(output);
    try w.writeAll(display_title);
    if (poem_metadata) |metadata| try w.writeAll(metadata);
    if (missing_dependency_metadata) |metadata| try w.writeAll(metadata);
    if (effects) |v| {
        try w.writeAll(&v.binding);
        try w.writeAll(v.collector);
    }
    try w.flush();
}

fn writeReady(w: *std.Io.Writer) !void {
    const frame = [_]u8{ 1, 0, 0, 0, 3 };
    try w.writeAll(&frame);
    try w.flush();
}

fn writeSkip(w: *std.Io.Writer) !void {
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, 1, .little);
    try w.writeAll(&outer);
    try w.writeByte(2);
    try w.flush();
}

fn writeError(w: *std.Io.Writer, stage: []const u8, error_name: []const u8, detail: []const u8, timed: bool) !void {
    const payload_len = try checkedFramePayload(&.{ error_header_len, stage.len, error_name.len, detail.len });
    var header: [error_header_len]u8 = undefined;
    header[0] = 1;
    try putU32(header[1..5], stage.len);
    try putU32(header[5..9], error_name.len);
    try putU32(header[9..13], detail.len);
    try writeReplyHeader(w, payload_len, timed);
    try w.writeAll(&header);
    try w.writeAll(stage);
    try w.writeAll(error_name);
    try w.writeAll(detail);
    try w.flush();
}

fn decodeReply(bytes: []const u8) !Reply {
    if (bytes.len == 0 or bytes.len > max_frame_bytes) return error.InvalidFrame;
    const has_effects = bytes[0] & 0x10 != 0;
    const tag = bytes[0] & ~@as(u8, 0x10);
    if (tag == 0 or tag == 4 or tag == 5 or tag == 6) {
        if (bytes.len < success_header_len) return error.InvalidFrame;
        var cursor: usize = 1;
        const output_len = try takeU32(bytes, &cursor);
        const display_title_len = try takeU32(bytes, &cursor);
        if (output_len > max_source_bytes or display_title_len > max_display_title_bytes) return error.InvalidFrame;
        const diagnostic = (try take(bytes, &cursor, 1))[0];
        if (diagnostic > 1) return error.InvalidFrame;
        const has_poem = tag == 4 or tag == 6;
        const has_missing = tag == 5 or tag == 6;
        const metadata_len = if (has_poem) try takeU32(bytes, &cursor) else 0;
        const missing_len = if (has_missing) try takeU32(bytes, &cursor) else 0;
        const effects_len = if (has_effects) try takeU32(bytes, &cursor) else 0;
        if (has_effects and (effects_len == 0 or effects_len > max_page_effect_bytes)) return error.InvalidFrame;
        if (has_poem and (metadata_len == 0 or metadata_len > max_poem_metadata_bytes)) return error.InvalidFrame;
        if (has_missing and (missing_len == 0 or missing_len > max_missing_dependency_metadata_bytes)) return error.InvalidFrame;
        const success: SuccessReply = .{
            .unsupported_parser_function = diagnostic == 1,
            .output = try take(bytes, &cursor, output_len),
            .display_title = try take(bytes, &cursor, display_title_len),
            .poem_metadata = if (has_poem) try take(bytes, &cursor, metadata_len) else null,
            .missing_dependency_metadata = if (has_missing) try take(bytes, &cursor, missing_len) else null,
            .page_effect_metadata = if (has_effects) .{
                .binding = (try take(bytes, &cursor, 32))[0..32].*,
                .collector = try take(bytes, &cursor, effects_len),
            } else null,
        };
        if (cursor != bytes.len) return error.InvalidFrame;
        if (success.page_effect_metadata) |v| if (!std.unicode.utf8ValidateSlice(v.collector)) return error.InvalidFrame;
        if (success.poem_metadata) |metadata| if (!std.unicode.utf8ValidateSlice(metadata)) return error.InvalidFrame;
        if (success.missing_dependency_metadata) |metadata| if (!std.unicode.utf8ValidateSlice(metadata)) return error.InvalidFrame;
        return .{ .output = success };
    }
    if (bytes[0] == 3) {
        if (bytes.len != 1) return error.InvalidFrame;
        return .ready;
    }
    if (bytes[0] == 2) {
        if (bytes.len != 1) return error.InvalidFrame;
        return .skip;
    }
    if (bytes[0] != 1 or bytes.len < error_header_len) return error.InvalidFrame;
    var cursor: usize = 1;
    const stage_len = try takeU32(bytes, &cursor);
    const name_len = try takeU32(bytes, &cursor);
    const detail_len = try takeU32(bytes, &cursor);
    const failure: ErrorReply = .{
        .stage = try take(bytes, &cursor, stage_len),
        .error_name = try take(bytes, &cursor, name_len),
        .detail = try take(bytes, &cursor, detail_len),
    };
    if (failure.stage.len == 0 or failure.error_name.len == 0 or cursor != bytes.len) return error.InvalidFrame;
    return .{ .failure = failure };
}

test "binary bundle request round trips without copying fields" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeRequest(&bytes.writer, .{ .root = "root", .dump = "dump.xml", .now_unix = 42, .page_ordinal = 17, .identity = .{ .index_offset = 123, .page_id = 456, .revision_id = 789, .namespace = 1728 }, .title = "cat", .source = "A & B" });
    const framed = bytes.written();
    const len = std.mem.readInt(u32, framed[0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(framed.len - 4)), len);
    const decoded = try decodeRequest(framed[4..]);
    try std.testing.expectEqualStrings("root", decoded.root);
    try std.testing.expectEqualStrings("dump.xml", decoded.dump);
    try std.testing.expectEqualStrings("cat", decoded.title);
    try std.testing.expectEqualStrings("A & B", decoded.source);
    try std.testing.expectEqual(@as(i64, 42), decoded.now_unix);
    try std.testing.expectEqual(@as(u64, 17), decoded.page_ordinal);
    try std.testing.expectEqualDeep(PageIdentity{ .index_offset = 123, .page_id = 456, .revision_id = 789, .namespace = 1728 }, decoded.identity);
}

test "binary bundle replies preserve output and errors" {
    var success: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer success.deinit();
    try writeSuccess(&success.writer, "expanded {{literal}}", "''display''", true);
    const success_bytes = success.written();
    const success_reply = try decodeReply(success_bytes[4..]);
    try std.testing.expect(success_reply.output.unsupported_parser_function);
    try std.testing.expectEqualStrings("expanded {{literal}}", success_reply.output.output);
    try std.testing.expectEqualStrings("''display''", success_reply.output.display_title);

    var failure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer failure.deinit();
    try writeError(&failure.writer, "expand", "LuaError", "detail", false);
    const failure_reply = try decodeReply(failure.written()[4..]);
    try std.testing.expectEqualStrings("expand", failure_reply.failure.stage);
    try std.testing.expectEqualStrings("LuaError", failure_reply.failure.error_name);
    try std.testing.expectEqualStrings("detail", failure_reply.failure.detail);

    var skip: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer skip.deinit();
    try writeSkip(&skip.writer);
    try std.testing.expect((try decodeReply(skip.written()[4..])) == .skip);
}

test "binary bundle protocol rejects malformed framing" {
    var request_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer request_bytes.deinit();
    try writeRequest(&request_bytes.writer, .{ .root = "root", .dump = "dump", .now_unix = 1, .page_ordinal = 0, .identity = .{ .index_offset = 0, .page_id = 1, .revision_id = 2, .namespace = 0 }, .title = "x", .source = "body" });
    const request = request_bytes.written()[4..];
    try std.testing.expectError(error.InvalidFrame, decodeRequest(request[0 .. request.len - 1]));
    const damaged = try std.testing.allocator.dupe(u8, request);
    defer std.testing.allocator.free(damaged);
    std.mem.writeInt(u32, damaged[57..61], 0xffff_ffff, .little);
    try std.testing.expectError(error.InvalidFrame, decodeRequest(damaged));

    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{}));
    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{ 2, 0 }));
    var error_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer error_bytes.deinit();
    try writeError(&error_bytes.writer, "expand", "Failure", "detail", false);
    const error_payload = error_bytes.written()[4..];
    try std.testing.expectError(error.InvalidFrame, decodeReply(error_payload[0 .. error_payload.len - 1]));
}

test "bundle success diagnostics reject unknown bits and truncated flags" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeSuccess(&bytes.writer, "body", "", false);
    try std.testing.expect(!(try decodeReply(bytes.written()[4..])).output.unsupported_parser_function);
    const bad = try std.testing.allocator.dupe(u8, bytes.written()[4..]);
    defer std.testing.allocator.free(bad);
    bad[9] = 2;
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad[0..9]));
}

test "ready reply has one explicit strictly decoded payload" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeReady(&bytes.writer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 3 }, bytes.written());
    try std.testing.expect((try decodeReply(bytes.written()[4..])) == .ready);
    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{ 3, 0 }));
    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{4}));
}

test "Poem success framing preserves legacy bytes and handled empty metadata" {
    var legacy: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer legacy.deinit();
    var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ordinary.deinit();
    try writeSuccess(&legacy.writer, "body", "title", true);
    try writeSuccessWithPoem(&ordinary.writer, "body", "title", true, null);
    try std.testing.expectEqualSlices(u8, legacy.written(), ordinary.written());
    try std.testing.expect((try decodeReply(ordinary.written()[4..])).output.poem_metadata == null);
    var modern: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer modern.deinit();
    const metadata = "{\"schema\":\"wikidict.poem-phase.v1\",\"handled\":true,\"items\":[]}";
    try writeSuccessWithPoem(&modern.writer, "<poem>literal</poem>", "", false, metadata);
    const decoded = (try decodeReply(modern.written()[4..])).output;
    try std.testing.expectEqualStrings(metadata, decoded.poem_metadata.?);
    try std.testing.expectEqualStrings("<poem>literal</poem>", decoded.output);
}

test "Poem success rejects truncated unknown oversized and invalid UTF8 metadata" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeSuccessWithPoem(&bytes.writer, "body", "", false, "{}");
    const payload = bytes.written()[4..];
    for (0..payload.len) |end| try std.testing.expectError(error.InvalidFrame, decodeReply(payload[0..end]));
    const bad = try std.testing.allocator.dupe(u8, payload);
    defer std.testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[10..14], 0xffff_ffff, .little);
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    std.mem.writeInt(u32, bad[10..14], @intCast(max_poem_metadata_bytes + 1), .little);
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    std.mem.writeInt(u32, bad[10..14], 0, .little);
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    @memcpy(bad, payload);
    bad[bad.len - 1] = 0xff;
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    bad[0] = 7;
    try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
    try std.testing.expectError(error.InvalidPoemMetadata, writeSuccessWithPoem(&bytes.writer, "", "", false, ""));
    try std.testing.expectError(error.InvalidPoemMetadata, writeSuccessWithPoem(&bytes.writer, "", "", false, &.{0xff}));
    try std.testing.expectError(error.FrameTooLarge, checkedFramePayload(&.{ success_header_len + 4, max_source_bytes, max_poem_metadata_bytes }));
    try std.testing.expectEqual(@as(u32, max_frame_bytes), try checkedFramePayload(&.{max_frame_bytes}));
    try std.testing.expectError(error.FrameTooLarge, checkedFramePayload(&.{ max_frame_bytes, 1 }));
    try std.testing.expectError(error.FrameTooLarge, checkedFramePayload(&.{ std.math.maxInt(usize), 1 }));
}

test "bundle request version rejects old native workers" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeRequest(&bytes.writer, .{ .root = "root", .dump = "dump", .now_unix = 1, .page_ordinal = 0, .identity = .{ .index_offset = 0, .page_id = 1, .revision_id = 2, .namespace = 0 }, .title = "x", .source = "body" });
    const payload = try std.testing.allocator.dupe(u8, bytes.written()[4..]);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(u8, 5), payload[0]);
    payload[0] = 4;
    try std.testing.expectError(error.InvalidFrame, decodeRequest(payload));
    payload[0] = 6;
    try std.testing.expectError(error.InvalidFrame, decodeRequest(payload));
}

test "missing dependency phase preserves legacy success bytes and independent metadata slices" {
    var legacy: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer legacy.deinit();
    try writeSuccessWithMetadata(&legacy.writer, "B", "T", false, null, null, false);
    try std.testing.expectEqualSlices(u8, &.{ 12, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 'B', 'T' }, legacy.written());
    var poem_only: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer poem_only.deinit();
    try writeSuccessWithMetadata(&poem_only.writer, "B", "T", false, "{}", null, false);
    try std.testing.expectEqualSlices(u8, &.{ 18, 0, 0, 0, 4, 1, 0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0, 'B', 'T', '{', '}' }, poem_only.written());
    const phase = "{\"schema\":\"wikidict.missing-dependency-phase.v1\"}";
    for ([_]?[]const u8{ null, "{}" }) |poem| {
        var framed: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer framed.deinit();
        try writeSuccessWithMetadata(&framed.writer, "body", "title", true, poem, phase, false);
        const payload = framed.written()[4..];
        try std.testing.expectEqual(@as(u8, if (poem != null) 6 else 5), payload[0]);
        try std.testing.expectEqual(@as(u32, @intCast(payload.len)), std.mem.readInt(u32, framed.written()[0..4], .little));
        const decoded = (try decodeReply(payload)).output;
        try std.testing.expectEqualStrings("body", decoded.output);
        try std.testing.expectEqualStrings("title", decoded.display_title);
        try std.testing.expect(decoded.unsupported_parser_function);
        try std.testing.expectEqualStrings(phase, decoded.missing_dependency_metadata.?);
        const offset: usize = (if (poem != null) @as(usize, 18) else 14) + 4 + 5 + (if (poem) |value| value.len else 0);
        try std.testing.expect(decoded.missing_dependency_metadata.?.ptr == payload[offset..].ptr);
        if (poem) |value| try std.testing.expectEqualStrings(value, decoded.poem_metadata.?) else try std.testing.expect(decoded.poem_metadata == null);
    }
}

test "missing dependency phase strictly rejects malformed lengths truncation and UTF8" {
    for ([_]?[]const u8{ null, "{}" }) |poem| {
        var framed: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer framed.deinit();
        try writeSuccessWithMetadata(&framed.writer, "body", "title", false, poem, "{}", false);
        const payload = framed.written()[4..];
        for (0..payload.len) |end| try std.testing.expectError(error.InvalidFrame, decodeReply(payload[0..end]));
        const bad = try std.testing.allocator.dupe(u8, payload);
        defer std.testing.allocator.free(bad);
        const at: usize = if (poem != null) 14 else 10;
        for ([_]u32{ 0, @intCast(max_missing_dependency_metadata_bytes + 1), 0xffff_ffff }) |length| {
            @memcpy(bad, payload);
            std.mem.writeInt(u32, bad[at..][0..4], length, .little);
            try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
        }
        @memcpy(bad, payload);
        bad[bad.len - 1] = 0xff;
        try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
        @memcpy(bad, payload);
        bad[9] = 2;
        try std.testing.expectError(error.InvalidFrame, decodeReply(bad));
        try framed.writer.writeByte(0);
        try std.testing.expectError(error.InvalidFrame, decodeReply(framed.written()[4..]));
    }
    var invalid: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidMissingDependencyMetadata, writeSuccessWithMetadata(&invalid.writer, "", "", false, null, "", false));
    try std.testing.expectError(error.InvalidMissingDependencyMetadata, writeSuccessWithMetadata(&invalid.writer, "", "", false, null, &.{0xff}, false));
    try std.testing.expectEqual(@as(usize, 0), invalid.written().len);
    try std.testing.expectError(error.FrameTooLarge, checkedFramePayload(&.{ success_header_len + 8, max_source_bytes, max_poem_metadata_bytes, max_missing_dependency_metadata_bytes }));
}

// Only this stamped interface is exported to producer and client. Payload-only
// codecs above are private and cannot provide an old-worker compatibility path.
fn writeReplyHeader(w: *std.Io.Writer, payload_len: u32, timed: bool) !void {
    var outer: [4]u8 = undefined;
    const total = try checkedFramePayload(&.{ payload_len, if (timed) cpu_envelope_len else 0 });
    std.mem.writeInt(u32, &outer, total, .little);
    try w.writeAll(&outer);
    if (timed) try w.writeByte(reply_envelope_version);
}

pub const TimedReply = struct { cpu_ns: u64, reply: Reply };

fn writeTimedPayload(w: *std.Io.Writer, reply: Reply) !void {
    switch (reply) {
        .output => |v| try writeSuccessPayload(w, v, true),
        .failure => |v| try writeError(w, v.stage, v.error_name, v.detail, true),
        .ready, .skip => {
            try writeReplyHeader(w, 1, true);
            try w.writeByte(if (reply == .ready) 3 else 2);
            try w.flush();
        },
    }
}

fn writeCpuTrailer(w: *std.Io.Writer, cpu_ns: u64) !void {
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u64, &trailer, cpu_ns, .little);
    try w.writeAll(&trailer);
    try w.flush();
}

pub fn writeTimedReply(w: *std.Io.Writer, cpu_ns: u64, reply: Reply) !void {
    try writeTimedPayload(w, reply);
    try writeCpuTrailer(w, cpu_ns);
}

// Producer clock is sampled after payload serialization/flush. No payload copy
// or staging allocation is needed; a clock failure leaves an incomplete frame.
pub fn writeTimedReplyWithClock(w: *std.Io.Writer, clock: anytype, reply: Reply) !void {
    try writeTimedPayload(w, reply);
    try writeCpuTrailer(w, try clock());
}

pub fn decodeTimedReply(bytes: []const u8) !TimedReply {
    if (bytes.len <= cpu_envelope_len or bytes.len > max_frame_bytes or bytes[0] != reply_envelope_version) return error.InvalidFrame;
    const end = bytes.len - 8;
    return .{ .cpu_ns = std.mem.readInt(u64, bytes[end..][0..8], .little), .reply = try decodeReply(bytes[1..end]) };
}

test "CPU reply envelope rejects old missing truncated and malformed readiness" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try writeTimedReply(&bytes.writer, 123456789, .ready);
    const timed = try decodeTimedReply(bytes.written()[4..]);
    try std.testing.expectEqual(@as(u64, 123456789), timed.cpu_ns);
    try std.testing.expect(timed.reply == .ready);
    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(&.{3}));
    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(bytes.written()[4..12]));
    const broken = try std.testing.allocator.dupe(u8, bytes.written()[4..]);
    defer std.testing.allocator.free(broken);
    broken[0] = 4;
    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(broken));
    broken[0] = reply_envelope_version;
    broken[1] = 99;
    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(broken));
}

test "completed OOM and ordinary replies retain exact CPU stamps independently of worker lifetime" {
    const replies = [_]Reply{ .{ .failure = .{ .stage = "expand", .error_name = "OutOfMemory", .detail = "owned" } }, .skip, .{ .output = .{ .output = "body", .display_title = "title" } } };
    for (replies) |reply| {
        var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer bytes.deinit();
        try writeTimedReply(&bytes.writer, 987, reply);
        const decoded = try decodeTimedReply(bytes.written()[4..]);
        try std.testing.expectEqual(@as(u64, 987), decoded.cpu_ns);
        try std.testing.expectEqual(std.meta.activeTag(reply), std.meta.activeTag(decoded.reply));
        if (decoded.reply == .failure) try std.testing.expectEqualStrings("OutOfMemory", decoded.reply.failure.error_name);
        try std.testing.expectError(error.InvalidFrame, decodeTimedReply(bytes.written()[4 .. bytes.written().len - 1]));
    }
}

test "producer CPU trailer samples after payload and clock failure leaves an incomplete frame" {
    const Clock = struct {
        var output: *std.Io.Writer.Allocating = undefined;
        fn now() !u64 {
            // Framed length, version and ready tag have already been emitted.
            try std.testing.expectEqual(@as(usize, 6), output.written().len);
            return 321;
        }
        fn unavailable() !u64 {
            return error.WorkerCpuClockUnavailable;
        }
    };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    Clock.output = &bytes;
    try writeTimedReplyWithClock(&bytes.writer, Clock.now, .ready);
    try std.testing.expectEqual(@as(u64, 321), (try decodeTimedReply(bytes.written()[4..])).cpu_ns);
    var partial: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer partial.deinit();
    try std.testing.expectError(error.WorkerCpuClockUnavailable, writeTimedReplyWithClock(&partial.writer, Clock.unavailable, .ready));
    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(partial.written()[4..]));
}

test "page effects opt in per request and preserve legacy timed reply fields" {
    const a = std.testing.allocator;
    var query: Request = .{ .root = "/root", .dump = "/dump", .title = "Entry", .source = "raw",
        .now_unix = 1, .page_ordinal = 0, .identity = .{ .index_offset = 2, .page_id = 3, .revision_id = 4, .namespace = 0 } };
    for ([_]bool{ false, true }) |collect| {
        query.effect_profile = if (collect) @as([32]u8, @splat(0x42)) else null;
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try writeRequest(&out.writer, query);
        const message = out.written()[4..];
        const decoded = try decodeRequest(message);
        try std.testing.expectEqual(query.effect_profile, decoded.effect_profile);
        try std.testing.expectEqualStrings(query.source, decoded.source);
        try std.testing.expectEqual(@as(u8, if (collect) 6 else 5), message[0]);
        try std.testing.expectError(error.InvalidFrame, decodeRequest(message[0 .. message.len - 1]));
    }
    for ([_]?[]const u8{ null, "{}" }) |poem| for ([_]?[]const u8{ null, "[]" }) |missing| {
        for ([_]?[]const u8{ null, "{\"schema\":1}" }) |effects| {
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            try writeTimedReply(&out.writer, 77, .{ .output = .{ .output = "expanded", .display_title = "Shown",
                .unsupported_parser_function = true, .poem_metadata = poem, .missing_dependency_metadata = missing,
                .page_effect_metadata = if (effects) |v| .{ .binding = @splat(7), .collector = v } else null } });
            const frame = out.written()[4..];
            const timed = try decodeTimedReply(frame);
            try std.testing.expectEqual(@as(u64, 77), timed.cpu_ns);
            const got = timed.reply.output;
            try std.testing.expect(got.unsupported_parser_function);
            try std.testing.expectEqualStrings("expanded", got.output);
            try std.testing.expectEqualStrings("Shown", got.display_title);
            if (poem) |v| try std.testing.expectEqualStrings(v, got.poem_metadata.?) else try std.testing.expect(got.poem_metadata == null);
            if (missing) |v| try std.testing.expectEqualStrings(v, got.missing_dependency_metadata.?) else try std.testing.expect(got.missing_dependency_metadata == null);
            if (effects) |v| {
                try std.testing.expectEqualStrings(v, got.page_effect_metadata.?.collector);
                const copied = try a.dupe(u8, frame);
                defer a.free(copied);
                const offset: usize = 1 + success_header_len + @as(usize, @intFromBool(poem != null)) * 4 + @as(usize, @intFromBool(missing != null)) * 4;
                for ([_]u32{ 0, max_page_effect_bytes + 1, 1 }) |wrong| {
                    std.mem.writeInt(u32, copied[offset..][0..4], wrong, .little);
                    try std.testing.expectError(error.InvalidFrame, decodeTimedReply(copied));
                }
                @memcpy(copied, frame);
                copied[copied.len - 9] = 0xff;
                try std.testing.expectError(error.InvalidFrame, decodeTimedReply(copied));
            } else try std.testing.expect(got.page_effect_metadata == null);
        }
    };
    const over = try a.alloc(u8, max_page_effect_bytes + 1);
    defer a.free(over);
    @memset(over, 'x');
    var bounded: std.Io.Writer.Allocating = .init(a);
    defer bounded.deinit();
    try writeTimedReply(&bounded.writer, 1, .{ .output = .{ .output = "body", .display_title = "", .page_effect_metadata = .{ .binding = @splat(7), .collector = over } } });
    try std.testing.expect((try decodeTimedReply(bounded.written()[4..])).reply.output.page_effect_metadata == null);
}
