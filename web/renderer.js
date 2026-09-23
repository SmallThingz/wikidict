import {safeURL} from './validate.js';
const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = text; if (cls) el.className = cls; return el; };
export function spans(values = [], onLink = () => {}, preserve = false) {
  const fragment = document.createDocumentFragment();
  const compact=[];
  for(const span of values){
    if(span.kind==='line_break' && (!compact.length||compact.at(-1).kind==='line_break'))continue;
    if(span.kind==='text'&&!span.text?.trim()&&!span.trail?.trim()&&(!compact.length||compact.at(-1).kind==='line_break'))continue;
    compact.push(span);
  }
  while(compact.length&&(compact.at(-1).kind==='line_break'||(!compact.at(-1).text?.trim()&&!compact.at(-1).trail?.trim())))compact.pop();
  for (const span of preserve?values:compact) {
    if (span.kind === 'line_break') { fragment.append(node('br'), document.createTextNode(span.trail || '')); continue; }
    let el = node('span', span.text || '');
    if (span.language) el.lang = span.language;
    if (['rtl','ltr'].includes(span.direction)) { el.dir = span.direction; el.style.unicodeBidi = 'isolate'; }
    if (['label','citation','pronunciation','headword'].includes(span.role)) el.classList.add(span.role);
    for (const [flag, tag] of [['bold','strong'],['italic','em'],['code','code'],['small','small'],['superscript','sup'],['subscript','sub'],['strike','s'],['underline','u']]) {
      if (span[flag]) { const wrapper = node(tag); wrapper.append(el); el = wrapper; }
    }
    if (span.kind === 'link' && span.target) {
      const link = node('a'); link.href = '#' + encodeURIComponent(span.target);
      link.addEventListener('click', event => { event.preventDefault(); onLink(span.target); }); link.append(el); el = link;
    } else if (span.kind === 'external_link' && safeURL(span.target)) {
      const link = node('a'); link.href = safeURL(span.target); link.rel = 'noopener noreferrer'; link.target = '_blank'; link.append(el); el = link;
    }
    fragment.append(el, document.createTextNode(span.trail || ''));
  }
  return fragment;
}
function blockView(block, onLink) {
  if (block.table) {
    const wrap = node('div', null, 'table-scroll'), table = node('table'); wrap.tabIndex = 0; wrap.setAttribute('aria-label','Scrollable table');
    if (block.table.caption?.length) { const caption = node('caption'); caption.append(spans(block.table.caption,onLink)); table.append(caption); }
    for (const row of block.table.rows) { const tr = node('tr'); for (const cell of row.cells) { const td = node(cell.header?'th':'td'); td.colSpan = cell.colspan || 1; td.rowSpan = cell.rowspan || 1; td.append(spans(cell.spans,onLink)); tr.append(td); } table.append(tr); }
    wrap.append(table); return wrap;
  }
  if (block.kind === 'rule') return node('hr');
  if (block.kind === 'preformatted') { const pre = node('pre'); pre.append(spans(block.spans,onLink,true)); return pre; }
  const allowed = new Set(['paragraph','definition','example','quotation','list_item','list_detail','indent','term','heading']);
  const kind = allowed.has(block.kind) ? block.kind : 'paragraph';
  const el = node(kind === 'heading'?'h4':'div',null,'block '+kind);
  el.style.marginInlineStart = `${Math.min(Math.max(block.depth || 0,0),8)*.45}rem`;
  const prefix = kind==='definition'?(block.number?`${block.number}.`:'•'):['example','quotation'].includes(kind)?'│':kind==='list_item'?'•':kind==='list_detail'?'↳':'';
  if (prefix) el.append(node('span',prefix,'prefix'));
  const body = node('span',null,'body'); body.append(spans(block.spans,onLink)); el.append(body); return el;
}
export function renderEntry(entry, onLink, settings = {}, mediaView = () => null) {
  const root = document.createDocumentFragment();
  root.append(node('p',entry.language || entry.kind,'entry-language'));
  const title = node('h1'); title.append(entry.display_title?.length?spans(entry.display_title,onLink):document.createTextNode(entry.title)); root.append(title);
  function fold(title, open=false) {const el=node('details');el.open=open;el.append(node('summary',title));return el;}
  if (entry.preamble_spans?.length) { const preamble=fold('About this entry',!settings.collapseOtherSections);preamble.append(spans(entry.preamble_spans,onLink));root.append(preamble); }
  for (const section of entry.sections) {
    const meaning=section.blocks.some(b=>b.kind==='definition');
    const expanded=meaning || (section.title.startsWith('Pronunciation')?!settings.collapsePronunciation:section.title.startsWith('Etymology')?!settings.collapseEtymology:!settings.collapseOtherSections);
    const el=fold(section.title===entry.language?'Overview':section.title||'Notes',expanded);
    el.classList.toggle('meaning',meaning);el.id=section.title.replaceAll(' ','_');
    const notes=[];
    for (const block of section.blocks) {
      if(block.kind==='blank'||(!block.table&&block.kind!=='rule'&&!block.spans?.some(s=>s.text?.trim())))continue;
      const view=blockView(block,onLink);
      if(meaning&&block.kind!=='definition')notes.push(view);else el.append(view);
    }
    if(notes.length){const details=fold('Examples & notes',!settings.collapseDetails);details.className='sense-notes';details.append(...notes);el.append(details);}
    if(el.children.length>1)root.append(el);
  }
  if (entry.references?.length) {
    const section=fold('References',!settings.collapseOtherSections);
    for (const ref of entry.references) { const p=node('p',null,'reference'); p.id=`cite_note-${ref.number}`; p.append(node('span',`[${ref.group?ref.group+' ':''}${ref.group_number}]`)); const body=node('span'); body.append(spans(ref.spans,onLink)); p.append(body); section.append(p); } root.append(section);
  }
  if (entry.media?.length) { const section=fold('Images & sound',!settings.collapseOtherSections);for(const media of entry.media){const view=mediaView(media);if(view)section.append(view);}root.append(section); }
  const credit=node('footer');const link=node('a','Wiktionary contributors');link.href='https://en.wiktionary.org/wiki/'+encodeURIComponent(entry.title);link.target='_blank';link.rel='noopener';credit.append(link,node('span','CC BY-SA 4.0'));root.append(credit);
  return root;
}
