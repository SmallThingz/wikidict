import { A, useLocation, useNavigate, useParams } from "@solidjs/router";
import {
  For,
  Show,
  type ParentProps,
  createEffect,
  createDeferred,
  createMemo,
  createResource,
  createSignal,
  onCleanup,
  onMount,
} from "solid-js";
import { Dynamic } from "solid-js/web";

import {
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
const THEME_MODE_KEY = "dict-theme-mode";
const COLOR_SCHEME_KEY = "dict-color-scheme";
const WIDTH_MODE_KEY = "dict-width-mode";
const THEME_KEYS = ["linen", "reef", "ember", "graphite"] as const;
const WIDTH_MODES = ["narrow", "standard", "wide"] as const;

type ThemeKey = (typeof THEME_KEYS)[number];
type ThemeMode = ThemeKey | "auto";
type ColorSchemeMode = "system" | "light" | "dark";
type WidthMode = (typeof WIDTH_MODES)[number];

export default function App(props: ParentProps) {
  const location = useLocation();
  const [themeMode, setThemeMode] = createSignal<ThemeMode>("auto");
  const [colorSchemeMode, setColorSchemeMode] = createSignal<ColorSchemeMode>("system");
  const [widthMode, setWidthMode] = createSignal<WidthMode>("standard");
  const [prefersDark, setPrefersDark] = createSignal(false);

  onMount(() => {
    const stored = readStoredThemeMode();
    if (stored) setThemeMode(stored);

    const storedScheme = readStoredColorScheme();
    if (storedScheme) setColorSchemeMode(storedScheme);

    const storedWidth = readStoredWidthMode();
    if (storedWidth) setWidthMode(storedWidth);

    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const updateScheme = () => setPrefersDark(media.matches);
    updateScheme();
    media.addEventListener("change", updateScheme);
    onCleanup(() => media.removeEventListener("change", updateScheme));
  });

  const activeTheme = createMemo<ThemeKey>(() => {
    const mode = themeMode();
    return mode === "auto" ? deriveThemeFromPath(location.pathname) : mode;
  });

  const activeColorScheme = createMemo<"light" | "dark">(() => {
    const mode = colorSchemeMode();
    if (mode === "system") return prefersDark() ? "dark" : "light";
    return mode;
  });

  const cycleTheme = () => {
    const modes: ThemeMode[] = ["auto", ...THEME_KEYS];
    const currentIndex = modes.indexOf(themeMode());
    const next = modes[(currentIndex + 1) % modes.length];
    setThemeMode(next);
    if (typeof localStorage !== "undefined") localStorage.setItem(THEME_MODE_KEY, next);
  };

  const themeLabel = createMemo(() => {
    const mode = themeMode();
    return mode === "auto" ? `Auto · ${titleCase(activeTheme())}` : titleCase(mode);
  });

  const cycleColorScheme = () => {
    const modes: ColorSchemeMode[] = ["system", "light", "dark"];
    const currentIndex = modes.indexOf(colorSchemeMode());
    const next = modes[(currentIndex + 1) % modes.length];
    setColorSchemeMode(next);
    if (typeof localStorage !== "undefined") localStorage.setItem(COLOR_SCHEME_KEY, next);
  };

  const colorSchemeLabel = createMemo(() => {
    const mode = colorSchemeMode();
    if (mode === "system") return `System · ${titleCase(activeColorScheme())}`;
    return titleCase(mode);
  });

  const cycleWidth = () => {
    const currentIndex = WIDTH_MODES.indexOf(widthMode());
    const next = WIDTH_MODES[(currentIndex + 1) % WIDTH_MODES.length];
    setWidthMode(next);
    if (typeof localStorage !== "undefined") localStorage.setItem(WIDTH_MODE_KEY, next);
  };

  const widthLabel = createMemo(() => titleCase(widthMode()));

  return (
    <div class="app-shell" data-theme={activeTheme()} data-scheme={activeColorScheme()} data-width={widthMode()}>
      <header class="site-header">
        <div class="header-container">
          <A class="wordmark" href="/">
            <span>dict</span>
            <small>en.wiktionary</small>
          </A>
          <div class="header-controls">
            <button class="theme-toggle" type="button" onClick={cycleWidth}>
              Width: {widthLabel()}
            </button>
            <button class="theme-toggle" type="button" onClick={cycleColorScheme}>
              Appearance: {colorSchemeLabel()}
            </button>
            <button class="theme-toggle" type="button" onClick={cycleTheme}>
              Palette: {themeLabel()}
            </button>
          </div>
        </div>
      </header>
      <div class="page-frame">{props.children}</div>
    </div>
  );
}

export { EntryPage, HomePage };

function HomePage() {
  const navigate = useNavigate();
  const [stats] = createResource(fetchStats);
  const [recents, setRecents] = createSignal<string[]>([]);
  const [favorites, setFavorites] = createSignal<string[]>([]);
  const statsError = createMemo(() => resourceErrorMessage(stats.error, "Failed to load dictionary stats."));

  onMount(() => {
    setRecents(loadList(RECENTS_KEY));
    setFavorites(loadList(FAVORITES_KEY));
  });

  return (
    <main class="page home-page">
      <section class="masthead">
        <div class="eyebrow">English Wiktionary</div>
        <h1>Dictionary</h1>
        <SearchCard onCommit={(value) => navigate(`/entry/${encodeURIComponent(value)}`)} />
      </section>

      <section class="stats-strip" aria-label="Dictionary stats">
        <Show
          when={stats()}
          fallback={
            <Show when={statsError()} fallback={<span class="strip-muted">Loading dictionary stats…</span>}>
              {(message) => <div class="inline-error">{message()}</div>}
            </Show>
          }
        >
          {(data) => <StatsStrip stats={data()} />}
        </Show>
      </section>

      <section class="home-columns">
        <LedgerSection
          title="Recent"
          empty="No recent lookups yet."
          values={recents()}
          onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
        />
        <LedgerSection
          title="Saved"
          empty="No saved words yet."
          values={favorites()}
          onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
        />
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
  const hitsError = createMemo(() => resourceErrorMessage(hits.error, `Failed to load “${term()}”.`));

  onMount(() => setFavorites(loadList(FAVORITES_KEY)));

  const primaryWord = createMemo(() => hits()?.[0]?.entry.word ?? term());

  const toggleFavorite = () => {
    const current = loadList(FAVORITES_KEY);
    const next = current.includes(primaryWord())
      ? current.filter((item) => item !== primaryWord())
      : [primaryWord(), ...current.filter((item) => item !== primaryWord())];
    const capped = next.slice(0, 12);
    saveList(FAVORITES_KEY, capped);
    setFavorites(capped);
  };

  return (
    <main class="page entry-page">
      <section class="entry-searchbar">
        <A class="back-link" href="/">
          Index
        </A>
        <SearchCard
          compact
          initialValue={term()}
          onCommit={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
        />
      </section>

      <Show
        when={hits()}
        fallback={
          <section class="state-line">
            <Show when={hitsError()} fallback={<span class="strip-muted">Loading entry…</span>}>
              {(message) => <div class="inline-error">{message()}</div>}
            </Show>
          </section>
        }
      >
        {(data) => (
          <Show when={data().length > 0} fallback={<section class="state-line">No entry found for “{term()}”.</section>}>
            <>
              <header class="entry-header">
                <div class="entry-title-row">
                  <h1>{primaryWord()}</h1>
                  <div class="entry-tools">
                    <button
                      class="icon-button"
                      type="button"
                      aria-label={favorites().includes(primaryWord()) ? "Remove saved word" : "Save word"}
                      title={favorites().includes(primaryWord()) ? "Remove saved word" : "Save word"}
                      onClick={toggleFavorite}
                    >
                      <BookmarkIcon filled={favorites().includes(primaryWord())} />
                    </button>
                  </div>
                </div>
              </header>

              <section class="entry-layout">
                <For each={data()}>{(hit) => <EntryArticle hit={hit} primaryWord={primaryWord()} />}</For>
              </section>
            </>
          </Show>
        )}
      </Show>
    </main>
  );
}

function EntryArticle(props: { hit: ApiLookupHit; primaryWord?: string }) {
  const matchIsAlias = createMemo(() => props.hit.matched !== props.hit.entry.word);
  const renderedSections = createMemo(() => props.hit.entry.renderedSections ?? []);

  onMount(() => {
    const current = loadList(RECENTS_KEY).filter((item) => item !== props.hit.entry.word);
    saveList(RECENTS_KEY, [props.hit.entry.word, ...current].slice(0, 8));
  });

  const copyRaw = async () => {
    if (!props.hit.entry.raw || typeof navigator === "undefined" || !navigator.clipboard) return;
    await navigator.clipboard.writeText(props.hit.entry.raw);
  };

  return (
    <article class="entry-record">
      <div class="article-head">
        <div>
          <Show when={props.hit.entry.word !== props.primaryWord}>
            <h2>{props.hit.entry.word}</h2>
          </Show>
          <Show when={matchIsAlias()}>
            <p class="article-note">
              Matched through <strong>{props.hit.matched}</strong> as an{" "}
              {props.hit.kind === "alternative_form" ? "alternative spelling" : "exact title"}.
            </p>
          </Show>
        </div>
        <div class="article-actions">
          <Show when={props.hit.entry.aliasOnly}>
            <span class="alias-tag">Alias entry</span>
          </Show>
          <button class="icon-button" type="button" aria-label="Copy source" title="Copy source" onClick={copyRaw}>
            <CopyIcon />
          </button>
        </div>
      </div>

      <Show when={props.hit.entry.summary}>
        <p class="summary-line">{props.hit.entry.summary}</p>
      </Show>

      <div class="meta-rail">
        <MetaLine title="Canonical" values={props.hit.entry.canonicalTargets} />
        <MetaLine title="Alternatives" values={props.hit.entry.altForms} />
        <MetaLine title="Incoming" values={props.hit.entry.incomingAliases} />
      </div>

      <Show
        when={renderedSections().length > 0}
        fallback={<div class="state-line narrow">This entry is stored without a rendered English section.</div>}
      >
        <div class="render-stack">
          <For each={renderedSections()}>
            {(block) => (
              <section class="render-section" id={block.id}>
                <Show when={block.title && block.title !== props.primaryWord}>
                  <div class="render-heading">
                    <Dynamic component={headingTag(block.level)}>{block.title}</Dynamic>
                  </div>
                </Show>
                <div class="source-html" innerHTML={block.html} />
              </section>
            )}
          </For>
        </div>
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

  createEffect(() => {
    setQuery(props.initialValue ?? "");
  });

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
    if (!word) return;
    navigate(`/entry/${encodeURIComponent(word)}`);
  };

  return (
    <div classList={{ "search-shell": true, compact: props.compact === true }}>
      <div class="search-row">
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
        <button class="search-action solid icon-button" type="button" aria-label="Search" title="Search" onClick={() => handleCommit(query())}>
          <SearchIcon />
        </button>
        <button class="search-action icon-button" type="button" aria-label="Random entry" title="Random entry" onClick={handleRandom}>
          <ShuffleIcon />
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

function StatsStrip(props: { stats: ApiStats }) {
  return (
    <>
      <StatDatum label="Entries" value={formatNumber(props.stats.entries)} />
      <StatDatum label="Raw" value={formatNumber(props.stats.rawEntries)} />
      <StatDatum label="Redirects" value={formatNumber(props.stats.redirects)} />
      <StatDatum label="Lookups" value={formatNumber(props.stats.lookups)} />
      <StatDatum label="Format" value={`v${props.stats.version}`} />
    </>
  );
}

function StatDatum(props: { label: string; value: string }) {
  return (
    <div class="stat-datum">
      <span>{props.label}</span>
      <strong>{props.value}</strong>
    </div>
  );
}

function headingTag(level: number) {
  if (level <= 2) return "h2";
  if (level === 3) return "h3";
  if (level === 4) return "h4";
  if (level === 5) return "h5";
  return "h6";
}

function SearchIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8">
      <circle cx="8.5" cy="8.5" r="4.75" />
      <path d="M12 12l4.25 4.25" stroke-linecap="round" />
    </svg>
  );
}

function ShuffleIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8">
      <path d="M3 5.5h3.2c1.2 0 2.3.5 3.1 1.3l4.4 5a4 4 0 003 1.4H17" stroke-linecap="round" />
      <path d="M14 4l3 1.5-3 1.5" stroke-linecap="round" stroke-linejoin="round" />
      <path d="M3 14.5h3.2c1.2 0 2.3-.5 3.1-1.3l4.4-5a4 4 0 013-1.4H17" stroke-linecap="round" />
      <path d="M14 13l3 1.5-3 1.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path d="M6 2h9a2 2 0 012 2v10h-2V4H6V2zm-3 4h9a2 2 0 012 2v10H5a2 2 0 01-2-2V6zm2 2v8h7V8H5z" />
    </svg>
  );
}

function BookmarkIcon(props: { filled: boolean }) {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path
        d="M5 2h10v16l-5-3.2L5 18V2z"
        fill={props.filled ? "currentColor" : "none"}
        stroke="currentColor"
        stroke-width="1.6"
      />
    </svg>
  );
}

