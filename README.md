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
    WIKBLB08 dictionaries with DPR presentation records
       /          |          \
  CLI / TUI     C ABI     Android decoder
                  |          |
               Qt GUI     Compose UI
```

Lua, templates and wikitext are build inputs. Readers only consume compiled semantic
data. No Lua engine, template source, LLVM bitcode or deferred executable corpus is
shipped in a dictionary.

## What is here

- **Compiler/bundler** for Wiktionary XML, templates and Scribunto modules.
- **WIKBLB08** dictionary encoder and decoder with versioned DPR presentation records.
- **CLI/TUI reader** with search, history, saved words and study modes.
- **C ABI** used by the native desktop application.
- **Raw and seekable XZ storage** with derived random-access indexes.
- **Corpus tooling** for downloading, building, verifying and publishing editions.

| Component | Contents |
| --- | --- |
| [compiler](compiler/) | Wiktionary dump processing, Lua and template expansion, dictionary compilation, and corpus tools |
| [renderer](renderer/) | Shared dictionary format, decoder, native storage, C ABI, command-line and terminal readers, and shared fonts |
| [desktop](desktop/) | Qt desktop app and web reader |
| [android](android/) | Android 12+ app, including the Kotlin decoder and Compose rendering |

Desktop links the renderer’s native C ABI. Android reads the same stored format with its Kotlin decoder and uses the renderer’s [native glyph shaper](renderer/src/shaping/android/egyptian_shape.cpp). Both application histories are part of this repository. The original desktop tag `0.16.0` is preserved as `desktop/0.16.0` alongside WikiDict’s own tag of the same version. Local dumps and generated dictionaries live in the Git-ignored `data/` directory.

The application remains under development. Release publication requires explicit
user approval.

## Build

Use Zig 0.17.0.

```sh
zig build
```

The default build installs the reader and C ABI under `zig-out/`.

For repeated builds on a small checkout volume, put Zig's cache and install
prefix on a volume with enough space. Reuse the same cache across builds. For
example, when your home directory is on that volume, build the reader with:

```sh
cache="${XDG_CACHE_HOME:-$HOME/.cache}/wikidict-native"
ZIG_GLOBAL_CACHE_DIR="$cache/global" zig build cli --cache-dir "$cache/local" --prefix "$cache/install"
```

Useful validation targets:

```sh
zig build test
zig build test-bundle
zig build test-reader
zig build test-storage
```

The Reader/PTY and storage checks require Python 3 with `pyte` installed in the
selected test environment. The Reader harness uses `python3` from `PATH` by
default. To use an existing test environment, run
`WIKIDICT_READER_UX_PYTHON=/path/to/venv/bin/python zig build test-reader`.

To check an entry in a generated dictionary, choose its exact language heading,
title, and a visible phrase from the original definition. For example, this
checks both terminal widths on a Zhuang edition and saves the rendered screens:

```sh
python3 compiler/tools/verify_edition_terminal.py --binary zig-out/bin/wikidict \
  --root "$EDITION_DIR" --language Vahgun --entry 梯田 --witness nazbanzseuj \
  --report .tmp/edition-terminal
```

The check uses a disposable copy of the edition's verified files. It exercises
empty search, keyboard recovery, entry reading, resize, Back, and terminal restoration.
Add `--implicit-language` to test normal startup and select the requested language
with the keyboard when the reader opens its Library.
Use `--screen-projection libvterm` to check native terminal cells, including combining marks.
Use `--screen-projection kitty` to check cell layout with an installed Kitty native parser.
The report records which terminal produced the cells at each width.
For a small bordered table, `--table-tsv original.tsv` compares every cell with
the source, including text split over several screen lines. Supply one TSV row
per source row, select a native screen projection, and use a complete cell as
the `--witness`. The table must fit in one viewport at each width.
For serial reviews, pass `--cases entries.tsv` in place of `--root`, `--language`,
`--entry`, and `--witness`. Each row needs `output_directory`, `owner_heading`,
`exact_title`, `visible_definition_witness`, and `selected_complete_sha256` (the hash
of `complete.json`). For appendices and other supplemental records, set the optional
`kind` column to `supplemental` and leave `owner_heading` empty. With `--root`, use
`--kind supplemental` and omit `--language`. Each result links to its own screens. A failed entry is recorded
and the remaining entries still run.

To inspect a page built with the Writer’s `--indexed-page-outputs` mode, pass
the case directory containing `ordinary-output-result.json` and `data/`. For
example, this opens the Norwegian Bokmål definition of `green` from the Serbian
edition at both terminal widths.

```sh
python3 compiler/tools/verify_edition_terminal.py --binary zig-out/bin/wikidict \
  --indexed-page "$CASE_DIR" --language 'Norwegian Bokmål' --entry green \
  --witness 'the closely mown area surrounding each hole' --report .tmp/green-pty
