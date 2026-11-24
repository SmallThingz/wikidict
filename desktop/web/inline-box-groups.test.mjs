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
const run=({kind=0,text='sample',target='',background=null,box=null,style=null,radius=false,fragment=null}={})=>cat(
  [kind,0,0],string(text),string(target),string(''),string(''),string(''),string(''),string(''),
  [0],background?cat([1],string(background)):[0],[(style?8:0)|(radius?32:0)],style??[],[0],
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
