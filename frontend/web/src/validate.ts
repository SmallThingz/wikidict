import type { Entry, Results } from './types';
import { validOrganization } from './organization';
const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const textOrNull = (v: unknown) => v === null || typeof v === 'string';
const count = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0;
const between = (v: unknown, min: number, max: number) => count(v) && (v as number) >= min && (v as number) <= max;
const kind = (v: unknown) => ['language', 'thesaurus', 'citations', 'reconstruction', 'rhymes', 'sign_gloss'].includes(v as string);
const list = (v: unknown, test: (item: unknown) => boolean) => Array.isArray(v) && v.every(test);
const optional = (v: unknown, test: (item: unknown) => boolean) => v === undefined || test(v);
const text = (v: unknown) => typeof v === 'string';
const span = (p: unknown): boolean => record(p) && ['text', 'template', 'link', 'external_link', 'line_break'].includes(p.kind as string)
  && text(p.text) && text(p.target) && text(p.trail) && typeof p.bold === 'boolean' && typeof p.italic === 'boolean'
  && ['code', 'small', 'superscript', 'subscript', 'strike', 'underline'].every(k => optional(p[k], v => typeof v === 'boolean'))
  && optional(p.language, text) && optional(p.role, v => ['normal', 'label', 'pronunciation', 'headword', 'example', 'quotation', 'citation', 'reference'].includes(v as string));
const table = (t: unknown): boolean => t === null || (record(t) && list(t.caption, span) && list(t.rows, r => record(r) && list(r.cells, c => record(c) && list(c.spans, span) && typeof c.header === 'boolean' && between(c.colspan, 1, 100) && between(c.rowspan, 1, 100))));
const block = (b: unknown): boolean => record(b) && ['paragraph', 'blank', 'definition', 'example', 'quotation', 'list_item', 'list_detail', 'indent', 'term', 'preformatted', 'heading', 'table', 'rule'].includes(b.kind as string)
  && between(b.depth, 0, 255) && text(b.text) && list(b.spans, span)
  && optional(b.list_path, v => typeof v === 'string' && /^[#*:;]{0,255}$/.test(v)) && optional(b.number, text) && optional(b.level, v => between(v, 0, 6)) && optional(b.table, table)
  && (b.feature === null || (record(b.feature) && ['kind', 'language', 'data', 'tail_kind', 'tail'].every(k => record(b.feature) && text(b.feature[k]))));
/** Pure validation shared by standalone exports and embedded consumers. */
export function isResults(value: unknown): value is Results {
  if (!record(value)) return false;
  const r = value;
  return r.schema === 'dict.results.v1' && ['lookup', 'search', 'stats', 'render'].includes(r.operation as string)
    && text(r.query) && kind(r.kind) && textOrNull(r.language) && text(r.match_mode)
    && count(r.record_count) && count(r.total_matches) && count(r.offset) && typeof r.has_more === 'boolean'
    && list(r.matches, m => record(m) && text(m.title))
    && list(r.entries, e => record(e) && text(e.title) && kind(e.kind) && textOrNull(e.language)
      && (e.expansion == null || (record(e.expansion) && ["lua-aot", "lua-vm"].includes(e.expansion.backend as string) && ["ok", "failed"].includes(e.expansion.status as string) && textOrNull(e.expansion.diagnostic)))
      && optional(e.media, value => list(value, m => record(m) && text(m.file) && text(m.caption) && ['image','audio'].includes(m.kind as string) && ['author','license','license_url','source_url'].every(k=>textOrNull(m[k])) && (m.license_text == null || text(m.license_text)) && (m.data_url === null || (typeof m.data_url === 'string' && (m.kind === 'image' ? /^data:image\/(jpeg|png|gif|webp);base64,[A-Za-z0-9+/=]+$/ : /^data:audio\/(ogg|wav|mpeg|flac);base64,[A-Za-z0-9+/=]+$/).test(m.data_url)))))
      && optional(e.content, v => v === 'complete' || v === 'core')
      && optional(e.language_code, text) && text(e.preamble) && count(e.unexpanded_templates) && optional(e.rendered_templates, count) && ['structured', 'raw', 'invalid_payload'].includes(e.status as string)
      && optional(e.preamble_spans, v => list(v, span)) && optional(e.references, v => list(v, ref => record(ref) && between(ref.number, 1, 100000) && text(ref.name) && text(ref.body) && list(ref.spans, span)))
      && textOrNull(e.source) && textOrNull(e.source_base64) && textOrNull(e.payload_base64)
      && list(e.sections, s => record(s) && text(s.title) && between(s.level, 1, 6) && list(s.blocks, block) && (s.deferred == null || (['etymology','translations','relations','references','quotations'].includes(s.deferred as string) && Array.isArray(s.blocks) && s.blocks.length === 0 && e.content === 'core')))
      && (e.content !== 'core' || (e.source === null && e.source_base64 === null && e.expansion == null))
      && optional(e.organization, value => validOrganization(value, e as unknown as Entry)));
}
