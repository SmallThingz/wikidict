// Genuine compiled input is required; constructed controls earn no corpus credit.
import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {build} from 'esbuild';
import {chromium} from 'playwright';
import {buildIndex,decode} from './blob.js';

const casesPath=process.env.WIKIDICT_WEB_TYPED_CASES;
const report=process.env.WIKIDICT_CONTAINER_FONTS_REPORT;
assert.ok(casesPath&&report&&path.isAbsolute(report),'Select genuine cases and a fresh absolute report directory');
const cases=JSON.parse(await readFile(casesPath,'utf8'));
assert.equal(cases.length,1,'This focused check owns one affected entry');
const selected=cases[0],bytes=new Uint8Array(await readFile(selected.blob));
const source={size:bytes.length,read:async(offset,length)=>bytes.slice(offset,offset+length)};
const index=await buildIndex(source),row=index.rows.find(row=>row.title===selected.title);
assert.ok(row);
const entry=decode(await source.read(row.offset,row.length),{...index.metadata,title:row.title});
assert.equal(entry.presentation_version,'DPRM');
await mkdir(report);
const bundle=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const results=[];
try{
 const page=await browser.newPage();
 await page.route('**/*',route=>route.abort());
 for(const width of [1000,640]){
  await page.setViewportSize({width,height:800});
  await page.setContent('<style>'+css+'</style><style>:root{--wikidict-normal-body-size:20px}</style><main></main>');
  await page.addScriptTag({content:bundle.outputFiles[0].text});
  await page.evaluate(entry=>{
   window.actions=[];
   document.querySelector('main').append(Renderer.renderEntry(entry,target=>window.actions.push(target),{fold:false}));
   for(const details of document.querySelectorAll('details'))details.open=true;
  },entry);
  await page.evaluate(()=>document.fonts.ready);
  const metrics=await page.evaluate(()=>{
   const table=document.querySelector('table'),cells=[...table.rows[0].cells];
   const owner=cells[0].querySelector('.compiled-container');
   const text=[...cells[0].querySelectorAll('span')].find(span=>span.textContent==='Gun (Bénin)');
   const word=document.createRange(),first=document.createTreeWalker(text,NodeFilter.SHOW_TEXT).nextNode();
   word.setStart(first,0);word.setEnd(first,3);
   const name=document.createRange();name.setStart(first,5);name.setEnd(first,10);
   const box=element=>{const r=element.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom};};
   return {cells:cells.map(box),table:box(table),ownerFont:getComputedStyle(owner).fontSize,cellFont:getComputedStyle(cells[0]).fontSize,cellLineHeight:getComputedStyle(cells[0]).lineHeight,padding:getComputedStyle(owner).paddingTop,body:document.querySelector('main').textContent,overflow:document.documentElement.scrollWidth>innerWidth,text:text?.textContent,firstWordRects:word.getClientRects().length,nameWordRects:name.getClientRects().length};
  });
  assert.equal(metrics.cells.length,5);
  assert.equal(metrics.ownerFont,'18px');assert.equal(metrics.cellFont,'18px');
  assert.ok(Math.abs(parseFloat(metrics.cellLineHeight)-17.1)<.001);
  assert.ok(Math.abs(parseFloat(metrics.padding)-9)<.001);
  assert.equal(metrics.overflow,false);
  for(let i=1;i<metrics.cells.length;i++)assert.ok(metrics.cells[i].left>=metrics.cells[i-1].right-.1,'Banner cells overlap');
  assert.equal(metrics.text,'Gun (Bénin)');
  assert.equal(metrics.firstWordRects,1,'A normal table word must not stack individual letters');
  assert.equal(metrics.nameWordRects,1,'The authored name must remain a word');
  assert.ok(metrics.body.includes('Okpli ɖé wɛ hwenue gbɛtɔ́gun ɖé kplidókpɔ́ nádó ɖɔxo dó onú tangan ɖé ji.'));
  const link=page.locator('a').filter({hasText:'Gun (Gungbe)'});
  await link.focus();assert.equal(await link.evaluate(el=>el===document.activeElement),true);
  await page.keyboard.press('Enter');
  assert.deepEqual(await page.evaluate(()=>window.actions),['opli']);
  await page.screenshot({path:path.join(report,`okpli-${width}.png`),fullPage:true});
  results.push({width,...metrics,keyboardTarget:'opli'});
 }
 await writeFile(path.join(report,'result.json'),JSON.stringify({title:entry.title,version:entry.presentation_version,results},null,2)+'\n');
}finally{await browser.close();}
