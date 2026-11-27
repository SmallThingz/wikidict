import {safeURL,linkTargetParts} from './validate.js';
const CACHE='wikidict-media-v1';
let activeMedia=0;
const mediaWaiters=[];
const inlineResources=new Map();
const acquireMedia=()=>{if(activeMedia<4){activeMedia++;return Promise.resolve();}return new Promise(resolve=>mediaWaiters.push(resolve));};
const releaseMedia=()=>{const next=mediaWaiters.shift();if(next)next();else activeMedia--;};
export async function trimMedia(mb){const cache=await caches.open(CACHE),keys=await cache.keys();let total=0;for(let i=keys.length-1;i>=0;i--){const r=await cache.match(keys[i]);total+=(await r.blob()).size;if(total>mb*1024*1024)await cache.delete(keys[i]);}}
export async function clearMedia(){await caches.delete(CACHE);}
export function mediaView(media,settings,sourceEdition,canonicalIdentity=false){
 const root=document.createElement('details'),summary=document.createElement('summary');
 const label=document.createElement('span');
 label.className='heading-label';
 label.textContent=media.caption||media.file;
 summary.append(label);
 root.append(summary);
 const allowed=media.kind==='image'?settings.allowImages:settings.allowAudio;
 if(!allowed){const note=document.createElement('small');note.textContent='Enable online '+(media.kind==='image'?'images':'audio')+' in Settings.';root.append(note);return root;}
 let loaded=false;
 root.addEventListener('toggle',async()=>{if(!root.open||loaded)return;loaded=true;const note=document.createElement('small');note.textContent='Loading…';root.append(note);
  let shared=null;
  try{
   shared=canonicalIdentity&&media.kind==='image'?acquireInlineResource({file:media.file},settings,sourceEdition):null;
   const result=shared?await shared.promise:await mediaResource(media,settings,sourceEdition,canonicalIdentity);
   if(shared&&(!root.isConnected||!result)){shared.release();return;}
   const {info,title,sourceHost}=result,object=shared?result.object:URL.createObjectURL(result.blob),el=document.createElement(media.kind==='image'?'img':'audio');el.src=object;
   if(media.kind==='image'){el.alt=media.caption||media.file;el.loading='lazy';}else el.controls=true;
   if(shared)el.addEventListener('error',()=>shared.release(),{once:true});
   root.addEventListener('toggle',()=>{if(!root.open&&el.pause)el.pause();});
   root.append(el);const credit=document.createElement('a');credit.textContent='Source & licence';credit.href=safeURL(info.descriptionurl)||'https://'+sourceHost+'/wiki/File:'+encodeURIComponent(title);credit.target='_blank';credit.rel='noopener';root.append(credit);note.remove();
   const observer=new MutationObserver(()=>{if(!root.isConnected){if(shared)shared.release();else URL.revokeObjectURL(object);if(el.pause)el.pause();observer.disconnect();}});observer.observe(document.body,{childList:true,subtree:true});
  }catch(error){shared?.release();note.textContent=error.message;loaded=false;}
 });return root;
}

