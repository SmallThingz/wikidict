import assert from 'node:assert/strict';
import test from 'node:test';
import {spans} from './renderer.js';

// Small DOM surface for locating the semantic font owner. Browser controls
// separately compare the computed request under different inherited families.
class Node {
  constructor(type, tag = '', text = '') {
    this.nodeType = type; this.tagName = tag.toUpperCase(); this.data = text;
    this.children = []; this.style = {}; this.attributes = {};
    this.classList = {add() {}};
  }
  append(...nodes) {
    for (let node of nodes) {
      if (typeof node === 'string') node = new Node(3, '', node);
      if (node.nodeType === 11) { this.append(...node.children); continue; }
      node.parentNode = this; this.children.push(node);
    }
  }
  set textContent(text) { this.children = []; if (text) this.append(new Node(3, '', text)); }
  get textContent() { return this.nodeType === 3 ? this.data : this.children.map(node => node.textContent).join(''); }
  get firstChild() { return this.children[0] ?? null; }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener() {}
}
globalThis.document = {
  createElement: tag => new Node(1, tag),
  createTextNode: text => new Node(3, '', text),
  createDocumentFragment: () => new Node(11),
};
const descendants = node => [node, ...node.children.flatMap(descendants)];
const span = kind => ({kind, text: kind === 'line_break' ? '' : 'alpha', trail: 'omega',
  target: kind === 'external_link' ? 'https://example.invalid/Font' : kind === 'link' ? 'Font' : ''});
const familyAt = node => {
  for (let current = node.parentNode; current; current = current.parentNode)
    if (current.style.fontFamily) return current.style.fontFamily;
  return null;
};

test('font requests cover trailing text for every ordinary span kind', () => {
  for (const kind of ['text', 'link', 'external_link', 'line_break']) {
    for (const [value, css] of [
      [{stack: {names: ['Times New Roman'], fallback: 'css_default'}}, '"Times New Roman"'],
      ['sans_serif', 'sans-serif'],
      [{stack: {names: ['Arial'], fallback: 'serif'}}, '"Arial",serif'],
    ]) {
      const input = {...span(kind), font_family: value}, snapshot = structuredClone(input);
      const root = spans([input]);
      const trail = descendants(root).find(node => node.nodeType === 3 && node.data === 'omega');
      assert.ok(trail); assert.equal(familyAt(trail), css);
      assert.deepEqual(input, snapshot);
    }
  }
});

test('absent font requests remain absent on trailing text', () => {
  for (const kind of ['text', 'link', 'external_link', 'line_break']) {
    const root = spans([span(kind)]);
    const trail = descendants(root).find(node => node.nodeType === 3 && node.data === 'omega');
    assert.ok(trail); assert.equal(familyAt(trail), null);
  }
});
