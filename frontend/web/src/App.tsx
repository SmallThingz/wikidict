import { createMemo, createSignal, createUniqueId, For, onCleanup, onMount, Show } from 'solid-js';
import { Reading } from './entry';
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
  const [filter, setFilter] = createSignal('');
  const [selection, setSelection] = createSignal(Math.max(0, props.data.entries.findIndex(e => e.title === props.data.query)));
  const [tab, setTab] = createSignal<Tab>('reading');
  const [mobileIndex, setMobileIndex] = createSignal(false);
  const [notice, setNotice] = createSignal('');
  const theme = useTheme(() => root, !!props.options?.inheritedTheme);
  const filtered = createMemo(() => props.data.entries.map((entry, index) => ({ entry, index })).filter(item => item.entry.title.toLocaleLowerCase().includes(filter().toLocaleLowerCase())));
  const current = createMemo(() => filtered().find(item => item.index === selection()) ?? filtered()[0]);
  const entry = () => current()?.entry;
  const entryJson = () => JSON.stringify({ ...props.data, operation: 'lookup', match_mode: 'exact-utf8', query: entry()?.title ?? '', total_matches: entry() ? 1 : 0, offset: 0, has_more: false, matches: [], entries: entry() ? [entry()] : [] }, null, 2);
  const select = (index: number) => { setSelection(index); setMobileIndex(false); setNotice(''); queueMicrotask(() => root.scrollIntoView({ block: 'start' })); };
  const step = (delta: number) => {
    const list = filtered(); if (!list.length) return;
    const position = list.findIndex(item => item.index === current()?.index);
    setSelection(list[Math.max(0, Math.min(list.length - 1, position + delta))].index);
    queueMicrotask(() => root.querySelector('[aria-current="true"]')?.scrollIntoView({ block: 'nearest' }));
  };
  const navigate = (title: string, event: MouseEvent) => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button !== 0) return;
    const found = props.data.entries.findIndex(item => item.title === title);
    if (found >= 0) { event.preventDefault(); setFilter(''); select(found); setTab('reading'); }
    else if (props.options?.onNavigate) { event.preventDefault(); props.options.onNavigate({ title, language: entry()?.language ?? null, kind: 'language' }); }
  };
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
    const keydown = (event: KeyboardEvent) => {
      if (props.options?.inheritedTheme && !root.contains(event.target as Node)) return;
      const editable = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || (event.target instanceof HTMLElement && event.target.isContentEditable);
      if ((event.key === '/' && !editable) || ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k')) {
        event.preventDefault(); setMobileIndex(true); queueMicrotask(() => { search.focus(); search.select(); });
      }
      if (event.key === 'Escape') { if (appearanceMenu) appearanceMenu.open = false; setMobileIndex(false); search.blur(); }
    };
    document.addEventListener('keydown', keydown);
    onCleanup(() => document.removeEventListener('keydown', keydown));
  });
  return <div class="dict-app" ref={root}>
    <a class="dict-skip" href={`#${id}-content`}>Skip to entry</a>
    <header class="dict-topbar"><div class="dict-topbar-inner">
      <a class="dict-brand" href="#" onClick={event => { event.preventDefault(); setFilter(''); select(0); }}>dict<span>.</span></a>
      <span class="dict-topbar-context">WIKTIONARY <span>/</span> LOCAL EDITION</span>
      <div class="dict-topbar-actions"><button class="dict-mobile-toggle" aria-expanded={mobileIndex()} aria-controls={`${id}-index`} onClick={() => setMobileIndex(!mobileIndex())}>Index</button>
        <Show when={!props.options?.inheritedTheme}><details class="dict-appearance" ref={appearanceMenu}><summary aria-label="Appearance settings">Appearance <span aria-hidden="true">◐</span></summary>
          <div class="dict-appearance-panel"><label>Theme<select aria-label="Theme" value={theme.appearance().mode} onChange={event => theme.update({ mode: event.currentTarget.value })}><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option><option value="cool">Cool dark</option></select></label>
            <label>Type<select aria-label="Typeface" value={theme.appearance().font} onChange={event => theme.update({ font: event.currentTarget.value })}><option value="sans">Sans serif</option><option value="mono">Monospace</option></select></label>
            <label class="dict-accent-label">Accent<input type="color" aria-label="Accent color" value={theme.appearance().accent || '#2563eb'} onInput={event => theme.update({ accent: event.currentTarget.value })}/></label>
            <button onClick={() => theme.update({ accent: '', font: 'sans', mode: 'system' })}>Reset appearance</button>
          </div></details></Show>
      </div>
    </div></header>
    <div class="dict-workspace">
      <aside class="dict-index" id={`${id}-index`} classList={{ 'dict-index-open': mobileIndex() }} aria-label="Export index">
        <div class="dict-index-header"><span class="dict-eyebrow">IN THIS EXPORT</span><span class="dict-count">{props.data.entries.length.toLocaleString()}</span></div>
        <label class="dict-search"><span class="dict-sr">Filter exported entries</span><span aria-hidden="true">⌕</span><input ref={search} value={filter()} placeholder="Find a word…" spellcheck={false} aria-label="Filter exported entries" aria-controls={`${id}-results`} onInput={event => setFilter(event.currentTarget.value)} onKeyDown={event => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); step(event.key === 'ArrowDown' ? 1 : -1); }
          if (event.key === 'Enter') { setMobileIndex(false); content.focus(); }
        }}/><kbd>/</kbd></label>
        <nav id={`${id}-results`} class="dict-results" aria-label="Entries"><For each={filtered()}>{item => <button aria-current={item.index === current()?.index ? 'true' : undefined} onClick={() => select(item.index)}><span>{item.entry.title}</span><small>{item.entry.language ?? item.entry.kind.replaceAll('_', ' ')}</small><span class="dict-result-arrow" aria-hidden="true">↗</span></button>}</For></nav>
        <Show when={!filtered().length}><p class="dict-empty-index">No entries match this filter.</p></Show>
        <Show when={entry()}>{selected => <nav class="dict-contents" aria-label="Entry contents"><span class="dict-eyebrow">ON THIS PAGE</span><For each={selected().sections}>{(section, index) => <Show when={section.level > 2}><a href={`#${id}-section-${index()}`} style={{ 'padding-left': `${Math.max(0, section.level - 3) * 10}px` }} onClick={event => { event.preventDefault(); setTab('reading'); setMobileIndex(false); queueMicrotask(() => root.querySelector(`[id="${id}-section-${index()}"]`)?.scrollIntoView({ block: 'start' })); }}>{section.title}</a></Show>}</For></nav>}</Show>
        <footer class="dict-index-footer"><span>WIKBLB03</span><span>{props.data.record_count.toLocaleString()} records in source blob</span><span>{props.data.total_matches.toLocaleString()} {props.data.operation === 'search' ? 'prefix matches' : 'exact match(es)'} · export is self-contained</span></footer>
      </aside>
      <main class="dict-main"><Show when={entry()} fallback={<div class="dict-empty"><span class="dict-eyebrow">A DICTIONARY, WITHOUT THE DISTRACTIONS</span><h1>Words, in context.</h1><p>{props.data.entries.length ? 'No entries match your filter. Clear it to return to the exported words.' : 'This export contains no matching entries.'}</p><Show when={filter()}><button onClick={() => setFilter('')}>Clear filter</button></Show></div>}>{selected => <>
        <div class="dict-entry-header"><div class="dict-breadcrumb"><span>{selected().language ?? selected().kind.replaceAll('_', ' ')}</span><span aria-hidden="true">/</span><span>DICTIONARY ENTRY</span></div><h1 dir="auto">{selected().title}</h1><div class="dict-entry-meta"><span class="dict-badge">{selected().kind.replaceAll('_', ' ')}</span><span>{selected().sections.length} sections</span><span>Available offline</span></div></div>
        <div class="dict-toolbar"><div role="tablist" aria-label="Entry view"><For each={tabs}>{value => <button id={`${id}-tab-${value}`} role="tab" aria-selected={tab() === value} aria-controls={`${id}-content`} tabIndex={tab() === value ? 0 : -1} onClick={() => setTab(value)} onKeyDown={event => {
          if (event.key === 'ArrowRight' || event.key === 'ArrowLeft' || event.key === 'Home' || event.key === 'End') {
            event.preventDefault(); const next = event.key === 'Home' ? 0 : event.key === 'End' ? 2 : (tabs.indexOf(value) + (event.key === 'ArrowRight' ? 1 : 2)) % 3;
            setTab(tabs[next]); (root.querySelector(`[id="${id}-tab-${tabs[next]}"]`) as HTMLButtonElement)?.focus();
          }
        }}>{value === 'json' ? 'JSON' : value[0].toUpperCase() + value.slice(1)}</button>}</For></div><div class="dict-tools"><button onClick={copy}>Copy</button><button onClick={download}>Export JSON <span aria-hidden="true">↓</span></button></div></div>
        <Show when={selected().unexpanded_templates > 0 && tab() === 'reading'}><p class="dict-render-note">{selected().unexpanded_templates} templates are preserved, not expanded. Select a template chip to inspect its source.</p></Show>
        <div class="dict-entry-content" id={`${id}-content`} ref={content} role="tabpanel" aria-labelledby={`${id}-tab-${tab()}`} tabIndex={0}>
          <Show when={tab() === 'reading'}><Reading entry={selected()} prefix={`${id}-section`} navigate={navigate}/></Show>
          <Show when={tab() === 'source'}><div class="dict-source-label">{selected().source != null ? 'EXACT WIKITEXT · UNMODIFIED' : selected().source_base64 != null ? 'EXACT SOURCE BYTES · BASE64' : selected().payload_base64 != null ? 'INVALID PAYLOAD · BASE64' : 'SOURCE NOT INCLUDED'}</div><pre class="dict-source" dir="auto">{selected().source ?? selected().source_base64 ?? selected().payload_base64 ?? 'Export with --with-source to include the original wikitext.'}</pre></Show>
          <Show when={tab() === 'json'}><div class="dict-source-label">DICT.RESULTS.V1 · FRONTEND-NEUTRAL DATA</div><pre class="dict-source">{entryJson()}</pre></Show>
        </div>
        <footer class="dict-entry-footer"><span>Wiktionary source, local rendering.</span><a href={`https://en.wiktionary.org/wiki/${encodeURIComponent((selected().kind === 'language' ? '' : selected().kind === 'sign_gloss' ? 'Sign gloss:' : selected().kind[0].toUpperCase() + selected().kind.slice(1) + ':') + selected().title)}`} rel="noopener noreferrer">View original ↗</a></footer>
      </>}</Show></main>
    </div><div class="dict-toast" role="status" aria-live="polite" hidden={!notice()}>{notice()}</div>
  </div>;
}
