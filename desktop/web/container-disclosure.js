// Typed IT button consumer adapted from retained S4 consumer04.
// Public wire admission belongs to the decoder and its exact capability gate.
const sides=['top','right','bottom','left'];
const states=['normal','hover','active','hover_active'];
const bad=()=>{throw Error('Invalid compiled container disclosure button');};
const check=v=>{if(!v)bad();};
const object=(v,keys,required=keys)=>{
  check(v&&typeof v==='object'&&!Array.isArray(v));
  check(Object.keys(v).every(k=>keys.includes(k))&&required.every(k=>Object.hasOwn(v,k)));
};
const rgb=v=>check(typeof v==='string'&&/^#[0-9a-f]{6}$/.test(v));
const finite=(v,positive=false)=>check(typeof v==='number'&&Number.isFinite(v)&&v<=3.4028234663852886e38&&(positive?v>0:v>=0));
const px=(v,positive=false)=>{object(v,['unit','value']);check(v.unit==='px');finite(v.value,positive);};
const signedPx=v=>{object(v,['unit','value']);check(v.unit==='px'&&typeof v.value==='number'&&Number.isFinite(v.value)&&Math.abs(v.value)<=3.4028234663852886e38);};
const one=(v,keys)=>{object(v,keys,[]);check(Object.keys(v).length===1);return Object.keys(v)[0];};
const empty=v=>object(v,[]);
const text=v=>check(typeof v==='string'&&!/[\u0000-\u001f\u007f\ud800-\udfff]/u.test(v));
function figureColor(v){
  object(v,['kind','value'],['kind']);check(['rgb','transparent'].includes(v.kind));
  if(v.kind==='rgb')rgb(v.value);else check(v.value==null);
}
function border(v){
  object(v,sides);
  for(const side of sides){
    const edge=v[side],kind=one(edge,['none','hidden','solid','dotted','inset','outset']);
    if(kind==='none'||kind==='hidden'){empty(edge[kind]);continue;}
    const line=edge[kind];object(line,['width','paint']);px(line.width);
    object(line.paint,['rgb']);rgb(line.paint.rgb);
  }
}
function fontFamily(v){
  object(v,['name']);const name=v.name;
  check(typeof name==='string'&&name.length>0&&name.length<=128&&name===name.trim()&&!/[^\x20-\x7e]|[\[\]]/.test(name));
  const folded=name.toLowerCase().replace(/ +/g,' ');
  check(!['serif','sans-serif','sans serif','sans','monospace','cursive','fantasy','system','system-ui','ui-serif','ui-sans-serif','ui-monospace','ui-rounded','emoji','math','fangsong'].includes(folded));
}
function labelPaint(v){
  object(v,[...states,'underline_on_focus'],states);
  check(v.underline_on_focus==null||typeof v.underline_on_focus==='boolean');
  for(const state of states){object(v[state],['foreground','underline']);rgb(v[state].foreground);check(typeof v[state].underline==='boolean');}
}
function labelRun(label,v){
  if(v==null)return;
  object(v,['start','end','paint']);labelPaint(v.paint);
  const bytes=new TextEncoder().encode(label);
  check(Number.isInteger(v.start)&&Number.isInteger(v.end)&&v.start>=0&&v.start<v.end&&v.end<=bytes.length);
  // The common model uses UTF-8 byte boundaries, not JS/Qt UTF-16 offsets.
  check((v.start===0||(bytes[v.start]&0xc0)!==0x80)&&(v.end===bytes.length||(bytes[v.end]&0xc0)!==0x80));
}
export function validateContainerDisclosureButton(v){
  const fields=['appearance','font_family','font_size','font_weight','font_italic','line_height','padding',...states,'focus_visible','outline_colors'];
  object(v,fields,fields.filter(k=>!['focus_visible','outline_colors'].includes(k)));
  check(v.appearance==='native_button');
  fontFamily(v.font_family);px(v.font_size,true);check(v.font_weight===400&&v.font_italic===false);
  const line=one(v.line_height,['normal','length']);if(line==='normal')empty(v.line_height.normal);else px(v.line_height.length,true);
  object(v.padding,sides);for(const side of sides)px(v.padding[side]);
  for(const state of states){object(v[state],['background','border']);figureColor(v[state].background);border(v[state].border);}
  if(v.focus_visible!=null){
    const focus=v.focus_visible;object(focus,['mode','outline']);check(focus.mode==='ua_auto');
    object(focus.outline,['width','color','radius','offset']);
    px(focus.outline.width,true);px(focus.outline.radius);signedPx(focus.outline.offset);figureColor(focus.outline.color);
    check(focus.outline.radius.value===0&&focus.outline.color.kind==='rgb');
  }
  if(v.outline_colors!=null){
    object(v.outline_colors,['unfocused','focused']);
    for(const key of ['unfocused','focused']){figureColor(v.outline_colors[key]);check(v.outline_colors[key].kind==='rgb');}
  }
}
export function containerDisclosureButtonOutlineColor(v,focused,focusVisible){
  validateContainerDisclosureButton(v);
  check(typeof focused==='boolean'&&typeof focusVisible==='boolean'&&(!focusVisible||focused));
  if(focusVisible&&v.focus_visible!=null)return v.focus_visible.outline.color;
  return v.outline_colors==null?null:v.outline_colors[focused?'focused':'unfocused'];
}
export function validateContainerDisclosure(owner){
  const p=owner.disclosure;
  if(p==null)return;
  object(p,['content_index','initially_collapsed','expand_label','collapse_label','focus','placement','foreground','direction','expand_run','collapse_run','button'],['content_index','initially_collapsed','expand_label','collapse_label','button']);
  check(Number.isInteger(p.content_index)&&p.content_index>=0&&p.content_index<=0xffffffff&&Array.isArray(owner.blocks)&&p.content_index<owner.blocks.length);
  const child=owner.blocks[p.content_index];check(child?.kind==='container'&&child.container!=null);
  check(typeof p.initially_collapsed==='boolean');
  for(const label of [p.expand_label,p.collapse_label]){text(label);const n=new TextEncoder().encode(label).length;check(n>0&&n<=32*1024*1024);}
  check(p.focus==null&&p.button!=null); // Legacy generic disclosure remains outside this new consumer domain.
  check(p.placement==null||['inline_flow','float_left','float_right'].includes(p.placement));
  check(p.direction==null||['ltr','rtl'].includes(p.direction));
  if(p.foreground!=null)figureColor(p.foreground);
  labelRun(p.expand_label,p.expand_run);labelRun(p.collapse_label,p.collapse_run);validateContainerDisclosureButton(p.button);
}
export function containerDisclosureItems(owner){
  validateContainerDisclosure(owner);
  const policy=owner.disclosure;
  if(policy==null)return 0;
  return 2+Number(policy.expand_run!=null)+Number(policy.collapse_run!=null)+
    Number(policy.button.focus_visible!=null)+Number(policy.button.outline_colors!=null);
}
const color=v=>v.kind==='rgb'?v.value:'transparent';
// One exact named request; never append a fabricated generic fallback.
const family=v=>JSON.stringify(v.name);
const lineCSS=v=>v.length?v.length.value+'px':'normal';
function borderCSS(v){
  return sides.map(side=>{
    const edge=v[side],[kind]=Object.keys(edge),line=edge[kind];
    return 'border-'+side+':'+(['none','hidden'].includes(kind)?kind:line.width.value+'px '+kind+' '+line.paint.rgb);
  }).join(';');
}
function stateCSS(v){return 'background-color:'+color(v.background)+';'+borderCSS(v.border);}
function textStateCSS(v){return 'color:'+v.foreground+';text-decoration-line:'+(v.underline?'underline':'none');}
function labelCSS(selector,paint){
  let css=selector+'{box-sizing:content-box;'+textStateCSS(paint.normal)+'}';
  for(const [state,pseudo] of [['hover',':hover'],['active',':active'],['hover_active',':hover:active']])
    css+=selector.replace(' > .compiled-disclosure-run',pseudo+' > .compiled-disclosure-run')+'{'+textStateCSS(paint[state])+'}';
  if(paint.underline_on_focus)for(const pseudo of [':focus',':focus:hover',':focus:active',':focus:hover:active'])
    css+=selector.replace(' > .compiled-disclosure-run',pseudo+' > .compiled-disclosure-run')+'{text-decoration-line:underline}';
  return css;
}
let sequence=0;
export function installContainerDisclosure(host,content,owner){
  validateContainerDisclosure(owner);
  if(owner.disclosure==null)return null;
  check(host instanceof Element&&content instanceof Element&&host.contains(content));
  const p=owner.disclosure,v=p.button,cls='compiled-disclosure-'+(++sequence);
  const button=document.createElement('button'),labelStyle=document.createElement('style'),style=document.createElement('style');
  button.type='button';button.className=cls+' compiled-container-disclosure';
  if(p.direction!=null)button.style.direction=p.direction;
  const selector='.'+cls;
  const fixed='box-sizing:border-box;width:auto;height:auto;min-width:0;min-height:0;margin:0;border-radius:0;'+
    'appearance:auto;font-family:'+family(v.font_family)+';font-size:'+v.font_size.value+'px;font-weight:400;font-style:normal;'+
    'font-stretch:normal;font-variant:normal;letter-spacing:normal;word-spacing:normal;line-height:'+lineCSS(v.line_height)+';'+
    'text-transform:none;text-indent:0;text-align:center;text-shadow:none;white-space:normal;'+
    'padding:'+sides.map(s=>v.padding[s].value+'px').join(' ')+';'+
    'color:'+(p.foreground==null?'inherit':color(p.foreground))+';'+
    'float:'+({float_left:'left',float_right:'right'}[p.placement]??'none')+';';
  // Unspecified focus paint leaves the active stylesheet/UA outline intact.
  style.textContent=selector+'{'+fixed+stateCSS(v.normal)+'}'+selector+':hover{'+stateCSS(v.hover)+'}'+
    selector+':active{'+stateCSS(v.active)+'}'+selector+':hover:active{'+stateCSS(v.hover_active)+'}';
  if(v.outline_colors!=null){
    // Explicit source-bound color only. Null adds no override; no default is inferred.
    style.textContent+=selector+':not(:focus){outline-color:'+color(v.outline_colors.unfocused)+'}'+
      selector+':focus{outline-color:'+color(v.outline_colors.focused)+'}';
  }
  if(v.focus_visible){
    // The independently captured focus-visible color wins only in that actual state.
    const o=v.focus_visible.outline;
    style.textContent+=selector+':focus-visible{outline:'+o.width.value+'px auto '+color(o.color)+';outline-offset:'+o.offset.value+'px}';
  }
  let collapsed=p.initially_collapsed;
  const show=next=>{
    collapsed=next;const label=next?p.expand_label:p.collapse_label,run=next?p.expand_run:p.collapse_run;
    button.replaceChildren();labelStyle.textContent='';
    if(run){
      const bytes=new TextEncoder().encode(label),decoder=new TextDecoder('utf-8',{fatal:true});
      const middle=document.createElement('span');middle.className='compiled-disclosure-run';middle.textContent=decoder.decode(bytes.subarray(run.start,run.end));
      button.append(decoder.decode(bytes.subarray(0,run.start)),middle,decoder.decode(bytes.subarray(run.end)));
      labelStyle.textContent=labelCSS(selector+' > .compiled-disclosure-run',run.paint);
    }else button.textContent=label;
    button.setAttribute('aria-expanded',String(!next));
    if(next)content.setAttribute('hidden','until-found');else content.removeAttribute('hidden');
  };
  button.addEventListener('click',()=>show(!collapsed)); // Native button handles Enter/Space and keyboard focus.
  content.addEventListener('beforematch',()=>show(false));
  // Element-reference ARIA avoids assigning an authored fragment destination.
  button.ariaControlsElements=[content];
  host.prepend(style,labelStyle,button);show(collapsed);
  return {button,content};
}
