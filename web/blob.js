// WIKBLB08 + DPR2 only. Every record remains binary until requested.
const utf8 = new TextDecoder('utf-8', {fatal:true});
const kinds = ['language','thesaurus','citations','reconstruction','rhymes','sign_gloss'];
const blocks = ['paragraph','blank','definition','example','quotation','list_item','list_detail','indent','term','heading','preformatted','rule','table'];
const roles = ['normal','label','pronunciation','headword','example','quotation','citation','reference'];
const require = (ok, message='Invalid compiled dictionary') => { if (!ok) throw Error(message); };
export function decode(bytes, metadata) {
  let p=0, budget=1000000;
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const take=n=>{require(n>=0 && n<=bytes.length-p);const start=p;p+=n;return bytes.subarray(start,p);};
  const byte=()=>take(1)[0], u16=()=>{const at=p;take(2);return view.getUint16(at,true);}, u32=()=>{const at=p;take(4);return view.getUint32(at,true);};
  const string=()=>{const n=u32();require(n<=32*1024*1024);return utf8.decode(take(n));};
  const count=min=>{const n=u32();require(n<=budget && n<=(bytes.length-p)/min);budget-=n;return n;};
  const list=(min,fn)=>Array.from({length:count(min)},fn);
  const tag=values=>{const n=byte();require(n<values.length);return values[n];};
  const presence=()=>{const n=byte();require(n<2);return n===1;};
  const index=limit=>{const n=u32();require(n<limit);return n;};
  const optional=limit=>{const n=u32();require(n===0xffffffff||n<limit);};
  const indices=limit=>list(4,()=>index(limit));
  const spans=()=>list(27,()=>{
    const kind=tag(['text','link','external_link','line_break']),role=tag(roles),flags=byte();
    const s={kind,role,text:string(),target:string(),trail:string(),language:string(),script:string(),direction:string()};
    ['bold','italic','code','small','superscript','subscript','strike','underline'].forEach((f,i)=>s[f]=!!(flags&(1<<i)));return s;
  });
  const block=()=>{
    const kind=tag(blocks),depth=byte();byte();const value={kind,depth,spans:spans()};
    if(presence()) value.feature={kind:string(),language:string(),data:string(),tail_kind:string(),tail:string()};
    value.path=string();value.number=string();
    if(presence()) value.table={caption:spans(),rows:list(4,()=>({cells:list(9,()=>{const header=presence(),colspan=u16(),rowspan=u16();require(colspan>=1&&colspan<=100&&rowspan>=1&&rowspan<=100);return {header,colspan,rowspan,spans:spans()};})}))};
    return value;
  };
  require(utf8.decode(take(4))==='DPR2','Dictionary contains uncompiled records');
  const entry={...metadata,display_title:spans(),sections:list(9,()=>({level:byte(),title:string(),blocks:list(17,block)})),preamble_spans:spans()};
  list(29,()=>{string();string();const s=index(entry.sections.length);optional(entry.sections.length);const n=entry.sections[s].blocks.length;
    list(18,(_,sense)=>{index(n);optional(sense);indices(n);indices(n);indices(n);if(presence()){string();string();string();}});
    indices(n);indices(n);indices(entry.sections.length);
  });
  indices(entry.sections.length);
  entry.references=list(20,()=>{const number=u32(),group_number=u32();require(number>0&&group_number>0);const name=string(),group=string();return {number,group_number,name,group,spans:spans()};});
  entry.media=list(9,()=>({file:string(),kind:tag(['image','audio']),caption:string()}));
  require(p===bytes.length,'Trailing presentation data');return entry;
}

export async function buildIndex(source) {
  let p=0, buffer=new Uint8Array(), start=-1;
  const byte=async()=>{require(p<source.size,'Truncated dictionary');if(p<start||p>=start+buffer.length){start=p;buffer=await source.read(p,Math.min(256*1024,source.size-p));}return buffer[p++-start];};
  const nul=async()=>{const value=[];while(true){const b=await byte();if(b===0)return {text:utf8.decode(new Uint8Array(value)),raw:value};require(value.length<65536);value.push(b);}};
  const magic=await source.read(0,9);require(utf8.decode(magic.subarray(0,8))==='WIKBLB08','Choose a WIKBLB08 dictionary');
  const kind=kinds[magic[8]-1];require(kind);p=9;
  const metadata={kind,language_code:'',language:null};
  if(kind==='language'){metadata.language_code=(await nul()).text;metadata.language=(await nul()).text;require(metadata.language.length>0);}
  const rows=[];let previous=null;
  while(p<source.size){
    const {text:title,raw}=await nul();require(title.length>0);
    if(previous){let i=0;while(i<Math.min(previous.length,raw.length)&&previous[i]===raw[i])i++;require(i<Math.min(previous.length,raw.length)?previous[i]<raw[i]:previous.length<raw.length,'Unsorted dictionary');}previous=raw;
    let length=0,multiplier=1,n=0,b;
    do{b=await byte();require(n++<8);length+=(b&127)*multiplier;multiplier*=128;}while(b&128);
    require(n===1||b!==0);require(Number.isSafeInteger(length)&&length>=4&&length<=128*1024*1024&&length<=source.size-p);
    require(utf8.decode(await source.read(p,4))==='DPR2');
    rows.push({title,offset:p,length});require(rows.length<=10000000);p+=length;
  }
  require(rows.length>0);return {metadata,rows};
}
export class RawSource {
  constructor(file){this.file=file;this.size=file.size;}
  async read(offset,length){require(offset>=0&&length>=0&&offset+length<=this.size);return new Uint8Array(await this.file.slice(offset,offset+length).arrayBuffer());}
}
