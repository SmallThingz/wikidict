import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {chromium} from 'playwright';
import {isAbsolute} from 'node:path';
import {buildSourceAnchorBrowser,checkAmericaSourceAnchors} from './source-anchor-browser-case.mjs';

const root=new URL('./',import.meta.url);
const local=name=>new URL(name,root);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const output=process.env.WIKIDICT_SOURCE_ANCHOR_REPORT;
const executable=process.env.CHROMIUM||'/opt/brave-bin/brave';
assert.ok(output&&isAbsolute(output),'Supply a fresh absolute report directory');
await mkdir(output);
const files=await buildSourceAnchorBrowser();
const built=Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,sha(bytes)]));
await testBrowser();

async function testBrowser(){
  const mime={'index.html':'text/html','style.css':'text/css','reader.ttf':'font/ttf',
    'assets/phonos/volumeUp.svg':'image/svg+xml'};
  const assetHashes={};
  for(const name of Object.keys(mime)){
    const source=name.startsWith('assets/')?new URL('../../renderer/'+name,root):local(name);
    files[name]=await readFile(source);
    assetHashes[name]=sha(files[name]);
  }
  const server=createServer((req,res)=>{
    const name=req.url==='/'?'index.html':req.url.slice(1);
    if(Object.hasOwn(files,name))return res.writeHead(200,{'Content-Type':mime[name]??'text/javascript'}).end(files[name]);
    res.writeHead(404).end();
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin='http://127.0.0.1:'+server.address().port;
  let browser;
  const report={node:process.version,executable,assets:assetHashes,bundles:built,checks:{}};
  try{
    browser=await chromium.launch({executablePath:executable,headless:true,
      args:['--no-sandbox','--disable-dev-shm-usage','--disable-background-networking','--renderer-process-limit=2']});
    report.browser=browser.version();
    const named=name=>({name,exact:true});
    const start=async page=>{
      await page.goto(origin);
      await page.getByRole('heading',named('Dictionaries')).waitFor();
    };
    const fileImport=async(page,member)=>page.locator('#file').setInputFiles({
      name:member.filename,mimeType:'application/octet-stream',buffer:member.bytes});
    const library=async(page,label)=>page.getByText(label,{exact:true}).waitFor();
    const openRead=async(page,query,resolved,selection)=>{
      await page.getByRole('button',named('Search')).click();
      await page.getByRole('searchbox',named('Find a word')).fill(query);
      const result=page.getByRole('button',named('Open '+query)).filter({has:page.getByText(selection,{exact:true})});
      await result.press('Enter');
      await page.locator('#entry').getByRole('heading',named(resolved)).first().waitFor();
    };
    const api={origin,start,fileImport,library,openRead,output};
    for(const branch of ['baseline','candidate']){
      const context=await browser.newContext({viewport:{width:1120,height:900},serviceWorkers:'block',
        locale:'en-US',deviceScaleFactor:1});
      const page=await context.newPage(),data={},errors=[];
      page.setDefaultTimeout(7500);
      page.on('pageerror',error=>errors.push(error.message));
      try{
        await checkAmericaSourceAnchors(page,context,data,api,branch);
        assert.deepEqual(errors,[]);
        if(branch==='candidate'){
          const previous=report.checks.baseline.data;
          assert.deepEqual(data.headings,previous.headings);
          assert.deepEqual(data.widths.map(row=>row.measure),previous.widths.map(row=>row.measure));
        }
        report.checks[branch]={ok:true,data};
      }catch(error){
        report.checks[branch]={ok:false,error:error.stack,errors,data,
          status:await page.locator('#status').allTextContents().catch(()=>[])};
        await page.screenshot({path:output+'/'+branch+'-failure.png',timeout:4000}).catch(()=>{});
        throw error;
      }finally{
        try{await context.close();}
        finally{await writeFile(output+'/browser.json',JSON.stringify(report,null,2)+'\n');}
      }
    }
  }finally{
    try{await browser?.close();}
    finally{await new Promise(resolve=>server.close(resolve));}
  }
}
