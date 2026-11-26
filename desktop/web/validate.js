import {validateFontFamily} from './font-family.js';
import {validateContainerDisclosure} from './container-disclosure.js';
const forbidden = new Set(['source','source_base64','payload_base64','unexpanded_templates','rendered_templates','expansion','deferred','content']);
const kinds = new Set(['text','link','external_link','line_break']);
export function validateFigureIntrinsicSize(figure) {
  const size=figure.intrinsic_size;
  const image=figure.image_span?.image;
  const axis=n=>Number.isInteger(n)&&n>0&&n<=0x7fffffff;
  if(!size||typeof size!=='object'||Array.isArray(size)||Object.keys(size).length!==2||
     !axis(size.width_px)||!axis(size.height_px)||figure.format!=='thumbnail'||figure.sizing!=='requested_fit'||
     !image||!axis(image.width_px)||image.width_px>size.width_px||image.height_px!=null||
     image.map!=null||image.static_poster!=null||image.svg_language!=null||!(/\.(?:jpe?g|jpe|png|gif|webp)$/i).test(image.file)||
     figure.table_caption_layout!=null||figure.block_media_layout!=null) throw Error('Invalid intrinsic raster figure');
}
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
        for(const span of child)if(span.font_family!=null)validateFontFamily(span.font_family);
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

export function validateSourceAnchor(block,sectionRoot){
 const invalid=()=>{throw Error('Invalid nonheading source anchor');};
 const {kind,anchor,anchor_fallback:fallback,spans,depth,level,number}=block;
 const path=block.list_path??block.path??'';
 if(block.path!=null&&block.list_path!=null&&block.path!==block.list_path)invalid();
 if(typeof anchor!=='string'||!anchor||fallback||anchor.length>255||/[\ud800-\udfff]/u.test(anchor)||fragmentUtf8.encode(anchor).length>255||
    !Array.isArray(spans)||['table','feature','container','figure','flow','rule_style','description_body'].some(key=>block[key]!=null))invalid();
 if(kind==='definition'){
  if(!/^[A-Za-z_\-\u0080-\u{10ffff}]+:_Q[1-9][0-9]*$/u.test(anchor)||level!==0||depth!==1||path!=='#'||
     typeof number!=='string'||!(/^[1-9][0-9]*$/u.test(number))||!spans.length)invalid();
  return;
 }
 if(kind!=='paragraph'||!sectionRoot||!/^Translations-Q[1-9][0-9]*$/u.test(anchor)||level!==0||depth!==0||
    path||number||block.text_align!=='left'||block.style!=null||block.column_break_inside!=null||spans.length!==5)invalid();
 for(const [i,span] of spans.entries()){
  if(span.kind!==(i===4?'link':'text')||span.classes!=='pseudo NavFrame NavHead'||(i!==4&&span.target)||
     !!span.italic!==(i===2)||span.trail||
     ['target_fragment','image','ruby','inline_padding_group','inline_action_group','inline_box_group','audio_control','clipped_absolute'].some(key=>span[key]!=null))invalid();
 }
 const [name,dash,see,gap,link]=spans;
 if(typeof link.target!=='string'||typeof link.text!=='string'||!link.text||link.text.includes('#')||
    link.target!==link.text+'#'+anchor||name.text!==link.text+' '||dash.text!=='— '||see.text!=='see'||gap.text!==' ')invalid();
}

export function validateSourceAnchorDestinations(entry){
 const headings=new Set(),sources=new Set();
 function heading(value){for(const id of [value.anchor,value.anchor_fallback])if(id)headings.add(id);}
 function visit(value){
  if(!value||typeof value!=='object')return;
  if(value.kind==='heading')heading(value);
  else if(['definition','paragraph'].includes(value.kind)&&value.anchor){
   if(sources.has(value.anchor))throw Error('Duplicate nonheading source anchor');
   sources.add(value.anchor);
  }
  for(const child of Object.values(value))visit(child);
 }
 for(const section of entry.sections){heading(section);visit(section.blocks);}
 visit(entry.references);
 if([...sources].some(id=>headings.has(id)))throw Error('Nonheading source anchor collides with a heading');
}