async function mediaResource(media,settings,sourceEdition,canonicalIdentity=false,stillNeeded=()=>true){
 await acquireMedia();
 try{if(!stillNeeded())throw Error('Media occurrence removed');return await fetchMediaResource(media,settings,sourceEdition,canonicalIdentity);}
 finally{releaseMedia();}
}
async function fetchMediaResource(media,settings,sourceEdition,canonicalIdentity){
   const title=canonicalIdentity?media.file:media.file.replace(/^(File|Image):/i,'');
   const canonicalImage=canonicalIdentity&&media.kind==='image';
   const edition=canonicalImage?canonicalImageEdition(sourceEdition):/^[a-z0-9_-]+wiktionary$/.test(sourceEdition||'')?sourceEdition.slice(0,-10).replaceAll('_','-'):null;
   const hosts=['commons.wikimedia.org'];if(edition)hosts.push(edition+'.wiktionary.org');
   let info,sourceHost,canonicalFile;
   const sourceWikiImage=canonicalImage;
   if(sourceWikiImage){
    sourceHost=edition+'.wiktionary.org';
    const url=`https://${sourceHost}/w/api.php?action=query&format=json&formatversion=2&origin=*&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata%7Ccanonicaltitle&iiurlwidth=960&titles=${encodeURIComponent('File:'+title)}`;
    const response=await fetch(url,{redirect:'error'});if(!response.ok)throw Error('Media server unavailable');
    const selected=canonicalImageInfo(await response.json(),title,edition);info=selected.info;canonicalFile=selected.canonical_file;
   }else for(const host of hosts){
    const url=`https://${host}/w/api.php?action=query&format=json&formatversion=2&origin=*&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=960&titles=${encodeURIComponent('File:'+title)}`;
    const response=await fetch(url);if(!response.ok)throw Error('Media server unavailable');const data=await response.json();info=data.query?.pages?.[0]?.imageinfo?.[0];if(info){sourceHost=host;break;}
   }
   if(!info)throw Error('Media unavailable');const url=media.kind==='audio'?info.url:sourceWikiImage?canonicalImageURL(info,canonicalFile):info.thumburl||info.url;
   if(new URL(url).protocol!=='https:')throw Error('Invalid media URL');
   const cacheKey='https://'+sourceHost+'/.wikidict-media-cache?url='+encodeURIComponent(url);
   const cache=await caches.open(CACHE);let response=await cache.match(cacheKey);
   if(!response){response=await fetch(url,sourceWikiImage?{redirect:'error'}:undefined);if(!response.ok)throw Error('Media download failed');const declared=Number(response.headers.get('content-length'));if(declared>50*1024*1024)throw Error('Media too large');const reader=response.body.getReader(),parts=[];let size=0;try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>50*1024*1024)throw Error('Media too large');parts.push(value);}}finally{await reader.cancel();}response=new Response(new Blob(parts),{headers:{'Content-Type':response.headers.get('content-type')||'application/octet-stream'}});if(settings.mediaCacheMb&&size<=settings.mediaCacheMb*1024*1024){await cache.put(cacheKey,response.clone());await trimMedia(settings.mediaCacheMb);}}
   const blob=await response.blob();return {blob,info,title,sourceHost};
}
export function inlineImageActionURL(target,sourceEdition,targetFragment){
 if(typeof target!=='string'||!target.startsWith('File:')||target.length===5)return null;
 const edition=/^[a-z0-9_-]+wiktionary$/.test(sourceEdition||'')?sourceEdition.slice(0,-10).replaceAll('_','-'):null;
 const {title:page,fragment:part}=linkTargetParts(target,targetFragment),fragment=part===undefined||(targetFragment!=null&&part==='')?'':'#'+encodeURIComponent(part);
 return edition?'https://'+edition+'.wiktionary.org/wiki/'+encodeURIComponent(page)+fragment:null;
}
function acquireInlineResource(image,settings,sourceEdition){
 const key=JSON.stringify([image.file,sourceEdition??null,settings.mediaCacheMb??null]);let resource=inlineResources.get(key);
 if(!resource){
  resource={refs:0,object:null,promise:null};inlineResources.set(key,resource);
  resource.promise=mediaResource({file:image.file,kind:'image'},settings,sourceEdition,true,()=>resource.refs>0).then(({blob,info,title,sourceHost})=>{
   if(!resource.refs)return null;resource.object=URL.createObjectURL(blob);return {object:resource.object,info,title,sourceHost};
  });
 }
 resource.refs++;let released=false;
 return {promise:resource.promise,release(){if(released)return;released=true;if(--resource.refs===0){if(inlineResources.get(key)===resource)inlineResources.delete(key);if(resource.object)URL.revokeObjectURL(resource.object);}}};
}
// Figure policies are producer decisions. Use exact integer fitting against
// source-original metadata, independently of downloaded thumbnail pixels/MIME.
export function figureImageSize(image,policy,original){
 const axis=n=>Number.isInteger(n)&&n>0&&n<=4294967295;
 if(!axis(original.width)||!axis(original.height))throw Error('Image size is unavailable.');
 const ow=BigInt(original.width),oh=BigInt(original.height);let width=ow,height=oh;
 const round=(n,d)=>n/d+(n%d>=(d+1n)/2n?1n:0n);
 if(policy!=='intrinsic'){
  if(policy==='original_width_with_height_bound'){if(!axis(image.height_px))throw Error('Invalid compiled figure sizing');}
  else {if(!['requested_fit','requested_fit_cap_original_width'].includes(policy)||!axis(image.width_px))throw Error('Invalid compiled figure sizing');width=BigInt(image.width_px);if(policy==='requested_fit_cap_original_width'&&width>ow)width=ow;}
  const limit=image.height_px==null?null:BigInt(image.height_px);
  if(limit!=null&&width*oh>limit*ow){const numerator=limit*ow,floor=numerator/oh,ceil=floor+(numerator%oh?1n:0n);width=round(ceil*oh,ow)>limit?floor:ceil;if(width===0n)width=1n;height=limit;}
  else height=round(width*oh,ow);
 }
 const exact=n=>{const number=Number(n);if(!Number.isFinite(number)||BigInt(number)!==n)throw Error('Image layout is unavailable.');return number;};
 return {width:exact(width),height:exact(height)};
}
export function loadInlineImage(el,image,settings,sourceEdition,occurrence={}){
 const readyDisplay=el.style.display;let status=null;
 const reserve=occurrence.intrinsic_size||(image.occurrence_layout&&image.width_px!=null&&image.height_px!=null);
 const showStatus=(state,message)=>{
  el.dataset.mediaState=state;el.hidden=true;el.style.display='none';if(!el.isConnected)return;
  if(!status){
   status=document.createElement('span');status.className='compiled-image-status';status.setAttribute('role','img');status.style.display='inline-block';status.style.boxSizing='border-box';status.style.verticalAlign='middle';status.dir='auto';
   if(image.alt){status.textContent=image.alt;status.style.fontSize='var(--wikidict-normal-body-size, 1rem)';}
   else {
    const icon=reserve?document.createElement('span'):status;
    icon.style.cssText+=';display:inline-block;box-sizing:border-box;width:15px;height:15px;border:1px dotted currentColor';
    if(icon!==status){icon.setAttribute('aria-hidden','true');status.append(icon);}
   }
   if(reserve){
    status.style.width=el.style.width;
    status.style.height=el.style.height;
    status.style.overflow='hidden';
   }
   el.insertAdjacentElement('afterend',status);
  }
  status.dataset.mediaState=state;status.setAttribute('aria-label',(image.alt?image.alt+': ':'')+message);status.title=image.tooltip??message;
 };
 el.hidden=true;el.style.display='none';
 if(!settings.allowImages){el.dataset.mediaState='disabled';queueMicrotask(()=>showStatus('disabled','Images are disabled.'));return;}
 queueMicrotask(()=>showStatus('loading','Image is loading.'));
 const resource=acquireInlineResource(image,settings,sourceEdition);let released=false,sourceSize=null,sourceMime=null;
 const observer=new MutationObserver(()=>{if(!el.isConnected){status?.remove();release();}});observer.observe(document.body,{childList:true,subtree:true});
 const release=()=>{if(released)return;released=true;resource.release();observer.disconnect();};
 queueMicrotask(()=>{if(!el.isConnected)release();});
 el.addEventListener('error',()=>{showStatus('error','Image could not be loaded.');release();},{once:true});
 el.addEventListener('load',()=>{
  if(sourceSize===null){showStatus('intrinsic-unresolved','Image size is unavailable.');return;}
  const {width,height}=sourceSize;
  const axes=occurrence.intrinsic_size;
  if(axes&&(width!==axes.width_px||height!==axes.height_px)){
   showStatus('geometry-unresolved','Image dimensions differ from the dictionary.');return;
  }
  if(!(width>0&&height>0)){showStatus('intrinsic-unresolved','Image size is unavailable.');return;}
  // A height-only vector starts with source-site SVGMaxSize, not intrinsic width.
  // Classify the ORIGINAL file: a downloaded PNG may itself be an SVG thumbnail.
  const rasterMime=['image/png','image/jpeg','image/gif','image/webp','image/bmp','image/avif','image/tiff'].includes(sourceMime);
  if(occurrence.sizing==null&&image.width_px==null&&image.height_px!=null&&!rasterMime){showStatus('geometry-unresolved','Image layout is unavailable.');return;}
  let fittedWidth,fittedHeight;
  if(occurrence.sizing!=null){
   try{const fit=figureImageSize(image,occurrence.sizing,sourceSize);fittedWidth=fit.width;fittedHeight=fit.height;}
   catch{showStatus('geometry-unresolved','Image layout is unavailable.');return;}
  }else if(image.height_px!=null){
   const requestedWidth=image.width_px??width;
   if(requestedWidth*height>image.height_px*width){
    const ideal=width*image.height_px/height,up=Math.ceil(ideal);
    fittedWidth=Math.max(1,Math.round(up*height/width)>image.height_px?Math.floor(ideal):up);fittedHeight=image.height_px;
   }else {fittedWidth=requestedWidth;fittedHeight=Math.max(1,Math.round(height*fittedWidth/width));}
  }else if(image.width_px!=null){fittedWidth=image.width_px;fittedHeight=Math.max(1,Math.round(height*fittedWidth/width));}
  else {fittedWidth=width;fittedHeight=height;}
  const renderScale=Math.min(1,10000/fittedWidth,10000/fittedHeight);
  el.style.width=fittedWidth*renderScale+'px';el.style.height=fittedHeight*renderScale+'px';status?.remove();status=null;el.hidden=false;el.style.display=readyDisplay;el.dataset.mediaState='loaded';
  el.dispatchEvent(new CustomEvent('wikidict-image-geometry',{detail:{original:{width,height},layout:{width:fittedWidth,height:fittedHeight}}}));
 },{once:true});
 resource.promise.then(result=>{
  if(released||!el.isConnected||!result){release();return;}const {object,info}=result;
  sourceMime=typeof info.mime==='string'?info.mime.toLowerCase():null;
  if(Number.isSafeInteger(info.width)&&info.width>0&&Number.isSafeInteger(info.height)&&info.height>0)sourceSize={width:info.width,height:info.height};
  el.src=object;
 }).catch(()=>{showStatus('error','Image could not be loaded.');release();});
}

