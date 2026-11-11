package app.smallthingz.dict

import kotlin.math.max

/** Computed pixels; gap has already been normalized to the normal-body font basis. */
internal data class NativeColumnPolicy(val count: Int, val gap: Float, val rtl: Boolean) {
    init { require(count in 1..65535 && gap.isFinite() && gap >= 0f) }
    fun width(containingWidth: Float): Float {
        require(containingWidth.isFinite() && containingWidth >= 0f)
        return max(0.0, (containingWidth.toDouble() - (count - 1) * gap.toDouble()) / count).toFloat()
    }
    fun left(column: Int, containingWidth: Float): Float {
        require(column in 0 until count)
        val width = width(containingWidth)
        val value = if (rtl) containingWidth.toDouble() - width - column * (width.toDouble() + gap)
            else column * (width.toDouble() + gap)
        if (!value.isFinite() || kotlin.math.abs(value) > TablePixelLimit)
            throw UnsupportedFloatLayout("Column origin exceeds native geometry")
        return value.toFloat()
    }
    fun intrinsic(content: Float): Float {
        val result = count * content.toDouble() + (count - 1) * gap.toDouble()
        if (!result.isFinite() || result > TablePixelLimit)
            throw UnsupportedFloatLayout("Column intrinsic width exceeds native geometry")
        return result.toFloat()
    }
}

/** One actual native line, in source order. A paragraph is never re-created per column. */
internal data class NativeColumnLine(val owner: Int, val line: Int, val height: Float,
    val gapBefore: Float = 0f) {
    init { require(owner >= 0 && line >= 0 && height.isFinite() && height >= 0f &&
        gapBefore.isFinite() && gapBefore >= 0f) }
}
internal data class NativeColumnPlacement(val column: Int, val top: Float)
internal data class NativeColumnBalance(val placements: List<NativeColumnPlacement>, val height: Float,
    val breaks: List<Int>)

/** Minimize the largest used column height, retaining the initial two-line widow/orphan rule.
 * Feasibility uses a sliding minimum over legal source boundaries, not block partitioning.
 * No shaping or child measurement occurs during balancing. Gaps at column breaks disappear. */
internal fun balanceNativeColumns(lines: List<NativeColumnLine>, count: Int): NativeColumnBalance {
    require(count in 1..65535)
    if (lines.isEmpty()) return NativeColumnBalance(emptyList(), 0f, emptyList())
    val size = lines.size
    val tops = DoubleArray(size)
    val bottoms = DoubleArray(size)
    val first = IntArray(size)
    val last = IntArray(size)
    var y = 0.0
    var start = 0
    while (start < size) {
        var end = start + 1
        require(lines[start].line == 0)
        while (end < size && lines[end].owner == lines[start].owner) {
            require(lines[end].line == end - start)
            end++
        }
        for (i in start until end) {
            if (i > 0) y += lines[i].gapBefore
            tops[i] = y
            y += lines[i].height
            bottoms[i] = y
            first[i] = start
            last[i] = end
        }
        start = end
    }
    if (!y.isFinite() || y > TablePixelLimit)
        throw UnsupportedFloatLayout("Column source extent exceeds native geometry")
    fun legalBoundary(index: Int): Boolean = index == 0 || index == size ||
        lines[index - 1].owner != lines[index].owner ||
        index - first[index] >= 2 && last[index] - index >= 2
    data class Partition(val previous: IntArray, val columns: Int)
    fun partition(limit: Double): Partition? {
        val unreachable = size + 1
        val used = IntArray(size + 1) { unreachable }
        val previous = IntArray(size + 1) { -1 }
        val queue = IntArray(size + 1)
        var head = 0
        var tail = 0
        var inserted = 0
        used[0] = 0
        for (end in 1..size) {
            // Two consecutive breaks inside one paragraph cannot leave a one-line fragment.
            val upper = if (end < size && lines[end - 1].owner == lines[end].owner)
                end - 2 else if (end - first[end - 1] > 1) end - 2 else end - 1
            while (inserted <= upper) {
                val index = inserted++
                if (legalBoundary(index) && used[index] < count) {
                    while (tail > head && used[queue[tail - 1]] >= used[index]) tail--
                    queue[tail++] = index
                }
            }
            while (head < tail && bottoms[end - 1] - tops[queue[head]] > limit) head++
            if (!legalBoundary(end) || head == tail) continue
            used[end] = used[queue[head]] + 1
            previous[end] = queue[head]
        }
        return if (used[size] <= count) Partition(previous, used[size]) else null
    }
    var low = 0.0
    var high = y
    var best = checkNotNull(partition(high))
    // Double precision keeps fractional line metrics; the output is the actual chosen extent.
    repeat(56) {
        val middle = (low + high) / 2.0
        val next = partition(middle)
        if (next == null) low = middle else { high = middle; best = next }
    }
    val breaks = mutableListOf(size)
    var end = size
    while (end > 0) { end = best.previous[end]; check(end >= 0); breaks += end }
    breaks.reverse()
    val placements = MutableList(size) { NativeColumnPlacement(0, 0f) }
    var height = 0.0
    for (column in 0 until breaks.lastIndex) {
        val a = breaks[column]
        val b = breaks[column + 1]
        height = max(height, bottoms[b - 1] - tops[a])
        for (i in a until b) placements[i] = NativeColumnPlacement(column, (tops[i] - tops[a]).toFloat())
    }
    return NativeColumnBalance(placements, height.toFloat(), breaks)
}
