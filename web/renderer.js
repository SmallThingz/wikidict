import {safeURL} from './validate.js';
const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = text; if (cls) el.className = cls; return el; };
let explanationSequence = 0;
export function spans(values = [], onLink = () => {}, preserve = false, explanations = null, withinSummary = false) {
  const fragment = document.createDocumentFragment();
  const compact=[];
  for(const span of values){
    if(span.kind==='line_break' && !span.trail && (!compact.length||compact.at(-1).kind==='line_break'))continue;
    if(span.kind==='text'&&!span.text?.trim()&&!span.trail?.trim()&&(!compact.length||compact.at(-1).kind==='line_break'))continue;
    compact.push(span);
  }
  while(compact.length&&((compact.at(-1).kind==='line_break'&&!compact.at(-1).trail?.trim())||(!compact.at(-1).text?.trim()&&!compact.at(-1).trail?.trim())))compact.pop();
  const visible = preserve?values:compact, described = new Map();
  for (let i=0;i<visible.length;) {
    const explanation=visible[i].explanation;
    if (!explanation) { i++; continue; }
    let end=i,label='';
    if(visible[i].kind==='line_break'){label=visible[i].trail||'';end++;}
    else while(end<visible.length && visible[end].kind!=='line_break' && visible[end].explanation===explanation) {
      label+=(visible[end].text||'')+(visible[end].trail||'');end++;
    }
    if (label.trim() && explanations) {
      const id=explanations.add(label.trim(),explanation);
      for(let j=i;j<end;j++)described.set(j,id);
    }
    i=end;
  }
  const trailNode=(span,i)=>{
    if(!span.explanation||!span.trail)return document.createTextNode(span.trail||'');
    const trail=node('abbr',span.trail);trail.title=span.explanation;
    if(described.has(i))trail.setAttribute('aria-describedby',described.get(i));
    return trail;
  };
  for (const [i,span] of visible.entries()) {
    if (span.kind === 'line_break') { fragment.append(node('br'),trailNode(span,i)); continue; }
    let el = node('span', span.text || '');
    if (span.language) el.lang = span.language;
    if (['rtl','ltr'].includes(span.direction)) { el.dir = span.direction; el.style.unicodeBidi = 'isolate'; }
    if (['label','citation','pronunciation','headword'].includes(span.role)) el.classList.add(span.role);
    for (const [flag, tag] of [['bold','strong'],['italic','em'],['code','code'],['small','small'],['superscript','sup'],['subscript','sub'],['strike','s'],['underline','u']]) {
      if (span[flag]) { const wrapper = node(tag); wrapper.append(el); el = wrapper; }
    }
    if (span.explanation) {
      const abbreviation=node('abbr');abbreviation.title=span.explanation;
      if(described.has(i))abbreviation.setAttribute('aria-describedby',described.get(i));
      abbreviation.append(el);el=abbreviation;
    }
    if (span.kind === 'link' && span.target) {
      const link = node('a'); link.href = '#' + encodeURIComponent(span.target);
      link.addEventListener('click', event => { event.preventDefault(); if(withinSummary)event.stopPropagation(); onLink(span.target); }); link.append(el); el = link;
    } else if (span.kind === 'external_link' && safeURL(span.target)) {
      const link = node('a'); link.href = safeURL(span.target); link.rel = 'noopener noreferrer'; link.target = '_blank'; if(withinSummary)link.addEventListener('click',event=>event.stopPropagation()); link.append(el); el = link;
    }
    if(described.has(i) && el.tagName==='A')el.setAttribute('aria-describedby',described.get(i));
    fragment.append(el,trailNode(span,i));
  }
  return fragment;
}
function blockView(block, onLink, explanations) {
  const margin = `${Math.min(Math.max(block.depth || 0,0),8)*.45}rem`;
  if (block.table) {
    const feature = block.feature;
    if (block.kind === 'table' && feature?.kind === 'color_swatch' &&
        typeof feature.data === 'string' && feature.data.length === 7 && /^#[0-9a-f]{6}$/.test(feature.data) &&
        (feature.language === undefined ? '' : feature.language) === '' && (feature.tail_kind === undefined ? 'none' : feature.tail_kind) === 'none' && (feature.tail === undefined ? '' : feature.tail) === '') {
      const sample = node('div', null, 'color-swatch');
      sample.style.marginInlineStart = margin;
      sample.style.display = 'flex'; sample.style.alignItems = 'center'; sample.style.gap = '.6rem';
      const chip = node('span'); chip.setAttribute('aria-hidden', 'true');
      chip.style.display = 'inline-block'; chip.style.width = '40px'; chip.style.height = '40px';
      chip.style.flexShrink = '0'; chip.style.border = '1px solid currentColor';
      chip.style.backgroundColor = feature.data;
      sample.append(chip, node('span', 'Color sample ' + feature.data));
      return sample;
    }
    const wrap = node('div', null, 'table-scroll'), table = node('table'); wrap.style.marginInlineStart = margin; wrap.tabIndex = 0; wrap.setAttribute('aria-label','Scrollable table');
    if (block.table.caption?.length) { const caption = node('caption'); caption.append(spans(block.table.caption,onLink,false,explanations)); table.append(caption); }
    for (const row of block.table.rows) { const tr = node('tr'); for (const cell of row.cells) { const td = node(cell.header?'th':'td'); td.colSpan = cell.colspan || 1; td.rowSpan = cell.rowspan || 1; td.append(spans(cell.spans,onLink,false,explanations)); tr.append(td); } table.append(tr); }
    wrap.append(table); return wrap;
  }
  if (block.kind === 'rule') return node('hr');
  if (block.kind === 'preformatted') { const pre = node('pre'); pre.append(spans(block.spans,onLink,true,explanations)); return pre; }
  const allowed = new Set(['paragraph','definition','example','quotation','list_item','list_detail','indent','term','heading']);
  const kind = allowed.has(block.kind) ? block.kind : 'paragraph';
  const el = node(kind === 'heading'?'h4':'div',null,'block '+kind);
  el.style.marginInlineStart = margin;
  const prefix = kind==='definition'?(block.number?`${block.number}.`:'•'):['example','quotation'].includes(kind)?'│':kind==='list_item'?(block.number?`${block.number}.`:'•'):kind==='list_detail'?'↳':'';
  if (prefix) el.append(node('span',prefix,'prefix'));
  const body = node('span',null,'body'); body.append(spans(block.spans,onLink,false,explanations)); el.append(body); return el;
}
function sectionHeadingCompanion(section){
  const first=section.blocks?.[0];
  if(!section.title||!first||first.kind!=='heading'||first.level!==section.level)return null;
  let navigable=false,explained=false,label='';
  for(const span of first.spans||[]){
    if(span.kind==='line_break'&&span.trail)return null;
    explained=explained||!!span.explanation;
    navigable=navigable||(['link','external_link'].includes(span.kind)&&!!span.target&&!!(span.text||span.trail));
    label+=span.kind==='line_break'?'\n':(span.text||'')+(span.trail||'');
  }
  const trimmed=label.replace(/^[ \t\r\n\u00a0]+|[ \t\r\n\u00a0]+$/g,'');
  return (navigable||explained)&&trimmed===section.title?first:null;
}
export function renderEntry(entry, onLink, settings = {}, mediaView = () => null) {
  const root = document.createDocumentFragment(), references = new Map();
  const explanationRows=[], explanationKeys=new Map();
  const explanations={add(label,explanation){
    const key=JSON.stringify([label,explanation]);
    if(explanationKeys.has(key))return explanationKeys.get(key);
    const id='abbreviation-explanation-'+(++explanationSequence);
    explanationKeys.set(key,id);explanationRows.push({id,label,explanation});return id;
  }};
  const followLink = target => {
    const reference = references.get(target);
    if (!reference) { onLink(target); return; }
    for (let parent = reference.parentElement; parent; parent = parent.parentElement)
      if (parent.tagName === 'DETAILS') parent.open = true;
    reference.scrollIntoView({block:'center'});
    reference.focus({preventScroll:true});
  };
  root.append(node('p',entry.language || entry.kind,'entry-language'));
  const title = node('h1'); title.append(entry.display_title?.length?spans(entry.display_title,followLink,false,explanations):document.createTextNode(entry.title)); root.append(title);
  if(entry.redirect){const r=entry.redirect;root.append(node('p',(r.followed?'Redirected from '+r.source_title+' to ':'Redirect to ')+r.target_title+(r.fragment?'#'+r.fragment:''),'entry-redirect'));}
  if(entry.alias&&entry.redirect?.followed){const a=entry.alias;root.append(node('p','Redirect to '+a.target_title+(a.fragment?'#'+a.fragment:''),'entry-alias'));}
  function fold(title, open=false, rich=null) {
    const el=node('details'),summary=node('summary',rich?null:title);el.open=open;
    if(rich)summary.append(spans(rich,followLink,false,explanations,true));
    el.append(summary);return el;
  }
  if (entry.preamble_spans?.length) { const preamble=fold('About this entry',entry.kind==='alias'||!settings.collapseOtherSections);preamble.append(spans(entry.preamble_spans,followLink,false,explanations));root.append(preamble); }
  for (const section of entry.sections) {
    const meaning=section.blocks.some(b=>b.kind==='definition');
    const expanded=meaning || (section.title.startsWith('Pronunciation')?!settings.collapsePronunciation:section.title.startsWith('Etymology')?!settings.collapseEtymology:!settings.collapseOtherSections);
    const companion=sectionHeadingCompanion(section);
    const el=fold(section.title===entry.language?'Overview':section.title||'Notes',expanded,companion?.spans);
    el.classList.toggle('meaning',meaning);el.id=section.title.replaceAll(' ','_');
    const notes=[];
    for (const block of section.blocks.slice(companion?1:0)) {
      if(block.kind==='blank'||(!block.table&&block.kind!=='rule'&&!block.spans?.some(s=>s.text?.trim()||s.trail?.trim())))continue;
      const view=blockView(block,followLink,explanations);
      if(meaning&&block.kind!=='definition')notes.push(view);else el.append(view);
    }
    if(notes.length){const details=fold('Examples & notes',!settings.collapseDetails);details.className='sense-notes';details.append(...notes);el.append(details);}
    if(el.children.length>1)root.append(el);
  }
  if (entry.references?.length) {
    const section=fold('References',!settings.collapseOtherSections);
    for (const ref of entry.references) { const p=node('p',null,'reference'); p.id=`reference-${ref.number}`; p.tabIndex=-1; references.set(`#${p.id}`,p); p.append(node('span',`[${ref.group?ref.group+' ':''}${ref.group_number}]`)); const body=node('span'); body.append(spans(ref.spans,followLink,false,explanations)); p.append(body); section.append(p); } root.append(section);
  }
  if (entry.media?.length) { const section=fold('Images & sound',!settings.collapseOtherSections);for(const media of entry.media){const view=mediaView(media);if(view)section.append(view);}root.append(section); }
  if(explanationRows.length){
    const details=fold('Abbreviations',false),list=node('dl');details.className='abbreviation-explanations';
    for(const row of explanationRows){
      const label=node('dt',row.label),description=node('dd',row.explanation);description.id=row.id;
      list.append(label,description);
    }
    details.append(list);root.append(details);
  }
  const edition=/^[a-z0-9_-]+wiktionary$/.test(entry.source_edition||'')?entry.source_edition.slice(0,-10).replaceAll('_','-'):null;
  const source=edition?'https://'+edition+'.wiktionary.org/':'https://www.wiktionary.org/';
  const credit=node('footer');const link=node('a','Wiktionary contributors');link.href=source+(edition&&entry.source_title?'wiki/'+encodeURIComponent(entry.source_title):'');link.target='_blank';link.rel='noopener';credit.append(link,node('span','CC BY-SA 4.0'));root.append(credit);
  return root;
}
