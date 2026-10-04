# Request allocation experiments

Neither candidate is retained. Full source, test logs, replay telemetry and build
scripts were checksum-verified in compact local recovery archives before their
reproducible binaries and temporary output trees were removed.

## Per-request size-class pool: rejected

Eight focused tests passed. Both ABBA artifact guards and all source/resume
guards passed. Measured children exited zero; exact parity passed for head36
(273 files) and rep10k (211 files), ignoring only fallback-record order, not
multiplicity. Hardware counters were 100% scheduled. Native toolchain, metadata
and imported value-leaf bytes were matched.

rep10k aggregate child CPU was 126.803–133.979 s versus control 102.380–110.811 s:
paired regressions 20.91% and 23.85%. Combined CPU regressed 22.32% and wall time
29.89%, despite instructions decreasing 0.38%. head36 favored the pool,
138.624–160.502 s versus 182.407–186.789 s; this does not excuse the ordinary
workload regression. These are dirty-host observations, not isolated timings.

The fixed-set replay completed 196 requests with exact control response hashes,
zero failures, worker/controller exit zero and no failed mappings. Post-page
VmSize at requests 64/192 was 2,381,340,672 / 2,427,539,456 bytes versus control
2,531,672,064 / 2,594,058,240. This demonstrates reduced retained address space
for that fixed set, not bounded memory across first-100k histories. Per-request
slab unmapping also increases system CPU and fault cost.

## In-place RequestAllocator remap: inconclusive

Eleven focused tests passed. Both artifact guards, source guard, child exits,
exact parity and unscaled counter checks passed. Production backing remained
smp; this variant did not include the pool.

rep10k CPU was 99.252–111.196 s versus 111.660–111.662 s. head36 was inconsistent:
124.376–166.216 s versus 145.352–151.814 s, paired -18.07% / +14.35%. Instructions
slightly increased. Dirty-host variation does not establish a reliable gain.
No independent long-history memory qualification was performed for this variant.

Full matched measurements and hashes are in request-pool-not-retained.json and
request-remap-not-retained.json. No rejected runtime implementation is installed
in main.
