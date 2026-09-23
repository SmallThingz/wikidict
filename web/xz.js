import xz from 'xz-decompress';
const {XzReadableStream} = xz;
import {RawSource} from './blob.js';
const check=(ok)=>{if(!ok)throw Error('Invalid or unsupported XZ dictionary');};
const u32=(b,p)=>new DataView(b.buffer,b.byteOffset,b.byteLength).getUint32(p,true);
const word=n=>{const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,n,true);return b;};
function crc(b){let c=0xffffffff;for(const x of b){c^=x;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
const vli=n=>{const a=[];do{const b=n%128;n=Math.floor(n/128);a.push(b|(n?128:0));}while(n);return a;};
function readVli(bytes,state){let n=0,m=1,b,c=0;do{check(state.p<bytes.length&&c++<9);b=bytes[state.p++];n+=(b&127)*m;m*=128;}while(b&128);check(Number.isSafeInteger(n)&&(c===1||b!==0));return n;}
const round4=n=>Math.ceil(n/4)*4;
export class XzSource {
  static async open(file){
    const source=new XzSource();source.file=file;source.raw=new RawSource(file);source.blocks=[];source.size=0;source.cache=null;
    let end=file.size;const streams=[];
    while(end){
      // XZ permits zero padding in multiples of four between concatenated streams.
      while(end>=4){const pad=await source.raw.read(end-4,4);if(pad.some(x=>x!==0))break;end-=4;}
      check(end>=24);const footer=await source.raw.read(end-12,12);
      check(footer[10]===89&&footer[11]===90&&crc(footer.subarray(4,10))===u32(footer,0));
      const indexSize=(u32(footer,4)+1)*4;check(indexSize>=8&&indexSize<=64*1024*1024&&indexSize<=end-24);
      const index=await source.raw.read(end-12-indexSize,indexSize);
      check(index[0]===0&&crc(index.subarray(0,-4))===u32(index,indexSize-4));
      const state={p:1},count=readVli(index,state),blocks=[];check(count<=1000000);
      let compressedSize=0;
      for(let i=0;i<count;i++){const packed=readVli(index,state),size=readVli(index,state);check(packed>=5&&size>0&&size<=128*1024*1024);blocks.push({packed,size});compressedSize+=round4(packed);}
      check(state.p<=indexSize-4 && index.subarray(state.p,-4).every(x=>x===0));
      const start=end-12-indexSize-compressedSize-12;check(start>=0);
      const header=await source.raw.read(start,12);
      check(header.slice(0,6).join(',')==='253,55,122,88,90,0'&&header[6]===footer[8]&&header[7]===footer[9]&&crc(header.subarray(6,8))===u32(header,8));
      let offset=start+12;for(const block of blocks){block.offset=offset;block.header=header;offset+=round4(block.packed);}
      streams.unshift(blocks);end=start;
    }
    for(const blocks of streams)for(const block of blocks){block.logical=source.size;source.size+=block.size;source.blocks.push(block);}
    check(source.size<=32*1024**3&&source.size>=9);return source;
  }
  async block(number){
    if(this.cache?.number===number)return this.cache.bytes;
    const b=this.blocks[number],index=[0,1,...vli(b.packed),...vli(b.size)];while(index.length%4)index.push(0);
    const indexBytes=new Uint8Array(index),back=word((index.length+4)/4-1);
    const footerBody=new Uint8Array([...back,b.header[6],b.header[7]]);
    const encoded=new Blob([b.header,this.file.slice(b.offset,b.offset+round4(b.packed)),indexBytes,word(crc(indexBytes)),word(crc(footerBody)),footerBody,new Uint8Array([89,90])]);
    const stream=new XzReadableStream(encoded.stream()).getReader(),parts=[];let length=0;
    try{while(true){const {done,value}=await stream.read();if(done)break;length+=value.length;check(length<=b.size);parts.push(value);}check(length===b.size);}finally{await stream.cancel();}
    const bytes=new Uint8Array(length);let p=0;for(const part of parts){bytes.set(part,p);p+=part.length;}
    this.cache={number,bytes};return bytes;
  }
  async read(offset,length){
    check(offset>=0&&length>=0&&offset+length<=this.size&&length<=128*1024*1024);
    const result=new Uint8Array(length);let written=0,lo=0,hi=this.blocks.length;
    while(lo<hi){const mid=(lo+hi)>>>1;if(this.blocks[mid].logical+this.blocks[mid].size<=offset)lo=mid+1;else hi=mid;}
    while(written<length){const b=this.blocks[lo],bytes=await this.block(lo++),at=offset-b.logical,n=Math.min(length-written,b.size-at);result.set(bytes.subarray(at,at+n),written);written+=n;offset+=n;}
    return result;
  }
}
export async function openSource(file){const magic=new Uint8Array(await file.slice(0,6).arrayBuffer());return magic.join(',')==='253,55,122,88,90,0'?XzSource.open(file):new RawSource(file);}
