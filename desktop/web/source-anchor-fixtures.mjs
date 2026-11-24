import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {buildIndex,decode} from './blob.js';
import {openSource} from './xz.js';

const root=new URL('./testdata/sr-america/',import.meta.url);
export const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
export const at=(value,path)=>path.reduce((item,key)=>item[key],value);
const oracleBytes=await readFile(new URL('oracle.json',root));
export const oracleSha='3e9c48824d398b177a3ba037f32a4ce4b10f20ed6e6eeae0d207bd33063c1a8a';
assert.equal(sha(oracleBytes),oracleSha);
export const oracle=JSON.parse(oracleBytes);
assert.deepEqual([oracle.title,oracle.page_id,oracle.revision_id],['America',11827,711271]);
const actions=await readFile(new URL('ordered-actions.json',root));
assert.equal(sha(actions),oracle.all_actions_sha256);
export const orderedActions=JSON.parse(actions);

export async function americaFixture(branch){
  const spec=oracle[branch];
  assert.match(spec.file,/^america-dpr[za]\.wikblb$/);
  const bytes=await readFile(new URL(spec.file,root));
  assert.equal(sha(bytes),spec.file_sha256);
  return {...spec,bytes};
}

export const indexMember=bytes=>openSource(new Blob([bytes])).then(buildIndex);

export async function readAmerica(branch){
  const file=await americaFixture(branch);
  const {metadata,rows}=await indexMember(file.bytes);
  assert.equal(rows.length,1);
  const [row]=rows;
  assert.deepEqual([row.title,row.offset,row.length],[oracle.title,file.payload_offset,file.payload_length]);
  const payload=file.bytes.subarray(row.offset,row.offset+row.length);
  assert.equal(sha(payload),file.payload_sha256);
  assert.equal(payload.subarray(0,4).toString(),file.magic);
  assert.equal(payload[file.root_width_tag_offset],3);
  const context={...metadata,title:row.title};
  return {row,raw:file.bytes,payload,context,entry:decode(payload,context)};
}
