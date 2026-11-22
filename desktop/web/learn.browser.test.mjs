import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const web=fileURLToPath(new URL('./',import.meta.url));
const report=process.env.WIKIDICT_LEARN_REPORT;
const selectedScope=process.env.WIKIDICT_LEARN_SCOPE||'all';
assert.ok(['all','normalization','flashcards'].includes(selectedScope),'Unknown Learn test scope');
assert.ok(report&&path.isAbsolute(report),'WIKIDICT_LEARN_REPORT must be a fresh absolute directory');
await mkdir(report,{recursive:false});
execFileSync(process.execPath,['build.mjs'],{cwd:web,stdio:'inherit'});
const root=fileURLToPath(new URL('../build/web/',import.meta.url));
const graphemeFixtures=[
  {id:'combining',title:'e\u0301t',scrambled:'te\u0301'},
  {id:'joined-emoji',title:'a\u{1f469}\u200d\u{1f52c}b',scrambled:'b\u{1f469}\u200d\u{1f52c}a'},
  {id:'flag',title:'ab\u{1f1f3}\u{1f1ff}',scrambled:'\u{1f1f3}\u{1f1ff}ba'},
];
const normalizationFixtures=[
  {id:'nfc',title:'caf\u00e9',scrambled:'\u00e9fac'},
  {id:'nfd',title:'cafe\u0301',scrambled:'e\u0301fac'},
  {id:'fullwidth',title:'\uff43\uff41\uff46\uff45',scrambled:'\uff45\uff46\uff41\uff43'},
];
const normalizationCases=[
  {id:'nfc-title-nfd-answer',fixture:'nfc',answer:' CAFE\u0301 ',correct:true},
  {id:'nfd-title-nfc-answer',fixture:'nfd',answer:'CAF\u00c9',correct:true},
  {id:'missing-accent',fixture:'nfc',answer:'cafe',correct:false},
  {id:'different-accent',fixture:'nfc',answer:'caf\u00e8',correct:false},
  {id:'compatibility-not-canonical',fixture:'fullwidth',answer:'cafe',correct:false},
];
const pendingFixture={id:'flashcards-pending',pending:true};
const fixtures=[...graphemeFixtures,...normalizationFixtures,pendingFixture];
const meaning='A controlled practice definition';
const pendingWorker=`
const hits=['First card','Second card'].map(title=>({dictionary:'practice-fixture',context:'practice-fixture',title,language:'English',kind:'language'}));
const entry=hit=>({...hit,language_code:'en',sections:[{title:'Meaning',blocks:[{kind:'definition',spans:[{kind:'text',text:'A controlled practice definition'}]}]}]});
let reads=0,waiting=[];
onmessage=({data:{id,type,args}})=>{
 if(type==='fixtureRelease'){const request=waiting.shift();if(!request)throw Error('No pending read');postMessage({id:request.id,value:args.fail?undefined:entry(request.hit),error:args.fail?'Controlled next-card failure':undefined});return;}
 if(type==='read'){const hit=hits.find(hit=>hit.title===args.title);if(++reads>1){waiting.push({id,hit});return;}postMessage({id,value:entry(hit)});return;}
 let value,error;
 if(type==='state')value={sources:[],history:hits,settings:{randomPool:'history'}};
 else if(type==='list')value=[{id:'practice-fixture',language:'English',count:2,bytes:2}];
 else if(type==='search')value=[];
 else if(type==='saveState')value=true;
 else error='Unexpected fixture request: '+type;
 postMessage({id,value,error});
};`;
const fixtureWorker=fixture=>fixture.pending?pendingWorker:`
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
    await context.addInitScript(()=>{
      const OriginalWorker=window.Worker;
      window.Worker=class extends OriginalWorker{
        constructor(...args){super(...args);window.practiceWorker=this;window.practiceReadRequests=[];}
        postMessage(message,...rest){
          if(message.type==='saveState')window.practiceSavedState=structuredClone(message.args);
          if(message.type==='read')window.practiceReadRequests.push(structuredClone(message.args));
          return super.postMessage(message,...rest);
        }
      };
    });
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
  if(selectedScope==='all'){
  for(const width of [360,768])for(const fixture of graphemeFixtures){
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
  }
  if(selectedScope!=='flashcards')for(const test of normalizationCases){
    const fixture=normalizationFixtures.find(item=>item.id===test.fixture);
    const {context,page}=await open(fixture,360);
    await page.getByRole('button',{name:fixture.title+'. Reveal meaning',exact:true}).waitFor();
    await page.getByRole('button',{name:'Scramble',exact:true}).click();
    const heading=page.locator('.practice h2');
    await heading.waitFor();
    assert.equal(await heading.textContent(),fixture.scrambled,'The original title graphemes remain unchanged');
    const input=page.getByRole('textbox',{name:'Your answer',exact:true});
    await input.fill(test.answer);
    await input.press('Tab');
    const check=page.getByRole('button',{name:'Check',exact:true});
    assert.equal(await check.evaluate(element=>document.activeElement===element),true);
    await page.keyboard.press('Enter');
    await page.getByText(test.correct?'Correct.':'Answer: '+fixture.title,{exact:true}).waitFor();
    await page.waitForFunction(()=>window.practiceSavedState&&Object.keys(window.practiceSavedState.scores).length===1);
    const saved=await page.evaluate(()=>window.practiceSavedState);
    const scoreKeys=Object.keys(saved.scores);
    assert.deepEqual(JSON.parse(scoreKeys[0]),['practice-fixture','practice-fixture',fixture.title]);
    assert.deepEqual(saved.scores[scoreKeys[0]],test.correct?{right:1,wrong:0}:{right:0,wrong:1});
    assert.equal(saved.history[0].title,fixture.title,'Answer normalization must not rewrite stored titles');
    assert.equal(await heading.textContent(),fixture.scrambled);
    assert.equal(await page.locator('#status').textContent(),'');
    await frame(page,'canonical-answer-'+test.id+'.png');
    cases.push({fixture:test.id,width:360,passed:true,correct:test.correct,storedTitle:saved.history[0].title,score:saved.scores[scoreKeys[0]]});
    await context.close();
  }
  if(selectedScope==='all'||selectedScope==='flashcards')for(const width of [360,768]){
    const {context,page}=await open(pendingFixture,width);
    const card=page.locator('.flashcard');await card.waitFor();
    const first=await card.locator('h2').textContent(),second=first==='First card'?'Second card':'First card';
    const scoreFor=async title=>page.evaluate(title=>{const scores=window.practiceSavedState?.scores||{};return Object.entries(scores).find(([key])=>JSON.parse(key)[2]===title)?.[1];},title);
    const requestCount=()=>page.evaluate(()=>window.practiceReadRequests.length);
    const release=fail=>page.evaluate(fail=>window.practiceWorker.postMessage({type:'fixtureRelease',args:{fail}}),fail);
    const again=page.getByRole('button',{name:'Again',exact:true}),gotIt=page.getByRole('button',{name:'Got it',exact:true});
    await card.click();await gotIt.focus();await page.keyboard.press('Enter');
    await page.keyboard.press('Enter');await again.dispatchEvent('click');await gotIt.dispatchEvent('click');
    await page.waitForFunction(()=>window.practiceSavedState&&Object.keys(window.practiceSavedState.scores).length===1);
    assert.deepEqual(await scoreFor(first),{right:1,wrong:0});assert.equal(await requestCount(),2);
    assert.equal(await again.isDisabled(),true);assert.equal(await gotIt.isDisabled(),true);assert.equal(await card.isDisabled(),true);
    assert.equal(await page.locator('#status').textContent(),'Loading next card…');
    await frame(page,'flashcards-'+width+'-pending.png');
    await release(true);await page.getByText('Controlled next-card failure',{exact:true}).waitFor();
    const retry=page.getByRole('button',{name:'Retry next card',exact:true});
    assert.equal(await retry.evaluate(element=>element===document.activeElement),true);
    assert.equal(await card.locator('h2').textContent(),first);assert.deepEqual(await scoreFor(first),{right:1,wrong:0});
    assert.equal(await again.isDisabled(),true);assert.equal(await gotIt.isDisabled(),true);
    await frame(page,'flashcards-'+width+'-retry.png');
    await page.keyboard.press('Enter');await retry.dispatchEvent('click');await again.dispatchEvent('click');
    assert.equal(await requestCount(),3);assert.deepEqual(await scoreFor(first),{right:1,wrong:0});
    assert.equal(await page.evaluate(()=>window.practiceReadRequests.at(-1).title),second,'Failed next-card load must not advance the displayed-card identity');
    await release(false);await page.getByRole('button',{name:second+'. Reveal meaning',exact:true}).waitFor();
    assert.equal(await card.evaluate(element=>element===document.activeElement),true);assert.equal(await page.locator('#status').textContent(),'');
    await page.keyboard.press('Space');await page.keyboard.press('Tab');
    assert.equal(await again.evaluate(element=>element===document.activeElement),true);await page.keyboard.press('Enter');
    await gotIt.dispatchEvent('click');await again.dispatchEvent('click');
    await page.waitForFunction(()=>Object.keys(window.practiceSavedState.scores).length===2);
    assert.deepEqual(await scoreFor(second),{right:0,wrong:1});assert.deepEqual(await scoreFor(first),{right:1,wrong:0});assert.equal(await requestCount(),4);
    await release(false);await page.getByRole('button',{name:first+'. Reveal meaning',exact:true}).waitFor();
    assert.equal(await card.evaluate(element=>element===document.activeElement),true);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await frame(page,'flashcards-'+width+'-recovered.png');
    cases.push({fixture:'flashcards-pending-retry',width,passed:true,first,second,reads:await requestCount(),firstScore:await scoreFor(first),secondScore:await scoreFor(second),keyboardRetryFocus:true});
    await context.close();
  }
  assert.deepEqual(errors,[]);
  assert.deepEqual(externalRequests,[]);
  await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,selectedScope,cases,frames,errors,externalRequests,scope:'Built browser Learn UI with controlled semantic worker entries. Selected scope checks canonical answer equivalence or pending flashcard single scoring, failed-load retry, keyboard focus and responsive layout; all also checks graphemes and unavailable segmentation. Not corpus import, physical-device or assistive-technology qualification.'},null,2)+'\n');
  console.log('LEARN_BROWSER_PASS');
}finally{
  await browser?.close();
  await new Promise(resolve=>server.close(resolve));
}
