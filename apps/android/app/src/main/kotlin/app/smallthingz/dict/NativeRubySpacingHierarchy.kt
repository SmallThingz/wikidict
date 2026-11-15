package app.smallthingz.dict

import java.util.Collections

/** Eligibility is resolved with the complete source language/script context, not
 * by reclassifying a Common punctuation edge after a native row is split. */
internal data class NativeRubySpacingEdge(val text: String, val eligible: Boolean) {
    init { require(text.isNotEmpty()) }
}

internal fun nativeRubySpacingJoin(left: NativeRubySpacingEdge, right: NativeRubySpacingEdge): Boolean =
    left.eligible && right.eligible && nativeRubySpacingEdgeAllowed(left.text, right.text)

internal data class NativeRubySpacingSourcePiece(val start: Int, val end: Int,
    val profile: NativeRubySpacingProfile)

/** Complete BASE source only. Private tokens/readings cannot manufacture an
 * opportunity. Counts and edge eligibility retain the actual native shaping proof. */
internal class NativeRubySpacingProfile private constructor(
    val units: Int,
    val firstEdge: NativeRubySpacingEdge?,
    val lastEdge: NativeRubySpacingEdge?,
    val interiorOpportunities: Int,
    val physicalEdges: Pair<NativeRubySpacingEdge, NativeRubySpacingEdge>? = null,
    val retainedGap: Boolean = false,
) {
    val sourceEmpty: Boolean get() = units == 0
    val firstUnit: String? get() = firstEdge?.text
    val lastUnit: String? get() = lastEdge?.text
    val zeroOpportunities: Boolean get() = interiorOpportunities == 0 && firstEdge?.eligible != true && lastEdge?.eligible != true

    init {
        require(units >= 0 && interiorOpportunities >= 0)
        require(if (sourceEmpty) firstEdge == null && lastEdge == null && physicalEdges == null &&
            interiorOpportunities == 0 && !retainedGap else firstEdge != null && lastEdge != null)
    }

    fun withPhysicalEdges(first: NativeRubySpacingEdge?, last: NativeRubySpacingEdge?): NativeRubySpacingProfile {
        if (sourceEmpty) { require(first == null && last == null); return this }
        return NativeRubySpacingProfile(units, firstEdge, lastEdge, interiorOpportunities,
            checkNotNull(first) to checkNotNull(last), retainedGap)
    }

    companion object {
        private fun checkedPolicy(text: String, boundaries: List<Int>, languageAt: (Int) -> String,
            provedCuts: List<Int>, complete: Boolean): NativeRubySpacingEligibility {
            if (!complete || '\ufffc' in text)
                throw UnsupportedFloatLayout("Ruby hierarchy requires complete original base source")
            val policy = nativeRubySpacingEligibility(text, boundaries, languageAt)
            if (policy.units.isEmpty()) throw UnsupportedFloatLayout("Ruby hierarchy requires nonempty base source")
            if (provedCuts.size != policy.cuts.size || provedCuts.sorted() != policy.cuts.sorted())
                throw UnsupportedFloatLayout("Ruby hierarchy lacks complete native shaping proof")
            return policy
        }
        private fun edge(text: String, boundaries: List<Int>, policy: NativeRubySpacingEligibility, index: Int) =
            NativeRubySpacingEdge(text.substring(boundaries[index], boundaries[index + 1]), policy.units[index])

        fun source(text: String, boundaries: List<Int>, languageAt: (Int) -> String,
            provedCuts: List<Int>, complete: Boolean): NativeRubySpacingProfile {
            val policy = checkedPolicy(text, boundaries, languageAt, provedCuts, complete)
            return NativeRubySpacingProfile(policy.units.size, edge(text, boundaries, policy, 0),
                edge(text, boundaries, policy, policy.units.lastIndex), policy.cuts.size)
        }

        /** Only proved eligible cuts split a native run. An ineligible span, including
         * its complete shaping clusters, stays in one intact dispatched piece. */
        fun sourcePieces(text: String, boundaries: List<Int>, languageAt: (Int) -> String,
            provedCuts: List<Int>, complete: Boolean): List<NativeRubySpacingSourcePiece> {
            val policy = checkedPolicy(text, boundaries, languageAt, provedCuts, complete)
            return (listOf(0) + policy.cuts.sorted() + text.length).zipWithNext().map { (start, end) ->
                val first = boundaries.binarySearch(start); val last = boundaries.binarySearch(end) - 1
                check(first >= 0 && last >= first)
                NativeRubySpacingSourcePiece(start, end, NativeRubySpacingProfile(last - first + 1,
                    edge(text, boundaries, policy, first), edge(text, boundaries, policy, last), 0))
            }
        }

        /** Existing all-grapheme controls remain useful, but a mixed native source
         * must use sourcePieces so an unproved ineligible boundary is never sliced. */
        fun sourceUnits(text: String, boundaries: List<Int>, languageAt: (Int) -> String,
            provedCuts: List<Int>, complete: Boolean): List<NativeRubySpacingProfile> {
            val pieces = sourcePieces(text, boundaries, languageAt, provedCuts, complete)
            if (pieces.size != boundaries.size - 1)
                throw UnsupportedFloatLayout("Ruby source units contain an indivisible native piece")
            return pieces.map { it.profile }
        }

        /** Only a genuinely empty original base identity may create this profile.
         * Its owner remains a physical item; no source unit or edge is invented. */
        fun sourceEmpty(): NativeRubySpacingProfile = NativeRubySpacingProfile(0, null, null, 0)

        /** Only the core's retained structural-gap metadata may create this item.
         * Its measured width/paint/source mapping stays an ordinary intact atom. */
        fun retainedGap(): NativeRubySpacingProfile {
            val edge = NativeRubySpacingEdge(" ", false)
            return NativeRubySpacingProfile(1, edge, edge, 0, edge to edge, retainedGap = true)
        }

        fun compose(children: List<NativeRubySpacingProfile>, physicalOrder: List<Int>,
            complete: Boolean): NativeRubySpacingProfile {
            if (!complete || children.isEmpty() || physicalOrder.sorted() != children.indices.toList())
                throw UnsupportedFloatLayout("Ruby hierarchy requires complete physical base profiles")
            fun physical(profile: NativeRubySpacingProfile) = profile.physicalEdges ?: run {
                val first = checkNotNull(profile.firstEdge); val last = checkNotNull(profile.lastEdge)
                if (first.eligible || last.eligible)
                    throw UnsupportedFloatLayout("Ruby hierarchy lacks measured physical source edges")
                first to last
            }
            val sourced = children.filterNot { it.sourceEmpty }
            if (sourced.isEmpty()) return sourceEmpty()
            val edges = physicalOrder.map { children[it] }.filterNot { it.sourceEmpty }.map(::physical)
            val count = children.sumOf { it.interiorOpportunities.toLong() } +
                edges.zipWithNext().count { (left, right) -> nativeRubySpacingJoin(left.second, right.first) }
            val units = children.sumOf { it.units.toLong() }
            if (units > Int.MAX_VALUE || count > Int.MAX_VALUE)
                throw UnsupportedFloatLayout("Ruby hierarchy exceeds source coordinate limits")
            return NativeRubySpacingProfile(units.toInt(), sourced.first().firstEdge, sourced.last().lastEdge,
                count.toInt(), edges.first().first to edges.last().second)
        }
    }
}