```

The report identifies the selected page-index row and the exact Reader files
used for this check. Whole-edition checks still use `--root` and `complete.json`.

Build just the reader or C ABI:

```sh
zig build cli -Doptimize=fast
zig build ffi -Doptimize=fast
```

The public header is installed as `zig-out/include/dict/dict.h`.

For the desktop app, configure CMake with the project's patched Qt and install the executable, GUI component and matching Qt runtime together. Follow the [desktop build and install instructions](desktop/README.md). With the prefix used there, launch the app from the repository root:

```sh
./.tmp/desktop-install/bin/wikidict-gio
```

Build Android using its own Gradle root:

```sh
./android/gradlew -p android :app:assembleDebug
```

See each application's README for platform dependencies and qualification steps.

## Build a dictionary

Use Wikimedia's `pages-meta-current` dump for complete builds. Wiktionary entries
can depend on pages outside the main and Template namespaces, so an articles-only
dump is not sufficient.

For corpus builds, keep the Wikimedia dumps compressed. The builder streams
their XML through bounded memory and writes page-aligned Zstandard frames with
an offset index for random access. Downloaded file boundaries are not usable
as page-stream boundaries: a single meta-current part can expand to gigabytes.
Corpus staging requires Python 3.14's `compression.zstd`; the native build tools
link against libbz2 and libzstd.

For faster staging of a single large `.bz2` archive, install `lbzip2` on the
builder's `PATH`. At 8 MiB or larger, a build with at least three available
workers can decode bzip2 blocks in parallel and stream them straight into the
Zstandard writer. One worker handles framing and the rest decode the archive,
up to the four-worker staging limit. Smaller jobs and hosts without `lbzip2`
use Python's bzip2 decoder. Both paths produce the same page frames and index.

```sh
python compiler/tools/download_wiktionaries.py --out data/dumps --wikis enwiktionary
python compiler/tools/build_wiktionaries.py --in data/dumps --out data/dictionaries \
  --wikis enwiktionary
```

`build-dictionary` still accepts decompressed XML for small one-off fixtures, but
the corpus builder does **not** materialize a decompressed `pages.xml` scratch
file. Compressed staging targets 256 KiB per frame, with a 64 MiB hard cap for
large pages. All XML bytes and page order are preserved across multipart and
concatenated-stream inputs. This requires recompression and compressed scratch
writes; staging uses Zstandard level 1 and reports page counts, byte counts and
elapsed time. Small frames reduce decompression work for random page reads.
Up to four archive parts decode and compress concurrently into ordered memory
queues, each capped at 512 MiB. The writer submits the next part only after
draining an earlier part, bounding queued compressed data to 2 GiB without
intermediate files. A page split across archive parts uses the serial framer;
that path compresses up to four ordinary frames concurrently with at most
32 MiB of raw input queued. Staging removes partial outputs on failure.

`compiler/tools/index_original_dump.py` indexes the `.bz2` downloads in place.
It verifies each part against its manifest size and SHA-1, checks each bzip2
block and stream CRC, and records the compressed bit ranges and decoded sizes
in a JSON file. A fresh index can process up to four archive parts in parallel.
For a single-part download it inflates up to four blocks concurrently and
feeds verified XML to the framer in source order. `--workers 1` uses the serial
reader. Both paths check the same SHA-1, block CRCs and stream CRCs.
The ordinary corpus build above defaults to Zstandard staging. Opt into direct
archive inputs for new editions with `--original-archives`. This works with
multiple editions in one ordinary invocation:

```sh
python3.14 compiler/tools/build_wiktionaries.py --in data/dumps --out data/dictionaries \
  --wikis itwiktionary viwiktionary --original-archives
