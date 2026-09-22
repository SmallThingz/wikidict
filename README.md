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

Use Wikimedia's **pages-meta-current** XML dump for complete builds. The
articles-only dump excludes namespaces such as `User:`, but dictionary entries
can transclude real templates stored there (including Georgian conjugation
tables). A missing source in an incomplete dump is not evidence that the page
is missing on Wiktionary. Use a matching dump date for all snapshots below.

Decompress the ordinary `pages-meta-current.xml.bz2` archive to XML before
passing it to the builder. Direct compressed input currently requires a
multistream archive and its companion index. The full XML is indexed across
all namespaces; only dictionary namespaces are published.


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

The `pages` count is derived exactly as MediaWiki does: `ALL - SUBCATS - FILES`. Category lookup preserves case, normalizes spaces/underscores, and ignores title fragments. A missing category in a supplied snapshot has zero members; if the snapshot itself is absent, `pagesInCategory` remains explicitly unsupported. This snapshot is also transient build input and is never published.


`#categorytree` page-member expansion requires the matching category membership
state as well as counts. For bundle inputs that use CategoryTree, provide a
pinned snapshot derived from the matching `linktarget.sql.gz`,
`categorylinks.sql.gz`, and page dump:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --category-tree-snapshot data/category-tree.tsv
```

Generate the snapshot from the same dated XML and SQL dumps (verify their
published checksums first):

```sh
python3 tools/category_tree_snapshot.py \
  --xml data/wiktionary.xml \
  --page data/page.sql.gz \
  --linktarget data/linktarget.sql.gz \
  --categorylinks data/categorylinks.sql.gz \
  --database .tmp/category-import.sqlite \
  --output data/category-tree.tsv
```

The importer uses bounded-memory SQLite scratch storage. Remove its database
from `.tmp/` when finished. The snapshot stores separate query results for
`namespaces=-` (`main`) and unrestricted `mode=pages` (`pages`):

```text
CATEGORY_DB_KEY<TAB>main<TAB>PAGE_TITLE_1<TAB>...<TAB>PAGE_TITLE_200
CATEGORY_DB_KEY<TAB>pages<TAB>PAGE_TITLE_1<TAB>...<TAB>PAGE_TITLE_200
```

Filtering occurs before MediaWiki's 200-child limit, in category-link type and
binary sort-key order. The unrestricted query includes subcategories and
non-file pages from other namespaces. Rendering places selected subcategories
first. Empty results contain the category key and scope only. Missing query
coverage fails explicitly. Old main-only snapshots must be regenerated; they
cannot answer unrestricted requests. Root counts come from
`category-stats.tsv`; CategoryTree's pages count includes subcategories and
excludes files. These snapshots are transient build inputs and never published.

Interwiki-aware Lua such as `mw.site.interwikiMap()` and `mw.title.new("w:...")` requires a pinned site interwiki map:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --interwiki-map-snapshot data/interwiki-map.tsv
```

`interwiki-map.tsv` uses one record per non-comment line:

```text
PREFIX<TAB>IS_LOCAL<TAB>IS_CURRENT_WIKI<TAB>IS_PROTOCOL_RELATIVE<TAB>IS_TRANSCLUDABLE<TAB>URL
```

The boolean fields are `0` or `1`. For MediaWiki siteinfo snapshots, `local` maps to `IS_LOCAL`, `localinterwiki` maps to `IS_CURRENT_WIKI`, `protorel` maps to `IS_PROTOCOL_RELATIVE`, and `trans` maps to `IS_TRANSCLUDABLE`. If the snapshot is absent, interwiki-map APIs remain explicitly unsupported rather than guessing site configuration. All snapshot flags may be supplied together, and every snapshot is copied only into the transient expander.

Wikibase sitelinks are also external state. Modules that call `mw.wikibase.getSitelink` or its legacy alias `mw.wikibase.sitelink` require an explicit snapshot:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --wikibase-sitelinks-snapshot data/wikibase-sitelinks.tsv
```

`wikibase-sitelinks.tsv` contains exact entity/site lookups:

```text
ENTITY_ID<TAB>GLOBAL_SITE_ID<TAB>PAGE_TITLE
```

An empty `PAGE_TITLE` records an authoritative no-sitelink result. A special
`GLOBAL_SITE_ID` of `*` with an empty title marks an entity whose complete
sitelink set was captured; for such an entity, an unlisted site is
authoritatively absent. Without that marker, an unlisted entity/site pair
fails closed as an incomplete snapshot. Absence of the snapshot leaves the API
explicitly unsupported. The optional `globalSiteId` argument defaults to
`enwiktionary`, matching this bundle's site identity.

Wikibase labels and descriptions are separate data-backed entity state. Modules
that call `mw.wikibase.getLabel` or `mw.wikibase.getDescription` require an
explicit English entity-text snapshot:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --wikibase-entity-text-snapshot data/wikibase-entity-text.tsv
```

`wikibase-entity-text.tsv` contains one authoritative entity per
non-comment line:

```text
ENTITY_ID<TAB>ENGLISH_LABEL<TAB>ENGLISH_DESCRIPTION
```

An empty label or description records an authoritative absence. An entity
missing from a supplied snapshot fails closed rather than synthesizing text.
If the snapshot itself is absent, these data-backed Wikibase calls remain
explicitly unsupported. This input is transient and is not copied into shipped
blobs.

MediaWiki's known-language-tag registry is site/version configuration rather than Wiktionary dump data. Interwiki translation helpers that call `mw.language.isKnownLanguageTag` require a pinned registry:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --language-registry-snapshot data/language-registry.tsv
```

`language-registry.tsv` contains the complete siteinfo language list as:

```text
CODE<TAB>NAME
```

Presence means `isKnownLanguageTag(CODE)` is true; absence means false. Without the snapshot, non-English known-tag queries remain explicitly unsupported. This input is transient and is not copied into shipped blobs.

Shared file-repository state used by `mw.title.file`, legacy `fileExists`, and
`Media:... .exists` is not present in the Wiktionary XML dump. Bundle builds
that need file dimensions or repository existence must provide a pinned
snapshot:

```sh
zig build -Doptimize=ReleaseFast build-dictionary -- \
  data/wiktionary.xml \
  data/wiktionary-blobs \
  --file-metadata-snapshot data/file-metadata.tsv
```

`file-metadata.tsv` contains one authoritative lookup per file title:

```text
FILE_TITLE<TAB>EXISTS<TAB>WIDTH<TAB>HEIGHT
```

`EXISTS` is `0` or `1`. Missing files use zero width and height. A title
absent from a supplied snapshot fails closed as an incomplete snapshot; if the
snapshot itself is absent, file-repository APIs remain explicitly unsupported.
`Media:` existence is resolved through the corresponding `File:` record.
This snapshot is transient and is not copied into shipped blobs.

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
