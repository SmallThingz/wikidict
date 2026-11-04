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
                                      val extraColumns: Int = 0, val style: TableResolvedStyle? = null) {
    fun cellWidth(column: Int, colspan: Int): Int = columnWidth * colspan + cellSpacing * (colspan - 1) +
        minOf(column + colspan, extraColumns) - minOf(column, extraColumns)
}

internal fun tableRenderMetrics(table: Table, preferredColumnWidth: Int, defaultPadding: Int,
                                defaultMinRowHeight: Int, cssPixelScale: Float, depth: Int = 1,
                                containerFontPixels: Float? = null, decorationScale: Double = 1.0,
                                decorationViewportWidth: Int? = null, decorationViewportHeight: Int? = null): TableRenderMetrics? {
    if (depth !in 1..MaxTableDepth || preferredColumnWidth <= 0 || defaultPadding < 0 || defaultMinRowHeight <= 0 ||
        !cssPixelScale.isFinite() || cssPixelScale <= 0f) return null
    if (!decorationScale.isFinite() || decorationScale !in 0.0..1.0) return null
    fun pixels(value: Long): Int? {
        val scaled = value.toDouble() * cssPixelScale
        return if (value < 0 || !scaled.isFinite() || scaled > TablePixelLimit) null else kotlin.math.round(scaled).toInt()
    }
    val geometry = table.geometry
    if (listOfNotNull(geometry?.border, geometry?.cellSpacing, geometry?.cellPadding).any { it !in 0..65535 }) return null
    val legacyBorder = geometry?.border?.let { pixels(it.toLong()) ?: return null } ?: 0
    val legacySpacing = geometry?.cellSpacing?.let { pixels(it.toLong()) ?: return null } ?: 0
    val padding = geometry?.cellPadding?.let { pixels(it.toLong()) ?: return null } ?: defaultPadding
    val grid = runCatching { tableGrid(table) }.getOrNull() ?: return null
    val style = if (tableHasOwnStyle(table)) {
        val font = containerFontPixels ?: return null
        if (!font.isFinite() || font < 0f) return null
        val original = resolveTableStyle(table, grid, cssPixelScale, font, padding, legacyBorder, decorationScale)
        val projectedSpacing = if (original.collapse) 0 else kotlin.math.round(legacySpacing * decorationScale).toInt()
        val factor = tableDecorationProjection(grid, original, preferredColumnWidth, defaultMinRowHeight, projectedSpacing,
            decorationViewportWidth, decorationViewportHeight)
        if (factor == 1.0) original else resolveTableStyle(table, grid, cssPixelScale, font, padding, legacyBorder, decorationScale * factor)
    } else null
    val border = if (style?.collapse == true && grid.rows > 0 && grid.columns > 0) 0
        else style?.border?.width?.let { kotlin.math.ceil(it).toInt() } ?: legacyBorder
    val spacing = if (style?.collapse == true) 0 else if (style != null) kotlin.math.round(legacySpacing * style.decorationScale).toInt() else legacySpacing
    val edgeWidth = 2L * border + (grid.columns.toLong() + 1) * spacing
    val budget = TablePixelLimit - edgeWidth
    if (budget < 0 || (grid.columns > 0 && budget < grid.columns)) return null
    val preferred = if (geometry?.width?.unit == TableWidthUnit.Px) 1 else preferredColumnWidth
    var column = if (grid.columns == 0) preferred.coerceAtMost(TablePixelLimit)
        else minOf(preferred, (budget / grid.columns).toInt())
    if (grid.columns > 0 && geometry != null && style == null) {
        column = maxOf(column, 2 * (padding + border) + 1)
    }
    for ((cellIndex, placed) in grid.cells.withIndex()) {
        val cell = placed.cell
        val cellInset = style?.cellInsets?.get(cellIndex)
        val horizontalInset = cellInset?.horizontal ?: 2 * (padding + border)
        if (style != null) column = maxOf(column, (horizontalInset + placed.colspan - 1) / placed.colspan + 1)
        if (style != null && style.decorationScale < 1.0) {
            // A projection reserves native body width, rather than fitting its
            // padding by squeezing an otherwise ordinary cell down to one pixel.
            val bodyColumn = if (grid.columns == 0) preferred else minOf(preferred, TablePixelLimit / grid.columns)
            column = maxOf(column, bodyColumn + (horizontalInset + placed.colspan - 1) / placed.colspan)
        }
        val children = if (cell.blocks != null) cell.blocks.mapNotNull { block -> block.table?.let { it to blockIndentDp(block) } }
            else listOfNotNull(cell.nestedTable?.let { it to 0 })
        for ((child, indent) in children) {
            val childMetrics = tableRenderMetrics(child, preferredColumnWidth, defaultPadding,
                defaultMinRowHeight, cssPixelScale, depth + 1, containerFontPixels, decorationScale,
                decorationViewportWidth, decorationViewportHeight) ?: return null
            val indentation = pixels(indent.toLong()) ?: return null
            val needed = childMetrics.width.toLong() + (childMetrics.style?.margins?.horizontal ?: 0) + indentation + horizontalInset - (placed.colspan - 1L) * spacing
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
    return TableRenderMetrics(column, padding, spacing, border, defaultMinRowHeight, width.toInt(), extraColumns, style)
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
