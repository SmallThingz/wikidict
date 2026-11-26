import test from 'node:test';
import assert from 'node:assert/strict';
import {decode,buildIndex,RawSource} from './blob.js';
import {validateInlineBoxSpan} from './validate.js';
import {spans} from './renderer.js';
import {inlineText} from './preview.js';

const cat=(...values)=>Buffer.concat(values.map(value=>Array.isArray(value)?Buffer.from(value):value));
const u=value=>{const bytes=Buffer.alloc(4);bytes.writeUInt32LE(value);return bytes;};
const f=value=>{const bytes=Buffer.alloc(4);bytes.writeFloatLE(value);return bytes;};
const string=value=>cat(u(Buffer.byteLength(value)),Buffer.from(value));
const list=values=>cat(u(values.length),...values);
const length=(n,unit=0)=>cat([unit],f(n));
const edge=cat([2],length(1),[2],string('#000000'));
const border=cat(edge,edge,edge,edge);
const cleanBorder=[0,0,0,0];
const zero=length(0);
const padding=cat(zero,zero,zero,zero);
const nb='\u00a0'.repeat(4);
const run=({kind=0,text='sample',target='',background=null,box=null,style=null,radius=false,atomic=false,scale=null,basis=1,fragment=null,family=false}={})=>cat(
  [kind,0,0],string(text),string(target),string(''),string(''),string(''),string(''),string(''),
  [0],background?cat([1],string(background)):[0],[(style?8:0)|(family?16:0)|(radius?32:0)|(atomic?64:0)|(scale===null?0:1)],scale===null?[]:cat(f(scale),[basis]),style??[],family?[0]:[],[0],
  fragment===null?[0]:cat([1],string(fragment)),[0,0,0,0],box?cat([1],box):[0]);
const box=(children,{overlay=[],radius=null,borders=border}={})=>cat(padding,borders,list(overlay),list(children),radius??[]);
const block=values=>cat([0,0,0],list(values),[0],string(''),string(''),[0],string(''),string(''),[0,0,0,0]);
const wire=(values,{flags=4,pending=0}={})=>cat(Buffer.from('DPRY'),[flags],u(0),u(1),[2],string('Meaning'),string(''),string(''),list([block(values)]),u(0),u(0),u(0),u(0),u(0),[pending]);
const swatch=(overrides={})=>run({text:'',background:'#80ffc0',box:box([run({text:nb})]),...overrides});
const cursor=[16,0];
const whiteLink=()=>run({kind:1,text:'white',target:'white',fragment:'Енглески'});
const decodeSpans=bytes=>decode(bytes,{title:'green',language:'English'}).sections[0].blocks[0].spans;

test('box-only owner geometry decodes measured swatch colors and typed box members without dropping the independent action',()=>{
  const values=decodeSpans(wire([swatch({style:cursor}),whiteLink(),swatch({background:'#00ff80'}),swatch({background:'#008040'})]));
  const [first,link]=values;
  assert.equal(first.inline_style.cursor,'help');
  assert.deepEqual(values.filter(v=>v.inline_box_group).map(v=>v.background),['#80ffc0','#00ff80','#008040']);
  assert.deepEqual(first.inline_box_group.border.top,{kind:'solid',width:{unit:'px',value:1},color:{kind:'rgb',value:'#000000'}});
  assert.equal(first.inline_box_group.spans[0].text,nb);
  assert.equal(inlineText(values),nb+'white'+nb+nb);
  assert.equal(link.target,'white');assert.equal(link.target_fragment,'Енглески');
});

test('box-only geometry preserves radius, signed overlay insets and nested nonaction boxes',()=>{
  const overlay=cat([9],length(-1),length(0,2),cleanBorder);
  const value=decodeSpans(wire([swatch({box:box([swatch({radius:true,box:box([run({text:nb})],{radius:length(50,2)})})],{overlay:[overlay]})})]))[0];
  assert.deepEqual(value.inline_box_group.overlays[0].insets,{top:{unit:'px',value:-1},left:{unit:'percent',value:0}});
  assert.deepEqual(value.inline_box_group.spans[0].inline_box_group.radius,{unit:'percent',value:50});
  assert.equal(inlineText([value]),nb);
});