function LedgerSection(props: {
  title: string;
  values: string[];
  empty: string;
  onSelect: (value: string) => void;
}) {
  return (
    <section class="plain-section">
      <h2>{props.title}</h2>
      <Show when={props.values.length > 0} fallback={<div class="strip-muted">{props.empty}</div>}>
        <div class="plain-list">
          <For each={props.values}>
            {(value) => (
              <button class="list-link" type="button" onClick={() => props.onSelect(value)}>
                {value}
              </button>
            )}
          </For>
        </div>
      </Show>
    </section>
  );
}

function MetaLine(props: { title: string; values: string[] }) {
  return (
    <Show when={props.values.length > 0}>
      <div class="meta-line">
        <span>{props.title}</span>
        <div class="token-row compact">
          <For each={props.values}>{(value) => <span class="token-static">{value}</span>}</For>
        </div>
      </div>
    </Show>
  );
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

function resourceErrorMessage(error: unknown, fallback: string): string | null {
  if (error == null) return null;
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string" && error) return error;
  return fallback;
}

function formatNumber(value: number) {
  return new Intl.NumberFormat().format(value);
}

function readStoredThemeMode(): ThemeMode | null {
  if (typeof localStorage === "undefined") return null;
  const stored = localStorage.getItem(THEME_MODE_KEY);
  if (stored === "auto") return "auto";
  return THEME_KEYS.includes(stored as ThemeKey) ? (stored as ThemeKey) : null;
}

function readStoredColorScheme(): ColorSchemeMode | null {
  if (typeof localStorage === "undefined") return null;
  const stored = localStorage.getItem(COLOR_SCHEME_KEY);
  return stored === "system" || stored === "light" || stored === "dark" ? stored : null;
}

function readStoredWidthMode(): WidthMode | null {
  if (typeof localStorage === "undefined") return null;
  const stored = localStorage.getItem(WIDTH_MODE_KEY);
  return WIDTH_MODES.includes(stored as WidthMode) ? (stored as WidthMode) : null;
}

function deriveThemeFromPath(pathname: string): ThemeKey {
  const termMatch = pathname.match(/^\/entry\/(.+)$/);
  const seed = termMatch ? decodeURIComponent(termMatch[1]) : pathname;
  let hash = 0;
  for (const char of seed) hash = (hash * 33 + char.charCodeAt(0)) >>> 0;
  return THEME_KEYS[hash % THEME_KEYS.length] ?? "linen";
}

function titleCase(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}
