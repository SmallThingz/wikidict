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
upstream and qualified file hash. The new private logical-flow, inline-style and Ruby headers are included in the
renderer patch.

Apply these three patches, in order, to that QtBase source:

1. `0001-logical-flow-renderer.patch`: the 27 renderer source files.
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

## Responsive table floats and named links

A typed table float retains one real grid, physical float placement and authored
margins while selecting its wide or narrow policy from the document CSS viewport.
Derived empty tracks retain source column spans and Cell typography. The native
validator authenticates the registered table object, including its index-free
format, and still refuses a foreign explicit object index.

A named section anchor attached to a link no longer makes only the first Unicode
scalar keyboard-focusable. The importer preserves the original actionable-link
flag for the rest of the label while keeping name-only anchors nonactionable.
The focused native regression covers name-plus-link, name-only, plain links and a
supplementary first scalar. The app's original full-label Tab selection now passes.

Three focused float controls passed before the importer change. The new importer
control and the affected app method passed on the subsequent library. Root viewed
both constructed app frames: at 900 pixels the table floats right; at 639 it moves
above the following rule and attribution. The green colspan heading is centered,
labels remain readable, and no overlap or clipping was observed. These are marked
component fixtures, not a genuine Mai dictionary page or whole-frontend result.
Earlier CENTER, ordinary-page and full-suite evidence keeps its original scope.

The GNU native regression target alone disables IPO and appends `-fno-lto` to its
compile and link commands. Qt product libraries retain their existing IPO policy.
Both test objects were rebuilt and checked for absent LTO sections on the same
incremental cache; the regression source and inventory were unchanged. Test
compile/link action times were 85.621/1.098 seconds, versus the retained
21.949/91.393 seconds with LTO. This is an observational comparison, without a
matched benchmark or historical test-only CPU/peak baseline.
The old caption failure from an earlier no-LTO trial remains separate.

The cumulative maintained patches include all implementation and regression
changes; no product implementation depends on a private postimage tree. Apply the
same pinned-source recipe below. Focused reproduction additionally uses:

```sh
"$qt_build/qtbase/tests/auto/gui/text/qtextdocumentlayout/tst_qtextdocumentlayout" \
  tableFloatViewportKeepsPhysicalFloatDirectedFlowAndSource \
  tableFloatViewportDerivedSlotsKeepTypographyAndRejectForeignState \
  tableFloatViewportUsesExistingFloatFreeIntervalAndClearance \
  namedAnchorPreservesFollowingLinkRangeAndNameOnlySemantics
```

Use the isolated environment described under Native validation. This command is a
reproduction recipe, not a claim that these historical scopes ran as one suite.

## Source-owned block media and responsive flex rows

Ordinary links retain their authored paint states and action ownership across real
text owners. Source-owned block media keeps its intrinsic ratio and CSS middle
alignment when text shaping revisits an inline object. Responsive flex rows use
word-based intrinsic minimums, preserve explicit anywhere wrapping, and retain
real item frames. Ordinary nested containers may cross a floating flex boundary
only after the row, direct item, ordinal and source ownership are authenticated.
Arbitrary floating ancestors and malformed ownership are still refused.

The app carries complete block-media states and pinned rendition identity through
its existing media pipeline. Eight focused native controls, eight Reader controls
and two Media controls passed on native115/App144. The cumulative patches below
contain the implementation and native regressions; the app source and tests are
tracked alongside them. The GNU native test target retains its existing LTO
opt-out; Qt product IPO policy is unchanged.

The three constructed captures at 900, 719 and 639 pixels show a readable image
and text row, with the following rule and attribution separate. The source selects
FloatRight at 900 and 719 pixels and InFlow only at 639. At 639 pixels the authored
100% border-box width equals the available width, while the retained 0.45em left
margin adds 9 CSS pixels at the fixture font size of 20. This retains a horizontal
scrollbar. This is not a claim of zero overflow. The blue square is
geometry test data, not a retained dictionary image. These captures and focused
checks do not qualify a genuine VI/Mai entry or the whole frontend. Earlier
CENTER, table-float, named-anchor, peili and full-suite results retain their
original scope. Original native112/native113/App143 failures remain recorded.

Use the pinned-source recipe and isolated environment below. Current focused
native reproduction uses:

```sh
"$qt_build/qtbase/tests/auto/gui/text/qtextdocumentlayout/tst_qtextdocumentlayout" \
  ordinaryLinkOutlineKeepsStockAndProjectedSourceGeometry \
  figureBlockMediaKeepsSourceRatioMiddleAndNonzeroStrut \
  figureBlockMediaRejectsForeignPolicyAndRecoversSameSource \
  containerFlexShrinksByBasisAndFreezesNoneWithoutGrowing \
  containerFlexAutoMarginsCrossOverflowAndRealLinkGeometry \
  containerFlexRejectsForeignItemsAndRecoversSameSource \
  containerFlexStrictMetadataCacheKeepsTypesAndRecovers \
  containerFlexFloatingRowsKeepOrdinaryDescendantOwnership
```

The app's focused Reader and Media commands are listed in the qualification
manifest. Reusing qualified binaries requires exact source, dependency and runtime
library identity; a source-only promotion is not a fresh full-suite execution.

## Typed body owners and intrinsic fit-content

