// Hand-framed boundary controls; genuine Writer/Reader fixtures remain independent.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {decode,buildIndex,RawSource} from './blob.js';
import {validateContainerBlock,validateContainerStyle} from './validate.js';
const cat=(...parts)=>Buffer.concat(parts.map(x=>Array.isArray(x)?Buffer.from(x):x));
const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const short=n=>Buffer.from([n&255,n>>8]);
const f=n=>{const b=Buffer.alloc(4);b.writeFloatLE(n);return b;};
const d=n=>{const b=Buffer.alloc(8);b.writeDoubleLE(n);return b;};
const s=x=>cat(u(Buffer.byteLength(x)),Buffer.from(x));
const list=values=>cat(u(values.length),...values);
const length=(value=0,unit=0)=>cat([unit],f(value));
const edges=()=>cat(...Array.from({length:4},()=>length()));
const textSpan=(version,{text='body',tooltip=null,image=null,target='',fragment=null,scale=null,basis=0}={})=>cat([image?1:0,0,0],s(image?'':text),s(image?target||'File:Map.svg':target),s(''),s(''),s(''),s(''),s(''),[0,0,scale===null?0:1],scale===null?[]:cat(f(scale),[basis]),image?cat([1],s('Map.svg'),[image.flags??(image.map?33:1)],u(120),image.map||[],image.afterMap||[]):[0],[fragment===null?0:1],fragment===null?[]:s(fragment),version>='H'?cat([tooltip===null?0:1],tooltip===null?[]:s(tooltip)):[]);
const block=(version,{values=[],table=null,style=null,figure=null,flow=null,container=null,kind=container?13:table?12:0}={})=>cat([kind,0,0],list(values),[0],s(''),s(''),table||[0],s(''),s(''),version>='E'?[0]:[],version>='I'?(style||[0]):[],version>='J'?(figure||[0]):[],version>='J'?(flow?cat([1],flow):[0]):[],container||[]);
const table=(version,{style=[0],caption=[],captionBlocks=null,cells=[]}={})=>cat([1,0],list(caption),list(cells.length?[cat(list(cells))]:[]),style,version>='J'?(captionBlocks?cat([1],list(captionBlocks)):[0]):[]);
const cell=(version,blocks)=>cat([0,1,0,1,0,0],u(0),[0,1],list(blocks),[0]);
const figure=(version,options={})=>cat([1,0,2,0],edges(),edges(),edges(),f(.884),length(1.2376,1),[0,0,0,0,0,0],textSpan(version,{image:{},target:'File:Map.svg'}),u(0),[1],list([block(version,{values:[textSpan(version,{text:'caption',tooltip:''})]})]),[0,2,0]);
const wire=(version,body,{media=false,reference=[],lexemes=[]}={})=>cat(Buffer.from('DPR'+version),u(0),u(1),[2],s('S'),s('S'),s(''),list(body),u(0),list(lexemes),u(0),list(reference),media?cat(u(1),s('Map.svg'),[0],s('')):u(0));
const map=({shape=0,coordinates=[0,0,120,40],kind=0,target='Target',fragment='',description=1}={})=>cat([description],u(1),[shape],list(coordinates.map(d)),[kind],s(target),[fragment===null?0:1],fragment===null?[]:s(fragment),s('label'),[0]);
const kStyle=({flags=0,extra=7,display=1,align=1,line=1.2,basis=1}={})=>cat([1,flags,extra],extra&1?[display]:[],extra&2?[align]:[],extra&4?cat(f(line),[basis]):[]);

