// WIKBLB08 contains compiled DPR2/DPR3/DPR4/DPR5/DPR6/DPR7 pages or typed DAL1 redirect envelopes.
// A leading U+FEFF belongs to a compiled title or field, not a file BOM.
const utf8 = new TextDecoder('utf-8', {fatal:true,ignoreBOM:true});
const kinds = ['language','thesaurus','citations','reconstruction','rhymes','sign_gloss','supplemental','alias'];
const blocks = ['paragraph','blank','definition','example','quotation','list_item','list_detail','indent','term','heading','preformatted','rule','table'];
const roles = ['normal','label','pronunciation','headword','example','quotation','citation','reference'];
const require = (ok, message='Invalid compiled dictionary') => { if (!ok) throw Error(message); };
export function decode(bytes, metadata) {
  let p=0, budget=1000000, explained=false, colored=false, anchored=false, painted=false, nested=false;
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
  const rgb=()=>{if(!presence())return null;const value=string();require(value.length===7&&/^#[0-9a-f]{6}$/.test(value));return value;};
  const spans=()=>list(painted?33:colored?32:explained?31:27,()=>{
    const kind=tag(['text','link','external_link','line_break']),role=tag(roles),flags=byte();
    const s={kind,role,text:string(),target:string(),trail:string(),language:string(),classes:string(),direction:string(),explanation:explained?string():'',foreground:colored?rgb():null,background:painted?rgb():null};
    ['bold','italic','code','small','superscript','subscript','strike','underline'].forEach((f,i)=>s[f]=!!(flags&(1<<i)));return s;
  });
  const tableValue=depth=>{
    if(!presence())return null;
    require(!nested||depth<=16,'Nested table depth exceeds limit');
    let geometry;
    if(nested){
      const flags=byte();require((flags&~15)===0);
      if(flags){geometry={};for(const [bit,key] of [[1,'border'],[2,'cell_spacing'],[4,'cell_padding']])if(flags&bit)geometry[key]=u16();
        if(flags&8){const unit=tag(['px','percent']),value=u32();require(unit!=='percent'||value<=100);geometry.width={unit,value};}}
    }
    const result={caption:spans(),rows:list(4,()=>({cells:list(nested?11:colored?10:9,()=>{
      const header=presence(),colspan=u16(),rowspan=u16();require(colspan>=1&&colspan<=100&&rowspan>=1&&rowspan<=100);
      const background=colored?rgb():null,values=spans(),cell={header,colspan,rowspan,background,spans:values};
      if(nested){const child=tableValue(depth+1);if(child){require(values.length===0);cell.nested_table=child;}}
      return cell;
    })}))};
    if(geometry)result.geometry=geometry;return result;
  };
  const block=()=>{
    const kind=tag(blocks),depth=byte(),level=byte();const value={kind,depth,level,spans:spans()};
    if(presence()) value.feature={kind:string(),language:string(),data:string(),tail_kind:string(),tail:string()};
    value.path=string();value.number=string();
    const table=tableValue(1);if(table)value.table=table;
    value.anchor=anchored?string():'';value.anchor_fallback=anchored?string():'';
    return value;
  };
  const magic=utf8.decode(take(4));
  require(magic==='DPR2'||magic==='DPR3'||magic==='DPR4'||magic==='DPR5'||magic==='DPR6'||magic==='DPR7','Dictionary contains uncompiled records');
  nested=magic==='DPR7';if(nested)budget=1<<20;painted=magic==='DPR6'||nested;anchored=magic==='DPR5'||painted;colored=magic==='DPR4'||anchored;explained=magic!=='DPR2';
  const entry={...metadata,presentation_version:magic,display_title:spans(),sections:list(anchored?17:9,()=>({level:byte(),title:string(),anchor:anchored?string():'',anchor_fallback:anchored?string():'',blocks:list(anchored?25:17,block)})),preamble_spans:spans()};
  list(29,()=>{string();string();const s=index(entry.sections.length);optional(entry.sections.length);const n=entry.sections[s].blocks.length;
    list(18,(_,sense)=>{index(n);optional(sense);indices(n);indices(n);indices(n);if(presence()){string();string();string();}});
    indices(n);indices(n);indices(entry.sections.length);
  });
  indices(entry.sections.length);
  entry.references=list(20,()=>{const number=u32(),group_number=u32();require(number>0&&group_number>0);const name=string(),group=string();return {number,group_number,name,group,spans:spans()};});
  entry.media=list(9,()=>({file:string(),kind:tag(['image','audio']),caption:string()}));
  require(p===bytes.length,'Trailing presentation data');return entry;
}

export function decodeAlias(bytes, rawKey) {
  const invalid='Invalid compiled alias';
  require(bytes.length>=15 && utf8.decode(bytes.subarray(0,4))==='DAL1',invalid);
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const source_namespace=view.getUint32(4,true),sourceKind=bytes[8],hasNamespace=bytes[9],targetNamespace=view.getUint32(10,true),targetKind=bytes[14];
  require(sourceKind>=1&&sourceKind<=7&&hasNamespace<=1&&targetKind<=7,invalid);
  require(hasNamespace===1||targetNamespace===0,invalid);
  require((sourceKind===1)===(source_namespace===0),invalid);
  if(targetKind)require(hasNamespace===1&&(targetKind===1)===(targetNamespace===0),invalid);
  let p=15;
  const field=()=>{
    let n=0,multiplier=1,count=0,b;
    do{require(p<bytes.length&&count++<8,invalid);b=bytes[p++];n+=(b&127)*multiplier;multiplier*=128;}while(b&128);
    require((count===1||b!==0)&&Number.isSafeInteger(n)&&n<=bytes.length-p,invalid);
    const value=bytes.subarray(p,p+n);p+=n;return value;
  };
  const text=()=>utf8.decode(field());
  const source_title=text(),source_key=text(),xml_target=text(),target_title=text(),target_key=text(),fragmentBytes=field(),fragment=utf8.decode(fragmentBytes),presentation=field();
  require(p===bytes.length&&presentation.length>0,invalid);
  for(const value of [source_title,source_key,xml_target,target_title])require(value.length>0&&!value.includes('\0'),invalid);
  require(!target_key.includes('\0')&&!fragment.includes('\0')&&fragmentBytes.length<=255,invalid);
  const key=(kind,title)=>{if(kind===1||kind===7)return title;const colon=title.indexOf(':');require(colon>=0,invalid);return title.slice(colon+1);};
  require(source_key===key(sourceKind,source_title),invalid);
  require(targetKind?target_key.length>0&&target_key===key(targetKind,target_title):target_key.length===0,invalid);
  require(rawKey===sourceKind+'\t'+source_key,invalid);
  const alias={source_namespace,source_kind:kinds[sourceKind-1],source_title,source_key,xml_target,target_title,target_namespace:hasNamespace?targetNamespace:null,target_kind:targetKind?kinds[targetKind-1]:null,target_key,fragment};
  const entry=decode(presentation,{kind:'alias',language:null,language_code:'',title:source_title});
  entry.alias={xml_target,target_title,fragment};
  entry.redirect={source_title,target_title,fragment,followed:false};
  return {alias,entry};
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
    if(kind==='alias'){
      const {alias}=decodeAlias(await source.read(p,length),title);
      rows.push({title:alias.source_key,raw_key:title,source_kind:alias.source_kind,source_title:alias.source_title,offset:p,length});
    }else{
      const magic=utf8.decode(await source.read(p,4));
      require(magic==='DPR2'||magic==='DPR3'||magic==='DPR4'||magic==='DPR5'||magic==='DPR6'||magic==='DPR7');
      rows.push({title,offset:p,length});
    }
    require(rows.length<=10000000);p+=length;
  }
  require(kind!=='language'||rows.length>0,'Empty language dictionary');return {metadata,rows};
}
export class RawSource {
  constructor(file){this.file=file;this.size=file.size;}
  async read(offset,length){require(offset>=0&&length>=0&&offset+length<=this.size);return new Uint8Array(await this.file.slice(offset,offset+length).arrayBuffer());}
}
