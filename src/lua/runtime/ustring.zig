const std = @import("std");
const rt = @import("zig_runtime");
const upat = @import("ustring_pattern.zig");

const Value = rt.Value;

fn one(_: std.mem.Allocator, value: Value) ![]const Value {
    const out = try std.heap.smp_allocator.alloc(Value, 1);
    out[0] = value;
    return out;
}

fn integer(v: Value) !i64 {
    const n = rt.toNumber(v) orelse return error.NumberExpected;
    return @intFromFloat(@trunc(n));
}

fn sourceArg(args: []const Value) ![]const u8 {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    return args[0].string;
}

fn nextCodepoint(source: []const u8, pos: *usize) !u21 {
    if (pos.* >= source.len) return error.EndOfString;
    const n = try std.unicode.utf8ByteSequenceLength(source[pos.*]);
    if (pos.* + n > source.len) return error.InvalidUtf8;
    const cp = std.unicode.utf8Decode(source[pos.* .. pos.* + n]) catch return error.InvalidUtf8;
    pos.* += n;
    return cp;
}

fn countCodepoints(source: []const u8) !usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < source.len) {
        _ = try nextCodepoint(source, &pos);
        count += 1;
    }
    return count;
}

fn normalizeIndex(raw: i64, len: i64) i64 {
    return if (raw < 0) len + raw + 1 else raw;
}

fn byteOffset(source: []const u8, cp_index: usize) !usize {
    if (cp_index == 0) return 0;
    var pos: usize = 0;
    var index: usize = 1;
    while (index < cp_index and pos < source.len) : (index += 1)
        _ = try nextCodepoint(source, &pos);
    return pos;
}

fn uLen(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const source = try sourceArg(args);
    return one(a, .{ .number = @floatFromInt(try countCodepoints(source)) });
}

fn uSub(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const source = try sourceArg(args);
    const len: i64 = @intCast(try countCodepoints(source));
    var first = normalizeIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, len);
    var last = normalizeIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else -1, len);
    first = @max(@as(i64, 1), first);
    last = @min(len, last);
    if (first > last or first > len) return one(a, .{ .string = "" });
    const start = try byteOffset(source, @intCast(first));
    const end = try byteOffset(source, @intCast(last + 1));
    return one(a, .{ .string = source[start..end] });
}

fn uChar(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    var out: std.ArrayList(u8) = .empty;
    for (args) |arg| {
        const raw = try integer(arg);
        if (raw < 0 or raw > 0x10ffff) return error.InvalidCodepoint;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(raw), &buf) catch return error.InvalidCodepoint;
        try out.appendSlice(a, buf[0..n]);
    }
    return one(a, .{ .string = try out.toOwnedSlice(a) });
}

fn uCodepoint(_: ?*anyopaque, _: *rt.Context, args: []const Value) ![]const Value {
    const source = try sourceArg(args);
    const len: i64 = @intCast(try countCodepoints(source));
    var first = normalizeIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, len);
    var last = normalizeIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else first, len);
    first = @max(@as(i64, 1), first);
    last = @min(len, last);
    if (first > last or first > len) return &.{};
    const out = try std.heap.smp_allocator.alloc(Value, @intCast(last - first + 1));
    var pos = try byteOffset(source, @intCast(first));
    for (out) |*value| value.* = .{ .number = @floatFromInt(try nextCodepoint(source, &pos)) };
    return out;
}

const GcodepointCtx = struct {
    source: []const u8,
    pos: usize,
    remaining: usize,
};

fn gcodepointNext(ctx_raw: ?*anyopaque, runtime: *rt.Context, _: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *GcodepointCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (ctx.remaining == 0) return &.{};
    const cp = try nextCodepoint(ctx.source, &ctx.pos);
    ctx.remaining -= 1;
    return one(a, .{ .number = @floatFromInt(cp) });
}

fn uGcodepoint(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const source = try sourceArg(args);
    const len: i64 = @intCast(try countCodepoints(source));
    var first = normalizeIndex(if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1, len);
    var last = normalizeIndex(if (args.len > 2 and args[2] != .nil) try integer(args[2]) else -1, len);
    first = @max(@as(i64, 1), first);
    last = @min(len, last);
    const ctx = try a.create(GcodepointCtx);
    ctx.* = .{
        .source = source,
        .pos = if (first <= len) try byteOffset(source, @intCast(first)) else source.len,
        .remaining = if (first <= last and first <= len) @intCast(last - first + 1) else 0,
    };
    return one(a, try runtime.newNative(ctx, gcodepointNext));
}

