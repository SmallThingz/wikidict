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

`store.zig` owns one read-only mapping and its validated runtime index. `model.zig` constructs an arena-owned view of semantic sections, blocks, inline spans and feature records. Most text borrows the mapping. Destroy presentation models before closing their store. Nothing in this model is persisted into blobs. Standalone library callers must likewise keep the input source, title and language alive until the returned model is destroyed; the CLI manages these lifetimes.

`dict.results.v1` JSON includes operation, query, kind, language, record_count, total_matches, offset, has_more, matches and entries. Search uses **case-sensitive UTF-8 byte prefixes**, returns title-only matches and supports bounded pagination. Lookup returns the complete semantic entry. `dict.languages.v1` returns sorted language headings. Results are written only to stdout; diagnostics use stderr. Exit codes: 0 success, 1 no matching titles, 2 usage, data, allocation or I/O error. An offset beyond the final search page returns an empty page with the original total.

Entry sections preserve heading levels. `wikitext.zig` renders semantic bodies through the existing portable inline tokenizer, shared HTML entity table and bounded runtime block/template helpers. The resulting spans carry visible text, link targets, emphasis, code, small text, superscript/subscript and semantic roles. Blocks include nested list marker paths, numbering, preformatted text, rules and table cells. Entries expose references, rendered preamble spans, `rendered_templates` and `unexpanded_templates` (unsupported count). These are runtime presentation fields, not a change to the blob format. `Block.text` and `Reference.body` retain source fragments for diagnostics; render their `spans`, not those raw fields. Original syntax remains separate in `source`/`source_base64` and unsupported-template spans.

`--with-source` adds exact reconstructed source. Non-UTF-8 source is carried as `source_base64` instead of invalid JSON text. Invalid semantic payloads are reported as `status: "invalid_payload"` with `payload_base64`, and lookup exits 2. Allocation and I/O failures are never converted into successful raw fallbacks. `--format source` emits exact source bytes, without a header or added newline.

Human output neutralizes terminal control and bidi-control sequences. `--color auto|always|never` controls renderer-owned ANSI styling; automatic mode honors `NO_COLOR`, `TERM=dumb`, and output redirection. The `source` format intentionally bypasses display sanitization.

Index construction validates framing and strict title order by default. `--trusted` skips only the order check for artifacts verified externally. No lookup table, compression metadata or frontend styling is added to the wire format.

Run `zig build test` for native presentation, parser, allocation-failure and all-six-kind encoder-to-reader-to-renderer tests, alongside the existing codec and wasm gates.

## Self-contained HTML

```sh
zig-out/bin/dict lookup cat --root data/wiktionary-blobs --format html --with-source > cat.html
zig-out/bin/dict search cat --root data/wiktionary-blobs --limit 50 --format html --with-source > cats.html
```

HTML includes its complete SolidJS application, styles and safely embedded JSON. Open the file directly; no server, external assets or network is needed. Search exports materialize only the requested page, not the whole dictionary. The UI filters those exported entries, with keyboard navigation, reading/source/JSON views, semantic lists/tables/references, unsupported-template disclosures and responsive layout. External Wiktionary links require a network connection only when followed.

Appearance is handled by JavaScript with system/light/dark/cool themes, an accent picker and sans/monospace type, persisted locally when storage permits. CSS consumes the site's `--site-*` tokens. `frontend/web/src/index.tsx` exposes `mountDictionary(element, data, { inheritedTheme, onNavigate })`, returning a disposer, for later host-site integration. No host-site files are changed.

The independently maintained SolidJS project is in `frontend/web`. Install its pinned dependencies with `bun install --frozen-lockfile`, then `bun run build` there (or `zig build frontend` from the repository). The build type-checks and produces exactly `dist/index.html`. That generated artifact is committed and packaged so native `zig build` requires neither Bun nor network frontend dependencies. Rebuild it when changing frontend source.

## Interactive terminal reader

```sh
zig-out/bin/dict tui cat --root data/wiktionary-blobs
zig-out/bin/dict tui --language French --root data/wiktionary-blobs --theme dark
zig-out/bin/dict tui English/ --kind rhymes --root data/wiktionary-blobs
```

The TUI shows rendered text, headwords, qualifiers, pronunciation, examples and references, with generated emphasis/link styles preserved across Unicode wrapping. Source mode is a separate view. The TUI keeps one runtime index open. Search edits use binary prefix bounds; selecting a result decodes only that entry. Wide terminals show results beside the reading pane, while narrow terminals switch between them. Resize handling, word wrapping, Unicode cell widths, search editing and bracketed paste are supported. Use `terminal`, `dark` or `light` palettes; `--color never` provides monochrome output.

`Tab` cycles search, results and reading; `Enter` opens reading. Arrows or `j`/`k` navigate, `PageUp`/`PageDown` page, and `Home`/`End` jump. `/` focuses search, `Ctrl-U` clears it, `s` toggles exact-source display, `t` changes palette, and `?` opens help. `q` exits outside search; `Ctrl-C`/`Ctrl-D` exits from anywhere. Pasted text is routed to search rather than interpreted as commands.

The current interactive backend targets Linux VT-compatible terminals and requires real terminal stdin/stdout, not pipes or `TERM=dumb`. Cell widths use the C UTF-8 locale; complex emoji sequences can vary between terminal emulators. The build uses libc and LLVM/lld for this executable only. Portable blob modules and browser consumers remain independent of those dependencies.

Terminal settings, cursor, bracketed-paste mode and alternate screen are restored on normal exit, propagated errors and handled interrupt/termination/hangup signals. Forced termination such as SIGKILL cannot run cleanup. Exact-source TUI display remains control-safe; only the CLI `--format source` intentionally emits unmodified bytes.

## Wikitext rendering

```sh
zig-out/bin/dict render article.wiki --title "Example" --format html --with-source > example.html
printf "# A '''bold''' [[word]].\n" | zig-out/bin/dict render - --title "Example"
```

The file/stdin command accepts at most 16 MiB. It supports paragraphs, headings, mixed/nested ordered and unordered lists, definition lists, emphasis, internal/external links, comments, character entities, protected `nowiki`/preformatted blocks, safe HTML formatting, named references, and wiki tables with captions, headers and row/column spans. HTML is constructed from validated nodes, never injected from source. Source-controlled terminal escape sequences remain neutralized. Unknown HTML stays literal or explicitly unsupported; scripts and active embeds never execute.

Common Wiktionary templates have native presentation handlers: headwords/POS, labels and qualifiers, mentions/links, explicit form-of descriptions, supplied IPA/pronunciation/audio links, etymology terms, synonyms, translations/columns, usage examples and multiline quotation passages with citations. No inflections, pronunciations or quotations are fabricated. `wiki_templates.zig` is the explicit supported set. Unknown templates are marked in reading mode; their full syntax is available through JSON, HTML disclosure or exact source.

This is a local Wikitext renderer, not a full MediaWiki/Scribunto installation. Arbitrary Lua modules, template transclusion, generated language-specific inflection tables, nested wiki tables, math typesetting and fetched images are not implemented. Native template handlers render supplied arguments and may not reproduce every MediaWiki-specific option. Depth, 512-argument and node budgets bound rendering; allocation/resource-limit failures propagate instead of being disguised as successful content. Unclosed/empty wiki tables fall back to literal preformatted text.

Renderer validation checks actual visible content and semantic DOM, not only executable exit codes. Tests cover nested/template syntax, HTML inertness, exact source, allocation failures and deterministic malformed input. Browser and PTY integration checks must assert that known templates become readable content and that Source retains the original wikitext.
