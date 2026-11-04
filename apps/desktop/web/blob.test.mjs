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
 const table=value=>{values.push(value.caption||[]);for(const row of value.rows)for(const cell of row.cells){values.push(cell.spans||[]);if(cell.blocks!=null)blocks(cell.blocks);else if(cell.nested_table)table(cell.nested_table);}};
 const blocks=items=>{for(const block of items){values.push(block.spans||[]);if(block.table)table(block.table);}};
 for(const section of entry.sections||[])blocks(section.blocks||[]);
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
 for(const magic of ['DPR1','DPR0','XXXX']){
  const invalid=Buffer.concat([Buffer.from(magic),valid.subarray(4)]);assert.throws(()=>decode(invalid,{}));
  await assert.rejects(()=>buildIndex(new RawSource(new Blob([dictionaryBlob(1,[['Bad',invalid]])]))));
 }
 for(const invalid of [valid.subarray(0,-1),Buffer.concat([valid,Buffer.from([0])]),explanationProtocolFixture('DPR3',{explanation:Buffer.from([0xff])}),explanationProtocolFixture('DPR3',{invalidLength:true})])assert.throws(()=>decode(invalid,{}));
 const tooMany=valid.slice();tooMany.writeUInt32LE(1000001,4);assert.throws(()=>decode(tooMany,{}));
});
test('genuine native abbreviation fixture matches normal CLI JSON for DPR3 annotated and DPR2 plain records',async()=>{
 const root=process.env.WIKBLB_ABBREVIATION_ROOT||'../tests/fixtures/abbreviation-interop';
 // This test intentionally requires the real normal test-bundle output; no synthetic fallback or skip.
 const blob=new Uint8Array(await readFile(path.join(root,'languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb')));
 const source=new RawSource(new Blob([blob])),index=await buildIndex(source);
 const cases=[['Acupuncture abbreviation sample','annotated.export.json','DPR3'],['Legacy format abbreviation control','legacy.export.json','DPR2']];
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

test('DPR7 nested cell preserves authored geometry and empty painted grid',async()=>{
 const u16=n=>Buffer.from([n&255,n>>8]);
 const rgb=color=>color?Buffer.concat([Buffer.from([1]),testString(color)]):Buffer.from([0]);
 const cell=(header,colspan,paint,child)=>Buffer.concat([Buffer.from([header]),u16(colspan),u16(1),rgb(paint),testU32(0),child||Buffer.from([0])]);
 const table=(flags,geometry,rows)=>Buffer.concat([Buffer.from([1,flags]),geometry,testU32(0),testU32(rows.length),...rows.map(cells=>Buffer.concat([testU32(cells.length),...cells]))]);
 const inner=table(13,Buffer.concat([u16(1),u16(2),Buffer.from([1]),testU32(100)]),[[cell(1,5,'#800080')],[...Array.from({length:4},()=>cell(0,1,null))]]);
 const outer=table(3,Buffer.concat([u16(0),u16(15)]),[[...Array.from({length:4},()=>cell(0,1,null,inner))]]);
 const block=Buffer.concat([Buffer.from([12,0,0]),testU32(0),Buffer.from([0]),testString(''),testString(''),outer,testString(''),testString('')]);
 const payload=Buffer.concat([Buffer.from('DPR7'),testU32(0),testU32(1),Buffer.from([1]),testString('Grid'),testString('Grid'),testString(''),testU32(1),block,...Array.from({length:5},()=>testU32(0))]);
 const entry=decode(payload,{}),grid=entry.sections[0].blocks[0].table;
 assert.equal(grid.rows[0].cells.length,4);assert.deepEqual(grid.geometry,{border:0,cell_spacing:15});
 for(const cell of grid.rows[0].cells){assert.equal(cell.spans.length,0);const child=cell.nested_table;assert.deepEqual(child.geometry,{border:1,cell_padding:2,width:{unit:'percent',value:100}});assert.equal(child.rows[0].cells[0].background,'#800080');assert.equal(child.rows[0].cells[0].colspan,5);assert.equal(child.rows[0].cells[0].spans.length,0);}
 const index=await buildIndex(new RawSource(new Blob([dictionaryBlob(1,[['Grid',payload]])])));assert.equal(index.rows.length,1);
 assert.throws(()=>decode(payload.subarray(0,-1),{}));
 const at=payload.indexOf(outer);assert.ok(at>=0);
 const withTable=value=>Buffer.concat([payload.subarray(0,at),value,payload.subarray(at+outer.length)]);
 const unknownGeometry=outer.slice();unknownGeometry[1]=128;assert.throws(()=>decode(withTable(unknownGeometry),{}));
 let deep=table(0,Buffer.alloc(0),[]);
 for(let i=0;i<16;i++)deep=table(0,Buffer.alloc(0),[[cell(0,1,null,deep)]]);
 assert.throws(()=>decode(withTable(deep),{}));
 const badWidth=inner.slice();badWidth[6]=1;badWidth.writeUInt32LE(101,7);
 assert.throws(()=>decode(withTable(table(0,Buffer.alloc(0),[[cell(0,1,null,badWidth)]])),{}));
});

function semanticTableGraph(){
 const spanKeys=['kind','role','text','target','trail','language','classes','direction','explanation','foreground','background','bold','italic','code','small','superscript','subscript','strike','underline'];
 const spans=values=>values.map(span=>Object.fromEntries(spanKeys.map(key=>{
  // Core JSON omits only a null Span.background; the web decoder materializes it.
  if(key==='background'&&!Object.hasOwn(span,key))return [key,null];
  assert.ok(Object.hasOwn(span,key),`Serialized span field missing: ${key}`);return [key,span[key]];
 })));
 const geometry=value=>({border:value?.border??null,cell_spacing:value?.cell_spacing??null,cell_padding:value?.cell_padding??null,width:value?.width??null});
 const table=value=>value==null?null:{geometry:geometry(value.geometry),caption:spans(value.caption),rows:value.rows.map(row=>({cells:row.cells.map(cell=>({header:cell.header,colspan:cell.colspan,rowspan:cell.rowspan,background:cell.background,spans:spans(cell.spans),nested_table:table(cell.nested_table),blocks:cell.blocks==null?null:cell.blocks.map(block)}))}))};
 const block=value=>({kind:value.kind,depth:value.depth,level:value.level,list_path:value.list_path??value.path,number:value.number,feature:value.feature??null,anchor:value.anchor,anchor_fallback:value.anchor_fallback,spans:spans(value.spans),table:table(value.table)});
 return entry=>entry.sections.flatMap((section,section_index)=>section.blocks.flatMap((block,block_index)=>block.table?[{
  section_index,block_index,section:{level:section.level,title:section.title,anchor:section.anchor,anchor_fallback:section.anchor_fallback},
  block:{kind:block.kind,depth:block.depth,level:block.level,list_path:block.list_path??block.path,number:block.number,feature:block.feature??null,anchor:block.anchor,anchor_fallback:block.anchor_fallback,spans:spans(block.spans)},table:table(block.table)
 }]:[]));
}

// Explicit genuine-product conformance target. No fixture fallback or synthetic credit.
if(process.env.WIKBLB_GEACEN_INTEROP==='1')test('genuine native geacen DPR7 matches core full semantic table graph',async()=>{
 assert.ok(process.env.WIKBLB_FIXTURE,'WIKBLB_FIXTURE must name the genuine generated language blob');
 assert.ok(process.env.WIKBLB_GEACEN_EXPORT,'WIKBLB_GEACEN_EXPORT must name qualified core CLI JSON');
 const exported=JSON.parse(await readFile(process.env.WIKBLB_GEACEN_EXPORT,'utf8'));
 assert.equal(exported.schema,'dict.results.v1');assert.equal(exported.entries.length,1);
 const expected=exported.entries[0];assert.equal(expected.title,'geacen');
 const source=new RawSource(new Blob([raw])),index=await buildIndex(source);
 assert.equal(index.metadata.kind,'language');
 const row=index.rows.find(value=>value.title===expected.title);assert.ok(row,'geacen record missing');
 const payload=await source.read(row.offset,row.length);
 assert.equal(new TextDecoder().decode(payload.subarray(0,4)),'DPR7');
 const actual=decode(payload,{...index.metadata,title:row.title});
 assert.equal(actual.language,expected.language);assert.equal(actual.language_code,expected.language_code);
 const graph=semanticTableGraph();
 const actualGraph=graph(actual);assert.deepEqual(actualGraph,graph(expected));
 assert.equal(actualGraph.length,1);assert.deepEqual([actualGraph[0].section_index,actualGraph[0].block_index],[3,0]);
 const grid=actualGraph[0].table;assert.equal(grid.rows.length,1);assert.equal(grid.rows[0].cells.length,4);
 assert.deepEqual(grid.geometry,{border:0,cell_spacing:15,cell_padding:null,width:null});
 let authoredLeafCells=0,painted=0,emptyPainted=0;
 for(const parent of grid.rows[0].cells){
  assert.equal(parent.spans.length,0);const child=parent.nested_table;assert.ok(child);
  assert.deepEqual(child.geometry,{border:1,cell_spacing:null,cell_padding:2,width:{unit:'percent',value:100}});
  assert.deepEqual(child.rows.map(row=>row.cells.length),[1,4,4,4,4,4,4]);
  assert.equal(child.rows[0].cells[0].colspan,5);
  for(const row of child.rows)for(const cell of row.cells){
   authoredLeafCells++;assert.equal(cell.nested_table,null);
   if(cell.background!==null){painted++;if(cell.spans.length===0){emptyPainted++;assert.equal(cell.header,true);assert.equal(cell.background,'#efafef');}}
  }
 }
 assert.equal(authoredLeafCells,100);assert.equal(painted,20);assert.equal(emptyPainted,4);
});

// Hand-encoded DPR8 controls exercise wire boundaries, not compiler acceptance.
for(const magic of ['DPR8','DPR9'])test(`${magic} ordered cells retain complete blocks through raw and DAL1 import`,async()=>{
 const bytes=values=>Buffer.concat(values),zero=()=>testU32(0);
 const span=text=>bytes([Buffer.from([0,0,0]),...[text,'','','','','',''].map(testString),Buffer.from([0,0])]);
 const spans=text=>text==null?zero():bytes([testU32(1),span(text)]);
 const cell=({items=null,text=null,child=null,presence=items==null?0:1}={})=>bytes([Buffer.from([1,1,0,1,0,0]),spans(text),child||Buffer.from([0]),Buffer.from([presence]),...(presence===1?[testU32(items.length),...items]:[])]);
 const table=cells=>bytes([Buffer.from([1,0]),zero(),testU32(1),testU32(cells.length),...cells]);
 const block=(kind,text=null,child=null,anchor='')=>bytes([Buffer.from([kind,2,3]),spans(text),Buffer.from([0]),testString('1'),testString('2'),child||Buffer.from([0]),testString(anchor),testString(anchor?'fallback-'+anchor:'')]);
 const payload=grid=>bytes([Buffer.from(magic),zero(),testU32(1),Buffer.from([2]),testString('Grid'),testString('Grid'),testString(''),testU32(1),block(12,null,grid),...Array.from({length:5},zero)]);
 const items=[block(0,'before'),block(9,'Cell heading',null,'Cell_heading'),block(5,'item'),block(11),block(12,null,table([cell({text:'child'})])),block(0,'after')];
 const valid=payload(table([cell({items}),cell({items:[]}),cell()]));
 const entry=decode(valid,{}),cells=entry.sections[0].blocks[0].table.rows[0].cells;
 assert.deepEqual(cells[0].blocks.map(b=>b.kind),['paragraph','heading','list_item','rule','table','paragraph']);
 assert.deepEqual(cells[0].blocks[1],{kind:'heading',depth:2,level:3,spans:cells[0].blocks[1].spans,path:'1',number:'2',anchor:'Cell_heading',anchor_fallback:'fallback-Cell_heading'});
 assert.equal(cells[0].blocks[1].spans[0].text,'Cell heading');assert.deepEqual(cells[1].blocks,[]);assert.equal(Object.hasOwn(cells[2],'blocks'),false);
 assert.deepEqual(decodeAlias(aliasPayload({compiled:valid}),'1\tCats').entry.sections,entry.sections);
 for(const [kind,rows] of [[1,[['Grid',valid]]],[8,[['1\tCats',aliasPayload({compiled:valid})]]]])assert.equal((await buildIndex(new RawSource(new Blob([dictionaryBlob(kind,rows)])))).rows.length,1);
 for(const invalid of [payload(table([cell({presence:2})])),payload(table([cell({items:[],text:'mixed'})])),payload(table([cell({items:[],child:table([])})])),payload(table([bytes([Buffer.from([0,1,0,1,0,0]),zero(),Buffer.from([0,1]),testU32(1),Buffer.alloc(24)])]))])assert.throws(()=>decode(invalid,{}));
 // Enough physical bytes for every declared block: failure must use the shared collection budget.
 const exhausted=bytes([Buffer.from([0,1,0,1,0,0]),zero(),Buffer.from([0,1]),testU32(1<<20),Buffer.alloc(25*(1<<20))]);
 assert.throws(()=>decode(payload(table([exhausted])),{}));
 for(let end=0;end<valid.length;end++)assert.throws(()=>decode(valid.subarray(0,end),{}));
 let deep=table([]);for(let i=0;i<15;i++)deep=table([cell({items:[block(12,null,deep)]})]);
 assert.doesNotThrow(()=>decode(payload(deep),{}));deep=table([cell({items:[block(12,null,deep)]})]);assert.throws(()=>decode(payload(deep),{}));
});

// Separately opted-in genuine Writer output: synthetic protocol controls earn no credit here.
if(process.env.WIKBLB_CELL_BLOCKS_INTEROP==='1')test('genuine Writer DPR8 ordered cells match normal CLI recursive semantic graph',async()=>{
 assert.ok(process.env.WIKBLB_CELL_BLOCKS_FIXTURE,'WIKBLB_CELL_BLOCKS_FIXTURE must name the genuine generated language blob');
 assert.ok(process.env.WIKBLB_CELL_BLOCKS_EXPORT,'WIKBLB_CELL_BLOCKS_EXPORT must name its qualified normal CLI JSON');
 const exported=JSON.parse(await readFile(process.env.WIKBLB_CELL_BLOCKS_EXPORT,'utf8'));
 assert.equal(exported.schema,'dict.results.v1');assert.equal(exported.entries.length,1);
 const expected=exported.entries[0];assert.equal(expected.title,'cell-heading-regression');
 const fixture=new Uint8Array(await readFile(process.env.WIKBLB_CELL_BLOCKS_FIXTURE));
 const source=new RawSource(new Blob([fixture])),index=await buildIndex(source);
 assert.equal(index.metadata.kind,'language');
 const row=index.rows.find(value=>value.title===expected.title);assert.ok(row,'genuine ordered-cell record missing');
 const payload=await source.read(row.offset,row.length);
 assert.equal(new TextDecoder().decode(payload.subarray(0,4)),'DPR8');
 const actual=decode(payload,{...index.metadata,title:row.title});
 assert.equal(actual.language,expected.language);assert.equal(actual.language_code,expected.language_code);
 const graph=semanticTableGraph(),actualGraph=graph(actual);
 assert.deepEqual(actualGraph,graph(expected));
 assert.equal(actualGraph.length,1);
 let orderedCells=0,orderedBlocks=0;const ordered=[];
 const visitTable=value=>{for(const row of value.rows)for(const cell of row.cells){
  if(cell.blocks!=null){assert.equal(cell.spans.length,0);assert.equal(cell.nested_table,null);orderedCells++;orderedBlocks+=cell.blocks.length;ordered.push(cell);for(const block of cell.blocks)if(block.table)visitTable(block.table);}
  else if(cell.nested_table)visitTable(cell.nested_table);
 }};
 for(const item of actualGraph)visitTable(item.table);
 assert.equal(orderedCells,1,'genuine fixture must contain exactly one authored ordered cell');
 assert.equal(orderedBlocks,7,'genuine fixture must contain the seven authored ordered blocks exactly once');
 const cell=ordered.find(cell=>cell.blocks.some(block=>block.kind==='heading'));assert.ok(cell);
 assert.deepEqual(cell.blocks.map(block=>block.kind),['paragraph','heading','paragraph','list_item','rule','table','paragraph']);
 assert.deepEqual([cell.background,cell.colspan,cell.rowspan],['#ffeecc',2,1]);
 assert.deepEqual([cell.blocks[1].level,cell.blocks[1].anchor,cell.blocks[1].anchor_fallback],[3,'حرف','.D8.AD.D8.B1.D9.81']);
 assert.deepEqual(cell.blocks[5].table.rows.map(row=>row.cells.length),[2]);
 assert.equal(actual.sections.some(section=>section.anchor==='حرف'),false,'cell heading must not become a Section');
 const outside=[...actual.sections,...actual.sections.flatMap(section=>section.blocks)].find(value=>value.anchor==='حرف_2');assert.ok(outside);
 assert.deepEqual([outside.level,outside.anchor_fallback],[3,'.D8.AD.D8.B1.D9.81_2']);
 const actions=[];const visitBlocks=blocks=>{for(const block of blocks){for(const span of block.spans)if(span.kind==='link')actions.push(span.target);if(block.table)for(const row of block.table.rows)for(const cell of row.cells){for(const span of cell.spans)if(span.kind==='link')actions.push(span.target);if(cell.blocks)visitBlocks(cell.blocks);}}};
 visitBlocks(cell.blocks);assert.deepEqual(actions,['Before','Middle','Item','Child','After']);
 assert.equal(cell.blocks[2].spans.find(span=>span.target==='Middle')?.italic,true);
});

// DPR9 fixtures are deliberately hand encoded; genuine producer interoperability
// remains a separate qualification input when that producer is available.
function referenceItemsPayload(items,{magic='DPR9',tagOverride=null,ordinalOverride=null}={}){
 const cat=Buffer.concat,zero=()=>testU32(0);
 const spans=text=>cat([testU32(1),Buffer.from([0,0,2]),...[text,'','','','h-usage-example',''].map(testString),
  ...(magic!=='DPR2'?[testString('')]:[]),...(['DPR4','DPR5','DPR6','DPR7','DPR8','DPR9'].includes(magic)?[Buffer.from([0])]:[]),
  ...(['DPR6','DPR7','DPR8','DPR9'].includes(magic)?[Buffer.from([0])]:[])]);
 const reference=item=>cat([
  ...(magic==='DPR9'?[Buffer.from([tagOverride??(item.kind==='fragment'?1:0)])]:[]),testU32(item.number),
  ...(item.kind==='fragment'?[]:[testU32(ordinalOverride??item.group_number),testString(item.name||'')]),
  testString(item.group||''),spans(item.text)]);
 return cat([Buffer.from(magic),...Array.from({length:5},zero),testU32(items.length),...items.map(reference),zero()]);
}
test('DPR9 mixed reference items retain stable IDs nullable ordinals and body order',async()=>{
 const items=[{kind:'fragment',number:2,group:'note <one>',text:'Fragment café'},
  {number:1,group_number:1,name:'named',group:'note <one>',text:'First note'},
  {number:3,group_number:2,group:'note <one>',text:'Later note'}];
 const payload=referenceItemsPayload(items),entry=decode(payload,{}),refs=entry.references;
 assert.deepEqual(refs.map(({kind='note',number,group_number,name,group})=>({kind,number,group_number,name,group})),[
  {kind:'fragment',number:2,group_number:null,name:'',group:'note <one>'},
  {kind:'note',number:1,group_number:1,name:'named',group:'note <one>'},
  {kind:'note',number:3,group_number:2,name:'',group:'note <one>'}]);
 assert.deepEqual(refs.map(r=>r.spans[0].text),['Fragment café','First note','Later note']);
 assert.ok(refs.every(r=>r.spans[0].italic&&r.spans[0].classes==='h-usage-example'));
 assert.equal(Object.hasOwn(refs[1],'kind'),false);
 assert.deepEqual(decodeAlias(aliasPayload({compiled:payload}),'1\tCats').entry.references,refs);
 const source=new RawSource(new Blob([dictionaryBlob(1,[['References',payload]])]));
 const index=await buildIndex(source);assert.equal(index.rows.length,1);
 assert.deepEqual(decode(await source.read(index.rows[0].offset,index.rows[0].length),{}).references,refs);
 const notes=items.slice(1);
 assert.deepEqual(decode(referenceItemsPayload(notes),{}).references,decode(referenceItemsPayload(notes,{magic:'DPR8'}),{}).references);
 const upper=decode(referenceItemsPayload([{number:0xfffffffe,group_number:0xfffffffe,text:'Upper valid bound'}]),{}).references[0];
 assert.equal(upper.number,0xfffffffe);assert.equal(upper.group_number,0xfffffffe);
 for(const number of [0,0xffffffff])for(const kind of ['note','fragment'])
  assert.throws(()=>decode(referenceItemsPayload([{kind,number,group_number:1,text:'Invalid ID'}]),{}));
 for(const ordinalOverride of [0,0xffffffff])assert.throws(()=>decode(referenceItemsPayload(notes,{ordinalOverride}),{}));
 for(const tagOverride of [2,255])assert.throws(()=>decode(referenceItemsPayload(items,{tagOverride}),{}));
 for(let end=0;end<payload.length;end++)assert.throws(()=>decode(payload.subarray(0,end),{}));
 assert.throws(()=>decode(Buffer.concat([payload,Buffer.from([0])]),{}));
});

test('DPR9 reference contract retains valid legacy notes and rejects reserved legacy indices',()=>{
 for(const magic of ['DPR2','DPR3','DPR4','DPR5','DPR6','DPR7','DPR8']){
  const note={number:0xfffffffe,group_number:0xfffffffe,name:'legacy',group:'g',text:'Legacy boundary'};
  const ref=decode(referenceItemsPayload([note],{magic}),{}).references[0];
  assert.equal(ref.number,0xfffffffe);assert.equal(ref.group_number,0xfffffffe);
  assert.equal(ref.spans[0].text,'Legacy boundary');assert.equal(Object.hasOwn(ref,'kind'),false);
  for(const key of ['number','group_number'])for(const invalid of [0,0xffffffff])
   assert.throws(()=>decode(referenceItemsPayload([{...note,[key]:invalid}],{magic}),{}));
 }
});

if(process.env.WIKBLB_REFERENCE_ITEMS_INTEROP==='1')test('genuine Writer DPR9 reference items match normal CLI and decoded producer bodies',async()=>{
 for(const key of ['WIKBLB_REFERENCE_ITEMS_FIXTURE','WIKBLB_REFERENCE_ITEMS_EXPORT','WIKBLB_REFERENCE_ITEMS_DECODED'])assert.ok(process.env[key],key+' is required');
 const exported=JSON.parse(await readFile(process.env.WIKBLB_REFERENCE_ITEMS_EXPORT,'utf8'));
 const producer=JSON.parse(await readFile(process.env.WIKBLB_REFERENCE_ITEMS_DECODED,'utf8')).entry;
 assert.equal(exported.schema,'dict.results.v1');assert.equal(exported.entries.length,1);
 const expected=exported.entries[0];assert.equal(expected.title,'DPR9 reference fragments');
 const source=new RawSource(new Blob([await readFile(process.env.WIKBLB_REFERENCE_ITEMS_FIXTURE)])),index=await buildIndex(source);
 assert.equal(index.rows.length,1);assert.equal(index.metadata.language,'English');assert.equal(index.metadata.language_code,'en');
 const row=index.rows[0];assert.equal(row.title,expected.title);
 const payload=await source.read(row.offset,row.length);assert.equal(new TextDecoder().decode(payload.subarray(0,4)),'DPR9');
 const actual=decode(payload,{...index.metadata,title:row.title});
 const span=value=>Object.fromEntries([
  ...['kind','role','text','target','trail','language','classes','direction','explanation'].map(k=>[k,value[k]??(k==='role'?'normal':k==='kind'?'text':'')]),
  ...['foreground','background'].map(k=>[k,value[k]??null]),
  ...['bold','italic','code','small','superscript','subscript','strike','underline'].map(k=>[k,!!value[k]])]);
 const refs=entry=>entry.references.map(r=>({kind:r.kind??'note',number:r.number,group_number:r.group_number??null,name:r.name??'',group:r.group??'',spans:r.spans.map(span)}));
 assert.deepEqual(refs(actual),refs(expected));assert.deepEqual(refs(actual),refs(producer));
 assert.deepEqual(actual.media,expected.media);assert.deepEqual(actual.media,producer.media);
 assert.deepEqual(refs(actual).map(r=>[r.kind,r.number,r.group_number,r.name,r.group]),[
  ['fragment',2,null,'','notes'],['note',1,1,'first','notes'],['note',3,2,'later','notes']]);
 assert.ok(actual.references[0].spans.some(s=>s.bold&&s.text.includes('Orphan fragment')));
 assert.ok(actual.references[0].spans.some(s=>s.kind==='link'&&s.target==='Target'&&s.text==='linked label'));
 assert.deepEqual(actual.media.map(m=>[m.file,m.caption]),[['Reference fragment.svg','Fragment media caption']]);
 const targets=actual.sections.flatMap(s=>s.blocks.flatMap(b=>b.spans)).filter(s=>s.kind==='link').map(s=>s.target);
 assert.ok(targets.includes('#reference-1')&&targets.includes('#reference-3'));assert.ok(!targets.includes('#reference-2'));
});

// DPRA wire controls are independent of the native producer interoperability gate.
function fontScalePayload({scale=1.25,presence=1,rawScale=null,magic='DPRA',basis=0}={}){
 const cat=Buffer.concat,zero=()=>testU32(0),string=testString;
 const float=Buffer.alloc(4);float.writeFloatLE(scale);
 const spans=(text='سبتمبر')=>cat([testU32(1),Buffer.from([1,0,3]),...[text,'Target','!','ar','AR','rtl','explanation'].map(string),Buffer.from([1]),string('#123456'),Buffer.from([1]),string('#ffeecc'),Buffer.from([presence]),...(presence===1?[rawScale??float,...(magic==='DPRB'?[Buffer.from([basis])]:[])]:[])]);
 const table=(cells,caption='Caption')=>cat([Buffer.from([1,15]),Buffer.from([2,0,3,0,4,0,1]),testU32(75),spans(caption),testU32(1),testU32(cells.length),...cells]);
 const cell=({child=null,items=null,text=null}={})=>cat([Buffer.from([1,2,0,1,0,1]),string('#ffeecc'),text===null?zero():spans(text),child??Buffer.from([0]),Buffer.from([items===null?0:1]),...(items===null?[]:[testU32(items.length),...items])]);
 const block=(kind=0,grid=null,text='Body')=>cat([Buffer.from([kind,2,3]),text===null?zero():spans(text),Buffer.from([1]),...['feature','ar','data','none',''].map(string),string('1'),string('2'),grid??Buffer.from([0]),string('Heading'),string('Heading_fallback')]);
 const inner=table([cell({text:'Nested cell'})],'Nested caption');
 const grid=table([cell({text:'Cell'}),cell({child:inner}),cell({items:[block(9,null,'Ordered heading'),block(12,inner,null)]})]);
 const section=cat([Buffer.from([2]),string('Section'),string('Section_anchor'),string('Section_fallback'),testU32(1),block(12,grid,null)]);
 const fragment=cat([Buffer.from([1]),testU32(2),string('notes'),spans('Fragment')]);
 const note=cat([Buffer.from([0]),testU32(1),testU32(1),string('named'),string('notes'),spans('Note')]);
 return cat([Buffer.from(magic),spans('Display'),testU32(1),section,spans('Preamble'),zero(),zero(),testU32(2),fragment,note,testU32(1),string('Media.svg'),Buffer.from([0]),string('Media caption')]);
}
test('DPRA font scale survives all recursive containers and retains DPR9 reference fields',async()=>{
 const payload=fontScalePayload(),entry=decode(payload,{title:'Scale'}),lists=presentationSpanLists(entry);
 assert.ok(lists.length>=10);assert.ok(lists.flat().every(span=>span.font_scale===1.25&&span.bold&&span.italic&&span.target==='Target'&&span.trail==='!'&&span.foreground==='#123456'&&span.background==='#ffeecc'));
 assert.equal(entry.presentation_version,'DPRA');assert.deepEqual(entry.references.map(({kind='note',number,group_number,name,group})=>({kind,number,group_number,name,group})),[{kind:'fragment',number:2,group_number:null,name:'',group:'notes'},{kind:'note',number:1,group_number:1,name:'named',group:'notes'}]);
 const table=entry.sections[0].blocks[0].table;assert.deepEqual(table.geometry,{border:2,cell_spacing:3,cell_padding:4,width:{unit:'percent',value:75}});assert.equal(table.rows[0].cells[2].blocks[0].anchor,'Heading');assert.equal(table.rows[0].cells[2].blocks[1].table.rows[0].cells[0].spans[0].text,'Nested cell');
 assert.deepEqual(decodeAlias(aliasPayload({compiled:payload}),'1\tCats').entry.references,entry.references);
 const source=new RawSource(new Blob([dictionaryBlob(1,[['Scale',payload]])]));assert.equal((await buildIndex(source)).rows.length,1);
 const absent=decode(fontScalePayload({presence:0}),{});assert.ok(presentationSpanLists(absent).flat().every(span=>!Object.hasOwn(span,'font_scale')));
 const zero=decode(fontScalePayload({scale:0}),{});assert.ok(presentationSpanLists(zero).flat().every(span=>span.font_scale===0));
 for(const scale of [NaN,Infinity,-Infinity,-1])assert.throws(()=>decode(fontScalePayload({scale}),{}));
 for(const presence of [2,255])assert.throws(()=>decode(fontScalePayload({presence}),{}));
 for(let end=0;end<payload.length;end++)assert.throws(()=>decode(payload.subarray(0,end),{}));
 assert.throws(()=>decode(Buffer.concat([payload,Buffer.from([0])]),{}));
});

test('DPRB retains typed heading size basis and explicit normal body identity recursively',async()=>{
 const payload=fontScalePayload({magic:'DPRB',basis:1,scale:1}),entry=decode(payload,{});
 assert.equal(entry.presentation_version,'DPRB');assert.ok(presentationSpanLists(entry).flat().every(span=>span.font_scale===1&&span.font_scale_basis==='normal_body'));
 assert.deepEqual(entry.references.map(({kind='note',number,group_number,name,group})=>({kind,number,group_number,name,group})),[{kind:'fragment',number:2,group_number:null,name:'',group:'notes'},{kind:'note',number:1,group_number:1,name:'named',group:'notes'}]);
 const context=decode(fontScalePayload({magic:'DPRB',basis:0}),{}),legacy=decode(fontScalePayload(),{});
 context.presentation_version='DPRA';assert.deepEqual(context,legacy);
 const absent=decode(fontScalePayload({magic:'DPRB',presence:0}),{});assert.ok(presentationSpanLists(absent).flat().every(span=>!Object.hasOwn(span,'font_scale')&&!Object.hasOwn(span,'font_scale_basis')));
 const zero=decode(fontScalePayload({magic:'DPRB',basis:1,scale:0}),{});assert.ok(presentationSpanLists(zero).flat().every(span=>span.font_scale===0&&span.font_scale_basis==='normal_body'));
 assert.deepEqual(decodeAlias(aliasPayload({compiled:payload}),'1\tCats').entry.references,entry.references);
 assert.equal((await buildIndex(new RawSource(new Blob([dictionaryBlob(1,[['Basis',payload]])])))).rows.length,1);
 for(const basis of [2,255])assert.throws(()=>decode(fontScalePayload({magic:'DPRB',basis}),{}));
 for(let end=0;end<payload.length;end++)assert.throws(()=>decode(payload.subarray(0,end),{}));
 assert.throws(()=>decode(Buffer.concat([payload,Buffer.from([0])]),{}));
 // An absent-scale DPRB span remains 34 bytes: the extra basis byte is present-only.
 const empty=Buffer.concat([Buffer.from([0,0,0]),...Array.from({length:7},()=>testU32(0)),Buffer.from([0,0,0])]);assert.equal(empty.length,34);
 const scale=Buffer.alloc(4);scale.writeFloatLE(1);const body=Buffer.concat([empty.subarray(0,33),Buffer.from([1]),scale,Buffer.from([1])]);
 const dense=Buffer.concat([Buffer.from('DPRB'),testU32(1025),...Array.from({length:1024},()=>empty),body,...Array.from({length:6},()=>testU32(0))]);
 const denseEntry=decode(dense,{});assert.equal(denseEntry.display_title.length,1025);assert.equal(denseEntry.display_title.at(-1).font_scale_basis,'normal_body');
});

// Optional real-product gate beside the default legacy and hand-framed controls.
// Caller authenticates these retained Writer/Reader inputs; no fixture fallback.
if(process.env.WIKBLB_FONT_BASIS_INTEROP==='1')test('genuine Native90 DPRB matches normal Reader modeled graph and source heading origins',async()=>{
 for(const key of ['WIKBLB_FONT_BASIS_FIXTURE','WIKBLB_FONT_BASIS_EXPORT','WIKBLB_FONT_BASIS_DECODED'])assert.ok(process.env[key],key+' is required');
 const exported=JSON.parse(await readFile(process.env.WIKBLB_FONT_BASIS_EXPORT,'utf8'));
 assert.equal(exported.schema,'dict.results.v1');assert.equal(exported.entries.length,1);
 const expected=exported.entries[0],producer=JSON.parse(await readFile(process.env.WIKBLB_FONT_BASIS_DECODED,'utf8'));
 assert.equal(expected.title,'DPRB font scale basis');assert.equal(producer.title,expected.title);
 const source=new RawSource(new Blob([await readFile(process.env.WIKBLB_FONT_BASIS_FIXTURE)])),index=await buildIndex(source);
 assert.equal(index.metadata.kind,'language');assert.equal(index.metadata.language,'English');assert.equal(index.metadata.language_code,'en');assert.equal(index.rows.length,1);
 const row=index.rows[0];assert.equal(row.title,expected.title);
 const payload=await source.read(row.offset,row.length);assert.equal(new TextDecoder().decode(payload.subarray(0,4)),'DPRB');
 const actual=decode(payload,{...index.metadata,title:row.title});
 const spanKeys=['kind','role','text','target','trail','language','classes','direction','explanation','bold','italic','code','small','superscript','subscript','strike','underline'];
 const spans=values=>values.map(span=>({...Object.fromEntries(spanKeys.map(key=>{
  assert.ok(Object.hasOwn(span,key),'Missing span field '+key);return [key,span[key]];
 })),foreground:span.foreground??null,background:span.background??null,font_scale:span.font_scale??null,font_scale_basis:span.font_scale_basis??'context'}));
 const geometry=value=>value==null?null:{border:value.border??null,cell_spacing:value.cell_spacing??null,cell_padding:value.cell_padding??null,width:value.width??null};
 const table=value=>value==null?null:{geometry:geometry(value.geometry),caption:spans(value.caption),rows:value.rows.map(row=>({cells:row.cells.map(cell=>({header:cell.header,colspan:cell.colspan,rowspan:cell.rowspan,background:cell.background??null,spans:spans(cell.spans),nested_table:table(cell.nested_table),blocks:cell.blocks==null?null:cell.blocks.map(block)}))}))};
 const block=value=>({kind:value.kind,depth:value.depth,level:value.level,list_path:value.list_path??value.path,number:value.number,feature:value.feature??null,anchor:value.anchor,anchor_fallback:value.anchor_fallback,spans:spans(value.spans),table:table(value.table)});
 const graph=value=>({title:value.title,kind:value.kind,language:value.language,language_code:value.language_code,
  display_title:spans(value.display_title),preamble_spans:spans(value.preamble_spans),
  sections:value.sections.map(section=>({level:section.level,title:section.title,anchor:section.anchor,anchor_fallback:section.anchor_fallback,blocks:section.blocks.map(block)})),
  references:value.references.map(ref=>({kind:ref.kind??'note',number:ref.number,group_number:ref.group_number,name:ref.name,group:ref.group,spans:spans(ref.spans)})),media:value.media});
 assert.deepEqual(graph(actual),graph(expected));assert.deepEqual(graph(actual),graph(producer));
 assert.ok(actual.display_title.some(span=>span.text==='DPRB font scale basis'&&span.font_scale===1.25&&(span.font_scale_basis??'context')==='context'));
 const headings=actual.sections.flatMap(section=>section.blocks).filter(block=>block.kind==='heading');
 const heading=(prefix,scale,basis)=>{
  const matches=headings.filter(block=>block.spans.map(span=>span.text+span.trail).join('').startsWith(prefix));assert.equal(matches.length,1,prefix);
  const values=matches[0].spans;assert.ok(values.length>0);assert.ok(values.every(span=>span.font_scale===scale&&(span.font_scale_basis??'context')===basis),prefix);
  return values;
 };
 heading('Normal body heading',1,'normal_body');heading('Context heading',1.25,'context');
 const small=heading('Nested small heading',Math.fround(1.25/1.2),'normal_body');assert.ok(small.every(span=>span.small===false));
 const bodySpans=actual.sections.flatMap(section=>section.blocks.flatMap(block=>block.spans));
 assert.ok(bodySpans.some(span=>span.text.startsWith('Zero text')&&span.font_scale===0&&(span.font_scale_basis??'context')==='context'));
 const actions=[...actual.display_title,...actual.preamble_spans,...bodySpans].filter(span=>span.kind==='link').map(span=>span.target);
 assert.deepEqual(actions,['Target','Target','Target','Target','Target']);
});
