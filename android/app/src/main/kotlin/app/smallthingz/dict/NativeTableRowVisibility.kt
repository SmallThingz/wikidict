package app.smallthingz.dict

/** A root CSS viewport decision; descendant allocation is never a visibility basis. */
internal fun nativeTableRowsHiddenAt(maximum: Long?, rootViewportCssWidth: Double): Boolean {
    if (maximum == null) return false
    require(maximum in 1..0xffffffffL) { "Invalid table row visibility threshold" }
    require(rootViewportCssWidth.isFinite() && rootViewportCssWidth >= 0.0) { "Table row visibility needs the root CSS viewport" }
    return rootViewportCssWidth <= maximum.toDouble()
}

internal fun nativeTableRowsHiddenAt(table: Table, rootViewportCssWidth: Double): Boolean =
    nativeTableRowsHiddenAt(table.rowsHiddenMaxWidthPx, rootViewportCssWidth)

/** The source remains complete and keeps its identity, paths and structural validation.
 * Only the measured/rendered grid changes. A hidden outer row therefore never prepares
 * the nested table or caption inside that original cell. */
internal class NativeTableRowProjection(val source: Table, val grid: TableGrid, val rowsHidden: Boolean)

internal fun nativeTableRowProjection(table: Table, rootViewportCssWidth: Double? = null): NativeTableRowProjection {
    val full = tableGrid(table)
    val hidden = table.rowsHiddenMaxWidthPx?.let {
        require(table.rows.isNotEmpty() && table.style?.isInline != true && table.style?.floatSide == null &&
            table.blockViewport == null && table.floatViewport == null) { "Invalid table row visibility owner" }
        nativeTableRowsHiddenAt(it, requireNotNull(rootViewportCssWidth) { "Table row visibility needs the root CSS viewport" })
    } ?: false
    return NativeTableRowProjection(table, if (hidden) TableGrid(emptyList(), 0, 0) else full, hidden)
}

/** Feature projections cannot replace a table that owns a viewport-driven row policy,
 * including an original nested table or caption table. */
internal fun nativeTableHasRowVisibility(table: Table): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onTable = { value, _, _ -> if (value.rowsHiddenMaxWidthPx != null) found = true }
    }.table(table)
    return found
}
