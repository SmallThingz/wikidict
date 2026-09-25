# Compilation and runtime performance checkpoint — 2026-09-25

## Outcome and scope

Guarded synthetic comparisons demonstrate lower module-registry lookup cost,
faster indexed global-name access, and substantially cheaper sparse module setup.
They do **not** establish a faster complete English dictionary build.

The requested **10,000 pages/s** and **under one hour for whole English** remain
unmeasured on the current changes. No end-to-end speed is inferred from these
microbenchmarks, existing artifact timestamps, or compiler-only observations.

The corpus admission budget is currently zero and the host has no delegated
writable cgroup subtree. Corpus and heavy native-worker builds remain blocked.
Earlier guarded measurements do not qualify pending source or waive containment.

This report preserves accepted results and their limits. The fuller working
record remains at [.tmp/compile-perf-20260925/EVIDENCE-DRAFT.md](../.tmp/compile-perf-20260925/EVIDENCE-DRAFT.md).
All artifact paths below are relative to the repository.

## Change status

| Change | Status at this checkpoint |
|---|---|
| Repacked-input cache scope | Landed: `3b0037c perf(build): retain repacked input across source changes` |
| ABI test ownership cleanup | Landed: `648f694 test(lua): free the decoded table in ABI coverage` |
| Module-chain registry indexing | Live, uncommitted candidate |
| Sorted global-name index | Live, uncommitted candidate |
| Build-graph coverage changes | Live, uncommitted candidate |
| Sparse globals v1 | Scratch only; rejected for dense-tail regression |
| Adaptive sparse globals v2 | Scratch only; accepted focused tests and guarded synthetic comparisons; production patch unapplied |
| Large shape-field v1 and v2 | Scratch only; rejected for small-field regression |
| Large shape-field v3 | Untested |
| Rare-module O0 policy | Patch ready; protected consumer requires coordinated ownership before editing |
| Python phase telemetry | Landed: `f67dc9b perf(build): record bounded pipeline phase timings` |

“Landed” records an existing commit; candidates retain their separate status.
ABI cleanup is test ownership repair, not a performance result.
The user permits O0 for very rarely used modules, but permission is not evidence
that a particular classification policy preserves English expansion throughput.

## Validation scope

| Validation | Result and boundary |
|---|---|
| Cache-scope Python tests at `3b0037c` | 30 passed |
| Phase telemetry and controller regression checks | 29 passed under a 128 MiB address-space cap; external child processes forbidden |
| Earlier Python tooling checkpoint | 28 passed |
| Original module-registry focused tests | 7 passed |
| Global-name index helper | 5 passed, including allocation failure |
| Added `test-global-index` build target | 5 passed separately |
| Original Lua core target | 31 passed after correcting a stale layout assertion |
| Full Zig graph | Passed at `a11aa5b` plus then-owned candidates, with unchanged source-set fingerprint |
| Adaptive sparse candidate | Root-verified 38 core tests and 3 ABI tests passed |
| Sparse functional matrix | 16 cases passed, covering 40 paired segment checks |
| Large shape-field candidate | 9 focused tests passed |
| O0 usage selector | 5 focused scratch tests passed; protected consumer unapplied |

The full-graph before/after source-set SHA-256 was:
`57e18be24ec629b5286329fd27bb52355eab62f999eae752911f1c49d9305764`.
That graph lacked the subsequently added helper target and does not certify
later sparse, field, O0, or production integration changes.
A focused test pass is not a full-graph or full-English pass.

The telemetry check selected the 29 controller tests that do not require external
compression, including failed-merge retries, verified cache reuse, empty-edition
publication, admission checks, malformed manifests, and broken log output. All
native commands were mocked and `subprocess.Popen` was forbidden. Five existing
external-compression tests were not rerun in this check. Evidence:
`.tmp/compile-perf-20260925/phase-tests.log` and `phase-tests.exit` (0).

## Measurement method and interpretation

Accepted comparisons use three pairs in AB / BA / AB order and exclude warmups.
Times below are medians. Ratio ranges are the minimum–maximum of the three
within-pair baseline/candidate ratios; ratios above one favor the candidate.
The median ratio need not equal the ratio of median times.
Ranges are observed samples, not confidence intervals or exhaustive bounds.

