# AGENTS.md

## Repository rules

- `main` is the only local branch. Work directly on it; do not create branches/worktrees unless the user explicitly asks.
- Do not push unless the user explicitly asks.
- Corpus builds use a fixed 8 GiB aggregate memory cap, independent of host free RAM. Retain private cgroup CPU/PID limits and any smaller inherited memory cap.
- Make regular, small commits after coherent validated steps. Stage only files owned by the current task; preserve unrelated shared dirty work.
- Keep temporary files under `.tmp/` and remove them before finishing.
- `.tmp/` is shared by long-running qualification jobs. Never delete it wholesale; remove only task-owned paths after checking that no live process owns them and that any required acceptance audit has completed.
- Keep product code under `src/` and build/integration utilities under `tools/`.
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
- `src/lua/parser/` owns Lua 5.1 syntax and ASTs.
- `src/lua/direct/` owns whole-program static analysis and direct LLVM module emission. Analysis metadata is allowed; a second executable/custom instruction IR is not.
- `src/lua/abi/` owns small stable compiler/runtime layouts such as global and native-namespace slots.
- `src/lua/runtime/` owns Zig primitives and the C ABI used by generated LLVM during bundling.
- `src/lua/wikitext/` and `src/lua/extract/` own MediaWiki preprocessing and dump extraction used during bundling.
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
- Reader UX changes should exercise the actual CLI and PTY, including narrow terminals, resize, Unicode input, terminal restoration, and concurrent state saves when relevant. `test-reader` generates marked synthetic fixtures for `tools/verify_reader_ux.py`; never run destructive state checks against user dictionaries.
- Terminal media work owns and joins its background tasks before releasing arguments or state. Preserve I/O cancellation errors through the media helpers.
