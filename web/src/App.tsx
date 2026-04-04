import { A, Route, useNavigate, useParams } from "@solidjs/router";
import {
  For,
  Show,
  createDeferred,
  createMemo,
  createResource,
  createSignal,
  onMount,
} from "solid-js";

import {
  type ApiEntry,
  type ApiLookupHit,
  type ApiStats,
  type ApiSuggestion,
  fetchLookup,
  fetchRandomWord,
  fetchStats,
  fetchSuggestions,
} from "./api";

const RECENTS_KEY = "dict-recents";
const FAVORITES_KEY = "dict-favorites";

type SourceBlock = {
  id: string;
  title: string;
  level: number;
  body: string;
};

export default function App() {
  return (
    <div class="app-shell">
      <div class="background-wash" />
      <div class="background-grid" />
      <Route path="/" component={HomePage} />
      <Route path="/entry/:term" component={EntryPage} />
    </div>
  );
}

function HomePage() {
  const navigate = useNavigate();
  const [stats] = createResource(fetchStats);
  const [recents, setRecents] = createSignal<string[]>([]);
  const [favorites, setFavorites] = createSignal<string[]>([]);

  onMount(() => {
    setRecents(loadList(RECENTS_KEY));
    setFavorites(loadList(FAVORITES_KEY));
  });

  return (
    <main class="page">
      <section class="hero">
        <div class="eyebrow">Lossless English Wiktionary</div>
        <h1>Compact binary storage, raw formatting preserved, and lookup indices built at load time.</h1>
        <p class="hero-copy">
          The Zig backend stores each English entry as compact raw wikitext and rebuilds spelling metadata after
          load. The browser never sees the XML dump, and the original entry formatting is still intact.
        </p>
        <SearchCard onCommit={(value) => navigate(`/entry/${encodeURIComponent(value)}`)} />
      </section>

      <section class="dashboard-grid">
        <article class="panel stats-panel">
          <div class="panel-title">Dictionary Stats</div>
          <Show when={stats()} fallback={<div class="muted">Loading stats…</div>}>
            {(data) => <StatsGrid stats={data()} />}
          </Show>
        </article>

        <article class="panel">
          <div class="panel-title">Recently Viewed</div>
          <TokenList
            empty="No recent lookups yet."
            values={recents()}
            onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
          />
        </article>

        <article class="panel">
          <div class="panel-title">Saved Words</div>
          <TokenList
            empty="Favorite words from any entry page."
            values={favorites()}
            onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
          />
        </article>
      </section>
    </main>
  );
}

