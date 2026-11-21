# Android validation

## Current inline-table bottom alignment — 2026-11-21

The qualified production source is commit
`5c26f9c0c512d3678c3f7d10c5a185ca49a83cd7`. Its
[commit/source bridge][bridge161-current] binds the ten changed files to the
982-file canonical inventory. Inline tables now have a separate bottom-alignment
value: the intact grid shares the parent line's bottom with its pronunciation
marker. The decoder requires the corresponding wide-header flag and an actual
inline-table payload; existing inline-box alignment remains separate.

[Host161][host161-current] passed **16 fresh focused JVM checks** with no failures,
skips or carry, including both new bottom-alignment checks and the affected
top/cell controls. Main, unit and instrumentation Kotlin compilation and
instrumentation Java compilation executed. The new pronunciation-marker device
control was compiled only.

The ordinary unfiltered `testDebugUnitTest` target then
[passed all 1,217 current cases][host162-current] across 155 reports: **zero
failures, skips or carried cases**. These comprise 1,215 correctness cases and
two benchmark-named controls, without a performance claim. Main and unit Kotlin
compilation reused up-to-date outputs; the test task executed. The independent
closure verified exact source and protected artifacts, absent owned processes
and free locks.

The [subsequent lint/package continuation][canonical163-current] completed debug
lint and ordinary unsigned release/vital tasks, reusing that full-suite result
without repeating JVM or instrumentation tests. Lint reported **zero errors,
37 warnings and five hints**, with no locations on lines changed by this commit.
Release Kotlin compilation, R8 and packaging ran; resource optimization reused
its up-to-date output. The [saved artifact audit][audit163-current] verifies the
new [retained APK][apk163-current]:

- Minimum API **31** (Android 12), target API **37**, package
  `app.smallthingz.dict`, version **0.4.0 / code 4**.
- **10,963,937 bytes**, unchanged in size from the prior verified APK, with changed
  `classes.dex`; SHA-256
  `f2063bd3b8b1df0151f23381fd4d9991d2b8dcbdc391f09c4c837680d8428020`.
- Four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`. Native libraries,
  fonts and licence payloads match the prior package. The separate table
  alignment class and line-geometry method are present in the release evidence.
- **Unsigned**. No signing, installation, device command or publication occurred.

The existing HOME Gradle, build and project caches were reused. Before replacing
mutable release outputs, the same worker preserved the five prior class/mapping
evidence files with verified hashes; the prior APK and receipts remain retained.
Both actual invocations and their independent closures returned zero. The
[normal-entry-point review][entrypoints163-current] also confirms that import and
record loading use the ordinary binary decoder; it is source evidence, not a
genuine ET dictionary or rendered-device acceptance result.

The physical-device access hold recorded below remains unchanged. No later
access clearance has been established; pixels, touch, selection and accessibility
remain unverified on the current physical Android build. The following sections
retain their historical qualification scopes.

[bridge161-current]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/et-bottom-alignment01/canonical-commit-bridge16101.json
[host161-current]: /home/a/.tmp/wikidict-android-host161-run01/saved-result-peer-reader01.json
[host162-current]: /home/a/.tmp/wikidict-android-host162-run01/saved-result-peer-reader01.json
[canonical163-current]: /home/a/.tmp/wikidict-android-canonical163-run01/completion01.json
[audit163-current]: /home/a/.tmp/wikidict-android-canonical163-run01/saved-result-peer-reader01.json
[apk163-current]: /home/a/.tmp/wikidict-android-canonical163-run01/retained/app-release-unsigned.apk
[entrypoints163-current]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/et-bottom-alignment01/entrypoints-sdk-source-review01.json

## Pegasus level-pitch regression — 2026-11-21

The retained Pegasus pronunciation already uses the native strict-interior
nesting path for its zero-padding level-pitch box without a drop indicator.
No renderer change was needed. One regression test now checks the exact text,
nested ranges, strict endpoint refusals and original Tokyo/Heiban link identities.

[Host160][host160-current] passed **five fresh focused JVM tests**: the new
Pegasus regression and four maintained pitch controls, with zero failures,
skips or carry. Main Kotlin compilation was up to date; unit Kotlin compilation
and the test task executed. Its independent closure verified the source,
protected artifacts, absent owned processes and free locks.

The inventory then declared 1,215 JVM tests. This focused run was not a new full
1,215-case result. The full 1,214-case result and lint/unsigned APK below provided
the evidence for the then-unchanged production source; packaging and instrumentation
were not repeated. This test establishes projection and branch-selection
behavior, not rendered pixels, touch or accessibility. The physical-device access
hold below remains unchanged.

[host160-current]: /home/a/.tmp/wikidict-android-host160-run01/saved-result-peer-reader01.json

## Historical table-border integration — 2026-11-20

The qualified Android production source at this boundary was commit
`b8ac8c2d47ec3f369cafb407d0dd6f6849c1f476`. Its [canonical application][application157]
and [commit bridge][bridge157] bind the 17 integrated files: 12 main, four JVM-test
and one instrumentation-test files, including seven new files. The canonical
inventory contains 982 files. The ordinary decoder and native table renderer now
consume the reviewed resolved table/cell borders, including owner-current-color
paint and the supported inset/outset and collapsed-border geometry.

[Host157][host157-current] passed 23 fresh focused JVM checks with no failures,
skips or carry, and compiled all three Kotlin routes: 170 main, 153 unit-test and
99 instrumentation sources. Its four new device controls were compiled only.

The normal unfiltered `testDebugUnitTest` target then [passed all 1,214 then-declared
cases][host158-current] across 155 reports, with **zero failures, skips or carried
cases**. This includes 1,212 correctness cases and two benchmark-named controls,
without a performance claim. Main and unit Kotlin compilation and the test task
all executed. The original invocation and independent closure returned zero;
the closure verified source and protected artifacts, absent owned processes and
free locks.

Gradle's dependency cache, build directory, project cache, temporary files and
qualification output now reside on HOME. The moved execution history contained
old absolute output paths, so the admitted worker preserved that history by an
atomic rename before the single Gradle invocation. Dependencies and compiled
outputs were retained; Gradle regenerated path-sensitive history normally.
The runtime filesystem reserve remained 2 GiB, and the original CPU, memory,
task and time limits were retained. Earlier admission failures remain recorded
and contribute no test credit.

The subsequent [canonical lint/package continuation][canonical159-current]
completed debug lint and ordinary unsigned release/vital tasks. It reused the
full-suite result without repeating JVM or instrumentation tests. Debug lint
reported **zero errors, 37 warnings and five hints**; none of its locations was
on a line changed by the table-border integration. This is not a zero-findings
lint result. Release compilation, R8, resource optimization and packaging
succeeded. The [saved artifact audit][audit159-current] verifies the current
[retained APK][apk159-current]:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, minimum API **31**
  (Android 12) and target API **37**.
- **10,963,937 bytes**, 32,768 bytes larger than the prior `bc0847` APK; SHA-256
  `66d77b8967c513ec43f4710da88d248c148a9f8cce4e134268f3235c1540b42f`.
- Four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`; native libraries,
  fonts and licence payloads match the prior verified package. The resolved-border
  classes and methods are present in the compiled and optimized release evidence.