The maintained patches retain typed Section headings, their source font families,
inline typography and Help, authored Rules, and one semantic body margin owner.
Native table storage carets preserve pending source margins. Fit-content owners
use measured minimum/preferred widths and available space, keep percentage caps
indefinite during intrinsic probes, and retain real nested tables and empty lines.

The EN reader keeps declared row spans and validates Qt's used span from the
actual source row count. Its complete genuine Entry retains both real tables,
Syriac/Latin text and actions. This does not rewrite Stored or qualify the source
rowspan999-to-Stored100 conversion or missing stylesheet authority.

Native123 passed two fit-content controls. Earlier native120/121/122 results keep
their original scopes. App154 passed seven affected Reader controls and carries
eighteen unchanged method sources. The two Media controls and standalone Library
check passed separately on retained artifacts. The paired CLI/FFI is the exact
I45 emission recorded in the manifest; ABI10 alone grants no semantic capability.

The genuine EN run exercised ordinary import, both expanded tables, wide/narrow
Syriac reading, horizontal pan, End navigation, normal Quit and persistence.
Three Tab inputs did not expose a selected href, so source-link activation and
Back navigation remain unqualified. Images/audio stayed OFF. This is neither a
whole-frontend result nor a Wiktionary browser-equivalence claim.

Root's later review of retained frame0048 also found the Noun headword line
extending beyond the Reading right edge. Whether this follows source nowrap or
wide-table/document-width coupling remains unresolved; full responsive layout
acceptance is not claimed. The original manual review is retained unchanged.

Reproduce the current affected native checks with the pinned build below:

```sh
"$qt_build/qtbase/tests/auto/gui/text/qtextdocumentlayout/tst_qtextdocumentlayout" \
  plainContainerFitContentUsesIntrinsicWidthsCapsAndInvalidation \
  plainContainerFitContentKeepsNestedTableEmptyAndStrictPolicies
```

The manifest names current Reader controls, retained histories, source components,
real-page captures and original failures. Source promotion reuses these earned
results without claiming another build or a full-suite replay.

## Complete grapheme character rectangles

The maintained native patch queries the complete same-line grapheme when a
character uses multiple UTF-16 units. Singleton characters retain their previous
mapping. Cursor positions, source offsets, link actions, drawing and layout are
unchanged. The strict native control covers Syriac combining marks, Latin
combining marks and supplementary characters in both directions and after resize.

Native124's failed independent-reference alignment assertion is preserved.
Native125 passed the corrected physical-alignment control; the other Native124
owner/source control retains its separate pass. The genuine EN Reader observation
confirms both Syriac code units receive the full character rectangle.

The later actual widget paint observation did not reproduce horizontal glyph-ink
clipping at wide, narrow or restored width. The native font engine's glyph bounds
remain within the viewport; narrow home-position clipping was vertical because
the Noun was below the viewport. This is bounded paint evidence, not pixel-level
or whole-frontend acceptance. Original screenshots and pending manual records
remain immutable and the later Root disposition is linked in the manifest.

The prior normal154 delivery retains its separate centered peili-table views,
strict heading/table allocation and overlap checks, and malformed-content
refusal/recovery results. Those scoped results are not rerun or expanded by this
character-rectangle change; broader CENTER and corpus-wide acceptance remain
outside this qualification.

Only these maintained native patches and their manifest are delivered here.
The private responsive DE Table changes are excluded by exact inverse sparse
reconstruction. No application source, data, build, or test is changed or rerun.

## Responsive source tables and preserved block boundaries

The same semantic Table owner floats at wide widths and becomes a local scroll
viewport at narrow widths. Its source grid, irregular rows, actions and physical
saved pan remain stable. A distinct source Table focus target supports keyboard
and accessibility actions even at zero horizontal range, without changing child
link identity. Native focus paint follows the explicit authored-none/native-UA
policy; it does not promise browser pixel equivalence.

Intrinsic width probes no longer overwrite the saved scroll offset with a
measurement-only range. The final layout still clamps that offset to its actual
range. The affected native paired restoration/hit method passes in both directions;
the nested probe and source-focus controls keep their separate earned passes.

Wrapping a table now preserves the complete exterior following-block format,
character format, visibility and list ownership. This fixes the demonstrated
empty-cell body-boundary refusal while retaining the strict ownership check.
Twelve contrasts cover CENTER alignment, headings, paragraphs, lists, visible and
hidden empty blocks, and the body boundary marker. These scoped controls do not
stand for all CENTER, overlap, crash or whole-corpus cases.

The Reader control verifies the selected child link's reveal while Reading owns
focus, then the ordinary accessibility focus transfer to the Table. Qt clears the
link focus indicator on focus-out; its source endpoint and the earned pan remain
stable. One current focus method and two unchanged App162 methods are qualified.
Original failures and bounded observations remain linked in the manifest.

Runtime production68 and the unchanged Library160 pass retain their exact identity.
The genuine EN full-JSON decode and minimal wide/narrow rendered follow-up use the
retained one-entry library, with images and audio OFF and normal Quit. The original
GUI aggregate remains failed because review fields were omitted; the corrected
saved-evidence review passed the same validator and Root inspection without a
runtime replay. They do not
qualify genuine DE Mai, missing source CSS, enabled media or the whole frontend.

The imported history and prior native patch series remain intact. Promotion
reuses qualified source and results; it performs no additional build or test.

