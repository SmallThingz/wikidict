import assert from 'node:assert/strict';

// Focused browser regression helper. The caller supplies an already-rendered
// compiled entry and a controlled media route; this helper invents no Entry.
export async function verifyTransportAcquisition(page,{label,trigger='click',retry=false,waitHeld,release}){
  const root=page.locator('.inline-audio-control'),audio=root.locator('audio');
  const button=root.locator('button.inline-audio-activate');
  assert.equal(await root.getByRole('button',{name:(retry?'Retry audio: ':'Play audio: ')+label,exact:true}).count(),1);
  assert.equal(await button.isEnabled(),true);
  assert.equal(await audio.getAttribute('src'),null);
  assert.equal(await audio.getAttribute('aria-hidden'),'true');
  assert.equal(await audio.getAttribute('tabindex'),'-1');
  const geometry=()=>root.evaluate(r=>{
    const box=e=>{const {x,y,width,height}=e.getBoundingClientRect();return {x,y,width,height};};
    return {audio:box(r.querySelector('audio')),button:box(r.querySelector('button'))};
  });
  const before=await geometry();
  const initialHit=await button.evaluate(b=>{const r=b.getBoundingClientRect(),hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return hit===b||b.contains(hit);});
  assert(initialHit,'Bootstrap must receive the initial pointer hit');
  for(const key of ['x','y','width','height'])assert(Math.abs(before.audio[key]-before.button[key])<=.5,key);
  await button.evaluate(b=>{
    window.transportGestureEvents=[];
    for(const type of ['keydown','click'])b.addEventListener(type,e=>window.transportGestureEvents.push({type,key:e.key??null,trusted:e.isTrusted}),true);
  });
  if(trigger==='click')await button.click();
  else{assert.equal(trigger,'Enter');await button.focus();await page.keyboard.press('Enter');}
  await waitHeld();
  assert.equal(await root.getAttribute('data-media-state'),'loading');
  assert.equal(await button.getAttribute('aria-busy'),'true');
  assert.equal(await button.getAttribute('aria-disabled'),'true');
  assert.equal(await audio.getAttribute('src'),null);
  assert(await button.evaluate(b=>document.activeElement===b));
  const events=await page.evaluate(()=>window.transportGestureEvents);
  assert(events.some(e=>e.type==='click'&&e.trusted));
  if(trigger==='Enter')assert(events.some(e=>e.type==='keydown'&&e.key==='Enter'&&e.trusted));
  await release();
  await page.waitForFunction(()=>{const a=document.querySelector('.inline-audio-control>audio');return !a.paused&&a.currentTime>.1;});
  assert.equal(await root.locator('button').isHidden(),true);
  assert.equal(await audio.getAttribute('aria-hidden'),null);
  assert.equal(await audio.getAttribute('tabindex'),null);
  assert(await audio.evaluate(a=>document.activeElement===a));
  const after=await geometry();
  const nativeHit=await audio.evaluate(a=>{const r=a.getBoundingClientRect(),hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return {hit:hit===a||a.contains(hit),pointerEvents:getComputedStyle(a).pointerEvents};});
  assert(nativeHit.hit&&nativeHit.pointerEvents!=='none','Native audio must receive pointer hits after bootstrap');
  for(const key of ['x','y','width','height'])assert(Math.abs(before.audio[key]-after.audio[key])<=.5,key);
  return {trigger,before,after,initialHit,nativeHit,events,focus:'bootstrap -> native audio',source:await audio.getAttribute('src')};
}
