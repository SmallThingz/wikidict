import { A, useNavigate, useParams } from "@solidjs/router";
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
import { get, set } from "idb-keyval";
import { createVirtualizer } from "@tanstack/solid-virtual";

import {
  type ApiSystemTheme,
  type ApiLookupHit,
  type ApiStats,
  type ApiSuggestion,
  fetchLookup,
  fetchRandomWord,
  fetchStats,
  fetchSuggestions,
  fetchSystemTheme,
  fetchWordOfDay,
} from "./api";

const RECENTS_KEY = "dict-recents";
const FAVORITES_KEY = "dict-favorites";
const THEME_MODE_KEY = "dict-theme-mode";
const WIDTH_MODE_KEY = "dict-width-mode";
const HIST_LIMIT_KEY = "dict-hist-limit";
const VIEW_MODE_KEY = "dict-view-mode";
const SHOW_COPY_BTN_KEY = "dict-show-copy";

const THEME_KEYS = ["system", "linen", "graphite"] as const;
const WIDTH_MODES = ["narrow", "standard", "wide"] as const;

type ThemeKey = (typeof THEME_KEYS)[number];
type ThemeMode = ThemeKey;
type WidthMode = (typeof WIDTH_MODES)[number];
type ViewMode = "infinite" | "paginated";
type HistLimit = "1000" | "5000" | "10000" | "infinite";
type ShowCopyBtnMode = "false" | "true";
type ThemeVars = Record<string, string>;

export const [showCopyBtn, setShowCopyBtn] = createSignal<ShowCopyBtnMode>("false");

const FALLBACK_SYSTEM_THEME: Record<"light" | "dark", ApiSystemTheme> = {
  light: {
    source: "fallback",
    name: "System",
    scheme: "light",
    colors: {
      bg: "#f5f5f2",
      page: "#fffdf8",
      panel: "#fffbf5",
      line: "#d4d2cb",
      lineStrong: "#b8b4aa",
      ink: "#1e222a",
      muted: "#6d706f",
      accent: "#3d7291",
      accentStrong: "#294e63",
      accentSoft: "rgba(61, 114, 145, 0.12)",
      glassBg: "rgba(255, 251, 245, 0.84)",
      glassBorder: "rgba(61, 114, 145, 0.09)",
    },
  },
  dark: {
    source: "fallback",
    name: "System",
    scheme: "dark",
    colors: {
      bg: "#0f1115",
      page: "#15191f",
      panel: "#1a1f26",
      line: "#3a434f",
      lineStrong: "#4b5765",
      ink: "#f2f4f8",
      muted: "#a4adb7",
      accent: "#7fbad6",
      accentStrong: "#abd6e8",
      accentSoft: "rgba(127, 186, 214, 0.18)",
      glassBg: "rgba(26, 31, 38, 0.82)",
      glassBorder: "rgba(127, 186, 214, 0.12)",
    },
  },
};

function fallbackSystemTheme(scheme: "light" | "dark"): ApiSystemTheme {
  return FALLBACK_SYSTEM_THEME[scheme];
}

function themeVarsFor(colors: ApiSystemTheme["colors"]): ThemeVars {
  return {
    "--bg": colors.bg,
    "--page": colors.page,
    "--panel": colors.panel,
    "--line": colors.line,
    "--line-strong": colors.lineStrong,
    "--ink": colors.ink,
    "--muted": colors.muted,
    "--accent": colors.accent,
    "--accent-strong": colors.accentStrong,
    "--accent-soft": colors.accentSoft,
    "--glass-bg": colors.glassBg,
    "--glass-border": colors.glassBorder,
  };
}

