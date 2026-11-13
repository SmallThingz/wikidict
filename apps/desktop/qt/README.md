# Patched Qt for the native reader

The logical-flow reader requires these Qt changes. A stock system Qt does not
provide the registration, source-position and figure-layout methods it uses.
The patches preserve original document offsets while laying out authored
paragraphs around real figure and caption frames. They also cover cursor movement,
selection, shaped character geometry, empty-paragraph struts and figure content
minimum widths. Projected text follows the document's cursor style and clears
floats using the paragraph's actual margins. Typed table boxes preserve physical
clearance, authored width and per-edge outer padding separately from cell padding.
Collapsed borders use zero outer padding, while the authored values remain stored.

Isolated compiled inline tables keep real cells, row spans and source actions. Their
shrink-to-fit width uses the containing block, while baseline or middle alignment
uses the measured cell lines and parent font. Computed table line heights retain
the table's font basis when a cell uses a smaller font. Inline tables with captions,
floats or unsupported mixed content are rejected rather than silently flattened.

Signed horizontal overflow uses the same origin for painting, scrolling, cursor
queries, selection and hit testing. Only current registered inline-table owners
contribute a negative extent. Reflow and entry replacement clear obsolete extents.
The minimum width of an unbroken word includes all of its formatting runs; a link
or color boundary does not create a wrapping opportunity.

The qualified source is QtBase commit
`025bdad181de241e81bf853c8a2d7bf3d19261a9` (module version 6.12.0, development
version alpha1). This is an upstream source pin, not a claim that a distribution's
Qt source archive or binaries have been reproduced. `manifest.json` records each
upstream and qualified file hash. The two new private headers are included in the
renderer patch.

Apply these three patches, in order, to that QtBase source:

1. `0001-logical-flow-renderer.patch`: the 21 renderer source files.
2. `0002-layout-regressions.patch`: the native regression target and tests.
3. `0003-bounded-gcc-link-policy.patch`: the separately maintained GNU LTO policy.

The companion modules use these exact upstream commits:

| Module | Commit |
| --- | --- |
| qtsvg | `883a58532078d003cefef0a549bfe9f885ce41f5` |
| qtshadertools | `bccd516b990a6396900051470ac86cc27a7042ea` |
| qtmultimedia | `6ca885f084a3984749d53bb50a0e08bdc60e86cc` |

Apply `0004-shadertools-private-namespace.patch` to qtshadertools. It gives the
bundled SPIRV-Cross SPIR-V types their own namespace consistently across translation
units. The qualified multimedia build uses the resulting `qsb` and generated
shaders. Do not substitute a system `qsb` or mix Qt module builds.

## Scoped plain-flow Containers

The native `wikidict.plain-container/1` capability retains a real source-owned
frame for an ordinary in-flow Container. Its descendants share the surrounding
float exclusions and may export their own floats without making the wrapper
artificially enclose their height. Paint, hit testing and selection use the same
real document hierarchy and positions.

The app materializes the supported plain-flow subset through its existing Flow
composition transaction. Authored empty child paragraphs retain their line;
renderer-created storage paragraphs remain zero-height. Unsupported Container
styles fail visibly and preserve history, source and recovery instead of dropping
the body or substituting stock frame layout. The original subset excluded flex and
floating Containers, fit-content, max-width and line-height overrides, responsive
rules, unequal padding, nonzero vertical margins, general table ancestry and
nonempty zero-width boxes. Later supported Cell and fixed-float cases are described
below; the remaining unsupported cases retain their refusals. A current registered Figure caption
provides a separately authenticated ancestry boundary for supported Containers.

The historical plain-Container qualification combines eleven passing methods from
the original native build
with the two corrected selection/stock-oracle controls on the same product
libraries. The original two failures are retained. Eight app controls cover
hierarchy, authored-empty behavior, requested geometry, the exact retained
compiler subtree, unsupported-style refusal and keyboard recovery. Reading-pane
captures cover 900 and 640 pixels. The full compiler diagnostic still refuses
unsupported float/fit-content; this is not ordinary Writer-to-Reader Container
acceptance. Current default media and unified-entry registrations run separately;
the opt-in audio skip is explicitly unqualified unless the manifest records the
separate owned silent-output check. Hardware audio, the complete native/Reader
suites and whole-corpus frontend acceptance are not claimed.