- **Unsigned**. The saved verifier reports no valid signatures. Signing,
  installation and publication were not performed. Original APKs and signer
  locations remain unchanged.

A separate [genuine Greek input check][greek159-current] used the already compiled
Host157 `CountingInput`/`BlobDecoder` against the actual 3,799-byte language blob.
The complete 5-by-3 table projection, its 15 cells and 64 resolved edges matched
the saved Reader projection. Its [independent closure][greek159-physical]
verified the compiled classes and released the read interval. This is scoped
decoder/table evidence, not full-entry parity or a rendered-device result.

There is **no current physical Android rendering or interaction acceptance**.
The latest retained [owned access attempt][phone-namespace-hold] failed before
ADB with `PermissionError(13, 'Permission denied')`, with zero events and no
device command or input. No later owner/access clearance has been established,
and no retry, alternate access path, signing or install action was taken here.
Pixels, touch, selection and accessibility still require permitted device access,
coordinated custody and a compatible authorized signed installation.

This section records the completed production-source and artifact boundary.
The sections below retain their historical results and do not replace the
current scopes above.

[application157]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/table-resolved-edges01/canonical-application01.json
[bridge157]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/table-resolved-edges01/canonical-commit-bridge01.json
[host157-current]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host157/saved-result-peer-reader01.json
[host158-current]: /home/a/.tmp/wikidict-android-host158-run01/saved-result-peer-reader01.json
[canonical159-current]: /home/a/.tmp/wikidict-android-canonical159-run01/completion01.json
[audit159-current]: /home/a/.tmp/wikidict-android-canonical159-run01/saved-result-peer-reader01.json
[apk159-current]: /home/a/.tmp/wikidict-android-canonical159-run01/retained/app-release-unsigned.apk
[greek159-current]: /home/a/.tmp/wikidict-android-genuine-greek01/runtime01/semantic-result01.json
[greek159-physical]: /home/a/.tmp/wikidict-android-genuine-greek01/runtime01/direct-runtime01/independent-closure01.json

## Historical nested-pitch and FlexColumn integration — 2026-11-20

The current Android production source is commit
`4b9d2dbacf2562e771ad9fc50e5ce634735a4fac`, **Android: render nested pitch and
flex columns**. Its [canonical application record][current-application-156]
binds the 19 integrated files to the qualified private inputs: 14 main, four JVM
test and one instrumentation test files, including five new files. The canonical
inventory contains 975 files. These changes use the ordinary native text and
container rendering paths. Nested pitch is limited to the reviewed Japanese
parent/child shapes; FlexColumn preserves source order, empty bordered children
and original actions. Wider producer shapes and genuine page interoperability
are not established by these host checks.

