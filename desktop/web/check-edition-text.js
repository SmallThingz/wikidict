import {sectionHeadingCompanion} from './renderer.js';

const visibleText = span => span && typeof span === 'object' && ['text', 'link', 'external_link'].includes(span.kind) &&
  typeof span.text === 'string' && span.font_scale !== 0;

export const normalizeVisibleText = text => text.normalize('NFC').replace(/\s+/gu, ' ').trim();

export function expectedTextFragments(...roots) {
  return collectTextFragments(roots, 3);
}

function collectTextFragments(roots, minimumLength) {
  const expected = new Set();
  function add(text) {
    if (!text) return;
    const fragment = normalizeVisibleText(text);
    if (fragment.length >= minimumLength) expected.add(fragment);
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
export function expectedBodyTextFragments(entry) {
  // renderEntry consumes only this exact companion as summary text. Do not
  // discard other headings, nested blocks, references or short definitions.
  const bodies = (entry.sections || []).map(section =>
    sectionHeadingCompanion(section) ? section.blocks.slice(1) : section.blocks);
  return collectTextFragments([bodies, entry.preamble_spans, entry.references], 1);
}

export function entryTextProblems(entry, renderedText, bodyNodes) {
  const problems = {}, text = normalizeVisibleText(renderedText);
  // Heading companions remain in the overall text oracle even though they
  // are excluded from the body oracle, just as summary nodes are in the DOM.
  const expected = expectedTextFragments(entry.sections, entry.references,
    entry.display_title, entry.preamble_spans);
  let missing = 0;
  for (const fragment of expected) if (!text.includes(fragment)) {
    if (++missing <= 4) (problems.missingTextExamples ??= []).push(fragment.slice(0, 120));
  }
  if (missing) problems.missingTextCandidates = missing;
  if (bodyNodes === 0 && expectedBodyTextFragments(entry).size) problems.emptyVisibleBody = true;
  return problems;
}
