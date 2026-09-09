# Dictionary frontends

The native frontend consumes `WIKBLB05` through the portable encoder/decoder modules. The older monolithic dictionary commands remain separate. No VM or source codec is duplicated here.

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

`store.zig` owns a native storage handle and its validated runtime directory; raw and XZ record reads have explicit ownership. `model.zig` constructs an arena-owned view of semantic sections, blocks, inline spans and feature records. Text may borrow the selected record buffer. Destroy presentation models before releasing that record or closing its store. Nothing in this model is persisted into blobs. Standalone `fromWikitext` owns its input copy; record-based models borrow their resolved payload, so destroy them before freeing the bound record or closing its store.

`dict.results.v1` JSON includes operation, query, kind, language, record_count, total_matches, offset, has_more, matches and entries. Search uses **case-sensitive UTF-8 byte prefixes**, returns title-only matches and supports bounded pagination. Lookup returns the complete semantic entry. `dict.languages.v1` returns sorted language headings. Results are written only to stdout; diagnostics use stderr. Exit codes: 0 success, 1 no matching titles, 2 usage, data, allocation or I/O error. An offset beyond the final search page returns an empty page with the original total.

Entry sections preserve heading levels. `wikitext.zig` renders semantic bodies through the existing portable inline tokenizer, shared HTML entity table and bounded runtime block/template helpers. The resulting spans carry visible text, link targets, emphasis, code, small text, superscript/subscript and semantic roles. Blocks include nested list marker paths, numbering, preformatted text, rules and table cells. Entries expose references, rendered preamble spans, `rendered_templates` and `unexpanded_templates` (unsupported count). These are runtime presentation fields, not a change to the blob format. `Block.text` and `Reference.body` retain source fragments for diagnostics; render their `spans`, not those raw fields. Original syntax remains separate in `source`/`source_base64` and unsupported-template spans.

`--with-source` adds exact reconstructed source. Non-UTF-8 source is carried as `source_base64` instead of invalid JSON text. Invalid semantic payloads are reported as `status: "invalid_payload"` with `payload_base64`, and lookup exits 2. Allocation and I/O failures are never converted into successful raw fallbacks. `--format source` emits exact source bytes, without a header or added newline.

Human output neutralizes terminal control and bidi-control sequences. `--color auto|always|never` controls renderer-owned ANSI styling; automatic mode honors `NO_COLOR`, `TERM=dumb`, and output redirection. The `source` format intentionally bypasses display sanitization.

Native directory construction and cache loading validate framing and strict title order. The legacy `--trusted` argument remains accepted, but does not bypass these checks on persistent native caches. No lookup table, compression metadata or frontend styling is added to the wire format.

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

This is a local Wikitext renderer, not a full MediaWiki/Scribunto installation. The native-only fallback does not execute arbitrary Lua or generate language morphology. Linked runtime mode below supplies Lua/module transclusion and generated tables. Nested wiki tables and math typesetting are not fully implemented. Local attributed media can be embedded in HTML. Native template handlers render supplied arguments and may not reproduce every MediaWiki-specific option. Depth, 512-argument and node budgets bound rendering; allocation/resource-limit failures propagate instead of being disguised as successful content. Unclosed/empty wiki tables fall back to literal preformatted text.

Renderer validation checks actual visible content and semantic DOM, not only executable exit codes. Tests cover nested/template syntax, HTML inertness, exact source, allocation failures and deterministic malformed input. Browser and PTY integration checks must assert that known templates become readable content and that Source retains the original wikitext.

## Lua bytecode integration

A dataset containing `bytecode.wikblb` automatically selects the VM-backed path. `--runtime PATH` overrides its location and enables it for standalone rendering. `--native` selects the explicitly limited native preview. The VM-backed path is used for lookup, HTML exports, standalone rendering and the TUI. It executes the existing `lua2` compiler/codec/runtime, not native guesses about Lua output. `runtime_bridge.zig` is the narrow integration adapter; no VM implementation is copied into the frontend.

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

Dictionary languages and feature blobs remain separate. Raw extraction/compiler inputs remain in `runtime/`; the final shared-ID `symbols.wikblb`, `templates.wikblb`, `bytecode.wikblb`, `redirects.wikblb` and `pages.wikblb` live at the dataset root. The published native worker works without the raw `.lua`/`.wiki` inputs; linked VM bytecode remains an oracle/legacy fallback. No compression metadata or runtime lookup index is added to `.wikblb`. The coordinated build currently delegates to the existing independent passes. A single-pass encoder/runtime build merge is still future work. AOT compiler and native worker are built from the same checkout; rebuild runtime assets after incompatible compiler or runtime changes.

