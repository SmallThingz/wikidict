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
 const root=document.createElement('details'),summary=document.createElement('summary');summary.textContent=media.caption||media.file;root.append(summary);
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
   const edition=/^[a-z0-9_-]+wiktionary$/.test(sourceEdition||'')?sourceEdition.slice(0,-10).replaceAll('_','-'):null;
   const hosts=['commons.wikimedia.org'];if(edition)hosts.push(edition+'.wiktionary.org');
   let info,sourceHost;
   for(const host of hosts){
    const url=`https://${host}/w/api.php?action=query&format=json&formatversion=2&origin=*&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=960&titles=${encodeURIComponent('File:'+title)}`;
    const response=await fetch(url);if(!response.ok)throw Error('Media server unavailable');const data=await response.json();info=data.query?.pages?.[0]?.imageinfo?.[0];if(info){sourceHost=host;break;}
   }
   if(!info)throw Error('Media unavailable');const url=info.thumburl||info.url;
   if(new URL(url).protocol!=='https:')throw Error('Invalid media URL');
   const cacheKey='https://'+sourceHost+'/.wikidict-media-cache?url='+encodeURIComponent(url);
   const cache=await caches.open(CACHE);let response=await cache.match(cacheKey);
   if(!response){response=await fetch(url);if(!response.ok)throw Error('Media download failed');const declared=Number(response.headers.get('content-length'));if(declared>50*1024*1024)throw Error('Media too large');const reader=response.body.getReader(),parts=[];let size=0;try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>50*1024*1024)throw Error('Media too large');parts.push(value);}}finally{await reader.cancel();}response=new Response(new Blob(parts),{headers:{'Content-Type':response.headers.get('content-type')||'application/octet-stream'}});if(settings.mediaCacheMb&&size<=settings.mediaCacheMb*1024*1024){await cache.put(cacheKey,response.clone());await trimMedia(settings.mediaCacheMb);}}
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
 const showStatus=(state,message)=>{
  el.dataset.mediaState=state;el.hidden=true;el.style.display='none';if(!el.isConnected)return;
  if(!status){
   status=document.createElement('span');status.className='compiled-image-status';status.setAttribute('role','img');status.style.display='inline-block';status.style.boxSizing='border-box';status.style.verticalAlign='middle';status.dir='auto';
   if(image.alt){status.textContent=image.alt;status.style.fontSize='var(--wikidict-normal-body-size, 1rem)';}
   else {
    const icon=occurrence.intrinsic_size?document.createElement('span'):status;
    icon.style.cssText+=';display:inline-block;box-sizing:border-box;width:15px;height:15px;border:1px dotted currentColor';
    if(icon!==status){icon.setAttribute('aria-hidden','true');status.append(icon);}
   }
   if(occurrence.intrinsic_size){
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
