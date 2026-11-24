# Plan a local dictionary build

Prefer the current connected Cloud checkout for compilation, translation and
qualification. Use RD/DC for an edition whose measured peak requirements do
not fit locally. Speed takes priority over smaller intermediate files when the
working set fits. The user's 24 November instruction supersedes the earlier
handoff's requirement to do all work on RD.

Work through one edition at a time from the repository root. Reconcile any
existing attempt for that edition before starting another. Reuse its pinned
manifest, original archives, metadata, and compatible stage or cache in place.
Keep inputs, outputs, and scratch inside the checkout and check the resolved
paths before starting. The checkout-local Zig cache can serve later editions.

## Check capacity before staging

```sh
mkdir -p .tmp
df -B1 . .tmp
awk '/^MemAvailable:/ { print }' /proc/meminfo
cat /proc/self/cgroup
# In this container the current cgroup is mounted at the root.
cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current /sys/fs/cgroup/cpu.max
if test -r /proc/pressure/memory; then cat /proc/pressure/memory; fi
```

Check each actual destination filesystem if the downloads, outputs, or caches
are on separate mounts. Count only additional bytes from the current free
space. Add the compressed downloads still needed and the largest concurrent
build footprint. Include any repack or index, snapshots, native tool and cache
growth, spool, shards, and output that overlap at that stage. The archive size
alone is just a lower bound. Keep the builder's 512 MiB disk reserve on each
filesystem. Use measurements from a comparable completed build, including its
cache state and archive mode, to estimate the peak. The watchdog report records
the lowest sampled free space and peak process-tree PSS. A disk delta also
needs a baseline and comparable filesystem activity. PSS misses unmapped file
cache and can miss brief peaks, so allow headroom above a sampled peak.

Check the selected allocation plus host reserve against `MemAvailable` and
the remaining headroom under applicable cgroup limits (`memory.max` minus
`memory.current` for a finite limit). If PSI is unavailable, record it as
unavailable. A build is a local candidate only when both disk and memory
estimates fit. If either estimate is missing, record the fit as unknown and
gather comparable evidence. If the edition exceeds local capacity, check RD/DC
capacity and adopt a matching attempt there or stage that edition there.

## Use the existing tools

For a **new** snapshot, use a fresh downloads directory. `--plan` writes the
manifest and registry without downloading dump files, and reports the selected
archive bytes. Set `edition` to the site ID, such as `simplewiktionary`.

```sh
export TMPDIR="$(realpath .tmp)"
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
downloads="data/inputs/local-$edition"
python3.14 -B compiler/tools/download_wiktionaries.py --out "$downloads" --wikis "$edition" --plan
```

Review the capacity estimate before resuming the download. Record the fresh
manifest digest for the build:

```sh
manifest="$downloads/manifest.json"
manifest_sha256=$(sha256sum "$manifest" | cut -d ' ' -f 1)
python3.14 -B compiler/tools/download_wiktionaries.py --out "$downloads" --wikis "$edition" --resume
```

For historical work, use the saved downloads root and the recorded manifest
digest. Supply that edition's pinned metadata options if required. Set `zig`
to the selected Zig 0.17.0 executable. With normal cgroup delegation, run the
builder with a single edition and one edition job:

```sh
python3.14 -B compiler/tools/build_wiktionaries.py \
  --in "$downloads" --out data/dictionaries --wikis "$edition" --jobs 1 \
  --zig "$zig" --input-manifest "$manifest" --input-manifest-sha256 "$manifest_sha256"
```

Compatible new builds index the compressed original archives in place by default. When
reusing a verified stage, pass `--staged-input-root` and, for repacked input,
its matching `--extraction-cache-root` if available. Keep standard shard
compression and the verified pipeline defaults unless comparable measurements
justify a change. A sharded build admits the merge using its verified shards and
publishes only after verification.

If cgroup delegation is unavailable and sampled watchdog mode is approved,
append `--resource-mode watchdog --cpu-admission affinity --threads 2
--watchdog-memory-limit-mib "$watchdog_mib"` on this two-CPU-quota container.
Choose `watchdog_mib` from the admitted allocation and lower the worker count
if that allocation supports only one. Keep the disk floor and deadline. Save
`.tmp/build-watchdog-report.json` with the attempt before the next launch.
Preserve the source data, verified work and failure receipts when resuming or
handing off an edition. For an existing qualified and armed corpus
configuration, `corpus_controller.py --config "$config" --phase all
--max-editions 1` uses its durable queue and closes at most one edition per run.

