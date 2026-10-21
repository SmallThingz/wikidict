import {chromium} from 'playwright';
import {build} from 'esbuild';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import path from 'node:path';
const report=process.env.WIKIDICT_POEM_REPORT;
assert.ok(report&&path.isAbsolute(report),'Use a fresh owned absolute report directory');
await mkdir(report,{recursive:false});
const bundle=await build({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],bundle:true,format:'iife',globalName:'Renderer',write:false});
const css=await readFile(new URL('./style.css',import.meta.url),'utf8');
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[],frames=[];
try{
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.setContent('<main></main>');await page.addStyleTag({content:css});await page.addScriptTag({content:bundle.outputFiles[0].text});
 const observed=await page.evaluate(()=>{
  const mark='wikidict-poem',indent=mark+' wikidict-poem-indent-2';
  const text=(text,classes='',extra={})=>({kind:'text',text,classes,...extra});
  const br=classes=>({kind:'line_break',text:'',trail:'',classes});
  const paragraph=spans=>({kind:'paragraph',spans});
  const blocks=[
   paragraph([text('Lead'),br(''),text('Styled ',indent,{bold:true}),text('cat',indent,{kind:'link',target:'cat#Noun'}),br(indent),br(mark),text('\u00a0\u00a0End',mark),br(mark)]),
   paragraph([text('Raw\nAfter',indent)]),
   paragraph([text('يمين طويل يلتف مع الكلمات العربية',indent+' wikidict-poem-dir-rtl',{direction:'ltr'})]),
   paragraph([text('Normal  ', '',{bold:true}),text(' link', '',{kind:'link',target:'normal target',trail:'  tail'}),br(''),text('next\u00a0\u00a0part')]),
   {kind:'preformatted',spans:[text('  literal\t  code\n next',indent,{code:true})]},
   paragraph([text('Inline  code', '',{code:true})]),
   paragraph([text('Invalid',mark+' wikidict-poem-indent-03 wikidict-poem-dir-rtl')]),
   paragraph([text('Duplicate',indent+' wikidict-poem-indent-2')]),
   paragraph([text('Not poem','not-wikidict-poem wikidict-poem-indent-2'),br(''),br(''),text('ordinary')]),
   paragraph([br(mark),br(mark)]),
   {kind:'table',spans:[],table:{caption:[text('Caption',indent)],rows:[{cells:[{header:false,colspan:1,rowspan:1,spans:[text('Cell',indent,{kind:'link',target:'cell target'}),br(indent),br(mark),text('Last',mark)]}]}]}}
  ];
  const entry={title:'Compiled Poem lines',language:'English',sections:[{title:'Poem controls',blocks}]};
  const original=JSON.stringify(entry);window.poemLinks=[];
  document.querySelector('main').append(Renderer.renderEntry(entry,t=>window.poemLinks.push(t),{collapseOtherSections:false,collapseDetails:false}));
  const blocksDOM=[...document.querySelectorAll('.block.paragraph')];
  const first=blocksDOM[0],lines=[...first.querySelectorAll('.poem-line')];
  return {unchanged:original===JSON.stringify(entry),firstLines:lines.map(x=>x.textContent),margins:lines.map(x=>x.style.marginInlineStart),styledVisible:lines[1].innerText,bold:first.querySelector('strong').textContent,link:first.querySelector('a').getAttribute('href'),rawLines:[...blocksDOM[1].querySelectorAll('.poem-line')].map(x=>({text:x.textContent,margin:x.style.marginInlineStart})),rtl:{direction:blocksDOM[2].querySelector('.poem-line').dir,margin:blocksDOM[2].querySelector('.poem-line').style.marginInlineStart},ordinary:{text:blocksDOM[3].innerText,poemLines:blocksDOM[3].querySelectorAll('.poem-line').length,breaks:blocksDOM[3].querySelectorAll('br').length},pre:{text:document.querySelector('pre').textContent,space:getComputedStyle(document.querySelector('pre')).whiteSpace,poemLines:document.querySelector('pre .poem-line')!==null},inlineCodeSpace:getComputedStyle(blocksDOM[4].querySelector('code')).whiteSpace,invalid:{margin:blocksDOM[5].querySelector('.poem-line').style.marginInlineStart,direction:blocksDOM[5].querySelector('.poem-line').dir},duplicateMargin:blocksDOM[6].querySelector('.poem-line').style.marginInlineStart,unmarked:{lines:blocksDOM[7].querySelectorAll('.poem-line').length,breaks:blocksDOM[7].querySelectorAll('br').length},onlyBlankLines:blocksDOM[8].querySelectorAll('.poem-line').length,table:{captionLines:document.querySelectorAll('caption .poem-line').length,cellLines:[...document.querySelectorAll('td .poem-line')].map(x=>x.textContent),link:document.querySelector('td a').getAttribute('href')}};
 });
 assert.equal(observed.unchanged,true);assert.deepEqual(observed.firstLines,['Lead','Styled cat','','\u00a0\u00a0End','']);
 assert.deepEqual(observed.margins,['','2em','','','']);assert.equal(observed.styledVisible,'Styled cat');assert.equal(observed.bold,'Styled ');assert.equal(observed.link,'#cat%23Noun');
 assert.deepEqual(observed.rawLines,[{text:'Raw',margin:'2em'},{text:'After',margin:''}]);
 assert.deepEqual(observed.rtl,{direction:'rtl',margin:'2em'});
 assert.deepEqual(observed.ordinary,{text:'Normal link tail\nnext\u00a0\u00a0part',poemLines:0,breaks:1});
 assert.deepEqual(observed.pre,{text:'  literal\t  code\n next',space:'pre',poemLines:false});assert.equal(observed.inlineCodeSpace,'normal');
 assert.deepEqual(observed.invalid,{margin:'',direction:'rtl'});assert.equal(observed.duplicateMargin,'');
 assert.deepEqual(observed.unmarked,{lines:0,breaks:1});assert.equal(observed.onlyBlankLines,3);
 assert.deepEqual(observed.table,{captionLines:1,cellLines:['Cell','','Last'],link:'#cell%20target'});
 const link=page.getByRole('link',{name:'cat',exact:true});await link.focus();assert.equal(await link.evaluate(el=>document.activeElement===el),true);await page.keyboard.press('Enter');
 assert.deepEqual(await page.evaluate(()=>window.poemLinks),['cat#Noun']);
 const first=page.locator('.block.paragraph').first();const accessible=await first.ariaSnapshot();assert.ok(accessible.includes('link "cat"'));assert.equal(accessible.split('Styled').length-1,1);
 for(const width of [360,768]){
  await page.setViewportSize({width,height:640});
  const layout=await page.evaluate(()=>{
   const first=document.querySelector('.block.paragraph'),lines=[...first.querySelectorAll('.poem-line')],body=first.querySelector('.body').getBoundingClientRect(),indented=lines[1].getBoundingClientRect(),font=parseFloat(getComputedStyle(lines[1]).fontSize);
   return {lines:lines.map(x=>{const r=x.getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:r.height,left:r.left,right:r.right};}),indent:indented.left-body.left,em:font,bodyLeft:body.left,bodyRight:body.right,rtl:(()=>{const block=document.querySelectorAll('.block.paragraph')[2],body=block.querySelector('.body').getBoundingClientRect(),line=block.querySelector('.poem-line'),rect=line.getBoundingClientRect(),style=getComputedStyle(line),child=line.querySelector('[dir=ltr]');return {rightInset:body.right-rect.right,bodyRight:body.right,containerRight:block.getBoundingClientRect().right,em:parseFloat(style.fontSize),height:rect.height,lineHeight:parseFloat(style.lineHeight),childIsolate:getComputedStyle(child).unicodeBidi};})(),focusableLines:first.querySelectorAll('.poem-line[tabindex],.poem-line[role]').length};
  });
  assert.ok(Math.abs(layout.indent-2*layout.em)<.1);assert.equal(layout.focusableLines,0);assert.ok(Math.abs(layout.rtl.rightInset-2*layout.rtl.em)<.1);assert.ok(Math.abs(layout.rtl.bodyRight-layout.rtl.containerRight)<.1);assert.equal(layout.rtl.childIsolate,'isolate');if(width===360)assert.ok(layout.rtl.height>layout.rtl.lineHeight);
  assert.ok(layout.lines.every((x,i)=>x.height>0&&x.left>=0&&x.right<=width+.1&&(i===0||x.top>=layout.lines[i-1].bottom-.1)));
  const file=`poem-${width}.png`;await page.screenshot({path:path.join(report,file),fullPage:true});frames.push(file);
 }
 assert.deepEqual(errors,[]);
 await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,scope:'Compiled typed Poem line/stanza/terminal/indent/style/action preservation with ordinary, pre/code/NBSP and table controls. Synthetic fixture; no wikitext parsing, corpus import or full browser suite.',observed,accessible,frames,errors},null,2)+'\n');
 console.log('WEB_POEM_PASS');
}finally{await browser.close();}
