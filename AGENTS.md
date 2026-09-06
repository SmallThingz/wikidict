# Project Notes

- The working tree may contain intentional WIP from multiple ongoing rewrites. Do not reset, clean, or discard unrelated changes.
- Commit completed features and bug fixes as coherent units using conventional commit types (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`, etc.). Stage only the files/hunks belonging to that unit; never sweep unrelated dirty or pre-staged WIP into a commit. Do not push unless explicitly requested.
- Dictionary format `WIKDIC34` keeps compact titles and aliases, fixed `u32` alias targets, and varint-length-prefixed tagged payload records.
- Payload kind `1` is the frontend-neutral English section IR. Payload kind `0` is compact raw fallback for mixed-language or non-English storage.
- Renderer-facing code should prefer `EntryView.renderDocumentAlloc()`. Use `term_records` for term-list sections, `translation_records` for translation sections, and stream `blockIterator()` / `inlineIterator()` for general/POS text. `documentAlloc()` additionally materializes compatibility bodies for structured sections and should be reserved for callers that need them. Template spans hand off to Lua/Scribunto expansion. Do not persist HTML or terminal-specific styling.
- Preserve exact source reconstruction through the existing raw APIs and verifier.
- Incompatible dictionary layout changes require a magic bump. Cache reference or semantic changes require a decoder cache-version bump.
- `WIKBLB04` blobs are logical uncompressed artifacts. Persist semantic data plus only the minimal framing needed to recover it; do not persist derivable lookup indexes, offset tables, record counts, record-area lengths, or catalog filename/count columns. Build those at runtime.
- Do not bake zstd, Brotli, chunk compression, or any transport/storage compression into blob formats; compress finished blob files separately outside the format when needed.
- Reuse `encoder/section_encoding.zig` rather than introducing a second structural parser.
- Run the stable Zig at `/home/a/zalloc-work/zalloc-next-handoff-20260904/remote-tools/zig/zig` and gate changes with `zig build test`.
- Follow `/home/a/AGENTS.md` for shared-host benchmark and tooling rules.

- Serialization work must not modify VM or VM-related code under `lua2/`; it is owned by another agent.

- Frontends share `frontend/model.zig`, the runtime wikitext renderer and the portable blob readers. Keep exact source separate from presentation; unresolved templates stay explicit, and human output must neutralize terminal control sequences.
- Machine results use the versioned `dict.results.v1` stdout protocol; diagnostics go to stderr. Do not place frontend data or theme state into blob files.
- Rebuild and commit `frontend/web/dist/index.html` after editing web source; native builds embed it and must not fetch Node dependencies. Test terminal cleanup using a real PTY, including resize and handled signals.
- Rendering gates must assert visible semantic content, not just process startup. Keep native template support explicit; never label an argument projection as full Scribunto expansion or fabricate language morphology.
- `runtime_bridge.zig` is the integration boundary for the VM-owned compiler/codec/runtime. Keep changes to `lua2/` with its owning agent; test the actual converter-to-renderer path through `zig build test-runtime`. `build-dictionary` coordinates existing passes, not a new wire format or a completed single-pass merger.
- VM expansion must preserve original source, expose failures in `entry.expansion`, return nonzero for CLI fallbacks, and reject incomplete runtime builds. Never treat a successful corpus compile as proof that all compiled modules execute correctly.
- WIKBLB04 external-body markers derive their family from the retained heading. Resolve required per-language companions before exact-source decoding or VM expansion; do not present missing bodies as empty. Validate complete source and orphan companion records after storage changes.
- `entry.organization` is runtime-only: preserve original sections, distinguish origins and languages, attach evidence to its actual definition, and never label synonym lists as usage examples. Inflected entries retain their own meanings and explicit base-word relations.
- Language accounting must state its scope (global catalog or exact spelling). Canonical registry matches are not a count of living languages or Wiktionary editions; Translingual and unverified headings are separate.
- Core presentation is explicit, not failed reconstruction: `section.deferred` and `entry.content` mark intentionally unopened companions. Exact source and VM expansion must resolve every required body; test missing-package recovery with a real PTY and verify zero companion mappings before details.
