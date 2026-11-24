import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {openSource} from './xz.js';
import {buildIndex,decode} from './blob.js';

const assets=new URL('../../android/app/src/androidTest/assets/vi1034/',import.meta.url);
async function readMember(asset){
  const source=await openSource(new Blob([await readFile(asset)]));
  const {metadata,rows}=await buildIndex(source);
  assert.equal(rows.length,1);
  const {title,offset,length}=rows[0];
  assert.equal(title,'từ điển');
  return {bytes:Buffer.from(await source.read(offset,length)),metadata:{...metadata,title,source_edition:'viwiktionary'}};
}

export async function verifyIntrinsicRaster(page,intrinsicAsset=new URL('intrinsic.wikblb.xz',assets)){
  const old=await readMember(new URL('original.wikblb.xz',assets));
  const current=await readMember(intrinsicAsset);
  assert.deepEqual(old.metadata,current.metadata);
  const legacy=decode(old.bytes,old.metadata);
  const entry=decode(current.bytes,current.metadata);
  function findFigure(node){
    if(!node||typeof node!=='object')return;
    if(node.image_span?.image?.file==='Latin dictionary.jpg')return node;
    for(const child of Object.values(node)){const result=findFigure(child);if(result)return result;}
  }
  const figure=findFigure(entry);
  assert.deepEqual(figure.intrinsic_size,{width_px:1408,height_px:1120});
  const {intrinsic_size,...unfeatured}=figure;
  assert.deepEqual(unfeatured,findFigure(legacy));
  assert.equal(figure.image_span.target,'File:Latin dictionary.jpg');
  const axes=Buffer.alloc(8);axes.writeUInt32LE(intrinsic_size.width_px);axes.writeUInt32LE(intrinsic_size.height_px,4);
  const at=current.bytes.indexOf(axes);
  assert.ok(at>=0);assert.equal(current.bytes.lastIndexOf(axes),at);
  const tagAt=old.bytes.findIndex((byte,index)=>byte!==current.bytes[index]);
  assert.ok(tagAt>=0&&tagAt<at);
  assert.equal(old.bytes[tagAt],1);
  assert.equal(current.bytes[tagAt],8);
  assert.deepEqual(current.bytes.subarray(tagAt+1,at),old.bytes.subarray(tagAt+1,at));
  assert.deepEqual(current.bytes.subarray(at+8),old.bytes.subarray(at));
  for(const offset of [at,at+4])for(const value of [0,0x80000000]){
    const bad=Buffer.from(current.bytes);bad.writeUInt32LE(value,offset);
    assert.throws(()=>decode(bad,current.metadata),/Invalid/);
  }
  assert.throws(()=>decode(current.bytes.subarray(0,at+7),current.metadata),/Invalid/);
  await page.evaluate(entry=>{
    // Chromium exercises the actual entry through each application media state.
    // Only this explicitly controlled load uses a local, one-pixel test PNG.
    window.caches={open:async()=>({match:async()=>null})};
    window.renderRaster=mode=>{
      window.rasterMode=mode;
      document.body.replaceChildren(document.createElement('main'));
      const localPixel='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ0kAAAAASUVORK5CYII=';
      window.fetch=async input=>{
        const url=new URL(input);
        if(url.pathname==='/w/api.php'){
          if(url.searchParams.get('titles')!=='File:Latin dictionary.jpg')throw Error('Unrelated fixture media is offline');
          if(mode==='disabled')throw Error('Unexpected disabled request');
          return new Promise((resolve,reject)=>{window.finishMetadata=()=>{
            if(mode==='error')reject(Error('controlled offline failure'));
            else resolve(new Response(JSON.stringify({query:{pages:[{imageinfo:[{url:'https://upload.wikimedia.org/test-only.png',mime:'image/jpeg',width:mode==='mismatch'?1407:1408,height:1120}]}]}})));
          };});
        }
        return new Response(Uint8Array.from(atob(localPixel),c=>c.charCodeAt(0)),{headers:{'Content-Type':'image/png'}});
      };
      const settings={allowImages:mode!=='disabled',mediaCacheMb:0};
      const holder=Renderer.renderEntry(entry,()=>{},{},()=>null,
        (el,image,occurrence)=>Media.loadInlineImage(el,image,settings,'viwiktionary',occurrence),
        (target,fragment)=>Media.inlineImageActionURL(target,'viwiktionary',fragment));
      document.querySelector('main').addEventListener('click',event=>{
        const link=event.target.closest('a');
        if(link){event.preventDefault();window.rasterAction=link.href;}
      });
      document.querySelector('main').append(holder);
    };
    window.rasterState=()=>{
      const frame=[...document.querySelectorAll('.compiled-figure')].find(node=>node.querySelector('figcaption')?.textContent==='từ điển');
      const image=frame.querySelector('img');
      const content=image.hidden?frame.querySelector('.compiled-image-status'):image;
      if(!content)return null;
      frame.scrollIntoView({block:'center'});
      const area=content.getBoundingClientRect();
      const caption=frame.querySelector('figcaption').getBoundingClientRect();
      const center=document.elementFromPoint(area.left+area.width/2,area.top+area.height/2);
      return {state:image.dataset.mediaState,width:area.width,height:area.height,captionTop:caption.top-area.bottom,
              float:getComputedStyle(frame).cssFloat,clear:getComputedStyle(frame).clear,hit:!!content.closest('a')&&center?.closest('a')===content.closest('a')};
    };
  },entry);
  const states=[];
  async function state(name){
    try{
      await page.waitForFunction(expected=>window.rasterState()?.state===expected,name,{timeout:10000});
    }catch(error){
      const current=await page.evaluate(()=>({mode:window.rasterMode,state:window.rasterState(),images:[...document.images].map(i=>[i.alt,i.dataset.mediaState])}));
      throw new Error('Expected '+name+' '+JSON.stringify(current),{cause:error});
    }
    const result=await page.evaluate(()=>window.rasterState());
    assert.deepEqual([result.width,result.height,result.float,result.clear,result.hit],[250,199,'right','right',true]);
    assert.ok(result.captionTop>=0);
    states.push(result);
    return result.captionTop;
  }
  await page.evaluate(()=>window.renderRaster('disabled'));
  const caption=await state('disabled');
  for(const [mode,finalState] of [['error','error'],['mismatch','geometry-unresolved'],['loaded','loaded']]){
    // Let the removed consumer release its resource before mounting an independent response.
    await page.evaluate(()=>document.body.replaceChildren());
    await page.evaluate(mode=>{window.finishMetadata=null;window.renderRaster(mode);},mode);
    assert.equal(await state('loading'),caption);
    await page.waitForFunction(()=>typeof window.finishMetadata==='function');
    await page.evaluate(()=>window.finishMetadata());
    assert.equal(await state(finalState),caption);
  }
  await page.locator('.compiled-figure').filter({has:page.locator('figcaption',{hasText:'từ điển'})}).locator('.compiled-figure-image a').click();
  const action=await page.evaluate(()=>window.rasterAction);
  assert.equal(action,'https://vi.wiktionary.org/wiki/File%3ALatin%20dictionary.jpg');
  return {states,action};
}
