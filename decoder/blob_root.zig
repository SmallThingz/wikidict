const blob_reader = @import("blob_reader.zig");
const blob_catalog = @import("blob_encoder").blob_catalog;

pub const BlobView = blob_reader.BlobView;
pub const BlobRecordView = blob_reader.RecordView;
pub const BlobBoundRecord = blob_reader.BoundRecord;
pub const BlobRecordIterator = blob_reader.RecordIterator;
pub const BlobIndexedView = blob_reader.IndexedBlobView;
pub const BlobLanguageRecordView = blob_reader.LanguageRecordView;
pub const BlobThesaurusRecordView = blob_reader.ThesaurusRecordView;
pub const BlobRhymesRecordView = blob_reader.RhymesRecordView;
pub const BlobReconstructionRecordView = blob_reader.ReconstructionRecordView;
pub const BlobRawRecordView = blob_reader.RawRecordView;
pub const BlobSupplementRecordView = blob_reader.SupplementRecordView;
pub const BlobCatalogEntry = blob_catalog.Entry;
pub const BlobCatalogIterator = blob_catalog.Iterator;
pub const language_blob_filename_len = blob_catalog.language_blob_filename_len;
pub const blob_manifest_filename = blob_catalog.manifest_filename;
pub const blob_language_directory = blob_catalog.language_directory;
pub const languageBlobFilename = blob_catalog.languageBlobFilename;
pub const featureBlobFilename = blob_catalog.featureBlobFilename;

pub fn findLanguageBlob(manifest_bytes: []const u8, heading: []const u8) error{InvalidManifest}!?BlobCatalogEntry {
    return blob_catalog.find(manifest_bytes, heading);
}

pub fn inspectBlob(bytes: []const u8) error{InvalidBlob}!BlobView {
    return BlobView.inspect(bytes);
}

/// Fast path for blobs whose integrity was established externally.
/// This parses only the blob identity/semantic metadata; build a runtime index for random access.
/// Use inspectBlob for a full record-framing and title-order validation pass.
pub fn openTrustedBlob(bytes: []const u8) error{InvalidBlob}!BlobView {
    return BlobView.openTrusted(bytes);
}

test "blob decoder root imports portable reader" {
    _ = blob_reader;
    _ = blob_catalog;
}
