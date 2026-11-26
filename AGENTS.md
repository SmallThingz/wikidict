# AGENTS.md

## Repository rules

- The active completion goal is all original 198 editions compiled and verified for faithful content and working rendering across the supported clients. Do not stop at environment setup, partial generations or scoped tests. Use RD/DC's `review-council` skill and keep working until the user pauses/stops the task or the complete evidence earns unanimous whole-task STOP votes. Use GPT-6.2 Astra/Sol only, with Daybreak off; current council seats and evidence are in `.tmp/completion-council/`.
- Run compilation, translation and qualification in the current connected Cloud environment. The user's 2026-11-26 instruction restricts RD/DC to absolute emergencies, requested cleanup and safely closing existing owned work. Storage exhaustion is not an emergency exception: reduce the local working set instead. Do not launch routine RD/DC builds, tests, staging or source-preparation jobs.
- Diagnose all 198 editions in parallel using delegated language workers; council agents may create their own subagents. Use only GPT-6.2 Astra/Sol, with Daybreak off. Share existing local inputs without duplicating checkouts or payloads, and bound aggregate build/browser memory and disk usage separately from lightweight parallel diagnosis.
- Keep only data needed for unfinished work, current dictionaries and meaningful verification. Remove obsolete runs and redundant intermediates. The user waived the 25 GB data-directory cap; this is a necessity-based cleanup, not a size target. Do not move or copy data elsewhere to evade the user's deletion.
- Prioritize end-to-end speed over minimum disk usage while keeping the working set within capacity. Stage selected compressed inputs one edition at a time, reuse compatible caches, and preserve original sources and unique failure evidence on RD. See `compiler/docs/local-build-capacity.md` for capacity checks and existing pipeline commands.
- `main` is the only local branch. Work directly on it; do not create branches/worktrees unless the user explicitly asks.
- Push verified source changes to `origin/main` as requested.
- When using collaboration tools, activate follow-up work on an idle or completed agent with `followup_task`. `send_message` only delivers a message; it does not wake the agent. Check actual owner/task status before waiting for a review or job, and reuse the existing owner instead of starting a duplicate.
- Do not publish GitHub releases, including prereleases, until the user explicitly approves publication again. The application is not production-ready until the user says it is; passing tests or packaging artifacts does not grant release approval.
- Corpus builds budget 8 GiB independently of host free RAM. The default requires private cgroup limits; explicit `--resource-mode=watchdog` uses sampled best-effort memory/task limits, bounded CPU affinity and a finite deadline when the user accepts that fallback.
- Check shared-host available RAM and memory pressure before admitting a job. Once admitted, host RAM/PSI changes are telemetry only and must not terminate the job. Preserve the job's own memory, CPU, task and time limits; queue subsequent work instead of killing an admitted job because another workload consumed RAM.
- `build_resource_limits.supervise_watchdog` and its cgroup counterpart `supervise` take Python arguments and prepend `sys.executable`. Do not pass a shell, Gradle wrapper, Node or native executable directly. To run another executable, pass `['-c', 'import os,sys; os.execv(sys.argv[1],sys.argv[1:])', absolute_executable, *arguments]`; this preserves the supervised process identity without adding another launcher process.
- For correctness builds and tests, require the selected job's allocation plus its host reserve. Prepared or queued jobs are not live allocations; reconcile actual admitted owners and serialize crossing admissions. Admission may explicitly count available RAM plus verified free swap on non-virtual block devices; exclude zram, swap files and unknown backing conservatively. Preserve the job's own memory/swap caps; record PSI as advisory rather than requiring an idle host. Matched performance measurements may require a quiet host. Reuse one finite admission queue and avoid repeating unchanged setup or validation.
- Incremental admission uses the new job's allocation plus its reserve against current available memory. Do not automatically add every already-admitted job's full maximum to that threshold. Reconcile owners and serialize the final check/start; this policy does not promise that all concurrent jobs can grow to their maximum simultaneously. A separate full-budget reservation policy must be explicitly selected, not silently inherited from a previous launcher.
- Unless the user or a matched benchmark requires specific CPUs, use an available subset of the allowed CPUs before waiting solely on a historical affinity assignment. Verify actual owners, keep the same CPU count and all memory/task/time limits, and rebind the existing unstarted invocation; preserve its original configuration. Never change an admitted job's affinity or interrupt another owner to make room.
- Short correctness checks may share a CPU with an existing owner by agreement when their mutable inputs and outputs are independent and fresh incremental admission passes. Keep both jobs' limits. Coordinate directly with the owner; do not add a root-approval wait for each already-authorized check or treat ordinary CPU activity as an exclusive reservation.
- Qualify task-owned private candidates as soon as ownership, matching source, syntax and resource checks pass; independent source review can run alongside compilation and tests. Keep the required review and test evidence before canonical integration. Do not add serial approval handoffs for an unchanged runner or already-authenticated metadata.
- When a corpus build uses the ordinary checkout fingerprint, coordinate edits against the files `_source_fingerprints` actually reads through the final publication check. It hashes `build.zig`, `build.zig.zon`, and matching source files throughout `compiler/src/`, `compiler/tools/` and `renderer/src/`, including Python tests, even when every executed program has an explicit path and digest. A fresh expansion worker can use this path with retained native tools. Check the selected builder's `PROJECT` and source mode when handing off a running job. Private candidates outside that tree can proceed during the build.
- Cleanup may signal only individually verified task-owned PIDs with matching start times and exclusive job ownership. Never signal process groups, ancestors, RD, plugins, servers, tunnels or shared infrastructure. Preserve an unknown cleanup outcome rather than targeting an unverified process.
- Make regular, small commits after coherent validated steps. Stage only files owned by the current task; preserve unrelated shared dirty work.
- Keep temporary files under `.tmp/` and remove them before finishing.
- Keep WikiDict packages, intermediate dictionary data, build outputs and QA working directories inside this checkout. Resolve writable paths before launching a job: a symlink under `.tmp/` may still point outside the checkout. Standard tool-managed caches and genuinely necessary system configuration are exceptions. Never create project-specific scratch directories under HOME or on another shared volume.
- Set `TMPDIR` to this checkout's resolved `.tmp/` or a directory inside it before running metadata validators, including read-only preflights. Validation can unpack an earlier capture into Python's default temporary directory.
- Reuse a checkout-local compiler cache across runs. Once a job closes, retain the selected dictionary, minimal failing input, source revision or patch, and test results. Remove regenerable scratch and redundant binary installs after the last consumer finishes. Use the original dated archives in place wherever the normal compiler supports them.
- Source snapshots may share hardlinks. Before editing a file with more than one hardlink, replace only the intended path with an independent copy; never modify the shared inode in place.
- For focused Zig tests, pass the selected `prepare-tests` arguments to `test_cache_report_command` in `compiler/tools/native_qualification.py`. For named Encoder or Tools tests, use `-Dprepare-test-group=encoder` or `-Dprepare-test-group=tools`. Physical partitions such as `tools_core` supply their own filters. Set `ZIG_GLOBAL_CACHE_DIR` in the child environment and pass the local path with `--cache-dir`. Run the returned `qualification-cache-artifacts` command and use its reported executable for each group's test discovery and execution. This avoids a second ELF in each run directory. When a diagnostic needs a standalone `-femit-bin` copy, release it after the last borrower finishes and keep the source, test results and failure output.
- `.tmp/` is shared by long-running qualification jobs. Never delete it wholesale; remove only task-owned paths after checking that no live process owns them and that any required acceptance audit has completed.
- Keep producer code and tooling under `compiler/`, the shared format and readers under `renderer/`, and the apps under `desktop/` and `android/`. Preserve the imported application histories and follow their local instructions.
- Delete dead experiments and compatibility layers instead of parking alternate architectures in the repository.

