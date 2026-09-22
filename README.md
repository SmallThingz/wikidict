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

Local pronunciation uses installed Android offline voices. Supported English IPA
transcriptions can use eSpeak NG phoneme input; unsupported transcriptions are not
fed to a text voice. The app does not bundle a TTS engine.
