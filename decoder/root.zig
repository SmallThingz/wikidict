pub const encoder = @import("encoder");
pub const format = encoder.format;
pub const compact_encoding = encoder.compact_encoding;

pub const normalize = @import("normalize");
const reader = @import("reader.zig");

pub const Dictionary = @import("reader.zig").Dictionary;
pub const LookupHit = @import("reader.zig").LookupHit;
pub const EntryView = @import("reader.zig").EntryView;
pub const TermListView = @import("reader.zig").TermListView;
pub const OpenOptions = @import("reader.zig").OpenOptions;

pub fn openDictionary(allocator: @import("std").mem.Allocator, io: @import("std").Io, path: []const u8) !Dictionary {
    return Dictionary.open(allocator, io, path, .{});
}

pub fn openDictionaryWithOptions(
    allocator: @import("std").mem.Allocator,
    io: @import("std").Io,
    path: []const u8,
    options: OpenOptions,
) !Dictionary {
    return Dictionary.open(allocator, io, path, options);
}

test "decoder root imports module tests" {
    _ = normalize;
    _ = reader;
}
