package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TablePixelLayoutTest {
    private fun cell(colspan: Int = 1, rowspan: Int = 1) = Cell(emptyList(), false, colspan, rowspan)
    @Test fun sixInflatedCellsHaveNormalCompactPixelWidths() {
        val grid = tableGrid(Table(emptyList(), listOf(List(6) { cell(100) })))
        val pixels = checkNotNull(tablePixelLayout(grid, checkNotNull(tableColumnWidth(grid.columns, 136)), 40, IntArray(6) { 50 }))
        assertEquals(816, pixels.width); assertEquals(50, pixels.height)
        assertArrayEquals(intArrayOf(0, 50), pixels.rowOffsets)
    }
    @Test fun widePixelsAreUniformlyBoundedInsteadOfClipped() {
        val grid = tableGrid(Table(emptyList(), listOf(List(512) { cell() })))
        val width = checkNotNull(tableColumnWidth(512, Int.MAX_VALUE))
        assertEquals(63, width)
        val pixels = checkNotNull(tablePixelLayout(grid, width, 1, IntArray(512) { 1 }))
        assertEquals(32256, pixels.width)
        assertNull(tablePixelLayout(grid, Int.MAX_VALUE, 1, IntArray(512) { 1 }))
    }
    @Test fun rowspansUseActualMeasuredHeightsAndAllBoundaryOffsets() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(rowspan = 2), cell()), listOf(cell()))))
        val pixels = checkNotNull(tablePixelLayout(grid, 100, 10, intArrayOf(50, 20, 30)))
        assertArrayEquals(intArrayOf(0, 20, 60), pixels.rowOffsets)
        assertEquals(pixels, tablePixelLayout(grid, 100, 10, intArrayOf(50, 20, 30)))
    }
    @Test fun saturatedOrOverflowingHeightsAreExplicitlyUnavailable() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell()))))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(TablePixelLimit)))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(Int.MAX_VALUE)))
        assertNull(tablePixelLayout(grid, 10, Int.MAX_VALUE, intArrayOf(1)))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(-1)))
        val rows = tableGrid(Table(emptyList(), listOf(listOf(cell()), listOf(cell()))))
        assertNotNull(tablePixelLayout(rows, 1, 16383, intArrayOf(1, 1)))
        assertNull(tablePixelLayout(rows, 1, 16384, intArrayOf(1, 1)))
    }
    @Test fun zeroAndCaptionOnlyGridsStayAvailableWithoutDivisionByZero() {
        val grid = tableGrid(Table(listOf(Span("text", "Caption")), emptyList()))
        val pixels = checkNotNull(tablePixelLayout(grid, checkNotNull(tableColumnWidth(0, 136)), 40, intArrayOf()))
        assertEquals(0, pixels.width); assertEquals(0, pixels.height)
        assertArrayEquals(intArrayOf(0), pixels.rowOffsets)
    }
}
