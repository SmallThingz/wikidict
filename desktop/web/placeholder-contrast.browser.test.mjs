import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const web=fileURLToPath(new URL('./',import.meta.url)),report=process.env.WIKIDICT_PLACEHOLDER_REPORT;
assert.ok(report&&path.isAbsolute(report));await mkdir(report,{recursive:false});
execFileSync(process.execPath,['build.mjs'],{cwd:web,stdio:'inherit'});
const root=fileURLToPath(new URL('../build/web/',import.meta.url)),assets=new Set(['index.html','app.js','import-worker.js','style.css','reader.ttf']);
const server=createServer(async(req,res)=>{try{const name=new URL(req.url,'http://localhost').pathname.split('/').filter(Boolean).at(-1)||'index.html';assert.ok(assets.has(name));const bytes=await readFile(path.join(root,name));res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
const lum=rgb=>rgb.map(x=>x/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4).reduce((v,x,i)=>v+x*[.2126,.7152,.0722][i],0);
const rgb=s=>s.match(/[\d.]+/g).slice(0,3).map(Number),ratio=(a,b)=>{const x=lum(rgb(a)),y=lum(rgb(b));return(Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
let browser;const externalRequests=[],errors=[],observations=[],frames=[];
try{browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
for(const theme of ['light','dark'])for(const width of [360,768]){
 const ctx=await browser.newContext({colorScheme:theme,viewport:{width,height:640}});await ctx.route('**/*',r=>{if(new URL(r.request().url()).origin===origin)return r.continue();externalRequests.push(r.request().url());return r.abort();});const page=await ctx.newPage();page.on('pageerror',e=>errors.push(e.message));await page.goto(origin);await page.getByRole('button',{name:'Add list',exact:true}).waitFor();await page.getByRole('button',{name:'Search',exact:true}).click();const input=page.getByRole('searchbox',{name:'Find a word',exact:true});await input.waitFor();
 const v=await input.evaluate(el=>{const p=getComputedStyle(el,'::placeholder'),s=getComputedStyle(el),r=el.getBoundingClientRect();return{foreground:p.color,background:s.backgroundColor,opacity:p.opacity,inputOpacity:s.opacity,inputForeground:s.color,fontSize:p.fontSize,theme:document.documentElement.dataset.theme,left:r.left,right:r.right,text:el.placeholder,value:el.value};});
 assert.equal(v.theme,theme);assert.equal(v.text,'Search your dictionaries');assert.equal(v.value,'');assert.equal(v.opacity,'1');assert.equal(v.inputOpacity,'1');assert.ok(v.left>=0&&v.right<=width);assert.equal(await input.evaluate(el=>document.activeElement===el),true);
 assert.equal(v.foreground,theme==='light'?'rgb(89, 101, 89)':'rgb(167, 180, 166)');assert.equal(v.inputForeground,theme==='light'?'rgb(38, 56, 45)':'rgb(228, 231, 218)');const contrast=ratio(v.foreground,v.background);assert.ok(contrast>=4.5);
 await input.fill('public test query');assert.equal(await input.inputValue(),'public test query');assert.equal(await input.evaluate(el=>getComputedStyle(el).color),v.inputForeground);await input.fill('');
 observations.push({...v,width,contrast});const name=`placeholder-contrast-${theme}-${width}.png`;await input.evaluate(el=>el.scrollIntoView({block:'center'}));await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));assert.equal(await input.evaluate(el=>{const r=el.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight&&document.activeElement===el&&el.value==='';}),true);await page.screenshot({path:path.join(report,name),fullPage:false,animations:'disabled'});frames.push(name);await ctx.close();
}
assert.deepEqual(errors,[]);assert.deepEqual(externalRequests,[]);await writeFile(path.join(report,'result.json'),JSON.stringify({passed:true,observations,frames,errors,externalRequests,scope:'Actual built app Search placeholder foreground/opacity/input background contrast/light-dark360-768; accessible query label, actual focus and typed text color retained. No navigation/action replay or public transport.'},null,2)+'\n');console.log('PLACEHOLDER_CONTRAST_BROWSER_PASS');
}finally{await browser?.close();await new Promise(r=>server.close(r));}