export default function App(props: ParentProps) {
  const navigate = useNavigate();
  const [themeMode, setThemeMode] = createSignal<ThemeMode>("system");
  const [widthMode, setWidthMode] = createSignal<WidthMode>("standard");
  const [histLimit, setHistLimit] = createSignal<HistLimit>("10000");
  const [viewMode, setViewMode] = createSignal<ViewMode>("infinite");
  const [prefersDark, setPrefersDark] = createSignal(false);
  const [isSettingsOpen, setIsSettingsOpen] = createSignal(false);
  const [isMobileSearchOpen, setIsMobileSearchOpen] = createSignal(false);
  const [systemTheme] = createResource(fetchSystemTheme);

  onMount(() => {
    const storedTheme = readStored(THEME_MODE_KEY, ["system", "linen", "graphite"]);
    if (storedTheme) setThemeMode(storedTheme as ThemeMode);

    const storedWidth = readStored(WIDTH_MODE_KEY, ["narrow", "standard", "wide"]);
    if (storedWidth) setWidthMode(storedWidth as WidthMode);

    const storedLimit = readStored(HIST_LIMIT_KEY, ["1000", "5000", "10000", "infinite"]);
    if (storedLimit) setHistLimit(storedLimit as HistLimit);

    const storedView = readStored(VIEW_MODE_KEY, ["infinite", "paginated"]);
    if (storedView) setViewMode(storedView as ViewMode);

    const storedCopyBtn = readStored(SHOW_COPY_BTN_KEY, ["false", "true"]);
    if (storedCopyBtn) setShowCopyBtn(storedCopyBtn as ShowCopyBtnMode);

    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const updateScheme = () => setPrefersDark(media.matches);
    updateScheme();
    media.addEventListener("change", updateScheme);
    onCleanup(() => media.removeEventListener("change", updateScheme));
  });

  const handleGlobalRandom = async () => {
    const word = await fetchRandomWord();
    if (word) navigate(`/entry/${encodeURIComponent(word)}`);
  };

  const fallbackScheme = createMemo<"light" | "dark">(() => (prefersDark() ? "dark" : "light"));
  const activeSystemTheme = createMemo<ApiSystemTheme>(() => systemTheme() ?? fallbackSystemTheme(fallbackScheme()));
  const activeColorScheme = createMemo<"light" | "dark">(() => {
    if (themeMode() === "system") return activeSystemTheme().scheme;
    return fallbackScheme();
  });
  const systemThemeVars = createMemo<ThemeVars | undefined>(() =>
    themeMode() === "system" ? themeVarsFor(activeSystemTheme().colors) : undefined,
  );

  return (
    <div class="app-shell" data-theme={themeMode()} data-scheme={activeColorScheme()} data-width={widthMode()} style={systemThemeVars()}>
      <header class="site-header">
        <div classList={{ "header-container": true, "mobile-search-active": isMobileSearchOpen() }}>
          <A class="wordmark" href="/" title="Home" aria-label="Home">
            <span>dict</span>
            <small>en.wiktionary</small>
          </A>

          <div class="header-search-wrapper">
            <SearchCard compact onCommit={(value) => { setIsMobileSearchOpen(false); navigate(`/entry/${encodeURIComponent(value)}`); }} focusTrigger={isMobileSearchOpen} />
          </div>

          <div class="header-controls">
            <button class="icon-button mobile-control-btn" type="button" aria-label="Random entry" title="Random entry" onClick={handleGlobalRandom}>
              <ShuffleIcon />
            </button>
            <button class="icon-button mobile-control-btn themed-search-icon" type="button" onClick={() => setIsMobileSearchOpen(true)} aria-label="Search">
              <SearchIcon />
            </button>
            <button class="icon-button close-search-inline" type="button" onClick={() => setIsMobileSearchOpen(false)} aria-label="Close search">
              <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
            <button class="icon-button settings-btn" type="button" onClick={() => setIsSettingsOpen(true)} title="Settings" aria-label="Settings">
              <SettingsIcon />
            </button>
          </div>
        </div>
      </header>

      <Show when={isSettingsOpen()}>
        <div class="settings-overlay-backdrop" onClick={() => setIsSettingsOpen(false)}></div>
        <dialog class="settings-dialog" data-theme={themeMode()} data-scheme={activeColorScheme()} style={systemThemeVars()} open>
          <div class="settings-dialog-header">
            <h2>Settings</h2>
            <button class="icon-button" type="button" onClick={() => setIsSettingsOpen(false)}>×</button>
          </div>
          <div class="settings-dialog-content">
            <div class="setting-group">
              <span class="setting-label">Theme Palette</span>
              <div class="chip-row">
                <For each={[
                  { id: "system", label: "System" },
                  { id: "linen", label: "Linen" },
                  { id: "graphite", label: "Graphite" },
                ]}>
                  {(opt) => (
                    <button classList={{ "chip-button": true, active: themeMode() === opt.id }} type="button" onClick={() => {
                      setThemeMode(opt.id as ThemeMode);
                      localStorage.setItem(THEME_MODE_KEY, opt.id);
                    }}>{opt.label}</button>
                  )}
                </For>
              </div>
              <Show when={themeMode() === "system"}>
                <div class="system-theme-note">
                  <strong>{activeSystemTheme().name}</strong>
                  <span>
                    {systemTheme.loading
                      ? "Detecting desktop colors…"
                      : systemTheme.error
                        ? "Backend theme detection failed; using a normalized fallback palette."
                        : `Backend palette source: ${activeSystemTheme().source}.`}
                  </span>
                </div>
              </Show>
            </div>

            <div class="setting-group">
              <span class="setting-label">Layout Width</span>
              <div class="segmented-control">
                <For each={[
                  { id: "narrow", label: "Narrow" },
                  { id: "standard", label: "Standard" },
                  { id: "wide", label: "Wide" },
                ]}>
                  {(opt) => (
                    <button classList={{ "segment-button": true, active: widthMode() === opt.id }} type="button" onClick={() => {
                      setWidthMode(opt.id as WidthMode);
                      localStorage.setItem(WIDTH_MODE_KEY, opt.id);
                    }}>{opt.label}</button>
                  )}
                </For>
              </div>
            </div>

            <div class="setting-group">
              <span class="setting-label">History Retention</span>
              <div class="segmented-control">
                <For each={[
                  { id: "1000", label: "1K" },
                  { id: "5000", label: "5K" },
                  { id: "10000", label: "10K" },
                  { id: "infinite", label: "Infinite" },
                ]}>
                  {(opt) => (
                    <button classList={{ "segment-button": true, active: histLimit() === opt.id }} type="button" onClick={() => {
                      setHistLimit(opt.id as HistLimit);
                      localStorage.setItem(HIST_LIMIT_KEY, opt.id);
                    }}>{opt.label}</button>
                  )}
                </For>
              </div>
            </div>

            <div class="setting-group">
              <span class="setting-label">List View Mode (History)</span>
              <div class="segmented-control">
                <For each={[
                  { id: "infinite", label: "Infinite Scroll" },
                  { id: "paginated", label: "Paginated (50)" },
                ]}>
                  {(opt) => (
                    <button classList={{ "segment-button": true, active: viewMode() === opt.id }} type="button" onClick={() => {
                      setViewMode(opt.id as ViewMode);
                      localStorage.setItem(VIEW_MODE_KEY, opt.id);
                    }}>{opt.label}</button>
                  )}
                </For>
              </div>
            </div>

            <div class="setting-group">
              <span class="setting-label">Show Source Copy Button</span>
              <div class="segmented-control">
                <For each={[
                  { id: "false", label: "Hidden" },
                  { id: "true", label: "Visible" },
                ]}>
                  {(opt) => (
                    <button classList={{ "segment-button": true, active: showCopyBtn() === opt.id }} type="button" onClick={() => {
                      setShowCopyBtn(opt.id as ShowCopyBtnMode);
                      localStorage.setItem(SHOW_COPY_BTN_KEY, opt.id);
                    }}>{opt.label}</button>
                  )}
                </For>
              </div>
            </div>
          </div>
        </dialog>
      </Show>

      <div class="page-frame">{props.children}</div>
    </div>
  );
}

