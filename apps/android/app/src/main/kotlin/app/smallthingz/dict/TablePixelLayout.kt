package app.smallthingz.dict

import androidx.compose.ui.unit.Constraints

/** Paired dimensions at or below this value fit Compose Constraints' 15/16-bit pair. */
internal const val TablePixelLimit = 32766
internal data class TablePixelLayout(val columnWidth: Int, val rowOffsets: IntArray, val width: Int,
                                    val cellSpacing: Int = 0, val borderWidth: Int = 0, val extraColumns: Int = 0,
                                    val tablePadding: TablePixelInsets = TablePixelInsets(0, 0, 0, 0),
                                    val columnWidths: List<Int>? = null,
    val outerBorder: TablePixelInsets = TablePixelInsets(borderWidth, borderWidth, borderWidth, borderWidth)) {
    val height: Int get() = rowOffsets.last() + outerBorder.vertical + cellSpacing * rowOffsets.size + tablePadding.vertical
    fun cellLeft(column: Int): Int = tablePadding.left + outerBorder.left + cellSpacing + column * cellSpacing + (columnWidths?.take(column)?.sum() ?: (column * columnWidth + minOf(column, extraColumns)))
    fun physicalCellLeft(column: Int, colspan: Int, rtl: Boolean): Int = if (!rtl) cellLeft(column)
        else width - cellLeft(column) - cellWidth(colspan, column) + tablePadding.left - tablePadding.right + outerBorder.left - outerBorder.right
    fun cellWidth(colspan: Int, column: Int = 0): Int = cellSpacing * (colspan - 1) +
        (columnWidths?.subList(column, column + colspan)?.sum() ?:
            (columnWidth * colspan + minOf(column + colspan, extraColumns) - minOf(column, extraColumns)))
    fun cellTop(row: Int): Int = tablePadding.top + outerBorder.top + cellSpacing + rowOffsets[row] + row * cellSpacing
    fun cellBottom(row: Int, rowspan: Int): Int = tablePadding.top + outerBorder.top + cellSpacing +
        rowOffsets[row + rowspan] + (row + rowspan - 1) * cellSpacing
    override fun equals(other: Any?): Boolean = other is TablePixelLayout &&
        columnWidth == other.columnWidth && width == other.width && rowOffsets.contentEquals(other.rowOffsets) && cellSpacing == other.cellSpacing && borderWidth == other.borderWidth && extraColumns == other.extraColumns && tablePadding == other.tablePadding && columnWidths == other.columnWidths && outerBorder == other.outerBorder
    override fun hashCode(): Int = 31 * (31 * (31 * (31 * (31 * (31 * columnWidth + width) + rowOffsets.contentHashCode()) + cellSpacing) + borderWidth) + extraColumns) + tablePadding.hashCode() + 31 * (columnWidths?.hashCode() ?: 0) + outerBorder.hashCode()
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
                              minimumWidth: Int = 0, extraColumns: Int = 0,
                              tablePadding: TablePixelInsets = TablePixelInsets(0, 0, 0, 0),
                               columnWidths: List<Int>? = null,
    outerBorder: TablePixelInsets = TablePixelInsets(borderWidth, borderWidth, borderWidth, borderWidth)): TablePixelLayout? {
    if (columnWidth <= 0 || minRowHeight <= 0 || measuredHeights.size != grid.cells.size || grid.rows < 0 ||
        cellSpacing < 0 || borderWidth < 0 || minimumWidth < 0 || extraColumns !in 0..grid.columns ||
        listOf(tablePadding.top, tablePadding.right, tablePadding.bottom, tablePadding.left,
            outerBorder.top, outerBorder.right, outerBorder.bottom, outerBorder.left).any { it < 0 }) return null
    if (columnWidths != null && (columnWidths.size != grid.columns || extraColumns != 0 ||
        columnWidths.any { it !in 0..TablePixelLimit })) return null
    val contentWidth = columnWidths?.sumOf { it.toLong() } ?: (columnWidth.toLong() * grid.columns + extraColumns)
    val width = maxOf(minimumWidth.toLong(), contentWidth +
        (grid.columns.toLong() + 1) * cellSpacing + outerBorder.horizontal.toLong() +
        tablePadding.left.toLong() + tablePadding.right)
    if (width !in 0L..TablePixelLimit.toLong()) return null
    val heightLimit = tableHeightLimit(width.toInt()) ?: return null
    val verticalEdges = (grid.rows.toLong() + 1) * cellSpacing + outerBorder.vertical.toLong() + tablePadding.top.toLong() + tablePadding.bottom
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
    return TablePixelLayout(columnWidth, offsets, width.toInt(), cellSpacing, borderWidth, extraColumns, tablePadding, columnWidths, outerBorder)
}


