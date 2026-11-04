// Source-only proposal using the existing Playwright/esbuild test stack.
import {chromium} from 'playwright';
import {build} from 'esbuild';
import assert from 'node:assert/strict';
const bundle=await build({entryPoints:[new URL('./renderer.js',import.meta.url).pathname],bundle:true,format:'iife',globalName:'Renderer',write:false});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/opt/brave-bin/brave',headless:true,args:['--no-sandbox']});
try {
 const page=await browser.newPage();
 await page.setContent('<main></main>');await page.addScriptTag({content:bundle.outputFiles[0].text});
 const result=await page.evaluate(()=>{
  const text=text=>({kind:'text',text}),link=(text,target)=>({kind:'link',text,target});
  const paragraph={kind:'paragraph',spans:[text('Četiri prije tablice '),link('Odredište','cilj')]};
  const table={kind:'table',spans:[],table:{caption:[],rows:[{cells:Array.from({length:5},(_,i)=>({header:true,colspan:1,rowspan:1,spans:[text('Glava '+i)]}))},{cells:Array.from({length:5},(_,i)=>({header:false,colspan:1,rowspan:1,spans:[text('Ćelija '+i)]}))}]}};
  const entry={title:'Reference controls',presentation_version:'DPRC',sections:[],references:[{number:7,group_number:2,group:'g',spans:[],blocks:[paragraph,table]},{kind:'fragment',number:8,group:'',spans:[],blocks:[{kind:'heading',level:4,anchor:'Autorska',spans:[text('Autorska')]}]},{number:9,group_number:3,spans:[],blocks:[]},{number:10,group_number:4,spans:[text('Legacy')],blocks:null}]};
  window.followed=[];document.querySelector('main').append(Renderer.renderEntry(entry,t=>window.followed.push(t),{collapseOtherSections:false}));
  let invalid=0;for(const blocks of [{},'bad',[]]){try{Renderer.renderEntry({...entry,references:[{number:1,spans:[text('mixed')],blocks}]},()=>{});}catch{invalid++;}}
  const refs=[...document.querySelectorAll('.reference')];
  return {tags:refs.map(r=>r.tagName),text:refs.map(r=>r.textContent),children:[...refs[0].children].map(c=>c.tagName),rows:refs[0].querySelectorAll('tr').length,headers:refs[0].querySelectorAll('th').length,cells:refs[0].querySelectorAll('td').length,invalid,illegal:document.querySelectorAll('p table').length,fragmentID:refs[1].id,anchor:!!refs[1].querySelector('#Autorska')};
 });
 assert.deepEqual(result.tags,['DIV','DIV','DIV','P']);assert.deepEqual(result.children,['SPAN','DIV','DIV']);
 assert.equal(result.rows,2);assert.equal(result.headers,5);assert.equal(result.cells,5);assert.equal(result.invalid,3);assert.equal(result.illegal,0);assert.equal(result.fragmentID,'');assert.equal(result.anchor,true);
 assert.ok(result.text[0].startsWith('[g 2]Četiri prije tablice'));assert.equal(result.text[2],'[3]');
 await page.getByRole('link',{name:'Odredište',exact:true}).click();assert.deepEqual(await page.evaluate(()=>window.followed),['cilj']);
 assert.ok((await page.locator('#reference-7').ariaSnapshot()).includes('Glava 0'));
} finally {await browser.close();}
