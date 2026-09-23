# Binary web reader

Run `pnpm install && pnpm build`, then serve `../build/web` over localhost or HTTPS. `pnpm test` covers binary/XZ decoding and malformed inputs; `pnpm test:browser` exercises the real browser with the Android binary fixture. Set `WIKBLB_FIXTURE` to override its path.

The reader stores compressed files in IndexedDB and builds a title/offset index. XZ blocks are located from stream indexes; only intersecting blocks are decoded on lookup, with one decoded block cached. Publish with 1 MiB blocks. Blocks above 128 MiB are rejected in the browser. No JSON dictionary import, Lua, templates, or source parser is used.

Features: meanings-first folds, per-section expansion, configurable folding defaults, tables and styled semantic spans, five-button navigation, persistent history (100,000 maximum), bookmarks, cards/quiz/scramble, offline system speech when a local browser voice exists, opt-in Wikimedia images/audio, bounded media cache (4 GiB), custom HTTPS catalogues, checksummed downloads, theme settings and import/remove controls.

Browser storage quotas and CORS apply. Downloads currently use the browser Blob API, so very large downloads depend on browser resources. Catalogue SHA-256 is verified incrementally in the worker. Terminal-style dictionary media URLs still require network access; offline speech availability depends on browser/OS voices.

Validation: raw and multiblock XZ produce identical decoded entries for the 30-entry fixture; concatenated streams, cross-block reads, truncation and corruption tests pass. Browser flows pass at 360, 768 and 1440 px, including history/bookmark persistence and the maximum settings values. Media playback and offline voice quality are not covered by that automated browser run. This is not a whole-corpus performance claim.
