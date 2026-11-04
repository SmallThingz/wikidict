// Hand-authored final DPRC wire controls; proposed, not executed.
import test from 'node:test';
import assert from 'node:assert/strict';
import {decode} from './blob.js';
const u=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n);return b;};
const f=n=>{const b=Buffer.alloc(4);b.writeFloatLE(n);return b;};
const cat=(...v)=>Buffer.concat(v.flatMap(x=>Array.isArray(x)?[Buffer.from(x)]:[x]));
const str=s=>cat(u(Buffer.byteLength(s)),Buffer.from(s));
const len=(unit,value)=>cat([unit],f(value));
const edges=(unit,value)=>cat(...Array.from({length:4},()=>len(unit,value)));
const solid=()=>cat([1],len(0,1),str('#aaaaaa'));
const tableStyle=()=>cat([1,15],str('#f9f9f9'),solid(),[1],edges(0,10));
const cellStyle=()=>cat([1,7],solid(),edges(1,.2),[1]);
function wire({cell=cellStyle(),table=tableStyle(),magic='DPRC'}={}){
 const c=cat([1,1,0,1,0,0],u(0),[0,0],cell);
 const t=cat([1,0],u(0),u(1),u(1),c,table);
 const b=cat([12,0,0],u(0),[0],str(''),str(''),t,str(''),str(''));
 const section=cat([2],str('S'),str('S'),str(''),u(1),b);
 return cat(Buffer.from(magic),u(0),u(1),section,u(0),u(0),u(0),u(0),u(0));
}
test('final C typed styles retain units, edges and native JSON union shape',()=>{
 const t=decode(wire(),{}).sections[0].blocks[0].table,c=t.rows[0].cells[0];
 assert.deepEqual(t.style,{background:'#f9f9f9',border:{solid:{width:{unit:'px',value:1},color:'#aaaaaa'}},collapse:'collapse',margins:Object.fromEntries(['top','right','bottom','left'].map(k=>[k,{unit:'px',value:10}]))});
 assert.equal(c.style.text_align,'center');assert.equal(c.style.padding.top.unit,'em');assert.equal(c.style.padding.top.value,Math.fround(.2));
 const zero=decode(wire({cell:cat([1,3,0],edges(1,0)),table:cat([1,4,0])}),{}).sections[0].blocks[0].table;
 assert.deepEqual(zero.rows[0].cells[0].style.border,{none:{}});assert.equal(zero.rows[0].cells[0].style.padding.left.value,0);assert.equal(zero.style.collapse,'separate');
 const max=decode(wire({cell:cat([1,2],edges(1,3.4028234663852886e38)),table:Buffer.from([0])}),{}).sections[0].blocks[0].table;
 assert.equal(max.rows[0].cells[0].style.padding.top.value,3.4028234663852886e38);
});
test('no-style B and final C have equal decoded graphs',()=>{
 const b=decode(wire({magic:'DPRB',cell:Buffer.alloc(0),table:Buffer.alloc(0)}),{});
 const c=decode(wire({cell:Buffer.from([0]),table:Buffer.from([0])}),{});
 const project=({presentation_version,...v})=>v;assert.deepEqual(project(c),project(b));
 assert.equal(Object.hasOwn(c.sections[0].blocks[0].table,'style'),false);
});
test('invalid style framing, enums, RGB and lengths reject',()=>{
 for(const cell of [cat([2]),cat([1,0]),cat([1,8]),cat([1,4,3]),cat([1,1,2]),cat([1,2],edges(2,0)),cat([1,2],edges(1,-1)),cat([1,2],edges(1,NaN)),cat([1,2],edges(1,Infinity))])assert.throws(()=>decode(wire({cell}),{}));
 for(const table of [cat([2]),cat([1,0]),cat([1,16]),cat([1,4,2]),cat([1,1],str('#ABCDEF')),cat([1,2,1],len(0,1),str('red'))])assert.throws(()=>decode(wire({table}),{}));
 const bytes=wire();assert.throws(()=>decode(bytes.subarray(0,bytes.length-1),{}));
});
