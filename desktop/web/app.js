import {linkTargetParts,bookSourcesURL,isBookSourcesTitle} from './validate.js';
import {renderEntry,revealFragment,validateInlineDestinationLayout} from './renderer.js';
import {entryClue as clue,hitKey as key,refreshSavedClue} from './preview.js';
import {mediaView,trimMedia,clearMedia,loadInlineImage,inlineImageActionURL} from './media.js';
const $=id=>document.getElementById(id),panel=$('panel'),entryView=$('entry');
const worker=new Worker('./import-worker.js',{type:'module'}),pending=new Map();let sequence=0;
worker.onmessage=({data})=>{const p=pending.get(data.id);if(p){pending.delete(data.id);data.error?p.reject(Error(data.error)):p.resolve(data.value);}};
const call=(type,args={})=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});worker.postMessage({id,type,args});});
const defaults={darkMode:'system',historyLimit:100,mediaCacheMb:100,quizLength:10,collapsePronunciation:true,collapseEtymology:true,collapseOtherSections:true,allowImages:false,allowAudio:false,randomPool:'all'};
let state={history:[],saved:[],scores:{},settings:{...defaults},sources:[]},page='search',current=null,currentHit=null,libraries=[],searchVersion=0,renderVersion=0;
const node=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
const button=(text,label,action,cls)=>{const b=node('button',text,cls);b.type='button';b.setAttribute('aria-label',label||text);b.onclick=()=>performAction(action);return b;};
const status=(text,error=false)=>{$('status').textContent=text;$('status').classList.toggle('error',error);};
// Invoke the action before awaiting so Import keeps direct user-gesture timing.
async function performAction(action){try{return await action();}catch(error){status(error.message,true);}}
// Only obsolete read failures belong to an abandoned view; mutation/save errors still surface.
async function readForView(type,args,isCurrent){try{return await call(type,args);}catch(error){if(isCurrent())throw error;}}
let saveTimer;function flushSave(){clearTimeout(saveTimer);saveTimer=null;return call('saveState',state);}
function save(){clearTimeout(saveTimer);saveTimer=setTimeout(()=>flushSave().catch(e=>status(e.message,true)),80);}
function theme(){document.documentElement.dataset.theme=state.settings.darkMode==='system'?(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'):state.settings.darkMode;}
function title(text){panel.append(node('h1',text));}
function navigate(next){return performAction(()=>{page=next;renderVersion++;panel.replaceChildren();entryView.replaceChildren();status('');$('dock').classList.remove('away');document.querySelectorAll('[data-page]').forEach(b=>{const active=b.dataset.page===next||(next==='reading'&&b.dataset.page==='search')||(next==='dictionaries'&&b.dataset.page==='settings');b.setAttribute('aria-current',active?'page':'false');});window.scrollTo(0,0);speechSynthesis.cancel();
 if(next==='search')return search();else if(next==='history'||next==='saved')return wordList(next);else if(next==='learn')return learn();else if(next==='settings')return settings();else if(next==='dictionaries')return dictionaries();else if(next==='reading')return renderWord();
});}
async function open(hit,fragment){if(!hit)return;const version=++renderVersion;status('Opening…');const value=await readForView('read',hit,()=>version===renderVersion);if(version!==renderVersion)return;
 const preview=clue(value),saved=refreshSavedClue(state.saved,hit,preview),savedChanged=saved!==state.saved;state.saved=saved;
 const remember=state.settings.historyLimit>0;
 if(remember){const item={...hit,clue:preview,at:Date.now()};state.history=[item,...state.history.filter(x=>key(x)!==key(hit))].slice(0,state.settings.historyLimit);}
 let historyError;
 if(savedChanged)await flushSave();
 else if(remember){
  try{await flushSave();}
  catch(error){historyError=error.message;}
 }
 if(version!==renderVersion){
  if(historyError)status(historyError,true);
  return;
 }
 current=value;currentHit=hit;
 navigate('reading');
 if(historyError)status(historyError,true);
 if(!revealFragment(entryView,fragment===undefined?(value.redirect?.followed?value.redirect.fragment:''):fragment)&&entryView.firstElementChild)
  entryView.focus({preventScroll:true});
}
async function openLink(target,targetFragment){const {title:name,fragment:anchor}=linkTargetParts(target,targetFragment);if(isBookSourcesTitle(name)){const url=bookSourcesURL(target,current?.source_edition,targetFragment);if(url)window.open(url,'_blank','noopener,noreferrer');else status('Source edition is unavailable for this link.');return;}if(name){const version=++renderVersion,isCurrent=()=>page==='reading'&&version===renderVersion;const hit=await readForView('exact',{title:targetFragment==null?name.replaceAll('_',' '):name,context:current?.navigation_context||currentHit?.context||currentHit?.dictionary},isCurrent);if(!isCurrent())return;if(!hit){status('Word is not installed in this dictionary.');return;}await open(hit,anchor);}else revealFragment(entryView,anchor);}
function speak(){if(!current)return;const lang=current.language_code;if(!lang||lang==='und'){status('No language is identified for offline pronunciation.');return;}const voices=speechSynthesis.getVoices().filter(v=>v.localService&&v.lang.split('-')[0]===lang.split('-')[0]);const voice=voices.find(v=>v.default)||voices.find(v=>v.lang===navigator.language)||voices[0];if(!voice){status('No offline voice for this language is installed.');return;}speechSynthesis.cancel();const speech=new SpeechSynthesisUtterance(current.title);speech.voice=voice;speech.lang=voice.lang;speechSynthesis.speak(speech);}
function renderWord(){
 if(!current){navigate('search');return;}
 const actions=node('div',undefined,'word-actions'),saved=state.saved.some(x=>key(x)===key(currentHit));
 const bookmark=button(saved?'◆':'◇','Bookmark',async()=>{
  if(bookmark.getAttribute('aria-disabled')==='true')return;
  const previous=state.saved,exists=state.saved.some(x=>key(x)===key(currentHit));
  const updated=exists?state.saved.filter(x=>key(x)!==key(currentHit)):[{...currentHit,clue:clue(current)},...state.saved];
  state.saved=updated;
  bookmark.setAttribute('aria-disabled','true');
  try{await flushSave();bookmark.textContent=exists?'◇':'◆';bookmark.setAttribute('aria-pressed',String(!exists));}
  catch(error){if(state.saved===updated)state.saved=previous;throw error;}
  finally{bookmark.removeAttribute('aria-disabled');}
 });
 bookmark.setAttribute('aria-pressed',String(saved));
 actions.append(button('◖','Pronounce word offline',speak),bookmark);
 entryView.append(actions,renderEntry(current,(target,targetFragment)=>performAction(()=>openLink(target,targetFragment)),state.settings,(m,canonicalIdentity)=>mediaView(m,state.settings,current.source_edition,canonicalIdentity),(el,image,occurrence)=>loadInlineImage(el,image,state.settings,current.source_edition,occurrence),(target,targetFragment)=>inlineImageActionURL(target,current.source_edition,targetFragment)));
 validateInlineDestinationLayout(entryView);
}
function search(){title('Find a word');const input=node('input');input.id='query';input.type='search';input.placeholder='Search your dictionaries';input.setAttribute('aria-label','Find a word');const matches=node('div',undefined,'word-list');matches.id='matches';panel.append(input,matches);input.focus();
 const update=async()=>{const version=++searchVersion;const hits=await readForView('search',{query:input.value.trim()},()=>page==='search'&&version===searchVersion);if(page!=='search'||version!==searchVersion)return;matches.replaceChildren(...hits.map(h=>wordButton(h)));status(hits.length?'':libraries.length?'No matches.':'Add a dictionary in Settings.');};input.oninput=()=>{renderVersion++;return performAction(update);};return update();
}
function sourceLabel(item){const edition=item.source_edition||libraries.find(d=>d.id===(item.context||item.dictionary))?.source_edition;return edition?' · '+edition.slice(0,-10).replaceAll('_','-')+'.wiktionary.org':'';}
function wordButton(hit){const b=button(hit.title,'Open '+hit.title,()=>open(hit),'word');b.append(node('small',(hit.language||hit.kind)+sourceLabel(hit)));if(hit.clue)b.append(node('p',hit.clue));return b;}
function wordList(which){title(which==='history'?'History':'Saved');const list=node('div',undefined,'word-list');for(const hit of state[which]){const row=node('div',undefined,'word-row');row.append(wordButton(hit),button('×','Remove '+hit.title,()=>{state[which]=state[which].filter(x=>key(x)!==key(hit));save();navigate(which);}));list.append(row);}panel.append(list);if(!state[which].length)panel.append(node('p',which==='history'?'Words you open will appear here.':'Bookmark a word to keep it here.'));}
function toggle(label,field){const row=node('label',undefined,'preference'),input=node('input');input.type='checkbox';input.checked=state.settings[field];input.setAttribute('role','switch');input.onchange=()=>{state.settings[field]=input.checked;save();};row.append(node('span',label),input);panel.append(row);}
function slider(label,field,max,log,min=0){const row=node('label',undefined,'slider'),head=node('span'),value=node('output'),input=node('input');input.type='range';input.min=log?0:min;input.max=log?1:max;input.step=log?'any':1;input.value=log?Math.log1p(state.settings[field])/Math.log1p(max):state.settings[field];input.setAttribute('aria-label',label);
 const number=()=>log?Math.round(Math.expm1(Number(input.value)*Math.log1p(max))):Number(input.value);
 const show=()=>{const n=number();value.textContent=n===0?'Off':field==='mediaCacheMb'?(n>=1024?(n/1024).toFixed(1)+' GB':n+' MB'):n.toLocaleString();};input.oninput=show;input.onchange=()=>{state.settings[field]=number();if(field==='historyLimit'&&number()>0)state.history=state.history.slice(0,number());if(field==='mediaCacheMb')trimMedia(number()).catch(e=>status(e.message,true));save();};show();head.append(node('span',label),value);row.append(head,input);panel.append(row);}
function segments(values,selected,action){const row=node('div',undefined,'segments');for(const value of values){const b=button(value,value,()=>action(value));b.setAttribute('aria-pressed',value===selected);row.append(b);}return row;}
function settings(){title('Settings');panel.append(button('Dictionaries →','Dictionaries',()=>navigate('dictionaries'),'wide-link'));panel.append(node('h2','Atmosphere'),segments(['system','light','dark'],state.settings.darkMode,value=>{state.settings.darkMode=value;theme();save();navigate('settings');}));
 panel.append(node('h2','Start folded'));for(const [label,field] of [['Pronunciation','collapsePronunciation'],['Etymology','collapseEtymology'],['Other sections','collapseOtherSections']])toggle(label,field);
 panel.append(node('h2','Images & sound'));toggle('Load images online','allowImages');toggle('Play online audio','allowAudio');slider('Media cache','mediaCacheMb',4096,true);panel.append(button('Clear cached media','Clear cached media',clearMedia));
 panel.append(node('h2','Your trail'));slider('Remember words','historyLimit',100000,true);panel.append(button('Clear history','Clear history',()=>{state.history=[];save();status('History cleared.');}));
 panel.append(node('h2','A little practice'));slider('Questions per round','quizLength',50,false,3);panel.append(segments(['all','history','saved'],state.settings.randomPool,value=>{state.settings.randomPool=value;save();navigate('settings');}),button('Reset scores','Reset scores',()=>{state.scores={};save();status('Scores reset.');}));
}
async function refresh(){libraries=await call('list');}
async function importFile(file){if(!file)return;status('Indexing dictionary…');await call('import',{file});await refresh();navigate('dictionaries');}
$('file').onchange=()=>{importFile($('file').files[0]).catch(e=>status(e.message,true));$('file').value='';};
function parseList(text){if(text.length>2*1024*1024)throw Error('Catalogue too large');return text.split(/\r?\n/).map(s=>s.trim()).filter(s=>s&&!s.startsWith('#')).map(line=>{const [url,label,bytes,sha256,...extra]=line.split('\t'),u=new URL(url);if(u.protocol!=='https:'||u.username||u.password||extra.length||sha256&&!/^[a-f0-9]{64}$/i.test(sha256)||bytes&&(!Number.isSafeInteger(+bytes)||+bytes<=0))throw Error('Invalid catalogue row');return {url,label:label||u.pathname.split('/').pop(),bytes:bytes?+bytes:null,sha256};});}
function browserLink(label,url){const a=node('a',label);a.href=url;a.target='_blank';a.rel='noopener noreferrer';return a;}
function catalogueDownloads(url){const u=new URL(url),match=u.hostname==='github.com'&&/^\/([^/]+)\/([^/]+)\/releases\/(?:latest\/download\/[^/]+|download\/([^/]+)\/[^/]+)$/.exec(u.pathname);return match?u.origin+'/'+match[1]+'/'+match[2]+'/releases/'+(match[3]?'tag/'+match[3]:'latest'):url;}
let catalogueVersion=0;
async function dictionaries(){title('Dictionaries');panel.append(button('↥ Import dictionary','Import dictionary',()=>$('file').click()));for(const d of libraries){const row=node('div',undefined,'word-row');row.append(node('p',`${d.language||d.kind} · ${d.count.toLocaleString()} words · ${(d.bytes/1024/1024).toFixed(1)} MB${sourceLabel(d)}`),button('×','Remove '+(d.language||d.kind),async()=>{await call('remove',{id:d.id});await refresh();navigate('dictionaries');}));panel.append(row);}
 panel.append(node('p','Download the individual .wikblb or .wikblb.xz dictionary files in your browser, keep their filenames, then import them here.'));
 panel.append(node('h2','Catalogue sources'));for(const source of state.sources){const row=node('div',undefined,'word-row'),info=node('div');info.append(node('small',source),node('br'),browserLink('Open downloads in browser',catalogueDownloads(source)));row.append(info,button('×','Remove source',()=>{state.sources=state.sources.filter(x=>x!==source);save();navigate('dictionaries');}));panel.append(row);}
 const input=node('input');input.type='url';input.placeholder='https://…/dictionaries.list';input.setAttribute('aria-label','Catalogue URL');panel.append(input,button('+ Add list','Add list',()=>{const u=new URL(input.value);if(u.protocol!=='https:'||u.username||u.password)throw Error('Use an HTTPS URL');state.sources=[...new Set([...state.sources,u.href])];save();navigate('dictionaries');}));
 const available=node('div');panel.append(button('↻ Refresh lists','Refresh lists',async()=>{const version=++catalogueVersion;available.replaceChildren();for(const url of state.sources){try{const response=await fetch(url);if(!response.ok)throw Error('Catalogue unavailable ('+response.status+')');const items=parseList(await response.text());if(version!==catalogueVersion||page!=='dictionaries')return;for(const item of items)available.append(button('↓ '+item.label,'Download '+item.label,()=>download(item),'wide-link'));}catch(e){available.append(node('small',e.message));}}}),available);
}
async function download(item){status('Downloading '+item.label+'…');let response;try{response=await fetch(item.url);}catch{status('Download unavailable here. Use the browser download, then import the file.');panel.append(browserLink('Download '+item.label+' in browser',item.url));return;}if(!response.ok)throw Error('Download failed ('+response.status+')');const declared=Number(response.headers.get('content-length'));if(item.bytes&&declared&&declared!==item.bytes)throw Error('Size mismatch');const bytes=await response.blob();if(item.bytes&&bytes.size!==item.bytes)throw Error('Size mismatch');const name=decodeURIComponent(new URL(item.url).pathname.split('/').pop());const file=new File([bytes],name||item.label,{type:bytes.type});status('Verifying and indexing…');await call('import',{file,sha256:item.sha256});await refresh();navigate('dictionaries');}
let game='Cards';
async function learn(){const version=renderVersion;title('Learn');panel.append(segments(['Quiz','Cards','Scramble'],game,value=>{game=value;navigate('learn');}));const area=node('div',undefined,'practice');panel.append(area);let pool=state.settings.randomPool==='history'?state.history:state.settings.randomPool==='saved'?state.saved:[...state.history,...state.saved];if(state.settings.randomPool==='all'){for(let i=0;i<16;i++){const h=await readForView('random',{},()=>page==='learn'&&version===renderVersion);if(page!=='learn'||version!==renderVersion)return;if(h)pool.push(h);}}pool=[...new Map(pool.map(x=>[key(x),x])).values()];if(version!==renderVersion)return;if(!pool.length){area.append(node('p','Add a dictionary or open some words first.'));return;}
 let round=0,right=0,last=null;
 const next=async()=>{const choices=pool.filter(h=>key(h)!==last),hit=(choices.length?choices:pool)[Math.floor(Math.random()*(choices.length||pool.length))];const word=await readForView('read',hit,()=>page==='learn'&&version===renderVersion);if(page!=='learn'||version!==renderVersion)return;last=key(hit);area.replaceChildren();if(game==='Quiz'&&round>=state.settings.quizLength){area.append(node('h2',`${right} / ${round}`),button('Another round','Another round',()=>{round=0;right=0;return next();}));return;}
  const answer=ok=>{const s=state.scores[key(hit)]||{right:0,wrong:0};s[ok?'right':'wrong']++;state.scores[key(hit)]=s;save();round++;if(ok)right++;};
  if(game==='Cards'){
   let shown=false;const card=button('',word.title,()=>{shown=!shown;updateCard();},'flashcard'),actions=node('div',undefined,'segments');
   const updateCard=()=>{const action=shown?'Hide meaning':'Reveal meaning';card.replaceChildren(node('h2',word.title),node('p',shown?clue(word):'Recall the meaning, then tap to reveal.'));card.setAttribute('aria-label',`${word.title}. ${shown?clue(word)+'. ':''}${action}`);card.setAttribute('aria-expanded',String(shown));actions.hidden=!shown;};
   let answered=false,advancing=false;
   const advance=async ok=>{if(advancing)return;if(!answered){answered=true;answer(ok);}advancing=true;card.disabled=again.disabled=gotIt.disabled=retry.disabled=true;status('Loading next card…');try{await next();if(page==='learn'&&version===renderVersion){status('');area.querySelector('.flashcard')?.focus();}}catch(error){card.disabled=false;retry.hidden=false;retry.disabled=false;retry.focus();throw error;}finally{advancing=false;}};
   const again=button('Again','Again',()=>advance(false)),gotIt=button('Got it','Got it',()=>advance(true)),retry=button('Retry','Retry next card',()=>advance());retry.hidden=true;
   updateCard();actions.append(again,gotIt,retry,button('Read','Read',()=>open(hit)));area.append(card,actions);
  }
  else if(game==='Quiz'){area.append(node('p',`${right} correct · ${round} of ${state.settings.quizLength}`),node('h2',clue(word)));const options=[hit,...pool.filter(x=>key(x)!==key(hit)).sort(()=>Math.random()-.5).slice(0,3)].sort(()=>Math.random()-.5);let answered=false;for(const option of options)area.append(button(option.title,option.title,()=>{if(answered)return;answered=true;const ok=key(option)===key(hit);answer(ok);area.append(node('p',ok?'Correct.':'Answer: '+hit.title),button('Next','Next',next));}));}
   else{if(typeof Intl.Segmenter!=='function'){area.append(node('p','Scramble is unavailable in this browser. Choose Quiz or Cards.'));return;}const letters=Array.from(new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(word.title),part=>part.segment);area.append(node('h2',letters.reverse().join('')),node('p',clue(word)));const input=node('input');input.setAttribute('aria-label','Your answer');let answered=false;area.append(input,button('Check','Check',()=>{if(answered)return;answered=true;const ok=input.value.trim().normalize('NFC').toLocaleLowerCase()===word.title.normalize('NFC').toLocaleLowerCase();answer(ok);area.append(node('p',ok?'Correct.':'Answer: '+word.title),button('Next','Next',next));}));}
 };await next();}
for(const b of document.querySelectorAll('[data-page]'))b.onclick=()=>navigate(b.dataset.page);
let lastY=0,travel=0;window.addEventListener('scroll',()=>{const y=window.scrollY,delta=y-lastY;lastY=y;if(page!=='reading')return;if(delta*travel<0)travel=0;travel+=delta;if(y===0)$('dock').classList.remove('away');else if(Math.abs(travel)>20){$('dock').classList.toggle('away',travel>0);travel=0;}},{passive:true});
try{const stored=await call('state');state={...state,...stored,settings:{...defaults,...stored.settings}};theme();await refresh();navigate(libraries.length?'search':'dictionaries');}catch(e){status(e.message,true);}
