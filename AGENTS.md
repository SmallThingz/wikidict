# AGENTS.md

## Repository rules

- `main` is the only local branch. Work directly on it. Do not create branches or worktrees unless the user explicitly asks.
- Do not push unless the user explicitly asks.
- Keep temporary files under `.tmp/` and remove them before finishing.
- Keep the working tree clean. Delete dead experiments instead of parking them in the repository.

## Lua architecture

- Lua execution is native AOT only. There is exactly one execution engine.
- `lua/parser/` owns Lua syntax parsing.
- `lua/compiler/` owns IR, analysis, optimization, lowering, and linking.
- `lua/abi/` owns stable compiler/runtime ABI contracts.
- `lua/aot/` emits native Zig and external program data.
- `lua/runtime/` is support code linked into generated native code.
- `lua/wikitext/` owns compile-time wikitext helpers.
- `lua/extract/` owns dump extraction for modules and templates.
- Production expansion requires the dump-specific `dict-native-expansion-worker`. Missing or incompatible native assets are explicit errors. Do not add a second execution path or silent fallback.
- Runtime builds publish source/provider data, `aot-data.bin` when required, and the native worker. Do not serialize executable Lua programs into a second runtime format.

## Validation

- Use the repository Zig toolchain configured for this host.
- For compiler/runtime changes, run `zig build test` and `zig build test-runtime`.
- For frontend schema/UI changes, rebuild `frontend/web` and run the relevant frontend tests.
- Run `git diff --check` before committing.
