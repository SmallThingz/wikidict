import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validate,safeURL,linkTargetParts,bookSourcesURL,isBookSourcesTitle} from './validate.js';
const document = ()=>({schema:'dict.results.v1',entries:[{title:'cat',sections:[]}]});
test('only compiled documents are accepted',()=>{assert.equal(validate(document()).entries[0].title,'cat');assert.throws(()=>validate({schema:'wikitext',entries:[]}));const bad=document();bad.entries[0].source='raw';assert.throws(()=>validate(bad));});
test('nested legacy fields and executable URL schemes are rejected',()=>{const bad=document();bad.entries[0].media=[{content:'raw'}];assert.throws(()=>validate(bad));assert.equal(safeURL('javascript:alert(1)'),null);assert.equal(safeURL('data:text/html,hi'),null);assert.equal(safeURL('https://example.org/'),'https://example.org/');});
test('table spans and inline kinds are checked',()=>{const bad=document();bad.entries[0].display_title=[{kind:'template',text:'hidden'}];assert.throws(()=>validate(bad));bad.entries[0].display_title=[];bad.entries[0].table={colspan:0};assert.throws(()=>validate(bad));});

test('compiled target components distinguish legacy split, literal whole title and explicit fragment',()=>{
 assert.deepEqual(linkTargetParts('Title#one#two'),{title:'Title',fragment:'one#two'});
 assert.deepEqual(linkTargetParts('Title#one#two',null),{title:'Title',fragment:'one#two'});
 assert.deepEqual(linkTargetParts('Title#one#two',''),{title:'Title#one#two',fragment:''});
 assert.deepEqual(linkTargetParts('Title#one#two','Part#Ω'),{title:'Title#one#two',fragment:'Part#Ω'});
 assert.deepEqual(linkTargetParts('','Local#Ω'),{title:'',fragment:'Local#Ω'});
 assert.deepEqual(linkTargetParts('Title%23literal',''),{title:'Title%23literal',fragment:''});
 assert.deepEqual(linkTargetParts('Under_score#literal',''),{title:'Under_score#literal',fragment:''});
 assert.deepEqual(linkTargetParts('Title','Part😀'),{title:'Title',fragment:'Part😀'});
 for(const target_fragment of [0,false,{},[], '\ud800','\udfff']){
  assert.throws(()=>linkTargetParts('Title',target_fragment));
  const value=document();value.entries[0].display_title=[{kind:'link',text:'Label',target:'Title',target_fragment}];assert.throws(()=>validate(value));
 }
 for(const kind of ['text','external_link','line_break']){const value=document();value.entries[0].display_title=[{kind,text:'Label',target:'Title',target_fragment:''}];assert.throws(()=>validate(value));}
 const value=document();value.entries[0].display_title=[{kind:'link',text:'Label',target:'Title#literal',target_fragment:''}];assert.equal(validate(value),value);
});
test('canonical Booksources uses exact title and separate fragment at the known source edition',()=>{
 const title='Special:Booksources/978#/%?&Ω',base='https://de.wiktionary.org/wiki/'+encodeURIComponent(title);
 assert.equal(bookSourcesURL(title,'dewiktionary',''),base);
 assert.equal(bookSourcesURL(title,'dewiktionary','Part#/%?&Ω'),base+'#'+encodeURIComponent('Part#/%?&Ω'));
 assert.equal(bookSourcesURL('Special:Booksources/978#tail','dewiktionary'), 'https://de.wiktionary.org/wiki/'+encodeURIComponent('Special:Booksources/978')+'#tail');
 for(const edition of [null,'','Unknown','https://example.org'])assert.equal(bookSourcesURL(title,edition,''),null);
 for(const target of ['Special:BookSources/9788323999997','Special:booksources/9788323999997','Special:Booksources/'])assert.equal(bookSourcesURL(target,'dewiktionary',''),null);
 assert.equal(isBookSourcesTitle(title),true);assert.equal(isBookSourcesTitle('Special:BookSources/9788323999997'),false);
});

test('explicit unavailable source editions do not become a current edition or poison literal lookup',()=>{
 const special='Special:Booksources/978#literal';for(const edition of [undefined,null,'']){assert.equal(bookSourcesURL(special,edition,''),null);assert.deepEqual(linkTargetParts('Page#literal',''),{title:'Page#literal',fragment:''});}
 assert.equal(bookSourcesURL(special,'mgwiktionary',''),'https://mg.wiktionary.org/wiki/'+encodeURIComponent(special));
});

// Scheme-relative external destinations retain their authored authority.
test('exact-retained-NDS-target',()=>assert.equal(safeURL("//nds.wiktionary.org/w/index.php?title=V%C3%B6rlaag:%C3%96_-bor&action=edit",'ndswiktionary'),'https:'+"//nds.wiktionary.org/w/index.php?title=V%C3%B6rlaag:%C3%96_-bor&action=edit"));
test('retained-RO-absolute-unchanged',()=>assert.equal(safeURL('https://ro.wikipedia.org/wiki/Limba_nepalez%C4%83'),'https://ro.wikipedia.org/wiki/Limba_nepalez%C4%83'));
test('authored-cross-host-query-fragment-preserved',()=>assert.equal(safeURL('//example.org/a%20b?x=1#part','ndswiktionary'),'https://example.org/a%20b?x=1#part'));
test('no-basis-no-default',()=>{for(const edition of [undefined,null,'','nds','wiktionary','enwikipedia','bad hostwiktionary'])assert.equal(safeURL("//nds.wiktionary.org/w/index.php?title=V%C3%B6rlaag:%C3%96_-bor&action=edit",edition),null);});
test('malformed-network-authority-refuses',()=>{for(const target of ['//','///example.org/a','//?x','//#part','//user:password@example.org/a','//user@example.org','//example.org:bad/a','//%2fexample.org'])assert.equal(safeURL(target,'ndswiktionary'),null);});
test('backslash-controls-whitespace-refuse',()=>{for(const target of ['//'+String.fromCharCode(92)+'/example.org','//example.org/a'+String.fromCharCode(92)+'b','//example.org/a b','//example.org/'+String.fromCharCode(0),'//example.org/'+String.fromCharCode(10),'//example.org/'+String.fromCharCode(127)])assert.equal(safeURL(target,'ndswiktionary'),null);});
test('ordinary-relative-and-non-http-refuse',()=>{for(const target of ['/a','a','../a','#part','javascript:alert(1)','data:text/plain,x','mailto:x@example.org'])assert.equal(safeURL(target,'ndswiktionary'),null);});
test('existing-absolute-http-https-policy-preserved',()=>{for(const target of ['http://example.org/a?b#c','https://example.org/a','https://example.org:443/a'])assert.equal(safeURL(target),new URL(target).href);});