test('box-only profile keeps clean rejection of malformed geometry, actions, metadata, and depth',async()=>{
  for(const bytes of [
    wire([swatch()],{flags:0}),wire([swatch()],{flags:5}),wire([swatch()],{pending:2}),wire([whiteLink()]),
    wire([run({text:'x',radius:true})]),wire([swatch({box:box([])})]),wire([swatch({text:'conflict'})]),
    wire([swatch({box:box([run({kind:3,text:''})])})]),wire([swatch({style:[16,1]})]),
    wire([swatch({kind:1,target:'outer',box:box([whiteLink()])})]),
    wire([swatch({box:box([run({text:'x'})],{overlay:[cat([0],length(1),length(1),cleanBorder)]})})]),
    wire([swatch({radius:true,box:box([run({text:'x'})],{radius:length(3,1)})})]),
    wire([swatch({radius:true,box:box([run({text:'x'})],{radius:length(3),borders:cleanBorder})})]),
    wire([swatch()]).subarray(0,-3),
  ]) assert.throws(()=>decodeSpans(bytes));
  let child=run({text:nb});for(let depth=0;depth<17;depth++)child=swatch({box:box([child])});
  assert.throws(()=>decodeSpans(wire([child])),/Content depth/);
  const valid=wire([swatch()]); const vl=n=>{const v=[];do{v.push((n&127)|(n>=128?128:0));n>>>=7;}while(n);return v;};
  const member=payload=>cat(Buffer.from('WIKBLB08'),[7],Buffer.from('green\0'),vl(payload.length),payload);
  assert.equal((await buildIndex(new RawSource(new Blob([member(valid)])))).rows[0].title,'green');
  await assert.rejects(buildIndex(new RawSource(new Blob([member(wire([swatch()],{flags:5}))]))),/Unsupported owner geometry features/);
});

class Element {
  constructor(tag,text=''){
    this.tagName=tag.toUpperCase();this.children=[];this.value=text;
    this.style={setProperty:(key,value)=>{this.style[key]=value;}};
    this.dataset={};this.attributes={};this.listeners={};
    this.classList={add:(...names)=>{this.className=[this.className??'',...names].join(' ').trim();}};
  }
  append(...nodes){for(const child of nodes)this.children.push(...(child.tagName==='#FRAGMENT'?child.children:[child]));}
  set textContent(value){this.value=value;this.children=[];}
  get textContent(){return this.value+this.children.map(child=>child.textContent).join('');}
  setAttribute(key,value){this.attributes[key]=value;}
  addEventListener(key,value){this.listeners[key]=value;}
}
const all=root=>[root,...root.children.flatMap(all)];
const dom=fn=>{const previous=globalThis.document;globalThis.document={createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),createDocumentFragment:()=>new Element('#fragment')};try{return fn();}finally{globalThis.document=previous;}};
test('rendering retains one inline CSS box, 4 NBSP, cursor and following link ownership',()=>dom(()=>{
  const [value,link]=decodeSpans(wire([swatch({style:cursor}),whiteLink()]));const calls=[];
  const fragment=spans([value,link],(...args)=>calls.push(args));const nodes=all(fragment);
  const boxNode=nodes.find(n=>n.className==='compiled-inline-box');const anchors=nodes.filter(n=>n.tagName==='A');
  assert.deepEqual([boxNode.textContent,boxNode.style.backgroundColor,boxNode.style['border-top'],boxNode.style.cursor,boxNode.style.boxSizing,boxNode.style.boxDecorationBreak],[nb,'#80ffc0','1px solid #000000','help','content-box','slice']);
  assert.equal(boxNode.style.whiteSpace,undefined);
  const coloredText=decodeSpans(wire([swatch(),run({text:'  ',background:'#edffff'})]))[1];
  const painted=all(spans([coloredText])).find(n=>n.style.backgroundColor==='#edffff');
  assert.equal(painted.style.whiteSpace,'pre-wrap');
  assert.equal(anchors.length,1);assert.equal(anchors[0].textContent,'white');
  anchors[0].listeners.click({preventDefault(){}});assert.deepEqual(calls,[['white','Енглески']]);
  value.inline_box_group.border.left.width.value=NaN;assert.throws(()=>validateInlineBoxSpan(value));
}));

