package app.smallthingz.dict

/** The two authored inner lines share the complete resolved declaring font. These
 * physical lengths retain their signs; no size or baseline is stored in the model. */
internal data class NativeInlineIntrinsicLinesFormat(
    val marginBottom: Float,
    val verticalAlign: Float,
    val textAlign: InlineBoxOverlayTextAlign,
    val lineHeight: NativeLineHeightPolicy,
) {
    init { nativeInlineBoxCoordinates(marginBottom, verticalAlign) }
}

internal fun nativeInlineIntrinsicSignedLength(value: InlineBoxSignedLength,
    declaringFontPixels: Float, density: Float): Float {
    if (!declaringFontPixels.isFinite() || declaringFontPixels <= 0f || !density.isFinite() || density <= 0f)
        throw UnsupportedFloatLayout("Intrinsic line owner has no positive resolved font basis")
    return nativeInlineBoxCoordinate(value.value.toDouble() *
        if (value.unit == StyleLengthUnit.Px) density else declaringFontPixels)
}

/** Bottom margin changes only the outer baseline envelope. Its signed extent may
 * be zero; an inverted native envelope is unavailable rather than silently clamped. */
internal fun nativeInlineIntrinsicLinesAllocation(width: Float, contentHeight: Float,
    marginBottom: Float): NativeInlineAtomicBoxAllocation {
    nativeInlineBoxCoordinates(width, contentHeight, marginBottom)
    if (width < 0f || contentHeight <= 0f)
        throw UnsupportedFloatLayout("Intrinsic lines require nonnegative measured width and positive content height")
    val outerHeight = nativeInlineBoxCoordinate(contentHeight.toDouble() + marginBottom)
    if (outerHeight < 0f)
        throw UnsupportedFloatLayout("Intrinsic line bottom margin reverses the native baseline envelope")
    return NativeInlineAtomicBoxAllocation(width, contentHeight, width, contentHeight,
        width, outerHeight, 0f, 0f, 0f, 0f)
}

/** Positive CSS vertical-align raises the whole owner. Content dimensions and
 * the actual last inner baseline remain independent of the signed displacement. */
internal fun nativeInlineIntrinsicLinesBaseline(allocation: NativeInlineAtomicBoxAllocation,
    baselineFromMarginTop: Float, verticalAlign: Float): NativeInlineAtomicBoxBaseline {
    nativeInlineBoxCoordinates(baselineFromMarginTop, verticalAlign)
    val aligned = nativeInlineBoxCoordinate(baselineFromMarginTop.toDouble() + verticalAlign)
    return NativeInlineAtomicBoxBaseline(aligned, NativeUsedLineMetrics(-aligned,
        nativeInlineBoxCoordinate(allocation.marginHeight.toDouble() - aligned)))
}