export { EntryPage, HomePage, HistoryPage, BookmarksPage };

function HomePage() {
  const navigate = useNavigate();
  const [stats] = createResource(fetchStats);
  const [wordOfDay] = createResource(async () => fetchWordOfDay());
  const [recents, setRecents] = createSignal<string[]>([]);
  const [favorites, setFavorites] = createSignal<string[]>([]);
  const statsError = createMemo(() => resourceErrorMessage(stats.error, "Failed to load dictionary stats."));
  const wordOfDayError = createMemo(() => resourceErrorMessage(wordOfDay.error, "Failed to load the word of the day."));

  onMount(() => {
    loadListDb(RECENTS_KEY).then(setRecents);
    loadListDb(FAVORITES_KEY).then(setFavorites);
  });

  return (
    <main class="page home-page">
      <section class="masthead">
        <div class="eyebrow">English Wiktionary</div>
        <h1>Dictionary</h1>
      </section>

      <section class="word-of-day-strip" aria-labelledby="word-of-day-heading">
        <div class="word-of-day-copy">
          <div class="eyebrow" id="word-of-day-heading">Word of the Day</div>
          <Show
            when={wordOfDay()}
            fallback={<div class="strip-muted">{wordOfDayError() ?? "Selecting today’s word…"}</div>}
          >
            {(daily) => (
              <>
                <button
                  class="word-of-day-link"
                  type="button"
                  onClick={() => navigate(`/entry/${encodeURIComponent(daily().word)}`)}
                >
                  {daily().word}
                </button>
                <div class="word-of-day-meta">Deterministic daily pick for {daily().day}</div>
              </>
            )}
          </Show>
        </div>

        <div class="stats-strip" aria-label="Dictionary statistics">
          <Show
            when={stats()}
            fallback={<div class="strip-muted stats-placeholder">{statsError() ?? "Loading stats…"}</div>}
          >
            {(loadedStats) => <StatsStrip stats={loadedStats()} />}
          </Show>
        </div>
      </section>

      <section class="home-columns">
        <LedgerSection
          title="Recent Lookup History"
          empty="No recent lookups yet."
          values={recents().slice(0, 15)}
          onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
          footer={<A href="/history" class="list-link view-all-link">View all history →</A>}
        />
        <LedgerSection
          title="Saved Words"
          empty="No saved words yet."
          values={favorites().slice(0, 15)}
          onSelect={(value) => navigate(`/entry/${encodeURIComponent(value)}`)}
          footer={<A href="/bookmarks" class="list-link view-all-link">View all bookmarks →</A>}
        />
      </section>
    </main>
  );
}

