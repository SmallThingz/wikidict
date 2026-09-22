# Wikidict desktop

Qt desktop and web presentation work, split from [wikidict](https://github.com/SmallThingz/wikidict) with the original commits for these files preserved.

The native desktop reader opens `.wikblb` dictionaries through the core C ABI. Lua compilation and dictionary encoding belong to the core repository.

## Build Qt

Build the sibling core checkout with its configured Zig toolchain:

```sh
cd ../wikidict
zig build ffi -Doptimize=ReleaseFast
cd ../wikidict-desktop
cmake -S . -B build -DWIKIDICT_CORE=../wikidict -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 2
./build/bin/dict-qt
```

The `web/` directory retains the earlier compiled-presentation browser renderer and its tests. Its export-based loading flow has not yet been migrated to direct `.wikblb` downloads; Android is the current product focus. It is not a feature-parity release.

Android is maintained in [wikidict-android](https://github.com/SmallThingz/wikidict-android).