test('H tooltip null and empty survive independently of image tooltip',()=>{
 const spans=[textSpan('H',{text:'absent'}),textSpan('H',{text:'empty',tooltip:''}),textSpan('H',{text:'advice',tooltip:'tip'})];
 assert.deepEqual(decode(wire('H',[block('H',{values:spans})]),{}).sections[0].blocks[0].spans.map(x=>x.tooltip),[null,'','tip']);
});
test('I block geometry preserves fractional independent edges and rejects mixed table context',()=>{
 const style=cat([1,3],edges(),cat(length(1.2,1),length(0),length(2),length(3)));
 const value=decode(wire('I',[block('I',{style})]),{}).sections[0].blocks[0];
 assert.equal(value.style.padding.top.value,Math.fround(1.2));assert.equal(value.style.padding.top.unit,'em');
 assert.throws(()=>decode(wire('I',[block('I',{style,table:table('I')})]),{}));
});
test('J preserves rich captions scopes maps and image catalogue identity',()=>{
 const inline=cat([0],list([textSpan('J',{text:'inside'})]));
 const scope=cat([2,0,3,1,1],s('ar'),list([inline]));
 const fig=cat([1],figure('J'));
 const value=decode(wire('J',[block('J',{flow:list([scope,fig]),values:[]}),block('J',{values:[textSpan('J',{image:{map:map()}})]})],{media:true}),{});
 assert.equal(value.sections[0].blocks[0].flow[0].scope.resolved_direction,'rtl');
 assert.equal(value.sections[0].blocks[0].flow[1].figure.caption_blocks[0].spans[0].text,'caption');
 assert.equal(value.sections[0].blocks[1].spans[0].image.map.regions[0].action.target_fragment,'');
 assert.throws(()=>decode(wire('J',[block('J',{figure:figure('J')})]),{}));
});
test('K extension preserves computed table-origin f32 length and existing cell font independence',()=>{
 const t=table('K',{style:kStyle(),cells:[cell('K',[block('K',{values:[textSpan('K',{text:'cell',scale:.8,basis:1})]})])]});
 const value=decode(wire('K',[block('K',{table:t})]),{}).sections[0].blocks[0].table;
 assert.deepEqual(value.style,{display:'inline_block',vertical_align:'middle',line_height:{value:Math.fround(1.2),font_scale_basis:'normal_body'}});
 assert.equal(value.rows[0].cells[0].blocks[0].spans[0].text,'cell');
 assert.equal(value.rows[0].cells[0].blocks[0].spans[0].font_scale,Math.fround(.8));
 assert.equal(value.style.line_height.value,Math.fround(1.2));
 assert.throws(()=>decode(wire('K',[block('K',{table:table('K',{style:kStyle()})})]),{}));
 assert.throws(()=>decode(wire('K',[block('K',{table:cat([1,0],u(0),u(1),u(0),kStyle(),[0])})]),{}));
 assert.throws(()=>decode(wire('K',[block('K',{table:table('K',{style:kStyle(),captionBlocks:[],cells:[cell('K',[])]})})]),{}));
 assert.throws(()=>decode(wire('K',[block('K',{table:table('K',{style:cat([1,16,1,0,1]),cells:[cell('K',[])]})})]),{}));
});
test('K rejects unknown extension fields enum basis nonpositive and nonfinite line height',()=>{
 for(const options of [{extra:8},{extra:0},{display:3},{align:2},{basis:2},{line:0},{line:-1},{line:NaN},{line:Infinity}]){
  assert.throws(()=>decode(wire('K',[block('K',{table:table('K',{style:kStyle(options),cells:[cell('K',[])]})})]),{}),JSON.stringify(options));
 }
});
test('J map grammar rejects coordinate shape nonfinite action and reserved image bits',()=>{
 for(const options of [{shape:0,coordinates:[1,2,3]},{shape:1,coordinates:[1,2]},{shape:2,coordinates:[1,2,3,4]},{coordinates:[0,0,Infinity,4]},{description:5},{kind:1,fragment:''},{target:'',fragment:null}])
  assert.throws(()=>decode(wire('J',[block('J',{values:[textSpan('J',{image:{map:map(options)}})]})],{media:true}),{}));
 for(const flags of [64,128,255])assert.throws(()=>decode(wire('J',[block('J',{values:[textSpan('J',{image:{flags}})]})],{media:true}),{}));
 const valid=wire('J',[block('J',{values:[textSpan('J',{image:{map:map()}})]})],{media:true});
 assert.throws(()=>decode(valid.subarray(0,valid.length-1),{}));assert.throws(()=>decode(cat(valid,[0]),{}));
});
test('rich content enforces independent depth budget and authoritative caption sinks',()=>{
 let flow=cat([0],u(0));for(let i=0;i<17;i++)flow=cat([2,0,0,0,0],list([flow]));
 assert.throws(()=>decode(wire('J',[block('J',{flow:list([flow])})]),{}));
 assert.throws(()=>decode(wire('J',[block('J',{table:table('J',{caption:[textSpan('J')],captionBlocks:[]})})]),{}));
});
test('known H through M headers index and decode compatible records; future headers stay refused',async()=>{
 for(const version of ['H','I','J','K','L','M']){
  const payload=wire(version,[block(version)]);let n=payload.length;const varint=[];do{let b=n%128;n=Math.floor(n/128);if(n)b|=128;varint.push(b);}while(n);
  const bytes=cat(Buffer.from('WIKBLB08'),[7],Buffer.from('Entry\0'),varint,payload);
  const index=await buildIndex(new RawSource(new Blob([bytes])));assert.equal(index.rows.length,1);
  assert.equal(decode(payload,index.metadata).presentation_version,'DPR'+version);
 }
 for(const version of ['N','O','P','Q','R','S','T'])assert.throws(()=>decode(wire(version,[]),{}));
});

