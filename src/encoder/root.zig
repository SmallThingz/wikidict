const blobs = @import("blob_encoder");

pub const part_kind = blobs.part_kind;
pub const language_source = @import("language_source.zig");
pub const document_ir = blobs.document_ir;
pub const blob_format = blobs.blob_format;
pub const blob_catalog = blobs.blob_catalog;
pub const presentation_types = blobs.presentation_types;
pub const blob_files = @import("blob_files.zig");
pub const blob_builder = @import("blob_builder.zig");
pub const presentation_compile = @import("presentation_compile.zig");
pub const presentation_layout = @import("presentation_layout.zig");
pub const presentation_document = @import("presentation_document.zig");

test "encoder root imports bundle-time presentation modules" {
    _ = part_kind;
    _ = language_source;
    _ = document_ir;
    _ = blob_format;
    _ = blob_catalog;
    _ = presentation_types;
    _ = blob_files;
    _ = blob_builder;
    _ = presentation_compile;
    _ = presentation_layout;
    _ = presentation_document;
}