Builds refuse existing output directories. A failed stage leaves `.incomplete` and its intermediate files for diagnosis; runtime loading refuses incomplete outputs. `module-redirects.tsv` supplies actual XML redirect targets to both native and legacy runtime loaders. Optional legacy `usage.tsv`, `wikibase-sitelinks.tsv` and `interwiki-map.tsv` are consumed when present.

CLI and TUI expansion use a subprocess with a 2 GiB address-space limit, bounded input/output and a wall deadline (`--runtime-timeout-ms`, default 60000, range 1..60000). New runtime builds publish a dump-specific native AOT worker; older runtimes fall back to the embedded VM. The live HTTP server keeps one framed expansion worker and gives every request fresh page state. A timeout/crash kills only that worker and the next entry request starts a clean replacement. The worker requests Linux parent-death cleanup. This is **not a security sandbox**; use trusted local runtime assets.

`entry.expansion` is an additive `dict.results.v1` field: `{backend:"lua-aot"|"lua-vm",status:"ok"|"failed",diagnostic:null|string}`. Lua expansion failures/timeouts produce an explicitly marked native fallback; CLI output exits 2, and the TUI keeps the source view available. Asset, allocation and I/O failures propagate as errors. HTML visibly labels fallback rather than presenting it as successful Lua expansion. Exact source always remains the original unexpanded bytes, including in HTML/JSON exports.

The integration tests extract fixture XML, build and execute the native AOT worker, exercise the VM oracle fallback, resolve `require` through a module redirect and template parameters, and assert rendered inflections/tables. They also exercise timeout, missing module/assets, failed conversion, existing-output refusal and incomplete-build refusal. They run in the native `zig build test` gate as well as `test-runtime`.

Native AOT correctness and full MediaWiki compatibility remain separate from integration correctness. Full pages can still fail because of runtime defects or missing external page/Wikibase dependencies. Linked datasets use their runtime automatically; `--native` and `--core-only` make fallback/partial reading explicit. Unlinked legacy datasets still use native rendering by default.

The real `cat` and `cats` entries are validated with zero unresolved calls through the linked runtime. Their runtime includes revision-pinned dependencies missing from the dump and actual auxiliary page source (including `Appendix:Glossary`), rather than native stubs. Success on these entries is not proof that every source template in the corpus can execute: fresh builds still need their external page/Wikibase dependencies, and missing data fails explicitly.

## Definition-first entries and exact language accounting

The reading model now exposes `entry.organization`: lexical entries grouped by part of speech and language, each with its original section, etymology association, definition tree, examples, quotations and supporting notes. These are runtime indices into the unchanged `sections` and `blocks`, not persisted lookup tables. Synonym lists are supporting notes, not examples. Distinct origins are not merged. Unrecognized sections and unattached material remain available.

HTML opens on definitions and usage examples. Quotations, history, translations, related terms and references use disclosures, with navigation opening the correct original section. Human CLI output defaults to this shorter view; `--details` includes all supporting material. In the TUI, `d` toggles details and `s` remains exact-source display.

Inflected entries remain real entries. For example, `cats` retains both its noun plural and verb inflection. Form relations are explicit in the machine model. Exact-lookup HTML includes up to eight direct, same-language base entries when available, enabling offline navigation without silently redirecting, merging senses, or inventing inflections. The primary match count remains one. JSON lookup returns the requested entry and semantic base-word references without copying those related pages.

`dict languages` reports the complete catalog. `dict languages cat` reports only blobs containing that exact spelling. JSON retains `dict.languages.v1` and its heading list, adding `scope`, `query`, separate language/Translingual/unverified counts and an `accounting` array of headings, canonical codes and per-blob title counts. Codes come from `Module:languages/canonical names` in the same input dump. Missing registry data remains explicitly unverified, never guessed. These counts are not Wiktionary edition counts, living-language totals, or translation-target counts.

## WIKBLB05 language companions

Definitions, usage examples and usage notes stay in each language's core file. Large section bodies are placed in per-language companions under `details/etymology`, `details/translations`, `details/relations`, `details/references` and `details/quotations`. Each filename is the same SHA-256 of its language heading. The original Thesaurus, Citations, Reconstruction, Rhymes and Sign gloss blobs stay independent. Quotes inside a definition's body stay with that body; the quotation companion stores standalone quotation-section bodies.

Core language payloads retain every section heading and its order. An external body is represented by the two-byte semantic marker `0, 2`; its family is derived from the retained heading, not persisted again. A companion uses outer kind `supplement`, metadata `code\0heading\0family:u8`, and the usual title-sorted, length-framed records. Each record contains canonical length-framed body fragments in section occurrence order. No lookup indexes, offsets, record counts or derived filenames are persisted, and compression stays external.