## Typed Figures and Cell typography

The cumulative patch also implements the API04 Figure contract: physical wrapper
margins and direction, caption-owned inline links, per-owner fixed link colors,
fragment focus geometry, and cancellation when a pointer release reaches a
changed link owner. Imported inline image helpers retain their real document
identity. Caption hit testing and image decoration use those same stored owners.
The app keeps CSS pixel text sizing separate from the reading-font zoom basis.

Typed Cell line height uses the Cell owner's font, including an explicit zero
basis, rather than inheriting a descendant's font. Stock and projected paragraphs
use their actual source block to resolve that owner. Signed glyph ink remains
separate from the used line allocation. Empty cells are inspected without
constructing a cursor during layout, and captions or nested owners retain their
own typography boundaries.

The Cell qualification remains recorded at its original source and artifact
identities. The current change excludes only undecorated, unowned native table
boundary caret storage from glyph traversal. Caret layout stays intact, and real
overflow, painted empty blocks, owned paragraphs, partial repaint and caret
ownership remain covered by the affected native controls. Three passes from the
product build carry with exact product and method equality; the corrected boundary
control passes separately. The original sample-premise failure is preserved.

The complete retained Italian `pianoforte` entry now reports document width equal
to its viewport and horizontal range zero at both 900x700 and 640x600. Actual owned
GUI review confirms wide and narrow quote/table fit with vertical scrolling and no
horizontal bar. Images and audio stayed off, so this does not qualify image paint
or whole frontend behavior. The GUI's first manual report had a schema error;
the corrected report authenticates the same actual frames without a replay.

Before the font-feature change below, the cached app CTest run passed all seven
registered tests on the recorded earlier bytes without rebuilding or configuring: Reader, media, library storage, both
library UI modes, core selection, and install/relocation. Reader reported 307
passing incidents and two optional compiler-fixture skips; media reported 58
passing incidents and one opt-in private audio-backend skip. The retained Italian
regression also passed separately at both widths. The full native suite, source
metadata destination, full accessibility, whole edition and release qualification
are not inferred.

## Typed font-feature policy

Explicit typed font-feature lists replace inherited settings, including an empty
list that resets them. An absent list retains inheritance. The app resolves the
font against its owner before applying the list, preserves span sizing origins
and the zero-font merging policy, and maps Figure struts, captions and Missing
labels through the same policy. Qt records an explicit empty feature property as
a resolved reset and applies explicit shaping features before automatic kerning
and tracking choices.

Four affected native controls passed: replacement/reset and shaper precedence,
plus the existing primary-font and owner-strut typography controls. Both app
controls passed with the current GUI and Reader binaries. The previous seven-test
CTest result and its optional skips remain historical; this focused component did
not repeat that healthy suite. The maintained patch series was checked forward
and backward against all 25 exact source targets.

Owned retained-Italian GUI checks also verified end-of-document keyboard input,
semantic Tab focus, a clear invalid-import error and recovery with the installed
dictionaries preserved. Two caller mistakes were rejected by the harness before
input/action and remain recorded. Images and audio stayed disabled. The media
placeholder border is not evidence of a reading-pane focus indicator. This does
not qualify transient loading, a genuine TH encoded page, or the full frontend.

## Table auto margins and ordinary-cell fixed floats

Typed table auto margins use the final measured table width and the containing
block's direction. Caption minimums are measured in the word-wrap domain before
the final normal wrapping layout. Projected captions keep their source owners and
allow a bounded signed physical origin while local padding and extents remain
nonnegative. The table policy retains exact nested value types through the Qt
format cache, so malformed and valid formats cannot alias through coercive equality.

