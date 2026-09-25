# Resource safety and performance, 2026-09-25

## Result and scope

The 10,000 pages/s full-build target has **not been reached or measured** in this
pass. These results cover one native dump-decoder operation and warm exact-title
lookup on an existing real dictionary. They do not measure corpus expansion,
blob construction, publication, cold reader startup, or rendered page decoding.

Work was performed in the live `/home/a/zig/wikidict` source checkout, based on
`9838a1bf42db072ad00d6df185a56b12915d4117`. The provided continuation was read
completely and verified as 317 lines, SHA-256
`cabcd59ad6f522ba8fda94a50b3011192b08b2ff9debf21b4252be6c566c32fc`.
Unrelated dirty source and assets were preserved.

This document records the initial decoder and reader qualification. The later
[compilation and runtime checkpoint](compilation-performance-2026-09-25.md)
records subsequent cache changes, the full Zig graph result, runtime candidates,
and their remaining native integration gates.

## Changes

### Whole-tree resource limits

The corpus CLI now requires a private cgroup v2 beneath an already delegated,
writable ancestor. The supervisor does not enable shared controllers or alter
existing limits. Before any builder child executes, it configures:

- Aggregate memory from live available headroom after a 2 GiB system reserve,
  capped at eight 1.5 GiB worker budgets plus 256 MiB for the builder.
- No build swap (`memory.swap.max=0`) and group OOM handling.
- A CPU quota of 75% of effective affinity/ancestor capacity.
- At most 256 tasks, with at least 16 parent task slots left available.
- A project lock held by the supervisor so two corpus invocations cannot both
  allocate the same resource snapshot.

The supervisor considers its own leaf limits even when the delegated parent
requires creating a sibling cgroup. Exit and handled interruption reap only the
private build group. Unknown available memory refuses admission. A zero-budget
CLI check terminates directly, so a later resource recovery cannot accidentally
start an uncontained build. Existing worker/concurrency caps and live admission
checks remain in place.

These are limits on this build tree, not a guarantee that unrelated programs
will leave their own memory/CPU usage unchanged. Direct Zig fixture commands do
not use the corpus supervisor and require external restrictions.

### Correct compressed staging and lower decoder overhead

Downloaded meta-current parts are not necessarily small independent members.
The former one-offset-per-download scheme could exceed the reader's 128 MiB
decoded limit; a concatenated compressed part could also decode only its first
member without proving that the rest was consumed.

Staging now preserves the decompressed byte sequence while repacking
page-aligned bzip2 level-1 members. It targets 4 MiB, caps each member/page at
64 MiB, writes actual compressed offsets, and reports page/byte counts and time.
Only compressed staging is written to disk. Recompression has CPU and compressed
scratch costs; this pass does not claim a staging throughput improvement.

The native reader now feeds 64 KiB compressed buffers into a persistent bzip2
decoder. Growing the decoded output does not restart decompression. It retains
the 128 MiB output cap, handles exact-cap stream trailers, and rejects truncation,
corruption, trailing data/members, and invalid spans.

Both verified staging and completed publications now record
`page-aligned-bz2-v1`. Older markers are refused before publication or accepting
an existing output as complete. Old output is preserved; use a new output
directory for requalification. Source fingerprints already invalidate old shard
workspaces after this code change.

### Exact-title lookup

Byte-exact lookup retains priority. Its case-insensitive fallback now returns
the first folded exact title in source order. This preserves the previous
tie-break because an exact folded key sorts before any longer prefix key.
General prefix search still uses its bounded result window.

The exact scan is selected at compile time. An earlier runtime-flag candidate
regressed missing-title lookup by about 14% and was rejected. The accepted
candidate reduces that cost to about 3% on the measured case. Temporary folded
cache files are also removed if initial file sizing or mapping fails.

## Measurements

Zig 0.16.0, Python 3.14.7, Linux 7.2.6-zen2-1-zen. Both sides used ReleaseFast,
identical harnesses/dependencies and CPU 0 affinity at nice 15. Each suite used
`host-quiet` followed by `guarded-run --abort-on-busy`; accepted runs exited zero
and reported `QUIET`. Bounded execution used a 512 MiB address-space limit,
512 UID-wide process slots, 45 CPU seconds and a 55-second wall timeout. Only one
benchmark process ran at a time. No corpus build was started.

