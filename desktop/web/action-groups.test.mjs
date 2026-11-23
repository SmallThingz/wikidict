import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {decode,buildIndex,RawSource} from './blob.js';
import {validateActionGroupSpan} from './validate.js';
import {spans} from './renderer.js';
import {inlineText,entryClue} from './preview.js';
const cat=(...values)=>Buffer.concat(values.map(value=>Array.isArray(value)?Buffer.from(value):value));
const u=value=>{const bytes=Buffer.alloc(4);bytes.writeUInt32LE(value);return bytes;};
const f=value=>{const bytes=Buffer.alloc(4);bytes.writeFloatLE(value);return bytes;};
const s=value=>cat(u(Buffer.byteLength(value)),Buffer.from(value));
const list=values=>cat(u(values.length),...values);
const run=({kind=0,text='label',target='',flags=0,children=null,scale=null,padding=null}={})=>cat([kind,0,flags],s(text),s(target),s(''),s(''),s(''),s(''),s(''),[0,0,scale===null?0:1],scale===null?[]:cat(f(scale),[0]),[0,0,0,0],padding?cat([1],padding):[0],children===null?[0]:cat([1],list(children)));
const block=values=>cat([0,0,0],list(values),[0],s(''),s(''),[0],s(''),s(''),[0,0,0,0]);
const wire=(values,{pending=0}={})=>cat(Buffer.from('DPRV'),u(0),u(1),[2],s('Meaning'),s(''),s(''),list([block(values)]),u(0),u(0),u(0),u(0),u(0),[pending]);
const target='https://species.wikimedia.org/wiki/Taenia_solium';
const grouped=()=>run({kind:2,text:'',target,children:[run({text:'Taenia',flags:131}),run({text:' ',flags:3}),run({text:'solium',flags:131})]});
const value=()=>decode(wire([grouped()]),{title:'Owner',language:'Tyap'}).sections[0].blocks[0].spans[0];

// The native Tyap interwiki test encodes the original page's token twice to
// exercise adjacent actions with identical targets (p3691/r43671, p3725/r43965).
test('native producer records keep each formatted Tyap link under one action',async()=>{
 for(const [title,label,destination] of [['amput','Taenia solium','Taenia_solium'],['sakhwak','Ptilopachus petrosus','Ptilopachus_petrosus']]){
  const bytes=await readFile(new URL(`../tests/fixtures/tyap-action-groups/tyap-${title}.dprv`,import.meta.url));
  const entry=decode(bytes,{title,language:'Tyap'}),owners=entry.sections[0].blocks[0].spans;
  assert.equal(entry.presentation_version,'DPRV');assert.equal(owners.length,2);
  for(const owner of owners){
   assert.equal(owner.kind,'external_link');assert.equal(owner.target,`https://species.wikimedia.org/wiki/${destination}`);
   assert.equal(inlineText(owner.inline_action_group.spans).trim(),label);
   assert.ok(owner.inline_action_group.spans.every(child=>child.kind==='text'&&child.target===''));
  }
 }
});

test('V action owner retains styled child runs and is required by its header',async()=>{
 const bytes=wire([grouped()]),entry=decode(bytes,{title:'Owner'}),owner=entry.sections[0].blocks[0].spans[0];
 assert.equal(entry.presentation_version,'DPRV');assert.equal(owner.text,'');assert.equal(owner.target,target);assert.deepEqual(owner.inline_action_group.spans.map(child=>[child.kind,child.target,child.text,child.bold,child.italic,child.underline]),[['text','','Taenia',true,true,true],['text','',' ',true,true,false],['text','','solium',true,true,true]]);
 assert.equal(inlineText([owner]),'Taenia solium');assert.equal(entryClue(entry),'Taenia solium');
 for(let end=0;end<bytes.length;end++)assert.throws(()=>decode(bytes.subarray(0,end),{}));
 assert.throws(()=>decode(cat(bytes,[0]),{}));assert.throws(()=>decode(cat(Buffer.from('DPRM'),bytes.subarray(4)),{}));assert.throws(()=>decode(wire([run()]),{}),/DPRV requires inline action payload/);assert.throws(()=>decode(wire([grouped()],{pending:1}),{}),/Unsupported extended-record body feature/);
 const vli=n=>{const out=[];do{let b=n%128;n=Math.floor(n/128);if(n)b|=128;out.push(b);}while(n);return Buffer.from(out);};
 const member=cat(Buffer.from('WIKBLB08\x01\x00Tyap\x00Owner\x00'),vli(bytes.length),bytes),source=new RawSource(new Blob([member])),index=await buildIndex(source);assert.equal(index.rows.length,1);assert.equal(decode(await source.read(index.rows[0].offset,index.rows[0].length),index.metadata).presentation_version,'DPRV');
});

