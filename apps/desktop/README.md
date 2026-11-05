# Wikidict Desktop

Desktop readers in the
[Wikidict project](../../README.md).

This directory contains:

- the native Qt 6 component of the unified `wikidict` application;
- a browser reader under `web/`.

The native Qt reader uses the core decoder for compiled WIKBLB08 presentation,
including DPR2 through DPR9. The browser reader has its own decoder and validation.
Older app versions may refuse newer dictionary formats. Lua, templates and
wikitext remain build-time concerns in the core project.

## Native Qt reader

### Requirements

- CMake 3.21+
- C++20 compiler
- Qt 6.5+ with Core, Gui, Widgets, Concurrent, Network, Multimedia and Svg
- Zig 0.17.0 for the core and fixture generator
- a built Wikidict core CLI and C ABI from this repository

The native install uses the system Qt libraries, including QtSvg; it does not
bundle a separate Qt runtime. Confirmed original SVG images use the linked native
QtSvg renderer directly, so their rendering does not require an SVG imageformat
plugin. Existing cached raster thumbnails remain available offline; Reload image
fetches the original SVG through the ordinary opt-in media path.

From the Wikidict repository root, build the core and desktop application:

```sh
zig build cli ffi -Doptimize=fast
cmake -S apps/desktop -B .tmp/desktop-build \
  -DCMAKE_BUILD_TYPE=Release
cmake --build .tmp/desktop-build --parallel
cmake --install .tmp/desktop-build --prefix "$PWD/.tmp/desktop-install"
./.tmp/desktop-install/bin/wikidict-gio
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
cmake --build .tmp/desktop-build --parallel
ctest --test-dir .tmp/desktop-build --output-on-failure
```

The CTest suite uses compiled dictionary fixtures and isolates application settings
under the owned build directory. Fixture provenance is documented in
[tests/README.md](tests/README.md).

## Web reader

The browser reader imports raw and compressed dictionaries directly, keeps dictionary
data and derived indexes in IndexedDB, and decodes entries in a worker.

```sh
cd apps/desktop/web
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

- [Wikidict core](../../README.md): compiler, blob format, CLI and C ABI
- [Android app](../android/README.md): native Android reader
