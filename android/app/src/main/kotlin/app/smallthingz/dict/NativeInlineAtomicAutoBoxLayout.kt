package app.smallthingz.dict

/** Content intrinsic widths after the authored maximum, before outer margins. */
internal data class NativeInlineAtomicAutoWidths(val minimum: Float, val maximum: Float)

internal fun nativeInlineAtomicAutoWidths(minimum: Float, maximum: Float, maxWidth: Float,
    padding: NativeInlineBoxEdges, border: NativeInlineBoxEdges,
    boxSizing: ContainerBoxSizing): NativeInlineAtomicAutoWidths {
    if (!minimum.isFinite() || !maximum.isFinite() || minimum < 0f || maximum < minimum ||
        !maxWidth.isFinite() || maxWidth <= 0f)
        throw UnsupportedFloatLayout("Auto inline box intrinsic width is unavailable")
    val edges = padding.left.toDouble() + padding.right + border.left + border.right
    val cap = when (boxSizing) {
        ContainerBoxSizing.ContentBox -> maxWidth.toDouble()
        ContainerBoxSizing.BorderBox -> maxOf(0.0, maxWidth.toDouble() - edges)
    }
    return NativeInlineAtomicAutoWidths(nativeInlineBoxCoordinate(minOf(minimum.toDouble(), cap)),
        nativeInlineBoxCoordinate(minOf(maximum.toDouble(), cap)))
}

/** Full containing content width, never the space remaining after prior inline text
 * or a reduced float lane. The outer fitter may move the completed atom intact. */
internal fun nativeInlineAtomicAutoContentWidth(widths: NativeInlineAtomicAutoWidths,
    containingWidth: Float, padding: NativeInlineBoxEdges, border: NativeInlineBoxEdges,
    margins: NativeInlineBoxEdges): Float {
    if (!containingWidth.isFinite() || containingWidth < 0f)
        throw UnsupportedFloatLayout("Auto inline box has no finite containing width")
    val available = maxOf(0.0, containingWidth.toDouble() - margins.left - margins.right -
        padding.left - padding.right - border.left - border.right)
    return nativeInlineBoxCoordinate(minOf(maxOf(widths.minimum.toDouble(), available), widths.maximum.toDouble()))
}

/** Auto height is the actual inner line-box extent. Zero used height/width is kept;
 * overflow ink and the last real baseline remain independent of these dimensions. */
internal fun nativeInlineAtomicAutoAllocation(contentWidth: Float, contentHeight: Float,
    padding: NativeInlineBoxEdges, border: NativeInlineBoxEdges,
    margins: NativeInlineBoxEdges): NativeInlineAtomicBoxAllocation {
    if (!contentWidth.isFinite() || !contentHeight.isFinite() || contentWidth < 0f || contentHeight < 0f)
        throw UnsupportedFloatLayout("Auto inline box has invalid used content dimensions")
    fun used(value: Double) = nativeInlineBoxCoordinate(value)
    val borderWidth = contentWidth.toDouble() + padding.left + padding.right + border.left + border.right
    val borderHeight = contentHeight.toDouble() + padding.top + padding.bottom + border.top + border.bottom
    return NativeInlineAtomicBoxAllocation(contentWidth, contentHeight, used(borderWidth), used(borderHeight),
        used(margins.left.toDouble() + borderWidth + margins.right),
        used(margins.top.toDouble() + borderHeight + margins.bottom),
        used(margins.left.toDouble() + border.left + padding.left),
        used(margins.top.toDouble() + border.top + padding.top), margins.left, margins.top)
}