The supported ordinary-cell float subset is a source-owned Container with a fixed
px/em width and a physical left/right side. Siblings are placed in source order;
transparent wrappers keep their zero used height while their floats contribute to
cell allocation. Unsupported widthless or mixed policies still refuse visibly.

Five affected native controls passed on the current library. Both corrected app
methods passed, with two unchanged app methods carried from the same product using
exact whole-method and product equality. Constructed caption and fixed-float views
were checked at 900 and 640 pixels, including actual Tab/Return actions, source
invariants and accessible text. The original failures and diagnostic limitations
remain recorded. These are controlled component views, not a normal Russian
Writer/Reader page; that producer pairing remains a separate qualification.

The maintained three-patch QtBase series was reconstructed forward and backward
against all 25 explicit targets. A normal incremental dependency check preceded
the seven-test CTest run: six suites passed; Reader reported 313 passing incidents,
one failed legacy rejection and two optional compiler-fixture skips. Media passed
58 incidents with its private audio-backend opt-in case skipped. The original
full-run failure remains recorded.

The legacy Cell control now verifies supported ordinary-cell Container geometry,
measured nearer-owner line spacing, source identity, actions, hit testing and
paint, and still rejects a genuinely unsupported floating-table case. Only that
changed Reader method was rebuilt and rerun; it passed, with all preceding typed
loops and every other method/helper unchanged. Product and native binaries were
unchanged. The six passed suites and unchanged Reader checks therefore retain
their exact dependency scope; this is not a restamped successful full-suite run.
Earlier CTest, media and GUI evidence keeps its original identities.

## Responsive Table block viewports

A typed Table block viewport keeps one source grid and caption while choosing its
source-proven wide or narrow box policy at the document CSS viewport boundary.
Containing direction and grid direction remain distinct. Source-owned language
reaches shaping, and typed cell alignment retains the actual line metrics.
Caption-only empty grids keep their intrinsic word floor and authenticated owner.

Copying a viewport through a Container preserves its hidden storage state only
after the destination frame hierarchy has been scanned. The edit checkpoint keeps
layout disabled, verifies the revision transition and retains one undo operation.
Keyboard focus reveals both ends of a selected link, then prioritizes the active
endpoint; cursor anchor identity is checked explicitly. Scrollbar geometry and
visible caption glyphs share the native local clipping and scroll coordinates.

Three affected native controls passed on the current library. Two current app
controls passed for responsive tables and ordinary Container scrollports. Root
reviewed the constructed 900- and 639-pixel frames: caption and rows are visible,
bars sit below the text, and the long word retains intended horizontal clipping.
The earlier numerical pass with incomplete visible content remains a recorded
visual failure. Earlier empty-caption, middle and language checks retain their
original execution and readset scopes, without claiming a new full-suite pass.

All 25 maintained Qt patch targets were reconstructed forward and backward against
the pinned upstream revision. The normal incremental dependency check and all
seven CTest suites passed on this source. Reader reported 318 passing incidents
and 2 optional skips; media reported 58 passing incidents and 1 private-backend
opt-in skip. The two library test executables were relinked against the current
product archive; unchanged compilation and the native library were reused.

Genuine Russian Writer-to-Reader interoperability and remaining ordinary-page
rendered checks retain their separate scope. These constructed views and host
checks do not establish whole-frontend, hardware-audio or release acceptance.

## Source and build layout

Use one source directory and one build directory per module. Keep the sources,
objects and package staging directory outside version control. From the repository
root, set absolute paths to the existing or selected source/build/prefix directories:

```sh
patch_dir="$PWD/apps/desktop/qt"
qt_sources="$PWD/.tmp/qt-sources"
qt_build="$PWD/.tmp/qt-build"
qt_prefix="$PWD/.tmp/qt-prefix"
```

Obtain the four source revisions above in `$qt_sources/<module>`. In a clean
QtBase checkout, check and apply the patches with ordinary Git:

