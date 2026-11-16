package app.smallthingz.dict

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
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
    context.containerText?.let { state ->
        val owner = state.resolved ?: throw UnsupportedFloatLayout(NativeContainerOwnerFontUnavailable)
        val style = inheritedStyle.copy(fontSize = checkNotNull(owner.style).fontSize,
            fontFamily = context.fontFamily?.let(::nativeTerminalFontFamily) ?: inheritedStyle.fontFamily)
        val height = context.resolvedLineHeight ?: state.lineHeight
            ?: nativeContainerLineHeight(context.lineHeight, normalBodyFontSize, density)
        return NativeContainerTextFormat(nativeCellLineStyle(style, height, density), height, context.fontFamily, owner)
    }
    val bodyPixels = normalBodyFontSize.value.toDouble() * density.density * density.fontScale
    val ownerSp = normalBodyFontSize.value.toDouble() * context.ownerFontScale
    val ownerPixels = context.cellText?.fontPixels?.toDouble() ?: (bodyPixels * context.ownerFontScale)
    if (!ownerSp.isFinite() || ownerSp > Float.MAX_VALUE || !ownerPixels.isFinite() || ownerPixels > MaxComputedFontPixels)
        throw UnsupportedFloatLayout("Computed container owner font exceeds native geometry")
    val height = context.resolvedLineHeight ?: context.cellText?.lineHeight ?: when (val value = context.lineHeight) {
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
    val style: TextStyle?, val kind: NativeDeclaringFontKind = NativeDeclaringFontKind.Absolute,
    val fontPixels: Float? = null)

internal enum class NativeDeclaringFontKind { Absolute, Container }

/** A rendering-context copy may update W's legacy size/family aliases. The stored source
 * snapshot is never changed; resolved metrics survive only an unchanged declaring font. */
internal data class NativeContainerTextState(val snapshot: InlineFontSnapshot,
    val resolved: NativeDeclaringFont? = null, val lineHeight: NativeLineHeightPolicy? = null)

internal const val NativeContainerOwnerFontUnavailable = "Container declaring font is unavailable."

private fun nativeContainerLineHeight(value: ContainerLineHeight, normalBodySize: TextUnit,
    density: Density): NativeLineHeightPolicy = when (value) {
    ContainerLineHeight.Normal -> NativeLineHeightPolicy.Normal
    is ContainerLineHeight.Multiplier -> NativeLineHeightPolicy.Multiplier(value.value)
    is ContainerLineHeight.Length -> {
        // Existing Container lengths keep their geometry/body units, independently of
        // the W font's text conversion (including CSS-pixel text zoom).
        val pixels = value.value.value.toDouble() * when (value.value.unit) {
            StyleLengthUnit.Px -> density.density.toDouble()
            StyleLengthUnit.Em -> normalBodySize.value.toDouble() * density.density * density.fontScale
        }
        if (!pixels.isFinite() || pixels > Float.MAX_VALUE)
            throw UnsupportedFloatLayout("Computed container line height exceeds native geometry")
        NativeLineHeightPolicy.Pixels(pixels.toFloat())
    }
}

/** Resolve only the independent W metric font. Child style inherits size/family through
 * the pure formatter; its booleans, features and language do not come from this probe. */
@Composable
internal fun nativeContainerOwnerTextContext(context: ContainerTextContext,
    inheritedStyle: TextStyle, density: Density): Result<ContainerTextContext> {
    val state = context.containerText ?: return Result.success(context)
    if (state.resolved != null) return Result.success(context)
    val snapshot = state.snapshot
    val language = snapshot.language.takeIf { it.isNotEmpty() }?.let(::nativeTableOwnerLanguageTag)
    val family = snapshot.fontFamily ?: context.fontFamily.takeIf {
        inlineFontSnapshotSpan(snapshot).legacyFontFamily() == null
    }
    val seed = inheritedStyle.copy(fontWeight = if (snapshot.bold) FontWeight.Bold else FontWeight.Normal,
        fontStyle = if (snapshot.italic) FontStyle.Italic else FontStyle.Normal,
        baselineShift = BaselineShift.None,
        fontFeatureSettings = snapshot.fontFeatures?.nativeSettings ?: inheritedStyle.fontFeatureSettings,
        fontFamily = family?.let(::nativeTerminalFontFamily) ?: inheritedStyle.fontFamily,
        localeList = language?.let { LocaleList(Locale(it)) } ?: inheritedStyle.localeList)
    var resolved = seed.toSpanStyle()
    CompositionLocalProvider(LocalCellWeight provides null, LocalCellLetterSpacingPixels provides null,
        LocalNativePreformattedText provides false,
        LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = context.fontFamily)) {
        resolved = inlineFontSnapshotAnnotation(snapshot, seed).spanStyles
            .fold(seed.toSpanStyle()) { value, range -> value.merge(range.item) }
    }
    return try {
        if (!snapshot.fontNormalized || snapshot.fontScale == null || snapshot.fontScaleBasis == FontScaleBasis.Context ||
            snapshot.language.isNotEmpty() && language == null)
            throw UnsupportedFloatLayout(NativeContainerOwnerFontUnavailable)
        val ownerStyle = seed.copy(fontSize = resolved.fontSize, fontWeight = resolved.fontWeight,
            fontStyle = resolved.fontStyle, fontFamily = resolved.fontFamily,
            fontSynthesis = resolved.fontSynthesis, fontFeatureSettings = resolved.fontFeatureSettings,
            localeList = resolved.localeList, baselineShift = BaselineShift.None,
            letterSpacing = resolved.letterSpacing, textGeometricTransform = resolved.textGeometricTransform)
        if (!ownerStyle.fontSize.isSp) throw UnsupportedFloatLayout(NativeContainerOwnerFontUnavailable)
        val pixels = with(density) { ownerStyle.fontSize.toPx() }
        if (!pixels.isFinite() || pixels < 0f || pixels > MaxComputedFontPixels)
            throw UnsupportedFloatLayout(NativeContainerOwnerFontUnavailable)
        Result.success(context.copy(containerText = state.copy(resolved = NativeDeclaringFont(snapshot,
            ownerStyle, NativeDeclaringFontKind.Container, pixels))))
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(if (error is UnsupportedFloatLayout) error else
            UnsupportedFloatLayout(NativeContainerOwnerFontUnavailable))
    }
}

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

