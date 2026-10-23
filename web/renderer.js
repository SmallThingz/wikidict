const canonicalRGB=value=>typeof value==='string'&&value.length===7&&/^#[0-9a-f]{6}$/.test(value);
import {safeURL} from './validate.js';
const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = text; if (cls) el.className = cls; return el; };
let explanationSequence = 0;
const poemTokens = span => (span.classes || '').split(/[ \t\r\n\v\f]+/).filter(Boolean);
const isPoem = span => poemTokens(span).includes('wikidict-poem');
function poemMetadata(span) {
  const tokens = poemTokens(span);
  if (!tokens.includes('wikidict-poem')) return {indent:0,direction:''};
  const indentTokens=tokens.filter(t=>t.startsWith('wikidict-poem-indent'));
  const directionTokens=tokens.filter(t=>t.startsWith('wikidict-poem-dir'));
  const indent=indentTokens.length===0?0:indentTokens.length===1&&/^wikidict-poem-indent-([1-9]|[12][0-9]|3[0-2])$/.test(indentTokens[0])?Number(indentTokens[0].slice(21)):-1;
  const direction=directionTokens.length===0?'':directionTokens.length===1&&['wikidict-poem-dir-ltr','wikidict-poem-dir-rtl'].includes(directionTokens[0])?directionTokens[0].slice(-3):null;
  return {indent,direction};
}
function poemSpans(values,onLink,explanations,withinSummary) {
  const fragment=document.createDocumentFragment();
  let line=[],metadata=null,endedWithBreak=false,lastBreak=null;
  const include=span=>{
    const next=poemMetadata(span);
    if(metadata===null)metadata=next;
    else {
      if(metadata.indent!==next.indent)metadata.indent=-1;
      if(metadata.direction!==next.direction)metadata.direction=null;
    }
  };
  const appendLine=()=>{
    const el=node('span',null,'poem-line');el.style.display='block';
    if(metadata?.indent>0)el.style.marginInlineStart=metadata.indent+'em';
    if(metadata?.direction)el.dir=metadata.direction;
    el.append(spans(line,onLink,true,explanations,withinSummary));
    if(!line.some(s=>/[^ \t\r]/.test((s.text||'')+(s.trail||''))))el.append(node('br'));
    fragment.append(el);line=[];metadata=null;
  };
  const appendPart=(span,text,trail)=>{
    const pieces=text.split('\n');
    for(let i=0;i<pieces.length;i++){
      if(pieces[i]){
        include(span);
        line.push({...span,...(trail?{kind:'text',target:'',text:'',trail:pieces[i]}:{text:pieces[i],trail:''})});
        endedWithBreak=false;
      }
      if(i+1<pieces.length){
        include(span);appendLine();endedWithBreak=true;
        span={...span,classes:poemTokens(span).filter(t=>!t.startsWith('wikidict-poem-indent')).join(' ')};
        lastBreak=span;
      }
    }
    return span;
  };
  for(const original of values){
    let span=original;
    if(span.kind==='line_break'){
      if(isPoem(span))include(span);
      appendLine();endedWithBreak=true;lastBreak=span;
      if(span.trail){span=appendPart({...span,kind:'text',text:'',trail:span.trail},span.trail,true);}
    }else if(!(span.text||'')&&!(span.trail||'')){
      include(span);line.push(span);endedWithBreak=false;
    }else{
      span=appendPart(span,span.text||'',false);
      appendPart(span,span.trail||'',true);
    }
  }
  if(line.length||metadata!==null)appendLine();
  else if(endedWithBreak){include(lastBreak);appendLine();}
  return fragment;
}
export function spans(values = [], onLink = () => {}, preserve = false, explanations = null, withinSummary = false) {
  if (!preserve && values.some(isPoem)) return poemSpans(values,onLink,explanations,withinSummary);
  const fragment = document.createDocumentFragment();
  const compact=[];
  const blank=value=>!(value||'').includes('\u00a0')&&!(value||'').trim();
  for(const span of values){
    if(span.kind==='line_break' && !span.trail && (!compact.length||compact.at(-1).kind==='line_break'))continue;
    if(span.kind==='text'&&blank(span.text)&&blank(span.trail)&&(!compact.length||compact.at(-1).kind==='line_break'))continue;
    compact.push(span);
  }
  while(compact.length&&((compact.at(-1).kind==='line_break'&&blank(compact.at(-1).trail))||(blank(compact.at(-1).text)&&blank(compact.at(-1).trail))))compact.pop();
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
    if(!span.explanation&&!canonicalRGB(span.foreground))return document.createTextNode(span.trail||'');
    if(!span.trail)return document.createTextNode('');
    const trail=node(span.explanation?'abbr':'span',span.trail);
    if(span.explanation){trail.title=span.explanation;if(described.has(i))trail.setAttribute('aria-describedby',described.get(i));}
    if(canonicalRGB(span.foreground))trail.style.color=span.foreground;
    return trail;
  };
  for (const [i,span] of visible.entries()) {
    if (span.kind === 'line_break') { fragment.append(node('br'),trailNode(span,i)); continue; }
    let el = node('span', span.text || '');
    if(canonicalRGB(span.foreground))el.style.color=span.foreground;
    if (span.language) el.lang = span.language;
    if (['rtl','ltr','auto'].includes(span.direction)) { el.dir = span.direction; el.style.unicodeBidi = 'isolate'; }
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
// Resolve exact compiled IDs within the active entry, without CSS selector escaping.
export function revealFragment(root, fragment) {
  if (!fragment) return false;
  const destinations = [...root.querySelectorAll('[id]')];
  let matches = destinations.filter(el => el.id === fragment);
  if (!matches.length) matches = destinations.filter(el => el.id === fragment.replaceAll(' ','_'));
  if (matches.length !== 1) return false;
  const target = matches[0];
  for (let el = target; el && el !== root; el = el.parentElement)
    if (el.tagName === 'DETAILS') el.open = true;
  if (!target.hasAttribute('tabindex')) target.tabIndex = -1;
  target.scrollIntoView({block:'center'});
  target.focus({preventScroll:true});
  return true;
}
function destination(el, value, legacy = '') {
  const primary = value.anchor || legacy, fallback = value.anchor_fallback;
  if (primary) el.id = primary;
  if (fallback && fallback !== primary) {
    const alias = node('span'); alias.id = fallback;
    // Keep a details summary first while locating its alias at the heading.
    (el.tagName === 'DETAILS' ? el.firstElementChild : el).prepend(alias);
  }
}
function legacyDestinations(entry) {
  const candidates = [], counts = new Map();
  if (entry.presentation_version === 'DPR5') return new Map();
  const add = (value, label) => {
    if (value.anchor || value.anchor_fallback) return;
    const id = label.replaceAll(' ','_');
    if (id) { candidates.push([value,id]); counts.set(id,(counts.get(id)||0)+1); }
  };
  for (const section of entry.sections) {
    add(section,section.title);
    const companion = sectionHeadingCompanion(section);
    for (const block of section.blocks.slice(companion?1:0)) if (block.kind === 'heading') {
      const label = (block.spans||[]).map(span => span.kind === 'line_break'?'\n':(span.text||'')+(span.trail||'')).join('').trim();
      add(block,label);
    }
  }
  return new Map(candidates.filter(([,id]) => counts.get(id) === 1));
}
function blockView(block, onLink, explanations, legacy = '') {
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
    for (const row of block.table.rows) { const tr = node('tr'); for (const cell of row.cells) { const td = node(cell.header?'th':'td'); td.colSpan = cell.colspan || 1; td.rowSpan = cell.rowspan || 1; if(canonicalRGB(cell.background))td.style.backgroundColor=cell.background; td.append(spans(cell.spans,onLink,false,explanations)); tr.append(td); } table.append(tr); }
    wrap.append(table); return wrap;
  }
  if (block.kind === 'rule') return node('hr');
  if (block.kind === 'preformatted') { const pre = node('pre'); pre.append(spans(block.spans,onLink,true,explanations)); return pre; }
  const allowed = new Set(['paragraph','definition','example','quotation','list_item','list_detail','indent','term','heading']);
  const kind = allowed.has(block.kind) ? block.kind : 'paragraph';
  const el = node(kind === 'heading'?'h4':'div',null,'block '+kind);
  el.style.marginInlineStart = margin;
  if (kind === 'heading') destination(el, block, legacy);
  const prefix = kind==='definition'?(block.number?`${block.number}.`:'•'):['example','quotation'].includes(kind)?'│':kind==='list_item'?(block.number?`${block.number}.`:'•'):kind==='list_detail'?'↳':'';
  if (prefix) el.append(node('span',prefix,'prefix'));
  const body = node('span',null,'body'); if(block.spans?.some(isPoem))body.style.flex='1'; body.append(spans(block.spans,onLink,false,explanations)); el.append(body); return el;
}
function sectionHeadingCompanion(section){
  const first=section.blocks?.[0];
  if(!section.title||!first||first.kind!=='heading'||first.level!==section.level)return null;
  let navigable=false,explained=false,styledText=false,label='';
  for(const span of first.spans||[]){
    if(span.kind==='line_break'&&span.trail)return null;
    explained=explained||!!span.explanation;
    navigable=navigable||(['link','external_link'].includes(span.kind)&&!!span.target&&!!(span.text||span.trail));
    const styled=['bold','italic','code','small','superscript','subscript','strike','underline'].some(flag=>span[flag])||
      span.foreground!=null||!!span.classes||!!span.language||!!span.direction||(span.role??'normal')!=='normal';
    styledText=styledText||(span.kind==='text'&&!!span.text&&!span.target&&styled);
    label+=span.kind==='line_break'?'\n':(span.text||'')+(span.trail||'');
  }
  const trimmed=label.replace(/^[ \t\r\n\u00a0]+|[ \t\r\n\u00a0]+$/g,'');
  return (navigable||explained||styledText||first.depth>0)&&trimmed===section.title?first:null;
}
export function renderEntry(entry, onLink, settings = {}, mediaView = () => null) {
  const root = document.createDocumentFragment(), references = new Map(), legacy = legacyDestinations(entry);
  const headingDestinations = new Set();
  for (const section of entry.sections) for (const value of [section,...section.blocks.filter(block=>block.kind==='heading')])
    for (const id of [value.anchor,value.anchor_fallback,legacy.get(value)]) if (id) headingDestinations.add(id);
  const explanationRows=[], explanationKeys=new Map();
  const explanations={add(label,explanation){
    const key=JSON.stringify([label,explanation]);
    if(explanationKeys.has(key))return explanationKeys.get(key);
    let id;do{id='abbreviation-explanation-'+(++explanationSequence);}while(headingDestinations.has(id));
    explanationKeys.set(key,id);explanationRows.push({id,label,explanation});return id;
  }};
  const followLink = target => {
    const fragment = target.startsWith('#')?target.slice(1):null;
    // Authored heading identities take precedence over generated citation IDs.
    if (fragment && (headingDestinations.has(fragment)||headingDestinations.has(fragment.replaceAll(' ','_')))) { onLink(target); return; }
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
  function fold(title, open=false, rich=null, depth=0) {
    const el=node('details'),summary=node('summary',rich?null:title);el.open=open;
    if(rich){const label=node('span',null,'heading-label');if(depth>0){label.style.display='inline-block';label.style.marginInlineStart=`${Math.min(depth,8)*.45}rem`;}label.append(spans(rich,followLink,false,explanations,true));summary.append(label);}
    el.append(summary);return el;
  }
  if (entry.preamble_spans?.length) { const preamble=fold('About this entry',entry.kind==='alias'||!settings.collapseOtherSections);preamble.append(spans(entry.preamble_spans,followLink,false,explanations));root.append(preamble); }
  for (const section of entry.sections) {
    const meaning=section.blocks.some(b=>b.kind==='definition');
    const expanded=meaning || (section.title.startsWith('Pronunciation')?!settings.collapsePronunciation:section.title.startsWith('Etymology')?!settings.collapseEtymology:!settings.collapseOtherSections);
    const companion=sectionHeadingCompanion(section);
    const el=fold(section.title===entry.language?'Overview':section.title||'Notes',expanded,companion?.spans,companion?.depth);
    el.classList.toggle('meaning',meaning);destination(el,section,legacy.get(section)||'');
    const notes=[];
    for (const block of section.blocks.slice(companion?1:0)) {
      if(block.kind==='blank'||(!block.table&&block.kind!=='rule'&&!block.spans?.some(s=>s.text?.trim()||s.trail?.trim())&&!block.spans?.some(isPoem)&&!(block.kind==='heading'&&(block.anchor||block.anchor_fallback))))continue;
      const view=blockView(block,followLink,explanations,legacy.get(block)||'');
      if(meaning&&block.kind!=='definition')notes.push(view);else el.append(view);
    }
    if(notes.length){const details=fold('Examples & notes',!settings.collapseDetails);details.className='sense-notes';details.append(...notes);el.append(details);}
    if(el.children.length>1||companion||section.anchor||section.anchor_fallback)root.append(el);
  }
  if (entry.references?.length) {
    const section=fold('References',!settings.collapseOtherSections);
    const referenceIDs=new Set(headingDestinations);
    for (const ref of entry.references) { const p=node('p',null,'reference'),target=`reference-${ref.number}`;let id=target;while(referenceIDs.has(id))id='citation-'+id;referenceIDs.add(id);p.id=id;p.tabIndex=-1;references.set(`#${target}`,p); p.append(node('span',`[${ref.group?ref.group+' ':''}${ref.group_number}]`)); const body=node('span'); body.append(spans(ref.spans,followLink,false,explanations)); p.append(body); section.append(p); } root.append(section);
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
