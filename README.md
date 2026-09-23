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

The `web/` reader now imports raw `.wikblb` and seekable `.wikblb.xz` directly. It keeps binary files and derived indexes in IndexedDB, decodes individual entries in a worker, and provides Saved, History, Search, Learn and Settings. Build with `cd web && pnpm install && pnpm build`; serve `build/web/` over localhost or HTTPS. See [web validation and capabilities](web/README.md).

Android is maintained in [wikidict-android](https://github.com/SmallThingz/wikidict-android).
