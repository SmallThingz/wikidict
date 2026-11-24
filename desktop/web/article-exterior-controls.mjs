import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {buildIndex,decode} from './blob.js';
import {openSource} from './xz.js';
import assert from 'node:assert/strict';

// The caller passes the complete ordinary HU entry when available. The mixed
// controlled example separately stresses placement and scroll ownership.
export async function verifyClippedGeometry(page,renderer,css,genuine){
  await page.route('**/*',route=>route.abort());
  await page.setContent('<main id="host"></main>');
  await page.addStyleTag({content:css});
  await page.addScriptTag({content:renderer});
  await page.evaluate(entry=>{
    const text='Tooltip time to peak concentrations';
    const length=value=>({unit:'px',value});
    const clip=(dir,owner,literal)=>({kind:'text',text:'',target:'',trail:'',clipped_absolute:{
      static_parent_direction:dir,...(owner?{containing_block:owner}:{}),width:length(1),height:length(1),
      margin:Object.fromEntries(['top','right','bottom','left'].map(side=>[side,{length:length(-1)}])),
      children:[{kind:'text',text:literal}]}});
    const host=document.getElementById('host');
    window.renderHU=(original=false)=>{
      const sample={title:'Clipped geometry controls',sections:[{level:2,title:'Layout',anchor:'layout',blocks:[{
        kind:'table',spans:[],table:{geometry:{width:{unit:'px',value:900}},rows:[{cells:[
          {header:false,colspan:1,rowspan:1,spans:[{kind:'link',target:'source target',text:'Tmax'},
            clip('ltr','article_exterior',text),{kind:'text',text:')'},
            clip('ltr',null,'Legacy initial body'),{kind:'text',text:' end'}]}]}]}}]}]};
      host.style.cssText='width:300px;margin:24px 0 0 32px;padding:0';
      host.replaceChildren(Renderer.renderEntry(original?entry:sample,(...a)=>window.activated=a,{collapseOtherSections:false}));
      for(const detail of host.querySelectorAll('details'))detail.open=true;
      return new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    };
  },genuine??null);
  await page.evaluate(()=>window.renderHU(false));
  const observed=await page.evaluate(()=>{
    const initial=document.querySelector('[data-clipped-owner="initial"]'),semantic=document.querySelector('[data-clipped-owner="article_exterior"]');
    const border=document.querySelector('.compiled-clipped-border'),origin=document.querySelector('.compiled-clipped-origin');
    const output=el=>{const {x,y,width,height}=el.getBoundingClientRect();return {x,y,width,height};};
    window.clips=()=>({border:output(border),origin:output(origin),semantic:output(semantic),initial:output(initial)});
    window.advance=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const range=document.createRange();range.selectNodeContents(semantic);
    const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
    return {selected:selection.toString(),parent:border.parentElement.className,semanticText:semantic.textContent,
      initialParent:initial.offsetParent?.tagName,initialClip:getComputedStyle(initial).clip,cellText:semantic.closest('td').textContent,
      borderVisible:document.elementsFromPoint(border.getBoundingClientRect().x,border.getBoundingClientRect().y).includes(border),rects:window.clips()};
  });
  const near=(a,b,msg)=>assert.ok(Math.abs(a-b)<=.125,msg+' '+a+' '+b);
  assert.equal(observed.parent,'compiled-clipped-plane');
  assert.equal(observed.selected,'Tooltip time to peak concentrations',JSON.stringify(observed));
  assert.equal(observed.cellText,'TmaxTooltip time to peak concentrations)Legacy initial body end');
  assert.equal(observed.initialParent,'BODY');
  assert.equal(observed.borderVisible,false);
  assert.equal(observed.rects.border.width,1);assert.equal(observed.rects.border.height,1);
  near(observed.rects.border.x,observed.rects.origin.x-1,'static exterior margin x');
  near(observed.rects.border.y,observed.rects.origin.y-1,'static exterior margin y');
  const after=await page.evaluate(async()=>{
    const pane=document.querySelector('.table-scroll');pane.scrollLeft=100;
    await window.advance();return {pan:pane.scrollLeft,...window.clips()};
  });
  assert.equal(after.pan,100);
  near(after.border.x,observed.rects.border.x,'exterior horizontal pan');
  near(after.origin.x,observed.rects.origin.x-100,'ordered source marker pans');
  near(after.initial.x,observed.rects.initial.x,'legacy initial geometry unaffected');
  const moved=await page.evaluate(async()=>{
    const host=document.getElementById('host');host.style.marginLeft='62px';host.style.width='270px';
    await window.advance();return window.clips();
  });
  near(moved.border.x,after.border.x+30,'article origin follows relocation');
  await page.evaluate(async()=>{document.querySelector('.table-scroll').scrollLeft=0;await window.advance();});
  await page.getByRole('link',{name:'Tmax',exact:true}).click();
  assert.equal((await page.evaluate(()=>window.activated))[0],'source target');
  const cdp=await page.context().newCDPSession(page);
  try{
    const tree=await cdp.send('Accessibility.getFullAXTree');
    assert.ok(tree.nodes.some(n=>!n.ignored&&n.name?.value==='Tooltip time to peak concentrations'));
  }finally{await cdp.detach();}
  let original=null;
  if(genuine){
    await page.evaluate(()=>window.renderHU(true));
    const actual=page.locator('[data-clipped-owner="article_exterior"]').filter({hasText:'Tooltip time to peak concentrations'});
    assert.equal(await actual.count(),1);
    const fields=await actual.evaluate(el=>({text:el.textContent,link:!!el.closest('a'),parentText:el.closest('td,th')?.textContent||'',border:document.querySelector('.compiled-clipped-border').getBoundingClientRect().width}));
    assert.equal(fields.text,'Tooltip time to peak concentrations');assert.equal(fields.link,false);
    assert.ok(fields.parentText.includes('Tooltip time to peak concentrations)'));
    assert.equal(fields.border,1);
    original=await actual.evaluate(async el=>{
      const cell=el.closest('td,th'),scroller=cell.closest('.table-scroll');
      const carrier=el.closest('.compiled-clipped-static'),origin=carrier.querySelector('.compiled-clipped-origin');
      const owners=[...document.querySelectorAll('.compiled-clipped-static')];
      const border=document.querySelectorAll('.compiled-clipped-border')[owners.indexOf(carrier)];
      const point=node=>{const {x,y,width,height}=node.getBoundingClientRect();return {x,y,width,height};};
      const snapshot=()=>({source:point(origin),box:point(border)});
      const host=document.getElementById('host');
      if(scroller.scrollWidth===scroller.clientWidth){host.style.width='160px';await window.advance();}
      const before=snapshot();scroller.scrollLeft=100;await window.advance();
      const pan=scroller.scrollLeft,after=snapshot();host.style.marginLeft='62px';await window.advance();const moved=snapshot();
      scroller.scrollLeft=0;await window.advance();
      const links=[...cell.querySelectorAll('a')].filter(n=>n.hash==='#time%20to%20peak%20concentrations'&&(n.compareDocumentPosition(el)&Node.DOCUMENT_POSITION_FOLLOWING));
      const targetText=links.map(n=>n.textContent).join('');
      const linkedSubscript=links.some(n=>n.querySelector('sub')?.textContent==='max');
      const selected=document.createRange();selected.selectNodeContents(el);
      const selection=window.getSelection();selection.removeAllRanges();selection.addRange(selected);
      const selectedText=selection.toString();
      const actions=links.map(link=>{window.activated=null;link.click();return window.activated?.[0];});
      return {before,after,moved,pan,selectedText,targetText,linkedSubscript,actions,hit:document.elementsFromPoint(before.box.x,before.box.y).includes(border)};
    });
    assert.ok(original.pan>0,'The original table must pan in a narrow viewport');
    near(original.before.box.width,1,'Original clipped width');near(original.before.box.height,1,'Original clipped height');
    near(original.after.box.x,original.before.box.x,'Original article owns border independently of the table');
    near(original.after.source.x,original.before.source.x-original.pan,'Original inline static position tracks table scroll');
    near(original.moved.box.x,original.before.box.x+30,'Original article moves with its viewport');
    assert.equal(original.selectedText,'Tooltip time to peak concentrations');assert.equal(original.hit,false);assert.equal(original.targetText,'Tmax');assert.ok(original.linkedSubscript);
    assert.ok(original.actions.length&&original.actions.every(target=>target==='time to peak concentrations'));
    const session=await page.context().newCDPSession(page);
    try{const {nodes}=await session.send('Accessibility.getFullAXTree');assert.ok(nodes.some(n=>!n.ignored&&n.name?.value===original.selectedText));}
    finally{await session.detach();}
  }
  return {observed,after,moved,original};
}

