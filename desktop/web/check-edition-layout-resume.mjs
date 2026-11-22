// Deterministic checkpoint regression against an unchanged real small member.
// The browser and explicit faults are test doubles; W7 supplies real browser coverage.
// node --experimental-vm-modules desktop/web/check-edition-layout-resume.mjs MEMBER SHA256
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {openAsBlob} from 'node:fs';
import {mkdir, mkdtemp, readFile, writeFile, symlink, unlink, rm} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import vm from 'node:vm';
import {buildIndex, decode, decodeAlias} from './blob.js';
import {openSource} from './xz.js';

const web = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(web, '../..');
const [member, expectedSha] = process.argv.slice(2);
const sha = value => createHash('sha256').update(value).digest('hex');
assert(member && /^[0-9a-f]{64}$/.test(expectedSha || ''), 'Supply a retained member and its publication SHA');
const memberBytes = await readFile(member);
assert.equal(sha(memberBytes), expectedSha);
const original = await buildIndex(await openSource(await openAsBlob(member)));
assert(original.rows.length >= 3 && original.rows.length <= 32, 'Use a real small member');
const sourcePath = path.join(web, 'check-edition-layout.mjs');
const source = await readFile(sourcePath, 'utf8');
const root = await mkdtemp(path.join(repo, '.tmp/layout-resume-test-'));
const editionRoot = path.join(root, 'edition');
await mkdir(editionRoot);
const filename = path.join(editionRoot, 'member.wikblb.xz');
await symlink(path.resolve(member), filename);
const manifest = {edition:'testwiktionary',blobs:1,publication_files:{'member.wikblb.xz':{size:memberBytes.length,sha256:expectedSha}}};
const manifestBytes = JSON.stringify(manifest);
await writeFile(path.join(editionRoot,'complete.json'),manifestBytes);
const inventory = path.join(root,'inventory.tsv');
await writeFile(inventory,`edition\tstatus\toutput_directory\tcomplete_sha256\ntestwiktionary\tbuilt\t${path.relative(repo,editionRoot)}\t${sha(manifestBytes)}\n`);
await writeFile(path.join(root,'local-edition-reader-checks.tsv'),`edition\tselected_complete_sha256\trecords\ntestwiktionary\t${sha(manifestBytes)}\t${original.rows.length}\n`);
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDioAAAAASUVORK5CYII=','base64');
const calls = [];

