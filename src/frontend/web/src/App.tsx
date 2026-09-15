import { createEffect, createMemo, createSignal, createUniqueId, For, onCleanup, onMount, Show } from 'solid-js';
import { Reading } from './entry';
import { LearningPanel } from './learning.tsx';
import { createLearningStore, savedWord, type SavedWord } from './learning';
import { navigation, reveal } from './organization';
import { useTheme } from './theme';
import type { MountOptions, Results } from './types';
import './style.css';

type Tab = 'reading' | 'source' | 'json';
const tabs: Tab[] = ['reading', 'source', 'json'];
export function DictionaryApp(props: { data: Results; options?: MountOptions }) {
  let root!: HTMLDivElement;
  let search!: HTMLInputElement;
  let content!: HTMLDivElement;
  let appearanceMenu!: HTMLDetailsElement;
  const id = createUniqueId();
  const [localFilter, setLocalFilter] = createSignal('');
  const live = () => props.options?.live;
  const filter = () => live()?.query ?? localFilter();
  const setFilter = (value: string) => {setSelection(0); if(live()) live()!.onQuery(value); else setLocalFilter(value);};
  const [selection, setSelection] = createSignal(Math.max(0, props.data.entries.findIndex(e => e.title === props.data.query)));
  const [tab, setTab] = createSignal<Tab>('reading');
  const [mobileIndex, setMobileIndex] = createSignal(false);
  const [notice, setNotice] = createSignal('');
  const [learningOpen, setLearningOpen] = createSignal(false);
  const learning = createLearningStore();
  const mobileQuery = matchMedia('(max-width: 720px)');
  const [mobileViewport, setMobileViewport] = createSignal(mobileQuery.matches);
  const initialOverflow = document.documentElement.style.overflow;
  createEffect(() => {
    document.documentElement.style.overflow = mobileIndex() && mobileViewport() ? 'hidden' : initialOverflow;
  });
  onCleanup(() => { document.documentElement.style.overflow = initialOverflow; });
  const theme = useTheme(() => root, !!props.options?.inheritedTheme);
  const filtered = createMemo(() => live() ? live()!.matches.map((m,index) => ({entry: {title:m.title,language:live()!.kind==='language' ? live()!.language : null,kind:live()!.kind},index})) : props.data.entries.map((entry, index) => ({ entry, index })).filter(item => item.entry.title.toLocaleLowerCase().includes(filter().toLocaleLowerCase())));
  const current = createMemo(() => filtered().find(item => item.index === selection()) ?? filtered()[0]);
  const entry = () => live() ? props.data.entries[0] : props.data.entries[current()?.index ?? -1];
  const learningFallback = createMemo(() => props.data.entries.map(savedWord));
  let lastRecorded = '';
  createEffect(() => {
    const selected = entry(); if (!selected) return;
    const key = savedWord(selected).key;
    if (key !== lastRecorded) { lastRecorded = key; learning.record(selected); }
  });
  const entryJson = () => JSON.stringify({ ...props.data, operation: 'lookup', match_mode: 'exact-utf8', query: entry()?.title ?? '', total_matches: entry() ? 1 : 0, offset: 0, has_more: false, matches: [], entries: entry() ? [entry()] : [] }, null, 2);
  const select = (index: number) => { if (live()) { const match=live()!.matches[index]; if(match) live()!.onSelect(match.title); setMobileIndex(false); setTab('reading'); return; } setSelection(index); setMobileIndex(false); setNotice(''); queueMicrotask(() => root.scrollIntoView({ block: 'start' })); };
  const step = (delta: number) => {
    const list = filtered(); if (!list.length) return;
    const position = list.findIndex(item => item.index === current()?.index);
    setSelection(list[Math.max(0, Math.min(list.length - 1, position + delta))].index);
    queueMicrotask(() => root.querySelector('[aria-current="true"]')?.scrollIntoView({ block: 'nearest' }));
  };
  const navigate = (raw: string, event: MouseEvent, language?: string) => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button !== 0) return;
    const hash = raw.indexOf('#');
    const title = (hash < 0 ? raw : raw.slice(0, hash)) || entry()?.title || '';
    let fragment = hash < 0 ? '' : raw.slice(hash + 1);
    try { fragment = decodeURIComponent(fragment); } catch { /* Retain a literal malformed fragment. */ }
    if (live() && props.options?.onNavigate) { if (/^(?:w|wikipedia|d|commons|s|wikisource|File|Image|Template|Module|Appendix|Wiktionary|Category):/i.test(title)) return; event.preventDefault();setTab('reading');setMobileIndex(false);props.options.onNavigate({title,fragment,language:language || live()!.language,kind:'language'});return; }
    const found = props.data.entries.findIndex(item => item.title === title && (!language || item.language_code === language || item.language === language));
    if (found >= 0) {
      event.preventDefault(); setFilter(''); select(found); setTab('reading');
      if (fragment) queueMicrotask(() => { const heading = fragment.replaceAll('_', ' ').trim(); const section = props.data.entries[found].sections.findIndex(s => s.title === heading); if (section >= 0) reveal(root.querySelector(`[id="${id}-section-${section}"]`)); });
    } else if (props.options?.onNavigate) {
      event.preventDefault(); props.options.onNavigate({ title, fragment, language: language || entry()?.language || null, kind: 'language' });
    }
  };
  const openSaved = (word: SavedWord) => {
    setLearningOpen(false); setTab('reading'); setMobileIndex(false);
    if (live() && props.options?.onNavigate) {
      props.options.onNavigate({ title: word.title, language: word.language, kind: word.kind });
      return;
    }
    const found = props.data.entries.findIndex(item => item.title === word.title && item.kind === word.kind && (!word.language || item.language === word.language));
    if (found >= 0) { setFilter(''); setSelection(found); queueMicrotask(() => root.scrollIntoView({ block: 'start' })); }
    else setNotice('That saved word is not included in this export.');
  };
  const randomWord = () => {
    if (live() && learning.state().settings.randomPool === 'all') { setLearningOpen(false); live()!.onRandom(); return; }
    const pool = learning.pool(learningFallback());
    if (!pool.length) { setNotice('No words are available for that random-word source yet.'); return; }
    openSaved(pool[Math.floor(Math.random() * pool.length)]);
  };
  const bookmarked = () => { const selected = entry(); return !!selected && learning.isBookmarked(savedWord(selected).key); };
  const copy = async () => {
    const value = tab() === 'json' ? entryJson() : tab() === 'source' ? entry()?.source ?? entry()?.source_base64 ?? entry()?.payload_base64 ?? '' : content.innerText;
    try { await navigator.clipboard.writeText(value); setNotice('Copied to clipboard.'); }
    catch { setNotice('Clipboard unavailable. Select and copy the visible text instead.'); }
  };
  const download = () => {
    const url = URL.createObjectURL(new Blob([entryJson()], { type: 'application/json;charset=utf-8' }));
    const link = document.createElement('a'); link.href = url; link.download = 'dict-entry.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  onMount(() => {
    theme.apply();
    const viewportChanged = (event: MediaQueryListEvent) => {
      setMobileViewport(event.matches);
      if (!event.matches) setMobileIndex(false);
    };
    mobileQuery.addEventListener('change', viewportChanged);
    const keydown = (event: KeyboardEvent) => {
      if (props.options?.inheritedTheme && !root.contains(event.target as Node)) return;
      const editable = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || (event.target instanceof HTMLElement && event.target.isContentEditable);
      if ((event.key === '/' && !editable) || ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k')) {
        event.preventDefault(); setMobileIndex(true); queueMicrotask(() => { search.focus(); search.select(); });
      }
      if (event.key === 'Escape') { if (learningOpen()) setLearningOpen(false); else { if (appearanceMenu) appearanceMenu.open = false; setMobileIndex(false); search.blur(); } }
    };
    document.addEventListener('keydown', keydown);
    onCleanup(() => {
      document.removeEventListener('keydown', keydown);
      mobileQuery.removeEventListener('change', viewportChanged);
    });
  });
  return <div class="dict-app" ref={root}>
    <a class="dict-skip" href={`#${id}-content`}>Skip to entry</a>
    <header class="dict-topbar"><div class="dict-topbar-inner">
      <a class="dict-brand" href="#" onClick={event => { event.preventDefault(); if (live()) { live()!.onHome(); setMobileIndex(false); setTab('reading'); } else { setFilter(''); select(0); } }}>dict<span>.</span></a>
      <span class="dict-topbar-context">Local Wiktionary <span>·</span> private, fast, offline</span>
      <div class="dict-topbar-actions"><button class="dict-header-action" onClick={randomWord}>Random</button><button class="dict-header-action" onClick={() => setLearningOpen(true)}>Learn <Show when={learning.state().bookmarks.length}><span class="dict-action-count">{learning.state().bookmarks.length}</span></Show></button><button class="dict-mobile-toggle" aria-expanded={mobileIndex()} aria-controls={`${id}-index`} onClick={() => { const next = !mobileIndex(); setMobileIndex(next); if (next) queueMicrotask(() => { search.focus(); search.select(); }); }}>{mobileIndex() ? 'Close' : live() ? 'Search' : 'Entries'}</button>
        <Show when={!props.options?.inheritedTheme}><details class="dict-appearance" ref={appearanceMenu}><summary aria-label="Appearance settings">Appearance <span aria-hidden="true">◐</span></summary>
          <div class="dict-appearance-panel"><label>Theme<select aria-label="Theme" value={theme.appearance().mode} onChange={event => theme.update({ mode: event.currentTarget.value })}><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option><option value="cool">Cool dark</option></select></label>
            <label>Type<select aria-label="Typeface" value={theme.appearance().font} onChange={event => theme.update({ font: event.currentTarget.value })}><option value="sans">Sans serif</option><option value="mono">Monospace</option></select></label>
            <label class="dict-accent-label">Accent<input type="color" aria-label="Accent color" value={theme.appearance().accent || '#2563eb'} onInput={event => theme.update({ accent: event.currentTarget.value })}/></label>
            <button onClick={() => theme.update({ accent: '', font: 'sans', mode: 'system' })}>Reset appearance</button>
          </div></details></Show>
      </div>
    </div></header>
    <div class="dict-workspace">
      <aside class="dict-index" id={`${id}-index`} classList={{ 'dict-index-open': mobileIndex() }} aria-label={live() ? 'Dictionary search' : 'Export index'}>
        <div class="dict-index-header"><span class="dict-eyebrow">{live() ? 'DICTIONARY' : 'IN THIS EXPORT'}</span><span class="dict-count">{(live()?.total ?? props.data.entries.length).toLocaleString()}</span></div>
        <Show when={live()}>{state => <div class="dict-live-selectors"><label>Collection<select aria-label="Dictionary collection" value={state().kind} onChange={event => state().onKind(event.currentTarget.value)}><option value="language">Dictionary</option><option value="thesaurus">Thesaurus</option><option value="citations">Citations</option><option value="reconstruction">Reconstruction</option><option value="rhymes">Rhymes</option><option value="sign_gloss">Sign gloss</option></select></label><Show when={state().kind==='language'}><label>Language<select aria-label="Dictionary language" value={state().language} onChange={event => state().onLanguage(event.currentTarget.value)}><For each={state().languages}>{lang => <option value={lang.heading} selected={lang.heading === state().language}>{lang.heading}</option>}</For></select></label></Show></div>}</Show>
        <div class="dict-mobile-learning"><button onClick={randomWord}>Random word</button><button onClick={() => { setLearningOpen(true); setMobileIndex(false); }}>Learn & saved</button></div>
        <label class="dict-search"><span class="dict-sr">Filter exported entries</span><span aria-hidden="true">⌕</span><input ref={search} value={filter()} placeholder="Find a word…" spellcheck={false} aria-label={live() ? 'Search dictionary' : 'Filter exported entries'} aria-controls={`${id}-results`} onInput={event => setFilter(event.currentTarget.value)} onKeyDown={event => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); step(event.key === 'ArrowDown' ? 1 : -1); }
          if (event.key === 'Enter') { if(live()) select(current()?.index ?? 0); else {setMobileIndex(false);content?.focus();} }
        }}/><kbd>/</kbd></label>
        <nav id={`${id}-results`} class="dict-results" aria-label="Entries"><For each={filtered()}>{item => <button aria-current={item.index === current()?.index ? 'true' : undefined} onClick={() => select(item.index)}><span>{item.entry.title}</span><small>{item.entry.language ?? item.entry.kind.replaceAll('_', ' ')}</small><span class="dict-result-arrow" aria-hidden="true">→</span></button>}</For></nav>
        <Show when={live()?.hasMore}><button class="dict-more-results" disabled={live()?.searching} onClick={() => live()?.onMore()}>More matches</button></Show>
        <Show when={!filtered().length && !live()?.searching}><p class="dict-empty-index">No entries match this filter.</p></Show>
        <Show when={entry()}>{selected => <nav class="dict-contents" aria-label="Entry contents"><span class="dict-eyebrow">ON THIS PAGE</span><For each={navigation(selected())}>{item => <a href={`#${id}-section-${item.index}`} onClick={event => { event.preventDefault(); setTab('reading'); setMobileIndex(false); queueMicrotask(() => reveal(root.querySelector(`[id="${id}-section-${item.index}"]`))); }}>{item.label}</a>}</For></nav>}</Show>
        <Show when={live()}><p class="dict-live-hint"><kbd>↑</kbd><kbd>↓</kbd> choose · <kbd>Enter</kbd> open · <kbd>Esc</kbd> close</p></Show><footer class="dict-index-footer"><span>{props.data.operation === "render" ? "WIKITEXT" : "WIKBLB05"}</span><span>{props.data.operation === "render" ? "Rendered local source" : `${props.data.record_count.toLocaleString()} records in source blob`}</span><span>{props.data.total_matches.toLocaleString()} {props.data.operation === 'search' ? 'prefix matches' : 'exact match(es)'} · {live() ? 'live local database' : 'export is self-contained'}</span></footer>
      </aside>
      <main class="dict-main"><Show when={live()?.loading || live()?.searching}><p class="dict-live-status" role="status">{live()?.loading ? 'Loading entry…' : 'Searching…'}</p></Show><Show when={live()?.error}><p class="dict-notice" role="alert">{live()?.error}</p></Show><Show when={entry()} fallback={<div class="dict-empty"><span class="dict-eyebrow">LOCAL WIKTIONARY</span><h1>Find the word.</h1><p>{live() ? 'Type a word or prefix. Definitions, examples, pronunciation and history stay together in one reading view.' : props.data.entries.length ? 'No entries match your filter. Clear it to return to the exported words.' : 'This export contains no matching entries.'}</p><Show when={filter()}><button onClick={() => setFilter('')}>Clear filter</button></Show></div>}>{selected => <>
        <div class="dict-entry-header"><div class="dict-breadcrumb"><span>{selected().language ?? selected().kind.replaceAll('_', ' ')}</span><span aria-hidden="true">/</span><span>DICTIONARY ENTRY</span></div><h1 dir="auto">{selected().title}</h1><div class="dict-entry-meta"><span class="dict-badge">{selected().kind.replaceAll('_', ' ')}</span><span>{selected().sections.length} sections</span><span>{live() ? 'Local database' : 'Available offline'}</span><Show when={selected().expansion?.status === "failed"}><span>Some templates unavailable</span></Show><button class="dict-bookmark" classList={{ active: bookmarked() }} aria-pressed={bookmarked()} onClick={() => learning.toggleBookmark(selected())}>{bookmarked() ? '★ Saved' : '☆ Bookmark'}</button></div></div>
        <Show when={!live()}><div class="dict-toolbar"><div role="tablist" aria-label="Entry view"><For each={tabs}>{value => <button id={`${id}-tab-${value}`} role="tab" aria-selected={tab() === value} aria-controls={`${id}-content`} tabIndex={tab() === value ? 0 : -1} onClick={() => setTab(value)} onKeyDown={event => {
          if (event.key === 'ArrowRight' || event.key === 'ArrowLeft' || event.key === 'Home' || event.key === 'End') {
            event.preventDefault(); const next = event.key === 'Home' ? 0 : event.key === 'End' ? 2 : (tabs.indexOf(value) + (event.key === 'ArrowRight' ? 1 : 2)) % 3;
            setTab(tabs[next]); (root.querySelector(`[id="${id}-tab-${tabs[next]}"]`) as HTMLButtonElement)?.focus();
          }
        }}>{value === 'json' ? 'JSON' : value[0].toUpperCase() + value.slice(1)}</button>}</For></div><div class="dict-tools"><button onClick={copy}>Copy</button><button onClick={download}>Export JSON <span aria-hidden="true">↓</span></button></div></div></Show>
        <Show when={selected().unexpanded_templates > 0 && tab() === 'reading'}><p class="dict-render-note">{selected().unexpanded_templates} unsupported templates need additional definitions. Their source remains inspectable; supported templates and wikitext are rendered.</p></Show>
        <Show when={selected().expansion?.status === "failed"}><p class="dict-notice" role="alert">Lua expansion failed. This is native fallback rendering: {selected().expansion?.diagnostic}</p></Show>
        <div class="dict-entry-content" id={`${id}-content`} ref={content} role={live() ? 'region' : 'tabpanel'} aria-label={live() ? 'Dictionary entry' : undefined} aria-labelledby={live() ? undefined : `${id}-tab-${tab()}`} tabIndex={0}>
          <Show when={tab() === 'reading'}><Reading entry={selected()} prefix={`${id}-section`} navigate={navigate}/></Show>
          <Show when={tab() === 'source'}><div class="dict-source-label">{selected().source != null ? 'EXACT WIKITEXT · UNMODIFIED' : selected().source_base64 != null ? 'EXACT SOURCE BYTES · BASE64' : selected().payload_base64 != null ? 'INVALID PAYLOAD · BASE64' : 'SOURCE NOT INCLUDED'}</div><pre class="dict-source" dir="auto">{selected().source ?? selected().source_base64 ?? selected().payload_base64 ?? (selected().content === 'core' ? 'This core-only export does not contain the complete source. Re-export without --core-only and with --with-source after installing the matching companions.' : 'Export with --with-source to include the original wikitext.')}</pre></Show>
          <Show when={tab() === 'json'}><div class="dict-source-label">DICT.RESULTS.V1 · FRONTEND-NEUTRAL DATA</div><pre class="dict-source">{entryJson()}</pre></Show>
        </div>
        <footer class="dict-entry-footer"><span>Wiktionary source, local rendering.</span><a href={`https://en.wiktionary.org/wiki/${encodeURIComponent((selected().kind === 'language' ? '' : selected().kind === 'sign_gloss' ? 'Sign gloss:' : selected().kind[0].toUpperCase() + selected().kind.slice(1) + ':') + selected().title)}`} rel="noopener noreferrer">View original ↗</a></footer>
      </>}</Show></main>
    </div><Show when={learningOpen()}><LearningPanel store={learning} current={entry()} fallback={learningFallback()} openWord={openSaved} randomWord={randomWord} close={() => setLearningOpen(false)}/></Show><div class="dict-toast" role="status" aria-live="polite" hidden={!notice()}>{notice()}</div>
  </div>;
}
