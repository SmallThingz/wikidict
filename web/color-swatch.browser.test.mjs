import {chromium} from 'playwright';
import {build} from 'esbuild';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import path from 'node:path';
const report=process.env.WIKIDICT_SWATCH_REPORT;
assert.ok(report && path.isAbsolute(report),'Use a fresh owned absolute report directory');
await mkdir(report,{recursive:false});
const bundle=await build({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],bundle:true,format:'iife',globalName:'Renderer',write:false});
const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[],frames=[];
try {
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.setContent('<button id="before">Before sample</button><main></main><button id="after">After sample</button>');
 await page.addStyleTag({content:css});await page.addScriptTag({content:bundle.outputFiles[0].text});
 const result=await page.evaluate(()=>{
  const table=feature=>({kind:'table',depth:2,spans:[],feature,table:{caption:[],rows:[{cells:[{header:false,colspan:1,rowspan:1,spans:[{kind:'link',text:'#ffff00',target:'fallback target'}]}]}]}});
  const valid={kind:'color_swatch',data:'#ffff00',language:'',tail_kind:'none',tail:''};
  const cases=[valid,{kind:'color_swatch',data:'#00ff00'},...[
   {data:'#FFFF00'},{data:'#ffff00\n'},{data:'#fff'},{data:'yellow'},{data:'#ffff00',kind:'unknown'},
   {language:'en'},{tail_kind:'text'},{tail:'retained semantic tail'},{language:null},{tail_kind:null},{tail:null}].map(extra=>({...valid,...extra}))];
  const blocks=cases.map(table),entry={title:'Compiled color sample',language:'English',sections:[{title:'Samples',blocks}]};
  const before=JSON.stringify(entry);window.links=[];
  document.querySelector('main').append(Renderer.renderEntry(entry,t=>window.links.push(t),{collapseOtherSections:false}));
  const samples=[...document.querySelectorAll('.color-swatch')];
  return {unchanged:before===JSON.stringify(entry),samples:samples.length,labels:samples.map(x=>x.textContent),colors:samples.map(x=>getComputedStyle(x.firstChild).backgroundColor),margins:samples.map(x=>x.style.marginInlineStart),decorative:samples.every(x=>x.firstChild.getAttribute('aria-hidden')==='true'),noFocus:samples.every(x=>x.tabIndex===-1&&!x.querySelector('a,button,input,[tabindex]')),fallbackTables:document.querySelectorAll('table').length,fallbackLinks:document.querySelectorAll('.table-scroll a').length};
 });
 assert.deepEqual(result,{unchanged:true,samples:2,labels:['Color sample #ffff00','Color sample #00ff00'],colors:['rgb(255, 255, 0)','rgb(0, 255, 0)'],margins:['0.9rem','0.9rem'],decorative:true,noFocus:true,fallbackTables:11,fallbackLinks:11});
 await page.getByRole('link',{name:'#ffff00',exact:true}).first().click();
 assert.deepEqual(await page.evaluate(()=>window.links),['fallback target']);
 const snapshot=await page.locator('.color-swatch').first().ariaSnapshot();
 assert.equal(snapshot.split('Color sample #ffff00').length-1,1);
 await page.locator('main details > summary').focus();await page.keyboard.press('Tab');
 assert.equal(await page.evaluate(()=>document.activeElement.matches('.table-scroll')),true);
 for(const width of [360,768]){
  await page.setViewportSize({width,height:640});
  const bounds=await page.locator('.color-swatch').first().evaluate(el=>{const r=el.getBoundingClientRect(),chip=el.firstChild.getBoundingClientRect();return {left:r.left,right:r.right,width:chip.width,height:chip.height};});
  assert.ok(bounds.left>=0&&bounds.right<=width);assert.equal(bounds.width,40);assert.equal(bounds.height,40);
  const name=`color-swatch-${width}.png`;await page.screenshot({path:path.join(report,name),fullPage:true});frames.push(name);
 }
 assert.deepEqual(errors,[]);
 await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,scope:'Focused compiled feature render, strict fallback, label accessibility, no focus stop, responsive bounds; synthetic typed input, not corpus import or public transport.',result,accessibleSnapshot:snapshot,frames,errors},null,2)+'\n');
 console.log('WEB_COLOR_SWATCH_PASS');
} finally {await browser.close();}
