package app.smallthingz.dict

import java.util.IdentityHashMap

internal fun nativeClearForPart(part: NativeFloatContextPart): FigureClear? = when (part) {
    is NativeFloatContextPart.Child -> part.clear
    is NativeFloatContextPart.Container -> part.clear
    is NativeFloatContextPart.Rule -> part.metrics.clear
    else -> null
}

internal fun nativeClearBottom(clear: FigureClear?, exclusions: List<NativeFloatExclusion>): Float? =
    exclusions.filter { when (clear) {
        FigureClear.Left -> it.side == TableFloatSide.Left
        FigureClear.Right -> it.side == TableFloatSide.Right
        FigureClear.Both -> true
        else -> false
    } }.maxOfOrNull { it.outer.bottom }

/** One measurement pass. Ordinary groups expose their source tree; isolated float owners
 * are measured once, while provisional placement can be recomputed without shaping text. */
internal class NativeOrdinaryPreparation(parts: List<NativeFloatContextPart>) {
    private val clearances = IdentityHashMap<NativeFloatContextPart, Boolean>()
    private val bodyLeadingFlows = IdentityHashMap<NativeFloatContextPart.Flow, Boolean>()
    private val indices = IdentityHashMap<NativeFloatContextPart, Int>()
    private val children = IdentityHashMap<NativeFloatContextPart.Child, Pair<NativeBlockMeasureRequest, NativeBlockMeasure>>()
    private val containers = IdentityHashMap<NativeFloatContextPart.Container, Pair<NativeMarginCollapse, NativeFloatContextGeometry>>()
    private val resolvedInner = IdentityHashMap<NativeFloatContextPart.Container, NativeAdjoiningMargins>()
    private var revision = 0

    init {
        fun visit(items: List<NativeFloatContextPart>) {
            items.forEach { item ->
                val nested = (item as? NativeFloatContextPart.Container)?.preparedParts
                if (nested != null) visit(nested) else {
                    check(!indices.containsKey(item)) { "One prepared part cannot have two source owners" }
                    indices[item] = indices.size
                }
            }
        }
        visit(parts)
    }

    fun sourceIndex(part: NativeFloatContextPart): Int = checkNotNull(indices[part])
    fun hasClearance(part: NativeFloatContextPart): Boolean = clearances.containsKey(part)
    fun markClearance(part: NativeFloatContextPart) {
        if (clearances.put(part, true) == null) revision++
    }
    fun innerMargins(part: NativeFloatContextPart.Container): NativeAdjoiningMargins? = resolvedInner[part]

    fun measureChild(part: NativeFloatContextPart.Child, request: NativeBlockMeasureRequest): NativeBlockMeasure {
        check(part.floatSide != null)
        children[part]?.let { (old, measured) ->
            if (old != request) throw UnsupportedFloatLayout("A prepared float requires two content measurements")
            return measured
        }
        return part.measure(request).also { children[part] = request to it }
    }

    fun measureContainer(part: NativeFloatContextPart.Container, collapse: NativeMarginCollapse,
        build: () -> NativeFloatContextGeometry): NativeFloatContextGeometry {
        fun record(geometry: NativeFloatContextGeometry): NativeFloatContextGeometry {
            geometry.adjoiningMargins?.let { resolvedInner[part] = it }
            return geometry
        }
        if (part.floatSide == null) return record(build())
        containers[part]?.let { (old, measured) ->
            check(old == collapse)
            return measured
        }
        return record(build()).also { containers[part] = collapse to it }
    }

    fun measurePreparedContainer(part: NativeFloatContextPart.Container,
        carried: List<NativeFloatExclusion>, collapse: NativeMarginCollapse): NativeFloatContextGeometry {
        val isolated = part.floatSide != null || part.isolatesFloats
        check(!isolated || carried.isEmpty()) { "An isolated owner cannot inherit outer float exclusions" }
        return measureContainer(part, collapse) {
            if (part.columns != null) {
                check(isolated && carried.isEmpty() && part.fixedContentHeight == null && part.row == null)
                NativeFloatContextGeometry.buildPreparedColumns(part.contentWidth,
                    part.horizontal?.content ?: part.contentWidth.toFloat(),
                    checkNotNull(part.preparedParts), part.columns, this)
            } else if (part.row != null) {
                check(isolated && carried.isEmpty())
                NativeFloatContextGeometry.buildPreparedRow(part.contentWidth,
                    part.horizontal?.content ?: part.contentWidth.toFloat(), checkNotNull(part.preparedParts), part.row, this,
                    part.fixedContentHeight)
            } else NativeFloatContextGeometry.build(part.contentWidth, checkNotNull(part.preparedParts),
                containAtEnd = isolated, carriedExclusions = carried, allowProtrudingFloats = !isolated,
                adjoining = true, marginCollapse = collapse, preparation = this)
        }
    }

    private fun profile(part: NativeFloatContextPart) =
        NativeFloatContextGeometry.adjoiningProfile(part, this)

    /** The selected ordinary body owns both adjoining edges at its assigned origin. */
    fun resolveBodyLeading(parts: List<NativeFloatContextPart>, width: Int) {
        require(width >= 0)
        while (true) {
            val previous = revision
            bodyLeadingFlows.clear()
            leading(parts, width, emptyList(), bodyLeading = true)
            if (previous == revision) return
        }
    }

