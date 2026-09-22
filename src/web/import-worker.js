import {validate} from './validate.js';
self.onmessage = async ({data: file}) => {
  try {
    if (file.size > 64 * 1024 * 1024) throw Error('Dictionary package is larger than 64 MiB.');
    const text = new TextDecoder('utf-8', {fatal:true}).decode(await file.arrayBuffer());
    self.postMessage({value:validate(JSON.parse(text))});
  } catch (error) { self.postMessage({error:error.message}); }
};
