package app.smallthingz.dict

import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Entry rendering of typed synthetic Sections; no source issuance or installed-font assumption. */
@RunWith(AndroidJUnit4::class)
class SectionHeadingDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val density = Density(1.25f, 1.2f)
    private var rootWindow = androidx.compose.ui.geometry.Rect.Zero
    private val settings = AppSettings(allowImages = false, allowAudio = false,
        collapseOtherSections = false, collapseDetails = false)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private fun style(clear: FigureClear = FigureClear.None, direction: BidiResolvedDirection = BidiResolvedDirection.Ltr,
        family: ContainerFontFamily = ContainerFontFamily.SansSerif) = SectionHeadingStyle(
        ContainerStyle(margins = edges(3.5f, 6.75f, 5.25f, 4.25f), padding = edges(1.5f, 1.5f, 1.5f, 1.5f),
            border = ContainerBorder.Solid(px(2.25f), ContainerColor.Rgb("#0000cc")),
            background = ContainerColor.Rgb("#00aa00"), ownerFontScale = .75f,
            lineHeight = ContainerLineHeight.Length(px(16f)), clear = clear, fontFamily = family),
        InlineFontSnapshot(fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody,
            italic = true, language = "th"), direction)
    private fun paragraph(label: String) = Block("paragraph", 0, listOf(Span("link", label, label)),
        style = BlockStyle(margins = edges()))
    private fun section(style: SectionHeadingStyle?, level: Int = 3, body: List<Block> = emptyList(),
        title: String = "Owner link", boldLink: Boolean = false): Section {
        val spans = if (title == "Owner link") listOf(Span("text", "Owner "),
            Span("link", "link", "heading-action", bold = boldLink)) else listOf(Span("text", title))
        val heading = Block("heading", 0, spans, level = level, anchor = "owner", anchorFallback = "owner-fallback")
        return Section(level, title, listOf(heading) + body, "owner", "owner-fallback", style)
    }
    private fun entry(sections: List<Section>, policy: BodyAdjoiningPolicy? = BodyAdjoiningPolicy.Ordinary) =
        Entry("Section box control", emptyList(), "language", "Japanese", "ja", sections, emptyList(), bodyAdjoining = policy)

    @Composable private fun Scene(value: Entry, actions: MutableList<EntryLink>, reading: EntryReadingState,
        failures: MutableList<String>, probe: NativeNamedFontProbe? = null,
        request: EntryAnchorRequest? = null, consumed: (EntryAnchorRequest) -> Unit = {}) {
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
            MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp, letterSpacing = 0.sp),
            titleMedium = MaterialTheme.typography.titleMedium.copy(fontSize = 72.sp, lineHeight = 80.sp))) {
            CompositionLocalProvider(LocalDensity provides density, LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalNativeFloatContextFailureObserver provides { failures += it }) {
                @Composable fun body() {
                    Box(Modifier.size(320.dp, 560.dp).background(Color.White).testTag("section-heading-root")
                        .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                        EntryView(value, false, {}, onLink = { actions += it }, settings = settings,
                            readingState = reading, anchorRequest = request, onAnchorConsumed = consumed)
                    }
                }
                if (probe == null) body() else CompositionLocalProvider(LocalNativeNamedFontProbe provides probe) { body() }
            }
        }
    }
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun collect(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
            }
            collect(activity.window.decorView)
        }
        return result
    }
    private fun owner(label: String = "Owner link"): NativeFloatTextView = views().single { view ->
        view.currentMeasuredGeometry?.nodes?.any { it.kind == FloatInteractionKind.HEADING && it.label == label } == true
    }
    private fun source(view: NativeFloatTextView): FloatTextGeometry =
        (checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry).content
    private fun heading(view: NativeFloatTextView, label: String = "Owner link") =
        source(view).nodes.single { it.kind == FloatInteractionKind.HEADING && it.label == label }
    private fun titleBounds(view: NativeFloatTextView): RectF = RectF(heading(view).bounds.single())
    private fun tap(view: NativeFloatTextView, label: String) {
        compose.runOnIdle {
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label == label }
            val bounds = node.bounds.single()
            assertEquals(node.id, geometry.interactionNodeAt(bounds.centerX(), bounds.centerY())?.id)
            val now = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, bounds.centerX(), bounds.centerY(), 0)
            val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP, bounds.centerX(), bounds.centerY(), 0)
            try { view.dispatchTouchEvent(down); view.dispatchTouchEvent(up) }
            finally { down.recycle(); up.recycle() }
        }
        compose.waitForIdle()
    }
    private fun tapRetained(label: String) {
        val candidates = views().filter { it.currentMeasuredGeometry?.nodes?.any { node ->
            node.kind == FloatInteractionKind.LINK && node.label == label
        } == true }
        if (candidates.isNotEmpty()) tap(candidates.single(), label) else {
            val text = compose.onNodeWithText(label, substring = true, useUnmergedTree = true)
            val layouts = mutableListOf<TextLayoutResult>()
            text.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            val offset = layout.layoutInput.text.text.indexOf(label).also { check(it >= 0) }
            text.performTouchInput { click(layout.getBoundingBox(offset).center) }
            compose.waitForIdle()
        }
    }
    private fun menu(label: String) {
        compose.onNodeWithContentDescription("Sections").performClick()
        compose.onNode(hasText(label) and hasAnyAncestor(isPopup())).performClick()
        compose.waitForIdle()
    }
    private fun keyboardMenu(label: String) {
        compose.onNodeWithContentDescription("Sections").performClick()
        val item = compose.onNode(hasText(label) and hasAnyAncestor(isPopup()))
        item.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
        item.assertIsFocused().performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
        compose.waitForIdle()
    }
    private fun paintedHeadingBox(): RectF {
        val pixels = compose.onNodeWithTag("section-heading-root").captureToImage().toPixelMap()
        var left = pixels.width; var right = -1; var top = pixels.height; var bottom = -1
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val color = pixels[x, y]
            if (color.blue > .7f && color.red < .05f && color.green < .05f) {
                left = minOf(left, x); right = maxOf(right, x); top = minOf(top, y); bottom = maxOf(bottom, y)
            }
        }
        check(right >= left && bottom >= top) { "Authored blue heading border was not painted" }
        return RectF(left.toFloat(), top.toFloat(), right + 1f, bottom + 1f)
    }
    private fun assertPaint(view: NativeFloatTextView, borderTop: Float) {
        var x = 0f; var y = 0f
        compose.runOnIdle {
            val geometry = checkNotNull(view.currentMeasuredGeometry) as NativeSurfaceGeometry
            val window = IntArray(2).also(view::getLocationInWindow)
            x = window[0] - rootWindow.left - geometry.surface.left
            y = window[1] - rootWindow.top - geometry.surface.top
        }
        val pixels = compose.onNodeWithTag("section-heading-root").captureToImage().toPixelMap()
        fun pixel(left: Float, top: Float) = pixels[(x + left).toInt(), (y + top).toInt()]
        val border = pixel((4.25f + 1.125f) * density.density, borderTop + 6f * density.density)
        assertTrue(border.blue > .7f && border.red < .1f && border.green < .1f)
        val padding = pixel(180f * density.density, borderTop + (2.25f + .75f) * density.density)
        assertTrue(padding.green > .6f && padding.red < .1f && padding.blue < .1f)
    }
    private fun control(name: String, body: () -> Unit) {
        try { body() }
        catch (failure: Throwable) {
            runCatching {
                val root = compose.onNodeWithTag("section-heading-root")
                val report = renderedLayoutFailureEvidence(name, null, null, root, name, root.captureToImage().asAndroidBitmap())
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun authoredFirstAndLastHeadingUsesOneSourceBoxFontAndNonpaintingAccessibilityControls() =
        control("section-heading-source-box.png") {
            val mode = mutableStateOf(0)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val reading = EntryReadingState()
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                Scene(entry(listOf(section(style(), level = if (mode.value == 2) 6 else 3)),
                    if (mode.value == 1) null else BodyAdjoiningPolicy.Ordinary), actions, reading, failures)
            } }
            compose.waitForIdle()
            val first = owner()
            val firstBounds = titleBounds(first)
            val firstHeight = source(first).extents.usedHeight
            compose.runOnIdle {
                assertTrue(failures.isEmpty())
                assertEquals("Owner link", first.logicalText.toString())
                assertEquals(1, source(first).nodes.count { it.kind == FloatInteractionKind.HEADING })
                assertEquals(1, source(first).nodes.count { it.kind == FloatInteractionKind.LINK })
                assertEquals(0, source(first).nodes.count { it.kind == FloatInteractionKind.CONTROL })
                assertTrue("No 48dp UI minimum or 72sp heading preset", firstHeight < 48f * density.density)
                first.setSelection(0, first.logicalText.length)
                assertEquals("Owner link", first.selectedTextForCopy())
                val node = heading(first)
                val info = checkNotNull(first.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                assertTrue(AccessibilityNodeInfoCompat.wrap(info).isHeading)
                assertEquals("Owner link", info.text.toString())
                assertTrue(info.actionList.any { it.label?.toString() == "Collapse Owner link" })
                assertTrue(info.actionList.none { it.label?.toString() == "heading-action" })
            }
            assertPaint(first, 0f)
            tap(first, "link")
            compose.runOnIdle { mode.value = 1 }
            compose.waitForIdle()
            val outside = owner()
            compose.runOnIdle {
                assertEquals(firstHeight + (3.5f + 5.25f) * density.density, source(outside).extents.usedHeight, .02f)
                assertEquals(firstBounds.top + 3.5f * density.density, titleBounds(outside).top, .02f)
                assertEquals(firstBounds.width(), titleBounds(outside).width(), .02f)
            }
            assertPaint(outside, 3.5f * density.density)
            compose.runOnIdle { mode.value = 2 }
            compose.waitForIdle()
            val otherLevel = owner()
            assertEquals(firstHeight, source(otherLevel).extents.usedHeight, .02f)
            assertEquals(firstBounds, titleBounds(otherLevel))
            assertPaint(otherLevel, 0f)
            assertEquals(listOf("heading-action"), actions.map { it.target })
        }

    @Test fun realPrefixTableAndClearReflowOneHeadingInsideTheActualFloatFreeInterval() =
        control("section-heading-float-clear.png") {
            val clear = mutableStateOf(false)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val reading = EntryReadingState()
            val prefix = Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(listOf(Span("link", "float", "float")), false, 1, 1,
                    style = CellStyle(padding = edges())))), style = TableStyle(floatSide = TableFloatSide.Left,
                    width = StyleWidth(StyleWidthUnit.Px, 80f), margins = edges())))
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                Scene(entry(listOf(Section(0, "", listOf(prefix)), section(style(
                    clear = if (clear.value) FigureClear.Both else FigureClear.None,
                    direction = BidiResolvedDirection.Rtl)))), actions, reading, failures)
            } }
            compose.waitForIdle()
            var prefixBounds = RectF()
            var besideBox = RectF()
            for (cleared in listOf(false, true)) {
                compose.runOnIdle { clear.value = cleared }
                compose.waitForIdle()
                val current = owner()
                val geometry = source(current)
                val root = compose.onNodeWithTag("section-heading-root").fetchSemanticsNode().boundsInRoot
                val grid = compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true)
                    .fetchSemanticsNode().boundsInRoot
                val floating = RectF(grid.left - root.left, grid.top - root.top, grid.right - root.left, grid.bottom - root.top)
                val painted = paintedHeadingBox()
                compose.runOnIdle {
                    assertTrue(failures.isEmpty())
                    assertEquals("\ufffc\nOwner link", current.logicalText.toString())
                    assertEquals(1, geometry.nodes.count { it.kind == FloatInteractionKind.HEADING })
                    assertEquals(0, geometry.nodes.count { it.kind == FloatInteractionKind.CONTROL })
                    assertFalse(RectF.intersects(painted, floating))
                    assertTrue(titleBounds(current).left > geometry.width / 2f)
                    if (!cleared) {
                        assertEquals(floating.top, painted.top, 2f)
                        assertTrue(painted.left >= floating.right - 1f)
                        assertTrue(painted.bottom <= floating.bottom + 1f)
                        prefixBounds = RectF(floating)
                        besideBox = RectF(painted)
                    } else {
                        assertEquals(prefixBounds, floating)
                        assertTrue(painted.top >= floating.bottom - 1f)
                        assertTrue(painted.left < besideBox.left)
                        assertTrue(painted.width() > besideBox.width())
                    }
                    current.setSelection(0, current.logicalText.length)
                    assertEquals("\ufffc\nOwner link", current.selectedTextForCopy())
                }
                tap(current, "link"); tapRetained("float")
            }
            assertEquals(listOf("heading-action", "float", "heading-action", "float"), actions.map { it.target })
        }

    @Test fun namedFamilyRefusalsRetainCompiledTitleAndActionsThenRecoverWithExternalFoldAndNavigation() =
        control("section-heading-family-recovery.png") {
            val mode = mutableStateOf(0)
            val request = mutableStateOf<EntryAnchorRequest?>(null)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val queries = mutableListOf<Triple<String, FontWeight, FontStyle>>()
            val reading = EntryReadingState()
            val names = listOf("Linux Libertine", "Georgia", "Times", "Source Serif 4")
            fun selected() = entry(listOf(section(style(family = ContainerFontFamily.Stack(
                if (mode.value == 3) emptyList() else names, GenericFontFamily.Serif)),
                body = listOf(paragraph("body-action")), boldLink = true)))
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val state = mode.value
                val probe = NativeNamedFontProbe { _, name, weight, italic ->
                    queries += Triple(name, weight, italic)
                    when (state) {
                        0 -> Typeface.SERIF
                        1 -> throw IllegalStateException("Synthetic optional-font loader failure")
                        else -> null
                    }
                }
                Scene(selected(), actions, reading, failures, probe, request.value,
                    { if (request.value === it) request.value = null })
            } }
            compose.waitForIdle()
            for (state in listOf(0, 1)) {
                compose.runOnIdle { mode.value = state }
                compose.waitForIdle()
                compose.onAllNodesWithText("Unable to display this layout.").onFirst().assertIsDisplayed()
                assertTrue(failures.any { it == if (state == 0) NativeNamedFamilyUnavailable else NativeNamedFamilyProbeUnavailable })
                // The retained title still contains one original source link and no reader chevron/buttons.
                val composeTitles = compose.onAllNodesWithText("Owner link", useUnmergedTree = true).fetchSemanticsNodes().size
                val nativeTitles = views().count { it.currentMeasuredGeometry?.text?.toString() == "Owner link" }
                assertEquals(1, composeTitles + nativeTitles)
                compose.onAllNodesWithText("Collapse Owner link").assertCountEquals(0)
                tapRetained("link"); tapRetained("body-action")
            }
            compose.runOnIdle { queries.clear(); mode.value = 2 }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            var current = owner()
            assertEquals("Owner link\nbody-action", current.logicalText.toString())
            assertTrue(queries.map { it.first }.containsAll(names))
            assertTrue(queries.any { it.second == FontWeight.Normal && it.third == FontStyle.Italic })
            assertTrue(queries.any { it.second == FontWeight.Bold && it.third == FontStyle.Italic })
            keyboardMenu("Collapse Owner link")
            current = owner()
            assertEquals("Owner link", current.logicalText.toString())
            compose.onAllNodesWithText("body-action", useUnmergedTree = true).assertCountEquals(0)
            menu("Owner link")
            current = owner()
            assertEquals("Owner link\nbody-action", current.logicalText.toString())
            menu("Collapse Owner link")
            compose.runOnIdle { request.value = EntryAnchorRequest(selected().key, "#owner-fallback") }
            compose.waitForIdle()
            assertNull(request.value)
            current = owner()
            assertEquals("Owner link\nbody-action", current.logicalText.toString())
            val recoveredText = current.logicalText.toString()
            val recoveredTitle = titleBounds(current)
            compose.runOnIdle {
                val node = heading(current)
                val info = checkNotNull(current.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                val fold = info.actionList.single { it.label?.toString() == "Collapse Owner link" }
                assertTrue(current.accessibilityNodeProvider.performAction(node.id, fold.id, null))
            }
            compose.waitForIdle()
            assertEquals("Owner link", owner().logicalText.toString())
            menu("Expand Owner link")
            tap(owner(), "link"); tap(owner(), "body-action")
            compose.runOnIdle { queries.clear(); mode.value = 3 }
            compose.waitForIdle()
            current = owner()
            assertEquals(recoveredText, current.logicalText.toString())
            assertEquals(recoveredTitle, titleBounds(current))
            assertTrue(queries.isEmpty())
            compose.runOnIdle {
                current.setSelection(0, current.logicalText.length)
                assertEquals("Owner link\nbody-action", current.selectedTextForCopy())
            }
            assertEquals(List(3) { listOf("heading-action", "body-action") }.flatten(), actions.map { it.target })
        }

    @Test fun compiledTitleWhitespaceAndNullHeadingKeepTheirSeparateExistingRoutes() =
        control("section-heading-compiled-whitespace.png") {
            val mode = mutableStateOf(0)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val reading = EntryReadingState()
            val titles = listOf(" \u00a0", " ")
            fun selected(): Entry {
                if (mode.value < 2) return entry(listOf(section(style(), title = titles[mode.value])))
                val companion = Block("heading", 0, listOf(Span("text", "Legacy", bold = true)), level = 3)
                return entry(listOf(Section(3, "Legacy", listOf(companion, paragraph("legacy-body")))), policy = null)
            }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                Scene(selected(), actions, reading, failures)
            } }
            compose.waitForIdle()
            for (state in titles.indices) {
                compose.runOnIdle { mode.value = state }
                compose.waitForIdle()
                val title = titles[state]
                val current = owner(title)
                compose.runOnIdle {
                    assertTrue(failures.isEmpty())
                    assertEquals(title, current.logicalText.toString())
                    assertEquals(title, selected().sections.single().blocks.first().spans.single().text)
                    assertEquals(1, source(current).nodes.count { it.kind == FloatInteractionKind.HEADING })
                    assertEquals(0, source(current).nodes.count { it.kind == FloatInteractionKind.CONTROL || it.kind == FloatInteractionKind.LINK })
                    assertEquals(title.length, source(current).characterRects(0, title.length).size)
                    current.setSelection(0, title.length)
                    assertEquals(title, current.selectedTextForCopy())
                    val info = checkNotNull(current.accessibilityNodeProvider.createAccessibilityNodeInfo(heading(current, title).id))
                    assertEquals(title, info.text.toString())
                    assertTrue(AccessibilityNodeInfoCompat.wrap(info).isHeading)
                }
                assertPaint(current, 0f)
            }
            compose.runOnIdle { mode.value = 2 }
            compose.waitForIdle()
            compose.onNodeWithContentDescription("Collapse Legacy").assertIsDisplayed()
            compose.onNodeWithText("legacy-body", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithContentDescription("Collapse Legacy").performClick()
            compose.onAllNodesWithText("legacy-body", useUnmergedTree = true).assertCountEquals(0)
            compose.onNodeWithContentDescription("Expand Legacy").performClick()
            tapRetained("legacy-body")
            assertEquals(listOf("legacy-body"), actions.map { it.target })
        }

    @Test fun sourceAnchorOutsetsUseOwnerFontContentAfterLayoutAndPreserveVisitStateOnRecovery() =
        control("section-heading-source-reveal.png") {
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val reading = EntryReadingState()
            val request = mutableStateOf<EntryAnchorRequest?>(null)
            val consumed = mutableListOf<EntryAnchorRequest>()
            val mounted = mutableStateOf(true)
            val unavailable = mutableStateOf(false)
            val hugeOutset = mutableStateOf(false)
            val trailing = mutableStateOf(true)
            val prefix = Section(0, "", List(50) { paragraph("before-$it") })
            val tail = List(50) { paragraph("after-$it") }
            fun selected(): Entry {
                val family = if (unavailable.value) ContainerFontFamily.Stack(listOf("owned-unavailable"),
                    GenericFontFamily.SansSerif) else ContainerFontFamily.SansSerif
                val base = style(family = family)
                val authored = base.copy(box = base.box.copy(lineHeight = ContainerLineHeight.Length(px(80f))),
                    titleWrap = TextWrap.Normal, anchorReveal = HeadingAnchorReveal(px(if (hugeOutset.value) 1_000_000f else 75f), px(0f)))
                return entry(listOf(prefix, section(authored, body = if (trailing.value) tail else emptyList())))
            }
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                if (mounted.value) Scene(selected(), actions, reading, failures,
                    NativeNamedFontProbe { _, _, _, _ -> Typeface.DEFAULT }, request.value) {
                    consumed += it
                    if (request.value === it) request.value = null
                } else Box(Modifier.size(320.dp, 560.dp))
            } }
            compose.waitForIdle()
            fun navigate(target: String): EntryAnchorRequest {
                val next = EntryAnchorRequest(selected().key, target)
                compose.runOnIdle { request.value = next }
                compose.waitUntil(10_000) { consumed.any { it === next } }
                compose.waitForIdle()
                assertEquals(1, consumed.count { it === next })
                return next
            }
            fun contentTopFromNativeOwner(): Float {
                var result = Float.NaN
                val view = owner()
                compose.runOnIdle {
                    val physical = view.currentMeasuredGeometry as NativeSurfaceGeometry
                    val context = physical.content as NativeFloatContextGeometry
                    val leaf = context.inputLeaves().single { it.geometry.nodes.any { node ->
                        node.kind == FloatInteractionKind.HEADING && node.label == "Owner link"
                    } }
                    val native = leaf.geometry as NativeFloatGeometry
                    val source = native.text as android.text.Spanned
                    val ownerMetrics = source.getSpans(0, source.length, NativeRunLineMetrics::class.java).single {
                        it.strut && source.getSpanStart(it) == 0
                    }.primary
                    val wrap = source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).single()
                    assertTrue(wrap.inheritedOwner); assertEquals(TextWrap.Normal, wrap.wrap)
                    assertEquals(0, source.getSpanStart(wrap)); assertEquals(source.length, source.getSpanEnd(wrap))
                    val fontTop = checkNotNull(checkNotNull(native.textBaselines).first) + ownerMetrics.ascent + ownerMetrics.baselineShift
                    assertTrue("The source target is not the authored 80px line-height top",
                        kotlin.math.abs(fontTop - native.firstLineBand().top) > 10f)
                    val location = IntArray(2).also(view::getLocationInWindow)
                    result = location[1] - physical.surface.top + leaf.y + fontTop
                }
                return result
            }
            fun assertSourceTop(expected: Float) {
                val viewport = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode().positionInWindow.y
                assertEquals(expected, contentTopFromNativeOwner() - viewport, 1.25f)
                compose.onNodeWithText(SourceHeadingRevealUnavailable).assertDoesNotExist()
            }
            navigate("#owner")
            assertSourceTop(75f * density.density)
            val originalText = owner().logicalText.toString()
            assertTrue(originalText.contains("before-0") && originalText.contains("after-49"))
            val originalRanges = source(owner()).nodes.filter { it.kind == FloatInteractionKind.LINK }
                .map { Triple(it.label, it.start, it.end) }
            navigate("#owner-fallback")
            assertSourceTop(0f)
            compose.runOnIdle {
                val view = owner()
                assertEquals(originalText, view.logicalText.toString())
                assertEquals(originalRanges, source(view).nodes.filter { it.kind == FloatInteractionKind.LINK }
                    .map { Triple(it.label, it.start, it.end) })
                val target = heading(view)
                view.setSelection(target.start, target.end)
                assertEquals("Owner link", view.selectedTextForCopy())
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
                assertTrue(AccessibilityNodeInfoCompat.wrap(info).isHeading)
                assertEquals("Owner link", info.text.toString())
                assertTrue(info.isVisibleToUser)
            }
            tap(owner(), "link")
            assertEquals(listOf("heading-action"), actions.map { it.target })

            // A new composition for the same visit restores the saved list state without another fragment request.
            val savedIndex = reading.scroll.firstVisibleItemIndex
            val savedOffset = reading.scroll.firstVisibleItemScrollOffset
            val beforeRestore = consumed.size
            compose.runOnIdle { mounted.value = false }
            compose.waitForIdle()
            compose.runOnIdle { mounted.value = true }
            compose.waitForIdle()
            assertEquals(savedIndex, reading.scroll.firstVisibleItemIndex)
            assertEquals(savedOffset, reading.scroll.firstVisibleItemScrollOffset)
            assertEquals(beforeRestore, consumed.size)
            assertSourceTop(0f)

            // The exact same body survives a native font refusal; no substitute caret is accepted as a source target.
            compose.runOnIdle { unavailable.value = true }
            compose.waitForIdle()
            navigate("#owner")
            compose.onNodeWithText(SourceHeadingRevealUnavailable).assertIsDisplayed()
            assertTrue(failures.any { it == NativeNamedFamilyUnavailable })
            val retainedNative = views().filter { it.currentMeasuredGeometry?.text?.toString() == "Owner link" }
            val retainedCompose = compose.onAllNodesWithText("Owner link", useUnmergedTree = true).fetchSemanticsNodes()
            assertEquals(1, retainedNative.size + retainedCompose.size)
            if (retainedNative.isNotEmpty()) compose.runOnIdle {
                val link = checkNotNull(retainedNative.single().currentMeasuredGeometry).nodes.single {
                    it.kind == FloatInteractionKind.LINK && it.label == "link"
                }
                assertEquals(6, link.start); assertEquals(10, link.end); assertNotNull(link.onClick)
            } else {
                val layouts = mutableListOf<TextLayoutResult>()
                compose.onNodeWithText("Owner link", useUnmergedTree = true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val retained = layouts.single().layoutInput.text
                val link = retained.getLinkAnnotations(0, retained.length).single()
                assertEquals("Owner link", retained.text)
                assertEquals(6, link.start); assertEquals(10, link.end)
                assertEquals("heading-action", (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
            }
            compose.runOnIdle { unavailable.value = false; failures.clear() }
            compose.waitForIdle()
            navigate("#owner")
            assertSourceTop(75f * density.density)
            assertTrue(failures.isEmpty())
            assertEquals(originalText, owner().logicalText.toString())
            tap(owner(), "link")
            assertEquals(listOf("heading-action", "heading-action"), actions.map { it.target })

            compose.runOnIdle { hugeOutset.value = true }
            compose.waitForIdle()
            navigate("#owner")
            compose.runOnIdle { assertFalse(reading.scroll.canScrollBackward) }
            compose.onNodeWithText(SourceHeadingRevealUnavailable).assertDoesNotExist()
            compose.runOnIdle { hugeOutset.value = false; trailing.value = false }
            compose.waitForIdle()
            navigate("#owner-fallback")
            compose.runOnIdle { assertFalse(reading.scroll.canScrollForward) }
            val viewport = compose.onNodeWithTag("entry-scroll").fetchSemanticsNode().positionInWindow.y
            assertTrue("The normal end clamp limits top alignment", contentTopFromNativeOwner() > viewport + 1f)
            compose.onNodeWithText(SourceHeadingRevealUnavailable).assertDoesNotExist()
        }


    @Test fun actualHeadingTitleWrapOwnsTheLongTitleWhileNullKeepsItsHistoricalLayout() =
        control("section-heading-title-wrap.png") {
            val wrap = mutableStateOf<TextWrap?>(null)
            val title = "W".repeat(72)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val reading = EntryReadingState()
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                Scene(entry(listOf(section(style().copy(titleWrap = wrap.value), title = title))),
                    actions, reading, failures)
            } }
            compose.waitForIdle()
            var legacyBaselines: NativeTextBaselines? = null
            var legacyBounds = emptyList<RectF>()
            var headingIdentity: Triple<Int, Int, Int>? = null
            for ((index, policy) in listOf(null, TextWrap.Normal, TextWrap.BreakWord, null).withIndex()) {
                compose.runOnIdle { wrap.value = policy }
                compose.waitForIdle()
                val view = owner(title)
                compose.runOnIdle {
                    assertTrue(failures.isEmpty())
                    val context = source(view) as NativeFloatContextGeometry
                    val leaf = context.inputLeaves().single { it.geometry.nodes.any { node ->
                        node.kind == FloatInteractionKind.HEADING && node.label == title
                    } }
                    val native = leaf.geometry as NativeFloatGeometry
                    val source = native.text as android.text.Spanned
                    val markers = source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java)
                    val node = context.nodes.single { it.kind == FloatInteractionKind.HEADING }
                    val identity = Triple(node.id, node.start, node.end)
                    if (headingIdentity == null) headingIdentity = identity else assertEquals(headingIdentity, identity)
                    assertEquals(title, source.toString()); assertEquals(title, view.logicalText.toString())
                    assertEquals(0, node.start); assertEquals(title.length, node.end)
                    assertEquals(title, node.label.toString())
                    view.setSelection(node.start, node.end)
                    assertEquals(title, view.selectedTextForCopy())
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                    assertTrue(AccessibilityNodeInfoCompat.wrap(info).isHeading)
                    assertEquals(title, info.text.toString())
                    val baselines = checkNotNull(native.textBaselines)
                    val first = checkNotNull(baselines.first); val last = checkNotNull(baselines.last)
                    when (policy) {
                        TextWrap.NoWrap -> error("NoWrap is outside the heading policy domain")
                        TextWrap.Normal -> {
                            assertEquals(first, last, 0f)
                            assertTrue("Normal retains one overflowing unbreakable title",
                                native.rectsForRange(0, source.length).maxOf { it.right } > native.width)
                        }
                        TextWrap.BreakWord -> {
                            assertTrue(last > first)
                            assertTrue(native.rectsForRange(0, source.length).all { it.width() <= native.width + 1f })
                        }
                        null -> {
                            assertTrue(markers.isEmpty())
                            if (index == 0) {
                                legacyBaselines = baselines
                                legacyBounds = native.rectsForRange(0, source.length).map(::RectF)
                            } else {
                                assertEquals(legacyBaselines, baselines)
                                assertEquals(legacyBounds, native.rectsForRange(0, source.length))
                            }
                        }
                    }
                    if (policy != null) {
                        val marker = markers.single()
                        assertTrue(marker.inheritedOwner); assertEquals(policy, marker.wrap)
                        assertEquals(0, source.getSpanStart(marker)); assertEquals(source.length, source.getSpanEnd(marker))
                    }
                }
            }
            assertTrue(actions.isEmpty())
            compose.onNodeWithText(SourceHeadingRevealUnavailable).assertDoesNotExist()
        }

}
