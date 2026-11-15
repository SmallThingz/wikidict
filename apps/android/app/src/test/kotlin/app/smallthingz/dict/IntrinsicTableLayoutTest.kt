package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Synthetic consumer controls for INTRINSIC_TABLE_SCROLL_API03 (bb4e49a7); no KU source claim. */
class IntrinsicTableLayoutTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun all(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private fun policy(direction: TableContainingDirection = TableContainingDirection.Ltr,
        gridDirection: TableContainingDirection = TableContainingDirection.Rtl,
        edges: StyleEdges = all(2f), margins: StyleEdges = StyleEdges(px(0f), px(7f), px(0f), px(5f)),
        border: Float = 1f) = TableBlockViewport(639,
        TableStyle(border = StyleBorder.Solid(px(border), "#123456"), padding = edges, margins = margins),
        ContainerBoxSizing.BorderBox, StyleWidth(StyleWidthUnit.Percent, 100f),
        TableStyle(collapse = TableCollapse.Collapse), gridDirection, "ku",
        TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone), direction)

    private fun table(policy: TableBlockViewport = policy(), rows: List<List<Cell>> = listOf(listOf(
        Cell(listOf(Span("link", "Real action", "Target")), false, 1, 1)))) = Table(emptyList(), rows,
        geometry = TableGeometry(border = 1, cellSpacing = 0, cellPadding = 4),
        style = TableStyle(collapse = TableCollapse.Collapse, margins = all(0f),
            border = StyleBorder.Solid(px(9f), "#abcdef")), blockViewport = policy)

    @Test fun fitContentUsesRealRangeAndOriginalPercentageBasisWithIndependentDirections() {
        val range = ContainerWidths(150f, 300f)
        for (direction in TableContainingDirection.entries) {
            val source = policy(direction)
            val box = resolveIntrinsicTableBlockBox(source, 200f, 100f, range, 1f, 20f)
            assertSame(source, box.policy)
            assertNull(box.floatPolicy)
            assertEquals(150f, box.contentWidth, 0f)
            assertEquals(156f, box.borderWidth, 0f)
            assertEquals(direction, box.containingDirection)
            assertEquals(TableContainingDirection.Rtl, source.gridDirection)
            assertFalse(box.margins!!.leftAuto)
            assertFalse(box.margins!!.rightAuto)
            assertEquals(if (direction == TableContainingDirection.Ltr) 5f else -63f,
                box.usedMargins.left, 0f)
            val differentContainingBasis = resolveIntrinsicTableBlockBox(source, 100f, 100f, range, 1f, 20f)
            assertEquals(94f, differentContainingBasis.contentWidth, 0f)
            assertEquals(100f, differentContainingBasis.borderWidth, 0f)
            assertThrows(IllegalArgumentException::class.java) { resolveTableBlockBox(source, 200f, 1f, 20f) }
            assertEquals(168, tableBlockIntrinsicWidth(source, 150, 1f, 20f))
        }
    }

    @Test fun ordinaryPlacementKeepsFractionalMarginsAndIntegralActualGridBoundary() {
        val margins = FloatMargins(1.25f, 6.5f, 2.75f, 4.25f)
        val blocker = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 60.5f, 40f))
        for (direction in TableContainingDirection.entries) {
            val requests = mutableListOf<NativeBlockMeasureRequest>()
            val placed = placeNativeFixedMarginTable(200.75f, 0f, listOf(blocker), margins, direction) { request ->
                requests += request
                NativeBlockMeasure(intrinsicTableGridWidth(request.availableWidth, ContainerWidths(80f, 300f)).toFloat(), 80f, 10f)
            }
            assertEquals(140.25f, requests.last().assignedWidth, 0f)
            assertEquals(129.5f, requests.last().availableWidth, 0f)
            assertTrue(requests.all { it.containingWidth == 200.75f && it.requestedWidth == null })
            assertEquals(129f, placed.content.width, 0f)
            assertEquals(if (direction == TableContainingDirection.Ltr) 64.75f else 65.25f, placed.content.left, 0f)
            assertEquals(1.25f, placed.content.top, 0f)
            assertEquals(14f, placed.outer.bottom, 0f)
        }
        val below = placeNativeFixedMarginTable(200.75f, 0f, listOf(blocker), margins,
            TableContainingDirection.Ltr) { request ->
            NativeBlockMeasure(intrinsicTableGridWidth(request.availableWidth, ContainerWidths(160f, 300f)).toFloat(), 160f, 10f)
        }
        assertEquals(40f, below.content.top, 0f)
        assertEquals(190f, below.content.width, 0f)
        val clear = placeNativeFixedMarginTable(200.75f, 0f, listOf(blocker), margins,
            TableContainingDirection.Rtl, clear = FigureClear.Both) { request ->
            NativeBlockMeasure(intrinsicTableGridWidth(request.availableWidth, ContainerWidths(80f, 100f)).toFloat(), 80f, 10f)
        }
        assertEquals(40f, clear.content.top, 0f)
        assertEquals(94.25f, clear.content.left, 0f)
        assertEquals(160, intrinsicTableGridWidth(99.75f, ContainerWidths(160f, 300f)))
        assertEquals(100, intrinsicTableGridWidth(300f, ContainerWidths(80f, 100f)))
    }

    @Test fun anonymousOuterHintIsSuppressedWhileCellHintAndExplicitOverridesSurvive() {
        val rows = listOf(listOf(
            Cell(listOf(Span("link", "Hint", "Hint target")), false, 1, 1),
            Cell(listOf(Span("link", "None", "None target")), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = all(0f))),
            Cell(emptyList(), false, 1, 1,
                style = CellStyle(border = StyleBorder.Solid(px(3f), "#112233"), padding = all(2f)))))
        val source = table(rows = rows)
        val wide = checkNotNull(tableRenderMetrics(source, 136, 99, 40, 1f, containerFontPixels = 20f))
        val narrow = checkNotNull(anonymousTableRenderMetrics(source, source.blockViewport!!.gridStyle, 1f, 20f, false))
        assertEquals(4, wide.cellPadding)
        assertEquals(wide.cellPadding, narrow.cellPadding)
        assertEquals(0, wide.cellSpacing)
        assertEquals(0, narrow.cellSpacing)
        assertEquals(0, wide.minRowHeight)
        assertEquals(0, narrow.minRowHeight)
        assertEquals(listOf(1f, 0f, 3f), wide.style!!.cellBorders.map { it.width })
        assertEquals(wide.style!!.cellEdges, narrow.style!!.cellEdges)
        assertEquals(9f, wide.style!!.outerEdges.top.width, 0f)
        assertEquals(0f, narrow.style!!.outerEdges.top.width, 0f)
        assertEquals(5, narrow.style!!.cellInsets[0].top)
        assertEquals(0, narrow.style!!.cellInsets[1].top)
        assertEquals(4, narrow.style!!.cellInsets[2].top)
        assertSame(rows, source.rows)
        assertEquals(listOf("Hint target", "None target"), source.rows.single().flatMap { it.spans }.map { it.target })
        assertThrows(IllegalArgumentException::class.java) {
            resolveTableStyle(source, tableGrid(source), 1f, 20f, 4, 1, suppressOuterHint = true)
        }
    }

    @Test fun emptySlotsKeepTheirRealEdgesWithoutSyntheticRowOrText() {
        for (rows in listOf(emptyList<List<Cell>>(), listOf(emptyList<Cell>()))) {
            val source = table(rows = rows)
            val grid = tableGrid(source)
            assertTrue(grid.cells.isEmpty())
            assertEquals(rows.size, grid.rows)
            val narrow = checkNotNull(anonymousTableRenderMetrics(source, source.blockViewport!!.gridStyle, 1f, 20f, false))
            val wide = checkNotNull(tableRenderMetrics(source, 136, 99, 40, 1f, containerFontPixels = 20f))
            fun pixels(metrics: TableRenderMetrics, anonymous: Boolean) = checkNotNull(tablePixelLayout(grid,
                metrics.columnWidth, metrics.minRowHeight, intArrayOf(), metrics.cellSpacing, metrics.borderWidth,
                metrics.width, metrics.extraColumns, metrics.style!!.tablePadding, metrics.columnWidths,
                metrics.outerBorder, anonymousGrid = anonymous, pairedGrid = true))
            assertEquals(0, pixels(narrow, true).width)
            assertEquals(0, pixels(narrow, true).height)
            assertEquals(18, pixels(wide, false).width)
            assertEquals(18, pixels(wide, false).height)
            assertSame(rows, source.rows)
        }
        val emptyCell = Cell(emptyList(), false, 1, 1)
        assertTrue(pairedTableCellHasIntrinsicHeight(emptyCell))
        val source = table(rows = listOf(listOf(emptyCell)))
        val metrics = checkNotNull(anonymousTableRenderMetrics(source, source.blockViewport!!.gridStyle, 1f, 20f, false))
        assertEquals(TablePixelInsets(5, 5, 5, 5), metrics.style!!.cellInsets.single())
        assertTrue(source.rows.single().single().spans.isEmpty())
    }

    @Test fun fractionalPaddingClipDoesNotRebaseContentOrPan() {
        val source = policy(edges = StyleEdges(px(.5f), px(3.25f), px(.75f), px(2.5f)),
            margins = StyleEdges(px(1.25f), px(4.5f), px(2.25f), px(3.5f)), border = 1.5f)
        val box = resolveIntrinsicTableBlockBox(source, 200.25f, 120.5f, ContainerWidths(60f, 300f), 1.25f, 20f)
        assertEquals(FloatMargins(1.5625f, 5.625f, 2.8125f, 4.375f), box.fixedMargins)
        assertEquals(FloatMargins(2.5f, 5.9375f, 2.8125f, 5f), box.insets)
        assertEquals(99.5625f, box.contentWidth, 0f)
        assertEquals(110.5f, box.borderWidth, 0f)
        val border = NativeFloatBounds(10.25f, 20.5f, 120.75f, 45.8125f)
        val content = NativeFloatBounds(15.25f, 23f, 114.8125f, 43f)
        val clip = tableBlockOverflowBounds(source, content, null, box.paddingBounds(border))
        assertEquals(NativeFloatBounds(12.125f, 22.375f, 118.875f, 43.9375f), clip)
        assertEquals(15.25f, content.left, 0f)
        assertEquals(99.5625f, content.width, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) { tableBlockOverflowBounds(source, content, null) }
        for (rtl in listOf(false, true)) {
            val pan = tableBlockScrollGeometry(box.contentWidth, 150, 11, rtl)
            assertEquals(if (rtl) -39.4375f else -11f, pan.physicalTranslation, 0f)
        }
    }

    @Test fun intrinsicQueryRequiresTheBoundSourceAndClearsAfterEachRequest() {
        val source = table()
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        assertThrows(UnsupportedFloatLayout::class.java) { input.beginBlockIntrinsicQuery() }
        input.bind(owner)
        val first = input.beginBlockIntrinsicQuery()
        val widths = ContainerWidths(90f, 220f)
        input.publishBlockIntrinsics(owner, source, first, widths)
        assertSame(widths, input.blockIntrinsicsReady(first))
        assertNull(input.blockIntrinsicQuery)
        assertThrows(UnsupportedFloatLayout::class.java) { input.blockIntrinsicsReady(first) }
        val second = input.beginBlockIntrinsicQuery()
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publishBlockIntrinsics(owner, source.copy(), second, widths)
        }
        input.unbind(owner)
        assertThrows(UnsupportedFloatLayout::class.java) { input.blockIntrinsicsReady(second) }
        val legacy = NativeTableMarginMeasureInput(source.copy(blockViewport = null))
        legacy.bind(owner)
        assertThrows(UnsupportedFloatLayout::class.java) { legacy.beginBlockIntrinsicQuery() }
    }

    @Test fun oneCenteredParagraphKeepsOriginalBlockAndActionsWithoutAdmittingRichCells() {
        val paragraph = Block("paragraph", 0, listOf(Span("text", "-")), textAlign = CellTextAlign.Center)
        val cell = Cell(emptyList(), false, 1, 1, blocks = listOf(paragraph))
        assertSame(paragraph, intrinsicTableSingleParagraph(cell))
        assertFalse(pairedTableCellHasIntrinsicHeight(cell))
        val action = paragraph.copy(spans = listOf(Span("link", "Centered action", "Center target")))
        val actionCell = cell.copy(blocks = listOf(action))
        assertSame(action, intrinsicTableSingleParagraph(actionCell))
        assertSame(action.spans, intrinsicTableSingleParagraph(actionCell)!!.spans)
        assertEquals(CellTextAlign.Center, intrinsicTableSingleParagraph(actionCell)!!.textAlign)
        assertEquals("Center target", intrinsicTableSingleParagraph(actionCell)!!.spans.single().target)
        assertNull(intrinsicTableSingleParagraph(cell.copy(blocks = listOf(paragraph, action))))
        assertNull(intrinsicTableSingleParagraph(cell.copy(blocks = listOf(paragraph.copy(style = BlockStyle(padding = all(1f)))))))
        assertNull(intrinsicTableSingleParagraph(cell.copy(blocks = listOf(paragraph.copy(depth = 1)))))
        assertNull(intrinsicTableSingleParagraph(cell.copy(blocks = listOf(paragraph.copy(spans = emptyList())))))
        assertSame(paragraph, cell.blocks!!.single())
    }
}
