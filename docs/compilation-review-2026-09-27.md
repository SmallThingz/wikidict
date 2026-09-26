# Compilation qualification review: 2026-09-27

The 2,000 selected rows/second target remains open. Parallel Sol and Astra
reviews inspected the current compiler/runtime changes and retained evidence.
Neither review demonstrated a correctness defect; this is not a correctness
proof or performance acceptance of the uncommitted changes.

## Newer retained measurement

C24 converted 100,000 selected index rows in 189.05 seconds, or **528.96
selected rows/second**, using eight workers. It emitted 74,848 language records
from 73,386 main-namespace pages. Its qualification receipt records exact
agreement for 524 non-fallback files and multiset agreement for 1,620 fallback
records, plus successful blob verification. Worker CPU was 1,357.54 seconds.

This supersedes the latest *observed rate* in the September 26 report, not its
controlled performance conclusions. The C24 ordinary-sample ABBA comparison
against C23 had mean worker CPU of 41.208392 versus 40.939403 seconds: a 0.657%
increase. The difficult window was contaminated and did not qualify. The
unpaired 100,000-row wall times do not establish a C24 speedup. Retaining the
combined compiler changes still requires matched performance evidence.

The C25 demanded-entry build and full ReleaseFast test command have terminal
success receipts. These receipts alone do not pin the current dirty source,
prove corpus parity, or qualify performance. Another active checkout session
was preparing frozen C25 assets during this review; this review did not launch
a competing build or benchmark.

## Next acceptance steps

1. Pin C25 source and frozen builder/worker/input identities. Verify that
   supposedly unchanged corpus inputs match the control.
2. Check ordinary and difficult 1,000-row windows against the established
   semantic identities, including exact coverage and fallback multisets.
3. Run serial paired timing with the existing host-activity rejection guard.
   Report contaminated windows as inconclusive rather than repeating without
   a bound or attributing host variation to the candidate.
4. Only after parity and measured benefit, qualify a counted larger window
   and record total build cost. Preserve the data-only reader boundary and
   blob verification; no deferred invocation is acceptable.

## Architecture opportunity and its limits

`Expander.invokeFresh` creates a child runtime, bootstraps it, installs
Scribunto, and loads modules for each invocation. Program metadata, bootstrap
templates, and loadData graphs already have shared mechanisms. Reusing a live
mutable runtime would change intentional invocation isolation.

A possible next experiment is predecoding already-proven static module root
blobs into immutable relocation data once per Program, then instantiating
fresh mutable objects in each child. `Program.staticModule` currently decodes
these blobs when loading a static root. Any replacement must preserve aliases,
closure-cell sharing, function identity, mutation and errors. Broader module
initialization reuse needs additional page/frame/dependency proofs.

This is a hypothesis, not an accepted optimization. The current difficult
profile distributes self cost across pattern matching, arena allocation,
table lookups and calls. Measure current invocation bootstrap, native root
execution and static decoding separately before choosing the next rewrite.
Removing one small helper cannot plausibly close the remaining 3.78x gap.

## Receipt identities

Paths are relative to `.tmp/runtime-optimization-20260925/`. These identify
the inspected retained evidence; no new timing run was made for this review.

| Receipt | SHA-256 |
| --- | --- |
| `candidate24-native-100k-8cpu-output/qualification.json` | `137b7301ece7af3682cc566eb6db04e33c06cdcd43e330ee3f2d0cddff39566d` |
| `candidate24-c23-timing-once/qualification.json` | `87ae29f8cf85912c65ac4270f36367a76d0b1a7c1df1712afcdca755d03341d4` |
| `candidate25-demanded-native-build/result.json` | `122dcd7ad8286da2acca18e3c4bfd4cdeb45af0559441680ccd0842eba891e87` |
| `candidate25-demanded-tests/result.json` | `39285d035895503464aeff6a87b5be64bbd603ec684fce66a32b589c48c2ffb0` |

## Rejected buffered-call dispatch candidate

The dispatch candidate bypassed generic runtime call wrappers while preserving
argument normalization, error propagation, module scopes, and result ownership.
Full ReleaseFast tests and both 1,000-page native parity windows passed. The
native build reused 118 LLVM objects and compiled none; the worker grew by
37,992 bytes. Extraction ran again because the extractor binary digest changed;
the input, arguments, version, and dynamic-library identities were unchanged.

One bounded C25/candidate ABBA comparison completed on four CPUs. Every warmup
and timed sample matched the pinned ordinary/hard output and coverage checks.
The result is observational: sampled host load and reclaim were recorded rather
than rejected. It does not qualify isolated performance or full-corpus speed.

