package app.smallthingz.dict

import android.graphics.RectF
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.snapshots.Snapshot
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

/** Separate enrollment for ordinary absolute Containers. The existing measured cell
 * surface, ancestry and paint/input proof still decide whether it can be used. */
internal fun nativeDelegatedAbsoluteTable(table: Table): Boolean = table.caption.isEmpty() &&
    table.captionBlocks == null && table.style?.isInline != true && table.rows.any { it.isNotEmpty() } &&
    table.rows.all { row -> row.all { cell ->
        val block = cell.blocks?.singleOrNull()
        val container = block?.container
        fun hasAbsolute(value: Container): Boolean = value.blocks.any { child ->
            child.container?.let { it.style.absolutePosition != null || it.style.absoluteStatic != null || hasAbsolute(it) } == true
        }
        cell.spans.isEmpty() && cell.nestedTable == null && block?.kind == "container" && block.style == null &&
            container != null && container.style.positioning == ContainerPositioning.RelativeAuto &&
            container.style.positionedScope == null && hasAbsolute(container)
    } }

/** Identity is required: another equal Block cannot borrow this cell's measured surface. */
internal fun nativeDelegatedAbsoluteCell(owner: NativeDelegatedCellOwner?, blocks: List<Block>): NativeDelegatedCellOwner? =
    owner?.takeIf { it.table.ordinaryAbsolute && blocks.size == 1 && blocks.single() === it.sourceBlock }

internal data class NativeDelegatedDocumentOverflow(val physical: NativeFloatBounds, val scrollable: NativeFloatBounds?)

internal data class NativeDelegatedAbsoluteFlow(val owner: NativeDelegatedCellOwner, val block: Block, val path: String)
internal val LocalNativeDelegatedAbsoluteFlow = staticCompositionLocalOf<NativeDelegatedAbsoluteFlow?> { null }

internal class NativeDelegatedCellOwner(val index: Int, val table: NativeDelegatedTableOwner) {
    val sourceBlock: Block = checkNotNull(tableGrid(table.table).cells[index].cell.blocks).single()
    private val absoluteFlowBlocks: List<Block> = if (!table.ordinaryAbsolute) emptyList() else buildList {
        fun collect(block: Block) {
            if (block.figure != null || block.flow != null) add(block)
            else block.container?.blocks?.forEach(::collect)
        }
        collect(sourceBlock)
    }
    private var absoluteSourceRevision: Any? = null
    private val absoluteFlowRevisions = linkedMapOf<String, Pair<Block, Any>>()
    fun ownsAbsoluteFlow(block: Block): Boolean = absoluteFlowBlocks.any { it === block }
    fun preparedAbsoluteSource(revision: Any) {
        if (absoluteSourceRevision != revision) {
            absoluteSourceRevision = revision
            publishAbsoluteRevision()
        }
    }
    fun preparedAbsoluteFlow(path: String, block: Block, revision: Any) {
        require(ownsAbsoluteFlow(block)) { "Only the original cell Flow may publish its preparation" }
        val old = absoluteFlowRevisions[path]
        require(old == null || old.first === block) { "A Flow occurrence cannot change its source owner" }
        if (old?.second != revision) {
            absoluteFlowRevisions[path] = block to revision
            publishAbsoluteRevision()
        }
    }
    private fun publishAbsoluteRevision() {
        val source = absoluteSourceRevision ?: return
        table.prepared(index, listOf(source, absoluteFlowRevisions.toSortedMap().map { (path, value) -> path to value.second }))
    }
    var cellCoordinates: LayoutCoordinates? = null
    var contextCoordinates: LayoutCoordinates? = null
    var viewCoordinates: LayoutCoordinates? = null
    private var originalView: NativeFloatTextView? = null
    private var physical: NativeSurfaceGeometry? = null
    private var scrollableBounds: NativeFloatBounds? = null
    private var logicalWidth = 0
    private var logicalHeight = 0
    private var minimumTouchWidth = 0f
    private var minimumTouchHeight = 0f
    private data class Envelopes(val ink: List<NativeFloatBounds>, val deferred: List<NativeFloatBounds>,
        val input: List<NativeFloatBounds>, val state: List<NativeFloatBounds>, val ordinary: List<NativeFloatBounds>)
    private var envelopeSurface: NativeSurfaceGeometry? = null
    private var envelopes: Envelopes? = null
    internal var envelopeBuildCount = 0
        private set
    private data class Placement(val root: LayoutCoordinates, val generation: Any, val surface: NativeSurfaceGeometry,
        val cell: LayoutCoordinates, val context: LayoutCoordinates, val view: LayoutCoordinates,
        val boxes: List<Pair<LayoutCoordinates, NativeFloatBounds>>, val clip: NativeFloatBounds)
    private var placement: Placement? = null

