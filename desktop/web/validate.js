const forbidden = new Set(['source','source_base64','payload_base64','unexpanded_templates','rendered_templates','expansion','deferred','content']);
const kinds = new Set(['text','link','external_link','line_break']);
export function validate(value) {
  if (!value || value.schema !== 'dict.results.v1' || !Array.isArray(value.entries)) throw Error('Unsupported dictionary package.');
  let objects = 0;
  function visit(v, depth = 0) {
    if (depth > 64 || ++objects > 2000000) throw Error('Dictionary structure exceeds the reader limit.');
    if (!v || typeof v !== 'object') return;
    for (const [key, child] of Object.entries(v)) {
      if (forbidden.has(key)) throw Error(`Uncompiled field: ${key}`);
      if (key === 'spans' || key === 'display_title' || key === 'preamble_spans') {
        if (!Array.isArray(child) || child.some(s => !s || !kinds.has(s.kind ?? 'text') || typeof s.text !== 'string' || (s.target_fragment!=null&&(s.kind!=='link'||!validTargetFragment(s.target_fragment))))) throw Error('Invalid compiled spans.');
      }
      if (key === 'colspan' || key === 'rowspan') if (!Number.isInteger(child) || child < 1 || child > 100) throw Error('Invalid table span.');
      visit(child, depth + 1);
    }
  }
  visit(value);
  for (const entry of value.entries) {
    if (typeof entry.title !== 'string' || !Array.isArray(entry.sections)) throw Error('Invalid dictionary entry.');
    for (const section of entry.sections) if (typeof section.title !== 'string' || !Array.isArray(section.blocks)) throw Error('Invalid section.');
  }
  return value;
}
export function safeURL(target) {
  try { const url = new URL(target); return ['http:', 'https:'].includes(url.protocol) ? url.href : null; } catch { return null; }
}

const fragmentUtf8=new TextEncoder();
const validTargetFragment=value=>typeof value==='string'&&!/[\ud800-\udfff]/u.test(value)&&fragmentUtf8.encode(value).length<=32*1024*1024;
// A present component owns the whole title; only legacy null splits combined text.
export function linkTargetParts(target,targetFragment){
 if(typeof target!=='string'||(targetFragment!=null&&!validTargetFragment(targetFragment)))throw Error('Invalid compiled link component');
 if(targetFragment!=null)return {title:target,fragment:targetFragment};
 const hash=target.indexOf('#');return {title:hash<0?target:target.slice(0,hash),fragment:hash<0?undefined:target.slice(hash+1)};
}
export const isBookSourcesTitle=title=>typeof title==='string'&&title.startsWith('Special:Booksources/')&&title.length>'Special:Booksources/'.length;
export function bookSourcesURL(target,sourceEdition,targetFragment){
 if(typeof target!=='string')return null;
 const {title,fragment}=linkTargetParts(target,targetFragment);
 if(!isBookSourcesTitle(title))return null;
 const edition=/^[a-z0-9_-]+wiktionary$/.test(sourceEdition||'')?sourceEdition.slice(0,-10).replaceAll('_','-'):null;
 if(!edition)return null;
 const suffix=fragment===undefined||(targetFragment!=null&&fragment==='')?'':'#'+encodeURIComponent(fragment);
 return 'https://'+edition+'.wiktionary.org/wiki/'+encodeURIComponent(title)+suffix;
}