export function audioControlView(span,label,settings,edition) {
  const root=document.createElement('span'),audio=document.createElement('audio');
  const compact=span.audio_control.presentation==='phonos_button',enabled=!!settings.allowAudio;
  const control=compact?document.createElement('button'):audio;
  const activation=compact?null:document.createElement('button');
  const status=document.createElement('span');
  status.className='audio-control-status';
  status.setAttribute('role','status');
  root.className=compact?'phonos-control':'inline-audio-control';
  audio.preload='none';
  if(compact){
    control.type='button';
    control.disabled=!enabled;
    control.title=span.tooltip;
    control.setAttribute('aria-label',span.tooltip);
    if(span.language)control.lang=span.language;
    const icon=document.createElement('img');
    icon.src='assets/phonos/volumeUp.svg';
    icon.alt='';
    icon.setAttribute('aria-hidden','true');
    label.classList.add('phonos-label');
    control.append(icon,label);
  }else{
    audio.controls=true;
    audio.setAttribute('aria-label',span.tooltip||span.text||span.target.slice(5));
    audio.setAttribute('aria-disabled',String(!enabled));
    activation.type='button';
    activation.className='inline-audio-activate';
    for(const axis of ['width','height']){
      const size=span.audio_control[axis];
      if(size)audio.style[axis]=size.unit==='em'?'calc(var(--wikidict-normal-body-size) * '+size.value+')':size.value+(size.unit==='percent'?'%':'px');
    }
  }
  const focus=span.audio_control.focus;
  if(focus){
    for(const target of activation?[control,activation]:[control]){
      target.dataset.focus=focus.mode;
      if(focus.color)target.style.setProperty('--audio-outline',focus.color.kind==='rgb'?focus.color.value:'transparent');
    }
  }
  root.append(control);
  if(activation)root.append(activation);
  root.append(status);
  let object=null,loading=false,observer=null,removed=false;
  function syncActivation(){
    if(!activation)return;
    const focused=root.isConnected?document.activeElement:null;
    activation.hidden=!!object;
    activation.disabled=!enabled;
    // Keep focus while loading; activate() already refuses duplicate gestures.
    activation.setAttribute('aria-disabled',String(!enabled||loading));
    activation.setAttribute('aria-busy',String(loading));
    const name=root.dataset.mediaState==='error'?'Retry audio':'Play audio';
    activation.textContent=loading?'Loading audio…':name;
    activation.setAttribute('aria-label',name+': '+audio.getAttribute('aria-label'));
    if(object){audio.removeAttribute('aria-hidden');audio.removeAttribute('tabindex');}
    else{audio.setAttribute('aria-hidden','true');audio.tabIndex=-1;}
    if(object&&focused===activation)audio.focus({preventScroll:true});
    else if(!object&&focused===audio&&enabled)activation.focus({preventScroll:true});
  }
  function state(name,message=''){
    root.dataset.mediaState=name;
    status.textContent=message;
    if(compact){
      control.setAttribute('aria-pressed',String(name==='playing'));
      control.setAttribute('aria-busy',String(name==='loading'));
    }
    syncActivation();
  }
  function release(){
    if(!object)return;
    const url=object;
    object=null;
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
    URL.revokeObjectURL(url);
  }
  function failed(){
    release();
    if(!removed)state('error','Audio unavailable. Activate to retry.');
  }
  async function activate(){
    if(!enabled||loading||removed||!root.isConnected)return;
    if(compact&&root.dataset.mediaState==='playing'){audio.pause();return;}
    if(!observer){
      observer=new MutationObserver(()=>{
        if(!root.isConnected){removed=true;observer.disconnect();release();}
      });
      observer.observe(document.body,{childList:true,subtree:true});
    }
    loading=true;
    try{
      if(!object){
        state('loading','Loading audio.');
        const stillNeeded=()=>!removed&&root.isConnected;
        const {blob}=await mediaResource({file:span.target.slice(5),kind:'audio'},settings,edition,true,stillNeeded);
        if(!stillNeeded())return;
        object=URL.createObjectURL(blob);
        audio.src=object;
        syncActivation();
      }
      await audio.play();
    }catch{failed();}
    finally{loading=false;syncActivation();}
  }
  audio.addEventListener('playing',()=>{if(object)state('playing');});
  audio.addEventListener('pause',()=>{if(object)state('paused');});
  audio.addEventListener('ended',()=>{if(object)state('ready');});
  audio.addEventListener('error',()=>{if(object)failed();});
  if(compact)control.addEventListener('click',activate);
  else{
    activation.addEventListener('click',activate);
    // The browser owns transport after the first user-initiated acquisition.
    control.addEventListener('click',()=>{if(!object)activate();});
    control.addEventListener('keydown',event=>{
      if(!object&&(event.key==='Enter'||event.key===' ')){event.preventDefault();activate();}
    });
  }
  state(enabled?'ready':'disabled',enabled?'':'Enable online audio in Settings.');
  return root;
}

