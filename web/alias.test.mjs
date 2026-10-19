import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {buildIndex,decodeAlias,RawSource} from './blob.js';
import {openSource} from './xz.js';
import {collections,search,exact,readEntry,publicationGroup,validatePublicationName} from './library.js';
import {aliasPayload,aliasCases,dictionaryBlob,presentation} from './alias-fixtures.mjs';
const compress=raw=>execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
async function dictionary(id,name,raw,xz=false){const source=xz?await openSource(new Blob([compress(raw)])):new RawSource(new Blob([raw]));return {id,name,...await buildIndex(source),source};}
const read=(all,hit)=>readEntry(all,hit,(d,r)=>d.source.read(r.offset,r.length));
const languageName=heading=>createHash('sha256').update(heading,'utf8').digest('hex')+'.wikblb';
const englishName=languageName('English'),germanName=languageName('German');
const ordinary=(language='English',code='en')=>dictionaryBlob(1,[['cat',presentation('Definition in '+language)]],{language,code});

test('DAL1 raw and XZ index and nested compiled presentation agree',async()=>{
 const raw=aliasCases(),a=await dictionary('a','aliases.wikblb',raw),b=await dictionary('b','aliases.wikblb.xz',raw,true);
 assert.deepEqual(a.rows,b.rows);assert.deepEqual(a.metadata,b.metadata);assert.equal(a.metadata.kind,'alias');
 for(const row of a.rows){const x=decodeAlias(await a.source.read(row.offset,row.length),row.raw_key),y=decodeAlias(await b.source.read(row.offset,row.length),row.raw_key);assert.deepEqual(x,y);assert.equal(x.entry.preamble_spans[0].text,'Retained alias preamble');}
 assert.equal(a.rows.find(r=>r.title==='Annexe:École').raw_key,'7\tAnnexe:École');
});

test('leading Unicode BOM remains part of compiled alias and ordinary field identities',async()=>{
 const title='\ufeffCats',target='\ufeffcat',payload=aliasPayload({source:title,target,compiled:presentation('\ufeffCompiled field')});
 const raw=dictionaryBlob(8,[['1\t'+title,payload]]);
 for(const xz of [false,true]){
  const alias=await dictionary('a','enwiktionary-20261001-aliases.wikblb',raw,xz);
  assert.equal(alias.rows[0].title,title);
  const decoded=decodeAlias(await alias.source.read(alias.rows[0].offset,alias.rows[0].length),'1\t'+title);
  assert.equal(decoded.alias.source_key,title);assert.equal(decoded.alias.target_key,target);assert.equal(decoded.entry.sections[0].blocks[0].spans[0].text,'\ufeffCompiled field');
  const main=await dictionary('en','enwiktionary-20261001-'+englishName,dictionaryBlob(1,[[target,presentation('Target with BOM')]]),xz);
  const all=[main,alias],hit=exact(collections(all),{title,context:'en'});assert.equal((await read(all,hit)).title,target);assert.equal((await read(all,hit)).redirect.followed,true);
 }
});

test('core-encoded DAL1 fixture and empty raw/XZ collections retain alias-only selections',async()=>{
 const native=await readFile('../tests/fixtures/alias-cases/aliases.wikblb');
 const a=await dictionary('native','enwiktionary-20261001-aliases.wikblb',native),b=await dictionary('packed','aliases.wikblb.xz',native,true);
 assert.deepEqual(a.rows,b.rows);assert.deepEqual(a.rows.map(row=>row.title).sort(),['Annexe:École','Cats','History of cat','Loop A','Loop B','Missing']);
 for(const xz of [false,true])for(const kind of [2,3,4,5,6,7,8]){
   const empty=await dictionary('empty','enwiktionary-20261001-empty.wikblb',dictionaryBlob(kind,[]),xz);
   assert.equal(empty.rows.length,0);
 }
 for(const xz of [false,true])await assert.rejects(()=>dictionary('empty','enwiktionary-20261001-empty.wikblb',dictionaryBlob(1,[]),xz),/Empty language dictionary/);
 const neutral=exact(collections([a]),{title:'Cats',context:'native'});assert.ok(neutral);assert.equal((await read([a],neutral)).redirect.followed,false);
 const feature=await dictionary('feature','enwiktionary-20261001-thesaurus.wikblb',dictionaryBlob(2,[]));
 const aliases=await dictionary('aliases','enwiktionary-20261001-aliases.wikblb',aliasCases());
 assert.ok(exact(collections([feature,aliases]),{title:'To main',context:'feature'}));
});

