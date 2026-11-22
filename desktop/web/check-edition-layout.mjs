// node check-edition-layout.mjs <local-editions.tsv> <new-output-dir> <edition> [...]
// Writes a summary per edition and one JSON line per failed/candidate check.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createReadStream, openAsBlob} from 'node:fs';
import {mkdir, open, readFile, realpath, rename, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
import {build} from 'esbuild';
import {buildIndex, decode, decodeAlias} from './blob.js';
import {openSource} from './xz.js';

const web = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(web, '../..');
const widths = [1000, 640];
if (process.argv.slice(2).join(' ') === '--help') {
  console.log('node desktop/web/check-edition-layout.mjs INVENTORY.tsv NEW_OUTPUT_DIR EDITION... [--resume] [--pause-after-members N] [--figure-witness FILE.json]');
  console.log('A fresh directory records an atomic checkpoint after each member. --resume reuses completed members under the same inputs and renderer. --pause-after-members N stops cleanly with exit 75 for a bounded run.');
  console.log('Reads an existing local edition inventory and its sibling Reader checks, then writes editions.jsonl, issues.jsonl, progress.jsonl and sampled viewport PNGs. Exit 2 means enumeration or a required layout check was incomplete.');
  process.exit(0);
}
const [inventory, destination, ...editions] = process.argv.slice(2);
function option(name, takesValue = false) {
  const index = editions.indexOf(name);
  if (index < 0) return null;
  const removed = editions.splice(index, takesValue ? 2 : 1);
  if (takesValue) assert(removed[1], `Missing value for ${name}`);
  return takesValue ? removed[1] : true;
}
const resume = option('--resume');
const pause = option('--pause-after-members', true);
if (pause !== null) assert(/^[1-9]\d*$/.test(pause) && Number.isSafeInteger(Number(pause)));
let processedThisInvocation = 0;
let figureWitness;
const flag = editions.indexOf('--figure-witness');
if (flag >= 0) {
  assert(flag === editions.length - 2, '--figure-witness requires a final JSON file argument');
  const [, file] = editions.splice(flag, 2);
  figureWitness = JSON.parse(await readFile(file, 'utf8'));
}
assert(inventory && destination && editions.length && new Set(editions).size === editions.length,
  'Expected inventory TSV, fresh output directory, and distinct edition names');
const out = path.resolve(destination);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
async function fileDigest(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
const inventoryBytes = await readFile(inventory);
const [header, ...lines] = inventoryBytes.toString('utf8').trimEnd().split('\n');
assert.equal(header, 'edition\tstatus\toutput_directory\tcomplete_sha256');
const selections = new Map(lines.map(line => { const row = line.split('\t'); return [row[0], row]; }));
// Native Reader counts distinct resolved destinations. Web coverage visits each stored body, including redirect envelopes.
const readerTable = await readFile(path.join(path.dirname(inventory), 'local-edition-reader-checks.tsv'));
const [readerHead, ...readerLines] = readerTable.toString('utf8').trimEnd().split('\n');
const columns = readerHead.split('\t');
const readColumn = key => {const i = columns.indexOf(key); assert(i >= 0); return i;};
const [editionCol, hashCol, countCol] = ['edition','selected_complete_sha256','records'].map(readColumn);
const expectedCounts = new Map(readerLines.map(line => {
  const fields = line.split('\t');
  return [fields[editionCol], {sha: fields[hashCol], count: fields[countCol]}];
}));
const selected = editions.map(id => {
  assert(/^[a-z0-9_-]+wiktionary$/.test(id));
  const row = selections.get(id);
  assert(row && ['built','empty'].includes(row[1]) && /^[0-9a-f]{64}$/.test(row[3]), `Missing built selection ${id}`);
  return row;
});
// Never create audit files inside an edition, including through a symlink.
const parent = await realpath(path.dirname(out));
const outputPath = path.join(parent, path.basename(out));
for (const [, , relative] of selections.values()) {
  if (!relative || relative === '-') continue;
  const root = path.resolve(repo, relative);
  if (outputPath === root || outputPath.startsWith(root + path.sep)) throw Error('Output inside edition');
}
if (!resume) await mkdir(out, {mode: 0o700});
assert.equal(await realpath(out), outputPath, 'Output directory must not be a symlink');
const directory = await open(out, 'r');
// flock(1) locks the inherited open file description, which this process retains.
const lock = spawnSync('flock', ['-n','3'], {stdio:['ignore','ignore','inherit',directory.fd]});
assert.equal(lock.status, 0, 'Layout output is in use or cannot be locked');
const checkpointPath = path.join(out, 'checkpoint.json');
let saved;
if (resume) {
  const {state, sha256} = JSON.parse(await readFile(checkpointPath,'utf8'));
  assert.equal(digest(JSON.stringify(state)),sha256,'Damaged checkpoint');
  saved=state;
}
const journals = {};
async function journal(name) {
  const filename = path.join(out, `${name}.jsonl`);
  const handle = await open(filename, resume ? 'a+' : 'wx');
  const hash = createHash('sha256');
  const prefix = saved?.logs[name];
  let bytes = 0;
  if (resume) {
    assert(Number.isSafeInteger(prefix?.bytes) && prefix.bytes >= 0 && prefix.bytes <= (await handle.stat()).size);
    if (prefix.bytes) for await (const chunk of createReadStream(filename,{end:prefix.bytes-1})) hash.update(chunk);
    assert.equal(hash.copy().digest('hex'), prefix.sha256, `Committed ${name} journal changed`);
    bytes = prefix.bytes;
  }
  return journals[name] = {
    handle, async writeFile(line) {await handle.writeFile(line); hash.update(line); bytes += Buffer.byteLength(line);},
    sync: () => handle.sync(), close: () => handle.close(),
    position: () => ({bytes, sha256:hash.copy().digest('hex')})
  };
}
const failures = await journal('issues'), summary = await journal('editions'), progress = await journal('progress');
const productBundle = await build({stdin: {contents: "export {renderEntry} from './renderer.js'; export {mediaView,loadInlineImage,inlineImageActionURL} from './media.js';", resolveDir: web}, bundle: true, format: 'iife', globalName: 'Product', write: false});
const js = productBundle.outputFiles[0].text;
const css = await readFile(path.join(web, 'style.css'), 'utf8');
const font = await readFile(path.join(web, 'reader.ttf'));
const browser = await chromium.launch({executablePath: process.env.CHROMIUM || '/opt/brave-bin/brave', headless: true, args: ['--no-sandbox']});

// Executed inside the real browser. Only compact counts and defect samples cross back.
async function inspectBatch({entries, edition, measureFigure = false}) {
  const normalize = value => value.normalize('NFC').replace(/\s+/gu, ' ').trim();
  const main = document.querySelector('main');
  const results = [];
  for (const entry of entries) {
    try {
      main.replaceChildren();
      window.auditActions = [];
      const settings = {allowImages: false, allowAudio: false};
      main.replaceChildren(Product.renderEntry(entry, (...args) => window.auditActions.push(args), settings,
        (m, c) => Product.mediaView(m, settings, edition, c),
        (el, img, occurrence) => Product.loadInlineImage(el, img, settings, edition, occurrence),
        (target, fragment) => Product.inlineImageActionURL(target, edition, fragment)));
      for (const el of main.querySelectorAll('details')) el.open = true;
      // Product figure sizing runs in a queued microtask after DOM attachment.
      await Promise.resolve();
      const problems = {};
      const text = normalize(main.innerText); // forces style/layout on this record
      if (!main.querySelector('h1')?.getBoundingClientRect().height) problems.missingHeading = true;
      const expected = new Set();
      function visit(value) {
        if (!value || typeof value !== 'object') return;
        if (['text', 'link', 'external_link'].includes(value.kind) && typeof value.text === 'string' && value.font_scale !== 0) {
          const fragment = normalize(value.text + (value.trail || ''));
          if (fragment.length > 2) expected.add(fragment);
        }
        for (const child of Object.values(value)) visit(child);
      }
      visit(entry.sections); visit(entry.references);
      let missing = 0;
      for (const fragment of expected) if (!text.includes(fragment)) {
        if (++missing <= 4) (problems.missingTextExamples ??= []).push(fragment.slice(0, 120));
      }
      if (missing) problems.missingTextCandidates = missing;
      if (document.documentElement.scrollWidth > innerWidth + 1) problems.pageOverflow = true;
      const cells = main.querySelectorAll('th,td');
      const overflowing = [...cells].filter(el => el.scrollWidth > el.clientWidth + 1).length;
      if (overflowing) problems.cellOverflowCandidates = overflowing;
      const links = [...main.querySelectorAll('a')].filter(a => a.getClientRects().length);
      const unnamed = links.filter(a => !normalize(a.textContent || a.getAttribute('aria-label') || [...a.querySelectorAll('img,[role="img"]')].map(x=>x.alt || x.getAttribute('aria-label') || '').join(' '))).length;
      if (unnamed) problems.unnamedLinkCandidates = unnamed;
      const walker = document.createTreeWalker(main, NodeFilter.SHOW_TEXT);
      let bodyNodes = 0, outside = 0, splitWords = 0, node;
      while ((node = walker.nextNode())) {
        const owner = node.parentElement;
        if (!normalize(node.data) || owner.closest('h1,.entry-language,summary,footer,script,style') || parseFloat(getComputedStyle(owner).fontSize) === 0) continue;
        const range = document.createRange(); range.selectNodeContents(node);
        const rects = [...range.getClientRects()].filter(r => r.width && r.height);
        if (!rects.length) continue;
        ++bodyNodes;
        if (rects.some(r => r.left < -.5 || r.right > innerWidth + .5)) ++outside;
        if (rects.length < 2) continue;
        for (const word of node.data.matchAll(/[\p{Script=Latin}\p{M}]{3,32}/gu)) {
          range.setStart(node, word.index); range.setEnd(node, word.index + word[0].length);
          if (range.getClientRects().length >= Math.ceil(word[0].length / 2)) ++splitWords;
        }
      }
      if (outside) problems.outsideViewportCandidates = outside;
      if (splitWords) problems.fragmentedWordCandidates = splitWords;
      if (expected.size && !bodyNodes) problems.emptyVisibleBody = true;
      let figure = null;
      if (measureFigure) {
        const frame = main.querySelector('figure.compiled-figure');
        const caption = frame?.querySelector('figcaption');
        if (caption) {
          const words = [];
          const iterator = document.createTreeWalker(caption, NodeFilter.SHOW_TEXT);
          let part;
          while ((part = iterator.nextNode())) for (const m of part.data.matchAll(/[\p{L}\p{M}]+/gu)) {
            const r = document.createRange(); r.setStart(part, m.index); r.setEnd(part, m.index + m[0].length);
            words.push({text:m[0],lines:new Set([...r.getClientRects()].map(rect=>rect.top)).size});
          }
          figure = {caption:caption.innerText, imageBoxWidth:frame.querySelector('.compiled-figure-image').getBoundingClientRect().width, words};
        }
      }
      results.push({figure, problems, cells: cells.length, links: links.length, bodyNodes, keyboardLink: links.some(a => a.getAttribute('href')?.startsWith('#') && normalize(a.textContent))});
    } catch (e) { results.push({error: String(e.message || e)}); }
  }
  return results;
}

async function inspectEntries(page, edition, entries) {
  try { return await page.evaluate(inspectBatch, {edition, entries}); }
  catch (e) {
    if (page.isClosed() || !browser.isConnected()) throw e;
    if (entries.length === 1) return [{error: String(e.message || e)}];
    const half = Math.ceil(entries.length / 2);
    return [...await inspectEntries(page, edition, entries.slice(0, half)),
      ...await inspectEntries(page, edition, entries.slice(half))];
  }
}

async function sample(page, payload, filename, keyboard) {
  const [rendered] = await page.evaluate(inspectBatch, payload);
  await page.evaluate(async () => {scrollTo(0, 0); await document.fonts.ready; await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));});
  const bytes = await page.screenshot({path: path.join(out, filename)});
  // Inspect the sampled compositor image. Count changed pixels against the
  // main surface; the layout assertions above operate on DOM geometry only.
  const frameHandle=await open(path.join(out,filename),'r'); try {await frameHandle.sync();} finally {await frameHandle.close();}
  const pixels = await page.evaluate(async encoded => {
    const data = Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
    const image = await createImageBitmap(new Blob([data], {type:'image/png'}));
    const canvas = document.createElement('canvas'); canvas.width=image.width; canvas.height=image.height;
    const ctx=canvas.getContext('2d'); ctx.drawImage(image,0,0); image.close();
    const rgb=ctx.getImageData(0,0,canvas.width,canvas.height).data;
    let contrasting=0;
    for(let y=0;y<canvas.height;y++) for(let x=0;x<canvas.width-20;x++) {
      const i=(y*canvas.width+x)*4;
      if(Math.max(Math.abs(rgb[i]-rgb[0]),Math.abs(rgb[i+1]-rgb[1]),Math.abs(rgb[i+2]-rgb[2]))>40) ++contrasting;
    }
    return {width:canvas.width,height:canvas.height,contrasting};
  }, bytes.toString('base64'));
  if (!rendered.error) assert(pixels.contrasting>0,'Sampled viewport has no contrasting pixels');
  const result = {filename, sha256: digest(bytes), bytes: bytes.length, pixels};
  if (rendered.error) return {...result, renderError:rendered.error};
  if (keyboard) {
    const link = page.locator('main a[href^="#"]').filter({hasText: /\S/}).first();
    await link.focus();
    const href = await link.getAttribute('href');
    assert(await link.evaluate(el => el === document.activeElement));
    const state = () => ({actions:window.auditActions.slice(), hash:location.hash, focused:document.activeElement?.id || null});
    const before = await page.evaluate(state);
    await page.keyboard.press('Enter');
    const after = await page.evaluate(state);
    const actions = after.actions.slice(before.actions.length);
    const expectedParts = href.slice(1).split('#').map(decodeURIComponent);
    const [call] = actions;
    const exactDispatch = actions.length === 1 && Array.isArray(call) && (
      (call.length === expectedParts.length && call.every((v,i)=>v === expectedParts[i])) ||
      (expectedParts.length === 1 && call.length === 2 && call[0] === '' && call[1] === expectedParts[0])
    );
    const localTarget = expectedParts.length === 1 ? expectedParts[0] : expectedParts[0] === '' ? expectedParts[1] : null;
    const exactLocalFocus = actions.length === 0 && localTarget && before.focused !== after.focused && after.focused === localTarget &&
      await page.evaluate(id => document.getElementById(id) === document.activeElement, localTarget);
    const exactLocalHash = actions.length === 0 && localTarget && before.hash !== after.hash &&
      decodeURIComponent(after.hash.slice(1)) === localTarget && await page.evaluate(id=>!!document.getElementById(id),localTarget);
    result.href = href;
    result.keyboard = {before, after, expectedParts, confirmedBy: exactDispatch ? 'matching dispatch' : exactLocalFocus ? 'focus moved to target' : exactLocalHash ? 'hash moved to target' : null,
      unconfirmed: !(exactDispatch || exactLocalFocus || exactLocalHash)};
  }
  return result;
}

