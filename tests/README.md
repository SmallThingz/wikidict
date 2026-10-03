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
and checks the effective settings paths. CTest also sets outer XDG directories
under `.tmp/ctest` for subprocesses.

`LibraryStoreTests` checks staged raw/compressed import, structural validation,
checksums, cancellation and removal. `LibraryDialogTests` drives the actual file
picker and confirmation dialogs. Both may also accept another raw `.wikblb` path
to validate a real dictionary; CTest supplies the committed fixture for the GUI.

`MediaPanelTest` supplies controlled HTTPS replies and a local fake speech process.
It tests the boundary between permission, downloading, caching and playback without
accessing public media or depending on an installed voice or sound device.
