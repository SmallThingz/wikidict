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