    fun measured(view: NativeFloatTextView, surface: NativeSurfaceGeometry, width: Int, height: Int,
        touchWidth: Float, touchHeight: Float, scrollableBounds: NativeFloatBounds? = null) {
        if (originalView !== view || physical !== surface || this.scrollableBounds != scrollableBounds) table.invalidate()
        originalView = view
        physical = surface
        this.scrollableBounds = scrollableBounds
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
            scrollableBounds = null
            placement = null
            envelopes = null
            envelopeSurface = null
            viewCoordinates = null
            table.invalidate()
        }
    }

    fun admissionChanged() { originalView?.delegatedAdmissionChanged() }
    fun measurementPending() { originalView?.delegatedMeasurementPending() }
    fun statePaintChanged() { table.statePaintChanged() }

    internal fun paintOriginalState(canvas: android.graphics.Canvas, focus: Boolean) {
        val stamp = placement ?: return
        val view = originalView ?: return
        val origin = stamp.boxes.firstOrNull { it.first === stamp.view }?.second ?: return
        val save = canvas.save()
        try {
            canvas.clipRect(stamp.clip.left, stamp.clip.top, stamp.clip.right, stamp.clip.bottom)
            canvas.translate(origin.left, origin.top)
            view.paintDelegatedState(canvas, focus)
        } finally { canvas.restoreToCount(save) }
    }

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
        val grid = table.gridCoordinates?.takeIf { it.isAttached } ?: return false
        return clippedBox(root, grid, stamp.view) == measuredBox(root, stamp.view) &&
            actualInputClip(root, stamp.view) == stamp.clip && view.delegatedCellOwner === this
    }

    fun snapshot(root: LayoutCoordinates, generation: Any, unavailable: (String) -> Unit): NativeDelegatedMeasuredCell? {
        fun missing(stage: String): NativeDelegatedMeasuredCell? { unavailable(stage); return null }
        val view = originalView ?: return missing("original View absent")
        val surface = physical ?: return missing("physical geometry absent")
        if (!view.isAttachedToWindow || view.currentMeasuredGeometry !== surface ||
            view.width != surface.width || view.height != surface.height) return missing("View attachment, geometry or dimensions changed")
        val coordinates = contextCoordinates?.takeIf { it.isAttached } ?: return missing("context coordinates absent/detached")
        val nativeCoordinates = viewCoordinates?.takeIf { it.isAttached } ?: return missing("View coordinates absent/detached")
        val cell = cellCoordinates?.takeIf { it.isAttached } ?: return missing("cell coordinates absent/detached")
        if (coordinates.size.width != logicalWidth || coordinates.size.height != logicalHeight) return missing("logical context dimensions changed")
        val origin = translationTo(root, coordinates) ?: return missing("context transform is not a translation")
        val ownerOrigin = Offset(origin.x + surface.surface.left, origin.y + surface.surface.top)
        // Layout advances/boxes remain separate from the expanded physical paint surface.
        val scrollable = scrollableBounds?.translated(origin.x, origin.y)
        if (table.ordinaryAbsolute && scrollable == null) return missing("cell scrollable layout bounds absent")
        val physicalBox = NativeFloatBounds(ownerOrigin.x, ownerOrigin.y,
            ownerOrigin.x + surface.width, ownerOrigin.y + surface.height)
        if (measuredBox(root, nativeCoordinates) != physicalBox || view.delegatedCellOwner !== this) return missing("physical View box or owner differs")
        val cellBox = measuredBox(root, cell) ?: return missing("cell transform is not a translation")
        val grid = table.gridCoordinates?.takeIf { it.isAttached } ?: return missing("table grid coordinates absent/detached")
        // These enrolled source cells have overflow:visible. A real inner clip must
        // not become authority to discard glyphs, focus or handles. Only the normal table
        // and outer Entry viewports above the grid can limit their visible/input domain.
        val innerClip = clippedBox(root, grid, nativeCoordinates)
        if (innerClip != physicalBox)
            return missing("unexpected cell-to-grid clipping: ${clippingSegments(root, nativeCoordinates, grid)}")
        // Query the actual expanded AndroidView, not its smaller logical context box.
        // Compose intersects only real clipping layers on this existing ancestry.
        val clip = actualInputClip(root, nativeCoordinates) ?: return missing("actual input clip unavailable")
        val ancestors = mutableListOf(NativeDelegatedInputAncestor(clip, true))
        val boxes = mutableListOf(cell to cellBox, coordinates to checkNotNull(measuredBox(root, coordinates)))
        var cursor: LayoutCoordinates? = nativeCoordinates
        var containsRoot = false
        while (cursor != null) {
            val bounds = measuredBox(root, cursor) ?: return missing("ancestor transform is not a translation")
            ancestors += NativeDelegatedInputAncestor(bounds, false)
            boxes += cursor to bounds
            if (cursor === root) containsRoot = true
            cursor = cursor.parentLayoutCoordinates
        }
        if (!containsRoot) return missing("root is not in the View ancestry")
        fun translated(rect: NativeFloatBounds) = rect.translated(ownerOrigin.x, ownerOrigin.y)
        if (envelopeSurface !== surface) {
            val density = view.resources.displayMetrics.density
            val selection = nativeDelegatedSelectionInk(surface, density)
            val handleInput = nativeDelegatedSelectionInput(surface, density)
            val hostFocus = nativeDelegatedHostFocusInk(surface, density)
            val logical = NativeFloatBounds(-surface.surface.left.toFloat(), -surface.surface.top.toFloat(),
                surface.content.width - surface.surface.left.toFloat(), surface.content.height - surface.surface.top.toFloat())
            envelopes = Envelopes(listOfNotNull(surface.extents.ink) + nativeDelegatedFocusInk(surface.nodes, density) +
                hostFocus + selection,
                if (table.ordinaryAbsolute) listOfNotNull(surface.extents.ink) else
                    surface.positionedGroups.flatMap { group ->
                        // Focus is painted once by the original View in the parent state phase.
                        group.bounds.map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
                    },
                (surface.nodes.flatMap { it.bounds } + surface.rectsForRange(0, surface.text.length))
                    .map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) } + handleInput +
                    listOfNotNull(logical, surface.extents.interaction) + surface.positionedGroups.flatMap { group ->
                        group.bounds.map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
                    },
                selection + hostFocus + nativeDelegatedFocusInk(surface.nodes, density), surface.ordinaryPaintBounds)
            envelopeSurface = surface
            envelopeBuildCount++
        }
        val local = checkNotNull(envelopes)
        if (local.deferred.isEmpty()) return missing("deferred envelope is empty")
        placement = Placement(root, generation, surface, cell, coordinates, nativeCoordinates, boxes, clip)
        return NativeDelegatedMeasuredCell(view, generation, cellBox, physicalBox, ancestors,
            local.ink.map(::translated), local.deferred.map(::translated), local.input.map(::translated),
            minimumTouchWidth, minimumTouchHeight, local.state.map(::translated), local.ordinary.map(::translated),
            root, innerClip, requiresRootExtent = table.ordinaryAbsolute, scrollableBounds = scrollable)
    }
}

