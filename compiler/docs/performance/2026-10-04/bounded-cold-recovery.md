# Bounded cold recovery after remote worker OOM

Only a fully decoded remote OutOfMemory response authorizes one replacement
worker. The failed child is killed/reaped before replacement; the exact root,
dump, pinned timestamp, ordinal, title and source are resent. Both attempts
share the original response budget. The existing blocking request-pipe write
is still protected by the outer build watchdog, rather than a strict pipe-write
deadline; this limitation is not hidden by calling it an end-to-end deadline.

Recovery accepts only a complete valid output frame. A second remote OOM stays
OutOfMemory. Every other cold error, timeout, EOF, malformed/truncated response,
local allocation failure or skip becomes fatal ColdRetryFailed. None can take
the semantic fallback route. Ordinary first-attempt semantic errors retain their
existing behavior. Parent allocation/decode failure now also retires its child.
Both worker-side promotion-OOM checks remain before success publication.

The caller consumes one returned output, so failed attempts create no dictionary
record. Attempt/recovered/failed counters and bounded ordinal/generation/hash
logs are distinct from page coverage and fallback counts. Request storage is
not reset between attempts; it owns the exact input and diagnostic slices.

This accepts a valid fresh page execution, not a claim of universal byte-identical
warm/cold timing. os.time/date are pinned and random state is page-local, but
os.clock exposes process CPU time. A bounded read-only scan of 60,606 English
modules found six direct references in Uzbek timing/test helpers; inspected
uses log diagnostics, with timing values also stored on one exports table.
Computed accesses and all downstream uses are not thereby proven absent.

Validation: focused parent tests passed; full native bundle integration passed
13/13 steps and 30 integration checks. The added cases cover identical resent
frames, distinct processes, exact body/display title, healthy subsequent pages,
OOM/semantic/skip/malformed/truncated/EOF/timeout outcomes, local allocation
failure on either attempt, no extra retries, and valid recovered publication
without fallback text. Existing permanent-OOM coverage/shard refusals remain.
Long-history and complete-edition qualification remain separate active work.