/** CSS-pixel metadata is resolved in the reader density; absent fields keep native defaults. */
internal data class TableRenderMetrics(val columnWidth: Int, val cellPadding: Int, val cellSpacing: Int,
                                      val borderWidth: Int, val minRowHeight: Int, val width: Int,
                                      val extraColumns: Int = 0, val style: TableResolvedStyle? = null,
                                       val columnWidths: List<Int>? = null,
    val outerBorder: TablePixelInsets = TablePixelInsets(borderWidth, borderWidth, borderWidth, borderWidth)) {
    fun cellWidth(column: Int, colspan: Int): Int = cellSpacing * (colspan - 1) +
        (columnWidths?.subList(column, column + colspan)?.sum() ?:
            (columnWidth * colspan + minOf(column + colspan, extraColumns) - minOf(column, extraColumns)))
}

internal fun tableRenderMetrics(table: Table, preferredColumnWidth: Int, defaultPadding: Int,
                                defaultMinRowHeight: Int, cssPixelScale: Float, depth: Int = 1,
                                containerFontPixels: Float? = null, decorationScale: Double = 1.0,
                                decorationViewportWidth: Int? = null, decorationViewportHeight: Int? = null,
                                rtl: Boolean = false): TableRenderMetrics? {
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
        val original = runCatching { resolveTableStyle(table, grid, cssPixelScale, font, padding, legacyBorder, decorationScale, rtl) }
            .getOrNull() ?: return null
        val projectedSpacing = if (original.collapse) 0 else kotlin.math.round(legacySpacing * decorationScale).toInt()
        val factor = if (tableHasComputedCellStyle(table)) 1.0 else tableDecorationProjection(grid, original, preferredColumnWidth, defaultMinRowHeight, projectedSpacing,
            decorationViewportWidth, decorationViewportHeight)
        if (factor == 1.0) original else resolveTableStyle(table, grid, cssPixelScale, font, padding, legacyBorder, decorationScale * factor, rtl)
    } else null
    val border = if (style?.collapse == true && grid.rows > 0 && grid.columns > 0) 0
        else style?.border?.width?.let { kotlin.math.ceil(it).toInt() } ?: legacyBorder
    val outerBorder = if (style == null) TablePixelInsets(border, border, border, border)
        else if (style.collapse && grid.rows > 0 && grid.columns > 0) TablePixelInsets(0, 0, 0, 0)
        else style.outerEdges.let { TablePixelInsets(kotlin.math.ceil(it.top.width).toInt(), kotlin.math.ceil(it.right.width).toInt(),
            kotlin.math.ceil(it.bottom.width).toInt(), kotlin.math.ceil(it.left.width).toInt()) }
    val spacing = if (style?.collapse == true) 0 else if (style != null) kotlin.math.round(legacySpacing * style.decorationScale).toInt() else legacySpacing
    val tablePadding = style?.tablePadding ?: TablePixelInsets(0, 0, 0, 0)
    val edgeWidth = outerBorder.horizontal.toLong() + (grid.columns.toLong() + 1) * spacing + tablePadding.horizontal
    val budget = TablePixelLimit - edgeWidth
    if (budget < 0 || (grid.columns > 0 && budget < grid.columns)) return null
    val cssWidth = table.style?.width
    val preferred = if (cssWidth != null || geometry?.width?.unit == TableWidthUnit.Px) 1 else preferredColumnWidth
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
                decorationViewportWidth, decorationViewportHeight, rtl) ?: return null
            val indentation = pixels(indent.toLong()) ?: return null
            val needed = childMetrics.width.toLong() + (childMetrics.style?.margins?.horizontal ?: 0) + indentation + horizontalInset - (placed.colspan - 1L) * spacing
            val perColumn = ((needed.coerceAtLeast(0) + placed.colspan - 1) / placed.colspan)
            if (perColumn > Int.MAX_VALUE) return null
            column = maxOf(column, perColumn.toInt())
        }
    }
    var width = edgeWidth + grid.columns.toLong() * column
    var extraColumns = 0
    val authoredWidth = geometry?.width.takeIf { cssWidth == null }
    if (cssWidth != null && cssWidth.unit != StyleWidthUnit.Percent) {
        val basis = if (cssWidth.unit == StyleWidthUnit.Px) cssPixelScale else containerFontPixels ?: return null
        val scaled = cssWidth.value.toDouble() * basis
        if (!scaled.isFinite() || scaled > TablePixelLimit) return null
        val wanted = kotlin.math.round(scaled).toLong()
        if (grid.columns == 0) width = maxOf(width, wanted) else if (wanted > width) {
            val content = wanted - edgeWidth
            column = (content / grid.columns).toInt()
            extraColumns = (content % grid.columns).toInt()
            width = wanted
        }
    }
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
    return TableRenderMetrics(column, padding, spacing, border, defaultMinRowHeight, width.toInt(), extraColumns, style, outerBorder = outerBorder)
}

