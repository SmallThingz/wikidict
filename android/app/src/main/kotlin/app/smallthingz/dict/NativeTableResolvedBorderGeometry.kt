package app.smallthingz.dict

/** Physical sides remain physical when a table's logical grid runs right to left. */
internal enum class NativeTableBorderSide { Top, Right, Bottom, Left }

internal data class NativeTableBorderPoint(val x: Float, val y: Float)

internal data class NativeTableBorderRectangle(val left: Float, val top: Float,
    val right: Float, val bottom: Float) {
    init {
        require(listOf(left, top, right, bottom).all { it.isFinite() })
        require(right >= left && bottom >= top)
    }
}

internal data class NativeTableBorderWidths(val top: Float, val right: Float,
    val bottom: Float, val left: Float) {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && it >= 0f }) }

    operator fun get(side: NativeTableBorderSide): Float = when (side) {
        NativeTableBorderSide.Top -> top
        NativeTableBorderSide.Right -> right
        NativeTableBorderSide.Bottom -> bottom
        NativeTableBorderSide.Left -> left
    }
}

/** One side of a band bounded by the same outer-to-inner corner diagonals.
 * Fractional band boundaries do not change the allocated border widths. */
internal data class NativeTableBorderPolygon(val side: NativeTableBorderSide,
    val outerStart: NativeTableBorderPoint, val outerEnd: NativeTableBorderPoint,
    val innerEnd: NativeTableBorderPoint, val innerStart: NativeTableBorderPoint)

internal fun nativeTableBorderSideBand(box: NativeTableBorderRectangle,
    widths: NativeTableBorderWidths, side: NativeTableBorderSide,
    from: Float = 0f, to: Float = 1f): NativeTableBorderPolygon? {
    require(from.isFinite() && to.isFinite() && from >= 0f && to >= from && to <= 1f)
    if (widths[side] == 0f || from == to) return null
    // The caller must supply an allocated border box. An inverted inner box is
    // unavailable geometry, not permission to reduce its authored border widths.
    require(widths.left.toDouble() + widths.right <= box.right.toDouble() - box.left)
    require(widths.top.toDouble() + widths.bottom <= box.bottom.toDouble() - box.top)
    fun rectangle(fraction: Float): NativeTableBorderRectangle = NativeTableBorderRectangle(
        (box.left.toDouble() + widths.left.toDouble() * fraction).toFloat(),
        (box.top.toDouble() + widths.top.toDouble() * fraction).toFloat(),
        (box.right.toDouble() - widths.right.toDouble() * fraction).toFloat(),
        (box.bottom.toDouble() - widths.bottom.toDouble() * fraction).toFloat())
    fun endpoints(rectangle: NativeTableBorderRectangle): Pair<NativeTableBorderPoint, NativeTableBorderPoint> =
        when (side) {
            NativeTableBorderSide.Top -> NativeTableBorderPoint(rectangle.left, rectangle.top) to
                NativeTableBorderPoint(rectangle.right, rectangle.top)
            NativeTableBorderSide.Right -> NativeTableBorderPoint(rectangle.right, rectangle.top) to
                NativeTableBorderPoint(rectangle.right, rectangle.bottom)
            NativeTableBorderSide.Bottom -> NativeTableBorderPoint(rectangle.right, rectangle.bottom) to
                NativeTableBorderPoint(rectangle.left, rectangle.bottom)
            NativeTableBorderSide.Left -> NativeTableBorderPoint(rectangle.left, rectangle.bottom) to
                NativeTableBorderPoint(rectangle.left, rectangle.top)
        }
    val outerRectangle = rectangle(from)
    val innerRectangle = rectangle(to)
    // A positive physical band must survive native Float coordinates. Do not
    // turn a subpixel border at a large translated origin into an absent edge.
    require(widths.left == 0f || innerRectangle.left > outerRectangle.left)
    require(widths.top == 0f || innerRectangle.top > outerRectangle.top)
    require(widths.right == 0f || innerRectangle.right < outerRectangle.right)
    require(widths.bottom == 0f || innerRectangle.bottom < outerRectangle.bottom)
    val outer = endpoints(outerRectangle)
    val inner = endpoints(innerRectangle)
    return NativeTableBorderPolygon(side, outer.first, outer.second, inner.second, inner.first)
}

internal data class NativeTableBorderJunctionInsets(val beforeStart: Float, val afterStart: Float,
    val beforeEnd: Float, val afterEnd: Float) {
    init {
        require(listOf(beforeStart, afterStart, beforeEnd, afterEnd).all { it.isFinite() && it >= 0f })
    }
}

/** The node is a real grid intersection. Each incident edge owns its diagonal
 * portion of the intersection, including unequal and one-sided exterior bands. */
internal fun nativeTableCollapsedBorderPolygon(start: NativeTableBorderPoint,
    end: NativeTableBorderPoint, vertical: Boolean, normalBefore: Float, normalAfter: Float,
    junction: NativeTableBorderJunctionInsets): List<NativeTableBorderPoint> {
    require(listOf(start.x, start.y, end.x, end.y, normalBefore, normalAfter).all { it.isFinite() })
    require(normalBefore >= 0f && normalAfter >= 0f)
    require(if (vertical) start.x == end.x && end.y > start.y else start.y == end.y && end.x > start.x)
    if (normalBefore == 0f && normalAfter == 0f) return emptyList()
    val first = if (vertical) start.y else start.x
    val last = if (vertical) end.y else end.x
    require(junction.beforeStart.toDouble() + junction.beforeEnd <= last.toDouble() - first)
    require(junction.afterStart.toDouble() + junction.afterEnd <= last.toDouble() - first)
    fun translated(value: Float, distance: Float, positive: Boolean): Float {
        val result = (value.toDouble() + if (positive) distance.toDouble() else -distance.toDouble()).toFloat()
        require(result.isFinite() && (distance == 0f || if (positive) result > value else result < value)) {
            "Table border junction loses a positive physical extent"
        }
        return result
    }
    val before = translated(if (vertical) start.x else start.y, normalBefore, false)
    val after = translated(if (vertical) start.x else start.y, normalAfter, true)
    val beforeStart = translated(first, junction.beforeStart, true)
    val afterStart = translated(first, junction.afterStart, true)
    val beforeEnd = translated(last, junction.beforeEnd, false)
    val afterEnd = translated(last, junction.afterEnd, false)
    require(beforeEnd >= beforeStart && afterEnd >= afterStart)
    return if (vertical) listOf(start, NativeTableBorderPoint(before, beforeStart),
        NativeTableBorderPoint(before, beforeEnd), end, NativeTableBorderPoint(after, afterEnd),
        NativeTableBorderPoint(after, afterStart))
    else listOf(start, NativeTableBorderPoint(beforeStart, before),
        NativeTableBorderPoint(beforeEnd, before), end, NativeTableBorderPoint(afterEnd, after),
        NativeTableBorderPoint(afterStart, after))
}

/** A positive stroke must retain both half-widths at its actual native origin. */
internal fun nativeTableBorderStrokePreflight(center: Float, width: Float, low: Float, high: Float) {
    require(listOf(center, width, low, high).all { it.isFinite() })
    val radius = width / 2f
    require(radius > 0f && center > low && center < high &&
        center - radius < center && center + radius > center) {
        "Table border stroke loses a positive physical half-width"
    }
}
