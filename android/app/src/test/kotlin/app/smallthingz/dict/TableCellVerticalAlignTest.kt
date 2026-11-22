package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-only controls for explicit cell middle alignment; unrun. */
class TableCellVerticalAlignTest {
    private fun cell(rowspan: Int = 1) = Cell(emptyList(), false, 1, rowspan)

    @Test fun unequalCellsCenterOnlyTheExplicitMiddleChildAndKeepHalfPixels() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(), cell()))))
        val pixels = checkNotNull(tablePixelLayout(grid, 20, 1, intArrayOf(7, 20)))
        val short = grid.cells[0]; val tall = grid.cells[1]
        assertEquals(6.5f, tableCellContentOffset(pixels, short, 7, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(pixels, tall, 20, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(pixels, short, 7, CellVerticalAlign.Top), 0f)
        assertEquals(0f, tableCellContentOffset(pixels, short, 7, null), 0f)
        assertEquals(20, pixels.height)
        assertArrayEquals(intArrayOf(0, 20), pixels.rowOffsets)
    }

    @Test fun rowspanUsesItsCompleteAllocatedHeightAndExistingRowGaps() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(2), cell()), listOf(cell()))))
        val pixels = checkNotNull(tablePixelLayout(grid, 20, 1, intArrayOf(7, 20, 10), cellSpacing = 3))
        val span = grid.cells.first()
        assertEquals(2, span.cell.rowspan)
        assertEquals(33, pixels.cellBottom(span.row, span.cell.rowspan) - pixels.cellTop(span.row))
        assertEquals(13f, tableCellContentOffset(pixels, span, 7, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(pixels, grid.cells[1], 20, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(pixels, grid.cells[2], 10, CellVerticalAlign.Middle), 0f)
    }

    @Test fun measuredPaddingMovesWithTheCellAndSidePaddingCannotChangeTheVerticalOffset() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun table(left: Float, right: Float) = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, style = CellStyle(
                padding = StyleEdges(px(3f), px(right), px(13f), px(left)))), cell())))
        fun prepared(value: Table): Pair<TablePixelLayout, TablePixelInsets> {
            val grid = tableGrid(value)
            val metrics = checkNotNull(tableRenderMetrics(value, 20, 0, 1, 1f, containerFontPixels = 16f))
            val insets = metrics.style!!.cellInsets.first()
            return checkNotNull(tablePixelLayout(grid, metrics.columnWidth, 1,
                intArrayOf(10 + insets.vertical, 50), tablePadding = TablePixelInsets(7, 11, 13, 17),
                outerBorder = TablePixelInsets(2, 3, 4, 5))) to insets
        }
        val value = table(17f, 11f)
        val (ordinary, insets) = prepared(value)
        val (widerSides, widerInsets) = prepared(table(71f, 44f))
        val child = tableGrid(value).cells.first()
        // The full 26px measured child includes its asymmetric 3px/13px padding once.
        val middle = tableCellContentOffset(ordinary, child, 10 + insets.vertical, CellVerticalAlign.Middle)
        assertEquals(12f, middle, 0f)
        assertEquals(24f, ordinary.cellTop(child.row) + middle + insets.top, 0f)
        assertEquals(middle, tableCellContentOffset(widerSides, child, 10 + widerInsets.vertical,
            CellVerticalAlign.Middle), 0f)
        assertEquals(ordinary.cellTop(child.row), widerSides.cellTop(child.row))
        assertEquals(ordinary.height, widerSides.height)
    }

    @Test fun zeroAndOverfullChildrenNeverProduceANegativeOffsetOrChangeLegacyRowFloors() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(), cell()))))
        val legacy = checkNotNull(tablePixelLayout(grid, 20, 40, intArrayOf(0, 12)))
        val empty = grid.cells.first()
        assertEquals(20f, tableCellContentOffset(legacy, empty, 0, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(legacy, empty, 45, CellVerticalAlign.Middle), 0f)
        assertEquals(0f, tableCellContentOffset(legacy, empty, 0, null), 0f)
        assertEquals(40, legacy.height)
        val anonymous = checkNotNull(tablePixelLayout(grid, 20, 0, intArrayOf(0, 0), anonymousGrid = true))
        assertEquals(0f, tableCellContentOffset(anonymous, empty, 0, CellVerticalAlign.Middle), 0f)
        assertEquals(0, anonymous.height)
    }
}