function HistoryPage() {
  const navigate = useNavigate();
  const [history, setHistory] = createSignal<string[]>([]);
  const [page, setPage] = createSignal(0);

  onMount(() => {
    loadListDb(RECENTS_KEY).then(setHistory);
  });

  const clearAll = async () => {
    if (!confirm("Are you sure you want to clear your entire history?")) return;
    await saveListDb(RECENTS_KEY, []);
    setHistory([]);
  };

  const removeEntry = async (word: string) => {
    const next = history().filter(item => item !== word);
    await saveListDb(RECENTS_KEY, next);
    setHistory(next);
  };

  const viewMode = readStored(VIEW_MODE_KEY, ["infinite", "paginated"]) ?? "infinite";
  const itemsPerPage = 50;

  const currentList = createMemo(() => {
    if (viewMode === "infinite") return history();
    const start = page() * itemsPerPage;
    return history().slice(start, start + itemsPerPage);
  });

  return (
    <main class="page list-page">
      <header class="page-header list-header">
        <h1>Your History</h1>
        <Show when={history().length > 0}>
          <button class="list-link view-all-link clear-button" type="button" onClick={clearAll}>Clear All</button>
        </Show>
      </header>
      <section class="list-section">
        <Show when={history().length > 0} fallback={<div class="strip-muted">No history stored.</div>}>
          <Show when={viewMode === "paginated"}>
            <div class="detailed-list">
              <For each={currentList()}>
                {(item) => (
                  <div class="list-item-row">
                    <button class="list-link inline-link" type="button" onClick={() => navigate(`/entry/${encodeURIComponent(item)}`)}>{item}</button>
                    <button class="icon-button delete-icon-button" type="button" aria-label="Delete" title="Delete entry" onClick={() => removeEntry(item)}>
                      <TrashIcon />
                    </button>
                  </div>
                )}
              </For>
            </div>
            <div class="pagination-bar">
              <button class="icon-button" disabled={page() === 0} onClick={() => setPage(p => p - 1)}>Prev</button>
              <span class="page-indicator">Page {page() + 1} of {Math.ceil(history().length / itemsPerPage)}</span>
              <button class="icon-button" disabled={(page() + 1) * itemsPerPage >= history().length} onClick={() => setPage(p => p + 1)}>Next</button>
            </div>
          </Show>

          <Show when={viewMode === "infinite"}>
            <VirtualListView items={history()} onRemove={removeEntry} onNavigate={(w) => navigate(`/entry/${encodeURIComponent(w)}`)} />
          </Show>
        </Show>
      </section>
    </main>
  );
}