```sh
git -C "$qt_sources/qtbase" apply --check \
  "$patch_dir/0001-logical-flow-renderer.patch" \
  "$patch_dir/0002-layout-regressions.patch" \
  "$patch_dir/0003-bounded-gcc-link-policy.patch"
git -C "$qt_sources/qtbase" apply \
  "$patch_dir/0001-logical-flow-renderer.patch" \
  "$patch_dir/0002-layout-regressions.patch" \
  "$patch_dir/0003-bounded-gcc-link-policy.patch"
git -C "$qt_sources/qtshadertools" apply \
  "$patch_dir/0004-shadertools-private-namespace.patch"
```

An already qualified source/build needs no new checkout, configure or rebuild just
to adopt this maintained recipe. Compare its selected source files with the
manifest, retain its CMake cache and objects, and continue using normal target
dependencies. Never edit generated Ninja rules or copy replacement object files.

## Build

The qualified Linux build used GCC 16.2.1, Ninja and CMake 3.25 or newer, with Qt's
platform development dependencies, FFmpeg and DejaVu Sans available. The following
configuration keeps the relevant source features, test target and bounded build
policy. Platform package choices remain local; this is not a byte-reproducible
binary recipe.

```sh
cmake -S "$qt_sources/qtbase" -B "$qt_build/qtbase" -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$qt_prefix" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
  -DCMAKE_USER_MAKE_RULES_OVERRIDE="$patch_dir/bounded-ipo.cmake" \
  -DCMAKE_POLICY_DEFAULT_CMP0137=NEW \
  -DCMAKE_TRY_COMPILE_NO_PLATFORM_VARIABLES=OFF \
  '-DCMAKE_TRY_COMPILE_PLATFORM_VARIABLES=CMAKE_USER_MAKE_RULES_OVERRIDE;CMAKE_POLICY_DEFAULT_CMP0137;CMAKE_TRY_COMPILE_NO_PLATFORM_VARIABLES' \
  '-DCMAKE_JOB_POOLS=wikidict_compile=4;wikidict_link=1' \
  -DCMAKE_JOB_POOL_COMPILE=wikidict_compile \
  -DCMAKE_JOB_POOL_LINK=wikidict_link \
  -DQT_BUILD_TESTS=ON -DQT_BUILD_TESTS_BY_DEFAULT=OFF \
  -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_MANUAL_TESTS=OFF \
  -DINPUT_libmd4c=qt -DFEATURE_system_textmarkdownreader=OFF \
  -DFEATURE_textmarkdownreader=ON -DFEATURE_textmarkdownwriter=ON
cmake --build "$qt_build/qtbase" --parallel 4
cmake --install "$qt_build/qtbase"
```

Configure qtsvg, qtshadertools, then qtmultimedia with the installed private
`qt-cmake`, using separate build directories and the same prefix and toolchain.
Set `QT_BUILD_TESTS=OFF`, `QT_BUILD_EXAMPLES=OFF`, `QT_USE_VCPKG=OFF`, the same IPO
override and job pools, and `FEATURE_ffmpeg=ON` for multimedia. Build the normal
`Svg QSvgPlugin QSvgIconPlugin`, `ShaderTools qsb`, and
`Multimedia QFFmpegMediaPlugin` targets respectively, with `--parallel 2`, then
install each module into the same prefix. The module commits and namespace patch
are required inputs; their source trees are not vendored here.

The GNU policy bounds ordinary IPO workers to one, requests four for Gui and
retains two for Widgets. Gui's generated MOC source has a final `-flto=4` option
because GCC retains duplicate IPO options in that first object's metadata. The
compile pool allows four jobs and the link pool one. Widgets has no matching MOC
workaround and is not claimed to link in parallel. Keep the normal dependency
graph; do not relink solely to measure this policy. The retained `-v` link option
makes the actual compiler invocation visible.

## Native validation

Build the existing target and run the 27-method suite. Use a fresh owned
settings directory; do not point tests at user dictionaries or preferences.

