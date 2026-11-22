// WIKBLB08 contains compiled semantic pages or typed DAL1 redirect envelopes.
// A leading U+FEFF belongs to a compiled title or field, not a file BOM.
import {validateContainerBlock,validateCellMetrics,validateRuby,validateRubyOwner,validateRubySpan} from './validate.js';
const utf8 = new TextDecoder('utf-8', {fatal:true,ignoreBOM:true});
const kinds = ['language','thesaurus','citations','reconstruction','rhymes','sign_gloss','supplemental','alias'];
const blocks = ['paragraph','blank','definition','example','quotation','list_item','list_detail','indent','term','heading','preformatted','rule','table','container'];
const validInlineImageFile=value=>typeof value==='string'&&value.length>0&&new TextEncoder().encode(value).length<=32*1024*1024&&!value.startsWith(' ')&&!value.endsWith(' ')&&!/[_\[\]{}<>|#\x00-\x1f\x7f-\x9f]/u.test(value);
const roles = ['normal','label','pronunciation','headword','example','quotation','citation','reference'];
const require = (ok, message='Invalid compiled dictionary') => { if (!ok) throw Error(message); };
export function decode(bytes, metadata) {
  let p=0, budget=1000000, explained=false, colored=false, anchored=false, painted=false, nested=false, ordered=false, scaled=false, based=false, referenceItems=false, referenceBlocks=false, imageBorder=false, aligned=false, componentTargets=false, dynamicCatalogue=false, tooltips=false, blockGeometry=false, rich=false, inlineTableStyles=false, containers=false, containerFonts=false, contentDepth=0, rubyDepth=0, rubyCount=0, rubyEnabled=false, mapStringBudget=32*1024*1024;
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const take=n=>{require(n>=0 && n<=bytes.length-p);const start=p;p+=n;return bytes.subarray(start,p);};
  const byte=()=>take(1)[0], u16=()=>{const at=p;take(2);return view.getUint16(at,true);}, u32=()=>{const at=p;take(4);return view.getUint32(at,true);};
  const string=()=>{const n=u32();require(n<=32*1024*1024);return utf8.decode(take(n));};
  const f32=()=>{const at=p;take(4);return view.getFloat32(at,true);};
  const f64=()=>{const at=p;take(8);return view.getFloat64(at,true);};
  const charge=()=>{require(budget>0);budget--;};
  const content=fn=>{require(contentDepth<16,'Content depth exceeds limit');contentDepth++;try{return fn();}finally{contentDepth--;}};
  const blockMinimum=()=>rich?29:blockGeometry?27:aligned?26:anchored?25:17;
  const mapString=()=>{const n=u32();require(n<=32*1024*1024&&n<=mapStringBudget);mapStringBudget-=n;return utf8.decode(take(n));};
  const mapAction=()=>{const kind=tag(['internal','external']),target=mapString(),target_fragment=presence()?mapString():null,label=mapString();require(kind==='internal'?(target.length>0||target_fragment!==null):(target.length>0&&target_fragment===null));return {kind,target,target_fragment,label};};
  const imageMap=()=>{
    const description=tag(['none','top_right','bottom_right','bottom_left','top_left']);
    const regions=list(39,()=>{const shape=tag(['rectangle','circle','polygon']),n=count(8);require(shape==='rectangle'?n===4:shape==='circle'?n===3:n>=6&&n%2===0);require(n*8+10<=bytes.length-p);const coordinates=Array.from({length:n},()=>{const n=f64();require(Number.isFinite(n));return n;});return {shape,coordinates,action:mapAction()};});
    const default_action=presence()?(charge(),mapAction()):null;return {description,regions,default_action};
  };
  const count=min=>{const n=u32();require(n<=budget && n<=(bytes.length-p)/min);budget-=n;return n;};
  const list=(min,fn)=>Array.from({length:count(min)},fn);
  const tag=values=>{const n=byte();require(n<values.length);return values[n];};
  const presence=()=>{const n=byte();require(n<2);return n===1;};
  const index=limit=>{const n=u32();require(n<limit);return n;};
  const optional=limit=>{const n=u32();require(n===0xffffffff||n<limit);};
  const indices=limit=>list(4,()=>index(limit));
  const rgb=()=>{if(!presence())return null;const value=string();require(value.length===7&&/^#[0-9a-f]{6}$/.test(value));return value;};
  const spanValue=()=>{
    const kind=tag(['text','link','external_link','line_break']),role=tag(roles),flags=byte();
    const s={kind,role,text:string(),target:string(),trail:string(),language:string(),classes:string(),direction:string(),explanation:explained?string():'',foreground:colored?rgb():null,background:painted?rgb():null};
    const fontFields=scaled?(containerFonts?byte():(presence()?1:0)):0;
    require((fontFields&~1)===0,'Unsupported span font policy');
    if(fontFields&1){const value=f32();require(Number.isFinite(value)&&value>=0,'Invalid semantic font scale');s.font_scale=value;if(based){const basis=tag(containerFonts?['context','normal_body','css_px']:['context','normal_body']);if(basis!=='context')s.font_scale_basis=basis;if(tooltips&&value===1&&basis==='context')delete s.font_scale;}}
    if(referenceBlocks&&presence()){
      require(kind!=='line_break'&&s.text===''&&s.trail===''&&(kind==='text'?s.target==='':s.target.length>0));const image={file:string()},flags=byte();require((flags&~(inlineTableStyles?127:rich?63:imageBorder?31:15))===0&&validInlineImageFile(image.file));
      for(const [bit,key] of [[1,'width_px'],[2,'height_px']])if(flags&bit){image[key]=u32();require(image[key]>0);}
      if(flags&4)image.alt=string();if(flags&8)image.tooltip=string();if(imageBorder&&(flags&16))image.border=true;if(flags&32)image.map=imageMap();if(flags&64)image.dark_mode_filter=tag(['invert_hue_rotate_180']);s.image=image;
    }
    if(componentTargets&&presence()){require(kind==='link','Invalid target fragment kind');s.target_fragment=string();}
    if(tooltips)s.tooltip=presence()?string():null;
    if(rubyEnabled&&presence()){s.ruby=rubyValue();validateRubySpan(s);}
    ['bold','italic','code','small','superscript','subscript','strike','underline'].forEach((f,i)=>s[f]=!!(flags&(1<<i)));return s;
  };
  const spans=()=>list(tooltips?37:componentTargets?36:referenceBlocks?35:scaled?34:painted?33:colored?32:explained?31:27,spanValue);
  const styleLength=()=>{const unit=tag(['px','em']),at=p;take(4);const value=view.getFloat32(at,true);require(Number.isFinite(value)&&value>=0,'Invalid style length');return {unit,value};};
  const rubyFontSnapshot=()=>{
    const fields=byte();require((fields&~31)===0,'Invalid ruby font flags');
    const value={small:!!(fields&2),superscript:!!(fields&4),subscript:!!(fields&8),font_normalized:!!(fields&16)};
    if(fields&1){const scale=f32(),basis=tag(['context','normal_body','css_px']);require(Number.isFinite(scale)&&scale>=0);if(scale!==1||basis!=='context')value.font_scale=scale;if(basis!=='context')value.font_scale_basis=basis;}
    const face=byte();require((face&~7)===0,'Unsupported ruby owner font policy');
    value.bold=!!(face&1);value.italic=!!(face&2);value.code=!!(face&4);value.language=string();value.classes=string();value.role=tag(roles);value.font_features=null;
    return value;
  };
  const rubyInlineStyle=()=>{
    const fields=byte();require(fields!==0&&(fields&~10)===0,'Unsupported ruby owner inline style');
    let line_height=null;
    if(fields&2){const kind=tag(['computed','font_relative']);line_height=kind==='computed'?{computed:{value:f32(),font_scale_basis:tag(['context','normal_body','css_px'])}}:{font_relative:{factor:f32(),font:rubyFontSnapshot()}};}
    return {decoration:null,line_height,baseline_shift:null,font_normalized:!!(fields&8),cursor:null};
  };
  const rubyOwner=()=>{
    charge();require(bytes.length-p>=18);const font=rubyFontSnapshot(),direction=string(),inline_style=presence()?rubyInlineStyle():null;
    const value={font,direction,inline_style,foreground:presence()?string():null,background:presence()?string():null};validateRubyOwner(value);return value;
  };
  const rubyValue=()=>{
    require(rubyDepth<16&&contentDepth<16,'Ruby depth exceeds limit');rubyDepth++;contentDepth++;rubyCount++;
    try{
      const segments=list(38,()=>{
        const gap_before=spans();const bases=list(26,()=>({gap_before:spans(),owner:rubyOwner(),spans:spans()}));
        const annotations=list(47,()=>{
          const base_start=u32(),base_count=u32(),level=u32(),owner=rubyOwner(),gap_before=spans(),values=spans(),fallback_before=spans(),fallback_after=spans(),flags=byte();
          require((flags&~1)===0,'Invalid ruby annotation flags');return {base_start,base_count,level,owner,gap_before,spans:values,fallback_before,fallback_after,explicit_fallback:!!(flags&1)};
        });return {gap_before,bases,annotations};
      });const value={segments};validateRuby(value);return value;
    }finally{rubyDepth--;contentDepth--;}
  };
  const edges=()=>({top:styleLength(),right:styleLength(),bottom:styleLength(),left:styleLength()});
  const containerWidth=()=>{const kind=tag(['auto','length','fit_content']);return {[kind]:kind==='length'?{unit:tag(['px','em','percent']),value:f32()}: {}};};
  const containerMaxWidth=()=>presence()?{length:{unit:tag(['px','em','percent']),value:f32()}}:{none:{}};
  const containerColor=()=>{const kind=tag(['transparent','rgb','light_dark']);return {[kind]:kind==='rgb'?string():kind==='light_dark'?{light:string(),dark:string()}: {}};};
  const containerBorder=()=>presence()?{solid:{width:styleLength(),color:containerColor()}}:{none:{}};
  const containerLineHeight=()=>{const kind=tag(['normal','multiplier','length']);return {[kind]:kind==='multiplier'?f32():kind==='length'?styleLength(): {}};};
  const containerMargins=()=>Object.fromEntries(['top','right','bottom','left'].map(side=>[side,presence()?{length:styleLength()}:{auto:{}}]));
  const containerScreen=(following=false)=>{
    const value={max_width_px:u32()},flags=byte();require(flags&127);require(!following||!(flags&128));
    if(flags&1)value.width=containerWidth();if(flags&2)value.max_width=containerMaxWidth();
    if(flags&4)value.box_sizing=tag(['content_box','border_box']);if(flags&8)value.line_height=containerLineHeight();
    if(flags&16)value.float_side=tag(['none','left','right']);if(flags&32)value.margins=containerMargins();
    if(flags&64)value.clear=tag(['none','left','right','both']);
    if(flags&128){const n=count(6);require(n>0&&n<16);value.following_rules=Array.from({length:n},()=>containerScreen(true));}
    return value;
  };
  const containerStyle=()=>{
    const flags=containerFonts?u32():u16(),style={},fields=[['margins',edges],['padding',edges],['width',containerWidth],['float_side',()=>tag(['left','right'])],['clear',()=>tag(['none','left','right','both'])],['max_width',containerMaxWidth],['box_sizing',()=>tag(['content_box','border_box'])],['layout',()=>tag(['flow','flex_row'])],['align_items',()=>tag(['stretch','start','center','end'])],['flex_item',()=>tag(['none'])],['background',containerColor],['border',containerBorder],['line_height',containerLineHeight],['text_align',()=>tag(['left','center','right'])],['screen_max_width',containerScreen],['overflow',()=>tag(['visible','auto'])],['owner_font_scale',f32],['height',styleLength],['columns',()=>({count:u16(),gap:styleLength()})]];
    require((flags&~0x7ffff)===0,'Unsupported container layout policy');
    fields.forEach(([key,read],bit)=>{if(flags&(1<<bit))style[key]=read();});return style;
  };
  const borderLine = kind => {
    const width = styleLength(), color = string();
    require(/^#[0-9a-f]{6}$/.test(color) && color.length === 7);
    return {[kind]: {width, color}};
  };
  const borderStyle = () => {
    const kind = tag(containerFonts ? ['none','solid','edges'] : ['none','solid']);
    if (kind === 'none') return {none:{}};
    if (kind === 'solid') return borderLine(kind);
    const edges = {};
    for (const side of ['top','right','bottom','left']) {
      const edge = tag(['none','hidden','solid','dotted']);
      edges[side] = edge === 'none' || edge === 'hidden' ? {[edge]:{}} : borderLine(edge);
    }
    return {edges};
  };
  const typedStyle=table=>{
    if(!presence())return null;
    const flags=byte(),extension=table&&inlineTableStyles?byte():0;require((extension&~7)===0&&(flags!==0||extension!==0)&&(flags&~(table?(rich?255:aligned?31:15):containerFonts?239:7))===0);
    const style={};
    if(table){
      if(flags&1){style.background=string();require(/^#[0-9a-f]{6}$/.test(style.background));}
      if(flags&2)style.border=borderStyle();
      if(flags&4)style.collapse=tag(['separate','collapse']);
      if(flags&8)style.margins=edges();
      if(aligned&&(flags&16))style.float_side=tag(['left','right']);
      if(flags&32){const unit=tag(['px','em','percent']),value=f32();require(Number.isFinite(value)&&value>=0);style.width={unit,value};}
      if(flags&64)style.padding=edges();
      if(flags&128)style.clear=tag(['none','left','right','both']);
      if(extension&1)style.display=tag(['table','inline_block','inline_table']);
      if(extension&2)style.vertical_align=tag(containerFonts?['baseline','middle','top']:['baseline','middle']);
      if(extension&4){const value=f32(),font_scale_basis=tag(['context','normal_body']);require(Number.isFinite(value)&&value>0);style.line_height={value,font_scale_basis};}
      require(!style.float_side||!['inline_block','inline_table'].includes(style.display),'Contradictory inline table float');
    }else{
      if(flags&1)style.border=borderStyle();
      if(flags&2)style.padding=edges();
      if(flags&4)style.text_align=tag(['left','center','right']);
      if(flags&32)style.width={unit:tag(['px','em','percent']),value:f32()};
      if(flags&64)style.min_width=styleLength();
      if(flags&128)style.vertical_align=tag(['top','middle']);
      if(flags&8){
        const strut=presence()?{font_scale:f32(),font_scale_basis:tag(['invalid','normal_body','css_px'])}:null;
        if(strut)require(strut.font_scale_basis!=='invalid'&&Number.isFinite(strut.font_scale)&&strut.font_scale>=0);
        const kind=tag(['normal','multiplier','length']);
        const height={[kind]:kind==='normal'?{}:kind==='multiplier'?f32():{value:f32(),font_scale_basis:tag(['invalid','normal_body','css_px'])}};
        style.line_height={...(strut?{strut}:{}),height};
      }
      validateCellMetrics(style);
    }
    return style;
  };
  const tableValue=depth=>{
    if(!presence())return null;
    require(!nested||depth<=16,'Nested table depth exceeds limit');
    let geometry;
    if(nested){
      const flags=byte();require((flags&~15)===0);
      if(flags){geometry={border:null,cell_spacing:null,cell_padding:null,width:null};for(const [bit,key] of [[1,'border'],[2,'cell_spacing'],[4,'cell_padding']])if(flags&bit)geometry[key]=u16();
        if(flags&8){const unit=tag(['px','percent']),value=u32();require(unit!=='percent'||value<=100);geometry.width={unit,value};}}
    }
    const result={caption:spans(),rows:list(4,()=>({cells:list(referenceBlocks?13:ordered?12:nested?11:colored?10:9,()=>{
      const header=presence(),colspan=u16(),rowspan=u16();require(colspan>=1&&colspan<=100&&rowspan>=1&&rowspan<=100);
      const background=colored?rgb():null,values=spans(),cell={header,colspan,rowspan,background,spans:values};
      if(nested){const child=tableValue(depth+1);if(child){require(values.length===0);cell.nested_table=child;}}
      if(ordered&&presence()){require(values.length===0&&!cell.nested_table);cell.blocks=list(blockMinimum(),()=>block(depth));}
      if(referenceBlocks){const style=typedStyle(false);if(style)cell.style=style;}
      return cell;
    })}))};
    if(referenceBlocks){const style=typedStyle(true);if(style)result.style=style;}
    if(rich&&presence()){require(result.caption.length===0);result.caption_blocks=content(()=>list(blockMinimum(),()=>block(depth)));}
    if(result.style&&['inline_block','inline_table'].includes(result.style.display))require(result.caption.length===0&&result.caption_blocks===undefined&&result.rows.some(row=>row.cells.length>0),'Inline table requires cells and no caption');
    if(geometry)result.geometry=geometry;return result;
  };
  const figureColor=()=>{const kind=tag(['native_theme','transparent','rgb']);if(kind!=='rgb')return {kind};const value=string();require(/^#[0-9a-f]{6}$/.test(value));return {kind,value};};
  const figureBorder=()=>{const kind=tag(['none','solid']);return kind==='none'?{kind}:{kind,width:styleLength(),color:figureColor()};};
  const figure=tableDepth=>{
    if(!presence())return null;
    require(bytes.length-p>=123);
    const value={format:tag(['thumbnail','framed']),placement:tag(['none','center','float_left','float_right']),clear:tag(['none','left','right','both']),margins:edges(),image_insets:edges(),caption_padding:edges(),caption_font_scale:f32(),caption_line_height:styleLength(),frame_background:figureColor(),frame_border:figureBorder(),image_background:figureColor(),image_border:figureBorder(),caption_foreground:figureColor(),caption_background:figureColor()};
    require(Number.isFinite(value.caption_font_scale)&&value.caption_font_scale>=0);charge();value.image_span=spanValue();value.caption=spans();
    if(presence()){require(value.caption.length===0);value.caption_blocks=content(()=>list(blockMinimum(),()=>block(tableDepth)));}
    if(presence())value.caption_text_align=tag(['left','center','right']);
    value.sizing=tag(['intrinsic','original_width_with_height_bound','requested_fit','requested_fit_cap_original_width']);
    if(presence()){value.frame_min_width=styleLength();require(value.frame_min_width.unit==='px');}
    const image=value.image_span.image;require(image);
    require(value.sizing==='intrinsic'?value.format==='framed':value.sizing==='original_width_with_height_bound'?value.format==='framed'&&image.height_px!=null:value.format==='thumbnail'&&image.width_px!=null);
    return value;
  };
  const flowParts=tableDepth=>list(5,()=>{const kind=tag(['inline','figure','scope']);if(kind==='inline')return {kind,spans:spans(),figure:null,scope:null};if(kind==='figure'){const value=figure(tableDepth);require(value);return {kind,spans:[],figure:value,scope:null};}return {kind,spans:[],figure:null,scope:content(()=>{const mode=tag(['isolate','isolate_override']),authored_direction=tag([null,'ltr','rtl','auto']),resolved_direction=tag(['ltr','rtl']),language=presence()?string():null;require(authored_direction==='ltr'?resolved_direction==='ltr':authored_direction==='rtl'?resolved_direction==='rtl':!(mode==='isolate_override'));return {mode,authored_direction,resolved_direction,language,parts:flowParts(tableDepth)};})};});
  const block=(tableDepth=0)=>{
    const kind=tag(containers?blocks:blocks.slice(0,-1)),depth=byte(),level=byte();const value={kind,depth,level,spans:spans()};
    if(presence()) value.feature={kind:string(),language:string(),data:string(),tail_kind:string(),tail:string()};
    value.path=string();value.number=string();
    const table=tableValue(tableDepth+1);if(table)value.table=table;
    value.anchor=anchored?string():'';value.anchor_fallback=anchored?string():'';
    if(aligned&&presence())value.text_align=tag(['left','center','right']);
    if(blockGeometry&&presence()){const flags=byte();require(flags!==0&&(flags&~3)===0);value.style={};if(flags&1)value.style.margins=edges();if(flags&2)value.style.padding=edges();require(kind==='paragraph'&&depth===0&&!value.table&&!value.feature&&value.path==='');}
    if(rich){
      const img=figure(tableDepth);if(img){require(value.spans.length===0&&!value.table&&!value.feature&&!value.style&&contentContext(value));value.figure=img;}
      if(presence()){require(value.spans.length===0&&!value.table&&!value.feature&&!value.figure&&contentContext(value));value.flow=content(()=>flowParts(tableDepth));}
    }
    if(kind==='container'){
      value.container=content(()=>({style:containerStyle(),blocks:list(blockMinimum(),()=>block(tableDepth))}));
      validateContainerBlock(value,{containerFonts});
    }
    if(rubyEnabled&&kind==='rule')require(byte()===0,'Unsupported ruby-record rule style');
    return value;
  };
  const contentContext=value=>['list_item','definition','example','quotation','term','list_detail','indent'].includes(value.kind)||(value.kind==='paragraph'&&value.depth===0&&value.path==='');
  const magic=utf8.decode(take(4));
  require(magic==='DPR2'||magic==='DPR3'||magic==='DPR4'||magic==='DPR5'||magic==='DPR6'||magic==='DPR7'||magic==='DPR8'||magic==='DPR9'||magic==='DPRA'||magic==='DPRB'||magic==='DPRC'||magic==='DPRD'||magic==='DPRE'||magic==='DPRF'||magic==='DPRG'||magic==='DPRH'||magic==='DPRI'||magic==='DPRJ'||magic==='DPRK'||magic==='DPRL'||magic==='DPRM'||magic==='DPRS','Dictionary contains uncompiled records');
  rubyEnabled=magic==='DPRS';containerFonts=magic==='DPRM'||rubyEnabled;containers=magic==='DPRL'||containerFonts;inlineTableStyles=magic==='DPRK'||containers;rich=magic==='DPRJ'||inlineTableStyles;blockGeometry=magic==='DPRI'||rich;tooltips=magic==='DPRH'||blockGeometry;dynamicCatalogue=magic==='DPRG'||tooltips;componentTargets=magic==='DPRF'||dynamicCatalogue;aligned=magic==='DPRE'||componentTargets;imageBorder=magic==='DPRD'||aligned;referenceBlocks=magic==='DPRC'||imageBorder;based=magic==='DPRB'||referenceBlocks;scaled=magic==='DPRA'||based;referenceItems=magic==='DPR9'||scaled;ordered=magic==='DPR8'||referenceItems;nested=magic==='DPR7'||ordered;if(nested)budget=1<<20;painted=magic==='DPR6'||nested;anchored=magic==='DPR5'||painted;colored=magic==='DPR4'||anchored;explained=magic!=='DPR2';
  const entry={...metadata,presentation_version:magic,display_title:spans(),sections:list(anchored?17:9,()=>({level:byte(),title:string(),anchor:anchored?string():'',anchor_fallback:anchored?string():'',blocks:list(blockMinimum(),()=>block())})),preamble_spans:spans()};
  const childPath=(values,root)=>{
    const n=count(4);require(n<=16);let value=values[root];
    for(let i=0;i<n;i++){require(value.kind==='container'&&value.container);value=value.container.blocks[index(value.container.blocks.length)];}
    return n;
  };
  const childPaths=(values,roots)=>{
    const n=count(4);require(n===0||n===roots.length);let nonempty=false;
    for(let i=0;i<n;i++)nonempty=childPath(values,roots[i])>0||nonempty;
    require(n===0||nonempty);
  };
  list(29,()=>{string();string();const s=index(entry.sections.length);optional(entry.sections.length);const values=entry.sections[s].blocks,n=values.length;
    list(18,(_,sense)=>{const root=index(n);optional(sense);const examples=indices(n),quotations=indices(n),notes=indices(n);if(presence()){string();string();string();}if(containers){childPath(values,root);for(const roots of [examples,quotations,notes])childPaths(values,roots);}});
    const introduction=indices(n),other=indices(n);indices(entry.sections.length);
    if(containers){childPaths(values,introduction);childPaths(values,other);}
  });
  indices(entry.sections.length);
  entry.references=list(referenceBlocks?14:referenceItems?13:20,()=>{
    const kind=referenceItems?tag(['note','fragment']):'note',number=u32();
    require(number>0&&number<0xffffffff);
    let reference;
    if(kind==='fragment')reference={kind,number,group_number:null,name:'',group:string(),spans:spans()};
    else {
      const group_number=u32();require(group_number>0&&group_number<0xffffffff);
      const name=string(),group=string();reference={number,group_number,name,group,spans:spans()};
    }
    if(referenceBlocks){
      if(presence()){require(reference.spans.length===0);reference.blocks=list(blockMinimum(),()=>block());}
    }
    return reference;
  });
  entry.media=list(9,()=>({file:string(),kind:tag(['image','audio']),caption:string()}));
  if(rubyEnabled){require(byte()===0,'Unsupported ruby-record body feature');require(rubyCount>0,'DPRS requires ruby payload');}
  const images=[];
  const inspect=values=>{for(const span of values||[])if(span.image)images.push(span.image);};
  const inspectTable=value=>{inspect(value.caption);if(value.caption_blocks)inspectBlocks(value.caption_blocks);for(const row of value.rows)for(const cell of row.cells){inspect(cell.spans);if(cell.blocks)inspectBlocks(cell.blocks);if(cell.nested_table)inspectTable(cell.nested_table);}};
  const inspectFigure=value=>{inspect([value.image_span]);inspect(value.caption);if(value.caption_blocks)inspectBlocks(value.caption_blocks);};
  const inspectFlow=parts=>{for(const part of parts){inspect(part.spans);if(part.figure)inspectFigure(part.figure);if(part.scope)inspectFlow(part.scope.parts);}};
  const inspectBlocks=values=>{for(const value of values){inspect(value.spans);if(value.table)inspectTable(value.table);if(value.figure)inspectFigure(value.figure);if(value.flow)inspectFlow(value.flow);if(value.container)inspectBlocks(value.container.blocks);}};
  inspect(entry.display_title);inspect(entry.preamble_spans);for(const section of entry.sections)inspectBlocks(section.blocks);for(const ref of entry.references){inspect(ref.spans);if(ref.blocks)inspectBlocks(ref.blocks);}
  if(images.length){
    if(!dynamicCatalogue)require(entry.media.length<=(aligned?256:128));
    // Build once; values and this local lookup are read-only during validation.
    const catalogue=new Map();
    for(const media of entry.media){const item=catalogue.get(media.file);if(item)item.multiplicity++;else catalogue.set(media.file,{kind:media.kind,multiplicity:1});}
    for(const item of catalogue.values())Object.freeze(item);
    for(const image of images){const item=catalogue.get(image.file);require(item?.multiplicity===1&&item.kind==='image','Invalid inline image catalog identity');}
  }
  require(p===bytes.length,'Trailing presentation data');return entry;
}

export function decodeAlias(bytes, rawKey) {
  const invalid='Invalid compiled alias';
  require(bytes.length>=15 && utf8.decode(bytes.subarray(0,4))==='DAL1',invalid);
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const source_namespace=view.getUint32(4,true),sourceKind=bytes[8],hasNamespace=bytes[9],targetNamespace=view.getUint32(10,true),targetKind=bytes[14];
  require(sourceKind>=1&&sourceKind<=7&&hasNamespace<=1&&targetKind<=7,invalid);
  require(hasNamespace===1||targetNamespace===0,invalid);
  require((sourceKind===1)===(source_namespace===0),invalid);
  if(targetKind)require(hasNamespace===1&&(targetKind===1)===(targetNamespace===0),invalid);
  let p=15;
  const field=()=>{
    let n=0,multiplier=1,count=0,b;
    do{require(p<bytes.length&&count++<8,invalid);b=bytes[p++];n+=(b&127)*multiplier;multiplier*=128;}while(b&128);
    require((count===1||b!==0)&&Number.isSafeInteger(n)&&n<=bytes.length-p,invalid);
    const value=bytes.subarray(p,p+n);p+=n;return value;
  };
  const text=()=>utf8.decode(field());
  const source_title=text(),source_key=text(),xml_target=text(),target_title=text(),target_key=text(),fragmentBytes=field(),fragment=utf8.decode(fragmentBytes),presentation=field();
  require(p===bytes.length&&presentation.length>0,invalid);
  for(const value of [source_title,source_key,xml_target,target_title])require(value.length>0&&!value.includes('\0'),invalid);
  require(!target_key.includes('\0')&&!fragment.includes('\0')&&fragmentBytes.length<=255,invalid);
  const key=(kind,title)=>{if(kind===1||kind===7)return title;const colon=title.indexOf(':');require(colon>=0,invalid);return title.slice(colon+1);};
  require(source_key===key(sourceKind,source_title),invalid);
  require(targetKind?target_key.length>0&&target_key===key(targetKind,target_title):target_key.length===0,invalid);
  require(rawKey===sourceKind+'\t'+source_key,invalid);
  const alias={source_namespace,source_kind:kinds[sourceKind-1],source_title,source_key,xml_target,target_title,target_namespace:hasNamespace?targetNamespace:null,target_kind:targetKind?kinds[targetKind-1]:null,target_key,fragment};
  const entry=decode(presentation,{kind:'alias',language:null,language_code:'',title:source_title});
  entry.alias={xml_target,target_title,fragment};
  entry.redirect={source_title,target_title,fragment,followed:false};
  return {alias,entry};
}

export async function buildIndex(source) {
  let p=0, buffer=new Uint8Array(), start=-1;
  async function refill() {
    require(p < source.size, 'Truncated dictionary');
    start = p;
    buffer = await source.read(p, Math.min(256 * 1024, source.size - p));
    require(buffer.length > 0, 'Truncated dictionary');
  }
  async function nul() {
    let prefix;
    while (true) {
      if (p >= start + buffer.length) await refill();
      const at = p - start;
      const remaining = 65536 - (prefix?.length ?? 0);
      const window = buffer.subarray(at, at + remaining + 1);
      const end = window.indexOf(0);
      const part = end < 0 ? window : window.subarray(0, end);
      require(part.length <= remaining);
      p += part.length;
      let raw = part;
      if (prefix) {
        raw = new Uint8Array(prefix.length + part.length);
        raw.set(prefix);
        raw.set(part, prefix.length);
      }
      if (end >= 0) {
        ++p;
        return {text: utf8.decode(raw), raw};
      }
      prefix = raw;
    }
  }
  // The title scan usually brought the record prefix (or the whole alias) into memory.
  const recordBytes = length => {
    const at = p - start;
    if (at >= 0 && at + length <= buffer.length) return buffer.subarray(at, at + length);
    return source.read(p, length);
  };
  const magic=await source.read(0,9);require(utf8.decode(magic.subarray(0,8))==='WIKBLB08','Choose a WIKBLB08 dictionary');
  const kind=kinds[magic[8]-1];require(kind);p=9;
  const metadata={kind,language_code:'',language:null};
  if(kind==='language'){metadata.language_code=(await nul()).text;metadata.language=(await nul()).text;require(metadata.language.length>0);}
  const rows=[];let previous=null;
  while(p<source.size){
    const {text:title,raw}=await nul();require(title.length>0);
    if(previous){let i=0;while(i<Math.min(previous.length,raw.length)&&previous[i]===raw[i])i++;require(i<Math.min(previous.length,raw.length)?previous[i]<raw[i]:previous.length<raw.length,'Unsorted dictionary');}previous=raw;
    let length=0,multiplier=1,n=0,b;
    do {
      if (p >= start + buffer.length) await refill();
      b = buffer[p++ - start];
      require(n++ < 8);
      length += (b & 127) * multiplier;
      multiplier *= 128;
    } while (b & 128);
    require(n===1||b!==0);require(Number.isSafeInteger(length)&&length>=4&&length<=128*1024*1024&&length<=source.size-p);
    if(kind==='alias'){
      const {alias}=decodeAlias(await recordBytes(length),title);
      rows.push({title:alias.source_key,raw_key:title,source_kind:alias.source_kind,source_title:alias.source_title,offset:p,length});
    }else{
      const magic=utf8.decode(await recordBytes(4));
      require(magic==='DPR2'||magic==='DPR3'||magic==='DPR4'||magic==='DPR5'||magic==='DPR6'||magic==='DPR7'||magic==='DPR8'||magic==='DPR9'||magic==='DPRA'||magic==='DPRB'||magic==='DPRC'||magic==='DPRD'||magic==='DPRE'||magic==='DPRF'||magic==='DPRG'||magic==='DPRH'||magic==='DPRI'||magic==='DPRJ'||magic==='DPRK'||magic==='DPRL'||magic==='DPRM'||magic==='DPRS');
      rows.push({title,offset:p,length});
    }
    require(rows.length<=10000000);p+=length;
  }
  require(kind!=='language'||rows.length>0,'Empty language dictionary');return {metadata,rows};
}
export class RawSource {
  constructor(file){this.file=file;this.size=file.size;}
  async read(offset,length){require(offset>=0&&length>=0&&offset+length<=this.size);return new Uint8Array(await this.file.slice(offset,offset+length).arrayBuffer());}
}
