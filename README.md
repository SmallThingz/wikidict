# Dict

English Wiktionary parsed from the XML dump into a compact binary format, with:

- `encoder/`: package root with the encoding library and CLI
- `decoder/`: package root with the loading, indexing, and query library and CLI
- `lua2/`: Lua 5.1 parser/VM, whole-corpus analysis, and MediaWiki/Scribunto runtime

## Layout

```text
encoder/
decoder/
lua2/
data/
build.zig
```

The Zig sources live directly under each package root, for example `encoder/root.zig` and `decoder/main.zig`.

## Zig Commands

All `zig build <command>` entrypoints now fail fast if a required input file is missing. The only exception is the decoder sidecar index file (`.idx`), which is still rebuilt on demand.

`data/wiktionary-structure.bin` is the persisted structure report used to generate corpus-derived structure tables for `encode`, `decode`, and `verify` when it is present. The build falls back to bootstrap tables when the report does not exist. Run `zig build structure` to refresh the report when the dump changes.

Build the installed dictionary executables:

```bash
zig build
```

### Per-language blob workflow

`WIKBLB05` is the per-language / feature-blob path. It is separate from the older monolithic `wiktionary.bin` workflow documented below.

Build blobs from a Wiktionary XML dump:

```bash
zig build -Doptimize=ReleaseFast build-blobs -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

Use an optional page limit for a smaller deterministic build:

```bash
zig build -Doptimize=ReleaseFast build-blobs -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  5000
```

The output contains `languages.tsv`, one `languages/<sha256>.wikblb` file per language, and fixed feature blobs such as `thesaurus.wikblb`, `citations.wikblb`, `reconstruction.wikblb`, `rhymes.wikblb`, and `sign-gloss.wikblb`. `languages.tsv` stores only language headings; each filename is derived from the heading with SHA-256 and record counts are derived by scanning/building the runtime index. A zero-record feature blob may be absent in a limited build.

Verify generated blobs against the source dump:

```bash
zig build -Doptimize=ReleaseFast verify-blobs -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

`verify-blobs` accepts the same optional trailing page limit as `build-blobs`, which is useful for validating a limited build against the same XML prefix.

Query blobs without reconstructing source wikitext:

```bash
zig build -Doptimize=ReleaseFast query-blobs -- \
  data/wiktionary-blobs language English cat

zig build -Doptimize=ReleaseFast query-blobs -- \
  data/wiktionary-blobs thesaurus cat
```

Queries validate record framing and title order while building the runtime index by default. `--trusted` skips the title-order check only for artifacts whose integrity has already been established externally. `--validate` explicitly selects the default.

For browser or freestanding consumers, depend on the public `blob_decoder` module (and `blob_encoder` when codec/format definitions are needed); these modules contain no filesystem, POSIX, XML-parser, or legacy dictionary dependency. The full `decoder` module re-exports the same blob API for native applications. Library consumers can call `openTrustedBlob(bytes)` for the fast borrowed view or `inspectBlob(bytes)` for full validation. The bare view supports allocation-free sequential iteration; call `buildTrustedIndexAlloc()` after trusted open, or `buildIndexAlloc()` to validate while indexing, to construct the in-memory offsets used by `find()` and `recordAt()`. `find()` then performs binary search over sorted titles, while language records expose `sectionIterator()`, Thesaurus/Rhymes expose typed `recordIterator()` APIs, Reconstruction exposes a typed view/section iterator, and Citations/Sign gloss expose borrowed raw source slices. Catalog helpers expose `languages.tsv` iteration, language filename derivation, fixed feature filenames, and `findLanguageBlob()`.

`WIKBLB05` persists no lookup index, record count, record-area length, or metadata-length field. The wire prefix is magic, blob kind and a 32-byte identity of the shared symbol catalog; language metadata is self-delimited, and each sorted record is `title\0 + varint(payload_len) + payload`. The payload length is the only per-record framing that cannot be recovered from delimiters because raw payloads may contain arbitrary bytes. Sequential traversal is zero-allocation; random-access indexes are derived in memory when requested. `WIKBLB05` itself is deliberately uncompressed: storage/transport compression belongs outside the format, and consumers should decompress the finished blob before opening it.
`WIKBLB02` and `WIKBLB03` files are incompatible: rebuild them with `build-blobs`. Runtime indexes own only their offset arrays; keep the borrowed blob bytes alive and unchanged until all views and indexes are no longer used, and release indexes with `deinit(allocator)`.

Framing validation cannot detect deletion at a complete-record boundary without external information. Use `verify-blobs` against the source for corpus completeness, and establish distribution integrity outside the logical format.

### Human and machine-readable results

Native text/TUI reading now opens only the language core. `--details` (or `d` in the TUI) loads companion sections on demand; source and VM paths remain strict. JSON/HTML include all sections by default, with explicit `--core-only` exports labelling bodies that were not included. See the frontend guide for package/recovery behavior.