Three paired runs reversed baseline/candidate order in pair 2. Values below are
medians of each variant's elapsed time, with the iteration count divided out
for reader latency. These short microbenchmarks are observations of the named
cases, not broad workload or statistical confidence claims.

### Decoder

The high-ratio fixture is 4 MiB of `x`, compressed to 49 bytes at bzip2 level 1.
The incompressible fixture is 1 MiB from
`random.Random(42).randbytes(1024*1024)`, compressed to 1,057,251 bytes. Each
sample performs eight decode/free operations and checks the aggregate decoded
bytes and Wyhash checksum. Reported time includes positional reads, allocation,
decoding, hashing and freeing.

| Synthetic input | Baseline median | Candidate median | Baseline throughput | Candidate throughput |
| --- | ---: | ---: | ---: | ---: |
| High compression ratio, 32 MiB total | 141.160 ms | 69.996 ms | 226.69 MiB/s | 457.17 MiB/s |
| Incompressible, 8 MiB total | 291.475 ms | 291.256 ms | 27.45 MiB/s | 27.47 MiB/s |

The high-ratio result is 2.02x using the ratio of median times, or 2.06x using
the median of the three paired speedup ratios. Incompressible input is
effectively unchanged.

### Warm reader lookup

Input: an existing real Simple English blob with 54,568 title records, originally
at `.tmp/perf-simple/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb.xz`.
An isolated hard link and cache were used. The SHA-256 below identifies the exact
input; use the original only if that hash still matches.

Each sample performs 30 lookups. Early and late ASCII-case-toggled titles have
no byte-exact match; expected source indices are 3 and 54,479. The absent query
is `__wikidict_reader_bench_absent_20260925__`. Opening, query selection and
warmup are excluded from the timer. Every timed lookup checks the returned
index, and both variants have matching checksums.

| Case | Baseline median per lookup | Candidate median per lookup | Observation |
| --- | ---: | ---: | --- |
| Early folded exact match | 1.195550 ms | <0.001 ms | Stops after the early match |
| Late folded exact match | 1.175086 ms | 1.118597 ms | About 4.8% less time |
| Missing title | 1.064080 ms | 1.096060 ms | About 3.0% more time |

Early-match candidate samples total only about 3.3 microseconds for 30 lookups.
Their large ratio should not be generalized. This real dataset is below the
100,000-record threshold for automatic folded-cache construction; it does not
qualify cold cache behavior or larger dictionaries.

### Raw accepted samples

Elapsed nanoseconds, paired in the order described above:

| Workload | Pair | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| Decoder high ratio, 8 iterations | 1 | 141160317 | 68625232 |
| Decoder high ratio, 8 iterations | 2 | 141085780 | 69996107 |
| Decoder high ratio, 8 iterations | 3 | 147823610 | 70404430 |
| Decoder incompressible, 8 iterations | 1 | 290310013 | 291724775 |
| Decoder incompressible, 8 iterations | 2 | 291474930 | 290898404 |
| Decoder incompressible, 8 iterations | 3 | 297445868 | 291255890 |
| Reader early, 30 iterations | 1 | 35866498 | 3264 |
| Reader early, 30 iterations | 2 | 36916147 | 3361 |
| Reader early, 30 iterations | 3 | 34931051 | 3244 |
| Reader late, 30 iterations | 1 | 35252593 | 33557909 |
| Reader late, 30 iterations | 2 | 35769154 | 32616368 |
| Reader late, 30 iterations | 3 | 34088565 | 34094963 |
| Reader absent, 30 iterations | 1 | 31974955 | 32881798 |
| Reader absent, 30 iterations | 2 | 31922392 | 34268172 |
| Reader absent, 30 iterations | 3 | 31539839 | 32471929 |

Decoder checksum totals: high ratio `13440433246585312872`;
incompressible `11727884570655679824`.
Reader checksum totals: early `525`; late `1634805`; absent `1637475`.

## Correctness and remaining qualification

- 38 Python build/resource tests passed, including whole-tree cap calculations,
  ancestor and leaf headroom, lock contention, missing delegation, re-exec
  admission, interrupted-group cleanup, old-output refusal, multipart/
  concatenated-stream byte preservation and independently decodable members.
- 11 ReleaseSafe dump-reader tests passed, including allocation-failure cleanup,
  exact/over-limit output, multiple input buffers, offset arithmetic,
  truncation, corrupt CRC and trailing members.
