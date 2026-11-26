import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {decode} from './blob.js';
import {renderEntry} from './renderer.js';
const repository = new URL('../../', import.meta.url);
import {containerDisclosureItems} from './container-disclosure.js';

const captureBytes = readFileSync(new URL('renderer/src/format/testdata/it-disclosure-button-captured.json', repository));
assert.equal(createHash('sha256').update(captureBytes).digest('hex'),
  'c5b0e5998409bf5f26dae8d7dbb9160402b4ea016e07356e317a0e4f94873c4e');
const capture = JSON.parse(captureBytes);

// Synthetic boundary controls only: this deliberately is not an encoder fixture
// or a public encoder roundtrip; the separately retained encoder-fixture check
// covers real encoder bytes and metrics.
const cat = (...values) => Buffer.concat(values.map(x => Array.isArray(x) ? Buffer.from(x) : x));
const u32 = n => { const b=Buffer.alloc(4); b.writeUInt32LE(n); return b; };
const u16 = n => { const b=Buffer.alloc(2); b.writeUInt16LE(n); return b; };
const f32 = n => { const b=Buffer.alloc(4); b.writeFloatLE(n); return b; };
const string = s => cat(u32(Buffer.byteLength(s)), Buffer.from(s));
const list = xs => cat(u32(xs.length), ...xs);
const length = x => cat([x.unit==='px'?0:1], f32(x.value));
const color = x => x.kind==='rgb' ? cat([2], string(x.value)) : [x.kind==='transparent'?1:0];
const names = ['normal','hover','active','hover_active'];
const sides = ['top','right','bottom','left'];
const edgeKinds = ['none','hidden','solid','dotted','inset','outset'];
const run = r => cat(u32(r.start),u32(r.end),...names.map(n=>string(r.paint[n].foreground)),
  [names.reduce((v,n,i)=>v+(r.paint[n].underline?1<<i:0),r.paint.underline_on_focus?16:0)]);
function button(b, changes={}) {
  const edge = e => {
    const [kind]=Object.keys(e), value=e[kind];
    return ['none','hidden'].includes(kind)?[edgeKinds.indexOf(kind)]:
      cat([edgeKinds.indexOf(kind)],length(value.width),[value.paint.rgb?0:1],
        value.paint.rgb?string(value.paint.rgb):[]);
  };
  const line = b.line_height;
  const optional = Number(b.focus_visible!=null) | (Number(b.outline_colors!=null)<<1);
  return cat([changes.appearance??0],string(b.font_family.name),length(b.font_size),u16(b.font_weight),
    [changes.italic??Number(b.font_italic)],
    line.normal?[0]:line.length?cat([2],length(line.length)):cat([1],f32(line.multiplier)),
    ...sides.map(s=>length(b.padding[s])),
    ...names.map(n=>cat(color(b[n].background),...sides.map(s=>edge(b[n].border[s])))),
    [changes.optional??optional],
    b.focus_visible?cat([b.focus_visible.mode==='ua_auto'?1:0],length(b.focus_visible.outline.width),
      color(b.focus_visible.outline.color),length(b.focus_visible.outline.radius),length(b.focus_visible.outline.offset)):[],
    b.outline_colors?cat(color(b.outline_colors.unfocused),color(b.outline_colors.focused)):[]);
}
function disclosure(p, changes={}) {
  const fields=Number(p.foreground!=null)|(Number(p.direction!=null)<<1)|
    (Number(p.expand_run!=null)<<2)|(Number(p.collapse_run!=null)<<3)|(Number(p.button!=null)<<4);
  return cat(u32(p.content_index),[changes.collapsed??Number(p.initially_collapsed)],
    string(p.expand_label),string(p.collapse_label),[Number(p.focus!=null)],
    p.focus?cat([p.focus.mode==='ua_auto'?1:0,Number(p.focus.color!=null)],p.focus.color?color(p.focus.color):[]):[],
    [['inline_flow','float_left','float_right'].indexOf(p.placement??'inline_flow')],
    [changes.fields??fields],p.foreground?color(p.foreground):[],p.direction?[p.direction==='ltr'?0:1]:[],
    p.expand_run?run(p.expand_run):[],p.collapse_run?run(p.collapse_run):[],
    p.button?cat(changes.oldPresence?[1]:[],button(p.button,changes)):[]);
}
const blockPrefix = kind => cat([kind,0,0],u32(0),[0],string(''),string(''),[0],string(''),string(''),[0,0,0,0]);
function probe(p=structuredClone(capture), changes={}) {
  const disc=disclosure(p,changes);
  const child=cat(blockPrefix(13),u32(0),[0],u32(0));
  const body=cat(blockPrefix(13),u32(0),[changes.extension??8],disc,
    list([blockPrefix(0),child]));
  const front=cat(Buffer.from(changes.magic??'DPRa'),u32(changes.features??0x100100),u32(0),u32(1),
    [2],string('IT'),string(''),string(''),u32(1));
  const roots=changes.roots??0;
  const bytes=cat(front,body,u32(0),u32(0),u32(roots),Buffer.alloc(roots*4),u32(0),u32(0),[0]);
  return {bytes,disclosureStart:front.length+blockPrefix(13).length+5,disclosureLength:disc.length};
}
const policy = bytes => decode(bytes,{}).sections[0].blocks[0].container.disclosure;

