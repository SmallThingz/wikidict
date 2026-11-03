// Small, explicitly synthetic compiled records for parser and browser contracts.
const u32=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const string=s=>{const b=Buffer.from(s);return Buffer.concat([u32(b.length),b]);};
export function varuint(n){const bytes=[];do{let b=n%128;n=Math.floor(n/128);if(n)b|=128;bytes.push(b);}while(n);return Buffer.from(bytes);}
const span=(text,target='')=>Buffer.concat([Buffer.from([target?1:0,0,0]),...[text,target,'','','',''].map(string)]);
const spans=(text,target='')=>text?Buffer.concat([u32(1),span(text,target)]):u32(0);
export function presentation(text='Compiled page',preamble='',linkTarget='',media=[]) {
 const block=Buffer.concat([Buffer.from([2,0,0]),spans(text,linkTarget),Buffer.from([0]),string(''),string('1'),Buffer.from([0])]);
 const section=Buffer.concat([Buffer.from([2]),string('Noun'),u32(1),block]);
 return Buffer.concat([Buffer.from('DPR2'),spans(''),u32(1),section,spans(preamble),u32(0),u32(0),u32(0),u32(media.length),...media.map(m=>Buffer.concat([string(m.file),Buffer.from([m.kind==='audio'?1:0]),string(m.caption||'')]))]);
}
const key=(kind,title)=>kind===1||kind===7?title:title.slice(title.indexOf(':')+1);
export function aliasPayload(options={}) {
 const {source='Cats',target='cat',sourceKind=1,targetKind=1,sourceNamespace=sourceKind===1?0:110,targetNamespace=targetKind===1?0:110,fragment='',sourceKey=key(sourceKind,source),targetKey=targetKind?key(targetKind,target):'',compiled=presentation('Compiled alias '+source,'Retained alias preamble')}=options;
 const head=Buffer.alloc(15);head.write('DAL1');head.writeUInt32LE(sourceNamespace,4);head[8]=sourceKind;head[9]=targetNamespace===null?0:1;head.writeUInt32LE(targetNamespace??0,10);head[14]=targetKind??0;
 const fields=[source,sourceKey,target,target,targetKey,fragment,compiled].map(v=>Buffer.isBuffer(v)?v:Buffer.from(v));
 return Buffer.concat([head,...fields.flatMap(v=>[varuint(v.length),v])]);
}
export function dictionaryBlob(kind,records,{language='English',code='en'}={}) {
 const header=[Buffer.from('WIKBLB08'),Buffer.from([kind])];if(kind===1)header.push(Buffer.from(code+'\0'+language+'\0'));
 const rows=records.map(([title,payload])=>({title:Buffer.from(title),payload})).sort((a,b)=>Buffer.compare(a.title,b.title));
 return Buffer.concat([...header,...rows.flatMap(r=>[r.title,Buffer.from([0]),varuint(r.payload.length),r.payload])]);
}
export function aliasCases(){return dictionaryBlob(8,[
 ['1\tCats',aliasPayload()],
 ['1\tLoop A',aliasPayload({source:'Loop A',target:'Loop B',fragment:'Incoming'})],
 ['1\tLoop B',aliasPayload({source:'Loop B',target:'cat',fragment:'Outgoing'})],
 ['1\tMissing',aliasPayload({source:'Missing',target:'not installed'})],
 ['1\tSelf',aliasPayload({source:'Self',target:'Self'})],
 ['1\tTo feature',aliasPayload({source:'To feature',target:'Thesaurus:animal',targetKind:2,targetNamespace:110})],
 ['2\tTo main',aliasPayload({source:'Thesaurus:To main',sourceKind:2,target:'cat',targetKind:1,targetNamespace:0})],
 ['7\tAnnexe:École',aliasPayload({source:'Annexe:École',sourceKind:7,sourceNamespace:100,target:'Annexe:école',targetKind:7,targetNamespace:100})]
]);}
