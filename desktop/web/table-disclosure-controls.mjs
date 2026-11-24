import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {openSource} from './xz.js';
import {buildIndex,decode} from './blob.js';
import {validateTableDisclosure} from './validate.js';

const defaultAsset=new URL('../../android/app/src/androidTest/assets/tl-society/disclosure.wikblb.xz',import.meta.url);
const modes=[['always','collapsed','collapsed',...Array(9).fill('expanded')],['always',...Array(5).fill('expanded')]];
const names=['always','collapsed','expanded'];
export async function readTableDisclosure(asset=defaultAsset){
  const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
  const xz=await readFile(asset);
  assert.equal(sha(xz),'e0939f8fe55bb31f92ffa4b5ad2b25d9d593e3d8e83983dfa166bcbf52d89918');
  const origin=await openSource(new Blob([xz]));
  assert.equal(origin.size,20587);
  assert.equal(sha(await origin.read(0,origin.size)),'eeb542fe4741553c4ec2f0dfddf4b95487731a1e72c2c5377d02221de446caf8');
  const {rows,metadata}=await buildIndex(origin),row=rows.find(r=>r.title==='समाज');
  assert.ok(row);
  const raw=Buffer.from(await origin.read(row.offset,row.length)),meta={...metadata,title:row.title,source_edition:'tlwiktionary'};
  assert.deepEqual([row.offset,row.length],[35,20552]);
  assert.equal(sha(raw),'d0a00155e571c80a74d44e52cc85c938e64e66415df5a10b603352b60304167c');
  const entry=decode(raw,meta),tables=[];
  function visit(node){
    if(!node||typeof node!=='object')return;
    if(node.disclosure&&Array.isArray(node.rows))tables.push(node);
    for(const child of Object.values(node))visit(child);
  }
  visit(entry);
  assert.equal(entry.title,'समाज');
  assert.deepEqual(tables.map(t=>t.rows.length),[12,6]);
  for(const [i,table] of tables.entries()){
    const p=table.disclosure;
    assert.deepEqual(p.row_modes,modes[i]);
    assert.equal(p.initially_collapsed,true);
    assert.equal(p.header_row,0);
    assert.equal(p.header_cell,0);
    assert.equal(p.expand_label,'more ▼');
    assert.equal(p.collapse_label,'less ▲');
    assert.equal(p.category,'inflection');
    const header=table.rows[p.header_row].cells[p.header_cell];
    assert.ok(header.header);
    const self=header.spans.find(span=>span.text==='समाज');
    assert.ok(self?.kind==='text'&&self.bold&&self.language==='mr'&&self.classes.split(/\s+/).includes('selflink'));
    assert.equal(self.target,'');
    const tail=[];
    function word(n){const b=Buffer.alloc(4);b.writeUInt32LE(n);tail.push(b);}
    word(p.header_row);word(p.header_cell);tail.push(Buffer.from([1]));
    for(const value of [p.expand_label,p.collapse_label,p.category]){
      const bytes=Buffer.from(value);word(bytes.length);tail.push(bytes);
    }
    const rowStart=Buffer.concat(tail).length;
    tail.push(Buffer.from(p.row_modes.map(m=>names.indexOf(m))));
    const needle=Buffer.concat(tail),at=raw.indexOf(needle);
    assert.ok(at>=0&&raw.lastIndexOf(needle)===at,'Unique typed table tail expected');
    for(const [offset,value] of [[0,255],[4,255],[8,2],[13,0],[rowStart,1],[rowStart+1,3]]){
      const forged=Buffer.from(raw);forged[at+offset]=value;
      assert.throws(()=>decode(forged,meta));
    }
    assert.throws(()=>decode(raw.subarray(0,at+needle.length-1),meta));
    for(const addition of [{rows_hidden_max_width_px:400},{block_viewport:{}},{float_viewport:{}},{style:{display:'inline_table'}}])
      assert.throws(()=>validateTableDisclosure({...table,...addition}),/table disclosure/);
    assert.throws(()=>validateTableDisclosure({...table,disclosure:{...p,row_modes:Array(table.rows.length).fill('always')}}));
  }
  assert.equal(tables[0].rows[3].cells[2].rowspan,10);
  assert.equal(tables[0].rows[11].cells[0].colspan,4);
  assert.equal(tables[1].rows[5].cells[0].colspan,8);
  return {entry,tables};
}