`zig build` installs `zig-out/bin/dict`. Use `dict lookup WORD`, `dict search PREFIX`, `dict languages`, or `dict stats`, with `--root PATH` and optional `--language HEADING` / `--kind KIND`.

`--format json` emits the versioned `dict.results.v1` interface for alternative frontends; `--with-source` includes exact source alongside semantic sections and spans. `--format source` emits only the reconstructed source bytes. Rendered human output is the default. `dict render FILE --title TITLE --format html` also renders standalone wikitext without a database; use `-` for stdin. See [frontend/README.md](frontend/README.md) for protocol, ownership, and rendering details.

Encode the dictionary:

```bash
zig build -Doptimize=ReleaseFast encode -- \
  --input data/wiktionary.xml \
  --output data/wiktionary.bin
```

Build a smaller test binary:

```bash
zig build encode -- \
  --input data/wiktionary.xml \
  --output data/test.bin \
  --limit 500
```

Lookup a word with the decoder CLI:

```bash
zig build decode -- lookup --db data/wiktionary.bin --word color
```

Suggestions:

```bash
zig build decode -- suggest --db data/wiktionary.bin --prefix colo --limit 10
```

Stats:

```bash
zig build decode -- stats --db data/wiktionary.bin
```

The first decoder open builds a sidecar cache at `data/wiktionary.bin.idx`. Later opens mmap that cache and skip the expensive metadata rebuild.

### Renderer-facing document format

Dictionary payloads are tagged, length-prefixed records. The default English build stores a compact section IR instead of one opaque wikitext blob; mixed-language builds retain a compact raw fallback.

Renderer code should call `EntryView.renderDocumentAlloc()` and walk sections directly. General and part-of-speech sections expose a renderer-neutral block stream; blocks classify paragraphs, definitions, examples, quotations, list items/details, indents, terms, and blank lines while preserving nesting depth and marker-free text. Each block provides a zero-allocation inline stream for plain text, balanced templates, internal/external links, MediaWiki link trails, `<br>` line breaks, and bold/italic state. Term-list sections additionally expose structured column/list records, and translation sections expose group boundaries and structured language mappings; these paths avoid reconstructing their source wikitext for rendering. Template spans carry the exact template body and normalized name so a frontend can hand them to the Lua/Scribunto runtime rather than parsing braces itself. `EntryView.documentAlloc()` remains available when compatibility bodies for structured sections are required, and the raw APIs still reconstruct the exact stored source for verification. HTML and terminal frontends should render this shared representation rather than reparsing wiki syntax.

Analyze the full dump structure:

```bash
zig build structure -- \
  --input data/wiktionary.xml \
  --output data/wiktionary-structure.bin \
  --top 100 \
  --samples 100
```

The structure analyzer runs in `ReleaseFast` by default and writes a compact binary report. The report persists the source-page dependencies and the exact corpus-derived tables/fingerprint used to synthesize `generated/structure_tables.zig`. Passing `--output -` prints summary counters instead of writing the report.

Extract Scribunto modules and template pages for the Lua/MediaWiki runtime:

```bash
zig build -Doptimize=ReleaseFast extract-modules -- data/wiktionary.xml data/wiktionary-lua
zig build -Doptimize=ReleaseFast extract-templates -- data/wiktionary.xml data/wiktionary-lua
```

The module extractor writes `modules/<page_id>.lua` plus `manifest.jsonl`; the template extractor writes `templates/<page_id>.wiki` plus `template-manifest.tsv`. Both mmap the XML dump and parse only matching namespace pages.

Run the complete test gate:

```bash
zig build test
```

This serializes the encoder, decoder, structure, verifier, and Lua2 test targets to keep peak build memory predictable. The Lua2 aggregate imports every committed Lua2 source, so operational tools are compile-checked alongside the parser, VM, MediaWiki, and Scribunto unit tests.

### Offline HTML reader

`dict lookup cat --root PATH --format html --with-source > cat.html` writes a self-contained themed reader. Use `dict search PREFIX --limit N --format html --with-source` to export a bounded set of entries. See `frontend/README.md` for the SolidJS project, rebuilding, and embedding interface.

`dict tui [PREFIX] --root PATH` opens the interactive terminal reader. It shares the same blob index and presentation model as the CLI and HTML reader. Use `Tab` for pane focus, arrows for navigation, `s` for source, `t` for theme, and `?` for help. The current TUI backend is Linux-specific.

### Shared Lua runtime and coordinated builds

`zig build build-dictionary -- DUMP.xml NEW_ROOT` builds per-language/feature blobs plus shared templates, module redirects and VM bytecode under `NEW_ROOT/runtime`. It uses the existing Lua converter and blob encoder as coordinated stages; their eventual single-pass merger remains separate work. Existing directories are refused and failed builds retain an `.incomplete` marker.

