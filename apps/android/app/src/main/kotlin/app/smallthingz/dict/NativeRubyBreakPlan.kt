package app.smallthingz.dict

import kotlin.math.abs

/** Coordinates and advances are supplied by full-context native ordinary shaping.
 * A base boundary is canonicalized as (nextBaseIndex, 0); only supplied cuts may break. */
internal data class NativeRubyBaseCut(val baseIndex: Int, val offset: Int, val advance: Float)
internal data class NativeRubyReadingCut(val offset: Int, val advance: Float)
internal data class NativeRubySourceSlice(val from: Int, val to: Int)
internal data class NativeRubyBaseRange(val first: Int, val count: Int)

/** Hidden annotations are omitted. A zero sourceLength denotes a real visible-empty
 * annotation, not an exhausted nonempty reading or an invented continuation. */
internal data class NativeRubyReadingBreak(val id: Int, val baseStart: Int, val baseCount: Int,
    val sourceLength: Int, val opportunities: List<NativeRubyReadingCut>)

internal data class NativeRubyBreakFragment(val baseFrom: NativeRubyBaseCut, val baseTo: NativeRubyBaseCut,
    val readings: Map<Int, NativeRubySourceSlice>, val width: Float)

/** Positive overlap connects covered bases; adjacency alone does not. Components never
 * manufacture ordinary line opportunities at their boundaries. */
internal fun nativeRubyConnectedBaseRanges(baseCount: Int,
    readings: List<NativeRubyReadingBreak>): List<NativeRubyBaseRange> {
    require(baseCount > 0)
    val joined = BooleanArray(baseCount - 1)
    readings.forEach { reading ->
        require(reading.baseStart >= 0 && reading.baseCount > 0 && reading.baseStart <= baseCount - reading.baseCount)
        for (edge in reading.baseStart until reading.baseStart + reading.baseCount - 1) joined[edge] = true
    }
    val result = mutableListOf<NativeRubyBaseRange>()
    var first = 0
    for (edge in joined.indices) if (!joined[edge]) {
        result += NativeRubyBaseRange(first, edge + 1 - first)
        first = edge + 1
    }
    result += NativeRubyBaseRange(first, baseCount - first)
    return result.toList()
}

/** An immutable continuation snapshot. Every known reading has one original source offset. */
internal data class NativeRubyBreakCursor(val baseFrom: NativeRubyBaseCut, val readingOffsets: Map<Int, Int>)
internal data class NativeRubyBreakCandidate<T>(val width: Float, val certificate: T)
internal data class NativeRubyBreakStep<T>(val fragment: NativeRubyBreakFragment,
    val nextCursor: NativeRubyBreakCursor, val certificate: T)

/** Select paired source cuts, never infer text/grapheme opportunities. The callback owns
 * actual per-base/span allocation: max(row widths) is insufficient for partial overlaps.
 * Proportion is only a preference among admitted cuts, using measured remaining advances.
 * If no paired cut fits, the earliest legal one overflows; an unsplittable remainder stays intact. */
internal fun nativeRubyBreakPlan(baseCount: Int, baseCuts: List<NativeRubyBaseCut>,
    readings: List<NativeRubyReadingBreak>, availableWidth: Float,
    measuredWidth: (NativeRubyBaseCut, NativeRubyBaseCut, Map<Int, NativeRubySourceSlice>) -> Float,
): List<NativeRubyBreakFragment> = nativeRubyBreakPlan(baseCount, baseCuts, readings, availableWidth,
    measuredWidth, availableWidthAt = null)

/** The optional band callback is queried once for each committed fragment's source start.
 * The five-argument overload preserves existing positional and trailing-lambda callers. */