## Connected workspace on 24 November 2026

The Cloud checkout is `/workspace/wikidict`, cloned from `origin/main` at
`20cc24979bbf9a793a8f8ccb2c69ad3ac9df7a02`. Its initial capacity was 8 GiB of
cgroup memory, a two-CPU quota and approximately 7.4 GiB of available disk.
Recheck capacity after builds; installed tools and caches consume that disk.

The local environment uses Zig 0.17.0, Python 3.14.10 and LLVM/Clang 23.1.6.
Zig and Python are user-managed tools. The checkout-local dependency prefix
is `.tmp/toolchain/usr`; it contains the LLVM/Clang packages and the bzip2/XZ
development headers. Package downloads were verified against their published
SHA-256 records and removed after extraction. RD's LLVM minor version is
23.1.4, so local native results have their own toolchain provenance.

Activate the current setup before building:

```sh
cd /workspace/wikidict
. .tmp/local-build/env.sh
zig build cli --search-prefix "$WIKIDICT_SEARCH_PREFIX" --cache-dir .zig-cache
```

The environment file selects Python 3.14 for subprocesses, the local Clang and
LLVM library, checkout-local scratch and cache, and the Reader's `pyte`
environment. It also sets `C_INCLUDE_PATH` for the user-installed XZ headers;
`--search-prefix` alone does not reach the existing translate-C step. No
producer source change was needed for that header lookup.

The compiler's title mapper also loads `libunistring.so.5` and
`libutf8proc.so.3` at runtime. The Cloud base image lacked the latter. The
matching dc-box libraries (libunistring 1.4.2 and libutf8proc 2.12.0) were
copied into the same dependency prefix, verified by byte count and SHA-256,
and loaded successfully on the local glibc. Their origins, hashes and local
paths are recorded in `.tmp/toolchain-packages/rd-unicode.json`. Keep these
runtime identities with Writer and namespace qualification receipts. A
successful native compilation alone does not exercise this dynamic load.

Local setup validation passed all six CLI build steps, all 20 compiler-tool
build steps, and 104 disk/memory-control tests. The CLI searched and exported
all three records of the retained Abkhaz output. The cold Writer compilation
took about six minutes with a reported 3 GiB maximum RSS; that measures tool
preparation, not the peak requirement or duration of a complete edition.

The pushed source rejects the newer private R08 Babua record with
`InvalidPresentation`; the matching R09 Reader reproduces the retained export
byte for byte. R09 was reconstructed locally from 1.06 MB of authenticated
diffs and fixtures. Its ten selected Encoder tests passed. The codec command
needed an explicit `blob encoder root imports data-only presentation codecs`
filter to discover its tests. All three codec tests passed after an independently
reviewed test-only correction: include the existing trailing extension byte
and corrupt the marker-weight and layout bytes independently. Production
encoding and decoding were unchanged. The original failures remain recorded.

R09 source, manifests and Encoder receipts are under `.tmp/r09-local/`.
The codec repair patch, compressed postimage and passing receipts are under
`.tmp/r09-codec-repair/`; its redundant source copy was retired after cleanup.
The combined local validation summary is `.tmp/local-build/qualification.json`.
These are selected checks, not full R09 or corpus acceptance. No new edition
was counted as complete, and the remaining Tools/Writer and application
qualification still need their original inputs and separate verification.

Keep this setup and its active cache while local consumers remain. Detailed
environment metadata and validation receipts are in `.tmp/local-environment.json`
and `.tmp/local-build/`. The reconciled RD job records and selected original
inputs are in `.tmp/rd-reconciliation.md` and `.tmp/rd-originals/`. These local
files are intentionally excluded from Git; the original RD corpus is retained.

### Continuing original-source qualification

The completion target remains all 198 original editions and faithful rendering
on the supported clients. The current generated inventory is still 185/198;
scoped Writer or UI passes do not close a whole edition. The nine-seat RD/DC
review council remains active with whole-task completion open. Its current
receipts and owners are recorded in `.tmp/completion-council/parent-live.json`.