Pass `--runtime NEW_ROOT/runtime` to `dict lookup`, `dict search --format html`, `dict render` or `dict tui` to enable real bytecode-backed expansion. Source output remains unexpanded and byte-exact. VM failures are explicitly labelled and CLI fallbacks exit 2. See [frontend/README.md](frontend/README.md#lua-bytecode-integration) for runtime assets, resource limits and validation. `zig build test-runtime` exercises the real converter/VM/rendering chain.

### Organized reading and section companions

Entries are grouped by part of speech, with definitions and usage examples first. Origins and sense-specific quotations remain associated, while long supporting sections are expandable. `cats` retains its separate noun and verb uses; exact-lookup HTML can include its base entry for offline navigation. Use `--details` for complete human output or `d` in the TUI.

`WIKBLB05` moves large language-section bodies into per-language `details/{etymology,translations,relations,references,quotations}/<sha256>.wikblb` companions. Core files retain all headings and semantic external-body markers. The native resolver rejoins them before exact-source decoding or VM expansion. Missing components are errors, not empty sections. This is a storage split, not compression, and all old v3 outputs must be rebuilt.

`dict languages WORD` counts only language blobs containing that exact spelling; omitting WORD counts the global catalog. Canonical codes come from the input dump, Translingual is counted separately, and catalog order is deterministic. See the frontend documentation for the full runtime model and protocol.

### Shared IDs in dictionary and bytecode

The final `WIKBLB05` package shares one typed symbol catalog across dictionary
calls, template programs and `DWSY01` Lua bytecode. Static template/function names
are ID operands in both formats; the original spelling exists once in the shared
catalog for exact source and reflection. `zig build audit-symbols -- ROOT RUNTIME_INPUTS`
checks exact source/owner-bytecode reconstruction and catalog binding.

A root with `bytecode.wikblb` automatically uses its linked runtime. `--native`
selects the limited preview, and `--core-only` selects partial native content.
`zig build fetch-media -- RESULTS.json ROOT/media` explicitly acquires attributed
assets; subsequent HTML exports embed them without network access. See
`frontend/README.md` for the APIs, format identity and runtime compatibility boundary.

## Live dictionary, single-entry exports and XZ storage

```sh
zig build
zig-out/bin/dict serve --port 8787
# Open http://127.0.0.1:8787 on the same computer.

zig-out/bin/dict export cats --format json --with-source > cats.json
zig-out/bin/dict export cats --format html --with-source > cats.html
zig-out/bin/dict export cats --format wikitext > cats.wiki
```

`serve` searches the complete selected language or feature collection, not a
static exported list. The themed Solid reader supports pagination, entry links,
language/collection selection and browser Back/Forward. The server binds only to
`127.0.0.1`; `--port 0` chooses an available port and prints it to stderr. Linked
Lua rendering and locally embedded media remain available. The server reuses one
framed Lua worker across entries, so its linked runtime is not rebuilt per page;
timeouts/crashes replace that worker. Slow entry expansion does not hold the search
lock. The live UI has no export toolbar; `export` is the
CLI operation for exactly one entry. Existing `lookup`/`search` exports and
standalone `render FILE` remain available for compatibility.

Native readers retain loaded indexes and save disposable directories under
`.dict-cache` beside each input file. New processes memory-map those caches rather
than rebuilding or copying the title directory into heap memory. Source identity,
size, modification/change times, cache checksum, framing and endpoint bounds reject
stale or damaged caches; strict title-order validation happens when the cache is built. Replacing a core file also invalidates its
in-process server index. Cache files are trusted local derived artifacts, not a
second source of dictionary content. An unavailable/read-only cache location
falls back to an explicitly reported memory-only index. Nothing was added to
the logical `WIKBLB05` format.

When a `.wikblb` file is absent, native readers try `.wikblb.xz`, including
companions, symbols and runtime artifacts. Building the native tools requires
liblzma headers; reading XZ requires `liblzma.so.5`. Portable blob codecs and the
browser have no liblzma dependency and still consume uncompressed logical bytes.

Compress finished files externally with independent XZ blocks for useful random
access. On a copy of the dataset, for example:

```sh
xz -0 -T1 --block-size=1MiB --check=crc64 path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
zig-out/bin/dict serve --root path/to/dataset
```

`index-blobs` accepts files compressed beforehand. The first directory build
streams and validates the decompressed data once without saving a decompressed
copy. Subsequent opens reuse the record directory and XZ's own block index;
selected records decode only intersecting blocks and verify their integrity
checks. Block-crossing records and concatenated XZ streams are supported. Large
blocks use bounded-memory streaming; small decoded blocks have a bounded cache.

A file compressed as one block must decode that block to read a record. Indexing
cannot create independent boundaries; recompress with `--block-size` to change
that tradeoff. `index-blobs` reports records, logical index bytes, heap-backed index bytes, cache
mapping bytes, block count and whether the cache was reused, written or memory-only.
The current cache uses compact 16-byte record rows; cache versions are disposable and
are rebuilt once when this derived layout changes. `zig build test-storage` and
`zig build test-http` exercise real raw/XZ files, cache recovery and the live
backend, and are included in the native test gate.
