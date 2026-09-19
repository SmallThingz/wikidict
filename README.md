# Dict

Offline Wiktionary tooling with a Zig core. The repository builds fully compiled per-language dictionary data, CLI/TUI readers, a C ABI, and a native Qt 6/C++ desktop application. Lua/Scribunto and MediaWiki templates execute only while bundling.

## Layout

```text
src/
├── decoder/        blob decoding and query APIs
├── encoder/        Wiktionary XML -> compact dictionary blobs
├── frontend/       CLI, TUI, C ABI, shared presentation
├── ffi/            stable public C header
├── qt/             Qt 6 / C++ desktop application
├── lua/            parser, direct LLVM compiler, Scribunto/runtime support
├── native/         storage and low-level native helpers
└── shared/         shared codecs and utilities
tools/              build, verification, indexing, integration tools
data/               ignored local datasets and generated artifacts
```

Lua is a build-time compiler path only: `Lua source -> AST -> LLVM module -> LLVM bitcode -> native code`. The bundler creates a transient native expander, executes templates/modules for each concrete page, encodes the resulting semantic presentation data, then deletes the expander. No Lua, template source, LLVM bitcode, native worker, bytecode, or other executable corpus representation is shipped.

## Build

Use the repository Zig toolchain:

```sh
zig build
```

This installs the Zig dictionary tools under `zig-out/bin/` and the C ABI library under `zig-out/lib/`. Build the native desktop GUI separately with `zig build qt`.

Run the main validation gate:

```sh
zig build test
```

Run the bundle-time expansion and data-only publication integration gate:

```sh
zig build test-bundle
```

## Build a complete dictionary

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs
```

LLVM bitcode compilation defaults to `1 + floor(logical CPU threads / 3)` concurrent Clang workers. Override the total worker count explicitly when needed:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --llvm-workers 8
```

Wiktionary modules that read Commons JsonConfig data through `mw.ext.data` require an explicit pinned snapshot. Supply it as a build input rather than allowing the compiler to consult live Wikimedia state:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --commons-data-snapshot data/commons-data.tsv
```

`commons-data.tsv` uses one record per non-comment line:

```text
DATA_TITLE<TAB>CONTENT_MODEL<TAB>COMPACT_JSON
```

For example, the title field is `Unicode data/images/000.tab` and the content model is `Tabular.JsonConfig`. The snapshot is copied only into the transient bundle expander and is deleted with it; it is never published in the dictionary blobs. If no snapshot is supplied, `mw.ext.data` remains explicitly unsupported. Missing titles in a supplied snapshot return the same `false` result as JsonConfig, while unsupported content models or localization paths fail closed rather than inventing Wikimedia state.

Category counts used by `mw.site.stats.pagesInCategory` likewise require a snapshot from the matching Wikimedia `category.sql.gz` dump date:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --category-stats-snapshot data/category-stats.tsv
```

`category-stats.tsv` uses the category database key and the three stored MediaWiki category counts:

```text
CATEGORY_DB_KEY<TAB>ALL<TAB>SUBCATS<TAB>FILES
```

The `pages` count is derived exactly as MediaWiki does: `ALL - SUBCATS - FILES`. Category lookup preserves case, normalizes spaces/underscores, and ignores title fragments. A missing category in a supplied snapshot has zero members; if the snapshot itself is absent, `pagesInCategory` remains explicitly unsupported. This snapshot is also transient build input and is never published. Both snapshot flags may be supplied together.

The coordinated pipeline:

1. extracts Scribunto modules and module redirects into a transient build directory;
2. indexes raw dump page ranges for page-sensitive MediaWiki/Scribunto title lookups, then parses the Lua corpus, builds LLVM modules directly from the AST, and serializes transient LLVM bitcode;
3. compiles module/support code to optimized native objects and normally links a transient expander;
4. expands every bundled page with its concrete title/frame context;
5. compiles the expanded wikitext into self-contained semantic presentation records;
6. emits data-only `WIKBLB08` blobs and deletes the entire transient expander directory.

