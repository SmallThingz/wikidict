import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {decode} from './blob.js';
import {validateResponsiveCaptionTable} from './validate.js';
const root=new URL('./testdata/hu-caption/',import.meta.url);
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const manifestBytes=readFileSync(new URL('manifest.json',root));
assert.equal(hash(manifestBytes),'a8bf4678143967bc5f0d539c8faccd1f6fb8e5404fa873403ea97c8dd0b86f7c');
const manifest=JSON.parse(manifestBytes);
assert.equal(manifest.fixtures.length,7);
for(const fixture of manifest.fixtures)test('actual native03 '+fixture.name,()=>{
 const wire=readFileSync(new URL(fixture.name+'.dpr',root));
 const jsonBytes=readFileSync(new URL(fixture.name+'.json',root));
 assert.equal(hash(wire),fixture.binary.sha256);assert.equal(hash(jsonBytes),fixture.json.sha256);
 const record=JSON.parse(jsonBytes);assert.equal(record.dpr_hex,wire.toString('hex'));
 assert.equal(record.expected,fixture.expected);assert.equal(record.original_source_credit,false);
 if(fixture.expected==='reject'){assert.throws(()=>decode(wire,{}));return;}
 assert.equal(wire.length,423);assert.equal(wire.readUInt32LE(4),0x02000000);
 const decoded=decode(wire,{}),actual=decoded.sections[0].blocks[0].table;
 const native=record.stored.entry.sections[0].blocks[0].table;
 validateResponsiveCaptionTable(native);validateResponsiveCaptionTable(actual);
 // Existing Span.jsonStringify omits absent nullable background, while the
 // Web binary decoder explicitly materializes null. Normalize ONLY that
 // authenticated old representation default; all other Table fields compare.
 const expectedTable=structuredClone(native);
 for(const span of [...expectedTable.caption,...expectedTable.rows.flatMap(r=>r.cells.flatMap(c=>c.spans))]){
  if(!Object.hasOwn(span,'background'))span.background=null;
 }
 assert.deepEqual(actual,expectedTable,'complete Table parity with only absent Span.background -> null');
 assert.equal(actual.caption.length,1);assert.equal(actual.rows.length,1);assert.equal(actual.rows[0].cells.length,1);
 const expected=fixture.name==='containing-ltr-grid-rtl'?['ltr','rtl']:['rtl','ltr'];
 assert.deepEqual([actual.caption_viewport.containing_direction,actual.caption_viewport.grid_direction],expected);
});

test('native caption full-font body debts exact84; every missing or extra pending flag refuses',()=>{
 for(const fixture of manifest.fixtures.filter(item=>item.expected!=='reject')){
  const wire=readFileSync(new URL(fixture.name+'.dpr',root));
  assert.equal(hash(wire),fixture.binary.sha256);
  assert.equal(wire.at(-1),0x84);decode(wire,{});
  for(let pending=0;pending<256;pending++)if(pending!==0x84){
   const changed=Buffer.from(wire);changed[changed.length-1]=pending;
   assert.throws(()=>decode(changed,{}),fixture.name+' pending='+pending.toString(16));
  }
 }
});
