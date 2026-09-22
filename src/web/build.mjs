import {mkdir,copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const target = fileURLToPath(new URL('../../zig-out/web/',import.meta.url));
await mkdir(target,{recursive:true});
for(const file of ['index.html','style.css','app.js','renderer.js','validate.js','import-worker.js']) await copyFile(new URL(file,import.meta.url),target+file);
console.log('Built '+target);