test('frozen public suffix order decodes authored data and reaches the renderer seam', () => {
  const {bytes}=probe();
  const entry=decode(bytes,{}), value=entry.sections[0].blocks[0].container.disclosure;
  const expected=structuredClone(capture);
  expected.button.font_size.value=Math.fround(expected.button.font_size.value);
  assert.deepEqual(value,expected);
  assert.equal(entry.presentation_version,'DPRa');
  assert.equal(containerDisclosureItems(entry.sections[0].blocks[0].container),5);
  assert.throws(()=>renderEntry(entry,()=>{}),/document is not defined/);
});

test('button local fields and optional two-bit mask reject every unallocated bit', () => {
  for(const bit of [0x20,0x40,0x80])assert.throws(()=>policy(probe(capture,{fields:0x1f|bit}).bytes),/Unknown disclosure fields/);
  for(const bit of [4,8,16,32,64,128])assert.throws(()=>policy(probe(capture,{optional:1|bit}).bytes),/Unknown button optional fields/);
  for(const n of [1,2,255])assert.throws(()=>policy(probe(capture,{appearance:n}).bytes));
  for(const n of [1,2,255])assert.throws(()=>policy(probe(capture,{italic:n}).bytes));
  assert.throws(()=>policy(probe(capture,{collapsed:2}).bytes));
  assert.throws(()=>policy(probe(capture,{oldPresence:true}).bytes));
});

test('both existing capabilities and a real button occurrence are mandatory', () => {
  for(const features of [0x100,0x100000,0,0x100100|0x80000000])
    assert.throws(()=>policy(probe(capture,{features:features>>>0}).bytes));
  assert.throws(()=>policy(probe(capture,{magic:'DPR!'}).bytes),/uncompiled records/);
  const privateNarrow=cat(Buffer.from('DPRZ'),u16(0x100),probe().bytes.subarray(8));
  assert.throws(()=>policy(privateNarrow),/Unsupported positioned container extension/);
  const absent=structuredClone(capture);delete absent.button;
  assert.throws(()=>policy(probe(absent).bytes),/Unsupported legacy container disclosure/);
  const advertised=probe();
  const noButton=cat(advertised.bytes.subarray(0,advertised.disclosureStart-5),
    u32(0x80000),[0,0], // Existing relative-auto positioning, no disclosure extension.
    advertised.bytes.subarray(advertised.disclosureStart+advertised.disclosureLength));
  assert.throws(()=>policy(noButton),/Invalid disclosure button feature census/);
  for(const bit of [1,2,4,32,64,128])assert.throws(()=>policy(probe(capture,{extension:8|bit}).bytes),/Unsupported positioned container extension/);
});

