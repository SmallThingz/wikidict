// Shared semantic family request. css_default records the absence of an
// authored generic; it does not request the parent's family or a new alias.
const genericNames = new Set([
  'serif', 'sans-serif', 'sans serif', 'sans', 'monospace', 'cursive',
  'fantasy', 'system', 'system-ui', 'ui-serif', 'ui-sans-serif',
  'ui-monospace', 'ui-rounded', 'emoji', 'math', 'fangsong',
]);
const invalid = () => { throw Error('Invalid compiled font family'); };
const exactObject = (value, fields) => {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== fields.length ||
      !fields.every(field => Object.hasOwn(value, field))) invalid();
};

export function validateFontFamily(value) {
  if (value === 'sans_serif') return;
  exactObject(value, ['stack']);
  const stack = value.stack;
  exactObject(stack, ['names', 'fallback']);
  if (!Array.isArray(stack.names) || stack.names.length > 16 ||
      !['sans_serif', 'serif', 'css_default'].includes(stack.fallback) ||
      (stack.fallback === 'css_default' && stack.names.length === 0)) invalid();
  for (const name of stack.names) {
    if (typeof name !== 'string' || name.length === 0 || name.length > 128 ||
        /[^\x20-\x7e]|[\[\]]/.test(name) || name.trim() !== name ||
        genericNames.has(name.toLowerCase().replace(/ +/g, ' '))) invalid();
  }
}

export function fontFamilyCSS(value) {
  validateFontFamily(value);
  if (value === 'sans_serif') return 'sans-serif';
  const {names, fallback} = value.stack;
  const families = names.map(name => '"' + name.replaceAll('\\', '\\\\').replaceAll('"', '\\"') + '"');
  if (fallback !== 'css_default') families.push(fallback === 'serif' ? 'serif' : 'sans-serif');
  return families.join(',');
}
