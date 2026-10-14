package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertSame
import org.junit.Test

class TableGridTest {
    private fun cell(colspan: Int = 1, rowspan: Int = 1) = Cell(emptyList(), false, colspan, rowspan)
    @Test fun spansReserveColumnsAcrossRows() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(rowspan = 2), cell(colspan = 2)), listOf(cell(), cell()), listOf(cell(), cell(), cell()))))
        assertEquals(listOf(0, 1, 1, 2, 0, 1, 2), grid.cells.map { it.column })
        assertEquals(3, grid.columns)
        assertEquals(3, grid.rows)
    }
    @Test fun invalidSpanIsRejected() {
        assertThrows(IllegalArgumentException::class.java) { tableGrid(Table(emptyList(), listOf(listOf(cell(colspan = 0))))) }
    }
    @Test fun inflatedSpansCompressWithoutChangingStoredCellsOrLinks() {
        val cells = List(6) { index -> Cell(listOf(Span("link", "Cell $index", target = "target$index")), false, 100, 1) }
        val grid = tableGrid(Table(emptyList(), listOf(cells)))
        assertEquals(6, grid.columns)
        assertEquals((0 until 6).toList(), grid.cells.map { it.column })
        assertEquals(List(6) { 1 }, grid.cells.map { it.colspan })
        grid.cells.forEachIndexed { index, placed -> assertSame(cells[index], placed.cell); assertEquals(100, placed.cell.colspan) }
    }
    @Test fun globalBoundariesPreserveAlignmentAndSparseRowspanOccupancy() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(100, 2), cell(100)), listOf(cell(50), cell(50)))))
        assertEquals(listOf(0, 1, 1, 2), grid.cells.map { it.column })
        assertEquals(listOf(1, 2, 1, 1), grid.cells.map { it.colspan })
        assertEquals(3, grid.columns)
        assertEquals(2, grid.rows)
    }
    @Test fun compactColumnBudgetRetains512MeaningfulColumns() {
        val accepted = tableGrid(Table(emptyList(), listOf(List(512) { cell(100) })))
        assertEquals(512, accepted.columns)
        assertEquals(511, accepted.cells.last().column)
        assertThrows(IllegalArgumentException::class.java) { tableGrid(Table(emptyList(), listOf(List(513) { cell(100) }))) }
    }
    @Test fun captionOnlyAndEmptyRowsHaveNoInventedColumns() {
        assertEquals(0, tableGrid(Table(listOf(Span("text", "Caption")), emptyList())).columns)
        val empty = tableGrid(Table(emptyList(), listOf(emptyList(), emptyList())))
        assertEquals(0, empty.columns); assertEquals(2, empty.rows)
    }
}