## Product / bundle boundary

- The shipped dictionary contains data only. No Lua modules, template source, LLVM bitcode, native expansion worker, bytecode, executable program representation, or other executable corpus code is shipped to the user.
- Lua modules, MediaWiki templates, and wikitext syntax are compile/bundle-time inputs. Execute/expand and compile them while building the blobs, then store only semantic presentation data needed by readers.
- Shipped readers decode compiled semantic presentation data only. They must not parse wikitext, expand templates, reconstruct source, load Lua/Scribunto/module/template inputs, or depend on a native expansion worker.
- Build-time expansion must preserve Wiktionary/MediaWiki semantics for page-sensitive constructs. If a result depends on page/title/frame/context, resolve it for that concrete bundled page rather than shipping deferred code.
- Prefer deleting runtime package/provider/code-loading machinery once bundling makes it unnecessary.
- Treat any template token, raw wikitext delimiter, deferred source body, or executable corpus representation surviving into a shipped reader record as a build error; do not add a read-time fallback.

## Build-time Lua architecture

- There is one Lua execution path used by the bundler: `Lua source -> AST -> LLVM module -> LLVM bitcode -> native code`.
- `compiler/src/lua/parser/` owns Lua 5.1 syntax and ASTs.
- `compiler/src/lua/direct/` owns whole-program static analysis and direct LLVM module emission. Analysis metadata is allowed; a second executable/custom instruction IR is not.
- `compiler/src/lua/abi/` owns small stable compiler/runtime layouts such as global and native-namespace slots.
- `compiler/src/lua/runtime/` owns Zig primitives and the C ABI used by generated LLVM during bundling.
- `compiler/src/lua/wikitext/` and `compiler/src/lua/extract/` own MediaWiki preprocessing and dump extraction used during bundling.
- Never introduce a VM, bytecode, serialized executable program, generated-Zig Lua functions, or a fallback execution engine.

