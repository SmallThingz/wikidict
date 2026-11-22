package app.smallthingz.dict

internal fun nativeTableUsesResolvedBorders(table: Table, style: TableStyle? = table.style): Boolean =
    style?.border is StyleBorder.ResolvedEdges || table.rows.any { row ->
        row.any { it.style?.border is StyleBorder.ResolvedEdges }
    }

internal fun nativeHasResolvedTableBorders(table: Table): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onTable = { value, _, _ -> if (nativeTableUsesResolvedBorders(value)) found = true }
    }.table(table)
    return found
}

internal fun nativeTableResolvedBorderFailure(table: Table, style: TableStyle? = table.style,
    anonymous: Boolean = false): String? {
    if (!nativeTableUsesResolvedBorders(table, style)) return null
    return when {
        anonymous || table.blockViewport != null || table.floatViewport != null ||
            style?.isInline == true || style?.floatSide != null ->
            "Resolved borders require an ordinary table. Table content is retained."
        style?.cornerRadii != null ->
            "Resolved table borders with rounded corners are unavailable. Table content is retained."
        table.rows.any { row -> row.any { it.rowspan != 1 || it.colspan != 1 } } ->
            "Resolved table borders with spanning cells are unavailable. Table content is retained."
        table.rows.any { row -> row.any { it.style?.border is StyleBorder.ResolvedEdges && it.style.borderEdges != null } } ->
            "Resolved cell borders cannot acquire separate edge overrides. Table content is retained."
        else -> null
    }
}

/** A preflighted paint region. Stroke remains authored until the painter chooses
 * the collapsed inset/outset appearance; the source color remains the base ink. */
internal data class NativeTableResolvedBorderRegion(val side: NativeTableBorderSide,
    val stroke: TableStroke, val collapsed: Boolean, val argb: Int,
    val polygon: List<NativeTableBorderPoint>, val line: TableBorderSegment,
    val normalLow: Float, val normalHigh: Float,
    val owner: NativeTableBorderOwner?)

internal data class NativeTableResolvedCellBorderPlan(val left: Float, val top: Float,
    val regions: List<NativeTableResolvedBorderRegion>)

internal data class NativeTableResolvedBorderPlan(
    /** Null leaves the old separate-table border path unchanged. */
    val outer: List<NativeTableResolvedBorderRegion>?,
    /** Only owners with the new complete representation replace their old path. */
    val cells: Map<Int, NativeTableResolvedCellBorderPlan>,
    /** Nonnull replaces all shared-edge paint for this mixed collapsed grid. */
    val collapsed: List<NativeTableResolvedBorderRegion>?)

internal fun TableCellBorders.hasResolvedTableBorder(): Boolean =
    top.resolved || right.resolved || bottom.resolved || left.resolved

internal fun TableResolvedStyle.hasResolvedTableBorder(): Boolean =
    outerEdges.hasResolvedTableBorder() || cellEdges.any { it.hasResolvedTableBorder() }

private fun TableCellBorders.side(side: NativeTableBorderSide): TableStyleBorder = when (side) {
    NativeTableBorderSide.Top -> top
    NativeTableBorderSide.Right -> right
    NativeTableBorderSide.Bottom -> bottom
    NativeTableBorderSide.Left -> left
}

/** Runs during native preparation/measurement. No source validation or geometry
 * construction is deferred to an Android draw callback. */
