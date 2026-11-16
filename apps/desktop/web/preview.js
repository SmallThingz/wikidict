const mediaClasses = new Set(['wikidict-media', 'audiotable']);

function previewText(block) {
  return (block.spans || [])
    .filter(span => !(span.classes || '').split(/\s+/).some(token => mediaClasses.has(token)))
    .map(span => (span.kind === 'line_break' ? ' ' : span.text || '') + (span.trail || ''))
    .join('').trim();
}

export function previewBlocks(values) {
  // Each table wrapper adds at most one visit per decoded block/cell item.
  let budget=2<<20;
  const spend=depth=>{if(depth>64||--budget<0)throw Error('Preview structure exceeds reader limit');};
  const append=(target,values)=>{for(const value of values)target.push(value);};
  const figure=(value,depth)=>descend(value.caption_blocks||[],true,depth+1);
  const flow=(values,depth)=>values.flatMap(part=>{spend(depth);return part.figure?figure(part.figure,depth):part.scope?flow(part.scope.parts,depth+1):[];});
  const table=(value,depth)=>{
    spend(depth);const result=descend(value.caption_blocks||[],true,depth+1);
    for(const row of value.rows||[]){spend(depth);for(const cell of row.cells||[]){spend(depth);append(result,cell.blocks!=null?descend(cell.blocks,true,depth+1):cell.nested_table?table(cell.nested_table,depth+1):[]);}}
    return result;
  };
  const descend=(values,onlyContainers=false,depth=0)=>values.flatMap(block=>{
    spend(depth);
    if(block.container)return descend(block.container.blocks,false,depth+1);
    // Preserve the older opaque-table preview policy, but discover L owners in
    // every supported host rather than losing their newly represented bodies.
    const result=onlyContainers?[]:[block];
    if(block.table)append(result,table(block.table,depth+1));
    if(block.figure)append(result,figure(block.figure,depth+1));
    if(block.flow)append(result,flow(block.flow,depth+1));
    return result;
  });
  return descend(values);
}

export function entryClue(entry) {
  const blocks = previewBlocks(entry.sections.flatMap(section=>section.blocks));
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
