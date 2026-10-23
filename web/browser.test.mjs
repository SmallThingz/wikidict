import {chromium} from 'playwright';
import {build as buildRendererTestBundle} from 'esbuild';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
import {aliasCases,aliasPayload,dictionaryBlob,presentation} from './alias-fixtures.mjs';
const root=fileURLToPath(new URL('../build/web/',import.meta.url)),report=fileURLToPath(new URL('../artifacts/web/',import.meta.url));
await mkdir(report,{recursive:true});
const nativeOnly=process.argv.includes('--native-only');
const fixture=process.env.WIKBLB_FIXTURE||fileURLToPath(new URL('../tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb',import.meta.url));
const raw=nativeOnly?null:await readFile(fixture),xz=nativeOnly?null:execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
const server=createServer(async(req,res)=>{try{const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname),file=path.resolve(root,'.'+(name==='/'?'/index.html':name));if(!file.startsWith(root))throw Error('path');const bytes=await readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[];
try{
 if(!nativeOnly){
 const rendererBundle=await buildRendererTestBundle({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],bundle:true,format:'iife',globalName:'WikidictRendererQA',write:false});
 const rendererPage=await browser.newPage();rendererPage.on('pageerror',e=>errors.push(e.message));
 await rendererPage.setContent('<main id="compiled-renderer-fixture"></main>');
 await rendererPage.addScriptTag({content:rendererBundle.outputFiles[0].text});
 const listBlock=(kind,text,number,path,depth)=>({kind,number,path,depth,spans:[{kind:'text',text,trail:''}]});
 const renderedLists=await rendererPage.evaluate(entry=>{
  const host=document.getElementById('compiled-renderer-fixture');
  host.replaceChildren(WikidictRendererQA.renderEntry(entry,()=>{}, {collapseOtherSections:false,collapseDetails:false}));
  return {prefixes:[...host.querySelectorAll('.block.list_item > .prefix')].map(el=>el.textContent),
   indents:[...host.querySelectorAll('.block.list_item')].map(el=>parseFloat(el.style.marginInlineStart)),
   definitions:host.querySelectorAll('.block.definition').length,
   meaningSections:[...host.querySelectorAll('details.meaning > summary')].map(el=>el.textContent),
   text:host.textContent,literalLinks:host.querySelectorAll('.block.paragraph a').length};
 },{title:'Ordered fixture',kind:'supplemental',sections:[
  {title:'List',blocks:[
   listBlock('list_item','Parent ordered','3','#',1),listBlock('list_item','Nested unordered','','#*',2),
   listBlock('list_item','Nested ordered','3.1','#*#',3),listBlock('list_detail','Parent continuation','','#:',2),
   listBlock('list_item','Explicit value','8','#',1),listBlock('list_item','Following value','9','#',1),
   listBlock('list_item','Alphabetic label','AA','#',1),listBlock('list_item','Roman label','iii','#',1),
   listBlock('list_item','Roman value','xxvi','#',1),listBlock('list_item','Escaped label','<i>','#',1),listBlock('paragraph','{{example}} [[literal]]','','',0)]},
  {title:'Meaning',blocks:[listBlock('definition','Actual dictionary meaning','1','#',1)]}]});
 assert.deepEqual(renderedLists.prefixes,['3.','•','3.1.','8.','9.','AA.','iii.','xxvi.','<i>.']);
 assert.equal(await rendererPage.locator('.list_item > .prefix i').count(),0);
 assert.ok(renderedLists.indents[2]>renderedLists.indents[1] && renderedLists.indents[1]>renderedLists.indents[0]);
 assert.equal(renderedLists.definitions,1);assert.deepEqual(renderedLists.meaningSections,['Meaning']);
 assert.ok(renderedLists.text.includes('{{example}} [[literal]]'));assert.equal(renderedLists.literalLinks,0);
 const renderedTables=await rendererPage.evaluate(()=>{
  const table=(depth,caption)=>({kind:'table',depth,path:depth?'#:':'',spans:[],table:{caption:[{kind:'text',text:caption}],rows:[{cells:[{header:false,colspan:1,rowspan:1,spans:[{kind:'text',text:'Cell'}]}]}]}});
  const host=document.getElementById('compiled-renderer-fixture');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Table fixture',kind:'supplemental',sections:[{title:'Tables',blocks:[table(0,'Outer caption'),table(2,'Nested caption')]}]},()=>{}, {collapseOtherSections:false}));
  return {margins:[...host.querySelectorAll('.table-scroll')].map(el=>parseFloat(el.style.marginInlineStart)),captions:[...host.querySelectorAll('caption')].map(el=>el.textContent),rows:host.querySelectorAll('tr').length};
 });
 assert.deepEqual(renderedTables.margins,[0,.9]);
 assert.deepEqual(renderedTables.captions,['Outer caption','Nested caption']);assert.equal(renderedTables.rows,2);
 const automaticDirection=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');
  const sample='\u0645\u0631\u062d\u0628\u0627 123';
  const entry={title:'Automatic direction',kind:'supplemental',sections:[{title:'Body',blocks:[
   {kind:'paragraph',spans:[{kind:'text',text:'English '},{kind:'link',text:sample,target:'Arabic target',direction:'auto',bold:true},{kind:'text',text:' tail'}]}]}]};
  const before=JSON.stringify(entry);
  host.replaceChildren(WikidictRendererQA.renderEntry(entry,()=>{}, {collapseOtherSections:false}));
  const link=host.querySelector('.block.paragraph a'),span=link.querySelector('span');
  return {unchanged:before===JSON.stringify(entry),text:span.textContent,dir:span.dir,isolation:getComputedStyle(span).unicodeBidi,
   direction:getComputedStyle(span).direction,href:link.getAttribute('href'),bold:!!link.querySelector('strong')};
 });
 assert.deepEqual(automaticDirection,{unchanged:true,text:'\u0645\u0631\u062d\u0628\u0627 123',dir:'auto',isolation:'isolate',direction:'rtl',href:'#Arabic%20target',bold:true});
 await rendererPage.screenshot({path:path.join(report,'automatic-direction-renderer.png'),fullPage:true});
 await writeFile(path.join(report,'automatic-direction-renderer.json'),JSON.stringify(automaticDirection,null,2)+'\n');

 const compiledNavigation=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');
  const outside=document.createElement('div');outside.id='Toolbar collision';document.body.append(outside);
  const heading={kind:'heading',level:3,anchor:'Usage_notes_2',anchor_fallback:'Usage.20notes_2',spans:[{kind:'text',text:'Usage notes'}]};
  const entry={title:'Compiled navigation',sections:[
   {title:'Noun',level:3,anchor:'Noun',anchor_fallback:'',blocks:[{kind:'definition',spans:[{text:'First meaning'}]}]},
   {title:'Noun',level:3,anchor:'Noun_2',anchor_fallback:'',blocks:[{kind:'definition',spans:[{text:'Second meaning'}]},heading]},
   {title:'Unicode heading',level:3,anchor:'\u00e4',anchor_fallback:'.C3.A4',blocks:[{kind:'heading',level:3,depth:1,anchor:'\u00e4',anchor_fallback:'.C3.A4',spans:[{text:'Unicode heading'}]}]}
  ]};
  const before=JSON.stringify(entry);host.replaceChildren(WikidictRendererQA.renderEntry(entry,()=>{}, {collapseOtherSections:true,collapseDetails:true}));
  const ids=[...host.querySelectorAll('[id]')].map(el=>el.id);
  const closedBefore=!host.querySelector('.sense-notes').open;
  host.querySelector('[id="Noun_2"]').open=false;
  const standalone=WikidictRendererQA.revealFragment(host,'Usage.20notes_2');
  const notesOpen=host.querySelector('.sense-notes').open;
  const sectionOpen=host.querySelector('[id="Noun_2"]').open;
  const unicode=WikidictRendererQA.revealFragment(host,'.C3.A4'),unicodeOpen=host.querySelector('[id="\u00e4"]').open;
  const second=WikidictRendererQA.revealFragment(host,'Noun_2'),focused=document.activeElement.id;
  const scoped=!WikidictRendererQA.revealFragment(host,'Toolbar collision');outside.remove();
  const blank={title:'Legacy title',anchor:'',anchor_fallback:'',blocks:[{kind:'paragraph',spans:[{text:'Body'}]}]};
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Legacy',sections:[blank]},()=>{}));
  const legacy=!!host.querySelector('[id="Legacy_title"]');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Anchored',presentation_version:'DPR5',sections:[blank]},()=>{}));
  const noInventedID=!host.querySelector('[id]');
  return {ids,closedBefore,standalone,notesOpen,sectionOpen,unicode,unicodeOpen,second,focused,scoped,legacy,noInventedID,unchanged:before===JSON.stringify(entry)};
 });
 assert.deepEqual(compiledNavigation,{ids:['Noun','Noun_2','Usage_notes_2','Usage.20notes_2','\u00e4','.C3.A4'],closedBefore:true,standalone:true,notesOpen:true,sectionOpen:true,unicode:true,unicodeOpen:true,second:true,focused:'Noun_2',scoped:true,legacy:true,noInventedID:true,unchanged:true});

 const navigationResolution=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');
  const paragraph=text=>({kind:'paragraph',spans:[{text}]});
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Legacy destinations',sections:[
   {title:'Repeated',blocks:[paragraph('First')]},{title:'Repeated',blocks:[paragraph('Second')]},
   {title:'Section',blocks:[{kind:'heading',spans:[{text:'Section'}]},{kind:'heading',spans:[{text:'Heading Only'}]}]}
  ]},()=>{}));
  const legacyIDs=[...host.querySelectorAll('[id]')].map(el=>el.id);
  const legacyHeading=WikidictRendererQA.revealFragment(host,'Heading Only');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Exact before normalized',presentation_version:'DPR5',sections:[
   {title:'Space',anchor:'A B',blocks:[paragraph('Literal space')]},
   {title:'Underscore',anchor:'A_B',blocks:[paragraph('Literal underscore')]},
   {title:'Mixed',anchor:'Usage_notes_2',blocks:[paragraph('Mixed separator')]}
  ]},()=>{}));
  WikidictRendererQA.revealFragment(host,'A B');const exact=document.activeElement.id;
  WikidictRendererQA.revealFragment(host,'Usage notes_2');const normalized=document.activeElement.id;
  const duplicate=document.createElement('span');duplicate.id='A B';host.append(duplicate);
  const ambiguous=!WikidictRendererQA.revealFragment(host,'A B');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Empty destinations',presentation_version:'DPR5',sections:[
   {title:'English',anchor:'English',anchor_fallback:'English.20owner',blocks:[]},
   {title:'Children',anchor:'Children',blocks:[{kind:'heading',anchor:'Empty_heading',anchor_fallback:'Empty.20heading',spans:[]}]}
  ]},()=>{}));
  const emptySection=WikidictRendererQA.revealFragment(host,'English'),emptySectionOpen=host.querySelector('[id="English"]').open;
  const emptyHeading=WikidictRendererQA.revealFragment(host,'Empty.20heading');
  window.headingCollisionLinks=[];
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Citation collision',presentation_version:'DPR5',sections:[
   {title:'Links',anchor:'Links',blocks:[{kind:'paragraph',spans:[{kind:'link',text:'Authored heading',target:'#reference-1'}]}]},
   {title:'Authored heading',anchor:'reference-1',blocks:[paragraph('Heading destination')]}
  ],references:[{number:1,group_number:1,group:'',spans:[{text:'Generated citation'}]}]},target=>{window.headingCollisionLinks.push(target);WikidictRendererQA.revealFragment(host,target.slice(1));}));
  host.querySelector('a').click();
  const headingWins=document.activeElement.id==='reference-1'&&document.activeElement.tagName==='DETAILS';
  const uniqueIDs=new Set([...host.querySelectorAll('[id]')].map(el=>el.id)).size===host.querySelectorAll('[id]').length;
  return {legacyIDs,legacyHeading,exact,normalized,ambiguous,emptySection,emptySectionOpen,emptyHeading,headingWins,uniqueIDs,links:window.headingCollisionLinks};
 });
 assert.deepEqual(navigationResolution,{legacyIDs:['Heading_Only'],legacyHeading:true,exact:'A B',normalized:'Usage_notes_2',ambiguous:true,emptySection:true,emptySectionOpen:true,emptyHeading:true,headingWins:true,uniqueIDs:true,links:['#reference-1']});

 const referenceFixture=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');window.referenceNavigations=[];
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Reference fixture',kind:'supplemental',sections:[{title:'Notes',blocks:[
   {kind:'paragraph',spans:[
    {kind:'link',text:'Grouped reference',target:'#reference-2'},
    {kind:'link',text:'Ordinary title',target:'a title #reference-2 & 猫'},
    {kind:'link',text:'Unmatched fragment',target:'#reference-404'}]}]}],references:[
     {number:1,group_number:1,group:'',spans:[{kind:'text',text:'Ordinary citation'}]},
     {number:2,group_number:1,group:'note <one>',spans:[{kind:'text',text:'{{Example}} [[Link]] __NOEDITSECTION__'}]}
   ]},target=>window.referenceNavigations.push(target),{collapseOtherSections:true}));
  const reference=host.querySelector('#reference-2');
  return {initiallyClosed:!reference.closest('details').open,text:reference.textContent};
 });
 await rendererPage.addStyleTag({content:'#compiled-renderer-fixture{padding-bottom:180px}.reference{min-height:80px}#compiled-renderer-fixture .block.paragraph{min-height:1000px}#renderer-fixed-nav{position:fixed;bottom:0;left:0;right:0;height:80px;background:white;z-index:9}'});
 await rendererPage.evaluate(()=>{const nav=document.createElement('nav');nav.id='renderer-fixed-nav';nav.textContent='Reader navigation';document.body.append(nav);});
 assert.equal(referenceFixture.initiallyClosed,true);
 assert.equal(referenceFixture.text,'[note <one> 1]{{Example}} [[Link]] __NOEDITSECTION__');
 await rendererPage.getByText('Notes',{exact:true}).click();
 await rendererPage.getByRole('link',{name:'Grouped reference',exact:true}).click();
 assert.equal(await rendererPage.locator('#reference-2').isVisible(),true);
 const matchedReference=await rendererPage.evaluate(()=>{
  const reference=document.getElementById('reference-2');
  return {opened:reference.closest('details').open,focused:document.activeElement===reference,navigation:window.referenceNavigations};
 });
 assert.deepEqual(matchedReference,{opened:true,focused:true,navigation:[]});
 assert.equal(await rendererPage.locator('#reference-2').evaluate(el=>{const target=el.getBoundingClientRect(),nav=document.getElementById('renderer-fixed-nav').getBoundingClientRect();return target.top>=0&&target.bottom<=nav.top;}),true);
 const ordinaryLink=rendererPage.getByRole('link',{name:'Ordinary title',exact:true});
 assert.equal(await ordinaryLink.getAttribute('href'),'#'+encodeURIComponent('a title #reference-2 & 猫'));
 await ordinaryLink.click();
 await rendererPage.getByRole('link',{name:'Unmatched fragment',exact:true}).click();
 assert.deepEqual(await rendererPage.evaluate(()=>window.referenceNavigations),['a title #reference-2 & 猫','#reference-404']);


 // Explanation disclosure is independent of compact labels and their existing link action.
 const explained=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');window.explanationLinks=[];
  const value=(text,extra={})=>({kind:'text',text,trail:'',explanation:'plain <meaning> & text',...extra});
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Annotations',kind:'language',language:'English',
   display_title:[value('Display')],preamble_spans:[value('Preamble')],sections:[{title:'Meaning',blocks:[
    {kind:'definition',spans:[value('der.',{kind:'link',target:'Appendix:Glossary#derived terms',explanation:'derived terms',bold:true}),value(' tail',{explanation:''})]},
    {kind:'paragraph',spans:[value('split ',{explanation:'split label'}),value('label',{italic:true,explanation:'split label'})]},
    {kind:'table',spans:[],table:{caption:[value('Caption')],rows:[{cells:[{header:false,colspan:1,rowspan:1,spans:[value('Cell')]}]}]}}
   ]}],references:[{number:1,group_number:1,group:'',spans:[value('Reference')]}]},target=>window.explanationLinks.push(target),{collapseOtherSections:false,collapseDetails:false}));
  const link=host.querySelector('.definition a'),id=link.getAttribute('aria-describedby');
  return {compact:host.querySelector('.definition .body').textContent,href:link.getAttribute('href'),description:host.querySelector('#'+id).textContent,
   labels:[...host.querySelectorAll('.abbreviation-explanations dt')].map(n=>n.textContent),
   noMarkup:host.querySelectorAll('.abbreviation-explanations meaning').length,
   annotatedContainers:['h1','caption','td','.reference'].map(selector=>!!host.querySelector(selector)?.querySelector('abbr')),
   annotatedPreamble:[...host.querySelectorAll('details')].some(el=>el.querySelector(':scope > summary')?.textContent==='About this entry' && !!el.querySelector('abbr'))};
 });
 assert.equal(explained.compact,'der. tail');assert.equal(explained.href,'#'+encodeURIComponent('Appendix:Glossary#derived terms'));assert.equal(explained.description,'derived terms');
 assert.deepEqual(explained.labels,['Display','Preamble','der.','split label','Caption','Cell','Reference']);assert.equal(explained.noMarkup,0);
 assert.deepEqual(explained.annotatedContainers,[true,true,true,true]);assert.equal(explained.annotatedPreamble,true);
 const annotations=rendererPage.locator('details.abbreviation-explanations');
 await annotations.locator('summary').focus();await rendererPage.keyboard.press('Enter');assert.equal(await annotations.evaluate(el=>el.open),true);
 assert.equal(await annotations.getByText('plain <meaning> & text',{exact:true}).first().isVisible(),true);
 const annotatedLink=rendererPage.getByRole('link',{name:'der.',exact:true});await annotatedLink.focus();await rendererPage.keyboard.press('Enter');
 assert.deepEqual(await rendererPage.evaluate(()=>window.explanationLinks),['Appendix:Glossary#derived terms']);
 await rendererPage.evaluate(()=>{const host=document.getElementById('compiled-renderer-fixture');host.replaceChildren(WikidictRendererQA.renderEntry({title:'Plain',kind:'language',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:[{kind:'text',text:'No annotation'}]}]}]},()=>{}));});
 assert.equal(await rendererPage.locator('.abbreviation-explanations,abbr[title]').count(),0);



 const trailCoverage=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Trails',kind:'language',sections:[{title:'Body',blocks:[{kind:'paragraph',spans:[
   {kind:'link',text:'linked',target:'Target',trail:'suffix',explanation:'linked trail'},
   {kind:'line_break',text:'',trail:'continued',explanation:'line trail'}
  ]},
   {kind:'paragraph',spans:[{kind:'line_break',text:'',trail:'line only',explanation:'only line'}]},
   {kind:'paragraph',spans:[{kind:'text',text:'',trail:'plain only',explanation:'only text'}]},
   {kind:'paragraph',spans:[{kind:'text',text:'',trail:'',explanation:'empty is not content'}]}
  ]}]},()=>{}, {collapseOtherSections:false}));
  const body=host.querySelector('.body'),link=body.querySelector('a');
  return {text:body.textContent,linkedText:link.textContent,trailText:link.nextSibling.textContent,trailTag:link.nextSibling.tagName,trailTitle:link.nextSibling.title,
   breaks:body.querySelectorAll('br').length,lastText:body.lastChild.textContent,lastTag:body.lastChild.tagName,lastTitle:body.lastChild.title,
   notes:[...host.querySelectorAll('.abbreviation-explanations dt')].map(el=>el.textContent),
   paragraphCount:host.querySelectorAll('.block.paragraph').length,
   trailOnly:[...host.querySelectorAll('.block.paragraph .body')].slice(1).map(el=>({text:el.textContent,trailTag:el.lastChild.tagName,trailTitle:el.lastChild.title}))};
 });
 assert.deepEqual(trailCoverage,{text:'linkedsuffixcontinued',linkedText:'linked',trailText:'suffix',trailTag:'ABBR',trailTitle:'linked trail',breaks:1,lastText:'continued',lastTag:'ABBR',lastTitle:'line trail',notes:['linkedsuffix','continued','line only','plain only'],paragraphCount:3,trailOnly:[{text:'line only',trailTag:'ABBR',trailTitle:'only line'},{text:'plain only',trailTag:'ABBR',trailTitle:'only text'}]});
 const headingCoverage=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');window.headingLinks=[];
  const text=(text,extra={})=>({kind:'text',text,trail:'',...extra});
  const section=(title,spans,level=2)=>({title,level:2,blocks:[{kind:'heading',level,spans},{kind:'paragraph',spans:[text('Retained body')]}]});
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Companions',kind:'language',sections:[
   section('Explained',[text('\u00a0Explained\u00a0',{explanation:'heading note'})]),
   section('Linked',[text('Linked',{kind:'link',target:'Heading target'})]),
   section('Plain',[text('Plain')]),section('Mismatch',[text('Other',{explanation:'other note'})]),
   section('WrongLevel',[text('WrongLevel',{explanation:'level note'})],3),
   section('Break',[text('Break',{explanation:'break note'}),{kind:'line_break',text:'',trail:' '}]),
   section('EdgeBreak',[{kind:'line_break',text:'',trail:''},text('EdgeBreak',{explanation:'edge note'})])
  ]},target=>window.headingLinks.push(target),{collapseOtherSections:true}));
  return ['Explained','Linked','Plain','Mismatch','WrongLevel','Break','EdgeBreak'].map(id=>{
   const el=[...host.querySelectorAll(':scope > details')].find(section=>section.querySelector(':scope > summary')?.textContent.trim()===id);return {id,summary:el.querySelector(':scope > summary').textContent.trim(),headingCount:el.querySelectorAll('.block.heading').length};
  });
 });
 assert.deepEqual(headingCoverage.map(x=>x.headingCount),[0,0,1,1,1,1,0]);
 assert.deepEqual(headingCoverage.map(x=>x.summary),['Explained','Linked','Plain','Mismatch','WrongLevel','Break','EdgeBreak']);
 const headingSection=rendererPage.locator('#compiled-renderer-fixture > details').filter({has:rendererPage.getByRole('link',{name:'Linked',exact:true})}),headingLink=headingSection.locator(':scope > summary a');
 assert.equal(await headingSection.evaluate(el=>el.open),false);await headingLink.focus();await rendererPage.keyboard.press('Enter');
 assert.deepEqual(await rendererPage.evaluate(()=>window.headingLinks),['Heading target']);assert.equal(await headingSection.evaluate(el=>el.open),false);
 await headingSection.locator(':scope > summary').focus();await rendererPage.keyboard.press('Enter');assert.equal(await headingSection.evaluate(el=>el.open),true);

 const styledHeadingCoverage=await rendererPage.evaluate(()=>{
  const host=document.getElementById('compiled-renderer-fixture');
  const styles=[...['bold','italic','code','small','superscript','subscript','strike','underline'].map(flag=>({[flag]:true})),
   {foreground:'#123456'},{classes:'note'},{language:'fr'},{direction:'rtl'},{role:'label'}];
  const section=(title,extra={},level=3)=>({title,level:3,blocks:[{kind:'heading',level,spans:[{kind:'text',text:title,...extra}]},
   {kind:'paragraph',spans:[{kind:'text',text:'Retained styled heading body'}]}]});
  const fixtures=styles.flatMap((style,i)=>[section('Styled '+i,style),section('Targeted '+i,{...style,target:'other'}),section('Wrong level '+i,style,2)]);
  fixtures.push(section('Plain control'));
  host.replaceChildren(WikidictRendererQA.renderEntry({title:'Styled companions',kind:'language',sections:fixtures},()=>{},{}));
  return [...host.querySelectorAll(':scope > details')].map(el=>({headings:el.querySelectorAll('.block.heading').length,
   lexicalLinks:el.querySelectorAll(':scope > summary a').length,body:el.textContent.includes('Retained styled heading body')}));
 });
 assert.equal(styledHeadingCoverage.length,40);
 for(let i=0;i<13;i++){
  assert.deepEqual(styledHeadingCoverage[i*3],{headings:0,lexicalLinks:0,body:true});
  assert.deepEqual(styledHeadingCoverage[i*3+1],{headings:1,lexicalLinks:0,body:true});
  assert.deepEqual(styledHeadingCoverage[i*3+2],{headings:1,lexicalLinks:0,body:true});
 }
 assert.deepEqual(styledHeadingCoverage.at(-1),{headings:1,lexicalLinks:0,body:true});
 await rendererPage.screenshot({path:path.join(report,'styled-unlinked-heading-companions.png'),fullPage:true});

  const indentedHeading=await rendererPage.evaluate(()=>{
   const host=document.getElementById('compiled-renderer-fixture');window.indentedHeadingLinks=[];
   const phrase="Se beiga la conchugazión benasquesa d'este berbo.";
   const heading={kind:'heading',level:4,depth:1,list_path:':',spans:[
    {kind:'text',text:'Se beiga ',italic:true},
    {kind:'link',text:'la conchugazión benasquesa',target:'templlar/conj.BEN',bold:true,italic:true},
    {kind:'text',text:" d'este berbo.",italic:true}]};
   host.replaceChildren(WikidictRendererQA.renderEntry({title:'templlar',kind:'language',sections:[
    {title:phrase,level:4,blocks:[heading]},
    {title:'Plain indented',level:4,blocks:[{kind:'heading',level:4,depth:1,list_path:':',spans:[{kind:'text',text:'Plain indented'}]}]},
    {title:'Empty plain control',level:4,blocks:[]},
    {title:'Mismatch control',level:4,blocks:[{...heading,spans:[{kind:'text',text:'Different heading'}]}]}
   ]},target=>window.indentedHeadingLinks.push(target),{collapseOtherSections:true}));
   const sections=[...host.querySelectorAll(':scope > details')];
   const first=sections[0],label=first.querySelector('.heading-label');first.id='indented-heading-case';
   return {count:sections.length,text:first.textContent,duplicate:first.querySelectorAll('.block.heading').length,
    margin:label.style.marginInlineStart,plainCount:sections[1].textContent.split('Plain indented').length-1,
    plainMargin:sections[1].querySelector('.heading-label').style.marginInlineStart,
    mismatch:sections[2].querySelectorAll('.block.heading').length,
    bold:!!label.querySelector('a strong'),italic:!!label.querySelector('a em'),open:first.open};
  });
  assert.equal(indentedHeading.count,3);assert.equal(indentedHeading.text,"Se beiga la conchugazión benasquesa d'este berbo.");
  assert.equal(indentedHeading.duplicate,0);assert.equal(indentedHeading.margin,'0.45rem');assert.equal(indentedHeading.plainCount,1);
  assert.equal(indentedHeading.plainMargin,'0.45rem');assert.equal(indentedHeading.mismatch,1);
  assert.equal(indentedHeading.bold,true);assert.equal(indentedHeading.italic,true);assert.equal(indentedHeading.open,false);
  const indentedSection=rendererPage.locator('#compiled-renderer-fixture > #indented-heading-case');
  await indentedSection.locator('summary a').focus();await rendererPage.keyboard.press('Enter');
  assert.deepEqual(await rendererPage.evaluate(()=>window.indentedHeadingLinks),['templlar/conj.BEN']);
  assert.equal(await indentedSection.evaluate(el=>el.open),false);
  await indentedSection.locator('summary').focus();await rendererPage.keyboard.press('Enter');
  assert.equal(await indentedSection.evaluate(el=>el.open),true);
  await rendererPage.setViewportSize({width:360,height:640});
  await rendererPage.addStyleTag({content:'#compiled-renderer-fixture{padding-bottom:0!important;max-width:100%}'});
  assert.equal(await indentedSection.evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  await rendererPage.screenshot({path:path.join(report,'heading-companion-ltr-360.png'),fullPage:true});
  await rendererPage.evaluate(()=>{
   const label='عنوان عربي طويل لاختبار التفاف النص واتجاه القراءة';
   document.getElementById('compiled-renderer-fixture').replaceChildren(WikidictRendererQA.renderEntry({title:'RTL renderer control',kind:'language',sections:[
    {title:label,level:4,blocks:[{kind:'heading',level:4,depth:1,list_path:':',spans:[{kind:'link',text:label,target:'RTL control target',direction:'rtl',bold:true,italic:true}]}]}
   ]},()=>{}, {collapseOtherSections:false}));
   document.querySelector('#compiled-renderer-fixture details').dir='rtl';
  });
  assert.equal(await rendererPage.locator('#compiled-renderer-fixture details').evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  await rendererPage.screenshot({path:path.join(report,'heading-companion-rtl-360.png'),fullPage:true});

 await rendererPage.close();
 }

 // Native fixture context is isolated from the existing IndexedDB/library contracts.
 const abbreviationRoot=process.env.WIKBLB_ABBREVIATION_ROOT||fileURLToPath(new URL('../tests/fixtures/abbreviation-interop/',import.meta.url));
 const abbreviationBlob=path.join(abbreviationRoot,'languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb');
 const nativeContext=await browser.newContext();
 try{
  const nativePage=await nativeContext.newPage();nativePage.on('pageerror',e=>errors.push(e.message));
  await nativePage.goto(`http://127.0.0.1:${server.address().port}`);
  await nativePage.locator('#file').setInputFiles(abbreviationBlob);await nativePage.getByText(/English · 2 words/).waitFor();
  await nativePage.getByRole('button',{name:'Search',exact:true}).click();
  await nativePage.getByRole('searchbox').fill('Acupuncture abbreviation sample');
  await nativePage.getByRole('button',{name:'Open Acupuncture abbreviation sample',exact:true}).click();
  await nativePage.locator('#entry h1').filter({hasText:'Acupuncture abbreviation sample'}).waitFor();
  const nativeBody=nativePage.locator('#entry .block.paragraph .body');
  const bodySection=nativePage.locator('#entry details:not(.abbreviation-explanations)').filter({has:nativePage.locator('.block.paragraph .body')});
  assert.equal(await bodySection.count(),1);
  if(!await bodySection.evaluate(el=>el.open))await bodySection.locator(':scope > summary').click();
  await nativeBody.scrollIntoViewIfNeeded();assert.equal(await nativeBody.isVisible(),true);
  assert.equal(await nativeBody.textContent(),'der. ? lbor. f c m n');
  const nativeNotes=nativePage.locator('#entry details.abbreviation-explanations');
  if(!await nativeNotes.evaluate(el=>el.open))await nativeNotes.locator(':scope > summary').click();
  assert.equal(await nativeNotes.evaluate(el=>el.open),true);
  assert.deepEqual(await nativeNotes.locator('dt').allTextContents(),['der.','?','lbor.','f','c','m','n']);
  assert.deepEqual(await nativeNotes.locator('dd').allTextContents(),['derived terms','uncertain','learned borrowing','feminine gender','common gender','masculine gender','neuter gender']);
  for(const [width,height] of [[360,800],[1440,900]]){
   await nativePage.setViewportSize({width,height});
   try{
    if(await nativeNotes.evaluate(el=>el.open))await nativeNotes.locator(':scope > summary').click();
    await nativeBody.scrollIntoViewIfNeeded();assert.equal(await nativeBody.isVisible(),true);
    assert.equal(await nativePage.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'native reader horizontal overflow');
    await nativePage.screenshot({path:path.join(report,`abbreviations-native-reader-${width}.png`),fullPage:true});
    await nativeNotes.locator(':scope > summary').click();assert.equal(await nativeNotes.evaluate(el=>el.open),true);
    const descriptions=nativeNotes.locator('dd');assert.equal(await descriptions.count(),7);
    for(let i=0;i<7;i++){
     const description=descriptions.nth(i);await description.scrollIntoViewIfNeeded();assert.equal(await description.isVisible(),true);
     assert.equal(await description.evaluate(el=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0&&r.top>=0&&r.bottom<=innerHeight;}),true,'native explanation outside viewport');
    }
    assert.equal(await nativePage.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'native disclosure horizontal overflow');
    await nativePage.screenshot({path:path.join(report,`abbreviations-native-disclosure-${width}.png`),fullPage:true});
    // Ordinary reader navigation must expose the complete attribution above the dock.
    await nativePage.locator('#entry h1').click();await nativePage.keyboard.press('End');
    await nativePage.waitForFunction(()=>{
     const scroller=document.scrollingElement;if(!scroller)return false;
     const atEnd=()=>Math.abs(scroller.scrollHeight-scroller.clientHeight-scroller.scrollTop)<=1;
     if(!atEnd())return false;const top=scroller.scrollTop;
     return new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(atEnd()&&Math.abs(scroller.scrollTop-top)<=1))));
    },null,{timeout:5000});
    const footer=nativePage.locator('#entry footer');assert.equal(await footer.count(),1);
    assert.equal(await footer.getByRole('link',{name:'Wiktionary contributors',exact:true}).count(),1);
    assert.ok((await footer.innerText()).includes('CC BY-SA 4.0'));
    const footerBounds=await footer.evaluate(el=>{
     const rect=r=>({left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height});
     const dock=document.getElementById('dock').getBoundingClientRect();
     return {viewport:{width:innerWidth,height:innerHeight},dock:rect(dock),
      safeBottom:Math.min(dock.top,innerHeight-dock.height),footer:rect(el.getBoundingClientRect()),
      content:[...el.querySelectorAll('a,span')].map(n=>({text:n.textContent,href:n.getAttribute('href'),...rect(n.getBoundingClientRect())}))};
    });
    await writeFile(path.join(report,`abbreviations-native-footer-${width}.json`),JSON.stringify(footerBounds,null,2));
    await nativePage.screenshot({path:path.join(report,`abbreviations-native-footer-${width}.png`),fullPage:false});
    for(const bounds of [footerBounds.footer,...footerBounds.content]){
     assert.ok(bounds.width>0&&bounds.height>0&&bounds.left>=0&&bounds.right<=footerBounds.viewport.width&&bounds.top>=0&&bounds.bottom<=footerBounds.safeBottom,
      'native attribution clipped by viewport or dock: '+JSON.stringify(footerBounds));
    }

   }catch(error){
    // Preserve actual failing pixels before the isolated browser context closes.
    try{await nativePage.screenshot({path:path.join(report,`abbreviations-native-failure-${width}.png`),fullPage:true});}catch{}
    throw error;
   }
  }
  const glossary=nativePage.getByRole('link',{name:'der.',exact:true});
  assert.equal(await glossary.getAttribute('href'),'#'+encodeURIComponent('Appendix:Glossary#derived terms'));
  const describedBy=await glossary.getAttribute('aria-describedby');assert.ok(describedBy);
  assert.equal(await nativePage.locator('#'+describedBy).textContent(),'derived terms');
  assert.equal(await nativePage.getByRole('link',{name:'lbor.',exact:true}).getAttribute('href'),'#'+encodeURIComponent('Appendix:Glossary#learned borrowing'));
  await nativePage.getByRole('button',{name:'Search',exact:true}).click();await nativePage.getByRole('searchbox').fill('Legacy format abbreviation control');
  await nativePage.getByRole('button',{name:'Open Legacy format abbreviation control',exact:true}).click();
  await nativePage.locator('#entry h1').filter({hasText:'Legacy format abbreviation control'}).waitFor();
  assert.equal(await nativePage.locator('#entry .abbreviation-explanations,#entry abbr[title]').count(),0);
  assert.equal(await nativePage.getByRole('link',{name:'control',exact:true}).getAttribute('href'),'#cat');
 }finally{await nativeContext.close();}

 if(nativeOnly){
  assert.deepEqual(errors,[]);await writeFile(path.join(report,'native-report.json'),JSON.stringify({status:'passed',scope:'native-abbreviation-only',errors},null,2));console.log('WEB_NATIVE_ABBREVIATIONS_PASS');
 }else{
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);await page.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await page.locator('#file').setInputFiles(fixture);await page.getByText(/English · 182 words/).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox').fill('cat');await page.getByRole('button',{name:'Open cat',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();assert.equal(await page.locator('details').filter({has:page.locator('summary').filter({hasText:/^Etymology$/})}).getAttribute('open'),null);
 assert.ok((await page.locator('#entry').innerText()).includes('A small animal'));
 assert.equal(await page.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://www.wiktionary.org/');
 for(const [width,height] of [[360,800],[768,1024],[1440,900]]){
  await page.setViewportSize({width,height});await page.evaluate(()=>scrollTo(0,0));
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'horizontal overflow');
  const centers=await page.locator('#dock button').evaluateAll(nodes=>nodes.map(n=>{const r=n.getBoundingClientRect();return r.x+r.width/2;}));const spacing=centers[1]-centers[0];assert.ok(centers.slice(1).every((x,i)=>Math.abs(x-centers[i]-spacing)<1));
  await page.screenshot({path:path.join(report,`reading-${width}.png`),fullPage:true});
 }
 await page.getByRole('button',{name:'Bookmark',exact:true}).click();await page.getByRole('button',{name:'Saved',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).waitFor();
 await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).waitFor();
 await page.getByRole('button',{name:'Learn',exact:true}).click();await page.getByRole('button',{name:'Reveal meaning'}).click();await page.getByRole('button',{name:'Got it',exact:true}).waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();
 for(const label of ['Remember words','Media cache']){await page.getByRole('slider',{name:label}).fill('1');await page.getByRole('slider',{name:label}).dispatchEvent('change');}
 assert.ok((await page.locator('#panel').innerText()).includes('100,000'));assert.ok((await page.locator('#panel').innerText()).includes('4.0 GB'));
 await page.getByRole('button',{name:'Dictionaries',exact:true}).click();await page.locator('#file').setInputFiles({name:'English.wikblb.xz',mimeType:'application/x-xz',buffer:xz});await page.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove English"]').length===2);
 await page.getByRole('button',{name:'Remove English',exact:true}).first().click();await page.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove English"]').length===1);
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox').fill('cat');await page.getByRole('button',{name:'Open cat',exact:true}).click();await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();await page.getByRole('button',{name:'Dictionaries',exact:true}).click();
 await page.locator('#file').setInputFiles({name:'bad.wikblb',mimeType:'application/octet-stream',buffer:Buffer.from('not a dictionary')});await page.getByRole('status').filter({hasText:'WIKBLB08'}).waitFor();
 await page.reload();await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).first().waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();assert.ok((await page.locator('#panel').innerText()).includes('4.0 GB'));

 await page.getByRole('button',{name:'Dictionaries',exact:true}).click();
 const supplemental=fileURLToPath(new URL('../tests/fixtures/supplemental.wikblb',import.meta.url));
 await page.locator('#file').setInputFiles(supplemental);await page.getByText(/supplemental · 2 words/).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();
 await page.getByRole('searchbox').fill('ANNEXE:É');await page.getByRole('button',{name:'Open Annexe:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Annexe:école'}).waitFor();
 assert.ok((await page.locator('#entry').innerText()).includes('Annexe:école'));
 await page.getByRole('button',{name:'Bookmark',exact:true}).click();
 await page.locator('[aria-label="Bookmark"][aria-pressed="true"]').waitFor();
 await page.reload();await page.getByRole('button',{name:'Saved',exact:true}).click();
 await page.getByRole('button',{name:'Open Annexe:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Annexe:école'}).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();
 await page.getByRole('searchbox').fill('APPENDIX:É');await page.getByRole('button',{name:'Open Appendix:école',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'Appendix:école'}).waitFor();
 const navigationPage=await browser.newPage();navigationPage.on('pageerror',e=>errors.push(e.message));
 const navU32=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
 const navString=s=>{const b=Buffer.from(s);return Buffer.concat([navU32(b.length),b]);};
 const navSpans=(text,target='')=>Buffer.concat([navU32(1),Buffer.from([target?1:0,0,0]),...[text,target,'','','','',''].map(navString),Buffer.from([0])]);
 const navPresentation=sections=>Buffer.concat([Buffer.from('DPR5'),navU32(0),navU32(sections.length),...sections.map(([title,anchor,fallback,text,target=''])=>Buffer.concat([
  Buffer.from([3]),navString(title),navString(anchor),navString(fallback),navU32(1),Buffer.from([0,0,0]),navSpans(text,target),Buffer.from([0]),navString(''),navString(''),Buffer.from([0]),navString(''),navString('')
 ])),navU32(0),navU32(0),navU32(0),navU32(0),navU32(0)]);
 const navPrefix='enwiktionary-20261002-',navAsset=navPrefix+createHash('sha256').update('English').digest('hex')+'.wikblb';
 const navMain=dictionaryBlob(1,[
  ['Start',navPresentation([['Links','Links','','Same entry','#Second'],['Second','Second','','Cross entry','Target#Noun_2']])],
  ['Target',navPresentation([['Noun','Noun','','First noun'],['Noun','Noun_2','','Second noun'],['Unicode','\u00e4','.C3.A4','Alias override','Alias#Noun_2'],['Empty override','Empty','','Suppress alias fragment','Alias#']])]
 ]);
 const navAliases=dictionaryBlob(8,[['1\tAlias',aliasPayload({source:'Alias',target:'Target',fragment:'\u00e4'})]]);
 await navigationPage.goto(`http://127.0.0.1:${server.address().port}`);
 await navigationPage.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await navigationPage.locator('#file').setInputFiles({name:navAsset,mimeType:'application/octet-stream',buffer:navMain});
 await navigationPage.getByText(/English · 2 words/).waitFor();
 await navigationPage.locator('#file').setInputFiles({name:navPrefix+'aliases.wikblb',mimeType:'application/octet-stream',buffer:navAliases});
 await navigationPage.getByText(/alias · 1 words/).waitFor();
 const navOpen=async title=>{await navigationPage.getByRole('button',{name:'Search',exact:true}).click();await navigationPage.getByRole('searchbox').fill(title);await navigationPage.getByRole('button',{name:'Open '+title,exact:true}).click();};
 await navOpen('Start');await navigationPage.locator('#entry #Links > summary').click();
 await navigationPage.getByRole('link',{name:'Same entry',exact:true}).click();
 assert.equal(await navigationPage.locator('#entry #Second').evaluate(el=>el.open),true);
 assert.equal(await navigationPage.evaluate(()=>document.activeElement.id),'Second');
 await navigationPage.getByRole('link',{name:'Cross entry',exact:true}).click();
 await navigationPage.locator('#entry h1').filter({hasText:/^Target$/}).waitFor();
 assert.equal(await navigationPage.locator('#entry #Noun_2').evaluate(el=>el.open),true);
 assert.equal(await navigationPage.locator('#entry #Noun').evaluate(el=>el.open),false);
 await navOpen('Alias');await navigationPage.locator('.entry-redirect').filter({hasText:'Alias to Target#\u00e4'}).waitFor();
 assert.equal(await navigationPage.locator('#entry [id="\u00e4"]').evaluate(el=>el.open),true);
 assert.equal(await navigationPage.evaluate(()=>document.activeElement.id),'\u00e4');
 await navigationPage.getByRole('link',{name:'Alias override',exact:true}).click();
 await navigationPage.waitForFunction(()=>document.activeElement.id==='Noun_2');
 assert.equal(await navigationPage.locator('#entry [id="\u00e4"]').evaluate(el=>el.open),false);
 await navigationPage.locator('#entry #Empty > summary').click();
 await navigationPage.getByRole('link',{name:'Suppress alias fragment',exact:true}).click();
 await navigationPage.waitForFunction(()=>[...document.querySelectorAll('#entry details[id]')].every(el=>!el.open));
 assert.equal(await navigationPage.locator('#entry [id="\u00e4"]').evaluate(el=>el.open),false);
 await navigationPage.getByRole('button',{name:'History',exact:true}).click();
 await navigationPage.getByRole('button',{name:'Open Alias',exact:true}).click();
 await navigationPage.waitForFunction(()=>document.activeElement.id==='\u00e4');
 await navigationPage.close();

 const aliases=await browser.newPage();aliases.on('pageerror',e=>errors.push(e.message));
 const prefix='enwiktionary-20261001-',english=dictionaryBlob(1,[['cat',presentation('English target definition')]]),german=dictionaryBlob(1,[['cat',presentation('German target definition')]],{language:'German',code:'de'});
 const aliasRaw=aliasCases(),aliasXZ=execFileSync('xz',['-1','-c'],{input:aliasRaw});
 const englishAsset=prefix+createHash('sha256').update('English').digest('hex')+'.wikblb',germanAsset=prefix+createHash('sha256').update('German').digest('hex')+'.wikblb';
 const downloadURL='https://fixtures.invalid/'+englishAsset;
 await aliases.route('https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list',route=>route.fulfill({contentType:'text/plain',body:downloadURL+'\tFixture English\t'+english.length+'\n'}));
 await aliases.route(downloadURL,route=>route.fulfill({contentType:'application/octet-stream',body:english}));
 await aliases.goto(`http://127.0.0.1:${server.address().port}`);
 await aliases.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await aliases.getByRole('button',{name:'Refresh lists',exact:true}).click();
 await aliases.getByRole('button',{name:'Download Fixture English',exact:true}).click();
 await aliases.getByText(/English · 1 words/).waitFor();
 const importAlias=async(name,buffer,label)=>{await aliases.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await aliases.getByText(label+' · en.wiktionary.org',{exact:true}).waitFor();};
 await importAlias(germanAsset,german,'German · 1 words · 0.0 MB');
 await importAlias(prefix+'aliases.wikblb.xz',aliasXZ,'alias · 8 words · 0.0 MB');
 await importAlias(prefix+'thesaurus.wikblb',dictionaryBlob(2,[['animal',presentation('Open beast','', 'beast')],['beast',presentation('Feature destination definition')]]),'thesaurus · 2 words · 0.0 MB');
 await importAlias(prefix+'supplemental.wikblb',dictionaryBlob(7,[]),'supplemental · 0 words · 0.0 MB');
 const stateFromDB=()=>aliases.evaluate(()=>new Promise((resolve,reject)=>{const r=indexedDB.open('wikidict-binary',1);r.onerror=()=>reject(r.error);r.onsuccess=()=>{const db=r.result,tx=db.transaction(['state','dictionaries']),a=tx.objectStore('state').get('learning'),b=tx.objectStore('dictionaries').getAll();tx.oncomplete=()=>{resolve({state:a.result,dictionaries:b.result.map(d=>({id:d.id,name:d.name}))});db.close();};};}));
 assert.ok((await stateFromDB()).dictionaries.some(d=>d.name===englishAsset),'download preserved canonical asset name');
 const searchAlias=async title=>{await aliases.getByRole('button',{name:'Search',exact:true}).click();await aliases.getByRole('searchbox').fill(title);await aliases.getByRole('button',{name:'Open '+title,exact:true}).first().waitFor();};
 const pickLanguage=(title,language)=>aliases.getByRole('button',{name:'Open '+title,exact:true}).filter({has:aliases.locator('small').filter({hasText:new RegExp('^'+language+'(?: · en\\.wiktionary\\.org)?$')})});
 await searchAlias('Cats');assert.equal(await aliases.getByRole('button',{name:'Open Cats',exact:true}).count(),2);
 await pickLanguage('Cats','German').click();await aliases.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();
 assert.ok((await aliases.locator('#entry').innerText()).includes('German target definition'));assert.ok((await aliases.locator('.entry-redirect').innerText()).includes('Cats to cat'));
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/wiki/cat');
 await aliases.getByRole('button',{name:'Bookmark',exact:true}).click();await aliases.locator('[aria-label="Bookmark"][aria-pressed="true"]').waitFor();
 const saved=(await stateFromDB()).state.saved[0];assert.equal(saved.raw_key,'1\tCats');assert.notEqual(saved.context,saved.dictionary);
 await aliases.reload();await aliases.getByRole('button',{name:'Saved',exact:true}).click();await pickLanguage('Cats','German').click();await aliases.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();assert.ok((await aliases.locator('#entry').innerText()).includes('German target definition'));
 await searchAlias('Loop A');await pickLanguage('Loop A','English').click();await aliases.locator('#entry h1').filter({hasText:/^Loop B$/}).waitFor();
 assert.ok((await aliases.locator('.entry-redirect').innerText()).includes('Loop A to Loop B#Incoming'));assert.equal(await aliases.locator('.entry-alias').innerText(),'Redirect to cat#Outgoing');
 assert.ok((await aliases.locator('#entry').innerText()).includes('Retained alias preamble'));
 await aliases.setViewportSize({width:360,height:800});assert.ok(await aliases.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'alias horizontal overflow');await aliases.screenshot({path:path.join(report,'alias-one-hop-360.png'),fullPage:true});
 await searchAlias('Self');await pickLanguage('Self','English').click();await aliases.locator('#entry h1').filter({hasText:/^Self$/}).waitFor();
 await aliases.evaluate(()=>{window.voiceLookups=0;speechSynthesis.getVoices=()=>{window.voiceLookups++;return [];};});
 await aliases.getByRole('button',{name:'Pronounce word offline',exact:true}).click();await aliases.getByRole('status').filter({hasText:'No language is identified for offline pronunciation.'}).waitFor();assert.equal(await aliases.evaluate(()=>window.voiceLookups),0);
 await searchAlias('Missing');await pickLanguage('Missing','English').click();await aliases.locator('#entry h1').filter({hasText:/^Missing$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to not installed');
 await searchAlias('To feature');await pickLanguage('To feature','English').click();await aliases.locator('#entry h1').filter({hasText:/^animal$/}).waitFor();
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/wiki/Thesaurus%3Aanimal');
 await aliases.getByRole('link',{name:'Open beast',exact:true}).click();await aliases.locator('#entry h1').filter({hasText:/^beast$/}).waitFor();assert.ok((await aliases.locator('#entry').innerText()).includes('Feature destination definition'));
 assert.equal(await aliases.getByRole('link',{name:'Wiktionary contributors',exact:true}).getAttribute('href'),'https://en.wiktionary.org/');
 await searchAlias('To main');await pickLanguage('To main','thesaurus').click();await aliases.locator('#entry h1').filter({hasText:/^Thesaurus:To main$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to cat');
 await searchAlias('Annexe:École');await pickLanguage('Annexe:École','supplemental').click();await aliases.locator('#entry h1').filter({hasText:/^Annexe:École$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to Annexe:école');
 await aliases.getByRole('button',{name:'Settings',exact:true}).click();await aliases.getByRole('button',{name:'Dictionaries',exact:true}).click();
 await aliases.locator('#file').setInputFiles({name:'aliases.wikblb',mimeType:'application/octet-stream',buffer:aliasRaw});await aliases.waitForFunction(()=>document.querySelectorAll('[aria-label="Remove alias"]').length===2);
 await searchAlias('Cats');await pickLanguage('Cats','language').click();await aliases.locator('#entry h1').filter({hasText:/^Cats$/}).waitFor();assert.equal(await aliases.locator('.entry-redirect').innerText(),'Redirect to cat');
 await aliases.getByRole('button',{name:'Settings',exact:true}).click();await aliases.getByRole('button',{name:'Dictionaries',exact:true}).click();
 const badAlias=dictionaryBlob(8,[['1\tCats',aliasPayload({sourceNamespace:10})]]),countBefore=(await stateFromDB()).dictionaries.length;
 for(const buffer of [badAlias,execFileSync('xz',['-1','-c'],{input:badAlias})]){await aliases.locator('#file').setInputFiles({name:'bad-alias.wikblb',mimeType:'application/octet-stream',buffer});await aliases.getByRole('status').filter({hasText:'Invalid compiled alias'}).waitFor();}
 assert.equal((await stateFromDB()).dictionaries.length,countBefore,'malformed imports did not persist');
 for(const [name,buffer] of [[prefix+'aliases.wikblb',english],[prefix+'0'.repeat(64)+'.wikblb',english],[prefix+createHash('sha256').update('English').digest('hex')+'.wikblb',aliasRaw]]){
  await aliases.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await aliases.getByRole('status').filter({hasText:'Dictionary filename does not match its compiled header'}).waitFor();
 }
 assert.equal((await stateFromDB()).dictionaries.length,countBefore,'misnamed canonical imports did not persist');
 const mediaPage=await browser.newPage();mediaPage.on('pageerror',e=>errors.push(e.message));const mediaRequests=[];let mediaDownloads=0;
 const mediaURL='https://upload.wikimedia.org/fixture/shared.png';
 await mediaPage.route('https://commons.wikimedia.org/w/api.php*',route=>{mediaRequests.push('commons.wikimedia.org');return route.fulfill({json:{query:{pages:[{}]}}});});
 await mediaPage.route('https://*.wiktionary.org/w/api.php*',route=>{mediaRequests.push(new URL(route.request().url()).hostname);return route.fulfill({json:{query:{pages:[{imageinfo:[{url:mediaURL}]}]}}});});
 await mediaPage.route(mediaURL,route=>{mediaDownloads++;return route.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=','base64')});});
 await mediaPage.goto(`http://127.0.0.1:${server.address().port}`);await mediaPage.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 for(const [i,wiki,title] of [[1,'arwiktionary','Arabic media'],[2,'frwiktionary','French media'],[3,null,'Unknown media']]){
  const name=wiki?wiki+'-20261001-'+createHash('sha256').update('English').digest('hex')+'.wikblb':'Unknown.wikblb';
  const buffer=dictionaryBlob(1,[[title,presentation('Media source fixture','','',[{file:'Shared.png',kind:'image',caption:'Shared fixture'}])],['Shared title',presentation('Edition selection fixture')]],{code:wiki?'en':'und'});
  await mediaPage.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer});await mediaPage.waitForFunction(n=>document.querySelectorAll('[aria-label="Remove English"]').length===n,i);
 }
 await mediaPage.getByText('English · 2 words · 0.0 MB · ar.wiktionary.org',{exact:true}).waitFor();await mediaPage.getByText('English · 2 words · 0.0 MB · fr.wiktionary.org',{exact:true}).waitFor();
 await mediaPage.getByRole('button',{name:'Search',exact:true}).click();await mediaPage.getByRole('searchbox').fill('Shared title');await mediaPage.getByRole('button',{name:'Open Shared title',exact:true}).first().waitFor();
 assert.deepEqual((await mediaPage.getByRole('button',{name:'Open Shared title',exact:true}).locator('small').allTextContents()).sort(),['English','English · ar.wiktionary.org','English · fr.wiktionary.org']);
 await mediaPage.getByRole('button',{name:'Settings',exact:true}).click();await mediaPage.getByRole('switch',{name:'Load images online',exact:true}).check();
 for(const [title,host] of [['Arabic media','ar.wiktionary.org'],['French media','fr.wiktionary.org'],['Unknown media',null]]){
  await mediaPage.getByRole('button',{name:'Search',exact:true}).click();await mediaPage.getByRole('searchbox').fill(title);await mediaPage.getByRole('button',{name:'Open '+title,exact:true}).click();await mediaPage.locator('#entry h1').filter({hasText:title}).waitFor();await mediaPage.getByText('Images & sound',{exact:true}).click();await mediaPage.getByText('Shared fixture',{exact:true}).click();
  if(host){await mediaPage.getByRole('link',{name:'Source & licence',exact:true}).waitFor();assert.equal(await mediaPage.getByRole('link',{name:'Source & licence',exact:true}).getAttribute('href'),'https://'+host+'/wiki/File:Shared.png');}
  else await mediaPage.getByText('Media unavailable',{exact:true}).waitFor();
 }
 assert.deepEqual(mediaRequests,['commons.wikimedia.org','ar.wiktionary.org','commons.wikimedia.org','fr.wiktionary.org','commons.wikimedia.org']);assert.equal(mediaDownloads,2);
 assert.deepEqual(await mediaPage.evaluate(async()=>(await(await caches.open('wikidict-media-v1')).keys()).map(r=>new URL(r.url).hostname).sort()),['ar.wiktionary.org','fr.wiktionary.org']);
 await mediaPage.evaluate(()=>{window.voiceLookups=0;speechSynthesis.getVoices=()=>{window.voiceLookups++;return [];};});await mediaPage.getByRole('button',{name:'Pronounce word offline',exact:true}).click();await mediaPage.getByRole('status').filter({hasText:'No language is identified for offline pronunciation.'}).waitFor();assert.equal(await mediaPage.evaluate(()=>window.voiceLookups),0,'und does not select an unrelated voice');
 const delivery=await browser.newPage();delivery.on('pageerror',e=>errors.push(e.message));
 await delivery.route('https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list',route=>route.fulfill({contentType:'text/plain',body:downloadURL+'\tFixture English\t'+english.length+'\n'}));await delivery.route(downloadURL,route=>route.abort('failed'));
 await delivery.goto(`http://127.0.0.1:${server.address().port}`);await delivery.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 assert.equal(await delivery.getByRole('link',{name:'Open downloads in browser',exact:true}).getAttribute('href'),'https://github.com/SmallThingz/wikidict/releases/latest');
 await delivery.getByRole('button',{name:'Refresh lists',exact:true}).click();await delivery.getByRole('button',{name:'Download Fixture English',exact:true}).click();await delivery.getByRole('status').filter({hasText:'Use the browser download, then import the file.'}).waitFor();
 const fallback=delivery.getByRole('link',{name:'Download Fixture English in browser',exact:true});assert.equal(await fallback.getAttribute('href'),downloadURL);assert.equal(await fallback.getAttribute('rel'),'noopener noreferrer');
 await delivery.locator('#file').setInputFiles({name:englishAsset,mimeType:'application/octet-stream',buffer:english});await delivery.getByText(/English · 1 words/).waitFor();
 await delivery.getByRole('button',{name:'Search',exact:true}).click();await delivery.getByRole('searchbox').fill('cat');await delivery.getByRole('button',{name:'Open cat',exact:true}).click();await delivery.locator('#entry h1').filter({hasText:/^cat$/}).waitFor();assert.ok((await delivery.locator('#entry').innerText()).includes('English target definition'));
 assert.deepEqual(errors,[]);await writeFile(path.join(report,'report.json'),JSON.stringify({status:'passed',rawBytes:raw.length,xzBytes:xz.length,aliasCases:8,aliasRawAndXZ:true,savedAliasContext:true,mediaRequests,mediaDownloads,errors},null,2));console.log('WEB_BINARY_PARITY_AND_ALIAS_PASS');
 }
}finally{await browser.close();server.close();}