const lContainer=(children,style=short(0))=>block('L',{container:cat(style,list(children))});
const screen=(limit,flags,fields,following=[])=>cat(u(limit),[flags|(following.length?128:0)],fields,following.length?list(following):[]);
test('L preserves every container field and descending responsive overrides without flattening children',()=>{
 const margins=cat(length(2),length(3),length(4),length(5));
 const responsiveMargins=cat([1],length(0),[0,1],length(0),[0]);
 const narrow=screen(399,1,[0]);
 const responsive=screen(719,127,cat([1,2],f(100),[0,1,2],length(2,1),[0],responsiveMargins,[3]),[narrow]);
 const style=cat(short(0xffff),margins,edges(),[2,0,3,1,0],f(300),[1,1,2,0,2],s('#ddeeff'),s('#112233'),[1],length(1),[1],s('#abcdef'),[1],f(1.25),[1],responsive,[1]);
 const child=lContainer([block('L',{kind:2,values:[textSpan('L',{text:'Nested meaning',tooltip:'kept'})]})]);
 const value=decode(wire('L',[lContainer([child],style)]),{}).sections[0].blocks[0];
 assert.equal(value.kind,'container');assert.equal(value.container.blocks[0].container.blocks[0].spans[0].tooltip,'kept');
 assert.deepEqual(value.container.style,{
  margins:{top:{unit:'px',value:2},right:{unit:'px',value:3},bottom:{unit:'px',value:4},left:{unit:'px',value:5}},
  padding:Object.fromEntries(['top','right','bottom','left'].map(side=>[side,{unit:'px',value:0}])),width:{fit_content:{}},float_side:'left',clear:'both',max_width:{length:{unit:'px',value:300}},box_sizing:'border_box',layout:'flex_row',align_items:'center',flex_item:'none',
  background:{light_dark:{light:'#ddeeff',dark:'#112233'}},border:{solid:{width:{unit:'px',value:1},color:{rgb:'#abcdef'}}},line_height:{multiplier:1.25},text_align:'center',
  screen_max_width:{max_width_px:719,width:{length:{unit:'percent',value:100}},max_width:{none:{}},box_sizing:'border_box',line_height:{length:{unit:'em',value:2}},float_side:'none',margins:{top:{length:{unit:'px',value:0}},right:{auto:{}},bottom:{length:{unit:'px',value:0}},left:{auto:{}}},clear:'both',following_rules:[{max_width_px:399,width:{auto:{}}}]},overflow:'auto'
 });
 const original=structuredClone(value);validateContainerBlock(value);assert.deepEqual(value,original);
});
test('L container content shares rich depth while table depth and catalogue traversal remain independent',()=>{
 let child=block('L',{values:[textSpan('L',{image:{},tooltip:'nested image'})]});
 for(let i=0;i<16;i++)child=lContainer([child]);
 assert.equal(decode(wire('L',[child],{media:true}),{}).sections[0].blocks[0].kind,'container');
 assert.throws(()=>decode(wire('L',[lContainer([child])],{media:true}),{}),/depth/i);
 assert.throws(()=>decode(wire('L',[child]),{}),/catalog/i);
 const caption=table('L',{captionBlocks:[child]});
 assert.throws(()=>decode(wire('L',[block('L',{table:caption})],{media:true}),{}),/depth/i);
 let grid=table('L',{cells:[cell('L',[lContainer([block('L',{values:[textSpan('L')]})])])]});
 for(let i=1;i<16;i++)grid=table('L',{cells:[cell('L',[block('L',{table:grid})])]});
 assert.doesNotThrow(()=>decode(wire('L',[block('L',{table:grid})]),{}));
 grid=table('L',{cells:[cell('L',[block('L',{table:grid})])]});
 assert.throws(()=>decode(wire('L',[block('L',{table:grid})]),{}),/table depth/i);
});
test('L retains lexical child paths and validates container owners, not flat block indices',()=>{
 const body=[lContainer([lContainer([block('L',{kind:2,values:[textSpan('L',{text:'definition'})]}),block('L',{kind:3})])])];
 const lexeme=(path,examplePaths=list([list([u(0),u(1)])]))=>cat(s('noun'),s(''),u(0),u(0xffffffff),list([
  cat(u(0),u(0xffffffff),list([u(0)]),u(0),u(0),[0],list(path.map(u)),examplePaths,u(0),u(0))
 ]),u(0),u(0),u(0),u(0),u(0));
 assert.deepEqual(decode(wire('L',body,{lexemes:[lexeme([0,0])]}),{}).organization,{
  lexemes:[{language:'noun',kind:'',section:0,etymology:null,definitions:[{
   block:0,parent:null,examples:[0],quotations:[],notes:[],form:null,block_path:[0,0],example_paths:[[0,1]]
  }],introduction:[],other_blocks:[],related_sections:[]}],other_sections:[]
 });
 for(const path of [[1],[0,2],[0,0,0],Array(17).fill(0)])assert.throws(()=>decode(wire('L',body,{lexemes:[lexeme(path)]}),{}));
 assert.throws(()=>decode(wire('L',body,{lexemes:[lexeme([0,0],list([u(0)]))]}),{}),'noncanonical all-empty parallel paths');
});
test('organization preserves forms, parent senses and independent lexical indices',()=>{
 const body=[block('K',{kind:2}),block('K',{kind:3}),block('K',{kind:4})];
 const sense=(root,parent,form)=>cat(u(root),u(parent),list([u(1)]),list([u(2)]),list([u(0)]),form);
 const form=cat([1],s('plural'),s('lemma'),s('it'));
 const lexeme=(section=0,parent=0)=>cat(s('Italian'),s('Noun'),u(section),u(0),list([
  sense(0,0xffffffff,[0]),sense(1,parent,form)
 ]),list([u(2)]),list([u(1)]),list([u(0)]));
 const value=decode(wire('K',body,{lexemes:[lexeme()]}),{}).organization;
 assert.deepEqual(value,{lexemes:[{language:'Italian',kind:'Noun',section:0,etymology:0,definitions:[
  {block:0,parent:null,examples:[1],quotations:[2],notes:[0],form:null},
  {block:1,parent:0,examples:[1],quotations:[2],notes:[0],form:{relation:'plural',target:'lemma',language:'it'}}
 ],introduction:[2],other_blocks:[1],related_sections:[0]}],other_sections:[]});
 assert.throws(()=>decode(wire('K',body,{lexemes:[lexeme(1)]}),{}));
 assert.throws(()=>decode(wire('K',body,{lexemes:[lexeme(0,1)]}),{}),'forward/self sense parent remains invalid');
});
test('L refuses malformed container ownership styles rules and later capabilities',()=>{
 for(const style of [cat(short(4),[3]),cat(short(4),[1,2],f(NaN)),cat(short(512),[1]),cat(short(1024),[1],s('#ABCDEF')),cat(short(2048),[2]),cat(short(4096),[1],f(-1)),cat(short(256),[2]),cat(short(1),cat(length(1),length(),length(),length())),cat(short(16384),screen(700,1,[0],[screen(700,1,[0])]))])
  assert.throws(()=>decode(wire('L',[lContainer([],style)]),{}));
 for(const child of [block('L',{kind:9}),block('L',{style:cat([1,1],length(1),length(),length(),length())})])assert.throws(()=>decode(wire('L',[lContainer([child])]),{}));
 assert.throws(()=>decode(wire('L',[block('L',{container:cat(short(0),u(0)),values:[textSpan('L')]})]),{}));
 assert.throws(()=>decode(wire('K',[lContainer([])]),{}));
 const valid=wire('L',[lContainer([])]);
 for(let end=4;end<valid.length;end++)assert.throws(()=>decode(valid.subarray(0,end),{}));
 assert.throws(()=>decode(cat(valid,[0]),{}));
 const value=decode(valid,{}).sections[0].blocks[0];
 for(const field of ['owner_font_scale','height','font_family','columns','margin_values'])assert.throws(()=>validateContainerBlock({...value,container:{...value.container,style:{[field]:1}}}));
});
test('M preserves owner font and cell strut metrics without shifting nested content',()=>{
 const style=cat([1,0xa8],[0],f(20),[0,1],f(.9),[1,2],f(.855),[1]);
 const c=cat([0,1,0,1,0,0],u(0),[0,1],list([block('M',{values:[textSpan('M',{text:'linked reading',scale:.9,basis:1})]})]),style);
 const owner=cat(u(0x10002),edges(),f(.9),list([block('M',{values:[textSpan('M',{text:'owner'})]})]));
 const bytes=wire('M',[block('M',{table:table('M',{cells:[c]})}),block('M',{container:owner})]);
 const result=decode(bytes,{}),value=result.sections[0].blocks[0].table.rows[0].cells[0];
 assert.deepEqual(value.style,{width:{unit:'px',value:20},vertical_align:'top',line_height:{strut:{font_scale:Math.fround(.9),font_scale_basis:'normal_body'},height:{length:{value:Math.fround(.855),font_scale_basis:'normal_body'}}}});
 assert.equal(value.blocks[0].spans[0].text,'linked reading');
 assert.equal(result.sections[0].blocks[1].container.style.owner_font_scale,Math.fround(.9));
 for(let end=0;end<bytes.length;end++)assert.throws(()=>decode(bytes.subarray(0,end),{}));
});
test('M admits authored flow margins while L still rejects them and unknown policies fail closed',()=>{
 const margin=cat(length(1),length(0),length(1),length(0));
 const m=wire('M',[block('M',{container:cat(u(1),margin,u(0))})]);
 assert.equal(decode(m,{}).sections[0].blocks[0].container.style.margins.top.value,1);
 assert.throws(()=>decode(wire('L',[block('L',{container:cat(short(1),margin,u(0))})]),{}));
 assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(0x80000),length(1),u(0))})]),{}));
 for(const value of [NaN,Infinity,-1])assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(0x10000),f(value),u(0))})]),{}));
 assert.throws(()=>decode(wire('N',[]),{}));
});
test('original M container margins retain the native range without admitting signed padding or L margins',async()=>{
 const {createHash}=await import('node:crypto');
 const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
 for(const [page,title,locale,size,memberSHA,payloadSHA] of [
  [3289,'kakophonisch','de',25824,'ca4bdbbdbac2c17d96610f0a34b7d75206b38a75306364f34898a8c687b734e0','ea6b64fcd714b2141c3fd30e497b5bc576b5f39bec8b6bec6dff4a9ce7d008f5'],
  [519864,'vit som ett lakan','sv',8982,'217f02b706024d06687f47cad03824ddfc474ea2a7f65688a4aac6a11fc013ec','e29be02d4e4f3de59b158a79e6a45024e29e7787c9fe1640c18e14bae67e3a6e'],
 ]){
  const bytes=await readFile(new URL(`testdata/de-tiff/p${page}.wikblb`,import.meta.url));
  assert.deepEqual([bytes.length,sha(bytes)],[size,memberSHA]);
  const {metadata,rows}=await buildIndex(new RawSource(new Blob([bytes])));
  assert.deepEqual([metadata.language_code,rows.map(row=>row.title)],[locale,[title]]);
  const [{offset,length}]=rows,payload=bytes.subarray(offset,offset+length);
  assert.equal(sha(payload),payloadSHA);
  const original=decode(payload,{...metadata,title});
  assert.equal(original.presentation_version,'DPRM');
  assert.deepEqual(original.sections[2].blocks[2].container.style.margins.bottom,{unit:'em',value:-.5});
 }
 const bottom=value=>cat(length(0),length(0),length(value,1),length(0));
 const container=(version,flags,edges)=>wire(version,[block(version,{container:cat(flags,edges,u(0))})]);
 const signed=decode(container('M',u(1),bottom(-.5)),{}).sections[0].blocks[0].container.style;
 assert.deepEqual(signed.margins.bottom,{unit:'em',value:-.5});
 assert.throws(()=>decode(container('M',u(2),bottom(-.5)),{}),/Invalid style length/);
 assert.throws(()=>decode(container('L',short(1),bottom(-.5)),{}),/Invalid style length/);
 for(const value of [NaN,Infinity,-Infinity])assert.throws(()=>decode(container('M',u(1),bottom(value)),{}),/Invalid signed length/);
});
// Existing ordinary Writer/Reader export route supplies genuine payload+complete JSON.
// No constructed page can satisfy this optional cross-decoder artifact assertion.
test('selected genuine Writer payload and Reader modeled graph agree',{skip:!process.env.WIKIDICT_WEB_TYPED_CASES},async()=>{
 const cases=JSON.parse(await readFile(process.env.WIKIDICT_WEB_TYPED_CASES,'utf8'));assert.ok(cases.length>0);
 for(const item of cases){
  const response=JSON.parse(await readFile(item.reader_json,'utf8'));assert.equal(response.entries.length,1);
  const expected=response.entries[0];
  let payload;
  if(item.blob){
   const bytes=new Uint8Array(await readFile(item.blob)),source={size:bytes.length,read:async(offset,length)=>bytes.slice(offset,offset+length)};
   const index=await buildIndex(source),row=index.rows.find(row=>row.title===expected.title);assert.ok(row,'genuine title missing from index');
   payload=await source.read(row.offset,row.length);
  }else payload=new Uint8Array(await readFile(item.payload));
  const actual=decode(payload,{title:expected.title,kind:expected.kind,language:expected.language,language_code:expected.language_code});
  // Existing web schema names list_path as path and keeps organization, with query-side alias fields represented separately.
  const project=(value,root=false)=>{
   if(Array.isArray(value))return value.map(x=>project(x));
   if(!value||typeof value!=='object')return value;
   const result=Object.fromEntries(Object.entries(value).filter(([k])=>!root||!['redirect','alias','presentation_version'].includes(k)).map(([k,v])=>[k==='list_path'?'path':k,project(v)]));
   if(Object.hasOwn(result,'text')&&Object.hasOwn(result,'trail')&&Object.hasOwn(result,'target')){
    result.background??=null;result.tooltip??=null;if(result.font_scale!==undefined)result.font_scale=Math.fround(result.font_scale);
    if(result.inline_style?.wrap===null)delete result.inline_style.wrap;
    if(result.audio_control)for(const key of ['width','height','focus'])result.audio_control[key]??=null;
   }
   if(Object.hasOwn(result,'depth')&&Object.hasOwn(result,'level')&&Object.hasOwn(result,'spans')){result.feature??=null;result.table??=null;}
   return result;
  };
  assert.deepEqual(project(actual,true),project(expected,true),expected.title);
 }
});