```

Each new edition gets a counted block directory and input marker under
`<output>/<edition>/<date>.original-input`. Indexing verifies the original bytes
once; the build retains their physical identities through completion. Resuming
uses the selected marker without repeating the indexing pass. Existing staged
work, publications, extraction caches and selected sealed workers retain their
normal path. An explicit `--staged-input-root` also remains authoritative.
New indexes and their markers are installed together, so an interrupted creation
can be retried without selecting incomplete metadata. A previously unbound block
directory without its marker is still refused; it is never authenticated against
a digest computed from itself.

Reviewed nonlexical row selections bind an exact physical dump and page index.
For these builds, automatic archive mode retains normal staging. Combining a
review with an explicit original-archive input is rejected before build setup;
the reviewed rows are never discarded or rebound to different coordinates.

To prepare an original-archive input separately for the native builder, give
the indexer a new output
file and a new build-input directory. It counts pages while it verifies the
original archives. This requires only the downloaded dump and its manifest.

```sh
python3.14 compiler/tools/index_original_dump.py --downloads data/dumps \
  --manifest data/dumps/manifest.json --manifest-sha256 "$manifest_sha256" \
  --edition enwiktionary --output en-blocks.json --build-input-root en-original-input
```

Use the digest of the selected download manifest for `manifest_sha256`. Keep the
archives, the block directory and the input marker together for the build. The
native builder selects that input with `--staged-input-root en-original-input`.
An index-only invocation can omit `--build-input-root`. To
read an existing page index in its original coordinates, also supply the
historical `--stage-receipt` and the authenticated `--page-index-sha256` and
`--page-index-size`. This mode rebuilds the original frame stream and its
offset index in memory, verifies both digests and the source page count, and
adds the logical frame ranges to the same JSON output.

To reuse an already verified, page-counted index, pass `--build-input-root` with
a new directory name and `--existing-blocks-sha256` for the JSON at `--output`.
For a historical frame index also pass `--stage-receipt-sha256` and the original
stage and page-index arguments. Both modes write a `.complete.json` pointing to
the original archives and block directory. Reselection takes no decompression.

The build pipeline:

1. extracts templates, modules and page metadata;
2. parses Lua and emits transient LLVM bitcode/native code;
3. expands every bundled page with its concrete MediaWiki context;
4. encodes each entry using the DPR features required by its content;
5. writes data-only WIKBLB08 files;
6. removes the transient executable build artifacts.

Existing output directories are not modified in place. Failed builds retain an
`.incomplete` marker.

When retrying one edition under a different output directory, pass
`--staged-input-root /path/to/previous/YYYYMMDD.shards/input` to reuse its
completed XML repack. This directory contains `pages.xml.zst`,
`pages-index.txt.bz2` and `.complete.json`. Keep it outside the new build's
output, shard and extraction-cache directories. The builder checks the selected
dump identity and both compressed files against the marker, then reads them in
place. Keep the directory intact until the retry finishes. This also works when
the previous attempt completed the repack and failed later while compiling an
entry.

New builds keep their extraction and native-object cache alongside `input` in
`YYYYMMDD.shards/extraction-cache`. Once the earlier build has ended, pass
that path as `--extraction-cache-root` along with `--staged-input-root` to
reuse both. This preserves the dump inode that the extracted indexes refer
to. Existing workspaces with a cache under `input` keep using it in place.

For an edition that repeatedly fails late in a shard, the Python corpus builder
accepts `--shard-pages 1000` to verify and checkpoint every 1,000 indexed pages.
The default is 100,000. Keep the same interval when resuming a build so the
builder can reuse its verified shards. Smaller intervals reduce the number of
completed pages at risk of recompilation and increase per-shard verification,
compression and merge overhead. The corpus controller also accepts `shard_pages`
in the edition's `edition_options` entry.

Completed output and verified staging must record the current page-aligned dump
version. Older builds are preserved but cannot be accepted as complete by a new
run: rebuild into a new output directory to requalify them against the full dump.

### Resource and scratch behavior

The corpus builder is intentionally conservative on developer machines:

Correctness jobs require their configured allocation plus host reserve before
starting. Callers may explicitly count available RAM plus free swap verified on
non-virtual block devices; swap files, zram and unknown backing contribute no
headroom. The default remains RAM-only. This host admission accounting does not
change the job's own memory or swap limits. Memory pressure is recorded but does
not require an otherwise idle host.
After admission, host RAM and pressure changes are telemetry; the job's own memory,
CPU, task and deadline limits still apply. Matched benchmarks use separate quiet-host
conditions so contention is not mistaken for a performance regression.

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
- LLVM bitcode/object scratch is removed before page expansion. Snapshot inputs
  use independent copy-on-write clones where supported. After merging, the
  builder checks the inputs and build identity and seals the verified inventory
  before removing the shard workspace. A failure at that check leaves the
  verified shards available for a matching resume.
- The builder compresses dictionary blobs with XZ preset `-0` and 1 MiB blocks.
  It decodes each compressed file and compares it with the original bytes.

Use `--compress-shards` to limit temporary disk use during a corpus build. The
controller verifies and compresses each completed shard before asking for the
next. For ordinary builds with two or more consecutive missing shards at the
end, a Writer that supports the shard protocol stays open and reuses its loaded
inputs. On resume, the controller rechecks existing shards before reusing them.

Language blobs merge with two workers, each streaming an independent heading
into a private file before renaming it. With four compression threads available,
large blobs use two concurrent XZ encoders with two threads and a 2 GiB encoder
memory limit each. Compression works in waves of at most three files; outputs
are verified one at a time, and the raw files remain until the whole wave passes.
Failures join the workers and remove partial outputs before returning.

A page expansion has a 60-second worker process CPU budget by default, shared
across the one permitted retry after a remote out-of-memory error. Scheduling
and idle waits do not consume this budget. `--expansion-timeout-ms 600000` allows
ten minutes of worker CPU per page; the Python launcher, native pipeline and
blob builder accept 1 through 3,600,000 milliseconds. This does not change Lua's
separate 10-second CPU limit, the worker startup response deadline or the
whole-build wall-clock deadline. An operational page timeout fails the build
instead of publishing an empty page as successful output.

The native dump reader accepts the Zstandard v3 page index and retains support
for the bzip2 v2 index. It validates each Zstandard frame's magic, exact compressed
span and known decoded length before allocating its output, with a 128 MiB decoded
limit. It rejects skippable frames, trailing streams and truncated input. The
bzip2 reader uses a 64 KiB input buffer and the same decoded-size limit.
Direct `zig build` fixture commands do not pass through the corpus
supervisor and must be launched with appropriate external limits.

When a user explicitly accepts sampled limits instead of a kernel aggregate cap,
`--resource-mode=watchdog` runs without cgroup delegation. It samples owned-process
PSS and task counts, stops the build above 8 GiB or 256 tasks, restricts it to four
CPUs and imposes a two-hour deadline. It preserves the caller's CPU nice priority
by default and does not change I/O priority. An explicit watchdog child-priority
target can lower priority but cannot raise it. PSS excludes unmapped file
cache, and sampling can overshoot between checks. This mode cannot disable build
swap. It retains per-process address-space limits and records peaks and the stop
reason in `.tmp/build-watchdog-report.json`. A separate bounded guardian watches
the supervisor and cleans up its identified process tree if the supervisor dies;
the supervisor also aborts if the guardian dies. Monitoring processes share the
selected CPU set, and their memory and tasks count toward the sampled limits.
This remains best-effort process supervision, with a kernel cgroup required for
hard aggregate limits. The cgroup mode remains the default.

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

### Diagnosing presentation failures

`--presentation-audit-pages=1024` asks the corpus controller to audit at most
1,024 indexed rows from a failed shard's start after an authenticated presentation
failure. The diagnostic pass uses the same inputs, worker settings and original
deadline. It preserves the original failure and leaves the edition failed and
unpublished. `--continue-failed-shards` additionally requires this explicit audit
bound; any failed shard still prevents merge and publication.

The native `dict-blob-build --audit-presentation-errors` mode can also audit a
retained failed shard directly, without first replaying its production build.
Use a fresh output path, the same dump, expander, Figure/Book inputs, timestamp
and worker limits, plus `--start-page N --limit-pages 1024`. Keep the original
failed command and failure receipt separately. Do not pass `--index-byte-offset`
(even zero), `--shard-pages`, or the original `--failure-receipt`/`--invocation-id`.
`--shared-inputs` belongs to `--indexed-page-outputs`, which is incompatible with
audit mode. `--audit-expanded-bytes` optionally retains up to 2,097,152 expanded
bytes per failure, within the audit's aggregate payload cap.

Audit rolls back each page's partial scratch records before processing the next
page. Only its supported presentation/input errors continue; allocation, I/O
and other fatal errors still abort. Audit never finalizes dictionary output or
publishes coverage. Check `audit-summary.json` for a complete selected range and
consistent counters; an interrupted summary is incomplete. Even a complete,
all-passing range is diagnostic evidence, not whole-corpus acceptance. Failed
pages make the native audit exit nonzero; the controller retains the original
production failure regardless of the diagnostic result.

Report audit time separately from production time. The page bound limits the
selected range, not startup I/O: full input hashing and final identity checks
still run. A diagnostic pass's cache state and discarded output also differ from
a production build, so its elapsed time is not a production-speed measurement.

### Reusing build work

An interrupted corpus build retains verified extraction assets and native Lua
objects in its staging workspace. Extraction reuse requires the same compressed
input and index hashes, extractor and extraction arguments. Native object reuse
is checked separately for each emitted batch and the program object. Each key
includes that object's exact bitcode, optimization mode, compiler, target and
flags. Optimized batches also include the build-only value helper bitcode and
its Zig producer; O0 batches and the program object do not import those helpers.
Changing one batch can therefore reuse the other objects while compiling and
linking a fresh worker. Every cached object is hashed before reuse. Missing or
corrupt entries are rebuilt independently, and successful corpus publication
removes the staging workspace and these transient caches.

A source-bound caller can explicitly select an independently closed, sealed
native generation as read-only input to an ordinary sharded build. The builder
validates the dump, snapshots, native roles, ABI, toolchain and seal before
creating current state in the owned output workspace. The retained generation
never becomes eligible for output cleanup; an incompatible selection stops
without resetting it. Reuse does not grant page or publication acceptance.

Up to four compiler workers take missing batches from one shared queue. A worker
starts its next batch as soon as its current compiler exits, while the final
link retains the original object order. A full cache hit launches no batch
compilers. On failure, the queue stops admitting work and joins all started
workers before returning. The first population of a new object-cache format
still requires a cold native compile.

Generated Lua batches use Clang's `-march=native` for the build host. The
transient expansion worker is therefore host-specific; the native-object cache
records Clang's resolved CPU and feature set as well as the compiler and flags,
and checks that target again before publishing a generation. A different
resolved CPU or feature set causes a cache miss. Published WIKBLB08/XZ blobs contain data, not the expansion
worker, and remain portable to readers built for their own target.

The runtime worker object and a small value-helper bitcode module compile beside
extraction. Lua emission imports fifteen shared Zig primitives for values,
arguments, captured variables and callable identity into optimized batches, so LLVM can inline their
actual representation and eliminate intermediate copies. O0 batches retain the ordinary runtime calls.
These helper definitions do not provide another public ABI or enable corpus LTO.
The compiler forwards results directly into the caller's result buffer for
eligible return calls, avoiding an intermediate result array. Fixed returns
expose their stores and clipped result count directly to LLVM, and successful
static calls bypass error-name handling. Return expressions still execute in
order even when the caller discards their values. It also emits
source-derived guarded calls for `Language:getCode` and
`Language:getCanonicalName`, and for known captured callables. Each direct
method or captured-call path checks the live function identity; reassigned or
unrelated callables take the ordinary dynamic path. Simple nil and boolean
equality uses direct comparisons while cases that can invoke Lua metamethods
retain dynamic comparison. Linking waits for the runtime worker and generated
module objects. The parser reserves execution slots while the worker compiler
and extractor are active.

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

Set `WIKIDICT_EXPANSION_PROFILE=1` to collect detailed expansion diagnostics.
This records CPU time for every invocation, subtracts nested invocation time
for per-function exclusive totals, and samples module-root timing. It also
tracks exact invocation-key repeats without reusing their results. Profiling is
off by default; worker CPU totals and native-error diagnostics remain enabled.
Profiled and unprofiled runs should be compared separately when measuring speed.

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
| `--language-fallbacks-snapshot` | captured language fallback chains |
| `--category-tree-snapshot` | category membership |
| `--interwiki-map-snapshot` | interwiki configuration |
| `--wikibase-sitelinks-snapshot` | Wikibase sitelinks |
| `--wikibase-entity-text-snapshot` | labels and descriptions |
| `--language-registry-snapshot` | known language tags |
| `--file-metadata-snapshot` | shared file metadata |
| `--transclusion-redirects-snapshot` | external transclusion redirects |

These are build inputs only. Missing required state fails closed rather than being
guessed or deferred to the reader.

For new full-edition builds, prepare a complete interface-message pair before
native compilation. Reuse an already verified complete pair for the same edition
and selected context when available. Otherwise use the existing collector's
`--complete-messages` profile, rather than treating an explicit list of previously
observed keys as full-edition coverage. For example, with matching prepared inputs:

```sh
python3 -B compiler/tools/prepare_language_messages_v2.py capture \
  --wiki jawiktionary --date 20261001 \
  --namespace-registry data/inputs/ja/namespace-registry.tsv \
  --languages en ja --complete-messages \
  --api-sources data/inputs/mediawiki-message-sources \
  --output data/inputs/ja/messages-complete01
