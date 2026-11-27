# Odia inline audio entries

These two unmodified, single-record WIKBLB08 members were emitted and verified by ordinary Writer24 from the 20261001 Odia Wiktionary input. The audio transport is inside a table cell at 175 CSS px with automatic height. The adjacent Image action remains separate.

| Fixture | Page ID | Revision and contributors |
| --- | --- | --- |
| `686.wikblb` | 2613 | [174489](https://or.wiktionary.org/w/index.php?oldid=174489) |
| `3667.wikblb` | 5706 | [193036](https://or.wiktionary.org/w/index.php?oldid=193036) |

The browser test checks the raw member and presentation payload hashes before lookup. It supplies a controlled silent WAV and aborts unrecognized requests. The fixture members contain compiled text and media identifiers. The recordings themselves are absent.

From `desktop/web`, use `node audio-transport.browser.test.mjs --fixtures-only` for the fixture checks or `node audio-transport.browser.test.mjs` for the focused browser test.