```sh
cmake --build "$qt_build/qtbase" --target tst_qtextdocumentlayout --parallel 4
qa_root="$qt_build/native-tests"
mkdir -p "$qa_root/config" "$qa_root/cache" "$qa_root/data"
XDG_CONFIG_HOME="$qa_root/config" XDG_CACHE_HOME="$qa_root/cache" \
XDG_DATA_HOME="$qa_root/data" QT_QPA_PLATFORM=offscreen \
QTEST_DISABLE_STACK_DUMP=1 QT_FORCE_STDERR_LOGGING=1 \
  "$qt_build/qtbase/tests/auto/gui/text/qtextdocumentlayout/tst_qtextdocumentlayout" \
  nativeLogicalOwnerKeepsRealCaptionsAndOriginalOffsets \
  nativeParagraphBoxOriginalFlowInvestigation defaultPageSizeHandling idealWidth \
  lineSeparatorFollowingTable wrapAtWordBoundaryOrAnywhere inlineImage clippedTableCell \
  floatingTablePageBreak imageAtRightAlignedTab blockVisibility testHitTest largeImage \
  wrapTextWithSpacesAndTabs listMarkerFollowsBaseline listMarkerHitTest \
  nativeTableBoxKeepsCellsAndContainingFlow \
  nativeInlineTableKeepsBaselineAndComputedCellHeight \
  nativeInlineTableWrapsRowsAndKeepsFollowingText \
  nativeInlineTableKeepsCompensatedListIndent \
  missingFigureLabelWrapRequiresCurrentOwnedAncestry \
  typedCellConstraintsUseIntrinsicContentAndTablePercent \
  typedCellCollapsedDoubleWinsWithoutChangingOrdinaryBorders \
  logicalCellGeometryWaitsForLayout \
  cachedFloatLineDisplacementAdvancesFollowingBlock \
  logicalRootNoWrapKeepsStockNaturalWidth \
  ownedFloatTableGridDoesNotAcquirePageMargin
```

On 2026-11-09 the earlier suite passed all 17 methods with 32 paragraph cases, two
lifecycle controls, ten numeric controls and 1,165 logical observations. The
original 24 geometry combinations and 18 authored-poem cases remain asserted.
The extended table controls include zero-cell frames, strict malformed-format
refusal, adjacent child-frame ownership and fragment-copy formatting. Copy tests
preserve both rich first-block properties and the destination character format
for plain-text fragments, including real empty-paragraph struts.

Styled zero-row tables use real zero-cell frames, preserving authored width,
padding, borders, floats, physical clear, captions and source offsets. They do not
invent a table cell or discard a valid style. Collapsed borders retain authored
padding while using zero outer padding. Inserting a wrapper reparents every
eligible adjacent child; fragment copies retain the initial boundary format.

The earlier unchanged app binary passed four selected style, refusal/recovery and genuine
Writer-fixture methods against this native library. The shared normal Writer and
Reader produced the maintained styled-empty-table fixture. Ordinary installed
GUI checks showed its caption, suffix links and styled box at wide and narrow
widths, with keyboard focus. The first GUI invocation ended after an invalid
scroll-observation target; its successful frames are retained separately from a
subsequent wide launch and ordinary Quit. No same-invocation wide restoration is
claimed. Original compile, ownership, copy-offset and orchestration failures remain
recorded in the qualification history.

The manifest retains native58/test59 and the earlier captured Serbian figures,
cursor, empty-paragraph and poem qualifications as history. These scoped checks
do not establish universal table fidelity, all-language frontend acceptance or a
full core bundle. The earlier 29-method desktop pass remains separate. Run every
selected strict check; a focused pass does not restamp an earlier full suite as
current. The held heading-convergence test93 is not included.

Current focused checks cover compensated list margins, RTL overflow, following
paragraphs and minimum widths across formatting boundaries. The actual reading
widget was checked in both widget directions with mouse caret/hit tests, keyboard
activation of both edge links, complete selected glyph visibility, wide reflow and
entry replacement. A selected anchor excludes the insertion caret after its text;
keyboard checks therefore measure selected glyph bounds and ink. Mouse-caret
containment remains a separate assertion.

