import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {buildIndex,decode} from './blob.js';
import {openSource} from './xz.js';

const file='LL-Q33190 (bug)-Iripseudocorus-Babbua.wav';
const credit='Berkas:'+file;
const findPlay=entry=>entry.sections.flatMap(section=>section.blocks).flatMap(block=>block.spans||[]).find(span=>span.audio_control);
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');

export async function verifyPhonos(page,bundle,asset,stylesheet,description=false) {
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
  const originalHeadings=old.sections.map(s=>s.heading_style);
  const currentHeadings=structuredClone(entry.sections.map(s=>s.heading_style));
  if(description){
    const stroke=currentHeadings[1].wrappers.outer.border.edges.top.dashed;
    assert.deepEqual(stroke.color,{light_dark:{light:'#a2a9b1',dark:'#72777d'}});
    stroke.color={rgb:stroke.color.light_dark.light};
  }
  assert.deepEqual(currentHeadings,originalHeadings);
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
  const bodies=description?await verifyDescription(page,bytes,meta):null;
  const iconPaint=description?await verifyPhonosPaint(page):null;
  return {bodies,iconPaint,title:row.title,payloadBytes:row.length,payloadSHA256:digest(bytes),features:bytes.readUInt16LE(4),
    flagsAt:at,localFlags:bytes[at],file,credit,geometry,localFetches:await page.evaluate(()=>window.localFetches)};
}

async function verifyDescription(page,bytes,metadata){
  assert.equal(digest(bytes),'57612f152e6722cbc444fa2985e4a9a48be4ca5de0bed0bed134d5abe49f37ba');
  // Dimension and paint oracles from the separately captured original page in both schemes.
  const states={};
  for(const theme of ['light','dark']){
    const result=await page.evaluate(theme=>{
      document.documentElement.dataset.theme=theme;
      document.documentElement.style.setProperty('--wikidict-normal-body-size','16px');
            const frame=document.querySelector('.compiled-heading-outer');
      const section=frame.closest('details'),summary=frame.closest('summary');
      const leaves=[...section.querySelectorAll('*')];
      const leaf=text=>leaves.find(el=>el.childElementCount===0&&el.textContent===text);
      const targets=[['heading',frame],['audio',section.querySelector('.phonos-control button')],
        ['info',leaf('ⓘ')],['term',leaf('Nomina')],['definition',leaf('perut')],['example',leaf('Maloppo ')]];
      const bodyOrder=targets.map(([name,node])=>[name,leaves.indexOf(node)]).filter(([,index])=>index>=0).sort((a,b)=>a[1]-b[1]).map(([name])=>name);
      const [shell,parent,label]=[frame,summary,leaf('babua')].map(el=>el.getBoundingClientRect());
      const sourceHeading={left:shell.left,right:shell.right,containerLeft:parent.left,containerRight:parent.right,labelLeft:label.left};
      const targetsRoot=section.closest('article,main'),anchor=section.id,alias=summary.querySelector('.compiled-fragment-alias');
      const fragments=anchor==='babua_[bug]'&&alias?.id==='babua_.5Bbug.5D'&&
        [anchor,alias.id].every(id=>{section.open=false;return Renderer.revealFragment(targetsRoot,id)&&section.open&&document.activeElement.id===id;});

      const bodies=[...document.querySelectorAll('.compiled-description-body')];
      const description=bodies.map(body=>{
        const css=getComputedStyle(body),pseudo=getComputedStyle(body,'::before');
        return {font:parseFloat(css.fontSize),pad:parseFloat(css.paddingLeft),position:css.position,
          left:parseFloat(pseudo.left),top:parseFloat(pseudo.top),bottom:parseFloat(pseudo.bottom),width:parseFloat(pseudo.width),
          fill:pseudo.backgroundColor,events:pseudo.pointerEvents,generated:pseudo.content,
          height:parseFloat(pseudo.height),box:body.getBoundingClientRect().height,text:body.innerText};
      });
      const title=document.querySelector('.compiled-heading-title'),nodes=[...title.querySelectorAll('*')];
      const rgb=text=>getComputedStyle(nodes.find(el=>el.childElementCount===0&&el.textContent.trim()===text)).color;
      return {bodyOrder,sourceHeading,fragments,description,nested:bodies.length===2&&bodies[0].contains(bodies[1]),word:rgb('babua'),sub:['[','bug',']'].map(rgb),frame:getComputedStyle(document.querySelector('.compiled-heading-outer')).borderTopColor};
    },theme);
    const dark=theme==='dark';
    assert.deepEqual(result.bodyOrder,['heading','audio','info','term','definition','example']);
    assert.ok(result.fragments);
    assert.ok(Math.abs(result.sourceHeading.left-result.sourceHeading.containerLeft)<1/64);
    assert.ok(Math.abs(result.sourceHeading.right-result.sourceHeading.containerRight)<1/64);
    assert.ok(Math.abs(result.sourceHeading.labelLeft-result.sourceHeading.left)<1/64);
    assert.equal(result.word,dark?'rgb(224, 224, 224)':'rgb(51, 51, 51)');
    assert.deepEqual(result.sub,Array(3).fill('rgb(136, 136, 136)'));
    assert.equal(result.frame,dark?'rgb(114, 119, 125)':'rgb(162, 169, 177)');
    assert.equal(result.nested,true);
    result.description.forEach((d,index)=>{
      const font=index?15.2:16,near=(a,b)=>assert.ok(Math.abs(a-b)<.035,JSON.stringify({a,b,theme,index}));
      near(d.font,font);near(d.pad,font*.8);
      assert.equal(d.position,'relative');assert.equal(d.generated,'""');assert.equal(d.events,'none');
      for(const inset of [d.left,d.top,d.bottom])near(inset,font*.2);
      near(d.width,1);near(d.height,d.box-d.top-d.bottom);
      assert.equal(d.fill,dark?'rgb(51, 51, 51)':'rgb(204, 204, 204)');
    });
    assert.ok(result.description[0].text.includes('Maloppo babuana amboku.'));
    assert.equal(result.description[1].text.trim(),'Perut bapak saya besar.');
    states[theme]=result;
  }
  const ink=Buffer.from('#e0e0e0'),at=bytes.indexOf(ink);
  assert.ok(at>=0);
  const malformed=Buffer.from(bytes);malformed[at+1]=71;
  assert.throws(()=>decode(malformed,metadata));
  const duplicate=Buffer.from(bytes);Buffer.from('#333333').copy(duplicate,at);
  assert.throws(()=>decode(duplicate,metadata));
  return states;
}