[Host156's successful continuation][host156] passed **24 fresh focused JVM checks,
with zero failures, skips or carried cases**, and all three Kotlin compilation
routes: 165 main, 152 unit-test and 98 instrumentation sources. The seven selected
device controls were compiled only. Earlier worker-launch, disk-admission and
affinity-guard failures remain in their original records; they ran no Gradle
tests and contribute no pass credit.

The subsequent [canonical follow-up][canonical156] ran the normal unfiltered
`testDebugUnitTest` target on the integrated source. **All 1,200 cases passed
freshly across 154 reports, with zero failures, skips or carried cases.** This
includes 1,198 correctness cases and two benchmark-named controls, without a
performance claim. Main and unit Kotlin compilation were up to date; the test
task executed. Debug lint also executed: **zero errors, 37 warnings and five
hints**. Its saved changed-line comparison found no finding on a changed line;
this is not a zero-findings lint result.

The same follow-up built the current local unsigned release. Release Kotlin,
R8, packaging, assembly and release-vital checks succeeded; unchanged resource
optimization and the vital-report task were up to date. Native libraries were
verified unchanged. The original command returned zero, its watchdog recorded
normal child exit and completed cleanup, and the closure verified all 975 source
files and free locks. The [retained APK][apk156] has:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, minimum API **31**
  and target API **37**.
- **10,931,169 bytes**, 16,384 bytes larger than Package154; SHA-256
  `bc0847e1659d64be15babc3349dd6e4b9382665e82815a8ed48599ae0b5115cc`.
- Four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`.
- **Unsigned**. The saved signature verifier reports `DOES NOT VERIFY` and
  `Missing META-INF/MANIFEST.MF`; no signer or installability qualification is
  claimed. No signing, installation or publication was performed.

The later commit `f4c1866ae9b45ce82208505ed67c68c6ba16bd13` changes only
`NativeContainerHeightDeviceTest.kt`. Its new
`flexColumnKeepsItsEmptyBorderAndOriginalActionsAcrossWidthAndDirection` control
[compiled successfully][column-device156] after correcting a test-only
`CharSequence?`/`String` mismatch; the [initial compiler failure][column-failure156]
is retained. Instrumentation Kotlin executed, while main Kotlin and
instrumentation Java were up to date. It ran no JVM or device test and rebuilt
no package. Production, JVM-test, resource and build inputs remain identical to
the full-suite and APK source, so those results remain applicable without replay.

There is **no current physical Android rendering or interaction acceptance**.
The [saved physical-access attempt][phone-namespace-hold] failed before ADB with
`PermissionError(13, 'Permission denied')` during host namespace identification,
with zero events and no device command or input. The denied path and process
were not recorded; no specific daemon is blamed. No later access recovery is
established. Device execution still requires permitted namespace access,
coordinated phone custody and an authorized compatible signed installation.
Host tests and compilation do not substitute for pixels, touch, selection,
accessibility or genuine producer-to-reader acceptance. Package154 and older
artifact histories, installed data and signer holds remain separate and intact.

This update changes documentation only. The following sections preserve their
results at the earlier source boundaries; their historical uses of “current” do
not supersede the source and artifact recorded above.

[current-application-156]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/mg-nested-pitch01/canonical-application01.json
[host156]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host156-dispatch06/saved-result-peer-reader01.json
[canonical156]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/canonical156-followup01/completion01.json
[apk156]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/canonical156-followup01/retained/app-release-unsigned.apk
[column-device156]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/canonical156-column-device02/completion01.json
[column-failure156]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/canonical156-column-device01-debug/stderr
[phone-namespace-hold]: ../../../.tmp/android-history-preview71/physical-historical-test65-update313/foreign-daemon01/qualification-live01/observation/passive-result.json

## Historical HU/RT, empty-entry and preview integration — 2026-11-19

The current Android product is commit
`c733b84d26638bfa9e34eb11ed503bf7b67adb0e`, **Android: render ruby margins and
improve entry previews**. The [commit bridge][current-bridge-153] proves that its
24 files match the qualified private inputs: 14 main, six JVM-test and four
instrumentation-test files, including six new files. The canonical source
inventory contains 970 files. These changes are integrated into the ordinary
decoder, entry view and saved-entry paths, not a separate private candidate.

The changes support ruby annotation margins and intrinsic two-line inline boxes,
show an accessible notice for entries with no content, and include table senses
in history/bookmark clues when no explicit definition or prose clue is available.
The Ido `abako` control retains both source-derived senses; the output remains
bounded to 420 UTF-16 units without splitting a supplementary character. Existing
explicit definitions and prose keep priority. Saved clues refresh through the
normal entry-revisit path.

[Host152][host152] ran **34 fresh JVM correctness checks: 34 passed, zero failed,
skipped or carried**. These include 23 HU/RT checks, four empty-entry checks and
seven Ido preview checks. Main and unit Kotlin compilation passed. That invocation
failed instrumentation compilation because one new fixture selected a font-family
enum value that the model does not support; its original failure remains recorded.
The correction changes only four matching font selections in that device fixture,
preserving every assertion and all production/JVM source bytes.

[Host153][host153] then passed instrumentation Kotlin compilation, with main Kotlin
and instrumentation Java up to date. It ran **zero new JVM cases** and retained the
exact 34 Host152 passes. The source routes bind 163 main, 150 unit-test and 97
instrumentation inputs. The 11 relevant device controls (nine new, two maintained)
are **compiled only**. Both runs have their original command terminal and independent
process, lock and source closure.

[Host155][host155] subsequently ran the normal, unfiltered JVM target and passed
**all 1,187 current cases freshly: zero failures, skips or carried cases**.
This includes 1,185 correctness tests and two benchmark-named controls, with no
performance claim. Main and unit Kotlin compilation were up to date; the test
task executed. All 152 report files and their case identities, source inputs and
timestamps were audited. The original command returned successfully, and owned
processes and locks were independently closed. No instrumentation, lint, JNI or
package task was repeated.

The full-suite inputs match Package154's production, test, resource and build
inputs; only the intervening validation-document update differs. **Package154
therefore has full current JVM qualification without a rebuild.** The earlier
[Host155 disk-admission refusal][host155-refusal] remains recorded separately:
it stopped before Gradle and ran zero tests. The successful continuation retained
the original source, caches and limits after verified storage cleanup.

[Host150's 1,165 fresh passes][host150] remain historical evidence for the preceding
`6ee35c48` product. [Host151's genuine Korean blob check][host151], integrated as
test/resource-only commit `8581e646`, is now included in the full current run. It
proves decode, complete entry and logical-range behavior, not glyph, hit-test or
accessibility rendering.

**Package154 is the current verified unsigned host artifact**, built from the
integrated `c733b84d` product. Release Kotlin compilation, R8, packaging, assembly
and ordinary release-vital checks passed. Resource optimization and the vital
report task were up to date. The [saved package audit][package154] records:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, non-debuggable;
  **minimum API 31, target API 37**.
- **10,914,785 bytes**, 16,384 bytes larger than Package149.
  SHA-256: `b6dba78903a2ae39fbbe4b5c1df7ef2bf03adad34556e260284cdd6b04634ddc`.
- 99 ZIP members, with no members added or removed. Only `classes.dex` and the
  two baseline-profile members changed. The 497 native source inputs, four
  optimized JNI libraries, packaged fonts and licences retain their verified bytes.
- **Unsigned**: no APK signing block or JAR signatures; release signing is not
  configured. The signature verifier exits 1 with `DOES NOT VERIFY` and
  `Missing META-INF/MANIFEST.MF`. No signing or signer qualification is claimed.
- VCS metadata reports `NO_SUPPORTED_VCS_FOUND`; the exact source manifest and
  commit bridge establish provenance, not an embedded revision.
- No JVM, instrumentation, JNI compilation or full lint was repeated by packaging.
  Its original command returned successfully and all owned processes and locks
  were independently closed.

The retained artifact is [Package154's release-unsigned.apk][apk154]. Package149
and the older unsigned archives, signed102 and installed62 artifact roles remain
preserved. No signing, installation, user-data operation or publication occurred.
The pre-ADB namespace `EACCES` still has no established recovery. Current phone
pixels and interaction require permitted physical access and an authorized
compatible signed installation; no current Android rendered frame is claimed.
Genuine producer-to-reader interoperability remains a separate qualification.
This documentation-only update follows packaging and changes no production, test,
resource or build-configuration input. Older sections retain their results at
their recorded boundaries.

[current-bridge-153]: ../../../.tmp/renderer-core-oct28/de-mai-ancestor-dag01/android-pending-y01/chemical-intrinsic01/canonical-commit-bridge01.json
[host152]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host152/saved-result-peer-reader01.json
[host153]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host153/saved-result-peer-reader01.json
[host155]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host155-dispatch02/saved-result-peer-reader01.json
[host155-refusal]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host155/saved-prechild-peer-reader01.json
[host150]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host150/saved-result-peer-reader01.json
[host151]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host151/saved-result-peer-reader01.json
[package154]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package154/saved-result-peer-reader01.json
[apk154]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package154/artifacts/release-unsigned.apk

## Historical scoped MG/HU integration and unsigned package — 2026-11-19

The current Android product is commit
`fd1718bbdb6b6a015d2e38fa127d8a6f2805773d`, **Render inherited cell ink and
auto-sized inline boxes on Android**. Its 24 files comprise 18 main, three JVM-test
and three instrumentation-test files, including six new files. The
[commit bridge][mg-hu-bridge] records exact equality between the integrated files
and the qualified private inputs. The canonical source inventory contains 962
files. The changes use the ordinary decoder and entry-rendering paths; they are
not an unmerged private candidate.

Host146 passed **25 fresh JVM correctness checks, with no failures, skips or
carried cases**: 14 new controls and 11 maintained regressions. All three Kotlin
routes compiled: 161 main, 147 unit-test and 95 instrumentation inputs. The 11
relevant device controls (four new and seven maintained) were **compiled only**.
The [Host146 audit][host146] binds the raw cases, compiler inputs and independent
source/process/lock closure. Its outer remote-command terminal was unavailable;
saved worker success and independent physical closure are established, while the
outer exit and reaping status remain unknown. No repeated test run was used to
replace that missing transport observation.

The current declared suite contains **1,163 cases**. No full 1,163-case pass or
carry of the other cases is claimed. Host144's 1,149 fresh passes below remain a
historical full-suite result on the earlier FR source.

**Package147 is the current verified unsigned host artifact**, built from the
integrated `fd1718bb` source. Release Kotlin compilation, R8, `packageRelease`,
`assembleRelease` and release vital checks passed. Resource optimization and the
vital report task were up to date. The 497 native inputs and four optimized JNI
libraries were verified and reused. Packaging repeated no JVM tests,
instrumentation tests, JNI compilation or full lint. Unlike Host146, Package147
has its original successful remote-command terminal and completed physical
closure. The [saved package audit][package147] records:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, non-debuggable;
  **minimum API 31, target API 37**.
- **10,898,401 bytes (10.39 MiB)**, 16,384 bytes larger than Package145.
  SHA-256: `d61bc7b01a8e902293331e7327523202e4dd684e9853a8c3813b64e602cdf51e`.
- 99 ZIP members. `classes.dex` and both baseline-profile members changed;
  `META-INF/services/fw` became `META-INF/services/gw` with the same payload.
  JNI libraries, fonts and licences retain their verified bytes.
- **Unsigned**: no APK signing block or JAR signatures. The signature verifier
  exits 1 with `DOES NOT VERIFY` and `Missing META-INF/MANIFEST.MF`. This artifact
  is not installable as-is; no signer qualification or signing is claimed.
- VCS metadata reports `NO_SUPPORTED_VCS_FOUND`. The authenticated source manifest
  and commit bridge establish provenance; no embedded revision is inferred.

The retained build is [Package147's release-unsigned.apk][apk147]. Package145 and
the earlier unsigned archives, signed102, installed62 and user data are preserved.
The pre-ADB namespace `EACCES` has no established access recovery. Current phone
pixels, hover, touch, selection, copy, accessibility, IME, media and lifecycle
validation require permitted physical access and an authorized compatible signed
installation. No current rendered Android frame is claimed for these new controls.
Genuine producer/Writer/reader interoperability remains a separate qualification.
No signing, installation, publication or physical-access change was performed.

[mg-hu-bridge]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/android-mg-hu-auto-canonical-commit-bridge01.json
[host146]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host146/saved-result-peer-reader01.json
[package147]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package147/saved-result-peer-reader01.json
[apk147]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package147/artifacts/release-unsigned.apk

## Historical full-suite and Package145 qualification — 2026-11-18

This section retains the earlier FR source, full-suite and package evidence.
References to current qualification here apply to that earlier boundary;
the current MG/HU scope and Package147 are recorded above.

The current Android product is commit
`a22f5f12b1928421762907e5b6e5f50cb7c3c67d`. Host144 ran the complete discovered
suite: **1,149 fresh passes, zero failures, errors, skips or carried cases**.
This includes 1,147 correctness cases and two benchmark-named cases, with no
performance claim. Main and unit Kotlin compilation were up to date on the exact
Host143 source paths. Host143's instrumentation compilation remains qualified on
identical inputs; no instrumentation task or device test was repeated. Its earlier
17 selected passes remain a separate result. The [full-suite audit][host144]
binds the raw cases, canonical source comparison and physical closure.

**Package145 is the current verified unsigned host artifact**, built from that
integrated FR source. Ordinary `assembleRelease`, release Kotlin compilation,
R8, packaging and release vital checks passed. Unchanged resource work stayed up
to date. The 497 native inputs and four optimized JNI libraries were verified and
reused. Packaging ran no JVM tests, instrumentation tests, JNI compilation or full
lint. The [saved package audit][package145] records:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, non-debuggable;
  **minimum API 31, target API 37**.
- **10,882,017 bytes (10.38 MiB)**, 32,768 bytes larger than Package142.
  SHA-256: `1f758496c90fe012efcbc1f91cd81a8777cc8e5ec5f98c24b0026ce55aa0ce9d`.
- The same 99 ZIP members, with only `classes.dex` and the two baseline-profile
  members changed. JNI libraries, fonts and licences retain their verified bytes.
- **Unsigned**: no APK signing block or JAR signatures. The signature verifier
  exits 1 with `DOES NOT VERIFY` and `Missing META-INF/MANIFEST.MF`. This artifact
  is not installable as-is; no signing, installation or signer qualification is
  claimed.

The retained build is [Package145's release-unsigned.apk][apk145]. Package142 and
the earlier unsigned archives, signed102, installed62 and user data are preserved.
The pre-ADB namespace `EACCES` still has no established access recovery. Current
phone rendering and interaction require permitted physical access and an authorized
compatible signed installation. Genuine complete FR producer/Writer/reader
interoperability and physical pixels, hover, selection and accessibility remain
separate from these host results. No publication is authorized by this qualification.

[host144]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host144/saved-result-peer-reader01.json
[package145]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package145/saved-result-peer-reader01.json
[apk145]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package145/artifacts/release-unsigned.apk

## Historical scoped FR integration and Package142 — 2026-11-18

This section preserves the earlier scoped integration and package evidence.
References to current qualification here apply to that earlier boundary; Host144
and Package145 above supersede its full-suite and unsigned-artifact roles.

The canonical Android implementation now includes commit
`a22f5f12b1928421762907e5b6e5f50cb7c3c67d`, **Support detached inline overlay
text in Android**. The 16 changed files comprise 12 main, two JVM-test and two
instrumentation-test files, including three new files. The [FR commit bridge][fr-bridge]
records exact equality with the qualified private inputs and the 13 earlier
candidate edits already satisfied by current code. The canonical source inventory
now contains 956 files. These FR changes are not in Package142.

Host143 passed **17 freshly executed JVM correctness checks**, with no carried
cases: ten new FR controls and seven maintained regressions covering atomic boxes,
radius/opacity custody, rich-source projection and NBSP actions. It compiled all
three Kotlin routes: 158 main, 145 unit-test and 94 instrumentation inputs. The
14 relevant device controls (nine new and five maintained) were **compiled only**.
The [Host143 audit][host143] retains the raw results and physical/source closure.
The declared suite now contains 1,149 cases; no full 1,149-case run is claimed.

The preceding canonical implementation includes commit
`86f83199d63ecc5b24f54d5f71534113bd71bbdb`, **Support scoped MG inline decorations
and cell opacity**. Its 31 files comprise 18 main, seven JVM-test and six
instrumentation-test files, including 11 new files. The integration includes the
RectF API correction and both later fixture corrections. The exact file list and
qualified private-to-canonical byte comparison are in the [commit bridge][mg-bridge].
The retained `mg-tooltip-circle01/private-host01/application03.json` is the
qualification input for this completed integration, not an unmerged product.
Package142's 953-file source manifest belongs to this MG baseline. Its product
inputs remain distinct from the subsequent FR source integration above.

The preceding MG JVM qualification covers **1,139 cases**: 1,137 correctness cases
and two benchmark-named cases, with no performance claim. Host140 ran all 1,139:
1,137 passed and two test fixtures failed. Host141 then ran and passed the two
corrected methods, carrying the exact 1,137 unchanged passing cases and their
source/helper evidence. This is **1,137 carried passes plus two fresh passes**,
not a fresh full-suite pass on the corrected files. The [Host141 audit][host141]
preserves Host140's original failures and identifies every carried case.
Host139's earlier main-compilation failure is also retained.

Host140 compiled all three Kotlin routes: 157 main, 144 unit-test and 93
instrumentation inputs. Host141 recompiled the changed unit tests; main was up
to date and instrumentation evidence was carried on identical inputs. The eight
new MG device controls were **compiled only**, not executed on a phone.

**Package142 is the current verified unsigned host artifact.** Ordinary
`assembleRelease`, R8 and release vital checks passed on the `86f83199` MG source.
The existing native libraries were verified and reused; no JNI build, JVM test
or instrumentation run was repeated. Release vital checks do not constitute a
new full-lint result. The [saved package audit][package142] records:

- Package `app.smallthingz.dict`, version **0.4.0 / code 4**, non-debuggable;
  **minimum API 31, target API 37**.
- **10,849,249 bytes (10.35 MiB)**, 32,768 bytes larger than unsigned Package138.
  SHA-256: `cf774f1cb7df33402e2dd4fecfbb7549f94c43c318a9a39a75726c94ae7e3ae4`.
- No APK signing block or JAR signatures. Signature verification reports
  `DOES NOT VERIFY`; this artifact is **not installable as-is**. No production
  signer qualification, signing, installation or publication is claimed.
- Four Egyptian JNI libraries, fonts and licences match the preserved inputs.
  No dictionary or executable corpus payload was added. The VCS metadata reports
  `NO_SUPPORTED_VCS_FOUND`; the source manifest and commit bridge establish
  provenance, not an embedded revision.

The retained APK is [Package142's release-unsigned.apk][apk142]. Earlier signed
artifacts, the installed62 pair and user data remain preserved. A passive host
network-namespace read returned `EACCES` before any ADB command; no newer access
recovery is established. Current-source phone rendering, hover/tooltips,
keyboard/IME, spoken accessibility, media and lifecycle validation still need
permitted physical access and an authorized compatible signed installation.

Historical rendered screens retain their original scope. The retained image
border failure from device run266 was followed by test-only ripple/focus
synchronization and a passing run275 of the same Compose method, including its
exact pixel assertions. Run275 emitted no success screenshot and is not current
whole-app rendering evidence. The [saved-screen disposition][screens142] also
records the reviewed search/Clear-focus frames and prior link/Learn dispositions.
There are no retained current Android rendered frames for the new MG circles,
nested decorations, NBSP or cell-opacity controls. Genuine producer/Writer/reader
interoperability and whole-page fidelity remain separate from host qualification.

The original French positioned-overlay packet (`cf93be81`) remains an immutable
source-only record. Its current-base successor (`fd70b1ce`) supplied the 16 edits
qualified by Host143 and integrated above; no source-integration dependency
remains for that selected scope. Detached text retains logical source, copy and
accessibility ordering while staying outside normal line breaking and advance.
Wrapped placement uses the measured LTR first/last padding-fragment rule; wrapped
RTL and bidi-split owners remain outside the supported scope. Genuine complete
FR producer/Writer/reader interoperability and rendered phone behavior remain
unqualified. No new APK was built for these changes, and no signing, installation
or physical-access hold was changed.

The evidence links below refer to retained local `.tmp` records, not published
assets.

[mg-bridge]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/android-mg-canonical-commit-bridge01.json
[fr-bridge]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/android-fr-overlay-canonical-commit-bridge01.json
[host143]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host143/saved-result-peer-reader01.json
[host141]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/host141/saved-result-peer-reader01.json
[package142]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package142/saved-result-peer-reader01.json
[apk142]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package142/artifacts/release-unsigned.apk
[screens142]: ../../../.tmp/renderer-core-oct28/sr-next268-source01/tallrik-cell-style01/android-consumer01/container-working01/package142/retained-rendered-screen-disposition01.json

## Historical Host78–Package82 qualification — 2026-11-16

This section preserves the earlier source20 qualification. Its references to
“current” apply to that dated baseline, not the canonical source and Package142
above. No earlier test, lint, signer or device result is restamped as current.

The current [build target](../app/build.gradle) is **Android 12+ (minimum API 31),
target API 37**. Required guards for later APIs remain. The qualified APKs were
built from source20, commit `b6b41b1e`. The subsequent commit `41370ede` removes
four redundant API 31 annotations and their two imports from two files; all
method and control bodies are unchanged. It was not separately compiled,
linted or packaged, so the APK lineage remains source20.

The current JVM qualification covers **937 cases**: 935 correctness tests and
two benchmark-named tests, with no performance claim. Host80 executed all 937:
936 passed and one failed on a stale native table-depth expectation. Host81
passed that corrected method and carried the exact 936 unchanged passing cases.
This is **936 carried passes plus one fresh pass**, not a fresh 937-test pass.
Host79 separately passed the 12 selected JVM controls. Main and
instrumentation compilation from Host78 is retained on unchanged inputs; that
run's later unit-compilation failure remains recorded. Device controls have
compilation evidence only for this candidate.

Package82 passed normal lint and debug Main/test APK qualification with all
compilation tasks up to date: zero lint errors, 36 warnings and five hints.
It reused the earned JVM results and native libraries without rerunning them.
Both APKs retain the expected API 31/37 identity and signing certificate. Main
retains its assets and four Egyptian JNI libraries; the test APK has no native
libraries. The [deterministic packaging setting](../gradle.properties)
produced no stranded virtual-entry space. Main/test APK SHA-256 prefixes are
`ae7f5a36` / `27e2bd1a`; their sizes are 81,691,779 and 11,556,303 bytes.

**Package82 is uninstalled; physical-device qualification remains pending.**
The installed62 pair and user data remain unchanged. A host process
network-namespace read failed with `EACCES` during preflight, before any device
command; preflight remains blocked on that unreadable namespace field. Earlier
device results do not establish acceptance of these APKs.

The genuine 1,852-byte Writer176 blob has host decoder coverage for its complete
body, Ruby font bases and actions. Ordinary Main import/read, rendered Ruby
actions, missing-target recovery, link/Back navigation, narrow layout,
soft-keyboard/cursor behavior and accessibility still need current device
evidence. The one-record fixture has no destination for its `旅路` links and
cannot prove successful destination navigation. Existing compiled controls
cover focused popup Retry activation and error recovery; they were not run on
this APK pair. No spoken TalkBack acceptance is claimed.

Release and prerelease publication remain on hold until the user explicitly
approves them. These debug APKs are not a production release.

## Historical Host72–Package74 qualification — 2026-11-16

This retained baseline predates source20. “Current” in this section refers only
to that earlier qualification; Package82 above supersedes its APK and lint roles.

The current [build target](../app/build.gradle) is **Android 12+ (minimum API 31),
target API 37**. Older-platform compatibility paths have been removed; guards
for APIs introduced after API 31 remain where needed.

Host72 passed all **926 JVM tests** (924 correctness tests and two benchmark
tests, with no performance claim), compiled the main and instrumentation
sources, and verified the merged API 31 manifests. The 26 selected device
controls were compiled only. Package73 then qualified the debug Main/test APK
pair and lint: zero errors, 36 warnings and five hints.

Package74 validated the [deterministic packaging setting](../gradle.properties)
with both compilations up to date and no JVM, lint or native rebuild. Its APK
contents, stable ZIP metadata, signing certificate, assets and four Egyptian
JNI libraries match Package73; obsolete ZIP space was removed. Host72's tests
and Package73's lint remain separately earned results on unchanged code inputs.
The current debug Main/test APK SHA-256 prefixes are `b251232f` / `a19751e6`;
the packaging change is commit `cccb60ed`.

**Physical-device qualification of this current APK pair is pending.** Earlier
device results do not establish current rendering, interaction or accessibility
acceptance. Release and prerelease publication remain on hold until the user
explicitly approves them; these debug APKs are not a production release.

All evidence below is historical. References to “final source,” older API
minimums and installed artifacts apply only to their dated qualification.

## Saved previews and compiled grammar qualification — 2026-10-07

The final source passed all **32 JVM tests** (zero failures, errors or skips),
plus lint with zero errors and 14 existing warnings. Optimized validation and
unsigned release builds passed with unchanged source; every recorded build
process closed. The APKs are version 0.3.0/code 3, minimum API 28/target API 37,
non-debuggable, and contain no native libraries or development dictionaries.
The optimized validation APK SHA-256 is
`af4868b37f7a17e417b1ecb9fba579bbb05ab9f7b714d30240bcb36117146715`;
the unsigned release APK SHA-256 is
`7df96d0bc6d8cbc2fe2399edfdf7ead9936cbc629edb258bbc08d77302b6a711`.
The `.validation` APK uses the existing debug signing identity and was installed
in place on the same API 36 Xiaomi device. Installed bytes match the qualified
artifact. The production-package APK was built and inspected, remains unsigned,
and was **not installed**; an established production signer is still required.

Saved clues keep definition priority and exclude media/audio-only fallback spans
without changing reader content. The actual full AF144 Engels collection (1,322
records) and matching 88-record alias sidecar were already installed. Its saved
original alias `spinal chord` reopened the scoped `spinal cord` entry and refreshed
the cached clue from pronunciation filenames to `(anatomie) Rugmurg`. Original
alias/source context, the other English and Arabic saved rows, and pronunciation
controls remained. Selecting another word before force-stop and then inspecting
Saved proved the new clue persisted without first rereading the Afrikaans entry.
JVM regressions additionally prove exact-scoped clue refresh preserves saved time
and review metadata, including when history is disabled. No broad startup reindex
or destructive re-saving is performed; ambiguous legacy identities are unchanged.

The synthetic compiler V2 fixture (2,748 bytes, SHA-256
`80c3448a3204271d69bf9b3041aacc424193fc8be9efb5d482a39b71cc6ef958`)
was imported with the normal file picker under an unscoped filename. Physical
checks confirmed ordered labels `3`, `1`, `8`, `9`, `ii`, `i`, the single real
meaning, nested terms and the nested table, and protected literal text in body,
media caption and reference footer. A normal tap on `[audit 1]` opened the folded
References section and displayed its exact compiled destination. The entire
reference text was visible, 168 pixels above all five bottom-navigation buttons.
Independent saved-image review confirmed the layout. The fixture's synthetic
`Grammar.png` is unavailable; this is not a live-media test. Literal delimiters
preserved from protected source are valid compiled text, not runtime markup.

A separate selected-corpus check imported the accepted AR149 supplemental
collection (55 records) and alias sidecar (1,756 records). The exact page
`ملحق:يونيكود/هانغل جامو` displayed the U+1100 Name cell as
`HANGUL CHOSEONG KIYEOK`, with no visible `reserved-1100`. Its retained,
source-authenticated character-list Lua diagnostic remained visible. This proves
that selected metadata repair renders correctly; it does not establish an
error-free page or whole-Arabic semantic acceptance. A separately reviewed,
self-targeted QA helper entered the Unicode query through the normal accessibility
text action, then was removed. It changed no keyboard, clipboard or global
settings and was not a rerun of the application instrumentation suite.

All original installed collections and saved entries remained; visible app
settings and global network/input settings matched the preflight state. Only
owned temporary helper/staging files were removed. Final receipts and exact
screenshots are retained under ignored `.tmp/android-qa-20261007/`. The earlier
19 debug instrumentation tests, live-download/media checks and 24-swipe frame
smoke below remain **historical evidence on the prior APK**, not reruns against
this successor. The final physical scope is one API 36 device, with no new frame
benchmark, current live-download test, or physical speech-quality claim.

## Earlier corpus compatibility qualification — 2026-10-07

Device: Xiaomi M2101K7BG, Android API 36; isolated package `app.smallthingz.dict.validation`. The installed APK was hashed before and after instrumentation. Existing unrelated applications and their data were left intact; the phone stayed awake. Private DNS remained `hostname` / `dns.adguard.com` throughout this run.

23 JVM tests and 19 device tests passed, with no skipped live-network tests. The final debug source guard passed. Coverage includes strict DAL1 decoding, real Afrikaans aliases (all 88), main and supplemental entries, all empty fixed-kind stores, Unclassified headings, same-name dictionaries from different source editions, one-edge alias navigation and missing targets, saved selections and removal, schema-1 migration, raw/XZ imports, checksum and canonical-filename/header rejection without damaging an existing install, and source-aware media/cache isolation. Leading U+FEFF in both a real alias title and a synthetic language heading survives Android SQLite writes, reloads, exact and prefix searches, links and saved identity; query plans retain the lookup indexes. A fresh core C ABI reader independently checked the alias-edge and BOM fixture semantics.

The UI test renders an exact two-record Arabic publication excerpt, checks that the short title occupies one line, and switches from an alias without an identified speech language to Arabic to prove the prior error clears. Portrait captures cover Arabic shaping and mixed text, alias breadcrumbs/preamble, source-edition choices and settings. The historical 30-entry compiled English QA slice (`cat`) displays live Commons images, artist/license credit and source actions. Offline word synthesis, folds and accessible slider updates also passed. These excerpts and synthetic edge fixtures are documented in `app/src/androidTest/ALIAS_FIXTURES.md`; this is reader conformance and device smoke coverage, not a claim that every corpus page has been visually inspected. The older English slice still contains a visible Wikidata logo filename; it is not evidence of the current compiler output.

The real Android DownloadManager retrieved the public canonical fixture from release `app-qa-fixtures-20261007`, verified 3,365,898 bytes / SHA-256 `1388760245fdfc7aaadebe1770415f44cf26e391811abae8d62b4044528b4ee3`, bound the English heading hash and `enwiktionary-20260901` scope, installed it and looked up `cat`. It is explicitly a 30-entry QA fixture. Live Commons image decoding and audio duration checks passed without changing network settings; isolated transport tests separately verify per-edition fallback and same-filename cache separation.

Legacy schema-1 dictionaries remain unscoped and existing saved data are preserved. If an older installation already lost an initial BOM in its index, this change cannot infer it safely and does not reindex the entire corpus during startup. Remove/reimport that affected dictionary to rebuild the index from authoritative bytes; newly imported canonical dictionaries have distinct scoped identities. Legacy saved selections reopen only when their retained title, language, kind and source scope identify a unique available entry.

The optimized `.validation` APK (SHA-256 `62e552c095c5cc96b2bd1d8de8cca61da827dd46e848a45217bab1ce01bdbf35`) passed a real public-catalogue download, canonical Arabic SAF import, exact Arabic selection/bookmark restoration after force-stop, same-word source selection, saved-entry reopening, live image/credit rendering and an error-free offline-speech button request. Its 24-swipe `cat` smoke (12 forward, 12 backward, 400 ms each) recorded 891 frames, 36 janky frames (4.04%), p50 10 ms, p95 17 ms and p99 25 ms. This is one bounded run, not a comparative speedup or a claim about every dictionary. Independent image review confirmed readable Arabic, complete media credit and distinct source choices in the optimized captures. Lint passed with zero errors and 14 warnings. The combined lint/performance/release invocation reported JVM metaspace pressure and failed in release compilation after the optimized APK completed; release compilation passed in a fresh bounded JVM on unchanged source. The final `assemblePerformance assembleRelease` retry passed with its source guard unchanged. The packaged optimized APK exactly matches the bytes tested on the phone. The unsigned production-package APK is 2,791,410 bytes, SHA-256 `fbaa919fd1a7dd36bd8be508ceda036ec0b6c2d19e916cf41e91c37e81d0ebcb`; archive/manifest checks passed and apksigner confirmed it has no signature. It was not installed. Both APKs target SDK 37, require SDK 28 or newer, contain no native libraries and bundle no dictionary/test fixtures. The optimized APK verifies with the existing Android debug certificate SHA-256 `451d06e1441fd8288e80d82b28598c36668478744db78f192c9e17ec459977fd`. All owned Gradle processes have exited. Local receipts and APK snapshots are under `.tmp/android-qa-20261007/`; phone screenshots are under `/home/a/Pictures/Screenshots/wikidict-android-20261007-device07/`. Debug and optimized validation APKs use the existing debug key and the `.validation` package. The production release variant has no configured signing identity and is delivered unsigned for the established release owner to sign. No debug-key APK is a production-signed release. The current downloader uses Android DownloadManager with persisted job state; this run covers live completion and cold startup after installation, not an interrupted download across process death. The earlier dated results below are historical.


## Historical validation — 2026-09-23

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

### Compressed dictionary installation — 2026-09-23

- Raw and XZ use the same logical record offsets. Files remain compressed in app storage; no full-language decode in memory or expanded disk copy.
- JVM tests cover reads crossing block and concatenated-stream boundaries, backwards seeks, truncated XZ and invalid raw ranges.
- Real-device test compressed the 30-entry binary fixture into 64 KiB independent blocks, imported/indexed it, compared the complete decoded elephant entry with its raw counterpart, and asserted the installed file retained the compressed byte size. Passed.
- `testDebugUnitTest`, debug/test APK builds, and optimized build passed. This is conformance evidence, not a whole-corpus performance benchmark.
