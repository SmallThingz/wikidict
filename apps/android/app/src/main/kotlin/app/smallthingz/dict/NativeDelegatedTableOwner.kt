package app.smallthingz.dict

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates

internal val LocalNativeDelegatedTable = staticCompositionLocalOf<NativeDelegatedTableOwner?> { null }
internal val LocalNativeDelegatedCell = staticCompositionLocalOf<NativeDelegatedCellOwner?> { null }
internal val LocalNativeDelegatedFigureScope = staticCompositionLocalOf<NativeDelegatedCellOwner?> { null }

internal class NativeDelegatedTableIdentity(private val table: Table) {
    override fun equals(other: Any?): Boolean = other is NativeDelegatedTableIdentity && other.table === table
    override fun hashCode(): Int = System.identityHashCode(table)
}

/** Closed structural entry point; current measured envelopes, not this predicate, grant use. */
internal fun nativeDelegatedFigureTable(table: Table): Boolean = table.caption.isEmpty() &&
    table.captionBlocks == null && table.style?.isInline != true && table.rows.any { it.isNotEmpty() } &&
    table.rows.all { row -> row.all { cell ->
        val block = cell.blocks?.singleOrNull()
        val figure = block?.figure
        val layout = figure?.tableCaptionLayout
        cell.spans.isEmpty() && cell.nestedTable == null && block?.kind == "paragraph" && block.style == null &&
            figure != null && figure.content is FigureContent.Image && layout != null && (layout.media.positioning == ContainerPositioning.RelativeAuto ||
                layout.viewportStates.any { it.media.positioning == ContainerPositioning.RelativeAuto }) &&
            (figure.captionBlocks?.all { caption -> caption.kind == "paragraph" && caption.depth == 0 &&
                caption.style == null && caption.figure == null && caption.flow == null && caption.container == null &&
                caption.table == null && caption.feature == null && caption.spans.all { it.image == null } }
                ?: figure.caption.all { it.image == null })
    } }

internal class NativeDelegatedCellOwner(val index: Int, val table: NativeDelegatedTableOwner) {
    val sourceBlock: Block = checkNotNull(tableGrid(table.table).cells[index].cell.blocks).single()
    var cellCoordinates: LayoutCoordinates? = null
    var contextCoordinates: LayoutCoordinates? = null
    var viewCoordinates: LayoutCoordinates? = null
    private var originalView: NativeFloatTextView? = null
    private var physical: NativeSurfaceGeometry? = null
    private var logicalWidth = 0
    private var logicalHeight = 0
    private var minimumTouchWidth = 0f
    private var minimumTouchHeight = 0f
    private data class Envelopes(val ink: List<NativeFloatBounds>, val deferred: List<NativeFloatBounds>,
        val input: List<NativeFloatBounds>, val ordinary: List<NativeFloatBounds>)
    private var envelopeSurface: NativeSurfaceGeometry? = null
    private var envelopes: Envelopes? = null
    internal var envelopeBuildCount = 0
        private set
    private data class Placement(val root: LayoutCoordinates, val generation: Any, val surface: NativeSurfaceGeometry,
        val cell: LayoutCoordinates, val context: LayoutCoordinates, val view: LayoutCoordinates,
        val boxes: List<Pair<LayoutCoordinates, NativeFloatBounds>>, val clip: NativeFloatBounds)
    private var placement: Placement? = null

    fun measured(view: NativeFloatTextView, surface: NativeSurfaceGeometry, width: Int, height: Int,
        touchWidth: Float, touchHeight: Float) {
        if (originalView !== view || physical !== surface) table.invalidate()
        originalView = view
        physical = surface
        logicalWidth = width
        logicalHeight = height
        minimumTouchWidth = touchWidth
        minimumTouchHeight = touchHeight
        view.delegatedCellOwner = this
    }

    fun permits(view: NativeFloatTextView): Boolean = originalView === view && table.permitsOriginalOwners()
    fun registeredOwner(): NativeFloatTextView? = originalView
    fun placementReported(): Boolean = originalView != null && viewCoordinates != null &&
        cellCoordinates != null && contextCoordinates != null

    fun clear(view: NativeFloatTextView) {
        if (originalView === view) {
            originalView = null
            physical = null
            placement = null
            envelopes = null
            envelopeSurface = null
            viewCoordinates = null
            table.invalidate()
        }
    }

    fun admissionChanged() { originalView?.delegatedAdmissionChanged() }
    fun measurementPending() { originalView?.delegatedMeasurementPending() }

