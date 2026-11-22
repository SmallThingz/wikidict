package app.smallthingz.dict

/** The producer has already normalized em to the original body basis. A wrapper's
 * effective font must never multiply these lengths a second time. */
internal fun nativeImageOccurrencePlacement(source: InlineImageOccurrenceLayout?,
    normalBodyPixels: Float, imagePixelDensity: Float): NativeImageOccurrencePlacement? {
    if (source == null) return null
    if (!normalBodyPixels.isFinite() || normalBodyPixels < 0f ||
        !imagePixelDensity.isFinite() || imagePixelDensity <= 0f)
        throw UnsupportedFloatLayout("Positioned image has an unavailable length basis")
    fun pixels(length: ContainerMarginLength): Float {
        val basis = when (length.unit) {
            StyleLengthUnit.Px -> imagePixelDensity
            StyleLengthUnit.Em -> normalBodyPixels
        }
        val value = length.value.toDouble() * basis.toDouble()
        if (!value.isFinite() || kotlin.math.abs(value) > TablePixelLimit)
            throw UnsupportedFloatLayout("Positioned image exceeds native coordinates")
        return value.toFloat()
    }
    return NativeImageOccurrencePlacement(pixels(source.x), pixels(source.y),
        pixels(source.paddingLeft), pixels(source.paddingRight))
}

/** Filter a refused occurrence before resource deduplication, so a later ordinary
 * occurrence of that same asset keeps its existing request. */
internal fun nativeInlineImageRequests(images: List<InlineImage>, terminalOccurrenceFallback: Boolean): List<InlineImage> =
    images.filterNot { terminalOccurrenceFallback && it.occurrenceLayout != null }.distinctBy(::inlineImageAssetKey)
