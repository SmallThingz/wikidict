import assert from 'node:assert/strict';
import test from 'node:test';
import {spans, renderEntry} from './renderer.js';
import {validate} from './validate.js';
const invalid = {stack: {names: [], fallback: 'css_default'}};
const span = (kind, text = '') => ({kind, text, target: '', trail: '', font_family: invalid});
const entry = values => ({kind: 'language', title: 'Named font control', display_title: values, sections: [], preamble_spans: [], references: [], media: []});
// Each malformed request must be refused before any DOM work, including values
// that ordinary whitespace compaction would otherwise discard.
globalThis.document = new Proxy({}, {get() { throw Error('DOM accessed before family validation'); }});
test('standalone span entry validates blank and line-break families before dropping them', () => {
  for (const kind of ['text', 'line_break']) {
    for (const preserve of [false, true]) {
      assert.throws(() => spans([span(kind)], undefined, preserve), /Invalid compiled font family/);
    }
  }
});
test('complete entry preflight refuses malformed display-title families before DOM work', () => {
  for (const kind of ['text', 'line_break']) {
    assert.throws(() => renderEntry(entry([span(kind)]), () => {}), /Invalid compiled font family/);
  }
});
test('JSON structural entry rejects malformed family in each named span-array route', () => {
  for (const field of ['display_title', 'preamble_spans', 'spans']) {
    const value = entry([]);
    if (field === 'spans') value.sections = [{title: 'Control', blocks: [{kind: 'paragraph', spans: [span('text')]}]}];
    else value[field] = [span('line_break')];
    assert.throws(() => validate({schema: 'dict.results.v1', entries: [value]}), /Invalid compiled font family/);
  }
});
