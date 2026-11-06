// Hand-authored final DPRC wire controls; proposed, not executed.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {decode,buildIndex} from './blob.js';
const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const f=n=>{const b=Buffer.alloc(4);b.writeFloatLE(n);return b;};
const cat=(...v)=>Buffer.concat(v.flatMap(x=>Array.isArray(x)?[Buffer.from(x)]:[x]));
const str=s=>cat(u(Buffer.byteLength(s)),Buffer.from(s));
const len=(unit,value)=>cat([unit],f(value));
const edges=(unit,value)=>cat(...Array.from({length:4},()=>len(unit,value)));
const solid=()=>cat([1],len(0,1),str('#aaaaaa'));
const tableStyle=()=>cat([1,15],str('#f9f9f9'),solid(),[1],edges(0,10));
const cellStyle=()=>cat([1,7],solid(),edges(1,.2),[1]);
function wire({cell=cellStyle(),table=tableStyle(),magic='DPRC'}={}){
 const c=cat([1,1,0,1,0,0],u(0),[0,0],cell);
 const t=cat([1,0],u(0),u(1),u(1),c,table);
 const b=cat([12,0,0],u(0),[0],str(''),str(''),t,str(''),str(''),magic==='DPRE'?[0]:[]);
 const section=cat([2],str('S'),str('S'),str(''),u(1),b);
 return cat(Buffer.from(magic),u(0),u(1),section,u(0),u(0),u(0),u(0),u(0));
}
test('final C typed styles retain units, edges and native JSON union shape',()=>{
 const t=decode(wire(),{}).sections[0].blocks[0].table,c=t.rows[0].cells[0];
 assert.deepEqual(t.style,{background:'#f9f9f9',border:{solid:{width:{unit:'px',value:1},color:'#aaaaaa'}},collapse:'collapse',margins:Object.fromEntries(['top','right','bottom','left'].map(k=>[k,{unit:'px',value:10}]))});
 assert.equal(c.style.text_align,'center');assert.equal(c.style.padding.top.unit,'em');assert.equal(c.style.padding.top.value,Math.fround(.2));
 const zero=decode(wire({cell:cat([1,3,0],edges(1,0)),table:cat([1,4,0])}),{}).sections[0].blocks[0].table;
 assert.deepEqual(zero.rows[0].cells[0].style.border,{none:{}});assert.equal(zero.rows[0].cells[0].style.padding.left.value,0);assert.equal(zero.style.collapse,'separate');
 const max=decode(wire({cell:cat([1,2],edges(1,3.4028234663852886e38)),table:Buffer.from([0])}),{}).sections[0].blocks[0].table;
 assert.equal(max.rows[0].cells[0].style.padding.top.value,3.4028234663852886e38);
});

test('E table float is physical, retains margins and rejects C/D reinterpretation',()=>{
 for(const [side,tag] of [['left',0],['right',1]]){
  const style=cat([1,24],edges(0,20),[tag]);
  const t=decode(wire({magic:'DPRE',table:style}),{}).sections[0].blocks[0].table;
  assert.equal(t.style.float_side,side);assert.equal(t.style.margins.left.value,20);
  for(const magic of ['DPRC','DPRD'])assert.throws(()=>decode(wire({magic,table:style}),{}));
 }
 for(const table of [cat([1,16,2]),cat([1,32,0]),cat([1,16])])assert.throws(()=>decode(wire({magic:'DPRE',table}),{}));
 const project=({presentation_version,...v})=>v;
 assert.deepEqual(project(decode(wire({magic:'DPRE'}),{})),project(decode(wire({magic:'DPRD'}),{})));
});

