package app.smallthingz.dict

/** Placement snapshots expire on reflow; the original source binding can remain live
 * while its own reveal changes placement. No Android geometry is simulated here. */
internal class NativeClippedPublication(val binding: Any, private var current: () -> Boolean) {
    private var active = true
    private var version = 0L
    val isCurrent: Boolean get() = active && current()
    fun update(current: () -> Boolean) {
        check(active)
        this.current = current
        version++
    }
    fun retire() { active = false }
    internal fun version(): Long = version
    internal fun matches(expected: Long): Boolean = isCurrent && version == expected
}

internal class NativeClippedPublicationSnapshot(
    private val owner: NativeClippedPublication,
) {
    private val version = owner.version()
    val isCurrent: Boolean get() = owner.matches(version)
    val ownerIsCurrent: Boolean get() = owner.isCurrent
}

internal data class NativeClippedScrollEscape<T : Any>(val owner: T, val virtualIndex: Int?)

/** Identity, not equal values, chooses the real viewport boundary. Aggregate geometry
 * and a source View can expose the same viewport; its motion is removed only once. */
internal fun <T : Any> nativeClippedScrollEscapes(source: T?, boundary: T?, virtual: List<T>,
    parent: (T) -> T?): List<NativeClippedScrollEscape<T>> {
    fun descends(child: T?, ancestor: T?): Boolean {
        var current = child
        val visited = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<T, Boolean>())
        while (current !== ancestor) {
            if (current == null) return ancestor == null
            require(visited.add(current)) { "Cyclic clipped absolute viewport ancestry" }
            current = parent(current)
        }
        return true
    }
    val result = mutableListOf<NativeClippedScrollEscape<T>>()
    val included = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<T, Boolean>())
    val chain = mutableListOf<T>().apply { source?.let(::add) }
    virtual.forEachIndexed { index, viewport ->
        require(chain.all { descends(viewport, it) || descends(it, viewport) }) {
            "Unrelated clipped absolute viewport ancestry"
        }
        chain += viewport
        if (!descends(viewport, boundary)) {
            require(descends(boundary, viewport)) { "Unrelated clipped absolute viewport ancestry" }
        } else if (viewport !== boundary && included.add(viewport)) result += NativeClippedScrollEscape(viewport, index)
    }
    var current = source
    val visited = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<T, Boolean>())
    while (current !== boundary) {
        require(current != null && visited.add(current)) { "Unavailable clipped absolute viewport ancestry" }
        if (included.add(current)) result += NativeClippedScrollEscape(current, null)
        current = parent(current)
    }
    return result
}
