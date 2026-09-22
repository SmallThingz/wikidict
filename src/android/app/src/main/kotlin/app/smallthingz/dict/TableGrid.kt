package app.smallthingz.dict

/** HTML-style occupancy: cells after a rowspan start in the next free column. */
data class PlacedCell(val cell: Cell, val row: Int, val column: Int)
data class TableGrid(val cells: List<PlacedCell>, val rows: Int, val columns: Int)
fun tableGrid(table: Table): TableGrid {
    val occupied = mutableListOf<Int>()
    val placed = mutableListOf<PlacedCell>()
    var rows = table.rows.size
    table.rows.forEachIndexed { row, cells ->
        var column = 0
        cells.forEach { cell ->
            require(cell.colspan in 1..100 && cell.rowspan in 1..100) { "Invalid table span" }
            while (true) {
                require(column + cell.colspan <= 512) { "Table is too wide" }
                while (occupied.size < column + cell.colspan) occupied.add(0)
                if ((column until column + cell.colspan).all { occupied[it] <= row }) break
                column++
            }
            placed.add(PlacedCell(cell, row, column))
            for (index in column until column + cell.colspan) occupied[index] = row + cell.rowspan
            rows = maxOf(rows, row + cell.rowspan)
            column += cell.colspan
        }
    }
    return TableGrid(placed, rows, occupied.size)
}
