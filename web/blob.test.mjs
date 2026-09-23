import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {buildIndex,decode,RawSource} from './blob.js';
import {openSource} from './xz.js';
const fixture=process.env.WIKBLB_FIXTURE || '../../wikidict-android/app/src/debug/assets/English.wikblb';
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
 assert.ok(index.rows.some(x=>x.title==='elephant'));
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
