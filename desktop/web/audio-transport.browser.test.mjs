import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {buildIndex, RawSource} from './blob.js';
import {readEntry, validatePublicationName} from './library.js';
import {verifyTransportAcquisition} from './audio-transport-controls.mjs';

const fixtureRoot = new URL('./testdata/or-audio/', import.meta.url);
const site = 'https://reader.test/';
const waveURL = 'https://upload.wikimedia.org/wikidict-test/inline-audio.wav';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const fixtures = [
  {
    ordinal: 686, title: 'ଅଂଶ', file: 'Or-ଅଂଶ.oga', block: 0, width: 1000, trigger: 'click',
    memberBytes: 6233, memberDigest: '5b3bb900f1fffc38003077b30a707ea1121657df5f39593270a1c6166b5d0e9e',
    payloadOffset: 35, payloadBytes: 6198, payloadDigest: 'ed510863431ab7d40bdf1fba6b1b65265fc1bda5515a5e5554cad903d5d06d76',
  },
  {
    ordinal: 3667, title: "'କ' 'ବ' 'ଚ' କରି ପଢ଼ିବା",
    file: 'Pronunciation of Odia word "\'କ\' \'ବ\' \'ଚ\' କରି ପଢ଼ିବା".ogg',
    block: 2, width: 640, trigger: 'Enter',
    memberBytes: 2021, memberDigest: 'fa5327f158ffb72ba90b48b8233f693600c6351ed571726d6d425fc68b450057',
    payloadOffset: 72, payloadBytes: 1949, payloadDigest: 'a15177bebc74f6a63517d0945c5f2c7c575ba05c5fa22dd729b7fa493ea54b72',
  },
];

async function loadFixture(spec) {
  const bytes = await readFile(new URL(spec.ordinal + '.wikblb', fixtureRoot));
  assert.equal(bytes.length, spec.memberBytes);
  assert.equal(digest(bytes), spec.memberDigest);
  const source = new RawSource(new Blob([bytes]));
  const {metadata, rows} = await buildIndex(source);
  const name = 'orwiktionary-20261001-1372a3810da5224a8d1007de41ff5f9bc16030f824f09ed65e954e00a1ade1a6.wikblb';
  validatePublicationName(name, metadata);
  assert.deepEqual(metadata, {kind:'language', language_code:'', language:'Unclassified'});
  assert.equal(rows.length, 1);
  const [row] = rows;
  assert.deepEqual([row.title, row.offset, row.length], [spec.title, spec.payloadOffset, spec.payloadBytes]);
  assert.equal(digest(await source.read(row.offset, row.length)), spec.payloadDigest);
  const entry = await readEntry([{id:name, name, metadata, rows}], {dictionary:name, title:spec.title},
    (_, record) => source.read(record.offset, record.length));
  assert.equal(entry.source_edition, 'orwiktionary');
  const {cells} = entry.sections[0].blocks[spec.block].table.rows[0];
  const [transport] = cells[1].spans;
  assert.deepEqual([transport.target, transport.text], ['File:' + spec.file, spec.file]);
  assert.deepEqual([transport.audio_control.presentation ?? 'transport', transport.audio_control.width,
    transport.audio_control.height ?? null], ['transport', {unit:'px', value:175}, null]);
  assert.deepEqual(cells[0].spans.map(span => span.text), ['ଧ୍ୱନି']);
  assert.deepEqual(cells[2].spans.map(span => [span.text, span.target]), [['(', ''], ['file', 'Image:' + spec.file], [')', '']]);
  assert.deepEqual(entry.media.filter(media => media.file === spec.file), [{file:spec.file, kind:'audio', caption:spec.file}]);
  return entry;
}

function silentWave() {
  const samples = 32000;
  const wave = Buffer.alloc(44 + samples, 128);
  wave.write('RIFF', 0);
  wave.writeUInt32LE(36 + samples, 4);
  wave.write('WAVEfmt ', 8);
  wave.writeUInt32LE(16, 16);
  wave.writeUInt16LE(1, 20);
  wave.writeUInt16LE(1, 22);
  wave.writeUInt32LE(8000, 24);
  wave.writeUInt32LE(8000, 28);
  wave.writeUInt16LE(1, 32);
  wave.writeUInt16LE(8, 34);
  wave.write('data', 36);
  wave.writeUInt32LE(samples, 40);
  return wave;
}