// Independent recursive E wire, including null and explicit physical alignment.
function alignedWire({alignment=cat([1,1]),nested=false,reference=false,magic='DPRE'}={}){
 const suffix=magic==='DPRE'?alignment:Buffer.alloc(0);
 const paragraph=cat([0,0,0],u(0),[0],str(''),str(''),[0],str(''),str(''),suffix);
 const cell=cat([0,1,0,1,0,0],u(0),[0,1],u(1),paragraph,[0]);
 const table=cat([1,0],u(0),u(1),u(1),cell,[0]);
 const block=nested?cat([12,0,0],u(0),[0],str(''),str(''),table,str(''),str(''),magic==='DPRE'?[0]:[]):paragraph;
 const section=cat([2],str('S'),str('S'),str(''),u(reference?0:1),reference?[]:block);
 const ref=cat([0],u(1),u(1),str(''),str(''),u(0),[1],u(1),block);
 return cat(Buffer.from(magic),u(0),u(1),section,u(0),u(0),u(0),u(reference?1:0),reference?ref:[],u(0));
}
test('E block alignment suffix covers sections, ordered cells and reference blocks',()=>{
 for(const nested of [false,true])for(const reference of [false,true])for(const [tag,side] of [[0,'left'],[1,'center'],[2,'right']]){
  const e=decode(alignedWire({alignment:cat([1,tag]),nested,reference}),{});
  const b=reference?e.references[0].blocks[0]:e.sections[0].blocks[0];
  assert.equal((nested?b.table.rows[0].cells[0].blocks[0]:b).text_align,side);
 }
 const e=decode(alignedWire({alignment:cat([0])}),{});assert.equal(Object.hasOwn(e.sections[0].blocks[0],'text_align'),false);
 for(const alignment of [cat([2]),cat([1,3]),cat([1])])assert.throws(()=>decode(alignedWire({alignment}),{}));
 const old=decode(alignedWire({magic:'DPRD'}),{});assert.equal(Object.hasOwn(old.sections[0].blocks[0],'text_align'),false);
 const bytes=alignedWire();assert.throws(()=>decode(bytes.subarray(0,bytes.length-1),{}));
});

test('normal dictionary index admits actual E header without widening unknown versions',async()=>{
 const payload=alignedWire(),title=Buffer.from('bat\0');
 const vlq=value=>{const bytes=[];do{let b=value&127;value=Math.floor(value/128);if(value)b|=128;bytes.push(b);}while(value);return Buffer.from(bytes);};
 const bytes=cat(Buffer.from('WIKBLB08'),[7],title,vlq(payload.length),payload);
 const source={size:bytes.length,read:async(offset,length)=>bytes.subarray(offset,offset+length)};
 const index=await buildIndex(source);assert.equal(index.rows[0].title,'bat');
 const decoded=decode(await source.read(index.rows[0].offset,index.rows[0].length),index.metadata);assert.equal(decoded.sections[0].blocks[0].text_align,'center');
 const bad=Buffer.from(bytes);bad[index.rows[0].offset+3]='F'.charCodeAt(0);
 await assert.rejects(()=>buildIndex({size:bad.length,read:async(o,n)=>bad.subarray(o,o+n)}));
});

test('E inherits the qualified D image border bit without admitting historical layout bits',()=>{
 const image=flags=>cat([0,0,0],...Array.from({length:7},()=>str('')),[0,0,0,1],str('Icon.svg'),[flags]);
 const payload=(magic,flags)=>cat(Buffer.from(magic),u(1),image(flags),u(0),u(0),u(0),u(0),u(0),u(1),str('Icon.svg'),[0],str(''));
 for(const magic of ['DPRD','DPRE'])assert.deepEqual(decode(payload(magic,16),{}).display_title[0].image,{file:'Icon.svg',border:true});
 assert.throws(()=>decode(payload('DPRC',16),{}));assert.throws(()=>decode(payload('DPRE',32),{}));
});
test('no-style B and final C have equal decoded graphs',()=>{
 const b=decode(wire({magic:'DPRB',cell:Buffer.alloc(0),table:Buffer.alloc(0)}),{});
 const c=decode(wire({cell:Buffer.from([0]),table:Buffer.from([0])}),{});
 const project=({presentation_version,...v})=>v;assert.deepEqual(project(c),project(b));
 assert.equal(Object.hasOwn(c.sections[0].blocks[0].table,'style'),false);
});
test('invalid style framing, enums, RGB and lengths reject',()=>{
 for(const cell of [cat([2]),cat([1,0]),cat([1,8]),cat([1,4,3]),cat([1,1,2]),cat([1,2],edges(2,0)),cat([1,2],edges(1,-1)),cat([1,2],edges(1,NaN)),cat([1,2],edges(1,Infinity))])assert.throws(()=>decode(wire({cell}),{}));
 for(const table of [cat([2]),cat([1,0]),cat([1,16]),cat([1,4,2]),cat([1,1],str('#ABCDEF')),cat([1,2,1],len(0,1),str('red'))])assert.throws(()=>decode(wire({table}),{}));
 const bytes=wire();assert.throws(()=>decode(bytes.subarray(0,bytes.length-1),{}));
});

