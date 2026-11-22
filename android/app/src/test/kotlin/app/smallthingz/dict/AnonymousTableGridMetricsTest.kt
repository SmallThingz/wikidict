package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-only controls for the existing table solver's anonymous-grid mode; unrun. */
class AnonymousTableGridMetricsTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val gridStyle = TableStyle(collapse = TableCollapse.Collapse)
    private fun table(style: TableStyle? = null, cellStyle: CellStyle? = null) = Table(emptyList(),
        listOf(listOf(Cell(listOf(Span("link", "Body", target = "Target")), false, 1, 1,
            background = "#ff0000", style = cellStyle))), style = style)
    private fun anonymous(value: Table, style: TableStyle = gridStyle, rtl: Boolean = false) =
        anonymousTableRenderMetrics(value, style, 1f, 16f, rtl)

    @Test fun absentNewModeKeepsExistingNativeDefaultsAndStyleSelection() {
        val value = table(TableStyle(border = StyleBorder.Solid(px(2f), "#123456"),
            background = "#abcdef", width = StyleWidth(StyleWidthUnit.Px, 100f)))
        val old = tableRenderMetrics(value, 136, 10, 40, 1f, containerFontPixels = 16f)
        val absent = tableRenderMetrics(value, 136, 10, 40, 1f,
            containerFontPixels = 16f, anonymousGridStyle = null)
        assertEquals(old, absent)
        assertEquals(40, old!!.minRowHeight); assertEquals(10, old.cellPadding)
        assertEquals(100, old.width); assertEquals("#abcdef", old.style!!.background)
        val grid = tableGrid(value)
        assertEquals(resolveTableStyle(value, grid, 1f, 16f, 10, 0),
            resolveTableStyle(value, grid, 1f, 16f, 10, 0, tableStyle = value.style))
        assertNull(tableRenderMetrics(value, 1, 0, 0, 1f, containerFontPixels = 16f))
    }

    @Test fun outerTableWidthAndPaintNeverBecomeAnonymousGridWidthOrPaint() {
        val value = table(TableStyle(background = "#123456", border = StyleBorder.Solid(px(4f), "#abcdef"),
            width = StyleWidth(StyleWidthUnit.Px, 800f), padding = edges(9f), margins = edges(7f)))
        val metrics = checkNotNull(anonymous(value))
        assertEquals(0, metrics.cellPadding); assertEquals(0, metrics.borderWidth)
        assertEquals(0, metrics.cellSpacing); assertEquals(0, metrics.minRowHeight)
        assertEquals(TablePixelInsets(0, 0, 0, 0), metrics.outerBorder)
        assertEquals(TablePixelInsets(0, 0, 0, 0), metrics.style!!.tablePadding)
        assertEquals(TablePixelInsets(0, 0, 0, 0), metrics.style!!.margins)
        assertNull(metrics.style!!.background)
        val used = checkNotNull(inlineTableMetrics(metrics, tableGrid(value), intArrayOf(20), intArrayOf(30),
            availableWidth = 70, authoredWidth = null))
        assertEquals(30, used.width) // A 70px content viewport does not force max-content or a second 70%.
        assertEquals("#ff0000", value.rows.single().single().background)
        assertEquals("Target", value.rows.single().single().spans.single().target)
        assertEquals(StyleWidth(StyleWidthUnit.Px, 800f), value.style!!.width)
    }

    @Test fun explicitCellEdgesRemainWhileRowsUseOnlyMeasuredContent() {
        val value = table(TableStyle(border = StyleBorder.Solid(px(10f), "#000000")),
            CellStyle(border = StyleBorder.Solid(px(2f), "#abcdef"), padding = edges(2f)))
        val metrics = checkNotNull(anonymous(value, rtl = true))
        assertTrue(metrics.style!!.rtl)
        assertEquals(2f, metrics.style!!.cellEdges.single().left.width, 0f)
        assertEquals(TablePixelInsets(3, 3, 3, 3), metrics.style!!.cellInsets.single())
        val grid = tableGrid(value)
        val used = checkNotNull(inlineTableMetrics(metrics, grid, intArrayOf(12), intArrayOf(12), 70))
        val pixels = checkNotNull(tablePixelLayout(grid, used.columnWidth, used.minRowHeight, intArrayOf(12),
            minimumWidth = used.width, columnWidths = used.columnWidths, outerBorder = used.outerBorder,
            anonymousGrid = true))
        assertEquals(12, pixels.height)
        assertNull(tablePixelLayout(grid, used.columnWidth, 0, intArrayOf(12),
            minimumWidth = used.width, columnWidths = used.columnWidths, outerBorder = used.outerBorder))
    }

    @Test fun emptyRowsAndRowspansDoNotAcquireAReaderFortyPixelFloor() {
        val value = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 2)), emptyList()))
        val metrics = checkNotNull(anonymous(value))
        val grid = tableGrid(value)
        val used = checkNotNull(inlineTableMetrics(metrics, grid, intArrayOf(0), intArrayOf(0), 70))
        val populated = checkNotNull(tablePixelLayout(grid, used.columnWidth, 0, intArrayOf(9),
            minimumWidth = used.width, columnWidths = used.columnWidths, anonymousGrid = true))
        assertArrayEquals(intArrayOf(0, 0, 9), populated.rowOffsets)
        val empty = checkNotNull(tablePixelLayout(grid, used.columnWidth, 0, intArrayOf(0),
            minimumWidth = used.width, columnWidths = used.columnWidths, anonymousGrid = true))
        assertEquals(0, empty.height)
        assertNull(tablePixelLayout(grid, used.columnWidth, -1, intArrayOf(0), anonymousGrid = true))
    }

    @Test fun noRowsOrCellsRemainAZeroSizedAnonymousGrid() {
        for (rows in listOf(emptyList<List<Cell>>(), listOf(emptyList<Cell>()))) {
            val value = Table(listOf(Span("text", "Caption stays with its owner")), rows,
                style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f)))
            val grid = tableGrid(value)
            val metrics = checkNotNull(anonymous(value))
            assertTrue(grid.cells.isEmpty()); assertEquals(0, metrics.width)
            val pixels = checkNotNull(tablePixelLayout(grid, metrics.columnWidth, metrics.minRowHeight,
                intArrayOf(), minimumWidth = metrics.width, anonymousGrid = true))
            assertEquals(0, pixels.width); assertEquals(0, pixels.height)
            assertEquals(rows.size + 1, pixels.rowOffsets.size)
            assertEquals("Caption stays with its owner", value.caption.single().text)
            // The caller bypasses the occupied-cell solver for this new-mode empty grid.
            assertNull(inlineTableMetrics(metrics, grid, intArrayOf(), intArrayOf(), 70))
        }
    }

    @Test fun autoGridRetainsCellPercentagesMinimumOverflowAndCaptionFloor() {
        val value = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, style = CellStyle(width = StyleWidth(StyleWidthUnit.Percent, 75f))),
            Cell(emptyList(), false, 1, 1))), style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f)))
        val metrics = checkNotNull(anonymous(value))
        val grid = tableGrid(value)
        val preferences = tableCellWidthPreferences(grid, metrics.style!!.cellInsets, 0, 1f, 16f)
        val minimum = intArrayOf(20, 20); val maximum = intArrayOf(80, 80)
        fun used(width: Int, caption: Int = 0) = checkNotNull(inlineTableMetrics(metrics, grid,
            minimum, maximum, width, authoredWidth = null, cellPreferences = preferences, captionMinimumWidth = caption))
        assertEquals(listOf(75, 25), used(100).columnWidths)
        assertEquals(listOf(20, 20), used(30).columnWidths)
        assertEquals(40, used(30).width)
        assertEquals(listOf(105, 35), used(100, 140).columnWidths)
        assertEquals(140, used(100, 140).width)
    }

    @Test fun nestedTablesRetainTheirOwnMetricsAndSupplyMinimaThroughActualCells() {
        val nested = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))),
            geometry = TableGeometry(cellPadding = 5, width = TableWidth(TableWidthUnit.Px, 500)))
        val value = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = nested))))
        val metrics = checkNotNull(anonymous(value))
        assertEquals(1, metrics.width) // Preparation is decoration only; no inherited child width/defaults.
        val used = checkNotNull(inlineTableMetrics(metrics, tableGrid(value), intArrayOf(90), intArrayOf(140), 70))
        assertEquals(90, used.width)
        val independent = checkNotNull(tableRenderMetrics(nested, 136, 10, 40, 1f, containerFontPixels = 16f))
        assertEquals(5, independent.cellPadding); assertEquals(40, independent.minRowHeight)
        assertEquals(500, independent.width)
        assertSame(nested, value.rows.single().single().nestedTable)
    }

    @Test fun newModeRejectsLegacyGeometryOuterStylesAndDecorationProjection() {
        val value = table()
        assertNull(anonymous(value.copy(geometry = TableGeometry())))
        for (style in listOf(TableStyle(collapse = TableCollapse.Separate), gridStyle.copy(background = "#abcdef"),
            gridStyle.copy(border = StyleBorder.None), gridStyle.copy(padding = edges(0f)),
            gridStyle.copy(width = StyleWidth(StyleWidthUnit.Percent, 70f)),
            gridStyle.copy(margins = edges(0f)), gridStyle.copy(clear = FigureClear.None),
            gridStyle.copy(floatSide = TableFloatSide.Left), gridStyle.copy(display = TableDisplay.Table)))
            assertNull(anonymous(value, style))
        assertNull(tableRenderMetrics(value, 1, 0, 0, 1f, containerFontPixels = 16f,
            decorationScale = .5, anonymousGridStyle = gridStyle))
        val padded = table(cellStyle = CellStyle(padding = edges(100f)))
        val exact = checkNotNull(tableRenderMetrics(padded, 1, 0, 0, 1f, containerFontPixels = 16f,
            decorationViewportWidth = 10, decorationViewportHeight = 10, anonymousGridStyle = gridStyle))
        assertEquals(1.0, exact.style!!.decorationScale, 0.0)
        assertEquals(TablePixelInsets(100, 100, 100, 100), exact.style!!.cellInsets.single())
    }
}
