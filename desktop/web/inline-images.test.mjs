// Source-only hand-framed controls for the selected final C image suffix.
import test from 'node:test';
import assert from 'node:assert/strict';
import {decode,decodeAlias,buildIndex,RawSource} from './blob.js';
import {dictionaryBlob,aliasPayload} from './alias-fixtures.mjs';
import {loadInlineImage,inlineImageActionURL} from './media.js';
const cat=(...v)=>Buffer.concat(v.map(x=>Array.isArray(x)?Buffer.from(x):x));
const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const s=value=>cat(u(Buffer.byteLength(value)),Buffer.from(value));
const image=(flags=13,width=15)=>cat([1],s('Vraagteken-2.svg'),[flags],flags&1?u(width):Buffer.alloc(0),flags&2?u(17):Buffer.alloc(0),flags&4?s(''):Buffer.alloc(0),flags&8?s('תיאור'):Buffer.alloc(0));
const span=(tail=image(),kind=1,legacy=false,text='',trail='')=>cat([kind,0,0],s(text),s(kind===1?'File:Vraagteken-2.svg':''),s(trail),...Array.from({length:4},()=>s('')),[0,0,0],legacy?Buffer.alloc(0):tail);
const spans=(tail=image(),kind=1,text='',trail='')=>cat(u(1),span(tail,kind,false,text,trail));
const block=values=>cat([0,0,0],values,[0],s(''),s(''),[0],s(''),s(''));
const table=(tail=image())=>cat([1,0],spans(tail),u(1),u(2),cat([0,1,0,1,0,0],spans(tail),[0,0,0]),cat([0,1,0,1,0,0],u(0),[0,1],u(1),block(spans(tail)),[0]),[0]);
function wire({magic='DPRC',defaultImage=image(),tail=defaultImage,kind=1,mediaKind=0,missing=false,duplicate=false,mixedDuplicate=false,text='',trail='',file=null}={}){
 const section=cat([2],s('S'),s('S'),s(''),u(2),block(spans(tail,kind,text,trail)),cat([12,0,0],u(0),[0],s(''),s(''),table(defaultImage),s(''),s('')));
 const ref=cat([0],u(1),u(1),s(''),s(''),u(0),[1],u(1),block(spans(defaultImage)));
 const media=cat(s('Vraagteken-2.svg'),[mediaKind],s(''));
 const legacyRef=cat([0],u(2),u(2),s(''),s(''),spans(defaultImage),[0]);
 let bytes=cat(Buffer.from(magic),spans(defaultImage),u(1),section,spans(defaultImage),u(0),u(0),u(2),ref,legacyRef,u(missing?0:duplicate||mixedDuplicate?2:1),missing?Buffer.alloc(0):duplicate?cat(media,media):mixedDuplicate?cat(media,s('Vraagteken-2.svg'),[1],s('')):media);
 if(file!==null){const from=s('Vraagteken-2.svg'),to=s(file),parts=[];let at=0,next;while((next=bytes.indexOf(from,at))>=0){parts.push(bytes.subarray(at,next),to);at=next+from.length;}parts.push(bytes.subarray(at));bytes=Buffer.concat(parts);}
 return bytes;
}
test('image occurrences survive every structural span sink with exact optional JSON',()=>{
 const e=decode(wire(),{}),t=e.sections[0].blocks[1].table;
 const occurrences=[e.display_title[0],e.preamble_spans[0],e.sections[0].blocks[0].spans[0],t.caption[0],t.rows[0].cells[0].spans[0],t.rows[0].cells[1].blocks[0].spans[0],e.references[0].blocks[0].spans[0],e.references[1].spans[0]];
 for(const v of occurrences){assert.equal(v.text,'');assert.equal(v.target,'File:Vraagteken-2.svg');assert.deepEqual(v.image,{file:'Vraagteken-2.svg',width_px:15,alt:'',tooltip:'תיאור'});}
 const absent=decode(wire({tail:image(1)}),{}).sections[0].blocks[0].spans[0].image;assert.equal(Object.hasOwn(absent,'alt'),false);assert.equal(Object.hasOwn(absent,'tooltip'),false);
});
test('malformed dimensions/flags/presence/action/catalog reject',()=>{
 for(const options of [{tail:image(1,0)},{tail:image(16)},{tail:Buffer.from([2])},{kind:3},{missing:true},{duplicate:true},{mixedDuplicate:true},{mediaKind:1},{text:'lost'},{trail:'lost'}])assert.throws(()=>decode(wire(options),{}));
 const bytes=wire();assert.throws(()=>decode(bytes.subarray(0,bytes.length-1),{}));
});
test('canonical identity permits colon/slash/Unicode and rejects malformed matching media files',()=>{
 for(const file of ['File:foo.svg','Image:foo.svg','קובץ/תמונה.svg'])assert.equal(decode(wire({file}),{}).display_title[0].image.file,file);
 for(const file of ['', ' leading.svg','trailing.svg ','under_score.svg','[bad].svg','{bad}.svg','<bad>.svg','bad|name.svg','bad#name.svg','bad\u0000name.svg','bad\u007fname.svg','bad\u0080name.svg','bad\u009fname.svg'])assert.throws(()=>decode(wire({file}),{}));
});
test('legacy B span remains unchanged while C adds exactly one absent-image byte',()=>{
 const b=span(Buffer.alloc(0),0,true),c=span(Buffer.from([0]),0);assert.equal(c.length,b.length+1);assert.deepEqual(c.subarray(0,-1),b);assert.equal(c.at(-1),0);
});
test('unavailable inline images retain distinct authored alt through consent, loading, error and success',async()=>{
 const saved={document:globalThis.document,MutationObserver:globalThis.MutationObserver,fetch:globalThis.fetch,caches:globalThis.caches};
 const observers=[];let fetches=0;
  const element=()=>Object.assign(new EventTarget(),{style:{display:'inline'},dataset:{},attributes:{},textContent:'',isConnected:true,hidden:false,siblings:[],setAttribute(k,v){this.attributes[k]=v;},insertAdjacentElement(_,v){this.siblings.push(v);v.remove=()=>{this.siblings=this.siblings.filter(x=>x!==v);};}});
 const tick=()=>new Promise(resolve=>setImmediate(resolve));
 try{
  globalThis.document={body:{},createElement:element};globalThis.MutationObserver=class{constructor(callback){observers.push(callback);}observe(){}disconnect(){}};
  globalThis.fetch=async()=>{fetches++;throw Error('unexpected consent-off fetch');};
  const images=[{file:'X mark.svg',width_px:15,alt:'איקס',tooltip:'איקס'},{file:'Yes check.svg',width_px:15,alt:'וי',tooltip:'וי'},{file:'Vraagteken-2.svg',width_px:15},{file:'decorative.svg',width_px:15,alt:''}];
  const before=JSON.stringify(images),off=images.map(()=>element());images.forEach((image,i)=>loadInlineImage(off[i],image,{allowImages:false},'hewiktionary'));await tick();
  assert.equal(fetches,0);assert.deepEqual(off.map(el=>el.siblings[0].textContent),['איקס','וי','','']);assert.ok(off.every(el=>el.hidden&&el.style.display==='none'&&el.dataset.mediaState==='disabled'));
  assert.equal(off[0].siblings[0].attributes['aria-label'],'איקס: Images are disabled.');assert.equal(off[1].siblings[0].title,'וי');assert.ok(off.every(el=>!el.siblings[0].textContent.includes('.svg')));
  const rejectors=[];globalThis.fetch=()=>{fetches++;return new Promise((_,reject)=>rejectors.push(reject));};
  const pending=images.slice(0,2).map(()=>element());images.slice(0,2).forEach((image,i)=>loadInlineImage(pending[i],image,{allowImages:true},'hewiktionary'));await tick();
  assert.deepEqual(pending.map(el=>el.siblings[0].textContent),['איקס','וי']);assert.ok(pending.every(el=>el.siblings[0].dataset.mediaState==='loading'&&el.style.display==='none'));
  rejectors.forEach(reject=>reject(Error('controlled missing asset')));await tick();assert.deepEqual(pending.map(el=>el.siblings[0].textContent),['איקס','וי']);assert.ok(pending.every(el=>el.siblings[0].dataset.mediaState==='error'&&el.style.display==='none'));
  globalThis.caches={open:async()=>({match:async()=>null})};globalThis.fetch=async url=>url.includes('/w/api.php')?new Response(JSON.stringify({query:{pages:[{ns:6,title:'File:X mark.svg',imagerepository:'local',imageinfo:[{url:'https://upload.wikimedia.org/wiktionary/he/a/ab/X_mark.svg',width:128,height:214,mime:'image/svg+xml'}]}]}})):new Response(new Uint8Array([1]),{headers:{'Content-Type':'image/svg+xml'}});
  const loaded=element(),geometry=[];loaded.addEventListener('wikidict-image-geometry',event=>geometry.push(event.detail));loadInlineImage(loaded,images[0],{allowImages:true,mediaCacheMb:0},'hewiktionary');
  const readyDeadline=Date.now()+5000;
  while(typeof loaded.src!=='string'){
   assert.notEqual(loaded.dataset.mediaState,'error','Controlled resource failed before src assignment');
   assert.ok(Date.now()<readyDeadline,'Controlled resource did not assign src within five seconds');
   await new Promise(resolve=>setTimeout(resolve,5));
  }
  assert.equal(loaded.siblings[0].textContent,'איקס');assert.ok(loaded.src.startsWith('blob:'));
  assert.deepEqual(geometry,[]);loaded.dispatchEvent(new Event('load'));assert.equal(loaded.siblings.length,0);assert.equal(loaded.hidden,false);assert.equal(loaded.style.display,'inline');assert.equal(loaded.dataset.mediaState,'loaded');assert.equal(loaded.style.width,'15px');assert.equal(loaded.style.height,'25px');
  assert.deepEqual(geometry,[{original:{width:128,height:214},layout:{width:15,height:25}}]);
  loaded.dispatchEvent(new Event('load'));assert.equal(geometry.length,1,'load observer is once-only');
  loaded.isConnected=false;observers.forEach(callback=>callback());assert.equal(JSON.stringify(images),before);
 }finally{Object.assign(globalThis,saved);}
});