/** Provisional composition still has one real cell graph. It is neither painted nor made
 * interactive until the post-layout proof succeeds. A refusal recomposes the existing
 * complete unavailable-content branch; the provisional graph remains gated meanwhile. */
internal class NativeDelegatedTableOwner(val table: Table, private val invalidateParent: () -> Unit) {
    val ordinaryAbsolute: Boolean = nativeDelegatedAbsoluteTable(table)
    private var statePaintRevision by mutableStateOf(0)
    fun statePaintChanged() {
        // AndroidView.update observes reads. Notify the draw reader without subscribing
        // the updating View to the revision it unconditionally changes during bind.
        Snapshot.withoutReadObservation { statePaintRevision++ }
    }
    private var rootStateView: NativeFloatTextView? = null
    private var rootStateCoordinates: LayoutCoordinates? = null
    private var rootStateSurface: NativeSurfaceGeometry? = null
    private var rootStateInput: List<NativeFloatBounds> = emptyList()
    private data class RootStatePlacement(val view: NativeFloatTextView, val surface: NativeSurfaceGeometry,
        val coordinates: LayoutCoordinates, val bounds: NativeFloatBounds, val clip: NativeFloatBounds)
    private var rootStatePlacement: RootStatePlacement? = null

    fun measuredRootState(view: NativeFloatTextView, surface: NativeSurfaceGeometry) {
        val previousView = rootStateView
        if (previousView !== view) {
            rootStateView = null
            if (previousView != null && previousView.delegatedStateOwner === this) previousView.delegatedStateOwner = null
            rootStateCoordinates = null
            rootStatePlacement = null
        }
        if (previousView !== view || rootStateSurface !== surface) {
            rootStateInput = nativeDelegatedSelectionInput(surface, view.resources.displayMetrics.density)
            rootStatePlacement = null
        }
        rootStateView = view
        rootStateSurface = surface
        view.delegatedStateOwner = this
    }

