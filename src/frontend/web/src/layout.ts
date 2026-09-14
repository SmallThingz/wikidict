import type { Block } from './types';
export type ListNode = { tag: 'ol' | 'ul' | 'dl'; items: { block?: Block; children: ListNode[] }[] };
export type Group = { block: Block } | { list: ListNode };
/** Build valid nested list containers from the marker paths already parsed by Zig. */
export function layout(blocks: Block[]): Group[] {
  const groups: Group[] = [];
  const stack: ListNode[] = [];
  for (const block of blocks) {
    const path = block.list_path || (block.kind === 'list_item' ? '*' : '');
    if (!path) { stack.length = 0; groups.push({ block }); continue; }
    const tags = Array.from(path.slice(0, 32), c => c === '#' ? 'ol' : c === '*' ? 'ul' : 'dl') as ListNode['tag'][];
    let common = 0;
    while (common < tags.length && common < stack.length && stack[common].tag === tags[common]) common++;
    stack.length = common;
    for (let depth = common; depth < tags.length; depth++) {
      const node: ListNode = { tag: tags[depth], items: [] };
      if (depth === 0) groups.push({ list: node });
      else {
        const parent = stack[depth - 1];
        if (!parent.items.length) parent.items.push({ children: [] });
        parent.items[parent.items.length - 1].children.push(node);
      }
      stack.push(node);
    }
    stack[stack.length - 1].items.push({ block, children: [] });
  }
  return groups;
}
