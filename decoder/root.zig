pub const encoder = @import("encoder");
pub const format = encoder.format;
pub const compact_encoding = encoder.compact_encoding;

pub const normalize = @import("normalize.zig");

pub const Dictionary = @import("reader.zig").Dictionary;
pub const LookupHit = @import("reader.zig").LookupHit;
pub const EntryView = @import("reader.zig").EntryView;

pub fn openDictionary(allocator: @import("std").mem.Allocator, io: @import("std").Io, path: []const u8) !Dictionary {
    return Dictionary.open(allocator, io, path);
}
