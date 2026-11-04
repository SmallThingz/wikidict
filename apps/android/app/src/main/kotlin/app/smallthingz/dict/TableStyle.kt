package app.smallthingz.dict

import kotlin.math.ceil
import kotlin.math.roundToInt

internal data class TablePixelInsets(val top: Int, val right: Int, val bottom: Int, val left: Int) {
    val horizontal: Int get() = left + right
    val vertical: Int get() = top + bottom
}
internal data class TableStyleBorder(val width: Float, val color: String?)
internal data class TableResolvedStyle(val background: String?, val border: TableStyleBorder,
    val collapse: Boolean, val margins: TablePixelInsets, val cellBorders: List<TableStyleBorder>,
    val cellInsets: List<TablePixelInsets>, val decorationScale: Double = 1.0)
private data class TableEdge(val vertical: Boolean, val fixed: Int, val interval: Int)
private data class TableEdgeCandidate(val border: TableStyleBorder, val priority: Int)
private fun collapsedBorderWinners(grid: TableGrid, borders: List<TableStyleBorder>, outer: TableStyleBorder): Map<TableEdge, TableEdgeCandidate> {
    val edges = linkedMapOf<TableEdge, TableEdgeCandidate>()
    fun put(edge: TableEdge, border: TableStyleBorder, priority: Int) {
        if (border.width <= 0f) return
        val old = edges[edge]
        if (old == null || border.width > old.border.width || (border.width == old.border.width && priority > old.priority))
            edges[edge] = TableEdgeCandidate(border, priority)
    }
    for (row in 0 until grid.rows) {
        put(TableEdge(true, 0, row), outer, 0); put(TableEdge(true, grid.columns, row), outer, 0)
    }
    for (column in 0 until grid.columns) {
        put(TableEdge(false, 0, column), outer, 0); put(TableEdge(false, grid.rows, column), outer, 0)
    }
    grid.cells.forEachIndexed { index, cell ->
        val border = borders[index]
        for (row in cell.row until cell.row + cell.cell.rowspan) {
            put(TableEdge(true, cell.column, row), border, 1); put(TableEdge(true, cell.column + cell.colspan, row), border, 1)
        }
        for (column in cell.column until cell.column + cell.colspan) {
            put(TableEdge(false, cell.row, column), border, 1); put(TableEdge(false, cell.row + cell.cell.rowspan, column), border, 1)
        }
    }
    return edges
}

/** CSS px uses display density; em uses the configured cell-container font in
 * physical pixels. The render-only ceiling agrees with semantic font rendering;
 * the original finite binary32 value, including zero, remains in the model. */
internal fun tableStyleLengthPixels(value: StyleLength, density: Float, containerFontPixels: Float): Float {
    require(density.isFinite() && density > 0f && containerFontPixels.isFinite() && containerFontPixels >= 0f)
    val unit = if (value.unit == StyleLengthUnit.Px) density else containerFontPixels
    return (value.value.toDouble() * unit.toDouble()).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
}
internal fun tableHasOwnStyle(table: Table): Boolean = table.style != null || table.rows.any { row -> row.any { it.style != null } }
internal fun tableStyleEdgesPixels(value: StyleEdges, density: Float, containerFontPixels: Float,
    decorationScale: Double = 1.0): TablePixelInsets {
    fun length(value: StyleLength) = (tableStyleLengthPixels(value, density, containerFontPixels) * decorationScale).roundToInt()
    return TablePixelInsets(length(value.top), length(value.right), length(value.bottom), length(value.left))
}
internal fun resolveTableStyle(table: Table, grid: TableGrid, density: Float, containerFontPixels: Float,
    defaultPadding: Int, legacyBorder: Int, decorationScale: Double = 1.0): TableResolvedStyle {
    require(decorationScale.isFinite() && decorationScale in 0.0..1.0)
    fun length(value: StyleLength) = (tableStyleLengthPixels(value, density, containerFontPixels) * decorationScale).toFloat()
    fun edges(value: StyleEdges) = tableStyleEdgesPixels(value, density, containerFontPixels, decorationScale)
    fun border(value: StyleBorder?): TableStyleBorder = when (value) {
        null -> TableStyleBorder((legacyBorder * decorationScale).toFloat(), null)
        StyleBorder.None -> TableStyleBorder(0f, null)
        is StyleBorder.Solid -> TableStyleBorder(length(value.width), value.color)
    }
    val collapse = table.style?.collapse == TableCollapse.Collapse
    val borders = grid.cells.map { border(it.cell.style?.border) }
    val outer = border(table.style?.border)
    val winners = if (collapse) collapsedBorderWinners(grid, borders, outer) else emptyMap()
    val insets = grid.cells.mapIndexed { index, placed ->
        val fallback = (defaultPadding * decorationScale).roundToInt()
        val p = placed.cell.style?.padding?.let(::edges) ?: TablePixelInsets(fallback, fallback, fallback, fallback)
        if (!collapse) {
            val stroke = ceil(borders[index].width).toInt()
            TablePixelInsets(p.top + stroke, p.right + stroke, p.bottom + stroke, p.left + stroke)
        } else {
            fun horizontal(row: Int) = (placed.column until placed.column + placed.colspan).maxOfOrNull {
                winners[TableEdge(false, row, it)]?.border?.width ?: 0f
            } ?: 0f
            fun vertical(column: Int) = (placed.row until placed.row + placed.cell.rowspan).maxOfOrNull {
                winners[TableEdge(true, column, it)]?.border?.width ?: 0f
            } ?: 0f
            TablePixelInsets(p.top + ceil(horizontal(placed.row) / 2f).toInt(),
                p.right + ceil(vertical(placed.column + placed.colspan) / 2f).toInt(),
                p.bottom + ceil(horizontal(placed.row + placed.cell.rowspan) / 2f).toInt(),
                p.left + ceil(vertical(placed.column) / 2f).toInt())
        }
    }
    return TableResolvedStyle(table.style?.background, outer, collapse,
        table.style?.margins?.let(::edges) ?: TablePixelInsets(0, 0, 0, 0), borders, insets, decorationScale)
}

