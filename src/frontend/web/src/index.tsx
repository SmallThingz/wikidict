import { render } from 'solid-js/web';
import { DictionaryApp } from './App';
import { isResults } from './validate';
import type { MountOptions, Results } from './types';
export { isResults } from './validate';
export type { Results, Entry, Section, Block, Span, Navigation, MountOptions } from './types';
/** Scoped styles and inherited site tokens; returns a disposer. */
export function mountDictionary(element: HTMLElement, data: Results, options: MountOptions = {}) {
  if (!isResults(data)) throw new Error('Unsupported or malformed dictionary results.');
  return render(() => <DictionaryApp data={data} options={options} />, element);
}
