package app.smallthingz.dict

import kotlin.math.ceil

/** One empty ordinary box: its exact height has no text strut or separator minimum. */
internal data class NativeRuleMetrics(val height: Float, val fill: Int?, val margins: FloatMargins) {
    init {
        listOf(height, margins.top, margins.right, margins.bottom, margins.left).forEach(::ruleCoordinate)
        ruleCoordinate(margins.left.toDouble() + margins.right)
    }

    val positive: Boolean get() = height > 0f
    val horizontalMargins: Float get() = margins.left + margins.right
    val allocatedHeight: Int get() = ceil(height.toDouble()).toInt()
    val adjoining: NativeAdjoiningMargins get() = NativeAdjoiningMargins(margins.top, margins.bottom, !positive)

    /** Only the fixed margins contribute to this empty auto-width box's intrinsic width. */
    fun intrinsic(): NativeWidthRange = ceil(margins.left.toDouble() + margins.right).toInt()
        .let { NativeWidthRange(it, it) }

    private fun usedWidth(availableWidth: Float): Double {
        ruleCoordinate(availableWidth)
        return maxOf(0.0, availableWidth.toDouble() - margins.left - margins.right)
    }

    fun contentWidth(availableWidth: Float): Float = usedWidth(availableWidth).toFloat()

    fun allocatedWidth(availableWidth: Float): Int = ceil(usedWidth(availableWidth)).toInt()
}

private fun ruleCoordinate(value: Double) {
    if (!value.isFinite() || value < 0.0 || value > TablePixelLimit)
        throw UnsupportedFloatLayout("Authored rule exceeds native geometry")
}
private fun ruleCoordinate(value: Float) = ruleCoordinate(value.toDouble())

/** Source em lengths already use the independent normal-body basis; never scale them by an owner font again. */
internal fun resolveAuthoredRuleMetrics(style: RuleStyle, density: Float,
    normalBodyPixels: Float, dark: Boolean): NativeRuleMetrics {
    require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    fun length(value: StyleLength): Float {
        val resolved = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyPixels
        ruleCoordinate(resolved)
        val pixels = resolved.toFloat()
        if (resolved > 0.0 && pixels == 0f)
            throw UnsupportedFloatLayout("Authored rule length is below native precision")
        ruleCoordinate(pixels)
        return pixels
    }
    val color = when (val fill = style.fill) {
        ContainerColor.Transparent -> null
        is ContainerColor.Rgb -> checkNotNull(canonicalColorArgb(fill.value)).toInt()
        is ContainerColor.LightDark -> checkNotNull(canonicalColorArgb(if (dark) fill.dark else fill.light)).toInt()
    }
    return NativeRuleMetrics(length(style.height), color, FloatMargins(length(style.margins.top),
        length(style.margins.right), length(style.margins.bottom), length(style.margins.left)))
}
