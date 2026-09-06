# Dictionary frontends

The native frontend consumes `WIKBLB04` through the portable encoder/decoder modules. The older monolithic dictionary commands remain separate. No VM or source codec is duplicated here.

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

## Lua bytecode integration

`--runtime PATH` opts into the VM-backed path for lookup, HTML exports, standalone rendering and the TUI. It executes the existing `lua2` compiler/codec/runtime, not native guesses about Lua output. `runtime_bridge.zig` is the narrow integration adapter; no VM implementation is copied into the frontend.

```sh
# Coordinated build: extract templates/modules/redirects, compile bytecode, encode blobs.
# The output directory must not already exist; parent directories are created as needed.
zig build build-dictionary -- DUMP.xml data/dictionary
zig-out/bin/dict lookup mouse --root data/dictionary --runtime data/dictionary/runtime
zig-out/bin/dict tui mouse --root data/dictionary --runtime data/dictionary/runtime
zig-out/bin/dict render article.wiki --runtime data/dictionary/runtime --format html --with-source > article.html

# Build only shared runtime assets, or call the existing converter directly.
zig build build-runtime -- DUMP.xml data/runtime
zig build compile-bytecode -- data/runtime/manifest.jsonl data/runtime/modules data/runtime/modules.bundle
zig build test-runtime
```

Dictionary languages and feature blobs remain separate. Shared templates, module source, semantic module redirects and bytecode live in `runtime/`. No compression metadata or runtime lookup index is added to `.wikblb`. The coordinated build currently delegates to the existing independent passes. A single-pass encoder/bytecode-generator merge is still future work, after the VM interface stabilizes. Converter and executor are built from the same checkout; rebuild assets after incompatible VM codec changes.

Builds refuse existing output directories. A failed stage leaves `.incomplete` and its intermediate files for diagnosis; runtime loading refuses incomplete outputs. `module-redirects.tsv` supplies actual XML redirect targets to the existing runtime loader. Optional legacy `usage.tsv`, `wikibase-sitelinks.tsv` and `interwiki-map.tsv` are consumed when present.

Each expansion runs in a separate process with a 2 GiB address-space limit, bounded input/output and a wall deadline (`--runtime-timeout-ms`, default 5000, range 1..60000). This isolates crashes and per-page allocations while the VM evolves; it is **not a security sandbox**. Use trusted local runtime assets. The TUI waits for each selected page within that deadline, so VM mode can be less responsive than native rendering.

`entry.expansion` is an additive `dict.results.v1` field: `{backend:"lua-vm",status:"ok"|"failed",diagnostic:null|string}`. Semantic VM failures/timeouts produce an explicitly marked native fallback; CLI output exits 2, and the TUI keeps the source view available. Asset, allocation and I/O failures propagate as errors. HTML visibly labels fallback rather than presenting it as successful VM expansion. Exact source always remains the original unexpanded bytes, including in HTML/JSON exports.

The integration tests extract fixture XML, invoke the real converter, execute serialized bytecode with `require` through a module redirect and template parameters, and assert rendered inflections/tables. They also exercise timeout, missing module/assets, failed conversion, existing-output refusal and incomplete-build refusal. They run in the native `zig build test` gate as well as `test-runtime`.

VM correctness and full MediaWiki compatibility remain separate from integration correctness. Full pages can still fail because of runtime defects or missing external page/Wikibase dependencies. Native template presentation remains the default while that work is ongoing; `--runtime` makes the choice explicit.

Observed against the pinned 2026-04-01 dump: the existing converter built all 59,701 extracted Scribunto modules. Actual `en-noun` and `IPA` expansion worked. `lb` and the full `cat activation noise` entry still reported `ModuleNotFound: Module:labels/data`; that title is absent from the extracted Scribunto manifest. Do not fabricate its data or equate this integration gate with full-page compatibility.

## Definition-first entries and exact language accounting

The reading model now exposes `entry.organization`: lexical entries grouped by part of speech and language, each with its original section, etymology association, definition tree, examples, quotations and supporting notes. These are runtime indices into the unchanged `sections` and `blocks`, not persisted lookup tables. Synonym lists are supporting notes, not examples. Distinct origins are not merged. Unrecognized sections and unattached material remain available.

HTML opens on definitions and usage examples. Quotations, history, translations, related terms and references use disclosures, with navigation opening the correct original section. Human CLI output defaults to this shorter view; `--details` includes all supporting material. In the TUI, `d` toggles details and `s` remains exact-source display.

Inflected entries remain real entries. For example, `cats` retains both its noun plural and verb inflection. Form relations are explicit in the machine model. Exact-lookup HTML includes up to eight direct, same-language base entries when available, enabling offline navigation without silently redirecting, merging senses, or inventing inflections. The primary match count remains one. JSON lookup returns the requested entry and semantic base-word references without copying those related pages.

`dict languages` reports the complete catalog. `dict languages cat` reports only blobs containing that exact spelling. JSON retains `dict.languages.v1` and its heading list, adding `scope`, `query`, separate language/Translingual/unverified counts and an `accounting` array of headings, canonical codes and per-blob title counts. Codes come from `Module:languages/canonical names` in the same input dump. Missing registry data remains explicitly unverified, never guessed. These counts are not Wiktionary edition counts, living-language totals, or translation-target counts.

## WIKBLB04 language companions

Definitions, usage examples and usage notes stay in each language's core file. Large section bodies are placed in per-language companions under `details/etymology`, `details/translations`, `details/relations`, `details/references` and `details/quotations`. Each filename is the same SHA-256 of its language heading. The original Thesaurus, Citations, Reconstruction, Rhymes and Sign gloss blobs stay independent. Quotes inside a definition's body stay with that body; the quotation companion stores standalone quotation-section bodies.

Core language payloads retain every section heading and its order. An external body is represented by the two-byte semantic marker `0, 2`; its family is derived from the retained heading, not persisted again. A companion uses outer kind `supplement`, metadata `code\0heading\0family:u8`, and the usual title-sorted, length-framed records. Each record contains canonical length-framed body fragments in section occurrence order. No lookup indexes, offsets, record counts or derived filenames are persisted, and compression stays external.

`blob_encoder.language_parts` splits/rejoins the portable payloads. A section iterator reports `section.external` rather than pretending that a referenced body is empty. `encoder.blob_files.Resolver` opens/maps/indexes companions lazily for selected records, validates their language/family, and reconstructs the original payload before source decoding or Lua expansion. Complete native rendering and exact-source export currently require referenced companions; missing, truncated or mismatched companions fail explicitly. Source-mode decoding must not bypass resolution. The corpus verifier also rejects orphan companion records.

This split reduces the core footprint, not necessarily total storage: titles and framing in independent companions add overhead. Keep all components together for exact reconstruction. Rebuild old v3 output; it is not compatible with v4.