The root accepted the runs after quiet-host guarding, with durable exit 0.
JSON records preserve matching pre/post binary hashes; newer runners also
record matching runner and frozen-source identities.
These checks apply to the frozen artifacts, not arbitrary later live edits.

Earlier refused, timed-out, or contaminated runs are excluded. In particular,
`shapes-pairs-final.exit = 75` is rejected despite apparent pair success in
its log. The accepted repeat overwrote `shapes-pairs.json`.
No timings from unguarded functional logs are used.

## Module-registry indexing

The harness constructs 115,351 **one-field synthetic shapes** across 60,606
modules, then performs 256 probes and 32 promotions. English metadata totals
supply dimensions; they do not supply the real per-module shape distribution.

| Stage | Baseline median, ms | Candidate median, ms | Paired speedup median (min–max) |
|---|---:|---:|---:|
| Setup | 6.612 | 8.884 | 0.752 (0.721–0.778) |
| Lookup | 14.283 | 0.040551 | 355.290 (300.599–440.001) |
| Promotion | 0.672831 | 0.004496 | 152.773 (104.315–232.572) |
| **Setup + lookup + promotion** | **21.553** | **8.929** | **2.439 (2.335–2.563)** |

Setup becomes 1.329x slower by median paired candidate/baseline ratio.
Lower lookup and promotion costs outweigh that cost in this workload.
The aggregate sums stages within each sample before taking its median.
It excludes teardown; isolated lookup ratios are not whole-compiler speedups.
All shape checksums were 29,588,004.

## Sorted global-name lookup

The comparison uses the **same binary**, toggling `--sorted-globals`.
It uses 2,895 globals and 60,606 logical modules, with 24 native ABI names plus
synthetic padding. Index construction occurs once, outside timed loops.
Each sample runs 1,000 iterations per segment after 32 warmups.

| Segment | Baseline median, microseconds | Sorted median, microseconds | Paired speedup median (min–max) |
|---|---:|---:|---:|
| Page stdlib, init + teardown | 35.709 | 32.483 | 1.120 (0.911–1.179) |
| Fork stdlib, init + teardown | 36.658 | 32.389 | 1.168 (1.089–1.173) |
| Fork + 8 mock requires, init + teardown | 190.284 | 181.495 | 1.034 (1.017–1.070) |
| Fork + 32 mock requires, init + teardown | 628.272 | 618.337 | 1.012 (1.006–1.019) |
| Dynamic globals, three accesses | 19.180 | 0.251 | 76.423 (69.190–79.283) |

The dynamic segment deliberately uses a final-slot hit, miss, and update.
Its large ratio reflects unfavorable linear-search positions, not an observed
English query distribution. Page setup includes a regressing pair.
All paired checksums and allocation counters match. The sorted index adds
11,580 persistent bytes per worker outside per-iteration counters.
No memory reduction is claimed for indexing.

## Sparse v1 rejection and adaptive v2

Dense globals originally copy 2,895 values of 32 bytes: 92,640 bytes per
first-touched module, before table and allocator overhead.
The logical module count does not mean every page touches every module.
Mock modules 0–31 share a module-state page and execute trivial native roots;
they exclude Scribunto, actual Lua work, wikitext, framing, and I/O.

V1 improved the original 32-module setup by a median paired 5.022x, but the
dense case regressed by 1.708x and used 9.1% more peak backing memory.
Adaptive v2 retains sparse storage while avoiding most of that dense penalty.
The v1 and v2 runs are separate comparisons against baseline, not a controlled
direct v1/v2 experiment.

| 32-module case | Baseline median, microseconds | Adaptive median | Adaptive paired speedup (min–max) |
|---|---:|---:|---:|
| Original | 614.614 | 149.424 | 4.132 (3.084–4.398) |
| Sparse: 8 values / 1 page | 610.738 | 178.920 | 3.413 (3.361–3.437) |
| Moderate: 707 values / 12 pages | 610.701 | 394.481 | 1.554 (1.532–1.571) |
| Dense: 2,830 values / 45 pages | 615.143 | 622.184 | 0.991 (0.906–1.001) |