test('legacy table geometry outputs all four nullable model components without inventing absent geometry',()=>{
 const short=n=>Buffer.from([n&255,n>>8]);
 for(const flags of [1,2,3,4,8,13,15]){
  const geometry=cat(flags&1?short(0):[],flags&2?short(15):[],flags&4?short(2):[],flags&8?cat([1],u(100)):[]);
  const grid=cat([1,flags],geometry,u(0),u(0));
  const actual=decode(wire('7',[block('7',{table:grid})]),{}).sections[0].blocks[0].table.geometry;
  assert.deepEqual(actual,{border:flags&1?0:null,cell_spacing:flags&2?15:null,cell_padding:flags&4?2:null,width:flags&8?{unit:'percent',value:100}:null});
 }
 const absent=decode(wire('7',[block('7',{table:cat([1,0],u(0),u(0))})]),{}).sections[0].blocks[0].table;
 assert.equal(Object.hasOwn(absent,'geometry'),false);
 assert.throws(()=>decode(wire('7',[block('7',{table:cat([1,16],u(0),u(0))})]),{}));
});

// Native266 K: 0x40 carries a closed enum after the complete optional map.
test('K image dark filter follows map and retains absent legacy shape',()=>{
 for(const mapped of [false,true]){
  const image={flags:mapped?97:65,...(mapped?{map:map()}:{}),afterMap:[0]};
  const payload=wire('K',[block('K',{values:[textSpan('K',{image,tooltip:'after-image'})]})],{media:true});
  const span=decode(payload,{}).sections[0].blocks[0].spans[0];
  assert.equal(span.image.dark_mode_filter,'invert_hue_rotate_180');
  assert.equal(span.tooltip,'after-image');
  assert.equal(span.image.width_px,120);
  if(mapped)assert.equal(span.image.map.regions[0].action.target_fragment,'');
  else assert.equal(Object.hasOwn(span.image,'map'),false);
 }
 for(const version of ['J','K']){
  const image=decode(wire(version,[block(version,{values:[textSpan(version,{image:{}})]})],{media:true}),{}).sections[0].blocks[0].spans[0].image;
  assert.equal(Object.hasOwn(image,'dark_mode_filter'),false);
 }
 const nested=table('K',{captionBlocks:[block('K',{values:[textSpan('K',{image:{flags:65,afterMap:[0]}})]})],cells:[]});
 assert.equal(decode(wire('K',[block('K',{table:nested})],{media:true}),{}).sections[0].blocks[0].table.caption_blocks[0].spans[0].image.dark_mode_filter,'invert_hue_rotate_180');
 const scope=cat([2,0,0,0,0],list([cat([0],list([textSpan('K',{image:{flags:65,afterMap:[0]}})]))]));
 assert.equal(decode(wire('K',[block('K',{flow:list([scope])})],{media:true}),{}).sections[0].blocks[0].flow[0].scope.parts[0].spans[0].image.dark_mode_filter,'invert_hue_rotate_180');
});
test('K dark filter refuses unknown enum reserved bit truncation and old J grant',()=>{
 for(const [version,flags,afterMap] of [['K',65,[1]],['K',65,[255]],['K',193,[0]],['J',65,[0]]])
  assert.throws(()=>decode(wire(version,[block(version,{values:[textSpan(version,{image:{flags,afterMap}})]})],{media:true}),{}));
 const valid=wire('K',[block('K',{values:[textSpan('K',{image:{flags:65,afterMap:[0]}})]})],{media:true});
 const enumAt=valid.indexOf(Buffer.from('Map.svg'))+Buffer.byteLength('Map.svg')+1+4;
 assert.equal(valid[enumAt],0);
 assert.throws(()=>decode(valid.subarray(0,enumAt),{}));
 assert.throws(()=>decode(cat(valid,[0]),{}));
});

