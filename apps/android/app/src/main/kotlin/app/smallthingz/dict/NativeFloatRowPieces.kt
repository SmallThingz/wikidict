package app.smallthingz.dict

/** Already-resolved occurrence pixels. Translation never contributes to advance or used metrics. */
internal data class NativeFloatRowImage(
    val outerWidth: Float,
    val outerHeight: Float,
    val baselineTop: Float,
    val paddingLeft: Float = 0f,
    val paddingRight: Float = 0f,
    val translationX: Float = 0f,
    val translationY: Float = 0f,
    val positioned: Boolean = false,
) {
    init {
        listOf(outerWidth, outerHeight, paddingLeft, paddingRight).forEach {
            require(it.isFinite() && it >= 0f)
        }
        listOf(baselineTop, translationX, translationY).forEach { require(it.isFinite()) }
        require(positioned || paddingLeft == 0f && paddingRight == 0f && translationX == 0f && translationY == 0f)
    }
    val advance: Float = nativeFloatRowCoordinate(paddingLeft.toDouble() + outerWidth + paddingRight)
}

/** Native measurement and line bidi select these ranges and their visual order before placement. */
internal sealed interface NativeFloatRowPiece {
    val start: Int
    val end: Int
    val rtl: Boolean
    val advance: Float

    data class Text(override val start: Int, override val end: Int, override val rtl: Boolean,
        override val advance: Float) : NativeFloatRowPiece {
        init {
            require(start >= 0 && end > start)
            require(advance.isFinite() && advance >= 0f)
        }
    }

    data class Image(override val start: Int, override val rtl: Boolean,
        val image: NativeFloatRowImage) : NativeFloatRowPiece {
        init { require(start >= 0 && start < Int.MAX_VALUE) }
        override val end: Int get() = start + 1
        override val advance: Float get() = image.advance
    }
}

internal data class NativeFloatRowPiecePlacement(
    val piece: NativeFloatRowPiece,
    val left: Float,
    val right: Float,
    /** The translated image outer box, excluding wrapper padding. Not a glyph/ink estimate. */
    val imageBounds: NativeFloatBounds?,
) {
    val sourceStartX: Float get() = if (piece.rtl) right else left
    val sourceEndX: Float get() = if (piece.rtl) left else right
    /** Handoff only: the existing positioned-group scheduler owns paint and hit order. */
    val positionedSourceOffset: Int? get() = (piece as? NativeFloatRowPiece.Image)
        ?.takeIf { it.image.positioned }?.start
}

/** Shared offsets retain both owner affinities; choosing one is the native query caller's job. */
internal data class NativeFloatRowSourceEdge(
    val piece: NativeFloatRowPiece,
    val offset: Int,
    val atStart: Boolean,
    val flowX: Float,
    /** Image-owned geometry may move while an adjacent text owner's flow edge stays fixed. */
    val imageX: Float?,
)

internal class NativeFloatRowPieces internal constructor(
    val start: Int,
    val end: Int,
    val originX: Float,
    val baseline: Float,
    val advance: Float,
    placements: List<NativeFloatRowPiecePlacement>,
) {
    val placements = placements.toList()

    fun sourceEdges(offset: Int): List<NativeFloatRowSourceEdge> {
        require(offset in start..end)
        return buildList {
            placements.forEach { placed ->
                val piece = placed.piece
                if (offset == piece.start) add(NativeFloatRowSourceEdge(piece, offset, true,
                    placed.sourceStartX, placed.imageBounds?.let { if (piece.rtl) it.right else it.left }))
                if (offset == piece.end) add(NativeFloatRowSourceEdge(piece, offset, false,
                    placed.sourceEndX, placed.imageBounds?.let { if (piece.rtl) it.left else it.right }))
            }
        }
    }
}

internal enum class NativeFloatRowPhysicalAlignment { Left, Right, Center }

/** The caller supplies the native visible advance and resolves logical alignment to physical. */
internal fun nativeFloatRowOrigin(left: Float, right: Float, visibleAdvance: Float,
    alignment: NativeFloatRowPhysicalAlignment): Float {
    require(left.isFinite() && right.isFinite() && right >= left &&
        visibleAdvance.isFinite() && visibleAdvance >= 0f)
    return nativeFloatRowCoordinate(when (alignment) {
        NativeFloatRowPhysicalAlignment.Left -> left.toDouble()
        NativeFloatRowPhysicalAlignment.Right -> right.toDouble() - visibleAdvance
        NativeFloatRowPhysicalAlignment.Center -> (left.toDouble() + right - visibleAdvance) / 2.0
    })
}

/**
 * Places one already-selected native row. This helper never fits a line, resolves bidi,
 * shapes glyphs, trims source or computes metrics. Float advances stay Float; Double prefix
 * accumulation avoids introducing a per-piece integer reserve or visual-order rounding bias.
 */
internal fun nativeFloatRowPieces(source: CharSequence, start: Int, end: Int,
    visualPieces: List<NativeFloatRowPiece>, originX: Float, baseline: Float): NativeFloatRowPieces {
    require(start in 0..source.length && end in start..source.length)
    nativeFloatRowCoordinate(originX.toDouble()); nativeFloatRowCoordinate(baseline.toDouble())
    fun validBoundary(offset: Int): Boolean = offset == 0 || offset == source.length ||
        !(Character.isHighSurrogate(source[offset - 1]) && Character.isLowSurrogate(source[offset]))
    require(validBoundary(start) && validBoundary(end))
    var covered = start
    visualPieces.sortedBy { it.start }.forEach { piece ->
        require(piece.start == covered && piece.end <= end && validBoundary(piece.start) && validBoundary(piece.end))
        if (piece is NativeFloatRowPiece.Image) require(source[piece.start] == '\ufffc')
        covered = piece.end
    }
    require(covered == end)
    var prefix = 0.0
    val placed = visualPieces.map { piece ->
        val leftExact = originX.toDouble() + prefix
        val left = nativeFloatRowCoordinate(leftExact)
        prefix += piece.advance.toDouble()
        val right = nativeFloatRowCoordinate(originX.toDouble() + prefix)
        val bounds = (piece as? NativeFloatRowPiece.Image)?.image?.let { image ->
            val x = leftExact + image.paddingLeft + image.translationX
            val y = baseline.toDouble() + image.baselineTop + image.translationY
            NativeFloatBounds(nativeFloatRowCoordinate(x), nativeFloatRowCoordinate(y),
                nativeFloatRowCoordinate(x + image.outerWidth), nativeFloatRowCoordinate(y + image.outerHeight))
        }
        NativeFloatRowPiecePlacement(piece, left, right, bounds)
    }
    return NativeFloatRowPieces(start, end, originX, baseline, nativeFloatRowCoordinate(prefix), placed)
}

private fun nativeFloatRowCoordinate(value: Double): Float {
    require(value.isFinite() && kotlin.math.abs(value) <= TablePixelLimit.toDouble())
    return value.toFloat()
}
