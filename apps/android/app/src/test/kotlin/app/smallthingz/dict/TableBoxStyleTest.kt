package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TableBoxStyleTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun all(value: StyleLength) = StyleEdges(value, value, value, value)
    private fun table(style: TableStyle, columns: Int = 1) = Table(emptyList(), listOf(List(columns) {
        Cell(listOf(Span("link", "body", target = "Target", fontScale = 7f)), false, 1, 1,
            style = CellStyle(border = StyleBorder.None, padding = all(px(1f))))
    }), style = style)
    private fun metrics(table: Table, density: Float = 1f, font: Float = 20f) =
        tableRenderMetrics(table, 136, 0, 10, density, containerFontPixels = font)

    @Test fun faBoxUsesNormalizedBodyEmOnceAndCssWidthOverridesLegacyRequest() {
        val original = table(TableStyle(width = StyleWidth(StyleWidthUnit.Em, 16f),
            padding = all(StyleLength(StyleLengthUnit.Em, .16f)), clear = FigureClear.Left), 2)
            .copy(geometry = TableGeometry(cellPadding = 9, width = TableWidth(TableWidthUnit.Px, 900)))
        val m = checkNotNull(metrics(original, density = 2f))
        assertEquals(320, m.width)
        assertEquals(TablePixelInsets(3, 3, 3, 3), m.style!!.tablePadding)
        assertEquals(TablePixelInsets(2, 2, 2, 2), m.style!!.cellInsets.first())
        assertEquals(640, metrics(original, density = 2f, font = 40f)!!.width)
        val pixels = original.copy(style = original.style!!.copy(width = StyleWidth(StyleWidthUnit.Px, 160f)))
        assertEquals(320, metrics(pixels, density = 2f, font = 40f)!!.width)
        val percent = original.copy(style = original.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, 50f)))
        assertEquals(320, tableMetricsInWidth(percent, metrics(percent, 2f)!!, 2, 640)!!.width)
        assertEquals(900L, original.geometry!!.width!!.value)
        assertEquals("Target", original.rows[0][0].spans.single().target)
        assertEquals(7f, original.rows[0][0].spans.single().fontScale)
    }

    @Test fun physicalTablePaddingSharesCellOriginsInBothDirectionsWithoutBecomingCellPadding() {
        val padding = StyleEdges(px(2f), px(4f), px(6f), px(8f))
        val table = table(TableStyle(border = StyleBorder.Solid(px(2f), "#123456"),
            width = StyleWidth(StyleWidthUnit.Px, 100f), padding = padding), 2)
            .copy(geometry = TableGeometry(cellSpacing = 3, cellPadding = 11))
        val m = metrics(table)!!
        assertEquals(listOf(TablePixelInsets(1, 1, 1, 1), TablePixelInsets(1, 1, 1, 1)), m.style!!.cellInsets)
        val pixels = tablePixelLayout(tableGrid(table), m.columnWidth, 10, intArrayOf(10, 10),
            m.cellSpacing, m.borderWidth, m.width, m.extraColumns, m.style!!.tablePadding)!!
        assertEquals(100, pixels.width); assertEquals(28, pixels.height)
        assertEquals(7, pixels.cellTop(0)); assertEquals(17, pixels.cellBottom(0, 1))
        assertEquals(13, pixels.physicalCellLeft(0, 1, false))
        assertEquals(53, pixels.physicalCellLeft(0, 1, true))
        assertEquals(13, pixels.physicalCellLeft(1, 1, true))
        assertEquals(91, pixels.physicalCellLeft(0, 1, true) + pixels.cellWidth(1, 0))
        assertEquals(padding, table.style!!.padding)
        val collapsed = table.copy(style = table.style!!.copy(collapse = TableCollapse.Collapse))
        assertEquals(TablePixelInsets(0, 0, 0, 0), metrics(collapsed)!!.style!!.tablePadding)
        assertEquals(padding, collapsed.style!!.padding)
        assertEquals(table.rows, collapsed.rows)
    }

    @Test fun zeroAndOverOneHundredPercentRemainRequestsSubjectToExistingGridMinima() {
        val zero = table(TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 0f)))
            .copy(geometry = TableGeometry(width = TableWidth(TableWidthUnit.Px, 900)))
        val minimum = metrics(zero)!!
        assertEquals(3, minimum.width)
        assertEquals(minimum, tableMetricsInWidth(zero, minimum, 1, 400))
        val larger = zero.copy(style = zero.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, 150f)))
        assertEquals(600, tableMetricsInWidth(larger, metrics(larger)!!, 1, 400)!!.width)
        val legacy = zero.copy(style = TableStyle(clear = FigureClear.None))
        assertEquals(900, metrics(legacy)!!.width)
        assertThrows(IllegalArgumentException::class.java) { TableStyle() }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { StyleWidth(StyleWidthUnit.Percent, value) }
    }

    @Test fun emptyAndExtremeTableBoxesKeepTheirInsetsOrExplicitlyRefuseNativeGeometry() {
        val empty = Table(emptyList(), emptyList(), style = TableStyle(
            width = StyleWidth(StyleWidthUnit.Px, 0f), padding = StyleEdges(px(2f), px(4f), px(6f), px(8f))))
        val m = metrics(empty)!!
        val pixels = tablePixelLayout(tableGrid(empty), m.columnWidth, 10, intArrayOf(), minimumWidth = m.width,
            tablePadding = m.style!!.tablePadding)!!
        assertEquals(12, pixels.width); assertEquals(8, pixels.height)
        val tall = table(TableStyle(width = StyleWidth(StyleWidthUnit.Px, 80f),
            padding = StyleEdges(px(50000f), px(0f), px(0f), px(0f))))
        val t = metrics(tall)!!
        assertEquals(50000, t.style!!.tablePadding.top)
        assertEquals(50010, tablePixelLayout(tableGrid(tall), t.columnWidth, 10, intArrayOf(10),
            minimumWidth = t.width, tablePadding = t.style!!.tablePadding)!!.height)
        assertNull(metrics(tall.copy(style = tall.style!!.copy(padding = all(px(Float.MAX_VALUE))))))
        assertNull(metrics(tall.copy(style = tall.style!!.copy(width = StyleWidth(StyleWidthUnit.Em, Float.MAX_VALUE)))))
        val hugePercent = tall.copy(style = tall.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, Float.MAX_VALUE)))
        assertNull(tableMetricsInWidth(hugePercent, metrics(hugePercent)!!, 1, 400))
    }

    @Test fun physicalClearUsesOnlyPrecedingRelevantFloatsWithoutChangingRequestedWidthBasis() {
        val exclusions = listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 50f, 60f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(250f, 0f, 300f, 90f)))
        assertEquals(10f, tableClearanceY(10f, null, exclusions), 0f)
        assertEquals(10f, tableClearanceY(10f, FigureClear.None, exclusions), 0f)
        assertEquals(60f, tableClearanceY(10f, FigureClear.Left, exclusions), 0f)
        assertEquals(90f, tableClearanceY(10f, FigureClear.Right, exclusions), 0f)
        assertEquals(90f, tableClearanceY(10f, FigureClear.Both, exclusions), 0f)
        assertEquals(10f, tableClearanceY(10f, FigureClear.Both, emptyList()), 0f)
        val placed = placeNativeFloatBlock(300f, tableClearanceY(10f, FigureClear.Left, exclusions), exclusions,
            NativeBlockWidth.Percent(50f)) { request ->
            assertEquals(300f, request.containingWidth, 0f)
            assertEquals(150f, request.requestedWidth!!, 0f)
            NativeBlockMeasure(150f, 150f, 10f)
        }
        assertEquals(60f, placed.bounds.top, 0f)
        assertEquals(150f, placed.bounds.width, 0f)
        val previous = exclusions.take(1)
        val margins = FloatMargins(15f, 0f, 7f, 0f)
        val normal = placeNativeClearedTable(300f, 0f, previous, FigureClear.Left, margins,
            NativeBlockWidth.FixedPx(300f)) { NativeBlockMeasure(300f, 300f, 10f) }
        assertEquals(60f, normal.content.top, 0f)
        assertEquals(45f, normal.outer.top, 0f)
        assertEquals(77f, normal.outer.bottom, 0f)
        val floating = placeNativeFloatingTable(300f, tableClearanceY(0f, FigureClear.Left, previous),
            previous, TableFloatSide.Left, margins, NativeBlockWidth.FixedPx(300f)) {
            NativeBlockMeasure(300f, 300f, 10f)
        }
        assertEquals(60f, floating.outer.top, 0f)
        assertEquals(75f, floating.content.top, 0f)
        val alreadyBelow = placeNativeClearedTable(300f, 0f, previous, FigureClear.Left,
            FloatMargins(100f, 0f, 0f, 0f), NativeBlockWidth.FixedPx(300f)) { NativeBlockMeasure(300f, 300f, 10f) }
        assertEquals(100f, alreadyBelow.content.top, 0f)
    }
}
