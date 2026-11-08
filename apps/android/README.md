# Wikidict Android

Native Android reader for Wiktionary dictionaries produced by
[wikidict](../../README.md). This Gradle project lives at `apps/android` in the
same repository as the compiler and desktop readers.

The app reads compiled WIKBLB08 dictionaries with DPR2 through DPRG presentation data directly. It does not ship a WebView, Lua
runtime, wikitext parser or JSON dictionary format.

Newer presentation versions preserve explanations, colors, anchors, nested tables
and reference fragments. Older readers may refuse newer dictionaries; update the
reader before importing them.

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
on-demand DPR2-DPRG decode
```

Only the selected record is decoded. Compressed dictionaries stay compressed on
disk; lookups decode the XZ blocks that intersect the requested record.

## Use

The **Dictionaries** screen can:

- download from a configured catalogue when it is available;
- add custom HTTPS `.list` catalogues;
- import local `.wikblb` or `.wikblb.xz` files;
- replace or remove installed dictionaries.

Configured default catalogue URL:

```text
https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list
```

Official releases and their assets are currently withdrawn. During testing, import
locally built dictionaries or use your own catalogue. The configured URL remains
unchanged; publication is on hold until explicitly approved again.

The catalogue format is documented in the
[catalogue documentation](../../docs/catalogues.md).

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
- Android NDK 29.0.14206865 and CMake 3.22.1

The application targets Android 37 and supports Android 28+. Run these commands
from the repository root; the wrapper and Gradle project remain app-local:

```sh
./apps/android/gradlew -p apps/android :app:assembleDebug
./apps/android/gradlew -p apps/android :app:testDebugUnitTest
```

For an optimized, locally installable profiling build:

```sh
./apps/android/gradlew -p apps/android :app:assemblePerformance
```

The `performance` variant uses release optimization with debug signing. Production
release signing is configured separately.

### Qualification after relocation

Keep the existing `GRADLE_USER_HOME` (normally `~/.gradle`) and Android SDK/NDK
installation. Put a machine-specific `sdk.dir` in ignored
`apps/android/local.properties` only if SDK environment variables are insufficient.
Do not copy the old checkout's `.gradle`, `.kotlin`, `app/.cxx`, `build`,
`app/build` or `artifacts` directories: their outputs can contain old absolute paths.

A fresh unit-test report and lint run can reuse cached dependencies and compilation
outputs:

```sh
./apps/android/gradlew -p apps/android --offline --no-daemon --max-workers=2 \
  :app:cleanTestDebugUnitTest :app:testDebugUnitTest :app:lintDebug
```

The targeted test clean refreshes test results without cleaning native or Kotlin
compilation. If offline resolution reports a missing dependency, arrange its
download separately; do not treat that failure as a source failure. Set the admitted
job's memory, CPU and deadline limits outside Gradle. Retain its actual exit status,
JUnit XML and lint reports under `apps/android/app/build` before claiming a pass;
an up-to-date task or an old report does not establish a fresh test run.

Host tests and lint do not establish native glyph fidelity or physical-device
behavior. Validate those on an actual device while preserving its installed data
and signing identity.

## Tests and fixtures

Debug builds use a local 30-word English corpus slice through the same installer and
decoder path as normal dictionaries. It is a development fixture, not a bundled
release dictionary.

Fixture provenance is in
[app/src/debug/ATTRIBUTION.md](app/src/debug/ATTRIBUTION.md).

Instrumentation tests cover binary installation, malformed data, search, settings,
media and UI state. Live Wikimedia media tests are opt-in:

```sh
./apps/android/gradlew -p apps/android :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.liveMedia=true
```

For the reader scroll benchmark, open `cat` in the app first, then run:

```sh
python3 apps/android/tools/benchmark_android_reader.py \
  --report apps/android/artifacts/scroll \
  --variant performance
```

## Related

- [wikidict](../../README.md): compiler, blob format, CLI and C ABI
- [desktop readers](../desktop/README.md): Qt and web readers
