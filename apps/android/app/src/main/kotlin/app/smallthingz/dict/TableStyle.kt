package app.smallthingz.dict

import kotlin.math.ceil
import kotlin.math.roundToInt

internal data class TablePixelInsets(val top: Int, val right: Int, val bottom: Int, val left: Int) {
    val horizontal: Int get() = left + right
    val vertical: Int get() = top + bottom
}
internal enum class TableStroke { None, Dotted, Solid, Double, Hidden }
internal data class TableStyleBorder(val width: Float, val color: String?,
    val stroke: TableStroke = if (width > 0f) TableStroke.Solid else TableStroke.None)
internal data class TableCellBorders(val top: TableStyleBorder, val right: TableStyleBorder,
    val bottom: TableStyleBorder, val left: TableStyleBorder)
internal data class TableResolvedStyle(val background: String?, val border: TableStyleBorder,
    val collapse: Boolean, val margins: TablePixelInsets, val cellBorders: List<TableStyleBorder>,
    val cellInsets: List<TablePixelInsets>, val decorationScale: Double = 1.0,
    val tablePadding: TablePixelInsets = TablePixelInsets(0, 0, 0, 0),
    val cellEdges: List<TableCellBorders> = cellBorders.map { TableCellBorders(it, it, it, it) },
    val rtl: Boolean = false,
    val outerEdges: TableCellBorders = TableCellBorders(border, border, border, border),
    val cornerRadii: NativeCornerRadii? = null)