// Canonical image authority is the compiled source wiki. A negative response
// never authorizes a second Commons lookup or a JavaScript case guess.
export function canonicalImageEdition(sourceEdition){
 if(typeof sourceEdition!=='string'||!/^[a-z0-9_-]+wiktionary$/.test(sourceEdition))throw Error('Canonical source edition unavailable');
 return sourceEdition.slice(0,-10).replaceAll('_','-');
}
export function canonicalImageInfo(data,file,edition){
 const fail=()=>{throw Error('Canonical source image unavailable');};
 if(!data||data.error||!Array.isArray(data.query?.pages)||data.query.pages.length!==1)fail();
 const requested='File:'+file,query=data.query,mappings=new Map();
 for(const name of ['normalized','redirects']){
  const rows=query[name]??[];if(!Array.isArray(rows)||rows.length>8)fail();
  for(const row of rows){
   if(!row||typeof row.from!=='string'||!row.from||typeof row.to!=='string'||!row.to||
      row.from===row.to||row.tofragment||mappings.has(row.from))fail();
   mappings.set(row.from,row.to);
  }
 }
 let resolved=requested;const seen=new Set();
 while(mappings.has(resolved)){
  if(seen.has(resolved)||seen.size>=16)fail();seen.add(resolved);resolved=mappings.get(resolved);
 }
 const page=query.pages[0];
 if(!page||page.invalid||page.ns!==6||page.title!==resolved||
    !['local','shared'].includes(page.imagerepository)||(page.missing&&page.imagerepository!=='shared')||
    !Array.isArray(page.imageinfo)||page.imageinfo.length!==1||mappings.size!==seen.size)fail();
 const info=page.imageinfo[0];
 const filename=title=>typeof title==='string'&&title.includes(':')?title.slice(title.indexOf(':')+1):null;
 if(!info||typeof info!=='object'||Array.isArray(info))fail();
 const selected=filename(page.title);
 const canonical=Object.hasOwn(info,'canonicaltitle')?filename(info.canonicaltitle):selected;
 if(!canonical||canonical!==selected||!Number.isInteger(info.width)||info.width<=0||
    !Number.isInteger(info.height)||info.height<=0||typeof info.mime!=='string')fail();
 let original;try{original=new URL(info.url);}catch{fail();}
 if(original.protocol!=='https:'||original.hostname!=='upload.wikimedia.org'||original.username||original.password||original.hash)fail();
 const parts=original.pathname.split('/');
 const local=parts[1]==='wiktionary'&&parts[2]?.replaceAll('_','-')===edition;
 const shared=parts[1]==='wikipedia'&&parts[2]==='commons';
 if(!(page.imagerepository==='local'?local:shared))fail();
 let uploaded;try{uploaded=decodeURIComponent(parts.at(-1)).replaceAll('_',' ');}catch{fail();}
 if(uploaded!==canonical.replaceAll('_',' '))fail();
 // A missing local description page can still resolve a shared file.
 return {info,canonical_file:canonical,repository:page.imagerepository,requested_title:requested,resolved_title:resolved};
}
export function canonicalImageURL(info,canonicalFile){
 const fail=()=>{throw Error('Unbound canonical image rendition');};
 const fallback=info.thumburl||info.url;
 let source,selected;try{source=new URL(info.url);selected=new URL(fallback);}catch{fail();}
 if(source.origin!=='https://upload.wikimedia.org'||source.username||source.password||source.hash||
    selected.username||selected.password||selected.hash)fail();
 const sameOrigin=selected.origin===source.origin;
 // The retained API response binds this one HTTPS thumbnail service. It is
 // not a general cross-host permission or an HTTP redirect allowance.
 const thumbnailOrigin=selected.origin==='https://thumb.wikimedia.org';
 if(!sameOrigin&&!thumbnailOrigin)fail();
 const sameStaticResource=sameOrigin&&selected.pathname===source.pathname;
 if(!sameStaticResource){
  // Both allowed rendition hosts must carry the complete original repository
  // and upload path, followed by exactly one opaque rendition component.
  const parts=source.pathname.split('/');
  const owner=parts.slice(0,3).join('/')+'/thumb/'+parts.slice(3).join('/')+'/';
  if(!selected.pathname.startsWith(owner)||!selected.pathname.slice(owner.length)||
     selected.pathname.slice(owner.length).includes('/'))fail();
 }

 // Bounded native JPEG case: choose the supplied original only when both URLs
 // identify the identical static upload resource. No thumbwidth/MIME-only or
 // SVG/TIFF/transcoded rendition inference, and no arbitrary query stripping.
 if(info.mime!=='image/jpeg'||!/^.+\.(?:jpg|jpeg)$/i.test(canonicalFile)||!info.thumburl)return fallback;
 let original,thumbnail;try{original=new URL(info.url);thumbnail=new URL(info.thumburl);}catch{return fallback;}
 if(original.protocol!=='https:'||thumbnail.protocol!=='https:'||original.hostname!=='upload.wikimedia.org'||
    original.origin!==thumbnail.origin||original.pathname!==thumbnail.pathname||
    original.pathname.includes('/thumb/')||original.username||thumbnail.username||original.hash||thumbnail.hash)return fallback;
 for(const u of [original,thumbnail]){
  for(const name of ['utm_source','utm_campaign','utm_content'])u.searchParams.delete(name);
  u.searchParams.sort();
 }
 return original.href===thumbnail.href?info.url:fallback;
}
