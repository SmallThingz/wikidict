# Dict Android

A native Kotlin/Jetpack Compose reader for Dict exports.

It opens `dict.results.v1` JSON produced by the CLI or other native Dict clients. Legacy self-contained HTML exports from older versions are still accepted by extracting their inert embedded JSON.

The app parses result JSON directly into Kotlin models and renders entries with Compose. It does not use WebView or depend on the desktop Qt frontend.

Product features are local/offline: entry search, source view, persistent history, bookmarks, appearance/learning settings, random words, definition quizzes, flashcards, and an unscramble game.

Security boundaries:

- no `INTERNET` permission;
- no broad storage permission; files come through Android document/content URI grants;
- no WebView or JavaScript/native bridge;
- imported files are capped at 64 MiB and must be UTF-8 Dict exports.

Build from this directory with `./gradlew :app:assembleDebug`. `lintDebug` and `testDebugUnitTest` are part of the validation gate.