    /** No text traversal or envelope rebuilding occurs on the draw/input/AX hot path. */
    fun currentPlacement(root: LayoutCoordinates, generation: Any): Boolean {
        val stamp = placement ?: return false
        val view = originalView ?: return false
        if (stamp.root !== root || stamp.generation !== generation || physical !== stamp.surface ||
            cellCoordinates !== stamp.cell || contextCoordinates !== stamp.context || viewCoordinates !== stamp.view ||
            !root.isAttached || !view.isAttachedToWindow || view.currentMeasuredGeometry !== stamp.surface ||
            view.width != stamp.surface.width || view.height != stamp.surface.height ||
            stamp.context.size.width != logicalWidth || stamp.context.size.height != logicalHeight) return false
        for ((coordinates, bounds) in stamp.boxes) if (measuredBox(root, coordinates) != bounds) return false
        return actualInputClip(root, stamp.view) == stamp.clip && view.delegatedCellOwner === this
    }

    fun snapshot(root: LayoutCoordinates, generation: Any): NativeDelegatedMeasuredCell? {
        val view = originalView ?: return null
        val surface = physical ?: return null
        if (!view.isAttachedToWindow || view.currentMeasuredGeometry !== surface ||
            view.width != surface.width || view.height != surface.height) return null
        val coordinates = contextCoordinates?.takeIf { it.isAttached } ?: return null
        val nativeCoordinates = viewCoordinates?.takeIf { it.isAttached } ?: return null
        val cell = cellCoordinates?.takeIf { it.isAttached } ?: return null
        if (coordinates.size.width != logicalWidth || coordinates.size.height != logicalHeight) return null
        val origin = translationTo(root, coordinates) ?: return null
        val ownerOrigin = Offset(origin.x + surface.surface.left, origin.y + surface.surface.top)
        val physicalBox = NativeFloatBounds(ownerOrigin.x, ownerOrigin.y,
            ownerOrigin.x + surface.width, ownerOrigin.y + surface.height)
        if (measuredBox(root, nativeCoordinates) != physicalBox || view.delegatedCellOwner !== this) return null
        val cellBox = measuredBox(root, cell) ?: return null
        // Query the actual expanded AndroidView, not its smaller logical context box.
        // Compose intersects only real clipping layers on this existing ancestry.
        val clip = actualInputClip(root, nativeCoordinates) ?: return null
        val ancestors = mutableListOf(NativeDelegatedInputAncestor(clip, true))
        val boxes = mutableListOf(cell to cellBox, coordinates to checkNotNull(measuredBox(root, coordinates)))
        var cursor: LayoutCoordinates? = nativeCoordinates
        var containsRoot = false
        while (cursor != null) {
            val bounds = measuredBox(root, cursor) ?: return null
            ancestors += NativeDelegatedInputAncestor(bounds, false)
            boxes += cursor to bounds
            if (cursor === root) containsRoot = true
            cursor = cursor.parentLayoutCoordinates
        }
        if (!containsRoot) return null
        fun translated(rect: NativeFloatBounds) = rect.translated(ownerOrigin.x, ownerOrigin.y)
        if (envelopeSurface !== surface) {
            val density = view.resources.displayMetrics.density
            val selection = nativeDelegatedSelectionInk(surface, density)
            val hostFocus = nativeDelegatedHostFocusInk(surface, density)
            val mediaNodes = surface.positionedGroups.flatMap { it.nodeIds }.toSet()
            envelopes = Envelopes(listOfNotNull(surface.extents.ink) + nativeDelegatedFocusInk(surface.nodes, density) +
                hostFocus + selection,
                surface.positionedGroups.flatMap { group ->
                    group.bounds.map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) } +
                        nativeDelegatedFocusInk(surface.nodes.filter { it.id in group.nodeIds }, density)
                },
                (surface.nodes.flatMap { it.bounds } + surface.rectsForRange(0, surface.text.length))
                    .map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) },
                selection + hostFocus + nativeDelegatedFocusInk(surface.nodes.filterNot { it.id in mediaNodes }, density))
            envelopeSurface = surface
            envelopeBuildCount++
        }
        val local = checkNotNull(envelopes)
        if (local.deferred.isEmpty()) return null
        placement = Placement(root, generation, surface, cell, coordinates, nativeCoordinates, boxes, clip)
        return NativeDelegatedMeasuredCell(view, generation, cellBox, physicalBox, ancestors,
            local.ink.map(::translated), local.deferred.map(::translated), local.input.map(::translated),
            minimumTouchWidth, minimumTouchHeight, local.ordinary.map(::translated))
    }
}

/** Provisional composition still has one real cell graph. It is neither painted nor made
 * interactive until the post-layout proof succeeds. A refusal recomposes the existing
 * complete unavailable-content branch; the provisional graph remains gated meanwhile. */
