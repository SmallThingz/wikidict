# Wikidict desktop

Qt desktop and web presentation work, split from [wikidict](https://github.com/SmallThingz/wikidict) with the original commits for these files preserved.

The native desktop reader opens `.wikblb` dictionaries through the core C ABI. Lua compilation and dictionary encoding belong to the core repository.

## Build Qt

Requires CMake 3.21+, a C++20 compiler, and Qt 6.5+ Core, Gui, Widgets,
Concurrent, Network and Multimedia. Qt Test is used when `BUILD_TESTING` is on.
Build the core checkout with its configured Zig toolchain:

```sh
cd ../wikidict
zig build ffi -Doptimize=ReleaseFast
cd ../wikidict-desktop
cmake -S . -B build -DWIKIDICT_CORE=../wikidict -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 2
./build/bin/dict-qt
```

Set `WIKIDICT_CORE` to the actual core checkout if the repositories are not siblings.
An optional `--root <folder>` selects a dictionary folder; otherwise the app restores
the last folder and word. First launch opens a recoverable setup screen.

## Native reader

- **Library:** import raw `.wikblb` files or `.wikblb.xz` with system `xz`; choose an
  existing folder; manage HTTPS catalogue sources; stream and verify downloads;
  confirm replacements and removals. Import, validation and downloads expose
  progress, cancellation and recovery. The default catalogue depends on published
  release assets; local import and custom catalogues remain usable if it is unavailable.
- **Search:** choose a language and collection, use case-insensitive Unicode prefix
  search, and load every result in pages of 80. Dictionary opening and title-index
  preparation happen in a worker. Exact title case is preferred when opening a word.
- **Reading:** warm system/light/dark themes, bundled Newsreader type, adjustable text
  size, section navigation, pronunciation/etymology folding, tables, styled spans,
  references and internal section links. Back/Forward restores folds and reading
  position. Window size and sidebar width are remembered.
- **Saved and learning:** direct History, Saved, Learn and Settings buttons;
  removable saved/history rows; persistent preferences; quiz, flashcards and
  grapheme-preserving scramble. The selected game source updates immediately.
  The all-words pool includes a sample of up to 64 dictionary entries, so learning
  works before a history has accumulated.
- **Media and speech:** opt-in image/audio loading, native playback and seeking,
  source/licence links, retry and bounded cache controls. Offline word speech uses
  an installed `espeak-ng` or `espeak` voice matching the entry language. A supported
  English IPA subset also has playback controls. Missing engines, voices or audio
  output produce an actionable message. No speech engine is bundled.

| Keyboard | Action |
| --- | --- |
| Ctrl+O | Open Library |
| Ctrl+L | Focus and select search |
| Up / Down | Move from search into suggestions |
| Enter | Open the selected suggestion or typed word |
| Escape, or Up from first suggestion | Return to search |
| Alt+Left / Alt+Right | Previous / next word |
| Ctrl+D | Toggle bookmark |
| Ctrl+H | Open History |
| Ctrl+, | Open Settings |
| Ctrl++ / Ctrl+- | Change reading text size |

## Native validation

```sh
cmake --build build --parallel 2
ctest --test-dir build --output-on-failure
```

The reader suite uses real compiled English and thesaurus fixtures through the C ABI
and Qt mouse/keyboard events. It covers setup and cancellation, case-insensitive
paging, stale queries, navigation, folding, references, live learning sources,
single-score scramble rounds, themes and layout. Library tests cover real file
imports, compressed replacement, malformed files, checksums, cancellation and
recovery. Media tests use controlled network responses and an isolated speech
process, covering opt-in behavior, bounded caching, language/IPA matching and
unavailable output. These tests do not establish whole-corpus performance or
verify audible sound on hardware. See [fixture provenance](tests/README.md).

The `web/` reader now imports raw `.wikblb` and seekable `.wikblb.xz` directly. It keeps binary files and derived indexes in IndexedDB, decodes individual entries in a worker, and provides Saved, History, Search, Learn and Settings. Build with `cd web && pnpm install && pnpm build`; serve `build/web/` over localhost or HTTPS. See [web validation and capabilities](web/README.md).

Android is maintained in [wikidict-android](https://github.com/SmallThingz/wikidict-android).