python3 -B compiler/tools/prepare_language_messages_v2.py verify \
  data/inputs/ja/messages-complete01
```

The source directory must contain the reviewed `ApiQueryAllMessages.php`,
`MessageCache.php` and `source-receipts01.json`. The verifier requires the pinned
PHP bytes, revision-specific source URLs and receipts, and the same recorded core
revision in every API response. Captured metadata reflects current sequential
observations; the associated dump date does not make it historical dump data.
The collector bounds responses, rows, requests and elapsed time, and retains raw
responses, explicit missing values, empty values and fallback evidence.

Keep the complete generation directory and select **both** its
`interface-messages.tsv` and `language-fallbacks.tsv`, using the corresponding
snapshot flags above. In `compiler/tools/corpus_controller.py` configuration, place their
exact `{path, bytes, sha256}` descriptors under
`edition_options.<wiki>.auxiliary_snapshots`, with keys `interface-messages` and
`language-fallbacks`. Merge these into existing edition options. Both explicit
roles supersede historical message-generation discovery while retaining normal
paired replay and namespace/context validation. Do not replace inputs used by a
running build.

Explicit `--messages` captures remain useful for bounded diagnostics and
historical evidence. Complete enumeration covers the API's returned keys for the
selected languages; it does not prove every page-context lookup. Local
language-suffixed-only pages without a base can be omitted by upstream
enumeration; exact observed extras can be supplied with `--messages` alongside
`--complete-messages`. An unobserved key is not an authoritative missing value.

CategoryTree snapshots can be generated from matching Wikimedia SQL/XML dumps with
`compiler/tools/category_tree_snapshot.py`.

`compiler/tools/category_stats_snapshot.py` streams category counts from a dated
`category.sql.gz` file. It verifies the compressed source against the download
manifest and records the output hash, row count and source identity alongside the
TSV. Category counts and CategoryTree membership use separate snapshots.

The Python build controller accepts the same auxiliary snapshot options and
includes each TSV's SHA-256 in its shard and publication identity. For a current
interwiki map, run `python3 compiler/tools/download_wiktionaries.py --output DIR --wikis
enwiktionary --interwiki-map-only`. This saves the exact API response, the
six-column `interwiki-map.tsv`, and a provenance file with the retrieval time
and both hashes. Siteinfo is current at retrieval time; this snapshot is not a
component of the dated XML/SQL dump.

## Verify and read

Set `EDITION_DIR` to the edition's dated output directory containing `complete.json`
and `languages.tsv`. A build with `--out data/dictionaries` writes to
`data/dictionaries/<wiki>/<dump-date>/`.

For the locally built October 2026 corpus, `data/corpus-campaign-current01/local-editions.tsv`
lists each edition's status, output directory relative to the checkout, and SHA-256
of `complete.json`. Use a `built` row to read entries. An `empty` row has a complete
catalog with no lexical entries. This command opens the Assamese edition from the
checkout root.

```sh
EDITION_DIR=$(awk -F '\t' '$1 == "aswiktionary" && $2 == "built" { print $3 }' \
    data/corpus-campaign-current01/local-editions.tsv)