async function verifyPhonosPaint(page){
  const button=page.getByRole('button',{name:'Putar audio',exact:true});
  const icon=button.locator('img');
  const sample=async()=>{
    await icon.evaluate(el=>el.decode());
    const png=await icon.screenshot();
    return page.evaluate(async bytes=>{
      const bitmap=await createImageBitmap(new Blob([new Uint8Array(bytes)],{type:'image/png'}));
      const canvas=new OffscreenCanvas(bitmap.width,bitmap.height),ctx=canvas.getContext('2d');
      ctx.drawImage(bitmap,0,0);bitmap.close();
      const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data,values=[];
      for(let i=0;i<rgba.length;i+=4)values.push(Math.round((rgba[i]+rgba[i+1]+rgba[i+2])/3));
      values.sort((a,b)=>a-b);
      // Use several fully covered source pixels rather than a single antialiased edge.
      return {darkInk:values[4],lightInk:values.at(-5)};
    },[...png]);
  };
  const states={};
  for(const theme of ['light','dark']){
    const night=theme==='dark';
    await page.evaluate(theme=>{document.documentElement.dataset.theme=theme;window.remount(true);},theme);
    await page.mouse.move(0,0);
    const ready=await sample();
    assert.ok(night?ready.lightInk>=250:ready.darkInk<=5,JSON.stringify({theme,ready}));
    await button.hover();
    const hover=await button.evaluate(el=>getComputedStyle(el).backgroundColor);
    assert.equal(hover,night?'rgb(27, 34, 61)':'rgb(232, 238, 255)');
    await page.evaluate(()=>{window.releaseAudio=null;window.fetchMode='error';});
    await button.press('Enter');
    await page.waitForFunction(()=>typeof window.releaseAudio==='function');
    await page.evaluate(()=>window.releaseAudio());
    await page.waitForFunction(()=>document.querySelector('.phonos-control').dataset.mediaState==='error');
    const error=await button.evaluate(el=>[getComputedStyle(el).backgroundColor,getComputedStyle(el).color]);
    assert.deepEqual(error,night?['rgb(39, 41, 45)','rgb(234, 236, 240)']:['rgb(234, 236, 240)','rgb(32, 33, 34)']);
    await page.evaluate(()=>window.remount(false));
    await page.mouse.move(0,0);
    assert.ok(await button.isDisabled());
    const disabled=await sample();
    assert.ok(night?disabled.lightInk>150&&disabled.lightInk<ready.lightInk:disabled.darkInk<110&&disabled.darkInk>ready.darkInk,
      JSON.stringify({theme,ready,disabled}));
    states[theme]={ready,disabled,hover,error};
  }
  return states;
}
