package app.smallthingz.dict

/** One window of the laid-out inline's composite decoration. The window does not
 * normalize corners again, even when it is narrower than the corner radius. */
internal class NativeInlineBoxCornerSlice(val fragment: NativeFloatBounds,
    val localShape: NativeTableCornerShape, val offset: Double, val compositeWidth: Double) {
    fun contains(x: Float, y: Float): Boolean =
        x >= fragment.left && x < fragment.right && y >= fragment.top && y < fragment.bottom &&
            localShape.contains(x - fragment.left, y - fragment.top)
}

/** Fragments arrive in actual inline progression: visual pieces on each line,
 * followed by the next line. Only decoration is joined; source and glyphs stay put. */
internal fun nativeInlineBoxCornerSlices(fragments: List<NativeFloatBounds>, rtl: Boolean,
    radius: Float, borderWidth: Float): List<NativeInlineBoxCornerSlice> {
    nativeInlineBoxCoordinates(radius, borderWidth)
    if (radius < 0f || borderWidth < 0f || fragments.isEmpty())
        throw UnsupportedFloatLayout("Rounded inline box lacks its source fragments")
    val widths = fragments.map { box ->
        nativeInlineBoxCoordinates(box.left, box.top, box.right, box.bottom)
        val width = box.right.toDouble() - box.left
        if (width <= 0.0 || box.bottom <= box.top)
            throw UnsupportedFloatLayout("Rounded inline box has an empty decoration fragment")
        width
    }
    val total = widths.fold(0.0) { sum, width -> sum + width }
    if (!total.isFinite()) throw UnsupportedFloatLayout("Rounded inline composite width is unavailable")
    var consumed = 0.0
    return fragments.mapIndexed { index, fragment ->
        val before = consumed
        consumed += widths[index]
        val offset = if (rtl) total - consumed else before
        // CSS slice assembles the laid-out visual fragments. Each fragment uses its
        // own height for the shared decoration; baseline/line placement is untouched.
        val height = nativeInlineBoxCoordinate(fragment.bottom.toDouble() - fragment.top)
        val usedRadius = minOf(radius.toDouble(), total / 2.0, height.toDouble() / 2.0)
        val guard = maxOf(usedRadius, borderWidth.toDouble())
        val remaining = if (rtl) before else total - consumed
        val ownsLeft = offset <= guard
        val ownsRight = remaining <= guard
        var left = if (ownsLeft) -offset else -guard
        var right = widths[index] + if (ownsRight) remaining else guard
        // Retain the actual ends only when their corner/border can reach this window.
        // A distant end is replaced outside the clip by a flat continuation. Keeping
        // room for both arcs prevents addRoundRect from renormalizing a narrow slice.
        if (!ownsLeft) left = minOf(left, right - 2.0 * guard)
        if (!ownsRight) right = maxOf(right, left + 2.0 * guard)
        val corners = NativeCornerRadii(usedRadius, usedRadius, usedRadius, usedRadius)
        val shape = NativeTableCornerShape(NativeFloatBounds(left.toFloat(), 0f, right.toFloat(), height),
            corners, borderWidth)
        if (shape.outerRadii != corners)
            throw UnsupportedFloatLayout("Rounded inline slice cannot preserve its normalized corners")
        NativeInlineBoxCornerSlice(fragment, shape, offset, total)
    }
}
