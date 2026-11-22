import {sha256} from '@noble/hashes/sha2.js';
import {openSource} from './xz.js';
import {buildIndex} from './blob.js';
import {collections,search,exact,random,readEntry,validatePublicationName,publicationGroup} from './library.js';
const dbp=new Promise((resolve,reject)=>{const r=indexedDB.open('wikidict-binary',1);r.onupgradeneeded=()=>{r.result.createObjectStore('dictionaries',{keyPath:'id'});r.result.createObjectStore('state');};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
async function dbcall(store,mode,fn){const db=await dbp;return new Promise((resolve,reject)=>{const t=db.transaction(store,mode),r=fn(t.objectStore(store));t.oncomplete=()=>resolve(r.result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error||Error('Storage transaction failed'));});}
const loaded=new Map();
let catalog,views;
async function library(){if(!catalog)catalog=await dbcall('dictionaries','readonly',s=>s.getAll());return catalog;}
async function selections(){if(!views)views=collections(await library());return views;}
async function source(id){let value=loaded.get(id);if(!value){const data=await dbcall('dictionaries','readonly',s=>s.get(id));if(!data)throw Error('Dictionary was removed');value={...data,source:await openSource(data.file)};loaded.set(id,value);}return value;}
async function action(type,args){switch(type){
 case 'list':return (await library()).map(({id,name,file,metadata,rows})=>({id,name,bytes:file.size,count:rows.length,...metadata,source_edition:publicationGroup(name)?.split('/')[0]||null}));
 case 'import':{
  if(args.sha256){const hash=sha256.create(),reader=args.file.stream().getReader();while(true){const {value,done}=await reader.read();if(done)break;hash.update(value);}const actual=Array.from(hash.digest(),x=>x.toString(16).padStart(2,'0')).join('');if(actual!==args.sha256.toLowerCase())throw Error('Dictionary checksum mismatch');}
 const src=await openSource(args.file),index=await buildIndex(src),name=args.file.name||args.name||'Dictionary';
  validatePublicationName(name,index.metadata);
  // Validate blocks skipped by record framing before committing the immutable file.
  if(src.verifyAllBlocks)await src.verifyAllBlocks();
  const id=crypto.randomUUID(),data={id,name,file:args.file,...index};
  const next=[...(await library()),data],nextViews=collections(next);
  await dbcall('dictionaries','readwrite',s=>s.put(data));catalog=next;views=nextViews;loaded.set(id,{...data,source:src});return id;
 }
 case 'remove':catalog=null;views=null;loaded.delete(args.id);await dbcall('dictionaries','readwrite',s=>s.delete(args.id));return true;
 case 'search':return search(await selections(),args.query);
 case 'exact':return exact(await selections(),args);
 case 'read':return readEntry(await library(),args,async(d,row)=>(await source(d.id)).source.read(row.offset,row.length));
 case 'random':return random(await selections());
 case 'state':return await dbcall('state','readonly',s=>s.get('learning')) || {};
 case 'saveState':await dbcall('state','readwrite',s=>s.put(args,'learning'));return true;
 default:throw Error('Unknown reader operation');
}}
let queue=Promise.resolve();
self.onmessage=({data:{id,type,args}})=>{queue=queue.then(async()=>{try{self.postMessage({id,value:await action(type,args)});}catch(error){self.postMessage({id,error:error.message});}});};
