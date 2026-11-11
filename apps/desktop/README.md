# Wikidict Desktop

Desktop readers in the
[Wikidict project](../../README.md).

This directory contains:

- the native Qt 6 component of the unified `wikidict` application;
- a browser reader under `web/`.

The native Qt reader uses the selected core decoder for compiled WIKBLB08
presentation. Keep the CLI, C ABI library and headers from the same qualified
core build; decoder support and native layout support are separate capabilities.
The browser reader has its own decoder and validation. Older app versions may
refuse newer dictionary formats. Lua, templates and wikitext remain build-time
concerns in the core project.

Current desktop qualification includes compatible stored entries decoded by the
DPRL core and the supported plain-flow Container subset in the
[Qt qualification record](qt/README.md). It does not establish support for every
DPRL layout feature. Unsupported Container styles fail explicitly and retain the
entry source for recovery; future presentation extensions require separate
consumer implementation and qualification.

## Native Qt reader

### Requirements

- CMake 3.21+
- C++20 compiler
- The [pinned, patched Qt build](qt/README.md), including Core, Gui, Widgets,
  Concurrent, Network, Multimedia and Svg
- Zig 0.17.0 for the core and fixture generator
- a built Wikidict core CLI and C ABI from this repository

Logical paragraphs and figure captions require the maintained Qt patches. Stock
system Qt is not a supported substitute for those layout methods. Follow the
[Qt source and build recipe](qt/README.md) first, reusing a qualified build when
available. Keep the modules from the same pinned source set together.

The Linux install can include that matching runtime, its platform/media/image
plugins and its original license and attribution files. Confirmed original SVG
images use QtSvg directly. Cached raster thumbnails remain available offline;
Reload image fetches the original SVG through the ordinary opt-in media path.

From the Wikidict repository root, use the `qt_sources` and `qt_prefix` paths
selected in the Qt recipe. Create the notice inventory from those source trees,
then build and install the core and desktop application:

```sh
zig build cli ffi -Doptimize=fast
python3 tools/qt_runtime_notices.py \
  --qtbase "$qt_sources/qtbase" --qtsvg "$qt_sources/qtsvg" \
  --qtmultimedia "$qt_sources/qtmultimedia" \
  --selection apps/desktop/qt/notices-selection.json \
  --output-dir "$PWD/.tmp/qt-notices"
cmake -S apps/desktop -B .tmp/desktop-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$qt_prefix" \
  -DWIKIDICT_BUNDLE_QT_RUNTIME=ON \
  -DWIKIDICT_QT_RUNTIME_ROOTS="$qt_prefix" \
  -DWIKIDICT_QT_RUNTIME_NOTICES_MANIFEST="$PWD/.tmp/qt-notices/manifest.json"
cmake --build .tmp/desktop-build --parallel 2
cmake --install .tmp/desktop-build --prefix "$PWD/.tmp/desktop-install"
./.tmp/desktop-install/bin/wikidict-gio
```

`wikidict` is the single executable. `wikidict-gio` is a relative symlink to it;
that invocation loads the Qt component in the same process. Normal `wikidict`
commands use the CLI or TUI without loading Qt. The installed `dict` symlink
preserves existing CLI commands. Keep `bin/` and `lib/` together when relocating
an installation.

The notice generator requires a fresh output directory and verifies the selected
source bytes. Reuse its existing unchanged output for later installs. QtShaderTools
supplies build-time shader generation; it is not part of this runtime inventory.
For a development build that uses an externally managed patched Qt installation,
leave `WIKIDICT_BUNDLE_QT_RUNTIME` off and arrange the loader paths for that exact
installation. Do not mix it with stock Qt libraries or plugins.

To install a separately qualified CLI, C ABI library and header with an existing
GUI build, select their common prefix without changing the GUI's link inputs:

```sh
cmake -S apps/desktop -B .tmp/desktop-build \
  -DWIKIDICT_INSTALL_CORE_PREFIX=/absolute/path/to/qualified-core \
  -DWIKIDICT_INSTALL_COMPILED_HEADER=/absolute/path/to/retained-compiled/dict.h
ctest --test-dir .tmp/desktop-build --output-on-failure \
  -R '^native-(install-core-selection|unified-entry)$' --parallel 1
cmake --install .tmp/desktop-build --config Release --prefix "$PWD/.tmp/desktop-install"
./.tmp/desktop-install/bin/wikidict-gio
```

The prefix must contain `bin/wikidict`, the matching `libdictffi` library under
`lib/`, and `include/dict/dict.h`. The selected header must exactly match the
header used to compile the GUI. For a retained build, use its authenticated
compiled header, not a newer mutable source header. Leaving the prefix empty
preserves the normal build-time core installation. Header equality does not
replace qualification of the selected GUI/core pair. The relocation check
installs test support only inside its temporary prefix; the final normal install
omits it. Keep using the same configured source and build directories.

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
