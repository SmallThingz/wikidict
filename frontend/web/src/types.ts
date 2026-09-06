/** Public dict.results.v1 protocol. Original source and rendered presentation are separate. */
export type Span = { kind: 'text' | 'template' | 'link' | 'external_link' | 'line_break'; text: string; target: string; trail: string; bold: boolean; italic: boolean;
  language?: string; code?: boolean; small?: boolean; superscript?: boolean; subscript?: boolean; strike?: boolean; underline?: boolean; role?: string };
export type Feature = { kind: string; language: string; data: string; tail_kind: string; tail: string };
export type Cell = { spans: Span[]; header: boolean; colspan: number; rowspan: number };
export type Table = { caption: Span[]; rows: { cells: Cell[] }[] };
export type Block = { kind: string; depth: number; text: string; spans: Span[]; feature: Feature | null; list_path?: string; number?: string; level?: number; table?: Table | null };
export type Section = { level: number; title: string; blocks: Block[] };
export type Reference = { number: number; name: string; body: string; spans: Span[] };
export type Entry = {
  organization?: Organization;
  language_code?: string;
  title: string; kind: string; language: string | null; sections: Section[]; preamble: string;
  expansion?: { backend: string; status: "ok" | "failed"; diagnostic: string | null } | null;
  unexpanded_templates: number; rendered_templates?: number; preamble_spans?: Span[]; references?: Reference[]; status: 'structured' | 'raw' | 'invalid_payload';
  source: string | null; source_base64: string | null; payload_base64: string | null;
};
export type Results = {
  schema: 'dict.results.v1'; operation: string; query: string; kind: string; language: string | null;
  match_mode: string; record_count: number; total_matches: number; offset: number; has_more: boolean;
  matches: { title: string }[]; entries: Entry[];
};
export const emptyResults: Results = { schema: 'dict.results.v1', operation: 'lookup', query: '', kind: 'language', language: null, match_mode: 'exact-utf8', record_count: 0, total_matches: 0, offset: 0, has_more: false, matches: [], entries: [] };
export type Navigation = { title: string; language: string | null; kind: string; fragment?: string };
export type MountOptions = { onNavigate?: (target: Navigation) => void; inheritedTheme?: boolean };

/** Indices refer to source sections/blocks. The complete source-order model is retained. */
export type FormRelation = { relation: string; target: string; language: string };
export type Sense = { block: number; parent: number | null; examples: number[]; quotations: number[]; notes: number[]; form: FormRelation | null };
export type Lexeme = { language?: string; kind: string; section: number; etymology: number | null; definitions: Sense[]; introduction: number[]; other_blocks: number[]; related_sections: number[] };
export type Organization = { lexemes: Lexeme[]; other_sections: number[] };