const DecomposeFn = *const fn ([*]const u8, isize, ?[*]i32, isize, c_int) callconv(.c) isize;
const ReencodeFn = *const fn ([*]i32, isize, c_int) callconv(.c) isize;
const FullCaseFn = *const fn ([*]const u8, usize, ?[*:0]const u8, ?*anyopaque, ?[*]u8, *usize) callconv(.c) ?[*]u8;
pub const Normalizer = struct {
    lib: std.DynLib,
    case_lib: std.DynLib,
    decompose: DecomposeFn,
    reencode: ReencodeFn,
    category: upat.CategoryFn,
    lower: FullCaseFn,
    upper: FullCaseFn,
    title: FullCaseFn,
};
const NormalizeCtx = struct { normalizer: *Normalizer, options: c_int };

fn createNormalizer(a: std.mem.Allocator) !*Normalizer {
    const normalizer = try a.create(Normalizer);
    var lib = std.DynLib.open("libutf8proc.so.3") catch try std.DynLib.open("libutf8proc.so");
    const decompose = lib.lookup(DecomposeFn, "utf8proc_decompose") orelse return error.UnicodeNormalizerUnavailable;
    const reencode = lib.lookup(ReencodeFn, "utf8proc_reencode") orelse return error.UnicodeNormalizerUnavailable;
    const category = lib.lookup(upat.CategoryFn, "utf8proc_category") orelse return error.UnicodeNormalizerUnavailable;
    var case_lib = std.DynLib.open("libunistring.so.5") catch try std.DynLib.open("libunistring.so");
    const lower = case_lib.lookup(FullCaseFn, "u8_tolower") orelse return error.UnicodeNormalizerUnavailable;
    const upper = case_lib.lookup(FullCaseFn, "u8_toupper") orelse return error.UnicodeNormalizerUnavailable;
    const title = case_lib.lookup(FullCaseFn, "u8_totitle") orelse return error.UnicodeNormalizerUnavailable;
    normalizer.* = .{ .lib = lib, .case_lib = case_lib, .decompose = decompose, .reencode = reencode, .category = category, .lower = lower, .upper = upper, .title = title };
    return normalizer;
}

fn uIsUtf8(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len == 0 or args[0] != .string) return one(a, .{ .boolean = false });
    _ = countCodepoints(args[0].string) catch return one(a, .{ .boolean = false });
    return one(a, .{ .boolean = true });
}

fn uByteoffset(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const source = try sourceArg(args);
    const delta = if (args.len > 1 and args[1] != .nil) try integer(args[1]) else 1;
    var byte_index = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const bytes_len: i64 = @intCast(source.len);
    if (byte_index < 0) byte_index = bytes_len + byte_index + 1;
    if (byte_index < 1 or byte_index > bytes_len) return one(a, .nil);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(std.heap.smp_allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        try starts.append(std.heap.smp_allocator, pos);
        _ = try nextCodepoint(source, &pos);
    }
    var cp_index: usize = 0;
    const target: usize = @intCast(byte_index - 1);
    while (cp_index + 1 < starts.items.len and starts.items[cp_index + 1] <= target) cp_index += 1;
    var adjusted = delta;
    if (adjusted > 0 and starts.items[cp_index] == target) adjusted -= 1;
    const destination = @as(i64, @intCast(cp_index)) + adjusted;
    if (destination < 0 or destination >= starts.items.len) return one(a, .nil);
    return one(a, .{ .number = @floatFromInt(starts.items[@intCast(destination)] + 1) });
}

pub const CaseKind = enum { lower, upper, title };

pub fn caseAlloc(normalizer: *Normalizer, a: std.mem.Allocator, source: []const u8, kind: CaseKind) ![]const u8 {
    _ = try countCodepoints(source);
    const capacity = std.math.add(usize, std.math.mul(usize, source.len, 4) catch return error.OutOfMemory, 16) catch return error.OutOfMemory;
    const buffer = try a.alloc(u8, @max(capacity, 64));
    var result_len = buffer.len;
    const case_fn = switch (kind) {
        .lower => normalizer.lower,
        .upper => normalizer.upper,
        .title => normalizer.title,
    };
    const result = case_fn(source.ptr, source.len, null, null, buffer.ptr, &result_len) orelse return error.UnicodeCaseFailed;
    if (@intFromPtr(result) == @intFromPtr(buffer.ptr)) return buffer[0..result_len];
    defer std.c.free(@ptrCast(result));
    return a.dupe(u8, result[0..result_len]);
}

