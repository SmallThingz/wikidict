package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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
}
