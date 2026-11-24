import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {basename} from 'node:path';
import {build} from 'esbuild';
import {americaFixture,oracle,oracleSha,orderedActions,sha} from './source-anchor-fixtures.mjs';

const smokeNames=['app.js','import-worker.js','source-anchor-browser-probe.js'];

export async function buildSourceAnchorBrowser(){
  const work=fileURLToPath(new URL('./',import.meta.url));
  const {outputFiles}=await build({absWorkingDir:work,entryPoints:smokeNames,bundle:true,
    format:'esm',splitting:true,write:false,platform:'browser',outdir:work,logLevel:'error'});
  const files=Object.fromEntries(outputFiles.map(file=>[basename(file.path),file.contents]));
  for(const name of smokeNames)assert.ok(files[name]);
  assert.ok(Object.keys(files).some(name=>/^chunk-.*\.js$/.test(name)));
  return files;
}

function recordLookups(){
  window.s4AmericaExact=[];
  const seen=new WeakSet(),post=Worker.prototype.postMessage;
  Worker.prototype.postMessage=function(request,...rest){
    if(request.type==='exact'){
      if(!seen.has(this)){
        seen.add(this);
        this.addEventListener('message',({data})=>{
          const row=window.s4AmericaExact.find(item=>item.id===data.id);
          if(row)row.reply={value:data.value,error:data.error};
        });
      }
      window.s4AmericaExact.push({id:request.id,title:request.args.title});
    }
    return post.call(this,request,...rest);
  };
}

async function reveal(page,id){
  return page.evaluate(async fragment=>{
    const {revealFragment}=await import('/source-anchor-browser-probe.js');
    return revealFragment(document.querySelector('#entry'),fragment);
  },id);
}

async function describeTarget(target,definition){
  return target.evaluate((el,isDefinition)=>{
    const own=el.querySelector(isDefinition?':scope > .definition > .body':':scope > .body');
    const box=own.getBoundingClientRect(), ancestors=[];
    for(let parent=el.parentElement;parent;parent=parent.parentElement){
      if(parent.tagName==='DETAILS')ancestors.push(parent.open);
    }
    return {tag:el.tagName,role:el.getAttribute('role'),text:own.innerText.trim(),
      focused:document.activeElement===el,tabIndex:el.tabIndex,ancestors,
      rect:{x:box.x,y:box.y,width:box.width,height:box.height},
      viewport:{width:innerWidth,height:innerHeight}};
  },definition);
}

async function collectWidth(card){
  await card.scrollIntoViewIfNeeded();
  return card.evaluate(el=>{
    const css=getComputedStyle(el),rect=el.getBoundingClientRect();
    const rule=el.querySelector(':scope > style').sheet.cssRules[0];
    return {authored:rule.style.width,max:css.maxWidth,overflow:css.overflow,box:css.boxSizing,
      width:rect.width,parent:el.parentElement.getBoundingClientRect().width,
      children:el.querySelectorAll(':scope > .compiled-container').length};
  });
}