- 17 ReleaseSafe reader/store/Unicode tests passed, including byte-exact
  preference, folded collisions, misses, bounded results and cache cleanup.
- Owned Zig files pass `zig fmt --check`; owned changes pass
  `git diff --check`.
- The real CLI refused with `Not enough available resources to start a build safely`
  and created no output directory. This validates the observed zero-budget
  refusal, not kernel enforcement of a newly created cgroup.

The current host exposes a read-only cgroup v2 mount at `/sys/fs/cgroup`,
with `cpu memory pids` available but no enabled subtree controllers. There is
no writable delegation for a new private build group. The raw `data/dumps`
cache is absent. Available RAM and load varied during the pass; an earlier
snapshot had about 3.5 GiB available and substantial existing swap use.

Cgroup control-file behavior is unit tested with temporary mocks. At this initial
checkpoint, a real delegated-host integration run, the full Zig test graph, an
end-to-end corpus build and Android/Desktop qualification had not been performed.
The bounded affected tests do not substitute for those qualifications.

## Next step toward 10,000 pages/s

On a host with writable delegated cgroups, nonzero live admission budget and
the complete raw dump cache, first establish a full-input baseline with phase
timing and verified page counts. Include staging, expansion, encoding, merging
and publication rather than extrapolating this decoder microbenchmark.

Persistent native workers already exist. Possible next targets from source
inspection are per-page context/standard-library setup in
`src/lua/bundle_worker.zig`, `src/lua/runtime/llvm_program.zig` and
`src/lua/runtime/stdlib.zig`, plus serialized coordinator reads/writes.
These are profiling hypotheses, not measured bottlenecks. Any reuse of runtime
state needs page-isolation and output-equivalence checks before accepting its
throughput result.

## Artifact identity

SHA-256 of measured source snapshots, binaries and inputs:

```text
2e39a9b84c6edec70531e7a187bfdf125a91b8b258fdaa95bbfe45add09f82bf  baseline wikimedia_dump.zig
16b6d1082469db683238a501c6d3d3e3f68f6111943ce9473b427c97154fb3b1  candidate wikimedia_dump.zig
e48e2a820bfddd200e0cb2891673773e8a07b56318220840f2ffb6a01e7393aa  baseline search.zig
b484a2a05f88e2103bef6395726229fe47b2c396623fdbc03813408a9abd68c7  candidate search.zig
d897be5d1512de62e46e7c117fbcb634953fe1b55809ac16787651e99648a55e  decode-baseline binary
d2a94ed106c72b67bc48a37ffee60d40cf35b0ef8fd8443f2cd0402699c3fe80  decode-candidate binary
67d264f0d198d1aa6e88453deafd203b0b88c7d9a40bd9c44e9f630b0d20fcbf  reader-baseline binary
1e3d699cdd5ef6706e165963ae53a8513629c93959f834e4461dc230ff6c483f  reader-candidate binary
53c0cfb71b5d4f94c35cdbc18ed2f178b2ab26920918b9088f49bcbbda9a4440  real Simple English blob
4c2af8fe9ee8e184a68ae1f059beff030e7e8d642c9cf2566ef53bc9d2580678  high_ratio.bz2
eb64c83e29337f9f7a52256b06a0eb427f40ae547620868f6356e4b1f241609c  incompressible.bz2
baa7a6d36ffa957552df230235c2d51d735f28d49c58a5f3438a3a973a25a37d  high_ratio decoded bytes
ba48c033547ece0b751c182b8a681cdaef29971e88c94aa029fad86233cdfb40  incompressible decoded bytes
```

Baseline reader dependencies were frozen from `9838a1b`; both measured variants
used those dependencies. Candidate source hashes match the accepted working
tree edits. Benchmark binaries and temporary caches are disposable; the raw
measurements, identity and exact harness sources are retained here.

## Benchmark harnesses

These harnesses describe the measured operations. Reproduction must retain the
external limits and quiet-host guard above. Do not run a corpus build to
reproduce these microbenchmarks.

### Decoder harness

