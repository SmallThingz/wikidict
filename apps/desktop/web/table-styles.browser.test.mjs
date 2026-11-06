// Proposed control using the existing Playwright/esbuild test stack; unrun.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
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
 const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
 for(const width of [320,640,900])for(const direction of ['ltr','rtl'])for(const side of ['left','right']){
  await page.setViewportSize({width,height:900});
  await page.setContent('<style>'+css+'</style><main dir="'+direction+'"></main>');
  await page.addScriptTag({content:bundle.outputFiles[0].text});
  const geometry=await page.evaluate(({side})=>{
   const text=text=>({kind:'text',text});
   const paragraph=(label,text_align)=>({kind:'paragraph',spans:[text(label)],...(text_align?{text_align}:{})});
   const margins=Object.fromEntries(['top','right','bottom','left'].map(k=>[k,{unit:'px',value:k===(side==='right'?'left':'right')?20:0}]));
   const table={kind:'table',spans:[],table:{caption:[],geometry:{width:{unit:'px',value:160},border:2,cell_padding:4,cell_spacing:0},style:{float_side:side,margins},rows:[{cells:[{header:false,colspan:2,rowspan:1,background:'#b4cdcd',style:{text_align:'right'},spans:[],blocks:[paragraph('1'),paragraph('2','center'),paragraph('3')]}]},{cells:[{spans:[text('Tall table')],colspan:1,rowspan:1}]}]}};
   const entry={title:'Layout',presentation_version:'DPRE',sections:[{title:'First',level:2,blocks:[table,paragraph('Ondo')]},{title:'Next',level:2,blocks:[{kind:'paragraph',spans:[{kind:'link',text:'Hurrengoa',target:'bat#Atala'}]}]}],references:[]};
   const actions=[];window.layoutActions=actions;document.querySelector('main').append(Renderer.renderEntry(entry,t=>actions.push(t),{}));
   const t=document.querySelector('table');t.rows[1].cells[0].style.height='300px';
   const box=e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width};};
   const ink=e=>{const r=document.createRange();r.selectNodeContents(e);return box({getBoundingClientRect:()=>r.getBoundingClientRect()});};
   const values=[...t.rows[0].cells[0].querySelectorAll('.body')].map(ink);
   const cell=box(t.rows[0].cells[0]),wrap=box(t.parentElement);
   const following=ink(t.parentElement.nextElementSibling.querySelector('.body'));
   const next=ink(document.querySelector('a'));
   const selection=getSelection(),range=document.createRange();range.selectNodeContents(t.rows[0].cells[0]);selection.removeAllRanges();selection.addRange(range);
   const selected=selection.toString();
   let invalid=0;for(const value of ['justify',0,{},'start'])try{Renderer.renderEntry({title:'Bad',sections:[{title:'S',blocks:[{...paragraph('bad'),text_align:value}]}]},()=>{});}catch{invalid++;}
   return {values,cell,wrap,following,next,selected,invalid,footer:box(document.querySelector('.compiled-table-flow>footer')),flow:box(document.querySelector('.compiled-table-flow')),side:getComputedStyle(t.parentElement).cssFloat,margin:getComputedStyle(t.parentElement)[side==='right'?'marginLeft':'marginRight'],tableMargin:getComputedStyle(t).marginLeft,href:document.querySelector('a').getAttribute('href')};
  },{side});
  assert.equal(geometry.side,side);assert.equal(geometry.margin,'20px');assert.equal(geometry.tableMargin,'0px');
  assert.ok(Math.abs(geometry.values[0].right-geometry.values[2].right)<1,'outer paragraphs inherit physical right');
  assert.ok(Math.abs((geometry.values[1].left+geometry.values[1].right)/2-(geometry.cell.left+geometry.cell.right)/2)<3,'only middle paragraph centers across full cell');
  assert.ok(geometry.values[0].right>(geometry.values[1].left+geometry.values[1].right)/2,'outer paragraphs remain right of center');
  for(const [name,r] of [['following',geometry.following],['next section',geometry.next]]){
   assert.ok(r.top<geometry.wrap.bottom,name+' remains beside live float');
   assert.ok(side==='right'?r.right<=geometry.wrap.left-19:r.left>=geometry.wrap.right+19,name+' respects physical margin box');
  }
  assert.ok(geometry.footer.top>=geometry.wrap.bottom-.5,'attribution starts below the article float');
  assert.ok(Math.abs(geometry.footer.width-geometry.flow.width)<1,'attribution uses full article width');
  assert.match(geometry.selected,/1[\s\S]*2[\s\S]*3/);assert.equal(geometry.invalid,4);
  await page.getByRole('link',{name:'Hurrengoa',exact:true}).focus();await page.keyboard.press('Enter');
  assert.deepEqual(await page.evaluate(()=>window.layoutActions),['bat#Atala']);
  const indents=await page.evaluate(()=>{
   const results=[];
   for(const authored of [null,{top:{unit:'px',value:0},right:{unit:'px',value:7},bottom:{unit:'px',value:0},left:{unit:'px',value:20}}]){
    const host=document.createElement('div');document.querySelector('main').append(host);
    host.append(Renderer.renderEntry({title:'Indent',sections:[{title:'S',blocks:[{kind:'table',depth:2,spans:[],table:{caption:[],rows:[],style:{float_side:'right',...(authored?{margins:authored}:{})}}}]}]},()=>{}));
    const css=getComputedStyle(host.querySelector('.compiled-table-float'));
    results.push({left:parseFloat(css.marginLeft),right:parseFloat(css.marginRight),rem:parseFloat(getComputedStyle(document.documentElement).fontSize)});
   }
   return results;
  });
  for(const [i,g] of indents.entries()){
   const indent=.9*g.rem;
   assert.ok(Math.abs(g.left-((i?20:0)+(direction==='ltr'?indent:0)))<.02,'semantic indent adds to physical left in LTR');
   assert.ok(Math.abs(g.right-((i?7:0)+(direction==='rtl'?indent:0)))<.02,'semantic indent adds to physical right in RTL');
  }

 }
}finally{await browser.close();}
