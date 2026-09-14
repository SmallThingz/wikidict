# AGENTS.md

## Repository rules

- `main` is the only local branch. Work directly on it. Do not create branches or worktrees unless the user explicitly asks.
- Do not push unless the user explicitly asks.
- Keep temporary files under `.tmp/` and remove them before finishing.
- Keep the working tree clean. Delete dead experiments instead of parking them in the repository.
- Keep product source under `src/` and build/integration utilities under `tools/`; do not add new top-level source trees without a concrete need.

## Lua architecture

- Lua execution is native AOT only. There is exactly one execution engine.
- `src/lua/parser/` owns Lua syntax parsing.
- `src/lua/compiler/` owns IR, analysis, optimization, lowering, and linking.
- `src/lua/abi/` owns stable compiler/runtime ABI contracts.
- `src/lua/aot/` emits native Zig and external program data.
- `src/lua/runtime/` is support code linked into generated native code.
- `src/lua/wikitext/` owns compile-time wikitext helpers.
- `src/lua/extract/` owns dump extraction for modules and templates.
- Production expansion requires the dump-specific `dict-native-expansion-worker`. Missing or incompatible native assets are explicit errors. Do not add a second execution path or silent fallback.
- Runtime builds publish source/provider data, `aot-data.bin` when required, and the native worker. Do not serialize executable Lua programs into a second runtime format.

## Validation

- Use the repository Zig toolchain configured for this host.
- For compiler/runtime changes, run `zig build test` and `zig build test-runtime`.
- For frontend schema/UI changes, rebuild `src/frontend/web` and run the relevant frontend tests.
- Run `git diff --check` before committing.
