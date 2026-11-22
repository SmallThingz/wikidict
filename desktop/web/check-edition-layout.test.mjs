import assert from 'node:assert/strict';
import test from 'node:test';
import {linkNameCandidate} from './check-edition-link-name.js';
import {expectedTextFragments,normalizeVisibleText} from './check-edition-text.js';

function element(text, attributes = {}, images = []) {
  return {textContent:text, getAttribute:name => attributes[name] ?? null, querySelectorAll:() => images};
}

test('screening recognizes explicit labels and leaves unlabeled whitespace as a candidate', () => {
  assert.equal(linkNameCandidate(element(' ', {'aria-label':'File:Sugar-485057.jpg'})), 'File:Sugar-485057.jpg');
  assert.equal(linkNameCandidate(element('caption', {'aria-label':'  explicit   label '})), 'explicit label');
  assert.equal(linkNameCandidate(element('\u00a0', {'aria-label':'  '})), '');
});

test('screening falls back to normalized text, image labels and tooltip', () => {
  assert.equal(linkNameCandidate(element(' a  caption ', {'aria-label':'  ', title:'tip'})), 'a caption');
  assert.equal(linkNameCandidate(element(' ', {title:'tip'}, [element('', {alt:' image label '})])), 'image label');
  assert.equal(linkNameCandidate(element(' ', {title:' Authored tooltip '})), 'Authored tooltip');
});

test('Upper Sorbian transliteration keeps the combining dot on the preceding text span', () => {
  const text = value => ({kind:'text',text:value});
  const spans = [{kind:'link',text:'أبيض'}, text(' (abyad'), text('\u0323'), text(')')];
  const fragments = expectedTextFragments([{blocks:[{table:{rows:[{cells:[{spans}]}]}}]}]);
  assert.deepEqual([...fragments], ['أبيض', '(abyaḍ']);
  const missing = visible => [...fragments].filter(fragment => !normalizeVisibleText(visible).includes(fragment));
  assert.deepEqual(missing('أبيض (abyad\u0323)'), []);
  assert.deepEqual(missing('أبيض (abyad)'), ['(abyaḍ']);
  assert.deepEqual(missing('أبيض (abyad\u0301)'), ['(abyaḍ']);
});

test('independent cells, line breaks and hidden spans preserve their own text boundaries', () => {
  const base = {kind:'link',text:'lin',trail:'ked'};
  const mark = {kind:'text',text:'\u0323'};
  assert.deepEqual([...expectedTextFragments([{spans:[base]}, {spans:[mark]}])], ['linked']);
  assert.deepEqual([...expectedTextFragments([base,{kind:'line_break'},mark])], ['linked']);
  assert.deepEqual([...expectedTextFragments([base,{...mark,font_scale:0}])], ['linked']);
});