// DPRD changes one existing image flag only; old C payloads remain authoritative.
test('DPRD border survives all image sinks while C and unbordered D remain unchanged',()=>{
 const values=e=>{const t=e.sections[0].blocks[1].table;return [e.display_title[0],e.preamble_spans[0],e.sections[0].blocks[0].spans[0],t.caption[0],t.rows[0].cells[0].spans[0],t.rows[0].cells[1].blocks[0].spans[0],e.references[0].blocks[0].spans[0],e.references[1].spans[0]];};
 const bordered=decode(wire({magic:'DPRD',defaultImage:image(29)}),{});
 assert.equal(bordered.presentation_version,'DPRD');
 for(const span of values(bordered)){
  assert.deepEqual(span.image,{file:'Vraagteken-2.svg',width_px:15,alt:'',tooltip:'תיאור',border:true});
  assert.equal(span.target,'File:Vraagteken-2.svg');assert.equal(span.text,'');assert.equal(span.trail,'');
 }
 const old=decode(wire(),{}),plain=decode(wire({magic:'DPRD'}),{});
 assert.ok(values(old).every(span=>!Object.hasOwn(span.image,'border')));
 assert.ok(values(plain).every(span=>!Object.hasOwn(span.image,'border')));
 delete old.presentation_version;delete plain.presentation_version;assert.deepEqual(plain,old);
 for(const flags of [16,29,31])assert.throws(()=>decode(wire({tail:image(flags)}),{}));
 for(const flags of [32,64,128,255])assert.throws(()=>decode(wire({magic:'DPRD',tail:image(flags)}),{}));
 assert.throws(()=>decode(wire({magic:'DPRD',tail:image(17,0)}),{}));
 const truncated=wire({magic:'DPRD',defaultImage:image(29)});assert.throws(()=>decode(truncated.subarray(0,truncated.length-1),{}));
});
test('DPRD capability reaches normal raw import and DAL1 compiled fallback without downgrading',async()=>{
 const payload=wire({magic:'DPRD',defaultImage:image(29)}),raw=dictionaryBlob(1,[['Border',payload]]);
 const source=new RawSource(new Blob([raw])),index=await buildIndex(source);
 assert.equal(index.metadata.language,'English');assert.equal(index.rows.length,1);
 const row=index.rows[0],entry=decode(await source.read(row.offset,row.length),{title:row.title});
 assert.equal(entry.presentation_version,'DPRD');assert.equal(entry.display_title[0].image.border,true);
 const envelope=aliasPayload({source:'Border alias',target:'Border',compiled:payload});
 const aliasSource=new RawSource(new Blob([dictionaryBlob(8,[['1\tBorder alias',envelope]])])),aliases=await buildIndex(aliasSource);
 const aliasRow=aliases.rows[0],alias=decodeAlias(await aliasSource.read(aliasRow.offset,aliasRow.length),aliasRow.raw_key);
 assert.equal(alias.entry.presentation_version,'DPRD');assert.equal(alias.entry.references[0].blocks[0].spans[0].image.border,true);
});

test('File description actions preserve explicit literal title and separate fragment components',()=>{
 const title='File:Other#/%?&Ω.svg',base='https://de.wiktionary.org/wiki/'+encodeURIComponent(title);
 assert.equal(inlineImageActionURL(title,'dewiktionary',''),base);
 assert.equal(inlineImageActionURL(title,'dewiktionary','Part#/%?&Ω'),base+'#'+encodeURIComponent('Part#/%?&Ω'));
 assert.equal(inlineImageActionURL('File:Other#part','dewiktionary'),'https://de.wiktionary.org/wiki/'+encodeURIComponent('File:Other')+'#part');
 assert.equal(inlineImageActionURL('File:Other#','dewiktionary'),'https://de.wiktionary.org/wiki/'+encodeURIComponent('File:Other')+'#');
 assert.equal(inlineImageActionURL(title,null,''),null);
});