## Compiled Q/R table, image and Rule semantics

The existing Table owner handles asymmetric physical corners, numeric separate
scroll boxes and intrinsic automatic-wide/fit-content-narrow allocation. It keeps
source cells, actions, focus and the independent containing-block direction.
Rounded overflow uses fractional padding edges; a wide radius alone does not clip
children. Responsive cell backgrounds preserve exact property presence. Table focus bindings
refresh after successful owned format transactions; external revisions remain
invalid. Fractional positions clamp against the active allocation; inactive
responsive owners retain their physical pan.
Explicit image baseline/middle geometry uses the occurrence font and the same
paint, hit, selection and accessibility box. Known image dimensions remain with
the same media asset across disabled, loading, failure and recovery states. Authored
image-link focus policies use the aligned image or Figure media action box;
bitmap glyph colors and underlines stay inert. Authored none remains distinct
from the native default. Omitted QTextLayout clip bounds preserve the existing
painter clip for stock focus outlines; explicit valid clips still intersect it.

Rule.clear uses physical float exclusions and the existing margin cursor. A
trailing zero-height cleared Rule refreshes its parent's exported after-margin
profile without changing the already established leading placement. Only orphan
anchor flags on authenticated empty Rules are normalized; typed nonempty named targets keep their navigation geometry while href and malformed
anchor metadata remain refused. Synchronous responsive reflow waits until an
owned Reading composition commits its source revision. Reader chrome settles before
the content layout snapshots margins; primary table-caption media preserves middle
metrics through inline reshaping.

The current Qt product includes typed per-range `normal` and `break_word`
wrapping. Emergency breaks use grapheme and shaping-cluster boundaries only
inside the authored text range; they do not lower the normal word minimum.
Mixed ranges, pre/no-wrap policy, stored text, actions, selection and accessibility
offsets stay intact. Effective shaping formats preserve overlay priority without
letting wrap-only boundaries split ligatures. Private logical-flow and source-map
headers are registered in Qt's existing CMake header generation/install path.

The optimized GUI and Reader qualification runs twenty-three current controls
and saves seventy-five constructed captures, including paragraph/table, LTR/RTL
and wide/narrow wrap views. These are test-constructed client-window captures,
not genuine dictionary or physical desktop acceptance. Cold141 compiled the
Gui dependency without native tests. Cold142 generated the registered headers;
its raw VCS-directory timestamp guard failure remains failed, while independent
source, object, runtime-byte and header checks establish reusable artifacts.
Earlier failures and qualifications remain in the referenced prior delivery.
Retained P68 supports source-local checks; current-R interchange, full suites
and full frontend acceptance remain separate.
Release refers only to the optimized CMake build profile and selected controls.
The application is not production-ready; publication approval remains withheld.

The eight app leaves are verified against qualified private source. Promotion
updates the existing renderer and CMake policy patches, manifest and README, and proves all
twenty-seven registered native patch targets forward and backward against the
pinned upstream. It performs no build or test.

## Compiled Ruby base and reading owners

The maintained native patches preserve separate logical base and reading ranges,
font owners, shaping, paint, hit testing, selection and caret geometry. The app
imports typed Ruby through the normal composition transaction; ordinary rich-text
fragment boundaries do not erase its owner. Ruby-only paragraphs, heading edges
and table cells retain their semantic content. Generated metadata has a dedicated
marker, so ordinary authored tooltips cannot impersonate an importer anchor.

The four new Ruby private headers and the existing inline-style header use Qt's
normal generated-header/install path. The desktop product links Qt6::GuiPrivate;
no copied private headers or hardcoded versioned include paths are required.
The cumulative three-patch QtBase series now verifies 31 source targets forward
and backward against the pinned upstream revision. Existing GNU IPO and companion
module policies remain unchanged.

Native qualification comprises one current corrected spacing method and 21
separately retained passing methods with source/dependency proofs. It is not a
rerun of 22 methods as one suite. Three equivalent Ruby-line containers remain
separate. Mixed fixed-height font/ink envelopes can overlap: the retained 146/147
failures and 0.1875-pixel ink-envelope observation are not rewritten as painted
pixel collisions, and product spacing was not inflated to satisfy that oracle.
The actual equivalent-line and mixed accent/descender captures remain legible.

Both focused App190 host methods passed. Genuine normal176 Writer/Reader output
for Japanese `たびぢ` matched every byte of FFI177's JSON and rendered through the
same App190 at 900x700 and 640x600. The reading `たびじ` appears above `旅路`.
Separate live Link descriptions retain the same internal destination, and real
Tab input selects base and reading as distinct UTF-16 ranges. One internal Press
reports the absent `旅路` record; ordinary search restores the source entry. Back
remains disabled, so successful destination content and Back traversal are not
claimed. Normal Quit, selected data, settings and process cleanup passed.

The subsequent full Reader run exposed a layout-enabled temporary document in
Flow construction. Keeping that structural staging document unlaid out fixes the
actual table-copy crash without changing destination layout or assertions. The
completed App192 run reached cleanup with 365 passing observations, three failing
fixture oracles and two optional diagnostic skips. App193 corrected only those
three test methods and passed them through the existing direct QTest route.
The combined evidence covers 368 passing observations and two optional skips;
it is not a new complete Reader run. The separate impact review authenticates
unchanged product bytes and source outside those methods, and carries the six
other historical CTest targets. Original crashes, failures and run scopes remain
recorded. The genuine App190 flow above was not replayed or relabeled App193.

