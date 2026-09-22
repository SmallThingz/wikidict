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

The default catalogue URL points at `SmallThingz/wikidict`'s latest release asset `dictionaries.list`. No complete corpus or production release has been published. The GitHub-hosted development list is explicitly labelled as a development test slice. Release/performance APKs contain no bundled development dictionary. Background downloads are process-bound and do not yet resume across process death; interrupted temporary files are removed on the next launch.


## Syntax and offline speech follow-up

The fixture now has 30 entries. February and pound are explicitly excluded because
literal source delimiters remain in quotations; no quotation text was silently
rewritten. The core compiler rejects such records at build time, including markup
split across spans. The fixture's device test scans all headings, span groups,
tables, references and media captions for leaked source syntax.

Image display has 12 dp top spacing and no redundant image icon after expansion.
Word pronunciation uses an installed offline Android voice. The explicit English
IPA subset in `Pronunciation.kt` uses eSpeak NG SSML phonemes; unsupported IPA is
not guessed, and other local engines remain available for ordinary word reading.
The official eSpeak NG 1.52.0 engine was installed on the test phone. Device tests
verified local WAV synthesis and distinct audio for distinct phoneme sequences.
This establishes execution, not linguistic accuracy across accents/languages.

Final validation: nine JVM tests passed; four instrumentation tests passed and the
opt-in live network test was skipped in this run (its earlier live run passed).
An additional speech instrumentation run passed with Wi-Fi disabled, then Wi-Fi
was restored. Core `zig build test test-bundle` passed, and a real guarded bundle
build stopped at `gratis` with `UncompiledPresentation`, as intended.

The final optimized scroll smoke recorded 608 frames, 31 janky frames (5.10%),
p50 10 ms, p95 15 ms and p99 24 ms for the same 24-swipe `cat` workload. This is
similar to the earlier run, not a demonstrated speedup or a zero-jank result.
Final screenshots show the image spacing and removed expanded-image icon.
Private DNS was restored to `hostname` / `dns.adguard.com`; Wi-Fi is enabled and
the device was left awake. The installed app is the optimized performance build.

## Meanings-first reading, sliders and speech correction — 2026-09-23

Supporting sections (including alternative forms, derived terms and translations)
now start folded. Sections containing definitions stay open, while a notes toggle
on their heading reveals forms, examples, quotations and media in original order.
Pronunciation and etymology keep their separate preferences. Overview, preamble,
references and remaining media also start folded. Existing settings files default
the two new folding preferences to enabled.

Repeated semantic breaks and whitespace-only lazy rows no longer create empty
vertical space; literal preformatted content keeps its whitespace. Failed image
loads animate away the reserved image area. Media cache (0–1024 MB) and remembered
words (0–500, zero disables history) use logarithmic sliders. Questions per round
uses a linear integer slider (3–50). Dragging only changes local UI state; settings
writes and cache trimming occur on release. Accessibility adjustments also commit.

The earlier IPA playback claim was incorrect. Distinct/nonempty WAVs were an
insufficient test: eSpeak Android 1.52.0 sends SSML without enabling phoneme input,
and its SSML phoneme implementation emits ordinary bracketed phoneme text. Our
app also incorrectly selected `en-029` (Jamaican English) ahead of the configured
`en-gb-x-rp` voice by alphabetical order. The broken IPA conversion/play buttons
were removed. The ordinary word speaker now honors the configured offline voice
and sends the actual word; IPA transcription remains dictionary text, and
recorded pronunciations remain available.

Evidence: the old path produced 63,918 WAV bytes for the phonetic request for
“elephant”, versus 22,072 bytes for the actual word with RP. Code inspection:
[eSpeak Android bridge](https://github.com/espeak-ng/espeak-ng/blob/1.52.0/android/jni/jni/eSpeakService.c#L313)
and [SSML handling](https://github.com/espeak-ng/espeak-ng/blob/1.52.0/src/libespeak-ng/ssml.c#L751).
The replacement tests verify configured-voice selection, local synthesis of
“elephant”, “cat” and “January”, and rejection of unavailable/network voices.
They do not claim human-listening assessment or universal phonetic accuracy.

13 JVM tests and six device tests passed; the opt-in live network test was skipped.
Device tests cover default folds, revealing notes, slider accessibility commits,
binary decoding and source-leak checks, and offline speech. Screenshots and logs
are retained locally in `artifacts/validation/meanings-first/`.

### Navigation and capacity follow-up — 2026-09-23

- Word scrolling animates the dock away on downward movement and restores it on upward movement; opening another word or screen resets visibility.
- Search is centered; dictionary management is reached from Settings. Learn flashcards use 16 dp corners.
- Logarithmic history limit now reaches 100,000 words; media cache reaches 4096 MB (4 GB), including persisted-setting clamps. Cache byte arithmetic already uses Long.
- Unit tests passed, including slider round trips across the expanded ranges. Device slider test passed at both endpoints and restored defaults. Manual device checks confirmed dock hiding/reappearance and Settings → Dictionaries navigation. Optimized build installed; screenshot: `artifacts/validation/navigation/cards.png`.
- This validates the configured limits, not performance with 100,000 populated history records or 4 GB of cached media.
