import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {entryClue,hitKey,refreshSavedClue} from './preview.js';

const source=await readFile(new URL('app.js',import.meta.url),'utf8');
const openSource=source.match(/async function open\(hit,fragment\)\{[\s\S]*?(?=async function openLink\()/)?.[0];
assert.ok(openSource,'Execute the actual application open flow');
const hit={dictionary:'control',title:'next excerpt'},entry={title:hit.title,sections:[]};

function fixture({saved=[],enabled=true}={}){
 const calls=[],save=Promise.withResolvers(),entered=Promise.withResolvers();
 const previous={title:'previous excerpt'},previousHit={dictionary:'control',title:previous.title};
 const context={renderVersion:0,current:previous,currentHit:previousHit,
  status:(...args)=>calls.push(['status',...args]),readForView:async()=>entry,
  clue:entryClue,key:hitKey,refreshSavedClue,
  state:{settings:{historyLimit:enabled?100:0},saved,history:[]},
  flushSave:()=>{calls.push(['save']);entered.resolve();return save.promise;},
  navigate:route=>calls.push(['navigate',route]),revealFragment:()=>true,entryView:{firstElementChild:null}};
 vm.createContext(context);vm.runInContext(openSource,context);
 return {calls,context,save,entered,previous,previousHit};
}
async function held(options){
 const run=fixture(options);run.opening=run.context.open(hit);await run.entered.promise;
 assert.deepEqual(run.calls,[['status','Opening…'],['save']]);
 assert.equal(run.context.current,run.previous);assert.equal(run.context.currentHit,run.previousHit);
 return run;
}

test('a history commit precedes displaying and bookmarking the new entry',{timeout:1000},async()=>{
 const {calls,context,save,opening}=await held();save.resolve();await opening;
 assert.equal(context.current,entry);assert.equal(context.currentHit,hit);
 assert.deepEqual(calls.at(-1),['navigate','reading']);
});
test('a completed history save cannot reopen a superseded entry',{timeout:1000},async()=>{
 const {calls,context,save,opening,previous,previousHit}=await held();
 context.renderVersion++;save.resolve();await opening;
 assert.equal(context.current,previous);assert.equal(context.currentHit,previousHit);
 assert.deepEqual(calls.at(-1),['save']);
});
test('a superseded history save failure remains visible without reopening',{timeout:1000},async()=>{
 const {calls,context,save,opening,previous}=await held();context.renderVersion++;
 save.reject(new Error('controlled write failure'));await opening;
 assert.equal(context.current,previous);assert.equal(calls.some(c=>c[0]==='navigate'),false);
 assert.deepEqual(calls.at(-1),['status','controlled write failure',true]);
});
test('a history-only save failure permits reading and reports the error',{timeout:1000},async()=>{
 const {calls,context,save,opening}=await held();save.reject(new Error('controlled write failure'));await opening;
 assert.equal(context.current,entry);assert.equal(context.currentHit,hit);
 assert.deepEqual(calls.slice(-2),[['navigate','reading'],['status','controlled write failure',true]]);
});
test('a saved-clue write failure preserves the visible entry',{timeout:1000},async()=>{
 const {calls,context,save,opening,previous,previousHit}=await held({saved:[{...hit,clue:'old'}]});
 assert.equal(context.state.saved[0].clue,entry.title);
 const rejected=assert.rejects(opening,/controlled write failure/);save.reject(new Error('controlled write failure'));await rejected;
 assert.equal(context.current,previous);assert.equal(context.currentHit,previousHit);
 assert.deepEqual(calls.at(-1),['save']);
});
test('history disabled does not write or wait before reading',{timeout:1000},async()=>{
 const {calls,context}=fixture({enabled:false});await context.open(hit);
 assert.deepEqual(calls,[['status','Opening…'],['navigate','reading']]);
 assert.equal(context.state.history.length,0);assert.equal(context.current,entry);
});
