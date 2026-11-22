package app.smallthingz.dict

/** All rectangles use one measured Entry root. Original Views retain input and AX;
 * the same root schedules their state after media without changing sibling-subtree order. */
internal data class NativeDelegatedMeasuredCell(
    val owner: Any,
    val generation: Any,
    val cell: NativeFloatBounds,
    val physicalSurface: NativeFloatBounds,
    val realInputAncestors: List<NativeDelegatedInputAncestor>,
    val ink: List<NativeFloatBounds>,
    val deferredInk: List<NativeFloatBounds>,
    val input: List<NativeFloatBounds>,
    val minimumTouchWidth: Float = 0f,
    val minimumTouchHeight: Float = 0f,
    val ordinaryStateInk: List<NativeFloatBounds> = emptyList(),
    val ordinaryInk: List<NativeFloatBounds> = ink,
    val rootOwner: Any? = null,
    val innerClip: NativeFloatBounds? = null,
    val requiresRootExtent: Boolean = false,
    val scrollableBounds: NativeFloatBounds? = null,
)

/** Innermost first; a real clipping ancestor limits reach without changing the owner. */
internal data class NativeDelegatedInputAncestor(val bounds: NativeFloatBounds, val clips: Boolean)

/** The existing root AndroidView is already above the Child slots. Its real selection
 * handles keep that priority; this is measured coverage of that View, not another owner. */
internal data class NativeDelegatedRootState(val view: Any, val surface: NativeFloatBounds,
    val clip: NativeFloatBounds, val input: List<NativeFloatBounds>,
    val fallbackInput: List<NativeFloatBounds> = emptyList())

/** Ancestor backgrounds are deliberately absent: they already precede this same child.
 * Every other painter and input owner must have a measured envelope, including focus
 * and selection ink and independently positioned descendants. A null list is unknown. */
internal data class NativeDelegatedSurroundings(
    val generation: Any,
    val allocation: NativeFloatBounds,
    val otherInk: List<NativeFloatBounds>?,
    val otherInput: List<NativeFloatBounds>?,
    val rootOwner: Any? = null,
    val rootState: NativeDelegatedRootState? = null,
    val rootFallbackInput: List<NativeFloatBounds> = emptyList(),
)

internal sealed interface NativeDelegatedPaintDecision {
    data class Permitted(val generation: Any, val owners: List<Any>) : NativeDelegatedPaintDecision
    data class Unavailable(val reason: String) : NativeDelegatedPaintDecision
}

