import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('.',import.meta.url));
const report=fileURLToPath(new URL('../../data/renderer-validation/web/',import.meta.url));
await mkdir(report,{recursive:true});
const fixture=process.env.RENDERER_FIXTURE || fileURLToPath(new URL('../../data/renderer-validation/fixture.json',import.meta.url));
const server=createServer(async(req,res)=>{try{const relative=decodeURIComponent(new URL(req.url,'http://localhost').pathname);const file=path.resolve(root,'.'+(relative==='/'?'/index.html':relative));if(!file.startsWith(root))throw Error('path');const bytes=await readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM || '/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[], measurements=[];
try {
  const page=await browser.newPage();
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.locator('#file').setInputFiles(fixture);
  await page.getByText('PREAMBLE: compiled presentation.').waitFor();
  await page.locator('pre').scrollIntoViewIfNeeded();
  assert.equal(await page.locator('pre').innerText(),'column A  column B\n  indented\tvalue');
  await page.locator('table').scrollIntoViewIfNeeded();
  assert.equal(await page.locator('th[rowspan="2"]').innerText(),'Case');
  assert.equal(await page.locator('th[colspan="2"]').innerText(),'Number');
  for(const tag of ['strong','em','code','small','sup','sub','s','u','br']) assert.ok(await page.locator('#entry '+tag).count(),tag);
  assert.equal(await page.locator('[dir=rtl]').innerText(),'كتاب');
  assert.ok((await page.locator('#entry').innerText()).includes('Reference content.'));
  assert.ok((await page.locator('#entry').innerText()).includes('Example pronunciation.ogg'));
  for(const [width,height] of [[360,800],[768,1024],[1440,900]]) {
    await page.setViewportSize({width,height});
    await page.locator('#entry').scrollIntoViewIfNeeded();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1),'page has horizontal overflow');
    const before=await page.locator('#entry').boundingBox();
    await page.getByRole('button',{name:'Change theme'}).click();
    const after=await page.locator('#entry').boundingBox();
    assert.equal(before.width,after.width,'theme causes layout shift');
    await page.screenshot({path:path.join(report,`reader-${width}.png`),fullPage:true});
    const elapsed=await page.evaluate(async()=>{const start=performance.now();const input=document.querySelector('#query');input.value='cat';input.dispatchEvent(new Event('input'));await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);return performance.now()-start;});
    measurements.push({width,height,search_frame_ms:elapsed});
    await page.locator('#matches button').first().click();
  }
  await page.locator('#query').fill('not-in-dictionary');
  await page.getByRole('status').filter({hasText:'No matches'}).waitFor();
  await page.locator('#query').fill('');
  await page.locator('#file').setInputFiles({name:'invalid.json',mimeType:'application/json',buffer:Buffer.from('{"schema":"dict.results.v1","entries":[],"source":"raw"}')});
  await page.getByRole('status').filter({hasText:'Uncompiled field'}).waitFor();
  assert.ok((await page.locator('#entry').innerText()).includes('A small animal.'),'failed import removed the current entry');
  if(process.env.CORPUS_FIXTURE) {
    await page.locator('#file').setInputFiles(process.env.CORPUS_FIXTURE);
    await page.getByText('PREAMBLE: compiled presentation.').waitFor({state:'detached'});
    await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();
    assert.ok((await page.locator('#entry').textContent()).length>1000);
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1));
    await page.screenshot({path:path.join(report,'corpus-cat.png'),fullPage:true});
  }
  assert.deepEqual(errors,[]);
  await writeFile(path.join(report,'report.json'),JSON.stringify({status:'passed',fixture,measurements,page_errors:errors},null,2)+'\n');
  console.log('WEB_RENDERER_PASS',JSON.stringify(measurements));
} finally { await browser.close();server.close(); }
