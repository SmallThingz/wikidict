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

1. `0001-logical-flow-renderer.patch`: the 19 renderer source files.
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

Build the existing target and run the 21-method suite. Use a fresh owned
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
  missingFigureLabelWrapRequiresCurrentOwnedAncestry
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

Configure the desktop with `CMAKE_PREFIX_PATH="$qt_prefix"` so all Qt components
come from this prefix. Packaging must retain the matching libraries, plugins and
upstream notices together. The unified `wikidict` executable and relative
`wikidict-gio` symlink continue to load the Qt component in the same process.