test('DAL1 rejects malformed identity, namespace, framing and nested presentation in raw and XZ',async()=>{
 const valid=aliasPayload();
 for(let end=0;end<valid.length;end++)assert.throws(()=>decodeAlias(valid.subarray(0,end),'1\tCats'));
 const variants=[Buffer.concat([valid,Buffer.from([0])]),aliasPayload({sourceNamespace:10}),aliasPayload({targetNamespace:null}),aliasPayload({sourceKind:8}),aliasPayload({targetKind:8}),aliasPayload({sourceKey:'Wrong'}),aliasPayload({targetKey:'Wrong'}),aliasPayload({targetKind:null,targetKey:'cat'}),aliasPayload({fragment:'é'.repeat(128)}),aliasPayload({compiled:Buffer.from('DPR2')}),aliasPayload({compiled:Buffer.from('#REDIRECT [[cat]]')}),aliasPayload({source:'bad\0title'}),aliasPayload({sourceKind:2,source:'no colon',sourceKey:'no colon'})];
 for(const [at,value] of [[9,2],[14,255],[15,0xff]]){const b=Buffer.from(valid);b[at]=value;variants.push(b);}
 const noncanonical=Buffer.concat([valid.subarray(0,15),Buffer.from([0x84,0]),valid.subarray(16)]);variants.push(noncanonical);
 const badUTF=Buffer.from(valid);badUTF[16]=255;variants.push(badUTF);
 assert.throws(()=>decodeAlias(valid,'2\tCats'));assert.throws(()=>decodeAlias(valid,'1\tWrong'));
 for(const payload of variants){const raw=dictionaryBlob(8,[['1\tCats',payload]]);for(const xz of [false,true])await assert.rejects(()=>dictionary('bad','bad.wikblb',raw,xz));}
});

test('alias overlay preserves selected language, namespace, one edge, saved identity and isolation',async()=>{
 const prefix='enwiktionary-20261001-';
 const en=await dictionary('en',prefix+englishName,ordinary()),de=await dictionary('de',prefix+germanName+'.xz',ordinary('German','de'),true);
 const aliases=await dictionary('aliases',prefix+'aliases.wikblb.xz',aliasCases(),true);
 const feature=await dictionary('feature',prefix+'thesaurus.wikblb',dictionaryBlob(2,[['animal',presentation('A thesaurus animal')]]));
 const supplemental=await dictionary('supplemental',prefix+'supplemental.wikblb',dictionaryBlob(7,[['Annexe:école',presentation('Supplemental definition')]]));
 const foreign=await dictionary('foreign','frwiktionary-20261001-'+languageName('French'),ordinary('French','fr'));
 const newer=await dictionary('newer','enwiktionary-20261002-'+englishName,ordinary());
 const all=[en,de,aliases,feature,supplemental,foreign,newer],views=collections(all);
 const cats=search(views,'CATS');assert.equal(cats.length,2);assert.deepEqual(cats.map(x=>x.context),['en','de']);
 for(const hit of cats){const entry=await read(all,JSON.parse(JSON.stringify(hit)));assert.equal(entry.title,'cat');assert.equal(entry.language,hit.language);assert.equal(entry.redirect.followed,true);assert.equal(hit.raw_key,'1\tCats');assert.equal(hit.dictionary,'aliases');}
 assert.equal(exact(views,{title:'Cats',context:'foreign'}),null);assert.equal(exact(views,{title:'Cats',context:'newer'}),null);
 const get=(title,context='en')=>read(all,exact(views,{title,context}));
 const one=await get('Loop A');assert.equal(one.title,'Loop B');assert.equal(one.alias.target_title,'cat');assert.equal(one.alias.fragment,'Outgoing');assert.equal(one.redirect.fragment,'Incoming');assert.equal(one.redirect.followed,true);assert.match(one.sections[0].blocks[0].spans[0].text,/Compiled alias/);
 assert.equal((await get('Self')).title,'Self');assert.equal((await get('Self')).redirect.followed,true);
 assert.equal((await get('Missing')).redirect.followed,false);
 assert.equal((await get('To feature')).kind,'thesaurus');assert.equal((await get('To feature')).navigation_context,'feature');assert.equal((await get('To feature')).source_edition,'enwiktionary');assert.equal((await get('To feature')).source_title,'Thesaurus:animal');assert.equal((await get('animal','feature')).source_title,null);assert.equal((await get('To main','feature')).redirect.followed,false);
 assert.equal((await get('Annexe:École','supplemental')).title,'Annexe:école');
 await assert.rejects(()=>read(all.filter(d=>d.id!=='de'),cats[1]),/Selected dictionary/);
 await assert.rejects(()=>read(all,{...cats[0],context:'foreign'}),/different dictionary/);
 const unknown=await dictionary('unknown','aliases.wikblb',aliasCases());const loose=[en,unknown];const looseHit=exact(collections(loose),{title:'Cats',context:'unknown'});assert.equal((await read(loose,looseHit)).redirect.followed,false);
 const looseChain=await read(loose,exact(collections(loose),{title:'Loop A',context:'unknown'}));assert.equal(looseChain.title,'Loop B');assert.equal(looseChain.redirect.followed,true);assert.equal(looseChain.alias.target_title,'cat');
 assert.equal(looseChain.source_edition,null);assert.equal(looseChain.source_title,'Loop B');
 const looseSelf=await read(loose,exact(collections(loose),{title:'Self',context:'unknown'}));assert.equal(looseSelf.title,'Self');assert.equal(looseSelf.redirect.followed,true);
 assert.equal(publicationGroup(prefix+'aliases.wikblb.xz'),'enwiktionary/20261001');assert.equal(publicationGroup('aliases.wikblb'),null);assert.equal(publicationGroup(prefix+'../aliases.wikblb'),null);
 for(const name of [prefix+'English.wikblb','enwiktionary-20260230-aliases.wikblb','/tmp/'+prefix+'aliases.wikblb',prefix+'unknown.wikblb'])assert.equal(publicationGroup(name),null);
 assert.equal(publicationGroup('enwiktionary-20240229-aliases.wikblb'),'enwiktionary/20240229');
});