[ -n "$EDITION_DIR" ] && zig-out/bin/wikidict tui --root "$EDITION_DIR"
```

[Local edition diagnostics](data/corpus-campaign-current01/local-edition-diagnostics.tsv)
lists the pages sent for expansion and the pages with a recorded fallback for
each selected build. The reason counts can overlap on a single page. The
manifest hash ties each row to the corresponding directory in the output index.
An edition without a completed build has blank counts.

[Local Reader checks](data/corpus-campaign-current01/local-edition-reader-checks.tsv)
lists the selected edition digest, scanned records, flagged fields, and original
source lines compared with the decoded text and links. Each completed scan links
to its compressed report. `batch_source_check` records whether the batch's final
source check passed, failed, or could not be confirmed from its receipt.
`batch_source_evidence` links to that receipt or the failure investigation when
available. Blank measurements indicate that this audit series has no result for
the selected output. The [local terminal reading results](data/corpus-campaign-current01/local-edition-terminal-checks.tsv)
link the selected entries to their 90- and 45-column screens, keyboard results,
and retained failures.

[Local edition build times](data/corpus-campaign-current01/local-edition-build-times.tsv)
lists the elapsed build time, input XML pages, and pages per second for each
selected output. The retry columns cover campaign attempts through sequence 351.
The [full-edition attempt log](data/corpus-campaign-current01/local-full-build-attempts.tsv)
lists the retained native driver's completed invocations, including failures. It
reports production time only when the builder recorded its end. Command time
includes setup and shutdown. A successful build can appear in both tables.
The `execution_mode` column identifies publication resumes and checks of
existing output when the original log recorded that distinction. A
`resumed_publication` time measures the final publication step. Use the
earlier producing attempt to account for the cost of compiling those pages.
To update the attempt log, run `python3 compiler/tools/index_corpus_attempts.py
--receipts DRIVER_DIR --output ATTEMPTS.tsv --add ATTEMPT_DIR` from the checkout
root. Supply the attempt directory name relative to the retained driver. The
command checks every numbered execution in that directory against its original
result and stdout. Omit `--add` to check all retained attempts. Include
`--retry-times RETRY_TIMES.tsv` to refresh the existing edition totals from the
same index. Both TSV files must be in the same directory.
For a direct build recorded outside the driver, `--add-guardian-closure` takes
its closure path and checks the command, source inventory, build catalog and
watchdog result. The `closure_join` column keeps a failed child's witnessed exit
distinct from the enclosing session's join. `original-terminal-unknown` means
the outer session lost its terminal and independent checks verified the failed
child's exit and cleanup.
The [per-edition retry times](data/corpus-campaign-current01/local-edition-retry-times.tsv)
combine the historical timings and later attempts, counting each recorded build
once. A logged snapshot-selection failure or a verified top-level import error
in the selected builder records command time before edition production starts.
An unexplained empty log or an interrupted production clock leaves the
production duration unknown. The rate stays blank when a production
duration or selected output is missing.

The native verifier checks the selected directory.

```sh
zig build -Doptimize=fast verify-blobs -- "$EDITION_DIR"
```

Build the reader and query it directly. The executable is `wikidict` on Unix and
`dict.exe` on Windows.

```sh
zig build cli -Doptimize=fast

