// Declared contract controls, not a genuine Yiddish dictionary fixture.
import assert from 'node:assert/strict';
import test from 'node:test';
import {validateFontFamily, fontFamilyCSS} from './font-family.js';
const stack = (names, fallback) => ({stack: {names, fallback}});

test('authored family order and absence of a generic survive serialization', () => {
  const request = stack(['Times New Roman', 'Later Face'], 'css_default');
  const before = JSON.stringify(request);
  assert.equal(fontFamilyCSS(request), '"Times New Roman","Later Face"');
  assert.equal(JSON.stringify(request), before);
  assert.equal(fontFamilyCSS(stack(['Unknown Face'], 'css_default')), '"Unknown Face"');
  assert.equal(fontFamilyCSS(stack(['Face"One', 'Face\\Two'], 'css_default')), '"Face\\"One","Face\\\\Two"');
});

test('legacy generic requests keep their exact CSS', () => {
  assert.equal(fontFamilyCSS('sans_serif'), 'sans-serif');
  assert.equal(fontFamilyCSS(stack([], 'sans_serif')), 'sans-serif');
  assert.equal(fontFamilyCSS(stack([], 'serif')), 'serif');
  assert.equal(fontFamilyCSS(stack(['Georgia'], 'serif')), '"Georgia",serif');
  assert.equal(fontFamilyCSS(stack(['Arial'], 'sans_serif')), '"Arial",sans-serif');
});

test('incomplete, unknown and malformed semantic requests are refused', () => {
  for (const value of [
    null, [], 'serif', 'css_default', 2, {}, {stack: {}},
    {stack: {names: ['Times'], fallback: 'css_default'}, extra: true},
    {stack: {names: ['Times'], fallback: 'css_default', extra: true}},
    stack([], 'css_default'), stack(['Times'], 2), stack(['Times'], 3),
    stack(['Times'], 'unknown'), stack('Times', 'serif'),
    stack(Array(17).fill('Times'), 'serif'),
    ...['', ' serif', 'serif ', 'serif', 'SANS  SERIF', 'monospace',
      'system-ui', 'Bad[Face]', 'Bad\nFace', 'Bad\0Face', '顔', 'x'.repeat(129)]
      .map(name => stack([name], 'css_default')),
  ]) assert.throws(() => validateFontFamily(value), /Invalid compiled font family/);
  assert.doesNotThrow(() => validateFontFamily(stack(Array(16).fill('x'.repeat(128)), 'css_default')));
});