// Controlled wire only: no native Writer or genuine DE presentation is implied.
function capacityWire({magic='DPRE',count,typed=true,reference=false,audio=0,files=Array.from({length:count},(_,i)=>'Asset '+i+'.svg')}={}){
 const occurrence=file=>cat([1,0,0],str(''),str('File:'+file),...Array.from({length:5},()=>str('')),[0,0,0,1],str(file),[1],u(30));
 const values=typed?cat(u(files.length),...files.map(occurrence)):u(0);
 const ref=reference?cat([0],u(1),u(1),str(''),str(''),values,[0]):Buffer.alloc(0);
 const catalog=cat(u(files.length+audio),...files.map(file=>cat(str(file),[0],str(''))),...Array.from({length:audio},(_,i)=>cat(str('Audio '+i+'.ogg'),[1],str(''))));
 return cat(Buffer.from(magic),reference?u(0):values,u(0),u(0),u(0),u(0),u(reference?1:0),ref,catalog);
}
test('E typed catalog admits256 while C/D retain128 across title and reference sinks',()=>{
 for(const reference of [false,true]){
  for(const magic of ['DPRC','DPRD']){
   assert.equal(decode(capacityWire({magic,count:128,reference}),{}).media.length,128);
   assert.throws(()=>decode(capacityWire({magic,count:129,reference}),{}));
   assert.equal(decode(capacityWire({magic,count:127,audio:1,reference}),{}).media.length,128);
   assert.throws(()=>decode(capacityWire({magic,count:128,audio:1,reference}),{}));
  }
  for(const count of [128,129,193,256]){
   const e=decode(capacityWire({count,reference}),{}),images=reference?e.references[0].spans:e.display_title;
   assert.equal(e.media.length,count);assert.deepEqual(images.map(s=>s.image.file),e.media.map(m=>m.file));
   assert.ok(images.every(s=>s.image.width_px===30&&s.target==='File:'+s.image.file));
  }
  assert.throws(()=>decode(capacityWire({count:257,reference}),{}));
  assert.equal(decode(capacityWire({count:255,audio:1,reference}),{}).media.length,256);
  assert.throws(()=>decode(capacityWire({count:256,audio:1,reference}),{}));
 }
});
test('historical media-only catalogs over256 remain outside typed-occurrence capacity guard',()=>{
 for(const magic of ['DPRB','DPRC','DPRD','DPRE'])assert.equal(decode(capacityWire({magic,count:257,typed:false}),{}).media.length,257);
});
if(process.env.WIKBLB_E_CAPACITY_SOURCE)test('controlled193 flag wire preserves authenticated source identities/order/30px in reference sink',async()=>{
 const bytes=await readFile(process.env.WIKBLB_E_CAPACITY_SOURCE);
 assert.equal(createHash('sha256').update(bytes).digest('hex'),'44e0df97165f226ef55e1f9d631f940cb99b97ce5971ccb2465e31ac1a67bb6c');
 const source=JSON.parse(bytes),items=source.lexical_observation.media;
 assert.equal(source.lexical_observation.distinct_simple_media,193);assert.equal(items.length,193);
 assert.equal(new Set(items.map(item=>item.file)).size,193);
 assert.ok(items.every((item,i)=>item.ordinal===i+1&&item.options==='|30px'));
 // This single reference container is controlled; it does not reconstruct actual DE references/body.
 const expected=items.map(item=>item.file),e=decode(capacityWire({count:193,files:expected,reference:true}),{});
 assert.deepEqual(e.media.map(m=>m.file),expected);assert.deepEqual(e.references[0].spans.map(s=>s.image.file),expected);
 assert.ok(e.references[0].spans.every(s=>s.image.width_px===30&&s.target==='File:'+s.image.file));
});