const inlineDestinationError=()=>{throw Error('Invalid inline destination');};
const inlineDestinationObjects=['image','ruby','inline_padding_group','inline_action_group','inline_box_group','audio_control','clipped_absolute'];
const inlineDestinationFlags=['bold','italic','code','small','superscript','subscript','strike','underline'];
const printableRun=value=>typeof value==='string'&&!/[^\x20-\x7e]/.test(value);
function flatDestinationRun(span){
 if(!span||!['text','link','external_link'].includes(span.kind)||
    !printableRun(span.text??'')||!printableRun(span.trail??'')||
    !['','ltr'].includes(span.direction??'')||inlineDestinationObjects.some(key=>span[key]!=null)||
    Object.hasOwn(span,'citation_marker')||(span.classes??'').split(/[ \t\r\n\f]+/).includes('wikidict-poem'))inlineDestinationError();
}
export function validateInlineDestinationList(block){
 if(!Object.hasOwn(block,'inline_destinations'))return [];
 const values=block.inline_destinations;
 if(!Array.isArray(values)||values.length>(1<<20))inlineDestinationError();
 let previous=0;
 for(const value of values){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==2||
     !Object.hasOwn(value,'id')||!Object.hasOwn(value,'before_run'))inlineDestinationError();
  const {id,before_run:index}=value;
  if(typeof id!=='string'||!id||/[\ud800-\udfff]/u.test(id)||/[\x00-\x20\x7f]/.test(id)||fragmentUtf8.encode(id).length>255||
     !Number.isInteger(index)||index<previous||index>0xffffffff||!Array.isArray(block.spans)||index>=block.spans.length)inlineDestinationError();
  const span=block.spans[index];flatDestinationRun(span);
  if(!(span.text??'').length&&!(span.trail??'').length)inlineDestinationError();
  if(inlineDestinationFlags.some(flag=>span[flag]!==undefined&&span[flag]!==false)||
     (span.role??'normal')!=='normal'||(span.classes??'')!==''||(span.language??'')!==''||
     ['font_scale','font_family','font_features','inline_style'].some(key=>span[key]!=null)||
     (span.font_scale_basis!==undefined&&span.font_scale_basis!=='context'))inlineDestinationError();
  previous=index;
 }
 return values;
}
export function validateInlineDestinationEntry(entry,owners){
 if(!owners.length)return;
 if(entry.presentation_version!=='DPRa')inlineDestinationError();
 const sections=new Map((entry.sections||[]).map(section=>[section.blocks?.[0],section]));
 const reserved=new Set(),fresh=new Set();
 const visit=value=>{
  if(!value||typeof value!=='object')return;
  for(const key of ['anchor','anchor_fallback'])if(value[key])reserved.add(value[key]);
  for(const child of Object.values(value))visit(child);
 };
 visit(entry.sections);visit(entry.references);
 for(const block of owners){
  const section=sections.get(block);
  if(!section||block.kind!=='heading'||block.level!==section.level||
     (block.anchor??'')!==(section.anchor??'')||(block.anchor_fallback??'')!==(section.anchor_fallback??'')||
     (block.depth??0)!==0||(block.path??'')!==''||(block.list_path??'')!==''||(block.number??'')!==''||
     (section.heading_style!=null&&section.heading_style.direction!=='ltr')||
     ['feature','table','figure','flow','container','description_body','rule_style','column_break_inside','style','text_align'].some(key=>block[key]!=null))inlineDestinationError();
  // V2 plain mode keeps the existing ordinary heading route. Nonnull style
  // retains every preexisting wrapped-heading constraint, including its runs.
  if(section.heading_style!=null)validateWrappedHeading(section);
  for(const span of block.spans)flatDestinationRun(span);
  if(block.spans.map(span=>(span.text??'')+(span.trail??'')).join('')!==section.title)inlineDestinationError();
  for(const value of validateInlineDestinationList(block)){
   if(reserved.has(value.id)||fresh.has(value.id))inlineDestinationError();
   fresh.add(value.id);
  }
 }
}
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
function containerLength(value,units=['px','em'],signed=false){
  containerObject(value,['unit','value'],['unit','value']);
  if(!units.includes(value.unit)||typeof value.value!=='number')containerError();
  containerNumber(signed?Math.abs(value.value):value.value);
}
const containerMarginLength=(value,signed)=>containerLength(value,['px','em'],signed);
function containerUnion(value,variants){containerObject(value,Object.keys(variants));const keys=Object.keys(value);if(keys.length!==1)containerError();variants[keys[0]](value[keys[0]]);}
const emptyContainerTag=value=>containerObject(value,[]);
const containerWidth=(value,intrinsic=false)=>containerUnion(value,{auto:emptyContainerTag,fit_content:emptyContainerTag,
  ...(intrinsic?{max_content:emptyContainerTag}:{}),length:v=>containerLength(v,['px','em','percent'])});
const containerMaxWidth=value=>containerUnion(value,{none:emptyContainerTag,length:v=>containerLength(v,['px','em','percent'])});
const containerLineHeight=value=>containerUnion(value,{normal:emptyContainerTag,multiplier:containerNumber,length:containerLength});
const containerMargin=(value,signed)=>containerUnion(value,{auto:emptyContainerTag,length:length=>containerMarginLength(length,signed)});
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

