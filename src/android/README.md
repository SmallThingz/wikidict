# Dict Android

A small offline host for the same renderer used by the web frontend.

It opens either:

- self-contained HTML produced by `dict export ... --format html`, or
- `dict.results.v1` JSON produced by the CLI.

The app bundles `src/frontend/web/dist/index.html` as an Android asset. JSON is injected into the same inert `dict-data` slot used by the desktop HTML exporter, so Android and browser rendering share one presentation implementation.

Security boundaries:

- no `INTERNET` permission;
- no broad storage permission; files come through Android's document/content URI grants;
- no JavaScript-to-native bridge;
- WebView file/content access and network loading are disabled;
- external HTTP(S) links are handed to the user's browser;
- imported files are capped at 64 MiB and must be UTF-8 Dict exports.

Build from this directory with `./gradlew :app:assembleDebug`. The web frontend must be built first so `../frontend/web/dist/index.html` is current.