/** Reserve the existing native body columns/rows before allocating decoration.
 * If necessary one factor reduces the whole grid's borders, padding, margins and
 * spacing. Colors/alignment, model values and every body node stay unchanged. */
internal fun tableDecorationProjection(grid: TableGrid, style: TableResolvedStyle,
    preferredColumnWidth: Int, minRowHeight: Int, spacing: Int,
    availableWidth: Int? = null, availableHeight: Int? = null): Double {
    val columns = maxOf(1, grid.columns)
    val bodyWidth = minOf(preferredColumnWidth, TablePixelLimit / columns) * grid.columns
    val bodyHeightBound = tableHeightLimit(maxOf(1, bodyWidth)) ?: return 1.0
    val bodyHeight = grid.rows.toLong() * minRowHeight
    if (bodyHeight > bodyHeightBound) return 1.0 // Existing body-size limitation, independent of decoration.
    val columnCost = LongArray(grid.columns)
    val rowCost = LongArray(grid.rows)
    grid.cells.forEachIndexed { index, cell ->
        val inset = style.cellInsets[index]
        val horizontal = (inset.horizontal.toLong() + cell.colspan - 1) / cell.colspan
        val vertical = (inset.vertical.toLong() + cell.cell.rowspan - 1) / cell.cell.rowspan
        for (column in cell.column until cell.column + cell.colspan) columnCost[column] = maxOf(columnCost[column], horizontal)
        for (row in cell.row until cell.row + cell.cell.rowspan) rowCost[row] = maxOf(rowCost[row], vertical)
    }
    val outer = if (style.collapse && grid.rows > 0 && grid.columns > 0) 0L else ceil(style.border.width).toLong() * 2
    val horizontal = columnCost.sum() + outer + style.margins.horizontal + (grid.columns.toLong() + 1) * spacing
    val vertical = rowCost.sum() + outer + style.margins.vertical + (grid.rows.toLong() + 1) * spacing
    val widthBudget = (TablePixelLimit - bodyWidth).toLong()
    // A wide grid may scroll normally. Bound the decoration around any one cell,
    // not the sum of all body columns, against the actual containing viewport.
    val visibleHorizontal = (style.cellInsets.maxOfOrNull { it.horizontal } ?: 0).toLong() + outer + style.margins.horizontal + 2L * spacing
    val visibleVertical = (style.cellInsets.maxOfOrNull { it.vertical } ?: 0).toLong() + outer + style.margins.vertical + 2L * spacing
    fun viewportScale(available: Int?, preferredBody: Int, cost: Long): Double {
        if (available == null || cost == 0L) return 1.0
        if (available <= 0) return 0.0
        val body = minOf(preferredBody, maxOf(1, available / 2))
        val budget = (available - body).toLong()
        if (cost <= budget) return 1.0
        // One rounding pixel for both sides of padding, margin, border and gap.
        return (budget - 8).coerceAtLeast(0).toDouble() / cost
    }
    val viewport = minOf(viewportScale(availableWidth, preferredColumnWidth, visibleHorizontal),
        viewportScale(availableHeight, minRowHeight, visibleVertical))
    // Leave one integer-pixel rounding reserve at each projected grid boundary.
    val widthScale = if (horizontal <= widthBudget) 1.0 else ((widthBudget - 2L * (grid.columns + 1)).coerceAtLeast(0)).toDouble() / horizontal
    val factor = minOf(1.0, widthScale, viewport)
    // Compose's paired height capacity depends on the resulting width. A narrow
    // scrolling table must not inherit the capacity of a 32766-pixel-wide grid.
    val projectedOuter = if (style.collapse && grid.rows > 0 && grid.columns > 0) 0L else ceil(style.border.width * factor).toLong() * 2
    val projectedGap = (spacing * factor).roundToInt()
    val edgeWidth = projectedOuter + (grid.columns.toLong() + 1) * projectedGap
    val nativeColumn = minOf(preferredColumnWidth, TablePixelLimit / columns)
    val insetColumn = grid.cells.indices.maxOfOrNull { index ->
        ceil(style.cellInsets[index].horizontal * factor / grid.cells[index].colspan).toInt()
    } ?: 0
    val column = if (factor < 1.0) nativeColumn + insetColumn else maxOf(nativeColumn, insetColumn + 1)
    val estimatedWidth = (edgeWidth + grid.columns.toLong() * column).coerceIn(1L, TablePixelLimit.toLong()).toInt()
    val heightBudget = (tableHeightLimit(estimatedWidth) ?: return factor) - bodyHeight
    if (vertical * factor <= heightBudget) return factor
    val heightScale = if (vertical == 0L) 1.0 else ((heightBudget - 2L * (grid.rows + 1)).coerceAtLeast(0)).toDouble() / vertical
    return minOf(factor, heightScale)
}