// Global25's distinct caption owner. These checks do not widen legacy cell,
// ruby, wrapped-heading, viewport or disclosure grammars.
export function validateResponsiveCaptionTable(table){
  if(table.caption_viewport==null)return;
  const fail=()=>{throw Error('Invalid responsive caption table');};
  const object=(v,keys,required=[])=>{
    if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!keys.includes(k))||required.some(k=>!Object.hasOwn(v,k)))fail();
  };
  const num=(v,positive=false)=>{if(typeof v!=='number'||!Number.isFinite(v)||v>3.4028234663852886e38||(positive?v<=0:v<0))fail();};
  const text=(v,max=1024)=>{if(typeof v!=='string'||/[\ud800-\udfff]/u.test(v)||new TextEncoder().encode(v).length>max)fail();};
  const length=(v,units=['px','em'],positive=false)=>{object(v,['unit','value'],['unit','value']);if(!units.includes(v.unit))fail();num(v.value,positive);};
  const edges=v=>{object(v,sides,sides);for(const s of sides)length(v[s]);};
  const rgb=v=>{if(typeof v!=='string'||!/^#[0-9a-f]{6}$/.test(v))fail();};
  const borderLine=(v,physical=false)=>{
    object(v,physical?['none','hidden','solid','dotted']:['none','solid']);
    const keys=Object.keys(v);if(keys.length!==1)fail();const k=keys[0];
    if(k==='none'||k==='hidden')object(v[k],[]);
    else{object(v[k],['width','color'],['width','color']);length(v[k].width);rgb(v[k].color);}
  };
  const border=v=>{
    if(v&&Object.hasOwn(v,'edges')){object(v,['edges'],['edges']);object(v.edges,sides,sides);for(const s of sides)borderLine(v.edges[s],true);}
    else borderLine(v);
  };
  const computed=v=>{object(v,['value','font_scale_basis'],['value','font_scale_basis']);num(v.value,true);if(v.font_scale_basis!=='normal_body')fail();};
  const style=(v,allowed,required)=>{
    object(v,allowed,required);
    for(const key of required)if(v[key]==null)fail();
    if(v.background!=null)rgb(v.background);if(v.border!=null)border(v.border);
    if(v.margins!=null)edges(v.margins);if(v.padding!=null)edges(v.padding);
    if(v.width!=null)length(v.width,['px','em','percent']);
    if(v.line_height!=null)computed(v.line_height);
  };
  for(const k of ['geometry','block_viewport','float_viewport','rows_hidden_max_width_px','disclosure'])if(table[k]!=null)fail();
  const p=table.caption_viewport;
  const fields=['max_viewport_width_px','narrow_box_style','narrow_grid_style','max_width','grid_spacing_x','grid_spacing_y','caption_box','containing_direction','grid_direction','language'];
  object(p,[...fields,'focus_paint'],fields);
  if(!Number.isInteger(p.max_viewport_width_px)||p.max_viewport_width_px<=0||p.max_viewport_width_px>0xffffffff)fail();
  length(p.max_width,['px'],true);length(p.grid_spacing_x,['px']);length(p.grid_spacing_y,['px']);
  for(const k of ['containing_direction','grid_direction'])if(!['ltr','rtl'].includes(p[k]))fail();
  text(p.language);if(!p.language.length)fail();
  const wide=table.style,box=p.narrow_box_style,grid=p.narrow_grid_style;
  style(wide,['background','border','collapse','margins','float_side','width','padding','clear','line_height'],['collapse','margins','float_side','width','padding','clear','line_height']);
  style(box,['background','border','margins','float_side','width','padding','clear'],['margins','float_side','width','padding','clear']);
  style(grid,['collapse','line_height'],['collapse','line_height']);
  if(wide.float_side!=='right'||box.float_side!=='right'||wide.clear!=='right'||box.clear!=='right'||wide.collapse!=='separate'||grid.collapse!=='separate'||
     wide.width.unit!=='em'||wide.width.value<=0||box.width.unit!=='percent'||box.width.value!==100||wide.line_height.value!==grid.line_height.value)fail();
  const caption=p.caption_box;object(caption,['margins','padding','line','text_align'],['margins','padding','line','text_align']);
  edges(caption.margins);edges(caption.padding);if(!['left','center','right'].includes(caption.text_align))fail();
  const line=caption.line;object(line,['strut','height'],['strut','height']);
  object(line.height,['length'],['length']);computed(line.height.length);
  const strut=line.strut;object(strut,['font_scale','font_scale_basis','owner_font'],['font_scale','font_scale_basis','owner_font']);
  num(strut.font_scale,true);if(strut.font_scale_basis!=='normal_body')fail();
  const f=strut.owner_font,flags=['small','superscript','subscript','font_normalized','bold','italic','code'];
  const ff=['font_scale','font_scale_basis',...flags,'language','classes','role','font_features','font_family'];
  object(f,ff,ff);for(const k of flags)if(typeof f[k]!=='boolean')fail();
  if(f.small||f.superscript||f.subscript||f.font_normalized||f.code||f.classes!==''||f.role!=='normal'||f.font_scale!==strut.font_scale||f.font_scale_basis!==strut.font_scale_basis)fail();
  text(f.language);if(!f.language.length||f.language.includes('\0')||!['normal','seven_on'].includes(f.font_features))fail();
  validateFontFamily(f.font_family);
  if(p.focus_paint!=null){
    const focus=p.focus_paint;object(focus,['mode','color'],['mode']);
    if(!['authored_none','ua_auto'].includes(focus.mode))fail();
    if(focus.color!=null){
      if(focus.mode!=='ua_auto')fail();const c=focus.color;object(c,['kind','value'],['kind']);
      if(c.kind==='rgb')rgb(c.value);else if(!['native_theme','transparent'].includes(c.kind)||c.value!=null)fail();
    }
  }
  if(!Array.isArray(table.caption)||!Array.isArray(table.rows)||!table.rows.some(r=>Array.isArray(r.cells)&&r.cells.length))fail();
  if(table.caption_blocks!=null){if(!Array.isArray(table.caption_blocks)||!table.caption_blocks.length||table.caption.length)fail();}
  else if(!table.caption.length)fail();
}
function containerScreen(value,following=false,signed=false){
  const fields=['width','max_width','box_sizing','line_height','float_side','margins','clear','layout'];
  containerObject(value,['max_width_px',...fields,'following_rules'],['max_width_px']);
  if(!Number.isInteger(value.max_width_px)||value.max_width_px<0||value.max_width_px>0xffffffff||!fields.some(key=>value[key]!=null))containerError();
  if(value.width!=null)containerWidth(value.width);if(value.max_width!=null)containerMaxWidth(value.max_width);
  if(value.box_sizing!=null)containerEnum(value.box_sizing,['content_box','border_box']);
  if(value.line_height!=null)containerLineHeight(value.line_height);
  if(value.float_side!=null)containerEnum(value.float_side,['none','left','right']);
  if(value.margins!=null)containerEdges(value.margins,margin=>containerMargin(margin,signed));
  if(value.clear!=null)containerEnum(value.clear,['none','left','right','both']);
  if(value.layout!=null)containerEnum(value.layout,['flow']);
  const rest=value.following_rules??[];
  if(!Array.isArray(rest)||rest.length>=16||(following&&rest.length))containerError();
  let limit=value.max_width_px;
  for(const rule of rest){containerScreen(rule,true,signed);if(rule.max_width_px>=limit)containerError();limit=rule.max_width_px;}
}
function orderedBox(style,root){
  containerObject(style,['margins','padding','line_height','owner_font_scale',...(root?['layout','ordered_marker_weight']:[])],['margins','padding']);
}
const responsiveFlow=style=>[style.screen_max_width,...(style.screen_max_width?.following_rules??[])]
  .some(rule=>rule?.layout!=null);

const onlyContainerStyle=(style,keys)=>{if(Object.keys(style).some(key=>!keys.includes(key)))containerError();};
function validatePositionedContainerStyle(style){
  if(style.layout==='flex_column'){
    onlyContainerStyle(style,['layout','align_items','width','padding','margin_values','owner_font','owner_font_scale']);
    if(style.align_items!=='center'||(style.width&&!style.width.fit_content)||Object.values(style.margin_values??{}).some(edge=>!edge.auto))containerError();
  }
  if(style.width?.max_content){
    onlyContainerStyle(style,['width','max_width','overflow','box_sizing','margins','padding','border','background','text_align','line_height','owner_font_scale','owner_font']);
    if(style.max_width?.length?.unit!=='percent'||style.max_width.length.value!==100||style.overflow!=='hidden'||style.box_sizing!=='border_box')containerError();
  }
  if(style.owner_font!=null){
    const font=style.owner_font;
    validateFontSnapshot(font);
    if(font.small||font.superscript||font.subscript)containerError();
  }
  if(style.positioning!=null)containerEnum(style.positioning,['relative_auto']);
  if(style.min_height!=null)containerLength(style.min_height);
  if(style.margin_values!=null){
    if(style.margins!=null)containerError();
    containerEdges(style.margin_values,edge=>containerMargin(edge,true));
  }
  if(style.inline_atomic!=null){
    onlyContainerStyle(style,['inline_atomic','owner_font']);
    if(!style.owner_font)containerError();
    containerEnum(style.inline_atomic,['adjacent','after_space']);
  }
  if(style.corner_radius_px!=null)containerNumber(style.corner_radius_px);
  if(style.translated_absolute!=null){
    onlyContainerStyle(style,['translated_absolute','corner_radius_px','owner_font','width','height','line_height','background','padding']);
    const value=style.translated_absolute, axes=['left','top','translate_x','translate_y'];
    containerObject(value,['placement','z_index','background_alpha','owns_abbreviation'],['placement','z_index','background_alpha','owns_abbreviation']);
    containerObject(value.placement,axes,axes);
    for(const axis of axes){
      const offset=value.placement[axis];containerObject(offset,['px','percent'],['px','percent']);
      if(!Number.isFinite(offset.px)||!Number.isFinite(offset.percent))containerError();
    }
    if(value.z_index!=null&&(!Number.isInteger(value.z_index)||value.z_index<0||value.z_index>2147483647))containerError();
    if(!Number.isFinite(value.background_alpha)||value.background_alpha<0||value.background_alpha>1||typeof value.owns_abbreviation!=='boolean' ||
       style.corner_radius_px==null||!style.owner_font||style.line_height?.length?.unit!=='px'||!style.width?.fit_content||!style.background?.rgb||
       (style.height!=null&&style.height.unit!=='px')||Object.values(style.padding??{}).some(edge=>edge.unit!=='px'))containerError();
  }else if(style.corner_radius_px!=null){
    onlyContainerStyle(style,['corner_radius_px','positioning','owner_font','text_align','padding','background','border']);
    if(style.positioning!=='relative_auto'||style.text_align!=='center'||!style.owner_font||!style.background?.rgb||
       style.border?.solid?.width?.unit!=='px'||!style.border.solid.color?.rgb||!style.padding||Object.values(style.padding).some(edge=>edge.unit!=='px'))containerError();
  }
}
export function validateContainerStyle(style,{containerFonts=false,positioned=false}={}){
  const keys=[...containerKeys];
  if(containerFonts)keys.push('owner_font_scale','height','columns');
  if(positioned)keys.push('ordered_marker_weight','positioning','min_height','margin_values','owner_font','translated_absolute','corner_radius_px','inline_atomic');
  containerObject(style,keys);
  if(positioned)validatePositionedContainerStyle(style);
  if(style.owner_font_scale!=null)containerNumber(style.owner_font_scale);
  if(style.height!=null)containerLength(style.height);
  if(style.columns!=null){
    containerObject(style.columns,['count','gap'],['count','gap']);
    if(!Number.isInteger(style.columns.count)||style.columns.count<1||style.columns.count>65535)containerError();
    containerLength(style.columns.gap);
    if(style.height!=null||style.min_height!=null||style.layout==='flex_row'||style.overflow==='auto'||style.overflow==='hidden'||style.positioning!=null||style.absolute_position!=null)containerError();
  }
  if(style.margins!=null)containerEdges(style.margins,length=>containerMarginLength(length,containerFonts));
  if(style.padding!=null)containerEdges(style.padding);
  if(style.width!=null)containerWidth(style.width,positioned);if(style.max_width!=null)containerMaxWidth(style.max_width);
  if(style.float_side!=null)containerEnum(style.float_side,['left','right']);
  if(style.clear!=null)containerEnum(style.clear,['none','left','right','both']);
  if(style.box_sizing!=null)containerEnum(style.box_sizing,['content_box','border_box']);
  if(style.layout!=null)containerEnum(style.layout,positioned?['flow','flex_row','flex_column','ordered_list']:['flow','flex_row']);
  if(style.align_items!=null){containerEnum(style.align_items,['stretch','start','center','end']);if(!['flex_row','flex_column'].includes(style.layout))containerError();}
  if(style.layout==='ordered_list'){
    orderedBox(style,true);
    containerEnum(style.ordered_marker_weight,['normal','bold']);
  }else if(style.ordered_marker_weight!=null)containerError();
  if(style.flex_item!=null)containerEnum(style.flex_item,['none']);
  if(style.background!=null)containerColor(style.background);
  if(style.border!=null){
    const line=value=>{containerObject(value,['width','color'],['width','color']);containerLength(value.width);containerColor(value.color);};
    const kinds={none:emptyContainerTag,solid:line};
    if(containerFonts)kinds.edges=value=>containerEdges(value,edge=>containerUnion(edge,{none:emptyContainerTag,hidden:emptyContainerTag,solid:line,dotted:line}));
    containerUnion(style.border,kinds);
  }
  if(style.line_height!=null)containerLineHeight(style.line_height);
  if(style.text_align!=null)containerEnum(style.text_align,['left','center','right']);
  if(style.overflow!=null)containerEnum(style.overflow,positioned?['visible','auto','hidden']:['visible','auto']);
  if(style.screen_max_width!=null)containerScreen(style.screen_max_width,false,containerFonts);
  if(responsiveFlow(style)&&(style.layout!=='flex_row'||style.align_items!=null||style.columns!=null))containerError();
  let floating=style.float_side!=null,vertical=!!(style.margins?.top.value||style.margins?.bottom.value);
  if(!containerFonts&&!floating&&vertical)containerError();
  for(const rule of style.screen_max_width?[style.screen_max_width,...(style.screen_max_width.following_rules??[])]:[]){
    if(rule.float_side!=null)floating=rule.float_side!=='none';
    if(rule.margins!=null)vertical=!!(rule.margins.top.length?.value||rule.margins.bottom.length?.value);
    if(!containerFonts&&!floating&&vertical)containerError();
  }
}
export function validateDarkForeground(span){
  const dark=span.inline_style?.dark_foreground;
  if(dark==null)return;
  if(span.kind!=='text'||!span.text||span.target||span.image||span.ruby||span.inline_padding_group||
    span.inline_action_group||span.inline_box_group||span.clipped_absolute||dark===span.foreground)
    throw Error('Invalid paired foreground owner');
  containerRGB(span.foreground);
  containerRGB(dark);
}

export function validateDescriptionBody(block){
  const path=block.path??block.list_path;
  if(!((block.kind==='example'&&path==='#:')||(block.kind==='indent'&&path===':'))||
    path.length!==block.depth||(block.level??0)!==0||block.number||block.anchor||block.anchor_fallback||
    !Array.isArray(block.spans)||block.spans.length||
    ['feature','table','container','figure','flow','rule_style','style','text_align','column_break_inside'].some(k=>block[k]!=null))
    throw Error('Invalid description body owner');
  const {before,box}=block.description_body;
  containerObject(block.description_body,['before','box'],['before','box']);
  containerObject(before,['top','bottom','left','width','fill'],['top','bottom','left','width','fill']);
  for(const key of ['top','bottom','left','width'])containerLength(before[key]);
  containerColor(before.fill);
  if(!before.width.value||before.fill.transparent)containerError();
  containerObject(box,['style','blocks','disclosure'],['style','blocks']);
  if(box.disclosure!=null||!Array.isArray(box.blocks)||!box.blocks.length)containerError();
  const style=box.style;
  containerObject(style,['positioning','margins','padding','owner_font_scale','line_height'],['positioning','margins','padding','owner_font_scale']);
  containerNumber(style.owner_font_scale);
  containerEdges(style.padding);containerEdges(style.margins);
  if(style.positioning!=='relative_auto'||sides.some(side=>style.margins[side].value!==0)||
    ['top','right','bottom'].some(side=>style.padding[side].value!==0)||style.padding.left.value<=0)containerError();
  for(const child of box.blocks)if(!child||child.kind==='heading'||child.style?.margins?.top.value||child.style?.margins?.bottom.value)containerError();
  if(style.line_height!=null){
    containerLineHeight(style.line_height);
    const [line]=box.blocks;
    if(!style.line_height.multiplier||block.kind!=='indent'||box.blocks.length!==1||line.kind!=='paragraph'||line.spans?.length!==2)containerError();
    const [button,credit]=line.spans;
    const strut=credit?.inline_style?.line_height?.font_relative;
    if(button?.kind!=='link'||button.audio_control?.presentation!=='phonos_button'||credit?.kind!=='link'||credit.audio_control!=null||
       !credit.superscript||!strut?.font?.superscript||!Number.isFinite(strut.factor)||strut.factor<=0)containerError();
  }
}


function validPositionedText(span){
  return span&&['text','link'].includes(span.kind)&&!!span.text&&((span.kind==='link')===!!span.target)&&
    ['image','ruby','inline_padding_group','inline_action_group','inline_box_group','clipped_absolute','audio_control','citation_marker'].every(key=>span[key]==null);
}
function validatePositionedContainer(value,parent){
  const {style,blocks}=value, shape=style.translated_absolute;
  const relative=style=>style?.positioning==='relative_auto'&&style.corner_radius_px!=null;
  if(style.inline_atomic||shape){
    const first=blocks[0],spans=first?.spans;
    if(first?.kind!=='paragraph'||!Array.isArray(spans)||!spans.length||!spans.every(validPositionedText))containerError();
    if(style.inline_atomic){
      if(!relative(parent)||blocks.length!==1)containerError();
    }else if(shape.owns_abbreviation){
      if(parent?.translated_absolute?.owns_abbreviation!==false||blocks.length!==1||spans.length!==1||
         spans[0].kind!=='text'||!spans[0].explanation||spans[0].tooltip!=null||spans[0].trail)containerError();
    }else{
      if(!relative(parent)||blocks.length>2||spans.some(span=>span.kind!=='link'||span.target!==spans[0].target||
        (span.target_fragment??null)!==(spans[0].target_fragment??null)||span.trail)||
        (blocks.length===2&&blocks[1]?.container?.style?.translated_absolute?.owns_abbreviation!==true))containerError();
    }
  }
  if(relative(style)){
    if(!blocks.length)containerError();
    blocks.forEach((block,index)=>{
      const child=block.container?.style;
      if(block.kind!=='container'||!child)containerError();
      if(child.inline_atomic){if(index===0&&child.inline_atomic==='after_space')containerError();}
      else if(index===0||index!==blocks.length-1||child.translated_absolute?.owns_abbreviation!==false)containerError();
    });
  }
}
export function validateContainerBlock(block,options){
  if(block.kind!=='container'||(block.depth??0)!==0||(block.level??0)!==0||!Array.isArray(block.spans)||block.spans.length||
    (block.path??'')!==''||(block.list_path??'')!==''||(block.number??'')!==''||(block.anchor??'')!==''||(block.anchor_fallback??'')!==''||
    ['feature','table','figure','flow','style','text_align'].some(key=>block[key]!=null))containerError();
  const value=block.container;containerObject(value,['style','blocks','disclosure'],['style','blocks']);validateContainerStyle(value.style,options);
  if(!Array.isArray(value.blocks))containerError();
  const {style,blocks}=value;
  if(value.disclosure!=null){
    // Wire capability checks belong to the DPRa decoder; typed rendering opts in explicitly.
    if(options?.containerDisclosureButtons!==true)containerError();
    if(style.layout!=null&&style.layout!=='flow')containerError();
    validateContainerDisclosure(value);
  }
  if(options?.positioned)validatePositionedContainer(value,options.parentStyle);
  if(responsiveFlow(style)){
    const direct=blocks[0],child=direct?.container?.style;
    if(blocks.length!==1||direct?.kind!=='container'||direct.description_body!=null||!child||child.flex_item!=null)containerError();
  }
  if(style.layout==='ordered_list'){
    if(!blocks.length)containerError();
    for(const [index,item] of blocks.entries()){
      if(item?.kind!=='container'||!Array.isArray(item.container?.blocks)||!item.container.blocks.length)containerError();
      orderedBox(item.container.style,false);
      const [head,...details]=item.container.blocks;
      if(!['definition','list_item'].includes(head.kind)||head.depth!==1||(head.path??head.list_path)!=='#'||head.number!==String(index+1))containerError();
      for(const child of details)if(child.kind!=='example'||child.depth!==2||(child.path??child.list_path)!=='#:'||child.number)containerError();
    }
  }
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
function validateFontSnapshot(font){
  const flags=['small','superscript','subscript','font_normalized','bold','italic','code'];
  rubyObject(font,['font_scale','font_scale_basis',...flags,'language','classes','role','font_features','font_family'],[...flags,'language','classes','role','font_features']);
  for(const name of flags)if(typeof font[name]!=='boolean')rubyFailure();
  for(const name of ['language','classes']){rubyString(font[name]);if(font[name].includes('\0'))rubyFailure();}
  if(!['normal','label','pronunciation','headword','example','quotation','citation','reference'].includes(font.role))rubyFailure();
  const basis=font.font_scale_basis??'context';if(!['context','normal_body','css_px'].includes(basis))rubyFailure();
  if(font.font_scale==null){if(basis!=='context'||font.font_normalized)rubyFailure();}
  else if(typeof font.font_scale!=='number'||!Number.isFinite(font.font_scale)||font.font_scale<0||font.font_scale>3.4028234663852886e38||(font.font_normalized&&basis==='context'))rubyFailure();
  if(font.font_features!=null||font.font_family!=null)throw Error('Unsupported ruby owner typography');
}
export function validateRubyOwner(value){
  rubyObject(value,['font','direction','inline_style','foreground','background']);
  const font=value.font;validateFontSnapshot(font);
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
  const atomicFont=value=>[
    value.font_scale,value.font_scale_basis,value.font_features??null,value.font_family??null,
    !!value.bold,!!value.italic,!!value.code,!!value.small,!!value.superscript,!!value.subscript,
    value.language??'',value.classes??'',value.role??'normal'
  ];
  const sameFields=(a,b)=>a.every((item,index)=>item===b[index]);
  const sameAtomicHeight=(first,second)=>{
    if(first==null||second==null)return first==null&&second==null;
    if(first.computed)return second.computed!=null&&
      first.computed.value===second.computed.value&&
      first.computed.font_scale_basis===second.computed.font_scale_basis;
    return first.font_relative!=null&&second.font_relative!=null&&
      first.font_relative.factor===second.font_relative.factor&&
      first.font_relative.font.font_normalized===second.font_relative.font.font_normalized&&
      sameFields(atomicFont(first.font_relative.font),atomicFont(second.font_relative.font));
  };
  const atomicStyle=(value,atomic)=>{
    const style=value.inline_style;
    check(value.kind==='text'&&!value.target&&value.target_fragment==null&&!value.link_paint&&
      !value.small&&!value.superscript&&!value.subscript&&!value.underline&&!value.strike&&
      value.citation_marker==null&&!value.audio_control&&
      [null,'normal','seven_on'].includes(value.font_features??null)&&
      [null,'sans_serif'].includes(value.font_family??null)&&
      typeof value.font_scale==='number'&&Number.isFinite(value.font_scale)&&value.font_scale>0&&
      ['normal_body','css_px'].includes(value.font_scale_basis)&&style?.font_normalized===true&&
      !style.decoration&&!style.baseline_shift&&!style.cursor&&(!style.wrap||style.wrap===atomic.wrap));
    if(style.line_height!=null)check(sameAtomicHeight(style.line_height,atomic.line_height));
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
    const atomic=group.atomic_layout;
    if(atomic!=null){
      check(depth===0&&!action&&!inAction&&group.radius==null&&group.overlays.length===0&&--budget>=0);
      check(group.atomic_auto_layout==null&&group.intrinsic_lines_layout==null&&group.vertical_align==null);
      const geometryKeys=['width','height','margins','box_sizing','text_align','wrap'];
      containerObject(atomic,[...geometryKeys,'line_height'],geometryKeys);
      length(atomic.width,['px','em']);length(atomic.height,['px','em']);
      check(atomic.width.value>0&&atomic.height.value>0&&['content_box','border_box'].includes(atomic.box_sizing)&&
        ['start','left','center','right'].includes(atomic.text_align)&&['normal','break_word'].includes(atomic.wrap));
      for(const side of inlineBoxSides)length(atomic.margins?.[side],['px','em']);
      atomicStyle(value,atomic);
      const direction=value.direction??'';
      check(['','ltr','rtl'].includes(direction));
      const height=atomic.line_height;
      if(height!=null){
        containerObject(height,['computed','font_relative'],[]);
        check(Object.keys(height).length===1);
        if(height.computed){
          containerObject(height.computed,['value','font_scale_basis'],['value','font_scale_basis']);
          check(Number.isFinite(height.computed.value)&&height.computed.value>=0&&
            ['normal_body','css_px'].includes(height.computed.font_scale_basis));
        }else{
          const item=height.font_relative;
          containerObject(item,['factor','font'],['factor','font']);
          // Reuse the snapshot validator while allowing the fixed atom's font policies.
          validateFontSnapshot({...item.font,font_features:null,font_family:null});
          check(item?.font?.font_normalized===true&&Number.isFinite(item.factor)&&item.factor>=0&&
            sameFields(atomicFont(value),atomicFont(item.font)));
        }
      }
      check(group.spans.some(child=>/[^ ]/u.test(child.text??'')));
      for(const child of group.spans){
        check(child&&typeof child.text==='string'&&!!child.text&&!child.trail&&!/[\x00-\x1f\x7f\u2028\u2029]/u.test(child.text)&&
          !child.inline_box_group&&!child.inline_action_group&&!child.inline_padding_group&&!child.ruby&&
          !child.clipped_absolute&&!child.image&&!child.audio_control&&child.citation_marker==null&&
          (child.direction??'')===direction&&sameFields(atomicFont(value),atomicFont(child)));
        atomicStyle(child,atomic);
      }
    }
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

export function validateAudioControl(span,media) {
  const invalid=()=>{throw Error('Invalid compiled audio control');};
  const control=span.audio_control;
  containerObject(control,['presentation','width','height','focus']);
  const compact=control.presentation==='phonos_button';
  if(control.presentation!==undefined&&!compact&&control.presentation!=='transport')invalid();
  if(compact&&(!span.text?.length||!span.tooltip?.length||control.width!=null||control.height!=null))invalid();
  for(const [axis,units] of [['width',['px','em','percent']],['height',['px','em']]]){
    if(control[axis]!=null){
      containerLength(control[axis],units);
      if(control[axis].value<=0)invalid();
    }
  }
  if(control.focus!=null){
    const {mode,color}=control.focus;
    containerObject(control.focus,['mode','color'],['mode']);
    if(!['authored_none','ua_auto'].includes(mode))invalid();
    if(color!=null){
      containerObject(color,['kind','value'],['kind']);
      if(mode!=='ua_auto'||(color.kind==='rgb'?!/^#[0-9a-f]{6}$/.test(color.value):color.kind!=='transparent'||color.value!=null))invalid();
    }
  }
  if(span.kind!=='link'||typeof span.target!=='string'||!span.target.startsWith('File:')||
     span.target.length===5||(span.trail??'')!==''||
     ['image','target_fragment','ruby','inline_padding_group','inline_action_group','inline_box_group','clipped_absolute','link_paint'].some(key=>span[key]!=null))invalid();
  const file=span.target.slice(5),tokens=(span.classes||'').split(/[ \t\r\n\v\f]+/);
  const prefix='wikidict-media-file-',owners=tokens.filter(token=>token.startsWith(prefix));
  if(!tokens.includes('wikidict-media')||owners.length!==1||media.get(file)!=='audio')invalid();
  const utf8=new TextEncoder().encode(file),hex=owners[0].slice(prefix.length);
  if(hex.length!==utf8.length*2)invalid();
  for(let i=0;i<utf8.length;i++)if(hex.slice(i*2,i*2+2)!==utf8[i].toString(16).padStart(2,'0'))invalid();
}

export function validateWrappedHeading(section){
  const invalid=()=>{throw Error('Invalid positioned heading companion');};
  const only=(value,keys)=>containerObject(value,keys,keys);
  const sides=['top','right','bottom','left'];
  const {heading_style:style,blocks,level,title}=section;
  only(style,['box','font','direction','wrappers']);
  const {box,font,wrappers}=style;
  only(box,['margins','padding','clear','border','line_height','owner_font_scale','positioning','font_family']);
  const lengths=(edges,top)=>{
    only(edges,sides);
    for(const side of sides){
      const edge=edges[side];
      containerLength(edge);
      if(side==='top'&&top){if(edge.unit!=='em'||edge.value<=0)invalid();}
      else if(edge.value!==0)invalid();
    }
  };
  lengths(box.margins,false);
  lengths(box.padding,false);
  only(box.border,['none']);only(box.border.none,[]);
  only(box.line_height,['multiplier']);
  containerNumber(box.line_height.multiplier);
  containerNumber(box.owner_font_scale);
  if(!['none','both','left','right'].includes(box.clear)||box.positioning!=='relative_auto'||box.font_family!=='sans_serif')invalid();
  for(const flag of ['small','superscript','subscript','font_normalized','bold','italic','code'])if(typeof font[flag]!=='boolean')invalid();
  if(font.font_scale!==box.owner_font_scale||font.font_scale_basis!=='normal_body'||font.font_family!=='sans_serif'||
     typeof font.language!=='string'||!font.language.length||new TextEncoder().encode(font.language).length>1024||font.language.includes('\0')||
     font.role!=='normal'||font.classes!==''||font.small||font.superscript||font.subscript||font.code||font.font_normalized||font.font_features!=null||
     !['ltr','rtl'].includes(style.direction))invalid();
  only(wrappers,['outer','inner','title_block_padding_right']);
  const {outer,inner,title_block_padding_right:pad}=wrappers;
  only(outer,['margins','overflow','border']);only(inner,['padding']);
  lengths(outer.margins,true);lengths(inner.padding,true);
  containerLength(pad,['em']);
  if(pad.value<=0||outer.overflow!=='visible_x_clip_y')invalid();
  only(outer.border,['edges']);only(outer.border.edges,sides);
  only(outer.border.edges.top,['dashed']);
  const stroke=outer.border.edges.top.dashed;
  only(stroke,['width','color']);containerLength(stroke.width,['px']);containerColor(stroke.color);
  if(stroke.width.value<=0||stroke.color.transparent)invalid();
  for(const side of sides.slice(1)){only(outer.border.edges[side],['none']);only(outer.border.edges[side].none,[]);}
  const first=blocks?.[0];
  if(!first||level<1||level>6||!title||first.kind!=='heading'||first.level!==level||first.depth!==0||
     (first.path??'')!==''||(first.number??'')!==''||first.anchor!==section.anchor||first.anchor_fallback!==section.anchor_fallback||
     ['feature','table','flow','figure','container','style','rule_style','text_align'].some(key=>first[key]!=null)||
     first.spans.some(span=>span.kind!=='text'||span.image||span.ruby||span.inline_action_group||span.inline_box_group||span.audio_control)||
     first.spans.map(span=>span.text+(span.trail||'')).join('')!==title)invalid();
}

export function validateTableDisclosure(table){
  const policy=table.disclosure,invalid=()=>{throw Error('Invalid compiled table disclosure');};
  const fields=['header_row','header_cell','initially_collapsed','expand_label','collapse_label','category','row_modes'];
  if(!policy||typeof policy!=='object'||Array.isArray(policy)||Object.keys(policy).length!==fields.length||
     fields.some(key=>!Object.hasOwn(policy,key)))invalid();
  if(!Array.isArray(table.rows)||!Array.isArray(policy.row_modes)||policy.row_modes.length!==table.rows.length||
     typeof policy.initially_collapsed!=='boolean'||
     !Number.isInteger(policy.header_row)||policy.header_row<0||policy.header_row>=table.rows.length||
     !Number.isInteger(policy.header_cell)||policy.header_cell<0||table.rows[policy.header_row]?.cells?.[policy.header_cell]?.header!==true||
     policy.row_modes[policy.header_row]!=='always'||policy.row_modes.every(mode=>mode==='always')||
     policy.row_modes.some(mode=>!['always','collapsed','expanded'].includes(mode)))invalid();
  for(const label of [policy.expand_label,policy.collapse_label,policy.category]){
    if(typeof label!=='string'||!label.length||/[\x00-\x1f\x7f\ud800-\udfff]/u.test(label)||
       new TextEncoder().encode(label).length>32*1024*1024)invalid();
  }
  if(table.rows_hidden_max_width_px!=null||table.block_viewport!=null||table.float_viewport!=null||
     ['inline_table','inline_block'].includes(table.style?.display))invalid();
}

export function validateClippedSpan(span) {
  const fail=()=>{throw Error('Invalid compiled clipped absolute inline');};
  const value=span.clipped_absolute;
  containerObject(value,['static_parent_direction','containing_block','width','height','margin','children'],['static_parent_direction','width','height','margin','children']);
  if(value.containing_block!==undefined&&!['initial','article_exterior'].includes(value.containing_block))fail();
  if(!['ltr','rtl'].includes(value.static_parent_direction)||
     (span.direction&&span.direction!==value.static_parent_direction)||span.text!==''||(span.trail??'')!=='')fail();
  const plain=s=>{
    if(!['text','link','external_link'].includes(s.kind)||(s.kind==='text'?!!s.target:!s.target))fail();
    for(const key of ['text','target','trail','language','classes','direction','explanation','tooltip','target_fragment'])
      if(s[key]!=null)rubyString(s[key]);
    if(s.target_fragment!=null&&s.kind!=='link')fail();
    if((s.classes??'').split(/[ \t\r\n\f]+/).some(c=>c==='wikidict-media'||c.startsWith('wikidict-media-file-')))fail();
    if(!['','ltr','rtl','auto'].includes(s.direction??''))fail();
    for(const key of ['image','audio_control','ruby','inline_padding_group','inline_action_group','inline_box_group','citation_marker'])
      if(s[key]!=null)fail();
  };
  plain(span);
  containerLength(value.width);containerLength(value.height);
  containerObject(value.margin,sides,sides);
  for(const side of sides){
    const unit=value.margin[side];
    containerObject(unit,['length'],['length']);
    containerObject(unit.length,['unit','value'],['unit','value']);
    if(!['px','em'].includes(unit.length.unit)||!Number.isFinite(unit.length.value)||Math.abs(unit.length.value)>3.4028234663852886e38)fail();
  }
  if(!Array.isArray(value.children)||!value.children.length||value.children.length>1048576)fail();
  let body=false;
  for(const child of value.children){
    plain(child);
    if(child.clipped_absolute!=null||/[\t\n\r\f]/u.test((child.text||'')+(child.trail||'')))fail();
    if(span.kind!=='text'&&(child.kind!=='text'||child.target))fail();
    if(child.text||child.trail)body=true;
  }
  if(!body)fail();
}