test('every focus/outline combination preserves null versus omitted values', () => {
  for(const focus of [false,true])for(const outlines of [false,true]) {
    const value=structuredClone(capture);
    if(!focus)value.button.focus_visible=null;
    if(outlines)value.button.outline_colors={unfocused:{kind:'rgb',value:'#010203'},focused:{kind:'rgb',value:'#040506'}};
    const decoded=policy(probe(value).bytes);
    assert.deepEqual(decoded.button.focus_visible,value.button.focus_visible);
    assert.equal(Object.hasOwn(decoded.button,'outline_colors'),outlines);
    if(outlines)assert.deepEqual(decoded.button.outline_colors,value.button.outline_colors);
    assert.equal(containerDisclosureItems({blocks:[{}, {kind:'container',container:{}}],disclosure:decoded}),4+Number(focus)+Number(outlines));
  }
});

test('none/hidden borders still require the resolved-border capability and retain the button', () => {
  const value=structuredClone(capture);
  names.forEach((name,i)=>sides.forEach(side=>{value.button[name].border[side]={[i%2?'hidden':'none']:{}};}));
  assert.deepEqual(policy(probe(value).bytes).button.normal.border,value.button.normal.border);
  assert.throws(()=>policy(probe(value,{features:0x100}).bytes));
});

test('invalid typed values, ambiguous focus and child custody fail in the actual decoder', () => {
  const changes=[
    p=>{p.focus={mode:'ua_auto',color:null};},p=>{p.content_index=0;},p=>{p.content_index=2;},
    p=>{p.button.font_family.name='serif';},p=>{p.button.font_size.value=0;},p=>{p.button.font_size.value=Infinity;},
    p=>{p.button.font_size.unit='em';},p=>{p.button.font_weight=700;},p=>{p.button.padding.left.value=-1;},
    p=>{p.button.line_height={multiplier:1};},p=>{p.button.normal.background={kind:'native_theme'};},
    p=>{p.button.normal.border.top={solid:{width:{unit:'px',value:1},paint:{owner_current_color:{}}}};},
    p=>{p.button.focus_visible.outline.radius.value=1;},p=>{p.button.focus_visible.outline.offset.value=NaN;},
    p=>{p.button.outline_colors={unfocused:{kind:'transparent'},focused:{kind:'rgb',value:'#000000'}};},
    p=>{p.expand_run.end=100;},p=>{p.expand_label='bad\nlabel';},
  ];
  for(const mutate of changes){const value=structuredClone(capture);mutate(value);assert.throws(()=>policy(probe(value).bytes));}
  const invalid=probe().bytes;
  const at=invalid.indexOf(Buffer.from('Arial'));assert.ok(at>0);invalid[at]=0xff;
  assert.throws(()=>policy(invalid));
});

test('every synthetic disclosure prefix truncation and trailing payload fails', () => {
  const {bytes,disclosureStart,disclosureLength}=probe();
  for(let end=disclosureStart;end<disclosureStart+disclosureLength;end++)assert.throws(()=>decode(bytes.subarray(0,end),{}));
  assert.throws(()=>decode(cat(bytes,[0]),{}),/Trailing presentation data/);
});

test('actual decoder item budget charges fixed button, runs, focus and optional colors exactly once', () => {
  const value=structuredClone(capture);
  value.button.outline_colors={unfocused:{kind:'rgb',value:'#010203'},focused:{kind:'rgb',value:'#040506'}};
  // Four structural items: section, outer block, paragraph and child container.
  // Six disclosure items: disclosure, button, two label runs, focus, colors.
  // Remaining index values are valid references to section 0; no disk payload.
  const remaining=(1<<20)-4-6;
  assert.doesNotThrow(()=>decode(probe(value,{roots:remaining}).bytes,{}));
  assert.throws(()=>decode(probe(value,{roots:remaining+1}).bytes,{}));
});

