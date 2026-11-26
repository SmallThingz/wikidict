import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {validateContainerBlock} from './validate.js';
import {renderEntry} from './renderer.js';
const repository = new URL('../../', import.meta.url);

const capture = readFileSync(new URL(
  'renderer/src/format/testdata/it-disclosure-button-captured.json', repository));
assert.equal(createHash('sha256').update(capture).digest('hex'),
  'c5b0e5998409bf5f26dae8d7dbb9160402b4ea016e07356e317a0e4f94873c4e');
function block() {
  return {kind: 'container', spans: [], container: {
    style: {}, blocks: [
      {kind: 'paragraph', spans: [{kind: 'text', text: 'Heading'}]},
      {kind: 'container', spans: [], container: {style: {}, blocks: []}},
    ], disclosure: JSON.parse(capture),
  }};
}

test('container validator preserves absent/null disclosure and closes the new gate', () => {
  const value = block();
  assert.throws(() => validateContainerBlock(value), /Invalid compiled container/);
  assert.throws(() => validateContainerBlock(value, {containerDisclosureButtons: false}), /Invalid compiled container/);
  assert.throws(() => validateContainerBlock(value, {containerDisclosureButtons: 'true'}), /Invalid compiled container/);
  value.container.disclosure = null;
  assert.doesNotThrow(() => validateContainerBlock(value));
  delete value.container.disclosure;
  assert.doesNotThrow(() => validateContainerBlock(value));
});

test('internal typed-model admission validates ownership, button fields and flow layout', () => {
  const options = {containerDisclosureButtons: true};
  const value = block();
  const before = JSON.stringify(value);
  assert.doesNotThrow(() => validateContainerBlock(value, options));
  assert.equal(JSON.stringify(value), before);
  value.container.style.layout = 'flow';
  assert.doesNotThrow(() => validateContainerBlock(value, options));
  value.container.style.layout = 'ordered_list';
  assert.throws(() => validateContainerBlock(value, options), /Invalid compiled container/);
  value.container.style = {};
  value.container.disclosure.content_index = 0;
  assert.throws(() => validateContainerBlock(value, options), /Invalid compiled container disclosure button/);
  value.container.disclosure.content_index = 1;
  value.container.disclosure.button.appearance = 'link';
  assert.throws(() => validateContainerBlock(value, options), /Invalid compiled container disclosure button/);
});

test('public DPRa typed rendering admits the button; older/private versions cannot opt in through settings', () => {
  assert.equal(typeof globalThis.document, 'undefined');
  const publicEntry = {presentation_version: 'DPRa', display_title: [], preamble_spans: [],
    sections: [{title: 'IT button', blocks: [block()]}]};
  // All rich validation runs before DOM construction. No browser is simulated here.
  assert.throws(() => renderEntry(publicEntry, () => {}), /document is not defined/);
  for (const version of ['DPRZ', 'DPR!']) {
    const entry = {presentation_version: version, display_title: [], preamble_spans: [],
      sections: [{title: 'IT button', blocks: [block()]}]};
    assert.throws(() => renderEntry(entry, () => {}, {containerDisclosureButtons: true}),
      /Invalid compiled container/);
  }
});
