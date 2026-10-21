package app.smallthingz.dict

import androidx.compose.ui.unit.Constraints
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
        val heightLimit = checkNotNull(tableHeightLimit(10))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(heightLimit)))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(Int.MAX_VALUE)))
        assertNull(tablePixelLayout(grid, 10, Int.MAX_VALUE, intArrayOf(1)))
        assertNull(tablePixelLayout(grid, 10, 1, intArrayOf(-1)))
        val rows = tableGrid(Table(emptyList(), listOf(listOf(cell()), listOf(cell()))))
        assertNotNull(tablePixelLayout(rows, 1, heightLimit / 2, intArrayOf(1, 1)))
        assertNull(tablePixelLayout(rows, 1, heightLimit / 2 + 1, intArrayOf(1, 1)))
    }
    @Test fun zeroAndCaptionOnlyGridsStayAvailableWithoutDivisionByZero() {
        val grid = tableGrid(Table(listOf(Span("text", "Caption")), emptyList()))
        val pixels = checkNotNull(tablePixelLayout(grid, checkNotNull(tableColumnWidth(0, 136)), 40, intArrayOf()))
        assertEquals(0, pixels.width); assertEquals(0, pixels.height)
        assertArrayEquals(intArrayOf(0), pixels.rowOffsets)
    }
    @Test fun widthDependentHeightMatchesInstalledConstraintsAtBitTierBoundaries() {
        // Derive the oracle through the installed public API, then prove the
        // returned boundary by constructing the exact finite constraint pair.
        for (width in intArrayOf(0, 1, 8190, 8191, 32766, 32767, 65534, 65535, 262142)) {
            val budget = Constraints.fitPrioritizingWidth(minWidth = width, maxWidth = width,
                minHeight = 0, maxHeight = Int.MAX_VALUE - 1)
            assertEquals(width, budget.minWidth)
            assertEquals(width, budget.maxWidth)
            val exact = Constraints.fixed(width, budget.maxHeight)
            assertEquals(budget.maxHeight, exact.minHeight)
            assertEquals(budget.maxHeight, exact.maxHeight)
            try {
                Constraints.fixed(width, budget.maxHeight + 1)
                fail("An overflowing finite width/height pair must be refused")
            } catch (_: IllegalArgumentException) { }
            if (width <= TablePixelLimit) assertEquals(budget.maxHeight, tableHeightLimit(width))
            else assertNull(tableHeightLimit(width))
        }
        assertNull(tableHeightLimit(-1))
        assertNull(tableHeightLimit(Int.MAX_VALUE))
    }
    @Test fun tallNarrowLayoutPreservesAllRowsAndRefusesOverflowOrSaturation() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell()), listOf(cell()))))
        for (width in intArrayOf(136, 8190, 8191, 32766)) {
            val maximum = Constraints.fitPrioritizingWidth(width, width, 0, Int.MAX_VALUE - 1).maxHeight
            assertTrue(maximum > TablePixelLimit)
            val pixels = checkNotNull(tablePixelLayout(grid, width, maximum / 2, intArrayOf(1, 1)))
            assertEquals(width, pixels.width)
            assertEquals(maximum, pixels.height)
            assertArrayEquals(intArrayOf(0, maximum / 2, maximum), pixels.rowOffsets)
            assertEquals(maximum, Constraints.fixed(pixels.width, pixels.height).maxHeight)
            assertNull(tablePixelLayout(grid, width, maximum / 2 + 1, intArrayOf(1, 1)))
            assertNull(tablePixelLayout(grid, width, 1, intArrayOf(maximum, 1)))
        }
    }

    @Test fun sparseEmptyRowsPreserveTallGridSpacingAndRealCellIdentity() {
        val first = Cell(listOf(Span("link", "Tall first", target = "tall-first")), false, 1, 1)
        val last = Cell(listOf(Span("link", "Tall last", target = "tall-last")), false, 1, 1)
        val rows = List(1000) { row -> when (row) {
            0 -> listOf(first)
            999 -> listOf(last)
            else -> emptyList()
        } }
        val grid = tableGrid(Table(emptyList(), rows))
        assertEquals(1000, grid.rows)
        assertEquals(1, grid.columns)
        assertEquals(2, grid.cells.size)
        assertSame(first, grid.cells[0].cell)
        assertSame(last, grid.cells[1].cell)
        val pixels = checkNotNull(tablePixelLayout(grid, 136, 40, intArrayOf(30, 30)))
        assertEquals(40000, pixels.height)
        assertEquals(39960, pixels.rowOffsets[999])
        assertEquals(40000, pixels.rowOffsets[1000])
    }

}
