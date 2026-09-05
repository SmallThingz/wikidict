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
