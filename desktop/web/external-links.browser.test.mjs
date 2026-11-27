import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
import {chromium} from 'playwright';

// Reduced typed link from the retained NDS entry, with synthetic routing controls.
const authored = '//nds.wiktionary.org/w/index.php?title=V%C3%B6rlaag:%C3%96_-bor&action=edit';
const absolute = 'https://ro.wikipedia.org/wiki/Limba_nepalez%C4%83';
const renderer = await build({entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],
  bundle:true,format:'iife',globalName:'Renderer',write:false});
const browser = await chromium.launch({executablePath:process.env.CHROMIUM || '/opt/brave-bin/brave',
  headless:true,args:['--no-sandbox']});
try {
  const context = await browser.newContext({viewport:{width:1000,height:700}});
  const requests = [];
  await context.route('**/*', async route => {
    requests.push(route.request().url());
    await route.fulfill({contentType:'text/html',body:'<!doctype html><title>Controlled destination</title>'});
  });
  const page = await context.newPage();
  await page.setContent('<!doctype html><base href="http://unrelated.invalid/"><main></main>');
  await page.addScriptTag({content:renderer.outputFiles[0].text});
  const render = async edition => page.evaluate(({edition,authored,absolute}) => {
    window.localCalls = [];
    const values = [
      {kind:'external_link',text:'NDS source',target:authored},
      {kind:'external_link',text:'Absolute control',target:absolute},
      {kind:'external_link',text:'Cross-host control',target:'//example.org/a%20b?x=1#part'},
      {kind:'external_link',text:'',target:authored},
      {kind:'external_link',text:'Invalid authority',target:'///example.org/a'},
      {kind:'link',text:'Local control',target:'Local#literal',target_fragment:''}
    ];
    const entry = {title:'External link controls',source_edition:edition,
      sections:[{title:'Links',blocks:[{kind:'paragraph',spans:values}]}],references:[],media:[]};
    document.querySelector('main').replaceChildren(Renderer.renderEntry(entry,(...parts)=>window.localCalls.push(parts)));
  },{edition,authored,absolute});
  for (const [width,trigger] of [[1000,'click'],[640,'Enter']]) {
    await page.setViewportSize({width,height:700});
    await render('ndswiktionary');
    const source = page.getByRole('link',{name:'NDS source',exact:true});
    assert.equal(await source.count(),1);
    assert.equal(await source.getAttribute('href'),'https:'+authored);
    assert.equal(await source.getAttribute('target'),'_blank');
    assert.equal(await source.getAttribute('rel'),'noopener noreferrer');
    assert.equal(await page.getByRole('link',{name:'Absolute control'}).getAttribute('href'),absolute);
    assert.equal(await page.getByRole('link',{name:'Cross-host control'}).getAttribute('href'),'https://example.org/a%20b?x=1#part');
    assert.equal(await page.getByRole('link',{name:'https:'+authored,exact:true}).count(),1);
    assert.equal(await page.getByRole('link',{name:'Invalid authority'}).count(),0);
    const pending = context.waitForEvent('page');
    if (trigger==='click') await source.click();
    else {await source.focus(); await source.press('Enter');}
    const popup = await pending;
    await popup.waitForLoadState('domcontentloaded');
    assert.equal(popup.url(),'https:'+authored);
    assert.equal(await popup.evaluate(()=>window.opener===null),true);
    await popup.close();
    await page.getByRole('link',{name:'Local control'}).click();
    assert.deepEqual(await page.evaluate(()=>window.localCalls),[['Local#literal','']]);
  }
  for (const edition of [undefined,'','Unknown']) {
    await render(edition);
    assert.equal(await page.getByRole('link',{name:'NDS source'}).count(),0);
    assert.equal(await page.getByRole('link',{name:'Absolute control'}).getAttribute('href'),absolute);
  }
  assert.deepEqual(requests,['https:'+authored,'https:'+authored]);
  await context.close();
  console.log('EXTERNAL_LINKS_BROWSER_PASS: pointer and Enter preserve authored destination; no external network');
} finally {
  await browser.close();
}
