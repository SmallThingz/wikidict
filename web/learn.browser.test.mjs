import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const web=fileURLToPath(new URL('./',import.meta.url));
const report=process.env.WIKIDICT_LEARN_REPORT;
assert.ok(report&&path.isAbsolute(report),'WIKIDICT_LEARN_REPORT must be a fresh absolute directory');
await mkdir(report,{recursive:false});
execFileSync(process.execPath,['build.mjs'],{cwd:web,stdio:'inherit'});
const root=fileURLToPath(new URL('../build/web/',import.meta.url));
const fixtures=[
  {id:'combining',title:'e\u0301t',scrambled:'te\u0301'},
  {id:'joined-emoji',title:'a\u{1f469}\u200d\u{1f52c}b',scrambled:'b\u{1f469}\u200d\u{1f52c}a'},
  {id:'flag',title:'ab\u{1f1f3}\u{1f1ff}',scrambled:'\u{1f1f3}\u{1f1ff}ba'},
];
const meaning='A controlled practice definition';
const fixtureWorker=fixture=>`
const title=${JSON.stringify(fixture.title)},meaning=${JSON.stringify(meaning)};
const hit={dictionary:'practice-fixture',context:'practice-fixture',title,language:'English',kind:'language'};
const entry={...hit,language_code:'en',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:[{kind:'text',text:meaning}]}]}]};
onmessage=({data:{id,type}})=>{
  let value,error;
  if(type==='state')value={sources:[],history:[hit],settings:{randomPool:'history'}};
  else if(type==='list')value=[{id:hit.dictionary,language:'English',count:1,bytes:1}];
  else if(type==='search')value=[];
  else if(type==='read')value=entry;
  else if(type==='saveState')value=true;
  else error='Unexpected fixture request: '+type;
  postMessage({id,value,error});
};`;
const assets=new Set(['index.html','app.js','import-worker.js','style.css','reader.ttf']);
const server=createServer(async(req,res)=>{
  try{
    const parts=new URL(req.url,'http://localhost').pathname.split('/').filter(Boolean);
    const fixture=fixtures.find(item=>item.id===parts[0]),name=parts.at(-1);
    assert.ok(fixture&&assets.has(name));
    const bytes=name==='import-worker.js'?fixtureWorker(fixture):await readFile(path.join(root,name));
    res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.ttf')?'font/ttf':'text/html');
    res.end(bytes);
  }catch{res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
const errors=[],externalRequests=[],cases=[],frames=[];
let browser;
try{
  browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
  const open=async(fixture,width,noSegmenter=false)=>{
    const context=await browser.newContext({viewport:{width,height:720},colorScheme:'light'});
    await context.route('**/*',route=>{
      if(new URL(route.request().url()).origin===origin)return route.continue();
      externalRequests.push(route.request().url());return route.abort();
    });
    if(noSegmenter)await context.addInitScript(()=>{Intl.Segmenter=undefined;});
    const page=await context.newPage();
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto(origin+'/'+fixture.id+'/index.html');
    await page.getByRole('searchbox',{name:'Find a word',exact:true}).waitFor();
    await page.getByRole('button',{name:'Learn',exact:true}).click();
    return {context,page};
  };
  const frame=async(page,name)=>{
    await page.screenshot({path:path.join(report,name),fullPage:true,animations:'disabled'});
    frames.push(name);
  };
  for(const width of [360,768])for(const fixture of fixtures){
    const {context,page}=await open(fixture,width);
    const hiddenName=fixture.title+'. Reveal meaning';
    const visibleName=fixture.title+'. '+meaning+'. Hide meaning';
    const card=page.getByRole('button',{name:hiddenName,exact:true});
    await card.waitFor();
    assert.equal(await card.getAttribute('aria-expanded'),'false');
    assert.equal(await page.getByRole('button',{name:'Again',exact:true}).isVisible(),false);
    await card.evaluate(element=>{window.practiceCard=element;});
    let tabs=0;
    while(!await card.evaluate(element=>document.activeElement===element)&&tabs<12){
      await page.keyboard.press('Tab');tabs++;
    }
    assert.equal(await card.evaluate(element=>document.activeElement===element),true,'Flashcard must be reachable by Tab');
    await page.keyboard.press('Enter');
    const revealed=page.getByRole('button',{name:visibleName,exact:true});
    await revealed.waitFor();
    assert.equal(await revealed.getAttribute('aria-expanded'),'true');
    assert.equal(await revealed.evaluate(element=>element===window.practiceCard&&document.activeElement===element),true);
    const revealedAccessibility=await revealed.ariaSnapshot();
    assert.ok(revealedAccessibility.includes(meaning));
    await frame(page,fixture.id+'-'+width+'-revealed.png');
    await page.keyboard.press('Tab');
    assert.equal(await page.getByRole('button',{name:'Again',exact:true}).evaluate(element=>document.activeElement===element),true);
    await page.keyboard.press('Shift+Tab');
    await page.keyboard.press('Space');
    await card.waitFor();
    assert.equal(await card.getAttribute('aria-expanded'),'false');
    assert.equal(await card.evaluate(element=>element===window.practiceCard&&document.activeElement===element),true);
    assert.equal(await page.getByRole('button',{name:'Again',exact:true}).isVisible(),false);
    assert.ok(!(await card.ariaSnapshot()).includes(meaning),'Hidden meaning must stay hidden from the accessible name');
    await page.getByRole('button',{name:'Scramble',exact:true}).click();
    const heading=page.locator('.practice h2');
    await heading.waitFor();
    assert.equal(await heading.textContent(),fixture.scrambled);
    const input=page.getByRole('textbox',{name:'Your answer',exact:true});
    await input.fill(fixture.title);
    await input.press('Tab');
    const check=page.getByRole('button',{name:'Check',exact:true});
    assert.equal(await check.evaluate(element=>document.activeElement===element),true);
    await page.keyboard.press('Enter');
    await page.getByText('Correct.',{exact:true}).waitFor();
    assert.equal(await page.locator('#status').textContent(),'');
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await frame(page,fixture.id+'-'+width+'-scramble.png');
    cases.push({fixture:fixture.id,width,passed:true,tabsToCard:tabs,revealedAccessibility});
    await context.close();
  }
  const {context,page}=await open(fixtures[0],360,true);
  await page.getByRole('button',{name:fixtures[0].title+'. Reveal meaning',exact:true}).waitFor();
  await page.getByRole('button',{name:'Scramble',exact:true}).click();
  await page.getByText('Scramble is unavailable in this browser. Choose Quiz or Cards.',{exact:true}).waitFor();
  assert.equal(await page.getByRole('textbox',{name:'Your answer',exact:true}).count(),0);
  await frame(page,'segmenter-unavailable.png');
  await page.getByRole('button',{name:'Cards',exact:true}).click();
  await page.getByRole('button',{name:fixtures[0].title+'. Reveal meaning',exact:true}).waitFor();
  assert.equal(await page.locator('#status').textContent(),'');
  cases.push({fixture:'segmenter-unavailable',width:360,passed:true});
  await context.close();
  assert.deepEqual(errors,[]);
  assert.deepEqual(externalRequests,[]);
  await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,cases,frames,errors,externalRequests,scope:'Built browser Learn UI with controlled semantic worker entries; accessible flashcard content/state, keyboard reveal/hide and focus, grapheme-preserving scramble, narrow/wide layout and unavailable-segmentation recovery. Not corpus import, physical-device or assistive-technology qualification.'},null,2)+'\n');
  console.log('LEARN_BROWSER_PASS');
}finally{
  await browser?.close();
  await new Promise(resolve=>server.close(resolve));
}