This table uses only the adaptive candidate's matched baseline pairs.
All times are initialization + teardown per iteration. Original samples use
1,000 iterations; explicit occupancy samples use 100 and include occupancy
initialization in setup. Cross-case absolute differences are not isolated
measurements of density effects.

| 32-module case | Baseline peak backing bytes | V1 peak | Adaptive peak | Adaptive backing allocations |
|---|---:|---:|---:|---:|
| Original / sparse | 3,454,974 | 409,152 | 409,152 | 5 -> 2 |
| Moderate | 3,454,974 | 1,432,716 | 1,432,716 | 5 -> 4 |
| Dense | 3,454,974 | 3,769,056 | 3,479,934 | 5 -> 5 |

Adaptive dense peak increases 24,960 bytes (0.72%). Dense eight-module setup
has median paired speedup 0.988x (0.956–0.997), with all pairs slightly slower.
Dense 32-module median slowdown is about 1%; one pair is about 10.4% slower.
The candidate does not establish zero dense overhead.

### Page overhead and semantic boundaries

Adaptive original page init + teardown is 35.902 -> 35.812 microseconds,
paired ratio 1.006x (0.985–1.032). Across the occupancy cases there is no
consistent material page timing regression. Page peak backing memory rises
96 bytes, from 102,408 to 102,504, with 28 backing allocations unchanged.
Original dynamic-global ratio is 0.962x (0.897–1.008); other cases vary around
parity. These samples do not establish a consistent dynamic-access change.

Fresh stdlib/Scribunto bootstrap initializes at most two names beyond the
24-slot ABI: `xpcall` and `os`. Only metadata slots at or above 64 contribute
to the sparse tail. See `stdlib.zig:452–454,1230–1237`, `os.zig:252–259`,
and `scribunto.zig:223–246` under `src/lua/runtime/`.

That is not a lifetime bound. Bootstrap stores the root global table in
`package.loaded._G` (`stdlib.zig:1085–1093`). Module snapshots shallow-copy
`package` while replacing their direct `_G` slot (`core.zig:1026–1047`).
Lua can mutate root metadata-known slots through `package.loaded._G` or
`require("_G")` before another module's first touch (`core.zig:1275–1278`).
Dense root occupancy is possible; its English frequency has not been measured.

Snapshot timing, nil pages, stable native pointers, table iteration, metatables,
OOM cleanup, and shapeless global tables remain correctness requirements.
A renamed native pointer symbol also requires matching regenerated objects/IR.

## Large shape-field candidates

This separate benchmark measures synthetic field collection, not registry
lookup or page expansion. Both attempted variants improve large cases but
regress all three pairs of the eight-field case; neither is accepted.

| Fields x iterations | Baseline v2 median, ms | V2 median, ms | V1 paired speedup | V2 paired speedup (min–max) |
|---|---:|---:|---:|---:|
| 8 x 1,024 | 0.188 | 0.206 | 0.960 | 0.944 (0.888–0.983) |
| 128 x 128 | 0.904 | 0.604 | 1.588 | 1.529 (1.490–1.536) |
| 4,096 x 8 | 38.505 | 2.415 | 17.724 | 15.944 (15.401–17.927) |

V2 eight-field median paired slowdown is about 5.9%, range 1.8–12.6%.
V3 is untested. No corpus-weighted whole-compiler gain is established.

## Compiler policy, overlap, and resource limits

Python orchestration now emits `BUILD_PHASE` JSON start/end records for download
verification, cached-input verification, repacking, expander construction,
page-index counting, shard construction/verification, merge/verification,
publication, and the whole edition. Shard records include start page, requested
page count, and retry attempt. End records carry monotonic elapsed seconds and
success/failure. Existing byte/page/blob counts are included where already known;
telemetry adds no checksum passes or corpus scans. Output failures do not replace
the original build exception.

These are enclosing wall-time phases. `expander_build` still combines extraction,
compiler construction, LLVM emission/optimization, and linking; `shard_build`
combines expansion and encoding. The protected native consumer needs finer
timings to separate those costs. A shard's requested page count is not its emitted
blob-record count. Parent and child phase durations overlap and must not be added
as independent costs. No new corpus measurements are claimed from adding logs.