test('zero-advance current-color top edge between Japanese text and a separately linked label',()=>{
  const top=cat([2],length(1),[0,0,0,0]);
  const mark=run({text:'',box:box([],{borders:top})});
  const original=wire([run({text:'ひ'}),mark,run({text:'[hì]'}),run({kind:1,text:'Heiban',target:'平板型'})]);
  const values=decodeSpans(original);
  assert.equal(inlineText(values),'ひ[hì]Heiban');
  assert.deepEqual(values[1].inline_box_group.border.top,{kind:'solid',width:{unit:'px',value:1},color:{kind:'current_color'}});
  assert.equal(values[1].inline_box_group.spans.length,0);
  assert.deepEqual(values.filter(s=>s.target).map(s=>[s.text,s.target]),[['Heiban','平板型']]);
  for(const invalid of [
    run({kind:1,target:'never',text:'',box:box([],{borders:top})}),
    run({text:'',box:box([mark,run({text:'x'})])}),
    run({text:'',box:box([],{borders:cat([2],length(2),[0,0,0,0])})}),
    run({text:'',box:box([],{borders:cat([0,2],length(1),[0,0,0])})}),
    run({text:'',box:box([],{borders:cleanBorder})}),
  ])assert.throws(()=>decodeSpans(wire([invalid])));
});

test('DPRY clipped absolute distinguishes initial and article exterior on each occurrence',()=>{
  const hidden='Tooltip time to peak concentrations';
  const clip=(direction,children=[run({text:hidden})])=>cat(run({text:''}).subarray(0,-1),[1,direction],
    length(1),length(1),...Array.from({length:4},()=>length(-1)),list(children));
  const stored=values=>wire(values,{flags:128});
  const before=run({kind:1,text:'Tmax',target:'time to peak concentrations'}),after=run({text:')'});
  for(const flags of [1,2,5,6]){
    const values=decodeSpans(stored([before,clip(flags),after]));
    assert.equal(values[0].target,'time to peak concentrations');
    assert.equal(values[1].kind,'text');
    const box=values[1].clipped_absolute;
    assert.equal(box.static_parent_direction,flags&1?'ltr':'rtl');
    assert.equal(box.containing_block??'initial',flags&4?'article_exterior':'initial');
    assert.deepEqual(box.width,{unit:'px',value:1});
    assert.deepEqual(box.margin.left.length,{unit:'px',value:-1});
    assert.equal(box.children[0].text,hidden);
    assert.equal(values[2].text,')');
  }
  const mixed=decodeSpans(stored([clip(1),clip(6)]));
  assert.equal(mixed[0].clipped_absolute.containing_block??'initial','initial');
  assert.equal(mixed[1].clipped_absolute.containing_block,'article_exterior');
  for(const flags of [0,3,4,7,8,9,0x81,0xff])assert.throws(()=>decode(stored([clip(flags)]),{}));
  for(const children of [[],[run({text:''})],[clip(1)],[run({text:'body\nbreak'})]])assert.throws(()=>decode(stored([clip(5,children)]),{}));
  const valid=stored([clip(5)]),at=valid.indexOf(Buffer.from(hidden));
  assert.ok(at>0);
  assert.throws(()=>decode(valid.subarray(0,at+3),{}));
  assert.throws(()=>decode(stored([before,after]),{}));
});


test('fixed atomic inline box reads the Android geometry suffix and preserves the separate source label',()=>dom(()=>{
  const geometry=cat(length(1.5,1),length(1.5,1),length(1),zero,length(1),zero,[0,0,0,0]);
  assert.equal(geometry.length,34);
  const child=run({text:'\u00a0',scale:.9,style:[8]});
  const owner=(suffix=geometry)=>run({text:'',background:'#ff0000',scale:.9,style:[8],atomic:true,
      box:cat(box([child]),suffix)});
  const after=run({text:'\u00a0Oxygen'});
  const [atom,label]=decodeSpans(wire([owner(),after]));
  assert.equal(atom.inline_box_group.spans[0].text,'\u00a0');
  assert.equal(label.text,'\u00a0Oxygen');
  assert.deepEqual(atom.inline_box_group.atomic_layout.width,{unit:'em',value:1.5});
  const result=spans([atom,label]),element=all(result).find(n=>n.className==='compiled-inline-box');
  assert.deepEqual([element.style.display,element.style.verticalAlign,element.style.boxSizing,
      element.style.width,element.style.height,element.style.marginTop,element.style.marginBottom,
      element.style.backgroundColor,element.textContent],
      ['inline-block','baseline','content-box','1.5em','1.5em','1px','1px','#ff0000','\u00a0']);
  assert.equal(result.textContent,'\u00a0\u00a0Oxygen');
  assert.equal(result.children[0].style.fontSize,'min(10000px, calc(var(--wikidict-normal-body-size) * '+atom.font_scale+'))');
  const ordinary=run({text:'',background:'#ff0000',scale:.9,style:[8],box:box([child])});
  assert.equal(decodeSpans(wire([ordinary,after]))[0].inline_box_group.atomic_layout,undefined);
  assert.throws(()=>decodeSpans(wire([owner(geometry.subarray(0,-1)),after])));
  assert.throws(()=>decodeSpans(wire([owner(cat(length(0,1),geometry.subarray(5))),after])));
  assert.throws(()=>decodeSpans(wire([run({text:'forged',scale:.9,style:[8],atomic:true}),ordinary])));
}));