export async function verifyTableDisclosureBrowser(page,bundle,entry,css){
  const url='https://reader.test/table-disclosure';
  await page.route('**/*',route=>route.request().url()===url?route.fulfill({contentType:'text/html',body:'<main></main>'}):route.abort());
  await page.goto(url);
  const mount=async original=>{
  await page.addStyleTag({content:css});
  await page.addScriptTag({content:bundle});
  await page.evaluate(entry=>{
    window.tableActions=[];
    const root=document.querySelector('main');
    root.append(Renderer.renderEntry(entry,(...a)=>window.tableActions.push(a),{collapseOtherSections:false}));
    for(const detail of root.querySelectorAll('details'))detail.open=true;
    window.grids=[...root.querySelectorAll('.table-disclosure-header')].map(h=>h.closest('table'));
    window.physicalRows=window.grids.map(table=>Array.from(table.rows));
    window.currentRows=()=>window.grids.map((table,i)=>Array.from(table.rows).flatMap((row,n)=>{
      if(row!==window.physicalRows[i][n])throw Error('Physical row was replaced');
      return row.getClientRects().length?[n]:[];
    }));
  },original);
  };
  await mount(entry);
  const category=page.getByRole('navigation',{name:'Visibility'}).getByRole('button');
  const [first,second]=[0,1].map(i=>page.locator('.table-disclosure-header button').nth(i));
  const collapsed=[[0,1,2],[0]],expandedFirst=[0,...Array.from({length:9},(_,i)=>i+3)];
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),collapsed);
  assert.equal(await page.getByRole('button',{name:'more ▼',exact:true}).count(),2);
  assert.equal(await category.textContent(),'Show inflection');
  await first.focus();
  await first.press('Space');
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),[expandedFirst,[0]]);
  assert.equal(await first.getAttribute('aria-expanded'),'true');
  assert.equal(await category.textContent(),'Show inflection');
  assert.equal(await first.textContent(),'less ▲');
  const overlap=await first.evaluate(button=>{
    const table=button.closest('table'),separator=table.rows[3].cells[2],foot=table.rows[11].cells[0];
    foot.scrollIntoView({block:'center',inline:'nearest'});
    const a=separator.getBoundingClientRect(),b=foot.getBoundingClientRect(),pane=table.closest('.table-scroll')?.getBoundingClientRect();
    const x0=Math.max(a.left,b.left,pane?.left??0,0),x1=Math.min(a.right,b.right,pane?.right??innerWidth,innerWidth);
    const y0=Math.max(a.top,b.top,0),y1=Math.min(a.bottom,b.bottom,innerHeight);
    const cells=x1>x0&&y1>y0?document.elementsFromPoint((x0+x1)/2,(y0+y1)/2).map(el=>el.closest('td,th')).filter(Boolean):[];
    return {width:x1-x0,height:y1-y0,footer:cells.includes(foot),separator:cells.includes(separator),
      controls:'ariaControlsElements' in button?button.ariaControlsElements.map(row=>row.rowIndex):null};
  });
  assert.ok(overlap.width>0&&overlap.height>0,'The original rowspan must intersect the four-column footer');
  assert.ok(overlap.footer&&overlap.separator,'Both original cell boxes participate in the overlap hit stack');
  if(overlap.controls)assert.deepEqual(overlap.controls,Array.from({length:11},(_,i)=>1+i));
  assert.equal(await first.evaluate(el=>el===document.activeElement),true);
  const footer=page.locator('.table-disclosure-header').first().locator('xpath=ancestor::table[1]').getByRole('link',{name:'-त',exact:true});
  await footer.click();
  const link=await page.evaluate(()=>window.tableActions.at(-1));
  assert.ok(link[0]==='-त#Marati'||(link[0]==='-त'&&link[1]==='Marati'));
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),[expandedFirst,[0]]);
  await second.press('Enter');
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),[expandedFirst,[0,1,2,3,4,5]]);
  assert.equal(await category.textContent(),'Hide inflection');
  assert.equal(await page.evaluate(()=>localStorage.length),0);
  const table=page.locator('.table-disclosure-header').nth(1).locator('xpath=ancestor::table[1]');
  assert.equal(await table.getByRole('link',{name:'ए',exact:true}).count(),1);
  assert.equal(await table.getByRole('link',{name:'अ',exact:true}).count(),1);
  await first.press('Enter');
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),[[0,1,2],[0,1,2,3,4,5]]);
  assert.equal(await category.textContent(),'Hide inflection');
  await second.press('Space');
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),collapsed);
  assert.equal(await category.textContent(),'Show inflection');
  assert.equal(await page.evaluate(()=>localStorage.length),0);
  await category.press('Enter');
  const expanded=[expandedFirst,[0,1,2,3,4,5]];
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),expanded);
  assert.equal(await category.textContent(),'Hide inflection');
  await first.press('Space');await second.press('Space');
  assert.equal(await category.textContent(),'Show inflection');
  // Fresh navigation sees only the explicit category preference, scoped to its source edition.
  await page.reload();await mount(entry);
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),expanded);
  assert.equal(await category.textContent(),'Hide inflection');
  await page.reload();await mount({...entry,source_edition:'otherwiktionary'});
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),collapsed);
  await page.reload();await mount(entry);await category.press('Space');
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),collapsed);
  await page.reload();await mount(entry);
  assert.deepEqual(await page.evaluate(()=>window.currentRows()),collapsed);
  assert.equal(await category.textContent(),'Show inflection');
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  const {entry}=await readTableDisclosure();
  if(!process.argv.includes('--node-only')){
    const {chromium}=await import('playwright'),{build}=await import('esbuild');
    const result=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
    const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
    try{await verifyTableDisclosureBrowser(await browser.newPage(),result.outputFiles[0].text,entry,await readFile(new URL('./style.css',import.meta.url),'utf8'));}
    finally{await browser.close();}
  }
}
