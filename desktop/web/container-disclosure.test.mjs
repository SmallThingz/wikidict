import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {
  validateContainerDisclosure,
  validateContainerDisclosureButton,
  containerDisclosureButtonOutlineColor,
  containerDisclosureItems,
  installContainerDisclosure,
} from './container-disclosure.js';

const repository = new URL('../../', import.meta.url);
const capturePath = new URL('renderer/src/format/testdata/it-disclosure-button-captured.json', repository);
const captureBytes = await readFile(capturePath);
assert.equal(createHash('sha256').update(captureBytes).digest('hex'),
  'c5b0e5998409bf5f26dae8d7dbb9160402b4ea016e07356e317a0e4f94873c4e');
const capture = JSON.parse(captureBytes);

// A narrow DOM double exercises the actual installer and its click listener.
// Browser layout, native keyboard activation and computed AX remain browser checks.
class ElementDouble extends EventTarget {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.attributes = new Map();
    this.style = {};
    this.listeners = [];
  }
  append(...children) { this.children.push(...children); }
  prepend(...children) { this.children.unshift(...children); }
  replaceChildren(...children) { this.children = children; }
  set textContent(text) { this.children = [String(text)]; }
  get textContent() {
    return this.children.map(child => typeof child === 'string' ? child : child.textContent).join('');
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
  contains(child) {
    return this === child || this.children.some(value =>
      value instanceof ElementDouble && value.contains(child));
  }
  addEventListener(name, listener, options) {
    this.listeners.push(name);
    super.addEventListener(name, listener, options);
  }
  click() { this.dispatchEvent(new Event('click')); }
}

function owner(policy = structuredClone(capture)) {
  return {
    style: {},
    blocks: [
      {kind: 'paragraph', spans: [{kind: 'text', text: 'Heading'}]},
      {kind: 'container', container: {style: {}, blocks: []}},
    ],
    disclosure: policy,
  };
}

const domContexts = new WeakSet();
function install(t, value = owner()) {
  if (!domContexts.has(t)) {
    domContexts.add(t);
    const previousElement = Object.getOwnPropertyDescriptor(globalThis, 'Element');
    const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document');
    globalThis.Element = ElementDouble;
    globalThis.document = {createElement: tag => new ElementDouble(tag)};
    t.after(() => {
      if (previousElement) Object.defineProperty(globalThis, 'Element', previousElement);
      else delete globalThis.Element;
      if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument);
      else delete globalThis.document;
    });
  }
  const host = new ElementDouble('div');
  const sibling = new ElementDouble('p');
  sibling.textContent = 'Heading';
  const content = new ElementDouble('div');
  content.textContent = 'Original content';
  host.append(sibling, content);
  const result = installContainerDisclosure(host, content, value);
  return {host, sibling, content, result, style: host.children[0], labelStyle: host.children[1]};
}

function declarations(sheet, selector) {
  const rule = sheet.split('}').find(value => value.startsWith(selector + '{'));
  assert.ok(rule, `Missing exact rule ${selector}`);
  return rule.slice(selector.length + 1).split(';').filter(Boolean);
}

test('captured typed button validates and item accounting preserves optional nulls', () => {
  const value = owner();
  const before = JSON.stringify(value);
  validateContainerDisclosure(value);
  assert.equal(containerDisclosureItems(value), 5);
  assert.equal(JSON.stringify(value), before);
  value.disclosure.button.outline_colors = null;
  assert.equal(containerDisclosureItems(value), 5);
  value.disclosure.button.outline_colors = {
    unfocused: {kind: 'rgb', value: '#010203'},
    focused: {kind: 'rgb', value: '#040506'},
  };
  assert.equal(containerDisclosureItems(value), 6);
});

test('absent or null disclosure adds no control, styles, attributes or item charge', t => {
  for (const value of [{style: {}, blocks: []}, {style: {}, blocks: [], disclosure: null}]) {
    const {host, sibling, content, result} = install(t, value);
    assert.equal(result, null);
    assert.deepEqual(host.children, [sibling, content]);
    assert.equal(content.attributes.size, 0);
    assert.equal(containerDisclosureItems(value), 0);
    assert.deepEqual(content.listeners, []);
  }
});

