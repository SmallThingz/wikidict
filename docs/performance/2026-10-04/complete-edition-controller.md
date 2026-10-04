# Complete-edition controller checks

Complete inventory discovery returned198 editions,1411 pinned dump files and
11,701,957,952 compressed bytes without discovery failures. This is acquisition
inventory, not successful compilation. Per-edition namespace semantics and
auxiliary data still require validation before claiming complete dictionaries.

The controller now rejects incomplete discovery, declared-but-missing editions,
undeclared editions and empty selections. An explicit requested subset may omit
unrelated failed editions; downloader resume actually filters that subset rather
than downloading the entire saved manifest. New plans retain the requested
edition inventory. New acquisition plans include page-table SQL required for
CategoryTree generation; older plans need separately acquired matching-date
page tables and are not silently upgraded during a live download.

`--now-unix` pins one validated positive64-bit timestamp through both small and
sharded builds. The native pipeline forwards it to page workers. A timestamp
change invalidates compiled shard state while preserving verified compressed
input staging. Published metadata records the timestamp, and explicit reuse
rejects differently timed or unrecorded old output. Completed-output reuse
remains labelled `existing_output`, not a new qualification pass.

Validation:95 Python downloader/controller tests passed, including explicit
subset/discovery failures, timestamp forwarding, published time, shard reuse,
and invalidation. Native pipeline option tests also passed through
`zig build test-bundle-pipeline`. Full-suite final validation is separately
recorded after the current runtime experiments finish.
