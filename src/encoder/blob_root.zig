pub const part_kind = @import("part_kind.zig");
pub const document_ir = @import("document_ir.zig");
pub const blob_format = @import("blob_format.zig");
pub const blob_catalog = @import("blob_catalog.zig");
pub const presentation_types = @import("presentation_types.zig");
pub const presentation_codec = @import("presentation_codec.zig");

test "blob encoder root imports data-only presentation codecs" {
    _ = blob_format;
    _ = blob_catalog;
    _ = presentation_types;
    _ = presentation_codec;
    _ = part_kind;
}

pub const wikitext_syntax = @import("wikitext_syntax.zig");