test('V refuses child actions, empty owners and groups, forged nesting and unsupported padding',()=>{
 for(const owner of [run({kind:0,text:'',children:[run()]}),run({kind:2,text:'visible',target,children:[run()]}),run({kind:2,text:'',target,children:[]}),run({kind:2,text:'',target,children:[run({kind:2,target})]}),run({kind:2,text:'',target,children:[run({kind:3,text:''})]}),run({kind:2,text:'',target,children:[grouped()]})])assert.throws(()=>decode(wire([owner]),{}));
 const padding=cat([0],f(1),[1],f(1),list([run({text:'padding'})]));assert.throws(()=>decode(wire([grouped(),run({padding})]),{}),/Unsupported inline padding group/);
 for(const mutate of [x=>x.text='not an owner',x=>x.trail='trail',x=>x.image={file:'x.svg'},x=>x.bold='true',x=>x.role='unknown',x=>x.inline_action_group.spans[0].target='elsewhere',x=>x.inline_action_group.spans[0].text='forced\nbreak',x=>x.inline_action_group.spans[0].classes='wikidict-media',x=>x.inline_action_group.spans[0].foreground='#ABCDEF',x=>x.inline_action_group.extra=true]){const owner=value();mutate(owner);assert.throws(()=>validateActionGroupSpan(owner));}
 for(const mutate of [x=>x.font_scale=0,x=>{x.font_scale=1;x.font_scale_basis='normal_body';},x=>x.code=true,x=>x.inline_action_group.spans[0].ruby={segments:[]}]){const owner=value();mutate(owner);assert.throws(()=>validateActionGroupSpan(owner),/Unsupported/);}
});

// DOM construction controls establish action ownership, not actual browser paint.
class Element{
 constructor(tag,text=''){this.tagName=tag.toUpperCase();this.children=[];this.value=text;this.style={};this.dataset={};this.attributes={};this.listeners={};this.classList={add:(...names)=>{this.className=[this.className??'',...names].join(' ').trim();}};}
 append(...nodes){for(const child of nodes)this.children.push(...(child.tagName==='#FRAGMENT'?child.children:[child]));}
 set textContent(value){this.value=value;this.children=[];}get textContent(){return this.value+this.children.map(child=>child.textContent).join('');}
 setAttribute(key,value){this.attributes[key]=value;}addEventListener(key,value){this.listeners[key]=value;}
}
const nodes=root=>[root,...root.children.flatMap(nodes)];
const dom=fn=>{const previous=globalThis.document;globalThis.document={createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),createDocumentFragment:()=>new Element('#fragment')};try{return fn();}finally{globalThis.document=previous;}};
test('one typed action produces one anchor with its complete human label and styled children',()=>dom(()=>{
 const owner=value(),fragment=spans([owner]),links=nodes(fragment).filter(node=>node.tagName==='A');assert.equal(links.length,1);assert.equal(links[0].textContent,'Taenia solium');assert.equal(links[0].href,target);assert.equal(links[0].target,'_blank');assert.equal(links[0].rel,'noopener noreferrer');assert.equal(links[0].attributes['aria-label'],undefined);assert.equal(nodes(fragment).filter(node=>node.tagName==='U').length,2);
 const adjacent=spans([owner,structuredClone(owner)]);assert.equal(nodes(adjacent).filter(node=>node.tagName==='A').length,2);
 const flat=owner.inline_action_group.spans.map(child=>({...child,kind:'external_link',target}));assert.equal(nodes(spans(flat)).filter(node=>node.tagName==='A').length,3);
 const internal={...owner,kind:'link',target:'Species',target_fragment:'Taxon'},calls=[];const link=nodes(spans([internal],(...parts)=>calls.push(parts))).find(node=>node.tagName==='A');link.listeners.click({preventDefault(){},stopPropagation(){}});assert.deepEqual(calls,[['Species','Taxon']]);
 const blank=structuredClone(owner);blank.inline_action_group.spans=[{...blank.inline_action_group.spans[0],text:' '}];assert.equal(nodes(spans([blank])).find(node=>node.tagName==='A').attributes['aria-label'],target);
}));
test('action declaring context scales child text once while retaining independent styles',()=>dom(()=>{
 const owner=value();owner.font_scale=Math.fround(1.2);owner.inline_action_group.spans.forEach(child=>child.font_scale=Math.fround(1.2));const fragment=spans([owner]),all=nodes(fragment);assert.equal(all.filter(node=>node.style.fontSize==='min(10000px, 1.2000000476837158em)').length,1);assert.equal(all.filter(node=>node.style.fontSize!=null).length,1);assert.ok(all.some(node=>node.style.fontWeight==='bold'));assert.ok(all.some(node=>node.style.fontStyle==='italic'));
}));