test('canonical acquisition basename matches compiled kind and exact UTF-8 language heading',async()=>{
 const prefix='afwiktionary-20261001-';
 for(const heading of ['English','Qafár af','Unclassified','\ufeffEnglish']){
  const metadata={kind:'language',language:heading,language_code:heading==='Unclassified'?'':'af'};
  assert.doesNotThrow(()=>validatePublicationName(prefix+languageName(heading)+'.xz',metadata));
  assert.throws(()=>validatePublicationName(prefix+'0'.repeat(64)+'.wikblb',metadata),/compiled header/);
  assert.throws(()=>validatePublicationName(prefix+'aliases.wikblb',metadata),/compiled header/);
 }
 assert.equal(languageName('Qafár af'),'ea554ca0ecd0803ff93048c2ddf4cc5274283af2024217f18e058c715367e7d8.wikblb');
 for(const [kind,base] of [['alias','aliases'],['supplemental','supplemental'],['sign_gloss','sign-gloss']]){
  assert.doesNotThrow(()=>validatePublicationName(prefix+base+'.wikblb',{kind}));
  assert.throws(()=>validatePublicationName(prefix+englishName,{kind}),/compiled header/);
 }
 const wrong=await dictionary('wrong',prefix+'aliases.wikblb',ordinary());assert.throws(()=>collections([wrong]),/compiled header/);
});

test('collisions, cycles, target identity mismatches and feature-to-main aliases',async()=>{
 const prefix='enwiktionary-20261001-';const en=await dictionary('en',prefix+englishName,ordinary());
 const collision=await dictionary('collision',prefix+'aliases.wikblb',dictionaryBlob(8,[['1\tcat',aliasPayload({source:'cat'})]]));
 assert.throws(()=>collections([en,collision]),/collides/);assert.throws(()=>collections([collision,en]),/collides/);
 const cases=await dictionary('a',prefix+'aliases.wikblb',dictionaryBlob(8,[
  ['1\tA',aliasPayload({source:'A',target:'B'})],['1\tB',aliasPayload({source:'B',target:'A'})],
  ['1\tBad',aliasPayload({source:'Bad',target:'Thesaurus:Target',targetKind:2,targetNamespace:999})],
  ['2\tTarget',aliasPayload({source:'Thesaurus:Target',sourceKind:2,target:'A',targetKind:1,targetNamespace:0})]
 ]));
 const all=[en,cases],views=collections(all);
 assert.equal((await read(all,exact(views,{title:'A',context:'en'}))).title,'B');
 assert.equal((await read(all,exact(views,{title:'B',context:'en'}))).title,'A');
 await assert.rejects(()=>read(all,exact(views,{title:'Bad',context:'en'})),/target identity/);
 const toMainAlias=await read(all,exact(views,{title:'Target',context:'a'}));assert.equal(toMainAlias.title,'A');assert.equal(toMainAlias.redirect.followed,true);assert.equal(toMainAlias.alias.target_title,'B');
 assert.throws(()=>collections([cases,{...cases,id:'duplicate'}]),/Duplicate/);
});
