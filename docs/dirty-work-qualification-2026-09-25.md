# Dirty-work review and English qualification — 2026-09-25

## Result

The reviewed source changes are committed on the live `main` checkout. All seven
detached Wikidict worktrees were removed after their history and local files were
reviewed and preserved where necessary. The live checkout remains in place.

**A complete English build in under one hour has not been demonstrated.** The
current source has focused correctness coverage and earlier guarded synthetic
performance evidence. Neither is an end-to-end English measurement. Fresh full
test-graph execution and linked native-worker startup remain acceptance gates.

## Integrated changes

| Commit | Result |
|---|---|
| `b107286` | Preserve edition-specific link trails; reject unsupported or invalid Unicode patterns rather than silently interpreting them. |
| `8be7bc9` | Index table shapes by module instead of repeatedly searching the complete registry. |
| `122c29d` | Preserve the live checkout's design references under `docs/assets/` and ignore generated Python caches. |
| `c464cc1` | Correct link and heading recovery, propagate link trails, and avoid repeated URL suffix scans across iterator spans. |
| `32a7d77` | Seek directly to each shard's verified index offset, verify complete input coverage, bound per-edition workers, release finished compiler scratch, and repair snapshot path ownership. |
| `6d0c1c9` | Index native global names without changing their slots; add global-index and ABI coverage to the serialized test graph. |
| `4dbc57b` | Escape bare and mixed-case Matrix and Wikipedia protocols in nowiki text. |

Previously integrated `6e0cc5d` selects O0 for modules with zero recorded page
and module reach, with O1/O2 for known uses. Dynamic module targets make that
classification a heuristic. Its effect on compilation plus full English
expansion is still unmeasured. Compilation/execution overlap has no accepted
performance measurement in this checkpoint.

## Actual count and the time target

A bounded, read-only scan of the retained English page index counted
**11,132,552 rows** in **1,073,455,299 bytes**. The title-index header independently
agreed with both the row count and source byte length. The page-index SHA-256 is:

```text
4f87c509eb6cdcfe0f150a2ce9c8a80340cb8d708fc0acd0d3dbc0cc6ff4e2a2
```

For 100,000-page shards, the scan produced 112 starting offsets. Their sum is
**59,517,635,910 bytes**: the logical preceding index text that repeated scans from
the beginning would traverse. Direct shard seeks remove that repeated traversal.
This is not a measurement of physical SSD traffic, saved write bytes, or elapsed
pipeline time.

At that historical count, under one hour requires an average above
**3,092.38 input pages/s over the entire build**, including native compilation,
expansion, encoding, merge, compression, validation, and publication. A requested
10,000 pages/s expansion rate alone would process those rows in about 18.55
minutes; it would leave the other phases unaccounted for.

The retained workspace is incomplete, and the verified original dump is absent.
The historical index count therefore does not certify completeness against a
fresh source dump. The count scan's elapsed time is not an accepted performance
comparison: its launch-memory check had a shell parsing defect, although the
fixed process/time limits were applied and the child exited successfully. Its
row count, checksum, and header cross-check are retained as inspection evidence.

The production controller now compares the complete index count with the
independent repacker `source_pages` count. Legacy caches without a valid source
count are repacked. Shard receipts record the actual selected count, requested
range, byte offset, and index identity. Publication requires total coverage to
match the expected input. Existing-output and resumed-publication timing labels
keep those paths distinguishable from a new pipeline run. These checks establish
coverage, not semantic perfection or a runtime guarantee.

## Current validation

These are focused results on the reviewed sources, not counts to sum into a
single disjoint suite. Document IR tests also appear in the encoder suite.

| Scope | Result |
|---|---|
| Python build controller | 44 passed, including independent input counts, receipts, cache invalidation, publication, and small compression cases. |
| Python downloader | 13 passed. |
| Native language registry | 6 passed. |
| Module shape registry | 7 passed. |
| Global-name index helper | 5 passed, including allocation failures. |
| Indexed-global core regression | 1 passed: aliases, iteration, and context isolation. |
| Document IR | 23 passed. |
| Encoder | 97 passed, including semantic round trips and recovery. |
| Native bundle consumer | 7 passed. |
| Blob-build helpers | 3 passed. |
| Full blob-build main | Semantic compilation passed with binary emission disabled; no linked execution. |
| Protocol helper | 1 passed. |
| Live MediaWiki oracle | 12 of 12 cases passed, including structural heading levels. |

