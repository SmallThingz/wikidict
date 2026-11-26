import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildIndex,decode} from './blob.js';
import {openSource} from './xz.js';
import {validateDescriptionBody} from './validate.js';
import {spans} from './renderer.js';

// R19 is a genuine historical member, whose credit is a local link. These
// controls construct the current native external-credit contract from it;
// they are not a regenerated Writer output or an original-corpus seal join.
const compressed=await readFile(new URL('./testdata/babua/r19-responsive.wikblb.xz',import.meta.url));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
assert.equal(sha(compressed),'b04077322097ea8bcdee4e3ca45f037f376617ff56b64170358f79e6aa775fe5');
const source=await openSource(new Blob([compressed]));
const {rows,metadata}=await buildIndex(source);
assert.deepEqual(rows.map(row=>[row.title,row.offset,row.length]),[['babua',30,4259]]);
const payload=Buffer.from(await source.read(rows[0].offset,rows[0].length));
assert.equal(sha(payload),'e735f12e030813c6e2b8496729fb3f88e9066a78f70409bb0c430f3ce7ed47dc');
const context={...metadata,title:'babua',source_edition:'idwiktionary'};
const legacy=decode(payload,context);
const owner=entry=>entry.sections[1].blocks[2];
const pair=block=>block.description_body.box.blocks[0].spans;
const legacyTitle='Berkas:LL-Q33190 (bug)-Iripseudocorus-Babbua.wav';
const destination='https://id.wiktionary.org/wiki/Berkas:LL-Q33190_(bug)-Iripseudocorus-Babbua.wav';
const string=value=>{const text=Buffer.from(value),size=Buffer.alloc(4);size.writeUInt32LE(text.length);return Buffer.concat([size,text]);};
const oldPrefix=Buffer.concat([string('ⓘ'),string(legacyTitle)]);
const at=payload.indexOf(oldPrefix);
assert.ok(at>=3);assert.equal(payload.indexOf(oldPrefix,at+1),-1);assert.equal(payload[at-3],1);
const wire=target=>Buffer.concat([payload.subarray(0,at-3),Buffer.from([2]),payload.subarray(at-2,at),
  string('ⓘ'),string(target),payload.subarray(at+oldPrefix.length)]);
const current=()=>decode(wire(destination),context);
const fixture=()=>owner(current());

test('Phonos credit: constructed current-contract record decodes with only its typed route changed',()=>{
  const expected=structuredClone(legacy),credit=pair(owner(expected))[1];
  assert.equal(credit.kind,'link');assert.equal(credit.target,legacyTitle);
  credit.kind='external_link';credit.target=destination;
  assert.deepEqual(current(),expected);
});

test('Phonos credit: strict destination refuses unrelated, malformed and mismatched URLs during decode',()=>{
  for(const target of [
    destination.replace('https:','http:'),destination.replace('id.wiktionary.org','example.invalid'),
    destination.replace('id.wiktionary.org','id.wiktionary.org.example.invalid'),
    destination.replace('id.wiktionary.org','id.wiktionary.org:443'),
    destination.replace('id.wiktionary.org','user@id.wiktionary.org'),
    destination.replace('id.wiktionary.org','id--x.wiktionary.org'),
    destination.replace('id.wiktionary.org','-id.wiktionary.org'),
    destination.replace('id.wiktionary.org','id-.wiktionary.org'),
    destination.replace('/wiki/','/w/'),destination.replace('Berkas:','Other:'),
    destination.replace('Babbua.wav','Other.wav'),destination+'?download=1',destination+'#file',
    destination+' ',destination+'\n',destination.replace('/wiki/','\\wiki/'),
    destination.replace('Berkas:','Berkas:%'),destination.replace('Berkas:','Berkas:%GG'),
    destination.replace('Berkas:','Berkas:%FF'),
  ])assert.throws(()=>decode(wire(target),context),/Invalid compiled container/,target);
  const encoded=destination.replace('LL-Q','%4C%4c-Q'),expected=current();
  pair(owner(expected))[1].target=encoded;
  assert.deepEqual(decode(wire(encoded),context),expected);
});

