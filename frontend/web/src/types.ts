/** Public dict.results.v1 protocol. Original source and rendered presentation are separate. */
export type Span = { kind: 'text' | 'template' | 'link' | 'external_link' | 'line_break'; text: string; target: string; trail: string; bold: boolean; italic: boolean;
  language?: string; code?: boolean; small?: boolean; superscript?: boolean; subscript?: boolean; strike?: boolean; underline?: boolean; role?: string };
export type Feature = { kind: string; language: string; data: string; tail_kind: string; tail: string };
export type Cell = { spans: Span[]; header: boolean; colspan: number; rowspan: number };
export type Table = { caption: Span[]; rows: { cells: Cell[] }[] };
export type Block = { kind: string; depth: number; text: string; spans: Span[]; feature: Feature | null; list_path?: string; number?: string; level?: number; table?: Table | null };
export type Section = { level: number; title: string; blocks: Block[]; deferred?: 'etymology' | 'translations' | 'relations' | 'references' | 'quotations' | null };
export type Reference = { number: number; name: string; body: string; spans: Span[] };
export type Media = { file:string;kind:'image'|'audio';caption:string;data_url:string|null;author:string|null;license:string|null;license_url:string|null;source_url:string|null;license_text?:string|null };
export type Entry = {
  media?: Media[];
  content?: 'complete' | 'core';
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
export type MountOptions = { live?: LiveOptions; onNavigate?: (target: Navigation) => void; inheritedTheme?: boolean };

/** Indices refer to source sections/blocks. The complete source-order model is retained. */
export type FormRelation = { relation: string; target: string; language: string };
export type Sense = { block: number; parent: number | null; examples: number[]; quotations: number[]; notes: number[]; form: FormRelation | null };
export type Lexeme = { language?: string; kind: string; section: number; etymology: number | null; definitions: Sense[]; introduction: number[]; other_blocks: number[]; related_sections: number[] };
export type Organization = { lexemes: Lexeme[]; other_sections: number[] };

export type LiveOptions = {
 query: string; language: string; kind: string; languages: {heading: string; code: string}[];
 matches: {title: string}[]; total: number; hasMore: boolean; searching: boolean; loading: boolean; error: string;
 onQuery: (value:string)=>void; onLanguage:(value:string)=>void; onKind:(value:string)=>void;
 onSelect:(title:string)=>void; onMore:()=>void;
};