/** Percent widths use the allocated containing cell, and never shrink stored child grids. */
internal fun tableMetricsInWidth(table: Table, metrics: TableRenderMetrics, columns: Int,
                                 availableWidth: Int?): TableRenderMetrics? {
    val css = table.style?.width
    val legacy = table.geometry?.width.takeIf { css == null }
    if (css?.unit != StyleWidthUnit.Percent && legacy?.unit != TableWidthUnit.Percent || availableWidth == null) return metrics
    if (availableWidth < 0 || legacy != null && legacy.value !in 0..100) return null
    val scaled = availableWidth.toDouble() * (css?.value?.toDouble() ?: legacy!!.value.toDouble()) / 100.0
    if (!scaled.isFinite() || scaled > TablePixelLimit) return null
    val target = if (css != null) kotlin.math.round(scaled).toLong() else scaled.toLong()
    if (target <= metrics.width) return metrics
    val edges = metrics.outerBorder.horizontal.toLong() + (columns.toLong() + 1) * metrics.cellSpacing + (metrics.style?.tablePadding?.horizontal ?: 0)
    if (target > TablePixelLimit) return null
    if (columns == 0) return metrics.copy(width = target.toInt())
    val content = (target - edges).coerceAtLeast(0)
    // Distribute residual pixels rather than rounding every column up beyond its containing cell.
    return metrics.copy(columnWidth = (content / columns).toInt(), width = target.toInt(),
        extraColumns = (content % columns).toInt())
}

/**
 * Call only with min/max widths measured from the
 * exact intrinsic-safe cell subtree, including its resolved padding/borders.
 * Never substitute the legacy preferred column width for an unknown intrinsic.
 */
internal data class TableCellWidthPreference(val pixels: Int? = null, val percent: Double? = null,
    val horizontalInsets: Int = 0, val minimumPixels: Int = 0) {
    init {
        require(pixels == null || pixels >= 0)
        require(percent == null || percent.isFinite() && percent >= 0.0)
        require(pixels == null || percent == null)
        require(horizontalInsets >= 0 && minimumPixels >= 0)
    }
}

internal fun tableCellWidthPreferences(grid: TableGrid, insets: List<TablePixelInsets>?,
    fallbackInset: Int, density: Float, normalBodyPixels: Float): List<TableCellWidthPreference> =
    grid.cells.mapIndexed { index, cell ->
        val width = cell.cell.style?.width
        val horizontal = insets?.get(index)?.horizontal ?: fallbackInset
        val minimum = cell.cell.style?.minWidth?.let {
            kotlin.math.ceil(exactCellStylePixels(it, density, normalBodyPixels)).toInt()
        } ?: 0
        when (width?.unit) {
            null -> TableCellWidthPreference(horizontalInsets = horizontal, minimumPixels = minimum)
            StyleWidthUnit.Percent -> TableCellWidthPreference(percent = width.value.toDouble(), horizontalInsets = horizontal, minimumPixels = minimum)
            StyleWidthUnit.Px, StyleWidthUnit.Em -> TableCellWidthPreference(pixels = kotlin.math.ceil(exactCellStylePixels(
                StyleLength(if (width.unit == StyleWidthUnit.Px) StyleLengthUnit.Px else StyleLengthUnit.Em, width.value),
                density, normalBodyPixels)).toInt(), horizontalInsets = horizontal, minimumPixels = minimum)
        }
    }

