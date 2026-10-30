# Wikidict Desktop

Desktop readers for dictionaries produced by
[wikidict](https://github.com/SmallThingz/wikidict).

This repository contains:

- the native Qt 6 component of the unified `wikidict` application;
- a browser reader under `web/`.

The native Qt 0.4.0 reader and browser reader support compiled WIKBLB08
presentation in DPR2 and DPR3 formats, including DPR3 abbreviation explanations.
Older app versions do not support DPR3 dictionaries; update the app before
importing them. Lua, templates and wikitext remain build-time concerns in the core
repository.

## Native Qt reader

### Requirements

- CMake 3.21+
- C++20 compiler
- Qt 6.5+ with Core, Gui, Widgets, Concurrent, Network and Multimedia
- Zig 0.17.0 for the core and fixture generator
- a built [wikidict](https://github.com/SmallThingz/wikidict) checkout

Point `CORE` at a wikidict checkout and build its CLI and C ABI first:

```sh
CORE=/path/to/wikidict
(cd "$CORE" && zig build cli ffi -Doptimize=fast)
```

Then, from this repository, build the desktop application against that checkout:

```sh
cmake -S . -B build \
  -DWIKIDICT_CORE="$CORE" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
cmake --install build --prefix "$PWD/build/install"
./build/install/bin/wikidict-gio
```

`wikidict` is the single executable. `wikidict-gio` is a relative symlink to it;
that invocation loads the Qt component in the same process. Normal `wikidict`
commands use the CLI or TUI without loading Qt. The installed `dict` symlink
preserves existing CLI commands. Keep `bin/` and `lib/` together when relocating
an installation.

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

Each native dictionary folder holds one edition and snapshot. Extract a complete
edition archive into its own folder, then open that folder. Individual release
files named `<edition>-<YYYYMMDD>-<blob filename>` can be imported together into
an empty folder; the reader rejects files from another edition or date there.
Import the matching `aliases.wikblb` file to include redirects. Existing folders
of manually named files remain readable; use a new folder for named releases.

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
