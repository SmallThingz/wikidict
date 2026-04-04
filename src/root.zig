pub const format = @import("format.zig");
pub const normalize = @import("normalize.zig");
pub const xml_decode = @import("xml_decode.zig");
pub const wikitext = @import("wikitext.zig");

pub const Dictionary = @import("reader.zig").Dictionary;
pub const LookupHit = @import("reader.zig").LookupHit;
pub const EntryView = @import("reader.zig").EntryView;

pub const BuildOptions = @import("builder.zig").BuildOptions;
pub const BuildStats = @import("builder.zig").BuildStats;
pub const ServeOptions = @import("server.zig").ServeOptions;

pub fn buildDictionary(io: @import("std").Io, allocator: @import("std").mem.Allocator, options: BuildOptions) !BuildStats {
    return @import("builder.zig").build(io, allocator, options);
}

pub fn serveDictionary(io: @import("std").Io, allocator: @import("std").mem.Allocator, args: []const []const u8) !void {
    return @import("server.zig").serve(io, allocator, args);
}
