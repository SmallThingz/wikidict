# Android validation — 2026-09-23

Device: Xiaomi M2101K7BG, Android API 36. The screen remained awake; tests do not lock it.

- Eight JVM tests passed: binary corpus decoding, malformed/truncated records, catalogue validation, lazy paragraph splitting, folding with nested definitions, and table placement.
- Four instrumentation tests passed with live Wikimedia enabled: install/search/decode all 32 English records, random lookup, checksum failure preserving the library, fold/search/theme/recreation, real image/audio download and decode, cache reuse and zero-limit eviction.
- `assemblePerformance` and `lintDebug` passed. Lint reported warnings, no errors; only application context is retained by the library singleton.
- The corpus slice was rebuilt through the core native expander and encoder: 64 selected pages produced 474 language records across 280 language blobs plus a reconstruction record. Core blob verification passed. The Android fixture includes the 32 English records, not a complete language corpus.
- Core `zig build test`, `test-bundle`, `test-reader`, and `ffi` passed. The separated Qt application built and its offscreen startup test passed; web build and three validator tests passed. This does not establish platform feature parity.

## Scroll measurement

Optimized, locally debug-signed `performance` APK; actual binary `cat` record; images enabled; 12 forward and 12 backward swipes of 400 ms. Android gfxinfo reported 617 rendered frames, 31 janky frames (5.02%), median 9 ms, p95 15 ms, p99 24 ms. This is one bounded device smoke run, not a corpus-wide benchmark or a claim of zero jank. Screenshots and raw gfxinfo are retained locally under ignored `artifacts/validation/`.

## Network diagnosis

The installed app's `INTERNET` permission was granted. GitHub resolved on the phone, but Commons, Wiktionary, Wikipedia and Wikimedia uploads did not resolve with the device's `dns.adguard.com` Private DNS setting. With user approval, switching temporarily to Automatic restored Wikimedia resolution and all four live tests passed. The original Private DNS setting was restored afterward. Cached dictionary/media data remain usable offline; uncached Wikimedia assets remain subject to that device DNS configuration.

## HTTPS catalogue and installation

The optimized APK was tested without development assets. A custom GitHub-hosted `.list` was added through the Dictionaries screen while the unpublished default returned HTTP 404. The custom list still loaded. The installed 32-word slice was removed and downloaded again over HTTPS (4,173,468 bytes, SHA-256 verified), indexed, and the saved `cat` lookup reopened from the installed binary. The development catalogue is `tools/catalogues/development.list`; its label explicitly distinguishes it from a complete dictionary.

## Release limits

The default catalogue URL points at `SmallThingz/wikidict`'s latest release asset `dictionaries.list`. No complete corpus or production release has been published. The GitHub-hosted development list is explicitly labelled as a 32-word test slice. Release/performance APKs contain no bundled development dictionary. Background downloads are process-bound and do not yet resume across process death; interrupted temporary files are removed on the next launch.