fn uCase(ctx_raw: ?*anyopaque, args: []const Value, a: std.mem.Allocator, upper: bool) ![]const Value {
    if (args.len == 0) return error.StringExpected;
    const normalizer: *Normalizer = @ptrCast(@alignCast(ctx_raw.?));
    const source = try stringArg(a, args[0]);
    return one(a, .{ .string = try caseAlloc(normalizer, a, source, if (upper) .upper else .lower) });
}

fn uUpper(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    return uCase(ctx_raw, args, a, true);
}

fn uLower(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    return uCase(ctx_raw, args, a, false);
}

fn uNormalize(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    const ctx: *NormalizeCtx = @ptrCast(@alignCast(ctx_raw.?));
    const source = try sourceArg(args);
    const needed = ctx.normalizer.decompose(source.ptr, @intCast(source.len), null, 0, ctx.options);
    if (needed < 0) return error.InvalidUtf8;
    const count: usize = @intCast(needed);
    const storage = try a.alloc(i32, count + 1);
    const written = ctx.normalizer.decompose(source.ptr, @intCast(source.len), storage.ptr, @intCast(count), ctx.options);
    if (written < 0 or written > needed) return error.UnicodeNormalizeFailed;
    const byte_len = ctx.normalizer.reencode(storage.ptr, written, ctx.options);
    if (byte_len < 0) return error.UnicodeNormalizeFailed;
    const bytes = std.mem.sliceAsBytes(storage);
    return one(a, .{ .string = bytes[0..@intCast(byte_len)] });
}

fn stringArg(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        .number => |v| try rt.numberToString(a, v),
        else => error.StringExpected,
    };
}

fn unicodeCaptureValue(search: *const upat.Search, capture: upat.Capture) !Value {
    return switch (capture) {
        .slice => |v| .{ .string = search.byteSlice(v.start, v.end) },
        .position => |v| .{ .number = @floatFromInt(v + 1) },
        .unfinished => error.UnfinishedCapture,
    };
}

fn unicodeCaptureResults(search: *const upat.Search, m: upat.Match, whole_if_empty: bool) ![]const Value {
    if (m.capture_count == 0) {
        if (!whole_if_empty) return &.{};
        const out = try std.heap.smp_allocator.alloc(Value, 1);
        out[0] = .{ .string = search.byteSlice(m.start, m.end) };
        return out;
    }
    const out = try std.heap.smp_allocator.alloc(Value, m.capture_count);
    for (out, 0..) |*value, i| value.* = try unicodeCaptureValue(search, m.captures[i]);
    return out;
}

fn uFind(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2) return error.MissingArgument;
    const normalizer: *Normalizer = @ptrCast(@alignCast(ctx_raw.?));
    const source = try stringArg(a, args[0]);
    const pat = try stringArg(a, args[1]);
    const init_index = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    const plain = args.len > 3 and args[3].truthy();
    var search = try upat.Search.init(std.heap.smp_allocator, source, pat);
    defer search.deinit();
    const found = if (plain) search.findPlain(init_index) else try search.find(normalizer.category, init_index, true);
    const m = found orelse return one(a, .nil);
    const out = try std.heap.smp_allocator.alloc(Value, 2 + m.capture_count);
    out[0] = .{ .number = @floatFromInt(m.start + 1) };
    out[1] = .{ .number = @floatFromInt(m.end) };
    for (0..m.capture_count) |i| out[2 + i] = try unicodeCaptureValue(&search, m.captures[i]);
    return out;
}

fn uMatch(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2) return error.MissingArgument;
    const normalizer: *Normalizer = @ptrCast(@alignCast(ctx_raw.?));
    const source = try stringArg(a, args[0]);
    const pat = try stringArg(a, args[1]);
    const init_index = if (args.len > 2 and args[2] != .nil) try integer(args[2]) else 1;
    var search = try upat.Search.init(std.heap.smp_allocator, source, pat);
    defer search.deinit();
    const m = try search.find(normalizer.category, init_index, true) orelse return one(a, .nil);
    return unicodeCaptureResults(&search, m, true);
}

const GmatchCtx = struct {
    search: upat.Search,
    category: upat.CategoryFn,
    next_start: usize = 0,
    done: bool = false,
};