internal fun tableContainsStyle(table: Table): Boolean = tableHasOwnStyle(table) || table.rows.any { row -> row.any { cell ->
    cell.nestedTable?.let(::tableContainsStyle) == true || cell.blocks?.any { it.table?.let(::tableContainsStyle) == true } == true
} }

internal data class TableBorderSegment(val x1: Float, val y1: Float, val x2: Float, val y2: Float,
    val width: Float, val color: String?)

/** Resolve solid/none conflicts once per shared edge: wider wins, then cell over
 * table, then the first authored cell. No doubled adjacent collapsed strokes. */
internal fun collapsedTableBorders(grid: TableGrid, pixels: TablePixelLayout,
    style: TableResolvedStyle): List<TableBorderSegment> {
    if (grid.rows == 0 || grid.columns == 0) {
        val width = style.border.width
        if (width <= 0f) return emptyList()
        val inset = width / 2f
        return listOf(TableBorderSegment(inset, inset, pixels.width - inset, inset, width, style.border.color),
            TableBorderSegment(inset, pixels.height - inset, pixels.width - inset, pixels.height - inset, width, style.border.color),
            TableBorderSegment(inset, inset, inset, pixels.height - inset, width, style.border.color),
            TableBorderSegment(pixels.width - inset, inset, pixels.width - inset, pixels.height - inset, width, style.border.color))
    }
    val edges = collapsedBorderWinners(grid, style.cellBorders, style.border)
    fun x(column: Int): Float = if (column == grid.columns) pixels.width.toFloat() else pixels.cellLeft(column).toFloat()
    fun y(row: Int): Float = if (row == grid.rows) pixels.height.toFloat() else pixels.cellTop(row).toFloat()
    return edges.map { (edge, winner) ->
        val width = winner.border.width
        if (edge.vertical) {
            val at = when (edge.fixed) { 0 -> width / 2f; grid.columns -> pixels.width - width / 2f; else -> x(edge.fixed) }
            TableBorderSegment(at, y(edge.interval), at, y(edge.interval + 1), width, winner.border.color)
        } else {
            val at = when (edge.fixed) { 0 -> width / 2f; grid.rows -> pixels.height - width / 2f; else -> y(edge.fixed) }
            TableBorderSegment(x(edge.interval), at, x(edge.interval + 1), at, width, winner.border.color)
        }
    }
}
