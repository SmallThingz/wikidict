package app.smallthingz.dict

/** All rectangles use the containing Entry's measured coordinates. This proof does not
 * transport input, create nodes, or change painting; it permits an existing cell owner
 * to keep its local relative-media phase only when that phase is observationally equal. */
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
)

/** Innermost first; a real clipping ancestor limits reach without changing the owner. */
internal data class NativeDelegatedInputAncestor(val bounds: NativeFloatBounds, val clips: Boolean)

/** Ancestor backgrounds are deliberately absent: they already precede this same child.
 * Every other painter and input owner must have a measured envelope, including focus
 * and selection ink and independently positioned descendants. A null list is unknown. */
internal data class NativeDelegatedSurroundings(
    val generation: Any,
    val allocation: NativeFloatBounds,
    val otherInk: List<NativeFloatBounds>?,
    val otherInput: List<NativeFloatBounds>?,
    val atomicAllocation: NativeFloatBounds = allocation,
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
    val otherInk = surroundings.otherInk
        ?: return refuse("A surrounding paint envelope is unavailable")
    val otherInput = surroundings.otherInput
        ?: return refuse("A surrounding input envelope is unavailable")
    val all = listOf(surroundings.allocation, surroundings.atomicAllocation) + otherInk + otherInput + cells.flatMap {
        listOf(it.cell, it.physicalSurface) + it.realInputAncestors.map { ancestor -> ancestor.bounds } +
            it.ink + it.deferredInk + it.input + it.ordinaryStateInk
    }
    if (all.any { !it.finiteOrdered() }) return refuse("A delegated owner envelope is invalid")
    for ((index, cell) in cells.withIndex()) {
        if (!cell.minimumTouchWidth.isFinite() || !cell.minimumTouchHeight.isFinite() ||
            cell.minimumTouchWidth < 0f || cell.minimumTouchHeight < 0f)
            return refuse("The platform minimum touch target is unavailable")
        // Cached Compose hit testing returns no minimum-target candidate when both axes
        // already reach this threshold. Smaller owners/ancestors need another join.
        if ((listOf(cell.physicalSurface) + cell.realInputAncestors.filterNot { it.clips }.map { it.bounds }).any {
                it.width < cell.minimumTouchWidth || it.height < cell.minimumTouchHeight })
            return refuse("Minimum touch expansion needs a complete delegated arbitration join")
        if (!surroundings.allocation.encloses(cell.cell) || !cell.cell.encloses(cell.physicalSurface))
            return refuse("The original native surface extends beyond its real table cell")
        // Ordinary Touch must reach the original AndroidView through its actual ancestors.
        // No stylus-only expansion or direct View event forwarding establishes this condition.
        if (cell.realInputAncestors.isEmpty()) return refuse("The original input ancestry is unavailable")
        var reachable: NativeFloatBounds? = cell.physicalSurface
        for (ancestor in cell.realInputAncestors) {
            val current = reachable ?: break
            if (ancestor.clips) reachable = current.intersection(ancestor.bounds)
            else if (!ancestor.bounds.encloses(current))
                return refuse("The original native surface extends beyond its real input ancestry")
        }
        if (reachable != null && !surroundings.atomicAllocation.encloses(reachable))
            return refuse("The visible native owner extends beyond the delegated atomic child")
        if ((cell.ink + cell.deferredInk + cell.input + cell.ordinaryStateInk).any { !cell.physicalSurface.encloses(it) })
            return refuse("The original native surface does not contain its complete ink and input")
        if (cells.take(index).any { it.cell.overlaps(cell.cell) })
            return refuse("Delegated table cells overlap")
        val visible = reachable
        if (visible != null && cell.deferredInk.any { ink ->
                ink.intersection(visible)?.let { clipped -> cell.ordinaryStateInk.any(clipped::overlaps) } == true })
            return refuse("Deferred media overlaps another phase's focus or selection ink")
        if (visible != null && cell.deferredInk.any { ink ->
                ink.intersection(visible)?.let { clipped -> otherInk.any(clipped::overlaps) } == true
            })
            return refuse("Deferred Figure ink overlaps another Entry painter")
        // The interop View participates in the real Compose hit path using its physical
        // bounds. Reject even an empty transparent overlap; onTouch rejection is too late
        // to repair an already selected sibling scroll ancestry.
        if (visible != null && otherInput.any(visible::overlaps))
            return refuse("The original native surface overlaps another Entry input owner")
    }
    return NativeDelegatedPaintDecision.Permitted(surroundings.generation, cells.map { it.owner })
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
