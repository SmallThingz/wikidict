package app.smallthingz.dict

/** Solved normal-flow offsets are signed; they are not authored FloatMargins.
 * Allocation is distinct from actual border/collision/paint extents. */
internal sealed interface NativeContainerMargins {
    val top: Float
    val right: Float
    val bottom: Float
    val left: Float
}
internal data class SignedNativeContainerMargins(override val top: Float, override val right: Float,
    override val bottom: Float, override val left: Float) : NativeContainerMargins {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && kotlin.math.abs(it) <= TablePixelLimit }) }
}
internal fun NativeContainerMargins.nonnegativeFloatMargins(): FloatMargins {
    if (listOf(top, right, bottom, left).any { it < 0f })
        throw UnsupportedFloatLayout("Signed external float margins are not supported")
    return FloatMargins(top, right, bottom, left)
}

internal data class NativeContainerHorizontal(val allocation: Float, val content: Float,
    val borderWidth: Float, val borderLeft: Float, val contentLeft: Float,
    val collisionLeft: Float, val collisionRight: Float) {
    init {
        require(listOf(allocation, content, borderWidth).all { it.isFinite() && it >= 0f })
        require(listOf(borderLeft, contentLeft, collisionLeft, collisionRight).all { it.isFinite() })
        require(contentLeft >= borderLeft && contentLeft + content <= borderLeft + borderWidth + .01f)
        require(collisionLeft <= borderLeft && collisionRight >= borderLeft + borderWidth)
        require(listOf(borderLeft, contentLeft, collisionLeft, collisionRight).all { kotlin.math.abs(it) <= TablePixelLimit })
    }

    companion object {
        fun from(width: ContainerBoxWidth, leftEdge: Float, authoredLeft: Float, authoredRight: Float): NativeContainerHorizontal {
            require(leftEdge.isFinite() && leftEdge >= 0f && authoredLeft.isFinite() && authoredRight.isFinite())
            return NativeContainerHorizontal(width.marginBox, width.content, width.borderBox,
                width.marginLeft, width.marginLeft + leftEdge,
                width.marginLeft - maxOf(0f, authoredLeft), width.marginLeft + width.borderBox + maxOf(0f, authoredRight))
        }
    }
}

/** CSS22 9.5 permits moving a BFC below preceding floats. This path keeps its solved
 * original-containing-width horizontal position and never shrinks/re-solves a negative
 * residual into a fictitious collision width. Content is already measured once. */
internal fun nativeContainerBfcTop(start: Float, height: Float, horizontal: NativeContainerHorizontal,
    exclusions: List<NativeFloatExclusion>): Float {
    require(start.isFinite() && kotlin.math.abs(start) <= TablePixelLimit && height.isFinite() && height >= 0f)
    var top = start
    while (true) {
        val bottom = top + height
        if (!bottom.isFinite() || bottom > TablePixelLimit)
            throw UnsupportedFloatLayout("Container BFC exceeds native geometry")
        val overlapping = if (height == 0f) emptyList() else exclusions.filter {
            it.outer.height > 0f && it.outer.width > 0f && it.outer.top < bottom && it.outer.bottom > top &&
                it.outer.left < horizontal.collisionRight && it.outer.right > horizontal.collisionLeft
        }
        if (overlapping.isEmpty()) return top
        val next = overlapping.minOf { it.outer.bottom }
        check(next > top)
        top = next
    }
}
