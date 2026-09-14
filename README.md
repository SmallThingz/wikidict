# Dict

Offline Wiktionary tooling in Zig. The repository builds compact per-language data, a local reader/server, and a dump-specific native Lua execution engine.

## Layout

```text
encoder/          Wiktionary XML -> compact dictionary blobs
decoder/          blob decoding and query APIs
frontend/         CLI, TUI, HTTP server, HTML/JSON presentation
lua/
  parser/         Lua syntax parser
  compiler/       IR, analysis, optimization, lowering, linking
  abi/            compiler/runtime ABI contracts
  aot/            native Zig generation and program data
  runtime/        support library linked into generated Lua code
  wikitext/       compile-time wikitext helpers
  extract/        module and template extraction
native/           storage and low-level native helpers
tools/            build, verification, indexing, and integration tools
shared/           shared codecs and utilities
data/             local datasets and generated artifacts
```

Lua has one execution architecture: whole-dump native AOT. A completed runtime contains the generated `dict-native-expansion-worker` and any required `aot-data.bin`. There is no alternate Lua execution engine or silent fallback.

## Build

Use the repository Zig toolchain:

```sh
zig build
```

This installs the main dictionary tools under `zig-out/bin/`.

Run the main validation gate:

```sh
zig build test
```

Run the real extraction -> AOT -> native expansion integration gate:

```sh
zig build test-runtime
```

## Build a complete dictionary

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

The coordinated pipeline:

1. extracts Scribunto modules;
2. extracts templates, redirects, and auxiliary source pages;
3. parses and compiles the module corpus;
4. generates native Zig AOT shards and external program data where required;
5. builds the dump-specific native expansion worker;
6. encodes and links dictionary blobs.

A failed build retains an `.incomplete` marker. Existing output directories are refused rather than modified in place.

For runtime-only assets:

```sh
zig build -Doptimize=ReleaseFast build-runtime -- \
  data/wiktionary.xml \
  data/runtime
```

## Per-language blobs

Build blobs only:

```sh
zig build -Doptimize=ReleaseFast build-blobs -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

An optional trailing page count creates a deterministic limited build.

Verify blobs against the XML source:

```sh
zig build -Doptimize=ReleaseFast verify-blobs -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

`WIKBLB05` stores sorted records with shared symbol identity and self-delimiting metadata. It deliberately stores no persisted lookup index. Native readers derive indexes into `.dict-cache/`; those caches are disposable and validated against the source file.

## Query and read

```sh
zig-out/bin/dict lookup cat --root data/wiktionary-blobs
zig-out/bin/dict search ca --root data/wiktionary-blobs
zig-out/bin/dict languages --root data/wiktionary-blobs
zig-out/bin/dict stats --root data/wiktionary-blobs
```

Useful output formats:

```sh
zig-out/bin/dict lookup cat --root ROOT --format json --with-source
zig-out/bin/dict lookup cat --root ROOT --format html --with-source > cat.html
zig-out/bin/dict lookup cat --root ROOT --format source
```

`dict.results.v1` is the frontend-neutral JSON interface. Exact source output remains byte-faithful to the stored source. Human rendering uses the native Lua worker when the linked runtime is available. A missing or incompatible worker is an explicit expansion failure.

`dict tui [PREFIX] --root ROOT` opens the interactive terminal reader.

## Live local server

```sh
zig-out/bin/dict serve --root ROOT --port 8787
```

Open `http://127.0.0.1:8787`. The server binds locally, shares retained indexes, and reuses one framed native Lua worker across entry requests. A timeout or crash discards that process and the next request starts a fresh worker.

`/api/stats` exposes native worker request/start counts alongside storage/index statistics.

## Lua development

Extract modules and templates directly:

```sh
zig build extract-modules -- data/wiktionary.xml data/runtime
zig build extract-templates -- data/wiktionary.xml data/runtime
```

Compile extracted modules to native AOT source:

```sh
zig build compile-aot -- \
  data/runtime/manifest.jsonl \
  data/runtime \
  data/runtime/aot \
  --sharded --external-data --external-functions
```

The compiler pipeline lives entirely under `lua/compiler/`; generated-code ABI contracts are isolated under `lua/abi/`. Keep runtime behavior in `lua/runtime/` and code generation in `lua/aot/` instead of mixing those layers.

## Blob storage and XZ

Logical blobs are uncompressed. Finished `.wikblb` files may be compressed externally with independent XZ blocks:

```sh
xz -0 -T1 --block-size=1MiB --check=crc64 path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
```

Native readers can use `.wikblb.xz` directly. The derived index records XZ block boundaries so record reads decode only intersecting blocks where possible. `zig build test-storage` and `zig build test-http` exercise raw files, XZ files, cache recovery, and the live server.

## Legacy monolithic encoder

The older `wiktionary.bin` workflow remains available for compatibility:

```sh
zig build encode -- --input data/wiktionary.xml --output data/wiktionary.bin
zig build decode -- lookup --db data/wiktionary.bin --word color
```

For current work, prefer the per-language blob and native Lua pipeline above.