/** Only ADDED allocation. A child retains its existing intrinsic alignment, then
 * receives these physical edge amounts and this amount at each eligible interior. */
internal data class NativeRubySpacingIncrement(val left: Float, val right: Float, val unit: Float) {
    init { require(listOf(left, right, unit).all { it.isFinite() && it >= 0f && it <= TablePixelLimit }) }
    val isZero: Boolean get() = left == 0f && right == 0f && unit == 0f
    fun width(profile: NativeRubySpacingProfile): Float {
        val value = left.toDouble() + right + profile.interiorOpportunities.toDouble() * unit
        if (!value.isFinite() || value > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby spacing increment exceeds native coordinates")
        return value.toFloat()
    }
}

/** A physically ordered occurrence, not a source Span equality key. currentWidth
 * includes all original intrinsic/annotation-induced allocation and structural gaps. */
internal data class NativeRubyHierarchyItem(
    val occurrence: Any,
    val profile: NativeRubySpacingProfile,
    val currentWidth: Float,
    val nested: Boolean,
    val reversedEdges: Boolean,
)

internal data class NativeRubyHierarchyPlacement(
    val occurrence: Any,
    val prefixIncrement: Float,
    val widthIncrement: Float,
    val newWidth: Float,
    val ordinaryInteriorIncrement: Float,
    val increment: NativeRubySpacingIncrement,
)

internal class NativeRubyHierarchyPlan internal constructor(
    val unit: Float,
    val leadingIncrement: Float,
    val trailingIncrement: Float,
    gaps: List<Float>,
    placements: List<NativeRubyHierarchyPlacement>,
) {
    val gaps: List<Float> = Collections.unmodifiableList(ArrayList(gaps))
    val placements: List<NativeRubyHierarchyPlacement> = Collections.unmodifiableList(ArrayList(placements))
}

/** Intrinsic slack and the parent's added budget are separate. Eligible joins get
 * one unit; nested children receive their adjoining halves, and the external gap
 * keeps the nonnegative remainder. Ineligible joins never acquire spacing. */
internal fun nativeRubyHierarchyPlan(items: List<NativeRubyHierarchyItem>, extra: Float,
    parentIncrement: NativeRubySpacingIncrement? = null): NativeRubyHierarchyPlan {
    require(extra.isFinite() && extra >= 0f && extra <= TablePixelLimit)
    require(items.isNotEmpty())
    require(items.all { it.currentWidth.isFinite() && it.currentWidth >= 0f && it.currentWidth <= TablePixelLimit })
    require(items.indices.all { index -> (0 until index).none { items[it].occurrence === items[index].occurrence } })
    fun edges(item: NativeRubyHierarchyItem) = item.profile.physicalEdges ?: if (item.reversedEdges)
        checkNotNull(item.profile.lastEdge) to checkNotNull(item.profile.firstEdge)
        else checkNotNull(item.profile.firstEdge) to checkNotNull(item.profile.lastEdge)
    // Source-empty owners keep their physical widths/paint. Only eligibility looks
    // across them; real SPACE and nonempty zero-font source remain in this sequence.
    val sourced = items.indices.filterNot { items[it].profile.sourceEmpty }
    val joins = sourced.zipWithNext().filter { (left, right) ->
        nativeRubySpacingJoin(edges(items[left]).second, edges(items[right]).first)
    }
    val opportunities = items.sumOf { it.profile.interiorOpportunities.toLong() } + joins.size
    if (opportunities > Int.MAX_VALUE) throw UnsupportedFloatLayout("Ruby hierarchy exceeds source coordinate limits")
    val intrinsicUnit = extra.toDouble() / (opportunities + 1.0)
    val unit = intrinsicUnit + (parentIncrement?.unit ?: 0f)
    val outerLeft = intrinsicUnit / 2.0 + (parentIncrement?.left ?: 0f)
    val outerRight = intrinsicUnit / 2.0 + (parentIncrement?.right ?: 0f)
    if (listOf(unit, outerLeft, outerRight).any { !it.isFinite() || it > TablePixelLimit })
        throw UnsupportedFloatLayout("Ruby hierarchy exceeds native coordinates")
    val leftShares = DoubleArray(items.size)
    val rightShares = DoubleArray(items.size)
    val gapShares = DoubleArray(items.size - 1)
    joins.forEach { (left, right) ->
        if (items[left].nested) rightShares[left] += unit / 2.0 else gapShares[left] += unit / 2.0
        if (items[right].nested) leftShares[right] += unit / 2.0 else gapShares[right - 1] += unit / 2.0
    }
    val firstAbsorbs = items.first().nested && !items.first().profile.sourceEmpty
    val lastAbsorbs = items.last().nested && !items.last().profile.sourceEmpty
    if (firstAbsorbs) leftShares[0] += outerLeft
    if (lastAbsorbs) rightShares[items.lastIndex] += outerRight
    val increments = items.mapIndexed { index, item ->
        if (item.profile.sourceEmpty) NativeRubySpacingIncrement(0f, 0f, 0f)
        else NativeRubySpacingIncrement(leftShares[index].toFloat(), rightShares[index].toFloat(), unit.toFloat())
    }
    val leading = if (firstAbsorbs) 0f else outerLeft.toFloat()
    val trailing = if (lastAbsorbs) 0f else outerRight.toFloat()
    // Shares are accumulated in Double before Float conversion, retaining the
    // exact nonnegative full/half-unit join budget for directly adjacent owners.
    val gaps = gapShares.map { it.toFloat() }
    var prefix = leading.toDouble()
    val placements = items.mapIndexed { index, item ->
        val increment = increments[index]
        val growth = increment.width(item.profile)
        val newWidth = item.currentWidth.toDouble() + growth
        if (!newWidth.isFinite() || newWidth > TablePixelLimit || prefix > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby hierarchy exceeds native coordinates")
        NativeRubyHierarchyPlacement(item.occurrence, prefix.toFloat(), growth, newWidth.toFloat(),
            if (item.nested || item.profile.sourceEmpty) 0f else unit.toFloat(), increment).also {
            prefix += growth
            if (index < gaps.size) prefix += gaps[index]
        }
    }
    return NativeRubyHierarchyPlan(unit.toFloat(), leading, trailing, gaps, placements)
}