test('DPRM preserves physical table and cell border edges in wire order', () => {
 const line=(tag,width,color)=>cat([tag],length(width),s(color));
 const border=cat([2,0,1],line(2,1,'#123456'),line(3,2,'#abcdef'));
 const make=(version,border)=>{
  const styledCell=cat([0,1,0,1,0,0],u(0),[0,0,1,1],border);
  const styledTable=table(version,{cells:[styledCell],style:cat([1,2,0],border)});
  return wire(version,[block(version,{table:styledTable})]);
 };
 const expected={edges:{top:{none:{}},right:{hidden:{}},bottom:{solid:{width:{unit:'px',value:1},color:'#123456'}},left:{dotted:{width:{unit:'px',value:2},color:'#abcdef'}}}};
 const value=decode(make('M',border),{}).sections[0].blocks[0].table;
 assert.deepEqual(value.style.border,expected);
 assert.deepEqual(value.rows[0].cells[0].style.border,expected);
 for(const invalid of [cat([2,0,0,0,4]),cat([2,0,0,0],line(2,-1,'#123456')),cat([2,0,0,0],line(3,2,'#abcdef\n')),cat([3,0,0,0,0])]){
  assert.throws(()=>decode(make('M',invalid),{}));
 }
 assert.throws(()=>decode(make('L',border),{}));
});

test('M fixed container height keeps owner basis and rejects malformed or unsupported policies',()=>{
 const bytes=wire('M',[block('M',{container:cat(u(0x30000),f(.9),length(1.6,1),list([block('M',{values:[textSpan('M',{text:'height body'})]})]))})]);
 const value=decode(bytes,{}).sections[0].blocks[0].container;
 assert.deepEqual(value.style,{owner_font_scale:Math.fround(.9),height:{unit:'em',value:Math.fround(1.6)}});
 assert.equal(value.blocks[0].spans[0].text,'height body');
 for(const [amount,unit] of [[0,0],[24,0],[1.44,1]]){const sample=decode(wire('M',[block('M',{container:cat(u(0x20000),length(amount,unit),u(0))})]),{});assert.deepEqual(sample.sections[0].blocks[0].container.style.height,{unit:unit?'em':'px',value:Math.fround(amount)});}
 for(let end=0;end<bytes.length;end++)assert.throws(()=>decode(bytes.subarray(0,end),{}));
 for(const bad of [-1,NaN,Infinity])assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(0x20000),length(bad),u(0))})]),{}));
 assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(0x20000),length(1,2),u(0))})]),{}));
 for(const bit of [0x80000,0x100000,0x200000,0x400000,0x800000])assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(bit),u(0))})]),{}),/Unsupported container layout policy/);
 assert.throws(()=>validateContainerBlock({kind:'container',container:{style:{height:{unit:'em',value:1.6}},blocks:[]}}));
});

const laoArchiveLimits = {compressed: 8 * 1024 ** 2, expanded: 160 * 1024 ** 2, line: 1024 ** 2};

