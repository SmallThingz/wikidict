# Dict Android

A native Kotlin/Jetpack Compose reader for Dict exports.

It opens either:

- self-contained HTML produced by `dict export ... --format html`, or
- `dict.results.v1` JSON produced by the CLI.

The app parses the embedded/result JSON directly into Kotlin models and renders entries with Compose. It does not use WebView or bundle the web frontend.

Product features are local/offline: entry search, source view, persistent history, bookmarks, appearance/learning settings, random words, definition quizzes, flashcards, and an unscramble game.

Security boundaries:

- no `INTERNET` permission;
- no broad storage permission; files come through Android document/content URI grants;
- no WebView or JavaScript/native bridge;
- imported files are capped at 64 MiB and must be UTF-8 Dict exports.

Build from this directory with `./gradlew :app:assembleDebug`. `lintDebug` and `testDebugUnitTest` are part of the validation gate.
