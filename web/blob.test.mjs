import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {buildIndex,decode,decodeAlias,RawSource} from './blob.js';
import {aliasPayload,dictionaryBlob} from './alias-fixtures.mjs';
import path from 'node:path';
import {openSource} from './xz.js';
const fixture=process.env.WIKBLB_FIXTURE || '../tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb';
const raw=new Uint8Array(await readFile(fixture));
test('binary and seekable multiblock XZ produce identical records',async()=>{
 const encoded=execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
 const a=new RawSource(new Blob([raw])),b=await openSource(new Blob([encoded]));
 assert.equal(b.size,raw.length);assert.ok(b.blocks.length>2);
 const index=await buildIndex(a),compressed=await buildIndex(b);assert.deepEqual(compressed,index);
 for(const row of index.rows){
  const left=decode(await a.read(row.offset,row.length),{...index.metadata,title:row.title});
  const right=decode(await b.read(row.offset,row.length),{...index.metadata,title:row.title});
  assert.deepEqual(right,left);
 }
 assert.ok(index.rows.some(x=>x.title==='cat'));
 for(const offset of [0,65530,131068,raw.length-12])assert.deepEqual(await b.read(offset,12),raw.slice(offset,offset+12));
});
test('concatenated streams and damaged framing',async()=>{
 const first=execFileSync('xz',['-1','-c'],{input:raw.slice(0,100000)}),second=execFileSync('xz',['-1','-c'],{input:raw.slice(100000)});
 const source=await openSource(new Blob([first,new Uint8Array(4),second]));
 assert.deepEqual(await source.read(99990,20),raw.slice(99990,100010));
 await assert.rejects(()=>openSource(new Blob([first.slice(0,-2)])));
 await assert.rejects(()=>buildIndex(new RawSource(new Blob([raw.slice(0,-1)]))));
 assert.throws(()=>decode(new Uint8Array([68,80,82,50]),{}));
 const corrupt=first.slice();corrupt[40]^=32;
 await assert.rejects(async()=>{const x=await openSource(new Blob([corrupt]));await x.read(0,x.size);});
});

test('supplemental namespaces preserve full Unicode titles in raw and XZ',async()=>{
 const raw=new Uint8Array(await readFile('../tests/fixtures/supplemental.wikblb'));
 const packed=execFileSync('xz',['-1','-c'],{input:raw});
 const sources=[new RawSource(new Blob([raw])),await openSource(new Blob([packed]))];
 const indexes=await Promise.all(sources.map(buildIndex));
 assert.deepEqual(indexes[0],indexes[1]);
 assert.equal(indexes[0].metadata.kind,'supplemental');
 assert.equal(indexes[0].metadata.language_code,'');
 assert.equal(indexes[0].metadata.language,null);
 assert.deepEqual(indexes[0].rows.map(x=>x.title),['Annexe:école','Appendix:école']);
 for(const row of indexes[0].rows){
  const entries=await Promise.all(sources.map(async source=>decode(await source.read(row.offset,row.length),{...indexes[0].metadata,title:row.title})));
  assert.deepEqual(entries[0],entries[1]);
  assert.equal(entries[0].title,row.title);
  assert.equal(entries[0].sections[0].blocks[0].spans[0].text,row.title);
 }
 for(const tag of [0,8,255]){const corrupt=raw.slice();corrupt[8]=tag;await assert.rejects(()=>buildIndex(new RawSource(new Blob([corrupt]))));}
});

