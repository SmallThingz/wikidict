// Hand-authored final DPRC wire controls; proposed, not executed.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {decode,decodeAlias,buildIndex,RawSource} from './blob.js';
import {dictionaryBlob,aliasPayload} from './alias-fixtures.mjs';
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
 const bad=Buffer.from(bytes);bad[index.rows[0].offset+3]='Z'.charCodeAt(0);
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
function capacityWire({magic='DPRE',count,typed=true,reference=false,audio=0,files=Array.from({length:count},(_,i)=>'Asset '+i+'.svg'),widths=files.map(()=>30)}={}){
 const occurrence=(file,i)=>cat([1,0,0],str(''),str('File:'+file),...Array.from({length:5},()=>str('')),[0,0,0,1],str(file),[widths[i]==null?0:1],widths[i]==null?[]:u(widths[i]),(magic==='DPRF'||magic==='DPRG')?[0]:[]);
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

// Independent F framing: component bytes follow the optional image in every sink.
function fragmentWire({magic='DPRF',component='',kind=1,target='Title#literal',text='Label',trail='!',raw=null,image=false}={}){
 const suffix=(magic==='DPRF'||magic==='DPRG')?(raw??(component===null?cat([0]):cat([1],str(component)))):Buffer.alloc(0);
 const occurrence=()=>cat([kind,0,0],str(text),str(target),str(trail),...Array.from({length:4},()=>str('')),[0,0,0],image?cat([1],str('Pixel.svg'),[21],u(15),str('')):cat([0]),suffix);
 const values=()=>cat(u(1),occurrence());
 const paragraph=()=>cat([0,0,0],values(),[0],str(''),str(''),[0],str(''),str(''),[0]);
 const cell=(content,nested=cat([0]),blocks=cat([0]))=>cat([0,1,0,1,0,0],content,nested,blocks,[0]);
 const leaf=cat([1,0],values(),u(1),u(1),cell(values()),[0]);
 const table=cat([1,0],values(),u(1),u(3),cell(values()),cell(u(0),cat([0]),cat([1],u(1),paragraph())),cell(u(0),leaf),[0]);
 const tableBlock=cat([12,0,0],u(0),[0],str(''),str(''),table,str(''),str(''),[0]);
 const section=cat([2],str('S'),str('S'),str(''),u(2),paragraph(),tableBlock);
 const refs=cat(u(2),[0],u(1),u(1),str(''),str(''),values(),[0], [0],u(2),u(2),str(''),str(''),u(0),[1],u(1),paragraph());
 return cat(Buffer.from(magic),values(),u(1),section,values(),u(0),u(0),refs,u(image?1:0),image?cat(str('Pixel.svg'),[0],str('')):[]);
}
function fragmentSpans(entry){
 const out=[],spans=values=>out.push(...values),table=value=>{spans(value.caption);for(const row of value.rows)for(const cell of row.cells){spans(cell.spans);if(cell.blocks)blocks(cell.blocks);if(cell.nested_table)table(cell.nested_table);}},blocks=values=>{for(const b of values){spans(b.spans);if(b.table)table(b.table);}};
 spans(entry.display_title);spans(entry.preamble_spans);for(const section of entry.sections)blocks(section.blocks);for(const ref of entry.references){spans(ref.spans);if(ref.blocks)blocks(ref.blocks);}return out;
}
test('F components preserve literal titles, separate fragments and nullable omission in all recursive sinks',()=>{
 for(const component of ['', 'Part#/%?&Ω']){
  const entry=decode(fragmentWire({component}),{}),spans=fragmentSpans(entry);
  assert.equal(spans.length,10);assert.ok(spans.every(s=>s.target==='Title#literal'&&s.target_fragment===component&&s.text==='Label'&&s.trail==='!'));
 }
 const legacy=decode(fragmentWire({magic:'DPRE',component:null}),{}),f=decode(fragmentWire({component:null}),{}),project=({presentation_version,...v})=>v;
 assert.deepEqual(project(f),project(legacy));assert.ok(fragmentSpans(f).every(s=>!Object.hasOwn(s,'target_fragment')));
 assert.equal(fragmentWire({component:null}).length-fragmentWire({magic:'DPRE',component:null}).length,10);
 const local=decode(fragmentWire({target:'',component:'Local#Ω'}),{});assert.equal(local.display_title[0].target,'');assert.equal(local.display_title[0].target_fragment,'Local#Ω');
 const images=fragmentSpans(decode(fragmentWire({target:'File:Other#literal',component:'',image:true,text:'',trail:''}),{}));
 assert.ok(images.every(s=>s.image.file==='Pixel.svg'&&s.image.width_px===15&&s.image.border===true&&s.image.alt===''&&s.target_fragment===''));
});
test('F refuses malformed component framing, wrong kinds and invalid UTF8 without widening E',()=>{
 for(const kind of [0,2,3])assert.throws(()=>decode(fragmentWire({kind,target:'',component:''}),{}));
 for(const raw of [cat([2]),cat([1],u(33554433)),cat([1],u(1),[0xc3])])assert.throws(()=>decode(fragmentWire({raw}),{}));
 assert.throws(()=>decode(fragmentWire({target:'',component:'local',image:true,text:'',trail:''}),{}));
 const oldHeader=Buffer.from(fragmentWire());oldHeader.write('DPRE');assert.throws(()=>decode(oldHeader,{}));
 const bytes=fragmentWire();assert.throws(()=>decode(bytes.subarray(0,bytes.length-1),{}));
});
test('F reaches normal raw import and DAL1 fallback and inherits E256 image admission',async()=>{
 const wire=fragmentWire(),raw=dictionaryBlob(7,[['Title#literal',wire]]),source=new RawSource(new Blob([raw])),index=await buildIndex(source);
 assert.equal(index.rows[0].title,'Title#literal');const row=index.rows[0];assert.equal(decode(await source.read(row.offset,row.length),index.metadata).display_title[0].target_fragment,'');
 assert.equal(decodeAlias(aliasPayload({source:'Alias',target:'Title#literal',compiled:wire}),'1\tAlias').entry.display_title[0].target_fragment,'');
 for(const reference of [false,true]){assert.equal(decode(capacityWire({magic:'DPRF',count:256,reference}),{}).media.length,256);assert.throws(()=>decode(capacityWire({magic:'DPRF',count:257,reference}),{}));}
 assert.equal(decode(capacityWire({magic:'DPRF',count:257,typed:false}),{}).media.length,257);
});

// G has no media-specific ceiling. These controlled catalogs are not Writer output.
function gBudgetWire(count,{typed=true,wrongKind=false,missing=false,duplicate=false,mixedUnused=false,fillerKind=1}={}){
 const occurrence=cat([1,0,0],str(''),str('File:Owned.svg'),...Array.from({length:5},()=>str('')),[0,0,0,1],str('Owned.svg'),[1],u(30),[1],str(''));
 const first=cat(str(missing?'Other.svg':'Owned.svg'),[wrongKind?1:0],str(''));
 const filler=cat(str(duplicate?'Owned.svg':'Unused.media'),[fillerKind],str(''));
 const rest=Buffer.alloc(Math.max(0,count-1)*filler.length,filler);
 if(mixedUnused&&count>1)rest[str('Unused.media').length]=0;
 return cat(Buffer.from('DPRG'),u(typed?1:0),typed?occurrence:[],u(0),u(0),u(0),u(0),u(0),u(count),count?first:[],rest);
}
test('G retains F components in every sink and admits catalogs beyond E/F256',async()=>{
 for(const reference of [false,true]){
  for(const magic of ['DPRC','DPRD']){assert.equal(decode(capacityWire({magic,count:128,reference}),{}).media.length,128);assert.throws(()=>decode(capacityWire({magic,count:129,reference}),{}));}
  for(const magic of ['DPRE','DPRF']){assert.equal(decode(capacityWire({magic,count:256,reference}),{}).media.length,256);assert.throws(()=>decode(capacityWire({magic,count:257,reference}),{}));}
  for(const count of [257,280,4096])assert.equal(decode(capacityWire({magic:'DPRG',count,reference}),{}).media.length,count);
 }
 const components=fragmentSpans(decode(fragmentWire({magic:'DPRG',component:'Part#/%?&Ω'}),{}));assert.equal(components.length,10);assert.ok(components.every(s=>s.target==='Title#literal'&&s.target_fragment==='Part#/%?&Ω'));
 const repeated=fragmentSpans(decode(fragmentWire({magic:'DPRG',component:'',image:true,target:'File:Other#literal',text:'',trail:''}),{}));assert.equal(repeated.length,10);assert.ok(repeated.every(s=>s.image.file==='Pixel.svg'&&s.image.border===true&&s.target_fragment===''));
 const raw=dictionaryBlob(7,[['G controlled',capacityWire({magic:'DPRG',count:280})]]),source=new RawSource(new Blob([raw])),index=await buildIndex(source),row=index.rows[0];
 assert.equal(decode(await source.read(row.offset,row.length),index.metadata).media.length,280);
 assert.equal(decodeAlias(aliasPayload({source:'Alias',compiled:capacityWire({magic:'DPRG',count:280})}),'1\tAlias').entry.media.length,280);
 for(const magic of ['DPRB','DPRC','DPRD','DPRE','DPRF','DPRG'])assert.equal(decode(capacityWire({magic,count:280,typed:false}),{}).media.length,280);
});
test('G lookup preserves referenced-only identity multiplicity and existing aggregate budget',()=>{
 for(const options of [{wrongKind:true},{missing:true},{duplicate:true},{duplicate:true,fillerKind:0}])assert.throws(()=>decode(gBudgetWire(280,options),{}));
 const unused=decode(gBudgetWire(280,{mixedUnused:true}),{});assert.equal(unused.media.length,280);assert.equal(unused.display_title[0].image.file,'Owned.svg');
 // Compiler max_nodes100000 is not a new consumer catalog ceiling. This model
 // remains under the existing1<<20 aggregate and uses just one typed occurrence.
 assert.equal(decode(gBudgetWire(100001),{}).media.length,100001);
 // Otherwise-valid repeated unreferenced records supply enough bytes for min9.
 // count() must reject before allocating a million catalog objects; its budget
 // has already consumed the title span. No new G-specific numeric limit is used.
 assert.throws(()=>decode(gBudgetWire(1<<20),{}));
 assert.throws(()=>decode(gBudgetWire((1<<20)+1,{typed:false}),{}));
 assert.throws(()=>decode(fragmentWire({magic:'DPRG',kind:0,target:'',component:''}),{}));
 assert.throws(()=>decode(fragmentWire({magic:'DPRG',raw:cat([1],u(33554433))}),{}));
});
if(process.env.WIKBLB_G_CAPACITY_SOURCE)test('controlled LT280 source-first names and explicit widths survive title/reference G catalogs',async()=>{
 const bytes=await readFile(process.env.WIKBLB_G_CAPACITY_SOURCE);assert.equal(createHash('sha256').update(bytes).digest('hex'),'866de9084a53a5f086b8d954c823d2a24ae27be00f813ee104c4024df7b06cab');
 const witness=JSON.parse(bytes),items=witness.media;assert.equal(witness.source.sha256,'32519d0ef559cd1c18f5d41869b2960cfaecfd982609e853a8709c87cd78a453');assert.equal(items.length,280);assert.equal(new Set(items.map(m=>m.file)).size,280);
 // This hand-framed sink arrangement is controlled, not actual LT body/order.
 for(const reference of [false,true]){const expected=items.map(m=>m.file),widths=items.map(m=>m.width_px),entry=decode(capacityWire({magic:'DPRG',count:280,files:expected,widths,reference}),{}),spans=reference?entry.references[0].spans:entry.display_title;
  assert.deepEqual(entry.media.map(m=>m.file),expected);assert.deepEqual(spans.map(s=>s.image.file),expected);assert.deepEqual(spans.map(s=>s.image.width_px??null),widths);assert.ok(spans.every(s=>s.target==='File:'+s.image.file&&s.text===''&&s.trail===''));
 }
});

test('recognized H through M and S headers reject incompatible G bodies; unsupported N through R and T refuse indexing',async()=>{
  // Non-alias indexing checks framing and the format header, not the body. The
  // deferred decoder still requires the actual H/I/J fields in every span/sink.
  for(const magic of ['DPRH','DPRI','DPRJ','DPRK','DPRL','DPRM','DPRS']){
    const bytes=fragmentWire({magic:'DPRG'});Buffer.from(magic).copy(bytes,0);assert.throws(()=>decode(bytes,{}));
    const source=new RawSource(new Blob([dictionaryBlob(7,[['Forged',bytes]])])),index=await buildIndex(source);
    assert.equal(index.rows.length,1);assert.equal(index.rows[0].title,'Forged');
    const row=index.rows[0],indexed=await source.read(row.offset,row.length);assert.deepEqual(Buffer.from(indexed),bytes);assert.throws(()=>decode(indexed,index.metadata));
  }
  for(const version of ['N','O','P','Q','R','T']){
    const bytes=fragmentWire({magic:'DPRG'});Buffer.from('DPR'+version).copy(bytes,0);assert.throws(()=>decode(bytes,{}));
    await assert.rejects(()=>buildIndex(new RawSource(new Blob([dictionaryBlob(7,[['Future',bytes]])]))));
  }
});
