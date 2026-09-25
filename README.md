# Wikidict

Wikidict turns Wiktionary dumps into compact, offline dictionaries and provides the
native readers and APIs needed to use them.

The important boundary is simple:

```text
Wikimedia dumps + pinned site data
              |
              v
   MediaWiki/Scribunto build pipeline
              |
              v
       WIKBLB08 + DPR2 data
          /          \
     CLI / TUI       C ABI
                       |
                 Android / Qt
```

Lua, templates and wikitext are build inputs. Readers only consume compiled semantic
data. No Lua engine, template source, LLVM bitcode or deferred executable corpus is
shipped in a dictionary.

## What is here

- **Compiler/bundler** for Wiktionary XML, templates and Scribunto modules.
- **WIKBLB08/DPR2** encoder and decoder.
- **CLI/TUI reader** with search, history, saved words and study modes.
- **C ABI** used by the native desktop application.
- **Raw and seekable XZ storage** with derived random-access indexes.
- **Corpus tooling** for downloading, building, verifying and publishing editions.

The Android and desktop applications live in separate repositories:

- [wikidict-android](https://github.com/SmallThingz/wikidict-android)
- [wikidict-desktop](https://github.com/SmallThingz/wikidict-desktop)

## Build

Use the Zig toolchain configured for the repository.

```sh
zig build
```

The default build installs the reader and C ABI under `zig-out/`.

Useful validation targets:

```sh
zig build test
zig build test-bundle
zig build test-reader
zig build test-storage
```

Build just the reader or C ABI:

```sh
zig build cli -Doptimize=ReleaseFast
zig build ffi -Doptimize=ReleaseFast
```

The public header is installed as `zig-out/include/dict/dict.h`.

## Build a dictionary

Use Wikimedia's `pages-meta-current` dump for complete builds. Wiktionary entries
can depend on pages outside the main and Template namespaces, so an articles-only
dump is not sufficient.

For corpus builds, keep the Wikimedia dumps compressed. The builder streams
their XML through bounded memory and writes page-aligned bzip2 members with
an offset index for random access. Downloaded file boundaries are not usable
as page-stream boundaries: a single meta-current part can expand to gigabytes.

```sh
python tools/download_wiktionaries.py --out data/dumps --wikis enwiktionary
python tools/build_wiktionaries.py --in data/dumps --out data/dictionaries \
  --wikis enwiktionary
```

`build-dictionary` still accepts decompressed XML for small one-off fixtures, but
the corpus builder does **not** materialize a decompressed `pages.xml` scratch
file. Compressed staging targets 4 MiB per member, with a 64 MiB hard cap for
large pages. All XML bytes and page order are preserved across multipart and
concatenated-stream inputs. This requires recompression and compressed scratch
writes; staging reports page counts, byte counts and elapsed time. Up to four
ordinary members compress concurrently, with at most 32 MiB of input queued.
Larger members drain the queue and compress synchronously. Staging removes both
partial outputs if any queued compression or output write fails.

The build pipeline:

1. extracts templates, modules and page metadata;
2. parses Lua and emits transient LLVM bitcode/native code;
3. expands every bundled page with its concrete MediaWiki context;
4. compiles the result into DPR2 presentation records;
5. writes data-only WIKBLB08 files;
6. removes the transient executable build artifacts.

Existing output directories are not modified in place. Failed builds retain an
`.incomplete` marker.

Completed output and verified staging must record the current page-aligned dump
version. Older builds are preserved but cannot be accepted as complete by a new
run: rebuild into a new output directory to requalify them against the full dump.

### Resource and scratch behavior

The corpus builder is intentionally conservative on developer machines:

- a project lock allows one corpus supervisor at a time, preventing concurrent
  corpus invocations from claiming the same build allocation;
- a private Linux cgroup v2 bounds the complete builder/compiler/compressor
  process tree, including memory, CPU time per scheduling period and task count;
  build swap is disabled and the supervisor reaps its own descendants on exit;
- the default resource mode requires an already delegated, writable cgroup with the CPU,
  memory and PIDs controllers enabled. Without it the launcher refuses before
  reading the input manifest. It does not change shared system limits;
- the whole build tree has a fixed 8 GiB aggregate RAM cap, with no build swap.
  Admission budgets 1.5 GiB per worker plus 256 MiB for the controller, allowing
  at most five workers globally and four within one edition. Live free RAM is
  not used to calculate this cap; smaller inherited hard limits still reduce it;
- at least 25% of logical CPU capacity is reserved, and CPU load remains an
  admission limit;
- compiler stages are capped at four workers, page expansion defaults to at most
  four workers, and XZ publication is capped at four threads;
- controller-generated `zig build` commands use `-j1`, serializing compilation
  of the build tools before those runtime worker limits take effect;
- LLVM bitcode/object scratch is removed before page expansion, snapshot inputs
  are linked instead of copied when possible, and verified shard trees are
  removed immediately after merge;
- release compression uses 1 MiB XZ blocks at preset `-6`; higher presets did
  not improve block utilization enough to justify their CPU cost.

The native dump reader decodes an indexed bzip2 member in one pass using a 64 KiB input
buffer. It rejects trailing streams, truncated input and decoded members over
128 MiB rather than allocating an entire compressed part or accepting a partial
decode. Direct `zig build` fixture commands do not pass through the corpus
supervisor and must be launched with appropriate external limits.

When a user explicitly accepts sampled limits instead of a kernel aggregate cap,
`--resource-mode=watchdog` runs without cgroup delegation. It samples owned-process
PSS and task counts, stops the build above 8 GiB or 256 tasks, restricts it to four
CPUs at low priority, and imposes a two-hour deadline. PSS excludes unmapped file
cache, and sampling can overshoot between checks. This mode cannot disable build
swap. It retains per-process address-space limits and records peaks and the stop
reason in `.tmp/build-watchdog-report.json`. The cgroup mode remains the default.

With watchdog mode and one edition job, `--expansion-workers` can explicitly
request up to eight page workers while `--threads` keeps compiler and other
pipeline stages at four or fewer. This uses at most eight CPUs and leaves four
available CPUs outside the build where possible; a request exceeding the selected
affinity is rejected. CPU selection takes one thread per physical core before
adding sibling threads, using Linux topology when it is available. The watchdog
records the actual CPU set and still enforces
the sampled 8 GiB and 256-task limits. The higher count requires workload memory
measurements: the workers share mapped input files, but also allocate private
runtime state. It is not admitted using the ordinary 1.5 GiB worker estimate.

One substantial scratch write remains by design: compiled records are first
written to spool files. Wikimedia dump order is not the final per-language title
order required by WIKBLB08, so the builder needs one reorder pass before it can
write canonical blobs. The spool is transient and is removed after finalization.

### Reusing build work

An interrupted corpus build retains verified extraction assets and native Lua
objects in its staging workspace. Extraction reuse requires the same compressed
input and index hashes, extractor and extraction arguments. Native object reuse
requires identical emitted bitcode, compiler identity, target and flags; changing
the Zig runtime still compiles and links a fresh worker. Every cached asset is
hashed before reuse, incomplete generations are rejected, and successful corpus
publication removes the staging workspace and these transient caches.

The worker keeps module globals sparse and initializes module-state pages on
first use. A bounded read-only `mw.loadData` cache can reuse results from isolated
evaluations that have no observed varying inputs or effects. Ordinary module
exports and mutable closure state remain local to each invocation. The data cache
holds at most 256 entries and 64 MiB, with an 8 MiB limit for one entry.

The provider also caches decoded non-template page sources, bounded to 64 MiB,
4,096 entries and 1 MiB per entry. It identifies entries by their immutable index
row, page ID and revision, returns a private copy to each caller, and preserves
the current page's in-memory source override. Shutdown diagnostics report page
and compressed-member cache activity, including decompressed byte counts.

Performance reports must distinguish extraction, compilation, page expansion and
publication, and identify which caches were reused. Page coverage and whole-page
fallback counts do not count embedded per-template Lua errors; inspect those
errors as well when qualifying successful conversion. An under-one-hour full-dump
claim requires a completed, timed build against the independently verified page
count, including final blob publication.

### External Wikimedia state

Some MediaWiki APIs depend on state that is not present in the XML dump. Supply
matching, pinned snapshots when the corpus uses them:

| Option | Data |
| --- | --- |
| `--commons-data-snapshot` | Commons JsonConfig |
| `--category-stats-snapshot` | category counts |
| `--interface-messages-snapshot` | localized interface messages |
| `--category-tree-snapshot` | category membership |
| `--interwiki-map-snapshot` | interwiki configuration |
| `--wikibase-sitelinks-snapshot` | Wikibase sitelinks |
| `--wikibase-entity-text-snapshot` | labels and descriptions |
| `--language-registry-snapshot` | known language tags |
| `--file-metadata-snapshot` | shared file metadata |
| `--transclusion-redirects-snapshot` | external transclusion redirects |

These are build inputs only. Missing required state fails closed rather than being
guessed or deferred to the reader.

CategoryTree snapshots can be generated from matching Wikimedia SQL/XML dumps with
`tools/category_tree_snapshot.py`.

`tools/category_stats_snapshot.py` streams category counts from a dated
`category.sql.gz` file. It verifies the compressed source against the download
manifest and records the output hash, row count and source identity alongside the
TSV. Category counts and CategoryTree membership use separate snapshots.

The Python build controller accepts the same auxiliary snapshot options and
includes each TSV's SHA-256 in its shard and publication identity. For a current
interwiki map, run `python3 tools/download_wiktionaries.py --output DIR --wikis
enwiktionary --interwiki-map-only`. This saves the exact API response, the
six-column `interwiki-map.tsv`, and a provenance file with the retrieval time
and both hashes. Siteinfo is current at retrieval time; this snapshot is not a
component of the dated XML/SQL dump.

## Verify and read

Verify a compiled directory:

```sh
zig build -Doptimize=ReleaseFast verify-blobs -- data/wiktionary-blobs
```

Build the reader and query it directly:

```sh
zig build cli -Doptimize=ReleaseFast

zig-out/bin/dict lookup cat --root data/wiktionary-blobs
zig-out/bin/dict search ca --root data/wiktionary-blobs
zig-out/bin/dict languages --root data/wiktionary-blobs
zig-out/bin/dict stats --root data/wiktionary-blobs
```

Run `zig-out/bin/dict` in a terminal to open the interactive reader. `DICT_ROOT`
and `DICT_LANGUAGE` can provide defaults; explicit flags take precedence.

Saved words and history use the same state as the TUI:

```sh
export DICT_ROOT=data/wiktionary-blobs
export DICT_LANGUAGE=English

zig-out/bin/dict save cat
zig-out/bin/dict saved
zig-out/bin/dict history
zig-out/bin/dict unsave cat
```

Search is Unicode case-insensitive by default while preserving exact-title
preference. It is prefix/title search, not fuzzy or full-text search.

## Compressed dictionaries

Readers accept raw `.wikblb` files and independently blocked `.wikblb.xz` files.

Publish compressed files with the repository tool:

```sh
python3 tools/compress_blobs.py path/language.wikblb
```

Or create compatible XZ manually:

```sh
xz -6 -T1 --block-size=1MiB -k path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
```

The external index is derived data. Readers validate it against the source file and
rebuild it when necessary.

## Catalogues and corpus builds

Resolve the newest complete snapshot for every Wiktionary edition:

```sh
python3 tools/download_wiktionaries.py --plan
```

Download selected editions:

```sh
python3 tools/download_wiktionaries.py --wikis enwiktionary simplewiktionary
```

Build downloaded snapshots:

```sh
python3 tools/build_wiktionaries.py --in data/dumps --out data/dictionaries
```

Whole-edition discovery also snapshots authoritative language names. It needs the
ISO 639-3 JSON table from the `iso-codes` package (normally
`/usr/share/iso-codes/json/iso_639-3.json`), or set `ISO_639_3_JSON` to an
equivalent file. The resulting per-edition registry is pinned alongside the dump
snapshot and reused on resume.

Catalogue format and publishing details are documented in
[docs/catalogues.md](docs/catalogues.md).

The reader can inspect a catalogue or install a dictionary directly:

```sh
zig-out/bin/dict catalog
zig-out/bin/dict install FILE_OR_HTTPS_URL --root DIRECTORY --sha256 HASH
```

## Repository layout

```text
src/
├── decoder/    WIKBLB08/DPR2 decoding and query APIs
├── encoder/    dictionary and presentation compilation
├── ffi/        public C header
├── frontend/   CLI, TUI and C ABI implementation
├── lua/        build-time Lua/Scribunto compiler and runtime
├── native/     storage and native helpers
└── shared/     shared codecs and utilities

tools/          corpus, build and validation tooling
docs/           catalogue, rendering and reader notes
```

For reader/platform coverage, see [docs/reader-parity.md](docs/reader-parity.md).
For rendering checks, see
[docs/rendering-validation.md](docs/rendering-validation.md).