test('real button contract toggles only its content and retains labels, ARIA and source data', t => {
  const value = owner();
  const before = JSON.stringify(value);
  const {result: {button}, content, sibling} = install(t, value);
  assert.equal(button.tagName, 'BUTTON');
  assert.equal(button.type, 'button');
  assert.equal(button.textContent, 'Mostra');
  assert.equal(button.getAttribute('aria-expanded'), 'false');
  assert.deepEqual(button.ariaControlsElements, [content]);
  assert.equal(content.getAttribute('hidden'), 'until-found');
  assert.equal(content.getAttribute('id'), null);
  assert.deepEqual(button.listeners, ['click']);
  button.click();
  assert.equal(button.textContent, 'Nascondi');
  assert.equal(button.getAttribute('aria-expanded'), 'true');
  assert.equal(content.getAttribute('hidden'), null);
  assert.equal(content.textContent, 'Original content');
  assert.equal(sibling.getAttribute('hidden'), null);
  button.click();
  assert.equal(content.getAttribute('hidden'), 'until-found');
  content.dispatchEvent(new Event('beforematch'));
  assert.equal(button.textContent, 'Nascondi');
  assert.equal(button.getAttribute('aria-expanded'), 'true');
  assert.equal(JSON.stringify(value), before);
});

test('native keyboard activation remains delegated to the button click contract', t => {
  const {result: {button}, content} = install(t);
  button.dispatchEvent(new Event('keydown'));
  button.dispatchEvent(new Event('keyup'));
  assert.equal(content.getAttribute('hidden'), 'until-found');
  assert.deepEqual(button.listeners, ['click']);
  assert.equal(button.getAttribute('role'), null);
  assert.equal(button.getAttribute('tabindex'), null);
  button.click();
  assert.equal(content.getAttribute('hidden'), null);
});

test('source font, box and float override the current general button style through scoped rules', async t => {
  const {result: {button}, style} = install(t);
  const selector = '.' + button.className.split(' ')[0];
  const rule = declarations(style.textContent, selector);
  for (const declaration of [
    'box-sizing:border-box', 'appearance:auto', 'font-family:"Arial"',
    'font-size:13.3333px', 'font-weight:400', 'font-style:normal',
    'line-height:normal', 'padding:1px 6px 1px 6px', 'border-radius:0',
    'float:right', 'color:#000000', 'margin:0', 'width:auto', 'height:auto',
  ]) assert.ok(rule.includes(declaration), declaration);
  assert.equal(button.style.direction, 'ltr');
  const productCSS = await readFile(new URL('desktop/web/style.css', repository), 'utf8');
  assert.match(productCSS, /button\{[^}]*padding:12px/);
  assert.match(productCSS, /button:focus-visible[^}]*outline:2px solid/);
  assert.deepEqual(declarations(style.textContent, selector + ':focus-visible'),
    ['outline:1px auto #3366cc', 'outline-offset:0px']);
});

test('all four source paint states and label states use whole-button pseudo classes', t => {
  const value = owner();
  const names = ['normal', 'hover', 'active', 'hover_active'];
  const colors = ['#010101', '#020202', '#030303', '#040404'];
  names.forEach((name, index) => {
    value.disclosure.button[name].background.value = colors[index];
    value.disclosure.expand_run.paint[name].foreground = colors[index];
  });
  const {result: {button}, style, labelStyle} = install(t, value);
  const selector = '.' + button.className.split(' ')[0];
  ['', ':hover', ':active', ':hover:active'].forEach((pseudo, index) => {
    const rule = declarations(style.textContent, selector + pseudo);
    assert.ok(rule.includes('background-color:' + colors[index]));
    const border = index < 2 ? 'outset' : 'inset';
    for (const side of ['top', 'right', 'bottom', 'left'])
      assert.ok(rule.includes(`border-${side}:2px ${border} #000000`));
    assert.ok(declarations(labelStyle.textContent, selector + pseudo + ' > .compiled-disclosure-run')
      .includes('color:' + colors[index]));
  });
  assert.doesNotMatch(labelStyle.textContent, /compiled-disclosure-run:hover/);
});

test('focused hover-active underline wins only when underline_on_focus is true', t => {
  // Evaluate only emitted label selectors for the simultaneous focused,
  // hovered, active state. This checks source specificity, not browser paint.
  const focusedActiveUnderline = sheet => {
    let winner = null;
    for (const match of sheet.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selector = match[1], body = match[2];
      assert.match(selector, /^\.compiled-disclosure-\d+(?::(?:focus|hover|active))* > \.compiled-disclosure-run$/);
      const underline = /(?:^|;)text-decoration-line:(underline|none)(?:;|$)/.exec(body);
      if (!underline) continue;
      const specificity = [...selector.matchAll(/[.:][a-zA-Z_][\w-]*/g)].length;
      if (winner === null || specificity >= winner.specificity)
        winner = {specificity, value: underline[1]};
    }
    assert.ok(winner);
    return winner;
  };
  for (const enabled of [true, false]) {
    const value = owner();
    for (const run of [value.disclosure.expand_run, value.disclosure.collapse_run]) {
      run.paint.underline_on_focus = enabled;
      for (const state of ['normal', 'hover', 'active', 'hover_active']) run.paint[state].underline = false;
    }
    const {result: {button}, labelStyle} = install(t, value);
    const selector = '.' + button.className.split(' ')[0];
    for (const expanded of [false, true]) {
      if (expanded) button.click();
      const css = labelStyle.textContent;
      assert.doesNotMatch(css, /!important/);
      assert.deepEqual(focusedActiveUnderline(css), {specificity: enabled ? 5 : 4, value: enabled ? 'underline' : 'none'});
      if (enabled) assert.deepEqual(declarations(css, selector + ':focus:hover:active > .compiled-disclosure-run'),
        ['text-decoration-line:underline']);
      else assert.doesNotMatch(css, /:focus/);
    }
  }
});

