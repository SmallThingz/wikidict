pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_encoding.zig");
pub const section_encoding = @import("section_encoding.zig");
const blobs = @import("blob_encoder");
pub const language_parts = blobs.language_parts;
pub const blob_codec_support = blobs.blob_codec_support;
pub const thesaurus_encoding = blobs.thesaurus_encoding;
pub const rhymes_encoding = blobs.rhymes_encoding;
pub const language_blob_encoding = blobs.language_blob_encoding;
pub const reconstruction_encoding = blobs.reconstruction_encoding;
pub const blob_format = blobs.blob_format;
pub const blob_catalog = blobs.blob_catalog;
pub const blob_files = @import("blob_files.zig");
pub const blob_builder = @import("blob_builder.zig");
pub const presentation_compile = @import("presentation_compile.zig");
pub const presentation_layout = @import("presentation_layout.zig");
pub const presentation_document = @import("presentation_document.zig");
pub const presentation_types = blobs.presentation_types;
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
    _ = language_blob_encoding;
    _ = reconstruction_encoding;
    _ = blob_format;
    _ = blob_catalog;
    _ = blob_builder;
    _ = presentation_compile;
    _ = presentation_layout;
    _ = presentation_document;
    _ = presentation_types;
    _ = xml_decode;
    _ = wikitext;
    _ = builder;
}

pub const name_linker = @import("name_linker.zig");
