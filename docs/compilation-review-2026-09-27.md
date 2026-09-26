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

## Allocator counted follow-up

Allocator follow-up measurements support retaining the change provisionally on the measured page windows. The observational C25-control ABBA comparisons had lower worker CPU in both matched pairs of both windows. Ordinary mean worker CPU was 44.55575 -> 41.48450 seconds (ratio 0.931069, -6.89%; paired ratios 0.902444/0.961746). Hard mean worker CPU was 66.38195 -> 65.22121 seconds (ratio 0.982514, -1.75%; paired ratios 0.997032/0.968066). The near-neutral first hard pair limits confidence in the small gain. Machine-wide load was observed, so these are measured-window prioritization evidence, without an isolated performance claim.

The separate eight-worker counted follow-up passed exact parity for 100,000 selected pages: 73,386 main pages, 74,848 language records, 1,620 fallback pages, all 524 nonfallback files, the fallback multiset, and blob verification. Native wall time was 192.161 seconds (520.397 selected pages/s), worker CPU 1,340.50864 seconds and joined process CPU 1,362.802 seconds. Complete bounded run time was 215.38 seconds, peak joined PSS 3,808,806,912 bytes and 23 tasks. Historical C24 measured 189.05 seconds / 528.96 pages/s on this workload; that unpaired run was faster in wall time. Different host pressure and the older C24 control prevent attributing either difference to the allocator. No counted throughput improvement over C25 has been demonstrated.

The counted native stage recorded machine-wide major-fault/swap deltas {'pgmajfault': 118615, 'pswpin': 23811, 'pswpout': 32111}; PSI total stall deltas remain in the raw receipt. These machine-wide counters include other host work. The result does not meet 2,000 pages/s or qualify whole-English completion.

Receipts:

- `allocator-observational-r1/qualification.json` SHA-256 `0a41ef1e1a734814f36689ee45b5320c14718a88bf0417ed23c1a83694d82142`.
- `allocator-counted-r2/qualification.json` SHA-256 `03dc9156ffdb00d9a588bbf90ab648fba183259790faa81ac24b2a99e6aee99e`.
- `allocator-counted-r2/watchdog.json` SHA-256 `16144ae9efcf61231ecc63c5b94f9f18de8ff698ef93024a90fa9cdf8f87ccc4`.
- `allocator-counted-r2/result.json` SHA-256 `075a780a9525461e26ded81c1ecf5615bb516c0f14a7c8e46f0bb5274f73a0a6`.

The allocator-only patch also passed the full test graph on a plain snapshot of clean `bc3dc03` plus only its five owned files (224.20 s). This establishes independent test coverage for the allocator commit; the native parity and timing measurements above used C25 plus the allocator. The staged allocator core was verified against this snapshot, and the remaining live core changes were verified to be the original C25 work. Receipt: `.tmp/allocator-isolated-head-20260927/gate-r1/allocator-isolated-qualified.json`, SHA-256 `135b473f7f6599287f3abd0dd5b3cd9e2ad17ffae6525a097c4afc137c145e93`.

## Rejected pattern token prototype

The scratch pattern-byte-program E candidate is rejected. Its first timing controller compared a one-iteration preflight checksum with 3,000 timed iterations and exited unsuccessfully. The separate G offline audit recovered four successful guarded samples: 48 rows and 12 exact same-iteration semantic pairs. Independent raw-log review confirmed that every candidate/control CPU ratio exceeded one, ranging from 1.047602 to 1.272888 (4.76–27.29% slower). This synthetic pattern evidence does not establish corpus performance. No retry was launched and no pattern changes were retained.

Receipt: `.tmp/runtime-optimization-20260926/pattern-byte-program-g-offline/qualified.json`, SHA-256 `0ff841a011f28ee78b68f5171f2751aa6ff4fc692c59bbece1154e5d94f4ea60`. The unchanged runtime pattern source SHA-256 is `ca105d341a1187e1c6f594daadc291507d81b7a2013b6c93263653f07ee85c13`.

## Combined compiler stack qualification

