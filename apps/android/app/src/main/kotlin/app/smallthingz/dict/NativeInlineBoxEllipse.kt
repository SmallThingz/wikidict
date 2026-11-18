package app.smallthingz.dict

/** One unsplit decoration; only its physical windows move when the inline wraps. */
internal data class NativeInlineBoxEllipseShape(val width: Double, val height: Double,
    val radiusX: Double, val radiusY: Double, val borderWidth: Float) {
    init {
        require(listOf(width, height, radiusX, radiusY).all { it.isFinite() && it >= 0.0 })
        require(width > 0.0 && height > 0.0 && borderWidth.isFinite() && borderWidth >= 0f)
        require(radiusX <= width / 2.0 && radiusY <= height / 2.0)
        require(borderWidth.toDouble() * 2.0 <= minOf(width, height))
    }

    fun contains(x: Double, y: Double): Boolean {
        if (!x.isFinite() || !y.isFinite() || x < 0.0 || x >= width || y < 0.0 || y >= height) return false
        if (radiusX == 0.0 || radiusY == 0.0) return true
        val dx = when { x < radiusX -> (radiusX - x) / radiusX
            x > width - radiusX -> (x - (width - radiusX)) / radiusX
            else -> 0.0 }
        val dy = when { y < radiusY -> (radiusY - y) / radiusY
            y > height - radiusY -> (y - (height - radiusY)) / radiusY
            else -> 0.0 }
        return dx == 0.0 || dy == 0.0 || dx * dx + dy * dy <= 1.0
    }
}

internal data class NativeInlineBoxEllipseSlice(val fragment: NativeFloatBounds,
    val shape: NativeInlineBoxEllipseShape, val offset: Double) {
    fun contains(x: Float, y: Float): Boolean =
        x >= fragment.left && x < fragment.right && y >= fragment.top && y < fragment.bottom &&
            shape.contains(offset + (x.toDouble() - fragment.left), y.toDouble() - fragment.top)
}

/** Percentages resolve on independent unsplit axes, never a fragment's width. */
internal fun nativeInlineBoxEllipseSlices(fragments: List<NativeFloatBounds>, rtl: Boolean,
    radius: Float, percentage: Boolean, borderWidth: Float): List<NativeInlineBoxEllipseSlice> {
    if (!radius.isFinite() || radius < 0f || !borderWidth.isFinite() || borderWidth < 0f || fragments.isEmpty())
        throw UnsupportedFloatLayout("Elliptical inline box lacks its source fragments")
    val widths = fragments.map { box ->
        nativeInlineBoxCoordinates(box.left, box.top, box.right, box.bottom)
        val width = box.right.toDouble() - box.left
        if (width <= 0.0 || box.bottom <= box.top)
            throw UnsupportedFloatLayout("Elliptical inline box has an empty decoration fragment")
        width
    }
    val total = widths.sum()
    if (!total.isFinite() || total <= 0.0)
        throw UnsupportedFloatLayout("Elliptical inline composite width is unavailable")
    val factor = minOf(radius.toDouble() / 100.0, 0.5)
    val shapes = mutableMapOf<Double, NativeInlineBoxEllipseShape>()
    var consumed = 0.0
    return fragments.mapIndexed { index, fragment ->
        val before = consumed
        consumed += widths[index]
        val height = fragment.bottom.toDouble() - fragment.top
        if (borderWidth.toDouble() * 2.0 > minOf(total, height))
            throw UnsupportedFloatLayout("Elliptical inline border exceeds its composite box")
        val shape = shapes.getOrPut(height) {
            val circular = minOf(radius.toDouble(), total / 2.0, height / 2.0)
            NativeInlineBoxEllipseShape(total, height,
                if (percentage) total * factor else circular,
                if (percentage) height * factor else circular, borderWidth)
        }
        NativeInlineBoxEllipseSlice(fragment, shape, if (rtl) total - consumed else before)
    }
}

/** The native contour uses Float, while source/composite accounting stays Double.
 * Use four half-ULP allowances below 1/64 device pixel and 1/64 of the
 * window width, height and positive border width. This checks coordinate
 * conversion, not the native curve approximation or total dot-phase error. Refuse unrepresentable windows instead of
 * flattening their corners, losing a dot stroke, or collapsing their extent. */
internal fun nativeInlineBoxEllipseNativePrecision(shape: NativeInlineBoxEllipseShape,
    offset: Double, windowWidth: Double) {
    if (!offset.isFinite() || !windowWidth.isFinite() || offset < 0.0 || windowWidth <= 0.0 ||
        offset + windowWidth > shape.width)
        throw UnsupportedFloatLayout("Elliptical inline window is unavailable")
    val feature = minOf(windowWidth, shape.height,
        if (shape.borderWidth > 0f) shape.borderWidth.toDouble() else Double.POSITIVE_INFINITY)
    val tolerance = minOf(1.0 / 64.0, feature / 64.0)
    val magnitude = maxOf(shape.width, shape.height, shape.radiusX, shape.radiusY,
        offset, offset + windowWidth).toFloat()
    val accumulatedRoundoff = Math.ulp(magnitude).toDouble() * 2.0
    if (!magnitude.isFinite() || accumulatedRoundoff > tolerance ||
        (offset + windowWidth).toFloat() <= offset.toFloat())
        throw UnsupportedFloatLayout("Elliptical inline composite loses native window precision")
}
