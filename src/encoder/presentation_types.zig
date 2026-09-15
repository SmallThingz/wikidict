const format = @import("blob_format.zig");

pub const schema = "dict.presentation.v1";
pub const part_schema = "dict.presentation-part.v1";
pub const Role = enum { normal, label, pronunciation, headword, example, quotation, citation, reference };
pub const InlineKind = enum { text, link, external_link, line_break };
pub const Span = struct {
    kind: InlineKind = .text,
    text: []const u8 = "",
    target: []const u8 = "",
    trail: []const u8 = "",
    language: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    small: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    strike: bool = false,
    underline: bool = false,
    role: Role = .normal,
};
pub const Feature = struct {
    kind: []const u8,
    language: []const u8 = "",
    data: []const u8 = "",
    tail_kind: []const u8 = "none",
    tail: []const u8 = "",
};
pub const BlockKind = enum { paragraph, blank, definition, example, quotation, list_item, list_detail, indent, term, heading, preformatted, rule, table };
pub const Cell = struct { spans: []const Span = &.{}, header: bool = false, colspan: u16 = 1, rowspan: u16 = 1 };
pub const Row = struct { cells: []const Cell = &.{} };
pub const Table = struct { caption: []const Span = &.{}, rows: []const Row = &.{} };
pub const Block = struct {
    kind: BlockKind,
    depth: u8 = 0,
    spans: []const Span = &.{},
    feature: ?Feature = null,
    list_path: []const u8 = "",
    number: []const u8 = "",
    level: u8 = 0,
    table: ?Table = null,
};
pub const Section = struct {
    level: u8,
    title: []const u8,
    blocks: []const Block = &.{},
};
pub const Form = struct { relation: []const u8, target: []const u8, language: []const u8 };
pub const Sense = struct {
    block: usize,
    parent: ?usize = null,
    examples: []const usize = &.{},
    quotations: []const usize = &.{},
    notes: []const usize = &.{},
    form: ?Form = null,
};
pub const Lexeme = struct {
    language: []const u8 = "",
    kind: []const u8,
    section: usize,
    etymology: ?usize = null,
    definitions: []const Sense = &.{},
    introduction: []const usize = &.{},
    other_blocks: []const usize = &.{},
    related_sections: []const usize = &.{},
};
pub const Layout = struct { lexemes: []const Lexeme = &.{}, other_sections: []const usize = &.{} };
pub const Reference = struct {
    number: usize,
    group_number: usize,
    name: []const u8 = "",
    group: []const u8 = "",
    spans: []const Span = &.{},
};
pub const MediaKind = enum { image, audio };
pub const Media = struct { file: []const u8, kind: MediaKind, caption: []const u8 };
pub const Entry = struct {
    organization: Layout = .{},
    title: []const u8,
    kind: format.BlobKind,
    language: ?[]const u8 = null,
    language_code: []const u8 = "",
    sections: []const Section = &.{},
    preamble_spans: []const Span = &.{},
    references: []const Reference = &.{},
    media: []const Media = &.{},
};
pub const Stored = struct { schema: []const u8 = schema, entry: Entry };
pub const PartSection = struct { index: usize, blocks: []const Block };
pub const Part = struct { schema: []const u8 = part_schema, sections: []const PartSection = &.{} };
