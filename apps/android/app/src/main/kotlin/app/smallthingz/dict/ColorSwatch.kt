package app.smallthingz.dict

import kotlin.math.pow

/** Compiled metadata only. Invalid or unknown features leave the stored table visible. */
internal data class ColorSwatch(val hex: String, val argb: Long)
internal fun colorSwatch(feature: Feature?): ColorSwatch? {
    if (feature?.kind != "color_swatch" || feature.language.isNotEmpty() ||
        feature.tailKind != "none" || feature.tail.isNotEmpty() || !Regex("#[0-9a-f]{6}").matches(feature.data)) return null
    return ColorSwatch(feature.data, 0xff000000L or feature.data.substring(1).toLong(16))
}

/** Canonical compiled cell metadata only; never interpret CSS or synthesize a label. */
internal fun canonicalColorArgb(value: String?): Long? =
    value?.takeIf { Regex("#[0-9a-f]{6}").matches(it) }?.let { 0xff000000L or it.substring(1).toLong(16) }

/** Explicit authored text wins; unspecified text must remain readable on authored paint. */
internal fun authoredSpanForegroundArgb(foreground: String?, background: String?): Long? {
    canonicalColorArgb(foreground)?.let { return it }
    val color = canonicalColorArgb(background) ?: return null
    fun linear(shift: Int): Double {
        val channel = ((color shr shift) and 255).toDouble() / 255.0
        return if (channel <= 0.04045) channel / 12.92 else ((channel + 0.055) / 1.055).pow(2.4)
    }
    val luminance = 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    val blackContrast = (luminance + 0.05) / 0.05
    val whiteContrast = 1.05 / (luminance + 0.05)
    return if (blackContrast >= whiteContrast) 0xff000000L else 0xffffffffL
}