fn uGmatchNext(ctx_raw: ?*anyopaque, _: *rt.Context, _: []const Value) ![]const Value {
    const ctx: *GmatchCtx = @ptrCast(@alignCast(ctx_raw.?));
    if (ctx.done) return &.{};
    const m = try ctx.search.findFrom(ctx.category, ctx.next_start, false) orelse {
        ctx.done = true;
        return &.{};
    };
    if (m.end == m.start) {
        if (m.end >= ctx.search.source.codepoints.len) ctx.done = true else ctx.next_start = m.end + 1;
    } else ctx.next_start = m.end;
    return unicodeCaptureResults(&ctx.search, m, true);
}

fn uGmatch(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 2) return error.MissingArgument;
    const normalizer: *Normalizer = @ptrCast(@alignCast(ctx_raw.?));
    const source = try stringArg(a, args[0]);
    const pat = try stringArg(a, args[1]);
    const ctx = try a.create(GmatchCtx);
    ctx.* = .{ .search = try upat.Search.init(a, source, pat), .category = normalizer.category };
    return one(a, try runtime.newNative(ctx, uGmatchNext));
}

fn appendUReplacement(out: *std.ArrayList(u8), repl: []const u8, search: *const upat.Search, m: upat.Match) !void {
    const ta = std.heap.smp_allocator;
    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] != '%') {
            try out.append(ta, repl[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= repl.len) {
            try out.append(ta, '%');
            i += 1;
            continue;
        }
        const code = repl[i + 1];
        if (code == '%') {
            try out.append(ta, '%');
            i += 2;
            continue;
        }
        if (code >= '0' and code <= '9') {
            if (code == '0') {
                try out.appendSlice(ta, search.byteSlice(m.start, m.end));
            } else {
                const index: usize = code - '1';
                if (m.capture_count == 0 and code == '1') {
                    try out.appendSlice(ta, search.byteSlice(m.start, m.end));
                } else {
                    if (index >= m.capture_count) return error.InvalidCapture;
                    switch (m.captures[index]) {
                        .slice => |v| try out.appendSlice(ta, search.byteSlice(v.start, v.end)),
                        .position => |v| {
                            var buf: [32]u8 = undefined;
                            const rendered = try std.fmt.bufPrint(&buf, "{d}", .{v + 1});
                            try out.appendSlice(ta, rendered);
                        },
                        .unfinished => return error.UnfinishedCapture,
                    }
                }
            }
            i += 2;
            continue;
        }
        // Scribunto ustring.gsub preserves unrecognized percent sequences.
        try out.append(ta, '%');
        i += 1;
    }
}

fn replacementValue(runtime: *rt.Context, replacement: Value, search: *const upat.Search, m: upat.Match, a: std.mem.Allocator) ![]const u8 {
    const whole = search.byteSlice(m.start, m.end);
    const value: Value = switch (replacement) {
        .table => |table| blk: {
            const captures = try unicodeCaptureResults(search, m, true);
            defer rt.freeResults(captures);
            break :blk try runtime.getIndex(.{ .table = table }, captures[0]);
        },
        .callable => blk: {
            const captures = try unicodeCaptureResults(search, m, true);
            defer rt.freeResults(captures);
            const result = try runtime.callValue(replacement, captures);
            defer rt.freeResults(result);
            break :blk if (result.len == 0) Value.nil else result[0];
        },
        else => return error.InvalidReplacement,
    };
    return switch (value) {
        .nil => whole,
        .boolean => |b| if (!b) whole else return error.InvalidReplacement,
        .string => |v| v,
        .number => |v| try rt.numberToString(a, v),
        else => return error.InvalidReplacement,
    };
}

fn uGsub(ctx_raw: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    const a = runtime.allocator;
    if (args.len < 3) return error.MissingArgument;
    const normalizer: *Normalizer = @ptrCast(@alignCast(ctx_raw.?));
    const source = try stringArg(a, args[0]);
    const pat = try stringArg(a, args[1]);
    var replacement = args[2];
    if (replacement == .number) replacement = .{ .string = try rt.numberToString(a, replacement.number) };
    if (replacement != .string and replacement != .table and replacement != .callable)
        return error.InvalidReplacement;
    const max_count: usize = if (args.len > 3 and args[3] != .nil)
        @intCast(@max(@as(i64, 0), try integer(args[3])))
    else
        std.math.maxInt(usize);
    var search = try upat.Search.init(std.heap.smp_allocator, source, pat);
    defer search.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.smp_allocator);
    var cursor: usize = 0;
    var next_start: usize = 0;
    var count: usize = 0;
    const anchored = pat.len != 0 and pat[0] == '^';
    while (count < max_count and next_start <= search.source.codepoints.len) {
        const m = try search.findFrom(normalizer.category, next_start, true) orelse break;
        if (m.start < cursor) return error.BadPatternProgress;
        try out.appendSlice(std.heap.smp_allocator, search.byteSlice(cursor, m.start));
        switch (replacement) {
            .string => |v| try appendUReplacement(&out, v, &search, m),
            else => try out.appendSlice(std.heap.smp_allocator, try replacementValue(runtime, replacement, &search, m, a)),
        }
        count += 1;
        cursor = m.end;
        if (anchored) break;
        if (m.end > m.start) next_start = m.end else if (m.end < search.source.codepoints.len) next_start = m.end + 1 else break;
    }
    try out.appendSlice(std.heap.smp_allocator, search.byteSlice(cursor, search.source.codepoints.len));
    const rendered = try a.dupe(u8, out.items);
    const result = try std.heap.smp_allocator.alloc(Value, 2);
    result[0] = .{ .string = rendered };
    result[1] = .{ .number = @floatFromInt(count) };
    return result;
}

