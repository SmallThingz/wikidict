// Source-only proposal: run from the postimage web directory after owner admission.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {decode,buildIndex,RawSource} from './blob.js';
const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const str=s=>{const b=Buffer.from(s);return Buffer.concat([u(b.length),b]);};
const cat=(...b)=>Buffer.concat(b.flatMap(x=>Array.isArray(x)?(x.every(n=>typeof n==='number')?[Buffer.from(x)]:x):[x]));
const span=(s,legacy=false)=>cat([0,0,0],str(s),...Array.from({length:6},()=>str('')),[0,0,0],legacy?[]:[0]);
const spans=(s,legacy=false)=>s==null?u(0):cat(u(1),span(s,legacy));
const block=(table=null)=>cat([table?12:0,0,0],spans(table?null:'Četiri'),[0],str(''),str(''),table?cat([1,0],spans(null),u(1),u(1),[1,1,0,1,0,0],spans(null),[0,1],u(1),block(),[0,0]):[0],str(''),str(''));
const ref=(structured,legacy=null)=>cat([0],u(1),u(1),str(''),str(''),spans(legacy),structured===null?[0]:cat([1],u(structured.length),structured));
const payload=(refs,magic='DPRC')=>cat(Buffer.from(magic),spans(null),u(0),spans(null),u(0),u(0),u(refs.length),refs,u(0));
test('DPRC null, empty and recursive references preserve authoritative mode',()=>{
 const entry=decode(payload([ref(null,'Legacy'),ref([]),ref([block(true)])]),{});
 assert.equal(Object.hasOwn(entry.references[0],'blocks'),false);
 assert.equal(entry.references[0].spans[0].text,'Legacy');
 assert.deepEqual(entry.references[1].blocks,[]);
 assert.deepEqual(entry.references[1].spans,[]);
 assert.equal(entry.references[2].blocks[0].table.rows[0].cells[0].blocks[0].spans[0].text,'Četiri');
 assert.throws(()=>decode(payload([ref([],'Mixed')]),{}));
 const bad=payload([cat([0],u(1),u(1),str(''),str(''),spans(null),[2])]);
 assert.throws(()=>decode(bad,{}));
 const excessive=payload([cat([0],u(1),u(1),str(''),str(''),spans(null),[1],u(0x100001))]);
 assert.throws(()=>decode(excessive,{}));
});
test('DPRB reference framing remains unchanged',()=>{
 const old=cat([0],u(1),u(1),str(''),str(''),spans('Old',true));
 const entry=decode(payload([old],'DPRB'),{});
 assert.equal(entry.references[0].spans[0].text,'Old');
 assert.equal(Object.hasOwn(entry.references[0],'blocks'),false);
});

// Finite generated controls only; no corpus fixture or decoder-derived encoder.
const tableBlock=table=>cat([12,0,0],spans(null),[0],str(''),str(''),[1],table,str(''),str(''));
const tableRows=n=>cat([0],spans(null),u(n),Buffer.alloc(n*4),[0]);
const nestedTable=depth=>cat([0],spans(null),u(1),u(1),[0,1,0,1,0,0],spans(null),depth>1?cat([1],nestedTable(depth-1)):[0],[0,0,0]);
test('DPRC reference tables retain exact depth boundary',()=>{
 assert.equal(decode(payload([ref([tableBlock(nestedTable(16))])]),{}).references[0].blocks.length,1);
 assert.throws(()=>decode(payload([ref([tableBlock(nestedTable(17))])]),{}),/depth/);
});
test('reference table rows share the page item budget across references',()=>{
 // Empty rows cost four wire bytes each. Two individually legal references exceed
 // the shared 2^20 item limit together; the second also has sufficient wire bytes.
 const first=ref([tableBlock(tableRows((1<<20)-8))]);
 const second=ref([tableBlock(tableRows(5))]);
 assert.equal(decode(payload([first]),{}).references.length,1);
 assert.equal(decode(payload([second]),{}).references.length,1);
 assert.throws(()=>decode(payload([first,second]),{}),/Invalid compiled dictionary/);
});
test('same legacy reference wire has equal B/C projected graphs',()=>{
 const legacy=flag=>cat([0],u(1),u(2),str('ime'),str('g'),spans('Četiri',flag));
 const b=decode(payload([legacy(true)],'DPRB'),{});
 const c=decode(payload([cat(legacy(false),[0])]),{});
 assert.deepEqual(c.references,b.references);
 const project=({presentation_version,...entry})=>entry;
 assert.deepEqual(project(c),project(b));
});