internal fun inlineTableColumnWidths(
    grid: TableGrid,
    minimumCells: IntArray,
    maximumCells: IntArray,
    cellSpacing: Int,
    outerEdges: Int,
    availableWidth: Int,
    authoredWidth: Int? = null,
    cellPreferences: List<TableCellWidthPreference>? = null,
): List<Int>? {
    if (grid.columns !in 1..512 || grid.cells.isEmpty() ||
        minimumCells.size != grid.cells.size || maximumCells.size != grid.cells.size ||
        cellSpacing < 0 || outerEdges < 0 || availableWidth < 0 ||
        authoredWidth != null && authoredWidth < 0 ||
        cellPreferences != null && cellPreferences.size != grid.cells.size) return null
    val minimum = LongArray(grid.columns) { 0L }
    val maximum = LongArray(grid.columns) { 0L }
    val order = grid.cells.indices.sortedWith(compareBy<Int> { grid.cells[it].colspan }.thenBy { it })
    fun satisfy(widths: LongArray, index: Int, requested: Int): Boolean {
        val cell = grid.cells[index]
        val end = cell.column.toLong() + cell.colspan
        if (cell.column < 0 || cell.colspan <= 0 || end > grid.columns || requested < 0 ||
            requested == Int.MAX_VALUE) return false
        val required = (requested.toLong() - (cell.colspan - 1L) * cellSpacing).coerceAtLeast(0)
        var present = 0L
        for (column in cell.column until end.toInt()) present += widths[column]
        val missing = (required - present).coerceAtLeast(0)
        val each = missing / cell.colspan
        val remainder = (missing % cell.colspan).toInt()
        for (column in cell.column until end.toInt())
            widths[column] += each + if (column - cell.column < remainder) 1 else 0
        return true
    }
    for (index in order) {
        val request = cellPreferences?.get(index)
        val specified = request?.pixels?.toLong()?.plus(request.horizontalInsets) ?: 0L
        val authoredFloor = request?.minimumPixels?.toLong()?.plus(request.horizontalInsets) ?: 0L
        if (specified > TablePixelLimit || authoredFloor > TablePixelLimit || maximumCells[index] < minimumCells[index] ||
            !satisfy(minimum, index, maxOf(minimumCells[index], specified.toInt(), authoredFloor.toInt()))) return null
    }
    minimum.copyInto(maximum)
    for (index in order) if (!satisfy(maximum, index, maximumCells[index])) return null
    val minimumWidth = minimum.sum() + outerEdges
    val maximumWidth = maximum.sum() + outerEdges
    if (minimumWidth > TablePixelLimit) return null
    val target = if (authoredWidth == null)
        maxOf(minimumWidth, minOf(availableWidth.toLong(), maximumWidth))
    else maxOf(minimumWidth, authoredWidth.toLong())
    if (target !in minimumWidth..TablePixelLimit.toLong()) return null
    val contentTarget = target - outerEdges
    val result = minimum.copyOf()
    // Percentages constrain this table's assignable grid width. They never use
    // the viewport, and an over-constrained percentage cannot erase real content minima.
    val percentWidths = minimum.copyOf()
    for (index in order) {
        val request = cellPreferences?.get(index) ?: continue
        val percent = request.percent ?: continue
        val wanted = contentTarget.toDouble() * percent / 100.0 + request.horizontalInsets
        if (!wanted.isFinite()) return null
        // Values above 100% remain distinct in the model; their achievable share
        // is bounded by the actual used table width, not a rewritten percentage.
        val bounded = kotlin.math.ceil(wanted).coerceAtMost(contentTarget.toDouble()).toInt()
        if (!satisfy(percentWidths, index, bounded)) return null
    }
    fun distribute(toward: LongArray, budget: Long) {
        val flexibility = LongArray(grid.columns) { (toward[it] - result[it]).coerceAtLeast(0) }
        val total = flexibility.sum()
        val grow = minOf(budget, total)
        if (grow <= 0 || total <= 0) return
        var distributed = 0L
        val residuals = LongArray(grid.columns)
        for (column in result.indices) {
            val numerator = flexibility[column] * grow
            val share = numerator / total
            result[column] += share; distributed += share; residuals[column] = numerator % total
        }
        result.indices.sortedWith(compareByDescending<Int> { residuals[it] }.thenBy { it })
            .take((grow - distributed).toInt()).forEach { result[it]++ }
    }
    distribute(percentWidths, contentTarget - result.sum())
    distribute(maximum, contentTarget - result.sum())
    val beyondMaximum = contentTarget - result.sum()
    if (beyondMaximum > 0) {
        val each = beyondMaximum / grid.columns
        val remainder = (beyondMaximum % grid.columns).toInt()
        for (column in result.indices) result[column] += each + if (column < remainder) 1 else 0
    }
    if (result.sum() + outerEdges != target || result.any { it !in 0..TablePixelLimit.toLong() }) return null
    return result.map { it.toInt() }
}

