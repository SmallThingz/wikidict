import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
import {chromium} from 'playwright';

// Reduced compiled citation from Nahuatl Wiktionary's acalco, revision 91178.
const address = 'https://web.archive.org/web/20130731105226/http://sites.estvideo.net/malinal/a/nahuatlACAI.html';
const entry = {
  title: 'acalco',
  source_edition: 'nahwiktionary',
  source_title: 'acalco',
  sections: [{
    title: 'Toquiliztequitl',
    level: 3,
    blocks: [{
      kind: 'list_item',
      depth: 1,
      spans: [
        {kind:'text',text:'Wimmer, Alexis. '},
        {kind:'text',text:'Dictionnaire de la langue Nahuatl Classique',italic:true},
        {kind:'text',text:': '},
        {kind:'external_link',text:address,target:address}
      ]
    }]
  }],
  references: [],
  media: []
};
const renderer = await build({
  entryPoints:[fileURLToPath(new URL('./renderer.js',import.meta.url))],
  bundle:true,format:'iife',globalName:'Renderer',write:false
});
const css = await readFile(new URL('./style.css',import.meta.url),'utf8');
const font = await readFile(new URL('./reader.ttf',import.meta.url));

function measureToken(link, {token, removeBreaks}) {
  if (removeBreaks) {
    for (const opportunity of link.querySelectorAll('wbr')) opportunity.remove();
    link.normalize();
  }
  const url = link.textContent;
  const from = token === 'net' ? url.indexOf('.net/') + 1 : url.lastIndexOf(token);
  const to = from + token.length;
  const walker = document.createTreeWalker(link,NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  let offset = 0;
  let text;
  while ((text = walker.nextNode())) {
    const end = offset + text.length;
    if (from >= offset && from < end) range.setStart(text,from-offset);
    if (to > offset && to <= end) {
      range.setEnd(text,to-offset);
      break;
    }
    offset = end;
  }
  const lines = new Set([...range.getClientRects()].filter(r=>r.width&&r.height).map(r=>r.top));
  return {text:range.toString(),lines:lines.size};
}

const browser = await chromium.launch({
  executablePath:process.env.CHROMIUM || '/opt/brave-bin/brave',
  headless:true,args:['--no-sandbox']
});
try {
  const page = await browser.newPage({viewport:{width:1000,height:800},colorScheme:'light',deviceScaleFactor:1});
  await page.route('**/*', route =>
    route.request().url()==='https://reader.invalid/reader.ttf' ?
      route.fulfill({body:font,contentType:'font/ttf',headers:{'access-control-allow-origin':'*'}}) : route.abort());
  await page.setContent('<!doctype html><base href="https://reader.invalid/"><style>'+css+'</style><main></main>');
  await page.addScriptTag({content:renderer.outputFiles[0].text});
  assert.equal(await page.evaluate(async () => {
    const faces = await document.fonts.load('16px Reader');
    await document.fonts.ready;
    return document.compatMode==='CSS1Compat' && faces.length>0 && faces.every(face=>face.status==='loaded');
  }),true);

  for (const [width,token] of [[1000,'html'],[640,'net']]) {
    await page.setViewportSize({width,height:800});
    await page.evaluate(value => {
      const main = document.querySelector('main');
      main.replaceChildren(Renderer.renderEntry(value,()=>{}));
      for (const disclosure of main.querySelectorAll('details')) disclosure.open = true;
    },entry);

    const link = page.getByRole('link',{name:address,exact:true});
    assert.equal(await link.count(),1);
    assert.equal(await link.getAttribute('href'),address);
    assert.equal(await link.textContent(),address);
    assert.equal(await link.evaluate(anchor => {
      const selection = getSelection();
      const range = document.createRange();
      range.selectNodeContents(anchor);
      selection.addRange(range);
      try { return selection.toString(); }
      finally { selection.removeAllRanges(); }
    }),address);
    assert.deepEqual(await link.evaluate(measureToken,{token,removeBreaks:false}),{text:token,lines:1});

    // Removing the soft break opportunities recreates the old layout.
    assert.deepEqual(await link.evaluate(measureToken,{token,removeBreaks:true}),{text:token,lines:2});
  }
  console.log('URL_WRAP_BROWSER_PASS');
} finally {
  await browser.close();
}