test('Phonos credit: destination, localized title and exact audio owner remain jointly required',()=>{
  const changes=[
    ([,credit])=>{credit.tooltip=null;},([,credit])=>{credit.tooltip='';},
    ([,credit])=>{credit.tooltip=':LL-Q33190 (bug)-Iripseudocorus-Babbua.wav';},
    ([,credit])=>{credit.tooltip='Berkas:';},([,credit])=>{credit.text='info';},
    ([,credit])=>{credit.target_fragment='file';},
    ([,credit])=>{credit.target=destination.replace('Babbua.wav','Other.wav');credit.tooltip=legacyTitle.replace('Babbua.wav','Other.wav');},
    ([button])=>{button.classes=button.classes.replace('wikidict-media ','');},
    ([button])=>{button.classes+=' '+button.classes.split(' ').find(value=>value.startsWith('wikidict-media-file-'));},
    ([button])=>{button.classes=button.classes.replace('wikidict-media-file-4c','wikidict-media-file-4C');},
    ([button])=>{button.classes=button.classes.replace('wikidict-media-file-4c','wikidict-media-file-gc');},
    ([button])=>{button.classes=button.classes.replace('wikidict-media-file-4c','wikidict-media-file-c');},
    ([button])=>{button.classes='wikidict-media';button.target='File:Other.wav';},
    ([button])=>{button.classes='wikidict-media';button.target='Berkas:'+legacyTitle.slice(7);},
    ([button])=>{button.audio_control.presentation='transport';},
    ([,credit])=>{credit.audio_control={presentation:'phonos_button'};},
    ([,credit])=>{credit.superscript=false;},
    ([,credit])=>{credit.inline_style.line_height.font_relative.factor=0;},
  ];
  for(const [index,change] of changes.entries()){
    const block=fixture();change(pair(block));
    assert.throws(()=>validateDescriptionBody(block),/Invalid compiled container/,`case ${index}`);
  }
  const fallback=fixture();pair(fallback)[0].classes='wikidict-media';
  pair(fallback)[0].target=pair(fallback)[0].target.replaceAll(' ','_');
  assert.doesNotThrow(()=>validateDescriptionBody(fallback)); // native owner fallback; full audio validation is separate
});

test('Phonos credit: UTF-8 localized title, encoded path and lowercase hex media owner bind without language guessing',()=>{
  const block=fixture(),[button,credit]=pair(block),file='é 日本.wav';
  button.target='File:'+file;button.classes='wikidict-media wikidict-media-file-'+Buffer.from(file).toString('hex');
  credit.tooltip='Fichier:'+file;credit.target='https://zh-min-nan.wiktionary.org/wiki/Fichier:'+encodeURIComponent(file).replaceAll('%20','_');
  assert.doesNotThrow(()=>validateDescriptionBody(block));
  credit.target=credit.target.replace('%C3%A9','%65%CC%81');
  assert.throws(()=>validateDescriptionBody(block),/Invalid compiled container/); // no Unicode normalization
});

// DOM construction controls establish dispatch ownership, not browser/OS navigation or paint.
class Element{
  constructor(tag,text=''){this.tagName=tag.toUpperCase();this.children=[];this.value=text;this.style={};this.attributes={};this.dataset={};this.listeners={};this.classList={add:(...names)=>{this.className=[this.className??'',...names].join(' ').trim();}};}
  append(...nodes){for(const child of nodes)this.children.push(...(child.tagName==='#FRAGMENT'?child.children:[child]));}
  set textContent(value){this.value=value;this.children=[];}get textContent(){return this.value+this.children.map(child=>child.textContent).join('');}
  setAttribute(key,value){this.attributes[key]=value;}addEventListener(key,value){this.listeners[key]=value;}
}
const nodes=root=>[root,...root.children.flatMap(nodes)];
test('Phonos credit: typed external action avoids local dispatch and legacy action stays local',()=>{
  const previous=globalThis.document;
  globalThis.document={createElement:tag=>new Element(tag),createTextNode:text=>new Element('#text',text),createDocumentFragment:()=>new Element('#fragment')};
  try{
    const credit=pair(fixture())[1],calls=[];
    for(const summary of [false,true]){
      const link=nodes(spans([credit],(...args)=>calls.push(args),false,{audioCredit:credit},summary)).find(node=>node.tagName==='A');
      assert.equal(link.href,destination);assert.equal(link.target,'_blank');assert.equal(link.rel,'noopener noreferrer');
      assert.equal(link.title,legacyTitle);assert.equal(link.textContent,'ⓘ');
      let stops=0,prevented=0;link.listeners.click?.({stopPropagation(){stops++;},preventDefault(){prevented++;}});
      assert.equal(stops,summary?1:0);assert.equal(prevented,0);assert.deepEqual(calls,[]);
    }
    const old=pair(owner(legacy))[1];
    const local=nodes(spans([old],(...args)=>calls.push(args),false,{audioCredit:old})).find(node=>node.tagName==='A');
    assert.equal(local.href,'#'+encodeURIComponent(legacyTitle));
    let prevented=0;local.listeners.click({preventDefault(){prevented++;}});
    assert.equal(prevented,1);assert.deepEqual(calls,[[legacyTitle]]);
  }finally{globalThis.document=previous;}
});
