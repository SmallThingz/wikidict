pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_runtime.zig");
pub const normalize = @import("normalize");
const reader = @import("reader.zig");
const blobs = @import("blob_decoder");

pub const Dictionary = reader.Dictionary;
pub const LookupHit = reader.LookupHit;
pub const EntryView = reader.EntryView;
pub const TermListView = reader.TermListView;
pub const Document = reader.Document;
pub const DocumentSection = reader.DocumentSection;
pub const DocumentBlock = reader.DocumentBlock;
pub const BlockIterator = reader.BlockIterator;
pub const InlineSpan = reader.InlineSpan;
pub const InlineIterator = reader.InlineIterator;
pub const TermRecordKind = reader.TermRecordKind;
pub const TermRecord = reader.TermRecord;
pub const TranslationRecordKind = reader.TranslationRecordKind;
pub const TranslationSeparator = reader.TranslationSeparator;
pub const TranslationRecord = reader.TranslationRecord;
pub const SectionKind = reader.SectionKind;
pub const BlockKind = reader.BlockKind;
pub const InlineKind = reader.InlineKind;
pub const OpenOptions = reader.OpenOptions;
pub const DictionaryCompatibility = reader.DictionaryCompatibility;
pub const BlobView = blobs.BlobView;
pub const BlobRecordView = blobs.BlobRecordView;
pub const BlobRecordIterator = blobs.BlobRecordIterator;
pub const BlobLanguageRecordView = blobs.BlobLanguageRecordView;
pub const BlobThesaurusRecordView = blobs.BlobThesaurusRecordView;
pub const BlobRhymesRecordView = blobs.BlobRhymesRecordView;
pub const BlobReconstructionRecordView = blobs.BlobReconstructionRecordView;
pub const BlobRawRecordView = blobs.BlobRawRecordView;
pub const BlobCatalogEntry = blobs.BlobCatalogEntry;
pub const BlobCatalogIterator = blobs.BlobCatalogIterator;
pub const language_blob_filename_len = blobs.language_blob_filename_len;
pub const blob_manifest_filename = blobs.blob_manifest_filename;
pub const blob_language_directory = blobs.blob_language_directory;
pub const languageBlobFilename = blobs.languageBlobFilename;
pub const featureBlobFilename = blobs.featureBlobFilename;
pub const findLanguageBlob = blobs.findLanguageBlob;
pub const inspectBlob = blobs.inspectBlob;
pub const openTrustedBlob = blobs.openTrustedBlob;

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

pub fn probeDictionaryCompatibility(io: @import("std").Io, path: []const u8) !DictionaryCompatibility {
    return reader.probeDictionaryCompatibility(io, path);
}

test "decoder root imports module tests" {
    _ = normalize;
    _ = reader;
    _ = blobs;
}
