package app.smallthingz.dict

/** Original UTF16 source interval belonging to one clipped occurrence. */
internal data class NativeClippedSourceRange(val start: Int, val end: Int) {
    init { require(start >= 0 && end > start) }
}

internal enum class NativeClippedSourceAffinity { Before, After }

/** One unchanged source slice. Both intervals are half-open and have equal length. */
internal data class NativeClippedVisibleRange(
    val sourceStart: Int,
    val sourceEnd: Int,
    val visualStart: Int,
    val visualEnd: Int,
)

/** Removes only the declared clipped intervals from native shaping input. The full
 * original text and the individual clipped occurrence indices remain authoritative.
 * No native cursor, grapheme or static-position policy is selected here. */
internal class NativeClippedSourceMap(
    val source: String,
    clippedRanges: List<NativeClippedSourceRange>,
) {
    private val clipped = clippedRanges.map { it.copy() }
    val clippedRanges: List<NativeClippedSourceRange> get() = clipped.toList()
    private val collapsedOffsets = IntArray(clipped.size)
    private val removedThrough = IntArray(clipped.size)
    private val visible: List<NativeClippedVisibleRange>
    val visual: String

    init {
        var previousEnd = 0
        var removed = 0
        for ((index, range) in clipped.withIndex()) {
            require(range.start >= previousEnd && range.end <= source.length) {
                "Clipped source ranges must be ordered, disjoint and inside the original text"
            }
            require(sourceBoundary(range.start) && sourceBoundary(range.end)) {
                "Clipped source range splits an original surrogate pair"
            }
            collapsedOffsets[index] = range.start - removed
            removed += range.end - range.start
            removedThrough[index] = removed
            previousEnd = range.end
        }
        val output = StringBuilder(source.length - removed)
        val slices = mutableListOf<NativeClippedVisibleRange>()
        var next = 0
        fun appendThrough(end: Int) {
            if (next == end) return
            val visualStart = output.length
            output.append(source, next, end)
            slices += NativeClippedVisibleRange(next, end, visualStart, output.length)
        }
        for (range in clipped) {
            appendThrough(range.start)
            next = range.end
        }
        appendThrough(source.length)
        visual = output.toString()
        visible = slices.toList()
    }

    /** Every original UTF16 offset is addressable, including either surrogate unit.
     * An offset within clipped source maps to that occurrence's collapsed point. */
    fun toVisual(sourceOffset: Int): Int {
        require(sourceOffset in 0..source.length)
        val index = upperSourceStart(sourceOffset) - 1
        if (index < 0) return sourceOffset
        val range = clipped[index]
        return if (sourceOffset <= range.end) collapsedOffsets[index]
            else sourceOffset - removedThrough[index]
    }

    /** Adjacent clipped occurrences retain separate indices but share a visual
     * point. Its two affinities bracket the entire contiguous removed sequence. */
    fun toSource(visualOffset: Int, affinity: NativeClippedSourceAffinity): Int {
        require(visualOffset in 0..visual.length)
        val first = lowerCollapsed(visualOffset)
        if (first < clipped.size && collapsedOffsets[first] == visualOffset) {
            return when (affinity) {
                NativeClippedSourceAffinity.Before -> clipped[first].start
                NativeClippedSourceAffinity.After -> clipped[upperCollapsed(visualOffset) - 1].end
            }
        }
        return visualOffset + if (first == 0) 0 else removedThrough[first - 1]
    }

    /** Exact unchanged intersections for copying native spans or querying visible
     * rectangles. Clipped text never becomes a token or a zero-length text slice. */
    fun visibleIntersections(sourceStart: Int, sourceEnd: Int): List<NativeClippedVisibleRange> {
        checkSourceRange(sourceStart, sourceEnd)
        if (sourceStart == sourceEnd) return emptyList()
        var low = 0
        var high = visible.size
        while (low < high) {
            val mid = low + (high - low) / 2
            if (visible[mid].sourceEnd <= sourceStart) low = mid + 1 else high = mid
        }
        return buildList {
            var index = low
            while (index < visible.size && visible[index].sourceStart < sourceEnd) {
                val slice = visible[index++]
                val first = maxOf(sourceStart, slice.sourceStart)
                val last = minOf(sourceEnd, slice.sourceEnd)
                add(NativeClippedVisibleRange(first, last, slice.visualStart + first - slice.sourceStart,
                    slice.visualStart + last - slice.sourceStart))
            }
        }
    }

    /** Half-open ownership; the source EOF and a range's unshared end own no clip. */
    fun clippedRangeIndexAt(sourceOffset: Int): Int? {
        require(sourceOffset in 0..source.length)
        val index = upperSourceStart(sourceOffset) - 1
        return index.takeIf { it >= 0 && sourceOffset < clipped[it].end }
    }

    fun clippedRangeIndicesIntersecting(sourceStart: Int, sourceEnd: Int): List<Int> {
        checkSourceRange(sourceStart, sourceEnd)
        if (sourceStart == sourceEnd) return emptyList()
        var low = 0
        var high = clipped.size
        while (low < high) {
            val mid = low + (high - low) / 2
            if (clipped[mid].end <= sourceStart) low = mid + 1 else high = mid
        }
        return buildList {
            var index = low
            while (index < clipped.size && clipped[index].start < sourceEnd) add(index++)
        }
    }

    private fun checkSourceRange(start: Int, end: Int) { require(start in 0..source.length && end in start..source.length) }

    private fun sourceBoundary(offset: Int): Boolean = offset == 0 || offset == source.length ||
        !(source[offset - 1].isHighSurrogate() && source[offset].isLowSurrogate())

    private fun upperSourceStart(offset: Int): Int {
        var low = 0
        var high = clipped.size
        while (low < high) {
            val mid = low + (high - low) / 2
            if (clipped[mid].start <= offset) low = mid + 1 else high = mid
        }
        return low
    }

    private fun lowerCollapsed(offset: Int): Int {
        var low = 0
        var high = clipped.size
        while (low < high) {
            val mid = low + (high - low) / 2
            if (collapsedOffsets[mid] < offset) low = mid + 1 else high = mid
        }
        return low
    }

    private fun upperCollapsed(offset: Int): Int {
        var low = 0
        var high = clipped.size
        while (low < high) {
            val mid = low + (high - low) / 2
            if (collapsedOffsets[mid] <= offset) low = mid + 1 else high = mid
        }
        return low
    }
}
