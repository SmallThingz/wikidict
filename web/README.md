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
