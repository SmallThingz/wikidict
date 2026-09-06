import type { Entry, Lexeme, Organization } from './types';
export type KindGroup = { kind: string; language: string; lexemes: Lexeme[] };
export function kindGroups(entry: Entry): KindGroup[] {
  const groups: KindGroup[] = [];
  for (const lexeme of entry.organization?.lexemes ?? []) {
    const language = lexeme.language || entry.language || "";
    let group = groups.find(item => item.kind === lexeme.kind && item.language === language);
    if (!group) { group = { kind: lexeme.kind, language, lexemes: [] }; groups.push(group); }
    group.lexemes.push(lexeme);
  }
  return groups;
}
export function navigation(entry: Entry): { index: number; label: string }[] {
  if (!entry.organization?.lexemes.length) return entry.sections.map((section, index) => ({ index, label: section.title })).filter(item => entry.sections[item.index].level > 2);
  const primary = kindGroups(entry).flatMap(group => group.lexemes.map(lexeme => ({ index: lexeme.section, label: group.kind + (group.lexemes.length > 1 && lexeme.etymology !== null ? ' · ' + entry.sections[lexeme.etymology].title.replace('Etymology', 'origin') : '') })));
  const indices = [...entry.organization.lexemes.flatMap(item => item.related_sections), ...entry.organization.other_sections];
  return [...primary, ...indices.filter(index => entry.sections[index].level > 2).map(index => ({ index, label: entry.sections[index].title }))];
}
export function reveal(element: Element | null) {
  if (!element) return;
  let parent: Element | null = element;
  while (parent) { if (parent instanceof HTMLDetailsElement) parent.open = true; parent = parent.parentElement; }
  queueMicrotask(() => element.scrollIntoView({ block: 'start' }));
}
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
/** Bounds and acyclic parents are checked before recursive rendering. */
export function validOrganization(value: unknown, entry: Entry): value is Organization {
  if (!object(value) || !Array.isArray(value.lexemes) || !Array.isArray(value.other_sections)) return false;
  const index = (n: unknown, size: number): n is number => Number.isSafeInteger(n) && (n as number) >= 0 && (n as number) < size;
  const section = (n: unknown): n is number => index(n, entry.sections.length);
  const list = (v: unknown, size: number) => Array.isArray(v) && v.every(n => index(n, size));
  if (!value.other_sections.every(section)) return false;
  return value.lexemes.every(l => {
    if (!object(l) || typeof l.kind !== 'string' || (l.language !== undefined && typeof l.language !== 'string') || !section(l.section) || !(l.etymology === null || section(l.etymology)) || !Array.isArray(l.definitions) || !Array.isArray(l.related_sections) || !l.related_sections.every(section)) return false;
    const size = entry.sections[l.section].blocks.length;
    const depths: number[] = [];
    return list(l.introduction, size) && list(l.other_blocks, size) && l.definitions.every((s, at) => object(s) && index(s.block, size) && (s.parent === null || index(s.parent, at)) && ((depths[at] = s.parent === null ? 1 : depths[s.parent as number] + 1) <= 255) && list(s.examples, size) && list(s.quotations, size) && list(s.notes, size) && (s.form === null || (object(s.form) && typeof s.form.target === 'string' && typeof s.form.relation === 'string' && typeof s.form.language === 'string')));
  });
}
