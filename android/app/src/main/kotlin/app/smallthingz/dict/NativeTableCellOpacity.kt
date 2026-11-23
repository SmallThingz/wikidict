package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.RectF
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.nativeCanvas

internal const val NativeCellOpacityUnavailable = "Cell opacity layout is unavailable. Table content is retained."

internal fun Cell.hasNativeCellOpacity(): Boolean = style?.opacity?.let { it < 1f } == true

internal fun Table.hasNativeCellOpacity(): Boolean = rows.any { row -> row.any(Cell::hasNativeCellOpacity) }

internal fun nativeHasCellOpacity(table: Table): Boolean {
    var found = false
    PresentationSpanVisitor { _, _ -> }.apply {
        onTable = { value, _, _ -> if (value.hasNativeCellOpacity()) found = true }
    }.table(table)
    return found
}

/** Initial consumer shape; no label, glyph, title or font-name whitelist. */
internal fun nativeCellOpacityTableShape(table: Table): Boolean {
    fun span(value: Span, child: Boolean, actions: Boolean): Boolean {
        if ((value.kind != "text" && !(actions && value.kind == "link")) ||
            value.image != null || value.ruby != null || value.inlinePaddingGroup != null ||
            value.inlineActionGroup != null || value.clippedAbsolute != null || value.audioControl != null ||
            value.citationMarker != null || value.isQualifiedCitationBacklink) return false
        val box = value.inlineBoxGroup
        return box == null || !child && box.atomicLayout == null && box.atomicAutoLayout == null && box.intrinsicLinesLayout == null && box.overlays.isEmpty() &&
            box.spans.all { span(it, true, actions) }
    }
    return table.style?.collapse != TableCollapse.Collapse && table.style?.isInline != true &&
        table.style?.floatSide == null && table.style?.marginValues == null && table.style?.margins == null &&
        table.style?.cornerRadii == null && table.blockViewport == null && table.floatViewport == null &&
        table.rowsHiddenMaxWidthPx == null && table.caption.isEmpty() && table.captionBlocks == null &&
        table.rows.all { row -> row.all { cell ->
            cell.blocks == null && cell.nestedTable == null && cell.rowspan == 1 &&
                (cell.colspan == 1 || !cell.hasNativeCellOpacity()) &&
                cell.spans.all { span(it, false, !cell.hasNativeCellOpacity()) }
        } }
}

internal fun NativeFloatBounds.opacityEncloses(other: NativeFloatBounds): Boolean =
    left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom

/** Includes the actual physical surface and the original View's possible selection/focus paint. */
internal fun nativeCellOpacityPaintBounds(geometry: FloatTextGeometry, density: Float): NativeFloatBounds {
    val physical = NativeSurfaceGeometry(geometry)
    val surface = physical.surface
    var bounds = NativeFloatBounds(0f, 0f, physical.width.toFloat(), physical.height.toFloat())
    nativeDelegatedSelectionInk(physical, density).forEach { bounds = checkNotNull(enclosingBounds(bounds, it)) }
    val focus = physical.focusBounds
    if (!focus.isEmpty) bounds = checkNotNull(enclosingBounds(bounds,
        NativeFloatBounds(focus.left, focus.top, focus.right, focus.bottom)))
    nativeFocusInk(physical.nodes)?.let { bounds = checkNotNull(enclosingBounds(bounds, it)) }
    physical.nodes.filter { it.focusPaint == null }.forEach { node -> node.bounds.forEach { rectangle ->
        bounds = checkNotNull(enclosingBounds(bounds, nativeDelegatedDefaultFocusInk(
            NativeFloatBounds(rectangle.left, rectangle.top, rectangle.right, rectangle.bottom), density,
            node.missingLinkPaint != null)))
    } }
    return bounds.translated(surface.left.toFloat(), surface.top.toFloat())
}

internal data class NativeCellOpacityPlacement(val border: NativeFloatBounds, val boxTop: Float,
    val paint: NativeFloatBounds)

