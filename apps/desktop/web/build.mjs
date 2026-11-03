import {mkdir,copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
const target=fileURLToPath(new URL('../build/web/',import.meta.url));
await mkdir(target,{recursive:true});
for(const file of ['index.html','style.css','reader.ttf','Newsreader-OFL.txt'])await copyFile(new URL(file,import.meta.url),target+file);
await build({entryPoints:['app.js','import-worker.js'],outdir:target,bundle:true,format:'esm',platform:'browser',target:'es2022',minify:true});
console.log('Built '+target);