The source entry still reports unresolved table style. Hypertext and spoken
assistive technology, general nested Ruby, general joint fragmentation, arbitrary
owner policies, whole frontend and phone acceptance remain outside this result.
Unsupported importer combinations refuse explicitly. Historical full-suite and
failed-run evidence keeps its original scope; this source delivery performs no
new build or runtime execution.

## Deep tables and visible overflow

Native layout is qualified at table depths 17, 20 and 32. The paired App
controls separately verify the 32/33 admission boundary. Intrinsic cell widths
are memoized only within one outer layout epoch for eligible owned,
unpaginated table/text subtrees. The key includes wrap mode and containing
width/height context. Paged, special object, non-table ancestor, fit/flex and
active exclusion contexts retain the ordinary measurement path. Final geometry
always runs; the cache stores only successful minimum/maximum widths.

Owned fixed-height tables retain their used and decorative dimensions while
visible child overflow participates in paint culling, document extent and hit
traversal. Actual scrollports and rounded clipping still constrain hidden
content. Reverse hit traversal respects transparent gaps and opaque later paint;
FuzzyHit preserves native insertion edges, with existing image and Ruby owner
semantics retained.

Qualification is deliberately scoped. The latest native run passed five selected
methods; thirteen passing methods from the prior run retain exact method bodies
and their historical result. One method appears in both sets. The two App
controls then ran against unchanged app product binaries and the newly qualified
native libraries; only the corrected Reader test executable was rebuilt. The earlier timeout, anchor failure, const-connection compile
failure, caret failure and document-rebuild cursor fixture failure remain recorded. This is not a fresh full native or
Reader suite, and does not claim genuine DPRT wire or rendered-page acceptance.

For reproduction, use the existing native target and isolated environment below
with `qualification.table_depth32.current_methods` and
`qualification.table_depth32.historical_passed_methods` from `manifest.json`.
The deterministic depth17/20/32 controls bound structural layout work; they do
not use elapsed time as the correctness oracle. The maintained patches contain
all source changes; the private qualification paths are evidence references,
not fresh-checkout build dependencies.

## Inline actions and Ruby reading padding

Private JSON consumers preserve distinct inline action occurrences,
independently resolved declaring and child fonts, wrapped and natural bidi
ranges, zero-length owner identity without hit advance, and native keyboard,
accessibility and copy paths. Ruby ancestor decoration covers the allocated
base band; annotation-local decoration stays separate, and action hits exclude
alignment slack.

Positive Ruby reading padding is supported only for a complete LTR unbreakable
reading. Other placements and wrapped padding refuse. Authored direction or
isolation, image descendants, competing descendant actions, and malformed or
unsupported structural fields refuse.

The current native qualification ran eleven selected methods. The App continuation
ran one Reader method. Four unchanged Reader method bodies retain their actual
App202 passes, including structural clue traversal. Two unchanged Media methods
retain their actual App204 passes for pronunciation traversal; their source and
binary remain exact and they were not rerun. GUI, Reader and Media targets were
built in App202. Only the Reader test executable was rebuilt in App205, with
product and native bytes unchanged and the existing CMake configuration reused. The original const-device and App private-header compile failures, and the
clipboard and selected-background fixture failures, remain recorded. These are
focused controls, not complete native or App suites. Numerical SUP controls are
synthetic: no actual Mai font tuple, paired U/V producer/FFI or genuine rendered
acceptance is claimed.

Reproduce the selected controls with the existing native and App build routes
and the method lists in `qualification.inline_action_v`. All native source
changes are in the maintained patch series; private qualification paths record
evidence and are not fresh-checkout build dependencies. Earlier qualification
sections retain their historical scope and were not rerun by this update.

## Owned-table boundary caret extent

Owned-table traversal excludes the same unpainted table-boundary storage lines
as glyph traversal. These empty lines retain their native caret allocation and
navigation, but do not enlarge the scrollable document. Authored empty paragraphs,
backgrounds, rules and entry-body boundaries retain their existing treatment;
real table and text overflow remains reachable. Ordinary stock scope is unchanged.

Seven affected native controls and the existing Reader table/list ownership
method qualify this correction. The Reader executable was reused without an App
build or configure replay. The earlier full Reader UX result (376 passes, one
failure and two skips) and the diagnostic failure remain recorded; the complete
suite was not rerun for this update. No genuine page or full frontend acceptance
is claimed. Reproduce the selected scope through the maintained build routes and
the method lists in `qualification.table_boundary_extent`.

## Fixed inline image metrics in owned tables

Owned in-flow table measurement can reuse fixed inline image metrics when the
registered image handler declares its stock delegate and native admission
validates that delegate and fixed dimensions. The cache retains format, device
and handler/delegate identity dependencies; unknown, resource-dependent or
decorated helper cases keep the original path. Image objects, source text, final
painting and hit testing remain intact.