```zig
const std = @import("std");
const dump = @import("dump");

pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const iterations = try std.fmt.parseInt(usize, args[2], 10);
    var file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const span: dump.StreamSpan = .{ .offset = 0, .len = (try file.stat(init.io)).size };
    var bytes: usize = 0;
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(init.io).toNanoseconds();
    for (0..iterations) |_| {
        const decoded = try dump.decompressMemberAlloc(init.io, a, &file, span);
        defer a.free(decoded);
        bytes += decoded.len;
        checksum +%= std.hash.Wyhash.hash(0, decoded);
    }
    const elapsed = std.Io.Clock.awake.now(init.io).toNanoseconds() - start;
    std.debug.print("bytes={d} iterations={d} elapsed_ns={d} checksum={d}\n", .{ bytes, iterations, elapsed, checksum });
}
```

### Reader harness

```zig
//! Isolated real-reader lookup benchmark. Copy into a frozen src/frontend/ tree.
const std = @import("std");
const search = @import("search.zig");
const store = @import("store.zig");
const storage = @import("blob_storage");

const Query = struct {
    bytes: []u8,
    source_index: usize,
};

fn toggledAsciiQuery(a: std.mem.Allocator, title: []const u8) !?[]u8 {
    if (title.len == 0 or title.len > 128) return null;
    var letter: ?usize = null;
    for (title, 0..) |byte, index| {
        if (byte >= 128) return null;
        if (letter == null and ((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z'))) {
            letter = index;
        }
    }
    const at = letter orelse return null;
    const query = try a.dupe(u8, title);
    query[at] = if (query[at] >= 'a' and query[at] <= 'z') query[at] - 32 else query[at] + 32;
    return query;
}

fn selectQuery(a: std.mem.Allocator, db: *store.Store, reverse: bool) !Query {
    const count = db.count();
    var checked: usize = 0;
    for (0..count) |ordinal| {
        const index = if (reverse) count - 1 - ordinal else ordinal;
        const query = (try toggledAsciiQuery(a, try db.titleAt(index))) orelse continue;
        errdefer a.free(query);
        if (db.file.find(query) != null) {
            a.free(query);
            continue;
        }
        checked += 1;
        const found = try search.find(a, db, query);
        if (found == index) return .{ .bytes = query, .source_index = index };
        a.free(query);
        if (checked >= 16) break;
    }
    return error.NoSuitableCaseToggledTitle;
}

fn measure(
    io: std.Io,
    a: std.mem.Allocator,
    db: *store.Store,
    label: []const u8,
    query: []const u8,
    source_index: i64,
    expected: ?usize,
    iterations: usize,
) !void {
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(io).toNanoseconds();
    for (0..iterations) |iteration| {
        const found = try search.find(a, db, query);
        if (found != expected) return error.LookupResultChanged;
        checksum +%= @as(u64, @intCast(found orelse db.count())) +% @as(u64, @intCast(iteration));
    }
    const elapsed = std.Io.Clock.awake.now(io).toNanoseconds() - start;
    const returned_index: i64 = if (expected) |index| @intCast(index) else -1;
    std.debug.print(
        "workload={s} iterations={d} elapsed_ns={d} source_index={d} returned_index={d} checksum={d}\n",
        .{ label, iterations, elapsed, source_index, returned_index, checksum },
    );
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3 or argv[1].len == 0 or argv[1].len > 4096) return error.Usage;
    const iterations = std.fmt.parseInt(usize, argv[2], 10) catch return error.Usage;
    if (iterations == 0 or iterations > 10_000) return error.Usage;

    var db: store.Store = .{
        .file = try storage.File.open(init.io, a, argv[1]),
        .allocator = a,
    };
    defer db.file.deinit(); // root is the non-owned Store default, so do not call Store.deinit.
    if (db.count() < 2 or db.count() > 100_000) return error.DatasetSizeOutOfRange;

    const early = try selectQuery(a, &db, false);
    defer a.free(early.bytes);
    const late = try selectQuery(a, &db, true);
    defer a.free(late.bytes);
    if (early.source_index == late.source_index) return error.DistinctQueriesRequired;

    const absent = "__wikidict_reader_bench_absent_20260925__";
    const absent_found = try search.find(a, &db, absent);
    if (db.file.find(absent) != null or absent_found != null)
        return error.AbsentQueryPresent;
    // Query selection and the full absent lookup finish before any timed section.
    try measure(init.io, a, &db, "early", early.bytes, @intCast(early.source_index), early.source_index, iterations);
    try measure(init.io, a, &db, "late", late.bytes, @intCast(late.source_index), late.source_index, iterations);
    try measure(init.io, a, &db, "absent", absent, -1, null, iterations);
}
```
