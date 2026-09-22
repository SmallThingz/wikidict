# Web reader

A static, offline reader for compiled `dict.results.v1` JSON exports. Import a file with the folder button; search and links stay local, except explicitly opened HTTPS links. Imports are validated in a worker and capped at 64 MiB. No wikitext, templates, Lua, or corpus executable code is loaded.

Run `pnpm install --ignore-scripts`, then `pnpm build` in this directory. Serve `../../zig-out/web` with any static HTTP server (module workers need HTTP). The web and Android clients currently read JSON exports, not whole `.wikblb` collections directly. Media descriptors are displayed; embedded media playback is not implemented.

`pnpm test` checks input validation. `pnpm test:browser` runs Chromium layout and semantic rendering checks at 360, 768 and 1440 px, tests failed imports and navigation, and saves screenshots under `data/renderer-validation/web/`. Set `CORPUS_FIXTURE` to a real `dict export cat` JSON file for the additional corpus import check. Set `CHROMIUM` to a Chromium executable if Brave is not installed at `/opt/brave-bin/brave`.

Generate the shared fixture with `zig build test-reader` from the repository root. Its final output names a cache artifact directory containing `fixture.json` and `blobs/`. Set `RENDERER_FIXTURE` to that JSON path before the browser test; its default is `data/renderer-validation/fixture.json`. The same fixture feeds Android's `-PrendererFixture` tests and terminal checks in `tools/verify_terminal.py`.
