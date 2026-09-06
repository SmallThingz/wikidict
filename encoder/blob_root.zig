pub const document_ir = @import("document_ir.zig");
pub const blob_codec_support = @import("blob_codec_support.zig");
pub const thesaurus_encoding = @import("thesaurus_encoding.zig");
pub const rhymes_encoding = @import("rhymes_encoding.zig");
pub const language_blob_encoding = @import("language_blob_encoding.zig");
pub const reconstruction_encoding = @import("reconstruction_encoding.zig");
pub const blob_format = @import("blob_format.zig");
pub const blob_catalog = @import("blob_catalog.zig");

test "blob encoder root imports portable codecs" {
    _ = blob_codec_support;
    _ = thesaurus_encoding;
    _ = rhymes_encoding;
    _ = language_blob_encoding;
    _ = reconstruction_encoding;
    _ = blob_format;
    _ = blob_catalog;
}
