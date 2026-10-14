package app.smallthingz.dict

import java.util.PriorityQueue
import java.util.TreeMap
import java.util.TreeSet

/** Stored spans stay unchanged; placements use global boundary-compressed columns. */
data class PlacedCell(val cell: Cell, val row: Int, val column: Int, val colspan: Int)
data class TableGrid(val cells: List<PlacedCell>, val rows: Int, val columns: Int)
fun tableGrid(table: Table): TableGrid {
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
        val start = compact.getValue(item.start)
        PlacedCell(item.cell, item.row, start, compact.getValue(item.end) - start)
    }
    return TableGrid(placed, rows, boundaries.size - 1)
}
