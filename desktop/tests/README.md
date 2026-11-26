# Native UX fixtures

`fixtures/languages.tsv` and its English `.wikblb` contain 182 synthetic compiled
presentation records: `cat`, `dog`, and `page001` through `page180`. They exercise
paging and rich presentation without shipping or evaluating wikitext, templates or
Lua. The content derives from the core's data-only reader integration fixture at
commit `cd7e511`, extended with additional titles. It is test data, not a complete
dictionary or a whole-corpus performance workload. `fixtures/thesaurus.wikblb`
contains one matching synthetic record encoded as the actual thesaurus kind; it
checks startup when a folder has no language dictionaries or manifest.

The blob SHA-256 is:

```
db3c875bf3f4415ccd2df7bf174bddbd8df188071f4e4c38df2aa28ddbb49fd4
```

The thesaurus blob SHA-256 is:

```
df626983893d887931379c19f32557c038567e3391cc3cfe86749bf011b1fe1e
```

To regenerate using this repository's compatible core and Zig 0.17.0 toolchain,
from `desktop`:

```sh
zig run -O safe --cache-dir .tmp/fixture-cache \
  --dep blob_encoder -Mroot=tests/generate_fixture.zig \
  -Mblob_encoder=../compiler/src/encoder/blob_root.zig -- tests/fixtures
```

The relative core path points to the repository root. The generator calls the
actual presentation encoder and blob builder. Regeneration was checked byte for
byte against the committed fixture.

`MainWindowTest` copies the blob into an isolated `.tmp` directory before opening
it, because the core writes a derived title cache beside dictionary files. It uses
real Qt input events and renders light, dark and compact screenshots under
`.tmp/ui-screenshots`. Each UI harness isolates config, cache and data paths before
constructing QApplication, redirects both native and INI QSettings formats/scopes,
and checks the effective settings paths. CTest runs from the build directory, so
these artifacts and its outer XDG directories under `.tmp/ctest` stay there.
The fixture paths remain anchored to the source checkout.

Three compositor tests load compressed ordinary Reader exports into memory.
The Korean and Serbian exports match the original desktop captures byte for
byte. The Korean Writer record is
`android/app/src/test/resources/zh-geoyigsimjo-c06.wikblb`. The Serbian
presentation payload is
`android/app/src/androidTest/assets/captured-sr-current212.dprj`. To read the
latter independently, frame the payload with the standard WIKBLB08 language
header for `sr` and `Српски`, followed by the NUL-terminated title `Србија`,
its unsigned varint payload length and the original payload bytes.

The Italian default comes from the official 20261001 Italian Wiktionary page
58290, revision 4263306, at zero-based ordinal 41030. The ordinary Writer read
one page from the prepared multistream archive with its original worker and
the tracked historical snapshot
`compiler/tools/testdata/figure-page-observations/it/figure-page-observations.json`.
That snapshot contains observations for `poliziotto`. The Writer emitted two
language records. The `italiano` record has SHA-256
`5c95c03380e89544911e93b85c19f91bf887806a344dc58cb0bffe34d45c2651`.
The earlier 270465-byte desktop capture remains unlocated. An explicit
`WIKIDICT_IT_PIANOFORTE_READER_JSON` still checks its original digest.

Each capture uses `wikidict export TITLE --case-sensitive --language HEADING
--root DICTIONARY`. The compressed fixture stores the stdout length as four
big-endian bytes followed by its zlib stream, as expected by `qUncompress`.
The tests pin the SHA-256 of the decompressed bytes.

On Linux, `native-unified-entry` installs the application twice into an isolated
directory, relocates that install, checks the `wikidict-gio` symlink and library
paths, runs CLI help without a display or Qt, and launches the real GUI entry with
copied fixtures. A test-only preload isolates
all QSettings paths before QApplication; it is not installed with the application.
This startup check complements the rendered reader and interaction tests.

`LibraryStoreTests` checks staged raw/compressed import, structural validation,
checksums, cancellation and removal. `LibraryDialogTests` drives the actual file
picker and confirmation dialogs. Both may also accept another raw `.wikblb` path
to validate a real dictionary; CTest supplies the committed fixture for the GUI.

`MediaPanelTest` supplies controlled HTTPS replies and a local fake speech process.
It tests the boundary between permission, downloading, caching and playback without
accessing public media or depending on an installed voice or sound device.

`fixtures/alias-cases/aliases.wikblb` contains six synthetic DAL1 redirect records
with presentation encoded by the same core generator. It covers an ordinary
target, one-edge traversal through another alias, an absent target, a neutral
alias-only library and a Unicode supplemental title. Its SHA-256 is
`6a612c395d676f87e66a3f7bfe1f71156f081cef4440607e9add1a875a9af6f6`.
The nested directory keeps these aliases out of the existing 182-entry fixture.
Regenerate this fixture with the same Zig 0.17 command shown above.

Import validation checks DAL1 identities, namespaces, text encoding and framing,
plus the nested presentation magic. The core reader performs full presentation
decoding; a separate test corrupts a nested presentation and requires lookup to
fail safely. Edition tests check that canonical release filenames bind an empty
library only after a successful import, preserve that binding on failures, and
reject mixed editions, dates or unlabelled files in a bound library.
Language-heading tests preserve an initial U+FEFF through import, SHA-256 naming,
the language manifest and installed metadata; it is part of the binary identity.
The reader regression also searches and opens a BOM-prefixed title through the
JSON API, which must preserve the same heading and title identities.

