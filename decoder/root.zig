pub const format = @import("format.zig");
pub const compact_encoding = @import("compact_runtime.zig");
pub const normalize = @import("normalize");
const reader = @import("reader.zig");

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
}
