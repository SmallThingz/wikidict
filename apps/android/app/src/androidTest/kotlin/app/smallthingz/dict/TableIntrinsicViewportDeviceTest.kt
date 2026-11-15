package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
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
import kotlin.math.ceil
import kotlin.math.floor

/** Synthetic DPRR constructor controls, not a KU capture or producer/Reader qualification. */
class TableIntrinsicViewportDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private fun line(size: Float = 12f, height: Float = 20f) = CellLineHeight(
        CellLineHeightValue.Length(CellFixedLineHeight(height, FontScaleBasis.CssPx)),
        CellTextStrut(size, FontScaleBasis.CssPx))
    private fun link(text: String, target: String, trail: String = ""): Span {
        val normal = FigureLinkState("#0000ff", false)
        val policy = LinkPaint(normal, normal, normal, normal, normal, normal, normal, normal,
            underlineOnFocus = true)
        return Span("link", text, target, targetFragment = "source", trail = trail,
            fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx, foreground = "#0000ff", linkPaint = policy)
    }
    private fun table(rows: List<List<Cell>>, gridDirection: TableContainingDirection = TableContainingDirection.Ltr,
        boxPadding: StyleEdges = edges(2f, 4f, 2f, 3f), margins: StyleEdges = edges(bottom = 6f, right = 7f, left = 5f),
        border: StyleBorder = StyleBorder.Solid(px(2f), "#008000"),
        focus: TableScrollFocusPaint = TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone), boxBorderWidth: Float = 2f) =
        Table(emptyList(), rows, geometry = TableGeometry(border = 1, cellSpacing = 0, cellPadding = 4),
            style = TableStyle(border = border, collapse = TableCollapse.Collapse, margins = margins),
            blockViewport = TableBlockViewport(639,
                TableStyle(border = StyleBorder.Solid(px(boxBorderWidth), "#008000"), background = "#ffffcc",
                    padding = boxPadding, margins = margins), ContainerBoxSizing.BorderBox,
                StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
                gridDirection, "ku", focusPaint = focus, intrinsicContainingDirection = TableContainingDirection.Ltr))
    private fun block(table: Table) = Block("table", 0, emptyList(), table = table)
    private val blocker = block(Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "F")), false, 1, 1,
        style = CellStyle(border = StyleBorder.None, padding = edges(bottom = 400f), minWidth = px(60f))))),
        style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse, margins = edges(),
            width = StyleWidth(StyleWidthUnit.Px, 60f), floatSide = TableFloatSide.Left)))
    private val following = Span("link", "t", "Following", fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx)

    @Composable private fun Scene(table: Table, viewport: Double, width: Int, withBlocker: Boolean,
        actions: MutableList<EntryLink>, failures: MutableList<String>, visits: MissingLinkVisits, owner: Any,
        recovery: OwnedTouchRecovery? = null) {
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Rtl,
            LocalTableDocumentViewportCssWidth provides viewport, LocalEntryEdition provides "ku",
            LocalMissingLinkVisits provides visits, LocalMissingLinkDocument provides "Intrinsic constructor",
            LocalMissingLinkOwner provides owner, LocalNativeFloatContextFailureObserver provides { failures += it }) {
            DictTheme("light") {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                    fontFamily = FontFamily.Monospace, letterSpacing = 0.sp))) {
                    val recoveryModifier = if (recovery == null) Modifier else {
                        val root = LocalView.current
                        SideEffect { recovery.root = root }
                        Modifier.onGloballyPositioned { coordinates ->
                            val at = coordinates.positionInWindow()
                            recovery.strip = if (coordinates.isAttached && coordinates.size.height >= 32)
                                RectF(at.x, at.y, at.x + coordinates.size.width, at.y + 32f) else null
                        }.pointerInteropFilter { event -> recovery.receive(event) }
                    }
                    Box(Modifier.width(400.dp).background(Color.White).testTag("intrinsic-root").then(recoveryModifier)) {
                        Box(Modifier.padding(start = 20.dp, top = 32.dp)) {
                            Box(Modifier.width(width.dp).testTag("intrinsic-containing")) {
                                NativeFloatBlockContext((if (withBlocker) listOf(blocker) else emptyList()) +
                                    listOf(block(table), Block("paragraph", 0, listOf(following))), { actions += it },
                                    "intrinsic-constructor", Modifier, inCell = false, gridPath = "root", gapDp = 0f,
                                    trailingGap = false)
                            }
                        }
                    }
                }
            }
        }
    }
    private fun control(content: @Composable () -> Unit, assertions: () -> Unit) {
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent(content = content) }
            compose.waitForIdle(); assertions()
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }
    private fun node(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true)
    private fun source() = node("compiled-table-scroll-focus")
    private fun content() = node("compiled-table-block-content")
    private fun grid(block: Int) = node("compiled-table-grid-root/block-$block")
    private fun cell(block: Int, index: Int) = node("compiled-table-cell-root/block-$block-$index")
    private fun box(node: SemanticsNodeInteraction): RectF {
        val semantic = node.fetchSemanticsNode(); val p = semantic.positionInWindow
        return RectF(p.x, p.y, p.x + semantic.size.width, p.y + semantic.size.height)
    }
    private fun axis() = source().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange)
    private fun scroll(delta: Float) {
        source().performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(delta, 0f)) }
        compose.waitForIdle()
    }
    // Called only inside runOnIdle; live View/geometry/location/provider reads share the UI owner.
    private fun views(): List<View> {
        val result = mutableListOf<View>()
        fun visit(view: View) {
            if (view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView); return result
    }
    private fun focusView() = views().filterIsInstance<NativeTableScrollFocusView>().single()
    private fun actionView(label: String) = views().filterIsInstance<NativeFloatTextView>().single { view ->
        view.currentMeasuredGeometry?.nodes?.any { it.kind == FloatInteractionKind.LINK && it.label.toString() == label } == true
    }
    private fun actionNode(view: NativeFloatTextView, label: String) = checkNotNull(view.currentMeasuredGeometry).nodes.single {
        it.kind == FloatInteractionKind.LINK && it.label.toString() == label
    }
    private fun ready(failures: List<String>, from: Int = 0) {
        compose.runOnIdle { assertTrue(failures.drop(from).toString(), failures.drop(from).isEmpty()) }
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
    }
    private data class Action(val view: NativeFloatTextView, val id: Int, val start: Int, val end: Int,
        val origin: Offset, val rectangles: List<RectF>, val identity: MissingLinkActionIdentity?)
    private fun action(span: Span): Action = compose.runOnIdle {
        val label = span.text + span.trail; val view = actionView(label); val geometry = checkNotNull(view.currentMeasuredGeometry)
        val entry = actionNode(view, label)
        assertEquals(label, geometry.text.subSequence(entry.start, entry.end).toString())
        assertEquals(span.linkPaint, entry.missingLinkPaint?.ordinaryPolicy)
        val at = IntArray(2).also(view::getLocationInWindow)
        val origin = Offset(at[0].toFloat() + view.paddingLeft, at[1].toFloat() + view.paddingTop)
        view.setSelection(entry.start, entry.end)
        assertEquals(label, view.selectedTextForCopy())
        assertTrue(geometry.characterRects(entry.start, entry.end - entry.start).all { it != null })
        assertTrue(geometry.rectsForRange(entry.start, entry.end).isNotEmpty())
        assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
        Action(view, entry.id, entry.start, entry.end, origin,
            entry.bounds.map { RectF(it).apply { offset(origin.x, origin.y) } }, entry.missingLinkPaint?.actionIdentity)
    }
    private fun tap(action: Action, point: Offset, actions: List<EntryLink>, accepted: Boolean) {
        compose.runOnIdle {
            assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
            val before = actions.size; val now = SystemClock.uptimeMillis()
            val x = point.x - action.origin.x + action.view.paddingLeft
            val y = point.y - action.origin.y + action.view.paddingTop
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0)
            val up = MotionEvent.obtain(now, now + 10, MotionEvent.ACTION_UP, x, y, 0)
            try {
                assertEquals(accepted, action.view.dispatchTouchEvent(down)); action.view.dispatchTouchEvent(up)
                assertEquals(before + if (accepted) 1 else 0, actions.size)
            } finally { down.recycle(); up.recycle() }
        }
        compose.waitForIdle()
    }
    private fun sourceProvider(id: Int, rows: Int): Pair<AccessibilityNodeProvider, AccessibilityNodeInfo> {
        val matches = mutableListOf<Pair<AccessibilityNodeProvider, AccessibilityNodeInfo>>()
        for (view in views()) {
            val provider = view.accessibilityNodeProvider ?: continue
            val info = provider.createAccessibilityNodeInfo(id) ?: continue
            if (info.collectionInfo?.rowCount == rows && info.collectionInfo?.columnCount == 1) matches += provider to info
            else info.recycle()
        }
        assertEquals(1, matches.size); return matches.single()
    }
    private fun sourceAction(rows: Int, action: Int): Boolean {
        val id = source().fetchSemanticsNode().id
        val accepted = compose.runOnIdle {
            val (provider, info) = sourceProvider(id, rows)
            try { provider.performAction(id, action, null) } finally { info.recycle() }
        }
        compose.waitForIdle(); return accepted
    }
    private fun key(view: NativeTableScrollFocusView, code: Int): Boolean {
        val accepted = compose.runOnIdle {
            assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
            val result = view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code)); result
        }
        compose.waitForIdle(); return accepted
    }
    private fun pixels() = node("intrinsic-root").captureToImage().toPixelMap()
    private fun color(image: PixelMap, point: Offset): Int {
        val root = box(node("intrinsic-root")); val c = image[(point.x - root.left).toInt(), (point.y - root.top).toInt()]
        return ((c.red * 255f + .5f).toInt() shl 16) or ((c.green * 255f + .5f).toInt() shl 8) or (c.blue * 255f + .5f).toInt()
    }
    private fun blue(region: RectF, allowed: (Offset) -> Boolean): Offset {
        val image = pixels(); val root = box(node("intrinsic-root"))
        for (y in maxOf(floor(region.top).toInt(), ceil(root.top).toInt()) until minOf(ceil(region.bottom).toInt(), floor(root.bottom).toInt()))
            for (x in maxOf(floor(region.left).toInt(), ceil(root.left).toInt()) until minOf(ceil(region.right).toInt(), floor(root.right).toInt())) {
                val p = Offset(x + .5f, y + .5f)
                if (allowed(p) && color(image, p) == 0x0000ff) return p
            }
        throw AssertionError("The measured original action must supply real blue source ink for this probe")
    }

    @Test fun intrinsicAutoAndFitContentUseRealIntervalsAndKeepLegacyCellHintsAndOverrides() {
        val a = link("A A A A A A A A A A A A A A A A A", "Intrinsic-A", "!")
        val b = link("B", "Intrinsic-B")
        val rows = listOf(
            listOf(Cell(listOf(a), false, 1, 1, style = CellStyle(minWidth = px(90f), lineHeight = line(), textAlign = CellTextAlign.Left))),
            listOf(Cell(listOf(b), false, 1, 1, style = CellStyle(border = StyleBorder.Solid(px(3f), "#ff0000"),
                padding = edges(1f, 1f, 1f, 1f), minWidth = px(90f), lineHeight = line(), textAlign = CellTextAlign.Left))),
            listOf(Cell(emptyList(), false, 1, 1, style = CellStyle(lineHeight = line()))))
        val original = table(rows, border = StyleBorder.Solid(px(4f), "#008000"), boxBorderWidth = 4f)
        val selected = mutableStateOf(original); val viewport = mutableStateOf(639.5); val width = mutableStateOf(300)
        val actions = mutableListOf<EntryLink>(); val failures = mutableListOf<String>(); val visits = MissingLinkVisits(); val owner = Any()
        control({ Scene(selected.value, viewport.value, width.value, true, actions, failures, visits, owner) }) {
            val sameView = compose.runOnIdle { focusView() }
            val sourceA = action(a); val sourceB = action(b)
            fun inventory() {
                ready(failures)
                assertSame(rows, selected.value.rows); assertNull(selected.value.floatViewport)
                assertNull(selected.value.style!!.floatSide); assertNull(selected.value.style!!.width)
                assertEquals(TableGeometry(border = 1, cellSpacing = 0, cellPadding = 4), selected.value.geometry)
                for ((span, before) in listOf(a to sourceA, b to sourceB)) {
                    val now = action(span)
                    assertSame(before.view, now.view); assertEquals(before.id, now.id)
                    assertEquals(before.start to before.end, now.start to now.end); assertEquals(before.identity, now.identity)
                }
                compose.runOnIdle { assertSame(sameView, focusView()) }
                assertEquals(3, source().fetchSemanticsNode().config[SemanticsProperties.CollectionInfo].rowCount)
                // Grid spacing=0: each actual row starts at the preceding measured row end.
                assertEquals(box(cell(1, 0)).bottom, box(cell(1, 1)).top, .05f)
                assertEquals(box(cell(1, 1)).bottom, box(cell(1, 2)).top, .05f)
                assertEquals(26f, box(cell(1, 1)).height(), .05f) // 20 + 2*(1px pad + ceil(3/2) border).
                val narrow = viewport.value <= 639.0
                // In wide mode the source outer border legitimately wins the perimeter.
                // In narrow mode it belongs only to the block; the real empty cell keeps hint1.
                assertEquals(if (narrow) 11f else 12f, box(cell(1, 2)).height(), .05f)
                for ((span, index, inset) in listOf(Triple(a, 0, if (narrow) 5f else 6f), Triple(b, 1, 3f))) {
                    val cellBox = box(cell(1, index))
                    compose.runOnIdle {
                        val view = actionView(span.text + span.trail)
                        val surface = (view.currentMeasuredGeometry as NativeSurfaceGeometry).surface
                        val at = IntArray(2).also(view::getLocationInWindow)
                        assertEquals(cellBox.left + inset + surface.left, at[0].toFloat(), .05f)
                    }
                }
                val next = compose.runOnIdle {
                    val view = actionView(following.text); val n = actionNode(view, following.text)
                    val at = IntArray(2).also(view::getLocationInWindow)
                    n.bounds.first().top + at[1] + view.paddingTop
                }
                assertTrue("An ordinary Table advances the following flow", next >= box(source()).bottom)
            }
            inventory()
            val initial = box(source()); val container = box(node("intrinsic-containing")); val floating = box(grid(0))
            assertEquals(container.left + 60f + 5f, initial.left, .05f)
            assertTrue(initial.top < floating.bottom && initial.bottom > floating.top)
            assertEquals(228f, initial.width(), 0f) // F=300-60; ordinary Auto has 5+7 fixed margins.
            assertNull(axis())
            compose.runOnIdle { viewport.value = 639.0 }; compose.waitForIdle(); inventory()
            assertEquals(228f, box(source()).width(), 0f)
            assertEquals(213f, box(content()).width(), 0f) // 4+3 and 4+4 box edges, each once.
            assertEquals(box(source()).left + 7f, box(content()).left, .05f)
            assertEquals(box(content()).left, box(grid(1)).left, .05f)
            val overrideBox = box(cell(1, 1))
            assertEquals(0xff0000, color(pixels(), Offset(overrideBox.centerX(), overrideBox.top + .5f)))
            assertEquals(0x008000, color(pixels(), Offset(box(source()).left + 1.5f, overrideBox.centerY())))
            assertNull(axis())
            compose.runOnIdle { viewport.value = 640.0; width.value = 360 }; compose.waitForIdle(); inventory()
            assertTrue("Auto retains preferred width instead of stretching to 100%", box(source()).width() < 288f)
            assertEquals(box(node("intrinsic-containing")).left + 65f, box(source()).left, .05f)
            val tailWidth = compose.runOnIdle { actionNode(actionView(following.text), following.text).bounds.single().width() }
            assertTrue("The following glyph could fit beside a wrongly floated table, but must remain after the ordinary table",
                box(node("intrinsic-containing")).right - box(source()).right - 7f > tailWidth)
            compose.runOnIdle { viewport.value = 639.0; width.value = 80 }; compose.waitForIdle(); inventory()
            assertTrue("A minimum too wide for the remaining band moves below the real blocker", box(source()).top >= box(grid(0)).bottom - .05f)
            assertEquals(80f, box(source()).width(), 0f)
            assertEquals(100f, box(grid(1)).width(), 0f)
            assertEquals(35f, checkNotNull(axis()).maxValue(), 0f)
            // This final F is C after moving below; original-C cap discrimination is a scalar host control.
            val zero = original.copy(rows = listOf(listOf(Cell(emptyList(), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = edges(), lineHeight = line(0f, 0f))))))
            compose.runOnIdle { selected.value = zero; width.value = 300 }; compose.waitForIdle(); ready(failures)
            assertEquals(0f, box(cell(1, 0)).height(), 0f)
            assertEquals(0f, box(grid(1)).height(), 0f)
            assertEquals(12f, box(source()).height(), 0f) // Only actual source box border+padding remains.
            assertNull(axis())
            assertTrue(sourceAction(1, AccessibilityNodeInfo.ACTION_FOCUS))
            compose.runOnIdle { assertTrue(focusView().isFocused); assertNotSame(sameView, focusView()) }
            compose.runOnIdle { selected.value = original; viewport.value = 639.5; width.value = 300 }; compose.waitForIdle(); ready(failures)
            assertEquals(initial, box(source()))
            val recovered = action(a); val visible = recovered.rectangles.first()
            tap(recovered, Offset(visible.centerX(), visible.centerY()), actions, true)
            compose.runOnIdle { assertEquals(EntryLink("Intrinsic-A", targetFragment = "source"), actions.last()) }

            // Caption data remains valid; the initial native focus/height owner explicitly refuses it.
            val caption = link("Intrinsic caption", "Intrinsic-caption")
            val withCaption = original.copy(caption = listOf(caption))
            assertSame(rows, withCaption.rows)
            val beforeFailure = compose.runOnIdle { failures.size }
            compose.runOnIdle { selected.value = withCaption; viewport.value = 639.0 }; compose.waitForIdle()
            compose.waitUntil(5_000) { compose.runOnIdle {
                failures.drop(beforeFailure).any { it == "Intrinsic table focus with a caption is unavailable." }
            } }
            compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).onFirst().assertIsDisplayed()
            compose.runOnIdle { assertTrue(views().filterIsInstance<NativeTableScrollFocusView>().none { it.owner.canAcquireFocus }) }
            for (span in listOf(caption, a, b)) {
                val retained = compose.onNodeWithText(span.text + span.trail, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                retained.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertEquals(span.text + span.trail, layouts.single().layoutInput.text.text)
                val count = compose.runOnIdle { actions.size }
                retained.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                compose.runOnIdle {
                    assertEquals(count + 1, actions.size)
                    assertEquals(EntryLink(span.target, targetFragment = "source"), actions.last())
                }
            }
            val beforeRecovery = compose.runOnIdle { failures.size }
            compose.runOnIdle { selected.value = original }; compose.waitForIdle(); ready(failures, beforeRecovery)
            action(a); action(b)
            compose.runOnIdle { assertTrue(focusView().owner.canAcquireFocus) }

            // Exact synthetic counterpart of the retained typed CENTER shape: the original
            // cell owns one ordinary centered paragraph, without converting its dash to a TD span.
            val dash = Span("text", "-")
            val paragraph = Block("paragraph", 0, listOf(dash), textAlign = CellTextAlign.Center)
            val centeredCell = Cell(emptyList(), false, 1, 1, blocks = listOf(paragraph),
                style = CellStyle(minWidth = px(90f), lineHeight = line()))
            val centered = original.copy(rows = rows + listOf(listOf(centeredCell)))
            assertSame(paragraph, centered.rows[3][0].blocks!!.single())
            assertSame(dash, paragraph.spans.single()); assertTrue(centeredCell.spans.isEmpty())
            fun centeredGeometry() {
                val cellBox = box(cell(1, 3))
                compose.runOnIdle {
                    val view = views().filterIsInstance<NativeFloatTextView>().single {
                        it.currentMeasuredGeometry?.text?.toString() == "-"
                    }
                    val surface = view.currentMeasuredGeometry as NativeSurfaceGeometry
                    val at = IntArray(2).also(view::getLocationInWindow)
                    val rect = surface.rectsForRange(0, 1).single()
                    assertEquals("The original BlockView centers within the allocated TD, not its glyph width",
                        cellBox.centerX(), rect.centerX() + at[0] + view.paddingLeft, .51f)
                    assertEquals(surface.content.extents.usedHeight + 10f, cellBox.height(), .05f)
                    assertTrue("No synthetic 40dp row floor", cellBox.height() < 40f)
                    assertTrue(surface.nodes.none { it.onClick != null })
                    view.setSelection(0, 1); assertEquals("-", view.selectedTextForCopy())
                    assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                }
            }
            compose.runOnIdle { selected.value = centered }; compose.waitForIdle(); ready(failures, beforeRecovery)
            centeredGeometry(); action(a); action(b)
            val extra = link("Extra paragraph", "Extra-paragraph")
            val unsupportedCell = centeredCell.copy(blocks = listOf(paragraph, Block("paragraph", 0, listOf(extra))))
            val unsupported = centered.copy(rows = rows + listOf(listOf(unsupportedCell)))
            assertSame(paragraph, unsupportedCell.blocks!!.first())
            val beforeRichFailure = compose.runOnIdle { failures.size }
            compose.runOnIdle { selected.value = unsupported }; compose.waitForIdle()
            compose.waitUntil(5_000) { compose.runOnIdle {
                failures.drop(beforeRichFailure).any { it == "Paired table intrinsic measurement is unavailable" }
            } }
            compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true).onFirst().assertIsDisplayed()
            compose.onNodeWithText("-", useUnmergedTree = true).assertIsDisplayed()
            for (span in listOf(a, b, extra)) {
                val retained = compose.onNodeWithText(span.text + span.trail, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                retained.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertEquals(span.text + span.trail, layouts.single().layoutInput.text.text)
                val count = compose.runOnIdle { actions.size }
                retained.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                compose.runOnIdle {
                    assertEquals(count + 1, actions.size)
                    assertEquals(EntryLink(span.target, targetFragment = "source"), actions.last())
                }
            }
            val afterRichFailure = compose.runOnIdle { failures.size }
            compose.runOnIdle { selected.value = centered }; compose.waitForIdle(); ready(failures, afterRichFailure)
            centeredGeometry(); action(a); action(b)
        }
    }

    // B alone owns this ordinary input recovery. The controller must supply the actual build
    // identity and its fresh full-system census; app-visible displays are not a complete census.
    private data class RecoveryReceipt(val action: Int, val downTime: Long, val eventTime: Long,
        val count: Int, val pointerId: Int, val source: Int, val x: Float, val y: Float)
    private data class RecoveryWindow(val activity: android.app.Activity, val decor: View, val root: View,
        val token: android.os.IBinder, val strip: RectF, val visibleWindow: Rect, val point: Offset,
        val touch: Boolean)
    private inner class OwnedTouchRecovery {
        var root: View? = null
        var strip: RectF? = null
        private var captured: RecoveryWindow? = null
        private var pending: Long? = null
        private var pendingPoint: Offset? = null
        private val receipts = mutableListOf<RecoveryReceipt>()
        private var rejected = false

        // PointerInteropFilter temporarily offsets the borrowed MotionEvent. Never throw,
        // retain it, or recycle it here; receipt assertions run after sendPointerSync returns.
        fun receive(event: MotionEvent): Boolean {
            val expected = pending ?: return false
            val expectedPoint = pendingPoint ?: return false
            val count = event.pointerCount
            val receipt = RecoveryReceipt(event.actionMasked, event.downTime, event.eventTime, count,
                if (count == 1) event.getPointerId(0) else -1, event.source,
                if (count > 0) event.x else Float.NaN, if (count > 0) event.y else Float.NaN)
            if (receipts.size < 3) receipts += receipt else rejected = true
            val width = strip?.width() ?: 0f
            val valid = receipt.downTime == expected && count == 1 && receipt.pointerId == 0 &&
                receipt.source == InputDevice.SOURCE_TOUCHSCREEN && receipt.x >= 0f && receipt.x < width &&
                receipt.y >= 0f && receipt.y < 32f && receipt.x == expectedPoint.x && receipt.y == expectedPoint.y &&
                ((receipt.action == MotionEvent.ACTION_DOWN && receipts.size == 1) ||
                    (receipt.action == MotionEvent.ACTION_UP && receipts.size == 2))
            if (!valid) rejected = true
            return valid
        }

        // UI-thread snapshot of the existing blank top strip, intersected with the actual
        // visible window and system insets. A missing safe point refuses before B's actions.
        private fun window(): RecoveryWindow {
            val activity = compose.activity
            assertPhysicalActivity(activity)
            val decor = activity.window.decorView
            val view = checkNotNull(root)
            check(!activity.isFinishing && !activity.isDestroyed)
            check(activity.hasWindowFocus() && decor.hasWindowFocus() && view.hasWindowFocus())
            check(decor.isAttachedToWindow && view.isAttachedToWindow && view.isShown)
            check(view.rootView === decor && view.windowToken === decor.windowToken)
            check(activity.display?.displayId == 0 && decor.display?.displayId == 0 && view.display?.displayId == 0)
            check(decor.isInTouchMode == view.isInTouchMode)
            val token = checkNotNull(decor.windowToken)
            // Keep copies before each intersection mutates its receiver. Format only on failure.
            val geometry = linkedMapOf<String, Any?>(
                "stripWindow" to strip?.let { RectF(it) },
                "decorSize" to listOf(decor.width, decor.height),
                "rootSize" to listOf(view.width, view.height),
                "decorTranslation" to listOf(decor.translationX, decor.translationY),
                "rootTranslation" to listOf(view.translationX, view.translationY))
            fun geometryFailure(stage: String): String =
                ("Owned touch recovery geometry[$stage]: " +
                    geometry.entries.joinToString("; ") { (key, value) -> "$key=$value" }).take(4096)
            val blank = RectF(checkNotNull(strip) { geometryFailure("missing-strip") })
            check(blank.width() > 4f && blank.height() == 32f) { geometryFailure("strip-size") }
            val screen = IntArray(2).also(decor::getLocationOnScreen)
            val local = IntArray(2).also(decor::getLocationInWindow)
            geometry["decorScreen"] = screen.toList()
            geometry["decorWindow"] = local.toList()
            geometry["windowToScreen"] = listOf(screen[0] - local[0], screen[1] - local[1])
            blank.offset((screen[0] - local[0]).toFloat(), (screen[1] - local[1]).toFloat())
            geometry["stripScreen"] = RectF(blank)
            val visible = Rect().also(decor::getWindowVisibleDisplayFrame)
            geometry["windowVisibleScreen"] = Rect(visible)
            val visibleWindow = Rect(visible)
            val rootVisible = Rect()
            val rootVisibleValid = view.getLocalVisibleRect(rootVisible)
            geometry["rootLocalVisibleValid"] = rootVisibleValid
            geometry["rootLocalVisible"] = if (rootVisibleValid) Rect(rootVisible) else null
            check(rootVisibleValid) { geometryFailure("root-not-visible") }
            val rootScreen = IntArray(2).also(view::getLocationOnScreen)
            geometry["rootScreen"] = rootScreen.toList()
            rootVisible.offset(rootScreen[0], rootScreen[1])
            geometry["rootVisibleScreen"] = Rect(rootVisible)
            check(visible.intersect(rootVisible)) { geometryFailure("window-root-intersection") }
            geometry["windowRootIntersection"] = Rect(visible)
            val insets = checkNotNull(decor.rootWindowInsets) { geometryFailure("missing-insets") }.getInsets(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
            geometry["systemCutoutImeInsets"] = listOf(insets.left, insets.top, insets.right, insets.bottom)
            val insetBounds = Rect(screen[0] + insets.left, screen[1] + insets.top,
                screen[0] + decor.width - insets.right, screen[1] + decor.height - insets.bottom)
            geometry["insetBoundsScreen"] = Rect(insetBounds)
            check(visibleWindow.intersect(insetBounds)) { geometryFailure("window-inset-intersection") }
            geometry["visibleWindowScreen"] = Rect(visibleWindow)
            check(visible.intersect(insetBounds)) { geometryFailure("visible-inset-intersection") }
            geometry["visibleScreen"] = Rect(visible)
            val safe = RectF(blank)
            check(safe.intersect(RectF(visible))) { geometryFailure("strip-visible-intersection") }
            geometry["stripVisibleIntersection"] = RectF(safe)
            safe.inset(2f, 2f)
            geometry["safeAfterMargin"] = RectF(safe)
            check(safe.width() > 0f && safe.height() > 0f) { geometryFailure("safe-margin") }
            val point = Offset(safe.centerX(), safe.centerY())
            return RecoveryWindow(activity, decor, view, token, blank, visibleWindow, point, decor.isInTouchMode)
        }
        private fun sameWindow(expected: RecoveryWindow): RecoveryWindow {
            val actual = window()
            check(actual.activity === expected.activity && actual.decor === expected.decor && actual.root === expected.root)
            // B intentionally resizes its content. Revalidate the current root clip in window(),
            // but compare window bounds and the exact inert strip/point, not the content extent.
            check(actual.token === expected.token && actual.strip == expected.strip && actual.visibleWindow == expected.visibleWindow)
            check(actual.point == expected.point)
            return actual
        }
        fun capture() {
            val arguments = InstrumentationRegistry.getArguments()
            check(Build.VERSION.SDK_INT >= 34)
            check(arguments.getString("owned-touch-recovery-sdk") == Build.VERSION.SDK_INT.toString())
            check(arguments.getString("owned-touch-recovery-fingerprint") == Build.FINGERPRINT)
            check(arguments.getString("owned-touch-recovery-display-ids") == "0")
            captured = compose.runOnIdle { window() }
        }
        fun restore() {
            val original = captured ?: return
            val current = compose.runOnIdle { sameWindow(original) }
            if (current.touch == original.touch) return
            check(original.touch && !current.touch) { "Owned keyboard baseline cannot be restored by a touch" }
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val downTime = SystemClock.uptimeMillis()
            compose.runOnIdle {
                receipts.clear(); rejected = false; pending = downTime
                pendingPoint = Offset(original.point.x - original.strip.left, original.point.y - original.strip.top)
            }
            var downAttempted = false
            var failure: Throwable? = null
            fun retain(problem: Throwable) {
                val first = failure
                if (first == null) failure = problem else if (first !== problem) first.addSuppressed(problem)
            }
            fun send(action: Int) {
                compose.runOnIdle { sameWindow(original) }
                val property = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
                val coordinate = MotionEvent.PointerCoords().apply {
                    x = original.point.x; y = original.point.y; pressure = if (action == MotionEvent.ACTION_DOWN) 1f else 0f; size = 1f
                }
                val event = checkNotNull(MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, 1,
                    arrayOf(property), arrayOf(coordinate), 0, 0, 1f, 1f, 0, 0,
                    InputDevice.SOURCE_TOUCHSCREEN, 0, 0, MotionEvent.CLASSIFICATION_NONE))
                try {
                    if (action == MotionEvent.ACTION_DOWN) downAttempted = true
                    instrumentation.sendPointerSync(event)
                } finally { event.recycle() }
            }
            try {
                send(MotionEvent.ACTION_DOWN)
                compose.runOnIdle {
                    check(!rejected && receipts.size == 1 && receipts.single().action == MotionEvent.ACTION_DOWN)
                }
            } catch (problem: Throwable) { retain(problem) }
            finally {
                // A DOWN may have reached the owned window even if its call failed. Pair it
                // once only while that exact window/point is still owned; never replay DOWN.
                try { if (downAttempted) send(MotionEvent.ACTION_UP) } catch (problem: Throwable) { retain(problem) }
                try {
                    compose.runOnIdle {
                        check(!rejected && receipts.size == 2)
                        check(receipts.map { it.action } == listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP))
                        check(receipts.all { it.downTime == downTime && it.eventTime >= downTime })
                        check(receipts[1].eventTime >= receipts[0].eventTime)
                        check(sameWindow(original).touch == original.touch)
                    }
                } catch (problem: Throwable) { retain(problem) }
                finally {
                    try { compose.runOnIdle { pending = null; pendingPoint = null } } catch (problem: Throwable) { retain(problem) }
                }
            }
            failure?.let { throw it }
        }
    }

    private inner class IntrinsicScrollFocusFixture {
        val glyph = link("MMMMMM", "Intrinsic-glyph").copy(fontScale = 48f,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(4f, FontScaleBasis.CssPx)),
                baselineShift = InlineComputedLength(0f, FontScaleBasis.CssPx), wrap = TextWrap.Normal))
        val rows = listOf(listOf(Cell(listOf(glyph), false, 1, 1, style = CellStyle(border = StyleBorder.None,
            padding = edges(), minWidth = px(220f), lineHeight = line(48f, 4f), textAlign = CellTextAlign.Left))))
        val original = table(rows, TableContainingDirection.Rtl, edges(12f, 10f, 12f, 10f),
            edges(top = 40f, right = 7f, bottom = 60f, left = 5f), StyleBorder.None,
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#cc00cc")))
        val selected = mutableStateOf(original); val viewport = mutableStateOf(640.0); val width = mutableStateOf(160)
        val actions = mutableListOf<EntryLink>(); val failures = mutableListOf<String>(); val visits = MissingLinkVisits(); val owner = Any()
    }

    private fun intrinsicScrollFocusControl(restoreOwnedTouch: Boolean = false,
        assertions: IntrinsicScrollFocusFixture.() -> Unit) {
        val fixture = IntrinsicScrollFocusFixture()
        val recovery = if (restoreOwnedTouch) OwnedTouchRecovery() else null
        control({ with(fixture) {
            if (recovery == null) {
                Scene(selected.value, viewport.value, width.value, false, actions, failures, visits, owner, recovery)
            } else {
                // Place B's existing blank strip inside actual app content, below system insets.
                Box(Modifier.safeDrawingPadding()) {
                    Scene(selected.value, viewport.value, width.value, false, actions, failures, visits, owner, recovery)
                }
            }
        } }) {
            var primary: Throwable? = null
            try { recovery?.capture(); fixture.assertions() }
            catch (failure: Throwable) { primary = failure; throw failure }
            finally {
                try { recovery?.restore() }
                catch (cleanup: Throwable) {
                    val failure = primary
                    if (failure == null) throw cleanup
                    if (failure !== cleanup) failure.addSuppressed(cleanup)
                }
            }
        }
    }

    @Test fun intrinsicSourceScrollFocusKeepsGridIdentityAcrossBreakpoints() {
        intrinsicScrollFocusControl {
            ready(failures)
            val wide = box(source()); val wideCell = box(cell(0, 0)); val wideAction = action(glyph)
            val native = compose.runOnIdle { focusView() }
            assertEquals(220f, wide.width(), 0f); assertEquals(4f, wideCell.height(), 0f); assertNull(axis())
            compose.runOnIdle { viewport.value = 639.0 }; compose.waitForIdle(); ready(failures)
            assertEquals(160f, box(source()).width(), 0f); assertEquals(136f, box(content()).width(), 0f)
            assertEquals(220f, box(grid(0)).width(), 0f); assertEquals(84f, checkNotNull(axis()).maxValue(), 0f)
            compose.runOnIdle { assertSame(native, focusView()); assertSame(wideAction.view, actionView(glyph.text)) }
            assertTrue(sourceAction(1, AccessibilityNodeInfo.ACTION_FOCUS))
            compose.runOnIdle {
                assertTrue(native.isFocused); assertTrue(native.owner.isFocused)
                assertTrue(native.defaultFocusHighlightEnabled)
                assertEquals(original.blockViewport!!.focusPaint, native.owner.policy)
            }
            val stable = listOf(box(source()), box(content()), box(grid(0)), box(cell(0, 0)))
            assertTrue(key(native, KeyEvent.KEYCODE_MOVE_HOME)); assertEquals(0f, checkNotNull(axis()).value(), 0f)
            assertTrue(key(native, KeyEvent.KEYCODE_MOVE_END)); assertEquals(84f, checkNotNull(axis()).value(), 0f)
            assertTrue(key(native, KeyEvent.KEYCODE_MOVE_HOME)); scroll(32f)
            val saved = checkNotNull(axis()).value(); assertEquals(32f, saved, 0f)
            assertEquals(stable.take(2), listOf(box(source()), box(content())))
            for (wideViewport in listOf(639.5, 640.0)) {
                compose.runOnIdle { viewport.value = wideViewport }; compose.waitForIdle(); ready(failures)
                assertNull(axis()); assertEquals(wide, box(source())); assertEquals(wideCell, box(cell(0, 0)))
                compose.runOnIdle {
                    assertSame(native, focusView()); assertTrue(native.isFocused)
                    assertEquals(NativeTableFocusTransfer.RetainedForWide, native.owner.lastTransfer)
                    assertFalse(native.owner.requestSourceFocus())
                }
                assertFalse(key(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                compose.runOnIdle { viewport.value = 639.0 }; compose.waitForIdle(); ready(failures)
                assertEquals(saved, checkNotNull(axis()).value(), 0f)
                val current = action(glyph)
                assertSame(wideAction.view, current.view); assertEquals(wideAction.id, current.id)
                assertEquals(wideAction.start to wideAction.end, current.start to current.end)
                assertEquals(wideAction.identity, current.identity)
            }
            assertTrue(sourceAction(1, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS))
            compose.runOnIdle { assertFalse(native.isFocused); assertFalse(native.owner.isFocused) }
        }
    }

    @Test fun intrinsicPaddingClipAndChildFocusSurviveZeroRangeRtlRestoration() {
        intrinsicScrollFocusControl(restoreOwnedTouch = true) {
            // This independent fixture starts wide; it does not replay the TABLE-focus scenario.
            ready(failures)
            assertSame(original, selected.value); assertSame(rows, selected.value.rows)
            val collection = source().fetchSemanticsNode().config[SemanticsProperties.CollectionInfo]
            assertEquals(1, collection.rowCount); assertEquals(1, collection.columnCount)
            val wideCell = box(cell(0, 0))
            assertEquals("Fresh wide source grid keeps its only original cell", box(grid(0)), wideCell)
            val native = compose.runOnIdle { focusView() }
            val wideAction = compose.runOnIdle {
                assertFalse("Fresh wide TABLE has no native focus", native.isFocused)
                assertFalse("Fresh wide TABLE has no source focus", native.owner.isFocused)
                assertFalse("Fresh wide TABLE cannot acquire source focus", native.owner.canAcquireFocus)
                assertEquals(original.blockViewport!!.focusPaint, native.owner.policy)
                val label = glyph.text + glyph.trail
                val view = actionView(label); val geometry = checkNotNull(view.currentMeasuredGeometry)
                val entry = actionNode(view, label)
                assertEquals("The raw witness belongs to the source action", label,
                    geometry.text.subSequence(entry.start, entry.end).toString())
                assertEquals(glyph.linkPaint, entry.missingLinkPaint?.ordinaryPolicy)
                val identity = checkNotNull(entry.missingLinkPaint?.actionIdentity)
                assertSame(owner, identity.owner)
                assertEquals(MissingLinkTarget("ku", "link", "Intrinsic-glyph", "source"), identity.target)
                assertNotNull(entry.onClick)
                val at = IntArray(2).also(view::getLocationInWindow)
                val origin = Offset(at[0].toFloat() + view.paddingLeft, at[1].toFloat() + view.paddingTop)
                // Read-only: no selection/copy, focus request, activation or extra raster capture.
                Action(view, entry.id, entry.start, entry.end, origin,
                    entry.bounds.map { RectF(it).apply { offset(origin.x, origin.y) } }, identity)
            }
            val wideInk = wideAction.rectangles.single()
            val outsideSource = blue(wideInk) { it.y < wideCell.top - 14f }
            compose.runOnIdle { viewport.value = 639.0 }
            compose.waitForIdle()
            ready(failures)
            compose.runOnIdle {
                assertSame("Fresh clip setup keeps the same TABLE owner", native, focusView())
                assertFalse("Padding-clip probes start without native TABLE focus", native.isFocused)
                assertFalse("Padding-clip probes start without source TABLE focus", native.owner.isFocused)
            }
            // Direct source geometry is unclipped; the actual ancestor applies the R padding-edge clip.
            scroll(-10_000f)
            val current = action(glyph); val contentBox = box(content()); val frame = box(source())
            assertSame("The wide raw witness and clipped action share their real native view", wideAction.view, current.view)
            assertEquals("The independent clip scenario retains the original action range and identity",
                listOf(wideAction.id, wideAction.start, wideAction.end, wideAction.identity),
                listOf(current.id, current.start, current.end, current.identity))
            val padding = RectF(frame).apply { inset(2f, 2f) }
            val currentInk = current.rectangles.single()
            assertEquals(wideInk.width(), currentInk.width(), .05f); assertEquals(wideInk.height(), currentInk.height(), .05f)
            val kept = blue(currentInk) { it.y > padding.top + 1f && it.y < contentBox.top - 1f && it.x > contentBox.left + 1f && it.x < padding.right - 1f }
            val dx = currentInk.left - wideInk.left; val dy = currentInk.top - wideInk.top
            // This fixture has integer density, edges and pan: the preclip pixel witness
            // moves by complete pixels, unlike an unproved fractional-raster correspondence.
            assertEquals(floor(dx), dx, .001f); assertEquals(floor(dy), dy, .001f)
            val cut = Offset(outsideSource.x + dx, outsideSource.y + dy)
            assertTrue(currentInk.contains(cut.x, cut.y)); assertTrue(cut.y < padding.top - 1f)
            assertNotEquals(0x0000ff, color(pixels(), cut))
            compose.runOnIdle {
                val geometry = checkNotNull(current.view.currentMeasuredGeometry)
                assertTrue(actionNode(current.view, glyph.text).contains(cut.x - current.origin.x, cut.y - current.origin.y))
                val info = checkNotNull(current.view.accessibilityNodeProvider.createAccessibilityNodeInfo(current.id))
                try {
                    assertEquals(glyph.text, info.text.toString())
                    val expected = RectF(currentInk); assertTrue(expected.intersect(padding))
                    val screen = IntArray(2).also(compose.activity.window.decorView::getLocationOnScreen)
                    val window = IntArray(2).also(compose.activity.window.decorView::getLocationInWindow)
                    expected.offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat())
                    val rounded = Rect(); expected.roundOut(rounded)
                    val actual = Rect(); info.getBoundsInScreen(actual); assertEquals(rounded, actual)
                    assertTrue(geometry.characterRects(current.start, current.end - current.start).all { it != null })
                } finally { info.recycle() }
            }
            tap(current, cut, actions, false); tap(current, kept, actions, true)
            compose.runOnIdle { assertEquals(EntryLink("Intrinsic-glyph", targetFragment = "source"), actions.last()) }
            // Child A gets its own actual virtual focus/keyboard activation, never the TABLE's focus.
            compose.runOnIdle {
                val count = actions.size
                assertTrue(current.view.accessibilityNodeProvider.performAction(current.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(current.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                assertTrue(current.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER)))
                assertEquals(count + 1, actions.size)
                assertEquals(EntryLink("Intrinsic-glyph", targetFragment = "source"), actions.last())
                assertFalse(native.isFocused)
            }
            compose.waitForIdle()
            val childFocusedOffset = checkNotNull(axis()).value()
            for (rootWidth in listOf(640.0, 639.0)) {
                compose.runOnIdle { viewport.value = rootWidth }; compose.waitForIdle(); ready(failures)
                compose.runOnIdle {
                    assertSame(current.view, actionView(glyph.text))
                    val child = actionNode(current.view, glyph.text)
                    assertEquals(current.id, child.id); assertEquals(current.identity, child.missingLinkPaint!!.actionIdentity)
                    assertTrue(child.missingLinkPaint!!.focused); assertFalse(native.isFocused)
                }
            }
            assertEquals(childFocusedOffset, checkNotNull(axis()).value(), 0f)
            // A larger C really removes overflow: this source grid's fixed intrinsic minimum is220.
            compose.runOnIdle { width.value = 300 }; compose.waitForIdle(); ready(failures)
            assertNull(axis()); assertNull(source().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
            assertTrue(sourceAction(1, AccessibilityNodeInfo.ACTION_FOCUS))
            compose.runOnIdle {
                assertSame(native, focusView()); assertEquals(0f, native.owner.overflow, 0f)
                assertEquals(0f, native.owner.physicalOffset, 0f)
            }
            val noRangeBounds = listOf(box(source()), box(content()), box(grid(0)), box(cell(0, 0)))
            assertFalse(key(native, KeyEvent.KEYCODE_MOVE_END)); assertFalse(key(native, KeyEvent.KEYCODE_DPAD_LEFT))
            assertEquals(noRangeBounds, listOf(box(source()), box(content()), box(grid(0)), box(cell(0, 0))))
            compose.runOnIdle { width.value = 160 }; compose.waitForIdle(); ready(failures)
            // The existing RTL scroll coordinate clamps to zero when its range disappears;
            // with range restored that origin is the physical right end, not an invented LTR origin.
            assertEquals(checkNotNull(axis()).maxValue(), checkNotNull(axis()).value(), 0f)
            assertEquals(box(content()).left - checkNotNull(axis()).value(), box(grid(0)).left, .05f)
        }
    }
}
