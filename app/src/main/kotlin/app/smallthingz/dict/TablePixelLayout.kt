package app.smallthingz.dict

/** Paired dimensions at or below this value fit Compose Constraints' 15/16-bit pair. */
internal const val TablePixelLimit = 32766
internal data class TablePixelLayout(val columnWidth: Int, val rowOffsets: IntArray, val width: Int) {
    val height: Int get() = rowOffsets.last()
    override fun equals(other: Any?): Boolean = other is TablePixelLayout &&
        columnWidth == other.columnWidth && width == other.width && rowOffsets.contentEquals(other.rowOffsets)
    override fun hashCode(): Int = 31 * (31 * columnWidth + width) + rowOffsets.contentHashCode()
}
internal fun tableColumnWidth(columns: Int, preferred: Int): Int? {
    if (columns !in 0..512 || preferred <= 0) return null
    return if (columns == 0) preferred.coerceAtMost(TablePixelLimit)
        else minOf(preferred, TablePixelLimit / columns).takeIf { it > 0 }
}
/** Null is an explicit unavailable layout, never permission to clip stored cells. */
internal fun tablePixelLayout(grid: TableGrid, columnWidth: Int, minRowHeight: Int,
                             measuredHeights: IntArray): TablePixelLayout? {
    if (columnWidth <= 0 || minRowHeight <= 0 || measuredHeights.size != grid.cells.size || grid.rows < 0) return null
    val width = columnWidth.toLong() * grid.columns
    if (width !in 0L..TablePixelLimit.toLong() || grid.rows.toLong() * minRowHeight > TablePixelLimit) return null
    val heights = LongArray(grid.rows) { minRowHeight.toLong() }
    for ((index, placed) in grid.cells.withIndex()) {
        val end = placed.row.toLong() + placed.cell.rowspan
        if (placed.row < 0 || end > grid.rows || end <= placed.row || measuredHeights[index] !in 0 until TablePixelLimit) return null
        var available = 0L
        for (row in placed.row until end.toInt()) available += heights[row]
        if (measuredHeights[index].toLong() > available) {
            heights[end.toInt() - 1] += measuredHeights[index].toLong() - available
        }
    }
    val offsets = IntArray(grid.rows + 1)
    var total = 0L
    for ((row, height) in heights.withIndex()) {
        total += height
        if (total > TablePixelLimit) return null
        offsets[row + 1] = total.toInt()
    }
    return TablePixelLayout(columnWidth, offsets, width.toInt())
}