/** BODY font and line-height are independent inheritance policies. The nullable original
 * context distinguishes an actual absent context from a synthesized body default. */
internal data class NativeBodyTextOrigin(val original: ContainerTextContext?,
    val baseline: ContainerTextContext, val fontInherited: Boolean = true,
    val lineHeightInherited: Boolean = true, val sizeInherited: Boolean = true,
    val familyInherited: Boolean = true)

/** This is the existing root body context calculation, before applying Entry typography. */
internal fun nativeRootTextContext(style: TextStyle, normalBodySize: TextUnit,
    density: Density): ContainerTextContext {
    val height = when {
        style.lineHeight.isSp -> ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px,
            style.lineHeight.value * density.fontScale))
        style.lineHeight.isEm -> ContainerLineHeight.Multiplier(style.lineHeight.value)
        else -> ContainerLineHeight.Normal
    }
    return ContainerTextContext(if (normalBodySize.value == 0f) 1f else
        style.fontSize.value / normalBodySize.value, height)
}

@Composable
internal fun nativeBodyTextContext(ownerFont: InlineFontSnapshot, lineHeight: ContainerLineHeight?,
    inherited: ContainerTextContext?, normalBodySize: TextUnit, inheritedStyle: TextStyle,
    density: Density): Result<ContainerTextContext> {
    val baseline = inherited ?: nativeRootTextContext(inheritedStyle, normalBodySize, density)
    val requested = ContainerStyle(ownerFont = ownerFont, lineHeight = lineHeight).textContext(baseline)
        .copy(bodyOrigin = NativeBodyTextOrigin(inherited, baseline))
    return nativeContainerOwnerTextContext(requested, inheritedStyle, density)
}

/** Excluded sinks remove only BODY-owned defaults. A nearer converted Cell/Table line
 * height survives without a fabricated Cell font or a physical-pixel round trip. */
internal fun nativeWithoutBodyTextContext(context: ContainerTextContext?, normalBodySize: TextUnit,
    density: Density): ContainerTextContext? {
    val origin = context?.bodyOrigin ?: return context
    if (origin.fontInherited && origin.lineHeightInherited && origin.sizeInherited && origin.familyInherited)
        return origin.original
    if (!origin.fontInherited && !origin.lineHeightInherited) return context.copy(bodyOrigin = null)
    // Legacy aliases remain source declarations, but do not issue a complete font.
    val fontContext = if (!origin.fontInherited) context else ContainerStyle(
        ownerFontScale = context.ownerFontScale.takeUnless { origin.sizeInherited },
        fontFamily = context.fontFamily.takeUnless { origin.familyInherited })
        .textContext((origin.original ?: origin.baseline).copy(bodyOrigin = null))
    val heightContext = if (origin.lineHeightInherited) origin.baseline else context
    val height = heightContext.resolvedLineHeight ?: heightContext.containerText?.lineHeight
        ?: heightContext.cellText?.lineHeight
        ?: nativeContainerLineHeight(heightContext.lineHeight, normalBodySize, density)
    return fontContext.copy(lineHeight = heightContext.lineHeight, resolvedLineHeight = height,
        cellText = fontContext.cellText?.copy(lineHeight = height),
        containerText = fontContext.containerText?.copy(lineHeight = height), bodyOrigin = null)
}

/** No layout wrapper: excluded source sinks retain their existing composition and owner. */
@Composable
internal fun WithoutBodyTypography(content: @Composable () -> Unit) {
    val context = LocalNativeContainerTextContext.current
    if (context?.bodyOrigin == null) content() else {
        val restored = nativeWithoutBodyTextContext(context, MaterialTheme.typography.bodyLarge.fontSize, LocalDensity.current)
        CompositionLocalProvider(LocalNativeContainerTextContext provides restored, content = content)
    }
}