The small exploratory Clang O0/O1 observations are not a balanced English
qualification. Large-case attempts supplied no accepted end-to-end comparison.
A ready O0 usage-selector patch is not an integrated production policy.
Its protected consumer needs coordinated ownership, correctness validation,
and compilation-plus-expansion measurements before adoption.

Compilation/execution overlap has no accepted performance measurement here.
Retained English artifact timestamps are stage-boundary clues only: they do
not prove current duration, exclude hidden work, or identify the dominant stage.
This report does not repeat unverified static-reach counts or infer page speed.

The repack cache saves repeat decompression/recompression, not hash-validation
reads or disk occupancy. Source-sensitive compiled work must remain separate
from source-independent verified input reuse.
Corpus launches require delegated CPU, memory, and PID controls plus a positive
admission budget. Fake-filesystem tests do not prove kernel subtree enforcement.
Foreign work must not be killed to create benchmark headroom.

## Accepted artifacts and identities

All paths below start with `.tmp/compile-perf-20260925/`.
Preserve each JSON together with the successful wrapper log/exit and frozen
manifest. A stale JSON alone is insufficient evidence of a successful rerun.

| Comparison | JSON | Successful exit artifact |
|---|---|---|
| Module registry | `shapes-pairs.json` | `shapes-pairs-repeat.exit` |
| Sorted globals | `setup-pairs.json` | `setup-pairs.exit` |
| Sparse v1 | `sparse/{original,sparse,moderate,dense}-pairs.json` | `sparse/original-pairs.exit`, `sparse/occupancy-pairs.exit` |
| Adaptive v2 | `sparse-adaptive/{original,sparse,moderate,dense}-pairs.json` | `sparse-adaptive/all-pairs.exit` |
| Field v1 / v2 | `shapes-fields-pairs.json`, `shapes-fields-v2-pairs.json` | corresponding `.exit` files |

| Frozen identity | SHA-256 |
|---|---|
| Original setup harness | `632bf21b209e3577ebf8dfa07b57165c432b6cd93fceade61078b74ced42474d` |
| Sparse baseline manifest | `3e1dea5149cfd1ebc1430b449f3313034657df8840af2e7fae2955159bb95017` |
| Adaptive candidate manifest | `cd0e229d4bc35ad8fb031a40d3186a99b3f0ce6a2aa1e7e93406f3e93fd4a28f` |
| Field v2 frozen source set | `8dee02da1ff320f017e3c79c3ded1c6e8474db09b4ffe7bafa172966dd72fe38` |
| Accepted module-registry JSON | `865ead42e538b99d7214bc22c184fb66f86ffb58f8ff7ed4b0a7abe49d3ac70f` |
| Accepted sorted-global JSON | `f9a18db3d237884168d4f3c059f97878c5de2aea91e9e205f403864092de1297` |

Sparse manifests are `sparse/frozen-sources.sha256` and
`sparse-adaptive/frozen-sources.sha256`, each covering 25 sources.
The JSON embeds per-binary hashes and before/after checks.
Reported family-level maximum child RSS is not per-variant RSS or a
whole-English memory bound. Full timing ranges are in the working evidence draft.

## Remaining acceptance gates

1. Preserve unrelated dirty work, integrate only owned adaptive changes, and
   coordinate ownership of the protected O0 consumer. Record each source identity.
2. Validate the exact integrated source, including the full graph and relevant
   native ABI/emitter paths. Older graph success is not transferable.
3. Keep small-field v1/v2 rejected; measure v3 only after resource admission,
   with small and large cases and unchanged workload checks.
4. Preserve corpus and heavy-build refusal while budget is zero or delegated
   cgroups are unavailable; bound any smaller diagnostic separately.
5. Once admitted, measure actual English worker requests, startup, compilation,
   expansion, I/O, and resource envelopes with functional equivalence.
6. Claim 10,000 pages/s or under-one-hour English only after a complete,
   reproducible end-to-end result demonstrates that target.
