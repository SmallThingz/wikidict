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
export function validateContainerStyle(style){
  containerObject(style,containerKeys);
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
  if(!floating&&vertical)containerError();
  for(const rule of style.screen_max_width?[style.screen_max_width,...(style.screen_max_width.following_rules??[])]:[]){
    if(rule.float_side!=null)floating=rule.float_side!=='none';
    if(rule.margins!=null)vertical=!!(rule.margins.top.length?.value||rule.margins.bottom.length?.value);
    if(!floating&&vertical)containerError();
  }
}
export function validateContainerBlock(block){
  if(block.kind!=='container'||(block.depth??0)!==0||(block.level??0)!==0||!Array.isArray(block.spans)||block.spans.length||
    (block.path??'')!==''||(block.list_path??'')!==''||(block.number??'')!==''||(block.anchor??'')!==''||(block.anchor_fallback??'')!==''||
    ['feature','table','figure','flow','style','text_align'].some(key=>block[key]!=null))containerError();
  const value=block.container;containerObject(value,['style','blocks'],['style','blocks']);validateContainerStyle(value.style);
  if(!Array.isArray(value.blocks))containerError();
  for(const child of value.blocks){
    if(!child||child.kind==='heading'||child.style?.margins?.top.value||child.style?.margins?.bottom.value)containerError();
  }
}