async function compareLaoArchive(input, {archiveHash, language, root, rows, limits = laoArchiveLimits}, compare) {
 const {createHash}=await import('node:crypto');
 const {Transform}=await import('node:stream');
 const {pipeline}=await import('node:stream/promises');
 const {createGunzip}=await import('node:zlib');
 const hash=createHash('sha256');
 let compressedBytes=0, expandedBytes=0, largestLine=0;
 const hashed=new Transform({
  transform(chunk, encoding, done) {
   compressedBytes+=chunk.length;
   if(compressedBytes>limits.compressed){
    done(new Error('Lao Reader archive exceeds compressed byte limit'));
    return;
   }
   hash.update(chunk);
   done(null,chunk);
  },
 });
 const pendingTitles=new Set(rows.keys());
 const requestPrefix=['export','--root',root,'--language',language,'--case-sensitive','--batch','--'];
 const compareLine=async bytes=>{
  const {request,response}=JSON.parse(bytes);
  assert.deepEqual(
   [response.schema,response.operation,response.kind,response.language,response.match_mode,
    response.offset,response.record_count,response.total_matches,response.has_more,response.entries.length],
   ['dict.results.v1','lookup','language',language,'exact-utf8',0,rows.size,1,false,1],
   'unexpected Lao Reader response envelope',
  );
  const [expected]=response.entries;
  assert.deepEqual(request,[...requestPrefix,expected.title],'Lao Reader request title or scope mismatch');
  assert.deepEqual([response.query,expected.language],[expected.title,language],'Lao Reader response title or language mismatch');
  const row=rows.get(expected.title);
  assert.ok(row,`unindexed Lao Reader title ${expected.title}`);
  assert.ok(pendingTitles.delete(expected.title),`duplicate Lao Reader title ${expected.title}`);
  await compare(row,expected,{request,response});
 };
 await pipeline(input,hashed,createGunzip(),async expanded=>{
  let parts=[], lineBytes=0;
  for await(const chunk of expanded){
   expandedBytes+=chunk.length;
   assert.ok(expandedBytes<=limits.expanded,'Lao Reader archive exceeds expanded byte limit');
   let start=0;
   while(start<chunk.length){
    const newline=chunk.indexOf(0x0a,start);
    const end=newline===-1?chunk.length:newline;
    lineBytes+=end-start;
    assert.ok(lineBytes<=limits.line,'Lao Reader archive exceeds line byte limit');
    parts.push(chunk.subarray(start,end));
    start=end+1;
    if(newline!==-1){
     largestLine=Math.max(largestLine,lineBytes);
     await compareLine(Buffer.concat(parts,lineBytes));
     parts=[];
     lineBytes=0;
    }
   }
  }
  if(lineBytes){
   largestLine=Math.max(largestLine,lineBytes);
   await compareLine(Buffer.concat(parts,lineBytes));
  }
 });
 assert.equal(hash.digest('hex'),archiveHash,'Lao Reader archive hash mismatch');
 assert.equal(pendingTitles.size,0,`missing Lao Reader titles: ${[...pendingTitles].slice(0,3).join(', ')}`);
 return {compressedBytes,expandedBytes,largestLine,uniqueTitles:rows.size};
}

test('current Lao container height member matches complete retained native graphs',{skip:!process.env.WIKIDICT_WEB_LO_HEIGHT_CASE},async()=>{
 const {createHash}=await import('node:crypto'),{createReadStream}=await import('node:fs');
 const {Readable}=await import('node:stream'),{gzipSync}=await import('node:zlib');
 const {openSource}=await import('./xz.js'),{pathToFileURL}=await import('node:url');
 const c=JSON.parse(await readFile(process.env.WIKIDICT_WEB_LO_HEIGHT_CASE,'utf8')),sha=b=>createHash('sha256').update(b).digest('hex');
 const baseline=await readFile(c.baseline_decoder.path);assert.equal(sha(baseline),c.baseline_decoder.sha256);assert.equal(baseline.length,c.baseline_decoder.bytes);const {decode:before}=await import(pathToFileURL(c.baseline_decoder.path).href);
 const manifest=await readFile(c.root+'/complete.json');assert.equal(sha(manifest),c.complete_sha256);const authority=JSON.parse(manifest).publication_files[c.member];
 const compressed=await readFile(c.root+'/'+c.member);assert.equal(sha(compressed),authority.sha256);assert.equal(compressed.length,authority.size);
 const source=await openSource(new Blob([compressed])),index=await buildIndex(source);assert.equal(index.rows.length,c.expected_records);
 const rows=new Map(index.rows.map(row=>[row.title,row])),failures={},heightValues=new Map();let heightEntries=0,heightNodes=0;
 assert.equal(rows.size,index.rows.length,'duplicate Lao title in the indexed member');
 const inspect=v=>{let found=false;if(v&&typeof v==='object'){if(v.style?.height!=null){heightNodes++;heightValues.set(JSON.stringify(v.style.height),true);found=true;}for(const x of Object.values(v))if(inspect(x))found=true;}return found;};
 for(const row of index.rows){const bytes=await source.read(row.offset,row.length);try{before(bytes,{...index.metadata,title:row.title});}catch(error){failures[error.message]=(failures[error.message]||0)+1;}
  const entry=decode(bytes,{...index.metadata,title:row.title});if(inspect(entry))heightEntries++;
 }
 const project=(v,top=false)=>{if(Array.isArray(v))return v.map(x=>project(x));if(!v||typeof v!=='object')return v;
  const out=Object.fromEntries(Object.entries(v).filter(([k])=>!top||!['redirect','alias','presentation_version'].includes(k)).map(([k,x])=>[k==='list_path'?'path':k,project(x)]));
  if(Object.hasOwn(out,'text')&&Object.hasOwn(out,'trail')&&Object.hasOwn(out,'target')){out.background??=null;out.tooltip??=null;if(out.font_scale!==undefined)out.font_scale=Math.fround(out.font_scale);}
  if(Object.hasOwn(out,'depth')&&Object.hasOwn(out,'level')&&Object.hasOwn(out,'spans')){out.feature??=null;out.table??=null;}return out;};
 let nativeHeightCompared=0;
 const sampleTitles=['ราตรี','ກ'];
 const samples=new Map();
 const archiveOptions={archiveHash:c.reader_archive_sha256,language:index.metadata.language,root:c.root,rows};
 const archive=await compareLaoArchive(createReadStream(c.reader_archive),archiveOptions,
  async(row,expected,item)=>{
   const entry=decode(await source.read(row.offset,row.length),{...index.metadata,title:row.title});
   assert.deepEqual(project(entry,true),project(expected,true),expected.title);
   if(sampleTitles.includes(row.title))samples.set(row.title,item);
   const prior=heightNodes;if(inspect(expected))nativeHeightCompared++;heightNodes=prior;
  },
 );
 assert.equal(archive.uniqueTitles,c.expected_native_graphs);assert.equal(nativeHeightCompared,c.expected_native_height_graphs);assert.equal(heightEntries,c.expected_height_entries);assert.equal(heightNodes,c.expected_height_nodes);assert.equal(Object.keys(failures).length,1);assert.equal(failures['Unsupported container layout policy'],c.expected_height_entries);

 // Preserve the two authentic graphs inside explicitly synthetic two-record archives.
 const controlRows=new Map(sampleTitles.map(title=>[title,rows.get(title)]));
 const [first,second]=sampleTitles.map(title=>{
  const {request,response}=samples.get(title);
  return {request,response:{...response,record_count:controlRows.size}};
 });
 const compareControl=(items,{limits,wrongHash=false}={})=>{
  const bytes=gzipSync(items.map(item=>JSON.stringify(item)+'\n').join(''));
  const input=Readable.from([bytes.subarray(0,11),bytes.subarray(11)]);
  return compareLaoArchive(input,{...archiveOptions,rows:controlRows,limits,
   archiveHash:wrongHash?'0'.repeat(64):sha(bytes)},(row,expected)=>{
    assert.deepEqual(expected,samples.get(row.title).response.entries[0]);
   });
 };
 assert.equal((await compareControl([first,second])).uniqueTitles,2);
 await assert.rejects(compareControl([first,first]),/duplicate Lao Reader title ราตรี/);
 await assert.rejects(compareControl([first]),/missing Lao Reader titles: ກ/);
 await assert.rejects(compareControl([{...first,request:[...first.request.slice(0,-1),'ກ']},second]),/request title or scope mismatch/);
 await assert.rejects(compareControl([{...first,response:{...first.response,query:'ກ'}},second]),/response title or language mismatch/);
 await assert.rejects(compareControl([first,second],{wrongHash:true}),/archive hash mismatch/);
 for(const bound of ['compressed','expanded','line']){
  await assert.rejects(compareControl([first,second],{limits:{...laoArchiveLimits,[bound]:64}}),
   new RegExp(`exceeds ${bound} byte limit`));
 }
 console.log(JSON.stringify({scope:'current2b9 affectedLao member, not frozenoldf412 census',records:index.rows.length,baseline_current_failures:failures,candidate_decode_failures:0,height_entries:heightEntries,height_nodes:heightNodes,height_values:[...heightValues.keys()],complete_native_graphs_compared:archive.uniqueTitles,native_height_graphs_compared:nativeHeightCompared,compressed_bytes:compressed.length,archive_compressed_bytes:archive.compressedBytes,archive_uncompressed_bytes:archive.expandedBytes,archive_largest_line_bytes:archive.largestLine,archive_limits:laoArchiveLimits,unique_reader_titles:archive.uniqueTitles,duplicate_reader_titles:0,synthetic_controls:{positive:1,rejected:['duplicate-with-omission','missing-title','crossed-request','crossed-response','bad-hash','compressed-limit','expanded-limit','line-limit']}}));
});

