import type { Results } from './types';
const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const textOrNull = (v: unknown) => v === null || typeof v === 'string';
const count = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0;
const kind = (v: unknown) => ['language', 'thesaurus', 'citations', 'reconstruction', 'rhymes', 'sign_gloss'].includes(v as string);
const list = (v: unknown, test: (item: unknown) => boolean) => Array.isArray(v) && v.every(test);
/** Pure validation shared by standalone exports and embedded consumers. */
export function isResults(value: unknown): value is Results {
  if (!record(value)) return false;
  const r = value;
  return r.schema === 'dict.results.v1' && ['lookup', 'search', 'stats'].includes(r.operation as string)
    && typeof r.query === 'string' && kind(r.kind) && textOrNull(r.language) && typeof r.match_mode === 'string'
    && count(r.record_count) && count(r.total_matches) && count(r.offset) && typeof r.has_more === 'boolean'
    && list(r.matches, m => record(m) && typeof m.title === 'string')
    && list(r.entries, e => record(e) && typeof e.title === 'string' && kind(e.kind) && textOrNull(e.language)
      && typeof e.preamble === 'string' && count(e.unexpanded_templates) && ['structured', 'raw', 'invalid_payload'].includes(e.status as string)
      && textOrNull(e.source) && textOrNull(e.source_base64) && textOrNull(e.payload_base64)
      && list(e.sections, s => record(s) && typeof s.title === 'string' && count(s.level) && (s.level as number) >= 2 && (s.level as number) <= 6
        && list(s.blocks, b => record(b) && ['paragraph', 'blank', 'definition', 'example', 'quotation', 'list_item', 'list_detail', 'indent', 'term'].includes(b.kind as string)
          && count(b.depth) && (b.depth as number) <= 255 && typeof b.text === 'string'
          && (b.feature === null || (record(b.feature) && ['kind', 'language', 'data', 'tail_kind', 'tail'].every(k => typeof b.feature === 'object' && b.feature !== null && typeof (b.feature as Record<string, unknown>)[k] === 'string')))
          && list(b.spans, p => record(p) && ['text', 'template', 'link', 'external_link', 'line_break'].includes(p.kind as string)
            && typeof p.text === 'string' && typeof p.target === 'string' && typeof p.trail === 'string' && typeof p.bold === 'boolean' && typeof p.italic === 'boolean'))));
}
