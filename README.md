# Wikidict Android

Native Android reader for Wiktionary dictionaries produced by
[wikidict](https://github.com/SmallThingz/wikidict).

The app reads compiled WIKBLB08 dictionaries with DPR2 or DPR3 presentation data directly. It does not ship a WebView, Lua
runtime, wikitext parser or JSON dictionary format.

DPR3 dictionaries preserve abbreviation explanations and require reader version 0.4.0
or newer. This reader also supports existing DPR2 dictionaries. Older readers refuse
unsupported DPR3 imports; update the reader before installing new DPR3 data.

## Data path

```text
.wikblb / .wikblb.xz
        |
        v
streaming validation + install
        |
        v
SQLite title / offset index
        |
        v
on-demand DPR2 / DPR3 decode
```

Only the selected record is decoded. Compressed dictionaries stay compressed on
disk; lookups decode the XZ blocks that intersect the requested record.

## Use

The **Dictionaries** screen can:

- download from the default catalogue;
- add custom HTTPS `.list` catalogues;
- import local `.wikblb` or `.wikblb.xz` files;
- replace or remove installed dictionaries.

Default catalogue:

```text
https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list
```

The catalogue format is documented in the
[core repository](https://github.com/SmallThingz/wikidict/blob/main/docs/catalogues.md).

The reader provides search, saved words, history and study modes. Pronunciation and
etymology sections can be folded independently. Online images and audio are opt-in
and use bounded caches. Word speech uses an installed Android TTS voice; no speech
engine is bundled.

HTTPS dictionary downloads use Android DownloadManager and are verified before
installation.

## Build

Requirements:

- JDK 21
- Android SDK 37
- Android build-tools 37.0.0

The application targets Android 37 and supports Android 28+.

```sh
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:connectedDebugAndroidTest
```

For an optimized, locally installable profiling build:

```sh
./gradlew :app:assemblePerformance
```

The `performance` variant uses release optimization with debug signing. Production
release signing is configured separately.

## Tests and fixtures

Debug builds use a local 30-word English corpus slice through the same installer and
decoder path as normal dictionaries. It is a development fixture, not a bundled
release dictionary.

Fixture provenance is in
[app/src/debug/ATTRIBUTION.md](app/src/debug/ATTRIBUTION.md).

Instrumentation tests cover binary installation, malformed data, search, settings,
media and UI state. Live Wikimedia media tests are opt-in:

```sh
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.liveMedia=true
```

For the reader scroll benchmark, open `cat` in the app first, then run:

```sh
python3 tools/benchmark_android_reader.py \
  --report artifacts/scroll \
  --variant performance
```

## Related

- [wikidict](https://github.com/SmallThingz/wikidict): compiler, blob format, CLI and C ABI
- [wikidict-desktop](https://github.com/SmallThingz/wikidict-desktop): Qt and web readers
