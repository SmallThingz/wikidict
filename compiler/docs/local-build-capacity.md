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

Local setup validation passed all six CLI build steps, all 20 compiler-tool
build steps, and 104 disk/memory-control tests. The CLI searched and exported
all three records of the retained Abkhaz output. The cold Writer compilation
took about six minutes with a reported 3 GiB maximum RSS; that measures tool
preparation, not the peak requirement or duration of a complete edition.

The pushed source rejects the newer private R08 Babua record with
`InvalidPresentation`. That failure is retained separately from the pending
R09 matching-source qualification. It does not change the corpus completion
count. The R09 source was reconstructed locally from 1.06 MB of authenticated
diffs and fixtures; its composition, source manifest, commands and individual
qualification receipts are under `.tmp/r09-local/`.

Keep this setup and its active cache while local consumers remain. Detailed
environment metadata and validation receipts are in `.tmp/local-environment.json`
and `.tmp/local-build/`. The reconciled RD job records and selected original
inputs are in `.tmp/rd-reconciliation.md` and `.tmp/rd-originals/`. These local
files are intentionally excluded from Git; the original RD corpus is retained.
