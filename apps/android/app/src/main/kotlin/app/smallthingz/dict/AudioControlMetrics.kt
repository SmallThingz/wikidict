package app.smallthingz.dict

/** Authored em values are already normalized to the original body-font basis. */
internal fun audioControlWidthPixels(control: AudioControl, containingWidth: Float, density: Float,
    normalBodyPixels: Float): Float? {
    val width = control.width ?: return null
    audioControlBasis(density, normalBodyPixels)
    val pixels = when (width.unit) {
        StyleWidthUnit.Px -> width.value.toDouble() * density
        StyleWidthUnit.Em -> width.value.toDouble() * normalBodyPixels
        StyleWidthUnit.Percent -> {
            if (!containingWidth.isFinite() || containingWidth !in 0f..TablePixelLimit.toFloat())
                throw UnsupportedFloatLayout("Audio percentage width requires its actual containing width")
            width.value.toDouble() * containingWidth / 100.0
        }
    }
    return audioControlPixels(pixels)
}

internal fun audioControlHeightPixels(control: AudioControl, density: Float, normalBodyPixels: Float): Float? {
    val height = control.height ?: return null
    audioControlBasis(density, normalBodyPixels)
    return audioControlPixels(height.value.toDouble() * when (height.unit) {
        StyleLengthUnit.Px -> density
        StyleLengthUnit.Em -> normalBodyPixels
    })
}

private fun audioControlBasis(density: Float, normalBodyPixels: Float) {
    if (!density.isFinite() || density <= 0f || !normalBodyPixels.isFinite() || normalBodyPixels < 0f)
        throw UnsupportedFloatLayout("Audio controls have an invalid geometry basis")
}

private fun audioControlPixels(pixels: Double): Float {
    if (!pixels.isFinite() || pixels !in 0.0..TablePixelLimit.toDouble())
        throw UnsupportedFloatLayout("Audio control dimensions exceed native geometry")
    return pixels.toFloat()
}
