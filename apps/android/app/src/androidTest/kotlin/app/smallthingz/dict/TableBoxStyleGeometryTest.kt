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
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

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
}
