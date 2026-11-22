package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.roundToInt

class TableBoxStyleGeometryTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)

    @Test fun separateTablePaddingKeepsActualCellPaintPlacementAndActionsAlignedInRtl() {
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val table = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("link", "A", target = "Target")), false, 1, 1, background = "#ff0000",
                style = CellStyle(StyleBorder.None, StyleEdges(px(1f), px(1f), px(1f), px(1f)))),
            Cell(listOf(Span("text", "B")), false, 1, 1, background = "#00ff00",
                style = CellStyle(StyleBorder.None, StyleEdges(px(1f), px(1f), px(1f), px(1f)))))),
            geometry = TableGeometry(cellSpacing = 3),
            style = TableStyle(background = "#123456", border = StyleBorder.Solid(px(2f), "#aaaaaa"),
                width = StyleWidth(StyleWidthUnit.Px, 100f), padding = StyleEdges(px(2f), px(4f), px(6f), px(8f))))
        val followed = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction.value) {
                    DictTheme("light") { Box(Modifier.width(200.dp)) { CompiledTableView(table, null) { followed += it.target } } }
                }
            } }
            for (value in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { direction.value = value }
                compose.waitForIdle()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
                val gridBounds = grid.fetchSemanticsNode().boundsInRoot
                val first = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val second = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(100f, gridBounds.width, .01f)
                assertEquals(if (value == LayoutDirection.Ltr) 13f else 53f, first.left - gridBounds.left, .01f)
                assertEquals(7f, first.top - gridBounds.top, .01f)
                assertEquals(if (value == LayoutDirection.Ltr) 54f else 13f, second.left - gridBounds.left, .01f)
                val image = grid.captureToImage().asAndroidBitmap()
                try {
                    assertEquals(0xff123456.toInt(), image.getPixel(5, 10))
                    assertEquals(0xffff0000.toInt(), image.getPixel((first.left - gridBounds.left).toInt() + 1, 8))
                    assertEquals(0xff00ff00.toInt(), image.getPixel((second.left - gridBounds.left).toInt() + 1, 8))
                } finally { image.recycle() }
                compose.onNodeWithText("A").assertIsDisplayed().performTouchInput { click(center) }
            }
            compose.runOnIdle { assertEquals(listOf("Target", "Target"), followed) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun ordinaryTableMinimumKeepsAutoSizingAndTheRealBorderBoxThroughResizeAndRecovery() {
        fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
            StyleEdges(px(top), px(right), px(bottom), px(left))
        fun width(unit: StyleWidthUnit, value: Float) = StyleWidth(unit, value)
        val a = Span("link", "A", "minimum-a", targetFragment = "source", fontScale = 12f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val b = a.copy(text = "B", target = "minimum-b")
        val largeA = a.copy(fontScale = 70f)
        fun cell(span: Span, color: String, align: CellTextAlign) = Cell(listOf(span), false, 1, 1,
            background = color, style = CellStyle(border = StyleBorder.None, padding = edges(),
                width = width(StyleWidthUnit.Px, 20f), textAlign = align))
        val rows = listOf(listOf(cell(a, "#ff0000", CellTextAlign.Left), cell(b, "#00ff00", CellTextAlign.Right)))
        val largeRows = listOf(listOf(cell(largeA, "#ff0000", CellTextAlign.Left), rows.single()[1]))
        val style = TableStyle(background = "#123456", border = StyleBorder.Solid(px(2f), "#aaaaaa"),
            collapse = TableCollapse.Separate, padding = edges(2f, 4f, 6f, 8f),
            width = width(StyleWidthUnit.Px, 100f), minWidth = width(StyleWidthUnit.Percent, 70f))
        val small = Table(emptyList(), rows, geometry = TableGeometry(border = 0, cellSpacing = 3, cellPadding = 0), style = style)
        val long = a.copy(text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega")
        val auto = Table(emptyList(), listOf(listOf(cell(long, "#ff0000", CellTextAlign.Left))),
            geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate, padding = edges()))
        val empty = small.copy(rows = emptyList(), style = style.copy(width = null,
            minWidth = width(StyleWidthUnit.Px, 100.25f)))
        data class State(val table: Table, val containing: Int, val expected: Int, val zoom: Float = 1f)
        val states = listOf(
            State(auto, 400, 400),
            State(auto.copy(style = auto.style!!.copy(minWidth = width(StyleWidthUnit.Percent, 70f))), 400, 400),
            State(auto.copy(style = auto.style!!.copy(minWidth = width(StyleWidthUnit.Px, 0f))), 400, 400),
            State(auto, 400, 400),
            State(small, 400, 280), State(small, 200, 140),
            State(small.copy(style = style.copy(width = width(StyleWidthUnit.Px, 360f), minWidth = width(StyleWidthUnit.Px, 280f))), 400, 360),
            State(small.copy(style = style.copy(minWidth = width(StyleWidthUnit.Percent, 150f))), 200, 300),
            State(small, 400, 280),
            State(small.copy(style = style.copy(minWidth = width(StyleWidthUnit.Px, 100.25f))), 400, 101),
            State(small.copy(rows = largeRows, style = style.copy(minWidth = width(StyleWidthUnit.Em, 7f))), 400, 140),
            State(small.copy(rows = largeRows, style = style.copy(minWidth = width(StyleWidthUnit.Em, 7f))), 400, 210, 1.5f),
            State(small.copy(rows = largeRows, style = style.copy(minWidth = width(StyleWidthUnit.Px, 140f))), 400, 140, 1.5f),
            State(empty, 400, 101),
            State(empty.copy(style = empty.style!!.copy(minWidth = width(StyleWidthUnit.Px, 0f))), 400, 19),
            State(small, 400, 280))
        val phase = mutableStateOf(0)
        val refused = small.copy(style = style.copy(minWidth = width(StyleWidthUnit.Px, 32767f)))
        val selected = mutableStateOf<Table?>(null)
        val swatch = Feature("color_swatch", "", "#ffff00", "none", "")
        val followed = mutableListOf<EntryLink>()
        var bodyPixels = 0f
        var primary: Throwable? = null
        fun raw(node: SemanticsNodeInteraction): androidx.compose.ui.geometry.Rect {
            val actual = node.fetchSemanticsNode()
            return androidx.compose.ui.geometry.Rect(actual.positionInRoot,
                androidx.compose.ui.geometry.Size(actual.size.width.toFloat(), actual.size.height.toFloat()))
        }
        fun grid() = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
        fun scroll() = compose.onNode(androidx.compose.ui.test.SemanticsMatcher.keyIsDefined(
            androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange), useUnmergedTree = true)
        fun range() = scroll().fetchSemanticsNode().config[
            androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange]
        fun layout(label: String): androidx.compose.ui.text.TextLayoutResult {
            val values = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            compose.onNodeWithText(label, useUnmergedTree = true).performSemanticsAction(
                androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(values) }
            return values.single().also { assertEquals(label, it.layoutInput.text.text) }
        }
        fun tap(label: String) {
            val at = layout(label).getBoundingBox(0).center
            compose.onNodeWithText(label, useUnmergedTree = true).performTouchInput { click(at) }
        }
        val widths = mutableListOf<Float>()
        val largeGlyphWidths = mutableListOf<Float>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val state = states[phase.value]
                CompositionLocalProvider(LocalDensity provides Density(1f, state.zoom),
                    LocalLayoutDirection provides LayoutDirection.Ltr, LocalCssPixelTextZoom provides 1f) {
                    val density = LocalDensity.current
                    DictTheme("light") {
                        androidx.compose.material3.MaterialTheme(typography = androidx.compose.material3.MaterialTheme.typography.copy(
                            bodyLarge = androidx.compose.ui.text.TextStyle(fontSize = 20.sp,
                                lineHeight = 24.sp, letterSpacing = 0.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.SansSerif))) {
                            val bodySize = androidx.compose.material3.MaterialTheme.typography.bodyLarge.fontSize
                            androidx.compose.runtime.SideEffect { bodyPixels = with(density) { bodySize.toPx() } }
                            Box(Modifier.width(state.containing.dp).testTag("minimum-containing")) {
                                // A min-bearing source feature must retain this real grid and its actions.
                                CompiledTableView(selected.value ?: state.table, if (phase.value == 8) swatch else null) { followed += it }
                            }
                        }
                    }
                }
            } }
            for (index in states.indices) {
                compose.runOnIdle { phase.value = index }
                compose.waitForIdle()
                val state = states[index]
                val bounds = raw(grid())
                widths += bounds.width
                assertEquals(state.expected.toFloat(), bounds.width, .01f)
                assertEquals(state.containing.toFloat(), raw(compose.onNodeWithTag("minimum-containing", useUnmergedTree = true)).width, .01f)
                if (index <= 3) {
                    val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        textSize = 12f; typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
                    }
                    assertTrue("The independent declared-font MAX exceeds the containing width", paint.measureText(long.text) > 400f)
                    assertTrue(long.text.split(' ').maxOf(paint::measureText) < 280f)
                    assertEquals(long.text, layout(long.text).layoutInput.text.text)
                    assertSame(long, state.table.rows.single().single().spans.single())
                } else if (state.table.rows.isNotEmpty()) {
                    val first = raw(compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true))
                    val second = raw(compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true))
                    assertEquals(13f, first.left - bounds.left, .01f)
                    assertEquals(9f, bounds.right - second.right, .01f)
                    assertEquals(3f, second.left - first.right, .01f)
                    assertEquals(7f, first.top - bounds.top, .01f)
                    assertEquals("A", layout("A").layoutInput.text.text)
                    assertEquals("B", layout("B").layoutInput.text.text)
                    assertSame(if (index in 10..12) largeA else a, state.table.rows.single()[0].spans.single())
                    assertSame(b, state.table.rows.single()[1].spans.single())
                    if (index in 10..12) {
                        assertEquals(20f * state.zoom, bodyPixels, .001f)
                        val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            textSize = 70f * state.zoom; typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
                        }
                        val aMinimum = paint.measureText("A")
                        paint.textSize = 12f * state.zoom
                        assertTrue(aMinimum + paint.measureText("B") + 25f < state.expected)
                        assertEquals(70f, checkNotNull(state.table.rows.single()[0].spans.single().fontScale), 0f)
                        largeGlyphWidths += layout("A").getBoundingBox(0).width
                    }
                    if (index == 5 || index == 15) {
                        val image = grid().captureToImage().asAndroidBitmap()
                        try {
                            assertEquals(0xffaaaaaa.toInt(), image.getPixel(1, 1))
                            assertEquals(0xff123456.toInt(), image.getPixel(5, 10))
                            assertEquals(0xffff0000.toInt(), image.getPixel((first.left - bounds.left).toInt() + 1, 8))
                            assertEquals(0xff00ff00.toInt(), image.getPixel((second.left - bounds.left).toInt() + 1, 8))
                        } finally { image.recycle() }
                    }
                } else {
                    assertEquals(15f, bounds.height, .01f)
                    compose.onAllNodesWithTag("compiled-table-cell-root-0", useUnmergedTree = true).assertCountEquals(0)
                    compose.onAllNodesWithText("A", useUnmergedTree = true).assertCountEquals(0)
                    compose.onAllNodesWithText("B", useUnmergedTree = true).assertCountEquals(0)
                    assertTrue(state.table.rows.isEmpty())
                }
                if (index == 7) {
                    assertEquals(100f, range().maxValue(), 1f)
                    val viewport = raw(compose.onNodeWithTag("minimum-containing", useUnmergedTree = true))
                    val text = compose.onNodeWithText("B", useUnmergedTree = true)
                    val original = raw(text)
                    val glyph = layout("B").getBoundingBox(0)
                    assertTrue(original.left + glyph.center.x > viewport.right)
                    scroll().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.ScrollBy) {
                        assertTrue(it(100f, 0f))
                    }
                    compose.waitForIdle()
                    assertEquals(100f, range().value(), 1f)
                    assertEquals(state.expected.toFloat(), raw(grid()).width, .01f)
                    assertTrue(raw(text).left + glyph.center.x in viewport.left..viewport.right)
                    tap("B")
                    compose.runOnIdle { assertEquals(listOf(EntryLink("minimum-b", "source")), followed) }
                } else assertEquals(0f, range().maxValue(), 1f)
            }
            assertEquals(widths[0], widths[1]); assertEquals(widths[0], widths[2]); assertEquals(widths[0], widths[3])
            assertEquals(widths[4], widths[8]); assertEquals(widths[4], widths[15])
            assertEquals(3, largeGlyphWidths.size)
            assertTrue("Actual child glyphs also follow the active text zoom", largeGlyphWidths[1] > largeGlyphWidths[0])
            assertEquals(largeGlyphWidths[1], largeGlyphWidths[2], .01f)
            tap("A")
            compose.runOnIdle { assertEquals(listOf(EntryLink("minimum-b", "source"), EntryLink("minimum-a", "source")), followed) }
            compose.runOnIdle { selected.value = refused }
            compose.waitForIdle()
            val warning = "Table minimum-width layout is unavailable. Table content is retained."
            compose.onNodeWithText(warning, useUnmergedTree = true).assertIsDisplayed()
            assertEquals("A", layout("A").layoutInput.text.text)
            assertEquals("B", layout("B").layoutInput.text.text)
            assertSame(rows, refused.rows)
            assertSame(a, refused.rows.single()[0].spans.single())
            assertSame(b, refused.rows.single()[1].spans.single())
            assertEquals(32767f, checkNotNull(refused.style!!.minWidth).value, 0f)
            tap("B")
            compose.runOnIdle {
                assertEquals(listOf(EntryLink("minimum-b", "source"), EntryLink("minimum-a", "source"),
                    EntryLink("minimum-b", "source")), followed)
                selected.value = null
            }
            compose.waitForIdle()
            compose.onAllNodesWithText(warning, useUnmergedTree = true).assertCountEquals(0)
            assertEquals(280f, raw(grid()).width, .01f)
            assertEquals(0f, range().maxValue(), 1f)
            tap("A")
            compose.runOnIdle { assertEquals(List(2) {
                listOf(EntryLink("minimum-b", "source"), EntryLink("minimum-a", "source")) }.flatten(), followed) }
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

    @Test fun nestedAndFloatedTableMinimaUseTheOriginalContainingWidthInsteadOfTheRemainingLane() {
        fun edges(bottom: Float = 0f) = StyleEdges(px(0f), px(0f), px(bottom), px(0f))
        val link = Span("link", "Kept", "minimum-nested", fontScale = 12f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val cell = Cell(listOf(link), false, 1, 1, style = CellStyle(border = StyleBorder.None,
            padding = edges(), width = StyleWidth(StyleWidthUnit.Px, 20f)))
        val inner = Table(emptyList(), listOf(listOf(cell)),
            geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate,
                padding = edges(), width = StyleWidth(StyleWidthUnit.Px, 100f),
                minWidth = StyleWidth(StyleWidthUnit.Percent, 70f)))
        val outerCell = Cell(emptyList(), false, 1, 1, nestedTable = inner,
            style = CellStyle(border = StyleBorder.None, padding = edges()))
        fun outer(width: Int) = Table(emptyList(), listOf(listOf(outerCell)),
            geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate,
                padding = edges(), width = StyleWidth(StyleWidthUnit.Px, width.toFloat())))
        val outers = listOf(outer(300), outer(200), outer(300))
        val floated = inner.copy(style = inner.style!!.copy(floatSide = TableFloatSide.Right))
        val blocker = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "F", fontScale = 12f,
            fontScaleBasis = FontScaleBasis.CssPx)), false, 1, 1,
            style = CellStyle(border = StyleBorder.None, padding = edges(70f),
                width = StyleWidth(StyleWidthUnit.Px, 20f))))),
            geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Separate,
                padding = edges(), width = StyleWidth(StyleWidthUnit.Px, 120f), floatSide = TableFloatSide.Left))
        fun block(table: Table) = Block("table", 0, emptyList(), table = table)
        val blocks = listOf(block(blocker), block(floated), Block("paragraph", 0,
            listOf(Span("text", "After", fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx))))
        val phase = mutableStateOf(0)
        val followed = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        var primary: Throwable? = null
        fun node(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true)
        fun raw(value: SemanticsNodeInteraction): androidx.compose.ui.geometry.Rect {
            val actual = value.fetchSemanticsNode()
            return androidx.compose.ui.geometry.Rect(actual.positionInRoot,
                androidx.compose.ui.geometry.Size(actual.size.width.toFloat(), actual.size.height.toFloat()))
        }
        var initialNested: androidx.compose.ui.geometry.Rect? = null
        var initialFloat: androidx.compose.ui.geometry.Rect? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides LayoutDirection.Ltr, LocalCssPixelTextZoom provides 1f,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    DictTheme("light") {
                        androidx.compose.material3.MaterialTheme(typography = androidx.compose.material3.MaterialTheme.typography.copy(
                            bodyLarge = androidx.compose.ui.text.TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                                letterSpacing = 0.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.SansSerif))) {
                            val width = if (phase.value < 3) 500 else if (phase.value == 4) 300 else 400
                            Box(Modifier.width(width.dp).testTag("minimum-native-containing")) {
                                if (phase.value < 3) CompiledTableView(outers[phase.value], null) { followed += it }
                                else NativeFloatBlockContext(blocks, { followed += it }, "minimum-floats", Modifier,
                                    inCell = false, gridPath = "root", gapDp = 0f, trailingGap = false)
                            }
                        }
                    }
                }
            } }
            for (index in 0..5) {
                compose.runOnIdle { phase.value = index; failures.clear() }
                compose.waitForIdle()
                compose.runOnIdle { assertTrue(failures.toString(), failures.isEmpty()) }
                val containing = raw(node("minimum-native-containing"))
                if (index < 3) {
                    val outerWidth = if (index == 1) 200f else 300f
                    val innerWidth = if (index == 1) 140f else 210f
                    val outerBounds = raw(node("compiled-table-grid"))
                    val cellBounds = raw(node("compiled-table-cell-root-0"))
                    val innerBounds = raw(node("compiled-table-grid-root/0"))
                    assertEquals(500f, containing.width, .01f)
                    assertEquals(outerWidth, outerBounds.width, .01f)
                    assertEquals(outerWidth, cellBounds.width, .01f)
                    assertEquals(innerWidth, innerBounds.width, .01f)
                    assertEquals(cellBounds.left, innerBounds.left, .01f)
                    assertSame(outerCell, outers[index].rows.single().single())
                    assertSame(inner, outerCell.nestedTable)
                    assertSame(link, inner.rows.single().single().spans.single())
                    val local = androidx.compose.ui.geometry.Rect(innerBounds.left - containing.left,
                        innerBounds.top - containing.top, innerBounds.right - containing.left, innerBounds.bottom - containing.top)
                    if (index == 0) initialNested = local
                    if (index == 2) assertEquals(initialNested, local)
                } else {
                    val c = if (index == 4) 300f else 400f
                    val expected = if (index == 4) 210f else 280f
                    val left = raw(node("compiled-table-grid-root/block-0"))
                    val right = raw(node("compiled-table-grid-root/block-1"))
                    assertEquals(c, containing.width, .01f)
                    assertEquals(120f, left.width, .01f)
                    assertEquals(0f, left.left - containing.left, .01f)
                    assertEquals(expected, right.width, .01f)
                    assertEquals(c, right.right - containing.left, .01f)
                    assertEquals(c - expected, right.left - containing.left, .01f)
                    if (index == 4) {
                        assertTrue("210px minimum cannot fit the real 180px lane", right.top >= left.bottom)
                    } else {
                        assertEquals(left.top, right.top, .01f)
                        assertEquals(left.right, right.left, .01f)
                    }
                    assertSame(cell, floated.rows.single().single())
                    assertSame(link, floated.rows.single().single().spans.single())
                    assertEquals(70f, checkNotNull(floated.style!!.minWidth).value, 0f)
                    val local = androidx.compose.ui.geometry.Rect(right.left - containing.left,
                        right.top - containing.top, right.right - containing.left, right.bottom - containing.top)
                    if (index == 3) initialFloat = local
                    if (index == 5) assertEquals(initialFloat, local)
                }
            }
            val text = compose.onNodeWithText("Kept", useUnmergedTree = true)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            text.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(link.text, layouts.single().layoutInput.text.text)
            val at = layouts.single().getBoundingBox(1).center
            text.performTouchInput { click(at) }
            compose.runOnIdle { assertEquals(listOf(EntryLink("minimum-nested")), followed) }
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

    @Test fun rootRowVisibilityKeepsTheActualCaptionBoxAndOriginalCellsAcrossNestedWidthsAndRecovery() {
        val caption = Span("link", "MMMMMMMM MMMM", target = "caption-target", fontScale = 20f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val body = Span("link", "Visible body", target = "body-target", fontScale = 20f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val cell = Cell(listOf(body), false, 1, 1, background = "#ff0000",
            style = CellStyle(border = StyleBorder.None, padding = StyleEdges(px(0f), px(0f), px(0f), px(0f)),
                width = StyleWidth(StyleWidthUnit.Px, 180f)))
        val original = Table(listOf(caption), listOf(listOf(cell)),
            geometry = TableGeometry(cellSpacing = 4, cellPadding = 0),
            style = TableStyle(background = "#123456", border = StyleBorder.Solid(px(2f), "#00ff00"),
                collapse = TableCollapse.Separate, padding = StyleEdges(px(3f), px(2f), px(5f), px(2f))),
            rowsHiddenMaxWidthPx = 639)
        val noCaption = original.copy(caption = emptyList())
        val nestedCaption = Span("link", "Nested caption", target = "nested-caption", fontScale = 12f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val inner = original.copy(caption = listOf(nestedCaption), rowsHiddenMaxWidthPx = 800)
        val outer = original.copy(rows = listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = inner,
            style = CellStyle(border = StyleBorder.None, padding = StyleEdges(px(0f), px(0f), px(0f), px(0f)))))))
        data class Phase(val table: Table, val root: Double, val containing: Int, val hidden: Boolean,
            val rtl: Boolean = false)
        val phases = listOf(
            Phase(original, 640.0, 240, false), Phase(original, 639.0, 240, true),
            Phase(original, 639.0, 80, true), Phase(original, Math.nextUp(639.0), 80, false),
            Phase(original, 639.0, 240, true, true), Phase(noCaption, 639.0, 240, true),
            Phase(original, 640.0, 240, false), Phase(outer, 639.0, 240, true),
            Phase(outer, 640.0, 240, false), Phase(outer, 801.0, 240, false),
            Phase(original, 640.0, 240, false))
        val phase = mutableStateOf(0)
        val followed = mutableListOf<EntryLink>()
        fun raw(node: SemanticsNodeInteraction): androidx.compose.ui.geometry.Rect {
            val value = node.fetchSemanticsNode()
            return androidx.compose.ui.geometry.Rect(value.positionInRoot,
                androidx.compose.ui.geometry.Size(value.size.width.toFloat(), value.size.height.toFloat()))
        }
        fun grid(path: String = "root") = compose.onNodeWithTag(
            if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path", useUnmergedTree = true)
        fun textLayout(label: String): androidx.compose.ui.text.TextLayoutResult {
            val results = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            compose.onNodeWithText(label, useUnmergedTree = true).performSemanticsAction(
                androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(results) }
            return results.single()
        }
        val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 20f; typeface = android.graphics.Typeface.MONOSPACE
        }
        val captionMinimum = kotlin.math.ceil(paint.measureText("MMMMMMMM").toDouble()).toFloat()
        assertTrue(paint.measureText(caption.text) > captionMinimum + 20f)
        var recoveredWidth = 0f
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val selected = phases[phase.value]
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalCssPixelTextZoom provides 1f,
                    LocalLayoutDirection provides if (selected.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
                    LocalTableDocumentViewportCssWidth provides selected.root) {
                    DictTheme("light") {
                        androidx.compose.material3.MaterialTheme(typography = androidx.compose.material3.MaterialTheme.typography.copy(
                            bodyLarge = androidx.compose.ui.text.TextStyle(fontSize = 20.sp, lineHeight = 24.sp,
                                letterSpacing = 0.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace))) {
                            Box(Modifier.width(selected.containing.dp).testTag("row-policy-containing")) {
                                CompiledTableView(selected.table, if (phase.value == 1)
                                    Feature("color_swatch", "", "#ffff00", "none", "") else null) { followed += it }
                            }
                        }
                    }
                }
            } }
            for (index in phases.indices) {
                compose.runOnIdle { phase.value = index }
                compose.waitForIdle()
                val selected = phases[index]
                val bounds = raw(grid())
                assertEquals(selected.containing.toFloat(), raw(compose.onNodeWithTag("row-policy-containing", useUnmergedTree = true)).width, .01f)
                if (selected.table === original || selected.table === noCaption) {
                    val expected = if (!selected.hidden) 196f else if (selected.table === noCaption) 12f else captionMinimum
                    assertEquals(expected, bounds.width, 1f)
                    if (selected.hidden) {
                        assertEquals(16f, bounds.height, .01f)
                        compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).assertDoesNotExist()
                        compose.onNodeWithText(body.text, useUnmergedTree = true).assertDoesNotExist()
                    } else {
                        compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).assertExists()
                        assertEquals(body.text, textLayout(body.text).layoutInput.text.text)
                        if (index == 0) recoveredWidth = bounds.width else assertEquals(recoveredWidth, bounds.width, .01f)
                    }
                    if (selected.table === original) {
                        assertEquals(caption.text, textLayout(caption.text).layoutInput.text.text)
                        if (selected.containing == 240) {
                            val captionNode = compose.onNodeWithText(caption.text, useUnmergedTree = true)
                            val hit = textLayout(caption.text).getBoundingBox(0).center
                            captionNode.assertIsDisplayed().performTouchInput { click(hit) }
                        }
                    } else compose.onNodeWithText(caption.text, useUnmergedTree = true).assertDoesNotExist()
                    if (selected.containing == 240 && selected.hidden) {
                        val image = grid().captureToImage().asAndroidBitmap()
                        try {
                            assertEquals(0xff00ff00.toInt(), image.getPixel(image.width / 2, 0))
                            assertEquals(0xff123456.toInt(), image.getPixel(image.width / 2, 8))
                        } finally { image.recycle() }
                    }
                } else {
                    assertSame(outer, selected.table)
                    if (selected.hidden) {
                        grid("root/0").assertDoesNotExist()
                        compose.onNodeWithText(nestedCaption.text, useUnmergedTree = true).assertDoesNotExist()
                    } else {
                        grid("root/0").assertExists()
                        compose.onNodeWithText(nestedCaption.text, useUnmergedTree = true).assertIsDisplayed()
                        if (selected.root == 640.0) {
                            assertEquals(16f, raw(grid("root/0")).height, .01f)
                            compose.onNodeWithText(body.text, useUnmergedTree = true).assertDoesNotExist()
                        } else assertEquals(body.text, textLayout(body.text).layoutInput.text.text)
                    }
                }
                assertSame(cell, original.rows.single().single())
                assertSame(caption, original.caption.single())
                assertSame(inner, outer.rows.single().single().nestedTable)
            }
            compose.runOnIdle {
                assertEquals(5, followed.size)
                assertTrue(followed.all { it.target == "caption-target" })
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun rowVisibilityCaptionSelectionKeepsItsAllocatedLaneRtlOriginAndExactVisibleSource() {
        val heading = Span("link", "captioncaptioncaption", target = "caption-action", fontScale = 16f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val body = Span("link", "body", target = "body-action", fontScale = 16f,
            fontScaleBasis = FontScaleBasis.CssPx)
        val table = Table(listOf(heading), listOf(listOf(Cell(listOf(body), false, 1, 1,
            style = CellStyle(border = StyleBorder.None, padding = StyleEdges(px(0f), px(0f), px(0f), px(0f)),
                width = StyleWidth(StyleWidthUnit.Px, 160f))))),
            geometry = TableGeometry(cellPadding = 0, cellSpacing = 0),
            style = TableStyle(border = StyleBorder.Solid(px(2f), "#00ff00")), rowsHiddenMaxWidthPx = 639)
        val root = mutableStateOf(640.0)
        val rtl = mutableStateOf(false)
        var geometry: FloatTextGeometry? = null
        val clicked = mutableListOf<String>()
        var firstBorderWidth: Int? = null
        val captionPaint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 16f; typeface = android.graphics.Typeface.MONOSPACE
        }
        val captionMinimum = kotlin.math.ceil(captionPaint.measureText(heading.text).toDouble()).toInt()
        assertTrue(captionMinimum > 164) // Caption MIN dominates the visible body's 160px + borders too.
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false),
            "", { clicked += it.target }, table)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides if (rtl.value) LayoutDirection.Rtl else LayoutDirection.Ltr,
                    LocalTableDocumentViewportCssWidth provides root.value) {
                    DictTheme("light") {
                        val style = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, lineHeight = 20.sp,
                            letterSpacing = 0.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                        androidx.compose.material3.MaterialTheme(typography = androidx.compose.material3.MaterialTheme.typography.copy(bodyLarge = style)) {
                            Box(Modifier.width(240.dp).testTag("selection-table-lane")) {
                                FigureCaptionTable(table, AnonymousFlowContext(if (rtl.value) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr,
                                    "en", null), style, reader) { geometry = it }
                            }
                        }
                    }
                }
            } }
            for ((wide, rightToLeft) in listOf(true to false, false to false, false to true, true to true, true to false)) {
                compose.runOnIdle { root.value = if (wide) 640.0 else 639.0; rtl.value = rightToLeft }
                compose.waitForIdle()
                compose.runOnIdle {
                    val actual = checkNotNull(geometry)
                    assertEquals(240, actual.width)
                    assertEquals(if (wide) heading.text + "\n" + body.text else heading.text, actual.text.toString())
                    val links = actual.nodes.filter { it.kind == FloatInteractionKind.LINK }
                    assertEquals(if (wide) listOf(heading.text, body.text) else listOf(heading.text), links.map { it.label.toString() })
                    val first = links.first()
                    assertEquals(0, first.start)
                    assertEquals(heading.text.length, first.end)
                    checkNotNull(first.onClick).invoke()
                }
                val lane = compose.onNodeWithTag("selection-table-lane", useUnmergedTree = true).fetchSemanticsNode()
                val grid = compose.onNodeWithTag("compiled-table-grid-figure-caption", useUnmergedTree = true).fetchSemanticsNode()
                if (firstBorderWidth == null) firstBorderWidth = grid.size.width
                assertEquals(checkNotNull(firstBorderWidth), grid.size.width)
                assertEquals(captionMinimum.toFloat(), grid.size.width.toFloat(), 1f)
                val left = grid.positionInRoot.x - lane.positionInRoot.x
                assertEquals(if (rightToLeft) 240f - grid.size.width else 0f, left, .01f)
                if (!wide) compose.onNodeWithTag("compiled-table-cell-figure-caption-0", useUnmergedTree = true).assertDoesNotExist()
                assertSame(body, table.rows.single().single().spans.single())
                assertSame(heading, table.caption.single())
            }
            compose.runOnIdle { assertEquals(List(5) { "caption-action" }, clicked) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun entryCellOpacityCompositesOnceAndKeepsInvisibleSwatchSourceThroughRefusalAndRecovery() {
        val zero = px(0f)
        fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
        val edge = InlineBoxBorderEdge.Solid(px(1f), InlineBoxColor.Rgb("#000000"))
        val border = InlineBoxBorderEdges(edge, edge, edge, edge)
        val nbsp = "\u00a0\u00a0\u00a0\u00a0"
        // The retained line25 swatches: three adjacent original four-NBSP boxes,
        // exact title spellings and two trailing spaces. Table/cell chrome and
        // font below are controlled; caption/full-page/TD-title parity is unclaimed.
        val colors = listOf("#80ffc0", "#00ff80", "#008040")
        val titles = listOf("rgb(128,255,192)", "rgb(000,255,128)", "rgb(000,128,064)")
        val owners = colors.mapIndexed { index, color -> Span("text", "", background = color, tooltip = titles[index],
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), border,
                spans = listOf(Span("text", nbsp)))) }
        val spaces = Span("text", "  ")
        val source = owners + spaces
        val text = nbsp.repeat(3) + "  "
        val action = Span("link", "Retained opacity action", target = "opacity-target", targetFragment = "Original")
        val backdrop = android.graphics.Color.rgb(4, 3, 5)
        val cellBackground = android.graphics.Color.rgb(127, 127, 127)
        val cellBorder = android.graphics.Color.rgb(0, 255, 0)
        val style = CellStyle(border = StyleBorder.Solid(px(4f), "#00ff00"), padding = edges(24f),
            textAlign = CellTextAlign.Left)
        val tableStyle = TableStyle(background = "#040305", border = StyleBorder.None,
            padding = edges(0f), collapse = TableCollapse.Separate,
            width = StyleWidth(StyleWidthUnit.Percent, 100f))
        data class Fixture(val entry: Entry, val table: Table, val alpha: Float?, val width: Int)
        fun fixture(alpha: Float?, width: Int = 320, withAction: Boolean = false): Fixture {
            val cell = Cell(if (withAction) source + action else source, false, 1, 1,
                background = "#7f7f7f", style = style.copy(opacity = alpha))
            val table = Table(emptyList(), listOf(listOf(cell)),
                geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0), style = tableStyle)
            return Fixture(Entry("", emptyList(), "language", "", "",
                listOf(Section(3, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList()),
                table, alpha, width)
        }
        val original = fixture(.2f)
        val selected = mutableStateOf(original, androidx.compose.runtime.referentialEqualityPolicy())
        val callbacks = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        val observer: (String) -> Unit = { failures += it }
        var primary: Throwable? = null
        fun views(root: android.view.View): List<NativeFloatTextView> = buildList {
            if (root is NativeFloatTextView) add(root)
            if (root is android.view.ViewGroup) for (i in 0 until root.childCount) addAll(views(root.getChildAt(i)))
        }
        fun cellView() = views(compose.activityRule.activity().window.decorView)
            .single { it.currentMeasuredGeometry?.text?.toString() == text }
        fun grid() = compose.onNode(SemanticsMatcher("the actual table grid") {
            it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag)?.let { tag ->
                tag == "compiled-table-grid" || tag.startsWith("compiled-table-grid-") } == true
        }, useUnmergedTree = true)
        fun warnings(rootFailure: Boolean = false) = compose.onAllNodesWithText(
            if (rootFailure) "Unable to display this layout." else NativeCellOpacityUnavailable, useUnmergedTree = true)
        fun change(value: Fixture, available: Boolean, rootFailure: Boolean = false) {
            compose.runOnIdle { failures.clear(); selected.value = value }
            compose.waitUntil(5000) {
                var hasText = false
                compose.runOnIdle { hasText = views(compose.activityRule.activity().window.decorView)
                    .any { it.currentMeasuredGeometry?.text?.toString() == text } }
                val hasWarning = warnings().fetchSemanticsNodes().isNotEmpty()
                val hasRootWarning = warnings(true).fetchSemanticsNodes().isNotEmpty()
                var exactRootReason = false
                compose.runOnIdle { exactRootReason = NativeCellOpacityUnavailable in failures }
                if (available) hasText && !hasWarning && !hasRootWarning
                else if (rootFailure) hasRootWarning && exactRootReason else hasWarning
            }
            compose.waitForIdle()
        }
        data class Raster(val bitmap: android.graphics.Bitmap, val x: Int, val y: Int)
        fun capture(): Raster {
            val node = grid().fetchSemanticsNode()
            val bounds = node.boundsInRoot
            val root = (checkNotNull(node.root) as androidx.compose.ui.platform.ViewRootForTest).view
            val bitmap = grid().captureToImage().asAndroidBitmap()
            try {
                val location = IntArray(2)
                compose.runOnIdle { root.getLocationOnScreen(location) }
                val left = bounds.left.roundToInt()
                val top = bounds.top.roundToInt()
                assertEquals(bounds.right.roundToInt() - left, bitmap.width)
                assertEquals(bounds.bottom.roundToInt() - top, bitmap.height)
                assertEquals(android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB), bitmap.colorSpace)
                return Raster(bitmap, location[0] + left, location[1] + top)
            } catch (failure: Throwable) { bitmap.recycle(); throw failure }
        }
        fun sample(raster: Raster, offset: Int): Int {
            val point = FloatArray(2)
            compose.runOnIdle {
                val view = cellView()
                val rect = checkNotNull(checkNotNull(view.currentMeasuredGeometry).characterRects(offset, 1).single())
                point[0] = rect.centerX() + view.paddingLeft
                point[1] = rect.centerY() + view.paddingTop
                val matrix = android.graphics.Matrix(); view.transformMatrixToGlobal(matrix); matrix.mapPoints(point)
            }
            return raster.bitmap.getPixel(kotlin.math.floor(point[0] - raster.x).toInt(),
                kotlin.math.floor(point[1] - raster.y).toInt())
        }
        fun expected(color: Int, alpha: Float): Int {
            fun channel(source: Int, destination: Int) = kotlin.math.floor(
                source.toDouble() * alpha.toDouble() + destination.toDouble() * (1.0 - alpha.toDouble()) + .5).toInt()
            return android.graphics.Color.rgb(channel(android.graphics.Color.red(color), android.graphics.Color.red(backdrop)),
                channel(android.graphics.Color.green(color), android.graphics.Color.green(backdrop)),
                channel(android.graphics.Color.blue(color), android.graphics.Color.blue(backdrop)))
        }
        fun assertColor(expected: Int, actual: Int) {
            assertEquals(255, android.graphics.Color.alpha(actual))
            for (shift in listOf(0, 8, 16)) assertTrue("expected ${Integer.toHexString(expected)}, got ${Integer.toHexString(actual)}",
                kotlin.math.abs(((expected ushr shift) and 255) - ((actual ushr shift) and 255)) <= 1)
        }
        data class TextShape(val characters: List<android.graphics.RectF?>, val carets: List<android.graphics.RectF>,
            val width: Int, val height: Int)
        fun shape(): TextShape {
            lateinit var result: TextShape
            compose.runOnIdle {
                val view = cellView(); val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals(text, geometry.text.toString())
                assertEquals(12, geometry.text.count { it == '\u00a0' })
                assertEquals(2, geometry.text.count { it == ' ' })
                assertTrue(geometry.nodes.none { it.onClick != null || it.onLongClick != null })
                result = TextShape(geometry.characterRects(0, text.length).map { it?.let { rect -> android.graphics.RectF(rect) } },
                    (0..text.length).map { geometry.caretRect(NativeTextCaret(it,
                        if (it == text.length) NativeTextAffinity.Upstream else NativeTextAffinity.Downstream)) },
                    geometry.width, geometry.height)
                assertTrue(result.characters.take(12).all { it != null && it.width() > 0f })
                val advice = geometry.nodes.filter { it.kind == FloatInteractionKind.ADVISORY }
                assertEquals(3, advice.size)
                advice.forEachIndexed { index, node ->
                    assertSame(owners[index], checkNotNull(node.advisoryIdentity).span)
                    assertEquals(titles[index], node.tooltip.toString())
                    assertEquals(index * 4 to index * 4 + 4, node.start to node.end)
                }
                val host = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(
                    android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID))
                try {
                    assertEquals(text, host.text.toString())
                    assertTrue(host.isVisibleToUser)
                    assertFalse(host.isClickable)
                } finally { host.recycle() }
            }
            return result
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides LayoutDirection.Ltr,
                    LocalNativeFloatContextFailureObserver provides observer) {
                    androidx.compose.material3.MaterialTheme(colorScheme = androidx.compose.material3.lightColorScheme(
                        background = androidx.compose.ui.graphics.Color.White, surface = androidx.compose.ui.graphics.Color.White),
                        typography = androidx.compose.material3.Typography(bodyLarge = androidx.compose.ui.text.TextStyle(
                            fontSize = 20.sp, letterSpacing = 0.sp,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace))) {
                        Box(Modifier.width(selected.value.width.dp).testTag("opacity-containing")) {
                            EntryView(selected.value.entry, false, {}, { callbacks += it },
                                settings = AppSettings(allowImages = false, allowAudio = false))
                        }
                    }
                }
            } }
            change(original, true)
            val initial = shape()
            var atPointTwo = 0
            for (alpha in listOf<Float?>(.2f, .201f, 0f, 1f, null, .2f)) {
                val next = fixture(alpha)
                change(next, true)
                assertEquals(initial, shape())
                assertSame(source, next.table.rows.single().single().spans)
                owners.forEachIndexed { index, owner -> assertSame(owner, next.table.rows[0][0].spans[index]) }
                val raster = capture()
                try {
                    // NativeDocumentScroll's actual reader insets are 12px per side;
                    // the authored 100% table fills that remaining body allocation.
                    assertEquals(320f, compose.onNodeWithTag("opacity-containing").fetchSemanticsNode().size.width.toFloat(), .01f)
                    assertEquals(296, raster.bitmap.width)
                    val effective = alpha ?: 1f
                    assertColor(expected(cellBackground, effective), raster.bitmap.getPixel(12, 12))
                    assertColor(expected(cellBorder, effective), raster.bitmap.getPixel(2, raster.bitmap.height / 2))
                    val swatches = listOf(1, 5, 9).map { sample(raster, it) }
                    for (i in colors.indices) assertColor(expected(android.graphics.Color.parseColor(colors[i]), effective), swatches[i])
                    // Opaque swatches cover the cell background BEFORE the one group
                    // alpha. Per-draw fading would leak the gray background here.
                    if (alpha == .2f) atPointTwo = android.graphics.Color.green(swatches[0])
                    if (alpha == .201f) {
                        assertEquals(53, atPointTwo)
                        assertEquals(54, android.graphics.Color.green(swatches[0]))
                        assertEquals(54, android.graphics.Color.green(swatches[1]))
                    }
                    if (alpha == 0f) {
                        assertEquals(listOf(backdrop, backdrop, backdrop), swatches)
                        assertEquals(backdrop, raster.bitmap.getPixel(12, 12))
                        assertEquals(backdrop, raster.bitmap.getPixel(2, raster.bitmap.height / 2))
                    }
                } finally { raster.bitmap.recycle() }
                if (alpha == 0f) compose.runOnIdle {
                    val view = cellView()
                    val args = android.os.Bundle().apply {
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                        putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, text.length)
                    }
                    assertTrue(view.accessibilityNodeProvider.performAction(
                        android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID,
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, args))
                    assertEquals(text, view.selectedTextForCopy())
                    view.setSelection(0, 0)
                }
            }
            val reference = android.text.TextPaint().apply { textSize = 20f; typeface = android.graphics.Typeface.MONOSPACE }
            assertTrue("One complete NBSP box plus real cell edges cannot fit this narrow reader body",
                reference.measureText(nbsp) + 2f + 2f * (24f + 4f) > 100f - 24f)
            // Same original Entry and source, only allocation changes: failure must
            // revoke a prior measured permission, and wide reflow must recover it.
            change(original.copy(width = 100), false, rootFailure = true)
            warnings(true)[0].assertIsDisplayed()
            compose.runOnIdle {
                assertTrue(NativeCellOpacityUnavailable in failures)
                val view = cellView()
                assertEquals(text, view.logicalText.toString())
                view.setSelection(0, text.length)
                assertEquals(text, view.selectedTextForCopy())
                view.setSelection(0, 0)
            }
            shape() // The real fallback cell retains original character and AX owners.
            assertSame(source, selected.value.table.rows[0][0].spans)
            change(original, true)
            assertEquals(initial, shape())
            val recovered = capture()
            try { assertColor(expected(android.graphics.Color.parseColor(colors[0]), .2f), sample(recovered, 1)) }
            finally { recovered.bitmap.recycle() }
            val unsupported = fixture(.2f, withAction = true)
            change(unsupported, false)
            warnings()[0].assertIsDisplayed()
            compose.waitUntil(5000) {
                var ready = false
                compose.runOnIdle { ready = views(compose.activityRule.activity().window.decorView).any { view ->
                    view.currentMeasuredGeometry?.nodes?.any { it.label.toString() == action.text && it.onClick != null } == true } }
                ready
            }
            compose.runOnIdle {
                val view = views(compose.activityRule.activity().window.decorView).single { candidate ->
                    candidate.currentMeasuredGeometry?.nodes?.any { it.label.toString() == action.text && it.onClick != null } == true }
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.label.toString() == action.text }
                assertEquals(text + action.text, view.logicalText.toString())
                assertSame(action, unsupported.table.rows[0][0].spans.last())
                assertTrue(view.accessibilityNodeProvider.performAction(node.id,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("opacity-target", "Original")), callbacks)
            }
            change(original, true)
            assertEquals(initial, shape())
            change(unsupported, false)
            warnings()[0].assertIsDisplayed()
            change(original, true)
            val last = capture()
            try { assertColor(expected(android.graphics.Color.parseColor(colors[1]), .2f), sample(last, 5)) }
            finally { last.bitmap.recycle() }
            compose.runOnIdle { assertEquals(1, callbacks.size) }
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

}
