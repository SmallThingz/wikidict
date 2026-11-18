package app.smallthingz.dict

/** Affinity belongs to the reader's selection state, never the stored source. */
internal enum class NativeTextAffinity { Upstream, Downstream }
internal data class NativeTextCaret(val offset: Int, val affinity: NativeTextAffinity = NativeTextAffinity.Downstream) {
    init { require(offset >= 0) }
    /** Source unit whose clipping/semantic owner contains this side of the boundary. */
    val ownerOffset: Int get() = if (affinity == NativeTextAffinity.Upstream && offset > 0) offset - 1 else offset
    fun translated(delta: Int): NativeTextCaret = copy(offset = Math.addExact(offset, delta))
}
