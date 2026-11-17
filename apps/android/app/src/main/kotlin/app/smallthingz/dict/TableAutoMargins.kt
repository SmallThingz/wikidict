package app.smallthingz.dict

import kotlin.math.abs

/** Only an admitted root table's actual automatic-margin owner replaces its legacy gap.
 * Other roots retain their original gaps and the adjoining layout's refusal checks. */
internal fun nativeTableBodyAdjoiningSpec(block: Block, policy: BodyAdjoiningPolicy?, bodyRoot: Boolean,
    child: NativeFloatContextSpec.Child): NativeFloatContextSpec.Child {
    if (policy != BodyAdjoiningPolicy.Ordinary || !bodyRoot || block.kind != "table" ||
        block.depth != 0 || block.listPath.isNotEmpty() || block.number.isNotEmpty() ||
        block.spans.isNotEmpty() || block.feature != null || block.table == null ||
        child.autoMarginTable !== block.table || child.autoMargins == null ||
        child.atomicInline || child.floatSide != null || child.gapBefore != 0f) return child
    return child.copy(gapAfter = 0f)
}

/** The table producer normalizes em to the independent normal-body font once. */
internal data class NativeTableAutoMargins(
    val fixed: FloatMargins,
    val leftAuto: Boolean,
    val rightAuto: Boolean,
) {
    init {
        require(!leftAuto || fixed.left == 0f)
        require(!rightAuto || fixed.right == 0f)
    }
}

internal fun resolveTableAutoMargins(values: ContainerMargins, density: Float,
    normalBodyPixels: Float): NativeTableAutoMargins {
    validateTableAutoMargins(values)
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    fun pixels(value: ContainerMargin): Float = when (value) {
        ContainerMargin.Auto -> 0f
        is ContainerMargin.Length -> {
            val scale = if (value.value.unit == StyleLengthUnit.Px) density else normalBodyPixels
            val pixels = value.value.value.toDouble() * scale
            if (!pixels.isFinite() || pixels > TablePixelLimit)
                throw UnsupportedFloatLayout("Table margins exceed native geometry")
            pixels.toFloat()
        }
    }
    val edges = FloatMargins(pixels(values.top), pixels(values.right), pixels(values.bottom), pixels(values.left))
    if (listOf(edges.top, edges.right, edges.bottom, edges.left).any { it > TablePixelLimit })
        throw UnsupportedFloatLayout("Table margins exceed native geometry")
    return NativeTableAutoMargins(edges, values.left == ContainerMargin.Auto, values.right == ContainerMargin.Auto)
}

/** Fixed responsive-table margins use the same proved body-em basis without pixel rounding. */
internal fun resolveTableFixedMargins(values: StyleEdges, density: Float, normalBodyPixels: Float): FloatMargins {
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    fun pixels(value: StyleLength): Float {
        val scale = if (value.unit == StyleLengthUnit.Px) density else normalBodyPixels
        val pixels = value.value.toDouble() * scale
        if (!pixels.isFinite() || pixels !in 0.0..TablePixelLimit.toDouble())
            throw UnsupportedFloatLayout("Table margins exceed native geometry")
        return pixels.toFloat()
    }
    return FloatMargins(pixels(values.top), pixels(values.right), pixels(values.bottom), pixels(values.left))
}

internal enum class NativeTableMarginFlow { Block, Floating, Inline }

/** Used horizontal margins may be signed even though authored table lengths cannot be. */
internal data class NativeTableUsedMargins(val top: Float, val right: Float, val bottom: Float, val left: Float) {
    init {
        require(listOf(top, right, bottom, left).all { it.isFinite() && abs(it) <= TablePixelLimit })
        require(top >= 0f && bottom >= 0f)
    }
}

/** finalBorderWidth includes the actual caption floor; it is never a clipped viewport width.
 * Containing direction is independent of table track order and text direction. */