    fun positionedRootState(view: NativeFloatTextView, coordinates: LayoutCoordinates) {
        if (rootStateView === view) {
            rootStateCoordinates = coordinates
            validateAfterPlacement()
        }
    }

    fun clearRootState(view: NativeFloatTextView) {
        if (rootStateView === view) {
            rootStateView = null
            rootStateCoordinates = null
            rootStateSurface = null
            rootStatePlacement = null
            rootStateInput = emptyList()
            statePaintChanged()
        }
        if (view.delegatedStateOwner === this) view.delegatedStateOwner = null
    }

    private fun paintRootState(canvas: android.graphics.Canvas, focus: Boolean) {
        val root = rootCoordinates ?: return
        val view = rootStateView ?: return
        val coordinates = rootStateCoordinates ?: return
        val surface = rootStateSurface ?: return
        if (!view.isAttachedToWindow || view.currentMeasuredGeometry !== surface ||
            view.width != surface.width || view.height != surface.height) return
        val bounds = measuredBox(root, coordinates) ?: return
        val clip = actualInputClip(root, coordinates) ?: return
        val save = canvas.save()
        try {
            canvas.clipRect(clip.left, clip.top, clip.right, clip.bottom)
            canvas.translate(bounds.left, bounds.top)
            view.paintDelegatedState(canvas, focus)
        } finally { canvas.restoreToCount(save) }
    }

    /** Reading the revision observes all original View invalidations in the existing
     * parent draw. Admission and immutable placement are rechecked before either phase. */
    fun paintOriginalState(canvas: android.graphics.Canvas, focus: Boolean) {
        statePaintRevision
        if (permitsOriginalOwners()) cells.forEach { it.paintOriginalState(canvas, focus) }
        // This is the existing upper AndroidView's priority, including parent selection
        // handles over a Child placeholder. Keep paint and real interop hit order aligned.
        paintRootState(canvas, focus)
    }

    val cells = tableGrid(table).cells.indices.map { NativeDelegatedCellOwner(it, this) }
    var fallbackReason by mutableStateOf<String?>(null)
        private set
    var refusalEvidence: String? = null
        private set
    private var fallbackComposed = false
    private var awaitingNativeComposition = false
    private var generation: Any = Any()
    private var source: Any? = null
    private var width: Int? = null
    private var rootCoordinates: LayoutCoordinates? = null
    var gridCoordinates: LayoutCoordinates? = null
    private var measuredSurroundings: NativeDelegatedSurroundings? = null
    private data class DocumentOverflow(val generation: Any, val bounds: NativeDelegatedDocumentOverflow)
    private var documentOverflow: DocumentOverflow? = null

    /** Bounds are retained relative to the original outer table allocation. Rebase onto
     * this measure's allocation so preceding flow and document-origin changes cannot drift. */
    fun documentOverflow(allocation: NativeFloatBounds): NativeDelegatedDocumentOverflow? = documentOverflow
        ?.takeIf { ordinaryAbsolute && fallbackReason == null && !fallbackComposed && it.generation === generation }
        ?.bounds?.let { value -> NativeDelegatedDocumentOverflow(
            value.physical.translated(allocation.left, allocation.top),
            value.scrollable?.translated(allocation.left, allocation.top)) }
    private var accepted by mutableStateOf(false)
    private var acceptedGeneration: Any? = null
    private var acceptedGrid: NativeFloatBounds? = null
    private val preparedRevisions = mutableMapOf<Int, Any>()

