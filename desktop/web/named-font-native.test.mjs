import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {decode} from './blob.js';
const dir = new URL('./testdata/yi-named-font/', import.meta.url);
const payload = new Uint8Array(await readFile(new URL('tog.dpr', dir)));
assert.equal(createHash('sha256').update(payload).digest('hex'), '351046ab2224cd239539115b2b6b7a43bcf8377265c56b90e1f6b3a6d1b03f26');
const fixture = JSON.parse(await readFile(new URL('manifest.json', dir), 'utf8'));
const expected = fixture.exact_decoded_caption_link_candidates[0].span;
const meta = {kind: 'language', title: 'טאָג', language_code: '', language: 'Unclassified'};
const values = root => {
  const found = [];
  const visit = value => {
    if (!value || typeof value !== 'object') return;
    if (Object.hasOwn(value, 'font_family')) found.push(value);
    for (const child of Object.values(value)) visit(child);
  };
  visit(root); return found;
};
const fields = span => Object.fromEntries(['kind', 'text', 'target', 'font_scale', 'font_scale_basis', 'font_family', 'direction'].map(key => [key, span[key]]));
const fallbackOffset = fixture.raw_named_stack_markers[0].fallback_offset_in_dpr;
const nameBytes = new TextEncoder().encode(expected.font_family.stack.names[0]);
const unionOffset = fallbackOffset - 9 - nameBytes.length;
assert.deepEqual(Array.from(payload.slice(unionOffset, unionOffset + 9)), [1, 1, 0, 0, 0, nameBytes.length, 0, 0, 0]);
assert.equal(new TextDecoder().decode(payload.slice(unionOffset + 9, fallbackOffset)), 'Times New Roman');
assert.equal(payload[fallbackOffset], 2);

test('genuine retained caption decodes to the native codec font request and metrics', () => {
  const decoded = decode(payload, meta);
  const [span, ...other] = values(decoded);
  assert.equal(other.length, 0);
  assert.deepEqual(fields(span), fields(expected));
  assert.deepEqual(span.inline_style.line_height, expected.inline_style.line_height);
  assert.equal(span.inline_style.font_normalized, expected.inline_style.font_normalized);
  assert.equal(decoded.presentation_version, 'DPRP');
});
test('unknown union and fallback values and malformed family requests are refused', () => {
  for (const [offset, value] of [[unionOffset, 2], [fallbackOffset, 3], [unionOffset + 1, 17], [unionOffset + 9, 91]]) {
    const changed = payload.slice(); changed[offset] = value;
    assert.throws(() => decode(changed, meta));
  }
  const emptyNames = Uint8Array.from([...payload.slice(0, unionOffset + 1), 0, 0, 0, 0, ...payload.slice(fallbackOffset)]);
  assert.throws(() => decode(emptyNames, meta), /Invalid compiled font family/);
});
test('DPRP font-only acceptance requires the exact declared feature, without masking others', () => {
  for (const feature of [0, 1, 2, 5, 6, 8, 12, 16, 20, 32, 36, 64, 68, 128, 132, 255]) {
    const changed = payload.slice(); changed[changed.length - 1] = feature;
    assert.throws(() => decode(changed, meta), /DPRP font feature/);
  }
});
test('legacy named-stack fallbacks and sans-serif union retain their typed values', () => {
  for (const [tag, fallback] of [[0, 'sans_serif'], [1, 'serif']]) {
    const changed = payload.slice(); changed[fallbackOffset] = tag;
    const [span] = values(decode(changed, meta));
    assert.deepEqual(span.font_family, {stack: {names: ['Times New Roman'], fallback}});
  }
  const legacyUnion = Uint8Array.from([...payload.slice(0, unionOffset), 0, ...payload.slice(fallbackOffset + 1)]);
  const [span] = values(decode(legacyUnion, meta));
  assert.equal(span.font_family, 'sans_serif');
});