test('atomic inline box uses its selected normal or font-relative baseline strut',()=>dom(()=>{
  const geometry=cat(length(1.5,1),length(1.5,1),length(1),zero,length(1),zero,[0,2,0]);
  const snapshot=scale=>cat([17],f(scale),[1,16],string(''),string(''),[0,0]);
  const child=run({text:'\u00a0',scale:.9,family:true,style:[8]});
  const member=(suffix)=>wire([run({text:'',background:'#ff0000',scale:.9,family:true,style:[8],atomic:true,
      box:cat(box([child]),geometry,suffix)}),run({text:'\u00a0Oxygen'})]);
  const boxElement=data=>all(spans(decodeSpans(data))).find(n=>n.className==='compiled-inline-box');
  const normal=boxElement(member([0]));
  assert.equal(normal.style.lineHeight,'normal');
  assert.equal(normal.style.whiteSpace,'normal');
  const inherited=boxElement(member(cat([2],f(1.6),snapshot(.9))));
  assert.ok(Math.abs(Number(inherited.style.lineHeight)-1.6)<1e-6);
  assert.equal(inherited.style.fontFamily,'sans-serif');
  assert.equal(inherited.style.textAlign,'center');
  const absolute=boxElement(member(cat([1],f(18.25),[2])));
  assert.equal(absolute.style.lineHeight,'18.25px');
  const bodyRelative=boxElement(member(cat([1],f(1.25),[1])));
  assert.equal(bodyRelative.style.lineHeight,'calc(var(--wikidict-normal-body-size) * 1.25)');
  assert.throws(()=>decodeSpans(member(cat([2],f(1.6),snapshot(1)))));
}));


test('fixed atomic geometry uses its declaring font and keeps the exterior label separate',()=>dom(()=>{
  const geometry=cat(length(2,1),length(1.5,1),length(.25,1),zero,length(.5,1),zero,[1,3,1,0]);
  const emEdge=cat([2],length(.125,1),[0]);
  const emPadding=cat(...Array.from({length:4},()=>length(.25,1)));
  const children=list([run({text:'\u00a0',scale:18,basis:2,style:[8]})]);
  const group=cat(emPadding,emEdge,emEdge,emEdge,emEdge,list([]),children,geometry);
  const values=decodeSpans(wire([
    run({text:'',scale:18,basis:2,style:[8],atomic:true,box:group}),
    run({text:'\u00a0Oxygen'}),
  ]));
  const rendered=spans(values),element=all(rendered).find(n=>n.className==='compiled-inline-box');
  assert.equal(rendered.children[0].style.fontSize,'min(10000px, 18px)');
  assert.equal(element.style.width,'2em');
  assert.equal(element.style.paddingLeft,'0.25em');
  assert.equal(element.style['border-left'],'0.125em solid currentColor');
  assert.equal(element.style.marginTop,'0.25em');
  assert.equal(element.style.marginBottom,'0.5em');
  assert.equal(element.style.verticalAlign,'baseline');
  assert.equal(element.style.boxSizing,'border-box');
  assert.equal(element.style.textAlign,'right');
  assert.equal(element.style.overflowWrap,'break-word');
  assert.equal(element.textContent,'\u00a0');
  assert.equal(rendered.textContent,'\u00a0\u00a0Oxygen');
}));

