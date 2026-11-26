import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {chromium} from 'playwright';
import {build} from 'esbuild';

const root = new URL('.', import.meta.url);
const output = process.env.WIKIDICT_TABLE_FIT_OUTPUT;
const observed = [];
const fixture = await readFile(new URL('testdata/yi-named-font/tog.dpr', root));
assert.equal(createHash('sha256').update(fixture).digest('hex'),
  '351046ab2224cd239539115b2b6b7a43bcf8377265c56b90e1f6b3a6d1b03f26');
const assets = new Map(await Promise.all(['index.html', 'style.css', 'reader.ttf'].map(async name =>
  [name, await readFile(new URL(name, root))])));
const bundle = await build({stdin: {
  contents: "export {decode} from './blob.js'; export {renderEntry} from './renderer.js'; export {loadInlineImage,mediaView,inlineImageActionURL} from './media.js';",
  resolveDir: root.pathname,
}, bundle: true, format: 'iife', globalName: 'Product', write: false});
const browser = await chromium.launch({executablePath: process.env.CHROMIUM || '/opt/brave-bin/brave',
  headless: true, args: ['--no-sandbox', '--disable-background-networking']});
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== 'https://table-fit.test') return route.abort();
    const name = url.pathname.slice(1) || 'index.html';
    if (name === 'app.js') return route.fulfill({contentType: 'text/javascript', body: ''});
    const body = assets.get(name);
    return body ? route.fulfill({contentType: name.endsWith('.css') ? 'text/css' : name.endsWith('.ttf') ? 'font/ttf' : 'text/html', body}) : route.abort();
  });
  await page.goto('https://table-fit.test/');
  await page.evaluate(() => document.fonts.load('16px Reader'));
  await page.addScriptTag({content: bundle.outputFiles[0].text});
  await page.evaluate(bytes => {
    const host = document.querySelector('#entry');
    const entry = Product.decode(new Uint8Array(bytes), {kind: 'language', title: 'טאָג', language_code: '', language: 'Unclassified'});
    const settings = {allowImages: false, allowAudio: false, mediaCacheMb: 0, collapseOtherSections: true};
    const actions = document.createElement('div'); actions.className = 'word-actions';
    for (const label of ['◖', '◇']) { const button = document.createElement('button'); button.textContent = label; actions.append(button); }
    window.tableFitActions = [];
    window.tableFitEntry = entry;
    window.tableFitSnapshot = JSON.stringify(entry);
    host.append(actions, Product.renderEntry(entry, (...args) => tableFitActions.push(args), settings,
      (media, title) => Product.mediaView(media, settings, 'yiwiktionary', title),
      (image, spec, occurrence) => Product.loadInlineImage(image, spec, settings, 'yiwiktionary', occurrence),
      (target, fragment) => Product.inlineImageActionURL(target, 'yiwiktionary', fragment)));
  }, [...fixture]);
  await page.locator('#entry > .compiled-table-flow > details > summary').filter({hasText: 'Overview'}).click();
  await page.locator('.compiled-figure figcaption a').waitFor({state: 'visible'});
  // Resize the same DOM in both directions: float avoidance must reflow, while
  // a table wider than the whole article must retain horizontal keyboard access.
  for (const width of [320, 640, 1000, 320]) {
    await page.setViewportSize({width, height: 900});
    const state = await page.evaluate(() => {
      const host = document.querySelector('#entry'), wrap = host.querySelector('.table-scroll');
      const table = wrap.querySelector('table'), figure = host.querySelector('.compiled-figure'), parent = wrap.parentElement;
      return {hostWidth: host.clientWidth, parentWidth: parent.clientWidth, ancestorOpen: wrap.closest('details').open, width: wrap.clientWidth, extent: wrap.scrollWidth,
        hostLeft: host.getBoundingClientRect().left, hostRight: host.getBoundingClientRect().right,
        left: wrap.getBoundingClientRect().left, right: wrap.getBoundingClientRect().right,
        rows: table.rows.length, tableTop: table.getBoundingClientRect().top,
        figureBottom: figure.getBoundingClientRect().bottom, overflow: getComputedStyle(wrap).overflowX,
        focusable: wrap.tabIndex, unchanged: JSON.stringify(tableFitEntry) === tableFitSnapshot};
    });
    observed.push({viewport: width, ...state});
    assert.equal(state.rows, 47);
    assert.equal(state.ancestorOpen, true);
    assert.ok(state.left >= state.hostLeft - 1 && state.right <= state.hostRight + 1, JSON.stringify(state));
    assert.equal(state.unchanged, true);
    assert.equal(state.focusable, 0);
    assert.equal(state.overflow, 'auto');
    if (output) { await page.evaluate(() => scrollTo(0, 0)); await page.screenshot({path: output + '/visible-' + width + '.png'}); }
    if (width === 320) {
      assert.ok(state.width >= state.parentWidth - 2, JSON.stringify(state));
      assert.ok(state.tableTop >= state.figureBottom, JSON.stringify(state));
      assert.ok(state.extent > state.width, JSON.stringify(state));
      const scroll = page.locator('.table-scroll').first();
      await scroll.evaluate(node => { node.scrollLeft = 0; });
      await scroll.focus(); await page.keyboard.press('ArrowRight');
      await page.waitForFunction(() => document.querySelector('.table-scroll').scrollLeft > 0);
    }
  }
  await page.locator('.compiled-figure figcaption a').focus();
  await page.keyboard.press('Enter');
  assert.equal(await page.evaluate(() => tableFitActions.at(-1)[0]), 'װיקיװערטערבוך:ײִדיש לעבט');

  // Deliberately oversized cells expose the indentation boundary in both directions.
  for (const direction of ['ltr', 'rtl']) {
    await page.setViewportSize({width: 320, height: 900});
    const controls = await page.evaluate(direction => {
      const host = document.querySelector('#entry'); host.replaceChildren(); host.dir = direction;
      const text = {kind: 'text', text: 'UnbreakableTableCell'.repeat(20)};
      const make = (depth, fields = {}) => ({kind: 'table', depth, spans: [], table: {
        caption: [], rows: [{cells: [{spans: [text], colspan: 1, rowspan: 1}]}], ...fields}});
      const cases = [
        {name: 'indented-auto', block: make(8)},
        {name: 'authored-width', block: make(0, {style: {width: {unit: 'px', value: 180}}})},
        {name: 'geometry-width', block: make(0, {geometry: {width: {unit: 'percent', value: 50}}})},
        {name: 'floated', block: make(0, {style: {float_side: 'left'}})},
        {name: 'inline', block: make(0, {style: {display: 'inline_table'}})},
      ];
      return cases.map(({name, block}) => {
        host.replaceChildren(Product.renderEntry({title: name, sections: [{title: 'Control', blocks: [block]}]}, () => {}, {}));
        const wrap = host.querySelector('.table-scroll'), table = wrap.querySelector('table');
        const w = wrap.getBoundingClientRect(), h = host.getBoundingClientRect();
        return {name, direction, left: w.left, right: w.right, hostLeft: h.left, hostRight: h.right,
          width: wrap.clientWidth, extent: wrap.scrollWidth, requestedWidth: wrap.style.width,
          maxWidth: wrap.style.maxWidth, tableWidth: table.style.width, float: wrap.style.cssFloat};
      });
    }, direction);
    observed.push(...controls);
    for (const c of controls) {
      if (c.name === 'indented-auto') {
        assert.ok(c.left >= c.hostLeft - 1 && c.right <= c.hostRight + 1, JSON.stringify(c));
        assert.ok(c.width > 0 && c.extent > c.width, JSON.stringify(c));
      } else {
        assert.equal(c.requestedWidth, '', JSON.stringify(c));
        assert.equal(c.maxWidth, '', JSON.stringify(c));
      }
      if (c.name === 'authored-width') assert.equal(c.tableWidth, '180px');
      if (c.name === 'geometry-width') assert.equal(c.tableWidth, '50%');
      if (c.name === 'floated') assert.equal(c.float, 'left');
    }
  }
  assert.deepEqual(errors, []);
  if (output) await writeFile(output + '/maintained-observations.json', JSON.stringify(observed, null, 2) + '\n', {flag: 'wx'});
} finally { await browser.close(); }
