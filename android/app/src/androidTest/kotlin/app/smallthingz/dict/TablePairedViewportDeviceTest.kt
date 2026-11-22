package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.roundToInt

/** Typed synthetic paired owners, not a captured Mai table or a producer/rendering qualification. */
class TablePairedViewportDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private val sourceColors = listOf("#3366cc", "#228844", "#cc5500", "#aa22cc", "#6a60b0", "#008080", "#993333", "#667700")
    private fun action(text: String, target: String, fragment: String, trail: String = ""): Span {
        val states = sourceColors.mapIndexed { index, color -> FigureLinkState(color, index % 2 != 0) }
        val policy = LinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], states[6], states[7],
            underlineOnFocus = true, focusOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"),
                px(2f), SignedContainerMargin(StyleLengthUnit.Px, -2f)))
        return Span("link", text, target, targetFragment = fragment, trail = trail,
            foreground = policy.normal.foreground, underline = policy.normal.underline, linkPaint = policy)
    }
    private data class Fixture(val table: Table, val rowspan: Span, val footer: Span)
    private fun fixture(focus: TableScrollFocusPaint = TableScrollFocusPaint(TableScrollFocusMode.UaAuto),
        short: Boolean = false, gridDirection: TableContainingDirection = TableContainingDirection.Ltr): Fixture {
        val rowspan = action(if (short) "A" else "A A A A A A A A A A", "DE-rowspan", "source-rowspan")
        val footer = action(if (short) "C" else "C C C C C C C C C C C C C C C", "DE-footer", "source-footer", "!")
        fun cell(spans: List<Span>, minimum: Float, colspan: Int = 1, rowSpan: Int = 1, header: Boolean = false) =
            Cell(spans, header, colspan, rowSpan, style = CellStyle(border = StyleBorder.None,
                padding = edges(), minWidth = px(minimum), verticalAlign = CellVerticalAlign.Top,
                lineHeight = CellLineHeight(CellLineHeightValue.Normal)))
        // Five real cells, including an authored empty cell; uncovered logical slots are not TD owners.
        val rows = listOf(
            listOf(cell(listOf(rowspan), 30f, rowSpan = 2), cell(listOf(Span("text", "B B")), 45f, colspan = 2),
                cell(emptyList(), 0f)),
            listOf(cell(listOf(Span("text", "r")), 45f, colspan = 2)),
            listOf(cell(listOf(footer), 120f, colspan = 7, header = true)))
        val fixed = edges(right = 6.5f, left = 4.25f)
        val table = Table(emptyList(), rows, style = TableStyle(border = StyleBorder.None,
            collapse = TableCollapse.Collapse, margins = fixed, floatSide = TableFloatSide.Right),
            floatViewport = TableFloatViewport(639, TableContainingDirection.Ltr, gridDirection, "de"),
            blockViewport = TableBlockViewport(639,
                TableStyle(margins = fixed, padding = edges(right = 2.25f, left = 3.5f),
                    border = StyleBorder.Solid(px(1.25f), "#003300"), background = "#eeeeee", clear = FigureClear.None),
                ContainerBoxSizing.BorderBox, StyleWidth(StyleWidthUnit.Percent, 75f),
                TableStyle(collapse = TableCollapse.Collapse), gridDirection, "de", focusPaint = focus))
        return Fixture(table, rowspan, footer)
    }
    private fun tableBlock(table: Table) = Block("table", 0, emptyList(), table = table)
    private val blocker = tableBlock(Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "F")), false, 1, 1,
        style = CellStyle(border = StyleBorder.None, padding = edges(bottom = 130f), minWidth = px(60f))))),
        style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse,
            width = StyleWidth(StyleWidthUnit.Px, 60f), floatSide = TableFloatSide.Left, margins = edges())))

    @Composable private fun Scene(fixture: Fixture, viewport: Double, width: Int, visits: MissingLinkVisits,
        owner: Any, actions: MutableList<EntryLink>, failures: MutableList<String>, uiDirection: LayoutDirection = LayoutDirection.Ltr) {
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides uiDirection,
            LocalTableDocumentViewportCssWidth provides viewport, LocalEntryEdition provides "de",
            LocalMissingLinkVisits provides visits, LocalMissingLinkDocument provides "Paired constructor",
            LocalMissingLinkOwner provides owner, LocalNativeFloatContextFailureObserver provides { failures += it }) {
            DictTheme("light") {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                    fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                    Box(Modifier.width(360.dp).background(Color.White).testTag("paired-root")) {
                        Box(Modifier.padding(start = 60.dp)) {
                            Box(Modifier.width(width.dp).testTag("paired-containing")) {
                                NativeFloatBlockContext(listOf(blocker, tableBlock(fixture.table)), { actions += it },
                                    "paired-constructor", Modifier, inCell = false, gridPath = "root", gapDp = 0f,
                                    trailingGap = false)
                            }
                        }
                    }
                }
            }
        }
    }
    private fun withScene(name: String, content: @Composable () -> Unit, assertions: () -> Unit) {
        var primaryFailure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent(content = content) }
            compose.waitForIdle()
            assertions()
        } catch (failure: Throwable) {
            primaryFailure = failure
            runCatching {
                val root = compose.onNodeWithTag("paired-root")
                val report = renderedLayoutFailureEvidence(name, null, null, root, name, root.captureToImage().asAndroidBitmap())
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanupFailure: Throwable) {
                val original = primaryFailure
                if (original == null) throw cleanupFailure
                if (cleanupFailure !== original) original.addSuppressed(cleanupFailure)
            }
        }
    }
    private val horizontal = SemanticsMatcher("actual local horizontal scroll range") {
        it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
    }
    private fun containing() = compose.onNodeWithTag("paired-containing", useUnmergedTree = true)
    private fun viewport() = sourceTable()
    private fun content() = compose.onNodeWithTag("compiled-table-block-content", useUnmergedTree = true)
    private fun sourceTable() = compose.onNodeWithTag("compiled-table-scroll-focus", useUnmergedTree = true)
    private fun grid() = compose.onNodeWithTag("compiled-table-grid-root/block-1", useUnmergedTree = true)
    private fun gridCell(index: Int) = compose.onNodeWithTag("compiled-table-cell-root/block-1-$index", useUnmergedTree = true)
    private fun box(node: SemanticsNodeInteraction): RectF {
        val source = node.fetchSemanticsNode()
        val position = source.positionInWindow
        return RectF(position.x, position.y, position.x + source.size.width, position.y + source.size.height)
    }
    private fun axis() = sourceTable().fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
    private fun scroll(amount: Float) {
        sourceTable().performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(amount, 0f)) }
        compose.waitForIdle()
    }
    private fun views(): List<View> {
        val result = mutableListOf<View>()
        fun collect(view: View) {
            if (view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { collect(view.getChildAt(it)) }
        }
        collect(compose.activity.window.decorView)
        return result
    }
    private fun actionViews(): List<NativeFloatTextView> = views().filterIsInstance<NativeFloatTextView>().filter { view ->
        view.currentMeasuredGeometry?.nodes?.any { it.missingLinkPaint?.ordinaryPolicy != null } == true
    }
    private fun sourceFocusView() = views().filterIsInstance<NativeTableScrollFocusView>().single()
    private fun sourceAccessibility(id: Int): Pair<AccessibilityNodeProvider, AccessibilityNodeInfo> {
        val candidates = mutableListOf<Pair<AccessibilityNodeProvider, AccessibilityNodeInfo>>()
        for (view in views()) {
            val provider = view.accessibilityNodeProvider ?: continue
            val info = provider.createAccessibilityNodeInfo(id) ?: continue
            if (info.collectionInfo?.rowCount == 3 && info.collectionInfo?.columnCount == 7)
                candidates += provider to info
            else info.recycle()
        }
        assertEquals("One actual source TABLE accessibility owner", 1, candidates.size)
        return candidates.single()
    }
    private fun actionView(label: String) = actionViews().single { view ->
        view.currentMeasuredGeometry!!.nodes.any { it.missingLinkPaint?.ordinaryPolicy != null && it.label.toString() == label }
    }
    private fun actionNode(view: NativeFloatTextView, label: String) = view.currentMeasuredGeometry!!.nodes.single {
        it.missingLinkPaint?.ordinaryPolicy != null && it.label.toString() == label
    }
    private fun label(span: Span) = span.text + span.trail
    private fun ready(failures: List<String>) {
        assertTrue(failures.toString(), failures.isEmpty())
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
    }
    private fun assertTopology(fixture: Fixture) {
        assertEquals(listOf(3, 1, 1), fixture.table.rows.map { it.size })
        assertSame(fixture.rowspan, fixture.table.rows[0][0].spans.single())
        assertSame(fixture.footer, fixture.table.rows[2][0].spans.single())
        val collection = sourceTable().fetchSemanticsNode().config[SemanticsProperties.CollectionInfo]
        assertEquals(3, collection.rowCount); assertEquals(7, collection.columnCount)
        val cells = SemanticsMatcher("real paired source TD") {
            it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("compiled-table-cell-root/block-1-") == true
        }
        compose.onAllNodes(cells, useUnmergedTree = true).assertCountEquals(5)
        val first = gridCell(0).fetchSemanticsNode().config[SemanticsProperties.CollectionItemInfo]
        val last = gridCell(4).fetchSemanticsNode().config[SemanticsProperties.CollectionItemInfo]
        assertEquals(2, first.rowSpan); assertEquals(1, first.columnSpan)
        assertEquals(7, last.columnSpan)
    }
    private fun actionOrigin(view: NativeFloatTextView, cellWindow: RectF): Pair<Float, Float> {
        // This fixture has one native text owner, zero cell edges and top alignment.
        val surface = (view.currentMeasuredGeometry as NativeSurfaceGeometry).surface
        return cellWindow.left + surface.left to cellWindow.top + surface.top
    }
    private fun assertActionClip(view: NativeFloatTextView, node: FloatInteractionNode, clipWindow: RectF, cellWindow: RectF) {
        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
        try {
            assertEquals(0, view.scrollX); assertEquals(0, view.scrollY)
            val screen = IntArray(2).also(compose.activity.window.decorView::getLocationOnScreen)
            val window = IntArray(2).also(compose.activity.window.decorView::getLocationInWindow)
            val (x, y) = actionOrigin(view, cellWindow)
            val raw = RectF().apply { node.bounds.forEach(::union) }
            raw.offset(x + view.paddingLeft + screen[0] - window[0], y + view.paddingTop + screen[1] - window[1])
            val clip = RectF(clipWindow).apply { offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat()) }
            val visible = raw.intersect(clip)
            val expected = Rect()
            if (visible) raw.roundOut(expected)
            val actual = Rect(); info.getBoundsInScreen(actual)
            assertEquals(expected, actual)
            assertEquals(visible, info.isVisibleToUser)
            assertEquals(node.label.toString(), info.text.toString()); assertTrue(info.isClickable)
        } finally { info.recycle() }
    }
    private fun assertSourceInkInside(clipWindow: RectF) {
        val root = compose.onNodeWithTag("paired-root")
        val origin = root.fetchSemanticsNode().positionInWindow
        val pixels = root.captureToImage().asAndroidBitmap()
        val colors = sourceColors.map { 0xff000000.toInt() or it.substring(1).toInt(16) }.toSet() +
            android.graphics.Color.RED
        try {
            var count = 0
            for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                if (pixels.getPixel(x, y) in colors) {
                    count++
                    assertTrue("Authored A ink must use the same source viewport clip as native hit/AX",
                        clipWindow.contains(origin.x + x + .5f, origin.y + y + .5f))
                }
            }
            assertTrue("The clipped source actions still paint", count > 0)
        } finally { pixels.recycle() }
    }
    private fun tap(view: NativeFloatTextView, node: FloatInteractionNode) {
        assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
        val bounds = node.bounds.first { !it.isEmpty }
        val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN,
            bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
        val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP, down.x, down.y, 0)
        try { assertTrue(view.dispatchTouchEvent(down)); assertTrue(view.dispatchTouchEvent(up)) }
        finally { down.recycle(); up.recycle() }
    }
    private fun rejectClippedGlyph(view: NativeFloatTextView, node: FloatInteractionNode, clipWindow: RectF, cellWindow: RectF) {
        val geometry = checkNotNull(view.currentMeasuredGeometry)
        val (originX, originY) = actionOrigin(view, cellWindow)
        val point = (node.start until node.end).mapNotNull { offset ->
            if (view.logicalText[offset].isWhitespace()) null else {
                val first = geometry.caretRect(offset); val next = geometry.caretRect(offset + 1)
                if (kotlin.math.abs(first.top - next.top) > .01f || next.centerX() <= first.centerX()) null else {
                    val x = (first.centerX() + next.centerX()) / 2f
                    val y = (first.centerY() + next.centerY()) / 2f
                    if (clipWindow.contains(originX + view.paddingLeft + x, originY + view.paddingTop + y)) null else x to y
                }
            }
        }.firstOrNull()
        assertNotNull("The typed LTR action has a real glyph outside the source clip", point)
        val (x, y) = checkNotNull(point)
        assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
        val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x + view.paddingLeft, y + view.paddingTop, 0)
        try { assertFalse(view.dispatchTouchEvent(down)) } finally { down.recycle() }
        assertFalse(node.missingLinkPaint!!.active)
    }

    @Test fun onePairedOwnerFitsItsAssignedIntervalThenRetainsAndClampsTheSameGridAndActionOffsets() {
        val fixture = fixture()
        val viewportWidth = mutableStateOf(639.5)
        val containingWidth = mutableStateOf(240)
        val actions = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        val visits = MissingLinkVisits()
        val owner = Any()
        withScene("paired-table-layout.png", { Scene(fixture, viewportWidth.value, containingWidth.value,
            visits, owner, actions, failures) }) {
            val identities = mutableMapOf<String, MissingLinkActionIdentity>()
            val ranges = mutableMapOf<String, Pair<Int, Int>>()
            fun inventory() {
                assertTopology(fixture); ready(failures)
                compose.runOnIdle {
                    val nodes = actionViews().flatMap { view -> view.currentMeasuredGeometry!!.nodes.filter {
                        it.missingLinkPaint?.ordinaryPolicy != null
                    } }
                    assertEquals(2, nodes.size)
                    for (span in listOf(fixture.rowspan, fixture.footer)) {
                        val label = label(span)
                        val view = actionView(label); val node = actionNode(view, label)
                        val identity = checkNotNull(node.missingLinkPaint!!.actionIdentity)
                        if (label !in identities) { identities[label] = identity; ranges[label] = node.start to node.end }
                        else { assertEquals(identities[label], identity); assertEquals(ranges[label], node.start to node.end) }
                        assertEquals(span.linkPaint, node.missingLinkPaint!!.ordinaryPolicy)
                        assertEquals(label, view.logicalText.subSequence(node.start, node.end).toString())
                        view.setSelection(node.start, node.end)
                        assertEquals(label, view.selectedTextForCopy())
                        assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                    }
                }
            }
            inventory()
            compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
            assertEquals(box(containing()).right - 6.5f, box(grid()).right, .05f)
            assertEquals(box(grid()).width(), box(viewport()).width(), .01f)

            compose.runOnIdle { viewportWidth.value = 639.0 }
            compose.waitForIdle(); inventory()
            compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
            assertEquals(170f, box(viewport()).width(), 0f) // ceil of the real169.25 border box.
            assertEquals(box(containing()).left + 60f + 4.25f, box(viewport()).left, .05f)
            assertEquals(box(viewport()).left + 4.75f, box(content()).left, .05f)
            assertEquals(161f, box(content()).width(), 0f)

            compose.runOnIdle { containingWidth.value = 120 }
            compose.waitForIdle(); inventory()
            assertEquals(90f, box(viewport()).width(), 0f)
            assertEquals(120f, box(grid()).width(), 0f)
            val blockerBox = box(compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true))
            assertTrue(box(viewport()).top >= blockerBox.bottom - .05f)
            assertEquals(box(containing()).left + 4.25f, box(viewport()).left, .05f)
            assertEquals(38.25f, axis().maxValue(), 0f)
            compose.runOnIdle {
                val view = actionView(label(fixture.footer)); val node = actionNode(view, label(fixture.footer))
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
            }
            compose.waitForIdle()
            scroll(12f)
            val saved = axis().value()
            assertTrue(saved > 0f && saved < axis().maxValue())
            for (wide in listOf(640.0, 639.5)) {
                compose.runOnIdle { viewportWidth.value = wide }
                compose.waitForIdle(); inventory()
                compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
                compose.runOnIdle {
                    val view = actionView(label(fixture.footer)); val node = actionNode(view, label(fixture.footer))
                    assertTrue(node.missingLinkPaint!!.focused)
                    assertEquals(identities[label(fixture.footer)], node.missingLinkPaint!!.actionIdentity)
                }
                assertTrue(box(grid()).left < box(containing()).left)
                assertEquals(box(containing()).right - 6.5f, box(grid()).right, .05f)
                compose.runOnIdle { viewportWidth.value = 639.0 }
                compose.waitForIdle(); inventory()
                assertEquals(saved, axis().value(), 0f)
                assertEquals(box(content()).left - saved, box(grid()).left, .05f)
                compose.runOnIdle {
                    assertTrue(actionNode(actionView(label(fixture.footer)), label(fixture.footer)).missingLinkPaint!!.focused)
                }
            }
            compose.runOnIdle {
                val view = actionView(label(fixture.footer)); val node = actionNode(view, label(fixture.footer))
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
            }
            compose.waitForIdle()
            scroll(10_000f)
            assertEquals(axis().maxValue(), axis().value(), 0f)
            compose.runOnIdle { containingWidth.value = 140 }
            compose.waitForIdle(); inventory()
            assertEquals(105f, box(viewport()).width(), 0f)
            assertEquals(23.25f, axis().maxValue(), 0f)
            assertEquals(axis().maxValue(), axis().value(), 0f)
            assertEquals(box(content()).left - 23.25f, box(grid()).left, .05f)
            val visible = box(content()).apply { right = left + 96.75f }
            val footerCell = box(gridCell(4))
            compose.runOnIdle {
                val view = actionView(label(fixture.footer)); val node = actionNode(view, label(fixture.footer))
                assertActionClip(view, node, visible, footerCell)
                assertEquals(0xff3366cc.toInt(), node.missingLinkPaint!!.appearance().color)
                assertFalse(node.missingLinkPaint!!.focused)
            }
            assertSourceInkInside(visible)
            compose.runOnIdle {
                val view = actionView(label(fixture.footer)); val node = actionNode(view, label(fixture.footer))
                rejectClippedGlyph(view, node, visible, footerCell)
                assertTrue(actions.isEmpty())
                tap(view, node)
            }
            compose.waitForIdle()
            scroll(-10_000f)
            compose.runOnIdle {
                val view = actionView(label(fixture.rowspan)); val node = actionNode(view, label(fixture.rowspan))
                tap(view, node)
            }
            compose.waitForIdle()
            assertEquals(listOf(EntryLink("DE-footer", targetFragment = "source-footer"),
                EntryLink("DE-rowspan", targetFragment = "source-rowspan")), actions)
            compose.runOnIdle { containingWidth.value = 240 }
            compose.waitForIdle(); inventory()
            compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
            compose.runOnIdle { containingWidth.value = 120 }
            compose.waitForIdle(); inventory()
            assertEquals(0f, axis().value(), 0f)
        }
    }

    @Test fun sourceTableFocusUsesNativePaintAndPhysicalScrollingWithoutReflowOrReplacingItsChildActions() {
        val cases = listOf(
            Triple(TableScrollFocusPaint(TableScrollFocusMode.UaAuto), TableContainingDirection.Ltr, LayoutDirection.Rtl),
            Triple(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone), TableContainingDirection.Rtl, LayoutDirection.Ltr),
            Triple(TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#cc00cc")),
                TableContainingDirection.Rtl, LayoutDirection.Rtl))
        for ((caseIndex, case) in cases.withIndex()) {
            val (policy, direction, uiDirection) = case
            val fixture = fixture(policy, short = true, gridDirection = direction)
            val current = mutableStateOf(fixture)
            val viewportWidth = mutableStateOf(639.0)
            val containingWidth = mutableStateOf(120)
            val actions = mutableListOf<EntryLink>()
            val failures = mutableListOf<String>()
            val visits = MissingLinkVisits()
            val scope = Any()
            withScene("paired-table-source-focus-$caseIndex.png", {
                Scene(current.value, viewportWidth.value, containingWidth.value, visits, scope, actions, failures, uiDirection)
            }) {
                fun bounds() = listOf(box(sourceTable()), box(content()), box(grid())) + (0..4).map { box(gridCell(it)) }
                fun pixels(): IntArray {
                    val image = compose.onNodeWithTag("paired-root").captureToImage().asAndroidBitmap()
                    return try { IntArray(image.width * image.height).also {
                        image.getPixels(it, 0, image.width, 0, 0, image.width, image.height)
                    } } finally { image.recycle() }
                }
                fun shortRows() {
                    assertTopology(fixture)
                    val b = box(gridCell(1)); val r = box(gridCell(3)); val footer = box(gridCell(4))
                    for (row in listOf(b, r, footer)) assertTrue("No synthetic 40dp row floor", row.height() > 0f && row.height() < 40f)
                    assertEquals(0f, box(gridCell(2)).height(), 0f)
                    assertTrue(box(gridCell(0)).height() <= b.height() + r.height())
                    assertEquals(b.bottom, r.top, .05f)
                    assertEquals(r.bottom, footer.top, .05f)
                    assertEquals(b.height() + r.height() + footer.height(), box(grid()).height(), .05f)
                }
                fun ax(action: Int): Boolean {
                    val id = sourceTable().fetchSemanticsNode().id
                    var accepted = false
                    compose.runOnIdle {
                        val (provider, info) = sourceAccessibility(id)
                        try { accepted = provider.performAction(id, action, null) } finally { info.recycle() }
                    }
                    compose.waitForIdle()
                    return accepted
                }
                fun assertSourceAx(focusable: Boolean, focused: Boolean, scrolling: Boolean) {
                    val node = sourceTable().fetchSemanticsNode()
                    val id = node.id
                    val rootAt = node.positionInRoot
                    val windowAt = node.positionInWindow
                    // Compose's AX region rounds in root coordinates before screen translation.
                    val actualOwner = RectF(rootAt.x.roundToInt().toFloat(), rootAt.y.roundToInt().toFloat(),
                        (rootAt.x + node.size.width).roundToInt().toFloat(), (rootAt.y + node.size.height).roundToInt().toFloat())
                        .apply { offset(windowAt.x - rootAt.x, windowAt.y - rootAt.y) }
                    val canLeft = scrolling && axis().value() > 0f
                    val canRight = scrolling && axis().value() < axis().maxValue()
                    compose.runOnIdle {
                        val (_, info) = sourceAccessibility(id)
                        try {
                            assertEquals(focusable, info.isFocusable); assertEquals(focused, info.isFocused)
                            assertFalse(info.isClickable)
                            val ids = info.actionList.map { it.id }
                            assertEquals(canRight, AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id in ids)
                            assertEquals(canLeft, AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id in ids)
                            val screen = IntArray(2).also(compose.activity.window.decorView::getLocationOnScreen)
                            val window = IntArray(2).also(compose.activity.window.decorView::getLocationInWindow)
                            val expected = RectF(actualOwner).apply {
                                offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat())
                            }
                            val rounded = Rect(); expected.roundOut(rounded)
                            val actual = Rect(); info.getBoundsInScreen(actual)
                            assertEquals(rounded, actual)
                        } finally { info.recycle() }
                    }
                }
                fun key(view: NativeTableScrollFocusView, code: Int): Boolean {
                    var accepted = false
                    compose.runOnIdle {
                        assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                        accepted = view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                        view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                    }
                    compose.waitForIdle()
                    return accepted
                }
                fun focusReaderHost() {
                    compose.runOnIdle {
                        assertTrue(actionView(label(fixture.footer)).requestFocus())
                    }
                    compose.waitForIdle()
                }
                fun assertSourcePaint(before: IntArray) {
                    if (policy.mode == TableScrollFocusMode.UaAuto) {
                        compose.waitUntil(5_000) { !before.contentEquals(pixels()) }
                    } else assertArrayEquals("Authored none suppresses only source TABLE focus paint", before, pixels())
                }
                fun actionsUnchanged() {
                    compose.runOnIdle {
                        assertEquals(2, actionViews().sumOf { view -> view.currentMeasuredGeometry!!.nodes.count {
                            it.missingLinkPaint?.ordinaryPolicy != null
                        } })
                        for (span in listOf(fixture.rowspan, fixture.footer)) {
                            val view = actionView(label(span)); val node = actionNode(view, label(span))
                            assertEquals(span.linkPaint, node.missingLinkPaint!!.ordinaryPolicy)
                            assertFalse(node.missingLinkPaint!!.focused)
                            assertFalse(node.missingLinkPaint!!.appearance().underline)
                            assertEquals(label(span), view.logicalText.subSequence(node.start, node.end).toString())
                            view.setSelection(node.start, node.end)
                            assertEquals(label(span), view.selectedTextForCopy())
                        }
                        assertTrue(actions.isEmpty())
                    }
                }

                ready(failures); shortRows(); actionsUnchanged()
                val sourceId = sourceTable().fetchSemanticsNode().id
                val native = compose.runOnIdle { sourceFocusView() }
                compose.runOnIdle {
                    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, native.importantForAccessibility)
                    assertEquals(policy, native.owner.policy)
                    assertEquals(policy.mode == TableScrollFocusMode.UaAuto, native.defaultFocusHighlightEnabled)
                }
                focusReaderHost()
                val unfocused = pixels(); val measured = bounds(); val initialOffset = axis().value()
                assertTrue(ax(AccessibilityNodeInfo.ACTION_FOCUS))
                compose.runOnIdle { assertTrue(native.isFocused); assertTrue(native.owner.isFocused) }
                assertEquals(true, sourceTable().fetchSemanticsNode().config[SemanticsProperties.Focused])
                assertSourceAx(focusable = true, focused = true, scrolling = true)
                assertEquals(measured, bounds()); assertEquals(initialOffset, axis().value(), 0f)
                assertSourcePaint(unfocused); actionsUnchanged()
                assertTrue(ax(AccessibilityNodeInfo.ACTION_CLEAR_FOCUS))
                compose.runOnIdle { assertFalse(native.isFocused); assertFalse(native.owner.isFocused) }
                assertTrue(ax(AccessibilityNodeInfo.ACTION_FOCUS))
                compose.runOnIdle { assertTrue(native.isFocused) }

                // The source axis is physical even when the reader UI or anonymous grid is RTL.
                if (axis().value() > 0f) assertTrue(ax(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id))
                assertEquals(0f, axis().value(), 0f)
                assertTrue(ax(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id))
                assertTrue(axis().value() > 0f)
                assertTrue(ax(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id))
                assertEquals(0f, axis().value(), 0f)
                assertTrue(key(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                assertTrue(axis().value() > 0f)
                assertTrue(key(native, KeyEvent.KEYCODE_MOVE_HOME))
                assertEquals(0f, axis().value(), 0f)
                assertTrue(key(native, KeyEvent.KEYCODE_MOVE_END))
                assertEquals(38.25f, axis().maxValue(), 0f)
                assertEquals(38.25f, axis().value(), 0f)
                assertEquals(box(content()).left - 38.25f, box(grid()).left, .05f)
                assertTrue(key(native, KeyEvent.KEYCODE_MOVE_HOME)); assertEquals(0f, axis().value(), 0f)

                // Positive source area with zero range remains a genuine focus target.
                compose.runOnIdle { containingWidth.value = 240 }
                compose.waitForIdle(); shortRows(); ready(failures)
                compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
                compose.runOnIdle { assertSame(native, sourceFocusView()); assertTrue(native.isFocused) }
                assertFalse(key(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                focusReaderHost()
                val zeroPaint = pixels(); val zeroBounds = bounds()
                assertTrue(ax(AccessibilityNodeInfo.ACTION_FOCUS))
                assertEquals(zeroBounds, bounds()); assertSourcePaint(zeroPaint)
                compose.runOnIdle { assertTrue(native.isFocused); assertFalse(native.owner.canScroll) }
                assertSourceAx(focusable = true, focused = true, scrolling = false)

                compose.runOnIdle { containingWidth.value = 120 }
                compose.waitForIdle()
                if (axis().value() > 0f) assertTrue(key(native, KeyEvent.KEYCODE_MOVE_HOME))
                assertTrue(key(native, KeyEvent.KEYCODE_MOVE_END))
                val saved = axis().value()
                for (wide in listOf(639.5, 640.0)) {
                    compose.runOnIdle { viewportWidth.value = wide }
                    compose.waitForIdle(); shortRows(); ready(failures)
                    assertEquals(sourceId, sourceTable().fetchSemanticsNode().id)
                    compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
                    assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.RequestFocus))
                    compose.runOnIdle {
                        assertSame(native, sourceFocusView()); assertTrue(native.isFocused)
                        assertEquals(NativeTableFocusTransfer.RetainedForWide, native.owner.lastTransfer)
                        assertFalse(native.owner.requestSourceFocus())
                        val candidates = arrayListOf<View>(); native.addFocusables(candidates, View.FOCUS_FORWARD, View.FOCUSABLES_ALL)
                        assertFalse(native in candidates)
                    }
                    assertFalse(key(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                    val wideBounds = bounds(); val wideFocused = pixels()
                    focusReaderHost()
                    assertArrayEquals("Wide source focus cannot paint a UA outline", wideFocused, pixels())
                    assertEquals(wideBounds, bounds())
                    assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsProperties.Focused))
                    assertSourceAx(focusable = false, focused = false, scrolling = false)
                    compose.runOnIdle { assertFalse(native.owner.requestSourceFocus()) }
                    compose.runOnIdle { viewportWidth.value = 639.0 }
                    compose.waitForIdle(); shortRows()
                    assertEquals(saved, axis().value(), 0f)
                    assertTrue(ax(AccessibilityNodeInfo.ACTION_FOCUS))
                }
                // One further transition keeps the actual focus throughout, without a host transfer.
                compose.runOnIdle { viewportWidth.value = 640.0 }
                compose.waitForIdle()
                compose.runOnIdle { viewportWidth.value = 639.0 }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertSame(native, sourceFocusView()); assertTrue(native.isFocused)
                    assertEquals(NativeTableFocusTransfer.RestoredForNarrow, native.owner.lastTransfer)
                }
                assertEquals(saved, axis().value(), 0f); actionsUnchanged()

                val childLabel = label(fixture.footer)
                compose.runOnIdle {
                    val view = actionView(childLabel); val node = actionNode(view, childLabel)
                    val identity = node.missingLinkPaint!!.actionIdentity
                    assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                    assertEquals(identity, node.missingLinkPaint!!.actionIdentity)
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    val view = actionView(childLabel); val node = actionNode(view, childLabel)
                    assertFalse(native.isFocused); assertTrue(node.missingLinkPaint!!.focused)
                    assertTrue(node.missingLinkPaint!!.appearance().underline)
                    assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                    assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER)))
                }
                compose.waitForIdle()
                assertEquals(listOf(EntryLink("DE-footer", targetFragment = "source-footer")), actions)
                if (caseIndex == 0) {
                    // This is valid paired data with a truly empty TD and zero source border area.
                    // Native View focus cannot represent it; the reader must refuse visibly, not invent a pixel.
                    val policyBox = checkNotNull(fixture.table.blockViewport)
                    val empty = fixture.table.copy(rows = listOf(listOf(Cell(emptyList(), false, 1, 1,
                        style = CellStyle(border = StyleBorder.None, padding = edges(), minWidth = px(0f))))),
                        blockViewport = policyBox.copy(boxStyle = policyBox.boxStyle.copy(
                            border = StyleBorder.None, padding = edges())))
                    compose.runOnIdle { current.value = fixture.copy(table = empty) }
                    compose.waitForIdle()
                    assertTrue(failures.toString(), failures.any { it == "Table automatic margin measurement is unavailable" })
                    compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true)
                        .onFirst().assertIsDisplayed()
                    compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(0)
                    compose.runOnIdle {
                        assertTrue(views().filterIsInstance<NativeTableScrollFocusView>().none { it.owner.canAcquireFocus })
                        assertTrue(views().filterIsInstance<NativeTableScrollFocusView>().none { it === native })
                        assertTrue(views().filterIsInstance<NativeFloatTextView>().any { it.logicalText.contains("F") })
                        assertTrue(actionViews().isEmpty())
                        assertEquals(1, empty.rows.size); assertTrue(empty.rows.single().single().spans.isEmpty())
                        current.value = fixture; failures.clear()
                    }
                    compose.waitForIdle(); ready(failures); shortRows()
                    compose.runOnIdle {
                        assertNotSame(native, sourceFocusView())
                        assertTrue(sourceFocusView().owner.canAcquireFocus)
                        val view = actionView(childLabel); val node = actionNode(view, childLabel)
                        assertEquals(fixture.footer.linkPaint, node.missingLinkPaint!!.ordinaryPolicy)
                        view.setSelection(node.start, node.end); assertEquals(childLabel, view.selectedTextForCopy())
                        assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                    }
                    compose.waitForIdle()
                    assertEquals(List(2) { EntryLink("DE-footer", targetFragment = "source-footer") }, actions)
                }
            }
        }
    }
}
