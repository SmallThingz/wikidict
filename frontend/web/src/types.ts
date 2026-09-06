/** Public dict.results.v1 protocol. Exact source and presentation are separate. */
export type Span = { kind: 'text' | 'template' | 'link' | 'external_link' | 'line_break'; text: string; target: string; trail: string; bold: boolean; italic: boolean };
export type Feature = { kind: string; language: string; data: string; tail_kind: string; tail: string };
export type Block = { kind: string; depth: number; text: string; spans: Span[]; feature: Feature | null };
export type Section = { level: number; title: string; blocks: Block[] };
export type Entry = {
  title: string; kind: string; language: string | null; sections: Section[]; preamble: string;
  unexpanded_templates: number; status: 'structured' | 'raw' | 'invalid_payload';
  source: string | null; source_base64: string | null; payload_base64: string | null;
};
export type Results = {
  schema: 'dict.results.v1'; operation: string; query: string; kind: string; language: string | null;
  match_mode: string; record_count: number; total_matches: number; offset: number; has_more: boolean;
  matches: { title: string }[]; entries: Entry[];
};
export const emptyResults: Results = { schema: 'dict.results.v1', operation: 'lookup', query: '', kind: 'language', language: null, match_mode: 'exact-utf8', record_count: 0, total_matches: 0, offset: 0, has_more: false, matches: [], entries: [] };
export type Navigation = { title: string; language: string | null; kind: string };
export type MountOptions = { onNavigate?: (target: Navigation) => void; inheritedTheme?: boolean };
