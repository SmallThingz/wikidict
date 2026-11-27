import {fontFamilyCSS,validateFontFamily} from './font-family.js';
const canonicalRGB=value=>typeof value==='string'&&value.length===7&&/^#[0-9a-f]{6}$/.test(value);
const rgbBytes=color=>[1,3,5].map(at=>parseInt(color.slice(at,at+2),16));
const luminance=rgb=>rgb.reduce((sum,value,i)=>{
  const v=value/255;
  return sum+[.2126,.7152,.0722][i]*(v<=.04045?v/12.92:((v+.055)/1.055)**2.4);
},0);
const contrastInk=background=>{
  const light=luminance(rgbBytes(background));
  return (light+.05)/.05>=1.05/(light+.05)?'#000000':'#ffffff';
};
function darkReadingInk(foreground,background){
  const source=rgbBytes(foreground),minimum=4.5*(luminance(rgbBytes(background))+.05)-.05;
  if(luminance(source)>=minimum||minimum>1)return null;
  // Lift the color toward white by the smallest amount that meets body-text contrast.
  const mix=amount=>source.map(channel=>Math.round(channel+(255-channel)*amount/255));
  let low=1,high=255;
  while(low<high){const mid=(low+high)>>1;if(luminance(mix(mid))>=minimum)high=mid;else low=mid+1;}
  return '#'+mix(low).map(channel=>channel.toString(16).padStart(2,'0')).join('');
}
import {safeURL,linkTargetParts,bookSourcesURL,validateDescriptionBody,validateDarkForeground,validateContainerBlock,validateCellMetrics,validateRuby,validateRubyOwner,validateRubySpan,validateActionGroupSpan,validateInlineBoxSpan,validateFigureIntrinsicSize,validateClippedSpan,validateAudioControl,validateWrappedHeading,validateTableDisclosure} from './validate.js';
import {validateColumnBreakInside,validateSourceAnchor,validateSourceAnchorDestinations} from './validate.js';
import {validateInlineDestinationList,validateInlineDestinationEntry} from './validate.js';
import {validateResponsiveCaptionTable} from './validate.js';
import {containerDisclosureItems,installContainerDisclosure} from './container-disclosure.js';
import {previewBlocks,inlineText} from './preview.js';
import {figureImageSize,audioControlView} from './media.js';
const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = text; if (cls) el.className = cls; return el; };
let explanationSequence = 0;
// Data-only destinations refer to existing text nodes; they add no DOM box or focus target.
const inlineDestinationOwners=new WeakMap();
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
  const unlinkedTrail=(span,trail)=>{const copy={...span,kind:'text',target:'',text:'',trail};delete copy.target_fragment;return copy;};
  const appendPart=(span,text,trail)=>{
    const pieces=text.split('\n');
    for(let i=0;i<pieces.length;i++){
      if(pieces[i]){
        include(span);
        line.push(trail?unlinkedTrail(span,pieces[i]):{...span,text:pieces[i],trail:''});
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
      if(span.trail){span=appendPart(unlinkedTrail(span,span.trail),span.trail,true);}
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
function semanticFontSize(span,declaringFont=null) {
  const basis=span.font_scale_basis===undefined?'context':span.font_scale_basis,scale=span.font_scale;
  if(!['context','normal_body','css_px'].includes(basis))throw new Error('invalid semantic font scale basis');
  if(declaringFont!==null&&basis==='context'){
    if((declaringFont.font_scale_basis??'context')!=='context')throw Error('Unsupported ruby contextual font basis');
    const owner=declaringFont.font_scale??1;if(!Number.isFinite(owner)||owner<=0)throw Error('Unsupported ruby declaring font size');
    const ratio=(scale??1)/owner;if(!Number.isFinite(ratio)||ratio<0)throw Error('Invalid ruby font ratio');
    return ratio===1?null:ratio===0?'0px':`min(10000px, ${ratio}em)`;
  }
  if(scale===undefined||scale===null){if(basis!=='context')throw new Error('normal body scale is absent');return null;}
  if(typeof scale!=='number'||!Number.isFinite(scale)||scale<0)throw new Error('invalid semantic font scale');
  const size=basis==='css_px'?`${scale}px`:basis==='normal_body'?`calc(var(--wikidict-normal-body-size) * ${scale})`:(scale===1?null:`${scale}em`);
  // Match the browser's computed-font ceiling in CSS pixels, retaining semantic
  // scale and the zero/identity paths rather than rewriting compiled data.
  return scale>0&&size!==null?`min(10000px, ${size})`:size;
}
function validateImageOccurrence(image){
  if(image.map||image.static_poster)throw Error('Conflicting image occurrence geometry');
  const fields=['x','y','padding_left','padding_right'];
  const box=richObject(image.occurrence_layout,fields,fields);
  for(const key of fields){
    const length=richObject(box[key],['unit','value'],['unit','value']);
    if(!['px','em'].includes(length.unit)||!Number.isFinite(length.value)||Math.abs(length.value)>3.4028234663852886e38||
       (key.startsWith('padding_')&&length.value<0))throw Error('Invalid inline image occurrence length');
  }
}
function inlineImageElement(image,load,options={}){
  if(!image||typeof image.file!=='string'||!image.file||new TextEncoder().encode(image.file).length>32*1024*1024||image.file.startsWith(' ')||image.file.endsWith(' ')||/[_\[\]{}<>|#\x00-\x1f\x7f-\x9f]/u.test(image.file))throw Error('Invalid inline image');
  if(image.border!==undefined&&typeof image.border!=='boolean')throw Error('Invalid inline image border');
  if(image.dark_mode_filter!==undefined&&image.dark_mode_filter!=='invert_hue_rotate_180')throw Error('Invalid image dark-mode filter');
  const el=node('img');el.className='compiled-inline-image';el.style.display='inline';el.style.verticalAlign='middle';el.style.border=image.border?'1px solid #eaecf0':'0';el.style.maxWidth='10000px';el.style.maxHeight='10000px';el.style.margin='0';el.style.borderRadius='0';el.style.objectFit='fill';
  if(image.dark_mode_filter!==undefined)el.dataset.darkModeFilter=image.dark_mode_filter;
  // The authored border surrounds the content box; site-wide border-box must not shrink it.
  if(image.border){el.style.boxSizing='content-box';el.style.padding='0';}
  for(const [key,axis] of [['width_px','width'],['height_px','height']])if(image[key]!=null){if(!Number.isInteger(image[key])||image[key]<=0||image[key]>4294967295)throw Error('Invalid image dimension');el.style[axis]=image[key]+'px';}
  const pendingScale=Math.min(1,image.width_px==null?1:10000/image.width_px,image.height_px==null?1:10000/image.height_px);
  if(image.width_px!=null)el.style.width=image.width_px*pendingScale+'px';if(image.height_px!=null)el.style.height=image.height_px*pendingScale+'px';
  if(image.width_px!=null&&image.height_px==null)el.style.height='auto';if(image.height_px!=null&&image.width_px==null)el.style.width='auto';
  for(const [key,attr] of [['alt','alt'],['tooltip','title']])if(image[key]!=null){if(typeof image[key]!=='string')throw Error('Invalid image description');el.setAttribute(attr,image[key]);}
  if(options.figureImage)el.style.border='0';
  if(options.intrinsic_size){
    const axes=options.intrinsic_size;
    const size=figureImageSize(image,options.sizing,{width:axes.width_px,height:axes.height_px});
    const scale=Math.min(1,10000/size.width,10000/size.height);
    el.style.width=size.width*scale+'px';
    el.style.height=size.height*scale+'px';
  }
  el.dataset.mediaState='pending';load?.(el,image,options.intrinsic_size?{sizing:options.sizing,intrinsic_size:options.intrinsic_size}:options.sizing==null?{}:{sizing:options.sizing});return el;
}
function rubyOwnerStyle(el,owner,contextFont){
  validateRubyOwner(owner);const font=owner.font;
  if(font.small||font.superscript||font.subscript)throw Error('Unsupported ruby owner script metrics');
  const size=semanticFontSize(font,contextFont);el.style.fontSize=size??'inherit';el.style.fontWeight=font.bold?'bold':'normal';el.style.fontStyle=font.italic?'italic':'normal';
  if(font.code)el.style.fontFamily='monospace';if(font.language)el.lang=font.language;
  if(owner.direction){el.dir=owner.direction;el.style.unicodeBidi='isolate';}
  if(owner.foreground!=null)el.style.color=owner.foreground;if(owner.background!=null)el.style.backgroundColor=owner.background;
  const height=owner.inline_style?.line_height;
  if(height?.font_relative)el.style.lineHeight=String(height.font_relative.factor);
  if(height?.computed){const n=height.computed;el.style.lineHeight=n.font_scale_basis==='css_px'?n.value+'px':`calc(var(--wikidict-normal-body-size) * ${n.value})`;}
}
function rubySpans(value,onLink,explanations,withinSummary,cellBackground,contextFont){
  validateRuby(value);
  if(value.segments.some(segment=>segment.annotations.some(annotation=>annotation.level!==0)))throw Error('Unsupported multilevel ruby association');
  const out=document.createDocumentFragment();
  const children=(values,font=contextFont)=>spans(values,onLink,true,explanations,withinSummary,cellBackground,font);
  const base=value=>{const el=node('span',null,'compiled-ruby-base');rubyOwnerStyle(el,value.owner,contextFont);el.append(children(value.spans,value.owner.font));return el;};
  for(const segment of value.segments){
    out.append(children(segment.gap_before));let index=0;
    for(const annotation of segment.annotations){
      while(index<annotation.base_start){out.append(children(segment.bases[index].gap_before),base(segment.bases[index]));index++;}
      const ruby=node('ruby',null,'compiled-ruby');ruby.style.rubyPosition='over';
      const end=annotation.base_start+annotation.base_count;
      while(index<end){ruby.append(children(segment.bases[index].gap_before),base(segment.bases[index]));index++;}
      if(annotation.explicit_fallback){const rp=node('rp');rp.append(children(annotation.fallback_before));ruby.append(rp);}
      const rt=node('rt',null,'compiled-ruby-annotation');rubyOwnerStyle(rt,annotation.owner,contextFont);rt.append(children(annotation.gap_before,annotation.owner.font),children(annotation.spans,annotation.owner.font));ruby.append(rt);
      if(annotation.explicit_fallback){const rp=node('rp');rp.append(children(annotation.fallback_after));ruby.append(rp);}
      out.append(ruby);
    }
    while(index<segment.bases.length){out.append(children(segment.bases[index].gap_before),base(segment.bases[index]));index++;}
  }
  return out;
}
const inlineBoxEdges=['top','right','bottom','left'];
function inlineBoxBorders(element,border,resolveLength=styleLength){
  for(const side of inlineBoxEdges){
    const edge=border[side];
    let value=edge.kind;
    if(edge.width){
      const color=edge.color;
      const ink=color.kind==='rgb'?color.value:color.kind==='light_dark'?`light-dark(${color.light}, ${color.dark})`:color.kind==='current_color'?'currentColor':'transparent';
      value=`${resolveLength(edge.width)} ${edge.kind} ${ink}`;
    }
    element.style.setProperty('border-'+side,value);
  }
}
function applyInlineBox(element,group){
  element.classList.add('compiled-inline-box');
  element.style.boxDecorationBreak='slice';
  element.style.boxSizing='content-box';
  const atomic=group.atomic_layout;
  const length=atomic?value=>value.value+value.unit:styleLength;
  if(atomic){
    element.style.display='inline-block';
    element.style.verticalAlign='baseline';
    element.style.boxSizing=atomic.box_sizing.replace('_','-');
    element.style.width=length(atomic.width);
    element.style.height=length(atomic.height);
    element.style.textAlign=atomic.text_align;
    element.style.overflowWrap=atomic.wrap.replace('_','-');
    element.style.whiteSpace='normal';
    if(!atomic.line_height)element.style.lineHeight='normal';
    else if(atomic.line_height.font_relative)element.style.lineHeight=String(atomic.line_height.font_relative.factor);
    styleEdges(element,'margin',atomic.margins,length);
  }
  styleEdges(element,'padding',group.padding,length);
  inlineBoxBorders(element,group.border,length);
  if(group.radius)element.style.borderRadius=group.radius.value+(group.radius.unit==='percent'?'%':'px');
  if(group.overlays.length)element.style.position='relative';
  for(const overlay of group.overlays){
    const layer=node('span',null,'compiled-inline-box-overlay');
    layer.setAttribute('aria-hidden','true');
    layer.style.position='absolute';layer.style.pointerEvents='none';
    for(const [side,inset] of Object.entries(overlay.insets))if(inset!=null)
      layer.style.setProperty(side,inset.value+(inset.unit==='percent'?'%':inset.unit));
    inlineBoxBorders(layer,overlay.border);
    element.append(layer);
  }
}
function applyInlineTextStyle(element,span,lineOwner=element){
  if(span.font_features!=null){
    if(!['normal','seven_on'].includes(span.font_features))throw Error('Invalid compiled font feature policy');
    element.style.fontFeatureSettings=span.font_features==='normal'?'normal':'"liga" 1, "clig" 1, "kern" 1, "ccmp" 1, "dist" 1, "mark" 1, "mkmk" 1';
  }
  const style=span.inline_style;
  if(!style)return;
  const computed=length=>{
    if(!Number.isFinite(length.value)||!['css_px','normal_body'].includes(length.font_scale_basis))throw Error('Invalid compiled inline length');
    return length.font_scale_basis==='css_px'?`${length.value}px`:`calc(var(--wikidict-normal-body-size) * ${length.value})`;
  };
  if(style.decoration){
    const decoration=style.decoration;
    if(!['solid','dotted'].includes(decoration.style)||decoration.color!=null&&!canonicalRGB(decoration.color))throw Error('Invalid compiled underline');
    element.style.textDecorationLine='underline';element.style.textDecorationStyle=decoration.style;
    if(decoration.color!=null)element.style.textDecorationColor=decoration.color;
    if(decoration.thickness)element.style.textDecorationThickness=styleLength(decoration.thickness);
  }
  if(style.cursor!=null){if(style.cursor!=='help')throw Error('Invalid compiled cursor');element.style.cursor=style.cursor;}
  if(style.wrap!=null){if(!['normal','break_word'].includes(style.wrap))throw Error('Invalid compiled inline wrap');element.style.overflowWrap=style.wrap.replace('_','-');}
  if(style.baseline_shift)element.style.verticalAlign=computed(style.baseline_shift);
  if(style.line_height?.computed)lineOwner.style.lineHeight=computed(style.line_height.computed);
  if(style.line_height?.font_relative){
    const {font,factor}=style.line_height.font_relative;
    if(!Number.isFinite(factor)||factor<0)throw Error('Invalid compiled inline line height');
    const basis=font.font_scale_basis??'context',scale=font.font_scale??1;
    if(basis==='context'){
      if((span.font_scale_basis??'context')!=='context'||(span.font_scale??1)<=0)throw Error('Unsupported inline declaring font');
      lineOwner.style.lineHeight=String(factor*scale/(span.font_scale??1));
    }else lineOwner.style.lineHeight=computed({font_scale_basis:basis,value:factor*scale});
  }
}
// Source-order semantic bodies never leave their original line. The nonpainting
// exterior rectangle belongs to the article, beyond any scrollable table.
const exteriorBoxes=new WeakMap();
function sizeClippedBox(box,value){
  box.style.width=styleLength(value.width);
  box.style.height=styleLength(value.height);
  for(const side of ['top','right','bottom','left']){
    const {unit,value:amount}=value.margin[side].length;
    box.style.setProperty('margin-'+side,unit==='px'?amount+'px':'calc(var(--wikidict-normal-body-size) * '+amount+')');
  }
}
function clippedOccurrence(el,value,projections){
  el.classList.add('compiled-clipped-body');
  const exterior=value.containing_block==='article_exterior';
  el.dataset.clippedOwner=exterior?'article_exterior':'initial';
  sizeClippedBox(el,value);
  if(!exterior)return el;
  if(!projections)throw Error('Clipped absolute requires an article projection');
  const source=node('span',null,'compiled-clipped-static');
  source.dir=value.static_parent_direction;
  const origin=node('span',null,'compiled-clipped-origin');
  origin.setAttribute('aria-hidden','true');
  const box=node('span',null,'compiled-clipped-border');
  box.setAttribute('aria-hidden','true');
  sizeClippedBox(box,value);
  source.append(origin,el);
  exteriorBoxes.set(el,box);
  projections.push({source,origin,el,box,rtl:value.static_parent_direction==='rtl'});
  return source;
}
function wrapExteriorBoxes(fragment,projections){
  const name='wikidict-clipped-article';
  if(!customElements.get(name))customElements.define(name,class extends HTMLElement{
    connectedCallback(){this.stopProjection=this.startProjection?.();}
    disconnectedCallback(){this.stopProjection?.();}
  });
  const article=document.createElement(name);
  article.append(fragment);
  article.startProjection=()=>connectExteriorBoxes(article,projections);
  fragment.append(article);
}
function connectExteriorBoxes(article,projections){
  const plane=node('div',null,'compiled-clipped-plane');
  plane.setAttribute('aria-hidden','true');
  plane.append(...projections.map(item=>item.box));
  article.append(plane);
  let frame=0,connected=true;
  const queue=()=>{if(connected&&!frame)frame=requestAnimationFrame(update);};
  const resize=new ResizeObserver(queue),mutations=new MutationObserver(queue);
  function update(){
    frame=0;
    if(!article.isConnected)return;
    const parent=plane.getBoundingClientRect();
    for(const {source,origin,el,box,rtl} of projections){
      const visible=source.getClientRects().length>0;
      if(box.hidden===visible)box.hidden=!visible;
      if(!visible)continue;
      let dx=0,dy=0;
      for(let ancestor=source.parentElement;ancestor&&ancestor!==article;ancestor=ancestor.parentElement){
        if(ancestor.classList.contains('table-scroll')||ancestor.classList.contains('compiled-caption-scroll')){dx+=ancestor.scrollLeft;dy+=ancestor.scrollTop;}
      }
      const anchor=origin.getBoundingClientRect();
      if(rtl)box.style.right=(parent.right-anchor.right-dx)+'px';
      else box.style.left=(anchor.left-parent.left+dx)+'px';
      box.style.top=(anchor.top-parent.top+dy)+'px';
      // Keep selectable children at the same projected origin without extending
      // a table's scroll area or putting a second copy of the text in the DOM.
      el.style.transform='translate('+dx+'px,'+dy+'px)';
    }
  }
  resize.observe(article);
  for(const {source} of projections){
    const table=source.closest('table');if(table)resize.observe(table);
  }
  mutations.observe(article,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['open','hidden','class','dir']});
  article.addEventListener('scroll',queue,true);
  article.addEventListener('load',queue,true);
  article.addEventListener('toggle',queue,true);
  window.addEventListener('resize',queue);
  document.fonts?.ready.then(queue);
  queue();
  return ()=>{
    connected=false;
    resize.disconnect();mutations.disconnect();cancelAnimationFrame(frame);
    article.removeEventListener('scroll',queue,true);
    article.removeEventListener('load',queue,true);
    article.removeEventListener('toggle',queue,true);
    window.removeEventListener('resize',queue);
    plane.remove();
  };
}

export function spans(values = [], onLink = () => {}, preserve = false, explanations = null, withinSummary = false, cellBackground = null, rubyFontContext = null, darkReadingSurface = null, normalizedEmphasis = false, runStarts = null) {
  if(runStarts&&!preserve)throw Error('Inline destination requires complete serialized runs');
  for(const value of values)if(value.font_family!=null)validateFontFamily(value.font_family);
  for(const value of values)if(value.target_fragment!=null){if(value.kind!=='link')throw Error('Invalid target fragment kind');linkTargetParts(value.target,value.target_fragment);}
  if (!preserve && values.some(isPoem)) return poemSpans(values,onLink,explanations,withinSummary,cellBackground);
  const fragment = document.createDocumentFragment();
  const compact=[];
  const scaled=span=>semanticFontSize(span,rubyFontContext)!==null;
  values.forEach(value=>{if(value.clipped_absolute!=null)validateClippedSpan(value);if(value.inline_action_group!=null)validateActionGroupSpan(value);if(value.inline_box_group!=null)validateInlineBoxSpan(value);semanticFontSize(value,rubyFontContext);if(value.ruby!=null){validateRubySpan(value);validateRuby(value.ruby);}if(value.image&&(value.text!==''||(value.trail??'')!==''||!['text','link','external_link'].includes(value.kind)||(value.kind==='text'?!!value.target:!value.target)))throw Error('Invalid inline image action');});
  const blank=value=>!(value||'').includes('\u00a0')&&!(value||'').trim();
  for(const span of values){
    if(span.kind==='line_break' && !span.trail && (!compact.length||compact.at(-1).kind==='line_break'))continue;
    if(!span.clipped_absolute&&!span.ruby&&!span.image&&!span.inline_box_group&&!scaled(span)&&!canonicalRGB(span.background)&&span.kind==='text'&&blank(span.text)&&blank(span.trail)&&(!compact.length||compact.at(-1).kind==='line_break'))continue;
    compact.push(span);
  }
  while(compact.length&&!compact.at(-1).clipped_absolute&&!compact.at(-1).ruby&&!compact.at(-1).image&&!compact.at(-1).inline_action_group&&!compact.at(-1).inline_box_group&&!scaled(compact.at(-1))&&!canonicalRGB(compact.at(-1).background)&&((compact.at(-1).kind==='line_break'&&blank(compact.at(-1).trail))||(blank(compact.at(-1).text)&&blank(compact.at(-1).trail))))compact.pop();
  const visible = preserve||explanations?.preserveFlowSpacing?values:compact, described = new Map();
  for (let i=0;i<visible.length;) {
    const explanation=visible[i].explanation;
    if (!explanation) { i++; continue; }
    let end=i,label='';
    if(visible[i].kind==='line_break'){label=visible[i].trail||'';end++;}
    else while(end<visible.length && visible[end].kind!=='line_break' && visible[end].explanation===explanation) {
      label+=inlineText([visible[end]]);end++;
    }
    if (label.trim() && explanations) {
      const id=explanations.add(label.trim(),explanation);
      for(let j=i;j<end;j++)described.set(j,id);
    }
    i=end;
  }
  const inkFor=span=>canonicalRGB(span.foreground)?span.foreground:
    explanations?.captionInk??(canonicalRGB(span.background)?contrastInk(span.background):canonicalRGB(cellBackground)?contrastInk(cellBackground):null);
  const colorSpan=(el,span)=>{
    validateDarkForeground(span);
    const ink=inkFor(span);
    if(!ink)return;
    el.style.color=ink;
    if(span.inline_style?.dark_foreground)el.style.color='light-dark('+ink+', '+span.inline_style.dark_foreground+')';
    else if(darkReadingSurface&&span.kind==='text'&&canonicalRGB(span.foreground)&&!span.background){
      const dark=darkReadingInk(ink,darkReadingSurface);
      if(dark)el.style.color=`light-dark(${ink}, ${dark})`;
    }
  };
  const explanationTag=span=>explanations?.isMediaExplanation?.(span)?'span':'abbr';
  const trailNode=(span,i)=>{
    if(!span.explanation&&span.tooltip==null&&!inkFor(span)&&!canonicalRGB(span.background)&&span.font_family==null)return document.createTextNode(span.trail||'');
    if(!span.trail)return document.createTextNode('');
    const trail=node(span.explanation?explanationTag(span):'span',span.trail);
    if(span.font_family!=null)trail.style.fontFamily=fontFamilyCSS(span.font_family);
    if(span.explanation){trail.title=span.explanation;if(described.has(i))trail.setAttribute('aria-describedby',described.get(i));}
    if(span.tooltip!=null)trail.title=span.tooltip;
    colorSpan(trail,span);
    if(canonicalRGB(span.background)){trail.style.backgroundColor=span.background;trail.style.whiteSpace='pre-wrap';}
    return trail;
  };
  for (const [i,span] of visible.entries()) {
    if (span.kind === 'line_break') {
      const trail=trailNode(span,i);
      if(scaled(span)){
        const wrapper=node('span');wrapper.style.fontSize=semanticFontSize(span,rubyFontContext);wrapper.append(trail);fragment.append(node('br'),wrapper);
      }else fragment.append(node('br'),trail);
      continue;
    }
    let el = node('span', span.text || '');
    const textStart=el.firstChild;
    if(span.font_family!=null)el.style.fontFamily=fontFamilyCSS(span.font_family);
    if(span.clipped_absolute)el.append(spans(span.clipped_absolute.children,onLink,true,explanations,withinSummary,cellBackground,span));
    if(span.ruby!=null)el.append(rubySpans(span.ruby,onLink,explanations,withinSummary,cellBackground,span));
    if(span.inline_action_group!=null)el.append(spans(span.inline_action_group.spans,onLink,true,explanations,withinSummary,cellBackground,span));
    if(span.inline_box_group!=null){
      el.append(spans(span.inline_box_group.spans,onLink,true,explanations,withinSummary,cellBackground,span,darkReadingSurface));
      applyInlineBox(el,span.inline_box_group);
    }
    const creditSup=explanations?.audioCredit===span?node('sup'):null;
    const atom=span.inline_box_group?.atomic_layout;
    applyInlineTextStyle(el,atom?{...span,inline_style:{...span.inline_style,line_height:
      atom.line_height?.computed?atom.line_height:null}}:span,creditSup??el);
    if(rubyFontContext||normalizedEmphasis){el.style.fontWeight=span.bold?'bold':'normal';el.style.fontStyle=span.italic?'italic':'normal';}
    if(span.image){const image=inlineImageElement(span.image,explanations?.inlineImage,{sizing:explanations?.figureSizing,figureImage:explanations?.figureImage,intrinsic_size:explanations?.figureIntrinsicSize});el.append(span.image.map?mappedImage(image,span.image,onLink,explanations):image);}
    colorSpan(el,span);
    const externalURL=span.kind==='external_link'?safeURL(span.target,explanations?.sourceEdition):null;
    if(!canonicalRGB(span.foreground)&&inkFor(span)&&((span.kind==='link'&&(span.target||span.target_fragment))||(span.kind==='external_link'&&externalURL)))el.style.textDecoration='underline';
    if(canonicalRGB(span.background)){
      el.style.backgroundColor=span.background;
      // A box owns decoration and preserves the source's inherited text wrapping.
      if(!span.inline_box_group)el.style.whiteSpace='pre-wrap';
    }
    if (span.language) el.lang = span.language;
    if (['rtl','ltr','auto'].includes(span.direction)) { el.dir = span.direction; el.style.unicodeBidi = 'isolate'; }
    if (['label','citation','pronunciation','headword'].includes(span.role)) el.classList.add(span.role);
    for (const [flag, tag] of [['bold','strong'],['italic','em'],['code','code'],['small','small'],['superscript','sup'],['subscript','sub'],['strike','s'],['underline','u']]) {
      if(creditSup&&flag==='superscript')continue;
      if (span[flag]) { const wrapper = node(tag); if(span.inline_style?.font_normalized&&['small','superscript','subscript'].includes(flag))wrapper.style.fontSize='inherit'; wrapper.append(el); el = wrapper; }
    }
    if (span.explanation) {
      const annotation=node(explanationTag(span));annotation.title=span.tooltip??span.explanation;
      if(described.has(i))annotation.setAttribute('aria-describedby',described.get(i));
      annotation.append(el);el=annotation;
    }
    const imageURL=span.image&&span.kind==='link'?safeURL(span.target_fragment==null?explanations?.imageActionURL?.(span.target):explanations?.imageActionURL?.(span.target,span.target_fragment)):null;
    const sourceURL=span.kind==='link'?safeURL(bookSourcesURL(span.target,explanations?.sourceEdition,span.target_fragment)):null;
    if(span.audio_control){
      el=explanations.audioControl(span,el);
      if(withinSummary)el.addEventListener('click',event=>event.stopPropagation());
    }else if(!span.image?.map&&(sourceURL||imageURL)){
      const link=node('a');link.href=sourceURL||imageURL;link.rel='noopener noreferrer';link.target='_blank';if(withinSummary)link.addEventListener('click',event=>event.stopPropagation());link.append(el);el=link;
    } else if(span.image&&!span.image.map&&span.kind==='link'&&span.target?.startsWith('File:')){
      const unresolved=node('span');unresolved.setAttribute('role','link');unresolved.setAttribute('aria-disabled','true');unresolved.dataset.actionTarget=span.target;unresolved.append(el);el=unresolved;
    } else if (span.kind === 'link' && (span.target||span.target_fragment) && !span.image?.map) {
      const link = node('a');
      if (span.target_fragment == null) {
        // Legacy local links include the leading hash in the stored target.
        const target = span.target.startsWith('#') ? span.target.slice(1) : span.target;
        link.href = '#' + encodeURIComponent(target);
      } else {
        link.href = '#' + (span.target ? encodeURIComponent(span.target) + '#' : '') + encodeURIComponent(span.target_fragment);
      }
      // Some table and thumbnail links contain only a space. Keep its layout and name the action.
      if (!span.image && !span.ruby && !span.clipped_absolute && !el.textContent.trim() && !span.tooltip?.trim()) {
        link.setAttribute('aria-label', span.explanation?.trim() || (span.target_fragment ? `${span.target}#${span.target_fragment}` : span.target));
      }
      link.addEventListener('click', event => { event.preventDefault(); if(withinSummary)event.stopPropagation(); if(span.target_fragment==null)onLink(span.target);else onLink(span.target,span.target_fragment); }); link.append(el); el = link;
    } else if (span.kind === 'external_link' && externalURL && !span.image?.map) {
      const link = node('a'); link.href = externalURL; link.rel = 'noopener noreferrer'; link.target = '_blank';
      // Prefer URL separators to emergency breaks inside a displayed address.
      if (!preserve && textStart && span.text === span.target && /^https?:\/\//i.test(span.target)) {
        const parts = span.text.split(/(?<!:\/\/)(?<=[/?&#])(?=[^/?&#])/u);
        if (parts.length > 1) {
          const label = document.createDocumentFragment();
          for (const [index, part] of parts.entries()) {
            if (index > 0) label.append(node('wbr'));
            label.append(part);
          }
          textStart.replaceWith(label);
        }
      }
      if(!span.image&&!span.ruby&&!span.clipped_absolute&&!el.textContent.trim()&&!span.tooltip?.trim())link.setAttribute('aria-label',span.explanation?.trim()||externalURL);
      if(withinSummary)link.addEventListener('click',event=>event.stopPropagation()); link.append(el); el = link;
    }
    if(described.has(i) && el.tagName==='A')el.setAttribute('aria-describedby',described.get(i));
    if(span.tooltip!=null){if(typeof span.tooltip!=='string')throw Error('Invalid compiled tooltip');el.title=span.tooltip;}
    if(creditSup){if(span.inline_style.font_normalized)creditSup.style.fontSize='inherit';creditSup.append(el);el=creditSup;}
    if(span.image?.occurrence_layout){
      validateImageOccurrence(span.image);
      const layout=span.image.occurrence_layout;
      // Offsets move the image and its action together. Padding occupies line
      // width outside the action. The compiler normalizes em to the body font.
      const length=v=>v.unit==='px'?v.value+'px':`calc(var(--wikidict-normal-body-size) * ${v.value})`;
      const owner=node('span',null,'compiled-image-occurrence');
      owner.style.position='relative';owner.style.left=length(layout.x);owner.style.top=length(layout.y);
      owner.style.paddingLeft=length(layout.padding_left);owner.style.paddingRight=length(layout.padding_right);
      owner.append(el);el=owner;
    }
    const trail=trailNode(span,i);
    if(runStarts)runStarts[i]=textStart??(trail.nodeType===3?trail:trail.firstChild);
    const fontSize=semanticFontSize(span,rubyFontContext);
    if(span.clipped_absolute){
      if(fontSize!==null)el.style.fontSize=fontSize;
      fragment.append(clippedOccurrence(el,span.clipped_absolute,explanations?.exteriorBoxes),trail);
      continue;
    }
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
  const inline=[];
  for(const label of root.querySelectorAll('.heading-label')){
    const text=inlineDestinationOwners.get(label)?.get(fragment);
    if(text)inline.push({label,text});
  }
  let matches = [...destinations.filter(el => el.id === fragment),...inline];
  if (!matches.length) matches = destinations.filter(el => el.id === fragment.replaceAll(' ','_'));
  if (matches.length !== 1) return false;
  const target = matches[0];
  if(inline.includes(target))return revealInlineDestination(target.label,target.text);
  for(let el=target;el&&el!==root;el=el.parentElement){
    if(el.tagName==='DETAILS')el.open=true;
    if(el.tagName==='TR'&&el.hidden)revealTableRow.get(el)?.();
  }
  if (!target.hasAttribute('tabindex')) target.tabIndex = -1;
  const clipped=target.closest('.compiled-clipped-body');
  // A sense owns the list item, but its examples and quotations can extend beyond the viewport.
  const lead=target.tagName==='LI'?target.querySelector(':scope > .definition')??target:target;
  (exteriorBoxes.get(clipped)??lead).scrollIntoView({block:'center'});
  target.focus({preventScroll:true});
  return true;
}
function inlineDestinationRange(label,text){
  if(!label.isConnected||!label.contains(text)||text.nodeType!==3||!text.length||
     getComputedStyle(label).direction!=='ltr'||getComputedStyle(text.parentElement).direction!=='ltr')throw Error('Unsupported inline destination layout');
  // The first character's native rectangle gives downstream line affinity at
  // a soft wrap. A collapsed boundary can instead report the preceding line.
  // No heading/ancestor box substitutes for a missing text rectangle.
  const range=document.createRange();range.setStart(text,0);range.setEnd(text,1);
  if(!range.getClientRects()[0]||range.getClientRects()[0].height<=0)throw Error('Unsupported inline destination layout');
  return range;
}
export function validateInlineDestinationLayout(root){
  for(const label of root.querySelectorAll('.heading-label')){
    const mapped=inlineDestinationOwners.get(label);
    if(mapped)for(const text of new Set(mapped.values()))inlineDestinationRange(label,text);
  }
}
function revealInlineDestination(label,text){
  for(let el=label;el;el=el.parentElement)if(el.tagName==='DETAILS')el.open=true;
  const range=inlineDestinationRange(label,text);
  const rect=()=>range.getClientRects()[0];
  for(let el=label.parentElement;el&&el!==document.documentElement&&el!==document.body;el=el.parentElement){
    const style=getComputedStyle(el),box=el.getBoundingClientRect(),r=rect();
    const top=/(auto|scroll)/.test(style.overflowY)&&el.scrollHeight>el.clientHeight?r.top+r.height/2-box.top-el.clientTop-el.clientHeight/2:0;
    const left=/(auto|scroll)/.test(style.overflowX)&&el.scrollWidth>el.clientWidth&&(r.left<box.left||r.right>box.right)?r.left-box.left-el.clientLeft:0;
    if(top||left)el.scrollBy({top,left,behavior:'instant'});
  }
  const r=rect();
  window.scrollBy({top:r.top+r.height/2-window.innerHeight/2,left:r.left<0||r.right>window.innerWidth?r.left:0,behavior:'instant'});
  return true;
}
function destination(el, value, legacy = '') {
  const primary = value.anchor || legacy, fallback = value.anchor_fallback;
  if (primary) el.id = primary;
  if (fallback && fallback !== primary) {
    const alias = node('span',null,'compiled-fragment-alias'); alias.id = fallback;
    // Keep a details summary first while locating its alias at the heading.
    (el.tagName === 'DETAILS' ? el.firstElementChild : el).prepend(alias);
  }
}
function legacyDestinations(entry) {
  const candidates = [], counts = new Map();
  if (['DPR5','DPR6','DPR7','DPR8','DPR9','DPRA','DPRB','DPRC','DPRD','DPRE','DPRF','DPRG','DPRH','DPRI','DPRJ','DPRK','DPRL','DPRM','DPRS','DPRV','DPRY','DPRZ','DPRa'].includes(entry.presentation_version)) return new Map();
  const add = (value, label) => {
    if (value.anchor || value.anchor_fallback) return;
    const id = label.replaceAll(' ','_');
    if (id) { candidates.push([value,id]); counts.set(id,(counts.get(id)||0)+1); }
  };
  for (const section of entry.sections) {
    add(section,section.title);
    const companion = sectionHeadingCompanion(section);
    for (const block of section.blocks.slice(companion?1:0)) if (block.kind === 'heading') {
      const label = inlineText(block.spans||[],'\n').trim();
      add(block,label);
    }
  }
  return new Map(candidates.filter(([,id]) => counts.get(id) === 1));
}
// Typed rich content extends the existing renderer; no source markup is interpreted.
const richListKinds=new Set(['list_item','definition','example','quotation','term','list_detail','indent']);
const richError=()=>{throw Error('Invalid compiled rich content');};
function richObject(value,keys,required=[]){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(key=>!keys.includes(key))||required.some(key=>!Object.hasOwn(value,key)))richError();
  return value;
}
function richLength(value,units=['px','em']){
  richObject(value,['unit','value'],['unit','value']);
  if(!units.includes(value.unit)||typeof value.value!=='number'||!Number.isFinite(value.value)||value.value<0||value.value>3.4028234663852886e38)richError();
}
function richEdges(value){richObject(value,['top','right','bottom','left'],['top','right','bottom','left']);for(const edge of Object.values(value))richLength(edge);}
function richColor(value){richObject(value,['kind','value'],['kind']);if(!['native_theme','transparent','rgb'].includes(value.kind)||(value.kind==='rgb'?!canonicalRGB(value.value):value.value!=null))richError();}
function richBorder(value){richObject(value,['kind','width','color'],['kind']);if(value.kind==='solid'){richLength(value.width);richColor(value.color);}else if(value.kind!=='none'||value.width!=null||value.color!=null)richError();}
function figureColor(value,fallback){return value.kind==='native_theme'?fallback:value.kind==='transparent'?'transparent':value.value;}
function figureBorder(value){return value.kind==='none'?'none':styleLength(value.width)+' solid '+figureColor(value.color,'var(--muted)');}
function validateRichEntry(entry){
  let remaining=1<<20,mapStrings=32*1024*1024;
  let sourceAnchors=false;
  const inlineOwners=[];
  const charge=(n=1)=>{if(!Number.isInteger(n)||n<0||(remaining-=n)<0)richError();};
  const string=value=>{if(typeof value!=='string'||/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)||new TextEncoder().encode(value).length>32*1024*1024)richError();};
  const array=value=>{if(!Array.isArray(value))richError();charge(value.length);return value;};
  const media=new Map();for(const item of entry.media||[]){if(media.has(item.file))media.set(item.file,null);else media.set(item.file,item.kind);}
  const action=value=>{
    richObject(value,['kind','target','target_fragment','label'],['kind','target','label']);
    for(const key of ['target','label','target_fragment'])if(value[key]!=null){string(value[key]);mapStrings-=new TextEncoder().encode(value[key]).length;if(mapStrings<0)richError();}
    if(value.kind==='internal'){if(!value.target&&value.target_fragment==null)richError();}
    else if(value.kind!=='external'||!value.target||value.target_fragment!=null)richError();
  };
  const span=value=>{
    if(!value||typeof value!=='object')richError();
    if(value.font_family!=null)validateFontFamily(value.font_family);
    if(value.clipped_absolute!=null){
      validateClippedSpan(value);charge(value.clipped_absolute.children.length);
      for(const child of value.clipped_absolute.children)span(child);
    }
    if(value.tooltip!=null)string(value.tooltip);
    if(value.audio_control!=null)validateAudioControl(value,media);
    if(value.ruby!=null){validateRubySpan(value);validateRuby(value.ruby);}
    if(value.inline_action_group!=null){validateActionGroupSpan(value);charge(value.inline_action_group.spans.length);}
    if(value.inline_box_group!=null){validateInlineBoxSpan(value);charge(value.inline_box_group.spans.length+value.inline_box_group.overlays.length);}
    if(value.target_fragment!=null&&value.kind!=='link')richError();
    if(!value.image)return;
    const image=richObject(value.image,['file','width_px','height_px','alt','tooltip','border','map','dark_mode_filter','occurrence_layout'],['file']);
    if(image.occurrence_layout!=null){charge(1);validateImageOccurrence(image);}
    if(image.dark_mode_filter!==undefined&&image.dark_mode_filter!=='invert_hue_rotate_180')richError();
    string(image.file);if(!image.file||/[\u0000-\u001f\u007f-\u009f_\[\]{}<>|#]/u.test(image.file)||image.file.startsWith(' ')||image.file.endsWith(' ')||media.get(image.file)!=='image')richError();
    if((value.text||'')!==''||(value.trail||'')!==''||!['text','link','external_link'].includes(value.kind)||(value.kind==='text'?!!value.target:!value.target))richError();
    for(const axis of ['width_px','height_px'])if(image[axis]!=null&&(!Number.isInteger(image[axis])||image[axis]<=0||image[axis]>4294967295))richError();
    for(const key of ['alt','tooltip'])if(image[key]!=null)string(image[key]);
    if(image.border!=null&&typeof image.border!=='boolean')richError();
    if(image.map!=null){
      const map=richObject(image.map,['regions','default_action','description'],['regions','description']);
      if(!['none','top_right','bottom_right','bottom_left','top_left'].includes(map.description))richError();
      for(const region of array(map.regions)){
        richObject(region,['shape','coordinates','action'],['shape','coordinates','action']);const coords=array(region.coordinates);
        if(!(region.shape==='rectangle'?coords.length===4:region.shape==='circle'?coords.length===3:region.shape==='polygon'&&coords.length>=6&&coords.length%2===0)||coords.some(n=>typeof n!=='number'||!Number.isFinite(n)))richError();
        action(region.action);
      }
      if(map.default_action!=null){charge();action(map.default_action);}
    }
  };
  const spanList=values=>{for(const value of array(values||[]))span(value);};
  const caption=(value,tableDepth,depth,inReference)=>{if(value.caption_blocks!=null){if(value.caption?.length)richError();blocks(value.caption_blocks,tableDepth,depth+1,inReference);}else spanList(value.caption);};
  const figure=(value,tableDepth,depth,inReference)=>{
    const required=['image_span','format','sizing','placement','clear','margins','image_insets','caption_padding','caption_font_scale','caption_line_height','frame_background','frame_border','image_background','image_border','caption_foreground','caption_background'];
    richObject(value,[...required,'caption','caption_blocks','caption_text_align','frame_min_width','intrinsic_size'],required);span(value.image_span);if(!value.image_span.image)richError();
    if(Object.hasOwn(value,'intrinsic_size'))validateFigureIntrinsicSize(value);
    if(!['thumbnail','framed'].includes(value.format)||!['none','center','float_left','float_right'].includes(value.placement)||!['none','left','right','both'].includes(value.clear))richError();
    const image=value.image_span.image;
    if(!(value.sizing==='intrinsic'?value.format==='framed':value.sizing==='original_width_with_height_bound'?value.format==='framed'&&image.height_px!=null:['requested_fit','requested_fit_cap_original_width'].includes(value.sizing)&&value.format==='thumbnail'&&image.width_px!=null))richError();
    if(value.frame_min_width!=null)richLength(value.frame_min_width,['px']);
    for(const key of ['margins','image_insets','caption_padding'])richEdges(value[key]);
    for(const key of ['frame_background','image_background','caption_foreground','caption_background'])richColor(value[key]);
    for(const key of ['frame_border','image_border'])richBorder(value[key]);
    if(typeof value.caption_font_scale!=='number'||!Number.isFinite(value.caption_font_scale)||value.caption_font_scale<0||value.caption_font_scale>3.4028234663852886e38)richError();
    richLength(value.caption_line_height);if(value.caption_text_align!=null&&!['left','center','right'].includes(value.caption_text_align))richError();
    caption(value,tableDepth,depth,inReference);
  };
  const flow=(values,tableDepth,depth,inReference)=>{
    if(depth>16)richError();
    for(const part of array(values)){
      richObject(part,['kind','spans','figure','scope'],['kind']);
      if(part.kind==='inline'){if(part.figure!=null||part.scope!=null)richError();spanList(part.spans);}
      else if(part.kind==='figure'){if(part.spans?.length||part.scope!=null)richError();figure(part.figure,tableDepth,depth,inReference);}
      else if(part.kind==='scope'){
        if(part.spans?.length||part.figure!=null)richError();const scope=richObject(part.scope,['mode','authored_direction','resolved_direction','language','parts'],['mode','resolved_direction','parts']);
        if(!['isolate','isolate_override'].includes(scope.mode)||!['ltr','rtl'].includes(scope.resolved_direction)||(scope.authored_direction!=null&&!['ltr','rtl','auto'].includes(scope.authored_direction))||(['ltr','rtl'].includes(scope.authored_direction)&&scope.authored_direction!==scope.resolved_direction)||(scope.mode==='isolate_override'&&!['ltr','rtl'].includes(scope.authored_direction)))richError();
        if(scope.language!=null)string(scope.language);flow(scope.parts,tableDepth,depth+1,inReference);
      }else richError();
    }
  };
  const inlineAudio=value=>{
    const tokens=poemTokens(value);if(!tokens.includes('wikidict-media'))return true;
    const prefix='wikidict-media-file-',owners=tokens.filter(token=>token.startsWith(prefix));let file;
    if(owners.length){if(owners.length!==1)return false;const hex=owners[0].slice(prefix.length);if(!/^(?:[0-9a-f]{2})+$/.test(hex))return false;try{file=new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(hex.match(/../g),n=>parseInt(n,16)));}catch{return false;}}
    else {if(!value.target?.startsWith('File:'))return false;file=value.target.slice(5).replaceAll('_',' ');}
    return media.get(file)==='audio';
  };
  const table=(value,tableDepth,depth,inReference,owner)=>{
    if(tableDepth>16)richError();
    if(value.disclosure!=null){validateTableDisclosure(value);charge(1+value.rows.length);}
    if(Object.hasOwn(value,'caption_viewport')){
      if(value.caption_viewport==null||entry.presentation_version!=='DPRa')richError();
      validateResponsiveCaptionTable(value);charge();
      const names=value.caption_viewport.caption_box.line.strut.owner_font.font_family?.stack?.names;
      if(names)charge(names.length);
    }
    const inline=['inline_block','inline_table'].includes(value.style?.display);
    applyTableStyle(node('table'),value.style);
    if(inline&&(tableDepth!==1||depth!==0||inReference||!owner||!['table','list_item'].includes(owner.kind)||owner.spans?.length||owner.feature!=null||value.caption?.length||value.caption_blocks!=null||value.style?.float_side!=null))richError();
    caption(value,tableDepth,depth,inReference);let cells=0;
    for(const row of array(value.rows))for(const cell of array(row.cells)){
      cells++;spanList(cell.spans);applyCellStyle(node('td'),cell.style);
      if(inline){
        if(cell.blocks!=null||cell.nested_table!=null)richError();
        for(const s of cell.spans||[]){if(s.image||!inlineAudio(s))richError();if(!s.code&&(s.font_scale??1)!==0&&s.kind!=='line_break'&&poemTokens(s).includes('Egyp')&&[...(s.text||'')].some(c=>c.codePointAt(0)>=0x13000&&c.codePointAt(0)<=0x13455))richError();}
      }
      if(cell.blocks!=null){if(cell.spans?.length||cell.nested_table!=null)richError();blocks(cell.blocks,tableDepth,depth,inReference);}
      if(cell.nested_table!=null){if(cell.spans?.length)richError();table(cell.nested_table,tableDepth+1,depth,inReference,null);}
    }
    if(inline&&!cells)richError();
  };
  const blocks=(values,tableDepth=0,depth=0,inReference=false,parentStyle=null,sectionRoot=false)=>{
    if(depth>16)richError();
    for(const block of array(values)){
      validateColumnBreakInside(block);
      const destinations=validateInlineDestinationList(block);charge(destinations.length);
      if(destinations.length)inlineOwners.push(block);
      spanList(block.spans);const owner=richListKinds.has(block.kind)||(block.kind==='paragraph'&&!(block.depth||0)&&!block.list_path);
      if(entry.presentation_version==='DPRa'&&block.kind!=='heading'&&(block.anchor||block.anchor_fallback)){
        validateSourceAnchor(block,sectionRoot);sourceAnchors=true;
      }
      if(block.description_body!=null){validateDescriptionBody(block);blocks(block.description_body.box.blocks,tableDepth,depth+1,inReference);}
      if(block.kind==='container'||block.container!=null){
        const version=entry.presentation_version;
        const positioned=version==='DPRZ'||version==='DPRa';
        validateContainerBlock(block,{containerFonts:positioned||['DPRM','DPRS','DPRV','DPRY'].includes(version),positioned,parentStyle,containerDisclosureButtons:version==='DPRa'});
        if(block.container.disclosure!=null)charge(containerDisclosureItems(block.container));
        blocks(block.container.blocks,tableDepth,depth+1,inReference,block.container.style);
      }
      if(block.flow!=null){if(!owner||block.spans?.length||block.table!=null||block.feature!=null||block.figure!=null)richError();flow(block.flow,tableDepth,depth+1,inReference);}
      if(block.figure!=null){if(!owner||block.spans?.length||block.table!=null||block.feature!=null||block.style!=null)richError();figure(block.figure,tableDepth,depth,inReference);}
      if(block.style!=null){if(block.kind!=='paragraph'||block.depth||block.list_path||block.table!=null||block.feature!=null)richError();richObject(block.style,['margins','padding']);if(block.style.margins==null&&block.style.padding==null)richError();for(const key of ['margins','padding'])if(block.style[key]!=null)richEdges(block.style[key]);}
      if(block.table!=null)table(block.table,tableDepth+1,depth,inReference,block);
    }
  };
  spanList(entry.display_title);spanList(entry.preamble_spans);
  for(const section of array(entry.sections))blocks(section.blocks,0,0,false,null,true);
  for(const ref of entry.references||[]){spanList(ref.spans);if(ref.blocks!=null)blocks(ref.blocks,0,0,true);}
  if(sourceAnchors)validateSourceAnchorDestinations(entry);
  validateInlineDestinationEntry(entry,inlineOwners);
  return sourceAnchors;
}
function richAction(action,onLink,explanations,label=action.label){
  const el=node('a',label);let href=null;
  if(action.kind==='external')href=safeURL(action.target,explanations?.sourceEdition);
  else if(action.target.startsWith('File:'))href=safeURL(explanations?.imageActionURL?.(action.target,action.target_fragment));
  else {const p=linkTargetParts(action.target,action.target_fragment);href='#'+encodeURIComponent(p.title)+(p.fragment===undefined?'':'#'+encodeURIComponent(p.fragment));el.addEventListener('click',event=>{event.preventDefault();event.stopPropagation();action.target_fragment==null?onLink(action.target):onLink(action.target,action.target_fragment);});}
  if(href){el.href=href;if(action.kind==='external'||action.target.startsWith('File:')){el.target='_blank';el.rel='noopener noreferrer';}}
  else {el.setAttribute('role','link');el.setAttribute('aria-disabled','true');el.dataset.actionTarget=action.target;}
  return el;
}
// Match the native/codec map contract: source coordinates are rounded after
// the shared (layout width + height)/(original width + height) scaling.
function imageMapHit(map,original,layout,x,y){
  const checked=n=>{if(!Number.isFinite(n))throw Error('Image map geometry unavailable');return n;};
  if(![original.width,original.height].every(n=>Number.isInteger(n)&&n>0&&n<=4294967295)||![layout.width,layout.height].every(n=>Number.isFinite(n)&&n>0))throw Error('Image map geometry unavailable');
  const scale=checked((layout.width+layout.height)/(original.width+original.height));
  const round=n=>n<0?-Math.round(-n):Math.round(n);
  for(let index=0;index<map.regions.length;index++){
    const region=map.regions[index],c=region.coordinates.map(n=>round(checked(n*scale)));let inside=false;
    if(region.shape==='rectangle')inside=c[0]!==c[2]&&c[1]!==c[3]&&x>=Math.min(c[0],c[2])&&x<=Math.max(c[0],c[2])&&y>=Math.min(c[1],c[3])&&y<=Math.max(c[1],c[3]);
    else if(region.shape==='circle')inside=c[2]>0&&checked(checked((x-c[0])**2)+checked((y-c[1])**2))<=checked(c[2]**2);
    else {
      let px=c.at(-2),py=c.at(-1);
      for(let at=0;at<c.length;at+=2){const cx=c[at],cy=c[at+1],dx=checked(cx-px),dy=checked(cy-py),qx=checked(x-px),qy=checked(y-py);
        if(x>=Math.min(px,cx)&&x<=Math.max(px,cx)&&y>=Math.min(py,cy)&&y<=Math.max(py,cy)&&checked(dx*qy)===checked(dy*qx)){inside=true;break;}
        if((py>y)!==(cy>y)){const crossing=checked(cx+checked(checked((y-cy)/(py-cy))*checked(px-cx)));if(x<crossing)inside=!inside;}px=cx;py=cy;
      }
    }
    if(inside)return index;
  }
  return map.default_action!=null?map.regions.length:null;
}
function mappedImage(el,image,onLink,explanations){
  const wrap=node('span',null,'compiled-image-map');wrap.style.cssText='display:inline-block;position:relative;vertical-align:middle;';wrap.append(el);
  const actions=node('span',null,'compiled-image-map-actions');actions.setAttribute('role','group');actions.setAttribute('aria-label','Image links');
  // Keyboard alternatives stay out of the image's geometry, and reveal on focus.
  actions.style.cssText='position:absolute;left:0;top:0;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);user-select:none;';
  // The image box has zero line height; keyboard text needs its own readable lines.
  actions.addEventListener('focusin',event=>{actions.style.cssText='position:absolute;left:0;top:0;z-index:2;display:flex;flex-direction:column;background:var(--bg);color:var(--fg);padding:4px;max-width:100%;max-height:100%;overflow:auto;overflow-wrap:anywhere;line-height:1.4;user-select:none;';event.target.scrollIntoView({block:'nearest',inline:'nearest'});});
  actions.addEventListener('focusout',event=>{if(!actions.contains(event.relatedTarget))actions.style.cssText='position:absolute;left:0;top:0;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);user-select:none;';});
  const links=[...image.map.regions.map(r=>r.action),...(image.map.default_action==null?[]:[image.map.default_action])].map(action=>richAction(action,onLink,explanations));for(const link of links)actions.append(link);wrap.append(actions);
  let geometry=null;el.addEventListener('wikidict-image-geometry',event=>{geometry=event.detail;});
  el.addEventListener('click',event=>{
    event.preventDefault();event.stopPropagation();if(el.dataset.mediaState!=='loaded'||!geometry)return;
    const rect=el.getBoundingClientRect(),css=getComputedStyle(el),left=rect.left+parseFloat(css.borderLeftWidth),top=rect.top+parseFloat(css.borderTopWidth),width=rect.width-parseFloat(css.borderLeftWidth)-parseFloat(css.borderRightWidth),height=rect.height-parseFloat(css.borderTopWidth)-parseFloat(css.borderBottomWidth);
    const x=event.clientX-left,y=event.clientY-top;if(x<0||y<0||x>=width||y>=height||!(width>0&&height>0))return;
    try{const hit=imageMapHit(image.map,geometry.original,geometry.layout,x/width*geometry.layout.width,y/height*geometry.layout.height);if(hit!=null)links[hit].click();}catch{wrap.dataset.mapState='geometry-unavailable';}
  });
  if(image.map.description!=='none'){
    const info=richAction({kind:'internal',target:'File:'+image.file,target_fragment:null,label:'Image description'},onLink,explanations,'ⓘ');info.className='compiled-image-description';info.setAttribute('aria-label','Image description');info.style.cssText='position:absolute;z-index:1;line-height:1;background:var(--bg);font:1rem Interface,sans-serif;user-select:none;';
    const [vertical,horizontal]=image.map.description.split('_');info.style[vertical]='0';info.style[horizontal]='0';wrap.append(info);
  }
  return wrap;
}
function figureView(value,onLink,explanations,context={}){
  const frame=node('figure',null,'compiled-figure');frame.style.cssText='display:flow-root;box-sizing:content-box;width:max-content;max-width:none;overflow-wrap:anywhere;';
  styleEdges(frame,'margin',value.margins);frame.style.clear=value.clear;frame.style.background=figureColor(value.frame_background,'var(--surface)');frame.style.border=figureBorder(value.frame_border);
  if(value.frame_min_width!=null)frame.style.minWidth=styleLength(value.frame_min_width);
  if(value.placement.startsWith('float_'))frame.style.cssFloat=value.placement.slice(6);
  const imageBox=node('div',null,'compiled-figure-image');imageBox.style.cssText='box-sizing:content-box;width:max-content;line-height:0;';styleEdges(imageBox,'margin',value.image_insets);imageBox.style.background=figureColor(value.image_background,'var(--bg)');imageBox.style.border=figureBorder(value.image_border);
  const imageExplanations={...explanations,figureSizing:value.sizing,figureIntrinsicSize:value.intrinsic_size,figureImage:true};imageBox.append(spans([value.image_span],onLink,false,imageExplanations,false,context.background));frame.append(imageBox);
  const image=imageBox.querySelector('img');
  // The image, not an unbreakable caption, owns the frame width. The authored
  // physical minimum remains a separate content-box floor.
  const size=()=>{
    if(!frame.isConnected)return;
    // An unloaded image is replaced by a small status icon. A width-only
    // requested fit already determines the image width without fetching it.
    const spec=value.image_span.image;
    const knownWidth=image.hidden&&value.sizing==='requested_fit'&&spec.width_px!=null&&spec.height_px==null;
    imageBox.style.width=knownWidth?image.style.width:'max-content';
    const css=getComputedStyle(imageBox),box=imageBox.getBoundingClientRect();
    frame.style.width=(box.width+parseFloat(css.marginLeft)+parseFloat(css.marginRight))+'px';
  };
  image.addEventListener('wikidict-image-geometry',size);queueMicrotask(size);
  const hasCaption=value.caption_blocks!=null?value.caption_blocks.length>0:value.caption?.length>0;
  if(hasCaption||Object.values(value.caption_padding).some(v=>v.value!==0)){
    const caption=node('figcaption');caption.style.cssText='display:block;box-sizing:border-box;overflow-wrap:anywhere;';styleEdges(caption,'padding',value.caption_padding);caption.style.background=figureColor(value.caption_background,'var(--surface)');caption.style.color=figureColor(value.caption_foreground,'var(--fg)');caption.style.fontSize=`calc(var(--wikidict-normal-body-size) * ${value.caption_font_scale})`;caption.style.lineHeight=styleLength(value.caption_line_height);if(value.caption_text_align!=null)caption.style.textAlign=value.caption_text_align;
    // Keep inherited authored ink inside anchors, where the global link palette
    // would otherwise replace it. Only native ink may adapt to an authored surface.
    const surface=value.caption_background.kind==='rgb'?value.caption_background.value:value.caption_background.kind==='transparent'?(value.frame_background.kind==='rgb'?value.frame_background.value:value.frame_background.kind==='transparent'?context.background:null):null;
    const captionInk=value.caption_foreground.kind==='native_theme'?(canonicalRGB(surface)?contrastInk(surface):null):figureColor(value.caption_foreground,null);
    const captionExplanations={...explanations,captionInk};
    if(value.caption_blocks!=null)appendBlocks(caption,value.caption_blocks,block=>blockView(block,onLink,captionExplanations,'',{...context,background:null,caption:true}),explanations?.sourceAnchors);else caption.append(spans(value.caption,onLink,false,captionExplanations));
    for(const block of caption.querySelectorAll('.block')){block.style.fontSize='inherit';block.style.lineHeight='inherit';}frame.append(caption);
  }
  if(value.placement==='center'){
    // Center the margin box without replacing either authored physical margin.
    const centered=node('div',null,'compiled-figure-center');centered.style.cssText='display:table;width:max-content;margin-left:auto;margin-right:auto;';centered.style.clear=value.clear;centered.append(frame);return centered;
  }
  return frame;
}
function flowView(values,onLink,explanations,context){
  const fragment=document.createDocumentFragment();
  for(const part of values){
    if(part.kind==='inline')fragment.append(spans(part.spans,onLink,false,{...explanations,preserveFlowSpacing:true},false,context.background));
    else if(part.kind==='figure')fragment.append(figureView(part.figure,onLink,explanations,context));
    else {const scope=node('span',null,'compiled-bidi-scope');scope.dir=part.scope.resolved_direction;scope.style.unicodeBidi=part.scope.mode==='isolate_override'?'isolate-override':'isolate';if(part.scope.language!=null)scope.lang=part.scope.language;scope.append(flowView(part.scope.parts,onLink,explanations,context));fragment.append(scope);}
  }
  return fragment;
}

function styleObject(value){if(value==null)return null;if(typeof value!=='object'||Array.isArray(value)||!Object.values(value).some(field=>field!=null))throw Error('Invalid typed table style');return value;}
function styleLength(value,signed=false){
  if(!value||!['px','em'].includes(value.unit)||typeof value.value!=='number'||!Number.isFinite(value.value)||(!signed&&value.value<0))throw Error('Invalid style length');
  // Compiled table lengths share the native readers' normal-body font basis,
  // independently of table typography and nested cell content.
  return value.unit==='em'?`calc(var(--wikidict-normal-body-size) * ${value.value})`:value.value+'px';
}
function borderLineCSS(value, physical) {
  const kinds = physical ? ['none','hidden','solid','dotted'] : ['none','solid'];
  richObject(value, kinds);
  const keys = Object.keys(value);
  if (keys.length !== 1) throw Error('Invalid style border');
  const [kind] = keys, line = value[kind];
  if (kind === 'none' || kind === 'hidden') {
    richObject(line, []);
    return kind;
  }
  richObject(line, ['width','color'], ['width','color']);
  if (!canonicalRGB(line.color)) throw Error('Invalid style border color');
  return `${styleLength(line.width)} ${kind} ${line.color}`;
}
function applyStyleBorder(el, value) {
  if (value && Object.hasOwn(value, 'edges')) {
    const sides = ['top','right','bottom','left'];
    richObject(value, ['edges']);
    richObject(value.edges, sides, sides);
    for (const side of sides) el.style.setProperty('border-' + side, borderLineCSS(value.edges[side], true));
  } else {
    el.style.border = borderLineCSS(value, false);
  }
}
function styleEdges(el,name,value,resolveLength=styleLength){if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid style edges');for(const side of ['top','right','bottom','left'])el.style[name+side[0].toUpperCase()+side.slice(1)]=resolveLength(value[side]);}
function applyTableStyle(el,value){
  const s=styleObject(value);if(!s)return;
  for(const key of Object.keys(s))if(!['background','border','collapse','margins','float_side','width','padding','clear','display','vertical_align','line_height'].includes(key))throw Error('Invalid table style field');
  if(s.background!=null){if(!canonicalRGB(s.background))throw Error('Invalid table background');el.style.backgroundColor=s.background;}
  if(s.border!=null)applyStyleBorder(el,s.border);
  if(s.collapse!=null){if(!['separate','collapse'].includes(s.collapse))throw Error('Invalid border collapse');el.style.borderCollapse=s.collapse;}
  if(s.margins!=null)styleEdges(el,'margin',s.margins);
  if(s.float_side!=null&&!['left','right'].includes(s.float_side))throw Error('Invalid table float side');
  if(s.width!=null){const w=s.width;if(!w||typeof w!=='object'||Array.isArray(w)||Object.keys(w).length!==2||!Number.isFinite(w.value)||w.value<0||!['px','em','percent'].includes(w.unit))throw Error('Invalid typed table width');el.style.width=w.unit==='percent'?w.value+'%':styleLength(w);}
  if(s.padding!=null)styleEdges(el,'padding',s.padding);
  if(s.clear!=null){if(!['none','left','right','both'].includes(s.clear))throw Error('Invalid table clear');el.style.clear=s.clear;}
  if(s.display!=null){if(!['table','inline_block','inline_table'].includes(s.display))throw Error('Invalid table display');if(s.display!=='table'&&s.float_side!=null)throw Error('Invalid floated inline table');el.style.display=s.display.replace('_','-');}
  if(s.vertical_align!=null){if(!['baseline','middle','top'].includes(s.vertical_align))throw Error('Invalid table vertical alignment');el.style.verticalAlign=s.vertical_align;}
  if(s.display!=null||s.vertical_align!=null||s.line_height!=null)el.style.fontSize='inherit';
  if(s.line_height!=null){
    const h=s.line_height;
    if(!h||typeof h!=='object'||Array.isArray(h)||Object.keys(h).some(k=>!['value','font_scale_basis'].includes(k))||!Number.isFinite(h.value)||h.value<=0||h.value>3.4028234663852886e38||(h.font_scale_basis!==undefined&&!['context','normal_body'].includes(h.font_scale_basis)))throw Error('Invalid computed table line height');
    // A length computes at this table, then inherits as an absolute length.
    // It is not the unitless multiplier that would shrink again in an 80% cell.
    el.style.lineHeight=h.font_scale_basis==='normal_body'?`calc(var(--wikidict-normal-body-size) * ${h.value})`:h.value+'em';
  }
}
function applyCellStyle(el,value){
  const s=styleObject(value);if(!s)return;
  for(const key of Object.keys(s))if(!['border','padding','text_align','width','min_width','vertical_align','line_height'].includes(key))throw Error('Invalid cell style field');
  validateCellMetrics(s);
  if(s.border!=null)applyStyleBorder(el,s.border);
  if(s.padding!=null)styleEdges(el,'padding',s.padding);
  if(s.text_align!=null){if(!['left','center','right'].includes(s.text_align))throw Error('Invalid cell text alignment');el.style.textAlign=s.text_align;}
  if(s.width)el.style.width=s.width.unit==='percent'?s.width.value+'%':styleLength(s.width);
  if(s.min_width)el.style.minWidth=styleLength(s.min_width);
  if(s.vertical_align)el.style.verticalAlign=s.vertical_align;
  if(s.line_height){
    el.classList.add('compiled-cell-metrics');
    const {strut,height}=s.line_height;
    const metric=(value,basis)=>basis==='css_px'?value+'px':`calc(var(--wikidict-normal-body-size) * ${value})`;
    // The cell's authored strut is independent of its children's font sizes.
    if(strut)el.style.fontSize=metric(strut.font_scale,strut.font_scale_basis);
    el.style.lineHeight=height.length?metric(height.length.value,height.length.font_scale_basis):height.multiplier!=null?String(height.multiplier):'normal';
  }
}
const revealTableRow=new WeakMap();
let captionTableSequence=0;
function responsiveCaptionView(table,value){
  const owner=value.caption_viewport,caption=table.caption;
  if(!caption)throw Error('Missing responsive table caption');
  // Preserve one TABLE, CAPTION and row group. Native CSS creates the anonymous
  // grid when the same table becomes a block; no cloned caption or scroll wrapper.
  const name='wikidict-caption-table';
  if(!customElements.get(name))customElements.define(name,class extends HTMLElement{
    connectedCallback(){this.stopCaption?.();this.stopCaption=this.startCaption?.();}
    disconnectedCallback(){this.stopCaption?.();this.stopCaption=null;}
  });
  const host=node(name),style=node('style'),id='compiled-caption-'+(++captionTableSequence);
  host.style.display='contents';host.dir=owner.containing_direction;
  table.classList.add(id,'compiled-caption-scroll');
  // The source TABLE owns caption/grid direction. The containing direction is
  // external context, not a replacement caption direction or an inferred LTR.
  table.dir=owner.grid_direction;table.lang=owner.language;
  for(const body of table.tBodies)body.dir=owner.grid_direction;
  const declarations=(typed,narrow)=>{
    const probe=node('table');
    probe.style.cssText='box-sizing:border-box;margin:0;padding:0;border:0;background:transparent;min-width:0;';
    applyTableStyle(probe,typed);
    probe.style.cssFloat=typed.float_side;
    probe.style.maxWidth=styleLength(owner.max_width);
    probe.style.display=narrow?'block':'table';
    probe.style.overflow=narrow?'auto':'visible';
    probe.style.borderCollapse='separate';
    probe.style.borderSpacing=styleLength(owner.grid_spacing_x)+' '+styleLength(owner.grid_spacing_y);
    const line=narrow?owner.narrow_grid_style.line_height:value.style.line_height;
    probe.style.lineHeight=`calc(var(--wikidict-normal-body-size) * ${line.value})`;
    probe.style.fontSize='inherit';
    return probe.style.cssText;
  };
  const wide=declarations(value.style,false),narrow=declarations(owner.narrow_box_style,true);
  table.removeAttribute('style');
  let focus='';
  if(owner.focus_paint){
    const probe=node('table'),paint=owner.focus_paint;
    probe.style.outlineStyle=paint.mode==='authored_none'?'none':'auto';
    if(paint.color)probe.style.outlineColor=figureColor(paint.color,'currentColor');
    focus='.'+id+':focus{'+probe.style.cssText+'}';
  }
  style.textContent='.'+id+'{'+wide+'}@media(max-width:'+owner.max_viewport_width_px+'px){.'+id+'{'+narrow+'}}'+focus;
  const box=owner.caption_box,font=box.line.strut.owner_font;
  styleEdges(caption,'margin',box.margins);styleEdges(caption,'padding',box.padding);
  caption.style.textAlign=box.text_align;
  caption.style.fontSize=`calc(var(--wikidict-normal-body-size) * ${box.line.strut.font_scale})`;
  caption.style.lineHeight=`calc(var(--wikidict-normal-body-size) * ${box.line.height.length.value})`;
  caption.style.fontWeight=font.bold?'bold':'normal';caption.style.fontStyle=font.italic?'italic':'normal';
  caption.style.fontFeatureSettings=font.font_features==='normal'?'normal':'"liga" 1, "clig" 1, "kern" 1, "ccmp" 1, "dist" 1, "mark" 1, "mkmk" 1';
  caption.style.fontFamily=fontFamilyCSS(font.font_family);
  caption.lang=font.language;
  for(const block of caption.querySelectorAll('.block'))if(block.closest('table')===table&&!block.classList.contains('heading')){
    // Ordinary paragraph defaults inherit the caption/nearest typed container.
    // Independent heading semantics and authored inline typography retain their
    // authority; the caption strut must not replace a descendant's style.
    for(const property of ['font-family','font-size','line-height','font-weight','font-style','font-feature-settings'])
      if(!block.style.getPropertyValue(property))block.style.setProperty(property,'inherit');
  }
  host.startCaption=()=>{
    let connected=true,frame=0;
    const media=matchMedia('(max-width:'+owner.max_viewport_width_px+'px)');
    const update=()=>{
      frame=0;if(!connected||!table.isConnected)return;
      const scrollable=media.matches&&(table.scrollWidth>table.clientWidth||table.scrollHeight>table.clientHeight);
      // The existing CAPTION supplies the table's name; do not replace it with
      // a generic label when the same table becomes keyboard scrollable.
      if(scrollable)table.tabIndex=0;
      else table.removeAttribute('tabindex');
    };
    const queue=()=>{if(connected&&!frame)frame=requestAnimationFrame(update);};
    const resize=new ResizeObserver(queue),mutation=new MutationObserver(queue);
    resize.observe(table);resize.observe(caption);for(const body of table.tBodies)resize.observe(body);
    mutation.observe(table,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['open','hidden','style','class']});
    media.addEventListener('change',queue);table.addEventListener('load',queue,true);
    document.fonts?.addEventListener('loadingdone',queue);document.fonts?.ready.then(queue);queue();
    return ()=>{connected=false;cancelAnimationFrame(frame);resize.disconnect();mutation.disconnect();media.removeEventListener('change',queue);table.removeEventListener('load',queue,true);document.fonts?.removeEventListener('loadingdone',queue);};
  };
  host.append(style,table);return host;
}
function tableDisclosureCategory(categories,edition,policy){
  const name=policy.category;
  if(categories.has(name))return categories.get(name);
  const button=node('button');button.type='button';
  const key=edition?'wikidict.visibility.'+JSON.stringify([edition,name]):null;
  let collapsed=policy.initially_collapsed;
  if(key){
    try{
      const saved=localStorage.getItem(key);
      if(saved==='true'||saved==='false')collapsed=saved==='false';
    }catch{/* A blocked store still permits changing the current page. */}
  }
  const members=new Map();
  function label(){button.textContent=(collapsed?'Show ':'Hide ')+name;}
  const category={button,add(show){members.set(show,collapsed);show(collapsed);},change(show,next){
    members.set(show,next);show(next);
    if(next!==collapsed&&[...members.values()].every(value=>value===next)){collapsed=next;label();}
  }};
  button.addEventListener('click',()=>{
    collapsed=!collapsed;label();
    for(const show of members.keys()){members.set(show,collapsed);show(collapsed);}
    if(key){try{localStorage.setItem(key,String(!collapsed));}catch{/* Retain the current page state. */}}
  });
  label();categories.set(name,category);return category;
}

function installTableDisclosure(group,policy,explanations){
  const category=tableDisclosureCategory(explanations.tableCategories,explanations.sourceEdition,policy);
  const rows=Array.from(group.rows),header=rows[policy.header_row].cells[policy.header_cell];
  const control=node('span',null,'table-disclosure'),button=node('button');
  button.type='button';
  // The brackets belong to the source decoration, outside the accessible button name.
  for(const part of ['[',button,']']){
    if(typeof part!=='string'){control.append(part);continue;}
    const bracket=node('span',part);
    bracket.setAttribute('aria-hidden','true');
    control.append(bracket);
  }
  header.prepend(control);
  header.classList.add('table-disclosure-header');
  const controlled=[];
  let collapsed=policy.initially_collapsed;
  function show(next){
    collapsed=next;
    button.textContent=next?policy.expand_label:policy.collapse_label;
    button.setAttribute('aria-expanded',String(!next));
    for(const [index,row] of rows.entries()){
      const mode=policy.row_modes[index];
      row.hidden=mode!=='always'&&(mode==='collapsed')!==next;
    }
  }
  for(const [index,row] of rows.entries()){
    const mode=policy.row_modes[index];
    if(mode==='always')continue;
    controlled.push(row);
    revealTableRow.set(row,()=>category.change(show,mode==='collapsed'));
  }
  // Associate the existing physical rows without manufacturing public fragment IDs.
  if('ariaControlsElements' in button)button.ariaControlsElements=controlled;
  button.addEventListener('click',()=>category.change(show,!collapsed));
  header.addEventListener('click',event=>{
    if(event.target.closest('th,td')!==header||event.target.closest('a,button,input,select,textarea,summary,audio,[role="link"]'))return;
    category.change(show,!collapsed);
  });
  category.add(show);
}

function tableView(value,onLink,explanations,depth=1,inheritedBackground=null){
  if(depth>16)throw Error('Nested table depth exceeds limit');
  if(value.geometry!=null&&(typeof value.geometry!=='object'||Array.isArray(value.geometry)))throw Error('Invalid table geometry object');
  const table=node('table'),g=value.geometry||{};
  const inline=value.style?.display==='inline_block'||value.style?.display==='inline_table';
  if(inline&&((value.caption!=null&&(!Array.isArray(value.caption)||value.caption.length))||value.caption_blocks!=null||!value.rows?.some(row=>row.cells?.length)))throw Error('Unsupported inline table caption or empty grid');
  const dimension=key=>{const n=g[key];if(n==null)return null;if(!Number.isInteger(n)||n<0||n>65535)throw Error('Invalid table geometry');return n;};
  const border=dimension('border'),spacing=dimension('cell_spacing'),padding=dimension('cell_padding');
  if(spacing!==null){table.style.borderCollapse='separate';table.style.borderSpacing=spacing+'px';}
  if(g.width!=null){const {unit,value:n}=g.width;if(!['px','percent'].includes(unit)||!Number.isInteger(n)||n<0||n>4294967295||(unit==='percent'&&n>100))throw Error('Invalid table width');table.style.width=n+(unit==='percent'?'%':'px');}
  applyTableStyle(table,value.style);
  const tableBackground=canonicalRGB(value.style?.background)?value.style.background:inheritedBackground;
  if(value.caption_blocks!=null){const caption=node('caption');appendBlocks(caption,value.caption_blocks,block=>blockView(block,onLink,explanations,'',{tableDepth:depth,background:tableBackground,caption:true}),explanations?.sourceAnchors);table.append(caption);}
  else if(value.caption?.length){const caption=node('caption');caption.append(spans(value.caption,onLink,false,explanations,false,tableBackground));table.append(caption);}
  const group=value.disclosure||value.caption_viewport?table.createTBody():table;
  for(const row of value.rows){const tr=node('tr');for(const cell of row.cells){
    const td=node(cell.header?'th':'td');td.colSpan=cell.colspan||1;td.rowSpan=cell.rowspan||1;
    if(border!==null)td.style.border=border+'px solid currentColor';if(padding!==null)td.style.padding=padding+'px';
    applyCellStyle(td,cell.style);
    const effectiveBackground=canonicalRGB(cell.background)?cell.background:tableBackground;
    // The new owner paints its own wide/narrow background once; retain only
    // genuinely authored cell backgrounds, not copies of the wide owner paint.
    if(canonicalRGB(effectiveBackground)&&(!value.caption_viewport||canonicalRGB(cell.background)))td.style.backgroundColor=effectiveBackground;
    if(cell.blocks!=null){
      if(!Array.isArray(cell.blocks)||cell.spans?.length||cell.nested_table!=null)throw Error('Invalid ordered table cell');
      appendBlocks(td,cell.blocks,block=>blockView(block,onLink,explanations,'',{tableDepth:depth,background:effectiveBackground,header:!!cell.header}),explanations?.sourceAnchors);
    }else if(cell.nested_table!=null){if(typeof cell.nested_table!=='object'||Array.isArray(cell.nested_table)||cell.spans?.length)throw Error('Invalid nested table cell');td.append(cell.nested_table.style?.float_side!=null?blockView({kind:'table',table:cell.nested_table},onLink,explanations,'',{tableDepth:depth,background:effectiveBackground}):tableView(cell.nested_table,onLink,explanations,depth+1,effectiveBackground));}
    else td.append(spans(cell.spans,onLink,false,explanations,false,effectiveBackground));
    tr.append(td);
  }group.append(tr);}
  if(value.disclosure)installTableDisclosure(group,value.disclosure,explanations);
  if(value.style?.line_height!=null)for(const block of table.querySelectorAll('.block')){
    if(value.caption_viewport&&(block.closest('caption')===table.caption||block.classList.contains('heading')||block.style.lineHeight))continue;
    block.style.lineHeight='inherit';
  }
  return value.caption_viewport?responsiveCaptionView(table,value):table;
}
function visibleBlock(block,sourceAnchors){
  return block.kind!=='blank'&&(((sourceAnchors||block.kind==='heading')&&(block.anchor||block.anchor_fallback))||block.description_body||block.container||block.figure||block.flow!=null||block.style||block.table||block.kind==='rule'||block.spans?.some(s=>s.image||s.inline_action_group||s.inline_box_group||s.clipped_absolute||s.text?.trim()||s.trail?.trim())||block.spans?.some(isPoem));
}
function appendBlocks(parent,values,render,sourceAnchors){
  const created=[];
  let lists=[];
  for(const block of values){
    const visible=visibleBlock(block,sourceAnchors);
    const path=block.list_path??block.path??'';
    const sense=block.kind==='definition'&&/^[*#:;]*#$/.test(path);
    const quotationItem=block.kind==='quotation'&&/^[*#:;]+\*$/.test(path)&&lists.some(list=>list.sense&&path.startsWith(list.path));
    if(block.kind==='list_item'||sense||quotationItem){
      const key=/^[*#:;]*[*#]$/.test(path)?path:(block.number?'#':'*');
      let at=lists.findIndex(list=>list.path===key&&list.sense===sense);
      if(at<0){
        while(lists.length&&(lists.at(-1).path===key||!key.startsWith(lists.at(-1).path)))lists.pop();
        const owner=lists.at(-1)?.item||parent,list=node(key.endsWith('#')?'ol':'ul',null,sense?'compiled-sense-list':'compiled-list');
        // Retain list semantics when custom visible markers suppress native markers.
        list.setAttribute('role','list');owner.append(list);created.push(list);
        lists.push({path:key,list,item:null,sense});at=lists.length-1;
      }
      lists.length=at+1;
      const current=lists[at],item=node('li',null,'compiled-list-item');
      if(block.column_break_inside!=null)item.style.breakInside=block.column_break_inside;
      if(sourceAnchors&&sense&&block.anchor)destination(item,block);
      if(key.endsWith('#')&&/^-?\d+$/.test(block.number||'')){
        const number=Number(block.number);
        if(Number.isInteger(number)&&number>=-2147483648&&number<=2147483647)item.value=number;
      }
      if(visible){
        const view=render(block);
        if(sense){
          // The native marker carries integer ordinals. Keep authored compound labels verbatim.
          if(block.number&&String(item.value)!==block.number)item.style.listStyleType='none';
          else view.querySelector(':scope > .prefix')?.remove();
          if(!block.style?.margins)view.style.removeProperty('margin-inline-start');
        }
        if(!block.number)view.querySelector(':scope > .prefix')?.setAttribute('aria-hidden','true');
        item.append(view);
      }
      current.list.append(item);current.item=item;
    }else{
      const continuation=['list_detail','example','quotation'].includes(block.kind)?/^([*#:;]*[*#]):+$/.exec(path):null;
      const at=continuation?lists.findIndex(list=>list.path===continuation[1]):-1;
      if(at>=0&&lists[at].item){
        lists.length=at+1;
        if(visible){
          const view=render(block),item=lists[at].item;
          view.querySelector(':scope > .prefix')?.setAttribute('aria-hidden','true');
          if(lists[at].sense&&(block.description_body||block.kind==='example'||block.kind==='quotation'))appendSenseDetail(item,view);
          else item.append(view);
        }
      }else{lists=[];if(visible){if(block.container?.style.inline_atomic==='after_space')parent.append(' ');parent.append(render(block));}}
    }
  }
  // An empty item can own a later continuation or child list. Remove a list only after all its children are known.
  for(const list of created.reverse())if([...list.children].every(item=>!item.childElementCount))list.remove();
}
function appendSenseDetail(item,view){
  let details=item.lastElementChild;
  if(details?.tagName!=='DL'){details=node('dl',null,'compiled-sense-details');item.append(details);}
  const description=node('dd');description.append(view);details.append(description);
}
function visitBlocks(values,visit){
  const figure=value=>{if(value.caption_blocks!=null)visitBlocks(value.caption_blocks,visit);};
  const flow=parts=>{for(const part of parts){if(part.figure)figure(part.figure);if(part.scope)flow(part.scope.parts);}};
  const table=value=>{if(value.caption_blocks!=null)visitBlocks(value.caption_blocks,visit);for(const row of value.rows||[])for(const cell of row.cells||[]){if(cell.blocks!=null)visitBlocks(cell.blocks,visit);else if(cell.nested_table)table(cell.nested_table);}};
  for(const block of values||[]){visit(block);if(block.table)table(block.table);if(block.figure)figure(block.figure);if(block.flow)flow(block.flow);const box=block.description_body?.box??block.container;if(box)visitBlocks(box.blocks,visit);}
}
let containerSequence=0;
const containerWidthCSS=value=>value.length?(value.length.unit==='percent'?value.length.value+'%':styleLength(value.length)):Object.hasOwn(value,'fit_content')?'fit-content':Object.hasOwn(value,'max_content')?'max-content':Object.hasOwn(value,'none')?'none':'auto';
const containerColorCSS=(value,dark)=>Object.hasOwn(value,'rgb')?value.rgb:value.light_dark?value.light_dark[dark?'dark':'light']:'transparent';
const containerHeightCSS=value=>Object.hasOwn(value,'multiplier')?String(value.multiplier):value.length?styleLength(value.length):'normal';
const positionedLength=({px,percent})=>`calc(${percent}% + ${px}px)`;
function containerDeclarations(style,dark=false){
  const css=[];
  const set=(key,value)=>css.push(key+':'+value);
  const margins=style.margin_values??style.margins;
  if(margins)for(const side of ['top','right','bottom','left']){
    const value=margins[side];set('margin-'+side,value.unit?styleLength(value,true):value.length?styleLength(value.length,true):'auto');
  }
  if(style.padding)for(const side of ['top','right','bottom','left'])set('padding-'+side,styleLength(style.padding[side]));
  if(style.width)set('width',containerWidthCSS(style.width));if(style.max_width)set('max-width',containerWidthCSS(style.max_width));
  if(style.float_side!=null)set('float',style.float_side);if(style.clear!=null)set('clear',style.clear);
  if(style.box_sizing!=null)set('box-sizing',style.box_sizing.replace('_','-'));
  if(style.layout!=null)set('display',['flex_row','flex_column'].includes(style.layout)?'flex':'block');
  if(style.layout==='flex_column')set('flex-direction','column');
  if(style.align_items!=null)set('align-items',({start:'flex-start',end:'flex-end'})[style.align_items]??style.align_items);
  if(style.flex_item!=null)set('flex','none');
  if(style.background){
    const color=containerColorCSS(style.background,dark);
    set('background-color',style.translated_absolute?`color-mix(in srgb, ${color} ${style.translated_absolute.background_alpha*100}%, transparent)`:color);
  }
  if(style.border){
    const paint=edge=>{
      const [kind,line]=Object.entries(edge)[0];
      return kind==='none'||kind==='hidden'?kind:styleLength(line.width)+' '+kind+' '+containerColorCSS(line.color,dark);
    };
    if(style.border.edges){for(const [side,edge] of Object.entries(style.border.edges))set('border-'+side,paint(edge));}
    else set('border',paint(style.border));
  }
  if(style.line_height)set('line-height',containerHeightCSS(style.line_height));
  if(style.text_align!=null)set('text-align',style.text_align);
  if(style.overflow!=null)set('overflow',style.overflow);
  if(style.owner_font_scale!=null)set('font-size',`calc(var(--wikidict-normal-body-size) * ${style.owner_font_scale})`);
  if(style.owner_font){
    const font=style.owner_font,size=semanticFontSize(font);
    if(size!=null)set('font-size',size);
    set('font-weight',font.bold?'bold':'normal');set('font-style',font.italic?'italic':'normal');
    if(font.code)set('font-family','monospace');
  }
  if(style.height!=null)set('height',styleLength(style.height));
  if(style.min_height!=null)set('min-height',styleLength(style.min_height));
  if(style.positioning==='relative_auto')set('position','relative');
  if(style.corner_radius_px!=null)set('border-radius',style.corner_radius_px+'px');
  if(style.inline_atomic)set('display','inline-block');
  if(style.translated_absolute){
    const {placement,z_index}=style.translated_absolute;
    set('position','absolute');set('left',positionedLength(placement.left));set('top',positionedLength(placement.top));
    set('transform',`translate(${positionedLength(placement.translate_x)}, ${positionedLength(placement.translate_y)})`);
    if(z_index!=null)set('z-index',String(z_index));
  }
  if(style.columns){
    if(style.columns.count!=null)set('column-count',String(style.columns.count));
    if(style.columns.width)set('column-width',styleLength(style.columns.width));
    set('column-gap',styleLength(style.columns.gap));set('column-fill','balance');
  }
  return css.join(';');
}
function orderedContainerView(value,onLink,explanations,context){
  const list=node('ol',null,'compiled-container compiled-ordered-list');
  list.setAttribute('role','list');
  if(!context.container&&!context.tableDepth&&!context.caption)list.classList.add('compiled-container-root');
  list.style.cssText=containerDeclarations(value.style);
  list.style.setProperty('--compiled-marker-weight',value.style.ordered_marker_weight==='bold'?'700':'400');
  const childContext={...context,container:true};
  for(const block of value.blocks){
    const {style,blocks:[head,...details]}=block.container;
    const item=node('li',null,'compiled-ordered-item');
    item.style.cssText=containerDeclarations(style);
    if(head.column_break_inside!=null)item.style.breakInside=head.column_break_inside;
    if(explanations?.sourceAnchors&&head.kind==='definition'&&head.anchor)destination(item,head);
    const view=blockView(head,onLink,explanations,'',childContext);
    view.querySelector(':scope > .prefix')?.remove();
    if(!head.style?.margins)view.style.removeProperty('margin-inline-start');
    item.append(view);
    for(const child of details){
      const detail=blockView(child,onLink,explanations,'',childContext);
      detail.querySelector(':scope > .prefix')?.setAttribute('aria-hidden','true');
      appendSenseDetail(item,detail);
    }
    list.append(item);
  }
  return list;
}
function containerView(value,onLink,explanations,context,before=null){
  if(value.style.layout==='ordered_list')return orderedContainerView(value,onLink,explanations,context);
  const cls='compiled-container-'+(++containerSequence),el=node('div',null,'compiled-container '+cls),style=node('style');
  if(value.style.owner_font?.language)el.lang=value.style.owner_font.language;
  if(!context.container&&!context.tableDepth&&!context.caption)el.classList.add('compiled-container-root');
  // Only validated typed values enter this stylesheet. Rules remain scoped to
  // this owner and react to the viewport/theme without a second layout engine.
  style.textContent='.'+cls+'{'+containerDeclarations(value.style)+'}'+':root[data-theme="dark"] .'+cls+'{'+containerDeclarations(value.style,true)+'}';
  const screen=value.style.screen_max_width;
  for(const rule of screen?[screen,...(screen.following_rules??[])]:[])
    style.textContent+='@media(max-width:'+rule.max_width_px+'px){.'+cls+'{'+containerDeclarations(rule)+'}:root[data-theme="dark"] .'+cls+'{'+containerDeclarations(rule,true)+'}}';
  if(before){
    // The source DD owns a non-interactive pseudo-element in its own padding box.
    el.classList.add('compiled-description-body');
    el.setAttribute('role','definition');
    el.style.position='relative';
    for(const key of ['top','bottom','left','width'])el.style.setProperty('--description-'+key,styleLength(before[key]));
    el.style.setProperty('--description-fill','light-dark('+containerColorCSS(before.fill,false)+','+containerColorCSS(before.fill,true)+')');
    if(value.style.line_height)explanations={...explanations,audioCredit:value.blocks[0].spans[1]};
  }
  el.append(style);
  if(value.style.overflow==='auto'){el.tabIndex=0;el.setAttribute('aria-label','Scrollable content');}
  const target=value.disclosure==null?null:value.blocks[value.disclosure.content_index];
  let content=null,targets=0;
  appendBlocks(el,value.blocks,block=>{
    const child=blockView(block,onLink,explanations,'',{...context,container:true});
    if(target&&block===target){content=child;targets++;}
    return child;
  },explanations?.sourceAnchors);
  if(value.disclosure!=null){
    if(targets!==1||!(content instanceof Element))throw Error('Missing compiled disclosure content owner');
    installContainerDisclosure(el,content,value);
  }
  return el;
}
// A fractional final glyph can outlive the scrollport's rounded maximum.
// Give ordinary start-aligned PRE content only the missing fractional end gutter.
function preformattedScrollPort(pre){
  const name='wikidict-preformatted-scroll';
  if(!customElements.get(name))customElements.define(name,class extends HTMLElement{
    connectedCallback(){this.stopPre?.();this.stopPre=this.startPre?.();}
    disconnectedCallback(){this.stopPre?.();this.stopPre=null;}
  });
  const host=document.createElement(name);host.style.display='contents';host.append(pre);
  host.startPre=()=>{
    let active=true,frame=0,ownedPadding=null;
    const clearPadding=()=>{
      if(ownedPadding!==null&&pre.style.paddingInlineEnd===ownedPadding)
        pre.style.removeProperty('padding-inline-end');
      ownedPadding=null;
    };
    const update=()=>{
      frame=0;if(!active||!pre.isConnected)return;
      clearPadding();
      if(!pre.getClientRects().length)return;
      const style=getComputedStyle(pre),rtl=style.direction==='rtl';
      // An end gutter must not shift centered/end-aligned authored text or replace padding.
      if(style.writingMode!=='horizontal-tb'||style.whiteSpace!=='pre'||
        !['auto','scroll'].includes(style.overflowX)||
        !(style.textAlign==='start'||style.textAlign===(rtl?'right':'left'))||
        parseFloat(style.paddingInlineStart)!==0||parseFloat(style.paddingInlineEnd)!==0)return;
      const box=pre.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(pre);
      const start=rtl?box.right-parseFloat(style.borderRightWidth):box.left+parseFloat(style.borderLeftWidth);
      let extent=0;
      for(const rect of range.getClientRects()){
        const end=rtl?rect.left+pre.scrollLeft:rect.right+pre.scrollLeft;
        extent=Math.max(extent,rtl?start-end:end-start);
      }
      const overflow=extent-pre.clientWidth;
      if(!Number.isFinite(overflow)||overflow<=0)return;
      const gutter=Math.ceil(overflow)-overflow;
      if(gutter>0&&gutter<1){pre.style.paddingInlineEnd=gutter+'px';ownedPadding=pre.style.paddingInlineEnd;}
    };
    const queue=()=>{if(active&&!frame)frame=requestAnimationFrame(update);};
    const resize=new ResizeObserver(queue),mutation=new MutationObserver(queue);
    resize.observe(pre);
    mutation.observe(pre,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','dir','hidden']});
    host.addEventListener('load',queue,true);document.fonts?.addEventListener('loadingdone',queue);
    document.fonts?.ready.then(queue);queue();
    return ()=>{active=false;cancelAnimationFrame(frame);resize.disconnect();mutation.disconnect();host.removeEventListener('load',queue,true);document.fonts?.removeEventListener('loadingdone',queue);clearPadding();};
  };
  return host;
}

function blockView(block, onLink, explanations, legacy = '', context = {}) {
  if(block.text_align!=null&&!['left','center','right'].includes(block.text_align))throw Error('Invalid block text alignment');
  const margin = `${Math.min(Math.max(block.depth || 0,0),8)*.45}rem`;
  if(block.description_body){const body=block.description_body;return containerView(body.box,onLink,explanations,context,body.before);}
  if(block.kind==='container')return containerView(block.container,onLink,explanations,context);
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
    if(block.table.caption_viewport)return table;
    const inline=block.table.style?.display==='inline_block'||block.table.style?.display==='inline_table';
    if(context.tableDepth&&!block.table.style?.float_side){table.style.marginInlineStart=margin;return table;}
    const wrap = node('div', null, 'table-scroll'); wrap.style.marginInlineStart = margin; wrap.tabIndex = 0; wrap.setAttribute('aria-label','Scrollable table');
    // Preserve intrinsic fit beside floats while keeping indentation inside the article.
    if(!inline&&!block.table.style?.float_side&&block.table.style?.display==null&&block.table.style?.width==null&&block.table.geometry?.width==null){
      wrap.style.width='fit-content';wrap.style.maxWidth=`calc(100% - ${margin})`;
    }
    if(block.table.style?.display!=null||block.table.style?.vertical_align!=null||block.table.style?.line_height!=null){
      wrap.style.font='var(--wikidict-normal-body-size)/normal Reader,Georgia,serif';
      if(inline){
        wrap.style.padding='0';
        if(block.kind==='list_item'){
          const prefix=node('span',block.number?block.number+'.':'•','prefix');
          prefix.style.font='inherit';prefix.style.display='inline-block';prefix.style.marginInlineEnd='10px';wrap.append(prefix);
        }
      }
    }
    if(block.table.style?.clear!=null&&!inline)wrap.style.clear=block.table.style.clear;
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
  if (block.kind === 'preformatted') { const pre = node('pre'); if(block.text_align!=null)pre.style.textAlign=block.text_align; if(context.header)pre.style.fontWeight='inherit'; pre.append(spans(block.spans,onLink,true,explanations,false,context.background)); return preformattedScrollPort(pre); }
  const allowed = new Set(['paragraph','definition','example','quotation','list_item','list_detail','indent','term','heading']);
  const kind = allowed.has(block.kind) ? block.kind : 'paragraph';
  const el = node(kind === 'heading'?'h'+(Number.isInteger(block.level)&&block.level>=1&&block.level<=6?block.level:4):'div',null,'block '+kind);
  el.style.marginInlineStart = margin;
  if(block.column_break_inside!=null)el.style.breakInside=block.column_break_inside;
  if(context.tableDepth||block.text_align!=null)el.classList.add('compiled-aligned-block');
  if(block.text_align!=null)el.style.textAlign=block.text_align;
  if(context.header)el.style.fontWeight='inherit';
  if (kind === 'heading') destination(el, block, legacy);
  if (explanations?.sourceAnchors && kind === 'paragraph' && block.anchor) destination(el, block);
  const prefix = kind==='definition'?(block.number?`${block.number}.`:'•'):['example','quotation'].includes(kind)?'│':kind==='list_item'?(block.number?`${block.number}.`:'•'):kind==='list_detail'?'↳':'';
  if (prefix) el.append(node('span',prefix,'prefix'));
  const rich=block.figure!=null||block.flow!=null;
  const body=node(rich?'div':'span',null,'body');
  if(block.spans?.some(isPoem)||rich)body.style.flex='1';
  if(block.figure!=null)body.append(figureView(block.figure,onLink,explanations,context));
  else if(block.flow!=null)body.append(flowView(block.flow,onLink,explanations,context));
  else {
    // Only plain definitions on the Reader surface have a known theme backdrop.
    const darkSurface=kind==='definition'&&!context.background&&!context.container&&!context.tableDepth&&!context.caption?explanations?.darkReadingSurface:null;
    body.append(spans(block.spans,onLink,false,explanations,false,context.background,null,darkSurface));
  }
  if(rich){el.style.display='block';body.style.display='block';if(prefix){const marker=el.querySelector('.prefix');marker.style.cssFloat='inline-start';marker.style.marginInlineEnd='10px';}}
  if(block.style?.margins)styleEdges(el,'margin',block.style.margins);
  if(block.style?.padding)styleEdges(el,'padding',block.style.padding);
  el.append(body);return el;
}
function applyWrappedHeading(summary,style){
  const label=summary.querySelector('.heading-label');
  if(!label)throw Error('Missing styled heading title');
  const {outer,inner,title_block_padding_right:pad}=style.wrappers;
  const shell=node('span',null,'compiled-heading-outer'),content=node('span',null,'compiled-heading-inner');
  const title=node('span',null,'compiled-heading-title');
  const {width,color}=outer.border.edges.top.dashed;
  shell.style.cssText=containerDeclarations({margins:outer.margins});
  shell.style.display='block';
  shell.style.overflowX='visible';
  shell.style.overflowY='clip';
  shell.style.borderTop=styleLength(width)+' dashed '+(color.rgb??'light-dark('+color.light_dark.light+', '+color.light_dark.dark+')');
  content.style.cssText=containerDeclarations(inner);
  content.style.display='block';
  title.style.cssText=containerDeclarations(style.box);
  title.style.position='relative';
  title.style.display='block';
  title.style.paddingRight=pad.value+'em';
  title.style.fontFamily='sans-serif';
  title.style.fontWeight=style.font.bold?'bold':'normal';
  title.style.fontStyle=style.font.italic?'italic':'normal';
  title.lang=style.font.language;
  title.dir=style.direction;
  label.replaceWith(shell);
  shell.append(content);
  content.append(title);
  title.append(label);
}

export function sectionHeadingCompanion(section){
  const first=section.blocks?.[0];
  if(!section.title||!first||first.kind!=='heading'||first.level!==section.level)return null;
  if(first.text_align!=null)return null;
  if(first.inline_destinations?.length)return first; // Already validated exact untrimmed title/run ownership.
  let navigable=false,explained=false,styledText=false,visual=false,label='';
  for(const span of first.spans||[]){
    if(span.kind==='line_break'&&span.trail)return null;
    visual=visual||span.image!=null||span.inline_box_group!=null;
    explained=explained||!!span.explanation;
    navigable=navigable||(['link','external_link'].includes(span.kind)&&!!(span.target||(span.kind==='link'&&span.target_fragment))&&!!inlineText([span]));
    const styled=['bold','italic','code','small','superscript','subscript','strike','underline'].some(flag=>span[flag])||
      (span.font_scale_basis==='normal_body'||(span.font_scale!=null&&span.font_scale!==1))||span.foreground!=null||span.background!=null||!!span.classes||!!span.language||!!span.direction||(span.role??'normal')!=='normal';
    styledText=styledText||(span.kind==='text'&&!!span.text&&!span.target&&styled);
    label+=inlineText([span],'\n');
  }
  const trimmed=label.replace(/^[ \t\r\n\u00a0]+|[ \t\r\n\u00a0]+$/g,'');
  return (navigable||explained||styledText||visual||first.depth>0)&&trimmed===section.title?first:null;
}
export function renderEntry(entry, onLink, settings = {}, mediaView = () => null, inlineImage = () => {}, imageActionURL = () => null) {
  const sourceAnchors=validateRichEntry(entry);
  const fragment = document.createDocumentFragment(), references = new Map(), legacy = legacyDestinations(entry);
  let hasTableFloat=false;
  const inspectTableFloat=table=>{
    if(table.style?.float_side!=null){if(!['left','right'].includes(table.style.float_side))throw Error('Invalid table float side');hasTableFloat=true;}
    for(const row of table.rows||[])for(const cell of row.cells||[])if(cell.nested_table)inspectTableFloat(cell.nested_table);
  };
  const flowFloat=parts=>parts.some(part=>part.figure?.placement?.startsWith('float_')||(part.scope&&flowFloat(part.scope.parts)));
  const inspectFloat=block=>{if(block.table)inspectTableFloat(block.table);if(block.container||block.figure?.placement?.startsWith('float_')||(block.flow&&flowFloat(block.flow)))hasTableFloat=true;};
  for(const section of entry.sections)visitBlocks(section.blocks,inspectFloat);
  for(const ref of entry.references||[])if(Array.isArray(ref.blocks))visitBlocks(ref.blocks,inspectFloat);
  const root=hasTableFloat?node('div',null,'compiled-table-flow'):fragment;
  if(hasTableFloat)fragment.append(root);
  const authoredDestinations = new Set();
  const observeDestination=value=>{for(const id of [value.anchor,value.anchor_fallback,legacy.get(value)])if(id)authoredDestinations.add(id);};
  const observeBlock=block=>{if(sourceAnchors||block.kind==='heading')observeDestination(block);for(const value of block.inline_destinations||[])authoredDestinations.add(value.id);};
  for(const section of entry.sections){observeDestination(section);visitBlocks(section.blocks,observeBlock);}
  for(const ref of entry.references||[]){
    if(ref.blocks!=null){
      if(!Array.isArray(ref.blocks)||!Array.isArray(ref.spans)||ref.spans.length)throw Error('Invalid structured reference');
      visitBlocks(ref.blocks,observeBlock);
    }
  }
  const explanationRows=[], explanationKeys=new Map();
  const mediaOwnerPrefix='wikidict-media-file-',mediaOwners=new Map();
  for(const media of entry.media||[])if(media.kind==='audio'&&media.file){
    const hex=[...new TextEncoder().encode(media.file)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
    mediaOwners.set(mediaOwnerPrefix+hex,media.file);
  }
  const darkSurface=globalThis.getComputedStyle?.(document.documentElement).getPropertyValue('--wikidict-dark-reading-surface').trim();
  const explanations={sourceAnchors,tableCategories:new Map(),exteriorBoxes:[],inlineImage,imageActionURL,audioControl:(span,label)=>audioControlView(span,label,settings,entry.source_edition),sourceEdition:entry.source_edition,darkReadingSurface:canonicalRGB(darkSurface)?darkSurface:null,isMediaExplanation(span){
    if(span.kind!=='link'||span.image)return false;
    const tokens=poemTokens(span),owners=tokens.filter(token=>token.startsWith(mediaOwnerPrefix));
    // Match the compiled media catalog, not an ordinary File link or a legacy abbreviation.
    const file=owners.length===1?mediaOwners.get(owners[0]):null;
    return !!file&&tokens.includes('wikidict-media')&&span.text===file&&span.target==='File:'+file;
  },add(label,explanation){
    const key=JSON.stringify([label,explanation]);
    if(explanationKeys.has(key))return explanationKeys.get(key);
    let id;do{id='abbreviation-explanation-'+(++explanationSequence);}while(authoredDestinations.has(id));
    explanationKeys.set(key,id);explanationRows.push({id,label,explanation});return id;
  }};
  const followLink = (target,targetFragment) => {
    const parts=linkTargetParts(target,targetFragment),fragment=parts.title===''?parts.fragment:null;
    const dispatch=()=>targetFragment==null?onLink(target):onLink(target,targetFragment);
    // Authored destinations take precedence over generated citation IDs.
    if (fragment && (authoredDestinations.has(fragment)||authoredDestinations.has(fragment.replaceAll(' ','_')))) { dispatch(); return; }
    const reference = fragment?references.get('#'+fragment):null;
    if (!reference) { dispatch(); return; }
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
  function fold(title, open=false, rich=null, depth=0, level=0, normalizedEmphasis=false, destinations=[]) {
    const el=node('details'),summary=node('summary',rich?null:title);el.open=open;
    if(rich){const authoredLevel=Number.isInteger(level)&&level>=1&&level<=6;
      const label=node(authoredLevel?'h'+level:'span',null,'heading-label');
      // Preserve the original title spacing when styled leaf runs become separate AX nodes.
      if(authoredLevel)label.setAttribute('aria-label',inlineText(rich,'\n').trim());
      if(depth>0){label.style.display='inline-block';label.style.marginInlineStart=`${Math.min(depth,8)*.45}rem`;}
      const starts=destinations.length?[]:null;
      label.append(spans(rich,followLink,!!starts,explanations,true,null,null,null,normalizedEmphasis,starts));
      if(starts){
        const mapped=new Map();
        for(const value of destinations){const text=starts[value.before_run];if(!text||text.nodeType!==3||!text.length)throw Error('Missing inline destination run');mapped.set(value.id,text);}
        inlineDestinationOwners.set(label,mapped);
      }
      summary.append(label);}
    el.append(summary);return el;
  }
  if (entry.preamble_spans?.length) { const preamble=fold('About this entry',entry.kind==='alias'||!settings.collapseOtherSections);preamble.append(spans(entry.preamble_spans,followLink,false,explanations));root.append(preamble); }
  for (const section of entry.sections) {
    if(section===emptyOwner)continue;
    const containsDefinition=block=>previewBlocks([block]).some(value=>value.kind==='definition');
    const meaning=section.blocks.some(containsDefinition);
    const expanded=meaning || (section.title.startsWith('Pronunciation')?!settings.collapsePronunciation:section.title.startsWith('Etymology')?!settings.collapseEtymology:!settings.collapseOtherSections);
    const companion=sectionHeadingCompanion(section);
    const el=fold(section.title===entry.language?'Overview':section.title||'Notes',expanded,companion?.spans,companion?.depth,section.level,!!section.heading_style?.font,companion?.inline_destinations);
    if(section.heading_style){
      validateWrappedHeading(section);
      applyWrappedHeading(el.querySelector('summary'),section.heading_style);
    }
    el.classList.toggle('meaning',meaning);destination(el,section,legacy.get(section)||'');
    const body=companion?section.blocks.slice(1):section.blocks;
    appendBlocks(el,body,block=>blockView(block,followLink,explanations,legacy.get(block)||''),sourceAnchors);
    if(section.blocks.some(block=>visibleBlock(block,sourceAnchors))||companion||section.anchor||section.anchor_fallback)root.append(el);
  }
  if (entry.references?.length) {
    const section=fold('References',!settings.collapseOtherSections);
    const referenceIDs=new Set(authoredDestinations);
    for (const ref of entry.references) {
      const p=node(ref.blocks!=null?'div':'p',null,'reference'),kind=ref.kind??'note';
      if(kind==='note'){
        const target=`reference-${ref.number}`;let id=target;
        while(referenceIDs.has(id))id='citation-'+id;
        referenceIDs.add(id);p.id=id;p.tabIndex=-1;references.set(`#${target}`,p);
        p.append(node('span',`[${ref.group?ref.group+' ':''}${ref.group_number}]`));
      }else if(kind!=='fragment')throw Error('Invalid compiled reference kind');
      if(ref.blocks!=null)appendBlocks(p,ref.blocks,block=>blockView(block,followLink,explanations),sourceAnchors);
      else {const body=node('span');body.append(spans(ref.spans,followLink,false,explanations));p.append(body);}
      section.append(p);
    }
    root.append(section);
  }
  if(explanations.tableCategories.size){
    const visibility=node('nav',null,'table-visibility');visibility.setAttribute('aria-label','Visibility');
    for(const category of explanations.tableCategories.values())visibility.append(category.button);
    title.after(visibility);
  }
  const canonicalImageFiles=new Set();
  const imageSpans=values=>{for(const span of values||[])if(span.image)canonicalImageFiles.add(span.image.file);};
  const imageFigure=value=>{imageSpans([value.image_span]);if(value.caption_blocks!=null)imageBlocks(value.caption_blocks);else imageSpans(value.caption);};
  const imageFlow=parts=>{for(const part of parts){imageSpans(part.spans);if(part.figure)imageFigure(part.figure);if(part.scope)imageFlow(part.scope.parts);}};
  const imageTable=value=>{if(value.caption_blocks!=null)imageBlocks(value.caption_blocks);else imageSpans(value.caption);for(const row of value.rows||[])for(const cell of row.cells||[]){imageSpans(cell.spans);if(cell.blocks)imageBlocks(cell.blocks);if(cell.nested_table)imageTable(cell.nested_table);}};
  const imageBlocks=values=>{for(const block of values||[]){imageSpans(block.spans);if(block.table)imageTable(block.table);if(block.figure)imageFigure(block.figure);if(block.flow)imageFlow(block.flow);const box=block.description_body?.box??block.container;if(box)imageBlocks(box.blocks);}};
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
  if(explanations.exteriorBoxes.length)wrapExteriorBoxes(fragment,explanations.exteriorBoxes);
  return fragment;
}
