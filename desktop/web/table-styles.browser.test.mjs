// Controlled rendering checks using the existing Playwright/esbuild test stack.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
const containerReport=process.env.WIKIDICT_CONTAINER_REPORT;
if(containerReport){assert.ok(path.isAbsolute(containerReport));await mkdir(containerReport);}
const bundle=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
try{
 const page=await browser.newPage();await page.setContent('<style>:root{--wikidict-normal-body-size:20px}table{font-size:12px}</style><main style="font-size:20px"></main>');await page.addScriptTag({content:bundle.outputFiles[0].text});
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
  assert.equal(result.header.background,'rgb(242, 242, 242)');assert.match(result.headerUnit,/var\(--wikidict-normal-body-size\)/);assert.equal(result.header.padding,'4px');assert.equal(result.header.align,'center');
 assert.equal(result.cell.padding,'0px');assert.equal(result.cell.border,'none');assert.equal(result.cell.align,'left');assert.equal(result.nestedColor,'rgb(0, 0, 0)');assert.equal(result.invalid,4);
  const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
  await page.setContent('<style>'+css+'</style><main></main>');
  await page.addScriptTag({content:bundle.outputFiles[0].text});
  const ink=await page.evaluate(()=>{
   const green='#008000',definition=(text,style={})=>({kind:'definition',spans:[{kind:'text',text,foreground:green,...style}]});
   const blocks=[definition('Reader surface',{italic:true}),definition('Readable ink',{foreground:'#87e787'}),
    definition('Authored highlight',{background:'#ffffff'}),
    {kind:'table',table:{rows:[{cells:[{background:'#ffffff',spans:[],blocks:[definition('Table surface')]}]}]}},
    {kind:'container',spans:[],container:{style:{background:{rgb:'#ffffff'}},blocks:[definition('Container surface')]}},
    definition('Authored link',{kind:'link',target:'Destination'})];
   const input={title:'Text contrast',sections:[{title:'Definitions',blocks}]},original=JSON.stringify(input);
   const main=document.querySelector('main');main.append(Renderer.renderEntry(input));
   const inspect=theme=>{
    document.documentElement.dataset.theme=theme;
    return ['Reader surface','Readable ink','Authored highlight','Table surface','Container surface','Authored link'].map(text=>{
     const span=[...main.querySelectorAll('span')].find(el=>el.children.length===0&&el.textContent===text);
     let owner=span;while(getComputedStyle(owner).backgroundColor==='rgba(0, 0, 0, 0)')owner=owner.parentElement;
     const css=getComputedStyle(span);
     return {color:css.color,background:getComputedStyle(owner).backgroundColor,italic:css.fontStyle,href:span.closest('a')?.getAttribute('href')};
    });
   };
   const light=inspect('light'),dark=inspect('dark');
   delete document.documentElement.dataset.theme;main.replaceChildren();
   return {light,dark,sourceUnchanged:JSON.stringify(input)===original};
  });
  const luma=rgb=>rgb.match(/\d+/g).slice(0,3).map(n=>Number(n)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
  assert.equal(ink.sourceUnchanged,true);
  assert.equal(ink.light[0].color,'rgb(0, 128, 0)');assert.equal(ink.dark[0].italic,'italic');
  assert.ok((luma(ink.dark[0].color)+.05)/(luma(ink.dark[0].background)+.05)>=4.5);
  assert.deepEqual(ink.dark.slice(2,5),ink.light.slice(2,5));
  assert.ok(ink.dark.slice(2,5).every(value=>value.color==='rgb(0, 128, 0)'&&value.background==='rgb(255, 255, 255)'));
  assert.equal(ink.dark[1].color,'rgb(135, 231, 135)');
  assert.equal(ink.dark[5].color,'rgb(0, 128, 0)');assert.equal(ink.dark[5].href,'#Destination');

  const sizes=await page.evaluate(()=>{
   const edges=value=>Object.fromEntries(['top','right','bottom','left'].map(k=>[k,{unit:'em',value}]));
   const text=text=>({kind:'text',text});
   const cell={spans:[text('Nested padding')],style:{padding:edges(.5)}};
   const child={kind:'table',table:{rows:[{cells:[cell]}]}};
   const outer={kind:'table',table:{style:{margins:edges(.5)},rows:[{cells:[{spans:[],blocks:[child],style:{padding:edges(.5)}}]}]}};
   document.querySelector('main').append(Renderer.renderEntry({title:'Font basis',sections:[{title:'S',blocks:[outer]}]},()=>{}));
   return [null,'24px'].map(size=>{
    if(size)document.documentElement.style.setProperty('--wikidict-normal-body-size',size);
    const tables=[...document.querySelectorAll('table')];
    const before=tables.map(t=>({padding:parseFloat(getComputedStyle(t.rows[0].cells[0]).paddingTop),font:getComputedStyle(t).fontSize}));
    tables[1].style.fontSize='9px';
    return {body:size?24:1.2*parseFloat(getComputedStyle(document.documentElement).fontSize),margin:parseFloat(getComputedStyle(tables[0]).marginTop),before,nestedAfter:parseFloat(getComputedStyle(tables[1].rows[0].cells[0]).paddingTop)};
   });
  });
  for(const value of sizes){
   assert.ok(Math.abs(value.margin-value.body*.5)<.02,'table margins use configured normal-body size');
   for(const cell of value.before)assert.ok(Math.abs(cell.padding-value.body*.5)<.02,'nested cell padding does not compound table font size');
   assert.ok(Math.abs(value.nestedAfter-value.body*.5)<.02,'changing nested text size does not change compiled lengths');
  }
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

 // Computed TABLE-origin line height is a length, not a cell font multiplier.
 await page.setContent('<style>'+css+'</style><main style="font-size:20px"></main>');
 await page.addScriptTag({content:bundle.outputFiles[0].text});
 const inline=await page.evaluate(()=>{
  document.documentElement.style.setProperty('--wikidict-normal-body-size','20px');
  const span={kind:'link',text:'Audio licence',target:'Licence',font_scale:.8,font_scale_basis:'normal_body'};
  const paragraph={kind:'paragraph',spans:[span]};
  const value={caption:[],style:{display:'inline_block',vertical_align:'middle',line_height:{value:1,font_scale_basis:'normal_body'}},rows:[{cells:[{spans:[span,{kind:'line_break',text:''},span]}]}]};
  const host=document.querySelector('main');window.inlineActions=[];
  host.append(Renderer.renderEntry({title:'Inline audio',sections:[{title:'S',blocks:[{kind:'list_item',list_path:'*',spans:[],table:value}]}]},t=>inlineActions.push(t)));
  const table=host.querySelector('table'),links=[...table.querySelectorAll('a')],link=links[0];
  // Rich cell blocks remain supported by ordinary block tables, not inline tables.
  const blockHost=document.createElement('div');host.append(blockHost);
  blockHost.append(Renderer.renderEntry({title:'Block table',sections:[{title:'S',blocks:[{kind:'table',spans:[],table:{caption:[],style:{line_height:value.style.line_height},rows:[{cells:[{spans:[],blocks:[paragraph,paragraph]}]}]}}]}]},()=>{}));
  const blocks=[...blockHost.querySelectorAll('table .block')];
  const cs=getComputedStyle(table),cell=getComputedStyle(table.rows[0].cells[0]);
  const selected=getSelection(),range=document.createRange();range.selectNodeContents(table);selected.removeAllRanges();selected.addRange(range);
  const text=selected.toString();let refused=0;
  for(const table of [{...value,caption:[{kind:'text',text:'Caption'}]},{...value,rows:[]},{...value,style:{...value.style,float_side:'left'}},{...value,style:{...value.style,line_height:{value:0}}},{...value,style:{...value.style,line_height:{value:1,font_scale_basis:'cell'}}},{...value,rows:[{cells:[{spans:[],blocks:[paragraph,paragraph]}]}]}])try{Renderer.renderEntry({title:'Bad',sections:[{title:'S',blocks:[{kind:'table',table}]}]},()=>{});}catch{refused++;}
  return {display:cs.display,align:cs.verticalAlign,lineHeight:cs.lineHeight,cellLineHeight:cell.lineHeight,blockLineHeights:blocks.map(b=>getComputedStyle(b).lineHeight),linkLines:links.map(a=>getComputedStyle(a).lineHeight),lineAdvance:links[1].getBoundingClientRect().top-links[0].getBoundingClientRect().top,breaks:table.querySelectorAll('br').length,linkFont:getComputedStyle(link).fontSize,width:table.getBoundingClientRect().width,hostWidth:host.getBoundingClientRect().width,text,refused,marker:host.querySelector('.prefix')?.textContent};
 });
 assert.equal(inline.display,'inline-block');assert.equal(inline.align,'middle');assert.equal(inline.marker,'•');
 assert.equal(inline.lineHeight,'20px');assert.equal(inline.cellLineHeight,'20px');assert.equal(inline.blockLineHeights.length,2);assert.ok(inline.blockLineHeights.every(v=>v==='20px'));
 assert.deepEqual(inline.linkLines,['20px','20px']);assert.equal(inline.breaks,1);assert.equal(inline.lineAdvance,20);
 assert.equal(inline.linkFont,'16px');assert.ok(inline.width<inline.hostWidth);assert.match(inline.text,/Audio licence/);assert.equal(inline.refused,6);
 await page.getByRole('link',{name:'Audio licence',exact:true}).first().focus();await page.keyboard.press('Enter');
 assert.deepEqual(await page.evaluate(()=>inlineActions),['Licence']);

 // DPRL retains real owners and browser layout across responsive/theme changes.
 await page.setViewportSize({width:900,height:700});
 await page.setContent('<style>'+css+'</style><main></main>');
 await page.addScriptTag({content:bundle.outputFiles[0].text});
 await page.evaluate(()=>{
  document.documentElement.style.setProperty('--wikidict-normal-body-size','20px');
  const length=value=>({unit:'px',value}),edges=value=>Object.fromEntries(['top','right','bottom','left'].map(side=>[side,length(value)]));
  const container=(style,blocks)=>({kind:'container',depth:0,level:0,spans:[],container:{style,blocks}});
  const text=text=>({kind:'text',text});
  const first={kind:'definition',spans:[{kind:'link',text:'Nested meaning',target:'Exact title',target_fragment:'Part',tooltip:'Owned tooltip',explanation:'Owned explanation',font_scale:.5,font_scale_basis:'normal_body'}]};
  const second={kind:'paragraph',spans:[text('Second child')]};
  const outer=container({width:{length:length(300)},max_width:{length:length(400)},box_sizing:'border_box',padding:edges(10),margins:edges(0),float_side:'right',clear:'both',layout:'flex_row',align_items:'center',line_height:{multiplier:2},text_align:'right',background:{light_dark:{light:'#ddeeff',dark:'#112233'}},border:{solid:{width:length(2),color:{light_dark:{light:'#123456',dark:'#abcdef'}}}},screen_max_width:{max_width_px:719,width:{length:{unit:'percent',value:100}},max_width:{none:{}},float_side:'none',margins:Object.fromEntries(['top','right','bottom','left'].map(side=>[side,['right','left'].includes(side)?{auto:{}}:{length:length(0)}])),following_rules:[{max_width_px:399,width:{auto:{}},line_height:{normal:{}}}]}},[
   container({width:{length:{unit:'percent',value:50}},flex_item:'none'},[first]),
   container({width:{length:{unit:'percent',value:50}},flex_item:'none'},[second])
  ]);
  const scroll=container({width:{length:length(100)},overflow:'auto',clear:'both',padding:edges(4)},[
   container({width:{length:length(300)}},[{kind:'paragraph',spans:[text('Local scroll body')]}])
  ]);
  const empty=container({padding:edges(4),background:{rgb:'#ccddaa'},border:{none:{}},clear:'both'},[]);
  window.containerEntry={title:'Container control',presentation_version:'DPRL',sections:[{title:'Meaning',level:2,blocks:[outer,scroll,empty]}],references:[],media:[]};
  window.containerBefore=JSON.stringify(containerEntry);window.containerActions=[];
  document.querySelector('main').append(Renderer.renderEntry(containerEntry,(...args)=>containerActions.push(args),{collapseOtherSections:true}));
  window.containerOwner=document.querySelector('.compiled-container');
 });
 const inspectContainers=()=>page.evaluate(()=>{
  const main=document.querySelector('main'),outer=window.containerOwner,children=[...outer.children].filter(e=>e.classList.contains('compiled-container'));
  const cs=getComputedStyle(outer),box=outer.getBoundingClientRect(),scroll=document.querySelector('[aria-label="Scrollable content"]');
  const range=document.createRange();range.selectNodeContents(outer);getSelection().removeAllRanges();getSelection().addRange(range);
  return {same:document.querySelector('.compiled-container')===outer,unchanged:JSON.stringify(containerEntry)===containerBefore,open:outer.closest('details').open,
   width:box.width,parent:outer.parentElement.getBoundingClientRect().width,padding:cs.paddingLeft,box:cs.boxSizing,display:cs.display,align:cs.alignItems,float:cs.cssFloat,clear:cs.clear,color:cs.backgroundColor,border:cs.borderTopColor,lineHeight:cs.lineHeight,textAlign:cs.textAlign,
   children:children.map(child=>({width:child.getBoundingClientRect().width,flex:getComputedStyle(child).flex,line:getComputedStyle(child.querySelector('.block')).lineHeight})),
   selected:getSelection().toString(),linkFont:getComputedStyle(outer.querySelector('a span')).fontSize,tooltip:outer.querySelector('[title]')?.title,explanation:main.querySelector('.abbreviation-explanations dd')?.textContent,
   scroll:{width:scroll.clientWidth,extent:scroll.scrollWidth,focusable:scroll.tabIndex,overflow:getComputedStyle(scroll).overflowX},empty:[...main.querySelectorAll('.compiled-container')].at(-1).getBoundingClientRect().height,
   footer:main.querySelector('.compiled-table-flow>footer').getBoundingClientRect().top,bottom:box.bottom};
 });
 const wide=await inspectContainers();
 assert.ok(wide.same&&wide.unchanged&&wide.open);assert.equal(wide.width,300);assert.equal(wide.padding,'10px');assert.equal(wide.box,'border-box');assert.equal(wide.display,'flex');assert.equal(wide.align,'center');assert.equal(wide.float,'right');assert.equal(wide.clear,'both');
 assert.equal(wide.color,'rgb(221, 238, 255)');assert.equal(wide.border,'rgb(18, 52, 86)');assert.equal(wide.lineHeight,'40px');assert.equal(wide.textAlign,'right');
 assert.equal(wide.children.length,2);for(const child of wide.children){assert.equal(child.width,138);assert.equal(child.flex,'0 0 auto');assert.equal(child.line,'40px');}
 assert.match(wide.selected,/Nested meaning[\s\S]*Second child/);assert.equal(wide.linkFont,'10px');assert.equal(wide.tooltip,'Owned tooltip');assert.equal(wide.explanation,'Owned explanation');
 assert.equal(wide.scroll.focusable,0);assert.equal(wide.scroll.overflow,'auto');assert.ok(wide.scroll.extent>wide.scroll.width);assert.equal(wide.empty,8);assert.ok(wide.footer>=wide.bottom);
 await page.getByRole('link',{name:'Nested meaning',exact:true}).focus();
 if(containerReport)await page.screenshot({path:path.join(containerReport,'container-wide-light.png')});
 await page.keyboard.press('Enter');
 assert.deepEqual(await page.evaluate(()=>containerActions),[['Exact title','Part']]);
 await page.locator('[aria-label="Scrollable content"]').focus();await page.keyboard.press('ArrowRight');
 await page.waitForFunction(()=>document.querySelector('[aria-label="Scrollable content"]').scrollLeft>0);
 for(const width of [720,719,399,900]){
  await page.setViewportSize({width,height:700});
  const actual=await inspectContainers();assert.ok(actual.same&&actual.unchanged);
  if(width>719){assert.equal(actual.width,300);assert.equal(actual.float,'right');assert.equal(actual.lineHeight,'40px');}
  else {assert.equal(actual.float,'none');assert.ok(Math.abs(actual.width-actual.parent)<1);assert.equal(actual.lineHeight,width<=399?'normal':'40px');}
 }
 await page.evaluate(()=>document.documentElement.dataset.theme='dark');
 const dark=await inspectContainers();assert.equal(dark.color,'rgb(17, 34, 51)');assert.equal(dark.border,'rgb(171, 205, 239)');assert.equal(dark.width,300);
 await page.setViewportSize({width:399,height:700});
 const darkNarrow=await inspectContainers();assert.equal(darkNarrow.float,'none');assert.ok(Math.abs(darkNarrow.width-darkNarrow.parent)<1);assert.equal(darkNarrow.color,dark.color);
 assert.equal(darkNarrow.lineHeight,'normal');
 if(containerReport)await page.screenshot({path:path.join(containerReport,'container-narrow-dark.png')});

 // An L owner has no font override. Caption metrics remain the context for
 // contextual spans; explicit normal-body scales still use the body basis.
 await page.setContent('<style>'+css+'</style><main></main>');
 await page.addScriptTag({content:bundle.outputFiles[0].text});
 const captionFonts=await page.evaluate(()=>{
  document.documentElement.style.setProperty('--wikidict-normal-body-size','20px');
  const length=value=>({unit:'px',value}),edges=Object.fromEntries(['top','right','bottom','left'].map(side=>[side,length(0)]));
  const owner={kind:'container',spans:[],container:{style:{},blocks:[{kind:'definition',spans:[
   {kind:'text',text:'Contextual',font_scale:.5,font_scale_basis:'context'},
   {kind:'text',text:'Body basis',font_scale:.5,font_scale_basis:'normal_body'}
  ]}]}};
  const table={kind:'table',spans:[],table:{caption:[],caption_blocks:[owner],rows:[{cells:[{spans:[{kind:'text',text:'Cell'}]}]}]}};
  const figure={kind:'paragraph',spans:[],figure:{format:'thumbnail',placement:'none',clear:'none',margins:edges,image_insets:edges,caption_padding:edges,caption_font_scale:.6,caption_line_height:length(18),frame_background:{kind:'transparent'},frame_border:{kind:'none'},image_background:{kind:'transparent'},image_border:{kind:'none'},caption_foreground:{kind:'native_theme'},caption_background:{kind:'transparent'},image_span:{kind:'text',text:'',image:{file:'Caption.svg',width_px:120}},caption:[],caption_blocks:[owner],sizing:'requested_fit'}};
  document.querySelector('main').append(Renderer.renderEntry({title:'Inherited captions',sections:[{title:'S',blocks:[table,figure]}],media:[{file:'Caption.svg',kind:'image'}]},()=>{},{collapseOtherSections:true,collapseDetails:true}));
  const grid=document.querySelector('table');grid.style.fontFamily='monospace';grid.style.fontSize='13px';grid.style.lineHeight='17px';
  return [...document.querySelectorAll('.compiled-container')].map(el=>({root:el.classList.contains('compiled-container-root'),meaningOpen:el.closest('details').open&&el.closest('details').classList.contains('meaning'),inNotes:!!el.closest('.sense-notes'),size:getComputedStyle(el).fontSize,family:getComputedStyle(el).fontFamily,line:getComputedStyle(el).lineHeight,blockLine:getComputedStyle(el.querySelector('.block')).lineHeight,spans:[...el.querySelectorAll('.body > span')].map(span=>getComputedStyle(span).fontSize)}));
 });
 assert.equal(captionFonts.length,2);assert.ok(captionFonts.every(value=>!value.root));
 assert.ok(captionFonts.every(value=>value.meaningOpen&&!value.inNotes),'L meanings hosted in table/figure captions stay in the open main section');
 assert.equal(captionFonts[0].size,'13px');assert.equal(captionFonts[0].family,'monospace');assert.equal(captionFonts[0].line,'17px');assert.equal(captionFonts[0].blockLine,'17px');assert.deepEqual(captionFonts[0].spans,['6.5px','10px']);
 assert.equal(captionFonts[1].size,'12px');assert.equal(captionFonts[1].line,'18px');assert.equal(captionFonts[1].blockLine,'18px');assert.deepEqual(captionFonts[1].spans,['6px','10px']);
}finally{await browser.close();}