internal fun inlineTableMetrics(natural: TableRenderMetrics, grid: TableGrid, minimumCells: IntArray,
    maximumCells: IntArray, availableWidth: Int, authoredWidth: Int? = null,
    cellPreferences: List<TableCellWidthPreference>? = null): TableRenderMetrics? {
    val edges = natural.outerBorder.horizontal.toLong() + (grid.columns.toLong() + 1) * natural.cellSpacing +
        (natural.style?.tablePadding?.horizontal ?: 0)
    if (edges !in 0L..TablePixelLimit.toLong()) return null
    val columns = inlineTableColumnWidths(grid, minimumCells, maximumCells, natural.cellSpacing,
        edges.toInt(), availableWidth, authoredWidth, cellPreferences) ?: return null
    return natural.copy(columnWidth = 1, extraColumns = 0, columnWidths = columns,
        width = columns.sum() + edges.toInt())
}

internal data class InlineTableLinePixels(val height: Int, val baseline: Int, val tableTop: Int, val markerTop: Int)

/** One atomic table and the existing list marker share the parent's strut.
 * Top alignment includes the complete table margin box and minimizes the line
 * height. If the table is taller, keep the strut at the top of that line; CSS
 * does not prescribe a unique baseline in that case (CSS 2.2 section 10.8).
 */
internal fun inlineTableLinePixels(strutHeight: Int, strutBaseline: Float, tableHeight: Int,
    tableBaseline: Float, align: InlineBoxVerticalAlign?, markerHeight: Int? = null,
    markerBaseline: Int = 0): InlineTableLinePixels {
    val limit = Int.MAX_VALUE / 8
    require(strutHeight in 0..limit && tableHeight in 0..limit &&
        (markerHeight == null || markerHeight in 0..limit) && markerBaseline in -limit..limit)
    require(strutBaseline.isFinite() && tableBaseline.isFinite() &&
        kotlin.math.abs(strutBaseline) <= limit && kotlin.math.abs(tableBaseline) <= limit)
    val markerTop = kotlin.math.round(strutBaseline - markerBaseline).toInt()
    val ordinaryTop = minOf(0, if (markerHeight == null) 0 else markerTop)
    val gridTop = if (align == InlineBoxVerticalAlign.Top) ordinaryTop
        else kotlin.math.round(strutBaseline - tableBaseline).toInt()
    val top = minOf(ordinaryTop, gridTop)
    val bottom = maxOf(strutHeight, gridTop + tableHeight,
        if (markerHeight == null) 0 else markerTop + markerHeight)
    return InlineTableLinePixels(bottom - top, kotlin.math.round(strutBaseline - top).toInt(),
        gridTop - top, markerTop - top)
}