`blob_encoder.language_parts` splits/rejoins the portable payloads. A section iterator reports `section.external` rather than pretending that a referenced body is empty. `encoder.blob_files.Resolver` opens/maps/indexes companions lazily for selected records, validates their language/family, and reconstructs the original payload before source decoding or Lua expansion. Complete native rendering and exact-source export currently require referenced companions; missing, truncated or mismatched companions fail explicitly. Source-mode decoding must not bypass resolution. The corpus verifier also rejects orphan companion records.

This split reduces the core footprint, not necessarily total storage: titles and framing in independent companions add overhead. Keep all components together for exact reconstruction. Rebuild or link old outputs to produce v5. The reader still accepts v4 staging artifacts, without pretending they are symbol-linked.

## Optional packages and core reading

Explicit `--native` text lookup and the native-only TUI start from the language core only. Etymology,
translations, relations, references and standalone quotation-section bodies are
not mapped or indexed until details or exact source is requested. Definitions,
usage examples, origins and their original section positions remain available.
`--details` loads the complete entry; the TUI uses `d` for details and `s` for source.
VM rendering also loads complete source, never a silently shortened fragment.

JSON and HTML remain complete by default. `--core-only` explicitly exports a
partial native entry in either format, without opening companion blobs. It cannot
be combined with `--with-source`, `--format source`, `--details` or `--runtime`.
`entry.content: "core"` and `section.deferred` identify excluded bodies; their
headings and origin associations remain present. A body marked deferred is **not
an empty source section**. The HTML labels it "Not included" and explains how to
make a complete export. `entry.content: "complete"` describes source inclusion,
not full MediaWiki/template rendering compatibility.

```sh
zig-out/bin/dict lookup cat --core-only --format json
zig-out/bin/dict lookup cat --core-only --format html > cat-core.html
zig-out/bin/dict lookup cat --details
```

A missing companion does not prevent core reading. Explicit complete CLI requests
still fail. In the TUI, a missing-package request displays an error without losing
the search session; leaving details/source returns to the core. Installing the
matching package and trying again works in the same session. Corrupt data, I/O and
allocation failures still propagate. The portable `fromRecord` remains strict;
`fromCoreRecord` is the explicit partial-presentation API. Core mode does not rewrite or drop stored source. `zig build test-reader` exercises these
paths against real freshly built files and is included in the native test gate.

## Reading layout and supplied quotations

HTML uses the original hierarchical definition numbers rather than restarting
visually at `1` at every nesting level. A compact pronunciation panel shows the
first supplied pronunciation and expands to the remaining variants. Only a
pronunciation section preceding every origin and part of speech within its
language is promoted; origin-specific pronunciations remain in their scope.
Sections are moved in the reading layout, not duplicated or rewritten in source.

Anagram templates render their supplied words as language-aware links; the
alphabetization key is not displayed as a word. Unknown options remain explicit.
For an unsupported `RQ:*` citation template with a named `passage`, the supplied
passage and named translation render visibly, but its original citation template
remains marked unexpanded and inspectable. This does not infer publication data,
claim a successful Lua expansion, or change the exact source.

## Shared template/function IDs and linked programs

`WIKBLB05` replaces static call-name occurrences with `0xfe + canonical varint(ID)`.
A literal `0xfe` is escaped with ID zero. IDs are one-based ordinals in the sorted,
typed `symbols.wikblb` catalog: template, parser function, module, and callable/member
atom. The same function ID occurs in an `#invoke` operand and the compiled program's
string-pool operand. Templates and module programs are themselves keyed by numeric
IDs, not names. Other dictionary titles remain ordinary words, not opaque identifiers.

The 41-byte outer header is eight-byte magic, kind and 32-byte catalog identity.
That identity is a cross-file semantic binding, not a lookup index. Mismatched
catalogs/artifacts and `.binding-incomplete` builds are rejected. Counts, offsets
and lookup maps are derived at runtime. Per-language separation and external
compression policy are unchanged. A spelling is retained once in the symbol catalog
for byte-exact source reconstruction and reflective Lua; this is not blind renaming
of prose, ordinary strings or dynamically computed names.

`DWSY01` is the linked envelope over the existing `DWVM02` codec. The link adapter
uses the owner's serializer, substitutes symbol operands in the string pool and
preserves every function/instruction body. At the VM boundary it binds shared atoms
back to the existing runtime API, preserving `require`, methods, constructed table
keys and Lua reflection. The executing VM was not rewritten for direct global-ID
dispatch. Internal local-function/register operands were already numeric.

Portable clients call `BlobView.bindRecordAlloc(allocator, record, names)` and retain
that transient owned result while inspecting its semantic views. Attempting semantic
iteration on a record that still needs symbol binding fails rather than treating its
ID bytes as source. Native `Store` and the verifier manage binding automatically.