internal fun solveTableAutoMargins(availableWidth: Float, finalBorderWidth: Float,
    margins: NativeTableAutoMargins, flow: NativeTableMarginFlow,
    containingDirection: TableContainingDirection): NativeTableUsedMargins {
    require(availableWidth.isFinite() && availableWidth in 0f..TablePixelLimit.toFloat())
    require(finalBorderWidth.isFinite() && finalBorderWidth in 0f..TablePixelLimit.toFloat())
    val fixed = margins.fixed
    var left = fixed.left.toDouble()
    var right = fixed.right.toDouble()
    if (flow == NativeTableMarginFlow.Block) {
        val remaining = availableWidth.toDouble() - finalBorderWidth - left - right
        if (remaining >= 0.0 && (margins.leftAuto || margins.rightAuto)) {
            when {
                margins.leftAuto && margins.rightAuto -> { left = remaining / 2.0; right = remaining / 2.0 }
                margins.leftAuto -> left = remaining
                else -> right = remaining
            }
        } else if (containingDirection == TableContainingDirection.Rtl) left += remaining
        else right += remaining
    }
    if (!left.isFinite() || !right.isFinite() || abs(left) > TablePixelLimit || abs(right) > TablePixelLimit)
        throw UnsupportedFloatLayout("Used table margins exceed native geometry")
    return NativeTableUsedMargins(fixed.top, right.toFloat(), fixed.bottom, left.toFloat())
}

internal data class NativeAutoMarginTablePlacement(
    val content: NativeFloatBounds,
    val margins: NativeTableUsedMargins,
    val availableLeft: Float,
    val availableRight: Float,
    val nextY: Float,
    val documentLeft: Float,
    val documentRight: Float,
    val measurementCount: Int,
)

/** Existing exclusion placement chooses the interval and measures the real table first.
 * The callback must report the final grid/caption border box, before any scroll clipping.
 * This owns the only table origin used by paint, hit geometry and document extents.
 * Fractional fixed and auto margins remain in the shared physical geometry; the native
 * painter must preserve the returned fractional origin. */
internal fun placeNativeAutoMarginTable(containingWidth: Float, normalY: Float,
    exclusions: List<NativeFloatExclusion>, margins: NativeTableAutoMargins,
    containingDirection: TableContainingDirection, widthRule: NativeBlockWidth = NativeBlockWidth.Auto,
    clear: FigureClear? = null,
    measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure): NativeAutoMarginTablePlacement {
    val fixed = margins.fixed
    val horizontal = fixed.left + fixed.right
    val requested = when (widthRule) {
        NativeBlockWidth.Auto -> null
        is NativeBlockWidth.FixedPx -> widthRule.value
        is NativeBlockWidth.Percent -> (containingWidth.toDouble() * widthRule.value / 100.0).toFloat()
    }
    if (!horizontal.isFinite() || !(normalY + fixed.top).isFinite() || requested?.isFinite() == false)
        throw UnsupportedFloatLayout("Table margin placement exceeds native geometry")
    val start = tableClearanceY(normalY + fixed.top, clear, exclusions)
    val outerRule = requested?.let { NativeBlockWidth.FixedPx(it + horizontal) } ?: NativeBlockWidth.Auto
    var body: NativeBlockMeasure? = null
    val placed = placeNativeFloatBlock(containingWidth, start, exclusions, outerRule,
        pixelAligned = false) { request ->
        val actual = measure(NativeBlockMeasureRequest(containingWidth,
            (request.availableWidth - horizontal).coerceAtLeast(0f), requested))
        body = actual
        NativeBlockMeasure(actual.usedWidth + horizontal, actual.minWidth + horizontal,
            actual.height + fixed.bottom)
    }
    val actual = checkNotNull(body)
    val used = solveTableAutoMargins(placed.availableRight - placed.availableLeft,
        actual.usedWidth, margins, NativeTableMarginFlow.Block, containingDirection)
    val left = placed.availableLeft + used.left
    val content = NativeFloatBounds(left, placed.bounds.top, left + actual.usedWidth,
        placed.bounds.top + actual.height)
    val nextY = placed.bounds.bottom
    if (listOf(content.left, content.top, content.right, content.bottom, nextY).any {
            !it.isFinite() || abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Placed table exceeds native geometry")
    return NativeAutoMarginTablePlacement(content, used, placed.availableLeft, placed.availableRight,
        nextY, minOf(0f, content.left), maxOf(containingWidth, content.right), placed.measurementCount)
}
