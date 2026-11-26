import {decode,decodeAlias} from './blob.js';
import {sha256} from '@noble/hashes/sha2.js';

// Edition provenance is external to DAL1. Unnamed imports remain independent.
const publicationName=/^([a-z0-9_-]+wiktionary)-(\d{8})-([0-9a-f]{64}|aliases|supplemental|thesaurus|citations|reconstruction|rhymes|sign-gloss)\.wikblb(?:\.xz)?$/;
export function publicationGroup(name='') {
  const match=publicationName.exec(name);
  if(!match)return null;
  const date=match[2],iso=date.slice(0,4)+'-'+date.slice(4,6)+'-'+date.slice(6),parsed=new Date(iso+'T00:00:00Z');
  return Number.isFinite(parsed.getTime())&&parsed.toISOString().slice(0,10)===iso?match[1]+'/'+date:null;
}
export function validatePublicationName(name,metadata) {
  const edition=publicationGroup(name);if(!edition)return;
  const expected=metadata.kind==='language'?Array.from(sha256(new TextEncoder().encode(metadata.language)),b=>b.toString(16).padStart(2,'0')).join(''):metadata.kind==='alias'?'aliases':metadata.kind.replaceAll('_','-');
  if(publicationName.exec(name)[3]!==expected)throw Error('Dictionary filename does not match its compiled header');
}
const rawKey=row=>row.raw_key??row.title;
const group=d=>publicationGroup(d.name);
function makeHit(owner,row,context,sourceEdition=group(context)?.split('/')[0]||null) {
  return {dictionary:owner.id,context:context.id,raw_key:rawKey(row),title:row.title,
    language:context.metadata.language,kind:row.source_kind||owner.metadata.kind,source_edition:sourceEdition};
}
export function collections(dictionaries) {
  for(const d of dictionaries)validatePublicationName(d.name,d.metadata);
  const aliases=dictionaries.filter(d=>d.metadata.kind==='alias'),ordinary=dictionaries.filter(d=>d.metadata.kind!=='alias');
  const seen=new Set(),aliasesByEdition=new Map(),kindsByEdition=new Map();
  for(const owner of aliases){
    const edition=group(owner);
    if(!edition)continue;
    if(!aliasesByEdition.has(edition))aliasesByEdition.set(edition,[]);
    aliasesByEdition.get(edition).push(owner);
    for(const row of owner.rows){
      const key=edition+'\0'+rawKey(row);
      if(seen.has(key))throw Error('Duplicate compiled alias in this edition');
      seen.add(key);
    }
  }
  const views=ordinary.map(context=>{
    const edition=group(context),entries=context.rows.map(row=>({owner:context,row}));
    if(!edition)return {context,entries};
    if(!kindsByEdition.has(edition))kindsByEdition.set(edition,new Set());
    kindsByEdition.get(edition).add(context.metadata.kind);
    const overlays=aliasesByEdition.get(edition);
    if(!overlays)return {context,entries};
    const keys=new Set(context.rows.map(row=>row.title));
    for(const owner of overlays)for(const row of owner.rows)if(row.source_kind===context.metadata.kind){
      if(keys.has(row.title))throw Error('Compiled alias collides with a definition');
      keys.add(row.title);entries.push({owner,row});
    }
    return {context,entries};
  });
  for(const owner of aliases){
    const kinds=kindsByEdition.get(group(owner));
    const entries=owner.rows.filter(row=>!kinds?.has(row.source_kind)).map(row=>({owner,row}));
    if(entries.length)views.push({context:owner,entries});
  }
  for(const view of views){
    const sourceEdition=group(view.context)?.split('/')[0]||null;
    view.hits=view.entries.map(({owner,row})=>{
      const hit=makeHit(owner,row,view.context,sourceEdition);
      hit.normalized=row.title.toLocaleLowerCase();
      return hit;
    });
    view.hits.sort((a,b)=>a.normalized<b.normalized?-1:a.normalized>b.normalized?1:0);
  }
  return views;
}
export function search(views,query,limit=80) {
  const q=query.toLocaleLowerCase(),result=[];
  for(const view of views){
    const rows=view.hits;let lo=0,hi=rows.length;
    while(lo<hi){const mid=(lo+hi)>>>1;if(rows[mid].normalized<q)lo=mid+1;else hi=mid;}
    for(let i=lo;i<rows.length&&rows[i].normalized.startsWith(q);i++){
      const {normalized,...hit}=rows[i];result.push(hit);if(result.length>=limit)return result;
    }
  }
  return result;
}
export function exact(views,args) {
  let candidates=views;
  if(args.context){
    const origin=views.find(view=>view.context.id===args.context);
    if(!origin)return null;
    candidates=[origin];
    const edition=group(origin.context);
    if(edition)candidates.push(...views.filter(view=>view!==origin&&group(view.context)===edition));
  }
  for(const view of candidates){
    const entry=view.entries.find(({row})=>row.title===args.title||row.source_title===args.title);
    if(entry)return makeHit(entry.owner,entry.row,view.context);
  }
  return null;
}
export function random(views) {
  const total=views.reduce((n,v)=>n+v.entries.length,0);if(!total)return null;
  let pick=Math.floor(Math.random()*total);
  for(const view of views){if(pick<view.entries.length){const {owner,row}=view.entries[pick];return makeHit(owner,row,view.context);}pick-=view.entries.length;}
  return null;
}
export async function readEntry(dictionaries,hit,load) {
  const owner=dictionaries.find(d=>d.id===hit.dictionary);
  if(!owner)throw Error('Dictionary was removed');
  const context=dictionaries.find(d=>d.id===(hit.context||hit.dictionary));
  if(!context)throw Error('Selected dictionary was removed');
  const row=owner.rows.find(r=>rawKey(r)===(hit.raw_key??hit.title));
  if(!row)throw Error('Word not found');
  const read=async(d,r)=>{
    const bytes=await load(d,r);
    const value=d.metadata.kind==='alias'?decodeAlias(bytes,rawKey(r)): {entry:decode(bytes,{...d.metadata,title:r.title})};
    value.entry.source_edition=group(d)?.split('/')[0]||null;
    value.entry.source_title=value.alias?value.alias.source_title:['language','supplemental'].includes(d.metadata.kind)?r.title:null;
    return value;
  };
  const source=await read(owner,row);
  source.entry.navigation_context=context.id;
  if(!source.alias)return source.entry;
  const alias=source.alias,edition=group(owner);
  if(owner.id!==context.id&&(!edition||group(context)!==edition||context.metadata.kind!==alias.source_kind))throw Error('Alias selection belongs to a different dictionary');
  if(!alias.target_kind)return source.entry;
  const followed=(entry,navigation=context.id)=>({...entry,source_title:entry.kind==='alias'?entry.source_title:alias.target_title,navigation_context:navigation,redirect:{source_title:alias.source_title,target_title:alias.target_title,fragment:alias.fragment,followed:true}});
  // Read the direct alias target as a compiled page; never recurse through it.
  for(const d of dictionaries)if(d.metadata.kind==='alias'&&(d.id===owner.id||(edition&&group(d)===edition))){
    const target=d.rows.find(r=>r.source_kind===alias.target_kind&&r.title===alias.target_key);
    if(target){
      const value=await read(d,target),next=value.alias;
      if(next.source_namespace!==alias.target_namespace||next.source_kind!==alias.target_kind||next.source_title!==alias.target_title||next.source_key!==alias.target_key)throw Error('Invalid compiled alias target identity');
      const selection=next.source_kind===context.metadata.kind?context:edition&&dictionaries.find(x=>group(x)===edition&&x.metadata.kind===next.source_kind&&x.metadata.kind!=='language');
      return followed(value.entry,selection?.id||d.id);
    }
  }
  if(!edition)return source.entry;
  let target;
  if(context.metadata.kind===alias.target_kind)target=context;
  else if(alias.target_kind==='language')return source.entry;
  else {
    const candidates=dictionaries.filter(d=>group(d)===edition&&d.metadata.kind===alias.target_kind);
    if(candidates.length>1)throw Error('Ambiguous target dictionary');
    target=candidates[0];
  }
  if(!target)return source.entry;
  const targetRow=target.rows.find(r=>r.title===alias.target_key);
  return targetRow?followed((await read(target,targetRow)).entry,target.id):source.entry;
}