`fixtures/fragment-cases/` contains one synthetic English `cat` record with Etymology after Noun. The alias search regression uses it to verify scrolling and unfolding a later destination; the original 182-entry fixture is unchanged.

## Native abbreviation interoperability fixture

`fixtures/abbreviation-interop/` supplies the ordinary native test-bundle's small
English blob and `annotated.export.json` / `legacy.export.json`. The synthetic
Acupuncture abbreviation sample uses seven verbatim captured abbreviation
contexts and actual DPR3 output; Legacy format abbreviation control uses fresh
unannotated DPR2 output. This is interoperability test data, not corpus acceptance.
The fixture must be copied from a qualified core `zig build test-bundle` output,
with its producer receipt and exact asset hashes retained before qualification.
No manually framed or JSON-only substitute is accepted. Missing files fail tests.
The standard CTest fixture copy includes this directory; an optional
`DICT_ABBREVIATION_INTEROP_ROOT` selects a fresh generated root instead.
The reader test imports the real blob through LibraryStorage, compares complete
FFI Entry objects to the normal CLI exports, and checks native rendered labels,
explanations, glossary links and navigation to the unannotated control before
separate synthetic styling and keyboard edge cases.

## Styled empty-table interoperability fixture

`fixtures/empty-table-interop/` retains the complete normal CLI JSON response and
DPRJ payload for `styled-empty-table-contract`. The ordinary core test-reader
`checkWriterStyledEmptyTable` compiles authored all-hidden rows through Writer,
retaining the caption and following link, all eight table style fields, and zero
cells. It verifies full typed-codec and CLI parity before writing these assets.
`provenance.json` records the exact earned source and artifact hashes. This is a
small controlled interoperability fixture, not a dictionary or corpus claim.

The default `retainedWriterEmptyTableKeepsBoxCaptionAndActions` test reads these
files from the normal isolated fixture copy and fails if provenance or JSON is
missing. A fresh normal test-reader output can be selected with
`WIKIDICT_EMPTY_TABLE_READER_JSON` and its exact
`WIKIDICT_EMPTY_TABLE_READER_SHA256`; neither path substitutes handwritten JSON.
Regeneration uses the existing `zig build test-reader` route and its
`writer-empty-table/styled-empty-table-contract.{json,dprj}` outputs. The desktop
composition test consumes the recorded JSON; ordinary installed GUI qualification
separately opened the genuine Writer library through the core FFI. The committed
DPRJ retains the paired semantic payload; it is not executable corpus code.

## Disclosure format continuity

`dict-disclosure-tests` is a focused executable linked to `wikidict-product`.
CTest registers it as `native-disclosure-continuity`; it does not compile the large
`MainWindowTest.cpp` translation unit. Build that target and select that CTest name
when qualifying this regression independently.

`fixtures/it-cediglia-disclosure` retains the complete ordinary `cediglia` Italian
Entry and its original compiled library member, not a synthetic surrounding body.
Its source is Italian Wiktionary [cediglia, revision 3991833](https://it.wiktionary.org/w/index.php?title=cediglia&oldid=3991833),
page 143745. The manifest pins the compiled member, full Entry, authored expectations
and existing `it_public_disclosure_button_source01.json` policy. Source witnesses
also remain in `compiler/tools/testdata/it-cediglia-right-default`. This fixture
covers one entry, not the whole Italian edition.

Provenance is limited to retained page 143745/revision 3991833: 590 bytes of raw
source and 2,086 bytes of retained expanded source, passed through the private
four-leaf producer with the controlled c5b0 policy capture. The fixture manifest
records the full producer closure and handoff hashes. Consumer evidence is a
direct Entry/native blob read through the product FFI, not a CLI check. It grants
no re-expansion, historical CSS fidelity, generic Writer, canonical producer, or
whole-Italian-edition qualification.

The test opens a private copy through the product FFI, compares the complete Entry,
and performs native collapsed/expanded/recollapsed clicks. It then reports the six
`FC02-*` controls separately: owned no-op, owned reflow, no consumption during a
hold (including idle click/programmatic toggle restoration), cancelled/new tickets,
foreign no-op/rebinding, and rejected holds. Each control explicitly resets private
disclosure state before rendering the same captured Entry; that setup is not a
claim about product reset behavior.

The maintained Qt capabilities and genuine Arial font tables are required.
Provide the licensed font through the test environment; this fixture does not
redistribute it. Missing capabilities/fonts fail rather than skip or substitute.
The test isolates XDG directories and default/explicit QSettings formats/scopes
before QApplication. Ordinary successful runs remove temporary profiles only after
a complete report write and flush. Failures retain available reports/captures under
the build directory's `.tmp`; report transport failures return 74 and print the
primary result, report path and I/O error to stderr.
Append `--startup-only` after the two fixture arguments to execute portable setup
only. This reports `STARTUP_ONLY_NOT_CONTROLS`, leaves the native cycle and all six
controls `UNRUN`, and retains its profile and `result.json` for archival while also
emitting the report to stdout. It does not replay or qualify the earned controls.