internal fun nativeRubyBreakPlan(baseCount: Int, baseCuts: List<NativeRubyBaseCut>,
    readings: List<NativeRubyReadingBreak>, availableWidth: Float,
    measuredWidth: (NativeRubyBaseCut, NativeRubyBaseCut, Map<Int, NativeRubySourceSlice>) -> Float,
    availableWidthAt: ((NativeRubyBaseCut) -> Float)? = null,
): List<NativeRubyBreakFragment> {
    validateRubyBreakInput(baseCount, baseCuts, readings, availableWidth)
    val result = mutableListOf<NativeRubyBreakFragment>()
    var cursor = NativeRubyBreakCursor(baseCuts.first(), readings.associate { it.id to 0 })
    while (cursor.baseFrom != baseCuts.last()) {
        val bandWidth = availableWidthAt?.invoke(cursor.baseFrom) ?: availableWidth
        require(bandWidth.isFinite() && bandWidth >= 0f)
        val step = checkNotNull(nextRubyBreak(baseCuts, readings, cursor, bandWidth) { from, to, slices ->
            NativeRubyBreakCandidate(measuredWidth(from, to, slices), Unit)
        }) // The full-plan callback admits the final whole remainder.
        result += step.fragment
        cursor = step.nextCursor
    }
    readings.forEach { reading -> check(cursor.readingOffsets.getValue(reading.id) == reading.sourceLength) }
    return result.toList()
}

/** Select one advancing fragment from an original-source continuation. A null trial means
 * the recursive source slice is not jointly admissible, never zero width or legal overflow.
 * Trials must be pure: only the selected certificate and cursor are committed by the caller.
 * Null result means no advancing candidate was admitted, or the supplied cursor is complete.
 * Reading alternatives use the same bounded proportional/backoff walk as the full plan. */
internal fun <T> nativeRubyNextBreak(baseCount: Int, baseCuts: List<NativeRubyBaseCut>,
    readings: List<NativeRubyReadingBreak>, cursor: NativeRubyBreakCursor, availableWidth: Float,
    measureCandidate: (NativeRubyBaseCut, NativeRubyBaseCut, Map<Int, NativeRubySourceSlice>) -> NativeRubyBreakCandidate<T>?,
): NativeRubyBreakStep<T>? {
    validateRubyBreakInput(baseCount, baseCuts, readings, availableWidth)
    return nextRubyBreak(baseCuts, readings, cursor, availableWidth, measureCandidate)
}

private fun validateRubyBreakInput(baseCount: Int, baseCuts: List<NativeRubyBaseCut>,
    readings: List<NativeRubyReadingBreak>, availableWidth: Float) {
    require(baseCount > 0 && availableWidth.isFinite() && availableWidth >= 0f)
    require(baseCuts.size >= 2 && baseCuts.first() == NativeRubyBaseCut(0, 0, 0f))
    require(baseCuts.last().baseIndex == baseCount && baseCuts.last().offset == 0)
    baseCuts.forEach { cut ->
        require(cut.baseIndex in 0..baseCount && cut.offset >= 0 &&
            (cut.baseIndex < baseCount || cut.offset == 0) && cut.advance.isFinite() && cut.advance >= 0f)
    }
    baseCuts.zipWithNext().forEach { (a, b) ->
        require(a.baseIndex < b.baseIndex || a.baseIndex == b.baseIndex && a.offset < b.offset)
        require(a.advance <= b.advance)
    }
    require(readings.map { it.id }.distinct().size == readings.size)
    readings.forEach { reading ->
        require(reading.id >= 0 && reading.baseStart >= 0 && reading.baseCount > 0 &&
            reading.baseStart <= baseCount - reading.baseCount && reading.sourceLength >= 0)
        require(reading.opportunities.isNotEmpty() && reading.opportunities.first() == NativeRubyReadingCut(0, 0f) &&
            reading.opportunities.last().offset == reading.sourceLength)
        reading.opportunities.forEach { cut ->
            require(cut.offset in 0..reading.sourceLength && cut.advance.isFinite() && cut.advance >= 0f)
        }
        reading.opportunities.zipWithNext().forEach { (a, b) ->
            require(a.offset < b.offset && a.advance <= b.advance)
        }
        require(reading.sourceLength != 0 || reading.opportunities.size == 1)
    }
}