// Hand-encoded protocol controls; these do not stand in for the native fixture.
const testU32=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const testString=value=>{const b=Buffer.isBuffer(value)?value:Buffer.from(value);return Buffer.concat([testU32(b.length),b]);};
function explanationProtocolFixture(magic,{explanation='meaning',invalidLength=false,classes='Latn',blockKind=12,blockLevel=0,foreground=null,background=null,spanBackground=null,backgroundPresence=null,foregroundPresence=null,anchor='Usage_notes_2',anchorFallback='Usage.20notes_2',sectionAnchor='English_2',sectionFallback='English.202'}={}){
 const string=testString;
 const rgb=value=>value===null?Buffer.from([0]):Buffer.concat([Buffer.from([1]),string(value)]);
 const span=text=>Buffer.concat([Buffer.from([1,0,1]),...[text,'Target','!','en',classes,'ltr'].map(string),...(magic!=='DPR2'?[invalidLength?Buffer.concat([testU32(32*1024*1024+1),Buffer.from('x')]):string(explanation)]:[]),...((magic==='DPR4'||magic==='DPR5'||magic==='DPR6')?[foregroundPresence===null?rgb(foreground):Buffer.from([foregroundPresence])]:[]),...(magic==='DPR6'?[backgroundPresence===null?rgb(spanBackground):Buffer.from([backgroundPresence])]:[])]);
 const spans=text=>Buffer.concat([testU32(1),span(text)]);
 const cell=Buffer.concat([Buffer.from([0,1,0,1,0]),...((magic==='DPR4'||magic==='DPR5'||magic==='DPR6')?[rgb(background)]:[]),spans('Cell')]);
 const table=Buffer.concat([spans('Caption'),testU32(1),testU32(1),cell]);
 const block=Buffer.concat([Buffer.from([blockKind,0,blockLevel]),spans('Body'),Buffer.from([0]),string(''),string(''),Buffer.from([1]),table,...((magic==='DPR5'||magic==='DPR6')?[string(anchor),string(anchorFallback)]:[])]);
 const section=Buffer.concat([Buffer.from([2]),string('Section'),...((magic==='DPR5'||magic==='DPR6')?[string(sectionAnchor),string(sectionFallback)]:[]),testU32(1),block]);
 const reference=Buffer.concat([testU32(1),testU32(1),string(''),string(''),spans('Reference')]);
 return Buffer.concat([Buffer.from(magic),spans('Display'),testU32(1),section,spans('Preamble'),testU32(0),testU32(0),testU32(1),reference,testU32(0)]);
}
function presentationSpanLists(entry){
 const values=[entry.display_title||[],entry.preamble_spans||[]];
 for(const section of entry.sections||[])for(const block of section.blocks||[]){
  values.push(block.spans||[]);
  if(block.table){values.push(block.table.caption||[]);for(const row of block.table.rows)for(const cell of row.cells)values.push(cell.spans||[]);}
 }
 for(const reference of entry.references||[])values.push(reference.spans||[]);
 return values;
}
const normalizedSpan=span=>Object.fromEntries([
 ['kind',span.kind||'text'],['role',span.role||'normal'],
 ...['text','target','trail','language','classes','direction','explanation'].map(key=>[key,span[key]||'']),
 ...['bold','italic','code','small','superscript','subscript','strike','underline'].map(key=>[key,!!span[key]])
]);
test('DPR2 and DPR3 use strict version framing in every serialized span container',async()=>{
 for(const magic of ['DPR2','DPR3']){
  const payload=explanationProtocolFixture(magic),entry=decode(payload,{title:'Protocol'}),lists=presentationSpanLists(entry);
  assert.equal(lists.length,6);
  for(const values of lists){assert.equal(values.length,1);assert.equal(values[0].explanation,magic==='DPR3'?'meaning':'');assert.equal(values[0].target,'Target');assert.equal(values[0].classes,'Latn');assert.equal(values[0].bold,true);}
  const bytes=dictionaryBlob(1,[['Protocol',payload]]),index=await buildIndex(new RawSource(new Blob([bytes])));
  assert.equal(index.rows.length,1);
  const nested=decodeAlias(aliasPayload({compiled:payload}),'1\tCats');assert.equal(nested.entry.display_title[0].explanation,magic==='DPR3'?'meaning':'');
 }
 const legacy=Buffer.concat([Buffer.from('DPR2'),testU32(8),...Array.from({length:8},()=>Buffer.concat([Buffer.alloc(3),...Array.from({length:6},()=>testU32(0))])),...Array.from({length:6},()=>testU32(0))]);
 assert.equal(legacy.length,248);assert.equal(decode(legacy,{}).display_title.length,8);
 const heading=decode(explanationProtocolFixture('DPR3',{blockKind:9,blockLevel:2}),{}).sections[0].blocks[0];
 assert.equal(heading.kind,'heading');assert.equal(heading.level,2);
 assert.throws(()=>decode(Buffer.concat([Buffer.from('DPR3'),legacy.subarray(4)]),{}));
});
test('DPR3 refuses unknown versions incomplete strings UTF8 limits and trailing bytes',async()=>{
 const valid=explanationProtocolFixture('DPR3');
 for(const magic of ['DPR1','DPR7','XXXX']){
  const invalid=Buffer.concat([Buffer.from(magic),valid.subarray(4)]);assert.throws(()=>decode(invalid,{}));
  await assert.rejects(()=>buildIndex(new RawSource(new Blob([dictionaryBlob(1,[['Bad',invalid]])]))));
 }
 for(const invalid of [valid.subarray(0,-1),Buffer.concat([valid,Buffer.from([0])]),explanationProtocolFixture('DPR3',{explanation:Buffer.from([0xff])}),explanationProtocolFixture('DPR3',{invalidLength:true})])assert.throws(()=>decode(invalid,{}));
 const tooMany=valid.slice();tooMany.writeUInt32LE(1000001,4);assert.throws(()=>decode(tooMany,{}));
});
test('genuine native abbreviation fixture matches normal CLI JSON for DPR5 annotated and plain records',async()=>{
 const root=process.env.WIKBLB_ABBREVIATION_ROOT||'../tests/fixtures/abbreviation-interop';
 // This test intentionally requires the real normal test-bundle output; no synthetic fallback or skip.
 const blob=new Uint8Array(await readFile(path.join(root,'languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb')));
 const source=new RawSource(new Blob([blob])),index=await buildIndex(source);
 const cases=[['Acupuncture abbreviation sample','annotated.export.json','DPR5'],['Legacy format abbreviation control','legacy.export.json','DPR5']];
 for(const [title,jsonName,magic] of cases){
  const row=index.rows.find(row=>row.title===title);assert.ok(row,title);
  const payload=await source.read(row.offset,row.length);assert.equal(new TextDecoder().decode(payload.subarray(0,4)),magic);
  const actual=decode(payload,{...index.metadata,title});
  const exported=JSON.parse(await readFile(path.join(root,jsonName),'utf8'));assert.equal(exported.schema,'dict.results.v1');assert.equal(exported.entries.length,1);
  const expected=exported.entries[0];assert.equal(actual.title,expected.title);assert.equal(actual.language,expected.language);
  assert.deepEqual(actual.sections.map(s=>[s.level,s.title,s.blocks.map(b=>b.kind)]),expected.sections.map(s=>[s.level,s.title,s.blocks.map(b=>b.kind)]));
  assert.deepEqual(presentationSpanLists(actual).map(v=>v.map(normalizedSpan)),presentationSpanLists(expected).map(v=>v.map(normalizedSpan)));
  const spans=presentationSpanLists(actual).flat();
  assert.deepEqual(actual.sections.map(s=>[s.anchor,s.anchor_fallback,s.blocks.map(b=>[b.anchor,b.anchor_fallback])]),expected.sections.map(s=>[s.anchor,s.anchor_fallback,s.blocks.map(b=>[b.anchor,b.anchor_fallback])]));
  if(title==='Acupuncture abbreviation sample'){
   assert.deepEqual([...new Set(spans.map(s=>s.explanation).filter(Boolean))],['derived terms','uncertain','learned borrowing','feminine gender','common gender','masculine gender','neuter gender']);
   assert.deepEqual(spans.filter(s=>s.kind==='link').map(s=>s.target),['Appendix:Glossary#derived terms','Appendix:Glossary#learned borrowing']);
   assert.equal(actual.sections.flatMap(s=>s.blocks).flatMap(b=>b.spans).map(s=>s.text+s.trail).join(''),'der. ? lbor. f c m n');
  }else assert.ok(spans.every(s=>s.explanation===''));
 }
});

