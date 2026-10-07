import {safeURL} from './validate.js';
const CACHE='wikidict-media-v1';
export async function trimMedia(mb){const cache=await caches.open(CACHE),keys=await cache.keys();let total=0;for(let i=keys.length-1;i>=0;i--){const r=await cache.match(keys[i]);total+=(await r.blob()).size;if(total>mb*1024*1024)await cache.delete(keys[i]);}}
export async function clearMedia(){await caches.delete(CACHE);}
export function mediaView(media,settings,sourceEdition){
 const root=document.createElement('details'),summary=document.createElement('summary');summary.textContent=media.caption||media.file;root.append(summary);
 const allowed=media.kind==='image'?settings.allowImages:settings.allowAudio;
 if(!allowed){const note=document.createElement('small');note.textContent='Enable online '+(media.kind==='image'?'images':'audio')+' in Settings.';root.append(note);return root;}
 let loaded=false;
 root.addEventListener('toggle',async()=>{if(!root.open||loaded)return;loaded=true;const note=document.createElement('small');note.textContent='Loading…';root.append(note);
  try{
   const title=media.file.replace(/^(File|Image):/i,'');
   const edition=/^[a-z0-9_-]+wiktionary$/.test(sourceEdition||'')?sourceEdition.slice(0,-10).replaceAll('_','-'):null;
   const hosts=['commons.wikimedia.org'];if(edition)hosts.push(edition+'.wiktionary.org');
   let info,sourceHost;
   for(const host of hosts){
    const url=`https://${host}/w/api.php?action=query&format=json&formatversion=2&origin=*&prop=imageinfo&iiprop=url%7Cextmetadata&iiurlwidth=960&titles=${encodeURIComponent('File:'+title)}`;
    const response=await fetch(url);if(!response.ok)throw Error('Media server unavailable');const data=await response.json();info=data.query?.pages?.[0]?.imageinfo?.[0];if(info){sourceHost=host;break;}
   }
   if(!info)throw Error('Media unavailable');const url=info.thumburl||info.url;
   if(new URL(url).protocol!=='https:')throw Error('Invalid media URL');
   const cacheKey='https://'+sourceHost+'/.wikidict-media-cache?url='+encodeURIComponent(url);
   const cache=await caches.open(CACHE);let response=await cache.match(cacheKey);
   if(!response){response=await fetch(url);if(!response.ok)throw Error('Media download failed');const declared=Number(response.headers.get('content-length'));if(declared>50*1024*1024)throw Error('Media too large');const reader=response.body.getReader(),parts=[];let size=0;try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>50*1024*1024)throw Error('Media too large');parts.push(value);}}finally{await reader.cancel();}response=new Response(new Blob(parts),{headers:{'Content-Type':response.headers.get('content-type')||'application/octet-stream'}});if(settings.mediaCacheMb&&size<=settings.mediaCacheMb*1024*1024){await cache.put(cacheKey,response.clone());await trimMedia(settings.mediaCacheMb);}}
   const blob=await response.blob(),object=URL.createObjectURL(blob),el=document.createElement(media.kind==='image'?'img':'audio');el.src=object;
   if(media.kind==='image'){el.alt=media.caption||media.file;el.loading='lazy';}else el.controls=true;
   root.addEventListener('toggle',()=>{if(!root.open&&el.pause)el.pause();});
   root.append(el);const credit=document.createElement('a');credit.textContent='Source & licence';credit.href=safeURL(info.descriptionurl)||'https://'+sourceHost+'/wiki/File:'+encodeURIComponent(title);credit.target='_blank';credit.rel='noopener';root.append(credit);note.remove();
   const observer=new MutationObserver(()=>{if(!root.isConnected){URL.revokeObjectURL(object);if(el.pause)el.pause();observer.disconnect();}});observer.observe(document.body,{childList:true,subtree:true});
  }catch(error){note.textContent=error.message;loaded=false;}
 });return root;
}
