import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {decode,buildIndex,RawSource} from './blob.js';
import {validateRuby,validateRubyOwner} from './validate.js';
import {spans} from './renderer.js';
const Q=new URL('./testdata/ruby/',import.meta.url);
const payload=await readFile(new URL('payload01.bin',Q)),native=JSON.parse(await readFile(new URL('native-response01.json',Q),'utf8'));
const witness=JSON.parse(await readFile(new URL('WITNESS_RESULT01.json',Q),'utf8'));
assert.equal(createHash('sha256').update(payload).digest('hex'),witness.payload.sha256);
assert.equal(createHash('sha256').update(await readFile(new URL('native-response01.json',Q))).digest('hex'),witness.native_response.sha256);
const real=native.entries[0],clone=value=>structuredClone(value);
const rubySpansIn=value=>{
 const out=[];const visit=x=>{if(Array.isArray(x)){for(const y of x)visit(y);}else if(x&&typeof x==='object'){if(x.ruby!=null)out.push(x);for(const[k,y]of Object.entries(x))if(k!=='ruby')visit(y);}};visit(value);return out;
};
const rubyRuns=rubySpansIn(real);assert.equal(rubyRuns.length,6);
const canonical=value=>{
 if(Array.isArray(value))return value.map(canonical);
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).filter(([k,v])=>!(k==='background'&&v===null&&Object.hasOwn(value,'kind'))).map(([k,v])=>[k,canonical(v)]));
 return value;
};
test('genuine original DPRS decodes all six ruby payloads exactly as the native Reader',()=>{
 const entry=decode(payload,witness.metadata),runs=rubySpansIn(entry);assert.equal(entry.presentation_version,'DPRS');assert.equal(runs.length,6);
 assert.deepEqual(canonical(runs.map(x=>x.ruby)),rubyRuns.map(x=>x.ruby));
 // The established web model differs only in query-side organization/aliases,
 // list_path naming, and nullable defaults. Preserve the complete modeled graph.
 const project=(value,root=false)=>{
  if(Array.isArray(value))return value.map(x=>project(x));
  if(!value||typeof value!=='object')return value;
  const result=Object.fromEntries(Object.entries(value).filter(([k])=>!root||!['organization','redirect','alias','presentation_version'].includes(k)).map(([k,v])=>[k==='list_path'?'path':k,project(v)]));
  if(Object.hasOwn(result,'text')&&Object.hasOwn(result,'trail')&&Object.hasOwn(result,'target')){result.background??=null;result.tooltip??=null;if(result.font_scale!==undefined)result.font_scale=Math.fround(result.font_scale);}
  if(Object.hasOwn(result,'depth')&&Object.hasOwn(result,'level')&&Object.hasOwn(result,'spans')){result.feature??=null;result.table??=null;}
  return result;
 };
 assert.deepEqual(project(entry,true),project(real,true));
});
test('DPRS is admitted by the ordinary importer only with a complete validated payload',async()=>{
 const title=Buffer.from(witness.metadata.title),u=n=>{const x=[];do{let b=n%128;n=Math.floor(n/128);if(n)b|=128;x.push(b);}while(n);return Buffer.from(x);};
 const bytes=Buffer.concat([Buffer.from('WIKBLB08\x01\x00Unclassified\x00'),title,Buffer.from([0]),u(payload.length),payload]);
 const index=await buildIndex(new RawSource(new Blob([bytes])));assert.equal(index.rows.length,1);assert.equal(index.rows[0].title,witness.metadata.title);assert.equal(index.metadata.language,'Unclassified');assert.equal(decode(bytes.subarray(index.rows[0].offset),{...index.metadata,title:index.rows[0].title}).sections.length,real.sections.length);
});
test('genuine framing rejects truncation, trailing bytes, a downgraded header, and unknown successors',()=>{
 for(const bytes of [payload.subarray(0,-1),Buffer.concat([payload,Buffer.from([0])]),Buffer.concat([Buffer.from('DPRM'),payload.subarray(4)]),Buffer.concat([Buffer.from('DPRX'),payload.subarray(4)])])assert.throws(()=>decode(bytes,witness.metadata));
});
test('ruby range, level, gap, fallback, owner and media corruption remain refused',()=>{
 const source=rubyRuns[0].ruby;
 const mutations=[r=>r.segments[0].annotations[0].base_count=0,r=>r.segments[0].annotations[0].base_start=1,r=>r.segments[0].annotations[0].level=1,r=>r.segments[0].gap_before=[clone(r.segments[0].bases[0].spans[0])],r=>r.segments[0].bases[0].spans[0].kind='line_break',r=>r.segments[0].bases[0].spans[0].image={file:'x.svg'},r=>r.segments[0].bases[0].spans[0].text='bad\n',r=>r.segments[0].bases[0].spans[0].classes='wikidict-media',r=>r.segments[0].annotations[0].explicit_fallback=false,r=>r.segments[0].annotations[0].owner.foreground='#ABCDEF',r=>r.segments[0].annotations[0].owner.inline_style.line_height.font_relative.font.font_scale=.25];
 for(const mutate of mutations){const value=clone(source);mutate(value);assert.throws(()=>validateRuby(value));}
});
test('ruby preserves multiple bases, ordered disjoint associations and bounded nesting',()=>{
 const source=clone(rubyRuns[0].ruby),segment=source.segments[0];segment.bases.push(clone(segment.bases[0]));segment.annotations[0].base_count=2;validateRuby(source);
 const second=clone(segment.annotations[0]);second.base_start=1;second.base_count=1;segment.annotations[0].base_count=1;segment.annotations.push(second);validateRuby(source);segment.annotations[1].base_start=0;assert.throws(()=>validateRuby(source));
 let value=clone(rubyRuns[0].ruby);
 for(let i=0;i<15;i++){const next=clone(rubyRuns[0].ruby),run=clone(rubyRuns[0]);run.ruby=value;next.segments[0].bases[0].spans=[run];value=next;}
 validateRuby(value);const next=clone(rubyRuns[0].ruby),run=clone(rubyRuns[0]);run.ruby=value;next.segments[0].bases[0].spans=[run];assert.throws(()=>validateRuby(next));
});
// This is a DOM construction unit control. Actual browser font/layout checks
// remain a separate genuine-page paint requirement.
class Element{
 constructor(tag,text=''){this.tagName=tag.toUpperCase();this.children=[];this.value=text;this.style={};this.dataset={};this.attributes={};this.listeners={};this.classList={add:(...v)=>{this.className=[this.className??'',...v].join(' ').trim();}};}
 append(...nodes){for(const n of nodes){if(n.tagName==='#FRAGMENT')this.children.push(...n.children);else this.children.push(typeof n==='string'?new Element('#text',n):n);}}
 set textContent(value){this.value=value;this.children=[];}get textContent(){return this.value+this.children.map(x=>x.textContent).join('');}
 setAttribute(k,v){this.attributes[k]=v;}addEventListener(k,v){this.listeners[k]=v;}
}
const elements=root=>[root,...root.children.flatMap(elements)];
test('HTML ruby retains six native associations, RP fallbacks, actions and single annotation scaling',()=>{
 const saved=globalThis.document;globalThis.document={createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),createDocumentFragment:()=>new Element('#fragment')};
 try{
  const actions=[];const fragment=spans(rubyRuns,(...args)=>actions.push(args));const nodes=elements(fragment),rubies=nodes.filter(x=>x.tagName==='RUBY'),rt=nodes.filter(x=>x.tagName==='RT'),rp=nodes.filter(x=>x.tagName==='RP');assert.equal(rubies.length,6);assert.equal(rt.length,6);assert.equal(rp.length,12);
  for(const annotation of rt){assert.equal(annotation.style.fontSize,'min(10000px, 0.5em)');assert.equal(annotation.style.lineHeight,'1');assert.ok(elements(annotation).filter(x=>x!==annotation).every(x=>x.style.fontSize!=='min(10000px, 0.5em)'));}
  const link=nodes.find(x=>x.tagName==='A');assert.ok(link);link.listeners.click({preventDefault(){},stopPropagation(){}});assert.deepEqual(actions[0],['みぬんが#Yonaguni']);assert.ok(fragment.textContent.includes('女'));assert.ok(fragment.textContent.includes('んが'));
 }finally{globalThis.document=saved;}
});
