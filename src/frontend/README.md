# Native frontends

The shipped desktop reader has three native surfaces over the same compiled dictionary data:

- `dict`: CLI
- `dict tui`: terminal UI
- `dict-qt`: Qt 6 / C++ desktop GUI

The separate `src/web/` reader imports compiled JSON exports. There is no read-time Lua, template, or wikitext execution. Lua/templates/wikitext are bundle-time compiler inputs only.

## C ABI

`src/frontend/c_api.zig` exposes an opaque data-reader handle through `src/ffi/dict.h`. The Qt application links to `libdictffi` and calls the Zig reader in-process. The ABI returns versioned UTF-8 `dict.results.v1` JSON buffers rather than exposing Zig layouts.

A handle owns the mapped blob/index and selected collection. Lookup, prefix search, random words, language catalog, and statistics are data-only operations.

## Compiled presentation

Every record is a self-contained compiled presentation document. Readers deserialize semantic sections, styled spans, links, tables, references, media descriptors and lexical layout directly; they do not reconstruct source, load companion bodies, expand templates, or parse wikitext. A payload that is not the expected compiled schema is rejected.

## Qt application

Build the native GUI with `zig build qt`. Qt uses Widgets and C++20. History, bookmarks, learning scores and UI settings are persisted locally with `QSettings`; quizzes, flashcards, unscramble and random-word navigation consume the same compiled dictionary data.

## Validation

```sh
zig build test
zig build test-reader
zig build ffi
zig build qt
```