    fun prepared(index: Int, revision: Any) {
        val previous = preparedRevisions.put(index, revision)
        if (previous != null && previous != revision) {
            accepted = false
            generation = Any()
            documentOverflow = null
            awaitingNativeComposition = fallbackComposed
            fallbackReason = null
            refusalEvidence = null
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
            documentOverflow = null
            awaitingNativeComposition = fallbackComposed
            fallbackReason = null
            refusalEvidence = null
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

    fun refuse(reason: String, evidence: String? = null) {
        // A real revision may arrive during measurement of the prior fallback slot.
        // Let that one slot recompose before judging its new native publication.
        if (awaitingNativeComposition || fallbackReason != null) return
        // The fallback removes the native slots and can fail preparation in turn. Keep
        // the first refusal and its value-only evidence, never that secondary teardown.
        refusalEvidence = evidence ?: "stage=native preparation; reason=$reason"
        accepted = false
        fallbackReason = reason
        cells.forEach { it.admissionChanged() }
    }

    fun measured(allocation: NativeFloatBounds, otherInk: List<NativeFloatBounds>?, otherInput: List<NativeFloatBounds>?,
        rootFallbackInput: List<NativeFloatBounds> = emptyList()) {
        measuredSurroundings = NativeDelegatedSurroundings(generation, allocation, otherInk, otherInput,
            rootFallbackInput = rootFallbackInput)
    }

    fun positioned(coordinates: LayoutCoordinates) {
        rootCoordinates = coordinates
        validateAfterPlacement()
    }

    fun validateAfterPlacement() {
        if (fallbackReason != null || fallbackComposed) return
        val evaluation = decision() ?: return
        when (val decision = evaluation.decision) {
            is NativeDelegatedPaintDecision.Permitted -> {
                if (!accepted) {
                    accepted = true
                    acceptedGeneration = generation
                    acceptedGrid = gridCoordinates?.let { grid -> rootCoordinates?.let { measuredBox(it, grid) } }
                    cells.forEach { it.admissionChanged() }
                }
            }
            is NativeDelegatedPaintDecision.Unavailable -> {
                refuse(decision.reason, evaluation.evidence)
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
        val state = rootStatePlacement ?: return false
        return rootStateView === state.view && rootStateSurface === state.surface &&
            rootStateCoordinates === state.coordinates && state.view.isAttachedToWindow &&
            state.view.currentMeasuredGeometry === state.surface && state.view.delegatedStateOwner === this &&
            state.view.width == state.surface.width && state.view.height == state.surface.height &&
            measuredBox(root, state.coordinates) == state.bounds && actualInputClip(root, state.coordinates) == state.clip &&
            measuredBox(root, grid) == acceptedGrid && cells.all { it.currentPlacement(root, generation) }
    }

    private data class Evaluation(val decision: NativeDelegatedPaintDecision, val evidence: String? = null)

    private fun decision(): Evaluation? {
        val root = rootCoordinates?.takeIf { it.isAttached } ?: return null
        val grid = gridCoordinates?.takeIf { it.isAttached } ?: return null
        val surroundings = measuredSurroundings ?: return null
        if (cells.any { !it.placementReported() }) return null
        val stateView = rootStateView ?: return null
        val stateCoordinates = rootStateCoordinates ?: return null
        val stateSurface = rootStateSurface ?: return null
        if (!stateView.isAttachedToWindow || stateView.currentMeasuredGeometry !== stateSurface ||
            stateView.width != stateSurface.width || stateView.height != stateSurface.height ||
            stateView.delegatedStateOwner !== this) return null
        val stateBounds = measuredBox(root, stateCoordinates) ?: return null
        val stateClip = actualInputClip(root, stateCoordinates) ?: return null
        if (stateBounds.width != stateSurface.width.toFloat() || stateBounds.height != stateSurface.height.toFloat()) return null
        val measured = mutableListOf<NativeDelegatedMeasuredCell>()
        fun unavailable(reason: String, stage: String): Evaluation {
            // Render only on failure. No View or LayoutCoordinates are retained by this
            // string, and no snapshot/admission function is called while observing it.
            val evidence = try { buildString {
                appendLine("stage=$stage; reason=$reason; expectedOwners=${cells.size}")
                appendLine("rootAttached=${root.isAttached}; gridAttached=${grid.isAttached}; grid=${measuredBox(root, grid)}")
                appendLine("surroundings=$surroundings")
                measured.forEachIndexed { index, cell -> appendLine("measured[$index]=$cell") }
            } } catch (failure: Exception) {
                "stage=$stage; reason=$reason; evidence unavailable: ${failure.javaClass.name}: ${failure.message}"
            }
            return Evaluation(NativeDelegatedPaintDecision.Unavailable(reason), evidence)
        }
        val tableBounds = measuredBox(root, grid) ?: return unavailable(
            "The delegated table transform is not a translation", "table transform")
        for (cell in cells) {
            var stage = "snapshot did not report its stage"
            val snapshot = cell.snapshot(root, generation) { stage = it } ?: return unavailable(
                "The delegated table's original native owner is not current", "cell[${cell.index}] $stage")
            measured += snapshot
        }
        if (ordinaryAbsolute) {
            val left = measured.minOf { it.physicalSurface.left } - surroundings.allocation.left
            val top = measured.minOf { it.physicalSurface.top } - surroundings.allocation.top
            val right = measured.maxOf { it.physicalSurface.right } - surroundings.allocation.left
            val bottom = measured.maxOf { it.physicalSurface.bottom } - surroundings.allocation.top
            val scrollable = measured.mapNotNull { it.scrollableBounds }
            if (scrollable.size != measured.size)
                return unavailable("Absolute table scrollable layout bounds are absent", "document extent")
            val scrollLeft = scrollable.minOf { it.left } - surroundings.allocation.left
            val scrollTop = scrollable.minOf { it.top } - surroundings.allocation.top
            val scrollRight = scrollable.maxOf { it.right } - surroundings.allocation.left
            val scrollBottom = scrollable.maxOf { it.bottom } - surroundings.allocation.top
            if (!listOf(left, top, right, bottom, scrollLeft, scrollTop, scrollRight, scrollBottom).all { it.isFinite() } ||
                left > right || top > bottom || scrollLeft > scrollRight || scrollTop > scrollBottom)
                return unavailable("Absolute table overflow is outside native coordinates", "document extent")
            val bounds = NativeDelegatedDocumentOverflow(NativeFloatBounds(left, top, right, bottom),
                NativeFloatBounds(scrollLeft, scrollTop, scrollRight, scrollBottom))
            val previous = documentOverflow
            if (previous == null || previous.generation !== generation || previous.bounds != bounds) {
                documentOverflow = DocumentOverflow(generation, bounds)
                accepted = false
                cells.forEach { it.measurementPending() }
                invalidateParent()
                // The next measure includes this actual overflow in the root export.
                // Until its real placement is checked, no provisional owner is admitted.
                return null
            }
        }
        val expected = cells.map { it.registeredOwner() ?: return unavailable("Original cell owner detached", "owner identity") }
        rootStatePlacement = RootStatePlacement(stateView, stateSurface, stateCoordinates, stateBounds, stateClip)
        val input = surroundings.copy(allocation = tableBounds, rootOwner = root,
            rootState = NativeDelegatedRootState(stateView, stateBounds, stateClip,
                rootStateInput.map { it.translated(stateBounds.left, stateBounds.top) }, surroundings.rootFallbackInput))
        return when (val decision = nativeDelegatedPaintDecision(input, measured, expected)) {
            is NativeDelegatedPaintDecision.Permitted -> Evaluation(decision)
            is NativeDelegatedPaintDecision.Unavailable -> unavailable(decision.reason, "paint/input proof; actualAllocation=$tableBounds")
        }
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

private fun clippedBox(root: LayoutCoordinates, ancestor: LayoutCoordinates,
    child: LayoutCoordinates): NativeFloatBounds? {
    if (!ancestor.isAttached || !child.isAttached) return null
    val origin = translationTo(root, ancestor) ?: return null
    val clipped = ancestor.localBoundingBoxOf(child, clipBounds = true)
    return NativeFloatBounds(clipped.left + origin.x, clipped.top + origin.y,
        clipped.right + origin.x, clipped.bottom + origin.y)
}

/** Value-only first-refusal evidence; never an admission, mutation or second snapshot. */
private fun clippingSegments(root: LayoutCoordinates, child: LayoutCoordinates,
    grid: LayoutCoordinates): String = buildString {
    var cursor: LayoutCoordinates? = child
    var count = 0
    while (cursor != null && count < 32) {
        val current = cursor
        append("[$count box=${measuredBox(root, current)} clipped=${clippedBox(root, current, child)}]")
        if (current === grid) return@buildString
        cursor = current.parentLayoutCoordinates
        count++
    }
    append(" grid not reached within finite ancestry")
}

private fun nativeDelegatedClip(bounds: NativeFloatBounds, clip: RectF?): NativeFloatBounds? {
    if (clip == null) return bounds
    val left = maxOf(bounds.left, clip.left); val top = maxOf(bounds.top, clip.top)
    val right = minOf(bounds.right, clip.right); val bottom = minOf(bounds.bottom, clip.bottom)
    return if (left < right && top < bottom) NativeFloatBounds(left, top, right, bottom) else null
}

private fun nativeDelegatedFocusInk(nodes: List<FloatInteractionNode>, density: Float): List<NativeFloatBounds> = buildList {
    nativeFocusInk(nodes)?.let(::add)
    nodes.filter { it.focusPaint == null }.forEach { node ->
        node.bounds.forEach {
            val ink = nativeDelegatedDefaultFocusInk(NativeFloatBounds(it.left, it.top, it.right, it.bottom),
                density, node.missingLinkPaint != null)
            nativeDelegatedClip(ink, node.clipBounds)?.let(::add)
        }
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
        val carets = NativeTextAffinity.entries.map { affinity ->
            val token = NativeTextCaret(position, affinity)
            geometry.caretRect(token).apply { offset(x, y) } to
                geometry.clipForOffset(token)?.let { RectF(it).apply { offset(x, y) } }
        }.distinctBy { (caret, clip) -> listOf(caret.left, caret.top, caret.right, caret.bottom,
            clip?.left, clip?.top, clip?.right, clip?.bottom) }
        for ((caret, clip) in carets) {
            nativeDelegatedClip(NativeFloatBounds(caret.left, caret.top, caret.left + maxOf(1f, density), caret.bottom), clip)?.let(::add)
            val cx = caret.left.coerceIn(owner.left + radius, maxOf(owner.left + radius, owner.right - radius))
            val cy = (caret.bottom + 7 * density).coerceIn(owner.top + radius, maxOf(owner.top + radius, owner.bottom - radius))
            nativeDelegatedClip(NativeFloatBounds(cx - radius, cy - radius, cx + radius, cy + radius), clip)?.let(::add)
            nativeDelegatedClip(NativeFloatBounds(caret.left, minOf(caret.bottom, cy), caret.left + density, maxOf(caret.bottom, cy)), clip)?.let(::add)
        }
    }
}

/** Actual original-View dispatch reaches the full 24-density handle target inside its
 * physical bounds. The 6-density painted knob is not an input envelope. */
internal fun nativeDelegatedSelectionInput(geometry: FloatTextGeometry, density: Float,
    x: Float = 0f, y: Float = 0f,
    owner: NativeFloatBounds = NativeFloatBounds(0f, 0f, geometry.width.toFloat(), geometry.height.toFloat())
): List<NativeFloatBounds> {
    if (geometry.text.isEmpty()) return emptyList()
    val radius = 24f * density
    return (0..geometry.text.length).flatMap { offset ->
        NativeTextAffinity.entries.mapNotNull { affinity ->
            val (cx, cy) = nativeSelectionHandleCenter(geometry, offset, density, x, y, owner, affinity)
            val clip = geometry.clipForOffset(NativeTextCaret(offset, affinity))?.let { RectF(it).apply { offset(x, y) } }
            nativeDelegatedClip(NativeFloatBounds(maxOf(owner.left, cx - radius), maxOf(owner.top, cy - radius),
                minOf(owner.right, cx + radius), minOf(owner.bottom, cy + radius)), clip)
        }.distinct()
    }
}

internal fun nativeSelectionHandleCenter(geometry: FloatTextGeometry, offset: Int, density: Float,
    x: Float = 0f, y: Float = 0f,
    owner: NativeFloatBounds = NativeFloatBounds(0f, 0f, geometry.width.toFloat(), geometry.height.toFloat()),
    affinity: NativeTextAffinity = NativeTextAffinity.Downstream,
): Pair<Float, Float> {
    val caret = geometry.caretRect(NativeTextCaret(offset, affinity)).apply { offset(x, y) }
    val radius = minOf(6f * density, minOf(owner.width, owner.height) / 2f)
    return caret.left.coerceIn(owner.left + radius, maxOf(owner.left + radius, owner.right - radius)) to
        (caret.bottom + 7f * density).coerceIn(owner.top + radius, maxOf(owner.top + radius, owner.bottom - radius))
}
