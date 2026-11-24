package app.smallthingz.dict

import java.util.PriorityQueue
import java.util.TreeMap
import java.util.TreeSet

/** Stored spans stay unchanged; placements use global boundary-compressed columns. */
data class PlacedCell(val cell: Cell, val row: Int, val column: Int, val colspan: Int)
data class TableGrid(val cells: List<PlacedCell>, val rows: Int, val columns: Int)
fun tableGrid(table: Table): TableGrid = tableGrid(table, null)

internal fun tableGrid(table: Table, physicalColumns: MutableList<Int>?): TableGrid {
    data class Interval(val start: Int, val end: Int, val untilRow: Int)
    data class Original(val cell: Cell, val row: Int, val start: Int, val end: Int)
    val active = TreeMap<Int, Interval>()
    val expiring = PriorityQueue<Interval>(compareBy<Interval> { it.untilRow }.thenBy { it.start })
    val original = mutableListOf<Original>()
    val boundaries = TreeSet<Int>().apply { add(0) }
    var rows = table.rows.size
    table.rows.forEachIndexed { row, cells ->
        while (expiring.isNotEmpty() && expiring.peek().untilRow <= row) {
            val expired = expiring.remove()
            check(active.remove(expired.start) === expired)
        }
        var column = 0
        cells.forEach { cell ->
            require(cell.colspan in 1..100 && cell.rowspan in 1..100) { "Invalid table span" }
            var end: Int
            while (true) {
                end = Math.addExact(column, cell.colspan)
                val previous = active.floorEntry(column)?.value
                val overlap = if (previous != null && previous.end > column) previous
                    else active.ceilingEntry(column)?.value?.takeIf { it.start < end }
                if (overlap == null) break
                column = overlap.end
            }
            val untilRow = Math.addExact(row, cell.rowspan)
            val interval = Interval(column, end, untilRow)
            check(active.put(column, interval) == null)
            expiring.add(interval)
            for (boundary in intArrayOf(column, end)) {
                if (!boundaries.contains(boundary)) {
                    require(boundaries.size < 513) { "Table has too many meaningful columns" }
                    boundaries.add(boundary)
                }
            }
            original.add(Original(cell, row, column, end))
            rows = maxOf(rows, untilRow)
            column = end
        }
    }
    val compact = boundaries.withIndex().associate { it.value to it.index }
    val placed = original.map { item ->
        physicalColumns?.add(item.start)
        val start = compact.getValue(item.start)
        PlacedCell(item.cell, item.row, start, compact.getValue(item.end) - start)
    }
    return TableGrid(placed, rows, boundaries.size - 1)
}

/** Cut only after every cell from the current band has ended. Column boundaries and cell
 * indices always come from the complete grid, including at sparse and merged rows. */
internal data class TableRowBand(val firstRow: Int, val endRow: Int, val firstCell: Int, val endCell: Int) {
    fun grid(source: TableGrid): TableGrid = TableGrid(source.cells.subList(firstCell, endCell).map {
        it.copy(row = it.row - firstRow)
    }, endRow - firstRow, source.columns)
}

internal fun tableRowBands(grid: TableGrid): List<TableRowBand> = buildList {
    var row = 0
    var cell = 0
    while (row < grid.rows) {
        val firstCell = cell
        var end = row + 1
        while (cell < grid.cells.size && grid.cells[cell].row < end) {
            val placed = grid.cells[cell++]
            end = maxOf(end, placed.row + placed.cell.rowspan)
        }
        add(TableRowBand(row, end, firstCell, cell))
        row = end
    }
}

/** Accessibility addresses original rows, including rows covered by a single merged item. */
internal fun tableBandIndex(bands: List<TableRowBand>, row: Int): Int = bands.binarySearch {
    when {
        it.endRow <= row -> -1
        it.firstRow > row -> 1
        else -> 0
    }
}