test('absent disclosure remains omitted at the old DPRM boundary', () => {
  const child=cat(blockPrefix(13),u32(0),u32(0)); // DPRM has no positioned extension byte.
  const bytes=cat(Buffer.from('DPRM'),u32(0),u32(1),[2],string('IT'),string(''),string(''),list([child]),
    u32(0),u32(0),u32(0),u32(0),u32(0));
  const entry=decode(bytes,{});
  assert.deepEqual(entry.sections[0].blocks[0].container,{style:{},blocks:[]});
  assert.equal(Object.hasOwn(entry.sections[0].blocks[0].container,'disclosure'),false);
});

test('decoded public data builds exactly one button bound to the selected direct child', t => {
  // This DOM double covers production construction and event ownership only.
  // It cannot qualify native keyboard, browser AX, fonts or computed geometry.
  class Element extends EventTarget {
    constructor(tag) {
      super();this.tagName=tag.toUpperCase();this.children=[];this.style={};this.attributes=new Map();
      this.classList={add:(...names)=>{this.className=[this.className??'',...names].join(' ').trim();},
        toggle:(name,on)=>{if(on)this.classList.add(name);}};
    }
    append(...children){for(const child of children){this.children.push(child);if(child instanceof Element)child.parentElement=this;}}
    prepend(...children){this.children.unshift(...children);for(const child of children)if(child instanceof Element)child.parentElement=this;}
    replaceChildren(...children){this.children=[];this.append(...children);}
    set textContent(value){this.children=[String(value)];}
    get textContent(){return this.children.map(x=>typeof x==='string'?x:x.textContent).join('');}
    setAttribute(name,value){this.attributes.set(name,String(value));}
    getAttribute(name){return this.attributes.get(name)??null;}
    removeAttribute(name){this.attributes.delete(name);}
    contains(child){return this===child||this.children.some(x=>x instanceof Element&&x.contains(child));}
    click(){this.dispatchEvent(new Event('click'));}
  }
  const previousElement=Object.getOwnPropertyDescriptor(globalThis,'Element');
  const previousDocument=Object.getOwnPropertyDescriptor(globalThis,'document');
  globalThis.Element=Element;
  globalThis.document={createElement:tag=>new Element(tag),createDocumentFragment:()=>new Element('#fragment'),createTextNode:text=>String(text)};
  t.after(()=>{
    if(previousElement)Object.defineProperty(globalThis,'Element',previousElement);else delete globalThis.Element;
    if(previousDocument)Object.defineProperty(globalThis,'document',previousDocument);else delete globalThis.document;
  });
  const entry=decode(probe().bytes,{title:'IT control',language:'Italian'});
  const before=JSON.stringify(entry);
  const root=renderEntry(entry,()=>assert.fail('Disclosure dispatched an article link'));
  const all=value=>[value,...value.children.filter(x=>x instanceof Element).flatMap(all)];
  const nodes=all(root),buttons=nodes.filter(x=>x.tagName==='BUTTON');
  assert.equal(buttons.length,1);
  const button=buttons[0],content=button.ariaControlsElements[0],owner=button.parentElement;
  assert.equal(button.type,'button');assert.equal(button.textContent,'Mostra');
  assert.ok(owner.children.includes(content));assert.ok(content.className.includes('compiled-container'));
  assert.equal(content.getAttribute('hidden'),'until-found');
  assert.equal(button.getAttribute('aria-expanded'),'false');
  assert.equal(owner.getAttribute('hidden'),null);
  button.click();assert.equal(button.textContent,'Nascondi');
  assert.equal(content.getAttribute('hidden'),null);assert.equal(button.getAttribute('aria-expanded'),'true');
  button.click();content.dispatchEvent(new Event('beforematch'));
  assert.equal(content.getAttribute('hidden'),null);
  assert.equal(JSON.stringify(entry),before);
});
