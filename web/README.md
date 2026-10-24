# Binary web reader

The reader strictly accepts compiled DPR2 and DPR3 records. DPR2 spans retain empty explanations; DPR3 preserves authored plain-text explanations across titles, body, table captions/cells, preambles and references. Compact labels and link actions stay separate from the keyboard/touch-accessible **Abbreviations** disclosure. No source markup is interpreted.

Run `pnpm install && pnpm build`, then serve `../build/web` over localhost or HTTPS. `pnpm test` covers binary/XZ decoding and malformed inputs; `pnpm test:browser` exercises the real browser with the Android binary fixture. Set `WIKBLB_FIXTURE` to override its path.

The reader stores compressed files in IndexedDB and builds a title/offset index. XZ blocks are located from stream indexes; only intersecting blocks are decoded on lookup, with one decoded block cached. Publish with 1 MiB blocks. Blocks above 128 MiB are rejected in the browser. No JSON dictionary import, Lua, templates, or source parser is used.

Features: meanings-first folds, per-section expansion, configurable folding defaults, tables and styled semantic spans, five-button navigation, persistent history (100,000 maximum), bookmarks, cards/quiz/scramble, offline system speech when a local browser voice exists, opt-in Wikimedia images/audio, bounded media cache (4 GiB), custom HTTPS catalogues, checksummed downloads, theme settings and import/remove controls.

Browser storage quotas and CORS apply. Downloads currently use the browser Blob API, so very large downloads depend on browser resources. Catalogue SHA-256 is verified incrementally in the worker. Terminal-style dictionary media URLs still require network access; offline speech availability depends on browser/OS voices.

Validation: raw and multiblock XZ produce identical decoded entries for the 30-entry fixture; concatenated streams, cross-block reads, truncation and corruption tests pass. Browser flows pass at 360, 768 and 1440 px, including history/bookmark persistence and the maximum settings values. Media playback and offline voice quality are not covered by that automated browser run. This is not a whole-corpus performance claim.

The ordinary test commands read the shared genuine `../tests/fixtures/abbreviation-interop` directory produced by the core's normal `zig build test-bundle` probe: the English blob, `annotated.export.json` and `legacy.export.json`. Set `WIKBLB_ABBREVIATION_ROOT` only to use a different fresh fixture directory. Node checks compare decoded spans with normal CLI JSON; the browser checks visible compact labels and all seven explanations, with reader/disclosure screenshots at 360 and 1440 pixels. Synthetic protocol controls remain separate from native interoperability.

The native fifth span string is `classes`; the web decoder and preview filtering use that canonical field. Rich explained/linked heading companions render once in their section summary, while mismatched/plain headings retain their ordinary body rendering. Explanations on visible trails remain outside link actions.

### Color sample regression

Compiled `color_swatch` table features display a decorative sample and one readable
hex label. Unknown or malformed features retain their original table and links;
no CSS or source markup is parsed by the reader.

Run the focused browser check with a fresh, absolute report path:

```sh
mkdir -p ../artifacts
WIKIDICT_SWATCH_REPORT="$PWD/../artifacts/color-swatch-run01" pnpm test:swatch
```

Choose a new report directory name for each run; the test refuses an existing
path. It uses the same Playwright/Brave and esbuild dependencies as `test:browser`,
checks strict feature fallback, keyboard traversal, accessible labels and layout
at 360 and 768 pixels, and saves screenshots. The input is a synthetic compiled
entry; this does not qualify corpus imports, public downloads or the full browser
application. Set `CHROMIUM` only when intentionally qualifying another browser.

### Compiled Poem regression

Canonical compiled Poem metadata preserves line indentation, blank stanzas and
terminal lines without interpreting wikitext. Ordinary inline whitespace and
preformatted text keep their separate rendering behavior.

```sh
mkdir -p ../artifacts
WIKIDICT_POEM_REPORT="$PWD/../artifacts/poem-run01" pnpm test:poem
```

Use a new absolute report directory each time. This focused Playwright check uses
synthetic typed spans, exercises styled links, keyboard navigation, accessible
text, RTL indentation and 360/768-pixel layouts, and retains screenshots. It does
not rerun the full browser suite or qualify public downloads/corpus content.

### Action error recovery regression

```sh
mkdir -p ../artifacts
WIKIDICT_ERROR_REPORT="$PWD/../artifacts/action-errors-run01" pnpm test:errors
```

Use a fresh absolute report directory. This runs the normal production build and
focused real-browser checks for invalid catalogue input, preserved input/recovery,
direct file-picker activation, isolated fixture import/search/read, keyboard access
and controlled asynchronous worker failures. It does not contact a public catalogue
or rerun the full browser suite. Optional `WIKIDICT_ERROR_BASELINE` names an immutable
absolute pre-fix `app.js` to reproduce the former uncaught URL error in a separate
isolated context; it is not needed for the normal regression check.

Error text contrast (fresh isolated report directory, actual light/dark UI):

```sh
WIKIDICT_CONTRAST_REPORT="$PWD/../artifacts/error-contrast-run01" pnpm test:error-contrast
```

Read-only error ownership (fresh isolated report directory; controlled delayed worker responses):

```sh
WIKIDICT_STALE_REPORT="$PWD/../artifacts/stale-errors-run01" pnpm test:stale-errors
```

Reader-link intent ordering (fresh isolated report directory, controlled response order):

```sh
WIKIDICT_LINK_ORDER_REPORT="$PWD/../artifacts/link-order-run01" pnpm test:link-order
```

Search placeholder contrast (fresh isolated report directory, actual light/dark views):

```sh
WIKIDICT_PLACEHOLDER_REPORT="$PWD/../artifacts/placeholder-contrast-run01" pnpm test:placeholder-contrast
```

Focused typed self-heading regression (client-only fixtures):

```sh
WIKIDICT_SELF_HEADING_REPORT=/absolute/fresh/report npm run test:self-heading
```

The report directory must not exist. `CHROMIUM` may select the installed Chromium-compatible executable; qualification pins its exact executable separately. This test covers matching self-only heading consumption, styles, nonactionable self text, adjacent-link activation, folding, keyboard focus and 360/768px layouts; it does not import a corpus publication.

### Learn accessibility and Unicode regression

```sh
WIKIDICT_LEARN_REPORT=/absolute/fresh/report npm run test:learn
```

This focused browser check uses controlled semantic entries at 360/768px. It checks
flashcard accessible names and expanded state, keyboard reveal/hide without lost
focus, combining marks and joined emoji in Scramble, and saves rendered evidence.
Scramble uses `Intl.Segmenter`; when unavailable, it offers Quiz or Cards instead
of splitting the word incorrectly. The test does not qualify corpus imports or
screen-reader software. Use a fresh report directory and the same isolated browser
setup as the other focused checks.