Native qualification combines one current control with twelve source-exact
retained passes. The unchanged production Gui policy is joined from its actual
build; the failed Test-only policy report remains preserved. Three App controls
include deferred-commit composition; loaded dictionary behavior is qualified only
by the retained genuine tag scene and a separate same-profile restart/Quit.
The original missing-focus-field finish failure is preserved.
Synchronous document invalidation inside an active intrinsic-size callback is an
observed unsupported reentrant lifetime; the queued-after-layout control does not
claim to repair it. No full native/App suite or whole frontend acceptance, and no
matched speedup measurement, is claimed. See `qualification.fixed_inline_image_memo`.

## Inline boxes and independent declaring fonts

The private native inline-box contract preserves admitted child text, actions,
paint and geometry while keeping owner decoration separate from child styling.
BODY and container declaring fonts provide independent line metrics; generated
zero-glyph fallback struts yield only when a typed BODY owner supplies them.
Authored unsupported geometry remains refused rather than silently discarded.

Qualification covers sixteen native controls and nineteen distinct App controls
composed from the current BODY result and source-exact retained results. Original
failures and the bounded ownership diagnostic remain preserved. These are
controlled consumer fixtures, not genuine finalY dataset or whole-frontend
acceptance. Reference direction, positioned media and clipped absolute owners
remain outside this change. See `qualification.final_y_inline_boxes_and_declaring_fonts`.

All seven registered desktop CTest checks passed with the current renderer and
Reader. The Reader reported 386 passes and two existing external-fixture skips;
Media reported 61 passes and one opt-in private-audio skip. Independent closure
verified the source, libraries and outputs after an owner bookkeeping error;
the original failed outer result remains recorded separately. No tests were
replayed to repair that receipt. Genuine finalY dataset acceptance remains open.

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

