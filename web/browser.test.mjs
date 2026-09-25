import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../build/web/',import.meta.url)),report=fileURLToPath(new URL('../artifacts/web/',import.meta.url));
await mkdir(report,{recursive:true});
const fixture=process.env.WIKBLB_FIXTURE||fileURLToPath(new URL('../tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb',import.meta.url));
const raw=await readFile(fixture),xz=execFileSync('xz',['-1','--block-size=64KiB','-c'],{input:raw});
const server=createServer(async(req,res)=>{try{const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname),file=path.resolve(root,'.'+(name==='/'?'/index.html':name));if(!file.startsWith(root))throw Error('path');const bytes=await readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
const errors=[];
try{
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}`);await page.getByRole('button',{name:'Import dictionary',exact:true}).waitFor();
 await page.locator('#file').setInputFiles(fixture);await page.getByText(/English · 182 words/).waitFor();
 await page.getByRole('button',{name:'Search',exact:true}).click();await page.getByRole('searchbox').fill('cat');await page.getByRole('button',{name:'Open cat',exact:true}).click();
 await page.locator('#entry h1').filter({hasText:'cat'}).waitFor();assert.equal(await page.locator('details').filter({has:page.locator('summary').filter({hasText:/^Etymology$/})}).getAttribute('open'),null);
 assert.ok((await page.locator('#entry').innerText()).includes('A small animal'));
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
 await page.reload();await page.getByRole('button',{name:'History',exact:true}).click();await page.getByRole('button',{name:'Open cat',exact:true}).waitFor();
 await page.getByRole('button',{name:'Settings',exact:true}).click();assert.ok((await page.locator('#panel').innerText()).includes('4.0 GB'));
 assert.deepEqual(errors,[]);await writeFile(path.join(report,'report.json'),JSON.stringify({status:'passed',rawBytes:raw.length,xzBytes:xz.length,errors},null,2));console.log('WEB_BINARY_PARITY_PASS');
}finally{await browser.close();server.close();}
