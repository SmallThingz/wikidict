# Dictionary frontends

The native frontend consumes `WIKBLB03` through the portable encoder/decoder modules. The older monolithic dictionary commands remain separate. No VM or source codec is duplicated here.

```sh
zig build
zig-out/bin/dict lookup cat --root data/wiktionary-blobs
zig-out/bin/dict search cat --root data/wiktionary-blobs --limit 20 --offset 0
zig-out/bin/dict lookup cat --root data/wiktionary-blobs --format json --with-source
zig-out/bin/dict lookup Proto-Germanic/frijaz --kind reconstruction --root data/wiktionary-blobs --format source
zig-out/bin/dict languages --root data/wiktionary-blobs --format json
zig-out/bin/dict stats --root data/wiktionary-blobs
```

`zig build dict -- ...` runs the same executable. The documented `query-blobs ROOT KIND [LANGUAGE] TITLE` positional syntax remains accepted; its obsolete diagnostic renderer has been removed.

## Runtime model and machine interface

`store.zig` owns one read-only mapping and its validated runtime index. `model.zig` constructs an arena-owned view of semantic sections, blocks, inline spans and feature records. Most text borrows the mapping. Destroy presentation models before closing their store. Nothing in this model is persisted into blobs.

`dict.results.v1` JSON includes operation, query, kind, language, record_count, total_matches, offset, has_more, matches and entries. Search uses **case-sensitive UTF-8 byte prefixes**, returns title-only matches and supports bounded pagination. Lookup returns the complete semantic entry. `dict.languages.v1` returns sorted language headings. Results are written only to stdout; diagnostics use stderr. Exit codes: 0 success, 1 no matching titles, 2 usage, data, allocation or I/O error. An offset beyond the final search page returns an empty page with the original total.

Entry sections preserve heading levels; blocks preserve kind and depth; spans preserve link targets, trails, emphasis and unresolved templates. Thesaurus and Rhymes expose feature language and qualifier data. This is not a Scribunto engine: unexpanded templates remain explicit rather than being silently discarded or invented.

`--with-source` adds exact reconstructed source. Non-UTF-8 source is carried as `source_base64` instead of invalid JSON text. Invalid semantic payloads are reported as `status: "invalid_payload"` with `payload_base64`, and lookup exits 2. Allocation and I/O failures are never converted into successful raw fallbacks. `--format source` emits exact source bytes, without a header or added newline.

Human output neutralizes terminal control and bidi-control sequences. `--color auto|always|never` controls renderer-owned ANSI styling; automatic mode honors `NO_COLOR`, `TERM=dumb`, and output redirection. The `source` format intentionally bypasses display sanitization.

Index construction validates framing and strict title order by default. `--trusted` skips only the order check for artifacts verified externally. No lookup table, compression metadata or frontend styling is added to the wire format.

Run `zig build test` for native presentation, parser, allocation-failure and all-six-kind encoder-to-reader-to-renderer tests, alongside the existing codec and wasm gates.

## Self-contained HTML

```sh
zig-out/bin/dict lookup cat --root data/wiktionary-blobs --format html --with-source > cat.html
zig-out/bin/dict search cat --root data/wiktionary-blobs --limit 50 --format html --with-source > cats.html
```

HTML includes its complete SolidJS application, styles and safely embedded JSON. Open the file directly; no server, external assets or network is needed. Search exports materialize only the requested page, not the whole dictionary. The UI filters those exported entries, with keyboard navigation, reading/source/JSON views, template disclosures and responsive layout. External Wiktionary links require a network connection only when followed.

Appearance is handled by JavaScript with system/light/dark/cool themes, an accent picker and sans/monospace type, persisted locally when storage permits. CSS consumes the site's `--site-*` tokens. `frontend/web/src/index.tsx` exposes `mountDictionary(element, data, { inheritedTheme, onNavigate })`, returning a disposer, for later host-site integration. No host-site files are changed.

The independently maintained SolidJS project is in `frontend/web`. Install its pinned dependencies with `bun install --frozen-lockfile`, then `bun run build` there (or `zig build frontend` from the repository). The build type-checks and produces exactly `dist/index.html`. That generated artifact is committed and packaged so native `zig build` requires neither Bun nor network frontend dependencies. Rebuild it when changing frontend source.
