# Android

The Android application is pure Kotlin + Jetpack Compose. It has no JNI/NDK/Zig/native library, no WebView, and no JavaScript bridge.

It consumes compiled `dict.results.v1` JSON presentation data. Wikitext, templates, Lua modules, and raw source are build-time inputs only and are never interpreted by the Android app.

Product features stay local/offline: dictionary search within the loaded package, persistent history, bookmarks, appearance/learning settings, random words, definition quizzes, flashcards, and an unscramble game.

Security boundaries:

- no `INTERNET` permission;
- no broad storage permission; files come through Android document/content URI grants;
- imported packages are capped at 64 MiB and must be UTF-8 compiled Dict JSON;
- no fallback HTML/wikitext/template renderer exists in the app.

Build from this directory with `./gradlew :app:assembleDebug`. `lintDebug` and `testDebugUnitTest` are part of the validation gate.

Device renderer tests use the semantic fixture emitted by `zig build test-reader`:

```sh
./gradlew -PrendererFixture=/absolute/path/to/fixture.json :app:connectedDebugAndroidTest
```

Add `-PcorpusFixture=/absolute/path/to/corpus-cat.json` to exercise an actual `dict export cat` result from a built corpus. Use JDK 21 and the configured Android SDK. Leave the device unlocked and awake while tests run. Tests cover inline styles, Unicode, preformatted whitespace, table spans, references/media descriptors, search, themes, rotation and activity recreation. The app currently imports JSON exports, not entire `.wikblb` collections; media playback is not implemented.