```sh
# Existing build pipelines finish with the shared encoder/bytecode link step.
zig build build-dictionary -- DUMP.xml NEW_DIRECTORY
# Or link a fresh copy of v4 data and separately prepared runtime inputs.
zig build link-blobs -- STAGED_DIRECTORY RUNTIME_INPUTS
zig build audit-symbols -- LINKED_DIRECTORY RUNTIME_INPUTS
```

Linking refuses published outputs. `audit-symbols` checks every program against its
exact original compiled bytes, every template against original source, typed IDs,
and shared catalog identity. Duplicate module titles in the source manifest retain
the original loader's last-row-wins semantics, with a diagnostic; conflicting extra
modules are rejected. Dependencies not present in a dump must be supplied from a
compatible, provenance-recorded revision rather than fabricated during rendering.

## Embedded offline images and audio

```sh
zig-out/bin/dict lookup cat --format json > cat.json
zig build fetch-media -- cat.json data/wiktionary-blobs/media
zig-out/bin/dict lookup cat --format html --with-source > cat.html
```

The explicit fetch step reads official Wikimedia image metadata, bounds each asset,
verifies its passive MIME type and saves a hash plus attribution/license metadata.
The renderer reads only local assets (default `ROOT/media`, or `--media-dir PATH`)
and embeds data URIs. Images and audio work with all HTTP(S) blocked. No SVG/HTML
media is executable. Missing assets remain labelled, not represented as embedded.
GFDL 1.2 assets retain the original image and an embedded full license copy. Source
and license links are for attribution, not dependencies needed for offline playback.

## Live HTTP application

`dict serve --root ROOT --port 8787` serves the embedded Solid application and a
local read-only HTTP/1.1 API. Same-origin requests use fixed routes, not arbitrary
filesystem paths. There is no remote-bind option or CORS wildcard. This is not
an authenticated public-deployment server.

Routes are `/api/languages`, `/api/search`, `/api/entry`, `/api/stats` and
`/api/health`. Search and entry return `dict.results.v1`. Parameters are `q`,
`language` (heading or code), `kind`, `offset` and `limit` (1–100). Search returns
titles; entry returns rendered content with original source. Unknown entries
return 404, malformed queries 400, and a failed Lua expansion returns 422 with
its diagnostic. The catalog lists available headings/codes, not the languages
claimed for a particular spelling.

The server keeps four language/feature stores. Lua expansion runs outside the index
lock. One persistent expansion worker keeps linked runtime assets hot while entry
requests are serialized; `/api/stats` exposes `vm_worker_starts` and `vm_requests`.
The browser debounces search, rejects stale responses and has a bounded entry-response cache. Entry links,
collection/language changes, pagination and history operate against the database.
Cancelling a browser request does not promise immediate cancellation of an
already-running expansion; its deadline still bounds that work. SIGINT/SIGTERM stop the
server and join its workers. Running servers can spawn their matching runtime worker
through `/proc/self/exe` even after an atomic executable replacement.

The live reader has no JSON/HTML/wikitext export controls. Use `dict export WORD
--format json|html|wikitext` for exactly one entry. `--with-source` includes source
in JSON/HTML. A single-entry HTML file does not silently bundle other entries.
The older `lookup --format html` compatibility path can still include direct
base entries. `render FILE` remains standalone Wikitext input.

## Native storage ownership and caches

`native/storage.zig` owns derived title/offset directories, retained file handles
and optional XZ transport. Raw payloads use owned positional reads rather than
permanently mapping complete source files. Compressed files retain a read-only
mapping; selected records decode intersecting independently compressed blocks.
Store record reads own their bytes: keep them alive while borrowed presentation
data is used, then call `deinit`. Core data, companions, symbols and auxiliary
runtime pages use the same transport. A VM page-content provider retains its
primary language store and caches existence checks during an expansion.

Disk indexes are separate `.dict-cache/*.idx` files bound to source identity,
size and modification/change times. They can be deleted safely. A newly built
directory validates every record and strict title order; a warm cache is checksum-
and boundary-checked, then memory-mapped directly with compact 16-byte rows instead
of copying its title directory into heap memory. A running server retains that
mapping instead of reopening it per request. HTTP `/api/stats` reports logical and
heap index bytes, cache mapping bytes, payload reads and selected-core XZ decode
counts; those counters exclude independent VM subprocess work.

Cold XZ indexing is one bounded-memory full decode. Warm title search does not
decode payload blocks; reading a record decodes its intersecting blocks. A
single-block file remains correct but expensive to seek. Large block decoding
does not require a full-block allocation. Bytecode/template initialization in
the existing VM adapter still visits all program records; compressed storage
does not make that adapter a demand-loaded VM.
