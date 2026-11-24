import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {buildIndex,decode} from './blob.js';
import {openSource} from './xz.js';

const file='LL-Q33190 (bug)-Iripseudocorus-Babbua.wav';
const credit='Berkas:'+file;
const findPlay=entry=>entry.sections.flatMap(section=>section.blocks).flatMap(block=>block.spans||[]).find(span=>span.audio_control);
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');

export async function verifyPhonos(page,bundle,asset,stylesheet) {
  const source=await openSource(new Blob([await readFile(asset)]));
  const {metadata,rows}=await buildIndex(source);
  assert.equal(rows.length,1);
  const row=rows[0];
  assert.equal(row.title,'babua');
  const bytes=Buffer.from(await source.read(row.offset,row.length));
  const meta={...metadata,title:row.title,source_edition:'idwiktionary'};
  const entry=decode(bytes,meta),play=findPlay(entry);
  const prior=await openSource(new Blob([await readFile(new URL('../../android/app/src/androidTest/assets/babua/heading.wikblb.xz',import.meta.url))]));
  const priorIndex=await buildIndex(prior),priorRow=priorIndex.rows[0];
  const old=decode(await prior.read(priorRow.offset,priorRow.length),meta);
  assert.equal(findPlay(old),undefined);
  assert.deepEqual(entry.sections.map(s=>s.heading_style),old.sections.map(s=>s.heading_style));
  assert.equal(entry.sections.length,2);
  assert.equal(entry.sections[1].blocks.length,6);
  assert.equal(entry.sections[1].anchor,'babua_[bug]');
  assert.equal(play.audio_control.presentation,'phonos_button');
  assert.equal(play.target,'File:'+file);
  assert.equal(play.text,'Suara');
  assert.equal(play.tooltip,'Putar audio');
  assert.equal(play.language,'bug');
  const originalBlock=entry.sections.flatMap(section=>section.blocks).find(block=>block.spans?.includes(play));
  const next=originalBlock.spans[originalBlock.spans.indexOf(play)+1];
  assert.equal(next.text,'ⓘ');
  assert.equal(next.target,credit);
  assert.equal(next.superscript,true);
  assert.equal(next.audio_control,undefined);
  assert.equal(entry.media.find(item=>item.file===file)?.caption,'Suara');
  // Resolve the local presence/flag from the original source tooltip boundary.
  const tooltip=Buffer.from(play.tooltip);
  const after=bytes.indexOf(tooltip)+tooltip.length;
  assert.ok(after>=tooltip.length&&bytes.indexOf(tooltip,after)===-1);
  // Ruby, padding and action presence, then the optional inline-box presence.
  const at=after+3+(bytes.readUInt16LE(4)&4?1:0)+1;
  assert.equal(bytes[at-1],1);
  assert.equal(bytes[at]&8,8);
  const edited=(i,value)=>{const copy=Buffer.from(bytes);copy[i]=value;return copy;};
  const transport=decode(edited(at,bytes[at]&~8),meta);
  assert.equal(findPlay(transport).audio_control.presentation,undefined);
  for(const flag of [16,9,10,255])assert.throws(()=>decode(edited(at,flag),meta));
  assert.throws(()=>decode(bytes.subarray(0,at),meta));
  assert.throws(()=>decode(edited(5,bytes[5]|128),meta));
  const ownerHex=Buffer.from(file).toString('hex');
  const owner=bytes.indexOf('wikidict-media-file-'+ownerHex)+'wikidict-media-file-'.length;
  assert.ok(owner>='wikidict-media-file-'.length);
  assert.throws(()=>decode(edited(owner,bytes[owner]===48?49:48),meta),/audio control/);

  const icon=await readFile(new URL('../../renderer/assets/phonos/volumeUp.svg',import.meta.url));
  assert.equal(digest(icon),'66052ea76d7a8af33585fd70ac00949b9dd0a4b42f06489044a7005a99dd45f7');
  const css=stylesheet??await readFile(new URL('style.css',import.meta.url),'utf8');
  const font=await readFile(new URL('reader.ttf',import.meta.url));
  const refused=[];
  await page.route('**/*',async route=>{
    const url=route.request().url();
    if(url==='https://reader.test/')return route.fulfill({body:'<!doctype html><html><body><main></main></body></html>',contentType:'text/html'});
    if(url==='https://reader.test/assets/phonos/volumeUp.svg')return route.fulfill({body:icon,contentType:'image/svg+xml'});
    if(url==='https://reader.test/reader.ttf')return route.fulfill({body:font,contentType:'font/ttf'});
    refused.push(url);
    return route.abort();
  });
  await page.goto('https://reader.test/');
  await page.addScriptTag({content:bundle});
  await page.addStyleTag({content:css});
  await page.evaluate(({entry,transport,file})=>{
    window.activated=[];
    window.remount=(on,generic=false)=>{
      const settings={allowAudio:on,mediaCacheMb:0,collapseOtherSections:false};
      const rendered=Renderer.renderEntry(generic?transport:entry,target=>window.activated.push(target),settings);
      document.querySelector('main').replaceChildren(rendered);
      document.querySelectorAll('details').forEach(d=>{d.open=true;});
    };
    window.localFetches=[];
    window.fetchMode='error';
    // Intercept at the fetch boundary, including settings and exact catalog title.
    window.fetch=async input=>{
      const url=new URL(input);
      window.localFetches.push(url.toString());
      if(url.pathname==='/w/api.php'&&url.searchParams.get('titles')==='File:'+file)
        return new Promise((resolve,reject)=>{window.releaseAudio=()=>{
          if(window.fetchMode==='error')reject(Error('Controlled offline source failure'));
          else resolve(Response.json({query:{pages:[{imageinfo:[{url:'https://media.test/controlled.wav',thumburl:'https://media.test/poster.png',mime:'audio/wav'}]}]}}));
        };});
      if(url.href==='https://media.test/controlled.wav'){
        // An independent eight-second silent PCM fixture exercises the real browser transport.
        const samples=64000,pcm=new Uint8Array(44+samples*2),view=new DataView(pcm.buffer);
        const text=(offset,s)=>pcm.set(new TextEncoder().encode(s),offset);
        text(0,'RIFF');view.setUint32(4,pcm.length-8,true);text(8,'WAVEfmt ');
        view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);
        view.setUint32(24,8000,true);view.setUint32(28,16000,true);view.setUint16(32,2,true);view.setUint16(34,16,true);
        text(36,'data');view.setUint32(40,samples*2,true);
        return new Response(window.fetchMode==='decode-error'?new Uint8Array([0]):pcm,{headers:{'Content-Type':'audio/wav'}});
      }
      throw Error('Unexpected media acquisition');
    };
    window.remount(false);
  },{entry,transport,file});
  const button=page.getByRole('button',{name:'Putar audio',exact:true}),link=page.getByRole('link',{name:'ⓘ',exact:true});
  const heading=page.locator('.compiled-heading-outer');
  assert.equal(await heading.count(),1);
  assert.equal(await heading.evaluate(el=>getComputedStyle(el).borderTopStyle),'dashed');
  assert.equal(await heading.locator('.compiled-heading-title').textContent(),'babua [bug]');
  assert.equal(await button.isDisabled(),true);
  assert.equal(await button.textContent(),'Suara');
  assert.equal(await button.getAttribute('lang'),'bug');
  assert.equal(await link.count(),1);
  await link.click();
  assert.deepEqual(await page.evaluate(()=>window.activated),[credit]);
  assert.deepEqual(await page.evaluate(()=>window.localFetches),[]);
  await page.evaluate(()=>window.remount(true));
  const geometry=await button.evaluate(async el=>{
    const icon=el.querySelector('img');
    await icon.decode();
    const {width,height}=icon.getBoundingClientRect(),style=getComputedStyle(el);
    return {width,height,em:parseFloat(style.fontSize),margin:getComputedStyle(el.querySelector('.phonos-label')).marginInlineStart,
      iconWidth:icon.naturalWidth,title:el.title,tabIndex:el.tabIndex,independent:!el.closest('a')};
  });
  // Chromium reports painted CSS boxes on a 1/64-pixel grid.
  assert.ok(Math.abs(geometry.width-geometry.em)<=1/64);
  assert.equal(geometry.height,geometry.width);
  assert.equal(geometry.margin,'2px');
  assert.equal(geometry.iconWidth,20);
  assert.equal(geometry.title,'Putar audio');
  assert.equal(geometry.tabIndex,0);
  assert.ok(geometry.independent);
  await button.focus();
  await page.keyboard.press('Enter');
  await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='loading');
  await page.keyboard.press('Space');
  assert.equal(await page.evaluate(()=>window.localFetches.length),1);
  await page.evaluate(()=>window.releaseAudio());
  await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='error');
  await page.evaluate(()=>{window.fetchMode='decode-error';window.releaseAudio=null;});
  await button.press('Space');
  await page.waitForFunction(()=>typeof window.releaseAudio==='function');
  await page.evaluate(()=>window.releaseAudio());
  await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='error');
  await page.evaluate(()=>{window.fetchMode='ok';window.releaseAudio=null;});
  await button.press('Enter');
  await page.waitForFunction(()=>typeof window.releaseAudio==='function');
  await page.evaluate(()=>window.releaseAudio());
  await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='playing');
  assert.equal(await button.getAttribute('aria-pressed'),'true');
  await button.press('Space');
  await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='paused');
  assert.equal(await button.evaluate(el=>el.matches(':focus-visible')),true);
  await page.keyboard.press('Tab');
  assert.equal(await link.evaluate(el=>el===document.activeElement),true);
  await page.keyboard.press('Enter');
  assert.deepEqual(await page.evaluate(()=>window.activated),[credit,credit]);
  await page.evaluate(()=>window.remount(false,true));
  assert.equal(await button.count(),0);
  assert.equal(await page.locator('.inline-audio-control audio[controls]').count(),1);
  assert.equal(await link.count(),1);
  assert.deepEqual(refused,[]);
  await page.evaluate(()=>window.remount(false));
  return {title:row.title,payloadBytes:row.length,payloadSHA256:digest(bytes),features:bytes.readUInt16LE(4),
    flagsAt:at,localFlags:bytes[at],file,credit,geometry,localFetches:await page.evaluate(()=>window.localFetches)};
}