function EntryPage() {
  const navigate = useNavigate();
  const params = useParams();
  const term = createMemo(() => decodeURIComponent(params.term ?? ""));
  const [hits] = createResource(term, fetchLookup);
  const [favorites, setFavorites] = createSignal<string[]>([]);

  onMount(() => setFavorites(loadList(FAVORITES_KEY)));

  const primaryWord = createMemo(() => hits()?.[0]?.entry.word ?? term());

  const toggleFavorite = () => {
    const current = loadList(FAVORITES_KEY);
    const next = current.includes(primaryWord())
      ? current.filter((item) => item !== primaryWord())
      : [...current, primaryWord()];
    saveList(FAVORITES_KEY, next.slice(0, 12));
    setFavorites(next);
  };

  return (
    <main class="page">
      <header class="entry-topbar">
        <A class="back-link" href="/">
          Home
        </A>
        <SearchCard
          compact
          initialValue={term()}
          onCommit={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
        />
      </header>

      <Show when={hits()} fallback={<article class="panel">Loading entry…</article>}>
        {(data) => (
          <Show when={data().length > 0} fallback={<article class="panel">No entry found for “{term()}”.</article>}>
            <section class="entry-stack">
              <div class="entry-hero">
                <div>
                  <div class="eyebrow">Lookup</div>
                  <h1>{primaryWord()}</h1>
                  <p class="hero-copy">
                    Query <code>{term()}</code> matched {data().length} entry{data().length === 1 ? "" : "ies"}.
                  </p>
                </div>
                <div class="entry-actions">
                  <button class="action-button" type="button" onClick={toggleFavorite}>
                    {favorites().includes(primaryWord()) ? "Remove Favorite" : "Save Word"}
                  </button>
                </div>
              </div>

              <For each={data()}>{(hit, index) => <EntryCard hit={hit} rank={index() + 1} />}</For>
            </section>
          </Show>
        )}
      </Show>
    </main>
  );
}

function EntryCard(props: { hit: ApiLookupHit; rank: number }) {
  const [view, setView] = createSignal<"blocks" | "raw">("blocks");
  const blocks = createMemo(() => splitRawEntry(props.hit.entry));
  const matchIsAlias = createMemo(() => props.hit.matched !== props.hit.entry.word);

  onMount(() => pushRecent(props.hit.entry.word));

  const copyRaw = async () => {
    if (!props.hit.entry.raw || typeof navigator === "undefined" || !navigator.clipboard) return;
    await navigator.clipboard.writeText(props.hit.entry.raw);
  };

  return (
    <article class="entry-card panel">
      <div class="entry-card-head">
        <div>
          <div class="entry-rank">Match {props.rank}</div>
          <h2>{props.hit.entry.word}</h2>
          <Show when={matchIsAlias()}>
            <p class="match-note">
              Matched via <span>{props.hit.matched}</span> as an{" "}
              {props.hit.kind === "alternative_form" ? "alternative spelling" : "exact title"} lookup.
            </p>
          </Show>
          <Show when={props.hit.entry.aliasOnly}>
            <div class="alias-flag">Alias-style entry</div>
          </Show>
        </div>
        <div class="summary-pill">{props.hit.entry.summary || "No summary extracted"}</div>
      </div>

      <div class="meta-grid">
        <MetaLine title="Canonical targets" values={props.hit.entry.canonicalTargets} />
        <MetaLine title="Alternative forms" values={props.hit.entry.altForms} />
        <MetaLine title="Incoming aliases" values={props.hit.entry.incomingAliases} />
      </div>

      <Show
        when={props.hit.entry.raw}
        fallback={
          <div class="panel-note">
            This entry is stored without a raw English section. It behaves as an alias or redirect entry.
          </div>
        }
      >
        <div class="entry-source-toolbar">
          <div class="panel-note">Source formatting is preserved exactly in the binary.</div>
          <div class="view-toggle">
            <button
              classList={{ "ghost-button": true, active: view() === "blocks" }}
              type="button"
              onClick={() => setView("blocks")}
            >
              Section View
            </button>
            <button
              classList={{ "ghost-button": true, active: view() === "raw" }}
              type="button"
              onClick={() => setView("raw")}
            >
              Raw Source
            </button>
            <button class="ghost-button" type="button" onClick={copyRaw}>
              Copy Source
            </button>
          </div>
        </div>

        <Show when={view() === "blocks"} fallback={<pre class="source-pre raw-view">{props.hit.entry.raw}</pre>}>
          <section class="source-block-grid">
            <For each={blocks()}>
              {(block) => (
                <article class="source-block">
                  <div class="section-kicker">Level {block.level}</div>
                  <h3>{block.title}</h3>
                  <pre class="source-pre">{block.body}</pre>
                </article>
              )}
            </For>
          </section>
        </Show>
      </Show>
    </article>
  );
}

function SearchCard(props: {
  onCommit: (value: string) => void;
  initialValue?: string;
  compact?: boolean;
}) {
  const navigate = useNavigate();
  const [query, setQuery] = createSignal(props.initialValue ?? "");
  const [open, setOpen] = createSignal(false);
  const [activeIndex, setActiveIndex] = createSignal(0);

  const deferred = createDeferred(query);
  const [suggestions] = createResource(
    () => deferred().trim(),
    (value) => fetchSuggestions(value),
  );

  const handleCommit = (value: string) => {
    const next = value.trim();
    if (!next) return;
    props.onCommit(next);
    setOpen(false);
  };

  const handleRandom = async () => {
    const word = await fetchRandomWord();
    navigate(`/entry/${encodeURIComponent(word)}`);
  };

  return (
    <div classList={{ "search-card": true, compact: props.compact === true }}>
      <div class="search-input-row">
        <input
          class="search-input"
          value={query()}
          placeholder="Search a word or alternate spelling"
          onInput={(event) => {
            setQuery(event.currentTarget.value);
            setOpen(true);
            setActiveIndex(0);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => queueMicrotask(() => setOpen(false))}
          onKeyDown={(event) => {
            const nextSuggestions = suggestions() ?? [];
            if (event.key === "ArrowDown" && nextSuggestions.length > 0) {
              event.preventDefault();
              setActiveIndex((index) => Math.min(index + 1, nextSuggestions.length - 1));
              return;
            }
            if (event.key === "ArrowUp" && nextSuggestions.length > 0) {
              event.preventDefault();
              setActiveIndex((index) => Math.max(index - 1, 0));
              return;
            }
            if (event.key === "Enter") {
              event.preventDefault();
              const active = nextSuggestions[activeIndex()];
              handleCommit(active?.matched ?? query());
            }
            if (event.key === "Escape") {
              setOpen(false);
            }
          }}
        />
        <button class="primary-button" type="button" onClick={() => handleCommit(query())}>
          Search
        </button>
        <button class="ghost-button" type="button" onClick={handleRandom}>
          Random
        </button>
      </div>

      <Show when={open() && (suggestions()?.length ?? 0) > 0}>
        <div class="suggestion-panel">
          <For each={suggestions()}>
            {(suggestion, index) => (
              <button
                classList={{ "suggestion-item": true, active: index() === activeIndex() }}
                type="button"
                onMouseDown={(event) => {
                  event.preventDefault();
                  handleCommit(suggestion.matched);
                }}
              >
                <div class="suggestion-head">
                  <span>{suggestion.matched}</span>
                  <span class="suggestion-kind">
                    {suggestion.kind === "alternative_form" ? "alternate spelling" : "title"}
                  </span>
                </div>
                <div class="suggestion-summary">
                  <strong>{suggestion.word}</strong>
                  <Show when={suggestion.summary}>
                    <span>{suggestion.summary}</span>
                  </Show>
                </div>
              </button>
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}

function StatsGrid(props: { stats: ApiStats }) {
  return (
    <div class="stats-grid">
      <StatTile label="Entries" value={formatNumber(props.stats.entries)} />
      <StatTile label="Raw Entries" value={formatNumber(props.stats.rawEntries)} />
      <StatTile label="Redirects" value={formatNumber(props.stats.redirects)} />
      <StatTile label="Lookups" value={formatNumber(props.stats.lookups)} />
    </div>
  );
}

function StatTile(props: { label: string; value: string }) {
  return (
    <div class="stat-tile">
      <div class="stat-value">{props.value}</div>
      <div class="stat-label">{props.label}</div>
    </div>
  );
}

function MetaLine(props: { title: string; values: string[] }) {
  return (
    <Show when={props.values.length > 0}>
      <div class="meta-line">
        <div class="meta-title">{props.title}</div>
        <div class="chip-row">
          <For each={props.values}>{(value) => <span class="chip">{value}</span>}</For>
        </div>
      </div>
    </Show>
  );
}

function TokenList(props: {
  values: string[];
  empty: string;
  onSelect: (value: string) => void;
}) {
  return (
    <Show when={props.values.length > 0} fallback={<div class="muted">{props.empty}</div>}>
      <div class="chip-row">
        <For each={props.values}>
          {(value) => (
            <button class="chip interactive" type="button" onClick={() => props.onSelect(value)}>
              {value}
            </button>
          )}
        </For>
      </div>
    </Show>
  );
}

function splitRawEntry(entry: ApiEntry): SourceBlock[] {
  if (!entry.raw) return [];

  const blocks: SourceBlock[] = [];
  let current: SourceBlock | null = null;

  for (const line of entry.raw.split("\n")) {
    const heading = parseHeading(line);
    if (heading) {
      if (current) current.body = current.body.trimEnd();
      current = {
        id: `${heading.level}:${heading.title}:${blocks.length}`,
        title: heading.title,
        level: heading.level,
        body: "",
      };
      blocks.push(current);
      continue;
    }

    if (!current) {
      current = {
        id: "lead",
        title: entry.word,
        level: 1,
        body: "",
      };
      blocks.push(current);
    }
    current.body += current.body ? `\n${line}` : line;
  }

  if (current) current.body = current.body.trimEnd();
  return blocks.filter((block) => block.body || block.title);
}

function parseHeading(line: string): { level: number; title: string } | null {
  const match = line.match(/^(={2,6})\s*(.*?)\s*\1$/);
  if (!match) return null;
  return {
    level: match[1].length,
    title: match[2],
  };
}

function pushRecent(word: string) {
  const next = toggleListValue(RECENTS_KEY, word, true);
  saveList(RECENTS_KEY, next.slice(0, 8));
}

function toggleListValue(key: string, value: string, prepend = false): string[] {
  const current = loadList(key).filter((item) => item !== value);
  const next = prepend ? [value, ...current] : [...current, value];
  saveList(key, next.slice(0, 12));
  return loadList(key);
}

function loadList(key: string): string[] {
  if (typeof localStorage === "undefined") return [];
  const raw = localStorage.getItem(key);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function saveList(key: string, values: string[]) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(key, JSON.stringify(values));
}

function formatNumber(value: number) {
  return new Intl.NumberFormat().format(value);
}
