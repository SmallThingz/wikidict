import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {collections, exact} from './library.js';

// Every member and row below is synthetic. Publication basenames are computed
// from those language labels to exercise the normal collection validation.
function member(id, rows, {edition = 'aywiktionary', date = '20261001', language = 'English', name} = {}) {
  const languageKey = createHash('sha256').update(language).digest('hex');
  return {
    id,
    name: name ?? edition + '-' + date + '-' + languageKey + '.wikblb',
    metadata: {kind: 'language', language},
    rows
  };
}

test("synthetic AY k'iläru resolves from origin 1 to sibling member 3", () => {
  const origin = member(1, [{title: 'origin only'}], {language: 'Unclassified'});
  const other = member(2, [{title: 'other member'}]);
  const sibling = member(3, [{title: "k'iläru", raw_key: "k'iläru"}], {language: 'Aymara'});
  const hit = exact(collections([origin, other, sibling]), {title: "k'iläru", context: 1});
  assert.deepEqual(hit, {
    dictionary: 3,
    context: 3,
    raw_key: "k'iläru",
    title: "k'iläru",
    language: 'Aymara',
    kind: 'language',
    source_edition: 'aywiktionary'
  });
});

test('origin wins even when a matching sibling precedes it', () => {
  const origin = member('origin', [{title: 'shared'}]);
  const sibling = member('sibling', [{title: 'shared'}], {language: 'Aymara'});
  const hit = exact(collections([sibling, origin]), {context: 'origin', title: 'shared'});
  assert.deepEqual([hit.dictionary, hit.context], ['origin', 'origin']);
});

test('fallback skips other editions, dates and unnamed imports before the eligible sibling', () => {
  const origin = member('origin', [{title: 'origin only'}]);
  const foreign = member('foreign', [{title: 'target'}], {edition: 'amwiktionary'});
  const newer = member('newer', [{title: 'target'}], {date: '20261002'});
  const unnamed = member('unnamed', [{title: 'target'}], {name: 'Dictionary.wikblb'});
  const sibling = member('sibling', [{title: 'target'}], {language: 'Aymara'});
  const all = [foreign, newer, unnamed, sibling, origin];
  const hit = exact(collections(all), {context: 'origin', title: 'target'});
  assert.deepEqual([hit?.dictionary, hit?.context], ['sibling', 'sibling']);
  assert.equal(exact(collections(all.filter(value => value !== sibling)),
    {context: 'origin', title: 'target'}), null);
});

test('missing or unnamed origins stay isolated and unnamed local matches still resolve', () => {
  const sibling = member('sibling', [{title: 'target'}]);
  const unnamed = member('unnamed', [{title: 'local'}], {name: 'Dictionary.wikblb'});
  const views = collections([sibling, unnamed]);
  assert.equal(exact(views, {context: 'removed', title: 'target'}), null);
  assert.equal(exact(views, {context: 'unnamed', title: 'target'}), null);
  assert.equal(exact(views, {context: 'unnamed', title: 'local'}).dictionary, 'unnamed');
});

test('invalid publication dates cannot establish a sibling group', () => {
  const origin = member('origin', [], {date: '20260230'});
  const sibling = member('sibling', [{title: 'target'}], {date: '20260230'});
  assert.equal(exact(collections([origin, sibling]), {context: 'origin', title: 'target'}), null);
});

test('context-free ordering and exact Unicode title matching remain consistent', () => {
  const first = member('first', [{title: "k'iläru"}], {edition: 'amwiktionary'});
  const second = member('second', [{title: "k'iläru"}]);
  const views = collections([first, second]);
  assert.equal(exact(views, {title: "k'iläru"}).dictionary, 'first');
  for (const title of ["K'iläru", "k'ila\u0308ru", 'k’iläru', "k'iläru "]) {
    assert.equal(exact(views, {context: 'second', title}), null);
  }
  assert.equal(exact(views, {context: 'second', title: 'missing'}), null);
});

test('origin alias overlays retain their owner, raw key and selected context', () => {
  const origin = member('origin', []);
  const sibling = member('sibling', [], {language: 'Aymara'});
  const aliases = {
    id: 'aliases', name: 'aywiktionary-20261001-aliases.wikblb', metadata: {kind: 'alias'},
    rows: [{title: 'alias', raw_key: '1\talias', source_title: 'Authored alias', source_kind: 'language'}]
  };
  const hit = exact(collections([sibling, origin, aliases]), {context: 'origin', title: 'Authored alias'});
  assert.deepEqual([hit.dictionary, hit.context, hit.raw_key, hit.kind],
    ['aliases', 'origin', '1\talias', 'language']);
});