test('M balanced container columns preserve count gap and native composition limits',()=>{
 const encoded=(count=3,gap=length(1,1),flags=0x40000,prefix=[])=>wire('M',[block('M',{container:cat(u(flags),prefix,short(count),gap,list([block('M',{values:[textSpan('M',{text:'kept child'})]})]))})]);
 for(const [count,value,unit] of [[1,0,0],[3,1,1],[65535,2,0]]){const result=decode(encoded(count,length(value,unit)),{}).sections[0].blocks[0].container;assert.deepEqual(result.style.columns,{count,gap:{unit:unit?'em':'px',value}});assert.equal(result.blocks[0].spans[0].text,'kept child');}
 const bytes=encoded();for(let end=0;end<bytes.length;end++)assert.throws(()=>decode(bytes.subarray(0,end),{}));
 assert.throws(()=>decode(encoded(0),{}));for(const bad of [-1,NaN,Infinity])assert.throws(()=>decode(encoded(3,length(bad)),{}));assert.throws(()=>decode(encoded(3,length(1,2)),{}));
 for(const [flags,prefix] of [[0x60000,length(1)],[0x40080,[1]],[0x48000,[1]]])assert.throws(()=>decode(encoded(3,length(1,1),flags,prefix),{}));
 for(const count of [0,-1,1.5,65536])assert.throws(()=>validateContainerStyle({columns:{count,gap:{unit:'em',value:1}}},{containerFonts:true}));
 for(const extra of [{height:{unit:'px',value:0}},{layout:'flex_row'},{overflow:'auto'},{min_height:{unit:'px',value:1}},{positioning:'relative_auto'}])assert.throws(()=>validateContainerStyle({columns:{count:3,gap:{unit:'em',value:1}},...extra},{containerFonts:true}));
 assert.throws(()=>validateContainerStyle({columns:{count:3,gap:{unit:'em',value:1}}}));
 assert.throws(()=>decode(wire('M',[block('M',{container:cat(u(0x80000),[0],u(0))})]),{}),/Unsupported container layout policy/);
});