R17's original Hungarian Writer, reference comparison and codec passed and
exported a fresh member with SHA-256
`83a15b666db909aa3a95d5f443e6bef72c1fe61b9dc7be233833c2d677f1a33d`.
The local browser imported that member and verified one accessible `Tmax`
action, its subscript and clipped explanation, horizontal pan and one Enter
lookup in each combination of light/dark and 340/1100-pixel widths. The old
two-action member remains a negative control. Full Hungarian table fidelity
and whole-edition qualification remain separate. The original Chinese action
repair also passed a fresh Writer/readback and browser action comparison.

R18's complete Kurdish table method reached its 4 GiB sampled PSS limit after
520.739 seconds, with child cleanup confirmed. Its source and runtime pins
remained unchanged. A separate finite probe of the same executable measured
eight completed calls to each of two functions at the first table-cell loop.
Nested-font queries retained 516,096–520,192 bytes per sampled call, while text
resolution retained 16,384–20,480 bytes. These are resident PSS deltas, not
allocation totals or transient peaks. The probe deliberately stopped its own
child after the sample budget and is not a passing full-method result.

The earlier focus-scratch repair has an independent sensitivity check. The
same corrected helper passes on the repaired source, while the old production
function returns typed `OutOfMemory` on its initial query inside the exact
2 MiB scratch bound. The old-function control used a smaller selected test
executable, so its process timing and PSS are not a matched performance ratio.
Keep the closed receipts under `.tmp/r14-ku-old-control/` and the finite probe
under `.tmp/completion-council/KU-performance/r18-owned-query-probe/`.

The independently joined native scan checkpoint covers 103 of the 185 generated
seals, with 400,101 attempted layouts and 306 refusals on the original runtime.
Private repair results have their own runtime identities and must not be mixed
into those seal receipts. Repeated browser checks also exposed intermittent
history loss after a cold reopen; earlier intermittent passes do not close it.
The latest six-case Android device run passed one case, retained five failures,
verified the protected dictionary/preferences bytes and restored the prior
foreground application. These findings keep application acceptance open.

The local candidate R19 combines reviewed Malagasy/Thai source-custody
repairs, a responsive-layout format extension and the Babua mutation-test
correction. Its 3,194-file manifest is
`915c8c39ca3b9f73d5b95d1934409749ed7562389f240621217e865dfcd1ef44`.
Its six Encoder and six codec checks passed. The separately compiled Tools
methods passed the full indexed Babua case, its adjacent-sibling control and
the original Hungarian Writer. Hungarian output remained byte-identical to
R17. Three other methods failed with clean process closure: Malagasy reached
an inline-box refusal in the deliberately withdrawn table-capability arm,
before the authentic arm ran; Thai reached a later geometry predicate on its
original nowrap element; Kurdish custody retained the ancestor-margin failure.
Keep these distinct from whole-edition results. The next Malagasy test runs
the authentic arm first while preserving both arms' assertions.

The ordinary R17 Babua pipeline also completed on RD: one authentic indexed
page, raw and compressed verification, and Buginese CLI readback. Its 1,244-byte
compressed member has SHA-256
`e9526f59d879ef4a5eb3268ca21f99b5ff7b70ff9706f6aa9ca8f0d91e8639e8`.
The source and all 34 original input roles remained unchanged. This does not
close rendering. The same original inputs are now staged locally for an R19
ordinary Writer/Verify/Reader run after the current native job closes.

The R20b cell-font scratch candidate compiled successfully. Its original
allocator control returned typed `OutOfMemory` at the first positive phase
under the 2 MiB fixture bound. The candidate completed 64 initial queries using
1,154,698 backing bytes, then failed the next retained-owner comparison. The
existing comparison uses pointer identity for non-byte slices, including
independently cloned named-font lists; a narrow value-comparison repair is
under review. Neither this failure nor compilation success qualifies the
memory change. The unchanged complete Kurdish original method has its own
4 GiB guard and result under `.tmp/r20b-local/`.

Closed source snapshots share identical files only when path, content, size
and mode agree. Their before/after manifests remain unchanged, and unique
failures and artifacts remain available. Any later edit must replace the inode
before writing or changing permissions. Clean-cache advice on closed files
resolved local compile admission pressure without changing limits or deleting
artifacts; admission-only refusals remain recorded separately from executed
compiles.

These candidates are not integrated production source. The new
responsive capability uses DPRa global bit 24. The earlier bit-21 proposal was
withdrawn because Android already uses bits 21 and 22 for bottom alignment.
Reserved bit 23 remains rejected. Preserve the allocation and legacy-format
controls when combining the client candidates. No release is published.
