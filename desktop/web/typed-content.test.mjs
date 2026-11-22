// Hand-framed boundary controls; genuine Writer/Reader fixtures remain independent.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {decode,buildIndex,RawSource} from './blob.js';
import {validateContainerBlock} from './validate.js';
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
test('known H I J K L dictionary index gates preserve unknown future refusal',async()=>{
 for(const version of ['H','I','J','K','L']){
  const payload=wire(version,[block(version)]);let n=payload.length;const varint=[];do{let b=n%128;n=Math.floor(n/128);if(n)b|=128;varint.push(b);}while(n);
  const bytes=cat(Buffer.from('WIKBLB08'),[7],Buffer.from('Entry\0'),varint,payload);
  const index=await buildIndex(new RawSource(new Blob([bytes])));assert.equal(index.rows.length,1);
 }
 for(const version of ['M','N','O','P','Q','R','S','T'])assert.throws(()=>decode(wire(version,[]),{}));
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
test('L validates lexical child paths against container children, not flat block indices',()=>{
 const body=[lContainer([lContainer([block('L',{kind:2,values:[textSpan('L',{text:'definition'})]}),block('L',{kind:3})])])];
 const lexeme=(path,examplePaths=list([list([u(0),u(1)])]))=>cat(s('noun'),s(''),u(0),u(0xffffffff),list([
  cat(u(0),u(0xffffffff),list([u(0)]),u(0),u(0),[0],list(path.map(u)),examplePaths,u(0),u(0))
 ]),u(0),u(0),u(0),u(0),u(0));
 assert.doesNotThrow(()=>decode(wire('L',body,{lexemes:[lexeme([0,0])]}),{}));
 for(const path of [[1],[0,2],[0,0,0],Array(17).fill(0)])assert.throws(()=>decode(wire('L',body,{lexemes:[lexeme(path)]}),{}));
 assert.throws(()=>decode(wire('L',body,{lexemes:[lexeme([0,0],list([u(0)]))]}),{}),'noncanonical all-empty parallel paths');
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
// Existing ordinary Writer/Reader export route supplies genuine payload+complete JSON.
// No constructed page can satisfy this optional cross-decoder artifact assertion.
test('selected genuine Writer payload and Reader modeled graph agree',{skip:!process.env.WIKIDICT_WEB_TYPED_CASES},async()=>{
 const cases=JSON.parse(await readFile(process.env.WIKIDICT_WEB_TYPED_CASES,'utf8'));assert.ok(cases.length>0);
 for(const item of cases){
  const response=JSON.parse(await readFile(item.reader_json,'utf8'));assert.equal(response.entries.length,1);
  const expected=response.entries[0],actual=decode(new Uint8Array(await readFile(item.payload)),{title:expected.title,kind:expected.kind,language:expected.language,language_code:expected.language_code});
  // Existing web schema names list_path as path and omits query-side organization/alias fields.
  const project=(value,root=false)=>{
   if(Array.isArray(value))return value.map(x=>project(x));
   if(!value||typeof value!=='object')return value;
   const result=Object.fromEntries(Object.entries(value).filter(([k])=>!root||!['organization','redirect','alias','presentation_version'].includes(k)).map(([k,v])=>[k==='list_path'?'path':k,project(v)]));
   if(Object.hasOwn(result,'text')&&Object.hasOwn(result,'trail')&&Object.hasOwn(result,'target')){
    result.background??=null;result.tooltip??=null;if(result.font_scale!==undefined)result.font_scale=Math.fround(result.font_scale);
   }
   if(Object.hasOwn(result,'depth')&&Object.hasOwn(result,'level')&&Object.hasOwn(result,'spans')){result.feature??=null;result.table??=null;}
   return result;
  };
  assert.deepEqual(project(actual,true),project(expected,true));
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
