package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Pure source controls; actual Compose measurement and device behavior remain separate. */
class TablePairedGridMetricsTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun zeroEdges() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun cell(text: String, colspan: Int = 1, rowspan: Int = 1) =
        Cell(if (text.isEmpty()) emptyList() else listOf(Span("text", text)), false, colspan, rowspan,
            style = CellStyle(border = StyleBorder.None, padding = zeroEdges(),
                lineHeight = CellLineHeight(CellLineHeightValue.Normal)))
    private fun paired(rows: List<List<Cell>>) = Table(emptyList(), rows,
        style = TableStyle(margins = zeroEdges(), floatSide = TableFloatSide.Right, collapse = TableCollapse.Collapse),
        blockViewport = TableBlockViewport(639, TableStyle(margins = zeroEdges()),
            ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
            TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Ltr, "de",
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto)),
        floatViewport = TableFloatViewport(639, TableContainingDirection.Ltr, TableContainingDirection.Ltr, "de"))

    @Test fun zeroRowFloorIsPairedOnlyAndKeepsWideSourceDecoration() {
        val source = paired(listOf(listOf(cell("short")), listOf(cell(""))))
        val wide = requireNotNull(tableRenderMetrics(source, 1, 10, 0, 1f,
            containerFontPixels = 16f, marginsConsumed = true))
        val narrow = requireNotNull(anonymousTableRenderMetrics(source, source.blockViewport!!.gridStyle, 1f, 16f, false))
        assertEquals(0, wide.minRowHeight)
        assertEquals(0, narrow.minRowHeight)
        assertEquals(10, wide.cellPadding) // Existing wide defaults are not the anonymous-grid defaults.
        assertEquals(0, narrow.cellPadding)
        assertEquals(2, wide.style!!.cellInsets.size)
        assertTrue(wide.style!!.cellInsets.all { it == TablePixelInsets(0, 0, 0, 0) })
        val old = source.copy(blockViewport = null, floatViewport = null)
        assertNull(tableRenderMetrics(old, 1, 10, 0, 1f, containerFontPixels = 16f))
        assertEquals(40, requireNotNull(tableRenderMetrics(old, 1, 10, 40, 1f,
            containerFontPixels = 16f)).minRowHeight)
        val grid = tableGrid(source)
        val actual = requireNotNull(tablePixelLayout(grid, 1, 0, intArrayOf(13, 0),
            columnWidths = listOf(60), pairedGrid = true))
        assertArrayEquals(intArrayOf(0, 13, 13), actual.rowOffsets)
        assertEquals(13, actual.height)
        assertNull(tablePixelLayout(grid, 1, 0, intArrayOf(13, 0), columnWidths = listOf(60)))
        assertEquals(80, requireNotNull(tablePixelLayout(grid, 1, 40, intArrayOf(13, 0),
            columnWidths = listOf(60))).height)
    }

    @Test fun pairedHeightPreservesRowspanAndRealEdgeAllocation() {
        val source = paired(listOf(listOf(cell("A", rowspan = 2), cell("B")),
            listOf(cell("C")), listOf(cell("footer", colspan = 2))))
        val grid = tableGrid(source)
        val pixels = requireNotNull(tablePixelLayout(grid, 1, 0, intArrayOf(15, 9, 21, 7),
            cellSpacing = 2, tablePadding = TablePixelInsets(3, 5, 4, 4),
            columnWidths = listOf(20, 30), outerBorder = TablePixelInsets(1, 2, 2, 1), pairedGrid = true))
        assertEquals(4, grid.cells.size)
        assertEquals(2, grid.cells.first().cell.rowspan)
        assertEquals(2, grid.cells.last().cell.colspan)
        assertArrayEquals(intArrayOf(0, 9, 30, 37), pixels.rowOffsets)
        assertEquals(68, pixels.width)
        assertEquals(55, pixels.height)
        assertEquals(32, pixels.cellBottom(0, 2) - pixels.cellTop(0))
        assertEquals(52, pixels.cellWidth(2, 0))
        assertNull(tablePixelLayout(grid, 1, 0, intArrayOf(15, 9, Int.MAX_VALUE, 7), pairedGrid = true))
        assertNull(tablePixelLayout(grid, 1, -1, intArrayOf(15, 9, 21, 7), pairedGrid = true))
    }

    @Test fun actualTextOwnersAreAdmittedWithoutInventingAnEmptyCellStrut() {
        val action = Span("link", "A", "Target", targetFragment = "part", trail = "s")
        val ordinary = cell("body").copy(spans = listOf(action, Span("text", "small", small = true),
            Span("text", "italic", italic = true), Span("line_break", ""), Span("text", "tail")))
        assertTrue(pairedTableCellHasIntrinsicHeight(ordinary))
        assertSame(action, ordinary.spans.first())
        assertEquals("part", ordinary.spans.first().targetFragment)
        val emptyCell = cell("")
        assertTrue(pairedTableCellHasIntrinsicHeight(emptyCell))
        assertTrue(emptyCell.spans.isEmpty())
        val owner = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(19f, FontScaleBasis.CssPx))))
        val explicitOwner = emptyCell.copy(spans = listOf(owner))
        assertTrue(pairedTableCellHasIntrinsicHeight(explicitOwner))
        assertEquals(1, explicitOwner.spans.size)
        assertSame(owner, explicitOwner.spans.single())
        assertEquals("", explicitOwner.spans.single().text)
    }

    @Test fun richCellRefusalPrecedesUnknownSubcomposeIntrinsicQueries() {
        val plain = cell("body")
        val nested = Table(emptyList(), listOf(listOf(plain)))
        val unsupported = listOf(
            plain.copy(spans = emptyList(), nestedTable = nested),
            plain.copy(spans = emptyList(), blocks = listOf(Block("paragraph", depth = 0, spans = listOf(Span("text", "kept"))))),
            plain.copy(spans = listOf(Span("text", "", image = InlineImage("Example.png")))),
            plain.copy(spans = listOf(Span("text", "media", classes = "wikidict-media"))),
            plain.copy(spans = listOf(Span("text", String(Character.toChars(0x13000)), classes = "Egyp")))
        )
        unsupported.forEach { assertFalse(pairedTableCellHasIntrinsicHeight(it)) }
        // Width metadata can remain available; it does not authorize a rich-cell height query.
        val source = paired(listOf(listOf(unsupported.first())))
        assertNotNull(tableRenderMetrics(source, 1, 10, 0, 1f, containerFontPixels = 16f, marginsConsumed = true))
        assertSame(nested, source.rows.single().single().nestedTable)
        assertTrue(pairedTableCellHasIntrinsicHeight(plain))
    }
}
