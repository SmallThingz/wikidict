import { createEffect, createSignal, onCleanup, onMount } from 'solid-js';
import { DictionaryApp } from './App';
import { isResults } from './validate';
import { emptyResults, type LiveOptions, type Results, type Navigation } from './types';
const kinds = new Set(['language', 'thesaurus', 'citations', 'reconstruction', 'rhymes', 'sign_gloss']);
const locationFragment = () => { const raw = location.hash.startsWith('#') ? location.hash.slice(1) : ''; try { return decodeURIComponent(raw); } catch { return raw; } };
export function LiveDictionary(props: { language: string; kind: string }) {
  const params = new URLSearchParams(location.search);
  const [query, setQuery] = createSignal(params.get('q') || '');
  const [language, setLanguage] = createSignal(params.get('language') || props.language);
  const [kind, setKind] = createSignal(kinds.has(params.get('kind') || '') ? params.get('kind')! : props.kind);
  const [languages, setLanguages] = createSignal<{ heading: string; code: string }[]>([]);
  const [data, setData] = createSignal<Results>(emptyResults);
  const [matches, setMatches] = createSignal<{ title: string }[]>([]);
  const [total, setTotal] = createSignal(0);
  const [more, setMore] = createSignal(false);
  const [searching, setSearching] = createSignal(false);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal('');
  let searchController: AbortController | undefined;
  let entryController: AbortController | undefined;
  let searchVersion = 0, entryVersion = 0;
  const cache = new Map<string, { data: Results; bytes: number }>();
  let cacheBytes = 0;
  const endpoint = (route: string, q: string, lang: string, category: string, offset = 0) =>
    `/api/${route}?${new URLSearchParams({ q, language: lang, kind: category, offset: String(offset), limit: '40' })}`;
  async function results(url: string, signal: AbortSignal) {
    const response = await fetch(url, { signal, credentials: 'same-origin' });
    const text = await response.text();
    const value: unknown = JSON.parse(text);
    if (!isResults(value)) throw new Error(response.status === 503 ? 'The renderer is busy. Retry this entry shortly.' : `Dictionary request failed (${response.status}).`);
    return { data: value, bytes: text.length * 2 };
  }
  async function search(append = false) {
    searchController?.abort(); const controller = new AbortController(); searchController = controller;
    const version = ++searchVersion;
    setSearching(true);
    try {
      const result = await results(endpoint('search', query(), language(), kind(), append ? matches().length : 0), controller.signal);
      if (version !== searchVersion) return;
      setMatches(previous => append ? [...previous, ...result.data.matches] : result.data.matches);
      setTotal(result.data.total_matches); setMore(result.data.has_more);
    } catch (e) { if (!controller.signal.aborted && version === searchVersion) setError(e instanceof Error ? e.message : 'Search failed.'); }
    finally { if (version === searchVersion) setSearching(false); }
  }
  async function open(title: string, lang = language(), category = kind(), fragment = '', history = true) {
    const resolvedLanguage = languages().find(item => item.code.toLowerCase() === lang.toLowerCase() || item.heading === lang)?.heading || lang;
    let name = title;
    const namespaces: Record<string, string> = { thesaurus: 'thesaurus', citations: 'citations', reconstruction: 'reconstruction', rhymes: 'rhymes', 'sign gloss': 'sign_gloss' };
    const colon = title.indexOf(':');
    const prefix = colon > 0 ? title.slice(0, colon).toLowerCase() : '';
    if (colon > 0 && Object.hasOwn(namespaces, prefix)) { category = namespaces[prefix]; name = title.slice(colon + 1); }
    setLanguage(resolvedLanguage); setKind(category); setQuery(name);
    entryController?.abort(); const controller = new AbortController(); entryController = controller;
    const version = ++entryVersion; setLoading(true); setError('');
    if (history) {
      const hash = fragment ? `#${encodeURIComponent(fragment.replaceAll(' ', '_'))}` : '';
      window.history.pushState(null, '', `/?${new URLSearchParams({ q: name, language: resolvedLanguage, kind: category })}${hash}`);
    }
    document.title = `${name} · Dict`;
    const url = endpoint('entry', name, resolvedLanguage, category);
    try {
      const result = cache.get(url) || await results(url, controller.signal);
      if (version !== entryVersion) return;
      setData(result.data);
      if (!result.data.entries.length) setError(`No exact entry for “${name}” in ${resolvedLanguage}.`);
      if (!cache.has(url) && result.bytes <= 16 * 1024 * 1024 && result.data.entries[0]?.expansion?.status !== 'failed') {
        while (cache.size && (cache.size >= 8 || cacheBytes + result.bytes > 32 * 1024 * 1024)) { const key = cache.keys().next().value!; cacheBytes -= cache.get(key)!.bytes; cache.delete(key); }
        cache.set(url, result); cacheBytes += result.bytes;
      }
      if (fragment) queueMicrotask(() => {
        const heading = fragment.replaceAll('_', ' ').trim();
        const section = [...document.querySelectorAll<HTMLElement>('[data-section]')].find(element => element.dataset.section === heading);
        if (section instanceof HTMLDetailsElement) section.open = true;
        section?.scrollIntoView({ block: 'start' });
      });
    } catch (e) { if (!controller.signal.aborted && version === entryVersion) setError(e instanceof Error ? e.message : 'Entry could not be loaded.'); }
    finally { if (version === entryVersion) setLoading(false); }
  }
  const home = () => {
    entryController?.abort(); ++entryVersion; searchController?.abort(); ++searchVersion;
    setLoading(false); setSearching(false); setError(''); setMatches([]); setMore(false); setQuery(''); setData(emptyResults);
    window.history.pushState(null, '', '/');
    document.title = 'Dict · A local dictionary';
  };
  createEffect(() => {
    query(); language(); kind();
    // Clear prior suggestions immediately; cancelled responses cannot replace new input.
    searchController?.abort(); ++searchVersion; setMatches([]); setMore(false);
    const timer = window.setTimeout(() => void search(), 140);
    onCleanup(() => window.clearTimeout(timer));
  });
  onMount(() => {
    const catalog = new AbortController();
    void fetch('/api/languages', { signal: catalog.signal }).then(r => r.json()).then((value: unknown) => {
      if (!value || typeof value !== 'object' || !('languages' in value) || !Array.isArray(value.languages)
          || !value.languages.every((item: unknown) => !!item && typeof item === 'object' && 'heading' in item && typeof item.heading === 'string' && 'code' in item && typeof item.code === 'string')) throw new Error('Invalid language catalog.');
      setLanguages(value.languages);
      const current = language();
      const canonical = value.languages.find((item: { heading: string; code: string }) => item.code.toLowerCase() === current.toLowerCase() || item.heading === current)?.heading;
      if (canonical && canonical !== current) setLanguage(canonical);
    }).catch(e => { if (!catalog.signal.aborted) setError(e instanceof Error ? e.message : 'Language catalog unavailable.'); });
    const pop = () => { const p = new URLSearchParams(location.search); const q = p.get('q') || ''; const requestedKind = p.get('kind') || props.kind; const category = kinds.has(requestedKind) ? requestedKind : props.kind; if (q) void open(q, p.get('language') || props.language, category, locationFragment(), false); else { entryController?.abort(); ++entryVersion; searchController?.abort(); ++searchVersion; setLoading(false); setSearching(false); setError(''); setMatches([]); setMore(false); setQuery(''); setData(emptyResults); document.title = 'Dict · A local dictionary'; } };
    window.addEventListener('popstate', pop); if (query()) void open(query(), language(), kind(), locationFragment(), false);
    onCleanup(() => { catalog.abort(); searchController?.abort(); entryController?.abort(); window.removeEventListener('popstate', pop); });
  });
  const live: LiveOptions = {
    get query() { return query(); }, get language() { return language(); }, get kind() { return kind(); },
    get languages() { return languages(); }, get matches() { return matches(); }, get total() { return total(); },
    get hasMore() { return more(); }, get searching() { return searching(); }, get loading() { return loading(); }, get error() { return error(); },
    onQuery: value => { setQuery(value); setError(''); },
    onLanguage: value => { entryController?.abort(); ++entryVersion; setLoading(false); setLanguage(value); setData(emptyResults); },
    onKind: value => { entryController?.abort(); ++entryVersion; setLoading(false); setKind(value); setData(emptyResults); },
    onSelect: title => { void open(title); }, onMore: () => { void search(true); }, onHome: home,
  };
  const navigate = (target: Navigation) => { void open(target.title, target.language || language(), target.kind, target.fragment); };
  return <DictionaryApp data={data()} options={{ live, onNavigate: navigate }} />;
}