private fun <T> nextRubyBreak(baseCuts: List<NativeRubyBaseCut>, readings: List<NativeRubyReadingBreak>,
    cursor: NativeRubyBreakCursor, availableWidth: Float,
    measureCandidate: (NativeRubyBaseCut, NativeRubyBaseCut, Map<Int, NativeRubySourceSlice>) -> NativeRubyBreakCandidate<T>?,
): NativeRubyBreakStep<T>? {
    val baseFromIndex = baseCuts.indexOf(cursor.baseFrom)
    require(baseFromIndex >= 0)
    val from = baseCuts[baseFromIndex]
    val offsets = cursor.readingOffsets.toMap()
    require(offsets.keys == readings.map { it.id }.toSet())
    val positions = IntArray(readings.size) { index ->
        val reading = readings[index]
        val offset = offsets.getValue(reading.id)
        val position = reading.opportunities.indexOfFirst { it.offset == offset }
        require(position >= 0)
        val before = from.baseIndex < reading.baseStart || from.baseIndex == reading.baseStart && from.offset == 0
        val after = from.baseIndex >= reading.baseStart + reading.baseCount
        require(when {
            before -> offset == 0
            after -> offset == reading.sourceLength
            else -> reading.sourceLength > 0 && offset > 0 && offset < reading.sourceLength
        })
        position
    }
    var selected: NativeRubyBreakFragment? = null
    var selectedCandidate: NativeRubyBreakCandidate<T>? = null
    // Descending order gives the furthest fitting ordinary base cut. The last
    // admitted non-fitting candidate retained below is the earliest legal overflowing cut.
    for (toIndex in baseCuts.lastIndex downTo baseFromIndex + 1) {
        val to = baseCuts[toIndex]
        val choices = mutableListOf<RubyReadingChoice>()
        val remaining = baseCuts.last().advance.toDouble() - from.advance
        val fraction = if (remaining > 0.0)
            ((to.advance.toDouble() - from.advance) / remaining).coerceIn(0.0, 1.0) else .5
        var joint = true
        for ((index, reading) in readings.withIndex()) {
            val endBase = reading.baseStart + reading.baseCount
            val before = to.baseIndex < reading.baseStart ||
                to.baseIndex == reading.baseStart && to.offset == 0
            val after = from.baseIndex >= endBase
            if (before || after) continue
            val begin = positions[index]
            val finishes = to.baseIndex >= endBase
            if (reading.sourceLength == 0) {
                // A real glyphless annotation has declaring bounds but no legal
                // interior break. It belongs to one intact covered association.
                if (!finishes) { joint = false; break }
                choices += RubyReadingChoice(index, begin, 0, 0)
            } else if (finishes) {
                check(begin < reading.opportunities.lastIndex)
                choices += RubyReadingChoice(index, begin, reading.opportunities.lastIndex,
                    reading.opportunities.lastIndex)
            } else {
                val first = begin + 1
                val last = reading.opportunities.lastIndex - 1
                if (first > last) { joint = false; break }
                val current = reading.opportunities[begin].advance.toDouble()
                val target = current + (reading.opportunities.last().advance - current) * fraction
                var closest = first
                for (candidate in first + 1..last) {
                    val distance = abs(reading.opportunities[candidate].advance - target)
                    val best = abs(reading.opportunities[closest].advance - target)
                    // Equal-distance admitted cuts prefer more progress; fitting may back off below.
                    if (distance <= best) closest = candidate
                }
                choices += RubyReadingChoice(index, begin, closest, first)
            }
        }
        if (!joint) continue
        var fits = false
        while (true) {
            val slices = choices.associate { choice ->
                val reading = readings[choice.reading]
                reading.id to NativeRubySourceSlice(reading.opportunities[choice.from].offset,
                    reading.opportunities[choice.to].offset)
            }
            val candidate = measureCandidate(from, to, slices)
            if (candidate != null) {
                require(candidate.width.isFinite() && candidate.width >= 0f)
                selected = NativeRubyBreakFragment(from, to, slices.toMap(), candidate.width)
                selectedCandidate = candidate
                if (candidate.width <= availableWidth) { fits = true; break }
            }
            // An inadmissible trial cannot erase an earlier admitted overflow. Both
            // refusals and oversized trials can try earlier actual reading endpoints.
            val choice = choices.filter { it.to > it.minimum }.maxByOrNull { value ->
                val cuts = readings[value.reading].opportunities
                cuts[value.to].advance - cuts[value.to - 1].advance
            } ?: break
            choice.to--
        }
        if (fits) break
    }
    val fragment = selected ?: return null
    val candidate = checkNotNull(selectedCandidate)
    val nextOffsets = offsets.toMutableMap()
    fragment.readings.forEach { (id, slice) -> nextOffsets[id] = slice.to }
    return NativeRubyBreakStep(fragment, NativeRubyBreakCursor(fragment.baseTo, nextOffsets.toMap()),
        candidate.certificate)
}

private class RubyReadingChoice(val reading: Int, val from: Int, var to: Int, val minimum: Int)
