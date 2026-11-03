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

To regenerate using a compatible core checkout and its Zig 0.17.0 toolchain, from
the desktop checkout:

```sh
zig run -O safe --cache-dir .tmp/fixture-cache \
  --dep blob_encoder -Mroot=tests/generate_fixture.zig \
  -Mblob_encoder=../wikidict/src/encoder/blob_root.zig -- tests/fixtures
```

Adjust the relative core path for the checkout layout. The generator calls the
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
