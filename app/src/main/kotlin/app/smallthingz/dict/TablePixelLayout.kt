package app.smallthingz.dict

import androidx.compose.ui.unit.Constraints

/** Paired dimensions at or below this value fit Compose Constraints' 15/16-bit pair. */
internal const val TablePixelLimit = 32766
internal data class TablePixelLayout(val columnWidth: Int, val rowOffsets: IntArray, val width: Int,
                                    val cellSpacing: Int = 0, val borderWidth: Int = 0, val extraColumns: Int = 0) {
    val height: Int get() = rowOffsets.last() + 2 * borderWidth + cellSpacing * rowOffsets.size
    fun cellLeft(column: Int): Int = borderWidth + cellSpacing + column * (columnWidth + cellSpacing) + minOf(column, extraColumns)
    fun cellWidth(colspan: Int, column: Int = 0): Int = columnWidth * colspan + cellSpacing * (colspan - 1) +
        minOf(column + colspan, extraColumns) - minOf(column, extraColumns)
    fun cellTop(row: Int): Int = borderWidth + cellSpacing + rowOffsets[row] + row * cellSpacing
    fun cellBottom(row: Int, rowspan: Int): Int = borderWidth + cellSpacing +
        rowOffsets[row + rowspan] + (row + rowspan - 1) * cellSpacing
    override fun equals(other: Any?): Boolean = other is TablePixelLayout &&
        columnWidth == other.columnWidth && width == other.width && rowOffsets.contentEquals(other.rowOffsets) && cellSpacing == other.cellSpacing && borderWidth == other.borderWidth && extraColumns == other.extraColumns
    override fun hashCode(): Int = 31 * (31 * (31 * (31 * (31 * columnWidth + width) + rowOffsets.contentHashCode()) + cellSpacing) + borderWidth) + extraColumns
}
internal fun tableColumnWidth(columns: Int, preferred: Int): Int? {
    if (columns !in 0..512 || preferred <= 0) return null
    return if (columns == 0) preferred.coerceAtMost(TablePixelLimit)
        else minOf(preferred, TablePixelLimit / columns).takeIf { it > 0 }
}
/** Preserve the finite table width and ask Compose for its paired height capacity. */
internal fun tableHeightLimit(width: Int): Int? {
    if (width !in 0..TablePixelLimit) return null
    return Constraints.fitPrioritizingWidth(minWidth = width, maxWidth = width,
        minHeight = 0, maxHeight = Int.MAX_VALUE - 1).maxHeight
}
/** Null is an explicit unavailable layout, never permission to clip stored cells. */
internal fun tablePixelLayout(grid: TableGrid, columnWidth: Int, minRowHeight: Int,
                             measuredHeights: IntArray, cellSpacing: Int = 0, borderWidth: Int = 0,
                             minimumWidth: Int = 0, extraColumns: Int = 0): TablePixelLayout? {
    if (columnWidth <= 0 || minRowHeight <= 0 || measuredHeights.size != grid.cells.size || grid.rows < 0 ||
        cellSpacing < 0 || borderWidth < 0 || minimumWidth < 0 || extraColumns !in 0..grid.columns) return null
    val width = maxOf(minimumWidth.toLong(), columnWidth.toLong() * grid.columns +
        (grid.columns.toLong() + 1) * cellSpacing + 2L * borderWidth + extraColumns)
    if (width !in 0L..TablePixelLimit.toLong()) return null
    val heightLimit = tableHeightLimit(width.toInt()) ?: return null
    val verticalEdges = (grid.rows.toLong() + 1) * cellSpacing + 2L * borderWidth
    if (grid.rows.toLong() * minRowHeight + verticalEdges > heightLimit) return null
    val heights = LongArray(grid.rows) { minRowHeight.toLong() }
    for ((index, placed) in grid.cells.withIndex()) {
        val end = placed.row.toLong() + placed.cell.rowspan
        if (placed.row < 0 || end > grid.rows || end <= placed.row || measuredHeights[index] !in 0 until heightLimit) return null
        var available = (placed.cell.rowspan - 1L) * cellSpacing
        for (row in placed.row until end.toInt()) available += heights[row]
        if (measuredHeights[index].toLong() > available) {
            heights[end.toInt() - 1] += measuredHeights[index].toLong() - available
        }
    }
    val offsets = IntArray(grid.rows + 1)
    var total = 0L
    for ((row, height) in heights.withIndex()) {
        total += height
        if (total + verticalEdges > heightLimit) return null
        offsets[row + 1] = total.toInt()
    }
    return TablePixelLayout(columnWidth, offsets, width.toInt(), cellSpacing, borderWidth, extraColumns)
}


/** CSS-pixel metadata is resolved in the reader density; absent fields keep native defaults. */
internal data class TableRenderMetrics(val columnWidth: Int, val cellPadding: Int, val cellSpacing: Int,
                                      val borderWidth: Int, val minRowHeight: Int, val width: Int,
                                      val extraColumns: Int = 0) {
    fun cellWidth(column: Int, colspan: Int): Int = columnWidth * colspan + cellSpacing * (colspan - 1) +
        minOf(column + colspan, extraColumns) - minOf(column, extraColumns)
}