// Optional genuine-product parity; caller authenticates all three retained inputs.
// Keep decoded defaults explicit and reject unmodeled fields instead of erasing them.
if(process.env.WIKBLB_C_INTEROP==='1'){
 const keys=(value,allowed)=>{for(const key of Object.keys(value))assert.ok(allowed.includes(key),'Unmodeled field '+key);};
 const nullable=value=>value??null;
 const length=value=>{keys(value,['unit','value']);return {unit:value.unit,value:value.value};};
 const edges=value=>{keys(value,['top','right','bottom','left']);return Object.fromEntries(['top','right','bottom','left'].map(key=>[key,length(value[key])]));};
 const border=value=>{
  keys(value,['none','solid']);assert.equal(Object.keys(value).length,1);
  if(Object.hasOwn(value,'none')){keys(value.none,[]);return {none:{}};}
  keys(value.solid,['width','color']);return {solid:{width:length(value.solid.width),color:value.solid.color}};
 };
 const style=(value,table)=>{
  if(value==null)return null;
  keys(value,table?['background','border','collapse','margins']:['border','padding','text_align']);
  return table?{background:nullable(value.background),border:value.border==null?null:border(value.border),collapse:nullable(value.collapse),margins:value.margins==null?null:edges(value.margins)}:
   {border:value.border==null?null:border(value.border),padding:value.padding==null?null:edges(value.padding),text_align:nullable(value.text_align)};
 };
 const image=value=>{
  if(value==null)return null;keys(value,['file','width_px','height_px','alt','tooltip']);
  return {file:value.file,width_px:nullable(value.width_px),height_px:nullable(value.height_px),alt:nullable(value.alt),tooltip:nullable(value.tooltip)};
 };
 const spanFields=['kind','role','text','target','trail','language','classes','direction','explanation','bold','italic','code','small','superscript','subscript','strike','underline'];
 const spans=values=>values.map(value=>{
  keys(value,[...spanFields,'foreground','background','font_scale','font_scale_basis','image']);
  return {...Object.fromEntries(spanFields.map(key=>{assert.ok(Object.hasOwn(value,key),'Missing span field '+key);return [key,value[key]];})),foreground:nullable(value.foreground),background:nullable(value.background),font_scale:nullable(value.font_scale),font_scale_basis:value.font_scale_basis??'context',image:image(value.image)};
 });
 const geometry=value=>{if(value==null)return null;keys(value,['border','cell_spacing','cell_padding','width']);return {border:nullable(value.border),cell_spacing:nullable(value.cell_spacing),cell_padding:nullable(value.cell_padding),width:nullable(value.width)};};
 const feature=value=>{if(value==null)return null;keys(value,['kind','language','data','tail_kind','tail']);return {kind:value.kind,language:value.language,data:value.data,tail_kind:value.tail_kind,tail:value.tail};};
 const table=value=>{
  if(value==null)return null;keys(value,['geometry','style','caption','rows']);
  return {geometry:geometry(value.geometry),style:style(value.style,true),caption:spans(value.caption),rows:value.rows.map(row=>{keys(row,['cells']);return {cells:row.cells.map(cell=>{
   keys(cell,['header','colspan','rowspan','background','spans','nested_table','blocks','style']);
   return {header:cell.header,colspan:cell.colspan,rowspan:cell.rowspan,background:nullable(cell.background),spans:spans(cell.spans),nested_table:table(cell.nested_table),blocks:cell.blocks==null?null:cell.blocks.map(block),style:style(cell.style,false)};
  })};})};
 };
 const block=value=>{
  keys(value,['kind','depth','level','spans','feature','list_path','path','number','table','anchor','anchor_fallback']);
  return {kind:value.kind,depth:value.depth,level:value.level,spans:spans(value.spans),feature:feature(value.feature),list_path:value.list_path??value.path,number:value.number,table:table(value.table),anchor:value.anchor,anchor_fallback:value.anchor_fallback};
 };
 const graph=value=>{
  keys(value,['organization','alias','redirect','presentation_version','title','kind','language','language_code','display_title','preamble_spans','sections','references','media']);
  // These blobs have no aliases/redirects; silently discarding a populated one is invalid.
  assert.equal(value.alias??null,null);assert.equal(value.redirect??null,null);
  return {title:value.title,kind:value.kind,language:value.language,language_code:value.language_code,display_title:spans(value.display_title),preamble_spans:spans(value.preamble_spans),sections:value.sections.map(section=>{
   keys(section,['level','title','anchor','anchor_fallback','blocks']);return {level:section.level,title:section.title,anchor:section.anchor,anchor_fallback:section.anchor_fallback,blocks:section.blocks.map(block)};
  }),references:value.references.map(ref=>{
   keys(ref,['kind','number','group_number','name','group','spans','blocks']);return {kind:ref.kind??'note',number:ref.number,group_number:ref.group_number,name:ref.name,group:ref.group,spans:spans(ref.spans),blocks:ref.blocks==null?null:ref.blocks.map(block)};
  }),media:value.media.map(media=>{keys(media,['file','kind','caption']);return {file:media.file,kind:media.kind,caption:media.caption};})};
 };
 for(const edition of ['HE','HR'])test('genuine '+edition+' DPRC matches complete Stored and normal Reader modeled graph',async()=>{
  const env=field=>{const key='WIKBLB_C_'+edition+'_'+field;assert.ok(process.env[key],key+' is required');return process.env[key];};
  const stored=JSON.parse(await readFile(env('STORED'),'utf8')),reader=JSON.parse(await readFile(env('READER'),'utf8'));
  assert.equal(stored.schema,'wikidict.captured-current-stored.v1');assert.equal(stored.full_export,true);assert.equal(stored.codec_roundtrip,true);assert.equal(stored.records.length,1);
  assert.equal(stored.records[0].stored.schema,'dict.presentation.v3');assert.equal(reader.schema,'dict.results.v1');assert.equal(reader.entries.length,1);
  const expected=stored.records[0].stored.entry;assert.deepEqual(reader.entries[0],expected);
  const source=new RawSource(new Blob([await readFile(env('FIXTURE'))])),index=await buildIndex(source);assert.equal(index.rows.length,1);assert.equal(index.rows[0].title,expected.title);
  const row=index.rows[0],wire=await source.read(row.offset,row.length);assert.equal(new TextDecoder().decode(wire.subarray(0,4)),'DPRC');
  const actual=decode(wire,{...index.metadata,title:row.title});assert.deepEqual(graph(actual),graph(expected));assert.deepEqual(graph(actual),graph(reader.entries[0]));
 });
}
