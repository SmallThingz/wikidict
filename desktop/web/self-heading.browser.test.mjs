import {chromium} from 'playwright';
import {build} from 'esbuild';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import path from 'node:path';
const report=process.env.WIKIDICT_SELF_HEADING_REPORT;
assert.ok(report&&path.isAbsolute(report),'Use a fresh owned absolute report directory');
await mkdir(report,{recursive:false});
const bundle=await build({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],bundle:true,format:'iife',globalName:'Renderer',write:false});
const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[],requests=[],frames=[];
try {
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',route=>{requests.push(route.request().url());return route.abort();});
 await page.setContent('<main></main>');await page.addStyleTag({content:css});await page.addScriptTag({content:bundle.outputFiles[0].text});
 const controls=await page.evaluate(()=>{
  const self={kind:'text',text:'Self heading',target:'',classes:'mw-selflink selflink',bold:true,italic:true};
  const make=(span,level=3,title='Self heading')=>({title,level,blocks:[{kind:'heading',level,spans:[span]},{kind:'paragraph',spans:[{kind:'text',text:'Visible body'}]}]});
  const sections=[make(self),make({...self,bold:false,italic:false}),make({...self,classes:'extra\tmw-selflink\nselflink note'})];
  const controls=[{classes:''},{classes:'mw-selflink'},{classes:'selflink'},{classes:'not-mw-selflink selflink'},{classes:'mw-selflink selflink-suffix'},{target:'other'},{kind:'link'},{text:'',trail:'Self heading'},{classes:'',bold:false,italic:false}];
  sections.push(...controls.map(extra=>make({...self,...extra})),make(self,2),make(self,3,'Different'));
  // Level mismatch is a section/block mismatch, not a different valid heading level.
  sections[sections.length-2].level=3;
  const entry={title:'CLIENT-ONLY self heading controls',language:'English',sections};const before=JSON.stringify(entry);
  document.querySelector('main').append(Renderer.renderEntry(entry,()=>{}, {collapseOtherSections:false}));
  const details=[...document.querySelectorAll('main > details')];
  const counts=details.map(d=>d.textContent.split('Self heading').length-1);
  const styles=details.slice(0,3).map(d=>({italic:!!d.querySelector('summary em'),bold:!!d.querySelector('summary strong'),anchors:d.querySelectorAll('summary a').length,bodyHeadings:d.querySelectorAll('.block.heading').length}));
  return {unchanged:before===JSON.stringify(entry),counts,styles};
 });
 assert.equal(controls.unchanged,true);assert.deepEqual(controls.counts,[1,1,1,1,1,1,1,1,2,2,2,2,2,1]);
 assert.deepEqual(controls.styles,[{italic:true,bold:true,anchors:0,bodyHeadings:0},{italic:false,bold:false,anchors:0,bodyHeadings:0},{italic:true,bold:true,anchors:0,bodyHeadings:0}]);
 await page.evaluate(()=>{
  const self={kind:'text',text:'Styled self',target:'',classes:'mw-selflink selflink',bold:true,italic:true};
  window.followed=[];const heading=[self,{kind:'text',text:' / '},{kind:'link',text:'Next dog',target:'dog'}];
  const entry={title:'CLIENT-ONLY compiled self heading',language:'English',sections:[{title:'Styled self / Next dog',level:3,blocks:[{kind:'heading',level:3,spans:heading},{kind:'paragraph',spans:[{kind:'text',text:'Visible body stays reachable'}]}]}]};
  document.querySelector('main').replaceChildren(Renderer.renderEntry(entry,t=>window.followed.push(t),{collapseOtherSections:false}));
 });
 const summary=page.locator('main > details > summary');
 assert.equal(await page.getByRole('link',{name:'Styled self',exact:true}).count(),0);
 const link=page.getByRole('link',{name:'Next dog',exact:true});await link.focus();await page.keyboard.press('Enter');
 assert.deepEqual(await page.evaluate(()=>window.followed),['dog']);assert.equal(await page.locator('main > details').evaluate(e=>e.open),true);
 await summary.focus();await page.keyboard.press('Enter');assert.equal(await page.locator('main > details').evaluate(e=>e.open),false);
 await page.keyboard.press('Enter');assert.equal(await page.locator('main > details').evaluate(e=>e.open),true);
 await page.keyboard.press('Tab');assert.equal(await link.evaluate(e=>document.activeElement===e),true);
 const accessibility=await summary.ariaSnapshot();assert.ok(accessibility.includes('Styled self'));assert.ok(accessibility.includes('link "Next dog"'));
 const layouts=[];
 for(const width of [360,768]) {
  await page.setViewportSize({width,height:640});await summary.focus();
  const rect=await summary.evaluate(e=>{
   const r=e.getBoundingClientRect(),label=e.querySelector(':scope > .heading-label'),strong=label.querySelector('strong').getBoundingClientRect(),link=label.querySelector('a').getBoundingClientRect();
   const walker=document.createTreeWalker(label,NodeFilter.SHOW_TEXT);let text;while((text=walker.nextNode()))if(text.textContent===' / ')break;
   const range=document.createRange();range.setStart(text,1);range.setEnd(text,2);const slash=range.getBoundingClientRect();
   return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,focused:document.activeElement===e,label:label.textContent,directChildren:e.children.length,slashGap:slash.left-strong.right,linkGap:link.left-slash.right,font:parseFloat(getComputedStyle(label).fontSize),chevronFlex:getComputedStyle(e,'::after').flexShrink};
  });
  assert.equal(rect.label,'Styled self / Next dog');assert.equal(rect.directChildren,1);assert.equal(rect.chevronFlex,'0');
  assert.ok(rect.slashGap>=0&&rect.slashGap<rect.font*.75&&rect.linkGap>=0&&rect.linkGap<rect.font*.75,'Inline label words must remain adjacent, not justify-separated flex columns');
  assert.ok(rect.left>=0&&rect.right<=width&&rect.top>=0&&rect.bottom<=640&&rect.focused);layouts.push({width,...rect});
  const filename=path.join(report,`self-heading-${width}.png`);await page.screenshot({path:filename,fullPage:false});frames.push(filename);
 }
 const wrapped=[];
 for(const width of [360,768]){
 await page.setViewportSize({width,height:640});
 const row=await page.evaluate(()=>{
  const text='يمين طويل '.repeat(12),span={kind:'text',text,target:'',classes:'mw-selflink selflink',direction:'rtl',bold:true};
  document.querySelector('main').replaceChildren(Renderer.renderEntry({title:'RTL wrapping control',language:'English',sections:[{title:text.trim(),level:3,blocks:[{kind:'heading',level:3,spans:[span]},{kind:'paragraph',spans:[{kind:'text',text:'Body'}]}]}]},()=>{},{collapseOtherSections:false}));
  const summary=document.querySelector('summary'),label=summary.querySelector('.heading-label'),r=summary.getBoundingClientRect(),lr=label.getBoundingClientRect(),bdi=label.querySelector('[dir="rtl"]');
  return {left:r.left,right:r.right,labelLeft:lr.left,labelRight:lr.right,labelHeight:lr.height,lineHeight:parseFloat(getComputedStyle(label).lineHeight),labelText:label.textContent,expected:text,rtl:!!bdi,overflow:document.documentElement.scrollWidth>innerWidth};
 });
 assert.equal(row.labelText,row.expected);assert.equal(row.rtl,true);assert.equal(row.overflow,false);assert.ok(row.labelLeft>=row.left&&row.labelRight<=row.right&&row.labelHeight>30);
 wrapped.push({width,...row});
 }
 assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
 await writeFile(path.join(report,'result.json'),JSON.stringify({schema:'wikidict.web-self-heading-focused.v1',passed:true,client_only_fixture:true,controls,accessibility,layouts,wrapped,frames,errors,requests,real_corpus_import:false},null,2)+'\n');
 console.log('WEB_SELF_HEADING_PASS');
} finally {await browser.close();}