The oracle exposed an asymmetric-heading mismatch during review. The compiler
now uses the smaller delimiter count, capped at six, while retaining extra equals
signs in the title. The checker suppresses edit-section controls and compares
heading levels as well as visible text. Raw HTML anchor recovery remains
explicitly reported; these cases do not establish universal MediaWiki parity.

Small native diagnostics ran serially with one CPU, low priority, finite CPU and
wall deadlines, and address-space/data/file-descriptor/output limits. The indexed
core and protocol helper used the non-LLVM backend without libc. Broader fresh
Scribunto/native integration did not complete within the available resource and
linker constraints. Earlier full-graph success is historical evidence only.

## Resource and input blockers

At the final recorded resource check, `safe_worker_budget()` returned **0**.
Available memory was **1,856,500 kB**, below the builder's 2 GiB reserve. Twelve
CPUs were in the affinity set, but additional CPU availability does not override
the memory gate.

The enclosing cgroup exposes CPU, memory, and PID controllers but has no writable
delegated subtree. The private aggregate build envelope therefore cannot be
established. No active Wikidict build, Zig, xz, or bzip2 worker was found by the
bounded process scan. No new corpus build was launched.

The verified raw English dump directory and completed English output are absent.
The retained `.building` workspace is not treated as a current completed build.
Both safe resource admission and verified inputs are prerequisites for a full
measurement; waiting for memory alone would not resolve the cgroup requirement.

A fresh, bounded metadata-only plan is ready in `data/dumps-en-20260901/`.
Its 15 unique files (nine XML parts and six SQL companions) total 3,362,510,164
bytes. Every filename, size, SHA1, and URL matches the retained official
2026-09-01 dump status; the plan has no failures. No corpus files were downloaded.
The manifest SHA-256 is:

```text
2d746c0869c30364835a09c95e1225471408f7b04530c7a1dd2e1aa4ad03c703
```

The input restoration command, to run with appropriate process and time limits,
is `python3 tools/download_wiktionaries.py --out data/dumps-en-20260901 --resume --connections 1`.
Restoring inputs does not waive the separate corpus-build resource gate.

## Worktree cleanup and evidence

The removed worktrees were `1c87`, `75f0`, `d3ac`, `ec20`, `f4e0`, `f68e`, and
`fa7a`. None contained unmerged unique code: six were ancestry-contained, and the
two ancestry-unique commits in `d3ac` had patch-equivalent changes on main.
Recovery refs preserve their exact former heads under `refs/recovery/worktrees/`.

The local recovery directory `data/worktree-recovery/20260925/` preserves 45
distinct design files totaling **20,595,475 bytes**, with source/destination
hashes verified before removal and again afterward. Its manifest SHA-256 is:

```text
91aec726269d9e944d01bc013cb944d77206c66eb3f248f9642e6e71a8e34501
```

Reproducible detached build/cache outputs were removed. The live English data
was retained. Recovery assets are local ignored data, not pushed Git content.

Detailed current logs, commands, source fingerprints, and resource checks are
under `.tmp/dirty-review-20260925/`. The count inspection is
`.tmp/compile-perf-20260925/en-index-inspect-20260925.log`; the current oracle
report is `.tmp/pipeline-mediawiki-recovery-20260925-fixed.json`. Required audit
evidence remains available for the pending full qualification.

The [compilation performance report](compilation-performance-2026-09-25.md)
records the earlier guarded comparisons, including both gains and regressions.
The next accepted whole-English result must preserve the exact source and input
identities, successful child exits, complete coverage, the total wall time, and
the enforced resource envelope. Until that run completes, the one-hour target
remains an open requirement.
