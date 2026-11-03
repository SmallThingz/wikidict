import {chromium} from 'playwright';
import {build} from 'esbuild';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
import path from 'node:path';
import {dictionaryBlob,presentation} from './alias-fixtures.mjs';
const web=fileURLToPath(new URL('./',import.meta.url));
const report=process.env.WIKIDICT_ERROR_REPORT;
assert.ok(report&&path.isAbsolute(report),'Use a fresh absolute report directory');await mkdir(report,{recursive:false});
// Use the normal production build, not a test-only application export.
execFileSync(process.execPath,['build.mjs'],{cwd:web,stdio:'inherit'});
const root=fileURLToPath(new URL('../build/web/',import.meta.url));
let baseline=null;
if(process.env.WIKIDICT_ERROR_BASELINE){
 assert.ok(path.isAbsolute(process.env.WIKIDICT_ERROR_BASELINE));
 const bundled=await build({stdin:{contents:await readFile(process.env.WIKIDICT_ERROR_BASELINE,'utf8'),resolveDir:web,sourcefile:'app.js',loader:'js'},bundle:true,format:'esm',platform:'browser',target:'es2022',minify:true,write:false});baseline=bundled.outputFiles[0].contents;
}
const faultWorker=mode=>`const hit={dictionary:'fixture',context:'fixture',title:'fixture',language:'English',kind:'language'};
const entry={title:'fixture',language:'English',language_code:'en',kind:'language',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:[{kind:'link',text:'Broken lookup',target:'other'}]}]}]};
onmessage=({data})=>{const {id,type}=data;let value,error;
if(type==='state')value={sources:${mode==='dictionaries'?"['not-a-valid-stored-source']":"[]"}};
else if(type==='list')value=${mode==='link'?"[{id:'fixture',language:'English',count:1,bytes:1}]":"[]"};
else if(type==='search'){${mode==='search'?"error='Controlled initial search failure';":mode==='link'?"value=[hit];":"value=[];"}}
else if(type==='random'){${mode==='learn'?"error='Controlled Learn failure';":"value=null;"}}
else if(type==='read')value=entry;
else if(type==='exact')error='Controlled linked lookup failure';
else value=true;
setTimeout(()=>postMessage({id,value,error}),0);};`;
const assets=new Set(['index.html','app.js','import-worker.js','style.css','reader.ttf']);
const server=createServer(async(req,res)=>{try{
 const parts=new URL(req.url,'http://localhost').pathname.split('/').filter(Boolean),mode=parts.length>1?parts[0]:'current',name=parts.at(-1)||'index.html';
 if(!assets.has(name))throw Error('unknown asset');
 let bytes;
 if(mode==='before'&&name==='app.js'){assert.ok(baseline);bytes=baseline;}
 else if(mode.startsWith('fault-')&&name==='import-worker.js')bytes=Buffer.from(faultWorker(mode.slice(6)));
 else bytes=await readFile(path.join(root,name));
 res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);
}catch{res.writeHead(404);res.end();}});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
let browser;const unexpected=[],externalRequests=[],frames=[];let beforeObserved=null;const asynchronous=[];
try{
 browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
 const context=async()=>{
  const context=await browser.newContext();await context.route('**/*',route=>{if(new URL(route.request().url()).origin===origin)return route.continue();externalRequests.push(route.request().url());return route.abort();});return context;
 };
 if(baseline){
  const ctx=await context(),page=await ctx.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(origin+'/before/index.html');await page.getByRole('button',{name:'Add list',exact:true}).waitFor();
  const field=page.getByRole('textbox',{name:'Catalogue URL',exact:true});await field.fill('not a URL');const failed=page.waitForEvent('pageerror');await page.getByRole('button',{name:'Add list',exact:true}).click();await failed;
  assert.equal(errors.length,1);assert.match(errors[0],/URL/i);assert.equal(await page.locator('#status').textContent(),'');assert.equal(await field.inputValue(),'not a URL');
  beforeObserved={uncaughtErrors:errors,status:'',fieldPreserved:true,scope:'Actual immutable pre-fix app.js UI with unchanged real worker; known synchronous URL failure reproduced, not a product pass.'};
  await page.screenshot({path:path.join(report,'before-invalid-url.png'),fullPage:true});await ctx.close();
 }
 const ctx=await context(),page=await ctx.newPage();page.on('pageerror',e=>unexpected.push(e.message));
 await page.addInitScript(()=>{window.filePickerActivation=[];document.addEventListener('click',event=>{if(event.target.id==='file')window.filePickerActivation.push(navigator.userActivation.isActive);},true);window.statusTransitions=[];addEventListener('DOMContentLoaded',()=>{new MutationObserver(()=>window.statusTransitions.push(document.getElementById('status').textContent)).observe(document.getElementById('status'),{childList:true,subtree:true});});});
 await page.goto(origin+'/current/index.html');await page.getByRole('button',{name:'Add list',exact:true}).waitFor();
 const input=()=>page.getByRole('textbox',{name:'Catalogue URL',exact:true});
 const sourceCount=()=>page.getByRole('button',{name:'Remove source',exact:true}).count();assert.equal(await sourceCount(),1);
 for(const [value,expected]of [['not a URL',null],['http://example.test/catalogue.list','Use an HTTPS URL']]){
  await input().fill(value);await input().focus();await page.keyboard.press('Tab');assert.equal(await page.getByRole('button',{name:'Add list',exact:true}).evaluate(el=>document.activeElement===el),true);await page.keyboard.press('Enter');
  await page.waitForFunction(()=>document.getElementById('status').classList.contains('error')&&document.getElementById('status').textContent.length>0);
  if(expected)assert.equal(await page.getByRole('status').textContent(),expected);assert.equal(await input().inputValue(),value);assert.equal(await sourceCount(),1);
 }
 for(const width of [360,768]){
  await page.setViewportSize({width,height:640});await input().scrollIntoViewIfNeeded();
  const bounds=await input().boundingBox();assert.ok(bounds.x>=0&&bounds.x+bounds.width<=width+.1);
  const name=`action-error-${width}.png`;await page.screenshot({path:path.join(report,name),fullPage:true});frames.push(name);
 }
 await input().fill('https://example.test/catalogue.list');await page.getByRole('button',{name:'Add list',exact:true}).click();await page.getByText('https://example.test/catalogue.list',{exact:true}).waitFor();assert.equal(await sourceCount(),2);assert.equal(await page.locator('#status').textContent(),'');
 const fixture=dictionaryBlob(1,[['fixture',presentation('A compiled fixture definition.','','')]]);
 const chooser=page.waitForEvent('filechooser');await page.getByRole('button',{name:'Import dictionary',exact:true}).click();await(await chooser).setFiles({name:'fixture.wikblb',mimeType:'application/octet-stream',buffer:fixture});
 await page.getByText('English · 1 words · 0.0 MB',{exact:true}).waitFor();assert.deepEqual(await page.evaluate(()=>window.filePickerActivation),[true]);assert.ok((await page.evaluate(()=>window.statusTransitions)).includes('Indexing dictionary…'));
 await page.getByRole('button',{name:'Search',exact:true}).click();const query=page.getByRole('searchbox',{name:'Find a word',exact:true});await query.fill('not-installed');await page.getByRole('status').filter({hasText:'No matches.'}).waitFor();assert.equal(await query.inputValue(),'not-installed');await query.fill('fixture');await page.getByRole('button',{name:'Open fixture',exact:true}).waitFor();await query.focus();await page.keyboard.press('Tab');assert.equal(await page.getByRole('button',{name:'Open fixture',exact:true}).evaluate(el=>document.activeElement===el),true);await page.keyboard.press('Enter');await page.getByRole('heading',{name:'fixture',exact:true}).waitFor();assert.ok((await page.evaluate(()=>window.statusTransitions)).includes('Opening…'));assert.equal(await page.locator('#status').textContent(),'');
 await ctx.close();
 for(const mode of ['search','learn','dictionaries','link']){
  const c=await context(),p=await c.newPage();p.on('pageerror',e=>unexpected.push(e.message));await p.goto(origin+'/fault-'+mode+'/index.html');
  if(mode==='search'){await p.getByRole('button',{name:'Add list',exact:true}).waitFor();await p.getByRole('button',{name:'Search',exact:true}).click();}
  if(mode==='learn'){await p.getByRole('button',{name:'Add list',exact:true}).waitFor();await p.getByRole('button',{name:'Learn',exact:true}).click();}
  if(mode==='link'){await p.getByRole('button',{name:'Open fixture',exact:true}).click();await p.getByRole('link',{name:'Broken lookup',exact:true}).click();}
  await p.waitForFunction(()=>document.getElementById('status').classList.contains('error')&&document.getElementById('status').textContent.length>0);
  const message=await p.getByRole('status').textContent();if(mode!=='dictionaries')assert.match(message,/Controlled/);else assert.match(message,/URL/i);
  if(mode==='search'){const field=p.getByRole('searchbox',{name:'Find a word',exact:true});assert.equal(await field.isEnabled(),true);assert.equal(await field.inputValue(),'');}
  if(mode==='link')assert.equal(await p.getByRole('heading',{name:'fixture',exact:true}).count(),1);
  await p.getByRole('button',{name:'Settings',exact:true}).click();await p.getByRole('heading',{name:'Settings',exact:true}).waitFor();assert.equal(await p.locator('#status').textContent(),'');asynchronous.push({mode,message,recovery:true,scope:'Controlled worker-protocol rejection with real built app UI; not an observed production storage failure.'});await c.close();
 }
 assert.deepEqual(unexpected,[]);assert.deepEqual(externalRequests,[]);
 await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,scope:'Focused real built app synchronous URL failure handling and controlled async worker/navigation/link rejection recovery; actual isolated raw-fixture import/read/empty/key/filechooser path. No public transport/full suite/current corpus claim.',baseline:beforeObserved,asynchronous,errors:unexpected,externalRequests,frames},null,2)+'\n');console.log('WEB_ACTION_ERRORS_PASS');
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
