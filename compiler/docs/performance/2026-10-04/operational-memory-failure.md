# Long-run memory failure and fail-closed transport

The accepted `243d29f` worker did not complete the official first-100k build.
Its first remote `OutOfMemory` was `mond`, ordinal 13586; 182 such replies
preceded `WorkerClosed` at ordinal 27241. The watchdog recorded child exit 1,
6071.149 seconds wall, 19555.027 aggregate child CPU seconds, and peak sampled
aggregate PSS 1,868,952,576 bytes. It did not enforce a memory/deadline kill.
Workers separately cap address-space growth to startup VmSize plus 1 GiB.
The failed worker's actual allocation and exit signal were not recorded.
These partial results are not successful throughput evidence.

A cold single-page replay of ordinal 13586 with the same accepted expander
completed successfully (38.587 seconds total, worker CPU 2.896 seconds).
That excludes an unconditional failure of this page, but does not identify
the history-dependent allocation failure. The replay overlapped correctness
builds and is not a speed comparison.

Remote OutOfMemory and Timeout now preserve operational error identity,
retire the worker and abort blob construction. The fallback classifier also
rejects wrapped operational errors. Publication refuses historical fallback
reports containing direct or staged OutOfMemory/Timeout reasons. Worker OOM
diagnostics include PID, ordinal, stage, VmSize and RLIMIT_AS without heap
allocation. This prevents successful-looking empty pages; it does not yet
prove bounded persistent promotion or solve the long-run allocation failure.

Validation: full `zig build test` passed (50/50 build steps), Python builder
suite passed (72 tests), and `zig build test-bundle` passed (13/13 steps,
23 integration checks). Framed remote OOM coverage verifies worker retirement
and refusal to publish both ordinary output and continuous shards.