test('DPR4 preserves RGB and explanations in all containers and nested aliases beside legacy versions',async()=>{
 for(const magic of ['DPR2','DPR3','DPR4']){
  const payload=explanationProtocolFixture(magic,{foreground:'#01796f',background:'#eeeeee'}),entry=decode(payload,{title:'RGB'});
  for(const list of presentationSpanLists(entry))for(const span of list){assert.equal(span.foreground,magic==='DPR4'?'#01796f':null);assert.equal(span.explanation,magic==='DPR2'?'':'meaning');assert.equal(span.target,'Target');assert.equal(span.bold,true);}
  assert.equal(entry.sections[0].blocks[0].table.rows[0].cells[0].background,magic==='DPR4'?'#eeeeee':null);
  assert.deepEqual(decodeAlias(aliasPayload({compiled:payload}),'1\tCats').entry.display_title,entry.display_title);
  const index=await buildIndex(new RawSource(new Blob([dictionaryBlob(1,[['RGB',payload]])])));assert.equal(index.rows.length,1);
 }
 const uncolored=decode(explanationProtocolFixture('DPR4'),{});assert.equal(uncolored.display_title[0].foreground,null);assert.equal(uncolored.sections[0].blocks[0].table.rows[0].cells[0].background,null);
 for(const value of ['#ABCDEF','#abc','red','#01796f\n']){assert.throws(()=>decode(explanationProtocolFixture('DPR4',{foreground:value}),{}));assert.throws(()=>decode(explanationProtocolFixture('DPR4',{background:value}),{}));}
 assert.throws(()=>decode(explanationProtocolFixture('DPR4',{foregroundPresence:2}),{}));
 const valid=explanationProtocolFixture('DPR4',{foreground:'#01796f',background:'#eeeeee'});assert.throws(()=>decode(valid.subarray(0,-1),{}));assert.throws(()=>decode(Buffer.concat([valid,Buffer.from([0])]),{}));
});