fn setNative(runtime: *rt.Context, table: *rt.Table, comptime name: []const u8, comptime call: anytype) !void {
    try table.rawSetNativeField(.ustring, name, try runtime.newNative(null, call));
}
fn setNativeCtx(runtime: *rt.Context, table: *rt.Table, comptime name: []const u8, host: ?*anyopaque, comptime call: anytype) !void {
    try table.rawSetNativeField(.ustring, name, try runtime.newNative(host, call));
}

pub fn install(runtime: *rt.Context, table: *rt.Table) !*Normalizer {
    const a = runtime.allocator;
    try setNative(runtime, table, "isutf8", uIsUtf8);
    try setNative(runtime, table, "byteoffset", uByteoffset);
    try setNative(runtime, table, "len", uLen);
    try setNative(runtime, table, "sub", uSub);
    try setNative(runtime, table, "char", uChar);
    try setNative(runtime, table, "codepoint", uCodepoint);
    try setNative(runtime, table, "gcodepoint", uGcodepoint);
    const normalizer = try createNormalizer(a);
    try setNativeCtx(runtime, table, "upper", normalizer, uUpper);
    try setNativeCtx(runtime, table, "lower", normalizer, uLower);
    try setNativeCtx(runtime, table, "find", normalizer, uFind);
    try setNativeCtx(runtime, table, "match", normalizer, uMatch);
    try setNativeCtx(runtime, table, "gmatch", normalizer, uGmatch);
    try setNativeCtx(runtime, table, "gsub", normalizer, uGsub);
    inline for (.{
        .{ "toNFC", @as(c_int, (1 << 1) | (1 << 3)) },
        .{ "toNFD", @as(c_int, (1 << 1) | (1 << 4)) },
        .{ "toNFKC", @as(c_int, (1 << 1) | (1 << 2) | (1 << 3)) },
        .{ "toNFKD", @as(c_int, (1 << 1) | (1 << 2) | (1 << 4)) },
    }) |item| {
        const ctx = try a.create(NormalizeCtx);
        ctx.* = .{ .normalizer = normalizer, .options = item[1] };
        try setNativeCtx(runtime, table, item[0], ctx, uNormalize);
    }
    return normalizer;
}

test "UTF-8 codepoint primitives" {
    const source = "hé猫";
    try std.testing.expectEqual(@as(usize, 3), try countCodepoints(source));
    var pos: usize = 0;
    try std.testing.expectEqual(@as(u21, 'h'), try nextCodepoint(source, &pos));
    try std.testing.expectEqual(@as(u21, 0x00e9), try nextCodepoint(source, &pos));
    try std.testing.expectEqual(@as(u21, 0x732b), try nextCodepoint(source, &pos));
    try std.testing.expectEqual(source.len, pos);
    try std.testing.expectEqual(@as(usize, 1), try byteOffset(source, 2));
    try std.testing.expectEqual(@as(usize, 3), try byteOffset(source, 3));
}

test "Scribunto full Unicode case mappings match MediaWiki expansions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const ustring = try runtime.newNativeNamespace(.ustring);
    _ = try install(&runtime, ustring);

    const upper = ustring.rawGet(.{ .string = "upper" }).?;
    const expanded = try runtime.callValue(upper, &.{.{ .string = "straße ﬃ ǰ ᾀ" }});
    defer rt.freeResults(expanded);
    try std.testing.expectEqualStrings("STRASSE FFI J̌ ἈΙ", expanded[0].string);

    const lower = ustring.rawGet(.{ .string = "lower" }).?;
    const dotted = try runtime.callValue(lower, &.{.{ .string = "İ ΣΊΣΥΦΟΣ" }});
    defer rt.freeResults(dotted);
    try std.testing.expectEqualStrings("i̇ σίσυφος", dotted[0].string);
}