internal class NativeDelegatedTableOwner(val table: Table, private val invalidateParent: () -> Unit) {
    val cells = tableGrid(table).cells.indices.map { NativeDelegatedCellOwner(it, this) }
    var fallbackReason by mutableStateOf<String?>(null)
        private set
    private var fallbackComposed = false
    private var awaitingNativeComposition = false
    private var generation: Any = Any()
    private var source: Any? = null
    private var width: Int? = null
    private var rootCoordinates: LayoutCoordinates? = null
    var gridCoordinates: LayoutCoordinates? = null
    private var measuredSurroundings: NativeDelegatedSurroundings? = null
    private var accepted by mutableStateOf(false)
    private var acceptedGeneration: Any? = null
    private var acceptedGrid: NativeFloatBounds? = null
    private val preparedRevisions = mutableMapOf<Int, Any>()

    fun prepared(index: Int, revision: Any) {
        val previous = preparedRevisions.put(index, revision)
        if (previous != null && previous != revision) {
            accepted = false
            generation = Any()
            awaitingNativeComposition = fallbackComposed
            fallbackReason = null
            measuredSurroundings = null
            cells.forEach { it.admissionChanged() }
            invalidateParent()
        }
    }

    fun begin(sourceRevision: Any, containingWidth: Int) {
        invalidate()
        measuredSurroundings = null
        val sourceChanged = source != sourceRevision
        if (sourceChanged || width != containingWidth) {
            source = sourceRevision
            width = containingWidth
            generation = Any()
            awaitingNativeComposition = fallbackComposed
            fallbackReason = null
            if (sourceChanged) cells.forEach { it.admissionChanged() }
        }
    }

    fun composedFallback(value: Boolean) {
        if (!value) awaitingNativeComposition = false
        if (fallbackComposed != value) {
            fallbackComposed = value
            invalidateParent()
        }
    }

    fun invalidate() {
        accepted = false
        cells.forEach { it.measurementPending() }
    }

    fun refuse(reason: String) {
        // A real revision may arrive during measurement of the prior fallback slot.
        // Let that one slot recompose before judging its new native publication.
        if (awaitingNativeComposition) return
        accepted = false
        fallbackReason = reason
        cells.forEach { it.admissionChanged() }
    }

    fun measured(allocation: NativeFloatBounds, otherInk: List<NativeFloatBounds>?, otherInput: List<NativeFloatBounds>?) {
        measuredSurroundings = NativeDelegatedSurroundings(generation, allocation, otherInk, otherInput)
    }

    fun positioned(coordinates: LayoutCoordinates) {
        rootCoordinates = coordinates
        validateAfterPlacement()
    }

    fun validateAfterPlacement() {
        if (fallbackReason != null || fallbackComposed) return
        val decision = decision() ?: return
        when (decision) {
            is NativeDelegatedPaintDecision.Permitted -> {
                if (!accepted) {
                    accepted = true
                    acceptedGeneration = generation
                    acceptedGrid = gridCoordinates?.let { grid -> rootCoordinates?.let { measuredBox(it, grid) } }
                    cells.forEach { it.admissionChanged() }
                }
            }
            is NativeDelegatedPaintDecision.Unavailable -> {
                refuse(decision.reason)
            }
        }
    }

    // A composed fallback may paint its own Compose children, but never reauthorizes a
    // provisional native View left over until the following measurement disposes it.
    fun permitsCellContent(): Boolean = fallbackComposed || permitsOriginalOwners()

    fun permitsOriginalOwners(): Boolean {
        if (fallbackReason != null || !accepted || fallbackComposed || acceptedGeneration !== generation) return false
        val root = rootCoordinates?.takeIf { it.isAttached } ?: return false
        val grid = gridCoordinates?.takeIf { it.isAttached } ?: return false
        return measuredBox(root, grid) == acceptedGrid && cells.all { it.currentPlacement(root, generation) }
    }

    private fun decision(): NativeDelegatedPaintDecision? {
        val root = rootCoordinates?.takeIf { it.isAttached } ?: return null
        val grid = gridCoordinates?.takeIf { it.isAttached } ?: return null
        val surroundings = measuredSurroundings ?: return null
        if (cells.any { !it.placementReported() }) return null
        val tableBounds = measuredBox(root, grid) ?: return NativeDelegatedPaintDecision.Unavailable(
            "The delegated table transform is not a translation")
        val measured = cells.map { it.snapshot(root, generation) ?: return NativeDelegatedPaintDecision.Unavailable(
            "The delegated table's original native owner is not current") }
        return nativeDelegatedPaintDecision(surroundings.copy(allocation = tableBounds,
            atomicAllocation = surroundings.allocation), measured,
            cells.map { it.registeredOwner() ?: return NativeDelegatedPaintDecision.Unavailable("Original cell owner detached") })
    }
}

