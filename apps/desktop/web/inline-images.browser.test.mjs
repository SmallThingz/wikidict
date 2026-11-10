// Proposed normal-package Playwright controls; no live network, no new runner.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
const renderer=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const media=await build({entryPoints:[new URL('./media.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Media',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage();await page.route('**/*',r=>r.abort());await page.setContent('<main></main>');await page.addScriptTag({content:renderer.outputFiles[0].text});await page.addScriptTag({content:media.outputFiles[0].text});
 if(process.env.WIKIDICT_WEB_IMAGE_THEME_ONLY!=='1'&&process.env.WIKIDICT_WEB_CAPTION_ONLY!=='1'){
 if(process.env.WIKIDICT_WEB_RICH_ONLY!=='1'){
 const disabled=await page.evaluate(async()=>{
  window.calls=0;window.followed=[];window.fetch=async()=>{window.calls++;throw Error('control failure');};
  const image=(alt,scale=0)=>({kind:'link',target:'File:Vraagteken-2.svg',text:'',font_scale:scale,image:{file:'Vraagteken-2.svg',width_px:15,...alt}});
  window.entry={title:'Inline controls',sections:[{title:'עברית',level:2,anchor:'עברית',blocks:[{kind:'heading',level:2,spans:[{kind:'text',text:'עברית'},image({})]},{kind:'paragraph',spans:[image({alt:'',tooltip:''}),image({alt:'איקס',tooltip:'איקס'},2)]}]}],references:[{number:1,group_number:1,spans:[],blocks:[{kind:'paragraph',spans:[image({alt:'וי',tooltip:'וי'})]}]}],media:[{file:'Vraagteken-2.svg',kind:'image',caption:'catalog-only'}]};
  const render=allow=>Renderer.renderEntry(window.entry,t=>window.followed.push(t),{},()=>null,(el,img)=>Media.loadInlineImage(el,img,{allowImages:allow,mediaCacheMb:0},'hewiktionary'),target=>Media.inlineImageActionURL(target,'hewiktionary'));
  window.renderImages=render;document.querySelector('main').append(render(false));
  await Promise.resolve();const imgs=[...document.querySelectorAll('img')];return {count:imgs.length,widths:imgs.map(e=>parseFloat(e.style.width)),hiddenBoxes:imgs.map(e=>({width:e.getBoundingClientRect().width,height:e.getBoundingClientRect().height,display:getComputedStyle(e).display})),fallbacks:[...document.querySelectorAll('.compiled-image-status')].map(e=>({text:e.textContent,width:e.getBoundingClientRect().width,label:e.getAttribute('aria-label')})),align:imgs.map(e=>getComputedStyle(e).verticalAlign),border:imgs.map(e=>getComputedStyle(e).borderTopWidth),alt:imgs.map(e=>e.getAttribute('alt')),titles:imgs.map(e=>e.getAttribute('title')),text:document.querySelector('main').textContent,states:imgs.map(e=>e.dataset.mediaState),calls:window.calls};
 });
 assert.equal(disabled.count,4);assert.deepEqual(disabled.widths,[15,15,15,15]);assert.deepEqual(disabled.alt,[null,'','איקס','וי']);assert.deepEqual(disabled.titles,[null,'','איקס','וי']);assert.ok(!disabled.text.includes('Vraagteken'));assert.ok(disabled.text.includes('איקס')&&disabled.text.includes('וי'));assert.equal(disabled.calls,0);assert.ok(disabled.states.every(v=>v==='disabled'));
 assert.deepEqual(disabled.fallbacks.map(v=>v.text),['','','איקס','וי']);assert.ok(disabled.fallbacks.every(v=>v.width>0));assert.ok(disabled.fallbacks[2].label.includes('איקס'));assert.ok(disabled.hiddenBoxes.every(v=>v.width===0&&v.height===0&&v.display==='none'));
 assert.deepEqual(disabled.align,['middle','middle','middle','middle']);assert.deepEqual(disabled.border,['0px','0px','0px','0px']);
 assert.equal(await page.locator('a').first().getAttribute('href'),'https://he.wiktionary.org/wiki/File%3AVraagteken-2.svg');assert.deepEqual(await page.evaluate(()=>window.followed),[]);
 await page.evaluate(()=>document.querySelector('main').replaceChildren(window.renderImages(true)));
 await page.waitForFunction(()=>[...document.querySelectorAll('img')].every(e=>e.dataset.mediaState==='error'));
 assert.ok((await page.locator('img').evaluateAll(v=>v.map(e=>({w:e.getBoundingClientRect().width,h:e.getBoundingClientRect().height,display:getComputedStyle(e).display})))).every(v=>v.w===0&&v.h===0&&v.display==='none'));assert.equal(await page.locator('img').count(),4);assert.equal(await page.locator('img').nth(2).getAttribute('alt'),'איקס');
 assert.deepEqual(await page.locator('.compiled-image-status').allTextContents(),['','','איקס','וי']);assert.equal(await page.locator('a').first().getAttribute('href'),'https://he.wiktionary.org/wiki/File%3AVraagteken-2.svg');
 await page.evaluate(()=>{
  const png=window.controlPng=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ0kAAAAASUVORK5CYII='),c=>c.charCodeAt(0));
  window.caches={open:async()=>({match:async()=>null})};
  window.assetCalls={metadata:0,blob:0};window.revoked=[];const revoke=URL.revokeObjectURL.bind(URL);URL.revokeObjectURL=url=>{window.revoked.push(url);revoke(url);};
  window.fetch=async url=>{if(url.includes('/w/api.php')){window.assetCalls.metadata++;return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/control.png',width:1,height:1}]}]}}),{headers:{'Content-Type':'application/json'}});}window.assetCalls.blob++;return new Response(png,{headers:{'Content-Type':'image/png'}});};
  document.querySelector('main').replaceChildren(window.renderImages(true));
 });
 await page.waitForFunction(()=>[...document.querySelectorAll('img')].every(e=>e.dataset.mediaState.startsWith('loaded')));
 const sizes=await page.locator('img').evaluateAll(v=>v.map(e=>({w:e.getBoundingClientRect().width,h:e.getBoundingClientRect().height,src:e.src,display:getComputedStyle(e).display})));assert.ok(sizes.every(e=>e.w===15&&e.h===15&&e.src.startsWith('blob:')&&e.display==='inline'));
 assert.equal(await page.locator('.compiled-image-status').count(),0);assert.ok(!(await page.locator('main').textContent()).includes('איקס'));
 assert.equal(new Set(sizes.map(e=>e.src)).size,1);assert.deepEqual(await page.evaluate(()=>window.assetCalls),{metadata:1,blob:1});
 await page.evaluate(()=>document.querySelector('main').replaceChildren(window.renderImages(true)));
 await page.waitForFunction(()=>[...document.querySelectorAll('main img')].every(e=>e.dataset.mediaState.startsWith('loaded')));
 assert.deepEqual(await page.evaluate(()=>window.assetCalls),{metadata:1,blob:1});assert.equal(await page.locator('main img').first().getAttribute('src'),sizes[0].src);
 await page.evaluate(()=>document.querySelector('main').replaceChildren());await page.waitForFunction(()=>window.revoked.length===1);assert.equal(await page.evaluate(()=>window.revoked[0]),sizes[0].src);
 const actions=await page.evaluate(()=>{
  const host=document.createElement('div');host.id='action-controls';const image={file:'Vraagteken-2.svg',width_px:15};
  const values=[{kind:'text',target:'',text:'',image},{kind:'link',target:'File:Override.svg#עברית section',text:'',image},{kind:'link',target:'Target',text:'',image},{kind:'external_link',target:'https://example.org/override',text:'',image}];
  host.append(Renderer.spans(values,t=>window.followed.push(t),false,{inlineImage:(el,image)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'hewiktionary'),imageActionURL:t=>Media.inlineImageActionURL(t,'hewiktionary')}));document.body.append(host);
  const unknown=document.createElement('div');unknown.id='unknown-action-controls';unknown.append(Renderer.spans([values[1]],t=>window.followed.push(t),false,{imageActionURL:t=>Media.inlineImageActionURL(t,null)}));document.body.append(unknown);
  return {links:[...host.querySelectorAll('a')].map(e=>e.getAttribute('href')),inert:host.firstElementChild.tagName,unknown:unknown.querySelector('[aria-disabled="true"]')?.dataset.actionTarget};
 });
 assert.deepEqual(actions.links,['https://he.wiktionary.org/wiki/File%3AOverride.svg#%D7%A2%D7%91%D7%A8%D7%99%D7%AA%20section','#Target','https://example.org/override']);assert.equal(actions.inert,'SPAN');assert.equal(actions.unknown,'File:Override.svg#עברית section');
 await page.waitForFunction(()=>{const images=[...document.querySelectorAll('#action-controls img')];return images.length===4&&images.every(el=>{const box=el.getBoundingClientRect();return el.dataset.mediaState==='loaded'&&box.width>0&&box.height>0;});});
 await page.locator('#action-controls a').nth(1).click();
 assert.deepEqual(await page.evaluate(()=>window.followed),['Target']);
 const actionOwner=await page.evaluate(()=>{
  const images=[...document.querySelectorAll('#action-controls img')],sources=[...new Set(images.map(el=>el.src))],originals=images.map(el=>[el.naturalWidth,el.naturalHeight]);
  document.getElementById('action-controls').remove();document.getElementById('unknown-action-controls').remove();return {sources,originals};
 });
 assert.equal(actionOwner.sources.length,1);assert.deepEqual(actionOwner.originals,Array.from({length:4},()=>[1,1]));
 await page.waitForFunction(source=>window.revoked.includes(source),actionOwner.sources[0]);
 await page.evaluate(()=>{
  window.requestedTitles=[];window.fetch=async url=>{window.requestedTitles.push(new URL(url).searchParams.get('titles'));throw Error('endpoint control');};
  const el=document.createElement('img');document.body.append(el);Media.loadInlineImage(el,{file:'File:foo.svg'},{allowImages:true,mediaCacheMb:0},'hewiktionary');
  const legacy=Media.mediaView({file:'File:foo.svg',kind:'image',caption:''},{allowImages:true,mediaCacheMb:0},'hewiktionary');document.body.append(legacy);legacy.open=true;
 });
 await page.waitForFunction(()=>window.requestedTitles.length===2);
 assert.deepEqual(await page.evaluate(()=>window.requestedTitles),['File:File:foo.svg','File:foo.svg']);
 await page.evaluate(()=>{
  // Original HE geometries supplied by the source owner; assets remain mocked.
  window.heOriginals={'File:Vraagteken-2.svg':{width:128,height:214,thumbwidth:15,thumbheight:26},'File:X mark.svg':{width:525,height:600,thumbwidth:15,thumbheight:18},'File:Yes check.svg':{width:600,height:600,thumbwidth:15,thumbheight:14}};
  window.sizeQueries=[];window.fetch=async url=>{
   if(url.includes('/w/api.php')){const q=new URL(url).searchParams;window.sizeQueries.push(q.get('iiprop'));const title=q.get('titles'),known=!title.startsWith('File:unknown');return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/one-pixel-thumbnail.png',...(known?(window.heOriginals[title]||(title==='File:tall.svg'?{width:100,height:300}:title==='File:rounding.svg'?{width:2001,height:1000}:{width:200,height:100})):{} )}]}]}}));}
   return new Response(window.controlPng,{headers:{'Content-Type':'image/png'}});
  };
  const host=document.createElement('div');host.id='aspect-controls';
  window.hugeImage={file:'huge.svg',width_px:4294967295,height_px:4294967295};
  const images=[{width_px:15,height_px:20},{width_px:15},{height_px:20},{},{file:'tall.svg',width_px:15,height_px:20},{file:'unknown.svg'},{file:'unknown-width.svg',width_px:15},{file:'unknown-both.svg',width_px:15,height_px:20},{file:'rounding.svg',width_px:15},window.hugeImage,{file:'Vraagteken-2.svg',width_px:15},{file:'X mark.svg',width_px:15},{file:'Yes check.svg',width_px:15}].map(v=>({kind:'text',target:'',text:'',image:{file:'source.svg',...v}}));
  host.append(Renderer.spans(images,()=>{},false,{inlineImage:(el,image)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'hewiktionary')}));document.body.append(host);
 });
 await page.waitForFunction(()=>[...document.querySelectorAll('#aspect-controls img')].every(e=>['loaded','intrinsic-unresolved','geometry-unresolved'].includes(e.dataset.mediaState)));
 const geometry=await page.locator('#aspect-controls img').evaluateAll(v=>v.map(e=>({w:parseFloat(e.style.width),h:parseFloat(e.style.height),fit:getComputedStyle(e).objectFit,state:e.dataset.mediaState,hidden:e.hidden})));
 assert.deepEqual([0,1,3,4,8].map(i=>[geometry[i].w,geometry[i].h]),[[15,8],[15,8],[200,100],[6,20],[15,7]]);assert.equal(geometry[2].state,'geometry-unresolved');assert.equal(geometry[2].hidden,true);assert.equal(geometry[5].state,'intrinsic-unresolved');assert.equal(geometry[5].hidden,true);for(const i of [6,7]){assert.equal(geometry[i].state,'intrinsic-unresolved');assert.equal(geometry[i].hidden,true);}
 // Client dimensions use original geometry, independently of API thumbnail pixels.
 assert.deepEqual(geometry.slice(10).map(({w,h})=>[w,h]),[[15,25],[15,17],[15,15]]);
 assert.deepEqual(await page.evaluate(()=>Object.values(window.heOriginals).map(v=>[v.thumbwidth,v.thumbheight])),[[15,26],[15,18],[15,14]]);
 assert.ok(geometry.every(v=>v.fit==='fill'));
 assert.ok(geometry[9].w<=10000&&geometry[9].h<=10000);assert.ok(Math.abs(geometry[9].w-10000)<.1&&Math.abs(geometry[9].h-5000)<.1);assert.deepEqual(await page.evaluate(()=>window.hugeImage),{file:'huge.svg',width_px:4294967295,height_px:4294967295});
 const status=await page.locator('#aspect-controls .compiled-image-status').evaluateAll(v=>v.map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:e.textContent,width:e.getBoundingClientRect().width})));
 assert.equal(status.length,4);assert.ok(status.every(e=>e.role==='img'&&e.label.includes('unavailable')&&e.text===''&&e.width===15));
 assert.ok(!(await page.locator('#aspect-controls').ariaSnapshot()).includes('unknown.svg'));
 const pending=await page.evaluate(()=>{
  const host=document.createElement('div');const image={file:'pending.svg',width_px:4294967295,height_px:2147483647},before=JSON.stringify(image);host.append(Renderer.spans([{kind:'text',target:'',text:'',image}]));document.body.append(host);const el=host.querySelector('img');return {width:parseFloat(el.style.width),height:parseFloat(el.style.height),unchanged:before===JSON.stringify(image),maxWidth:el.style.maxWidth,maxHeight:el.style.maxHeight};
 });
 assert.equal(pending.width,10000);assert.ok(Math.abs(pending.height-5000)<.1);assert.equal(pending.unchanged,true);assert.equal(pending.maxWidth,'10000px');assert.equal(pending.maxHeight,'10000px');
 assert.ok((await page.evaluate(()=>window.sizeQueries)).every(v=>v==='url|size|mime|extmetadata'));
 await page.evaluate(()=>{
  window.mediaControl={running:0,peak:0,calls:0,pending:[]};window.fetch=()=>new Promise((resolve,reject)=>{const c=window.mediaControl;c.calls++;c.running++;c.peak=Math.max(c.peak,c.running);c.pending.push(()=>{c.running--;reject(Error('finite queue control'));});});
  const host=document.createElement('div');host.id='queue-controls';
  host.append(Renderer.spans(Array.from({length:10},(_,i)=>({kind:'text',target:'',text:'',image:{file:'queue'+i+'.png',width_px:15}})),()=>{},false,{inlineImage:(el,image)=>Media.loadInlineImage(el,image,{allowImages:true},'hewiktionary')}));document.body.append(host);host.lastElementChild.remove();
 });
 for(const count of [4,4,1]){await page.waitForFunction(n=>window.mediaControl.pending.length===n,count);await page.evaluate(()=>{const pending=window.mediaControl.pending.splice(0);pending.forEach(release=>release());});}
 await page.waitForFunction(()=>[...document.querySelectorAll('#queue-controls img')].every(e=>e.dataset.mediaState==='error'));
 assert.deepEqual(await page.evaluate(()=>({calls:window.mediaControl.calls,peak:window.mediaControl.peak,running:window.mediaControl.running})),{calls:9,peak:4,running:0});
 await page.evaluate(()=>{
  window.joinedCalls={titles:[],blobs:0,canonical:[]};window.fetch=async url=>{
   if(url.includes('/w/api.php')){window.joinedCalls.titles.push(new URL(url).searchParams.get('titles'));return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/joined.png',width:1,height:1}]}]}}));}
   window.joinedCalls.blobs++;return new Response(window.controlPng,{headers:{'Content-Type':'image/png'}});
  };
  const host=document.createElement('div');host.id='joined-catalog';
  const entry={title:'Joined identity',sections:[],references:[{number:1,group_number:1,spans:[],blocks:[{kind:'paragraph',spans:[{kind:'text',target:'',text:'',image:{file:'File:foo.svg',width_px:15}}]}]}],media:[{file:'File:foo.svg',kind:'image',caption:'catalog-control'}]};
  host.append(Renderer.renderEntry(entry,()=>{},{},(m,canonical)=>{window.joinedCalls.canonical.push(canonical);return Media.mediaView(m,{allowImages:true,mediaCacheMb:0},'hewiktionary',canonical);},(el,image)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'hewiktionary')));document.body.append(host);
 });
 await page.waitForFunction(()=>document.querySelector('#joined-catalog img')?.dataset.mediaState==='loaded');
 await page.locator('#joined-catalog details details').evaluate(e=>e.open=true);
 await page.waitForFunction(()=>document.querySelectorAll('#joined-catalog img').length===2);
 assert.deepEqual(await page.evaluate(()=>window.joinedCalls),{titles:['File:File:foo.svg'],blobs:1,canonical:[true]});
 assert.equal(new Set(await page.locator('#joined-catalog img').evaluateAll(v=>v.map(e=>e.src))).size,1);
 // Match the actual site's global sizing rule: border is outside the authored content box.
 await page.addStyleTag({content:'*{box-sizing:border-box}'});
 await page.evaluate(async()=>{
  const canvas=document.createElement('canvas');canvas.width=4;canvas.height=2;canvas.getContext('2d').fillRect(0,0,4,2);
  const raster=new Uint8Array(await (await new Promise(resolve=>canvas.toBlob(resolve,'image/png'))).arrayBuffer());
  const svg='<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><path fill="red" d="M0 0h400v200H0z"/></svg>';
  window.fetch=async url=>{
   if(url.includes('/w/api.php')){const file=new URL(url).searchParams.get('titles'),vector=file.endsWith('.svg');return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/'+(vector?'border-flag.svg':'border-book.png'),width:vector?400:4,height:vector?200:2}]}]}}));}
   return url.endsWith('.svg')?new Response(svg,{headers:{'Content-Type':'image/svg+xml'}}):new Response(raster,{headers:{'Content-Type':'image/png'}});
  };
  const host=document.createElement('div');host.id='border-controls';window.borderFollowed=[];
  window.borderValues=['svg','png'].flatMap((extension,i)=>[undefined,false,true].map((border,j)=>({kind:'link',target:i?'Target':'File:Border flag.svg',text:'',font_scale:0,image:{file:i?'Border book.png':'Border flag.svg',width_px:i?30:40,alt:(i?'Book ':'Flag ')+['absent','false','true'][j],tooltip:'unchanged tooltip',...(border===undefined?{}:{border})}})));
  window.borderBefore=JSON.stringify(window.borderValues);
  host.append(Renderer.spans(window.borderValues,target=>window.borderFollowed.push(target),false,{inlineImage:(el,image)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'itwiktionary'),imageActionURL:target=>Media.inlineImageActionURL(target,'itwiktionary')}));document.body.append(host);
 });
 await page.waitForFunction(()=>[...document.querySelectorAll('#border-controls img')].length===6&&[...document.querySelectorAll('#border-controls img')].every(el=>el.dataset.mediaState==='loaded'));
 const bordered=await page.locator('#border-controls img').evaluateAll(images=>images.map(el=>{
  const style=getComputedStyle(el),box=el.getBoundingClientRect();return {width:box.width,height:box.height,contentWidth:parseFloat(style.width),contentHeight:parseFloat(style.height),border:[style.borderTopWidth,style.borderRightWidth,style.borderBottomWidth,style.borderLeftWidth],color:style.borderTopColor,line:style.borderTopStyle,padding:[style.paddingTop,style.paddingRight,style.paddingBottom,style.paddingLeft],boxSizing:style.boxSizing,alt:el.getAttribute('alt'),tooltip:el.getAttribute('title'),target:el.closest('a').getAttribute('href')};
 }));
 assert.deepEqual(bordered.map(({width,height})=>[width,height]),[[40,20],[40,20],[42,22],[30,15],[30,15],[32,17]]);
 assert.deepEqual(bordered.map(({contentWidth,contentHeight})=>[contentWidth,contentHeight]),[[40,20],[40,20],[40,20],[30,15],[30,15],[30,15]]);
 for(let i=0;i<bordered.length;i++){
  const value=bordered[i],enabled=i%3===2;assert.deepEqual(value.border,Array(4).fill(enabled?'1px':'0px'));assert.deepEqual(value.padding,Array(4).fill('0px'));assert.equal(value.tooltip,'unchanged tooltip');
  if(enabled){assert.equal(value.color,'rgb(234, 236, 240)');assert.equal(value.line,'solid');assert.equal(value.boxSizing,'content-box');}
 }
 assert.deepEqual(bordered.map(value=>value.alt),['Flag absent','Flag false','Flag true','Book absent','Book false','Book true']);
 assert.ok(bordered.slice(0,3).every(value=>value.target==='https://it.wiktionary.org/wiki/File%3ABorder%20flag.svg'));
 assert.ok(bordered.slice(3).every(value=>value.target==='#Target'));
 assert.equal(await page.getByRole('img',{name:'Flag true',exact:true}).count(),1);assert.equal(await page.getByRole('img',{name:'Book true',exact:true}).count(),1);
 await page.locator('#border-controls a').last().focus();await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>window.borderFollowed),['Target']);
 assert.equal(await page.evaluate(()=>JSON.stringify(window.borderValues)===window.borderBefore),true);
 const badBorders=await page.evaluate(()=>[null,1,'true',{}].map(border=>{try{Renderer.spans([{kind:'text',target:'',text:'',image:{file:'Border flag.svg',border}}]);return false;}catch(error){return error.message==='Invalid inline image border';}}));
 assert.deepEqual(badBorders,[true,true,true,true]);
 await page.locator('#border-controls').screenshot({path:new URL('../artifacts/web/inline-image-border-controls.png',import.meta.url).pathname});
  const heightCases=await page.evaluate(async()=>{
   const canvas=document.createElement('canvas');canvas.width=100;canvas.height=50;canvas.getContext('2d').fillRect(0,0,100,50);const png=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
   const cases=[{name:'raster-limited',mime:'image/png',height:25,expected:[52,27]},{name:'raster-native-bound',mime:'image/png',height:100,expected:[102,52]},{name:'svg-png-thumbnail',mime:'image/svg+xml',height:25,expected:null},{name:'unknown-original',mime:null,height:25,expected:null}];
   window.heightRequests=[];window.fetch=async url=>{if(url.includes('/w/api.php')){heightRequests.push(url);const title=new URL(url).searchParams.get('titles'),test=cases.find(row=>title==='File:'+row.name+'.png');return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/'+test.name+'.png',width:100,height:50,...(test.mime?{mime:test.mime}:{})}]}]}}));}return new Response(png,{headers:{'Content-Type':'image/png'}});};
   const root=document.createElement('div');root.id='height-controls';document.body.append(root);window.heightModels=cases.map(test=>({file:test.name+'.png',height_px:test.height,alt:test.name,tooltip:'Height test '+test.name,border:true}));window.heightBefore=JSON.stringify(heightModels);
   for(const image of heightModels){const link=document.createElement('a');link.href='https://example.test/';const el=document.createElement('img');el.alt=image.alt;el.title=image.tooltip;el.style.cssText='display:inline-block;margin:0;max-width:none;max-height:none;border:1px solid #eaecf0;box-sizing:content-box;padding:0';link.append(el);root.append(link);Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},null);}
   return cases;
  });
  await page.waitForFunction(()=>[...document.querySelectorAll('#height-controls img')].every(el=>['loaded','geometry-unresolved'].includes(el.dataset.mediaState)));
  const heightObserved=await page.locator('#height-controls img').evaluateAll(images=>images.map(el=>{const box=el.getBoundingClientRect();return {state:el.dataset.mediaState,width:box.width,height:box.height,alt:el.alt,tooltip:el.title,target:el.closest('a').getAttribute('href')};}));
  for(let i=0;i<heightCases.length;i++){const test=heightCases[i],observed=heightObserved[i];assert.equal(observed.state,test.expected?'loaded':'geometry-unresolved');if(test.expected)assert.deepEqual([observed.width,observed.height],test.expected);assert.equal(observed.alt,test.name);assert.equal(observed.tooltip,'Height test '+test.name);assert.equal(observed.target,'https://example.test/');}
  assert.equal(await page.evaluate(()=>heightRequests.length===4&&heightRequests.every(url=>new URL(url).searchParams.get('iiprop').split('|').includes('mime'))&&JSON.stringify(heightModels)===heightBefore),true);
  await page.screenshot({path:new URL('../artifacts/web/height-only-original-mime-360.png',import.meta.url).pathname,fullPage:true});assert.equal(heightObserved.length,4);
 }
  // J is a real recursive DOM path, sharing the existing permission/cache owner.
  await page.addStyleTag({content:await (await import('node:fs/promises')).readFile(new URL('./style.css',import.meta.url),'utf8')});
  const richSetup=await page.evaluate(()=>{
    document.body.replaceChildren(document.createElement('main'));window.richCalls={metadata:0,blob:0};window.richFollowed=[];
    window.caches={open:async()=>({match:async()=>null})};
    window.controlPng=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ0kAAAAASUVORK5CYII='),c=>c.charCodeAt(0));
    window.fetch=async url=>{if(url.includes('/w/api.php')){richCalls.metadata++;return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/rich-control.png',width:200,height:100,mime:'image/svg+xml'}]}]}}));}richCalls.blob++;return new Response(window.controlPng,{headers:{'Content-Type':'image/png'}});};
    const length=value=>({unit:'px',value}),edges=value=>Object.fromEntries(['top','right','bottom','left'].map(key=>[key,length(value)])),native={kind:'native_theme'},transparent={kind:'transparent'};
    const text=text=>({kind:'text',text}),link=(text,target)=>({kind:'link',text,target}),paragraph=spans=>({kind:'paragraph',spans});
    const figure=(sizing='requested_fit',format='thumbnail')=>({image_span:{kind:'text',text:'',image:{file:'rich-control.svg',width_px:80,alt:'controlled figure',tooltip:''}},caption:[],format,sizing,placement:'none',clear:'none',margins:edges(0),image_insets:edges(2),caption_padding:edges(3),caption_font_scale:.8,caption_line_height:length(18),frame_background:native,frame_border:{kind:'solid',width:length(1),color:{kind:'rgb',value:'#334455'}},image_background:transparent,image_border:{kind:'none'},caption_foreground:native,caption_background:native});
    const first=figure();first.frame_min_width=length(160);first.placement='float_right';first.clear='both';first.caption_blocks=[paragraph([link('Caption action','Caption target')]),{kind:'table',spans:[],table:{caption:[],caption_blocks:[paragraph([link('Table caption','Table destination')])],rows:[{cells:[{spans:[text('Cell content')]}]}]}}];
    const map=figure('intrinsic','framed');map.image_span.image.map={description:'top_left',regions:[{shape:'rectangle',coordinates:[0,0,100,100],action:{kind:'internal',target:'Region',target_fragment:'piece',label:'Region action'}},{shape:'circle',coordinates:[150,50,20],action:{kind:'external',target:'https://example.test/map',target_fragment:null,label:'Circle action'}},{shape:'polygon',coordinates:[100,0,200,0,200,100],action:{kind:'internal',target:'Polygon',target_fragment:null,label:'Polygon action'}}],default_action:{kind:'internal',target:'Fallback',target_fragment:'',label:'Default action'}};
    map.caption_blocks=[];
    window.richEntry={presentation_version:'DPRJ',title:'Rich content',kind:'language',language:'English',source_edition:'enwiktionary',display_title:[text('Rich content')],sections:[{level:2,title:'English',blocks:[{kind:'paragraph',spans:[],style:{margins:edges(1),padding:edges(2)},flow:[{kind:'inline',spans:[text('Before ')]},{kind:'scope',spans:[],scope:{mode:'isolate',authored_direction:'auto',resolved_direction:'rtl',language:'he',parts:[{kind:'inline',spans:[text('אבג ')]},{kind:'figure',spans:[],figure:first},{kind:'inline',spans:[link('After figure','After target')]}]}},{kind:'inline',spans:[text(' Suffix')]}]}, {kind:'paragraph',spans:[],figure:map},paragraph([{kind:'text',text:'Advice',tooltip:''},{kind:'link',text:'Explained',target:'Explanation target',tooltip:'authored advice',explanation:'Expansion remains accessible'}])]}],references:[],media:[{kind:'image',file:'rich-control.svg',caption:'Catalogue'}]};
    window.richBefore=JSON.stringify(richEntry);window.richRender=allow=>Renderer.renderEntry(richEntry,(...args)=>richFollowed.push(args),{},()=>null,(el,image,occurrence)=>Media.loadInlineImage(el,image,{allowImages:allow,mediaCacheMb:0},'enwiktionary',occurrence),target=>Media.inlineImageActionURL(target,'enwiktionary'));
    document.querySelector('main').append(richRender(false));return {text:document.querySelector('main').textContent};
  });
  await page.waitForFunction(()=>[...document.querySelectorAll('main img')].every(el=>el.dataset.mediaState==='disabled'));
  assert.deepEqual(await page.evaluate(()=>richCalls),{metadata:0,blob:0});
  assert.equal(await page.locator('main figure').count(),2);assert.equal(await page.locator('main figcaption').count(),2); // second exists only for authored padding
  assert.equal(await page.locator('main .compiled-bidi-scope').getAttribute('dir'),'rtl');
  assert.equal(await page.locator('main .compiled-bidi-scope').evaluate(el=>getComputedStyle(el).unicodeBidi),'isolate');
  assert.ok(richSetup.text.indexOf('Before')<richSetup.text.indexOf('Caption action')&&richSetup.text.indexOf('Caption action')<richSetup.text.indexOf('After figure')&&richSetup.text.indexOf('After figure')<richSetup.text.indexOf('Suffix'));
  assert.equal(await page.locator('main caption').innerText(),'Table caption');
  await page.getByRole('link',{name:'Caption action',exact:true}).focus();await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>richFollowed),[['Caption target']]);
  await page.evaluate(()=>document.querySelector('main').replaceChildren(richRender(true)));
  await page.waitForFunction(()=>[...document.querySelectorAll('main img')].every(el=>el.dataset.mediaState==='loaded'));
  assert.deepEqual(await page.evaluate(()=>richCalls),{metadata:1,blob:1});
  const richGeometry=await page.locator('main figure').evaluateAll(values=>values.map(el=>{const css=getComputedStyle(el),image=el.querySelector('img'),caption=el.querySelector('figcaption');return {width:el.getBoundingClientRect().width,image:[image.getBoundingClientRect().width,image.getBoundingClientRect().height],float:css.cssFloat,clear:css.clear,border:css.borderTopWidth,captionSize:getComputedStyle(caption).fontSize,captionLine:getComputedStyle(caption).lineHeight,captionAfterImage:caption.getBoundingClientRect().top>=image.getBoundingClientRect().bottom};}));
  assert.equal(richGeometry[0].width,162);assert.deepEqual(richGeometry[0].image,[80,40]);assert.equal(richGeometry[0].float,'right');assert.equal(richGeometry[0].clear,'both');assert.equal(richGeometry[0].border,'1px');assert.equal(richGeometry[0].captionLine,'18px');assert.deepEqual(richGeometry[1].image,[200,100]);
  assert.ok(richGeometry.every(value=>value.captionAfterImage));
  assert.deepEqual(await page.locator('main a').filter({hasText:'Explained'}).evaluate(el=>[el.title,el.querySelector('abbr').title]),['authored advice','authored advice']);
  const mapImage=page.locator('main .compiled-image-map img');await mapImage.click({position:{x:20,y:20}});assert.deepEqual(await page.evaluate(()=>richFollowed.at(-1)),['Region','piece']);
  await mapImage.click({position:{x:150,y:10}});assert.deepEqual(await page.evaluate(()=>richFollowed.at(-1)),['Polygon']);
  await mapImage.click({position:{x:110,y:90}});assert.deepEqual(await page.evaluate(()=>richFollowed.at(-1)),['Fallback','']);
  const unavailableMap=await mapImage.evaluate(el=>{
    const before=richFollowed.length,rect=el.getBoundingClientRect(),states=[];
    for(const width of [4294967296,1.5,0]){el.dispatchEvent(new CustomEvent('wikidict-image-geometry',{detail:{original:{width,height:100},layout:{width:200,height:100}}}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:rect.left+20,clientY:rect.top+20}));states.push(el.closest('.compiled-image-map').dataset.mapState);}
    el.dispatchEvent(new CustomEvent('wikidict-image-geometry',{detail:{original:{width:200,height:100},layout:{width:200,height:100}}}));return {added:richFollowed.length-before,states};
  });assert.deepEqual(unavailableMap,{added:0,states:Array(3).fill('geometry-unavailable')});
  await page.getByRole('link',{name:'Default action',exact:true}).focus();await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>richFollowed.at(-1)),['Fallback','']);
  assert.equal(await page.getByRole('link',{name:'Circle action',exact:true}).getAttribute('href'),'https://example.test/map');
  assert.equal(await page.getByRole('link',{name:'Image description',exact:true}).getAttribute('href'),'https://en.wiktionary.org/wiki/File%3Arich-control.svg');
  const selected=await page.evaluate(()=>{const range=document.createRange();range.selectNodeContents(document.querySelector('main .compiled-bidi-scope'));getSelection().removeAllRanges();getSelection().addRange(range);return getSelection().toString();});assert.ok(selected.includes('Caption action')&&selected.includes('Cell content')&&selected.includes('After figure'));
  const mapObservations=[];
  for(const [index,width] of [900,360,900].entries()){
    await page.setViewportSize({width,height:700});
    await page.getByRole('link',{name:'Default action',exact:true}).focus();
    const menu=await page.locator('.compiled-image-map-actions').evaluate(el=>{
      const box=el.getBoundingClientRect(),owner=el.parentElement.getBoundingClientRect(),links=[...el.querySelectorAll('a')].map(a=>{const r=a.getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:r.height,line:parseFloat(getComputedStyle(a).lineHeight)};});
      const active=document.activeElement.getBoundingClientRect(),rect=e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
      return {links,height:box.height,ownerHeight:owner.height,contained:box.top>=owner.top&&box.bottom<=owner.bottom,focusedVisible:active.top>=box.top&&active.bottom<=box.bottom,scrollHeight:el.scrollHeight,clientHeight:el.clientHeight,geometry:{frame:rect(el.closest('figure')),imageBox:rect(el.closest('.compiled-figure-image')),map:rect(el.parentElement),image:rect(el.parentElement.querySelector('img'))}};
    });
    mapObservations.push(menu);
    await (await import('node:fs/promises')).writeFile(new URL('../artifacts/web/rich-map08-'+index+'-'+width+'.json',import.meta.url),JSON.stringify(menu,null,2)+'\n');
    await page.locator('main').screenshot({path:new URL('../artifacts/web/rich-flow-map08-'+index+'-'+width+'.png',import.meta.url).pathname});
    const text=await page.locator('main').textContent();for(const part of ['Caption action','Table caption','Cell content','After figure','Suffix'])assert.equal(text.split(part).length-1,1);
    await page.keyboard.press('Tab');assert.equal(await page.getByRole('link',{name:'Image description',exact:true}).evaluate(el=>el===document.activeElement),true);
    assert.equal(await page.locator('.compiled-image-map-actions').evaluate(el=>getComputedStyle(el).clipPath),'inset(50%)');
  }
  for(const menu of mapObservations){
    assert.equal(menu.links.length,4);
    // CSS computed line-height can differ from the layout rectangle by a subpixel.
    assert.ok(menu.links.every(a=>a.line>0&&Math.abs(a.height-a.line)<=1/64),'each controlled map label retains a full line box');
    assert.ok(menu.scrollHeight>menu.clientHeight,'bounded menu scrolls instead of compressing action lines');
    assert.ok(menu.links.every((a,i)=>i===0||a.top>=menu.links[i-1].bottom),'map keyboard labels must not overlap');
    assert.ok(menu.contained&&menu.focusedVisible);assert.ok(menu.height<=menu.ownerHeight);
    assert.deepEqual(menu.geometry.map,menu.geometry.image,'image-map hit plane must share the actual image box');
    assert.equal(menu.geometry.imageBox.y,menu.geometry.image.y,'external floats must not shift image inside its frame');
    assert.equal(menu.geometry.imageBox.height,menu.geometry.image.height,'image box must not retain float-induced blank lines');
  }
  assert.equal(await page.evaluate(()=>JSON.stringify(richEntry)===richBefore),true);
  const exactPolicies=await page.evaluate(()=>{
    const original={width:200,height:100};return [Media.figureImageSize({width_px:400,height_px:10},'intrinsic',original),Media.figureImageSize({width_px:999,height_px:25},'original_width_with_height_bound',original),Media.figureImageSize({width_px:400},'requested_fit',original),Media.figureImageSize({width_px:400},'requested_fit_cap_original_width',original),Media.figureImageSize({width_px:1},'requested_fit',{width:2001,height:1000})];
  });assert.deepEqual(exactPolicies,[{width:200,height:100},{width:50,height:25},{width:400,height:200},{width:200,height:100},{width:1,height:0}]);
  const richRefusals=await page.evaluate(()=>{
    const changes=[e=>e.sections[0].blocks[0].flow[1].scope.resolved_direction='auto',e=>e.sections[0].blocks[0].flow[1].scope.mode='isolate_override',e=>e.sections[0].blocks[1].figure.caption=[{kind:'text',text:'competing caption'}],e=>e.sections[0].blocks[1].figure.unknown_style=true,e=>e.sections[0].blocks[1].figure.image_span.image.map.regions[0].coordinates=[0,1],e=>e.sections[0].blocks[1].figure.image_span.image.map.regions[0].action.target_fragment=7,e=>e.media.push(e.media[0]),e=>e.sections[0].blocks[0].spans=[{kind:'text',text:'competing flow'}]];
    return changes.map(change=>{const entry=structuredClone(richEntry);change(entry);try{Renderer.renderEntry(entry,()=>{});return false;}catch{return true;}});
  });assert.ok(richRefusals.every(Boolean));
  const boundaries=await page.evaluate(()=>{
    const entry={title:'Boundary spaces',sections:[{title:'Body',blocks:[{kind:'paragraph',spans:[],flow:[{kind:'inline',spans:[{kind:'text',text:'A'},{kind:'text',text:' '}]},{kind:'scope',scope:{mode:'isolate',authored_direction:'ltr',resolved_direction:'ltr',language:null,parts:[{kind:'inline',spans:[{kind:'text',text:'B'}]}]}},{kind:'inline',spans:[{kind:'text',text:' '},{kind:'text',text:'C'},{kind:'line_break',text:''},{kind:'line_break',text:''}]}]}]}]};
    const host=document.createElement('div');host.append(Renderer.renderEntry(entry,()=>{}));document.body.append(host);const body=host.querySelector('.block>.body'),result={text:body.textContent,breaks:body.querySelectorAll('br').length};host.remove();return result;
  });assert.deepEqual(boundaries,{text:'A B C',breaks:2});
  const inlineDomain=await page.evaluate(()=>{
    const span={kind:'text',text:'ordinary'},table={caption:[],style:{display:'inline_table',vertical_align:'baseline',line_height:{value:1.5}},rows:[{cells:[{spans:[span]}]}]},entry={title:'K domain',sections:[{title:'Body',blocks:[{kind:'table',spans:[],table}]}],media:[]};
    const checks=[e=>{},e=>e.sections[0].blocks[0].kind='paragraph',e=>e.sections[0].blocks[0].spans=[span],e=>e.sections[0].blocks[0].table.caption_blocks=[],e=>e.sections[0].blocks[0].table.rows[0].cells[0].blocks=[],e=>e.sections[0].blocks[0].table.rows[0].cells[0].spans=[{...span,classes:'Egyp',text:String.fromCodePoint(0x13000)}],e=>e.sections[0].blocks[0].table.rows[0].cells[0].spans=[{...span,classes:'wikidict-media',target:'File:absent.ogg'}],e=>e.references=[{spans:[],blocks:e.sections[0].blocks}]];
    return checks.map(change=>{const value=structuredClone(entry);change(value);try{Renderer.renderEntry(value,()=>{});return true;}catch{return false;}});
  });assert.deepEqual(inlineDomain,[true,false,false,false,false,false,false,false]);
  await page.evaluate(()=>document.querySelector('main').replaceChildren());
  if(process.env.WIKIDICT_WEB_RICH_READER){
    const fs=await import('node:fs/promises'),crypto=await import('node:crypto');
    const bytes=await fs.readFile(process.env.WIKIDICT_WEB_RICH_READER);
    assert.match(process.env.WIKIDICT_WEB_RICH_READER_SHA256||'',/^[0-9a-f]{64}$/);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),process.env.WIKIDICT_WEB_RICH_READER_SHA256);
    const response=JSON.parse(bytes),entry=response.entries[0];
    assert.equal(entry.title,'Србија');assert.equal(entry.language,'Српски');
    await page.evaluate(entry=>{
      window.genuineBefore=JSON.stringify(entry);window.genuineEntry=entry;window.genuineFetches=0;
      window.fetch=async()=>{genuineFetches++;throw Error('No network in genuine data rendering control');};
      document.querySelector('main').replaceChildren(Renderer.renderEntry(entry,()=>{}, {},()=>null,(el,image,occurrence)=>Media.loadInlineImage(el,image,{allowImages:false,mediaCacheMb:0},'srwiktionary',occurrence)));
    },entry);
    await page.waitForFunction(()=>[...document.querySelectorAll('main img')].every(el=>el.dataset.mediaState==='disabled'));
    assert.equal(await page.locator('main figure').count(),2);assert.equal(await page.locator('main table').count(),2);
    assert.deepEqual(await page.locator('main figcaption').allTextContents(),['Застава Србије','Положај Србије у Европи (црвено)']);
    for(const [index,width] of [900,640,900].entries()){await page.setViewportSize({width,height:700});await page.locator('main').screenshot({path:new URL('../artifacts/web/genuine-sr-rich-'+index+'-'+width+'.png',import.meta.url).pathname});assert.equal(await page.locator('main figure').count(),2);}
    assert.equal(await page.evaluate(()=>genuineFetches),0);assert.equal(await page.evaluate(()=>JSON.stringify(genuineEntry)===genuineBefore),true);
    // This optional data control earns offline composition only, never image pixels.
  }
 }
 if(process.env.WIKIDICT_WEB_CAPTION_ONLY!=='1'){
 // Current K image policy: exercise the paired decoder and actual DOM pixels.
 const {decode}=await import('./blob.js');
 const cat=(...parts)=>Buffer.concat(parts.map(x=>Array.isArray(x)?Buffer.from(x):x));
 const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
 const f=n=>{const b=Buffer.alloc(4);b.writeFloatLE(n);return b;};
 const d=n=>{const b=Buffer.alloc(8);b.writeDoubleLE(n);return b;};
 const s=x=>cat(u(Buffer.byteLength(x)),Buffer.from(x)),list=v=>cat(u(v.length),...v);
 const length=n=>cat([0],f(n)),edges=()=>cat(...Array.from({length:4},()=>length(0)));
 const map=cat([0],u(1),[0],list([0,0,120,40].map(d)),[0],s('Theme target'),[1],s(''),s('Theme map action'),[0]);
 const span=(version,{text='',target='',image=null}={})=>cat([image||target?1:0,0,0],s(image?'':text),s(image?'File:Map.svg':target),s(''),s(''),s(''),s(''),s(''),[0,0,0],image?cat([1],s('Map.svg'),[image.flags],u(120),image.map||[],image.after||[]):[0],[0],version>='H'?[0]:[]);
 const block=(version,values=[],figure=null)=>cat([0,0,0],list(values),[0],s(''),s(''),[0],s(''),s(''),[0],version>='I'?[0]:[],version>='J'?(figure||[0]):[],version>='J'?[0]:[]);
 const color=value=>cat([2],s(value));
 const figure=cat([1,0,0,0],edges(),edges(),edges(),f(1),length(20),color('#ccddee'),[0],color('#123456'),[0],color('#123456'),color('#abcdef'),span('K',{image:{flags:65,after:[0]}}),u(0),[1],list([block('K',[span('K',{text:'Unaffected caption',target:'Caption target'})])]),[0,2,0]);
 const wire=(version,body)=>cat(Buffer.from('DPR'+version),u(0),u(1),[2],s('S'),s('S'),s(''),list(body),u(0),u(0),u(0),u(0),u(1),s('Map.svg'),[0],s(''));
 const payload=wire('K',[block('K',[span('K',{image:{flags:97,map,after:[0]}}),span('K',{text:' '}),span('K',{image:{flags:1}})]),block('K',[],figure)]);
 const themeEntry=decode(payload,{title:'Image theme',kind:'language',language:'English'});
 assert.equal(themeEntry.sections[0].blocks[0].spans[0].image.dark_mode_filter,'invert_hue_rotate_180');
 assert.equal(Object.hasOwn(themeEntry.sections[0].blocks[0].spans[2].image,'dark_mode_filter'),false);
 for(const [version,flags,after] of [['J',65,[0]],['K',65,[1]],['K',193,[0]]])assert.throws(()=>decode(wire(version,[block(version,[span(version,{image:{flags,after}})])]),{}));
 await page.setViewportSize({width:900,height:700});
 await page.addStyleTag({content:await (await import('node:fs/promises')).readFile(new URL('./style.css',import.meta.url),'utf8')});
 await page.evaluate(entry=>{
  document.body.replaceChildren(document.createElement('main'));window.themeEntry=entry;window.themeBefore=JSON.stringify(entry);window.themeActions=[];window.themeCalls={metadata:0,blob:0};window.themeRevoked=[];
  const revoke=URL.revokeObjectURL.bind(URL);URL.revokeObjectURL=url=>{themeRevoked.push(url);revoke(url);};window.caches={open:async()=>({match:async()=>null})};
  const svg='<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><style>@media(prefers-color-scheme:dark){.scheme{fill:red}}</style><path fill="white" d="M0 0h20v40H0z"/><path fill="black" d="M20 0h20v40H20z"/><path fill="red" d="M40 0h20v40H40z"/><path class="scheme" fill="black" d="M60 0h20v40H60z"/><path fill="red" fill-opacity=".5" d="M80 0h20v40H80z"/></svg>';
  window.fetch=async url=>{if(url.includes('/w/api.php')){themeCalls.metadata++;return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/theme-control.svg',width:120,height:40,mime:'image/svg+xml'}]}]}}));}themeCalls.blob++;return new Response(svg,{headers:{'Content-Type':'image/svg+xml'}});};
  document.querySelector('main').append(Renderer.renderEntry(entry,(...v)=>themeActions.push(v),{},()=>null,(el,image,occurrence)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'enwiktionary',occurrence),target=>Media.inlineImageActionURL(target,'enwiktionary')));
  for(const img of document.querySelectorAll('main img')){img.parentElement.style.background='#123456';img.parentElement.style.display='inline-block';}
 },themeEntry);
 await page.waitForFunction(()=>document.querySelectorAll('main img').length===3&&[...document.querySelectorAll('main img')].every(el=>el.dataset.mediaState==='loaded'));
 const images=page.locator('main img');assert.deepEqual(await page.evaluate(()=>themeCalls),{metadata:1,blob:1});
 const urls=await images.evaluateAll(v=>v.map(el=>el.src));assert.equal(new Set(urls).size,1);
 const geometry=()=>images.evaluateAll(v=>v.map(el=>{const r=el.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};}));
 const screenshotPixels=async(locator,name)=>{
  const bytes=await locator.screenshot({path:new URL('../artifacts/web/theme09-'+name+'.png',import.meta.url).pathname});
  return page.evaluate(async data=>{
   const image=new Image();image.src='data:image/png;base64,'+data;await image.decode();const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const context=canvas.getContext('2d');context.drawImage(image,0,0);
   return [10,30,50,70,90,110].map(x=>Array.from(context.getImageData(x,20,1,1).data));
  },bytes.toString('base64'));
 };
 const closePixels=(actual,expected)=>{assert.equal(actual.length,expected.length);for(let i=0;i<actual.length;i++){assert.equal(actual[i][3],255);for(let c=0;c<3;c++)assert.ok(Math.abs(actual[i][c]-expected[i][c])<=2,JSON.stringify({i,c,actual:actual[i],expected:expected[i]}));}};
 const light=[[255,255,255],[0,0,0],[255,0,0],[0,0,0],[137,26,43],[18,52,86]],dark=[[0,0,0],[255,255,255],[255,146,146],[255,255,255],[137,99,116],[18,52,86]];
 const observations=[];let baseline;
 for(const [index,effective,os] of [[0,'light','dark'],[1,'dark','light'],[2,'light','dark']]){
  await page.emulateMedia({colorScheme:os});await page.evaluate(value=>document.documentElement.dataset.theme=value,effective);
  const current=await geometry();if(baseline)assert.deepEqual(current,baseline);else baseline=current;
  const styles=await images.evaluateAll(v=>v.map(el=>({filter:getComputedStyle(el).filter,scheme:getComputedStyle(el).colorScheme})));
  assert.deepEqual(styles.map(v=>v.filter),effective==='dark'?['invert(1) hue-rotate(180deg)','none','invert(1) hue-rotate(180deg)']:['none','none','none']);
  assert.equal(styles[0].scheme,'light');assert.equal(styles[2].scheme,'light');assert.equal(styles[1].scheme,effective);
  const filtered=await screenshotPixels(images.nth(0),index+'-'+effective+'-filtered'),plain=await screenshotPixels(images.nth(1),index+'-'+effective+'-plain'),framed=await screenshotPixels(images.nth(2),index+'-'+effective+'-figure');
  await (await import('node:fs/promises')).writeFile(new URL('../artifacts/web/theme09-observed-'+index+'.json',import.meta.url),JSON.stringify({index,effective,os,styles,geometry:current,filtered,plain,framed},null,2)+'\n');
  closePixels(filtered,effective==='dark'?dark:light);closePixels(framed,effective==='dark'?dark:light);
  const unfiltered=structuredClone(light);if(effective==='dark')unfiltered[3]=[255,0,0];closePixels(plain,unfiltered);
  const caption=await page.locator('figcaption').evaluate(el=>({filter:getComputedStyle(el).filter,color:getComputedStyle(el).color,background:getComputedStyle(el).backgroundColor,text:el.textContent}));assert.deepEqual(caption,{filter:'none',color:'rgb(18, 52, 86)',background:'rgb(171, 205, 239)',text:'Unaffected caption'});
  observations.push({index,effective,os,styles,geometry:current,filtered,plain,framed,caption});
  await page.locator('main').screenshot({path:new URL('../artifacts/web/theme09-'+index+'-'+effective+'-900.png',import.meta.url).pathname});
  if(effective==='dark'){
   await page.locator('.compiled-image-map img').click({position:{x:10,y:20}});assert.deepEqual(await page.evaluate(()=>themeActions.at(-1)),['Theme target','']);
   await page.getByRole('link',{name:'Unaffected caption',exact:true}).focus();await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>themeActions.at(-1)),['Caption target']);
   await page.setViewportSize({width:360,height:700});assert.deepEqual((await geometry()).map(v=>[v.width,v.height]),[[120,40],[120,40],[120,40]]);
   await page.locator('main').screenshot({path:new URL('../artifacts/web/theme09-dark-360.png',import.meta.url).pathname});await page.setViewportSize({width:900,height:700});
  }
 }
 const badThemes=await page.evaluate(()=>[null,0,{},'invert','invert_hue_rotate_180 '].map(policy=>{
  const entry=structuredClone(themeEntry);entry.sections[0].blocks[0].spans[0].image.dark_mode_filter=policy;let entryRefused=false,spanRefused=false;
  try{Renderer.renderEntry(entry,()=>{});}catch{entryRefused=true;}try{Renderer.spans([entry.sections[0].blocks[0].spans[0]],()=>{});}catch{spanRefused=true;}return entryRefused&&spanRefused;
 }));assert.ok(badThemes.every(Boolean));
 assert.equal(await page.evaluate(()=>JSON.stringify(themeEntry)===themeBefore),true);assert.deepEqual(await page.evaluate(()=>themeCalls),{metadata:1,blob:1});assert.deepEqual(await images.evaluateAll(v=>v.map(el=>el.src)),urls);
 await (await import('node:fs/promises')).writeFile(new URL('../artifacts/web/theme09-observations.json',import.meta.url),JSON.stringify({observations,badThemes,requests:{metadata:1,blob:1},sourceUnchanged:true},null,2)+'\n');
 await page.evaluate(()=>document.querySelector('main').replaceChildren());await page.waitForFunction(url=>themeRevoked.includes(url),urls[0]);assert.equal(await page.evaluate(url=>themeRevoked.filter(value=>value===url).length,urls[0]),1);

 }
 // Caption defaults must respect compiled ink and the actual painted surface.
 await page.setViewportSize({width:900,height:700});
 await page.addStyleTag({content:await (await import('node:fs/promises')).readFile(new URL('./style.css',import.meta.url),'utf8')});
 await page.evaluate(()=>{
  const rgb=value=>({kind:'rgb',value}),native={kind:'native_theme'},clear={kind:'transparent'},length=value=>({unit:'px',value}),edges=()=>Object.fromEntries(['top','right','bottom','left'].map(k=>[k,length(0)]));
  const link=(text,foreground)=>({kind:'link',text,target:text+' target',...(foreground?{foreground}:{})}),paragraph=spans=>({kind:'paragraph',spans});
  const figure=(foreground,background,caption,blocks=null,frame=native)=>({image_span:{kind:'text',text:'',image:{file:'Caption.svg',width_px:240,height_px:16,alt:'Caption surface control'}},caption,format:'thumbnail',sizing:'requested_fit',placement:'none',clear:'none',margins:edges(),image_insets:edges(),caption_padding:edges(),caption_font_scale:1,caption_line_height:length(24),frame_background:frame,frame_border:{kind:'none'},image_background:native,image_border:{kind:'none'},caption_foreground:foreground,caption_background:background,...(blocks==null?{}:{caption_blocks:blocks})});
  const figures=[
   figure(rgb('#123456'),rgb('#abcdef'),[],[paragraph([link('Inherited caption'),{kind:'text',text:' / '},link('Explicit authored','#dd0000')])]),
   figure(native,rgb('#abcdef'),[link('Native on light')]),
   figure(native,rgb('#17251e'),[],[{kind:'paragraph',spans:[],flow:[{kind:'scope',spans:[],scope:{mode:'isolate',authored_direction:'ltr',resolved_direction:'ltr',parts:[{kind:'inline',spans:[link('Native on dark')]}]}}]}]),
   figure(native,clear,[link('Transparent on frame')],null,rgb('#17251e')),
   figure(native,native,[link('Native surface')]),
   figure(clear,rgb('#abcdef'),[link('Authored transparent')])
  ];
  window.captionEntry={presentation_version:'DPRK',title:'Caption surfaces',language:'English',sections:[{level:2,title:'Caption controls',blocks:figures.map(figure=>({kind:'paragraph',spans:[],figure}))}],references:[],media:[{kind:'image',file:'Caption.svg',caption:''}]};
  window.captionBefore=JSON.stringify(captionEntry);window.captionActions=[];window.captionCalls=0;
  window.caches={open:async()=>({match:async()=>null})};
  window.fetch=async url=>{captionCalls++;if(url.includes('/w/api.php'))return new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/caption-control.svg',width:240,height:16,mime:'image/svg+xml'}]}]}}));return new Response('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="16"><path fill="#808080" d="M0 0h240v16H0z"/></svg>',{headers:{'Content-Type':'image/svg+xml'}});};
  document.body.replaceChildren(document.createElement('main'));document.querySelector('main').append(Renderer.renderEntry(captionEntry,(...v)=>captionActions.push(v),{},()=>null,(el,image,occurrence)=>Media.loadInlineImage(el,image,{allowImages:true,mediaCacheMb:0},'enwiktionary',occurrence)));
 });
 await page.waitForFunction(()=>document.querySelectorAll('main img').length===6&&[...document.querySelectorAll('main img')].every(el=>el.dataset.mediaState==='loaded'));
 const captionObservations=[];let captionGeometry;
 const ratio=(a,b)=>{const lum=value=>{const v=value.match(/[\d.]+/g).slice(0,3).map(Number).map(x=>{x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;});return v[0]*.2126+v[1]*.7152+v[2]*.0722;};const x=lum(a),y=lum(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
 for(const [index,theme,width] of [[0,'light',900],[1,'dark',900],[2,'dark',360],[3,'light',900]]){
  await page.setViewportSize({width,height:700});await page.evaluate(value=>document.documentElement.dataset.theme=value,theme);
  const rows=await page.locator('figcaption').evaluateAll(values=>values.map(el=>{const css=getComputedStyle(el),frame=getComputedStyle(el.parentElement),r=el.getBoundingClientRect();return {foreground:css.color,background:css.backgroundColor,frameBackground:frame.backgroundColor,filter:css.filter,rect:{x:r.x,y:r.y,width:r.width,height:r.height},links:[...el.querySelectorAll('a')].map(a=>({text:a.textContent,color:getComputedStyle(a.querySelector('span')).color,anchorColor:getComputedStyle(a).color,decoration:getComputedStyle(a.querySelector('span')).textDecorationLine,href:a.getAttribute('href')}))};}));
  captionObservations.push({index,theme,width,rows});
  await (await import('node:fs/promises')).writeFile(new URL('../artifacts/web/caption10-observed-'+index+'.json',import.meta.url),JSON.stringify(captionObservations.at(-1),null,2)+'\n');
  assert.equal(rows[0].foreground,'rgb(18, 52, 86)');assert.equal(rows[0].background,'rgb(171, 205, 239)');assert.equal(rows[0].links[0].color,'rgb(18, 52, 86)');
  assert.equal(rows[0].links[1].color,'rgb(221, 0, 0)'); // authored link remains exact even if low contrast
  assert.equal(rows[1].links[0].color,'rgb(0, 0, 0)');assert.equal(rows[2].links[0].color,'rgb(255, 255, 255)');assert.equal(rows[3].links[0].color,'rgb(255, 255, 255)');
  assert.equal(rows[4].links[0].color,theme==='dark'?'rgb(233, 184, 138)':'rgb(133, 81, 40)');assert.equal(rows[5].links[0].color,'rgba(0, 0, 0, 0)');
  for(const n of [0,1,2,3]){const row=rows[n],surface=n===3?row.frameBackground:row.background;assert.ok(ratio(row.links[0].color,surface)>=4.5);assert.equal(row.links[0].decoration,'underline');}
  assert.ok(rows.every(row=>row.filter==='none'));assert.deepEqual(await page.locator('main img').evaluateAll(v=>v.map(el=>[el.getBoundingClientRect().width,el.getBoundingClientRect().height])),Array.from({length:6},()=>[240,16]));
  if(width===900){const g=rows.map(row=>row.rect);if(captionGeometry)assert.deepEqual(g,captionGeometry);else captionGeometry=g;}
  await page.getByRole('link',{name:'Inherited caption',exact:true}).focus();await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>captionActions.at(-1)),['Inherited caption target']);
  await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement.textContent),'Explicit authored');await page.keyboard.press('Enter');assert.deepEqual(await page.evaluate(()=>captionActions.at(-1)),['Explicit authored target']);
  await page.locator('main').screenshot({path:new URL('../artifacts/web/caption10-'+index+'-'+theme+'-'+width+'.png',import.meta.url).pathname});
 }
 assert.equal(await page.evaluate(()=>JSON.stringify(captionEntry)===captionBefore),true);assert.equal(await page.evaluate(()=>captionCalls),2);
 await (await import('node:fs/promises')).writeFile(new URL('../artifacts/web/caption10-observations.json',import.meta.url),JSON.stringify({captionObservations,sourceUnchanged:true,metadataAndBlobRequests:2,explicitLowContrastColorPreserved:true},null,2)+'\n');
}finally{await browser.close();}
