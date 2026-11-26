import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {decode} from './blob.js';
import {sectionHeadingCompanion} from './renderer.js';
import {linkNameCandidate} from './check-edition-link-name.js';
import {expectedTextFragments,normalizeVisibleText,expectedBodyTextFragments,entryTextProblems} from './check-edition-text.js';

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

test('PS heading-only screening preserves heading coverage and detects genuinely missing body text', async () => {
  const fixture = JSON.parse(await readFile(new URL('./testdata/ps-heading-only.json', import.meta.url), 'utf8'));
  const sha = value => createHash('sha256').update(value).digest('hex');
  assert.equal(sha(fixture.source.text), fixture.source.text_sha256);
  const bytes = Buffer.from(fixture.record.payload_hex, 'hex');
  assert.equal(bytes.length, fixture.record.length);
  assert.equal(sha(bytes), fixture.record.sha256);
  const entry = decode(bytes, {title:fixture.title,kind:'language',language:'Unclassified',source_edition:fixture.edition});
  const section = entry.sections[0], heading = 'انگرېزي';
  assert.equal(entry.sections.length, 1);
  assert.equal(section.blocks.length, 1);
  assert.equal(sectionHeadingCompanion(section), section.blocks[0]);
  assert.deepEqual([...expectedTextFragments(entry.sections)], [heading]);
  assert.equal(expectedBodyTextFragments(entry).size, 0);
  assert.deepEqual(entryTextProblems(entry, fixture.title+'\n'+heading, 0), {});
  // Removing the heading is still a defect; we have not dropped it from the oracle.
  assert.deepEqual(entryTextProblems(entry, fixture.title, 0), {
    missingTextExamples:[heading],missingTextCandidates:1
  });

  const text = value => ({kind:'text',text:value});
  const withBody = block => ({...entry,sections:[{...section,blocks:[section.blocks[0],block]}]});
  const definition = {kind:'definition',spans:[text('actual definition')]};
  const populated = withBody(definition);
  assert.deepEqual(entryTextProblems(populated, fixture.title+' '+heading, 0), {
    missingTextExamples:['actual definition'],missingTextCandidates:1,emptyVisibleBody:true
  });
  assert.deepEqual(entryTextProblems(populated, fixture.title+' '+heading+' actual definition', 1), {});
  // Repeated heading text and one-character definitions must not mask an absent body.
  for (const value of [heading, 'x']) {
    assert.equal(entryTextProblems(withBody({kind:'definition',spans:[text(value)]}), heading, 0).emptyVisibleBody, true);
  }
  const standalone = {...entry,sections:[{...section,title:'Another section'}]};
  assert.equal(sectionHeadingCompanion(standalone.sections[0]), null);
  assert.equal(entryTextProblems(standalone, heading, 0).emptyVisibleBody, true);
  const aligned = {...entry,sections:[{...section,blocks:[{...section.blocks[0],text_align:'left'}]}]};
  assert.equal(sectionHeadingCompanion(aligned.sections[0]), null);
  assert.equal(entryTextProblems(aligned, heading, 0).emptyVisibleBody, true);

  // Do not lose recursive content or content outside the ordinary section body.
  for (const block of [
    {kind:'container',container:{blocks:[definition]}},
    {kind:'table',table:{rows:[{cells:[{spans:[text('table cell')]}]}]}}
  ]) assert.equal(entryTextProblems(withBody(block), heading, 0).emptyVisibleBody, true);
  for (const extra of [
    {preamble_spans:[text('preamble')]},
    {references:[{spans:[text('reference')]}]},
    {references:[{blocks:[definition]}]}
  ]) assert.equal(entryTextProblems({...entry,...extra}, heading, 0).emptyVisibleBody, true);
  assert.equal(expectedBodyTextFragments(withBody({kind:'paragraph',spans:[{...text('hidden'),font_scale:0}]})).size, 0);
  // A styled title remains in overall coverage, never in the body predicate.
  const styledTitle = {...entry,display_title:[text('Styled title')]};
  assert.deepEqual(entryTextProblems(styledTitle, heading, 0), {
    missingTextExamples:['Styled title'],missingTextCandidates:1
  });
});
