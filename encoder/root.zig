pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_encoding.zig");
pub const section_encoding = @import("section_encoding.zig");
pub const blob_codec_support = @import("blob_codec_support.zig");
pub const thesaurus_encoding = @import("thesaurus_encoding.zig");
pub const rhymes_encoding = @import("rhymes_encoding.zig");
pub const xml_decode = @import("shared_xml_decode");
pub const wikitext = @import("wikitext_source");

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
    _ = blob_codec_support;
    _ = thesaurus_encoding;
    _ = rhymes_encoding;
    _ = xml_decode;
    _ = wikitext;
    _ = builder;
}
