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
    val luminance = rgbLuminance(color.toInt())
    val blackContrast = (luminance + 0.05) / 0.05
    val whiteContrast = 1.05 / (luminance + 0.05)
    return if (blackContrast >= whiteContrast) 0xff000000L else 0xffffffffL
}

private fun rgbLuminance(color: Int): Double {
    fun linear(shift: Int): Double {
        val channel = ((color ushr shift) and 255) / 255.0
        return if (channel <= 0.04045) channel / 12.92 else ((channel + 0.055) / 1.055).pow(2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
}

/** Only a bare definition paints directly onto the reader page. Media and poem
 * renderers establish their own presentation and can project their source spans. */
internal fun Block.usesPageForDefinitionInk(): Boolean = kind == "definition" && table == null &&
    container == null && figure == null && flow == null && feature == null && style == null &&
    !spans.hasNativeInlineGroups() && spans.none {
        it.classes.isNotEmpty() && (it.hasClassToken("wikidict-media") || it.hasClassToken("wikidict-poem"))
    }

internal fun readingSpanInk(span: Span, ink: Int?, darkPage: Int?): Int? {
    if (ink == null || darkPage == null || span.kind != "text" || span.background != null ||
        span.code || span.image != null || span.linkPaint != null || span.audioControl != null ||
        span.classes.isNotEmpty() && span.hasClassToken("Egyp")) return ink
    val minimum = 4.5 * (rgbLuminance(darkPage) + 0.05) - 0.05
    if (rgbLuminance(ink) >= minimum || minimum > 1.0) return ink
    fun blend(amount: Int): Int {
        fun channel(shift: Int): Int {
            val source = (ink ushr shift) and 255
            return source + ((255 - source) * amount + 127) / 255
        }
        return (0xff shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }
    // Find the first quantized blend toward white that reaches normal text contrast.
    var low = 1
    var high = 255
    while (low < high) {
        val mid = (low + high) / 2
        if (rgbLuminance(blend(mid)) >= minimum) high = mid else low = mid + 1
    }
    return blend(low)
}