test('genuine TPI Thesaurus talk columns match complete native graphs',{skip:!process.env.WIKIDICT_WEB_TPI_COLUMNS_CASE},async()=>{
 const {createHash}=await import('node:crypto'),{openAsBlob}=await import('node:fs'),{gunzipSync}=await import('node:zlib'),{openSource}=await import('./xz.js');
 const c=JSON.parse(await readFile(process.env.WIKIDICT_WEB_TPI_COLUMNS_CASE,'utf8')),sha=b=>createHash('sha256').update(b).digest('hex');
 const {pathToFileURL}=await import('node:url');const baseline=await readFile(c.baseline_decoder.path);assert.equal(baseline.length,c.baseline_decoder.bytes);assert.equal(sha(baseline),c.baseline_decoder.sha256);const {decode:before}=await import(pathToFileURL(c.baseline_decoder.path).href);
 const manifest=await readFile(c.root+'/complete.json');assert.equal(sha(manifest),c.complete_sha256);const authority=JSON.parse(manifest).publication_files[c.member],compressed=await readFile(c.root+'/'+c.member);assert.equal(sha(compressed),authority.sha256);assert.equal(compressed.length,authority.size);
 const source=await openSource(await openAsBlob(c.root+'/'+c.member)),index=await buildIndex(source);assert.equal(index.rows.length,c.expected_records);const map=new Map();let failures=0;
 for(const row of index.rows){const bytes=await source.read(row.offset,row.length);try{before(bytes,{...index.metadata,title:row.title});}catch(error){assert.equal(row.title,c.title);assert.equal(error.message,'Unsupported container layout policy');failures++;}map.set(row.title,decode(bytes,{...index.metadata,title:row.title}));}
 assert.equal(failures,1);const archive=await readFile(c.reader_archive);assert.equal(sha(archive),c.reader_archive_sha256);
 const project=(v,top=false)=>{if(Array.isArray(v))return v.map(x=>project(x));if(!v||typeof v!=='object')return v;const o=Object.fromEntries(Object.entries(v).filter(([k])=>!top||!['redirect','alias','presentation_version'].includes(k)).map(([k,x])=>[k==='list_path'?'path':k,project(x)]));if(Object.hasOwn(o,'text')&&Object.hasOwn(o,'trail')&&Object.hasOwn(o,'target')){o.background??=null;o.tooltip??=null;if(o.font_scale!==undefined)o.font_scale=Math.fround(o.font_scale);}if(Object.hasOwn(o,'depth')&&Object.hasOwn(o,'level')&&Object.hasOwn(o,'spans')){o.feature??=null;o.table??=null;}return o;};
 let compared=0;const comparedTitles=new Set();for(const line of gunzipSync(archive,{maxOutputLength:64*1024*1024}).toString().trim().split('\n')){const row=JSON.parse(line);if(row.request?.[4]!==index.metadata.language)continue;const expected=row.response?.entries?.[0];if(!expected||!map.has(expected.title))continue;assert.deepEqual(project(map.get(expected.title),true),project(expected,true),expected.title);compared++;comparedTitles.add(expected.title);}
 assert.equal(compared,c.expected_native_exports);assert.equal(comparedTitles.size,c.expected_native_unique);const actual=map.get(c.title),columns=[];const walk=x=>{if(x&&typeof x==='object'){if(x.style?.columns)columns.push(x.style.columns);for(const y of Object.values(x))walk(y);}};walk(actual);assert.deepEqual(columns,[{count:3,gap:{unit:'em',value:1}},{count:3,gap:{unit:'em',value:1}}]);
 for(const [name,count] of [['Synonyms',8],['Hyponyms',2]])assert.equal(actual.sections.find(s=>s.title===name).blocks[0].container.blocks.length,count);
 console.log(JSON.stringify({scope:'Exact current/frozen TPI English member',records:index.rows.length,before_failures:failures,after_failures:0,native_graphs:compared,native_unique_graphs:comparedTitles.size,column_owners:columns,synonyms:8,hyponyms:2,compressed_bytes:compressed.length}));
});

test('ordinary description bodies reject forged owner, zero rail, unknown tag and invalid paired paint',async()=>{
  const {openSource}=await import('./xz.js');
  const {createHash}=await import('node:crypto');
  const asset=new URL('../../android/app/src/androidTest/assets/babua/description-body.wikblb.xz',import.meta.url);
  const source=await openSource(new Blob([await readFile(asset)]));
  const {rows,metadata}=await buildIndex(source),row=rows[0];
  const bytes=Buffer.from(await source.read(row.offset,row.length));
  assert.equal(createHash('sha256').update(bytes).digest('hex'),'57612f152e6722cbc444fa2985e4a9a48be4ca5de0bed0bed134d5abe49f37ba');
  const entry=decode(bytes,metadata),outer=entry.sections[1].blocks[5];
  assert.equal(outer.kind,'example');assert.equal(outer.description_body.before.fill.light_dark.dark,'#333333');
  const mutate=(at,edit)=>{const altered=Buffer.from(bytes);edit(altered,at);assert.throws(()=>decode(altered,metadata));};
  for(const [inset,ownerPath] of [[.2,'#:'],[.19,':']]){
    const prefix=cat([2],length(inset,1),length(inset,1),length(inset,1),length(1),[2],s('#cccccc'),s('#333333'));
    const at=bytes.indexOf(prefix);
    assert.ok(at>0);assert.equal(bytes.indexOf(prefix,at+1),-1);
    // The description's original list path ends immediately before the 16 bytes of empty number/table/anchor/geometry fields.
    const pathEnd=at-16;
    assert.equal(bytes.subarray(pathEnd-ownerPath.length,pathEnd).toString(),ownerPath);
    mutate(pathEnd-1,(b,i)=>{b[i]=59;});
    mutate(at,(b,i)=>{b[i]=3;});
    mutate(at+17,(b,i)=>b.writeFloatLE(0,i));
    mutate(at+1,(b,i)=>{b[i]=2;});
    assert.throws(()=>decode(bytes.subarray(0,at+20),metadata));
  }
  const ink=bytes.indexOf('#e0e0e0');assert.ok(ink>0);
  mutate(ink,(b,i)=>Buffer.from('#333333').copy(b,i));
  mutate(ink,(b,i)=>Buffer.from('#GGGGGG').copy(b,i));
});

test('DPRM table disclosure keeps physical header, row modes and old table bytes',()=>{
  const body=(flags=0x41,modes=[0,1,2],collapsed=1,headerCell=0,label='more',version='M')=>{
    const cells=[1,0,0].map(header=>cat([header,1,0,1,0,0],u(0),[0,0,0]));
    const base=cat([flags,0],u(0),list(cells.map(c=>list([c]))),[0,0]);
    const tail=flags===1?Buffer.alloc(0):cat(u(0),u(headerCell),[collapsed],s(label),s('less'),s('inflection'),modes);
    return wire(version,[block(version,{table:cat(base,tail)})]);
  };
  const record=body();
  const table=decode(record,{}).sections[0].blocks[0].table;
  assert.deepEqual(table.disclosure,{header_row:0,header_cell:0,initially_collapsed:true,expand_label:'more',
    collapse_label:'less',category:'inflection',row_modes:['always','collapsed','expanded']});
  assert.equal(table.rows[0].cells[0].header,true);
  const old=decode(body(1),{}).sections[0].blocks[0].table;
  assert.equal(old.disclosure,undefined);
  assert.deepEqual(old.rows,table.rows);
  assert.equal(decode(body(0x41,[0,1,2],0),{}).sections[0].blocks[0].table.disclosure.initially_collapsed,false);
  for(const flags of [0x40,0x43,0x61,0x81])assert.throws(()=>decode(body(flags),{}));
  for(const modes of [[2,1,0],[0,0,0],[0,3,2],[0,1]])assert.throws(()=>decode(body(0x41,modes),{}));
  for(const bad of [body(0x41,[0,1,2],2),body(0x41,[0,1,2],0,1),body(0x41,[0,1,2],0,0,''),
    body(0x41,[0,1,2],0,0,'more\x00'),body(0x41,[0,1,2],0,0,'more','L')])assert.throws(()=>decode(bad,{}));
});
