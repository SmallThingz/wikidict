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