test('unspecified focus emits no outline reset for absent or null optional fields', t => {
  for (const focus of ['absent', 'null']) for (const colors of ['absent', 'null']) {
    const value = owner(), button = value.disclosure.button;
    if (focus === 'absent') delete button.focus_visible;
    else button.focus_visible = null;
    if (colors === 'absent') delete button.outline_colors;
    else button.outline_colors = null;
    const {style, labelStyle, result} = install(t, value);
    assert.doesNotMatch(style.textContent + labelStyle.textContent,
      /(?:^|[;{])outline(?:-[a-z-]+)?:/);
    assert.doesNotMatch(style.textContent, /:focus/);
    assert.equal(Object.keys(result.button.style).some(key => key.startsWith('outline')), false);
    assert.equal(containerDisclosureButtonOutlineColor(button, true, true), null);
  }
});

test('explicit focus colors preserve unknown absence and visible-focus precedence', t => {
  const value = owner();
  const button = value.disclosure.button;
  assert.equal(containerDisclosureButtonOutlineColor(button, false, false), null);
  button.outline_colors = null;
  assert.equal(containerDisclosureButtonOutlineColor(button, true, false), null);
  button.outline_colors = {
    unfocused: {kind: 'rgb', value: '#010203'},
    focused: {kind: 'rgb', value: '#040506'},
  };
  assert.deepEqual(containerDisclosureButtonOutlineColor(button, false, false), button.outline_colors.unfocused);
  assert.deepEqual(containerDisclosureButtonOutlineColor(button, true, false), button.outline_colors.focused);
  assert.deepEqual(containerDisclosureButtonOutlineColor(button, true, true), button.focus_visible.outline.color);
  assert.throws(() => containerDisclosureButtonOutlineColor(button, false, true));
  const installed = install(t, value);
  const css = installed.style.textContent;
  const selector = '.' + installed.result.button.className.split(' ')[0];
  assert.deepEqual(declarations(css, selector + ':not(:focus)'), ['outline-color:#010203']);
  assert.deepEqual(declarations(css, selector + ':focus'), ['outline-color:#040506']);
  assert.ok(css.indexOf(':focus-visible') > css.indexOf(':focus{'));
});

test('UTF-8 run boundaries preserve label content and reject broken code-point ranges', t => {
  const value = owner();
  value.disclosure.expand_label = 'aé🙂z';
  value.disclosure.expand_run.start = 1;
  value.disclosure.expand_run.end = 7;
  const {result: {button}} = install(t, value);
  assert.equal(button.textContent, 'aé🙂z');
  assert.equal(button.children[1].textContent, 'é🙂');
  for (const [start, end] of [[2, 7], [1, 5], [7, 7], [0, 9]]) {
    const bad = structuredClone(value);
    Object.assign(bad.disclosure.expand_run, {start, end});
    assert.throws(() => validateContainerDisclosure(bad));
  }
});

test('typed consumer rejects unsupported button values and foreign child ownership', t => {
  const mutations = [
    p => { p.button.appearance = 'link'; },
    p => { p.button.font_family.name = 'sans-serif'; },
    p => { p.button.font_size.unit = 'em'; },
    p => { p.button.font_size.value = Infinity; },
    p => { p.button.font_weight = 700; },
    p => { p.button.font_italic = true; },
    p => { p.button.line_height = {multiplier: 1.2}; },
    p => { p.button.padding.left.value = -1; },
    p => { p.button.active.border.top = {solid: {width: {unit: 'px', value: 1}, paint: {current_color: {}}}}; },
    p => { p.button.normal.background = {kind: 'current_color'}; },
    p => { p.button.focus_visible.mode = 'solid'; },
    p => { p.button.focus_visible.outline.radius.value = 1; },
    p => { p.button.outline_colors = {unfocused: {kind: 'transparent'}, focused: {kind: 'rgb', value: '#000000'}}; },
    p => { p.button.extra = true; },
    p => { p.button = null; },
    p => { delete p.button; },
    p => { p.focus = {}; },
    p => { p.content_index = 0; },
    p => { p.content_index = 2; },
    p => { p.expand_label = 'bad\nlabel'; },
    p => { p.direction = 'auto'; },
  ];
  for (const mutate of mutations) {
    const value = owner();
    mutate(value.disclosure);
    assert.throws(() => validateContainerDisclosure(value));
  }
  assert.throws(() => validateContainerDisclosureButton(null));
  const installed = install(t);
  assert.throws(() => installContainerDisclosure(installed.host, new ElementDouble('div'), owner()));
});

test('explicit appearance none preserves the typed box and button behavior without native chrome', t => {
  const value = owner();
  value.disclosure.button.appearance = 'none';
  const before = JSON.stringify(value);
  const {result: {button}, style, content} = install(t, value);
  const selector = '.' + button.className.split(' ')[0];
  const rule = declarations(style.textContent, selector);
  assert.ok(rule.includes('appearance:none'));
  assert.ok(!rule.includes('appearance:auto'));
  const native = install(t);
  const nativeSelector = '.' + native.result.button.className.split(' ')[0];
  assert.deepEqual(rule.filter(x => !x.startsWith('appearance:')),
    declarations(native.style.textContent, nativeSelector).filter(x => !x.startsWith('appearance:')));
  assert.equal(button.tagName, 'BUTTON');
  assert.equal(button.type, 'button');
  assert.equal(button.textContent, 'Mostra');
  assert.equal(content.getAttribute('hidden'), 'until-found');
  button.click();
  assert.equal(button.textContent, 'Nascondi');
  assert.equal(content.getAttribute('hidden'), null);
  assert.equal(JSON.stringify(value), before);
  for (const appearance of ['auto', 'NONE', 'link', '', null, 1]) {
    const invalid = structuredClone(value);
    invalid.disclosure.button.appearance = appearance;
    assert.throws(() => validateContainerDisclosure(invalid));
  }
  for (const change of [v => {v.font_weight = 500;}, v => {v.padding.left.value = -1;}]) {
    const invalid = structuredClone(value);
    change(invalid.disclosure.button);
    assert.throws(() => validateContainerDisclosure(invalid));
  }
});

test('run-local pointer paint leaves bracket activation and keyboard focus on the button', t => {
  const value=owner(), p=value.disclosure;
  p.expand_label='[Mostra]';p.collapse_label='[Nascondi]';
  for(const [name,end] of [['expand_run',7],['collapse_run',9]]) {
    p[name].start=1;p[name].end=end;p[name].pointer_on_run=true;
    p[name].paint.normal={foreground:'#3366cc',underline:false};
    p[name].paint.hover={foreground:'#3056a9',underline:true};
    p[name].paint.active={foreground:'#233566',underline:true};
    p[name].paint.hover_active={foreground:'#233566',underline:true};
    p[name].paint.underline_on_focus=true;
  }
  const unchanged=JSON.stringify(value), x=install(t,value), b=x.result.button;
  const selector='.'+b.className.split(' ')[0], run=selector+' > .compiled-disclosure-run';
  assert.equal(b.textContent,'[Mostra]');
  assert.deepEqual([b.children[0],b.children[2]],['[',']']);
  for(const state of [':hover',':active',':hover:active']) {
    assert.ok(x.labelStyle.textContent.includes(run+state+'{'));
    assert.ok(!x.labelStyle.textContent.includes(selector+state+' > .compiled-disclosure-run{'));
  }
  assert.ok(x.labelStyle.textContent.includes(selector+':focus > .compiled-disclosure-run{text-decoration-line:underline}'));
  assert.deepEqual(b.listeners,['click']);assert.equal(b.children[1].listeners.length,0);
  b.click();assert.equal(b.textContent,'[Nascondi]');assert.equal(x.content.getAttribute('hidden'),null);
  assert.equal(JSON.stringify(value),unchanged);
  for(const bad of [null,0,1,'true',{},[]]) {
    const copy=structuredClone(value);copy.disclosure.expand_run.pointer_on_run=bad;
    assert.throws(()=>validateContainerDisclosure(copy));
  }
  for(const old of [undefined,false]) {
    const copy=structuredClone(value);
    for(const key of ['expand_run','collapse_run']) {
      if(old===undefined)delete copy.disclosure[key].pointer_on_run;else copy.disclosure[key].pointer_on_run=false;
    }
    const legacy=install(t,copy), oldSelector='.'+legacy.result.button.className.split(' ')[0];
    assert.ok(legacy.labelStyle.textContent.includes(oldSelector+':hover > .compiled-disclosure-run{'));
  }
});