export async function checkAmericaSourceAnchors(page,context,data,api,branch){
  const {origin,start,fileImport,library,openRead,output}=api;
  const member=await americaFixture(branch);
  const candidate=branch==='candidate';
  Object.assign(data,{oracle:oracleSha,member:member.file_sha256,branch, widths:[],jumps:[]});
  await context.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
  await context.addInitScript(recordLookups);
  await start(page);
  await fileImport(page,member);
  await library(page,'Енглески · 1 words · 0.0 MB · sr.wiktionary.org');
  await openRead(page,'America','America','Енглески · sr.wiktionary.org',true);
  const entry=page.locator('#entry');
  const card=entry.locator('.compiled-container').filter({hasText:'lbor.'}).first();
  await card.waitFor({state:'attached'});
  for(const detail of (await entry.locator('details').all()).reverse()){
    if(await detail.evaluate(el=>!el.open&&el.querySelector('.compiled-container')))
      await detail.locator(':scope > summary').click();
  }
  data.headings=await entry.locator('h1,h2,h3,h4,h5,h6,[role=heading]').evaluateAll(
    nodes=>nodes.map(el=>[el.tagName,el.textContent,el.id]));
  const owners=Object.entries(oracle.owners);
  const translations=entry.locator('[id="Translations-Q30"]').locator('xpath=ancestor::details[1]');
  if(candidate){
    assert.equal(await translations.count(),1);
    if(await translations.evaluate(el=>el.open))await translations.locator(':scope > summary').click();
    assert.equal(await translations.evaluate(el=>el.open),false);
  }
  for(const width of [390,1000]){
    await page.setViewportSize({width,height:800});
    const measure=await collectWidth(card);
    assert.deepEqual([measure.authored,measure.max,measure.overflow,measure.box,measure.children],
      ['max-content','100%','hidden','border-box',2]);
    assert.ok(measure.width>0&&measure.width<=measure.parent+1);
    const file=output+'/sr-america-'+branch+'-clip-'+width+'.png';
    data.widths.push({width,measure,file,png:sha(await card.screenshot({path:file,animations:'disabled'}))});
    for(const [id,owner] of owners){
      const target=entry.locator('[id='+JSON.stringify(id)+']');
      assert.equal(await target.count(),candidate?1:0,id);
      assert.equal(await reveal(page,id),candidate,id);
      if(!candidate){data.jumps.push({id,width,found:false});continue;}
      const definition=owner.kind==='definition',jump=await describeTarget(target,definition);
      const row={id,width,path:owner.path,jump};
      data.jumps.push(row);
      assert.equal(jump.tag,definition?'LI':'DIV');
      assert.equal(jump.text,owner.visible);
      assert.equal(jump.role,null);
      assert.equal(jump.focused,true);
      assert.equal(jump.tabIndex,-1);
      assert.ok(jump.ancestors.length&&jump.ancestors.every(Boolean));
      assert.ok(jump.rect.width>0&&jump.rect.height>0&&jump.rect.y>=0&&jump.rect.y+jump.rect.height<=jump.viewport.height);
      const ax=await target.ariaSnapshot();
      row.ax=ax;
      assert.doesNotMatch(ax,/^\s*- heading\b/);
      if(definition)assert.match(ax,/^\s*- listitem\b/);
      const own=target.locator(definition?':scope > .definition > .body':':scope > .body');
      const action=orderedActions.find(item=>JSON.stringify(item.path.slice(0,-2))===JSON.stringify(owner.path));
      assert.ok(action&&action.target===owner.outgoing&&action.target_fragment===null);
      const link=own.getByRole('link',{name:action.text,exact:true});
      assert.equal(await own.getByRole('link').count(),1);
      assert.equal(await link.getAttribute('href'),'#'+encodeURIComponent(owner.outgoing));
      const label=id.startsWith('Translations-')?id:'definition-'+id.split(':_')[1];
      const file=output+'/sr-america-owner-'+width+'-'+label+'.png';
      const {x,y,width:ownerWidth,height}=jump.rect;
      row.pixels={file,sha256:sha(await page.screenshot({path:file,
        clip:{x:Math.max(0,Math.floor(x)),y:Math.floor(y),width:Math.ceil(ownerWidth),height:Math.ceil(height)}}))};
      await page.keyboard.press('Tab');
      assert.equal(await link.evaluate(el=>el===document.activeElement),true);
      const prior=await page.evaluate(()=>window.s4AmericaExact.length);
      await page.keyboard.press('Enter');
      await page.waitForFunction(index=>window.s4AmericaExact[index]?.reply!==undefined,prior);
      await page.getByText('Word is not installed in this dictionary.',{exact:true}).waitFor();
      const dispatches=await page.evaluate(index=>window.s4AmericaExact.slice(index),prior);
      assert.equal(dispatches.length,1);
      assert.equal(dispatches[0].title,owner.outgoing.split('#')[0]);
      assert.equal(dispatches[0].reply.value,null);
      assert.equal(dispatches[0].reply.error,undefined);
      Object.assign(row,{outgoing:owner.outgoing,dispatches});
    }
  }
}
