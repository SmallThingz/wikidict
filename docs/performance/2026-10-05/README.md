# Wikidict consolidation and corpus readiness, 2026-10-05

## Status

Implementation consolidation and the upstream Zig 0.17 integration are complete on local main. Full corpus execution is blocked before launch by unavailable strict resource containment. Zero of the 198 requested dictionaries have been published by this completion task.

## Repository

- Consolidation commit: `2f29b17213037f6a561bc7f29ccac114cdfb0b72`.
- Integrated upstream tip: `04bffaaa4085eba64df97ba447c3e337c4bde78b`, including the Zig 0.17 migration.
- Merge commit: `6cf2d86505a5e9498984ead968f2b9c762177ea1`.
- One registered worktree and one local branch, main. The remote advertises only main. There were no extra branch refs or registered worktrees to delete.
- Three historical recovery stashes were reviewed and preserved. Their obsolete runtime/codec implementations and incomplete transclusion fragment were not reintroduced into the current architecture.
- No remote push was performed; repository instructions require an explicit request.

## Consolidated behavior

Edition namespace registries now flow through extraction, sparse transclusion closure, native compilation and page contexts. Supplemental namespaces are retained in data-only output and represented in namespace coverage. Localized title content models and File/Media aliases follow the edition registry, including snapshot-key ownership and duplicate validation.

Native verification checks fixed-feature record counts against namespace coverage. Integration cases prove that missing and truncated supplemental output is rejected. Main language pages remain distinct from record counts because one page can contain several languages.

Published outputs carry sorted file inventories with sizes and SHA-256 digests. Resume validates exact bytes, edition/date/format, source identity, publication status and coverage before pruning shard workspaces. Invalid publications preserve recovery work. Derived reader indexes are excluded from the authoritative inventory. Failed publication renames retain the verified staging marker.

Inherited typed program shapes and the bounded warm request pool are consolidated. The pool retains at most 160 MiB per worker. Current tests cover runtime correctness; they do not establish full-history memory stability or a throughput improvement.

The Zig 0.17 integration preserves those changes. Additional runtime test repetitions and optimization-mode guards were migrated after the compiler exposed compatibility gaps in local commits beyond the upstream migration.

## Validation

| Gate | Result |
|---|---|
| Consolidated tree, Zig 0.16.0 | 64/64 build steps; 783 unit tests, zero failures/leaks/crashes; native integration passed |
| Merged tree, Zig 0.17.0 | 65/65 build steps; 783 unit tests, zero failures/leaks/crashes; native integration passed |
| Final Python discovery | 190/190 tests passed with `PYTHONPATH=tools` and a task-owned `TMPDIR` |
| Input integrity | 1,609/1,609 upstream SHA-1 checks passed |
| Edition provenance | 198/198 snapshot resolutions passed |
| Patch whitespace | `git diff --check` passed before both code commits |

Every successful qualification recorded unchanged source hashes across its run. The initial Python discovery attempt lacked the documented child-process `PYTHONPATH`; its four import failures were corrected by the invocation environment without changing resource-supervisor code. The first Zig 0.17 gate exposed removed syntax and old optimization enum literals; those were repaired and the full gate rerun.

Correctness runs occurred on the shared host. Their elapsed times are not performance benchmarks. Native bundle integration uses freshly built corpus fixtures and the build-only LLVM AOT worker; its injected OOM, worker-exit and timeout probes are expected test cases.

## Corpus inventory

- Manifest: `data/dumps/manifest.json`.
- SHA-256: `92e0a7425e89dcb183e401bc70ad68194b1c0ed64668cce86f133b2909a2c144`.
- 198 requested editions, all dated `20261001`.
- 1,609 downloaded files; 13,235,967,656 compressed bytes.
- Every file matched its upstream SHA-1, with file-stability checks. All 198 edition snapshot/provenance resolutions passed.
- Namespace registries, language registries, category statistics and interwiki maps exist for all 198 editions.
- Category trees are complete for 180 editions. Missing: hu, hy, id, it, ja, ku, lt, mg, nl, pl, pt, ru, sv, ta, th, tr, vi and zh.
- Full published dictionaries: 0/198. Downloaded inputs, native workers and synthetic integration blobs are not completed dictionaries.

No full-corpus fallback count or semantic expansion success rate is available. Real file-metadata captures are absent from this inventory; file snapshot tests use marked synthetic fixtures. The earlier first-100k history failure and the throughput goal remain unqualified by this task.

## Execution blocker and prepared continuation

The strict supervisor attempt at 2026-10-05T02:01:15.352534+00:00 stopped before starting auxiliary preparation:

```text
A writable delegated cgroup with cpu, memory and pids controllers is required
```

`AGENTS.md` requires strict private cgroup limits by default and explicit user acceptance of the existing watchdog fallback. The environment has a read-only cgroup mount, no writable delegated subtree, and no usable user or system systemd manager. No corpus preparation or expansion was launched outside the required supervisor.

The prepared sequence first creates the 18 missing category trees in a fresh task-owned scratch directory, then runs `tools/build_wiktionaries.py` for all editions. It fixes `--now-unix=1791158400`, uses one edition job and four pipeline/expansion workers, and pins the verified project-local Zig 0.17.0 compiler. If accepted, the watchdog would use the existing sampled aggregate 8 GiB cap, one CPU and a 24-hour deadline for auxiliary preparation, then four CPUs and a seven-day deadline for the dictionary batch. This is best-effort process-tree enforcement rather than a kernel cgroup memory cap.

The exact argument arrays and watchdog options are recorded in `validation.json`. The compiler archive was verified against the official SHA-256 `1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026`. The compiler executable is `.tmp/toolchains/zig-x86_64-linux-0.17.0/zig`; the global Zig installation was unchanged.

After authorization or environment repair, run preparation under the corpus lock, run the complete batch under the same lock through its controller, and reconcile all 198 requested editions against verified `complete.json` publications. Report actual page coverage, fallback totals, output counts and any failed editions. Do not infer completion from a downloaded dump or a partial shard.
