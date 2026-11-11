package app.smallthingz.dict

/** Aligned used extents relative to the native baseline. These are not glyph ink bounds. */
internal data class NativeUsedLineMetrics(val top: Float, val bottom: Float) {
    init { require(top.isFinite() && bottom.isFinite() && bottom >= top && (bottom - top).isFinite()) }
    val height: Float get() = bottom - top

    /** Includes the parent strut and every aligned inline/replaced box on this native line. */
    fun including(other: NativeUsedLineMetrics) = NativeUsedLineMetrics(minOf(top, other.top), maxOf(bottom, other.bottom))
}

/** Font ascent is signed. Negative half-leading is retained, including authored height zero. */
internal fun nativeInlineLineMetrics(fontAscent: Float, fontDescent: Float,
    usedLineHeight: Float, baselineShift: Float = 0f): NativeUsedLineMetrics {
    require(listOf(fontAscent, fontDescent, usedLineHeight, baselineShift).all { it.isFinite() })
    require(fontDescent >= fontAscent && usedLineHeight >= 0f)
    val halfLeading = (usedLineHeight.toDouble() - (fontDescent.toDouble() - fontAscent)) / 2.0
    return NativeUsedLineMetrics((fontAscent - halfLeading + baselineShift).toFloat(),
        (fontDescent + halfLeading + baselineShift).toFloat())
}

/** Logical flow allocation and signed overflow travel together, without an intrinsic-size feedback. */
internal data class NativeGeometryExtents(val usedWidth: Int, val usedHeight: Float,
    val ink: NativeFloatBounds?, val interaction: NativeFloatBounds?) {
    init { require(usedWidth >= 0 && usedHeight.isFinite() && usedHeight >= 0f) }

    /** A descendant's signed origin survives without changing this owner's flow allocation. */
    fun including(child: NativeGeometryExtents, x: Float, y: Float) = copy(
        ink = enclosingBounds(ink, child.ink?.translatedForSurface(x, y)),
        interaction = enclosingBounds(interaction, child.interaction?.translatedForSurface(x, y)))
}

private fun NativeFloatBounds.translatedForSurface(x: Float, y: Float): NativeFloatBounds {
    val values = listOf(left.toDouble() + x, top.toDouble() + y, right.toDouble() + x, bottom.toDouble() + y)
    if (values.any { !it.isFinite() || kotlin.math.abs(it) > Int.MAX_VALUE / 4.0 })
        throw UnsupportedFloatLayout("Native descendant overflow exceeds the surface coordinate range")
    return NativeFloatBounds(values[0].toFloat(), values[1].toFloat(), values[2].toFloat(), values[3].toFloat())
}

internal fun NativeFloatBounds.enclosing(other: NativeFloatBounds) = NativeFloatBounds(
    minOf(left, other.left), minOf(top, other.top), maxOf(right, other.right), maxOf(bottom, other.bottom))

internal fun enclosingBounds(left: NativeFloatBounds?, right: NativeFloatBounds?): NativeFloatBounds? =
    if (left == null) right else if (right == null) left else left.enclosing(right)

/** One physical painting/input surface, separate from the parent's used width and height. */
internal data class NativeSurfaceBox(val left: Int, val top: Int, val width: Int, val height: Int) {
    init { require(width >= 0 && height >= 0) }
    companion object {
        fun from(extents: NativeGeometryExtents): NativeSurfaceBox {
            val logical = NativeFloatBounds(0f, 0f, extents.usedWidth.toFloat(), extents.usedHeight)
            val area = checkNotNull(enclosingBounds(enclosingBounds(logical, extents.ink), extents.interaction))
            val left = kotlin.math.floor(area.left.toDouble())
            val top = kotlin.math.floor(area.top.toDouble())
            val right = kotlin.math.ceil(area.right.toDouble())
            val bottom = kotlin.math.ceil(area.bottom.toDouble())
            val limit = Int.MAX_VALUE / 4.0
            if (listOf(left, top, right, bottom).any { !it.isFinite() || kotlin.math.abs(it) > limit } ||
                right - left > limit || bottom - top > limit)
                throw UnsupportedFloatLayout("Native signed overflow exceeds the surface coordinate range")
            return NativeSurfaceBox(left.toInt(), top.toInt(), (right - left).toInt(), (bottom - top).toInt())
        }
    }
}

/** A successful zero-sized geometry is distinct from unavailable/unmeasured geometry. */
internal sealed interface NativeGeometryOutcome<out T> {
    data class Ready<T>(val geometry: T, val extents: NativeGeometryExtents) : NativeGeometryOutcome<T>
    data class Unavailable(val reason: String) : NativeGeometryOutcome<Nothing>
}

/**
 * The same composed child publishes one atomic result for an immutable complete input key.
 * The key must snapshot owner/content, style/font/media revision, density/fontScale/direction,
 * root viewport, actual constraints and copied exclusions. A parent may reuse a matching result
 * when Compose skips remeasure; changed keys cannot see the previous result. Actual failure must
 * publish Unavailable for that key, replacing any prior Ready result.
 */
internal class NativeGeometryPublication<K : Any, T : Any> {
    internal class Attempt<K : Any> internal constructor(val key: K)
    private data class Published<K, T>(val key: K, val outcome: T)
    private var selected: K? = null
    private var attempt: Attempt<K>? = null
    private var published: Published<K, T>? = null

    /** Selecting the same input preserves a cached measure. A different input cannot reuse it. */
    fun select(key: K) {
        if (selected == key) return
        selected = key
        attempt = null
        published = null
    }

    /** Only the actual child measure calls this, never a parent's possibly cached measure call. */
    fun begin(key: K): Attempt<K> {
        check(selected == key)
        published = null
        return Attempt(key).also { attempt = it }
    }

    fun forInput(key: K): T? = published?.takeIf { selected == key && it.key == key }?.outcome
    fun isCurrent(ticket: Attempt<K>): Boolean = attempt === ticket && selected == ticket.key

    /** Callback re-entry, a new attempt or detach makes an old completion ineligible. */
    fun publish(ticket: Attempt<K>, outcome: T): Boolean {
        if (!isCurrent(ticket)) return false
        published = Published(ticket.key, outcome)
        attempt = null
        return true
    }

    fun ownerDetached() { selected = null; attempt = null; published = null }
}
