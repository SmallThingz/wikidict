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
 const rgbResult=await page.evaluate(()=>{
  document.querySelector('main').replaceChildren();window.links=[];
  const colors=['#000000','#808080','#ffffff','#c0c0c0','#ffd700','#ff0000','#800080','#0000ff','#008000','#ffff00','#ffa500'];
  const rows=colors.map((background,i)=>({cells:[{background:'#eeeeee',spans:[{kind:'link',text:'Label '+i,target:'Label '+i,foreground:'#01796f',bold:true,trail:'!'}]},{background,spans:[{kind:'text',text:'\u00a0'}]}]}));
  rows.push({cells:[{background:'#01796f',rowspan:2,colspan:1,spans:[{text:'own fill'}]},{background:null,spans:[{text:'no fill'}]}]},{cells:[{background:'red',spans:[{text:'invalid fill',foreground:'red'}]}]});
  const entry={title:'Typed RGB',sections:[{title:'Colors',blocks:[{kind:'paragraph',spans:[{kind:'text',text:'   '},{kind:'text',text:'ASCII sentinel'}]},{kind:'paragraph',spans:[{text:'invalid foreground',foreground:'#01796f\n'}]},{kind:'table',table:{caption:[{text:'Caption',foreground:'#1c39bb'}],rows}}]}]};const before=JSON.stringify(entry);
  document.querySelector('main').append(Renderer.renderEntry(entry,t=>window.links.push(t)));
  return {unchanged:before===JSON.stringify(entry),backgrounds:[...document.querySelectorAll('tr')].slice(0,11).map(tr=>[...tr.cells].map(td=>td.style.backgroundColor)),blank:[...document.querySelectorAll('tr')].slice(0,11).map(tr=>tr.cells[1].textContent),linkColor:getComputedStyle(document.querySelector('td a span')).color,trailColor:getComputedStyle(document.querySelector('td > span')).color,bold:!!document.querySelector('td a strong'),caption:getComputedStyle(document.querySelector('caption span')).color,rowspan:document.querySelectorAll('tr')[11].cells[0].rowSpan,nullFill:document.querySelectorAll('tr')[11].cells[1].style.backgroundColor,invalidFill:document.querySelectorAll('tr')[12].cells[0].style.backgroundColor,asciiBlank:document.querySelector('.block.paragraph .body').textContent,invalidForeground:document.querySelectorAll('.block.paragraph .body')[1].firstChild.style.color};
 });
 assert.equal(rgbResult.unchanged,true);assert.equal(rgbResult.backgrounds.length,11);assert.deepEqual(rgbResult.backgrounds,['rgb(0, 0, 0)','rgb(128, 128, 128)','rgb(255, 255, 255)','rgb(192, 192, 192)','rgb(255, 215, 0)','rgb(255, 0, 0)','rgb(128, 0, 128)','rgb(0, 0, 255)','rgb(0, 128, 0)','rgb(255, 255, 0)','rgb(255, 165, 0)'].map(color=>['rgb(238, 238, 238)',color]));assert.ok(rgbResult.blank.every(text=>text==='\u00a0'));
 assert.equal(rgbResult.linkColor,'rgb(1, 121, 111)');assert.equal(rgbResult.trailColor,'rgb(1, 121, 111)');assert.equal(rgbResult.caption,'rgb(28, 57, 187)');assert.equal(rgbResult.bold,true);assert.equal(rgbResult.rowspan,2);assert.equal(rgbResult.nullFill,'');assert.equal(rgbResult.invalidFill,'');assert.equal(rgbResult.asciiBlank,'ASCII sentinel');assert.equal(rgbResult.invalidForeground,'');
 await page.getByRole('link',{name:'Label 0',exact:true}).click();assert.deepEqual(await page.evaluate(()=>window.links),['Label 0']);
 await page.setViewportSize({width:768,height:640});
 await page.screenshot({path:path.join(report,'typed-rgb-768.png'),fullPage:true});frames.push('typed-rgb-768.png');
 const paintResult=await page.evaluate(()=>{
  document.querySelector('main').replaceChildren();
  const painted={kind:'link',text:'Nested paint',trail:'!',target:'Paint target',foreground:'#01796f',background:'#ffffe0',code:true};
  const entry={title:'Paint title',presentation_version:'DPR6',display_title:[{text:'Paint title',background:'#ffffe0'}],preamble_spans:[{text:'Preamble',background:'#ffffe0'}],sections:[{title:'Noun',level:3,blocks:[{kind:'heading',level:3,spans:[{kind:'text',text:'Noun',background:'#ffffe0'}]},{kind:'paragraph',spans:[{kind:'text',text:'   ',background:'#00ff00'},{text:'after paint'},{kind:'line_break',trail:'break trail',background:'#ff0000'}]},{kind:'table',table:{caption:[{text:'Caption',background:'#ffffe0'}],rows:[{cells:[{background:'#fffdd0',spans:[painted,{text:' plain neighbor'},{text:'Invalid',background:'#FFFFE0'}]}]}]}}]}],references:[]};
  const before=JSON.stringify(entry);document.querySelector('main').append(Renderer.renderEntry(entry,()=>{}));
  const td=document.querySelector('td'),link=td.querySelector('a span'),trail=td.querySelector(':scope > span');
  return {unchanged:JSON.stringify(entry)===before,title:document.querySelector('h1 span').style.backgroundColor,heading:document.querySelector('summary .heading-label span').style.backgroundColor,nouns:[...document.querySelectorAll('summary')].filter(x=>x.textContent.includes('Noun')).length,outer:td.style.backgroundColor,inner:link.style.backgroundColor,trail:trail.style.backgroundColor,code:!!td.querySelector('code'),neighbor:td.children[2].style.backgroundColor,invalid:td.lastElementChild.style.backgroundColor,blank:document.querySelector('.paragraph .body').firstChild.textContent,blankFill:document.querySelector('.paragraph .body').firstChild.style.backgroundColor,caption:document.querySelector('caption span').style.backgroundColor,breakTrail:document.querySelector('.paragraph .body').lastChild.textContent,breakFill:document.querySelector('.paragraph .body').lastChild.style.backgroundColor,breakCount:[...document.querySelector('.paragraph .body').childNodes].filter(x=>x.nodeName==='BR').length};
 });
 assert.deepEqual(paintResult,{unchanged:true,title:'rgb(255, 255, 224)',heading:'rgb(255, 255, 224)',nouns:1,outer:'rgb(255, 253, 208)',inner:'rgb(255, 255, 224)',trail:'rgb(255, 255, 224)',code:true,neighbor:'',invalid:'',blank:'   ',blankFill:'rgb(0, 255, 0)',caption:'rgb(255, 255, 224)',breakTrail:'break trail',breakFill:'rgb(255, 0, 0)',breakCount:1});
 await page.setViewportSize({width:768,height:640});
 await page.locator('main').scrollIntoViewIfNeeded();
 await page.screenshot({path:path.join(report,'span-background-768.png'),fullPage:true,animations:'disabled'});frames.push('span-background-768.png');
 const contrastResults=[];
 for(const theme of ['light','dark']){
  contrastResults.push(await page.evaluate(theme=>{
   document.documentElement.dataset.theme=theme;document.querySelector('main').replaceChildren();
   const spans=[{kind:'link',text:'Pale link',target:'Target',background:'#ffffe0'},{text:'Dark paint',background:'#000000'},{text:'Authored ink',background:'#ffffe0',foreground:'#123456'},{kind:'link',text:'Cell link',target:'Cell target'},{text:'Cell plain'},{text:'Span override',background:'#000000'}];
   const entry={title:'Contrast',sections:[{title:'Paint',blocks:[{kind:'table',table:{rows:[{cells:[{background:'#fffdd0',spans}]}]}},{kind:'paragraph',spans:[{text:'Theme neighbor'}]}]}]};
   document.querySelector('main').append(Renderer.renderEntry(entry,()=>{}));
   const text=value=>[...document.querySelectorAll('td span')].find(el=>el.textContent===value);
   const color=value=>getComputedStyle(text(value)).color;
   return {theme,pale:color('Pale link'),dark:color('Dark paint'),authored:color('Authored ink'),cellLink:color('Cell link'),cellPlain:color('Cell plain'),override:color('Span override'),underlined:getComputedStyle(text('Pale link')).textDecorationLine.includes('underline')&&getComputedStyle(text('Cell link')).textDecorationLine.includes('underline'),themeUnchanged:document.querySelector('.paragraph .body span').style.color===''};
  },theme));
 }
 for(const measured of contrastResults)assert.deepEqual(measured,{theme:measured.theme,pale:'rgb(0, 0, 0)',dark:'rgb(255, 255, 255)',authored:'rgb(18, 52, 86)',cellLink:'rgb(0, 0, 0)',cellPlain:'rgb(0, 0, 0)',override:'rgb(255, 255, 255)',underlined:true,themeUnchanged:true});
 await page.screenshot({path:path.join(report,'span-background-contrast-dark-768.png'),fullPage:true,animations:'disabled'});frames.push('span-background-contrast-dark-768.png');
 const nestedResults=[];
 for(const theme of ['light','dark'])for(const width of [360,768]){
 await page.setViewportSize({width,height:640});
 const nestedResult=await page.evaluate(theme=>{document.documentElement.dataset.theme=theme;
  const child=()=>({caption:[{kind:'link',text:'Child caption',target:'#Forms'}],geometry:{border:1,cell_padding:2,width:{unit:'percent',value:100}},rows:[{cells:[{header:true,colspan:5,background:'#800080',spans:[]}]},{cells:Array.from({length:4},(_,i)=>({spans:[{kind:'link',text:'form '+i,target:'#Forms'}]}))}]});
  const entry={title:'Nested grid',presentation_version:'DPR7',sections:[{title:'Forms',anchor:'Forms',blocks:[{kind:'table',table:{geometry:{border:0,cell_spacing:15},rows:[{cells:Array.from({length:4},()=>({background:'#000000',spans:[],nested_table:child()}))}]}}]}]};
  const links=[];document.querySelector('main').replaceChildren(Renderer.renderEntry(entry,target=>links.push(target)));
  document.querySelector('table table a').click();
  const outer=document.querySelector('.table-scroll > table'),cells=[...outer.rows[0].cells],children=cells.map(td=>td.querySelector(':scope > table'));
  const wrap=outer.parentElement;
  const words=[...outer.querySelectorAll('td a span')].filter(el=>el.textContent.startsWith('form ')).map(el=>{
   const range=document.createRange();range.setStart(el.firstChild,0);range.setEnd(el.firstChild,4);
   const rects=[...range.getClientRects()].filter(r=>r.width>0&&r.height>0);
   return {word:range.toString(),oneLine:rects.length>0&&rects.every(r=>Math.abs(r.top-rects[0].top)<.5)};
  });
  wrap.scrollLeft=wrap.scrollWidth;
  const last=children.at(-1).rows[1].cells[3].getBoundingClientRect(),box=wrap.getBoundingClientRect();
  const scroll={overflow:wrap.scrollWidth>wrap.clientWidth,moved:wrap.scrollLeft>0,
   finalColumnVisible:last.left>=box.left+wrap.clientLeft-1&&last.right<=box.left+wrap.clientLeft+wrap.clientWidth+1};
  wrap.scrollLeft=0;
  return {words,scroll,links,outerCells:cells.length,totalTables:document.querySelectorAll('table').length,scrollRegions:document.querySelectorAll('.table-scroll').length,spacing:outer.style.borderSpacing,children:children.map(table=>({rows:table.rows.length,span:table.rows[0].cells[0].colSpan,empty:table.rows[0].cells[0].textContent,paint:getComputedStyle(table.rows[0].cells[0]).backgroundColor,padding:getComputedStyle(table.rows[0].cells[0]).padding,width:table.style.width,childPaint:table.rows[1].cells[0].style.backgroundColor,ink:getComputedStyle(table.rows[1].cells[0].querySelector('span')).color,captionInk:getComputedStyle(table.querySelector('caption span')).color,area:table.rows[0].cells[0].getBoundingClientRect().width*table.rows[0].cells[0].getBoundingClientRect().height>0}))};
 },theme);nestedResults.push({theme,width,...nestedResult});
 assert.deepEqual(nestedResult.links,['#Forms']); assert.equal(nestedResult.outerCells,4);assert.equal(nestedResult.totalTables,5);assert.equal(nestedResult.scrollRegions,1);assert.equal(nestedResult.spacing,'15px');
 for(const child of nestedResult.children)assert.deepEqual(child,{rows:2,span:5,empty:'',paint:'rgb(128, 0, 128)',padding:'2px',width:'100%',childPaint:'rgb(0, 0, 0)',ink:'rgb(255, 255, 255)',captionInk:'rgb(255, 255, 255)',area:true});
 assert.equal(nestedResult.words.length,16);
 assert.ok(nestedResult.words.every(word=>word.word==='form'&&word.oneLine));
 assert.equal(nestedResult.scroll.finalColumnVisible,true);
 if(nestedResult.scroll.overflow)assert.equal(nestedResult.scroll.moved,true);
 const name=`nested-grid-${theme}-${width}.png`;
 await page.screenshot({path:path.join(report,name),fullPage:true,animations:'disabled'});frames.push(name);
 }
 const orderedResults=[];
 for(const theme of ['light','dark'])for(const width of [360,768]){
  await page.setViewportSize({width,height:640});
  const ordered=await page.evaluate(theme=>{
   document.documentElement.dataset.theme=theme;
   const text=text=>[{kind:'text',text}];
   const heading={kind:'heading',level:2,anchor:'reference-1',anchor_fallback:'Cell.20heading',spans:text('Cell heading')};
   const child={kind:'table',table:{geometry:{width:{unit:'percent',value:100}},rows:[{cells:[{spans:text('child text')},{spans:text('child second')}]}]}};
   const blocks=[{kind:'paragraph',spans:[{kind:'link',text:'before',target:'#reference-1',explanation:'cell explanation'}]},heading,{kind:'list_item',spans:text('item')},{kind:'rule'},child,{kind:'paragraph',spans:text('following text')},{kind:'heading',level:6,anchor:'empty-cell-heading',spans:[]}];
   const entry={title:'Ordered cells',presentation_version:'DPR8',sections:[{title:'Owning fold',anchor:'Owner',blocks:[{kind:'table',table:{rows:[{cells:[{header:true,background:'#000000',spans:[],blocks},{spans:[],blocks:[]}]}]}}]},{title:'Unrelated',anchor:'Other',blocks:[{kind:'paragraph',spans:text('other')}]}],references:[{number:1,group_number:1,spans:text('citation')}]};
   const before=JSON.stringify(entry),links=[];
   const main=document.querySelector('main');main.replaceChildren(Renderer.renderEntry(entry,t=>links.push(t),{collapseOtherSections:true}));
   const owner=document.getElementById('Owner'),other=document.getElementById('Other');
   const revealed=Renderer.revealFragment(main,'Cell.20heading');
   const headingNode=document.getElementById('reference-1'),td=headingNode.closest('th'),nested=td.querySelector('table');
   td.querySelector('a').click();
   const wrap=document.querySelector('.table-scroll');wrap.scrollLeft=wrap.scrollWidth;
   const box=wrap.getBoundingClientRect(),last=nested.rows[0].cells[1].getBoundingClientRect();
   return {unchanged:before===JSON.stringify(entry),order:[...td.children].map(el=>el.tagName==='TABLE'?'table':el.tagName==='HR'?'rule':el.textContent),heading:headingNode.tagName,empty:document.getElementById('empty-cell-heading').tagName,paint:getComputedStyle(td).backgroundColor,ink:getComputedStyle(headingNode.querySelector('.body span')).color,header:getComputedStyle(headingNode).fontWeight===getComputedStyle(td).fontWeight,childInk:getComputedStyle(nested.querySelector('span')).color,scrolls:main.querySelectorAll('.table-scroll').length,childWidth:nested.style.width,childFits:nested.getBoundingClientRect().width<=td.getBoundingClientRect().width+1,finalVisible:last.right<=box.right+1,links,revealed,owningOpen:owner.open,otherClosed:!other.open,focused:document.activeElement.id,uniqueIDs:new Set([...main.querySelectorAll('[id]')].map(el=>el.id)).size===main.querySelectorAll('[id]').length,explanation:!!main.querySelector('abbr[aria-describedby]'),foldCount:main.querySelectorAll('details').length};
  },theme);
  assert.deepEqual(ordered.order,['before','Cell heading','•item','rule','table','following text','']);
  assert.equal(ordered.unchanged,true);assert.equal(ordered.heading,'H2');assert.equal(ordered.empty,'H6');assert.equal(ordered.paint,'rgb(0, 0, 0)');assert.equal(ordered.ink,'rgb(255, 255, 255)');assert.equal(ordered.childInk,'rgb(255, 255, 255)');assert.equal(ordered.header,true);assert.equal(ordered.scrolls,1);assert.equal(ordered.childWidth,'100%');assert.equal(ordered.childFits,true);assert.equal(ordered.finalVisible,true);assert.deepEqual(ordered.links,['#reference-1']);assert.equal(ordered.revealed,true);assert.equal(ordered.owningOpen,true);assert.equal(ordered.otherClosed,true);assert.equal(ordered.focused,'Cell.20heading');assert.equal(ordered.uniqueIDs,true);assert.equal(ordered.explanation,true);assert.equal(ordered.foldCount,4);
  orderedResults.push({theme,width,...ordered});
  const name=`ordered-cells-${theme}-${width}.png`;
  await page.screenshot({path:path.join(report,name),fullPage:true,animations:'disabled'});frames.push(name);
 }
 assert.deepEqual(errors,[]);
 await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,scope:'Focused compiled feature render, strict fallback, label accessibility, no focus stop, responsive bounds; synthetic typed input, not corpus import or public transport.',result,paintResult,contrastResults,nestedResults,orderedResults,accessibleSnapshot:snapshot,frames,errors},null,2)+'\n');
 console.log('WEB_COLOR_SWATCH_PASS');
} finally {await browser.close();}
