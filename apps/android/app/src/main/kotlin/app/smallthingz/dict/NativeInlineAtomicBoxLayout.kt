package app.smallthingz.dict

/** Physical used boxes, measured from the outer margin-box origin. The declared
 * size and actual child overflow remain independent; no integer allocation enters fitting. */
internal data class NativeInlineAtomicBoxAllocation(
    val contentWidth: Float, val contentHeight: Float,
    val borderWidth: Float, val borderHeight: Float,
    val marginWidth: Float, val marginHeight: Float,
    val contentLeft: Float, val contentTop: Float,
    val borderLeft: Float, val borderTop: Float,
)

internal fun nativeInlineAtomicBoxAllocation(width: Float, height: Float,
    padding: NativeInlineBoxEdges, border: NativeInlineBoxEdges, margins: NativeInlineBoxEdges,
    boxSizing: ContainerBoxSizing): NativeInlineAtomicBoxAllocation {
    if (!width.isFinite() || !height.isFinite() || width <= 0f || height <= 0f)
        throw UnsupportedFloatLayout("Atomic inline box requires positive definite dimensions")
    fun used(value: Double) = nativeInlineBoxCoordinate(value)
    val horizontal = padding.left.toDouble() + padding.right + border.left + border.right
    val vertical = padding.top.toDouble() + padding.bottom + border.top + border.bottom
    val contentWidth = when (boxSizing) {
        ContainerBoxSizing.ContentBox -> width.toDouble()
        ContainerBoxSizing.BorderBox -> maxOf(0.0, width.toDouble() - horizontal)
    }
    val contentHeight = when (boxSizing) {
        ContainerBoxSizing.ContentBox -> height.toDouble()
        ContainerBoxSizing.BorderBox -> maxOf(0.0, height.toDouble() - vertical)
    }
    val borderWidth = contentWidth + horizontal
    val borderHeight = contentHeight + vertical
    return NativeInlineAtomicBoxAllocation(used(contentWidth), used(contentHeight),
        used(borderWidth), used(borderHeight),
        used(margins.left.toDouble() + borderWidth + margins.right),
        used(margins.top.toDouble() + borderHeight + margins.bottom),
        used(margins.left.toDouble() + border.left + padding.left),
        used(margins.top.toDouble() + border.top + padding.top), margins.left, margins.top)
}

internal data class NativeInlineAtomicBoxBaseline(
    val baselineFromMarginTop: Float, val metrics: NativeUsedLineMetrics,
)

/** Visible-overflow inline blocks use the last real in-flow child's baseline,
 * including when it lies below the declared height. No synthetic empty line is made. */
internal fun nativeInlineAtomicBoxBaseline(allocation: NativeInlineAtomicBoxAllocation,
    lastContentBaseline: Float): NativeInlineAtomicBoxBaseline {
    if (!lastContentBaseline.isFinite())
        throw UnsupportedFloatLayout("Atomic inline box has no finite child baseline")
    val baseline = nativeInlineBoxCoordinate(allocation.contentTop.toDouble() + lastContentBaseline)
    return NativeInlineAtomicBoxBaseline(baseline, NativeUsedLineMetrics(-baseline,
        nativeInlineBoxCoordinate(allocation.marginHeight.toDouble() - baseline)))
}
