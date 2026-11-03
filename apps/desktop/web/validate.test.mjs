import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validate,safeURL} from './validate.js';
const document = ()=>({schema:'dict.results.v1',entries:[{title:'cat',sections:[]}]});
test('only compiled documents are accepted',()=>{assert.equal(validate(document()).entries[0].title,'cat');assert.throws(()=>validate({schema:'wikitext',entries:[]}));const bad=document();bad.entries[0].source='raw';assert.throws(()=>validate(bad));});
test('nested legacy fields and executable URL schemes are rejected',()=>{const bad=document();bad.entries[0].media=[{content:'raw'}];assert.throws(()=>validate(bad));assert.equal(safeURL('javascript:alert(1)'),null);assert.equal(safeURL('data:text/html,hi'),null);assert.equal(safeURL('https://example.org/'),'https://example.org/');});
test('table spans and inline kinds are checked',()=>{const bad=document();bad.entries[0].display_title=[{kind:'template',text:'hidden'}];assert.throws(()=>validate(bad));bad.entries[0].display_title=[];bad.entries[0].table={colspan:0};assert.throws(()=>validate(bad));});
