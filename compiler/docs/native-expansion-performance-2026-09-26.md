# Native expansion performance: 2026-09-26

## Result and remaining target

The current validated runtime converted **100,000 selected index rows in
245.398 seconds: 407.501 selected pages/second**. This is an observed count,
not a controlled comparison against another version. It does not meet the
2,000 pages/second target, and it does not establish a sub-hour English build.

The English source index contains 11,132,552 selected rows. At 2,000 rows/second,
the page stage alone would take about 92.8 minutes. A complete build under an
hour needs more than 3,092 rows/second, with additional time reserved for
compilation, staging, merging, compression, and publication. Main-namespace
pages, selected rows, and emitted records are different counts; the benchmark
uses selected index rows as its denominator.

## Changes qualified together

The runtime batch reduces boxed-value size, repeated allocation, table lookup,
and host-call overhead. It adds guarded numeric operations, buffered builtins,
prehashed constant field access, guarded field-site and program-shape caches,
and a bounded cache for short table-valued inheritance chains. Cache hits
retain table identity, lifetime, mutation, metatable, and live-value checks;
dynamic cases keep the generic Lua path.

Captured functions allocate their function record, environment, and captured
cell-pointer array together while preserving live-cell sharing. The `#invoke`
boundary requests one result in fixed storage. Generated Lua still evaluates
all return expressions and their side effects. Pattern search skips impossible
starting bytes only when the leading pattern class consumes a required byte;
zero-match substitutions can reuse their immutable input string.

The build controller can keep one bounded expansion pool alive across a
contiguous sequence of shards. Each shard drains before its writer finishes,
checks coverage and source-index identity, and publishes by renaming its
private directory. Resume preserves verified completed shards. Verification
or resource failures do not delete completed output.

The earlier native build cache remains content-addressed by emitted bitcode,
optimization mode, compiler identity, and target options. The frozen English
plan uses 100 O2 modules, 2,790 O1 modules, 3,697 O0 modules, and 54,019 data
modules. No Lua interpreter or generated-Zig Lua backend was introduced.

## Validation

The C23-b qualification passed the Python gate and all 48 steps of the isolated
Zig test graph. Native output matched the frozen controls for both a 1,000-row
ordinary sample and a 1,000-row difficult sample. The English worker build
reused all 118 native Lua objects, with zero Clang batch compilations, and took
68.150 seconds wall time. This is a warm worker build, not a clean end-to-end
build measurement. The entire qualification took 394.762 seconds, including
tests and qualification preparation.

The counted 100,000-row run selected 73,386 main-namespace pages and emitted
74,848 records. All 524 non-fallback output files matched the control exactly;
the 1,620 fallback records matched as a multiset because worker completion
order is not semantic. Native expansion used 1,546.681 seconds of joined CPU,
including 1,521.561 worker CPU seconds. The outer validation run took 252.628
seconds. It excluded compilation, full-corpus staging, final merge,
compression, and publication.

### Controlled timing

An ordinary-sample ABBA comparison against C21 passed all output and
contamination checks. Mean worker CPU decreased from 48.568801 to 44.647124
seconds, an **8.07% reduction**. Mean joined CPU decreased from 49.669760 to
45.669499 seconds. Mean wall time was 14.471765 versus 13.064639 seconds.

The difficult-sample comparison encountered unrelated host CPU activity and
was discarded. There is no accepted difficult-sample speed comparison for
this batch. The observed 100,000-row results below are not paired measurements
and cannot establish relative improvements or regressions:

| Runtime | Selected rows | Native wall seconds | Observed rows/second |
| --- | ---: | ---: | ---: |
| C21 | 100,000 | 200.715 | 498.218 |
| C22 | 100,000 | 270.433 | 369.777 |
| C23 | 100,000 | 245.398 | 407.501 |

## Resource envelope

Native jobs run under a finite-deadline supervisor with an 8 GiB aggregate
sampled proportional-set-size budget, a 256-task ceiling, bounded worker and
compiler concurrency, and an owned-process-group guardian. This is a sampled
watchdog, not a kernel-enforced memory limit. CPU affinity is restricted to
four or eight logical CPUs depending on the job. The eight-CPU selection
leaves four logical SMT siblings outside the job; it does not reserve four
physical cores. Foreign processes are neither suspended nor signalled.

The C23-b qualification peaked at 2,485,213,184 bytes PSS and 22 tasks on four
CPUs. The counted eight-CPU run peaked at 3,464,366,080 bytes PSS and 20 tasks.
These observations are below the configured envelope. Performance comparisons
add a host-activity check and discard contaminated pairs.

## Evidence and provenance

These are SHA-256 identities of local qualification receipts under
`.tmp/runtime-optimization-20260925/`. The source manifest records the exact
tested source contents independently of subsequent Git commits.

| Evidence | Relative path | SHA-256 |
| --- | --- | --- |
| Tested source manifest | `candidate23-runtime-batch-serial-b/source-inputs.json` | `8f9e817aed1fc8cbc6ca960cd62b16c5c47eece5b0830be7707d0d734a2e34dd` |
| Runtime qualification | `candidate23-runtime-batch-serial-b/runtime-batch-qualified.json` | `8c1de7e287aed1da7538abbc79c7bd0669ced31c9ad451ef6acb79e52d79cc5c` |
| Count qualification | `candidate23-runtime-100k-8cpu-output/qualification.json` | `f9398fbfde7664eee91fd16ecdc168e771709241bbbac78eba1786614205b276` |
| Controlled ordinary timing | `candidate23-runtime-timing-c21-once/qualification.json` | `324199703d019b6873be9e98f05f3f54c193534e0f718216789dfbf5e121fcb1` |

The performance target remains open. The next compiler work targets numeric
values across closed loops and direct guarded table operations in generated
native code. Prototype or instruction-count results alone do not qualify as
a measured throughput improvement.
