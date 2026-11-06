const canonicalRGB=value=>typeof value==='string'&&value.length===7&&/^#[0-9a-f]{6}$/.test(value);
const contrastInk=background=>{
  const linear=value=>{value/=255;return value<=0.04045?value/12.92:((value+0.055)/1.055)**2.4;};
  const rgb=[1,3,5].map(at=>linear(parseInt(background.slice(at,at+2),16)));
  const luminance=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];
  return (luminance+.05)/.05>=1.05/(luminance+.05)?'#000000':'#ffffff';
};
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
function poemSpans(values,onLink,explanations,withinSummary,cellBackground) {
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
    el.append(spans(line,onLink,true,explanations,withinSummary,cellBackground));
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
// Normal-body basis shares the same configured size as .block in style.css.
// Keep context-relative em sizing for legacy and inline heading spans.
function semanticFontSize(span) {
  const basis=span.font_scale_basis===undefined?'context':span.font_scale_basis,scale=span.font_scale;
  if(basis!=='context'&&basis!=='normal_body')throw new Error('invalid semantic font scale basis');
  if(scale===undefined||scale===null){if(basis!=='context')throw new Error('normal body scale is absent');return null;}
  if(typeof scale!=='number'||!Number.isFinite(scale)||scale<0)throw new Error('invalid semantic font scale');
  const size=basis==='normal_body'?`calc(var(--wikidict-normal-body-size) * ${scale})`:(scale===1?null:`${scale}em`);
  // Match the browser's computed-font ceiling in CSS pixels, retaining semantic
  // scale and the zero/identity paths rather than rewriting compiled data.
  return scale>0&&size!==null?`min(10000px, ${size})`:size;
}
function inlineImageElement(image,load){
  if(!image||typeof image.file!=='string'||!image.file||new TextEncoder().encode(image.file).length>32*1024*1024||image.file.startsWith(' ')||image.file.endsWith(' ')||/[_\[\]{}<>|#\x00-\x1f\x7f-\x9f]/u.test(image.file))throw Error('Invalid inline image');
  if(image.border!==undefined&&typeof image.border!=='boolean')throw Error('Invalid inline image border');
  const el=node('img');el.className='compiled-inline-image';el.style.display='inline';el.style.verticalAlign='middle';el.style.border=image.border?'1px solid #eaecf0':'0';el.style.maxWidth='10000px';el.style.maxHeight='10000px';el.style.margin='0';el.style.borderRadius='0';el.style.objectFit='fill';
  // The authored border surrounds the content box; site-wide border-box must not shrink it.
  if(image.border){el.style.boxSizing='content-box';el.style.padding='0';}
  for(const [key,axis] of [['width_px','width'],['height_px','height']])if(image[key]!=null){if(!Number.isInteger(image[key])||image[key]<=0||image[key]>4294967295)throw Error('Invalid image dimension');el.style[axis]=image[key]+'px';}
  const pendingScale=Math.min(1,image.width_px==null?1:10000/image.width_px,image.height_px==null?1:10000/image.height_px);
  if(image.width_px!=null)el.style.width=image.width_px*pendingScale+'px';if(image.height_px!=null)el.style.height=image.height_px*pendingScale+'px';
  if(image.width_px!=null&&image.height_px==null)el.style.height='auto';if(image.height_px!=null&&image.width_px==null)el.style.width='auto';
  for(const [key,attr] of [['alt','alt'],['tooltip','title']])if(image[key]!=null){if(typeof image[key]!=='string')throw Error('Invalid image description');el.setAttribute(attr,image[key]);}
  el.dataset.mediaState='pending';load?.(el,image);return el;
}
export function spans(values = [], onLink = () => {}, preserve = false, explanations = null, withinSummary = false, cellBackground = null) {
  if (!preserve && values.some(isPoem)) return poemSpans(values,onLink,explanations,withinSummary,cellBackground);
  const fragment = document.createDocumentFragment();
  const compact=[];
  const scaled=span=>semanticFontSize(span)!==null;
  values.forEach(value=>{semanticFontSize(value);if(value.image&&(value.text!==''||(value.trail??'')!==''||!['text','link','external_link'].includes(value.kind)||(value.kind==='text'?!!value.target:!value.target)))throw Error('Invalid inline image action');});
  const blank=value=>!(value||'').includes('\u00a0')&&!(value||'').trim();
  for(const span of values){
    if(span.kind==='line_break' && !span.trail && (!compact.length||compact.at(-1).kind==='line_break'))continue;
    if(!span.image&&!scaled(span)&&!canonicalRGB(span.background)&&span.kind==='text'&&blank(span.text)&&blank(span.trail)&&(!compact.length||compact.at(-1).kind==='line_break'))continue;
    compact.push(span);
  }
  while(compact.length&&!compact.at(-1).image&&!scaled(compact.at(-1))&&!canonicalRGB(compact.at(-1).background)&&((compact.at(-1).kind==='line_break'&&blank(compact.at(-1).trail))||(blank(compact.at(-1).text)&&blank(compact.at(-1).trail))))compact.pop();
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
  const inkFor=span=>canonicalRGB(span.foreground)?span.foreground:
    canonicalRGB(span.background)?contrastInk(span.background):canonicalRGB(cellBackground)?contrastInk(cellBackground):null;
  const explanationTag=span=>explanations?.isMediaExplanation?.(span)?'span':'abbr';
  const trailNode=(span,i)=>{
    if(!span.explanation&&!inkFor(span)&&!canonicalRGB(span.background))return document.createTextNode(span.trail||'');
    if(!span.trail)return document.createTextNode('');
    const trail=node(span.explanation?explanationTag(span):'span',span.trail);
    if(span.explanation){trail.title=span.explanation;if(described.has(i))trail.setAttribute('aria-describedby',described.get(i));}
    if(inkFor(span))trail.style.color=inkFor(span);
    if(canonicalRGB(span.background)){trail.style.backgroundColor=span.background;trail.style.whiteSpace='pre-wrap';}
    return trail;
  };
  for (const [i,span] of visible.entries()) {
    if (span.kind === 'line_break') {
      const trail=trailNode(span,i);
      if(scaled(span)){
        const wrapper=node('span');wrapper.style.fontSize=semanticFontSize(span);wrapper.append(trail);fragment.append(node('br'),wrapper);
      }else fragment.append(node('br'),trail);
      continue;
    }
    let el = node('span', span.text || '');
    if(span.image){if(span.kind==='line_break')throw Error('Invalid inline image action');el.append(inlineImageElement(span.image,explanations?.inlineImage));}
    if(inkFor(span))el.style.color=inkFor(span);
    if(!canonicalRGB(span.foreground)&&inkFor(span)&&((span.kind==='link'&&span.target)||(span.kind==='external_link'&&safeURL(span.target))))el.style.textDecoration='underline';
    if(canonicalRGB(span.background)){el.style.backgroundColor=span.background;el.style.whiteSpace='pre-wrap';}
    if (span.language) el.lang = span.language;
    if (['rtl','ltr','auto'].includes(span.direction)) { el.dir = span.direction; el.style.unicodeBidi = 'isolate'; }
    if (['label','citation','pronunciation','headword'].includes(span.role)) el.classList.add(span.role);
    for (const [flag, tag] of [['bold','strong'],['italic','em'],['code','code'],['small','small'],['superscript','sup'],['subscript','sub'],['strike','s'],['underline','u']]) {
      if (span[flag]) { const wrapper = node(tag); wrapper.append(el); el = wrapper; }
    }
    if (span.explanation) {
      const annotation=node(explanationTag(span));annotation.title=span.explanation;
      if(described.has(i))annotation.setAttribute('aria-describedby',described.get(i));
      annotation.append(el);el=annotation;
    }
    const imageURL=span.image&&span.kind==='link'?safeURL(explanations?.imageActionURL?.(span.target)):null;
    if(imageURL){
      const link=node('a');link.href=imageURL;link.rel='noopener noreferrer';link.target='_blank';if(withinSummary)link.addEventListener('click',event=>event.stopPropagation());link.append(el);el=link;
    } else if(span.image&&span.kind==='link'&&span.target?.startsWith('File:')){
      const unresolved=node('span');unresolved.setAttribute('role','link');unresolved.setAttribute('aria-disabled','true');unresolved.dataset.actionTarget=span.target;unresolved.append(el);el=unresolved;
    } else if (span.kind === 'link' && span.target) {
      const link = node('a'); link.href = '#' + encodeURIComponent(span.target);
      link.addEventListener('click', event => { event.preventDefault(); if(withinSummary)event.stopPropagation(); onLink(span.target); }); link.append(el); el = link;
    } else if (span.kind === 'external_link' && safeURL(span.target)) {
      const link = node('a'); link.href = safeURL(span.target); link.rel = 'noopener noreferrer'; link.target = '_blank'; if(withinSummary)link.addEventListener('click',event=>event.stopPropagation()); link.append(el); el = link;
    }
    if(described.has(i) && el.tagName==='A')el.setAttribute('aria-describedby',described.get(i));
    const trail=trailNode(span,i);
    const fontSize=semanticFontSize(span);
    if(fontSize!==null){
      const scaled=node('span');scaled.style.fontSize=fontSize;
      scaled.append(el,trail);fragment.append(scaled);continue;
    }
    fragment.append(el,trail);
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
  if (['DPR5','DPR6','DPR7','DPR8','DPR9','DPRA','DPRB','DPRC','DPRD','DPRE'].includes(entry.presentation_version)) return new Map();
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
function styleObject(value){if(value==null)return null;if(typeof value!=='object'||Array.isArray(value)||!Object.values(value).some(field=>field!=null))throw Error('Invalid typed table style');return value;}
function styleLength(value){if(!value||!['px','em'].includes(value.unit)||typeof value.value!=='number'||!Number.isFinite(value.value)||value.value<0)throw Error('Invalid style length');return value.value+value.unit;}
function styleBorder(value){if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==1)throw Error('Invalid style border');if(Object.hasOwn(value,'none')){if(!value.none||typeof value.none!=='object'||Array.isArray(value.none)||Object.keys(value.none).length)throw Error('Invalid none border');return 'none';}const solid=value.solid;if(!solid||!canonicalRGB(solid.color))throw Error('Invalid style border color');return styleLength(solid.width)+' solid '+solid.color;}
function styleEdges(el,name,value){if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid style edges');for(const side of ['top','right','bottom','left'])el.style[name+side[0].toUpperCase()+side.slice(1)]=styleLength(value[side]);}
function applyTableStyle(el,value){const s=styleObject(value);if(!s)return;for(const key of Object.keys(s))if(!['background','border','collapse','margins','float_side'].includes(key))throw Error('Invalid table style field');if(s.background!=null){if(!canonicalRGB(s.background))throw Error('Invalid table background');el.style.backgroundColor=s.background;}if(s.border!=null)el.style.border=styleBorder(s.border);if(s.collapse!=null){if(!['separate','collapse'].includes(s.collapse))throw Error('Invalid border collapse');el.style.borderCollapse=s.collapse;}if(s.margins!=null)styleEdges(el,'margin',s.margins);if(s.float_side!=null&&!['left','right'].includes(s.float_side))throw Error('Invalid table float side');}
function applyCellStyle(el,value){const s=styleObject(value);if(!s)return;for(const key of Object.keys(s))if(!['border','padding','text_align'].includes(key))throw Error('Invalid cell style field');if(s.border!=null)el.style.border=styleBorder(s.border);if(s.padding!=null)styleEdges(el,'padding',s.padding);if(s.text_align!=null){if(!['left','center','right'].includes(s.text_align))throw Error('Invalid cell text alignment');el.style.textAlign=s.text_align;}}
function tableView(value,onLink,explanations,depth=1,inheritedBackground=null){
  if(depth>16)throw Error('Nested table depth exceeds limit');
  if(value.geometry!=null&&(typeof value.geometry!=='object'||Array.isArray(value.geometry)))throw Error('Invalid table geometry object');
  const table=node('table'),g=value.geometry||{};
  const dimension=key=>{const n=g[key];if(n==null)return null;if(!Number.isInteger(n)||n<0||n>65535)throw Error('Invalid table geometry');return n;};
  const border=dimension('border'),spacing=dimension('cell_spacing'),padding=dimension('cell_padding');
  if(spacing!==null){table.style.borderCollapse='separate';table.style.borderSpacing=spacing+'px';}
  if(g.width!=null){const {unit,value:n}=g.width;if(!['px','percent'].includes(unit)||!Number.isInteger(n)||n<0||n>4294967295||(unit==='percent'&&n>100))throw Error('Invalid table width');table.style.width=n+(unit==='percent'?'%':'px');}
  applyTableStyle(table,value.style);
  const tableBackground=canonicalRGB(value.style?.background)?value.style.background:inheritedBackground;
  if(value.caption?.length){const caption=node('caption');caption.append(spans(value.caption,onLink,false,explanations,false,tableBackground));table.append(caption);}
  for(const row of value.rows){const tr=node('tr');for(const cell of row.cells){
    const td=node(cell.header?'th':'td');td.colSpan=cell.colspan||1;td.rowSpan=cell.rowspan||1;
    if(border!==null)td.style.border=border+'px solid currentColor';if(padding!==null)td.style.padding=padding+'px';
    applyCellStyle(td,cell.style);
    const effectiveBackground=canonicalRGB(cell.background)?cell.background:tableBackground;
    if(canonicalRGB(effectiveBackground))td.style.backgroundColor=effectiveBackground;
    if(cell.blocks!=null){
      if(!Array.isArray(cell.blocks)||cell.spans?.length||cell.nested_table!=null)throw Error('Invalid ordered table cell');
      appendBlocks(td,cell.blocks,block=>blockView(block,onLink,explanations,'',{tableDepth:depth,background:effectiveBackground,header:!!cell.header}));
    }else if(cell.nested_table!=null){if(typeof cell.nested_table!=='object'||Array.isArray(cell.nested_table)||cell.spans?.length)throw Error('Invalid nested table cell');td.append(cell.nested_table.style?.float_side!=null?blockView({kind:'table',table:cell.nested_table},onLink,explanations,'',{tableDepth:depth,background:effectiveBackground}):tableView(cell.nested_table,onLink,explanations,depth+1,effectiveBackground));}
    else td.append(spans(cell.spans,onLink,false,explanations,false,effectiveBackground));
    tr.append(td);
  }table.append(tr);}return table;
}
function visibleBlock(block){
  return block.kind!=='blank'&&(block.table||block.kind==='rule'||block.spans?.some(s=>s.image||s.text?.trim()||s.trail?.trim())||block.spans?.some(isPoem)||(block.kind==='heading'&&(block.anchor||block.anchor_fallback)));
}
function appendBlocks(parent,values,render){
  let lists=[];
  for(const block of values){
    const visible=visibleBlock(block);
    const path=block.list_path??block.path??'';
    if(block.kind==='list_item'){
      const key=/^[*#:;]*[*#]$/.test(path)?path:(block.number?'#':'*');
      let at=lists.findIndex(list=>list.path===key);
      if(at<0){
        while(lists.length&&!key.startsWith(lists.at(-1).path))lists.pop();
        const owner=lists.at(-1)?.item||parent,list=node(key.endsWith('#')?'ol':'ul',null,'compiled-list');
        // Retain list semantics when custom visible markers suppress native markers.
        list.setAttribute('role','list');owner.append(list);
        lists.push({path:key,list,item:null});at=lists.length-1;
      }
      lists.length=at+1;
      const current=lists[at],item=node('li',null,'compiled-list-item');
      if(key.endsWith('#')&&/^-?\d+$/.test(block.number||'')){
        const number=Number(block.number);
        if(Number.isInteger(number)&&number>=-2147483648&&number<=2147483647)item.value=number;
      }
      if(visible){
        const view=render(block);
        if(!block.number)view.querySelector(':scope > .prefix')?.setAttribute('aria-hidden','true');
        item.append(view);
      }
      current.list.append(item);current.item=item;
    }else{
      const continuation=block.kind==='list_detail'?/^([*#:;]*[*#]):+$/.exec(path):null;
      const at=continuation?lists.findIndex(list=>list.path===continuation[1]):-1;
      if(at>=0&&lists[at].item){
        lists.length=at+1;
        if(visible){const view=render(block);view.querySelector(':scope > .prefix')?.setAttribute('aria-hidden','true');lists[at].item.append(view);}
      }else{lists=[];if(visible)parent.append(render(block));}
    }
  }
}
function visitBlocks(values,visit){
  const table=value=>{for(const row of value.rows||[])for(const cell of row.cells||[]){if(cell.blocks!=null)visitBlocks(cell.blocks,visit);else if(cell.nested_table)table(cell.nested_table);}};
  for(const block of values||[]){visit(block);if(block.table)table(block.table);}
}
function blockView(block, onLink, explanations, legacy = '', context = {}) {
  if(block.text_align!=null&&!['left','center','right'].includes(block.text_align))throw Error('Invalid block text alignment');
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
    const table = tableView(block.table,onLink,explanations,(context.tableDepth||0)+1,context.background);
    if(context.tableDepth&&!block.table.style?.float_side){table.style.marginInlineStart=margin;return table;}
    const wrap = node('div', null, 'table-scroll'); wrap.style.marginInlineStart = margin; wrap.tabIndex = 0; wrap.setAttribute('aria-label','Scrollable table');
    if(block.table.style?.float_side){
      wrap.classList.add('compiled-table-float');wrap.style.cssFloat=block.table.style.float_side;
      // The scroll box itself floats: its margin box excludes following text.
      if(block.table.style.margins)styleEdges(wrap,'margin',block.table.style.margins);
      wrap.style.setProperty('--compiled-float-left',block.table.style.margins?styleLength(block.table.style.margins.left):'0px');
      wrap.style.setProperty('--compiled-float-right',block.table.style.margins?styleLength(block.table.style.margins.right):'0px');
      // Keep semantic indentation in addition to the authored physical margin.
      wrap.style.removeProperty('margin-inline-start');
      wrap.style.marginInlineStart=`calc(${margin} + var(--compiled-float-inline-margin))`;
      if(block.table.geometry?.width?.unit==='percent'){wrap.style.width=block.table.geometry.width.value+'%';table.style.width='100%';}
      for(const side of ['Top','Right','Bottom','Left'])table.style['margin'+side]='0';
    }
    wrap.append(table); return wrap;
  }
  if (block.kind === 'rule') return node('hr');
  if (block.kind === 'preformatted') { const pre = node('pre'); if(block.text_align!=null)pre.style.textAlign=block.text_align; if(context.header)pre.style.fontWeight='inherit'; pre.append(spans(block.spans,onLink,true,explanations,false,context.background)); return pre; }
  const allowed = new Set(['paragraph','definition','example','quotation','list_item','list_detail','indent','term','heading']);
  const kind = allowed.has(block.kind) ? block.kind : 'paragraph';
  const el = node(kind === 'heading'?'h'+(Number.isInteger(block.level)&&block.level>=1&&block.level<=6?block.level:4):'div',null,'block '+kind);
  el.style.marginInlineStart = margin;
  if(context.tableDepth||block.text_align!=null)el.classList.add('compiled-aligned-block');
  if(block.text_align!=null)el.style.textAlign=block.text_align;
  if(context.header)el.style.fontWeight='inherit';
  if (kind === 'heading') destination(el, block, legacy);
  const prefix = kind==='definition'?(block.number?`${block.number}.`:'•'):['example','quotation'].includes(kind)?'│':kind==='list_item'?(block.number?`${block.number}.`:'•'):kind==='list_detail'?'↳':'';
  if (prefix) el.append(node('span',prefix,'prefix'));
  const body = node('span',null,'body'); if(block.spans?.some(isPoem))body.style.flex='1'; body.append(spans(block.spans,onLink,false,explanations,false,context.background)); el.append(body); return el;
}
function sectionHeadingCompanion(section){
  const first=section.blocks?.[0];
  if(!section.title||!first||first.kind!=='heading'||first.level!==section.level)return null;
  if(first.text_align!=null)return null;
  let navigable=false,explained=false,styledText=false,visual=false,label='';
  for(const span of first.spans||[]){
    if(span.kind==='line_break'&&span.trail)return null;
    visual=visual||span.image!=null;
    explained=explained||!!span.explanation;
    navigable=navigable||(['link','external_link'].includes(span.kind)&&!!span.target&&!!(span.text||span.trail));
    const styled=['bold','italic','code','small','superscript','subscript','strike','underline'].some(flag=>span[flag])||
      (span.font_scale_basis==='normal_body'||(span.font_scale!=null&&span.font_scale!==1))||span.foreground!=null||span.background!=null||!!span.classes||!!span.language||!!span.direction||(span.role??'normal')!=='normal';
    styledText=styledText||(span.kind==='text'&&!!span.text&&!span.target&&styled);
    label+=span.kind==='line_break'?'\n':(span.text||'')+(span.trail||'');
  }
  const trimmed=label.replace(/^[ \t\r\n\u00a0]+|[ \t\r\n\u00a0]+$/g,'');
  return (navigable||explained||styledText||visual||first.depth>0)&&trimmed===section.title?first:null;
}
export function renderEntry(entry, onLink, settings = {}, mediaView = () => null, inlineImage = () => {}, imageActionURL = () => null) {
  const fragment = document.createDocumentFragment(), references = new Map(), legacy = legacyDestinations(entry);
  let hasTableFloat=false;
  const inspectTableFloat=table=>{
    if(table.style?.float_side!=null){if(!['left','right'].includes(table.style.float_side))throw Error('Invalid table float side');hasTableFloat=true;}
    for(const row of table.rows||[])for(const cell of row.cells||[])if(cell.nested_table)inspectTableFloat(cell.nested_table);
  };
  const inspectFloat=block=>{if(block.table)inspectTableFloat(block.table);};
  for(const section of entry.sections)visitBlocks(section.blocks,inspectFloat);
  for(const ref of entry.references||[])if(Array.isArray(ref.blocks))visitBlocks(ref.blocks,inspectFloat);
  const root=hasTableFloat?node('div',null,'compiled-table-flow'):fragment;
  if(hasTableFloat)fragment.append(root);
  const headingDestinations = new Set();
  const observeHeading=value=>{for(const id of [value.anchor,value.anchor_fallback,legacy.get(value)])if(id)headingDestinations.add(id);};
  for(const section of entry.sections){observeHeading(section);visitBlocks(section.blocks,block=>{if(block.kind==='heading')observeHeading(block);});}
  for(const ref of entry.references||[]){
    if(ref.blocks!=null){
      if(!Array.isArray(ref.blocks)||!Array.isArray(ref.spans)||ref.spans.length)throw Error('Invalid structured reference');
      visitBlocks(ref.blocks,block=>{if(block.kind==='heading')observeHeading(block);});
    }
  }
  const explanationRows=[], explanationKeys=new Map();
  const mediaOwnerPrefix='wikidict-media-file-',mediaOwners=new Map();
  for(const media of entry.media||[])if(media.kind==='audio'&&media.file){
    const hex=[...new TextEncoder().encode(media.file)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
    mediaOwners.set(mediaOwnerPrefix+hex,media.file);
  }
  const explanations={inlineImage,imageActionURL,isMediaExplanation(span){
    if(span.kind!=='link'||span.image)return false;
    const tokens=poemTokens(span),owners=tokens.filter(token=>token.startsWith(mediaOwnerPrefix));
    // Match the compiled media catalog, not an ordinary File link or a legacy abbreviation.
    const file=owners.length===1?mediaOwners.get(owners[0]):null;
    return !!file&&tokens.includes('wikidict-media')&&span.text===file&&span.target==='File:'+file;
  },add(label,explanation){
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
  const language=node('p',entry.language || entry.kind,'entry-language');
  const ownerSections=entry.kind==='language'&&entry.language?
    entry.sections.filter(section=>section.level===2&&section.title===entry.language):[];
  const emptyOwner=ownerSections.length===1&&ownerSections[0].blocks.length===0?ownerSections[0]:null;
  // Keep the compiled language destination on its visible label, without an empty disclosure.
  if(emptyOwner)destination(language,emptyOwner,legacy.get(emptyOwner)||'');
  root.append(language);
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
    if(section===emptyOwner)continue;
    const meaning=section.blocks.some(b=>b.kind==='definition');
    const expanded=meaning || (section.title.startsWith('Pronunciation')?!settings.collapsePronunciation:section.title.startsWith('Etymology')?!settings.collapseEtymology:!settings.collapseOtherSections);
    const companion=sectionHeadingCompanion(section);
    const el=fold(section.title===entry.language?'Overview':section.title||'Notes',expanded,companion?.spans,companion?.depth);
    el.classList.toggle('meaning',meaning);destination(el,section,legacy.get(section)||'');
    const main=[],notes=[];
    for (const block of section.blocks.slice(companion?1:0)) {
      if(meaning&&block.kind!=='definition')notes.push(block);else main.push(block);
    }
    const view=block=>blockView(block,followLink,explanations,legacy.get(block)||'');
    appendBlocks(el,main,view);
    if(notes.some(visibleBlock)){const details=fold('Examples & notes',!settings.collapseDetails);details.className='sense-notes';appendBlocks(details,notes,view);el.append(details);}
    if(section.blocks.some(visibleBlock)||companion||section.anchor||section.anchor_fallback)root.append(el);
  }
  if (entry.references?.length) {
    const section=fold('References',!settings.collapseOtherSections);
    const referenceIDs=new Set(headingDestinations);
    for (const ref of entry.references) {
      const p=node(ref.blocks!=null?'div':'p',null,'reference'),kind=ref.kind??'note';
      if(kind==='note'){
        const target=`reference-${ref.number}`;let id=target;
        while(referenceIDs.has(id))id='citation-'+id;
        referenceIDs.add(id);p.id=id;p.tabIndex=-1;references.set(`#${target}`,p);
        p.append(node('span',`[${ref.group?ref.group+' ':''}${ref.group_number}]`));
      }else if(kind!=='fragment')throw Error('Invalid compiled reference kind');
      if(ref.blocks!=null)appendBlocks(p,ref.blocks,block=>blockView(block,followLink,explanations));
      else {const body=node('span');body.append(spans(ref.spans,followLink,false,explanations));p.append(body);}
      section.append(p);
    }
    root.append(section);
  }
  const canonicalImageFiles=new Set();
  const imageSpans=values=>{for(const span of values||[])if(span.image)canonicalImageFiles.add(span.image.file);};
  const imageTable=value=>{imageSpans(value.caption);for(const row of value.rows||[])for(const cell of row.cells||[]){imageSpans(cell.spans);if(cell.blocks)imageBlocks(cell.blocks);if(cell.nested_table)imageTable(cell.nested_table);}};
  const imageBlocks=values=>{for(const block of values||[]){imageSpans(block.spans);if(block.table)imageTable(block.table);}};
  imageSpans(entry.display_title);imageSpans(entry.preamble_spans);for(const section of entry.sections||[])imageBlocks(section.blocks);for(const ref of entry.references||[]){imageSpans(ref.spans);imageBlocks(ref.blocks);}
  if (entry.media?.length) { const section=fold('Images & sound',!settings.collapseOtherSections);for(const media of entry.media){const view=mediaView(media,canonicalImageFiles.has(media.file));if(view)section.append(view);}root.append(section); }
  if(explanationRows.length){
    const details=fold('Text details',false),list=node('dl');details.className='abbreviation-explanations';
    for(const row of explanationRows){
      const label=node('dt',row.label),description=node('dd',row.explanation);description.id=row.id;
      list.append(label,description);
    }
    details.append(list);root.append(details);
  }
  const edition=/^[a-z0-9_-]+wiktionary$/.test(entry.source_edition||'')?entry.source_edition.slice(0,-10).replaceAll('_','-'):null;
  const source=edition?'https://'+edition+'.wiktionary.org/':'https://www.wiktionary.org/';
  const credit=node('footer');const link=node('a','Wiktionary contributors');link.href=source+(edition&&entry.source_title?'wiki/'+encodeURIComponent(entry.source_title):'');link.target='_blank';link.rel='noopener';credit.append(link,node('span','CC BY-SA 4.0'));root.append(credit);
  return fragment;
}
