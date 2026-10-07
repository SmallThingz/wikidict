import {chromium} from 'playwright';
import {build as buildRendererTestBundle} from 'esbuild';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
import {aliasCases,aliasPayload,dictionaryBlob,presentation} from './alias-fixtures.mjs';
const root=fileURLToPath(new URL('../build/web/',import.meta.url)),report=fileURLToPath(new URL('../artifacts/web/',import.meta.url));
await mkdir(report,{recursive:true});
const fixture=process.env.WIKBLB_FIXTURE||fileURLToPath(new URL('../tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb',import.meta.url));
const raw=await readFile(fixture),xz=execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
const server=createServer(async(req,res)=>{try{const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname),file=path.resolve(root,'.'+(name==='/'?'/index.html':name));if(!file.startsWith(root))throw Error('path');const bytes=await readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[];
try{
 const rendererBundle=await buildRendererTestBundle({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],bundle:true,format:'iife',globalName:'WikidictRendererQA',write:false});
 const rendererPage=await browser.newPage();rendererPage.on('pageerror',e=>errors.push(e.message));
 await rendererPage.setContent('<main id="compiled-renderer-fixture"></main>');
 await rendererPage.addScriptTag({content:rendererBundle.outputFiles[0].text});
 const listBlock=(kind,text,number,path,depth)=>({kind,number,path,depth,spans:[{kind:'text',text,trail:''}]});
 const renderedLists=await rendererPage.evaluate(entry=>{
  const host=document.getElementById('compiled-renderer-fixture');
  host.replaceChildren(WikidictRendererQA.renderEntry(entry,()=>{}, {collapseOtherSections:false,collapseDetails:false}));
  return {prefixes:[...host.querySelectorAll('.block.list_item > .prefix')].map(el=>el.textContent),
   indents:[...host.querySelectorAll('.block.list_item')].map(el=>parseFloat(el.style.marginInlineStart)),
   definitions:host.querySelectorAll('.block.definition').length,
   meaningSections:[...host.querySelectorAll('details.meaning > summary')].map(el=>el.textContent),
   text:host.textContent,literalLinks:host.querySelectorAll('.block.paragraph a').length};
 },{title:'Ordered fixture',kind:'supplemental',sections:[
  {title:'List',blocks:[
   listBlock('list_item','Parent ordered','3','#',1),listBlock('list_item','Nested unordered','','#*',2),
   listBlock('list_item','Nested ordered','3.1','#*#',3),listBlock('list_detail','Parent continuation','','#:',2),
   listBlock('list_item','Explicit value','8','#',1),listBlock('list_item','Following value','9','#',1),
   listBlock('list_item','Alphabetic label','AA','#',1),listBlock('list_item','Roman label','iii','#',1),
   listBlock('list_item','Roman value','xxvi','#',1),listBlock('list_item','Escaped label','<i>','#',1),listBlock('paragraph','{{example}} [[literal]]','','',0)]},
  {title:'Meaning',blocks:[listBlock('definition','Actual dictionary meaning','1','#',1)]}]});
 assert.deepEqual(renderedLists.prefixes,['3.','•','3.1.','8.','9.','AA.','iii.','xxvi.','<i>.']);
 assert.equal(await rendererPage.locator('.list_item > .prefix i').count(),0);
 assert.ok(renderedLists.indents[2]>renderedLists.indents[1] && renderedLists.indents[1]>renderedLists.indents[0]);
 assert.equal(renderedLists.definitions,1);assert.deepEqual(renderedLists.meaningSections,['Meaning']);
 assert.ok(renderedLists.text.includes('{{example}} [[literal]]'));assert.equal(renderedLists.literalLinks,0);
 const renderedTables=await rendererPage.evaluate(()=>{
  const table=(depth,caption)=>({kind:'table',depth,path:depth?'#:':'',spans:[],table:{caption:[{kind:'text',text:caption}],rows:[{cells:[{header:false,colspan:1,rowspan:1,spans:[{kind:'text',text:'Cell'}]}]}]}});
  const host=document.getElementById('compiled-renderer-fixture');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Table fixture',kind:'supplemental',sections:[{title:'Tables',blocks:[table(0,'Outer caption'),table(2,'Nested caption')]}]},()=>{}, {collapseOtherSections:false}));
  return {margins:[...host.querySelectorAll('.table-scroll')].map(el=>parseFloat(el.style.marginInlineStart)),captions:[...host.querySelectorAll('caption')].map(el=>el.textContent),rows:host.querySelectorAll('tr').length};
 });
 assert.deepEqual(renderedTables.margins,[0,.9]);
 assert.deepEqual(renderedTables.captions,['Outer caption','Nested caption']);assert.equal(renderedTables.rows,2);

 const referenceFixture=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');window.referenceNavigations=[];
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Reference fixture',kind:'supplemental',sections:[{title:'Notes',blocks:[
   {kind:'paragraph',spans:[
    {kind:'link',text:'Grouped reference',target:'#reference-2'},
    {kind:'link',text:'Ordinary title',target:'a title #reference-2 & 猫'},
    {kind:'link',text:'Unmatched fragment',target:'#reference-404'}]}]}],references:[
     {number:1,group_number:1,group:'',spans:[{kind:'text',text:'Ordinary citation'}]},
     {number:2,group_number:1,group:'note <one>',spans:[{kind:'text',text:'{{Example}} [[Link]] __NOEDITSECTION__'}]}
   ]},target=>window.referenceNavigations.push(target),{collapseOtherSections:true}));
  const reference=host.querySelector('#reference-2');
  return {initiallyClosed:!reference.closest('details').open,text:reference.textContent};
 });
 await rendererPage.addStyleTag({content:'#compiled-renderer-fixture{padding-bottom:180px}.reference{min-height:80px}#compiled-renderer-fixture .block.paragraph{min-height:1000px}#renderer-fixed-nav{position:fixed;bottom:0;left:0;right:0;height:80px;background:white;z-index:9}'});
 await rendererPage.evaluate(()=>{const nav=document.createElement('nav');nav.id='renderer-fixed-nav';nav.textContent='Reader navigation';document.body.append(nav);});
 assert.equal(referenceFixture.initiallyClosed,true);
 assert.equal(referenceFixture.text,'[note <one> 1]{{Example}} [[Link]] __NOEDITSECTION__');
 await rendererPage.getByText('Notes',{exact:true}).click();
 await rendererPage.getByRole('link',{name:'Grouped reference',exact:true}).click();
 assert.equal(await rendererPage.locator('#reference-2').isVisible(),true);
 const matchedReference=await rendererPage.evaluate(()=>{
  const reference=document.getElementById('reference-2');
  return {opened:reference.closest('details').open,focused:document.activeElement===reference,navigation:window.referenceNavigations};
 });
 assert.deepEqual(matchedReference,{opened:true,focused:true,navigation:[]});
 assert.equal(await rendererPage.locator('#reference-2').evaluate(el=>{const target=el.getBoundingClientRect(),nav=document.getElementById('renderer-fixed-nav').getBoundingClientRect();return target.top>=0&&target.bottom<=nav.top;}),true);
 const ordinaryLink=rendererPage.getByRole('link',{name:'Ordinary title',exact:true});
 assert.equal(await ordinaryLink.getAttribute('href'),'#'+encodeURIComponent('a title #reference-2 & 猫'));
 await ordinaryLink.click();
 await rendererPage.getByRole('link',{name:'Unmatched fragment',exact:true}).click();
 assert.deepEqual(await rendererPage.evaluate(()=>window.referenceNavigations),['a title #reference-2 & 猫','#reference-404']);

 await rendererPage.close();
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);await page.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await page.locator('#file').setInputFiles(fixture);await page.getByText(/English · 182 words/).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox').fill('cat');await page.getByRole('button',{name:'Open cat',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();assert.equal(await page.locator('details').filter({has:page.locator('summary').filter({hasText:/^Etymology$/})}).getAttribute('open'),null);
 assert.ok((await page.locator('#entry').innerText()).includes('A small animal'));
 assert.equal(await page.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://www.wiktionary.org/');
 for(const [width,height] of [[360,800],[768,1024],[1440,900]]){
  await page.setViewportSize({width,height});await page.evaluate(()=>scrollTo(0,0));
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'horizontal overflow');
  const centers=await page.locator('#dock button').evaluateAll(nodes=>nodes.map(n=>{const r=n.getBoundingClientRect();return r.x+r.width/2;}));const spacing=centers[1]-centers[0];assert.ok(centers.slice(1).every((x,i)=>Math.abs(x-centers[i]-spacing)<1));
  await page.screenshot({path:path.join(report,`reading-${width}.png`),fullPage:true});
 }
 await page.getByRole('button',{name:'Bookmark',exact:true}).click();await page.getByRole('button',{name:'Saved',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).waitFor();
 await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).waitFor();
 await page.getByRole('button',{name:'Learn',exact:true}).click();await page.getByRole('button',{name:'Reveal meaning'}).click();await page.getByRole('button',{name:'Got it',exact:true}).waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();
 for(const label of ['Remember words','Media cache']){await page.getByRole('slider',{name:label}).fill('1');await page.getByRole('slider',{name:label}).dispatchEvent('change');}
 assert.ok((await page.locator('#panel').innerText()).includes('100,000'));assert.ok((await page.locator('#panel').innerText()).includes('4.0 GB'));
 await page.getByRole('button',{name:'Dictionaries',exact:true}).click();await page.locator('#file').setInputFiles({name:'English.wikblb.xz',mimeType:'application/x-xz',buffer:xz});await page.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove English"]').length===2);
 await page.getByRole('button',{name:'Remove English',exact:true}).first().click();await page.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove English"]').length===1);
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox').fill('cat');await page.getByRole('button',{name:'Open cat',exact:true}).click();await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();await page.getByRole('button',{name:'Dictionaries',exact:true}).click();
 await page.locator('#file').setInputFiles({name:'bad.wikblb',mimeType:'application/octet-stream',buffer:Buffer.from('not a dictionary')});await page.getByRole('status').filter({hasText:'WIKBLB08'}).waitFor();
 await page.reload();await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).first().waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();assert.ok((await page.locator('#panel').innerText()).includes('4.0 GB'));

 await page.getByRole('button',{name:'Dictionaries',exact:true}).click();
 const supplemental=fileURLToPath(new URL('../tests/fixtures/supplemental.wikblb',import.meta.url));
 await page.locator('#file').setInputFiles(supplemental);await page.getByText(/supplemental · 2 words/).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();
 await page.getByRole('searchbox').fill('ANNEXE:É');await page.getByRole('button',{name:'Open Annexe:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Annexe:école'}).waitFor();
 assert.ok((await page.locator('#entry').innerText()).includes('Annexe:école'));
 await page.getByRole('button',{name:'Bookmark',exact:true}).click();
 await page.locator('[aria-label="Bookmark"][aria-pressed="true"]').waitFor();
 await page.reload();await page.getByRole('button',{name:'Saved',exact:true}).click();
 await page.getByRole('button',{name:'Open Annexe:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Annexe:école'}).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();
 await page.getByRole('searchbox').fill('APPENDIX:É');await page.getByRole('button',{name:'Open Appendix:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Appendix:école'}).waitFor();
 const aliases=await browser.newPage();aliases.on('pageerror',e=>errors.push(e.message));
 const prefix='enwiktionary-20261001-',english=dictionaryBlob(1,[['cat',presentation('English target definition')]]),german=dictionaryBlob(1,[['cat',presentation('German target definition')]],{language:'German',code:'de'});
 const aliasRaw=aliasCases(),aliasXZ=execFileSync('xz',['-1','-c'],{input:aliasRaw});
 const englishAsset=prefix+createHash('sha256').update('English').digest('hex')+'.wikblb',germanAsset=prefix+createHash('sha256').update('German').digest('hex')+'.wikblb';
 const downloadURL='https://fixtures.invalid/'+englishAsset;
 await aliases.route('https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list',route=>route.fulfill({contentType:'text/plain',body:downloadURL+'\tFixture English\t'+english.length+'\n'}));
 await aliases.route(downloadURL,route=>route.fulfill({contentType:'application/octet-stream',body:english}));
 await aliases.goto(`http://127.0.0.1:${server.address().port}`);
 await aliases.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await aliases.getByRole('button',{name:'Refresh lists',exact:true}).click();
 await aliases.getByRole('button',{name:'Download Fixture English',exact:true}).click();
 await aliases.getByText(/English · 1 words/).waitFor();
 const importAlias=async(name,buffer,label)=>{await aliases.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await aliases.getByText(label+' · en.wiktionary.org',{exact:true}).waitFor();};
 await importAlias(germanAsset,german,'German · 1 words · 0.0 MB');
 await importAlias(prefix+'aliases.wikblb.xz',aliasXZ,'alias · 8 words · 0.0 MB');
 await importAlias(prefix+'thesaurus.wikblb',dictionaryBlob(2,[['animal',presentation('Open beast','', 'beast')],['beast',presentation('Feature destination definition')]]),'thesaurus · 2 words · 0.0 MB');
 await importAlias(prefix+'supplemental.wikblb',dictionaryBlob(7,[]),'supplemental · 0 words · 0.0 MB');
 const stateFromDB=()=>aliases.evaluate(()=>new Promise((resolve,reject)=>{const r=indexedDB.open('wikidict-binary',1);r.onerror=()=>reject(r.error);r.onsuccess=()=>{const db=r.result,tx=db.transaction(['state','dictionaries']),a=tx.objectStore('state').get('learning'),b=tx.objectStore('dictionaries').getAll();tx.oncomplete=()=>{resolve({state:a.result,dictionaries:b.result.map(d=>({id:d.id,name:d.name}))});db.close();};};}));
 assert.ok((await stateFromDB()).dictionaries.some(d=>d.name===englishAsset),'download preserved canonical asset name');
 const searchAlias=async title=>{await aliases.getByRole('button',{name:'Search',exact:true}).click();await aliases.getByRole('searchbox').fill(title);await aliases.getByRole('button',{name:'Open '+title,exact:true}).first().waitFor();};
 const pickLanguage=(title,language)=>aliases.getByRole('button',{name:'Open '+title,exact:true}).filter({has:aliases.locator('small').filter({hasText:new RegExp('^'+language+'(?: · en\\.wiktionary\\.org)?$')})});
 await searchAlias('Cats');assert.equal(await aliases.getByRole('button',{name:'Open Cats',exact:true}).count(),2);
 await pickLanguage('Cats','German').click();await aliases.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();
 assert.ok((await aliases.locator('#entry').innerText()).includes('German target definition'));assert.ok((await aliases.locator('.entry-redirect').innerText()).includes('Cats to cat'));
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/wiki/cat');
 await aliases.getByRole('button',{name:'Bookmark',exact:true}).click();await aliases.locator('[aria-label="Bookmark"][aria-pressed="true"]').waitFor();
 const saved=(await stateFromDB()).state.saved[0];assert.equal(saved.raw_key,'1\tCats');assert.notEqual(saved.context,saved.dictionary);
 await aliases.reload();await aliases.getByRole('button',{name:'Saved',exact:true}).click();await pickLanguage('Cats','German').click();await aliases.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();assert.ok((await aliases.locator('#entry').innerText()).includes('German target definition'));
 await searchAlias('Loop A');await pickLanguage('Loop A','English').click();await aliases.locator('#entry h1').filter({hasText:/^Loop B$/}).waitFor();
 assert.ok((await aliases.locator('.entry-redirect').innerText()).includes('Loop A to Loop B#Incoming'));assert.equal(await aliases.locator('.entry-alias').innerText(),'Redirect to cat#Outgoing');
 assert.ok((await aliases.locator('#entry').innerText()).includes('Retained alias preamble'));
 await aliases.setViewportSize({width:360,height:800});assert.ok(await aliases.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'alias horizontal overflow');await aliases.screenshot({path:path.join(report,'alias-one-hop-360.png'),fullPage:true});
 await searchAlias('Self');await pickLanguage('Self','English').click();await aliases.locator('#entry h1').filter({hasText:/^Self$/}).waitFor();
 await aliases.evaluate(()=>{window.voiceLookups=0;speechSynthesis.getVoices=()=>{window.voiceLookups++;return [];};});
 await aliases.getByRole('button',{name:'Pronounce word offline',exact:true}).click();await aliases.getByRole('status').filter({hasText:'No language is identified for offline pronunciation.'}).waitFor();assert.equal(await aliases.evaluate(()=>window.voiceLookups),0);
 await searchAlias('Missing');await pickLanguage('Missing','English').click();await aliases.locator('#entry h1').filter({hasText:/^Missing$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to not installed');
 await searchAlias('To feature');await pickLanguage('To feature','English').click();await aliases.locator('#entry h1').filter({hasText:/^animal$/}).waitFor();
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/wiki/Thesaurus%3Aanimal');
 await aliases.getByRole('link',{name:'Open beast',exact:true}).click();await aliases.locator('#entry h1').filter({hasText:/^beast$/}).waitFor();assert.ok((await aliases.locator('#entry').innerText()).includes('Feature destination definition'));
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/');
 await searchAlias('To main');await pickLanguage('To main','thesaurus').click();await aliases.locator('#entry h1').filter({hasText:/^Thesaurus:To main$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to cat');
 await searchAlias('Annexe:École');await pickLanguage('Annexe:École','supplemental').click();await aliases.locator('#entry h1').filter({hasText:/^Annexe:École$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to Annexe:école');
 await aliases.getByRole('button',{name:'Settings',exact:true}).click();await aliases.getByRole('button',{name:'Dictionaries',exact:true}).click();
 await aliases.locator('#file').setInputFiles({name:'aliases.wikblb',mimeType:'application/octet-stream',buffer:aliasRaw});await aliases.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove alias"]').length===2);
 await searchAlias('Cats');await pickLanguage('Cats','language').click();await aliases.locator('#entry h1').filter({hasText:/^Cats$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to cat');
 await aliases.getByRole('button',{name:'Settings',exact:true}).click();await aliases.getByRole('button',{name:'Dictionaries',exact:true}).click();
 const badAlias=dictionaryBlob(8,[['1\tCats',aliasPayload({sourceNamespace:10})]]),countBefore=(await stateFromDB()).dictionaries.length;
 for(const buffer of [badAlias,execFileSync('xz',['-1','-c'],{input:badAlias})]){await aliases.locator('#file').setInputFiles({name:'bad-alias.wikblb',mimeType:'application/octet-stream',buffer});await aliases.getByRole('status').filter({hasText:'Invalid compiled alias'}).waitFor();}
 assert.equal((await stateFromDB()).dictionaries.length,countBefore,'malformed imports did not persist');
 for(const [name,buffer] of [[prefix+'aliases.wikblb',english],[prefix+'0'.repeat(64)+'.wikblb',english],[prefix+createHash('sha256').update('English').digest('hex')+'.wikblb',aliasRaw]]){
  await aliases.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await aliases.getByRole('status').filter({hasText:'Dictionary filename does not match its compiled header'}).waitFor();
 }
 assert.equal((await stateFromDB()).dictionaries.length,countBefore,'misnamed canonical imports did not persist');
 const mediaPage=await browser.newPage();mediaPage.on('pageerror',e=>errors.push(e.message));const mediaRequests=[];let mediaDownloads=0;
 const mediaURL='https://upload.wikimedia.org/fixture/shared.png';
 await mediaPage.route('https://commons.wikimedia.org/w/api.php*',route=>{mediaRequests.push('commons.wikimedia.org');return route.fulfill({json:{query:{pages:[{}]}}});});
 await mediaPage.route('https://*.wiktionary.org/w/api.php*',route=>{mediaRequests.push(new URL(route.request().url()).hostname);return route.fulfill({json:{query:{pages:[{imageinfo:[{url:mediaURL}]}]}}});});
 await mediaPage.route(mediaURL,route=>{mediaDownloads++;return route.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=','base64')});});
 await mediaPage.goto(`http://127.0.0.1:${server.address().port}`);await mediaPage.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 for(const [i,wiki,title] of [[1,'arwiktionary','Arabic media'],[2,'frwiktionary','French media'],[3,null,'Unknown media']]){
  const name=wiki?wiki+'-20261001-'+createHash('sha256').update('English').digest('hex')+'.wikblb':'Unknown.wikblb';
  const buffer=dictionaryBlob(1,[[title,presentation('Media source fixture','','',[{file:'Shared.png',kind:'image',caption:'Shared fixture'}])],['Shared title',presentation('Edition selection fixture')]],{code:wiki?'en':'und'});
  await mediaPage.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await mediaPage.waitForFunction(n=>document.querySelectorAll('[aria-label="Remove English"]').length===n,i);
 }
 await mediaPage.getByText('English · 2 words · 0.0 MB · ar.wiktionary.org',{exact:true}).waitFor();await mediaPage.getByText('English · 2 words · 0.0 MB · fr.wiktionary.org',{exact:true}).waitFor();
 await mediaPage.getByRole('button',{name:'Search',exact:true}).click();await mediaPage.getByRole('searchbox').fill('Shared title');await mediaPage.getByRole('button',{name:'Open Shared title',exact:true}).first().waitFor();
 assert.deepEqual((await mediaPage.getByRole('button',{name:'Open Shared title',exact:true}).locator('small').allTextContents()).sort(),['English','English · ar.wiktionary.org','English · fr.wiktionary.org']);
 await mediaPage.getByRole('button',{name:'Settings',exact:true}).click();await mediaPage.getByRole('switch',{name:'Load images online',exact:true}).check();
 for(const [title,host] of [['Arabic media','ar.wiktionary.org'],['French media','fr.wiktionary.org'],['Unknown media',null]]){
  await mediaPage.getByRole('button',{name:'Search',exact:true}).click();await mediaPage.getByRole('searchbox').fill(title);await mediaPage.getByRole('button',{name:'Open '+title,exact:true}).click();await mediaPage.locator('#entry h1').filter({hasText:title}).waitFor();await mediaPage.getByText('Images & sound',{exact:true}).click();await mediaPage.getByText('Shared fixture',{exact:true}).click();
  if(host){await mediaPage.getByRole('link',{name:'Source & licence',exact:true}).waitFor();assert.equal(await mediaPage.getByRole('link',{name:'Source & licence',exact:true}).getAttribute('href'),'https://'+host+'/wiki/File:Shared.png');}
  else await mediaPage.getByText('Media unavailable',{exact:true}).waitFor();
 }
 assert.deepEqual(mediaRequests,['commons.wikimedia.org','ar.wiktionary.org','commons.wikimedia.org','fr.wiktionary.org','commons.wikimedia.org']);assert.equal(mediaDownloads,2);
 assert.deepEqual(await mediaPage.evaluate(async()=>(await(await caches.open('wikidict-media-v1')).keys()).map(r=>new URL(r.url).hostname).sort()),['ar.wiktionary.org','fr.wiktionary.org']);
 await mediaPage.evaluate(()=>{window.voiceLookups=0;speechSynthesis.getVoices=()=>{window.voiceLookups++;return [];};});await mediaPage.getByRole('button',{name:'Pronounce word offline',exact:true}).click();await mediaPage.getByRole('status').filter({hasText:'No language is identified for offline pronunciation.'}).waitFor();assert.equal(await mediaPage.evaluate(()=>window.voiceLookups),0,'und does not select an unrelated voice');
 const delivery=await browser.newPage();delivery.on('pageerror',e=>errors.push(e.message));
 await delivery.route('https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list',route=>route.fulfill({contentType:'text/plain',body:downloadURL+'\tFixture English\t'+english.length+'\n'}));await delivery.route(downloadURL,route=>route.abort('failed'));
 await delivery.goto(`http://127.0.0.1:${server.address().port}`);await delivery.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 assert.equal(await delivery.getByRole('link',{name:'Open downloads in browser',exact:true}).getAttribute('href'),'https://github.com/SmallThingz/wikidict/releases/latest');
 await delivery.getByRole('button',{name:'Refresh lists',exact:true}).click();await delivery.getByRole('button',{name:'Download Fixture English',exact:true}).click();await delivery.getByRole('status').filter({hasText:'Use the browser download, then import the file.'}).waitFor();
 const fallback=delivery.getByRole('link',{name:'Download Fixture English in browser',exact:true});assert.equal(await fallback.getAttribute('href'),downloadURL);assert.equal(await fallback.getAttribute('rel'),'noopener noreferrer');
 await delivery.locator('#file').setInputFiles({name:englishAsset,mimeType:'application/octet-stream',buffer:english});await delivery.getByText(/English · 1 words/).waitFor();
 await delivery.getByRole('button',{name:'Search',exact:true}).click();await delivery.getByRole('searchbox').fill('cat');await delivery.getByRole('button',{name:'Open cat',exact:true}).click();await delivery.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();assert.ok((await delivery.locator('#entry').innerText()).includes('English target definition'));
 assert.deepEqual(errors,[]);await writeFile(path.join(report,'report.json'),JSON.stringify({status:'passed',rawBytes:raw.length,xzBytes:xz.length,aliasCases:8,aliasRawAndXZ:true,savedAliasContext:true,mediaRequests,mediaDownloads,errors},null,2));console.log('WEB_BINARY_PARITY_AND_ALIAS_PASS');
}finally{await browser.close();server.close();}
