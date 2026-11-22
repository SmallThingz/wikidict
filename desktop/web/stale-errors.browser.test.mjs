import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const web=fileURLToPath(new URL('./',import.meta.url)),report=process.env.WIKIDICT_STALE_REPORT;assert.ok(report&&path.isAbsolute(report));await mkdir(report,{recursive:false});execFileSync(process.execPath,['build.mjs'],{cwd:web,stdio:'inherit'});
const root=fileURLToPath(new URL('../build/web/',import.meta.url));
const faultWorker=mode=>`const mode=${JSON.stringify(mode)},hit={dictionary:'fixture',context:'fixture',title:'fixture',language:'English',kind:'language'},entry={title:'fixture',language:'English',language_code:'en',kind:'language',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:[{kind:'link',text:'Broken lookup',target:'other'}]}]}]};let pending=null;const hold=(id,type)=>{pending={id,type};postMessage({fixturePending:type});};onmessage=({data})=>{if(data.fixtureRelease){if(!pending)throw Error('No controlled pending request');postMessage({id:pending.id,...(data.fixtureReject===false?{value:entry}:{error:'Controlled delayed '+pending.type+' failure'})});pending=null;postMessage({fixtureReleased:true});return;}const{id,type,args}=data;let value,error;if(type==='state')value={sources:[]};else if(type==='list')value=[{id:'fixture',language:'English',count:1,bytes:1}];else if(type==='search'){if(args.query==='old'){hold(id,type);return;}if(mode==='current-search'&&args.query==='current')error='Controlled current search failure';else value=args.query?[{...hit,title:args.query==='new'?'new':'fixture'}]:[];}else if(type==='random'){if(mode==='learn-random-navigation'){hold(id,type);return;}if(mode==='current-random')error='Controlled current random failure';else value=hit;}else if(type==='read'){if(mode==='read-navigation'||mode==='learn-read-navigation'||mode.startsWith('read-search-edit-')){hold(id,type);return;}if(mode==='current-read'||mode==='current-learn-read')error='Controlled current read failure';else value=entry;}else if(type==='exact'){if(mode==='exact-navigation'){hold(id,type);return;}error='Controlled current exact failure';}else if(type==='saveState'&&mode==='save-navigation'){hold(id,type);return;}else value=true;postMessage({id,value,error});};`;
// Model the production worker queue: queued exact/read starts only after bookmark save settles.
const bookmarkWorker=mode=>`const mode=${JSON.stringify(mode)},hit=title=>({dictionary:'fixture',context:'fixture',title,language:'English',kind:'language'}),entry=title=>({title,language:'English',language_code:'en',kind:'language',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:title==='fixture'?[{kind:'link',text:'Other entry',target:'other'},{kind:'link',text:'Same entry fragment',target:'#Destination'}]:[{kind:'text',text:'Other meaning'}]}]},{title:'Target fold',anchor:'Destination',blocks:[{kind:'paragraph',spans:[{kind:'text',text:'Fragment destination'}]}]}]});let queue=Promise.resolve(),releaseSave=null,saveNumber=0;onmessage=({data})=>{if(data.fixtureRelease){if(!releaseSave)throw Error('No pending bookmark save');releaseSave(data.fixtureReject);releaseSave=null;postMessage({fixtureReleased:true});return;}const{id,type,args}=data;queue=queue.then(async()=>{try{let value;if(type==='state')value={sources:[],settings:{historyLimit:0},saved:mode==='bookmark-rollback-later-mutation'?[{...hit('fixture'),clue:'Other entrySame entry fragment'},{...hit('other'),clue:'Other meaning'}]:[]};else if(type==='list')value=[{id:'fixture',language:'English',count:2,bytes:1}];else if(type==='search')value=args.query?[hit('fixture')]:[];else if(type==='read')value=entry(args.title);else if(type==='exact')value=hit(args.title);else if(type==='saveState'){postMessage({fixturePending:type,saveNumber:++saveNumber});if(mode!=='bookmark-rollback-later-mutation'||saveNumber===1){const reject=await new Promise(resolve=>{releaseSave=resolve;});if(reject)throw Error('Controlled bookmark save failure');}postMessage({fixturePersisted:args.saved.map(hit=>hit.title),saveNumber});value=true;}else value=true;postMessage({id,value});postMessage({fixtureCompleted:type});}catch(error){postMessage({id,error:error.message});postMessage({fixtureCompleted:type});}});};`;
const assets=new Set(['index.html','app.js','import-worker.js','style.css','reader.ttf']);const server=createServer(async(req,res)=>{try{const parts=new URL(req.url,'http://localhost').pathname.split('/').filter(Boolean),mode=parts[0],name=parts.at(-1);assert.ok(assets.has(name));const bytes=name==='import-worker.js'?(mode.startsWith('bookmark-')?bookmarkWorker(mode):faultWorker(mode)):await readFile(path.join(root,name));res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;let browser;const errors=[],externalRequests=[],cases=[],frames=[];
try{browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
for(const mode of ['search-superseded','search-navigation','current-search','read-search-edit-success','read-search-edit-error','read-navigation','current-read','learn-random-navigation','current-random','learn-read-navigation','current-learn-read','exact-navigation','current-exact','save-navigation','bookmark-current','bookmark-link','bookmark-fragment','bookmark-error','bookmark-rollback-later-mutation']){
 const ctx=await browser.newContext({viewport:{width:360,height:640},colorScheme:'light'});await ctx.route('**/*',r=>{if(new URL(r.request().url()).origin===origin)return r.continue();externalRequests.push(r.request().url());return r.abort();});const page=await ctx.newPage();page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(()=>{const Native=Worker;window.fixtureMessages=[];window.Worker=class extends Native{constructor(...args){super(...args);window.fixtureWorker=this;this.addEventListener('message',({data})=>{if(data.fixturePending||data.fixtureReleased||data.fixtureCompleted||data.fixturePersisted)window.fixtureMessages.push(data);});}};});await page.goto(origin+'/'+mode+'/index.html');const query=page.getByRole('searchbox',{name:'Find a word',exact:true});await query.waitFor();
 const pending=type=>page.waitForFunction(t=>window.fixtureMessages.some(x=>x.fixturePending===t),type);
 const release=async(reject=true)=>{await page.evaluate(reject=>window.fixtureWorker.postMessage({fixtureRelease:true,fixtureReject:reject}),reject);await page.waitForFunction(()=>window.fixtureMessages.some(x=>x.fixtureReleased));await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));};
 const settings=async()=>{await page.getByRole('button',{name:'Settings',exact:true}).click();await page.getByRole('heading',{name:'Settings',exact:true}).waitFor();};
 const openFixture=async()=>{await query.fill('fixture');await page.getByRole('button',{name:'Open fixture',exact:true}).click();};
 if(mode.startsWith('search-')){await query.fill('old');await pending('search');if(mode==='search-superseded'){await query.fill('new');await page.getByRole('button',{name:'Open new',exact:true}).waitFor();}else await settings();await release();assert.equal(await page.locator('#status').textContent(),'');if(mode==='search-superseded'){assert.equal(await query.inputValue(),'new');assert.equal(await page.getByRole('button',{name:'Open new',exact:true}).count(),1);}else assert.equal(await page.getByRole('heading',{name:'Settings',exact:true}).count(),1);}
 else if(mode==='current-search'){await query.fill('current');await page.getByRole('status').filter({hasText:'Controlled current search failure'}).waitFor();assert.equal(await query.inputValue(),'current');}
 else if(mode.startsWith('read-search-edit-')){
  await openFixture();await pending('read');await query.fill('new');
  await release(mode==='read-search-edit-error');
  await page.getByRole('button',{name:'Open new',exact:true}).waitFor();
  assert.equal(await query.inputValue(),'new');assert.equal(await page.locator('#status').textContent(),'');
  assert.equal(await page.getByRole('heading',{name:'fixture',exact:true}).count(),0);
  assert.equal(await page.getByRole('button',{name:'Open fixture',exact:true}).count(),0);
  const name=mode+'-query.png';await page.screenshot({path:path.join(report,name),fullPage:false,animations:'disabled'});frames.push(name);
  await page.getByRole('button',{name:'History',exact:true}).click();
  await page.getByText('Words you open will appear here.',{exact:true}).waitFor();
  assert.equal(await page.getByRole('button',{name:'Open fixture',exact:true}).count(),0);
 }
 else if(mode==='read-navigation'){await openFixture();await pending('read');await settings();await release();assert.equal(await page.locator('#status').textContent(),'');}
 else if(mode==='current-read'){await openFixture();await page.getByRole('status').filter({hasText:'Controlled current read failure'}).waitFor();}
 else if(mode.startsWith('learn-')||mode==='current-random'||mode==='current-learn-read'){await page.getByRole('button',{name:'Learn',exact:true}).click();if(mode.endsWith('-navigation')){await pending(mode==='learn-random-navigation'?'random':'read');await settings();await release();assert.equal(await page.locator('#status').textContent(),'');}else await page.getByRole('status').filter({hasText:mode==='current-random'?'Controlled current random failure':'Controlled current read failure'}).waitFor();}
 else if(mode==='exact-navigation'||mode==='current-exact'){await openFixture();await page.getByRole('heading',{name:'fixture',exact:true}).waitFor();await page.getByRole('link',{name:'Broken lookup',exact:true}).click();if(mode==='exact-navigation'){await pending('exact');await settings();await release();assert.equal(await page.locator('#status').textContent(),'');}else{await page.getByRole('status').filter({hasText:'Controlled current exact failure'}).waitFor();assert.equal(await page.getByRole('heading',{name:'fixture',exact:true}).count(),1);}}
 else if(mode.startsWith('bookmark-')){
  await openFixture();await page.getByRole('heading',{name:'fixture',exact:true}).waitFor();
  const bookmark=page.getByRole('button',{name:'Bookmark',exact:true});
  const initiallySaved=mode==='bookmark-rollback-later-mutation';
  assert.equal(await bookmark.getAttribute('aria-pressed'),String(initiallySaved));assert.equal(await bookmark.textContent(),initiallySaved?'◆':'◇');
  await bookmark.evaluate(el=>{window.bookmarkControl=el;});
  await bookmark.click();await pending('saveState');assert.equal(await bookmark.isDisabled(),true);
  if(mode==='bookmark-rollback-later-mutation'){
   await page.getByRole('button',{name:'Saved',exact:true}).click();
   assert.equal(await page.getByRole('button',{name:'Open fixture',exact:true}).count(),0);
   await page.getByRole('button',{name:'Remove other',exact:true}).click();
   await page.getByText('Bookmark a word to keep it here.',{exact:true}).waitFor();
   await release(true);await page.getByRole('status').filter({hasText:'Controlled bookmark save failure'}).waitFor();
   await page.waitForFunction(()=>window.fixtureMessages.some(x=>x.fixturePersisted&&x.saveNumber===2));
   assert.deepEqual(await page.evaluate(()=>window.fixtureMessages.find(x=>x.fixturePersisted&&x.saveNumber===2).fixturePersisted),[]);
   await page.getByRole('button',{name:'Search',exact:true}).click();await query.waitFor();
   await page.getByRole('button',{name:'Saved',exact:true}).click();
   await page.getByText('Bookmark a word to keep it here.',{exact:true}).waitFor();
  }else if(mode==='bookmark-link'){
   await page.getByRole('link',{name:'Other entry',exact:true}).click();
   await release(false);await page.getByRole('heading',{name:'other',exact:true}).waitFor();
   assert.equal(await page.getByRole('heading',{name:'fixture',exact:true}).count(),0);
   assert.equal(await bookmark.getAttribute('aria-pressed'),'false');assert.equal(await bookmark.textContent(),'◇');
   const order=await page.evaluate(()=>window.fixtureMessages.filter(x=>x.fixtureCompleted).map(x=>x.fixtureCompleted));
   assert.ok(order.indexOf('saveState')<order.indexOf('exact'));
   await page.getByRole('button',{name:'Saved',exact:true}).click();
   assert.equal(await page.getByRole('button',{name:'Open fixture',exact:true}).count(),1);
   assert.equal(await page.getByRole('button',{name:'Open other',exact:true}).count(),0);
  }else if(mode==='bookmark-fragment'){
   assert.equal(await page.locator('#Destination').evaluate(el=>el.open),false);
   await page.getByRole('link',{name:'Same entry fragment',exact:true}).click();
   await page.locator('#Destination').evaluate(el=>{window.bookmarkDestination=el;window.bookmarkScrollY=scrollY;});
   assert.equal(await page.evaluate(()=>document.activeElement.id),'Destination');
   await release(false);await page.waitForFunction(()=>!window.bookmarkControl.disabled);
   assert.deepEqual(await page.evaluate(()=>({sameButton:document.querySelector('.word-actions button[aria-label="Bookmark"]')===window.bookmarkControl,sameDestination:document.getElementById('Destination')===window.bookmarkDestination,open:window.bookmarkDestination.open,focused:document.activeElement.id,scrollKept:Math.abs(scrollY-window.bookmarkScrollY)<1})),{sameButton:true,sameDestination:true,open:true,focused:'Destination',scrollKept:true});
   assert.equal(await bookmark.getAttribute('aria-pressed'),'true');assert.equal(await bookmark.textContent(),'◆');
  }else if(mode==='bookmark-error'){
   await release(true);await page.getByRole('status').filter({hasText:'Controlled bookmark save failure'}).waitFor();
   assert.equal(await bookmark.isEnabled(),true);assert.equal(await bookmark.getAttribute('aria-pressed'),'false');assert.equal(await bookmark.textContent(),'◇');
   await page.getByRole('button',{name:'Saved',exact:true}).click();await page.getByText('Bookmark a word to keep it here.',{exact:true}).waitFor();
  }else{
   await release(false);await page.waitForFunction(()=>!window.bookmarkControl.disabled);
   assert.equal(await bookmark.evaluate(el=>el===window.bookmarkControl),true);
   assert.equal(await bookmark.getAttribute('aria-pressed'),'true');assert.equal(await bookmark.textContent(),'◆');
   await bookmark.click();await page.waitForFunction(()=>window.fixtureMessages.some(x=>x.saveNumber===2));
   await release(false);await page.waitForFunction(()=>!window.bookmarkControl.disabled);
   assert.equal(await bookmark.getAttribute('aria-pressed'),'false');assert.equal(await bookmark.textContent(),'◇');
  }
 }
 else if(mode==='save-navigation'){await settings();await page.getByRole('button',{name:'dark',exact:true}).click();await pending('saveState');await page.getByRole('button',{name:'Search',exact:true}).click();await query.waitFor();await release();await page.getByRole('status').filter({hasText:'Controlled delayed saveState failure'}).waitFor();}
 cases.push({mode,passed:true,kind:mode.startsWith('current-')?'current-read-error-visible':mode==='save-navigation'?'mutation-error-visible-after-navigation':mode.startsWith('read-search-edit-')?'query-edit-cancels-open-without-history':mode.startsWith('bookmark-')?'bookmark-completion-preserves-navigation':'obsolete-read-error-ignored'});
 if(mode==='search-superseded'||mode==='save-navigation'){await page.evaluate(()=>scrollTo(0,0));await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));const name=mode+'.png';await page.screenshot({path:path.join(report,name),fullPage:false,animations:'disabled'});frames.push(name);}await ctx.close();
}
assert.deepEqual(errors,[]);assert.deepEqual(externalRequests,[]);await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,cases,frames,errors,externalRequests,scope:'Actual built UI with explicitly controlled read-only/mutation worker failures; obsolete rejection after supersession/navigation ignored; query edit cancels pending open success/failure without stale History; bookmark save completion preserves queued named links and same-entry fragment DOM/focus/fold, ordinary glyph/pressed, rollback and later-removal preservation controls; current search/read/random/exact failures and delayed saveState failure still visible. Not actual storage failure or public transport.'},null,2)+'\n');console.log('STALE_ERRORS_BROWSER_PASS');}finally{await browser?.close();await new Promise(r=>server.close(r));}