private fun translationTo(root: LayoutCoordinates, child: LayoutCoordinates): Offset? {
    if (!root.isAttached || !child.isAttached) return null
    val origin = root.localPositionOf(child, Offset.Zero)
    val x = root.localPositionOf(child, Offset(1f, 0f))
    val y = root.localPositionOf(child, Offset(0f, 1f))
    if (!origin.x.isFinite() || !origin.y.isFinite() || x.x - origin.x != 1f || x.y != origin.y ||
        y.x != origin.x || y.y - origin.y != 1f) return null
    return origin
}

private fun measuredBox(root: LayoutCoordinates, child: LayoutCoordinates): NativeFloatBounds? =
    translationTo(root, child)?.let { NativeFloatBounds(it.x, it.y,
        it.x + child.size.width, it.y + child.size.height) }

/** Include the existing outer Entry scroll viewport as well as the table viewport. */
private fun actualInputClip(root: LayoutCoordinates, child: LayoutCoordinates): NativeFloatBounds? {
    var top = child
    while (true) top = top.parentLayoutCoordinates ?: break
    val origin = translationTo(root, top) ?: return null
    if (!child.isAttached) return null
    val clipped = top.localBoundingBoxOf(child, clipBounds = true)
    return NativeFloatBounds(clipped.left + origin.x, clipped.top + origin.y,
        clipped.right + origin.x, clipped.bottom + origin.y)
}

/** Include every focus state and every possible caret/handle position, not only the
 * currently selected text. The real View remains responsible for painting these states. */
internal fun nativeDelegatedOwnerInk(geometry: FloatTextGeometry, density: Float,
    selection: List<NativeFloatBounds> = nativeDelegatedSelectionInk(geometry, density)): List<NativeFloatBounds> = buildList {
    geometry.extents.ink?.let(::add)
    addAll(nativeDelegatedFocusInk(geometry.nodes, density))
    addAll(nativeDelegatedHostFocusInk(geometry, density))
    addAll(geometry.rectsForRange(0, geometry.text.length).map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) })
    addAll(selection)
}

private fun nativeDelegatedFocusInk(nodes: List<FloatInteractionNode>, density: Float): List<NativeFloatBounds> = buildList {
    nativeFocusInk(nodes)?.let(::add)
    nodes.filter { it.focusPaint == null }.forEach { node ->
        node.bounds.forEach { add(nativeDelegatedDefaultFocusInk(
            NativeFloatBounds(it.left, it.top, it.right, it.bottom), density, node.missingLinkPaint != null)) }
    }
}

private fun nativeDelegatedHostFocusInk(geometry: FloatTextGeometry, density: Float): List<NativeFloatBounds> {
    val bounds = geometry.focusBounds
    val stroke = minOf(2 * density, bounds.width(), bounds.height())
    if (stroke <= 0f) return emptyList()
    return listOf(
        NativeFloatBounds(bounds.left, bounds.top, bounds.right, bounds.top + stroke),
        NativeFloatBounds(bounds.left, bounds.bottom - stroke, bounds.right, bounds.bottom),
        NativeFloatBounds(bounds.left, bounds.top, bounds.left + stroke, bounds.bottom),
        NativeFloatBounds(bounds.right - stroke, bounds.top, bounds.right, bounds.bottom),
    )
}

internal fun nativeDelegatedSelectionInk(geometry: FloatTextGeometry, density: Float,
    x: Float = 0f, y: Float = 0f,
    owner: NativeFloatBounds = NativeFloatBounds(0f, 0f, geometry.width.toFloat(), geometry.height.toFloat())
): List<NativeFloatBounds> = buildList {
    addAll(geometry.rectsForRange(0, geometry.text.length).map {
        NativeFloatBounds(it.left + x, it.top + y, it.right + x, it.bottom + y)
    })
    val radius = minOf(6 * density, minOf(owner.width, owner.height) / 2f)
    for (position in 0..geometry.text.length) {
        val caret = geometry.caretRect(position).apply { offset(x, y) }
        add(NativeFloatBounds(caret.left, caret.top, caret.left + maxOf(1f, density), caret.bottom))
        val cx = caret.left.coerceIn(owner.left + radius, maxOf(owner.left + radius, owner.right - radius))
        val cy = (caret.bottom + 7 * density).coerceIn(owner.top + radius, maxOf(owner.top + radius, owner.bottom - radius))
        add(NativeFloatBounds(cx - radius, cy - radius, cx + radius, cy + radius))
        add(NativeFloatBounds(caret.left, minOf(caret.bottom, cy), caret.left + density, maxOf(caret.bottom, cy)))
    }
}
