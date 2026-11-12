package app.smallthingz.dict

/** The compiled empty pseudo box participates in float exclusion, never in text or actions. */
internal data class FigureCaptionFloat(val side: TableFloatSide, val width: Float, val height: Float,
    val margins: FloatMargins) {
    val minimumWidth: Float get() = width + margins.left + margins.right
    fun place(containingWidth: Int): NativeFloatingTablePlacement = placeNativeFloatingTable(
        containingWidth.toFloat(), 0f, emptyList(), side, margins, NativeBlockWidth.FixedPx(width),
        pixelAligned = false) { NativeBlockMeasure(width, width, height) }
}

internal fun captionBeforeFloat(style: ContainerStyle, density: Float, normalBodyPixels: Float): FigureCaptionFloat {
    if (!validFigureCaptionBefore(style)) throw UnsupportedFloatLayout("Unsupported caption pseudo box")
    val viewport = style.atViewport(0.0)
    val box = viewport.box
    val side = box.floatSide ?: throw UnsupportedFloatLayout("Caption pseudo box is not a physical float")
    val width = (box.width as? ContainerWidth.Length)?.value
        ?: throw UnsupportedFloatLayout("Caption pseudo box needs a definite width")
    if (width.unit == StyleWidthUnit.Percent)
        throw UnsupportedFloatLayout("Caption pseudo box percentage width is unavailable")
    val height = box.height ?: throw UnsupportedFloatLayout("Caption pseudo box needs a definite height")
    fun length(value: StyleLength) = figureLengthPixels(value, density, normalBodyPixels)
    fun margin(value: ContainerMargin?): Float = when (value) {
        null -> 0f
        ContainerMargin.Auto -> throw UnsupportedFloatLayout("Caption pseudo box auto margin is unavailable")
        is ContainerMargin.Length -> {
            if (value.value.value < 0f) throw UnsupportedFloatLayout("Caption pseudo box negative margin is unavailable")
            length(StyleLength(value.value.unit, value.value.value))
        }
    }
    val edges = viewport.margins
    val margins = FloatMargins(margin(edges?.top), margin(edges?.right), margin(edges?.bottom), margin(edges?.left))
    val resolvedWidth = length(StyleLength(if (width.unit == StyleWidthUnit.Px) StyleLengthUnit.Px else StyleLengthUnit.Em, width.value))
    val resolvedHeight = length(height)
    if (resolvedWidth + margins.left + margins.right > TablePixelLimit ||
        resolvedHeight + margins.top + margins.bottom > TablePixelLimit)
        throw UnsupportedFloatLayout("Caption pseudo box exceeds native geometry")
    return FigureCaptionFloat(side, resolvedWidth, resolvedHeight, margins)
}