function BookmarksPage() {
  const navigate = useNavigate();
  const [favorites, setFavorites] = createSignal<string[]>([]);
  const [page, setPage] = createSignal(0);

  onMount(() => {
    loadListDb(FAVORITES_KEY).then(setFavorites);
  });

  const clearAll = async () => {
    if (!confirm("Are you sure you want to completely clear your bookmarks?")) return;
    await saveListDb(FAVORITES_KEY, []);
    setFavorites([]);
  };

  const removeEntry = async (word: string) => {
    const next = favorites().filter(item => item !== word);
    await saveListDb(FAVORITES_KEY, next);
    setFavorites(next);
  };

  const viewMode = readStored(VIEW_MODE_KEY, ["infinite", "paginated"]) ?? "infinite";
  const itemsPerPage = 50;

  const currentList = createMemo(() => {
    if (viewMode === "infinite") return favorites();
    const start = page() * itemsPerPage;
    return favorites().slice(start, start + itemsPerPage);
  });

  return (
    <main class="page list-page">
      <header class="page-header list-header">
        <h1>Bookmarks</h1>
        <Show when={favorites().length > 0}>
          <button class="list-link view-all-link clear-button" type="button" onClick={clearAll}>Clear All</button>
        </Show>
      </header>
      <section class="list-section">
        <Show when={favorites().length > 0} fallback={<div class="strip-muted">No bookmarks saved yet.</div>}>
          <Show when={viewMode === "paginated"}>
            <div class="detailed-list">
              <For each={currentList()}>
                {(item) => (
                  <div class="list-item-row">
                    <button class="list-link inline-link" type="button" onClick={() => navigate(`/entry/${encodeURIComponent(item)}`)}>{item}</button>
                    <button class="icon-button delete-icon-button" type="button" aria-label="Delete" title="Remove bookmark" onClick={() => removeEntry(item)}>
                      <TrashIcon />
                    </button>
                  </div>
                )}
              </For>
            </div>
            <div class="pagination-bar">
              <button class="icon-button" disabled={page() === 0} onClick={() => setPage(p => p - 1)}>Prev</button>
              <span class="page-indicator">Page {page() + 1} of {Math.ceil(favorites().length / itemsPerPage)}</span>
              <button class="icon-button" disabled={(page() + 1) * itemsPerPage >= favorites().length} onClick={() => setPage(p => p + 1)}>Next</button>
            </div>
          </Show>

          <Show when={viewMode === "infinite"}>
            <VirtualListView items={favorites()} onRemove={removeEntry} onNavigate={(w) => navigate(`/entry/${encodeURIComponent(w)}`)} />
          </Show>
        </Show>
      </section>
    </main>
  );
}

