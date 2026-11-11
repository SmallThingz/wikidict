package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

internal data class NativeContainerTextFormat(val style: TextStyle, val lineHeight: NativeLineHeightPolicy)

/** Adapt the real owner's computed context for the existing native paragraph preparation.
 * No descendant span supplies the strut, and no box length is rescaled here. */
internal fun nativeContainerTextFormat(context: ContainerTextContext, normalBodyFontSize: TextUnit,
    inheritedStyle: TextStyle, density: Density): NativeContainerTextFormat {
    require(normalBodyFontSize.isSp && normalBodyFontSize.value.isFinite() && normalBodyFontSize.value >= 0f)
    require(density.density.isFinite() && density.density > 0f && density.fontScale.isFinite() && density.fontScale > 0f)
    val bodyPixels = normalBodyFontSize.value.toDouble() * density.density * density.fontScale
    val ownerSp = normalBodyFontSize.value.toDouble() * context.ownerFontScale
    val ownerPixels = bodyPixels * context.ownerFontScale
    if (!ownerSp.isFinite() || ownerSp > Float.MAX_VALUE || !ownerPixels.isFinite() || ownerPixels > MaxComputedFontPixels)
        throw UnsupportedFloatLayout("Computed container owner font exceeds native geometry")
    val height = when (val value = context.lineHeight) {
        ContainerLineHeight.Normal -> NativeLineHeightPolicy.Normal
        is ContainerLineHeight.Multiplier -> NativeLineHeightPolicy.Multiplier(value.value)
        is ContainerLineHeight.Length -> {
            val pixels = value.value.value.toDouble() * when (value.value.unit) {
                StyleLengthUnit.Px -> density.density.toDouble()
                StyleLengthUnit.Em -> bodyPixels
            }
            if (!pixels.isFinite() || pixels > Float.MAX_VALUE)
                throw UnsupportedFloatLayout("Computed container line height exceeds native geometry")
            NativeLineHeightPolicy.Pixels(pixels.toFloat())
        }
    }
    return NativeContainerTextFormat(inheritedStyle.copy(fontSize = ownerSp.toFloat().sp), height)
}
