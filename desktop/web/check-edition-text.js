const visibleText = span => span && typeof span === 'object' && ['text', 'link', 'external_link'].includes(span.kind) &&
  typeof span.text === 'string' && span.font_scale !== 0;

export const normalizeVisibleText = text => text.normalize('NFC').replace(/\s+/gu, ' ').trim();

export function expectedTextFragments(...roots) {
  const expected = new Set();
  function add(text) {
    if (!text) return;
    const fragment = normalizeVisibleText(text);
    if (fragment.length > 2) expected.add(fragment);
  }
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    if (!Array.isArray(value)) {
      for (const child of Object.values(value)) {
        if (visibleText(child)) add(child.text + (child.trail || ''));
        visit(child);
      }
      return;
    }
    let pending = '';
    for (const child of value) {
      const text = visibleText(child) ? child.text + (child.trail || '') : '';
      // A combining mark may be stored separately from its base. The browser
      // presents them together, even across a formatting or link boundary.
      if (!/^\p{M}/u.test(text)) {
        add(pending);
        pending = '';
      }
      pending += text;
      visit(child);
    }
    add(pending);
  }
  visit(roots);
  return expected;
}