Image-theme controls separately passed four pixel/transform cases and an actual
window light/dark/cached-source case. They verify the compiled image-only
invert/hue-rotation policy, alpha preservation and unchanged surrounding geometry.
The app reapplies ready image formats through the existing guarded provider after
reading and title composition. Those image successes are carried from a run whose
table-widget check failed; the original whole-run failure remains recorded.

Missing figure content uses a real centered label frame, preserving its compiled
text, action, child styles, caption and computed line height. Only label blocks
with the exact marker and current registered Figure/helper ancestry receive
word-boundary and emergency grapheme wrapping. The native control retains its
authored 180px width even in a 120px parent; ordinary image and caption width rules
are unchanged.

The focused native method passed its geometry and refusal checks. Its wrapper
then failed an unrelated inline-table screenshot requirement; independent closure
verified the skipped artifact/source checks, and that original failure is retained.
Five affected app methods passed, including SVG occurrence language, physical-pixel
rendition demand and cache identity. An actual window frame then exposed missing
label glyphs after visiting a link. The repaired foreground-only focus hint passed
the affected method again, with visible glyph ink on all twelve lines in hover,
active, visited-hover, visited-active and return states. The original rendered
failure remains recorded. A requested compact width of 360 produced the app's
actual minimum width of 480; lower content requires vertical scrolling.

These checks do not restamp the historical full suite. The current genuine K
Writer/Reader exports still require a paired native frontend run. Missing/SVG
consumer tests use controlled JSON and owned media fixtures; genuine future
Writer/Reader/frontend interoperability remains unqualified.

Typed cell styles preserve physical per-edge none, solid and double borders.
Collapsed conflict resolution considers none, width and style before existing
origin and direction ties. Cell widths are content constraints in the automatic
table algorithm; percentages use the table grid. Rich and nested content retains
intrinsic minimums. Fragment expansion preserves explicit inherited letter
spacing and weight without replacing a child's explicit zero or normal weight.

Mapped positions refuse table geometry until ancestor layout vectors are ready.
Hidden Reading composition initializes an unset page size from its actual
WidgetWidth viewport. Existing page settings remain intact. Reused heading lines
retain float displacement in their flow advance. Unpaginated typed tables keep
ancestor page reservations out of their local row and cell-content origins.
Decoded nonempty tables receive native ownership before optional box styles,
including basic imported floats; authored widths and padding stay intact.
Raw HTML remains unowned, and finite pagination retains its existing rules. Root NoWrap paragraphs preserve
Qt's zero-width sentinel and stock natural width without forcing viewport wrapping.

The focused native table-origin method and current Reader registration passed.
Unified-entry passed before the final test-only corrections; its product, native
libraries, checker and execution dependencies are verified unchanged. Earlier focused native, alignment,
tracking, weight, swatch and glyph checks remain separately identified in the
manifest. The unchanged Library and media test binaries retain their previous
qualification; those registrations were not replayed against the latest native
library. The complete 27-method native suite above was not rerun as one current
suite. Controlled fixtures do not establish genuine Tallrik Writer/Reader/frontend
interoperability, complete CSS automatic table layout or Container DPRL support.

Reader composition enforces exclusive cell content modes and avoids empty image
format transactions while preserving real resource and geometry changes. Tests
use the production projection lifecycle and mapped geometry. Egyptian text is
compared with an independently shaped, nonblank five-glyph reference; zero-size
text retains copy/accessibility content without ink or advance. Abbreviation
expectations changed only for additive null tooltip fields, retaining original
blob and CLI provenance. Original failures and debugger limitations remain in
the qualification history.

Installation tools retain their loader environment while relocated app checks
remove it. Install commands have 120-second limits within the existing 300-second
CTest bound; CLI and loader probes retain 45-second limits. The opt-in private
null-audio case remains skipped. No installed application or user data was changed
by this source delivery.

Configure the desktop with `CMAKE_PREFIX_PATH="$qt_prefix"` so all Qt components
come from this prefix. Packaging must retain the matching libraries, plugins and
upstream notices together. The unified `wikidict` executable and relative
`wikidict-gio` symlink continue to load the Qt component in the same process.