    /** A measured zero extent does not prove that an anonymous float owner is through-empty. */
    fun checkBodyLeadingFlow(part: NativeFloatContextPart.Flow, normalFlowExtent: Float, exportsFloats: Boolean) {
        if (bodyLeadingFlows.containsKey(part) && normalFlowExtent == 0f && exportsFloats)
            throw UnsupportedFloatLayout("Ordinary body leading float flow has no structural adjoining profile")
    }

    /** Each newly established clearance removes an adjacency; this is finite structural
     * progress, not repeated measurement or a width/height convergence heuristic. */
    fun resolve(group: NativeFloatContextPart.Container, incoming: List<NativeFloatExclusion>,
        borderTop: (NativeAdjoiningMargins) -> Float) {
        check(group.preparedParts != null && group.floatSide == null && !group.isolatesFloats)
        while (true) {
            val previous = revision
            val top = borderTop(checkNotNull(profile(group))) + group.padding.top
            val x = group.horizontal?.contentLeft ?: (group.margins.left + group.padding.left)
            if (group.padding.top == 0f) {
                val carried = incoming.filter { it.outer.bottom > top }.map {
                    it.copy(outer = it.outer.translated(-x, -top))
                }
                leading(group.preparedParts, group.contentWidth, carried)
            }
            if (previous == revision) return
        }
    }

    private fun leading(parts: List<NativeFloatContextPart>, width: Int,
        incoming: List<NativeFloatExclusion>, bodyLeading: Boolean = false): List<NativeFloatExclusion> {
        val exclusions = incoming.toMutableList()
        val cursor = NativeMarginCursor(NativeMarginCollapse(true, true))
        for (part in parts) {
            if (part is NativeFloatContextPart.Container && part.absolute != null) continue
            val margins = profile(part)
            if (margins == null) {
                val normalY = tableClearanceY(cursor.floatTop, nativeClearForPart(part), exclusions)
                val placement = when (part) {
                    is NativeFloatContextPart.Child -> placeNativeFloatingTable(width.toFloat(), normalY,
                        exclusions, checkNotNull(part.floatSide), part.margins, part.widthRule,
                        pixelAligned = false) { measureChild(part, it) }.outer
                    is NativeFloatContextPart.Container -> {
                        val edgeWidth = part.horizontal?.borderWidth ?: (part.contentWidth + part.padding.left + part.padding.right)
                        placeNativeFloatingTable(width.toFloat(), normalY, exclusions,
                            checkNotNull(part.floatSide), part.margins.nonnegativeFloatMargins(), NativeBlockWidth.FixedPx(edgeWidth),
                            pixelAligned = false) {
                            val collapse = NativeMarginCollapse(false, false)
                            val measured = if (part.preparedParts != null)
                                measurePreparedContainer(part, emptyList(), collapse)
                            else measureContainer(part, collapse) {
                                val build = part.buildAdjoining
                                    ?: throw UnsupportedFloatLayout("Float adjoining content is not prepared")
                                build(part.contentWidth, emptyList(), collapse)
                            }
                            NativeBlockMeasure(edgeWidth, edgeWidth,
                                part.padding.top + part.contentHeight(measured.usedHeight) + part.padding.bottom)
                        }.outer
                    }
                    else -> error("Only a float is absent from the adjoining profile")
                }
                val side = when (part) {
                    is NativeFloatContextPart.Child -> checkNotNull(part.floatSide)
                    is NativeFloatContextPart.Container -> checkNotNull(part.floatSide)
                    else -> error("Not a float")
                }
                exclusions += NativeFloatExclusion(side, placement)
                continue
            }
            if (bodyLeading && part is NativeFloatContextPart.Flow) bodyLeadingFlows[part] = true
            // A prior pass already proved this child's clearance. Its own margin stays
            // inside the group and terminates the parent's leading adjoining chain.
            if (hasClearance(part)) return exclusions.drop(incoming.size)
            val clear = nativeClearForPart(part)
            val hypothetical = cursor.preview(margins).borderTop
            val bottom = nativeClearBottom(clear, exclusions)
            if (bottom != null && bottom > hypothetical) {
                markClearance(part)
                return exclusions.drop(incoming.size)
            }
            val placement = cursor.begin(margins)
            if (part is NativeFloatContextPart.Container && part.preparedParts != null &&
                !part.isolatesFloats && part.floatSide == null && part.padding.top == 0f) {
                val x = part.horizontal?.contentLeft ?: (part.margins.left + part.padding.left)
                val top = placement.borderTop
                val carried = exclusions.filter { it.outer.bottom > top }.map {
                    it.copy(outer = it.outer.translated(-x, -top))
                }
                val previous = revision
                val own = leading(part.preparedParts, part.contentWidth, carried, bodyLeading)
                if (previous != revision) return exclusions.drop(incoming.size)
                exclusions += own.map { it.copy(outer = it.outer.translated(x, top)) }
            }
            if (!margins.through) return exclusions.drop(incoming.size)
            cursor.end(placement, 0f, margins)
        }
        return exclusions.drop(incoming.size)
    }
}
