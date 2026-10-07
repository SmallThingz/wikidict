const mediaClasses = new Set(['wikidict-media', 'audiotable']);

function previewText(block) {
  return (block.spans || [])
    .filter(span => !(span.script || '').split(/\s+/).some(token => mediaClasses.has(token)))
    .map(span => (span.kind === 'line_break' ? ' ' : span.text || '') + (span.trail || ''))
    .join('').trim();
}

export function entryClue(entry) {
  const blocks = entry.sections.flatMap(section => section.blocks);
  for (const block of blocks) {
    if (block.kind === 'definition') {
      const text = previewText(block);
      if (text) return text;
    }
  }
  for (const block of blocks) {
    const text = previewText(block);
    if (text) return text;
  }
  return entry.title;
}

export const hitKey = hit => JSON.stringify([hit.dictionary, hit.context || hit.dictionary, hit.raw_key ?? hit.title]);

export function refreshSavedClue(saved, hit, clue) {
  const identity = hitKey(hit);
  let changed = false;
  const refreshed = saved.map(item => {
    if (hitKey(item) !== identity || item.clue === clue) return item;
    changed = true;
    return {...item, clue};
  });
  return changed ? refreshed : saved;
}