A failed build retains an `.incomplete` marker. Existing output directories are refused rather than modified in place.

## Per-language blobs

The blob writer is a build-tool component fed already-expanded wikitext. Use `build-dictionary` for complete corpus builds; it owns the transient expander and guarantees executable corpus artifacts cannot leak into the published directory.

Verify the published compiled blobs directly:

```sh
zig build -Doptimize=ReleaseFast verify-blobs -- data/wiktionary-blobs
```

The verifier checks WIKBLB08 framing/order/metadata plus every binary `DPR2` presentation record and its semantic indices. It does not reconstruct pre-expansion wikitext.

`WIKBLB08` stores only data records with a minimal magic/kind header and self-delimiting metadata. It deliberately stores no persisted lookup index. Native readers derive indexes into `.dict-cache/`; those caches are disposable and validated against the source file.

`WIKBLB08` is intentionally incompatible with older bundles: presentation payloads are binary `DPR2` semantic records, including compiled display-title spans, rather than JSON or raw title markup. Rebuild older bundles instead of attempting an in-reader compatibility path.

## Query and read

```sh
zig-out/bin/dict lookup cat --root data/wiktionary-blobs
zig-out/bin/dict search ca --root data/wiktionary-blobs
zig-out/bin/dict languages --root data/wiktionary-blobs
zig-out/bin/dict stats --root data/wiktionary-blobs
```

`dict.results.v1` is the frontend-neutral JSON interface. Reader output is rendered from self-contained compiled presentation data; readers do not parse wikitext or execute Lua/templates.

`dict tui [PREFIX] --root ROOT` opens the interactive terminal reader.

## Native Qt desktop application

```sh
zig build qt
zig-out/bin/dict-qt --root ROOT cat
```

The Qt 6 interface is written in C++ and links directly to `libdictffi`; there is no local HTTP server, browser UI, or web engine. The C ABI owns the mapped dictionary/index and returns versioned `dict.results.v1` JSON buffers to native clients.

The Qt app includes native history, bookmarks, settings, random words, definition quizzes, flashcards, and an unscramble game. Build/install the reusable C boundary with `zig build ffi`; its public header is installed as `zig-out/include/dict/dict.h`.

## Lua development

Extract Scribunto modules directly:

```sh
zig build extract-modules -- data/wiktionary.xml data/runtime
```

Compile extracted modules directly to LLVM bitcode:

```sh
zig build compile-lua -- \
  data/runtime/manifest.jsonl \
  data/runtime \
  data/runtime/llvm
```

`src/lua/direct/` analyzes the AST and constructs LLVM modules directly through LLVM's C API; production does not print or reparse textual LLVM IR. The build therefore requires the host LLVM shared library and matching Clang toolchain. Executable Lua modules are grouped into bounded in-memory LLVM modules and serialized once as transient bitcode; the compact root-function table is separate bitcode, while names, lookups, shapes, and other semantic corpus metadata use a build-only binary format and bypass LLVM entirely. Large static Lua literal graphs are likewise encoded as constant data and materialized by the Zig runtime instead of becoming optimizer-visible table-building instruction graphs. `src/lua/abi/` contains small stable slot/layout contracts, while `src/lua/runtime/` provides Zig runtime primitives through a C ABI. Production optimization is usage-driven: modules covering the dominant page and module reach compile at `-O2`, while the rest use `-O1`; source size is only a secondary ranking cost. `-O0` is reserved for tests and diagnostics. No LTO is used. Bitcode and the native expander are build-only artifacts and are deleted before publication.

## Blob storage and XZ

Logical blobs are uncompressed. Finished `.wikblb` files may be compressed externally with independent XZ blocks:

```sh
xz -0 -T1 --block-size=1MiB --check=crc64 path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
```

Native readers can use `.wikblb.xz` directly. The derived index records XZ block boundaries so record reads decode only intersecting blocks where possible. `zig build test-storage` and `zig build test-reader` exercise raw files, XZ files, cache recovery, and native reader behavior.