internal class NativeCellOpacityTable(val table: Table) {
    private val cells = tableGrid(table).cells
    private val alpha = cells.map { it.cell.style?.opacity }
    private val paints = arrayOfNulls<Paint>(cells.size)
    fun opacity(index: Int): Float? = alpha[index]
    fun paint(index: Int): Paint = paints[index] ?: Paint().apply {
        // Apply the original float to the completed layer, before destination
        // blending. Paint.alpha would prequantize the source policy to eight bits.
        colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setScale(1f, 1f, 1f, checkNotNull(opacity(index))) })
    }.also { paints[index] = it }
    private val geometry = arrayOfNulls<FloatTextGeometry>(cells.size)
    private val tokens = arrayOfNulls<Any>(cells.size)
    val text = cells.indices.map { NativeCellOpacityText(this, it) }
    var permitted by mutableStateOf(false)
        private set
    var width = 0
        private set
    var height = 0
        private set
    var placements: List<NativeCellOpacityPlacement>? = null
        private set

    fun revoke() { permitted = false }
    fun bind(index: Int): NativeCellOpacityTextBinding {
        val token = Any()
        tokens[index] = token
        geometry[index] = null
        revoke()
        return NativeCellOpacityTextBinding(this, index, token)
    }
    fun observed(index: Int, token: Any, value: FloatTextGeometry?) {
        if (tokens[index] !== token) return
        geometry[index] = value
        revoke()
    }
    fun measureStarted() { revoke(); placements = null }
    fun measured(width: Int, height: Int, boxes: List<NativeFloatBounds>,
        boxTops: List<Float>, contentOffsets: List<Pair<Float, Float>>, sizes: List<Pair<Int, Int>>, density: Float) {
        this.width = width; this.height = height
        val grid = NativeFloatBounds(0f, 0f, width.toFloat(), height.toFloat())
        if (boxes.size != cells.size || boxTops.size != cells.size || contentOffsets.size != cells.size || sizes.size != cells.size) return
        val actual = cells.indices.map { index ->
            val value = geometry[index] ?: return
            val size = sizes[index]
            if (value.width != size.first || value.height != size.second) return
            if (value.positionedGroups.isNotEmpty() || value.clippedAbsoluteSemanticLocations.isNotEmpty()) return
            if (cells[index].cell.hasNativeCellOpacity() && value.nodes.any { it.onClick != null || it.onLongClick != null }) return
            val (x, y) = contentOffsets[index]
            val paint = nativeCellOpacityPaintBounds(value, density).translated(x, y)
            val border = boxes[index]
            if (!grid.opacityEncloses(border) || !border.opacityEncloses(paint)) return
            NativeCellOpacityPlacement(border, boxTops[index], paint)
        }
        // The original validated grid and tablePixelLayout own disjoint row /
        // column intervals; do not rebuild or pairwise rescan that same grid.
        placements = actual
    }
    fun permit() { check(placements != null); permitted = true }
}

internal class NativeCellOpacityText(private val owner: NativeCellOpacityTable, private val index: Int) {
    fun bind(): NativeCellOpacityTextBinding = owner.bind(index)
}

internal class NativeCellOpacityTextBinding(private val owner: NativeCellOpacityTable,
    private val index: Int, private val token: Any) {
    fun observed(value: FloatTextGeometry?) = owner.observed(index, token, value)
    fun clear() = observed(null)
}

internal val LocalNativeCellOpacityTable = staticCompositionLocalOf<NativeCellOpacityTable?> { null }

/** Minted only for the complete visible Entry body, never by an arbitrary child Table. */
internal class NativeCellOpacitySourceIdentity(private val source: Any) {
    override fun equals(other: Any?): Boolean = other is NativeCellOpacitySourceIdentity && source === other.source
    override fun hashCode(): Int = System.identityHashCode(source)
}
internal class NativeCellOpacityEntrySource(val entry: Entry)

internal fun nativeCellOpacityEntrySource(entry: Entry, rows: List<ReadingRow>, run: IntRange): NativeCellOpacityEntrySource? =
    if (entry.displayTitle.isEmpty() && entry.preamble.isEmpty() && entry.references.isEmpty() && entry.media.isEmpty() &&
        run.first == 0 && run.last == rows.lastIndex &&
        rows.none { it.reference != null || it.referenceBatch != null }) NativeCellOpacityEntrySource(entry) else null

