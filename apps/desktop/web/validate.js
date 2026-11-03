const forbidden = new Set(['source','source_base64','payload_base64','unexpanded_templates','rendered_templates','expansion','deferred','content']);
const kinds = new Set(['text','link','external_link','line_break']);
export function validate(value) {
  if (!value || value.schema !== 'dict.results.v1' || !Array.isArray(value.entries)) throw Error('Unsupported dictionary package.');
  let objects = 0;
  function visit(v, depth = 0) {
    if (depth > 64 || ++objects > 2000000) throw Error('Dictionary structure exceeds the reader limit.');
    if (!v || typeof v !== 'object') return;
    for (const [key, child] of Object.entries(v)) {
      if (forbidden.has(key)) throw Error(`Uncompiled field: ${key}`);
      if (key === 'spans' || key === 'display_title' || key === 'preamble_spans') {
        if (!Array.isArray(child) || child.some(s => !s || !kinds.has(s.kind ?? 'text') || typeof s.text !== 'string')) throw Error('Invalid compiled spans.');
      }
      if (key === 'colspan' || key === 'rowspan') if (!Number.isInteger(child) || child < 1 || child > 100) throw Error('Invalid table span.');
      visit(child, depth + 1);
    }
  }
  visit(value);
  for (const entry of value.entries) {
    if (typeof entry.title !== 'string' || !Array.isArray(entry.sections)) throw Error('Invalid dictionary entry.');
    for (const section of entry.sections) if (typeof section.title !== 'string' || !Array.isArray(section.blocks)) throw Error('Invalid section.');
  }
  return value;
}
export function safeURL(target) {
  try { const url = new URL(target); return ['http:', 'https:'].includes(url.protocol) ? url.href : null; } catch { return null; }
}
