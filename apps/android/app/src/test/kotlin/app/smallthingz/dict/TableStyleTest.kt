package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TableStyleTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun all(value: StyleLength) = StyleEdges(value, value, value, value)

    @Test fun authoredHrCellEmUsesContainerFontWhilePxMarginsAndHeaderPaintStayDistinct() {
        val border = StyleBorder.Solid(px(1f), "#aaaaaa")
        val cellStyle = CellStyle(border, all(em(0.2f)), CellTextAlign.Center)
        val table = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("text", "Large first run", fontScale = 500f)), true, 1, 1,
                background = "#f2f2f2", style = cellStyle),
            Cell(listOf(Span("text", "Ordinary")), false, 1, 1, style = cellStyle.copy(textAlign = CellTextAlign.Left)))),
            style = TableStyle("#f9f9f9", border, TableCollapse.Collapse, all(px(10f))))
        val grid = tableGrid(table)
        val resolved = resolveTableStyle(table, grid, 2f, 20f, 10, 0)
        assertEquals(TablePixelInsets(20, 20, 20, 20), resolved.margins)
        assertEquals(listOf(TablePixelInsets(5, 5, 5, 5), TablePixelInsets(5, 5, 5, 5)), resolved.cellInsets)
        assertEquals("#f9f9f9", resolved.background)
        assertEquals("#f2f2f2", table.rows[0][0].background)
        assertEquals(CellTextAlign.Center, table.rows[0][0].style!!.textAlign)
        assertEquals(CellTextAlign.Left, table.rows[0][1].style!!.textAlign)
        val largerFont = resolveTableStyle(table, grid, 2f, 40f, 10, 0)
        assertEquals(TablePixelInsets(9, 9, 9, 9), largerFont.cellInsets.first())
        assertEquals(resolved.margins, largerFont.margins)
        val metrics = tableRenderMetrics(table, 10, 10, 10, 2f, containerFontPixels = 20f)!!
        assertEquals(0, metrics.borderWidth); assertEquals(0, metrics.cellSpacing)
        assertEquals(resolved, metrics.style)
        assertEquals(metrics, tableRenderMetrics(table, 10, 10, 10, 2f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640))
        assertEquals(500f, table.rows[0][0].spans.single().fontScale)
        // Narrow tall grids have more paired height capacity than widest grids;
        // ordinary decoration must remain exact while the body scrolls vertically.
        val tall = table.copy(rows = List(1500) { listOf(table.rows[0][0].copy(spans = listOf(Span("text", "Ordinary")))) })
        val tallMetrics = tableRenderMetrics(tall, 136, 10, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        assertEquals(1.0, tallMetrics.style!!.decorationScale, 0.0)
        assertEquals(TablePixelInsets(10, 10, 10, 10), tallMetrics.style!!.margins)
        assertTrue(tallMetrics.style!!.cellInsets.all { it == TablePixelInsets(5, 5, 5, 5) })
        val tallGrid = tableGrid(tall)
        val tallPixels = tablePixelLayout(tallGrid, tallMetrics.columnWidth, 40, IntArray(1500) { 34 })!!
        assertEquals(60000, tallPixels.height)
        assertEquals(1500, tallGrid.cells.size)
    }

    @Test fun collapsedSolidBordersResolveOneWidestSharedEdgeAndNoneDoesNotInventAStroke() {
        val red = StyleBorder.Solid(px(1f), "#ff0000")
        val green = StyleBorder.Solid(px(3f), "#00ff00")
        val table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, style = CellStyle(red, all(px(0f)))),
            Cell(emptyList(), false, 1, 1, style = CellStyle(green, all(px(0f)))))),
            style = TableStyle(border = red, collapse = TableCollapse.Collapse))
        val grid = tableGrid(table)
        val metrics = tableRenderMetrics(table, 10, 0, 10, 1f, containerFontPixels = 20f)!!
        assertEquals(2, metrics.style!!.cellInsets[0].right)
        assertEquals(2, metrics.style!!.cellInsets[1].left)
        val pixels = tablePixelLayout(grid, metrics.columnWidth, 10, intArrayOf(10, 10))!!
        val edges = collapsedTableBorders(grid, pixels, metrics.style!!)
        val shared = edges.filter { it.x1 == pixels.cellLeft(1).toFloat() && it.x2 == it.x1 }
        assertEquals(1, shared.size)
        assertEquals(3f, shared.single().width, 0f); assertEquals("#00ff00", shared.single().color)
        assertTrue(edges.all { listOf(it.x1, it.x2, it.y1, it.y2, it.width).all { value -> value.isFinite() } })
        val noBorder = table.copy(style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse),
            rows = table.rows.map { row -> row.map { it.copy(style = CellStyle(StyleBorder.None, all(px(0f)))) } })
        val none = resolveTableStyle(noBorder, tableGrid(noBorder), 1f, 20f, 10, 0)
        assertTrue(none.cellInsets.all { it == TablePixelInsets(0, 0, 0, 0) })
        assertTrue(collapsedTableBorders(tableGrid(noBorder), pixels, none).isEmpty())
        val empty = table.copy(rows = emptyList())
        val emptyGrid = tableGrid(empty)
        val emptyMetrics = tableRenderMetrics(empty, 10, 0, 10, 1f, containerFontPixels = 20f)!!
        val emptyPixels = tablePixelLayout(emptyGrid, emptyMetrics.columnWidth, 10, intArrayOf(), borderWidth = emptyMetrics.borderWidth)!!
        assertEquals(2, emptyPixels.height)
        assertEquals(4, collapsedTableBorders(emptyGrid, emptyPixels, emptyMetrics.style!!).size)
    }

    @Test fun finiteHugeLengthsSaturateOnlyComputedPixelsWhileZeroAndLegacyMetricsRemainExact() {
        val huge = px(Float.MAX_VALUE)
        assertEquals(MaxComputedFontPixels, tableStyleLengthPixels(huge, Float.MAX_VALUE, 20f), 0f)
        assertEquals(MaxComputedFontPixels, tableStyleLengthPixels(em(Float.MAX_VALUE), 1f, Float.MAX_VALUE), 0f)
        assertEquals(0f, tableStyleLengthPixels(px(0f), 3f, 30f), 0f)
        assertEquals(0f, tableStyleLengthPixels(em(Float.MAX_VALUE), 1f, 0f), 0f)
        assertEquals(Float.MAX_VALUE, huge.value, 0f)
        val plain = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))))
        val legacy = tableRenderMetrics(plain, 20, 4, 10, 1f)!!
        assertNull(legacy.style); assertEquals(20, legacy.columnWidth); assertEquals(4, legacy.cellPadding)
        assertEquals(legacy, tableRenderMetrics(plain, 20, 4, 10, 1f, containerFontPixels = 37f))
        val body = Span("link", "Visible body", "Target")
        val extreme = plain.copy(style = TableStyle(border = StyleBorder.Solid(huge, "#aaaaaa"), margins = all(huge)),
            rows = plain.rows.map { row -> row.map { it.copy(spans = listOf(body), style = CellStyle(padding = all(huge))) } })
        val bounded = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        val style = bounded.style!!
        assertTrue(style.decorationScale in 0.0..1.0 && style.decorationScale < 1.0)
        val grid = tableGrid(extreme)
        val inset = style.cellInsets.single()
        val pixels = tablePixelLayout(grid, bounded.columnWidth, bounded.minRowHeight,
            intArrayOf(24 + inset.vertical), bounded.cellSpacing, bounded.borderWidth, bounded.width, bounded.extraColumns)!!
        assertTrue(pixels.width + style.margins.horizontal <= 360)
        assertTrue(pixels.height + style.margins.vertical <= 640)
        assertTrue(pixels.cellWidth(1) - inset.horizontal >= 136)
        assertTrue(pixels.cellBottom(0, 1) - pixels.cellTop(0) - inset.vertical >= 24)
        assertEquals(1, grid.rows); assertEquals(1, grid.cells.size)
        assertEquals(listOf(body), grid.cells.single().cell.spans)
        val dense = extreme.copy(rows = listOf(List(512) { extreme.rows.single().single() }))
        val denseMetrics = tableRenderMetrics(dense, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        val denseGrid = tableGrid(dense)
        assertEquals(512, denseGrid.cells.size)
        assertTrue(denseGrid.cells.all { it.cell.spans == listOf(body) })
        assertNotNull(tablePixelLayout(denseGrid, denseMetrics.columnWidth, 40, IntArray(512) { 24 },
            denseMetrics.cellSpacing, denseMetrics.borderWidth, denseMetrics.width, denseMetrics.extraColumns))
        assertEquals("Target", grid.cells.single().cell.spans.single().target)
        assertEquals(Float.MAX_VALUE, (extreme.style!!.border as StyleBorder.Solid).width.value, 0f)
        assertEquals(Float.MAX_VALUE, extreme.style!!.margins!!.left.value, 0f)
        val tiny = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 1, decorationViewportHeight = 1)!!
        assertEquals(0.0, tiny.style!!.decorationScale, 0.0)
        assertEquals(TablePixelInsets(0, 0, 0, 0), tiny.style!!.margins)
        assertEquals(listOf(body), extreme.rows.single().single().spans)
        val zeroWindow = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 0, decorationViewportHeight = 0)!!
        assertEquals(0.0, zeroWindow.style!!.decorationScale, 0.0)
        assertEquals(listOf(body), grid.cells.single().cell.spans)
    }
}