test('DPR5 preserves primary and fallback anchors with DPR4 rich fields and nested aliases',async()=>{
 const payload=explanationProtocolFixture('DPR5',{blockKind:9,blockLevel:3,foreground:'#01796f',background:'#eeeeee'});
 const entry=decode(payload,{title:'Anchored'}),section=entry.sections[0],heading=section.blocks[0];
 assert.deepEqual([section.anchor,section.anchor_fallback,heading.anchor,heading.anchor_fallback],['English_2','English.202','Usage_notes_2','Usage.20notes_2']);
 assert.equal(entry.presentation_version,'DPR5');assert.equal(heading.kind,'heading');assert.equal(heading.level,3);
 for(const spans of presentationSpanLists(entry))for(const span of spans){assert.equal(span.foreground,'#01796f');assert.equal(span.explanation,'meaning');}
 assert.equal(heading.table.rows[0].cells[0].background,'#eeeeee');
 assert.deepEqual(decodeAlias(aliasPayload({compiled:payload}),'1\tCats').entry.sections,entry.sections);
 for(const [kind,rows] of [[1,[['Anchored',payload]]],[8,[['1\tCats',aliasPayload({compiled:payload})]]]]){
  const index=await buildIndex(new RawSource(new Blob([dictionaryBlob(kind,rows)])));assert.equal(index.rows.length,1);
 }
 const fallback=decode(explanationProtocolFixture('DPR5',{blockKind:9,anchor:'',sectionAnchor:''}),{}).sections[0];
 assert.deepEqual([fallback.anchor,fallback.anchor_fallback,fallback.blocks[0].anchor,fallback.blocks[0].anchor_fallback],['','English.202','','Usage.20notes_2']);
 for(const magic of ['DPR2','DPR3','DPR4']){
  const legacyEntry=decode(explanationProtocolFixture(magic),{}),legacy=legacyEntry.sections[0];assert.equal(legacyEntry.presentation_version,magic);
  assert.deepEqual([legacy.anchor,legacy.anchor_fallback,legacy.blocks[0].anchor,legacy.blocks[0].anchor_fallback],['','','','']);
 }
});
test('DPR5 rejects truncated boundaries invalid anchor UTF8 lengths and trailing data',()=>{
 const valid=explanationProtocolFixture('DPR5',{blockKind:9});
 for(let end=0;end<valid.length;end++)assert.throws(()=>decode(valid.subarray(0,end),{}));
 assert.throws(()=>decode(Buffer.concat([valid,Buffer.from([0])]),{}));
 for(const field of ['anchor','anchorFallback','sectionAnchor','sectionFallback'])assert.throws(()=>decode(explanationProtocolFixture('DPR5',{[field]:Buffer.from([0xff])}),{}));
 for(const anchor of ['English_2','English.202','Usage_notes_2','Usage.20notes_2']){
  const invalid=Buffer.from(valid),at=invalid.indexOf(anchor);assert.ok(at>4);invalid.writeUInt32LE(32*1024*1024+1,at-4);assert.throws(()=>decode(invalid,{}));
 }
});


test('DPR6 span paint preserves every container, anchors and strict RGB framing',async()=>{
 const payload=explanationProtocolFixture('DPR6',{foreground:'#01796f',background:'#fffdd0',spanBackground:'#ffffe0'});
 const entry=decode(payload,{title:'Paint'});
 const nested=decodeAlias(aliasPayload({compiled:payload}),'1	Cats');
 assert.equal(nested.entry.display_title[0].background,'#ffffe0');
 assert.equal(entry.presentation_version,'DPR6');
 for(const list of presentationSpanLists(entry))for(const span of list){assert.equal(span.background,'#ffffe0');assert.equal(span.foreground,'#01796f');assert.equal(span.trail,'!');}
 assert.equal(entry.sections[0].anchor,'English_2');
 assert.equal(entry.sections[0].blocks[0].anchor,'Usage_notes_2');
 assert.equal(entry.sections[0].blocks[0].table.rows[0].cells[0].background,'#fffdd0');
 for(const magic of ['DPR2','DPR3','DPR4','DPR5'])for(const list of presentationSpanLists(decode(explanationProtocolFixture(magic),{})))for(const span of list)assert.equal(span.background,null);
 for(const value of ['#ABCDEF','#abc','red','#ffffe0\n'])assert.throws(()=>decode(explanationProtocolFixture('DPR6',{spanBackground:value}),{}));
 assert.throws(()=>decode(explanationProtocolFixture('DPR6',{backgroundPresence:2}),{}));
 assert.throws(()=>decode(payload.subarray(0,-1),{}));
 assert.throws(()=>decode(Buffer.concat([payload,Buffer.from([0])]),{}));
 const variable=n=>{const bytes=[];do{let b=n&127;n=Math.floor(n/128);if(n)b|=128;bytes.push(b);}while(n);return Buffer.from(bytes);};
 const raw=Buffer.concat([Buffer.from('WIKBLB08'),Buffer.from([1]),Buffer.from('en\0English\0Paint\0'),variable(payload.length),payload]);
 const index=await buildIndex(new RawSource(new Blob([raw])));assert.equal(index.rows[0].title,'Paint');
});
