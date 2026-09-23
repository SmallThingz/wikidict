# Wikidict Android

A native Kotlin/Compose reader for downloadable Wiktionary dictionaries. The reading surface uses Newsreader typography, a compact bottom dock, independently folding sections and themed controls.

Dictionary content comes directly from **WIKBLB08/DPR2** binary files. Downloads stream to disk, verify advertised size and SHA-256, and build a SQLite title/offset index. A lookup reads and decodes one binary record. There is no JSON dictionary import, WebView, Lua engine or wikitext parser.

## Use

Open **Dictionaries** to download a language or import a local `.wikblb` file. Add your own HTTPS `.list` sources there. The default release catalogue is:

`https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list`

See the [catalogue specification](https://github.com/SmallThingz/wikidict/blob/main/docs/catalogues.md). The default URL becomes available when a release with `dictionaries.list` is published. This repository does not pretend a complete corpus has been published.

Tap the dictionary dock icon again to search installed languages. Pronunciation and Etymology start folded; change those defaults in Settings. Enable online images and audio separately. Media caches can be disabled or limited to 25, 100 or 500 MiB, and cleared independently of dictionaries. Cached assets remain available without network; audio downloads only after tapping Play.

Debug builds replace the default remote catalogue with a local **30-word English corpus slice**, using the same binary installer and lookup path. Custom sources still use HTTPS. This is explicitly a development fixture, not a complete dictionary or the release application. [Fixture sources and attribution](app/src/debug/ATTRIBUTION.md).

## Build and test

Use JDK 21 and an Android SDK containing API 37/build-tools 37.0.0:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
./gradlew :app:assemblePerformance
```

`performance` enables release optimization with local debug signing for device profiling. It does not contain the development dictionary or local catalogue. Production release signing is configured separately.

Live Wikimedia tests require a connected device with working internet; opt in with `-Pandroid.testInstrumentationRunnerArguments.liveMedia=true`. The remaining tests validate the real binary corpus, corrupt/truncated records, catalogue URLs/checksums, installation, search, collapse controls and recreation. For a scroll smoke benchmark, open `cat` first and run `python3 tools/benchmark_android_reader.py --report artifacts/scroll --variant performance`.

[Core compiler/encoder/decoder](https://github.com/SmallThingz/wikidict) · [Desktop](https://github.com/SmallThingz/wikidict-desktop)

This repository preserves the original Android file history from the core project.

Local pronunciation speaks the word using the configured installed Android offline
voice. IPA remains visible as dictionary data; the app does not feed phonetic codes
to text voices. The app does not bundle a TTS engine.

Compressed dictionaries: imports and catalogue downloads accept raw `.wikblb` and `.wikblb.xz` (detected by magic). Installation scans the logical stream into SQLite without writing an expanded copy. Lookups seek to the recorded logical offset and decode the intersecting XZ blocks. Publish XZ with independent 1 MiB blocks (`xz -9e --block-size=1MiB -k dictionary.wikblb`) for bounded random-access work. Legacy single-block files work but may require decoding much more data for a lookup. The XZ decoder has a 128 MiB memory limit.

HTTPS dictionary transfers use Android DownloadManager with system notification progress and automatic network retry/resume. The library shows bytes and percentage and reattaches after app restart, then verifies and indexes the completed file. Cancel deliberately discards the transfer. No separate download app is required. A connected device completed a real HTTPS DownloadManager transfer and read a host-compressed extreme XZ dictionary; interruption and process-restart recovery remain to be exercised.