The command below reproduces the historical 27-method baseline. For the scoped
Ruby controls, pass the 22 exact names in `manifest.json` at
`qualification.native_qualification.combined_methods` to the same
`tst_qtextdocumentlayout` executable with the same isolated environment. The
recorded Ruby result comprises one current method plus 21 retained passes,
not a new 22-method replay. The complete desktop CTest build/run instructions
remain in [the desktop README](../README.md#native-validation).

Use a fresh owned settings directory; do not point tests at user dictionaries
or preferences.

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

## Independent table minimum width

Typed table minima remain separate from preferred width and intrinsic content
constraints. Pixel and em minima use the original NormalBody basis; percentage
minima use the actual containing block. The native table solver applies the floor
after ordinary allocation and track rounding, including caption intrinsic floors.
Authored outer borders use the existing physical-edge path for nonrounded real
tables, independently of cell borders. A typed table border does not invent a
cell-border hint when legacy geometry is absent; explicit legacy hints and Cell
CSS overrides remain distinct. Source-known zero cell widths are materialized
when HTML import omits them, including validated empty ragged-grid cells, so
collapsed outer borders remain continuous without inventing a cell grid. Rounded and empty border routes and wholly
untyped legacy defaults are outside this repair. Empty tables and
responsive-wrapper minima remain explicit refusals in this consumer subset.

The native qualification combines one corrected caption-fixture method with eight
unchanged passes on the same product. App qualification exercises four affected
methods, including a border-policy paint/geometry matrix, ragged outer-edge
continuity, minimum sizing, Flow and fractional-style controls. Two exact earlier
passes are retained because their sources do not enter the typed outer-border
normalization path. GUI and Reader are rebuilt for the header correction. The
earlier overall Reader syntax failure and partial GUI/archive completion remain
historical evidence, as does the subsequent collapsed-border paint failure. The
original four-border consistency result is representation evidence, not CSS
fidelity. These checks do not constitute either full suite.

The matching normal ZH229 Writer, CLI and FFI supplied the retained cheng-khi
one-cell table. Owned wide and narrow GUI observations cover its text, 70 percent
minimum, half-em left cell padding, independent outer border and link focus,
followed by restoration and
normal Quit. The custom background variable remains unresolved. No missing-link
destination, whole-edition or complete frontend acceptance is claimed.

The existing patch series reproduces the minimal source change over the tracked
Qt baseline. All 32 targets reconstruct forward and backward; affected native
functions and controls match the recorded private qualification. The app source
proof excludes one reset of a private absolute-owner field absent from the normal
source. Unrelated private absolute-container and relative-float features are not
part of this delivery. This source-composition proof is separate from a newly
built canonical binary.

## Reading audio occurrence controls

The source-mapped logical text engine recognizes registered custom inline
objects before shaping. Their original document handler supplies advance and
height, and character-rectangle queries use the same visual item interval and
vertical alignment as native drawing. Insertion caret positions remain unchanged.
Unowned, unmapped and unregistered custom formats retain their existing behavior.
The controls compare actual allocation, drawing and character rectangles in
projected and ordinary documents, including real RTL and vertical alignments.

The paired existing desktop source keeps occurrence-specific native Play and
seek views in Reading and reuses the media controller and resource lifetime.
The projected normal-alignment host and the paired App stock RTL placement
path consume the native rectangle. The App source composition includes the
stock-host correction; its controlled qualification is recorded separately
from the three native controls and the existing-library GUI observation.
The recorded qualification includes three selected native controls and four
affected Reading controls, including mixed document-link and native-control
keyboard traversal. The unchanged generic direction control carries from
App243 through exact source/domain proof; one unchanged Media control carries
from App242 through exact source/artifact/native proof. Four controlled widget
frames record direct focus, keyboard-return focus, narrow and restored widths.
Other historical controls are not promoted. The GUI product and Reader test
were built in App245. The product also has a recorded isolated GUI regression
on an unchanged genuine ZH193 library. Its original worker exit1 is retained: an
omitted manual-review root field was reconciled additively against the same
frames and unchanged validator after successful normal Quit and cleanup. That record has no AUDIO occurrence:
genuine AUDIO8192 data/Reader/FFI, rendered audio playback and backend
acceptance remain unearned. No canonical binary rebuild, full suite or full
frontend acceptance is claimed.

The maintained 32-target patch recipe receives only the object classifier,
rectangle repair and exact selected test/helper/slot. Unrelated private absolute
containers and relative floats remain excluded. Relevant callback, drawing and
logical-position functions match the private source exactly; ordinary line
allocation matches after excluding its unrelated absolute-owner branch.

## Typed reference layout and citation controls

Reference32768 retains real wrapper, list and item Container frames. The existing
list painter shapes the original unsigned group number and its decimal suffix as
one run, using the item owner's font and direction. The run ends at the principal
content edge on its first actual line baseline. Backlinks and body text keep their
own fonts, actions and source positions; an active item background changes paint
without changing the source or frame geometry.

Citation64 preserves each authored marker range. Its nowrap policy prevents both
ordinary and emergency cuts inside that range while leaving neighboring break
opportunities intact. Existing authenticated isolation and source mapping remain
in use. Target paint and focus outline are selected by the current source,
occurrence identity and composition epoch. Cached traversal reserves both ordinary
and target outline ink, so a target switch needs no source-format mutation.

The private source193 correction activates that traversal for a citation in an
otherwise ordinary root paragraph, before checkpoint culling, and clears it when
the last citation policy is removed. The original failed external-ink raster crop
and pixel-equivalence assertions remain intact. The same control checks removal
and restoration while preserving the used root box and source text. The original
source192 run's eight passes and one failure remain separate evidence.

The recorded native qualification has three current methods and six earlier
passes carried through exact source and unchanged-domain proof. One corrected
App control passes currently, while twelve unchanged controls and the reviewed
wide, selected-target and narrow frames retain their actual earlier evidence.
The original failed run remains recorded. These are controlled fixtures, with
their actual pixel dimensions recorded. The used root
box and source text remain stable; document size includes reserved outline ink.
Null-layout legacy body typography remains refused because the synthetic prefix
and reference body have independent typography. Genuine producer/Reader/FFI
reference data, rendered genuine records, full suites and full frontend
acceptance remain unearned.

The maintained 32-target recipe reconstructs forward and backward. It receives
only the five reference/citation native leaves; relevant functions and all nine
selected control bodies match private193. Source positions remain document UTF-16
ranges, independent of source-file line numbers. Unrelated private absolute,
relative-float, image-occurrence and static-label changes remain excluded. This source composition does not include a new canonical binary build.

## Rounded whole-link inline boxes (candidate)

The known AF box keeps one original wiki-link owner and one plain text child.
Its italic declaring font supplies the existing em-padding basis; radius uses CSS
pixels without another font multiplier. Null radius keeps the square form, while
explicit zero remains distinct source. Non-null radius requires equal solid RGB
edges and no overlays. The native layout rounds the unbroken composite decoration
before slicing it across visual lines, without adding wrap-edge padding or new
intermediate corners. Background and border follow that shape; visible glyph
overflow is not clipped merely because the box is rounded.

The whole curved border area supplies action geometry through the original source
range. Padding adds no synthetic character or caret. Cut-away corners are excluded
from pointer hits. Existing native anchor navigation distinguishes adjacent owners
with the same href, and its ordinary style-provided focus pen follows the curved
owner path. No authored LinkPaint or focus-outline policy is fabricated. Static
Unicode/background support uses real shaped clusters under the existing LTR and
same-font admission rules, with ordinary selection paint preserved.

Native183 passed two repaired controls with eight explicitly retained passes
(native182 four,176 two,177 one,179 one), following a Gui/Test build with
Widgets182 bytes unchanged. App251 completed configure and the GUI/product
targets, then failed Test MOC parsing. App252 corrected the constructor token but exposed a second MOC lexer failure
and did not run tests. App253 changed only the identical JSON fixture to an
ordinary escaped literal; its targeted MOC check and Reader build passed, followed
by eleven passes and one invalid pre-focus selection expectation. App254 verified
the corrected ordinary-focus activation baseline in that single method while
retaining those eleven passes and five earlier passes. Controlled
frames and the ordinary ZA cancellation/MG pitch repair session were reviewed
separately. Raw prior failures, full-suite gaps and canonical-build limits remain.

The maintained 32-target recipe verifies forward and reverse reconstruction.
Eight native leaves differ from the delivered reference recipe. All pre-AF
canonical Test bytes remain exact after removing the five new methods, helpers,
include and slots with their later corrected bodies. The current glyph helper
endpoint equals private198; six other endpoints remain exact to predecessor08.
The qdoc/Test private exclusions
remain byte-identical before and after: the new AF focus edits in
QTextDocumentLayout::draw are exact, but its excluded absolute-container branches
prevent claiming whole-function equivalence. No private absolute, relative-float
or image-occurrence implementation is imported or admitted by this change.

The same-path QTextLayout header changes the private draw_internal signature and
its exported private symbol. Normal Gui and Widgets dependency rebuilds are
required; public callable API and class member layout remain unchanged. This is
recipe composition only, with no canonical binary rebuild or current source edit.

### AF fixture syntax correction (historical source stage)

Native175 built the source194 Gui/Widgets outputs but failed while compiling the
Test fixture, before any of its eight selected tests ran. Source195 adds one
missing closing brace to the RoundedLinkControl border initializer. Every test
method and assertion remains exact; the six product source endpoints are unchanged.
The canonical recipe carries only that one-byte Test correction in addition to the
AF/static source splice above. Actual qualification is now pending native176,
with product source194/build175 recorded separately as an original failed run.
No prior test or LTO-stage pass is inferred from the completed library outputs.

### AF source and caret-oracle correction (historical source stage)

Native176 compiled the corrected Test and executed eight methods: four passed
and four failed. Source196 changes only the four failed methods. Its invalid
Unicode fixture constructs FEFF literally instead of losing it through UTF-32
BOM decoding. Its cursor inverse compares the same shaped position with ordinary
Qt, retaining exact offsets when the ordinary inverse returns them.

The focus raster equality and foreign-policy refusal assertions remain unchanged.
Failure-only actual/expected/difference PNGs and variant/policy observations help
diagnose them; they confer no rendered acceptance or anticipated-failure waiver.
The prospective scope is now native177 current4 plus four exact native176 passes,
not an eight-method replay. Six product endpoints, the shared fixture and all
prior canonical Test bytes outside these four bodies remain exact. Product
source194/build175 remains separate, and all actual qualification pins stay unset.

### AF typed-policy and focus-only paint repair (historical source stage)

Source197 adds two narrow product fixes to the preceding immutable AF recipe.
InlineBox property 0x5831 uses the existing recursive exact-metatype comparator,
so a malformed string radius cannot be interned as a previously valid numeric
radius. An authenticated whole-box selection containing only OutlinePen queues
the native focus contour and leaves normal text on its ordinary paint path,
preserving italic overhang outside the layout bounds. Other selection formats
retain the existing selection/background/foreground behavior.

All Test bytes, strict raster/refusal assertions and eight method bodies remain
exact to source196. The prospective cold178 scope is a Gui-only build and two
current affected methods, with four native176 and two native177 passes retained
under explicit changed-source-domain proofs. This is not a claim that the Gui
binary is unchanged. Test retains its native177 binary; Widgets retains
its source194/build175 origin unchanged. Earlier failure and fixture-correction stages
remain immutable history. All actual qualification pins remain unset here.

Only qtextformat.cpp and qtextlayout.cpp change from the preceding normal-source
packet. The six other AF endpoints, including qdoc/Test private exclusions, are
exact. No unrelated absolute, float, image, overlay or bidi domain is imported.
A fresh canonical build still uses the cumulative AF header/Widgets dependencies;
this source-only reconstruction does not perform that build or claim full suites,
paired App frames, genuine producer/Reader or rendered AF acceptance.

### Fallback glyph source-index repair (historical source stage)

Source198 corrects the source-index walk when Qt emits a fallback-font subrun
beginning after glyph zero. It bounds cluster lookup and retains the existing
private rangeStart/rangeEnd convention, shaped positions, skipped glyph handling
and RTL output order. The existing Unicode control adds exact source-index and
hit checks; its ordinary shaping, selection and source assertions remain intact.
Only qtextlayout.cpp and that one Test method differ from predecessor08.

App248's original AX assertion remains failed history. Its read-only capture
identified the source-index mismatch without converting the failed test into a
pass. The candidate Test subsequently passed the retained native176 compiler's
single-TU syntax command using unchanged native197 headers and MOC; that is not
runtime or library qualification. Native175's original Test compile failure and
all subsequent native176/177 failures remain linked through immutable stages.

The pending native179 scope builds Gui and Test, runs three affected controls,
and carries five source-domain-proved passes from176/177/178. Widgets retains
source194/build175. Actual native179, App and frame pins remain unset. The normal
32-target patch recipe is reconstructed and reversed exactly, without a canonical
build, current-source change, or unrelated private feature import.

### Glyph-cache fixture setup correction (historical source stage)

The first native179 Unicode assertion inspected private shaping data immediately
after document layout. Qt may free that cache at endLayout while retaining its
lines. Source199 moves the same full-source glyphRuns call before the independent
cluster inspection, allowing Qt's public retrieval path to reconstruct the data.
Every returned-run, source-index, position, selection and caret assertion remains
unchanged, as does the default cache setting. No product source changes.

Native179's original two PASS/one FAIL rows and both failed final source guards
remain intact. The generated Test MOC bytes were unchanged; independent current
source stat/membership and selected-byte checks reconciled custody. The previous
cached state was not persisted, so no inode/time-only explanation is asserted.
That physical handback does not turn the raw qualification into a pass.

The pending native180 scope rebuilds Test only, runs the corrected Unicode method
and carries seven explicitly joined passes. Gui remains source198/build179 and
Widgets remains source194/build175. All seven normal product endpoints and private
exclusions are exact to predecessor09. Actual native180/App/UI pins remain unset.

### Hidden-glyph fixture correction (historical source200 stage)

Native180 progressed through cache reconstruction and strict glyph/source-index
checks, then failed the sawHiddenGlyph coverage assertion. ZWJ/ZWNJ/variation
selectors may become zero-advance HarfBuzz glyphs without Qt's dontPrint flag.
The source200 candidate adds one ordinary-layout retrieval case containing literal
U+00AD followed by visible AB. Qt explicitly hides the soft-hyphen cluster, while
AB prevents the line-end soft-hyphen reveal. This supplies the required witness
without changing the InlineBox text domain or removing any coverage assertion.
Existing fixture sources and exact source-index, position, geometry and caret
comparisons remain intact. Failure-only diagnostics report all coverage flags.

All seven product endpoints and prior canonical/private exclusions equal packet10.
Only the existing Unicode Test method changes. Source200 is not applied by this
packet; the planned native181 scope is Test-only current1 plus seven explicitly
joined historical passes. Product source198/build179 and Widgets175 stay distinct.
The original179 failed guards/reconciliation and original180 failure rows/XML are
preserved, without turning either attempt into a passing qualification. All actual
native181/App/UI qualification pins remain null. No build or runtime was invoked.

### Source-owned empty border overlays (historical source201 stage)

The actual MG source has a top-bordered, padded inline owner around original
Japanese text, with one empty absolutely positioned right-border descendant.
The existing box carrier now authenticates the original owner source, typed inset
and edge data, and the currentColor ownership. The inherited declaring brush is
resolved during normal paint, including palette and selection foreground changes.
The overlay uses the first/last inline padding-box containing geometry, paints once
after its owner, and participates in repaint traversal without adding text,
advance, or a line strut. This is the empty border-only domain; detached textual
content, nested circles, atomic/float boxes and unrelated private layout are not
included. Root paragraphs and validated ordinary root-owned table cells are
admitted; unsupported frame and foreign/malformed policy ownership still refuse.

Canonical projection changes five native leaves and preserves all prior exclusions.
The private-only absolute policy symbol at one refusal is represented by the same
property ID0x5861. This does not import absolute layout support. The two new controls
and all eight prior method bodies match private source201 exactly; all other
canonical Test bytes remain unchanged. The maintained32-target recipe is checked
forward and in reverse, with no canonical checkout or native build mutation.

Native182 built Gui, Widgets and Test; four controls passed and two failed.
Its generated MOC reached the exact syntax-derived endpoint, while stale cache
bookkeeping caused both raw final guards to fail. Independent closure reconciled
source custody without converting those failures into passes. Native183 repaired
the two selected controls with eight exact-body/domain passes retained and
Widgets182 bytes unchanged. App254 and the retained App251 GUI in the ordinary MG session separately
validated the genuine pitch owner. Full suites and whole-edition acceptance remain
separate.

The cumulative AF portion of this normal patch still includes its original
QTextLayout header/private exported signature change. Those cumulative package
facts remain distinct from source201: the latest five-leaf repair changes the
private inline-box header and renderer implementation but does not change public
header text, callable API, exported symbols or class member layout. Historical
fixture/retention and syntax198 metadata is archived under explicit historical
keys; that historical source201 scope was ten methods, six current plus four retained.
The manifest binds Native183, App254, the retained App251 GUI, controlled frames and the ordinary
ZA/MG repair session. These scoped qualifications do not authorize publication.

### Inline-box frame recovery and fixture correction

The source202 product change adds authenticated inline-box policy presence to
existing full layout invalidation. Ordinary FloatRight-to-InFlow table format
restoration therefore clears the earlier refusal through the maintained complete
revalidation path. No header, Widgets source, API or object layout changes.
The same strict two controls remain selected. The paint fixture now disables
layout before installing its paint device and enables it before measuring; its
three-row repaint stripe is cropped in the original overlay rectangle before
intersecting the image. Raster equality, nonempty stripe, top stroke, metric,
source and recovery assertions remain, with contextual failure diagnostics.

Only two of the eight cumulative native endpoints change. All prior private
exclusions and the refusal-only0x5861 projection remain identical. The saved
32-target recipe and four-file package are checked forward and backward without
reading or changing native working source, canonical files or the index.

Native182's build and LTO audit passed; its selected tests were four PASS/two FAIL.
Both raw source-after guards failed because an obsolete generated-MOC cache key
remained active after the exact new endpoint was installed. Independent physical
closure verified source custody and that endpoint without converting those raw
failures into passes. Native183 earned the two repaired controls and current Gui/Test products.
Eight exact-body/domain passes are retained separately; Widgets stays at182,
and unchanged Test MOC bytes use the existing same-byte transition. The manifest
binds the separate App and ordinary GUI evidence; no whole-corpus acceptance
is inferred.

### Cancelled owner choice and supplementary Han fallback

Cancelling an in-entry language choice preserves the existing query, result pages,
selection, filters and status; a pending ordinary search debounce resumes without
rewriting the query. Entry and Back history stay unchanged. Typed search retains
its separate exact-query behavior. The status bar shows a concise failure summary;
full recovery instructions remain in Reading and the results status.

The full unmodified HanaMinB font and its upstream dual license live once under
apps/shared/fonts. The GUI and Reader test resource reference that shared source.
Script_Han fallback preserves existing primary and kana font choices; U+20000 is
verified as the real glyph104 with an outline and raster, alongside exact source,
copy and accessibility offsets. First-use observations include ordinary UI
construction and explicitly make no cold-cache or matched performance claim.
