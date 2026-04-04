pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_encoding.zig");
pub const section_encoding = @import("section_encoding.zig");
pub const xml_decode = @import("xml_decode.zig");
pub const wikitext = @import("wikitext.zig");

pub const BuildOptions = @import("builder.zig").BuildOptions;
pub const BuildStats = @import("builder.zig").BuildStats;

pub fn buildDictionary(io: @import("std").Io, allocator: @import("std").mem.Allocator, options: BuildOptions) !BuildStats {
    return @import("builder.zig").build(io, allocator, options);
}