// DPRL's closed container domain. Later font/adjoining-margin capabilities are
// deliberately absent here; accepting their fields would silently lose layout.
const containerError=()=>{throw Error('Invalid compiled container');};
const containerKeys=['margins','padding','width','float_side','clear','max_width','box_sizing','layout','align_items','flex_item','background','border','line_height','text_align','screen_max_width','overflow'];
const sides=['top','right','bottom','left'];
function containerObject(value,keys,required=[]){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(key=>!keys.includes(key))||required.some(key=>!Object.hasOwn(value,key)))containerError();
}
function containerNumber(value){if(typeof value!=='number'||!Number.isFinite(value)||value<0||value>3.4028234663852886e38)containerError();}
function containerLength(value,units=['px','em']){containerObject(value,['unit','value'],['unit','value']);if(!units.includes(value.unit))containerError();containerNumber(value.value);}
function containerUnion(value,variants){containerObject(value,Object.keys(variants));const keys=Object.keys(value);if(keys.length!==1)containerError();variants[keys[0]](value[keys[0]]);}
const emptyContainerTag=value=>containerObject(value,[]);
const containerWidth=value=>containerUnion(value,{auto:emptyContainerTag,fit_content:emptyContainerTag,length:v=>containerLength(v,['px','em','percent'])});
const containerMaxWidth=value=>containerUnion(value,{none:emptyContainerTag,length:v=>containerLength(v,['px','em','percent'])});
const containerLineHeight=value=>containerUnion(value,{normal:emptyContainerTag,multiplier:containerNumber,length:containerLength});
const containerMargin=value=>containerUnion(value,{auto:emptyContainerTag,length:containerLength});
function containerEdges(value,check=containerLength){containerObject(value,sides,sides);for(const side of sides)check(value[side]);}
const containerRGB=value=>{if(typeof value!=='string'||!/^#[0-9a-f]{6}$/.test(value))containerError();};
const containerColor=value=>containerUnion(value,{transparent:emptyContainerTag,rgb:containerRGB,light_dark:v=>{containerObject(v,['light','dark'],['light','dark']);containerRGB(v.light);containerRGB(v.dark);}});
const containerEnum=(value,values)=>{if(!values.includes(value))containerError();};
export function validateCellMetrics(style){
  if(style.width!=null)containerLength(style.width,['px','em','percent']);
  if(style.min_width!=null)containerLength(style.min_width);
  if(style.vertical_align!=null)containerEnum(style.vertical_align,['top','middle']);
  if(style.line_height!=null){
    const value=style.line_height;containerObject(value,['strut','height'],['height']);
    const metric=(v,key)=>{containerObject(v,[key,'font_scale_basis'],[key,'font_scale_basis']);containerNumber(v[key]);containerEnum(v.font_scale_basis,['normal_body','css_px']);};
    if(value.strut!=null)metric(value.strut,'font_scale');
    containerUnion(value.height,{normal:emptyContainerTag,multiplier:containerNumber,length:v=>metric(v,'value')});
  }
}
function containerScreen(value,following=false){
  const fields=['width','max_width','box_sizing','line_height','float_side','margins','clear'];
  containerObject(value,['max_width_px',...fields,'following_rules'],['max_width_px']);
  if(!Number.isInteger(value.max_width_px)||value.max_width_px<0||value.max_width_px>0xffffffff||!fields.some(key=>value[key]!=null))containerError();
  if(value.width!=null)containerWidth(value.width);if(value.max_width!=null)containerMaxWidth(value.max_width);
  if(value.box_sizing!=null)containerEnum(value.box_sizing,['content_box','border_box']);
  if(value.line_height!=null)containerLineHeight(value.line_height);
  if(value.float_side!=null)containerEnum(value.float_side,['none','left','right']);
  if(value.margins!=null)containerEdges(value.margins,containerMargin);
  if(value.clear!=null)containerEnum(value.clear,['none','left','right','both']);
  const rest=value.following_rules??[];
  if(!Array.isArray(rest)||rest.length>=16||(following&&rest.length))containerError();
  let limit=value.max_width_px;
  for(const rule of rest){containerScreen(rule,true);if(rule.max_width_px>=limit)containerError();limit=rule.max_width_px;}
}
export function validateContainerStyle(style,{containerFonts=false}={}){
  containerObject(style,containerFonts?[...containerKeys,'owner_font_scale','height','columns']:containerKeys);
  if(style.owner_font_scale!=null)containerNumber(style.owner_font_scale);
  if(style.height!=null)containerLength(style.height);
  if(style.columns!=null){
    containerObject(style.columns,['count','gap'],['count','gap']);
    if(!Number.isInteger(style.columns.count)||style.columns.count<1||style.columns.count>65535)containerError();
    containerLength(style.columns.gap);
    if(style.height!=null||style.min_height!=null||style.layout==='flex_row'||style.overflow==='auto'||style.overflow==='hidden'||style.positioning!=null||style.absolute_position!=null)containerError();
  }
  for(const key of ['margins','padding'])if(style[key]!=null)containerEdges(style[key]);
  if(style.width!=null)containerWidth(style.width);if(style.max_width!=null)containerMaxWidth(style.max_width);
  if(style.float_side!=null)containerEnum(style.float_side,['left','right']);
  if(style.clear!=null)containerEnum(style.clear,['none','left','right','both']);
  if(style.box_sizing!=null)containerEnum(style.box_sizing,['content_box','border_box']);
  if(style.layout!=null)containerEnum(style.layout,['flow','flex_row']);
  if(style.align_items!=null){containerEnum(style.align_items,['stretch','start','center','end']);if(style.layout!=='flex_row')containerError();}
  if(style.flex_item!=null)containerEnum(style.flex_item,['none']);
  if(style.background!=null)containerColor(style.background);
  if(style.border!=null)containerUnion(style.border,{none:emptyContainerTag,solid:v=>{containerObject(v,['width','color'],['width','color']);containerLength(v.width);containerColor(v.color);}});
  if(style.line_height!=null)containerLineHeight(style.line_height);
  if(style.text_align!=null)containerEnum(style.text_align,['left','center','right']);
  if(style.overflow!=null)containerEnum(style.overflow,['visible','auto']);
  if(style.screen_max_width!=null)containerScreen(style.screen_max_width);
  let floating=style.float_side!=null,vertical=!!(style.margins?.top.value||style.margins?.bottom.value);
  if(!containerFonts&&!floating&&vertical)containerError();
  for(const rule of style.screen_max_width?[style.screen_max_width,...(style.screen_max_width.following_rules??[])]:[]){
    if(rule.float_side!=null)floating=rule.float_side!=='none';
    if(rule.margins!=null)vertical=!!(rule.margins.top.length?.value||rule.margins.bottom.length?.value);
    if(!containerFonts&&!floating&&vertical)containerError();
  }
}
export function validateContainerBlock(block,options){
  if(block.kind!=='container'||(block.depth??0)!==0||(block.level??0)!==0||!Array.isArray(block.spans)||block.spans.length||
    (block.path??'')!==''||(block.list_path??'')!==''||(block.number??'')!==''||(block.anchor??'')!==''||(block.anchor_fallback??'')!==''||
    ['feature','table','figure','flow','style','text_align'].some(key=>block[key]!=null))containerError();
  const value=block.container;containerObject(value,['style','blocks'],['style','blocks']);validateContainerStyle(value.style,options);
  if(!Array.isArray(value.blocks))containerError();
  for(const child of value.blocks){
    if(!child||child.kind==='heading'||child.style?.margins?.top.value||child.style?.margins?.bottom.value)containerError();
  }
}

// DPRS retains explicit base/annotation associations; no text flattening or
// annotation-offset inference is permitted at the reader boundary.
const rubyFailure=()=>{throw Error('Invalid compiled ruby');};
const rubyObject=(value,keys,required=keys)=>{
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!keys.includes(k))||required.some(k=>!Object.hasOwn(value,k)))rubyFailure();
};
const rubyArray=value=>{if(!Array.isArray(value)||value.length>1048576)rubyFailure();};
const rubyString=value=>{if(typeof value!=='string'||/[\ud800-\udfff]/u.test(value))rubyFailure();};
const rubyRGB=value=>{if(value!=null&&(typeof value!=='string'||!/^#[0-9a-f]{6}$/.test(value)))rubyFailure();};
export function validateRubyOwner(value){
  rubyObject(value,['font','direction','inline_style','foreground','background']);
  const font=value.font;const flags=['small','superscript','subscript','font_normalized','bold','italic','code'];
  rubyObject(font,['font_scale','font_scale_basis',...flags,'language','classes','role','font_features','font_family'],[...flags,'language','classes','role','font_features']);
  for(const name of flags)if(typeof font[name]!=='boolean')rubyFailure();
  for(const name of ['language','classes']){rubyString(font[name]);if(font[name].includes('\0'))rubyFailure();}
  if(!['normal','label','pronunciation','headword','example','quotation','citation','reference'].includes(font.role))rubyFailure();
  const basis=font.font_scale_basis??'context';if(!['context','normal_body','css_px'].includes(basis))rubyFailure();
  if(font.font_scale==null){if(basis!=='context'||font.font_normalized)rubyFailure();}
  else if(typeof font.font_scale!=='number'||!Number.isFinite(font.font_scale)||font.font_scale<0||font.font_scale>3.4028234663852886e38||(font.font_normalized&&basis==='context'))rubyFailure();
  if(font.font_features!=null||font.font_family!=null)throw Error('Unsupported ruby owner typography');
  if(value.inline_style!=null){
    const style=value.inline_style;rubyObject(style,['decoration','line_height','baseline_shift','font_normalized','cursor','wrap'],['decoration','line_height','baseline_shift','font_normalized','cursor']);
    if(style.decoration!=null||style.baseline_shift!=null||style.cursor!=null||style.wrap!=null)throw Error('Unsupported ruby owner inline style');
    if(typeof style.font_normalized!=='boolean'||(style.font_normalized&&!font.font_normalized))rubyFailure();
    if(style.line_height==null){if(!style.font_normalized)rubyFailure();}
    else{
      const height=style.line_height;rubyObject(height,['computed','font_relative'],[]);if(Object.keys(height).length!==1)rubyFailure();
      if(height.computed){const n=height.computed;rubyObject(n,['value','font_scale_basis']);if(!Number.isFinite(n.value)||n.value<0||!['normal_body','css_px'].includes(n.font_scale_basis))rubyFailure();}
      else{
        const n=height.font_relative;rubyObject(n,['factor','font']);if(!Number.isFinite(n.factor)||n.factor<0)rubyFailure();
        const same=(a,b)=>{const keys=new Set([...Object.keys(a),...Object.keys(b)]);return [...keys].every(k=>(a[k]??(k==='font_scale_basis'?'context':null))===(b[k]??(k==='font_scale_basis'?'context':null)));};
        if(!same(n.font,font))rubyFailure();
      }
    }
  }
  if(!['','ltr','rtl','auto'].includes(value.direction))rubyFailure();rubyRGB(value.foreground);rubyRGB(value.background);
}
export function validateRuby(value,depth=0,state={items:0}){
  if(depth>=16||++state.items>1048576)rubyFailure();rubyObject(value,['segments']);rubyArray(value.segments);if(!value.segments.length)rubyFailure();
  const children=(spans,gap=false)=>{
    rubyArray(spans);
    for(const span of spans){
      if(++state.items>1048576||!span||!['text','link','external_link'].includes(span.kind)||span.image!=null||span.audio_control!=null||span.inline_padding_group!=null||span.inline_action_group!=null||span.inline_box_group!=null||span.clipped_absolute!=null)rubyFailure();
      for(const name of ['text','target','trail','language','classes','direction','explanation'])rubyString(span[name]??'');
      if(span.kind==='text'?!!span.target:!span.target)rubyFailure();
      if((span.classes??'').split(/[ \t\r\n\f]+/).some(token=>token==='wikidict-media'||token.startsWith('wikidict-media-file-')))rubyFailure();
      if(!['','ltr','rtl','auto'].includes(span.direction??''))rubyFailure();rubyRGB(span.foreground);rubyRGB(span.background);
      if(span.target_fragment!=null){if(span.kind!=='link')rubyFailure();rubyString(span.target_fragment);}
      if(span.tooltip!=null)rubyString(span.tooltip);
      if(span.inline_style!=null||span.font_features!=null||span.font_family!=null||span.link_paint!=null)throw Error('Unsupported ruby child typography');
      if(gap){if(span.kind!=='text'||span.target_fragment!=null||span.trail||span.ruby!=null||/[^ \t\n\r\f]/u.test(span.text))rubyFailure();}
      else if(/[\t\n\r\f]/u.test((span.text??'')+(span.trail??'')))rubyFailure();
      if(span.ruby!=null){validateRubySpan(span);validateRuby(span.ruby,depth+1,state);}
    }
  };
  value.segments.forEach((segment,segmentIndex)=>{
    rubyObject(segment,['gap_before','bases','annotations']);children(segment.gap_before,true);if(segmentIndex===0&&segment.gap_before.length)rubyFailure();rubyArray(segment.bases);rubyArray(segment.annotations);if(!segment.bases.length)rubyFailure();
    segment.bases.forEach((base,index)=>{if(++state.items>1048576)rubyFailure();rubyObject(base,['owner','gap_before','spans']);validateRubyOwner(base.owner);children(base.gap_before,true);if(index===0&&base.gap_before.length)rubyFailure();children(base.spans);});
    let level=0,end=0;
    segment.annotations.forEach((annotation,index)=>{
      if(++state.items>1048576)rubyFailure();rubyObject(annotation,['base_start','base_count','level','owner','gap_before','spans','fallback_before','fallback_after','explicit_fallback']);
      for(const name of ['base_start','base_count','level'])if(!Number.isInteger(annotation[name])||annotation[name]<0||annotation[name]>0xffffffff)rubyFailure();
      if(!annotation.base_count||annotation.base_start+annotation.base_count>segment.bases.length||typeof annotation.explicit_fallback!=='boolean')rubyFailure();
      if(index===0){if(annotation.level!==0||annotation.gap_before.length)rubyFailure();}
      else if(annotation.level!==level){if(annotation.level!==level+1||annotation.gap_before.length)rubyFailure();end=0;}
      if(annotation.base_start<end)rubyFailure();level=annotation.level;end=annotation.base_start+annotation.base_count;
      validateRubyOwner(annotation.owner);children(annotation.gap_before,true);for(const name of ['spans','fallback_before','fallback_after'])children(annotation[name]);
      if(!annotation.explicit_fallback&&(annotation.fallback_before.length||annotation.fallback_after.length))rubyFailure();
    });
  });
}
export function validateRubySpan(span){
  if(span.kind!=='text'||span.text!==''||span.target!==''||(span.trail??'')!==''||span.target_fragment!=null||span.image!=null||span.inline_padding_group!=null||span.inline_action_group!=null||span.inline_box_group!=null||span.clipped_absolute!=null||span.audio_control!=null)rubyFailure();
  if(span.inline_style!=null||span.font_features!=null||span.font_family!=null||span.link_paint!=null)throw Error('Unsupported ruby root typography');
}

// An explicit owner identifies one authored action; equal URLs never identify it.
export function validateActionGroupSpan(span){
  const invalid=()=>{throw Error('Invalid compiled inline action group');};
  const string=value=>{
    if(typeof value!=='string'||/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)||new TextEncoder().encode(value).length>32*1024*1024)invalid();
  };
  const text=value=>{
    if(!value||typeof value!=='object')invalid();
    for(const key of ['text','target','trail','language','classes','direction','explanation'])string(value[key]??'');
    if(value.role!=null&&!['normal','label','pronunciation','headword','example','quotation','citation','reference'].includes(value.role))invalid();
    for(const key of ['bold','italic','code','small','superscript','subscript','strike','underline'])if(value[key]!=null&&typeof value[key]!=='boolean')invalid();
    if(/[\t\n\r\f]/u.test((value.text??'')+(value.trail??'')))invalid();
    if(!['','ltr','rtl','auto'].includes(value.direction??''))invalid();
    for(const key of ['foreground','background'])if(value[key]!=null&&!/^#[0-9a-f]{6}$/.test(value[key]))invalid();
    if((value.classes??'').split(/[ \t\r\n\f]+/).some(token=>token==='wikidict-media'||token.startsWith('wikidict-media-file-')))invalid();
    if(value.tooltip!=null)string(value.tooltip);
    const basis=value.font_scale_basis??'context',scale=value.font_scale;
    if(!['context','normal_body','css_px'].includes(basis)||(scale==null?basis!=='context':typeof scale!=='number'||!Number.isFinite(scale)||scale<0||scale>3.4028234663852886e38))invalid();
    for(const key of ['image','audio_control','inline_box_group','clipped_absolute'])if(value[key]!=null)invalid();
    if(value.font_features!=null||value.font_family!=null||value.inline_style!=null||value.link_paint!=null)throw Error('Unsupported inline action typography');
  };
  text(span);
  if(!['link','external_link'].includes(span.kind)||!span.target||span.text!==''||(span.trail??'')!==''||span.ruby!=null||span.inline_padding_group!=null||span.self_link)invalid();
  if(span.target_fragment!=null){if(span.kind!=='link')invalid();string(span.target_fragment);}
  if((span.font_scale_basis??'context')!=='context'||span.font_scale===0||span.code||span.small||span.superscript||span.subscript)throw Error('Unsupported inline action declaring font');
  const group=span.inline_action_group;
  if(!group||typeof group!=='object'||Array.isArray(group)||Object.keys(group).length!==1||!Array.isArray(group.spans)||!group.spans.length||group.spans.length>1048576)invalid();
  for(const child of group.spans){
    text(child);
    if(child.kind!=='text'||child.target!==''||child.target_fragment!=null||child.inline_action_group!=null)invalid();
    if(child.ruby!=null||child.inline_padding_group!=null)throw Error('Unsupported rich inline action child');
  }
}

const inlineBoxSides = ['top','right','bottom','left'];
const inlineBoxRgb = value => typeof value === 'string' && /^#[0-9a-f]{6}$/.test(value);

export function validateInlineBoxSpan(owner) {
  let budget=1048576;
  const invalid=()=>{throw Error('Invalid compiled inline box group');};
  const check=(accept)=>{if(!accept)invalid();};
  const length=(value,units,signed=false)=>{
    check(value && units.includes(value.unit) && Number.isFinite(value.value) &&
      Math.abs(value.value)<=3.4028234663852886e38 && (signed||value.value>=0));
  };
  const borders=value=>{
    for(const side of inlineBoxSides){
      const edge=value?.[side];check(edge&&['none','hidden','solid','dotted'].includes(edge.kind));
      if(edge.kind==='none'||edge.kind==='hidden')continue;
      length(edge.width,['px','em']);
      const color=edge.color;check(color&&['current_color','transparent','rgb','light_dark'].includes(color.kind));
      if(color.kind==='rgb')check(inlineBoxRgb(color.value));
      if(color.kind==='light_dark')check(inlineBoxRgb(color.light)&&inlineBoxRgb(color.dark));
    }
  };
  const span=(value,depth,inAction)=>{
    check(value && depth<=16 && --budget>=0 && ['text','link','external_link'].includes(value.kind));
    check(typeof value.text==='string'&&typeof value.target==='string'&&typeof (value.trail??'')==='string');
    const action=value.kind!=='text';
    check(action?!!value.target&&!inAction:value.target==='');
    if(value.target_fragment!=null){check(value.kind==='link');linkTargetParts(value.target,value.target_fragment);}
    check(!value.image&&!value.audio_control&&!value.inline_padding_group&&!value.clipped_absolute);
    check(!(value.classes??'').split(/[ \t\r\n\f]+/u).some(c=>c==='wikidict-media'||c.startsWith('wikidict-media-file-')));
    if(value.inline_action_group){validateActionGroupSpan(value);return value.inline_action_group.spans.some(child=>child.text.length||child.trail?.length);}
    const group=value.inline_box_group;
    if(!group){
      if(value.ruby!=null){check(!inAction);validateRubySpan(value);validateRuby(value.ruby);return true;}
      return value.text.length!==0||(value.trail??'').length!==0;
    }
    check(depth<16&&!value.ruby&&value.text===''&&!value.trail&&Array.isArray(group.spans)&&Array.isArray(group.overlays));
    budget-=group.overlays.length;check(budget>=0);
    for(const side of inlineBoxSides)length(group.padding?.[side],['px','em']);
    borders(group.border);
    if(group.spans.length===0){
      const top=group.border.top;
      check(depth===0&&!action&&!inAction&&value.tooltip==null&&value.inline_style==null&&!(value.explanation??'')&&
        group.overlays.length===0&&group.radius==null&&inlineBoxSides.every(side=>group.padding[side].value===0)&&
        top.kind==='solid'&&top.width.unit==='px'&&top.width.value===1&&top.color.kind==='current_color'&&
        ['left','right','bottom'].every(side=>group.border[side].kind==='none'));
      return false;
    }
    if(group.radius!=null){
      length(group.radius,['px','percent']);
      const edge=group.border.top;
      check(group.overlays.length===0&&(edge.kind==='solid'||edge.kind==='dotted')&&edge.color.kind==='rgb');
      for(const side of inlineBoxSides){const x=group.border[side];check(x.kind===edge.kind&&x.color.kind==='rgb'&&x.color.value===edge.color.value&&x.width.unit===edge.width.unit&&x.width.value===edge.width.value);}
    }
    for(const overlay of group.overlays){
      check(overlay?.insets && !overlay.content && (overlay.insets.top!=null||overlay.insets.bottom!=null) && (overlay.insets.left!=null||overlay.insets.right!=null));
      for(const side of inlineBoxSides)if(overlay.insets[side]!=null)length(overlay.insets[side],['px','em','percent'],true);
      borders(overlay.border);
    }
    let text=false;
    for(const child of group.spans){if(span(child,depth+1,inAction||action))text=true;}
    check(text);
    return text;
  };
  check(owner?.inline_box_group);
  span(owner,0,false);
}
