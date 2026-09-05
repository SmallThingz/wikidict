const std = @import("std");
const ir = @import("vm_ir.zig");
const codec = @import("vm_codec.zig");

pub const magic = "DICTVM1\x00";

pub const Entry = struct {
    title: []const u8,
    program: *ir.Program,
};

pub const Bundle = struct {
    entries: []Entry,
    by_title: std.StringHashMapUnmanaged(*ir.Program) = .empty,

    pub fn get(self: *const Bundle, title: []const u8) ?*ir.Program {
        return self.by_title.get(title);
    }
};

fn readU32(bytes: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > bytes.len) return error.Truncated;
    const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}
fn readU64(bytes: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > bytes.len) return error.Truncated;
    const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

pub const BlobIndex = struct {
    by_title: std.StringHashMapUnmanaged([]const u8) = .empty,
    count: usize = 0,

    pub fn get(self: *const BlobIndex, title: []const u8) ?[]const u8 {
        return self.by_title.get(title);
    }
};

pub fn index(a: std.mem.Allocator, bytes: []const u8) !BlobIndex {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    var pos: usize = magic.len;
    const count = try readU32(bytes, &pos);
    var out: BlobIndex = .{ .count = count };
    try out.by_title.ensureTotalCapacity(a, count);
    for (0..count) |_| {
        const title_len = try readU32(bytes, &pos);
        const blob_len_u64 = try readU64(bytes, &pos);
        const blob_len = std.math.cast(usize, blob_len_u64) orelse return error.FileTooBig;
        if (pos + title_len + blob_len > bytes.len) return error.Truncated;
        const title = bytes[pos .. pos + title_len];
        pos += title_len;
        const blob = bytes[pos .. pos + blob_len];
        pos += blob_len;
        try out.by_title.put(a, title, blob);
    }
    if (pos != bytes.len) return error.TrailingData;
    return out;
}

pub fn deserialize(a: std.mem.Allocator, bytes: []const u8) !Bundle {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic))
        return error.BadMagic;
    var pos: usize = magic.len;
    const count = try readU32(bytes, &pos);
    const entries = try a.alloc(Entry, count);
    var by_title: std.StringHashMapUnmanaged(*ir.Program) = .empty;
    for (entries, 0..) |*entry, i| {
        const title_len = try readU32(bytes, &pos);
        const blob_len_u64 = try readU64(bytes, &pos);
        const blob_len = std.math.cast(usize, blob_len_u64) orelse return error.FileTooBig;
        if (pos + title_len + blob_len > bytes.len) return error.Truncated;
        const title = try a.dupe(u8, bytes[pos .. pos + title_len]);
        pos += title_len;
        const program = try a.create(ir.Program);
        program.* = try codec.deserialize(a, bytes[pos .. pos + blob_len]);
        pos += blob_len;
        entry.* = .{ .title = title, .program = program };
        try by_title.put(a, title, program);
        _ = i;
    }
    if (pos != bytes.len) return error.TrailingData;
    return .{ .entries = entries, .by_title = by_title };
}
