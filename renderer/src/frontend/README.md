# Native frontends

The shipped reader has three native surfaces over the same compiled dictionary data:

- `wikidict`: CLI (`dict` remains an invocation alias)
- `wikidict tui`: terminal UI
- `wikidict-gio`: Qt 6 / C++ desktop GUI, a symlink to `wikidict`

The invocation name selects the surface in the same process. The CLI and TUI require no Qt libraries. The GUI invocation loads the installed desktop library from `../lib` relative to the real executable; install the desktop component into the same prefix as `wikidict`.

The Qt and web interfaces live in [desktop](../../../desktop/README.md), alongside the [Android application](../../../android/README.md). Both application histories are preserved in this repository. There is no read-time Lua, template, or wikitext execution. Lua/templates/wikitext are bundle-time compiler inputs only.

## C ABI

`renderer/src/frontend/c_api.zig` exposes an opaque data-reader handle through `renderer/src/ffi/dict.h`. The Qt desktop library links to `libdictffi` and calls the Zig reader in-process. The ABI returns versioned UTF-8 `dict.results.v1` JSON buffers rather than exposing Zig layouts. The desktop component exports `extern C int wikidict_gui_main(int argc, char **argv)`; exceptions must be handled within that entry point.

A handle owns the mapped blob/index and selected collection. Lookup, prefix search, random words, language catalog, and statistics are data-only operations.

## Compiled presentation

Every record is a self-contained compiled presentation document. Readers deserialize semantic sections, styled spans, links, tables, references, media descriptors and lexical layout directly; they do not reconstruct source, load companion bodies, expand templates, or parse wikitext. A payload that is not the expected compiled schema is rejected.

## Qt application

Build the native GUI from this repository using the [desktop build instructions](../../../desktop/README.md#native-qt-reader). Qt uses Widgets and C++20. History, bookmarks, learning scores and UI settings are persisted locally with `QSettings`; quizzes, flashcards, unscramble and random-word navigation consume the same compiled dictionary data.

## Validation

```sh
zig build test
zig build test-reader
zig build ffi
```