The current stack combines guarded numeric continuations/loops and deferred numeric SSA, prehashed stores, structural fixed-call specialization, guarded scalar `string.find` results, and an imported positive shape-slot lookup. Dynamic operations retain their existing fallback, including arbitrary metamethod results. The leaf importer now requires the shape-cache TLS declaration and rejects an unexpected mutable field-cache declaration; mutable map-cache lookup stays in the runtime.

The repaired full graph passed, as did linked find/fixed-call fixtures and parser IR checks. The final shape checker initially rejected a valid LLVM exported alias. A separate, pinned recovery resolved aliases, reran fixture comparisons and mechanism checks, and authenticated all preceding successful phases without rebuilding or weakening product semantics. The full-graph receipt is `.tmp/combined-stack-native-20260927/recovery-r1/full-graph-qualified.json`, SHA-256 `b2b6043795e7e09efdaa56ae79d89fa1865e7f2554a8a2fb71e2519b6c218e06`.

Real English native compilation took 518.25 seconds and 1,811.46 child CPU seconds, reusing 1/118 objects and publishing all 118. Exact ordinary and hard 1,000-page parity passed. The complete gate took 555.01 seconds, with peak PSS 2,820,161,536 bytes and 20 tasks. Receipt: `.tmp/combined-stack-native-20260927/native-r1/build-qualified.json`, SHA-256 `89705705c8263533343b4fabfc80d731dd11ddd6701f936d74a02277fdc5ca7d`.

Three separate ABBA comparisons used frozen binaries and exact output checks for every warmup and timed sample. Ratios below are candidate/control worker CPU; values below one favor the combined stack.

| Control | Ordinary mean ratio (matched pairs) | Hard mean ratio (matched pairs) |
| --- | --- | --- |
| C25 plus allocator | 0.996894 (1.012968 / 0.981111) | 0.964070 (0.977374 / 0.951078) |
| Authenticated C23 | 0.997841 (1.024570 / 0.971021) | 0.964096 (0.962673 / 0.965507) |
| Clean committed C23 plus allocator | 0.982032 (0.988660 / 0.975751) | 0.995067 (0.995309 / 0.994824) |

The last control was freshly built from clean committed `233dba6`, excluding the shared uncommitted compiler work, and passed both exact windows independently. These measurements observed host memory reclaim and other activity; none qualifies an isolated gain. The first two ordinary comparisons were mixed. The final comparison favored the candidate in both pairs/windows but only slightly, especially on hard pages. This supports provisional retention and a broader counted follow-up, not a large compiler speedup claim.

Comparison receipts are respectively `allocator-abba-r1/qualification.json` (SHA-256 `8f75da79a34056891c23d1335c34faf55e4d540d86f153fa0ca98223be38248a`) and `c23-abba-r1/qualification.json` (`3136549f98f445ef00471e3b53e1a6f47dfcc73a84b11a71c300111befabae31`) under `.tmp/combined-stack-native-20260927/`, and `.tmp/committed-control-comparison-20260927/abba-r1/qualification.json` (`fc172275648932ce1435d9367ac9dd4ab73c7b31d8237d808de5ee555427aa10`).

## Combined stack counted follow-up

The eight-worker 100,000-page run passed all 524 nonfallback file comparisons, the 1,620-record fallback multiset, and final blob verification. It produced 73,386 main pages and 74,848 language records. Native wall time was **180.300 seconds / 554.631 selected pages/s**, worker CPU 1,292.18424 seconds, and joined process CPU 1,313.924 seconds. The full wrapper took 188.285 seconds, including 0.754 seconds for blob verification; peak aggregate PSS was 3,529,057,280 bytes with 20 tasks. Memory limits used sampled watchdog enforcement, not a kernel hard cap.

This observed rate exceeds the earlier unpaired 520.397 pages/s allocator count, but differing host pressure prevents attributing the difference entirely to source changes. The 2,000 pages/s target and full-English end-to-end goal remain unmet. Receipt: `.tmp/combined-stack-native-20260927/counted-r1/qualification.json`, SHA-256 `37c9236d0fb735700bbd855ec71b4c16d98bc44c4a3ce3b741f04070ee389e92`.
