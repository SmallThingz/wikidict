package app.smallthingz.dict

import android.content.Context
import android.graphics.Typeface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.AndroidFont
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontLoadingStrategy
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import kotlinx.coroutines.CancellationException

internal const val NativeNamedFamilyUnavailable = "A loaded named font family requires a native fallback chain."
internal const val NativeNamedFamilyProbeUnavailable = "Named font availability is unavailable."
internal const val NativeSectionHeadingLanguageUnavailable = "Section heading language is unavailable for this layout."

/** OptionalLocal's nullable loader is the presence test; Resolver.resolve would hide absence. */
internal fun interface NativeNamedFontProbe {
    fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface?
}

private object AndroidNamedFontProbe : NativeNamedFontProbe {
    override fun load(context: Context, name: String, weight: FontWeight, style: FontStyle): Typeface? {
        val font = Font(DeviceFontFamilyName(name), weight, style) as? AndroidFont
            ?: throw UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable)
        if (font.loadingStrategy != FontLoadingStrategy.OptionalLocal)
            throw UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable)
        return font.typefaceLoader.loadBlocking(context, font)
    }
}

internal val LocalNativeNamedFontProbe = staticCompositionLocalOf<NativeNamedFontProbe> { AndroidNamedFontProbe }

/** Only a terminal generic is executable until an ordered native named fallback chain exists. */
internal fun nativeTerminalFontFamily(family: ContainerFontFamily): FontFamily = when (family) {
    ContainerFontFamily.SansSerif -> FontFamily.SansSerif
    is ContainerFontFamily.Stack -> when (family.fallback) {
        GenericFontFamily.SansSerif -> FontFamily.SansSerif
        GenericFontFamily.Serif -> FontFamily.Serif
    }
}

internal fun nativeContainerFontAdmission(family: ContainerFontFamily?, weight: FontWeight, style: FontStyle,
    available: (String, FontWeight, FontStyle) -> Boolean): Result<FontFamily?> = try {
    if (family is ContainerFontFamily.Stack) family.names.forEach { name ->
        if (available(name, weight, style)) throw UnsupportedFloatLayout(NativeNamedFamilyUnavailable)
    }
    Result.success(family?.let(::nativeTerminalFontFamily))
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    Result.failure(if (error is UnsupportedFloatLayout) error else UnsupportedFloatLayout(NativeNamedFamilyProbeUnavailable))
}

@Composable
internal fun nativeContainerFontAdmission(family: ContainerFontFamily?, weight: FontWeight,
    style: FontStyle): Result<FontFamily?> {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val probe = LocalNativeNamedFontProbe.current
    return remember(family, weight, style, context, configuration, probe) {
        nativeContainerFontAdmission(family, weight, style) { name, requestedWeight, requestedStyle ->
            probe.load(context, name, requestedWeight, requestedStyle) != null
        }
    }
}

/** The exact owner tuple replaces UI heading presets. Box em lengths keep the normal-body basis. */
@Composable
internal fun nativeSectionHeadingTextFormat(heading: SectionHeadingStyle, normalBodySize: TextUnit,
    inheritedStyle: TextStyle, density: Density): Result<NativeContainerTextFormat> {
    val weight = if (heading.font.bold) FontWeight.Bold else FontWeight.Normal
    val fontStyle = if (heading.font.italic) FontStyle.Italic else FontStyle.Normal
    val family = nativeContainerFontAdmission(heading.box.fontFamily, weight, fontStyle)
    return try {
        val language = heading.font.language?.let(::nativeTableOwnerLanguageTag)
            ?: throw UnsupportedFloatLayout(NativeSectionHeadingLanguageUnavailable)
        val ownerStyle = inheritedStyle.copy(fontWeight = weight, fontStyle = fontStyle,
            fontFamily = family.getOrThrow(), localeList = LocaleList(Locale(language)),
            textDirection = if (heading.direction == BidiResolvedDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr,
            baselineShift = BaselineShift.None, fontFeatureSettings = heading.font.fontFeatures?.nativeSettings)
        Result.success(nativeContainerTextFormat(heading.box.textContext(ContainerTextContext()),
            normalBodySize, ownerStyle, density))
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(if (error is UnsupportedFloatLayout) error else UnsupportedFloatLayout("Section heading font geometry is unavailable."))
    }
}

/** One original child and one existing border-box solver; source heading flow-root is explicit. */
internal data class NativeSectionHeadingAllocation(val minimumWidth: Float,
    val horizontal: (Float) -> NativeContainerHorizontal)

internal fun nativeSectionHeadingSpec(id: Int, heading: SectionHeadingStyle, child: NativeFloatContextSpec.Text,
    density: Float, normalBodyFont: Float, dark: Boolean): NativeFloatContextSpec.Container {
    // The closed heading box has no responsive rules; its projection is width-independent.
    val resolved = heading.box.atViewport(0.0)
    val prepared = nativeContainerSpec(id, resolved, listOf(child), density,
        normalBodyFont, heading.direction == BidiResolvedDirection.Rtl, dark, false)
    if (prepared.unavailableReason != null) return prepared.copy(isolatesFloats = true)
    return try {
        val edges = prepared.padding(0)
        val margins = prepared.margins(0)
        val minimum = maxOf(0.0, edges.left.toDouble() + edges.right + margins.left + margins.right)
        if (!minimum.isFinite() || minimum > TablePixelLimit)
            throw UnsupportedFloatLayout("Section heading edges exceed native geometry.")
        // Round the minimum upward only when Float storage would otherwise admit a band
        // narrower than the fixed edges. The actual interval and solved origin stay Float.
        val minimumFloat = minimum.toFloat().let { if (it.toDouble() < minimum) java.lang.Math.nextUp(it) else it }
        val allocation = NativeSectionHeadingAllocation(minimumFloat) { available ->
            if (!available.isFinite() || available < 0f || available.toDouble() < minimum)
                throw UnsupportedFloatLayout("An overconstrained heading box requires its containing direction.")
            val box = containerBoxWidth(resolved, available, ContainerWidths(0f, 0f), density, normalBodyFont)
            NativeContainerHorizontal.from(box, edges.left, margins.left, margins.right)
        }
        prepared.copy(isolatesFloats = true, headingAllocation = allocation,
            contentWidth = { width, _ -> kotlin.math.floor(allocation.horizontal(width.toFloat()).content).toInt() },
            horizontal = { width, _ -> allocation.horizontal(width.toFloat()) })
    } catch (failure: UnsupportedFloatLayout) {
        prepared.copy(isolatesFloats = true, unavailableReason = failure.message)
    }
}

/** Resource-backed custom action IDs cannot collide with Android's standard action bitmask. */
internal fun nativeHeadingCustomActionId(index: Int): Int = NativeHeadingCustomActionIds[index]
internal val NativeHeadingCustomActionIds = intArrayOf(
    R.id.section_heading_fold,
    R.id.section_heading_details,
)
