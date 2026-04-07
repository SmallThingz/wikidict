pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_encoding.zig");
pub const section_encoding = @import("section_encoding.zig");
pub const xml_decode = @import("shared_xml_decode");
pub const wikitext = @import("wikitext_source");
pub const cli_args = @import("cli_args");

pub const BuildOptions = @import("builder.zig").BuildOptions;
pub const BuildStats = @import("builder.zig").BuildStats;
pub const GeneratedBuildDataView = @import("builder.zig").GeneratedBuildDataView;
const builder = @import("builder.zig");

pub fn buildDictionary(io: @import("std").Io, allocator: @import("std").mem.Allocator, options: BuildOptions) !BuildStats {
    return builder.build(io, allocator, options);
}

pub fn currentGeneratedBuildData() GeneratedBuildDataView {
    return builder.currentGeneratedBuildData();
}

test "encoder root imports module tests" {
    _ = format;
    _ = compact_encoding;
    _ = section_encoding;
    _ = xml_decode;
    _ = wikitext;
    _ = cli_args;
    _ = builder;
}
