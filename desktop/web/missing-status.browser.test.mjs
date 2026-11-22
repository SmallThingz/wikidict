import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const web=fileURLToPath(new URL('./',import.meta.url)),require=createRequire(path.join(web,'package.json'));
const {chromium}=require('playwright'),{build}=require('esbuild');
const c=JSON.parse(await readFile(process.env.WIKIDICT_WEB_TPI_COLUMNS_CASE,'utf8')),out=process.env.WIKIDICT_STATUS_REPORT,start=performance.now();assert.ok(path.isAbsolute(out));await mkdir(out,{mode:0o700});
const sha=b=>createHash('sha256').update(b).digest('hex'),manifest=await readFile(path.join(c.root,'complete.json'));assert.equal(sha(manifest),c.complete_sha256);
const file=path.join(c.root,c.member),bytes=await readFile(file),authority=JSON.parse(manifest).publication_files[c.member];assert.equal(sha(bytes),authority.sha256);assert.equal(bytes.length,authority.size);
const assets=new Map();
for(const [name,type] of [['index.html','text/html'],['style.css','text/css'],['reader.ttf','font/ttf']])assets.set('/'+name,{body:await readFile(path.join(web,name)),contentType:type});
assets.set('/',assets.get('/index.html'));
for(const name of ['app.js','import-worker.js']){const result=await build({entryPoints:[path.join(web,name)],bundle:true,format:'esm',platform:'browser',target:'es2022',minify:true,write:false});assets.set('/'+name,{body:Buffer.from(result.outputFiles[0].contents),contentType:'text/javascript'});}
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const origin='https://wikidict.invalid',requests=[],errors=[],requestFailures=[];
try{
 const context=await browser.newContext({viewport:{width:1000,height:800},serviceWorkers:'block',colorScheme:'light'});
 await context.route('**/*',route=>{const url=new URL(route.request().url()),asset=url.origin===origin?assets.get(url.pathname):null;requests.push({url:url.href,local_asset:!!asset});return asset?route.fulfill(asset):route.abort();});
 const page=await context.newPage();page.on('pageerror',error=>errors.push(String(error)));page.on('requestfailed',request=>requestFailures.push({url:request.url(),failure:request.failure()}));
 await page.goto(origin+'/');await page.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await page.locator('#file').setInputFiles(file);await page.getByText(/English · 5 words/).waitFor();
 const importLabel=await page.locator('#panel').innerText();
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox',{name:'Find a word'}).fill(c.title);
 const hit=page.getByRole('button',{name:'Open '+c.title,exact:true});await hit.waitFor();await hit.focus();await page.keyboard.press('Enter');await page.locator('#entry h1').filter({hasText:c.title}).waitFor();
 async function expand(){const summaries=page.locator('#entry summary');for(let i=0;i<await summaries.count();i++){const s=summaries.nth(i);if(await s.isVisible()&&!await s.evaluate(el=>el.parentElement.open)){await s.focus();await page.keyboard.press('Space');}}await page.evaluate(()=>document.fonts.ready);await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));}
 const views=[];
 for(const width of [640]){
  await page.setViewportSize({width,height:800});await expand();
  const metrics=await page.evaluate(()=>{const owners=[...document.querySelectorAll('#entry .compiled-container')].filter(el=>getComputedStyle(el).columnCount!=='auto');return {title:document.querySelector('#entry h1')?.textContent,page_horizontal_overflow:document.documentElement.scrollWidth>innerWidth,columns:owners.map(el=>{el.dataset.columnWitness='true';const cs=getComputedStyle(el),rect=el.getBoundingClientRect(),links=[...el.querySelectorAll('a')].map(a=>{const r=a.getBoundingClientRect();return {text:a.textContent.trim(),x:r.x,y:r.y,width:r.width,height:r.height};});return {count:Number(cs.columnCount),gap_px:parseFloat(cs.columnGap),font_px:parseFloat(cs.fontSize),fill:cs.columnFill,overflow:cs.overflow,rectangle:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},links};})};});
  assert.equal(metrics.title,c.title);assert.equal(metrics.page_horizontal_overflow,false);assert.equal(metrics.columns.length,2);
  assert.deepEqual(metrics.columns.map(x=>x.links.length),[8,2]);assert.deepEqual(metrics.columns[0].links.map(x=>x.text),['blabber','blather','conversation','discussion','gossip','prattle','speech','talk']);
  for(const [i,col] of metrics.columns.entries()){assert.equal(col.count,3);assert.equal(col.fill,'balance');assert.ok(Math.abs(col.gap_px-col.font_px)<.1);const occupied=new Set(col.links.map(x=>Math.round(x.x)));assert.equal(occupied.size,Math.min(3,col.links.length));assert.ok(col.links.every(x=>x.width>0&&x.height>0&&x.x>=col.rectangle.x-.5&&x.x+x.width<=col.rectangle.x+col.rectangle.width+.5));}
  await page.locator('[data-column-witness]').first().scrollIntoViewIfNeeded();const frame='thesaurus-talk-'+width+'.png';await page.screenshot({path:path.join(out,frame)});views.push({width,...metrics,frame});
 }
 const synonym=page.getByRole('link',{name:'blabber',exact:true});await synonym.focus();const focused=await synonym.evaluate(el=>document.activeElement===el);assert.ok(focused);const beforeMissing=await synonym.evaluate(el=>({scrollY,rectangle:el.getBoundingClientRect().toJSON()}));await page.keyboard.press('Enter');await page.locator('#status').filter({hasText:'Word is not installed in this dictionary.'}).waitFor();
 const missing=await page.locator('#status').evaluate(el=>{const r=el.getBoundingClientRect();return {text:el.textContent,role:el.getAttribute('role'),aria_live:el.getAttribute('aria-live'),rectangle:{x:r.x,y:r.y,width:r.width,height:r.height},within_viewport:r.top>=0&&r.bottom<=innerHeight};});
 assert.equal(await page.locator('#entry h1').innerText(),c.title);assert.equal(missing.within_viewport,true);const afterMissing=await synonym.evaluate(el=>({focused:document.activeElement===el,scrollY,rectangle:el.getBoundingClientRect().toJSON()}));assert.equal(afterMissing.focused,true);assert.ok(Math.abs(afterMissing.rectangle.y-beforeMissing.rectangle.y)<1);await page.screenshot({path:path.join(out,'missing-status-640.png')});
 const history=page.getByRole('button',{name:'History',exact:true});await history.focus();await page.keyboard.press('Enter');const reopen=page.getByRole('button',{name:'Open '+c.title,exact:true});await reopen.waitFor();await reopen.focus();await page.keyboard.press('Enter');await page.locator('#entry h1').filter({hasText:c.title}).waitFor();await expand();
 const recovery={title:await page.locator('#entry h1').innerText(),synonym_visible:await page.getByRole('link',{name:'blabber',exact:true}).isVisible(),route:'Ordinary History -> Open Thesaurus:talk using real keyboard; browser Back not claimed'};assert.ok(recovery.synonym_visible);
 assert.deepEqual(errors,[]);
 await writeFile(path.join(out,'result.json'),JSON.stringify({scope:'Normal product file input/import-worker/library/search/keyboard reading, not injected Entry data',browser:browser.version(),publication:c.complete_sha256,member:c.member,member_sha256:authority.sha256,member_bytes:bytes.length,source_owner:'English',source_edition_external_authority:'tpiwiktionary',import_label:importLabel,ordinary_import:true,keyboard_open:true,views,missing_link:{target:'blabber',focused,beforeMissing,afterMissing,...missing},recovery,page_errors:errors,requests,external_network_enabled:false,elapsed_seconds:(performance.now()-start)/1000},null,2)+'\n');
}catch(error){await writeFile(path.join(out,'failure.json'),JSON.stringify({error:String(error),requests,requestFailures,errors},null,2)+'\n');throw error;}finally{await browser.close();}
