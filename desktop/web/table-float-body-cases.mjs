import assert from 'node:assert/strict';

// The fixture is a complete ordinary compiled record, not hand-authored DOM.
export async function checkTableFloatBody(page, fixture) {
  await page.evaluate(bytes => {
    const host = document.querySelector('#entry');
    host.removeAttribute('dir');
    const entry = Product.decode(new Uint8Array(bytes), {
      kind: 'language', title: 'crepans', language: 'latino', language_code: 'la',
    });
    window.floatBodyEntry = entry;
    window.floatBodySnapshot = JSON.stringify(entry);
    window.floatBodyRender = value => {
      host.replaceChildren(Product.renderEntry(value, () => {}, {collapseOtherSections: false}));
      for (const details of host.querySelectorAll('details')) details.open = true;
    };
    floatBodyRender(entry);
  }, [...fixture]);

  const measure = () => page.evaluate(() => {
    const host = document.querySelector('#entry');
    const table = host.querySelector('.compiled-table-float');
    const rect = node => {
      const {left, right, top, bottom, width} = node.getBoundingClientRect();
      return {left, right, top, bottom, width};
    };
    const summary = [...host.querySelectorAll('summary')].find(x => x.textContent.includes('Voce verbale'));
    const body = summary.parentElement.querySelector('.block');
    function wordRects(root, word) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode, start = node.data.indexOf(word);
        if (start < 0) continue;
        const range = document.createRange();
        range.setStart(node, start); range.setEnd(node, start + word.length);
        return [...range.getClientRects()].map(r => ({left:r.left, right:r.right, top:r.top, bottom:r.bottom}));
      }
      throw new Error('Missing expected word: ' + word);
    }
    return {
      table: rect(table), summary: rect(summary),
      words: ['Voce', 'verbale'].map(word => ({word, rects:wordRects(summary, word)}))
        .concat({word:'crepans', rects:wordRects(body, 'crepans')}),
      documentWidth: document.documentElement.scrollWidth,
      viewportWidth: innerWidth, float: getComputedStyle(table).float,
      rows: table.querySelectorAll('tr').length,
      unchanged: JSON.stringify(floatBodyEntry) === floatBodySnapshot,
    };
  });
  const settle = () => page.evaluate(() => new Promise(resolve =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const observed = [];
  for (const width of [1000, 360, 1000]) {
    await page.setViewportSize({width, height:1100});
    await settle();
    const state = await measure();
    observed.push({name:'genuine-crepans-body', width, ...state});
    assert.equal(state.rows, 17);
    assert.equal(state.float, 'right');
    assert.equal(state.unchanged, true);
    assert.ok(state.documentWidth <= width, JSON.stringify(state));
    for (const word of state.words) {
      assert.equal(word.rects.length, 1, JSON.stringify({width, ...word}));
      const r = word.rects[0], t = state.table;
      assert.ok(r.right <= t.left || r.left >= t.right || r.top >= t.bottom || r.bottom <= t.top,
        'Text overlaps the table: ' + JSON.stringify({width, word, table:t}));
      if (width === 360) assert.ok(r.top >= t.bottom, JSON.stringify({word, table:t}));
    }
    if (width === 1000) assert.ok(state.summary.top < state.table.bottom,
      'The desktop heading should still flow beside the table');
  }

  // A browser-level negative control recreates the exact former CSS defect.
  await page.setViewportSize({width:360, height:1100});
  await page.evaluate(() => {
    const style = document.createElement('style'); style.id = 'old-float-heading';
    style.textContent = '.compiled-table-flow summary{width:auto;max-width:none}' +
      '.compiled-table-flow summary>.heading-label,.compiled-table-flow summary>.heading-label a{overflow-wrap:anywhere}';
    document.head.append(style);
  });
  await settle();
  const old = await measure();
  assert.ok(old.words.every(word => word.rects.length > 1), JSON.stringify(old));
  observed.push({name:'old-css-negative-control', ...old});
  await page.evaluate(() => document.querySelector('#old-float-heading').remove());
  await settle();

  // Native disclosure keyboard interaction must survive the intrinsic width.
  const heading = page.locator('#entry summary').filter({hasText:'Voce verbale'});
  await heading.focus();
  await page.keyboard.press('Enter');
  assert.equal(await heading.evaluate(node => node.parentElement.open), false);
  await page.keyboard.press('Enter');
  assert.equal(await heading.evaluate(node => node.parentElement.open), true);
  await settle();
  assert.ok((await measure()).words.every(word => word.rects.length === 1));

  // Synthetic stress only: a long unbreakable heading must wrap within the page.
  await page.evaluate(() => {
    const entry = structuredClone(floatBodyEntry), title = 'W'.repeat(120);
    entry.sections[1].title = title;
    entry.sections[1].blocks[0].spans.find(span => span.text === 'Voce verbale').text = title;
    floatBodyRender(entry);
  });
  await settle();
  const long = await page.evaluate(() => {
    const heading = [...document.querySelectorAll('#entry .heading-label')]
      .find(node => node.textContent.includes('W'.repeat(120))).getBoundingClientRect();
    const table = document.querySelector('#entry .compiled-table-float').getBoundingClientRect();
    return {documentWidth:document.documentElement.scrollWidth, viewportWidth:innerWidth,
      headingTop:heading.top, headingLeft:heading.left, headingRight:heading.right, tableBottom:table.bottom,
      unchanged:JSON.stringify(floatBodyEntry) === floatBodySnapshot};
  });
  assert.ok(long.documentWidth <= long.viewportWidth && long.headingLeft >= 0 && long.headingRight <= long.viewportWidth,
    JSON.stringify(long));
  assert.ok(long.headingTop >= long.tableBottom, JSON.stringify(long));
  assert.equal(long.unchanged, true);
  observed.push({name:'synthetic-long-heading', ...long});
  return observed;
}
