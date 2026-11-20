package app.smallthingz.dict

/** Legacy roots have one strict-interior child. Authenticated pitch roots may have
 * two separated single-character children sharing one parent endpoint. */
internal fun nativeInlineBoxNestedParents(ranges: List<Pair<Int, Int>>,
    pitchParents: Set<Int> = emptySet()): List<Int>? {
    if (ranges.any { it.first < 0 || it.first >= it.second } ||
        pitchParents.any { it !in ranges.indices }) return null
    val parents = MutableList(ranges.size) { -1 }
    val children = IntArray(ranges.size)
    val lastChildEnd = IntArray(ranges.size) { -1 }
    val active = ArrayList<Int>(2)
    val ordered = ranges.indices.sortedWith(compareBy({ ranges[it].first }, { -ranges[it].second }))
    for (index in ordered) {
        val current = ranges[index]
        while (active.isNotEmpty() && current.first >= ranges[active.last()].second) active.removeAt(active.lastIndex)
        if (active.isNotEmpty()) {
            val parent = active.last()
            val outer = ranges[parent]
            if (active.size != 1 || current.first < outer.first || current.second > outer.second || current == outer)
                return null
            if (parent in pitchParents) {
                if (current.second - current.first != 1 || children[parent] == 2 ||
                    children[parent] > 0 && current.first <= lastChildEnd[parent]) return null
            } else if (current.first <= outer.first || current.second >= outer.second || children[parent] != 0) return null
            parents[index] = parent
            children[parent]++
            lastChildEnd[parent] = current.second
        }
        active.add(index)
    }
    return parents
}
