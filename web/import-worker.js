import {sha256} from '@noble/hashes/sha2.js';
import {openSource} from './xz.js';
import {buildIndex,decode} from './blob.js';
const dbp=new Promise((resolve,reject)=>{const r=indexedDB.open('wikidict-binary',1);r.onupgradeneeded=()=>{r.result.createObjectStore('dictionaries',{keyPath:'id'});r.result.createObjectStore('state');};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
async function dbcall(store,mode,fn){const db=await dbp;return new Promise((resolve,reject)=>{const t=db.transaction(store,mode),r=fn(t.objectStore(store));t.oncomplete=()=>resolve(r.result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error||Error('Storage transaction failed'));});}
const loaded=new Map();
let catalog;
async function library(){if(!catalog)catalog=await dbcall('dictionaries','readonly',s=>s.getAll());return catalog;}
function prepare(value){if(!value.sorted){for(const row of value.rows)row.normalized=row.title.toLocaleLowerCase();value.sorted=[...value.rows].sort((a,b)=>a.normalized<b.normalized?-1:a.normalized>b.normalized?1:0);}return value;}
function lower(rows,q){let lo=0,hi=rows.length;while(lo<hi){const mid=(lo+hi)>>>1;if(rows[mid].normalized<q)lo=mid+1;else hi=mid;}return lo;}
async function source(id){let value=loaded.get(id);if(!value){const data=await dbcall('dictionaries','readonly',s=>s.get(id));if(!data)throw Error('Dictionary was removed');value={...data,source:await openSource(data.file)};loaded.set(id,value);}return prepare(value);}
function hit(value,row){return {dictionary:value.id,title:row.title,language:value.metadata.language,kind:value.metadata.kind};}
async function action(type,args){switch(type){
 case 'list':return (await library()).map(({id,name,file,metadata,rows})=>({id,name,bytes:file.size,count:rows.length,...metadata}));
 case 'import':{
  if(args.sha256){const hash=sha256.create(),reader=args.file.stream().getReader();while(true){const {value,done}=await reader.read();if(done)break;hash.update(value);}const actual=Array.from(hash.digest(),x=>x.toString(16).padStart(2,'0')).join('');if(actual!==args.sha256.toLowerCase())throw Error('Dictionary checksum mismatch');}
 const src=await openSource(args.file),index=await buildIndex(src);
  // Visit every XZ block to validate it, including blocks skipped by record framing.
  if(src.blocks)for(let i=0;i<src.blocks.length;i++)await src.block(i);
  const id=crypto.randomUUID(),data={id,name:args.file.name||args.name||'Dictionary',file:args.file,...index};
  await dbcall('dictionaries','readwrite',s=>s.put(data));catalog=null;loaded.set(id,{...data,source:src});return id;
 }
 case 'remove':catalog=null;loaded.delete(args.id);await dbcall('dictionaries','readwrite',s=>s.delete(args.id));return true;
 case 'search':{
  const result=[],q=args.query.toLocaleLowerCase();
  for(const d of await library()){const value=await source(d.id);for(let i=lower(value.sorted,q);i<value.sorted.length&&value.sorted[i].normalized.startsWith(q);i++){result.push(hit(value,value.sorted[i]));if(result.length>=80)return result;}}
  return result;
 }
 case 'exact':{for(const d of await library()){const value=await source(d.id),row=value.rows.find(x=>x.title===args.title);if(row)return hit(value,row);}return null;}
 case 'read':{const value=await source(args.dictionary),row=value.rows.find(x=>x.title===args.title);if(!row)throw Error('Word not found');return decode(await value.source.read(row.offset,row.length),{...value.metadata,title:row.title});}
 case 'random':{const dictionaries=await library();const total=dictionaries.reduce((n,d)=>n+d.rows.length,0);if(!total)return null;let pick=Math.floor(Math.random()*total);for(const d of dictionaries){if(pick<d.rows.length)return hit(d,d.rows[pick]);pick-=d.rows.length;}return null;}
 case 'state':return await dbcall('state','readonly',s=>s.get('learning')) || {};
 case 'saveState':await dbcall('state','readwrite',s=>s.put(args,'learning'));return true;
 default:throw Error('Unknown reader operation');
}}
let queue=Promise.resolve();
self.onmessage=({data:{id,type,args}})=>{queue=queue.then(async()=>{try{self.postMessage({id,value:await action(type,args)});}catch(error){self.postMessage({id,error:error.message});}});};