internal fun nativeTableResolvedBorderPlan(table: Table, grid: TableGrid, pixels: TablePixelLayout,
    style: TableResolvedStyle, tableInk: NativeSemanticBorderInk?,
    cellInks: List<NativeSemanticBorderInk?>, legacyArgb: Int): NativeTableResolvedBorderPlan {
    require(style.hasResolvedTableBorder())
    require(cellInks.size == grid.cells.size)
    fun resolveColor(border: TableStyleBorder): Int {
        if (!border.resolved) return border.color?.let { checkNotNull(canonicalColorArgb(it)).toInt() } ?: legacyArgb
        return when (val paint = checkNotNull(border.sourcePaint)) {
            is StyleBorderPaint.Rgb -> checkNotNull(canonicalColorArgb(paint.value)).toInt()
            StyleBorderPaint.OwnerCurrentColor -> {
                val owner = checkNotNull(border.sourceOwner)
                require(owner.table === table)
                val expected = when (owner.origin) {
                    NativeTableBorderOrigin.Table -> NativeTableBorderOwner(table, table, NativeTableBorderOrigin.Table)
                    NativeTableBorderOrigin.Cell -> {
                        val index = checkNotNull(owner.cellIndex)
                        val cell = grid.cells.getOrNull(index)?.cell ?: error("Table border lost its original cell position")
                        NativeTableBorderOwner(table, cell, NativeTableBorderOrigin.Cell, index)
                    }
                }
                val ink = if (owner.origin == NativeTableBorderOrigin.Table) tableInk
                    else cellInks[checkNotNull(owner.cellIndex)]
                nativeTableOwnerCurrentColor(owner, NativeTableBorderOwnerInk(expected, ink))
            }
        }
    }
    fun visible(border: TableStyleBorder): Boolean = border.width > 0f &&
        border.stroke != TableStroke.None && border.stroke != TableStroke.Hidden
    // Resolve every requested source-owner color before choosing shared winners.
    // No losing or zero-width declaration can silently acquire another owner's ink.
    val colors = java.util.IdentityHashMap<TableStyleBorder, Int>()
    fun prepareColors(edges: TableCellBorders) {
        NativeTableBorderSide.entries.forEach { side ->
            val edge = edges.side(side)
            if (edge.sourcePaint != null || visible(edge)) colors[edge] = resolveColor(edge)
        }
    }
    prepareColors(style.outerEdges)
    style.cellEdges.forEach(::prepareColors)
    fun color(border: TableStyleBorder): Int = checkNotNull(colors[border])
    fun separate(box: NativeTableBorderRectangle, edges: TableCellBorders): List<NativeTableResolvedBorderRegion> {
        val widths = NativeTableBorderWidths(edges.top.width, edges.right.width, edges.bottom.width, edges.left.width)
        return NativeTableBorderSide.entries.mapNotNull { side ->
            val border = edges.side(side)
            if (!visible(border)) return@mapNotNull null
            val polygon = checkNotNull(nativeTableBorderSideBand(box, widths, side))
            val line = when (side) {
                NativeTableBorderSide.Top -> TableBorderSegment(box.left, box.top + border.width / 2f,
                    box.right, box.top + border.width / 2f, border.width, border.color, border.stroke)
                NativeTableBorderSide.Right -> TableBorderSegment(box.right - border.width / 2f, box.top,
                    box.right - border.width / 2f, box.bottom, border.width, border.color, border.stroke)
                NativeTableBorderSide.Bottom -> TableBorderSegment(box.left, box.bottom - border.width / 2f,
                    box.right, box.bottom - border.width / 2f, border.width, border.color, border.stroke)
                NativeTableBorderSide.Left -> TableBorderSegment(box.left + border.width / 2f, box.top,
                    box.left + border.width / 2f, box.bottom, border.width, border.color, border.stroke)
            }
            val low = when (side) {
                NativeTableBorderSide.Top -> box.top
                NativeTableBorderSide.Right -> box.right - border.width
                NativeTableBorderSide.Bottom -> box.bottom - border.width
                NativeTableBorderSide.Left -> box.left
            }
            val high = when (side) {
                NativeTableBorderSide.Top -> box.top + border.width
                NativeTableBorderSide.Right -> box.right
                NativeTableBorderSide.Bottom -> box.bottom
                NativeTableBorderSide.Left -> box.left + border.width
            }
            require(high > low)
            NativeTableResolvedBorderRegion(side, border.stroke, false, color(border),
                listOf(polygon.outerStart, polygon.outerEnd, polygon.innerEnd, polygon.innerStart),
                line, low, high, border.sourceOwner)
        }
    }
    val outerBox = NativeTableBorderRectangle(0f, 0f, pixels.width.toFloat(), pixels.height.toFloat())
    if (!style.collapse || grid.rows == 0 || grid.columns == 0) {
        val cells = linkedMapOf<Int, NativeTableResolvedCellBorderPlan>()
        if (!style.collapse) grid.cells.forEachIndexed { index, placed ->
            val edges = style.cellEdges[index]
            if (edges.hasResolvedTableBorder()) {
                val left = pixels.physicalCellLeft(placed.column, placed.colspan, style.rtl)
                val right = left + pixels.cellWidth(placed.colspan, placed.column)
                val top = pixels.cellTop(placed.row).toFloat()
                cells[index] = NativeTableResolvedCellBorderPlan(left.toFloat(), top,
                    separate(NativeTableBorderRectangle(left.toFloat(), top,
                        right.toFloat(), pixels.cellBottom(placed.row, placed.cell.rowspan).toFloat()), edges))
            }
        }
        return NativeTableResolvedBorderPlan(
            if (style.outerEdges.hasResolvedTableBorder()) separate(outerBox, style.outerEdges) else null,
            cells, null)
    }
    val logical = collapsedBorderWinners(grid, style.cellEdges, style.outerEdges, style.rtl)
    // Grid keys, not rounded cell insets or coordinate equality, retain each incidence.
    val physical = linkedMapOf<TableEdge, TableEdgeCandidate>()
    logical.forEach { (edge, candidate) ->
        val key = if (!style.rtl) edge else if (edge.vertical)
            edge.copy(fixed = grid.columns - edge.fixed)
        else edge.copy(interval = grid.columns - edge.interval - 1)
        physical[key] = candidate
    }
    fun logicalX(column: Int): Float = if (column == grid.columns) pixels.width.toFloat() else pixels.cellLeft(column).toFloat()
    fun x(column: Int): Float = if (style.rtl) pixels.width - logicalX(grid.columns - column) else logicalX(column)
    fun y(row: Int): Float = if (row == grid.rows) pixels.height.toFloat() else pixels.cellTop(row).toFloat()
    fun normal(edge: TableEdge, candidate: TableEdgeCandidate?): Pair<Float, Float> {
        if (candidate == null || !visible(candidate.border)) return 0f to 0f
        val width = candidate.border.width
        val limit = if (edge.vertical) grid.columns else grid.rows
        return when (edge.fixed) {
            0 -> 0f to width
            limit -> width to 0f
            else -> (width / 2f).let {
                require(it > 0f) { "Table border half-width is unrepresentable" }
                it to it
            }
        }
    }
    fun before(edge: TableEdge) = normal(edge, physical[edge]).first
    fun after(edge: TableEdge) = normal(edge, physical[edge]).second
    val regions = physical.mapNotNull { (edge, winner) ->
        val border = winner.border
        if (!visible(border)) return@mapNotNull null
        val band = normal(edge, winner)
        val start: NativeTableBorderPoint
        val end: NativeTableBorderPoint
        val junction: NativeTableBorderJunctionInsets
        if (edge.vertical) {
            start = NativeTableBorderPoint(x(edge.fixed), y(edge.interval))
            end = NativeTableBorderPoint(x(edge.fixed), y(edge.interval + 1))
            junction = NativeTableBorderJunctionInsets(
                after(TableEdge(false, edge.interval, edge.fixed - 1)),
                after(TableEdge(false, edge.interval, edge.fixed)),
                before(TableEdge(false, edge.interval + 1, edge.fixed - 1)),
                before(TableEdge(false, edge.interval + 1, edge.fixed)))
        } else {
            start = NativeTableBorderPoint(x(edge.interval), y(edge.fixed))
            end = NativeTableBorderPoint(x(edge.interval + 1), y(edge.fixed))
            junction = NativeTableBorderJunctionInsets(
                after(TableEdge(true, edge.interval, edge.fixed - 1)),
                after(TableEdge(true, edge.interval, edge.fixed)),
                before(TableEdge(true, edge.interval + 1, edge.fixed - 1)),
                before(TableEdge(true, edge.interval + 1, edge.fixed)))
        }
        val polygon = nativeTableCollapsedBorderPolygon(start, end, edge.vertical, band.first, band.second, junction)
        val fixed = if (edge.vertical) start.x else start.y
        val low = fixed - band.first
        val high = fixed + band.second
        require(high > low)
        val middle = fixed + (band.second - band.first) / 2f
        val line = if (edge.vertical) TableBorderSegment(middle, start.y, middle, end.y,
            border.width, border.color, border.stroke)
        else TableBorderSegment(start.x, middle, end.x, middle, border.width, border.color, border.stroke)
        NativeTableResolvedBorderRegion(winner.physicalSide, border.stroke, true, color(border), polygon,
            line, low, high, border.sourceOwner)
    }
    return NativeTableResolvedBorderPlan(null, emptyMap(), regions)
}
