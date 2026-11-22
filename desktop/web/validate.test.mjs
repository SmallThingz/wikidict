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
