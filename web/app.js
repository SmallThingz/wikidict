import {renderEntry} from './renderer.js';
const $ = id => document.getElementById(id);
let entries = [], selected = null, importer = null;
const status = (text, error = false) => { $('status').textContent = text; $('status').classList.toggle('error',error); };
function select(entry) { selected=entry; $('entry').replaceChildren(renderEntry(entry,openLink)); $('matches').hidden=true; $('query').value=''; status(''); window.scrollTo({top:0,behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'}); }
function openLink(target) {
  const [title, anchor] = target.split('#');
  if (title) { const next=entries.find(e=>e.title===title.replaceAll('_',' ')); if (!next) {status(`“${title}” is not in this dictionary.`);return;} select(next); }
  if (anchor) document.getElementById(anchor)?.scrollIntoView({block:'start',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});
}
function open(file) {
  if (!file) return; importer?.terminate(); const worker = new Worker('./import-worker.js',{type:'module'}); importer = worker; status('Opening dictionary…');
  worker.onmessage = ({data}) => {
    if (importer !== worker) return;
    worker.terminate(); importer=null;
    if (data.error) {status(data.error,true);return;}
    entries=data.value.entries; $('query').disabled=!entries.length;
    if(entries.length) select(entries[0]); else {selected=null;$('entry').replaceChildren();status('This dictionary has no entries.');}
  };
  worker.onerror = () => {if(importer!==worker)return;worker.terminate();importer=null;status('Could not open the dictionary.',true);};
  worker.postMessage(file);
}
$('file').addEventListener('change',()=>{open($('file').files[0]);$('file').value='';});
$('open').onclick=()=>$('file').click(); $('begin').onclick=()=>$('file').click();
let queryVersion=0;
$('query').addEventListener('input',()=>{
  const version=++queryVersion;
  requestAnimationFrame(()=>{if(version!==queryVersion)return;
    const query=$('query').value.trim().toLocaleLowerCase();
    if(!query){$('matches').hidden=true;status('');return;}
    const found=[]; for(const entry of entries){if(entry.title.toLocaleLowerCase().includes(query))found.push(entry);if(found.length===80)break;}
    $('matches').replaceChildren(...found.map(entry=>{const b=document.createElement('button');b.textContent=entry.title;const small=document.createElement('small');small.textContent=entry.language||entry.kind;b.append(small);b.onclick=()=>select(entry);return b;}));
    $('matches').hidden=false;status(found.length?'':`No matches for “${$('query').value}”.`);
  });
});
const theme=localStorage.getItem('dict.theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'); document.documentElement.dataset.theme=theme;
$('theme').onclick=()=>{const value=document.documentElement.dataset.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=value;localStorage.setItem('dict.theme',value);};