zig-out/bin/wikidict languages --root "$EDITION_DIR"
zig-out/bin/wikidict lookup cat --language English --root "$EDITION_DIR"
zig-out/bin/wikidict search ca --language English --root "$EDITION_DIR"
zig-out/bin/wikidict stats --language English --root "$EDITION_DIR"
```

Open the interactive reader with `zig-out/bin/wikidict tui --root "$EDITION_DIR"`.
It opens English when installed. In an edition without English it opens the sole
language or shows the Library, where the arrow keys and Enter select a language.
Use `--language` with an exact heading from `languages` to open it directly.
`DICT_ROOT` and `DICT_LANGUAGE` supply defaults for subsequent commands.

Saved words and history use the same state as the TUI:

```sh
export DICT_ROOT="$EDITION_DIR"
export DICT_LANGUAGE=English

zig-out/bin/wikidict save cat
zig-out/bin/wikidict saved
zig-out/bin/wikidict history
zig-out/bin/wikidict unsave cat
```

Search is Unicode case-insensitive by default while preserving exact-title
preference. It is prefix/title search, not fuzzy or full-text search.

## Compressed dictionaries

Readers accept raw `.wikblb` files and independently blocked `.wikblb.xz` files.

Publish compressed files with the repository tool:

```sh
python3 compiler/tools/compress_blobs.py path/language.wikblb
```

Or create compatible XZ manually:

```sh
xz -0 -T1 --block-size=1MiB -k path/language.wikblb
zig build index-blobs -- path/language.wikblb.xz
```

The external index is derived data. Readers validate it against the source file and
rebuild it when necessary.

## Catalogues and corpus builds

Resolve the newest complete snapshot for every Wiktionary edition:

```sh
python3 compiler/tools/download_wiktionaries.py --plan
```

Download selected editions:

```sh
python3 compiler/tools/download_wiktionaries.py --wikis enwiktionary simplewiktionary
```

Build downloaded snapshots:

```sh
python3 compiler/tools/build_wiktionaries.py --in data/dumps --out data/dictionaries
```

Whole-edition discovery also snapshots authoritative language names. It needs the
ISO 639-3 JSON table from the `iso-codes` package (normally
`/usr/share/iso-codes/json/iso_639-3.json`), or set `ISO_639_3_JSON` to an
equivalent file. The resulting per-edition registry is pinned alongside the dump
snapshot and reused on resume.

Catalogue format and publishing details are documented in
[compiler/docs/catalogues.md](compiler/docs/catalogues.md).

The reader can inspect a catalogue or install a dictionary directly:

```sh
zig-out/bin/wikidict catalog "$CATALOG_HTTPS_URL"
zig-out/bin/wikidict install FILE_OR_HTTPS_URL --root DIRECTORY --sha256 HASH
```

Use a separate root folder for each edition and snapshot date. Canonically named
release files retain that scope; the CLI refuses imports from another edition
or unlabelled files into a scoped root. Unlabelled local files remain supported
in their own unscoped root.

## Reader documentation

See [reader and platform coverage](renderer/docs/reader-parity.md) and [rendering validation](renderer/docs/rendering-validation.md).
