// Proposed control using the existing Playwright/esbuild test stack; unrun.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
const bundle=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage();await page.setContent('<main style="font-size:20px"></main>');await page.addScriptTag({content:bundle.outputFiles[0].text});
 const result=await page.evaluate(()=>{
  const edges=(unit,value)=>Object.fromEntries(['top','right','bottom','left'].map(k=>[k,{unit,value}]));
  const border={solid:{width:{unit:'px',value:1},color:'#aaaaaa'}};
  const text=text=>({kind:'text',text});
  const child={kind:'table',spans:[],table:{caption:[text('Nested')],rows:[{cells:[{spans:[text('Inherited surface')],colspan:1,rowspan:1}]}]}};
  const table={kind:'table',spans:[],table:{style:{background:'#f9f9f9',border,collapse:'collapse',margins:edges('px',10)},caption:[],rows:[{cells:[{header:true,background:'#f2f2f2',style:{border,padding:edges('em',.2),text_align:'center'},spans:[text('Četiri')],colspan:1,rowspan:1},{style:{border:{none:{}},padding:edges('px',0),text_align:'left'},spans:[],blocks:[child],colspan:1,rowspan:1}]}]}};
  document.querySelector('main').append(Renderer.renderEntry({title:'Styles',sections:[],references:[{number:1,group_number:1,spans:[],blocks:[table]}]},()=>{},{}));
  const t=document.querySelector('table'),th=t.querySelector('th'),td=t.querySelector('td'),nested=td.querySelector('table');
  const css=e=>{const c=getComputedStyle(e);return {background:c.backgroundColor,padding:c.paddingTop,align:c.textAlign,border:c.borderTopStyle,color:c.color};};
  let invalid=0;for(const style of [{padding:edges('em',-1)},{text_align:'justify'},{border:{solid:{width:{unit:'pt',value:1},color:'#aaa'}}},{}]){try{Renderer.renderEntry({title:'Bad',sections:[{title:'S',blocks:[{kind:'table',table:{rows:[{cells:[{style,spans:[]}]}]}}]}]},()=>{});}catch{invalid++;}}
  return {table:{collapse:t.style.borderCollapse,margin:t.style.marginTop,border:t.style.borderTopColor,background:t.style.backgroundColor},header:css(th),headerUnit:th.style.paddingTop,cell:css(td),nestedColor:getComputedStyle(nested.querySelector('td span')).color,invalid};
 });
 assert.equal(result.table.collapse,'collapse');assert.equal(result.table.margin,'10px');assert.equal(result.table.border,'rgb(170, 170, 170)');
 assert.equal(result.header.background,'rgb(242, 242, 242)');assert.equal(result.headerUnit,'0.2em');assert.equal(result.header.align,'center');
 assert.equal(result.cell.padding,'0px');assert.equal(result.cell.border,'none');assert.equal(result.cell.align,'left');assert.equal(result.nestedColor,'rgb(0, 0, 0)');assert.equal(result.invalid,4);
}finally{await browser.close();}