internal fun tableRenderMetrics(table: Table, preferredColumnWidth: Int, defaultPadding: Int,
                                defaultMinRowHeight: Int, cssPixelScale: Float, depth: Int = 1): TableRenderMetrics? {
    if (depth !in 1..MaxTableDepth || preferredColumnWidth <= 0 || defaultPadding < 0 || defaultMinRowHeight <= 0 ||
        !cssPixelScale.isFinite() || cssPixelScale <= 0f) return null
    fun pixels(value: Long): Int? {
        val scaled = value.toDouble() * cssPixelScale
        return if (value < 0 || !scaled.isFinite() || scaled > TablePixelLimit) null else kotlin.math.round(scaled).toInt()
    }
    val geometry = table.geometry
    if (listOfNotNull(geometry?.border, geometry?.cellSpacing, geometry?.cellPadding).any { it !in 0..65535 }) return null
    val border = geometry?.border?.let { pixels(it.toLong()) ?: return null } ?: 0
    val spacing = geometry?.cellSpacing?.let { pixels(it.toLong()) ?: return null } ?: 0
    val padding = geometry?.cellPadding?.let { pixels(it.toLong()) ?: return null } ?: defaultPadding
    val grid = runCatching { tableGrid(table) }.getOrNull() ?: return null
    val edgeWidth = 2L * border + (grid.columns.toLong() + 1) * spacing
    val budget = TablePixelLimit - edgeWidth
    if (budget < 0 || (grid.columns > 0 && budget < grid.columns)) return null
    val preferred = if (geometry?.width?.unit == TableWidthUnit.Px) 1 else preferredColumnWidth
    var column = if (grid.columns == 0) preferred.coerceAtMost(TablePixelLimit)
        else minOf(preferred, (budget / grid.columns).toInt())
    if (grid.columns > 0 && geometry != null) {
        column = maxOf(column, 2 * (padding + border) + 1)
    }
    for (placed in grid.cells) {
        val cell = placed.cell
        val children = if (cell.blocks != null) cell.blocks.mapNotNull { block -> block.table?.let { it to blockIndentDp(block) } }
            else listOfNotNull(cell.nestedTable?.let { it to 0 })
        for ((child, indent) in children) {
            val childMetrics = tableRenderMetrics(child, preferredColumnWidth, defaultPadding,
                defaultMinRowHeight, cssPixelScale, depth + 1) ?: return null
            val indentation = pixels(indent.toLong()) ?: return null
            val needed = childMetrics.width.toLong() + indentation + 2L * (padding + border) - (placed.colspan - 1L) * spacing
            val perColumn = ((needed.coerceAtLeast(0) + placed.colspan - 1) / placed.colspan)
            if (perColumn > Int.MAX_VALUE) return null
            column = maxOf(column, perColumn.toInt())
        }
    }
    var width = edgeWidth + grid.columns.toLong() * column
    var extraColumns = 0
    val authoredWidth = geometry?.width
    if (authoredWidth != null) {
        if (authoredWidth.value !in 0..0xffffffffL ||
            (authoredWidth.unit == TableWidthUnit.Percent && authoredWidth.value > 100)) return null
        if (authoredWidth.unit == TableWidthUnit.Px) {
            val wanted = pixels(authoredWidth.value) ?: return null
            if (grid.columns == 0) width = maxOf(width, wanted.toLong()) else if (wanted > width) {
                val content = wanted - edgeWidth
                column = (content / grid.columns).toInt()
                extraColumns = (content % grid.columns).toInt()
                width = wanted.toLong()
            }
        }
    }
    if (width > TablePixelLimit) return null
    return TableRenderMetrics(column, padding, spacing, border, defaultMinRowHeight, width.toInt(), extraColumns)
}

/** Percent widths use the allocated containing cell, and never shrink stored child grids. */
internal fun tableMetricsInWidth(table: Table, metrics: TableRenderMetrics, columns: Int,
                                 availableWidth: Int?): TableRenderMetrics? {
    val width = table.geometry?.width ?: return metrics
    if (width.unit != TableWidthUnit.Percent || availableWidth == null) return metrics
    if (width.value !in 0..100 || availableWidth < 0) return null
    val target = availableWidth.toLong() * width.value / 100
    if (target <= metrics.width) return metrics
    val edges = 2L * metrics.borderWidth + (columns.toLong() + 1) * metrics.cellSpacing
    if (target > TablePixelLimit) return null
    if (columns == 0) return metrics.copy(width = target.toInt())
    val content = (target - edges).coerceAtLeast(0)
    // Distribute residual pixels rather than rounding every column up beyond its containing cell.
    return metrics.copy(columnWidth = (content / columns).toInt(), width = target.toInt(),
        extraColumns = (content % columns).toInt())
}
