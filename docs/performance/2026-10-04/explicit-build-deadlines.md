# Explicit finite deadlines for complete builds

Watchdog builds still default to two hours. Full-edition qualification can now
set --build-timeout-seconds explicitly, with a positive finite maximum of seven
days. The detached guardian accepts the same bound and the child CPU limit
follows the requested duration. Memory remains at most 8 GiB, task-count and
CPU-affinity limits are unchanged, and no shared cgroup settings are modified.
Cgroup mode rejects the watchdog-only override rather than silently ignoring it.

103 resource/controller tests passed, including normal child completion, rapid
native-child churn, deadline termination/reaping, default routing, explicit
14,400-second forwarding, and rejection of invalid/unbounded deadlines. The
first invocation lacked the test subprocess PYTHONPATH and failed three import
checks; the corrected harness rerun passed. No production resource failure was
reclassified as a successful test.