async function run(output, mode, args = [], changedIndex = false) {
  const attempt = [];
  calls.push(attempt);
  const proc = {argv:['node',sourcePath,inventory,output,'testwiktionary','--checkpoint-rows','1',...args],
    env:{...process.env,CHROMIUM:'/usr/bin/true'},version:process.version,exitCode:undefined};
  const context = vm.createContext({console:{log(){}},process:proc,Buffer,URL,performance,Uint8Array,TextDecoder,TextEncoder,setTimeout,clearTimeout});
  let widthsCreated = 0;
  const browser = {
    version:()=> 'deterministic-browser-double',isConnected:()=>true,close:async()=>{},
    async newPage() {
      const width = [1000,640][widthsCreated++];
      return {route:async()=>{},setContent:async()=>{},addScriptTag:async()=>{},isClosed:()=>false,
        screenshot:async({path:target})=>{await writeFile(target,png);return png;},
        async evaluate(fn,arg) {
          if (fn.name === 'inspectBatch') {
            const {entries} = typeof arg === 'string' ? JSON.parse(arg) : arg;
            return entries.map(entry => {
              const ordinal = original.rows.findIndex(row => (row.source_title ?? row.title) === entry.source_title);
              if (mode === 'mixed' && width === 640 && ordinal === 2) return {error:'controlled render failure'};
              return {figure:null,problems:{},cells:0,links:0,bodyNodes:1,keyboardLink:false};
            });
          }
          if (typeof arg === 'string') return {width:1,height:1,contrasting:1};
          return undefined;
        }};
    }
  };
  const codec = {decode,decodeAlias,async buildIndex(input) {
    const index = await buildIndex(input);
    input.rows = index.rows; input.indexed = true;
    if (changedIndex) index.rows[0] = {...index.rows[0],title:index.rows[0].title+' changed'};
    return index;
  }};
  const xz = {async openSource(blob) {
    const raw = await openSource(blob);
    return {size:raw.size,indexed:false,rows:null,async read(offset,length) {
      if (this.indexed) {
        const ordinal = this.rows.findIndex(row=>row.offset===offset && row.length===length);
        assert(ordinal >= 0); attempt.push(ordinal);
        if (mode === 'all-fail' || (mode === 'mixed' && ordinal === 1)) throw Error('controlled decode read failure');
      }
      return raw.read(offset,length);
    }};
  }};
  const module = new vm.SourceTextModule(source,{context,identifier:sourcePath,initializeImportMeta(meta){meta.url=pathToFileURL(sourcePath).href;}});
  const imports = new Map();
  await module.link(async specifier => {
    if (imports.has(specifier)) return imports.get(specifier);
    const values = specifier === 'playwright' ? {chromium:{launch:async()=>browser}}
      : specifier === 'esbuild' ? {build:async()=>({outputFiles:[{text:'deterministic product double'}]})}
      : specifier === './blob.js' ? codec : specifier === './xz.js' ? xz : await import(specifier);
    const keys = Object.keys(values);
    const linked = new vm.SyntheticModule(keys,function(){for(const key of keys)this.setExport(key,values[key]);},{context});
    imports.set(specifier,linked); return linked;
  });
  await module.evaluate();
  return {code:proc.exitCode ?? 0,attempt};
}
async function state(output) {
  const record = JSON.parse(await readFile(path.join(output,'checkpoint.json'),'utf8'));
  assert.equal(sha(JSON.stringify(record.state)),record.sha256);
  return record.state;
}
async function journal(output,name) {
  const bytes = await readFile(path.join(output,`${name}.jsonl`),'utf8');
  return bytes.trimEnd() ? bytes.trimEnd().split('\n').map(line=>JSON.parse(line)) : [];
}
const stable = value => {
  if (Array.isArray(value)) return value.map(stable);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key])=>!['elapsedSeconds','costMs'].includes(key)).map(([key,v])=>[key,stable(v)]));
};
try {
  for (const mode of ['normal','mixed','all-fail']) {
    const whole = path.join(root,`${mode}-whole`), resumed = path.join(root,`${mode}-resumed`);
    const expected = await run(whole,mode);
    const seen = [];
    let result = await run(resumed,mode,['--pause-after-rows','1']); seen.push(...result.attempt);
    let checkpoints = 0;
    while (result.code === 75) {
      const saved = await state(resumed);
      if (!saved.activeMember) break;
      ++checkpoints;
      assert.equal(saved.nextMember,0);assert.equal(saved.stat.completedMembers,0);
      assert.equal(saved.stat.indexed,original.rows.length);
      assert.equal(saved.stat.byKind[original.metadata.kind],original.rows.length);
      assert.equal(saved.activeMember.nextOrdinal,seen.length);
      assert.equal(saved.activeMember.sha256,expectedSha);
      assert.equal(saved.activeMember.size,memberBytes.length);
      if (mode === 'all-fail') {assert.equal(saved.stat.decoded,0);assert.deepEqual(saved.stat.views,[0,0]);assert.equal(saved.stat.issues,seen.length);}
      for (const name of Object.keys(saved.logs)) {
        const file = path.join(resumed,`${name}.jsonl`);
        await writeFile(file,'UNCOMMITTED-TAIL',{flag:'a'});
      }
      if (mode === 'normal' && checkpoints === 1) {
        await assert.rejects(run(resumed,mode,['--resume'],true),/Resumed member or index changed/);
        const damaged = Buffer.from(memberBytes); damaged[damaged.length-1] ^= 1;
        const corrupt = path.join(root,'corrupt-member'); await writeFile(corrupt,damaged);
        await unlink(filename); await symlink(corrupt,filename);
        await assert.rejects(run(resumed,mode,['--resume']));
        await unlink(filename); await symlink(path.resolve(member),filename);
        assert.equal((await state(resumed)).activeMember.nextOrdinal,saved.activeMember.nextOrdinal);
      }
      result = await run(resumed,mode,['--resume','--pause-after-rows','1']); seen.push(...result.attempt);
    }
    if (result.code === 75) {result=await run(resumed,mode,['--resume']);seen.push(...result.attempt);}
    assert.equal(result.code,expected.code);assert.equal(checkpoints,original.rows.length-1);
    assert.deepEqual(seen,original.rows.map((_,i)=>i));
    assert.deepEqual(expected.attempt,seen);
    for (const name of ['issues','editions','progress']) {
      const a=stable(await journal(whole,name)),b=stable(await journal(resumed,name));
      assert.deepEqual(b,a,`${mode} ordered ${name}`);
      assert.equal(sha(JSON.stringify(a)),sha(JSON.stringify(b)));
    }
    const end=await state(resumed);assert.equal(end.editionIndex,1);assert.equal(end.nextMember,0);assert.equal(end.activeMember,null);
    const [summary]=await journal(resumed,'editions');
    assert.equal(summary.completedMembers,1);assert.equal(summary.indexed,original.rows.length);
    if (mode === 'mixed') {assert.equal(summary.categories.decodeError,1);assert.equal(summary.categories.renderError,1);}
    for (const sample of summary.samples) if(sample.filename) assert.equal(sha(await readFile(path.join(resumed,sample.filename))),sample.sha256);
    console.log(JSON.stringify({mode,records:original.rows.length,checkpoints,returncode:result.code,orderedCountersAndHashesEqual:true,eachOrdinalAttemptedOnce:true}));
  }
  console.log(JSON.stringify({member:path.resolve(member),sha256:expectedSha,checkerSha256:sha(source),realBrowser:false,passed:true}));
} finally {await rm(root,{recursive:true,force:true});}