test "utf8proc canonical normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const normalizer = try createNormalizer(a);
    var nfd_ctx = NormalizeCtx{ .normalizer = normalizer, .options = (1 << 1) | (1 << 4) };
    const nfd = try uNormalize(&nfd_ctx, &runtime, &.{.{ .string = "é" }});
    try std.testing.expectEqualStrings("e\u{301}", nfd[0].string);
    var nfc_ctx = NormalizeCtx{ .normalizer = normalizer, .options = (1 << 1) | (1 << 3) };
    const nfc = try uNormalize(&nfc_ctx, &runtime, &.{.{ .string = "e\u{301}" }});
    try std.testing.expectEqualStrings("é", nfc[0].string);
}

test "Scribunto Unicode pattern functions operate on codepoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime = try rt.Context.init(a, 0);
    defer runtime.deinit();
    const ustring = try runtime.newNativeNamespace(.ustring);
    _ = try install(&runtime, ustring);

    const match_fn = ustring.rawGet(.{ .string = "match" }).?;
    const matched = try runtime.callValue(match_fn, &.{ .{ .string = "ʃə" }, .{ .string = "^." } });
    defer rt.freeResults(matched);
    try std.testing.expectEqualStrings("ʃ", matched[0].string);

    const find_fn = ustring.rawGet(.{ .string = "find" }).?;
    const found = try runtime.callValue(find_fn, &.{ .{ .string = "αβ 12" }, .{ .string = "β%s(%d+)" } });
    defer rt.freeResults(found);
    try std.testing.expectEqual(@as(f64, 2), found[0].number);
    try std.testing.expectEqual(@as(f64, 5), found[1].number);
    try std.testing.expectEqualStrings("12", found[2].string);

    const gsub_fn = ustring.rawGet(.{ .string = "gsub" }).?;
    const replaced = try runtime.callValue(gsub_fn, &.{ .{ .string = "ʃə" }, .{ .string = "^." }, .{ .string = "" } });
    defer rt.freeResults(replaced);
    try std.testing.expectEqualStrings("ə", replaced[0].string);
    try std.testing.expectEqual(@as(f64, 1), replaced[1].number);
}

fn replacementUpper(_: ?*anyopaque, runtime: *rt.Context, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const out = try runtime.allocator.dupe(u8, args[0].string);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return one(runtime.allocator, .{ .string = out });
}

fn replacementUpperFunction(runtime: *rt.Context, _: rt.Captures, args: []const Value) ![]const Value {
    if (args.len == 0 or args[0] != .string) return error.StringExpected;
    const out = try runtime.allocator.dupe(u8, args[0].string);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return one(runtime.allocator, .{ .string = out });
}

test "AOT Unicode gsub supports table and callable replacements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime = try rt.Context.init(arena.allocator(), 0);
    defer runtime.deinit();
    const ustring = try runtime.newNativeNamespace(.ustring);
    _ = try install(&runtime, ustring);
    const gsub = ustring.rawGet(.{ .string = "gsub" }).?;

    const replacements = try runtime.newTable();
    try replacements.rawSet(runtime.allocator, .{ .string = "α" }, .{ .string = "A" });
    const table_out = try runtime.callValue(gsub, &.{ .{ .string = "αβ" }, .{ .string = "." }, .{ .table = replacements } });
    defer rt.freeResults(table_out);
    try std.testing.expectEqualStrings("Aβ", table_out[0].string);

    const callable = try runtime.newNative(null, replacementUpper);
    const call_out = try runtime.callValue(gsub, &.{ .{ .string = "ab" }, .{ .string = "." }, callable });
    defer rt.freeResults(call_out);
    try std.testing.expectEqualStrings("AB", call_out[0].string);
    try std.testing.expectEqual(@as(f64, 2), call_out[1].number);

    const lua_callable = try runtime.makeFunctionKnown(0, replacementUpperFunction, &.{});
    const lua_out = try runtime.callValue(gsub, &.{ .{ .string = "cd" }, .{ .string = "." }, lua_callable });
    defer rt.freeResults(lua_out);
    try std.testing.expectEqualStrings("CD", lua_out[0].string);
    try std.testing.expectEqual(@as(f64, 2), lua_out[1].number);
}