test('fixed atomic validation rejects unsupported geometry and mismatched declaring fonts',()=>{
  const geometry=cat(length(1.5,1),length(1.5,1),padding,[0,0,0,0]);
  const child=run({text:'\u00a0',scale:.9,style:[8]});
  const owner=(suffix=geometry,options={})=>run({
    text:'',scale:.9,style:[8],atomic:true,box:cat(box([child]),suffix),...options,
  });
  const decoded=()=>decodeSpans(wire([owner()]))[0];
  const reject=mutate=>{const value=decoded();mutate(value);assert.throws(()=>validateInlineBoxSpan(value));};
  for(const field of ['radius','atomic_auto_layout','intrinsic_lines_layout','vertical_align'])
    reject(value=>{value.inline_box_group[field]={};});
  for(const axis of ['width','height']){
    for(const amount of [0,-1,NaN,Infinity])reject(value=>{value.inline_box_group.atomic_layout[axis].value=amount;});
    reject(value=>{value.inline_box_group.atomic_layout[axis].unit='percent';});
  }
  for(const [key,value] of [['box_sizing','auto'],['text_align','justify'],['wrap','anywhere'],['vertical_align','bottom']])
    reject(owner=>{owner.inline_box_group.atomic_layout[key]=value;});
  for(const field of ['small','superscript','underline','strike'])
    reject(value=>{value[field]=true;});
  for(const field of ['font_scale','font_scale_basis','direction','font_family'])
    reject(value=>{value.inline_box_group.spans[0][field]=field==='font_scale'?1:'invalid';});
  for(const text of ['', ' ', '\n', '\u2028'])reject(value=>{value.inline_box_group.spans[0].text=text;});
  reject(value=>{value.inline_box_group.spans[0].inline_box_group=structuredClone(value.inline_box_group);});
  reject(value=>{value.inline_style.font_normalized=false;});
  reject(value=>{value.inline_style.baseline_shift={value:1,font_scale_basis:'css_px'};});
  reject(value=>{value.inline_box_group.atomic_layout.margins.top.value=-1;});
  reject(value=>{value.kind='link';value.target='Oxygen';});
  assert.throws(()=>decodeSpans(wire([owner(geometry,{radius:true})])));
  assert.throws(()=>decodeSpans(wire([owner(geometry,{kind:1,target:'Oxygen'})])));
  assert.throws(()=>decodeSpans(wire([run({text:'',box:box([owner()])})])));
  assert.throws(()=>decodeSpans(wire([run({family:true}),swatch()])),/font policy/);
  for(const feature of [0x20000,0x80000,0x400000]){
    const fixed=wire([owner()]);
    const unsupported=cat(Buffer.from('DPRa'),u(4|feature),fixed.subarray(5));
    assert.throws(()=>decodeSpans(unsupported),/Unsupported responsive presentation features/);
  }
  for(const [offset,invalid] of [[0,2],[30,2],[31,4],[32,2],[33,3]]){
    const suffix=Buffer.from(geometry);suffix[offset]=invalid;
    assert.throws(()=>decodeSpans(wire([owner(suffix)])));
  }
  for(let end=0;end<geometry.length;end++)
    assert.throws(()=>decodeSpans(wire([owner(geometry.subarray(0,end))])));
});

test('fixed atomic matching line heights accept field order and reject snapshot or style mismatches',()=>dom(()=>{
  const geometry=cat(length(1.5,1),length(1.5,1),padding,[0,0,0]);
  const snapshot=cat([17],f(.9),[1,16],string(''),string(''),[0,0]);
  const line=cat(f(1.6),snapshot);
  const style=cat([10,1],line);
  const child=run({text:'\u00a0',scale:.9,family:true,style});
  const data=wire([run({text:'',scale:.9,family:true,style,atomic:true,
    box:cat(box([child]),geometry,[2],line)})]);
  const owner=decodeSpans(data)[0];
  owner.inline_style.line_height.font_relative={font:owner.inline_style.line_height.font_relative.font,
    factor:owner.inline_style.line_height.font_relative.factor};
  validateInlineBoxSpan(owner);
  const element=all(spans([owner])).find(n=>n.className==='compiled-inline-box');
  assert.ok(Math.abs(Number(element.style.lineHeight)-1.6)<1e-6);
  for(const mutate of [
    value=>{value.inline_box_group.atomic_layout.line_height.font_relative.font.small=true;},
    value=>{value.inline_box_group.atomic_layout.line_height.font_relative.factor=-1;},
    value=>{value.inline_box_group.atomic_layout.line_height.font_relative.font.font_normalized=false;},
    value=>{value.inline_box_group.spans[0].inline_style.line_height.font_relative.factor=2;},
  ]){
    const invalid=decodeSpans(data)[0];mutate(invalid);assert.throws(()=>validateInlineBoxSpan(invalid));
  }
}));
