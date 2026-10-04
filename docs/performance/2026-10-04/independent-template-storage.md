# Independent persistent template storage

The earlier instrumented first-100k attempt failed at ordinal 6685, title `ю`,
with OutOfMemory. Its affected worker reported outer arena capacity 766,644,032
bytes, template capacity 123,333,746 and string arena capacity 31,142,716.
Outer reserved capacity had grown roughly 460 MB while template capacity grew
roughly 61 MB. These capacities overlap and must not be summed. Nested geometric
arenas amplified retained virtual-address reservations. The operational guard
correctly aborted this attempt rather than publishing OOM fallback records.

The persistent template now backs its arena buffers directly with smp_allocator,
keeping only its small descriptors in the program allocator. Its strings use
that context arena from initialization, before bootstrap. Page and invocation
allocation policies are unchanged. Context cleanup also now runs if Scribunto
installation fails after successful base initialization. Destruction remains
Context, independent arena, descriptors; no template pointers publish early.

Validation:
- 125 focused runtime tests passed, including large promoted string/cyclic graph,
  captured closure lifetime, independent storage, page isolation and balanced frees.
- Full `zig build test -j2` and `zig build test-bundle -j2` passed; bundle suite
  completed all 24 integration checks.
- 196 persistent-worker replay requests exactly matched saved control responses,
  with no operational errors or failed mappings and worker exit zero.
- Replay outer capacity stayed 307,090,538 bytes as template capacity grew from
  13,023,406 to 35,562,388 bytes; nested string capacity stayed zero. This confirms
  removal of the nested reserve amplification. It does not prove bounded total
  persistent memory or lower total VmSize on every working set.
- Metadata and imported value-leaf bytes match control exactly; fresh normal and
  diagnostic runtime workers used the existing qualified native corpus objects.

Matched dirty-host ABBA results are recorded in independent-template-cohorts.json.
Both artifact guards, output parity, child exits and unscaled counters passed.
rep10k CPU: control 128.77 / 118.80 s, candidate 111.77 / 138.06 s.
head36 CPU: control 168.20 / 149.08 s, candidate 161.50 / 160.20 s.
These mixed timings establish no speed gain. Retention is an ownership/memory
correctness correction, not a claim of thousands of pages per second.

A new first-100k diagnostic qualification, with unchanged per-worker headroom,
was started after these gates. Its outcome is recorded separately; this receipt
does not claim that the long history completed or the full corpus fits in an hour.

## Long-history outcome

The new attempt also failed, safely, on OutOfMemory at ordinal 39229 (`ala`),
after 6,315.94 wall seconds / 21,764.15 aggregate child CPU seconds. The last
parallel progress line was selected=39300; that is not completed artifact
coverage. The binary guard passed. The 8-GiB watchdog recorded normal child
failure, not an aggregate-memory kill (peak sampled PSS 3,472,593,920 bytes).

At failure the worker's VmSize was 3,430,854,656 bytes against its unchanged
3,435,511,808-byte address-space limit. Outer arena capacity remained
307,090,538 bytes, template capacity was 192,134,234, and nested string capacity
zero. Thus this correction removed the observed outer-arena amplification but
did not bound total retained address space. Remaining persistent graph growth
and allocator high-water retention still need separate investigation.

A fresh-worker `ala` replay succeeded in 36.33 seconds with no operational error.
This supports a worker-history/resource issue rather than unavoidable failure
of that page. Its one-response digest is not an independent semantic oracle.

The official first-100k qualification is FAILED, not partial success. No result
from this failed build is published. Neither thousands of pages/second nor an
under-hour whole-Wiktionary build has been established. Exact results and memory
telemetry are preserved in independent-template-long-history.json.
