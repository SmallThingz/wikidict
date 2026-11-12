package app.smallthingz.dict

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** Resolved inheritance on the existing content owner; this is not serialized or a new layout. */
internal data class NativeCellTextState(val fontPixels: Float?, val lineHeight: NativeLineHeightPolicy?) {
    init { require(fontPixels == null || fontPixels.isFinite() && fontPixels >= 0f) }
}

internal fun cellTextMetricPixels(value: Float, basis: FontScaleBasis, normalBodySize: TextUnit,
    density: Density, cssPixelTextZoom: Float, fontSize: Boolean = false): Float {
    require(value.isFinite() && value >= 0f && basis != FontScaleBasis.Context)
    require(normalBodySize.isSp && normalBodySize.value.isFinite() && normalBodySize.value >= 0f)
    require(cssPixelTextZoom.isFinite() && cssPixelTextZoom > 0f)
    val pixels = when (basis) {
        FontScaleBasis.NormalBody -> with(density) { normalBodySize.toPx() }.toDouble() * value
        FontScaleBasis.CssPx -> {
            val nominal = value.toDouble() * cssPixelTextZoom
            if (!nominal.isFinite() || nominal > Float.MAX_VALUE && !fontSize)
                throw UnsupportedFloatLayout("Cell text metric exceeds the native range")
            with(density) { nominal.coerceAtMost(Float.MAX_VALUE.toDouble()).toFloat().sp.toPx() }.toDouble()
        }
        FontScaleBasis.Context -> error("Cell metrics require an explicit origin")
    }
    if (fontSize && !pixels.isNaN() && pixels >= 0.0)
        return pixels.coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
    if (!pixels.isFinite() || pixels < 0.0 || pixels > Float.MAX_VALUE)
        throw UnsupportedFloatLayout("Cell text metric exceeds the native range")
    return pixels.toFloat()
}

internal fun nativeCellLineStyle(style: TextStyle, height: NativeLineHeightPolicy, density: Density): TextStyle =
    style.copy(lineHeight = when (height) {
        NativeLineHeightPolicy.Normal -> TextUnit.Unspecified
        is NativeLineHeightPolicy.Multiplier -> height.value.em
        is NativeLineHeightPolicy.Pixels -> with(density) { height.value.toSp() }
    })

/** Resolve a cell before its descendants. Both ordinary grids and caption grids use this path. */
internal fun nativeCellTextContext(cell: Cell, inherited: ContainerTextContext?, inheritedStyle: TextStyle,
    normalBodySize: TextUnit, density: Density, cssPixelTextZoom: Float,
    tableLineHeightPixels: Float?): ContainerTextContext? {
    val own = cell.style?.lineHeight
    if (own == null && inherited?.cellText == null) return inherited
    require(inheritedStyle.fontSize.isSp)
    val previous = inherited?.let { nativeContainerTextFormat(it, normalBodySize, inheritedStyle, density) }
    val fontPixels = own?.strut?.let {
        cellTextMetricPixels(it.fontScale, it.fontScaleBasis, normalBodySize, density, cssPixelTextZoom, fontSize = true)
    } ?: with(density) { inheritedStyle.fontSize.toPx() }
    val height = when (val value = own?.height) {
        CellLineHeightValue.Normal -> NativeLineHeightPolicy.Normal
        is CellLineHeightValue.Multiplier -> NativeLineHeightPolicy.Multiplier(value.value)
        is CellLineHeightValue.Length -> NativeLineHeightPolicy.Pixels(cellTextMetricPixels(value.value.value,
            value.value.fontScaleBasis, normalBodySize, density, cssPixelTextZoom))
        null -> tableLineHeightPixels?.let { NativeLineHeightPolicy.Pixels(it) } ?: previous?.lineHeight
            ?: when {
                inheritedStyle.lineHeight.isSp -> NativeLineHeightPolicy.Pixels(with(density) { inheritedStyle.lineHeight.toPx() })
                inheritedStyle.lineHeight.isEm -> NativeLineHeightPolicy.Multiplier(inheritedStyle.lineHeight.value)
                else -> NativeLineHeightPolicy.Normal
            }
    }
    if (height is NativeLineHeightPolicy.Pixels && height.value > TablePixelLimit)
        throw UnsupportedFloatLayout("Cell line height exceeds the native range")
    return (inherited ?: ContainerTextContext()).copy(cellText = NativeCellTextState(fontPixels, height))
}
