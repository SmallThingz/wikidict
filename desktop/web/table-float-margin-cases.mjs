import assert from 'node:assert/strict';

// The caller supplies the maintained renderer as Product.renderEntry and the
// product stylesheet. These controls deliberately exceed the containing width.
export async function checkTableFloatMargins(page) {
  const observations = [];
  for (const width of [360, 1000]) {
    await page.setViewportSize({width, height: 900});
    for (const direction of ['ltr', 'rtl']) {
      const cases = await page.evaluate(direction => {
        const host = document.querySelector('#entry');
        host.replaceChildren(); host.dir = direction;
        const basisProbe = document.createElement('span');
        basisProbe.style.fontSize = 'var(--wikidict-normal-body-size)';
        host.append(basisProbe);
        const basis = parseFloat(getComputedStyle(basisProbe).fontSize);
        const rootFont = parseFloat(getComputedStyle(document.documentElement).fontSize);
        basisProbe.remove();
        const text = 'UnbreakableInflectedForm'.repeat(12);
        const observations = [];
        for (const floatSide of ['left', 'right']) {
          for (const variant of ['right-margin', 'both-margins', 'indented', 'percent']) {
            const depth = variant === 'indented' ? 4 : 0;
            const left = variant === 'right-margin' ? 0 : .5, right = 1;
            const margins = {top: {unit: 'px', value: 0}, right: {unit: 'em', value: right},
              bottom: {unit: 'px', value: 0}, left: {unit: 'em', value: left}};
            const table = {caption: [{kind: 'text', text: 'Inflected forms'}],
              style: {float_side: floatSide, margins},
              rows: [{cells: [0, 1].map(i => ({colspan: 1, rowspan: 1,
                spans: [{kind: 'link', text: text + i, target: 'Form' + i}]}))}]};
            if (variant === 'percent') table.geometry = {width: {unit: 'percent', value: 100}};
            const entry = {title: 'Float margin control', sections: [{title: 'Control',
              blocks: [{kind: 'table', depth, spans: [], table}]}]};
            const before = JSON.stringify(entry);
            host.replaceChildren(Product.renderEntry(entry, () => {}, {}));
            const wrap = host.querySelector('.table-scroll'), rendered = wrap.querySelector('table');
            const box = wrap.getBoundingClientRect(), parent = host.getBoundingClientRect();
            const css = getComputedStyle(wrap);
            const initial = wrap.scrollLeft;
            wrap.scrollLeft = direction === 'rtl' ? -wrap.scrollWidth : wrap.scrollWidth;
            const end = wrap.scrollLeft; wrap.scrollLeft = 0;
            observations.push({direction, floatSide, variant, depth, basis, rootFont,
              expectedLeft: left * basis + (direction === 'ltr' ? depth * .45 * rootFont : 0),
              expectedRight: right * basis + (direction === 'rtl' ? depth * .45 * rootFont : 0),
              marginLeft: parseFloat(css.marginLeft), marginRight: parseFloat(css.marginRight),
              left: box.left, right: box.right, parentLeft: parent.left, parentRight: parent.right,
              width: wrap.clientWidth, extent: wrap.scrollWidth - wrap.clientWidth,
              initial, end, restored: wrap.scrollLeft, overflow: css.overflowX, tabIndex: wrap.tabIndex,
              caption: rendered.caption.textContent, rows: rendered.rows.length,
              cells: [...rendered.rows[0].cells].map(c => ({text: c.textContent,
                colspan: c.colSpan, rowspan: c.rowSpan, href: c.querySelector('a').getAttribute('href')})),
              expectedText: [text + 0, text + 1], unchanged: before === JSON.stringify(entry)});
          }
        }
        return observations;
      }, direction);
      for (const c of cases) {
        const detail = JSON.stringify(c);
        assert.ok(c.left - c.marginLeft >= c.parentLeft - 1, detail);
        assert.ok(c.right + c.marginRight <= c.parentRight + 1, detail);
        assert.ok(Math.abs(c.marginLeft - c.expectedLeft) < .1, detail);
        assert.ok(Math.abs(c.marginRight - c.expectedRight) < .1, detail);
        assert.ok(c.width > 0 && c.extent > 0, detail);
        assert.ok(Math.abs(c.end) >= c.extent - 1, detail);
        assert.equal(c.initial, 0, detail); assert.equal(c.restored, 0, detail);
        assert.equal(c.overflow, 'auto', detail); assert.equal(c.tabIndex, 0, detail);
        assert.equal(c.caption, 'Inflected forms', detail); assert.equal(c.rows, 1, detail);
        assert.deepEqual(c.cells.map(x => x.text), c.expectedText, detail);
        assert.deepEqual(c.cells.map(x => [x.colspan, x.rowspan, x.href]),
          [[1, 1, '#Form0'], [1, 1, '#Form1']], detail);
        assert.equal(c.unchanged, true, detail);
        observations.push({viewport: width, ...c});
      }
    }
  }
  return observations;
}