internal class NativeCellOpacityRoot(val source: NativeCellOpacityEntrySource) {
    private val tables = linkedMapOf<Int, NativeCellOpacityTable>()
    fun table(id: Int, value: Table): NativeCellOpacityTable = tables[id]?.takeIf { it.table === value }
        ?: NativeCellOpacityTable(value).also { tables[id]?.revoke(); tables[id] = it }
    fun retain(ids: Set<Int>) { tables.keys.filter { it !in ids }.forEach { tables.remove(it)?.revoke() } }
    fun revoke() { tables.values.forEach(NativeCellOpacityTable::revoke) }
    fun validate(geometry: NativeFloatContextGeometry?, parts: List<NativeFloatContextSpec>, density: Float) {
        revoke()
        if (geometry == null) return
        fun unavailable(): Nothing = throw UnsupportedFloatLayout(NativeCellOpacityUnavailable)
        if (parts.any { it !is NativeFloatContextSpec.Text && it !is NativeFloatContextSpec.Child && it !is NativeFloatContextSpec.Rule } ||
            geometry.children.size != tables.size || tables.isEmpty()) unavailable()
        val sources = parts.filterIsInstance<NativeFloatContextSpec.Child>()
        if (sources.size != tables.size || sources.any { it.id !in tables || it.floatSide != null ||
            it.scrollport != null || it.delegatedTable != null || it.atomicInline }) unavailable()
        val other = geometry.inputLeaves().map { leaf ->
            nativeCellOpacityPaintBounds(leaf.geometry, density).translated(leaf.x, leaf.y)
        }
        val allocations = geometry.children.map { placed ->
            val owner = tables[placed.id] ?: unavailable()
            if (!nativeCellOpacityTableShape(owner.table) || owner.placements == null ||
                placed.bounds.width() != owner.width.toFloat() || placed.bounds.height() != owner.height.toFloat()) unavailable()
            val bounds = NativeFloatBounds(placed.bounds.left, placed.bounds.top, placed.bounds.right, placed.bounds.bottom)
            // This initial complete body route has full-width ordinary tables.
            // That gives an exact interval sweep instead of quadratic pair tests.
            if (bounds.left != 0f || bounds.right != geometry.width.toFloat()) unavailable()
            bounds
        }.sortedBy { it.top }
        if (allocations.zipWithNext().any { (a, b) -> a.bottom > b.top }) unavailable()
        val surrounding = other.filter { it.left < geometry.width && it.right > 0f }.sortedBy { it.top }
        var tableIndex = 0
        var otherIndex = 0
        while (tableIndex < allocations.size && otherIndex < surrounding.size) {
            val a = allocations[tableIndex]
            val b = surrounding[otherIndex]
            when {
                a.bottom <= b.top -> tableIndex++
                b.bottom <= a.top -> otherIndex++
                else -> unavailable()
            }
        }
        tables.values.forEach(NativeCellOpacityTable::permit)
    }
}

/** One compositing operation; normal layout and original input/AX owners are untouched. */
internal fun Modifier.nativeCellOpacity(owner: NativeCellOpacityTable?, index: Int,
    backdrop: (android.graphics.Canvas, RectF) -> Unit): Modifier = if (owner == null ||
        owner.opacity(index)?.let { it < 1f } != true) this else drawWithContent {
    val placement = owner.placements?.getOrNull(index)
    if (!owner.permitted || placement == null) {
        drawContent()
    } else {
        val border = placement.border
        // This modifier is on the unchanged padded/content-height Box. Its border
        // remains at the grid origin even when vertical-align moves the content.
        val local = RectF(0f, border.top - placement.boxTop, border.width, border.bottom - placement.boxTop)
        val canvas = drawContext.canvas.nativeCanvas
        val clip = canvas.clipBounds
        val bounded = RectF(local)
        if (bounded.intersect(clip.left.toFloat(), clip.top.toFloat(), clip.right.toFloat(), clip.bottom.toFloat())) {
            val saved = canvas.saveLayer(bounded, owner.paint(index))
            try { backdrop(canvas, local); drawContent() }
            finally { canvas.restoreToCount(saved) }
        }
    }
}
