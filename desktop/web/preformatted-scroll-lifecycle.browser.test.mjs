// Only previously unqualified resize/lifecycle transitions; retained endpoint passes stay separate.
// Run from the checkout root with a fresh absolute WIKIDICT_PRE_SCROLL_REPORT directory.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
const web=path.resolve('desktop/web'),require=createRequire(path.join(web,'package.json'));
const {chromium}=require('playwright'),{build}=require('esbuild');
const report=process.env.WIKIDICT_PRE_SCROLL_REPORT;
const only=process.env.WIKIDICT_PRE_SCROLL_ONLY;
const names=['ltr-actual-resize-at-end','rtl-actual-resize-at-end','centered-resize-negative','end-aligned-resize-negative','rtl-end-aligned-resize-negative','authored-start-padding-resize-negative','authored-end-padding-resize-negative','pending-update-detach-and-authored-padding'];
assert(!only||names.includes(only),'Unknown test selection');
assert(report&&path.isAbsolute(report));await mkdir(report,{recursive:false});
const renderer=await readFile(path.join(web,'renderer.js')),css=await readFile(path.join(web,'style.css'),'utf8');
const sha=b=>createHash('sha256').update(b).digest('hex');
const bundle=await build({entryPoints:[path.join(web,'renderer.js')],bundle:true,format:'iife',globalName:'Renderer',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
const errors=[],results=[],requests=[];let failure=null,closeError=null;
const settle=p=>p.evaluate(async()=>{await document.fonts.ready;for(let i=0;i<8;i++)await new Promise(r=>requestAnimationFrame(r));});
async function pageFor(spec){
 const page=await browser.newPage({viewport:{width:1300,height:760},deviceScaleFactor:1});
 page.on('pageerror',e=>errors.push({case:spec.name,message:e.message}));
 await page.route('**/*',r=>{requests.push(r.request().url());return r.abort();});
 await page.setContent('<style>'+css+'</style><main></main>');
 await page.evaluate(()=>{
  window.watch={resize:0,mutation:0,styleWrites:0};
  const RO=ResizeObserver,MO=MutationObserver;
  window.ResizeObserver=class extends RO{constructor(callback){super((...args)=>{watch.resize++;callback(...args);});}};
  window.MutationObserver=class extends MO{constructor(callback){super((...args)=>{watch.mutation++;callback(...args);});}};
  window.RawMutationObserver=MO;
 });
 await page.addScriptTag({content:bundle.outputFiles[0].text});
 await page.evaluate(spec=>{
  const text=spec.rtl?'אבגדה'.repeat(15)+'ת':'0123456789'.repeat(6)+'/';
  const entry={title:'PRE lifecycle control',language:'Test',sections:[{title:'Control',blocks:[{kind:'preformatted',spans:[{kind:'text',text}],...(spec.align?{text_align:spec.align}:{})}]}]};
  const before=JSON.stringify(entry),article=Renderer.renderEntry(entry,()=>{}, {collapseOtherSections:false,collapseDetails:false});
  const pre=article.querySelector('pre'),host=pre.parentElement;
  if(host.localName!=='wikidict-preformatted-scroll')throw Error('Public renderEntry did not create PRE host');
  pre.dir=spec.rtl?'rtl':'ltr';pre.style.cssText+=';margin:0;width:400px;max-width:none;font:16px/24px monospace;';
  if(spec.paddingStart)pre.style.paddingInlineStart=spec.paddingStart;
  if(spec.paddingEnd)pre.style.paddingInlineEnd=spec.paddingEnd;
  const baseline=pre.cloneNode(true);baseline.dataset.baseline='true';
  document.querySelector('main').append(article,baseline);
  new RawMutationObserver(list=>{watch.styleWrites+=list.filter(x=>x.attributeName==='style').length;}).observe(pre,{attributes:true});
  window.test={entry,before,text,pre,host,baseline,mount:host.parentElement};
 },spec);await settle(page);return page;
}
async function snapshot(page){return page.evaluate(()=>{
 const {pre,baseline,entry,before}=test,style=getComputedStyle(pre),box=pre.getBoundingClientRect();
 const rects=el=>{const range=document.createRange();range.selectNodeContents(el);const b=el.getBoundingClientRect();return [...range.getClientRects()].map(r=>[r.left-b.left+el.scrollLeft,r.right-b.left+el.scrollLeft,r.top-b.top,r.bottom-b.top]);};
 const bstyle=getComputedStyle(baseline);
 return {width:box.width,clientWidth:pre.clientWidth,scrollWidth:pre.scrollWidth,scrollLeft:pre.scrollLeft,
  padding:style.paddingInlineEnd,inlinePadding:pre.style.paddingInlineEnd,align:style.textAlign,direction:style.direction,
  baselinePadding:bstyle.paddingInlineEnd,rects:rects(pre),baselineRects:rects(baseline),
  text:pre.textContent,sourceUnchanged:before===JSON.stringify(entry),watch:{...watch}};
});}
async function width(page,value){await page.evaluate(value=>{test.pre.style.width=value+'px';test.baseline.style.width=value+'px';},value);await settle(page);}
async function endpoint(page,rtl,end){
 const target=await page.evaluate(({rtl,end})=>{
  const {pre}=test,b=pre.getBoundingClientRect();
  pre.scrollIntoView({block:'center',inline:'nearest'});
  const box=pre.getBoundingClientRect(),max=pre.scrollWidth-pre.clientWidth;
  return {x:(box.left+box.right)/2,y:(box.top+box.bottom)/2,max,delta:(rtl?-1:1)*(end?1:-1)*(max+64)};
 },{rtl,end});
 assert(target.max>0);await page.mouse.move(target.x,target.y);await page.mouse.wheel(target.delta,0);
 const result=await page.evaluate(async({rtl,end})=>{
  const {pre}=test,max=pre.scrollWidth-pre.clientWidth,wanted=end?(rtl?-max:max):0;
  for(let i=0;i<90;i++){await new Promise(r=>requestAnimationFrame(r));if(pre.scrollLeft===wanted)break;}
  const nodes=[],walk=document.createTreeWalker(pre,NodeFilter.SHOW_TEXT);let node;
  while((node=walk.nextNode()))if(node.data)nodes.push(node);
  node=end?nodes.at(-1):nodes[0];const pieces=[...new Intl.Segmenter('und',{granularity:'grapheme'}).segment(node.data)];
  const part=end?pieces.at(-1):pieces[0],range=document.createRange();range.setStart(node,part.index);range.setEnd(node,part.index+part.segment.length);
  const rect=range.getBoundingClientRect(),box=pre.getBoundingClientRect(),left=box.left+pre.clientLeft,right=left+pre.clientWidth;
  const hit=document.elementFromPoint((rect.left+rect.right)/2,(rect.top+rect.bottom)/2);
  return {end,scrollLeft:pre.scrollLeft,wanted,max,rect:{left:rect.left,right:rect.right},clip:{left,right},fullRange:rect.left>=left&&rect.right<=right,hitOwner:!!hit&&pre.contains(hit),glyph:part.segment,padding:getComputedStyle(pre).paddingInlineEnd};
 },{rtl,end});
 assert.equal(result.scrollLeft,result.wanted);assert(result.fullRange,'Endpoint crosses PRE clip: '+JSON.stringify(result));assert(result.hitOwner);return result;
}
try{
 for(const rtl of [false,true]){
  const spec={name:(rtl?'rtl':'ltr')+'-actual-resize-at-end',rtl};if(only&&only!==spec.name)continue;
  const page=await pageFor(spec);
  try{
   // The initial endpoint was already qualified. Measure only after actual width changes.
   await page.evaluate(rtl=>{test.pre.scrollLeft=rtl?-100000:100000;},rtl);
   await width(page,313);
   const narrow=await snapshot(page);assert.equal(narrow.width,313);assert(narrow.scrollWidth>narrow.clientWidth);
   assert(narrow.sourceUnchanged);assert.deepEqual(narrow.rects,narrow.baselineRects);
   const narrowEnd=await endpoint(page,rtl,true),narrowStart=await endpoint(page,rtl,false);
   const fitWidth=await page.evaluate(()=>{const range=document.createRange();range.selectNodeContents(test.pre);return Math.ceil(range.getBoundingClientRect().width)+32;});
   await width(page,fitWidth);const fit=await snapshot(page);
   assert.equal(fit.width,fitWidth);assert.equal(fit.scrollWidth,fit.clientWidth);assert.equal(fit.scrollLeft,0);assert.equal(fit.inlinePadding,'');assert.deepEqual(fit.rects,fit.baselineRects);
   await width(page,337);const again=await snapshot(page);assert.equal(again.width,337);assert(again.scrollWidth>again.clientWidth);assert.deepEqual(again.rects,again.baselineRects);
   const againEnd=await endpoint(page,rtl,true),againStart=await endpoint(page,rtl,false);
   const stableBefore=await snapshot(page);await settle(page);const stableAfter=await snapshot(page);
   assert.deepEqual(stableAfter.watch,stableBefore.watch,'Observer or style-write loop after resize');
   await page.locator('pre').first().screenshot({path:path.join(report,spec.name+'.png')});
   results.push({name:spec.name,passed:true,narrow,narrowEnd,narrowStart,fit,again,againEnd,againStart,stableBefore:stableBefore.watch,stableAfter:stableAfter.watch});
  }finally{await page.close();}
 }
 for(const spec of [
  {name:'centered-resize-negative',align:'center'},
  {name:'end-aligned-resize-negative',align:'right'},
  {name:'rtl-end-aligned-resize-negative',rtl:true,align:'left'},
  {name:'authored-start-padding-resize-negative',paddingStart:'7px'},
  {name:'authored-end-padding-resize-negative',paddingEnd:'9px'},
 ]){if(only&&only!==spec.name)continue;const page=await pageFor(spec);try{
  const stages=[];for(const w of [303,720,349]){await width(page,w);const s=await snapshot(page);assert.equal(s.width,w);assert.deepEqual(s.rects,s.baselineRects);assert.equal(s.padding,s.baselinePadding);assert.equal(s.inlinePadding,spec.paddingEnd||'');assert(s.sourceUnchanged);stages.push(s);}
  const a=await snapshot(page);await settle(page);const b=await snapshot(page);assert.deepEqual(a.watch,b.watch);results.push({name:spec.name,passed:true,stages});
 }finally{await page.close();}}
 if(!only||only==='pending-update-detach-and-authored-padding'){
  const spec={name:'pending-update-detach-and-authored-padding'},page=await pageFor(spec);try{
   await width(page,311);await page.evaluate(async()=>{
    const before=watch.mutation;
    test.pre.firstChild.firstChild ? test.pre.firstChild.firstChild.appendData('x') : test.pre.firstChild.appendData('x');
    // Deliver the mutation callback and its queued RAF, then detach before the frame.
    await Promise.resolve();if(watch.mutation<=before)throw Error('Pending-update setup did not deliver mutation');
    test.host.remove();if(test.pre.style.paddingInlineEnd!=='')throw Error('Disconnected owned gutter retained');
   });await settle(page);const detached=await snapshot(page);await settle(page);const detachedAfter=await snapshot(page);
   assert.deepEqual(detached.watch,detachedAfter.watch,'Detached observer activity');assert.equal(detached.inlinePadding,'');
   await page.evaluate(()=>{test.mount.append(test.host);if(!test.host.isConnected)throw Error('Reconnect setup is detached');});await settle(page);const reconnected=await snapshot(page);
   assert(reconnected.scrollWidth>reconnected.clientWidth);assert(Number.parseFloat(reconnected.padding)>=0&&Number.parseFloat(reconnected.padding)<1);
   // A later authored value must survive teardown even when an owned value existed earlier.
   await page.evaluate(()=>{test.pre.style.paddingInlineEnd='11px';test.host.remove();});await settle(page);const authored=await snapshot(page);assert.equal(authored.inlinePadding,'11px');
   await page.evaluate(()=>{test.mount.append(test.host);if(!test.host.isConnected)throw Error('Reconnect setup is detached');});await settle(page);const restored=await snapshot(page);assert.equal(restored.inlinePadding,'11px');
   results.push({name:spec.name,passed:true,detached,detachedAfter,reconnected,authored,restored});
  }finally{await page.close();}
 }
 assert.deepEqual(errors,[]);
}catch(e){failure={message:String(e),stack:e.stack};}
finally{try{await browser.close();}catch(e){closeError=String(e);}}
const sourceStable=sha(await readFile(path.join(web,'renderer.js')))===sha(renderer);
const passed=results.length===(only?1:8)&&!failure&&!errors.length&&!closeError&&sourceStable;
await writeFile(path.join(report,'result.json'),JSON.stringify({passed,selected:only||'all-eight-new-transitions',scope:'NEW synthetic resize/lifecycle transitions only; existing original and static negative passes retained separately',rendererSHA:sha(renderer),bundleSHA:sha(bundle.outputFiles[0].text),browser:'Chromium',results,errors,failure,closeError,sourceStable,requests,wholeQualified:false},null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({passed,cases:results.map(x=>x.name),errors,failure,closeError,sourceStable}));
if(!passed)process.exitCode=1;
