const std = @import("std");

pub const max_frame_bytes: usize = 32 * 1024 * 1024;
pub const max_source_bytes: usize = 16 * 1024 * 1024;
pub const max_display_title_bytes: usize = 64 * 1024;
pub const max_path_bytes: usize = 4096;
pub const max_title_bytes: usize = 4096;
const request_version: u8 = 2;
const request_header_len: usize = 1 + 8 + 8 + 4 * 4;
const success_header_len: usize = 1 + 4 * 2;
const error_header_len: usize = 1 + 4 * 3;

pub const Request = struct {
    root: []const u8,
    dump: []const u8,
    now_unix: i64,
    page_ordinal: u64,
    title: []const u8,
    source: []const u8,
};

pub const SuccessReply = struct {
    output: []const u8,
    display_title: []const u8,
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
    const payload_len = try checkedFramePayload(&.{ request_header_len, request.root.len, request.dump.len, request.title.len, request.source.len });
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, payload_len, .little);
    var header: [request_header_len]u8 = undefined;
    header[0] = request_version;
    std.mem.writeInt(i64, header[1..9], request.now_unix, .little);
    std.mem.writeInt(u64, header[9..17], request.page_ordinal, .little);
    try putU32(header[17..21], request.root.len);
    try putU32(header[21..25], request.dump.len);
    try putU32(header[25..29], request.title.len);
    try putU32(header[29..33], request.source.len);
    try w.writeAll(&outer);
    try w.writeAll(&header);
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
    if (bytes.len < request_header_len or bytes[0] != request_version) return error.InvalidFrame;
    var cursor: usize = 1;
    const now_unix = std.mem.readInt(i64, (try take(bytes, &cursor, 8))[0..8], .little);
    const page_ordinal = std.mem.readInt(u64, (try take(bytes, &cursor, 8))[0..8], .little);
    const root_len = try takeU32(bytes, &cursor);
    const dump_len = try takeU32(bytes, &cursor);
    const title_len = try takeU32(bytes, &cursor);
    const source_len = try takeU32(bytes, &cursor);
    const request: Request = .{
        .root = try take(bytes, &cursor, root_len),
        .dump = try take(bytes, &cursor, dump_len),
        .title = try take(bytes, &cursor, title_len),
        .source = try take(bytes, &cursor, source_len),
        .now_unix = now_unix,
        .page_ordinal = page_ordinal,
    };
    if (cursor != bytes.len) return error.InvalidFrame;
    try validateRequest(request);
    return request;
}

pub fn writeSuccess(w: *std.Io.Writer, output: []const u8, display_title: []const u8) !void {
    if (output.len > max_source_bytes or display_title.len > max_display_title_bytes) return error.FrameTooLarge;
    const payload_len = try checkedFramePayload(&.{ success_header_len, output.len, display_title.len });
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, payload_len, .little);
    var header: [success_header_len]u8 = undefined;
    header[0] = 0;
    try putU32(header[1..5], output.len);
    try putU32(header[5..9], display_title.len);
    try w.writeAll(&outer);
    try w.writeAll(&header);
    try w.writeAll(output);
    try w.writeAll(display_title);
    try w.flush();
}

pub fn writeSkip(w: *std.Io.Writer) !void {
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, 1, .little);
    try w.writeAll(&outer);
    try w.writeByte(2);
    try w.flush();
}

pub fn writeError(w: *std.Io.Writer, stage: []const u8, error_name: []const u8, detail: []const u8) !void {
    const payload_len = try checkedFramePayload(&.{ error_header_len, stage.len, error_name.len, detail.len });
    var outer: [4]u8 = undefined;
    std.mem.writeInt(u32, &outer, payload_len, .little);
    var header: [error_header_len]u8 = undefined;
    header[0] = 1;
    try putU32(header[1..5], stage.len);
    try putU32(header[5..9], error_name.len);
    try putU32(header[9..13], detail.len);
    try w.writeAll(&outer);
    try w.writeAll(&header);
    try w.writeAll(stage);
    try w.writeAll(error_name);
    try w.writeAll(detail);
    try w.flush();
}

pub fn decodeReply(bytes: []const u8) !Reply {
    if (bytes.len == 0) return error.InvalidFrame;
    if (bytes[0] == 0) {
        if (bytes.len < success_header_len) return error.InvalidFrame;
        var cursor: usize = 1;
        const output_len = try takeU32(bytes, &cursor);
        const display_title_len = try takeU32(bytes, &cursor);
        if (output_len > max_source_bytes or display_title_len > max_display_title_bytes) return error.InvalidFrame;
        const success: SuccessReply = .{
            .output = try take(bytes, &cursor, output_len),
            .display_title = try take(bytes, &cursor, display_title_len),
        };
        if (cursor != bytes.len) return error.InvalidFrame;
        return .{ .output = success };
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
    try writeRequest(&bytes.writer, .{ .root = "root", .dump = "dump.xml", .now_unix = 42, .page_ordinal = 17, .title = "cat", .source = "A & B" });
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
}

test "binary bundle replies preserve output and errors" {
    var success: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer success.deinit();
    try writeSuccess(&success.writer, "expanded {{literal}}", "''display''");
    const success_bytes = success.written();
    const success_reply = try decodeReply(success_bytes[4..]);
    try std.testing.expectEqualStrings("expanded {{literal}}", success_reply.output.output);
    try std.testing.expectEqualStrings("''display''", success_reply.output.display_title);

    var failure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer failure.deinit();
    try writeError(&failure.writer, "expand", "LuaError", "detail");
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
    try writeRequest(&request_bytes.writer, .{ .root = "root", .dump = "dump", .now_unix = 1, .page_ordinal = 0, .title = "x", .source = "body" });
    const request = request_bytes.written()[4..];
    try std.testing.expectError(error.InvalidFrame, decodeRequest(request[0 .. request.len - 1]));
    const damaged = try std.testing.allocator.dupe(u8, request);
    defer std.testing.allocator.free(damaged);
    std.mem.writeInt(u32, damaged[29..33], 0xffff_ffff, .little);
    try std.testing.expectError(error.InvalidFrame, decodeRequest(damaged));

    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{}));
    try std.testing.expectError(error.InvalidFrame, decodeReply(&.{ 2, 0 }));
    var error_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer error_bytes.deinit();
    try writeError(&error_bytes.writer, "expand", "Failure", "detail");
    const error_payload = error_bytes.written()[4..];
    try std.testing.expectError(error.InvalidFrame, decodeReply(error_payload[0 .. error_payload.len - 1]));
}