## Native optimization rules

- Make every operation as static as correctness permits. Prefer LLVM constants, typed SSA values, direct calls, fixed offsets/slots, and compile-time tables over `Value`, hashes, or generic table dispatch.
- Do not abandon a specialization because the proof/lowering is difficult. Solve the hard cases; keep a dynamic fallback only for the exact operation whose semantics are not proven.
- Treat corpus-wide module identities, redirects, function targets, exports, globals, result arity, types, captures, immutable constants, table shapes, and field names as compiler knowledge.
- Preserve Lua/Scribunto edge semantics during bundle-time execution: evaluation/store order, rebinding, varargs, multiple returns, closures/upvalues, recursion, module cycles, metamethods, identity/mutation, iteration, errors, and number/string coercion.
- Broad structural rewrites are allowed when they remove indirection. Prefer deleting an obsolete layer over adapting it.
- Use Zig primitives behind a C ABI for general hash maps, allocation, Unicode, patterns, host APIs, and other complex services; do not reimplement them in LLVM IR.
- Program/corpus metadata should be immutable and process-lifetime during bundling. Page state must be explicit and local; do not rebuild/reset a global execution environment per operation when state can be split into static program data plus page-local mutation.
- Constant module/name lookups should compile to IDs/direct references where semantics prove them; otherwise generated static tables/binary search are preferred to startup-built hash maps.
- Serialize executable LLVM modules directly to transient bitcode, compile that bitcode to native objects, and link the expander normally with Zig/LLD. Keep semantic corpus metadata and large static literal graphs out of optimizer-visible LLVM instruction graphs. Choose production module optimization from corpus usage: dominant page/module reach uses `-O2`, known lower reach uses `-O1`, and zero recorded page and module reach may use `-O0`. Zero recorded reach is a heuristic under dynamic module targets; qualify full-page runtime and total build time before retaining it. Source size is only a secondary ranking cost. The compact program root table uses `-O1`. Do not use LTO/ThinLTO for the corpus-wide expander.
- Optimize total dictionary build time plus shipped-reader execution time. Code/binary/blob size is secondary unless it materially affects those times or operational limits.
- String interning/deduplication, compression, canonicalization, or compact encodings are not goals by themselves. Remove or weaken them when measured compile+run time improves and correctness/operational limits remain acceptable.
- Profile before retaining performance work. Reject changes that reduce instructions or size but regress measured cycles/task time on representative workloads.
- Runtime-only relinks may reuse native Lua objects only after verifying that their imported value-leaf ABI matches the current runtime Context, Table, Shape, Value, and callable layouts. Rebuild leaf bitcode and affected native batches after layout changes; output parity alone does not establish ABI compatibility. Hold the native toolchain, leaf bytes, and link order constant for matched performance comparisons.

## Encoder / decoder rules

- Encoder owns build-time wikitext-to-presentation compilation; decoder/runtime APIs expose compiled semantic data only. Keep Lua/compiler/module/template execution and wikitext parsing out of reader APIs.
- Prefer simple direct encodings over expensive deduplication/indexing when the latter does not win end-to-end build+read time.
- Any size-for-speed tradeoff must be measured with dictionary build time and reader throughput, not assumed from file size alone.

## Validation

- Use the repository Zig toolchain configured for this host.
- Build-time compiler/expander changes require direct compiler/runtime tests and bundle-time expansion integration coverage.
- Encoder/decoder changes require round-trip tests plus representative build/read benchmarks.
- Run full `zig build test` when unrelated shared edits do not block it.
- Run `git diff --check` before every commit.
- The representative English 100k benchmark is the first 100,000 rows of the official 2026-09-01 multistream index (row-window SHA-256 `abf923c141deef52263527cc8e00f81acc83eb6017a7f9d58c152f6638cc866e`). Build the expander from the full dump first, then run the blob stage with `--limit-pages 100000`; the standalone 100k XML shard has no Module namespace and is not a valid Lua-performance oracle.
- Reader UX changes should exercise the actual CLI and PTY, including narrow terminals, resize, Unicode input, terminal restoration, and concurrent state saves when relevant. `test-reader` generates marked synthetic fixtures for `compiler/tools/verify_reader_ux.py`; never run destructive state checks against user dictionaries.
- Terminal media work owns and joins its background tasks before releasing arguments or state. Preserve I/O cancellation errors through the media helpers.
