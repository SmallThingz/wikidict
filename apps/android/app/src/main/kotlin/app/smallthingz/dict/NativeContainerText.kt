package app.smallthingz.dict

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.BaselineShift
import kotlinx.coroutines.CancellationException
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

internal data class NativeContainerTextFormat(val style: TextStyle, val lineHeight: NativeLineHeightPolicy,
    val sourceFamily: ContainerFontFamily? = null, val ownerFont: NativeDeclaringFont? = null)

/** Adapt the real owner's computed context for the existing native paragraph preparation.
 * No descendant span supplies the strut, and no box length is rescaled here. */
internal fun nativeContainerTextFormat(context: ContainerTextContext, normalBodyFontSize: TextUnit,
    inheritedStyle: TextStyle, density: Density): NativeContainerTextFormat {
    require(normalBodyFontSize.isSp && normalBodyFontSize.value.isFinite() && normalBodyFontSize.value >= 0f)
    require(density.density.isFinite() && density.density > 0f && density.fontScale.isFinite() && density.fontScale > 0f)
    val bodyPixels = normalBodyFontSize.value.toDouble() * density.density * density.fontScale
    val ownerSp = normalBodyFontSize.value.toDouble() * context.ownerFontScale
    val ownerPixels = context.cellText?.fontPixels?.toDouble() ?: (bodyPixels * context.ownerFontScale)
    if (!ownerSp.isFinite() || ownerSp > Float.MAX_VALUE || !ownerPixels.isFinite() || ownerPixels > MaxComputedFontPixels)
        throw UnsupportedFloatLayout("Computed container owner font exceeds native geometry")
    val height = context.cellText?.lineHeight ?: when (val value = context.lineHeight) {
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
    val size = context.cellText?.fontPixels?.let { with(density) { it.toSp() } } ?: ownerSp.toFloat().sp
    val style = inheritedStyle.copy(fontSize = size,
        fontFamily = context.fontFamily?.let(::nativeTerminalFontFamily) ?: inheritedStyle.fontFamily)
    return NativeContainerTextFormat(if (context.cellText == null) style else nativeCellLineStyle(style, height, density),
        height, context.fontFamily)
}

/** The declaring probe is resolved once, independently of every descendant style. */
internal data class NativeDeclaringFont(val snapshot: InlineFontSnapshot,
    /** Null means no source line uses this font; it is not a resolved fallback face. */
    val style: TextStyle?)

internal const val NativeAbsoluteOwnerFontUnavailable = "Absolute declaring font is unavailable."

@Composable
internal fun nativeAbsoluteContainerTextFormat(absolute: ContainerPositioning.Absolute,
    inheritedStyle: TextStyle, density: Density,
    inheritedFamily: ContainerFontFamily? = null, hasLine: Boolean): Result<NativeContainerTextFormat> {
    val snapshot = absolute.ownerFont
    if (!hasLine) return Result.success(NativeContainerTextFormat(inheritedStyle,
        NativeLineHeightPolicy.Pixels(0f), snapshot.fontFamily ?: inheritedFamily,
        NativeDeclaringFont(snapshot, null)))
    val language = snapshot.language.takeIf { it.isNotEmpty() }?.let(::nativeTableOwnerLanguageTag)
    val normalBodySize = MaterialTheme.typography.bodyLarge.fontSize
    val cssPixelTextZoom = LocalCssPixelTextZoom.current
    val family = snapshot.fontFamily ?: inheritedFamily.takeIf {
        inlineFontSnapshotSpan(snapshot).legacyFontFamily() == null
    }
    // The snapshot owns these traits even when false/absent. UI heading/cell presets
    // cannot supply a declaring font, and a font probe cannot introduce paint effects.
    val seed = inheritedStyle.copy(fontWeight = if (snapshot.bold) FontWeight.Bold else FontWeight.Normal,
        fontStyle = if (snapshot.italic) FontStyle.Italic else FontStyle.Normal,
        baselineShift = BaselineShift.None, fontFeatureSettings = snapshot.fontFeatures?.nativeSettings,
        fontFamily = family?.let(::nativeTerminalFontFamily) ?: inheritedStyle.fontFamily,
        localeList = language?.let { LocaleList(Locale(it)) } ?: inheritedStyle.localeList)
    var resolved = seed.toSpanStyle()
    CompositionLocalProvider(LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null,
        LocalNativePreformattedText provides false,
        LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = inheritedFamily)) {
        resolved = inlineFontSnapshotAnnotation(snapshot, seed).spanStyles
            .fold(seed.toSpanStyle()) { value, range -> value.merge(range.item) }
    }
    return try {
        if (snapshot.fontScaleBasis == FontScaleBasis.Context || snapshot.language.isNotEmpty() && language == null)
            throw UnsupportedFloatLayout(NativeAbsoluteOwnerFontUnavailable)
        val value = absolute.lineHeight
        val height = cellTextMetricPixels(value.value, value.fontScaleBasis, normalBodySize, density, cssPixelTextZoom)
        if (!height.isFinite() || height < 0f || height > TablePixelLimit)
            throw UnsupportedFloatLayout("Absolute declaring line height exceeds native geometry.")
        val ownerStyle = seed.copy(fontSize = resolved.fontSize, fontWeight = resolved.fontWeight,
            fontStyle = resolved.fontStyle, fontFamily = resolved.fontFamily,
            fontSynthesis = resolved.fontSynthesis, fontFeatureSettings = resolved.fontFeatureSettings,
            localeList = resolved.localeList, baselineShift = resolved.baselineShift,
            letterSpacing = resolved.letterSpacing, textGeometricTransform = resolved.textGeometricTransform)
        if (!ownerStyle.fontSize.isSp)
            throw UnsupportedFloatLayout(NativeAbsoluteOwnerFontUnavailable)
        // The explicit text length follows the same existing typography conversion
        // as the font snapshot; physical top/left and zero used height belong to the box.
        val policy = NativeLineHeightPolicy.Pixels(height)
        Result.success(NativeContainerTextFormat(nativeCellLineStyle(ownerStyle, policy, density), policy,
            family, NativeDeclaringFont(snapshot, ownerStyle)))
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(if (error is UnsupportedFloatLayout) error else
            UnsupportedFloatLayout(NativeAbsoluteOwnerFontUnavailable))
    }
}
