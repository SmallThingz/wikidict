# Project Notes

- The working tree may contain intentional WIP from multiple ongoing rewrites. Do not reset, clean, or discard unrelated changes.
- Commit completed features and bug fixes as coherent units using conventional commit types (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`, etc.). Stage only the files/hunks belonging to that unit; never sweep unrelated dirty or pre-staged WIP into a commit. Do not push unless explicitly requested.
- Dictionary format `WIKDIC34` keeps compact titles and aliases, fixed `u32` alias targets, and varint-length-prefixed tagged payload records.
- Payload kind `1` is the frontend-neutral English section IR. Payload kind `0` is compact raw fallback for mixed-language or non-English storage.
- Renderer-facing code should prefer `EntryView.documentAlloc()` and walk section level/title/kind plus renderer-neutral blocks (`kind`, nesting `depth`, marker-free `text`). Do not persist HTML or terminal-specific styling.
- Preserve exact source reconstruction through the existing raw APIs and verifier.
- Incompatible dictionary layout changes require a magic bump. Cache reference or semantic changes require a decoder cache-version bump.
- Reuse `encoder/section_encoding.zig` rather than introducing a second structural parser.
- Run the stable Zig at `/home/a/zalloc-work/zalloc-next-handoff-20260904/remote-tools/zig/zig` and gate changes with `zig build test`.
- Follow `/home/a/AGENTS.md` for shared-host benchmark and tooling rules.