function VirtualListView(props: { items: string[]; onRemove: (word: string) => void; onNavigate: (word: string) => void }) {
  let listRef!: HTMLDivElement;

  const virtualizer = createVirtualizer({
    get count() { return props.items.length; },
    getScrollElement: () => document.documentElement,
    estimateSize: () => 40,
    overscan: 10,
  });

  return (
    <div
      ref={listRef}
      style={{
        height: `${virtualizer.getTotalSize()}px`,
        width: "100%",
        position: "relative",
      }}
    >
      <For each={virtualizer.getVirtualItems()}>
        {(virtualItem) => {
          const item = props.items[virtualItem.index];
          return (
            <div
              class="list-item-row virtual-row"
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${virtualItem.start}px)`,
              }}
            >
              <button class="list-link inline-link" type="button" onClick={() => props.onNavigate(item)}>{item}</button>
              <button class="icon-button delete-icon-button" type="button" onClick={() => props.onRemove(item)}>
                <TrashIcon />
              </button>
            </div>
          );
        }}
      </For>
    </div>
  );
}

function EntryPage() {
  const params = useParams();
  const term = createMemo(() => decodeURIComponent(params.term ?? ""));
  const [hits] = createResource(term, fetchLookup);
  const [favorites, setFavorites] = createSignal<string[]>([]);
  const hitsError = createMemo(() => resourceErrorMessage(hits.error, `Failed to load “${term()}”.`));

  onMount(() => {
    loadListDb(FAVORITES_KEY).then(setFavorites);
  });

  const primaryWord = createMemo(() => hits()?.[0]?.entry.word ?? term());

  const getLimitInt = () => {
    const val = readStored(HIST_LIMIT_KEY, ["1000", "5000", "10000", "infinite"]) ?? "10000";
    return val === "infinite" ? Infinity : parseInt(val);
  };

  const toggleFavorite = async () => {
    const current = await loadListDb(FAVORITES_KEY);
    const next = current.includes(primaryWord())
      ? current.filter((item) => item !== primaryWord())
      : [primaryWord(), ...current.filter((item) => item !== primaryWord())];
    const capped = next.slice(0, getLimitInt());
    await saveListDb(FAVORITES_KEY, capped);
    setFavorites(capped);
  };

  return (
    <main class="page entry-page">
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
                  <div class="title-with-audio">
                    <h1>{primaryWord()}</h1>
                    <PronounceButton word={primaryWord()} />
                  </div>
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
  const aliasHintTarget = createMemo(() =>
    props.hit.entry.aliasOnly && props.hit.entry.aliasHintLabel && props.hit.entry.canonicalTargets.length === 1
      ? props.hit.entry.canonicalTargets[0]
      : "",
  );
  const showAliasHint = createMemo(() => aliasHintTarget().length > 0);
  const canonicalMetaTargets = createMemo(() => (showAliasHint() ? [] : props.hit.entry.canonicalTargets));

  onMount(() => {
    loadListDb(RECENTS_KEY).then((current) => {
      const val = readStored(HIST_LIMIT_KEY, ["1000", "5000", "10000", "infinite"]) ?? "10000";
      const limit = val === "infinite" ? Infinity : parseInt(val);
      const next = current.filter((item) => item !== props.hit.entry.word);
      const capped = limit === Infinity ? [props.hit.entry.word, ...next] : [props.hit.entry.word, ...next].slice(0, limit);
      saveListDb(RECENTS_KEY, capped);
    });
  });

  const copyRaw = async () => {
    if (!props.hit.entry.raw || typeof navigator === "undefined" || !navigator.clipboard) return;
    await navigator.clipboard.writeText(props.hit.entry.raw);
  };

  const showWordTitle = createMemo(() => props.hit.entry.word !== props.primaryWord);
  const showHeadArea = createMemo(() => showWordTitle() || matchIsAlias() || props.hit.entry.aliasOnly || (props.hit.entry.raw && showCopyBtn() === "true"));

  return (
    <article class="entry-record">
      <Show when={showHeadArea()}>
        <div class="article-head">
          <div>
            <Show when={showWordTitle()}>
              <div class="title-with-audio title-with-audio-secondary">
                <h2>{props.hit.entry.word}</h2>
                <PronounceButton word={props.hit.entry.word} />
              </div>
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
            <Show when={props.hit.entry.raw && showCopyBtn() === "true"}>
              <button class="icon-button" type="button" aria-label="Copy source" title="Copy source" onClick={copyRaw}>
                <CopyIcon />
              </button>
            </Show>
          </div>
        </div>
      </Show>

      <Show when={showAliasHint()}>
        <p class="article-note">
          {props.hit.entry.aliasHintLabel}{" "}
          <A href={`/entry/${encodeURIComponent(aliasHintTarget())}`}>{aliasHintTarget()}</A>.
        </p>
      </Show>

      <Show when={canonicalMetaTargets().length > 0 || props.hit.entry.altForms.length > 0 || props.hit.entry.incomingAliases.length > 0}>
        <div class="meta-rail">
          <MetaLine title="Canonical" values={canonicalMetaTargets()} />
          <MetaLine title="Alternatives" values={props.hit.entry.altForms} />
          <MetaLine title="Incoming" values={props.hit.entry.incomingAliases} />
        </div>
      </Show>

      <Show
        when={renderedSections().length > 0}
        fallback={
          <Show when={props.hit.entry.raw && !props.hit.entry.aliasOnly}>
            <div class="state-line narrow">This entry is stored without a rendered English section.</div>
          </Show>
        }
      >
        <div class="render-stack">
          <For each={renderedSections()}>
            {(block) => (
              <section class="render-section" id={block.id} data-family={getHeadingFamily(block.title)}>
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
  autoFocus?: boolean;
  focusTrigger?: () => boolean;
}) {
  const navigate = useNavigate();
  const [query, setQuery] = createSignal(props.initialValue ?? "");
  const [open, setOpen] = createSignal(false);
  const [activeIndex, setActiveIndex] = createSignal(0);
  let inputRef: HTMLInputElement | undefined;

  createEffect(() => {
    setQuery(props.initialValue ?? "");
  });

  createEffect(() => {
    if (props.focusTrigger?.()) {
      // wait one frame for the CSS width transition to begin
      requestAnimationFrame(() => inputRef?.focus());
    }
  });

  onMount(() => {
    if (props.autoFocus && inputRef) {
      inputRef.focus();
    }
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
    (document.activeElement as HTMLElement)?.blur();
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
          ref={inputRef}
          class="search-input"
          value={query()}
          placeholder="Search Wiktionary"
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
                    {suggestion.kind === "alternative_form" ? "alternate" : "title"}
                  </span>
                </div>
                <div class="suggestion-summary">
                  <strong>{suggestion.word}</strong>
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
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="11" cy="11" r="8" />
      <line x1="21" y1="21" x2="16.65" y2="16.65" />
    </svg>
  );
}

function SpeakerIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M11 5 6.8 8.5H3.8A1.8 1.8 0 0 0 2 10.3v3.4a1.8 1.8 0 0 0 1.8 1.8h3L11 19z" />
      <path d="M15.5 8.5a5.2 5.2 0 0 1 0 7" />
      <path d="M18.3 6a8.5 8.5 0 0 1 0 12" />
    </svg>
  );
}

function ShuffleIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="16 3 21 3 21 8" />
      <line x1="4" y1="20" x2="21" y2="3" />
      <polyline points="21 16 21 21 16 21" />
      <line x1="15" y1="15" x2="21" y2="21" />
      <line x1="4" y1="4" x2="9" y2="9" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function BookmarkIcon(props: { filled: boolean }) {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill={props.filled ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="3 6 5 6 21 6"></polyline>
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

function PronounceButton(props: { word: string }) {
  const [speaking, setSpeaking] = createSignal(false);
  const supported = createMemo(() =>
    typeof window !== "undefined" &&
    "speechSynthesis" in window &&
    "SpeechSynthesisUtterance" in window,
  );

  let utterance: SpeechSynthesisUtterance | undefined;

  const stop = () => {
    if (!supported()) return;
    window.speechSynthesis.cancel();
    utterance = undefined;
    setSpeaking(false);
  };

  onCleanup(stop);

  const handleClick = () => {
    if (!supported() || !props.word.trim()) return;
    if (speaking()) {
      stop();
      return;
    }

    const synth = window.speechSynthesis;
    synth.cancel();

    utterance = new SpeechSynthesisUtterance(props.word);
    utterance.lang = "en";
    utterance.rate = 0.9;
    utterance.pitch = 1;

    const voices = synth.getVoices();
    const preferredVoice =
      voices.find((voice) => /^en-(AU|GB|US)\b/i.test(voice.lang)) ??
      voices.find((voice) => voice.lang.toLowerCase().startsWith("en")) ??
      null;
    if (preferredVoice) utterance.voice = preferredVoice;

    utterance.onend = () => {
      utterance = undefined;
      setSpeaking(false);
    };
    utterance.onerror = () => {
      utterance = undefined;
      setSpeaking(false);
    };

    setSpeaking(true);
    synth.speak(utterance);
  };

  return (
    <button
      classList={{ "icon-button": true, "pronounce-button": true, "is-active": speaking() }}
      type="button"
      onClick={handleClick}
      disabled={!supported()}
      aria-label={speaking() ? `Stop pronunciation for ${props.word}` : `Pronounce ${props.word}`}
      title={supported() ? (speaking() ? "Stop pronunciation" : "Pronounce") : "Browser pronunciation unavailable"}
    >
      <SpeakerIcon />
    </button>
  );
}

function LedgerSection(props: {
  title: string;
  values: string[];
  empty: string;
  onSelect: (value: string) => void;
  footer?: import("solid-js").JSX.Element;
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
        <Show when={props.footer}><div class="ledger-footer">{props.footer}</div></Show>
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

async function loadListDb(key: string): Promise<string[]> {
  try {
    const data = await get(key);
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

async function saveListDb(key: string, values: string[]) {
  try {
    await set(key, values);
  } catch { }
}

function readStored(key: string, expectedKeys: string[]): string | null {
  if (typeof localStorage === "undefined") return null;
  const stored = localStorage.getItem(key);
  return stored && expectedKeys.includes(stored) ? stored : null;
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

function titleCase(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function getHeadingFamily(title: string): string {
  const t = title.toLowerCase();
  switch (t) {
    case "noun":
    case "verb":
    case "adjective":
    case "adverb":
    case "pronoun":
    case "preposition":
    case "conjunction":
    case "interjection":
    case "proper noun":
    case "article":
    case "prepositional phrase":
    case "particle":
    case "determiner":
    case "numeral":
    case "participle":
      return "part-of-speech";
    case "etymology":
      return "etymology";
    case "pronunciation":
      return "pronunciation";
    case "translations":
      return "translations";
    case "derived terms":
    case "related terms":
    case "synonyms":
    case "antonyms":
    case "hypernyms":
    case "hyponyms":
    case "coordinate terms":
      return "relations";
    case "alternative forms":
      return "alternative-forms";
    case "anagrams":
    case "see also":
      return "navigation";
    case "references":
    case "further reading":
    case "notes":
      return "citations";
    case "english":
      return "language-root";
    default:
      return "unknown";
  }
}