| Window, 1,000 selected pages per sample | C25 mean worker CPU | Candidate mean worker CPU | Candidate/control | Matched pair ratios |
| --- | ---: | ---: | ---: | --- |
| Ordinary | 46.06176 s | 43.15881 s | 0.936977 | 0.953932, 0.920376 |
| Hard | 64.45718 s | 67.24531 s | 1.043256 | 1.049790, 1.036719 |

Ordinary worker CPU decreased 6.30%, but hard-window worker CPU increased 4.33%
and regressed in both pairs. This mixed result rejects the blanket candidate.
Wall means were 19.2973 to 14.1356 seconds ordinary and 26.4212 to 28.1007 seconds
hard; differing memory/I/O pressure prevents interpreting those as isolated
speedups. Per-sample PSI, major-fault/swap deltas, busy observations, parity,
worker CPU, and joined child CPU are retained in the receipt.

The complete watchdog took 272.582 seconds, with peak sampled aggregate PSS
2,580,826,112 bytes and 13 tasks under the four-CPU, 8 GiB, 900-second envelope.
All supervisor, child, and guardian exits were zero. The watchdog limit is
sampled best effort, rather than a kernel hard aggregate memory cap.

Raw receipt:
`.tmp/c25-continuation-review-20260927/dispatch-observational-r1/qualification.json`
SHA-256 `1dc9152fbc1dcf49531aa3088c5da0baef5f8868c211894da2c4da1009d703c1`.
The result status is `observational_loaded_host`; clean-host, isolated-gain,
and full-corpus qualification are explicitly false.

## Private invocation allocator candidate

The page-local bump allocator passed the complete ReleaseFast test gate (104.91 s), then native compilation and exact 1,000-page ordinary/hard output parity. The native stage took 646.08 s and 2,304.13 child CPU seconds; the complete build plus parity gate took 681.92 s. LLVM reused 63 of 118 native objects and recompiled 55 after the Context layout/helper dependency changed. The watchdog recorded peak joined PSS 2,775,964,672 bytes and 20 tasks under four CPUs, an 8 GiB sampled limit, and a 900 s deadline.

The qualified worker SHA-256 is `4a7cea6cb6ff8487dc0c23f90ed01a7a47a68708715d5725e838ffc42303eefc`; source manifest SHA-256 is `62d09072faea841877c4610aa8d915e171da19d022828117e0983c64dfa8dd1a`. Ordinary semantic output SHA-256 is `d3986988fb84bb1e7bcab03a14877abafea363a443e36c79fafb31896c669901`; hard output SHA-256 is `8f6f87de6c6b70de554b679596b26d1df5cdffc0651a02e6e53d3234ad8272fd`. These gates establish build correctness and those two page windows only. They do not establish an isolated speedup, 2,000 pages/s, or full-corpus completion.

Receipts under `.tmp/c25-continuation-review-20260927/allocator-build-r2/`:

- `build-qualified.json` SHA-256 `d80ef0e6974752a5c02a03373c0d00ca325e642bdbe13775a8dd24749ba20757`.
- `result.json` SHA-256 `5f488485a52eef4bafcf01fde64e8793a5432b8f45e484d696e93935924f81c4`.
- `native-build.json` SHA-256 `a332fcc8de484e1398f6b833e96b8d106ef79f25bf8c0a7c7d26108b9cabbc66`.
- `watchdog.json` SHA-256 `5a360ac85ce6d955ee9aa9bbc699094c36c132a4f22cf20192a7b9ecd777fd13`.

A four-CPU observational ABBA comparison then passed exact output checks in all warmups and timed samples:

| Window | C25 mean worker CPU | Candidate mean worker CPU | Candidate/control | Matched pair ratios |
| --- | ---: | ---: | ---: | --- |
| Ordinary, 1,000 selected pages | 44.55575 s | 41.48450 s | 0.931069 | 0.902444, 0.961746 |
| Hard, 1,000 selected pages | 66.38195 s | 65.22121 s | 0.982514 | 0.997032, 0.968066 |

Both pairs improved worker CPU in each window, but the difficult-window gain is small. Machine-wide pressure and busy observations are recorded; this is loaded-host evidence, not clean-host or isolated-gain qualification. The complete comparison took 237.72 s with peak sampled PSS 2,776,522,752 bytes. A larger 100,000-page semantic count is the next gate; no new counted throughput is claimed here.

Receipt: `.tmp/c25-continuation-review-20260927/allocator-observational-r1/qualification.json`, SHA-256 `0a41ef1e1a734814f36689ee45b5320c14718a88bf0417ed23c1a83694d82142`.
