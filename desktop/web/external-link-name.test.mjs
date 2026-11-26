import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spans} from './renderer.js';

// Exercise DOM construction, naming attributes and layout inputs through spans().
// The existing action-groups unit uses the same small DOM construction approach.
class Element {
  constructor(tag, text = '') {
    this.tagName = tag.toUpperCase();
    this.nodeType = tag === '#text' ? 3 : tag === '#fragment' ? 11 : 1;
    this.value = text;
    this.children = [];
    this.attributes = {};
    this.style = {};
    Object.defineProperty(this.style, 'setProperty', {
      value(name, value) { this[name] = value; }
    });
    this.dataset = {};
    this.listeners = {};
    this.classList = {
      add: (...names) => { this.className = [this.className ?? '', ...names].join(' ').trim(); }
    };
  }
  get firstChild() { return this.children[0] ?? null; }
  set textContent(value) {
    this.value = '';
    this.children = value === '' ? [] : [new Element('#text', value)];
  }
  get textContent() { return this.value + this.children.map(child => child.textContent).join(''); }
  append(...nodes) {
    for (const child of nodes) {
      this.children.push(...(child.nodeType === 11 ? child.children : [child]));
    }
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(name, listener) { this.listeners[name] = listener; }
}
const descendants = root => [root, ...root.children.flatMap(descendants)];
function render(span, {preserve = false, withinSummary = false, followingText = 'following'} = {}) {
  const previous = globalThis.document;
  globalThis.document = {
    createElement: tag => new Element(tag),
    createTextNode: text => new Element('#text', text),
    createDocumentFragment: () => new Element('#fragment')
  };
  try {
    // A following visible run keeps ordinary trailing-space compaction out of
    // the case while still exercising the normal preserve=false entry point.
    return spans([span, {kind: 'text', text: followingText, target: ''}],
      () => {}, preserve, null, withinSummary);
  } finally {
    globalThis.document = previous;
  }
}
const target = 'https://gd.wikipedia.org/wiki/Edmund_Crosby_Quiggin';
const external = (text, extra = {}) => ({kind: 'external_link', target, text, ...extra});
function check(span, expectedName, options = {}) {
  const input = structuredClone(span);
  const current = render(span, options);
  const currentLinks = descendants(current).filter(node => node.tagName === 'A');
  assert.equal(currentLinks.length, 1);
  const link = currentLinks[0];
  assert.equal(link.href, target);
  assert.equal(link.target, '_blank');
  assert.equal(link.rel, 'noopener noreferrer');
  assert.equal(link.attributes['aria-label'], expectedName);
  assert.equal(link.title, span.tooltip);
  const group = span.inline_action_group ?? span.inline_box_group;
  const authoredText = group ? group.spans.map(child => child.text + (child.trail ?? '')).join('') : span.text;
  assert.equal(link.textContent, authoredText);
  assert.equal(current.textContent, authoredText + (span.trail ?? '') + (options.followingText ?? 'following'));
  assert.deepEqual(span, input);
  return {link, current};
}

for (const [name, text] of [['space', ' '], ['NBSP', '\u00a0'], ['mixed whitespace', '\t \u00a0\n']]) {
  test(`ordinary ${name} external link gains a name and preserves its DOM`, () => {
    const {link} = check(external(text), target);
    assert.equal(link.textContent, text);
  });
}
test('preserved-flow whitespace uses explanation before the URL', () => {
  check(external('\u00a0', {explanation: '  Source biography  '}), 'Source biography',
    {preserve: true});
});
test('blank tooltip and explanation still fall back to the URL', () => {
  check(external('\u00a0', {tooltip: ' \u00a0', explanation: ' \t'}), target);
});
test('visible text and nonblank Unicode names retain their authored DOM', () => {
  for (const text of ['Edmund Crosby Quiggin', ' léigh ', '字', '\u00a0visible\u00a0']) {
    const {link} = check(external(text, {bold: true}), undefined);
    assert.equal(link.textContent, text);
    const bold = descendants(link).filter(node => node.tagName === 'STRONG');
    assert.equal(bold.length, 1);
    assert.equal(bold[0].textContent, text);
  }
});
test('tooltip naming remains authored', () => {
  const {link} = check(external('\u00a0', {tooltip: 'Biography', explanation: 'Other'}), undefined);
  assert.equal(link.title, 'Biography');
});
test('image alt and tooltip retain their names and sizing without a URL override', () => {
  for (const description of [{alt: 'Portrait'}, {tooltip: 'Portrait tooltip'}, {alt: ''}]) {
    const {current} = check(external('', {
      image: {file: 'Portrait.svg', width_px: 18, height_px: 12, ...description}
    }), undefined);
    const image = descendants(current).find(node => node.tagName === 'IMG');
    assert.equal(image.style.width, '18px');
    assert.equal(image.style.height, '12px');
    assert.equal(image.attributes.alt, description.alt);
    assert.equal(image.attributes.title, description.tooltip);
  }
});
for (const groupKind of ['inline_action_group', 'inline_box_group']) {
  test(`${groupKind} keeps existing blank and visible naming behavior`, () => {
    for (const text of ['\u00a0', 'group label']) {
      const group = {spans: [{kind: 'text', target: '', text}]};
      if (groupKind === 'inline_box_group') {
        const sides = ['top', 'right', 'bottom', 'left'];
        group.padding = Object.fromEntries(sides.map(side => [side, {unit: 'px', value: 2}]));
        group.border = Object.fromEntries(sides.map(side => [side, {kind: 'none'}]));
        group.overlays = [];
      }
      const owner = external('', {[groupKind]: group});
      const {link} = check(owner, text.trim() ? undefined : target);
      const {link: tooltipLink} = check({...owner, tooltip: 'Group tooltip'}, undefined);
      for (const rendered of [link, tooltipLink]) {
        const child = descendants(rendered).find(node => node.tagName === 'SPAN' &&
          node.style.fontWeight === 'normal' && node.style.fontStyle === 'normal');
        assert.ok(child, 'Grouped text retains its normal font styles');
        assert.equal(child.textContent, text);
        if (groupKind === 'inline_box_group') {
          const box = descendants(rendered).find(node => node.className === 'compiled-inline-box');
          assert.ok(box);
          assert.equal(box.textContent, text);
          assert.equal(box.style.boxDecorationBreak, 'slice');
          assert.equal(box.style.boxSizing, 'content-box');
          for (const side of ['Top', 'Right', 'Bottom', 'Left']) {
            assert.equal(box.style['padding' + side], '2px');
            assert.equal(box.style['border-' + side.toLowerCase()], 'none');
          }
        }
      }
    }
  });
}
test('summary links retain their click handler and whitespace text', () => {
  const {link} = check(external('\u00a0'), target, {withinSummary: true});
  let stopped = 0;
  link.listeners.click({stopPropagation() { stopped++; }});
  assert.equal(stopped, 1);
  assert.equal(link.textContent, '\u00a0');
});


test('ordinary external NBSP links get a name despite visible outer trail text', () => {
  const {link, current} = check(external('\u00a0', {trail: 'outside label'}), target);
  assert.equal(link.textContent, '\u00a0');
  assert.equal(current.children[1].textContent, 'outside label');
});

for (const [description, text] of [['blank', '\u00a0'], ['nonblank', 'group label']]) {
  test(`${description} action groups reject a nonempty outer trail`, () => {
    const owner = external('', {
      trail: 'outside label',
      inline_action_group: {spans: [{kind: 'text', target: '', text}]}
    });
    const input = structuredClone(owner);
    // The compiled group contract forbids outer trails before rendering begins.
    assert.throws(() => render(owner), /Invalid compiled inline action group/);
    assert.deepEqual(owner, input);
  });
  test(`${description} action groups keep following sibling text outside their name`, () => {
    const owner = external('', {
      inline_action_group: {spans: [{kind: 'text', target: '', text}]}
    });
    const {link, current} = check(owner, text.trim() ? undefined : target,
      {followingText: 'outside label'});
    assert.equal(link.textContent, text);
    assert.equal(current.children[2].textContent, 'outside label');
  });
}

test('internal whitespace links use their destination despite visible outer trails', () => {
  for (const fragment of [undefined, 'Sense']) {
    const owner = {
      kind: 'link', target: 'Entry', target_fragment: fragment,
      text: '\u00a0', trail: 'outside label'
    };
    const input = structuredClone(owner);
    const current = render(owner);
    const links = descendants(current).filter(node => node.tagName === 'A');
    assert.equal(links.length, 1);
    const name = fragment === undefined ? 'Entry' : 'Entry#Sense';
    assert.equal(links[0].attributes['aria-label'], name);
    assert.equal(links[0].href, '#' + name);
    assert.equal(links[0].textContent, '\u00a0');
    assert.equal(current.children[1].textContent, 'outside label');
    assert.equal(current.textContent, '\u00a0outside labelfollowing');
    assert.deepEqual(owner, input);
  }
});

for (const groupKind of ['inline_action_group', 'inline_box_group']) {
  test(`${groupKind} child trails remain inside the anchor and provide its name`, () => {
    const group = {spans: [{kind: 'text', target: '', text: '\u00a0', trail: 'child label'}]};
    if (groupKind === 'inline_box_group') {
      const sides = ['top', 'right', 'bottom', 'left'];
      group.padding = Object.fromEntries(sides.map(side => [side, {unit: 'px', value: 2}]));
      group.border = Object.fromEntries(sides.map(side => [side, {kind: 'none'}]));
      group.overlays = [];
    }
    const {link} = check(external('', {[groupKind]: group}), undefined);
    assert.equal(link.textContent, '\u00a0child label');
  });
}