internal fun nativeDelegatedPaintDecision(
    surroundings: NativeDelegatedSurroundings,
    cells: List<NativeDelegatedMeasuredCell>,
    expectedOwners: List<Any>,
): NativeDelegatedPaintDecision {
    fun refuse(reason: String) = NativeDelegatedPaintDecision.Unavailable(reason)
    if (cells.isEmpty() || cells.size != expectedOwners.size || cells.indices.any { cells[it].owner !== expectedOwners[it] })
        return refuse("The delegated table's original cell owners are incomplete")
    if (cells.indices.any { index -> cells.take(index).any { it.owner === cells[index].owner } })
        return refuse("The delegated table has a duplicated input owner")
    if (cells.any { it.generation !== surroundings.generation })
        return refuse("The delegated table's measured owner generation changed")
    if (surroundings.rootOwner == null || cells.any { it.rootOwner !== surroundings.rootOwner })
        return refuse("The original owners do not share the measured Entry root")
    val rootState = surroundings.rootState
        ?: return refuse("The original root state owner is unavailable")
    if (cells.any { it.owner === rootState.view }) return refuse("The root state owner duplicates a cell owner")
    val otherInk = surroundings.otherInk
        ?: return refuse("A surrounding paint envelope is unavailable")
    val otherInput = surroundings.otherInput
        ?: return refuse("A surrounding input envelope is unavailable")
    val all = listOf(surroundings.allocation, rootState.surface, rootState.clip) + rootState.input +
        rootState.fallbackInput + otherInk + otherInput + cells.flatMap {
        listOf(it.cell, it.physicalSurface) + it.realInputAncestors.map { ancestor -> ancestor.bounds } +
            it.ink + it.deferredInk + it.input + it.ordinaryStateInk + it.ordinaryInk + listOfNotNull(it.innerClip, it.scrollableBounds)
    }
    if (all.any { !it.finiteOrdered() }) return refuse("A delegated owner envelope is invalid")
    if ((rootState.input + rootState.fallbackInput).any { !rootState.surface.encloses(it) })
        return refuse("Root selection input exceeds its original physical View")
    for ((index, cell) in cells.withIndex()) {
        if (!cell.minimumTouchWidth.isFinite() || !cell.minimumTouchHeight.isFinite() ||
            cell.minimumTouchWidth < 0f || cell.minimumTouchHeight < 0f)
            return refuse("The platform minimum touch target is unavailable")
        // Cached Compose hit testing returns no minimum-target candidate when both axes
        // already reach this threshold. Smaller owners/ancestors need another join.
        if ((listOf(cell.physicalSurface) + cell.realInputAncestors.filterNot { it.clips }.map { it.bounds }).any {
                it.width < cell.minimumTouchWidth || it.height < cell.minimumTouchHeight })
            return refuse("Minimum touch expansion needs a complete delegated arbitration join")
        if (!surroundings.allocation.encloses(cell.cell))
            return refuse("The original cell extends beyond its measured table grid")
        if (cell.innerClip != cell.physicalSurface)
            return refuse("A cell-to-grid clip discards source-visible native overflow")
        // The ordinary absolute family has no late child-to-document extent export.
        // Actual root geometry, never the viewport clip, must already cover this surface.
        if (cell.requiresRootExtent && !rootState.surface.encloses(cell.physicalSurface))
            return refuse("Absolute table overflow exceeds the existing document extent")
        // Ordinary Touch must reach the original AndroidView through its actual ancestors.
        // No stylus-only expansion or direct View event forwarding establishes this condition.
        if (cell.realInputAncestors.isEmpty()) return refuse("The original input ancestry is unavailable")
        var reachable: NativeFloatBounds? = cell.physicalSurface
        for (ancestor in cell.realInputAncestors) {
            val current = reachable ?: break
            if (ancestor.clips) reachable = current.intersection(ancestor.bounds)
        }
        if ((cell.ink + cell.deferredInk + cell.input + cell.ordinaryStateInk + cell.ordinaryInk).any { !cell.physicalSurface.encloses(it) })
            return refuse("The original native surface does not contain its complete ink and input")
        if (cells.take(index).any { it.cell.overlaps(cell.cell) })
            return refuse("Delegated table cells overlap")
        val visible = reachable
        // Every original selection is painted after all media, then every focus outline.
        // Ordinary paint remains in its original slot, so inter-cell phase overlap refuses.
        if (visible != null && cell.deferredInk.any { ink ->
                ink.intersection(visible)?.let { clipped -> cells.indices.any { other ->
                    other != index && cells[other].ordinaryInk.any(clipped::overlaps)
                } } == true })
            return refuse("Deferred media overlaps another cell's ordinary paint")
        if (visible != null && cell.deferredInk.any { ink ->
                ink.intersection(visible)?.let { clipped -> otherInk.any(clipped::overlaps) } == true
            })
            return refuse("Deferred Figure ink overlaps another Entry painter")
        // The same-grid interop siblings share hit testing and reject an unowned DOWN
        // before invoking their detector. Full logical boxes and 24-density handle targets
        // are included; physical focus-only overlap never creates a new hit region.
        if (visible != null && cell.input.any { input -> input.intersection(visible)?.let { hit ->
                otherInput.any(hit::overlaps) || rootState.fallbackInput.any(hit::overlaps) || cells.take(index).any { previous ->
                    val previousVisible = previous.visibleSurface()
                    previousVisible != null && previous.input.any { prior ->
                        prior.intersection(previousVisible)?.overlaps(hit) == true
                    }
                }
            } == true })
            return refuse("Original native input domains overlap")
    }
    return NativeDelegatedPaintDecision.Permitted(surroundings.generation, cells.map { it.owner })
}

private fun NativeDelegatedMeasuredCell.visibleSurface(): NativeFloatBounds? =
    realInputAncestors.filter { it.clips }.fold(physicalSurface as NativeFloatBounds?) { area, ancestor ->
        area?.intersection(ancestor.bounds)
    }

/** The existing root accepts blank logical space except actual Child targets. Rectangle
 * subtraction preserves that complete domain; glyph-only envelopes would miss it. */
internal fun nativeInputOutsideChildren(bounds: NativeFloatBounds,
    children: List<NativeFloatBounds>): List<NativeFloatBounds> = children.fold(listOf(bounds)) { regions, child ->
    regions.flatMap { region ->
        val cut = region.intersection(child)
        if (cut == null) listOf(region) else listOf(
            NativeFloatBounds(region.left, region.top, region.right, cut.top),
            NativeFloatBounds(region.left, cut.bottom, region.right, region.bottom),
            NativeFloatBounds(region.left, cut.top, cut.left, cut.bottom),
            NativeFloatBounds(cut.right, cut.top, region.right, cut.bottom),
        ).filter { it.width > 0f && it.height > 0f }
    }
}

private fun NativeFloatBounds.finiteOrdered() =
    left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite() && left <= right && top <= bottom

private fun NativeFloatBounds.encloses(other: NativeFloatBounds) =
    left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom

private fun NativeFloatBounds.overlaps(other: NativeFloatBounds) =
    left < other.right && other.left < right && top < other.bottom && other.top < bottom

private fun NativeFloatBounds.intersection(other: NativeFloatBounds): NativeFloatBounds? {
    val l = maxOf(left, other.left)
    val t = maxOf(top, other.top)
    val r = minOf(right, other.right)
    val b = minOf(bottom, other.bottom)
    return if (l < r && t < b) NativeFloatBounds(l, t, r, b) else null
}

/** Match NativeFloatTextView's centered ordinary stroke, or its outset Missing-link
 * round rect plus half the two-density stroke. This is ink only, never a hit expansion. */
internal fun nativeDelegatedDefaultFocusInk(bounds: NativeFloatBounds, density: Float,
    missingLink: Boolean): NativeFloatBounds {
    val outset = if (missingLink) 2f * density else density / 2f
    return NativeFloatBounds(bounds.left - outset, bounds.top - outset,
        bounds.right + outset, bounds.bottom + outset)
}
