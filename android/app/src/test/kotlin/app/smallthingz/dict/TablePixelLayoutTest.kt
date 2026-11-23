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

    @Test fun oversizedGridKeepsGlobalColumnsAndOriginalCellIdentityAcrossBands() {
        val first = cell(colspan = 2, rowspan = 2)
        val last = Cell(listOf(Span("link", "last", target = "destination")), false, 1, 1)
        val table = Table(emptyList(), List(24999) { row -> when (row) {
            0 -> listOf(first, cell())
            1 -> listOf(cell())
            24998 -> listOf(cell(), last)
            else -> emptyList()
        } })
        val grid = tableGrid(table)
        val metrics = checkNotNull(tableRenderMetrics(table, 136, 10, 40, 1f))
        assertSame(metrics, tallOrdinaryTableMetrics(table, metrics, 400))
        assertNull(tablePixelLayout(grid, metrics.columnWidth, 40, IntArray(grid.cells.size)))
        val bands = tableRowBands(grid)
        assertEquals(TableRowBand(0, 2, 0, 3), bands.first())
        assertEquals(TableRowBand(24998, 24999, 3, 5), bands.last())
        assertEquals(24998, bands.size)
        assertEquals(0, tableBandIndex(bands, 1))
        assertEquals(1, tableBandIndex(bands, 2))
        assertEquals(bands.lastIndex, tableBandIndex(bands, 24998))
        assertTrue(tableBandIndex(bands, 24999) < 0)
        val firstGrid = bands.first().grid(grid)
        val lastGrid = bands.last().grid(grid)
        assertEquals(grid.columns, lastGrid.columns)
        assertSame(first, firstGrid.cells.first().cell)
        assertEquals(2, firstGrid.cells.first().colspan)
        assertSame(last, lastGrid.cells.last().cell)
        assertEquals(grid.cells.last().column, lastGrid.cells.last().column)
        assertNotNull(tablePixelLayout(lastGrid, metrics.columnWidth, 40, intArrayOf(20,20)))
        assertNull(tallOrdinaryTableMetrics(table.copy(rows = table.rows.take(1000)), metrics, 400))
        assertNull(tallOrdinaryTableMetrics(table.copy(rowsHiddenMaxWidthPx = 480), metrics, 400))
        assertFalse(tableCanUseRowBands(table, metrics.copy(outerBorder = TablePixelInsets(1,0,1,0))))
    }

    @Test fun adjacentBandsShareTheRealCollapsedEdgeInsteadOfRepeatingTheOuterBorder() {
        val grid = tableGrid(Table(emptyList(), List(3) { listOf(cell()) }))
        val bands = tableRowBands(grid)
        val none = TableStyleBorder(0f, null)
        val red = TableStyleBorder(4f, "#ff0000")
        val blue = TableStyleBorder(4f, "#0000ff")
        val black = TableStyleBorder(8f, "#000000")
        val all = TableCellBorders(black,black,black,black)
        val first = TableCellBorders(none,none,red,none)
        val second = TableCellBorders(blue,none,none,none)
        val third = TableCellBorders(none,none,none,none)
        val zero = TablePixelInsets(0,0,0,0)
        val style = TableResolvedStyle(null, black, true, zero, List(3) { none }, List(3) { zero },
            cellEdges = listOf(first,second,third), outerEdges = all)
        val full = checkNotNull(tablePixelLayout(grid, 136, 40, IntArray(3)))
        val single = checkNotNull(tablePixelLayout(bands[0].grid(grid),136,40,intArrayOf(0)))
        val original = collapsedTableBorders(grid, full, style).single { it.y1 == 40f && it.y2 == 40f }
        for (i in 0..1) {
            val current = collapsedTableBorders(bands[i].grid(grid), single, style, tableBandPaint(grid,style,bands,i))
            val at = if (i == 0) 40f else 0f
            assertEquals(original.copy(y1=at,y2=at), current.single { it.y1 == at && it.y2 == at })
        }
    }

    @Test fun wrappedRowsCanSwitchToBandsAfterTheirActualMeasurement() {
        val table = Table(emptyList(), List(3) { listOf(cell()) })
        val grid = tableGrid(table)
        val metrics = checkNotNull(tableRenderMetrics(table, 136, 10, 40, 1f))
        assertNull(tallOrdinaryTableMetrics(table, metrics, 400))
        val measured = checkNotNull(tableHeightLimit(metrics.width)) / 2
        assertNull(tablePixelLayout(grid, metrics.columnWidth, 40, IntArray(3) { measured }))
        assertTrue(tableCanUseRowBands(table, metrics))
        for (band in tableRowBands(grid)) {
            val local = checkNotNull(tablePixelLayout(band.grid(grid), metrics.columnWidth, 40, intArrayOf(measured)))
            assertEquals(measured, local.height)
        }
    }

    @Test fun tablePositionBelongsToItsImmutableRecordOrExactStandaloneTable() {
        val table = Table(emptyList(), listOf(listOf(cell())))
        val replacement = table.copy()
        val origin = WordHit("library", "index", "", "supplemental", 49, 1234)
        val record = "body-dictionary" to origin
        val stored = TableScrollPosition(table, record, 10, 8, 3)
        assertTrue(stored.belongsTo(replacement, record))
        assertFalse(stored.belongsTo(replacement, "other-dictionary" to origin))
        assertFalse(stored.belongsTo(replacement, "body-dictionary" to origin.copy(offset = 80)))
        val standalone = TableScrollPosition(table, null, 10, 8, 3)
        assertTrue(standalone.belongsTo(table, null))
        assertFalse(standalone.belongsTo(replacement, null))
    }

}