async function runTransport(browser, spec, entry, bundle, stylesheet, font, wave) {
  const context = await browser.newContext({viewport:{width:spec.width, height:800}, serviceWorkers:'block'});
  try {
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    const requests = [], refused = [];
    let showError = false, held = null;
    await context.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.href === site) return route.fulfill({contentType:'text/html', body:'<!doctype html><meta charset="utf-8"><main></main>'});
      if (url.href === site + 'reader.ttf') return route.fulfill({contentType:'font/ttf', body:font});
      if (url.origin === 'https://commons.wikimedia.org' && url.pathname === '/w/api.php' &&
        url.searchParams.get('titles') === 'File:' + spec.file) {
        requests.push('File:' + spec.file);
        if (showError) return route.fulfill({status:503, headers:{'Access-Control-Allow-Origin':'*'}, body:'Unavailable'});
        return route.fulfill({headers:{'Access-Control-Allow-Origin':'*'}, json:{query:{pages:[{imageinfo:[{url:waveURL, mime:'audio/wav'}]}]}}});
      }
      if (url.href === waveURL && held === null) {
        requests.push('wave');
        held = route;
        return;
      }
      refused.push(url.href);
      await route.abort();
    });
    await page.goto(site);
    await page.addStyleTag({content:stylesheet});
    await page.addScriptTag({content:bundle});
    await page.evaluate(() => {
      window.revokedAudioURLs = [];
      const revoke = URL.revokeObjectURL.bind(URL);
      URL.revokeObjectURL = url => { window.revokedAudioURLs.push(url); revoke(url); };
    });
    const render = allowAudio => page.evaluate(({entry, allowAudio}) => {
      const settings = {allowAudio, allowImages:false, mediaCacheMb:0, collapsePronunciation:false,
        collapseEtymology:false, collapseOtherSections:false};
      window.followed = [];
      const element = Renderer.renderEntry(entry, (...args) => window.followed.push(args), settings,
        (media, canonical) => Renderer.mediaView(media, settings, entry.source_edition, canonical));
      document.querySelector('main').replaceChildren(element);
    }, {entry, allowAudio});
    const root = page.locator('.inline-audio-control');
    const audio = root.locator('audio');
    const button = root.locator('button');
    await render(false);
    assert.ok(await button.isDisabled());
    await audio.focus();
    await page.keyboard.press('Enter');
    assert.deepEqual(requests, []);

    await render(true);
    assert.equal(await audio.getAttribute('src'), null);
    const row = root.locator('xpath=ancestor::tr[1]');
    assert.deepEqual(await row.evaluate(el => [el.cells[0].textContent, el.cells[2].textContent]), ['ଧ୍ୱନି', '(file)']);
    await row.getByRole('link', {name:'file', exact:true}).focus();
    await page.keyboard.press('Enter');
    assert.deepEqual(await page.evaluate(() => window.followed), [['Image:' + spec.file]]);
    assert.deepEqual(requests, []);
    await page.evaluate(() => document.fonts.ready);
    const geometry = await audio.evaluate(el => ({width:el.getBoundingClientRect().width, height:el.style.height}));
    assert.deepEqual(geometry, {width:175, height:''});

    const retry = spec.trigger === 'click';
    if (retry) {
      showError = true;
      await button.click();
      await page.waitForFunction(() => document.querySelector('.inline-audio-control').dataset.mediaState === 'error');
      assert.ok(await button.evaluate(el => document.activeElement === el));
      assert.equal(await audio.getAttribute('src'), null);
      showError = false;
    }
    const waitHeld = async () => {
      for (let i = 0; held === null && i < 200; i++) await new Promise(resolve => setTimeout(resolve, 25));
      assert.ok(held, 'Controlled audio download was never requested');
    };
    const release = async () => {
      assert.ok(held);
      const request = held;
      held = null;
      await request.fulfill({headers:{'Access-Control-Allow-Origin':'*'}, contentType:'audio/wav', body:wave});
    };
    const result = await verifyTransportAcquisition(page, {label:spec.file, trigger:spec.trigger, retry, waitHeld, release});
    assert.deepEqual(requests, retry ? ['File:' + spec.file, 'File:' + spec.file, 'wave'] : ['File:' + spec.file, 'wave']);
    const removed = await audio.elementHandle();
    await page.evaluate(() => document.querySelector('main').replaceChildren());
    await page.waitForFunction(el => el.paused && !el.hasAttribute('src'), removed);
    assert.deepEqual(await page.evaluate(() => window.revokedAudioURLs), [result.source]);
    assert.deepEqual(refused, []);
  } finally {
    await context.close();
  }
}

const args = process.argv.slice(2);
assert.ok(args.length === 0 || args.length === 1 && args[0] === '--fixtures-only', 'Only --fixtures-only is supported');
const entries = await Promise.all(fixtures.map(loadFixture));
if (args.length === 1) {
  console.log('Verified retained OR Writer24 fixtures 686 and 3667');
} else {
  const [{build}, {chromium}] = await Promise.all([import('esbuild'), import('playwright')]);
  const {outputFiles:[bundle]} = await build({
    stdin:{contents:"export {renderEntry} from './renderer.js'; export {mediaView} from './media.js';",
      resolveDir:fileURLToPath(new URL('./', import.meta.url))}, bundle:true,
    format:'iife', globalName:'Renderer', write:false,
  });
  const [stylesheet, font] = await Promise.all([
    readFile(new URL('./style.css', import.meta.url), 'utf8'),
    readFile(new URL('./reader.ttf', import.meta.url)),
  ]);
  const browser = await chromium.launch({executablePath:process.env.CHROMIUM || '/opt/brave-bin/brave',
    headless:true, args:['--mute-audio', '--no-sandbox', '--disable-dev-shm-usage']});
  try {
    const wave = silentWave();
    for (let i = 0; i < fixtures.length; i++) await runTransport(browser, fixtures[i], entries[i], bundle.text, stylesheet, font, wave);
  } finally {
    await browser.close();
  }
}
