import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {buildIndex,decode,RawSource} from './blob.js';
import {openSource} from './xz.js';
const fixture=process.env.WIKBLB_FIXTURE || '../tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb';
const raw=new Uint8Array(await readFile(fixture));
test('binary and seekable multiblock XZ produce identical records',async()=>{
 const encoded=execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
 const a=new RawSource(new Blob([raw])),b=await openSource(new Blob([encoded]));
 assert.equal(b.size,raw.length);assert.ok(b.blocks.length>2);
 const index=await buildIndex(a),compressed=await buildIndex(b);assert.deepEqual(compressed,index);
 for(const row of index.rows){
  const left=decode(await a.read(row.offset,row.length),{...index.metadata,title:row.title});
  const right=decode(await b.read(row.offset,row.length),{...index.metadata,title:row.title});
  assert.deepEqual(right,left);
 }
 assert.ok(index.rows.some(x=>x.title==='cat'));
 for(const offset of [0,65530,131068,raw.length-12])assert.deepEqual(await b.read(offset,12),raw.slice(offset,offset+12));
});
test('concatenated streams and damaged framing',async()=>{
 const first=execFileSync('xz',['-1','-c'],{input:raw.slice(0,100000)}),second=execFileSync('xz',['-1','-c'],{input:raw.slice(100000)});
 const source=await openSource(new Blob([first,new Uint8Array(4),second]));
 assert.deepEqual(await source.read(99990,20),raw.slice(99990,100010));
 await assert.rejects(()=>openSource(new Blob([first.slice(0,-2)])));
 await assert.rejects(()=>buildIndex(new RawSource(new Blob([raw.slice(0,-1)]))));
 assert.throws(()=>decode(new Uint8Array([68,80,82,50]),{}));
 const corrupt=first.slice();corrupt[40]^=32;
 await assert.rejects(async()=>{const x=await openSource(new Blob([corrupt]));await x.read(0,x.size);});
});

test('supplemental namespaces preserve full Unicode titles in raw and XZ',async()=>{
 const raw=new Uint8Array(await readFile('../tests/fixtures/supplemental.wikblb'));
 const packed=execFileSync('xz',['-1','-c'],{input:raw});
 const sources=[new RawSource(new Blob([raw])),await openSource(new Blob([packed]))];
 const indexes=await Promise.all(sources.map(buildIndex));
 assert.deepEqual(indexes[0],indexes[1]);
 assert.equal(indexes[0].metadata.kind,'supplemental');
 assert.equal(indexes[0].metadata.language_code,'');
 assert.equal(indexes[0].metadata.language,null);
 assert.deepEqual(indexes[0].rows.map(x=>x.title),['Annexe:école','Appendix:école']);
 for(const row of indexes[0].rows){
  const entries=await Promise.all(sources.map(async source=>decode(await source.read(row.offset,row.length),{...indexes[0].metadata,title:row.title})));
  assert.deepEqual(entries[0],entries[1]);
  assert.equal(entries[0].title,row.title);
  assert.equal(entries[0].sections[0].blocks[0].spans[0].text,row.title);
 }
 for(const tag of [0,8,255]){const corrupt=raw.slice();corrupt[8]=tag;await assert.rejects(()=>buildIndex(new RawSource(new Blob([corrupt]))));}
});