let issueCount = 0, incompleteEditions = 0;
try {
  for (const [edition,,relative,sha] of selected) {
    const bytes = await readFile(path.resolve(repo,relative,'complete.json'));
    assert.equal(digest(bytes),sha,`Published manifest changed for ${edition}`);
  }
  const inputPaths = ['check-edition-layout.mjs','blob.js','validate.js','xz.js','package.json','pnpm-lock.yaml'];
  const sources = {};
  for (const file of inputPaths) sources[file] = await fileDigest(path.join(web,file));
  const binding = {version:1, selected, inventory:digest(inventoryBytes), reader:digest(readerTable), sources,
    bundle:digest(js), css:digest(css), font:digest(font), browser:browser.version(),
    executable:await fileDigest(process.env.CHROMIUM || '/opt/brave-bin/brave'), node:process.version, widths, figureWitness:figureWitness ?? null};
  let witnessDigest = saved?.witnessDigest ?? null;
  const syncFile = async filename => {const f=await open(filename,'r'); try {await f.sync();} finally {await f.close();}};
  async function commit(editionIndex, nextMember, stat, screens) {
    const logs = {};
    for (const [name,log] of Object.entries(journals)) {await log.sync(); logs[name]=log.position();}
    const state = {binding,witnessDigest,editionIndex,nextMember,stat,screens:screens?.map(v=>[...v]) ?? null,issueCount,incompleteEditions,logs};
    const tmp = `${checkpointPath}.next`;
    await writeFile(tmp,JSON.stringify({state,sha256:digest(JSON.stringify(state))})+'\n'); await syncFile(tmp);
    await rename(tmp,checkpointPath); await directory.sync();
  }
  if (saved) {
    assert.deepEqual(saved.binding,binding,'Resume input or renderer changed');
    assert(Number.isSafeInteger(saved.editionIndex) && saved.editionIndex >= 0 && saved.editionIndex <= selected.length);
    const summarize = (await readFile(path.join(out,'editions.jsonl'))).subarray(0,journals.editions.position().bytes).toString();
    const credited = summarize.trimEnd() ? summarize.trimEnd().split('\n').map(line=>JSON.parse(line)) : [];
    assert.deepEqual(credited.map(row=>row.edition),editions.slice(0,saved.editionIndex));
    if (saved.stat) {
      assert.equal(saved.stat.edition,editions[saved.editionIndex]);
      credited.push(saved.stat);
    }
    for (const row of credited) for (const sample of row.samples) if (sample.filename) {
      assert.equal(path.basename(sample.filename),sample.filename);
      assert.equal(await fileDigest(path.join(out,sample.filename)),sample.sha256,'Committed sample changed');
    }
    if (witnessDigest) assert.equal(await fileDigest(path.join(out,'figure-witness.json')),witnessDigest);
    // Discard only uncredited tail writes, after validating every journal and input.
    for (const log of Object.values(journals)) await log.handle.truncate(log.position().bytes);
    issueCount=saved.issueCount; incompleteEditions=saved.incompleteEditions;
  } else await commit(0,0,null,null);
  const pages = [];
  for (const width of widths) {
    const page = await browser.newPage({viewport: {width, height: 800}});
    await page.route('**/*', route => route.request().url() === 'https://reader.invalid/reader.ttf' ? route.fulfill({body: font, contentType:'font/ttf',headers:{'access-control-allow-origin':'*'}}) : route.abort());
    await page.setContent('<base href="https://reader.invalid/"><style>' + css + '</style><main></main>');
    await page.addScriptTag({content: js});
    await page.evaluate(async () => { const faces = await document.fonts.load('16px Reader'); await document.fonts.ready; if (!faces.length || faces.some(face => face.status !== 'loaded') || !document.fonts.check('16px Reader')) throw Error('Product Reader font failed to load'); });
    pages.push(page);
  }
  if (figureWitness && !witnessDigest) {
    const w = figureWitness;
    const selection = selections.get(w.edition);
    assert(selection && selection[3] === w.completeSha256 && !editions.includes(w.edition));
    const root = path.resolve(repo, selection[2]);
    const manifest = await readFile(path.join(root,'complete.json')); assert.equal(digest(manifest),w.completeSha256);
    const member = JSON.parse(manifest).publication_files[w.member];
    assert(member && !path.isAbsolute(w.member) && w.member.split('/').every(s => s && s !== '.' && s !== '..'));
    const file = path.join(root,w.member); assert.equal(await fileDigest(file),member.sha256);
    const source = await openSource(await openAsBlob(file)); const index = await buildIndex(source);
    const row = index.rows.find(r=>r.title===w.title); assert(row && index.metadata.kind==='language');
    const entry = decode(await source.read(row.offset,row.length),{...index.metadata,title:row.title});
    entry.source_edition=w.edition; entry.source_title=row.title;
    const views = [];
    for (const [i,page] of pages.entries()) {
      const [result] = await page.evaluate(inspectBatch,{entries:[entry],edition:w.edition,measureFigure:true});
      views.push({width:widths[i],...result});
    }
    await writeFile(path.join(out,'figure-witness.json'),JSON.stringify({selection:w,views})+'\n');
    for (const {figure} of views) {
      assert.equal(figure?.caption,w.caption); assert.equal(figure?.imageBoxWidth,w.imageBoxWidth);
      assert(figure.words.length && figure.words.every(word=>word.lines===1));
    }
  }
  if (figureWitness && !witnessDigest) {
    const filename = path.join(out,'figure-witness.json'); await syncFile(filename); witnessDigest=await fileDigest(filename);
  }
  for (let editionIndex=saved?.editionIndex ?? 0; editionIndex < selected.length; ++editionIndex) {
    const [edition,selectedStatus,relative,completeHash]=selected[editionIndex];
    const previous=saved?.editionIndex===editionIndex ? saved : null;
    const started = performance.now();
    const stat = previous?.stat ?? {edition, selectedStatus, completeHash, indexed: 0, decoded: 0, views: [0,0], members: 0, completedMembers: 0, byKind: {}, issues: 0, categories: {}, samples: [], indexFailures: 0};
    async function issue(identity, problems) {
      ++stat.issues; ++issueCount;
      for (const k of Object.keys(problems)) stat.categories[k] = (stat.categories[k] || 0) + 1;
      await failures.writeFile(JSON.stringify({...identity, edition, problems})+'\n');
    }
    const root = path.resolve(repo, relative);
    const manifest = await readFile(path.join(root,'complete.json'));
    assert.equal(digest(manifest),completeHash);
    const complete = JSON.parse(manifest);
    assert.equal(complete.edition, edition);
    const members = Object.entries(complete.publication_files).filter(([n]) => /\.wikblb(?:\.xz)?$/.test(n));
    assert.equal(members.length, complete.blobs);
    if (selectedStatus === 'empty') assert(complete.status === 'empty' && !members.length);
    stat.members = members.length;
    const screens = widths.map((_,i) => new Set(previous?.screens?.[i]));
    stat.layout ??= widths.map(width => ({width, bodyTextNodes:0, visibleLinks:0, tableCells:0, emptyBodyViews:0}));
    const priorSeconds=stat.elapsedSeconds ?? 0;
    const firstMember = previous?.nextMember ?? 0;
    assert(Number.isSafeInteger(firstMember) && firstMember >= 0 && firstMember <= members.length);
    assert.equal(stat.completedMembers + stat.indexFailures,firstMember);
    for (let mi=firstMember; mi<members.length; ++mi) {
      const [member,authority]=members[mi];
      assert(!path.isAbsolute(member) && member.split('/').every(s => s && s !== '..' && s !== '.'));
      const filename = path.join(root,member);
      let source, index;
      try {
        const blob = await openAsBlob(filename);
        assert.equal(blob.size, authority.size); assert.equal(await fileDigest(filename), authority.sha256);
        source = await openSource(blob); index = await buildIndex(source);
      } catch(e) { ++stat.indexFailures; await issue({member}, {archiveOrIndex: String(e.message||e)}); }
      if (index) {
        stat.indexed += index.rows.length;
        const kind = index.metadata.kind;
        stat.byKind[kind] = (stat.byKind[kind] || 0) + index.rows.length;
        let batch = [], batchBytes = 0, checkpoint = 0;
        async function checkpointThrough(ordinal) {
          await progress.writeFile(JSON.stringify({edition, member, ordinal, completeHash, indexed:stat.indexed,
            decoded:stat.decoded, views:stat.views, issues:stat.issues, elapsedSeconds:(performance.now()-started)/1000})+'\n');
        }
        async function flush() {
          if (!batch.length) return;
          for (const [i, page] of pages.entries()) {
            const width = widths[i];
            const entries = batch.map(r => r.entry);
            const rows = await inspectEntries(page, edition, entries);
            assert.equal(rows.length, batch.length);
            for (const [n, metrics] of rows.entries()) {
              const {entry, identity} = batch[n];
              const where = {...identity, width};
              if (metrics.error) {
                await issue(where, {renderError:metrics.error});
                if (!screens[i].has('render-error')) {
                  screens[i].add('render-error');
                  try {
                    const frame=await sample(page,{edition,entries:[entry]},`${edition}-${width}-render-error.png`,false);
                    stat.samples.push({...where,reason:'render-error',...frame});
                  } catch(e) { await issue(where,{sample:String(e.message || e)}); }
                }
                continue;
              }
              ++stat.views[i];
              stat.layout[i].bodyTextNodes += metrics.bodyNodes;
              stat.layout[i].visibleLinks += metrics.links;
              stat.layout[i].tableCells += metrics.cells;
              if (!metrics.bodyNodes) ++stat.layout[i].emptyBodyViews;
              const bad = Object.keys(metrics.problems).length > 0;
              if (bad) await issue(where, metrics.problems);
              const reason = bad && !screens[i].has('issue') ? 'issue' : metrics.keyboardLink && !screens[i].has('keyboard') ? 'keyboard' : !screens[i].has('first') ? 'first' : null;
              if (!reason) continue;
              screens[i].add('first'); screens[i].add(reason);
              if (metrics.keyboardLink) screens[i].add('keyboard');
              try {
                const frame = await sample(page, {edition, entries:[entry]}, `${edition}-${width}-${reason}.png`, metrics.keyboardLink);
                stat.samples.push({...where, reason, ...frame});
                if (frame.renderError || frame.keyboard?.unconfirmed) await issue(where, {sample: frame.renderError || 'Keyboard activation unconfirmed'});
              } catch(e) {await issue(where, {sample: String(e.message || e)});}
            }
          }
          const ordinal = batch.at(-1).identity.ordinal;
          if (ordinal - checkpoint >= 2048) { await checkpointThrough(ordinal); checkpoint = ordinal; }
          batch = []; batchBytes = 0;
        }
        for (const [ordinal,row] of index.rows.entries()) {
          const identity = {member, ordinal, title:row.title, offset:row.offset, length:row.length};
          // A single oversized entry still gets its own batch.
          if (batch.length && (batch.length >= 24 || batchBytes + row.length > 256*1024)) await flush();
          try {
            const payload = await source.read(row.offset,row.length);
            const alias = index.metadata.kind === 'alias' ? decodeAlias(payload, row.raw_key ?? row.title) : null;
            const entry = alias ? alias.entry : decode(payload, {...index.metadata, title:row.title});
            // A raw alias presentation and its destination have distinct stored bodies.
            entry.source_edition = edition;
            entry.source_title = alias ? alias.alias.source_title : ['language','supplemental'].includes(index.metadata.kind) ? row.title : null;
            batch.push({entry,identity}); batchBytes += row.length; ++stat.decoded;
          } catch(e) {await issue(identity,{decodeError: String(e.message || e)});}
        }
        await flush(); ++stat.completedMembers; await checkpointThrough(index.rows.length - 1);
      }
      stat.elapsedSeconds=priorSeconds+(performance.now()-started)/1000;
      await commit(editionIndex,mi+1,stat,screens);
      if (++processedThisInvocation === Number(pause)) {
        console.log(JSON.stringify({paused:true,edition,nextMember:mi+1})); process.exitCode=75; break;
      }
    }
    if (process.exitCode === 75) break;
    stat.enumerated = stat.members === stat.completedMembers && !stat.indexFailures;
    const expected = expectedCounts.get(edition);
    if (expected?.sha === completeHash && /^\d+$/.test(expected.count)) {
      stat.nativeDistinctDestinations = Number(expected.count);
      stat.storedRecordsMinusNativeDestinations = stat.indexed - stat.nativeDistinctDestinations;
    }
    stat.emptyCatalog = selectedStatus === 'empty' && !stat.members;
    stat.fullLayoutAtBothWidths = !stat.emptyCatalog && stat.enumerated && stat.decoded===stat.indexed && stat.views.every(n => n===stat.indexed);
    if (!(stat.fullLayoutAtBothWidths || stat.emptyCatalog) || stat.categories.missingHeading) ++incompleteEditions;
    stat.elapsedSeconds = priorSeconds+(performance.now()-started)/1000;
    await summary.writeFile(JSON.stringify(stat)+'\n'); await summary.sync(); await failures.sync();
    await commit(editionIndex+1,0,null,null);
    console.log(JSON.stringify({edition,indexed:stat.indexed,views:stat.views,issues:stat.issues,elapsedSeconds:stat.elapsedSeconds}));
  }
  if (process.exitCode !== 75) await writeFile(path.join(out,'run.json'),JSON.stringify({editions,widths,inventorySha256:digest(inventoryBytes),readerTableSha256:digest(readerTable),productBundleSha256:digest(js),cssSha256:digest(css),fontSha256:digest(font),browser:browser.version(),issues:issueCount,incompleteEditions})+'\n');
  if (process.exitCode !== 75 && incompleteEditions) process.exitCode = 2;
} finally {await browser.close(); await summary.close(); await failures.close(); await progress.close(); await directory.close();}
