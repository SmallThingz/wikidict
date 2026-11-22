package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect as ComposeRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.floor

/** Typed synthetic controls: source-shaped corners/colors/padding, not a compiled MG acceptance. */
class TableCornerRadiiDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private lateinit var activity: MainActivity
    private val actions = mutableListOf<EntryLink>()
    private val body = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.SansSerif, letterSpacing = 0.sp)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun edges(value: StyleLength) = StyleEdges(value, value, value, value)
    private val radii = TableCornerRadii(px(8f), px(8f), px(8f), px(0f))
    private val firstLabel = "MMMMMMMMMMMM"
    private val lastLabel = "Last action"
    private fun cell(label: String, background: String? = null) = Cell(
        listOf(Span("link", label, label, fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx)),
        false, 1, 1, background = background, style = CellStyle(border = StyleBorder.None,
            padding = edges(px(0f)), textAlign = CellTextAlign.Left, minWidth = px(120f),
            lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(20f, FontScaleBasis.CssPx)),
                CellTextStrut(12f, FontScaleBasis.CssPx))))
    private fun sourceStyle(corners: Boolean, padding: StyleLength = em(.1f)) = TableStyle(
        background = "#f5f4aa", border = StyleBorder.Solid(px(1f), "#bca674"),
        collapse = TableCollapse.Separate, padding = edges(padding),
        margins = StyleEdges(px(0f), px(0f), em(.5f), px(0f)),
        width = StyleWidth(StyleWidthUnit.Percent, 100f), cornerRadii = radii.takeIf { corners })
    private fun fixture(corners: Boolean = true, viewport: Boolean = false,
        padding: StyleLength = em(.1f), firstBackground: String? = null): Table {
        val style = sourceStyle(corners, padding)
        val policy = if (!viewport) null else TableBlockViewport(639,
            style.copy(collapse = null, margins = null,
                marginValues = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
                    ContainerMargin.Length(em(.5f)), ContainerMargin.Auto),
                containingDirection = TableContainingDirection.Ltr),
            // The fixed cap is a synthetic overflow premise, independent of the document
            // viewport and the MG-like source corner/color/padding declarations.
            ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Px, 154f),
            TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Ltr, "mg")
        return Table(emptyList(), listOf(listOf(cell(firstLabel, firstBackground), cell(lastLabel, "#0000ff"))),
            style = style, blockViewport = policy)
    }
    @Composable private fun Scene(value: Table, viewport: Double = 900.0, width: Int = 280) {
        CompositionLocalProvider(LocalDensity provides Density(1f), LocalTableDocumentViewportCssWidth provides viewport) {
            MaterialTheme(typography = Typography(bodyLarge = body), colorScheme = lightColorScheme(
                primary = Color.Black, surface = Color.White, background = Color.White,
                onSurface = Color.Black, onSurfaceVariant = Color.Black)) {
                Box(Modifier.width(width.dp).background(Color.White).testTag("corner-host")) {
                    NativeFloatBlockContext(listOf(Block("table", 0, emptyList(), table = value),
                        Block("paragraph", 0, listOf(Span("link", "Following", "Following")))),
                        { actions += it }, "corner-control", Modifier, inCell = false,
                        gridPath = "root", gapDp = 0f, trailingGap = false)
                }
            }
        }
    }
    private fun control(content: @Composable () -> Unit, assertions: () -> Unit) {
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> this.activity = activity; activity.setContent(content = content) }
            compose.waitForIdle(); assertions()
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (failure: Throwable) {
                val original = primary
                if (original == null) throw failure
                if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
    private val gridMatcher = SemanticsMatcher("actual table grid") {
        val tag = it.config.getOrNull(SemanticsProperties.TestTag)
        tag == "compiled-table-grid" || tag?.startsWith("compiled-table-grid-") == true
    }
    private fun grid() = compose.onNode(gridMatcher, useUnmergedTree = true)
    private fun border() = compose.onNodeWithTag("compiled-table-block-viewport", useUnmergedTree = true)
    private fun content() = compose.onNodeWithTag("compiled-table-block-content", useUnmergedTree = true)
    private fun cell(index: Int) = compose.onNodeWithTag("compiled-table-cell-root/block-0-$index", useUnmergedTree = true)
    private fun bounds(node: SemanticsNodeInteraction): ComposeRect = node.getUnclippedBoundsInRoot().let {
        ComposeRect(it.left.value, it.top.value, it.right.value, it.bottom.value)
    }
    private fun ready() {
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
    }
    private fun rgb(image: PixelMap, x: Float, y: Float): Int {
        val value = image[floor(x).toInt(), floor(y).toInt()]
        return (value.red * 255f + .5f).toInt().shl(16) or (value.green * 255f + .5f).toInt().shl(8) or
            (value.blue * 255f + .5f).toInt()
    }
    private fun image() = compose.onRoot().captureToImage().toPixelMap()
    private fun assertCorners(box: ComposeRect, rounded: Boolean) {
        val pixels = image()
        assertEquals(if (rounded) 0xffffff else 0xf5f4aa, rgb(pixels, box.left + 1.5f, box.top + 1.5f))
        assertEquals(if (rounded) 0xffffff else 0xf5f4aa, rgb(pixels, box.right - 1.5f, box.top + 1.5f))
        assertEquals(if (rounded) 0xffffff else 0xf5f4aa, rgb(pixels, box.right - 1.5f, box.bottom - 1.5f))
        assertEquals(0xbca674, rgb(pixels, box.left + .5f, box.bottom - .5f))
        assertEquals(0xf5f4aa, rgb(pixels, box.left + 2.5f, box.bottom - 2.5f))
    }
    private fun owner(label: String): NativeFloatTextView {
        val matches = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown &&
                view.currentMeasuredGeometry?.nodes?.any { it.label?.toString() == label && it.onClick != null } == true) matches += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(activity.window.decorView)
        return matches.single()
    }
    private data class Target(val view: NativeFloatTextView, val id: Int, val start: Int, val end: Int,
        val rects: List<RectF>, val origin: Offset, val screen: Rect)
    private fun target(label: String): Target = compose.runOnIdle {
        val view = owner(label); val geometry = checkNotNull(view.currentMeasuredGeometry)
        val node = geometry.nodes.single { it.label?.toString() == label && it.onClick != null }
        assertEquals(label, geometry.text.subSequence(node.start, node.end).toString())
        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
        assertEquals(label, info.text?.toString()); assertTrue(info.isClickable)
        val screen = Rect(); info.getBoundsInScreen(screen)
        val location = IntArray(2); view.getLocationOnScreen(location)
        Target(view, node.id, node.start, node.end, node.bounds.map(::RectF),
            Offset(location[0].toFloat() + view.paddingLeft, location[1].toFloat() + view.paddingTop), screen)
    }
    private fun tap(point: Offset) {
        val root = compose.onRoot().fetchSemanticsNode().positionOnScreen
        compose.onRoot().performTouchInput { click(point - root) }
    }
    private fun activate(label: String) {
        val target = target(label)
        assertFalse(target.screen.isEmpty)
        compose.runOnIdle {
            target.view.setSelection(target.start, target.end)
            assertEquals(label, target.view.selectedTextForCopy())
            target.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
            val info = checkNotNull(target.view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
            assertTrue(info.isVisibleToUser)
        }
        val count = actions.size
        tap(Offset(target.screen.exactCenterX(), target.screen.exactCenterY()))
        compose.runOnIdle { assertEquals(count + 1, actions.size); assertEquals(EntryLink(label), actions.last()) }
    }
    private fun outsideCornerPoint(actual: Target, frame: ComposeRect, oldContent: ComposeRect, rootScreen: Offset): Offset =
        actual.rects.asSequence().flatMap { rect ->
            sequenceOf(.25f, .75f, 1.25f, 1.75f).flatMap { dx -> sequenceOf(.25f, .75f, 1.25f, 1.75f).map { dy ->
                Offset(actual.origin.x + rect.left + dx, actual.origin.y + rect.top + dy)
            } }
        }.firstOrNull { screen ->
            val p = screen - rootScreen
            val dx = p.x - (frame.left + 8f); val dy = p.y - (frame.top + 8f)
            // Keep the entire sampled pixel outside the padding arc. The outer
            // border may still paint here, so its actual baseline color is retained.
            val pixelDx = floor(p.x) + 1f - (frame.left + 8f)
            val pixelDy = floor(p.y) + 1f - (frame.top + 8f)
            oldContent.contains(p) && p.x < frame.left + 8f && p.y < frame.top + 8f &&
                dx * dx + dy * dy > 49f && pixelDx * pixelDx + pixelDy * pixelDy > 49f &&
                actual.rects.any { it.contains(screen.x - actual.origin.x, screen.y - actual.origin.y) }
        } ?: error("The zero-padding fixture must expose a live raw link rectangle outside the 7px padding arc")

    @Test fun ordinarySourceShapedCornersPreserveAllocationActionsAndActualCellBackgrounds() {
        val rounded = mutableStateOf(false)
        val noPadding = mutableStateOf(false)
        val authoredFirst = mutableStateOf(false)
        control({ Scene(fixture(rounded.value, padding = if (noPadding.value) px(0f) else em(.1f),
            firstBackground = "#0000ff".takeIf { authoredFirst.value })) }) {
            ready()
            val originalGrid = bounds(grid()); val originalCells = listOf(bounds(cell(0)), bounds(cell(1)))
            val originalFollowing = target("Following").screen
            assertCorners(originalGrid, false)
            for (enabled in listOf(true, false, true)) {
                compose.runOnIdle { rounded.value = enabled }; compose.waitForIdle(); ready()
                assertEquals(originalGrid, bounds(grid()))
                assertEquals(originalCells, listOf(bounds(cell(0)), bounds(cell(1))))
                assertEquals(originalFollowing, target("Following").screen)
                assertCorners(bounds(grid()), enabled)
                val blue = bounds(cell(1))
                assertEquals(0x0000ff, rgb(image(), blue.center.x, blue.bottom - 2f))
                activate(firstLabel); activate(lastLabel); activate("Following")
            }
            // A radius is decoration, not an implicit ordinary-table content clip. This
            // explicit zero-padding control deliberately puts real blue cell paint in the arc.
            compose.runOnIdle { noPadding.value = true; authoredFirst.value = true }
            compose.waitForIdle(); ready()
            val box = bounds(grid())
            assertEquals(0x0000ff, rgb(image(), box.left + 1.5f, box.top + 1.5f))
            activate(firstLabel)
        }
    }

    @Test fun theSameTableOwnsWideAndNarrowDecorationWhileNarrowScrollKeepsBodySelectionHitAndAx() {
        val viewport = mutableStateOf(639.5)
        val value = fixture(viewport = true)
        val corners = mutableStateOf(true)
        val plain = value.copy(style = value.style!!.copy(cornerRadii = null),
            blockViewport = value.blockViewport!!.copy(boxStyle = value.blockViewport.boxStyle.copy(cornerRadii = null)))
        control({ Scene(if (corners.value) value else plain, viewport.value, width = 280) }) {
            val sourceRows = value.rows
            var checkedNarrowParity = false
            for (css in listOf(639.5, 639.0, 639.5, 639.0)) {
                compose.runOnIdle { viewport.value = css }; compose.waitForIdle(); ready()
                assertSame(sourceRows, value.rows)
                assertEquals(listOf(firstLabel, lastLabel), value.rows.single().map { it.spans.single().text })
                val box = if (css <= 639.0) bounds(border()) else bounds(grid())
                assertCorners(box, true)
                if (css <= 639.0) {
                    val axis = content().fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
                    assertTrue(axis.maxValue() > 0f)
                    if (!checkedNarrowParity) {
                        val positions = listOf(bounds(border()), bounds(grid()), bounds(cell(0)), bounds(cell(1)))
                        val overflow = axis.maxValue()
                        compose.runOnIdle { corners.value = false }; compose.waitForIdle(); ready()
                        assertEquals(positions, listOf(bounds(border()), bounds(grid()), bounds(cell(0)), bounds(cell(1))))
                        assertEquals(overflow, content().fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].maxValue(), 0f)
                        assertCorners(bounds(border()), false)
                        compose.runOnIdle { corners.value = true }; compose.waitForIdle(); ready()
                        assertEquals(positions, listOf(bounds(border()), bounds(grid()), bounds(cell(0)), bounds(cell(1))))
                        checkedNarrowParity = true
                    }
                    activate(firstLabel)
                    content().performSemanticsAction(SemanticsActions.ScrollBy) { it(axis.maxValue(), 0f) }
                    compose.waitForIdle(); ready(); activate(lastLabel)
                    val right = target(lastLabel).screen
                    val rootScreen = compose.onRoot().fetchSemanticsNode().positionOnScreen
                    val clip = bounds(content())
                    assertTrue(right.left >= floor(rootScreen.x + clip.left).toInt())
                    assertTrue(right.right <= kotlin.math.ceil(rootScreen.x + clip.right).toInt())
                    val blue = image()
                    assertEquals(0x0000ff, rgb(blue, clip.right - 3f, clip.top + clip.height / 2f))
                } else {
                    border().assertDoesNotExist(); content().assertDoesNotExist()
                    activate(firstLabel)
                }
            }
        }
    }

    @Test fun actualNarrowCornerClipRejectsAnOtherwiseLiveLinkAndClipsItsSelectionPaint() {
        val value = fixture(viewport = true, padding = px(0f), firstBackground = "#0000ff")
        val viewport = mutableStateOf(639.5)
        control({ Scene(value, viewport.value, width = 280) }) {
            ready()
            val wideFrame = bounds(grid())
            val wideTarget = target(firstLabel)
            val rootScreen = compose.onRoot().fetchSemanticsNode().positionOnScreen
            val wideCandidate = outsideCornerPoint(wideTarget, wideFrame,
                ComposeRect(wideFrame.left + 1f, wideFrame.top + 1f, wideFrame.right - 1f, wideFrame.bottom - 1f), rootScreen)
            val wideCount = actions.size
            tap(wideCandidate)
            compose.runOnIdle { assertEquals(wideCount + 1, actions.size); assertEquals(EntryLink(firstLabel), actions.last()) }
            compose.runOnIdle { viewport.value = 639.0 }; compose.waitForIdle(); ready()
            val frame = bounds(border())
            val actual = target(firstLabel)
            val oldContent = bounds(content())
            val candidate = outsideCornerPoint(actual, frame, oldContent, rootScreen)
            val pixel = candidate - rootScreen
            val before = image()
            val excludedColor = rgb(before, pixel.x, pixel.y)
            assertNotEquals("Authored blue cell paint must be clipped outside the padding arc", 0x0000ff, excludedColor)
            val count = actions.size
            tap(candidate)
            compose.runOnIdle { assertEquals(count, actions.size) }
            compose.runOnIdle {
                actual.view.setSelection(actual.start, actual.end)
                assertEquals(firstLabel, actual.view.selectedTextForCopy())
            }
            compose.waitForIdle()
            val selected = image()
            assertEquals(excludedColor, rgb(selected, pixel.x, pixel.y))
            var highlighted = false
            val clip = bounds(content())
            for (y in (clip.top + 8f).toInt() until minOf((clip.top + 18f).toInt(), selected.height))
                for (x in (clip.left + 10f).toInt() until minOf((clip.left + 50f).toInt(), selected.width))
                    if (selected[x, y] != before[x, y]) highlighted = true
            assertTrue("The visible part of the original selection must still paint", highlighted)
            compose.runOnIdle {
                actual.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
                val info = checkNotNull(actual.view.accessibilityNodeProvider.createAccessibilityNodeInfo(actual.id))
                assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                assertEquals(firstLabel, info.text?.toString())
                assertTrue(actual.view.accessibilityNodeProvider.performAction(actual.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            }
            compose.runOnIdle { assertEquals(count + 1, actions.size); assertEquals(EntryLink(firstLabel), actions.last()) }
            activate(firstLabel)
            compose.runOnIdle { viewport.value = 639.5 }; compose.waitForIdle(); ready()
            val restored = bounds(grid())
            val restoredPoint = outsideCornerPoint(target(firstLabel), restored,
                ComposeRect(restored.left + 1f, restored.top + 1f, restored.right - 1f, restored.bottom - 1f), rootScreen)
            val restoredCount = actions.size
            tap(restoredPoint)
            compose.runOnIdle { assertEquals(restoredCount + 1, actions.size); assertEquals(EntryLink(firstLabel), actions.last()) }
        }
    }
    @Test fun numericCornerViewportRetainsSeparateSourceGridAndDefaultCellPaddingAcrossBreakpoint() {
        // Synthetic API06 constructor policy, not compiled MG source proof. The containing
        // wide containing direction is LTR, narrow containing direction is independently
        // RTL, and the original grid and link text remain LTR.
        val viewport = mutableStateOf(639.5)
        val labels = listOf("Q first", "Q last")
        val sourceCells = labels.mapIndexed { index, label ->
            val original = cell(label, if (index == 1) "#0000ff" else null)
            original.copy(style = original.style!!.copy(padding = null))
        }
        val margins = StyleEdges(px(4f), px(0f), em(.5f), px(0f))
        val style = sourceStyle(true).copy(margins = margins, containingDirection = TableContainingDirection.Ltr)
        val value = Table(emptyList(), listOf(sourceCells),
            geometry = TableGeometry(cellSpacing = 2, cellPadding = 1), style = style,
            blockViewport = TableBlockViewport(639, style.copy(collapse = null,
                containingDirection = TableContainingDirection.Rtl),
                ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
                TableStyle(collapse = TableCollapse.Separate), TableContainingDirection.Ltr, "mg",
                focusPaint = TableScrollFocusPaint(TableScrollFocusMode.UaAuto)))
        val selected = mutableStateOf(value)
        val failures = mutableListOf<String>()
        val sourceRows = value.rows
        val sourceSpans = sourceCells.map { it.spans }
        control({
            CompositionLocalProvider(LocalDensity provides Density(1f),
                LocalNativeFloatContextFailureObserver provides { failures += it }) {
                // The existing 280px containing block has room to paint its genuine -6px
                // RTL overconstraint. This is not an extra source margin or layout spacer.
                Box(Modifier.width(300.dp).background(Color.White), contentAlignment = androidx.compose.ui.Alignment.TopCenter) {
                    Scene(selected.value, viewport.value, width = 280)
                }
            }
        }) {
            fun sourceTable() = compose.onNodeWithTag("compiled-table-scroll-focus", useUnmergedTree = true)
            // Called only from runOnIdle: inspect real native views and the existing Compose
            // provider, without inventing a source TABLE label or a second AX owner.
            fun shownViews(): List<View> {
                val result = mutableListOf<View>()
                fun visit(view: View) {
                    if (view.isShown) result += view
                    if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                }
                visit(activity.window.decorView)
                return result
            }
            fun nativeFocus() = shownViews().filterIsInstance<NativeTableScrollFocusView>().single()
            fun sourceAx(action: Int? = null, focused: Boolean? = null, focusable: Boolean? = null): Boolean {
                val id = sourceTable().fetchSemanticsNode().id
                return compose.runOnIdle {
                    val matches = shownViews().mapNotNull { view ->
                        val provider = view.accessibilityNodeProvider ?: return@mapNotNull null
                        val info = provider.createAccessibilityNodeInfo(id) ?: return@mapNotNull null
                        if (info.collectionInfo?.rowCount == 1 && info.collectionInfo?.columnCount == 2) provider to info
                        else { info.recycle(); null }
                    }
                    assertEquals("One source TABLE accessibility owner", 1, matches.size)
                    val (provider, info) = matches.single()
                    try {
                        focused?.let { assertEquals(it, info.isFocused) }
                        focusable?.let { assertEquals(it, info.isFocusable) }
                        assertTrue(info.isVisibleToUser)
                        assertFalse(info.isClickable)
                        assertFalse(info.isScrollable)
                        val ids = info.actionList.map { it.id }
                        assertFalse(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id in ids)
                        assertFalse(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id in ids)
                        if (action == null) true else provider.performAction(id, action, null)
                    } finally { info.recycle() }
                }
            }
            fun focusPixels(): IntArray {
                val pixels = image()
                return IntArray(pixels.width * pixels.height) { index ->
                    rgb(pixels, (index % pixels.width) + .5f, (index / pixels.width) + .5f)
                }
            }
            fun focusBounds() = listOf(bounds(sourceTable()), bounds(content()), bounds(grid())) +
                listOf(bounds(cell(0)), bounds(cell(1)))
            fun focusBodyHost() {
                compose.runOnIdle {
                    val view = owner("Following")
                    assertTrue(view.accessibilityNodeProvider.performAction(View.NO_ID,
                        AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                    assertTrue(view.requestFocus())
                }
                compose.waitForIdle()
            }
            fun sourceKey(native: NativeTableScrollFocusView, code: Int): Boolean {
                val accepted = compose.runOnIdle {
                    assertPhysicalActivity(activity); check(activity.hasWindowFocus())
                    val down = native.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                    native.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                    down
                }
                compose.waitForIdle()
                return accepted
            }
            var wideFrame: ComposeRect? = null
            var wideCells: List<ComposeRect>? = null
            var wideFollowing: Rect? = null
            for (css in listOf(639.5, 639.0, 640.0)) {
                compose.runOnIdle { assertSame(value, selected.value); viewport.value = css }
                compose.waitForIdle(); ready()
                focusBodyHost()
                assertSame(sourceRows, value.rows)
                sourceCells.indices.forEach { index ->
                    assertSame(sourceCells[index], value.rows.single()[index])
                    assertSame(sourceSpans[index], value.rows.single()[index].spans)
                    assertNull(value.rows.single()[index].style!!.padding)
                }
                assertEquals(TableGeometry(cellSpacing = 2, cellPadding = 1), value.geometry)
                assertEquals(TableContainingDirection.Rtl, value.blockViewport!!.boxStyle.containingDirection)
                assertEquals(TableContainingDirection.Ltr, value.blockViewport.gridDirection)
                assertEquals(TableContainingDirection.Ltr, value.style!!.containingDirection)
                assertNull(value.floatViewport)
                val narrow = css <= 639.0
                val host = bounds(compose.onNodeWithTag("corner-host", useUnmergedTree = true))
                val gridBox = bounds(grid())
                val frame = bounds(sourceTable())
                val cells = listOf(bounds(cell(0)), bounds(cell(1)))
                val rootScreen = compose.onRoot().fetchSemanticsNode().positionOnScreen
                val following = target("Following")
                // Numeric top margin belongs to the outer owner, not to grid spacing.
                assertEquals(host.top + 4f, frame.top, .01f)
                assertEquals(32f, frame.height, .01f) // 20px source line + 2px cell padding + 4px spacing + 6px outer edges.
                cells.forEach { assertEquals(22f, it.height, .01f) }
                assertEquals(cells[0].top, cells[1].top, .01f)
                assertEquals(2f, cells[1].left - cells[0].right, .01f)
                assertEquals(if (narrow) 2f else 5f, cells[0].left - gridBox.left, .01f)
                assertEquals(if (narrow) 2f else 5f, gridBox.right - cells[1].right, .01f)
                assertEquals(if (narrow) 2f else 5f, cells[0].top - gridBox.top, .01f)
                if (narrow) {
                    // width/max-width100% remain content-box percentages of the original C280.
                    // The 6px border/padding excess goes to physical left for containing RTL.
                    assertEquals(286f, frame.width, .01f)
                    assertEquals(host.left - 6f, frame.left, .01f)
                    val viewportBox = bounds(content())
                    assertEquals(280f, viewportBox.width, .01f)
                    assertEquals(frame.left + 3f, viewportBox.left, .01f)
                    assertEquals(frame.top + 3f, viewportBox.top, .01f)
                    // The separate anonymous grid has only its own 2px spacing and 1px
                    // default cell padding. Its two 120px minimum content boxes fit in C.
                    assertEquals(250f, gridBox.width, .01f)
                    assertEquals(26f, gridBox.height, .01f)
                    assertEquals(viewportBox.left, gridBox.left, .01f)
                    assertEquals(viewportBox.top, gridBox.top, .01f)
                    cells.forEach { assertEquals(122f, it.width, .01f) }
                    assertNull(content().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
                    assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
                    assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
                    compose.runOnIdle { assertEquals(0f, nativeFocus().owner.overflow, 0f) }
                    // No anonymous outer border/background is copied into its spacing strip.
                    assertEquals(0xf5f4aa, rgb(image(), gridBox.left + 10.5f, gridBox.top + .5f))
                } else {
                    content().assertExists()
                    assertEquals(280f, frame.width, .01f)
                    assertEquals(host.left, frame.left, .01f)
                    if (wideFrame == null) {
                        wideFrame = frame; wideCells = cells; wideFollowing = Rect(following.screen)
                    } else {
                        assertEquals(wideFrame, frame)
                        assertEquals(wideCells, cells)
                        assertEquals(wideFollowing, following.screen)
                    }
                }
                border().assertDoesNotExist()
                assertCorners(frame, true)
                val pixels = image()
                assertEquals(0xf5f4aa, rgb(pixels, (cells[0].right + cells[1].left) / 2f, cells[0].center.y))
                assertEquals(0x0000ff, rgb(pixels, cells[1].center.x, cells[1].bottom - .5f))
                labels.forEachIndexed { index, label ->
                    val originalAction = target(label)
                    // Selection/AX starts at the true text owner after exactly one default
                    // padding pixel, independent of border padding and current grid width.
                    assertEquals(rootScreen.x + cells[index].left + 1f,
                        originalAction.screen.left.toFloat(), 1f)
                    activate(label)
                }
                activate("Following")
            }
            // Cancel the unchanged following text's own font/baseline offset. Changing
            // only the numeric bottom margin must move that same text up exactly .5em.
            val beforeFrame = bounds(grid())
            val beforeCells = listOf(bounds(cell(0)), bounds(cell(1)))
            val beforeFollowing = Rect(target("Following").screen)
            val noBottom = margins.copy(bottom = px(0f))
            val withoutBottom = value.copy(style = style.copy(margins = noBottom),
                blockViewport = value.blockViewport!!.copy(
                    boxStyle = value.blockViewport.boxStyle.copy(margins = noBottom)))
            assertSame(sourceRows, withoutBottom.rows)
            compose.runOnIdle { selected.value = withoutBottom }
            compose.waitForIdle(); ready()
            assertEquals(beforeFrame, bounds(grid()))
            assertEquals(beforeCells, listOf(bounds(cell(0)), bounds(cell(1))))
            val shiftedFollowing = Rect(beforeFollowing).apply { offset(0, -10) }
            assertEquals(shiftedFollowing, target("Following").screen)
            compose.runOnIdle {
                assertEquals(List(3) { labels.map { EntryLink(it) } + EntryLink("Following") }.flatten(), actions)
            }

            val policies = listOf(TableScrollFocusPaint(TableScrollFocusMode.UaAuto),
                TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone),
                TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#cc00cc")))
            var previousNative: NativeTableScrollFocusView? = null
            for (policy in policies) {
                val focusedTable = value.copy(blockViewport = value.blockViewport!!.copy(focusPaint = policy))
                assertSame(sourceRows, focusedTable.rows)
                compose.runOnIdle { selected.value = focusedTable; viewport.value = 639.0 }
                compose.waitForIdle(); ready()
                val sourceId = sourceTable().fetchSemanticsNode().id
                val native = compose.runOnIdle { nativeFocus() }
                val callbackCount = compose.runOnIdle { actions.size }
                compose.runOnIdle {
                    previousNative?.let { assertNotSame(it, native) }
                    assertEquals(policy, native.owner.policy)
                    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, native.importantForAccessibility)
                    assertEquals(policy.mode == TableScrollFocusMode.UaAuto, native.defaultFocusHighlightEnabled)
                    assertTrue(native.owner.canAcquireFocus); assertFalse(native.owner.canScroll)
                    assertEquals(0f, native.owner.overflow, 0f)
                }
                previousNative = native
                focusBodyHost()
                val unfocused = focusPixels()
                val beforeFocus = focusBounds()
                val followingBeforeFocus = Rect(target("Following").screen)
                val actionRanges = labels.map { label -> target(label).let { Triple(it.start, it.end, Rect(it.screen)) } }
                assertTrue(sourceAx(AccessibilityNodeInfo.ACTION_FOCUS))
                compose.waitForIdle()
                compose.runOnIdle { assertTrue(native.isFocused); assertTrue(native.owner.isFocused) }
                sourceAx(focused = true, focusable = true)
                assertEquals(true, sourceTable().fetchSemanticsNode().config[SemanticsProperties.Focused])
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
                if (policy.mode == TableScrollFocusMode.UaAuto) {
                    // Public Android UA focus paint has no source RGB setter. Retain the
                    // requested color above, but observe the actual platform highlight.
                    compose.waitUntil(5_000) { !unfocused.contentEquals(focusPixels()) }
                } else assertArrayEquals("Authored none suppresses source TABLE highlight", unfocused, focusPixels())
                assertEquals(beforeFocus, focusBounds())
                assertEquals(followingBeforeFocus, target("Following").screen)
                labels.forEachIndexed { index, label ->
                    val action = target(label)
                    assertEquals(actionRanges[index], Triple(action.start, action.end, Rect(action.screen)))
                }
                assertTrue(sourceAx(AccessibilityNodeInfo.ACTION_CLEAR_FOCUS))
                compose.waitForIdle()
                compose.runOnIdle {
                    assertFalse(native.isFocused); assertFalse(native.owner.isFocused)
                    // The real keyboard focus path remains eligible after an actual AX clear.
                    assertTrue(native.requestFocus(View.FOCUS_FORWARD))
                }
                compose.waitForIdle(); sourceAx(focused = true, focusable = true)
                assertFalse(sourceKey(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                assertFalse(sourceKey(native, KeyEvent.KEYCODE_MOVE_END))
                assertEquals(beforeFocus, focusBounds())
                compose.runOnIdle { assertEquals(0f, native.owner.physicalOffset, 0f); assertEquals(callbackCount, actions.size) }

                // Same source TABLE and actual native focus owner survive both states.
                // Wide removes acquisition, movement and paint without focusing another A.
                compose.runOnIdle { viewport.value = 640.0 }
                compose.waitForIdle(); ready()
                assertEquals(sourceId, sourceTable().fetchSemanticsNode().id)
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.RequestFocus))
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
                assertNull(sourceTable().fetchSemanticsNode().config.getOrNull(SemanticsActions.ScrollBy))
                compose.runOnIdle {
                    assertSame(native, nativeFocus()); assertTrue(native.isFocused)
                    assertEquals(NativeTableFocusTransfer.RetainedForWide, native.owner.lastTransfer)
                    assertFalse(native.owner.requestSourceFocus())
                    val eligible = arrayListOf<View>()
                    native.addFocusables(eligible, View.FOCUS_FORWARD, View.FOCUSABLES_ALL)
                    assertFalse(native in eligible)
                }
                assertFalse(sourceKey(native, KeyEvent.KEYCODE_DPAD_RIGHT))
                val wideFocusedPixels = focusPixels(); val wideFocusedBounds = focusBounds()
                focusBodyHost()
                assertArrayEquals("Wide suppresses source TABLE focus paint", wideFocusedPixels, focusPixels())
                assertEquals(wideFocusedBounds, focusBounds())
                compose.runOnIdle { assertFalse(native.isFocused); assertFalse(native.owner.requestSourceFocus()) }
                assertFalse(sourceAx(AccessibilityNodeInfo.ACTION_FOCUS, focused = false, focusable = false))

                compose.runOnIdle { viewport.value = 639.0 }
                compose.waitForIdle(); ready()
                compose.runOnIdle { assertSame(native, nativeFocus()) }
                assertTrue(sourceAx(AccessibilityNodeInfo.ACTION_FOCUS))
                compose.waitForIdle()
                compose.runOnIdle { viewport.value = 640.0 }
                compose.waitForIdle()
                compose.runOnIdle { viewport.value = 639.0 }
                compose.waitForIdle(); ready()
                compose.runOnIdle {
                    assertSame(native, nativeFocus()); assertTrue(native.isFocused)
                    assertEquals(NativeTableFocusTransfer.RestoredForNarrow, native.owner.lastTransfer)
                }
                assertEquals(beforeFocus, focusBounds())

                // TABLE focus leaves the existing child A's own virtual keyboard action,
                // exact source offsets, copy and real touch activation intact.
                val first = target(labels.first())
                compose.runOnIdle {
                    assertTrue(first.view.accessibilityNodeProvider.performAction(first.id,
                        AccessibilityNodeInfo.ACTION_FOCUS, null))
                    assertFalse(native.isFocused)
                    assertTrue(first.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                    assertTrue(first.view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER)))
                    assertEquals(callbackCount + 1, actions.size)
                    assertEquals(EntryLink(labels.first()), actions.last())
                }
                compose.waitForIdle()
                labels.forEach(::activate); activate("Following")
                compose.runOnIdle {
                    assertEquals(listOf(EntryLink(labels.first())) + labels.map { EntryLink(it) } + EntryLink("Following"),
                        actions.drop(callbackCount))
                }
            }

            // A source caption is valid data, but this focus owner has no joined caption
            // projection. Its visible refusal must preserve every original action.
            val captionLabel = "Q caption"
            val withCaption = value.copy(caption = listOf(Span("link", captionLabel, captionLabel)))
            assertSame(sourceRows, withCaption.rows)
            val previousFailures = compose.runOnIdle { failures.size }
            compose.runOnIdle { selected.value = withCaption; viewport.value = 639.0 }
            compose.waitForIdle()
            compose.waitUntil(5_000) { compose.runOnIdle {
                failures.drop(previousFailures).any { it == "Corner-table focus with a caption is unavailable." }
            } }
            compose.onAllNodesWithText("Unable to display this layout.", useUnmergedTree = true)
                .onFirst().assertIsDisplayed()
            compose.runOnIdle {
                assertTrue(shownViews().filterIsInstance<NativeTableScrollFocusView>().none { it.owner.canAcquireFocus })
            }
            for (label in listOf(captionLabel) + labels) {
                val retained = compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                retained.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertEquals(label, layouts.single().layoutInput.text.text)
                val beforeClick = compose.runOnIdle { actions.size }
                compose.runOnIdle { assertPhysicalActivity(activity); check(activity.hasWindowFocus()) }
                retained.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                compose.runOnIdle { assertEquals(beforeClick + 1, actions.size); assertEquals(EntryLink(label), actions.last()) }
            }
            compose.runOnIdle { selected.value = value }
            compose.waitForIdle(); ready()
            compose.runOnIdle { assertTrue(nativeFocus().owner.canAcquireFocus) }
            assertTrue(sourceAx(AccessibilityNodeInfo.ACTION_FOCUS))
            compose.waitForIdle()
            labels.forEach(::activate)

            // A real older rounded viewport is the ancestor, with the same Q TABLE in
            // its cell. Its fractional cap yields an observed fractional paint origin.
            // Compare focus-only pixel changes with square/rounded ancestor corners;
            // the source TABLE's own outline must not become its content clip.
            for (roundedAncestor in listOf(false, true)) {
                val parentRadii = if (roundedAncestor) TableCornerRadii(px(24f), px(24f), px(24f), px(0f))
                    else TableCornerRadii(px(0f), px(0f), px(0f), px(0f))
                val parentTemplate = fixture(viewport = true)
                val nested = Cell(emptyList(), false, 1, 1,
                    blocks = listOf(Block("table", 0, emptyList(), table = value)),
                    style = CellStyle(border = StyleBorder.None, padding = edges(px(0f)), minWidth = px(0f)))
                val ancestor = parentTemplate.copy(rows = listOf(listOf(nested)),
                    style = parentTemplate.style!!.copy(cornerRadii = parentRadii),
                    blockViewport = parentTemplate.blockViewport!!.copy(
                        boxStyle = parentTemplate.blockViewport.boxStyle.copy(cornerRadii = parentRadii),
                        maxWidth = StyleWidth(StyleWidthUnit.Px, 154.25f)))
                assertSame(value, ancestor.rows.single().single().blocks!!.single().table)
                compose.runOnIdle { selected.value = ancestor; viewport.value = 639.0 }
                compose.waitForIdle(); ready(); focusBodyHost()
                val parentFrame = bounds(border())
                assertTrue("The real ancestor has a fractional physical origin",
                    parentFrame.left - floor(parentFrame.left) > .01f)
                assertTrue(parentFrame.width >= 48f && parentFrame.height >= 48f)
                val sourceFrame = bounds(sourceTable())
                val beforeActions = labels.map { target(it).screen }
                val before = focusPixels()
                val rasterWidth = image().width
                assertTrue(sourceAx(AccessibilityNodeInfo.ACTION_FOCUS))
                compose.waitForIdle()
                compose.waitUntil(5_000) { !before.contentEquals(focusPixels()) }
                val after = focusPixels()
                assertEquals(before.size, after.size)
                assertEquals(parentFrame, bounds(border()))
                assertEquals(sourceFrame, bounds(sourceTable()))
                assertEquals(beforeActions, labels.map { target(it).screen })
                var outsideArcChanges = 0
                var insideArcChanges = 0
                for (index in before.indices) if (before[index] != after[index]) {
                    val dx = index % rasterWidth + .5f - parentFrame.left
                    val dy = index / rasterWidth + .5f - parentFrame.top
                    if (dx in 4f..24f && dy in 4f..24f) {
                        // Actual parent radius24 / uniform border1 => inner radius23,
                        // center unchanged. One-pixel guard excludes antialias boundary.
                        val distanceSquared = (dx - 24f) * (dx - 24f) + (dy - 24f) * (dy - 24f)
                        if (distanceSquared > 24f * 24f) outsideArcChanges++
                        if (distanceSquared < 22f * 22f) insideArcChanges++
                    }
                }
                assertTrue("Native UA paint remains visible inside the real ancestor", insideArcChanges > 0)
                if (roundedAncestor) assertEquals("The ancestor's curved clip also clips UA paint", 0, outsideArcChanges)
                else assertTrue("The square contrast exposes the otherwise clipped UA paint", outsideArcChanges > 0)
                labels.forEach(::activate)
            }
        }
    }

    @Test fun numericCornerPaddingClipRetainsRealInkActionsAndPannedImageWithoutChangingLegacyClip() {
        // Synthetic API07 data. The bitmap is controlled local pixels, not an MG asset.
        val glyphLabel = "MMMMMM"
        val imageLabel = "Padding image"
        val glyph = Span("link", glyphLabel, glyphLabel, foreground = "#0000ff",
            fontScale = 48f, fontScaleBasis = FontScaleBasis.CssPx,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
                InlineComputedLength(4f, FontScaleBasis.CssPx)),
                baselineShift = InlineComputedLength(0f, FontScaleBasis.CssPx), wrap = TextWrap.Normal))
        val objectImage = InlineImage("Controlled padding.png", widthPx = 60, heightPx = 24, alt = imageLabel,
            verticalAlign = InlineImageVerticalAlign.Baseline)
        val imageSpan = Span("link", "", imageLabel, image = objectImage)
        val glyphCell = Cell(listOf(glyph), false, 1, 1, style = CellStyle(
            border = StyleBorder.None, padding = edges(px(1f)), textAlign = CellTextAlign.Left,
            lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(4f, FontScaleBasis.CssPx)),
                CellTextStrut(48f, FontScaleBasis.CssPx))))
        val imageCell = Cell(listOf(imageSpan), false, 1, 1, style = CellStyle(
            border = StyleBorder.None, padding = edges(px(1f)), textAlign = CellTextAlign.Left))
        val rows = listOf(listOf(glyphCell), listOf(imageCell))
        val padding = StyleEdges(px(7.25f), px(13.75f), px(11.5f), px(24.5f))
        val sourceStyle = TableStyle(background = "#f5f4aa", border = StyleBorder.Solid(px(2.5f), "#bca674"),
            collapse = TableCollapse.Separate, padding = padding,
            margins = StyleEdges(px(40f), px(0f), px(8f), px(0f)),
            width = StyleWidth(StyleWidthUnit.Percent, 100f), containingDirection = TableContainingDirection.Ltr,
            cornerRadii = TableCornerRadii(px(17.25f), px(13.5f), px(31.75f), px(40.125f)))
        val q = Table(emptyList(), rows, geometry = TableGeometry(cellSpacing = 2, cellPadding = 1), style = sourceStyle,
            blockViewport = TableBlockViewport(639, sourceStyle.copy(collapse = null), ContainerBoxSizing.ContentBox,
                StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Separate),
                TableContainingDirection.Rtl, "mg", TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone)))
        // A valid old auto-margin/collapsed policy is the contrast. Nulling corners on Q
        // would be invalid data. The same real spans and explicit cell padding survive.
        val legacyStyle = sourceStyle.copy(cornerRadii = null, containingDirection = null)
        val legacy = q.copy(geometry = null, style = legacyStyle,
            blockViewport = q.blockViewport!!.copy(boxStyle = legacyStyle.copy(collapse = null, margins = null,
                marginValues = ContainerMargins(ContainerMargin.Length(px(40f)), ContainerMargin.Auto,
                    ContainerMargin.Length(px(8f)), ContainerMargin.Auto), containingDirection = TableContainingDirection.Ltr),
                gridStyle = TableStyle(collapse = TableCollapse.Collapse), gridDirection = TableContainingDirection.Ltr,
                focusPaint = null))
        val selected = mutableStateOf(q)
        val viewport = mutableStateOf(640.0)
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val media = listOf(Media(objectImage.file, "image", ""))
        val bitmap = android.graphics.Bitmap.createBitmap(60, 24, android.graphics.Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.RED)
        }
        var primary: Throwable? = null
        try {
            control({
                val imageOwner = rememberInlineImageViewOwner(listOf(objectImage), media, settings, "mg")
                androidx.compose.runtime.remember(imageOwner) {
                    imageOwner.states[inlineImageAssetKey(objectImage)] = InlineImageAssetState.Ready(
                        DecodedMediaBitmap(bitmap, 60, 24), 60, 24, "image/png", "controlled", "")
                    true
                }
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalInlineImageOwner provides imageOwner) {
                    Box(Modifier.width(400.dp).background(Color.White), contentAlignment = androidx.compose.ui.Alignment.TopCenter) {
                        Scene(selected.value, viewport.value, width = 160)
                    }
                }
            }) {
                data class Ink(val view: NativeFloatTextView, val id: Int, val start: Int, val end: Int,
                    val origin: Offset, val raw: RectF, val text: String)
                fun sourceTable() = compose.onNodeWithTag("compiled-table-scroll-focus", useUnmergedTree = true)
                fun ink(label: String, index: Int): Ink {
                    val cellBox = bounds(cell(index))
                    return compose.runOnIdle {
                        val view = owner(label)
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        val surface = (geometry as NativeSurfaceGeometry).surface
                        val node = geometry.nodes.single { it.label?.toString() == label && it.onClick != null }
                        val origin = Offset(cellBox.left + 1f + surface.left + view.paddingLeft,
                            cellBox.top + 1f + surface.top + view.paddingTop)
                        val raw = RectF(node.bounds.first()).apply { node.bounds.drop(1).forEach(::union); offset(origin.x, origin.y) }
                        val text = geometry.text.subSequence(node.start, node.end).toString()
                        assertEquals(if (index == 0) glyphLabel else "\uFFFC", text)
                        Ink(view, node.id, node.start, node.end, origin, raw, text)
                    }
                }
                fun coloredPoint(color: Int, region: RectF, pixels: PixelMap = image(), allowed: (Offset) -> Boolean): Offset {
                    for (y in maxOf(0, floor(region.top).toInt()) until minOf(pixels.height, kotlin.math.ceil(region.bottom).toInt()))
                        for (x in maxOf(0, floor(region.left).toInt()) until minOf(pixels.width, kotlin.math.ceil(region.right).toInt())) {
                            val point = Offset(x + .5f, y + .5f)
                            if (allowed(point) && rgb(pixels, point.x, point.y) == color) return point
                        }
                    throw AssertionError("The actual source ink does not satisfy the padding-strip premise")
                }
                fun clickInk(ink: Ink, point: Offset, expected: EntryLink, accepted: Boolean) {
                    compose.runOnIdle {
                        assertPhysicalActivity(activity); check(activity.hasWindowFocus())
                        val count = actions.size
                        val time = android.os.SystemClock.uptimeMillis()
                        val x = point.x - ink.origin.x + ink.view.paddingLeft
                        val y = point.y - ink.origin.y + ink.view.paddingTop
                        val down = android.view.MotionEvent.obtain(time, time, android.view.MotionEvent.ACTION_DOWN, x, y, 0)
                        val up = android.view.MotionEvent.obtain(time, time + 10, android.view.MotionEvent.ACTION_UP, x, y, 0)
                        try {
                            assertEquals(accepted, ink.view.dispatchTouchEvent(down))
                            ink.view.dispatchTouchEvent(up)
                        } finally { down.recycle(); up.recycle() }
                        assertEquals(count + if (accepted) 1 else 0, actions.size)
                        if (accepted) assertEquals(expected, actions.last())
                    }
                }
                fun selectionAndAx(ink: Ink, point: Offset, description: Boolean) {
                    val root = compose.onRoot().fetchSemanticsNode().positionOnScreen
                    compose.runOnIdle {
                        ink.view.setSelection(ink.start, ink.end)
                        assertEquals(ink.text, ink.view.selectedTextForCopy())
                        val rectangles = checkNotNull(ink.view.currentMeasuredGeometry).rectsForRange(ink.start, ink.end)
                        assertTrue(rectangles.any { it.contains(point.x - ink.origin.x, point.y - ink.origin.y) })
                        val info = checkNotNull(ink.view.accessibilityNodeProvider.createAccessibilityNodeInfo(ink.id))
                        try {
                            assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                            assertEquals(if (description) imageLabel else glyphLabel,
                                if (description) info.contentDescription?.toString() else info.text?.toString())
                            val screen = Rect(); info.getBoundsInScreen(screen)
                            assertTrue(screen.contains((root.x + point.x).toInt(), (root.y + point.y).toInt()))
                        } finally { info.recycle() }
                        assertTrue(ink.view.accessibilityNodeProvider.performAction(View.NO_ID,
                            AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                    }
                }
                fun physicalPan(amount: Float, isQ: Boolean) {
                    val node = if (isQ) sourceTable() else content()
                    node.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(amount, 0f)) }
                    compose.waitForIdle()
                }
                ready()
                val wideFrame = bounds(sourceTable())
                val wideCells = listOf(bounds(cell(0)), bounds(cell(1)))
                val wideFollowing = Rect(target("Following").screen)
                val wideGlyph = ink(glyphLabel, 0)
                val wideImage = ink(imageLabel, 1)
                assertEquals(60f, wideImage.raw.width(), .01f); assertEquals(24f, wideImage.raw.height(), .01f)
                val widePixels = image()
                val aboveBorder = coloredPoint(0x0000ff, wideGlyph.raw, widePixels) { point ->
                    point.y < wideFrame.top - 1f && (-1..1).all { dx -> (-1..1).all { dy ->
                        point.x + dx >= 0f && point.x + dx < widePixels.width &&
                            point.y + dy >= 0f && point.y + dy < widePixels.height &&
                            rgb(widePixels, point.x + dx, point.y + dy) == 0x0000ff
                    } }
                }
                selectionAndAx(wideGlyph, aboveBorder, false)
                clickInk(wideGlyph, aboveBorder, EntryLink(glyphLabel), true)
                val glyphRelative = RectF(wideGlyph.raw).apply { offset(-wideCells[0].left, -wideCells[0].top) }
                val imageRelative = RectF(wideImage.raw).apply { offset(-wideCells[1].left, -wideCells[1].top) }

                compose.runOnIdle { viewport.value = 639.0 }
                compose.waitForIdle(); ready()
                val axis = sourceTable().fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
                assertFalse(axis.reverseScrolling)
                val initialOffset = compose.runOnIdle { axis.value() }
                assertTrue(initialOffset > 36f) // Source RTL starts at the physical right edge.
                physicalPan(-initialOffset, true)
                compose.runOnIdle { assertEquals(0f, axis.value(), 0f) }
                val narrowFrame = bounds(sourceTable())
                val narrowCells = listOf(bounds(cell(0)), bounds(cell(1)))
                val narrowGlyph = ink(glyphLabel, 0)
                val narrowFollowing = Rect(target("Following").screen)
                wideCells.indices.forEach { index ->
                    assertEquals(wideCells[index].height, narrowCells[index].height, .01f)
                }
                val narrowPreclip = RectF(glyphRelative).apply { offset(narrowCells[0].left, narrowCells[0].top) }
                assertEquals(narrowPreclip, narrowGlyph.raw)
                val translation = Offset(narrowCells[0].left - wideCells[0].left, narrowCells[0].top - wideCells[0].top)
                val narrowContent = bounds(content())
                val retainedGlyph = coloredPoint(0x0000ff, narrowPreclip) {
                    it.y > narrowContent.top - 7.25f + 1f && it.y < narrowContent.top - 1f &&
                        it.x > narrowContent.left + 1f && it.x < narrowContent.right - 1f
                }
                val rejectedGlyph = aboveBorder + translation
                assertTrue(narrowPreclip.contains(retainedGlyph.x, retainedGlyph.y))
                assertTrue(narrowPreclip.contains(rejectedGlyph.x, rejectedGlyph.y))
                assertEquals(0x0000ff, rgb(image(), retainedGlyph.x, retainedGlyph.y))
                assertNotEquals(0x0000ff, rgb(image(), rejectedGlyph.x, rejectedGlyph.y))
                selectionAndAx(narrowGlyph, retainedGlyph, false)
                clickInk(narrowGlyph, retainedGlyph, EntryLink(glyphLabel), true)
                clickInk(narrowGlyph, rejectedGlyph, EntryLink(glyphLabel), false)

                val contentBefore = bounds(content())
                val imageBefore = ink(imageLabel, 1)
                physicalPan(36f, true)
                val imageAfter = ink(imageLabel, 1)
                val cellAfter = bounds(cell(1))
                assertEquals(contentBefore, bounds(content()))
                assertEquals(narrowFrame, bounds(sourceTable()))
                assertEquals(imageBefore.raw.left - 36f, imageAfter.raw.left, .01f)
                val preclipImage = RectF(imageRelative).apply { offset(cellAfter.left, cellAfter.top) }
                assertEquals(preclipImage, imageAfter.raw)
                assertEquals(60f, imageAfter.raw.width(), .01f); assertEquals(24f, imageAfter.raw.height(), .01f)
                val retainedImage = Offset(contentBefore.left - 10f, preclipImage.centerY())
                val rejectedImage = Offset(contentBefore.left - 24.5f - 1.5f, preclipImage.centerY())
                assertTrue(preclipImage.contains(retainedImage.x, retainedImage.y))
                assertTrue(preclipImage.contains(rejectedImage.x, rejectedImage.y))
                assertEquals(0xff0000, rgb(image(), retainedImage.x, retainedImage.y))
                assertNotEquals(0xff0000, rgb(image(), rejectedImage.x, rejectedImage.y))
                selectionAndAx(imageAfter, retainedImage, true)
                clickInk(imageAfter, retainedImage, EntryLink(imageLabel), true)
                clickInk(imageAfter, rejectedImage, EntryLink(imageLabel), false)
                // The expanded rectangular padding area is still intersected with the
                // rounded padding edge. Compute its BL arc independently from the source
                // radii and actual content box, including the one global outer factor.
                val outerWidth = contentBefore.width + 24.5f + 13.75f + 5f
                val outerHeight = contentBefore.height + 7.25f + 11.5f + 5f
                val factor = minOf(1f,
                    minOf(outerWidth / (17.25f + 13.5f), outerWidth / (40.125f + 31.75f)),
                    minOf(outerHeight / (17.25f + 40.125f), outerHeight / (13.5f + 31.75f)))
                val radius = 40.125f * factor
                val innerRadius = maxOf(0f, radius - 2.5f)
                assertTrue(innerRadius > 2f)
                val center = Offset(contentBefore.left - 24.5f - 2.5f + radius,
                    contentBefore.bottom + 11.5f + 2.5f - radius)
                fun inCorner(point: Offset): Boolean = point.x > contentBefore.left - 24.5f + 1f &&
                    point.x < center.x && point.y > center.y && point.y < contentBefore.bottom + 11.5f - 1f
                fun squaredDistance(point: Offset): Float = (point.x - center.x) * (point.x - center.x) +
                    (point.y - center.y) * (point.y - center.y)
                val imageTranslation = Offset(preclipImage.left - wideImage.raw.left, preclipImage.top - wideImage.raw.top)
                val cutArc = coloredPoint(0xff0000, wideImage.raw, widePixels) { source ->
                    val point = source + imageTranslation
                    inCorner(point) && squaredDistance(point) > (innerRadius + 1.5f) * (innerRadius + 1.5f)
                } + imageTranslation
                val keptArc = coloredPoint(0xff0000, preclipImage) { point ->
                    inCorner(point) && squaredDistance(point) < (innerRadius - 1.5f) * (innerRadius - 1.5f)
                }
                assertTrue(preclipImage.contains(cutArc.x, cutArc.y))
                assertTrue(preclipImage.contains(keptArc.x, keptArc.y))
                assertNotEquals(0xff0000, rgb(image(), cutArc.x, cutArc.y))
                selectionAndAx(imageAfter, keptArc, true)
                clickInk(imageAfter, keptArc, EntryLink(imageLabel), true)
                clickInk(imageAfter, cutArc, EntryLink(imageLabel), false)
                assertNull(content().fetchSemanticsNode().config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange))
                // This TABLE owner has no scrollbar/gutter: its one physical axis belongs
                // to the source TABLE; the content origin is unchanged by clipping/pan.
                compose.runOnIdle { assertEquals(36f, axis.value(), 0f) }
                assertEquals(narrowFollowing, target("Following").screen)

                compose.runOnIdle { selected.value = legacy }
                compose.waitForIdle(); ready()
                sourceTable().assertDoesNotExist()
                val legacyContent = bounds(content())
                physicalPan(36f, false)
                val legacyImage = ink(imageLabel, 1)
                val legacyCell = bounds(cell(1))
                val legacyPreclip = RectF(imageRelative).apply { offset(legacyCell.left, legacyCell.top) }
                assertEquals(legacyPreclip, legacyImage.raw)
                val legacyPadding = Offset(legacyContent.left - 10f, legacyPreclip.centerY())
                assertTrue(legacyPreclip.contains(legacyPadding.x, legacyPadding.y))
                assertNotEquals(0xff0000, rgb(image(), legacyPadding.x, legacyPadding.y))
                clickInk(legacyImage, legacyPadding, EntryLink(imageLabel), false)
                val legacyInside = coloredPoint(0xff0000, legacyPreclip) { it.x > legacyContent.left + 2f }
                selectionAndAx(legacyImage, legacyInside, true)
                clickInk(legacyImage, legacyInside, EntryLink(imageLabel), true)
                assertSame(glyph, legacy.rows[0][0].spans.single())
                assertSame(imageSpan, legacy.rows[1][0].spans.single())

                compose.runOnIdle { selected.value = q; viewport.value = 640.0 }
                compose.waitForIdle(); ready()
                assertEquals(wideFrame, bounds(sourceTable()))
                assertEquals(wideCells, listOf(bounds(cell(0)), bounds(cell(1))))
                assertEquals(wideFollowing, target("Following").screen)
                assertEquals(0x0000ff, rgb(image(), aboveBorder.x, aboveBorder.y))
                clickInk(ink(glyphLabel, 0), aboveBorder, EntryLink(glyphLabel), true)
                activate("Following")
            }
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.runOnIdle { if (!bitmap.isRecycled) bitmap.recycle() } }
            catch (failure: Throwable) {
                val original = primary
                if (original == null) throw failure
                if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
}
