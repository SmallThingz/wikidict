import assert from 'node:assert/strict';
import test from 'node:test';
import {linkNameCandidate} from './check-edition-link-name.js';

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