import {createHash} from 'node:crypto';

// Exercise the packaged reader against the original normal Writer member.
// The separate mixed control shares its native projection, direction and scrolling APIs.
export async function readArticleExterior(asset=new URL('../../android/app/src/androidTest/assets/hu-klavulansav/article-exterior.wikblb.xz',import.meta.url)){
  const source=await openSource(new Blob([await readFile(asset)]));
  const {rows,metadata}=await buildIndex(source),row=rows.find(record=>record.title==='klavulánsav');
  assert.ok(row,'Missing original Hungarian entry');
  const payload=await source.read(row.offset,row.length);
  assert.equal(row.offset,39);assert.equal(row.length,28150);
  assert.equal(createHash('sha256').update(payload).digest('hex'),'0224b0ff05d849a36883499aceb2286745f6670d4cf1e9094dcd8fa4460f5aed');
  // The matched Writer emitted one clipped occurrence. Mutate only that flag.
  assert.equal(payload[5996],5);
  for(const invalid of [0,3,4,7,8,9,0x81,0xff]){
    const mutation=Uint8Array.from(payload);mutation[5996]=invalid;
    assert.throws(()=>decode(mutation,{}),/Invalid clipped static direction or containing block/);
  }
  const entry=decode(payload,{...metadata,title:row.title,source_edition:'huwiktionary'});
  return entry;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  const {chromium}=await import('playwright'),{build}=await import('esbuild');
  const entry=await readArticleExterior();
  const built=await build({entryPoints:[new URL('renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
  const css=await readFile(new URL('style.css',import.meta.url),'utf8');
  const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
  try{const page=await browser.newPage();await verifyClippedGeometry(page,built.outputFiles[0].text,css,entry);}
  finally{await browser.close();}
}
