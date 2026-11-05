// Proposed normal-package Playwright controls; no live network, no new runner.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
const renderer=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const media=await build({entryPoints:[new URL('./media.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Media',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage();await page.route('**/*',r=>r.abort());await page.setContent('<main></main>');await page.addScriptTag({content:renderer.outputFiles[0].text});await page.addScriptTag({content:media.outputFiles[0].text});
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
}finally{await browser.close();}
