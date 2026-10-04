# Bounded optional loadData admission

Shared loadData graph admission now limits the backing allocations of each
candidate arena before allocation, including descriptor/chunk overhead and
clone scratch. The ceiling is the smaller of 8 MiB and the remaining 64 MiB
entry-storage budget. Cache maps/metatable storage remain separate metadata;
this is not a total-process or RSS cap.

Failed candidates release their complete arenas. Optional allocation failure
falls back to ordinary page-local loading; non-allocation semantic errors are
preserved. Shared metatable construction is transactional. If it fails before
any shared graph exists, that page stays local even after allocator recovery,
preserving protected metatable identity. Retained candidate arenas detach their
stack-local budget and remain owned by the original reclaiming allocator.

Validation: full `zig build test` passed (50/50 steps), and `zig build test-bundle`
passed (13/13 steps, 23 integration checks). New tests enumerate backing allocator
failures during graph admission, metatable construction and headword seeding;
assert cycle/alias/payload preservation and balanced frees; check sticky local
fallback; and repeatedly reject oversized graphs within the remaining budget,
including an exactly full cache. Standalone allocator tests passed (2 tests).

This fixes definite admission behavior. It is not evidence that loadData was
the source of the long-run worker failure, and no throughput gain is claimed.
