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

`WIKBLB02` is the per-language / feature-blob path. It is separate from the older monolithic `wiktionary.bin` workflow documented below.

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

The output contains `languages.tsv`, one `languages/<sha256>.wikblb` file per language, and fixed feature blobs such as `thesaurus.wikblb`, `citations.wikblb`, `reconstruction.wikblb`, `rhymes.wikblb`, and `sign-gloss.wikblb`. A zero-record feature blob may be absent in a limited build.

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

Add `--validate` to make the query tool run the full record-order/offset validation pass before lookup. Without it, the tool uses the trusted fast-open path and validates individual records as they are accessed.

Library consumers can call `decoder.openTrustedBlob(bytes)` for the fast path or `decoder.inspectBlob(bytes)` for full validation. `find()` performs binary search over sorted titles, while language records expose `sectionIterator()`, Thesaurus/Rhymes expose typed `recordIterator()` APIs, Reconstruction exposes a typed view/section iterator, and Citations/Sign gloss expose borrowed raw source slices. Catalog helpers expose `languages.tsv` iteration, language filename derivation, fixed feature filenames, and `findLanguageBlob()`.

These traversal APIs are zero-allocation after the logical blob bytes are available. `WIKBLB02` itself is deliberately uncompressed: storage/transport compression belongs outside the format, and consumers should decompress the finished blob before opening it.

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
