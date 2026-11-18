package app.smallthingz.dict

/** A disjoint set of flat owners, optionally with one strictly interior child per root.
 * Shared endpoints, crossings and deeper trees have no selected native contract. */
internal fun nativeInlineBoxNestedParents(ranges: List<Pair<Int, Int>>): List<Int>? {
    if (ranges.any { it.first < 0 || it.first >= it.second }) return null
    val parents = MutableList(ranges.size) { -1 }
    val children = BooleanArray(ranges.size)
    val active = ArrayList<Int>(2)
    val ordered = ranges.indices.sortedWith(compareBy({ ranges[it].first }, { -ranges[it].second }))
    for (index in ordered) {
        val current = ranges[index]
        while (active.isNotEmpty() && current.first >= ranges[active.last()].second) active.removeAt(active.lastIndex)
        if (active.isNotEmpty()) {
            val parent = active.last()
            val outer = ranges[parent]
            if (active.size != 1 || current.first <= outer.first || current.second >= outer.second || children[parent]) return null
            parents[index] = parent
            children[parent] = true
        }
        active.add(index)
    }
    return parents
}
