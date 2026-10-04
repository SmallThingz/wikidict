# Compiler/runtime performance qualification

## Final status

All three Wikidict repositories are consolidated on their sole local main
worktrees. The retained compiler/runtime changes pass full unit and bundle tests.
Rejected and inconclusive optimization candidates were not installed.

The performance target remains unmet. The latest first-100k attempt failed
safely at page ordinal 39229 with a worker address-space OOM; a cold replay of
that page succeeds. See [memory ownership and long-history results](independent-template-storage.md).
No whole-Wiktionary under-hour or thousands-of-pages/second result is claimed.

See [request allocation experiments](request-allocation-experiments.md) for
rejected pool/remap changes, and the individual receipts for bounded cache
admission, promotion preflight/fail-stop and receiver-shape measurements.

These measurements use dc-box under concurrent unrelated workloads. Wall-clock
throughput is an observed lower bound, not a clean-host speed claim.

## Retained changes

- Long percent-free Unicode bracket classes are prepared as merged ranges.
- Each compiled Program owns a bounded immutable pattern cache. Cached UTF-8
  keys, decoded codepoints and prepared ranges survive page-arena resets;
  searches retain page-local captures and callback behavior. Allocation failure
  and capacity exhaustion retain the uncached path.
- Pure string concatenations, including proven immutable string locals, fold
  into compiler-owned literals. Mutable/captured/runtime values retain ordinary
  evaluation and errors. Embedded NUL and non-UTF8 bytes remain length-delimited.
- Explicit expansion response deadlines are configurable. Operational timeouts
  fail the build instead of becoming successful empty pages.

## Matched 10,000-page cache comparison

Four page workers, four P-core logical CPUs, fixed time input, identical frozen
corpus inputs and output parity, fold/cache/cache/fold order:

| Variant | Seconds | Pages/second | Instructions | Cycles |
| --- | ---: | ---: | ---: | ---: |
| Fold baseline 1 | 51.39 | 194.58 | 548,152,621,487 | 391,401,864,737 |
| Pattern cache 1 | 47.65 | 209.86 | 514,464,713,638 | 350,918,365,766 |
| Pattern cache 2 | 40.36 | 247.78 | 515,736,434,470 | 342,231,941,733 |
| Fold baseline 2 | 47.29 | 211.46 | 547,833,300,253 | 395,108,949,617 |

The cache removes approximately 6% of instructions in both adjacent comparisons.
All four runs produced identical output, allowing only fallback-record ordering.
The first cache run retained roughly 249–254 KB per worker, served 213,354 hits,
and had no cache allocation failures. Capacity saturation fell back safely.

The separate compiler and 36-page head-window cohorts are retained as JSON.
Constant folding makes little difference to retired instructions in those
windows; their wall/cycle differences must not be attributed solely to folding.
The tiny head window contains unusually expensive multilingual entries and is
not a representative whole-dump throughput estimate.

## Native ABI provenance

Every variant was rebuilt using its matching emitted Value-leaf bitcode. Adding
a Context field changes auto-layout and therefore requires rebuilding affected
native batches. Earlier runtime-only relinks against old Clang 22/old-layout
objects are invalid performance comparisons and are superseded by these cohorts.
Current comparisons use Clang 23, fixed batch-plan order and matching runtime
objects. JSON receipts preserve binary hashes, counters, commands and resource
guard results, even when historical temporary paths are subsequently cleaned.

The cache comparison covers an interior 10,000-row window. It does not establish
the first-100,000-row acceptance result, complete semantic coverage with missing
auxiliary datasets, or compilation of all Wiktionary editions in under an hour.
