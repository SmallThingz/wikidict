# Wikidict Android

Native Android reader for Wiktionary dictionaries produced by
[wikidict](../README.md). This Gradle project lives at `android` in the
same repository as the compiler and desktop readers.

The app reads compiled WIKBLB08 dictionaries directly. Its native Kotlin decoder
recognizes DPR2 through DPR9, DPRA through DPRV, and the supported DPRY, DPRZ and
DPRa feature flags. These versions carry formatting such as ruby annotations,
nested tables, reference fragments, inherited cell ink and automatic inline-box
sizing. A reader that reports an unsupported record version or feature combination
needs a compatible build.

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
on-demand DPR entry decoding
```

Only the selected record is decoded. Compressed dictionaries stay compressed on
disk; lookups decode the XZ blocks that intersect the requested record.

## Use

The **Dictionaries** screen can:

- download from a configured catalogue when it is available;
- add custom HTTPS `.list` catalogues;
- import local `.wikblb` or `.wikblb.xz` files;
- replace or remove installed dictionaries.

On a fresh release or performance-build installation, the catalogue list starts
empty. Open **Dictionaries** and import a local `.wikblb` or `.wikblb.xz` file, or
use **Add catalogue** to enter an HTTPS list. Existing installations keep their
saved sources. The official releases and assets have been withdrawn.

The catalogue format is documented in the
[catalogue documentation](../compiler/docs/catalogues.md).

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

The native Egyptian glyph shaper is in [renderer/src/shaping/android](../renderer/src/shaping/android/). The Android CMake target builds it with the HarfBuzz sources vendored in this app.

The application targets API 37 and supports Android 12 (API 31) or newer. Run these commands
from the repository root; the wrapper and Gradle project remain app-local:

```sh
./android/gradlew -p android :app:assembleDebug
./android/gradlew -p android :app:testDebugUnitTest
```

For an optimized, locally installable profiling build:

```sh
./android/gradlew -p android :app:assemblePerformance
```

The `performance` variant uses release optimization with debug signing. Production
release signing is configured separately.

### Qualification after relocation

Keep the existing `GRADLE_USER_HOME` (normally `~/.gradle`) and Android SDK/NDK
installation. Put a machine-specific `sdk.dir` in ignored
`android/local.properties` only if SDK environment variables are insufficient.
Do not copy the old checkout's `.gradle`, `.kotlin`, `app/.cxx`, `build`,
`app/build` or `artifacts` directories: their outputs can contain old absolute paths.

A fresh unit-test report and lint run can reuse cached dependencies and compilation
outputs:

```sh
./android/gradlew -p android --offline --no-daemon --max-workers=2 \
  :app:cleanTestDebugUnitTest :app:testDebugUnitTest :app:lintDebug
```

The targeted test clean refreshes test results without cleaning native or Kotlin
compilation. If offline resolution reports a missing dependency, arrange its
download separately; do not treat that failure as a source failure. Set the admitted
job's memory, CPU and deadline limits outside Gradle. Retain its actual exit status,
JUnit XML and lint reports under `android/app/build` before claiming a pass;
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
./android/gradlew -p android :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.liveMedia=true
```

For the reader scroll benchmark, open `cat` in the app first, then run:

```sh
python3 android/tools/benchmark_android_reader.py \
  --report android/artifacts/scroll \
  --variant performance
```

## Related

- [wikidict](../README.md): compiler, blob format, CLI and C ABI
- [desktop readers](../desktop/README.md): Qt and web readers
