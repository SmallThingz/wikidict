const std = @import("std");

pub const magic = "WIKDICT1";
pub const version: u32 = 1;

pub const StringRef = extern struct {
    offset: u32 = 0,
    len: u32 = 0,
};

pub const Range = extern struct {
    start: u32 = 0,
    len: u32 = 0,
};

pub const lookup_kind_title: u8 = 0;
pub const lookup_kind_alternative_form: u8 = 1;

pub const flag_alias_only: u32 = 1 << 0;

pub const Header = extern struct {
    magic_bytes: [8]u8,
    version: u32,
    header_size: u32,
    entry_count: u32,
    string_list_count: u32,
    section_count: u32,
    sense_count: u32,
    lookup_count: u32,
    reserved0: u32 = 0,
    entries_offset: u64,
    string_lists_offset: u64,
    sections_offset: u64,
    senses_offset: u64,
    lookups_offset: u64,
    strings_offset: u64,
    strings_len: u64,

    pub fn init(
        entry_count: u32,
        string_list_count: u32,
        section_count: u32,
        sense_count: u32,
        lookup_count: u32,
        entries_offset: u64,
        string_lists_offset: u64,
        sections_offset: u64,
        senses_offset: u64,
        lookups_offset: u64,
        strings_offset: u64,
        strings_len: u64,
    ) Header {
        return .{
            .magic_bytes = magic.*,
            .version = version,
            .header_size = @sizeOf(Header),
            .entry_count = entry_count,
            .string_list_count = string_list_count,
            .section_count = section_count,
            .sense_count = sense_count,
            .lookup_count = lookup_count,
            .entries_offset = entries_offset,
            .string_lists_offset = string_lists_offset,
            .sections_offset = sections_offset,
            .senses_offset = senses_offset,
            .lookups_offset = lookups_offset,
            .strings_offset = strings_offset,
            .strings_len = strings_len,
        };
    }
};

pub const EntryRecord = extern struct {
    word: StringRef,
    normalized: StringRef,
    alt_forms: Range,
    canonical_targets: Range,
    incoming_aliases: Range,
    sections: Range,
    senses: Range,
    flags: u32 = 0,
};

pub const SectionRecord = extern struct {
    group: StringRef,
    title: StringRef,
    body: StringRef,
};

pub const SenseRecord = extern struct {
    group: StringRef,
    pos: StringRef,
    gloss: StringRef,
    examples: StringRef,
    depth: u16 = 0,
    flags: u16 = 0,
};

pub const LookupRecord = extern struct {
    key: StringRef,
    display: StringRef,
    entry_index: u32,
    kind: u8,
    reserved: [3]u8 = .{ 0, 0, 0 },
};

test "header magic is stable" {
    try std.testing.expectEqualStrings(magic, &Header.init(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).magic_bytes);
}
