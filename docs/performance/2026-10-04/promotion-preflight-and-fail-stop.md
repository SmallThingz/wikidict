# Promotion preflight and operational fail-stop

Module-template preflight now validates changed module globals as well as
exports, including allocated sparse-tail pages, before copying into persistent
storage. It mirrors the clone's unchanged-root and `_G` exclusions and binds
environment aliases only when the destination can bind them. Ordinary promotion
also preflights exports and override graphs. Native metatable checks now use the
same ordering as cloning.

Regression tests repeat rejected dense and sparse global graphs 64 times and
verify zero target-arena growth/publication. A supported control verifies that
unchanged nonportable root values are skipped and environment/export/global
aliases remain consistent. Existing sparse nil-tombstone coverage still passes.

Promotion is not generally transactional yet. An out-of-band, process-lifetime
OOM flag now survives caught/flattened errors from ordinary or upstream
promotion, including failures in override handling. The worker checks both the
successful and erroneous expansion paths before writing a reply. It emits an
operational OutOfMemory response and stops; it does not reuse partially changed
persistent state or silently accept the page. This is fail-stop containment,
not rollback and not a claim that all persistent allocation growth is fixed.

EOF diagnostics now attempt bounded child-status capture before resetting the
worker, recording PID, page ordinal, title and termination status when available.
A child that closes stdout without exiting is never waited on indefinitely.

Validation: all 124 focused core tests passed; full `zig build test` passed
(50/50 steps); full `zig build test-bundle` passed (13/13 steps, 24 integration
checks). The closed-worker fixture recorded the actual exit status 7. Both
ordinary and upstream swallowed promotion OOM retain the fatal signal.

Fresh native corpus emission retained byte-identical program metadata and an
exact matching imported value leaf. Matched runtime measurements are separate
and pending; this correctness fix makes no speed claim.
