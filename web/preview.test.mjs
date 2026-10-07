import test from 'node:test';
import assert from 'node:assert/strict';
import {entryClue,hitKey,refreshSavedClue} from './preview.js';

const span=(text,script='',extra={})=>({kind:'text',text,trail:'',script,...extra});
const block=(kind,...spans)=>({kind,spans});
const entry=(...blocks)=>({title:'Fallback title',sections:[{title:'Any section',blocks}]});

test('AF spinal cord shape skips media-only pronunciation and keeps linked indent meaning',()=>{
  const actual={title:'spinal cord',sections:[
    {title:'Engels (en)',blocks:[block('paragraph',span(' ')),block('table')]},
    {title:'Uitspraak',blocks:[block('indent',span('\u00a0'),span('\u00a0'),
      span('Nuvola apps amarok.png','wikidict-media',{kind:'link',target:'File:Nuvola apps amarok.png'}),
      span('\u00a0'),span('LL-Q1860 (eng)-Vealhurl-spinal cord.wav','wikidict-media',{kind:'link',target:'File:LL-Q1860 (eng)-Vealhurl-spinal cord.wav'}),
      span('(','audiotable'),span('lêer','audiotable',{kind:'link',target:'Image:LL-Q1860 (eng)-Vealhurl-spinal cord.wav'}),span(')','audiotable'))]},
    {title:'Selfstandige naamwoord',blocks:[]},
    {title:'Betekenisse',blocks:[block('indent',span('('),span('anatomie','',{kind:'link',target:'anatomie'}),span(')'),span(' '),span('Rugmurg','',{kind:'link',target:'rugmurg'}))]}
  ]};
  const before=structuredClone(actual);
  assert.equal(entryClue(actual),'(anatomie) Rugmurg');
  assert.deepEqual(actual,before,'preview must not change the rendered entry');
  for(const section of actual.sections)section.title='No language-specific heading';
  assert.equal(entryClue(actual),'(anatomie) Rugmurg');
});

test('first nonblank semantic definition retains priority over earlier ordinary prose',()=>{
  assert.equal(entryClue(entry(
    block('paragraph',span('Earlier prose')),
    block('definition',span('sound.wav','wikidict-media'),span(' \u00a0')),
    block('definition',span('First definition')),
    block('definition',span('Second definition'))
  )),'First definition');
});

test('media class tokens are exact and only affect preview text',()=>{
  assert.equal(entryClue(entry(block('indent',
    span('ignored','other wikidict-media\tLatn'),span('control','audiotable extra'),
    span('Useful '),span('linked prose','',{kind:'link',target:'meaning'}),span('', '',{kind:'line_break'}),span('continues')
  ))),'Useful linked prose continues');
  assert.equal(entryClue(entry(block('paragraph',span('Keep this','not-wikidict-media audiotables')))),'Keep this');
  assert.equal(entryClue(entry(block('paragraph',span('A file can be prose','',{kind:'link',target:'File:Example.png'})))),'A file can be prose');
});

test('first remaining nonblank block is used, with title fallback for media-only entries',()=>{
  assert.equal(entryClue(entry(block('blank'),block('indent',span('\u00a0')),block('paragraph',span('Fallback prose')))),'Fallback prose');
  assert.equal(entryClue(entry(block('indent',span('audio','audiotable'),span('image','wikidict-media'),span(' \u00a0')))),'Fallback title');
});

test('saved clue refresh requires exact dictionary, selected context and raw key',()=>{
  const hit={dictionary:'aliases',context:'AF-English',raw_key:'1\tCats',title:'Cats'};
  const selected={...hit,clue:'Old title',at:17,savedAt:12,review:{right:3,wrong:1},extra:'retain'};
  const saved=[selected,
    {...selected,dictionary:'other-aliases'},
    {...selected,context:'AR-English'},
    {...selected,raw_key:'1\tcats'},
    {...selected,raw_key:'7\tCats'}];
  const before=structuredClone(saved),refreshed=refreshSavedClue(saved,hit,'A meaning');
  assert.deepEqual(refreshed[0],{...selected,clue:'A meaning'});
  assert.deepEqual(saved,before);
  assert.equal(refreshed.length,saved.length);
  for(let i=1;i<saved.length;i++)assert.equal(refreshed[i],saved[i]);
  assert.equal(refreshed[0].review,selected.review);
  assert.equal(refreshSavedClue(refreshed,hit,'A meaning'),refreshed);
  assert.equal(refreshSavedClue(saved,{...hit,dictionary:'absent'},'No match'),saved);
  assert.equal(hitKey({dictionary:'one',title:'cat'}),hitKey({dictionary:'one',context:'one',raw_key:'cat',title:'Other display'}));
});

test('ordered list numbering remains distinct from a semantic definition',()=>{
  const items=[
    {...block('list_item',span('Parent ordered')),number:'3',path:'#',depth:1},
    {...block('list_item',span('Nested unordered')),number:'',path:'#*',depth:2},
    {...block('list_item',span('Nested ordered')),number:'3.1',path:'#*#',depth:3},
    {...block('list_detail',span('Parent continuation')),number:'',path:'#:',depth:2},
    {...block('list_item',span('Explicit value')),number:'8',path:'#',depth:1},
    {...block('list_item',span('Following value')),number:'9',path:'#',depth:1}
  ];
  assert.equal(entryClue(entry(...items)),'Parent ordered');
  const value=entry(...items,block('definition',span('Actual dictionary meaning')));
  const original=structuredClone(value);
  assert.equal(entryClue(value),'Actual dictionary meaning');
  assert.deepEqual(value,original);
});
