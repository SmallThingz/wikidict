# Wikidict Desktop

Desktop readers for dictionaries produced by
[wikidict](https://github.com/SmallThingz/wikidict).

This repository contains:

- a native Qt 6 reader using the core C ABI;
- a browser reader under `web/`.

Both consume compiled WIKBLB08/DPR2 presentation data. Lua, templates and wikitext
remain build-time concerns in the core repository.

## Native Qt reader

### Requirements

- CMake 3.21+
- C++20 compiler
- Qt 6.5+ with Core, Gui, Widgets, Concurrent, Network and Multimedia
- a built [wikidict](https://github.com/SmallThingz/wikidict) checkout

Build the core C ABI first:

```sh
cd ../wikidict
zig build ffi -Doptimize=ReleaseFast
```

Then build the desktop application:

```sh
cd ../wikidict-desktop
cmake -S . -B build \
  -DWIKIDICT_CORE=../wikidict \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/bin/dict-qt
```

Set `WIKIDICT_CORE` to the real core checkout when the repositories are not siblings.

Pass `--root <folder>` to open a dictionary directory explicitly. Otherwise the app
restores its previous dictionary folder and word.

### Reader features

- import raw `.wikblb` and compressed `.wikblb.xz` dictionaries;
- install from HTTPS catalogues with checksum validation;
- Unicode case-insensitive title search with exact-title preference;
- Saved, History and Learn views;
- section folding, tables, references and internal links;
- persistent themes, text size and reading state;
- opt-in image/audio loading with bounded caches;
- offline word speech through an installed matching-language `espeak-ng` or `espeak` voice.

Dictionary opening, indexing, imports and network work stay off the UI thread.

### Keyboard

| Shortcut | Action |
| --- | --- |
| `Ctrl+O` | Open Library |
| `Ctrl+L` | Focus search |
| `Up` / `Down` | Move through suggestions |
| `Enter` | Open the selected or typed word |
| `Escape` | Return to search |
| `Alt+Left` / `Alt+Right` | Previous / next word |
| `Ctrl+D` | Toggle saved word |
| `Ctrl+H` | Open History |
| `Ctrl+,` | Open Settings |
| `Ctrl++` / `Ctrl+-` | Change reading text size |

## Native validation

```sh
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The CTest suite uses compiled dictionary fixtures and isolates application settings
under the repository's `.tmp/` directory. Fixture provenance is documented in
[tests/README.md](tests/README.md).

## Web reader

The browser reader imports raw and compressed dictionaries directly, keeps dictionary
data and derived indexes in IndexedDB, and decodes entries in a worker.

```sh
cd web
pnpm install
pnpm build
```

Run its automated tests with:

```sh
pnpm test
pnpm test:browser
```

See [web/README.md](web/README.md) for browser-specific behavior and validation.

## Related

- [wikidict](https://github.com/SmallThingz/wikidict): compiler, blob format, CLI and C ABI
- [wikidict-android](https://github.com/SmallThingz/wikidict-android): native Android reader
