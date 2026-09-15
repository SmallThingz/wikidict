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

Lua is a build-time compiler path only: `Lua source -> AST -> LLVM IR -> native code`. The bundler creates a transient native expander, executes templates/modules for each concrete page, encodes the resulting semantic presentation data, then deletes the expander. No Lua, template source, LLVM bitcode, native worker, bytecode, or other executable corpus representation is shipped.

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

The coordinated pipeline:

1. extracts Scribunto modules and module redirects into a transient build directory;
2. indexes raw dump page ranges for page-sensitive MediaWiki/Scribunto title lookups, then parses the Lua corpus and emits LLVM IR directly from the AST;
3. compiles module/support bitcode and ThinLTO-links a bounded-concurrency transient expander;
4. expands every bundled page with its concrete title/frame context;
5. compiles the expanded wikitext into self-contained semantic presentation records;
6. emits data-only `WIKBLB06` blobs and deletes the entire transient expander directory.

A failed build retains an `.incomplete` marker. Existing output directories are refused rather than modified in place.

## Per-language blobs

The blob writer is a build-tool component fed already-expanded wikitext. Use `build-dictionary` for complete corpus builds; it owns the transient expander and guarantees executable corpus artifacts cannot leak into the published directory.

Verify the published compiled blobs directly:

```sh
zig build -Doptimize=ReleaseFast verify-blobs -- data/wiktionary-blobs
```

The verifier checks WIKBLB06 framing/order/metadata plus every `dict.presentation.v1` record and its semantic indices. It does not reconstruct pre-expansion wikitext.

`WIKBLB06` stores only data records with a minimal magic/kind header and self-delimiting metadata. It deliberately stores no persisted lookup index. Native readers derive indexes into `.dict-cache/`; those caches are disposable and validated against the source file.

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

Compile extracted modules directly to LLVM IR:

```sh
zig build compile-lua -- \
  data/runtime/manifest.jsonl \
  data/runtime \
  data/runtime/llvm
```

`src/lua/direct/` analyzes the AST and emits LLVM IR directly. `src/lua/abi/` contains small stable slot/layout contracts, while `src/lua/runtime/` provides Zig runtime primitives through a C ABI. Bundle builds compile the emitted IR with `zig cc -flto=thin` and perform a bounded ThinLTO link with Zig's bundled LLD. These compiler artifacts are transient and are deleted before publication.

## Blob storage and XZ

Logical blobs are uncompressed. Finished `.wikblb` files may be compressed externally with independent XZ blocks:

```sh
xz -0 -T1 --block-size=1MiB --check=crc64 path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
```

Native readers can use `.wikblb.xz` directly. The derived index records XZ block boundaries so record reads decode only intersecting blocks where possible. `zig build test-storage` and `zig build test-reader` exercise raw files, XZ files, cache recovery, and native reader behavior.