private data class TableEdge(val vertical: Boolean, val fixed: Int, val interval: Int)
private data class TableEdgeCandidate(val border: TableStyleBorder, val priority: Int)
private fun collapsedBorderWinners(grid: TableGrid, borders: List<TableCellBorders>, outer: TableCellBorders, rtl: Boolean): Map<TableEdge, TableEdgeCandidate> {
    val edges = linkedMapOf<TableEdge, TableEdgeCandidate>()
    fun put(edge: TableEdge, border: TableStyleBorder, priority: Int) {
        // none loses before width. Exact ties retain the first cell in source order:
        // top first, then the start-side cell (left in LTR, right in RTL).
        if (border.stroke == TableStroke.None) return
        val old = edges[edge]
        if (old == null || border.stroke == TableStroke.Hidden && old.border.stroke != TableStroke.Hidden ||
            old.border.stroke != TableStroke.Hidden && (border.width > old.border.width || (border.width == old.border.width &&
                (border.stroke.ordinal > old.border.stroke.ordinal ||
                    border.stroke == old.border.stroke && priority > old.priority))))
            edges[edge] = TableEdgeCandidate(border, priority)
    }
    for (row in 0 until grid.rows) {
        put(TableEdge(true, 0, row), if (rtl) outer.right else outer.left, 0)
        put(TableEdge(true, grid.columns, row), if (rtl) outer.left else outer.right, 0)
    }
    for (column in 0 until grid.columns) {
        put(TableEdge(false, 0, column), outer.top, 0); put(TableEdge(false, grid.rows, column), outer.bottom, 0)
    }
    grid.cells.forEachIndexed { index, cell ->
        val border = borders[index]
        for (row in cell.row until cell.row + cell.cell.rowspan) {
            put(TableEdge(true, cell.column, row), if (rtl) border.right else border.left, 1)
            put(TableEdge(true, cell.column + cell.colspan, row), if (rtl) border.left else border.right, 1)
        }
        for (column in cell.column until cell.column + cell.colspan) {
            put(TableEdge(false, cell.row, column), border.top, 1)
            put(TableEdge(false, cell.row + cell.cell.rowspan, column), border.bottom, 1)
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
internal fun CellStyle.hasTableLayoutStyle(): Boolean = border != null || padding != null || textAlign != null ||
    borderEdges != null || letterSpacing != null || width != null || minWidth != null || verticalAlign != null || lineHeight != null
internal fun tableHasOwnStyle(table: Table): Boolean = table.style != null || table.rows.any { row -> row.any { it.style?.hasTableLayoutStyle() == true } }
internal fun tableHasComputedCellStyle(table: Table): Boolean = table.style?.border is StyleBorder.Edges || table.rows.any { row -> row.any { cell ->
    cell.style?.let { it.border is StyleBorder.Edges || it.borderEdges != null || it.letterSpacing != null || it.width != null || it.minWidth != null || it.lineHeight != null } == true ||
        cell.nestedTable?.let(::tableHasComputedCellStyle) == true ||
        cell.blocks?.any { it.table?.let(::tableHasComputedCellStyle) == true } == true
} }
/** Enrolled native Figure cells supply real intrinsic widths even with padding-only styles. */
internal fun tableUsesContentWidths(table: Table, inherited: Boolean = false): Boolean =
    inherited || table.style?.minWidth != null || tableHasComputedCellStyle(table) || nativeDelegatedFigureTable(table) || nativeDelegatedAbsoluteTable(table)

/** A hard table floor keeps its original-body units and real containing-width authority. */
internal fun tableMinimumWidthPixels(value: StyleWidth, density: Float, normalBodyPixels: Float,
    containingWidth: Int? = null): Float {
    if (!density.isFinite() || density <= 0f || !normalBodyPixels.isFinite() || normalBodyPixels < 0f)
        throw UnsupportedFloatLayout("Table minimum width has an invalid geometry basis")
    val pixels = when (value.unit) {
        StyleWidthUnit.Px -> value.value.toDouble() * density
        StyleWidthUnit.Em -> value.value.toDouble() * normalBodyPixels
        StyleWidthUnit.Percent -> {
            val containing = containingWidth?.takeIf { it in 0..TablePixelLimit }
                ?: throw UnsupportedFloatLayout("Table percentage minimum requires its actual containing width")
            value.value.toDouble() * containing / 100.0
        }
    }
    if (!pixels.isFinite() || pixels !in 0.0..TablePixelLimit.toDouble())
        throw UnsupportedFloatLayout("Table minimum width exceeds native geometry")
    return pixels.toFloat()
}

/** Table-box fields retain their geometry; font-size caps and decoration projection do not apply. */
internal fun tableBoxLengthPixels(value: StyleLength, density: Float, bodyFontPixels: Float): Int {
    require(density.isFinite() && density > 0f && bodyFontPixels.isFinite() && bodyFontPixels >= 0f)
    val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else bodyFontPixels
    require(pixels.isFinite() && pixels <= Int.MAX_VALUE / 4) { "Table padding exceeds native coordinates" }
    return pixels.roundToInt()
}
internal fun tableBoxPaddingPixels(value: StyleEdges, density: Float, bodyFontPixels: Float) = TablePixelInsets(
    tableBoxLengthPixels(value.top, density, bodyFontPixels), tableBoxLengthPixels(value.right, density, bodyFontPixels),
    tableBoxLengthPixels(value.bottom, density, bodyFontPixels), tableBoxLengthPixels(value.left, density, bodyFontPixels))
internal fun tableStyleEdgesPixels(value: StyleEdges, density: Float, containerFontPixels: Float,
    decorationScale: Double = 1.0): TablePixelInsets {
    fun length(value: StyleLength) = (tableStyleLengthPixels(value, density, containerFontPixels) * decorationScale).roundToInt()
    return TablePixelInsets(length(value.top), length(value.right), length(value.bottom), length(value.left))
}
internal fun resolveTableStyle(table: Table, grid: TableGrid, density: Float, containerFontPixels: Float,
    defaultPadding: Int, legacyBorder: Int, decorationScale: Double = 1.0, rtl: Boolean = false,
    tableStyle: TableStyle? = table.style, suppressOuterHint: Boolean = false): TableResolvedStyle {
    require(decorationScale.isFinite() && decorationScale in 0.0..1.0)
    require(!suppressOuterHint || table.blockViewport?.intrinsicContainingDirection != null &&
        tableStyle === table.blockViewport.gridStyle) { "Anonymous outer-border hint has no intrinsic source owner" }
    val corners = tableStyle?.cornerRadii?.let {
        require(tableStyle.collapse == TableCollapse.Separate && !tableStyle.isInline && decorationScale == 1.0 &&
            (tableStyle.border == StyleBorder.None || tableStyle.border is StyleBorder.Solid)) {
            "Authored table corner geometry is unavailable for this border model"
        }
        nativeTableCornerRadii(it, density)
    }
    fun length(value: StyleLength) = (tableStyleLengthPixels(value, density, containerFontPixels) * decorationScale).toFloat()
    fun edges(value: StyleEdges) = tableStyleEdgesPixels(value, density, containerFontPixels, decorationScale)
    fun edge(value: StyleBorderEdge): TableStyleBorder = when (value) {
        StyleBorderEdge.None -> TableStyleBorder(0f, null, TableStroke.None)
        StyleBorderEdge.Hidden -> TableStyleBorder(0f, null, TableStroke.Hidden)
        is StyleBorderEdge.Solid -> TableStyleBorder(exactCellStylePixels(value.width, density, containerFontPixels), value.color, TableStroke.Solid)
        is StyleBorderEdge.Dotted -> TableStyleBorder(exactCellStylePixels(value.width, density, containerFontPixels), value.color, TableStroke.Dotted)
    }
    fun border(value: StyleBorder?): TableCellBorders {
        if (value is StyleBorder.Edges) return TableCellBorders(edge(value.top), edge(value.right), edge(value.bottom), edge(value.left))
        val uniform = when (value) {
            null -> TableStyleBorder((legacyBorder * decorationScale).toFloat(), null)
            StyleBorder.None -> TableStyleBorder(0f, null)
            is StyleBorder.Solid -> TableStyleBorder(length(value.width), value.color)
            is StyleBorder.Edges -> error("Per-edge border already resolved")
        }
        return TableCellBorders(uniform, uniform, uniform, uniform)
    }
    // Validate the actual cell floor before composition chooses its ordinary unavailable path.
    grid.cells.forEach { it.cell.style?.minWidth?.let { value -> exactCellStylePixels(value, density, containerFontPixels) } }
    val collapse = tableStyle?.collapse == TableCollapse.Collapse
    val borders = grid.cells.map { border(it.cell.style?.border) }
    fun side(value: CellBorder?, fallback: TableStyleBorder): TableStyleBorder = when (value) {
        null -> fallback
        CellBorder.None -> TableStyleBorder(0f, null, TableStroke.None)
        is CellBorder.Solid -> TableStyleBorder(exactCellStylePixels(value.width, density, containerFontPixels), value.color, TableStroke.Solid)
        is CellBorder.Double -> TableStyleBorder(exactCellStylePixels(value.width, density, containerFontPixels), value.color, TableStroke.Double)
    }
    val cellEdges = grid.cells.mapIndexed { index, placed ->
        placed.cell.style?.letterSpacing?.let { exactCellStylePixels(it, density, containerFontPixels) }
        placed.cell.style?.width?.takeUnless { it.unit == StyleWidthUnit.Percent }?.let {
            exactCellStylePixels(StyleLength(if (it.unit == StyleWidthUnit.Px) StyleLengthUnit.Px else StyleLengthUnit.Em, it.value), density, containerFontPixels)
        }
        val edge = placed.cell.style?.borderEdges; val fallback = borders[index]
        TableCellBorders(side(edge?.top, fallback.top), side(edge?.right, fallback.right),
            side(edge?.bottom, fallback.bottom), side(edge?.left, fallback.left))
    }
    val outer = if (corners != null && tableStyle?.border is StyleBorder.Solid) {
        val source = tableStyle.border
        val exact = TableStyleBorder(exactCellStylePixels(source.width, density, containerFontPixels), source.color)
        TableCellBorders(exact, exact, exact, exact)
    } else border(if (suppressOuterHint && tableStyle?.border == null) StyleBorder.None else tableStyle?.border)
    val padding = grid.cells.map { placed ->
        val fallback = (defaultPadding * decorationScale).roundToInt()
        placed.cell.style?.padding?.let(::edges) ?: TablePixelInsets(fallback, fallback, fallback, fallback)
    }
    val insets = if (collapse) collapsedTableCellInsets(grid, cellEdges, outer, padding, rtl)
        else padding.mapIndexed { index, p ->
            val edge = cellEdges[index]
            TablePixelInsets(p.top + ceil(edge.top.width).toInt(), p.right + ceil(edge.right.width).toInt(),
                p.bottom + ceil(edge.bottom.width).toInt(), p.left + ceil(edge.left.width).toInt())
        }
    val tablePadding = if (collapse) TablePixelInsets(0, 0, 0, 0)
        else tableStyle?.padding?.let { tableBoxPaddingPixels(it, density, containerFontPixels) }
            ?: TablePixelInsets(0, 0, 0, 0)
    return TableResolvedStyle(tableStyle?.background, outer.top, collapse,
        tableStyle?.margins?.let(::edges) ?: TablePixelInsets(0, 0, 0, 0), borders.map { it.top }, insets, decorationScale, tablePadding, cellEdges, rtl, outer, corners)
}

/** Shared collapsed-edge allocation for ordinary cells and the Figure's anonymous media cell. */
internal fun collapsedTableCellInsets(grid: TableGrid, cellEdges: List<TableCellBorders>,
    outer: TableCellBorders, padding: List<TablePixelInsets>, rtl: Boolean): List<TablePixelInsets> {
    require(padding.size == grid.cells.size && cellEdges.size == grid.cells.size)
    val winners = collapsedBorderWinners(grid, cellEdges, outer, rtl)
    return grid.cells.mapIndexed { index, placed ->
        val p = padding[index]
        fun horizontal(row: Int) = (placed.column until placed.column + placed.colspan).maxOfOrNull {
            winners[TableEdge(false, row, it)]?.border?.width ?: 0f
        } ?: 0f
        fun vertical(column: Int) = (placed.row until placed.row + placed.cell.rowspan).maxOfOrNull {
            winners[TableEdge(true, column, it)]?.border?.width ?: 0f
        } ?: 0f
        val start = ceil(vertical(placed.column) / 2f).toInt()
        val end = ceil(vertical(placed.column + placed.colspan) / 2f).toInt()
        TablePixelInsets(p.top + ceil(horizontal(placed.row) / 2f).toInt(),
            p.right + if (rtl) start else end,
            p.bottom + ceil(horizontal(placed.row + placed.cell.rowspan) / 2f).toInt(),
            p.left + if (rtl) end else start)
    }
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
    val outer = if (style.collapse && grid.rows > 0 && grid.columns > 0) 0L else
        ceil(style.outerEdges.left.width).toLong() + ceil(style.outerEdges.right.width).toLong()
    val outerVertical = if (style.collapse && grid.rows > 0 && grid.columns > 0) 0L else
        ceil(style.outerEdges.top.width).toLong() + ceil(style.outerEdges.bottom.width).toLong()
    val horizontal = columnCost.sum() + outer + style.margins.horizontal + (grid.columns.toLong() + 1) * spacing
    val vertical = rowCost.sum() + outerVertical + style.margins.vertical + (grid.rows.toLong() + 1) * spacing
    val widthBudget = (TablePixelLimit - bodyWidth).toLong()
    // A wide grid may scroll normally. Bound the decoration around any one cell,
    // not the sum of all body columns, against the actual containing viewport.
    val visibleHorizontal = (style.cellInsets.maxOfOrNull { it.horizontal } ?: 0).toLong() + outer + style.margins.horizontal + 2L * spacing
    val visibleVertical = (style.cellInsets.maxOfOrNull { it.vertical } ?: 0).toLong() + outerVertical + style.margins.vertical + 2L * spacing
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
    val projectedOuter = if (style.collapse && grid.rows > 0 && grid.columns > 0) 0L else
        ceil(style.outerEdges.left.width * factor).toLong() + ceil(style.outerEdges.right.width * factor).toLong()
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
    val width: Float, val color: String?, val stroke: TableStroke = TableStroke.Solid)

/** Resolve each shared edge once: none loses, then width, style, origin and position. */
internal fun collapsedTableBorders(grid: TableGrid, pixels: TablePixelLayout,
    style: TableResolvedStyle): List<TableBorderSegment> {
    if (grid.rows == 0 || grid.columns == 0) {
        return separateCellBorderSegments(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat(), style.outerEdges)
    }
    val edges = collapsedBorderWinners(grid, style.cellEdges, style.outerEdges, style.rtl)
    fun x(column: Int): Float = if (column == grid.columns) pixels.width.toFloat() else pixels.cellLeft(column).toFloat()
    fun y(row: Int): Float = if (row == grid.rows) pixels.height.toFloat() else pixels.cellTop(row).toFloat()
    return edges.map { (edge, winner) ->
        val width = winner.border.width
        if (edge.vertical) {
            val at = when (edge.fixed) { 0 -> width / 2f; grid.columns -> pixels.width - width / 2f; else -> x(edge.fixed) }
            TableBorderSegment(at, y(edge.interval), at, y(edge.interval + 1), width, winner.border.color, winner.border.stroke)
        } else {
            val at = when (edge.fixed) { 0 -> width / 2f; grid.rows -> pixels.height - width / 2f; else -> y(edge.fixed) }
            TableBorderSegment(x(edge.interval), at, x(edge.interval + 1), at, width, winner.border.color, winner.border.stroke)
        }
    }
}

/** New computed cell lengths are never rescaled by a descendant font or decoration projection. */
internal fun exactCellStylePixels(value: StyleLength, density: Float, normalBodyPixels: Float): Float {
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyPixels
    require(pixels.isFinite() && pixels <= TablePixelLimit) { "Cell style exceeds native measurement range" }
    return pixels.toFloat()
}

/** The authored double width includes both colored thirds and the unpainted middle third. */
internal fun tableBorderBands(edge: TableBorderSegment): List<TableBorderSegment> {
    if (edge.stroke == TableStroke.None || edge.stroke == TableStroke.Hidden || edge.width <= 0f) return emptyList()
    if (edge.stroke == TableStroke.Solid || edge.stroke == TableStroke.Dotted) return listOf(edge)
    val third = edge.width / 3f
    return listOf(-third, third).map { offset ->
        if (edge.x1 == edge.x2) edge.copy(x1 = edge.x1 + offset, x2 = edge.x2 + offset,
            width = third, stroke = TableStroke.Solid)
        else edge.copy(y1 = edge.y1 + offset, y2 = edge.y2 + offset,
            width = third, stroke = TableStroke.Solid)
    }
}

/** Physical sides are resolved before drawing, independently of the table's inline direction. */
internal fun separateCellBorderSegments(left: Float, top: Float, right: Float, bottom: Float,
    edges: TableCellBorders): List<TableBorderSegment> = listOf(
    TableBorderSegment(left, top + edges.top.width / 2f, right, top + edges.top.width / 2f,
        edges.top.width, edges.top.color, edges.top.stroke),
    TableBorderSegment(right - edges.right.width / 2f, top, right - edges.right.width / 2f, bottom,
        edges.right.width, edges.right.color, edges.right.stroke),
    TableBorderSegment(left, bottom - edges.bottom.width / 2f, right, bottom - edges.bottom.width / 2f,
        edges.bottom.width, edges.bottom.color, edges.bottom.stroke),
    TableBorderSegment(left + edges.left.width / 2f, top, left + edges.left.width / 2f, bottom,
        edges.left.width, edges.left.color, edges.left.stroke),
).flatMap(::tableBorderBands)
