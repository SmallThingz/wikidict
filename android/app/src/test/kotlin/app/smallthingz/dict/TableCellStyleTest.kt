package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TableCellStyleTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun cell(style: CellStyle? = null, colspan: Int = 1, rowspan: Int = 1) =
        Cell(listOf(Span("text", "body")), false, colspan, rowspan, style = style)
    private fun gridTable(vararg cells: Cell, collapse: Boolean = false) = Table(emptyList(), listOf(cells.toList()),
        style = TableStyle(collapse = if (collapse) TableCollapse.Collapse else TableCollapse.Separate))

    @Test fun physicalEdgesOverrideOnlyTheirOwnUniformFallbackAndReserveRealInsets() {
        val style = CellStyle(border = StyleBorder.Solid(px(2f), "#ff0000"),
            padding = StyleEdges(px(3f), px(3f), px(4f), px(3f)),
            borderEdges = CellBorderEdges(top = CellBorder.None, bottom = CellBorder.Double(px(4f), "#0000ff")))
        val table = gridTable(cell(style))
        val result = resolveTableStyle(table, tableGrid(table), 1f, 20f, 10, 1)
        val edges = result.cellEdges.single()
        assertEquals(TableStroke.None, edges.top.stroke)
        assertEquals(TableStroke.Solid, edges.left.stroke)
        assertEquals(2f, edges.right.width, 0f)
        assertEquals(TableStroke.Double, edges.bottom.stroke)
        assertEquals(TablePixelInsets(3, 5, 8, 5), result.cellInsets.single())
        assertEquals(result.cellEdges, resolveTableStyle(table, tableGrid(table), 1f, 20f, 10, 1, rtl = true).cellEdges)
    }

    @Test fun collapsedNoneLosesThenWidthThenDoubleAndPhysicalPositionBreakTies() {
        fun shared(left: CellBorder, right: CellBorder, rtl: Boolean = false): TableBorderSegment {
            val a = CellStyle(borderEdges = if (rtl) CellBorderEdges(left = left) else CellBorderEdges(right = left))
            val b = CellStyle(borderEdges = if (rtl) CellBorderEdges(right = right) else CellBorderEdges(left = right))
            val table = gridTable(cell(a), cell(b), collapse = true)
            val grid = tableGrid(table)
            val style = resolveTableStyle(table, grid, 1f, 20f, 0, 0, rtl = rtl)
            val pixels = tablePixelLayout(grid, 50, 20, intArrayOf(20, 20))!!
            return collapsedTableBorders(grid, pixels, style).single { it.x1 == 50f && it.x2 == 50f }
        }
        val blue = CellBorder.Double(px(4f), "#0000ff")
        val red = CellBorder.Solid(px(4f), "#ff0000")
        assertEquals("#0000ff", shared(CellBorder.None, blue).color)
        assertEquals(TableStroke.Double, shared(red, blue).stroke)
        assertEquals("#ff0000", shared(CellBorder.Solid(px(5f), "#ff0000"), blue).color)
        assertEquals("#0000ff", shared(blue, CellBorder.Double(px(4f), "#ff0000")).color)
        assertEquals("#0000ff", shared(blue, CellBorder.Double(px(4f), "#ff0000"), rtl = true).color)
    }

    @Test fun doublePaintHasTwoThirdsWithOneUnpaintedThirdAndNoExtraGeometry() {
        val bands = tableBorderBands(TableBorderSegment(0f, 12f, 80f, 12f, 6f, "#0000ff", TableStroke.Double))
        assertEquals(2, bands.size)
        assertEquals(listOf(10f, 14f), bands.map { it.y1 })
        assertTrue(bands.all { it.width == 2f && it.x1 == 0f && it.x2 == 80f && it.stroke == TableStroke.Solid })
        assertEquals(2f, bands[1].y1 - bands[1].width / 2 - bands[0].y1 - bands[0].width / 2, 0f)
        val subpixel = tableBorderBands(TableBorderSegment(0f, 0f, 10f, 0f, .6f, "#0000ff", TableStroke.Double))
        assertTrue(subpixel.all { kotlin.math.abs(it.width - .2f) < .00001f })
    }

    @Test fun contentWidthRequestAddsInsetsAndNeverShrinksARealContentMinimum() {
        val table = gridTable(cell(CellStyle(width = StyleWidth(StyleWidthUnit.Px, 65f))), cell())
        val grid = tableGrid(table)
        val preferences = tableCellWidthPreferences(grid, listOf(TablePixelInsets(0, 7, 0, 7), TablePixelInsets(0, 0, 0, 0)), 0, 1f, 20f)
        assertEquals(listOf(79, 40), inlineTableColumnWidths(grid, intArrayOf(30, 20), intArrayOf(60, 40), 0, 0, 1000, cellPreferences = preferences))
        assertEquals(listOf(110, 40), inlineTableColumnWidths(grid, intArrayOf(110, 20), intArrayOf(110, 40), 0, 0, 1000, cellPreferences = preferences))
    }

    @Test fun percentagesUseTheFixedTableAssignableWidthInsteadOfTheOuterViewport() {
        val table = gridTable(cell(CellStyle(width = StyleWidth(StyleWidthUnit.Percent, 50f))), cell())
        val grid = tableGrid(table)
        val preferences = tableCellWidthPreferences(grid, listOf(TablePixelInsets(0, 5, 0, 5), TablePixelInsets(0, 0, 0, 0)), 0, 1f, 20f)
        val widths = inlineTableColumnWidths(grid, intArrayOf(20, 20), intArrayOf(20, 500), 0, 0, 1000, authoredWidth = 200, cellPreferences = preferences)!!
        assertEquals(listOf(110, 90), widths)
        val excessive = preferences.mapIndexed { index, value -> if (index == 0) value.copy(percent = 200.0) else value }
        val constrained = inlineTableColumnWidths(grid, intArrayOf(20, 35), intArrayOf(20, 500), 0, 0, 1000, authoredWidth = 200, cellPreferences = excessive)!!
        assertEquals(200, constrained.sum())
        assertTrue(constrained[1] >= 35)
        assertEquals(200.0, excessive.first().percent!!, 0.0)
    }

    @Test fun computedEmAndExplicitZeroRemainIndependentOfChildFontScaling() {
        val parent = cell(CellStyle(letterSpacing = em(.3f), width = StyleWidth(StyleWidthUnit.Em, 3.25f)))
        val table = gridTable(parent.copy(spans = listOf(Span("text", "small", fontScale = .8f))))
        val preference = tableCellWidthPreferences(tableGrid(table), null, 0, 2f, 20f).single()
        assertEquals(65, preference.pixels)
        assertEquals(6f, exactCellStylePixels(parent.style!!.letterSpacing!!, 2f, 20f), .00001f)
        val reset = CellStyle(letterSpacing = em(0f), width = StyleWidth(StyleWidthUnit.Px, 0f))
        assertNotNull(reset.letterSpacing); assertEquals(0f, reset.letterSpacing!!.value, 0f)
        assertEquals(0, tableCellWidthPreferences(tableGrid(gridTable(cell(reset))), null, 0, 2f, 20f).single().pixels)
        assertNull(tableCellWidthPreferences(tableGrid(gridTable(cell())), null, 0, 2f, 20f).single().pixels)
    }

    @Test fun spanningCellMinimumSurvivesColumnPreferencesAndRowspans() {
        val table = Table(emptyList(), listOf(listOf(cell(colspan = 2)), listOf(
            cell(CellStyle(width = StyleWidth(StyleWidthUnit.Px, 65f)), rowspan = 2), cell()), listOf(cell())))
        val grid = tableGrid(table)
        val widths = inlineTableColumnWidths(grid, intArrayOf(220, 20, 30, 40), intArrayOf(220, 80, 70, 50),
            0, 0, 180, cellPreferences = tableCellWidthPreferences(grid, null, 0, 1f, 20f))!!
        assertEquals(2, widths.size); assertTrue(widths.sum() >= 220); assertTrue(widths.first() >= 65)
        val pixels = tablePixelLayout(grid, 1, 20, intArrayOf(20, 50, 20, 20), columnWidths = widths)!!
        assertEquals(widths.sum(), pixels.width)
        assertTrue(pixels.cellBottom(1, 2) - pixels.cellTop(1) >= 50)
    }
}
