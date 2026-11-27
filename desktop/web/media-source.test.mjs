// Captured source metadata plus explicitly constructed derivatives. No network.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {canonicalImageInfo,canonicalImageURL,canonicalImageEdition} from './media.js';
const fixture=name=>JSON.parse(readFileSync(new URL('./testdata/media-source/'+name,import.meta.url),'utf8'));
const local=fixture('sd-imageinfo.json'),commons=fixture('commons-imageinfo.json'),copy=v=>structuredClone(v);
test('captured-source-local-identity-and-unscaled-original',()=>{
 const row=canonicalImageInfo(local,'antenna.jpg','sd');
 assert.equal(row.canonical_file,'antenna.jpg');assert.equal(row.repository,'local');
 assert.equal(canonicalImageURL(row.info,row.canonical_file),row.info.url);
 assert.deepEqual([row.info.width,row.info.height],[150,107]);
});
test('different-repository-cannot-masquerade-as-local',()=>{
 assert.throws(()=>canonicalImageInfo(commons,'antenna.jpg','sd'));
 const x=copy(local);x.query.pages[0].imagerepository='shared';assert.throws(()=>canonicalImageInfo(x,'antenna.jpg','sd'));
});
test('coherent-shared-with-missing-local-description-CONSTRUCTED',()=>{
 const x=copy(commons);x.query.pages[0].imagerepository='shared';x.query.pages[0].missing=true;
 const row=canonicalImageInfo(x,'antenna.jpg','sd');assert.equal(row.repository,'shared');
 assert.equal(row.canonical_file,'Antenna.jpg');
 assert.equal(canonicalImageURL(row.info,row.canonical_file),row.info.thumburl);
});
test('optional-canonicaltitle-must-match-when-supplied',()=>{
 const x=copy(local);x.query.pages[0].imageinfo[0].canonicaltitle='File:antenna.jpg';
 assert.equal(canonicalImageInfo(x,'antenna.jpg','sd').canonical_file,'antenna.jpg');
 x.query.pages[0].imageinfo[0].canonicaltitle='File:Antenna.jpg';
 assert.throws(()=>canonicalImageInfo(x,'antenna.jpg','sd'));
});
test('case-change-requires-explicit-source-normalization',()=>{
 const x=copy(commons);x.query.pages[0].imagerepository='shared';delete x.query.normalized;
 assert.throws(()=>canonicalImageInfo(x,'antenna.jpg','sd'));
});
test('missing-invalid-api-ambiguous-and-local-missing-refuse',()=>{
 const mutations=[x=>delete x.query.pages[0].imageinfo,x=>x.error={code:'denied'},
  x=>x.query.pages.push(copy(x.query.pages[0])),x=>x.query.pages[0].ns=0,
  x=>x.query.pages[0].invalid=true,x=>x.query.pages[0].missing=true];
 for(const mutate of mutations){const x=copy(local);mutate(x);assert.throws(()=>canonicalImageInfo(x,'antenna.jpg','sd'));}
});
test('unbound-redirect-loop-and-fragment-refuse',()=>{
 for(const rows of [[{from:'unrelated',to:'File:other.jpg'}],
   [{from:'فائل:antenna.jpg',to:'File:antenna.jpg'}],
   [{from:'فائل:antenna.jpg',to:'File:other.jpg',tofragment:'x'}]]){
  const x=copy(local);x.query.redirects=rows;assert.throws(()=>canonicalImageInfo(x,'antenna.jpg','sd'));
 }
});
test('explicit-returned-redirect-relation-CONSTRUCTED-no-request-change',()=>{
 const x=copy(local),p=x.query.pages[0];
 x.query.redirects=[{from:p.title,to:'فائل:renamed.jpg'}];p.title='فائل:renamed.jpg';
 p.imageinfo[0].canonicaltitle=p.title;p.imageinfo[0].url=p.imageinfo[0].url.replace('antenna.jpg','renamed.jpg');
 assert.equal(canonicalImageInfo(x,'antenna.jpg','sd').canonical_file,'renamed.jpg');
 const row=canonicalImageInfo(x,'antenna.jpg','sd');
 assert.throws(()=>canonicalImageURL(row.info,row.canonical_file));
 x.query.pages[0].imageinfo[0].thumburl=x.query.pages[0].imageinfo[0].thumburl.replace('antenna.jpg','renamed.jpg');
 assert.equal(canonicalImageURL(x.query.pages[0].imageinfo[0],row.canonical_file),x.query.pages[0].imageinfo[0].url);
});
test('url-identity-keeps-transform-auth-and-other-format-boundaries',()=>{
 const i=local.query.pages[0].imageinfo[0];
 for(const thumbnail of [i.thumburl+'&width=960',i.thumburl+'&token=other']){
  assert.equal(canonicalImageURL({...i,thumburl:thumbnail},'antenna.jpg'),thumbnail);
 }
 for(const wrong of [i.thumburl.replace('/wiktionary/sd/','/wikipedia/commons/'),i.thumburl.replace('antenna.jpg','Antenna.jpg'),i.thumburl.replace('upload.wikimedia.org','example.invalid'),i.thumburl.replace('/e/e2/','/thumb/e/e2/')])
  assert.throws(()=>canonicalImageURL({...i,thumburl:wrong},'antenna.jpg'));
 const owner='https://upload.wikimedia.org/wiktionary/sd/thumb/e/e2/antenna.jpg/960px-antenna.jpg';
 assert.equal(canonicalImageURL({...i,thumburl:owner},'antenna.jpg'),owner);
 assert.equal(canonicalImageURL({...i,mime:'image/svg+xml'},'antenna.svg'),i.thumburl);
 assert.equal(canonicalImageURL({...i,mime:'image/tiff'},'antenna.tiff'),i.thumburl);
});
test('known-thumbnail-host-requires-complete-owner-path-CONSTRUCTED',()=>{
 const shared=copy(commons);shared.query.pages[0].imagerepository='shared';shared.query.pages[0].missing=true;
 const row=canonicalImageInfo(shared,'antenna.jpg','sd'),i=row.info;
 assert.equal(canonicalImageURL(i,row.canonical_file),i.thumburl);
 assert.equal(new URL(i.thumburl).origin,'https://thumb.wikimedia.org');
 const wrongs=[
  i.thumburl.replace('thumb.wikimedia.org','thumb.wikimedia.org.example.invalid'),
  i.thumburl.replace('https://thumb.wikimedia.org','http://thumb.wikimedia.org'),
  i.thumburl.replace('thumb.wikimedia.org','thumb.wikimedia.org:444'),
  i.thumburl.replace('/wikipedia/commons/','/wiktionary/sd/'),
  i.thumburl.replace('/Antenna.jpg/','/antenna.jpg/'),
  i.thumburl.replace('/thumb/7/76/','/thumb/7/'),
  i.thumburl.replace('/960px-Antenna.jpg','/nested/960px-Antenna.jpg'),
  i.url.replace('upload.wikimedia.org','thumb.wikimedia.org'),
 ];
 for(const thumburl of wrongs)assert.throws(()=>canonicalImageURL({...i,thumburl},row.canonical_file));
 const localInfo=local.query.pages[0].imageinfo[0];
 assert.throws(()=>canonicalImageURL({...localInfo,thumburl:i.thumburl},'antenna.jpg'));
 assert.throws(()=>canonicalImageURL({...i,url:i.url.replace('upload.wikimedia.org','upload.wikimedia.org:444')},row.canonical_file));
});
test('canonical-edition-required-before-any-legacy-loop-CONSTRUCTED',()=>{
 assert.equal(canonicalImageEdition('sdwiktionary'),'sd');
 assert.equal(canonicalImageEdition('enwiktionary'),'en');
 for(const edition of [null,undefined,'','sd','wiktionary','SDwiktionary','enwikipedia','bad hostwiktionary',4,{}])
  assert.throws(()=>canonicalImageEdition(edition));
});
