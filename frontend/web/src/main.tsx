import { render } from 'solid-js/web';
import { LiveDictionary } from './live';
import { mountDictionary, isResults } from './index';
import { emptyResults } from './types';
const root = document.getElementById('app');
if (!root) throw new Error('Missing dictionary root.');
try {
  const parsed: unknown = JSON.parse(document.getElementById('dict-data')?.textContent || 'null');
  if (parsed && typeof parsed === 'object' && 'mode' in parsed && parsed.mode === 'live' && 'language' in parsed && typeof parsed.language === 'string' && 'kind' in parsed && typeof parsed.kind === 'string') {
    if (!/^https?:$/.test(location.protocol)) throw new Error('Start dict serve to use live search.');
    render(() => <LiveDictionary language={parsed.language as string} kind={parsed.kind as string}/>,root);
  } else {
  const data = parsed === '__DICT_DATA__' ? emptyResults : parsed;
  if (!isResults(data)) throw new Error('Unsupported or malformed dictionary results.');
  mountDictionary(root, data);
  document.title = `${data.query || 'Dictionary'} · Dict`;
  }
} catch (error) {
  root.setAttribute('role', 'alert');
  root.textContent = error instanceof Error ? error.message : 'Unable to read this dictionary export.';
}
