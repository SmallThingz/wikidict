import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {buildIndex,decode} from './blob.js';
import {validateSourceAnchor,validateSourceAnchorDestinations} from './validate.js';
import {at,indexMember,oracle,orderedActions,readAmerica} from './source-anchor-fixtures.mjs';
import {openSource} from './xz.js';

test('original America scope retains separate nonheading owners and all 116 native actions',async()=>{
  const [previous,current]=await Promise.all([readAmerica('baseline'),readAmerica('candidate')]);
  assert.equal(current.payload.readUInt32LE(4),0x08000101);
  assert.equal(previous.payload.readUInt16LE(4),0x0101);
  const restored=structuredClone(current.entry);
  restored.presentation_version=previous.entry.presentation_version;
  for(const [id,owner] of Object.entries(oracle.owners)){
    const value=at(current.entry,owner.path);
    assert.deepEqual([value.kind,value.anchor,value.anchor_fallback],[owner.kind,id,'']);
    assert.equal(value.spans.map(s=>s.text+(s.trail??'')).join('').trim(),owner.visible);
    assert.deepEqual(value.spans.filter(s=>s.kind==='link').map(s=>s.target),[owner.outgoing]);
    assert.equal(at(previous.entry,owner.path).anchor,'');
    at(restored,owner.path).anchor='';
  }
  assert.equal(Object.keys(oracle.owners).length,4);
  assert.deepEqual(restored,previous.entry);
  assert.equal(orderedActions.length,116);
  for(const {path,...expected} of orderedActions){
    const {kind,text,target,target_fragment,trail,explanation}=at(current.entry,path);
    assert.deepEqual({kind,text,target,target_fragment:target_fragment??null,trail,explanation},expected);
  }
  const root=at(current.entry,['sections',3,'blocks',0,'container','style']);
  assert.deepEqual([root.width,root.max_width,root.overflow,root.box_sizing],
    [{max_content:{}},{length:{unit:'percent',value:100}},'hidden','border_box']);
});

test('DPRa source-anchor header and census reject malformed original-derived payloads',async()=>{
  const [previous,current]=await Promise.all([readAmerica('baseline'),readAmerica('candidate')]);
  const withWord=(bytes,word)=>{
    const changed=Buffer.from(bytes);changed.writeUInt32LE(word,4);return changed;
  };
  const widePredecessor=Buffer.concat([Buffer.from('DPRa'),Buffer.alloc(4),previous.payload.subarray(6)]);
  const badHeaders=[0x00000101,0x08800101];
  for(const word of badHeaders){
    const changed=withWord(current.payload,word);
    assert.throws(()=>decode(changed,current.context));
    const raw=Buffer.from(current.raw);
    changed.subarray(0,8).copy(raw,current.row.offset);
    await assert.rejects(()=>indexMember(raw));
  }
  // Indexing accepts the supported inline-destination header. Its advertised
  // per-block destination lists are absent from this unchanged source-anchor body.
  const unusedDestination=withWord(current.payload,0x18000101);
  const indexedDestination=Buffer.from(current.raw);
  unusedDestination.subarray(0,8).copy(indexedDestination,current.row.offset);
  await assert.doesNotReject(()=>indexMember(indexedDestination));
  assert.throws(()=>decode(unusedDestination,current.context));
  const narrow=Buffer.concat([Buffer.from('DPRZ'),current.payload.subarray(4,6),current.payload.subarray(8)]);
  for(const changed of [withWord(widePredecessor,0x08000101),narrow,current.payload.subarray(0,7),
    withWord(current.payload,0x09000101)]){
    assert.throws(()=>decode(changed,current.context));
  }
  const babuaFile=await readFile(new URL('./testdata/babua/r19-responsive.wikblb.xz',import.meta.url));
  const babuaSource=await openSource(new Blob([babuaFile]));
  const {metadata,rows}=await buildIndex(babuaSource);
  const babuaRow=rows.find(row=>row.title==='babua');
  assert.ok(babuaRow);
  const babua=Buffer.from(await babuaSource.read(babuaRow.offset,babuaRow.length));
  const flags=babua.readUInt32LE(4), context={...metadata,title:babuaRow.title};
  assert.equal(flags,0x01002120);
  assert.equal(decode(babua,context).title,'babua');
  assert.throws(()=>decode(withWord(babua,flags|0x08000000),context),/Invalid source anchor feature census/);
  assert.throws(()=>decode(withWord(babua,flags|0x00800000),context),/Unsupported responsive presentation features/);
});

test('source-anchor owners and heading aliases are validated by physical context',async()=>{
  const {entry}=await readAmerica('candidate');
  const nav=at(entry,oracle.owners['Translations-Q30'].path);
  assert.throws(()=>validateSourceAnchor(nav,false));
  assert.throws(()=>validateSourceAnchor({...nav,anchor:'Translations-Q828'},true));
  const ids=Object.keys(oracle.owners).filter(id=>id.startsWith('Енглески:'));
  const first=oracle.owners[ids[0]].path;
  const sense=at(entry,first);
  assert.doesNotThrow(()=>validateSourceAnchor({...sense,list_path:'#'},true));
  assert.throws(()=>validateSourceAnchor({...sense,list_path:'*'},true));
  assert.throws(()=>validateSourceAnchor({...nav,list_path:'#'},true));
  const duplicate=structuredClone(entry);
  at(duplicate,first).anchor=ids[1];
  assert.throws(()=>validateSourceAnchorDestinations(duplicate),/Duplicate nonheading source anchor/);
  assert.throws(()=>validateSourceAnchor({...at(entry,first),anchor:'English:_Q0'},true));
  const collided=structuredClone(entry);
  collided.sections[0].anchor_fallback=ids[0];
  assert.throws(()=>validateSourceAnchorDestinations(collided),/collides with a heading/);
});
